"""Protect the shadow verdict and its source/run binding, without running Xcode."""

import copy
import hashlib
import json
import os
import tempfile
import time
import unittest
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import ci_smoke_shadow as shadow
from ci_summary import ContractError


HEAD = "a" * 40
REPOSITORY = "example/photos"


def environment(event="workflow_run"):
    return {"GITHUB_EVENT_NAME": event, "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": REPOSITORY, "GITHUB_RUN_ID": "200", "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_SHA": "b" * 40, "SMOKE_NIGHTLY_RUN_ID": "100"}


def nightly():
    return {"id": 100, "run_attempt": 1, "path": ".github/workflows/ci-nightly.yml", "workflow_id": 7,
            "repository": {"full_name": REPOSITORY}, "head_repository": {"full_name": REPOSITORY},
            "head_branch": "main", "head_sha": HEAD, "event": "schedule", "status": "completed",
            "conclusion": "failure"}


def manifest():
    return {"schema_version": 1, "flows": [
        {"id": "phone-one", "platform": "ios", "device": "iphone", "configuration": "Debug",
         "fixtures": ["a"], "selector": "Smoke/testPhone"},
        {"id": "tv-one", "platform": "tvos", "device": "tv", "configuration": "Release",
         "fixtures": ["a", "b"], "selector": "Smoke/testTV"}]}


def plan():
    return shadow.make_plan(environment(), nightly(), manifest(), "c" * 64, "real")


def group_records(scheduling):
    records = []
    for group in scheduling["groups"]:
        records.append({"schema_version": 1, "shadow": scheduling["shadow"], "head_sha": HEAD,
                        "manifest_sha256": scheduling["manifest_sha256"], "group": group,
                        "selection": "group", "runner_exit_code": 0, "elapsed_seconds": 2, "errors": [],
                        "group_validation": {"outcome": "passed", "reason": None},
                        "job_started_epoch": 1, "job_elapsed_seconds": 2,
                        "phases": [{"name": name, "elapsed_seconds": 1, "exit_code": 0} for name in ("warm-up", "flows")],
                        "flows": [{"id": flow["id"], "selector": flow["selector"], "outcome": "passed",
                                   "elapsed_seconds": 1, "executed": True, "official_execution_complete": True,
                                   "failure_category": None,
                                   "first_failure_message": None}
                                  for flow in shadow.group_flows(scheduling, group["id"])]})
    return records


def runner_evidence(directory, *, failed=False, message=None):
    flow = manifest()["flows"][0]
    result = {"id": flow["id"], "selector": flow["selector"], "outcome": "FAIL" if failed else "PASS",
              "source_sha": HEAD, "source_dirty_paths": [],
              "failure_kind": "test" if failed else "none", "official_execution_complete": True,
              "exit_code": 65 if failed else 0, "elapsed_seconds": 1, "total_elapsed_seconds": 2,
              "first_public_failure_message": message}
    node = {"nodeType": "Test Case", "nodeIdentifier": flow["selector"] + "()", "result": "Failed" if failed else "Passed"}
    if failed and message:
        from ci_failure_diagnostics import failure_messages_diagnostics
        node.update(failure_messages=[message], **failure_messages_diagnostics([message]))
    tests = {"testNodes": [{"nodeType": "Unit test bundle", "name": "immichSlidesUITests", "children": [node]}]}
    summary = {"totalTestCount": 1, "passedTests": 0 if failed else 1, "failedTests": 1 if failed else 0,
               "skippedTests": 0, "result": "Failed" if failed else "Passed"}
    source = {"source_sha": HEAD, "source_dirty_paths": [], "suite": "smoke-flow", "platform": "ios", "configuration": "Debug",
              "destination": "platform=iOS Simulator,id=synthetic", "result": "FAILED" if failed else "Passed",
              "selection": "group"}
    directory.mkdir(exist_ok=True)
    child = directory / flow["id"]
    child.mkdir(exist_ok=True)
    exported = json.dumps(tests).encode()
    digest = hashlib.sha256(exported).hexdigest()
    result.update(official_summary=summary, official_tests_sha256=digest, request_logs={"a": {"state": "unavailable",
                  "bytes": None, "sha256": None, "request_count": None}})
    shadow.write_json(directory / "smoke-flow-results.json", dict(source, schema_version=1, device="iphone",
                                                                 exit_code=result["exit_code"], flows=[result]))
    shadow.write_json(directory / "case-manifest.json", dict(source, device="iphone", flows=[result], exit_code=result["exit_code"],
                                                            official_tests_sha256=digest))
    shadow.write_json(child / "case-manifest.json", dict(source, flow=result, exit_code=result["exit_code"],
                                                        official_summary=summary, official_tests_sha256=digest))
    shadow.write_json(child / "official-summary.json", summary)
    (directory / "official-tests.json").write_bytes(exported)
    (child / "official-tests.json").write_bytes(exported)
    return flow, source["destination"]


def replace_runner_record(directory, result):
    for path, field in [(directory / "smoke-flow-results.json", "flows"),
                        (directory / "case-manifest.json", "flows"),
                        (directory / result["id"] / "case-manifest.json", "flow")]:
        record = json.loads(path.read_text())
        record[field] = [result] if field == "flows" else result
        shadow.write_json(path, record)


