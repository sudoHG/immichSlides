"""Bounded App Store Connect calls without response-body or credential logging."""

from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from ci_summary import ContractError, require
from ci_xcode_cloud import IMPORT_PATH, ROUTE_PATH, WORKFLOW_ID, uuid

ORIGIN = "https://api.appstoreconnect.apple.com"
MAX_BYTES = 16 * 1024 * 1024


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise ContractError("App Store Connect redirect refused")


def raw_signature(signature):
    # ES256 uses a fixed-width R || S JWT signature, whereas OpenSSL emits DER.
    require(len(signature) >= 8 and signature[0] == 0x30 and signature[1] == len(signature) - 2,
            "invalid ES256 signature")
    cursor, values = 2, []
    for _ in range(2):
        require(cursor + 2 <= len(signature) and signature[cursor] == 2, "invalid ES256 integer")
        length = signature[cursor + 1]
        value = signature[cursor + 2:cursor + 2 + length]
        require(length > 0 and len(value) == length and value[0] < 128, "invalid ES256 integer encoding")
        value = value.lstrip(b"\0")
        require(len(value) <= 32, "invalid ES256 integer width")
        values.append(value.rjust(32, b"\0"))
        cursor += 2 + length
    require(cursor == len(signature), "invalid ES256 signature suffix")
    return b"".join(values)


def credential_context(environment, path):
    require(path in {IMPORT_PATH, ROUTE_PATH} and environment.get("GITHUB_REF") == "refs/heads/main"
            and environment.get("GITHUB_WORKFLOW_REF") == environment.get("GITHUB_REPOSITORY", "") +
            "/" + path + "@refs/heads/main" and environment.get("GITHUB_EVENT_NAME") == "workflow_dispatch",
            "ASC credential requires the expected main-only workflow")


def jwt(environment, path):
    credential_context(environment, path)
    issuer, key_id = environment.get("ASC_ISSUER_ID", ""), environment.get("ASC_KEY_ID", "")
    uuid(issuer)
    require(re.fullmatch(r"[A-Z0-9]{10}", key_id), "missing or invalid ASC key identifier")
    private_key = environment.get("ASC_PRIVATE_KEY", "").encode()
    require(0 < len(private_key) <= 4096, "missing or oversized ASC private key")
    encode = lambda value: base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=")
    now = int(time.time())
    message = encode({"alg": "ES256", "kid": key_id, "typ": "JWT"}) + b"." + encode({
        "iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"})
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, private_key)
        os.close(write_fd)
        write_fd = None
        signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", f"/dev/fd/{read_fd}"], input=message,
                                capture_output=True, pass_fds=(read_fd,), env={"PATH": environment.get("PATH", "")}, timeout=10)
        require(signed.returncode == 0, "ASC signing failed")
    finally:
        os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)
    return (message + b"." + base64.urlsafe_b64encode(raw_signature(signed.stdout)).rstrip(b"=")).decode()


class AppStoreConnect:
    def __init__(self, token):
        self.token = token

    def request(self, path, *, method="GET", payload=None):
        parsed = urlsplit(path)
        if parsed.scheme:
            require(parsed.scheme == "https" and parsed.netloc == "api.appstoreconnect.apple.com"
                    and not parsed.fragment and parsed.path.startswith("/v1/"), "unexpected ASC pagination URL")
            url = path
        else:
            require(path.startswith("/v1/") and not path.startswith("//"), "invalid ASC path")
            url = ORIGIN + path
        data = json.dumps(payload).encode() if payload is not None else None
        request = Request(url, method=method, data=data, headers={
            "Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        try:
            with build_opener(NoRedirect()).open(request, timeout=45) as response:
                raw = response.read(MAX_BYTES + 1)
        except HTTPError as error:
            raise ContractError(f"ASC {method} refused request (HTTP {error.code})") from None
        require(len(raw) <= MAX_BYTES, "ASC payload exceeds limit")
        return json.loads(raw)

    def pages(self, path):
        rows, seen, links = [], set(), set()
        for _ in range(100):
            require(path not in links, "ASC pagination cycle")
            links.add(path)
            response = self.request(path)
            require(isinstance(response["data"], list), "ASC collection is invalid")
            for row in response["data"]:
                require(isinstance(row["id"], str) and row["id"] not in seen, "duplicated ASC resource")
                seen.add(row["id"])
                rows.append(row)
            next_page = response.get("links", {}).get("next")
            if not next_page:
                return rows
            require(isinstance(next_page, str), "invalid ASC pagination link")
            path = next_page
        raise ContractError("ASC pagination limit reached")

    def evidence(self, run_id):
        uuid(run_id)
        run = self.request("/v1/ciBuildRuns/" + run_id)["data"]
        attributes = run["attributes"]
        # ciBuildRuns exposes builds/actions, not a workflow relationship to
        # Developer keys. Membership in the fixed workflow's paginated build
        # collection independently binds the API results to that workflow.
        workflow_runs = self.pages("/v1/ciWorkflows/" + WORKFLOW_ID + "/buildRuns?limit=200")
        require(sum(row["id"] == run_id for row in workflow_runs) == 1, "cloud run is outside the overflow workflow")
        result = {"id": run["id"], "workflow_id": WORKFLOW_ID,
                  "head_sha": attributes.get("sourceCommit", {}).get("commitSha"),
                  "progress": attributes.get("executionProgress"), "status": attributes.get("completionStatus"),
                  "started": attributes.get("startedDate"), "finished": attributes.get("finishedDate"), "actions": []}
        for action in self.pages("/v1/ciBuildRuns/" + run_id + "/actions?limit=200"):
            a = action["attributes"]
            item = {"id": action["id"], "name": a.get("name"), "type": a.get("actionType"),
                    "progress": a.get("executionProgress"), "status": a.get("completionStatus"),
                    "started": a.get("startedDate"), "finished": a.get("finishedDate"), "tests": []}
            # Incomplete runs are intentionally incomplete evidence, not a
            # partial successful subset or a reason to omit missing methods.
            if a.get("executionProgress") == "COMPLETE":
                for test in self.pages("/v1/ciBuildActions/" + action["id"] + "/testResults?limit=200"):
                    t = test["attributes"]
                    item["tests"].append({"id": test["id"], "class": t.get("className"), "method": t.get("name"),
                        "status": t.get("status"), "destinations": [{"device": d.get("deviceName"),
                        "os": d.get("osVersion"), "status": d.get("status")} for d in t.get("destinationTestResults", [])]})
            result["actions"].append(item)
        return result
