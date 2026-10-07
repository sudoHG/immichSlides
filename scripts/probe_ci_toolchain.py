#!/usr/bin/env python3
"""Report pinned inventory failures and possible upstream changes using trusted code."""
from __future__ import annotations

import base64
import json
import os
import plistlib
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from setup_ci_python import PINS_PATH, load_pins, run, verify_python


PROBE_PATH = ".github/workflows/ci-probe.yml"
UPSTREAM = "repos/actions/runner-images/issues"


class GitHubAPI:
    def __init__(self, token=None):
        self.token = token

    def request(self, method, path, payload=None):
        headers = {"Accept": "application/vnd.github+json", "Content-Type": "application/json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "immichSlides-ci-probe"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request("https://api.github.com/" + path, method=method,
            data=None if payload is None else json.dumps(payload).encode("utf-8"), headers=headers)
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def pages(self, path, query):
        collected = []
        for page in range(1, 21):
            rows = self.request("GET", path + "?" + urllib.parse.urlencode(dict(query, per_page=100, page=page)))
            if not isinstance(rows, list):
                raise ValueError("Expected a paginated GitHub list")
            collected.extend(rows)
            if len(rows) < 100:
                return collected
        raise ValueError("GitHub pagination limit reached; refusing an incomplete probe")


def validate_context(environment, event):
    repository = event["repository"]
    name = repository["full_name"]
    branch = repository["default_branch"]
    expected_ref = "refs/heads/" + branch
    if (environment.get("GITHUB_REPOSITORY") != name or environment.get("GITHUB_REF") != expected_ref
            or environment.get("GITHUB_WORKFLOW_REF") != f"{name}/{PROBE_PATH}@{expected_ref}"
            or environment.get("GITHUB_EVENT_NAME") not in {"schedule", "workflow_dispatch"}):
        raise ValueError("ci-probe requires its own workflow on the default branch, on schedule or manual dispatch")
    if (environment["GITHUB_EVENT_NAME"] == "workflow_dispatch"
            and environment.get("GITHUB_ACTOR") != repository["owner"]["login"]):
        raise ValueError("Manual ci-probe dispatch requires the repository owner")
    return name


def inventory_findings(pins):
    pin = pins["xcode"]
    developer = Path(pin["developer_dir"])
    if not developer.is_dir():
        return [f"Pinned Xcode developer directory is missing: `{developer}`"]
    try:
        metadata = plistlib.loads((developer.parent / "version.plist").read_bytes())
        observed = (metadata["CFBundleShortVersionString"], metadata["ProductBuildVersion"])
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
        return ["Pinned Xcode version metadata is missing or unreadable."]
    expected = (pin["version"], pin["build"])
    if observed != expected:
        return [f"Pinned Xcode version/build mismatch: expected `{expected}`, observed `{observed}`."]
    environment = dict(os.environ, DEVELOPER_DIR=pin["developer_dir"])
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "--json"], env=environment))["runtimes"]
    findings = []
    for platform, runtime_pin in pins["simulators"].items():
        matches = [runtime for runtime in runtimes if runtime["identifier"] == runtime_pin["runtime"]
                   and runtime.get("isAvailable") and runtime["version"] == runtime_pin["version"]
                   and runtime["buildversion"] == runtime_pin["build"]]
        if len(matches) != 1:
            findings.append(f"Pinned {platform} runtime is missing, unavailable or mismatched: "
                            f"`{runtime_pin['runtime']}` / `{runtime_pin['version']}` / `{runtime_pin['build']}`.")
    return findings


def possible_announcements(pins, issues):
    findings = []
    major = pins["xcode"]["version"].split(".")[0]
    for issue in issues:
        if ("pull_request" in issue or issue["state"] != "open"
                or not any(label["name"] == "Announcement" for label in issue["labels"])):
            continue
        text = issue["title"] + "\n" + (issue.get("body") or "")
        # Co-occurrence only: beta/runtime/retained versions and other images also warn.
        if re.search("xcode", text, re.I) and re.search(r"(?<!\d)" + re.escape(major) + r"(?!\d)", text):
            findings.append("Announcement mentions Xcode and the pinned major: " + issue["html_url"])
    return findings


def toolset_findings(pins, api):
    image = pins["runner"].removeprefix("macos-")
    path = f"images/macos/toolsets/toolset-{image}.json"
    response = api.request("GET", f"repos/actions/runner-images/contents/{path}?ref=main")
    if response["encoding"] != "base64":
        raise ValueError("Expected base64 upstream toolset content")
    toolset = json.loads(base64.b64decode("".join(response["content"].split()), validate=True))
    expected = pins["xcode"]["version"] + "+" + pins["xcode"]["build"]
    versions = toolset["xcode"]["arm64"]["versions"]
    if any(version["version"] == expected for version in versions):
        return []
    # Source build configuration is an early warning, never deployed-runner inventory.
    return [f"Upstream arm64 toolset does not list `{expected}`: {response['html_url']}"]


