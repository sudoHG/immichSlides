#!/usr/bin/env python3
"""Trusted, state-based CI admission, publication and exact-head approval.

No candidate checkout, candidate imports or artifact execution. The App key is
read only after the workflow/event/ref guard, and tokens are never printed.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import re
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from ci_summary import ContractError, parse_identity, parse_summary, require, sha
from ci_publish_git import derive_record, evaluate_records, git, ui_failure_hint, workflow_contract

PUBLISH_PATH = ".github/workflows/ci-publish.yml"
APPROVAL_PATH = ".github/workflows/ci-approval.yml"
APPROVE_PATH = ".github/workflows/ci-approve.yml"
PRODUCERS = {"ci-pr-gate": ".github/workflows/ci-gate.yml", "ci-ui": ".github/workflows/ci-ui.yml"}
MAX_JSON_BYTES = 16 * 1024 * 1024


class ArtifactRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        from urllib.parse import urlsplit
        parsed = urlsplit(new_url)
        require(parsed.scheme == "https", "artifact redirect must use HTTPS")
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if parsed.hostname != "api.github.com":
            redirected.remove_header("Authorization")
        return redirected


def positive(value):
    require(type(value) is int and value > 0, "positive integer required")
    return value


def verify_workflow(run, workflow, repository):
    require(run["repository"]["full_name"] == repository, "wrong producer repository")
    require(run["workflow_id"] == workflow["id"] and run["path"] == workflow["path"], "wrong producer workflow path or ID")
    positive(run["id"])
    sha(run["head_sha"])
    require(run["event"] in {"pull_request", "push"}, "unsupported producer event")


def admission_identity(repository, run, pr, commit, *, existing=None, on_main=False):
    if existing is not None:
        identity = parse_identity(existing)
        require(identity["repository"] == repository, "wrong original admission repository")
        return identity
    require(run["repository"]["full_name"] == repository, "wrong admission repository")
    identity = {"schema_version": 1, "repository": repository, "event": run["event"], "tree_sha": commit["tree"]["sha"]}
    if run["event"] == "pull_request":
        require(pr["state"] == "open" and pr["base"]["ref"] == "main"
                and pr["base"]["repo"]["full_name"] == repository, "PR must target this repository's main")
        require(len(commit["parents"]) == 2, "GitHub merge must have two parents")
        require(commit["parents"][1]["sha"] == pr["head"]["sha"] == run["head_sha"], "stale producer head")
        identity.update(pull_request=positive(pr["number"]), merge_sha=commit["sha"],
                        base_sha=commit["parents"][0]["sha"], head_sha=pr["head"]["sha"])
    else:
        require(run["event"] == "push" and run["head_branch"] == "main" and on_main,
                "push must be an ancestor of main")
        require(commit["sha"] == run["head_sha"], "push commit mismatch")
        identity.update(ref="refs/heads/main", pushed_sha=commit["sha"])
    return parse_identity(identity)


def match_producer(producer, admitted, *, previous_mismatch=False):
    if parse_identity(producer) != parse_identity(admitted):
        return "base moved; push again or update the branch" + (" (repeated across reruns)" if previous_mismatch else "")
    return None


def prior_mismatch(statuses, run, login):
    prefix = f"ci-base-mismatch/run-{run['id']}/attempt-"
    return any(status["creator"]["login"] == login and status["state"] == "success"
               and status["context"].startswith(prefix) and status["context"][len(prefix):].isdecimal()
               and int(status["context"][len(prefix):]) < run["run_attempt"] for status in statuses)


def authoritative_run(runs, head, workflow, repository):
    admitted = []
    for run in runs:
        if run["head_sha"] == head:
            verify_workflow(run, workflow, repository)
            admitted.append(run)
    return max(admitted, key=lambda run: (run["id"], run["run_attempt"]), default=None)


def complete_attempt_jobs(api, run):
    """Require the API's explicit count, including for an empty attempt."""
    jobs, seen, total = [], set(), None
    for page in range(1, 101):
        response = api.repo(f"actions/runs/{positive(run['id'])}/attempts/{positive(run['run_attempt'])}/jobs?"
                            + urlencode({"per_page": 100, "page": page}))
        count, batch = response["total_count"], response["jobs"]
        require(type(count) is int and 0 <= count <= 10000 and (total is None or count == total),
                "invalid or changing attempt job count")
        require(isinstance(batch, list) and len(batch) <= 100, "invalid attempt jobs")
        total = count
        for job in batch:
            job_id = positive(job["id"])
            require(job_id not in seen and positive(job["run_id"]) == run["id"]
                    and positive(job["run_attempt"]) == run["run_attempt"], "unexpected attempt job")
            seen.add(job_id)
        jobs.extend(batch)
        require(len(seen) <= total, "attempt jobs exceed total count")
        if len(batch) < 100 or len(seen) == total:
            require(len(seen) == total, "incomplete attempt jobs")
            return jobs
    raise ContractError("attempt jobs pagination limit reached")


def cancelled_unstarted_run(api, run):
    """Recognize an unexecuted first-attempt main gate or UI run superseded by a push."""
    try:
        workflow_file = {path: path.rpartition("/")[2] for path in PRODUCERS.values()}.get(run["path"])
        if (workflow_file is None or run["event"] != "push"
                or run["head_branch"] != "main" or run["head_repository"]["full_name"] != api.repository
                or run["repository"]["full_name"] != api.repository
                or run["status"] != "completed" or run["conclusion"] != "cancelled"
                or type(run["run_attempt"]) is not int or run["run_attempt"] != 1):
            return False
        workflow = api.repo("actions/workflows/" + workflow_file)
        verify_workflow(run, workflow, api.repository)
        for job in complete_attempt_jobs(api, run):
            require(job["status"] == "completed" and job["conclusion"] in {"cancelled", "skipped"}
                    and (job["runner_id"] is None or type(job["runner_id"]) is int and job["runner_id"] == 0)
                    and job["steps"] == [], "job may have executed")
        # main is protected and linear. A bounded recent page is enough to prove
        # a newer different push exists; missing proof keeps the failure path.
        response = api.repo(f"actions/workflows/{positive(workflow['id'])}/runs?"
                            + urlencode({"branch": "main", "event": "push", "per_page": 100}))
        require(isinstance(response["workflow_runs"], list), "invalid main runs")
        for newer in response["workflow_runs"]:
            verify_workflow(newer, workflow, api.repository)
            if (newer["event"] == "push" and newer["head_branch"] == "main"
                    and newer["head_repository"]["full_name"] == api.repository
                    and newer["id"] > run["id"] and newer["head_sha"] != run["head_sha"]):
                return True
        return False
    except (ContractError, KeyError, ValueError, TypeError):
        return False


