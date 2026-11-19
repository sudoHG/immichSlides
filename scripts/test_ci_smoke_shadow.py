"""Protect the shadow verdict and its source/run binding, without running Xcode."""

import copy
import hashlib
import io
import json
import os
import plistlib
import subprocess
import tempfile
import time
import tarfile
import unittest
from contextlib import ExitStack, redirect_stderr
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import ci_smoke_shadow as shadow
# Import before patching dependencies so the tracer cannot retain their mocks.
import strict_e2e_runner_support as tracer
import strict_e2e_build
from ci_summary import ContractError


HEAD = "a" * 40
REPOSITORY = "example/photos"


def environment(event="workflow_dispatch"):
    return {"GITHUB_EVENT_NAME": event, "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": REPOSITORY, "GITHUB_RUN_ID": "200", "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_SHA": HEAD, "SMOKE_SCOPE": "full"}


def run_metadata():
    return {"id": 100, "run_attempt": 1, "path": shadow.WORKFLOW, "workflow_id": 7,
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
    return shadow.make_plan(environment(), manifest(), "c" * 64)


def shared_plan():
    return dict(plan(), build_mode=shadow.ARCHIVE_MODE, tested_source={"head_sha": HEAD},
                control={"run_id": "200", "attempt": 1, "api_head_sha": "b" * 40})


def archive_provenance(scheduling):
    return {"configuration": "Debug", "artifact_id": 91, "manifest_sha256": "d" * 64,
            "archive_sha256": "e" * 64, "control": scheduling["control"],
            "source": scheduling["tested_source"], "producer_job": "smoke-shadow-ios-debug"}


def archive_api():
    job = {"name": "smoke-shadow-ios-debug", "run_attempt": 1, "conclusion": "success", "steps": [
        {"name": "Build the generic smoke configuration", "conclusion": "success"},
        {"name": "Publish the immutable configuration archive", "conclusion": None}]}
    metadata = {"id": 91, "name": "smoke-build-debug-200-1", "expired": False,
                "workflow_run": {"id": 200, "head_sha": "b" * 40}}
    return SimpleNamespace(repo=Mock(return_value=metadata)), job


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


def runner_evidence(directory, *, failed=False, message=None, first_failure=None):
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
    if first_failure is not None:
        node["first_failure"] = first_failure
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
    context = dict(environment(), GITHUB_OUTPUT=str(temporary / "output"))
    api = SimpleNamespace(repository=REPOSITORY, pages=Mock(return_value=[]))
    stack.enter_context(patch("ci_smoke_shadow.GitHub", return_value=api))
    stack.enter_context(patch.object(shadow.subprocess, "call", return_value=ancestor))
    reader = stack.enter_context(patch.object(shadow, "manifest_at_head", return_value=(manifest(), "c" * 64)))
    return context, api, reader


class SimulatorGroupFixture(ExitStack):
    """Keep real group control/ownership and fake only host and official-result boundaries."""

    def __init__(self, *, archive=True, group_id="iphone-debug", elapsed=0):
        super().__init__()
        self.archive, self.group_id, self.elapsed = archive, group_id, elapsed

    def __enter__(self):
        with ExitStack() as stack:
            archive, group_id, elapsed = self.archive, self.group_id, self.elapsed
            temporary = Path(stack.enter_context(tempfile.TemporaryDirectory()))
            scheduling = shared_plan() if archive else plan()
            context = dict(environment(), SMOKE_GROUP=group_id, GITHUB_ENV=str(temporary / "github-env"))
            clock = [1000.0]
            identity = {"source": scheduling.get("tested_source")}
            if archive:
                shadow.write_json(temporary / "smoke-archive-selection.json", {
                    "provenance": archive_provenance(scheduling), "identity": identity,
                    "transfer_started_epoch": clock[0]})
            stack.enter_context(patch.dict(os.environ, context))
            stack.enter_context(patch.object(shadow.time, "time", side_effect=lambda: clock[0]))
            stack.enter_context(patch.object(shadow, "git", return_value=HEAD))
            stack.enter_context(patch("ci_build_archive.file_hash", return_value="c" * 64))
            stack.enter_context(patch.object(shadow, "job_started_epoch", return_value=clock[0] - elapsed))
            stack.enter_context(patch("ci_build_archive.workspace_preflight"))
            stack.enter_context(patch("run_offline_unit_tests.ensure_disk_for_xcodebuild"))
            stack.enter_context(patch("strict_e2e_build.smoke_build_identity", return_value=identity))
            verify = stack.enter_context(patch.object(shadow, "verify_smoke_archive"))
            load = stack.enter_context(patch("strict_e2e_build.load_smoke_archive"))
            prepare = stack.enter_context(patch("strict_e2e_runner_support.prepare_simulator"))
            created = []
            def create(*_args):
                udid = "synthetic-" + str(len(created) + 1)
                created.append(udid)
                with open(context["GITHUB_ENV"], "a") as handle:
                    handle.write(f"UI_SIMULATOR={udid}\nUI_DESTINATION=platform=iOS Simulator,id={udid}\nUI_PLATFORM=ios\n")
                return udid
            simulator = stack.enter_context(patch("ci_simulator.create_and_boot_simulator", side_effect=create))
            retire = stack.enter_context(patch("strict_e2e_runner_support.simulator_command",
                                              return_value=SimpleNamespace(returncode=0)))
            def execute(command, *_args, **_options):
                if "--test-without-building" in command:
                    shadow.write_json(temporary / "smoke-execution.noindex/flows/case-manifest.json", {"selection": "group"})
                return 0
            runner = stack.enter_context(patch.object(tracer, "run_runner", side_effect=execute))
            def evidence(*_args, validation, **_options):
                validation.update(outcome="passed", reason=None)
                index = next(index for index, group in enumerate(scheduling["groups"]) if group["id"] == group_id)
                return group_records(scheduling)[index]["flows"], []
            stack.enter_context(patch.object(shadow, "read_runner_flows", side_effect=evidence))
            stack.enter_context(patch.object(shadow, "scan_records"))
            stack.enter_context(patch("ci_failure_diagnostics.validate_ui_first_failure_images"))
            log = stack.enter_context(redirect_stderr(io.StringIO()))
            fixture = SimpleNamespace(temporary=temporary, scheduling=scheduling, context=context, clock=clock,
                verify=verify, load=load, prepare=prepare, create=create, simulator=simulator, retire=retire,
                runner=runner, log=log,
                run=lambda: shadow.run_group(scheduling, context, temporary),
                record=lambda: json.loads((temporary / "smoke-records/group.json").read_text()))
            self.enter_context(stack.pop_all())
            return fixture


class SmokeReadOnlyAPITests(unittest.TestCase):
    def test_artifact_redirect_keeps_tokens_only_on_https_github(self):
        from urllib.request import Request
        redirect = shadow.ArtifactRedirect()
        request = Request("https://api.github.com/repos/example/photos", headers={"Authorization": "Bearer synthetic"})
        for target, authenticated in (("https://api.github.com/download", True), ("https://storage.example/download", False)):
            with self.subTest(target=target):
                redirected = redirect.redirect_request(request, None, 302, "Found", {}, target)
                self.assertEqual(redirected.has_header("Authorization"), authenticated)
        with self.assertRaisesRegex(ContractError, "HTTPS"):
            redirect.redirect_request(request, None, 302, "Found", {}, "http://storage.example/download")

    def test_smoke_client_refuses_writes_and_incomplete_attempt_jobs(self):
        api = shadow.GitHub(REPOSITORY, "synthetic")
        with patch.object(shadow, "build_opener") as network:
            with self.assertRaisesRegex(ContractError, "read-only"):
                api.repo("statuses/head", method="POST", payload={})
            network.assert_not_called()
        job = {"id": 1, "run_id": 200, "run_attempt": 1}
        for response in ({"total_count": 1, "jobs": []}, {"total_count": True, "jobs": [job]},
                         {"total_count": 2, "jobs": [job, job]},
                         {"total_count": 1, "jobs": [dict(job, run_attempt=2)]}):
            with self.subTest(response=response), self.assertRaises(ContractError):
                shadow.complete_attempt_jobs(SimpleNamespace(repo=Mock(return_value=response)), {"id": 200, "run_attempt": 1})
        self.assertEqual([job], shadow.complete_attempt_jobs(
            SimpleNamespace(repo=Mock(return_value={"total_count": 1, "jobs": [job]})), {"id": 200, "run_attempt": 1}))


class SmokeShadowTests(unittest.TestCase):
    def test_scopes_select_exact_flows_and_omit_empty_jobs(self):
        import strict_e2e_smoke as smoke
        from run_strict_e2e import main
        flows = json.loads((shadow.ROOT / shadow.MANIFEST).read_text())
        expected_core = {"tv-first-boot", "tv-playback-controls", "tv-pause-resume", "tv-background-return",
                         "tv-server-switch", "iphone-first-boot", "ipad-rotation"}
        planned = flows["flows"]
        for scope, expected in (("core", expected_core), ("full", {flow["id"] for flow in planned})):
            with self.subTest(scope=scope):
                context = environment("schedule" if scope == "core" else "workflow_dispatch")
                context.pop("SMOKE_SCOPE")
                scheduling = shadow.make_plan(context, flows, "c" * 64)
                self.assertEqual({flow["id"] for flow in scheduling["flows"]}, expected)
                self.assertEqual(len(scheduling["flows"]), 7 if scope == "core" else 23)
                groups = {group["id"] for group in scheduling["groups"]}
                self.assertEqual(groups, {flow["device"] + "-" + flow["configuration"].lower()
                                         for flow in scheduling["flows"]})
                self.assertEqual(groups, {"iphone-debug", "ipad-debug", "tv-debug", "tv-release"}
                                 if scope == "core" else set(shadow.GROUP_BUDGET_MINUTES))
                for group in scheduling["groups"]:
                    command = shadow.runner_command(group, "synthetic", Path("/tmp/synthetic"), Path("/tmp/evidence"),
                                                    warm=True, scope=scope)
                    with patch.object(smoke, "run", return_value=0) as run:
                        self.assertEqual(main(command[3:], stdout=io.StringIO(), stderr=io.StringIO()), 0)
                    arguments = run.call_args.args[0]
                    self.assertEqual(arguments.smoke_scope, scope)
                    runner = SimpleNamespace(CommandError=ValueError, data_available_gib=lambda: 100,
                        ensure_disk_for_xcodebuild=Mock(side_effect=RuntimeError("selection inspected")))
                    methods = {flow["selector"]: {flow["platform"]} for flow in flows["flows"]}
                    with patch.object(smoke, "select_flows", wraps=smoke.select_flows) as select, \
                            patch.object(smoke, "load_manifest", return_value=(flows, methods)), \
                            self.assertRaisesRegex(RuntimeError, "selection inspected"):
                        smoke.run(arguments, shadow.ROOT, runner, io.StringIO(), io.StringIO())
                    self.assertEqual(select.call_args.args[0], scheduling["flows"])
                with tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
                    temporary = Path(raw)
                    context, _api, reader = plan_fixture(temporary, stack)
                    reader.return_value = (flows, "c" * 64)
                    context["SMOKE_SCOPE"] = scope
                    self.assertEqual(shadow.plan_run(context, temporary / "plan"), 0)
                    outputs = (temporary / "output").read_text()
                    self.assertIn("ios_debug=true", outputs)
                    self.assertIn("ios_release=" + str(scope == "full").lower(), outputs)
        with self.assertRaises(ValueError):
            smoke.select_scope(flows["flows"], "unknown")
        with self.assertRaisesRegex(ContractError, "unknown smoke group"):
            shadow.group_flows(scheduling, "unknown")

    def test_admission_requires_main_schedule_or_dispatch_and_first_attempt(self):
        for event in ("schedule", "workflow_dispatch"):
            self.assertEqual(shadow.admit(environment(event)), HEAD)
        for change in ({"GITHUB_REF": "refs/heads/topic"}, {"GITHUB_EVENT_NAME": "workflow_run"},
                       {"GITHUB_EVENT_NAME": "pull_request"}, {"GITHUB_RUN_ATTEMPT": "2"}, {"GITHUB_SHA": "invalid"}):
            with self.subTest(change=change), self.assertRaises(ContractError):
                shadow.admit(dict(environment(), **change))

    def test_workflow_policy_requires_scopes_schedule_and_run_head(self):
        import check_workflow_policy as policy
        import yaml
        workflow = yaml.load((shadow.ROOT / shadow.WORKFLOW).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(policy.check_workflow(shadow.WORKFLOW, yaml.safe_dump(workflow)), [])
        for mutate in (lambda doc: doc["on"]["schedule"][0].update(cron="7 19 * * *"),
                       lambda doc: doc["on"]["schedule"].pop(),
                       lambda doc: doc["on"]["workflow_dispatch"]["inputs"]["scope"].update(default="core"),
                       lambda doc: doc["on"]["workflow_dispatch"]["inputs"]["scope"].update(options=["full"]),
                       lambda doc: doc["jobs"]["plan"]["steps"][0]["with"].update(ref="main"),
                       lambda doc: doc["jobs"]["ios-release"].update({"if": doc["jobs"]["flows"]["if"]})):
            changed = copy.deepcopy(workflow)
            mutate(changed)
            with self.subTest(mutation=mutate):
                self.assertIn("smoke-shadow-contract", {item.rule for item in policy.check_workflow(
                    shadow.WORKFLOW, yaml.safe_dump(changed))})

    def test_schedule_skips_only_a_source_with_completed_flow_results_dispatch_always_runs(self):
        prior = {"id": 100, "run_attempt": 1, "path": shadow.WORKFLOW, "workflow_id": 7,
                 "repository": {"full_name": REPOSITORY}, "head_repository": {"full_name": REPOSITORY},
                 "head_branch": "main", "head_sha": HEAD, "event": "schedule", "status": "completed",
                 "conclusion": "failure"}
        for defect in (None, "new-head", "skipped", "cancelled", "group-skipped", "group-cancelled", "partial", "foreign", "later-run"):
            for event in ("schedule", "workflow_dispatch"):
                with self.subTest(defect=defect, event=event), tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
                    temporary = Path(raw)
                    context, api, _reader = plan_fixture(temporary, stack)
                    context["GITHUB_EVENT_NAME"] = event
                    record = shadow.aggregate(plan(), group_records(plan()), "failure")
                    record["shadow"] = dict(record["shadow"], id="100", event="schedule")
                    candidate = dict(prior)
                    jobs = [{"name": "smoke-shadow-" + group["id"], "status": "completed", "conclusion": "success"}
                            for group in plan()["groups"]]
                    if defect == "new-head": candidate["head_sha"] = "d" * 40
                    if defect == "skipped": record["executed"] = False
                    if defect == "cancelled": candidate["conclusion"] = "cancelled"
                    if defect in {"group-skipped", "group-cancelled"}: jobs[0]["conclusion"] = defect[6:]
                    if defect == "partial": record["flows"][0]["executed"] = False
                    if defect == "foreign": candidate["head_repository"] = {"full_name": "foreign/repo"}
                    if defect == "later-run":
                        candidate["id"] = 201
                        record["shadow"]["id"] = "201"
                    api.pages.side_effect = lambda path, _collection, **_filters: ([candidate] if path.endswith("/runs") else [
                        {"name": f"smoke-shadow-{candidate['id']}-1", "expired": False, "id": 9}])
                    stack.enter_context(patch("ci_smoke_shadow.json_member", return_value=record))
                    stack.enter_context(patch("ci_smoke_shadow.complete_attempt_jobs", return_value=jobs))
                    self.assertEqual(shadow.plan_run(context, temporary / "plan"), 0)
                    scheduling = json.loads((temporary / "plan/plan.json").read_text())
                    expected = event == "workflow_dispatch" or defect is not None
                    self.assertEqual(scheduling["execute"], expected)
                    self.assertEqual(scheduling["head_sha"], HEAD)
                    self.assertIn("execute=" + str(expected).lower(), (temporary / "output").read_text())
                    if not expected:
                        result = shadow.aggregate(scheduling, [], "skipped")
                        self.assertEqual(result["outcome"], "not-run")
                        reason = ("Main head already tested by [run 100, attempt 1]"
                                  "(https://github.com/example/photos/actions/runs/100/attempts/1) (FAILED); all groups skipped.")
                        self.assertEqual(scheduling["not_run_reason"], reason)
                        self.assertEqual(shadow.markdown(result), "Smoke skipped: " + reason + "\n")
        with tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
            temporary = Path(raw)
            context, api, reader = plan_fixture(temporary, stack)
            context.update(GITHUB_EVENT_NAME="schedule", SMOKE_SCOPE="core")
            smoke_manifest = json.loads((shadow.ROOT / shadow.MANIFEST).read_text())
            reader.return_value = (smoke_manifest, "c" * 64)
            full = shadow.make_plan(environment(), smoke_manifest, "c" * 64)
            record = shadow.aggregate(full, group_records(full), "success")
            record["shadow"] = dict(record["shadow"], id="100", event="schedule")
            api.pages.side_effect = lambda path, _collection, **_filters: ([prior] if path.endswith("/runs") else [
                {"name": "smoke-shadow-100-1", "expired": False, "id": 9}])
            stack.enter_context(patch("ci_smoke_shadow.json_member", return_value=record))
            stack.enter_context(patch("ci_smoke_shadow.complete_attempt_jobs", return_value=[
                {"name": "smoke-shadow-" + group["id"], "status": "completed", "conclusion": "success"}
                for group in full["groups"]]))
            stack.enter_context(patch.object(shadow, "git", return_value=HEAD))
            shared = stack.enter_context(patch.object(shadow, "plan_shared"))
            self.assertEqual(shadow.plan_run(context, temporary / "plan", shared=True), 0)
            outputs = (temporary / "output").read_text()
            self.assertIn("execute=false", outputs)
            self.assertIn("ios_debug=false", outputs)
            self.assertIn("ios_release=false", outputs)
            shared.assert_not_called()

    def test_history_read_exceptions_execute_instead_of_skipping(self):
        import zipfile
        for failure in ("list", "artifact"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
                temporary = Path(raw)
                context, api, _reader = plan_fixture(temporary, stack)
                context["GITHUB_EVENT_NAME"] = "schedule"
                if failure == "list":
                    api.pages.side_effect = OSError("synthetic list failure")
                else:
                    api.pages.side_effect = lambda path, _collection, **_filters: ([run_metadata()] if path.endswith("/runs") else [
                        {"name": "smoke-shadow-100-1", "expired": False, "id": 9}])
                read = stack.enter_context(patch("ci_smoke_shadow.json_member", side_effect=zipfile.BadZipFile("synthetic corrupt artifact")))
                self.assertEqual(shadow.plan_run(context, temporary / "plan"), 0)
                scheduling = json.loads((temporary / "plan/plan.json").read_text())
                self.assertTrue(scheduling["execute"])
                self.assertIn("execute=true", (temporary / "output").read_text())
                if failure == "artifact":
                    read.assert_called_once()

    def test_successful_setup_never_recreates_the_simulator(self):
        for archive, group in ((True, "iphone-debug"), (False, "tv-release")):
            with self.subTest(archive=archive), SimulatorGroupFixture(archive=archive, group_id=group) as fixture:
                self.assertEqual(fixture.run(), 0)
                self.assertEqual(fixture.simulator.call_count, 1)
                fixture.retire.assert_not_called()
                self.assertIsNone(fixture.record()["simulator_recreate"])
                self.assertNotIn("setup-recreate:", fixture.log.getvalue())

    def test_simulator_setup_failure_recreates_once_before_the_first_flow(self):
        from strict_e2e_runner_support import CommandError, InfrastructureTimeout
        for step in ("simulator", "simulator-ready"):
            for kind in ("command", "timeout", "readiness-timeout", "converted-timeout"):
                with self.subTest(step=step, kind=kind), SimulatorGroupFixture() as fixture:
                    failure = {"command": CommandError("PRIVATE_SENTINEL"),
                        "timeout": subprocess.TimeoutExpired(["xcrun", "simctl", "PRIVATE_SENTINEL"], 60),
                        "readiness-timeout": InfrastructureTimeout("PRIVATE_SENTINEL", 300),
                        "converted-timeout": ContractError("PRIVATE_SENTINEL")}[kind]
                    command = "readiness" if kind == "readiness-timeout" else "simctl" if step == "simulator" or kind == "timeout" else "other"
                    def create(*args):
                        udid = fixture.create(*args)
                        if fixture.simulator.call_count == 1 and step == "simulator":
                            raise failure
                        return udid
                    fixture.simulator.side_effect = create
                    if step == "simulator-ready":
                        fixture.prepare.side_effect = [failure, None]
                    self.assertEqual(fixture.run(), 0)
                    self.assertEqual(fixture.simulator.call_count, 2)
                    self.assertEqual(fixture.retire.call_count, 2)
                    self.assertEqual([call.args[0] for call in fixture.retire.call_args_list], [
                        ["xcrun", "simctl", action, "synthetic-1"] for action in ("shutdown", "delete")])
                    for call in fixture.retire.call_args_list:
                        self.assertEqual(call.kwargs["timeout_seconds"], 60)
                    self.assertEqual(fixture.load.call_count, 1)
                    self.assertEqual(fixture.runner.call_count, 1)
                    self.assertEqual(fixture.record()["simulator_recreate"], {"step": step, "command": command})
                    self.assertEqual(fixture.log.getvalue(), f"setup-recreate: step={step}; command={command}; attempt=1\n")
                    self.assertIsNone(fixture.record()["setup_failure_step"])
                    self.assertEqual(fixture.record()["errors"], [])
                    self.assertEqual(fixture.load.call_args.args[2], "platform=iOS Simulator,id=synthetic-2")
                    self.assertEqual(fixture.prepare.call_args.args, ("synthetic-2",))
                    self.assertEqual(fixture.prepare.call_args.kwargs, {"boot_submitted": True, "should_check_app": False})
                    self.assertNotIn("PRIVATE_SENTINEL", fixture.log.getvalue() + json.dumps(fixture.record()))

    def test_second_setup_failure_stays_red_without_another_recreate(self):
        from strict_e2e_runner_support import InfrastructureTimeout
        for second in ("simulator", "simulator-ready"):
            with self.subTest(second=second), SimulatorGroupFixture() as fixture:
                failure = InfrastructureTimeout("PRIVATE_SENTINEL", 300)
                fixture.prepare.side_effect = [failure, failure]
                def create(*args):
                    udid = fixture.create(*args)
                    if fixture.simulator.call_count == 2 and second == "simulator":
                        raise subprocess.TimeoutExpired(["git", "PRIVATE_SENTINEL"], 30)
                    return udid
                fixture.simulator.side_effect = create
                self.assertEqual(fixture.run(), 1)
                self.assertEqual(fixture.simulator.call_count, 2)
                self.assertEqual(fixture.retire.call_count, 2)
                record = fixture.record()
                self.assertEqual(record["simulator_recreate"], {"step": "simulator-ready", "command": "readiness"})
                self.assertEqual(record["setup_failure_step"], second)
                self.assertEqual(record["setup_failure_command"], "git" if second == "simulator" else "readiness")
                self.assertEqual(record["runner_exit_code"], 124)
                self.assertEqual(record["errors"], ["setup-step-timeout"])
                self.assertTrue(all(row["outcome"] == "not-run" and not row["executed"] for row in record["flows"]))
                self.assertEqual(fixture.log.getvalue().count("setup-recreate:"), 1)
                fixture.runner.assert_not_called()

    def test_recreate_never_catches_archive_runner_or_group_budget_failures(self):
        for boundary in ("archive-verify", "archive-load", "runner-command", "warm-up", "flows"):
            with self.subTest(boundary=boundary), SimulatorGroupFixture(archive=boundary != "warm-up") as fixture:
                failure = subprocess.TimeoutExpired(["xcrun", "simctl", "PRIVATE_SENTINEL"], 60)
                target = {"archive-verify": fixture.verify, "archive-load": fixture.load,
                          "warm-up": fixture.runner, "flows": fixture.runner}.get(boundary)
                if target is not None:
                    target.side_effect = failure
                with patch.object(shadow, "runner_command", side_effect=failure) if boundary == "runner-command" else ExitStack():
                    self.assertEqual(fixture.run(), 1)
                fixture.retire.assert_not_called()
                self.assertLessEqual(fixture.simulator.call_count, 1)
                self.assertIsNone(fixture.record()["simulator_recreate"])
                self.assertEqual(fixture.record()["setup_failure_step"], boundary if boundary in {
                    "archive-verify", "archive-load", "runner-command"} else None)
                self.assertNotIn("setup-recreate:", fixture.log.getvalue())

    def test_create_without_publication_never_retires_an_inherited_device(self):
        with SimulatorGroupFixture() as fixture:
            fixture.context["UI_SIMULATOR"] = "inherited-device"
            publication = Path(fixture.context["GITHUB_ENV"])
            publication.write_text("UNRELATED=unchanged\n")
            fixture.simulator.side_effect = ContractError("PRIVATE_SENTINEL")
            self.assertEqual(fixture.run(), 1)
            self.assertEqual(fixture.simulator.call_count, 1)
            fixture.retire.assert_not_called()
            self.assertNotIn("setup-recreate:", fixture.log.getvalue())
            self.assertEqual(publication.read_text(), "UNRELATED=unchanged\n")
            self.assertIsNone(fixture.record()["simulator_recreate"])

    def test_already_shutdown_device_can_be_retired_before_recreating(self):
        from strict_e2e_runner_support import InfrastructureTimeout
        with SimulatorGroupFixture() as fixture:
            fixture.prepare.side_effect = [InfrastructureTimeout("PRIVATE_SENTINEL", 300), None]
            fixture.retire.side_effect = [SimpleNamespace(returncode=149, stderr=
                "Unable to shutdown device in current state: Shutdown\nPRIVATE_SENTINEL"),
                SimpleNamespace(returncode=0)]
            self.assertEqual(fixture.run(), 0)
            self.assertEqual(fixture.simulator.call_count, 2)
            self.assertEqual([call.args[0] for call in fixture.retire.call_args_list], [
                ["xcrun", "simctl", action, "synthetic-1"] for action in ("shutdown", "delete")])
            self.assertEqual(fixture.record()["simulator_recreate"],
                             {"step": "simulator-ready", "command": "readiness"})
            self.assertNotIn("PRIVATE_SENTINEL", fixture.log.getvalue() + json.dumps(fixture.record()))

    def test_failed_retirement_keeps_the_original_setup_attribution_and_device(self):
        from strict_e2e_runner_support import InfrastructureTimeout
        for action in ("shutdown", "delete"):
            for kind in ("exit", "timeout", "launch"):
                with self.subTest(action=action, kind=kind), SimulatorGroupFixture() as fixture:
                    fixture.prepare.side_effect = InfrastructureTimeout("PRIVATE_SENTINEL", 300)
                    def retire(argv, *_args, **_options):
                        if argv[2] == action:
                            if kind == "timeout":
                                raise InfrastructureTimeout("PRIVATE_SENTINEL", 60)
                            if kind == "launch":
                                raise OSError("PRIVATE_SENTINEL")
                            return SimpleNamespace(returncode=1, stderr="PRIVATE_SENTINEL" if action == "shutdown"
                                                   else "current state: Shutdown")
                        return SimpleNamespace(returncode=0)
                    fixture.retire.side_effect = retire
                    self.assertEqual(fixture.run(), 1)
                    self.assertEqual(fixture.simulator.call_count, 1)
                    self.assertEqual(fixture.retire.call_count, 1 if action == "shutdown" else 2)
                    self.assertEqual(fixture.context["UI_SIMULATOR"], "synthetic-1")
                    published = dict(line.split("=", 1) for line in Path(fixture.context["GITHUB_ENV"]).read_text().splitlines())
                    self.assertEqual(published["UI_SIMULATOR"], "synthetic-1")
                    record = fixture.record()
                    self.assertIsNone(record["simulator_recreate"])
                    self.assertEqual((record["setup_failure_step"], record["setup_failure_command"], record["runner_exit_code"]),
                                     ("simulator-ready", "readiness", 124))
                    self.assertEqual(fixture.log.getvalue(), "setup-step-timeout: step=simulator-ready; command=readiness\n")
                    fixture.load.assert_not_called()

    def test_recreate_eligibility_bounds_setup_before_and_after_retirement(self):
        from strict_e2e_runner_support import InfrastructureTimeout
        for archive, group, before_elapsed, after_elapsed in ((True, "iphone-debug", 780, 900),
                                                            (False, "tv-release", 1080, 1200)):
            for boundary in ("before", "after"):
                for offset in (-1, 0, 1):
                    elapsed = before_elapsed + offset if boundary == "before" else 0
                    with self.subTest(archive=archive, boundary=boundary, offset=offset), SimulatorGroupFixture(
                            archive=archive, group_id=group, elapsed=elapsed) as fixture:
                        failure = InfrastructureTimeout("PRIVATE_SENTINEL", 300)
                        if archive:
                            fixture.prepare.side_effect = [failure, None]
                        else:
                            def create(*args):
                                udid = fixture.create(*args)
                                if fixture.simulator.call_count == 1:
                                    raise failure
                                return udid
                            fixture.simulator.side_effect = create
                        if boundary == "after":
                            def retire(*_args, **_options):
                                fixture.clock[0] = 1000 + after_elapsed + offset
                                return SimpleNamespace(returncode=0)
                            fixture.retire.side_effect = retire
                        eligible = offset <= 0
                        self.assertEqual(fixture.run(), 0 if eligible else 1)
                        self.assertEqual(fixture.simulator.call_count, 2 if eligible else 1)
                        self.assertEqual(fixture.retire.call_count, 0 if boundary == "before" and not eligible else 2)
                        self.assertEqual(fixture.record()["simulator_recreate"] is not None, eligible)
                        if not eligible:
                            self.assertEqual(fixture.record()["setup_failure_step"], "simulator-ready" if archive else "simulator")
                            fixture.load.assert_not_called()
                            fixture.runner.assert_not_called()

    def test_recreated_archive_requires_its_own_caps_before_loading(self):
        from strict_e2e_runner_support import InfrastructureTimeout
        for recreated in (False, True):
            for offset in (-1, 0, 1):
                with self.subTest(recreated=recreated, offset=offset), SimulatorGroupFixture() as fixture:
                    def prepare(*_args, **_options):
                        if recreated and fixture.prepare.call_count == 1:
                            raise InfrastructureTimeout("PRIVATE_SENTINEL", 300)
                        fixture.clock[0] = 1000 + 1110 + offset
                    fixture.prepare.side_effect = prepare
                    eligible = not recreated or offset <= 0
                    self.assertEqual(fixture.run(), 0 if eligible else 1)
                    self.assertEqual(fixture.simulator.call_count, 2 if recreated else 1)
                    self.assertEqual(fixture.load.call_count, int(eligible))
                    self.assertEqual(fixture.runner.call_count, int(eligible))
                    self.assertEqual(fixture.record()["simulator_recreate"] is not None, recreated)
                    if not eligible:
                        record = fixture.record()
                        self.assertEqual(record["errors"], ["group-budget-exhausted"])
                        self.assertEqual(record["runner_exit_code"], 124)
                        self.assertIsNone(record["setup_failure_step"])
                        self.assertIsNone(record["setup_failure_command"])
                        self.assertTrue(all(row["outcome"] == "not-run" and not row["executed"] for row in record["flows"]))

    def test_cleanup_uses_the_fresh_published_device_even_when_its_boot_fails(self):
        from strict_e2e_runner_support import InfrastructureTimeout
        for failure in (None, "boot", "create"):
            with self.subTest(failure=failure), SimulatorGroupFixture() as fixture:
                fixture.prepare.side_effect = [InfrastructureTimeout("PRIVATE_SENTINEL", 300), None]
                def create(*args):
                    if failure == "create" and fixture.simulator.call_count == 2:
                        raise ContractError("PRIVATE_SENTINEL")
                    udid = fixture.create(*args)
                    if failure == "boot" and fixture.simulator.call_count == 2:
                        raise ContractError("PRIVATE_SENTINEL")
                    return udid
                fixture.simulator.side_effect = create
                self.assertEqual(fixture.run(), int(failure is not None))
                published = dict(line.split("=", 1) for line in Path(fixture.context["GITHUB_ENV"]).read_text().splitlines())
                self.assertEqual(published["UI_SIMULATOR"], "" if failure == "create" else "synthetic-2")
                self.assertEqual(published["UI_DESTINATION"], "" if failure == "create" else "platform=iOS Simulator,id=synthetic-2")
                self.assertEqual(fixture.context.get("UI_SIMULATOR"), None if failure == "create" else "synthetic-2")
                calls = []
                def dispose(argv, **_options):
                    calls.append(argv)
                    return SimpleNamespace(returncode=1, stdout=b"", stderr=b"")
                with patch.object(shadow.subprocess, "run", side_effect=dispose):
                    self.assertEqual(shadow.cleanup(dict(fixture.context, **published), fixture.temporary), 0)
                self.assertEqual([argv for argv in calls if argv[0] == "xcrun"], [] if failure == "create" else [
                    ["xcrun", "simctl", action, "synthetic-2"] for action in ("shutdown", "delete")])
                self.assertFalse((fixture.temporary / "smoke-execution.noindex").exists())

    def test_recreate_public_record_is_closed_and_old_records_default_to_none(self):
        for value, valid in ((None, True), ({"step": "simulator", "command": "simctl"}, True),
                ({"step": "simulator-ready", "command": "readiness"}, True),
                ({"step": "archive-load", "command": "simctl"}, False),
                ({"step": "simulator", "command": "PRIVATE_SENTINEL"}, False),
                ({"step": ["simulator"], "command": "simctl"}, False),
                ({"step": "simulator", "command": ["simctl"]}, False),
                ({"step": "simulator", "command": "simctl", "udid": "PRIVATE_SENTINEL"}, False),
                ("PRIVATE_SENTINEL", False)):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as raw:
                records = group_records(plan())
                records[0]["simulator_recreate"] = value
                result = shadow.aggregate(plan(), records, "success")
                self.assertEqual("invalid simulator recreate: iphone-debug" in result["errors"], not valid)
                self.assertNotIn("PRIVATE_SENTINEL", shadow.markdown(result))
                self.assertEqual(result["group_timings"]["iphone-debug"].get("simulator_recreate"), value if valid else None)
                if valid:
                    shadow.check_group_upload(Path(raw), records[0])
                    line = next(line for line in shadow.markdown(result).splitlines() if line.startswith("| iphone-debug |"))
                    self.assertIn("none" if value is None else value["step"] + "/" + value["command"], line)
                else:
                    with self.assertRaisesRegex(ValueError, "invalid simulator recreate"):
                        shadow.check_group_upload(Path(raw), records[0])
        result = shadow.aggregate(plan(), group_records(plan()), "success")
        self.assertIsNone(result["group_timings"]["iphone-debug"]["simulator_recreate"])

    def test_aggregate_requires_the_planned_main_control_even_for_suppressed_plans(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            def commit(value):
                (root / "source").write_text(value)
                subprocess.run(["git", "add", "."], cwd=root, check=True)
                subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                "commit", "-qm", "fixture"], cwd=root, check=True)
                return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            planned = commit("planned")
            advanced = commit("advanced main")
            subprocess.run(["git", "update-ref", "refs/remotes/origin/main", advanced], cwd=root, check=True)
            subprocess.run(["git", "checkout", "-q", "--detach", planned], cwd=root, check=True)
            foreign = commit("outside main")
            temporary = root / ".git/runner"
            context = dict(environment(), RUNNER_TEMP=str(temporary), SMOKE_MATRIX_RESULT="skipped",
                           GITHUB_STEP_SUMMARY=str(temporary / "summary.md"))
            for case in ("planned", "checkout-changed", "staged-changed", "outside-main", "missing-archive", "missing-shared"):
                with self.subTest(case=case), ExitStack() as stack:
                    scheduling = dict(plan(), execute=False, not_run_reason="Synthetic suppression.",
                                      build_mode=shadow.ARCHIVE_MODE, control_source_sha=planned)
                    checkout = advanced if case == "checkout-changed" else foreign if case == "outside-main" else planned
                    subprocess.run(["git", "checkout", "-q", "--detach", checkout], cwd=root, check=True)
                    staged = temporary / "smoke-control/stage.json"
                    if case == "staged-changed":
                        shadow.write_json(staged, {"head_sha": advanced})
                    elif staged.exists():
                        staged.unlink()
                    if case == "outside-main":
                        scheduling["control_source_sha"] = foreign
                    elif case.startswith("missing"):
                        scheduling.pop("control_source_sha")
                        if case == "missing-shared":
                            scheduling.pop("build_mode")
                    shadow.write_json(temporary / "ci-artifacts/smoke-plan/plan.json", scheduling)
                    stack.enter_context(patch.dict(os.environ, context, clear=True))
                    stack.enter_context(patch.object(shadow, "ROOT", root))
                    reader = stack.enter_context(patch.object(shadow, "manifest_at_head", return_value=(manifest(), "c" * 64)))
                    stack.enter_context(patch.object(shadow, "read_transfer_timings"))
                    stack.enter_context(patch.object(shadow, "scan_records"))
                    self.assertEqual(shadow.main(["aggregate"]), 0 if case == "planned" else 1)
                    if case == "planned":
                        reader.assert_called_once_with(HEAD)
                        result = json.loads((temporary / "smoke-shadow/shadow.json").read_text())
                        self.assertEqual(result["outcome"], "not-run")
                    else:
                        reader.assert_not_called()

    def test_source_at_commit_matches_the_clean_checkout_fingerprint(self):
        from strict_e2e_build import smoke_source_identity
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "nested").mkdir()
            (root / "nested/photo.txt").write_bytes(b"synthetic\x00content\n")
            (root / "unicode-\u00e9.txt").write_text("fixture")
            (root / "link").symlink_to("nested/photo.txt")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                            "commit", "-qm", "fixture"], cwd=root, check=True)
            with patch.object(shadow, "ROOT", root):
                self.assertEqual(shadow.source_at_commit(shadow.git("rev-parse", "HEAD")), smoke_source_identity(root))

    def test_current_control_keeps_the_planned_commit_when_main_advances(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            def commit(value):
                (root / "source").write_text(value)
                subprocess.run(["git", "add", "."], cwd=root, check=True)
                subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                "commit", "-qm", "fixture"], cwd=root, check=True)
                return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            planned = commit("planned")
            subprocess.run(["git", "update-ref", "refs/remotes/origin/main", planned], cwd=root, check=True)
            temporary = root / ".git/runner"
            context = dict(environment(), RUNNER_TEMP=str(temporary), GITHUB_SHA=planned,
                           GITHUB_WORKFLOW_REF=REPOSITORY + "/" + shadow.WORKFLOW + "@refs/heads/main")
            run = dict(run_metadata(), id=200, workflow_id=8, path=shadow.WORKFLOW, head_sha=planned, event="workflow_dispatch")
            api = SimpleNamespace(repo=lambda path: run if path == "actions/runs/200" else {"id": 8, "path": shadow.WORKFLOW})
            with patch.object(shadow, "ROOT", root), patch("ci_smoke_shadow.GitHub", return_value=api):
                control = shadow.authoritative_control(context, api)
                advanced = commit("advanced")
                subprocess.run(["git", "update-ref", "refs/remotes/origin/main", advanced], cwd=root, check=True)
                subprocess.run(["git", "checkout", "-q", "--detach", planned], cwd=root, check=True)
                shadow.write_json(temporary / "smoke-control/stage.json", {"head_sha": planned})
                self.assertEqual(shadow.current_control({"control": control}, context), (api, control))
                shadow.write_json(temporary / "smoke-control/stage.json", {"head_sha": advanced})
                with self.assertRaisesRegex(ValueError, "control changed"):
                    shadow.current_control({"control": control}, context)

    def test_select_archive_uses_api_admission_and_producer_hashes(self):
        scheduling = shared_plan()
        for defect in (None, "expired", "failed-producer", "source"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as raw:
                temporary = Path(raw)
                api, job = archive_api()
                if defect == "expired":
                    api.repo.return_value["expired"] = True
                if defect == "failed-producer":
                    job["conclusion"] = "failure"
                identity = {"source": {"head_sha": "f" * 40} if defect == "source" else scheduling["tested_source"]}
                context = dict(environment(), SMOKE_GROUP="iphone-debug", SMOKE_DEBUG_ARTIFACT_ID="91",
                               SMOKE_DEBUG_MANIFEST_SHA256="d" * 64, SMOKE_DEBUG_ARCHIVE_SHA256="e" * 64)
                with patch.object(shadow, "current_control", return_value=(api, scheduling["control"])), \
                        patch.object(shadow, "producer_job", return_value=job), \
                        patch("strict_e2e_build.smoke_build_identity", return_value=identity):
                    if defect:
                        with self.assertRaises(ValueError):
                            shadow.select_archive(scheduling, context, temporary)
                        self.assertFalse((temporary / "smoke-archive-selection.json").exists())
                    else:
                        self.assertEqual(shadow.select_archive(scheduling, context, temporary), 0)
                        selection = json.loads((temporary / "smoke-archive-selection.json").read_text())
                        self.assertEqual(selection["provenance"], archive_provenance(scheduling))
                        api.repo.assert_called_once_with("actions/artifacts/91")

    def test_producer_record_keeps_unknown_upload_timing_without_failing_admission(self):
        scheduling = shared_plan()
        for defect in (None, "expired", "build-source"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as raw:
                temporary = Path(raw)
                api, job = archive_api()
                if defect == "expired":
                    api.repo.return_value["expired"] = True
                source = {} if defect == "build-source" else scheduling["tested_source"]
                shadow.write_json(temporary / "smoke-producer/build.json", {"configuration": "Debug", "source": source,
                    "job_started_epoch": time.time(), "measurements": {"build_seconds": 10, "pack_seconds": 1,
                    "manifest_sha256": "d" * 64, "archive_sha256": "e" * 64}})
                with patch.object(shadow, "current_control", return_value=(api, scheduling["control"])), \
                        patch.object(shadow, "producer_job", return_value=job), patch.object(shadow, "scan_records"):
                    code = shadow.finish_producer(scheduling, dict(environment(), SMOKE_CONFIGURATION="Debug",
                                                  SMOKE_ARTIFACT_ID="91"), temporary)
                record = json.loads((temporary / "smoke-producer-records/producer.json").read_text())
                self.assertEqual((code, record["outcome"]), (1, "failed") if defect else (0, "passed"))
                if not defect:
                    self.assertEqual(record["provenance"], archive_provenance(scheduling))
                    self.assertIsNone(record["timing"]["upload_seconds"])

    def test_aggregate_transfer_diagnostics_tolerate_incomplete_steps_and_api_failure(self):
        scheduling = shared_plan()
        for state in ("complete", "running", "missing", "api-error", "invalid-clock"):
            with self.subTest(state=state):
                step = {"name": "Publish the immutable configuration archive", "conclusion": "success",
                        "started_at": "2026-11-15T00:00:00Z", "completed_at": "2026-11-15T00:00:02Z"}
                if state == "running":
                    step.update(conclusion=None, completed_at=None)
                if state == "invalid-clock":
                    step["completed_at"] = "invalid"
                jobs = [{"name": "smoke-shadow-ios-debug", "steps": [] if state == "missing" else [step]},
                        {"name": "smoke-shadow-iphone-debug", "steps": [dict(step, name="Download the selected configuration archive")]}]
                producers = [{"configuration": "Debug", "timing": {"upload_seconds": None}}]
                records = [{"timing_mode": shadow.ARCHIVE_MODE, "group": {"id": "iphone-debug"}, "transfer_seconds": None}]
                with patch("ci_smoke_shadow.GitHub"), patch("ci_smoke_shadow.complete_attempt_jobs", return_value=jobs,
                        side_effect=OSError("unavailable") if state == "api-error" else None):
                    shadow.read_transfer_timings(scheduling, producers, records, environment())
                self.assertEqual(producers[0]["timing"]["upload_seconds"], 2 if state == "complete" else None)
                self.assertEqual(records[0]["transfer_seconds"], 2 if state in {"complete", "missing"} else None)

    def test_archive_group_verifies_planned_expectations_before_slow_simulator_creation(self):
        scheduling = shared_plan()
        for defect in (None, "control", "manifest", "allowance", "selection"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
                temporary = Path(raw)
                provenance = archive_provenance(scheduling)
                identity = {"source": scheduling["tested_source"]}
                clock = [100.0]
                shadow.write_json(temporary / "smoke-archive-selection.json", {"provenance": provenance,
                    "identity": identity, "transfer_started_epoch": 100.0})
                if defect == "selection":
                    (temporary / "smoke-archive-selection.json").unlink()
                shadow.write_json(temporary / "ci-artifacts/smoke-build/manifest.json", {"control": {"run_id": "untrusted"}})
                calls = []
                ready = [False]
                def verify(_directory, derived, **options):
                    calls.append("verify")
                    self.assertTrue(derived.parent.name.endswith(".noindex"))
                    self.assertEqual(options["control"], scheduling["control"])
                    self.assertEqual(options["manifest_hash"], "d" * 64)
                    self.assertEqual(options["archive_hash"], "e" * 64)
                    clock[0] += 121 if defect == "allowance" else 1
                    if defect in {"control", "manifest"}:
                        raise ValueError("archive admission rejected")
                def create(*_args):
                    calls.append("create")
                    clock[0] += 150
                    return "synthetic"
                def prepare(*_args, **options):
                    self.assertTrue(options["boot_submitted"])
                    self.assertIs(options["should_check_app"], False)
                    calls.append("ready")
                    ready[0] = True
                def load_archive(*_args, **_options):
                    # Model the hosted post-boot Git timeout, before any flow can start.
                    if not ready[0]:
                        raise subprocess.TimeoutExpired(["git", "status", "--porcelain"], 30)
                stack.enter_context(patch.object(shadow.time, "time", side_effect=lambda: clock[0]))
                stack.enter_context(patch.object(shadow.time, "monotonic", side_effect=lambda: clock[0]))
                stack.enter_context(patch.object(shadow, "git", return_value=HEAD))
                stack.enter_context(patch("ci_build_archive.file_hash", return_value="c" * 64))
                stack.enter_context(patch.object(shadow, "job_started_epoch", return_value=100.0))
                stack.enter_context(patch("ci_smoke_shadow.complete_attempt_jobs", return_value=[{"name": "smoke-shadow-iphone-debug", "steps": [
                    {"name": "Download the selected configuration archive", "conclusion": None}]}]))
                stack.enter_context(patch("ci_build_archive.workspace_preflight"))
                stack.enter_context(patch("run_offline_unit_tests.ensure_disk_for_xcodebuild"))
                stack.enter_context(patch("ci_simulator.create_and_boot_simulator", side_effect=create))
                stack.enter_context(patch("strict_e2e_runner_support.prepare_simulator", side_effect=prepare))
                stack.enter_context(patch("strict_e2e_build.smoke_build_identity", return_value=identity))
                stack.enter_context(patch.object(shadow, "verify_smoke_archive", side_effect=verify))
                load = stack.enter_context(patch("strict_e2e_build.load_smoke_archive", side_effect=load_archive))
                run = stack.enter_context(patch.object(tracer, "run_runner", return_value=0))
                def evidence(*_args, validation, **_options):
                    validation.update(outcome="passed", reason=None)
                    return group_records(scheduling)[0]["flows"], []
                stack.enter_context(patch.object(shadow, "read_runner_flows", side_effect=evidence))
                stack.enter_context(patch.object(shadow, "check_group_upload"))
                def execute(*_args, **_options):
                    shadow.write_json(temporary / "smoke-execution.noindex/flows/case-manifest.json", {"selection": "group"})
                    return 0
                run.side_effect = execute
                code = shadow.run_group(scheduling, dict(environment(), SMOKE_GROUP="iphone-debug"), temporary)
                record = json.loads((temporary / "smoke-records/group.json").read_text())
                if defect:
                    self.assertEqual(code, 1)
                    self.assertEqual(calls, [] if defect == "selection" else ["verify"])
                    run.assert_not_called()
                    load.assert_not_called()
                    self.assertEqual(record["flows"][0]["outcome"], "not-run")
                    self.assertFalse(record["flows"][0]["executed"])
                else:
                    self.assertEqual((code, calls), (0, ["verify", "create", "ready"]))
                    self.assertTrue((temporary / "smoke-execution.noindex/ownership.json").is_file())
                    self.assertEqual(record["build_provenance"], provenance)
                    self.assertEqual(record["verify_seconds"], 1)
                    self.assertIsNone(record["transfer_seconds"])
                    self.assertEqual(load.call_args.kwargs["control"], scheduling["control"])
                    self.assertIn("--test-without-building", run.call_args.args[0])

    def test_setup_failures_name_the_step_and_keep_subprocess_timeouts_distinct_from_the_group_budget(self):
        from strict_e2e_runner_support import CommandError, InfrastructureTimeout
        from run_offline_unit_tests import CommandError as OfflineCommandError
        scheduling = shared_plan()
        for step in ("job-clock", "preflight", "archive-verify", "simulator", "simulator-ready", "archive-load"):
            kinds = ["timeout", "value"]
            if step in {"simulator-ready", "archive-load"}:
                kinds.append("command")
            if step == "preflight":
                kinds.append("offline-command")
            for kind in kinds:
                with self.subTest(step=step, kind=kind), tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
                    temporary = Path(raw)
                    identity = {"source": scheduling["tested_source"]}
                    shadow.write_json(temporary / "smoke-archive-selection.json", {
                        "provenance": archive_provenance(scheduling), "identity": identity,
                        "transfer_started_epoch": time.time()})
                    timed_out = kind == "timeout"
                    argv = {"job-clock": ["git", "status"], "preflight": [], "archive-verify": ["xcrun", "--sdk"],
                            "simulator": ["xcrun", "simctl"], "archive-load": ["codesign"]}.get(step, [])
                    timeout_seconds = {"archive-verify": 60, "simulator": 60, "archive-load": 120}.get(step, 30)
                    failure = {"timeout": subprocess.TimeoutExpired(argv + ["PRIVATE_SENTINEL"], timeout_seconds, output="PRIVATE_SENTINEL"),
                               "value": ValueError("PRIVATE_SENTINEL"), "command": CommandError("PRIVATE_SENTINEL"),
                               "offline-command": OfflineCommandError("PRIVATE_SENTINEL")}[kind]
                    if timed_out and step == "simulator-ready":
                        failure = InfrastructureTimeout("simulator-bootstatus", 300)
                    stack.enter_context(patch.object(shadow, "git", return_value=HEAD))
                    stack.enter_context(patch("ci_build_archive.file_hash", return_value="c" * 64))
                    for name, target, value in (
                        ("job-clock", "ci_smoke_shadow.job_started_epoch", time.time()),
                        ("preflight", "ci_build_archive.workspace_preflight", None),
                        ("archive-verify", "ci_smoke_shadow.verify_smoke_archive", None),
                        ("simulator", "ci_simulator.create_and_boot_simulator", "synthetic"),
                        ("simulator-ready", "strict_e2e_runner_support.prepare_simulator", None),
                        ("archive-load", "strict_e2e_build.load_smoke_archive", None)):
                        stack.enter_context(patch(target, return_value=value,
                            side_effect=failure if name == step and kind != "offline-command" else None))
                    stack.enter_context(patch("run_offline_unit_tests.ensure_disk_for_xcodebuild",
                                             side_effect=failure if kind == "offline-command" else None))
                    stack.enter_context(patch("strict_e2e_build.smoke_build_identity", return_value=identity))
                    stack.enter_context(patch.object(shadow, "check_group_upload"))
                    run = stack.enter_context(patch.object(tracer, "run_runner"))
                    log = stack.enter_context(redirect_stderr(io.StringIO()))
                    self.assertEqual(shadow.run_group(scheduling, dict(environment(), SMOKE_GROUP="iphone-debug"), temporary), 1)
                    text = (temporary / "smoke-records/group.json").read_text()
                    record = json.loads(text)
                    self.assertEqual(record["setup_failure_step"], step)
                    command = {"job-clock": "git", "preflight": "other", "archive-verify": "xcrun-sdk",
                               "simulator": "simctl", "simulator-ready": "readiness", "archive-load": "codesign"}[step] if timed_out else None
                    self.assertEqual(record["setup_failure_command"], command)
                    self.assertEqual(record["runner_exit_code"], 124 if timed_out else 1)
                    self.assertEqual(record["errors"], ["setup-step-timeout" if timed_out
                                                     else "group-execution-or-official-evidence-failed"])
                    self.assertEqual(record["flows"][0]["outcome"], "not-run")
                    self.assertFalse(record["flows"][0]["executed"])
                    self.assertNotIn("PRIVATE_SENTINEL", text)
                    self.assertNotIn("PRIVATE_SENTINEL", log.getvalue())
                    self.assertEqual(log.getvalue(), (f"setup-step-timeout: step={step}; command={command}"
                        + ("" if command == "readiness" else f"; timeout={timeout_seconds}s") + "\n") if timed_out else "")
                    run.assert_not_called()
                    result = shadow.aggregate(scheduling, [record], "failure")
                    self.assertEqual(result["outcome"], "failed")
                    self.assertEqual(result["group_timings"]["iphone-debug"]["setup_failure_step"], step)
                    self.assertEqual(result["group_timings"]["iphone-debug"]["setup_failure_command"], command)
                    self.assertIn(step, shadow.markdown(result))

    def test_setup_attribution_rejects_unknown_steps_and_success_claims(self):
        for step, code, executed, valid in (("archive-load", 1, True, False), ("archive-load", 0, False, False),
                ("archive-load", 124, False, True), ("archive-load", "124", False, False),
                ("archive-load", True, False, False), ("archive-load", 124.0, False, False),
                ("/private/path", 1, False, False), (["archive-load"], 1, False, False), (True, 1, False, False)):
            with self.subTest(step=step, code=code, executed=executed), tempfile.TemporaryDirectory() as raw:
                records = group_records(plan())
                records[0].update(setup_failure_step=step, runner_exit_code=code)
                if not executed:
                    records[0]["flows"][0].update(outcome="not-run", elapsed_seconds=None, executed=False,
                                                official_execution_complete=False)
                self.assertIs(shadow.valid_setup_failure(records[0]), valid)
                result = shadow.aggregate(plan(), records, "failure")
                self.assertEqual("invalid group setup failure: iphone-debug" in result["errors"], not valid)
                with patch.object(shadow, "scan_records"), patch("ci_failure_diagnostics.validate_ui_first_failure_images"):
                    if valid:
                        shadow.check_group_upload(Path(raw), records[0])
                    else:
                        with self.assertRaisesRegex(ValueError, "invalid group setup failure"):
                            shadow.check_group_upload(Path(raw), records[0])

    def test_timeout_command_attribution_uses_only_known_argv_prefixes(self):
        for argv, expected in ((["git", "status", "PRIVATE_SENTINEL"], "git"),
                (["xcrun", "--sdk", "iphonesimulator", "PRIVATE_SENTINEL"], "xcrun-sdk"),
                (["xcrun", "simctl", "list", "PRIVATE_SENTINEL"], "simctl"),
                (["codesign", "-dv", "PRIVATE_SENTINEL"], "codesign"),
                (["xcrun", "PRIVATE_SENTINEL"], "other"), (["/private/git", "status"], "other"),
                ("git status PRIVATE_SENTINEL", "other"), (None, "other"), ([], "other")):
            with self.subTest(argv=argv):
                self.assertEqual(shadow.timeout_command(argv), expected)

    def test_setup_command_requires_a_closed_timeout_attribution_and_preserves_historical_records(self):
        for command, step, code, errors, valid in (("simctl", "archive-load", 124, ["setup-step-timeout"], True),
                ("/private/path", "archive-load", 124, ["setup-step-timeout"], False),
                (["simctl"], "archive-load", 124, ["setup-step-timeout"], False),
                (None, "archive-load", 124, ["setup-step-timeout"], False),
                ("simctl", None, 124, ["setup-step-timeout"], False),
                ("simctl", "archive-load", 1, ["setup-step-timeout"], False),
                ("simctl", "archive-load", 124, [], False),
                (None, "archive-load", 124, None, True),
                (None, "archive-load", 1, [], True), (None, None, 0, [], True)):
            with self.subTest(command=command, step=step, code=code, errors=errors), tempfile.TemporaryDirectory() as raw:
                records = group_records(plan())
                record = records[0]
                record.update(setup_failure_step=step, setup_failure_command=command, runner_exit_code=code, errors=errors)
                record["flows"][0].update(outcome="not-run", elapsed_seconds=None, executed=False,
                                           official_execution_complete=False)
                self.assertIs(shadow.valid_setup_failure(record), valid)
                result = shadow.aggregate(plan(), records, "failure")
                self.assertEqual("invalid group setup failure: iphone-debug" in result["errors"], not valid)
                timing = result["group_timings"]["iphone-debug"]
                if valid:
                    self.assertEqual(timing["setup_failure_command"], command)
                else:
                    self.assertNotIn("setup_failure_step", timing)
                    self.assertNotIn("setup_failure_command", timing)
                with patch.object(shadow, "scan_records"), patch("ci_failure_diagnostics.validate_ui_first_failure_images"):
                    if valid:
                        shadow.check_group_upload(Path(raw), record)
                    else:
                        with self.assertRaisesRegex(ValueError, "invalid group setup failure"):
                            shadow.check_group_upload(Path(raw), record)
                del record["setup_failure_command"]
                self.assertTrue(shadow.valid_setup_failure(record))

    def test_setup_summary_distinguishes_explicit_none_from_historical_unknown(self):
        for fields, expected in (({}, "unknown | unknown"),
                ({"setup_failure_step": None, "setup_failure_command": None}, "none | none"),
                ({"setup_failure_step": "archive-load", "setup_failure_command": "simctl"}, "archive-load | simctl")):
            with self.subTest(fields=fields):
                result = shadow.aggregate(plan(), group_records(plan()), "success")
                result["group_timings"]["iphone-debug"].update(fields)
                line = next(line for line in shadow.markdown(result).splitlines() if line.startswith("| iphone-debug |"))
                self.assertTrue(line.endswith("| " + expected + " |"), line)

    def test_invalid_setup_attribution_renders_unknown_without_claiming_no_failure(self):
        for fields in ({"setup_failure_step": "invalid", "setup_failure_command": None},
                {"setup_failure_step": "archive-load", "setup_failure_command": "invalid"}):
            with self.subTest(fields=fields):
                scheduling = plan()
                records = group_records(scheduling)
                records[0].update(fields, runner_exit_code=124, errors=["setup-step-timeout"])
                records[0]["flows"][0].update(outcome="not-run", elapsed_seconds=None, executed=False,
                                            official_execution_complete=False)
                result = shadow.aggregate(scheduling, records, "failure")
                self.assertIn("invalid group setup failure: iphone-debug", result["errors"])
                self.assertEqual(result["outcome"], "failed")
                timing = result["group_timings"]["iphone-debug"]
                self.assertNotIn("setup_failure_step", timing)
                self.assertNotIn("setup_failure_command", timing)
                line = next(line for line in shadow.markdown(result).splitlines() if line.startswith("| iphone-debug |"))
                self.assertTrue(line.endswith("| unknown | unknown |"), line)

    def test_historical_shared_head_writes_a_suppressed_plan_and_reason(self):
        with tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
            temporary = Path(raw)
            context, _api, _reader = plan_fixture(temporary, stack)
            stack.enter_context(patch.object(shadow, "git", return_value=HEAD))
            self.assertEqual(shadow.plan_run(context, temporary / "plan", shared=True), 0)
            scheduling = json.loads((temporary / "plan/plan.json").read_text())
            self.assertFalse(scheduling["execute"])
            self.assertIn("predates the complete", scheduling["not_run_reason"])
            record = shadow.aggregate(scheduling, [], "skipped")
            self.assertEqual(record["outcome"], "not-run")
            self.assertIn("predates the complete", shadow.markdown(record))

    def test_hosted_stages_require_runner_temp_before_any_filesystem_action(self):
        for phase in ("stage", "setup", "plan", "plan-shared", "build", "producer-record", "select-archive", "run", "aggregate", "cleanup"):
            with self.subTest(phase=phase), patch.dict(os.environ, {}, clear=True), \
                    patch.object(shadow, "git", side_effect=AssertionError("stage touched git")), \
                    patch.object(shadow, "setup", side_effect=AssertionError("setup ran")), \
                    patch.object(shadow, "cleanup", side_effect=AssertionError("cleanup ran")):
                self.assertEqual(shadow.main([phase]), 1)

    def test_hosted_producer_passes_the_filtered_build_environment_to_the_runner(self):
        scheduling = shared_plan()
        with tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
            temporary = Path(raw)
            stack.enter_context(patch.object(shadow, "current_control", return_value=(None, scheduling["control"])))
            stack.enter_context(patch.object(shadow, "job_started_epoch", return_value=time.time()))
            stack.enter_context(patch("strict_e2e_build.smoke_source_identity", return_value=scheduling["tested_source"]))
            stack.enter_context(patch("ci_build_archive.workspace_preflight"))
            stack.enter_context(patch("ci_build_archive.disk_check"))
            def build(**options):
                options["execute"](["synthetic-build"], log_path=temporary / "build.log", environment={"PATH": "/filtered"})
                return {"identity": {"source": scheduling["tested_source"]}}, {
                    "manifest_sha256": "d" * 64, "archive_sha256": "e" * 64}
            stack.enter_context(patch("strict_e2e_build.build_smoke_archive", side_effect=build))
            run = stack.enter_context(patch("strict_e2e_runner_support.run_runner", return_value=0))
            self.assertEqual(shadow.run_producer(scheduling, dict(environment(), SMOKE_CONFIGURATION="Debug"), temporary), 0)
            self.assertEqual(run.call_args.kwargs["environment"], {"PATH": "/filtered"})

    def test_archive_loader_checks_the_explicit_expected_control(self):
        import strict_e2e_build as build
        identity = {"source": {"head_sha": HEAD}, "configuration": "Debug"}
        receipt = {"schema_version": 2, "kind": "smoke-archive", "identity": identity, "control": {"run_id": "wrong"},
                   "architectures": ["arm64"], "signing_mode": "adhoc", "private_configuration_present": False,
                   "xctestrun": "one.xctestrun", "products": [], "archive_sha256": "f" * 64, "source_root": "/source"}
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            shadow.write_json(root / build.SMOKE_RECEIPT, receipt)
            with patch.object(build, "workspace_preflight"), patch.object(build, "smoke_build_identity", return_value=identity), \
                    patch.object(build, "smoke_execution_identity", side_effect=AssertionError("unadmitted control reached simulator")):
                with self.assertRaisesRegex(ValueError, "control provenance differs"):
                    build.load_smoke_archive(root, "Debug", "platform=iOS Simulator,id=synthetic", "iphone", root,
                                             control={"run_id": "200"})

    def test_runner_child_receives_only_the_explicit_build_environment(self):
        import sys
        from strict_e2e_runner_support import run_runner
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            with patch.dict(os.environ, {"UI_TEST_SYNTHETIC": "ambient"}):
                code = run_runner([sys.executable, "-c", "import os; print(os.environ.get('UI_TEST_SYNTHETIC', 'absent'))"],
                                  root, root / "runner.log", timeout_seconds=10, environment={"PATH": "/filtered"})
            self.assertEqual(code, 0)
            self.assertEqual((root / "runner.log").read_text().strip(), "absent")

    def test_shared_plan_refuses_tested_heads_without_the_complete_producer_contract(self):
        capabilities = ("SMOKE_ARCHIVE_VERSION = 2", "SMOKE_SOURCE_PLIST_PREFLIGHT_VERSION = 1", "SMOKE_EXPECTED_CONTROL_VERSION = 1")
        for version in ("", *("\n".join(value for value in capabilities if value != missing) for missing in capabilities),
                        "\n".join(capabilities)):
            with self.subTest(version=version), patch.object(shadow, "git", return_value=version), \
                    patch.object(shadow, "source_at_commit", return_value={"head_sha": HEAD}), \
                    patch.object(shadow, "authoritative_control", return_value={"run_id": "200"}) as admission:
                scheduling = plan()
                if all(value in version for value in capabilities):
                    shadow.plan_shared(scheduling, environment(), None)
                    self.assertEqual(scheduling["build_mode"], shadow.ARCHIVE_MODE)
                else:
                    shadow.plan_shared(scheduling, environment(), None)
                    self.assertFalse(scheduling["execute"])
                    self.assertIn("predates the complete", scheduling["not_run_reason"])
                    admission.assert_not_called()

    def test_generic_producer_checks_source_server_fields_before_and_after_compilation(self):
        import strict_e2e_build as build
        for defect in (None, "before", "after", "symlink"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                source = root / "source"
                plist = source / "immichSlides/Info.plist"
                plist.parent.mkdir(parents=True)
                values = {key: "$(" + key + ")" for key in ("IMMICH_SERVER_URL", "IMMICH_API_KEY")}
                plist.write_bytes(plistlib.dumps(dict(values, IMMICH_API_KEY="synthetic-key") if defect == "before" else values))
                if defect == "symlink":
                    target = source / "synthetic.plist"
                    target.write_bytes(plist.read_bytes())
                    plist.unlink()
                    plist.symlink_to(target)
                derived = root / "derived"
                def compile(**_options):
                    products = derived / "Build/Products"
                    app = products / "Debug-iphonesimulator/immichSlides.app"
                    app.mkdir(parents=True)
                    (app / "Info.plist").write_bytes(plistlib.dumps({key: "" for key in values}))
                    (app / "immichSlides").write_bytes(b"synthetic-binary")
                    (products / "one.xctestrun").write_bytes(b"synthetic-run")
                    if defect == "after":
                        plist.write_bytes(plistlib.dumps(dict(values, IMMICH_SERVER_URL="synthetic-server")))
                    return {"signing_mode": "adhoc", "xctestrun": "one.xctestrun"}
                identity = {"configuration": "Debug", "source": {"head_sha": HEAD}}
                with patch.object(build, "workspace_preflight"), patch.object(build, "smoke_build_identity", return_value=identity), \
                        patch.object(build, "warm_up", side_effect=compile) as compilation, \
                        patch.object(build.subprocess, "check_output", return_value="arm64"):
                    options = dict(root=source, configuration="Debug", control={}, derived=derived, packages=root / "packages",
                                   output=root / "output", execute=None)
                    if defect is None:
                        build.build_smoke_archive(**options)
                        self.assertTrue((root / "output/archive/manifest.json").is_file())
                    else:
                        with self.assertRaisesRegex(ValueError, "source app plist"):
                            build.build_smoke_archive(**options)
                        self.assertFalse((root / "output/archive/manifest.json").exists())
                        if defect in {"before", "symlink"}:
                            compilation.assert_not_called()

    def test_producer_cleanup_refusal_preserves_owned_products(self):
        from strict_e2e_runner_support import RunnerGroupCleanupError
        scheduling = dict(plan(), build_mode=shadow.ARCHIVE_MODE, tested_source={"head_sha": HEAD}, control={"run_id": "200"})
        with tempfile.TemporaryDirectory() as raw:
            temporary = Path(raw)
            def build(**options):
                options["execute"](["synthetic-build"], log_path=temporary / "build.log")
            with patch.object(shadow, "current_control", return_value=(None, scheduling["control"])), \
                    patch.object(shadow, "job_started_epoch", return_value=time.time()), \
                    patch("strict_e2e_build.smoke_source_identity", return_value=scheduling["tested_source"]), \
                    patch("strict_e2e_build.build_smoke_archive", side_effect=build), \
                    patch("ci_build_archive.workspace_preflight"), patch("ci_build_archive.disk_check"), \
                    patch("strict_e2e_runner_support.run_runner", side_effect=RunnerGroupCleanupError("synthetic refusal")):
                with self.assertRaises(RunnerGroupCleanupError):
                    shadow.run_producer(scheduling, dict(environment(), SMOKE_CONFIGURATION="Debug"), temporary)
            self.assertTrue((temporary / "smoke-cleanup-blocked").exists())
            with self.assertRaisesRegex(ValueError, "cleanup unverified"):
                shadow.cleanup(dict(environment(), SMOKE_CONFIGURATION="Debug"), temporary)
            self.assertTrue((temporary / "smoke-producer/ownership.json").is_file())


    def test_shared_control_requires_authoritative_main_run_and_keeps_the_staged_source_separate(self):
        with tempfile.TemporaryDirectory() as raw:
            context = dict(environment(), RUNNER_TEMP=raw, GITHUB_SHA="b" * 40,
                           GITHUB_WORKFLOW_REF=REPOSITORY + "/" + shadow.WORKFLOW + "@refs/heads/main")
            run = dict(run_metadata(), id=200, path=shadow.WORKFLOW, workflow_id=8, head_sha="b" * 40, event="workflow_dispatch")
            workflow = {"id": 8, "path": shadow.WORKFLOW}
            api = SimpleNamespace(repo=lambda path: run if path == "actions/runs/200" else workflow)
            with patch.object(shadow.subprocess, "call", return_value=0), patch.object(shadow, "git", return_value="c" * 40):
                control = shadow.authoritative_control(context, api)
                self.assertEqual((control["api_head_sha"], control["control_source_sha"], control["run_id"]),
                                 ("b" * 40, "c" * 40, "200"))
                for field, value in (("head_sha", HEAD), ("head_branch", "topic"), ("run_attempt", 2),
                                     ("workflow_id", 9), ("path", ".github/workflows/other.yml"),
                                     ("repository", {"full_name": "other/repo"})):
                    changed = dict(run, **{field: value})
                    bad_api = SimpleNamespace(repo=lambda path: changed if path == "actions/runs/200" else workflow)
                    with self.subTest(field=field), self.assertRaisesRegex(ValueError, "control API provenance"):
                        shadow.authoritative_control(context, bad_api)
            with patch.object(shadow.subprocess, "call", return_value=1), self.assertRaisesRegex(ValueError, "admitted main"):
                shadow.authoritative_control(context, api)

    def test_smoke_archive_gate_rejects_hash_inventory_links_configuration_and_signature_before_admission(self):
        import ci_build_archive as archive
        import strict_e2e_build as build
        for defect in (None, "manifest", "tar", "inventory", "link", "configuration", "signature"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                products = root / "Products"
                app = products / "Release-iphonesimulator/immichSlides.app"
                app.mkdir(parents=True)
                (app / "Info.plist").write_bytes(plistlib.dumps({"IMMICH_SERVER_URL": "", "IMMICH_API_KEY": ""}))
                (products / "one.xctestrun").write_bytes(b"synthetic")
                identity = {"configuration": "Release", "source": {"head_sha": HEAD}}
                receipt = {"schema_version": 2, "kind": "smoke-archive", "identity": identity, "control": {},
                    "architectures": ["arm64"], "signing_mode": "adhoc", "private_configuration_present": False,
                    "xctestrun": "one.xctestrun", "products": archive.inventory(products), "source_root": "/retired/source"}
                directory = root / "archive"
                directory.mkdir()
                archive.pack_products(products, directory / "build.tar.gz")
                receipt["archive_sha256"] = archive.file_hash(directory / "build.tar.gz")
                if defect == "inventory":
                    next(entry for entry in receipt["products"] if entry["kind"] == "file")["sha256"] = "f" * 64
                if defect == "link":
                    (products / "escape").symlink_to("../../outside")
                    with tarfile.open(directory / "build.tar.gz", "w:gz", dereference=False) as packed:
                        packed.add(products, arcname="Products")
                    receipt["products"].append({"path": "Products/escape", "kind": "symlink", "mode": 511, "target": "../../outside"})
                    receipt["archive_sha256"] = archive.file_hash(directory / "build.tar.gz")
                if defect == "configuration":
                    receipt["identity"]["configuration"] = "Debug"
                shadow.write_json(directory / "manifest.json", receipt)
                digest = archive.file_hash(directory / "manifest.json")
                if defect == "manifest":
                    with (directory / "manifest.json").open("a") as handle:
                        handle.write("\n")
                if defect == "tar":
                    with (directory / "build.tar.gz").open("ab") as handle:
                        handle.write(b"changed")
                with patch("ci_build_archive.measure_signing", side_effect=ContractError("signature") if defect == "signature" else None,
                           return_value="adhoc"):
                    if defect is None:
                        admitted = shadow.verify_smoke_archive(directory, root / "relocated", expected_identity=identity,
                                                               control={}, manifest_hash=digest)
                        build.validate_warm_products(root / "relocated", admitted)
                        (root / "relocated/Build/Products/one.xctestrun").write_bytes(b"changed")
                        with self.assertRaisesRegex(build.CommandError, "Products changed"):
                            build.validate_warm_products(root / "relocated", admitted)
                    else:
                        with self.assertRaises(ValueError):
                            shadow.verify_smoke_archive(directory, root / "relocated", expected_identity={"configuration": "Release", "source": {"head_sha": HEAD}},
                                                        control={}, manifest_hash=digest)
                        self.assertFalse((root / "relocated" / build.SMOKE_RECEIPT).exists())

    def test_archive_timing_requires_provenance_and_failed_producers_stay_red(self):
        scheduling = plan()
        scheduling.update(build_mode=shadow.ARCHIVE_MODE, control={"run_id": "200"}, tested_source={"head_sha": HEAD})
        provenance = {"configuration": "Debug", "artifact_id": 91, "manifest_sha256": "d" * 64,
                      "archive_sha256": "e" * 64, "control": scheduling["control"], "source": scheduling["tested_source"],
                      "producer_job": "smoke-shadow-ios-debug"}
        producers = [{"schema_version": 1, "configuration": configuration, "outcome": "passed",
                      "provenance": dict(provenance, configuration=configuration, producer_job="smoke-shadow-ios-" + configuration.lower()),
                      "timing": {"build_seconds": 10, "pack_seconds": 1, "upload_seconds": 2, "job_elapsed_seconds": 20}}
                     for configuration in ("Debug", "Release")]
        records = group_records(scheduling)
        records[0].update(schema_version=2, timing_mode=shadow.ARCHIVE_MODE, build_provenance=provenance,
                          transfer_seconds=2, verify_seconds=1)
        records[0]["phases"][0]["name"] = "archive-verify"
        good = shadow.aggregate(scheduling, records, "success", producers=producers, producer_results={"Debug": "success", "Release": "success"})
        self.assertEqual((good["outcome"], good["executed"]), ("passed", True))
        self.assertEqual(good["shared_build_runner_seconds"], 20)
        self.assertIn("archive-verify", str(good["group_timings"]))
        unknown_records, unknown_producers = copy.deepcopy(records), copy.deepcopy(producers)
        unknown_records[0]["transfer_seconds"] = None
        unknown_records[0]["verify_seconds"] = "incomplete"
        unknown_producers[0]["timing"]["upload_seconds"] = None
        unknown = shadow.aggregate(scheduling, unknown_records, "success", producers=unknown_producers,
                                   producer_results={"Debug": "success", "Release": "success"})
        self.assertEqual(unknown["outcome"], "passed")
        self.assertIsNone(unknown["group_timings"]["iphone-debug"]["transfer_seconds"])
        self.assertIsNone(unknown["group_timings"]["iphone-debug"]["verify_seconds"])
        for index in (0, 1):
            for field in ("job_started_epoch", "job_elapsed_seconds", "phase-0", "phase-1"):
                with self.subTest(group=records[index]["group"]["id"], field=field):
                    invalid = copy.deepcopy(records)
                    if field.startswith("phase-"):
                        invalid[index]["phases"][int(field[-1])]["elapsed_seconds"] = None
                    else:
                        invalid[index][field] = None
                    result = shadow.aggregate(scheduling, invalid, "success", producers=producers,
                                              producer_results={"Debug": "success", "Release": "success"})
                    self.assertIn("invalid group job timing: " + records[index]["group"]["id"], result["errors"])
                    self.assertEqual(result["outcome"], "failed")
        rejected = copy.deepcopy(records)
        rejected[0].update(build_provenance=None, runner_exit_code=1, errors=["archive-verification-failed"])
        rejected[0]["phases"] = [{"name": "archive-verify", "elapsed_seconds": 12, "exit_code": 1}]
        rejected[0]["flows"][0].update(outcome="not-run", elapsed_seconds=None, executed=False, official_execution_complete=False)
        rejection = shadow.aggregate(scheduling, rejected, "failure", producers=producers,
                                     producer_results={"Debug": "success", "Release": "success"})
        self.assertIn("archive admission failed: iphone-debug", rejection["errors"])
        self.assertIn("iphone-debug: archive-verification-failed", rejection["errors"])
        self.assertEqual(rejection["group_timings"]["iphone-debug"]["phases"], rejected[0]["phases"])
        for defect in ("missing-provenance", "zero-warm", "failed-producer", "missing-producer", "missing-group", "partial"):
            changed, builds = copy.deepcopy(records), copy.deepcopy(producers)
            if defect == "missing-provenance":
                changed[0].pop("build_provenance")
            elif defect == "zero-warm":
                changed[0]["phases"][0].update(name="warm-up", elapsed_seconds=0)
            elif defect == "failed-producer":
                builds[0]["outcome"] = "failed"
            elif defect == "missing-producer":
                builds.pop(0)
            elif defect == "missing-group":
                changed.pop()
            elif defect == "partial":
                changed[0]["selection"] = "single-flow"
                changed.append(copy.deepcopy(changed[0]))
            result = shadow.aggregate(scheduling, changed, "success", producers=builds, producer_results={"Debug": "success", "Release": "success"})
            with self.subTest(defect=defect):
                self.assertEqual(result["outcome"], "failed")
                if defect in {"missing-producer", "failed-producer"}:
                    self.assertEqual(result["flows"][0]["outcome"], "not-run")
        failed_api = shadow.aggregate(scheduling, records, "success", producers=producers,
                                      producer_results={"Debug": "failure", "Release": "success"})
        self.assertEqual(failed_api["outcome"], "failed")

    def test_smoke_archive_manifest_binds_tested_source_and_control_independently(self):
        import strict_e2e_build as build
        identity = {"source": {"head_sha": HEAD, "tree_sha": "d" * 40, "source_sha256": "e" * 64, "clean": True},
                    "configuration": "Debug"}
        control = {"repository": REPOSITORY, "run_id": "200", "attempt": 1, "workflow_id": 8,
                   "workflow_path": shadow.WORKFLOW, "api_head_sha": "b" * 40, "main_admitted": True}
        receipt = {"schema_version": 2, "kind": "smoke-archive", "identity": identity, "control": control,
                   "architectures": ["arm64"], "signing_mode": "adhoc", "private_configuration_present": False,
                   "xctestrun": "one.xctestrun", "products": [{"path": "Products", "mode": 493, "kind": "directory"}],
                   "archive_sha256": "f" * 64, "source_root": "/private/synthetic/source"}
        build.validate_smoke_receipt(receipt, identity, control)
        cases = [("source", "head_sha", "b" * 40), ("source", "head_sha", "f" * 40),
                 ("source", "tree_sha", "f" * 40), ("source", "source_sha256", "f" * 64),
                 ("control", "attempt", 2), ("control", "workflow_id", 9),
                 ("control", "workflow_path", ".github/workflows/other.yml"), ("control", "api_head_sha", HEAD),
                 ("control", "main_admitted", False), ("configuration", None, "Release"),
                 ("signing_mode", None, "unsigned"), ("private_configuration_present", None, True)]
        for section, key, value in cases:
            changed = copy.deepcopy(receipt)
            if section == "source":
                changed["identity"]["source"][key] = value
            elif section == "configuration":
                changed["identity"][section] = value
            elif key:
                changed[section][key] = value
            else:
                changed[section] = value
            with self.subTest(section=section, key=key), self.assertRaises(ValueError):
                build.validate_smoke_receipt(changed, identity, control)

    def test_smoke_archive_api_provenance_requires_successful_configuration_producer(self):
        control = {"repository": REPOSITORY, "run_id": "200", "attempt": 1, "workflow_id": 8,
                   "workflow_path": shadow.WORKFLOW, "api_head_sha": "b" * 40,
                   "control_source_sha": "c" * 40, "main_admitted": True}
        metadata = {"id": 91, "name": "smoke-build-debug-200-1", "expired": False,
                    "workflow_run": {"id": 200, "head_sha": "b" * 40}}
        producer = {"name": "smoke-shadow-ios-debug", "conclusion": "success", "run_attempt": 1}
        shadow.validate_smoke_artifact(metadata, control, "Debug", 91, producer)
        for field, value in (("id", 92), ("name", "smoke-build-release-200-1"), ("expired", True),
                             ("workflow_run", {"id": 200, "head_sha": HEAD}),
                             ("workflow_run", {"id": 201, "head_sha": "b" * 40})):
            with self.subTest(field=field), self.assertRaises(ValueError):
                shadow.validate_smoke_artifact(dict(metadata, **{field: value}), control, "Debug", 91, producer)
        for change in ({"name": "smoke-shadow-ios-release"}, {"conclusion": "failure"}, {"run_attempt": 2}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                shadow.validate_smoke_artifact(metadata, control, "Debug", 91, dict(producer, **change))

    def test_aggregate_drops_invalid_optional_first_failure_without_changing_results(self):
        from ci_failure_diagnostics import unavailable_first_failure
        scheduling = plan()
        records = group_records(scheduling)
        records[0]["flows"][0].update(outcome="failed", failure_category="unknown")
        records[0].update(runner_exit_code=65, group_validation={"outcome": "failed", "reason": "test"})
        baseline = shadow.aggregate(scheduling, records, "failure")
        stale = unavailable_first_failure("xctest")
        stale["element"] = "retired-control"
        for receipt in (stale, None, {"schema_version": 1}):
            with self.subTest(receipt=receipt):
                changed = copy.deepcopy(records)
                changed[0]["flows"][0]["first_failure"] = receipt
                result = shadow.aggregate(scheduling, changed, "failure")
                self.assertEqual((result["outcome"], result["executed"]), ("failed", True))
                self.assertNotIn("first_failure", result["flows"][0])
                for key in ("outcome", "executed", "errors", "flows"):
                    self.assertEqual(result[key], baseline[key])


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
        self.assertEqual((passing["outcome"], passing["executed"]), ("passed", True))
        records[0]["runner_exit_code"] = 65
        records[0]["flows"][0].update(outcome="failed", failure_category="assertion",
                                      first_failure_message="smoke: expected | actual\n<script>")
        result = shadow.aggregate(scheduling, records, "failure")
        self.assertEqual(result["outcome"], "failed")
        self.assertTrue(result["executed"])
        self.assertEqual(result["flows"][0]["first_failure_message"], "smoke: expected | actual\n<script>")
        markdown = shadow.markdown(result)
        self.assertIn("expected &#124; actual", markdown)
        self.assertNotIn("<script>", markdown)
        self.assertIn(HEAD, markdown)
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
        failed_job = shadow.aggregate(scheduling, records, "failure")
        self.assertEqual(failed_job["outcome"], "failed")


    def test_plan_ancestor_guard_rejects_before_loading_manifest(self):
        with tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
            context, _api, reader = plan_fixture(Path(raw), stack, ancestor=1)
            with self.assertRaisesRegex(ContractError, "not an ancestor of main"):
                shadow.plan_run(context, Path(raw) / "plan")
            reader.assert_not_called()


    def test_plan_scan_failure_never_publishes_safe_outputs(self):
        with tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
            context, _api, _reader = plan_fixture(Path(raw), stack)
            with patch("run_strict_e2e.write_sensitive_scan", side_effect=ValueError("synthetic scan refusal")):
                with self.assertRaisesRegex(ValueError, "synthetic scan refusal"):
                    shadow.plan_run(context, Path(raw) / "plan")
            self.assertFalse((Path(raw) / "output").exists())

    def test_skipped_plan_rejects_artifacts_and_failed_matrix(self):
        scheduling = dict(plan(), execute=False, not_run_reason="Main head already tested; all groups skipped.")
        for records, matrix in ((group_records(scheduling), "skipped"), ([], "failure")):
            with self.subTest(matrix=matrix, records=bool(records)):
                result = shadow.aggregate(scheduling, records, matrix)
                self.assertIn("unexpected execution on skipped smoke", result["errors"])
                self.assertEqual(result["outcome"], "failed")

    def test_group_refuses_suppressed_plan_before_creating_simulator(self):
        scheduling = dict(plan(), execute=False, not_run_reason="Main head already tested; all groups skipped.")
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
            root = temporary / "smoke-execution.noindex"
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

    def test_cleanup_failure_names_only_the_closed_step_and_retains_owned_inputs(self):
        for step in ("runner-cleanup", "ownership", "simctl-shutdown", "simctl-delete", "lsof-timeout", "lsof-holders",
                     "lsof-unavailable", "lsof-stderr", "lsof-empty", "lsof-exit", "lsof-exit-output", "remove"):
            with self.subTest(step=step), tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
                temporary = Path(raw)
                root = temporary / "smoke-execution.noindex"
                shadow.write_json(root / "ownership.json", shadow.shadow_context(environment()) if step != "ownership" else {})
                if step == "runner-cleanup":
                    (temporary / "smoke-cleanup-blocked").touch()
                def run(argv, **options):
                    if argv[:2] == ["xcrun", "simctl"]:
                        if argv[2] == "shutdown":
                            self.assertIs(options["stdout"], subprocess.DEVNULL)
                            self.assertIs(options["stderr"], subprocess.DEVNULL)
                        else:
                            self.assertEqual(options, {"check": True, "timeout": 60})
                        if step == "simctl-" + argv[2]:
                            raise subprocess.TimeoutExpired(["PRIVATE_SENTINEL"], 60, output="PRIVATE_SENTINEL")
                    elif step == "lsof-timeout":
                        raise subprocess.TimeoutExpired(["PRIVATE_SENTINEL"], 30, output="PRIVATE_SENTINEL")
                    elif step == "lsof-unavailable":
                        raise OSError("PRIVATE_SENTINEL")
                    elif step == "lsof-stderr":
                        return SimpleNamespace(returncode=1, stdout=b"", stderr=b"PRIVATE_SENTINEL")
                    elif step == "lsof-empty":
                        return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
                    elif step in {"lsof-exit", "lsof-exit-output"}:
                        return SimpleNamespace(returncode=2, stdout=b"cPython3\n" if step == "lsof-exit-output" else b"", stderr=b"")
                    return SimpleNamespace(returncode=1, stdout=(b"p123456\ncmdworker_PRIVATE_SENTINEL\ncPython3\n"
                        b"n/private/PRIVATE_SENTINEL\n" if step == "lsof-holders" else b""), stderr=b"")
                stack.enter_context(patch.object(shadow.subprocess, "run", side_effect=run))
                remove = stack.enter_context(patch.object(shadow.shutil, "rmtree", side_effect=OSError("PRIVATE_SENTINEL")))
                log = stack.enter_context(redirect_stderr(io.StringIO()))
                with self.assertRaises((OSError, ValueError, subprocess.SubprocessError)):
                    shadow.cleanup(dict(environment(), UI_SIMULATOR="PRIVATE_SENTINEL"), temporary)
                expected = "lsof-probe" if step in {"lsof-unavailable", "lsof-stderr", "lsof-empty", "lsof-exit", "lsof-exit-output"} else step
                holder_log = "cleanup-holder: family=python\ncleanup-holder: family=spotlight\n" if step == "lsof-holders" else ""
                self.assertEqual(log.getvalue(), f"cleanup-failed: step={expected}\n" + holder_log)
                self.assertNotIn("PRIVATE_SENTINEL", log.getvalue())
                self.assertNotIn("123456", log.getvalue())
                self.assertTrue(root.is_dir())
                if step != "remove":
                    remove.assert_not_called()

    def test_cleanup_reprobes_only_transient_spotlight_holders_once_before_deleting(self):
        spotlight = SimpleNamespace(returncode=0, stdout=b"cmdworker_shared\n", stderr=b"")
        clear = SimpleNamespace(returncode=1, stdout=b"", stderr=b"")
        cases = [
            ("clear", [spotlight, clear], 1, None, []),
            ("held", [spotlight, spotlight, clear], 1, "lsof-holders", ["spotlight"]),
            ("mixed", [SimpleNamespace(returncode=0, stdout=b"cmds\ncxcodebuild\n", stderr=b"")],
             0, "lsof-holders", ["spotlight", "xcode"]),
            ("stderr", [SimpleNamespace(returncode=0, stdout=b"cmds\n", stderr=b"PRIVATE_SENTINEL")],
             0, "lsof-holders", ["spotlight"]),
            ("timeout", [spotlight, subprocess.TimeoutExpired(["PRIVATE_SENTINEL"], 30)],
             1, "lsof-timeout", []),
            ("other", [SimpleNamespace(returncode=0, stdout=b"cxcodebuild\n", stderr=b"")],
             0, "lsof-holders", ["xcode"]),
            ("exit-one", [SimpleNamespace(returncode=1, stdout=b"cmds\n", stderr=b"")],
             0, "lsof-holders", ["spotlight"]),
            ("exit-other", [SimpleNamespace(returncode=2, stdout=b"cmds\n", stderr=b"")],
             0, "lsof-probe", []),
            ("retry-unavailable", [spotlight, OSError("PRIVATE_SENTINEL")], 1, "lsof-probe", []),
            ("last-family", [spotlight, SimpleNamespace(returncode=0, stdout=b"cPython3\n", stderr=b"")],
             1, "lsof-holders", ["python"]),
        ]
        for producer in (False, True):
            for case, probes, retries, failure, families in cases:
                with self.subTest(producer=producer, case=case), tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
                    temporary = Path(raw)
                    root = temporary / ("smoke-producer" if producer else "smoke-execution.noindex")
                    context = dict(environment(), **({"SMOKE_CONFIGURATION": "Debug"} if producer else {}))
                    shadow.write_json(root / "ownership.json", shadow.shadow_context(context))
                    events = []
                    remaining = iter(probes)
                    def probe(argv, **options):
                        self.assertEqual(argv, ["lsof", "-Fc", "+D", str(root)])
                        self.assertEqual(options, {"capture_output": True, "timeout": 30})
                        events.append("probe")
                        value = next(remaining)
                        if isinstance(value, Exception):
                            raise value
                        return value
                    run = stack.enter_context(patch.object(shadow.subprocess, "run", side_effect=probe))
                    sleep = stack.enter_context(patch.object(shadow.time, "sleep", side_effect=lambda _seconds: events.append("sleep")))
                    log = stack.enter_context(redirect_stderr(io.StringIO()))
                    if failure:
                        with self.assertRaises((OSError, ValueError, subprocess.SubprocessError)):
                            shadow.cleanup(context, temporary)
                        self.assertTrue(root.is_dir())
                    else:
                        self.assertEqual(shadow.cleanup(context, temporary), 0)
                        self.assertFalse(root.exists())
                    self.assertEqual(run.call_count, 1 + retries)
                    self.assertEqual(sleep.call_args_list, [unittest.mock.call(5)] * retries)
                    self.assertEqual(events, ["probe"] + ["sleep", "probe"] * retries)
                    expected = "cleanup-retry: family=spotlight attempt=1\n" * retries
                    if failure:
                        expected += f"cleanup-failed: step={failure}\n"
                    expected += "".join(f"cleanup-holder: family={family}\n" for family in families)
                    self.assertEqual(log.getvalue(), expected)

    def test_cleanup_holder_families_use_only_lsof_command_fields_and_closed_names(self):
        for commands, expected in ((b"cmds\ncmds_stores\ncmdworker_shared\n", ["spotlight"]),
                (b"cCoreSimulatorService\ncCoreSimulatorBridge\nclaunchd_sim\ncsimctl\n", ["simulator"]),
                (b"ccom.apple.CoreSimulator.CoreSimulatorService\n", ["simulator"]),
                (b"cxcodebuild\ncXCBBuildService\nctestmanagerd\n", ["xcode"]),
                (b"cPython\ncpython3.9\n", ["python"]), (b"cPRIVATE_SENTINEL\n", ["other"]),
                (b"p123456\nnmdworker_PRIVATE_SENTINEL\nf42\n", ["other"]), (b"", ["other"]),
                (b"cmds\ncPython3\ncxcodebuild\ncsimctl\ncPRIVATE_SENTINEL\ncmds\n",
                 ["other", "python", "simulator", "spotlight", "xcode"])):
            with self.subTest(expected=expected):
                self.assertEqual(shadow.cleanup_holder_families(commands), expected)

    def test_job_clock_binds_deadline_to_current_attempt_and_group(self):
        job = {"id": 1, "run_id": 200, "run_attempt": 1, "name": "smoke-shadow-iphone-debug",
               "started_at": "1970-01-01T00:16:40Z"}
        api = SimpleNamespace(repo=Mock(return_value={"total_count": 1, "jobs": [job]}))
        with patch("ci_smoke_shadow.GitHub", return_value=api), patch.object(shadow.time, "time", return_value=1100):
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

    def test_group_setup_time_consumes_the_selected_budget(self):
        smoke_manifest = json.loads((shadow.ROOT / shadow.MANIFEST).read_text())
        scheduling = shadow.make_plan(environment(), smoke_manifest, "c" * 64)
        expected = {"iphone-debug": 27, "iphone-release": 27, "ipad-debug": 27,
                    "ipad-release": 27, "tv-debug": 22, "tv-release": 22}
        self.assertEqual({group["id"] for group in scheduling["groups"]}, set(expected))
        for group_id, minutes in expected.items():
            for setup_seconds in (20 * 60, minutes * 60 + 1):
                with self.subTest(group=group_id, setup_seconds=setup_seconds), \
                        tempfile.TemporaryDirectory() as raw, patch.object(shadow, "git", return_value=HEAD), \
                        patch("ci_build_archive.file_hash", return_value="c" * 64), \
                        patch("ci_build_archive.workspace_preflight"), patch("run_offline_unit_tests.ensure_disk_for_xcodebuild"), \
                        patch("ci_simulator.create_and_boot_simulator", return_value="synthetic"), \
                        patch.object(shadow.time, "time", return_value=2000), \
                        patch.object(shadow, "job_started_epoch", return_value=2000 - setup_seconds), \
                        patch("strict_e2e_runner_support.run_runner", return_value=65) as runner:
                    self.assertEqual(shadow.run_group(scheduling, dict(environment(), SMOKE_GROUP=group_id), Path(raw)), 1)
                    record = json.loads((Path(raw) / "smoke-records/group.json").read_text())
                    if setup_seconds < minutes * 60:
                        self.assertEqual(runner.call_count, 1)
                        self.assertEqual(runner.call_args.kwargs["timeout_seconds"], minutes * 60 - setup_seconds)
                        self.assertEqual(record["runner_exit_code"], 65)
                    else:
                        runner.assert_not_called()
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
                        patch("strict_e2e_runner_support.run_runner", side_effect=invoke) as runner:
                    self.assertEqual(shadow.run_group(plan(), context, temporary), int(clock_failure))
                    self.assertFalse("SMOKE_TOKEN" in os.environ, "runner environment excludes the clock token")
                    self.assertFalse("SMOKE_TOKEN" in context, "control context excludes the clock token")
                    if clock_failure:
                        runner.assert_not_called()


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
                 ("First-boot form must show the API Key field.", "assertion"),
                 ("Smoke flow: control appears: filterSummary.person.button.", "assertion")]
        for message, category in cases:
            with self.subTest(category=category), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                flow, destination = runner_evidence(directory, failed=True, message=message)
                rows, errors = shadow.read_runner_flows(directory, plan(), [flow], destination)
                self.assertEqual(errors, [])
                self.assertEqual((rows[0]["outcome"], rows[0]["executed"], rows[0]["failure_category"]),
                                 ("failed", True, category))
                self.assertEqual(rows[0]["first_failure_message"], message)
                scheduling = plan()
                groups = group_records(scheduling)
                groups[0]["flows"] = rows
                groups[0]["runner_exit_code"] = 65
                groups[0]["group_validation"] = {"outcome": "failed", "reason": "failed first result"}
                result = shadow.aggregate(scheduling, groups, "failure")
                self.assertEqual(result["outcome"], "failed")
                self.assertEqual(result["flows"][0]["first_failure_message"], message)
                self.assertIn(message, shadow.markdown(result))
                compact = directory / "compact"
                shadow.write_json(compact / "shadow.json", result)
                (compact / "summary.md").write_text(shadow.markdown(result))
                shadow.scan_records(compact)
                self.assertEqual(json.loads((compact / "sensitive-scan.json").read_text())["result"], "PASS")

    def test_group_copies_only_validated_first_failure_json_and_privacy_approved_pngs(self):
        import io
        from PIL import Image
        from ci_build_archive import file_hash
        from ci_failure_diagnostics import render_first_failure, unavailable_first_failure
        picture = io.BytesIO()
        Image.new("RGB", (64, 32), "blue").save(picture, format="PNG")
        png = picture.getvalue()
        safe = unavailable_first_failure("xctest", step="query-element", element="slideshow.control.settings.button")
        safe["action"] = "tap"
        safe["timing"].update(since_action_issued_seconds=16, since_action_returned_seconds=7,
                              action_duration_seconds=9, wait_elapsed_seconds=7, deadline_seconds=7)
        safe["state"].update(app="running-foreground", surface="playback", observation="failure-snapshot")
        safe["screenshot"].update(status="captured", width=64, height=32, bytes=len(png))
        for defect in (None, "withheld-firstboot", "withheld-unknown", "withheld-private-controls", "invalid-receipt",
                       "forged-firstboot", "symlink-image", "noncanonical-image"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as raw:
                temporary = Path(raw)
                receipt = copy.deepcopy(safe)
                if defect and defect.startswith("withheld-"):
                    receipt["screenshot"] = {"status": "withheld-privacy", "width": None, "height": None, "bytes": None}
                    receipt["state"]["surface"] = "firstboot" if defect == "withheld-firstboot" else "unknown" if defect == "withheld-unknown" else "playback-settings"
                elif defect == "invalid-receipt":
                    receipt["element"] = "private-input-sentinel"
                elif defect == "forged-firstboot":
                    receipt["state"]["surface"] = "firstboot"
                context = dict(environment(), SMOKE_GROUP="iphone-debug", GITHUB_OUTPUT=str(temporary / "output"))

                def invoke(command, *_args, **_kwargs):
                    if "--test-without-building" in command:
                        evidence = Path(command[command.index("--evidence-dir") + 1])
                        runner_evidence(evidence, failed=True, message="Smoke flow: action exceeded the shared hang guard.",
                                        first_failure=receipt)
                        images = evidence / "phone-one/first-failure"
                        images.mkdir()
                        (images / "0.png").write_bytes(png + (b"private-input-sentinel" if defect == "noncanonical-image" else b""))
                        (images / "unselected.png").write_bytes(png)
                        (images / "raw.log").write_text("private-input-sentinel")
                        if defect == "symlink-image":
                            (images / "0.png").unlink()
                            (images / "0.png").symlink_to(images / "unselected.png")
                    return 65 if "--test-without-building" in command else 0

                def bound_hash(path):
                    return "c" * 64 if path == shadow.ROOT / shadow.MANIFEST else file_hash(path)

                with patch.object(shadow, "git", return_value=HEAD), \
                        patch.object(shadow, "job_started_epoch", return_value=time.time()), \
                        patch("ci_build_archive.file_hash", side_effect=bound_hash), \
                        patch("ci_build_archive.workspace_preflight"), patch("run_offline_unit_tests.ensure_disk_for_xcodebuild"), \
                        patch("ci_simulator.create_and_boot_simulator", return_value="synthetic"), \
                        patch("strict_e2e_runner_support.run_runner", side_effect=invoke):
                    self.assertEqual(shadow.run_group(plan(), context, temporary), 1)
                records = temporary / "smoke-records"
                group = json.loads((records / "group.json").read_text())
                row = group["flows"][0]
                self.assertEqual((group["runner_exit_code"], row["outcome"], row["executed"], row["exit_code"]), (65, "failed", True, 65))
                retained = sorted(records.rglob("*.png"))
                self.assertEqual(len(retained), 1 if defect is None else 0)
                if defect in {"invalid-receipt", "forged-firstboot"}:
                    self.assertNotIn("first_failure", row)
                elif defect in {"symlink-image", "noncanonical-image"}:
                    self.assertEqual(row["first_failure"]["screenshot"]["status"], "unavailable")
                else:
                    self.assertEqual(row["first_failure"], receipt)
                if retained:
                    self.assertEqual(retained[0].read_bytes(), png)
                    self.assertEqual(retained[0].relative_to(records).as_posix(), "failure-screenshots/first-failure-attempt-1/0.png")
                self.assertEqual(json.loads((records / "sensitive-scan.json").read_text())["result"], "PASS")
                self.assertFalse(any(path.suffix in {".log", ".xcresult"} for path in records.rglob("*")))
                self.assertNotIn("private-input-sentinel", (records / "group.json").read_text())
                groups = group_records(plan())
                groups[0] = group
                result = shadow.aggregate(plan(), groups, "failure")
                self.assertEqual((result["outcome"], result["executed"]), ("failed", True))
                if "first_failure" in row:
                    self.assertEqual(result["flows"][0]["first_failure"], row["first_failure"])
                    self.assertIn(render_first_failure(row["first_failure"]), shadow.markdown(result))

    def test_group_image_copy_and_upload_check_preserve_the_second_flow_index(self):
        import io
        from PIL import Image
        from ci_failure_diagnostics import unavailable_first_failure
        picture = io.BytesIO()
        Image.new("RGB", (64, 32), "blue").save(picture, format="PNG")
        png = picture.getvalue()
        group = group_records(plan())[0]
        second = copy.deepcopy(group["flows"][0])
        second.update(id="phone-two", selector="Smoke/testPhoneTwo", outcome="failed")
        receipt = unavailable_first_failure("xctest")
        receipt["state"].update(app="running-foreground", surface="playback")
        receipt["screenshot"].update(status="captured", width=64, height=32, bytes=len(png))
        second["first_failure"] = receipt
        group["flows"].append(second)
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            evidence, records = root / "evidence", root / "records"
            source = evidence / "phone-two/first-failure/0.png"
            source.parent.mkdir(parents=True)
            source.write_bytes(png)
            records.mkdir()
            shadow.copy_first_failure_images(evidence, records, group["flows"])
            shadow.write_json(records / "group.json", group)
            shadow.check_group_upload(records, group)
            retained = sorted(path.relative_to(records).as_posix() for path in records.rglob("*.png"))
            self.assertEqual(retained, ["failure-screenshots/first-failure-attempt-1/1.png"])
            self.assertEqual((records / retained[0]).read_bytes(), png)

    def test_group_upload_check_rejects_unbound_images_even_on_a_withheld_surface(self):
        import io
        from PIL import Image
        from ci_failure_diagnostics import unavailable_first_failure
        picture = io.BytesIO()
        Image.new("RGB", (64, 32), "blue").save(picture, format="PNG")
        with tempfile.TemporaryDirectory() as raw:
            records = Path(raw)
            group = group_records(plan())[0]
            row = group["flows"][0]
            row["first_failure"] = unavailable_first_failure("xctest")
            row["first_failure"]["screenshot"]["status"] = "withheld-privacy"
            shadow.write_json(records / "group.json", group)
            shadow.check_group_upload(records, group)
            image = records / "failure-screenshots/first-failure-attempt-1/0.png"
            image.parent.mkdir(parents=True)
            image.write_bytes(picture.getvalue())
            with self.assertRaisesRegex(ValueError, "invalid first failure package directory"):
                shadow.check_group_upload(records, group)

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

    def test_pretest_step_survives_projection_and_old_heads_render_unknown(self):
        import strict_e2e_smoke as smoke
        self.assertEqual(smoke.PRETEST_FAILURE_STEPS, shadow.PRETEST_FAILURE_STEPS)
        flows = json.loads((Path(__file__).resolve().parent / "smoke-flows.json").read_text())["flows"]
        for fixture in {fixture for flow in flows for fixture in flow["fixtures"]}:
            self.assertIn("fixture-service:" + fixture, smoke.PRETEST_FAILURE_STEPS)
            self.assertIn("fixture-service:" + fixture + ":timeout", smoke.PRETEST_FAILURE_STEPS)
        cases = [(step, "infrastructure") for step in ("absent", None, *sorted(shadow.PRETEST_FAILURE_STEPS))]
        cases.append(("first-failure-spool", "cleanup"))
        for step, kind in cases:
            with self.subTest(step=step, kind=kind), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                flow, destination = runner_evidence(directory, failed=step not in ("absent", None))
                result = json.loads((directory / "smoke-flow-results.json").read_text())["flows"][0]
                if step != "absent":
                    result["pretest_failure_step"] = step
                if step not in ("absent", None):
                    result.update(failure_kind=kind, official_execution_complete=False, elapsed_seconds=0)
                replace_runner_record(directory, result)
                rows, _ = shadow.read_runner_flows(directory, plan(), [flow], destination)
                if step == "absent":
                    self.assertNotIn("pretest_failure_step", rows[0])
                else:
                    self.assertEqual(step, rows[0]["pretest_failure_step"])
                records = group_records(plan())
                records[0]["flows"] = rows
                records[0]["runner_exit_code"] = result["exit_code"]
                summary = shadow.aggregate(plan(), records, "failure" if step not in ("absent", None) else "success")
                rendered = shadow.markdown(summary)
                self.assertIn("Pre-test failure step", rendered)
                expected = "unknown" if step == "absent" else "none" if step is None else step
                flow_row = next(line for line in rendered.splitlines() if line.startswith("| " + flow["id"] + " |"))
                self.assertEqual(expected, flow_row.split("|")[7].strip())
                self.assertEqual(summary["flows"][0].get("pretest_failure_step"), rows[0].get("pretest_failure_step"))

    def test_pretest_step_rejects_unknown_and_contradictory_diagnostics_at_every_reader(self):
        cases = [{"pretest_failure_step": step} for step in ("private-input-sentinel", [], 7, "simulator-reset:terminate")]
        failed = {"pretest_failure_step": "simulator-reset:terminate", "outcome": "FAIL", "exit_code": 2,
                  "failure_kind": "infrastructure", "elapsed_seconds": 0, "official_execution_complete": False}
        cases.extend(dict(failed, **change) for change in (
            {"elapsed_seconds": 1}, {"official_execution_complete": True}, {"failure_kind": "hang-guard"}))
        for change in cases:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                flow, destination = runner_evidence(directory)
                result = json.loads((directory / "smoke-flow-results.json").read_text())["flows"][0]
                result.update(change)
                replace_runner_record(directory, result)
                with self.assertRaisesRegex(ContractError, "pretest failure step"):
                    shadow.read_runner_flows(directory, plan(), [flow], destination)
                records = group_records(plan())
                records[0]["flows"][0].update(change)
                if "outcome" in change:
                    records[0]["flows"][0]["outcome"] = "failed"
                if "official_execution_complete" in change:
                    records[0]["flows"][0]["executed"] = change["official_execution_complete"]
                summary = shadow.aggregate(plan(), records, "success")
                self.assertEqual(summary["outcome"], "failed")
                self.assertTrue(any("pretest failure step" in error for error in summary["errors"]))
                self.assertNotIn("private-input-sentinel", shadow.markdown(summary))
                with patch.object(shadow, "scan_records"), self.assertRaisesRegex(ContractError, "pretest failure step"):
                    shadow.check_group_upload(directory, records[0])

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
        scheduling = shadow.make_plan(environment(), {"schema_version": 1, "flows": [first, second]}, "c" * 64)
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
                    patch("strict_e2e_runner_support.run_runner", side_effect=invoke):
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


if __name__ == "__main__":
    unittest.main()
