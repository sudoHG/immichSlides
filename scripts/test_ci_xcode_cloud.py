"""Adversarial cases at the external Apple TV evidence trust boundary."""

import copy
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock, patch

import ci_xcode_cloud as cloud
from ci_summary import ContractError, observation, test_identity


class CloudEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.identity = {"repository": "owner/repo", "event": "pull_request", "head_sha": "a" * 40,
                         "tree_sha": "b" * 40}
        self.run = {"id": 123, "run_attempt": 2, "event": "pull_request", "path": cloud.UI_PATH,
                    "status": "in_progress", "run_started_at": datetime.now(timezone.utc).isoformat(),
                    "head_sha": "a" * 40, "repository": {"full_name": "owner/repo"},
                    "head_repository": {"full_name": "owner/repo"}}
        self.population = [test_identity("ui", "ExampleTests/testExample", platform="tvos", device="appletv")]
        self.record = {"identity": self.identity, "run_id": 123,
                       "classification": {"app_affected": True},
                       "cloud_inputs": {"head_tree_sha": "b" * 40, "plan_sha256": "c" * 64,
                                        "fixture_sha256": "d" * 64, "source_sha256": "d" * 64, "plan": {}},
                       "ui_inputs": {"base": {"populations": {"appletv": {"default": self.population}}}},
                       "base_policy": {}, "candidate_policy": {}}
        self.route = {"schema_version": 1, "identity": self.identity, "producer_run_id": 123,
                      "producer_attempt": 2, "decision": "routed", "cloud_run_id": "1" * 8 + "-1111-1111-1111-" + "1" * 12,
                      "workflow_id": cloud.WORKFLOW_ID, "plan_sha256": "c" * 64}
        self.evidence = {"id": self.route["cloud_run_id"], "workflow_id": cloud.WORKFLOW_ID,
                         "is_pull_request_build": False,
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
                      "id": 1,
                      "name": cloud.CHECK_NAME, "status": "completed", "conclusion": "success",
                      "details_url": "https://appstoreconnect.apple.com/teams/" + cloud.TEAM_ID +
                      "/apps/" + cloud.APPLE_APP_ID + "/ci/builds/" + self.evidence["id"] +
                      "/action/" + self.evidence["actions"][0]["id"]}

    def validate(self, checks=None):
        with patch.object(cloud, "admitted_population", return_value=self.population):
            return cloud.validate_evidence(self.record, self.run, self.route, self.evidence,
                                           [self.check] if checks is None else checks, approved=False)

    def test_newer_same_head_app_check_cannot_be_hidden_by_an_old_success(self):
        for status, conclusion in (("completed", "failure"), ("completed", "cancelled"),
                                   ("in_progress", None), ("completed", "success")):
            newer = dict(self.check, id=2, status=status, conclusion=conclusion,
                         details_url=self.check["details_url"] + "-another-execution")
            with self.subTest(status=status, conclusion=conclusion), self.assertRaises(ContractError):
                self.validate([self.check, newer])
        with self.assertRaises(ContractError):
            self.validate([self.check, dict(self.check)])

    def test_cloud_branch_run_cannot_be_a_pull_request_merge_build(self):
        for value in (True, None, "false", 0):
            self.evidence["is_pull_request_build"] = value
            with self.subTest(value=value), self.assertRaises(ContractError):
                self.validate()

    def test_untrusted_uploaders_are_filtered_before_opening_fork_main_artifact_bytes(self):
        workflow = {"id": 789, "path": cloud.IMPORT_PATH}
        trusted = {"id": 456, "workflow_id": 789, "path": cloud.IMPORT_PATH, "event": "workflow_dispatch",
                   "head_branch": "main", "head_sha": "a" * 40, "status": "completed", "conclusion": "success",
                   "run_attempt": 1, "repository": {"full_name": "owner/repo"},
                   "head_repository": {"full_name": "owner/repo"}}
        api = Mock(repository="owner/repo")
        artifact = lambda run_id: {"id": run_id, "name": "receipt", "expired": False, "workflow_run": {"id": run_id}}
        receipt = {"uploader_run_id": 456, "uploader_attempt": 1, "route_artifact_id": 55, "evidence": self.evidence}
        for mutation in ("fork", "event", "history"):
            hostile = copy.deepcopy(trusted)
            hostile["id"] = 123
            if mutation == "fork":
                hostile["head_repository"]["full_name"] = "fork/repo"
            elif mutation == "event":
                hostile["event"] = "pull_request"
            else:
                hostile["head_sha"] = "b" * 40
            api.repo.side_effect = lambda path, **_: workflow if "workflows/" in path else hostile if path.endswith("123") else trusted
            api.pages.return_value = [artifact(123), artifact(456)]
            with self.subTest(mutation=mutation), patch("ci_publish.git"), \
                    patch.object(cloud, "on_main", side_effect=lambda value: value == "a" * 40), \
                    patch("ci_publish.json_member", return_value=receipt) as read:
                self.assertEqual(cloud.trusted_artifact(api, "receipt", cloud.IMPORT_PATH, "cloud.json"), (receipt, 456))
                self.assertEqual([call.args[1]["id"] for call in read.call_args_list], [456])

    def test_duplicate_import_receipts_need_identical_evidence_and_route_binding(self):
        api = Mock(repository="owner/repo")
        workflow = {"id": 789, "path": cloud.IMPORT_PATH}
        def uploader(path, **_):
            if "workflows/" in path:
                return workflow
            return {"id": int(path.split('/')[2]), "workflow_id": 789, "path": cloud.IMPORT_PATH,
                    "event": "workflow_dispatch", "head_branch": "main", "head_sha": "a" * 40,
                    "status": "completed", "conclusion": "success", "run_attempt": 1,
                    "repository": {"full_name": "owner/repo"}, "head_repository": {"full_name": "owner/repo"}}
        api.repo.side_effect = uploader
        api.pages.return_value = [{"id": number, "name": "receipt", "expired": False, "workflow_run": {"id": number}}
                                 for number in (456, 457)]
        receipts = [{"uploader_run_id": number, "uploader_attempt": 1, "route_artifact_id": 55,
                     "evidence": copy.deepcopy(self.evidence)} for number in (456, 457)]
        def read(_api, artifact, _member):
            return receipts[artifact["id"] - 456]
        with patch("ci_publish.git"), patch.object(cloud, "on_main", return_value=True), patch("ci_publish.json_member", side_effect=read):
            self.assertEqual(cloud.trusted_artifact(api, "receipt", cloud.IMPORT_PATH, "cloud.json"), (receipts[0], 456))
            for field, value in (("route_artifact_id", 66), ("evidence", {})):
                original = receipts[1][field]
                receipts[1][field] = value
                with self.subTest(field=field), self.assertRaises(ContractError):
                    cloud.trusted_artifact(api, "receipt", cloud.IMPORT_PATH, "cloud.json")
                receipts[1][field] = original

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
        source += '''  cloud:
    name: ui-cloud-wait
    steps:
      - run: python3 scripts/ci_ui_tests.py wait-cloud
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: {name: 'ui-cloud-selection-${{ github.run_id }}-${{ github.run_attempt }}', path: records/summary.json}
'''
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
            expected = ([test_identity("host", "UI archive selection")] if name == "ui-archive" else
                        [test_identity("host", "Apple TV cloud selection")] if name == "ui-cloud-wait"
                        else populations[meta["device"]][meta["shard"]])
            summary = valid_summary()
            summary.update(identity=identity, status="passed")
            summary["source"].update(repository=REPOSITORY, event="pull_request", workflow_path=cloud.UI_PATH, fork_originated=False)
            summary["run"] = {"id": str(run["id"]), "attempt": 1, **{key: meta[key] for key in ("tier", "job", "shard")}}
            summary["hashes"]["manifests"] = {"ui-shards": "e" * 64}
            if meta["tier"] == "ui":
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
            self.assertEqual(sum(item["observed"] for item in result["population"]), 8)
            self.assertEqual(result["population"][-1], {"tier": "ui", "shard": "appletv/xcode-cloud",
                                                        "expected": 2, "compiled": None, "observed": 2})
            missing_ios = copy.deepcopy(summaries)
            missing_ios[1]["population"]["observed"] = []
            self.assertEqual(evaluate_records(record, run, jobs, missing_ios, approved=False, fork=False, cloud=proof)["state"], "failure")
            with self.assertRaises(ContractError):
                evaluate_records(record, run, jobs, summaries, approved=False, fork=False, cloud={"identities": tv[:1]})
            removed = test_identity("ui", "RemovedTests/testRemoved", platform="tvos", device="appletv")
            ui["base_populations"]["appletv"].append(removed)
            policy["deselections"] = [{"identity": tv[1], "tier": "ui", "environment": "fixture",
                                       "reason": "Owned by another controlled tier", "owning_tier": "controlled"}]
            with patch.object(cloud, "admitted_population", return_value=tv[:1]):
                result = evaluate_records(record, run, jobs, summaries, approved=False, fork=False,
                                          cloud={"identities": tv[:1], "cloud_run_id": "verified-run"})
            self.assertEqual(result["removed_by_pr"], [removed])
            self.assertEqual(result["deselected"], [{key: policy["deselections"][0][key]
                                                    for key in ("identity", "reason", "owning_tier")}])

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
                                  "scheme": (root / cloud.SCHEME_PATH).read_text(), "plan_paths": [cloud.PLAN_PATH],
                                  "fixture_sha256": "d" * 64, "source_sha256": "d" * 64},
                  "ui_inputs": {"base": {"populations": {"appletv": shards}}}, "base_policy": policy}
        expected = sorted([entry for entries in shards.values() for entry in entries], key=lambda entry: entry["key"])
        self.assertEqual(cloud.admitted_population(record, approved=False), expected)
        record["cloud_inputs"]["plan"]["testTargets"][0]["selectedTests"].pop()
        with self.assertRaises(ContractError):
            cloud.admitted_population(record, approved=False)
        record["cloud_inputs"]["plan"] = json.loads(plan)
        original = record["cloud_inputs"]["scheme"]
        for scheme in (original.replace("container:" + cloud.PLAN_PATH, "container:other/" + cloud.PLAN_PATH),
                       original.replace("<TestPlans>", "<PreActions/><TestPlans>"),
                       original.replace("<TestPlans>", "<PostActions/><TestPlans>")):
            record["cloud_inputs"]["scheme"] = scheme
            with self.subTest(scheme=scheme[:30]), self.assertRaises(ContractError):
                cloud.admitted_population(record, approved=False)
        record["cloud_inputs"]["scheme"] = original
        record["cloud_inputs"]["plan_paths"].append("other/" + cloud.PLAN_PATH)
        with self.assertRaises(ContractError):
            cloud.admitted_population(record, approved=False)

    def test_archive_job_execution_binds_the_proof_across_failed_job_reruns(self):
        api = Mock()
        api.pages.side_effect = [[{"id": 777, "name": "ui-archive"}], [{"id": 777, "name": "ui-archive"}]]
        result = cloud.archive_evidence_run(api, self.run)
        self.assertEqual((result["run_attempt"], result["producer_latest_attempt"]), (1, 2))
        api.pages.side_effect = [[{"id": 777, "name": "ui-archive"}], [{"id": 888, "name": "ui-archive"}]]
        self.assertEqual(cloud.archive_evidence_run(api, self.run)["run_attempt"], 2)
        execution = {"name": "ui-archive", "started_at": "2026-10-09T00:00:00Z", "completed_at": "2026-10-09T00:01:00Z", "runner_id": 99}
        api.pages.side_effect = [[dict(execution, id=777)], [dict(execution, id=888)]]
        self.assertEqual(cloud.archive_evidence_run(api, self.run)["run_attempt"], 1)

    def test_receipts_validate_the_claimed_historical_uploader_attempt(self):
        api = Mock(repository="owner/repo")
        workflow = {"id": 789, "path": cloud.ROUTE_PATH}
        uploader = {"id": 456, "workflow_id": 789, "path": cloud.ROUTE_PATH, "event": "workflow_dispatch",
                    "head_branch": "main", "head_sha": "a" * 40, "status": "completed", "conclusion": "success",
                    "run_attempt": 2, "repository": {"full_name": "owner/repo"}, "head_repository": {"full_name": "owner/repo"}}
        def response(path, **_):
            if "workflows/" in path:
                return workflow
            return dict(uploader, run_attempt=1) if "/attempts/1" in path else uploader
        api.repo.side_effect = response
        api.pages.return_value = [{"id": 99, "name": "receipt", "expired": False, "workflow_run": {"id": 456}}]
        receipt = {"uploader_run_id": 456, "uploader_attempt": 1}
        with patch("ci_publish.git"), patch.object(cloud, "on_main", return_value=True), \
                patch("ci_publish.json_member", return_value=receipt):
            for status, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "cancelled")):
                uploader.update(status=status, conclusion=conclusion)
                api.repo.side_effect = lambda path, **_: workflow if "workflows/" in path else (
                    dict(uploader, run_attempt=1, status="completed", conclusion="success") if "/attempts/1" in path else uploader)
                with self.subTest(status=status, conclusion=conclusion):
                    self.assertEqual(cloud.trusted_artifact(api, "receipt", cloud.ROUTE_PATH, "route.json"), (receipt, 99))
                    self.assertIn(unittest.mock.call("actions/runs/456/attempts/1"), api.repo.call_args_list)
            api.repo.side_effect = lambda path, **_: workflow if "workflows/" in path else (
                dict(uploader, run_attempt=1, status="completed", conclusion="failure") if "/attempts/1" in path else uploader)
            with self.assertRaises(ContractError):
                cloud.trusted_artifact(api, "receipt", cloud.ROUTE_PATH, "route.json")

    def test_scheduling_artifacts_authenticate_the_main_attempt_before_reading(self):
        import ci_xcode_cloud_state as state
        api = Mock(repository="owner/repo")
        artifact = {"name": "ci-xcc-post-456-1", "expired": False, "workflow_run": {"id": 456}}
        workflow = {"id": 789, "path": cloud.ROUTE_PATH}
        uploader = {"id": 456, "run_attempt": 1, "workflow_id": 789, "path": cloud.ROUTE_PATH,
                    "event": "workflow_dispatch", "head_branch": "main", "head_sha": "a" * 40,
                    "status": "completed", "conclusion": "cancelled", "repository": {"full_name": "owner/repo"},
                    "head_repository": {"full_name": "owner/repo"}}
        api.repo.return_value = uploader
        with patch.object(state, "on_main", return_value=True), patch.object(state, "json_member", return_value={"uploader_run_id": 456, "uploader_attempt": 1}) as read:
            state.read_state(api, artifact, workflow, prefix=state.POST_PREFIX, member="post.json")
            read.reset_mock()
            uploader["head_repository"]["full_name"] = "fork/repo"
            with self.assertRaises(ContractError):
                state.read_state(api, artifact, workflow, prefix=state.POST_PREFIX, member="post.json")
            read.assert_not_called()

    def test_collapsed_tv_matrix_requires_verified_cloud_proof_and_cannot_cover_ios(self):
        from ci_ui_reuse import expand_skipped_ui_matrix
        from ci_publish_git import workflow_contract
        from test_ci_publish import FIXTURE_UI, RUN
        source = FIXTURE_UI.replace("device: [iphone]", "device: [appletv]").replace(
            "name: ui-${{ matrix.device }}-${{ matrix.shard }}", "name: ui-appletv-${{ matrix.shard }}")
        run = dict(RUN, path=cloud.UI_PATH)
        placeholder = "ui-appletv-${{ matrix.shard }}"
        jobs = [{"name": "ui-archive", "status": "completed", "conclusion": "success"},
                {"name": placeholder, "status": "completed", "conclusion": "skipped", "runner_id": 0, "steps": []}]
        self.assertIn(placeholder, cloud.apple_tv_skip_names(source, run))
        with self.assertRaises(ContractError):
            expand_skipped_ui_matrix(source, run, jobs)
        normalized = expand_skipped_ui_matrix(source, run, jobs, cloud=True)
        self.assertEqual({job["name"] for job in normalized}, set(workflow_contract(source, run)[0]))
        discarded = set()
        earlier = expand_skipped_ui_matrix(source, run, jobs, historical=True, complete=False, discarded_shards=discarded)
        self.assertEqual({job["name"] for job in earlier}, {"ui-archive"})
        self.assertEqual(discarded, set(workflow_contract(source, run)[0]) - {"ui-archive"})
        jobs[1]["steps"] = [{"name": "executed"}]
        with self.assertRaises(ContractError):
            expand_skipped_ui_matrix(source, run, jobs, cloud=True)
        self.assertNotIn("ui-${{ matrix.device }}-${{ matrix.shard }}", cloud.apple_tv_skip_names(FIXTURE_UI, run))
        ios_jobs = [{"name": "ui-archive", "status": "completed", "conclusion": "success"},
                    {"name": "ui-${{ matrix.device }}-${{ matrix.shard }}", "status": "completed",
                     "conclusion": "skipped", "runner_id": 0, "steps": []}]
        with self.assertRaises(ContractError):
            expand_skipped_ui_matrix(FIXTURE_UI, run, ios_jobs, cloud=True)


