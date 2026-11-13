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
# XCTest rounds method allowances up to whole minutes.
METHOD_TIMEOUT_SECONDS = 120
STARTUP_OVERHEAD_SECONDS = 150
FLOW_TIMEOUT_SECONDS = METHOD_TIMEOUT_SECONDS + STARTUP_OVERHEAD_SECONDS
FLOW_METHODS = {
    "album-selection": "testAlbumSelection", "background-return": "testBackgroundReturn",
    "connection-error": "testConnectionError", "first-boot": "testFirstBoot",
    "person-return": "testPersonReturn", "pin-gate": "testPinGate",
    "playback-controls": "testPlaybackControls", "settings-relaunch": "testSettingsRelaunch",
    "rotation": "testRotation", "settings-sidebar": "testSettingsSidebar",
    "directional-wake": "testDirectionalWake", "pause-resume": "testPauseResume",
    "person-selection": "testPersonSelection", "server-switch": "testServerSwitch",
}


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"smoke-manifest-shape: duplicate JSON key {key}")
        value[key] = item
    return value


def validate_manifest(manifest, planned, methods=None, inventory=None):
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
        expected_selector = ("SmokeFlowTVOSUITests" if platform == "tvos" else "SmokeFlowIOSUITests")
        expected_selector += "/" + FLOW_METHODS.get(key.partition("-")[2], "<unknown>")
        if selector != expected_selector:
            errors.append(f"smoke-manifest-binding: {key} must select {expected_selector}")
        if (not isinstance(selector, str) or len(selector.split("/")) != 2
                or methods is not None and platform not in methods.get(selector, set())):
            errors.append(f"smoke-manifest-selector: {key} {selector!r} is not compiled for {platform}")
        if inventory is not None:
            rows = [row for row in inventory if row.get("kind") == "ui" and row.get("identifier") == selector]
            if len(rows) != 1 or rows[0].get("target_home") != "smoke" or key not in rows[0].get("smoke_flows", []):
                errors.append(f"smoke-manifest-inventory: {key} requires one matching smoke UI row")
    if inventory is not None:
        for row in inventory:
            selector = row.get("identifier", "")
            if selector.partition("/")[0] not in {"SmokeFlowIOSUITests", "SmokeFlowTVOSUITests"}:
                continue
            mapped = [flow["id"] for flow in manifest["flows"] if flow.get("selector") == selector]
            if (not mapped or row.get("kind") != "ui" or row.get("target_home") != "smoke"
                    or sorted(row.get("smoke_flows", [])) != sorted(mapped)):
                errors.append(f"smoke-manifest-inventory: {selector} reverse mapping differs")
    for key in sorted(expected.keys() - seen):
        errors.append(f"smoke-manifest-population: missing {key}")
    if errors:
        raise ValueError("\n".join(errors))
    return manifest["flows"]


def validate_exclusions(flows, methods, plans):
    """Evaluate actual plan populations, including class and method selections."""
    from ci_ui_shards import default_plan_population
    for platform in ("ios", "tvos"):
        population = [{"key": selector} for selector, platforms in methods.items() if platform in platforms]
        smoke = {flow["selector"] for flow in flows if flow["platform"] == platform}
        for name, plan in plans[platform].items():
            leaked = smoke & {entry["key"] for entry in default_plan_population(population, plan)}
            if leaked:
                raise ValueError(f"smoke-manifest-exclusion: {name} includes {sorted(leaked)!r}")


