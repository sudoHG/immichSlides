#!/usr/bin/env python3
"""Shared macOS host-check entry point for CI, agents and check_all.sh."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import platform
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

from ci_summary import (ContractError, identity_key, observation, parse_identity, parse_summary,
                        render_markdown, test_identity, validate_observation, validate_test_identity, write_summary)

REPO_ROOT = Path(__file__).resolve().parent.parent
GROUP_TERM_GRACE_SECONDS = 5
HOST_CHECKS = [
    ("swift-format lint", ["xcrun", "swift-format", "lint", "--strict", "--recursive", "--parallel",
                           "immichSlides", "immichSlidesTests", "immichSlidesUITests", "TestSupport"]),
    ("test conventions", [sys.executable, "scripts/check_test_conventions.py"]),
    ("release guards", [sys.executable, "scripts/check_release_guards.py"]),
    ("localization catalog", [sys.executable, "scripts/validate_localization_catalog.py"]),
    ("localization usage", [sys.executable, "scripts/scan_chinese_strings.py", "--limit", "20"]),
    ("Python test prerequisites", [sys.executable, "scripts/check_required_test_tools.py"]),
    ("workflow policy", [sys.executable, "scripts/check_workflow_policy.py", "--check-ui-shards"]),
    ("known-flaky registry", [sys.executable, "scripts/ci_flaky.py"]),
    ("Xcode Cloud UI contract", [sys.executable, "scripts/check_xcode_cloud_ui.py"]),
    ("python tests", [sys.executable, "-B", "scripts/run_python_tests.py"]),
]
MACOS_PYTHON_TESTS = frozenset({
    "test_strict_e2e_filter_contract.DisplayPolicyVisualContractTests.test_swift_capture_candidate_recognizes_public_fit_without_rewriting_evidence",
    "test_strict_e2e_photo_identity.IOSVisualIdentityJSONEncodingTests.test_nil_mark_is_valid_json_object",
})


def host_partition(population, scope):
    """Split admitted identities using base-owned macOS requirements, never producer exclusions."""
    if scope not in {"linux", "macos"}:
        raise ContractError("unknown host platform partition")
    keys = set()
    for entry in population:
        validate_test_identity(entry)
        if entry["kind"] not in {"host", "python"} or identity_key(entry) in keys:
            raise ContractError("invalid or duplicate host partition identity")
        keys.add(identity_key(entry))
    if {entry["key"] for entry in population if entry["kind"] == "host"} != {name for name, _ in HOST_CHECKS}:
        raise ContractError("host partition checks differ from the complete host inventory")
    def needs_macos(entry):
        return (entry["kind"] == "host" and entry["key"] == "swift-format lint"
                or entry["kind"] == "python" and entry["key"] in MACOS_PYTHON_TESTS)
    return sorted([entry for entry in population if needs_macos(entry) == (scope == "macos")], key=identity_key)


def git(*args):
    return subprocess.check_output(["git", *args], cwd=REPO_ROOT, text=True,
                                   stderr=subprocess.DEVNULL, timeout=30).strip()


def local_repository():
    try:
        remote = git("remote", "get-url", "origin").rstrip("/").removesuffix(".git")
        parsed = urlsplit(remote)
        if parsed.scheme in {"https", "ssh"} and parsed.hostname:
            repository = parsed.path.lstrip("/")
        else:
            match = re.fullmatch(r"[^/:]+(?:@[^/:]+)?:([\w.-]+/[\w.-]+)", remote)
            repository = match[1] if match else None
        return repository if repository and re.fullmatch(r"[\w.-]+/[\w.-]+", repository) else None
    except (ValueError, subprocess.SubprocessError):
        # A local clone need not have a GitHub origin to run checks.
        return None


def run_identity(env, *, ci=False):
    event = env.get("GITHUB_EVENT_NAME") if ci else "local"
    repository = local_repository() if event == "local" else env.get("GITHUB_REPOSITORY")
    commit = git("rev-parse", "HEAD")
    identity = {"schema_version": 1, "event": event, "repository": repository,
                "tree_sha": git("rev-parse", "HEAD^{tree}")}
    if event == "pull_request":
        require_sha = env.get("GITHUB_SHA")
        if commit != require_sha:
            raise ContractError("checkout does not match GITHUB_SHA")
        # Raw headers preserve parent IDs even in the sibling workflow's shallow checkout.
        headers = git("cat-file", "commit", commit).partition("\n\n")[0]
        parents = [line[7:] for line in headers.splitlines() if line.startswith("parent ")]
        if len(parents) != 2:
            raise ContractError("pull request checkout must have exactly two merge parents")
        event_payload = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        identity.update(pull_request=event_payload["number"], merge_sha=commit, base_sha=parents[0], head_sha=parents[1])
    elif event == "push":
        if commit != env.get("GITHUB_SHA"):
            raise ContractError("checkout does not match pushed GITHUB_SHA")
        identity.update(ref=env.get("GITHUB_REF"), pushed_sha=commit)
    elif event in {"workflow_dispatch", "schedule"}:
        if commit != env.get("GITHUB_SHA"):
            raise ContractError("checkout does not match dispatched GITHUB_SHA")
        identity.update(ref=env.get("GITHUB_REF"), commit_sha=commit)
    elif event == "local":
        identity.update(commit_sha=commit, dirty=bool(git("status", "--porcelain")))
    else:
        raise ContractError("CI identity supports pull_request, main push, schedule and workflow_dispatch only")
    return parse_identity(identity)


def source_metadata(identity, env, requested_workflow):
    if identity["event"] == "local":
        if requested_workflow is not None:
            raise ContractError("local source does not have a workflow path")
        return None, False
    path, separator, ref = env.get("GITHUB_WORKFLOW_REF", "").rpartition("@")
    prefix = identity["repository"] + "/"
    if not separator or not ref or not path.startswith(prefix):
        raise ContractError("GITHUB_WORKFLOW_REF does not identify this repository's workflow")
    workflow = path[len(prefix):]
    if not workflow.startswith(".github/workflows/") or (requested_workflow and requested_workflow != workflow):
        raise ContractError("--workflow-path does not match GITHUB_WORKFLOW_REF")
    fork = False
    if identity["event"] == "pull_request":
        event = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        head_repo = event["pull_request"]["head"]["repo"]
        # GitHub emits null when a fork was deleted; it cannot prove same-repository origin.
        fork = head_repo is None or head_repo["full_name"] != identity["repository"]
    return workflow, fork


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
    # Host checks never inherit server/test-runner or external calibration inputs.
    return {key: value for key, value in os.environ.items()
            if not key.startswith(("IMMICH", "TEST_RUNNER_IMMICH", "SIMCTL_CHILD_IMMICH"))
            and key != "STRICT_E2E_REVIEWED_SCREENSHOTS"}


def group_has_live_members(group_id):
    # killpg(..., 0) can return EPERM for an adopted zombie on macOS.
    targeted = sys.platform == "darwin"
    command = (["ps", "-g", str(group_id), "-o", "pgid=,stat="] if targeted
               else ["ps", "-axo", "pgid=,stat="])
    try:
        # Bound the probe to the runner's group without querying every simulator process.
        states = subprocess.check_output(command, text=True, timeout=5, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        # macOS ps reports an absent selected group with empty output and exit 1.
        if targeted and error.returncode == 1 and error.output == "" and error.stderr == "":
            return False
        raise
    return any(parts[0] == str(group_id) and not parts[1].startswith("Z")
               for line in states.splitlines() if len(parts := line.split()) == 2)


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    except PermissionError:
        if group_has_live_members(process.pid):
            raise
        process.wait()
        return
    deadline = time.monotonic() + GROUP_TERM_GRACE_SECONDS
    while True:
        process.poll()  # Reap the parent without mistaking its exit for the whole group's exit.
        if not group_has_live_members(process.pid):
            break
        if time.monotonic() >= deadline:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                if group_has_live_members(process.pid):
                    raise
            break
        time.sleep(0.05)
    process.wait()


def run_steps(steps, repo_root, *, timeout_seconds=900):
    records, infrastructure = [], []
    deadline = time.monotonic() + timeout_seconds
    interrupted = False
    for name, command in steps:
        print(f"\n==> {name}", flush=True)
        started = time.monotonic()
        remaining = deadline - started
        code, outcome = None, "not-run"
        message = f"{name}: not run after interruption" if interrupted else f"{name}: host-check time budget exhausted"
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
            interrupted = True
            deadline = 0
            infrastructure.append({"code": "interrupted", "message": message})
        elapsed = round(time.monotonic() - started, 6)
        records.append(observation(test_identity("host", name), outcome, elapsed, message=message, exit_code=code))
        print(f"{outcome.upper()}: {name}" + (f" (exit {code})" if code is not None else ""), flush=True)
    return records, infrastructure


def failed_record(initial, current, error):
    # A malformed producer result must not leave the earlier empty placeholder.
    fallback = copy.deepcopy(initial)
    fallback["status"] = "failed"
    for collection in ("compiled", "observed"):
        seen = {identity_key(entry) for entry in fallback["population"][collection]}
        for entry in current["population"][collection]:
            try:
                if collection == "observed":
                    validate_observation(entry)
                    identity = entry["identity"]
                else:
                    validate_test_identity(entry)
                    identity = entry
                token = identity_key(identity)
            except (ContractError, TypeError, ValueError, KeyError):
                continue
            if token not in seen:
                fallback["population"][collection].append(copy.deepcopy(entry))
                seen.add(token)
    for entry in current["infrastructure"]:
        candidate = dict(initial, infrastructure=[entry])
        try:
            parse_summary(candidate)
        except (ContractError, TypeError, ValueError, KeyError):
            continue
        fallback["infrastructure"].append(copy.deepcopy(entry))
    lines = str(error).splitlines()
    fallback["infrastructure"].append({"code": "record-invalid", "message":
        f"{type(error).__name__}: {lines[0][:200] if lines else 'No error detail provided'}"})
    return fallback


def print_result(summary, output, hide_path):
    print("\n" + render_markdown(summary), end="", flush=True)
    print(f"\nRESULT: {summary['status'].upper()}", flush=True)
    if not hide_path:
        print(f"Summary: {output / 'summary.json'}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        'Invoke with "${PYTHON:-python3}"; every Python check uses that interpreter, '
        'honoring an active venv or pyenv when PYTHON is unset.'))
    parser.add_argument("--output-dir", type=Path, help="Outside the repository; default is a new temporary directory")
    parser.add_argument("--timeout-seconds", type=float, default=900, help="Total host-check budget; default 900")
    parser.add_argument("--workflow-path", help="Enable CI identity; assert this path against GITHUB_WORKFLOW_REF. Omit for local identity, regardless of CI environment")
    parser.add_argument("--no-summary-path", action="store_true", help="Suppress the record path in the final report")
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
    initial = None
    try:
        identity = run_identity(os.environ, ci=args.workflow_path is not None)
        is_ci = identity["event"] != "local"
        workflow_path, fork = source_metadata(identity, os.environ, args.workflow_path)
        print(f"Python interpreter: {sys.executable} ({platform.python_version()})", flush=True)
        policy_path = REPO_ROOT / "scripts/ci-test-policy.json"
        declared = [test_identity("host", name) for name, _ in HOST_CHECKS]
        summary = {"schema_version": 1, "identity": identity,
                   "source": {"repository": identity["repository"], "workflow_path": workflow_path,
                              "event": identity["event"], "fork_originated": fork, "ci_changing": None},
                   "run": {"id": os.environ.get("GITHUB_RUN_ID") if is_ci else None,
                           "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")) if is_ci else 1,
                           "tier": "host", "job": "host-checks", "shard": None},
                   "hashes": {
                       "manifests": {"ci-pins": hashlib.sha256((REPO_ROOT / "scripts/ci-pins.json").read_bytes()).hexdigest()}
                       if is_ci else {},
                       "policies": {"workflow-policy": hashlib.sha256(
                           (REPO_ROOT / "scripts/check_workflow_policy.py").read_bytes()).hexdigest()}},
                   "toolchain": toolchain(),
                   "population": {"declared": declared,
                                  "compiled": [test_identity("host", name) for name, _ in HOST_CHECKS],
                                  "observed": [], "deselected": [], "removed_by_pr": []},
                   "infrastructure": [], "status": "unverified"}
        # An interrupted producer leaves a valid, explicitly unverified record.
        write_summary(summary, output)
        initial = copy.deepcopy(summary)
        # A broken candidate inventory or policy must not suppress the host checks
        # or prevent their results from replacing the interruption placeholder.
        policy = None
        try:
            # Archive consumers import metadata helpers without the host libraries.
            from ci_verdict import evaluate_population, expected_skip_verdict, identity_label, parse_policy, tier_approved

            policy_bytes = policy_path.read_bytes()
            summary["hashes"]["policies"]["test-policy"] = hashlib.sha256(policy_bytes).hexdigest()
            policy = parse_policy(policy_bytes.decode("utf-8"))
        except (ContractError, ImportError, OSError, ValueError, TypeError) as error:
            summary["infrastructure"].append({"code": "population-invalid", "message": f"Test policy: {error}"})
        try:
            from ci_population import python_identities, python_sources

            declared.extend(python_identities(python_sources(REPO_ROOT / "scripts")))
        except (ContractError, ImportError, OSError, ValueError, TypeError) as error:
            summary["infrastructure"].append({"code": "population-invalid", "message": f"Static inventory: {error}"})
        steps = [(name, command + (["--output", str(output / "python-results.json")] if name == "python tests" else []))
                 for name, command in HOST_CHECKS]
        records, infrastructure = run_steps(steps, REPO_ROOT, timeout_seconds=args.timeout_seconds)
        summary["population"]["observed"] = list(records)
        summary["infrastructure"].extend(infrastructure)
        try:
            python = json.loads((output / "python-results.json").read_text(encoding="utf-8"))
            summary["population"]["compiled"].extend(python["compiled"])
            summary["population"]["observed"].extend(python["observed"])
        except (OSError, ValueError, KeyError, TypeError):
            summary["infrastructure"].append({"code": "missing-python-results", "message": "Python result identities are missing or malformed"})
        command_passed = not summary["infrastructure"] and all(entry["outcome"] == "passed" for entry in records)
        # Coverage is evaluated separately from command success. Candidate policy
        # consumption here is informational; a trusted gate selects its own policy.
        summary["status"] = "passed" if command_passed else "failed"
        if command_passed:
            coverage = evaluate_population(summary, declared, policy, environment="hermetic")
            skipped = [entry for entry in summary["population"]["observed"] if entry["outcome"] == "skipped"]
            proposed_skips_only = (bool(skipped) and coverage["errors"] == [
                "skipped: " + identity_label(entry["identity"]) for entry in skipped] and all(
                    expected_skip_verdict(entry, policy["expected_skips"], tier="host", environment="hermetic") ==
                    ((True, None) if entry["outcome"] == "skipped" else (False, None))
                    for entry in summary["population"]["observed"]))
            if not tier_approved(policy, "host") and proposed_skips_only:
                summary["status"] = "unverified"
                summary["infrastructure"].append({"code": "policy-proposed", "message":
                    "Only proposed exceptions explain coverage; maintainer approval is still required"})
            else:
                summary["status"] = coverage["status"]
                summary["infrastructure"].extend({"code": "coverage-failed", "message": message} for message in coverage["errors"])
        write_summary(summary, output)
        print_result(summary, output, args.no_summary_path)
        return 0 if command_passed and summary["status"] != "failed" else 1
    except (subprocess.SubprocessError, ContractError, OSError, ValueError, KeyError, TypeError) as error:
        message = f"Git metadata command failed ({type(error).__name__})" if isinstance(error, subprocess.SubprocessError) else str(error)
        print(f"FAIL: host-check record could not be produced: {message}", file=sys.stderr)
        if initial is not None:
            try:
                fallback = failed_record(initial, summary, error)
                write_summary(fallback, output)
                print_result(fallback, output, args.no_summary_path)
            except (ContractError, OSError, ValueError, KeyError, TypeError) as recovery_error:
                print(f"FAIL: failed record could not be written: {recovery_error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    from ci_local import local_main
    raise SystemExit(local_main(main, __file__))
