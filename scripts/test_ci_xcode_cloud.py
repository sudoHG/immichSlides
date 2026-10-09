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
        for mutation in ("fork", "event", "status", "conclusion", "history"):
            hostile = copy.deepcopy(trusted)
            hostile["id"] = 123
            if mutation == "fork":
                hostile["head_repository"]["full_name"] = "fork/repo"
            elif mutation == "event":
                hostile["event"] = "pull_request"
            elif mutation == "status":
                hostile["status"] = "in_progress"
            elif mutation == "conclusion":
                hostile["conclusion"] = "failure"
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
            return {"id": int(path.rsplit('/', 1)[1]), "workflow_id": 789, "path": cloud.IMPORT_PATH,
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
    def test_event_bridge_dispatches_only_fixed_main_workflows_without_cloud_credentials(self):
        import ci_xcode_cloud_dispatch as bridge
        api = Mock(repository="owner/repo")
        source = {"id": 123, "path": cloud.UI_PATH, "repository": {"full_name": "owner/repo"},
                  "head_repository": {"full_name": "owner/repo"}}
        api.repo.return_value = source
        with patch.object(bridge, "current_producer") as current:
            bridge.dispatch(api, {"workflow_run": {"id": 123}, "action": "requested"})
            current.assert_called_once_with(api, source)
        api.dispatch.assert_called_once_with(cloud.ROUTE_PATH, {"producer_run_id": "123", "mode": "auto"})
        api.dispatch.reset_mock()
        source["head_repository"]["full_name"] = "fork/repo"
        with patch.object(bridge, "json_member") as read, self.assertRaises(ContractError):
            bridge.dispatch(api, {"workflow_run": {"id": 123}, "action": "completed"})
        read.assert_not_called()
        api.dispatch.assert_not_called()

    def test_event_bridge_imports_only_a_successful_dispatch_router_routed_receipt(self):
        import ci_xcode_cloud_dispatch as bridge
        api = Mock(repository="owner/repo")
        source = {"id": 456, "path": cloud.ROUTE_PATH, "repository": {"full_name": "owner/repo"},
                  "head_repository": {"full_name": "owner/repo"}, "run_attempt": 1}
        api.repo.return_value = source
        api.pages.return_value = [{"name": "ci-xcc-route-123-2", "expired": False}]
        receipt = {"uploader_run_id": 456, "uploader_attempt": 1, "producer_run_id": 123,
                   "producer_attempt": 2, "decision": "routed"}
        with patch.object(bridge, "git"), patch.object(bridge, "validate_uploader") as verify, \
                patch.object(bridge, "json_member", return_value=receipt) as read:
            bridge.dispatch(api, {"workflow_run": {"id": 456}, "action": "completed"})
            api.dispatch.assert_called_once_with(cloud.IMPORT_PATH, {"producer_run_id": "123"})
            api.dispatch.reset_mock()
            receipt["decision"] = "fallback"
            bridge.dispatch(api, {"workflow_run": {"id": 456}, "action": "completed"})
            api.dispatch.assert_not_called()
            read.reset_mock()
            verify.side_effect = ContractError("untrusted router")
            with self.assertRaises(ContractError):
                bridge.dispatch(api, {"workflow_run": {"id": 456}, "action": "completed"})
            read.assert_not_called()

    def test_router_requires_complete_validated_method_evidence_before_routed_receipt(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api, asc = Mock(), Mock()
        asc.pages.return_value = [{"id": "reference", "attributes": {"canonicalName": "refs/heads/branch"}}]
        asc.evidence.return_value = fixture.evidence
        api.pages.return_value = [fixture.check]
        def response(path, **_):
            return ({"data": {"id": fixture.evidence["id"]}} if path == "/v1/ciBuildRuns" else
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
            result = router.route_run(api, lambda: asc, fixture.run, sleep=lambda _: None)
            self.assertEqual(result["decision"], "routed")
            fixture.evidence["actions"][0]["tests"][0]["status"] = "SKIPPED"
            result = router.route_run(api, lambda: asc, fixture.run, sleep=lambda _: None)
            self.assertEqual((result["decision"], result["reason"]), ("fallback", "cloud-population-or-app-check-refused"))

    def test_budget_reads_every_product_and_includes_failed_and_running_actions(self):
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
                         "attributes": {"executionProgress": "RUNNING"}}]
            failed = {"id": "failed-action", "attributes": {"executionProgress": "COMPLETE",
                      "completionStatus": "FAILED", "startedDate": "2026-10-09T15:40:00Z",
                      "finishedDate": "2026-10-09T15:50:00Z"}}
            running = {"id": "running-action", "attributes": {"executionProgress": "RUNNING",
                       "startedDate": "2026-10-09T15:55:00Z", "finishedDate": None}}
            return [failed] if run_ids[0] in path else [running]
        asc.pages.side_effect = pages
        usage = month_usage(asc, now)
        self.assertEqual((usage["month"], usage["products"], usage["actions"], usage["minutes"]),
                         ("2026-10", 2, 2, 15))
        asc.pages.side_effect = lambda path: [] if "/actions?" in path else pages(path)
        with self.assertRaises(ContractError):
            month_usage(asc, now)
        asc.pages.return_value, asc.pages.side_effect = [], None
        with self.assertRaises(ContractError):
            month_usage(asc, now)

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
        result = router.route_run(api, lambda: asc, fixture.run, sleep=lambda _: None)
        self.assertEqual((result["decision"], result["reason"], result["http_status"]),
                         ("fallback", "cloud-start-failed", 400))
        asc.request.side_effect = [{"data": {"id": fixture.evidence["id"]}}, {"data": {"attributes": {
            "executionProgress": "COMPLETE", "completionStatus": "FAILED",
            "sourceCommit": {"commitSha": fixture.run["head_sha"]}}}}]
        result = router.route_run(api, lambda: asc, fixture.run, sleep=lambda _: None)
        self.assertEqual((result["decision"], result["reason"]), ("fallback", "cloud-run-failed-or-timed-out"))
        asc.evidence.assert_not_called()

    def test_disabled_uncongested_and_at_cap_routes_cannot_start_cloud_runs(self):
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api, factory, asc = Mock(), Mock(), Mock()
        factory.return_value = asc
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
        api.repo.return_value = {"id": 123, "run_attempt": 1, "head_sha": "a" * 40,
                                "run_started_at": (now - timedelta(minutes=5)).isoformat()}
        with patch.object(producer, "verify_workflow"), \
                patch("ci_publish.trusted_admissions", return_value={123: {"identity": identity}}), \
                patch.object(router, "producer_decision", side_effect=["github", "routed"]), \
                patch.object(cloud, "trusted_artifact", side_effect=ContractError("not ready")), \
                patch.object(producer.time, "monotonic", side_effect=[0, 601]), \
                patch.object(producer.time, "sleep") as sleep:
            self.assertEqual(producer.wait_cloud(ctx, api), "routed")
            sleep.assert_called_once_with(20)

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
