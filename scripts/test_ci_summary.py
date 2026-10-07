"""Guard the producer/reader contract and honest host-check failure reporting."""

import copy
import contextlib
import io
import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ci_summary
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


class SummaryContractTests(unittest.TestCase):
    def test_current_summary_round_trips_and_names_failures_in_markdown(self):
        summary = valid_summary()
        self.assertEqual(ci_summary.parse_summary(json.dumps(summary)), summary)
        summary["population"]["observed"][0] = ci_summary.observation(
            summary["population"]["declared"][0], "failed", 0.2, message="format exited 1", exit_code=1)
        summary["status"] = "failed"
        self.assertIn("format exited 1", ci_summary.render_markdown(ci_summary.parse_summary(summary)))

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

    def test_pr_and_push_identity_schemas_fail_closed(self):
        pr = {"schema_version": 1, "event": "pull_request", "repository": "sudoHG/immichSlides",
              "pull_request": 86, "merge_sha": "a" * 40, "base_sha": "b" * 40,
              "head_sha": "c" * 40, "tree_sha": "d" * 40}
        push = {"schema_version": 1, "event": "push", "repository": "sudoHG/immichSlides",
                "ref": "refs/heads/main", "pushed_sha": "a" * 40, "tree_sha": "b" * 40}
        for identity in (pr, push):
            self.assertEqual(ci_summary.parse_identity(json.dumps(identity)), identity)
            for key in identity:
                broken = dict(identity)
                del broken[key]
                with self.subTest(event=identity["event"], key=key), self.assertRaises(ci_summary.ContractError):
                    ci_summary.parse_identity(broken)
        push["ref"] = "refs/heads/other"
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_identity(push)


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
                    identity = run_host_checks.run_identity({})
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
                       ("show", "-s", "--format=%P", "a" * 40): "b" * 40 + " " + "c" * 40}
            env = {"GITHUB_REPOSITORY": "sudoHG/immichSlides", "GITHUB_EVENT_NAME": "pull_request",
                   "GITHUB_SHA": "a" * 40, "GITHUB_EVENT_PATH": str(event_path)}
            with patch.object(run_host_checks, "git", side_effect=lambda *args: answers[args]):
                identity = run_host_checks.run_identity(env)
                self.assertEqual((identity["base_sha"], identity["head_sha"]), ("b" * 40, "c" * 40))
                env["GITHUB_SHA"] = "0" * 40
                with self.assertRaises(ci_summary.ContractError):
                    run_host_checks.run_identity(env)
                env["GITHUB_SHA"] = "a" * 40
                answers[("show", "-s", "--format=%P", "a" * 40)] = "b" * 40
                with self.assertRaises(ci_summary.ContractError):
                    run_host_checks.run_identity(env)

    def test_python_failures_skips_subtests_and_empty_suites_never_report_success(self):
        class Sample(unittest.TestCase):
            def test_pass(self):
                self.assertTrue(True)

            def test_fail(self):
                with self.subTest(case="broken"):
                    self.assertEqual(1, 2)

            def test_skip(self):
                self.skipTest("missing fixture")

            def test_subtest_skip(self):
                for fixture in ("A", "B"):
                    with self.subTest(fixture=fixture):
                        self.skipTest(f"missing fixture {fixture}")

            @unittest.expectedFailure
            def test_unexpected_success(self):
                self.assertTrue(True)

        payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Sample), io.StringIO())
        self.assertEqual(code, 1)
        outcomes = {entry["identity"]["key"].rsplit(".", 1)[-1]: entry for entry in payload["observed"]}
        self.assertEqual(outcomes["test_fail"]["outcome"], "failed")
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
        self.assertEqual(len(payload["compiled"]), 5)
        empty, code = run_python_tests.run_suite(unittest.TestSuite(), io.StringIO())
        self.assertEqual(code, 1)
        self.assertEqual(empty["observed"], [])

    def test_expected_failures_return_failure_with_their_actual_reason(self):
        class Sample(unittest.TestCase):
            @unittest.expectedFailure
            def test_expected_failure(self):
                self.fail("known failure")

            @unittest.expectedFailure
            def test_unexpected_success(self):
                self.assertTrue(True)

        for name, message in (("test_expected_failure", "expected failure"),
                              ("test_unexpected_success", "unexpected success")):
            with self.subTest(name=name):
                payload, code = run_python_tests.run_suite(unittest.TestSuite([Sample(name)]), io.StringIO())
                self.assertEqual(code, 1)
                entry = payload["observed"][0]
                self.assertEqual(entry["outcome"], "failed")
                self.assertIn(message, entry["attempts"][0]["message"])

    def test_python_class_setup_error_names_failure_and_accounts_for_missing_tests(self):
        class Sample(unittest.TestCase):
            @classmethod
            def setUpClass(cls):
                raise RuntimeError("fixture unavailable")

            def test_never_started(self):
                self.fail("must not run")

        payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Sample), io.StringIO())
        self.assertEqual(code, 1)
        self.assertEqual([entry["outcome"] for entry in payload["observed"]], ["failed", "not-run"])
        self.assertIn("setUpClass", payload["observed"][0]["identity"]["key"])

    def test_python_class_skip_keeps_legacy_cli_verdict_and_records_unverified_members(self):
        class Sample(unittest.TestCase):
            @classmethod
            def setUpClass(cls):
                raise unittest.SkipTest("external calibration screenshots unavailable")

            def test_never_started(self):
                self.fail("must not run")

        payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Sample), io.StringIO())
        self.assertEqual(code, 0)
        self.assertEqual([entry["outcome"] for entry in payload["observed"]], ["skipped", "not-run"])
        self.assertEqual(payload["observed"][0]["attempts"][0]["reason"], "external calibration screenshots unavailable")

    def test_host_class_skip_preserves_cli_success_and_never_labels_summary_passed(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            identity = ci_summary.test_identity("python", "calibration.Sample.test_photo")

            def steps(*args, **kwargs):
                (output / "python-results.json").write_text(json.dumps({"compiled": [identity], "observed": [
                    ci_summary.observation(identity, "skipped", 0, reason="external screenshots unavailable", exit_code=None)]}))
                return [ci_summary.observation(ci_summary.test_identity("host", name), "passed", 0)
                        for name, _ in run_host_checks.HOST_CHECKS], []

            with patch("sys.argv", ["run_host_checks.py", "--output-dir", str(output)]), \
                    patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                    patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                    patch.object(run_host_checks, "run_steps", side_effect=steps), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = run_host_checks.main()
            self.assertEqual(code, 0)
            summary = ci_summary.parse_summary((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "unverified")
            self.assertEqual(summary["population"]["observed"][-1]["attempts"][0]["reason"], "external screenshots unavailable")

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
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
