"""Reporter decisions guard duplicate notifications, premature closure and lost provenance."""

import copy
import unittest
from unittest.mock import patch

from ci_summary import ContractError, observation, test_identity
from ci_report import (daily_rollup, identity_token, issue_decision, registry_checks,
                       render_entry, summary_diagnostics, synchronize_issues, read_state,
                       read_run, check_context, NIGHTLY_INFRASTRUCTURE)
from test_ci_summary import valid_summary


IDENTITY = test_identity("strict", "ExampleUITests/testPlayback", device="iphone",
                         configuration="Debug", suite="smoke", scenario="normal", fixture="a")


def entry(day="2026-10-01", outcome="failed", run=10, attempt=1):
    return {"schema_version": 1, "day": day, "run": {"id": run, "attempt": attempt},
            "source": {"repository": "sudoHG/immichSlides", "workflow_path": ".github/workflows/ci-nightly.yml",
                       "event": "schedule", "fork_originated": False, "ci_changing": False,
                       "approval_based": False},
            "status": "failed" if outcome == "failed" else "passed", "release_eligible": False,
            "observed": [observation(IDENTITY, outcome, 1, exit_code=65 if outcome == "failed" else 0)],
            "diagnostics": {"counts": {}, "failures": [], "missing": [], "infrastructure": []}}


