#!/usr/bin/env python3
"""Measure explicit cold builds and warm strict cases; P2 stays needs-human-review."""

from __future__ import annotations

import argparse
import copy
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
from ci_failure_diagnostics import VALIDATOR_FAILURE_FIELD, public_validator_failure_message
from ci_execution_diagnostics import Recorder, TRUNCATION_PREFIX, TRUNCATION_REASONS, report_truncation, session
from ci_bounded_diagnostics import (MAX_DIAGNOSTIC_SECONDS, MAX_PROCESSES, public_runner_process_name,
                                    render_runner_group_members, validate_runner_group_members)
from ci_summary import decode, identity_key, observation, parse_summary, require, test_identity, write_summary
from run_host_checks import GROUP_TERM_GRACE_SECONDS, group_has_live_members, run_identity, source_metadata, stop_group, toolchain
from run_strict_e2e import (CommandError, FILTER_PERSON_SESSIONS, resolve_suite_selector,
                            write_sensitive_scan, WRONG_PUBLIC_API_KEY)
from strict_e2e_build import build_settings, write_json
from strict_e2e_p2_contract import P2_CASES, RAW_VERDICT, official_tests_facts
from strict_e2e_server import PUBLIC_API_KEY
from strict_e2e_runner_support import (IOS_LIFECYCLE_PAUSE_SUITE, SIMULATOR_READINESS_TIMEOUT_SECONDS,
                                     SIMULATOR_PREPARATION_TIMEOUT_SECONDS,
                                     destination_udid, pause_timing_verdict, prepare_simulator)

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts/strict-tracer.json"
SIMULATOR_PREPARATION_HARD_TIMEOUT_SECONDS = SIMULATOR_PREPARATION_TIMEOUT_SECONDS + 180
RUNNER_MEMBER_PROBE_TIMEOUT_SECONDS = 3
MAX_RUNNER_PROCESS_TABLE_BYTES = 2 * 1024 * 1024
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
        payload = decode(path.read_text())
        facts = official_tests_facts(payload)["test_cases"]
        require(len(facts) == 1, "official export must contain exactly one selected method per invocation")
        bundle, name = selector.split("/", 1)
        require(facts[0]["bundle"] == bundle and facts[0]["identifier"] == name + "()", "official selected method differs from case")
        require(facts[0]["result"] in {"Passed", "Failed", "Skipped"}, "unknown official method outcome")
        counts["totalTestCount"] += 1
        counts[{"Passed": "passedTests", "Failed": "failedTests", "Skipped": "skippedTests"}[facts[0]["result"]]] += 1
        method = {"identifier": name, "result": facts[0]["result"]}
        if method["result"] == "Failed":
            from ci_failure_diagnostics import test_node_diagnostics, unknown_diagnostics
            method.update(test_node_diagnostics(payload).get(name, unknown_diagnostics()))
        methods.append(method)
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
        pending_timing = (result["identity"]["dimensions"]["suite"] == IOS_LIFECYCLE_PAUSE_SUITE
                          and result.get("p2_verdict") != "PASS")
        outcome = ("needs-human-review" if p2 or pending_timing else "passed") if passed else "failed"
        from ci_failure_diagnostics import DIAGNOSTIC_FIELDS, FIRST_FAILURE_FIELD, public_first_failure
        receipt = public_first_failure(result.get(FIRST_FAILURE_FIELD))
        preparation_failed = (outcome == "failed" and receipt is not None and receipt["source"] == "preparation"
                              and not official and not result.get("official_methods"))
        failed_method = next((method for method in result.get("official_methods", []) if method["result"] == "Failed"), None)
        failure_diagnostics = ({field: failed_method[field] for field in DIAGNOSTIC_FIELDS}
                               if outcome == "failed" and failed_method is not None else None)
        observed.append(observation(result["identity"], outcome, result["duration_seconds"],
            reason=("Pause timing requires signed transition-start evidence" if pending_timing else
                    "P2 contract requires signed human review") if outcome == "needs-human-review" else None,
            exit_code=result["exit_code"], failure_diagnostics=failure_diagnostics))
        if preparation_failed:
            observed[-1]["attempts"][0]["outcome"] = "not-run"
            observed[-1]["attempts"][0]["reason"] = "simulator preparation infrastructure failure before test execution"
        # The collector only adds receipts to failed phases; keep this check as defence in depth.
        if outcome == "failed" and VALIDATOR_FAILURE_FIELD in result:
            observed[-1][VALIDATOR_FAILURE_FIELD] = observed[-1]["attempts"][0][VALIDATOR_FAILURE_FIELD] = result[VALIDATOR_FAILURE_FIELD]
        if outcome == "failed" and receipt is not None and (preparation_failed or receipt["source"] in {"xctest", "validator"}):
            observed[-1][FIRST_FAILURE_FIELD] = observed[-1]["attempts"][0][FIRST_FAILURE_FIELD] = receipt
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

    def __init__(self, reason, *, members=None, truncated=False):
        self.members = members
        self.members_truncated = truncated
        super().__init__(reason + "; live members: " + render_runner_group_members(members, truncated=truncated))


