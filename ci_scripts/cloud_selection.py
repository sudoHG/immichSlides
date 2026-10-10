#!/usr/bin/env python3
"""Credential-free bootstrap: load verified base code, treat the PR as Git data."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.request import HTTPRedirectHandler, Request, build_opener

REPOSITORY = "sudoHG/immichSlides"
ORIGIN = "https://api.github.com/repos/" + REPOSITORY + "/"
MODULES = ("ci_summary", "ci_xcode_cloud", "ci_xcode_cloud_groups", "ci_xcode_cloud_selection",
           "ci_population", "ui_test_inventory", "ci_ui_packing", "ci_ui_selection", "ci_ui_shards",
           "ci_ui_test_kinds", "ci_verdict")
PUBLISHER = ("sudohg-ci[bot]", 339382712)
MAX_BYTES = 16 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise ValueError("Cloud public API redirect refused")


def public_get(path):
    require(isinstance(path, str) and not path.startswith("/") and ".." not in path.split("/"), "invalid public API path")
    request = Request(ORIGIN + path, headers={"Accept": "application/vnd.github+json", "User-Agent": "immichSlides-Cloud-selection"})
    with build_opener(NoRedirect()).open(request, timeout=30) as response:
        raw = response.read(MAX_BYTES + 1)
    require(len(raw) <= MAX_BYTES, "Cloud public API response exceeds bound")
    return json.loads(raw)


def pages(path, collection=None, *, query=""):
    result = []
    for page in range(1, 101):
        value = public_get(path + "?per_page=100&page=" + str(page) + query)
        rows = value[collection] if collection else value
        require(isinstance(rows, list), "invalid public collection")
        result.extend(rows)
        if len(rows) < 100:
            return result
    raise ValueError("Cloud public API pagination exceeds bound")


def git(root, *arguments):
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"}
    value = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "fetch.recurseSubmodules=false",
                            "-C", str(root), *arguments], capture_output=True, env=environment, timeout=90)
    require(value.returncode == 0, "Cloud trusted Git object operation failed")
    require(len(value.stdout) <= MAX_BYTES, "Cloud Git object exceeds bound")
    return value.stdout.decode("utf-8").rstrip("\n")


def listing(root, revision):
    result = []
    for value in git(root, "ls-tree", "-rz", "--full-tree", revision).split("\0"):
        if value:
            metadata, path = value.split("\t", 1)
            mode, kind, digest = metadata.split()
            result.append({"mode": mode, "type": kind, "sha": digest, "path": path})
    return result


def pointer_for(statuses, head, *, workflow_id, registry_value):
    matches = []
    for status in statuses:
        if (status.get("creator", {}).get("login"), status.get("creator", {}).get("id")) != PUBLISHER:
            continue
        context = re.fullmatch(r"ci-xcc-selection/([1-9][0-9]*)/([1-9][0-9]*)/(ios|tvos)", status.get("context", ""))
        if context is None:
            continue
        registration = registry_value["groups"].get(context[3])
        if registration is None or registration["workflow_id"] != workflow_id:
            continue
        description = re.fullmatch(r"Selection only: ([0-9a-f]{40}) ([0-9a-f]{64})", status.get("description", ""))
        target = re.fullmatch(re.escape("https://github.com/" + REPOSITORY + "/commit/") + r"([0-9a-f]{40})",
                              status.get("target_url", ""))
        require(description is not None and target is not None and status["state"] == "success"
                and status.get("url") == ORIGIN + "statuses/" + head
                and type(status.get("id")) is int and status["id"] > 0, "Cloud pointer is malformed")
        matches.append((int(context[1]), int(context[2]), status["id"], context[3], description[1], description[2], target[1]))
    require(matches, "Cloud selection pointer is missing")
    return max(matches)


def bootstrap(root, environment):
    require(environment.get("CI_XCODE_CLOUD") == "TRUE" and environment.get("CI_XCODEBUILD_ACTION") == "build-for-testing"
            and environment.get("CI_START_CONDITION") in {"manual", "manual_rebuild"}, "Cloud selection requires manual build-for-testing")
    head = git(root, "rev-parse", "HEAD")
    require(re.fullmatch(r"[0-9a-f]{40}", head) is not None and environment.get("CI_COMMIT", "").lower() == head,
            "Cloud checkout differs from CI_COMMIT")
    statuses = pages("commits/" + head + "/statuses")
    # The pointer chooses a base, but it cannot authorize it. Fetch main from the
    # fixed public repository and prove ancestry before loading any base code.
    candidates = [status for status in statuses if status.get("creator", {}).get("login") == PUBLISHER[0]
                  and status.get("creator", {}).get("id") == PUBLISHER[1]
                  and re.fullmatch(r"ci-xcc-selection/[1-9][0-9]*/[1-9][0-9]*/(?:ios|tvos)", status.get("context", ""))]
    require(candidates, "Cloud selection pointer is missing")
    for candidate in candidates:
        require(re.fullmatch(r"Selection only: [0-9a-f]{40} [0-9a-f]{64}", candidate.get("description", "")) is not None,
                "Cloud pointer base is invalid")
    base = max(candidates, key=lambda row: row["id"])["description"].removeprefix("Selection only: ").split()[0]
    git(root, "fetch", "--no-tags", "https://github.com/" + REPOSITORY + ".git", "refs/heads/main")
    git(root, "merge-base", "--is-ancestor", base, "FETCH_HEAD")
    registration = json.loads(git(root, "show", base + ":scripts/ci-xcode-cloud-groups.json"))
    chosen = pointer_for(statuses, head, workflow_id=environment["CI_WORKFLOW_ID"].lower(), registry_value=registration)
    run_id, attempt, pointer_id, group, selected_base, digest, merge = chosen
    require(selected_base == base and registration.get("routing_enabled") is True, "Cloud registered base differs or routing is inactive")
    run = public_get("actions/runs/" + str(run_id))
    require(run["id"] == run_id and run["run_attempt"] == attempt and run["head_sha"] == head
            and run["event"] == "pull_request" and run["path"] == ".github/workflows/ci-ui.yml"
            and run["repository"]["full_name"] == run["head_repository"]["full_name"] == REPOSITORY
            and run["status"] != "completed", "Cloud producer is stale or untrusted")
    recent = pages("actions/workflows/" + str(run["workflow_id"]) + "/runs", "workflow_runs",
                   query="&event=pull_request&head_sha=" + head)
    require(max(row["id"] for row in recent if row["head_repository"]["full_name"] == REPOSITORY) == run_id,
            "Cloud producer is no longer authoritative")
    prs = pages("commits/" + head + "/pulls")
    prs = [pr for pr in prs if pr["state"] == "open" and pr["head"]["sha"] == head
           and pr["head"]["repo"]["full_name"] == REPOSITORY]
    require(len(prs) == 1, "Cloud head has no unique open maintainer PR")
    pr = public_get("pulls/" + str(prs[0]["number"]))
    require(pr["user"]["login"] == "sudoHG" and pr["user"]["id"] == 279902076
            and pr["base"]["ref"] == "main" and pr["base"]["sha"] == base
            and pr["merge_commit_sha"] == merge, "Cloud admission base or author changed")
    git(root, "fetch", "--no-tags", "https://github.com/" + REPOSITORY + ".git", merge)
    require(git(root, "rev-list", "--parents", "-n", "1", merge).split() == [merge, base, head],
            "Cloud admitted merge parents differ")
    tree = git(root, "rev-parse", head + "^{tree}")
    require(tree == git(root, "rev-parse", merge + "^{tree}"), "Cloud head differs from admitted merge tree")
    require(not git(root, "diff", "--name-only", "HEAD"), "Cloud checkout has tracked changes before plan generation")
    identity = {"schema_version": 1, "repository": REPOSITORY, "event": "pull_request", "pull_request": pr["number"],
                "base_sha": base, "head_sha": head, "merge_sha": merge, "tree_sha": tree}
    # Verify this entry point and all hooks before materializing executable code.
    head_listing, base_listing = listing(root, head), listing(root, base)
    hooks = [entry for entry in base_listing if entry["path"].startswith("ci_scripts/")]
    require({entry["path"] for entry in hooks} == {entry["path"] for entry in head_listing if entry["path"].startswith("ci_scripts/")},
            "Cloud hook population changed")
    for entry in hooks:
        require(entry["mode"] in {"100644", "100755"} and git(root, "show", base + ":" + entry["path"])
                == git(root, "show", head + ":" + entry["path"]), "Cloud bootstrap/hook differs from trusted base")
    with tempfile.TemporaryDirectory(prefix="immichslides-xcc-reader-") as directory:
        for module in MODULES:
            Path(directory, module + ".py").write_text(git(root, "show", base + ":scripts/" + module + ".py") + "\n", encoding="utf-8")
        sys.path.insert(0, directory)
        try:
            from ci_xcode_cloud_selection import recompute, runtime_plans
            import ci_xcode_cloud_groups as groups
            record = recompute(identity, run, pr["user"], listing=lambda revision: listing(root, revision),
                read_blob=lambda revision, path: subprocess.check_output(["git", "-C", str(root), "show", revision + ":" + path],
                    env={"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}, timeout=60).decode(),
                changed_paths=git(root, "diff", "--name-only", "--no-renames", base + "..." + head).splitlines(), head_tree=tree)
            descriptor = groups.selection(record, run, group, approved=False)
            require(groups.canonical_hash(descriptor) == digest, "Cloud recomputed selection differs from pointer")
            groups.validate_pointer(record, run, group, digest, pages("commits/" + head + "/statuses"), pointer_id=pointer_id)
            fresh = public_get("pulls/" + str(pr["number"]))
            fresh_run = public_get("actions/runs/" + str(run_id))
            require(fresh["head"]["sha"] == head and fresh["base"]["sha"] == base
                    and fresh["user"]["login"] == "sudoHG" and fresh["user"]["id"] == 279902076
                    and fresh_run["run_attempt"] == attempt and fresh_run["status"] != "completed", "Cloud head changed during selection")
            for path, plan in runtime_plans(record, descriptor).items():
                destination = root / path
                require(destination.is_file() and not destination.is_symlink(), "Cloud runtime plan is not a regular template")
                destination.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            print(f"Cloud trusted functional plan generated: {group}; producer {run_id}/{attempt}; selection {digest}")
        finally:
            sys.path.pop(0)


def main():
    try:
        bootstrap(Path(os.environ["CI_PRIMARY_REPOSITORY_PATH"]), os.environ)
        return 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        print("Cloud selection unavailable or untrusted; refusing template execution", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