def approval_context(pr, head):
    positive(pr)
    sha(head)
    return f"ci-approved/pr-{pr}/{head}"


def approval_plan(pr, requests, *, approved, needs_approval):
    head = pr["head"]["sha"]
    return {"request": head if needs_approval and not approved and not any(r["head_sha"] == head for r in requests) else None,
            "obsolete": [r["run_id"] for r in requests if r["head_sha"] != head and r["status"] != "completed"]}


def publication_plan(pr, runs, admissions, evaluations, *, approved, needs_approval):
    fork = pr["head"]["repo"]["full_name"] != pr["base"]["repo"]["full_name"]
    plan = {}
    for context in PRODUCERS:
        run = runs.get(context)
        if needs_approval and not approved:
            state = {"state": "failure", "description": "Exact head approval required"}
            if run and admissions.get(run["id"], {}).get("workflows", {}).get(run["path"], {}).get("base", "") is None:
                state["description"] = "workflow is absent on the base; exact-head approval required"
        elif not run or run["id"] not in admissions:
            state = {"state": "pending", "description": "Waiting for producer and trusted admission"}
        elif run["status"] != "completed":
            state = {"state": "pending", "description": "Authoritative producer is running (latest attempt)"}
        elif run["conclusion"] != "success":
            state = {"state": "failure", "description": "Authoritative producer failed or was cancelled"}
        else:
            state = dict(evaluations.get(context, {"state": "failure", "description": "Missing or invalid producer evidence"}))
        # Failure/approval state is independent of the retained producer diagnostics.
        for key in ("diagnostics", "report_source"):
            if key in evaluations.get(context, {}):
                state[key] = evaluations[context][key]
        if state["state"] == "failure" and run:
            state.setdefault("target_url", f"https://github.com/{pr['base']['repo']['full_name']}/actions/runs/{run['id']}")
        suffix = "; self-reported" if fork else ""
        suffix += "; approval-based" if approved and needs_approval else ""
        state["description"] = state["description"][:140 - len(suffix)] + suffix
        plan[context] = state
    plan["ci-approval-state"] = {"state": "success" if approved or not needs_approval else "pending",
                                 "description": "Exact head approved" if approved else "Approval not needed" if not needs_approval else "Waiting for maintainer approval"}
    return plan


def check_credential_context(environment, path):
    require(environment.get("GITHUB_REF") == "refs/heads/main", "publisher credential requires main")
    require(environment.get("GITHUB_WORKFLOW_REF") == environment.get("GITHUB_REPOSITORY", "") + "/" + path + "@refs/heads/main",
            "publisher credential requires the expected workflow path")
    allowed = {"workflow_run", "workflow_dispatch"} if path == PUBLISH_PATH else {"workflow_dispatch"}
    require(environment.get("GITHUB_EVENT_NAME") in allowed, "publisher credential refused to this event")


class RateLimited(ContractError):
    """A GitHub rate-limit refusal; carries only the seconds until a retry may succeed."""

    def __init__(self, message, wait_seconds):
        super().__init__(message)
        self.wait_seconds = wait_seconds


SECONDARY_RATE_LIMIT_SECONDS = 60  # GitHub documents waiting at least a minute when no reset header is sent


def rate_limit_wait(error):
    """Seconds to wait when an HTTP error is a documented rate limit, else None. Never exposes the response."""
    if error.code not in (403, 429):
        return None
    headers = error.headers or {}
    retry_after, remaining, reset = (headers.get(name) for name in ("Retry-After", "X-RateLimit-Remaining", "X-RateLimit-Reset"))
    if retry_after and retry_after.isdecimal():
        return max(1, int(retry_after))
    if remaining == "0" and reset and reset.isdecimal():
        return max(1, int(reset) - int(time.time()))
    if error.code == 429:
        return SECONDARY_RATE_LIMIT_SECONDS
    try:
        body = error.read(4096).decode("utf-8", "replace").lower()
    except (OSError, ValueError, AttributeError):
        return None
    return SECONDARY_RATE_LIMIT_SECONDS if "secondary rate limit" in body else None


class GitHub:
    def __init__(self, repository, token, *, response_headers=None):
        require(re.fullmatch(r"[\w.-]+/[\w.-]+", repository) is not None, "invalid repository")
        self.repository, self.token = repository, token
        self.response_headers = response_headers

    def request(self, path, *, method="GET", payload=None, binary=False, missing=False, timeout=45):
        url = "https://api.github.com" + path
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = Request(url, data=data, method=method, headers=headers)
        try:
            with build_opener(ArtifactRedirect()).open(request, timeout=timeout) as response:
                if self.response_headers:
                    self.response_headers(response.headers)
                raw = response.read(MAX_JSON_BYTES + 1)
        except HTTPError as error:
            if self.response_headers:
                self.response_headers(error.headers)
            if missing and error.code == 404:
                return None
            # Never echo response bodies, headers, request objects or credentials.
            message = f"GitHub API {method} refused request (HTTP {error.code})"
            wait = rate_limit_wait(error)
            if wait is not None:
                raise RateLimited(message, wait) from None
            raise ContractError(message) from None
        require(len(raw) <= MAX_JSON_BYTES, "GitHub payload exceeds limit")
        return raw if binary else json.loads(raw) if raw else None

    def repo(self, path, **options):
        return self.request("/repos/" + self.repository + "/" + path, **options)

    def pages(self, path, collection=None, **filters):
        rows = []
        for page in range(1, 101):
            response = self.repo(path + "?" + urlencode(dict(filters, per_page=100, page=page)))
            batch = response[collection] if collection else response
            rows.extend(batch)
            if len(batch) < 100:
                return rows
        raise ContractError("GitHub pagination limit reached; publication refused")

    def status(self, head, context, state, description, target_url):
        sha(head)
        self.repo("statuses/" + head, method="POST", payload={"context": context, "state": state,
                  "description": description[:140], "target_url": target_url})

    def dispatch(self, path, inputs):
        self.repo("actions/workflows/" + path.rsplit("/", 1)[-1] + "/dispatches", method="POST",
                  payload={"ref": "main", "inputs": inputs})


