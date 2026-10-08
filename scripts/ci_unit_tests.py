#!/usr/bin/env python3
"""Run the complete unit target from the existing verified, relocated build archive."""
from __future__ import annotations

import argparse
import json
import math
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import ci_build_archive as archive
from ci_summary import ContractError, decode, observation, parse_summary, require, test_identity, write_summary
from ci_verdict import expected_skip_verdict, identity_label, parse_policy, tier_approved
from run_host_checks import toolchain
from run_offline_unit_tests import (CommandError, INTERRUPT_GRACE_SECONDS, classify_test_results,
                                    default_run, parse_official_test_results_summary)
from run_strict_e2e import (export_private_result_bundle, finalize_private_result_bundle,
                            prepare_private_result_bundle_path, write_sensitive_scan)
from strict_e2e_server import PUBLIC_API_KEY

ROOT = Path(__file__).resolve().parent.parent
UNIT_TARGET = "immichSlidesTests"
TOOL_FILES = ("ci_unit_tests.py", "ci_build_archive.py", "ci_summary.py", "run_host_checks.py",
              "run_offline_unit_tests.py", "run_strict_e2e.py", "strict_e2e_runner_support.py",
              "strict_e2e_server.py", "strict_e2e_photo_identity.py", "strict_e2e_filter_contract.py",
              "strict_e2e_filter_manifest.py", "strict_e2e_out_of_order_contract.py",
              "strict_e2e_p2_contract.py", "album_server_narrow_contract.py", "access_lifecycle_contract.py",
              "ci-pins.json", "ci_verdict.py", "ci_population.py", "ui_test_inventory.py", "ci-test-policy.json")

# Post-boot enumeration calibration is distinct from the separately measured simulator startup.
HOSTED_ENUMERATION_SAMPLES = {
    "ios": {"completed_seconds": [307.096293334],
            "calibration_run_id": "37716498397", "calibration_boot_seconds": [53.769112167]},
    "tvos": {"completed_seconds": [41.619890792],
             "calibration_run_id": "37716498397", "calibration_boot_seconds": [25.735431]},
}
# Job overhead is the failed iOS job duration minus its independently measured phases.
HOSTED_BOOT_MAX_SECONDS = 110.186966041
HOSTED_JOB_OVERHEAD_SECONDS = 556 - (110.186966041 + 251.284679625 + 70.472742334)
OFFICIAL_SUMMARY_EXPORT_TIMEOUT_SECONDS = 60
OFFICIAL_EXPORT_TIMEOUT_SECONDS = 60 + OFFICIAL_SUMMARY_EXPORT_TIMEOUT_SECONDS
SIMULATOR_SHUTDOWN_TIMEOUT_SECONDS = 15
# A hosted delete exceeded its former 15-second bound; allow recovery before recording failure.
SIMULATOR_DELETE_TIMEOUT_SECONDS = 60


def measured_timeout(samples, *, margin, minimum):
    bounds = sorted(samples["completed_seconds"])
    require(bool(bounds) and all(isinstance(value, (int, float)) and math.isfinite(value) and value > 0 for value in bounds),
            "timeout calibration needs positive measured samples")
    require(margin > 1 and minimum >= 0, "timeout calibration needs a margin and nonnegative floor")
    p95 = bounds[math.ceil(0.95 * len(bounds)) - 1]
    return {**samples, "p95_seconds": p95, "margin_multiplier": margin,
            "timeout_seconds": max(minimum, math.ceil(p95 * margin / 60) * 60),
            "method": "nearest-rank sample p95; completed post-boot enumerations"}