def runner_group_members(group_id):
    """A failure-only ps projection: no arguments, paths, PIDs or arbitrary names survive."""
    try:
        table = subprocess.check_output(["ps", "-axo", "pid=,ppid=,pgid=,stat=,comm="],
            text=True, stderr=subprocess.DEVNULL, timeout=RUNNER_MEMBER_PROBE_TIMEOUT_SECONDS)
        if len(table.encode()) > MAX_RUNNER_PROCESS_TABLE_BYTES:
            return None, False
        rows = [line.split(None, 4) for line in table.splitlines()]
        rows = {row[0]: row for row in rows if len(row) == 5 and all(value.isdecimal() for value in row[:3])}
        members = []
        for row in rows.values():
            if row[2] != str(group_id) or row[3].startswith("Z"):
                continue
            parent = rows.get(row[1])
            members.append({"name": public_runner_process_name(row[4]),
                "parent": public_runner_process_name(parent[4]) if parent else "unknown",
                "state": "exiting" if "E" in row[3] else {"R": "running", "S": "sleeping", "I": "sleeping", "U": "uninterruptible",
                          "D": "uninterruptible", "T": "stopped"}.get(row[3][:1], "unknown")})
        return members[:MAX_PROCESSES], len(members) > MAX_PROCESSES
    except (OSError, ValueError, subprocess.SubprocessError):
        return None, False


