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
import subprocess
import sys
import time
from pathlib import Path

from ci_build_archive import check_products, measure_signing, record_signing
from ci_population import ui_identities
from ci_summary import ContractError, observation, require, write_summary
from ci_verdict import evaluate_population, parse_policy
from run_host_checks import run_identity, source_metadata, toolchain
from run_offline_unit_tests import (CommandError as OfflineCommandError, _stop_process_group,
                                    default_data_available_gib, ensure_disk_for_xcodebuild)
from run_strict_e2e import (export_private_result_bundle, finalize_private_result_bundle,
                            prepare_private_result_bundle_path, write_sensitive_scan)
from strict_e2e_runner_support import CommandError, destination_udid, reset_simulator_app, stop_exact_process, wait_for_service
from strict_e2e_server import PUBLIC_API_KEY, fixture_manifest
from access_lifecycle_contract import logical_bytes_contain

ROOT = Path(__file__).resolve().parent.parent
DEVICES = {"iphone": "ios", "ipad": "ios", "appletv": "tvos"}


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
    targets = [target for target in plan["testTargets"] if target["target"]["name"] == "immichSlidesUITests"]
    require(len(targets) == 1, "default plan must have exactly one UI target")
    excluded = [item.removesuffix("()") for item in targets[0].get("skippedTests", [])]
    def selected(key):
        return not any(key == item or key.startswith(item + "/") for item in excluded)
    declared = [entry for entry in ui_identities(files, platform) if selected(entry["key"])]
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
    compiled_keys = {entry["key"] for entry in compiled}
    require(len(compiled_keys) == len(compiled), "duplicate compiled identity")
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
                              "duration_seconds": 0, "reason": "not compiled" if key not in compiled_keys
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


def read_problem_reason(bundle, key):
    completed = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "test-details", "--path", str(bundle),
                                "--test-id", key + "()", "--compact"], capture_output=True, check=False, timeout=60)
    require(completed.returncode == 0, "official problem detail export failed")
    require(not logical_bytes_contain(completed.stdout, [PUBLIC_API_KEY]), "official problem detail contains credentials")
    return problem_reason(json.loads(completed.stdout), key)


