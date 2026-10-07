#!/usr/bin/env python3
"""Report missing pinned Xcode or announced removal, using default-branch code only."""
from __future__ import annotations

import json
import os
import plistlib
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from setup_ci_python import PINS_PATH, load_pins, verify_python


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
    return []


def version_tuple(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def announced_version_matches(pin_version, version, *, major_series):
    pinned = version_tuple(pin_version)
    if version.lower().endswith((".x", ".*")):
        prefix = tuple(int(part) for part in version.split(".")[:-1])
        return pinned[:len(prefix)] == prefix
    if major_series and "." not in version:
        return pinned[0] == int(version)
    return pinned == version_tuple(version)


def removal_announcements(pins, issues):
    findings = []
    runner = pins["runner"]
    pin_version = pins["xcode"]["version"]
    image_name = runner.replace("-", " ")
    for issue in issues:
        if "pull_request" in issue:
            continue
        body = issue.get("body") or ""
        # Checked images are authoritative; unchecked image mentions must not cause alerts.
        checked = re.findall(r"(?im)^\s*-\s*\[x\]\s*(.+)$", body)
        if checked:
            if not any(image_name in name.lower() for name in checked):
                continue
        elif runner not in body.lower() and image_name not in body.lower() and "all macos" not in body.lower():
            continue
        section = re.search(r"(?ims)^### Breaking changes\s*\n(.*?)(?=^### |\Z)", body)
        changes = section[1] if section else body.split("### Mitigation", 1)[0]
        title = issue["title"]
        # An Xcode runner label in another tool's title is not an Xcode removal.
        title_is_xcode_change = re.match(r"(?:\[[^]]+\]\s*)?(?:Xcode\b|(?:remov\w*|drop\w*|deprecat\w*)\s+(?:of\s+)?Xcode\b)", title, re.I)
        text = (title + "\n" if title_is_xcode_change else "") + changes
        sentences = re.split(r"\n|(?<=[.!?])\s+(?=[A-Z])", text.replace("`", "").replace("**", ""))
        for sentence in sentences:
            if not re.search(r"\b(remov\w*|drop\w*|deprecat\w*|unsupported|no longer|replac\w*)\b", sentence, re.I):
                continue
            if re.search(r"\b(remain\w*|keep\w*|not remov\w*|not drop\w*|does not remov\w*)\b", sentence, re.I):
                continue
            floor = re.search(r"Xcode (?:versions? )?(?:older than|below|before|less than) (\d+(?:\.\d+){0,2})", sentence, re.I)
            version_pattern = r"\d+(?:\.\d+){0,2}(?:\.[xX*])?"
            separator = r"(?:\s*,?\s*(?:and|&)\s*|\s*,\s*)"
            subjects = re.finditer(
                r"\b(?:(all)\s+)?Xcode\s+(?:versions?\s+)?(" + version_pattern +
                r"(?:" + separator + version_pattern + r")*)(?:\s+(?:major\s+)?(series|versions))?",
                re.split(r"\b(?:by|with)\b", sentence, maxsplit=1)[0], re.I)
            affected = any(announced_version_matches(pin_version, value,
                major_series=subject[1] is not None or subject[3] is not None)
                for subject in subjects for value in re.findall(version_pattern, subject[2]))
            if floor:
                affected = version_tuple(pin_version) < version_tuple(floor[1])
            if affected:
                findings.append("Announced pinned Xcode removal: " + issue["html_url"])
                break
    return findings


def issue_marker(pins, simulated):
    pin = pins["xcode"]
    mode = "simulation" if simulated else "inventory"
    return f"<!-- ci-probe:{mode}:{pins['runner']}:{pin['version']}:{pin['build']} -->"


def report_findings(api, repository, pins, findings, run_url, *, simulated=False):
    if not findings:
        return {"action": "quiet"}
    marker = issue_marker(pins, simulated)
    prefix = "[SIMULATION] " if simulated else ""
    pin = pins["xcode"]
    title = f"{prefix}CI toolchain: Xcode {pin['version']} ({pin['build']}) on {pins['runner']} needs attention"
    body = "\n".join([marker, "", "The pinned CI toolchain needs maintainer attention.", "",
        f"Runner: `{pins['runner']}`. Xcode pin: `{pin['version']}` / `{pin['build']}`.",
        f"Developer directory: `{pin['developer_dir']}`.", "", *["- " + finding for finding in findings], "",
        f"Latest probe: {run_url}", "",
        "Review the runner-image announcement and update scripts/ci-pins.json intentionally; no alternate Xcode was selected.",
        "This issue is updated by ci-probe and is never closed automatically.",
        "Simulation only: close this test issue after checking the run." if simulated else "",
    ])
    matches = [issue for issue in api.pages(f"repos/{repository}/issues", {"state": "open", "creator": "github-actions[bot]"})
               if "pull_request" not in issue and marker in (issue.get("body") or "")
               and issue["user"]["login"] == "github-actions[bot]"]
    if len(matches) > 1:
        raise ValueError("Multiple open ci-probe issues match this pin; refusing an ambiguous update")
    if matches:
        issue = api.request("PATCH", f"repos/{repository}/issues/{matches[0]['number']}", {"title": title, "body": body})
        return {"action": "updated", "issue": issue["html_url"]}
    issue = api.request("POST", f"repos/{repository}/issues", {"title": title, "body": body})
    return {"action": "opened", "issue": issue["html_url"]}


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
        announcements = GitHubAPI().pages(UPSTREAM, {"state": "open", "labels": "Announcement"})
        findings.extend(removal_announcements(pins, announcements))
        run_url = f"https://github.com/{repository}/actions/runs/{os.environ['GITHUB_RUN_ID']}/attempts/{os.environ['GITHUB_RUN_ATTEMPT']}"
        outcome = report_findings(api, repository, pins, findings, run_url, simulated=simulation == "true")
        summary = "ci-probe: " + json.dumps(outcome, sort_keys=True)
        print(summary)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as output:
                output.write(summary + "\n")
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Never echo HTTP bodies, headers or ambient configuration.
        print(f"ci-probe FAIL: {type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