def enumeration_budget(profile, platform):
    require(profile in {"local", "ci"} and platform in HOSTED_ENUMERATION_SAMPLES, "unknown enumeration profile or platform")
    budget = {"profile": profile, "timeout_seconds": 300, "test_timeout_seconds": 900,
              "simulator_boot_timeout_seconds": 600,
              "job_timeout_seconds": None}
    if profile == "ci":
        samples = HOSTED_ENUMERATION_SAMPLES[platform]
        budget.update(measured_timeout(samples, margin=2, minimum=300), job_timeout_seconds=2400,
                      sample_configuration="separate boot; calibration run " + samples["calibration_run_id"],
                      simulator_boot_timeout_seconds=math.ceil(HOSTED_BOOT_MAX_SECONDS * 2 / 60) * 60,
                      boot_max_seconds=HOSTED_BOOT_MAX_SECONDS, recovery_calibration_run_id="37717972490",
                      interrupt_grace_seconds=INTERRUPT_GRACE_SECONDS,
                      measured_job_overhead_seconds=HOSTED_JOB_OVERHEAD_SECONDS,
                      official_export_timeout_seconds=OFFICIAL_EXPORT_TIMEOUT_SECONDS,
                      official_summary_export_timeout_seconds=OFFICIAL_SUMMARY_EXPORT_TIMEOUT_SECONDS,
                      simulator_shutdown_timeout_seconds=SIMULATOR_SHUTDOWN_TIMEOUT_SECONDS,
                      simulator_delete_timeout_seconds=SIMULATOR_DELETE_TIMEOUT_SECONDS,
                      overhead_allowance_seconds=math.ceil((HOSTED_JOB_OVERHEAD_SECONDS + OFFICIAL_EXPORT_TIMEOUT_SECONDS +
                                                           SIMULATOR_SHUTDOWN_TIMEOUT_SECONDS + SIMULATOR_DELETE_TIMEOUT_SECONDS) / 60) * 60)
    return budget


def write_unit_summary(summary, path, budget):
    write_summary(summary, path)
    with (path / "summary.md").open("a", encoding="utf-8") as handle:
        handle.write(f"\nEnumeration infrastructure budget ({budget['profile']}): {budget['timeout_seconds']} s; "
                     f"execution: {budget['test_timeout_seconds']} s; "
                     f"separate simulator boot: {budget['simulator_boot_timeout_seconds']} s.\n")
        if budget["profile"] == "ci":
            handle.write(f"Sample configuration: {budget['sample_configuration']}. "
                         f"Completed hosted samples: {budget['completed_seconds']} s; "
                         f"Nearest-rank sample p95: {budget['p95_seconds']} s; "
                         f"margin: {budget['margin_multiplier']}x, rounded up to whole minutes with a 300 s minimum. "
                         f"Combined script phase bounds: {budget['simulator_boot_timeout_seconds'] + budget['timeout_seconds'] + budget['test_timeout_seconds']} s; "
                         f"stop grace: {budget['interrupt_grace_seconds']} s; "
                         f"overhead allowance: {budget['overhead_allowance_seconds']} s "
                         f"(measured job overhead {budget['measured_job_overhead_seconds']:.2f} s plus "
                         f"{budget['official_export_timeout_seconds']} s for tests and summary exports plus "
                         f"{budget['simulator_shutdown_timeout_seconds']} / {budget['simulator_delete_timeout_seconds']} s "
                         "for simulator shutdown / delete, rounded up to whole minutes). "
                         f"job bound: {budget['job_timeout_seconds']} s. "
                         "The small calibration sample does not estimate population tail latency; local defaults and product assertions are unchanged.\n")


def enumeration_keys(payload):
    require(isinstance(payload, dict) and payload.get("errors") == [], "bundle enumeration reported errors")
    found = []

    def walk(nodes, parents=(), target=None):
        require(isinstance(nodes, list), "unparseable enumeration children")
        for node in nodes:
            require(isinstance(node, dict), "unparseable enumeration node")
            kind, name = node.get("kind"), node.get("name")
            require(isinstance(name, str) and name, "missing enumeration name")
            if kind == "target":
                walk(node.get("children", []), (), name)
            elif kind == "test":
                require(target == UNIT_TARGET and parents, "enumeration contains a non-unit test")
                found.append("/".join((*parents, name)))
                require(not node.get("children"), "unsupported enumeration parameters")
            elif kind in {"plan", "class"}:
                walk(node.get("children", []), (*parents, name) if kind == "class" else parents, target)
            else:
                raise ContractError("unsupported enumeration node kind")

    walk(payload.get("values"))
    require(bool(found) and len(found) == len(set(found)), "empty or duplicate unit bundle enumeration")
    return set(found)