def issue_marker(pins, signal, simulated):
    pin = pins["xcode"]
    if signal == "possible":
        return f"<!-- ci-probe:possible:{pins['runner']}:{pin['version'].split('.')[0]} -->"
    mode = "simulation" if simulated else "inventory"
    return f"<!-- ci-probe:{mode}:{pins['runner']}:{pin['version']}:{pin['build']} -->"


def report_findings(api, repository, pins, findings, run_url, *, signal="missing", simulated=False):
    if signal not in {"missing", "possible"} or (simulated and signal != "missing"):
        raise ValueError("Simulation is available only for the missing-inventory signal")
    if not findings:
        return {"action": "quiet"}
    marker = issue_marker(pins, signal, simulated)
    prefix = "[SIMULATION] " if simulated else ""
    pin = pins["xcode"]
    if signal == "missing":
        title = f"{prefix}CI: pinned toolchain missing - Xcode {pin['version']} ({pin['build']}) on {pins['runner']}"
        description = ("Simulation only: the pinned toolchain is treated as missing; this does not establish a runner failure."
                       if simulated else
                       "High-confidence inventory finding: the runner cannot satisfy the pinned Xcode/runtime toolchain.")
    else:
        title = f"CI: possible toolchain change - please check - Xcode {pin['version'].split('.')[0]} on {pins['runner']}"
        description = ("Early warning only: review the matched upstream sources below. This does not establish removal "
                       "of the pinned toolchain. Beta/runtime changes, other images and retained versions also warn; "
                       "false positives are intentional.")
    body = "\n".join([marker, "", description, "",
        f"Runner: `{pins['runner']}`. Xcode pin: `{pin['version']}` / `{pin['build']}`.",
        f"Developer directory: `{pin['developer_dir']}`.", "", *["- " + finding for finding in findings], "",
        f"Latest probe: {run_url}", "",
        "Review the inventory and upstream sources; update scripts/ci-pins.json intentionally if needed. No alternate Xcode was selected.",
        "This issue is updated by ci-probe and is never closed automatically.",
        "Simulation only: close this test issue after checking the run." if simulated else "",
    ])
    matches = [issue for issue in api.pages(f"repos/{repository}/issues", {"state": "open", "creator": "github-actions[bot]"})
               if "pull_request" not in issue and marker in (issue.get("body") or "")
               and issue["user"]["login"] == "github-actions[bot]"]
    if len(matches) > 1:
        raise ValueError("Multiple open ci-probe issues match this signal; refusing an ambiguous update")
    if matches:
        issue = api.request("PATCH", f"repos/{repository}/issues/{matches[0]['number']}", {"title": title, "body": body})
        return {"action": "updated", "issue": issue["html_url"]}
    issue = api.request("POST", f"repos/{repository}/issues", {"title": title, "body": body})
    return {"action": "opened", "issue": issue["html_url"]}


def summarize(signal, outcome):
    summary = "ci-probe: " + json.dumps({"signal": signal, **outcome}, sort_keys=True)
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as output:
            output.write(summary + "\n")


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        repository = validate_context(os.environ, event)
        pins = load_pins(PINS_PATH)
        verify_python(sys.executable, pins["python"])
        simulation = os.environ.get("CI_PROBE_SIMULATE_MISSING_PIN", "false")
        if simulation not in {"true", "false"} or (simulation == "true" and os.environ["GITHUB_EVENT_NAME"] != "workflow_dispatch"):
            raise ValueError("Missing-pin simulation is a boolean available only on manual dispatch")
        # Validate provenance before reading the issue-write token.
        token = os.environ["CI_PROBE_TOKEN"]
        if not token:
            raise ValueError("Missing ci-probe GITHUB_TOKEN")
        api = GitHubAPI(token)
        findings = inventory_findings(pins)
        if simulation == "true":
            findings.append("SIMULATION: the pinned Xcode is treated as missing; installed tools and pins were not changed.")
        run_url = f"https://github.com/{repository}/actions/runs/{os.environ['GITHUB_RUN_ID']}/attempts/{os.environ['GITHUB_RUN_ATTEMPT']}"
        # Publish confirmed inventory failures before attempting any upstream reads.
        summarize("missing", report_findings(api, repository, pins, findings, run_url, simulated=simulation == "true"))
        upstream = GitHubAPI()
        possible = toolset_findings(pins, upstream)
        announcements = upstream.pages(UPSTREAM, {"state": "open", "labels": "Announcement"})
        possible.extend(possible_announcements(pins, announcements))
        summarize("possible", report_findings(api, repository, pins, possible, run_url, signal="possible"))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Never echo HTTP bodies, headers or ambient configuration.
        print(f"ci-probe FAIL: {type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
