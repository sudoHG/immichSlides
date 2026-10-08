"""Reporter decisions guard duplicate notifications, premature closure and lost provenance."""

import copy
import json
import tempfile
import unittest
from datetime import date, datetime, timezone
from pathlib import Path
from unittest.mock import patch

import ci_report
from ci_summary import ContractError, observation, test_identity
from ci_report import (daily_rollup, identity_token, issue_decision, registry_checks,
                       render_entry, summary_diagnostics, synchronize_issues, read_state,
                       read_run, check_context, NIGHTLY_INFRASTRUCTURE)
from test_ci_summary import valid_summary


IDENTITY = {"kind": "strict", "key": "ExampleUITests/testPlayback",
            "dimensions": {"device": "iphone", "configuration": "Debug", "suite": "smoke",
                           "scenario": "normal", "fixture": "a"}}


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
                self.issues = {135: {"number": 135, "body": "Existing maintainer diagnosis.", "state": "open",
                                     "labels": [{"name": "known-flaky"}]}}
                self.created = 0
            def pages(self, path, **filters):
                return list(self.issues.values())
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {"name": "ci-reported-failure"}
                if path == "issues":
                    self.created += 1
                    return {"number": 136, **payload}
                number = int(path.rsplit("/", 1)[-1])
                if method == "PATCH":
                    updated = copy.deepcopy(payload)
                    if "labels" in updated:
                        updated["labels"] = [{"name": name} for name in updated["labels"]]
                    self.issues[number].update(updated)
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
        for day, run in (("2026-10-03", 12), ("2026-10-04", 13), ("2026-10-05", 14)):
            synchronize_issues(api, [entry(day, "passed", run)], registry)
        self.assertEqual("open", api.issues[135]["state"])
        receipts, _ = synchronize_issues(api, [entry("2026-10-06", "passed", 15)], {"entries": []})
        self.assertEqual(["close"], [receipt["action"] for receipt in receipts])
        self.assertEqual(135, receipts[0]["issue"])
        self.assertEqual(0, api.created)
        self.assertEqual({"known-flaky", "ci-reported-failure"}, {label["name"] for label in api.issues[135]["labels"]})

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
        identity = {"schema_version": 1, "repository": api.repository, "event": "push",
                    "ref": "refs/heads/main", "pushed_sha": run["head_sha"], "tree_sha": "b" * 40}
        record = {"workflow_id": run["workflow_id"], "workflow_path": run["path"], "identity": identity,
                  "classification": {"ci_changing": True}, "workflows": {run["path"]: {"base": "trusted workflow"}}}
        summary = valid_summary()
        summary["identity"] = identity
        summary["source"].update(event="push", workflow_path=run["path"])
        summary["run"]["id"] = str(run["id"])
        with patch("ci_report.on_main", return_value=True), patch("ci_publish.producer_evidence", return_value=([], [summary])), \
                patch("ci_publish_git.evaluate_records", return_value={"state": "success"}):
            verified = read_run(api, {**run, "conclusion": "success"}, {run["id"]: record})
        self.assertEqual("passed", verified["status"])
        self.assertEqual([], verified["diagnostics"]["infrastructure"])

    def test_immediate_issue_replay_survives_label_index_delay(self):
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.issues, self.created = {}, 0
            def pages(self, path, **filters):
                # GitHub's label-filtered list can lag a successful create.
                return [] if "labels" in filters else list(self.issues.values())
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {"name": "ci-reported-failure"}
                if path == "issues":
                    self.created += 1
                    issue = {"number": self.created, "body": payload["body"], "state": "open",
                             "labels": [{"name": name} for name in payload["labels"]]}
                    self.issues[self.created] = issue
                    return issue
                number = int(path.rsplit("/", 1)[-1])
                if method == "PATCH":
                    self.issues[number].update(payload)
                return self.issues[number]
        api = API()
        synchronize_issues(api, [entry()], {"entries": []})
        self.assertEqual([], synchronize_issues(api, [entry()], {"entries": []})[0])
        self.assertEqual(1, api.created)

    def test_parameterized_swift_observations_cover_the_declared_function(self):
        summary = valid_summary()
        declared = test_identity("swift", "ExampleTests/loads photo", platform="ios")
        compiled = test_identity("swift", "immichSlidesTests/ExampleTests/`loads photo`(input:)", platform="ios")
        parameter = copy.deepcopy(compiled)
        parameter["dimensions"]["parameter"] = "input=1"
        summary["population"].update(declared=[declared], compiled=[compiled],
                                     observed=[observation(parameter, "passed", 1)])
        self.assertEqual([], summary_diagnostics([summary])["missing"])

    def test_reporter_credential_context_refuses_branch_events_and_other_workflows(self):
        environment = {"GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": "sudoHG/immichSlides",
                       "GITHUB_WORKFLOW_REF": "sudoHG/immichSlides/.github/workflows/ci-report.yml@refs/heads/main",
                       "GITHUB_EVENT_NAME": "workflow_run"}
        check_context(environment)
        for key, value in (("GITHUB_REF", "refs/heads/feature"), ("GITHUB_EVENT_NAME", "pull_request"),
                           ("GITHUB_WORKFLOW_REF", "sudoHG/immichSlides/.github/workflows/ci-gate.yml@refs/heads/main")):
            with self.subTest(key=key), self.assertRaises(ContractError):
                check_context({**environment, key: value})

    def test_real_nightly_suite_records_require_verified_method_results_for_registry_reuse(self):
        from ci_nightly import aggregate_nightly
        method = test_identity("strict", "StrictE2EFilterIOSUITests/testFilterPersonNormalMatch",
                               **{**IDENTITY["dimensions"], "suite": "filter-person"})
        case = test_identity("strict", "filter-person", **method["dimensions"])
        shard = valid_summary()
        shard["population"].update(declared=[case], compiled=[case],
                                   observed=[observation(case, "failed", 1, exit_code=65)])
        aggregate = aggregate_nightly([case], [shard], live_in_scope=False)
        trace = {"warm": [{"identity": case, "official_methods": [
            {"identifier": method["key"], "result": "Failed"}],
            "build_operations": 0, "products_unchanged": True, "log_present": True, "exit_code": 65,
            "official_summary": {"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0}}]}
        observed, missing = ci_report.method_observations(shard, trace)
        self.assertEqual(method, observed[0]["identity"])
        self.assertEqual("failed", observed[0]["outcome"])
        self.assertEqual(identity_token(method), identity_token(observed[0]["identity"]))
        self.assertNotEqual(identity_token(aggregate["observed"][0]["identity"]), identity_token(method))
        self.assertTrue(missing)  # The other filter-person invocations were not observed.
        from run_strict_e2e import FILTER_PERSON_SESSIONS
        trace["warm"][0]["official_methods"] += [{"identifier": item["selector"].split("/", 1)[1], "result": "Passed"}
                                               for item in FILTER_PERSON_SESSIONS[1:]]
        trace["warm"][0]["official_summary"].update(totalTestCount=3, passedTests=2)
        methods, missing = ci_report.method_observations(shard, trace)
        self.assertEqual([], missing)
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.issue = {"number": 133, "state": "open", "body": "Existing person-filter diagnosis.", "labels": []}
            def pages(self, *args, **kwargs):
                return []
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {}
                self.assert_path(path, method)
                if method == "PATCH":
                    self.issue.update(payload)
                return self.issue
            def assert_path(self, path, method):
                if path != "issues/133" or method not in {"GET", "PATCH"}:
                    raise AssertionError("method failure must reuse registry issue 133")
        api = API()
        report = entry()
        report["observed"] = methods
        receipts, _ = synchronize_issues(api, [report], {"entries": [{"identity": method,
            "issue": "https://github.com/sudoHG/immichSlides/issues/133"}]})
        self.assertEqual([133], [receipt["issue"] for receipt in receipts])
        self.assertEqual(identity_token(method), receipts[0]["token"])
        trace["warm"][0]["official_methods"][0]["result"] = "Passed"
        trace["warm"][0]["official_summary"].update(failedTests=0, passedTests=3)
        outcomes = ci_report.method_observations(shard, trace)[0]
        self.assertEqual([case], [item["identity"] for item in outcomes if item["outcome"] == "failed"])
        self.assertEqual("strict-case-contract-failed", outcomes[-1]["attempts"][0]["reason"])
        trace["warm"][0].pop("official_methods")
        self.assertEqual([case], [item["identity"] for item in ci_report.method_observations(shard, trace)[0]])

    def test_newer_attempt_without_observation_revokes_a_saved_pass_and_keeps_first_failure(self):
        state = self.transition(None, entry())["state"]
        state = self.transition(state, entry("2026-10-02", "passed", 11))["state"]
        rerun = entry("2026-10-02", "passed", 11, 2)
        rerun["observed"] = []
        state = self.transition(state, rerun)["state"]
        self.assertEqual("unverified", state["nights"]["2026-10-02"]["11"]["outcome"])
        self.assertEqual([], state["explicit_pass_nights"])
        fresh = entry(attempt=2, outcome="passed")
        fresh["attempt_history"] = [entry(), fresh.copy()]
        self.assertEqual("open", self.transition(None, fresh)["action"])
        self.assertEqual("failed", self.transition(None, fresh)["state"]["nights"]["2026-10-01"]["10"]["outcome"])
        run = {"id": 10, "workflow_id": 123, "run_attempt": 2, "created_at": "2026-10-01T10:00:00Z", "head_sha": "a" * 40,
               "path": ci_report.NIGHTLY_PATH, "event": "schedule", "head_branch": "main",
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "status": "completed", "conclusion": "success"}
        api = type("API", (), {"repository": "sudoHG/immichSlides", "pages": lambda *args: []})()
        with patch("ci_report.on_main", return_value=True), patch("ci_report.nightly_attempt",
                side_effect=[entry(), entry(attempt=2, outcome="passed")]) as reader:
            observed = read_run(api, run, {})
        self.assertEqual([1, 2], [call.args[2] for call in reader.call_args_list])
        self.assertEqual("failed", self.transition(None, observed)["state"]["nights"]["2026-10-01"]["10"]["outcome"])
        compact = ci_report.compact_entry(observed, set())
        self.assertEqual([IDENTITY], [item["identity"] for item in compact["observed"]])
        with patch("ci_report.ensure_label"), patch("ci_report.visible_issues", return_value=[]), \
                patch("ci_report.sync_identity", return_value=None) as sync:
            synchronize_issues(api, [compact], {"entries": []})
        self.assertIn(IDENTITY, [call.args[2] for call in sync.call_args_list])

    def test_three_p2_contract_pass_nights_close_without_granting_release_authority(self):
        identity = copy.deepcopy(IDENTITY)
        identity["dimensions"]["suite"] = "p2-rotation"
        def report(day, outcome, run):
            value = entry(day, outcome, run)
            value["observed"][0]["identity"] = identity
            return value
        state = issue_decision(None, identity, [report("2026-10-01", "failed", 10)], registry_referenced=False)["state"]
        for day, run in (("2026-10-02", 11), ("2026-10-03", 12), ("2026-10-04", 13)):
            value = report(day, "needs-human-review", run)
            decision = issue_decision(state, identity, [value], registry_referenced=False)
            state = decision["state"]
            self.assertFalse(value["release_eligible"])
        self.assertEqual("close", decision["action"])

    def test_manual_closure_survives_passes_and_replay_and_history_starts_at_last_failure(self):
        state = self.transition(None, entry())["state"]
        closed = copy.deepcopy(state)
        closed["closed"] = True
        self.assertEqual("none", self.transition(closed, entry())["action"])
        self.assertEqual("none", self.transition(closed, entry("2026-10-02", "passed", 11))["action"])
        state = self.transition(state, entry("2026-10-03", run=12))["state"]
        self.assertEqual(["2026-10-03"], sorted(state["nights"]))
        self.assertEqual(2, state["failure_nights"])
        self.assertEqual("2026-10-01", state["first_failure"])

    def test_expired_evidence_does_not_rebuild_or_downgrade_the_verified_snapshot(self):
        saved = entry("2026-09-01", "passed")
        expired = copy.deepcopy(saved)
        expired.update(status="failed", evidence_expired=True)
        snapshot = {"schema_version": 2, "days": {saved["day"]: daily_rollup(saved["day"], [saved])}, "issue_index": {}}
        result = ci_report.merge_snapshot(snapshot, [expired], date(2026, 10, 1))
        self.assertEqual([saved], result["days"][saved["day"]]["entries"])
        self.assertEqual([], ci_report.decision_entries([expired], date(2026, 10, 1)))

    def test_compact_rollups_keep_failures_and_tracked_passes_without_full_populations(self):
        value = entry(outcome="passed")
        other = test_identity("strict", "OtherUITests/testOther", **IDENTITY["dimensions"])
        value["observed"].append(observation(other, "passed", 1))
        compact = ci_report.compact_entry(value, {identity_token(IDENTITY)})
        self.assertEqual([value["observed"][0]], compact["observed"])
        self.assertNotIn("population", compact)

    def test_workflow_completions_read_only_the_trigger_and_prior_snapshot(self):
        run = {"id": 10, "path": ci_report.NIGHTLY_PATH, "head_branch": "main",
               "event": "schedule", "head_repository": {"full_name": "sudoHG/immichSlides"},
               "repository": {"full_name": "sudoHG/immichSlides"}}
        api = type("API", (), {"repository": "sudoHG/immichSlides", "repo": lambda self, path: run,
                               "pages": lambda *args, **kwargs: self.fail("completion must not enumerate producer days")})()
        self.assertEqual([run], ci_report.discover_runs(api, "workflow_run", {"workflow_run": {"id": 10}}, date(2026, 10, 1)))
        for changes in ({"head_repository": {"full_name": "contributor/immichSlides"}},
                        {"event": "pull_request"}, {"path": ci_report.PRODUCER_PATHS[0], "event": "pull_request"},
                        {"head_branch": "feature"}):
            with self.subTest(changes=changes), patch.object(api, "repo", return_value={**run, **changes}):
                self.assertEqual([], ci_report.discover_runs(api, "workflow_run", {"workflow_run": {"id": 10}}, date(2026, 10, 1)))
        for changes in ({"fork_originated": True}, {"event": "pull_request"}):
            report = entry()
            report["source"].update(changes)
            with self.subTest(changes=changes), patch("ci_report.ensure_label", side_effect=AssertionError("no writes")):
                self.assertEqual(([], {}), synchronize_issues(api, [report], {"entries": []}))

    def test_dry_run_refuses_writes_and_low_api_budget_stops_before_another_request(self):
        api = ci_report.ReportGitHub("sudoHG/immichSlides", "", dry_run=True)
        with self.assertRaises(ContractError):
            api.repo("issues", method="POST", payload={"title": "must not write"})
        self.assertEqual(0, api.request_count)
        api.check_headers({"X-RateLimit-Remaining": "500", "X-RateLimit-Limit": "1000"})
        with patch("ci_publish.GitHub.request", side_effect=AssertionError("no request allowed")), \
                self.assertRaises(ci_report.RateLimitLow):
            api.repo("actions/runs/10")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with self.assertRaises(ci_report.RateLimitLow):
                ci_report.collect_report(api, "schedule", {}, date(2026, 10, 1), output)
            self.assertEqual([], list(output.iterdir()))
        self.assertEqual(0, api.request_count)
        self.assertLessEqual(ci_report.REQUEST_BUDGET, 150)
        api.check_headers({"X-RateLimit-Remaining": "900", "X-RateLimit-Limit": "1000"})
        api.request_count = 150
        with patch("ci_publish.GitHub.request", side_effect=AssertionError("run budget exhausted")), self.assertRaises(ci_report.RateLimitLow):
            api.repo("actions/runs/10")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "runs").mkdir()
            value = entry(day=datetime.now(timezone.utc).date().isoformat())
            (output / "sync.json").write_text(json.dumps({"schema_version": 2, "entries": [value], "registry": {"entries": []},
                "budget_stopped": False, "api_budget": {"requests": 150, "remaining": 900, "limit": 1000}}))
            with patch("ci_report.check_context"), patch("ci_report.ReportGitHub", return_value=api), \
                    patch.dict("os.environ", {"CI_REPORT_TOKEN": "synthetic-test-token", "GITHUB_REPOSITORY": api.repository}), \
                    patch("ci_publish.GitHub.request", side_effect=AssertionError("sync cannot reset the run budget")):
                self.assertEqual(0, ci_report.main(["--phase", "sync", "--output-dir", str(output)]))
            self.assertEqual(150, json.loads((output / "runs/issue-actions.json").read_text())["requests"])

    def test_unread_history_fails_without_outputs_but_loaded_history_survives_budget_stop(self):
        saved = ci_report.merge_snapshot(None, [entry()], date(2026, 10, 1))
        api = type("API", (), {"repository": "sudoHG/immichSlides", "request_count": 2, "remaining": 501,
                               "request": lambda *args: None, "budget_exhausted": lambda *args: False})()
        for previous, expected in ((None, "fail"), (saved, "preserve")):
            with tempfile.TemporaryDirectory() as temporary, patch("ci_flaky.parse_registry", return_value={"entries": []}), \
                    patch("ci_report.read_snapshot", side_effect=ci_report.RateLimitLow() if previous is None else None,
                          return_value=previous), patch("ci_report.visible_issues", side_effect=ci_report.RateLimitLow()):
                output = Path(temporary)
                if expected == "fail":
                    with self.assertRaises(ci_report.RateLimitLow):
                        ci_report.collect_report(api, "schedule", {}, date(2026, 10, 1), output)
                    self.assertFalse((output / "daily/history.json").exists())
                else:
                    ci_report.collect_report(api, "schedule", {}, date(2026, 10, 1), output)
                    snapshot = json.loads((output / "daily/history.json").read_text())
                    self.assertEqual(saved["days"], snapshot["days"])
                    self.assertTrue(snapshot["budget_stopped"])

    def test_history_search_paginates_and_missing_snapshots_require_explicit_maintainer_reset(self):
        run = {"id": 10, "workflow_id": 20, "path": ci_report.REPORT_PATH, "head_branch": "main",
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "repository": {"full_name": "sudoHG/immichSlides"},
               "event": "schedule", "head_sha": "a" * 40, "run_attempt": 1}
        saved = ci_report.merge_snapshot(None, [entry()], date(2026, 10, 1))
        saved["producer"] = {"repository": "sudoHG/immichSlides", "workflow_path": ci_report.REPORT_PATH,
                             "run": {"id": "10", "attempt": 1}, "commit_sha": "a" * 40}
        class API:
            repository = "sudoHG/immichSlides"
            def repo(self, path, **options):
                if path == "actions/workflows/ci-report.yml":
                    return {"id": 20, "path": ci_report.REPORT_PATH}
                if "&page=1" in path:
                    return {"workflow_runs": [{**run, "id": value} for value in range(110, 10, -1)]}
                return {"workflow_runs": [run]}
            def pages(self, path, *args, **options):
                return [{"name": "ci-report-daily-10-1", "expired": False}] if path == "actions/runs/10/artifacts" else []
        with patch("ci_report.on_main", return_value=True), patch("ci_publish.json_member", return_value=saved):
            self.assertEqual(saved, ci_report.read_snapshot(API()))
        with patch("ci_report.on_main", return_value=True), patch.object(API, "pages", return_value=[]), self.assertRaises(ContractError):
            ci_report.read_snapshot(API())
        api = type("EmptyAPI", (), {"repository": "sudoHG/immichSlides", "request_count": 1, "remaining": 900,
                                   "request": lambda *args: None, "budget_exhausted": lambda *args: False})()
        for event, actor, allowed in (("schedule", "sudoHG", False), ("workflow_dispatch", "other", False),
                                      ("workflow_dispatch", "sudoHG", True)):
            with self.subTest(event=event, actor=actor), tempfile.TemporaryDirectory() as temporary, \
                    patch("ci_flaky.parse_registry", return_value={"entries": []}), patch("ci_report.read_snapshot", return_value=None), \
                    patch("ci_report.visible_issues", return_value=[]), patch("ci_report.discover_runs", return_value=[]), \
                    patch.dict("os.environ", {"GITHUB_ACTOR": actor, "GITHUB_TRIGGERING_ACTOR": actor}, clear=False):
                output = Path(temporary)
                if allowed:
                    ci_report.collect_report(api, event, {"inputs": {"reset_history": True}}, date(2026, 10, 1), output)
                    self.assertEqual("sudoHG", json.loads((output / "daily/history.json").read_text())["history_reset"]["actor"])
                else:
                    with self.assertRaises(ContractError):
                        ci_report.collect_report(api, event, {"inputs": {"reset_history": True}}, date(2026, 10, 1), output)

    def test_diagnostic_nightly_is_retained_but_never_writes_or_recovers_an_issue(self):
        report = entry()
        report["diagnostic_shard"] = "ios-iphone-0"
        compact = ci_report.compact_entry(report, set())
        self.assertEqual("ios-iphone-0", compact["diagnostic_shard"])
        self.assertEqual([], ci_report.decision_entries([compact], date(2026, 10, 1)))
        with patch("ci_report.ensure_label", side_effect=AssertionError("no diagnostic writes")):
            self.assertEqual(([], {}), synchronize_issues(object(), [compact], {"entries": []}))
        self.assertEqual("none", self.transition(None, compact)["action"])
        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z", "head_sha": "a" * 40,
               "path": ci_report.NIGHTLY_PATH, "event": "workflow_dispatch", "head_branch": "main",
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "status": "completed", "conclusion": "failure"}
        api = type("API", (), {"repository": "sudoHG/immichSlides", "pages": lambda *args: []})()
        with patch("ci_report.on_main", return_value=True):
            unavailable = read_run(api, run, {})
        self.assertEqual("unverified-dispatch-plan", unavailable["diagnostic_shard"])
        self.assertFalse(ci_report.issue_eligible(unavailable))
        plan = {"schema_version": 1, "identity": {"schema_version": 1, "repository": api.repository,
                "event": "workflow_dispatch", "ref": "refs/heads/main", "commit_sha": "a" * 40, "tree_sha": "b" * 40},
                "source": {"workflow_path": ci_report.NIGHTLY_PATH, "fork_originated": False},
                "run": {"id": "10", "attempt": 1}, "diagnostic_shard": "ios-iphone-0"}
        with patch("ci_report.on_main", return_value=True), patch.object(api, "pages", return_value=[{
                "name": "nightly-plan-10-1", "expired": False}]), patch("ci_publish.json_member", return_value=plan):
            failed_aggregate = read_run(api, run, {})
        self.assertEqual("ios-iphone-0", failed_aggregate["diagnostic_shard"])
        self.assertFalse(ci_report.issue_eligible(failed_aggregate))

    def test_rollup_is_written_before_issue_sync_and_sync_errors_preserve_other_identities(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            snapshot = ci_report.merge_snapshot(None, [entry()], date(2026, 10, 1))
            ci_report.write_report(output, snapshot, [entry()], {"entries": []}, {}, stopped=False, now=date(2026, 10, 1))
            self.assertTrue((output / "daily/history.json").is_file())
            self.assertTrue((output / "sync.json").is_file())
            ci_report.write_report(output, snapshot, [], {"entries": []}, {}, stopped=False, now=date(2026, 10, 1))
            self.assertEqual([entry()], json.loads((output / "sync.json").read_text())["entries"])
        errors = []
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.created = []
            def pages(self, *args, **kwargs):
                return []
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {}
                if method == "POST":
                    self.created.append(payload)
                    return {"number": len(self.created), "state": "open", "body": payload["body"],
                            "labels": [{"name": "ci-reported-failure"}]}
                return None
        api = API()
        second = entry(run=11)
        second["observed"][0]["identity"] = test_identity("strict", "OtherUITests/testOther", **IDENTITY["dimensions"])
        real_body = ci_report.issue_body
        def bounded_body(issue, state, repository):
            if state["identity"] == IDENTITY:
                raise ContractError("issue history exceeds GitHub limit")
            return real_body(issue, state, repository)
        with patch("ci_report.issue_body", side_effect=bounded_body), patch("ci_report.wait_for_issue_visibility"):
            receipts, _ = synchronize_issues(api, [entry(), second], {"entries": []}, errors=errors)
        self.assertEqual(1, len(errors))
        self.assertEqual(1, len(receipts))
        self.assertEqual(1, len(api.created))


if __name__ == "__main__":
    unittest.main()
