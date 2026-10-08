"""Guard coverage and admission decisions against accidental green verdicts."""

import ast
import copy
import json
import re
import unittest
from pathlib import Path
from unittest.mock import patch

import ci_summary
from run_host_checks import HOST_CHECKS
from ci_verdict import (classify_changes, evaluate_gate, evaluate_population, parse_policy, select_policy)
from test_ci_summary import valid_summary


class NightlyVerdictTests(unittest.TestCase):
    def test_ipad_smoke_exclusions_follow_the_selected_tests_phone_guard(self):
        from ci_nightly import contract_population
        cases, exclusions = contract_population()
        self.assertEqual([case for case in cases if case["device"] == "ipad" and case["suite"] == "smoke"], [])
        device_exclusions = [entry for entry in exclusions if entry["case"]["device"] == "ipad"
                             and entry["case"]["suite"] == "smoke"]
        self.assertEqual({entry["case"]["fixture"] for entry in device_exclusions}, {"a", "b"})
        from ci_nightly import require_smoke_phone_guard
        source = (Path(__file__).parent.parent / "immichSlidesUITests/StrictE2ESmokeUITests.swift").read_text()
        require_smoke_phone_guard(source)
        for changed in (source.replace("== .phone", "== .pad"),
                        source.replace("guard UIDevice", "// guard UIDevice"),
                        source.replace("throw XCTSkip", "XCTFail")):
            with self.subTest(source=changed), self.assertRaises(ci_summary.ContractError):
                require_smoke_phone_guard(changed)

    def test_informational_outcomes_are_reported_without_hiding_execution_or_infrastructure_failure(self):
        from ci_nightly import aggregate_nightly
        identity = ci_summary.test_identity("strict", "filter-vision", device="iphone", configuration="Debug",
                                            suite="filter-vision", scenario="normal", fixture="a")
        for outcome, infrastructure, expected in (("failed", [], "passed"), ("not-run", [], "failed"),
                ("passed", [{"code": "interrupted", "message": "cancelled"}], "failed")):
            with self.subTest(outcome=outcome, infrastructure=infrastructure):
                summary = valid_summary()
                summary["population"].update(declared=[identity], compiled=[identity],
                    observed=[ci_summary.observation(identity, outcome, 1)])
                summary["infrastructure"] = infrastructure
                result = aggregate_nightly([identity], [summary], live_in_scope=False, informational=["filter-vision"])
                self.assertEqual(result["status"], expected)
                self.assertEqual(len(result["informational"]), 1)

    def test_matrix_requires_exact_execution_without_duplicates_or_unrun_placeholders(self):
        from ci_nightly import matrix_equality
        identity = ci_summary.test_identity("strict", "smoke", device="iphone", configuration="Debug",
                                            suite="smoke", scenario="normal", fixture="a")
        good = ci_summary.observation(identity, "passed", 1)
        for entries, expected in (([good], True), ([], False), ([good, good], False),
                                  ([ci_summary.observation(identity, "not-run", 0)], False),
                                  ([dict(good, identity=dict(identity, key="unexpected"))], False)):
            with self.subTest(entries=entries):
                self.assertEqual(matrix_equality([identity], entries)["equal"], expected)

    def test_nightly_rules_keep_unbuilt_tiers_green_and_skeletons_ineligible(self):
        from ci_nightly import aggregate_nightly
        identity = ci_summary.test_identity("strict", "smoke", device="iphone", configuration="Debug",
                                            suite="smoke", scenario="normal", fixture="a")
        summary = valid_summary()
        summary["population"] = dict(summary["population"], declared=[identity], compiled=[identity],
                                     observed=[ci_summary.observation(identity, "passed", 1)])
        summary["run"].update(tier="strict", job="nightly-strict", shard="iphone-debug-0")
        for outcome, infrastructure, live, expected in (
                ("passed", [], False, "passed"), ("flaky-passed", [], False, "passed"),
                ("needs-human-review", [], False, "failed"), ("failed", [], False, "failed"),
                ("skipped", [], False, "failed"), ("not-run", [], False, "failed"),
                ("passed", [{"code": "interrupted", "message": "cancelled"}], False, "failed"),
                ("passed", [], True, "failed")):
            with self.subTest(outcome=outcome, live=live, infrastructure=infrastructure):
                changed = copy.deepcopy(summary)
                entry = ci_summary.observation(identity, outcome, 1, reason="unexpected skip")
                if outcome == "flaky-passed":
                    entry["attempts"] = [dict(entry["attempts"][0], number=1, outcome="failed", duration_seconds=.5),
                                          dict(entry["attempts"][0], number=2, outcome="passed", duration_seconds=.5)]
                changed["population"]["observed"] = [entry]
                changed["infrastructure"] = infrastructure
                changed["status"] = "unverified" if outcome == "needs-human-review" else "passed"
                result = aggregate_nightly([identity], [changed], live_in_scope=live)
                self.assertEqual(result["status"], expected)
                self.assertFalse(result["release_eligible"])
                self.assertEqual(result["tiers"]["ui"], "not yet in scope")
        summary["status"] = "unverified"
        self.assertEqual(aggregate_nightly([identity], [summary], live_in_scope=False)["status"], "failed")

    def test_p2_contracts_allow_review_pending_but_never_a_failed_producer(self):
        from ci_nightly import aggregate_nightly
        identity = ci_summary.test_identity("strict", "p2-rotation", device="iphone", configuration="Debug",
                                            suite="p2-rotation", scenario="normal", fixture="a")
        summary = valid_summary()
        summary["population"].update(declared=[identity], compiled=[identity],
                                     observed=[ci_summary.observation(identity, "needs-human-review", 1)])
        summary["status"] = "unverified"
        self.assertEqual(aggregate_nightly([identity], [summary], live_in_scope=False)["status"], "passed")
        summary["status"] = "failed"
        self.assertEqual(aggregate_nightly([identity], [summary], live_in_scope=False)["status"], "failed")

    def test_aggregate_rejects_wrong_provenance_and_declared_population(self):
        from ci_nightly import validate_shard
        summary = valid_summary()
        expected = summary["population"]["declared"]
        summary["run"].update(tier="strict", job="nightly-strict", shard="s")
        summary["hashes"] = {"manifests": {"nightly-matrix": "a" * 64},
                              "policies": {"nightly": "b" * 64}}
        for path, value in (("identity.tree_sha", "c" * 40), ("run.attempt", 2),
                            ("run.shard", "other"), ("hashes.manifests.nightly-matrix", "c" * 64),
                            ("population.declared", [])):
            with self.subTest(path=path):
                changed = copy.deepcopy(summary)
                target = changed
                parts = path.split(".")
                for part in parts[:-1]:
                    target = target[part]
                target[parts[-1]] = value
                with self.assertRaises(ci_summary.ContractError):
                    validate_shard(changed, summary["identity"], summary["run"], summary["hashes"], expected)

    def test_missing_compilation_fails_only_that_case_and_preserves_completed_results(self):
        from ci_nightly import aggregate_nightly, validate_shard
        identities = [ci_summary.test_identity("strict", "smoke", device="iphone", configuration="Debug",
                      suite="smoke", scenario="normal", fixture=str(number)) for number in range(6)]
        for outcome, executed in (("failed", 6), ("passed", 6), ("not-run", 5)):
            with self.subTest(outcome=outcome):
                summary = valid_summary()
                summary["run"].update(tier="strict", job="nightly-strict", shard="partial")
                summary["status"] = "failed"
                summary["population"].update(declared=identities, compiled=identities[:5], observed=[
                    *[ci_summary.observation(identity, "passed", 1) for identity in identities[:5]],
                    ci_summary.observation(identities[5], outcome, 2 if executed == 6 else 0,
                        reason="original result", exit_code=124 if outcome == "failed" else None)])
                original = copy.deepcopy(summary)
                accepted = validate_shard(summary, summary["identity"], summary["run"], summary["hashes"], identities)
                result = aggregate_nightly(identities, [accepted], live_in_scope=False)
                self.assertEqual(result["status"], "failed")
                expected_outcome = "not-run" if outcome == "not-run" else "failed"
                self.assertEqual([entry["outcome"] for entry in result["observed"]], ["passed"] * 5 + [expected_outcome])
                self.assertEqual(result["observed"][:5], original["population"]["observed"][:5])
                failed = result["observed"][5]
                if outcome == "not-run":
                    self.assertEqual(failed, original["population"]["observed"][5])
                else:
                    self.assertIn("declared-not-compiled", failed["attempts"][-1]["reason"])
                self.assertEqual(failed["duration_seconds"], original["population"]["observed"][5]["duration_seconds"])
                self.assertEqual(failed["attempts"][-1]["exit_code"], original["population"]["observed"][5]["attempts"][-1]["exit_code"])
                ci_summary.validate_observation(failed)
                self.assertEqual(result["matrix"]["executed"], executed)
                self.assertEqual(result["matrix"]["equal"], executed == 6)
                self.assertEqual(summary, original)

    def test_manifest_rejects_unknown_missing_and_duplicate_cases(self):
        from ci_nightly import parse_manifest
        raw = json.loads((Path(__file__).parent / "nightly-matrix.json").read_text())
        parse_manifest(raw)
        for mutation in (lambda x: x["cases"].pop(), lambda x: x["cases"].append(x["cases"][0]),
                         lambda x: x["cases"][0].update(suite="unknown"),
                         lambda x: x.update(schema_version=99)):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(raw)
                mutation(changed)
                with self.assertRaises(ci_summary.ContractError):
                    parse_manifest(changed)


