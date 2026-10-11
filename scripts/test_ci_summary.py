"""Guard the producer/reader contract and honest host-check failure reporting."""

import copy
import contextlib
import hashlib
import io
import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import ci_summary
import ci_verdict
import run_host_checks
import run_python_tests


def valid_summary():
    identity = ci_summary.test_identity("host", "format")
    return {
        "schema_version": 1,
        "identity": {"schema_version": 1, "event": "local", "repository": "sudoHG/immichSlides",
                     "commit_sha": "a" * 40, "tree_sha": "b" * 40, "dirty": False},
        "source": {"repository": "sudoHG/immichSlides", "workflow_path": None, "event": "local",
                   "fork_originated": False, "ci_changing": None},
        "run": {"id": None, "attempt": 1, "tier": "host", "job": "host-checks", "shard": None},
        "hashes": {"manifests": {}, "policies": {}},
        "toolchain": {"versions": {"python": "3.13"}, "signing_mode": "not-applicable"},
        "population": {"declared": [identity], "compiled": [identity],
                       "observed": [ci_summary.observation(identity, "passed", 0.1)],
                       "deselected": [], "removed_by_pr": []},
        "infrastructure": [], "status": "passed",
    }


def discovery_summary():
    summary = valid_summary()
    summary.update(schema_version=2, identity={"schema_version": 1, "event": "pull_request",
        "repository": "sudoHG/immichSlides", "pull_request": 1, "base_sha": "a" * 40,
        "head_sha": "b" * 40, "merge_sha": "c" * 40, "tree_sha": "d" * 40})
    summary["source"].update(event="pull_request", workflow_path=".github/workflows/ci-ui.yml")
    summary["run"] = {"id": "123", "attempt": 1, "tier": "ui", "job": "ui-iphone", "shard": "scoped-a"}
    entry = ci_summary.test_identity("ui", "SettingsUITests/testOpen", platform="ios", device="iphone")
    summary["population"].update(declared=[entry], compiled=[entry],
        observed=[ci_summary.observation(entry, "passed", 1)])
    summary["hashes"]["manifests"]["ui-scoped-plan"] = "e" * 64
    summary["compiled_evidence"] = {"schema_version": 1, "mode": "official-result-discovery-v1",
        "identity": copy.deepcopy(summary["identity"]), "run": dict(summary["run"]), "plan_sha256": "e" * 64,
        "device_id": "target", "first_exit_code": 0,
        "official_tests": {"devices": [{"deviceId": "target", "modelName": "iPhone 17", "platform": "iOS Simulator"}],
            "testNodes": [{"nodeType": "UI test bundle", "name": "immichSlidesUITests", "children": [
                {"nodeType": "Test Case", "nodeIdentifier": entry["key"] + "()",
                 "result": "Passed", "durationInSeconds": 1}]}]}}
    refresh_discovery_hash(summary)
    return summary


