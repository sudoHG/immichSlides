#!/usr/bin/env python3
"""Shared macOS host-check entry point for CI, agents and check_all.sh."""

from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from ci_summary import ContractError, observation, parse_identity, test_identity, write_summary

REPO_ROOT = Path(__file__).resolve().parent.parent
HOST_CHECKS = [
    ("swift-format lint", ["xcrun", "swift-format", "lint", "--strict", "--recursive", "--parallel",
                           "immichSlides", "immichSlidesTests", "immichSlidesUITests", "TestSupport"]),
    ("test conventions", [sys.executable, "scripts/check_test_conventions.py"]),
    ("release guards", [sys.executable, "scripts/check_release_guards.py"]),
    ("localization catalog", [sys.executable, "scripts/validate_localization_catalog.py"]),
    ("localization usage", [sys.executable, "scripts/scan_chinese_strings.py", "--limit", "20"]),
    ("Python test prerequisites", [sys.executable, "scripts/check_required_test_tools.py"]),
    ("python tests", [sys.executable, "-B", "scripts/run_python_tests.py"]),
]


def git(*args):
    return subprocess.check_output(["git", *args], cwd=REPO_ROOT, text=True, timeout=30).strip()


def run_identity(env):
    repository = env.get("GITHUB_REPOSITORY")
    if not repository:
        remote = git("remote", "get-url", "origin").removesuffix(".git")
        repository = remote.removeprefix("https://github.com/").removeprefix("git@github.com:")
    event = env.get("GITHUB_EVENT_NAME", "local")
    commit = git("rev-parse", "HEAD")
    identity = {"schema_version": 1, "event": event, "repository": repository,
                "tree_sha": git("rev-parse", "HEAD^{tree}")}
    if event == "pull_request":
        require_sha = env.get("GITHUB_SHA")
        if commit != require_sha:
            raise ContractError("checkout does not match GITHUB_SHA")
        parents = git("show", "-s", "--format=%P", commit).split()
        if len(parents) != 2:
            raise ContractError("pull request checkout must have exactly two merge parents")
        event_payload = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        identity.update(pull_request=event_payload["number"], merge_sha=commit, base_sha=parents[0], head_sha=parents[1])
    elif event == "push":
        if commit != env.get("GITHUB_SHA"):
            raise ContractError("checkout does not match pushed GITHUB_SHA")
        identity.update(ref=env.get("GITHUB_REF"), pushed_sha=commit)
    elif event == "local":
        identity.update(commit_sha=commit, dirty=bool(git("status", "--porcelain")))
    else:
        raise ContractError("host entry point supports local, pull_request and main push only")
    return parse_identity(identity)


def version(command):
    try:
        return subprocess.check_output(command, stderr=subprocess.STDOUT, text=True, timeout=30).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def toolchain():
    try:
        import PIL
        pillow = PIL.__version__
    except ImportError:
        pillow = None
    developer = os.environ.get("DEVELOPER_DIR") or version(["xcode-select", "-p"])
    xcode = None
    if developer:
        try:
            with (Path(developer).parent / "version.plist").open("rb") as handle:
                plist = plistlib.load(handle)
            xcode = f"{plist['CFBundleShortVersionString']} ({plist['ProductBuildVersion']})"
        except (OSError, KeyError, ValueError):
            pass
    return {"versions": {"macos": platform.mac_ver()[0], "python": platform.python_version(),
                         "swift": version(["swift", "--version"]), "xcode": xcode,
                         "pillow": pillow, "zstd": version(["zstd", "--version"])},
            "signing_mode": "not-applicable"}


