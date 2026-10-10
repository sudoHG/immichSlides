"""Guard workflow trust boundaries against accidental privilege and code execution."""

import copy
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

import check_workflow_policy as policy


SHA = "11d5960a326750d5838078e36cf38b85af677262"
TRUSTED = ".github/workflows/ci-publish.yml"


def workflow():
    return {
        "on": {"pull_request": None},
        "permissions": {"contents": "read"},
        "jobs": {"check": {"runs-on": "macos-latest", "timeout-minutes": 5,
                           "steps": [{"uses": f"actions/checkout@{SHA}"}]}},
    }


class WorkflowPolicyTests(unittest.TestCase):
    def test_area_map_errors_identify_the_area_map_and_its_own_rule(self):
        from ci_summary import ContractError
        from ci_ui_selection import AREA_MAP_PATH
        from ci_ui_shards import MANIFEST_PATH
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/workflows/check.yml").write_text(yaml.safe_dump(workflow()))
            (root / "scripts").mkdir()
            (root / MANIFEST_PATH).write_text("{}")
            output = io.StringIO()
            with patch("ci_ui_shards.validate_shard_assignments"), \
                    patch("ci_ui_selection.check_area_map", side_effect=ContractError("unmapped app source")), \
                    contextlib.redirect_stderr(output), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(policy.main(["--root", str(root), "--check-ui-shards"]), 1)
            self.assertIn(AREA_MAP_PATH + ":map: [ui-areas] unmapped app source", output.getvalue())
            self.assertNotIn(MANIFEST_PATH, output.getvalue())

    def test_nightly_aggregates_cannot_wait_for_macos_or_require_xcode(self):
        path = policy.LIVE_WORKFLOW
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(set(), self.rules(document, path))
        for job_id in ("aggregate", "ui-aggregate"):
            for mutation in ("runner", "xcode", "toolchain", "bootstrap"):
                with self.subTest(job=job_id, mutation=mutation):
                    changed = copy.deepcopy(document)
                    job = changed["jobs"][job_id]
                    if mutation == "runner":
                        job["runs-on"] = "xcode-27"
                    elif mutation == "bootstrap":
                        for step in job["steps"]:
                            if "setup_ci_publisher_python.py" in step.get("run", ""):
                                step["run"] = "python3 scripts/setup_ci_python.py --venv env"
                    else:
                        job["steps"].append({"run": "xcrun simctl list" if mutation == "xcode" else "python3 setup.py --verify-toolchain"})
                    self.assertIn("nightly-aggregate-platform", self.rules(changed, path))

    def test_macos_jobs_cannot_survive_cancellation_through_always(self):
        document = workflow()
        for condition in ("always()", "${{ always() && needs.archive.outputs.run_ui == 'true' }}"):
            with self.subTest(condition=condition):
                document["jobs"]["check"]["if"] = condition
                self.assertIn("macos-cancellation", self.rules(document))
        document["jobs"]["check"]["if"] = "${{ !cancelled() && needs.archive.outputs.run_ui == 'true' }}"
        self.assertNotIn("macos-cancellation", self.rules(document))

    def test_cloud_start_requires_a_scheduling_marker_before_post(self):
        path = policy.XCC_ROUTE_WORKFLOW
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        steps = document["jobs"]["start"]["steps"]
        marker = next(index for index, step in enumerate(steps) if step.get("with", {}).get("name", "").startswith("ci-xcc-post-"))
        post = next(index for index, step in enumerate(steps) if step.get("id") == "start")
        steps[marker], steps[post] = steps[post], steps[marker]
        self.assertIn("xcc-post-marker", self.rules(document, path))
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        steps = document["jobs"]["start"]["steps"]
        marker = next(index for index, step in enumerate(steps) if step.get("with", {}).get("name", "").startswith("ci-xcc-post-"))
        del steps[marker]
        self.assertIn("xcc-post-marker", self.rules(document, path))

    def test_failed_ios_reruns_cannot_repeat_successful_tv_through_dependencies(self):
        path = ".github/workflows/ci-ui.yml"
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertNotIn("xcc-dependencies", self.rules(document, path))
        for job in ("cloud-wait", "appletv-shards"):
            changed = copy.deepcopy(document)
            changed["jobs"][job]["needs"] = ["archive", "shards"]
            with self.subTest(job=job):
                self.assertIn("xcc-dependencies", self.rules(changed, path))
        changed = copy.deepcopy(document)
        changed["jobs"]["appletv-shards"]["if"] = changed["jobs"]["appletv-shards"]["if"].replace(
            "needs.archive.result == 'success' && ", "")
        self.assertIn("xcc-dependencies", self.rules(changed, path))

    def test_cloud_event_bridge_cannot_receive_secrets_or_execute_pr_code(self):
        root = Path(__file__).resolve().parent.parent
        path = policy.XCC_DISPATCH_WORKFLOW
        document = yaml.load((root / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(document, path), set())
        for mutation in ("branch", "environment", "secret", "checkout", "command", "write"):
            changed = copy.deepcopy(document)
            job = changed["jobs"]["dispatch"]
            if mutation == "branch":
                job["if"] = "always()"
            elif mutation == "environment":
                job["environment"] = "xcode-cloud"
            elif mutation == "secret":
                job["steps"][-1]["env"]["ASC_PRIVATE_KEY"] = "${{ secrets.ASC_PRIVATE_KEY }}"
            elif mutation == "checkout":
                job["steps"][0]["with"]["ref"] = "${{ github.event.workflow_run.head_sha }}"
            elif mutation == "command":
                job["steps"][-1]["run"] += " --workflow other.yml"
            else:
                job["permissions"]["contents"] = "write"
            with self.subTest(mutation=mutation):
                self.assertTrue(self.rules(changed, path))

    def test_cloud_import_forwarder_is_required_and_has_no_environment_or_arbitrary_dispatch(self):
        path = policy.XCC_ROUTE_WORKFLOW
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(document, path), set())
        for mutation in ("missing", "branch", "environment", "needs", "write", "secret", "command", "output"):
            changed = copy.deepcopy(document)
            job = changed["jobs"]["dispatch-import"]
            if mutation == "missing":
                del changed["jobs"]["dispatch-import"]
            elif mutation == "branch":
                job["if"] = "always()"
            elif mutation == "environment":
                job["environment"] = "xcode-cloud"
            elif mutation == "needs":
                job["needs"] = "start"
            elif mutation == "write":
                job["permissions"]["contents"] = "write"
            elif mutation == "secret":
                job["steps"][-1]["env"]["ASC_PRIVATE_KEY"] = "${{ secrets.ASC_PRIVATE_KEY }}"
            elif mutation == "command":
                job["steps"][-1]["run"] += " --workflow other.yml"
            else:
                del changed["jobs"]["route"]["outputs"]
            with self.subTest(mutation=mutation):
                self.assertTrue(self.rules(changed, path))

    def test_cloud_router_cannot_bypass_main_context_budget_serialization_or_credential_scope(self):
        root = Path(__file__).resolve().parent.parent
        path = policy.XCC_ROUTE_WORKFLOW
        document = yaml.load((root / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(document, path), set())
        for mutation in ("branch", "fork", "parallel", "write", "early-key", "checkout", "upload", "trigger"):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(document)
                job = changed["jobs"]["route"]
                if mutation == "branch":
                    job["if"] = "always()"
                elif mutation == "fork":
                    job["if"] = "github.ref == 'refs/heads/main'"
                elif mutation == "parallel":
                    changed["jobs"]["start"]["concurrency"]["group"] += "-${{ github.run_id }}"
                elif mutation == "write":
                    job["permissions"]["contents"] = "write"
                elif mutation == "early-key":
                    job["env"] = {"KEY": "${{ secrets.ASC_PRIVATE_KEY }}"}
                elif mutation == "checkout":
                    job["steps"][0]["with"]["ref"] = "${{ github.event.workflow_run.head_sha }}"
                elif mutation == "upload":
                    job["steps"][-1]["if"] = "always()"
                else:
                    changed["on"]["pull_request"] = None
                self.assertTrue(self.rules(changed, path))

    def test_cloud_importer_main_context_and_secret_step_cannot_be_weakened(self):
        path = policy.XCC_IMPORT_WORKFLOW
        source = (Path(__file__).resolve().parent.parent / path).read_text()
        document = yaml.load(source, Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(document, path), set())
        for mutation in ("branch", "event", "checkout", "environment", "permissions", "job-secret", "early-secret", "upload"):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(document)
                job = changed["jobs"]["import"]
                if mutation == "branch":
                    job.pop("if")
                elif mutation == "event":
                    changed["on"]["pull_request"] = None
                elif mutation == "checkout":
                    job["steps"][0]["with"]["ref"] = "${{ github.event.pull_request.head.sha }}"
                elif mutation == "environment":
                    job["environment"] = "release"
                elif mutation == "permissions":
                    job["permissions"]["actions"] = "write"
                elif mutation == "job-secret":
                    job["env"] = policy.XCC_BINDINGS
                elif mutation == "early-secret":
                    job["steps"][0]["env"] = policy.XCC_BINDINGS
                else:
                    job["steps"][-1]["with"]["path"] = "${{ github.workspace }}"
                self.assertTrue(self.rules(changed, path))

    def test_live_environment_and_credentials_are_bound_to_guarded_nightly_jobs(self):
        root = Path(__file__).resolve().parent.parent
        source = (root / ".github/workflows/ci-nightly.yml").read_text()
        document = yaml.load(source, Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(document, ".github/workflows/ci-nightly.yml"), set())
        legal = copy.deepcopy(document)
        steps = legal["jobs"]["live-unit"]["steps"]
        steps[0]["name"] = "Check secrets are absent before injection"
        steps[2]["run"] = "# secrets are injected later\n" + steps[2]["run"]
        steps[3]["name"] = "${{ format('{0}', 'secrets') }}"
        steps[4]["name"] = "${{ github.event.inputs.secrets }} ${{ inputs.check-secrets }}"
        steps[5]["name"] = "Check secrets.IMMICH_TEST_SERVER_URL is absent"
        self.assertEqual(self.rules(legal, ".github/workflows/ci-nightly.yml"), set())
        for mutation in ("other-workflow", "unconditional", "job-secret", "early-secret", "wrong-environment",
                         "run-secret", "with-secret", "bracket-secret", "expression-environment",
                         "whole-context", "dynamic-secret", "lowercase-secret", "uppercase-context",
                         "other-secret", "inherited-context", "binding-context", "env-named-if", "implicit-if"):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(document)
                job = changed["jobs"]["live-unit"]
                path = ".github/workflows/ci-nightly.yml"
                if mutation == "other-workflow":
                    path = ".github/workflows/other.yml"
                elif mutation == "unconditional":
                    job.pop("if")
                elif mutation == "job-secret":
                    job["env"] = {"CI_LIVE_KEY": "${{ secrets.IMMICH_TEST_SERVER_API_KEY }}"}
                elif mutation == "early-secret":
                    job["steps"][0]["env"] = {"CI_LIVE_KEY": "${{ secrets.IMMICH_TEST_SERVER_API_KEY }}"}
                elif mutation == "run-secret":
                    job["steps"][0]["run"] = "echo '${{ secrets.IMMICH_TEST_SERVER_URL }}'"
                elif mutation == "with-secret":
                    job["steps"][0]["with"]["ref"] = "${{ secrets.IMMICH_TEST_SERVER_API_KEY }}"
                elif mutation == "bracket-secret":
                    job["steps"][0]["env"] = {"OTHER": "${{ secrets['IMMICH_TEST_SERVER_URL'] }}"}
                elif mutation == "expression-environment":
                    job["environment"] = "${{ inputs.environment }}"
                elif mutation == "whole-context":
                    job["steps"][0]["env"] = {"OTHER": "${{ toJSON(secrets) }}"}
                elif mutation == "dynamic-secret":
                    job["steps"][0]["env"] = {"OTHER": "${{ secrets[format('IMMICH_{0}', 'TEST_SERVER_URL')] }}"}
                elif mutation == "lowercase-secret":
                    job["steps"][0]["env"] = {"OTHER": "${{ secrets.immich_test_server_url }}"}
                elif mutation == "uppercase-context":
                    job["steps"][0]["env"] = {"OTHER": "${{ toJSON(SeCrEtS) }}"}
                elif mutation == "other-secret":
                    job["env"] = {"OTHER": "${{ secrets.UNRELATED }}"}
                elif mutation == "inherited-context":
                    changed["env"] = {"OTHER": "${{ toJSON(secrets) }}"}
                elif mutation == "env-named-if":
                    job["steps"][0]["env"] = {"if": "'${{ toJSON(secrets) }}'"}
                elif mutation == "implicit-if":
                    job["steps"][0]["if"] = "secrets.OTHER != ''"
                elif mutation == "binding-context":
                    step = next(step for step in job["steps"] if step.get("id") == "live")
                    step["env"]["CI_LIVE_URL"] = "${{ toJSON(secrets) }}"
                else:
                    job["environment"] = "test-server"
                self.assertIn("live-credential", self.rules(changed, path))

    def test_ui_verdict_upload_is_limited_to_the_exact_publisher_output(self):
        document = self.trusted()
        upload = {"uses": "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
                  "with": {"name": "ci-ui-verdict-${{ steps.publish.outputs.ui_verdict_tree }}",
                           "path": "${{ runner.temp }}/ci-ui-verdict/verdict.json",
                           "if-no-files-found": "error", "retention-days": 30}}
        document["jobs"]["check"]["steps"].append(upload)
        self.assertNotIn("trusted-action", self.rules(document, TRUSTED))
        for key, value in (("path", "${{ runner.temp }}/**"), ("retention-days", 90),
                           ("name", "ci-ui-verdict-${{ github.sha }}")):
            bad = copy.deepcopy(document)
            bad["jobs"]["check"]["steps"][-1]["with"][key] = value
            with self.subTest(key=key):
                self.assertIn("trusted-action", self.rules(bad, TRUSTED))

    def rules(self, document, path=".github/workflows/example.yml"):
        return {item.rule for item in policy.check_workflow(path, yaml.safe_dump(document))}

    def trusted(self):
        document = workflow()
        document["on"] = {"workflow_run": {"workflows": ["ci-gate", "ci-ui"],
                                           "types": ["requested", "in_progress", "completed"]}}
        document["jobs"]["check"]["steps"][0]["with"] = {"ref": "main"}
        document["jobs"]["check"]["runs-on"] = "ubuntu-24.04"
        return document

    def test_main_push_producers_coalesce_by_replacing_only_pending_runs(self):
        root = Path(__file__).resolve().parent.parent
        for path in (".github/workflows/ci-gate.yml", ".github/workflows/ci-ui.yml"):
            document = yaml.load((root / path).read_text(), Loader=policy.WorkflowLoader)
            self.assertNotIn("concurrency-queue", self.rules(document, path))
            for mutation in (
                    lambda doc: doc["concurrency"].update({"cancel-in-progress": True}),
                    lambda doc: doc["concurrency"].update({"cancel-in-progress": False}),
                    lambda doc: doc["concurrency"].update(group=doc["concurrency"]["group"].replace("run_attempt == 1", "true")),
                    lambda doc: doc["concurrency"].update(group="shared"),
                    lambda doc: doc.pop("concurrency"),
                    lambda doc: next(iter(doc["jobs"].values())).update(concurrency={"group": "x", "cancel-in-progress": True})):
                changed = copy.deepcopy(document)
                mutation(changed)
                with self.subTest(path=path):
                    self.assertIn("concurrency-queue", self.rules(changed, path))

    def test_remote_actions_and_reusable_workflows_require_full_commit_pins(self):
        for uses in ["actions/checkout@v4", "owner/repo@main", "owner/repo@abc123",
                     "owner/repo/.github/workflows/test.yml@v1", "${{ inputs.action }}",
                     "docker://alpine:3", "actions/checkout@" + "g" * 40]:
            with self.subTest(uses=uses):
                document = workflow()
                document["jobs"]["check"]["steps"][0]["uses"] = uses
                self.assertIn("action-pin", self.rules(document))
        document = workflow()
        document["jobs"]["check"]["uses"] = "owner/repo/.github/workflows/test.yml@main"
        self.assertIn("action-pin", self.rules(document))

    def test_immutable_actions_and_local_actions_pass(self):
        for uses in [f"actions/checkout@{SHA}", f"owner/repo/subdir@{SHA}",
                     "./.github/actions/check", "docker://alpine@sha256:" + "a" * 64]:
            with self.subTest(uses=uses):
                document = workflow()
                document["jobs"]["check"]["steps"][0]["uses"] = uses
                self.assertEqual(set(), self.rules(document))

    def test_permissions_must_be_explicit_and_valid_at_workflow_or_every_job(self):
        for value in [None, "write-all", "${{ inputs.permissions }}", {"contents": "admin"}]:
            with self.subTest(value=value):
                document = workflow()
                document["permissions"] = value
                self.assertIn("permissions", self.rules(document))
        document = workflow()
        del document["permissions"]
        self.assertIn("permissions", self.rules(document))
        document["jobs"]["check"]["permissions"] = {}
        self.assertEqual(set(), self.rules(document))
        document["jobs"]["other"] = copy.deepcopy(document["jobs"]["check"])
        del document["jobs"]["other"]["permissions"]
        self.assertIn("permissions", self.rules(document))

    def test_each_job_needs_a_bounded_literal_timeout(self):
        for value in [None, 0, -1, 361, True, "5", "${{ inputs.timeout }}"]:
            with self.subTest(value=value):
                document = workflow()
                document["jobs"]["check"]["timeout-minutes"] = value
                self.assertIn("timeout", self.rules(document))
        document = workflow()
        document["jobs"]["other"] = {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]}
        self.assertIn("timeout", self.rules(document))

    def test_approval_wait_cannot_acquire_credentials_or_execute_an_action(self):
        document = {"on": {"workflow_dispatch": None}, "permissions": {}, "jobs": {
            "wait": {"runs-on": "ubuntu-24.04", "timeout-minutes": 5, "permissions": {},
                     "environment": "ci-approval", "steps": [{"run": "/usr/bin/true"}]}}}
        path = ".github/workflows/ci-approval.yml"
        self.assertEqual(self.rules(document, path), set())
        for key, value in (("permissions", {"contents": "read"}),
                           ("env", {"CI_APP_PRIVATE_KEY": "${{ secrets.CI_APP_PRIVATE_KEY }}"}),
                           ("steps", [{"uses": f"actions/checkout@{SHA}", "with": {"ref": "main"}}])):
            with self.subTest(key=key):
                modified = copy.deepcopy(document)
                modified["jobs"]["wait"][key] = value
                self.assertIn("approval-wait", self.rules(modified, path))

    def test_app_key_binding_is_refused_outside_the_guarded_publisher_step(self):
        document = self.trusted()
        document["jobs"]["check"]["steps"] = [{"run": '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_publish.py route',
            "env": {"CI_APP_PRIVATE_KEY": "${{ secrets.CI_APP_PRIVATE_KEY }}"}}]
        self.assertIn("publisher-credential", self.rules(document, TRUSTED))
        document["jobs"]["check"]["environment"] = "ci-publisher"
        self.assertIn("publisher-credential", self.rules(document, TRUSTED))
        document["jobs"]["check"]["steps"][0]["run"] = '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_publish.py publish'
        self.assertNotIn("publisher-credential", self.rules(document, TRUSTED))
        for scope in ("workflow", "job"):
            for binding in ("CI_APP_ID", "CI_APP_PRIVATE_KEY"):
                with self.subTest(scope=scope, binding=binding):
                    modified = copy.deepcopy(document)
                    owner = modified if scope == "workflow" else modified["jobs"]["check"]
                    owner["env"] = {binding: policy.PUBLISHER_BINDINGS[binding]}
                    self.assertIn("publisher-credential", self.rules(modified, TRUSTED))

    def test_publisher_history_runner_and_approval_queue_contracts_fail_closed(self):
        root = Path(__file__).parents[1]
        publisher = yaml.load((root / TRUSTED).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(publisher, TRUSTED), set())
        shallow = copy.deepcopy(publisher)
        del shallow["jobs"]["publish"]["steps"][0]["with"]["fetch-depth"]
        self.assertIn("publisher-history", self.rules(shallow, TRUSTED))
        expensive = copy.deepcopy(publisher)
        expensive["jobs"]["admission"]["runs-on"] = "xcode-27"
        self.assertIn("publisher-runner", self.rules(expensive, TRUSTED))
        redundant = copy.deepcopy(publisher)
        del redundant["jobs"]["admission"]["steps"][-1]["if"]
        self.assertIn("publisher-admission", self.rules(redundant, TRUSTED))
        for path in (".github/workflows/ci-approval.yml", ".github/workflows/ci-approve.yml"):
            document = yaml.load((root / path).read_text(), Loader=policy.WorkflowLoader)
            self.assertEqual(self.rules(document, path), set())
            document["jobs"]["record"]["concurrency"] = {"group": "ci-state-pr-${{ inputs.pull_request }}", "cancel-in-progress": False}
            self.assertIn("approval-queue", self.rules(document, path))

    def probe(self):
        document = self.trusted()
        document["name"] = "ci-probe"
        document["on"] = {"schedule": [{"cron": "17 8 * * *"}], "workflow_dispatch": None}
        document["permissions"] = {}
        document["jobs"]["check"]["permissions"] = {"contents": "read", "issues": "write"}
        document["jobs"]["check"]["steps"].extend([
            {"run": '/usr/bin/python3 scripts/setup_ci_python.py --python /usr/bin/python3 --venv "$RUNNER_TEMP/ci-python"'},
            {"run": "/usr/bin/python3 scripts/probe_ci_toolchain.py", "env": {
                "CI_PROBE_TOKEN": "${{ github.token }}",
                "CI_PROBE_SIMULATE_MISSING_PIN": "${{ inputs.simulate_missing_pin || false }}",
            }},
        ])
        return document

    def test_probe_grants_only_its_named_trusted_entry_points_and_bindings(self):
        document = self.probe()
        self.assertEqual(set(), self.rules(document, ".github/workflows/ci-probe.yml"))
        self.assertIn("issue-write", self.rules(document))
        self.assertIn("trusted-run", self.rules(document, TRUSTED))
        for mutation, rule in [
            ({"name": "renamed"}, "probe-contract"),
            ({"on": {"pull_request": None}}, "probe-contract"),
            ({"on": {"workflow_dispatch": None}}, "probe-contract"),
            ({"permissions": {"issues": "write"}}, "probe-contract"),
        ]:
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(document)
                changed.update(mutation)
                self.assertIn(rule, self.rules(changed, ".github/workflows/ci-probe.yml"))
        for key, value in [("contents", "write"), ("actions", "write"), ("id-token", "write")]:
            with self.subTest(permission=key):
                changed = copy.deepcopy(document)
                changed["jobs"]["check"]["permissions"][key] = value
                self.assertIn("probe-contract", self.rules(changed, ".github/workflows/ci-probe.yml"))
        for script in ["/usr/bin/python3 scripts/probe_ci_toolchain.py --root ci-artifacts",
                       "/usr/bin/python3 scripts/probe_ci_toolchain.py; echo unsafe"]:
            with self.subTest(script=script):
                changed = copy.deepcopy(document)
                changed["jobs"]["check"]["steps"][-1]["run"] = script
                self.assertIn("trusted-run", self.rules(changed, ".github/workflows/ci-probe.yml"))
        changed = copy.deepcopy(document)
        changed["jobs"]["check"]["steps"][-1]["env"]["CI_PROBE_TOKEN"] = "${{ secrets.OTHER_TOKEN }}"
        self.assertIn("trusted-environment", self.rules(changed, ".github/workflows/ci-probe.yml"))
        changed = copy.deepcopy(document)
        changed["jobs"]["check"]["steps"][0]["with"]["ref"] = "${{ github.sha }}"
        self.assertIn("trusted-checkout", self.rules(changed, ".github/workflows/ci-probe.yml"))

    def test_issue_write_is_reserved_for_probe_and_report(self):
        for path in [".github/workflows/example.yml", TRUSTED, ".github/workflows/ci-probe.yaml"]:
            with self.subTest(path=path):
                document = workflow()
                document["permissions"]["issues"] = "write"
                self.assertIn("issue-write", self.rules(document, path))
        document = self.trusted()
        document["permissions"]["issues"] = "write"
        self.assertNotIn("issue-write", self.rules(document, ".github/workflows/ci-report.yml"))

    def test_privileged_triggers_use_exact_paths_in_all_yaml_forms(self):
        for event in ["pull_request_target", ["pull_request_target"], {"pull_request_target": None}]:
            with self.subTest(event=event):
                document = workflow()
                document["on"] = event
                self.assertIn("pull-request-target", self.rules(document))
                self.assertEqual(set(), self.rules(document, policy.PRIVACY_WORKFLOW))
                self.assertIn("pull-request-target", self.rules(document, ".github/workflows/privacy-preflight.yaml"))
        document = self.trusted()
        self.assertEqual(set(), self.rules(document, TRUSTED))
        self.assertIn("workflow-run", self.rules(document))
        for event in ["workflow_run", ["workflow_run"]]:
            document["on"] = event
            self.assertIn("workflow-run", self.rules(document, TRUSTED))

    def test_workflow_run_requires_named_producers_and_valid_event_types(self):
        for configuration in [{}, {"workflows": ["*"]}, {"workflows": ["ci-gate", "untrusted"]},
                              {"workflows": "ci-gate"}, {"workflows": ["ci-gate"], "types": ["unknown"]}]:
            with self.subTest(configuration=configuration):
                document = self.trusted()
                document["on"]["workflow_run"] = configuration
                self.assertIn("workflow-run", self.rules(document, TRUSTED))
        document = self.trusted()
        document["on"]["workflow_run"] = {"workflows": ["ci-nightly"], "types": ["completed"]}
        self.assertNotIn("workflow-run", self.rules(document, ".github/workflows/ci-report.yml"))

    def test_reporter_rejects_write_grants_environments_branch_code_and_unbounded_retention(self):
        document = {"name": "ci-report", "on": {"schedule": [{"cron": "30 8 * * *"}],
                    "workflow_dispatch": {"inputs": {"reset_history": {
                        "description": "Maintainer-only explicit bootstrap or reset of reporting history",
                        "required": False, "default": False, "type": "boolean"}}},
                    "workflow_run": {"workflows": ["ci-nightly"], "types": ["completed"], "branches": ["main"]}},
                    "permissions": {}, "jobs": {"report": {"if": "github.ref == 'refs/heads/main' && "
                    "(github.event_name != 'workflow_run' || "
                    "(github.event.workflow_run.head_repository.full_name == github.repository && github.event.workflow_run.head_branch == 'main' && "
                    "((github.event.workflow_run.name == 'ci-nightly' && contains(fromJSON('[\"schedule\",\"workflow_dispatch\"]'), github.event.workflow_run.event)) || "
                    "(contains(fromJSON('[\"ci-gate\",\"ci-ui\"]'), github.event.workflow_run.name) && github.event.workflow_run.event == 'push'))))",
                    "runs-on": "ubuntu-24.04", "timeout-minutes": 30,
                    "permissions": {"contents": "read", "actions": "read", "pull-requests": "read", "issues": "write"},
                    "concurrency": {"group": "ci-report-state", "cancel-in-progress": False},
                    "steps": [{"uses": "actions/checkout@" + SHA, "with": {"ref": "main", "fetch-depth": 0}},
                              {"run": '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_report.py --phase collect',
                               "env": {"CI_REPORT_TOKEN": "${{ github.token }}"}},
                              {"if": "success()", "uses": "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
                               "with": {"name": "ci-report-daily-${{ github.run_id }}-${{ github.run_attempt }}",
                                        "path": "${{ runner.temp }}/ci-report/daily", "if-no-files-found": "error", "retention-days": 90}},
                              {"if": "success()", "run": '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_report.py --phase sync',
                               "env": {"CI_REPORT_TOKEN": "${{ github.token }}"}}]}}}
        document["on"]["workflow_dispatch"]["inputs"]["health_month"] = {
            "description": "Optional UTC health month (YYYY-MM); scheduled collection reports the previous month on day 1",
            "required": False, "default": "", "type": "string"}
        document["jobs"]["report"]["steps"].insert(3, {
            "if": "success() && steps.collect.outputs.health_month != ''",
            "uses": "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            "with": {"name": "ci-report-health-${{ steps.collect.outputs.health_month }}-${{ github.run_id }}-${{ github.run_attempt }}",
                     "path": "${{ runner.temp }}/ci-report/health", "if-no-files-found": "error", "retention-days": 90}})
        self.assertEqual(set(), self.rules(document, policy.REPORT_WORKFLOW))
        for mutate in (lambda job: job["permissions"].update(actions="write"),
                       lambda job: job.update(environment="ci-publisher"),
                       lambda job: job.update({"if": "github.ref == 'refs/heads/main'"}),
                       lambda job: job.update({"if": job["if"].replace("head_repository.full_name == github.repository", "head_repository.full_name != github.repository")}),
                       lambda job: job.update({"if": job["if"].replace("event == 'push'", "event == 'pull_request'")}),
                       lambda job: job["steps"][2].update({"if": "always()"}),
                       lambda job: job["steps"][3].update({"if": "always()"}),
                       lambda job: job["steps"].reverse(),
                       lambda job: job["steps"][0]["with"].update(ref="${{ github.event.workflow_run.head_sha }}"),
                       lambda job: job.update(concurrency={"group": "ci-report-state", "cancel-in-progress": True})):
            changed = copy.deepcopy(document)
            mutate(changed["jobs"]["report"])
            self.assertIn("report-contract", self.rules(changed, policy.REPORT_WORKFLOW))
        changed = copy.deepcopy(document)
        changed["on"]["workflow_run"].pop("branches")
        self.assertIn("report-contract", self.rules(changed, policy.REPORT_WORKFLOW))

    def test_trusted_checkout_rejects_pr_refs_shas_and_indirection(self):
        for ref in ["refs/pull/123/head", "refs/pull/123/merge", "${{ github.event.pull_request.head.sha }}",
                    "${{ github.event.workflow_run.head_sha }}", "${{ github.sha }}", "${{ env.REF }}",
                    "${{ inputs.sha }}", "abc123", "feature", {"head": "sha"}]:
            with self.subTest(ref=ref):
                document = self.trusted()
                document["jobs"]["check"]["steps"][0]["with"]["ref"] = ref
                self.assertIn("trusted-checkout", self.rules(document, TRUSTED))
        document = self.trusted()
        document["jobs"]["check"]["steps"][0]["with"]["repository"] = "${{ github.event.pull_request.head.repo.full_name }}"
        self.assertIn("trusted-checkout", self.rules(document, TRUSTED))

    def test_trusted_checkout_accepts_default_branch_and_privacy_base_only(self):
        for ref in ["main", "refs/heads/main", "${{ github.event.repository.default_branch }}"]:
            document = self.trusted()
            document["jobs"]["check"]["steps"][0]["with"]["ref"] = ref
            self.assertEqual(set(), self.rules(document, TRUSTED))
        document = workflow()
        document["on"] = {"pull_request_target": None}
        document["jobs"]["check"]["steps"][0]["with"] = {"ref": "${{ github.event.pull_request.base.sha }}"}
        self.assertEqual(set(), self.rules(document, policy.PRIVACY_WORKFLOW))
        self.assertIn("trusted-checkout", self.rules(document, TRUSTED))

    def test_trusted_shell_cannot_materialize_pr_code_but_can_fetch_objects(self):
        for command in ["git checkout $HEAD_SHA", "git switch branch", "git reset --hard FETCH_HEAD",
                        "gh pr checkout 123", "git worktree add /tmp/pr FETCH_HEAD"]:
            with self.subTest(command=command):
                document = self.trusted()
                document["jobs"]["check"]["steps"].append({"run": command})
                self.assertIn("trusted-run", self.rules(document, TRUSTED))
        document = workflow()
        document["on"] = {"pull_request_target": None}
        document["jobs"]["check"]["steps"].append({"run": policy.PRIVACY_OBJECT_FETCH})
        self.assertEqual(set(), self.rules(document, policy.PRIVACY_WORKFLOW))
        document["jobs"]["check"]["steps"][-1]["run"] += "\ngit checkout FETCH_HEAD"
        self.assertIn("trusted-run", self.rules(document, policy.PRIVACY_WORKFLOW))

    def test_trusted_artifacts_may_be_read_as_data_but_never_executed(self):
        for command in ["bash ci-artifacts/report.sh", "python3 ci-artifacts/report.py", "./ci-artifacts/run",
                        "source ci-artifacts/env", "chmod +x ci-artifacts/run", "eval $(cat ci-artifacts/code)",
                        "cat ci-artifacts/code | sh", "cd ci-artifacts && ./run", "bash $PAYLOAD",
                        "cat ci-artifacts/code | python3", "cat ci-artifacts/code | /usr/bin/ruby",
                        ". ci-artifacts/env", "echo safe\n./ci-artifacts/run", "env bash ci-artifacts/run",
                        "exec ./ci-artifacts/run", "python3 -c 'import runpy; runpy.run_path(path)'",
                        "chmod +x $PAYLOAD"]:
            with self.subTest(command=command):
                document = self.trusted()
                document["jobs"]["check"]["steps"].extend([
                    {"uses": f"actions/download-artifact@{SHA}", "with": {"path": "ci-artifacts"}},
                    {"run": command},
                ])
                self.assertIn("trusted-run", self.rules(document, TRUSTED))
        document = self.trusted()
        document["jobs"]["check"]["steps"].extend([
            {"uses": f"actions/download-artifact@{SHA}", "with": {"path": "ci-artifacts"}},
            {"run": "python3 scripts/read_summary.py --input ci-artifacts/summary.json"},
        ])
        self.assertIn("trusted-run", self.rules(document, TRUSTED))
        document["jobs"]["check"]["steps"][-1]["run"] = "/usr/bin/python3 scripts/check_workflow_policy.py"
        self.assertEqual(set(), self.rules(document, TRUSTED))

    def test_trusted_artifact_downloads_cannot_overwrite_the_checkout(self):
        for path in [None, ".", "scripts", "ci-artifacts/../scripts", "${{ github.workspace }}", "$DEST"]:
            with self.subTest(path=path):
                document = self.trusted()
                document["jobs"]["check"]["steps"].append({"uses": f"actions/download-artifact@{SHA}", "with": {"path": path}})
                self.assertIn("artifact-execution", self.rules(document, TRUSTED))

    def test_inline_action_scripts_cannot_evaluate_artifact_contents(self):
        document = self.trusted()
        document["jobs"]["check"]["steps"].append({"uses": f"actions/github-script@{SHA}", "with": {
            "script": "eval(require('fs').readFileSync('ci-artifacts/code.js', 'utf8'))"}})
        self.assertIn("artifact-execution", self.rules(document, TRUSTED))

    def test_inline_downloads_cannot_bypass_artifact_isolation(self):
        for script in ["gh run download 123 && bash report.sh",
                       "curl -L https://api.github.com/repos/org/repo/actions/artifacts/123/zip -o payload.zip",
                       "await github.rest.actions.downloadArtifact({artifact_id: 123})"]:
            with self.subTest(script=script):
                document = self.trusted()
                document["jobs"]["check"]["steps"].append({"run": script})
                self.assertIn("trusted-run", self.rules(document, TRUSTED))

    def test_protected_environments_are_bound_to_named_workflows(self):
        for environment, allowed in [("ci-publisher", TRUSTED), ("ci-approval", ".github/workflows/ci-approval.yml"),
                                     ("release", ".github/workflows/ci-release.yml")]:
            for value in [environment, environment.upper(), {"name": environment}]:
                with self.subTest(value=value):
                    document = workflow()
                    document["jobs"]["check"]["steps"][0]["with"] = {"ref": "main"}
                    document["jobs"]["check"]["environment"] = value
                    self.assertIn("environment", self.rules(document))
                    self.assertNotIn("environment", self.rules(document, allowed))
        document = workflow()
        document["jobs"]["check"]["environment"] = "${{ inputs.environment }}"
        self.assertIn("environment", self.rules(document))

    def test_trusted_artifacts_cannot_be_injected_through_loader_environment(self):
        for key, value in [("PATH", "ci-artifacts:$PATH"), ("BASH_ENV", "ci-artifacts/env"),
                           ("PYTHONPATH", "ci-artifacts"), ("NODE_OPTIONS", "--require ci-artifacts/init.js"),
                           ("ENV", "${{ steps.download.outputs.path }}")]:
            with self.subTest(key=key):
                document = self.trusted()
                document["jobs"]["check"]["steps"].append({"uses": f"actions/download-artifact@{SHA}", "with": {"path": "ci-artifacts"}})
                document["env"] = {key: value}
                self.assertIn("artifact-execution", self.rules(document, TRUSTED))

    def test_malformed_or_ambiguous_yaml_fails_closed(self):
        for source in ["on: [", "on: pull_request\non: push", "[]", "", "jobs: {}", "on: 7",
                       "on: pull_request\njobs: []", "!!python/object:os.system {}",
                       "on: &event pull_request\nother: *event", "on: pull_request\n---\non: push"]:
            with self.subTest(source=source):
                self.assertIn("workflow-format", {item.rule for item in policy.check_workflow(TRUSTED, source)})

    def test_reviewed_execution_and_checkout_bypasses_fail_closed(self):
        for review, step, path, expected in [
            ("R1", {"run": "python3 < ci-artifacts/code.py"}, TRUSTED, "trusted-run"),
            ("R2", {"uses": "./ci-artifacts/action"}, TRUSTED, "trusted-action"),
            ("R3", {"run": 'git -C "$GITHUB_WORKSPACE" checkout "$PR_HEAD_SHA"'}, TRUSTED, "trusted-run"),
            ("R4", {"uses": f"actions/checkout@{SHA}"}, policy.PRIVACY_WORKFLOW, "trusted-checkout"),
        ]:
            with self.subTest(review=review):
                document = workflow() if review == "R4" else self.trusted()
                if review == "R4":
                    document["jobs"]["check"]["steps"] = [step]
                else:
                    document["jobs"]["check"]["steps"].extend([
                        {"uses": f"actions/download-artifact@{SHA}", "with": {"path": "ci-artifacts"}}, step,
                    ])
                self.assertIn(expected, self.rules(document, path))

    def test_trusted_allowlists_reject_unreviewed_actions_arguments_and_execution_settings(self):
        for step, expected in [
            ({"uses": f"owner/tool@{SHA}"}, "trusted-action"),
            ({"uses": "./.github/actions/downloads/payload"}, "trusted-action"),
            ({"uses": f"actions/checkout@{SHA}", "with": {"ref": "main", "path": "ci-artifacts"}}, "trusted-action"),
            ({"run": "/usr/bin/python3 scripts/check_workflow_policy.py --root ci-artifacts"}, "trusted-run"),
            ({"run": "pwd", "working-directory": "ci-artifacts"}, "trusted-run"),
            ({"run": "pwd", "shell": "bash --rcfile ci-artifacts/env {0}"}, "trusted-run"),
            ({"run": "pwd", "env": {"GIT_SSH_COMMAND": "ci-artifacts/run"}}, "trusted-environment"),
        ]:
            with self.subTest(step=step):
                document = self.trusted()
                document["jobs"]["check"]["steps"].append(step)
                self.assertIn(expected, self.rules(document, TRUSTED))
        for override in [{"defaults": {"run": {"working-directory": "ci-artifacts"}}},
                         {"container": "alpine"}, {"services": {"payload": {"image": "alpine"}}}]:
            with self.subTest(override=override):
                document = self.trusted()
                document["jobs"]["check"].update(override)
                self.assertIn("trusted-run", self.rules(document, TRUSTED))
        document = self.trusted()
        document["jobs"]["check"]["steps"].extend([
            {"run": "git rev-parse HEAD"}, {"uses": "./.github/actions/check"},
            {"run": "/usr/bin/python3 scripts/check_workflow_policy.py --root ."},
        ])
        self.assertEqual(set(), self.rules(document, TRUSTED))
        for event in ["pull_request", ["pull_request_target", "pull_request"],
                      {"pull_request_target": None, "workflow_dispatch": None}]:
            for ref in [None, "${{ github.event.pull_request.base.sha }}"]:
                with self.subTest(event=event, ref=ref):
                    document = workflow()
                    document["on"] = event
                    document["jobs"]["check"]["steps"][0]["with"] = {"ref": ref}
                    self.assertIn("trusted-checkout", self.rules(document, policy.PRIVACY_WORKFLOW))


if __name__ == "__main__":
    unittest.main()