def refresh_discovery_hash(summary):
    raw = json.dumps(summary["compiled_evidence"], sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    summary["hashes"]["manifests"]["ui-discovery"] = hashlib.sha256(raw).hexdigest()


class SummaryContractTests(unittest.TestCase):
    def test_scoped_official_discovery_requires_bound_complete_compiled_and_executed_population(self):
        summary = discovery_summary()
        self.assertEqual(ci_summary.parse_summary(json.dumps(summary)), summary)
        changes = (
            lambda value: value["compiled_evidence"].update(mode="unknown"),
            lambda value: value["compiled_evidence"].update(schema_version=True),
            lambda value: value["compiled_evidence"].update(first_exit_code=True),
            lambda value: value["compiled_evidence"]["run"].update(attempt=2),
            lambda value: value["compiled_evidence"]["identity"].update(head_sha="f" * 40),
            lambda value: value["compiled_evidence"].update(plan_sha256="f" * 64),
            lambda value: value["compiled_evidence"].update(first_exit_code=65),
            lambda value: value["compiled_evidence"]["official_tests"]["devices"][0].update(modelName="iPad Pro"),
            lambda value: value["compiled_evidence"]["official_tests"]["devices"][0].update(deviceId="other"),
            lambda value: value["compiled_evidence"]["official_tests"]["testNodes"][0].update(children=[]),
            lambda value: value["compiled_evidence"]["official_tests"]["testNodes"][0].update(name="immichSlidesTests"),
            lambda value: value["population"].update(compiled=[]),
            lambda value: value["population"].update(observed=[]),
        )
        for mutate in changes:
            bad = copy.deepcopy(summary)
            mutate(bad)
            refresh_discovery_hash(bad)
            with self.subTest(mutate=mutate), self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_summary(bad)
        bad = copy.deepcopy(summary)
        bad["compiled_evidence"]["official_tests"]["testNodes"][0]["children"].append(
            copy.deepcopy(bad["compiled_evidence"]["official_tests"]["testNodes"][0]["children"][0]))
        refresh_discovery_hash(bad)
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(bad)
        from ci_ui_discovery import MAX_EXPORT_BYTES, MAX_EXPORT_DEPTH, MAX_EXPORT_NODES
        nested = None
        for _ in range(MAX_EXPORT_DEPTH + 1):
            nested = {"child": nested}
        for padding in ("x" * (MAX_EXPORT_BYTES + 1), [None] * (MAX_EXPORT_NODES + 1), nested):
            bad = copy.deepcopy(summary)
            bad["compiled_evidence"]["official_tests"]["padding"] = padding
            refresh_discovery_hash(bad)
            with self.subTest(padding_type=type(padding).__name__), self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_summary(bad)
        bad = copy.deepcopy(summary)
        bad["hashes"]["manifests"]["ui-discovery"] = "f" * 64
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(bad)
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / "summary.json"
            record.write_text(json.dumps(bad))
            result = subprocess.run([sys.executable, str(Path(ci_summary.__file__)), str(record)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 1)
            self.assertTrue(result.stdout.startswith("FAIL:"), result)
            self.assertNotIn("Traceback", result.stderr)

    def test_incomplete_official_discovery_writes_fail_only_diagnostics_with_raw_first_exit(self):
        from run_fixture_ui_tests import write_fixture_summary
        missing = ci_summary.test_identity("ui", "SettingsUITests/testMissing", platform="ios", device="iphone")
        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        for code, export in ((1, "partial"), (65, "partial-unread"), (65, "empty"), (124, "missing")):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                summary = discovery_summary()
                summary["status"] = "failed"
                summary["compiled_evidence"]["first_exit_code"] = code
                summary["population"]["declared"].append(missing)
                if export == "empty":
                    summary["compiled_evidence"]["official_tests"]["testNodes"][0]["children"] = []
                    summary["population"]["compiled"] = []
                    summary["population"]["observed"] = []
                elif export == "missing":
                    summary["compiled_evidence"]["official_tests"] = None
                    summary["population"]["compiled"] = []
                    summary["population"]["observed"] = []
                elif export == "partial-unread":
                    summary["population"]["compiled"] = []
                    summary["population"]["observed"] = []
                self.assertEqual(write_fixture_summary(summary, Path(directory)), code)
                saved = ci_summary.parse_summary((Path(directory) / "summary.json").read_text())
                undiscovered = [entry for entry in saved["population"]["observed"]
                                if entry["identity"] not in saved["population"]["compiled"]]
                self.assertTrue(undiscovered)
                self.assertEqual({entry["outcome"] for entry in undiscovered}, {"timed-out" if code == 124 else "not-run"})
                self.assertEqual({entry["attempts"][0]["exit_code"] for entry in undiscovered}, {code})
                verdict = ci_verdict.evaluate_population(saved, saved["population"]["declared"], policy, environment="fixture")
                self.assertEqual(verdict["status"], "failed")
                self.assertEqual(sorted(map(ci_summary.identity_key, verdict["missing_compiled"])),
                                 sorted(ci_summary.identity_key(entry["identity"]) for entry in undiscovered))
                def claim_missing_passed(value):
                    entry = value["population"]["observed"][-1]
                    entry["outcome"] = entry["attempts"][0]["outcome"] = "passed"
                    entry["attempts"][0]["exit_code"] = 0
                for mutate in (lambda value: value.update(status="passed"),
                               lambda value: value["compiled_evidence"].update(first_exit_code=0),
                               lambda value: value["population"]["compiled"].append(missing),
                               claim_missing_passed,
                               lambda value: value["population"]["observed"][-1]["attempts"][0].update(exit_code=0)):
                    bad = copy.deepcopy(saved)
                    mutate(bad)
                    refresh_discovery_hash(bad)
                    with self.subTest(mutate=mutate), self.assertRaises(ci_summary.ContractError):
                        ci_summary.parse_summary(bad)

    def test_official_discovery_cannot_cover_nightly_full_or_deselected_tests(self):
        for mutate in (lambda value: value["run"].update(shard="visual-a"),
                       lambda value: value["source"].update(workflow_path=".github/workflows/ci-nightly.yml"),
                       lambda value: value["population"]["deselected"].append({
                           "identity": value["population"]["declared"][0], "reason": "not runnable", "owning_tier": "nightly"})):
            bad = discovery_summary()
            mutate(bad)
            bad["compiled_evidence"]["run"] = dict(bad["run"])
            refresh_discovery_hash(bad)
            with self.subTest(mutate=mutate), self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_summary(bad)

    def test_official_discovery_retains_first_failure_raw_exit_and_expected_skip(self):
        for result, outcome, code in (("Failed", "failed", 65), ("Skipped", "skipped", 0)):
            summary = discovery_summary()
            summary['compiled_evidence']['first_exit_code'] = code
            case = summary['compiled_evidence']['official_tests']['testNodes'][0]['children'][0]
            case['result'] = result
            summary['population']['observed'] = [ci_summary.observation(summary['population']['declared'][0],
                outcome, 1, exit_code=code, reason='Official XCTest ' + result)]
            summary['status'] = 'failed' if code else 'passed'
            refresh_discovery_hash(summary)
            with self.subTest(result=result):
                self.assertEqual(ci_summary.parse_summary(summary), summary)
            def change_consistent_duration(value):
                observed = value['population']['observed'][0]
                observed['duration_seconds'] = observed['attempts'][0]['duration_seconds'] = 2
            for mutate in (lambda value: value['population']['observed'][0]['attempts'][0].update(exit_code=1),
                           change_consistent_duration,
                           lambda value: value['compiled_evidence'].update(first_exit_code=0 if code else 65)):
                bad = copy.deepcopy(summary)
                mutate(bad)
                refresh_discovery_hash(bad)
                with self.subTest(result=result, mutate=mutate), self.assertRaises(ci_summary.ContractError):
                    ci_summary.parse_summary(bad)

    def test_host_platform_parts_preserve_every_identity_once(self):
        from run_host_checks import MACOS_PYTHON_TESTS, host_partition
        population = [ci_summary.test_identity("host", name) for name, _ in run_host_checks.HOST_CHECKS]
        population += [ci_summary.test_identity("python", key) for key in MACOS_PYTHON_TESTS]
        population.append(ci_summary.test_identity("python", "test_example.ExampleTests.testPortable"))
        linux, macos = (host_partition(population, scope) for scope in ("linux", "macos"))
        key = ci_summary.identity_key
        self.assertFalse(set(map(key, linux)) & set(map(key, macos)))
        self.assertEqual(sorted(map(key, population)), sorted(map(key, linux + macos)))
        self.assertEqual({entry["key"] for entry in macos}, {"swift-format lint", *MACOS_PYTHON_TESTS})
        removed = [entry for entry in population if entry["key"] not in MACOS_PYTHON_TESTS]
        renamed = removed + [ci_summary.test_identity("python", "test_example.ExampleTests.testRenamedSwiftCase")]
        for entries in (removed, renamed):
            parts = [host_partition(entries, scope) for scope in ("linux", "macos")]
            self.assertEqual(sorted(map(key, entries)), sorted(map(key, parts[0] + parts[1])))
            self.assertEqual({entry["key"] for entry in parts[1]}, {"swift-format lint"})
        for entries, scope in ((population, "unknown"), (population + population[:1], "linux"),
                               ([entry for entry in population if entry["key"] != "workflow policy"], "linux")):
            with self.subTest(scope=scope), self.assertRaises(ci_summary.ContractError):
                host_partition(entries, scope)

    def test_current_summary_round_trips_and_names_failures_in_markdown(self):
        summary = valid_summary()
        self.assertEqual(ci_summary.parse_summary(json.dumps(summary)), summary)
        summary["population"]["observed"][0] = ci_summary.observation(
            summary["population"]["declared"][0], "failed", 0.2, message="format exited 1", exit_code=1)
        summary["status"] = "failed"
        self.assertIn("format exited 1", ci_summary.render_markdown(ci_summary.parse_summary(summary)))
        from ci_unit_tests import judge_execution
        from run_offline_unit_tests import TestResultsSummary
        unit = valid_summary()
        skipped = ci_summary.observation(ci_summary.test_identity("swift", "immichSlidesTests/A/a()", platform="ios"),
                                         "skipped", 0, reason="Test skipped")
        proposed = {"schema_version": 1, "approval_records": [], "deselections": [], "expected_skips": [
            {"kind": "swift", "key_pattern": skipped["identity"]["key"], "dimensions": {"platform": "ios"},
             "tier": "unit", "environment": "hermetic", "reason": "Test skipped"}]}
        self.assertEqual(judge_execution(unit, {"A/a()"}, [skipped], TestResultsSummary(1, 0, 0, 1, "Passed"), 0, proposed), 0)
        diagnostics = [(code, category, "diagnostic detail") for code, category in
                       (("policy-proposed", "Policy"), ("population-invalid", "Population"),
                        ("coverage-failed", "Coverage"), ("step-timeout", "Infrastructure"))]
        diagnostics.append((unit["infrastructure"][0]["code"], "Policy", unit["infrastructure"][0]["message"]))
        for code, category, message in diagnostics:
            with self.subTest(code=code):
                summary["infrastructure"] = [{"code": code, "message": message}]
                markdown = ci_summary.render_markdown(summary)
                self.assertIn(f"{category}: {code}: {message}", markdown)
                if category != "Infrastructure":
                    self.assertNotIn("Infrastructure:", markdown)

    def test_malformed_or_unknown_contracts_are_rejected(self):
        changes = [
            ("schema_version", 99), ("schema_version", True), ("status", "green"),
            ("unexpected_field", 1), ("run.attempt", 0), ("run.attempt", True),
            ("source.repository", "other/repo"), ("source.event", "push"),
            ("hashes.policies.skip", "not-a-hash"), ("toolchain.signing_mode", "disabled"),
            ("population.observed.0.duration_seconds", -1),
            ("population.observed.0.attempts.0.duration_seconds", float("nan")),
            ("population.observed.0.outcome", "invented"),
            ("population.observed.0.attempts.0.number", 2),
        ]
        for path, value in changes:
            with self.subTest(path=path, value=value):
                summary = valid_summary()
                target = summary
                parts = path.split(".")
                for part in parts[:-1]:
                    target = target[int(part)] if isinstance(target, list) else target[part]
                target[parts[-1]] = value
                with self.assertRaises(ci_summary.ContractError):
                    ci_summary.parse_summary(summary)
        for raw in ('[]', '{', '{"schema_version":1,"schema_version":2}'):
            with self.subTest(raw=raw), self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_summary(raw)
        summary = valid_summary()
        del summary["population"]
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(summary)

    def test_explicit_successor_reader_is_required_before_producer_transition(self):
        summary = valid_summary()
        summary["schema_version"] = 2
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(summary)

        def successor(payload):
            normalized = copy.deepcopy(payload)
            normalized["schema_version"] = 1
            ci_summary.validate_summary_v1(normalized)

        with patch.dict(ci_summary.SUMMARY_READERS, {2: successor}):
            self.assertEqual(ci_summary.parse_summary(summary), summary)
            summary["run"]["attempt"] = 0
            with self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_summary(summary)

    def test_duplicate_identities_and_unexplained_skips_or_deselections_are_rejected(self):
        for collection in ("declared", "compiled", "observed"):
            with self.subTest(collection=collection):
                summary = valid_summary()
                summary["population"][collection] *= 2
                with self.assertRaises(ci_summary.ContractError):
                    ci_summary.parse_summary(summary)
        summary = valid_summary()
        entry = summary["population"]["observed"][0]
        entry["outcome"] = entry["attempts"][0]["outcome"] = "skipped"
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(summary)
        summary = valid_summary()
        summary["population"]["deselected"] = [{"identity": summary["population"]["declared"][0],
                                                "reason": "live only", "owning_tier": ""}]
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(summary)

    def test_strict_keys_and_retry_attempts_preserve_full_identity_and_outcomes(self):
        summary = valid_summary()
        identity = ci_summary.test_identity("strict", "playback", device="iphone", configuration="Release",
                                            suite="smoke", scenario="single", fixture="A")
        summary["population"]["declared"] = summary["population"]["compiled"] = [identity]
        entry = ci_summary.observation(identity, "failed", 1, exit_code=1)
        entry["attempts"].append({"number": 2, "outcome": "passed", "duration_seconds": 2,
                                  "exit_code": 0, "reason": None, "message": None})
        entry["outcome"] = "flaky-passed"
        entry["duration_seconds"] = 3
        summary["population"]["observed"] = [entry]
        ci_summary.parse_summary(summary)
        entry["outcome"] = "failed"
        entry["attempts"][1]["outcome"] = "skipped"
        entry["attempts"][1]["reason"] = "retry fixture unavailable"
        ci_summary.parse_summary(summary)
        del identity["dimensions"]["fixture"]
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(summary)

    def test_ci_identity_schemas_fail_closed(self):
        pr = {"schema_version": 1, "event": "pull_request", "repository": "sudoHG/immichSlides",
              "pull_request": 86, "merge_sha": "a" * 40, "base_sha": "b" * 40,
              "head_sha": "c" * 40, "tree_sha": "d" * 40}
        push = {"schema_version": 1, "event": "push", "repository": "sudoHG/immichSlides",
                "ref": "refs/heads/main", "pushed_sha": "a" * 40, "tree_sha": "b" * 40}
        dispatch = {"schema_version": 1, "event": "workflow_dispatch", "repository": "sudoHG/immichSlides",
                    "ref": "refs/heads/feature", "commit_sha": "a" * 40, "tree_sha": "b" * 40}
        schedule = dict(dispatch, event="schedule", ref="refs/heads/main")
        for identity in (pr, push, dispatch, schedule):
            self.assertEqual(ci_summary.parse_identity(json.dumps(identity)), identity)
            for key in identity:
                broken = dict(identity)
                del broken[key]
                with self.subTest(event=identity["event"], key=key), self.assertRaises(ci_summary.ContractError):
                    ci_summary.parse_identity(broken)
        push["ref"] = "refs/heads/other"
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_identity(push)
        for ref in (None, "", "main", "refs/pull/120/merge"):
            with self.subTest(ref=ref), self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_identity(dict(dispatch, ref=ref))
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_identity(dict(schedule, ref="refs/heads/feature"))


class HostResultTests(unittest.TestCase):
    def test_local_repository_metadata_accepts_remote_forms_and_missing_origin(self):
        remotes = [
            ("https://github.com/sudoHG/immichSlides.git/", "sudoHG/immichSlides"),
            ("ssh://git@github.com/sudoHG/immichSlides.git", "sudoHG/immichSlides"),
            ("git@github-work:sudoHG/immichSlides/", "sudoHG/immichSlides"),
            ("/tmp/local-clone", None),
            (subprocess.CalledProcessError(2, ["git", "remote", "get-url", "origin"]), None),
        ]
        for remote, repository in remotes:
            with self.subTest(remote=remote):
                def answers(*args):
                    if args == ("remote", "get-url", "origin"):
                        if isinstance(remote, Exception):
                            raise remote
                        return remote
                    return {("rev-parse", "HEAD"): "a" * 40,
                            ("rev-parse", "HEAD^{tree}"): "b" * 40,
                            ("status", "--porcelain"): ""}[args]

                with patch.object(run_host_checks, "git", side_effect=answers):
                    # Ambient CI configuration must not switch a local caller into CI mode.
                    identity = run_host_checks.run_identity({"GITHUB_EVENT_NAME": "workflow_dispatch",
                                                             "GITHUB_REPOSITORY": "other/repo"})
                self.assertEqual(identity["event"], "local")
                self.assertEqual(identity["repository"], repository)
                summary = valid_summary()
                summary["identity"] = identity
                summary["source"]["repository"] = repository
                ci_summary.parse_summary(summary)
        with tempfile.TemporaryDirectory() as directory, \
                patch("sys.argv", ["run_host_checks.py", "--output-dir", directory]), \
                patch.object(run_host_checks, "git", side_effect=subprocess.CalledProcessError(128, ["git"])), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(run_host_checks.main(), 1)
        self.assertIn("Git metadata command failed", errors.getvalue())

    def test_ci_source_cross_checks_workflow_reference_and_handles_deleted_forks(self):
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            identity = {"event": "pull_request", "repository": "sudoHG/immichSlides"}
            workflow = ".github/workflows/ci-gate.yml"
            env = {"GITHUB_EVENT_PATH": str(event_path),
                   "GITHUB_WORKFLOW_REF": f"sudoHG/immichSlides/{workflow}@refs/pull/120/merge"}
            for repo, expected in (({"full_name": "sudoHG/immichSlides"}, False),
                                   ({"full_name": "contributor/immichSlides"}, True), (None, True)):
                with self.subTest(repo=repo):
                    event_path.write_text(json.dumps({"pull_request": {"head": {"repo": repo}}}))
                    self.assertEqual(run_host_checks.source_metadata(identity, env, workflow), (workflow, expected))
            for reference, requested in ((env["GITHUB_WORKFLOW_REF"], ".github/workflows/copied.yml"),
                                         ("other/repo/.github/workflows/ci-gate.yml@main", workflow),
                                         ("", workflow)):
                with self.subTest(reference=reference), self.assertRaises(ci_summary.ContractError):
                    run_host_checks.source_metadata(identity, dict(env, GITHUB_WORKFLOW_REF=reference), requested)

    def test_pr_identity_reads_checkout_parents_instead_of_event_claims(self):
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            event_path.write_text(json.dumps({"number": 86, "pull_request": {
                "base": {"sha": "0" * 40}, "head": {"sha": "0" * 40}}}))
            answers = {("rev-parse", "HEAD"): "a" * 40,
                       ("rev-parse", "HEAD^{tree}"): "d" * 40,
                       ("cat-file", "commit", "a" * 40): "tree " + "d" * 40 + "\nparent " + "b" * 40 +
                       "\nparent " + "c" * 40 + "\nauthor Contributor\n\nMerge message"}
            env = {"GITHUB_REPOSITORY": "sudoHG/immichSlides", "GITHUB_EVENT_NAME": "pull_request",
                   "GITHUB_SHA": "a" * 40, "GITHUB_EVENT_PATH": str(event_path)}
            with patch.object(run_host_checks, "git", side_effect=lambda *args: answers[args]):
                identity = run_host_checks.run_identity(env, ci=True)
                self.assertEqual((identity["base_sha"], identity["head_sha"]), ("b" * 40, "c" * 40))
                env["GITHUB_SHA"] = "0" * 40
                with self.assertRaises(ci_summary.ContractError):
                    run_host_checks.run_identity(env, ci=True)
                env["GITHUB_SHA"] = "a" * 40
                answers[("cat-file", "commit", "a" * 40)] = "parent " + "b" * 40 + "\n\nMerge message"
                with self.assertRaises(ci_summary.ContractError):
                    run_host_checks.run_identity(env, ci=True)
                for event, ref, field in (("push", "refs/heads/main", "pushed_sha"),
                                          ("schedule", "refs/heads/main", "commit_sha"),
                                          ("workflow_dispatch", "refs/heads/feature", "commit_sha")):
                    with self.subTest(event=event):
                        trigger = dict(env, GITHUB_EVENT_NAME=event, GITHUB_REF=ref)
                        identity = run_host_checks.run_identity(trigger, ci=True)
                        self.assertEqual((identity["event"], identity["ref"], identity[field]),
                                         (event, ref, "a" * 40))
                        with self.assertRaises(ci_summary.ContractError):
                            run_host_checks.run_identity(dict(trigger, GITHUB_SHA="0" * 40), ci=True)

    def test_python_failures_skips_subtests_and_empty_suites_never_report_success(self):
        class Sample(unittest.TestCase):
            def test_pass(self):
                self.assertTrue(True)

            def test_fail(self):
                self.fail("plain failure " + "x" * 240 + "\nsecond line must not be exported")

            def test_skip(self):
                self.skipTest("missing fixture")

            def test_subtest_skip(self):
                for fixture in ("A", "B"):
                    with self.subTest(fixture=fixture):
                        self.skipTest(f"missing fixture {fixture}")

            def test_mixed_subtests(self):
                with self.subTest(fixture="A"):
                    self.skipTest("fixture A unavailable")
                with self.subTest(fixture="B"):
                    self.fail("fixture B failed")

            @unittest.expectedFailure
            def test_unexpected_success(self):
                self.assertTrue(True)

        payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Sample), io.StringIO())
        self.assertEqual(code, 1)
        outcomes = {entry["identity"]["key"].rsplit(".", 1)[-1]: entry for entry in payload["observed"]}
        self.assertEqual(outcomes["test_fail"]["outcome"], "failed")
        message = outcomes["test_fail"]["attempts"][0]["message"]
        self.assertIn("AssertionError: plain failure", message)
        self.assertNotIn("second line", message)
        self.assertLessEqual(len(message.split("AssertionError: ", 1)[1]), 200)
        self.assertEqual(outcomes["test_pass"]["outcome"], "passed")
        self.assertEqual(outcomes["test_skip"]["attempts"][0]["reason"], "missing fixture")
        self.assertEqual(outcomes["test_unexpected_success"]["outcome"], "failed")
        self.assertEqual(outcomes["test_subtest_skip"]["outcome"], "skipped")
        reason = outcomes["test_subtest_skip"]["attempts"][0]["reason"]
        summary = valid_summary()
        summary["population"]["observed"] = [outcomes["test_subtest_skip"]]
        summary["status"] = "unverified"
        markdown = ci_summary.render_markdown(ci_summary.parse_summary(summary))
        for fixture in ("A", "B"):
            self.assertIn(f"missing fixture {fixture}", reason)
            self.assertIn(f"fixture='{fixture}'", reason)
            self.assertIn(f"missing fixture {fixture}", markdown)
        mixed = outcomes["test_mixed_subtests"]
        self.assertEqual(mixed["outcome"], "failed")
        summary["population"]["observed"] = [mixed]
        summary["status"] = "failed"
        markdown = ci_summary.render_markdown(ci_summary.parse_summary(summary))
        for detail in ("fixture A unavailable", "fixture='B'", "AssertionError", "fixture B failed"):
            self.assertIn(detail, markdown)
        self.assertEqual(len(payload["compiled"]), 6)
        empty, code = run_python_tests.run_suite(unittest.TestSuite(), io.StringIO())
        self.assertEqual(code, 1)
        self.assertEqual(empty["observed"], [])

    def test_expected_failures_return_failure_with_their_actual_reason(self):
        class Sample(unittest.TestCase):
            @unittest.expectedFailure
            def test_expected_failure(self):
                self.fail("known failure")

        payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Sample), io.StringIO())
        self.assertEqual(code, 1)
        entry = payload["observed"][0]
        self.assertEqual(entry["outcome"], "failed")
        self.assertIn("expected failure", entry["attempts"][0]["message"])
        self.assertIn("known failure", entry["attempts"][0]["message"])

    def test_python_class_setup_error_names_failure_and_accounts_for_missing_tests(self):
        for stage in ("setup", "teardown", "cleanups"):
            with self.subTest(stage=stage):
                class Sample(unittest.TestCase):
                    @classmethod
                    def setUpClass(cls):
                        def cleanup():
                            raise ValueError("class cleanup broken")
                        cls.addClassCleanup(cleanup)
                        if stage == "setup":
                            raise RuntimeError("fixture unavailable")
                        if stage == "cleanups":
                            def other_cleanup():
                                raise RuntimeError("fixture unavailable")
                            cls.addClassCleanup(other_cleanup)

                    @classmethod
                    def tearDownClass(cls):
                        if stage == "teardown":
                            raise RuntimeError("fixture unavailable")

                    def test_member(self):
                        self.assertTrue(True)

                payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Sample), io.StringIO())
                self.assertEqual(code, 1)
                self.assertEqual([entry["outcome"] for entry in payload["observed"]],
                                 ["failed", "not-run"] if stage == "setup" else ["passed", "failed"])
                failure = next(entry for entry in payload["observed"] if entry["outcome"] == "failed")
                self.assertIn("setUpClass" if stage == "setup" else "tearDownClass", failure["identity"]["key"])
                summary = valid_summary()
                summary["status"] = "failed"
                summary["population"].update(compiled=payload["compiled"], observed=payload["observed"])
                markdown = ci_summary.render_markdown(ci_summary.parse_summary(summary))
                for message in ("RuntimeError: fixture unavailable", "ValueError: class cleanup broken"):
                    self.assertIn(message, failure["attempts"][0]["message"])
                    self.assertIn(message, markdown)

    def test_python_fixture_skip_records_every_discovered_member_with_its_reason(self):
        class Sample(unittest.TestCase):
            def test_never_started(self):
                self.fail("must not run")

            def test_also_never_started(self):
                self.fail("must not run")

        def skip_fixture(*args):
            raise unittest.SkipTest("external calibration screenshots unavailable")

        class OtherSample(Sample):
            pass

        module = types.ModuleType("fixture_skip_regression")
        for scope in ("class", "module"):
            with self.subTest(scope=scope), patch.dict(sys.modules, {module.__name__: module}), \
                    patch.object(Sample, "__module__", module.__name__), \
                    patch.object(OtherSample, "__module__", module.__name__), \
                    patch.object(Sample, "setUpClass", classmethod(skip_fixture) if scope == "class" else classmethod(lambda cls: None)), \
                    patch.object(module, "setUpModule", skip_fixture if scope == "module" else lambda: None, create=True):
                suite = unittest.defaultTestLoader.loadTestsFromTestCase(Sample)
                if scope == "module":
                    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(OtherSample))
                payload, code = run_python_tests.run_suite(suite, io.StringIO())
                self.assertEqual(code, 0)
                self.assertEqual([entry["identity"] for entry in payload["observed"]], payload["compiled"])
                self.assertEqual([entry["outcome"] for entry in payload["observed"]],
                                 ["skipped"] * (2 if scope == "class" else 4))
                for entry in payload["observed"]:
                    self.assertEqual(entry["attempts"][0]["reason"], "external calibration screenshots unavailable")

        class SetupCleanupSample(unittest.TestCase):
            @classmethod
            def setUpClass(cls):
                cls.addClassCleanup(skip_fixture)
                raise unittest.SkipTest("setup fixture unavailable")

            def test_never_started(self):
                self.fail("must not run")

        payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(SetupCleanupSample), io.StringIO())
        self.assertEqual(code, 0)
        self.assertEqual([entry["identity"] for entry in payload["observed"]], payload["compiled"])
        reason = payload["observed"][0]["attempts"][0]["reason"]
        self.assertIn("setup fixture unavailable", reason)
        self.assertIn("external calibration screenshots unavailable", reason)

        class CleanupSample(unittest.TestCase):
            def test_pass(self):
                self.assertTrue(True)

        for fixture in ("tearDownClass", "tearDownModule"):
            with self.subTest(fixture=fixture), patch.dict(sys.modules, {module.__name__: module}), \
                    patch.object(CleanupSample, "__module__", module.__name__), \
                    patch.object(CleanupSample, "tearDownClass", classmethod(skip_fixture) if fixture == "tearDownClass" else classmethod(lambda cls: None)), \
                    patch.object(module, "tearDownModule", skip_fixture if fixture == "tearDownModule" else lambda: None, create=True):
                payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(CleanupSample), io.StringIO())
                self.assertEqual(code, 0)
                self.assertEqual([entry["outcome"] for entry in payload["observed"]], ["passed", "skipped"])
                cleanup = payload["observed"][-1]
                self.assertTrue(cleanup["identity"]["key"].startswith(fixture + " ("))
                self.assertEqual(cleanup["attempts"][0]["reason"], "external calibration screenshots unavailable")
                summary = valid_summary()
                summary["status"] = "unverified"
                summary["population"].update(compiled=payload["compiled"], observed=payload["observed"])
                self.assertIn("external calibration screenshots unavailable",
                              ci_summary.render_markdown(ci_summary.parse_summary(summary)))

    def test_invalid_final_record_is_rewritten_failed_with_executed_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            identity = ci_summary.test_identity("python", "fixture.Sample.test_failure")
            failure = ci_summary.observation(identity, "failed", 0, message="assertion broken", exit_code=None)

            def steps(*args, **kwargs):
                (output / "python-results.json").write_text(json.dumps({"compiled": [identity], "observed": [failure, failure]}))
                return [ci_summary.observation(ci_summary.test_identity("host", name), "failed" if name == "python tests" else "passed", 0)
                        for name, _ in run_host_checks.HOST_CHECKS], []

            with patch("sys.argv", ["run_host_checks.py", "--output-dir", str(output)]), \
                    patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                    patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                    patch.object(run_host_checks, "run_steps", side_effect=steps), \
                    contextlib.redirect_stdout(io.StringIO()) as terminal, contextlib.redirect_stderr(io.StringIO()):
                code = run_host_checks.main()
            self.assertEqual(code, 1)
            summary = ci_summary.parse_summary((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertIn("record-invalid", [item["code"] for item in summary["infrastructure"]])
            self.assertEqual(len(summary["population"]["observed"]), len(run_host_checks.HOST_CHECKS) + 1)
            for name, _ in run_host_checks.HOST_CHECKS:
                self.assertIn(name, terminal.getvalue())
            self.assertIn(identity["key"], terminal.getvalue())

    def test_host_coverage_failures_are_distinct_from_infrastructure(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            identity = ci_summary.test_identity("python", "calibration.Sample.test_photo")

            def steps(*args, **kwargs):
                (output / "python-results.json").write_text(json.dumps({"compiled": [identity], "observed": [
                    ci_summary.observation(identity, "skipped", 0, reason="external screenshots unavailable", exit_code=None)]}))
                return [ci_summary.observation(ci_summary.test_identity("host", name), "passed", 0)
                        for name, _ in run_host_checks.HOST_CHECKS], []

            with patch("sys.argv", ["run_host_checks.py", "--output-dir", str(output)]), \
                    patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]) as identity_call, \
                    patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                    patch("ci_population.python_identities", return_value=[identity]), \
                    patch.object(run_host_checks, "run_steps", side_effect=steps), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = run_host_checks.main()
            self.assertEqual(code, 1)
            identity_call.assert_called_once_with(os.environ, ci=False)
            summary = ci_summary.parse_summary((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertEqual(summary["population"]["observed"][-1]["attempts"][0]["reason"], "external screenshots unavailable")
            self.assertEqual({item["code"] for item in summary["infrastructure"]}, {"coverage-failed"})
            self.assertTrue(all(identity["key"] in item["message"] for item in summary["infrastructure"]))
            markdown = ci_summary.render_markdown(summary)
            self.assertIn("Coverage: coverage-failed: skipped: " + identity["key"], markdown)
            self.assertNotIn("Infrastructure:", markdown)

    def test_host_policy_distinguishes_proposed_and_approved_expected_skips(self):
        identity = ci_summary.test_identity("python", "calibration.Sample.test_photo")
        parse_policy = ci_verdict.parse_policy
        for state, outcome in (("proposed", "unverified"), ("approved", "passed")):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"
                record = {"approver": "maintainer example", "date": "2026-10-08", "tier": "host",
                          "link": "https://github.com/example/project/issues/1#issuecomment-1"}
                policy = {"schema_version": 1, "approval_records": [record] if state == "approved" else [], "deselections": [],
                          "expected_skips": [{"kind": "python", "key_pattern": identity["key"], "dimensions": {},
                                              "tier": "host", "environment": "hermetic", "reason": "no fixture"}]}

                def steps(*args, **kwargs):
                    (output / "python-results.json").write_text(json.dumps({"compiled": [identity], "observed": [
                        ci_summary.observation(identity, "skipped", 0, reason="no fixture")]}))
                    return [ci_summary.observation(ci_summary.test_identity("host", name), "passed", 0)
                            for name, _ in run_host_checks.HOST_CHECKS], []

                with patch("sys.argv", ["run_host_checks.py", "--output-dir", str(output)]), \
                        patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                        patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                        patch("ci_population.python_identities", return_value=[identity]), \
                        patch("ci_verdict.parse_policy", side_effect=lambda raw: policy if isinstance(raw, str) else parse_policy(raw)), \
                        patch.object(run_host_checks, "run_steps", side_effect=steps), \
                        contextlib.redirect_stdout(io.StringIO()):
                    code = run_host_checks.main()
                self.assertEqual(code, 0)
                summary = ci_summary.parse_summary((output / "summary.json").read_text())
                self.assertEqual(summary["status"], outcome)
                self.assertEqual(summary["population"]["declared"][-1], identity)
                self.assertIn("test-policy", summary["hashes"]["policies"])

    def test_invalid_population_or_policy_still_writes_placeholder_and_runs_all_checks(self):
        for invalid in ("python_identities", "parse_policy"):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"

                def steps(commands, *args, **kwargs):
                    placeholder = ci_summary.parse_summary((output / "summary.json").read_text())
                    self.assertEqual(placeholder["status"], "unverified")
                    self.assertEqual(placeholder["population"]["observed"], [])
                    self.assertEqual([name for name, _ in commands], [name for name, _ in run_host_checks.HOST_CHECKS])
                    (output / "python-results.json").write_text(json.dumps({"compiled": [], "observed": []}))
                    return [ci_summary.observation(ci_summary.test_identity("host", name), "passed", 0)
                            for name, _ in commands], []

                with patch("sys.argv", ["run_host_checks.py", "--output-dir", str(output)]), \
                        patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                        patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                        patch(("ci_population." if invalid == "python_identities" else "ci_verdict.") + invalid,
                              side_effect=ci_summary.ContractError("unsupported test base")), \
                        patch.object(run_host_checks, "run_steps", side_effect=steps) as run, \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    code = run_host_checks.main()
                self.assertEqual(code, 1)
                run.assert_called_once()
                summary = ci_summary.parse_summary((output / "summary.json").read_text())
                self.assertEqual(summary["status"], "failed")
                self.assertEqual(len(summary["population"]["observed"]), len(run_host_checks.HOST_CHECKS))
                self.assertIn("population-invalid", [item["code"] for item in summary["infrastructure"]])

    def test_host_environment_excludes_external_screenshot_calibration(self):
        with patch.dict(os.environ, {"STRICT_E2E_REVIEWED_SCREENSHOTS": "/external/reviewed", "PATH": "/bin"}, clear=True):
            self.assertNotIn("STRICT_E2E_REVIEWED_SCREENSHOTS", run_host_checks.clean_environment())
            self.assertEqual(run_host_checks.clean_environment()["PATH"], "/bin")

    def test_host_failures_and_timeouts_name_the_step_and_continue(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            steps = [("format", ["/bin/sh", "-c", "exit 3"]),
                     ("slow", ["/bin/sleep", "30"]), ("last", ["/usr/bin/true"])]
            with contextlib.redirect_stdout(io.StringIO()):
                records, infrastructure = run_host_checks.run_steps(steps, root, timeout_seconds=3)
            self.assertEqual([entry["outcome"] for entry in records], ["failed", "timed-out", "not-run"])
            self.assertIn("format", records[0]["attempts"][0]["message"])
            self.assertEqual(records[0]["attempts"][0]["exit_code"], 3)
            self.assertEqual(infrastructure[0]["code"], "step-timeout")
            with patch.object(run_host_checks.subprocess, "Popen") as spawn, \
                    patch.object(run_host_checks, "stop_group"), contextlib.redirect_stdout(io.StringIO()):
                spawn.return_value.wait.side_effect = KeyboardInterrupt
                records, infrastructure = run_host_checks.run_steps(steps, root, timeout_seconds=3)
            self.assertEqual(spawn.call_count, 1)
            self.assertEqual(infrastructure[0]["code"], "interrupted")
            for entry in records[1:]:
                self.assertEqual(entry["outcome"], "not-run")
                self.assertIn("not run after interruption", entry["attempts"][0]["message"])

    def test_timeout_kills_a_surviving_child_after_the_parent_exits(self):
        code = """import os, signal, time
if os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print('child ready', flush=True)
while True:
    time.sleep(30)
"""
        process = subprocess.Popen([sys.executable, "-c", code], start_new_session=True,
                                   stdout=subprocess.PIPE, text=True)
        try:
            self.assertTrue(select.select([process.stdout], [], [], 10)[0], "child did not become ready")
            self.assertEqual(process.stdout.readline().strip(), "child ready")
            with patch.object(run_host_checks, "GROUP_TERM_GRACE_SECONDS", 0.1, create=True):
                run_host_checks.stop_group(process)
            # EOF requires every process holding this pipe to exit, including the child.
            process.communicate(timeout=5)

            self.assertEqual(process.returncode, -signal.SIGTERM)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                # macOS can leave only an adopted zombie in the group after pipe EOF.
                pass
            process.communicate(timeout=5)

    def test_process_group_liveness_ignores_zombies_but_keeps_live_children(self):
        for states, alive in (("42 Z\n99 S\n", False), ("42 Z\n42 S\n", True), ("99 S\n", False)):
            with self.subTest(states=states), patch.object(run_host_checks.subprocess, "check_output", return_value=states):
                self.assertEqual(run_host_checks.group_has_live_members(42), alive)

    def test_macos_group_probe_avoids_a_slow_full_system_query_without_widening_the_deadline(self):
        def probe(command, **kwargs):
            self.assertEqual(kwargs["timeout"], 5)
            if "-axo" in command:
                raise subprocess.TimeoutExpired(command, 5)
            self.assertEqual(command, ["ps", "-g", "42", "-o", "pgid=,stat="])
            return "42 Z\n42 S\n"

        with patch.object(run_host_checks.sys, "platform", "darwin"), \
                patch.object(run_host_checks.subprocess, "check_output", side_effect=probe):
            self.assertTrue(run_host_checks.group_has_live_members(42))

    def test_macos_absent_group_is_stopped_but_probe_errors_are_not_hidden(self):
        command = ["ps", "-g", "42", "-o", "pgid=,stat="]
        missing = subprocess.CalledProcessError(1, command, output="", stderr="")
        with patch.object(run_host_checks.sys, "platform", "darwin"), \
                patch.object(run_host_checks.subprocess, "check_output", side_effect=missing):
            self.assertFalse(run_host_checks.group_has_live_members(42))
        errors = [subprocess.CalledProcessError(1, command, output="42 S\n", stderr=""),
                  subprocess.CalledProcessError(1, command, output="", stderr="permission denied"),
                  subprocess.CalledProcessError(2, command, output="", stderr=""),
                  subprocess.TimeoutExpired(command, 5)]
        for error in errors:
            with self.subTest(error=error), patch.object(run_host_checks.sys, "platform", "darwin"), \
                    patch.object(run_host_checks.subprocess, "check_output", side_effect=error):
                with self.assertRaises(type(error)):
                    run_host_checks.group_has_live_members(42)

    def test_non_macos_probe_keeps_full_query_and_propagates_empty_exit_one(self):
        with patch.object(run_host_checks.sys, "platform", "linux"), \
                patch.object(run_host_checks.subprocess, "check_output", return_value="42 S\n") as probe:
            self.assertTrue(run_host_checks.group_has_live_members(42))
            self.assertEqual(probe.call_args.args[0], ["ps", "-axo", "pgid=,stat="])
            self.assertEqual(probe.call_args.kwargs["timeout"], 5)
        with patch.object(run_host_checks.sys, "platform", "linux"), \
                patch.object(run_host_checks.subprocess, "check_output", side_effect=
                             subprocess.CalledProcessError(1, ["ps"], output="", stderr="")):
            with self.assertRaises(subprocess.CalledProcessError):
                run_host_checks.group_has_live_members(42)


if __name__ == "__main__":
    unittest.main()
