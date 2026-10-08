"""Guard registry admission and listed-only retries against accidental green results."""

import copy
import io
import json
import os
import subprocess
import tempfile
import unittest
from datetime import date
from argparse import Namespace
from contextlib import ExitStack, redirect_stderr
from pathlib import Path
from unittest import mock

from ci_summary import ContractError, observation, test_identity
from ci_flaky import (eligible_entry, enumerated_ui_keys, load_registry, merge_retry, parse_registry, registry_revision, retry_command, run_xcode_attempts,
                      retry_observations, validate_registry_population)


def registry():
    identity = test_identity("ui", "ExampleTests/testNavigation", platform="ios")
    return {"schema_version": 1, "entries": [{
        "identity": identity, "scope": {"tier": "ui", "environment": "hermetic"},
        "issue": "https://github.com/sudoHG/immichSlides/issues/123",
        "owner": "sudoHG", "review_by": "2026-11-07", "added_on": "2026-10-07",
        "symptom": "Navigation occasionally stays on the prior screen",
        "evidence": ["Repeated failure and pass on 2026-10-07; see tracking issue"],
    }]}


class RegistryTests(unittest.TestCase):
    def test_schedule_consumes_only_tested_main_registry(self):
        environment = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "schedule", "GITHUB_SHA": "a" * 40,
                       "GITHUB_REF": "refs/heads/main"}
        with mock.patch("ci_flaky.subprocess.check_output", return_value="a" * 40):
            self.assertEqual(registry_revision(Path("."), environment), "a" * 40)
            with self.assertRaises(ContractError):
                registry_revision(Path("."), environment | {"GITHUB_REF": "refs/heads/candidate"})

    def test_pr_uses_merge_base_parent_and_never_candidate_or_ci_override(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = dict(os.environ, GIT_AUTHOR_NAME="CI Flaky", GIT_AUTHOR_EMAIL="ci-flaky@example.invalid",
                               GIT_COMMITTER_NAME="CI Flaky", GIT_COMMITTER_EMAIL="ci-flaky@example.invalid")
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, env=environment, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q")
            tree = git("mktree")
            base = git("commit-tree", tree, "-m", "base without registry")
            head = git("commit-tree", tree, "-p", base, "-m", "candidate")
            merge = git("commit-tree", tree, "-p", base, "-p", head, "-m", "merge")
            git("update-ref", "HEAD", merge)
            ci = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "pull_request", "GITHUB_SHA": merge}
            self.assertEqual(registry_revision(root, ci), base)
            self.assertEqual(load_registry(root, base)[0]["entries"], [])
            for changed in ({"GITHUB_SHA": head}, {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/candidate"}):
                with self.subTest(changed=changed), self.assertRaises(ContractError):
                    registry_revision(root, ci | changed)
            with self.assertRaises(ContractError):
                registry_revision(root, ci, head)
            self.assertEqual(registry_revision(root, {}, head), head)

    def test_invalid_format_duplicates_and_missing_tests_are_rejected(self):
        payload = registry()
        self.assertEqual(parse_registry(payload), payload)
        identity = payload["entries"][0]["identity"]
        validate_registry_population(payload, {"ios": [identity], "tvos": []})
        for field, value in (("owner", ""), ("review_by", "tomorrow"),
                             ("added_on", "2026-12-01"), ("evidence", []),
                             ("issue", "https://example.com/issues/123"),
                             ("identity", test_identity("python", "test_example")),
                             ("scope", {"tier": "unit", "environment": "hermetic"})):
            with self.subTest(field=field):
                invalid = copy.deepcopy(payload)
                invalid["entries"][0][field] = value
                with self.assertRaises(ContractError):
                    parse_registry(invalid)
        with self.assertRaises(ContractError):
            parse_registry(dict(payload, entries=payload["entries"] * 2))
        with self.assertRaises(ContractError):
            validate_registry_population(payload, {"ios": [], "tvos": []})
        with self.assertRaises(ContractError):
            parse_registry('{"schema_version":1,"schema_version":1,"entries":[]}')

    def test_only_exact_active_ui_or_strict_scope_is_eligible(self):
        payload = registry()
        identity = payload["entries"][0]["identity"]
        args = {"tier": "ui", "environment": "hermetic", "today": date(2026, 11, 7)}
        self.assertIsNotNone(eligible_entry(payload, identity, **args))
        for changed in ({"today": date(2026, 11, 8)}, {"tier": "strict"},
                        {"environment": "live"}):
            with self.subTest(changed=changed):
                self.assertIsNone(eligible_entry(payload, identity, **(args | changed)))
        self.assertIsNone(eligible_entry(payload, dict(identity, key="ExampleTests/testNew"), **args))
        self.assertIsNone(eligible_entry(payload, test_identity("swift", identity["key"], platform="ios"), **args))
        strict = copy.deepcopy(payload)
        strict_identity = test_identity("strict", identity["key"], device="iphone", configuration="Debug",
                                        suite="smoke", scenario="normal", fixture="a")
        strict["entries"][0]["identity"] = strict_identity
        strict["entries"][0]["scope"]["tier"] = "strict"
        strict_args = args | {"tier": "strict"}
        self.assertIsNotNone(eligible_entry(strict, strict_identity, **strict_args))
        for dimension, value in (("device", "ipad"), ("configuration", "Release"), ("suite", "journey-a"),
                                 ("scenario", "timeout"), ("fixture", "b")):
            with self.subTest(dimension=dimension):
                changed = dict(strict_identity, dimensions=strict_identity["dimensions"] | {dimension: value})
                self.assertIsNone(eligible_entry(strict, changed, **strict_args))
        # Calendar age belongs to the reporter, not PR format validation.
        validate_registry_population(payload, {"ios": [identity], "tvos": []})

    def test_recording_suites_cannot_be_registered_for_retry(self):
        from strict_e2e_runner_support import P2_CASES, SERVER_SWITCH_DISPLAY_SUITES
        suites = [suite for suite, case in P2_CASES.items() if case.video] + list(SERVER_SWITCH_DISPLAY_SUITES)
        for suite in suites:
            with self.subTest(suite=suite):
                payload = registry()
                payload["entries"][0]["scope"]["tier"] = "strict"
                payload["entries"][0]["identity"] = test_identity("strict", "ExampleTests/testNavigation",
                    device="iphone", configuration="Debug", suite=suite, scenario="normal", fixture="a")
                with self.assertRaisesRegex(ContractError, "recording"):
                    parse_registry(payload)


class RetryTests(unittest.TestCase):
    def test_official_failure_types_and_devices_control_retry_admission(self):
        from ci_flaky import read_xcode_observations
        identity = registry()["entries"][0]["identity"]
        device = {"deviceId": "target", "modelName": "iPhone 17", "platform": "iOS Simulator"}
        tests = {"devices": [device], "testNodes": [{"nodeType": "UI test bundle", "name": "immichSlidesUITests",
            "children": [{"nodeType": "Test Case", "nodeIdentifier": identity["key"] + "()",
                          "result": "Failed", "durationInSeconds": 1}]}]}
        for issue_types in (["Assertion Failure"], ["Crash"], ["Infrastructure Failure"], [],
                            ["Unknown"], ["Assertion Failure", "Crash"], ["Uncategorized"]):
            with self.subTest(issue_types=issue_types):
                issues = {"issues": {"testFailureSummaries": {"_values": [
                    {"testCaseName": {"_value": "ExampleTests.testNavigation()"},
                     "issueType": {"_value": kind}} for kind in issue_types]}}}
                def run(command, **kwargs):
                    details = {"testIdentifier": identity["key"] + "()", "testResult": "Failed", "testRuns": [
                        {"nodeType": "Test Case Run", "result": "Failed", "name": "failed - Deliberate assertion",
                         "sourceLocation": {"lineNumber": 12}}]}
                    return subprocess.CompletedProcess(command, 0, json.dumps(issues if "--legacy" in command else
                        details if "test-details" in command else tests))
                with mock.patch("ci_flaky.subprocess.run", side_effect=run):
                    rows = read_xcode_observations(Path("result"), lambda key: identity, 1, 65,
                                                   expected_device=("target", "iphone"))
                    resets = []
                    actual = retry_observations(rows, registry(), tier="ui", environment="hermetic",
                        today=date(2026, 10, 8), reset=lambda: resets.append(True),
                        execute=lambda key: observation(identity, "passed", 1))
                    self.assertEqual(bool(resets), issue_types in (["Assertion Failure"], ["Uncategorized"]))
                    self.assertEqual(actual[0]["outcome"], "flaky-passed" if resets else
                                     "crashed" if "Crash" in issue_types else "failed")
                    with self.assertRaises(ContractError):
                        read_xcode_observations(Path("result"), lambda key: identity, 1, 65,
                                                expected_device=("target", "ipad"))

    def test_uncategorized_details_require_assertion_message_and_source_location(self):
        from ci_flaky import official_assertion_details
        key = "ExampleTests/testNavigation()"
        for name, line, expected in (("failed - Deliberate assertion", 12, True),
                                     ("XCTAssertTrue failed - Navigation missing", 12, True),
                                     ("Crash: test runner exited unexpectedly", 12, False),
                                     ("Simulator connection lost", 12, False),
                                     ("Unknown failure", 12, False), ("failed - Deliberate assertion", 0, False)):
            with self.subTest(name=name, line=line):
                payload = {"testIdentifier": key, "testResult": "Failed", "testRuns": [{
                    "nodeType": "Test Case Run", "result": "Failed", "name": name, "sourceLocation": {"lineNumber": line}}]}
                self.assertEqual(official_assertion_details(payload, key), expected)

    def test_target_udid_refuses_device_class_mismatch(self):
        from ci_flaky import simulator_device_class
        payload = {"devices": {"runtime": [{"udid": "target", "deviceTypeIdentifier":
                   "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5"}]}}
        with mock.patch("ci_flaky.subprocess.run", return_value=subprocess.CompletedProcess([], 0, json.dumps(payload))):
            self.assertEqual(simulator_device_class("target", "ipad"), "ipad")
            with self.assertRaises(ContractError):
                simulator_device_class("target", "iphone")

    def test_second_execution_timeout_keeps_first_failure_and_both_invocations(self):
        from strict_e2e_runner_support import CommandError
        identity = registry()["entries"][0]["identity"]
        first = observation(identity, "failed", 1, reason="Official XCTest assertion failure", exit_code=65)
        command = ["xcodebuild", "test-without-building", "-resultBundlePath", "first-private/result.xcresult"]
        for error, outcome in ((CommandError("xcodebuild timed out after 300s without exiting."), "timed-out"),
                               (subprocess.TimeoutExpired("xcodebuild", 300), "timed-out"),
                               (CommandError("Cannot execute xcodebuild"), "not-run")):
            with self.subTest(error=error):
                actual = run_xcode_attempts(command, registry(), tier="ui", environment="hermetic",
                    today=date(2026, 10, 8), identity_for_key=lambda key: identity, reset=lambda: None,
                    execute=mock.Mock(side_effect=[(65, 1), error]), read=lambda *args: [first],
                    allocate_bundle=lambda: Path("second-private/result.xcresult"))
                self.assertEqual(actual["observed"][0]["attempts"][0], first["attempts"][0])
                self.assertEqual(actual["observed"][0]["attempts"][1]["outcome"], outcome)
                self.assertEqual(len(actual["invocations"]), 2)
                self.assertNotEqual(actual["exit_code"], 0)

    def test_timed_out_ui_invocation_keeps_failure_and_quarantines_unreadable_bundle(self):
        from ci_flaky import run_ui
        from strict_e2e_runner_support import CommandError
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root = Path(directory)
            checkout = root / "checkout"
            checkout.mkdir()
            output = root / "output"
            stack.enter_context(mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", root / "private"))
            stack.enter_context(mock.patch.dict(os.environ,
                {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}, clear=True))
            stack.enter_context(mock.patch("ci_build_archive.default_data_available_gib", return_value=39))
            executed = []
            disk_checks = []
            def subprocess_run(call, **kwargs):
                if call[0] == "df":
                    disk_checks.append(call)
                    return subprocess.CompletedProcess(call, 0)
                raise subprocess.CalledProcessError(1, "enumeration")
            def execute(call, **kwargs):
                Path(call[call.index("-resultBundlePath") + 1]).mkdir()
                executed.append(call)
                if len(executed) == 1:
                    return 65
                raise CommandError("xcodebuild timed out after 300s without exiting")
            patches = {
                "ci_build_archive.workspace_preflight": {"return_value": None},
                "ci_flaky.registry_revision": {"return_value": "b" * 40},
                "ci_flaky.load_registry": {"return_value": (registry(), "a" * 64)},
                "ci_flaky.simulator_device_class": {"return_value": "iphone"},
                "ci_flaky.subprocess.run": {"side_effect": subprocess_run},
                "ci_flaky.read_xcode_observations": {"return_value": [observation(
                    registry()["entries"][0]["identity"], "failed", 1, reason="Official XCTest assertion failure", exit_code=65)]},
                "run_host_checks.run_identity": {"return_value": {"schema_version": 1, "event": "local",
                    "repository": "sudoHG/immichSlides", "tree_sha": "a" * 40, "commit_sha": "b" * 40, "dirty": False}},
                "run_host_checks.source_metadata": {"return_value": (None, False)},
                "run_host_checks.toolchain": {"return_value": {"versions": {"python": "test"}}},
                "strict_e2e_runner_support.reset_simulator_app": {"return_value": "reset"},
                "run_strict_e2e.run_command": {"side_effect": execute},
                "run_strict_e2e.export_private_result_bundle": {"side_effect": CommandError("Official test export failed")},
            }
            for target, options in patches.items():
                stack.enter_context(mock.patch(target, **options))
            args = Namespace(root=checkout, output_dir=output, registry_ref=None, platform="ios", only_testing=[],
                xctestrun=root / "built.xctestrun", destination="platform=iOS Simulator,id=00000000-0000-0000-0000-000000000000",
                timeout_seconds=300, min_free_gib=30)
            with redirect_stderr(io.StringIO()):
                self.assertEqual(run_ui(args), 1)
            summary = json.loads((output / "summary.json").read_text())
            attempts = json.loads((output / "retry-invocations.json").read_text())
            self.assertEqual(len(attempts["invocations"]), 2)
            self.assertEqual(len(disk_checks), 3)
            self.assertEqual(attempts["invocations"][0]["exit_code"], 65)
            self.assertEqual(attempts["invocations"][1]["outcome"], "timed-out")
            self.assertEqual(summary["population"]["observed"][0]["attempts"][1]["outcome"], "timed-out")
            self.assertEqual(summary["status"], "failed")
            self.assertEqual({row["code"] for row in summary["infrastructure"]},
                             {"ui-runner-failed", "bundle-finalization-failed"})
            quarantine = json.loads((output / "result-bundle-quarantine-attempt-1.json").read_text())
            self.assertFalse(quarantine["result_bundle_disposed"])
            self.assertTrue(Path(quarantine["private_path"]).is_dir())
            self.assertFalse((output / "result-bundle-disposal-attempt-1.json").exists())

    def test_retry_bundles_have_independent_private_directories_and_all_dispose(self):
        from run_strict_e2e import finalize_private_result_bundle, prepare_private_result_bundle_path
        with tempfile.TemporaryDirectory() as directory, mock.patch(
                "run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", Path(directory) / "private"):
            evidence = Path(directory) / "exports"
            evidence.mkdir()
            payload = registry()
            first_identity = payload["entries"][0]["identity"]
            second_identity = dict(first_identity, key="ExampleTests/testOtherNavigation")
            payload["entries"].append(dict(payload["entries"][0], identity=second_identity))
            first_bundle = prepare_private_result_bundle_path("first")
            command = ["xcodebuild", "test-without-building", "-resultBundlePath", str(first_bundle)]
            def execute(call):
                Path(call[call.index("-resultBundlePath") + 1]).mkdir()
                return (65 if call == command else 0), 1
            records = iter([[observation(first_identity, "failed", 1, reason="Official XCTest assertion failure", exit_code=65),
                             observation(second_identity, "failed", 1, reason="Official XCTest assertion failure", exit_code=65)],
                            [observation(first_identity, "passed", 1)],
                            [observation(second_identity, "passed", 1)]])
            actual = run_xcode_attempts(command, payload, tier="ui", environment="hermetic", today=date(2026, 10, 8),
                identity_for_key=lambda key: dict(first_identity, key=key), reset=lambda: None,
                execute=execute, read=lambda *args: next(records),
                allocate_bundle=lambda: prepare_private_result_bundle_path("retry"))
            self.assertEqual(actual["exit_code"], 0)
            bundles = [Path(call["result_bundle"]) for call in actual["invocations"]]
            self.assertEqual(len({bundle.parent for bundle in bundles}), 3)
            for number, bundle in enumerate(bundles, 1):
                self.assertEqual(finalize_private_result_bundle(bundle, evidence, "a" * 64,
                                 successful=True, suffix=f"-attempt-{number}"), [])
                self.assertFalse(bundle.exists())
                self.assertFalse(bundle.parent.exists())

    def test_compiled_selection_accounts_for_xcode_disabled_nodes_and_errors(self):
        payload = {"errors": [], "values": [{"name": "immichSlides-iOS", "children": [{
            "name": "immichSlidesUITests", "children": [{"name": "ExampleTests", "children": [
                {"kind": "test", "name": "testNavigation()", "disabled": False},
                {"kind": "test", "name": "testUnselected()", "disabled": True}]}]}]}]}
        self.assertEqual(enumerated_ui_keys(payload), ["ExampleTests/testNavigation"])
        for changed in (dict(payload, errors=["bundle missing"]),
                        {"errors": [], "values": [{"name": "immichSlidesUITests", "disabled": True,
                                                   "children": payload["values"][0]["children"][0]["children"]}]}):
            with self.subTest(changed=changed), self.assertRaises(ContractError):
                enumerated_ui_keys(changed)

    def test_filtered_second_call_forbids_global_retry_and_iteration_flags(self):
        command = ["xcodebuild", "test", "-project", "App.xcodeproj",
                   "-only-testing:immichSlidesUITests/ExampleTests", "-resultBundlePath", "first.xcresult"]
        actual = retry_command(command, "ExampleTests/testNavigation", "second.xcresult")
        self.assertIn("test-without-building", actual)
        self.assertNotIn("test", actual)
        self.assertEqual([item for item in actual if item.startswith("-only-testing:")],
                         ["-only-testing:immichSlidesUITests/ExampleTests/testNavigation"])
        self.assertEqual(actual[actual.index("-resultBundlePath") + 1], "second.xcresult")
        for flag in ("-retry-tests-on-failure", "-test-iterations",
                     "-run-tests-until-failure", "-maximum-test-iterations", "-test-repetition-relaunch-enabled"):
            with self.subTest(flag=flag), self.assertRaises(ContractError):
                retry_command(command + [flag, "2"], "ExampleTests/testNavigation", "second.xcresult")

    def test_only_failed_listed_observations_reset_and_execute_once(self):
        payload = registry()
        listed = payload["entries"][0]["identity"]
        unlisted = dict(listed, key="ExampleTests/testUnlisted")
        first = [observation(listed, "failed", 1, reason="Official XCTest assertion failure", exit_code=65),
                 observation(unlisted, "failed", 2, reason="Official XCTest assertion failure", exit_code=65)]
        events = []
        def execute(identity):
            events.append(("execute", identity))
            return observation(identity, "passed", 3)
        actual = retry_observations(first, payload, tier="ui", environment="hermetic",
                                    today=date(2026, 10, 8), reset=lambda: events.append("reset"), execute=execute)
        self.assertEqual(events, ["reset", ("execute", listed)])
        self.assertEqual(actual[0]["outcome"], "flaky-passed")
        self.assertEqual(actual[0]["duration_seconds"], 4)
        self.assertEqual([item["number"] for item in actual[0]["attempts"]], [1, 2])
        self.assertEqual(actual[1], first[1])
        self.assertEqual(first[0]["outcome"], "failed")
        for outcome in ("passed", "skipped", "crashed", "timed-out", "not-run"):
            with self.subTest(outcome=outcome):
                events.clear()
                retry_observations([observation(listed, outcome, 1, reason="fixture unavailable")], payload,
                                   tier="ui", environment="hermetic", today=date(2026, 10, 8),
                                   reset=lambda: events.append("reset"), execute=execute)
                self.assertEqual(events, [])

    def test_skip_crash_timeout_missing_mismatch_and_failed_retry_stay_failed(self):
        identity = registry()["entries"][0]["identity"]
        first = observation(identity, "failed", 1, exit_code=65)
        for outcome in ("passed", "failed", "skipped", "crashed", "timed-out", "not-run"):
            with self.subTest(outcome=outcome):
                second = observation(identity, outcome, 2, reason="unavailable", exit_code=0 if outcome == "passed" else 65)
                actual = merge_retry(first, second)
                self.assertEqual(actual["outcome"], "flaky-passed" if outcome == "passed" else "failed")
                self.assertEqual(len(actual["attempts"]), 2)
        self.assertEqual(merge_retry(first, None)["outcome"], "failed")
        wrong = observation(dict(identity, key="ExampleTests/testOther"), "passed", 2)
        with self.assertRaises(ContractError):
            merge_retry(first, wrong)
        with self.assertRaises(ContractError):
            merge_retry(merge_retry(first, None), None)

    def test_invocation_failure_missing_extra_and_wrong_rows_cannot_become_flaky_passes(self):
        payload = registry()
        identity = payload["entries"][0]["identity"]
        command = ["xcodebuild", "test-without-building", "-resultBundlePath", "first.xcresult",
                   "-only-testing:immichSlidesUITests/ExampleTests"]
        for retry_exit, retry_rows, expected in (
                (0, [observation(identity, "passed", 2)], "flaky-passed"),
                (65, [observation(identity, "passed", 2)], "failed"),
                (0, [], "failed"),
                (0, [observation(identity, "passed", 2)] * 2, "failed"),
                (0, [observation(dict(identity, key="ExampleTests/testOther"), "passed", 2)], "failed")):
            with self.subTest(retry_exit=retry_exit, rows=retry_rows):
                codes = iter([(65, 1), (retry_exit, 2)])
                rows = iter([[observation(identity, "failed", 1, reason="Official XCTest assertion failure", exit_code=65)], retry_rows])
                events = []
                actual = run_xcode_attempts(command, payload, tier="ui", environment="hermetic", today=date(2026, 10, 8),
                    identity_for_key=lambda key: dict(identity, key=key), reset=lambda: events.append("reset"),
                    execute=lambda call: next(codes), read=lambda *args: next(rows),
                    allocate_bundle=lambda: Path("retry-private") / "second.xcresult")
                self.assertEqual(events, ["reset"])
                self.assertEqual(actual["observed"][0]["outcome"], expected)
                self.assertEqual(actual["exit_code"], 0 if expected == "flaky-passed" else 65)
        for code in (0, 1, 124, 130):
            with self.subTest(first_exit=code):
                events = []
                actual = run_xcode_attempts(command, payload, tier="ui", environment="hermetic", today=date(2026, 10, 8),
                    identity_for_key=lambda key: dict(identity, key=key), reset=lambda: events.append("reset"),
                    execute=lambda call: (code, 1), read=lambda *args: [observation(identity, "failed", 1, exit_code=code)],
                    allocate_bundle=lambda: self.fail("must not allocate retry bundle"))
                self.assertEqual(events, [])
                self.assertNotEqual(actual["exit_code"], 0)
        actual = run_xcode_attempts(command, payload, tier="ui", environment="hermetic", today=date(2026, 10, 8),
            identity_for_key=lambda key: dict(identity, key=key), reset=lambda: self.fail("must not reset"),
            execute=lambda call: (65, 1), read=lambda *args: [observation(identity, "passed", 1)],
            allocate_bundle=lambda: self.fail("must not allocate retry bundle"))
        self.assertEqual(actual["exit_code"], 65)


if __name__ == "__main__":
    unittest.main()