def official_cases(payload):
    require(isinstance(payload, dict) and isinstance(payload.get("testNodes"), list), "unparseable official tests")
    found = []

    def walk(nodes, bundle=None):
        for node in nodes:
            require(isinstance(node, dict), "unparseable official test node")
            kind = node.get("nodeType")
            if kind == "Test Case":
                require(bundle == UNIT_TARGET, "official results contain a non-unit test")
                found.append(node)
            else:
                walk(node.get("children", []), node.get("name") if str(kind).endswith("test bundle") else bundle)

    walk(payload["testNodes"])
    keys = [node.get("nodeIdentifier") for node in found]
    require(all(isinstance(key, str) and key for key in keys) and len(keys) == len(set(keys)),
            "missing or duplicate official test identity")
    return found


def duration_seconds(node):
    value = node.get("durationInSeconds", node.get("duration", "0s"))
    if isinstance(value, (float, int)):
        return float(value)
    require(isinstance(value, str) and re.fullmatch(r"[\d.]+s", value) is not None,
            "unsupported official test duration")
    return float(value[:-1])


def failure_message(node):
    if node.get("nodeType") == "Failure Message" and isinstance(node.get("name"), str) and node["name"].strip():
        return node["name"].strip().splitlines()[0][:200]
    for child in node.get("children", []):
        message = failure_message(child)
        if message:
            return message
    return None


def result_observations(payload, platform, skip_reasons):
    outcomes = {"Passed": "passed", "Failed": "failed", "Skipped": "skipped", "Expected Failure": "failed"}
    rows = []
    for node in official_cases(payload):
        key = node["nodeIdentifier"]
        require(node.get("result") in outcomes, "unsupported official test outcome")
        outcome = outcomes[node["result"]]
        reason = skip_reasons.get(key) if outcome == "skipped" else None
        require(outcome != "skipped" or isinstance(reason, str) and bool(reason.strip()), "missing official skip reason")
        rows.append(observation(test_identity("swift", UNIT_TARGET + "/" + key, platform=platform), outcome,
                                duration_seconds(node), reason=reason,
                                message=failure_message(node) if outcome == "failed" else None, exit_code=None))
        # The function remains the primary identity; parameter runs have their own dimensions.
        for child in node.get("children", []):
            if child.get("nodeType") not in {"Test Case Run", "Arguments"}:
                continue
            require(child.get("result") in outcomes, "unsupported parameter outcome")
            parameter = child.get("nodeIdentifier") or child.get("nodeIdentifierURL")
            require(isinstance(parameter, str) and parameter, "missing parameter identity")
            rows.append(observation(test_identity("swift", UNIT_TARGET + "/" + key,
                                                 platform=platform, parameter=parameter), outcomes[child["result"]],
                                    duration_seconds(child), reason=reason,
                                    message=(failure_message(child) or failure_message(node))
                                    if outcomes[child["result"]] == "failed" else None, exit_code=None))
    return rows


def compare_execution(compiled, observed):
    missing, extra = sorted(compiled - observed), sorted(observed - compiled)
    require(not missing and not extra, f"unit enumeration mismatch: missing={missing}; extra={extra}")


