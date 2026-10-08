"""Guard per-test fixture coverage against missing, duplicate and skipped results."""

import copy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import run_fixture_ui_tests as runner
from ci_summary import ContractError
from run_fixture_ui_tests import clean_environment, compiled_tests, coverage_rows, declared_tests, problem_reason


class FixtureCoverageTests(unittest.TestCase):
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

    def test_default_plan_exclusions_and_explicit_selection_define_the_population(self):
        files = {"Tests.swift": "class Flow: XCTestCase { func testFirst() {} func testSecond() {} }"}
        plan = {"testTargets": [{"target": {"name": "immichSlidesUITests"},
                                 "skippedTests": ["Flow/testSecond()"]}]}
        self.assertEqual([entry["key"] for entry in declared_tests(files, "ios", plan, [])], ["Flow/testFirst"])
        with self.assertRaises(ContractError):
            declared_tests(files, "ios", plan, ["immichSlidesUITests/Flow/testSecond"])

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


if __name__ == "__main__":
    unittest.main()
