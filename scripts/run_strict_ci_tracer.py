#!/usr/bin/env python3
"""Measure explicit cold builds and warm strict cases; P2 stays needs-human-review."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from ci_build_archive import file_hash, workspace_preflight
from ci_summary import identity_key, observation, test_identity, write_summary
from run_host_checks import GROUP_TERM_GRACE_SECONDS, group_has_live_members, run_identity, source_metadata, stop_group, toolchain
from run_strict_e2e import CommandError, write_sensitive_scan, WRONG_PUBLIC_API_KEY
from strict_e2e_build import build_settings, write_json
from strict_e2e_p2_contract import P2_CASES, RAW_VERDICT
from strict_e2e_server import PUBLIC_API_KEY

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts/strict-tracer.json"
BUILD_OPERATIONS = re.compile(r"^(?:SwiftCompile|SwiftEmitModule|CompileC|Ld |CompileAssetCatalog|CodeSign |ProcessInfoPlistFile )", re.MULTILINE)


def evaluate_tracer(declared, results, *, interrupted=False):
    observed = []
    for result in results:
        official = result.get("official_summary") or {}
        passed = (result.get("exit_code") == 0 and result.get("log_present") is True
                  and result.get("build_operations") == 0 and result.get("products_unchanged") is True
                  and official.get("result") == "Passed" and official.get("totalTestCount") == 1
                  and official.get("passedTests") == 1 and official.get("failedTests") == 0
                  and official.get("skippedTests") == 0)
        p2 = result["identity"]["dimensions"]["suite"] in P2_CASES
        passed = passed and (not p2 or result.get("p2_verdict") == RAW_VERDICT)
        outcome = ("needs-human-review" if p2 else "passed") if passed else "failed"
        observed.append(observation(result["identity"], outcome, result["duration_seconds"],
            reason="P2 contract requires signed human review" if outcome == "needs-human-review" else None,
            exit_code=result["exit_code"]))
    declared_keys = {identity_key(item) for item in declared}
    observed_keys = {identity_key(item["identity"]) for item in observed}
    complete = bool(declared) and declared_keys == observed_keys and len(results) == len(declared)
    failed = interrupted or not complete or any(item["outcome"] == "failed" for item in observed)
    for item in declared:
        if identity_key(item) not in observed_keys:
            observed.append(observation(item, "not-run", 0, reason="Tracer did not complete this declared case", exit_code=None))
    status = "failed" if failed else ("unverified" if any(item["outcome"] == "needs-human-review" for item in observed) else "passed")
    return observed, status


class RunnerGroupCleanupError(RuntimeError):
    """Build paths must be retained if runner descendants cannot be stopped."""


def run_runner(command, repo_root, log_path, *, timeout_seconds):
    with log_path.open("a+") as log:
        offset = log.tell()
        process = subprocess.Popen(command, cwd=repo_root, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout_seconds)
        finally:
            try:
                stop_group(process)
                deadline = time.monotonic() + GROUP_TERM_GRACE_SECONDS
                while group_has_live_members(process.pid):
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Runner process group still has live members")
                    time.sleep(0.05)
            except BaseException as error:
                raise RunnerGroupCleanupError(f"Runner process group cleanup failed: {type(error).__name__}: {error}") from error
            log.seek(offset)
            errors = [line for line in log.read().splitlines() if line.startswith(("CommandError: ", "OfflineCommandError: "))]
            if errors:
                print(errors[-1], file=sys.stderr, flush=True)
    return code


def recording_evidence(case, destination):
    destination.mkdir(parents=True)
    for name in ("screen-recording.mov", "screen-recording-timing.json"):
        shutil.copy2(case / name, destination / name)
    write_sensitive_scan(destination, [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY])
    write_json(destination / "recording-hashes.json", {
        "source_sha": json.loads((case / "case-manifest.json").read_text())["source_sha"],
        "files": {path.relative_to(destination).as_posix(): file_hash(path)
                  for path in sorted(destination.rglob("*")) if path.is_file()},
    })


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("ios", "tvos"), required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cold-timeout-seconds", type=int, default=1200)
    parser.add_argument("--warm-timeout-seconds", type=int, default=600)
    parser.add_argument("--min-free-gib", type=int, default=80)
    args = parser.parse_args(argv)
    if args.cold_timeout_seconds <= 0 or args.warm_timeout_seconds <= 0 or args.min_free_gib < 0:
        parser.error("timeouts must be positive and free space nonnegative")
    output = args.output_dir.resolve()
    if output == ROOT or ROOT in output.parents or os.path.lexists(output):
        parser.error("output must be fresh and outside the checkout")
    output.mkdir(parents=True)
    manifest = json.loads(MANIFEST.read_text())
    cases = [case for case in manifest["cases"] if case["platform"] == args.platform]
    identities = [test_identity("strict", case["suite"], **{key: case[key] for key in ("device", "configuration", "suite", "scenario", "fixture")}) for case in cases]
    identity = run_identity(os.environ, ci=os.environ.get("GITHUB_ACTIONS") == "true")
    workspace_preflight(ROOT)
    workflow, fork = source_metadata(identity, os.environ, ".github/workflows/ci-strict-tracer.yml" if identity["event"] != "local" else None)
    summary = {"schema_version": 1, "identity": identity,
               "source": {"repository": identity["repository"], "event": identity["event"], "workflow_path": workflow, "fork_originated": fork, "ci_changing": None},
               "run": {"id": os.environ.get("GITHUB_RUN_ID"), "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")), "tier": "strict", "job": "strict-tracer", "shard": args.platform},
               "hashes": {"manifests": {"strict-tracer": file_hash(MANIFEST)}, "policies": {}},
               "toolchain": toolchain(), "population": {"declared": identities, "compiled": [], "observed": [], "deselected": [], "removed_by_pr": []},
               "infrastructure": [], "status": "failed"}
    records = output / "records"
    records.mkdir()
    free_samples = [shutil.disk_usage("/System/Volumes/Data").free]
    stopped = threading.Event()

    def sample_disk():
        while not stopped.wait(1):
            free_samples.append(shutil.disk_usage("/System/Volumes/Data").free)

    sampler = threading.Thread(target=sample_disk, daemon=True)
    sampler.start()
    trace = {"schema_version": 1, "cold": [], "warm": [], "exclusions": manifest["exclusions"],
             "budgets_seconds": {"cold": args.cold_timeout_seconds, "warm": args.warm_timeout_seconds},
             "min_free_gib": args.min_free_gib}
    results = []
    can_cleanup = True
    completed = False

    def checkpoint():
        free_samples.append(shutil.disk_usage("/System/Volumes/Data").free)
        samples = list(free_samples)
        trace["disk"] = {"before_free_gib": samples[0] / 1024**3, "after_free_gib": samples[-1] / 1024**3,
                         "minimum_free_gib": min(samples) / 1024**3,
                         "peak_used_gib": (shutil.disk_usage("/System/Volumes/Data").total - min(samples)) / 1024**3,
                         "peak_growth_gib": (samples[0] - min(samples)) / 1024**3, "sampling_interval_seconds": 1}
        write_json(records / "trace.json", trace)
        summary["population"]["observed"], summary["status"] = evaluate_tracer(identities, results, interrupted=bool(summary["infrastructure"]) or not completed)
        write_summary(summary, records)

    def invoke(case, evidence, derived, warm):
        command = [sys.executable, "-B", str(ROOT / "scripts/run_strict_e2e.py"),
                   "--platform", args.platform, "--destination", args.destination, "--suite", case["suite"],
                   "--configuration", case["configuration"], "--scenario", case["scenario"], "--fixture-set", case["fixture"],
                   "--evidence-dir", str(evidence), "--derived-data-path", str(derived),
                   "--cloned-source-packages-path", str(output / "SourcePackages"),
                   "--cold-timeout-seconds", str(args.cold_timeout_seconds), "--warm-timeout-seconds", str(args.warm_timeout_seconds),
                   "--min-free-gib", str(args.min_free_gib), "--test-without-building" if warm else "--warm-up-only"]
        started = time.monotonic()
        print(f"{'warm' if warm else 'cold'} {case['suite']}", flush=True)
        phase = {"identity": identities[cases.index(case)]} if warm else {"shard": derived.name}
        try:
            phase["exit_code"] = run_runner(command, ROOT, output / "runner.log",
                timeout_seconds=(args.warm_timeout_seconds if warm else args.cold_timeout_seconds) + 240)
            return phase
        except BaseException as error:
            phase["exit_code"] = 124 if isinstance(error, subprocess.TimeoutExpired) else 130 if isinstance(error, KeyboardInterrupt) else 1
            raise
        finally:
            phase["duration_seconds"] = time.monotonic() - started
            trace["warm" if warm else "cold"].append(phase)
            checkpoint()

    def cancel(signum, _frame):
        raise KeyboardInterrupt(f"Received signal {signum}")

    previous_term = signal.signal(signal.SIGTERM, cancel)
    try:
        checkpoint()
        workspace_preflight(ROOT)
        shards = {}
        for case, case_identity in zip(cases, identities):
            scheme, plan, configuration = build_settings(args.platform, case["suite"], case["configuration"])
            shard = scheme + "-" + configuration
            derived = output / "derived" / shard
            if shard not in shards:
                phase = invoke(case, output / "warm-up" / shard, derived, False)
                if phase["exit_code"]:
                    raise CommandError(f"Cold build failed with exit {phase['exit_code']}")
                shards[shard] = True
                receipt = json.loads((derived / "strict-warm-build.json").read_text())
                summary["toolchain"]["signing_mode"] = "sign-to-run-locally"
                summary["toolchain"]["versions"]["codesign_signature"] = receipt["signing_mode"]
            evidence = output / "cases" / case["suite"]
            phase = invoke(case, evidence, derived, True)
            reuse = evidence / "xcodebuild-reuse.json"
            manifest_path = evidence / "case-manifest.json"
            details = json.loads(manifest_path.read_text()) if manifest_path.is_file() else {}
            log_path = evidence / "xcodebuild.log"
            builds = BUILD_OPERATIONS.findall(log_path.read_text()) if log_path.is_file() else []
            unchanged = reuse.is_file() and json.loads(reuse.read_text())["products_unchanged"] is True
            phase.update(log_present=log_path.is_file(), build_operations=len(builds), products_unchanged=unchanged,
                         official_summary=details.get("official_summary"), p2_verdict=details.get("visual_identity", {}).get("verdict"))
            results.append(phase)
            if details.get("official_summary") is not None:
                summary["population"]["compiled"].append(case_identity)
            observed, _ = evaluate_tracer([case_identity], [phase])
            outcome = observed[0]["outcome"]
            checkpoint()
            if outcome == "needs-human-review":
                recording_evidence(evidence, output / "p2-trace" / case["suite"])
            print(f"{case['suite']}: {outcome}, {phase['duration_seconds']:.1f}s, build operations={len(builds)}", flush=True)
            checkpoint()
        completed = True
    except BaseException as error:
        can_cleanup = not isinstance(error, RunnerGroupCleanupError)
        if not can_cleanup:
            (output / "runner-group-cleanup-failed").touch()
        code = "strict-tracer-failed" if isinstance(error, CommandError) else "step-timeout" if isinstance(error, subprocess.TimeoutExpired) else "interrupted"
        message = f"{type(error).__name__}: {error}"
        summary["infrastructure"].append({"code": code, "message": message})
        print(message, file=sys.stderr, flush=True)
    finally:
        stopped.set()
        try:
            sampler.join(timeout=5)
            # A failed process-group stop retains build paths instead of deleting live inputs.
            if can_cleanup:
                for name in ("derived", "SourcePackages"):
                    path = output / name
                    if path.exists():
                        shutil.rmtree(path)
            checkpoint()
            with (records / "summary.md").open("a") as report:
                report.write("\nCold build durations: " + ", ".join(f"{item['shard']}: {item['duration_seconds']:.1f}s" for item in trace["cold"]) + "\n")
                report.write(f"\nPeak sampled disk growth: {trace['disk']['peak_growth_gib']:.2f} GiB; minimum free: {trace['disk']['minimum_free_gib']:.2f} GiB.\n")
        except BaseException as error:
            summary["infrastructure"].append({"code": "interrupted", "message": f"Finalization interrupted: {type(error).__name__}: {error}"})
            print(summary["infrastructure"][-1]["message"], file=sys.stderr, flush=True)
            checkpoint()
        finally:
            signal.signal(signal.SIGTERM, previous_term)
    return 1 if summary["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