class RateLimitWaitingGitHub(GitHub):
    """Long-running read waiters only: a rate-limited GET waits for its reset inside the caller's remaining time."""

    def __init__(self, repository, token, remaining_seconds, *, sleep=time.sleep):
        super().__init__(repository, token)
        self.remaining_seconds, self.sleep = remaining_seconds, sleep

    def pause_for(self, wait_seconds):
        """Sleep out a rate limit whose full wait (plus one second) fits in the remaining time; True when a retry is still in time."""
        if wait_seconds + 1 >= self.remaining_seconds():
            return False
        print(f"GitHub rate limit: waiting {wait_seconds} seconds", flush=True)
        self.sleep(wait_seconds + 1)
        return self.remaining_seconds() > 0

    def retry_timeout(self, timeout):
        return max(0.1, min(timeout, self.remaining_seconds()))

    def request(self, path, *, method="GET", **options):
        timeout = options.pop("timeout", 45)
        while True:
            try:
                return super().request(path, method=method, timeout=timeout, **options)
            except RateLimited as error:
                if method != "GET" or not self.pause_for(error.wait_seconds):
                    raise
                timeout = self.retry_timeout(timeout)


def mint_app(environment, path):
    check_credential_context(environment, path)
    app_id = environment.get("CI_APP_ID", "")
    require(app_id.isdecimal(), "missing App ID")
    private_key = environment.get("CI_APP_PRIVATE_KEY", "")
    require(bool(private_key), "missing App private key")
    now = int(time.time())
    encoded = lambda value: base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=")
    message = encoded({"alg": "RS256", "typ": "JWT"}) + b"." + encoded({"iat": now - 60, "exp": now + 540, "iss": app_id})
    # A pipe avoids leaving key files behind after forced cancellation. OpenSSL
    # receives only this descriptor; its environment contains no credentials.
    key_bytes = private_key.encode()
    require(len(key_bytes) <= 4096, "App key exceeds the supported RSA PEM size")
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, key_bytes)
        os.close(write_fd)
        write_fd = None
        signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", f"/dev/fd/{read_fd}"], input=message,
                                capture_output=True, pass_fds=(read_fd,), env={"PATH": environment.get("PATH", "")}, timeout=10)
        require(signed.returncode == 0, "App signing failed")
    finally:
        os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)
    jwt = (message + b"." + base64.urlsafe_b64encode(signed.stdout).rstrip(b"=")).decode()
    api = GitHub(environment["GITHUB_REPOSITORY"], jwt)
    app = api.request("/app")
    require(str(app["id"]) == app_id, "App identity mismatch")
    installation = api.repo("installation")
    token = api.request(f"/app/installations/{installation['id']}/access_tokens", method="POST",
                        payload={"repositories": [api.repository.split("/")[1]],
                                 "permissions": {"statuses": "write", "contents": "read", "actions": "read", "pull_requests": "read"}})["token"]
    return GitHub(api.repository, token), app["slug"] + "[bot]"


def json_member(api, artifact, filename, *, optional=False):
    require(not artifact["expired"] and artifact["size_in_bytes"] <= MAX_JSON_BYTES, "artifact expired or oversized")
    archive = api.repo(f"actions/artifacts/{positive(artifact['id'])}/zip", binary=True)
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        members = [entry for entry in zipped.infolist() if entry.filename == filename]
        if optional and not members:
            require(not any(entry.filename.rsplit("/", 1)[-1] == filename for entry in zipped.infolist()),
                    "artifact member has an unexpected path")
            return None
        require(len(members) == 1 and members[0].file_size <= MAX_JSON_BYTES, "artifact member missing, duplicated or oversized")
        value = json.loads(zipped.read(members[0]))
        require(not optional or value is not None, "optional artifact member cannot be null")
        return value


def trusted_admissions(api, run_ids):
    if not run_ids:
        return {}
    workflow = api.repo("actions/workflows/ci-publish.yml", missing=True)
    records = {}
    if workflow is None:
        return records
    # Locate the exact name without enumerating publisher history. Validate
    # each producing run before reading bytes; PR name collisions are ignored.
    git("fetch", "--no-tags", "origin", "refs/heads/main")
    trusted, ancestry = {}, {}
    for run_id in run_ids:
        for artifact in api.pages("actions/artifacts", "artifacts", name=f"ci-admission-{positive(run_id)}"):
            if artifact["name"] != f"ci-admission-{run_id}" or artifact["expired"]:
                continue
            uploader = positive(artifact["workflow_run"]["id"])
            if uploader not in trusted:
                run = api.repo(f"actions/runs/{uploader}")
                trusted[uploader] = False
                if (run["id"] == uploader and run["path"] == PUBLISH_PATH and run["workflow_id"] == workflow["id"]
                        and run["event"] in {"workflow_run", "workflow_dispatch"} and run["head_branch"] == "main"
                        and run["head_repository"]["full_name"] == api.repository
                        and run["repository"]["full_name"] == api.repository):
                    revision = run["head_sha"]
                    sha(revision)
                    if revision not in ancestry:
                        ancestry[revision] = subprocess.run(
                            ["git", "merge-base", "--is-ancestor", revision, "FETCH_HEAD"],
                            capture_output=True, timeout=30).returncode == 0
                    trusted[uploader] = ancestry[revision]
            if trusted[uploader]:
                record = json_member(api, artifact, "record.json")
                require(type(record.get("schema_version")) is int and record["schema_version"] == 1, "unsupported admission version")
                require(artifact["name"] == f"ci-admission-{record['run_id']}", "admission run ID mismatch")
                parse_identity(record["identity"])
                if record["run_id"] in records:
                    require(records[record["run_id"]] == record, "conflicting immutable admission records")
                records[record["run_id"]] = record
    return records


def workflows(api):
    result = {}
    for context, path in PRODUCERS.items():
        workflow = api.repo("actions/workflows/" + path.rsplit("/", 1)[-1], missing=True)
        if workflow is not None:
            require(workflow["path"] == path, "unexpected workflow path")
            result[context] = workflow
    return result


def map_pr(api, run, *, current=True):
    candidates = run.get("pull_requests", []) or api.repo("commits/" + run["head_sha"] + "/pulls")
    if not candidates:
        candidates = api.pages("pulls", state="open", base="main",
                               head=run["head_repository"]["owner"]["login"] + ":" + run["head_branch"])
    matches = []
    for candidate in candidates:
        pr = api.repo(f"pulls/{positive(candidate['number'])}")
        if (pr["state"] == "open" and (not current or pr["head"]["sha"] == run["head_sha"])
                and pr["head"]["repo"]["full_name"] == run["head_repository"]["full_name"]
                and pr["base"]["ref"] == "main" and pr["base"]["repo"]["full_name"] == api.repository):
            matches.append(pr)
    require(len(matches) == 1, "producer has no unique current PR mapping")
    return matches[0]


