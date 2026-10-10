"""Guard per-test fixture coverage against missing, duplicate and skipped results."""

import copy
import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import run_fixture_ui_tests as runner
from ci_summary import ContractError
from run_fixture_ui_tests import clean_environment, compiled_tests, coverage_rows, declared_tests, problem_reason


class FixtureCoverageTests(unittest.TestCase):
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
            prepared = runner.prepare_test_run(source, screenshots, {"IMMICH_TEST_API_KEY": "public-fixture-input"}, failure_screenshots=True)
            targets = plistlib.loads(prepared.read_bytes())["TestConfigurations"][0]["TestTargets"]
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