class RoutingPolicyTests(unittest.TestCase):
    def test_inventory_reuses_exact_heads_and_bounds_stuck_builds_without_quota_artifacts(self):
        import ci_xcode_cloud_route as router
        from datetime import timedelta
        fixture = CloudEvidenceTests()
        fixture.setUp()
        now = datetime.now(timezone.utc)
        asc = Mock()
        run = {"id": fixture.evidence["id"], "attributes": {"executionProgress": "PENDING",
               "createdDate": now.isoformat(), "sourceCommit": {"commitSha": fixture.run["head_sha"]}}}
        asc.pages.return_value = [run]
        result = router.start_cloud(asc, dict(fixture.route, reference_id="reference"))
        self.assertEqual(result["cloud_run_id"], run["id"])
        asc.request.assert_not_called()
        run["attributes"]["sourceCommit"] = None
        self.assertEqual(router.start_cloud(asc, dict(fixture.route, reference_id="reference"))["reason"], "overflow-build-in-flight")
        asc.request.assert_not_called()
        run["attributes"]["createdDate"] = (now - timedelta(hours=4)).isoformat()
        asc.request.return_value = {"data": {"id": fixture.evidence["id"], "attributes": {"createdDate": now.isoformat()}}}
        with patch.object(router, "month_usage", return_value={"minutes": 100}):
            self.assertEqual(router.start_cloud(asc, dict(fixture.route, reference_id="reference"))["reason"], "cloud-started")
        self.assertEqual(asc.request.call_count, 1)

    def test_router_503_for_more_than_sixty_seconds_then_recovery_still_routes(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api, asc, elapsed = Mock(), Mock(), [0]
        asc.request.return_value = {"data": {"attributes": {"executionProgress": "COMPLETE",
            "completionStatus": "SUCCEEDED", "sourceCommit": {"commitSha": fixture.run["head_sha"]}}}}
        asc.evidence.return_value = fixture.evidence
        def checks(*args, **kwargs):
            if elapsed[0] < 61:
                elapsed[0] = 61
                raise ContractError("GitHub HTTP 503")
            return [fixture.check]
        api.pages.side_effect = checks
        with patch.object(router, "refresh_producer"), patch.object(cloud, "admitted_population", return_value=fixture.population):
            result = router.poll_route(api, asc, fixture.record, fixture.run, dict(fixture.route, decision="pending"),
                monotonic=lambda: elapsed[0], sleep=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds))
        self.assertEqual(result["decision"], "routed")
        self.assertGreater(elapsed[0], 60)

    def test_post_without_created_date_fetches_start_receipt_and_waits_through_the_marker_race(self):
        import ci_ui_tests as producer
        import ci_xcode_cloud_route as router
        import ci_xcode_cloud_state as state
        fixture = CloudEvidenceTests()
        fixture.setUp()
        now = datetime.now(timezone.utc).isoformat()
        fixture.identity.update(schema_version=1, pull_request=1, merge_sha="e" * 40, base_sha="f" * 40)
        fixture.record["schema_version"] = 1
        api, asc = Mock(repository="owner/repo"), Mock()
        workflow = {"id": 789, "path": cloud.ROUTE_PATH, "state": "active"}
        source = {"id": 456, "run_attempt": 1, "display_title": "xcc-route-123-2", "workflow_id": 789,
                  "event": "workflow_dispatch", "path": cloud.ROUTE_PATH, "head_branch": "main", "head_sha": "b" * 40,
                  "repository": {"full_name": "owner/repo"}, "head_repository": {"full_name": "owner/repo"}}
        publisher = dict(source, id=345, workflow_id=567, event="workflow_run", path=".github/workflows/ci-publish.yml")
        def response(path, **_):
            if path.endswith("ci-publish.yml"):
                return {"id": 567, "path": publisher["path"]}
            if path.endswith("/345"):
                return publisher
            if "/runs?" in path:
                return {"workflow_runs": [source]}
            if "ci-xcode-cloud-" in path:
                return workflow
            return source if "456" in path else fixture.run
        api.repo.side_effect = response
        artifacts = [{"name": "ci-xcc-post-456-1", "expired": False, "workflow_run": {"id": 456}}]
        api.pages.side_effect = lambda *args, **kwargs: ([{"name": "ci-admission-123", "expired": False,
            "workflow_run": {"id": 345}}] if kwargs.get("name") == "ci-admission-123" else list(artifacts))
        posted = dict(fixture.route, head_sha=fixture.run["head_sha"], uploader_run_id=456, uploader_attempt=1, posted_at=now)
        receipts = {"post.json": posted}
        asc.pages.return_value = []
        asc.request.side_effect = [{"data": {"id": fixture.evidence["id"]}},
                                   {"data": {"id": fixture.evidence["id"], "attributes": {"createdDate": now}}}]
        def upload_start(_seconds):
            value = router.start_cloud(asc, dict(posted, reference_id="reference"))
            receipts["start.json"] = dict(posted, **value)
            artifacts.append({"name": "ci-xcc-start-456-1", "expired": False, "workflow_run": {"id": 456}})
        ctx = {"identity": fixture.identity, "source": {"fork_originated": False}, "run": {"id": "123", "attempt": 2}}
        with patch("ci_publish.git") as git, patch.object(state, "on_main", return_value=True), \
                patch("ci_publish.subprocess.run", return_value=Mock(returncode=0)), \
                patch("ci_publish.json_member", return_value=fixture.record), \
                patch.object(state, "json_member", side_effect=lambda api, artifact, member: receipts[member]), \
                patch.object(producer, "verify_workflow"), \
                patch.object(router, "month_usage", return_value={"minutes": 0}), \
                patch.object(router, "producer_decision", side_effect=["github", "github", "routed"]), \
                patch.object(cloud, "trusted_artifact", return_value=(fixture.route, 55)), \
                patch.object(producer.time, "sleep", side_effect=upload_start) as sleep:
            self.assertEqual(producer.wait_cloud(ctx, api), "routed")
            sleep.assert_called_once()
            git.assert_called_once_with("fetch", "--no-tags", "origin", "refs/heads/main")
        self.assertEqual(asc.request.call_args_list[0].kwargs["method"], "POST")
        self.assertEqual(asc.request.call_args_list[1].args[0], "/v1/ciBuildRuns/" + fixture.evidence["id"])
        self.assertEqual(receipts["start.json"]["cloud_created_at"], now)

    def test_start_window_and_wait_deadline_allow_queueing_without_indefinite_pending(self):
        from ci_xcode_cloud_route import remaining_seconds, cloud_wait_deadline
        from datetime import timedelta
        now = datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc)
        run = {"run_started_at": (now - timedelta(minutes=29)).isoformat()}
        self.assertEqual(remaining_seconds(run, now), 60)
        self.assertEqual(remaining_seconds(run, now + timedelta(minutes=2)), 0)
        self.assertAlmostEqual(cloud_wait_deadline(0), 99.7 * 60)
        self.assertAlmostEqual(cloud_wait_deadline(50 * 60), 149.7 * 60)

    def test_github_reads_retry_transient_errors_but_dispatches_do_not_replay(self):
        from ci_xcode_cloud_client import RetryingGitHub
        from ci_publish import GitHub
        elapsed = [0]
        client = RetryingGitHub("owner/repo", "test-token", 120, timer=lambda: elapsed[0],
                              sleep=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds))
        with patch.object(GitHub, "request", side_effect=[ContractError("HTTP 429"), TimeoutError(), {"id": 1}, ContractError("HTTP 503")]) as network:
            self.assertEqual(client.request("/repos/owner/repo/actions/runs/1"), {"id": 1})
            self.assertEqual(elapsed[0], 6)
            with self.assertRaises(ContractError):
                client.request("/repos/owner/repo/actions/workflows/route/dispatches", method="POST", payload={})
            self.assertEqual(network.call_count, 4)

    def test_known_terminal_build_does_not_block_even_when_its_head_cannot_count(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        result = {"cloud_run_id": fixture.evidence["id"]}
        inventory = [{"id": result["cloud_run_id"], "attributes": {"executionProgress": "COMPLETE",
                     "sourceCommit": {"commitSha": "f" * 40}}}]
        self.assertEqual(router.blocking_builds(inventory, datetime.now(timezone.utc)), [])
        fixture.evidence["head_sha"] = "f" * 40
        with self.assertRaises(ContractError):
            fixture.validate()

    def test_a_terminal_wrong_head_build_does_not_block_the_next_producer_start(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api, asc = Mock(), Mock()
        old_id = "11111111-1111-1111-1111-111111111111"
        def pages(path):
            if "/scmRepositories/" in path:
                return [{"id": "reference", "attributes": {"canonicalName": "refs/heads/branch"}}]
            return [{"id": old_id, "attributes": {"executionProgress": "COMPLETE", "sourceCommit": {"commitSha": "f" * 40}}}]
        asc.pages.side_effect = pages
        asc.request.return_value = {"data": {"id": "22222222-2222-2222-2222-222222222222",
                                    "attributes": {"createdDate": datetime.now(timezone.utc).isoformat()}}}
        with patch.object(router, "current_producer", return_value={"head": {"ref": "branch"}}), patch.object(router, "refresh_producer"), \
                patch.object(router, "trusted_admissions", return_value={123: fixture.record}), \
                patch.object(router, "admitted_population", return_value=fixture.population), \
                patch.object(router, "github_capacity", return_value={"congested": True}), patch.object(router, "month_usage", return_value={"minutes": 0}):
            prepared = router.route_run(api, lambda: asc, fixture.run)
            self.assertEqual(prepared["reason"], "inventory-allows-start")
            result = router.start_cloud(asc, prepared)
            self.assertEqual(result["reason"], "cloud-started")
            asc.request.assert_called_once()

    def test_superseded_router_exits_successfully_without_a_start_or_receipt(self):
        import ci_xcode_cloud_route as router
        import json
        import os
        import tempfile
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api = Mock(repository="owner/repo")
        api.repo.return_value = fixture.run
        with tempfile.TemporaryDirectory() as directory:
            event, output = Path(directory, "event.json"), Path(directory, "output")
            event.write_text(json.dumps({"inputs": {"producer_run_id": "123", "producer_attempt": "2"}}))
            environment = {"GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output), "GITHUB_REPOSITORY": "owner/repo",
                           "CI_WORKFLOW_TOKEN": "test-token", "GITHUB_RUN_ID": "456", "GITHUB_RUN_ATTEMPT": "1", "RUNNER_TEMP": directory}
            with patch.dict(os.environ, environment), patch.object(router.sys, "argv", ["router", "prepare"]), \
                    patch.object(router, "credential_context"), patch("ci_publish.git"), patch.object(router, "RetryingGitHub", return_value=api), \
                    patch.object(router, "verify_workflow"), patch.object(router, "recorded_decision", return_value=False), \
                    patch.object(router, "route_run", side_effect=router.SupersededProducer("old head")), patch.object(router, "jwt") as sign, \
                    patch("builtins.print") as log:
                self.assertEqual(router.main(), 0)
                sign.assert_not_called()
                log.assert_called_once()
                self.assertIn("recorded=false", output.read_text())
                self.assertFalse(Path(directory, "ci-xcc-route").exists())

    def test_all_post_client_errors_are_definite_rejections_including_conflict(self):
        import ci_xcode_cloud_route as router
        prepared = {"identity": {"head_sha": "a" * 40}, "reference_id": "reference"}
        asc = Mock()
        asc.pages.return_value = []
        for status in (400, 401, 403, 404, 409, 422, 429):
            asc.request.side_effect = ContractError(f"HTTP {status}")
            with self.subTest(status=status), patch.object(router, "month_usage", return_value={"minutes": 0}):
                result = router.start_cloud(asc, prepared)
                self.assertEqual(result["http_status"], status)
                self.assertEqual(result["decision"], "fallback")
        cloud_id = "11111111-1111-1111-1111-111111111111"
        asc.request.side_effect = [{"data": {"id": cloud_id}}, ContractError("HTTP 429")]
        with patch.object(router, "month_usage", return_value={"minutes": 0}), self.assertRaises(ContractError):
            router.start_cloud(asc, prepared)
        self.assertEqual(asc.request.call_args.args[0], "/v1/ciBuildRuns/" + cloud_id)

    def test_never_started_terminal_actions_cost_zero_but_missing_success_timing_is_refused(self):
        from ci_xcode_cloud_route import action_minutes
        now = datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc)
        for status in ("SKIPPED", "CANCELED"):
            with self.subTest(status=status):
                self.assertEqual(action_minutes({"executionProgress": "COMPLETE", "completionStatus": status,
                    "startedDate": None, "finishedDate": "2026-10-09T15:00:00Z"}, now.replace(day=1), now), 0)
        with self.assertRaises(ContractError):
            action_minutes({"executionProgress": "COMPLETE", "completionStatus": "SUCCEEDED"}, now.replace(day=1), now)

    def setUp(self):
        import ci_xcode_cloud_route as router
        for context in (patch.object(router, "selection_open", return_value=True),
                        patch.object(cloud, "archive_evidence_run", side_effect=lambda api, run: dict(run,
                            archive_job={"id": 999, "status": "completed", "conclusion": "success"})),
                        patch("ci_publish.git")):
            context.start()
            self.addCleanup(context.stop)

    def run_stages(self, router, api, asc, fixture, **options):
        asc.pages.side_effect = lambda path: ([{"id": "reference", "attributes": {"canonicalName": "refs/heads/branch"}}]
                                            if "/scmRepositories/" in path else [])
        prepared = router.route_run(api, lambda: asc, fixture.run, sleep=lambda _: None, **options)
        if prepared["decision"] != "pending":
            return prepared
        started = dict(prepared, **router.start_cloud(asc, prepared))
        return router.poll_route(api, asc, fixture.record, fixture.run, started, sleep=lambda _: None)

    def test_a_post_interruption_reuses_the_visible_inventory_without_another_post(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        prepared = {"identity": fixture.identity, "reference_id": "reference"}
        asc, inventory = Mock(), []
        asc.pages.side_effect = lambda _: copy.deepcopy(inventory)
        def post(path, **kwargs):
            self.assertEqual((path, kwargs["method"]), ("/v1/ciBuildRuns", "POST"))
            inventory.append({"id": fixture.evidence["id"], "attributes": {
                "createdDate": "2026-10-09T16:00:01Z", "executionProgress": "RUNNING",
                "sourceCommit": {"commitSha": fixture.run["head_sha"]}}})
            raise KeyboardInterrupt()
        asc.request.side_effect = post
        with patch.object(router, "month_usage", return_value={"minutes": 0}), self.assertRaises(KeyboardInterrupt):
            router.start_cloud(asc, prepared)
        result = router.start_cloud(asc, prepared)
        self.assertEqual(result["cloud_run_id"], fixture.evidence["id"])
        asc.request.assert_called_once()

    def test_active_overflow_builds_count_at_least_the_projection(self):
        from ci_xcode_cloud_route import month_usage
        asc = Mock()
        for progress in ("PENDING", "RUNNING"):
            run = {"id": "22222222-2222-2222-2222-222222222222", "attributes": {
                "executionProgress": progress, "createdDate": "2026-10-09T11:00:00Z"}}
            def pages(path):
                if path == "/v1/ciProducts?limit=200":
                    return [{"id": "11111111-1111-1111-1111-111111111111"}]
                if "/ciProducts/" in path:
                    return [run]
                return [] if progress == "PENDING" else [{"id": "completed-action", "attributes": {
                    "executionProgress": "COMPLETE", "startedDate": "2026-10-09T15:40:00Z",
                    "finishedDate": "2026-10-09T15:50:00Z"}}, {"id": "running-action", "attributes": {
                    "executionProgress": "RUNNING", "startedDate": "2026-10-09T15:50:00Z"}}]
            asc.pages.side_effect = pages
            with self.subTest(progress=progress):
                usage = month_usage(asc, datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc), inventory=[run])
                self.assertEqual(usage["projected_minutes"], 100 if progress == "PENDING" else 80)
                self.assertEqual(usage["minutes"], 100)

    def test_a_stuck_running_build_for_four_hours_counts_all_elapsed_minutes(self):
        import ci_xcode_cloud_route as router
        asc = Mock()
        now = datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc)
        run = {"id": "22222222-2222-2222-2222-222222222222", "attributes": {
            "executionProgress": "RUNNING", "createdDate": "2026-10-09T11:00:00Z"}}
        def pages(path):
            if path == "/v1/ciProducts?limit=200":
                return [{"id": "11111111-1111-1111-1111-111111111111"}]
            if "/ciProducts/" in path:
                return [run]
            return [{"id": "completed-action", "attributes": {"executionProgress": "COMPLETE",
                     "startedDate": "2026-10-09T11:50:00Z", "finishedDate": "2026-10-09T12:00:00Z"}},
                    {"id": "running-action", "attributes": {"executionProgress": "RUNNING",
                     "startedDate": "2026-10-09T12:00:00Z"}}]
        asc.pages.side_effect = pages
        self.assertEqual(router.blocking_builds([run], now), [])
        usage = router.month_usage(asc, now, inventory=[run])
        self.assertEqual((usage["minutes"], usage["projected_minutes"]), (250, 0))

    def test_near_the_cap_an_inconsistent_complete_build_refuses_a_start(self):
        import ci_xcode_cloud_route as router
        from datetime import timedelta
        asc = Mock()
        now = datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc)
        run = {"id": "22222222-2222-2222-2222-222222222222", "attributes": {
            "executionProgress": "COMPLETE", "finishedDate": now.isoformat()}}
        asc.request.return_value = {"data": {"id": "33333333-3333-3333-3333-333333333333",
                                            "attributes": {"createdDate": now.isoformat()}}}
        def pages(path):
            if path == "/v1/ciProducts?limit=200":
                return [{"id": "11111111-1111-1111-1111-111111111111"}]
            if "/actions?" in path:
                return [{"id": "completed-action", "attributes": {"executionProgress": "COMPLETE",
                         "startedDate": (now - timedelta(minutes=2600)).isoformat(), "finishedDate": now.isoformat()}},
                        {"id": "unfinished-action", "attributes": {"executionProgress": "RUNNING",
                         "startedDate": (now - timedelta(minutes=1)).isoformat()}}]
            return [run]
        asc.pages.side_effect = pages
        with patch.object(router, "datetime", wraps=datetime) as clock:
            clock.now.return_value = now
            with self.assertRaisesRegex(ContractError, "inconsistent"):
                router.start_cloud(asc, {"identity": {"head_sha": "a" * 40}, "reference_id": "reference"})
        asc.request.assert_not_called()

    def test_an_uncertain_post_selects_github_without_inventory_polling(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        asc, api = Mock(), Mock()
        asc.pages.return_value = []
        from urllib.error import URLError
        for error in (TimeoutError(), URLError("connection lost"), ContractError("HTTP 503")):
            asc.request.side_effect = error
            with self.subTest(error=type(error).__name__), patch.object(router, "month_usage", return_value={"minutes": 0}):
                result = router.start_cloud(asc, {"identity": fixture.identity, "reference_id": "reference"})
                self.assertEqual((result["decision"], result["reason"]), ("github", "start-outcome-unknown"))
        asc.pages.reset_mock()
        asc.request.reset_mock()
        with patch.object(router, "refresh_producer"), patch.object(router, "selection_open", return_value=True):
            polled = router.poll_route(api, asc, fixture.record, fixture.run, dict(result, decision="pending"),
                sleep=lambda _: None, monotonic=Mock(side_effect=[0, 0, 0, 100 * 60]))
        self.assertEqual(polled["decision"], "github")
        asc.pages.assert_not_called()
        asc.request.assert_not_called()

    def test_git_errors_select_github_instead_of_failing_the_producer(self):
        import subprocess
        import ci_ui_tests as producer
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api = Mock()
        api.repo.return_value = fixture.run
        ctx = {"identity": fixture.identity, "source": {"fork_originated": False}, "run": {"id": "123", "attempt": 2}}
        for error in (subprocess.CalledProcessError(128, ["git", "fetch"]), subprocess.TimeoutExpired(["git"], 30)):
            with self.subTest(error=type(error).__name__), \
                    patch.object(router, "trusted_artifact", side_effect=error):
                self.assertEqual(router.producer_decision(api, fixture.record, fixture.run, approved=False, transient_errors=True), "github")
            with self.subTest(wait_error=type(error).__name__), patch.object(producer, "verify_workflow"), \
                    patch("ci_publish.trusted_admissions", side_effect=error), patch.object(producer.time, "sleep") as sleep:
                self.assertEqual(producer.wait_cloud(ctx, api), "github")
                sleep.assert_not_called()

    def test_a_failed_archive_selects_github_before_reading_cloud_proof(self):
        import ci_ui_tests as producer
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api = Mock()
        api.repo.return_value = fixture.run
        ctx = {"identity": fixture.identity, "source": {"fork_originated": False}, "run": {"id": "123", "attempt": 2}}
        for conclusion in ("failure", "cancelled", "timed_out", None):
            with self.subTest(conclusion=conclusion), patch.object(producer, "verify_workflow"), \
                    patch("ci_publish.trusted_admissions", return_value={123: fixture.record}), \
                    patch.object(cloud, "archive_evidence_run", return_value=dict(fixture.run,
                        archive_job={"status": "completed", "conclusion": conclusion})), \
                    patch.object(router, "producer_decision", return_value="routed") as proof:
                self.assertEqual(producer.wait_cloud(ctx, api), "github")
                proof.assert_not_called()

    def test_incomplete_inventory_blocks_starts_and_duplicate_exact_heads_are_reused(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        prepared = {"identity": fixture.identity, "reference_id": "reference"}
        asc = Mock()
        for commits in ((None,), (fixture.run["head_sha"], fixture.run["head_sha"])):
            asc.pages.return_value = [{"id": f"{index:08d}-1111-1111-1111-111111111111", "attributes": {
                "createdDate": datetime.now(timezone.utc).isoformat(), "executionProgress": "PENDING",
                "sourceCommit": {} if head is None else {"commitSha": head}}} for index, head in enumerate(commits)]
            with self.subTest(commits=commits):
                result = router.start_cloud(asc, prepared)
                self.assertEqual(result["decision"], "github" if commits == (None,) else "pending")
                asc.request.assert_not_called()

    def test_token_age_and_read_backoff_do_not_replay_an_uncertain_post(self):
        from ci_xcode_cloud_client import RenewingAppStoreConnect
        from ci_xcode_cloud_api import AppStoreConnect
        elapsed = [0]
        def sleep(seconds):
            elapsed[0] += seconds
        factory = Mock(side_effect=["first-test-token", "second-test-token"])
        client = RenewingAppStoreConnect(factory, 1200, timer=lambda: elapsed[0], sleep=sleep)
        with patch.object(AppStoreConnect, "request", side_effect=[ContractError("HTTP 429"), {"data": []}, {"data": []}, TimeoutError()]) as network:
            self.assertEqual(client.request("/v1/ciProducts"), {"data": []})
            self.assertEqual(elapsed[0], 2)
            elapsed[0] = 481
            client.request("/v1/ciProducts")
            self.assertEqual(factory.call_count, 2)
            with self.assertRaises(TimeoutError):
                client.request("/v1/ciBuildRuns", method="POST", payload={})
            self.assertEqual(network.call_count, 4)

    def test_unaffected_retained_or_late_producers_cannot_start_cloud(self):
        import ci_xcode_cloud_route as router
        from datetime import timedelta
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api, factory = Mock(), Mock()
        with patch.object(router, "current_producer", return_value={}), \
                patch.object(router, "trusted_admissions", return_value={123: fixture.record}), \
                patch.object(router, "admitted_population", return_value=fixture.population), \
                patch.object(router, "github_capacity") as capacity:
            fixture.record["classification"]["app_affected"] = False
            self.assertEqual(router.route_run(api, factory, fixture.run)["reason"], "trusted-app-unaffected")
            capacity.assert_not_called()
            fixture.record["classification"]["app_affected"] = True
            with patch.object(cloud, "archive_evidence_run", return_value=dict(fixture.run, run_attempt=1)):
                self.assertEqual(router.route_run(api, factory, fixture.run)["reason"], "retained-archive-selection")
            for late in (False, True):
                with self.subTest(late=late), patch.object(router, "selection_open", return_value=late):
                    run = dict(fixture.run, run_started_at=(datetime.now(timezone.utc) - timedelta(minutes=31)).isoformat()) if late else fixture.run
                    self.assertEqual(router.route_run(api, factory, run)["reason"], "producer-selection-too-late")
            factory.assert_not_called()

    def test_polling_refreshes_producer_and_waits_for_this_runs_newest_check(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api, asc = Mock(), Mock()
        asc.request.return_value = {"data": {"attributes": {"executionProgress": "COMPLETE", "completionStatus": "SUCCEEDED"}}}
        asc.evidence.return_value = fixture.evidence
        api.pages.side_effect = [[dict(fixture.check, status="in_progress")], [fixture.check]]
        with patch.object(router, "refresh_producer") as refresh, \
                patch.object(cloud, "admitted_population", return_value=fixture.population), \
                patch.object(router, "selection_open", return_value=True), patch.object(router.time, "sleep"):
            result = router.poll_route(api, asc, fixture.record, fixture.run, fixture.route, sleep=lambda _: None)
            self.assertEqual(result["decision"], "routed")
            self.assertEqual(refresh.call_count, 2)
            refresh.side_effect = router.SupersededProducer("producer superseded")
            asc.request.reset_mock()
            with self.assertRaises(router.SupersededProducer):
                router.poll_route(api, asc, fixture.record, fixture.run, fixture.route)
            asc.request.assert_not_called()

    def test_finished_previous_month_runs_do_not_consume_or_scan_current_budget(self):
        from ci_xcode_cloud_route import month_usage, action_minutes
        asc = Mock()
        asc.pages.side_effect = [[{"id": "11111111-1111-1111-1111-111111111111"}], [{
            "id": "22222222-2222-2222-2222-222222222222", "attributes": {
                "executionProgress": "COMPLETE", "finishedDate": "2026-09-30T23:59:59Z"}}]]
        now = datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc)
        self.assertEqual(month_usage(asc, now, inventory=[])["minutes"], 0)
        self.assertEqual(asc.pages.call_count, 2)
        self.assertEqual(action_minutes({"executionProgress": "PENDING", "startedDate": None}, now.replace(day=1), now), 0)

    def test_failed_job_reruns_use_retained_archive_proof_or_github_tv(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        run = dict(fixture.run, run_attempt=3)
        evidence_run = dict(run, run_attempt=2)
        api = Mock()
        with patch.object(cloud, "archive_evidence_run", return_value=evidence_run), \
                patch.object(router, "trusted_artifact", return_value=(fixture.route, 55)) as artifact, \
                patch.object(router, "trusted_cloud", return_value={}) as proof:
            self.assertEqual(router.producer_decision(api, fixture.record, run, approved=False), "routed")
            self.assertEqual(artifact.call_args.args[1], "ci-xcc-route-123-2")
            proof.side_effect = ContractError("prior cloud proof is no longer valid")
            self.assertEqual(router.producer_decision(api, fixture.record, run, approved=False), "github")
            proof.side_effect = ContractError("GitHub HTTP 503")
            with self.assertRaises(ContractError):
                router.producer_decision(api, fixture.record, run, approved=False, transient_errors=True)

    def test_disabled_or_finished_without_receipt_workflows_fall_back_without_waiting(self):
        import ci_ui_tests as producer
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        ctx = {"identity": fixture.identity, "source": {"fork_originated": False}, "run": {"id": "123", "attempt": 2}}
        api = Mock()
        for inactive in (True, False):
            def response(path):
                if "/runs?" in path:
                    return {"workflow_runs": [{"display_title": "xcc-route-123-2", "status": "completed"}]}
                if "ci-xcode-cloud-" in path:
                    return {"id": 99, "state": "disabled_manually" if inactive else "active"}
                return fixture.run
            api.repo.side_effect = response
            with self.subTest(inactive=inactive), patch.object(producer, "verify_workflow"), \
                    patch("ci_publish.trusted_admissions", return_value={123: fixture.record}), \
                    patch.object(router, "producer_decision", return_value="github"), \
                    patch("ci_xcode_cloud_state.inflight_start", return_value=None if inactive else {
                        "identity": fixture.identity, "cloud_created_at": datetime.now(timezone.utc).isoformat()}), \
                    patch.object(cloud, "trusted_artifact", side_effect=ContractError("missing receipt")), \
                    patch.object(producer.time, "sleep") as sleep:
                self.assertEqual(producer.wait_cloud(ctx, api), "github")
                sleep.assert_not_called()

    def test_full_rerun_without_a_matching_started_cloud_task_chooses_github_immediately(self):
        import ci_ui_tests as producer
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        run = dict(fixture.run, run_attempt=3)
        ctx = {"identity": fixture.identity, "source": {"fork_originated": False}, "run": {"id": "123", "attempt": 3}}
        api = Mock()
        api.repo.side_effect = lambda path: {"id": 99, "state": "active"} if "ci-xcode-cloud-" in path else run
        with patch.object(producer, "verify_workflow"), patch("ci_publish.trusted_admissions", return_value={123: fixture.record}), \
                patch.object(router, "producer_decision", return_value="github"), \
                patch("ci_xcode_cloud_state.inflight_start", return_value=None), patch.object(producer.time, "sleep") as sleep:
            self.assertEqual(producer.wait_cloud(ctx, api), "github")
            sleep.assert_not_called()

    def test_a_transient_poll_round_does_not_decide_github_before_valid_proof_arrives(self):
        import ci_ui_tests as producer
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        ctx = {"identity": fixture.identity, "source": {"fork_originated": False}, "run": {"id": "123", "attempt": 2}}
        api, reads = Mock(), [0]
        def response(path):
            if "ci-xcode-cloud-" in path:
                return {"id": 99, "state": "active"}
            if path == "actions/runs/123":
                reads[0] += 1
                if reads[0] == 2:
                    raise ContractError("GitHub HTTP 503")
            return fixture.run
        api.repo.side_effect = response
        start = {"identity": fixture.identity, "cloud_created_at": datetime.now(timezone.utc).isoformat()}
        with patch.object(producer, "verify_workflow"), patch("ci_publish.trusted_admissions", return_value={123: fixture.record}), \
                patch("ci_xcode_cloud_state.inflight_start", return_value=start), \
                patch.object(router, "producer_decision", side_effect=["github", "routed"]), \
                patch.object(cloud, "trusted_artifact", return_value=(fixture.route, 55)), patch.object(producer.time, "sleep") as sleep:
            self.assertEqual(producer.wait_cloud(ctx, api), "routed")
            sleep.assert_called_once_with(60)

    def test_retained_archive_selection_reuses_valid_proof_and_invalid_proof_chooses_tv(self):
        import ci_ui_tests as producer
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        run = dict(fixture.run, run_attempt=3)
        ctx = {"identity": fixture.identity, "source": {"fork_originated": False}, "run": {"id": "123", "attempt": 3}}
        api = Mock()
        api.repo.return_value = run
        with patch.object(producer, "verify_workflow"), patch("ci_publish.trusted_admissions", return_value={123: fixture.record}), \
                patch.object(cloud, "archive_evidence_run", return_value=dict(run, run_attempt=2,
                    archive_job={"status": "completed", "conclusion": "success"})), \
                patch.object(router, "producer_decision", side_effect=["routed", "github"]) as proof, \
                patch.object(producer.time, "sleep") as sleep:
            self.assertEqual(producer.wait_cloud(ctx, api), "routed")
            self.assertEqual(producer.wait_cloud(ctx, api), "github")
            self.assertEqual(proof.call_args.kwargs["evidence_attempt"], 2)
            sleep.assert_not_called()

    def test_event_bridge_dispatches_only_fixed_main_workflows_without_cloud_credentials(self):
        import ci_xcode_cloud_dispatch as bridge
        api = Mock(repository="owner/repo")
        source = {"id": 123, "run_attempt": 2, "event": "pull_request", "path": cloud.UI_PATH, "repository": {"full_name": "owner/repo"},
                  "head_repository": {"full_name": "owner/repo"}}
        api.repo.return_value = source
        with patch.object(bridge, "current_producer") as current:
            bridge.dispatch(api, {"workflow_run": {"id": 123}, "action": "requested"})
            current.assert_called_once_with(api, source)
        api.dispatch.assert_called_once_with(cloud.ROUTE_PATH, {"producer_run_id": "123", "producer_attempt": "2", "mode": "auto"})
        api.dispatch.reset_mock()
        source["event"] = "push"
        bridge.dispatch(api, {"workflow_run": {"id": 123}, "action": "requested"})
        api.dispatch.assert_not_called()
        source["event"] = "pull_request"
        bridge.dispatch(api, {"workflow_run": {"id": 123}, "action": "in_progress"})
        api.dispatch.assert_not_called()
        source["head_repository"]["full_name"] = "fork/repo"
        with patch.object(bridge, "json_member") as read, self.assertRaises(ContractError):
            bridge.dispatch(api, {"workflow_run": {"id": 123}, "action": "completed"})
        read.assert_not_called()
        api.dispatch.assert_not_called()

    def test_event_bridge_imports_only_a_successful_dispatch_router_routed_receipt(self):
        import ci_xcode_cloud_dispatch as bridge
        api = Mock(repository="owner/repo")
        source = {"id": 456, "path": cloud.ROUTE_PATH, "repository": {"full_name": "owner/repo"},
                  "head_repository": {"full_name": "owner/repo"}, "run_attempt": 1, "conclusion": "success"}
        api.repo.return_value = source
        api.pages.return_value = [{"name": "ci-xcc-route-123-2", "expired": False}]
        receipt = {"uploader_run_id": 456, "uploader_attempt": 1, "producer_run_id": 123,
                   "producer_attempt": 2, "decision": "routed"}
        with patch.object(bridge, "git"), patch.object(bridge, "validate_uploader") as verify, \
                patch.object(bridge, "json_member", return_value=receipt) as read:
            bridge.dispatch(api, {"workflow_run": {"id": 456}, "action": "completed"})
            api.dispatch.assert_called_once_with(cloud.IMPORT_PATH, {"producer_run_id": "123", "producer_attempt": "2"})
            api.dispatch.reset_mock()
            receipt["decision"] = "fallback"
            bridge.dispatch(api, {"workflow_run": {"id": 456}, "action": "completed"})
            api.dispatch.assert_not_called()
            read.reset_mock()
            verify.side_effect = ContractError("untrusted router")
            with self.assertRaises(ContractError):
                bridge.dispatch(api, {"workflow_run": {"id": 456}, "action": "completed"})
            read.assert_not_called()
            verify.reset_mock()
            for conclusion in ("failure", "cancelled", "timed_out"):
                source["conclusion"] = conclusion
                with self.subTest(conclusion=conclusion):
                    bridge.dispatch(api, {"workflow_run": {"id": 456}, "action": "completed"})
                    verify.assert_not_called()
                    read.assert_not_called()
                    api.dispatch.assert_not_called()

    def test_router_requires_complete_validated_method_evidence_before_routed_receipt(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api, asc = Mock(), Mock()
        asc.pages.return_value = [{"id": "reference", "attributes": {"canonicalName": "refs/heads/branch"}}]
        asc.evidence.return_value = fixture.evidence
        api.pages.return_value = [fixture.check]
        def response(path, **_):
            return ({"data": {"id": fixture.evidence["id"], "attributes": {"createdDate": datetime.now(timezone.utc).isoformat()}}} if path == "/v1/ciBuildRuns" else
                    {"data": {"attributes": {"executionProgress": "COMPLETE", "completionStatus": "SUCCEEDED",
                     "sourceCommit": {"commitSha": fixture.run["head_sha"]}}}})
        asc.request.side_effect = response
        with patch.object(router, "current_producer", return_value={"head": {"ref": "branch"}}), \
                patch.object(router, "refresh_producer"), \
                patch.object(router, "trusted_admissions", return_value={123: fixture.record}), \
                patch.object(router, "admitted_population", return_value=fixture.population), \
                patch.object(cloud, "admitted_population", return_value=fixture.population), \
                patch.object(router, "github_capacity", return_value={"congested": True}), \
                patch.object(router, "month_usage", return_value={"minutes": 0}):
            result = self.run_stages(router, api, asc, fixture)
            self.assertEqual(result["decision"], "routed")
            fixture.evidence["actions"][0]["tests"][0]["status"] = "SKIPPED"
            result = self.run_stages(router, api, asc, fixture)
            self.assertEqual((result["decision"], result["reason"]), ("fallback", "cloud-population-or-app-check-refused"))

    def test_budget_counts_failed_running_and_pending_elapsed_actions_across_products(self):
        from ci_xcode_cloud_route import month_usage
        now = datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc)
        asc = Mock()
        product_ids = ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"]
        run_ids = ["33333333-3333-3333-3333-333333333333", "44444444-4444-4444-4444-444444444444"]
        def pages(path):
            if path == "/v1/ciProducts?limit=200":
                return [{"id": item} for item in product_ids]
            if "/ciProducts/" in path:
                return [{"id": run_ids[product_ids.index(path.split('/')[3])],
                         "attributes": {"executionProgress": "COMPLETE" if path.split('/')[3] == product_ids[0] else "RUNNING"}}]
            failed = {"id": "failed-action", "attributes": {"executionProgress": "COMPLETE",
                      "completionStatus": "FAILED", "startedDate": "2026-10-09T15:40:00Z",
                      "finishedDate": "2026-10-09T15:50:00Z"}}
            running = {"id": "running-action", "attributes": {"executionProgress": "RUNNING",
                       "startedDate": "2026-10-09T15:55:00Z", "finishedDate": None}}
            pending = {"id": "pending-action", "attributes": {"executionProgress": "PENDING",
                       "startedDate": "2026-10-09T15:58:00Z", "finishedDate": None}}
            return [failed] if run_ids[0] in path else [running, pending]
        asc.pages.side_effect = pages
        usage = month_usage(asc, now, inventory=[])
        self.assertEqual(usage["minutes"], 17)
        inventory = [{"id": run_ids[1], "attributes": {"executionProgress": "RUNNING"}}]
        usage = month_usage(asc, now, inventory=inventory)
        self.assertEqual((usage["month"], usage["products"], usage["actions"], usage["minutes"]),
                         ("2026-10", 2, 3, 110))
        asc.pages.side_effect = lambda path: [] if "/actions?" in path else pages(path)
        with self.assertRaises(ContractError):
            month_usage(asc, now, inventory=inventory)
        asc.pages.return_value, asc.pages.side_effect = [], None
        with self.assertRaises(ContractError):
            month_usage(asc, now, inventory=inventory)

    def test_main_override_is_head_bound_and_cannot_bypass_budget_or_population(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api, asc = Mock(), Mock()
        asc.pages.return_value = [{"id": "reference", "attributes": {"canonicalName": "refs/heads/branch"}}]
        asc.evidence.return_value = fixture.evidence
        api.pages.return_value = [fixture.check]
        asc.request.side_effect = lambda path, **_: ({"data": {"id": fixture.evidence["id"],
            "attributes": {"createdDate": datetime.now(timezone.utc).isoformat()}}}
            if path == "/v1/ciBuildRuns" else {"data": {"attributes": {
                "executionProgress": "COMPLETE", "completionStatus": "SUCCEEDED",
                "sourceCommit": {"commitSha": fixture.run["head_sha"]}}}})
        with patch.object(router, "current_producer", return_value={"head": {"ref": "branch"}}), \
                patch.object(router, "refresh_producer"), \
                patch.object(router, "trusted_admissions", return_value={123: fixture.record}), \
                patch.object(router, "admitted_population", return_value=fixture.population), \
                patch.object(cloud, "admitted_population", return_value=fixture.population), \
                patch.object(router, "github_capacity", return_value={"congested": False}), \
                patch.object(router, "month_usage", return_value={"minutes": 0}) as usage:
            override = fixture.run["head_sha"] + ":force-congestion"
            result = router.route_run(api, lambda: asc, fixture.run, override="c" * 40 + ":force-congestion")
            self.assertEqual(result["reason"], "github-capacity-available")
            asc.request.assert_not_called()
            result = self.run_stages(router, api, asc, fixture, override=override)
            self.assertEqual(result["decision"], "routed")
            self.assertEqual(result["control"], {"source": "repository-variable", "mode": "force-congestion"})
            self.assertFalse(result["capacity"]["congested"])
            asc.request.reset_mock()
            usage.return_value = {"minutes": router.CAP_MINUTES}
            self.assertEqual(router.route_run(api, lambda: asc, fixture.run, override=override)["reason"],
                             "monthly-cap-reached")
            asc.request.assert_not_called()
            usage.return_value = {"minutes": 0}
            fixture.evidence["actions"][0]["tests"][0]["status"] = "SKIPPED"
            result = self.run_stages(router, api, asc, fixture, override=override)
            self.assertEqual(result["decision"], "fallback")
            asc.request.reset_mock()
            result = router.route_run(api, lambda: asc, fixture.run,
                                      override=fixture.run["head_sha"] + ":github")
            self.assertEqual((result["decision"], result["reason"]), ("github", "routing-disabled"))
            asc.request.assert_not_called()
            asc.request.side_effect = ContractError("ASC POST refused request (HTTP 400)")
            result = self.run_stages(router, api, asc, fixture,
                                     override=fixture.run["head_sha"] + ":force-start-failure")
            self.assertEqual((result["decision"], result["reason"], result["http_status"]),
                             ("fallback", "cloud-start-failed", 400))
            reference = asc.request.call_args.kwargs["payload"]["data"]["relationships"]["sourceBranchOrTag"]
            self.assertEqual(reference["data"]["id"], "invalid-reference")
            for malformed in ("force-congestion", "a" * 40 + ":auto", "a" * 40 + ":force-congestion\n"):
                with self.subTest(override=malformed):
                    self.assertEqual(router.route_run(api, lambda: asc, fixture.run, override=malformed)["decision"], "fallback")

    def test_router_checks_latest_attempt_before_start_and_acceptance(self):
        from ci_xcode_cloud_route import refresh_producer
        api = Mock()
        original = {"id": 123, "run_attempt": 1, "head_sha": "a" * 40}
        with patch("ci_xcode_cloud_route.current_producer", return_value={}):
            api.repo.return_value = dict(original)
            refresh_producer(api, original)
            for field, value in (("run_attempt", 2), ("head_sha", "b" * 40), ("id", 456)):
                api.repo.return_value = dict(original, **{field: value})
                with self.subTest(field=field), self.assertRaises(ContractError):
                    refresh_producer(api, original)

    def test_api_start_failure_and_terminal_run_failure_never_authorize_a_skip(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api, asc = Mock(), Mock()
        pr = {"head": {"ref": "branch"}}
        asc.pages.return_value = [{"id": "reference", "attributes": {"canonicalName": "refs/heads/branch"}}]
        common = (patch.object(router, "current_producer", return_value=pr),
                  patch.object(router, "refresh_producer"),
                  patch.object(router, "trusted_admissions", return_value={123: fixture.record}),
                  patch.object(router, "admitted_population", return_value=fixture.population),
                  patch.object(router, "github_capacity", return_value={"congested": True}),
                  patch.object(router, "month_usage", return_value={"minutes": 0}))
        for context in common:
            context.start()
            self.addCleanup(context.stop)
        asc.request.side_effect = ContractError("App Store Connect refused HTTP 400")
        result = self.run_stages(router, api, asc, fixture)
        self.assertEqual((result["decision"], result["reason"], result["http_status"]),
                         ("fallback", "cloud-start-failed", 400))
        asc.request.side_effect = [{"data": {"id": fixture.evidence["id"], "attributes": {"createdDate": datetime.now(timezone.utc).isoformat()}}}, {"data": {"attributes": {
            "executionProgress": "COMPLETE", "completionStatus": "FAILED",
            "sourceCommit": {"commitSha": fixture.run["head_sha"]}}}}]
        result = self.run_stages(router, api, asc, fixture)
        self.assertEqual((result["decision"], result["reason"]), ("fallback", "cloud-run-failed-or-timed-out"))
        asc.evidence.assert_not_called()

    def test_disabled_uncongested_and_at_cap_routes_cannot_start_cloud_runs(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api, factory, asc = Mock(), Mock(), Mock()
        factory.return_value = asc
        asc.pages.return_value = []
        with patch.object(router, "current_producer", return_value={"head": {"ref": "branch"}}), \
                patch.object(router, "trusted_admissions", return_value={123: fixture.record}), \
                patch.object(router, "admitted_population", return_value=fixture.population), \
                patch.object(router, "github_capacity", return_value={"congested": False}) as capacity, \
                patch.object(router, "month_usage", return_value={"minutes": router.CAP_MINUTES}) as usage:
            self.assertEqual(router.route_run(api, factory, fixture.run, mode="github")["decision"], "github")
            self.assertEqual(router.route_run(api, factory, fixture.run)["reason"], "github-capacity-available")
            factory.assert_not_called()
            capacity.return_value = {"congested": True}
            self.assertEqual(router.route_run(api, factory, fixture.run)["reason"], "monthly-cap-reached")
            usage.assert_called_once()
            asc.request.assert_not_called()

    def test_producer_waits_for_cloud_completion_and_forks_do_not_read_cloud_artifacts(self):
        import ci_ui_tests as producer
        import ci_xcode_cloud_route as router
        from datetime import timedelta
        now = datetime.now(timezone.utc)
        identity = {"event": "pull_request", "head_sha": "a" * 40}
        ctx = {"identity": identity, "source": {"fork_originated": True}, "run": {"id": "123", "attempt": 1}}
        api = Mock()
        self.assertEqual(producer.wait_cloud(ctx, api), "github")
        api.repo.assert_not_called()
        ctx["source"]["fork_originated"] = False
        run = {"id": 123, "run_attempt": 1, "head_sha": "a" * 40, "status": "in_progress",
               "run_started_at": (now - timedelta(minutes=5)).isoformat()}
        def response(path):
            if path.endswith("ci-ui.yml"):
                return {}
            if "/runs?" in path:
                return {"workflow_runs": [{"display_title": "xcc-route-123-1", "status": "in_progress"}]}
            if "ci-xcode-cloud-" in path:
                return {"id": 99, "state": "active"}
            return run
        api.repo.side_effect = response
        with patch.object(producer, "verify_workflow"), \
                patch("ci_publish.trusted_admissions", return_value={123: {"identity": identity, "classification": {"app_affected": True}}}), \
                patch.object(router, "producer_decision", side_effect=["github", "routed"]), \
                patch.object(cloud, "trusted_artifact", return_value=({"decision": "routed"}, 1)), \
                patch("ci_xcode_cloud_state.inflight_start", return_value={"identity": identity, "cloud_created_at": now.isoformat()}), \
                patch.object(producer.time, "monotonic", return_value=0), \
                patch.object(producer.time, "sleep") as sleep:
            self.assertEqual(producer.wait_cloud(ctx, api), "routed")
            sleep.assert_not_called()

    def test_capacity_requires_five_mac_jobs_and_a_two_minute_queue(self):
        from ci_xcode_cloud_route import congestion
        now = datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc)
        jobs = [{"id": number, "status": "in_progress", "labels": ["xcode-27"]} for number in range(5)]
        jobs.append({"id": 6, "status": "queued", "labels": ["xcode-27"], "created_at": "2026-10-09T15:58:00Z"})
        self.assertTrue(congestion(jobs, now)["congested"])
        self.assertFalse(congestion(jobs[1:], now)["congested"])
        jobs[-1]["created_at"] = "2026-10-09T15:59:00Z"
        self.assertFalse(congestion(jobs, now)["congested"])
        jobs[-1]["labels"] = ["ubuntu-24.04"]
        self.assertFalse(congestion(jobs, now)["congested"])

    def test_month_usage_counts_all_actions_and_running_time_with_utc_reset(self):
        from ci_xcode_cloud_route import action_minutes
        now = datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc)
        start = datetime(2026, 10, 1, tzinfo=timezone.utc)
        complete = {"executionProgress": "COMPLETE", "startedDate": "2026-09-30T23:50:00Z",
                    "finishedDate": "2026-10-01T00:10:00Z"}
        self.assertEqual(action_minutes(complete, start, now), 10)
        running = {"executionProgress": "RUNNING", "startedDate": "2026-10-09T15:50:00Z", "finishedDate": None}
        self.assertEqual(action_minutes(running, start, now), 10)
        complete["finishedDate"] = "2026-09-30T23:55:00Z"
        self.assertEqual(action_minutes(complete, start, now), 0)
        complete["finishedDate"] = None
        with self.assertRaises(ContractError):
            action_minutes(complete, start, now)

    def test_missing_importer_or_run_failure_always_uses_github(self):
        from ci_xcode_cloud_route import producer_decision
        run = {"id": 123, "run_attempt": 2}
        with patch("ci_xcode_cloud_route.trusted_artifact", side_effect=ContractError("missing router")):
            self.assertEqual(producer_decision(object(), {}, run, approved=False), "github")
        route = {"decision": "fallback"}
        with patch("ci_xcode_cloud_route.trusted_artifact", return_value=(route, 1)):
            self.assertEqual(producer_decision(object(), {}, run, approved=False), "github")
        route["decision"] = "routed"
        with patch("ci_xcode_cloud_route.trusted_artifact", return_value=(route, 1)), \
                patch("ci_xcode_cloud_route.trusted_cloud", side_effect=ContractError("failed cloud import")) as read:
            self.assertEqual(producer_decision(object(), {}, run, approved=False), "github")
            read.assert_called_once()


if __name__ == "__main__":
    unittest.main()
