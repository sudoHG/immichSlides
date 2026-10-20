"""Guard per-test fixture coverage against missing, duplicate and skipped results."""

import copy
import contextlib
import io
import itertools
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import run_fixture_ui_tests as runner
from ci_summary import ContractError
from run_fixture_ui_tests import clean_environment, compiled_tests, coverage_rows, declared_tests, problem_reason


class FixtureCoverageTests(unittest.TestCase):
    def test_same_named_target_and_class_keeps_failure_identity_through_summary(self):
        from ci_failure_diagnostics import first_failure_environment, collect_first_failure_spool, attach_first_failures
        from ci_summary import observation, test_identity, write_summary, parse_summary
        from test_ci_summary import first_failure_receipt, valid_summary
        method = "testPlaybackSettingsBlocksFilteredModeWhenSelectionEmpty"
        key = "immichSlidesUITests/" + method
        identity = test_identity("ui", key, platform="ios")
        receipt = first_failure_receipt()
        receipt["screenshot"] = {"status": "unavailable", "width": None, "height": None, "bytes": None}
        for selector, official_key in itertools.product((key, "immichSlidesUITests/" + key), repeat=2):
            for defect in (None, "wrong-method", "wrong-attempt"):
                with self.subTest(selector=selector, official_key=official_key, defect=defect), tempfile.TemporaryDirectory() as raw:
                    root = Path(raw)
                    mapping = json.loads(first_failure_environment(root, [selector])["STRICT_E2E_FIRST_FAILURE_TESTS"])
                    # This is the Class/method key constructed from XCTestCase type and name in Swift.
                    swift_key = "/".join(("immichSlidesUITests", method))
                    self.assertEqual({swift_key: 0}, mapping)
                    (root / "0.json").write_text(json.dumps(receipt))
                    original = official_key + ("Other()" if defect == "wrong-method" else "()")
                    node = {"nodeType": "Test Case", "nodeIdentifier": original, "result": "Failed"}
                    collect_first_failure_spool(root, [selector], [node], root)
                    entry = observation(identity, "failed", 1, exit_code=65)
                    attach_first_failures([entry], {"testNodes": [node]}, 2 if defect == "wrong-attempt" else 1)
                    self.assertEqual(original, node["nodeIdentifier"])
                    summary = valid_summary()
                    summary["run"].update(tier="ui", job="ui-iphone")
                    summary["population"].update(declared=[identity], compiled=[identity], observed=[entry])
                    summary["status"] = "failed"
                    write_summary(summary, root)
                    entry = parse_summary((root / "summary.json").read_text())["population"]["observed"][0]
                    self.assertEqual(65, entry["attempts"][0]["exit_code"])
                    if defect is None:
                        self.assertEqual(receipt, entry["first_failure"])
                        self.assertEqual(receipt, entry["attempts"][0]["first_failure"])
                    else:
                        self.assertNotIn("first_failure", entry)

    def test_slow_official_result_steps_keep_phase_elapsed_and_missing_identities(self):
        from types import SimpleNamespace
        from ci_summary import parse_summary, test_identity
        from ci_verdict import parse_policy
        from test_ci_summary import archive_download_summary
        for phase in ("tests-read", "export", "summary-read", "details-read", "attachments-export"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                root, output = Path(directory, "checkout"), Path(directory, "output")
                root.mkdir()
                bundle = Path(directory, "private/result/fixture.xcresult")
                bundle.mkdir(parents=True)
                source = root / "Products/app.xctestrun"
                source.parent.mkdir()
                source.touch()
                (source.parent / "Debug-iphonesimulator/immichSlides.app").mkdir(parents=True)
                seed = archive_download_summary()
                declared = [test_identity("ui", "NavigationUITests/testMethod" + str(index),
                            platform="ios", device="ipad") for index in range(21)]
                official = {"devices": [{"deviceId": "target", "modelName": "iPad Pro", "platform": "iOS Simulator"}],
                    "testNodes": [{"nodeType": "UI test bundle", "name": "immichSlidesUITests", "children": [
                        {"nodeType": "Test Case", "nodeIdentifier": entry["key"] + "()", "durationInSeconds": 1,
                         "result": "Passed" if index == 0 else "Skipped"} for index, entry in enumerate(declared)]}]}
                counts = {"totalTestCount": 21, "passedTests": 1, "failedTests": 0, "skippedTests": 20, "result": "Passed"}
                policy = parse_policy((runner.ROOT / "scripts/ci-test-policy.json").read_text())
                inputs = {"hashes": seed["hashes"], "population": dict(seed["population"], declared=declared,
                    compiled=[], observed=[]), "policy": policy, "discovery_policy": policy, "deselections": [],
                    "registry": {"schema_version": 1, "entries": []}, "registry_revision": "b" * 40}
                inputs["hashes"]["policies"]["known-flaky"] = "f" * 64
                clock, tests_reads, executions = [0.0], [], []
                def process(command, **kwargs):
                    if command[0] == "xcodebuild":
                        if "-enumerate-tests" in command:
                            enumeration = {"errors": [], "values": [{"enabledTests": [
                                {"identifier": "immichSlidesUITests/" + entry["key"]} for entry in declared]}]}
                            Path(command[command.index("-test-enumeration-output-path") + 1]).write_text(json.dumps(enumeration))
                        else:
                            executions.append(command)
                    return SimpleNamespace(wait=lambda **kwargs: 0, pid=42)
                def read(command, **kwargs):
                    self.assertEqual(command[:2], ["xcrun", "xcresulttool"])
                    self.assertEqual(kwargs["timeout"], 180)
                    if command[4] == "tests":
                        tests_reads.append(command)
                    current = ("attachments-export" if command[2] == "export" else "details-read" if command[4] == "test-details"
                               else "summary-read" if command[4] == "summary" else "tests-read" if len(tests_reads) == 1 else "export")
                    if current == phase:
                        clock[0] += 184.7
                        raise subprocess.TimeoutExpired(command, kwargs["timeout"], output=b"PRIVATE_SENTINEL", stderr=b"PRIVATE_SENTINEL")
                    clock[0] += 0.44
                    detail = ({"testIdentifier": command[command.index("--test-id") + 1], "testResult": "Skipped", "testRuns": [
                        {"nodeType": "Test Case Run", "result": "Skipped", "name": "Official skip"}]} if current == "details-read" else {})
                    payload = json.dumps(counts if command[4] == "summary" else detail if current == "details-read" else official)
                    return subprocess.CompletedProcess(command, 0, payload if kwargs.get("text") else payload.encode())
                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2"}))
                    for name, value in (("ROOT", root), ("run_identity", seed["identity"]),
                        ("source_metadata", (".github/workflows/ci-nightly.yml", False)), ("fixture_inputs", inputs),
                        ("toolchain", seed["toolchain"]), ("prepare_fixture_result_bundle", bundle),
                        ("prepare_simulator", None), ("verify_simulator_device", None), ("simulator_inventory", {}),
                        ("wait_for_service", ("127.0.0.1", 1234)), ("disk_check", None), ("check_products", None),
                        ("measure_signing", "adhoc"), ("prepare_test_run", source), ("reset_simulator_app", None),
                        ("crash_report_directories", []), ("crash_report_snapshot", {}),
                        ("stop_exact_process", None), ("finalize_fixture_run", [])):
                        stack.enter_context(patch.object(runner, name, value if name == "ROOT" else unittest.mock.Mock(return_value=value)))
                    stack.enter_context(patch.object(runner.subprocess, "Popen", side_effect=process))
                    stack.enter_context(patch.object(runner.subprocess, "run", side_effect=read))
                    stack.enter_context(patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]))
                    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                    stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                    code = runner.main(["--device", "ipad", "--destination", "platform=iOS Simulator,id=target",
                        "--output-dir", str(output), "--xctestrun", str(source), "--shard", "navigation",
                        "--shard-manifest", str(root / "manifest.json"), "--listed-only-retry",
                        "--result-export-timeout-seconds", "180", "--failure-screenshots"])
                self.assertEqual(code, 1)
                result = parse_summary((output / "summary.json").read_text())
                self.assertEqual(result["status"], "failed")
                self.assertEqual(result["population"]["declared"], declared)
                self.assertCountEqual(result["population"]["compiled"], declared)
                self.assertIn("xcresult-export-timeout", [item["code"] for item in result["infrastructure"]], result["infrastructure"])
                timeout = next(item for item in result["infrastructure"] if item["code"] == "xcresult-export-timeout")
                self.assertEqual(timeout["message"], "Official result export exceeded its budget; phase=" + phase + "; elapsed_seconds=184.700")
                self.assertEqual(len(executions), 1, "An official result timeout must not retry XCTest")
                self.assertEqual(len(tests_reads), 1 if phase == "attachments-export" else 2,
                                 "Result export is separate from normalized tests reading")
                observed = result["population"]["observed"]
                self.assertEqual(len(observed), 0 if phase == "tests-read" else 21)
                rows = json.loads((output / "fixture-coverage.json").read_text())["tests"]
                self.assertEqual(len(rows), len(observed))
                self.assertNotIn(str(bundle), json.dumps(result["infrastructure"]))
                self.assertNotIn("PRIVATE_SENTINEL", json.dumps(result))
                if phase == "tests-read":
                    self.assertTrue((output / "official-summary.json").exists(), result["infrastructure"])
                    self.assertEqual(json.loads((output / "official-summary.json").read_text()), counts)
                    self.assertEqual(json.loads((output / "export-read-timing.json").read_text())["attempts"][0]["elapsed_seconds"], 184.7)
                    self.assertAlmostEqual(json.loads((output / "export-timing.json").read_text())["official_export_seconds"], 0.88)

    def test_inventory_timeouts_use_bounded_readiness_without_retrying_invalid_results(self):
        import strict_e2e_runner_support as support
        for state in ("recovered", "timeout", "late", "exit", "invalid"):
            with self.subTest(state=state):
                clock, calls, reports = [0.0], [], []
                def query(command, **kwargs):
                    calls.append(kwargs["timeout"])
                    self.assertEqual(command, ["xcrun", "simctl", "list", "devices", "available", "--json"])
                    if state == "timeout" or state == "recovered" and len(calls) == 1:
                        clock[0] += kwargs["timeout"]
                        raise subprocess.TimeoutExpired(["private-input"], kwargs["timeout"], output=b"private-input")
                    if state == "late":
                        clock[0] = 301
                    return subprocess.CompletedProcess(command, 2 if state == "exit" else 0,
                        "private-input" if state == "invalid" else '{"devices":{}}', "private-input")
                with patch.object(support.subprocess, "run", side_effect=query), \
                        patch.object(support.time, "monotonic", side_effect=lambda: clock[0]):
                    if state == "recovered":
                        self.assertEqual(support.simulator_inventory(report=reports.append), {"devices": {}})
                        self.assertEqual(calls, [10, 20])
                    else:
                        with self.assertRaises(support.CommandError) as error:
                            support.simulator_inventory(report=reports.append)
                        self.assertNotIn("private-input", str(error.exception))
                        if state == "timeout":
                            self.assertEqual(clock[0], 300)
                            self.assertLessEqual(max(calls), 60)
                            self.assertEqual(error.exception.entry["code"], "simulator-inventory-timeout")
                        else:
                            self.assertEqual(len(calls), 1)
                self.assertNotIn("private-input", "\n".join(reports))

    def test_early_fixture_failures_keep_registry_date_and_nonpassing_coverage(self):
        from datetime import date
        from strict_e2e_runner_support import InfrastructureTimeout
        from test_ci_summary import discovery_summary
        from ci_summary import parse_summary
        from ci_verdict import parse_policy
        for stage in ("simulator", "inventory", "service"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as directory:
                root, output = Path(directory, "checkout"), Path(directory, "output")
                root.mkdir()
                bundle = Path(directory, "private/result/fixture.xcresult")
                bundle.mkdir(parents=True)
                seed = discovery_summary()
                policy = parse_policy((runner.ROOT / "scripts/ci-test-policy.json").read_text())
                inputs = {"hashes": seed["hashes"], "population": dict(seed["population"], compiled=[], observed=[]),
                          "policy": policy, "discovery_policy": policy, "deselections": [],
                          "registry": {"schema_version": 1, "entries": []}, "registry_revision": "b" * 40}
                error = runner.CommandError("Synthetic " + stage + " preparation failure")
                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}))
                    for name, value in (("ROOT", root), ("run_identity", seed["identity"]),
                                        ("source_metadata", (".github/workflows/ci-ui.yml", False)),
                                        ("fixture_inputs", inputs), ("toolchain", seed["toolchain"]),
                                        ("prepare_fixture_result_bundle", bundle), ("verify_simulator_device", None),
                                        ("stop_exact_process", None), ("finalize_fixture_run", [])):
                        stack.enter_context(patch.object(runner, name, value if name == "ROOT" else unittest.mock.Mock(return_value=value)))
                    clock = stack.enter_context(patch.object(runner, "date"))
                    clock.today.return_value = date(2026, 10, 13)
                    stack.enter_context(patch.object(runner, "prepare_simulator", side_effect=error if stage == "simulator" else None))
                    stack.enter_context(patch.object(runner, "simulator_inventory", return_value={},
                        side_effect=InfrastructureTimeout("simulator-inventory", 60) if stage == "inventory" else None))
                    stack.enter_context(patch.object(runner.subprocess, "Popen"))
                    stack.enter_context(patch.object(runner, "wait_for_service", side_effect=error))
                    launch = stack.enter_context(patch.object(runner, "run_xcode_attempts"))
                    scan = stack.enter_context(patch.object(runner, "write_sensitive_scan"))
                    evaluate = stack.enter_context(patch.object(runner, "evaluate_population", wraps=runner.evaluate_population))
                    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                    stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                    code = runner.main(["--device", "iphone", "--destination", "platform=iOS Simulator,id=target",
                        "--output-dir", str(output), "--xctestrun", str(root / "unused.xctestrun"), "--shard", "scoped-a",
                        "--shard-manifest", str(root / "unused.json"), "--scoped-plan-sha256", "e" * 64,
                        "--compiled-from-official-results", "--listed-only-retry"])
                self.assertNotEqual(code, 0)
                launch.assert_not_called()
                scan.assert_called_once()
                self.assertEqual(evaluate.call_args.kwargs["evaluated_on"], date(2026, 10, 13))
                result = parse_summary((output / "summary.json").read_text())
                self.assertEqual(result["status"], "failed")
                self.assertTrue(any(stage in item["message"] for item in result["infrastructure"]))
                self.assertTrue(all(item["outcome"] == "not-run" for item in result["population"]["observed"]))
                verdict = json.loads((output / "coverage-verdict.json").read_text())
                self.assertEqual(verdict["status"], "failed")
                self.assertFalse(any("trusted producer evaluation date" in message for message in verdict["errors"]))

    def test_listed_only_retry_main_preserves_legacy_labels_for_failed_and_flaky_passed_methods(self):
        from types import SimpleNamespace
        from ci_flaky import ASSERTION_FAILURE
        from ci_summary import observation, parse_summary
        from ci_verdict import parse_policy
        from test_ci_flaky import registry
        from test_ci_summary import discovery_summary, first_failure_receipt
        from ci_failure_diagnostics import configure_first_failure_attempt
        for retried, retry_read_failed, retry_two, configure_failed, first_missing in (
                (False, False, False, False, False), (True, False, False, False, False),
                (True, True, False, False, False), (True, False, True, False, False),
                (True, False, True, True, False), (True, False, True, False, True)):
            for diagnostics in ({"failure_phase": "interval_setup", "failure_class": "interval_readback"},
                                {"failure_phase": "unknown", "failure_class": "unknown"}):
                with self.subTest(retried=retried, retry_read_failed=retry_read_failed, retry_two=retry_two,
                                  configure_failed=configure_failed, first_missing=first_missing,
                                  diagnostics=diagnostics), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory, "checkout").resolve()
                    root.mkdir()
                    output = Path(directory, "output")
                    source = root / "Products" / "app.xctestrun"
                    source.parent.mkdir()
                    source.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [
                        {"BlueprintName": "immichSlidesUITests", "EnvironmentVariables": {}}]}]}))
                    (source.parent / "Debug-iphonesimulator" / "immichSlides.app").mkdir(parents=True)
                    seed = discovery_summary()
                    entry = seed["population"]["declared"][0]
                    if retry_read_failed:
                        missing = dict(entry, key="SettingsUITests/testMissing")
                        seed["population"]["declared"].append(missing)
                    official = seed["compiled_evidence"]["official_tests"]
                    official["testNodes"][0]["children"][0].update(result="Failed", **diagnostics)
                    if retry_two:
                        second = dict(entry, key=entry["key"] + "Second")
                        seed["population"]["declared"].append(second)
                        official["testNodes"][0]["children"].append({"nodeType": "Test Case",
                            "nodeIdentifier": second["key"] + "()", "result": "Failed", "durationInSeconds": 1, **diagnostics})
                    trusted = registry()
                    trusted["entries"][0]["identity"] = dict(entry, dimensions={"platform": "ios"})
                    trusted["entries"][0]["review_by"] = "2099-01-01"
                    if retry_two:
                        trusted["entries"].append(copy.deepcopy(trusted["entries"][0]))
                        trusted["entries"][-1]["identity"] = dict(second, dimensions={"platform": "ios"})
                    if not retried:
                        trusted["entries"] = []
                    policy = parse_policy((runner.ROOT / "scripts/ci-test-policy.json").read_text())
                    inputs = {"hashes": seed["hashes"], "population": dict(seed["population"], compiled=[], observed=[]),
                              "policy": policy, "discovery_policy": policy, "deselections": [], "registry": trusted,
                              "registry_revision": "b" * 40}
                    inputs["hashes"]["policies"]["known-flaky"] = "f" * 64
                    failed = observation(entry, "failed", 1, exit_code=65, reason=ASSERTION_FAILURE,
                                         failure_diagnostics=diagnostics)
                    passed = observation(entry, "passed", 1)
                    first_receipt = first_failure_receipt()
                    first_receipt["screenshot"] = {"status": "unavailable", "width": None, "height": None, "bytes": None}
                    if retry_two:
                        from PIL import Image
                        pixels = io.BytesIO()
                        Image.new("RGB", (64, 32), "blue").save(pixels, format="PNG")
                        first_receipt["screenshot"] = {"status": "captured", "width": 64, "height": 32,
                                                       "bytes": len(pixels.getvalue())}
                    bundles, invocations = [], []
                    def configure(call, spool, selectors, **kwargs):
                        if configure_failed and spool.name != "attempt-1":
                            original_write = Path.write_bytes
                            def fail_write(path, payload):
                                original_write(path, payload[:8])
                                raise OSError("Synthetic partial attempt configuration write")
                            with patch.object(Path, "write_bytes", fail_write):
                                return configure_first_failure_attempt(call, spool, selectors, **kwargs)
                        return configure_first_failure_attempt(call, spool, selectors, **kwargs)
                    def allocate():
                        bundle = Path(directory, "private", str(len(bundles)), "fixture.xcresult")
                        bundle.mkdir(parents=True)
                        bundles.append(bundle)
                        return bundle
                    def process(command, **kwargs):
                        if command[0] == "xcodebuild":
                            invocations.append(command)
                            target = plistlib.loads(Path(command[command.index("-xctestrun") + 1]).read_bytes())["TestConfigurations"][0]["TestTargets"][0]
                            environment = target["EnvironmentVariables"]
                            number = len(invocations)
                            if configure_failed and number > 1:
                                self.assertNotEqual("1", environment.get("STRICT_E2E_FIRST_FAILURE_ENABLED"))
                                self.assertNotIn("STRICT_E2E_FIRST_FAILURE_DIR", environment)
                            else:
                                self.assertEqual("1", environment["STRICT_E2E_FIRST_FAILURE_ENABLED"])
                                spool = Path(environment["STRICT_E2E_FIRST_FAILURE_DIR"])
                                self.assertEqual(spool, Path(directory, "private/first-failure-spool", "attempt-" + str(number)))
                        code = 65 if len(invocations) == 1 or retry_two else 0
                        return SimpleNamespace(wait=lambda **kwargs: code, pid=42)
                    def export(bundle, *args, **kwargs):
                        self.assertIs(kwargs["enrich_failure_diagnostics"], True)
                        self.assertEqual(kwargs["export_timeout_seconds"], 60)
                        suffix = kwargs["suffix"]
                        number = bundles.index(bundle) + 1
                        self.assertEqual(kwargs["first_failure_spool"], None if configure_failed and number > 1 else
                            (Path(directory, "private/first-failure-spool", "attempt-" + str(number)),
                             [item["key"] for item in seed["population"]["declared"]]))
                        payload = copy.deepcopy(official)
                        for node in payload["testNodes"][0]["children"]:
                            if not first_missing:
                                node["first_failure"] = copy.deepcopy(first_receipt)
                        if bundle != bundles[0]:
                            retried_entry = second if retry_two and bundle == bundles[2] else entry
                            payload["testNodes"][0]["children"][0] = {
                                "nodeType": "Test Case", "nodeIdentifier": retried_entry["key"] + "()",
                                "result": "Failed" if retry_two else "Passed", "durationInSeconds": 1}
                            payload["testNodes"][0]["children"] = payload["testNodes"][0]["children"][:1]
                            if retry_two and not configure_failed:
                                payload["testNodes"][0]["children"][0]["first_failure"] = {
                                    **copy.deepcopy(first_receipt), "step": "capture-frame"}
                        (output / ("official-tests" + suffix + ".json")).write_text(json.dumps(payload))
                        if retry_two:
                            for node in payload["testNodes"][0]["children"]:
                                if "first_failure" not in node:
                                    continue
                                index = 1 if node["nodeIdentifier"] == second["key"] + "()" else 0
                                image = kwargs["first_failure_images"] / (str(index) + ".png")
                                image.parent.mkdir(parents=True, exist_ok=True)
                                image.write_bytes(pixels.getvalue())
                        return "f" * 64
                    # Test-details text disagrees with legacy summaries; it must never replace their labels.
                    detail = ("Failed to get matching snapshot: private detail" if diagnostics["failure_phase"] != "unknown"
                              else "The iOS slider must be settable to 30 seconds. conflicting failure")
                    with contextlib.ExitStack() as stack:
                        stack.enter_context(patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}))
                        for name, value in (("ROOT", root), ("run_identity", seed["identity"]),
                                            ("source_metadata", (".github/workflows/ci-ui.yml", False)),
                                            ("fixture_inputs", inputs), ("toolchain", seed["toolchain"]),
                                            ("prepare_simulator", None), ("verify_simulator_device", None),
                                            ("wait_for_service", ("127.0.0.1", 1234)), ("disk_check", None),
                                            ("check_products", None), ("measure_signing", "adhoc"),
                                            ("reset_simulator_app", None),
                                            ("crash_report_directories", []), ("crash_report_snapshot", {}),
                                            ("read_problem_reason", detail), ("stop_exact_process", None)):
                            stack.enter_context(patch.object(runner, name, value if name == "ROOT"
                                                            else unittest.mock.Mock(return_value=value)))
                        stack.enter_context(patch.object(runner, "prepare_fixture_result_bundle", side_effect=allocate))
                        reads = ([copy.deepcopy([failed, observation(second, "failed", 1, exit_code=65, reason=ASSERTION_FAILURE,
                                   failure_diagnostics=diagnostics)]), [observation(entry, "failed", 1, exit_code=65)],
                                   [observation(second, "failed", 1, exit_code=65)]] if retry_two else
                                 [copy.deepcopy([failed]), subprocess.TimeoutExpired("xcresulttool", 60)
                                  if retry_read_failed else [passed]])
                        stack.enter_context(patch.object(runner, "read_xcode_observations", side_effect=reads))
                        stack.enter_context(patch.object(runner.subprocess, "Popen", side_effect=process))
                        stack.enter_context(patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"{}")))
                        stack.enter_context(patch.object(runner, "simulator_inventory", return_value={}))
                        stack.enter_context(patch.object(runner, "export_private_result_bundle", side_effect=export))
                        stack.enter_context(patch("ci_failure_diagnostics.configure_first_failure_attempt", side_effect=configure))
                        stack.enter_context(patch.object(runner, "finalize_fixture_run", return_value=[]))
                        stack.enter_context(patch.object(runner, "write_sensitive_scan"))
                        stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                        stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                        code = runner.main(["--device", "iphone", "--destination", "platform=iOS Simulator,id=target",
                            "--output-dir", str(output), "--xctestrun", str(source), "--shard", "scoped-a",
                            "--shard-manifest", str(root / "manifest.json"), "--scoped-plan-sha256", "e" * 64,
                            "--compiled-from-official-results", "--listed-only-retry", *(["--failure-screenshots"] if retry_two else [])])
                    self.assertEqual(code, 0 if retried and not retry_read_failed and not retry_two else 65)
                    self.assertEqual(len(invocations), 3 if retry_two else 2 if retried else 1)
                    result = parse_summary((output / "summary.json").read_text())
                    actual = result["population"]["observed"][0]
                    self.assertEqual(actual["outcome"], "flaky-passed" if retried and not retry_read_failed and not retry_two else "failed")
                    if first_missing:
                        self.assertNotIn("first_failure", actual)
                        self.assertTrue(all("first_failure" not in item for item in actual["attempts"]))
                    else:
                        self.assertEqual(first_receipt, actual["first_failure"])
                    if retry_two:
                        self.assertEqual(2, len(result["population"]["observed"]))
                        for record in result["population"]["observed"]:
                            if first_missing:
                                self.assertNotIn("first_failure", record)
                            else:
                                self.assertEqual(first_receipt, record["first_failure"])
                                if configure_failed:
                                    self.assertNotIn("first_failure", record["attempts"][1])
                                else:
                                    self.assertEqual("capture-frame", record["attempts"][1]["first_failure"]["step"])
                        import ci_ui_tests
                        with patch.object(ci_ui_tests, "output"), contextlib.redirect_stderr(io.StringIO()):
                            self.assertEqual(0, ci_ui_tests.main(["check-upload", "--output-dir", str(output)]))
                    for field, value in diagnostics.items():
                        self.assertEqual(actual[field], value)
                        self.assertEqual(actual["attempts"][0][field], value)
                        rows = json.loads((output / "fixture-coverage.json").read_text())["tests"]
                        self.assertEqual(rows[0][field], value)
                    if retry_read_failed:
                        self.assertEqual((rows[-1]["identity"], rows[-1]["outcome"], rows[-1]["reason"]),
                                         (missing, "not-run", "compiled but no official result"))
                    if retried:
                        self.assertNotIn("failure_phase", actual["attempts"][1])

    def test_failed_ui_method_diagnostics_survive_coverage_and_summary_without_free_text(self):
        from ci_summary import observation, test_identity, validate_observation
        identity = test_identity("ui", "Flow/testFailure", platform="ios")
        diagnostics = {"failure_phase": "interval_setup", "failure_class": "interval_readback"}
        node = {"nodeType": "Test Case", "nodeIdentifier": "Flow/testFailure()", "result": "Failed",
                "durationInSeconds": 1, **diagnostics}
        for extra in (diagnostics, {}):
            with self.subTest(extra=extra):
                official = {"testNodes": [{key: value for key, value in node.items()
                                           if key not in diagnostics or key in extra}]}
                row = coverage_rows([identity], [identity], official, "iphone")[0]
                expected = diagnostics if extra else {"failure_phase": "unknown", "failure_class": "unknown"}
                self.assertEqual({field: row[field] for field in expected}, expected)
                entry = observation(identity, row["outcome"], row["duration_seconds"], exit_code=65, failure_diagnostics=expected)
                validate_observation(entry)
                self.assertEqual(entry["outcome"], "failed")
                self.assertEqual(entry["attempts"][0]["exit_code"], 65)
                for field in expected:
                    self.assertEqual(entry[field], entry["attempts"][0][field])
                entry["attempts"][0]["failure_class"] = "private assertion text"
                with self.assertRaises(ContractError):
                    validate_observation(entry)
        with self.assertRaises(ValueError):
            coverage_rows([identity], [identity], {"testNodes": [dict(node, failure_phase="private assertion text")]}, "iphone")

    def test_candidate_deselection_changes_cannot_override_base_discovery_eligibility(self):
        import hashlib
        from test_ci_summary import discovery_summary
        from ci_summary import parse_summary
        from ci_summary import test_identity
        policy = json.loads((runner.ROOT / "scripts/ci-test-policy.json").read_text())
        entry = test_identity("ui", "Flow/testFirst", platform="ios", device="iphone")
        rule = {"tier": "ui", "environment": "fixture", "identity": entry,
                "reason": "Reviewed fixture exception", "owning_tier": "nightly"}
        for base_has_rule in (False, True):
            with self.subTest(base_has_rule=base_has_rule), tempfile.TemporaryDirectory() as directory:
                root = Path(directory, "checkout").resolve()
                root.mkdir()
                (root / "scripts").mkdir()
                (root / "immichSlidesUITests").mkdir()
                (root / "immichSlidesUITests" / "Tests.swift").write_text(
                    "class Flow: XCTestCase { func testFirst() {} }")
                (root / "immichSlides-iOS.xctestplan").write_text(json.dumps({"testTargets": [
                    {"target": {"name": "immichSlidesUITests"}}]}))
                base, candidate = copy.deepcopy(policy), copy.deepcopy(policy)
                base["deselections"] = [rule] if base_has_rule else []
                candidate["deselections"] = [] if base_has_rule else [rule]
                candidate["expected_skips"] = [{"kind": "ui", "key_pattern": entry["key"],
                    "dimensions": entry["dimensions"], "tier": "ui", "environment": "fixture", "reason": "Candidate skip"}]
                candidate_text = json.dumps(candidate, indent=2)
                candidate_bytes = candidate_text.replace("\n", "\r\n").encode()
                (root / "scripts/ci-test-policy.json").write_bytes(candidate_bytes)
                with patch("ci_publish_git.read_blob", return_value=json.dumps(base)) as blob:
                    result = runner.fixture_inputs(root, "iphone", [], mode="pr", policy_revision="b" * 40)
                blob.assert_called_once_with("b" * 40, "scripts/ci-test-policy.json")
                self.assertEqual(result["official_discovery_eligible"], not base_has_rule)
                self.assertEqual(result["deselections"], [] if base_has_rule else [rule])
                self.assertEqual(result["policy"], candidate)
                self.assertEqual(result["hashes"]["policies"]["test-policy"], hashlib.sha256(candidate_bytes).hexdigest())
                if not base_has_rule:
                    result["hashes"]["manifests"]["ui-scoped-plan"] = "e" * 64
                    seed = discovery_summary()
                    output = Path(directory, "conflict")
                    stderr = io.StringIO()
                    with patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}), \
                            patch.object(runner, "ROOT", root), patch.object(runner, "fixture_inputs", return_value=result), \
                            patch.object(runner, "run_identity", return_value=seed["identity"]), \
                            patch.object(runner, "source_metadata", return_value=(".github/workflows/ci-ui.yml", False)), \
                            patch.object(runner, "toolchain") as tools, patch.object(runner.subprocess, "run") as host, \
                            patch.object(runner.subprocess, "Popen") as launch, \
                            contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                        self.assertEqual(runner.main(["--device", "iphone", "--destination", "platform=iOS Simulator,id=target",
                            "--output-dir", str(output), "--xctestrun", str(root / "unused.xctestrun"), "--shard", "scoped-a",
                            "--shard-manifest", str(root / "unused.json"), "--compiled-from-official-results"]), 1)
                    tools.assert_not_called()
                    host.assert_not_called()
                    launch.assert_not_called()
                    conflict = parse_summary((output / "summary.json").read_text())
                    self.assertEqual(conflict["status"], "failed")
                    self.assertIn("candidate fixture deselection conflicts with base", conflict["infrastructure"][0]["message"])
                    self.assertIn(conflict["infrastructure"][0]["message"], stderr.getvalue())

    def test_scoped_execution_skips_enumeration_and_rejected_proofs_still_scan_and_dispose(self):
        from types import SimpleNamespace
        from test_ci_summary import discovery_summary
        from ci_summary import observation, parse_summary
        from ci_verdict import parse_policy
        for raw, shape in ((0, "complete"), (0, "expected-skip"), (65, "missing-export"), (124, "empty"),
                           (0, "empty"), (65, "complete"), (65, "unknown"), (65, "malformed"), (2, "launch")):
            with self.subTest(raw=raw, shape=shape), tempfile.TemporaryDirectory() as directory:
                root = Path(directory, "checkout").resolve()
                root.mkdir()
                output, work = Path(directory, "output"), Path(directory, "private")
                work.mkdir()
                bundle = work / "result" / "fixture.xcresult"
                bundle.mkdir(parents=True)
                source = root / "Products" / "app.xctestrun"
                source.parent.mkdir()
                source.touch()
                (source.parent / "Debug-iphonesimulator" / "immichSlides.app").mkdir(parents=True)
                seed = discovery_summary()
                entry = seed["population"]["declared"][0]
                official = seed["compiled_evidence"]["official_tests"]
                if shape == "empty":
                    official["testNodes"][0]["children"] = []
                elif shape == "unknown":
                    official["testNodes"][0]["children"][0]["result"] = "Unknown"
                elif shape == "malformed":
                    official["testNodes"] = None
                elif shape == "expected-skip":
                    official["testNodes"][0]["children"][0]["result"] = "Skipped"
                policy = parse_policy((runner.ROOT / "scripts/ci-test-policy.json").read_text())
                discovery_policy = copy.deepcopy(policy)
                if shape == "expected-skip":
                    policy["expected_skips"].append({"kind": "ui", "key_pattern": entry["key"],
                        "dimensions": entry["dimensions"], "tier": "ui", "environment": "fixture", "reason": "Candidate skip"})
                inputs = {"hashes": seed["hashes"], "population": dict(seed["population"], compiled=[], observed=[]),
                          "policy": policy, "discovery_policy": discovery_policy, "deselections": [], "registry": {"schema_version": 1, "entries": []},
                          "registry_revision": "b" * 40}
                inputs["hashes"]["policies"]["known-flaky"] = "f" * 64
                def export(*args, **kwargs):
                    if shape in {"missing-export", "launch"}:
                        raise runner.CommandError("Synthetic export unavailable")
                    (output / "official-tests.json").write_text(json.dumps(official))
                    return "f" * 64
                commands = []
                gate_finished = []
                def gate(udid, *, boot_submitted=False):
                    self.assertEqual(udid, "target")
                    self.assertEqual(boot_submitted, shape == "complete")
                    gate_finished.append(True)
                def process(command, **kwargs):
                    self.assertTrue(gate_finished, "fixture launch must wait for simulator readiness")
                    commands.append(command)
                    if shape == "launch" and command[0] == "xcodebuild":
                        raise OSError("Synthetic launch failure")
                    return SimpleNamespace(wait=lambda **kwargs: raw, pid=42)
                observed = [observation(entry, "passed", 1)] if shape == "complete" else []
                if shape == "expected-skip":
                    observed = [observation(entry, "skipped", 1, reason="Candidate skip")]
                argv = ["--device", "iphone", "--destination", "platform=iOS Simulator,id=target",
                        "--output-dir", str(output), "--xctestrun", str(source), "--shard", "scoped-a",
                        "--shard-manifest", str(root / "manifest.json"), "--scoped-plan-sha256", "e" * 64,
                        "--compiled-from-official-results", "--listed-only-retry", "--failure-screenshots"]
                attachments = []
                inventory_calls = []
                def run(command, **kwargs):
                    self.assertTrue(gate_finished, "simulator inventory must wait for readiness")
                    if command[:3] == ["xcrun", "simctl", "list"]:
                        inventory_calls.append(command)
                        if len(inventory_calls) == 1:
                            raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                    if "attachments" in command:
                        attachments.append(command)
                        from PIL import Image
                        exported = Path(command[command.index("--output-path") + 1]) / "legacy.png"
                        exported.parent.mkdir(parents=True, exist_ok=True)
                        Image.new("RGB", (2000, 100), "blue").save(exported, format="PNG", icc_profile=b"PRIVATE_PROFILE")
                    return SimpleNamespace(returncode=0, stdout=b"{}")
                stderr = io.StringIO()
                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}))
                    for name, value in (("ROOT", root), ("run_identity", seed["identity"]),
                                        ("source_metadata", (".github/workflows/ci-ui.yml", False)),
                                        ("fixture_inputs", inputs), ("toolchain", seed["toolchain"]),
                                        ("prepare_fixture_result_bundle", bundle), ("verify_simulator_device", None),
                                        ("wait_for_service", ("127.0.0.1", 1234)), ("disk_check", None),
                                        ("check_products", None), ("measure_signing", "adhoc"),
                                        ("prepare_test_run", source), ("reset_simulator_app", None),
                                        ("crash_report_directories", []), ("crash_report_snapshot", {}),
                                        ("read_xcode_observations", observed), ("read_problem_reason", "Candidate skip"),
                                        ("stop_exact_process", None)):
                        stack.enter_context(patch.object(runner, name, value if name == "ROOT" else unittest.mock.Mock(return_value=value)))
                    stack.enter_context(patch.object(runner.subprocess, "Popen", side_effect=process))
                    stack.enter_context(patch.object(runner.subprocess, "run", side_effect=run))
                    stack.enter_context(patch.object(runner, "prepare_simulator", side_effect=gate))
                    stack.enter_context(patch.object(runner, "export_private_result_bundle", side_effect=export))
                    scan = stack.enter_context(patch.object(runner, "write_sensitive_scan"))
                    dispose = stack.enter_context(patch.object(runner, "finalize_fixture_run", return_value=[]))
                    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                    stack.enter_context(contextlib.redirect_stderr(stderr))
                    code = runner.main(argv, simulator_prepared=shape == "complete")
                    runner.reset_simulator_app.assert_called_once_with("target", boot_submitted=True)
                    runner.wait_for_service.assert_called_once_with(work / "ready.json", unittest.mock.ANY,
                                                                    startup_log=work / "service.log")
                self.assertEqual(len(inventory_calls), 2)
                tests = [command for command in commands if command[0] == "xcodebuild"]
                self.assertEqual(len(tests), 1)
                self.assertNotIn("-enumerate-tests", tests[0])
                self.assertEqual(len(attachments), 1)
                from PIL import Image
                exported = output / "failure-screenshots/attempt-1/legacy.png"
                with Image.open(exported) as image:
                    self.assertLessEqual(max(image.size), 1536)
                    self.assertEqual({}, image.info)
                self.assertLessEqual(exported.stat().st_size, 1048576)
                scan.assert_called_once()
                dispose.assert_called_once()
                self.assertEqual(code, 0 if raw == 0 and shape in {"complete", "expected-skip"} else raw or 1)
                result = json.loads((output / "summary.json").read_text())
                self.assertEqual(result["compiled_evidence"]["first_exit_code"], raw)
                self.assertEqual(result["status"], "passed" if code == 0 else "failed")
                if shape in {"missing-export", "launch"} or raw == 124 or code == 0:
                    parse_summary(result)
                else:
                    with self.assertRaises(ContractError):
                        parse_summary(result)
                    rejection = next(entry for entry in result["infrastructure"] if entry["code"] == "discovery-record-invalid")
                    self.assertIn(rejection["message"], (output / "summary.md").read_text())
                    self.assertIn(rejection["message"], stderr.getvalue())
                import ci_ui_tests as producer
                with patch.object(producer, "output"), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(producer.main(["check-upload", "--output-dir", str(output)]), 0)
                    if shape in {"empty", "complete", "unknown", "malformed"} and code != 0 and raw != 124:
                        for mutation in ("unmarked", "passed", "metadata"):
                            with self.subTest(mutation=mutation):
                                rejected = copy.deepcopy(result)
                                if mutation == "unmarked":
                                    rejected["infrastructure"] = [item for item in rejected["infrastructure"]
                                                                 if item["code"] != "discovery-record-invalid"]
                                elif mutation == "passed":
                                    rejected["status"] = "passed"
                                else:
                                    rejected["toolchain"]["versions"] = {}
                                (output / "summary.json").write_text(json.dumps(rejected))
                                with patch("run_strict_e2e.write_sensitive_scan") as guard:
                                    self.assertEqual(producer.main(["check-upload", "--output-dir", str(output)]), 1)
                                    guard.assert_not_called()
                        (output / "summary.json").write_text(json.dumps(result))
                    (output / "sensitive.txt").write_text(runner.PUBLIC_API_KEY)
                    with self.assertRaises(runner.CommandError):
                        producer.main(["check-upload", "--output-dir", str(output)])
                self.assertEqual(json.loads((output / "sensitive-scan.json").read_text())["result"], "FAIL")

    def test_official_discovery_starts_only_for_bound_scoped_pr_without_base_deselection(self):
        from test_ci_summary import discovery_summary
        from ci_verdict import parse_policy
        summary = discovery_summary()
        summary.pop("compiled_evidence")
        summary["schema_version"] = 1
        policy = parse_policy((runner.ROOT / "scripts/ci-test-policy.json").read_text())
        self.assertTrue(runner.start_official_discovery(summary, "target", policy, enabled=True))
        self.assertEqual(summary["schema_version"], 2)
        self.assertEqual(summary["compiled_evidence"]["official_tests"], None)
        self.assertEqual(summary["population"]["compiled"], [])
        conflict = discovery_summary()
        conflict["population"]["deselected"] = [{"identity": conflict["population"]["declared"][0],
            "reason": "Candidate deselection", "owning_tier": "nightly"}]
        with self.assertRaisesRegex(ContractError, "candidate fixture deselection conflicts with base"):
            runner.start_official_discovery(conflict, "target", policy, enabled=True)
        for mutate in (lambda value: value["run"].update(shard="visual-a"),
                       lambda value: value["identity"].update(event="push"),
                       lambda value: value["source"].update(workflow_path=".github/workflows/ci-nightly.yml"),
                       lambda value: value["hashes"]["manifests"].pop("ui-scoped-plan")):
            other = discovery_summary()
            other["schema_version"] = 1
            other.pop("compiled_evidence")
            mutate(other)
            self.assertFalse(runner.start_official_discovery(other, "target", policy, enabled=True))
            self.assertEqual(other["schema_version"], 1)
        base = copy.deepcopy(policy)
        base["deselections"] = [{"tier": "ui", "environment": "fixture", "identity": summary["population"]["declared"][0]}]
        self.assertFalse(runner.start_official_discovery(discovery_summary(), "target", base, enabled=True))

    def test_fixture_launch_inputs_never_mutate_the_archived_run_or_unit_target(self):
        payload = {"TestConfigurations": [{"TestTargets": [
            {"BlueprintName": "immichSlidesUITests", "EnvironmentVariables": {},
             "TestingEnvironmentVariables": {}, "UITargetAppEnvironmentVariables": {}},
            {"BlueprintName": "immichSlidesTests", "EnvironmentVariables": {},
             "TestingEnvironmentVariables": {}, "UITargetAppEnvironmentVariables": {}}]}]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "archive.xctestrun"
            original = plistlib.dumps(payload)
            source.write_bytes(original)
            screenshots = root / "screenshots"
            screenshots.mkdir()
            prepared = runner.prepare_test_run(source, screenshots, {"IMMICH_TEST_API_KEY": "public-fixture-input"},
                failure_screenshots=True, first_failure_spool=(root / "private-spool", ["FlowUITests/testPlayback"]))
            targets = plistlib.loads(prepared.read_bytes())["TestConfigurations"][0]["TestTargets"]
            environment = targets[0]["EnvironmentVariables"]
            self.assertEqual(environment["STRICT_E2E_FIRST_FAILURE_ENABLED"], "1")
            self.assertEqual(environment["STRICT_E2E_FIRST_FAILURE_DIR"], str(root / "private-spool"))
            self.assertEqual(json.loads(environment["STRICT_E2E_FIRST_FAILURE_TESTS"]), {"FlowUITests/testPlayback": 0})
            self.assertNotIn("STRICT_E2E_FIRST_FAILURE_ENABLED", targets[0]["UITargetAppEnvironmentVariables"])
            self.assertEqual(targets[1], payload["TestConfigurations"][0]["TestTargets"][1])
            self.assertEqual(source.read_bytes(), original)

    def test_crash_reports_keep_only_new_reports_of_this_simulator_within_bounds(self):
        mine, other = "AAAAAAAA-0000-0000-0000-000000000001", "BBBBBBBB-0000-0000-0000-000000000002"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = root / "reports"
            retired = reports / "Retired"
            retired.mkdir(parents=True)
            def write(name, text, folder=reports, age=0):
                path = folder / name
                path.write_text(text) if isinstance(text, str) else path.write_bytes(text)
                stamp = baseline["started"] + age
                os.utime(path, (stamp, stamp))
            baseline = {"started": 1_000_000.0}
            write("immichSlides-old.ips", f"CoreSimulator/Devices/{mine}", age=-100)
            moved = reports / "immichSlides-moved.ips"
            write(moved.name, f"CoreSimulator/Devices/{mine}", age=-100)
            baseline = runner.crash_report_snapshot([reports, retired])
            self.assertIn(moved.name, baseline["names"])
            baseline["started"] = 1_000_000.0
            moved.rename(retired / moved.name)
            write("immichSlides-unlisted-old.ips", f"CoreSimulator/Devices/{mine}", folder=retired, age=-100)
            write("immichSlides-this.ips", f'"procPath" : "{root}/CoreSimulator/Devices/{mine}/immichSlides"\n'
                  f'"crashReporterKey" : "D2604435-10B2-A3CB-5A7F-F0079E1980C1"\n'
                  f'CrashReporter Key:   D2604435-10B2-A3CB-5A7F-F0079E1980C1\nAnonymous UUID:  1234\n'
                  f'"uuid" : "13bf61dd-c45c-3fbf-94a2-7219a8e7abf4"', age=1)
            write("immichSlides-other-simulator.ips", f"CoreSimulator/Devices/{other}", age=1)
            write("accountsd-this.ips", f"CoreSimulator/Devices/{mine}", age=1)
            write("immichSlides-huge.ips", b"x" * (runner.MAX_CRASH_REPORT_BYTES + 1), age=1)
            destination = root / "out"
            collected, omitted = runner.collect_crash_reports(mine, baseline, destination, [reports, retired], home=root)
            self.assertEqual([item["name"] for item in collected], ["immichSlides-this.ips"])
            self.assertEqual([item["name"] for item in omitted], ["immichSlides-huge.ips"])
            self.assertEqual(sorted(path.name for path in destination.iterdir()), ["immichSlides-this.ips", "manifest.json"])
            text = (destination / "immichSlides-this.ips").read_text()
            for private in (str(root), "D2604435", "1234"):
                self.assertNotIn(private, text)
            self.assertIn("13bf61dd-c45c-3fbf-94a2-7219a8e7abf4", text)
            for number in range(runner.MAX_CRASH_REPORTS + 2):
                write(f"immichSlides-burst-{number}.ips", f"CoreSimulator/Devices/{mine}", age=2 + number)
            bounded, _ = runner.collect_crash_reports(mine, baseline, root / "bounded", [reports, retired], home=root)
            self.assertEqual(len(bounded), runner.MAX_CRASH_REPORTS)
            self.assertNotIn("immichSlides-unlisted-old.ips", [item["name"] for item in bounded])

    def test_crash_report_collection_failure_never_escapes_into_the_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = root / "reports"
            reports.mkdir()
            (reports / "immichSlides-this.ips").write_text("CoreSimulator/Devices/UDID")
            blocker = root / "blocker"
            blocker.write_text("a file where the destination parent should be")
            baseline = {"started": 0.0, "names": set()}
            self.assertEqual(runner.collect_crash_reports("UDID", baseline, blocker / "crash-logs", [reports]), ([], []))
            with patch.object(Path, "iterdir", side_effect=PermissionError):
                self.assertEqual(runner.crash_report_snapshot([reports])["names"], set())

    def test_successful_private_disposal_removes_bundle_and_sibling_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private = root / "private"
            private.mkdir()
            output = root / "public"
            output.mkdir()
            with patch.object(runner, "prepare_private_result_bundle_path", return_value=private / "result.xcresult"):
                bundle = runner.prepare_fixture_result_bundle()
            bundle.mkdir()
            (bundle / "Data").write_text("synthetic result")
            (private / "test.log").write_text("synthetic log")
            (private / "fixture.xctestrun").write_text("synthetic launch inputs")
            self.assertEqual(runner.finalize_fixture_run(bundle, output, "0" * 64, successful=True), [])
            self.assertFalse(private.exists())
            self.assertTrue((output / "result-bundle-disposal.json").exists())
            private.mkdir()
            with patch.object(runner, "prepare_private_result_bundle_path", return_value=private / "result.xcresult"):
                bundle = runner.prepare_fixture_result_bundle()
            bundle.mkdir()
            (private / "test.log").write_text("failed-run diagnostic")
            self.assertEqual(runner.finalize_fixture_run(bundle, output, None, successful=False), [])
            self.assertTrue(bundle.exists())
            self.assertTrue((private / "test.log").exists())
            self.assertTrue((output / "result-bundle-quarantine.json").exists())

    def test_device_labels_require_matching_simulator_type_and_official_device(self):
        for label, model, type_name, platform in (
                ("iphone", "iPhone 17e", "iPhone-17e", "iOS Simulator"),
                ("ipad", "iPad Air", "iPad-Air", "iOS Simulator"),
                ("appletv", "Apple TV 4K", "Apple-TV-4K", "tvOS Simulator")):
            device = {"udid": "target", "isAvailable": True,
                      "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + type_name}
            inventory = {"devices": {"runtime": [device]}}
            official = {"devices": [{"deviceId": "target", "modelName": model, "platform": platform}]}
            with self.subTest(label=label):
                runner.verify_simulator_device(inventory, "target", label)
                runner.verify_official_device(official, "target", label)
                for other in set(runner.DEVICES) - {label}:
                    with self.assertRaises(ContractError):
                        runner.verify_simulator_device(inventory, "target", other)
                    with self.assertRaises(ContractError):
                        runner.verify_official_device(official, "target", other)
                for bad in ({"devices": {}}, {"devices": {"runtime": [device, device]}},
                            {"devices": {"runtime": [dict(device, isAvailable=False)]}},
                            {"devices": {"runtime": [dict(device, deviceTypeIdentifier="unknown")]}}):
                    with self.assertRaises(ContractError):
                        runner.verify_simulator_device(bad, "target", label)
                for bad in ({}, {"devices": []}, {"devices": official["devices"] * 2},
                            {"devices": [dict(official["devices"][0], deviceId="other")]},
                            {"devices": [dict(official["devices"][0], platform="physical")]},
                            {"devices": [dict(official["devices"][0], modelName=None)]}):
                    with self.assertRaises(ContractError):
                        runner.verify_official_device(bad, "target", label)

    def test_ambient_and_prefixed_server_ui_and_debug_inputs_cannot_reach_fixture_runs(self):
        for prefix in ("", "TEST_RUNNER_", "SIMCTL_CHILD_", "TEST_RUNNER_SIMCTL_CHILD_"):
            for key in ("IMMICH_API_KEY", "IMMICH_TEST_SERVER_URL", "UI_TEST_SERVER_URL", "ENABLE_DEBUG_FILL_APIKEY",
                        "STRICT_E2E_INPUT_SERVER_URL"):
                with self.subTest(prefix=prefix, key=key):
                    self.assertEqual(clean_environment({prefix + key: "ambient", "PATH": "/bin"}), {"PATH": "/bin"})

    def test_compiled_enumeration_does_not_count_disabled_tests_or_ignore_errors(self):
        expected = [{"kind": "ui", "key": "Flow/testFirst", "dimensions": {"platform": "ios"}}]
        payload = {"errors": [], "values": [{"enabledTests": [{"identifier": "immichSlidesUITests/Flow/testFirst()"}],
                                             "disabledTests": [{"identifier": "immichSlidesUITests/Flow/testOther()"}]}]}
        self.assertEqual(compiled_tests(payload, expected), expected)
        with self.assertRaises(ContractError):
            compiled_tests(dict(payload, errors=["enumeration failed"]), expected)

    def test_enumeration_is_rerun_once_only_after_a_runner_bootstrap_crash(self):
        crash = {"errors": ["Runner (1) encountered an error. (Underlying Error: Early unexpected exit, operation never "
                            "finished bootstrapping - no restart will be attempted. (Underlying Error: Test crashed with "
                            "signal abrt while preparing to run tests.))"], "values": []}
        other = {"errors": ["enumeration failed"], "values": []}
        clean = {"errors": [], "values": []}
        for name, outputs, calls, retried in (("recovered", [crash, clean], 2, True), ("persistent", [crash, crash], 2, True),
                                              ("other error", [other, clean], 1, False), ("clean", [clean, clean], 1, False)):
            with self.subTest(name), tempfile.TemporaryDirectory() as directory:
                enumeration = Path(directory) / "compiled-tests.json"
                names = []
                def run(command_name):
                    enumeration.write_text(json.dumps(outputs[len(names)]))
                    names.append(command_name)
                    return 0
                code, record = runner.enumerate_tests_with_bootstrap_retry(run, enumeration)
                self.assertEqual((code, len(names), record is not None), (0, calls, retried))
                self.assertEqual(json.loads(enumeration.read_text()), outputs[calls - 1])
                if retried:
                    self.assertEqual((names, record["code"]), (["enumerate", "enumerate-retry"], "enumeration-bootstrap-retry"))
                    self.assertEqual(json.loads((Path(directory) / "compiled-tests-attempt-1.json").read_text()), crash)
        with self.assertRaises(ContractError):
            compiled_tests(crash, [])

    def test_default_plan_exclusions_and_explicit_selection_define_the_population(self):
        files = {"Tests.swift": "class Flow: XCTestCase { func testFirst() {} func testSecond() {} }"}
        plan = {"testTargets": [{"target": {"name": "immichSlidesUITests"},
                                 "skippedTests": ["Flow/testSecond()"]}]}
        self.assertEqual([entry["key"] for entry in declared_tests(files, "ios", plan, [])], ["Flow/testFirst"])
        with self.assertRaises(ContractError):
            declared_tests(files, "ios", plan, ["immichSlidesUITests/Flow/testSecond"])
        selected = {"testTargets": [{"target": {"name": "immichSlidesUITests"},
                                    "selectedTests": ["Flow/testSecond()"]}]}
        self.assertEqual([entry["key"] for entry in declared_tests(files, "ios", selected, [])], ["Flow/testSecond"])
        with self.assertRaises(ContractError):
            declared_tests(files, "ios", selected, ["immichSlidesUITests/Flow/testFirst"])
        selected["testTargets"][0]["enabled"] = False
        with self.assertRaises(ContractError):
            declared_tests(files, "ios", selected, [])

    def test_missing_duplicate_unexpected_and_skipped_results_cannot_be_covered(self):
        expected = [{"kind": "ui", "key": "Flow/testFirst", "dimensions": {"platform": "ios"}}]
        nodes = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "Flow/testFirst()",
                                "result": "Passed", "duration": "1秒", "durationInSeconds": 1.25}]}
        rows = coverage_rows(expected, expected, nodes, "iphone")
        self.assertEqual(rows[0]["outcome"], "passed")
        self.assertEqual(rows[0]["duration_seconds"], 1.25)
        same_name = [{"kind": "ui", "key": "immichSlidesUITests/testFirst", "dimensions": {"platform": "ios"}}]
        same_node = {"testNodes": [dict(nodes["testNodes"][0], nodeIdentifier="immichSlidesUITests/testFirst()")]}
        self.assertEqual(coverage_rows(same_name, same_name, same_node, "iphone")[0]["identity"], same_name[0])
        enumeration = {"errors": [], "values": [{"enabledTests": [
            {"identifier": "immichSlidesUITests/immichSlidesUITests/testFirst()"}]}]}
        self.assertEqual(compiled_tests(enumeration, same_name), same_name)
        missing = coverage_rows(expected, expected, {"testNodes": []}, "iphone")
        self.assertEqual(missing[0]["outcome"], "not-run")
        skipped = copy.deepcopy(nodes)
        skipped["testNodes"][0]["result"] = "Skipped"
        self.assertEqual(coverage_rows(expected, expected, skipped, "iphone")[0]["outcome"], "skipped")
        for malformed in ({"testNodes": nodes["testNodes"] * 2},
                          {"testNodes": [dict(nodes["testNodes"][0], nodeIdentifier="Flow/testOther()")]},
                          {"testNodes": [dict(nodes["testNodes"][0], result="Unknown")]},
                          {"testNodes": [dict(nodes["testNodes"][0], children=None)]},
                          {"testNodes": [dict(nodes["testNodes"][0], durationInSeconds="bad")]}):
            with self.subTest(malformed=malformed), self.assertRaises(ContractError):
                coverage_rows(expected, expected, malformed, "iphone")
        uncompiled = coverage_rows(expected, [], {"testNodes": []}, "iphone")
        self.assertEqual(uncompiled[0]["outcome"], "not-run")
        self.assertIn("not compiled", uncompiled[0]["reason"])
        unattempted = coverage_rows(expected, None, {"testNodes": []}, "iphone")
        self.assertEqual(unattempted[0]["outcome"], "not-run")
        self.assertEqual(unattempted[0]["reason"], "not attempted")

    def test_official_problem_details_keep_skip_reasons_and_require_matching_identity(self):
        payload = {"testIdentifier": "Flow/testFirst()", "testResult": "Skipped", "testRuns": [
            {"nodeType": "Device", "children": [{"nodeType": "Test Plan Configuration", "children": [
                {"nodeType": "Test Case Run", "result": "Skipped", "name": "Test skipped - opt-in is disabled"}]}]}]}
        self.assertEqual(problem_reason(payload, "Flow/testFirst"), "Test skipped - opt-in is disabled")
        for invalid in (dict(payload, testIdentifier="Flow/testOther()"), dict(payload, testRuns=[])):
            with self.subTest(invalid=invalid), self.assertRaises(ContractError):
                problem_reason(invalid, "Flow/testFirst")


class WaitFactorPolicyTests(unittest.TestCase):
    def test_nonfinite_out_of_range_and_non_numeric_factors_are_refused(self):
        from ci_wait_policy import wait_configuration
        for value in (float("nan"), float("inf"), 0, 0.5, 4.01, True, "2", None):
            with self.subTest(value=value), self.assertRaises(ContractError):
                wait_configuration(value)
        for value in (1, 2, 4):
            with self.subTest(value=value):
                self.assertEqual(value, wait_configuration(value)["infrastructure_factor"])
                self.assertEqual(1, wait_configuration(value)["product_factor"])


if __name__ == "__main__":
    unittest.main()
