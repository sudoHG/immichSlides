"""Guard registry admission and listed-only retries against accidental green results."""

import copy
import os
import subprocess
import tempfile
import unittest
from datetime import date
from pathlib import Path
from unittest import mock

from ci_summary import ContractError, observation, test_identity
from ci_flaky import (eligible_entry, enumerated_ui_keys, load_registry, merge_retry, parse_registry, registry_revision, retry_command, run_xcode_attempts,
                      retry_observations, validate_registry_population, nightly_findings)


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
    def test_pr_uses_merge_base_parent_and_never_candidate_or_ci_override(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = dict(os.environ, GIT_AUTHOR_NAME="sudoHG", GIT_AUTHOR_EMAIL="by331works@gmail.com",
                               GIT_COMMITTER_NAME="sudoHG", GIT_COMMITTER_EMAIL="by331works@gmail.com")
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
        # Age and issue state belong to nightly, not PR format validation.
        validate_registry_population(payload, {"ios": [identity], "tvos": []})
        findings = nightly_findings(payload, today=date(2026, 11, 8), issue_states={123: "closed"})
        self.assertEqual({finding["code"] for finding in findings}, {"expired", "issue-closed"})


class RetryTests(unittest.TestCase):
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
            records = iter([[observation(first_identity, "failed", 1, exit_code=65),
                             observation(second_identity, "failed", 1, exit_code=65)],
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
        first = [observation(listed, "failed", 1, exit_code=65), observation(unlisted, "failed", 2, exit_code=65)]
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
                rows = iter([[observation(identity, "failed", 1, exit_code=65)], retry_rows])
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
