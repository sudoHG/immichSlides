"""Recorded GitHub payload seams guard trusted publication races and provenance."""

import copy
import hashlib
import json
import tempfile
import unittest
import os
import zlib
from unittest.mock import patch

from ci_summary import ContractError
from ci_publish import (admission_identity, approval_context, approval_plan, authoritative_run,
                        check_credential_context, match_producer, publication_plan, verify_workflow,
                        producer_evidence, record_approval, write_publication, ArtifactRedirect, mint_app, approved_status)
from ci_publish_git import derive_record, base_reader, BASE_MODULES, OPTIONAL_BASE_MODULES, evaluate_records
from pathlib import Path
from test_ci_summary import valid_summary
from ci_summary import observation, test_identity
from ci_publish import trusted_admissions, compute, prior_mismatch, map_pr
from ci_publish_git import workflow_contract
from ci_ui_shards import parse_shard_manifest, shard_populations

UI_MANIFEST = {"schema_version": 1, "revision": "iphone-v1", "default_shard": "default",
               "shards": {"default": [], "visual": ["VisualUITests"]}}
UI_PLAN = {"testTargets": [{"target": {"name": "immichSlidesUITests"},
                           "skippedTests": ["EvidenceUITests", "VisualUITests/testCapture()"]}]}
FIXTURE_UI = '''jobs:
  archive:
    name: ui-archive
    steps:
      - run: python3 scripts/ci_ui_tests.py wait-archive
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: {name: 'ui-archive-${{ github.run_id }}-${{ github.run_attempt }}', path: records/summary.json}
  shards:
    name: ui-${{ matrix.device }}-${{ matrix.shard }}
    strategy: {matrix: {device: [iphone], shard: [default, visual]}}
    steps:
      - run: python3 scripts/ci_ui_tests.py run --device '${{ matrix.device }}' --shard '${{ matrix.shard }}'
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: {name: 'ui-${{ matrix.device }}-${{ matrix.shard }}-${{ github.run_id }}-${{ github.run_attempt }}', path: records/summary.json}
'''

FIXTURE_GATE = '''jobs:
  host:
    name: host-checks
    steps:
      - run: python3 scripts/run_host_checks.py
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: {name: 'host-summary-${{ github.run_id }}-${{ github.run_attempt }}', path: records/summary.json}
  ios:
    name: build-ios
    steps:
      - run: python3 scripts/ci_build_archive.py build --platform ios
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: {name: 'build-ios-records-${{ github.run_id }}-${{ github.run_attempt }}', path: records/summary.json}
  tvos:
    name: build-tvos
    steps:
      - run: python3 scripts/ci_build_archive.py build --platform tvos
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: {name: 'build-tvos-records-${{ github.run_id }}-${{ github.run_attempt }}', path: records/summary.json}
  relocation:
    name: archive-relocation-${{ matrix.platform }}
    strategy: {matrix: {platform: [ios, tvos]}}
    steps:
      - run: python3 scripts/ci_build_archive.py preflight --platform '${{ matrix.platform }}'
      - run: python3 scripts/ci_build_archive.py proof
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: {name: 'relocation-${{ matrix.platform }}-${{ github.run_id }}-${{ github.run_attempt }}', path: records/summary.json}
'''

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

# Actual jobs returned by attempts 2 and 3 of run 37700479666. Attempt 3
# regenerates IDs for retained jobs, without changing their execution identity.
RERUN_JOBS = {
    1: [
        {"id": 113062461508, "name": "host-checks", "started_at": "2026-10-07T23:08:16Z", "completed_at": "2026-10-07T23:13:14Z", "runner_id": 1000001225},
        {"id": 113062461842, "name": "build-tvos", "started_at": "2026-10-07T23:08:14Z", "completed_at": "2026-10-07T23:12:09Z", "runner_id": 1000001226},
        {"id": 113062461846, "name": "build-ios", "started_at": "2026-10-07T23:08:26Z", "completed_at": "2026-10-07T23:11:54Z", "runner_id": 1000001227},
        {"id": 113063754841, "name": "archive-relocation-ios", "started_at": "2026-10-07T23:12:19Z", "completed_at": "2026-10-07T23:17:49Z", "runner_id": 1000001230},
        {"id": 113063754874, "name": "archive-relocation-tvos", "started_at": "2026-10-07T23:12:19Z", "completed_at": "2026-10-07T23:14:54Z", "runner_id": 1000001229},
    ],
    2: [
        {"id": 113066370190, "name": "build-ios", "started_at": "2026-10-07T23:20:24Z", "completed_at": "2026-10-07T23:24:54Z", "runner_id": 1000001231},
        {"id": 113066370383, "name": "host-checks", "started_at": "2026-10-07T23:20:28Z", "completed_at": "2026-10-07T23:25:23Z", "runner_id": 1000001232},
        {"id": 113066370438, "name": "build-tvos", "started_at": "2026-10-07T23:20:24Z", "completed_at": "2026-10-07T23:24:07Z", "runner_id": 1000001233},
        {"id": 113067827414, "name": "archive-relocation-ios", "started_at": "2026-10-07T23:25:03Z", "completed_at": "2026-10-07T23:29:32Z", "runner_id": 1000001235},
        {"id": 113067827509, "name": "archive-relocation-tvos", "started_at": "2026-10-07T23:25:00Z", "completed_at": "2026-10-07T23:26:35Z", "runner_id": 1000001236},
    ],
    3: [
        {"id": 113069595741, "name": "archive-relocation-tvos", "started_at": "2026-10-07T23:30:43Z", "completed_at": "2026-10-07T23:32:20Z", "runner_id": 1000001237},
        {"id": 113069596171, "name": "host-checks", "started_at": "2026-10-07T23:20:28Z", "completed_at": "2026-10-07T23:25:23Z", "runner_id": 1000001232},
        {"id": 113069596674, "name": "build-ios", "started_at": "2026-10-07T23:20:24Z", "completed_at": "2026-10-07T23:24:54Z", "runner_id": 1000001231},
        {"id": 113069597028, "name": "build-tvos", "started_at": "2026-10-07T23:20:24Z", "completed_at": "2026-10-07T23:24:07Z", "runner_id": 1000001233},
        {"id": 113069597081, "name": "archive-relocation-ios", "started_at": "2026-10-07T23:25:03Z", "completed_at": "2026-10-07T23:29:32Z", "runner_id": 1000001235},
    ],
}


def gate_fixture(*, units):
    identity = admission_identity(REPOSITORY, RUN, PR, COMMIT)
    population = {"host": [test_identity("host", "format")]}
    for platform in ("ios", "tvos"):
        population["unit-" + platform] = [test_identity("swift", "Tests/unit", platform=platform)]
        population["ui-" + platform] = [test_identity("ui", "UITests/testUI", platform=platform)]
    operations = {name: {platform: [test_identity("host", name, platform=platform, configuration="Debug")]
                         for platform in ("ios", "tvos")} for name in ("run_build", "run_proof")}
    source = FIXTURE_GATE
    if units:
        for platform in ("ios", "tvos"):
            source += f'''  consumer-{platform}:
    name: renamed-unit-{platform}
    steps:
      - run: python3 scripts/ci_unit_tests.py run --platform {platform}
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: {{name: 'unit-{platform}-${{{{ github.run_id }}}}-${{{{ github.run_attempt }}}}', path: records/summary.json}}
'''
    policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
    record = {"identity": identity, "reader_revision": BASE, "populations": population, "base_populations": population,
              "operational_populations": operations, "classification": {"ci_changing": False, "app_affected": True},
              "base_policy": policy, "candidate_policy": policy, "workflows": {RUN["path"]: {"base": source, "candidate": source}}}
    names, _, _, metadata = workflow_contract(source, RUN, metadata=True)
    jobs = [dict(name=name, status="completed", conclusion="success", evidence_attempt=1) for name in names]
    summaries = []
    for meta in metadata.values():
        summary = valid_summary()
        summary["identity"] = identity
        summary["source"] = {"repository": REPOSITORY, "workflow_path": RUN["path"], "event": "pull_request",
                             "fork_originated": False, "ci_changing": False}
        summary["run"].update(id=str(RUN["id"]), tier=meta["tier"], job=meta["job"], shard=meta["shard"])
        expected = operations[meta["population"]][meta["shard"]] if meta["tier"] == "build" else population[meta["population"]]
        summary["population"].update(declared=expected, compiled=expected, observed=[observation(value, "passed", 0) for value in expected])
        summaries.append(summary)
    return record, jobs, summaries