def clean_environment():
    # Host checks never inherit server/test-runner configuration. No private file is read.
    return {key: value for key, value in os.environ.items()
            if not key.startswith(("IMMICH", "TEST_RUNNER_IMMICH", "SIMCTL_CHILD_IMMICH"))}


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except ProcessLookupError:
        pass
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def run_steps(steps, repo_root, output_dir, *, timeout_seconds=900):
    records, infrastructure = [], []
    deadline = time.monotonic() + timeout_seconds
    for name, command in steps:
        print(f"\n==> {name}", flush=True)
        started = time.monotonic()
        remaining = deadline - started
        code, outcome = None, "not-run"
        message = f"{name}: host-check time budget exhausted"
        process = None
        try:
            if remaining > 0:
                process = subprocess.Popen(command, cwd=repo_root, env=clean_environment(), start_new_session=True)
                code = process.wait(timeout=remaining)
                outcome = "passed" if code == 0 else "failed"
                message = None if code == 0 else f"{name}: exited {code}"
        except subprocess.TimeoutExpired:
            stop_group(process)
            code, outcome = 124, "timed-out"
            message = f"{name}: host-check time budget exhausted"
            infrastructure.append({"code": "step-timeout", "message": message})
            # Continue recording the remainder as not-run instead of dropping identities.
        except OSError as error:
            code, outcome = 127, "failed"
            message = f"{name}: cannot start ({type(error).__name__})"
            infrastructure.append({"code": "missing-tool", "message": message})
        except KeyboardInterrupt:
            if process:
                stop_group(process)
            outcome, message = "not-run", f"{name}: interrupted"
            deadline = 0
            infrastructure.append({"code": "interrupted", "message": message})
        elapsed = round(time.monotonic() - started, 6)
        records.append(observation(test_identity("host", name), outcome, elapsed, message=message, exit_code=code))
        print(f"{outcome.upper()}: {name}" + (f" (exit {code})" if code is not None else ""), flush=True)
    return records, infrastructure


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, help="Outside the repository; default is a new temporary directory")
    parser.add_argument("--timeout-seconds", type=float, default=900, help="Total host-check budget; default 900")
    parser.add_argument("--workflow-path", help="Workflow path recorded in CI source")
    args = parser.parse_args()
    if not 0 < args.timeout_seconds <= 1200:
        parser.error("--timeout-seconds must be in (0, 1200]")
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="immichslides-host-"))).resolve()
    if output == REPO_ROOT or REPO_ROOT in output.parents:
        parser.error("--output-dir must be outside the repository")
    output.mkdir(parents=True, exist_ok=True)
    for filename in ("python-results.json", "summary.json", "summary.md", "run-identity.json"):
        if (output / filename).exists():
            parser.error("--output-dir must not contain results of an earlier run")
    try:
        identity = run_identity(os.environ)
        is_ci = identity["event"] != "local"
        if is_ci and not args.workflow_path:
            parser.error("CI requires --workflow-path")
        fork = False
        if identity["event"] == "pull_request":
            event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
            fork = event["pull_request"]["head"]["repo"]["full_name"] != identity["repository"]
        summary = {"schema_version": 1, "identity": identity,
                   "source": {"repository": identity["repository"], "workflow_path": args.workflow_path,
                              "event": identity["event"], "fork_originated": fork, "ci_changing": None},
                   "run": {"id": os.environ.get("GITHUB_RUN_ID") if is_ci else None,
                           "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")) if is_ci else 1,
                           "tier": "host", "job": "host-checks", "shard": None},
                   "hashes": {"manifests": {}, "policies": {}}, "toolchain": toolchain(),
                   "population": {"declared": [test_identity("host", name) for name, _ in HOST_CHECKS],
                                  "compiled": [test_identity("host", name) for name, _ in HOST_CHECKS],
                                  "observed": [], "deselected": [], "removed_by_pr": []},
                   "infrastructure": [], "status": "unverified"}
        # An interrupted producer leaves a valid, explicitly unverified record.
        write_summary(summary, output)
        steps = [(name, command + (["--output", str(output / "python-results.json")] if name == "python tests" else []))
                 for name, command in HOST_CHECKS]
        records, infrastructure = run_steps(steps, REPO_ROOT, output, timeout_seconds=args.timeout_seconds)
        summary["population"]["observed"] = records
        summary["infrastructure"] = infrastructure
        try:
            python = json.loads((output / "python-results.json").read_text(encoding="utf-8"))
            summary["population"]["compiled"].extend(python["compiled"])
            summary["population"]["observed"].extend(python["observed"])
        except (OSError, ValueError, KeyError, TypeError):
            summary["infrastructure"].append({"code": "missing-python-results", "message": "Python result identities are missing or malformed"})
        summary["status"] = "passed" if not summary["infrastructure"] and all(
            entry["outcome"] == "passed" for entry in summary["population"]["observed"]) else "failed"
        write_summary(summary, output)
        print(f"\nRESULT: {summary['status'].upper()}\nSummary: {output / 'summary.json'}", flush=True)
        return 0 if summary["status"] == "passed" else 1
    except (ContractError, OSError, ValueError, KeyError) as error:
        print(f"FAIL: host-check record could not be produced: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
