#!/usr/bin/env python3
"""Run default-plan UI tests against public loopback fixtures and measure each test."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import time
from datetime import date
from functools import partial
from pathlib import Path

from ci_build_archive import check_products, disk_check, measure_signing, record_signing
from ci_population import ui_identities
from ci_summary import ContractError, observation, require, write_summary
from ci_ui_shards import DEVICES, default_plan_population
from ci_verdict import evaluate_population, parse_policy, tier_approved
from ci_flaky import OfficialResultReadError, load_registry, registry_revision, run_xcode_attempts, read_xcode_observations
from run_host_checks import run_identity, source_metadata, toolchain
from run_offline_unit_tests import CommandError as OfflineCommandError, _stop_process_group
from run_strict_e2e import (export_private_result_bundle, finalize_private_result_bundle,
                            prepare_private_result_bundle_path, write_sensitive_scan)
from strict_e2e_runner_support import CommandError, destination_udid, reset_simulator_app, stop_exact_process, wait_for_service
from strict_e2e_server import PUBLIC_API_KEY, fixture_manifest
from access_lifecycle_contract import logical_bytes_contain
from ci_wait_policy import FACTOR_ENVIRONMENT_KEY, wait_configuration

ROOT = Path(__file__).resolve().parent.parent
DEVICE_MODELS = {"iphone": "iPhone", "ipad": "iPad", "appletv": "Apple TV"}
# Simulator processes are crash-reported by the host, so their reports land in the host's diagnostic directories.
CRASH_REPORT_DIRECTORIES = ("Library/Logs/DiagnosticReports", "Library/Logs/DiagnosticReports/Retired")
CRASH_REPORT_SUFFIXES = {".ips", ".crash"}
CRASH_REPORT_PROCESS_PREFIX = "immichSlides"  # the app and the UI test runner
MAX_CRASH_REPORTS = 5
MAX_CRASH_REPORT_BYTES = 1024 * 1024
MAX_CRASH_REPORTS_TOTAL_BYTES = 4 * 1024 * 1024


def verify_simulator_device(payload, udid, device):
    require(isinstance(payload, dict) and isinstance(payload.get("devices"), dict), "invalid simulator inventory")
    matches = []
    for devices in payload["devices"].values():
        require(isinstance(devices, list) and all(isinstance(item, dict) for item in devices),
                "invalid simulator inventory devices")
        matches.extend(item for item in devices if item.get("udid") == udid)
    require(len(matches) == 1 and matches[0].get("isAvailable") is True, "destination simulator is missing or unavailable")
    type_id = matches[0].get("deviceTypeIdentifier")
    prefix = "com.apple.CoreSimulator.SimDeviceType." + DEVICE_MODELS[device].replace(" ", "-") + "-"
    require(isinstance(type_id, str) and type_id.startswith(prefix), "destination simulator type differs from --device")


def verify_official_device(payload, udid, device):
    devices = payload.get("devices") if isinstance(payload, dict) else None
    require(isinstance(devices, list) and len(devices) == 1 and isinstance(devices[0], dict),
            "official results must record exactly one device")
    recorded = devices[0]
    require(recorded.get("deviceId") == udid, "official result device UDID differs from destination")
    platform = "tvOS Simulator" if DEVICES[device] == "tvos" else "iOS Simulator"
    model = recorded.get("modelName")
    require(recorded.get("platform") == platform and isinstance(model, str)
            and model.startswith(DEVICE_MODELS[device]), "official result device type differs from --device")


def prepare_fixture_result_bundle():
    original = prepare_private_result_bundle_path("fixture-ui")
    # The shared finalizer removes the bundle's parent; logs must live outside it.
    directory = original.parent / "result"
    directory.mkdir(mode=0o700)
    return directory / original.name


def finalize_fixture_run(bundle, output, digest, *, successful):
    failures = finalize_private_result_bundle(bundle, output, digest, successful=successful)
    if successful and not failures and not bundle.exists():
        try:
            shutil.rmtree(bundle.parent.parent)
        except OSError as error:
            failures.append("dispose_fixture_logs: " + str(error))
    return failures


def clean_environment(source):
    def forbidden(key):
        for prefix in ("TEST_RUNNER_", "SIMCTL_CHILD_"):
            if key.startswith(prefix):
                return forbidden(key[len(prefix):])
        return key.startswith(("IMMICH", "UI_TEST_", "STRICT_E2E_", "ENABLE_DEBUG_"))
    return {key: value for key, value in source.items() if not forbidden(key)}


def canonical_test(identifier):
    require(isinstance(identifier, str), "invalid UI test identifier type")
    # The main test class has the same name as the target; official nodes omit the target.
    if identifier.count("/") == 2:
        identifier = identifier.removeprefix("immichSlidesUITests/")
    identifier = identifier.removesuffix("()")
    require(re.fullmatch(r"[A-Za-z_]\w*/test[A-Za-z_]\w*", identifier), "invalid UI test identifier")
    return identifier


def declared_tests(files, platform, plan, selectors):
    declared = default_plan_population(ui_identities(files, platform), plan)
    if selectors:
        keys = {canonical_test(selector) for selector in selectors}
        require(keys <= {entry["key"] for entry in declared}, "selector is outside the default UI plan")
        declared = [entry for entry in declared if entry["key"] in keys]
    require(declared, "empty UI test population")
    return declared


def duration_seconds(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        seconds = float(value)
    else:
        require(isinstance(value, str), "missing test duration")
        parts = re.findall(r"([0-9]+(?:\.[0-9]+)?)\s*(ms|s|m|h)", value)
        require(parts and not re.sub(r"([0-9]+(?:\.[0-9]+)?)\s*(ms|s|m|h)", "", value).strip(),
                "invalid test duration")
        seconds = sum(float(amount) * {"ms": .001, "s": 1, "m": 60, "h": 3600}[unit] for amount, unit in parts)
    require(math.isfinite(seconds) and seconds >= 0, "invalid test duration")
    return seconds


def coverage_rows(declared, compiled, official, device):
    expected = {entry["key"]: entry for entry in declared}
    compiled_keys = {entry["key"] for entry in compiled or []}
    require(len(compiled_keys) == len(compiled or []), "duplicate compiled identity")
    require(compiled_keys <= expected.keys(), "unexpected compiled identity")
    outcomes = {"Passed": "passed", "Failed": "failed", "Skipped": "skipped"}
    observed = {}
    def visit(node):
        require(isinstance(node, dict), "invalid official test node")
        if node.get("nodeType") == "Test Case":
            key = canonical_test(node["nodeIdentifier"])
            require(key in expected and key in compiled_keys and key not in observed, "unexpected or duplicate official test")
            require(node.get("result") in outcomes, "unknown official test outcome")
            outcome = outcomes[node["result"]]
            observed[key] = {"identity": expected[key], "device": device, "outcome": outcome,
                             "duration_seconds": duration_seconds(node["durationInSeconds"]),
                             "reason": None if outcome == "passed" else "Official XCTest " + node["result"]}
        children = node.get("children", [])
        require(isinstance(children, list), "invalid official test children")
        for child in children:
            visit(child)
    require(isinstance(official, dict) and isinstance(official.get("testNodes"), list), "invalid official test export")
    for node in official["testNodes"]:
        visit(node)
    return [observed.get(key, {"identity": entry, "device": device, "outcome": "not-run",
                              "duration_seconds": 0, "reason": "not attempted" if compiled is None
                              else "not compiled" if key not in compiled_keys
                              else "compiled but no official result"}) for key, entry in sorted(expected.items())]


def compiled_tests(payload, declared):
    expected = {entry["key"]: entry for entry in declared}
    found = []
    require(isinstance(payload, dict) and payload.get("errors") == [] and isinstance(payload.get("values"), list),
            "invalid compiled enumeration")
    for configuration in payload["values"]:
        require(isinstance(configuration, dict) and isinstance(configuration.get("enabledTests"), list),
                "invalid compiled test configuration")
        for item in configuration["enabledTests"]:
            require(isinstance(item, dict) and isinstance(item.get("identifier"), str), "invalid compiled test identity")
            identifier = item["identifier"]
            require(identifier.startswith("immichSlidesUITests/"), "enumeration contains another target")
            found.append(canonical_test(identifier))
    require(len(found) == len(set(found)) and set(found) <= expected.keys(), "unexpected compiled population")
    return [expected[key] for key in sorted(found)]


def problem_reason(payload, key):
    require(canonical_test(payload["testIdentifier"]) == key, "official problem detail identity differs")
    require(payload["testResult"] in {"Failed", "Skipped"}, "official problem detail is not non-passing")
    messages = []
    def visit(node):
        require(isinstance(node, dict), "invalid official problem node")
        if node.get("nodeType") == "Test Case Run" and node.get("result") in {"Failed", "Skipped"}:
            require(isinstance(node.get("name"), str) and node["name"].strip(), "missing official problem message")
            messages.append(node["name"])
        children = node.get("children", [])
        require(isinstance(children, list), "invalid official problem children")
        for child in children:
            visit(child)
    require(isinstance(payload.get("testRuns"), list), "invalid official problem runs")
    for run in payload["testRuns"]:
        visit(run)
    require(messages, "official non-passing test has no reason")
    return " ".join(messages)


def read_problem_reason(bundle, key, *, export_timeout_seconds=60):
    completed = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "test-details", "--path", str(bundle),
                                "--test-id", key + "()", "--compact"], capture_output=True, check=False, timeout=export_timeout_seconds)
    require(completed.returncode == 0, "official problem detail export failed")
    require(not logical_bytes_contain(completed.stdout, [PUBLIC_API_KEY]), "official problem detail contains credentials")
    return problem_reason(json.loads(completed.stdout), key)


def prepare_test_run(source, directory, inputs, *, failure_screenshots=False):
    payload = plistlib.loads(source.read_bytes())
    def relocate(value):
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(source.parent))
        if isinstance(value, list):
            return [relocate(item) for item in value]
        if isinstance(value, dict):
            return {key: relocate(item) for key, item in value.items()}
        return value
    payload = relocate(payload)
    targets = [target for configuration in payload.get("TestConfigurations", [])
               for target in configuration.get("TestTargets", [])]
    require(targets, "test run has no targets")
    for target in targets:
        for field in ("EnvironmentVariables", "UITargetAppEnvironmentVariables", "TestingEnvironmentVariables"):
            target[field] = clean_environment(target.get(field, {}))
        if target.get("BlueprintName") == "immichSlidesUITests":
            target["EnvironmentVariables"].update(inputs)
            if failure_screenshots:
                # Archives default to video; export requires real failure images.
                target["PreferredScreenCaptureFormat"] = "screenshots"
                target["SystemAttachmentLifetime"] = "deleteOnSuccess"
    path = directory / "fixture.xctestrun"
    path.write_bytes(plistlib.dumps(payload))
    return path


CRASH_DEVICE_IDENTIFIER_JSON = re.compile(
    rb'("(?:crashReporterKey|bootSessionUUID|anonymousUUID|sleepWakeUUID)"\s*:\s*")[^"]*(")', re.IGNORECASE)
CRASH_DEVICE_IDENTIFIER_TEXT = re.compile(
    rb"^((?:CrashReporter Key|Anonymous UUID|Sleep/Wake UUID|Boot Session UUID):[ \t]*)[^\r\n]*", re.IGNORECASE | re.MULTILINE)


def crash_report_directories():
    try:
        return [Path.home() / directory for directory in CRASH_REPORT_DIRECTORIES]
    except Exception:
        return []


def crash_report_snapshot(directories):
    """Names are stable when the host moves a report into Retired; the start time covers a failed listing."""
    baseline = {"started": time.time(), "names": set()}
    try:
        baseline["names"] = {path.name for directory in directories if directory.is_dir() for path in directory.iterdir()}
    except Exception as error:
        print(f"Crash report baseline unavailable ({type(error).__name__}); relying on the time window", file=sys.stderr, flush=True)
    return baseline


def redact_crash_report(data, home_text):
    """Drop the host path and stable device identifiers; binary image UUIDs stay for symbolication."""
    data = data.replace(home_text.encode(), b"~").replace(home_text.replace("/", "\\/").encode(), b"~")
    data = CRASH_DEVICE_IDENTIFIER_JSON.sub(rb"\1<redacted>\2", data)
    return CRASH_DEVICE_IDENTIFIER_TEXT.sub(rb"\1<redacted>", data)


def collect_crash_reports(udid, baseline, destination, directories, *, home=None):
    """Best effort: a failure here must never change the run's exit code or hide the other evidence."""
    try:
        return collect_new_crash_reports(udid, baseline, destination, directories, home=home)
    except Exception as error:
        print(f"Crash report collection skipped ({type(error).__name__})", file=sys.stderr, flush=True)
        return [], []


