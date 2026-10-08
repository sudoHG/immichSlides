"""Recorded GitHub payload seams guard trusted publication races and provenance."""

import copy
import unittest
from unittest.mock import patch

from ci_summary import ContractError
from ci_publish import (admission_identity, approval_context, approval_plan, authoritative_run,
                        check_credential_context, match_producer, publication_plan, verify_workflow,
                        producer_evidence, record_approval, write_publication, ArtifactRedirect, mint_app, approved_status)
from ci_publish_git import derive_record, base_reader, BASE_MODULES
from pathlib import Path
from test_ci_summary import valid_summary

# Reduced API payloads recorded from ci-gate on 2026-10-08. Repository names,
# IDs and SHAs are normalized; field shapes and the PR-head run SHA are retained.
REPOSITORY = "example/photos"
BASE = "a" * 40
HEAD = "b" * 40
MERGE = "c" * 40
TREE = "d" * 40
WORKFLOW = {"id": 42, "path": ".github/workflows/ci-gate.yml", "state": "active"}
RUN = {"id": 101, "workflow_id": 42, "path": ".github/workflows/ci-gate.yml", "event": "pull_request",
       "status": "completed", "conclusion": "success", "head_sha": HEAD, "run_attempt": 1,
       "head_branch": "feature", "repository": {"full_name": REPOSITORY},
       "head_repository": {"full_name": REPOSITORY}, "pull_requests": [{"number": 7}]}
PR = {"number": 7, "state": "open", "head": {"sha": HEAD, "repo": {"full_name": REPOSITORY}},
      "base": {"ref": "main", "repo": {"full_name": REPOSITORY}}}
COMMIT = {"sha": MERGE, "parents": [{"sha": BASE}, {"sha": HEAD}], "tree": {"sha": TREE}}