def policy():
    return {"schema_version": 1, "approval_records": [approval_record("host")], "expected_skips": [], "deselections": []}


def approval_record(tier):
    return {"approver": "maintainer example", "date": "2026-10-08", "tier": tier,
            "link": "https://github.com/example/project/issues/1#issuecomment-1"}


def expected_population(identities, tree_sha):
    return {"tree_sha": tree_sha, "identities": identities}


class PopulationVerdictTests(unittest.TestCase):
    def test_flaky_pass_requires_exact_trusted_registry_and_preserved_two_attempts(self):
        from datetime import date
        from test_ci_flaky import registry
        from ci_flaky import merge_retry
        base = registry()
        identity = base["entries"][0]["identity"]
        summary = valid_summary()
        summary["run"]["tier"] = "ui"
        summary["population"]["declared"] = summary["population"]["compiled"] = [identity]
        summary["population"]["observed"] = [merge_retry(ci_summary.observation(identity, "failed", 1,
                                                        reason="Official XCTest assertion failure", exit_code=65),
                                                        ci_summary.observation(identity, "passed", 2))]
        args = {"environment": "hermetic", "base_registry": base, "evaluated_on": date(2026, 10, 8)}
        self.assertEqual(evaluate_population(summary, [identity], policy(), **args)["status"], "passed")
        for override in ({"base_registry": None}, {"base_registry": dict(base, entries=[])},
                         {"evaluated_on": date(2026, 11, 8)}, {"evaluated_on": None}, {"environment": "live"}):
            with self.subTest(override=override):
                self.assertEqual(evaluate_population(summary, [identity], policy(), **(args | override))["status"], "failed")
        summary["run"]["tier"] = "host"
        self.assertEqual(evaluate_population(summary, [identity], policy(), **args)["status"], "failed")
        summary["run"]["tier"] = "ui"
        summary["population"]["observed"][0]["attempts"][0]["reason"] = "Unclassified failure"
        self.assertEqual(evaluate_population(summary, [identity], policy(), **args)["status"], "failed")

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
        for tier, environment, test in (("unit", "hermetic", ci_summary.test_identity("swift", "Tests/skipped()", platform="ios")),
                                        ("ui", "fixture", ci_summary.test_identity("ui", "Tests/testSkipped", platform="ios", device="iphone"))):
            self.summary["run"]["tier"] = tier
            self.expected = self.summary["population"]["declared"] = self.summary["population"]["compiled"] = [test]
            self.summary["population"]["observed"] = [ci_summary.observation(test, "skipped", 0, reason="no fixture")]
            self.policy["expected_skips"] = [{"kind": test["kind"], "key_pattern": test["key"], "dimensions": test["dimensions"],
                                              "tier": tier, "environment": environment, "reason": "no fixture"}]
            for records, status in (([approval_record("host"), approval_record(tier)], "passed"),
                                    ([approval_record("host")], "failed")):
                with self.subTest(tier=tier, approval_tiers=[record["tier"] for record in records]):
                    self.policy["approval_records"] = records
                    verdict = evaluate_population(self.summary, self.expected, self.policy, environment=environment)
                    self.assertEqual(verdict["status"], status)
                    self.assertEqual(verdict["expected_skips"], [test] if status == "passed" else [])

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
        # Xcode enumerates functions and exports their individual arguments separately.
        compiled = ci_summary.test_identity("swift", "immichSlidesTests/Tests/`works`(value:)", platform="ios")
        parameters = [dict(compiled, dimensions={"platform": "ios", "parameter": p}) for p in ("a", "b")]
        self.summary["population"]["compiled"] = [compiled]
        rows = [ci_summary.observation(p, "passed", 0) for p in [compiled, *parameters]]
        self.summary["population"]["observed"] = rows
        self.assertEqual(self.verdict()["status"], "passed")
        for case in ("failed argument", "duplicate argument", "unknown parent", "no function result"):
            with self.subTest(case=case):
                changed = copy.deepcopy(rows)
                if case == "failed argument":
                    changed[1] = ci_summary.observation(parameters[0], "failed", 0, message="Expectation failed")
                elif case == "duplicate argument":
                    changed.append(copy.deepcopy(changed[1]))
                elif case == "unknown parent":
                    changed[1]["identity"]["key"] = "immichSlidesTests/Other/`works`(value:)"
                else:
                    changed.pop(0)
                self.summary["population"]["observed"] = changed
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
        self.policy["approval_records"] = []
        self.assertEqual(self.verdict()["status"], "passed")
        self.policy["expected_skips"] = [{"kind": "host", "key_pattern": "format", "dimensions": {},
                                          "tier": "host", "environment": "hermetic", "reason": "missing"}]
        self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], "skipped", 0, reason="missing")]
        self.assertEqual(self.verdict()["status"], "failed")
        self.policy = policy()
        rule = {"kind": "host", "key_pattern": "*", "dimensions": {}, "tier": "host",
                "environment": "hermetic", "reason": "missing"}
        self.policy["proposed"] = {"expected_skips": [rule], "deselections": []}
        self.assertEqual(parse_policy(self.policy)["proposed"], self.policy["proposed"])
        self.assertEqual(self.verdict()["status"], "failed")
        self.assertEqual(self.verdict()["errors"], ["skipped: format"])
        self.policy["expected_skips"] = [rule, dict(rule, key_pattern="format")]
        self.assertEqual(self.verdict()["status"], "failed")

    def test_proposed_section_is_validated_but_never_authorizes_deselections(self):
        entry = {"identity": self.expected[0], "tier": "host", "environment": "hermetic",
                 "reason": "fixture mismatch", "owning_tier": "nightly-live"}
        self.policy["proposed"] = {"expected_skips": [], "deselections": [entry]}
        self.assertEqual(parse_policy(self.policy), self.policy)
        self.assertEqual(self.verdict()["status"], "passed")
        self.summary["population"]["observed"] = []
        self.summary["population"]["deselected"] = [
            {key: value for key, value in entry.items() if key not in {"tier", "environment"}}]
        self.assertEqual(self.verdict()["status"], "failed")
        for proposed in ({"deselections": []}, {"expected_skips": [], "deselections": [dict(entry, owning_tier="host")]},
                         {"expected_skips": [], "deselections": [entry, entry]},
                         {"expected_skips": [], "deselections": [], "approval_state": "approved"}):
            with self.subTest(proposed=proposed), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(self.policy, proposed=proposed))

    def test_malformed_policy_versions_duplicate_rules_and_owner_are_rejected(self):
        record = {"approver": "maintainer example", "date": "2026-10-08", "tier": "host",
                  "link": "https://github.com/example/project/issues/1#issuecomment-1"}
        recorded = dict(policy(), approval_records=[record])
        self.assertEqual(parse_policy(recorded), recorded)
        for field, value in (("approver", ""), ("date", "2026-02-30"), ("date", "20261008"),
                             ("tier", ""), ("link", "http://github.com/example/project/issues/1#issuecomment-1"),
                             ("link", "https://example.com/approval"), ("unknown", "value")):
            with self.subTest(approval_field=field, value=value), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(recorded, approval_records=[dict(record, **{field: value})]))
        for malformed in (None, [], {}, {key: value for key, value in record.items() if key != "tier"}):
            with self.subTest(approval_record=malformed), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(recorded, approval_records=[malformed]))
        for records in (None, {}, [record, record]):
            with self.subTest(approval_records=records), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(recorded, approval_records=records))
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
                      "attempt": 1, "workflow_paths": [None], "status": "completed", "conclusion": "success",
                      "expected": expected_population(self.summary["population"]["declared"], self.identity["tree_sha"])}]
        self.expected = self.summary["population"]["declared"]

    def verdict(self, **kwargs):
        trusted = {"fork_originated": False, "ci_changing": False, "app_affected": True,
                   "allowed_events": ("pull_request", "push", "local")}
        if self.identity["event"] == "pull_request":
            trusted["base_population"] = {"base_sha": self.identity["base_sha"], "identities": self.expected}
        trusted.update(kwargs)
        expected = trusted.pop("expected", expected_population(self.expected, self.identity["tree_sha"]))
        return evaluate_gate([self.summary], expected=expected, admission_identity=self.identity,
                             required_jobs=self.jobs, base_policy=policy(), environment="hermetic", **trusted)

    def test_default_admission_rejects_local_events_and_unclassified_inputs(self):
        default = evaluate_gate([self.summary], expected=expected_population(self.expected, self.identity["tree_sha"]), admission_identity=self.identity,
                                required_jobs=self.jobs, base_policy=policy(), environment="hermetic",
                                fork_originated=False, ci_changing=False, app_affected=True)
        self.assertEqual(default["status"], "failed")
        self.assertTrue(any("event is not admitted" in error for error in default["errors"]))
        self.assertEqual(self.verdict()["status"], "passed")
        for key in ("fork_originated", "ci_changing", "app_affected"):
            with self.subTest(key=key):
                self.assertEqual(self.verdict(**{key: None})["status"], "failed")

    def test_absent_artifacts_jobs_or_mismatched_run_identity_fail_closed(self):
        self.assertEqual(self.verdict()["status"], "passed")
        missing = evaluate_gate([], expected=expected_population(self.expected, self.identity["tree_sha"]), admission_identity=self.identity,
                                required_jobs=self.jobs, base_policy=policy(), environment="hermetic",
                                fork_originated=False, ci_changing=False, app_affected=True, allowed_events=("local",))
        self.assertEqual(missing["status"], "failed")
        self.assertTrue(any("missing required job/artifact" in error for error in missing["errors"]))
        admitted_job = self.jobs[0]
        for status, conclusion in (("completed", "failure"), ("completed", "cancelled"), ("completed", "timed_out"),
                                   ("completed", "skipped"), ("in_progress", "success"), ("queued", None),
                                   (None, None)):
            with self.subTest(status=status, conclusion=conclusion):
                self.jobs[0] = dict(admitted_job, status=status, conclusion=conclusion)
                verdict = self.verdict()
                self.assertEqual(verdict["status"], "failed")
                self.assertTrue(any("required job did not complete successfully" in error for error in verdict["errors"]))
                self.assertEqual(self.verdict(context="ui", app_affected=False)["status"], "failed")
        for field in ("status", "conclusion"):
            with self.subTest(missing_job_field=field):
                self.jobs[0] = {key: value for key, value in admitted_job.items() if key != field}
                self.assertEqual(self.verdict()["status"], "failed")
        self.jobs[0] = admitted_job
        self.assertEqual(self.verdict()["status"], "passed")
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
        candidate["approval_records"] = [approval_record("host")]
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
        self.jobs[0]["expected"] = expected_population(self.expected, self.identity["tree_sha"])
        self.jobs.append(dict(self.jobs[0], shard="second"))
        verdict = evaluate_gate([first, second], expected=expected_population(self.expected, self.identity["tree_sha"]), admission_identity=self.identity,
                                required_jobs=self.jobs, base_policy=policy(), environment="hermetic",
                                fork_originated=False, ci_changing=False, app_affected=True, allowed_events=("local",))
        self.assertEqual(verdict["status"], "failed")
        self.assertTrue(any("missing compiled" in error for error in verdict["errors"]))

    def test_removal_report_requires_the_admitted_base_and_does_not_gate_coverage(self):
        self.identity = {"schema_version": 1, "event": "pull_request", "repository": "sudoHG/immichSlides",
                         "tree_sha": "b" * 40, "merge_sha": "a" * 40,
                         "base_sha": "c" * 40, "head_sha": "d" * 40, "pull_request": 1}
        self.summary["identity"] = self.identity
        self.summary["source"].update(event="pull_request", workflow_path=".github/workflows/ci-gate.yml")
        self.summary["run"]["id"] = "42"
        self.jobs[0].update(run_id="42", workflow_paths=[".github/workflows/ci-gate.yml"])
        old = ci_summary.test_identity("host", "removed-on-pr")
        admitted_base = {"base_sha": self.identity["base_sha"], "identities": self.expected + [old]}
        before = self.verdict(base_population=admitted_base)
        added_on_main = ci_summary.test_identity("host", "new-on-main")
        later_main = {"base_sha": "e" * 40, "identities": admitted_base["identities"] + [added_on_main]}
        rejected = self.verdict(base_population=later_main)
        self.assertEqual(rejected["status"], "failed")
        self.assertEqual(rejected["removed_by_pr"], [])
        self.assertTrue(any("admitted base SHA" in error for error in rejected["errors"]))
        later_denominator = expected_population(self.expected + [added_on_main], "f" * 40)
        for location in ("overall", "job"):
            with self.subTest(location=location):
                if location == "overall":
                    rejected = self.verdict(base_population=admitted_base, expected=later_denominator)
                else:
                    admitted_job = self.jobs[0]["expected"]
                    self.jobs[0]["expected"] = later_denominator
                    rejected = self.verdict(base_population=admitted_base)
                    self.jobs[0]["expected"] = admitted_job
                self.assertEqual(rejected["status"], "failed")
                self.assertTrue(any("admitted tree SHA" in error for error in rejected["errors"]))
        for malformed in (None, self.expected, {}, expected_population(self.expected, "invalid"),
                          expected_population(None, self.identity["tree_sha"]),
                          expected_population(self.expected * 2, self.identity["tree_sha"])):
            with self.subTest(expected=malformed):
                self.assertEqual(self.verdict(base_population=admitted_base, expected=malformed)["status"], "failed")
                admitted_job = self.jobs[0]["expected"]
                self.jobs[0]["expected"] = malformed
                self.assertEqual(self.verdict(base_population=admitted_base)["status"], "failed")
                self.jobs[0]["expected"] = admitted_job
        after = self.verdict(base_population=admitted_base)
        self.assertEqual(after["status"], before["status"])
        self.assertEqual(after["status"], "passed")
        self.assertEqual(before["removed_by_pr"], [old])
        self.assertEqual(after["removed_by_pr"], [old])
        self.assertEqual(after["errors"], before["errors"])
        self.assertEqual(self.verdict()["status"], "passed")
        self.assertEqual(self.verdict()["removed_by_pr"], [])
        for malformed in (None, admitted_base["identities"], {},
                          dict(admitted_base, base_sha="invalid"), dict(admitted_base, identities=None),
                          dict(admitted_base, identities=[old, old]), dict(admitted_base, identities=[{}])):
            with self.subTest(base_population=malformed):
                verdict = self.verdict(base_population=malformed)
                self.assertEqual(verdict["status"], "failed")
                self.assertEqual(verdict["removed_by_pr"], [])

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
        allowlist = json.loads(Path(__file__).with_name("ci-classification.json").read_text(encoding="utf-8"))
        for paths, members, app, ci in ((["docs/README.md"], set(), False, False),
                                       (["docs/bundled.md"], {"docs/bundled.md"}, True, False),
                                       (["immichSlides/Resources/privacy.html"], set(), True, False),
                                       (["scripts/ci-test-policy.json"], set(), True, True),
                                       (["scripts/ci_population.py"], set(), True, True),
                                       (["scripts/test_ci_summary.py"], set(), True, True),
                                       (["scripts/run_host_checks.py"], set(), True, True),
                                       (["scripts/ui_test_inventory.py"], set(), True, True),
                                       (["scripts/ci-pins.json"], set(), True, True),
                                       (["scripts/ci-ui-shards.json"], set(), True, True),
                                       (["immichSlides-iOS.xctestplan"], set(), True, True),
                                       (["immichSlides-tvOS.xctestplan"], set(), True, True),
                                       ([".github/workflows/ci-gate.yml"], set(), True, True),
                                       ([".github/actions/check/action.yml", ".github/actions/check/check.py"], set(), True, True),
                                       ([".swift-format"], set(), True, True),
                                       (["scripts/check_test_conventions.py", "scripts/test_conventions_allowlist.json"], set(), True, True),
                                       (["AGENTS.md", "CLAUDE.md", ".github/ISSUE_TEMPLATE/bug.md"], set(), True, False),
                                       (["scripts/run_strict_e2e.py", "scripts/test_strict_e2e_photo_identity.py"], set(), True, True),
                                       (["scripts/clean_stale_catalog_entries.py", "scripts/test_clean_stale_catalog_entries.py"], set(), True, False),
                                       (["unknown.file"], set(), True, False)):
            with self.subTest(paths=paths):
                classification = classify_changes(paths, allowlist, build_target_paths=members)
                self.assertEqual((classification["app_affected"], classification["ci_changing"]), (app, ci))
        host_paths = [part for _, command in HOST_CHECKS for part in command if part.startswith("scripts/")]
        host_paths += ["scripts/test_check_test_conventions.py", "scripts/test_check_release_guards.py",
                       "scripts/test_validate_localization_catalog.py", "scripts/test_scan_chinese_strings.py",
                       "scripts/test_required_test_tools.py", "scripts/test_conventions_allowlist.json"]
        root = Path(__file__).resolve().parent.parent
        for workflow in (root / ".github/workflows").glob("*.yml"):
            source = workflow.read_text(encoding="utf-8")
            for reference in re.findall(r"\bscripts/[A-Za-z0-9_./*?\[\]-]+", source):
                if any(character in reference for character in "*?["):
                    matches = [str(path.relative_to(root)) for path in root.glob(reference) if path.is_file()]
                    self.assertTrue(matches, f"workflow path pattern has no files: {reference}")
                    host_paths += matches
                else:
                    host_paths.append(reference)
            for action in re.findall(r"\buses:\s*['\"]?\./([A-Za-z0-9_./-]+)", source):
                action_files = [str(path.relative_to(root)) for path in (root / action).rglob("*") if path.is_file()]
                self.assertTrue(action_files, f"local action path has no files: {action}")
                host_paths += action_files
            # Bare names in the source-free consumer toolset are CI inputs too.
            for copied in re.findall(r"for file in ([^;]+); do", source):
                host_paths += ["scripts/" + name for name in copied.split()]
        host_paths += ["scripts/test_check_all.py", "scripts/test_git_privacy_gate.py", "scripts/__init__.py"]
        host_paths += [str(path.relative_to(root)) for path in (root / "scripts").glob("git_privacy_gate_test_*.py")]
        host_paths += ["scripts/test_run_offline_unit_tests.py"]
        host_paths += [str(path.relative_to(root)) for path in (root / "scripts").glob("run_offline_unit_tests_test_*.py")]
        for path in host_paths:
            with self.subTest(host_path=path):
                self.assertTrue(classify_changes([path], allowlist, build_target_paths=set())["ci_changing"])
        local_modules = {path.stem: path for path in (root / "scripts").glob("*.py")}
        pending = [path for path in local_modules.values()
                   if classify_changes([str(path.relative_to(root))], allowlist, build_target_paths=set())["ci_changing"]]
        visited = set()
        while pending:
            path = pending.pop()
            if path in visited:
                continue
            visited.add(path)
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"), filename=str(path))):
                if isinstance(node, ast.Import):
                    names = [alias.name for alias in node.names]
                elif isinstance(node, ast.ImportFrom):
                    names = (["__init__"] + [alias.name for alias in node.names] if node.module == "scripts"
                             else [node.module] if node.module else [alias.name for alias in node.names])
                else:
                    continue
                for name in names:
                    module = name.removeprefix("scripts.").split(".")[0]
                    if module in local_modules:
                        dependency = local_modules[module]
                        relative = str(dependency.relative_to(root))
                        with self.subTest(importer=str(path.relative_to(root)), dependency=relative):
                            self.assertTrue(classify_changes([relative], allowlist, build_target_paths=set())["ci_changing"],
                                            "CI-trusted scripts must include their recursive local-import closure")
                        pending.append(dependency)
        for pattern in allowlist["ci_trusted"] + allowlist["app_unaffected"]:
            if not any(character in pattern for character in "*?["):
                with self.subTest(exact_path=pattern):
                    self.assertTrue((root / pattern).is_file(), "exact classification entries must exist")
        self.assertEqual(self.verdict(context="ui", app_affected=False)["status"], "not-applicable")
        with self.assertRaisesRegex(ci_summary.ContractError, "changed path list"):
            classify_changes([], allowlist, build_target_paths=set())
        for path in ("../README.md", "/README.md", "docs/../scripts/x.py"):
            with self.subTest(path=path), self.assertRaises(ci_summary.ContractError):
                classify_changes([path], allowlist, build_target_paths=set())


if __name__ == "__main__":
    unittest.main()