def route(api, event, environment):
    if environment["GITHUB_EVENT_NAME"] == "workflow_dispatch":
        inputs = event["inputs"]
        pr = int(inputs.get("pull_request", "0") or "0")
        pushed = inputs.get("pushed_sha", "")
        require(bool(pr) != bool(pushed), "dispatch requires one PR or pushed SHA")
        if pushed:
            sha(pushed)
        return {"pr": str(pr), "pushed": pushed, "key": f"pr-{pr}" if pr else "push-" + pushed, "run_id": "0"}
    run = api.repo("actions/runs/" + str(positive(event["workflow_run"]["id"])))
    workflow = next((w for w in workflows(api).values() if w["id"] == run["workflow_id"]), None)
    require(workflow is not None, "producer workflow ID is not admitted")
    verify_workflow(run, workflow, api.repository)
    if run["event"] == "pull_request":
        pr = map_pr(api, run, current=False)["number"]
        return {"pr": str(pr), "pushed": "", "key": f"pr-{pr}", "run_id": str(run["id"])}
    require(run["head_branch"] == "main", "producer push must target main")
    return {"pr": "0", "pushed": run["head_sha"], "key": "push-" + run["head_sha"], "run_id": str(run["id"])}


def admit(api, event):
    run = api.repo("actions/runs/" + str(event["workflow_run"]["id"]))
    require(any(w["id"] == run["workflow_id"] and w["path"] == run["path"] for w in workflows(api).values()), "untrusted producer")
    records = trusted_admissions(api, [run["id"]])
    if run["id"] in records:
        return None
    pr = map_pr(api, run) if run["event"] == "pull_request" else None
    reference_sha = pr["merge_commit_sha"] if pr else api.repo("git/ref/heads/main")["object"]["sha"]
    sha(reference_sha)
    commit_sha = reference_sha if pr else run["head_sha"]
    commit = api.repo("git/commits/" + commit_sha)
    git("fetch", "--no-tags", "origin", "refs/heads/main")
    on_main = not pr and subprocess.run(["git", "merge-base", "--is-ancestor", commit_sha, "FETCH_HEAD"],
                                       capture_output=True, timeout=30).returncode == 0
    if pr:
        git("fetch", "--no-tags", "origin", f"refs/pull/{pr['number']}/merge")
    require(git("cat-file", "-t", commit_sha) == "commit", "admitted GitHub commit unavailable")
    identity = admission_identity(api.repository, run, pr, commit, on_main=on_main)
    if pr:
        require(subprocess.run(["git", "merge-base", "--is-ancestor", identity["base_sha"], "refs/remotes/origin/main"],
                               capture_output=True, timeout=30).returncode == 0, "admitted base is not trusted main history")
    record = derive_record(identity, run)
    if pr:
        author = pr.get("user") or {}
        record["cloud_pr_author"] = {key: author.get(key) for key in ("login", "id")}
    return record


def approved_status(api, pr, login):
    context = approval_context(pr["number"], pr["head"]["sha"])
    statuses = api.pages("commits/" + pr["head"]["sha"] + "/statuses")
    return any(status["context"] == context and status["state"] == "success"
               and status["creator"]["login"] == login for status in statuses)


def producer_evidence(api, run, source, *, diagnostics=None, admission=None, cloud=None):
    """Bind each retained artifact to its job's latest execution attempt.

    Failed-job reruns legitimately retain successful jobs and their old records.
    A rerun job can never fall back to an earlier artifact just because it passed.
    """
    jobs = {}
    minimum_attempts = {}
    for attempt in range(1, run["run_attempt"] + 1):
        require(attempt <= 100, "too many producer attempts")
        attempt_jobs = api.pages(f"actions/runs/{run['id']}/attempts/{attempt}/jobs", "jobs")
        if run["path"] == ".github/workflows/ci-ui.yml":
            from ci_ui_reuse import expand_skipped_ui_matrix
            # Reruns may switch between a collapsed skip and literal execution.
            # Normalize within each attempt before merging logical shard history.
            discarded = set()
            attempt_jobs = expand_skipped_ui_matrix(source, dict(run, run_attempt=attempt), attempt_jobs,
                                                   complete=False, historical=attempt < run["run_attempt"],
                                                   discarded_shards=discarded, cloud=cloud,
                                                   group_history=bool((admission or {}).get("cloud_v2_inputs")))
            # Keep execution history to recognize retained API jobs, but never
            # admit a shard artifact from before its matrix was invalidated.
            minimum_attempts.update({name: attempt + 1 for name in discarded})
        for job in attempt_jobs:
            previous = jobs.get(job["name"])
            execution = ("started_at", "completed_at", "runner_id")
            retained = (previous and all(job.get(key) and job[key] == previous.get(key) for key in execution))
            jobs[job["name"]] = dict(job, evidence_attempt=previous["evidence_attempt"] if retained else attempt)
    require(all(name in jobs and jobs[name]["evidence_attempt"] >= attempt
                for name, attempt in minimum_attempts.items()), "UI shard did not execute after skipped matrix")
    expected, _, by_job, metadata = workflow_contract(source, run, metadata=True)
    from ci_publish_git import gate_not_applicable_jobs, ui_empty_selection_jobs
    allowed_skips = gate_not_applicable_jobs(admission, run, metadata) | ui_empty_selection_jobs(admission, run, metadata, source)
    if diagnostics is None:
        require(set(jobs) == set(expected), "required job set mismatch")
    elif set(jobs) != set(expected):
        diagnostics.append("required job set mismatch")
    artifacts = api.pages(f"actions/runs/{run['id']}/artifacts", "artifacts")
    summaries = []
    for name in expected:
        if name not in jobs:
            diagnostics.append("required job missing: " + name)
            continue
        job = jobs[name]
        if (name in allowed_skips and job["status"] == "completed" and job["conclusion"] == "skipped"):
            continue
        if (run["event"] == "push" and metadata[name]["tier"] == "ui"
                and job["status"] == "completed" and job["conclusion"] == "skipped"):
            continue
        from ci_xcode_cloud_groups import cloud_devices
        if (cloud is not None and run["event"] == "pull_request" and metadata[name].get("device") in cloud_devices(cloud)
                and job["status"] == "completed" and job["conclusion"] == "skipped"):
            require((job.get("runner_id") is None or type(job.get("runner_id")) is int and job["runner_id"] == 0)
                    and job.get("steps") == [], "routed device job may have executed")
            continue
        attempt_run = dict(run, run_attempt=job["evidence_attempt"])
        _, _, names = workflow_contract(source, attempt_run, details=True)
        for artifact_name in names[name]:
            try:
                expired = [artifact for artifact in artifacts if artifact["name"] == artifact_name and artifact["expired"]]
                if expired and diagnostics is not None:
                    diagnostics.append("required artifact expired: " + artifact_name)
                    continue
                matches = [artifact for artifact in artifacts if artifact["name"] == artifact_name and not artifact["expired"]]
                require(len(matches) == 1, "required artifact is missing, expired or duplicated")
                summary = parse_summary(json_member(api, matches[0], "summary.json"))
                require(summary["run"]["id"] == str(run["id"]) and summary["run"]["attempt"] == job["evidence_attempt"],
                        "artifact does not match its job's latest execution attempt")
                require(all(summary["run"][key] == metadata[name][key] for key in ("tier", "job", "shard")),
                        "summary tier/job/shard differs from its verified uploading job")
                summaries.append(summary)
            except (ContractError, KeyError, ValueError, TypeError):
                if diagnostics is None:
                    raise
                diagnostics.append("required artifact missing or invalid: " + artifact_name)
    return list(jobs.values()), summaries


