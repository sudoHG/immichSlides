"""Guard coverage and admission decisions against accidental green verdicts."""

import copy
import unittest
from unittest.mock import patch

import ci_summary
from ci_verdict import (classify_changes, evaluate_gate, evaluate_population, parse_policy, select_policy)
from test_ci_summary import valid_summary


def policy():
    return {"schema_version": 1, "approval_state": "approved", "expected_skips": [], "deselections": []}


class PopulationVerdictTests(unittest.TestCase):
    def setUp(self):
        self.summary = valid_summary()
        self.expected = self.summary["population"]["declared"]
        self.policy = policy()

    def verdict(self):
        return evaluate_population(self.summary, self.expected, self.policy, environment="hermetic")

    def test_declared_compiled_and_executed_must_account_for_every_identity(self):
        self.assertEqual(self.verdict()["status"], "passed")
        for collection in ("declared", "compiled", "observed"):
            with self.subTest(collection=collection):
                original = self.summary["population"][collection]
                self.summary["population"][collection] = []
                self.assertEqual(self.verdict()["status"], "failed")
                self.summary["population"][collection] = original

    def test_expected_skip_requires_exact_reason_tier_environment_and_no_execution(self):
        identity = self.expected[0]
        self.policy["expected_skips"] = [{"kind": "host", "key_pattern": "format", "dimensions": {},
                                          "tier": "host", "environment": "hermetic", "reason": "no fixture"}]
        self.summary["status"] = "unverified"
        self.summary["population"]["observed"] = [ci_summary.observation(identity, "skipped", 0, reason="no fixture")]
        self.assertEqual(self.verdict()["status"], "passed")
        self.assertEqual(self.verdict()["expected_skips"], [identity])
        for field, value in (("reason", "different"), ("tier", "nightly"), ("environment", "live")):
            with self.subTest(field=field):
                original = self.policy["expected_skips"][0][field]
                self.policy["expected_skips"][0][field] = value
                self.assertEqual(self.verdict()["status"], "failed")
                self.policy["expected_skips"][0][field] = original
        self.summary["population"]["observed"] = [ci_summary.observation(identity, "passed", 0)]
        self.assertEqual(self.verdict()["status"], "failed")

    def test_deselections_require_compilation_reason_owner_and_exclusive_accounting(self):
        entry = {"identity": self.expected[0], "tier": "host", "environment": "hermetic",
                 "reason": "live only", "owning_tier": "nightly-live"}
        self.policy["deselections"] = [entry]
        self.summary["population"]["observed"] = []
        self.summary["population"]["deselected"] = [{k: v for k, v in entry.items() if k not in {"tier", "environment"}}]
        self.assertEqual(self.verdict()["status"], "passed")
        for field in ("reason", "owning_tier"):
            with self.subTest(field=field):
                self.summary["population"]["deselected"][0][field] = "wrong"
                self.assertEqual(self.verdict()["status"], "failed")
                self.summary["population"]["deselected"][0][field] = entry[field]
        self.summary["population"]["compiled"] = []
        self.assertEqual(self.verdict()["status"], "failed")
        self.summary["population"]["compiled"] = self.expected
        self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], "passed", 0)]
        self.assertEqual(self.verdict()["status"], "failed")

    def test_parameter_rows_do_not_hide_missing_compiled_parameters(self):
        function = ci_summary.test_identity("swift", "Tests/works", platform="ios")
        parameters = [ci_summary.test_identity("swift", "Tests/works", platform="ios", parameter=p) for p in ("a", "b")]
        self.expected = [function]
        self.summary["population"]["declared"] = [function]
        self.summary["population"]["compiled"] = parameters
        self.summary["population"]["observed"] = [ci_summary.observation(p, "passed", 0) for p in parameters]
        self.assertEqual(self.verdict()["status"], "passed")
        self.summary["population"]["observed"].pop()
        self.assertEqual(self.verdict()["status"], "failed")

    def test_failures_infrastructure_partial_results_and_unregistered_retries_stay_red(self):
        for outcome in ("failed", "crashed", "timed-out", "not-run", "needs-human-review", "skipped"):
            with self.subTest(outcome=outcome):
                self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], outcome, 0, reason="unexpected")]
                self.assertEqual(self.verdict()["status"], "failed")
        self.summary = valid_summary()
        self.summary["status"] = "unverified"
        self.assertEqual(self.verdict()["status"], "failed")
        self.summary["status"] = "passed"
        self.summary["infrastructure"] = [{"code": "cancelled", "message": "job cancelled"}]
        self.assertEqual(self.verdict()["status"], "failed")
        self.summary = valid_summary()
        entry = self.summary["population"]["observed"][0]
        entry["outcome"] = "flaky-passed"
        entry["duration_seconds"] = 0.2
        entry["attempts"][0].update(outcome="failed", exit_code=1)
        entry["attempts"].append(dict(entry["attempts"][0], number=2, outcome="passed", exit_code=0))
        self.assertEqual(self.verdict()["status"], "failed")

    def test_proposed_or_ambiguous_policy_cannot_authorize_an_exception(self):
        self.policy["approval_state"] = "proposed"
        self.assertEqual(self.verdict()["status"], "passed")
        self.policy["expected_skips"] = [{"kind": "host", "key_pattern": "format", "dimensions": {},
                                          "tier": "host", "environment": "hermetic", "reason": "missing"}]
        self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], "skipped", 0, reason="missing")]
        self.assertEqual(self.verdict()["status"], "failed")
        self.policy = policy()
        rule = {"kind": "host", "key_pattern": "*", "dimensions": {}, "tier": "host",
                "environment": "hermetic", "reason": "missing"}
        self.policy["expected_skips"] = [rule, dict(rule, key_pattern="format")]
        self.assertEqual(self.verdict()["status"], "failed")

    def test_malformed_policy_versions_duplicate_rules_and_owner_are_rejected(self):
        for version in (2, True, "1", None):
            with self.subTest(version=version), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(policy(), schema_version=version))
        rule = {"kind": "host", "key_pattern": "format", "dimensions": {}, "tier": "host",
                "environment": "hermetic", "reason": "no fixture"}
        for entries in ([rule, rule], [dict(rule, reason="")], [dict(rule, dimensions={"unknown": "x"})]):
            with self.subTest(entries=entries), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(policy(), expected_skips=entries))
        with self.assertRaises(ci_summary.ContractError):
            parse_policy(dict(policy(), deselections=[{"identity": self.expected[0], "tier": "host",
                         "environment": "hermetic", "reason": "elsewhere", "owning_tier": "host"}]))