def prepare_test_run(source, directory, inputs):
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
    path = directory / "fixture.xctestrun"
    path.write_bytes(plistlib.dumps(payload))
    return path


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
    args = parser.parse_args(argv)
    output = args.output_dir.resolve()
    code, service, bundle, digest, summary = 1, None, None, None, None
    rows = []
    try:
        require(math.isfinite(args.timeout_minutes) and args.timeout_minutes > 0, "timeout must be finite and positive")
        require(ROOT != output and ROOT not in output.parents, "output must be outside the checkout")
        output.mkdir(parents=True, exist_ok=True, mode=0o700)
        require(not any(output.iterdir()), "output directory must be fresh")
        identity = run_identity(os.environ, ci=bool(os.environ.get("GITHUB_ACTIONS")))
        workflow, fork = source_metadata(identity, os.environ, None)
        summary = {"schema_version": 1, "identity": identity,
                   "source": {"repository": identity["repository"], "workflow_path": workflow,
                              "event": identity["event"], "fork_originated": fork, "ci_changing": None},
                   "run": {"id": os.environ.get("GITHUB_RUN_ID"), "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
                           "tier": "ui", "job": "fixture-ui", "shard": args.device},
                   "hashes": {"manifests": {}, "policies": {}}, "toolchain": toolchain(),
                   "population": {"declared": [], "compiled": [], "observed": [], "deselected": [], "removed_by_pr": []},
                   "infrastructure": [], "status": "failed"}
        require(not os.path.lexists(ROOT / "Config/env.xcconfig"), "fixture mode forbids private configuration files or links")
        udid = destination_udid(args.destination)
        platform = DEVICES[args.device]
        expected_destination = "tvOS Simulator" if platform == "tvos" else "iOS Simulator"
        require(args.destination.startswith("platform=" + expected_destination + ","), "wrong simulator platform")
        plan_name = "immichSlides-" + ("tvOS" if platform == "tvos" else "iOS")
        plan = json.loads((ROOT / (plan_name + ".xctestplan")).read_text())
        ui_root = ROOT / "immichSlidesUITests"
        declared = declared_tests({path.relative_to(ui_root).as_posix(): path.read_text() for path in ui_root.rglob("*.swift")},
                                  platform, plan, args.only_testing)
        for entry in declared:
            entry["dimensions"]["device"] = args.device
        rows = coverage_rows(declared, [], {"testNodes": []}, args.device)
        policy_path = ROOT / "scripts/ci-test-policy.json"
        policy = parse_policy(policy_path.read_text())
        deselections = [entry for entry in policy["deselections"] if policy["approval_state"] == "approved"
                       and entry["tier"] == "ui" and entry["environment"] == "fixture"
                       and entry["identity"] in declared] if args.mode == "pr" else []
        summary["hashes"] = {"manifests": {"fixture-c": fixture_manifest("c")["fixture_sha256"],
                                           "test-plan": hashlib.sha256((ROOT / (plan_name + ".xctestplan")).read_bytes()).hexdigest()},
                             "policies": {"test-policy": hashlib.sha256(policy_path.read_bytes()).hexdigest()}}
        summary["population"]["declared"] = declared
        summary["population"]["deselected"] = [
            {key: value for key, value in entry.items() if key not in {"tier", "environment"}} for entry in deselections]
        bundle = prepare_private_result_bundle_path("fixture-ui")
        env = clean_environment(os.environ)
        timeout = args.timeout_minutes * 60
        def execute(command, name):
            subprocess.run(["df", "-h", "/System/Volumes/Data"], check=True)
            ensure_disk_for_xcodebuild(min_free_gib=80, data_available_gib=default_data_available_gib)
            require(not os.path.lexists(ROOT / "Config/env.xcconfig"), "private configuration reappeared")
            print("Running " + name, flush=True)
            with (bundle.parent / (name + ".log")).open("w") as log:
                process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                deadline = time.monotonic() + timeout
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
        with (bundle.parent / "service.log").open("wb") as log:
            service = subprocess.Popen([sys.executable, str(ROOT / "scripts/strict_e2e_server.py"), "--fixture-set", "c",
                                        "--host", "127.0.0.1", "--port", "0", "--ready-file", str(bundle.parent / "ready.json"),
                                        "--log-file", str(bundle.parent / "service-requests.log")],
                                       env=env, stdout=log, stderr=subprocess.STDOUT)
        host, port = wait_for_service(bundle.parent / "ready.json", service)
        inputs = {"IMMICH_TEST_SERVER_URL": f"http://{host}:{port}/api", "IMMICH_TEST_API_KEY": PUBLIC_API_KEY,
                  "IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID": "album-c-exif",
                  "TEST_RUNNER_SCENE_PRESENTATION_CONTRACT_RUN_DIR": str(output / "scene-contracts")}
        run = prepare_test_run(source_run, bundle.parent, inputs)
        base = ["xcodebuild", "test-without-building", "-xctestrun", str(run), "-destination", args.destination,
                "-derivedDataPath", str(bundle.parent / "xcode-data"),
                "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]
        selections = ["-only-testing:immichSlidesUITests/" + entry["key"] for entry in declared]
        enumeration = output / "compiled-tests.json"
        code = execute(base + selections + ["-enumerate-tests", "-test-enumeration-style", "flat",
                       "-test-enumeration-format", "json", "-test-enumeration-output-path", str(enumeration),
                       "-resultBundlePath", str(bundle.parent / "enumeration.xcresult")], "enumerate")
        require(code == 0, "compiled enumeration failed")
        summary["population"]["compiled"] = compiled_tests(json.loads(enumeration.read_text()), declared)
        reset_simulator_app(udid)
        code = execute(base + selections + ["-resultBundlePath", str(bundle)] +
                       ["-skip-testing:immichSlidesUITests/" + entry["identity"]["key"] for entry in deselections], "test")
        digest = export_private_result_bundle(bundle, output, [PUBLIC_API_KEY])
        selected = [entry for entry in declared if not any(rule["identity"] == entry for rule in deselections)]
        compiled = [entry for entry in summary["population"]["compiled"] if entry in selected]
        rows = coverage_rows(selected, compiled, json.loads((output / "official-tests.json").read_text()), args.device)
        for row in rows:
            if row["outcome"] in {"skipped", "failed"}:
                row["reason"] = read_problem_reason(bundle, row["identity"]["key"])
        summary["population"]["observed"] = [observation(row["identity"], row["outcome"], row["duration_seconds"],
                                              reason=row["reason"], exit_code=0 if row["outcome"] == "passed" else None)
                                             for row in rows]
        if code == 0:
            summary["status"] = "unverified" if any(row["outcome"] == "skipped" for row in rows) else "passed"
        measured_policy = {"schema_version": 1, "approval_state": "approved", "expected_skips": [], "deselections": []}
        verdict = evaluate_population(summary, declared, policy if args.mode == "pr" else measured_policy, environment="fixture")
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
            summary["infrastructure"].append({"code": "fixture-run-failed", "message": str(error)[:200]})
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
            failures = finalize_private_result_bundle(bundle, output, digest, successful=code == 0) if bundle else []
            if failures:
                code = code or 1
                summary["status"] = "failed"
                summary["infrastructure"].append({"code": "cleanup-failed", "message": "Private bundle disposal failed"})
                write_summary(summary, output)
            if code == 0 and bundle and bundle.parent.exists():
                import shutil
                shutil.rmtree(bundle.parent)
            print(f"Fixture UI: {summary['status']} ({len(rows)} per-test rows), exit {code}", flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