def plan_fixture(temporary, stack, *, ancestor=0):
    event = temporary / "event.json"
    shadow.write_json(event, {"workflow_run": nightly()})
    context = dict(environment(), GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(temporary / "output"))
    api = SimpleNamespace(repository=REPOSITORY, pages=Mock(return_value=[]), repo=Mock(side_effect=lambda path:
        nightly() if path == "actions/runs/100" else {"id": 7, "path": shadow.NIGHTLY}))
    stack.enter_context(patch("ci_publish.GitHub", return_value=api))
    stack.enter_context(patch("ci_nightly_change.run_evidence", return_value="real"))
    stack.enter_context(patch.object(shadow, "paired_nightly_aggregate", return_value={"availability": "unavailable"}))
    stack.enter_context(patch.object(shadow.subprocess, "call", return_value=ancestor))
    reader = stack.enter_context(patch.object(shadow, "manifest_at_head", return_value=(manifest(), "c" * 64)))
    return context, api, reader


class SmokeShadowTests(unittest.TestCase):
    def test_admission_refuses_untrusted_or_unfinished_nightly_and_non_main_dispatch(self):
        run = nightly()
        payload = {"workflow_run": run}
        workflow = {"id": 7, "path": run["path"]}
        self.assertEqual(shadow.admit(environment(), payload, run, workflow), HEAD)
        cases = [
            ("repository", {"full_name": "other/repo"}, "nightly source"),
            ("head_repository", None, "nightly source"),
            ("head_repository", {"full_name": "other/repo"}, "nightly source"),
            ("head_branch", "topic", "nightly source"),
            ("event", "pull_request", "nightly source"),
            ("path", ".github/workflows/other.yml", "nightly workflow"),
            ("workflow_id", 8, "nightly workflow"),
            ("status", "in_progress", "nightly must be completed"),
            ("head_sha", "invalid", "40-digit hash"),
            ("run_attempt", 2, "completion event differs"),
        ]
        for key, value, message in cases:
            with self.subTest(key=key, value=value):
                changed = dict(run, **{key: value})
                with self.assertRaisesRegex(ContractError, message):
                    shadow.admit(environment(), payload, changed, workflow)
        for change, message in [({"GITHUB_REF": "refs/heads/topic"}, "main-only"),
                                ({"GITHUB_EVENT_NAME": "push"}, "main-only"),
                                ({"GITHUB_RUN_ATTEMPT": "2"}, "first attempt"),
                                ({"SMOKE_NIGHTLY_RUN_ID": "bad"}, "nightly run ID")]:
            with self.subTest(change=change), self.assertRaisesRegex(ContractError, message):
                shadow.admit(dict(environment("workflow_dispatch"), **change), {}, run, workflow)
        from ci_nightly_change import FULL_MANUAL_TITLE
        full = dict(run, event="workflow_dispatch", display_title=FULL_MANUAL_TITLE)
        self.assertEqual(shadow.admit(environment(), {"workflow_run": full}, full, workflow), HEAD)
        for diagnostic in ("probe_environment_refusal", "shard", "ui_only", "strict_only", "live_only", "unknown"):
            with self.subTest(diagnostic=diagnostic):
                diagnostic_run = dict(full, display_title="ci-nightly diagnostic", inputs={diagnostic: True})
                with self.assertRaisesRegex(ContractError, "full scheduled or manual nightly"):
                    shadow.admit(environment(), {"workflow_run": diagnostic_run}, diagnostic_run, workflow)
        with self.assertRaisesRegex(ContractError, "full scheduled or manual nightly"):
            shadow.admit(environment("workflow_dispatch"), {}, dict(full, display_title=None), workflow)

    def test_groups_follow_manifest_and_manual_skip_still_executes(self):
        scheduling = plan()
        self.assertEqual({item["id"] for item in scheduling["groups"]}, {"iphone-debug", "tv-release"})
        self.assertEqual([flow["id"] for flow in shadow.group_flows(scheduling, "tv-release")], ["tv-one"])
        skipped = shadow.make_plan(environment(), nightly(), manifest(), "c" * 64, "skipped")
        self.assertFalse(skipped["execute"])
        manual = shadow.make_plan(environment("workflow_dispatch"), nightly(), manifest(), "c" * 64, "skipped")
        self.assertTrue(manual["execute"])
        with self.assertRaisesRegex(ContractError, "unknown smoke group"):
            shadow.group_flows(scheduling, "other")

    def test_plan_binding_rejects_foreign_attempt_head_and_manifest(self):
        scheduling = plan()
        shadow.validate_plan(scheduling, environment())
        for field, value in [("shadow", dict(scheduling["shadow"], id="201")),
                             ("repository", "other/repo")]:
            with self.subTest(field=field), self.assertRaisesRegex(ContractError, "shadow plan context"):
                shadow.validate_plan(dict(scheduling, **{field: value}), environment())
        with self.assertRaisesRegex(ContractError, "tested checkout"):
            shadow.validate_plan(scheduling, environment(), checkout_sha="d" * 40, manifest_hash="c" * 64)
        with self.assertRaisesRegex(ContractError, "manifest binding"):
            shadow.validate_plan(scheduling, environment(), checkout_sha=HEAD, manifest_hash="d" * 64)
        with self.assertRaisesRegex(ContractError, "manifest population"):
            shadow.validate_plan(dict(scheduling, flows=[]), environment(), manifest=manifest())

    def test_aggregate_preserves_red_first_result_and_escapes_public_markdown(self):
        scheduling = plan()
        records = group_records(scheduling)
        passing = shadow.aggregate(scheduling, records, "success")
        self.assertEqual((passing["outcome"], passing["executed"], passing["comparison_eligible"]),
                         ("passed", True, True))
        records[0]["runner_exit_code"] = 65
        records[0]["flows"][0].update(outcome="failed", failure_category="assertion",
                                      first_failure_message="smoke: expected | actual\n<script>")
        result = shadow.aggregate(scheduling, records, "failure")
        self.assertEqual(result["outcome"], "failed")
        self.assertTrue(result["executed"])
        self.assertTrue(result["comparison_eligible"])
        self.assertEqual(result["flows"][0]["first_failure_message"], "smoke: expected | actual\n<script>")
        markdown = shadow.markdown(result)
        self.assertIn("expected &#124; actual", markdown)
        self.assertNotIn("<script>", markdown)
        self.assertIn("100", markdown)
        records[0]["flows"][0]["failure_category"] = "xctest-tool"
        self.assertEqual(shadow.aggregate(scheduling, records, "failure")["outcome"], "failed")

    def test_aggregate_fails_closed_for_missing_duplicate_foreign_or_invalid_results(self):
        scheduling = plan()
        records = group_records(scheduling)
        missing = shadow.aggregate(scheduling, records[:1], "failure")
        self.assertEqual(missing["outcome"], "failed")
        self.assertFalse(missing["executed"])
        self.assertEqual(missing["flows"][1]["outcome"], "not-run")
        cases = [
            (lambda rows: rows.append(copy.deepcopy(rows[0])), "duplicate group"),
            (lambda rows: rows[0].update(head_sha="d" * 40), "group provenance"),
            (lambda rows: rows[0].update(shadow=dict(scheduling["shadow"], attempt=2)), "group provenance"),
            (lambda rows: rows[0].update(manifest_sha256="d" * 64), "group provenance"),
            (lambda rows: rows[0]["group"].update(id="other"), "unknown group"),
            (lambda rows: rows[0].update(selection="single-flow"), "group selection is not complete"),
            (lambda rows: rows[0]["flows"].append(copy.deepcopy(rows[0]["flows"][0])), "flow population"),
            (lambda rows: rows[0]["flows"][0].update(selector="Smoke/testOther"), "flow population"),
            (lambda rows: rows[0]["flows"][0].update(outcome="flaky-passed"), "raw outcome"),
            (lambda rows: rows[0]["flows"][0].update(elapsed_seconds=float("nan")), "flow duration"),
            (lambda rows: rows[0]["flows"][0].update(executed=False), "passing flow was not executed"),
            (lambda rows: rows[0]["flows"][0].update(official_execution_complete=False), "official execution completeness differs"),
            (lambda rows: rows[0]["flows"][0].update(outcome="skipped"), "non-executed outcome"),
            (lambda rows: rows[0]["flows"][0].update(failure_category="yellow"), "invalid public failure"),
            (lambda rows: rows[0]["flows"][0].update(first_failure_message=123), "invalid public failure"),
            (lambda rows: rows[0]["flows"][0].update(failure_locations=[{"path": "/private/source.swift", "line": 3}]),
             "invalid public failure locations"),
            (lambda rows: rows[0].update(group=None), "invalid group record"),
            (lambda rows: rows[0].update(runner_exit_code=1), "runner failed"),
            (lambda rows: rows[0].update(errors=["official-results-missing"]), "official-results-missing"),
            (lambda rows: rows[0].update(group_validation=None), "invalid group validation"),
            (lambda rows: rows[0].update(group_validation={"outcome": "failed", "reason": "rejected"}),
             "runner group validation rejected"),
            (lambda rows: rows[0].update(job_started_epoch=None), "invalid group job timing"),
            (lambda rows: rows[0].update(job_elapsed_seconds=float("nan")), "invalid group job timing"),
            (lambda rows: rows[0].update(phases=[]), "invalid group job timing"),
            (lambda rows: rows[0]["phases"][0].update(elapsed_seconds=-1), "invalid group job timing"),
            (lambda rows: rows[0]["phases"][0].update(name="untrusted"), "invalid group job timing"),
        ]
        for mutate, message in cases:
            with self.subTest(message=message):
                changed = copy.deepcopy(records)
                mutate(changed)
                result = shadow.aggregate(scheduling, changed, "success")
                self.assertEqual(result["outcome"], "failed")
                self.assertTrue(any(message in item for item in result["errors"]), result["errors"])
                self.assertFalse(result["comparison_eligible"])
        failed_job = shadow.aggregate(scheduling, records, "failure")
        self.assertEqual(failed_job["outcome"], "failed")
        self.assertFalse(failed_job["comparison_eligible"])

    def test_shadow_count_uses_new_first_execution_and_keeps_old_yellow_and_infra(self):
        for status, errors in [("environment-limited", []), ("failed", ["producer infrastructure failure"])]:
            with self.subTest(old_status=status):
                old = {"status": status, "environment_limited": [{"raw": "unchanged"}], "errors": errors}
                scheduling = shadow.make_plan(environment(), nightly(), manifest(), "c" * 64, "unverified", old)
                result = shadow.aggregate(scheduling, group_records(scheduling), "success")
                self.assertTrue(result["comparison_eligible"])
                self.assertEqual(result["nightly"]["aggregate"], old)
                missing = shadow.aggregate(scheduling, group_records(scheduling)[:1], "failure")
                self.assertFalse(missing["comparison_eligible"])
                cancelled_records = group_records(scheduling)
                cancelled_records[0]["flows"][0]["outcome"] = "failed"
                cancelled_records[0]["runner_exit_code"] = 65
                cancelled = shadow.aggregate(scheduling, cancelled_records, "cancelled")
                self.assertFalse(cancelled["comparison_eligible"])
        for field, value in [("head_sha", "d" * 40), ("status", "in_progress")]:
            with self.subTest(pair_field=field):
                scheduling = plan()
                scheduling["nightly"][field] = value
                self.assertFalse(shadow.aggregate(scheduling, group_records(scheduling), "success")["comparison_eligible"])
        scheduling = plan()
        scheduling["shadow"]["attempt"] = 2
        self.assertFalse(shadow.aggregate(scheduling, group_records(scheduling), "success")["comparison_eligible"])
        scheduling = shadow.make_plan(environment(), nightly(), manifest(), "c" * 64, "skipped")
        result = shadow.aggregate(scheduling, [], "skipped")
        self.assertEqual(result["outcome"], "not-run")
        self.assertFalse(result["executed"])
        self.assertFalse(result["comparison_eligible"])
        cancelled = plan()
        cancelled["nightly"]["conclusion"] = "cancelled"
        self.assertFalse(shadow.aggregate(cancelled, group_records(cancelled), "success")["comparison_eligible"])
        automatic = shadow.aggregate(plan(), group_records(plan()), "success")
        repeated = plan()
        repeated["shadow"]["id"] = "201"
        repeated["shadow"]["event"] = "workflow_dispatch"
        manual_result = shadow.aggregate(repeated, group_records(repeated), "success")
        self.assertEqual(automatic["nightly_run_id"], manual_result["nightly_run_id"])
        other_nightly = plan()
        other_nightly["nightly"]["id"] = "101"
        self.assertNotEqual(automatic["nightly_run_id"], shadow.aggregate(
            other_nightly, group_records(other_nightly), "success")["nightly_run_id"])
        manual = shadow.make_plan(environment("workflow_dispatch"), nightly(), manifest(), "c" * 64, "skipped")
        result = shadow.aggregate(manual, group_records(manual), "success")
        self.assertEqual(result["outcome"], "passed")
        self.assertTrue(result["executed"])
        self.assertFalse(result["comparison_eligible"])

    def test_plan_ancestor_guard_rejects_before_loading_manifest(self):
        with tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
            context, _api, reader = plan_fixture(Path(raw), stack, ancestor=1)
            with self.assertRaisesRegex(ContractError, "not an ancestor of main"):
                shadow.plan_run(context, Path(raw) / "plan")
            reader.assert_not_called()

    def test_plan_blocks_active_main_nightlies_and_scans_the_non_counting_record(self):
        from ci_nightly_change import ACTIVE_RUN_STATUSES
        for status in (*sorted(ACTIVE_RUN_STATUSES), None):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as raw:
                temporary = Path(raw)
                with ExitStack() as stack:
                    context, api, _reader = plan_fixture(temporary, stack)
                    active = dict(nightly(), id=101, status=status)
                    api.pages.side_effect = lambda _path, _collection, **filters: [active] if filters["status"] == status else []
                    self.assertEqual(shadow.plan_run(context, temporary / "plan"), 0)
                scheduling = json.loads((temporary / "plan/plan.json").read_text())
                self.assertEqual(scheduling["execute"], status is None)
                self.assertTrue("execute=" + str(status is None).lower() in (temporary / "output").read_text(),
                                "planner output matches its execution decision")
                self.assertTrue((temporary / "plan/sensitive-scan.json").is_file())
                self.assertIn("records_safe=true", (temporary / "output").read_text())
                if status:
                    self.assertEqual(scheduling["blocked_by_active_nightly"], ["101"])
                    result = shadow.aggregate(scheduling, [], "skipped")
                    self.assertEqual((result["outcome"], result["comparison_eligible"]), ("not-run", False))
                    self.assertIn("nightly is active", result["flows"][0]["first_failure_message"])
        with tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
            context, api, _reader = plan_fixture(Path(raw), stack)
            api.pages.side_effect = lambda _path, _collection, **filters: [dict(nightly(), status=filters["status"], head_branch="topic")]
            with self.assertRaisesRegex(ContractError, "active nightly listing differs"):
                shadow.plan_run(context, Path(raw) / "plan")

    def test_plan_never_executes_nightlies_without_a_real_result_conclusion(self):
        for conclusion in ("cancelled", "timed_out", "startup_failure", "neutral"):
            for event in ("workflow_run", "workflow_dispatch"):
                with self.subTest(conclusion=conclusion, event=event), tempfile.TemporaryDirectory() as raw:
                    temporary = Path(raw)
                    with ExitStack() as stack:
                        context, api, _reader = plan_fixture(temporary, stack)
                        context["GITHUB_EVENT_NAME"] = event
                        run = dict(nightly(), conclusion=conclusion)
                        api.repo.side_effect = lambda path: run if path == "actions/runs/100" else {"id": 7, "path": shadow.NIGHTLY}
                        self.assertEqual(shadow.plan_run(context, temporary / "plan"), 0)
                    scheduling = json.loads((temporary / "plan/plan.json").read_text())
                    self.assertFalse(scheduling["execute"])
                    self.assertTrue("execute=false" in (temporary / "output").read_text(), "planner publishes execute=false")
                    self.assertIn("not success/failure", scheduling["not_run_reason"])
                    result = shadow.aggregate(scheduling, [], "skipped")
                    self.assertEqual((result["outcome"], result["comparison_eligible"]), ("not-run", False))

    def test_plan_scan_failure_never_publishes_safe_outputs(self):
        with tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
            context, _api, _reader = plan_fixture(Path(raw), stack)
            with patch("run_strict_e2e.write_sensitive_scan", side_effect=ValueError("synthetic scan refusal")):
                with self.assertRaisesRegex(ValueError, "synthetic scan refusal"):
                    shadow.plan_run(context, Path(raw) / "plan")
            self.assertFalse((Path(raw) / "output").exists())

    def test_skipped_plan_rejects_artifacts_and_failed_matrix(self):
        scheduling = shadow.make_plan(environment(), nightly(), manifest(), "c" * 64, "skipped")
        for records, matrix in ((group_records(scheduling), "skipped"), ([], "failure")):
            with self.subTest(matrix=matrix, records=bool(records)):
                result = shadow.aggregate(scheduling, records, matrix)
                self.assertIn("unexpected execution on skipped nightly", result["errors"])
                self.assertEqual((result["outcome"], result["comparison_eligible"]), ("failed", False))

    def test_group_refuses_suppressed_plan_before_creating_simulator(self):
        scheduling = shadow.make_plan(environment(), nightly(), manifest(), "c" * 64, "skipped")
        with tempfile.TemporaryDirectory() as raw, patch.object(shadow, "git", return_value=HEAD), \
                patch("ci_build_archive.file_hash", return_value="c" * 64), \
                patch.object(shadow, "job_started_epoch", return_value=time.time()), \
                patch("ci_build_archive.workspace_preflight"), patch("run_offline_unit_tests.ensure_disk_for_xcodebuild"), \
                patch("ci_simulator.create_and_boot_simulator") as create:
            with self.assertRaisesRegex(ContractError, "cannot execute a smoke group"):
                shadow.run_group(scheduling, dict(environment(), SMOKE_GROUP="iphone-debug"), Path(raw))
            create.assert_not_called()

    def test_cleanup_never_disposes_foreign_or_unverified_inputs(self):
        with tempfile.TemporaryDirectory() as raw:
            temporary = Path(raw)
            root = temporary / "smoke-execution"
            root.mkdir()
            marker = temporary / "smoke-cleanup-blocked"
            marker.touch()
            with self.assertRaisesRegex(ContractError, "runner cleanup unverified"):
                shadow.cleanup(environment(), temporary)
            marker.unlink()
            shadow.write_json(root / "ownership.json", dict(shadow.shadow_context(environment()), id="other"))
            with patch.object(shadow.subprocess, "run") as run:
                with self.assertRaisesRegex(ContractError, "cleanup ownership differs"):
                    shadow.cleanup(dict(environment(), UI_SIMULATOR="foreign"), temporary)
                run.assert_not_called()
            shadow.write_json(root / "ownership.json", shadow.shadow_context(environment()))
            for code, stdout, stderr in ((0, b"", b""), (1, b"p1", b""), (1, b"", b"unavailable")):
                with self.subTest(code=code, stdout=stdout, stderr=stderr), patch.object(shadow.subprocess, "run",
                        return_value=SimpleNamespace(returncode=code, stdout=stdout, stderr=stderr)):
                    with self.assertRaisesRegex(ContractError, "owned build inputs still open"):
                        shadow.cleanup(environment(), temporary)
                    self.assertTrue(root.is_dir())
            with patch.object(shadow.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout=b"", stderr=b"")):
                self.assertEqual(shadow.cleanup(environment(), temporary), 0)
            self.assertFalse(root.exists())

    def test_job_clock_binds_deadline_to_current_attempt_and_group(self):
        job = {"id": 1, "run_id": 200, "run_attempt": 1, "name": "smoke-shadow-iphone-debug",
               "started_at": "1970-01-01T00:16:40Z"}
        api = SimpleNamespace(repo=Mock(return_value={"total_count": 1, "jobs": [job]}))
        with patch("ci_publish.GitHub", return_value=api), patch.object(shadow.time, "time", return_value=1100):
            self.assertEqual(shadow.job_started_epoch(environment(), "iphone-debug"), 1000)
            for change, message in [({"name": "foreign-job"}, "job start is unavailable"),
                                    ({"started_at": "invalid"}, "job start timestamp differs"),
                                    ({"started_at": "1970-01-01T00:16:40"}, "job start timestamp differs"),
                                    ({"started_at": "1970-01-01T00:20:00Z"}, "job start timestamp differs"),
                                    ({"run_attempt": 2}, "unexpected attempt job")]:
                api.repo.return_value = {"total_count": 1, "jobs": [dict(job, **change)]}
                with self.subTest(change=change), self.assertRaisesRegex(ContractError, message):
                    shadow.job_started_epoch(environment(), "iphone-debug")
            with self.assertRaisesRegex(ContractError, "job clock context differs"):
                shadow.job_started_epoch(dict(environment(), GITHUB_RUN_ID="0"), "iphone-debug")

    def test_group_setup_time_consumes_the_unchanged_budget(self):
        scheduling = plan()
        with tempfile.TemporaryDirectory() as raw, patch.object(shadow, "git", return_value=HEAD), \
                patch("ci_build_archive.file_hash", return_value="c" * 64), \
                patch("ci_build_archive.workspace_preflight"), patch("run_offline_unit_tests.ensure_disk_for_xcodebuild"), \
                patch("ci_simulator.create_and_boot_simulator", return_value="synthetic"), \
                patch.object(shadow, "job_started_epoch", return_value=time.time() - shadow.GROUP_BUDGET_SECONDS - 1, create=True), \
                patch("run_strict_ci_tracer.run_runner", return_value=0) as runner:
            self.assertEqual(shadow.run_group(scheduling, dict(environment(), SMOKE_GROUP="iphone-debug"), Path(raw)), 1)
            runner.assert_not_called()
            record = json.loads((Path(raw) / "smoke-records/group.json").read_text())
            self.assertEqual(record["runner_exit_code"], 124)
            self.assertIn("group-budget-exhausted", record["errors"])

    def test_group_removes_its_api_token_before_any_tested_runner_can_inherit_it(self):
        from ci_build_archive import file_hash
        for clock_failure in (False, True):
            with self.subTest(clock_failure=clock_failure), tempfile.TemporaryDirectory() as raw:
                temporary = Path(raw)
                context = dict(environment(), SMOKE_GROUP="iphone-debug", SMOKE_TOKEN="synthetic-shadow-token")

                def clock(environment, _group):
                    self.assertTrue(environment.get("SMOKE_TOKEN") == "synthetic-shadow-token", "clock receives the synthetic token")
                    if clock_failure:
                        raise ValueError("synthetic clock unavailable")
                    return time.time()

                def invoke(command, *_args, **_kwargs):
                    self.assertFalse("SMOKE_TOKEN" in os.environ, "runner environment excludes the clock token")
                    self.assertFalse("SMOKE_TOKEN" in context, "control context excludes the clock token")
                    if "--test-without-building" in command:
                        runner_evidence(Path(command[command.index("--evidence-dir") + 1]))
                    return 0

                def bound_hash(path):
                    return "c" * 64 if path == shadow.ROOT / shadow.MANIFEST else file_hash(path)

                with patch.dict(os.environ, {"SMOKE_TOKEN": "synthetic-shadow-token"}), \
                        patch.object(shadow, "git", return_value=HEAD), patch("ci_build_archive.file_hash", side_effect=bound_hash), \
                        patch.object(shadow, "job_started_epoch", side_effect=clock), patch("ci_build_archive.workspace_preflight"), \
                        patch("run_offline_unit_tests.ensure_disk_for_xcodebuild"), \
                        patch("ci_simulator.create_and_boot_simulator", return_value="synthetic"), \
                        patch("run_strict_ci_tracer.run_runner", side_effect=invoke) as runner:
                    self.assertEqual(shadow.run_group(plan(), context, temporary), int(clock_failure))
                    self.assertFalse("SMOKE_TOKEN" in os.environ, "runner environment excludes the clock token")
                    self.assertFalse("SMOKE_TOKEN" in context, "control context excludes the clock token")
                    if clock_failure:
                        runner.assert_not_called()

    def test_paired_nightly_preserves_raw_verdict_only_for_matching_run_and_sha(self):
        run = nightly()
        api = SimpleNamespace(repository=REPOSITORY, pages=lambda *_: [
            {"name": "nightly-aggregate-100-1", "expired": False, "id": 1}])
        old = {"run": {"id": "100", "attempt": 1}, "identity": {"repository": REPOSITORY, "commit_sha": HEAD},
               "status": "environment-limited", "environment_limited": [{"raw": "unchanged"}],
               "errors": ["original infrastructure error"], "matrix": {"equal": False}, "tiers": {"ui": "failed"}}
        with patch("ci_publish.json_member", return_value=old):
            record = shadow.paired_nightly_aggregate(api, run)
        self.assertEqual(record, {"availability": "present", **{key: old[key] for key in
                         ("status", "environment_limited", "errors", "matrix", "tiers")}})
        for field, value in [("run", {"id": "100", "attempt": 2}),
                             ("identity", None),
                             ("identity", {"repository": REPOSITORY, "commit_sha": "d" * 40})]:
            with self.subTest(field=field), patch("ci_publish.json_member", return_value=dict(old, **{field: value})):
                with self.assertRaisesRegex(ContractError, "paired nightly aggregate source differs"):
                    shadow.paired_nightly_aggregate(api, run)
        with patch("ci_publish.json_member", return_value=None):
            with self.assertRaisesRegex(ContractError, "paired nightly aggregate source differs"):
                shadow.paired_nightly_aggregate(api, run)
        missing_api = SimpleNamespace(repository=REPOSITORY, pages=lambda *_: [])
        self.assertEqual(shadow.paired_nightly_aggregate(missing_api, run), {"availability": "unavailable"})

    def test_runner_adapter_requires_source_bound_official_results_before_claiming_execution(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            flow, destination = runner_evidence(directory)
            rows, errors = shadow.read_runner_flows(directory, plan(), [flow], destination)
            self.assertEqual(errors, [])
            self.assertEqual((rows[0]["outcome"], rows[0]["executed"]), ("passed", True))
            root_case = json.loads((directory / "case-manifest.json").read_text())
            shadow.write_json(directory / "case-manifest.json", dict(root_case, source_sha="d" * 40))
            with self.assertRaisesRegex(ContractError, "smoke runner source binding differs"):
                shadow.read_runner_flows(directory, plan(), [flow], destination)
            for filename, field, value, message in [
                    ("case-manifest.json", "selection", "single-flow", "selection is not a complete group"),
                    ("smoke-flow-results.json", "selection", "single-flow", "selection is not a complete group"),
                    ("smoke-flow-results.json", "source_sha", "d" * 40, "first-result source binding differs"),
                    ("case-manifest.json", "source_dirty_paths", ["changed.swift"], "source state or group differs"),
                    ("smoke-flow-results.json", "source_dirty_paths", ["changed.swift"], "source state or group differs"),
                    ("smoke-flow-results.json", "device", "ipad", "source state or group differs"),
                    ("smoke-flow-results.json", "configuration", "Release", "source state or group differs")]:
                with self.subTest(filename=filename, field=field):
                    runner_evidence(directory)
                    path = directory / filename
                    changed = json.loads(path.read_text())
                    shadow.write_json(path, dict(changed, **{field: value}))
                    with self.assertRaisesRegex(ContractError, message):
                        shadow.read_runner_flows(directory, plan(), [flow], destination)
            for field, value, message in [("source_sha", "d" * 40, "flow source differs"),
                                          ("source_dirty_paths", ["changed.swift"], "flow source differs"),
                                          ("failure_kind", "cleanup", "flow metadata differs")]:
                with self.subTest(record_field=field):
                    runner_evidence(directory)
                    changed = json.loads((directory / "smoke-flow-results.json").read_text())["flows"][0]
                    replace_runner_record(directory, dict(changed, **{field: value}))
                    with self.assertRaisesRegex(ContractError, message):
                        shadow.read_runner_flows(directory, plan(), [flow], destination)
            runner_evidence(directory)
            changed = json.loads((directory / "smoke-flow-results.json").read_text())["flows"][0]
            replace_runner_record(directory, dict(changed, official_execution_complete=False))
            rows, errors = shadow.read_runner_flows(directory, plan(), [flow], destination)
            self.assertEqual((rows[0]["outcome"], rows[0]["executed"]), ("failed", False))
            self.assertEqual(errors, ["flow-official-evidence-invalid: phone-one: flow official execution incomplete"])
            for key, value, reason in [("result", "RUNNING", "runner-group-finalization-incomplete"),
                                       ("result", "FAILED", "runner-group-verdict-mismatch"),
                                       ("official_tests_sha256", "d" * 64, "runner-group-official-hash-mismatch")]:
                with self.subTest(root=key, value=value):
                    runner_evidence(directory)
                    case_path = directory / "case-manifest.json"
                    case = json.loads(case_path.read_text())
                    shadow.write_json(case_path, dict(case, **{key: value}))
                    rows, errors = shadow.read_runner_flows(directory, plan(), [flow], destination)
                    self.assertEqual(errors, [reason])
            cases = [("case-manifest.json", "source_sha", "d" * 40, "flow source binding differs"),
                     ("case-manifest.json", "official_tests_sha256", "d" * 64, "flow official hash differs"),
                     ("official-summary.json", "passedTests", 2, "official counts do not add up"),
                     ("official-tests.json", "testNodes", [], "flow official identity differs")]
            for filename, key, value, reason in cases:
                with self.subTest(filename=filename, key=key):
                    runner_evidence(directory)
                    path = directory / flow["id"] / filename
                    changed = json.loads(path.read_text())
                    changed[key] = value
                    shadow.write_json(path, changed)
                    if filename == "official-tests.json":
                        case_path = directory / flow["id"] / "case-manifest.json"
                        case = json.loads(case_path.read_text())
                        # Keep the hash binding valid so this negative reaches the identity rule.
                        case["official_tests_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                        shadow.write_json(case_path, case)
                        changed_result = dict(case["flow"], official_tests_sha256=case["official_tests_sha256"])
                        replace_runner_record(directory, changed_result)
                    rows, errors = shadow.read_runner_flows(directory, plan(), [flow], destination)
                    self.assertEqual((rows[0]["outcome"], rows[0]["executed"]), ("failed", False))
                    self.assertEqual(errors, ["flow-official-evidence-invalid: phone-one: " + reason])
            runner_evidence(directory)
            with self.assertRaisesRegex(ContractError, "ordered flow population differs"):
                shadow.read_runner_flows(directory, plan(), [dict(flow, id="different")], destination)

    def test_runner_adapter_classifies_official_failures_without_promoting_tool_failures(self):
        cases = [("Failed to get matching snapshots: Timed out while evaluating UI query", "xctest-tool"),
                 ("First-boot form must show the API Key field.", "assertion")]
        for message, category in cases:
            with self.subTest(category=category), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                flow, destination = runner_evidence(directory, failed=True, message=message)
                rows, errors = shadow.read_runner_flows(directory, plan(), [flow], destination)
                self.assertEqual(errors, [])
                self.assertEqual((rows[0]["outcome"], rows[0]["executed"], rows[0]["failure_category"]),
                                 ("failed", True, category))
                self.assertEqual(rows[0]["first_failure_message"], message)

    def test_runner_adapter_obeys_shared_group_validator_and_records_its_rejection(self):
        from strict_e2e_smoke import validate_group_evidence
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            flow, destination = runner_evidence(directory)
            verdict = {}
            with patch("strict_e2e_smoke.validate_group_evidence", wraps=validate_group_evidence) as validate:
                rows, errors = shadow.read_runner_flows(directory, plan(), [flow], destination, validation=verdict)
            validate.assert_called_once_with(directory, plan()["flows"], "iphone", "Debug", expected_source_sha=HEAD)
            self.assertEqual((errors, verdict), ([], {"outcome": "passed", "reason": None, "group_failures": []}))
            with patch("strict_e2e_smoke.validate_group_evidence", side_effect=ValueError(
                    "smoke-group-evidence: group verdict, selection, source state or device differs")):
                rows, errors = shadow.read_runner_flows(directory, plan(), [flow], destination, validation=verdict)
            self.assertEqual(verdict["outcome"], "failed")
            self.assertEqual(errors, ["runner-group-validation-failed: " + verdict["reason"]])
            self.assertEqual(rows[0]["runner_outcome"], "PASS")
            failed_flow, destination = runner_evidence(directory, failed=True)
            rows, errors = shadow.read_runner_flows(directory, plan(), [failed_flow], destination, validation=verdict)
            self.assertEqual((errors, rows[0]["outcome"], verdict["outcome"]), ([], "failed", "failed"))

    def test_runner_adapter_keeps_late_gate_failures_red_and_source_locations_bounded(self):
        location = [{"path": "immichSlidesUITests/SmokeFlowIOSUITests.swift", "line": 42}]
        for gate in ("warm-products", "sensitive-scan", "build-cleanup", "evidence-finalization", "official-result"):
            with self.subTest(gate=gate), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                flow, destination = runner_evidence(directory)
                result = json.loads((directory / "smoke-flow-results.json").read_text())["flows"][0]
                result.update(outcome="FAIL", exit_code=2, failure_kind=gate, failure_locations=location)
                replace_runner_record(directory, result)
                for path in (directory / "case-manifest.json", directory / "smoke-flow-results.json",
                             directory / flow["id"] / "case-manifest.json"):
                    payload = json.loads(path.read_text())
                    shadow.write_json(path, dict(payload, result="FAILED", exit_code=2))
                gates = [{"failure_kind": gate, "exit_code": 2, "flow_ids": [flow["id"]]}]
                for path in (directory / "case-manifest.json", directory / "smoke-flow-results.json"):
                    shadow.write_json(path, dict(json.loads(path.read_text()), group_failures=gates))
                verdict = {}
                rows, errors = shadow.read_runner_flows(directory, plan(), [flow], destination, validation=verdict)
                self.assertEqual(errors, [])
                self.assertEqual((rows[0]["outcome"], rows[0]["failure_kind"], verdict["outcome"]), ("failed", gate, "failed"))
                self.assertTrue(rows[0]["executed"])
                self.assertEqual(rows[0]["official_summary"]["result"], "Passed")
                self.assertEqual((rows[0]["source_sha"], rows[0]["failure_locations"]), (HEAD, location))
                self.assertEqual(verdict["group_failures"], gates)
                result["failure_locations"] = [{"path": "/private/source.swift", "line": 42}]
                replace_runner_record(directory, result)
                with self.assertRaisesRegex(ContractError, "smoke runner public failure locations differ"):
                    shadow.read_runner_flows(directory, plan(), [flow], destination)
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            flow, destination = runner_evidence(directory, failed=True)
            gate = {"failure_kind": "sensitive-scan", "exit_code": 2, "flow_ids": [flow["id"]]}
            for path in (directory / "case-manifest.json", directory / "smoke-flow-results.json"):
                shadow.write_json(path, dict(json.loads(path.read_text()), group_failures=[gate], exit_code=2))
            verdict = {}
            rows, errors = shadow.read_runner_flows(directory, plan(), [flow], destination, validation=verdict)
            self.assertEqual((errors, rows[0]["exit_code"], rows[0]["failure_kind"]), ([], 65, "test"))
            self.assertEqual(verdict["group_failures"], [gate])
            for change in ({"failure_kind": "unknown"}, {"exit_code": 0}, {"flow_ids": ["foreign"]},
                           {"flow_ids": [flow["id"], flow["id"]]}):
                for path in (directory / "case-manifest.json", directory / "smoke-flow-results.json"):
                    shadow.write_json(path, dict(json.loads(path.read_text()), group_failures=[dict(gate, **change)]))
                with self.subTest(gate=change), self.assertRaisesRegex(ContractError, "group gate evidence differs"):
                    shadow.read_runner_flows(directory, plan(), [flow], destination)

    def test_group_timeout_preserves_completed_first_results_and_keeps_missing_flows_red(self):
        import subprocess
        from ci_build_archive import file_hash
        first = manifest()["flows"][0]
        second = dict(first, id="phone-two", selector="Smoke/testSecond")
        scheduling = shadow.make_plan(environment(), nightly(), {"schema_version": 1, "flows": [first, second]}, "c" * 64, "real")
        with tempfile.TemporaryDirectory() as raw:
            temporary = Path(raw)
            context = dict(environment(), SMOKE_GROUP="iphone-debug", GITHUB_OUTPUT=str(temporary / "output"))

            def invoke(command, *_args, **kwargs):
                if "--warm-up-only" in command:
                    return 0
                evidence = Path(command[command.index("--evidence-dir") + 1])
                runner_evidence(evidence)
                case = json.loads((evidence / "case-manifest.json").read_text())
                shadow.write_json(evidence / "case-manifest.json", dict(case, result="RUNNING"))
                (evidence / "official-tests.json").unlink()
                raise subprocess.TimeoutExpired(command, kwargs["timeout_seconds"])

            def bound_hash(path):
                return "c" * 64 if path == shadow.ROOT / shadow.MANIFEST else file_hash(path)

            with patch.object(shadow, "git", return_value=HEAD), \
                    patch.object(shadow, "job_started_epoch", return_value=time.time() - 60, create=True), \
                    patch("ci_build_archive.file_hash", side_effect=bound_hash), \
                    patch("ci_build_archive.workspace_preflight"), \
                    patch("run_offline_unit_tests.ensure_disk_for_xcodebuild"), \
                    patch("ci_simulator.create_and_boot_simulator", return_value="synthetic"), \
                    patch("run_strict_ci_tracer.run_runner", side_effect=invoke):
                self.assertEqual(shadow.run_group(scheduling, context, temporary), 1)
            record = json.loads((temporary / "smoke-records/group.json").read_text())
            self.assertEqual(record["runner_exit_code"], 124)
            self.assertIn("group-budget-exhausted", record["errors"])
            self.assertEqual([row["outcome"] for row in record["flows"]], ["passed", "not-run"])
            self.assertEqual([row["executed"] for row in record["flows"]], [True, False])
            self.assertIn("records_safe=true", (temporary / "output").read_text())
            self.assertEqual([phase["name"] for phase in record["phases"]], ["warm-up", "flows"])
            self.assertGreaterEqual(record["job_elapsed_seconds"], 60)
            result = shadow.aggregate(scheduling, [record], "failure")
            self.assertEqual(result["outcome"], "failed")
            self.assertFalse(result["comparison_eligible"])


if __name__ == "__main__":
    unittest.main()
