"""Guard workflow trust boundaries against accidental privilege and code execution."""

import copy
import sys
import unittest
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
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
    def rules(self, document, path=".github/workflows/example.yml"):
        return {item.rule for item in policy.check_workflow(path, yaml.safe_dump(document))}

    def trusted(self):
        document = workflow()
        document["on"] = {"workflow_run": {"workflows": ["ci-gate", "ci-ui"],
                                           "types": ["requested", "in_progress", "completed"]}}
        document["jobs"]["check"]["steps"][0]["with"] = {"ref": "main"}
        return document

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
        self.assertEqual(set(), self.rules(document, ".github/workflows/ci-report.yml"))

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
                self.assertIn("trusted-checkout", self.rules(document, TRUSTED))
        document = self.trusted()
        document["jobs"]["check"]["steps"].append({"run": 'git fetch origin "refs/pull/${PR}/head"'})
        self.assertEqual(set(), self.rules(document, TRUSTED))

    def test_trusted_artifacts_may_be_read_as_data_but_never_executed(self):
        for command in ["bash ci-artifacts/report.sh", "python3 ci-artifacts/report.py", "./ci-artifacts/run",
                        "source ci-artifacts/env", "chmod +x ci-artifacts/run", "eval $(cat ci-artifacts/code)",
                        "cat ci-artifacts/code | sh", "cd ci-artifacts && ./run", "bash $PAYLOAD",
                        ". ci-artifacts/env", "echo safe\n./ci-artifacts/run", "env bash ci-artifacts/run",
                        "exec ./ci-artifacts/run", "python3 -c 'import runpy; runpy.run_path(path)'",
                        "chmod +x $PAYLOAD"]:
            with self.subTest(command=command):
                document = self.trusted()
                document["jobs"]["check"]["steps"].extend([
                    {"uses": f"actions/download-artifact@{SHA}", "with": {"path": "ci-artifacts"}},
                    {"run": command},
                ])
                self.assertIn("artifact-execution", self.rules(document, TRUSTED))
        document = self.trusted()
        document["jobs"]["check"]["steps"].extend([
            {"uses": f"actions/download-artifact@{SHA}", "with": {"path": "ci-artifacts"}},
            {"run": "python3 scripts/read_summary.py --input ci-artifacts/summary.json"},
        ])
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
                self.assertIn("artifact-execution", self.rules(document, TRUSTED))

    def test_protected_environments_are_bound_to_named_workflows(self):
        for environment, allowed in [("ci-publisher", TRUSTED), ("ci-approval", ".github/workflows/ci-approval.yml"),
                                     ("release", ".github/workflows/ci-release.yml")]:
            for value in [environment, {"name": environment}]:
                with self.subTest(value=value):
                    document = workflow()
                    document["jobs"]["check"]["steps"][0]["with"] = {"ref": "main"}
                    document["jobs"]["check"]["environment"] = value
                    self.assertIn("environment", self.rules(document))
                    self.assertNotIn("environment", self.rules(document, allowed))
        document = workflow()
        document["jobs"]["check"]["environment"] = "${{ inputs.environment }}"
        self.assertIn("environment", self.rules(document))

    def test_malformed_or_ambiguous_yaml_fails_closed(self):
        for source in ["on: [", "on: pull_request\non: push", "[]", "", "jobs: {}", "on: 7",
                       "on: pull_request\njobs: []", "!!python/object:os.system {}",
                       "on: &event pull_request\nother: *event", "on: pull_request\n---\non: push"]:
            with self.subTest(source=source):
                self.assertIn("workflow-format", {item.rule for item in policy.check_workflow(TRUSTED, source)})


if __name__ == "__main__":
    unittest.main()