class ReporterTests(unittest.TestCase):
    def transition(self, state, report, referenced=False):
        return issue_decision(state, IDENTITY, [report], registry_referenced=referenced)

    def test_failures_open_update_and_reopen_one_identity_and_replays_do_not_count(self):
        first = self.transition(None, entry())
        self.assertEqual("open", first["action"])
        replay = self.transition(first["state"], entry())
        self.assertEqual("none", replay["action"])
        second = self.transition(first["state"], entry("2026-10-02", run=11))
        self.assertEqual("update", second["action"])
        self.assertEqual(2, second["state"]["failure_nights"])
        closed = copy.deepcopy(second["state"])
        closed["closed"] = True
        self.assertEqual("reopen", self.transition(closed, entry("2026-10-03", run=12))["action"])

    def test_only_three_distinct_later_explicit_pass_nights_can_close(self):
        state = self.transition(None, entry())["state"]
        for day, run in (("2026-10-02", 11), ("2026-10-02", 12), ("2026-10-03", 13)):
            decision = self.transition(state, entry(day, "passed", run))
            self.assertNotEqual("close", decision["action"])
            state = decision["state"]
        self.assertEqual("close", self.transition(state, entry("2026-10-04", "passed", 14))["action"])

    def test_flaky_skipped_missing_and_infrastructure_nights_cannot_close(self):
        for outcome in ("flaky-passed", "skipped", "not-run", "failed"):
            with self.subTest(outcome=outcome):
                state = self.transition(None, entry())["state"]
                for day, run in (("2026-10-02", 11), ("2026-10-03", 12)):
                    state = self.transition(state, entry(day, "passed", run))["state"]
                report = entry("2026-10-04", "passed", 13)
                report["observed"][0]["outcome"] = outcome
                self.assertNotEqual("close", self.transition(state, report)["action"])
        report = entry("2026-10-04", "passed", 13)
        report["diagnostics"]["infrastructure"] = ["missing-evidence"]
        self.assertNotEqual("close", self.transition(state, report)["action"])

    def test_registry_reference_blocks_closure_even_after_review_date(self):
        state = self.transition(None, entry())["state"]
        for day, run in (("2026-10-02", 11), ("2026-10-03", 12), ("2026-10-04", 13)):
            state = self.transition(state, entry(day, "passed", run), True)["state"]
        self.assertFalse(state["closed"])
        self.assertEqual("close", self.transition(state, entry("2026-10-05", "passed", 14))["action"])

    def test_older_failure_delivery_cannot_erase_later_failure_or_pass_history(self):
        state = self.transition(None, entry("2026-10-04", run=14))["state"]
        state = self.transition(state, entry("2026-10-01", run=10))["state"]
        self.assertEqual("2026-10-04", state["last_failure"])
        self.assertEqual("2026-10-01", state["first_failure"])
        for day, run in (("2026-10-05", 15), ("2026-10-06", 16)):
            state = self.transition(state, entry(day, "passed", run))["state"]
        self.assertEqual("close", self.transition(state, entry("2026-10-07", "passed", 17))["action"])

    def test_ui_devices_share_platform_registry_identity_but_strict_dimensions_remain_distinct(self):
        iphone = test_identity("ui", "ExampleUITests/testPlayback", platform="ios", device="iphone")
        ipad = test_identity("ui", "ExampleUITests/testPlayback", platform="ios", device="ipad")
        self.assertEqual(identity_token(iphone), identity_token(ipad))
        tv = copy.deepcopy(IDENTITY)
        tv["dimensions"]["device"] = "tv"
        self.assertNotEqual(identity_token(IDENTITY), identity_token(tv))

    def test_rollup_is_idempotent_selects_latest_attempt_and_preserves_source(self):
        old, new = entry(), entry(attempt=2, outcome="passed")
        new["source"].update(fork_originated=True, ci_changing=True, approval_based=True)
        report = daily_rollup("2026-10-01", [old, new, new])
        self.assertEqual([new], report["entries"])
        self.assertEqual(90, report["retention_days"])
        with self.assertRaises(ContractError):
            conflicting = copy.deepcopy(new)
            conflicting["status"] = "failed"
            daily_rollup("2026-10-01", [new, conflicting])

    def test_diagnostics_keep_failed_identities_counts_exit_codes_and_missing_evidence(self):
        summary = valid_summary()
        summary["population"]["observed"][0] = observation(summary["population"]["declared"][0], "failed", 1, exit_code=65)
        summary["status"] = "failed"
        summary["population"]["compiled"] = []
        diagnostics = summary_diagnostics([summary], ["required artifact missing"])
        self.assertEqual(1, diagnostics["counts"]["failed"])
        self.assertEqual([65], diagnostics["failures"][0]["exit_codes"])
        self.assertTrue(diagnostics["missing"])
        self.assertIn("required artifact missing", diagnostics["infrastructure"])
        report = entry()
        report["diagnostics"] = diagnostics
        rendered = render_entry(report)
        self.assertIn("65", rendered)
        self.assertIn("Infrastructure", rendered)

    def test_registry_checks_report_expiration_and_closed_or_missing_issues_without_gating_tests(self):
        registry = {"entries": [{"identity": IDENTITY, "issue": "https://github.com/sudoHG/immichSlides/issues/135",
                                  "review_by": "2026-10-01", "owner": "sudoHG"}]}
        checks = registry_checks(registry, "2026-10-02", {135: "closed"})
        self.assertTrue(checks[0]["expired"])
        self.assertEqual("closed", checks[0]["issue_state"])
        self.assertFalse(registry_checks(registry, "2026-10-01", {135: "open"})[0]["expired"])

    def test_missing_nightly_evidence_is_infrastructure_and_not_an_invented_test_result(self):
        report = entry()
        report["observed"] = []
        report["diagnostics"]["infrastructure"] = ["missing aggregate"]
        decision = issue_decision(None, NIGHTLY_INFRASTRUCTURE, [report], registry_referenced=False)
        self.assertEqual("open", decision["action"])
        self.assertEqual([], report["observed"])

    def test_github_lifecycle_reuses_registry_issue_preserves_body_and_reconciles_manual_closure(self):
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.issues = {135: {"number": 135, "body": "Existing maintainer diagnosis.", "state": "open"}}
                self.created = 0
            def pages(self, path, **filters):
                return []
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {"name": "ci-reported-failure"}
                if path == "issues":
                    self.created += 1
                    return {"number": 136, **payload}
                number = int(path.rsplit("/", 1)[-1])
                if method == "PATCH":
                    self.issues[number].update(payload)
                return self.issues[number]
        api = API()
        registry = {"entries": [{"identity": IDENTITY, "issue": "https://github.com/sudoHG/immichSlides/issues/135"}]}
        receipts, _ = synchronize_issues(api, [entry()], registry)
        self.assertEqual(135, receipts[0]["issue"])
        self.assertEqual(0, api.created)
        self.assertTrue(api.issues[135]["body"].startswith("Existing maintainer diagnosis."))
        receipts, _ = synchronize_issues(api, [entry()], registry)
        self.assertEqual([], receipts)
        api.issues[135]["state"] = "closed"
        receipts, _ = synchronize_issues(api, [entry("2026-10-02", run=11)], registry)
        self.assertEqual("reopen", receipts[0]["action"])
        self.assertFalse(read_state(api.issues[135])["closed"])

    def test_failed_main_push_without_admission_still_has_a_verified_notification_sha(self):
        run = {"id": 12, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z", "head_sha": "a" * 40,
               "path": ".github/workflows/ci-gate.yml", "event": "push", "head_branch": "main",
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "status": "completed", "conclusion": "failure"}
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        with patch("ci_report.on_main", return_value=True):
            report = read_run(api, run, {})
        self.assertEqual("a" * 40, report["pushed_sha"])
        self.assertTrue(report["diagnostics"]["infrastructure"])
        with patch("ci_report.on_main", return_value=False):
            self.assertNotIn("pushed_sha", read_run(api, run, {}))

    def test_reporter_credential_context_refuses_branch_fork_and_other_workflow(self):
        environment = {"GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": "sudoHG/immichSlides",
                       "GITHUB_WORKFLOW_REF": "sudoHG/immichSlides/.github/workflows/ci-report.yml@refs/heads/main",
                       "GITHUB_EVENT_NAME": "workflow_run"}
        check_context(environment)
        for key, value in (("GITHUB_REF", "refs/heads/feature"), ("GITHUB_EVENT_NAME", "pull_request"),
                           ("GITHUB_WORKFLOW_REF", "sudoHG/immichSlides/.github/workflows/ci-gate.yml@refs/heads/main")):
            with self.subTest(key=key), self.assertRaises(ContractError):
                check_context({**environment, key: value})


if __name__ == "__main__":
    unittest.main()
