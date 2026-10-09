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
from ci_summary import decode, identity_key, observation, require, test_identity, write_summary
from run_host_checks import GROUP_TERM_GRACE_SECONDS, group_has_live_members, run_identity, source_metadata, stop_group, toolchain
from run_strict_e2e import (CommandError, FILTER_PERSON_SESSIONS, resolve_suite_selector,
                            write_sensitive_scan, WRONG_PUBLIC_API_KEY)
from strict_e2e_build import build_settings, write_json
from strict_e2e_p2_contract import P2_CASES, RAW_VERDICT, official_tests_facts
from strict_e2e_server import PUBLIC_API_KEY

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts/strict-tracer.json"
BUILD_OPERATIONS = re.compile(r"^(?:SwiftCompile|SwiftEmitModule|CompileC|Ld |CompileAssetCatalog|CodeSign |ProcessInfoPlistFile )", re.MULTILINE)


def read_case_official(evidence, suite):
    """Read exported results after finalization, including nonzero runner exits."""
    def read(path):
        payload = decode(path.read_text())
        counts = ("totalTestCount", "passedTests", "failedTests", "skippedTests")
        for name in counts:
            require(type(payload.get(name)) is int and payload[name] >= 0, "invalid official count: " + name)
        require(payload["totalTestCount"] == sum(payload[name] for name in counts[1:]), "official counts do not add up")
        require(payload.get("result") in {"Passed", "Failed", "Skipped", "Unknown"}, "invalid official result")
        require(payload["result"] != "Passed" or (payload["passedTests"] == payload["totalTestCount"]
                and payload["totalTestCount"] > 0), "passing official result has nonpassing counts")
        return {name: payload[name] for name in (*counts, "result")}

    path = evidence / "official-summary.json"
    top = read(path) if path.is_file() else None
    if suite != "filter-person":
        return top
    sessions = [read(path) for session in FILTER_PERSON_SESSIONS
                if (path := evidence / f"official-summary-{session['name']}.json").is_file()]
    if not sessions:
        return top
    combined = {name: sum(item[name] for item in sessions)
                for name in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
    combined["result"] = "Passed" if all(item["result"] == "Passed" for item in sessions) else "Failed"
    require(top is None or top == combined, "official suite and session counts differ")
    return combined


def validate_case_export(evidence, platform, suite, official=None):
    sessions = [("-" + entry["name"], entry["selector"]) for entry in FILTER_PERSON_SESSIONS] if suite == "filter-person" else [
        ("", resolve_suite_selector(platform, suite))]
    methods = []
    counts = {"totalTestCount": 0, "passedTests": 0, "failedTests": 0, "skippedTests": 0}
    for suffix, selector in sessions:
        path = evidence / f"official-tests{suffix}.json"
        if not path.is_file():
            continue
        facts = official_tests_facts(decode(path.read_text()))["test_cases"]
        require(len(facts) == 1, "official export must contain exactly one selected method per invocation")
        bundle, name = selector.split("/", 1)
        require(facts[0]["bundle"] == bundle and facts[0]["identifier"] == name + "()", "official selected method differs from case")
        require(facts[0]["result"] in {"Passed", "Failed", "Skipped"}, "unknown official method outcome")
        counts["totalTestCount"] += 1
        counts[{"Passed": "passedTests", "Failed": "failedTests", "Skipped": "skippedTests"}[facts[0]["result"]]] += 1
        methods.append({"identifier": name, "result": facts[0]["result"]})
    require(methods, "official test identity export is missing")
    require(official is None or counts == {key: official[key] for key in counts}, "official counts differ from exported method outcomes")
    return methods


def evaluate_tracer(declared, results, *, interrupted=False, informational=()):
    observed = []
    for result in results:
        official = result.get("official_summary") or {}
        expected_count = len(FILTER_PERSON_SESSIONS) if result["identity"]["dimensions"]["suite"] == "filter-person" else 1
        passed = (result.get("exit_code") == 0 and result.get("log_present") is True
                  and result.get("build_operations") == 0 and result.get("products_unchanged") is True
                  and official.get("result") == "Passed" and official.get("totalTestCount") == expected_count
                  and official.get("passedTests") == expected_count and official.get("failedTests") == 0
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
    failed = interrupted or not complete or any(item["outcome"] == "failed"
        and item["identity"]["dimensions"]["suite"] not in informational for item in observed)
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
            errors = [line for line in log.read().splitlines() if line.startswith(("CommandError: ", "OfflineCommandError: ", "InfrastructureTimeout: "))]
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
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--shard", help="nightly shard from the versioned matrix")
    args = parser.parse_args(argv)
    if args.cold_timeout_seconds <= 0 or args.warm_timeout_seconds <= 0 or args.min_free_gib < 0:
        parser.error("timeouts must be positive and free space nonnegative")
    output = args.output_dir.resolve()
    if output == ROOT or ROOT in output.parents or os.path.lexists(output):
        parser.error("output must be fresh and outside the checkout")
    output.mkdir(parents=True)
    manifest = decode(args.manifest.read_text())
    nightly = args.shard is not None
    if nightly:
        from ci_nightly import parse_manifest, shards
        manifest = parse_manifest(manifest)
        selected = [shard for shard in shards(manifest) if shard["id"] == args.shard]
        require(len(selected) == 1 and selected[0]["platform"] == args.platform, "unknown or mismatched nightly shard")
        cases = selected[0]["cases"]
    else:
        cases = [case for case in manifest["cases"] if case["platform"] == args.platform]
    identities = [test_identity("strict", case["suite"], **{key: case[key] for key in ("device", "configuration", "suite", "scenario", "fixture")}) for case in cases]
    identity = run_identity(os.environ, ci=os.environ.get("GITHUB_ACTIONS") == "true")
    workspace_preflight(ROOT)
    workflow_path = ".github/workflows/ci-nightly.yml" if nightly else ".github/workflows/ci-strict-tracer.yml"
    workflow, fork = source_metadata(identity, os.environ, workflow_path if identity["event"] != "local" else None)
    summary = {"schema_version": 1, "identity": identity,
               "source": {"repository": identity["repository"], "event": identity["event"], "workflow_path": workflow, "fork_originated": fork, "ci_changing": None},
               "run": {"id": os.environ.get("GITHUB_RUN_ID"), "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")), "tier": "strict", "job": "nightly-strict" if nightly else "strict-tracer", "shard": args.shard or args.platform},
               "hashes": {"manifests": {"nightly-matrix" if nightly else "strict-tracer": file_hash(args.manifest)}, "policies": {}},
               "toolchain": toolchain(), "population": {"declared": identities, "compiled": [], "observed": [], "deselected": [], "removed_by_pr": []},
               "infrastructure": [], "status": "failed"}
    if nightly:
        summary["hashes"]["policies"]["nightly"] = file_hash(ROOT / "scripts/nightly-policy.json")
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
    trace["started_epoch"] = time.time()
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
        summary["population"]["observed"], summary["status"] = evaluate_tracer(identities, results,
            interrupted=bool(summary["infrastructure"]) or not completed,
            informational=[entry["suite"] for entry in manifest.get("informational", [])] if nightly else ())
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
            invocations = len(FILTER_PERSON_SESSIONS) if warm and case["suite"] == "filter-person" else 1
            phase["exit_code"] = run_runner(command, ROOT, output / "runner.log",
                timeout_seconds=(args.warm_timeout_seconds * invocations if warm else args.cold_timeout_seconds) + 240)
            return phase
        except BaseException as error:
            phase["exit_code"] = 124 if isinstance(error, subprocess.TimeoutExpired) else 130 if isinstance(error, KeyboardInterrupt) else 1
            raise
        finally:
            phase["duration_seconds"] = time.monotonic() - started
            if warm:
                collect_result(case, evidence, phase)
            trace["warm" if warm else "cold"].append(phase)
            checkpoint()

    def collect_result(case, evidence, phase):
        manifest_path = evidence / "case-manifest.json"
        details = decode(manifest_path.read_text()) if manifest_path.is_file() else {}
        infrastructure = details.get("infrastructure", [])
        require(isinstance(infrastructure, list) and all(isinstance(entry, dict)
                and set(entry) == {"code", "message"} and all(isinstance(value, str) for value in entry.values())
                for entry in infrastructure), "invalid case infrastructure entries")
        phase["infrastructure"] = infrastructure
        summary["infrastructure"].extend(infrastructure)
        log_path = evidence / "xcodebuild.log"
        builds = BUILD_OPERATIONS.findall(log_path.read_text()) if log_path.is_file() else []
        reuse_paths = ([evidence / f"xcodebuild-{session['name']}-reuse.json" for session in FILTER_PERSON_SESSIONS]
                       if case["suite"] == "filter-person" else [evidence / "xcodebuild-reuse.json"])
        unchanged = all(path.is_file() and decode(path.read_text())["products_unchanged"] is True for path in reuse_paths)
        official = None
        phase["official_methods"] = []
        try:
            official = read_case_official(evidence, case["suite"])
            if official is not None and official["totalTestCount"] > 0:
                phase["official_methods"] = validate_case_export(evidence, args.platform, case["suite"], official)
        except (ValueError, OSError) as error:
            phase["official_error"] = str(error)
            official = None
        contract_path = evidence / "visual-identity-runner.json"
        contract = decode(contract_path.read_text()) if contract_path.is_file() else {}
        contract_failed = contract.get("suite") == case["suite"] and contract.get("verdict") == "FAIL"
        phase.update(log_present=log_path.is_file(), build_operations=len(builds), products_unchanged=unchanged,
                     official_summary=official, p2_verdict=details.get("visual_identity", {}).get("verdict"),
                     automated_contract_failed=contract_failed)
        results.append(phase)
        if official is not None and official["totalTestCount"] > 0:
            summary["population"]["compiled"].append(phase["identity"])

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
            evidence = output / "cases" / (f"{cases.index(case):03d}-" + case["suite"])
            phase = invoke(case, evidence, derived, True)
            observed, _ = evaluate_tracer([case_identity], [phase])
            outcome = observed[0]["outcome"]
            checkpoint()
            if outcome == "needs-human-review" and not nightly and P2_CASES[case["suite"]].video:
                recording_evidence(evidence, output / "p2-trace" / case["suite"])
            print(f"{case['suite']}: {outcome}, {phase['duration_seconds']:.1f}s, build operations={phase['build_operations']}", flush=True)
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
        trace["finished_epoch"] = time.time()
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