def archive_blocked_ui(api, record, run, jobs, summaries):
    """Excuse only a bound archive timeout behind a superseded unexecuted gate."""
    try:
        if (run["path"] != PRODUCERS["ci-ui"] or run["event"] != "push" or run["head_branch"] != "main"
                or run["head_repository"]["full_name"] != api.repository or run["status"] != "completed"
                or run["conclusion"] != "failure" or type(run["run_attempt"]) is not int or run["run_attempt"] != 1):
            return False
        archive_summaries = [summary for summary in summaries if summary["run"]["job"] == "ui-archive"]
        if len(archive_summaries) != 1 or archive_summaries[0]["infrastructure"] != [{"code": "archive-selection-failed",
                "message": "archive-unavailable: no exact-identity gate archive before timeout"}]:
            return False
        verify_workflow(run, api.repo("actions/workflows/ci-ui.yml"), api.repository)
        identity = parse_identity(record["identity"])
        require(record["workflow_id"] == run["workflow_id"] and record["workflow_path"] == run["path"]
                and identity["repository"] == api.repository and identity["event"] == "push"
                and identity["pushed_sha"] == run["head_sha"], "UI admission mismatch")
        source = record["workflows"][run["path"]]["base"]
        from ci_ui_reuse import expand_skipped_ui_matrix
        normalized = expand_skipped_ui_matrix(source, run, complete_attempt_jobs(api, run))
        _, _, artifacts_by_job, metadata = workflow_contract(source, run, metadata=True)
        require({job["name"] for job in jobs} == {job["name"] for job in normalized}, "UI job set mismatch")
        archives = [job for job in normalized if job["name"] == "ui-archive" and metadata[job["name"]]["tier"] == "ui-infrastructure"]
        selections = [job for job in normalized if job["name"] == "ui-cloud-wait" and metadata[job["name"]]["tier"] == "ui-infrastructure"]
        shards = [job for job in normalized if metadata[job["name"]]["tier"] == "ui"]
        require(len(archives) == 1 and archives[0]["name"] == "ui-archive"
                and archives[0]["status"] == "completed" and archives[0]["conclusion"] == "failure",
                "UI archive did not fail")
        require(shards and len(archives) + len(shards) + len(selections) == len(normalized)
                and all(job["status"] == "completed" and job["conclusion"] == "skipped"
                        and (job["runner_id"] is None or type(job["runner_id"]) is int and job["runner_id"] == 0)
                        and job["steps"] == [] for job in shards), "UI shard may have executed")
        require(len(summaries) == 1 + len(selections) and len(selections) <= 1, "unexpected UI selection records")
        if selections:
            selection_summaries = [entry for entry in summaries if entry["run"]["job"] == "ui-cloud-wait"]
            require(len(selection_summaries) == 1 and selections[0]["status"] == "completed"
                    and selections[0]["conclusion"] == "success", "cloud selection incomplete")
            selection = parse_summary(selection_summaries[0])
            from ci_ui_reuse import validate_infrastructure_summary
            validate_infrastructure_summary(record, selection, "ui-cloud-wait")
            require(selection["run"]["id"] == str(run["id"]) and selection["run"]["attempt"] == run["run_attempt"], "cloud selection attempt differs")
        summary = parse_summary(archive_summaries[0])
        require(summary["identity"] == identity and summary["source"]["workflow_path"] == run["path"]
                and summary["source"]["fork_originated"] is False and summary["status"] == "failed"
                and summary["run"]["id"] == str(run["id"]) and summary["run"]["attempt"] == run["run_attempt"]
                and all(summary["run"][key] == metadata["ui-archive"][key] for key in ("tier", "job", "shard")),
                "UI archive summary is not bound")
        ui_inputs = record["ui_inputs"]["base"]
        require("error" not in ui_inputs and summary["hashes"]["manifests"] == {"ui-shards": ui_inputs["manifest_sha256"]},
                "UI archive manifest differs from admission")
        from ci_summary import test_identity
        population = summary["population"]
        expected = [test_identity("host", "UI archive selection")]
        require(population["declared"] == expected and population["compiled"] == expected
                and not population["deselected"] and not population["removed_by_pr"], "UI archive population differs")
        observed = population["observed"]
        require(len(observed) == 1 and observed[0]["identity"] == expected[0] and observed[0]["outcome"] == "failed"
                and len(observed[0]["attempts"]) == 1 and observed[0]["attempts"][0]["outcome"] == "failed"
                and observed[0]["attempts"][0]["exit_code"] == 1, "UI archive outcome differs")
        names = artifacts_by_job["ui-archive"]
        require(len(names) == 1, "unexpected UI archive artifacts")
        matches = [artifact for artifact in api.pages(f"actions/runs/{run['id']}/artifacts", "artifacts")
                   if artifact["name"] == names[0] and not artifact["expired"]]
        require(len(matches) == 1, "UI archive artifact unavailable or duplicated")
        refusals = json_member(api, matches[0], "archive-refusals.json", optional=True)
        require(refusals is None or refusals == [], "UI archive selection had refusals")
        gate_workflow = api.repo("actions/workflows/ci-gate.yml")
        candidates = api.pages(f"actions/workflows/{positive(gate_workflow['id'])}/runs", "workflow_runs",
                               head_sha=run["head_sha"], branch="main", event="push")
        gate = authoritative_run(candidates, run["head_sha"], gate_workflow, api.repository)
        return gate is not None and cancelled_unstarted_run(api, gate)
    except (ContractError, KeyError, ValueError, TypeError, zipfile.BadZipFile):
        return False


