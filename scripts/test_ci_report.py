"""Reporter decisions guard duplicate notifications, premature closure and lost provenance."""

import copy
import json
import subprocess
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
    def test_nightly_ui_reader_rejects_missing_samples_and_foreign_shards(self):
        from ci_nightly_ui import judge_ui, parse_ui_plan, validate_ui_record
        identity = {"schema_version": 1, "repository": "sudoHG/immichSlides", "event": "schedule",
                    "ref": "refs/heads/main", "commit_sha": "a" * 40, "tree_sha": "b" * 40}
        plan = {"schema_version": 1, "identity": identity, "run": {"id": "10", "attempt": 1},
                "source": {"repository": identity["repository"], "workflow_path": ci_report.NIGHTLY_PATH,
                           "event": "schedule", "fork_originated": False, "ci_changing": None},
                "hashes": {}, "shards": [], "max_parallel": 2, "started_epoch": 1}
        summaries = []
        for device, platform in (("iphone", "ios"), ("ipad", "ios"), ("appletv", "tvos")):
            plan["hashes"][device] = {"manifests": {"ui-shards": "c" * 64}, "policies": {}}
            for shard in ("default", "navigation", "visual"):
                test = test_identity("ui", "ExampleUITests/test" + shard.capitalize(), platform=platform, device=device)
                plan["shards"].append({"device": device, "shard": shard, "declared": [test]})
                summary = valid_summary()
                summary.update(identity=identity, source=plan["source"], hashes=plan["hashes"][device],
                               run={**plan["run"], "tier": "ui", "job": "ui-" + device, "shard": shard})
                summary["population"].update(declared=[test], compiled=[test], observed=[observation(test, "passed", 2)])
                summaries.append(summary)
        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        good = judge_ui(plan, summaries, policy=policy, registry={"schema_version": 1, "entries": []},
                        evaluated_on=date(2026, 10, 1), matrix_job_result="success")
        self.assertEqual("passed", good["status"])
        self.assertEqual(9, good["matrix"]["executed"])
        expanded, expanded_summaries = copy.deepcopy(plan), copy.deepcopy(summaries)
        for device, platform in (("iphone", "ios"), ("ipad", "ios"), ("appletv", "tvos")):
            next(item for item in expanded["shards"] if item["device"] == device and item["shard"] == "visual")["shard"] = "visual-1"
            original = next(item for item in expanded_summaries if item["run"]["job"] == "ui-" + device and item["run"]["shard"] == "visual")
            original["run"]["shard"] = "visual-1"
            extra = test_identity("ui", "ExampleUITests/testVisualMore", platform=platform, device=device)
            expanded["shards"].append({"device": device, "shard": "visual-2", "declared": [extra]})
            summary = copy.deepcopy(original)
            summary["run"]["shard"] = "visual-2"
            summary["population"].update(declared=[extra], compiled=[extra], observed=[observation(extra, "passed", 1)])
            expanded_summaries.append(summary)
        expanded_good = judge_ui(expanded, expanded_summaries, policy=policy, registry={"schema_version": 1, "entries": []},
                                 evaluated_on=date(2026, 10, 1), matrix_job_result="success")
        self.assertEqual(("passed", 12), (expanded_good["status"], expanded_good["matrix"]["executed"]))
        intervals = [{"shard": item["device"] + "/" + item["shard"], "started_epoch": index + 1, "finished_epoch": index + 2}
                     for index, item in enumerate(expanded["shards"])]
        expanded_record = {"schema_version": 1, "plan": expanded, "verdict": expanded_good, "matrix_job_result": "success",
            "capacity": {"max_parallel": 2, "shards": 12, "minimum_shard_waves": 6, "shard_intervals": intervals,
                         "start_order_waves": [[item["shard"] for item in intervals[index:index + 2]] for index in range(0, 12, 2)],
                         "wall_seconds": 14}}
        validate_ui_record(expanded_record, expanded_summaries, policy=policy, registry={"schema_version": 1, "entries": []},
                           evaluated_on=date(2026, 10, 1))
        stale_capacity = copy.deepcopy(expanded_record)
        stale_capacity["capacity"].update(shards=9, minimum_shard_waves=5)
        with self.assertRaises(ContractError):
            validate_ui_record(stale_capacity, expanded_summaries, policy=policy, registry={"schema_version": 1, "entries": []},
                               evaluated_on=date(2026, 10, 1))
        for change in ("missing-shard", "missing-sample", "foreign-attempt", "duplicate-shard", "failed-job"):
            records = copy.deepcopy(summaries)
            job_result = "success"
            if change == "missing-shard":
                records.pop()
            elif change == "missing-sample":
                records[-1]["population"]["observed"] = []
            elif change == "foreign-attempt":
                records[-1]["run"]["attempt"] = 2
            elif change == "duplicate-shard":
                records.append(records[-1])
            else:
                job_result = "failure"
            with self.subTest(change=change):
                result = judge_ui(plan, records, policy=policy, registry={"schema_version": 1, "entries": []},
                                  evaluated_on=date(2026, 10, 1), matrix_job_result=job_result)
                self.assertEqual("failed", result["status"])
                self.assertTrue(result["errors"])
                self.assertEqual(9, len(result["shards"]))
        for version in (True, "1", 2):
            with self.subTest(version=version), self.assertRaises(ContractError):
                parse_ui_plan(dict(plan, schema_version=version))
        incomplete = copy.deepcopy(plan)
        incomplete["shards"] = incomplete["shards"][:-1]
        with self.assertRaises(ContractError):
            parse_ui_plan(incomplete)

    def test_nightly_ui_successor_is_bound_to_artifacts_and_diagnostics_cannot_write(self):
        import hashlib
        from ci_nightly import aggregate_nightly
        from ci_nightly_ui import judge_ui
        from strict_e2e_server import fixture_manifest
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
               "head_sha": "a" * 40, "path": ci_report.NIGHTLY_PATH, "event": "schedule", "head_branch": "main",
               "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "failure"}
        identity = {"schema_version": 1, "repository": api.repository, "event": "schedule", "ref": "refs/heads/main",
                    "commit_sha": run["head_sha"], "tree_sha": "b" * 40}
        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        registry = {"schema_version": 1, "entries": []}
        blobs = {"scripts/ci-test-policy.json": json.dumps(policy).encode(), "scripts/ci-known-flaky.json": json.dumps(registry).encode()}
        blobs["scripts/strict_e2e_server.py"] = Path(__file__).with_name("strict_e2e_server.py").read_bytes()
        blobs.update({"scripts/ci-ui-shards.json": json.dumps({"schema_version": 1, "revision": "example-v1",
            "default_shard": "default", "shards": {"default": [], "navigation": ["NavigationUITests"], "visual": ["VisualUITests"]}}).encode(),
            "immichSlides-iOS.xctestplan": json.dumps({"testTargets": [{"target": {"name": "immichSlidesUITests"}}]}).encode(),
            "immichSlides-tvOS.xctestplan": json.dumps({"testTargets": [{"target": {"name": "immichSlidesUITests"}}]}).encode(),
            "immichSlidesUITests/Example.swift": b"\n".join(
                ("final class " + shard.capitalize() + "UITests: XCTestCase { func test" + shard.capitalize() + "() {} }").encode()
                for shard in ("default", "navigation", "visual"))})
        hashes = {"manifests": {"ui-shards": hashlib.sha256(blobs["scripts/ci-ui-shards.json"]).hexdigest(),
                  "test-plan": hashlib.sha256(blobs["immichSlides-iOS.xctestplan"]).hexdigest(),
                  "fixture-c": fixture_manifest("c")["fixture_sha256"]}, "policies": {
            name: hashlib.sha256(blobs[path]).hexdigest() for name, path in (
                ("test-policy", "scripts/ci-test-policy.json"), ("known-flaky", "scripts/ci-known-flaky.json"))}}
        source = {"repository": api.repository, "workflow_path": ci_report.NIGHTLY_PATH, "event": "schedule",
                  "fork_originated": False, "ci_changing": None}
        plan = {"schema_version": 1, "identity": identity, "source": source, "run": {"id": "10", "attempt": 1},
                "hashes": {device: hashes for device in ("iphone", "ipad", "appletv")},
                "shards": [], "max_parallel": 2, "started_epoch": 1}
        members, summaries, intervals = {}, [], []
        for device, platform in (("iphone", "ios"), ("ipad", "ios"), ("appletv", "tvos")):
            for shard in ("default", "navigation", "visual"):
                test = test_identity("ui", shard.capitalize() + "UITests/test" + shard.capitalize(), device=device, platform=platform)
                plan["shards"].append({"device": device, "shard": shard, "declared": [test]})
                summary = valid_summary()
                summary.update(identity=identity, source=source, hashes=hashes,
                               run={**plan["run"], "tier": "ui", "job": "ui-" + device, "shard": shard})
                outcome = "failed" if device == "appletv" and shard == "visual" else "passed"
                summary["population"].update(declared=[test], compiled=[test], observed=[observation(
                    test, outcome, 2, message="private-runner-failure-text" if outcome == "failed" else None,
                    reason="private-runner-reason" if outcome == "failed" else None)])
                summaries.append(summary)
                members[(f"ui-{device}-{shard}-10-1", "summary.json")] = summary
                intervals.append({"shard": device + "/" + shard, "started_epoch": len(intervals) + 1, "finished_epoch": len(intervals) + 2})
        ui = {"schema_version": 1, "plan": plan, "matrix_job_result": "failure",
              "verdict": judge_ui(plan, summaries, policy=policy, registry=registry, evaluated_on=date(2026, 10, 1), matrix_job_result="failure"),
              "capacity": {"max_parallel": 2, "shards": 9, "minimum_shard_waves": 5, "shard_intervals": intervals,
                           "start_order_waves": [[item["shard"] for item in intervals[index:index + 2]] for index in range(0, 9, 2)], "wall_seconds": 10}}
        raw = aggregate_nightly([], [], live_in_scope=False)
        raw.update(schema_version=2, identity=identity, source={**source, "approval_based": False}, hashes=hashes, run=plan["run"], ui=ui,
                   capacity={"shard_intervals": []})
        raw["matrix"]["equal"] = True
        raw["errors"] = []
        raw["tiers"]["ui"] = "failed"
        members[("nightly-aggregate-10-1", "nightly.json")] = raw
        members[("nightly-ui-aggregate-10-1", "nightly-ui.json")] = ui
        artifacts = [{"name": name, "expired": False} for name in sorted({name for name, _ in members})]
        def git_output(command, **kwargs):
            if command[1] == "ls-tree":
                return b"100644 blob " + b"d" * 40 + b"\timmichSlidesUITests/Example.swift\0"
            if command[1] == "rev-parse":
                return b"b" * 40 + b"\n"
            return blobs[command[-1].split(":", 1)[1]]
        with patch("ci_publish.json_member", side_effect=lambda api, artifact, member: members[(artifact["name"], member)]), \
                patch("subprocess.check_output", side_effect=git_output), patch("ci_report.on_main", return_value=True):
            report = ci_report.nightly_attempt(api, run, 1, artifacts)
            self.assertEqual(9, report["diagnostics"]["counts"]["ui_executed"])
            failed = [item for item in report["observed"] if item["outcome"] == "failed"]
            self.assertEqual("appletv", failed[0]["identity"]["dimensions"]["device"])
            self.assertEqual("open", issue_decision(None, failed[0]["identity"], [report], registry_referenced=False)["action"])
            self.assertEqual(9, report["diagnostics"]["counts"]["declared"])
            api.pages = lambda path, collection: artifacts
            history = ci_report.read_run(api, run, {})
            self.assertNotIn("private-runner-failure-text", json.dumps(ci_report.compact_entry(history, set())["attempt_history"]))
            self.assertNotIn("private-runner-reason", json.dumps(ci_report.compact_entry(history, set())["attempt_history"]))
            outer_source = raw["source"]
            for field, value in (("repository", "foreign/repository"), ("workflow_path", ci_report.REPORT_PATH),
                                 ("event", "workflow_dispatch"), ("fork_originated", True), ("ci_changing", True),
                                 ("approval_based", True), ("approval_based", 0), ("unknown", "untrusted")):
                raw["source"] = {**outer_source, field: value}
                with self.subTest(outer_source=field, value=value), self.assertRaises(ContractError):
                    ci_report.nightly_attempt(api, run, 1, artifacts)
            raw["source"] = {key: value for key, value in outer_source.items() if key != "approval_based"}
            with self.subTest(outer_source="missing approval_based"), self.assertRaises(ContractError):
                ci_report.nightly_attempt(api, run, 1, artifacts)
            raw["source"] = outer_source
            fixture_source = blobs["scripts/strict_e2e_server.py"]
            blobs["scripts/strict_e2e_server.py"] += b"\n# different tested fixture source\n"
            with self.assertRaisesRegex(ContractError, "fixture-source-drift"):
                ci_report.nightly_attempt(api, run, 1, artifacts)
            drift = ci_report.read_run(api, run, {})
            self.assertEqual("failed", drift["status"])
            self.assertIn("fixture-source-drift", drift["diagnostics"]["infrastructure"])
            self.assertNotIn("different tested fixture source", json.dumps(drift))
            blobs["scripts/strict_e2e_server.py"] = fixture_source
            for change in ("unverified shard plus a real failure in another shard", "missing sample", "missing compilation"):
                changed = copy.deepcopy(summaries)
                if change.startswith("unverified"):
                    changed[0]["status"] = "unverified"
                elif change == "missing sample":
                    changed[0]["population"]["observed"] = []
                else:
                    changed[0]["population"]["compiled"] = []
                ui["verdict"] = judge_ui(plan, changed, policy=policy, registry=registry,
                    evaluated_on=date(2026, 10, 1), matrix_job_result="failure")
                for index, item in enumerate(plan["shards"]):
                    members[(f"ui-{item['device']}-{item['shard']}-10-1", "summary.json")] = changed[index]
                with self.subTest(change=change):
                    incomplete = ci_report.nightly_attempt(api, run, 1, artifacts)
                    self.assertTrue(any("nightly UI" in error for error in incomplete["diagnostics"]["infrastructure"]))
                    self.assertEqual(9, incomplete["diagnostics"]["counts"]["declared"])
                    tracked = plan["shards"][1]["declared"][0]
                    opened = issue_decision(None, tracked, [entry(outcome="failed") | {
                        "observed": [observation(tracked, "failed", 1)]}], registry_referenced=False)["state"]
                    incomplete["day"] = "2026-10-02"
                    self.assertEqual([], issue_decision(opened, tracked, [incomplete], registry_referenced=False)["state"]["explicit_pass_nights"])
            for index, item in enumerate(plan["shards"]):
                members[(f"ui-{item['device']}-{item['shard']}-10-1", "summary.json")] = summaries[index]
            skipped = summaries[0]["population"]["declared"][0]
            policy["approval_records"] = [{"tier": "ui", "approver": "example maintainer", "date": "2026-10-01",
                                            "link": "https://github.com/sudoHG/immichSlides/issues/123#issuecomment-123"}]
            policy["expected_skips"] = [{"kind": "ui", "key_pattern": skipped["key"], "dimensions": skipped["dimensions"],
                                         "tier": "ui", "environment": "fixture", "reason": "approved device skip"}]
            blobs["scripts/ci-test-policy.json"] = json.dumps(policy).encode()
            hashes["policies"]["test-policy"] = hashlib.sha256(blobs["scripts/ci-test-policy.json"]).hexdigest()
            summaries[0]["population"]["observed"] = [observation(skipped, "skipped", 1, reason="approved device skip")]
            ui["verdict"] = judge_ui(plan, summaries, policy=policy, registry=registry,
                evaluated_on=date(2026, 10, 1), matrix_job_result="failure")
            skipped_report = ci_report.nightly_attempt(api, run, 1, artifacts)
            self.assertEqual(0, skipped_report["health"]["unexpected_skips"])
            for path in ("immichSlidesUITests/Example.swift", "scripts/ci-ui-shards.json",
                         "immichSlides-iOS.xctestplan", "immichSlides-tvOS.xctestplan"):
                original = blobs[path]
                blobs[path] = (original.replace(b"testDefault", b"testInvented") if path.endswith(".swift")
                               else original + b" ")
                with self.subTest(path=path), self.assertRaises(ContractError):
                    ci_report.nightly_attempt(api, run, 1, artifacts)
                blobs[path] = original
            for field, value in (("fork_originated", True), ("ci_changing", True)):
                plan["source"][field] = value
                with self.subTest(field=field), self.assertRaises(ContractError):
                    ci_report.nightly_attempt(api, run, 1, artifacts)
                plan["source"][field] = False if field == "fork_originated" else None
            for error in (subprocess.CalledProcessError(128, ["git", "show"]),
                          subprocess.TimeoutExpired(["git", "show"], 30), OSError("source unavailable")):
                def unavailable_source(command, **kwargs):
                    if command[1] == "show":
                        raise error
                    return git_output(command, **kwargs)
                with self.subTest(error=type(error).__name__), patch("subprocess.check_output", side_effect=unavailable_source):
                    unavailable = ci_report.read_run(api, run, {})
                    self.assertEqual("failed", unavailable["status"])
                    self.assertIn("nightly attempt evidence unavailable", unavailable["diagnostics"]["infrastructure"])
            for version in (True, "2", 3):
                with self.subTest(version=version), self.assertRaises(ContractError):
                    raw["schema_version"] = version
                    ci_report.nightly_attempt(api, run, 1, artifacts)
            raw["schema_version"] = 2
            with self.assertRaises(ContractError):
                ci_report.nightly_attempt(api, run, 1, artifacts[:-1])
        branch = dict(run, event="workflow_dispatch", head_branch="nightly-candidate")
        branch_identity = dict(identity, event="workflow_dispatch", ref="refs/heads/nightly-candidate")
        self.assertFalse(ci_report.nightly_ref_allowed(api, branch, branch_identity))
        api.diagnostic_nightly = True
        self.assertFalse(ci_report.nightly_ref_allowed(api, branch, branch_identity))
        api.dry_run = True
        self.assertTrue(ci_report.nightly_ref_allowed(api, branch, branch_identity))
        api.request_count = 0
        branch["repository"] = {"full_name": api.repository}
        api.repo = lambda path: {"id": 123, "path": ci_report.NIGHTLY_PATH} if path.startswith("actions/workflows/") else branch
        with tempfile.TemporaryDirectory() as directory, patch("ci_report.read_run", return_value=report):
            output = Path(directory, "diagnostic")
            self.assertEqual(0, ci_report.diagnose_nightly(api, [10], output))
            self.assertEqual([report], json.loads((output / "runs.json").read_text()))
            branch["workflow_id"] = 124
            with self.assertRaises(ContractError):
                ci_report.diagnose_nightly(api, [10], Path(directory, "foreign"))
            with self.assertRaisesRegex(ContractError, "outside checkout"):
                ci_report.diagnose_nightly(api, [10], Path(ci_report.__file__).resolve().parent.parent / "reader-diagnostic")
        for arguments in (["--diagnostic-nightly"], ["--dry-run", "--diagnostic-nightly"],
                          ["--dry-run", "--diagnostic-nightly", "--run-id", "10", "--phase", "sync"]):
            with self.subTest(arguments=arguments), self.assertRaises(ContractError):
                ci_report.main(arguments)

    def test_cloud_pr_diagnostics_require_trusted_proof_and_keep_compiled_inventory_unknown(self):
        identity = test_identity("ui", "ExampleTests/testExample", platform="tvos", device="appletv")
        proof = {"identities": [identity], "cloud_run_id": "verified-run"}
        with patch("ci_xcode_cloud.trusted_cloud", side_effect=AssertionError("second API read")) as reader:
            diagnostics = ci_report.cloud_pr_diagnostics([], cloud=proof)
        reader.assert_not_called()
        self.assertEqual(diagnostics["counts"], {"declared": 1, "observed": 1, "passed": 1,
                                               "compiled_not_exposed_by_api": 1})
        self.assertNotIn("compiled", diagnostics["counts"])
        with self.assertRaises(ContractError):
            ci_report.cloud_pr_diagnostics([], cloud=None)

    def test_archive_unavailable_ui_cannot_notify_for_a_superseded_unexecuted_gate(self):
        from ci_health import health_report
        from test_ci_publish import UnavailableUIAPI
        api = UnavailableUIAPI()
        with patch("ci_report.on_main", return_value=True):
            report = read_run(api, api.ui, {201: api.record})
        self.assertEqual("not-run", report["status"])
        self.assertEqual([], report["observed"])
        self.assertEqual([], report["diagnostics"]["failures"])
        self.assertEqual({"schema_version": 1, "first_attempt_failures": None}, report["first_execution_health"])
        self.assertIn("Not evaluated", render_entry(ci_report.compact_entry(report, set())))
        snapshot = ci_report.merge_snapshot(None, [ci_report.compact_entry(report, set())], date(2026, 10, 9))
        snapshot["producer"] = {"repository": api.repository}
        health = health_report(snapshot, {"entries": []}, "2026-10", date(2026, 10, 9))
        self.assertEqual({"not-run": 1}, health["coverage"]["statuses"])
        self.assertEqual(1, health["coverage"]["incomplete_evidence_runs"])
        with patch("ci_report.ensure_label") as writes:
            self.assertEqual(([], {}), synchronize_issues(api, [report], {"entries": []}))
        writes.assert_not_called()
        api.refusals = [{"outcome": "archive-identity-mismatch"}]
        with patch("ci_report.on_main", return_value=True):
            rejected = read_run(api, api.ui, {201: api.record})
        self.assertEqual("failed", rejected["status"])
        self.assertTrue(ci_report.issue_eligible(rejected))

    def test_unstarted_main_gate_is_not_run_and_all_cancellations_remain_ineligible(self):
        from test_ci_publish import RUN, UNSTARTED_GATE_JOBS, UnstartedGateAPI
        run = dict(RUN, event="push", head_branch="main", conclusion="cancelled",
                   created_at="2026-10-09T02:57:13Z")
        api = UnstartedGateAPI()
        with patch("ci_report.on_main", return_value=True):
            report = read_run(api, run, {})
        self.assertEqual("not-run", report["status"])
        self.assertEqual(run["head_sha"], report["pushed_sha"])
        self.assertEqual([], report["observed"])
        self.assertEqual([], report["diagnostics"]["infrastructure"])
        self.assertIn("Not evaluated", render_entry(report))
        compact = ci_report.compact_entry(report, set())
        self.assertEqual(report["not_evaluated_reason"], compact["not_evaluated_reason"])
        self.assertEqual({"schema_version": 1, "first_attempt_failures": None}, compact["first_execution_health"])
        self.assertEqual("cancelled", compact["conclusion"])
        self.assertEqual(run["created_at"], compact["created_at"])
        self.assertEqual(run["head_sha"], compact["head_sha"])
        self.assertIn("Not evaluated", render_entry(compact))
        saved = ci_report.merge_snapshot(None, [compact], date(2026, 10, 9))
        self.assertEqual("not-run", saved["days"]["2026-10-09"]["entries"][0]["status"])
        with patch("ci_report.ensure_label") as writes:
            self.assertEqual(([], {}), synchronize_issues(api, [report], {"entries": []}))
        writes.assert_not_called()
        for mutation in ({"runner_id": 123}, {"steps": [{"status": "completed"}]},
                         {"conclusion": "failure"}):
            api.jobs = [dict(UNSTARTED_GATE_JOBS[0], **mutation)]
            api.total_count = 1
            with patch("ci_report.on_main", return_value=True):
                started = read_run(api, run, {})
            self.assertEqual("unverified", started["status"])
            self.assertEqual([], started["observed"])
            self.assertEqual([], started["diagnostics"]["infrastructure"])
            self.assertFalse(ci_report.issue_eligible(started))
            with patch("ci_report.ensure_label", side_effect=AssertionError("cancelled push cannot notify")):
                self.assertEqual(([], {}), synchronize_issues(api, [started], {"entries": []},
                                                            post_merge_since="2026-10-09T00:00:00Z"))
        api.jobs = UNSTARTED_GATE_JOBS
        api.total_count = len(api.jobs)
        api.newer = []
        with patch("ci_report.on_main", return_value=True):
            self.assertEqual("unverified", read_run(api, run, {})["status"])
        api.newer = UnstartedGateAPI().newer
        with patch("ci_report.on_main", return_value=False):
            self.assertEqual("unverified", read_run(api, run, {})["status"])

    def transition(self, state, report, referenced=False):
        return issue_decision(state, IDENTITY, [report], registry_referenced=referenced)

    def test_snapshot_uses_upload_time_and_survives_an_interrupted_new_attempt(self):
        runs = {number: {"id": number, "workflow_id": 20, "path": ci_report.REPORT_PATH,
            "head_branch": "main", "repository": {"full_name": "sudoHG/immichSlides"},
            "head_repository": {"full_name": "sudoHG/immichSlides"}, "event": "schedule",
            "head_sha": "a" * 40, "run_attempt": 1} for number in (10, 20)}
        artifacts = [{"name": f"ci-report-daily-{number}-1", "expired": False,
            "created_at": created, "workflow_run": {"id": number, "head_branch": "main"}}
            for number, created in ((20, "2026-10-01T10:00:00Z"), (10, "2026-10-01T11:00:00Z"))]
        snapshots = {}
        for number in runs:
            saved = ci_report.merge_snapshot(None, [entry(run=number)], date(2026, 10, 1))
            saved["producer"] = {"repository": "sudoHG/immichSlides", "workflow_path": ci_report.REPORT_PATH,
                "run": {"id": str(number), "attempt": 1}, "commit_sha": "a" * 40}
            snapshots[f"ci-report-daily-{number}-1"] = saved
        class API:
            repository = "sudoHG/immichSlides"
            def repo(self, path, **options):
                if path == "actions/workflows/ci-report.yml":
                    return {"id": 20, "path": ci_report.REPORT_PATH}
                if path.startswith("actions/runs/"):
                    return runs[int(path.rsplit("/", 1)[-1])]
                return {"workflow_runs": [runs[20], runs[10]]}
            def pages(self, path, *args, **options):
                return artifacts if path == "actions/artifacts" else [item for item in artifacts
                    if item["workflow_run"]["id"] == int(path.split("/")[2])]
        for attempt in (1, 2):
            runs[10]["run_attempt"] = attempt
            with self.subTest(attempt=attempt), patch("ci_report.on_main", return_value=True), \
                    patch("ci_publish.json_member", side_effect=lambda api, artifact, member: snapshots[artifact["name"]]):
                self.assertEqual(snapshots["ci-report-daily-10-1"], ci_report.read_snapshot(API()))

    def test_closed_issue_history_does_not_expand_reads_and_collect_inventory_is_reused(self):
        from urllib.parse import parse_qs, urlparse
        state = self.transition(None, entry())["state"]
        state["closed"] = True
        target = {"number": 135, "state": "closed", "labels": [{"name": ci_report.LABEL}],
                  "body": ci_report.issue_body(None, state, "sudoHG/immichSlides")}
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.reads, self.searches, self.listings = [], [], []
            def pages(self, path, **filters):
                self.listings.append(filters)
                return [] if filters.get("state") == "open" else [target] * 1000
            def request(self, path, **options):
                query = parse_qs(urlparse(path).query)["q"][0]
                self.searches.append(query)
                return {"total_count": 1, "incomplete_results": False, "items": [target]}
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {}
                if path != "issues/135":
                    raise AssertionError("only the touched closed issue may be read or updated")
                if method == "GET":
                    self.reads.append(path)
                else:
                    target.update(payload)
                return target
        api = API()
        inventory = ci_report.visible_issues(api, ci_report.LABEL)
        self.assertEqual([], inventory)
        receipts, _ = synchronize_issues(api, [entry("2026-10-02", run=11)], {"entries": []}, inventory=inventory)
        self.assertEqual(["reopen"], [item["action"] for item in receipts])
        self.assertEqual(1, len(api.listings))
        self.assertEqual(["issues/135"], api.reads)
        self.assertEqual(1, len(api.searches))
        self.assertIn('label:"ci-reported-failure"', api.searches[0])
        self.assertIn('in:title "CI nightly failure: ExampleUITests/testPlayback"', api.searches[0])
        # Adopted registry issues retain their maintainer title after registry removal.
        target["state"] = "closed"
        target["title"] = "Existing maintainer diagnosis"
        api = API()
        target["body"] = ci_report.issue_body(None, state, api.repository)
        receipts, _ = synchronize_issues(api, [entry("2026-10-02", run=11)], {"entries": []}, inventory=[],
                                         issue_index={identity_token(IDENTITY): 135})
        self.assertEqual(["reopen"], [item["action"] for item in receipts])
        self.assertEqual([], api.searches)
        self.assertEqual(2, len(api.reads))

    def test_timeouts_and_missing_exports_are_infrastructure_not_contract_failures(self):
        method = test_identity("strict", "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke", **IDENTITY["dimensions"])
        case = test_identity("strict", "smoke", **IDENTITY["dimensions"])
        shard = valid_summary()
        shard["population"].update(declared=[case], compiled=[case], observed=[observation(case, "failed", 1, exit_code=124)])
        base = {"identity": case, "exit_code": 124, "build_operations": 0, "products_unchanged": True,
                "log_present": True, "official_methods": [{"identifier": method["key"], "result": "Passed"}],
                "official_summary": {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}}
        for changes in ({"automated_contract_failed": True, "infrastructure": [{"code": "step-timeout", "message": "timeout"}]},
                        {"automated_contract_failed": True, "exit_code": 65, "official_error": "export failed"},
                        {"automated_contract_failed": True, "exit_code": 65, "official_methods": []}, {"exit_code": 65}):
            with self.subTest(changes=changes):
                observed, missing = ci_report.method_observations(shard, {"warm": [{**base, **changes}]})
                self.assertFalse(any(item["outcome"] == "failed" for item in observed))
                self.assertTrue(missing)
        failed = copy.deepcopy(base)
        failed["official_methods"][0]["result"] = "Failed"
        failed["official_summary"].update(passedTests=0, failedTests=1)
        observed, _ = ci_report.method_observations(shard, {"warm": [failed]})
        self.assertEqual([method], [item["identity"] for item in observed if item["outcome"] == "failed"])

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

    def test_registry_warning_and_expiry_match_retry_dates_without_editing_entries(self):
        from ci_flaky import eligible_entry
        from test_ci_flaky import registry
        payload = registry()
        original = copy.deepcopy(payload)
        item = payload["entries"][0]
        for day, status, eligible in (("2026-10-30", "active", True),
                                      ("2026-10-31", "review-due", True),
                                      ("2026-11-07", "review-due", True),
                                      ("2026-11-08", "expired", False)):
            for states, expected in (({123: "open"}, "open"), ({123: "closed"}, "closed"),
                                     ({123: "missing"}, "missing"), ({}, "unknown")):
                with self.subTest(day=day, state=expected):
                    check = registry_checks(payload, day, states)[0]
                    self.assertEqual(status, check["review_status"])
                    self.assertEqual(expected, check["issue_state"])
                    self.assertEqual(eligible, check["date_eligible"])
                    self.assertEqual(eligible, eligible_entry(payload, item["identity"],
                        tier="ui", environment="hermetic", today=date.fromisoformat(day)) is not None)
        self.assertEqual(original, payload)

    def test_health_keeps_first_failure_after_rerun_and_reports_missing_legacy_metrics(self):
        from ci_health import health_report, observation_metrics
        first = entry("2026-10-01")
        first["health"] = observation_metrics(first["observed"], unexpected_skips=0)
        last = entry("2026-10-01", "passed", attempt=2)
        last["health"] = observation_metrics(last["observed"], unexpected_skips=0)
        last["attempt_history"] = [first, copy.deepcopy(last)]
        legacy = entry("2026-10-02", "passed", run=11)
        snapshot = ci_report.merge_snapshot(None, [last, legacy], date(2026, 10, 9))
        result = health_report(snapshot, {"entries": []}, "2026-10", date(2026, 10, 9))
        self.assertEqual(2, result["coverage"]["runs"])
        self.assertEqual(["2026-10-01", "2026-10-02"], result["coverage"]["days_with_runs"])
        self.assertEqual(6, result["coverage"]["missing_calendar_days"])
        self.assertEqual({"value": 1, "sampled_runs": 1, "missing_runs": 1}, result["metrics"]["first_attempt_failures"])
        self.assertEqual({"value": None, "sampled_runs": 0, "missing_runs": 2}, result["metrics"]["queue_seconds"])
        self.assertGreater(result["storage"]["snapshot_json_bytes"], 0)
        malformed = copy.deepcopy(snapshot)
        malformed["days"]["2026-10-01"]["retention_days"] = 7
        with self.assertRaises(ContractError):
            health_report(malformed, {"entries": []}, "2026-10", date(2026, 10, 9))

    def test_health_counts_retry_first_calls_before_compaction_and_rejects_bad_metrics(self):
        from ci_health import health_report, observation_metrics
        from ci_flaky import merge_retry
        report = entry()
        report["observed"] = [merge_retry(report["observed"][0], observation(IDENTITY, "passed", 2))]
        report["health"] = observation_metrics(report["observed"], unexpected_skips=0)
        compact = ci_report.compact_entry(report, set())
        snapshot = ci_report.merge_snapshot(None, [compact], date(2026, 10, 1))
        result = health_report(snapshot, {"entries": []}, "2026-10", date(2026, 10, 1))
        for key, expected in (("first_attempt_failures", 1), ("flaky_passed", 1), ("test_duration_seconds", 3)):
            self.assertEqual(expected, result["metrics"][key]["value"])
        for invalid in (-1, float("nan"), True):
            broken = copy.deepcopy(snapshot)
            broken["days"]["2026-10-01"]["entries"][0]["health"]["test_duration_seconds"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ContractError):
                health_report(broken, {"entries": []}, "2026-10", date(2026, 10, 1))

    def test_first_failure_survives_pending_snapshot_before_gate_or_ui_rerun_passes(self):
        from ci_health import health_report
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        now = date(2026, 10, 1)
        for path in ci_report.PRODUCER_PATHS[:2]:
            for status in ("queued", "in_progress"):
                with self.subTest(path=path, status=status):
                    run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
                           "head_sha": "a" * 40, "path": path, "event": "push", "head_branch": "main",
                           "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "failure"}
                    identity = {"schema_version": 1, "repository": api.repository, "event": "push", "ref": "refs/heads/main",
                                "pushed_sha": run["head_sha"], "tree_sha": "b" * 40}
                    record = {"workflow_id": 123, "workflow_path": path, "identity": identity,
                              "classification": {"ci_changing": False}, "workflows": {path: {"base": "trusted workflow"}}}
                    summary = valid_summary()
                    summary["identity"] = identity
                    summary["source"].update(event="push", workflow_path=path)
                    summary["run"]["id"] = str(run["id"])
                    test = summary["population"]["observed"][0]["identity"]
                    summary["population"]["observed"] = [observation(test, "failed", 2, exit_code=1)]
                    jobs = [{"status": "completed", "conclusion": "failure"}]
                    with patch("ci_report.on_main", return_value=True), \
                            patch("ci_publish.producer_evidence", return_value=(jobs, [summary])) as producer, \
                            patch("ci_publish_git.evaluate_records", return_value={"state": "success"}):
                        failed = read_run(api, run, {10: record})
                        snapshot = ci_report.merge_snapshot(None, [ci_report.compact_entry(failed, set())], now)
                        saved = snapshot["days"][now.isoformat()]["entries"][0]
                        pending = read_run(api, {**run, "run_attempt": 2, "status": status}, {10: record}, saved)
                        self.assertEqual(1, producer.call_count)
                        snapshot = ci_report.merge_snapshot(snapshot, [ci_report.compact_entry(pending, set())], now)
                        metrics = health_report(snapshot, {"entries": []}, "2026-10", now)["metrics"]
                        self.assertEqual({"value": 1, "sampled_runs": 1, "missing_runs": 0}, metrics["first_attempt_failures"])
                        saved = snapshot["days"][now.isoformat()]["entries"][0]
                        summary["run"]["attempt"] = 2
                        summary["population"]["observed"] = [observation(test, "passed", 3)]
                        jobs[0]["conclusion"] = "success"
                        passed = read_run(api, {**run, "run_attempt": 2, "conclusion": "success"}, {10: record}, saved)
                    self.assertEqual("passed", passed["status"])
                    snapshot = ci_report.merge_snapshot(snapshot, [ci_report.compact_entry(passed, set())], now)
                    metrics = health_report(snapshot, {"entries": []}, "2026-10", now)["metrics"]
                    self.assertEqual({"value": 1, "sampled_runs": 1, "missing_runs": 0}, metrics["first_attempt_failures"])

    def test_nightly_method_placeholder_durations_are_unavailable_after_compaction(self):
        from ci_health import health_report
        from ci_nightly import aggregate_nightly
        from run_strict_e2e import resolve_suite_selector
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
               "head_sha": "a" * 40, "path": ci_report.NIGHTLY_PATH, "event": "schedule", "head_branch": "main",
               "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "success"}
        identity = {"schema_version": 1, "repository": api.repository, "event": "schedule", "ref": "refs/heads/main",
                    "commit_sha": run["head_sha"], "tree_sha": "b" * 40}
        case = test_identity("strict", "smoke", **IDENTITY["dimensions"])
        summary = valid_summary()
        summary["identity"] = identity
        summary["source"].update(event="schedule", workflow_path=ci_report.NIGHTLY_PATH)
        summary["run"] = {"id": "10", "attempt": 1, "tier": "strict", "job": "nightly-strict", "shard": "iphone"}
        # A measured case invocation is not an individual method duration.
        summary["population"].update(declared=[case], compiled=[case], observed=[observation(case, "passed", 37)])
        aggregate = aggregate_nightly([case], [summary], live_in_scope=False)
        aggregate.update(identity=identity, hashes=summary["hashes"], run={"id": "10", "attempt": 1},
                         source=summary["source"], capacity={"shard_intervals": [{"shard": "iphone"}]})
        trace = {"warm": [{"identity": case, "official_methods": [
            {"identifier": resolve_suite_selector("ios", "smoke").split("/", 1)[1], "result": "Passed"}],
            "build_operations": 0, "products_unchanged": True, "log_present": True, "exit_code": 0,
            "official_summary": {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}}]}
        artifacts = [{"name": name, "expired": False} for name in ("nightly-aggregate-10-1", "nightly-strict-iphone-10-1")]
        with patch("ci_publish.json_member", side_effect=[aggregate, summary, trace]):
            report = ci_report.nightly_attempt(api, run, 1, artifacts)
        self.assertTrue(report["observed"])
        compact = ci_report.compact_entry(report, set())
        snapshot = ci_report.merge_snapshot(None, [compact], date(2026, 10, 1))
        metrics = health_report(snapshot, {"entries": []}, "2026-10", date(2026, 10, 1))["metrics"]
        self.assertEqual({"value": None, "sampled_runs": 0, "missing_runs": 1}, metrics["test_duration_seconds"])
        self.assertEqual({"value": 0, "sampled_runs": 1, "missing_runs": 0}, metrics["first_attempt_failures"])

    def test_monthly_due_date_handles_year_boundary_and_explicit_partial_month(self):
        from ci_health import report_month
        self.assertEqual("2025-12", report_month("schedule", {}, date(2026, 1, 1)))
        self.assertIsNone(report_month("schedule", {}, date(2026, 1, 2)))
        self.assertIsNone(report_month("workflow_run", {}, date(2026, 1, 1)))
        self.assertEqual("2026-01", report_month("workflow_dispatch", {"inputs": {"health_month": "2026-01"}}, date(2026, 1, 2)))
        for month in ("2026-02", "2026-13", "2026-1", "candidate text"):
            with self.subTest(month=month), self.assertRaises(ContractError):
                report_month("workflow_dispatch", {"inputs": {"health_month": month}}, date(2026, 1, 2))

    def test_health_skip_classification_uses_approved_rules_and_exact_reasons(self):
        from ci_health import unexpected_skips, run_metrics
        summary = valid_summary()
        identity = summary["population"]["observed"][0]["identity"]
        summary["population"]["observed"] = [observation(identity, "skipped", 0, reason="fixture unavailable")]
        rule = {"kind": identity["kind"], "key_pattern": identity["key"], "dimensions": identity["dimensions"],
                "tier": summary["run"]["tier"], "environment": "hermetic", "reason": "fixture unavailable"}
        policy = {"schema_version": 1, "expected_skips": [rule], "deselections": [],
                  "approval_records": [{"approver": "sudoHG", "date": "2026-10-01", "tier": summary["run"]["tier"],
                                        "link": "https://github.com/sudoHG/immichSlides/issues/83#issuecomment-123"}]}
        self.assertEqual(0, unexpected_skips([summary], policy, "hermetic"))
        self.assertEqual(1, unexpected_skips([summary], policy, "live"))
        policy["approval_records"] = []
        self.assertEqual(1, unexpected_skips([summary], policy, "hermetic"))
        self.assertIsNone(unexpected_skips([summary], None, "hermetic"))
        run = {"run_attempt": 1, "status": "completed", "created_at": "2026-10-01T00:00:00Z",
               "run_started_at": "2026-10-01T00:00:10Z", "updated_at": "2026-10-01T00:01:10Z"}
        jobs = [{"conclusion": "success", "created_at": "2026-10-01T00:00:10Z", "started_at": "2026-10-01T00:00:40Z"},
                {"conclusion": "success", "created_at": "2026-10-01T00:00:10Z", "started_at": "2026-10-01T00:00:50Z"}]
        self.assertEqual({"queue_seconds": 70, "run_duration_seconds": 60}, run_metrics(run, jobs))
        self.assertIsNone(run_metrics(run)["queue_seconds"])
        self.assertEqual(70, run_metrics({**run, "run_attempt": 2}, jobs)["queue_seconds"])
        from ci_health import observation_metrics
        self.assertIsNone(observation_metrics([], unexpected_skips=0)["first_attempt_failures"])
        self.assertIsNone(observation_metrics([], unexpected_skips=0)["test_duration_seconds"])

    def test_read_only_health_stops_on_quota_and_never_bootstraps_missing_history(self):
        for snapshot, error in ((None, ContractError), (ci_report.RateLimitLow(), None)):
            with self.subTest(snapshot=snapshot), tempfile.TemporaryDirectory() as temporary:
                api = ci_report.ReportGitHub("sudoHG/immichSlides", "synthetic", dry_run=True)
                with patch("ci_report.ReportGitHub", return_value=api), patch.dict("os.environ", {"CI_REPORT_TOKEN": "synthetic"}), \
                        patch.object(api, "request", return_value={}), patch("ci_report.read_snapshot", return_value=snapshot,
                            side_effect=snapshot if isinstance(snapshot, Exception) else None):
                    args = ["--phase", "health", "--dry-run", "--month", "2026-10", "--output-dir", temporary]
                    if error:
                        with self.assertRaises(error):
                            ci_report.main(args)
                    else:
                        self.assertEqual(0, ci_report.main(args))
                    self.assertEqual([], list(Path(temporary).iterdir()))

    def test_artifact_storage_reuses_listed_metadata_without_counting_pages_twice(self):
        api = ci_report.ReportGitHub("sudoHG/immichSlides", "synthetic", dry_run=True)
        response = {"artifacts": [{"id": 1, "size_in_bytes": 12}, {"id": 2, "size_in_bytes": 8}]}
        with patch("ci_publish.GitHub.request", return_value=response):
            api.repo("actions/runs/10/artifacts?per_page=100&page=1")
            api.repo("actions/runs/10/artifacts?per_page=100&page=1")
        self.assertEqual(20, sum(api.artifact_sizes[10].values()))
        self.assertEqual(2, api.request_count)

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
            def request(self, path, **options):
                return {"total_count": 0, "incomplete_results": False, "items": []}
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

    def test_post_merge_plan_requires_failure_identity_after_exact_reset_point(self):
        point = "2026-10-09T01:14:43Z"
        report = entry("2026-10-08", run=37759065943)
        report["source"].update(workflow_path=ci_report.PRODUCER_PATHS[0], event="push")
        report.update(pushed_sha="3f84ad734e632f7cabd6fcd2743d03e0c323b52a",
                      created_at="2026-10-08T09:47:17Z", conclusion="success", observed=[])
        report["diagnostics"].update(counts={"declared": 1051, "compiled": 1051, "observed": 1051,
                                           "passed": 1046, "skipped": 5},
                                     infrastructure=["missing required unit tier"])
        genuine = copy.deepcopy(report)
        genuine.update(day="2026-10-09", created_at="2026-10-09T02:00:00Z", conclusion="failure")
        genuine["diagnostics"]["counts"].update(passed=1045, failed=1)
        genuine["diagnostics"]["failures"] = [{"identity": test_identity("host", "format"), "outcome": "failed", "exit_codes": [1]}]
        cases = [(report, point, False), (genuine, point, True), (genuine, None, False)]
        for timestamp, accepted in (("2026-10-09T01:14:42Z", False), (point, True)):
            cases.append(({**genuine, "created_at": timestamp}, point, accepted))
        cases += [({key: value for key, value in genuine.items() if key != "created_at"}, point, False),
                  ({**genuine, "conclusion": "cancelled"}, point, False),
                  ({**genuine, "diagnostics": report["diagnostics"]}, point, False)]
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        for value, since, accepted in cases:
            with self.subTest(created=value.get("created_at"), since=since, accepted=accepted), tempfile.TemporaryDirectory() as temporary:
                snapshot = ci_report.merge_snapshot(None, [value], date(2026, 10, 9))
                if since:
                    snapshot["history_reset"] = {"actor": "sudoHG", "day": "2026-10-09", "run": "37868827278", "created_at": since}
                ci_report.write_report(Path(temporary), snapshot, [value], {"entries": []}, {}, stopped=False, now=date(2026, 10, 9))
                plan = json.loads((Path(temporary) / "sync.json").read_text())
                self.assertEqual([value] if accepted else [], plan["entries"])
                if not accepted:
                    with patch("ci_report.ensure_label", side_effect=AssertionError("no false-notification writes")):
                        self.assertEqual(([], {}), synchronize_issues(api, [value], {"entries": []}, post_merge_since=since))

    def test_newer_same_sha_producer_supersedes_a_saved_push_failure(self):
        first = entry()
        first["source"].update(workflow_path=ci_report.PRODUCER_PATHS[0], event="push")
        first.update(pushed_sha="a" * 40, created_at="2026-10-01T10:00:00Z", conclusion="failure")
        first["diagnostics"]["failures"] = [{"identity": test_identity("host", "format"), "outcome": "failed", "exit_codes": [1]}]
        newer = copy.deepcopy(first)
        newer.update(run={"id": 11, "attempt": 1}, created_at="2026-10-01T11:00:00Z", status="passed", conclusion="success")
        newer["diagnostics"]["failures"] = []
        since = "2026-10-01T00:00:00Z"
        self.assertEqual([first], ci_report.decision_entries([first], date(2026, 10, 1), post_merge_since=since))
        for status in ("passed", "pending", "unverified"):
            with self.subTest(status=status):
                latest = {**newer, "status": status}
                self.assertEqual([], ci_report.decision_entries([first, latest], date(2026, 10, 1), post_merge_since=since))
                api = type("API", (), {"repository": "sudoHG/immichSlides"})()
                with patch("ci_report.ensure_label", side_effect=AssertionError("no superseded notification")):
                    self.assertEqual(([], {}), synchronize_issues(api, [first, latest], {"entries": []}, post_merge_since=since))

    def test_verified_gate_and_ui_failures_after_reset_notify_once_per_sha(self):
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.issues, self.writes = [], []
            def pages(self, *args, **kwargs):
                return self.issues
            def request(self, path, **kwargs):
                return {"total_count": 0, "incomplete_results": False, "items": []}
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {}
                if path == "issues" and method == "POST":
                    self.writes.append(payload)
                    issue = {"number": 1, "state": "open", "body": payload["body"], "labels": [{"name": ci_report.LABEL}]}
                    self.issues.append(issue)
                    return issue
                if path == "issues/1" and method == "GET":
                    return self.issues[0]
                raise AssertionError("unexpected issue write")
        api, reports = API(), []
        for number, path in enumerate(ci_report.PRODUCER_PATHS[:2], 10):
            report = entry(run=number)
            report["source"].update(event="push", workflow_path=path)
            report.update(pushed_sha="a" * 40, created_at="2026-10-01T10:00:00Z", conclusion="failure")
            report["diagnostics"]["failures"] = [{"identity": test_identity("host", "format"), "outcome": "failed", "exit_codes": [1]}]
            reports.append(report)
        with patch("ci_report.wait_for_issue_visibility"):
            for _ in range(2):
                receipts, _ = synchronize_issues(api, reports, {"entries": []}, post_merge_since="2026-10-01T09:00:00Z")
                self.assertEqual(["post-merge"], [receipt["action"] for receipt in receipts])
        self.assertEqual(1, len(api.writes))
        self.assertIn("format", api.writes[0]["body"])
        self.assertIn(ci_report.PRODUCER_PATHS[0], api.writes[0]["body"])
        self.assertIn(ci_report.PRODUCER_PATHS[1], api.writes[0]["body"])

    def test_cancelled_nightly_or_push_does_not_read_missing_artifacts_or_track_failures(self):
        api = type("API", (), {"repository": "sudoHG/immichSlides",
                    "pages": lambda *args: self.fail("cancelled run must not read artifacts")})()
        for path, event in ((ci_report.NIGHTLY_PATH, "schedule"), (ci_report.PRODUCER_PATHS[0], "push")):
            run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
                   "head_sha": "a" * 40, "path": path, "event": event, "head_branch": "main",
                   "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "cancelled"}
            with self.subTest(path=path), patch("ci_report.on_main", return_value=True):
                report = ci_report.compact_entry(read_run(api, run, {}), set())
                self.assertEqual("unverified", report["status"])
                self.assertEqual("cancelled", report["conclusion"])
                self.assertEqual([], report["diagnostics"]["infrastructure"])
                self.assertFalse(ci_report.issue_eligible(report))
                self.assertEqual("none", issue_decision(None, NIGHTLY_INFRASTRUCTURE, [report], registry_referenced=False)["action"])

    def test_legacy_reset_point_uses_one_verified_read_and_is_cached_for_replay(self):
        reset = {"actor": "sudoHG", "day": "2026-10-09", "run": "37868827278"}
        run = {"id": 37868827278, "path": ci_report.REPORT_PATH, "event": "workflow_dispatch",
               "created_at": "2026-10-09T01:14:43Z", "head_branch": "main", "repository": {"full_name": "sudoHG/immichSlides"},
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "actor": {"login": "sudoHG"}, "triggering_actor": {"login": "sudoHG"}}
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        with patch.object(api, "repo", return_value=run, create=True) as reader:
            self.assertEqual(run["created_at"], ci_report.reset_notification_point(api, reset))
            self.assertEqual(run["created_at"], ci_report.reset_notification_point(api, reset))
            reader.assert_called_once_with("actions/runs/37868827278")
        for changes in ({"path": ci_report.PRODUCER_PATHS[0]}, {"actor": {"login": "other"}}):
            with self.subTest(changes=changes), patch.object(api, "repo", return_value={**run, **changes}, create=True), self.assertRaises(ContractError):
                ci_report.reset_notification_point(api, {key: value for key, value in reset.items() if key != "created_at"})
        limited = ci_report.ReportGitHub(api.repository, "", dry_run=True)
        limited.check_headers({"X-RateLimit-Remaining": "500", "X-RateLimit-Limit": "1000"})
        with self.assertRaises(ci_report.RateLimitLow):
            ci_report.reset_notification_point(limited, {key: value for key, value in reset.items() if key != "created_at"})
        self.assertEqual(0, limited.request_count)
        snapshot = ci_report.merge_snapshot(None, [], date(2026, 10, 9))
        snapshot["history_reset"] = {key: value for key, value in reset.items() if key != "created_at"}
        with tempfile.TemporaryDirectory() as temporary, patch("ci_report.read_snapshot", return_value=snapshot), \
                patch.object(limited, "request", return_value=None), patch.object(limited, "repo", side_effect=ci_report.RateLimitLow):
            self.assertEqual(0, ci_report.collect_report(limited, "schedule", {}, date(2026, 10, 9), Path(temporary)))
            saved = json.loads((Path(temporary) / "daily/history.json").read_text())
            self.assertEqual(snapshot["days"], saved["days"])
            self.assertTrue(saved["budget_stopped"])
            self.assertEqual([], json.loads((Path(temporary) / "sync.json").read_text())["entries"])

    def test_immediate_issue_replay_survives_label_index_delay(self):
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.issues, self.created = {}, 0
                self.index_lag = False
            def pages(self, path, **filters):
                if self.index_lag and "labels" in filters:
                    self.index_lag = False
                    return []
                return list(self.issues.values())
            def request(self, path, **options):
                return {"total_count": 0, "incomplete_results": False, "items": []}
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {"name": "ci-reported-failure"}
                if path == "issues":
                    self.created += 1
                    issue = {"number": self.created, "body": payload["body"], "state": "open",
                             "labels": [{"name": name} for name in payload["labels"]]}
                    self.issues[self.created] = issue
                    self.index_lag = True
                    return issue
                number = int(path.rsplit("/", 1)[-1])
                if method == "PATCH":
                    self.issues[number].update(payload)
                return self.issues[number]
        api = API()
        with patch("ci_report.time.sleep"):
            synchronize_issues(api, [entry()], {"entries": []})
        self.assertEqual([], synchronize_issues(api, [entry()], {"entries": []})[0])
        self.assertEqual(1, api.created)

    def test_main_ui_skips_require_the_existing_trusted_reuse_verdict(self):
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        run = {"id": 12, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
               "head_sha": "a" * 40, "path": ".github/workflows/ci-ui.yml", "event": "push", "head_branch": "main",
               "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "success"}
        identity = {"schema_version": 1, "repository": api.repository, "event": "push", "ref": "refs/heads/main",
                    "pushed_sha": run["head_sha"], "tree_sha": "b" * 40}
        record = {"workflow_id": 123, "workflow_path": run["path"], "identity": identity,
                  "classification": {"ci_changing": False}, "workflows": {run["path"]: {"base": "trusted workflow"}}}
        jobs = [{"name": "ui-archive", "status": "completed", "conclusion": "success"},
                {"name": "ui-iphone-default", "status": "completed", "conclusion": "skipped"}]
        summary = valid_summary()
        summary["identity"] = identity
        summary["source"].update(event="push", workflow_path=run["path"])
        summary["run"]["id"] = str(run["id"])
        for verdict in ({"state": "success", "reuse": {"producer_run_id": 10}}, ContractError("no trusted proof")):
            with self.subTest(verdict=verdict), patch("ci_report.on_main", return_value=True), \
                    patch("ci_publish.producer_evidence", return_value=(jobs, [summary])), \
                    patch("ci_ui_reuse.evaluate_reused_push", side_effect=verdict if isinstance(verdict, Exception) else None,
                          return_value=verdict) as reuse:
                report = read_run(api, run, {12: record})
                self.assertEqual("passed" if isinstance(verdict, dict) else "failed", report["status"])
                reuse.assert_called_once_with(api, record, run, jobs, [summary])

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
        trace["warm"][0]["automated_contract_failed"] = True
        outcomes = ci_report.method_observations(shard, trace)[0]
        self.assertEqual([case], [item["identity"] for item in outcomes if item["outcome"] == "failed"])
        self.assertEqual("strict-case-contract-failed", outcomes[-1]["attempts"][0]["reason"])
        trace["warm"][0].pop("official_methods")
        observed, missing = ci_report.method_observations(shard, trace)
        self.assertEqual([], observed)
        self.assertTrue(missing)

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
                patch("ci_report.matching_issues", return_value=[]), \
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
                if path == "actions/runs/10":
                    return run
                if path.startswith("actions/artifacts?"):
                    from urllib.parse import parse_qs, urlparse
                    return {"artifacts": [{"name": "unrelated"}] * 100 if parse_qs(urlparse(path).query)["page"] == ["1"] else [{
                        "name": "ci-report-daily-10-1", "expired": False, "created_at": "2026-10-01T10:00:00Z",
                        "workflow_run": {"id": 10, "head_branch": "main"}}]}
                return {"workflow_runs": [run]}
            def pages(self, path, *args, **options):
                return ci_report.GitHub.pages(self, path, *args, **options)
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
                    patch.dict("os.environ", {"GITHUB_ACTOR": actor, "GITHUB_TRIGGERING_ACTOR": actor, "GITHUB_RUN_ID": ""}, clear=False):
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
            def request(self, path, **options):
                return {"total_count": 0, "incomplete_results": False, "items": []}
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