def produce_environment_limits(summary, results, *, informational=(), policy_version=None, rejections=None):
    """Attach only reader-validated same-case proofs; retain every raw outcome."""
    from ci_failure_diagnostics import ENVIRONMENT_LIMIT_FIELD, environment_limit_evidence
    from ci_bounded_diagnostics import validate_receipt
    summary.pop("strict_case_evidence", None)
    if rejections is not None:
        rejections.clear()
    for index, entry in enumerate(summary["population"]["observed"]):
        def reject(reason):
            if rejections is not None and entry["outcome"] == "failed":
                rejections[identity_key(entry["identity"])] = reason

        if entry["identity"]["dimensions"]["suite"] in informational:
            reject("informational-suite")
            continue
        phases = [phase for phase in results if phase["identity"] == entry["identity"]]
        if len(phases) != 1:
            reject("phase-count")
            continue
        phase = phases[0]
        if (phase.get("infrastructure") or phase.get("official_error")
                or phase.get("exit_code") in {None, 124, 130} or phase.get("log_present") is not True
                or phase.get("build_operations") != 0 or phase.get("products_unchanged") is not True):
            reject("invocation-not-verified")
            continue
        rejection_reason = "invalid-bounded-receipt"
        try:
            ledger = phase.get("bounded_diagnostics")
            validate_receipt(ledger)
            resources = ledger.get("case_resources", [])
            failures = [resource for resource in resources if resource["first_failure_elapsed_seconds"] is not None]
            if len(failures) != 1:
                reject("failure-resource-count")
                continue
            samples = [event["sample"] for event in ledger["events"] if event["scope"] == "xcode"
                and event["sequence"] == failures[0]["sequence"] and event["sample"] is not None]
            hosted = len(samples) == 1 and samples[0]["runner_hosted"] is True
            proof = environment_limit_evidence(summary, entry, resources, runner_hosted=hosted, policy_version=policy_version)
            if proof is None:
                reject("missing-xcode-host-samples" if not samples else
                       "hosting-not-proven" if not hosted else "proof-not-eligible")
                continue
            # Validate hosting, attempt shape and original case binding through the merged reader.
            candidate = copy.deepcopy(summary)
            target = candidate["population"]["observed"][index]
            target[ENVIRONMENT_LIMIT_FIELD] = target["attempts"][0][ENVIRONMENT_LIMIT_FIELD] = proof
            candidate.setdefault("strict_case_evidence", []).append({"identity": entry["identity"],
                "bounded_diagnostics": ledger})
            rejection_reason = "summary-reader-rejected"
            parse_summary(candidate)
            from ci_report import method_observations
            # Other incomplete cases retain red status without hiding a qualified case's warning.
            scoped = copy.deepcopy(candidate)
            scoped["population"] = {"declared": [entry["identity"]],
                "compiled": [identity for identity in scoped["population"]["compiled"] if identity == entry["identity"]],
                "observed": [target], "deselected": [], "removed_by_pr": []}
            rejection_reason = "official-method-not-bound"
            methods, missing = method_observations(scoped, {"warm": [phase]}, runner_hosted=hosted)
            claimed = [method for method in methods if method.get(ENVIRONMENT_LIMIT_FIELD) == proof]
            if missing or len(claimed) != 1:
                reject("official-method-not-bound")
                continue
        except (ValueError, TypeError, KeyError, AttributeError, IndexError):
            reject(rejection_reason)
            continue
        entry[ENVIRONMENT_LIMIT_FIELD] = entry["attempts"][0][ENVIRONMENT_LIMIT_FIELD] = proof
        summary["strict_case_evidence"] = candidate["strict_case_evidence"]
    if summary["status"] != "failed":
        return 0
    population = summary["population"]
    complete = (len(population["observed"]) == len(population["declared"])
        and {identity_key(entry["identity"]) for entry in population["observed"]}
        == {identity_key(identity) for identity in population["declared"]})
    nonpassing = [entry for entry in population["observed"] if entry["outcome"] not in {"passed", "needs-human-review"}]
    return 0 if (complete and not summary["infrastructure"] and nonpassing
                 and all(ENVIRONMENT_LIMIT_FIELD in entry for entry in nonpassing)) else 1