def approval_requests(api, pr):
    workflow = api.repo("actions/workflows/ci-approval.yml", missing=True)
    if workflow is None:
        return []
    requests = []
    pattern = re.compile(r"CI approval PR " + str(pr["number"]) + r" ([0-9a-f]{40})")
    for run in api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs", event="workflow_dispatch", branch="main"):
        match = pattern.fullmatch(run["display_title"])
        if match and run["path"] == APPROVAL_PATH:
            requests.append({"head_sha": match[1], "run_id": run["id"], "status": run["status"]})
    return requests


def compute(api, pr_number, pushed, login):
    pr = api.repo(f"pulls/{pr_number}") if pr_number else None
    require(not pr or (pr["state"] == "open" and pr["base"]["ref"] == "main"), "PR is closed or does not target main")
    head = pr["head"]["sha"] if pr else pushed
    sha(head)
    runs, evaluations = {}, {}
    for context, workflow in workflows(api).items():
        candidates = api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs",
                               head_sha=head, event="pull_request" if pr else "push")
        if pr:
            candidates = [run for run in candidates if (not run.get("pull_requests") or
                          any(p["number"] == pr_number for p in run["pull_requests"]))
                          and run["head_repository"]["full_name"] == pr["head"]["repo"]["full_name"]]
        runs[context] = authoritative_run(candidates, head, workflow, api.repository)
    not_evaluated = {context: {"state": "pending",
        "description": "Not evaluated: " + ("gate" if context == "ci-pr-gate" else "UI run") + " cancelled before any job executed",
        "target_url": f"https://github.com/{api.repository}/actions/runs/{run['id']}"}
        for context, run in runs.items() if not pr and run and cancelled_unstarted_run(api, run)}
    admissions = trusted_admissions(api, [run["id"] for context, run in runs.items() if run and context not in not_evaluated])
    approved = approved_status(api, pr, login) if pr else False
    records = [admissions[run["id"]] for run in runs.values() if run and run["id"] in admissions]
    classified = bool(records) and all(not run or run["id"] in admissions for run in runs.values())
    fork = bool(pr and pr["head"]["repo"]["full_name"] != api.repository)
    # Missing admission is pending, never success. Do not create an unnecessary
    # docs-only approval request while its classification is still being derived.
    needs_approval = bool(pr and (fork or any(r["classification"]["ci_changing"] for r in records)))
    for context, run in runs.items():
        if not run or run["id"] not in admissions or run["status"] != "completed":
            continue
        record = admissions[run["id"]]
        summaries = []
        diagnostic_errors = []
        try:
            require(record["workflow_id"] == run["workflow_id"] and record["workflow_path"] == run["path"], "admission producer mismatch")
            identity = record["identity"]
            require(identity["repository"] == api.repository and identity["event"] == ("pull_request" if pr else "push"), "admission source mismatch")
            require((identity["pull_request"] == pr_number and identity["head_sha"] == head) if pr else identity["pushed_sha"] == head,
                    "admission does not name current head")
            source = record["workflows"][run["path"]]["candidate" if approved else "base"]
            require(source is not None, "workflow is absent on the base; exact-head approval required")
            if context == "ci-ui":
                ui = record.get("ui_inputs", {}).get("candidate" if approved else "base")
                if ui is not None:
                    require("error" not in ui, ui.get("error", "candidate UI inputs are invalid"))
            cloud = None
            if context == "ci-ui" and pr and not fork:
                from ci_xcode_cloud_groups import skipped_groups, trusted_groups
                from ci_xcode_cloud import apple_tv_skip_names
                cloud_skips = apple_tv_skip_names(source, run)
                current_jobs = api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs")
                if ((ui or {}).get("selection") or {}).get("coverage") == "functional":
                    groups = skipped_groups(source, run, current_jobs, record, approved=approved)
                    if groups:
                        cloud = trusted_groups(api, record, run, groups, approved=approved)
                elif any(job["conclusion"] == "skipped" and job["name"] in cloud_skips for job in current_jobs):
                    from ci_xcode_cloud import trusted_cloud
                    cloud = trusted_cloud(api, record, run, approved=approved)
            jobs, summaries = producer_evidence(api, run, source, diagnostics=diagnostic_errors, admission=record, cloud=cloud)
            for summary in summaries:
                mismatch = match_producer(summary["identity"], identity)
                require(mismatch is None, mismatch or "identity mismatch")
            require(not diagnostic_errors, "missing or invalid artifact evidence")
            if context == "ci-ui" and not pr and archive_blocked_ui(api, record, run, jobs, summaries):
                not_evaluated[context] = {"state": "pending", "description": "Not evaluated: archive unavailable for unexecuted gate",
                    "target_url": f"https://github.com/{api.repository}/actions/runs/{run['id']}"}
                continue
            if context == "ci-ui" and not pr and any(job["conclusion"] == "skipped" for job in jobs):
                from ci_ui_reuse import evaluate_reused_push
                evaluations[context] = evaluate_reused_push(api, record, run, jobs, summaries)
            else:
                evaluations[context] = evaluate_records(record, run, jobs, summaries, approved=approved, fork=fork, cloud=cloud)
                if context == "ci-ui" and cloud is None:
                    from ci_ui_reuse import make_verdict
                    receipt = make_verdict(record, run, summaries, evaluations[context])
                    if receipt is not None:
                        evaluations[context]["reuse_verdict"] = receipt
            from ci_report import summary_diagnostics
            if cloud is not None:
                from ci_report import cloud_pr_diagnostics
                evaluations[context]["diagnostics"] = cloud_pr_diagnostics(summaries, cloud=cloud)
            else:
                evaluations[context]["diagnostics"] = summary_diagnostics(summaries, diagnostic_errors)
        except (ContractError, KeyError, ValueError, TypeError) as error:
            evaluations[context] = {"state": "failure", "description": ui_failure_hint(error) or
                                   "Missing, invalid or mismatched admitted evidence"}
            # The infrastructure advice is deterministic, without candidate text.
            if any(match_producer(s["identity"], record["identity"]) for s in summaries):
                previous = prior_mismatch(api.pages("commits/" + head + "/statuses"), run, login)
                evaluations[context]["description"] = "base moved; push again or update the branch" + (" (repeated across reruns)" if previous else "")
                evaluations[context]["mismatch"] = {"run_id": run["id"], "attempt": run["run_attempt"]}
        if "diagnostics" not in evaluations[context]:
            try:
                from ci_report import summary_diagnostics
                evaluations[context]["diagnostics"] = summary_diagnostics(summaries, diagnostic_errors)
            except (ContractError, KeyError, ValueError, TypeError):
                evaluations[context]["diagnostics"] = {"counts": {}, "failures": [], "missing": [],
                    "infrastructure": ["failure diagnostics unavailable"], "skipped": [], "deselected": []}
        evaluations[context]["report_source"] = {
            "repository": api.repository, "workflow_path": run["path"], "event": run["event"],
            "run_id": run["id"], "attempt": run["run_attempt"],
            "fork_originated": fork, "ci_changing": record["classification"]["ci_changing"],
            "approval_based": bool(approved and needs_approval)}
    if pr:
        plan = publication_plan(pr, runs, admissions, evaluations, approved=approved, needs_approval=needs_approval)
        # UI has not shipped yet. Docs-only changes may be independently shown as
        # not applicable, but unknown/CI changes never become green without it.
        if classified and not any(r["classification"]["app_affected"] for r in records) and (not needs_approval or approved):
            plan["ci-ui"] = {"state": "success", "description": "Not applicable: trusted classification cannot affect the app"}
            if fork:
                plan["ci-ui"]["description"] += "; self-reported; approval-based"
    else:
        synthetic = {"number": 1, "head": {"sha": head, "repo": {"full_name": api.repository}},
                     "base": {"repo": {"full_name": api.repository}}}
        plan = publication_plan(synthetic, runs, admissions, evaluations, approved=False, needs_approval=False)
        plan.update(not_evaluated)
        if classified and not any(r["classification"]["app_affected"] for r in records):
            plan["ci-ui"] = {"state": "success", "description": "Not applicable: trusted classification cannot affect the app"}
    if pr and not classified:
        plan["ci-approval-state"] = {"state": "pending", "description": "Waiting for trusted classification"}
    requests = approval_requests(api, pr) if pr else []
    current_request = next((request for request in requests if request["head_sha"] == head), None)
    if current_request:
        plan["ci-approval-state"]["target_url"] = f"https://github.com/{api.repository}/actions/runs/{current_request['run_id']}"
    return head, plan, approval_plan(pr, requests, approved=approved, needs_approval=needs_approval) if pr else None