def judge_execution(summary, compiled, rows, counts, code, policy=None):
    summary["population"]["observed"] = rows
    observed = {row["identity"]["key"].removeprefix(UNIT_TARGET + "/") for row in rows
                if "parameter" not in row["identity"]["dimensions"]}
    compare_execution(compiled, observed)
    require(counts.total_test_count > 0, "official unit tests were empty")
    verdict = classify_test_results(counts)
    failed = verdict == "failed" or any(row["outcome"] == "failed" for row in rows)
    if failed and code in {0, 65}:
        summary["status"] = "failed"
        return code or 1
    require(code == 0, f"test-without-building failed (exit {code})")
    summary["status"] = "passed" if verdict == "passed" else "unverified"
    if counts.result.casefold() != "passed":
        summary["infrastructure"].append({"code": "unit-results-unverified", "message":
            "The official overall result does not establish passing unit tests."})
        return 1
    policy = policy or {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
    approved = tier_approved(policy, "unit")
    errors = []
    for row in rows:
        matched, error = expected_skip_verdict(row, policy["expected_skips"], tier="unit", environment="hermetic")
        if error:
            errors.append(error)
        elif row["outcome"] == "skipped" and not matched:
            errors.append("unexpected skip: " + identity_label(row["identity"]))
    if errors:
        summary["status"] = "failed"
        summary["infrastructure"].extend({"code": "coverage-failed", "message": error} for error in errors)
        return 1
    if counts.skipped_tests and not approved:
        summary["infrastructure"].append({"code": "policy-proposed", "message":
            "Only proposed unit exceptions explain coverage; maintainer approval is still required."})
    elif approved:
        summary["status"] = "passed"
    return code


def skip_reason(details):
    # Xcode's detail record owns the reason; never substitute source conditions or log guesses.
    reasons = []
    def walk(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if (key in {"skipReason", "skipMessage"} or key == "name" and value.get("nodeType") == "Skip Message") and isinstance(item, str) and item.strip():
                    reasons.append(item)
                else:
                    walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
    walk(details)
    require(bool(reasons), "official skipped test has no emitted reason")
    return "; ".join(dict.fromkeys(reasons))


def read_results(records, platform):
    tests = decode((records / "official-tests.json").read_text())
    reasons = {}
    for node in official_cases(tests):
        if node.get("result") == "Skipped":
            reasons[node["nodeIdentifier"]] = skip_reason(node)
    rows = result_observations(tests, platform, reasons)
    counts = parse_official_test_results_summary((records / "official-summary.json").read_text())
    cases = [row for row in rows if "parameter" not in row["identity"]["dimensions"]]
    require(counts.total_test_count == len(cases) and
            counts.passed_tests == sum(row["outcome"] == "passed" for row in cases) and
            counts.failed_tests == sum(row["outcome"] == "failed" for row in cases) and
            counts.skipped_tests == sum(row["outcome"] == "skipped" for row in cases),
            "official counts and per-test outcomes disagree")
    return rows, counts


def cleanup_simulator(simulator, measurements):
    failures = []
    for operation in ("shutdown", "delete"):
        timeout_seconds = SIMULATOR_SHUTDOWN_TIMEOUT_SECONDS if operation == "shutdown" else SIMULATOR_DELETE_TIMEOUT_SECONDS
        started = time.monotonic()
        code, message = 1, "consumer simulator " + operation + " failed"
        try:
            completed = subprocess.run(["xcrun", "simctl", operation, simulator], capture_output=True,
                                       timeout=timeout_seconds, check=False)
            code = completed.returncode
        except subprocess.TimeoutExpired:
            code = 124
            message = f"consumer simulator {operation} timed out after {timeout_seconds} s"
        except OSError as error:
            message += ": " + type(error).__name__
        measurements["simulator_" + operation + "_seconds"] = time.monotonic() - started
        measurements["simulator_" + operation + "_exit_code"] = code
        if code:
            failures.append({"code": "simulator-cleanup-timed-out" if code == 124 else "simulator-cleanup-failed", "message": message})
    return failures


def run_units(args):
    ctx = decode(args.selection_path.read_text())
    platform = ctx["platform"]
    summary = archive.record(ctx, platform, "unit-" + platform)
    summary["run"]["tier"] = "unit"
    summary["hashes"]["policies"]["unit-consumer"] = archive.file_hash(Path(__file__))
    budget = enumeration_budget(args.enumeration_profile, platform)
    write_unit_summary(summary, args.output_dir, budget)
    # This precedes archive validation and Xcode: failed tests must not lose their provenance.
    provenance = {"artifact_id": ctx["artifact_id"], "producer_run_id": ctx["run_id"],
                  "producer_attempt": ctx["producer_attempt"], "consumer_attempt": ctx["attempt"],
                  "identity": ctx["identity"], "platform": platform}
    archive.write_json(args.output_dir / "archive-consumption.json", provenance)
    started = time.monotonic()
    measurements = {"setup_seconds": args.setup_seconds, "transfer_seconds": args.transfer_seconds,
                    "enumeration_budget": budget,
                    "simulator_boot_seconds": None, "simulator_boot_exit_code": None,
                    "enumeration_seconds": None, "enumeration_exit_code": None,
                    "test_seconds": None, "test_exit_code": None,
                    "simulator_shutdown_seconds": None, "simulator_shutdown_exit_code": None,
                    "simulator_delete_seconds": None, "simulator_delete_exit_code": None}
    disk = None
    simulator, owns_simulator = args.simulator_id, False
    result_bundle = enumeration_bundle = None
    digest = None
    compiled = set()
    code = 1
    policy = None
    export_complete = False
    archive_ready = False
    try:
        archive.workspace_preflight(ROOT)
        require(not (ROOT / "immichSlides.xcodeproj").exists(), "consumer tooling must not contain an app source checkout")
        manifest_path = args.archive_dir / "manifest.json"
        manifest = decode(manifest_path.read_text())
        pins_path = Path(__file__).with_name("ci-pins.json")
        pins = decode(pins_path.read_text())
        developer = Path(os.environ.get("DEVELOPER_DIR") or archive.checked_command(["xcode-select", "-p"]))
        xcode_build = plistlib.loads((developer.parent / "version.plist").read_bytes())["ProductBuildVersion"]
        require(archive.file_hash(pins_path) == ctx["pins_sha256"], "consumer pins changed after selection")
        archive.validate_manifest(manifest, ctx["identity"], ctx["run_id"] or "local", ctx["producer_attempt"],
                                  platform, xcode_build, ctx["pins_sha256"])
        policy_path = Path(__file__).with_name("ci-test-policy.json")
        policy = parse_policy(policy_path.read_text(encoding="utf-8"))
        summary["hashes"]["policies"]["test-policy"] = archive.file_hash(policy_path)
        require(not os.path.lexists(manifest["source_path"]), "build-time source checkout is present on consumer")
        require(not os.path.lexists(manifest["products_path"]), "build-time Products path is present on consumer")
        require(str((args.relocated_path / "Products").resolve()) != manifest["products_path"], "Products were not relocated")
        archive.disk_check(args.min_free_gib)
        disk = archive.DiskMeasurement()
        archive.extract_products(args.archive_dir / "build.tar.gz", args.relocated_path, manifest)
        signature = archive.measure_signing(next((args.relocated_path / "Products").glob("Debug-*simulator/immichSlides.app")))
        require(signature == manifest["signing_mode"], "relocated app signing mismatch")
        summary["toolchain"] = toolchain()
        archive.record_signing(summary, signature)
        summary["toolchain"]["versions"]["simulator_runtime"] = pins["simulators"][platform]["runtime"]
        summary["hashes"]["manifests"] = {"ci-pins": ctx["pins_sha256"], "build": archive.file_hash(manifest_path)}
        provenance.update(manifest_sha256=archive.file_hash(manifest_path), archive_sha256=manifest["archive_sha256"],
                          signing_mode=signature, build_source_absent=True, build_products_absent=True)
        archive.write_json(args.output_dir / "archive-consumption.json", provenance)
        archive_ready = True
        devices = decode(archive.checked_command(["xcrun", "simctl", "list", "devicetypes", "--json"]))["devicetypes"]
        device_name = pins["device_types"]["iphone" if platform == "ios" else "appletv"]
        device_type = next(item["identifier"] for item in devices if item["name"] == device_name)
        runtime = pins["simulators"][platform]["runtime"]
        if simulator:
            available = decode(archive.checked_command(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
            require(any(item["udid"] == simulator and item["deviceTypeIdentifier"] == device_type
                        for item in available.get(runtime, [])), "assigned simulator does not match pins")
        else:
            simulator = archive.checked_command(["xcrun", "simctl", "create", "immichSlides-unit-archive", device_type, runtime])
            owns_simulator = True
        archive.disk_check(args.min_free_gib)
        phase = time.monotonic()
        code = default_run(["xcrun", "simctl", "bootstatus", simulator, "-b"],
                           timeout_seconds=budget["simulator_boot_timeout_seconds"])
        measurements["simulator_boot_seconds"] = time.monotonic() - phase
        measurements["simulator_boot_exit_code"] = code
        require(code == 0, f"simulator boot failed (exit {code})")
        xctestrun = next((args.relocated_path / "Products").glob("*.xctestrun"))
        base = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                "-destination", f"platform={archive.DESTINATIONS[platform]},id={simulator}",
                "-derivedDataPath", str(args.relocated_path / "consumer-derived"),
                "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                "-only-testing:" + UNIT_TARGET]
        enumeration_bundle = prepare_private_result_bundle_path("unit-enumeration-" + platform)
        enumeration_path = enumeration_bundle.parent / "enumeration.json"
        archive.disk_check(args.min_free_gib)
        phase = time.monotonic()
        code = default_run([*base, "-resultBundlePath", str(enumeration_bundle), "-enumerate-tests",
                            "-test-enumeration-format", "json", "-test-enumeration-output-path", str(enumeration_path)],
                           timeout_seconds=budget["timeout_seconds"])
        measurements["enumeration_seconds"] = time.monotonic() - phase
        measurements["enumeration_exit_code"] = code
        require(code == 0, f"unit enumeration failed (exit {code})")
        enumeration = decode(enumeration_path.read_text())
        compiled = enumeration_keys(enumeration)
        summary["population"]["compiled"] = [test_identity("swift", UNIT_TARGET + "/" + key, platform=platform)
                                                for key in sorted(compiled)]
        archive.write_json(args.output_dir / "bundle-enumeration.json", enumeration)
        result_bundle = prepare_private_result_bundle_path("unit-" + platform)
        archive.disk_check(args.min_free_gib)
        phase = time.monotonic()
        code = default_run([*base, "-resultBundlePath", str(result_bundle)], timeout_seconds=budget["test_timeout_seconds"])
        measurements["test_seconds"] = time.monotonic() - phase
        measurements["test_exit_code"] = code
        if code not in {0, 65}:
            summary["infrastructure"].append({"code": "unit-execution-timed-out" if code == 124 else "unit-execution-failed",
                                               "message": f"unit execution {'timed out' if code == 124 else 'failed'} (exit {code})"})
        # Do not raise on xcodebuild failure until official results have been exported.
    except Exception as error:
        code = code or 1
        # Enumeration can fail after creating a bundle; export or quarantine it too.
        if result_bundle is None:
            result_bundle = enumeration_bundle
        failure = ({"code": "unit-archive-failed", "message": str(error) if isinstance(error, (ContractError, CommandError))
                    else type(error).__name__} if archive_ready else archive.classify_archive_failure(error, "archive-consumption-failed"))
        summary["infrastructure"].append(failure)
    finally:
        if result_bundle is not None:
            try:
                digest = export_private_result_bundle(result_bundle, args.output_dir, [PUBLIC_API_KEY],
                                                      summary_timeout_seconds=OFFICIAL_SUMMARY_EXPORT_TIMEOUT_SECONDS)
                rows, counts = read_results(args.output_dir, platform)
                code = judge_execution(summary, compiled, rows, counts, code, policy)
                export_complete = True
            except Exception as error:
                code = code or 1
                summary["infrastructure"].append({"code": "unit-results-timed-out" if isinstance(error, subprocess.TimeoutExpired) else "unit-results-failed",
                                                   "message": f"official result export timed out after {error.timeout} s" if isinstance(error, subprocess.TimeoutExpired)
                                                   else str(error) if isinstance(error, (ContractError, CommandError)) else type(error).__name__})
        if owns_simulator:
            failures = cleanup_simulator(simulator, measurements)
            if failures:
                code = code or 1
                summary["infrastructure"].extend(failures)
        if code != 0 or summary["infrastructure"] and not export_complete:
            summary["status"] = "failed"
        if disk:
            measurements["disk"] = disk.finish()
        measurements["total_seconds"] = time.monotonic() - started
        archive.write_json(args.output_dir / "measurements.json", measurements)
        provenance["official_tests_sha256"] = digest
        provenance["official_result_kind"] = ("execution" if measurements["test_exit_code"] is not None else "enumeration") if result_bundle else None
        provenance["enumeration_exit_code"] = measurements["enumeration_exit_code"]
        provenance["test_exit_code"] = measurements["test_exit_code"]
        archive.write_json(args.output_dir / "archive-consumption.json", provenance)
        try:
            write_unit_summary(summary, args.output_dir, budget)
            write_sensitive_scan(args.output_dir, [PUBLIC_API_KEY])
        except Exception as error:
            code = code or 1
            export_complete = False
            summary["status"] = "failed"
            summary["infrastructure"].append({"code": "unit-finalization-failed", "message": type(error).__name__})
            write_unit_summary(summary, args.output_dir, budget)
        if result_bundle:
            failures = finalize_private_result_bundle(result_bundle, args.output_dir, digest, successful=export_complete and code == 0)
            if failures:
                code = code or 1
                summary["status"] = "failed"
                summary["infrastructure"].extend({"code": "unit-disposal-failed", "message": failure} for failure in failures)
                write_unit_summary(summary, args.output_dir, budget)
        # Successful enumeration has no execution activity; failed enumeration stays private.
        if enumeration_bundle and enumeration_bundle != result_bundle:
            shutil.rmtree(enumeration_bundle.parent)
        try:
            write_sensitive_scan(args.output_dir, [PUBLIC_API_KEY])
            archive.output("records_safe", "true")
        except Exception:
            code = code or 1
            summary["status"] = "failed"
            summary["infrastructure"].append({"code": "unit-publication-refused", "message": "publishable records failed the sensitive scan"})
            write_unit_summary(summary, args.output_dir, budget)
    print(f"Unit {platform}: {summary['status']}; artifact {ctx['artifact_id']}, producer attempt {ctx['producer_attempt']}; exit {code}", flush=True)
    return code


def stage_tools(path):
    require(not os.path.lexists(path), "staged tooling path must be fresh")
    (path / "scripts").mkdir(parents=True)
    for name in TOOL_FILES:
        shutil.copy2(ROOT / "scripts" / name, path / "scripts" / name)


def scan_records(path, *, failed_step=None):
    produced = (path / "summary.json").is_file()
    archive.output("records_produced", "true" if produced else "false")
    archive.output("records_safe", "false")
    if not produced:
        print("Unit records were not produced; publication is unavailable.")
        return 0
    try:
        summary = parse_summary(decode((path / "summary.json").read_text()))
        if failed_step and (summary["status"] != "failed" or summary["run"]["job"] != "unit-" + summary["run"]["shard"]):
            summary["run"].update(job="unit-" + summary["run"]["shard"], tier="unit")
            if summary["status"] != "failed":
                step = test_identity("host", "consumer " + failed_step, platform=summary["run"]["shard"])
                summary["population"]["declared"] = summary["population"]["compiled"] = [step]
                error = (archive.WorkspacePreflightError("consumer preflight or toolchain setup failed")
                         if failed_step == "preflight" else CommandError("consumer " + failed_step + " failed")
                         if failed_step in {"stage", "units"} else archive.ArchiveUnavailableError("selected archive " + failed_step + " failed"))
                archive.record_failure(summary, step, error, 1, time.monotonic(),
                                       "unit-stage-failed" if failed_step == "stage" else "unit-execution-failed"
                                       if failed_step == "units" else "archive-consumption-failed")
            write_summary(summary, path)
        require((path / "summary.md").is_file() and (path / "run-identity.json").is_file(), "incomplete unit records")
        write_sensitive_scan(path, [PUBLIC_API_KEY])
        archive.output("records_safe", "true")
        return 0
    except Exception:
        print("Unit record scanning refused publication.")
        return 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("stage")
    stage.add_argument("--path", type=Path, required=True)
    scan = commands.add_parser("scan")
    scan.add_argument("--output-dir", type=Path, required=True)
    scan.add_argument("--failed-step", choices=("preflight", "select", "download", "stage", "units"))
    run = commands.add_parser("run")
    for name in ("selection-path", "archive-dir", "relocated-path", "output-dir"):
        run.add_argument("--" + name, type=Path, required=True)
    run.add_argument("--min-free-gib", type=int, default=80)
    run.add_argument("--simulator-id")
    run.add_argument("--enumeration-profile", choices=("local", "ci"), default="local")
    run.add_argument("--setup-seconds", type=float)
    run.add_argument("--transfer-seconds", type=float)
    args = parser.parse_args(argv)
    try:
        for name in ("path", "selection_path", "archive_dir", "relocated_path", "output_dir"):
            if hasattr(args, name):
                path = getattr(args, name).resolve()
                require(ROOT != path and ROOT not in path.parents, "unit outputs must be outside tooling/source")
                setattr(args, name, path)
        if args.command == "stage":
            stage_tools(args.path)
            return 0
        if args.command == "scan":
            return scan_records(args.output_dir, failed_step=args.failed_step)
        require(args.min_free_gib >= 0, "disk threshold must be nonnegative")
        return run_units(args)
    except (OSError, ValueError, CommandError, subprocess.SubprocessError) as error:
        print(f"Unit archive FAIL: {error if isinstance(error, (ContractError, CommandError)) else type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
