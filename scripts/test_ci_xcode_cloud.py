"""Adversarial cases at the legacy and grouped Cloud evidence trust boundaries."""

import copy
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, patch

import ci_xcode_cloud as cloud
from ci_summary import ContractError, observation, test_identity


class GroupEvidenceTests(unittest.TestCase):
    """A shared method on two destinations is two independently required results."""

    def setUp(self):
        import ci_xcode_cloud_groups as groups
        self.groups = groups
        self.identity = {"schema_version": 1, "repository": "owner/repo", "event": "pull_request", "pull_request": 7,
                         "base_sha": "c" * 40, "head_sha": "a" * 40, "merge_sha": "d" * 40,
                         "tree_sha": "b" * 40}
        self.run = {"id": 123, "run_attempt": 2, "event": "pull_request", "path": cloud.UI_PATH,
                    "head_sha": "a" * 40, "repository": {"full_name": "owner/repo"},
                    "head_repository": {"full_name": "owner/repo"}}
        devices = {"iphone": {"device": "iPhone 17 Pro", "os": "27.0"},
                   "ipad": {"device": "iPad Pro 13-inch (M5)", "os": "27.0"}}
        self.registration = {"workflow_id": cloud.WORKFLOW_ID,
                             "queue_seconds_upper": 120,
                             "actions": [{"name": "Functional - iOS", "check_name": "Registered iOS check",
                                          "plan_path": "Cloud-iOS.xctestplan",
                                          "scheme_path": "Project.xcodeproj/xcshareddata/xcschemes/iOS.xcscheme",
                                          "devices": devices}]}
        template = {"testTargets": [{"target": {"name": "immichSlidesUITests"}, "selectedTests": []}]}
        self.registry = {"schema_version": 2, "groups": {"ios": self.registration}}
        selected = {device: {"scoped-a": [test_identity("ui", "SettingsTests/testToggle",
                    platform="ios", device=device)]} for device in devices}
        selected["appletv"] = {}
        self.record = {"identity": self.identity, "run_id": 123,
                       "cloud_pr_author": {"login": "sudoHG", "id": 279902076},
                       "cloud_v2_inputs": {"registry": self.registry, "head_tree_sha": "b" * 40,
                                           "files": {"ci_scripts/ci_post_clone.sh": "e" * 64},
                                           "plans": {"Cloud-iOS.xctestplan": template}},
                       "ui_inputs": {"base": {"selection": {"mode": "scoped", "coverage": "functional",
                           "map_revision": "c" * 40, "map_sha256": "f" * 64,
                           "packing": {"sha256": "e" * 64}, "shards": selected}}}}
        self.descriptor = groups.selection(self.record, self.run, "ios", approved=False)
        self.digest = groups.canonical_hash(self.descriptor)
        self.pointer = {"id": 56, "context": "ci-xcc-selection/123/2/ios", "state": "success",
                        "creator": {"login": groups.PUBLISHER_LOGIN, "id": groups.PUBLISHER_ID},
                        "description": "Selection only: " + "c" * 40 + " " + self.digest,
                        "target_url": "https://github.com/owner/repo/commit/" + "d" * 40,
                        "url": "https://api.github.com/repos/owner/repo/statuses/" + "a" * 40}
        self.route = {"schema_version": 2, "identity": self.identity, "producer_run_id": 123,
                      "producer_attempt": 2, "group": "ios", "decision": "routed",
                      "selection_sha256": self.digest, "pointer_id": 56,
                      "runtime_plan_sha256": self.descriptor["runtime_plan_sha256"],
                      "workflow_id": cloud.WORKFLOW_ID,
                      "cloud_run_id": "11111111-1111-1111-1111-111111111111"}
        self.evidence = {"id": self.route["cloud_run_id"], "workflow_id": cloud.WORKFLOW_ID,
                         "head_sha": "a" * 40, "is_pull_request_build": False,
                         "progress": "COMPLETE", "status": "SUCCEEDED",
                         "started": "2026-10-10T00:00:00Z", "finished": "2026-10-10T00:15:00Z",
                         "actions": [{"id": "22222222-2222-2222-2222-222222222222", "name": "Functional - iOS",
                           "type": "TEST", "progress": "COMPLETE", "status": "SUCCEEDED",
                           "started": "2026-10-10T00:00:00Z", "finished": "2026-10-10T00:15:00Z",
                           "tests": [{"id": "one", "class": "SettingsTests", "method": "testToggle()",
                                      "status": "SUCCESS", "destinations": [dict(value, status="SUCCESS")
                                                                         for value in devices.values()]}]}]}
        self.check = {"id": 88, "head_sha": "a" * 40, "app": {"id": cloud.APP_ID, "slug": "xcode-cloud"},
                      "name": "Registered iOS check", "status": "completed", "conclusion": "success",
                      "details_url": "https://appstoreconnect.apple.com/teams/" + cloud.TEAM_ID + "/apps/" +
                        cloud.APPLE_APP_ID + "/ci/builds/" + self.evidence["id"] + "/action/" + self.evidence["actions"][0]["id"]}

    def validate(self):
        return self.groups.validate_evidence(self.record, self.run, self.route, self.evidence,
                                             [self.check], [self.pointer], approved=False)

    def test_same_method_requires_both_exact_destinations(self):
        proof = self.validate()
        self.assertEqual({entry["dimensions"]["device"] for entry in proof["identities"]}, {"iphone", "ipad"})
        self.assertEqual(proof["selection_sha256"], self.digest)
        self.assertEqual(proof["action_minutes"], 15)
        self.assertEqual(proof["compute_upper_minutes"], 30)
        original = copy.deepcopy(self.evidence)
        for mutation in ("missing-device", "extra-device", "duplicate-device", "os", "failed", "skipped",
                         "missing-method", "extra-method", "duplicate-method", "extra-action", "pr-build", "head"):
            self.evidence = copy.deepcopy(original)
            action = self.evidence["actions"][0]
            test = action["tests"][0]
            if mutation == "missing-device":
                test["destinations"].pop()
            elif mutation in {"extra-device", "duplicate-device"}:
                test["destinations"].append(dict(test["destinations"][0]))
                if mutation == "extra-device":
                    test["destinations"][-1]["device"] = "Unknown iPhone"
            elif mutation == "os":
                test["destinations"][0]["os"] = "26.0"
            elif mutation in {"failed", "skipped"}:
                test["destinations"][0]["status"] = mutation.upper()
            elif mutation == "missing-method":
                action["tests"] = []
            elif mutation in {"extra-method", "duplicate-method"}:
                action["tests"].append(copy.deepcopy(test))
                action["tests"][-1]["id"] = "two"
                if mutation == "extra-method":
                    action["tests"][-1]["method"] = "testOther()"
            elif mutation == "extra-action":
                self.evidence["actions"].append(copy.deepcopy(action))
            elif mutation == "pr-build":
                self.evidence["is_pull_request_build"] = True
            else:
                self.evidence["head_sha"] = "e" * 40
            with self.subTest(mutation=mutation), self.assertRaises(ContractError):
                self.validate()

    def test_pointer_creator_hash_head_attempt_and_replacement_are_bound(self):
        original = copy.deepcopy(self.pointer)
        for field, value in (("creator", {"login": self.groups.PUBLISHER_LOGIN, "id": 1}),
                             ("description", "c" * 40 + " " + "0" * 64), ("state", "pending"),
                             ("context", "ci-xcc-selection/123/1/ios"),
                             ("url", "https://api.github.com/repos/owner/repo/statuses/" + "e" * 40),
                             ("target_url", "https://example.org/selection"), ("id", 57)):
            self.pointer = dict(original, **{field: value})
            with self.subTest(field=field), self.assertRaises(ContractError):
                self.validate()
        self.pointer = original
        with self.assertRaises(ContractError):
            self.groups.validate_pointer(self.record, self.run, "ios", self.digest,
                                         [original, dict(original, id=57)], pointer_id=56)

    def test_admission_not_receipt_selects_methods_and_registered_workflow(self):
        for mutation in ("selection", "workflow", "attempt", "tree", "fork", "external", "author-id", "screenshot"):
            record, run, route = copy.deepcopy((self.record, self.run, self.route))
            if mutation == "selection":
                route["selection_sha256"] = "0" * 64
            elif mutation == "workflow":
                route["workflow_id"] = "33333333-3333-3333-3333-333333333333"
            elif mutation == "attempt":
                route["producer_attempt"] = 1
            elif mutation == "tree":
                record["cloud_v2_inputs"]["head_tree_sha"] = "e" * 40
            elif mutation == "fork":
                run["head_repository"]["full_name"] = "fork/repo"
            elif mutation == "external":
                record["cloud_pr_author"]["login"] = "contributor"
            elif mutation == "author-id":
                record["cloud_pr_author"]["id"] = 42
            else:
                record["ui_inputs"]["base"]["selection"]["shards"]["iphone"]["scoped-a"][0]["key"] = "SettingsTests/testScreenshot"
            with self.subTest(mutation=mutation), self.assertRaises(ContractError):
                self.groups.validate_evidence(record, run, route, self.evidence, [self.check], [self.pointer], approved=False)

    def test_newest_app_check_and_each_action_plan_are_authoritative(self):
        newer = dict(self.check, id=89, conclusion="failure")
        with self.assertRaises(ContractError):
            self.groups.validate_evidence(self.record, self.run, self.route, self.evidence,
                                          [self.check, newer], [self.pointer], approved=False)
        selection = self.record["ui_inputs"]["base"]["selection"]
        selection["shards"]["ipad"]["scoped-a"].append(test_identity("ui", "SettingsTests/testOther", platform="ios", device="ipad"))
        with self.assertRaises(ContractError):
            self.groups.selection(self.record, self.run, "ios", approved=False)

    def gate_fixture(self, routed):
        from ci_publish_git import workflow_contract
        from test_ci_publish import FIXTURE_UI
        from test_ci_summary import valid_summary
        from test_ci_verdict import approval_record
        source = FIXTURE_UI.replace("device: [iphone]", "device: [iphone, ipad, appletv]").replace("shard: [default, visual]", "shard: [scoped-a]")
        tv = test_identity("ui", "TVSettingsTests/testToggle", platform="tvos", device="appletv")
        populations = copy.deepcopy(self.record["ui_inputs"]["base"]["selection"]["shards"])
        populations["appletv"] = {"scoped-a": [tv]}
        ui = {"populations": populations, "base_populations": {device: [entry for entries in shards.values() for entry in entries]
              for device, shards in populations.items()}, "manifest_sha256": "e" * 64,
              "plans": {platform: {"sha256": "f" * 64} for platform in ("ios", "tvos")},
              "selection": dict(self.record["ui_inputs"]["base"]["selection"], shards=populations)}
        record = copy.deepcopy(self.record)
        policy = {"schema_version": 1, "approval_records": [approval_record("ui")], "expected_skips": [], "deselections": []}
        record.update(ui_inputs={"base": ui, "candidate": ui}, base_policy=policy, candidate_policy=policy,
                      classification={"app_affected": True, "ci_changing": False},
                      workflows={cloud.UI_PATH: {"base": source, "candidate": source}})
        tv_registration = {"workflow_id": "33333333-3333-3333-3333-333333333333", "actions": [{
            "name": "Functional - tvOS", "check_name": "Registered tvOS check", "plan_path": "Cloud-tvOS.xctestplan",
            "scheme_path": "Project.xcodeproj/xcshareddata/xcschemes/tvOS.xcscheme",
            "devices": {"appletv": {"device": cloud.DEVICE_NAME, "os": "27.0"}}}]}
        record["cloud_v2_inputs"]["registry"]["groups"]["tvos"] = tv_registration
        record["cloud_v2_inputs"]["plans"]["Cloud-tvOS.xctestplan"] = copy.deepcopy(record["cloud_v2_inputs"]["plans"]["Cloud-iOS.xctestplan"])
        names, _, _, metadata = workflow_contract(source, self.run, metadata=True)
        jobs, summaries = [], []
        devices = {device for group in routed for device in self.groups.GROUPS[group]}
        for name in names:
            meta = metadata[name]
            skipped = meta.get("device") in devices
            jobs.append({"name": name, "status": "completed", "conclusion": "skipped" if skipped else "success",
                         "evidence_attempt": 2, "runner_id": None if skipped else 1, "steps": []})
            if skipped:
                continue
            entries = [test_identity("host", "UI archive selection")] if name == "ui-archive" else populations[meta["device"]][meta["shard"]]
            summary = valid_summary()
            summary.update(identity=self.identity, status="passed")
            summary["source"].update(repository="owner/repo", event="pull_request", workflow_path=cloud.UI_PATH, fork_originated=False)
            summary["run"] = {"id": "123", "attempt": 2, **{key: meta[key] for key in ("tier", "job", "shard")}}
            summary["hashes"]["manifests"] = {"ui-shards": "e" * 64, "ui-scoped-plan": "e" * 64}
            if meta["tier"] == "ui":
                summary["hashes"]["manifests"]["test-plan"] = "f" * 64
            summary["population"].update(declared=entries, compiled=entries,
                observed=[observation(entry, "passed", 0) for entry in entries], deselected=[], removed_by_pr=[])
            summaries.append(summary)
        proofs = {}
        for group in routed:
            descriptor = self.groups.selection(record, self.run, group, approved=False)
            entries = sorted([entry for population in descriptor["populations"].values() for entry in population], key=self.groups.identity_key)
            proofs[group] = {"group": group, "identities": entries, "selection_sha256": self.groups.canonical_hash(descriptor), "evidence_attempt": 2}
        proof = {"schema_version": 2, "groups": proofs, "identities": sorted([entry for group in proofs.values() for entry in group["identities"]], key=self.groups.identity_key)}
        return record, jobs, summaries, proof

    def test_gate_accepts_either_complete_group_and_all_cloud_but_never_missing_or_mixed_evidence(self):
        from ci_publish_git import BASE_MODULES, OPTIONAL_BASE_MODULES, evaluate_records
        modules = {name: (Path(__file__).parent / name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
        with patch("ci_publish_git.trusted_reader", return_value=modules):
            for routed in ({"ios"}, {"tvos"}, {"ios", "tvos"}):
                record, jobs, summaries, proof = self.gate_fixture(routed)
                with self.subTest(routed=routed):
                    result = evaluate_records(record, self.run, jobs, summaries, approved=False, fork=False, cloud=proof)
                    self.assertEqual(result["state"], "success")
                    self.assertEqual(result["ui_population_mode"], "scoped")
                    self.assertEqual(sum(entry["observed"] for entry in result["population"]), 4)
                    self.assertTrue(all(entry["compiled"] is None for entry in result["population"] if (entry["shard"] or "").endswith("/xcode-cloud")))
                    with self.assertRaises(ContractError):
                        evaluate_records(record, self.run, jobs, summaries, approved=False, fork=False)
                    incomplete = copy.deepcopy(proof)
                    incomplete["groups"][next(iter(routed))]["identities"].pop()
                    with self.assertRaises(ContractError):
                        evaluate_records(record, self.run, jobs, summaries, approved=False, fork=False, cloud=incomplete)
                    executed = copy.deepcopy(jobs)
                    next(job for job in executed if job["conclusion"] == "skipped").update(conclusion="success", runner_id=1)
                    with self.assertRaises(ContractError):
                        evaluate_records(record, self.run, executed, summaries, approved=False, fork=False, cloud=proof)
            record, jobs, summaries, _ = self.gate_fixture(set())
            # A failed/unavailable Cloud attempt contributes nothing to complete GitHub fallback.
            self.assertEqual(evaluate_records(record, self.run, jobs, summaries, approved=False, fork=False)["state"], "success")

    def test_collapsed_skips_and_history_cover_only_the_verified_group(self):
        from ci_publish_git import bind_ui_shards
        from ci_ui_reuse import expand_skipped_ui_matrix
        from test_ci_publish import dynamic_ui_workflow
        source = dynamic_ui_workflow(split_ios=True).replace("name: ui-${{ matrix.device }}-${{ matrix.shard }}",
                 "name: ui-iphone-${{ matrix.shard }}", 1)
        source = source.replace("name: ui-${{ matrix.device }}-${{ matrix.shard }}", "name: ui-ipad-${{ matrix.shard }}", 1)
        source = bind_ui_shards(source,
                                {device: ["scoped-a"] for device in ("iphone", "ipad", "appletv")})
        skipped = {"name": "ui-iphone-${{ matrix.shard }}", "id": 1, "status": "completed",
                   "conclusion": "skipped", "runner_id": 0, "steps": []}
        proof = {"schema_version": 2, "groups": {"ios": {}}}
        normalized = expand_skipped_ui_matrix(source, self.run, [skipped], complete=False, cloud=proof)
        self.assertEqual([job["name"] for job in normalized], ["ui-iphone-scoped-a"])
        for mutation in (dict(skipped, runner_id=7), dict(skipped, steps=[{}]), dict(skipped, conclusion="success")):
            with self.assertRaises(ContractError):
                expand_skipped_ui_matrix(source, self.run, [mutation], complete=False, cloud=proof)
        with self.assertRaises(ContractError):
            expand_skipped_ui_matrix(source, self.run, [skipped, dict(normalized[0])], complete=False, cloud=proof)
        # A later GitHub fallback must execute after the historical collapsed skip.
        for current in (None, {"schema_version": 2, "groups": {"tvos": {}}}):
            discarded = set()
            with self.subTest(current=current):
                self.assertEqual(expand_skipped_ui_matrix(source, self.run, [skipped], complete=False, historical=True,
                                 group_history=True, cloud=current, discarded_shards=discarded), [])
                self.assertEqual(discarded, {"ui-iphone-scoped-a"})
        with self.assertRaises(ContractError):
            expand_skipped_ui_matrix(source, self.run, [skipped], cloud={"schema_version": 2, "groups": {"tvos": {}}})
        tv_source = source.replace("name: ui-${{ matrix.device }}-${{ matrix.shard }}", "name: ui-appletv-${{ matrix.shard }}")
        discarded = set()
        self.assertEqual(expand_skipped_ui_matrix(tv_source, self.run,
            [dict(skipped, name="ui-appletv-${{ matrix.shard }}")], complete=False, historical=True,
            group_history=True, cloud=proof, discarded_shards=discarded), [])
        self.assertEqual(discarded, {"ui-appletv-scoped-a"})

    def test_linux_selection_contract_and_anchor_do_not_require_the_github_archive(self):
        from ci_publish_git import BASE_MODULES, OPTIONAL_BASE_MODULES, bind_ui_shards, evaluate_records, scoped_packing_intent, workflow_contract
        from test_ci_publish import dynamic_ui_workflow
        source = dynamic_ui_workflow(split_ios=True).replace("needs.archive.outputs.", "needs.selection.outputs.")
        bound = bind_ui_shards(source, {device: ["scoped-a"] for device in ("iphone", "ipad", "appletv")})
        self.assertNotIn("fromJSON", bound)
        self.assertTrue(scoped_packing_intent(source.replace("wait-archive", "select --pack-scoped-ui")))
        with self.assertRaises(ContractError):
            bind_ui_shards(source.replace("needs.selection.outputs.", "needs.other.outputs."), {"ios": [], "tvos": []})
        record, jobs, summaries, proof = self.gate_fixture({"ios", "tvos"})
        source = record["workflows"][cloud.UI_PATH]["base"].replace("name: ui-archive", "name: ui-selection").replace("ci_ui_tests.py wait-archive", "ci_ui_tests.py select")
        record["workflows"][cloud.UI_PATH] = {"base": source, "candidate": source}
        jobs[0]["name"] = "ui-selection"
        summaries[0]["run"]["job"] = "ui-selection"
        selected = [test_identity("host", "UI selection")]
        summaries[0]["population"].update(declared=selected, compiled=selected, observed=[observation(selected[0], "passed", 0)])
        modules = {name: (Path(__file__).parent / name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
        with patch("ci_publish_git.trusted_reader", return_value=modules):
            self.assertEqual(evaluate_records(record, self.run, jobs, summaries, approved=False, fork=False, cloud=proof)["state"], "success")
            fallback_record, fallback_jobs, fallback_summaries, _ = self.gate_fixture(set())
            fallback_record["workflows"][cloud.UI_PATH] = record["workflows"][cloud.UI_PATH]
            fallback_record["cloud_v2_inputs"] = {"error": "head hook changed"}
            fallback_jobs[0]["name"] = "ui-selection"
            fallback_summaries[0] = copy.deepcopy(summaries[0])
            self.assertEqual(evaluate_records(fallback_record, self.run, fallback_jobs, fallback_summaries,
                             approved=False, fork=False)["state"], "success")
        api = Mock()
        retained = dict(jobs[0], id=11, runner_id=9, started_at="one", completed_at="two")
        api.pages.side_effect = [[retained], [dict(retained, id=12)]]
        self.assertEqual(cloud.archive_evidence_run(api, self.run, selection_job="ui-selection")["run_attempt"], 1)
        api.pages.side_effect = [[retained], [dict(retained, id=12, started_at="new")]]
        self.assertEqual(cloud.archive_evidence_run(api, self.run, selection_job="ui-selection")["run_attempt"], 2)
        wait_source = '''jobs:
  wait:
    name: ui-cloud-wait-ios
    steps:
      - run: python3 scripts/ci_ui_tests.py wait-group --group ios
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: {name: 'group-${{ github.run_id }}-${{ github.run_attempt }}', path: records/summary.json}
'''
        self.assertEqual(workflow_contract(wait_source, self.run, metadata=True)[3]["ui-cloud-wait-ios"]["population"], "ui-cloud-wait-ios")
        with self.assertRaises(ContractError):
            workflow_contract(wait_source.replace("--group ios", "--group macos"), self.run)

    def test_changed_hooks_symlinks_case_shadows_and_redirected_plans_cannot_be_admitted(self):
        root = Path(__file__).resolve().parent.parent
        import json
        files = {path: (root / path).read_text() for path in (
            "ci_scripts/ci_post_clone.sh", "ci_scripts/ci_pre_xcodebuild.sh", "ci_scripts/ci_post_xcodebuild.sh",
            "ci_scripts/fixture_server.py", "scripts/strict_e2e_server.py", "scripts/ci_ui_selection.py",
            "scripts/ci_ui_packing.py", "scripts/ci_ui_test_kinds.py", "scripts/ci_ui_shards.py",
            "scripts/ci-ui-areas.json", "scripts/ci-ui-durations.json")}
        files[self.groups.REGISTRY_PATH] = json.dumps(self.registry)
        plan_path = self.registration["actions"][0]["plan_path"]
        scheme_path = self.registration["actions"][0]["scheme_path"]
        files[plan_path] = json.dumps(self.record["cloud_v2_inputs"]["plans"][plan_path])
        files[scheme_path] = '<Scheme><TestAction><TestPlans><TestPlanReference reference="container:' + plan_path + '"/></TestPlans></TestAction></Scheme>'
        listing = [{"path": path, "type": "blob", "mode": "100644"} for path in files]
        read = lambda revision, path: files[path]
        self.assertEqual(self.groups.snapshot("c" * 40, "a" * 40, listing, listing, read, "b" * 40)["registry"], self.registry)
        self.assertIsNone(self.groups.snapshot("c" * 40, "a" * 40, [], listing, read, "b" * 40))
        for mutation in ("hook", "symlink", "case-shadow", "extra-hook", "extra-symlink", "redirect", "fixture", "duplicate-json"):
            head = copy.deepcopy(listing)
            changed = dict(files)
            if mutation == "hook":
                changed["ci_scripts/ci_post_clone.sh"] += "\nfalse\n"
            elif mutation == "symlink":
                next(entry for entry in head if entry["path"] == plan_path)["mode"] = "120000"
            elif mutation == "case-shadow":
                head.append({"path": plan_path.lower(), "type": "blob", "mode": "100644"})
            elif mutation == "extra-hook":
                head.append({"path": "ci_scripts/unreviewed.sh", "type": "blob", "mode": "100644"})
            elif mutation == "extra-symlink":
                head.append({"path": "ci_scripts/unreviewed.sh", "type": "blob", "mode": "120000"})
            elif mutation == "redirect":
                changed[scheme_path] = files[scheme_path].replace("container:", "container:other/")
            elif mutation == "fixture":
                changed["ci_scripts/fixture_server.py"] += "\n# mismatch\n"
            else:
                changed[self.groups.REGISTRY_PATH] = '{"schema_version": 2, "schema_version": 2, "groups": {}}'
            with self.subTest(mutation=mutation), self.assertRaises(ContractError):
                self.groups.snapshot("c" * 40, "a" * 40, listing, head,
                                     lambda revision, path: changed[path] if revision == "a" * 40 else files[path], "b" * 40)

    def test_receipt_binds_descriptor_runtime_plan_pointer_route_and_attempt(self):
        from test_ci_publish import FIXTURE_UI
        self.record["workflows"] = {cloud.UI_PATH: {"base": FIXTURE_UI}}
        receipt = {field: copy.deepcopy(self.route[field]) for field in (
            "schema_version", "identity", "producer_run_id", "producer_attempt", "group", "selection_sha256", "pointer_id")}
        receipt.update(selection=self.descriptor, runtime_plan_sha256=self.descriptor["runtime_plan_sha256"],
                       route_artifact_id=90, evidence=self.evidence)
        api = Mock()
        api.pages.side_effect = lambda path, *args, **kwargs: [self.check] if path.endswith("check-runs") else [self.pointer]
        def read(*args, **kwargs):
            return (self.route, 90) if args[2] == cloud.ROUTE_PATH else (receipt, 91)
        with patch.object(cloud, "archive_evidence_run", return_value=self.run), patch.object(cloud, "trusted_artifact", side_effect=read):
            proof = self.groups.trusted_groups(api, self.record, self.run, {"ios"}, approved=False)
            self.assertEqual(proof["groups"]["ios"]["import_artifact_id"], 91)
            original = copy.deepcopy(receipt)
            for field, value in (("route_artifact_id", 92), ("producer_attempt", 1), ("pointer_id", 57),
                                 ("selection", {}), ("runtime_plan_sha256", {}), ("schema_version", 1), ("group", "tvos")):
                receipt.clear()
                receipt.update(copy.deepcopy(original), **{field: value})
                with self.subTest(field=field), self.assertRaises(ContractError):
                    self.groups.trusted_groups(api, self.record, self.run, {"ios"}, approved=False)
            receipt.clear()
            receipt.update(original)
            pointer_reads = iter([[self.pointer], [dict(self.pointer, id=57)]])
            api.pages.side_effect = lambda path, *args, **kwargs: [self.check] if path.endswith("check-runs") else next(pointer_reads)
            with self.assertRaises(ContractError):
                self.groups.trusted_groups(api, self.record, self.run, {"ios"}, approved=False)

    def test_separate_ios_actions_can_run_different_per_device_populations(self):
        action = self.registration["actions"][0]
        second = copy.deepcopy(action)
        second.update(name="Functional - iPad", check_name="Registered iPad check", plan_path="Cloud-iPad.xctestplan")
        action["devices"].pop("ipad")
        second["devices"].pop("iphone")
        self.registration["actions"].append(second)
        self.record["cloud_v2_inputs"]["plans"][second["plan_path"]] = copy.deepcopy(self.record["cloud_v2_inputs"]["plans"][action["plan_path"]])
        self.record["ui_inputs"]["base"]["selection"]["shards"]["ipad"]["scoped-a"].append(
            test_identity("ui", "SettingsTests/testOther", platform="ios", device="ipad"))
        descriptor = self.groups.selection(self.record, self.run, "ios", approved=False)
        self.route.update(selection_sha256=self.groups.canonical_hash(descriptor), runtime_plan_sha256=descriptor["runtime_plan_sha256"])
        self.pointer["description"] = "Selection only: " + "c" * 40 + " " + self.route["selection_sha256"]
        first = self.evidence["actions"][0]
        first["tests"][0]["destinations"] = [dict(action["devices"]["iphone"], status="SUCCESS")]
        other = copy.deepcopy(first)
        other.update(id="44444444-4444-4444-4444-444444444444", name=second["name"])
        other["tests"][0].update(id="ipad-one", destinations=[dict(second["devices"]["ipad"], status="SUCCESS")])
        other["tests"].append(dict(other["tests"][0], id="ipad-two", method="testOther()"))
        self.evidence["actions"].append(other)
        check = dict(self.check, id=89, name=second["check_name"], details_url=self.check["details_url"].rsplit("/", 1)[0] + "/" + other["id"])
        proof = self.groups.validate_evidence(self.record, self.run, self.route, self.evidence,
                                              [self.check, check], [self.pointer], approved=False)
        self.assertEqual(len(proof["identities"]), 3)
        self.assertEqual(proof["action_minutes"], 30)
        self.assertEqual(proof["compute_upper_minutes"], 30)
        self.assertEqual(len(proof["runtime_plan_sha256"]), 2)

    def test_group_diagnostics_preserve_counts_without_inventing_compiled_samples(self):
        from ci_report import cloud_pr_diagnostics
        _, _, summaries, proof = self.gate_fixture({"ios", "tvos"})
        diagnostics = cloud_pr_diagnostics(summaries, cloud=proof)
        self.assertEqual(diagnostics["counts"]["passed"], 4)
        self.assertEqual(diagnostics["counts"]["compiled"], 1)
        self.assertEqual(diagnostics["counts"]["compiled_not_exposed_by_api"], 3)
        self.assertEqual(set(diagnostics["xcode_cloud"]["groups"]), {"ios", "tvos"})
        self.assertTrue(all("identities" not in group for group in diagnostics["xcode_cloud"]["groups"].values()))

    def test_publication_reads_cloud_only_for_selected_skipped_groups_and_ignores_failed_cloud_on_complete_fallback(self):
        from ci_publish import compute
        from ci_publish_git import BASE_MODULES, OPTIONAL_BASE_MODULES
        modules = {name: (Path(__file__).parent / name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
        run = dict(self.run, workflow_id=42, status="completed", conclusion="success", head_branch="feature")
        workflow = {"id": 42, "path": cloud.UI_PATH}
        pr = {"number": 7, "state": "open", "head": {"sha": "a" * 40, "repo": {"full_name": "owner/repo"}},
              "base": {"ref": "main", "repo": {"full_name": "owner/repo"}}}
        api = Mock(repository="owner/repo")
        api.repo.return_value = pr
        with patch("ci_publish.workflows", return_value={"ci-ui": workflow}), \
                patch("ci_publish.approved_status", return_value=False), patch("ci_publish.approval_requests", return_value=[]), \
                patch("ci_publish_git.trusted_reader", return_value=modules), \
                patch.object(self.groups, "trusted_groups", side_effect=ContractError("Cloud failed")) as read_cloud:
            record, jobs, summaries, _ = self.gate_fixture(set())
            record.update(workflow_id=42, workflow_path=cloud.UI_PATH)
            api.pages.side_effect = lambda path, *args, **kwargs: [run] if path.endswith("/runs") else jobs
            with patch("ci_publish.trusted_admissions", return_value={123: record}), \
                    patch("ci_publish.producer_evidence", return_value=(jobs, summaries)):
                self.assertEqual(compute(api, 7, "", "publisher")[1]["ci-ui"]["state"], "success")
                read_cloud.assert_not_called()
            record, jobs, summaries, _ = self.gate_fixture({"ios"})
            record.update(workflow_id=42, workflow_path=cloud.UI_PATH)
            with patch("ci_publish.trusted_admissions", return_value={123: record}), \
                    patch("ci_publish.producer_evidence", return_value=(jobs, summaries)):
                status = compute(api, 7, "", "publisher")[1]["ci-ui"]
                self.assertEqual(status["state"], "failure")
                self.assertIn("Cloud ios", status["description"])
                self.assertIn("NOT_RUN", status["description"])
                self.assertEqual({item["identity"]["dimensions"]["device"] for item in status["diagnostics"]["missing"]},
                                 {"iphone", "ipad"})
                self.assertEqual(read_cloud.call_args.args[3], {"ios"})
            record["ui_inputs"]["base"]["selection"]["shards"]["appletv"] = {}
            tv_skip = {"name": "ui-appletv-scoped-a", "conclusion": "skipped"}
            source = record["workflows"][cloud.UI_PATH]["base"]
            self.assertEqual(self.groups.skipped_groups(source, run, jobs + [tv_skip], record, approved=False), {"ios"})


class GroupProducerTests(unittest.TestCase):
    """Guard scheduling, pointer provenance and exact plan materialization."""

    def setUp(self):
        GroupEvidenceTests.setUp(self)
        self.registry.update(cap_minutes=2700, billing_anchor={"day": 1, "time_zone": "UTC"},
                             asc_visibility_delay_seconds=600)

    def test_skipped_ui_history_uses_trusted_base_weights_for_live_device_families(self):
        import json
        import ci_xcode_cloud_group_route as router
        from ci_xcode_cloud_schedule import choose_cloud, month_policy
        now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        running = [{"id": i, "status": "in_progress", "conclusion": None, "labels": ["xcode-27"],
                    "runner_id": i, "name": "ui-" + ("iphone" if i % 2 else "ipad") + "-default",
                    "started_at": "2026-10-09T23:59:00Z", "steps": [{}]} for i in range(1, 6)]
        queued = [dict(running[i % 5], id=20 + i, status="queued", runner_id=0, steps=[],
                       created_at="2026-10-09T23:00:00Z") for i in range(10)]
        skipped = [{"id": 100 + i, "name": "ui-" + device + "-${{ matrix.shard }}", "status": "completed",
                    "conclusion": "skipped", "runner_id": 0, "labels": [], "steps": []}
                   for i, device in enumerate(("iphone", "ipad", "appletv"))]
        gate = {"id": 902, "run_attempt": 1, "head_sha": self.run["head_sha"], "path": ".github/workflows/ci-gate.yml"}
        completed = [{"id": i, "name": name, "status": "completed", "conclusion": "success"}
                     for i, name in enumerate(("build-ios", "unit-ios"), 200)]
        api = Mock()
        api.repo.side_effect = lambda path: {"workflow_runs": [gate] if "head_sha=" in path else [{"id": 901, "run_attempt": 1}]}
        api.pages.side_effect = lambda path, collection, **query: ([] if query.get("status") == "queued" else
            [{"id": 900, "run_attempt": 1}] if path == "actions/runs" else
            skipped if "/901/" in path else completed if "/902/" in path else running + queued)
        base_ui = {"manifest": {"shards": {"default": []}, "default_shard": "default"},
                   "base_populations": {device: [test_identity("ui", "SettingsTests/testToggle", platform="ios", device=device)]
                                        for device in ("iphone", "ipad")}}
        durations = {"schema_version": 1, "revision": "reviewed", "default_seconds": 120,
                     "seconds": {"iphone": {"SettingsTests/testToggle": 900}, "ipad": {"SettingsTests/testToggle": 900}, "appletv": {}}}
        selected = {"packing": {"estimated_job_seconds": {"iphone": [600], "ipad": [600]}}}
        with patch("ci_publish_git.read_blob", return_value=json.dumps(durations)) as read:
            estimate = router.queue_snapshot(api, now, selected, "ios", producer_run_id=123, head_sha=self.run["head_sha"],
                                             base_sha=self.identity["base_sha"], ui_inputs=base_ui)
        read.assert_called_once_with(self.identity["base_sha"], "scripts/ci-ui-durations.json")
        self.assertEqual(estimate["duration_history"]["ui-iphone-default"], [1440])
        self.assertTrue(choose_cloud(estimate, {"seconds": 1700, "reservation_minutes": 80}, 0,
                                     month_policy(now, self.registry["billing_anchor"]))["route"])
        for job in running + queued:
            job["name"] = job["name"].replace("-default", "-scoped-a")
        sampled = [dict(running[0], id=300 + i, name="ui-iphone-scoped-" + str(i), status="completed", conclusion="success",
                        started_at=now.isoformat(), completed_at=(now + timedelta(minutes=minutes)).isoformat())
                   for i, minutes in enumerate((15.9, 16.3, 17.0, 18.6, 21.9, 26.5, 27.4))]
        for recent, expected in ((skipped + sampled, 18.6 * 60), (skipped, 120)):
            with self.subTest(samples=len(recent)):
                api.pages.side_effect = lambda path, collection, **query: ([] if query.get("status") == "queued" else
                    [{"id": 900, "run_attempt": 1}] if path == "actions/runs" else
                    recent if "/901/" in path else completed if "/902/" in path else running + queued)
                with patch("ci_publish_git.read_blob", return_value=json.dumps(durations)):
                    estimate = router.queue_snapshot(api, now, selected, "ios", producer_run_id=123, head_sha=self.run["head_sha"],
                                                     base_sha=self.identity["base_sha"], ui_inputs=base_ui)
                self.assertAlmostEqual(estimate["duration_history"]["ui-iphone-scoped-a"][0], expected)
                self.assertEqual(estimate["duration_history"]["ui-ipad-scoped-a"], [120])
                if recent == skipped:
                    self.assertFalse(choose_cloud(estimate, {"seconds": 1700, "reservation_minutes": 80}, 0,
                                                 month_policy(now, self.registry["billing_anchor"]))["route"])

    def test_job_phases_share_the_runner_job_deadline_and_leave_upload_time(self):
        import json
        import tempfile
        import ci_xcode_cloud_route as router
        api = Mock()
        api.pages.return_value = [{"name": "xcc-start", "status": "in_progress", "started_at": "2026-10-10T00:00:00Z"}]
        for phase in ("prepare", "arm", "start"):
            with self.subTest(phase=phase):
                self.assertEqual(router.job_deadline(api, {"uploader_run_id": 900, "uploader_attempt": 1}, phase),
                                 datetime(2026, 10, 10, 0, 20, tzinfo=timezone.utc))
        api.pages.return_value[0]["started_at"] = None
        with self.assertRaises(ContractError):
            router.job_deadline(api, {"uploader_run_id": 900, "uploader_attempt": 1}, "start")
        api.pages.return_value[0]["started_at"] = (datetime.now(timezone.utc) - timedelta(minutes=19)).isoformat()
        with tempfile.TemporaryDirectory() as directory:
            event, output = Path(directory, "event.json"), Path(directory, "output")
            event.write_text(json.dumps({"inputs": {"producer_run_id": "123", "producer_attempt": "2", "group": "ios"}}))
            environment = {"GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output), "GITHUB_REPOSITORY": "owner/repo",
                           "CI_WORKFLOW_TOKEN": "test-token", "GITHUB_RUN_ID": "900", "GITHUB_RUN_ATTEMPT": "1", "RUNNER_TEMP": directory}
            with patch.dict(router.os.environ, environment), patch.object(router.sys, "argv", ["router", "start"]), \
                    patch.object(router, "credential_context"), patch.object(router, "RetryingGitHub", return_value=api), \
                    patch.object(router, "RenewingAppStoreConnect") as asc:
                self.assertEqual(router.main(), 1)
                asc.assert_not_called()
            api.repo.assert_not_called()

    def test_interrupted_after_arm_uploads_unposted_state_and_reconciles_without_reservation(self):
        import json
        import tempfile
        import ci_xcode_cloud_group_route as router
        prepared = dict(self.route, decision="pending", head_sha=self.run["head_sha"], reason="cloud-estimated-faster",
                        reference_id="branch")
        uploader = {"uploader_run_id": 900, "uploader_attempt": 1}
        api, asc = Mock(), Mock()
        api.request.return_value = {"resources": {"core": {"remaining": 1000}}}
        api.pages.return_value = [self.pointer]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory, "ci-xcc-route")
            folder.mkdir()
            (folder / "prepared.json").write_text(json.dumps(prepared))
            with patch.dict(router.os.environ, {"RUNNER_TEMP": directory, "GITHUB_OUTPUT": str(Path(directory, "output"))}), \
                    patch.object(router, "refresh_producer", return_value={"user": self.record["cloud_pr_author"],
                                                                           "base": {"sha": self.identity["base_sha"]}}), \
                    patch.object(router, "selection_open", return_value=True), patch.object(router, "remaining_seconds", return_value=100):
                router.phase(api, asc, self.run, {"inputs": {"group": "ios"}}, "arm", uploader,
                             deadline=datetime.now(timezone.utc) + timedelta(minutes=20))
                with patch.object(router, "prepare_group", side_effect=KeyboardInterrupt), self.assertRaises(KeyboardInterrupt):
                    router.phase(api, asc, self.run, {"inputs": {"group": "ios"}}, "start", uploader)
            marker = json.loads((folder / "post.json").read_text())
            start = json.loads((folder / "start.json").read_text())
            self.assertFalse(start["post_attempted"])
            api.repo.return_value = {"id": 42}
            api.pages.return_value = []
            with patch.object(router, "route_sources", return_value=[{"id": 900, "run_attempt": 1}]), \
                    patch.object(router.state, "receipt", side_effect=[marker, start]):
                self.assertEqual(router.unknown_starts(api, self.registry, {"ios": []}), [])
            with patch.dict(router.os.environ, {"RUNNER_TEMP": directory, "GITHUB_OUTPUT": str(Path(directory, "output"))}), \
                    patch.object(router, "prepare_group", return_value=prepared), \
                    patch.object(router.state, "receipt", return_value=marker), \
                    patch.object(router, "post_group", side_effect=KeyboardInterrupt):
                with self.assertRaises(KeyboardInterrupt):
                    router.phase(api, asc, self.run, {"inputs": {"group": "ios"}}, "start", uploader)
                attempted = json.loads((folder / "start.json").read_text())
                self.assertTrue(attempted["post_attempted"])
                with self.assertRaises(ContractError):
                    router.phase(api, asc, self.run, {"inputs": {"group": "ios"}}, "start", uploader)
                self.assertTrue(json.loads((folder / "start.json").read_text())["post_attempted"])
            asc.request.assert_not_called()

    def test_interrupted_atomic_state_replacement_preserves_the_previous_record(self):
        import json
        import tempfile
        import ci_xcode_cloud_route as router
        with tempfile.TemporaryDirectory() as directory, patch.dict(router.os.environ, {"RUNNER_TEMP": directory}):
            router.write_phase("start", {"post_attempted": False})
            with patch.object(router.os, "replace", side_effect=KeyboardInterrupt), self.assertRaises(KeyboardInterrupt):
                router.write_phase("start", {"post_attempted": True})
            self.assertFalse(json.loads(Path(directory, "ci-xcc-route/start.json").read_text())["post_attempted"])

    def test_recent_reconciliation_refuses_low_rate_budget_and_truncated_run_lists(self):
        from urllib.parse import parse_qs, urlsplit
        import ci_xcode_cloud_group_route as router
        api = Mock()
        api.request.return_value = {"resources": {"core": {"remaining": 10}}}
        with self.assertRaises(ContractError):
            router.route_sources(api, {"id": 42})
        api.repo.assert_not_called()
        api.request.return_value["resources"]["core"]["remaining"] = 1000
        api.repo.return_value = {"total_count": 1001, "workflow_runs": []}
        with self.assertRaises(ContractError):
            router.route_sources(api, {"id": 42})
        api.repo.return_value = {"total_count": 0, "workflow_runs": []}
        self.assertEqual(router.route_sources(api, {"id": 42}), [])
        cutoff = parse_qs(urlsplit(api.repo.call_args.args[0]).query)["created"][0].removeprefix(">=")
        self.assertLess((datetime.now(timezone.utc) - router.timestamp(cutoff)).total_seconds(), 3 * 3600)
        peak = [{"id": 900 + i, "run_attempt": 1} for i in range(46)]
        api.repo.return_value = {"total_count": 46, "workflow_runs": peak}
        self.assertEqual(router.route_sources(api, {"id": 42}), peak)
        api.pages.return_value = []
        self.assertEqual(len(list(router.scheduling_attempts(api, peak))), 46)
        api.request.return_value["resources"]["core"]["remaining"] = 500
        with self.assertRaises(ContractError):
            router.route_sources(api, {"id": 42})
        api.request.return_value["resources"]["core"]["remaining"] = 2500
        paginated = [{"id": 900 + i, "run_attempt": 1} for i in range(101)]
        api.repo.side_effect = [{"total_count": 101, "workflow_runs": paginated[:100]},
                               {"total_count": 101, "workflow_runs": paginated[100:]}]
        self.assertEqual(router.route_sources(api, {"id": 42}), paginated)
        for call in api.repo.call_args_list[-2:]:
            self.assertEqual(parse_qs(urlsplit(call.args[0]).query)["per_page"], ["100"])
        api.repo.side_effect = None
        api.pages.return_value = [{"name": "ci-xcc-post-900-" + str(attempt)} for attempt in range(1, 27)]
        self.assertEqual(len(list(router.scheduling_attempts(api, [{"id": 900, "run_attempt": 26}]))), 26)
        api.request.return_value["resources"]["core"]["remaining"] = 500
        with self.assertRaises(ContractError):
            list(router.scheduling_attempts(api, [{"id": 900, "run_attempt": 26}]))

    def test_absent_build_resolves_only_after_start_deadline_and_reviewed_visibility_delay(self):
        import ci_xcode_cloud_group_route as router
        now = datetime(2026, 10, 10, 1, tzinfo=timezone.utc)
        marker = dict(self.route, head_sha=self.run["head_sha"], posted_at="2026-10-10T00:30:00Z",
                      start_deadline="2026-10-10T00:50:00Z")
        self.record["ui_inputs"]["base"]["selection"]["packing"]["estimated_test_seconds"] = {"iphone": 60, "ipad": 120}
        api = Mock()
        api.request.return_value = {"resources": {"core": {"remaining": 1000}}}
        api.pages.return_value = []
        api.repo.side_effect = [{"id": 42}, self.run]
        with patch.object(router, "route_sources", return_value=[{"id": 900, "run_attempt": 1}]), \
                patch.object(router.state, "receipt", side_effect=[marker, None]), \
                patch.object(router, "trusted_admissions", return_value={123: self.record}):
            self.assertTrue(router.unknown_starts(api, self.registry, {"ios": []}, now=now))
        api.repo.side_effect = None
        api.repo.return_value = {"id": 42}
        with patch.object(router, "route_sources", return_value=[{"id": 900, "run_attempt": 1}]), \
                patch.object(router.state, "receipt", side_effect=[marker, None]), \
                patch.object(router, "trusted_admissions", side_effect=AssertionError("complete absence proof suffices")):
            self.assertEqual(router.unknown_starts(api, self.registry, {"ios": []}, now=now.replace(second=1)), [])
        with patch.object(router, "route_sources", return_value=[{"id": 900, "run_attempt": 1}]), \
                patch.object(router.state, "receipt", side_effect=[marker, None]), self.assertRaises(ContractError):
            router.unknown_starts(api, self.registry, {}, now=now.replace(second=1))
        late = {"id": self.route["cloud_run_id"], "attributes": {"createdDate": "2026-10-10T00:55:00Z",
                "sourceCommit": {"commitSha": self.run["head_sha"]}}}
        for commit in (None, self.run["head_sha"]):
            late["attributes"]["sourceCommit"]["commitSha"] = commit
            with self.subTest(commit=commit), patch.object(router, "route_sources", return_value=[{"id": 900, "run_attempt": 1}]), \
                    patch.object(router.state, "receipt", side_effect=[marker, None]), self.assertRaises(ContractError):
                router.unknown_starts(api, self.registry, {"ios": [late]}, now=now.replace(second=1))

    def test_unknown_post_match_accepts_small_clock_skew_but_refuses_ambiguous_builds(self):
        import ci_xcode_cloud_group_route as router
        marker = dict(self.route, head_sha=self.run["head_sha"], posted_at="2026-10-10T00:00:00Z")
        row = {"id": self.route["cloud_run_id"], "attributes": {"createdDate": "2026-10-09T23:59:55Z",
               "sourceCommit": {"commitSha": self.run["head_sha"]}}}
        api = Mock()
        api.request.return_value = {"resources": {"core": {"remaining": 1000}}}
        api.pages.return_value = []
        api.repo.return_value = {"id": 42}
        for rows in ([row], [row, dict(row, id="22222222-2222-2222-2222-222222222222")]):
            with patch.object(router, "route_sources", return_value=[{"id": 900, "run_attempt": 1}]), \
                    patch.object(router.state, "receipt", side_effect=[marker, None]):
                if len(rows) == 1:
                    self.assertEqual(router.unknown_starts(api, self.registry, {"ios": rows}), [])
                else:
                    with self.assertRaises(ContractError):
                        router.unknown_starts(api, self.registry, {"ios": rows})

    def test_pointer_writer_reuses_identical_status_and_refuses_conflicting_history(self):
        from ci_xcode_cloud_selection import write_pointer
        api, app = Mock(), Mock()
        api.repository = "owner/repo"
        api.pages.return_value = [self.pointer]
        self.assertEqual(write_pointer(api, app, self.record, self.run, "ios"), 56)
        app.status.assert_not_called()
        api.pages.return_value = [dict(self.pointer, description="wrong")]
        with self.assertRaises(ContractError):
            write_pointer(api, app, self.record, self.run, "ios")
        app.status.assert_not_called()
        api.pages.side_effect = [[], [self.pointer]]
        self.assertEqual(write_pointer(api, app, self.record, self.run, "ios"), 56)
        self.assertEqual(app.status.call_args.args[1], self.pointer["context"])

    def test_rendering_uses_exact_device_population_and_rejects_pointer_hash_drift(self):
        from ci_xcode_cloud_selection import runtime_plans
        plans = runtime_plans(self.record, self.descriptor)
        self.assertEqual(plans["Cloud-iOS.xctestplan"]["testTargets"][0]["selectedTests"],
                         ["SettingsTests/testToggle()"])
        self.assertEqual(self.groups.canonical_hash(plans["Cloud-iOS.xctestplan"]),
                         self.descriptor["runtime_plan_sha256"]["Cloud-iOS.xctestplan"])
        descriptor = copy.deepcopy(self.descriptor)
        descriptor["runtime_plan_sha256"]["Cloud-iOS.xctestplan"] = "0" * 64
        with self.assertRaises(ContractError):
            runtime_plans(self.record, descriptor)

    def test_live_queue_estimate_deduplicates_attempt_jobs_and_does_not_count_unassigned_jobs_running(self):
        from ci_xcode_cloud_schedule import github_estimate
        now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        jobs = [{"id": index, "run_id": index, "status": "in_progress", "labels": ["xcode-27"],
                 "runner_id": index, "name": "ui-iphone-scoped-a", "created_at": "2026-10-09T23:59:00Z",
                 "started_at": "2026-10-09T23:59:00Z", "steps": [{"status": "in_progress"}]}
                for index in range(1, 6)]
        result = github_estimate(jobs + [jobs[0]], now, [600, 600], history={"ui-iphone-scoped-a": [3600]})
        self.assertEqual(result["running_mac_jobs"], 5)
        self.assertEqual(result["free_slots"], 0)
        self.assertGreater(result["seconds"], 3600)
        jobs[0] = dict(jobs[0], runner_id=0, steps=[])
        result = github_estimate(jobs, now, [600], history={"ui-iphone-scoped-a": [3600]})
        self.assertEqual(result["running_mac_jobs"], 4)
        self.assertFalse(result["can_prove_saturation"])

    def test_queue_snapshot_does_not_count_this_producers_blocked_matrices_twice(self):
        from ci_xcode_cloud_group_route import queue_snapshot
        now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        running = [{"id": index, "status": "in_progress", "conclusion": None, "labels": ["xcode-27"], "runner_id": index,
                    "name": "host-checks", "started_at": "2026-10-09T23:59:00Z", "steps": [{}]} for index in range(1, 6)]
        blocked = {"id": 7, "status": "queued", "labels": ["xcode-27"], "runner_id": 0, "steps": [],
                   "name": "ui-iphone-scoped-a", "created_at": "2026-10-09T23:59:00Z"}
        history = dict(running[0], id=9, status="completed", conclusion="success", started_at="2026-10-09T23:00:00Z",
                       completed_at="2026-10-09T23:45:00Z")
        api = Mock()
        gate = {"id": 902, "run_attempt": 1, "head_sha": self.run["head_sha"], "path": ".github/workflows/ci-gate.yml"}
        archive = {"id": 8, "name": "build-ios", "status": "completed", "conclusion": "success", "labels": ["xcode-27"]}
        unit = dict(archive, id=10, name="unit-ios")
        def response(path):
            if path.startswith("actions/runs?"):
                return {"workflow_runs": [{"id": 903, "run_attempt": 1, "name": "ci-publish"}]}
            return {"workflow_runs": [gate] if "head_sha=" in path else [{"id": 901, "run_attempt": 1, "name": "ci-gate"}]}
        api.repo.side_effect = response
        api.pages.side_effect = lambda path, collection, **query: ([] if query.get("status") == "queued" else
            [{"id": 900, "run_attempt": 1}, {"id": 123, "run_attempt": 2}] if path == "actions/runs" else
            [blocked] if "/123/" in path else [history] if "/901/" in path else [archive, unit] if "/902/" in path else
            [{"id": 903, "status": "completed", "conclusion": "success", "runner_id": 0}] if "/903/" in path else running)
        selected = {"packing": {"estimated_job_seconds": {"iphone": [600], "ipad": [600]}}}
        result = queue_snapshot(api, now, selected, "ios", producer_run_id=123, head_sha=self.run["head_sha"])
        self.assertTrue(result["can_prove_saturation"])
        self.assertEqual(result["queued_mac_jobs"], 0)
        self.assertEqual(result["archive_ready_seconds"], 0)
        queried = [call.args[0] for call in api.repo.call_args_list]
        self.assertEqual(sum("status=success" in path for path in queried), 4)
        self.assertTrue(all("actions/workflows/" in path for path in queried))
        cached = result["duration_history"]
        api.repo.reset_mock()
        queue_snapshot(api, now, selected, "ios", producer_run_id=123, head_sha=self.run["head_sha"], history=cached)
        self.assertFalse(any("status=success" in call.args[0] for call in api.repo.call_args_list))
        names = ("nightly-strict-ipad-immichSlides-iOS-debug-4", "nightly-strict-ipad-immichSlides-iOS-debug-6",
                 "nightly-strict-iphone-immichSlides-iOS-debug-0", "nightly-strict-tv-immichSlides-tvOS-debug-0",
                 "live-unit (ios)", "live-unit (tvos)", "live-build (tvos)", "ci-p2-review", "ci-probe", "ci-strict-tracer")
        running[0]["name"] = names[0]
        queued = [dict(blocked, id=20 + i, name=name) for i, name in enumerate(names[1:])]
        api.pages.side_effect = lambda path, collection, **query: ([] if query.get("status") == "queued" else
            [{"id": 38088674819, "run_attempt": 1}] if path == "actions/runs" else
            [archive, unit] if "/902/" in path else running + queued)
        estimate = queue_snapshot(api, now, selected, "ios", producer_run_id=123, head_sha=self.run["head_sha"], history=cached)
        self.assertTrue(estimate["can_prove_saturation"])
        self.assertEqual(estimate["queued_mac_jobs"], len(queued))
        self.assertLess(estimate["seconds"], result["seconds"])

    def test_two_minute_margin_free_capacity_budget_and_confirmed_month_end_rules(self):
        from ci_xcode_cloud_schedule import choose_cloud, month_policy
        now = datetime(2026, 10, 30, tzinfo=timezone.utc)
        normal = month_policy(now, None)
        self.assertEqual((normal["reserve_minutes"], normal["margin_seconds"]), (120, 120))
        end = month_policy(now, {"day": 1, "time_zone": "UTC"})
        self.assertEqual((end["reserve_minutes"], end["margin_seconds"]), (0, 0))
        busy = {"can_prove_saturation": True, "free_slots": 0, "seconds": 1500}
        cloud_estimate = {"seconds": 1400, "reservation_minutes": 60}
        self.assertFalse(choose_cloud(busy, cloud_estimate, 0, normal)["route"])
        self.assertTrue(choose_cloud(busy, cloud_estimate, 0, end)["route"])
        self.assertFalse(choose_cloud(dict(busy, free_slots=1), cloud_estimate, 0, end)["route"])
        self.assertFalse(choose_cloud(dict(busy, seconds=5000), cloud_estimate, 2580, normal)["route"])
        self.assertTrue(choose_cloud(dict(busy, seconds=5000), cloud_estimate, 2520, normal)["route"])

    def test_cloud_compute_reservation_counts_destinations_and_rounds_up(self):
        from ci_xcode_cloud_schedule import cloud_estimate
        selected = self.record["ui_inputs"]["base"]["selection"]
        selected["packing"].update(estimated_test_seconds={"iphone": 60, "ipad": 120, "appletv": 0})
        self.descriptor["registration"]["destinations_parallel"] = True
        result = cloud_estimate(self.descriptor, selected)
        self.assertEqual(result["seconds"], (13 + 9 + 2 + 3) * 60)
        self.assertEqual(result["destination_count"], 2)
        self.assertEqual(result["reservation_minutes"] % 5, 0)
        self.assertGreaterEqual(result["reservation_minutes"], 2 * 24 * 1.3 + 5)
        self.descriptor["registration"]["destinations_parallel"] = False
        serialized = cloud_estimate(self.descriptor, selected)
        self.assertGreater(serialized["seconds"], result["seconds"])
        self.assertGreater(serialized["reservation_minutes"], result["reservation_minutes"])

    def test_absent_or_disabled_registry_never_reads_asc_and_each_group_freezes_on_github(self):
        import ci_xcode_cloud_group_route as router
        api, factory = Mock(), Mock()
        self.record["classification"] = {"app_affected": True}
        with patch.object(router, "current_producer"), patch.object(router, "trusted_admissions", return_value={123: self.record}):
            result = router.prepare_group(api, factory, self.run, "ios")
            self.assertEqual((result["decision"], result["reason"]), ("github", "routing-inactive"))
            factory.assert_not_called()
            api.pages.assert_not_called()

    def test_account_usage_counts_both_destinations_and_keeps_cross_window_active_reservations(self):
        from ci_xcode_cloud_group_route import account_usage
        now = datetime(2026, 10, 10, 1, tzinfo=timezone.utc)
        registration = {"account_product_ids": ["33333333-3333-3333-3333-333333333333"],
                        "account_action_destinations": {"Functional - iOS": 2}, "unknown_active_minutes": 250,
                        "account_workflow_attributes_sha256": {cloud.WORKFLOW_ID: self.groups.canonical_hash({"reviewed": True})}}
        active = {"id": "44444444-4444-4444-4444-444444444444", "attributes": {"executionProgress": "RUNNING"}}
        action = {"id": "55555555-5555-5555-5555-555555555555", "attributes": {"name": "Functional - iOS",
                  "executionProgress": "RUNNING", "startedDate": "2026-10-10T00:30:00Z", "finishedDate": None}}
        asc = Mock()
        asc.pages.side_effect = [[{"id": registration["account_product_ids"][0]}],
                                [{"id": cloud.WORKFLOW_ID, "attributes": {"reviewed": True}}], [active], [action]]
        usage = account_usage(asc, registration, now, "2026-10-01T00:00:00Z")
        self.assertEqual(usage["elapsed_minutes"], 60)
        self.assertGreaterEqual(usage["minutes"], 250)
        asc.pages.side_effect = [[{"id": registration["account_product_ids"][0]}],
                                [{"id": cloud.WORKFLOW_ID, "attributes": {"reviewed": False}}]]
        with self.assertRaises(ContractError):
            account_usage(asc, registration, now, "2026-10-01T00:00:00Z")
        asc.pages.side_effect = [[{"id": "66666666-6666-6666-6666-666666666666"}]]
        with self.assertRaises(ContractError):
            account_usage(asc, registration, now, "2026-10-01T00:00:00Z")

    def test_ambiguous_post_is_never_replayed_and_failed_cloud_returns_the_group_to_github(self):
        import ci_xcode_cloud_group_route as router
        asc = Mock()
        asc.request.side_effect = ContractError("ASC POST refused request (HTTP 503)")
        prepared = dict(self.route, decision="pending", reference_id="registered-branch")
        prepared["selection"] = self.descriptor
        result = router.post_group(asc, prepared)
        self.assertEqual(result["reason"], "start-outcome-unknown")
        self.assertEqual(asc.request.call_count, 1)
        asc.request.side_effect = ContractError("ASC POST refused request (HTTP 404)")
        result = router.post_group(asc, prepared)
        self.assertEqual((result["decision"], result["http_status"]), ("fallback", 404))

    def test_unknown_post_reservation_is_recomputed_while_inventory_visibility_is_pending(self):
        import ci_xcode_cloud_group_route as router
        self.record["ui_inputs"]["base"]["selection"]["packing"].update(
            estimated_test_seconds={"iphone": 60, "ipad": 120, "appletv": 0})
        marker = dict(self.route, head_sha=self.run["head_sha"], posted_at=datetime.now(timezone.utc).isoformat(),
                      reservation_minutes=1)
        source = {"id": 900, "run_attempt": 1}
        api = Mock()
        api.request.return_value = {"resources": {"core": {"remaining": 1000}}}
        api.pages.return_value = []
        api.repo.side_effect = [{"id": 42}, self.run]
        with patch.object(router.state, "receipt", side_effect=[marker, None]), \
                patch.object(router, "route_sources", return_value=[source]), \
                patch.object(router, "trusted_admissions", return_value={123: self.record}):
            reservations = router.unknown_starts(api, self.registry, {"ios": []})
        expected = router.cloud_estimate(self.descriptor, self.record["ui_inputs"]["base"]["selection"])["reservation_minutes"]
        self.assertEqual(reservations[0]["minutes"], expected)
        self.assertGreater(reservations[0]["minutes"], marker["reservation_minutes"])
        api.pages.return_value = []
        api.repo.side_effect = [{"id": 42}]
        with patch.object(router, "route_sources", return_value=[source]), \
                patch.object(router.state, "receipt", side_effect=[marker, dict(marker, post_attempted=False)]):
            self.assertEqual(router.unknown_starts(api, self.registry, {"ios": []}), [])
        # A workflow rerun updates the run list but cannot hide its older POST.
        api.repo.side_effect = [{"id": 42}, self.run]
        api.pages.return_value = [{"name": "ci-xcc-post-900-1"}]
        rerun = dict(source, run_attempt=2)
        with patch.object(router, "route_sources", return_value=[rerun]), \
                patch.object(router.state, "receipt", side_effect=[marker, None]), \
                patch.object(router, "trusted_admissions", return_value={123: self.record}):
            prior = router.unknown_starts(api, self.registry, {"ios": []}, current_uploader=(900, 2))
        self.assertEqual(prior, [{"uploader_run_id": 900, "uploader_attempt": 1, "minutes": expected}])

    def test_cloud_bootstrap_pointer_does_not_trust_login_or_other_workflow(self):
        import importlib.util
        path = Path(__file__).resolve().parent.parent / "ci_scripts/cloud_selection.py"
        spec = importlib.util.spec_from_file_location("cloud_bootstrap_probe", path)
        bootstrap = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bootstrap)
        pointer = dict(self.pointer, url=bootstrap.ORIGIN + "statuses/" + self.run["head_sha"],
                       target_url="https://github.com/" + bootstrap.REPOSITORY + "/commit/" + self.identity["merge_sha"])
        selected = bootstrap.pointer_for([pointer], self.run["head_sha"], workflow_id=cloud.WORKFLOW_ID,
                                         registry_value=self.registry)
        self.assertEqual(selected[3:6], ("ios", self.identity["base_sha"], self.digest))
        for bad in (dict(pointer, creator={"login": self.groups.PUBLISHER_LOGIN, "id": 1}),
                    dict(pointer, description=pointer["description"].removeprefix("Selection only: ")),
                    dict(pointer, url=bootstrap.ORIGIN + "statuses/" + "f" * 40)):
            with self.subTest(pointer=bad), self.assertRaises(ValueError):
                bootstrap.pointer_for([bad], self.run["head_sha"], workflow_id=cloud.WORKFLOW_ID,
                                      registry_value=self.registry)

    def test_cloud_recomputation_matches_the_github_functional_packed_selection(self):
        import json
        import subprocess
        import ci_ui_tests as producer
        from ci_xcode_cloud_selection import recompute
        root = Path(__file__).resolve().parent.parent
        files = {path: (root / path).read_text() for path in subprocess.check_output(
                 ["git", "ls-files"], cwd=root, text=True).splitlines()
                 if path.startswith(("scripts/", "ci_scripts/", "immichSlidesUITests/")) and path.endswith((".py", ".json", ".swift"))}
        for path in ("immichSlides-iOS.xctestplan", "immichSlides-tvOS.xctestplan", "immichSlides.xcodeproj/project.pbxproj"):
            files[path] = (root / path).read_text()
        for path in (root / "ci_scripts").iterdir():
            if path.is_file():
                files[path.relative_to(root).as_posix()] = path.read_text()
        files[self.groups.REGISTRY_PATH] = json.dumps(self.registry)
        files["Cloud-iOS.xctestplan"] = json.dumps(self.record["cloud_v2_inputs"]["plans"]["Cloud-iOS.xctestplan"])
        scheme = self.registration["actions"][0]["scheme_path"]
        files[scheme] = '<Scheme><TestAction><TestPlans><TestPlanReference reference="container:Cloud-iOS.xctestplan"/></TestPlans></TestAction></Scheme>'
        members = [path.relative_to(root).as_posix() for path in (root / "immichSlides").rglob("*.swift")]
        listing = [{"path": path, "type": "blob", "mode": "100644"} for path in set(files) | set(members)]
        for changed in ("immichSlides/iOS/Settings/SettingsViewIOS.swift", "immichSlides/tvOS/Filter/AlbumFilterViewTV.swift",
                        "immichSlides/Shared/Models/Album.swift"):
            record = recompute(self.identity, self.run, self.record["cloud_pr_author"], listing=lambda revision: listing,
                read_blob=lambda revision, path: files[path], changed_paths=[changed], head_tree=self.identity["tree_sha"])
            with patch.object(producer, "git_blob", side_effect=lambda revision, path: files[path].encode()), \
                    patch.object(producer.subprocess, "check_output", side_effect=[changed + "\n", "\n".join(members), "\n".join(members)]):
                planned = producer.planned_ui_selection(self.identity, pack_scoped_ui=True)
            self.assertEqual(record["ui_inputs"]["base"]["selection"]["packing"], planned["packing"])

    def test_group_waits_do_not_wait_for_an_archive_when_cloud_is_verified_and_fallback_is_exact(self):
        import json
        import tempfile
        from types import SimpleNamespace
        import ci_ui_tests as producer
        import ci_xcode_cloud_ui as consumer
        context = {"identity": self.identity, "source": {"repository": "owner/repo", "event": "pull_request",
            "workflow_path": cloud.UI_PATH, "fork_originated": False, "ci_changing": None},
            "run": {"id": "123", "attempt": 2, "tier": "ui-infrastructure", "job": "ui-selection", "shard": None}}
        for group in ("ios", "tvos"):
            for decision in ("routed", "github"):
                with self.subTest(group=group, decision=decision), tempfile.TemporaryDirectory() as directory:
                    selection = Path(directory, "ui-selection.json")
                    selection.write_text(json.dumps({"identity": self.identity, "run_ui": True,
                        "platform_shards": {group: ["scoped-a"]}, "keys": {group: ["SettingsTests/testToggle"]},
                        "packing": {"sha256": "e" * 64}}))
                    arguments = SimpleNamespace(group=group, output_dir=Path(directory, "records"), selection_path=selection,
                                                timeout_minutes=180, defer_main_ui=True)
                    with patch.object(producer, "context", return_value=copy.deepcopy(context)), \
                            patch.object(producer, "workspace_preflight"), patch.object(consumer, "RetryingGitHub"), \
                            patch.object(consumer, "wait_cloud_group", return_value=decision), patch.object(producer, "output"), \
                            patch.dict(consumer.os.environ, {"GH_TOKEN": "test-placeholder"}), \
                            patch.object(producer, "select_archive", return_value={"artifact_id": 9, "producer_run_id": 99,
                                                                                  "producer_attempt": 1}) as archive:
                        self.assertEqual(consumer.wait_group(arguments), 0)
                    self.assertEqual(archive.call_count, int(decision == "github"))
                    summary = json.loads((arguments.output_dir / "summary.json").read_text())
                    self.assertEqual(summary["run"]["job"], "ui-cloud-wait-" + group)
                    if decision == "github":
                        self.assertEqual(archive.call_args.kwargs["platform_name"], group)
                        receipt = json.loads((arguments.output_dir / ("archive-selection-" + group + ".json")).read_text())
                        self.assertEqual(receipt["selected_keys"], ["SettingsTests/testToggle"])
                        self.assertEqual(receipt["packing"]["sha256"], "e" * 64)

    def test_fork_nightly_and_unregistered_waits_never_consume_cloud_proof(self):
        from ci_xcode_cloud_ui import wait_cloud_group
        for event, fork in (("schedule", False), ("pull_request", True)):
            api = Mock()
            self.assertEqual(wait_cloud_group({"identity": {"event": event}, "source": {"fork_originated": fork}}, api, "ios"), "github")
            api.assert_not_called()
            self.assertEqual(api.method_calls, [])

    def test_group_wait_allows_admission_to_arrive_after_the_linux_selection(self):
        import ci_xcode_cloud_ui as consumer
        self.registry["routing_enabled"] = True
        run = dict(self.run, status="in_progress", run_started_at="2026-10-10T00:00:00Z")
        api = Mock(repository="owner/repo")
        api.repo.side_effect = lambda path: run if path.startswith("actions/runs/") else {"id": 42, "state": "active"}
        context = {"identity": self.identity, "source": {"fork_originated": False}, "run": {"id": "123", "attempt": 2}}
        sleep = Mock()
        with patch.object(consumer, "registration_hint", return_value=True), \
                patch("ci_publish.verify_workflow"), patch("ci_publish.trusted_admissions", side_effect=[{}, {123: self.record}]), \
                patch("ci_xcode_cloud_group_route.anchor", return_value="ui-selection"), \
                patch.object(consumer, "archive_evidence_run", return_value=run), \
                patch.object(consumer, "trusted_artifact", return_value=(self.route, 99)), \
                patch.object(self.groups, "trusted_groups", return_value={"schema_version": 2, "groups": {"ios": {}}}):
            self.assertEqual(consumer.wait_cloud_group(context, api, "ios", sleep=sleep, monotonic=lambda: 0), "routed")
        sleep.assert_called_once_with(15)

    def test_group_wait_filters_single_pages_and_backs_off_until_import_proof_arrives(self):
        from urllib.parse import parse_qs, urlsplit
        import ci_xcode_cloud_ui as consumer
        self.registry["routing_enabled"] = True
        run = dict(self.run, run_attempt=1, status="in_progress", run_started_at="2026-10-10T00:00:00Z")
        api = Mock(repository="owner/repo")
        def response(path):
            if path.startswith("actions/runs/"):
                return run
            if "/runs?" in path:
                return {"workflow_runs": [{"id": 900, "run_attempt": 1, "display_title": "xcc-route-123-1-ios",
                                          "status": "in_progress"}] if "/42/" in path else []}
            return {"id": 42 if path.endswith("route.yml") else 43, "state": "active"}
        api.repo.side_effect = response
        api.pages.return_value = []
        context = {"identity": self.identity, "source": {"fork_originated": False}, "run": {"id": "123", "attempt": 1}}
        elapsed, pauses = [0], []
        def sleep(seconds):
            pauses.append(seconds)
            elapsed[0] += seconds
        with patch.object(consumer, "registration_hint", return_value=True), patch("ci_publish.verify_workflow"), \
                patch("ci_publish.trusted_admissions", return_value={123: self.record}), \
                patch("ci_xcode_cloud_group_route.anchor", return_value="ui-selection"), \
                patch.object(consumer, "archive_evidence_run", return_value=run), \
                patch.object(consumer, "trusted_artifact", return_value=(self.route, 99)), \
                patch.object(self.groups, "trusted_groups", side_effect=[ContractError("import pending")] * 5 + [{}]):
            self.assertEqual(consumer.wait_cloud_group(context, api, "ios", sleep=sleep, monotonic=lambda: elapsed[0]), "routed")
        self.assertEqual(pauses, [60, 120, 240, 300, 300])
        self.assertEqual(api.pages.call_count, 5)
        self.assertTrue(all(call.args[0] == "actions/runs/900/artifacts" for call in api.pages.call_args_list))
        queries = [parse_qs(urlsplit(call.args[0]).query) for call in api.repo.call_args_list if "/runs?" in call.args[0]]
        self.assertEqual(len(queries), 10)
        self.assertTrue(all(query["per_page"] == ["100"] and query["event"] == ["workflow_dispatch"]
                            and query["created"] == [">=2026-10-09T23:55:00+00:00"] for query in queries))
        queried = [call.args[0] for call in api.repo.call_args_list if "/runs?" in call.args[0]]
        self.assertTrue(any("/42/" in path for path in queried) and any("/43/" in path for path in queried))

    def test_router_waits_for_the_publishers_pointer_before_releasing_the_group(self):
        import ci_xcode_cloud_group_route as router
        self.registry.update(routing_enabled=True, scm_repository_id="33333333-3333-3333-3333-333333333333")
        self.record["ui_inputs"]["base"]["selection"]["packing"]["estimated_test_seconds"] = {"iphone": 60, "ipad": 120}
        api, asc, sleep = Mock(), Mock(), Mock()
        api.pages.side_effect = [[], [self.pointer]]
        asc.pages.return_value = [{"id": "branch-ref", "attributes": {"canonicalName": "refs/heads/topic"}}]
        pr = {"user": self.record["cloud_pr_author"], "base": {"sha": self.identity["base_sha"]}, "head": {"ref": "topic"}}
        with patch.object(router, "current_producer"), patch.object(router, "trusted_admissions", return_value={123: self.record}), \
                patch.object(router, "anchor", return_value="ui-selection"), \
                patch.object(router, "archive_evidence_run", return_value=dict(self.run, archive_job={"status": "completed", "conclusion": "success"})), \
                patch.object(router, "selection_open", return_value=True), patch.object(router, "remaining_seconds", return_value=100), \
                patch.object(router, "refresh_producer", return_value=pr), patch.object(router, "group_started", return_value=False) as past, \
                patch.object(router, "queue_snapshot", return_value={"seconds": 7200, "free_slots": 0, "can_prove_saturation": True,
                                                                    "duration_history": {}}) as queue, \
                patch.object(router, "inventories", return_value={"ios": []}), patch.object(router, "account_usage", return_value={"minutes": 300}), \
                patch.object(router, "route_sources", return_value=[]), \
                patch.object(router, "unknown_starts", return_value=[]) as unknown:
            result = router.prepare_group(api, lambda: asc, self.run, "ios", sleep=sleep, monotonic=lambda: 0)
            api.pages.side_effect = None
            api.pages.return_value = [self.pointer]
            fresh = router.prepare_group(api, lambda: asc, self.run, "ios", prepared=result)
            self.assertEqual(fresh["decision"], "pending")
            self.assertEqual((past.call_count, unknown.call_count), (1, 1))
            self.assertEqual(queue.call_args.kwargs["history"], {})
        self.assertEqual(result["decision"], "pending")
        sleep.assert_called_once_with(15)

    def test_missing_confirmed_allowance_or_billing_period_refuses_cloud_before_asc(self):
        import ci_xcode_cloud_group_route as router
        self.registry["routing_enabled"] = True
        api = Mock()
        api.pages.return_value = [self.pointer]
        reviewed = dict(self.registry)
        for missing in ("cap_minutes", "billing_anchor", "asc_visibility_delay_seconds"):
            with self.subTest(missing=missing):
                self.registry.clear()
                self.registry.update({key: value for key, value in reviewed.items() if key != missing})
                factory = Mock(side_effect=AssertionError("ASC must not be accessed without confirmed account policy"))
                with patch.object(router, "current_producer"), patch.object(router, "trusted_admissions", return_value={123: self.record}), \
                        patch.object(router, "anchor", return_value="ui-selection"), \
                        patch.object(router, "archive_evidence_run", return_value=dict(self.run, archive_job={"status": "completed", "conclusion": "success"})), \
                        patch.object(router, "selection_open", return_value=True), patch.object(router, "remaining_seconds", return_value=100), \
                        patch.object(router, "queue_snapshot", return_value={"seconds": 7200, "free_slots": 0, "can_prove_saturation": True}):
                    result = router.prepare_group(api, factory, self.run, "ios")
                self.assertEqual((result["decision"], result["reason"]), ("fallback", "cloud-budget-unavailable"))
                factory.assert_not_called()

    def test_same_selection_cannot_post_again_but_a_full_rerun_can_choose_another_provider(self):
        import ci_xcode_cloud_group_route as router
        api = Mock()
        api.repo.return_value = {"id": 42, "total_count": 1, "workflow_runs": [{"id": 900, "run_attempt": 1,
                                                                                 "display_title": "xcc-route-123-1-ios"}]}
        api.request.return_value = {"resources": {"core": {"remaining": 1000}}}
        old = {"id": 900, "run_attempt": 1, "display_title": "xcc-route-123-1-ios"}
        api.pages.return_value = [old]
        with patch.object(router.state, "receipt") as read:
            self.assertFalse(router.group_started(api, self.run, "ios"))
            read.assert_not_called()
        current = dict(old, display_title="xcc-route-123-2-ios")
        api.repo.return_value["workflow_runs"] = [current]
        api.pages.return_value = []
        with patch.object(router.state, "receipt", return_value=dict(self.route, head_sha=self.run["head_sha"])):
            self.assertTrue(router.group_started(api, self.run, "ios"))
        api.repo.return_value["workflow_runs"] = [dict(current, run_attempt=2)]
        api.pages.return_value = [{"name": "ci-xcc-post-900-1"}]
        with patch.object(router.state, "receipt", return_value=dict(self.route, head_sha=self.run["head_sha"])) as read:
            self.assertTrue(router.group_started(api, self.run, "ios", current_uploader=(900, 2)))
            self.assertEqual(read.call_args.args[2]["run_attempt"], 1)

    def test_post_marker_phase_never_needs_asc_credentials(self):
        import json
        import tempfile
        import ci_xcode_cloud_group_route as router
        prepared = dict(self.route, decision="pending", head_sha=self.run["head_sha"], reason="cloud-estimated-faster")
        asc = Mock()
        api = Mock()
        api.pages.return_value = [self.pointer]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory, "output")
            state = Path(directory, "ci-xcc-route")
            state.mkdir()
            (state / "prepared.json").write_text(json.dumps(prepared))
            with patch.dict(router.os.environ, {"RUNNER_TEMP": directory, "GITHUB_OUTPUT": str(output)}, clear=True), \
                    patch.object(router, "refresh_producer", return_value={"user": self.record["cloud_pr_author"],
                                                                           "base": {"sha": self.identity["base_sha"]}}), \
                    patch.object(router, "selection_open", return_value=True), \
                    patch.object(router, "remaining_seconds", return_value=100), \
                    patch.object(router, "prepare_group", side_effect=AssertionError("credential-free arm must not refresh ASC")):
                self.assertEqual(router.phase(api, asc, self.run, {"inputs": {"group": "ios"}}, "arm",
                                             {"uploader_run_id": 900, "uploader_attempt": 1},
                                             deadline=datetime.now(timezone.utc) + timedelta(minutes=20)), 0)
            self.assertEqual(asc.method_calls, [])
            marker = json.loads((state / "post.json").read_text())
            self.assertEqual(marker["pointer_id"], 56)

    def test_armed_but_unposted_errors_persist_a_refusal_and_release_the_reservation(self):
        import json
        import tempfile
        import ci_xcode_cloud_group_route as router
        prepared = dict(self.route, decision="pending", head_sha=self.run["head_sha"], reason="cloud-estimated-faster")
        uploader = {"uploader_run_id": 900, "uploader_attempt": 1}
        api, asc = Mock(), Mock()
        api.request.return_value = {"resources": {"core": {"remaining": 1000}}}
        api.pages.return_value = [self.pointer]
        pr = {"user": self.record["cloud_pr_author"], "base": {"sha": self.identity["base_sha"]}}
        for error in (router.SupersededProducer("head changed"), RuntimeError("unexpected pre-POST error")):
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as directory:
                output, folder = Path(directory, "output"), Path(directory, "ci-xcc-route")
                folder.mkdir()
                (folder / "prepared.json").write_text(json.dumps(prepared))
                with patch.dict(router.os.environ, {"RUNNER_TEMP": directory, "GITHUB_OUTPUT": str(output)}), \
                        patch.object(router, "refresh_producer", return_value=pr), \
                        patch.object(router, "selection_open", return_value=True), \
                        patch.object(router, "remaining_seconds", return_value=100):
                    router.phase(api, asc, self.run, {"inputs": {"group": "ios"}}, "arm", uploader,
                                 deadline=datetime.now(timezone.utc) + timedelta(minutes=20))
                    with patch.object(router, "prepare_group", side_effect=error):
                        self.assertEqual(router.phase(api, asc, self.run, {"inputs": {"group": "ios"}}, "start", uploader), 0)
                marker = json.loads((folder / "post.json").read_text())
                start = json.loads((folder / "start.json").read_text())
                self.assertEqual((start["decision"], start["post_attempted"]), ("github", False))
                self.assertIn("start_recorded=true\npoll=false", output.read_text())
                api.repo.return_value = {"id": 42}
                api.pages.return_value = []
                with patch.object(router, "route_sources", return_value=[{"id": 900, "run_attempt": 1}]), \
                        patch.object(router.state, "receipt", side_effect=[marker, start]):
                    self.assertEqual(router.unknown_starts(api, self.registry, {"ios": []}), [])
                api.pages.side_effect = None
                api.pages.return_value = [self.pointer]
                asc.request.assert_not_called()

    def test_main_start_refusal_also_covers_errors_before_group_phase(self):
        import json
        import os
        import tempfile
        import ci_xcode_cloud_route as router
        uploader = {"uploader_run_id": 900, "uploader_attempt": 1}
        armed = dict(self.route, decision="pending", head_sha=self.run["head_sha"], reason="cloud-estimated-faster", **uploader)
        api = Mock(repository="owner/repo")
        api.repo.return_value = dict(self.run, run_attempt=3)
        with tempfile.TemporaryDirectory() as directory:
            event, output = Path(directory, "event.json"), Path(directory, "output")
            event.write_text(json.dumps({"inputs": {"producer_run_id": "123", "producer_attempt": "2", "group": "ios"}}))
            folder = Path(directory, "ci-xcc-route")
            folder.mkdir()
            (folder / "post.json").write_text(json.dumps(armed))
            environment = {"GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output), "GITHUB_REPOSITORY": "owner/repo",
                           "CI_WORKFLOW_TOKEN": "test-token", "GITHUB_RUN_ID": "900", "GITHUB_RUN_ATTEMPT": "1", "RUNNER_TEMP": directory}
            with patch.dict(os.environ, environment), patch.object(router.sys, "argv", ["router", "start"]), \
                    patch.object(router, "credential_context"), patch("ci_publish.git"), \
                    patch.object(router, "job_deadline", return_value=datetime.now(timezone.utc) + timedelta(minutes=20)), \
                    patch.object(router, "RetryingGitHub", return_value=api), patch.object(router, "jwt") as sign:
                self.assertEqual(router.main(), 0)
                self.assertFalse(json.loads((folder / "start.json").read_text())["post_attempted"])
                sign.assert_not_called()
            # A process exception after entering POST cannot be converted to a refund.
            (folder / "start.json").write_text(json.dumps(dict(armed, post_attempted=True)))
            with patch.dict(os.environ, environment), patch.object(router.sys, "argv", ["router", "start"]), \
                    patch.object(router, "credential_context"), patch.object(router, "RetryingGitHub", return_value=api), \
                    patch.object(router, "job_deadline", return_value=datetime.now(timezone.utc) + timedelta(minutes=20)), \
                    patch("ci_publish.git", side_effect=RuntimeError("failed before phase")):
                self.assertEqual(router.main(), 1)
            self.assertTrue(json.loads((folder / "start.json").read_text())["post_attempted"])

    def test_start_records_actual_post_time_and_does_not_repeat_historical_scans(self):
        import json
        import tempfile
        import ci_xcode_cloud_group_route as router
        prepared = dict(self.route, decision="pending", head_sha=self.run["head_sha"], reason="cloud-estimated-faster", reference_id="branch")
        uploader = {"uploader_run_id": 900, "uploader_attempt": 1}
        marker = dict(prepared, posted_at="2026-10-10T00:00:00Z", **uploader)
        api, asc = Mock(), Mock()
        api.request.return_value = {"resources": {"core": {"remaining": 1000}}}
        api.repo.return_value = {"id": 42}
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory, "ci-xcc-route")
            folder.mkdir()
            (folder / "prepared.json").write_text(json.dumps(prepared))
            (folder / "start.json").write_text(json.dumps(dict(prepared, post_attempted=False, **uploader)))
            with patch.dict(router.os.environ, {"RUNNER_TEMP": directory, "GITHUB_OUTPUT": str(Path(directory, "output"))}), \
                    patch.object(router, "prepare_group", return_value=prepared) as refresh, \
                    patch.object(router.state, "receipt", return_value=marker), \
                    patch.object(router, "post_group", side_effect=lambda *_: self.assertTrue(
                        json.loads((folder / "start.json").read_text())["post_attempted"]) or
                        {"decision": "fallback", "reason": "start-outcome-unknown", "cloud_run_id": None}):
                self.assertEqual(router.phase(api, asc, self.run, {"inputs": {"group": "ios"}}, "start", uploader), 0)
            started = json.loads((folder / "start.json").read_text())
            self.assertGreater(router.timestamp(started["posted_at"]), router.timestamp(marker["posted_at"]))
            self.assertIsNotNone(refresh.call_args.kwargs["prepared"])
            row = {"id": "11111111-1111-1111-1111-111111111111", "attributes": {
                "createdDate": started["posted_at"], "sourceCommit": {"commitSha": self.run["head_sha"]}}}
            api.pages.return_value = []
            with patch.object(router, "route_sources", return_value=[{"id": 900, "run_attempt": 1}]), \
                    patch.object(router.state, "receipt", side_effect=[marker, started]):
                self.assertEqual(router.unknown_starts(api, self.registry, {"ios": [row]}), [])

    def test_gate_forecast_uses_the_actual_archive_and_releases_units_after_their_build(self):
        from ci_xcode_cloud_schedule import github_estimate
        now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        running = [{"id": i, "name": "other", "status": "in_progress", "labels": ["xcode-27"],
                    "runner_id": i, "steps": [{}], "started_at": "2026-10-09T23:59:00Z"} for i in range(1, 6)]
        # The first slot frees in two minutes; four older 30-minute jobs occupy it first.
        running[0]["name"] = "short"
        queued = [{"id": i, "name": "other", "status": "queued", "labels": ["xcode-27"],
                   "created_at": "2026-10-09T23:00:00Z"} for i in range(6, 10)]
        build = {"id": 10, "name": "build-ios", "status": "queued", "labels": ["xcode-27"],
                 "created_at": "2026-10-09T23:59:00Z"}
        unit = {"id": 11, "name": "unit-ios", "status": "queued", "labels": [],
                "created_at": "2026-10-09T23:59:00Z"}
        gate = {"id": 44, "run_attempt": 2, "jobs": [build, unit]}
        history = {"short": [180], "other": [1860], "build-ios": [720], "unit-ios": [1200]}
        result = github_estimate(running + queued + [build, unit], now, {"iphone": [600]}, history=history,
                                 matrix_cap={"iphone": 2}, gate=gate, platform="ios")
        self.assertEqual(result["archive_ready_seconds"], 42 * 60)
        self.assertGreaterEqual(result["gate_job_finish_seconds"]["unit-ios"], 62 * 60)
        self.assertEqual(result["other_group_ui"], "not-modeled")
        gate["jobs"] = [build]  # GitHub has not created the dependent unit job yet.
        missing_unit = github_estimate(running + queued + [build], now, {"iphone": [600]}, history=history,
                                      matrix_cap={"iphone": 2}, gate=gate, platform="ios")
        self.assertGreaterEqual(missing_unit["gate_job_finish_seconds"]["unit-ios"], 62 * 60)
        gate["jobs"][0] = dict(build, status="completed", conclusion="success")
        completed = github_estimate(running + queued, now, {"iphone": [600]}, history=history,
                                   matrix_cap={"iphone": 2}, gate=gate, platform="ios")
        self.assertEqual(completed["archive_ready_seconds"], 0)

    def test_billing_anchor_rolls_over_months_time_zones_and_short_months(self):
        from ci_xcode_cloud_schedule import month_policy
        anchor = {"day": 31, "time_zone": "Asia/Singapore"}
        january = month_policy(datetime(2026, 1, 31, tzinfo=timezone.utc), anchor)
        february = month_policy(datetime(2026, 2, 28, tzinfo=timezone.utc), anchor)
        self.assertEqual(january["windows"][1][1], february["windows"][1][0])
        self.assertEqual(february["windows"][1], ("2026-02-27T16:00:00+00:00", "2026-03-30T16:00:00+00:00"))
        self.assertFalse(february["confirmed_expiry_window"])
        for invalid in ({"day": 0, "time_zone": "UTC"}, {"day": 1, "time_zone": "unknown-zone"},
                        {"start": "2026-10-01T00:00:00Z", "end": "2026-11-01T00:00:00Z"}):
            with self.subTest(anchor=invalid), self.assertRaises((ContractError, KeyError, ValueError)):
                month_policy(datetime(2026, 10, 10, tzinfo=timezone.utc), invalid)

    def test_route_history_is_recent_bounded_and_missing_queue_registration_refuses_cloud(self):
        import ci_xcode_cloud_group_route as router
        api = Mock()
        api.repo.return_value = {"id": 42, "total_count": 0, "workflow_runs": []}
        api.request.return_value = {"resources": {"core": {"remaining": 1000}}}
        api.pages.return_value = []
        self.assertFalse(router.group_started(api, self.run, "ios"))
        self.assertIn("created=", api.repo.call_args.args[0])
        self.registry["routing_enabled"] = True
        self.registration.pop("queue_seconds_upper")
        api.pages.return_value = [self.pointer]
        factory = Mock()
        with patch.object(router, "current_producer"), patch.object(router, "trusted_admissions", return_value={123: self.record}), \
                patch.object(router, "anchor", return_value="ui-selection"), patch.object(router, "selection_open", return_value=True), \
                patch.object(router, "remaining_seconds", return_value=100), \
                patch.object(router, "archive_evidence_run", return_value=dict(self.run, archive_job={"status": "completed", "conclusion": "success"})), \
                patch.object(router, "queue_snapshot", return_value={"seconds": 7200, "free_slots": 0, "can_prove_saturation": True}):
            result = router.prepare_group(api, factory, self.run, "ios")
        self.assertEqual((result["decision"], result["reason"]), ("fallback", "cloud-registry-unavailable"))
        factory.assert_not_called()

    def test_new_main_selection_and_both_group_waits_supply_complete_deferral_evidence(self):
        import json
        import tempfile
        from types import SimpleNamespace
        import ci_ui_tests as producer
        import ci_xcode_cloud_ui as consumer
        from ci_publish_git import bind_ui_shards, workflow_contract
        from ci_ui_reuse import evaluate_reused_push
        push = {"schema_version": 1, "repository": "owner/repo", "event": "push", "ref": "refs/heads/main",
                "pushed_sha": "a" * 40, "tree_sha": "b" * 40}
        context = {"identity": push, "source": {"repository": "owner/repo", "event": "push", "workflow_path": cloud.UI_PATH,
            "fork_originated": False, "ci_changing": None},
            "run": {"id": "123", "attempt": 2, "tier": "ui-infrastructure", "job": "ui-selection", "shard": None}}
        with tempfile.TemporaryDirectory() as directory, patch.object(producer, "context", side_effect=lambda: copy.deepcopy(context)), \
                patch.object(producer, "workspace_preflight"), patch.object(producer, "output"), \
                patch.object(consumer, "RetryingGitHub"), patch("ci_ui_reuse.find_reuse", return_value=None), \
                patch.dict(consumer.os.environ, {"GH_TOKEN": "test-placeholder"}), \
                patch.object(producer, "select_archive") as archive:
            selected = Path(directory, "selection")
            self.assertEqual(consumer.select(SimpleNamespace(output_dir=selected, pack_scoped_ui=True, defer_main_ui=True)), 0)
            planned = json.loads((selected / "ui-selection.json").read_text())
            self.assertFalse(planned["run_ui"])
            records = [json.loads((selected / "summary.json").read_text())]
            for group in ("ios", "tvos"):
                output = Path(directory, group)
                self.assertEqual(consumer.wait_group(SimpleNamespace(output_dir=output, group=group, timeout_minutes=180,
                    defer_main_ui=True, selection_path=selected / "ui-selection.json")), 0)
                records.append(json.loads((output / "summary.json").read_text()))
            archive.assert_not_called()
            source = bind_ui_shards((producer.ROOT / cloud.UI_PATH).read_text(), planned["device_shards"])
            run = dict(self.run, event="push", head_branch="main", status="completed", conclusion="success")
            names, _, _, metadata = workflow_contract(source, run, metadata=True)
            jobs = [{"name": name, "status": "completed", "conclusion": "skipped" if metadata[name]["tier"] == "ui" else "success",
                     "runner_id": 0, "steps": []} for name in names]
            record = {"identity": push, "workflows": {cloud.UI_PATH: {"base": source}},
                      "ui_inputs": {"base": {"manifest_sha256": records[0]["hashes"]["manifests"]["ui-shards"]}}}
            self.assertEqual(evaluate_reused_push(Mock(repository="owner/repo"), record, run, jobs, records)["state"], "pending")
            with self.assertRaises(ContractError):
                evaluate_reused_push(Mock(repository="owner/repo"), record, run, jobs, records[:-1])



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

    def test_cloud_wait_reads_wait_out_a_rate_limit_only_inside_the_deadline(self):
        from ci_xcode_cloud_client import RetryingGitHub
        from ci_publish import GitHub, RateLimited
        def client(deadline):
            elapsed = [0]
            return RetryingGitHub("owner/repo", "test-token", deadline, timer=lambda: elapsed[0], wait_out_rate_limits=True,
                                  sleep=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds)), elapsed
        waiting, elapsed = client(600)
        with patch.object(GitHub, "request", side_effect=[RateLimited("HTTP 403", 120), {"id": 1}]):
            self.assertEqual(waiting.request("/repos/owner/repo/actions/runs/1"), {"id": 1})
        self.assertEqual(elapsed[0], 121)
        waiting, _ = client(100)
        with patch.object(GitHub, "request", side_effect=[RateLimited("HTTP 403", 120), {"id": 1}]) as network, \
                self.assertRaises(RateLimited):
            waiting.request("/repos/owner/repo/actions/runs/1")
        self.assertEqual(network.call_count, 1)
        waiting, _ = client(121)  # the extra second of the sleep does not fit
        with patch.object(GitHub, "request", side_effect=[RateLimited("HTTP 403", 120), {"id": 1}]) as network, \
                self.assertRaises(RateLimited):
            waiting.request("/repos/owner/repo/actions/runs/1")
        self.assertEqual(network.call_count, 1)
        waiting, _ = client(600)
        with patch.object(GitHub, "request", side_effect=[ContractError("GitHub API GET refused request (HTTP 403)"), {"id": 1}]) as network, \
                self.assertRaises(ContractError):
            waiting.request("/repos/owner/repo/actions/runs/1")
        self.assertEqual(network.call_count, 1)
        with patch.object(GitHub, "request", side_effect=[RateLimited("HTTP 403", 5), {}]) as network, self.assertRaises(RateLimited):
            waiting.request("/repos/owner/repo/dispatches", method="POST", payload={})
        self.assertEqual(network.call_count, 1)

    def test_router_importer_and_dispatcher_clients_still_fail_at_once_on_a_rate_limited_403(self):
        import re
        import ci_xcode_cloud_dispatch, ci_xcode_cloud_import, ci_xcode_cloud_route
        from ci_xcode_cloud_client import RetryingGitHub
        from ci_publish import GitHub, RateLimited
        client = RetryingGitHub("owner/repo", "test-token", 600, timer=lambda: 0, sleep=lambda seconds: self.fail("must not wait"))
        with patch.object(GitHub, "request", side_effect=[RateLimited("GitHub API GET refused request (HTTP 403)", 30), {"id": 1}]) as network, \
                self.assertRaises(RateLimited):
            client.request("/repos/owner/repo/actions/runs/1")
        self.assertEqual(network.call_count, 1)
        for module in (ci_xcode_cloud_dispatch, ci_xcode_cloud_import, ci_xcode_cloud_route):
            with self.subTest(module=module.__name__):
                source = Path(module.__file__).read_text()
                self.assertTrue(re.search(r"RetryingGitHub\(", source))
                self.assertNotIn("wait_out_rate_limits", source)

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
            event.write_text(json.dumps({"inputs": {"producer_run_id": "123", "producer_attempt": "2", "group": "ios"}}))
            environment = {"GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output), "GITHUB_REPOSITORY": "owner/repo",
                           "CI_WORKFLOW_TOKEN": "test-token", "GITHUB_RUN_ID": "456", "GITHUB_RUN_ATTEMPT": "1", "RUNNER_TEMP": directory}
            with patch.dict(os.environ, environment), patch.object(router.sys, "argv", ["router", "prepare"]), \
                    patch.object(router, "credential_context"), patch("ci_publish.git"), patch.object(router, "RetryingGitHub", return_value=api), \
                    patch.object(router, "job_deadline", return_value=datetime.now(timezone.utc) + timedelta(minutes=20)), \
                    patch.object(router, "verify_workflow"), patch.object(router, "recorded_decision", return_value=False), \
                    patch("ci_xcode_cloud_group_route.phase", side_effect=router.SupersededProducer("old head")), patch.object(router, "jwt") as sign, \
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

    def test_unaffected_scoped_retained_or_late_producers_cannot_start_cloud(self):
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
            # A scoped selection, including one without Apple TV tests, never starts a Cloud build.
            base_ui = fixture.record.setdefault("ui_inputs", {}).get("base") or {}
            fixture.record["ui_inputs"]["base"] = dict(base_ui, selection={"mode": "scoped"})
            self.assertEqual(router.route_run(api, factory, fixture.run)["reason"], "scoped-ui-selection")
            capacity.assert_not_called()
            fixture.record["ui_inputs"]["base"] = base_ui
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
        with patch.object(bridge, "current_producer") as current, patch.object(bridge, "active_groups", return_value=["ios", "tvos"]):
            bridge.dispatch(api, {"workflow_run": {"id": 123}, "action": "requested"})
            current.assert_called_once_with(api, source)
        self.assertEqual(api.dispatch.call_count, 2)
        self.assertEqual({call.args[1]["group"] for call in api.dispatch.call_args_list}, {"ios", "tvos"})
        self.assertTrue(all(call.args[0] == cloud.ROUTE_PATH and call.args[1]["producer_run_id"] == "123"
                            and call.args[1]["producer_attempt"] == "2" for call in api.dispatch.call_args_list))
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

    def test_router_forwards_only_its_successful_job_and_routed_receipt(self):
        import ci_xcode_cloud_dispatch as bridge
        import ci_xcode_cloud_route as router
        fixture = CloudEvidenceTests()
        fixture.setUp()
        routing_api, asc_factory = Mock(), Mock()
        with patch.object(router, "current_producer"), \
                patch.object(router, "trusted_admissions", return_value={123: fixture.record}) as admission:
            github = router.route_run(routing_api, asc_factory, fixture.run, override="a" * 40 + ":github")
            admission.side_effect = ContractError("admission unavailable")
            fallback = router.route_run(routing_api, asc_factory, fixture.run)
        decisions = [router.poll_route(routing_api, asc_factory, fixture.record, fixture.run, receipt)
                     for receipt in (github, fallback)]
        self.assertEqual([receipt["decision"] for receipt in decisions], ["github", "fallback"])
        asc_factory.assert_not_called()
        api = Mock(repository="owner/repo")
        source = {"id": 456, "path": cloud.ROUTE_PATH, "repository": {"full_name": "owner/repo"},
                  "head_repository": {"full_name": "owner/repo"}, "run_attempt": 1, "conclusion": None,
                  "status": "in_progress", "event": "workflow_dispatch", "head_branch": "main",
                  "head_sha": "b" * 40, "workflow_id": 789}
        producer = {"id": 123, "head_sha": "a" * 40, "run_attempt": 2}
        env = {"GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "workflow_dispatch",
               "GITHUB_WORKFLOW_REF": "owner/repo/" + cloud.ROUTE_PATH + "@refs/heads/main",
               "GITHUB_JOB": "dispatch-import", "GITHUB_RUN_ID": "456", "GITHUB_RUN_ATTEMPT": "1"}
        event = {"inputs": {"producer_run_id": "123", "producer_attempt": "2"}}
        api.repo.side_effect = lambda path: (source if path == "actions/runs/456" else producer
                                            if path == "actions/runs/123" else {"id": 789, "path": cloud.ROUTE_PATH})
        job = {"name": "route", "status": "completed", "conclusion": "success"}
        artifact = {"name": "ci-xcc-route-123-2", "expired": False, "workflow_run": {"id": 456}}
        api.pages.side_effect = lambda path, *_args, **_kwargs: [job] if path.endswith("/jobs") else [artifact]
        receipt = {"schema_version": 1, "uploader_run_id": 456, "uploader_attempt": 1, "producer_run_id": 123,
                   "producer_attempt": 2, "decision": "routed", "terminal": True, "head_sha": "a" * 40}
        with patch.object(bridge, "git"), patch.object(cloud, "on_main", return_value=True), \
                patch.object(bridge, "current_producer") as current, patch.object(bridge, "json_member", return_value=receipt) as read:
            bridge.forward_import(api, env, event)
            current.assert_called_once_with(api, producer)
            api.dispatch.assert_called_once_with(cloud.IMPORT_PATH, {"producer_run_id": "123", "producer_attempt": "2"})
            api.dispatch.reset_mock()
            source["status"] = "queued"
            bridge.forward_import(api, env, event)
            api.dispatch.assert_called_once_with(cloud.IMPORT_PATH, {"producer_run_id": "123", "producer_attempt": "2"})
            api.dispatch.reset_mock()
            source["status"] = "in_progress"
            for decision in decisions:
                read.return_value = dict(decision, uploader_run_id=456, uploader_attempt=1)
                current.reset_mock()
                with self.subTest(decision=decision["decision"]):
                    bridge.forward_import(api, env, event)
                current.assert_not_called()
                api.dispatch.assert_not_called()
            read.return_value = receipt
            read.reset_mock()
            for field, value in (("head_branch", "candidate"), ("event", "pull_request"), ("run_attempt", 2), ("status", "completed")):
                original = source[field]
                source[field] = value
                with self.subTest(field=field), self.assertRaises(ContractError):
                    bridge.forward_import(api, env, event)
                read.assert_not_called()
                api.dispatch.assert_not_called()
                source[field] = original
            for conclusion in ("failure", "cancelled", "timed_out"):
                job["conclusion"] = conclusion
                with self.subTest(conclusion=conclusion), self.assertRaises(ContractError):
                    bridge.forward_import(api, env, event)
                read.assert_not_called()
                api.dispatch.assert_not_called()
            job["conclusion"] = "success"
            for field, value in (("producer_run_id", 999), ("producer_attempt", 3), ("uploader_attempt", 2),
                                 ("decision", "unknown"), ("terminal", False), ("head_sha", "c" * 40)):
                original = receipt[field]
                receipt[field] = value
                with self.subTest(field=field), self.assertRaises(ContractError):
                    bridge.forward_import(api, env, event)
                api.dispatch.assert_not_called()
                receipt[field] = original

    def test_router_import_forwarder_refuses_non_main_or_wrong_job_context_before_reads(self):
        import ci_xcode_cloud_dispatch as bridge
        api = Mock(repository="owner/repo")
        env = {"GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "workflow_dispatch",
               "GITHUB_WORKFLOW_REF": "owner/repo/" + cloud.ROUTE_PATH + "@refs/heads/main", "GITHUB_JOB": "dispatch-import"}
        for field, value in (("GITHUB_REF", "refs/heads/candidate"), ("GITHUB_EVENT_NAME", "pull_request"),
                             ("GITHUB_WORKFLOW_REF", "owner/repo/" + cloud.ROUTE_PATH + "@refs/heads/candidate"),
                             ("GITHUB_JOB", "start")):
            with self.subTest(field=field), self.assertRaises(ContractError):
                bridge.forward_import(api, dict(env, **{field: value}), {})
            api.repo.assert_not_called()
            api.dispatch.assert_not_called()

    def test_import_waits_for_router_finalization_without_accepting_refused_provenance(self):
        import ci_xcode_cloud_import as importer
        fixture = CloudEvidenceTests()
        fixture.setUp()
        api = Mock()
        with patch.object(importer, "trusted_artifact", side_effect=[ContractError("uploader still running"), (fixture.route, 55)]) as read:
            sleep = Mock()
            self.assertEqual(importer.completed_route(api, fixture.run, sleep=sleep, monotonic=lambda: 0), (fixture.route, 55))
            sleep.assert_called_once_with(5)
            self.assertEqual(read.call_count, 2)
        with patch.object(importer, "trusted_artifact", side_effect=ContractError("untrusted or failed uploader")), \
                self.assertRaises(ContractError):
            importer.completed_route(api, fixture.run, sleep=Mock(), monotonic=Mock(side_effect=[0, 121]))

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
