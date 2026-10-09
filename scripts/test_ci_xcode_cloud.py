"""Adversarial cases at the external Apple TV evidence trust boundary."""

import copy
import unittest
from pathlib import Path
from unittest.mock import patch

import ci_xcode_cloud as cloud
from ci_summary import ContractError, observation, test_identity


class CloudEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.identity = {"repository": "owner/repo", "event": "pull_request", "head_sha": "a" * 40,
                         "tree_sha": "b" * 40}
        self.run = {"id": 123, "run_attempt": 2, "event": "pull_request", "path": cloud.UI_PATH,
                    "head_sha": "a" * 40, "repository": {"full_name": "owner/repo"},
                    "head_repository": {"full_name": "owner/repo"}}
        self.population = [test_identity("ui", "ExampleTests/testExample", platform="tvos", device="appletv")]
        self.record = {"identity": self.identity, "run_id": 123,
                       "cloud_inputs": {"head_tree_sha": "b" * 40, "plan_sha256": "c" * 64,
                                        "fixture_sha256": "d" * 64, "source_sha256": "d" * 64, "plan": {}},
                       "ui_inputs": {"base": {"populations": {"appletv": {"default": self.population}}}},
                       "base_policy": {}, "candidate_policy": {}}
        self.route = {"schema_version": 1, "identity": self.identity, "producer_run_id": 123,
                      "producer_attempt": 2, "decision": "routed", "cloud_run_id": "1" * 8 + "-1111-1111-1111-" + "1" * 12,
                      "workflow_id": cloud.WORKFLOW_ID, "plan_sha256": "c" * 64}
        self.evidence = {"id": self.route["cloud_run_id"], "workflow_id": cloud.WORKFLOW_ID,
                         "head_sha": "a" * 40, "progress": "COMPLETE", "status": "SUCCEEDED",
                         "started": "2026-10-09T16:00:00Z", "finished": "2026-10-09T16:20:00Z",
                         "actions": [{"id": "2" * 8 + "-2222-2222-2222-" + "2" * 12,
                                      "name": cloud.ACTION_NAME, "type": "TEST", "progress": "COMPLETE",
                                      "status": "SUCCEEDED", "started": "2026-10-09T16:01:00Z",
                                      "finished": "2026-10-09T16:20:00Z", "tests": [{
                                          "id": "result-one", "class": "ExampleTests", "method": "testExample()",
                                          "status": "SUCCESS", "destinations": [{"device": cloud.DEVICE_NAME,
                                                                                      "os": "27.0", "status": "SUCCESS"}]}]}]}
        self.check = {"app": {"id": cloud.APP_ID, "slug": "xcode-cloud"}, "head_sha": "a" * 40,
                      "name": cloud.CHECK_NAME, "status": "completed", "conclusion": "success",
                      "details_url": "https://appstoreconnect.apple.com/teams/" + cloud.TEAM_ID +
                      "/apps/" + cloud.APPLE_APP_ID + "/ci/builds/" + self.evidence["id"] +
                      "/action/" + self.evidence["actions"][0]["id"]}

    def validate(self):
        with patch.object(cloud, "admitted_population", return_value=self.population):
            return cloud.validate_evidence(self.record, self.run, self.route, self.evidence, [self.check], approved=False)

    def test_exact_success_returns_every_identity_and_action_compute_time(self):
        result = self.validate()
        self.assertEqual(result["identities"], self.population)
        self.assertEqual(result["wall_minutes"], 20)
        self.assertEqual(result["compute_minutes"], 19)

    def test_missing_extra_duplicate_failed_skipped_and_wrong_destination_results_are_refused(self):
        original = copy.deepcopy(self.evidence)
        for mutation in ("missing", "extra", "duplicate", "failed", "skipped", "destination", "partial", "action"):
            with self.subTest(mutation=mutation):
                self.evidence = copy.deepcopy(original)
                action = self.evidence["actions"][0]
                tests = action["tests"]
                if mutation == "missing":
                    tests.clear()
                elif mutation in {"extra", "duplicate"}:
                    tests.append(copy.deepcopy(tests[0]))
                    if mutation == "extra":
                        tests[-1].update(id="other-result", method="testOther()")
                elif mutation in {"failed", "skipped"}:
                    tests[0]["status"] = mutation.upper()
                elif mutation == "destination":
                    tests[0]["destinations"][0]["device"] = "iPhone"
                elif mutation == "partial":
                    action["progress"] = "RUNNING"
                else:
                    self.evidence["actions"].append(copy.deepcopy(action))
                with self.assertRaises(ContractError):
                    self.validate()

    def test_wrong_head_workflow_attempt_tree_fork_and_unrouted_proof_are_refused(self):
        for target, field, value in ((self.evidence, "head_sha", "e" * 40),
                                     (self.evidence, "workflow_id", "other-workflow"),
                                     (self.route, "producer_attempt", 1),
                                     (self.route, "decision", "github"),
                                     (self.record["cloud_inputs"], "head_tree_sha", "f" * 40),
                                     (self.run["head_repository"], "full_name", "fork/repo"),
                                     (self.run, "event", "push")):
            with self.subTest(field=field, value=value):
                original = target[field]
                target[field] = value
                with self.assertRaises(ContractError):
                    self.validate()
                target[field] = original

    def test_app_check_is_required_but_does_not_replace_method_evidence(self):
        for target, field, value in ((self.check["app"], "id", 123),
                                     (self.check["app"], "slug", "impostor"),
                                     (self.check, "name", "Another workflow"),
                                     (self.check, "head_sha", "e" * 40),
                                     (self.check, "conclusion", "failure"),
                                     (self.check, "status", "in_progress"),
                                     (self.check, "details_url", "https://example.org/ci/builds/" + self.evidence["id"])):
            with self.subTest(field=field):
                original = target[field]
                target[field] = value
                with self.assertRaises(ContractError):
                    self.validate()
                target[field] = original

    def test_branch_or_old_attempt_importer_artifacts_are_not_trusted(self):
        workflow = {"id": 789, "path": cloud.IMPORT_PATH}
        uploader = {"id": 456, "workflow_id": 789, "path": cloud.IMPORT_PATH, "event": "workflow_dispatch",
                    "head_branch": "main", "head_sha": "a" * 40, "status": "completed", "conclusion": "success",
                    "run_attempt": 1, "repository": {"full_name": "owner/repo"},
                    "head_repository": {"full_name": "owner/repo"}}
        with patch.object(cloud, "on_main", return_value=True):
            cloud.validate_uploader(uploader, workflow, "owner/repo", cloud.IMPORT_PATH, 1)
            for field, value in (("head_branch", "candidate"), ("event", "pull_request"),
                                 ("run_attempt", 2), ("conclusion", "failure"), ("workflow_id", 999)):
                with self.subTest(field=field):
                    invalid = dict(uploader, **{field: value})
                    with self.assertRaises(ContractError):
                        cloud.validate_uploader(invalid, workflow, "owner/repo", cloud.IMPORT_PATH, 1)

    def test_github_ios_and_cloud_tv_are_both_required_without_fabricated_compiled_counts(self):
        from ci_publish_git import BASE_MODULES, OPTIONAL_BASE_MODULES, evaluate_records, workflow_contract
        from ci_ui_shards import shard_populations
        from test_ci_publish import FIXTURE_UI, RUN, UI_MANIFEST, UI_PLAN, admission_identity, PR, COMMIT, REPOSITORY
        from test_ci_summary import valid_summary
        from test_ci_verdict import approval_record
        source = FIXTURE_UI.replace("device: [iphone]", "device: [iphone, ipad, appletv]")
        run = dict(RUN, path=cloud.UI_PATH)
        identity = admission_identity(REPOSITORY, RUN, PR, COMMIT)
        populations = {device: shard_populations([test_identity("ui", key, platform=platform)
                      for key in ("NewUITests/testNew", "VisualUITests/testFlow")], UI_PLAN, UI_MANIFEST, device)
                       for device, platform in (("iphone", "ios"), ("ipad", "ios"), ("appletv", "tvos"))}
        ui = {"populations": populations, "base_populations": {device: [entry for entries in shards.values() for entry in entries]
               for device, shards in populations.items()}, "manifest_sha256": "e" * 64,
              "plans": {platform: {"sha256": "f" * 64} for platform in ("ios", "tvos")}}
        policy = {"schema_version": 1, "approval_records": [approval_record("ui")], "expected_skips": [], "deselections": []}
        record = {"identity": identity, "ui_inputs": {"base": ui, "candidate": ui},
                  "workflows": {cloud.UI_PATH: {"base": source, "candidate": source}},
                  "classification": {"app_affected": True, "ci_changing": False},
                  "base_policy": policy, "candidate_policy": policy}
        names, _, _, metadata = workflow_contract(source, run, metadata=True)
        jobs, summaries = [], []
        for name in names:
            meta = metadata[name]
            is_tv = meta.get("device") == "appletv"
            jobs.append({"name": name, "status": "completed", "conclusion": "skipped" if is_tv else "success",
                         "evidence_attempt": 1, "runner_id": None if is_tv else 1, "steps": []})
            if is_tv:
                continue
            expected = ([test_identity("host", "UI archive selection")] if name == "ui-archive"
                        else populations[meta["device"]][meta["shard"]])
            summary = valid_summary()
            summary.update(identity=identity, status="passed")
            summary["source"].update(repository=REPOSITORY, event="pull_request", workflow_path=cloud.UI_PATH, fork_originated=False)
            summary["run"] = {"id": str(run["id"]), "attempt": 1, **{key: meta[key] for key in ("tier", "job", "shard")}}
            summary["hashes"]["manifests"] = {"ui-shards": "e" * 64}
            if name != "ui-archive":
                summary["hashes"]["manifests"]["test-plan"] = "f" * 64
            summary["population"].update(declared=expected, compiled=expected,
                observed=[observation(entry, "passed", 0) for entry in expected], deselected=[], removed_by_pr=[])
            summaries.append(summary)
        tv = sorted([entry for entries in populations["appletv"].values() for entry in entries], key=lambda entry: entry["key"])
        modules = {name: (Path(__file__).parent / name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
        proof = {"identities": tv, "cloud_run_id": "verified-run"}
        with patch("ci_publish_git.trusted_reader", return_value=modules), patch.object(cloud, "admitted_population", return_value=tv):
            with self.assertRaises(ContractError):
                evaluate_records(record, run, jobs, summaries, approved=False, fork=False)
            result = evaluate_records(record, run, jobs, summaries, approved=False, fork=False, cloud=proof)
            self.assertEqual(result["state"], "success")
            self.assertEqual(sum(item["observed"] for item in result["population"]), 7)
            self.assertEqual(result["population"][-1], {"tier": "ui", "shard": "appletv/xcode-cloud",
                                                        "expected": 2, "compiled": None, "observed": 2})
            missing_ios = copy.deepcopy(summaries)
            missing_ios[1]["population"]["observed"] = []
            self.assertEqual(evaluate_records(record, run, jobs, missing_ios, approved=False, fork=False, cloud=proof)["state"], "failure")
            with self.assertRaises(ContractError):
                evaluate_records(record, run, jobs, summaries, approved=False, fork=False, cloud={"identities": tv[:1]})

    def test_asc_context_is_checked_before_signing_or_reading_credentials(self):
        from ci_xcode_cloud_api import jwt, credential_context
        environment = {"GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": "owner/repo",
                       "GITHUB_EVENT_NAME": "workflow_dispatch",
                       "GITHUB_WORKFLOW_REF": "owner/repo/" + cloud.IMPORT_PATH + "@refs/heads/main"}
        credential_context(environment, cloud.IMPORT_PATH)
        for field, value in (("GITHUB_REF", "refs/heads/candidate"), ("GITHUB_EVENT_NAME", "pull_request"),
                             ("GITHUB_WORKFLOW_REF", "owner/repo/.github/workflows/ci-ui.yml@refs/heads/main")):
            with self.subTest(field=field), patch("ci_xcode_cloud_api.subprocess.run") as signing:
                with self.assertRaises(ContractError):
                    jwt(dict(environment, **{field: value}), cloud.IMPORT_PATH)
                signing.assert_not_called()

    def test_asc_signature_and_pagination_refuse_malformed_or_cross_host_data(self):
        from ci_xcode_cloud_api import AppStoreConnect, raw_signature
        self.assertEqual(raw_signature(b"\x30\x06\x02\x01\x01\x02\x01\x02"), b"\0" * 31 + b"\x01" + b"\0" * 31 + b"\x02")
        for signature in (b"", b"\x30\x06\x02\x01\x81\x02\x01\x02", b"\x30\x08\x02\x01\x01\x02\x01\x02"):
            with self.assertRaises(ContractError):
                raw_signature(signature)
        client = AppStoreConnect("test-token")
        with patch("ci_xcode_cloud_api.build_opener") as network:
            with self.assertRaises(ContractError):
                client.request("https://example.org/v1/ciBuildRuns")
            network.assert_not_called()
        with patch.object(client, "request", return_value={"data": [{"id": "one"}], "links": {"next": "/v1/same"}}):
            with self.assertRaises(ContractError):
                client.pages("/v1/same")
        with patch.object(client, "request", return_value={"data": [{"id": "one"}, {"id": "one"}], "links": {}}):
            with self.assertRaises(ContractError):
                client.pages("/v1/same")

    def test_api_result_membership_is_checked_against_the_fixed_workflow_collection(self):
        from ci_xcode_cloud_api import AppStoreConnect
        client = AppStoreConnect("test-token")
        run_id = self.evidence["id"]
        run = {"id": run_id, "attributes": {"executionProgress": "RUNNING", "sourceCommit": {"commitSha": "a" * 40}}}
        with patch.object(client, "request", return_value={"data": run}), patch.object(client, "pages", return_value=[]):
            with self.assertRaises(ContractError):
                client.evidence(run_id)
        def pages(path):
            if path == "/v1/ciWorkflows/" + cloud.WORKFLOW_ID + "/buildRuns?limit=200":
                return [{"id": run_id}]
            self.assertEqual(path, "/v1/ciBuildRuns/" + run_id + "/actions?limit=200")
            return []
        with patch.object(client, "request", return_value={"data": run}), patch.object(client, "pages", side_effect=pages):
            evidence = client.evidence(run_id)
        self.assertEqual(evidence["workflow_id"], cloud.WORKFLOW_ID)
        self.assertEqual(evidence["progress"], "RUNNING")

    def test_actual_admitted_plan_is_checked_instead_of_trusting_a_receipt_count(self):
        import hashlib
        import json
        from check_xcode_cloud_ui import fixture_population
        root = Path(__file__).resolve().parent.parent
        shards = fixture_population(root)
        plan = (root / cloud.PLAN_PATH).read_bytes()
        policy = json.loads((root / "scripts/ci-test-policy.json").read_text())
        record = {"cloud_inputs": {"plan": json.loads(plan), "plan_sha256": hashlib.sha256(plan).hexdigest(),
                                  "fixture_sha256": "d" * 64, "source_sha256": "d" * 64},
                  "ui_inputs": {"base": {"populations": {"appletv": shards}}}, "base_policy": policy}
        expected = sorted([entry for entries in shards.values() for entry in entries], key=lambda entry: entry["key"])
        self.assertEqual(cloud.admitted_population(record, approved=False), expected)
        record["cloud_inputs"]["plan"]["testTargets"][0]["selectedTests"].pop()
        with self.assertRaises(ContractError):
            cloud.admitted_population(record, approved=False)


if __name__ == "__main__":
    unittest.main()