class PublisherTests(unittest.TestCase):
    def test_failed_publication_summary_keeps_source_and_approval_basis(self):
        source = {"repository": REPOSITORY, "workflow_path": RUN["path"], "event": "pull_request",
                  "run_id": RUN["id"], "attempt": 1, "fork_originated": True,
                  "ci_changing": True, "approval_based": True}
        plan = {"ci-pr-gate": {"state": "failure", "description": "Authoritative producer failed",
                               "report_source": source}}
        api = type("API", (), {"repository": REPOSITORY, "status": lambda *args: None})()
        with tempfile.TemporaryDirectory() as temporary:
            summary = Path(temporary) / "summary.md"
            with patch("ci_publish.compute", return_value=(HEAD, plan, None)), patch.dict(
                    os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
                write_publication(api, api, None, HEAD, "generic-app[bot]")
            rendered = summary.read_text()
        self.assertIn("approval-based: True", rendered)
        self.assertIn("fork-originated: True", rendered)
        self.assertIn("pull_request", rendered)
    def test_ui_reuse_requires_complete_plain_pr_verdict_and_identical_inputs(self):
        from ci_ui_reuse import validate_reuse
        push = {"schema_version": 1, "repository": REPOSITORY, "event": "push", "ref": "refs/heads/main",
                "pushed_sha": MERGE, "tree_sha": TREE}
        inputs = {"manifest": "a" * 64, "policy": "b" * 64, "pins": "c" * 64}
        shards = sorted(["iphone/default", "ipad/default", "appletv/default"])
        receipt = {"schema_version": 1, "identity": admission_identity(REPOSITORY, RUN, PR, COMMIT),
                   "source": {"repository": REPOSITORY, "workflow_path": ".github/workflows/ci-ui.yml",
                              "run_id": RUN["id"], "attempt": 1, "fork_originated": False,
                              "ci_changing": False, "approval_based": False},
                   "status": "passed", "inputs": inputs, "device_shards": shards,
                   "toolchains": {name: {"versions": {"xcode": "27.0 (27A266a)", "python": "3.9.6",
                                                          "pillow": "11.3.0", "zstd": "zstd 1.5.7"},
                                            "signing_mode": "not-applicable"} for name in shards}}
        pins = json.loads(Path(__file__).with_name("ci-pins.json").read_text())
        ui_run = dict(RUN, path=".github/workflows/ci-ui.yml")
        validate_reuse(receipt, push, inputs, shards, pins, ui_run, PR)
        mutations = [lambda r: r.update(schema_version=2), lambda r: r.update(status="failed"),
                     lambda r: r["identity"].update(tree_sha="e" * 40),
                     lambda r: r["identity"].update(pull_request=8),
                     lambda r: r["source"].update(fork_originated=True),
                     lambda r: r["source"].update(ci_changing=True),
                     lambda r: r["source"].update(approval_based=True),
                     lambda r: r["inputs"].update(policy="f" * 64),
                     lambda r: r["inputs"].update(manifest="f" * 64),
                     lambda r: r["inputs"].update(pins="f" * 64),
                     lambda r: r["device_shards"].pop(),
                     lambda r: r["toolchains"].pop("ipad/default"),
                     lambda r: r["toolchains"]["ipad/default"]["versions"].update(xcode="26.0 (other)")]
        # Wrong nested types must be contract failures, never attribute errors
        # escaping the conservative reuse fallback.
        mutations += [lambda r: r.update(identity=[]), lambda r: r.update(identity=json.dumps(r["identity"])),
                      lambda r: r.update(source=[]),
                      lambda r: r.update(inputs=[]), lambda r: r.update(device_shards={}),
                      lambda r: r.update(toolchains=list(shards)),
                      lambda r: r["source"].update(run_id=True),
                      lambda r: r["toolchains"].update({"ipad/default": []}),
                      lambda r: r["toolchains"]["ipad/default"].update(versions=[]),
                      lambda r: r["toolchains"]["ipad/default"].update(signing_mode=[]),
                      lambda r: r["toolchains"]["ipad/default"]["versions"].update(zstd=[])]
        for mutate in mutations:
            bad = copy.deepcopy(receipt)
            mutate(bad)
            with self.subTest(mutate=mutate), self.assertRaises(ContractError):
                validate_reuse(bad, push, inputs, shards, pins, ui_run, PR)
        for change in ({"conclusion": "failure"}, {"conclusion": "cancelled"},
                       {"status": "in_progress"}, {"run_attempt": 2}, {"id": 102},
                       {"head_repository": {"full_name": "fork/photos"}}):
            with self.subTest(change=change), self.assertRaises(ContractError):
                validate_reuse(receipt, push, inputs, shards, pins, dict(ui_run, **change), PR)
        # Another green head can have the same tree and all the same inputs.
        # It still cannot authorize skipping for the PR head actually merged.
        previous = copy.deepcopy(receipt)
        previous["identity"]["head_sha"] = "f" * 40
        with self.assertRaises(ContractError):
            validate_reuse(previous, push, inputs, shards, pins, dict(ui_run, head_sha="f" * 40), PR)
        from ci_ui_reuse import find_reuse
        import zipfile
        merged_prs = [dict(PR, merge_commit_sha=MERGE, merged_at="2026-10-08T15:03:00Z")]
        artifact = {"id": 22, "name": "ci-ui-verdict-" + TREE, "expired": False, "workflow_run": {"id": 201}}
        class RecordedAPI:
            repository = REPOSITORY
            def repo(self, path, **kwargs):
                return {"id": 43 if "ci-publish" in path else 42,
                        "path": ".github/workflows/ci-publish.yml" if "ci-publish" in path else ui_run["path"]}
            def pages(self, path, *args, **kwargs):
                if path == f"commits/{MERGE}/pulls":
                    return merged_prs
                return [artifact] if path == "actions/artifacts" else [ui_run]
        with patch("ci_ui_reuse.reuse_inputs", return_value=inputs), \
                patch("ci_ui_reuse.read_blob", return_value=json.dumps(pins)), \
                patch("ci_ui_reuse.device_shards", return_value=shards), \
                patch("ci_ui_reuse.git"), patch("ci_ui_reuse.trusted_uploader"), \
                patch("ci_publish.json_member", return_value=receipt) as member:
            self.assertEqual(find_reuse(RecordedAPI(), push)["artifact_id"], 22)
            for matches in ([], merged_prs * 2,
                            [dict(merged_prs[0], merge_commit_sha="f" * 40)],
                            [dict(merged_prs[0], head=dict(PR["head"], sha="f" * 40))],
                            [dict(merged_prs[0], head=dict(PR["head"], repo={"full_name": "fork/photos"}))]):
                original, merged_prs = merged_prs, matches
                with self.subTest(merged=matches):
                    self.assertIsNone(find_reuse(RecordedAPI(), push))
                merged_prs = original
            for mutate in mutations:
                bad = copy.deepcopy(receipt)
                mutate(bad)
                member.return_value = bad
                with self.subTest(malformed=bad):
                    self.assertIsNone(find_reuse(RecordedAPI(), push))
            for error in (zipfile.BadZipFile("corrupt receipt"), zlib.error("invalid compressed data")):
                member.side_effect = error
                self.assertIsNone(find_reuse(RecordedAPI(), push))
                with patch.object(RecordedAPI, "pages", side_effect=error):
                    self.assertIsNone(find_reuse(RecordedAPI(), push))

    def test_ui_rerun_normalizes_each_attempt_before_merging_shard_history(self):
        run = dict(RUN, event="push", head_branch="main", path=".github/workflows/ci-ui.yml", run_attempt=2)
        names, _, _, metadata = workflow_contract(FIXTURE_UI, run, metadata=True)
        def job(name, attempt, conclusion):
            return {"name": name, "status": "completed", "conclusion": conclusion,
                    "started_at": f"2026-10-08T15:0{attempt}:00Z", "completed_at": f"2026-10-08T15:0{attempt}:10Z",
                    "runner_id": 100 + attempt, "run_attempt": attempt}
        skipped = [job("ui-archive", 1, "success"),
                   job("ui-${{ matrix.device }}-${{ matrix.shard }}", 1, "skipped")]
        executed = [job(name, 1, "success") for name in names]
        def read_summary(api, artifact, filename):
            name, attempt = artifact["name"].rsplit("-", 1)
            meta = metadata[name.rsplit("-", 1)[0]]
            summary = valid_summary()
            summary["run"].update(id=str(run["id"]), attempt=int(attempt),
                                  tier=meta["tier"], job=meta["job"], shard=meta["shard"])
            return summary
        class RecordedAPI:
            def pages(self, path, collection):
                if collection == "jobs":
                    return attempts[int(path.split("/attempts/")[1].split("/")[0])]
                return [{"name": f"{name}-{run['id']}-{attempt}", "expired": False}
                        for attempt in (1, 2) for name in names]
        for first, second in ((skipped, executed), (executed, skipped)):
            # Include both full reruns and a jobs API response that retains
            # archive execution only in the earlier attempt.
            for partial in (False, True):
                latest = [job(row["name"], 2, row["conclusion"]) for row in second
                          if not partial or row["name"] != "ui-archive"]
                attempts = {1: first, 2: latest}
                with self.subTest(first=first, partial=partial), patch("ci_publish.json_member", side_effect=read_summary):
                    jobs, summaries = producer_evidence(RecordedAPI(), run, FIXTURE_UI)
                self.assertEqual({row["name"] for row in jobs}, set(names))
                self.assertEqual({row["evidence_attempt"] for row in jobs if row["name"] != "ui-archive"}, {2})
                self.assertEqual(next(row for row in jobs if row["name"] == "ui-archive")["evidence_attempt"],
                                 1 if partial else 2)
                self.assertEqual(len(summaries), 1 if second is skipped else len(names))
                self.assertEqual({row["conclusion"] for row in jobs if row["name"] != "ui-archive"},
                                 {"skipped" if second is skipped else "success"})
        attempts = {1: executed, 2: skipped + [executed[1]]}
        with patch("ci_publish.json_member", side_effect=read_summary), self.assertRaises(ContractError):
            producer_evidence(RecordedAPI(), run, FIXTURE_UI)

    def test_ui_skipped_shards_need_independent_trusted_reuse_proof(self):
        from ci_ui_reuse import evaluate_reused_push
        from types import SimpleNamespace
        api = SimpleNamespace(repository=REPOSITORY)
        push = {"schema_version": 1, "repository": REPOSITORY, "event": "push", "ref": "refs/heads/main",
                "pushed_sha": MERGE, "tree_sha": TREE}
        run = dict(RUN, event="push", head_branch="main", path=".github/workflows/ci-ui.yml")
        manifest_hash = "e" * 64
        record = {"identity": push, "workflows": {run["path"]: {"base": FIXTURE_UI}},
                  "ui_inputs": {"base": {"manifest_sha256": manifest_hash}}}
        names, _, _, metadata = workflow_contract(FIXTURE_UI, run, metadata=True)
        jobs = [{"name": name, "status": "completed", "conclusion": "success" if name == "ui-archive" else "skipped"}
                for name in names]
        summary = valid_summary()
        expected = [test_identity("host", "UI archive selection")]
        summary.update(identity=push, status="passed", infrastructure=[])
        summary["source"].update(repository=REPOSITORY, event="push", workflow_path=run["path"], fork_originated=False)
        summary["run"].update(id=str(run["id"]), tier="ui-infrastructure", job="ui-archive", shard=None)
        summary["hashes"]["manifests"] = {"ui-shards": manifest_hash}
        summary["population"].update(declared=expected, compiled=expected, deselected=[],
                                     observed=[observation(expected[0], "passed", 0)])
        receipt = {"source": {"run_id": 101, "attempt": 1, "approval_based": False,
                              "fork_originated": False, "ci_changing": False},
                   "artifact_id": 22, "identity": {"tree_sha": TREE}}
        with patch("ci_ui_reuse.find_reuse", return_value=receipt):
            self.assertEqual(evaluate_reused_push(api, record, run, jobs, [summary])["state"], "success")
            # Actual jobs API payload from run 37797617602: a skipped whole
            # matrix is one unexpanded job, rather than one row per shard.
            collapsed = [
                {"id": 113381069593, "name": "ui-archive", "status": "completed", "conclusion": "success",
                 "started_at": "2026-10-08T15:03:47Z", "completed_at": "2026-10-08T15:03:57Z", "run_attempt": 1},
                {"id": 113381171846, "name": "ui-${{ matrix.device }}-${{ matrix.shard }}", "status": "completed",
                 "conclusion": "skipped", "started_at": "2026-10-08T15:03:58Z",
                 "completed_at": "2026-10-08T15:03:57Z", "run_attempt": 1}]
            class RecordedAPI:
                def pages(self, path, collection):
                    if collection == "jobs":
                        return collapsed
                    return [{"name": f"ui-archive-{run['id']}-1", "expired": False}]
            with patch("ci_publish.json_member", return_value=summary):
                mapped, records = producer_evidence(RecordedAPI(), run, FIXTURE_UI)
            self.assertEqual({job["name"] for job in mapped}, set(names))
            self.assertEqual({job["id"] for job in mapped if job["conclusion"] == "skipped"}, {113381171846})
            self.assertEqual(evaluate_reused_push(api, record, run, collapsed, records)["state"], "success")
            reused = evaluate_reused_push(api, record, run, collapsed, records)
            self.assertNotIn("source", reused)
            with tempfile.TemporaryDirectory() as directory, \
                    patch("ci_publish.compute", return_value=(MERGE, {"ci-ui": reused}, None)), \
                    patch("ci_publish.os.environ", {"GITHUB_STEP_SUMMARY": directory + "/summary.md"}), \
                    patch.object(api, "status", create=True):
                write_publication(api, api, 0, MERGE, "generic-app[bot]")
                rendered = Path(directory, "summary.md").read_text()
                self.assertIn("Reuse: producer run 101, attempt 1; verdict artifact 22; tree " + TREE, rendered)
                self.assertIn("approval-based: False, fork-originated: False, CI-changing: False", rendered)
            for bad in (collapsed + [jobs[1]], collapsed[:1],
                        [collapsed[0], dict(collapsed[1], conclusion="success")],
                        [dict(collapsed[0], conclusion="skipped"), collapsed[1]],
                        [collapsed[0], dict(collapsed[1], name="ui-${{ matrix.other }}")]):
                with self.subTest(jobs=bad), self.assertRaises(ContractError):
                    evaluate_reused_push(api, record, run, bad, [summary])
            for mutate in (lambda j, s: j[0].update(conclusion="skipped"),
                           lambda j, s: j[1].update(conclusion="cancelled"),
                           lambda j, s: j[1].update(conclusion="success"),
                           lambda j, s: s["population"].update(compiled=[]),
                           lambda j, s: s["population"]["observed"][0].update(outcome="failed"),
                           lambda j, s: s["source"].update(workflow_path=".github/workflows/other.yml"),
                           lambda j, s: s["hashes"]["manifests"].update({"ui-shards": "f" * 64})):
                bad_jobs, bad_summary = copy.deepcopy(jobs), copy.deepcopy(summary)
                mutate(bad_jobs, bad_summary)
                with self.subTest(mutate=mutate), self.assertRaises(ContractError):
                    evaluate_reused_push(api, record, run, bad_jobs, [bad_summary])
        with patch("ci_ui_reuse.find_reuse", return_value=None), self.assertRaises(ContractError):
            evaluate_reused_push(api, record, run, jobs, [summary])
        with patch("ci_ui_reuse.find_reuse", return_value=None), self.assertRaises(ContractError):
            evaluate_reused_push(api, record, run, collapsed, [summary])

    def test_ui_verdict_artifact_must_come_from_main_publisher_history(self):
        from ci_ui_reuse import trusted_uploader
        from types import SimpleNamespace
        workflow = {"id": 43, "path": ".github/workflows/ci-publish.yml"}
        artifact = {"workflow_run": {"id": 201}}
        uploader = dict(RUN, id=201, workflow_id=43, path=workflow["path"], event="workflow_run", head_branch="main")
        class RecordedAPI:
            repository = REPOSITORY
            def repo(self, path):
                return uploader
        with patch("ci_ui_reuse.subprocess.run", return_value=SimpleNamespace(returncode=0)):
            trusted_uploader(RecordedAPI(), artifact, workflow)
            for change in ({"workflow_id": 42}, {"path": ".github/workflows/ci-ui.yml"},
                           {"head_branch": "feature"}, {"event": "pull_request"},
                           {"head_repository": {"full_name": "fork/photos"}}):
                original = copy.deepcopy(uploader)
                uploader.update(change)
                with self.subTest(change=change), self.assertRaises(ContractError):
                    trusted_uploader(RecordedAPI(), artifact, workflow)
                uploader = original
        with patch("ci_ui_reuse.subprocess.run", return_value=SimpleNamespace(returncode=1)), self.assertRaises(ContractError):
            trusted_uploader(RecordedAPI(), artifact, workflow)

    def test_shards_put_new_classes_in_default_and_partition_the_default_plan(self):
        declared = [test_identity("ui", key, platform="ios") for key in
                    ("NewUITests/testNew", "VisualUITests/testFlow", "VisualUITests/testCapture",
                     "EvidenceUITests/testRecord")]
        actual = shard_populations(declared, UI_PLAN, UI_MANIFEST, "iphone")
        self.assertEqual(actual, {
            "default": [test_identity("ui", "NewUITests/testNew", platform="ios", device="iphone")],
            "visual": [test_identity("ui", "VisualUITests/testFlow", platform="ios", device="iphone")]})
        for bad in (dict(UI_MANIFEST, schema_version=2), dict(UI_MANIFEST, default_shard="missing"),
                    dict(UI_MANIFEST, shards={"default": ["VisualUITests"], "visual": ["VisualUITests"]}),
                    dict(UI_MANIFEST, shards={"default": [], "visual": ["VisualUITests/testFlow"]}),
                    dict(UI_MANIFEST, unexpected=True)):
            with self.subTest(bad=bad), self.assertRaises(ContractError):
                parse_shard_manifest(bad)
        for bad in (declared + declared[:1], [test_identity("ui", "VisualUITests/testFlow", platform="tvos")]):
            with self.subTest(bad=bad), self.assertRaises(ContractError):
                shard_populations(bad, UI_PLAN, UI_MANIFEST, "iphone")
        with self.assertRaisesRegex(ContractError, "shard visual has no tests on iphone; update scripts/ci-ui-shards.json"):
            shard_populations(declared[:1], UI_PLAN, UI_MANIFEST, "iphone")

    def test_ui_workflow_binds_literal_device_and_shard_to_each_uploading_job(self):
        names, _, _, metadata = workflow_contract(FIXTURE_UI, RUN, metadata=True)
        self.assertEqual(names, ["ui-archive", "ui-iphone-default", "ui-iphone-visual"])
        self.assertEqual(metadata["ui-archive"], {"tier": "ui-infrastructure", "job": "ui-archive",
                                               "shard": None, "population": "ui-archive"})
        self.assertEqual(metadata["ui-iphone-visual"], {"tier": "ui", "job": "ui-iphone", "shard": "visual",
                                                      "population": "ui-ios", "device": "iphone"})
        for source in (FIXTURE_UI.replace("[iphone]", "[unknown]"),
                       FIXTURE_UI.replace("--shard '${{ matrix.shard }}'", ""),
                       FIXTURE_UI.replace("--device '${{ matrix.device }}'", "--device '$DEVICE'")):
            with self.subTest(source=source), self.assertRaises(ContractError):
                workflow_contract(source, RUN, metadata=True)

    def test_ui_reader_requires_device_population_union_and_admitted_manifest_hash(self):
        from ci_publish_git import ui_inputs
        from test_ci_verdict import approval_record
        identity = admission_identity(REPOSITORY, RUN, PR, COMMIT)
        population = [test_identity("ui", key, platform="ios") for key in
                      ("NewUITests/testNew", "VisualUITests/testFlow", "EvidenceUITests/testRecord")]
        files = {"scripts/ci-ui-shards.json": json.dumps(UI_MANIFEST),
                 "immichSlides-iOS.xctestplan": json.dumps(UI_PLAN)}
        listing = [{"path": path, "type": "blob", "mode": "100644"} for path in files]
        modules = {name: (Path(__file__).parent / name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
        with patch("ci_publish_git.read_blob", side_effect=lambda revision, path: files[path]):
            admitted = ui_inputs(MERGE, listing, populations={"ui-ios": population},
                                 base_populations={"ui-ios": population}, workflow=FIXTURE_UI, run=RUN, modules=modules)
        self.assertEqual(admitted["populations"]["iphone"], shard_populations(population, UI_PLAN, UI_MANIFEST, "iphone"))
        with patch("ci_publish_git.read_blob", side_effect=lambda revision, path: files[path]):
            empty = ui_inputs(MERGE, listing, populations={"ui-ios": population[:1]},
                              base_populations={"ui-ios": population}, workflow=FIXTURE_UI, run=RUN, modules=modules)
        self.assertEqual(empty["error"], "shard visual has no tests on iphone; update scripts/ci-ui-shards.json")
        self.assertEqual(empty["base_populations"], admitted["base_populations"])
        record = {"identity": identity, "populations": {"ui-ios": population},
                  "base_populations": {"ui-ios": population}, "ui_inputs": {"base": admitted, "candidate": admitted},
                  "workflows": {".github/workflows/ci-ui.yml": {"base": FIXTURE_UI, "candidate": FIXTURE_UI}},
                  "base_policy": {"schema_version": 1, "approval_records": [approval_record("ui")],
                                  "expected_skips": [], "deselections": []},
                  "classification": {"app_affected": True, "ci_changing": False}}
        record["candidate_policy"] = record["base_policy"]
        run = dict(RUN, path=".github/workflows/ci-ui.yml", run_started_at="2026-10-08T10:00:00Z")
        names, _, _, metadata = workflow_contract(FIXTURE_UI, run, metadata=True)
        shards = shard_populations(population, UI_PLAN, UI_MANIFEST, "iphone")
        jobs = [{"name": name, "status": "completed", "conclusion": "success", "evidence_attempt": 1} for name in names]
        summaries = []
        for name in names:
            meta = metadata[name]
            expected = ([test_identity("host", "UI archive selection")] if name == "ui-archive" else shards[meta["shard"]])
            summary = valid_summary()
            summary.update(identity=identity, status="passed")
            summary["source"].update(repository=REPOSITORY, event="pull_request", workflow_path=run["path"], fork_originated=False)
            summary["run"] = {"id": str(RUN["id"]), "attempt": 1, **{key: meta[key] for key in ("tier", "job", "shard")}}
            summary["hashes"]["manifests"] = {"ui-shards": hashlib.sha256(files["scripts/ci-ui-shards.json"].encode()).hexdigest()}
            if name != "ui-archive":
                summary["hashes"]["manifests"]["test-plan"] = hashlib.sha256(files["immichSlides-iOS.xctestplan"].encode()).hexdigest()
            summary["population"].update(declared=expected, compiled=expected,
                                         observed=[observation(entry, "passed", 0) for entry in expected],
                                         deselected=[], removed_by_pr=[])
            summaries.append(summary)
        from ci_flaky import ASSERTION_FAILURE, merge_retry
        from test_ci_flaky import registry
        record["base_registry"] = json.loads(Path(__file__).with_name("ci-known-flaky.json").read_text())
        entry = registry()["entries"][0]
        entry["identity"] = test_identity("ui", "NewUITests/testNew", platform="ios")
        record["base_registry"]["entries"].append(entry)
        with patch("ci_publish_git.trusted_reader", return_value=modules):
            self.assertEqual(evaluate_records(record, run, jobs, summaries, approved=False, fork=False)["state"], "success")
            retried = copy.deepcopy(summaries)
            retried[1]["population"]["observed"] = [merge_retry(
                observation(shards["default"][0], "failed", 1, reason=ASSERTION_FAILURE, exit_code=65),
                observation(shards["default"][0], "passed", 1))]
            self.assertEqual(evaluate_records(record, run, jobs, retried, approved=False, fork=False)["state"], "success")
            entry["review_by"] = "2026-10-07"
            self.assertEqual(evaluate_records(record, run, jobs, retried, approved=False, fork=False)["state"], "failure")
            entry["review_by"] = "2026-10-28"
            # Admission contains the exact population; late publication does not
            # recalculate it using the publisher's current shard implementation.
            with patch("ci_publish_git.shard_populations", side_effect=AssertionError("late re-derivation")):
                self.assertEqual(evaluate_records(record, run, jobs, summaries, approved=False, fork=False)["state"], "success")
            skipped = copy.deepcopy(summaries)
            skipped[1]["population"]["observed"] = [observation(shards["default"][0], "skipped", 0, reason="device prerequisite")]
            record["base_policy"]["expected_skips"] = [{"kind": "ui", "key_pattern": "NewUITests/testNew",
                "dimensions": {"platform": "ios", "device": "iphone"}, "tier": "ui", "environment": "fixture",
                "reason": "device prerequisite"}]
            self.assertEqual(evaluate_records(record, run, jobs, skipped, approved=False, fork=False)["state"], "success")
            record["base_policy"]["expected_skips"] = []
            for mutate in (lambda rows: rows[1]["hashes"]["manifests"].update({"ui-shards": "f" * 64}),
                           lambda rows: rows[1]["hashes"]["manifests"].pop("test-plan"),
                           lambda rows: rows[1]["population"].update(compiled=[]),
                           lambda rows: rows[1]["population"]["declared"][0]["dimensions"].update(device="ipad")):
                bad = copy.deepcopy(summaries)
                mutate(bad)
                with self.subTest(mutate=mutate):
                    try:
                        result = evaluate_records(record, run, jobs, bad, approved=False, fork=False)
                    except ContractError:
                        continue
                    self.assertEqual(result["state"], "failure")
            incomplete = FIXTURE_UI.replace("[default, visual]", "[visual]")
            record["workflows"][run["path"]]["base"] = incomplete
            with self.assertRaises(ContractError):
                evaluate_records(record, run, [jobs[0], jobs[2]], [summaries[0], summaries[2]], approved=False, fork=False)

    def test_fixture_device_observations_use_only_the_matching_hermetic_base_registry(self):
        from datetime import date
        from ci_flaky import eligible_entry
        from test_ci_flaky import registry
        base = registry()
        identity = dict(base["entries"][0]["identity"], dimensions={"platform": "ios", "device": "iphone"})
        self.assertIsNotNone(eligible_entry(base, identity, tier="ui", environment="fixture", today=date(2026, 10, 8)))
        for bad, environment, today in (
                (dict(identity, key="ExampleTests/testUnlisted"), "fixture", date(2026, 10, 8)),
                (dict(identity, dimensions={"platform": "ios", "device": "appletv"}), "fixture", date(2026, 10, 8)),
                (identity, "live", date(2026, 10, 8)), (identity, "fixture", date(2026, 11, 8))):
            with self.subTest(bad=bad, environment=environment, today=today):
                self.assertIsNone(eligible_entry(base, bad, tier="ui", environment=environment, today=today))

    def test_new_ui_workflow_is_admitted_as_candidate_metadata_without_a_base_workflow(self):
        identity = admission_identity(REPOSITORY, RUN, PR, COMMIT)
        base_tree = []
        candidate_tree = [{"path": ".github/workflows/ci-ui.yml", "mode": "100644", "type": "blob"}]
        derived = {"populations": {}, "classification": {"app_affected": True, "ci_changing": True}}
        def blob(revision, path):
            if path == ".github/workflows/ci-ui.yml":
                self.assertEqual(revision, MERGE)
                return FIXTURE_UI
            if path.endswith(".json"):
                return '{"schema_version":1}'
            if path.endswith("ci_build_archive.py"):
                return 'def run_build():\n step = test_identity("host", "secret-free build archive", configuration="Debug")\n'
            return "base reader text"
        with patch("ci_publish_git.read_blob", side_effect=blob), patch("ci_publish_git.git", return_value="workflow changed"), \
                patch("ci_publish_git.tree_inputs", side_effect=[(candidate_tree, {}), (base_tree, {})]), \
                patch("ci_publish_git.base_reader", return_value=derived):
            record = derive_record(identity, RUN)
        self.assertEqual(record["workflows"][".github/workflows/ci-ui.yml"], {"base": None, "candidate": FIXTURE_UI})
        ui_run = dict(RUN, path=".github/workflows/ci-ui.yml")
        record.update(workflow_id=ui_run["workflow_id"], workflow_path=ui_run["path"])
        class RecordedAPI:
            repository = REPOSITORY
            def repo(self, path):
                return PR
            def pages(self, path, collection=None, **filters):
                return [ui_run]
        with patch("ci_publish.workflows", return_value={"ci-ui": dict(WORKFLOW, path=ui_run["path"])}), \
                patch("ci_publish.approval_requests", return_value=[]), patch("ci_publish.approved_status", return_value=False), \
                patch("ci_publish.trusted_admissions", return_value={RUN["id"]: record}), \
                patch("ci_publish.producer_evidence", return_value=([], [])) as evidence, \
                patch("ci_publish.evaluate_records", return_value={"state": "success", "description": "verified"}) as evaluate:
            _, statuses, approval = compute(RecordedAPI(), 7, "", "generic-app[bot]")
            self.assertEqual(statuses["ci-ui"]["state"], "failure")
            self.assertEqual(statuses["ci-ui"]["description"], "workflow is absent on the base; exact-head approval required")
            self.assertEqual(approval["request"], HEAD)
            evidence.assert_not_called()
            evaluate.assert_not_called()
            with patch("ci_publish.approved_status", return_value=True):
                _, statuses, approval = compute(RecordedAPI(), 7, "", "generic-app[bot]")
            self.assertEqual(statuses["ci-ui"]["state"], "success")
            evidence.assert_called_once_with(unittest.mock.ANY, ui_run, FIXTURE_UI, diagnostics=[])
            self.assertIsNone(approval["request"])
            with patch("ci_publish.approved_status", return_value=True), patch(
                    "ci_report.summary_diagnostics", side_effect=ContractError("malformed diagnostics")):
                _, statuses, _ = compute(RecordedAPI(), 7, "", "generic-app[bot]")
            self.assertEqual("failure", statuses["ci-ui"]["state"])
            self.assertIn("diagnostics", statuses["ci-ui"])
            with patch("ci_publish.approved_status", return_value=True), patch(
                    "ci_publish.evaluate_records", side_effect=ContractError(
                        "workflow is absent on the base; exact-head approval required")):
                _, statuses, _ = compute(RecordedAPI(), 7, "", "generic-app[bot]")
            self.assertEqual(statuses["ci-ui"]["description"],
                             "workflow is absent on the base; exact-head approval required; approval-based")

        candidate_tree += [{"path": path, "mode": "100644", "type": "blob"} for path in
                           ("scripts/ci-ui-shards.json", "immichSlides-iOS.xctestplan")]
        original_blob = blob
        for invalid_path, invalid_text in (("scripts/ci-ui-shards.json", "{broken"),
                                           ("immichSlides-iOS.xctestplan", "{broken"),
                                           ("immichSlides-iOS.xctestplan", "[]"),
                                           ("immichSlides-iOS.xctestplan", "null"),
                                           (".github/workflows/ci-ui.yml", "jobs: {bad: null}"),
                                           (".github/workflows/ci-ui.yml", "[" * 1500)):
            def invalid_blob(revision, path):
                if path == invalid_path:
                    return invalid_text
                if path == ".github/workflows/ci-ui.yml":
                    return FIXTURE_UI
                if path == "scripts/ci-ui-shards.json":
                    return json.dumps(UI_MANIFEST)
                if path == "immichSlides-iOS.xctestplan":
                    return json.dumps(UI_PLAN)
                return original_blob(revision, path)
            with self.subTest(invalid_path=invalid_path), \
                    patch("ci_publish_git.read_blob", side_effect=invalid_blob), \
                    patch("ci_publish_git.git", return_value="workflow changed"), \
                    patch("ci_publish_git.tree_inputs", side_effect=[(candidate_tree, {}), (base_tree, {})]), \
                    patch("ci_publish_git.base_reader", return_value=derived):
                malformed = derive_record(identity, RUN)
                self.assertEqual(malformed["ui_inputs"]["candidate"], {"error": "candidate UI inputs are invalid"})
                self.assertEqual(malformed["classification"], derived["classification"])
            gate, gate_jobs, gate_summaries = gate_fixture(units=True)
            gate["ui_inputs"] = malformed["ui_inputs"]
            modules = {name: (Path(__file__).parent / name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
            with patch("ci_publish_git.trusted_reader", return_value=modules):
                self.assertEqual(evaluate_records(gate, RUN, gate_jobs, gate_summaries, approved=True, fork=False)["state"], "success")
            malformed.update(identity=identity, workflow_id=ui_run["workflow_id"], workflow_path=ui_run["path"])
            with self.assertRaisesRegex(ContractError, "candidate UI inputs are invalid"):
                evaluate_records(malformed, ui_run, [dict(name=name, status="completed", conclusion="success")
                    for name in workflow_contract(FIXTURE_UI, ui_run)[0]], [], approved=True, fork=False)
            with patch("ci_publish.workflows", return_value={"ci-ui": dict(WORKFLOW, path=ui_run["path"])}), \
                    patch("ci_publish.approval_requests", return_value=[]), patch("ci_publish.approved_status", return_value=True), \
                    patch("ci_publish.trusted_admissions", return_value={RUN["id"]: malformed}), \
                    patch("ci_publish.producer_evidence", side_effect=AssertionError("invalid UI workflow must not be reparsed")):
                _, statuses, _ = compute(RecordedAPI(), 7, "", "generic-app[bot]")
            self.assertEqual(statuses["ci-ui"]["description"],
                             "Missing, invalid or mismatched admitted evidence; approval-based")
            with patch("ci_publish_git.read_blob", side_effect=invalid_blob), \
                    patch("ci_publish_git.git", return_value="workflow changed"), \
                    patch("ci_publish_git.tree_inputs", return_value=(candidate_tree, {})), \
                    patch("ci_publish_git.base_reader", return_value=derived), self.assertRaises(Exception):
                derive_record(identity, RUN)

        gate, gate_jobs, gate_summaries = gate_fixture(units=True)
        merge_population = copy.deepcopy(gate["populations"])
        merge_population["ui-ios"] = [test_identity("ui", "NewUITests/testNew", platform="ios")]
        base_population = copy.deepcopy(merge_population)
        base_population["ui-ios"].append(test_identity("ui", "VisualUITests/testFlow", platform="ios"))
        listing = candidate_tree + [{"path": RUN["path"], "mode": "100644", "type": "blob"}]
        def populated_blob(revision, path):
            if path == RUN["path"]:
                return gate["workflows"][RUN["path"]]["base"]
            if path == "scripts/ci-test-policy.json":
                return json.dumps(gate["base_policy"])
            if path == "scripts/ci_build_archive.py":
                return '\n'.join('def ' + name + '():\n step = test_identity("host", "' + name +
                                 '", configuration="Debug")' for name in ("run_build", "run_proof"))
            if path.startswith("scripts/") and path.endswith(".py"):
                return (Path(__file__).parent / Path(path).name).read_text()
            return invalid_blob(revision, path) if path != ".github/workflows/ci-ui.yml" else FIXTURE_UI
        def static_reader(modules, payload):
            if payload["operation"] == "derive":
                population = base_population if payload["sources"] else merge_population
                return {"populations": population, "classification": {"app_affected": True, "ci_changing": False}}
            return base_reader(modules, payload)
        with patch("ci_publish_git.read_blob", side_effect=populated_blob), patch("ci_publish_git.git", return_value="test renamed"), \
                patch("ci_publish_git.tree_inputs", side_effect=[(listing, {}), (listing, {"base": "source"})]), \
                patch("ci_publish_git.base_reader", side_effect=static_reader):
            empty = derive_record(identity, RUN)
        hint = "shard visual has no tests on iphone; update scripts/ci-ui-shards.json"
        self.assertEqual(empty["ui_inputs"]["base"]["error"], hint)
        gate["ui_inputs"] = empty["ui_inputs"]
        with patch("ci_publish_git.trusted_reader", return_value=modules):
            self.assertEqual(evaluate_records(gate, RUN, gate_jobs, gate_summaries, approved=False, fork=False)["state"], "success")
        empty.update(workflow_id=ui_run["workflow_id"], workflow_path=ui_run["path"])
        ui_jobs = [dict(name=name, status="completed", conclusion="success") for name in workflow_contract(FIXTURE_UI, ui_run)[0]]
        with patch("ci_publish.workflows", return_value={"ci-ui": dict(WORKFLOW, path=ui_run["path"])}), \
                patch("ci_publish.approval_requests", return_value=[]), patch("ci_publish.approved_status", return_value=False), \
                patch("ci_publish.trusted_admissions", return_value={RUN["id"]: empty}), \
                patch("ci_publish.producer_evidence", return_value=(ui_jobs, [])):
            _, statuses, _ = compute(RecordedAPI(), 7, "", "generic-app[bot]")
        self.assertEqual(statuses["ci-ui"], {"state": "failure", "description": hint,
                         "target_url": "https://github.com/" + REPOSITORY + "/actions/runs/101",
                         "diagnostics": {"counts": {}, "failures": [], "missing": [], "infrastructure": [],
                                         "skipped": [], "deselected": []},
                         "report_source": {"repository": REPOSITORY, "workflow_path": ui_run["path"], "event": "pull_request",
                                           "run_id": RUN["id"], "attempt": RUN["run_attempt"],
                                           "fork_originated": False, "ci_changing": False, "approval_based": False}})

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
        self.assertEqual(match_producer(identity, identity), None)
        for field in ("base_sha", "merge_sha", "tree_sha", "head_sha"):
            with self.subTest(field=field):
                forged = dict(identity, **{field: "e" * 40})
                self.assertIn("base moved; push again or update the branch", match_producer(forged, identity))
                self.assertNotIn("repeated", match_producer(forged, identity))
                self.assertIn("repeated", match_producer(forged, identity, previous_mismatch=True))

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

    def test_complete_gate_requires_both_unit_populations_and_refuses_host_impersonation(self):
        modules = {name: (Path(__file__).parent / name).read_text() for name in BASE_MODULES}
        dependency = Path(__file__).parent / "ci_flaky.py"
        if dependency.exists():
            modules[dependency.name] = dependency.read_text()
        with patch("ci_publish_git.trusted_reader", return_value=modules):
            record, jobs, summaries = gate_fixture(units=False)
            self.assertEqual(evaluate_records(record, RUN, jobs, summaries, approved=False, fork=False),
                             {"state": "pending", "description": "unit tier not yet produced"})
            record, jobs, summaries = gate_fixture(units=True)
            self.assertEqual(evaluate_records(record, RUN, jobs, summaries, approved=False, fork=False)["state"], "success")
            units = [summary for summary in summaries if summary["run"]["tier"] == "unit"]
            for summary in units:
                static = summary["population"]["declared"][0]
                owner, _, function = static["key"].rpartition("/")
                compiled = dict(static, key="immichSlidesTests/" + owner + "/`" + function + "`(value:)")
                parameter = dict(compiled, dimensions={**compiled["dimensions"], "parameter": "argument:1"})
                summary["population"].update(compiled=[compiled], observed=[observation(value, "passed", 0)
                                                                           for value in (compiled, parameter)])
            self.assertEqual(evaluate_records(record, RUN, jobs, summaries, approved=False, fork=False)["state"], "success")
            for case in ("missing declaration", "failed parameter", "duplicate parameter", "unknown parent"):
                changed = copy.deepcopy(summaries)
                unit = next(summary for summary in changed if summary["run"]["tier"] == "unit")
                rows = unit["population"]["observed"]
                if case == "missing declaration":
                    unit["population"]["declared"] = []
                elif case == "failed parameter":
                    rows[1] = observation(rows[1]["identity"], "failed", 0, message="Expectation failed")
                elif case == "duplicate parameter":
                    rows.append(copy.deepcopy(rows[1]))
                else:
                    rows[1]["identity"]["key"] = "immichSlidesTests/Unknown/`works`(value:)"
                with self.subTest(case=case):
                    self.assertEqual(evaluate_records(record, RUN, jobs, changed, approved=False, fork=False)["state"], "failure")
            for summary in summaries:
                summary["run"]["tier"] = "host"
                expected = record["populations"]["host"]
                summary["population"].update(declared=expected, compiled=expected,
                                             observed=[observation(value, "passed", 0) for value in expected])
            self.assertEqual(evaluate_records(record, RUN, jobs, summaries, approved=False, fork=False)["state"], "failure")

    def test_base_reader_carries_same_revision_dependencies_and_tolerates_older_bases(self):
        from ci_publish_git import revision_modules
        modules = {name: (Path(__file__).parent / name).read_text() for name in BASE_MODULES}
        dependency = Path(__file__).parent / "ci_flaky.py"
        modules["ci_flaky.py"] = dependency.read_text() if dependency.exists() else "from ci_summary import require\n"
        # Old evaluators do not import ci_flaky; retain the dependency seam on
        # old checkouts as well as the current evaluator used by PR merge CI.
        modules["ci_verdict.py"] += "\nimport ci_flaky\n"
        def blob(revision, path):
            self.assertEqual(revision, BASE)
            return modules[path.removeprefix("scripts/")]
        with patch("ci_publish_git.git", side_effect=lambda *args: args[-1] if args[-1].endswith("ci_flaky.py") else ""), \
                patch("ci_publish_git.read_blob", side_effect=blob):
            loaded = revision_modules(BASE)
        self.assertEqual(loaded, modules)
        record, jobs, summaries = gate_fixture(units=True)
        with patch("ci_publish_git.trusted_reader", return_value=loaded):
            self.assertEqual(evaluate_records(record, RUN, jobs, summaries, approved=False, fork=False)["state"], "success")
        with patch("ci_publish_git.git", return_value=""), patch("ci_publish_git.read_blob", side_effect=blob):
            self.assertEqual(set(revision_modules(BASE)), set(BASE_MODULES))

    def test_real_workflow_contract_ignores_copied_script_names_and_binds_producer_platforms(self):
        source = (Path(__file__).parent.parent / ".github/workflows/ci-gate.yml").read_text()
        _, _, _, metadata = workflow_contract(source, RUN, metadata=True)
        builds = [meta for meta in metadata.values() if meta["population"] == "run_build"]
        self.assertEqual({meta["shard"] for meta in builds}, {"ios", "tvos"})
        proofs = [meta for meta in metadata.values() if meta["population"] == "run_proof"]
        self.assertTrue(all(meta["tier"] == "build" and meta["job"] == "archive-relocation" for meta in proofs))
        reference_only = '''jobs:
  copy:
    steps:
      - run: for file in run_host_checks.py; do cp "scripts/$file" tools/; done
      - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: {name: copied-summary, path: records/summary.json}
'''
        with self.assertRaises(ContractError):
            workflow_contract(reference_only, RUN, metadata=True)

    def test_untrusted_same_name_admissions_and_a_main_tag_cannot_poison_a_trusted_record(self):
        uploader = dict(RUN, id=500, workflow_id=201, path=".github/workflows/ci-publish.yml",
                        head_sha=BASE, head_branch="main", event="workflow_run")
        tagged = dict(uploader, id=502, head_sha=TREE, event="workflow_dispatch")
        record = {"schema_version": 1, "run_id": 101, "identity": admission_identity(REPOSITORY, RUN, PR, COMMIT)}
        legitimate = {"id": 1, "name": "ci-admission-101", "expired": False, "workflow_run": {"id": 500}}
        class RecordedAPI:
            repository = REPOSITORY
            def repo(self, path, **options):
                if path == "actions/workflows/ci-publish.yml":
                    return {"id": 201}
                if path.startswith("actions/runs/"):
                    return {500: uploader, 502: tagged, 101: RUN}[int(path.rsplit("/", 1)[1])]
                raise AssertionError(path)
            def pages(self, path, collection, **filters):
                if path != "actions/artifacts" or filters != {"name": "ci-admission-101"}:
                    raise AssertionError("Expected an exact artifact lookup")
                return [dict(legitimate, id=2, workflow_run={"id": 101}), legitimate,
                        dict(legitimate, id=3, workflow_run={"id": 502})]
        def ancestry(command, **options):
            return type("Completed", (), {"returncode": 0 if command[-2] == BASE else 1})()
        with patch("ci_publish.git"), patch("ci_publish.subprocess.run", side_effect=ancestry), \
                patch("ci_publish.json_member", return_value=record) as read:
            self.assertEqual(trusted_admissions(RecordedAPI(), [101]), {101: record})
            self.assertEqual(read.call_args.args[1]["id"], 1)
            self.assertEqual(read.call_count, 1)

    def test_admission_lookup_cost_is_independent_of_publisher_history_length(self):
        uploader = dict(RUN, id=500, workflow_id=201, path=".github/workflows/ci-publish.yml",
                        head_sha=BASE, head_branch="main", event="workflow_run")
        record = {"schema_version": 1, "run_id": 101, "identity": admission_identity(REPOSITORY, RUN, PR, COMMIT)}
        class RecordedAPI:
            repository = REPOSITORY
            def __init__(self, newer_runs):
                self.newer_runs, self.calls = newer_runs, []
            def repo(self, path, **options):
                self.calls.append(path)
                if path == "actions/workflows/ci-publish.yml":
                    return {"id": 201, "path": uploader["path"]}
                if path == "actions/runs/500":
                    return uploader
                if path == "git/ref/heads/main":
                    return {"object": {"sha": BASE}}
                if path.startswith("compare/"):
                    return {"merge_base_commit": {"sha": BASE}, "status": "identical"}
                raise AssertionError(path)
            def pages(self, path, collection, **filters):
                self.calls.append((path, collection, filters))
                if path == "actions/artifacts" and filters == {"name": "ci-admission-101"}:
                    return [{"id": 1, "name": "ci-admission-101", "expired": False, "workflow_run": {"id": 500}}]
                if path == "actions/workflows/201/runs":
                    # GitHub's workflow-run search cap excludes uploader 500
                    # when more than 1000 newer runs match the old query.
                    return [dict(uploader, id=501 + index) for index in range(min(self.newer_runs, 1000))]
                raise AssertionError(path)
        counts = []
        with patch("ci_publish.git"), patch("ci_publish.subprocess.run") as ancestry, \
                patch("ci_publish.json_member", return_value=record):
            ancestry.return_value.returncode = 0
            for newer_runs in (1001, 10000):
                api = RecordedAPI(newer_runs)
                self.assertEqual(trusted_admissions(api, [101]), {101: record})
                counts.append(len(api.calls))
                self.assertEqual(ancestry.call_args.args[0], ["git", "merge-base", "--is-ancestor", BASE, "FETCH_HEAD"])
        self.assertEqual(counts, [3, 3])

    def test_docs_only_approved_fork_is_not_applicable_and_missing_classification_stays_pending(self):
        fork = copy.deepcopy(PR)
        fork["head"]["repo"]["full_name"] = "contributor/photos"
        run = dict(RUN, status="in_progress", head_repository=fork["head"]["repo"])
        record = {"classification": {"ci_changing": False, "app_affected": False}}
        class RecordedAPI:
            repository = REPOSITORY
            def repo(self, path):
                return fork
            def pages(self, path, collection=None, **filters):
                return [run]
        with patch("ci_publish.workflows", return_value={"ci-pr-gate": WORKFLOW}), \
                patch("ci_publish.approval_requests", return_value=[]), patch("ci_publish.approved_status", return_value=True), \
                patch("ci_publish.trusted_admissions", return_value={101: record}):
            _, statuses, _ = compute(RecordedAPI(), 7, "", "generic-app[bot]")
            self.assertEqual(statuses["ci-ui"]["state"], "success")
            self.assertIn("self-reported", statuses["ci-ui"]["description"])
        fork, run = PR, RUN
        with patch("ci_publish.workflows", return_value={"ci-pr-gate": WORKFLOW}), \
                patch("ci_publish.approval_requests", return_value=[]), patch("ci_publish.approved_status", return_value=False), \
                patch("ci_publish.trusted_admissions", return_value={}):
            _, statuses, _ = compute(RecordedAPI(), 7, "", "generic-app[bot]")
            self.assertEqual(statuses["ci-approval-state"], {"state": "pending", "description": "Waiting for trusted classification"})
            with patch("ci_publish.approved_status", return_value=True):
                _, statuses, _ = compute(RecordedAPI(), 7, "", "generic-app[bot]")
                self.assertEqual(statuses["ci-approval-state"]["state"], "pending")

    def test_empty_fork_run_pr_list_uses_commit_mapping_and_refuses_stale_or_wrong_source(self):
        fork = copy.deepcopy(PR)
        fork["head"]["repo"]["full_name"] = "contributor/photos"
        fork["head"]["repo"]["owner"] = {"login": "contributor"}
        run = dict(RUN, pull_requests=[], head_repository=fork["head"]["repo"])
        class RecordedAPI:
            repository = REPOSITORY
            def __init__(self, current, *, commit_mapping=True, head_candidates=None, pagination_error=False):
                self.current, self.paths = current, []
                self.commit_mapping, self.head_candidates = commit_mapping, head_candidates
                self.pagination_error = pagination_error
            def repo(self, path):
                self.paths.append(path)
                if path == "commits/" + HEAD + "/pulls":
                    return [{"number": 7}] if self.commit_mapping else []
                return dict(self.current, number=int(path.removeprefix("pulls/")))
            def pages(self, path, collection=None, **filters):
                self.paths.append((path, filters))
                if self.pagination_error:
                    raise ContractError("GitHub pagination limit reached; publication refused")
                return [{"number": 7}] if self.head_candidates is None else self.head_candidates
        for commit_mapping in (True, False):
            with self.subTest(commit_mapping=commit_mapping):
                api = RecordedAPI(fork, commit_mapping=commit_mapping)
                self.assertEqual(map_pr(api, run), fork)
                paths = ["commits/" + HEAD + "/pulls"]
                if not commit_mapping:
                    paths.append(("pulls", {"state": "open", "base": "main", "head": "contributor:feature"}))
                self.assertEqual(api.paths, paths + ["pulls/7"])
                newer = copy.deepcopy(fork)
                newer["head"]["sha"] = "e" * 40
                with self.assertRaises(ContractError):
                    map_pr(RecordedAPI(newer, commit_mapping=commit_mapping), run)
                self.assertEqual(map_pr(RecordedAPI(newer, commit_mapping=commit_mapping), run, current=False), newer)
                for field, value in (("state", "closed"), ("head-repository", "another/photos"),
                                     ("base-ref", "other"), ("base-repository", "another/photos")):
                    with self.subTest(field=field):
                        wrong = copy.deepcopy(fork)
                        if field == "state":
                            wrong["state"] = value
                        elif field == "head-repository":
                            wrong["head"]["repo"]["full_name"] = value
                        elif field == "base-ref":
                            wrong["base"]["ref"] = value
                        else:
                            wrong["base"]["repo"]["full_name"] = value
                        with self.assertRaises(ContractError):
                            map_pr(RecordedAPI(wrong, commit_mapping=commit_mapping), run)
        for candidates in ([], [{"number": 7}, {"number": 8}]):
            with self.subTest(head_candidates=candidates), self.assertRaises(ContractError):
                map_pr(RecordedAPI(fork, commit_mapping=False, head_candidates=candidates), run)
        with self.assertRaises(ContractError):
            map_pr(RecordedAPI(fork, commit_mapping=False, pagination_error=True), run)

    def test_repeated_mismatch_requires_a_persisted_earlier_attempt_from_the_app(self):
        run = dict(RUN, run_attempt=3)
        receipt = {"context": "ci-base-mismatch/run-101/attempt-2", "state": "success", "creator": {"login": "generic-app[bot]"}}
        self.assertTrue(prior_mismatch([receipt], run, "generic-app[bot]"))
        self.assertFalse(prior_mismatch([], run, "generic-app[bot]"))
        self.assertFalse(prior_mismatch([dict(receipt, context="ci-base-mismatch/run-101/attempt-3")], run, "generic-app[bot]"))
        self.assertFalse(prior_mismatch([dict(receipt, creator={"login": "outsider"})], run, "generic-app[bot]"))
        identity = admission_identity(REPOSITORY, RUN, PR, COMMIT)
        moved = dict(identity, base_sha="e" * 40)
        self.assertNotIn("repeated", match_producer(moved, identity, previous_mismatch=prior_mismatch([], run, "generic-app[bot]")))
        self.assertIn("repeated", match_producer(moved, identity, previous_mismatch=prior_mismatch([receipt], run, "generic-app[bot]")))

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

    def test_failure_details_link_to_each_authoritative_producer(self):
        for conclusion, evaluation, needs_approval in (
                ("failure", {}, False), ("cancelled", {}, False),
                ("success", {}, False),
                ("success", {"state": "failure", "description": "Base moved; push again"}, False),
                ("success", {"state": "success", "description": "Complete"}, True)):
            with self.subTest(conclusion=conclusion, evaluation=evaluation, needs_approval=needs_approval):
                runs = {context: dict(RUN, id=run_id, conclusion=conclusion)
                        for context, run_id in (("ci-pr-gate", 101), ("ci-ui", 102))}
                plan = publication_plan(PR, runs, {101: {}, 102: {}},
                                        {context: evaluation for context in runs} if evaluation else {},
                                        approved=False, needs_approval=needs_approval)
                for context, run in runs.items():
                    self.assertEqual(plan[context]["state"], "failure")
                    self.assertEqual(plan[context]["target_url"],
                                     f"https://github.com/{REPOSITORY}/actions/runs/{run['id']}")

    def test_publisher_writing_an_old_snapshot_cannot_erase_a_concurrent_approval(self):
        class RecordedAPI:
            repository = REPOSITORY
            def __init__(self):
                self.store, self.dispatched = {}, []
            def repo(self, path):
                return PR
            def status(self, head, context, state, *args):
                self.store[context] = state
            def dispatch(self, *args):
                self.dispatched.append(args)
            def pages(self, path):
                return [{"context": key, "state": state, "creator": {"login": "generic-app[bot]"}}
                        for key, state in self.store.items()]
        api = RecordedAPI()
        def approve_during_read(*args):
            environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                           "GITHUB_REPOSITORY": REPOSITORY, "GITHUB_RUN_ID": "200", "GITHUB_ACTOR": "example",
                           "GITHUB_TRIGGERING_ACTOR": "example",
                           "GITHUB_WORKFLOW_REF": REPOSITORY + "/.github/workflows/ci-approve.yml@refs/heads/main"}
            record_approval(api, api, {"inputs": {"pull_request": "7", "head_sha": HEAD}}, environment,
                            "generic-app[bot]", ".github/workflows/ci-approve.yml")
            return HEAD, {"ci-approval-state": {"state": "pending", "description": "old read"}}, None
        with patch("ci_publish.compute", side_effect=approve_during_read), patch("ci_publish.os.environ", {}):
            write_publication(api, api, 7, "", "generic-app[bot]")
        self.assertEqual(api.store[approval_context(7, HEAD)], "success")
        self.assertEqual(len(api.dispatched), 1)

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

    def test_refusal_diagnostics_explain_contract_guards_without_printing_exception_payloads(self):
        from ci_publish import main
        for error, expected in ((ContractError("historical reader is not on main"), "historical reader is not on main"),
                                (OSError("private response body"), "OSError"),
                                (ValueError("private subprocess output"), "ValueError")):
            with self.subTest(error=type(error).__name__), \
                    patch("sys.argv", ["ci_publish.py", "dry-run", "--repository", REPOSITORY,
                                       "--pr", "7", "--app-login", "generic-app[bot]"]), \
                    patch("ci_publish.os.environ", {}), patch("ci_publish.write_publication", side_effect=error), \
                    patch("builtins.print") as output:
                self.assertEqual(main(), 1)
                output.assert_called_once_with("Trusted publisher refused: " + expected)

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
        _, _, fixture_summaries = gate_fixture(units=False)
        summaries_by_job = {summary["run"]["job"] + ("-" + summary["run"]["shard"]
                            if summary["run"]["job"] == "archive-relocation" else ""): summary for summary in fixture_summaries}
        artifacts = ["build-tvos-records-37700479666-2", "build-tvos-37700479666-2", "relocation-tvos-37700479666-2",
                     "relocation-ios-37700479666-2", "build-ios-records-37700479666-2", "build-ios-37700479666-2",
                     "host-summary-37700479666-2", "relocation-tvos-37700479666-3"]
        def read_summary(api, artifact, filename):
            name = artifact["name"]
            job = "host-checks" if name.startswith("host-summary") else "archive-relocation-" + name.split("-")[1] if name.startswith("relocation") else "-".join(name.split("-")[:2])
            summary = copy.deepcopy(summaries_by_job[job])
            summary["run"].update(id="37700479666", attempt=int(name.rsplit("-", 1)[1]))
            return summary
        class RecordedAPI:
            def pages(self, path, collection):
                if path.endswith("/artifacts"):
                    return [{"name": name, "expired": False} for name in artifacts]
                attempt = int(path.split("/attempts/")[1].split("/")[0])
                rows = RERUN_JOBS[attempt]
                return [dict(row, status="completed", conclusion="success", run_attempt=attempt)
                        for row in rows]
        with patch("ci_publish.json_member", side_effect=read_summary):
            jobs, summaries = producer_evidence(RecordedAPI(), dict(RUN, id=37700479666, run_attempt=3), FIXTURE_GATE)
        self.assertEqual({job["name"]: job["evidence_attempt"] for job in jobs},
                         {"host-checks": 2, "build-ios": 2, "build-tvos": 2, "archive-relocation-ios": 2, "archive-relocation-tvos": 3})
        self.assertEqual(sorted(summary["run"]["attempt"] for summary in summaries), [2, 2, 2, 2, 3])
        class RerunAPI(RecordedAPI):
            def pages(self, path, collection):
                rows = super().pages(path, collection)
                if "/attempts/3/" in path:
                    rows = [dict(row, runner_id=1000001237, started_at="2026-10-07T23:30:43Z",
                                 completed_at="2026-10-07T23:32:20Z") if row["name"] == "host-checks" else row for row in rows]
                return rows
        with patch("ci_publish.json_member", side_effect=read_summary), self.assertRaises(ContractError):
            producer_evidence(RerunAPI(), dict(RUN, id=37700479666, run_attempt=3), FIXTURE_GATE)
        with patch("ci_publish.json_member", side_effect=read_summary):
            diagnostics = []
            _, partial = producer_evidence(RerunAPI(), dict(RUN, id=37700479666, run_attempt=3), FIXTURE_GATE,
                                          diagnostics=diagnostics)
        self.assertEqual(4, len(partial))
        self.assertEqual(["required artifact missing or invalid: host-summary-37700479666-3"], diagnostics)

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

    def test_approval_reservation_retries_failed_dispatch_and_links_the_created_run(self):
        class RecordedAPI:
            repository = REPOSITORY
            def __init__(self):
                self.writes, self.dispatches, self.requests = [], [], []
                self.fail_dispatch = True
            def repo(self, path):
                return PR
            def pages(self, path):
                return [{"context": row[1], "state": row[2], "creator": {"login": "generic-app[bot]"}}
                        for row in reversed(self.writes)]
            def status(self, *args):
                self.writes.append(args)
            def dispatch(self, *args):
                self.dispatches.append(args)
                if self.fail_dispatch:
                    raise ContractError("GitHub API POST refused request (HTTP 503)")
                self.requests = [{"head_sha": HEAD, "run_id": 200, "status": "waiting"}]
        plan = {context: {"state": "pending", "description": "pending"} for context in ("ci-pr-gate", "ci-ui", "ci-approval-state")}
        api = RecordedAPI()
        with tempfile.TemporaryDirectory() as directory, \
                patch("ci_publish.compute", return_value=(HEAD, plan, {"request": HEAD, "obsolete": []})), \
                patch("ci_publish.os.environ", {"GITHUB_RUN_ID": "100", "GITHUB_STEP_SUMMARY": directory + "/summary.md"}), \
                patch("ci_publish.approval_requests", side_effect=lambda *args: api.requests):
            with self.assertRaises(ContractError):
                write_publication(api, api, 7, "", "generic-app[bot]")
            self.assertEqual(api.writes[-1][2], "pending")
            self.assertIn("Bookkeeping", api.writes[-1][3])
            self.assertEqual(len(api.dispatches), 1)
            api.fail_dispatch = False
            write_publication(api, api, 7, "", "generic-app[bot]")
            self.assertEqual(len(api.dispatches), 2)
            self.assertEqual(api.writes[-1][2], "success")
            self.assertEqual(api.writes[-1][4], "https://github.com/example/photos/actions/runs/200")
            display = next(row for row in reversed(api.writes) if row[1] == "ci-approval-state")
            self.assertEqual(display[2], "pending")
            self.assertEqual(display[4], "https://github.com/example/photos/actions/runs/200")
            self.assertIn("- ci-approval-state: pending — pending ([Details](https://github.com/example/photos/actions/runs/200))",
                          Path(directory, "summary.md").read_text())
            write_publication(api, api, 7, "", "generic-app[bot]")
            self.assertEqual(len(api.dispatches), 2)
            writes = len(api.writes)
            with patch("builtins.print"):
                write_publication(api, api, 7, "", "generic-app[bot]", dry_run=True)
            self.assertEqual(len(api.writes), writes)
            # A pending receipt plus an already-created run is recovered without
            # another dispatch, including interruption after the HTTP response.
            api.status(HEAD, f"ci-approval-request/pr-7/{HEAD}", "pending", "Bookkeeping", "")
            write_publication(api, api, 7, "", "generic-app[bot]")
            self.assertEqual(len(api.dispatches), 2)
            self.assertEqual(api.writes[-1][2], "success")

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