class AdmissionVerdictTests(unittest.TestCase):
    def setUp(self):
        self.summary = valid_summary()
        self.identity = self.summary["identity"]
        self.jobs = [{"tier": "host", "job": "host-checks", "shard": None, "run_id": None,
                      "attempt": 1, "workflow_paths": [None], "expected": self.summary["population"]["declared"]}]
        self.expected = self.summary["population"]["declared"]

    def verdict(self, **kwargs):
        trusted = {"fork_originated": False, "ci_changing": False, "app_affected": True}
        trusted.update(kwargs)
        return evaluate_gate([self.summary], expected=self.expected, admission_identity=self.identity,
                             required_jobs=self.jobs, base_policy=policy(), environment="hermetic", **trusted)

    def test_unclassified_inputs_cannot_default_to_a_non_ci_changing_green(self):
        for key in ("fork_originated", "ci_changing", "app_affected"):
            with self.subTest(key=key):
                self.assertEqual(self.verdict(**{key: None})["status"], "failed")

    def test_absent_artifacts_jobs_or_mismatched_run_identity_fail_closed(self):
        self.assertEqual(self.verdict()["status"], "passed")
        missing = evaluate_gate([], expected=self.expected, admission_identity=self.identity,
                                required_jobs=self.jobs, base_policy=policy(), environment="hermetic",
                                fork_originated=False, ci_changing=False, app_affected=True)
        self.assertEqual(missing["status"], "failed")
        self.assertTrue(any("missing required job/artifact" in error for error in missing["errors"]))
        for mutate in (lambda s: s["run"].update(attempt=2),
                       lambda s: s["identity"].update(tree_sha="c" * 40),
                       lambda s: s["source"].update(workflow_path=".github/workflows/renamed.yml")):
            with self.subTest(mutate=mutate):
                self.summary = valid_summary()
                mutate(self.summary)
                self.assertEqual(self.verdict()["status"], "failed")

    def test_exact_head_approval_controls_fork_and_candidate_policy(self):
        pr = {"schema_version": 1, "event": "pull_request", "repository": "sudoHG/immichSlides",
              "tree_sha": "b" * 40, "merge_sha": "a" * 40,
              "base_sha": "c" * 40, "head_sha": "d" * 40, "pull_request": 1}
        for approved in (None, "e" * 40, "d" * 40):
            with self.subTest(approved=approved):
                base = policy()
                candidate = dict(policy(), expected_skips=[])
                chosen = select_policy(base, candidate, pr, approved)
                self.assertEqual(chosen[1], approved == pr["head_sha"])
        self.assertEqual(self.verdict(fork_originated=True)["status"], "failed")
        self.assertEqual(self.verdict(ci_changing=True)["status"], "failed")
        self.identity = pr
        self.summary["identity"] = pr
        self.summary["source"].update(event="pull_request", fork_originated=True,
                                      workflow_path=".github/workflows/ci-gate.yml")
        self.summary["run"]["id"] = "42"
        self.jobs[0].update(run_id="42", workflow_paths=[".github/workflows/ci-gate.yml"])
        self.assertEqual(self.verdict(fork_originated=True)["status"], "failed")
        self.assertEqual(self.verdict(fork_originated=True, approved_head="e" * 40)["status"], "failed")
        verdict = self.verdict(fork_originated=True, approved_head=pr["head_sha"])
        self.assertEqual(verdict["status"], "passed")
        self.assertTrue(verdict["approval_based"])
        self.assertTrue(verdict["self_reported"])
        self.summary["source"]["fork_originated"] = False
        self.assertEqual(self.verdict(ci_changing=True)["status"], "failed")
        self.assertEqual(self.verdict(ci_changing=True, approved_head=pr["head_sha"])["status"], "passed")

    def test_candidate_exception_applies_only_after_exact_head_approval(self):
        pr = {"schema_version": 1, "event": "pull_request", "repository": "sudoHG/immichSlides",
              "tree_sha": "b" * 40, "merge_sha": "a" * 40, "base_sha": "c" * 40,
              "head_sha": "d" * 40, "pull_request": 1}
        self.identity = pr
        self.summary["identity"] = pr
        self.summary["source"].update(event="pull_request", workflow_path=".github/workflows/ci-gate.yml")
        self.summary["run"]["id"] = "42"
        self.jobs[0].update(run_id="42", workflow_paths=[".github/workflows/ci-gate.yml"])
        candidate = policy()
        candidate["expected_skips"] = [{"kind": "host", "key_pattern": "format", "dimensions": {},
                                        "tier": "host", "environment": "hermetic", "reason": "fixture unavailable"}]
        self.summary["status"] = "unverified"
        self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], "skipped", 0, reason="fixture unavailable")]
        for head, status in ((None, "failed"), ("e" * 40, "failed"), (pr["head_sha"], "passed")):
            with self.subTest(head=head):
                self.assertEqual(self.verdict(candidate_policy=candidate, approved_head=head)["status"], status)

    def test_another_shard_cannot_cover_a_tests_absence_from_its_assigned_job(self):
        extra = ci_summary.test_identity("host", "second")
        self.expected = self.expected + [extra]
        first = self.summary
        second = copy.deepcopy(first)
        second["run"]["shard"] = "second"
        second["population"]["declared"].append(extra)
        second["population"]["compiled"].append(extra)
        second["population"]["observed"].append(ci_summary.observation(extra, "passed", 0))
        self.jobs[0]["expected"] = self.expected
        self.jobs.append(dict(self.jobs[0], shard="second"))
        verdict = evaluate_gate([first, second], expected=self.expected, admission_identity=self.identity,
                                required_jobs=self.jobs, base_policy=policy(), environment="hermetic",
                                fork_originated=False, ci_changing=False, app_affected=True)
        self.assertEqual(verdict["status"], "failed")
        self.assertTrue(any("missing compiled" in error for error in verdict["errors"]))

    def test_later_main_population_never_enters_the_verdict(self):
        before = self.verdict(base_population=self.expected)
        later_main = self.expected + [ci_summary.test_identity("host", "new-on-main")]
        after = self.verdict(base_population=later_main)
        self.assertEqual(after["status"], before["status"])
        self.assertEqual(after["status"], "passed")

    def test_push_requires_pushed_identity_and_manual_dispatch_is_not_gate_evidence(self):
        pushed = {"schema_version": 1, "event": "push", "repository": "sudoHG/immichSlides",
                  "tree_sha": "b" * 40, "pushed_sha": "a" * 40, "ref": "refs/heads/main"}
        self.identity = pushed
        self.summary["identity"] = pushed
        self.summary["source"].update(event="push", workflow_path=".github/workflows/ci-gate.yml")
        self.summary["run"]["id"] = "42"
        self.jobs[0].update(run_id="42", workflow_paths=[".github/workflows/ci-gate.yml"])
        self.assertEqual(self.verdict(ci_changing=True, allowed_events=("pull_request", "push"))["status"], "passed")
        dispatched = dict(pushed, event="workflow_dispatch", commit_sha=pushed["pushed_sha"])
        del dispatched["pushed_sha"]
        self.identity = dispatched
        self.summary["identity"] = dispatched
        self.summary["source"]["event"] = "workflow_dispatch"
        self.assertEqual(self.verdict(allowed_events=("pull_request", "push"))["status"], "failed")

    def test_reader_first_accepts_installed_successor_and_rejects_malformed_versions(self):
        for version in (2, 99, True, "1", None):
            with self.subTest(version=version):
                self.summary["schema_version"] = version
                self.assertEqual(self.verdict()["status"], "failed")
        def successor(payload):
            normalized = copy.deepcopy(payload)
            normalized["schema_version"] = 1
            ci_summary.validate_summary_v1(normalized)
        self.summary["schema_version"] = 2
        with patch.dict(ci_summary.SUMMARY_READERS, {2: successor}):
            self.assertEqual(self.verdict()["status"], "passed")
            self.summary["run"]["attempt"] = 0
            self.assertEqual(self.verdict()["status"], "failed")

    def test_identity_successor_requires_installed_validator_before_acceptance(self):
        self.identity = dict(self.identity, schema_version=2)
        self.summary["identity"] = self.identity
        self.assertEqual(self.verdict()["status"], "failed")

        def successor(payload):
            normalized = copy.deepcopy(payload)
            normalized["schema_version"] = 1
            ci_summary.validate_identity_v1(normalized)

        with patch.dict(ci_summary.IDENTITY_READERS, {2: successor}):
            self.assertEqual(self.verdict()["status"], "passed")
            self.identity["tree_sha"] = "invalid"
            self.assertEqual(self.verdict()["status"], "failed")

    def test_only_verified_allowlisted_nonmembers_make_ui_not_applicable(self):
        allowlist = {"schema_version": 1, "app_unaffected": ["docs/**", "README.md"],
                     "ci_trusted": ["scripts/**", ".github/**"]}
        for paths, members, app, ci in ((["docs/README.md"], set(), False, False),
                                       (["docs/bundled.md"], {"docs/bundled.md"}, True, False),
                                       (["immichSlides/Resources/privacy.html"], set(), True, False),
                                       (["scripts/ci-policy.json"], set(), True, True),
                                       (["unknown.file"], set(), True, False)):
            with self.subTest(paths=paths):
                classification = classify_changes(paths, allowlist, build_target_paths=members)
                self.assertEqual((classification["app_affected"], classification["ci_changing"]), (app, ci))
        self.assertEqual(self.verdict(context="ui", app_affected=False)["status"], "not-applicable")
        for path in ("../README.md", "/README.md", "docs/../scripts/x.py"):
            with self.subTest(path=path), self.assertRaises(ci_summary.ContractError):
                classify_changes([path], allowlist, build_target_paths=set())


if __name__ == "__main__":
    unittest.main()