def validate_group_evidence(evidence, flows, device, configuration, *, expected_source_sha):
    """Return complete ordered first-result records, or fail closed for shadow consumers."""
    evidence = Path(evidence)
    case = json.loads((evidence / "case-manifest.json").read_text())
    result = json.loads((evidence / "smoke-flow-results.json").read_text())
    selected = select_flows(flows, device, configuration)
    for payload in (case, result):
        if (payload.get("selection") != "group" or payload.get("result") != "Passed"
                or type(payload.get("exit_code")) is not int or payload["exit_code"] != 0
                or payload.get("source_dirty_paths") != [] or payload.get("device") != device
                or payload.get("configuration") != configuration or payload.get("group_failures", []) != []):
            raise ValueError("smoke-group-evidence: group verdict, selection, source state or device differs")
    sha = case.get("source_sha")
    if not isinstance(sha, str) or len(sha) != 40 or any(c not in "0123456789abcdef" for c in sha):
        raise ValueError("smoke-group-evidence: invalid source SHA")
    if result.get("source_sha") != sha or sha != expected_source_sha:
        raise ValueError("smoke-group-evidence: source SHA differs")
    records = result.get("flows", [])
    if ([record.get("id") for record in records] != [flow["id"] for flow in selected]
            or case.get("flows") != records):
        raise ValueError("smoke-group-evidence: ordered flow population differs")
    for flow, record in zip(selected, records):
        directory = evidence / flow["id"]
        summary = json.loads((directory / "official-summary.json").read_text())
        tests_path = directory / "official-tests.json"
        tests = json.loads(tests_path.read_text())
        if (record.get("selector") != flow["selector"] or record.get("source_sha") != sha
                or record.get("source_dirty_paths") != [] or record.get("outcome") != "PASS"
                or type(record.get("exit_code")) is not int or record["exit_code"] != 0
                or record.get("official_execution_complete") is not True
                or record.get("failure_kind") != "none" or record.get("official_summary") != summary
                or record.get("official_tests_sha256") != hashlib.sha256(tests_path.read_bytes()).hexdigest()
                or not official_flow_passed(flow["selector"], summary, tests)):
            raise ValueError(f"smoke-group-evidence: incomplete or failed {flow['id']}")
    return records


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


def fail_gate_flows(evidence, records, gate):
    """Keep flow verdicts consistent with the evidence gate that invalidated them."""
    affected = {record["id"] for record in records}
    if gate == "sensitive-scan":
        try:
            matched = json.loads((evidence / "sensitive-scan.json").read_text())["matched_files"]
            owners = [Path(path).parts[0] if isinstance(path, str) and path and not Path(path).is_absolute()
                      and ".." not in Path(path).parts else None for path in matched]
            if owners and all(owner in affected for owner in owners):
                affected = set(owners)
        except (OSError, ValueError, KeyError, TypeError, IndexError):
            pass  # An unlocalised privacy failure invalidates the whole group.
    for record in records:
        if record["id"] in affected and record["outcome"] == "PASS":
            record.update(outcome="FAIL", exit_code=2, failure_kind=gate)
    for record in records:
        if record["id"] in affected:
            path = evidence / record["id"] / "case-manifest.json"
            case = json.loads(path.read_text())
            case.update(flow=record, result="FAILED", exit_code=record["exit_code"])
            write_json(path, case)
    return {"failure_kind": gate, "exit_code": 2,
            "flow_ids": [record["id"] for record in records if record["id"] in affected]}


def record_cleanup_failure(evidence, details):
    """Record a local launcher's late cleanup failure without replacing first native failures."""
    evidence = Path(evidence)
    case = json.loads((evidence / "case-manifest.json").read_text())
    result = json.loads((evidence / "smoke-flow-results.json").read_text())
    if case.get("suite") != "smoke-flow":
        raise ValueError("cleanup evidence is not a smoke-flow group")
    records = result["flows"]
    gate = {"failure_kind": "cleanup", "exit_code": 2, "flow_ids": [record["id"] for record in records],
            "phase": details["phase"], "error_type": details["error_type"],
            "retained_snapshot": details["retained_path"] is not None}
    for payload, name in ((case, "case-manifest.json"), (result, "smoke-flow-results.json")):
        payload.update(result="FAILED", exit_code=2, flows=records)
        payload.setdefault("group_failures", []).append(gate)
        if isinstance(payload.get("official_summary"), dict):
            payload["official_summary"]["result"] = "Failed"
        write_json(evidence / name, payload)
    # Invalidate roots before per-flow writes that could themselves fail.
    fail_gate_flows(evidence, records, "cleanup")
    write_json(evidence / "case-manifest.json", case)
    write_json(evidence / "smoke-flow-results.json", result)
    summary_path = evidence / "official-summary.json"
    if summary_path.is_file():
        summary = json.loads(summary_path.read_text())
        summary["result"] = "Failed"
        write_json(summary_path, summary)


