"""Guard workflow trust boundaries against accidental privilege and code execution."""

import copy
import json
import unittest
from pathlib import Path

import yaml

import check_workflow_policy as policy


SHA = "11d5960a326750d5838078e36cf38b85af677262"
TRUSTED = ".github/workflows/privacy-preflight.yml"
SHADOW = ".github/workflows/ci-smoke-shadow.yml"


def workflow():
    return {
        "on": {"pull_request": None},
        "permissions": {"contents": "read"},
        "jobs": {"check": {"runs-on": "macos-latest", "timeout-minutes": 5,
                           "steps": [{"uses": f"actions/checkout@{SHA}"}]}},
    }


class SmokeShadowWorkflowPolicyTests(unittest.TestCase):
    def test_shared_smoke_graph_rejects_missing_verification_name_download_and_producer_drift(self):
        baseline = self.document()
        self.assertEqual(self.violations(baseline), [])
        self.assertEqual(set(baseline["jobs"]), {"plan", "ios-debug", "ios-release", "flows", "aggregate"})
        flow = baseline["jobs"]["flows"]
        select = next(index for index, step in enumerate(flow["steps"]) if step.get("id") == "select")
        download = select + 1
        cases = [
            lambda doc: doc["jobs"]["flows"].update({"if": "${{ !cancelled() && needs.plan.result == 'success' && needs.plan.outputs.execute == 'true' && needs.ios-debug.result == 'success' }}"}),
            lambda doc: doc["jobs"]["flows"]["steps"][0]["with"].update(ref="main"),
            lambda doc: doc["jobs"]["aggregate"]["steps"][0]["with"].update(ref="main"),
            lambda doc: doc["jobs"]["plan"]["outputs"].pop("control_sha"),
            lambda doc: next(step for step in doc["jobs"]["flows"]["steps"] if step.get("id") == "run").update({"if": "${{ !cancelled() }}"}),
            lambda doc: doc["jobs"]["flows"]["steps"].pop(select),
            lambda doc: doc["jobs"]["flows"]["steps"][download]["with"].update(name="latest"),
            lambda doc: doc["jobs"]["flows"]["steps"][download]["with"].pop("artifact-ids"),
            lambda doc: doc["jobs"]["flows"]["steps"][select]["env"].update(SMOKE_DEBUG_ARTIFACT_ID="${{ needs.ios-release.outputs.artifact_id }}"),
            lambda doc: doc["jobs"]["ios-debug"].update({"timeout-minutes": 31}),
            lambda doc: doc["jobs"]["ios-release"].update(strategy={"matrix": {"configuration": ["Debug", "Release"]}}),
            lambda doc: doc["jobs"]["ios-debug"].update(environment="immich-test-server"),
            lambda doc: doc["jobs"]["ios-debug"]["permissions"].update(actions="write"),
            lambda doc: doc["jobs"]["flows"].update(needs="plan"),
            lambda doc: doc["jobs"]["flows"]["strategy"].update({"max-parallel": 4}),
            lambda doc: doc["jobs"]["aggregate"].update({"if": "success()"}),
            lambda doc: doc["jobs"]["ios-debug"]["outputs"].update(artifact_id="${{ needs.ios-release.outputs.artifact_id }}"),
        ]
        for mutation in cases:
            changed = copy.deepcopy(baseline)
            mutation(changed)
            with self.subTest(mutation=mutation):
                self.assertIn("smoke-shadow-contract", {item.rule for item in self.violations(changed)})
        foreign = workflow()
        foreign["jobs"]["check"]["timeout-minutes"] = "${{ matrix.timeout_minutes }}"
        self.assertIn("timeout", {item.rule for item in self.violations(foreign, ".github/workflows/ci-gate.yml")})

    def document(self):
        root = Path(__file__).resolve().parent.parent
        return yaml.load((root / SHADOW).read_text(), Loader=policy.WorkflowLoader)

    def violations(self, document, path=SHADOW):
        return policy.check_workflow(path, yaml.safe_dump(document), run_named_workflows={"ci-nightly"})

    def test_shadow_job_timeouts_follow_runner_budgets_with_three_minutes_reserved(self):
        import ci_smoke_shadow as shadow
        baseline = self.document()
        self.assertEqual(self.violations(baseline), [])
        self.assertEqual(baseline["jobs"]["flows"]["timeout-minutes"], "${{ matrix.timeout_minutes }}")
        smoke_manifest = json.loads((shadow.ROOT / shadow.MANIFEST).read_text())
        groups = shadow.manifest_groups(smoke_manifest)
        expected = {"iphone-debug": 30, "iphone-release": 30, "ipad-debug": 30,
                    "ipad-release": 30, "tv-debug": 25, "tv-release": 25}
        self.assertEqual({group["id"]: group["timeout_minutes"] for group in groups}, expected)
        self.assertEqual(shadow.PRODUCER_BUDGET_MINUTES, 27)
        self.assertEqual(2 * (shadow.PRODUCER_BUDGET_MINUTES + shadow.JOB_RESERVE_MINUTES)
                         + sum(expected.values()), 230)
        for group in groups:
            self.assertEqual(group["timeout_minutes"], shadow.GROUP_BUDGET_MINUTES[group["id"]] + 3)
        for timeout in (25, "${{ matrix.timeout_minutes + 1 }}", "${{ matrix.other }}"):
            with self.subTest(timeout=timeout):
                document = copy.deepcopy(baseline)
                document["jobs"]["flows"]["timeout-minutes"] = timeout
                self.assertIn("smoke-shadow-contract", {item.rule for item in self.violations(document)})

    def test_shadow_contract_rejects_weaker_triggers_authority_budget_and_raw_result_gates(self):
        baseline = self.document()
        self.assertEqual(self.violations(baseline), [])
        self.assertIn(policy.SHADOW_PLAN_GUARD, policy.SHADOW_CONCURRENCY_GROUP)
        cases = [
            (lambda doc: doc["permissions"].update(contents="read"), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["plan"].update({"if": "true"}), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["flows"].update({"continue-on-error": True}), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["flows"].update({"timeout-minutes": 30}), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["flows"]["strategy"].update({"fail-fast": True}), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["flows"]["strategy"].update(matrix={"id": ["iphone-debug"]}), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["flows"]["steps"][1].update(run=policy.SHADOW_SETUP), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["flows"]["steps"][-1].update({"if": "success()"}), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["plan"]["permissions"].update(actions="write"), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["aggregate"]["steps"][-1]["with"].update({"retention-days": 7}), "trusted-action"),
            (lambda doc: doc["concurrency"].update(group="per-run-${{ github.run_id }}"), "smoke-shadow-contract"),
            (lambda doc: doc["concurrency"].update(group="ci-smoke-shadow"), "smoke-shadow-contract"),
            (lambda doc: doc["concurrency"].update({"cancel-in-progress": True}), "smoke-shadow-contract"),
            (lambda doc: doc.update(env={"SMOKE_TOKEN": "${{ github.token }}"}), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["plan"]["outputs"].update(head_sha="${{ github.sha }}"), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["plan"]["steps"][2].update(id="other"), "smoke-shadow-contract"),
            (lambda doc: doc["jobs"]["flows"]["steps"][-1].update(env={"SMOKE_TOKEN": "${{ github.token }}"}), "smoke-shadow-contract"),
        ]
        for role in ("plan", "flows", "aggregate"):
            for field, value in (("env", {"SMOKE_TOKEN": "${{ github.token }}"}), ("environment", "ci-publisher"),
                                 ("runs-on", "ubuntu-latest"), ("needs", "other"), ("if", "true")):
                cases.append((lambda doc, role=role, field=field, value=value:
                              doc["jobs"][role].update({field: value}), "smoke-shadow-contract"))
            phase = "run" if role == "flows" else role
            index = next(index for index, step in enumerate(baseline["jobs"][role]["steps"]) if step.get("id") == phase)
            first_run = next(index for index, step in enumerate(baseline["jobs"][role]["steps"]) if "run" in step)
            cases.extend([
                (lambda doc, role=role, index=index: doc["jobs"][role]["steps"][index].pop("env"), "smoke-shadow-contract"),
                (lambda doc, role=role, index=index: doc["jobs"][role]["steps"][index].update({"if": "false"}), "smoke-shadow-contract"),
                (lambda doc, role=role, index=first_run: doc["jobs"][role]["steps"][index].update(
                    env={"SMOKE_TOKEN": "${{ github.token }}"}), "smoke-shadow-contract"),
            ])
        cases.append((lambda doc: doc["jobs"]["flows"]["permissions"].pop("actions"), "smoke-shadow-contract"))
        for mutate, rule in cases:
            with self.subTest(rule=rule, mutation=mutate):
                document = copy.deepcopy(baseline)
                mutate(document)
                self.assertIn(rule, {item.rule for item in self.violations(document)})

    def test_shadow_trusted_exceptions_cannot_execute_foreign_code_or_publish_unscanned_data(self):
        baseline = self.document()
        run_index = next(index for index, step in enumerate(baseline["jobs"]["flows"]["steps"]) if step.get("id") == "run")
        upload_index = run_index + 1
        cases = [
            (lambda doc: doc["jobs"]["flows"]["steps"][2]["with"].update(ref="${{ github.event.workflow_run.head_sha }}"), "trusted-checkout"),
            (lambda doc: doc["jobs"]["plan"]["steps"][0]["with"].update(ref="topic"), "trusted-checkout"),
            (lambda doc: doc["jobs"]["flows"]["steps"][run_index].update(run="python3 downloaded.py"), "trusted-run"),
            (lambda doc: doc["jobs"]["flows"]["steps"][run_index]["env"].update(SMOKE_GROUP="other"), "trusted-environment"),
            (lambda doc: doc["jobs"]["flows"]["steps"][upload_index]["with"].update(path="${{ runner.temp }}/smoke-execution"), "trusted-action"),
            (lambda doc: doc["jobs"]["flows"]["steps"][upload_index].update({"if": "always()"}), "trusted-action"),
            (lambda doc: doc["jobs"]["aggregate"]["steps"][3]["with"].update(pattern="smoke-shadow-group-*"), "trusted-action"),
            (lambda doc: doc["jobs"]["aggregate"]["steps"][3].update(uses=doc["jobs"]["aggregate"]["steps"][3]["uses"].replace(
                "actions/download-artifact", "Actions/Download-Artifact")), "trusted-action"),
            (lambda doc: doc["jobs"]["aggregate"]["steps"][3].update(uses="actions/download-artifact@" + "a" * 40), "trusted-action"),
            (lambda doc: doc["jobs"]["flows"]["steps"][upload_index].update(uses="actions/upload-artifact@" + "a" * 40), "trusted-action"),
            (lambda doc: doc["jobs"]["plan"]["steps"][-1].pop("if", None), "trusted-action"),
            (lambda doc: doc["jobs"]["plan"]["steps"][-1]["with"].update({"retention-days": 90}), "trusted-action"),
            (lambda doc: doc["jobs"]["flows"]["steps"][upload_index]["with"].update({"retention-days": 90}), "trusted-action"),
        ]
        for role in ("plan", "flows", "aggregate"):
            for index, step in enumerate(baseline["jobs"][role]["steps"]):
                if step.get("uses", "").startswith("actions/checkout@"):
                    for field, value in (("persist-credentials", True), ("fetch-depth", 1)):
                        cases.append((lambda doc, role=role, index=index, field=field, value=value:
                                      doc["jobs"][role]["steps"][index]["with"].update({field: value}), "trusted-checkout"))
        for mutate, rule in cases:
            with self.subTest(rule=rule, mutation=mutate):
                document = copy.deepcopy(baseline)
                mutate(document)
                self.assertIn(rule, {item.rule for item in self.violations(document)})
        document = workflow()
        document["on"] = {"workflow_run": {"workflows": ["ci-nightly"], "types": ["completed"]}}
        document["jobs"]["check"]["steps"] = [{"run": "/usr/bin/python3 -B scripts/ci_smoke_shadow.py setup"}]
        self.assertIn("trusted-run", {item.rule for item in self.violations(document, TRUSTED)})


