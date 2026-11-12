"""Trusted short-flow manifest and first-result-only smoke execution."""

from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

MANIFEST = "scripts/smoke-flows.json"
FLOW_TIMEOUT_SECONDS = 180


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"smoke-manifest-shape: duplicate JSON key {key}")
        value[key] = item
    return value


def validate_manifest(manifest, planned, methods=None):
    """Fail closed on population, execution metadata and compiled-selector drift."""
    if (not isinstance(manifest, dict) or set(manifest) != {"schema_version", "flows"}
            or type(manifest["schema_version"]) is not int or manifest["schema_version"] != 1
            or not isinstance(manifest["flows"], list)):
        raise ValueError("smoke-manifest-shape: expected schema_version 1 and flows array")
    expected = {flow["id"]: flow for flow in planned}
    errors, seen = [], set()
    for flow in manifest["flows"]:
        if (not isinstance(flow, dict)
                or set(flow) != {"id", "platform", "device", "configuration", "fixtures", "selector"}
                or not isinstance(flow.get("id"), str)):
            errors.append("smoke-manifest-shape: invalid flow fields")
            continue
        key = flow["id"]
        if key in seen:
            errors.append(f"smoke-manifest-population: duplicate {key}")
        seen.add(key)
        source = expected.get(key)
        if source is None:
            errors.append(f"smoke-manifest-population: unknown {key}")
            continue
        platform = "tvos" if source["device"] == "tv" else "ios"
        fixtures = [source["fixture"]] + ([source["peer_fixture"]] if "peer_fixture" in source else [])
        for field, value in (("device", source["device"]), ("platform", platform),
                             ("configuration", source["configuration"]), ("fixtures", fixtures)):
            if flow[field] != value:
                errors.append(f"smoke-manifest-mapping: {key} {field} must be {value!r}")
        selector = flow["selector"]
        if (not isinstance(selector, str) or len(selector.split("/")) != 2
                or methods is not None and platform not in methods.get(selector, set())):
            errors.append(f"smoke-manifest-selector: {key} {selector!r} is not compiled for {platform}")
    for key in sorted(expected.keys() - seen):
        errors.append(f"smoke-manifest-population: missing {key}")
    if errors:
        raise ValueError("\n".join(errors))
    return manifest["flows"]


def load_manifest(root):
    from ui_test_inventory import parse_ui_tests
    manifest = json.loads((root / MANIFEST).read_text(), object_pairs_hook=unique_object)
    planned = json.loads((root / "scripts/ci-test-tiers.json").read_text(), object_pairs_hook=unique_object)["smoke_flows"]
    _, classes, errors, _ = parse_ui_tests({path.relative_to(root).as_posix(): path.read_text()
                                          for path in (root / "immichSlidesUITests").rglob("*.swift")})
    if errors:
        raise ValueError("smoke-manifest-selector: " + "; ".join(errors))
    methods = {f"{name}/{method}": platforms for name, entries in classes.items()
               for method, platforms in entries.items()}
    return manifest, planned, methods


def write_json(path, payload):
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def official_flow_complete(selector, summary, tests):
    nodes = []
    def visit(node):
        if isinstance(node, dict):
            if node.get("nodeType") == "Test Case":
                nodes.append(node)
            for child in node.get("children", []):
                visit(child)
    for node in tests.get("testNodes", []):
        visit(node)
    counts = [summary.get(field) for field in ("totalTestCount", "passedTests", "failedTests", "skippedTests")]
    return (len(nodes) == 1 and nodes[0].get("nodeIdentifier", "").removesuffix("()") == selector
            and all(type(count) is int for count in counts)
            and ((counts == [1, 1, 0, 0] and summary.get("result") == nodes[0].get("result") == "Passed")
                 or (counts == [1, 0, 1, 0] and summary.get("result") == nodes[0].get("result") == "Failed")))


def official_flow_passed(selector, summary, tests):
    return official_flow_complete(selector, summary, tests) and summary["result"] == "Passed"


