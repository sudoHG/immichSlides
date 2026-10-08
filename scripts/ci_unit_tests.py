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
from ci_summary import ContractError, decode, observation, require, test_identity, write_summary
from run_host_checks import toolchain
from run_offline_unit_tests import CommandError, default_run, parse_official_test_results_summary
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
              "ci-pins.json")

# Interrupted samples provide lower bounds for their unknown true duration, excluding shutdown grace.
HOSTED_ENUMERATION_SAMPLES = {
    "ios": {"completed_seconds": [166.58, 293.18], "censored_samples": [
        {"limit_seconds": 300, "wall_seconds": 352.58}, {"limit_seconds": 300, "wall_seconds": 304.47}]},
    "tvos": {"completed_seconds": [63.16, 95.22, 89.32], "censored_samples": []},
}


def enumeration_budget(profile, platform):
    require(profile in {"local", "ci"} and platform in HOSTED_ENUMERATION_SAMPLES, "unknown enumeration profile or platform")
    budget = {"profile": profile, "timeout_seconds": 300, "test_timeout_seconds": 900,
              "job_timeout_seconds": None}
    if profile == "ci":
        samples = HOSTED_ENUMERATION_SAMPLES[platform]
        bounds = sorted([*samples["completed_seconds"], *(item["limit_seconds"] for item in samples["censored_samples"])])
        p95_floor = bounds[math.ceil(0.95 * len(bounds)) - 1]
        budget.update(samples, p95_lower_bound_seconds=p95_floor, margin_multiplier=2,
                      timeout_seconds=max(300, math.ceil(p95_floor * 2 / 60) * 60), job_timeout_seconds=2100,
                      method="nearest-rank sample p95 lower bound; censored durations are unknown above their limit")
    return budget


def write_unit_summary(summary, path, budget):
    write_summary(summary, path)
    with (path / "summary.md").open("a", encoding="utf-8") as handle:
        handle.write(f"\nEnumeration infrastructure budget ({budget['profile']}): {budget['timeout_seconds']} s; "
                     f"execution: {budget['test_timeout_seconds']} s.\n")
        if budget["profile"] == "ci":
            handle.write(f"Completed hosted samples: {budget['completed_seconds']} s; "
                         f"right-censored samples (limit and wall including shutdown): {budget['censored_samples']}. "
                         f"Nearest-rank p95 lower bound: {budget['p95_lower_bound_seconds']} s; "
                         f"margin: {budget['margin_multiplier']}x, rounded up to whole minutes with a 300 s minimum. "
                         f"Combined script phase bounds: {budget['timeout_seconds'] + budget['test_timeout_seconds']} s; "
                         f"job bound: {budget['job_timeout_seconds']} s. "
                         "The censored sample does not estimate the true p95; local defaults and product assertions are unchanged.\n")


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
                                duration_seconds(node), reason=reason, exit_code=None))
        # The function remains the primary identity; parameter runs have their own dimensions.
        for child in node.get("children", []):
            if child.get("nodeType") not in {"Test Case Run", "Arguments"}:
                continue
            require(child.get("result") in outcomes, "unsupported parameter outcome")
            parameter = child.get("nodeIdentifier") or child.get("nodeIdentifierURL")
            require(isinstance(parameter, str) and parameter, "missing parameter identity")
            rows.append(observation(test_identity("swift", UNIT_TARGET + "/" + key,
                                                 platform=platform, parameter=parameter), outcomes[child["result"]],
                                    duration_seconds(child), reason=reason, exit_code=None))
    return rows


def compare_execution(compiled, observed):
    missing, extra = sorted(compiled - observed), sorted(observed - compiled)
    require(not missing and not extra, f"unit enumeration mismatch: missing={missing}; extra={extra}")


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
                    "enumeration_seconds": None, "enumeration_exit_code": None,
                    "test_seconds": None, "test_exit_code": None}
    disk = None
    simulator, owns_simulator = args.simulator_id, False
    result_bundle = enumeration_bundle = None
    digest = None
    compiled = set()
    code = 1
    export_complete = False
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
        # Do not raise on xcodebuild failure until official results have been exported.
    except Exception as error:
        code = code or 1
        # Enumeration can fail after creating a bundle; export or quarantine it too.
        if result_bundle is None:
            result_bundle = enumeration_bundle
        summary["infrastructure"].append({"code": "unit-archive-failed", "message": str(error) if isinstance(error, (ContractError, CommandError))
                                           else type(error).__name__})
    finally:
        if result_bundle is not None:
            try:
                digest = export_private_result_bundle(result_bundle, args.output_dir, [PUBLIC_API_KEY])
                rows, counts = read_results(args.output_dir, platform)
                summary["population"]["observed"] = rows
                compare_execution(compiled, {node["nodeIdentifier"] for node in official_cases(
                    decode((args.output_dir / "official-tests.json").read_text()))})
                require(counts.total_test_count > 0 and counts.failed_tests == 0, "official unit tests failed or were empty")
                require(not any(row["outcome"] == "failed" for row in rows), "official parameter run failed")
                require(code == 0, f"test-without-building failed (exit {code})")
                summary["status"] = "unverified" if counts.skipped_tests else "passed"
                if counts.skipped_tests:
                    summary["infrastructure"].append({"code": "unit-skips-unapproved", "message":
                        "Measured unit skips remain proposed for maintainer approval; no expected-skip policy is applied."})
                export_complete = True
            except Exception as error:
                code = code or 1
                summary["infrastructure"].append({"code": "unit-results-failed", "message": str(error) if isinstance(error, (ContractError, CommandError))
                                                   else type(error).__name__})
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
        if owns_simulator:
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deleted = subprocess.run(["xcrun", "simctl", "delete", simulator], capture_output=True)
            if deleted.returncode:
                code = code or 1
                summary["status"] = "failed"
                summary["infrastructure"].append({"code": "simulator-cleanup-failed", "message": "consumer simulator deletion failed"})
                write_unit_summary(summary, args.output_dir, budget)
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("stage")
    stage.add_argument("--path", type=Path, required=True)
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
        require(args.min_free_gib >= 0, "disk threshold must be nonnegative")
        return run_units(args)
    except (OSError, ValueError, CommandError, subprocess.SubprocessError) as error:
        print(f"Unit archive FAIL: {error if isinstance(error, (ContractError, CommandError)) else type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