class WorkflowPolicyTests(unittest.TestCase):


    def test_macos_jobs_cannot_survive_cancellation_through_always(self):
        document = workflow()
        for condition in ("always()", "${{ always() && needs.archive.outputs.run_ui == 'true' }}"):
            with self.subTest(condition=condition):
                document["jobs"]["check"]["if"] = condition
                self.assertIn("macos-cancellation", self.rules(document))
        document["jobs"]["check"]["if"] = "${{ !cancelled() && needs.archive.outputs.run_ui == 'true' }}"
        self.assertNotIn("macos-cancellation", self.rules(document))


    def rules(self, document, path=".github/workflows/example.yml", **options):
        return {item.rule for item in policy.check_workflow(path, yaml.safe_dump(document), **options)}

    def trusted(self):
        document = workflow()
        document["on"] = {"pull_request_target": None}
        document["jobs"]["check"]["steps"][0]["with"] = {"ref": "main"}
        document["jobs"]["check"]["runs-on"] = "ubuntu-24.04"
        return document

    def test_main_push_producers_coalesce_by_replacing_only_pending_runs(self):
        root = Path(__file__).resolve().parent.parent
        for path in (".github/workflows/ci-gate.yml",):
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
        for value in [None, 0, -1, 361, True, "5", "${{ inputs.timeout }}", "${{ matrix.timeout_minutes }}"]:
            with self.subTest(value=value):
                document = workflow()
                document["jobs"]["check"]["timeout-minutes"] = value
                if value == "${{ matrix.timeout_minutes }}":
                    document["jobs"]["flows"] = document["jobs"].pop("check")
                self.assertIn("timeout", self.rules(document))
        document = workflow()
        document["jobs"]["other"] = {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]}
        self.assertIn("timeout", self.rules(document))


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
        self.assertIn("pull-request-target", self.rules(document))
        for event in ["workflow_run", ["workflow_run"]]:
            document["on"] = event
            self.assertIn("workflow-run", self.rules(document, TRUSTED))

    def test_workflow_run_requires_named_producers_and_valid_event_types(self):
        for configuration in [{}, {"workflows": ["*"]}, {"workflows": ["ci-gate", "untrusted"]},
                              {"workflows": "ci-gate"}, {"workflows": ["ci-gate"], "types": ["unknown"]}]:
            with self.subTest(configuration=configuration):
                document = self.trusted()
                document["on"] = {"workflow_run": configuration}
                self.assertIn("workflow-run", self.rules(document, TRUSTED))
        document = self.trusted()
        document["on"]["workflow_run"] = {"workflows": ["ci-nightly"], "types": ["completed"]}
        self.assertIn("workflow-run", self.rules(document, TRUSTED))


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