def select_flows(flows, device, configuration, flow_id=None):
    selected = [flow for flow in flows if flow["device"] == device and flow["configuration"] == configuration
                and (flow_id is None or flow["id"] == flow_id)]
    if not selected:
        raise ValueError("smoke-flow selection is empty or the requested flow belongs to another device/configuration")
    return selected


def run(arguments, root, runner, stdout, stderr):
    """Reuse strict privacy/reset/export contracts without legacy visual judges or retries."""
    from strict_e2e_build import load_warm_build, validate_paths, validate_warm_products, warm_up
    from strict_e2e_server import PUBLIC_API_KEY

    if (not arguments.smoke_device or not arguments.configuration
            or (arguments.platform == "tvos") != (arguments.smoke_device == "tv")):
        raise runner.CommandError("smoke-flow requires a matching --smoke-device and explicit --configuration")
    if (arguments.listed_retry_device or arguments.nightly_retry_method or arguments.nightly_retry_source
            or arguments.scenario != "normal" or arguments.fixture_set != "a"):
        raise runner.CommandError("smoke-flow accepts no retry, scenario or fixture overrides")
    manifest, planned, methods = load_manifest(root)
    flows = validate_manifest(manifest, planned)
    selected = select_flows(flows, arguments.smoke_device, arguments.configuration, arguments.smoke_flow)
    for flow in selected:
        if arguments.platform not in methods.get(flow["selector"], set()):
            raise runner.CommandError(f"smoke-manifest-selector: {flow['id']} is not compiled for {arguments.platform}")
    runner.ensure_disk_for_xcodebuild(runner.data_available_gib, arguments.min_free_gib)
    udid = runner.destination_udid(arguments.destination)
    if "Simulator" not in arguments.destination:
        raise runner.CommandError("smoke-flow only accepts Simulator destinations")
    from ci_flaky import simulator_device_class
    simulator_device_class(udid, arguments.smoke_device)
    runner.prepare_evidence_directory(arguments.evidence_dir)
    evidence = arguments.evidence_dir.resolve()
    owned_derived = None
    derived = arguments.derived_data_path
    if derived is None:
        owned_derived = Path(tempfile.mkdtemp(prefix="immichslides-smoke-build-"))
        derived = owned_derived / "DerivedData"
    derived = derived.resolve()
    packages = (arguments.cloned_source_packages_path or derived.parent / "SourcePackages").resolve()
    validate_paths(root, derived, evidence, packages)
    try:
        if not arguments.test_without_building:
            warm_up(root=root, platform=arguments.platform, suite="smoke-flow", configuration=arguments.configuration,
                    destination=arguments.destination, derived=derived, packages=packages, evidence=evidence,
                    timeout=arguments.cold_timeout_seconds, execute=runner.run_command)
        if arguments.warm_up_only:
            runner.write_sensitive_scan(evidence, [PUBLIC_API_KEY, runner.WRONG_PUBLIC_API_KEY])
            return 0
        receipt, source_run = load_warm_build(root, arguments.platform, "smoke-flow", arguments.configuration,
                                              arguments.destination, derived)
        records = []
        case = {"source_sha": runner.read_source_sha(root), "platform": arguments.platform,
                "suite": "smoke-flow", "scenario": "normal", "fixture_set": "a",
                "os": "iOS Simulator" if arguments.platform == "ios" else "tvOS Simulator", "e2e_ids": [],
                "device": arguments.smoke_device, "configuration": arguments.configuration,
                "selection": "single-flow" if arguments.smoke_flow else "group",
                "destination": arguments.destination, "warm_build_identity": receipt["identity"],
                "human_review": "NOT_RUN", "result": "RUNNING", "flows": records}
        runner.write_case_manifest(evidence, case)
        code = 0
        for flow in selected:
            record = execute_flow(flow, root, arguments, source_run, runner, evidence)
            records.append(record)
            code = code or record["exit_code"]
            runner.write_case_manifest(evidence, case)
            write_json(evidence / "smoke-flow-results.json", {"schema_version": 1, "source_sha": case["source_sha"],
                "selection": case["selection"], "flows": records})
            print(f"{flow['id']}: {record['outcome']} ({record['elapsed_seconds']:.3f}s)", file=stdout, flush=True)
        validate_warm_products(derived, receipt)
        summaries = [json.loads((evidence / flow["id"] / "official-summary.json").read_text())
                     for flow in selected if (evidence / flow["id"] / "official-summary.json").is_file()]
        summary = {field: sum(item[field] for item in summaries)
                   for field in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
        summary["result"] = "Passed" if code == 0 and len(summaries) == len(selected) else "Failed"
        write_json(evidence / "official-summary.json", summary)
        tests = {"testNodes": [node for flow in selected
                 if (evidence / flow["id"] / "official-tests.json").is_file()
                 for node in json.loads((evidence / flow["id"] / "official-tests.json").read_text()).get("testNodes", [])]}
        write_json(evidence / "official-tests.json", tests)
        case["official_tests_sha256"] = hashlib.sha256((evidence / "official-tests.json").read_bytes()).hexdigest()
        case.update(result="Passed" if code == 0 else "FAILED", exit_code=code, official_summary=summary)
        runner.write_case_manifest(evidence, case)
        runner.write_sensitive_scan(evidence, [PUBLIC_API_KEY, runner.WRONG_PUBLIC_API_KEY])
        return code
    finally:
        if owned_derived is not None:
            shutil.rmtree(owned_derived)


def execute_flow(flow, root, arguments, source_run, runner, evidence):
    from strict_e2e_build import prepare_test_run, warm_test_command
    from strict_e2e_server import PUBLIC_API_KEY
    directory = evidence / flow["id"]
    directory.mkdir()
    started = time.monotonic()
    record = {"id": flow["id"], "selector": flow["selector"], "outcome": "FAIL",
              "source_sha": runner.read_source_sha(root), "failure_kind": "infrastructure",
              "official_execution_complete": False, "official_summary": None, "official_tests_sha256": None,
              "elapsed_seconds": 0, "first_public_failure_message": None, "exit_code": 2}
    private_evidence = directory / "private"
    private_evidence.mkdir(mode=0o700)
    processes, private_run, bundle, digest = [], None, None, None
    exported, summary, fixture_payload = False, None, None
    stage = "infrastructure"
    try:
        reset = runner.reset_simulator_app(runner.destination_udid(arguments.destination), platform=arguments.platform,
                                           boot_submitted=arguments.simulator_boot_submitted)
        (directory / "simulator-reset.log").write_text(reset)
        urls = []
        for fixture in flow["fixtures"]:
            ready = directory / f"service-{fixture}-ready.json"
            startup = directory / f"service-{fixture}-startup.log"
            with startup.open("wb") as output:
                process = subprocess.Popen([sys.executable, str(root / "scripts/strict_e2e_server.py"),
                    "--host", "127.0.0.1", "--port", "0", "--fixture-set", fixture, "--scenario", "normal",
                    "--ready-file", str(ready), "--log-file", str(private_evidence / f"service-{fixture}.log")],
                    cwd=root, stdout=output, stderr=subprocess.DEVNULL)
            processes.append(process)
            host, port = runner.wait_for_service(ready, process, startup_log=startup)
            urls.append(f"http://{host}:{port}/api")
        fixture_payload = runner.write_fixture_artifacts(directory, "a")
        environment = runner.make_test_environment(os.environ, server_url=urls[0], public_key=PUBLIC_API_KEY,
                                                   server_url_b=urls[1] if len(urls) == 2 else None)
        environment["STRICT_E2E_EVIDENCE_DIR"] = str(directory)
        bundle = runner.prepare_private_result_bundle_path("smoke-flow")
        private_run = prepare_test_run(source_run, bundle.parent / "run", environment)
        command = warm_test_command(private_run, arguments.destination, bundle,
                                    "immichSlidesUITests/" + flow["selector"])
        command += ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", str(FLOW_TIMEOUT_SECONDS),
                    "-maximum-test-execution-time-allowance", str(FLOW_TIMEOUT_SECONDS)]
        execution_started = time.monotonic()
        try:
            code = runner.run_command(command, cwd=root, environment=environment, log_path=directory / "xcodebuild.log",
                                       timeout_seconds=FLOW_TIMEOUT_SECONDS)
        except runner.CommandError as error:
            record["failure_kind"] = "hang-guard"
            record["first_public_failure_message"] = "Smoke flow execution exceeded its hang guard."
            raise runner.CommandError(str(error), code=124) from error
        finally:
            record["elapsed_seconds"] = round(time.monotonic() - execution_started, 3)
        budget = runner.OfficialExportBudget()
        stage = "official-result"
        digest = runner.export_private_result_bundle(bundle, directory, [PUBLIC_API_KEY, runner.WRONG_PUBLIC_API_KEY],
                                                     export_budget=budget, enrich_failure_diagnostics=True)
        exported = True
        summary = json.loads((directory / "official-summary.json").read_text())
        public_tests = json.loads((directory / "official-tests.json").read_text())
        failures = []
        def visit(node):
            if isinstance(node, dict):
                if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
                    failures.extend(node.get("failure_messages", []))
                for child in node.get("children", []):
                    visit(child)
        for node in public_tests.get("testNodes", []):
            visit(node)
        if failures:
            record["first_public_failure_message"] = failures[0]
        record["official_execution_complete"] = official_flow_complete(flow["selector"], summary, public_tests)
        record["official_summary"], record["official_tests_sha256"] = summary, digest
        record["exit_code"] = code or (0 if official_flow_passed(flow["selector"], summary, public_tests) else 2)
        record["outcome"] = "PASS" if record["exit_code"] == 0 else "FAIL"
        record["failure_kind"] = ("none" if record["outcome"] == "PASS" else
            "test" if record["official_execution_complete"] and summary["failedTests"] == 1 else
            "infrastructure" if record["official_execution_complete"] else "official-result")
    except (runner.CommandError, ValueError, OSError, subprocess.SubprocessError) as error:
        record["exit_code"] = getattr(error, "code", 2)
        if record["failure_kind"] != "hang-guard":
            record["failure_kind"] = stage
        record["first_public_failure_message"] = record["first_public_failure_message"] or "Smoke flow infrastructure or official-result validation failed."
        print(f"{flow['id']}: {type(error).__name__}: {error}", file=sys.stderr)
    finally:
        for process in processes:
            runner.stop_exact_process(process)
        if private_run is not None:
            shutil.rmtree(private_run.parent)
        if bundle is not None:
            cleanup = runner.finalize_private_result_bundle(bundle, directory, digest,
                                                            successful=exported and record["exit_code"] == 0)
            if cleanup:
                record.update(outcome="FAIL", exit_code=2, failure_kind="cleanup")
        record["request_logs"] = {}
        for fixture in flow["fixtures"]:
            path = private_evidence / f"service-{fixture}.log"
            try:
                payload = path.read_bytes()
                path.chmod(0o600)
                record["request_logs"][fixture] = {"state": "present", "bytes": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "request_count": sum(line.startswith(b"request ") for line in payload.splitlines())}
            except OSError:
                record["request_logs"][fixture] = {"state": "unavailable", "bytes": None,
                    "sha256": None, "request_count": None}
        record["total_elapsed_seconds"] = round(time.monotonic() - started, 3)
        write_json(directory / "case-manifest.json", {"source_sha": runner.read_source_sha(root),
            "platform": arguments.platform, "suite": "smoke-flow", "flow": record,
            "destination": arguments.destination, "scenario": "normal", "fixture_set": "a",
            "configuration": arguments.configuration, "human_review": "NOT_RUN",
            "fixture_sha256": fixture_payload["fixture_sha256"] if fixture_payload else None,
            "official_tests_sha256": digest, "official_summary": summary,
            "result": "Passed" if record["exit_code"] == 0 else "FAILED", "exit_code": record["exit_code"]})
    return record