def collect_new_crash_reports(udid, baseline, destination, directories, *, home=None):
    """Copy this simulator's app crash reports written during the run, earliest first and within fixed bounds."""
    home_text = str(home or Path.home())
    candidates, seen = [], set()
    for directory in directories:
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if (path.name in baseline["names"] or path.name in seen or path.suffix.lower() not in CRASH_REPORT_SUFFIXES
                    or not path.name.startswith(CRASH_REPORT_PROCESS_PREFIX)):
                continue
            try:
                modified = path.stat().st_mtime
            except OSError:
                continue
            if modified < baseline["started"]:
                continue
            seen.add(path.name)
            candidates.append((modified, path.name, path))
    reports, omitted, total = [], [], 0
    for _, name, path in sorted(candidates):
        try:
            with path.open("rb") as handle:
                data = handle.read(MAX_CRASH_REPORT_BYTES + 1)
        except OSError:
            omitted.append({"name": name, "reason": "unreadable"})
            continue
        if len(data) > MAX_CRASH_REPORT_BYTES:
            omitted.append({"name": name, "reason": "larger than the per-report limit"})
            continue
        if udid.lower().encode() not in data.lower():
            continue
        data = redact_crash_report(data, home_text)
        if len(reports) >= MAX_CRASH_REPORTS or total + len(data) > MAX_CRASH_REPORTS_TOTAL_BYTES:
            omitted.append({"name": name, "reason": "report count or total size limit reached"})
            continue
        destination.mkdir(parents=True, exist_ok=True)
        (destination / name).write_bytes(data)
        total += len(data)
        reports.append({"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    if reports or omitted:
        destination.mkdir(parents=True, exist_ok=True)
        write_json(destination / "manifest.json", {"schema_version": 1, "reports": reports, "omitted": omitted})
    return reports, omitted


def write_json(path, payload):
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", choices=DEVICES, required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    build = parser.add_mutually_exclusive_group(required=True)
    build.add_argument("--derived-data-path", type=Path)
    build.add_argument("--xctestrun", type=Path, help="Use an already secret-free build without rebuilding")
    parser.add_argument("--only-testing", action="append", default=[], help="Exact default-plan UI test selector")
    parser.add_argument("--mode", choices=("measure", "pr"), default="pr")
    parser.add_argument("--timeout-minutes", type=float, default=90)
    parser.add_argument("--total-timeout-minutes", type=float, help="Bound all Xcode calls in a shard together")
    parser.add_argument("--result-export-timeout-seconds", type=float, default=60, help="Bound each official result export")
    parser.add_argument("--wait-factor", type=float, default=1, help="Infrastructure test waits only; finite range [1, 4]")
    parser.add_argument("--listed-only-retry", action="store_true", help="Use only the trusted base known-flaky registry")
    parser.add_argument("--failure-screenshots", action="store_true", help="Export public fixture failure attachments before scanning")
    parser.add_argument("--shard")
    parser.add_argument("--shard-manifest", type=Path)
    parser.add_argument("--min-free-gib", type=int, default=80,
                        help="Disk guard; thresholds below 80 require a GitHub-hosted runner")
    args = parser.parse_args(argv)
    output = args.output_dir.resolve()
    code, service, bundle, digest, summary = 1, None, None, None, None
    rows = []
    bundles, digests = [], {}
    try:
        waits = wait_configuration(args.wait_factor)
        require(math.isfinite(args.timeout_minutes) and args.timeout_minutes > 0, "timeout must be finite and positive")
        require(math.isfinite(args.result_export_timeout_seconds) and args.result_export_timeout_seconds > 0,
                "result export timeout must be finite and positive")
        require(args.min_free_gib >= 0, "disk threshold must be non-negative")
        require((args.shard is None) == (args.shard_manifest is None), "shard and its manifest must be supplied together")
        require(args.total_timeout_minutes is None or (math.isfinite(args.total_timeout_minutes) and args.total_timeout_minutes > 0),
                "total timeout must be finite and positive")
        total_deadline = time.monotonic() + args.total_timeout_minutes * 60 if args.total_timeout_minutes else float("inf")
        require(ROOT != output and ROOT not in output.parents, "output must be outside the checkout")
        output.mkdir(parents=True, exist_ok=True, mode=0o700)
        require(not any(output.iterdir()), "output directory must be fresh")
        identity = run_identity(os.environ, ci=bool(os.environ.get("GITHUB_ACTIONS")))
        workflow, fork = source_metadata(identity, os.environ, None)
        summary = {"schema_version": 1, "identity": identity,
                   "source": {"repository": identity["repository"], "workflow_path": workflow,
                              "event": identity["event"], "fork_originated": fork, "ci_changing": None},
                   "run": {"id": os.environ.get("GITHUB_RUN_ID"), "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
                           "tier": "ui", "job": "ui-" + args.device if args.shard else "fixture-ui", "shard": args.shard or args.device},
                   "hashes": {"manifests": {}, "policies": {}}, "toolchain": toolchain(),
                   "population": {"declared": [], "compiled": [], "observed": [], "deselected": [], "removed_by_pr": []},
                   "infrastructure": [], "status": "failed"}
        summary["toolchain"]["versions"]["test_wait_factor"] = str(waits["infrastructure_factor"])
        write_json(output / "wait-configuration.json", waits)
        require(not os.path.lexists(ROOT / "Config/env.xcconfig"), "fixture mode forbids private configuration files or links")
        udid = destination_udid(args.destination)
        platform = DEVICES[args.device]
        expected_destination = "tvOS Simulator" if platform == "tvos" else "iOS Simulator"
        require(args.destination.startswith("platform=" + expected_destination + ","), "wrong simulator platform")
        inventory = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                                   capture_output=True, check=True, timeout=60)
        verify_simulator_device(json.loads(inventory.stdout), udid, args.device)
        plan_name = "immichSlides-" + ("tvOS" if platform == "tvos" else "iOS")
        plan = json.loads((ROOT / (plan_name + ".xctestplan")).read_text())
        ui_root = ROOT / "immichSlidesUITests"
        declared = declared_tests({path.relative_to(ui_root).as_posix(): path.read_text() for path in ui_root.rglob("*.swift")},
                                  platform, plan, args.only_testing)
        for entry in declared:
            entry["dimensions"]["device"] = args.device
        rows = coverage_rows(declared, None, {"testNodes": []}, args.device)
        policy_path = ROOT / "scripts/ci-test-policy.json"
        policy = parse_policy(policy_path.read_text())
        deselections = [entry for entry in policy["deselections"] if tier_approved(policy, "ui")
                       and entry["tier"] == "ui" and entry["environment"] == "fixture"
                       and entry["identity"] in declared] if args.mode == "pr" else []
        summary["hashes"] = {"manifests": {"fixture-c": fixture_manifest("c")["fixture_sha256"],
                                           "test-plan": hashlib.sha256((ROOT / (plan_name + ".xctestplan")).read_bytes()).hexdigest()},
                             "policies": {"test-policy": hashlib.sha256(policy_path.read_bytes()).hexdigest()}}
        if args.shard_manifest:
            summary["hashes"]["manifests"]["ui-shards"] = hashlib.sha256(args.shard_manifest.read_bytes()).hexdigest()
        summary["population"]["declared"] = declared
        summary["population"]["deselected"] = [
            {key: value for key, value in entry.items() if key not in {"tier", "environment"}} for entry in deselections]
        bundle = prepare_fixture_result_bundle()
        bundles.append(bundle)
        work = bundle.parent.parent
        env = clean_environment(os.environ)
        # Start fixtures during preflight, before spending time on a build.
        with (work / "service.log").open("wb") as log:
            service = subprocess.Popen([sys.executable, str(ROOT / "scripts/strict_e2e_server.py"), "--fixture-set", "c",
                                        "--host", "127.0.0.1", "--port", "0", "--ready-file", str(work / "ready.json"),
                                        "--log-file", str(work / "service-requests.log")],
                                       env=env, stdout=log, stderr=subprocess.STDOUT)
        host, port = wait_for_service(work / "ready.json", service)
        print(f"Fixture preflight ready: http://{host}:{port}/api (public set C)", flush=True)
        timeout = args.timeout_minutes * 60
        def execute(command, name):
            disk_check(args.min_free_gib)
            require(not os.path.lexists(ROOT / "Config/env.xcconfig"), "private configuration reappeared")
            print("Running " + name, flush=True)
            with (work / (name + ".log")).open("w") as log:
                process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                deadline = min(time.monotonic() + timeout, total_deadline)
                try:
                    while time.monotonic() < deadline:
                        try:
                            return process.wait(timeout=min(30, deadline - time.monotonic()))
                        except subprocess.TimeoutExpired:
                            print("Still running " + name, flush=True)
                    _stop_process_group(process, 15)
                    return 124
                except BaseException:
                    _stop_process_group(process, 15)
                    raise
        if args.xctestrun:
            source_run = args.xctestrun.resolve()
        else:
            derived = args.derived_data_path.resolve()
            require(not os.path.lexists(derived), "build needs fresh task DerivedData")
            code = execute(["xcodebuild", "build-for-testing", "-project", "immichSlides.xcodeproj", "-scheme", plan_name,
                            "-testPlan", plan_name, "-configuration", "Debug", "-destination", args.destination,
                            "-derivedDataPath", str(derived), "-disableAutomaticPackageResolution",
                            "-onlyUsePackageVersionsFromResolvedFile", "-parallel-testing-enabled", "NO",
                            "-only-testing:immichSlidesUITests"], "build")
            require(code == 0, "build failed with exit " + str(code))
            runs = list((derived / "Build/Products").glob("*.xctestrun"))
            require(len(runs) == 1, "expected one built test run")
            source_run = runs[0]
        apps = list(source_run.parent.glob("Debug-*simulator/immichSlides.app"))
        require(len(apps) == 1, "expected one Debug simulator app")
        check_products(source_run.parent)
        record_signing(summary, measure_signing(apps[0]))
        inputs = {"IMMICH_TEST_SERVER_URL": f"http://{host}:{port}/api", "IMMICH_TEST_API_KEY": PUBLIC_API_KEY,
                  "IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID": "album-c-exif",
                  "TEST_RUNNER_SCENE_PRESENTATION_CONTRACT_RUN_DIR": str(output / "scene-contracts")}
        inputs[FACTOR_ENVIRONMENT_KEY] = str(waits["infrastructure_factor"])
        run = prepare_test_run(source_run, work, inputs, failure_screenshots=args.failure_screenshots)
        base = ["xcodebuild", "test-without-building", "-xctestrun", str(run), "-destination", args.destination,
                "-derivedDataPath", str(work / "xcode-data"),
                "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]
        selections = ["-only-testing:immichSlidesUITests/" + entry["key"] for entry in declared]
        enumeration = output / "compiled-tests.json"
        code = execute(base + selections + ["-enumerate-tests", "-test-enumeration-style", "flat",
                       "-test-enumeration-format", "json", "-test-enumeration-output-path", str(enumeration),
                       "-resultBundlePath", str(work / "enumeration.xcresult")], "enumerate")
        require(code == 0, "compiled enumeration failed")
        summary["population"]["compiled"] = compiled_tests(json.loads(enumeration.read_text()), declared)
        rows = coverage_rows(declared, summary["population"]["compiled"], {"testNodes": []}, args.device)
        reset_simulator_app(udid)
        crash_directories = crash_report_directories()
        crash_reports_before = crash_report_snapshot(crash_directories)
        selected = [entry for entry in declared if not any(rule["identity"] == entry for rule in deselections)]
        compiled = [entry for entry in summary["population"]["compiled"] if entry in selected]
        command = base + selections + ["-resultBundlePath", str(bundle)] + [
            "-skip-testing:immichSlidesUITests/" + entry["identity"]["key"] for entry in deselections]
        print("Fixture test command: " + shlex.join(command), flush=True)
        registry, evaluated_on = None, None
        if args.listed_only_retry:
            revision = registry_revision(ROOT, os.environ)
            registry, registry_hash = load_registry(ROOT, revision)
            evaluated_on = date.today()
            summary["hashes"]["policies"]["known-flaky"] = registry_hash
            expected_by_key = {entry["key"]: entry for entry in selected}
            read = partial(read_xcode_observations, expected_device=(udid, "tv" if args.device == "appletv" else args.device),
                           export_timeout_seconds=args.result_export_timeout_seconds)
            def read_details(path, identity_for_key, elapsed, exit_code):
                observed = read(path, identity_for_key, elapsed, exit_code)
                try:
                    for item in observed:
                        if item["outcome"] in {"failed", "skipped"}:
                            message = read_problem_reason(path, item["identity"]["key"], export_timeout_seconds=args.result_export_timeout_seconds)
                            item["attempts"][0]["message"] = message
                            if item["outcome"] == "skipped":
                                item["attempts"][0]["reason"] = message
                except (ContractError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
                    raise OfficialResultReadError(error, observed) from error
                return observed
            reads = []
            def read_attempt(path, identity_for_key, elapsed, exit_code):
                started = time.monotonic()
                try:
                    return read_details(path, identity_for_key, elapsed, exit_code)
                finally:
                    reads.append({"attempt": len(reads) + 1, "elapsed_seconds": time.monotonic() - started})
                    write_json(output / "export-read-timing.json", {"schema_version": 1, "attempts": reads,
                               "timeout_seconds": args.result_export_timeout_seconds})
            def allocate():
                path = prepare_fixture_result_bundle()
                bundles.append(path)
                return path
            def attempt(call):
                started = time.monotonic()
                return execute(call, "test-" + str(len(bundles))), time.monotonic() - started
            retry_result = run_xcode_attempts(command, registry, tier="ui", environment="fixture", today=evaluated_on,
                identity_for_key=lambda key: expected_by_key[key], reset=lambda: reset_simulator_app(udid),
                execute=attempt, allocate_bundle=allocate, read=read_attempt)
            summary["population"]["observed"] = retry_result["observed"]
            summary["infrastructure"].extend(retry_result["infrastructure"])
            write_json(output / "retry-invocations.json", dict(retry_result, registry_revision=revision, registry_sha256=registry_hash))
            code = retry_result["exit_code"]
            invocation_codes = [invocation["exit_code"] for invocation in retry_result["invocations"]]
            if (not retry_result["infrastructure"] and retry_result["observed"]
                    and all(item["outcome"] in {"passed", "flaky-passed", "skipped"} for item in retry_result["observed"])
                    and (retry_result["invocations"][0]["exit_code"] == 0 or
                         (retry_result["invocations"][0]["exit_code"] == 65 and len(retry_result["invocations"]) > 1))):
                code = 0
            observed = {entry["identity"]["key"]: entry for entry in retry_result["observed"]}
            rows = [{"identity": entry, "device": args.device,
                     "outcome": observed[entry["key"]]["outcome"] if entry["key"] in observed else "not-run",
                     "duration_seconds": observed[entry["key"]]["duration_seconds"] if entry["key"] in observed else 0,
                     "reason": observed[entry["key"]]["attempts"][-1]["reason"] if entry["key"] in observed else "compiled but no official result"}
                    for entry in selected]
        else:
            code = execute(command, "test")
            invocation_codes = [code]
        if args.failure_screenshots and any(item != 0 for item in invocation_codes):
            # Lets a failure that left the app gone (home screen, failed termination) be told from a plain test failure.
            collected, omitted = collect_crash_reports(udid, crash_reports_before,
                                                       output / "failure-screenshots" / "crash-logs", crash_directories)
            print(f"Crash reports for this simulator: {len(collected)} collected, {len(omitted)} omitted", flush=True)
        for number, path in enumerate(bundles, 1):
            if not path.exists():
                continue
            suffix = "" if number == 1 else "-attempt-" + str(number)
            export_started = time.monotonic()
            digests[path] = export_private_result_bundle(path, output, [PUBLIC_API_KEY], suffix=suffix,
                summary_timeout_seconds=args.result_export_timeout_seconds, export_timeout_seconds=args.result_export_timeout_seconds)
            write_json(output / ("export-timing" + suffix + ".json"), {"schema_version": 1,
                "official_export_seconds": time.monotonic() - export_started, "timeout_seconds": args.result_export_timeout_seconds})
            official = json.loads((output / ("official-tests" + suffix + ".json")).read_text())
            verify_official_device(official, udid, args.device)
            if args.failure_screenshots:
                attachment_root = output / "failure-screenshots" / ("attempt-" + str(number))
                attachment_root.mkdir(parents=True, exist_ok=True)
                subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(path),
                                "--output-path", str(attachment_root), "--only-failures"],
                               capture_output=True, check=True, timeout=args.result_export_timeout_seconds)
        digest = digests.get(bundle)
        if not args.listed_only_retry:
            require(bundle in digests, "official fixture result is missing")
            rows = coverage_rows(selected, compiled, official, args.device)
            for row in rows:
                if row["outcome"] in {"skipped", "failed"}:
                    row["reason"] = read_problem_reason(bundle, row["identity"]["key"], export_timeout_seconds=args.result_export_timeout_seconds)
            summary["population"]["observed"] = [observation(row["identity"], row["outcome"], row["duration_seconds"],
                                                  reason=row["reason"], exit_code=0 if row["outcome"] == "passed" else None)
                                                 for row in rows]
        if code == 0:
            summary["status"] = "unverified" if any(row["outcome"] == "skipped" for row in rows) else "passed"
        measured_policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        verdict = evaluate_population(summary, declared, policy if args.mode == "pr" else measured_policy, environment="fixture",
                                      base_registry=registry, evaluated_on=evaluated_on)
        write_json(output / "coverage-verdict.json", verdict)
        summary["status"] = verdict["status"]
        if summary["status"] != "passed":
            code = code or 1
    except KeyboardInterrupt:
        code = 130
        if summary:
            summary["infrastructure"].append({"code": "interrupted", "message": "Fixture run interrupted"})
    except (OSError, ValueError, TypeError, KeyError, CommandError, OfflineCommandError, subprocess.SubprocessError) as error:
        code = code or 1
        print(f"Fixture UI failed: {error}", file=sys.stderr)
        if summary:
            summary["infrastructure"].append({"code": "xcresult-export-timeout" if isinstance(error, subprocess.TimeoutExpired)
                                               and "xcresulttool" in str(error.cmd) else "fixture-run-failed", "message": str(error)[:200]})
    finally:
        if service:
            try:
                stop_exact_process(service)
            except (OSError, subprocess.SubprocessError):
                code = code or 1
                if summary:
                    summary["infrastructure"].append({"code": "cleanup-failed", "message": "Fixture server cleanup failed"})
        if summary:
            if code:
                summary["status"] = "failed"
            write_json(output / "fixture-coverage.json", {"schema_version": 1, "device": args.device, "tests": rows,
                       "covered_selectors": ["immichSlidesUITests/" + row["identity"]["key"] for row in rows
                                             if row["outcome"] == "passed"]})
            table = "| Test | Device | Outcome | Seconds | Reason |\n|---|---|---|---:|---|\n"
            table += "".join(f"| `{row['identity']['key']}` | {args.device} | {row['outcome']} | "
                             f"{row['duration_seconds']:.2f} | {(row['reason'] or '').replace('|', '/').replace(chr(10), ' ')} |\n"
                             for row in rows)
            (output / "fixture-coverage.md").write_text(table)
            write_summary(summary, output)
            try:
                write_sensitive_scan(output, [PUBLIC_API_KEY])
            except (OSError, ValueError, CommandError) as error:
                code = code or 1
                summary["status"] = "failed"
                summary["infrastructure"].append({"code": "sensitive-scan-failed", "message": str(error)[:200]})
                write_summary(summary, output)
            failures = []
            for number, path in reversed(list(enumerate(bundles, 1))):
                disposal_output = output if number == 1 else output / ("disposal-attempt-" + str(number))
                disposal_output.mkdir(exist_ok=True)
                failures.extend(finalize_fixture_run(path, disposal_output, digests.get(path), successful=code == 0))
            if failures:
                code = code or 1
                summary["status"] = "failed"
                summary["infrastructure"].append({"code": "cleanup-failed", "message": "Private bundle disposal failed"})
                write_summary(summary, output)
            print(f"Fixture UI: {summary['status']} ({len(rows)} per-test rows), exit {code}", flush=True)
    return code


if __name__ == "__main__":
    from ci_local import local_main
    raise SystemExit(local_main(main, __file__))