def run_runner(command, repo_root, log_path, *, timeout_seconds, truncation_seen=None):
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
                reason = ("RuntimeError: Runner process group still has live members" if str(error) == "Runner process group still has live members"
                          else type(error).__name__)
                try:
                    members, truncated = runner_group_members(process.pid)
                    validate_runner_group_members(members)
                except BaseException:
                    # A second cancellation must never authorize deleting live build inputs.
                    members, truncated = None, False
                raise RunnerGroupCleanupError("Runner process group cleanup failed: " + reason,
                    members=members, truncated=truncated) from None
            log.seek(offset)
            lines = log.read().splitlines()
            truncation = next((line for line in lines if line.startswith(TRUNCATION_PREFIX)
                               and line.removeprefix(TRUNCATION_PREFIX) in TRUNCATION_REASONS), None)
            if truncation is not None:
                if truncation_seen is not None:
                    truncation_seen.set()
                report_truncation(truncation.removeprefix(TRUNCATION_PREFIX))
            errors = [line for line in lines if line.startswith(("CommandError: ", "OfflineCommandError: ", "InfrastructureTimeout: "))]
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
    parser.add_argument("--preparation-failed", action="store_true",
                        help="Record infrastructure failure with every case not-run; do not start builds or tests")
    parser.add_argument("--preparation-diagnostics", type=Path, help="public preparation measurement receipt")
    parser.add_argument("--prepare-simulator-only", action="store_true", help="Run only the bounded post-build service gate")
    parser.add_argument("--simulator-boot-submitted", action="store_true",
                        help="Gate an early-booted dedicated device after the first cold build, before any tests")
    args = parser.parse_args(argv)
    if args.cold_timeout_seconds <= 0 or args.warm_timeout_seconds <= 0 or args.min_free_gib < 0:
        parser.error("timeouts must be positive and free space nonnegative")
    if args.prepare_simulator_only:
        try:
            with session(args.preparation_diagnostics, reuse=True):
                prepare_simulator(destination_udid(args.destination), boot_submitted=True, should_check_app=False)
            return 0
        except CommandError as error:
            print(f"CommandError: {error}", file=sys.stderr, flush=True)
            return error.code
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
    identity_failure = None
    if nightly and not args.preparation_failed:
        identity_failure = {"schema_version": 1, "run": {"id": os.environ.get("GITHUB_RUN_ID"),
                            "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1"))},
                            "job": "nightly-strict", "shard": args.shard, "phase": "identity-collection",
                            "reason": "identity-collection-failed", "declared": identities}
    try:
        identity = run_identity(os.environ, ci=os.environ.get("GITHUB_ACTIONS") == "true")
    except Exception:
        if identity_failure is not None:
            write_json(output / "identity-failure.json", identity_failure)
        raise
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
    diagnostics_path = output / "bounded-diagnostics.json"
    diagnostics = Recorder()
    cleanup_event = None
    if args.preparation_diagnostics:
        diagnostics.load(args.preparation_diagnostics)
    diagnostics.save(diagnostics_path)
    if args.preparation_failed:
        reason = "simulator preparation infrastructure failure before tracer execution"
        summary["infrastructure"].append({"code": "simulator-preparation-failed", "message": reason})
        # Failed case accounting must not claim compilation or an executed attempt.
        summary["population"]["observed"] = [
            dict(observation(item, "not-run", 0, reason=reason, exit_code=None), outcome="failed")
            for item in identities]
        from ci_failure_diagnostics import preparation_first_failure
        for item in summary["population"]["observed"]:
            receipt = preparation_first_failure(diagnostics.receipt())
            item["first_failure"] = item["attempts"][0]["first_failure"] = receipt
        started = time.time()
        write_json(records / "trace.json", {"schema_version": 1, "cold": [], "warm": [],
            "exclusions": manifest["exclusions"], "started_epoch": started, "finished_epoch": time.time()})
        diagnostics.attach(summary)
        write_summary(summary, records)
        return 1
    free_samples = [shutil.disk_usage("/System/Volumes/Data").free]
    stopped = threading.Event()
    child_truncated = threading.Event()

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
    simulator_prepared = False
    preparation_failure = None
    exit_code = 1
    environment_rejections = {}
    from strict_e2e_resource_diagnostics import NativeActivityBudget
    native_budget = NativeActivityBudget()

    def checkpoint():
        nonlocal exit_code
        diagnostics.load(diagnostics_path)
        if cleanup_event is not None and cleanup_event not in diagnostics.events:
            diagnostics.retain(cleanup_event)
        if child_truncated.is_set():
            diagnostics.truncate("inherited")
        diagnostics.save(diagnostics_path)
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
        if preparation_failure is not None:
            summary["population"]["observed"] = [
                dict(observation(item, "not-run", 0, reason="simulator preparation infrastructure failure before test execution",
                                 exit_code=None), outcome="failed", first_failure=preparation_failure)
                for item in identities]
            for item in summary["population"]["observed"]:
                item["attempts"][0]["first_failure"] = preparation_failure
        diagnostics.attach(summary)
        exit_code = produce_environment_limits(summary, results,
            informational=[entry["suite"] for entry in manifest.get("informational", [])],
            rejections=environment_rejections)
        # Retain the existing case/receipt join for diagnostic hints even when a case is not yellow.
        bound = {identity_key(case["identity"]) for case in summary.get("strict_case_evidence", [])}
        for phase in results:
            receipt = phase.get("bounded_diagnostics", {})
            if (identity_key(phase["identity"]) not in bound
                    and any("app_hang_stack" in case or "continue_watch" in case
                            for case in receipt.get("case_resources", []))):
                summary.setdefault("strict_case_evidence", []).append({"identity": phase["identity"],
                    "bounded_diagnostics": receipt})
                bound.add(identity_key(phase["identity"]))
        write_summary(summary, records)

    def invoke(case, evidence, derived, warm):
        native_allowance = native_budget.reserve_case() if warm else 0
        command = [sys.executable, "-B", str(ROOT / "scripts/run_strict_e2e.py"),
                   "--platform", args.platform, "--destination", args.destination, "--suite", case["suite"],
                   "--configuration", case["configuration"], "--scenario", case["scenario"], "--fixture-set", case["fixture"],
                   "--evidence-dir", str(evidence), "--derived-data-path", str(derived),
                   "--diagnostics-receipt", str(diagnostics_path),
                   "--native-diagnostics-allowance-seconds", str(native_allowance),
                   "--cloned-source-packages-path", str(output / "SourcePackages"),
                   "--cold-timeout-seconds", str(args.cold_timeout_seconds), "--warm-timeout-seconds", str(args.warm_timeout_seconds),
                   "--min-free-gib", str(args.min_free_gib), "--test-without-building" if warm else "--warm-up-only"]
        if warm and simulator_prepared:
            command.append("--simulator-boot-submitted")
        started = time.monotonic()
        print(f"{'warm' if warm else 'cold'} {case['suite']}", flush=True)
        phase = {"identity": identities[cases.index(case)]} if warm else {"shard": derived.name}
        try:
            invocations = len(FILTER_PERSON_SESSIONS) if warm and case["suite"] == "filter-person" else 1
            phase["exit_code"] = run_runner(command, ROOT, output / "runner.log",
                truncation_seen=child_truncated,
                timeout_seconds=((args.warm_timeout_seconds + SIMULATOR_READINESS_TIMEOUT_SECONDS) * invocations
                                 if warm else args.cold_timeout_seconds) + 240)
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
        if "bounded_diagnostics" in details:
            from ci_bounded_diagnostics import validate_receipt
            try:
                validate_receipt(details["bounded_diagnostics"])
                phase["bounded_diagnostics"] = details["bounded_diagnostics"]
            except (ValueError, TypeError, KeyError):
                pass
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
        if case["suite"] == IOS_LIFECYCLE_PAUSE_SUITE:
            # This existing field carries visual verdicts despite its legacy P2 name.
            phase["p2_verdict"] = pause_timing_verdict(evidence)
        if contract_failed:
            observed, _ = evaluate_tracer([phase["identity"]], [phase])
            if observed[0]["outcome"] == "failed":
                # records/ is uploaded unscanned; sanitize before copying the candidate.
                # The existing CommandError relay can still expose raw errors in public job logs.
                phase[VALIDATOR_FAILURE_FIELD] = public_validator_failure_message(contract.get("error"))
        from ci_failure_diagnostics import FIRST_FAILURE_FIELD, public_first_failure
        if phase["exit_code"] and official is None and not phase["official_methods"]:
            receipt = public_first_failure(details.get(FIRST_FAILURE_FIELD))
            if receipt is not None and receipt["source"] == "preparation":
                phase[FIRST_FAILURE_FIELD] = receipt
        for method in phase["official_methods"]:
            receipt = public_first_failure(method.get(FIRST_FAILURE_FIELD))
            if method["result"] == "Failed" and receipt is not None and receipt["source"] == "xctest":
                phase[FIRST_FAILURE_FIELD] = receipt
                break
        if contract_failed and FIRST_FAILURE_FIELD not in phase:
            path = evidence / "first-failure-validator.json"
            try:
                receipt = public_first_failure(decode(path.read_text())) if path.is_file() and path.stat().st_size <= 8192 else None
            except (OSError, ValueError, TypeError, KeyError):
                receipt = None
            if receipt is not None and receipt["source"] == "validator":
                phase[FIRST_FAILURE_FIELD] = receipt
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
            if args.simulator_boot_submitted and not simulator_prepared:
                # Build time is settling time, outside the unchanged preparation/readiness budgets.
                try:
                    preparation_log = output / "simulator-preparation.log"
                    try:
                        preparation_exit = run_runner([sys.executable, "-B", str(Path(__file__).resolve()),
                            "--platform", args.platform, "--destination", args.destination, "--output-dir", str(output),
                            "--prepare-simulator-only", "--preparation-diagnostics", str(diagnostics_path)],
                            ROOT, preparation_log, timeout_seconds=SIMULATOR_PREPARATION_HARD_TIMEOUT_SECONDS,
                            truncation_seen=child_truncated)
                    finally:
                        if preparation_log.is_file():
                            for line in preparation_log.read_text().splitlines():
                                if line.startswith(("simulator-bootstatus:", "simulator-readiness:", "simulator-preparation:")):
                                    print(line, flush=True)
                    if preparation_exit:
                        raise CommandError(f"Simulator preparation child failed (exit {preparation_exit}).", code=preparation_exit)
                except (CommandError, subprocess.TimeoutExpired) as error:
                    from ci_failure_diagnostics import preparation_first_failure
                    diagnostics.load(diagnostics_path)
                    preparation_failure = preparation_first_failure(diagnostics.receipt())
                    if isinstance(error, subprocess.TimeoutExpired):
                        raise CommandError(f"Simulator preparation child timed out after {SIMULATOR_PREPARATION_HARD_TIMEOUT_SECONDS}s.", code=124) from None
                    raise
                simulator_prepared = True
            evidence = output / "cases" / (f"{cases.index(case):03d}-" + case["suite"])
            phase = invoke(case, evidence, derived, True)
            observed, _ = evaluate_tracer([case_identity], [phase])
            outcome = observed[0]["outcome"]
            checkpoint()
            if outcome == "needs-human-review" and not nightly and case["suite"] in P2_CASES and P2_CASES[case["suite"]].video:
                recording_evidence(evidence, output / "p2-trace" / case["suite"])
            print(f"{case['suite']}: {outcome}, {phase['duration_seconds']:.1f}s, build operations={phase['build_operations']}", flush=True)
            checkpoint()
        completed = True
    except BaseException as error:
        can_cleanup = not isinstance(error, RunnerGroupCleanupError)
        if not can_cleanup:
            (output / "runner-group-cleanup-failed").touch()
            cleanup_event = {"scope": "xcode", "phase": "unknown", "state": "after-reap", "sequence": 0,
                "elapsed_seconds": min(MAX_DIAGNOSTIC_SECONDS, max(0, time.time() - trace["started_epoch"])),
                "cpu_seconds": None, "sample": None, "input_sha256": None, "official_exports": None,
                "runner_group_members": error.members, "runner_group_truncated": error.members_truncated}
        code = ("simulator-preparation-failed" if preparation_failure is not None else
                "strict-tracer-failed" if isinstance(error, CommandError) else
                "step-timeout" if isinstance(error, subprocess.TimeoutExpired) else "interrupted")
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
    from ci_failure_diagnostics import render_environment_limit
    if (summary["source"]["workflow_path"] == ".github/workflows/ci-nightly.yml"
            and summary["source"]["event"] in {"schedule", "workflow_dispatch"}):
        for key, reason in environment_rejections.items():
            print(f"{key}: environment-limit: not eligible ({reason})", flush=True)
    for entry in summary["population"]["observed"]:
        if "environment_limit" in entry:
            print("::warning title=Environment-limited strict timing::" + identity_key(entry["identity"])
                  + ": " + render_environment_limit(entry["environment_limit"]), flush=True)
    return exit_code


if __name__ == "__main__":
    from ci_local import local_main
    raise SystemExit(local_main(main, __file__))