class PublisherTests(unittest.TestCase):
    def test_admission_uses_github_merge_parents_and_preserves_original_on_rerun(self):
        identity = admission_identity(REPOSITORY, RUN, PR, COMMIT)
        self.assertEqual((identity["base_sha"], identity["head_sha"], identity["merge_sha"], identity["tree_sha"]),
                         (BASE, HEAD, MERGE, TREE))
        moved = copy.deepcopy(COMMIT)
        moved["parents"][0]["sha"] = "e" * 40
        self.assertEqual(admission_identity(REPOSITORY, dict(RUN, run_attempt=2), PR, moved,
                                            existing=identity), identity)
        for field in ("sha", "parents"):
            bad = copy.deepcopy(COMMIT)
            bad[field] = None
            with self.subTest(field=field), self.assertRaises((ContractError, TypeError)):
                admission_identity(REPOSITORY, RUN, PR, bad)

    def test_producer_cannot_claim_an_older_base_or_computed_merge_tree(self):
        identity = admission_identity(REPOSITORY, RUN, PR, COMMIT)
        self.assertEqual(match_producer(identity, identity, attempt=1), None)
        for field in ("base_sha", "merge_sha", "tree_sha", "head_sha"):
            with self.subTest(field=field):
                forged = dict(identity, **{field: "e" * 40})
                self.assertIn("base moved; push again or update the branch", match_producer(forged, identity, attempt=1))
                self.assertIn("repeated", match_producer(forged, identity, attempt=2))

    def test_push_identity_requires_same_repository_main_and_ancestry(self):
        run = dict(RUN, event="push", head_branch="main", head_sha=MERGE, pull_requests=[])
        identity = admission_identity(REPOSITORY, run, None, COMMIT, on_main=True)
        self.assertEqual(identity["pushed_sha"], MERGE)
        for change in ({"head_branch": "other"}, {"repository": {"full_name": "fork/photos"}}):
            with self.subTest(change=change), self.assertRaises(ContractError):
                admission_identity(REPOSITORY, dict(run, **change), None, COMMIT, on_main=True)
        with self.assertRaises(ContractError):
            admission_identity(REPOSITORY, run, None, COMMIT, on_main=False)

    def test_newest_run_and_latest_attempt_override_delayed_success(self):
        failed = dict(RUN, id=102, run_attempt=2, conclusion="failure")
        self.assertEqual(authoritative_run([RUN, failed], HEAD, WORKFLOW, REPOSITORY), failed)
        rerun = dict(failed, run_attempt=3, status="in_progress", conclusion=None)
        self.assertEqual(authoritative_run([RUN, failed, rerun], HEAD, WORKFLOW, REPOSITORY), rerun)
        other_head = dict(RUN, id=103, head_sha="e" * 40)
        self.assertEqual(authoritative_run([RUN, other_head], HEAD, WORKFLOW, REPOSITORY), RUN)

    def test_workflow_name_collision_wrong_path_and_wrong_id_are_refused(self):
        verify_workflow(RUN, WORKFLOW, REPOSITORY)
        for change in ({"workflow_id": 99}, {"path": ".github/workflows/forged.yml"},
                       {"repository": {"full_name": "fork/photos"}}):
            with self.subTest(change=change), self.assertRaises(ContractError):
                verify_workflow(dict(RUN, **change), WORKFLOW, REPOSITORY)

    def test_completion_before_admission_and_rerun_stay_pending_until_re_evaluation(self):
        states = {"ci-pr-gate": {"state": "success", "description": "complete"},
                  "ci-ui": {"state": "success", "description": "not applicable"}}
        before = publication_plan(PR, {"ci-pr-gate": RUN}, {}, states, approved=False, needs_approval=False)
        self.assertEqual(before["ci-pr-gate"]["state"], "pending")
        after = publication_plan(PR, {"ci-pr-gate": RUN}, {101: {"identity": {"head_sha": HEAD}}}, states,
                                 approved=False, needs_approval=False)
        self.assertEqual(after["ci-pr-gate"]["state"], "success")
        rerun = publication_plan(PR, {"ci-pr-gate": dict(RUN, status="in_progress")},
                                 {101: {"identity": {"head_sha": HEAD}}}, states, approved=False, needs_approval=False)
        self.assertEqual(rerun["ci-pr-gate"]["state"], "pending")

    def test_fork_is_self_reported_and_approval_is_exact_head_display_only(self):
        fork = copy.deepcopy(PR)
        fork["head"]["repo"]["full_name"] = "contributor/photos"
        states = {context: {"state": "success", "description": "complete"} for context in ("ci-pr-gate", "ci-ui")}
        records = {101: {"identity": {"head_sha": HEAD}}}
        plan = publication_plan(fork, {"ci-pr-gate": RUN, "ci-ui": RUN}, records, states,
                                approved=False, needs_approval=True)
        self.assertEqual(plan["ci-pr-gate"]["state"], "failure")
        self.assertIn("self-reported", plan["ci-pr-gate"]["description"])
        self.assertNotIn(approval_context(7, HEAD), plan)
        approved = publication_plan(fork, {"ci-pr-gate": RUN, "ci-ui": RUN}, records, states,
                                    approved=True, needs_approval=True)
        self.assertEqual(approved["ci-pr-gate"]["state"], "success")
        self.assertIn("approval-based", approved["ci-pr-gate"]["description"])

    def test_publisher_read_approve_write_interleaving_never_overwrites_record(self):
        states = {context: {"state": "success", "description": "complete"} for context in ("ci-pr-gate", "ci-ui")}
        stale = publication_plan(PR, {"ci-pr-gate": RUN}, {101: {"identity": {"head_sha": HEAD}}}, states,
                                 approved=False, needs_approval=True)
        status_store = {approval_context(7, HEAD): "success"}
        status_store.update({key: value["state"] for key, value in stale.items()})
        self.assertEqual(status_store[approval_context(7, HEAD)], "success")

    def test_approval_request_is_per_head_and_old_request_is_obsolete(self):
        self.assertEqual(approval_plan(PR, [], approved=False, needs_approval=True)["request"], HEAD)
        request = {"head_sha": HEAD, "run_id": 200, "status": "waiting"}
        self.assertIsNone(approval_plan(PR, [request], approved=False, needs_approval=True)["request"])
        newer = copy.deepcopy(PR)
        newer["head"]["sha"] = "e" * 40
        plan = approval_plan(newer, [request], approved=False, needs_approval=True)
        self.assertEqual(plan["obsolete"], [200])
        self.assertEqual(plan["request"], "e" * 40)

    def test_pr_jobs_other_refs_and_wrong_workflows_are_refused_before_key_access(self):
        valid = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                 "GITHUB_REPOSITORY": REPOSITORY,
                 "GITHUB_WORKFLOW_REF": REPOSITORY + "/.github/workflows/ci-publish.yml@refs/heads/main"}
        check_credential_context(valid, ".github/workflows/ci-publish.yml")
        for change in ({"GITHUB_EVENT_NAME": "pull_request"}, {"GITHUB_REF": "refs/heads/other"},
                       {"GITHUB_WORKFLOW_REF": REPOSITORY + "/.github/workflows/other.yml@refs/heads/main"}):
            with self.subTest(change=change), self.assertRaises(ContractError):
                check_credential_context(dict(valid, **change), ".github/workflows/ci-publish.yml")

    def test_admission_persists_derived_tree_population_and_base_reader_for_late_approval(self):
        identity = admission_identity(REPOSITORY, RUN, PR, COMMIT)
        tree = [{"path": "scripts/test_probe.py", "mode": "100644", "type": "blob", "sha": TREE}]
        populations = {"host": [{"kind": "host", "key": "format", "dimensions": {}}]}
        derived = {"populations": populations, "classification": {"ci_changing": False, "app_affected": False}}
        def blob(commit, path):
            if path.endswith(".json"):
                return '{"schema_version":1}'
            if path.endswith("ci_build_archive.py"):
                return 'def run_build():\n step = test_identity("host", "secret-free build archive", platform=args.platform, configuration="Debug")\n'
            return "trusted base module" if commit == BASE else "candidate text"
        with patch("ci_publish_git.read_blob", side_effect=blob), patch("ci_publish_git.tree_inputs", return_value=(tree, {})), \
                patch("ci_publish_git.git", return_value="docs/example.md"), patch("ci_publish_git.base_reader", return_value=derived):
            record = derive_record(identity, RUN)
        self.assertEqual(record["tree_listing"], tree)
        self.assertEqual(record["populations"], populations)
        self.assertEqual(record["identity"], identity)
        self.assertEqual(record["reader_revision"], BASE)
        self.assertNotIn("base_modules", record)

    def test_latest_job_execution_controls_artifacts_in_failed_job_reruns(self):
        source = '''jobs:
  host:
    name: renamed-host
    steps:
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with:
          name: host-${{ github.run_id }}-${{ github.run_attempt }}
          path: records/summary.json
'''
        summary = valid_summary()
        summary["run"].update(id="101", attempt=1)
        job = {"name": "renamed-host", "status": "completed", "conclusion": "success"}
        class RecordedAPI:
            def pages(self, path, collection):
                if path.endswith("/artifacts"):
                    return [{"name": "host-101-1", "expired": False}]
                return [job] if "/attempts/1/" in path else []
        with patch("ci_publish.json_member", return_value=summary):
            jobs, summaries = producer_evidence(RecordedAPI(), dict(RUN, run_attempt=2), source)
        self.assertEqual(jobs[0]["evidence_attempt"], 1)
        self.assertEqual(summaries[0]["run"]["attempt"], 1)
        class RerunAPI(RecordedAPI):
            def pages(self, path, collection):
                return [job] if "/attempts/2/" in path else super().pages(path, collection)
        with patch("ci_publish.json_member", return_value=summary), self.assertRaises(ContractError):
            producer_evidence(RerunAPI(), dict(RUN, run_attempt=2), source)

    def test_credential_free_approval_requires_the_actual_environment_reviewer(self):
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_REPOSITORY": REPOSITORY, "GITHUB_RUN_ID": "200",
                       "GITHUB_WORKFLOW_REF": REPOSITORY + "/.github/workflows/ci-approval.yml@refs/heads/main"}
        class RecordedAPI:
            repository = REPOSITORY
            def __init__(self, reviewer):
                self.reviewer, self.dispatched = reviewer, False
            def repo(self, path):
                return [{"state": "approved", "user": {"login": self.reviewer},
                         "environments": [{"name": "ci-approval"}]}] if path.endswith("/approvals") else PR
            def pages(self, path):
                return []
            def status(self, *args):
                pass
            def dispatch(self, *args):
                self.dispatched = True
        event = {"inputs": {"pull_request": "7", "head_sha": HEAD}}
        api = RecordedAPI("example")
        record_approval(api, api, event, environment, "generic-app[bot]", ".github/workflows/ci-approval.yml")
        self.assertTrue(api.dispatched)
        with self.assertRaises(ContractError):
            wrong = RecordedAPI("outsider")
            record_approval(wrong, wrong, event, environment, "generic-app[bot]", ".github/workflows/ci-approval.yml")

    def test_reserved_approval_is_not_dispatched_twice_and_dry_run_never_writes(self):
        class RecordedAPI:
            repository = REPOSITORY
            def __init__(self):
                self.writes, self.dispatches = [], []
            def repo(self, path):
                return PR
            def pages(self, path):
                return [{"context": f"ci-approval-request/pr-7/{HEAD}", "creator": {"login": "generic-app[bot]"}}]
            def status(self, *args):
                self.writes.append(args)
            def dispatch(self, *args):
                self.dispatches.append(args)
        plan = {context: {"state": "pending", "description": "pending"} for context in ("ci-pr-gate", "ci-ui", "ci-approval-state")}
        api = RecordedAPI()
        with patch("ci_publish.compute", return_value=(HEAD, plan, {"request": HEAD, "obsolete": []})), \
                patch("ci_publish.os.environ", {}):
            write_publication(api, api, 7, "", "generic-app[bot]")
            self.assertEqual(len(api.writes), 3)
            self.assertEqual(api.dispatches, [])
            with patch("builtins.print"):
                write_publication(api, api, 7, "", "generic-app[bot]", dry_run=True)
            self.assertEqual(len(api.writes), 3)

    def test_artifact_redirect_never_forwards_installation_credentials_to_storage(self):
        from urllib.request import Request
        request = Request("https://api.github.com/artifact", headers={"Authorization": "Bearer test-value"})
        redirected = ArtifactRedirect().redirect_request(request, None, 302, "redirect", {}, "https://storage.example/artifact")
        self.assertIsNone(redirected.get_header("Authorization"))
        with self.assertRaises(ContractError):
            ArtifactRedirect().redirect_request(request, None, 302, "redirect", {}, "http://storage.example/artifact")

    def test_approving_commit_a_never_authorizes_commit_b_or_another_status_creator(self):
        class RecordedAPI:
            def __init__(self, context, login):
                self.context, self.login = context, login
            def pages(self, path):
                return [{"context": self.context, "state": "success", "creator": {"login": self.login}}]
        login = "generic-app[bot]"
        self.assertTrue(approved_status(RecordedAPI(approval_context(7, HEAD), login), PR, login))
        new_pr = copy.deepcopy(PR)
        new_pr["head"]["sha"] = "e" * 40
        self.assertFalse(approved_status(RecordedAPI(approval_context(7, HEAD), login), new_pr, login))
        self.assertFalse(approved_status(RecordedAPI(approval_context(7, HEAD), "outsider"), PR, login))

    def test_minting_rejects_untrusted_context_without_reading_the_private_key(self):
        class UntrustedEnvironment(dict):
            def get(self, key, default=None):
                if key == "CI_APP_PRIVATE_KEY":
                    raise AssertionError("private key read before context rejection")
                return super().get(key, default)
        environment = UntrustedEnvironment(GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/7/merge")
        with self.assertRaises(ContractError):
            mint_app(environment, ".github/workflows/ci-publish.yml")

    def test_base_reader_enumerates_candidate_text_without_executing_candidate_verdict_code(self):
        # Reading the actual reader is necessary here: this is a security seam
        # for a result-judging tool, not an assertion on implementation text.
        root = Path(__file__).parent
        modules = {name: (root / name).read_text() for name in BASE_MODULES}
        payload = {"operation": "derive", "sources": {
            "scripts/ci_verdict.py": 'raise RuntimeError("candidate verdict executed")',
            "scripts/test_candidate.py": 'import unittest\nclass Example(unittest.TestCase):\n def test_works(self): pass\n'},
            "paths": ["scripts/ci_verdict.py"], "build_target_paths": [],
            "classification_policy": {"schema_version": 1, "app_unaffected": ["docs/**"], "ci_trusted": ["scripts/ci_*.py"]}}
        result = base_reader(modules, payload)
        self.assertTrue(result["classification"]["ci_changing"])
        self.assertTrue(any(identity["key"] == "test_candidate.Example.test_works" for identity in result["populations"]["host"]))