def write_publication(api, app, pr_number, pushed, login, *, dry_run=False):
    # Serialize display publication per PR and re-read current state. Approval
    # records write independently, then dispatch a fresh publication.
    head, plan, approval = compute(api, pr_number, pushed, login)
    target = f"https://github.com/{api.repository}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"
    if dry_run:
        print(json.dumps({"head": head, "statuses": plan, "approval": approval, "writes": False}, indent=2))
        return
    if pr_number:
        require(api.repo(f"pulls/{pr_number}")["head"]["sha"] == head, "PR head changed before publication")
    receipt = plan.get("ci-ui", {}).get("reuse_verdict")
    if receipt is not None:
        directory = Path(os.environ["RUNNER_TEMP"], "ci-ui-verdict")
        directory.mkdir(mode=0o700, exist_ok=False)
        (directory / "verdict.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
            handle.write("ui_verdict_tree=" + receipt["identity"]["tree_sha"] + "\n")
    for context, status in plan.items():
        app.status(head, context, status["state"], status["description"], status.get("target_url", target))
        if status.get("mismatch"):
            mismatch = status["mismatch"]
            app.status(head, f"ci-base-mismatch/run-{mismatch['run_id']}/attempt-{mismatch['attempt']}",
                       "success", "Bookkeeping: mismatch recorded; not a test result", target)
    if approval:
        for run_id in approval["obsolete"]:
            api.repo(f"actions/runs/{run_id}/cancel", method="POST")
        request_context = f"ci-approval-request/pr-{pr_number}/{head}"
        statuses = api.pages("commits/" + head + "/statuses")
        reservation = next((s for s in statuses if s["context"] == request_context and s["creator"]["login"] == login), None)
        requests = approval_requests(api, {"number": pr_number})
        request = next((r for r in requests if r["head_sha"] == head), None)
        dispatched = False
        if approval["request"] and not request and (not reservation or reservation["state"] != "success"):
            app.status(head, request_context, "pending", "Bookkeeping: approval dispatch pending; not a test result", target)
            api.dispatch(APPROVAL_PATH, {"pull_request": str(pr_number), "head_sha": head})
            dispatched = True
            # The accepted receipt survives a delay before the new run becomes
            # visible. Pending receipts with no run are retried on publication.
            app.status(head, request_context, "success", "Bookkeeping: approval dispatch accepted; not a test result",
                       f"https://github.com/{api.repository}/actions/workflows/ci-approval.yml")
            for _ in range(10):
                requests = approval_requests(api, {"number": pr_number})
                request = next((r for r in requests if r["head_sha"] == head), None)
                if request:
                    break
                time.sleep(1)
        if request:
            approval_target = f"https://github.com/{api.repository}/actions/runs/{request['run_id']}"
            display = plan["ci-approval-state"]
            display["target_url"] = approval_target
            app.status(head, "ci-approval-state", display["state"], display["description"], approval_target)
            if reservation or dispatched:
                app.status(head, request_context, "success", "Bookkeeping: approval request created; not a test result", approval_target)
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a") as handle:
            handle.write("## Trusted CI publication\n\nInformational commit statuses; required promotion is a maintainer decision.\n\n")
            for context, status in plan.items():
                details = f" ([Details]({status['target_url']}))" if status.get("target_url") else ""
                handle.write(f"- {context}: {status['state']} — {status['description']}{details}\n")
                source = status.get("report_source") or status.get("source")
                if source:
                    handle.write(f"  Source: {source['repository']}, {source['workflow_path']}; run {source['run_id']}, attempt {source['attempt']}; "
                                 f"event: {source.get('event', 'unknown')}; CI-changing: {source.get('ci_changing')}; "
                                 f"approval-based: {source['approval_based']}, fork-originated: {source['fork_originated']}.\n")
                reuse = status.get("reuse")
                if reuse:
                    handle.write(f"  Reuse: producer run {reuse['producer_run_id']}, attempt {reuse['producer_attempt']}; "
                                 f"verdict artifact {reuse['verdict_artifact_id']}; tree {reuse['tree_sha']}; "
                                 f"approval-based: {reuse['approval_based']}, fork-originated: {reuse['fork_originated']}, "
                                 f"CI-changing: {reuse['ci_changing']}.\n")
                for population in status.get("population", []):
                    compiled = population["compiled"] if population["compiled"] is not None else "NOT_EXPOSED_BY_API"
                    handle.write(f"  {population['tier']} / {population['shard']}: expected {population['expected']}, "
                                 f"compiled {compiled}, observed {population['observed']}, "
                                 "per-job population.\n")
                cloud = status.get("xcode_cloud")
                if cloud:
                    proofs = cloud["groups"].values() if cloud.get("schema_version") == 2 else [cloud]
                    for proof in proofs:
                        links = proof["actions"] if cloud.get("schema_version") == 2 else [proof]
                        for action in links:
                            handle.write(f"  Xcode Cloud: [{proof['cloud_run_id']}]({action['details_url']}); "
                                         f"import artifact {proof['import_artifact_id']}; route artifact {proof['route_artifact_id']}; "
                                         f"wall {proof['wall_minutes']:.2f} min; compute {proof['compute_minutes']:.2f} min.\n")
                for skipped in status.get("not_applicable", []):
                    handle.write(f"  {skipped['job']}: not applicable; {len(skipped['identities'])} admitted identities; "
                                 "trusted PR classification cannot affect the app or CI tooling.\n")
                if status.get("source"):
                    handle.write(f"  Expected skips {len(status['expected_skips'])}, deselected {len(status['deselected'])}, "
                                 f"removed by PR {len(status['removed_by_pr'])}.\n")
                diagnostics = status.get("diagnostics")
                if diagnostics:
                    from ci_summary import markdown_text
                    handle.write("\n  Producer counts (admission/verdict acceptance is separate): " +
                                 "; ".join(f"{key} {value}" for key, value in sorted(diagnostics["counts"].items())) + ".\n")
                    for failure in diagnostics["failures"]:
                        handle.write("  Failed: " + markdown_text(failure["identity"]) +
                                     "; exit codes: " + str(failure["exit_codes"]) + ".\n")
                    for missing in diagnostics["missing"]:
                        handle.write("  Missing evidence: " + markdown_text(missing["identity"]) + "; " + missing["reason"] + ".\n")
                    for error in diagnostics["infrastructure"]:
                        handle.write("  Infrastructure: " + markdown_text(error) + ".\n")


def record_approval(api, app, event, environment, login, path):
    check_credential_context(environment, path)
    maintainer = api.repository.split("/")[0]
    if path == APPROVAL_PATH:
        reviews = api.repo(f"actions/runs/{positive(int(environment['GITHUB_RUN_ID']))}/approvals")
        require(any(review["state"] == "approved" and review["user"]["login"] == maintainer
                    and any(item["name"] == "ci-approval" for item in review["environments"]) for review in reviews),
                "maintainer environment approval is missing")
    else:
        require(environment.get("GITHUB_ACTOR") == maintainer and environment.get("GITHUB_TRIGGERING_ACTOR") == maintainer,
                "only the repository maintainer may use the approval fallback")
    inputs = event["inputs"]
    number, head = positive(int(inputs["pull_request"])), inputs["head_sha"]
    sha(head)
    pr = api.repo(f"pulls/{number}")
    require(pr["state"] == "open" and pr["base"]["ref"] == "main" and pr["head"]["sha"] == head, "approval request is obsolete")
    if not approved_status(api, pr, login):
        app.status(head, approval_context(number, head), "success", "Maintainer approved this exact PR head",
                   f"https://github.com/{api.repository}/actions/runs/{environment['GITHUB_RUN_ID']}")
    api.dispatch(PUBLISH_PATH, {"pull_request": str(number), "pushed_sha": ""})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("route", "admit", "reevaluate", "publish", "approve", "fallback", "dry-run"))
    parser.add_argument("--pr", type=int, default=0)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--app-login", default="")
    args = parser.parse_args()
    environment = os.environ
    api = GitHub(args.repository, environment.get("GH_TOKEN", environment.get("CI_WORKFLOW_TOKEN", "")))
    event = json.loads(Path(environment["GITHUB_EVENT_PATH"]).read_text()) if args.command != "dry-run" else {}
    try:
        if args.command == "dry-run":
            require(args.pr > 0 and bool(args.app_login), "dry-run requires --pr and --app-login")
            write_publication(api, None, args.pr, "", args.app_login, dry_run=True)
        elif args.command == "route":
            check_credential_context(environment, PUBLISH_PATH)
            values = route(api, event, environment)
            with open(environment["GITHUB_OUTPUT"], "a") as handle:
                for key, value in values.items():
                    handle.write(key + "=" + value + "\n")
        elif args.command == "admit":
            check_credential_context(environment, PUBLISH_PATH)
            record = admit(api, event)
            if record:
                directory = Path(environment["RUNNER_TEMP"], "ci-admission")
                directory.mkdir()
                (directory / "record.json").write_text(json.dumps(record))
                with open(environment["GITHUB_OUTPUT"], "a") as handle:
                    handle.write(f"recorded=true\nrun_id={record['run_id']}\n")
        elif args.command == "reevaluate":
            check_credential_context(environment, PUBLISH_PATH)
            values = route(api, event, environment)
            api.dispatch(PUBLISH_PATH, {"pull_request": values["pr"] if values["pr"] != "0" else "", "pushed_sha": values["pushed"]})
        else:
            path = APPROVAL_PATH if args.command == "approve" else APPROVE_PATH if args.command == "fallback" else PUBLISH_PATH
            app, login = mint_app(environment, path)
            try:
                if args.command in {"approve", "fallback"}:
                    record_approval(api, app, event, environment, login, path)
                else:
                    write_publication(api, app, int(environment["CI_PR_NUMBER"]), environment.get("CI_PUSHED_SHA", ""), login)
            finally:
                app.request("/installation/token", method="DELETE")
        return 0
    except (ContractError, KeyError, ValueError, TypeError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        detail = str(error) if isinstance(error, ContractError) else type(error).__name__
        print("Trusted publisher refused: " + detail)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