def flow_failure_locations(tests, selector, source_roots):
    """Project only reviewed relative source coordinates from the selected official failure."""
    from ci_bounded_diagnostics import MAX_FAILURE_LOCATIONS, public_failure_locations
    locations = []
    roots = {Path(root).resolve() for root in source_roots if isinstance(root, (str, Path))}
    def visit(node, selected=False):
        if not isinstance(node, dict):
            return
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier")
            selected = node.get("result") == "Failed" and isinstance(identifier, str) and identifier.removesuffix("()") == selector
        if selected and node.get("nodeType") == "Failure Message":
            source = node.get("sourceLocation", {})
            source = source if isinstance(source, dict) else {}
            path = source.get("filePath")
            if isinstance(path, str) and Path(path).is_absolute():
                for root in roots:
                    prefix = root.as_posix().rstrip("/") + "/"
                    prefixes = {prefix, prefix.removeprefix("/private") if prefix.startswith("/private/") else prefix}
                    if not any(path.startswith(value) for value in prefixes):
                        continue
                    try:
                        relative = Path(path).resolve().relative_to(root).as_posix()
                    except (OSError, ValueError, RuntimeError):
                        continue
                    value = {"path": relative, "line": source.get("lineNumber")}
                    if public_failure_locations([value]) is not None and value not in locations:
                        locations.append(value)
                        break
        for child in node.get("children", []):
            visit(child, selected)
    for node in tests.get("testNodes", []):
        visit(node)
    return public_failure_locations(locations[:MAX_FAILURE_LOCATIONS])


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
        case = {"source_sha": runner.read_source_sha(root), "source_dirty_paths": runner.read_source_dirty_paths(root),
                "platform": arguments.platform,
                "suite": "smoke-flow", "scenario": "normal", "fixture_set": "a",
                "os": "iOS Simulator" if arguments.platform == "ios" else "tvOS Simulator", "e2e_ids": [],
                "device": arguments.smoke_device, "configuration": arguments.configuration,
                "selection": "single-flow" if arguments.smoke_flow else "group",
                "destination": arguments.destination, "warm_build_identity": receipt["identity"],
                "human_review": "NOT_RUN", "result": "RUNNING", "exit_code": None, "flows": records,
                "group_failures": []}
        def write_state():
            runner.write_case_manifest(evidence, case)
            write_json(evidence / "smoke-flow-results.json", {"schema_version": 1, "source_sha": case["source_sha"],
                "source_dirty_paths": case["source_dirty_paths"], "device": case["device"],
                "configuration": case["configuration"], "selection": case["selection"],
                "result": case["result"], "exit_code": case["exit_code"], "flows": records,
                "group_failures": case["group_failures"]})
        write_state()
        gate = None
        try:
            if case["source_dirty_paths"] != []:
                raise runner.CommandError("smoke-flow requires a clean tested checkout")
            code = 0
            for flow in selected:
                record = execute_flow(flow, root, arguments, source_run, runner, evidence,
                                      build_source_root=receipt.get("source_root", str(root)))
                records.append(record)
                code = code or record["exit_code"]
                write_state()
                print(f"{flow['id']}: {record['outcome']} ({record['elapsed_seconds']:.3f}s)", file=stdout, flush=True)
            gate = "warm-products"
            validate_warm_products(derived, receipt)
            gate = "official-result"
            summaries = [json.loads((evidence / flow["id"] / "official-summary.json").read_text())
                         for flow in selected if (evidence / flow["id"] / "official-summary.json").is_file()]
            if len(summaries) != len(selected):
                code = code or 2
            summary = {field: sum(item[field] for item in summaries)
                       for field in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
            summary["result"] = "Passed" if code == 0 else "Failed"
            tests = {"testNodes": [node for flow in selected
                     if (evidence / flow["id"] / "official-tests.json").is_file()
                     for node in json.loads((evidence / flow["id"] / "official-tests.json").read_text()).get("testNodes", [])]}
            write_json(evidence / "official-tests.json", tests)
            case["official_tests_sha256"] = hashlib.sha256((evidence / "official-tests.json").read_bytes()).hexdigest()
            if owned_derived is not None:
                gate = "build-cleanup"
                cleanup_path, owned_derived = owned_derived, None
                shutil.rmtree(cleanup_path)
            gate = "sensitive-scan"
            runner.write_sensitive_scan(evidence, [PUBLIC_API_KEY, runner.WRONG_PUBLIC_API_KEY])
            gate = "evidence-finalization"
            write_json(evidence / "official-summary.json", summary)
            case.update(result="Passed" if code == 0 else "FAILED", exit_code=code, official_summary=summary)
            write_state()
            return code
        except BaseException as error:
            case.update(result="FAILED", exit_code=getattr(error, "code", 2) or 2)
            try:
                if gate is not None:
                    case["group_failures"].append(fail_gate_flows(evidence, records, gate))
                summary_path = evidence / "official-summary.json"
                if summary_path.is_file():
                    summary = json.loads(summary_path.read_text())
                    summary["result"] = "Failed"
                    write_json(summary_path, summary)
                    case["official_summary"] = summary
            finally:
                write_state()
            raise
    finally:
        if owned_derived is not None:
            shutil.rmtree(owned_derived)


def execute_flow(flow, root, arguments, source_run, runner, evidence, *, build_source_root=None):
    from strict_e2e_build import prepare_test_run, warm_test_command
    from strict_e2e_server import PUBLIC_API_KEY
    directory = evidence / flow["id"]
    directory.mkdir()
    started = time.monotonic()
    record = {"id": flow["id"], "selector": flow["selector"], "outcome": "FAIL",
              "source_sha": runner.read_source_sha(root), "source_dirty_paths": runner.read_source_dirty_paths(root),
              "failure_kind": "infrastructure",
              "official_execution_complete": False, "official_summary": None, "official_tests_sha256": None,
              "failure_locations": None,
              "elapsed_seconds": 0, "first_public_failure_message": None, "exit_code": 2}
    private_evidence = evidence.parent / "private" / evidence.name / flow["id"]
    private_evidence.mkdir(mode=0o700, parents=True)
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
            peer = [name for name in flow["fixtures"] if name != fixture]
            peer_arguments = ["--peer-fixture-set", peer[0]] if peer else []
            with startup.open("wb") as output:
                process = subprocess.Popen([sys.executable, str(root / "scripts/strict_e2e_server.py"),
                    "--host", "127.0.0.1", "--port", "0", "--fixture-set", fixture, "--scenario", "normal",
                    "--ready-file", str(ready), "--log-file", str(private_evidence / f"service-{fixture}.log"), *peer_arguments],
                    cwd=root, stdout=output, stderr=subprocess.DEVNULL)
            processes.append(process)
            host, port = runner.wait_for_service(ready, process, startup_log=startup)
            urls.append(f"http://{host}:{port}/api")
        fixture_payload = runner.write_fixture_artifacts(directory, "a")
        if "b" in flow["fixtures"]:
            write_json(directory / "fixture-manifest-b.json", runner.fixture_manifest("b"))
            runner.write_member_manifest(directory / "member-manifest-b.json", "b")
        environment = runner.make_test_environment(os.environ, server_url=urls[0], public_key=PUBLIC_API_KEY,
                                                   server_url_b=urls[1] if len(urls) == 2 else None)
        environment["STRICT_E2E_EVIDENCE_DIR"] = str(directory)
        bundle = runner.prepare_private_result_bundle_path("smoke-flow")
        private_run = prepare_test_run(source_run, bundle.parent / "run", environment)
        command = warm_test_command(private_run, arguments.destination, bundle,
                                    "immichSlidesUITests/" + flow["selector"])
        command += ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", str(METHOD_TIMEOUT_SECONDS),
                    "-maximum-test-execution-time-allowance", str(METHOD_TIMEOUT_SECONDS)]
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
        record["failure_locations"] = flow_failure_locations(public_tests, flow["selector"],
                                                             [root, build_source_root or root])
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
            "source_dirty_paths": record["source_dirty_paths"],
            "platform": arguments.platform, "suite": "smoke-flow", "flow": record,
            "destination": arguments.destination, "scenario": "normal", "fixture_set": "a",
            "configuration": arguments.configuration, "human_review": "NOT_RUN",
            "fixture_sha256": fixture_payload["fixture_sha256"] if fixture_payload else None,
            "official_tests_sha256": digest, "official_summary": summary,
            "result": "Passed" if record["exit_code"] == 0 else "FAILED", "exit_code": record["exit_code"]})
    return record
