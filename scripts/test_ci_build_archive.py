"""Regression checks for workspace preflight, artifact selection and extraction safety."""
import contextlib
import copy
import io
import json
import base64
import os
import plistlib
import platform
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

import ci_build_archive as archive
import ci_ui_tests as ui
from ci_summary import ContractError


class BuildArchiveTests(unittest.TestCase):
    def test_nightly_ui_requires_its_exact_attempt_archive_and_never_reuses_a_pr_verdict(self):
        identity = {"schema_version": 1, "repository": "owner/repo", "event": "schedule", "ref": "refs/heads/main",
                    "commit_sha": "a" * 40, "tree_sha": "d" * 40}
        context = {"identity": identity, "run": {"id": "123", "attempt": 1}}
        producer = {"id": 123, "path": ui.NIGHTLY_WORKFLOW, "workflow_id": 20, "run_attempt": 1,
                    "repository": {"full_name": "owner/repo"}, "head_repository": {"full_name": "owner/repo"},
                    "event": "schedule", "head_sha": identity["commit_sha"]}
        metadata = {"id": 7, "name": "build-ios-123-1", "expired": False,
                    "workflow_run": {"id": 123, "head_sha": identity["commit_sha"]}}
        manifest = self.manifest()
        manifest.update(identity=identity, pins_sha256=archive.file_hash(archive.ROOT / "scripts/ci-pins.json"))
        manifest["producer"]["workflow_path"] = ui.NIGHTLY_WORKFLOW
        class API:
            repository = "owner/repo"
            def repo(self, path):
                return {"id": 20, "path": ui.NIGHTLY_WORKFLOW} if path.startswith("actions/workflows/") else producer
            def pages(self, path, collection):
                return [metadata]
        with patch.object(ui, "downloaded_archive", return_value=(manifest, "e" * 64)):
            selection = ui.select_nightly_archive(API(), context, "ios")
            self.assertEqual(("123", 1, 7), (selection["producer_run_id"], selection["producer_attempt"], selection["artifact_id"]))
            for target, key, value in ((producer, "run_attempt", 2), (producer, "workflow_id", 21),
                                       (producer, "head_sha", "b" * 40), (metadata, "name", "build-ios-123-2"),
                                       (metadata, "expired", True), (manifest, "platform", "tvos")):
                original = target[key]
                with self.subTest(key=key, value=value), self.assertRaises(ContractError):
                    target[key] = value
                    ui.select_nightly_archive(API(), context, "ios")
                target[key] = original
        from types import SimpleNamespace
        context.update(source={"repository": identity["repository"], "event": identity["event"],
                               "workflow_path": ui.NIGHTLY_WORKFLOW, "fork_originated": False, "ci_changing": None})
        context["run"].update(tier="ui-infrastructure", job="ui-archive", shard=None)
        with patch.object(ui, "context", return_value=context), patch.object(ui, "workspace_preflight"), \
                patch.object(ui, "output") as outputs, patch.object(ui, "GitHub"), \
                patch.dict(ui.os.environ, {"GH_TOKEN": "test-placeholder"}), \
                patch.object(ui, "select_nightly_archive", return_value=selection) as select, \
                patch.object(ui, "select_archive", side_effect=AssertionError("nightly cannot select another workflow's archive")), \
                patch("ci_ui_reuse.find_reuse", side_effect=AssertionError("nightly must execute the complete UI population")):
            self.assertEqual(ui.wait_archive(SimpleNamespace(output_dir=self.root / "nightly", timeout_minutes=1)), 0)
        self.assertEqual(["ios", "tvos"], [call.args[-1] for call in select.call_args_list])
        self.assertIn(unittest.mock.call("run_ui", "true"), outputs.call_args_list)

    def test_historical_reproduction_preserves_default_and_refuses_unsupported_factor(self):
        for factor, help_text, expected in ((1, "legacy usage", []),
                                            (2, "usage: run --wait-factor WAIT_FACTOR", ["--wait-factor", "2"]),
                                            (2, "legacy usage", None)):
            with self.subTest(factor=factor, help=help_text):
                with patch.object(ui.subprocess, "check_output", return_value=help_text):
                    if expected is None:
                        with self.assertRaisesRegex(ContractError, "predates"):
                            ui.reproduction_wait_arguments(Path("source"), factor, {})
                    else:
                        self.assertEqual(expected, ui.reproduction_wait_arguments(Path("source"), factor, {}))

    def test_apple_tv_ui_archive_cannot_use_the_iphone_build(self):
        manifest = self.manifest()
        manifest["platform"] = "tvos"
        manifest["producer"]["artifact_name"] = "build-tvos-123-1"
        run = {"id": 123}
        ui.check_cross_run_identity(manifest, self.identity, run, 1, {"xcode": {"build": "27A266a"}},
                                    "f" * 64, platform_name="tvos")
        for mutate in (lambda m: m.update(platform="ios"),
                       lambda m: m["producer"].update(artifact_name="build-ios-123-1")):
            bad = copy.deepcopy(manifest)
            mutate(bad)
            with self.subTest(mutate=mutate), self.assertRaises(ContractError):
                ui.check_cross_run_identity(bad, self.identity, run, 1, {"xcode": {"build": "27A266a"}},
                                            "f" * 64, platform_name="tvos")
        runs = [{"name": "build-ios", "status": "completed", "conclusion": "success"},
                {"name": "build-tvos", "status": "completed", "conclusion": "failure"}]
        class API:
            def pages(self, path, collection):
                return runs
        self.assertEqual(ui.build_job_attempt(API(), {"id": 123, "run_attempt": 1}, platform_name="tvos")["conclusion"], "failure")

    def test_main_ui_archive_wait_is_skipped_only_with_trusted_reuse(self):
        from types import SimpleNamespace
        push = {"schema_version": 1, "repository": "owner/repo", "event": "push", "ref": "refs/heads/main",
                "pushed_sha": "a" * 40, "tree_sha": "d" * 40}
        for identity, proof, expected_waits in ((push, {"source": {"run_id": 123}}, 0),
                                               (push, None, 2), (self.identity, None, 2)):
            with self.subTest(event=identity["event"], proof=proof):
                context = {"identity": identity, "source": {"repository": "owner/repo", "event": identity["event"],
                           "workflow_path": ui.WORKFLOW, "fork_originated": False, "ci_changing": None},
                           "run": {"id": "100", "attempt": 1, "tier": "ui-infrastructure", "job": "ui-archive", "shard": None}}
                directory = self.root / (identity["event"] + ("-reuse" if proof else "-run"))
                with patch.object(ui, "context", return_value=context), patch.object(ui, "workspace_preflight"), \
                        patch.object(ui, "app_affected", return_value=True), patch.object(ui, "output") as outputs, \
                        patch("ci_ui_reuse.find_reuse", return_value=proof) as reuse, \
                        patch.object(ui, "GitHub"), patch.dict(ui.os.environ, {"GH_TOKEN": "test-placeholder"}), \
                        patch.object(ui, "select_archive", return_value={"artifact_id": 9, "producer_run_id": "123", "producer_attempt": 1}) as select:
                    self.assertEqual(ui.wait_archive(SimpleNamespace(output_dir=directory, timeout_minutes=1)), 0)
                self.assertEqual(select.call_count, expected_waits)
                self.assertIn(unittest.mock.call("run_ui", "false" if proof else "true"), outputs.call_args_list)
                self.assertEqual(reuse.call_count, 1 if identity["event"] == "push" else 0)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.identity = {"schema_version": 1, "event": "pull_request", "repository": "owner/repo",
                         "pull_request": 2, "merge_sha": "a" * 40, "base_sha": "b" * 40,
                         "head_sha": "c" * 40, "tree_sha": "d" * 40}
        self.products = self.root / "Products"
        self.app = self.products / "Debug-iphonesimulator/App.app"
        self.app.mkdir(parents=True)
        self.plist = self.app / "Info.plist"
        self.values = {"IMMICH_SERVER_URL": "", "IMMICH_API_KEY": "", "ENABLE_DEBUG_AUTO_SERVER": "0"}
        self.plist.write_bytes(plistlib.dumps(self.values))
        (self.app / "App").write_bytes(b"executable")
        (self.app / "App").chmod(0o755)
        (self.app / "link").symlink_to("App")
        (self.products / "App.xctestrun").write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"FormatVersion": 2}}))

    def manifest(self):
        return archive.make_manifest(self.products, identity=self.identity, run_id="123", attempt=1,
                                     platform="ios", architecture=[platform.machine()], xcode_build="27A266a",
                                     source_path=self.root / "source", archive_sha="e" * 64,
                                     pins_sha="f" * 64, signing_mode="adhoc")

    def test_private_configuration_is_rejected_without_following_links(self):
        config = self.root / "Config/env.xcconfig"
        config.parent.mkdir()
        archive.workspace_preflight(self.root)
        for kind in ("file", "symlink", "dangling"):
            with self.subTest(kind=kind):
                if kind == "file":
                    config.write_text("unread private content")
                else:
                    config.symlink_to(self.plist if kind == "symlink" else self.root / "missing")
                with self.assertRaisesRegex(ContractError, "private configuration"):
                    archive.workspace_preflight(self.root)
                config.unlink()

    def test_structural_secret_checks_reject_configured_servers_and_debug_flags(self):
        archive.check_products(self.products)
        for key, value in (("IMMICH_SERVER_URL", "fixture.invalid"), ("IMMICH_API_KEY", "dummy"),
                           ("ENABLE_DEBUG_AUTO_SERVER", "1"), ("ENABLE_DEBUG_NEW_FLAG", True),
                           ("ENABLE_DEBUG_AUTO_SERVER", "$(UNRESOLVED)")):
            with self.subTest(key=key, value=value):
                values = dict(self.values, **{key: value})
                self.plist.write_bytes(plistlib.dumps(values))
                with self.assertRaises(ContractError):
                    archive.check_products(self.products)
        self.plist.write_bytes(plistlib.dumps({"IMMICH_SERVER_URL": ""}))
        with self.assertRaises(ContractError):
            archive.check_products(self.products)

    def test_archive_identity_refuses_another_base_even_with_the_same_head(self):
        manifest = self.manifest()
        archive.validate_manifest(manifest, self.identity, "123", 1, "ios", "27A266a", "f" * 64)
        for field, value in (("repository", "other/repo"), ("pull_request", 3), ("base_sha", "e" * 40),
                             ("head_sha", "e" * 40), ("tree_sha", "e" * 40), ("merge_sha", "e" * 40)):
            with self.subTest(field=field):
                expected = dict(self.identity, **{field: value})
                with self.assertRaises(ContractError):
                    archive.validate_manifest(manifest, expected, "123", 1, "ios", "27A266a", "f" * 64)
        for run, attempt, platform in (("124", 1, "ios"), ("123", 2, "ios"), ("123", 1, "tvos")):
            with self.subTest(run=run, attempt=attempt, platform=platform):
                with self.assertRaises(ContractError):
                    archive.validate_manifest(manifest, self.identity, run, attempt, platform, "27A266a", "f" * 64)
        import ci_unit_tests as units
        from ci_verdict import evaluate_population
        selection = self.root / "selection.json"
        selection.write_text(json.dumps({"identity": self.identity, "platform": "ios"}))
        sources = {"immichSlidesTests/ExampleTests.swift": "import Testing\nstruct ExampleTests { @Test func `works`() {} }"}
        staged = self.root / "staged"
        def git(*args):
            self.assertIn(self.identity["tree_sha"], args[3] if args[0] == "ls-tree" else args[1])
            return next(iter(sources)) if args[0] == "ls-tree" else next(iter(sources.values()))
        with patch.object(archive, "context", return_value={"identity": self.identity}), patch.object(units, "git", side_effect=git):
            units.stage_tools(staged, selection)
        # Declarations survive without any source; they cannot be copied from enumeration.
        declared = units.read_declarations(staged, {"identity": self.identity, "platform": "ios"})
        self.assertEqual(declared, [{"kind": "swift", "key": "ExampleTests/works", "dimensions": {"platform": "ios"}}])
        # Lazy cleanup imports must work after the source checkout is removed too.
        child = ("import json, os, signal, sys, time\nfrom pathlib import Path\n"
                 "output = Path(sys.argv[1])\n"
                 "def finalize(signum, frame):\n"
                 "    (output / 'finalized.json').write_text(json.dumps({'pid': os.getpid(), 'finalized': True}))\n"
                 "    raise SystemExit(0)\n"
                 "signal.signal(signal.SIGINT, finalize)\n"
                 "(output / 'ready.json').write_text(json.dumps({'pid': os.getpid()}))\n"
                 "time.sleep(60)\n")
        parent = ("import signal, sys\nfrom pathlib import Path\n"
                  "tools, mode, output, child = sys.argv[1:]\n"
                  "sys.path.insert(0, str(Path(tools) / 'scripts'))\n"
                  "import ci_unit_tests as units\n"
                  "assert units.ROOT == Path(tools).resolve()\n"
                  "signal.signal(signal.SIGINT, signal.default_int_handler)\n"
                  "try:\n"
                  "    code = units.default_run([sys.executable, '-I', '-c', child, output], "
                  "timeout_seconds=2 if mode == 'timeout' else 30, grace_seconds=10)\n"
                  "except KeyboardInterrupt:\n"
                  "    code = 130\n"
                  "raise SystemExit(code)\n")
        for mode, expected in (("timeout", 124), ("interrupt", 130)):
            with self.subTest(relocated_cleanup=mode):
                output = self.root / mode
                output.mkdir()
                with (output / "runner.log").open("w") as log:
                    process = subprocess.Popen([sys.executable, "-I", "-B", "-c", parent,
                                                str(staged), mode, str(output), child], cwd=staged,
                                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        deadline = time.monotonic() + 15
                        while not (output / "ready.json").exists() and time.monotonic() < deadline:
                            if process.poll() is not None:
                                break
                            time.sleep(.05)
                        self.assertTrue((output / "ready.json").exists(), (output / "runner.log").read_text())
                        ready = json.loads((output / "ready.json").read_text())
                        if mode == "interrupt":
                            process.send_signal(signal.SIGINT)
                        self.assertEqual(process.wait(timeout=20), expected, (output / "runner.log").read_text())
                        self.assertEqual(json.loads((output / "finalized.json").read_text()),
                                         {"pid": ready["pid"], "finalized": True})
                        with self.assertRaises(ProcessLookupError):
                            os.kill(ready["pid"], 0)
                    finally:
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait(timeout=5)
                        if (output / "ready.json").exists():
                            try:
                                os.killpg(json.loads((output / "ready.json").read_text())["pid"], signal.SIGKILL)
                            except ProcessLookupError:
                                pass
        for field, value in (("platform", "tvos"), ("identity", dict(self.identity, tree_sha="e" * 40))):
            with self.subTest(field=field), self.assertRaisesRegex(ContractError, "declaration.*mismatch"):
                units.read_declarations(staged, {"identity": self.identity, "platform": "ios", field: value})
        with patch.object(archive, "context", return_value={"identity": dict(self.identity, tree_sha="e" * 40)}), \
                patch.object(units, "git") as source, self.assertRaisesRegex(ContractError, "checkout identity mismatch"):
            units.stage_tools(self.root / "mismatched", selection)
        source.assert_not_called()
        record = json.loads((staged / "unit-declarations.json").read_text())
        for values in ([], declared * 2):
            with self.subTest(declarations=values), self.assertRaises(ContractError):
                (staged / "unit-declarations.json").write_text(json.dumps(dict(record, declared=values)))
                units.read_declarations(staged, {"identity": self.identity, "platform": "ios"})
        from test_ci_summary import valid_summary
        summary = valid_summary()
        summary["run"]["tier"] = "unit"
        summary["population"].update(declared=declared, compiled=declared, observed=[])
        empty_policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        self.assertEqual(evaluate_population(summary, declared, empty_policy, environment="hermetic")["status"], "failed")
        from ci_summary import observation
        summary["population"]["observed"] = [observation(declared[0], "passed", 0)]
        self.assertEqual(evaluate_population(summary, declared, empty_policy, environment="hermetic")["status"], "passed")

    def test_cross_run_ui_selection_refuses_same_head_other_base_and_binds_build_record_hash(self):
        from ci_summary import observation, test_identity
        manifest = self.manifest()
        pins = {"xcode": {"build": "27A266a"}}
        run = {"id": 123, "run_attempt": 1, "workflow_id": 42, "path": ui.GATE_WORKFLOW,
               "event": "pull_request", "head_sha": self.identity["head_sha"],
               "head_repository": {"full_name": "owner/repo"},
               "repository": {"full_name": "owner/repo"}, "pull_requests": [{"number": 2}]}
        ui.check_cross_run_identity(manifest, self.identity, run, 1, pins, "f" * 64)
        with self.assertRaisesRegex(ContractError, "archive-identity-mismatch"):
            ui.check_cross_run_identity(manifest, dict(self.identity, base_sha="e" * 40), run, 1, pins, "f" * 64)
        step = test_identity("host", "secret-free build archive", platform="ios", configuration="Debug")
        summary = archive.record({"identity": self.identity, "source": {
            "repository": "owner/repo", "event": "pull_request", "workflow_path": ui.GATE_WORKFLOW,
            "fork_originated": False, "ci_changing": None}, "run_id": "123", "attempt": 1}, "ios", "build-ios")
        summary.update(status="passed")
        summary["population"].update(declared=[step], compiled=[step], observed=[observation(step, "passed", 0)])
        summary["hashes"]["manifests"]["build"] = "a" * 64
        records = {"id": 8, "name": "build-ios-records-123-1", "expired": False}
        artifact = {"id": 9, "name": "build-ios-123-1", "expired": False,
                    "workflow_run": {"id": 123, "head_sha": self.identity["head_sha"]}}
        class API:
            repository = "owner/repo"
            def repo(self, path):
                if path.startswith("pulls/"):
                    return {"head": {"repo": {"full_name": "owner/repo"}}}
                return {"id": 42, "path": ui.GATE_WORKFLOW, "state": "active"}
            def pages(self, path, collection, **filters):
                return [run] if collection == "workflow_runs" else [records, artifact]
        with patch.object(ui, "build_job_attempt", return_value={"status": "completed", "conclusion": "success", "evidence_attempt": 1}), \
                patch.object(ui, "json_member", return_value=summary), patch.object(ui, "downloaded_archive", return_value=(manifest, "a" * 64)), \
                patch.object(ui, "file_hash", return_value="f" * 64):
            for remaining_seconds in (1, 0):
                # An exhausted shared deadline still checks the next platform's ready archive.
                selected = ui.select_archive(API(), self.identity, timeout_seconds=remaining_seconds)
                self.assertEqual((selected["artifact_id"], selected["producer_run_id"], selected["producer_attempt"]), (9, "123", 1))
            with patch.object(API, "pages", return_value=[]) as poll, self.assertRaisesRegex(ContractError, "archive-unavailable"):
                ui.select_archive(API(), self.identity, timeout_seconds=0)
            poll.assert_called_once()
            with patch.object(ui, "downloaded_archive", return_value=(manifest, "e" * 64)), self.assertRaisesRegex(ContractError, "manifest differ"):
                ui.select_archive(API(), self.identity, timeout_seconds=1)
            refused = []
            summary["identity"] = dict(self.identity, base_sha="e" * 40)
            with self.assertRaisesRegex(ContractError, "archive-identity-mismatch"):
                ui.select_archive(API(), self.identity, timeout_seconds=.001, poll_seconds=0,
                                  record_refusals=lambda rows: refused.extend(rows))
            self.assertTrue(refused)
            self.assertEqual(refused[0]["head_sha"], self.identity["head_sha"])
            summary["identity"] = self.identity
            fork = dict(run, id=125, head_repository={"full_name": "fork/repo"})
            with patch.object(API, "pages", side_effect=lambda path, collection, **filters:
                              [fork, run] if collection == "workflow_runs" else [records, artifact]):
                selected = ui.select_archive(API(), self.identity, timeout_seconds=1)
            self.assertEqual(selected["artifact_id"], 9)
            self.assertEqual(selected["refusals"][0]["outcome"], "archive-head-repository-mismatch")
            for conclusion in ("failure", "cancelled"):
                with self.subTest(conclusion=conclusion):
                    newer = dict(run, id=124)
                    other = copy.deepcopy(summary)
                    other["identity"]["base_sha"] = "e" * 40
                    other["run"]["id"] = "124"
                    other["status"] = "failed"
                    other_records = dict(records, name="build-ios-records-124-1")
                    def pages(path, collection, **filters):
                        return [newer, run] if collection == "workflow_runs" else (
                            [other_records] if "/124/" in path else [records, artifact])
                    jobs = lambda api, candidate, **options: {"status": "completed", "evidence_attempt": 1,
                        "conclusion": conclusion if candidate["id"] == 124 else "success"}
                    with patch.object(API, "pages", side_effect=pages), patch.object(ui, "build_job_attempt", side_effect=jobs), \
                            patch.object(ui, "json_member", side_effect=lambda api, record, name: other if record == other_records else summary):
                        selected = ui.select_archive(API(), self.identity, timeout_seconds=1)
                    self.assertEqual(selected["artifact_id"], 9)
                    self.assertEqual(selected["refusals"][0]["producer_identity"], other["identity"])
                    # The same failed job is fatal once its full identity matches.
                    other["identity"] = self.identity
                    with patch.object(API, "pages", side_effect=pages), patch.object(ui, "build_job_attempt", side_effect=jobs), \
                            patch.object(ui, "json_member", return_value=other), self.assertRaisesRegex(ContractError, "did not succeed"):
                        ui.select_archive(API(), self.identity, timeout_seconds=1)

    def test_main_push_archive_wait_ends_when_the_gate_is_superseded_and_pauses_while_it_is_held(self):
        head = "d" * 40
        identity = {"schema_version": 1, "event": "push", "repository": "owner/repo",
                    "ref": "refs/heads/main", "pushed_sha": head, "tree_sha": "c" * 40}
        def gate(status, conclusion=None):
            return {"id": 300, "workflow_id": 42, "path": ui.GATE_WORKFLOW, "event": "push", "head_sha": head,
                    "head_branch": "main", "run_attempt": 1, "status": status, "conclusion": conclusion,
                    "repository": {"full_name": "owner/repo"}, "head_repository": {"full_name": "owner/repo"}}
        def wait(run):
            clock = [1000.0]
            class API:
                repository = "owner/repo"
                def repo(self, path):
                    return {"id": 42, "path": ui.GATE_WORKFLOW, "state": "active"}
                def pages(self, path, collection, **filters):
                    return [run] if collection == "workflow_runs" else []
            def sleep(seconds):
                clock[0] += seconds
            with patch.object(ui.time, "monotonic", side_effect=lambda: clock[0]), patch.object(ui.time, "sleep", side_effect=sleep), \
                    patch.object(ui, "build_job_attempt", return_value=None), \
                    contextlib.redirect_stdout(io.StringIO()), \
                    self.assertRaisesRegex(ContractError, "archive-unavailable"):
                ui.select_archive(API(), identity, timeout_seconds=600, poll_seconds=20)
            return clock[0] - 1000.0
        self.assertEqual(0, wait(gate("completed", "cancelled")))
        self.assertAlmostEqual(600, wait(gate("in_progress")), delta=20)
        waited = wait(gate("pending"))
        self.assertAlmostEqual(ui.GATE_PENDING_PAUSE_SECONDS + 600, waited, delta=20)

    def test_both_platforms_share_one_archive_deadline_that_includes_the_pending_gate_pause(self):
        head = "d" * 40
        identity = {"schema_version": 1, "event": "push", "repository": "owner/repo",
                    "ref": "refs/heads/main", "pushed_sha": head, "tree_sha": "c" * 40}
        ready_at = {"ios": 90 * 60, "tvos": 125 * 60}
        def scenario(gate_pending_seconds):
            clock = [1000.0]
            now = lambda: clock[0] - 1000.0
            def gate():
                return {"id": 300, "workflow_id": 42, "path": ui.GATE_WORKFLOW, "event": "push", "head_sha": head,
                        "head_branch": "main", "run_attempt": 1, "repository": {"full_name": "owner/repo"},
                        "head_repository": {"full_name": "owner/repo"}, "conclusion": None,
                        "status": "pending" if now() < gate_pending_seconds else "in_progress"}
            class API:
                repository = "owner/repo"
                def repo(self, path):
                    return {"id": 42, "path": ui.GATE_WORKFLOW, "state": "active"}
                def pages(self, path, collection, **filters):
                    if collection == "workflow_runs":
                        return [gate()]
                    return [{"id": 1000 + index, "name": name, "expired": False}
                            for index, name in enumerate(
                                [f"build-{p}-records-300-1" for p in ready_at if now() >= ready_at[p]]
                                + [ui.artifact_name(p, "300", 1) for p in ready_at if now() >= ready_at[p]])]
            build = {"source": {"workflow_path": ui.GATE_WORKFLOW, "repository": "owner/repo", "event": "push",
                                "fork_originated": False}, "identity": identity, "status": "passed",
                     "hashes": {"manifests": {"build": "a" * 64}}}
            def parse(_):
                return dict(build, run={"id": "300", "attempt": 1, "tier": "build",
                                        "job": "build-" + self.platform, "shard": self.platform})
            result = {}
            with patch.object(ui.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(ui.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                    patch.object(ui, "build_job_attempt", return_value={"status": "completed", "conclusion": "success", "evidence_attempt": 1}), \
                    patch.object(ui, "json_member", return_value={}), patch.object(ui, "parse_summary", side_effect=parse), \
                    patch.object(ui, "validate_artifact"), patch.object(ui, "downloaded_archive", return_value=({}, "a" * 64)), \
                    patch.object(ui, "check_cross_run_identity"), patch.object(ui, "file_hash", return_value="f" * 64), \
                    contextlib.redirect_stdout(io.StringIO()):
                wait = ui.ArchiveWait(120 * 60)
                for self.platform in ready_at:
                    try:
                        ui.select_archive(API(), identity, platform_name=self.platform, wait=wait)
                        result[self.platform] = now()
                    except ContractError as error:
                        result[self.platform] = str(error)
                        break
            return result, wait
        selected, wait = scenario(60 * 60)
        self.assertEqual(["ios", "tvos"], list(selected))
        self.assertTrue(all(isinstance(value, float) for value in selected.values()), selected)
        self.assertGreaterEqual(selected["tvos"], ready_at["tvos"])
        self.assertEqual(ui.GATE_PENDING_PAUSE_SECONDS, wait.paused)
        # Without a pending gate the unextended 120-minute deadline ends before tvOS is ready.
        unpaused, _ = scenario(0)
        self.assertRegex(unpaused["tvos"], "archive-unavailable")
        # A gate that stays pending can extend the shared deadline by the single allowance only.
        ready_at.update(ios=10 ** 6, tvos=10 ** 6)
        stuck, wait = scenario(10 ** 6)
        self.assertRegex(stuck["ios"], "archive-unavailable")
        self.assertEqual(ui.GATE_PENDING_PAUSE_SECONDS, wait.paused)
        self.assertAlmostEqual(170 * 60, wait.deadline - 1000.0, delta=1)

    def test_ui_reproduction_checks_revision_pins_and_exact_destination_before_build(self):
        pins = json.loads((ui.ROOT / "scripts/ci-pins.json").read_text())
        source = self.root / "source"
        (source / "scripts").mkdir(parents=True)
        (source / "scripts/ci-pins.json").write_text(json.dumps(pins))
        udid = "00000000-0000-0000-0000-000000000000"
        version = f"Xcode {pins['xcode']['version']}\nBuild version {pins['xcode']['build']}"
        for device, platform_name in ui.DEVICES.items():
            runtime = pins["simulators"][platform_name]
            type_id = "com.apple.CoreSimulator.SimDeviceType." + device
            inventory = {"runtimes": [{"identifier": runtime["runtime"], "isAvailable": True,
                                      "version": runtime["version"], "buildversion": runtime["build"]}],
                         "devices": {runtime["runtime"]: [{"udid": udid, "isAvailable": True, "deviceTypeIdentifier": type_id}]},
                         "devicetypes": [{"name": pins["device_types"][device], "identifier": type_id}]}
            destination = "platform=" + ("iOS Simulator" if platform_name == "ios" else "tvOS Simulator") + ",id=" + udid
            for mismatch in (None, "xcode", "runtime", "destination-runtime", "device-type"):
                with self.subTest(device=device, mismatch=mismatch):
                    actual = copy.deepcopy(inventory)
                    if mismatch == "runtime":
                        actual["runtimes"][0]["buildversion"] = "wrong"
                    if mismatch == "destination-runtime":
                        actual["devices"]["other-runtime"] = actual["devices"].pop(runtime["runtime"])
                    if mismatch == "device-type":
                        actual["devices"][runtime["runtime"]][0]["deviceTypeIdentifier"] = "other-device"
                    environment = {"DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
                    with patch.object(ui.subprocess, "check_output", side_effect=["Xcode other" if mismatch == "xcode" else version, json.dumps(actual)]):
                        if mismatch:
                            with self.assertRaisesRegex(ContractError, "pin mismatch"):
                                ui.verify_reproduction_pins(source, destination, environment, device)
                        else:
                            ui.verify_reproduction_pins(source, destination, environment, device)
                    self.assertEqual(environment["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")

    def test_ui_archive_retains_successful_job_attempt_but_never_falls_back_for_a_rerun_job(self):
        runs = {1: [{"name": "build-ios", "started_at": "first", "completed_at": "done", "runner_id": 1,
                     "status": "completed", "conclusion": "success"}],
                2: [{"name": "build-ios", "started_at": "first", "completed_at": "done", "runner_id": 1,
                     "status": "completed", "conclusion": "success"}]}
        class API:
            def pages(self, path, collection):
                return runs[int(path.split("/")[-2])]
        self.assertEqual(ui.build_job_attempt(API(), {"id": 123, "run_attempt": 2})["evidence_attempt"], 1)
        runs[2][0].update(started_at="rerun", completed_at="later", runner_id=2, conclusion="failure")
        self.assertEqual(ui.build_job_attempt(API(), {"id": 123, "run_attempt": 2})["evidence_attempt"], 2)
        self.assertEqual(ui.build_job_attempt(API(), {"id": 123, "run_attempt": 2})["conclusion"], "failure")

    def test_artifact_selection_requires_id_run_and_producer_attempt(self):
        import ci_live_tests as live
        metadata = {"id": 7, "name": archive.artifact_name("ios", "123", 1), "expired": False,
                    "workflow_run": {"id": 123, "head_sha": self.identity["head_sha"]}}
        archive.validate_artifact(metadata, self.identity, "123", 1, "ios", 7)
        second = dict(metadata, id=8, name=archive.artifact_name('ios', '123', 2))
        future = dict(metadata, id=9, name=archive.artifact_name('ios', '123', 4))
        self.assertEqual(live.latest_artifact([metadata, second, future], 'ios', '123', 3), (8, 2))
        self.assertEqual(live.latest_artifact([metadata, dict(second, expired=True)], 'ios', '123', 3), (7, 1))
        for entries in ([], [future], [metadata, metadata], [dict(metadata, expired=True)]):
            with self.subTest(entries=entries), self.assertRaises(ContractError):
                live.latest_artifact(entries, 'ios', '123', 3)
        for field, value in (("id", 8), ("name", archive.artifact_name("ios", "123", 2)), ("expired", True)):
            with self.subTest(field=field):
                candidate = dict(metadata, **{field: value})
                with self.assertRaises(ContractError):
                    archive.validate_artifact(candidate, self.identity, "123", 1, "ios", 7)
        candidate = copy.deepcopy(metadata)
        candidate["workflow_run"]["id"] = 124
        with self.assertRaises(ContractError):
            archive.validate_artifact(candidate, self.identity, "123", 1, "ios", 7)

    def test_tar_round_trip_preserves_modes_symlinks_and_detects_tampering(self):
        (self.products / "sub").mkdir()
        (self.products / "sub/up").symlink_to("..")
        (self.products / "alias").symlink_to("sub/up/Debug-iphonesimulator/App.app/link")
        tar_path = self.root / "build.tar.gz"
        archive.pack_products(self.products, tar_path)
        manifest = self.manifest()
        manifest["archive_sha256"] = archive.file_hash(tar_path)
        relocated = self.root / "relocated"
        archive.extract_products(tar_path, relocated, manifest)
        self.assertEqual(archive.inventory(relocated / "Products"), manifest["files"])
        self.assertEqual((relocated / "Products/Debug-iphonesimulator/App.app/App").stat().st_mode & 0o777, 0o755)
        self.assertEqual((relocated / "Products/Debug-iphonesimulator/App.app/link").readlink(), Path("App"))
        manifest["files"][-1]["mode"] = 0
        with self.assertRaises(ContractError):
            archive.extract_products(tar_path, self.root / "tampered", manifest)
        tar_path.write_bytes(tar_path.read_bytes() + b"modified")
        with self.assertRaisesRegex(ContractError, "archive hash"):
            archive.extract_products(tar_path, self.root / "corrupt", manifest)

    def test_archive_rejects_links_outside_products_and_unlisted_entries(self):
        (self.app / "link").unlink()
        for target in ("/etc/passwd", "../../../outside"):
            with self.subTest(target=target):
                (self.app / "link").symlink_to(target)
                with self.assertRaises(ContractError):
                    archive.inventory(self.products)
                (self.app / "link").unlink()
        base_manifest = self.manifest()
        sub = self.products / "sub"
        sub.mkdir()
        for case, links in (
            ("combined escape", {"sub/link": "..", "escape": "sub/link/../outside"}),
            ("self loop", {"escape": "escape"}),
            ("chain loop", {"sub/link": "../escape", "escape": "sub/link"}),
        ):
            with self.subTest(case=case):
                for name, target in links.items():
                    (self.products / name).symlink_to(target)
                try:
                    candidate = copy.deepcopy(base_manifest)
                    candidate["files"].append({"path": "Products/sub", "kind": "directory", "mode": 0o755})
                    candidate["files"].extend({"path": "Products/" + name, "kind": "symlink", "mode": 0o755,
                                               "target": target} for name, target in links.items())
                    with self.assertRaisesRegex(ContractError, "symlink (escapes|loop)"):
                        archive.inventory(self.products)
                    with self.assertRaisesRegex(ContractError, "symlink (escapes|loop)"):
                        archive.validate_manifest(candidate, self.identity, "123", 1, "ios", "27A266a", "f" * 64)
                    unsafe_tar = self.root / "unsafe.tar.gz"
                    with tarfile.open(unsafe_tar, "w:gz", dereference=False) as handle:
                        handle.add(self.products, arcname="Products")
                    candidate["archive_sha256"] = archive.file_hash(unsafe_tar)
                    with self.assertRaisesRegex(ContractError, "symlink (escapes|loop)"):
                        archive.extract_products(unsafe_tar, self.root / case, candidate)
                    self.assertFalse((self.root / case).exists())
                finally:
                    for name in links:
                        (self.products / name).unlink()
        sub.rmdir()
        tar_path = self.root / "build.tar.gz"
        archive.pack_products(self.products, tar_path)
        manifest = self.manifest()
        manifest["archive_sha256"] = archive.file_hash(tar_path)
        manifest["files"].pop()
        with self.assertRaises(ContractError):
            archive.extract_products(tar_path, self.root / "extra", manifest)

    def test_local_disk_safety_cannot_use_the_hosted_ci_exception(self):
        from unittest.mock import patch
        for environment in ({}, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"}):
            with self.subTest(environment=environment), patch.dict(archive.os.environ, environment, clear=True):
                with self.assertRaisesRegex(ContractError, "local 80 GiB"):
                    archive.disk_check(30)

    def test_manifest_rejects_unknown_versions_unsafe_paths_and_false_secret_claims(self):
        manifest = self.manifest()
        for key, value in (("schema_version", 2), ("private_configuration_present", True),
                           ("signing_mode", "disabled"), ("unexpected", "field")):
            with self.subTest(key=key):
                candidate = dict(manifest, **{key: value})
                with self.assertRaises(ContractError):
                    archive.validate_manifest(candidate, self.identity, "123", 1, "ios", "27A266a", "f" * 64)
        for name in ("/Products/App", "Products/../outside", "Products//App", "Other/App"):
            with self.subTest(path=name):
                with self.assertRaises(ContractError):
                    archive.safe_path(name)

    def test_ambient_server_configuration_is_rejected_without_echoing_values(self):
        from unittest.mock import patch
        for key in ("IMMICH_SERVER_URL", "TEST_RUNNER_IMMICH_API_KEY", "SIMCTL_CHILD_IMMICH_API_KEY", "ENABLE_DEBUG_AUTO_SERVER"):
            with self.subTest(key=key), patch.dict(archive.os.environ, {key: "unread dummy value"}, clear=True):
                with self.assertRaisesRegex(ContractError, "ambient server/debug configuration is forbidden"):
                    archive.workspace_preflight(self.root)

    def test_unsigned_or_non_adhoc_apps_cannot_claim_local_simulator_signing(self):
        for code, display in ((1, "code object is not signed at all"), (0, "Signature=Developer ID"), (0, "")):
            with self.subTest(code=code, display=display), patch.object(archive.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], code, stdout="", stderr=display)):
                with self.assertRaises(ContractError):
                    archive.measure_signing(self.app)
        with patch.object(archive.subprocess, "run",
                          return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="Signature=adhoc\n")):
            self.assertEqual(archive.measure_signing(self.app), "adhoc")

    def test_failed_entry_points_leave_failed_records_and_rerun_all_advice(self):
        workspace = self.root / "source"
        (workspace / "Config").mkdir(parents=True)
        ctx = {"identity": self.identity, "source": {"repository": "owner/repo", "event": "pull_request",
               "workflow_path": archive.WORKFLOW, "fork_originated": False, "ci_changing": None},
               "run_id": "123", "attempt": 2}
        private = workspace / "Config/env.xcconfig"
        private.symlink_to(workspace / "missing")
        metadata = {"id": 7, "name": archive.artifact_name("ios", "123", 1), "expired": True,
                    "workflow_run": {"id": 123, "head_sha": self.identity["head_sha"]}}
        for name in ("preflight", "expired", "absent", "identity"):
            output = self.root / name
            command = ["preflight", "--platform", "ios", "--output-dir", str(output)] if name == "preflight" else [
                "select", "--platform", "ios", "--artifact-id", "7", "--producer-attempt", "1",
                "--selection-path", str(self.root / (name + ".json")), "--output-dir", str(output)]
            candidate = copy.deepcopy(metadata)
            candidate["expired"] = name == "expired"
            if name == "identity":
                candidate["workflow_run"]["head_sha"] = "e" * 40
            response = io.BytesIO(json.dumps(candidate).encode())
            missing = urllib.error.HTTPError("https://api.github.com/artifact", 404, "Not Found", None, None)
            with self.subTest(entry=name), patch.object(archive, "ROOT", workspace), patch.object(
                    archive, "context", return_value=ctx), patch.object(archive, "toolchain") as versions, patch.dict(
                    archive.os.environ, {"GH_TOKEN": "dummy"}), patch.object(archive.urllib.request, "urlopen",
                    side_effect=missing if name == "absent" else None, return_value=response), redirect_stderr(io.StringIO()):
                self.assertEqual(archive.main(command), 1)
                versions.assert_not_called()
                summary = json.loads((output / "summary.json").read_text())
                self.assertEqual(summary["status"], "failed")
                failure = summary["infrastructure"][0]
                expected_code = "workspace-preflight-failed" if name == "preflight" else (
                    "archive-identity-mismatch" if name == "identity" else "archive-unavailable")
                self.assertEqual(failure["code"], expected_code)
                self.assertIn("use Re-run all jobs", failure["message"])
                self.assertNotIn("dummy", failure["message"])
                self.assertIn("use Re-run all jobs", (output / "summary.md").read_text())
            if name == "preflight":
                private.unlink()
        archive_dir = self.root / "archive"
        archive_dir.mkdir()
        manifest = copy.deepcopy(self.manifest())
        manifest["identity"]["base_sha"] = "e" * 40
        (archive_dir / "manifest.json").write_text(json.dumps(manifest))
        selection = dict(ctx, platform="ios", producer_attempt=1, artifact_id=7,
                         pins_sha256=archive.file_hash(Path(archive.__file__).with_name("ci-pins.json")))
        selection_path = self.root / "selected.json"
        selection_path.write_text(json.dumps(selection))
        developer = self.root / "Xcode/Contents/Developer"
        developer.mkdir(parents=True)
        (developer.parent / "version.plist").write_bytes(plistlib.dumps({"ProductBuildVersion": "27A266a"}))
        output = self.root / "proof-failure"
        relocated = self.root / "relocated-failure"
        import ci_unit_tests as units
        with patch.object(units, "ROOT", workspace), patch.dict(archive.os.environ, {"DEVELOPER_DIR": str(developer)}), \
                patch.object(archive, "extract_products") as extract, redirect_stderr(io.StringIO()):
            self.assertEqual(units.main(["run", "--selection-path", str(selection_path), "--archive-dir", str(archive_dir),
                                           "--relocated-path", str(relocated), "--output-dir", str(output)]), 1)
            extract.assert_not_called()
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertEqual(summary["infrastructure"][0]["code"], "archive-identity-mismatch")
            self.assertIn("use Re-run all jobs", summary["infrastructure"][0]["message"])
            self.assertFalse(relocated.exists())
        (archive_dir / "manifest.json").unlink()
        with patch.object(units, "ROOT", workspace), patch.object(units, "default_run") as xcode:
            self.assertEqual(units.main(["run", "--selection-path", str(selection_path), "--archive-dir", str(archive_dir),
                                        "--relocated-path", str(relocated), "--output-dir", str(output)]), 1)
            xcode.assert_not_called()
        summary = json.loads((output / "summary.json").read_text())
        self.assertEqual(summary["infrastructure"][0]["code"], "archive-unavailable")
        self.assertIn("use Re-run all jobs", summary["infrastructure"][0]["message"])

    def test_consumer_timeouts_preserve_scanned_failed_records_and_finish_cleanup(self):
        import ci_unit_tests as units
        pins_path = Path(units.__file__).with_name("ci-pins.json")
        pins = json.loads(pins_path.read_text())
        workspace = self.root / "tooling"
        workspace.mkdir()
        (workspace / "unit-declarations.json").write_text(json.dumps({"identity": self.identity, "platform": "ios",
            "declared": [{"kind": "swift", "key": "A/a", "dimensions": {"platform": "ios"}}]}))
        developer = self.root / "Xcode/Contents/Developer"
        developer.mkdir(parents=True)
        (developer.parent / "version.plist").write_bytes(plistlib.dumps({"ProductBuildVersion": "27A266a"}))
        archive_dir = self.root / "archive"
        archive_dir.mkdir()
        (archive_dir / "manifest.json").write_text(json.dumps({
            "source_path": str(self.root / "absent-source"), "products_path": str(self.root / "absent-products"),
            "signing_mode": "adhoc", "archive_sha256": "e" * 64,
        }))
        ctx = {"identity": self.identity, "source": {"repository": "owner/repo", "event": "pull_request",
               "workflow_path": archive.WORKFLOW, "fork_originated": False, "ci_changing": None},
               "run_id": "123", "attempt": 2, "platform": "ios", "producer_attempt": 1, "artifact_id": 7,
               "pins_sha256": archive.file_hash(pins_path)}
        selection = self.root / "selection.json"
        selection.write_text(json.dumps(ctx))
        def extract(_tar, destination, _manifest):
            products = destination / "Products"
            (products / "Debug-iphonesimulator/immichSlides.app").mkdir(parents=True)
            (products / "units.xctestrun").touch()

        device_type, simulator = "fixture.device", "fixture-simulator"
        device_types = {"devicetypes": [{"name": pins["device_types"]["iphone"], "identifier": device_type}]}
        devices = {"devices": {pins["simulators"]["ios"]["runtime"]: [
            {"udid": simulator, "deviceTypeIdentifier": device_type}]}}
        for phase, readable, export_bound in ((phase, readable, bound) for bound in (60, 180)
                                for phase, readable in (("enumeration", False), ("enumeration", True),
                                ("execution", False), ("execution", True),
                                ("tests", False), ("summary", False), ("shutdown", True), ("delete", True))):
            with self.subTest(phase=phase, readable=readable, export_bound=export_bound):
                case = self.root / (phase + ("-readable" if readable else "-unreadable") + str(export_bound))
                relocated, output = case / "relocated", case / "records"
                enumeration_bundle = case / "private/enumeration/enumeration.xcresult"
                execution_bundle = case / "private/execution/execution.xcresult"
                enumeration_bundle.mkdir(parents=True)
                execution_bundle.mkdir(parents=True)
                bundle = enumeration_bundle if phase == "enumeration" else execution_bundle
                owns_simulator = phase in {"tests", "summary", "shutdown", "delete"}
                codes = iter([0, 124] if phase == "enumeration" else [0, 0, 124 if phase == "execution" else 0])

                def run(command, **_kwargs):
                    if "-enumerate-tests" in command:
                        enumeration_path = Path(command[command.index("-test-enumeration-output-path") + 1])
                        enumeration_path.write_text(json.dumps({"errors": [], "values": [
                            {"kind": "target", "name": "immichSlidesTests", "children": [
                                {"kind": "class", "name": "A", "children": [{"kind": "test", "name": "a()"}]}]}]}))
                    return next(codes)

                def process(command, **kwargs):
                    operation = command[2] if command[1] == "simctl" else command[4]
                    if operation == phase:
                        raise subprocess.TimeoutExpired(command, kwargs.get("timeout", 0))
                    return subprocess.CompletedProcess(command, 0, json.dumps({"testNodes": []}).encode(), b"")

                def export_empty(_bundle, records, _sensitive, **kwargs):
                    self.assertEqual(kwargs["summary_timeout_seconds"], export_bound)
                    if phase in {"tests", "summary"}:
                        from run_strict_e2e import export_private_result_bundle
                        return export_private_result_bundle(_bundle, records, _sensitive, **kwargs)
                    if not readable:
                        raise units.CommandError("Enumeration has no readable official results")
                    complete = phase in {"shutdown", "delete"}
                    children = [{"nodeType": "Test Case", "nodeIdentifier": "A/a()", "result": "Passed", "duration": "0s"}] if complete else []
                    (records / "official-tests.json").write_text(json.dumps({"testNodes": [
                        {"nodeType": "Unit test bundle", "name": "immichSlidesTests", "children": children}]}))
                    (records / "official-summary.json").write_text(json.dumps({"totalTestCount": int(complete), "passedTests": int(complete),
                        "failedTests": 0, "skippedTests": 0, "result": "Passed" if complete else "unknown"}))
                    return archive.file_hash(records / "official-tests.json")

                with patch.object(units, "ROOT", workspace), patch.dict(archive.os.environ, {"DEVELOPER_DIR": str(developer)}), \
                        patch.object(archive, "workspace_preflight"), patch.object(archive, "validate_manifest"), \
                        patch.object(archive, "disk_check"), patch.object(archive, "DiskMeasurement"), \
                        patch.object(archive, "extract_products", side_effect=extract), \
                        patch.object(archive, "measure_signing", return_value="adhoc"), \
                        patch.object(archive, "checked_command", side_effect=[json.dumps(device_types), simulator if owns_simulator else json.dumps(devices)]), \
                        patch.object(units, "toolchain", return_value={"versions": {}, "signing_mode": "not-applicable"}), \
                        patch.object(units, "prepare_private_result_bundle_path", side_effect=[enumeration_bundle, execution_bundle]), \
                        patch.object(units, "default_run", side_effect=run), \
                        patch.object(subprocess, "run", side_effect=process) as processes, \
                        patch.dict(archive.os.environ, {"GITHUB_OUTPUT": str(case / "step-output")}), \
                        patch.object(units, "export_private_result_bundle", side_effect=export_empty) as export:
                    archive.DiskMeasurement.return_value.finish.return_value = {}
                    self.assertEqual(units.main(["run", "--selection-path", str(selection), "--archive-dir", str(archive_dir),
                                                "--relocated-path", str(relocated), "--output-dir", str(output),
                                                *([] if export_bound == 60 else ["--result-export-timeout-seconds", str(export_bound)]),
                                                *([] if owns_simulator else ["--simulator-id", simulator])]),
                                     124 if phase in {"enumeration", "execution"} else 1)
                    export.assert_called_once_with(bundle, output.resolve(), [units.PUBLIC_API_KEY],
                                                   summary_timeout_seconds=export_bound, export_timeout_seconds=export_bound)
                if owns_simulator:
                    cleanup = [call for call in processes.call_args_list if call.args[0][1] == "simctl"]
                    self.assertEqual([call.args[0][2] for call in cleanup], ["shutdown", "delete"])
                    self.assertEqual([call.kwargs["timeout"] for call in cleanup], [15, 60])
                    self.assertFalse(enumeration_bundle.parent.exists())
                if phase in {"tests", "summary"}:
                    exports = [call for call in processes.call_args_list if call.args[0][1] == "xcresulttool"]
                    expected_exports = ["tests", "summary"] if phase == "summary" else ["tests"]
                    self.assertEqual([call.args[0][4] for call in exports], expected_exports)
                    self.assertEqual([call.kwargs["timeout"] for call in exports], [export_bound] * len(expected_exports))
                self.assertTrue(bundle.is_dir())
                self.assertFalse(json.loads((output / "result-bundle-quarantine.json").read_text())["result_bundle_disposed"])
                provenance = json.loads((output / "archive-consumption.json").read_text())
                self.assertEqual((provenance["artifact_id"], provenance["producer_attempt"], provenance["consumer_attempt"]), (7, 1, 2))
                self.assertEqual(provenance["enumeration_exit_code"], 124 if phase == "enumeration" else 0)
                self.assertEqual(provenance["test_exit_code"], None if phase == "enumeration" else 124 if phase == "execution" else 0)
                summary = json.loads((output / "summary.json").read_text())
                self.assertEqual(summary["status"], "failed")
                self.assertEqual(summary["population"]["declared"], [{"kind": "swift", "key": "A/a", "dimensions": {"platform": "ios"}}])
                self.assertEqual(summary["hashes"]["manifests"]["unit-declarations"],
                                 archive.file_hash(workspace / "unit-declarations.json"))
                self.assertEqual(json.loads((output / "sensitive-scan.json").read_text())["result"], "PASS")
                self.assertIn("records_safe=true", (case / "step-output").read_text())
                if readable and phase != "summary":
                    self.assertEqual(provenance["official_tests_sha256"], archive.file_hash(output / "official-tests.json"))
                if readable and phase == "enumeration":
                    self.assertEqual(summary["infrastructure"][-1]["message"], "official unit tests were empty")
                if phase in {"execution", "tests", "summary", "shutdown", "delete"}:
                    code = "unit-execution-timed-out" if phase == "execution" else "xcresult-export-timeout" if phase in {"tests", "summary"} else "simulator-cleanup-timed-out"
                    self.assertIn(code, [entry["code"] for entry in summary["infrastructure"]])
                if phase in {"tests", "summary"}:
                    diagnostic = next(entry["message"] for entry in summary["infrastructure"] if entry["code"] == "xcresult-export-timeout")
                    self.assertIn("official " + phase + " export timed out", diagnostic)
                    self.assertIn(f"budget={export_bound}s", diagnostic)
                    self.assertIn("elapsed=", diagnostic)
                    measurements = json.loads((output / "measurements.json").read_text())
                    self.assertEqual(measurements["enumeration_budget"]["result_export_timeout_seconds"], export_bound)
                    self.assertGreaterEqual(measurements["official_export_seconds"], 0)


class ArchiveUnitResultTests(unittest.TestCase):
    def test_unscanned_records_never_reach_workflow_summary_and_cleanup_runs(self):
        import os
        import re
        import yaml
        workflow = yaml.safe_load((Path(__file__).resolve().parent.parent / ".github/workflows/ci-gate.yml").read_text())
        for platform, case in ((p, c) for p in ("ios", "tvos") for c in
                               ("no-record", "scan-refused", "preflight-failure", "select-failure", "download-failure",
                                "stage-failure", "units-failure", "units-reported-failure")):
            with self.subTest(platform=platform, case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                records = root / "unit-records"
                (root / "consumer-source").symlink_to(Path(__file__).resolve().parent.parent)
                from ci_unit_tests import PUBLIC_API_KEY
                marker = PUBLIC_API_KEY
                ctx = {"identity": {"schema_version": 1, "event": "pull_request", "repository": "owner/repo",
                       "pull_request": 2, "merge_sha": "a" * 40, "base_sha": "b" * 40,
                       "head_sha": "c" * 40, "tree_sha": "d" * 40},
                       "source": {"repository": "owner/repo", "event": "pull_request", "workflow_path": archive.WORKFLOW,
                                  "fork_originated": False, "ci_changing": None}, "run_id": "123", "attempt": 2}
                if case == "select-failure":
                    missing = urllib.error.HTTPError("https://api.github.com/artifact", 404, "Not Found", None, None)
                    with patch.object(archive, "context", return_value=ctx), patch.dict(os.environ, {"GH_TOKEN": "dummy"}), \
                            patch.object(archive, "workspace_preflight"), patch.object(archive.urllib.request, "urlopen", side_effect=missing), \
                            redirect_stderr(io.StringIO()):
                        self.assertEqual(archive.main(["select", "--platform", platform, "--artifact-id", "7",
                            "--producer-attempt", "1", "--selection-path", str(root / "selection.json"),
                            "--output-dir", str(records)]), 1)
                elif case != "no-record":
                    record = archive.record(ctx, platform, "unit-" + platform if case == "units-reported-failure" else "artifact-selection")
                    if case == "units-reported-failure":
                        record["status"] = "failed"
                    archive.write_summary(record, records)
                    if case == "scan-refused":
                        with (records / "summary.md").open("a") as handle:
                            handle.write(marker)
                        (records / "measurements.json").write_text(marker)
                relocated = root / ("consumer-relocated-" + platform)
                relocated.mkdir()
                (root / "archive-download").mkdir()
                summary = root / "step-summary.md"
                outputs = root / "step-outputs"
                job = workflow["jobs"]["unit-" + platform]
                scan_outputs = {}
                for name in ("Scan available unit records", "Display only scanned records", "Remove relocated products"):
                    step = next(step for step in job["steps"] if step["name"] == name)
                    self.assertEqual(step["if"], "always()")
                    command = step["run"].replace("${{ env.UNIT_PLATFORM }}", platform).replace(
                        "${{ steps.download.outcome }}", "failure" if case == "download-failure" else "skipped")
                    for stage in ("preflight", "select", "stage", "units"):
                        failed = case == stage + "-failure" or stage == "units" and case == "units-reported-failure"
                        command = command.replace("${{ steps." + stage + ".outcome }}",
                                                  "failure" if failed else "success" if stage in {"stage", "units"} else "skipped")
                    for key in ("records_safe", "records_produced"):
                        command = command.replace("${{ steps.record_scan.outputs." + key + " }}", scan_outputs.get(key, ""))
                    completed = subprocess.run(["bash", "-eo", "pipefail", "-c", command], capture_output=True,
                                               env={**os.environ, "RUNNER_TEMP": temporary, "GITHUB_WORKSPACE": temporary,
                                                    "GITHUB_OUTPUT": str(outputs), "GITHUB_STEP_SUMMARY": str(summary)},
                                               text=True, timeout=10)
                    expected_code = 1 if name == "Scan available unit records" and case == "scan-refused" else 0
                    self.assertEqual(completed.returncode, expected_code, completed.stderr)
                    self.assertNotIn(marker, completed.stdout)
                    self.assertNotIn(marker, completed.stderr)
                    if outputs.exists():
                        scan_outputs = dict(line.split("=", 1) for line in outputs.read_text().splitlines())
                self.assertNotIn(marker, summary.read_text())
                self.assertEqual(scan_outputs["records_safe"], "true" if case.endswith("failure") else "false")
                upload = next(step for step in job["steps"] if step["name"].startswith("Publish only unit records"))
                condition = re.sub(r"steps\.([a-z_]+)\.outputs\.records_safe",
                    lambda match: repr(scan_outputs["records_safe"] if match[1] == "record_scan" else ""),
                    upload["if"]).replace("always()", "True").replace("&&", "and")
                self.assertEqual(eval(condition, {"__builtins__": {}}, {}), case.endswith("failure"))
                if case in {"no-record", "scan-refused"}:
                    self.assertEqual(summary.read_text().strip(), "Unit records were not produced; publication is unavailable."
                        if case == "no-record" else "Unit record scanning refused publication.")
                else:
                    failure = json.loads((records / "summary.json").read_text())
                    self.assertEqual((failure["run"]["job"], failure["status"]), ("unit-" + platform, "failed"))
                    if case == "units-reported-failure":
                        self.assertEqual(failure["infrastructure"], [])
                    else:
                        self.assertIn("workspace-preflight-failed" if case == "preflight-failure" else
                                      "unit-stage-failed" if case == "stage-failure" else
                                      "unit-execution-failed" if case == "units-failure" else "archive-unavailable", summary.read_text())
                        self.assertIn("use Re-run all jobs", summary.read_text())
                self.assertFalse(relocated.exists())
                self.assertFalse((root / "archive-download").exists())

    def test_measured_timeout_uses_sample_rank_margin_rounding_and_floor(self):
        from ci_unit_tests import measured_timeout
        for completed, minimum, expected in (([40, 80], 60, 120),
                ([10], 180, 180), ([60 * value for value in range(1, 21)], 0, 1740)):
            with self.subTest(completed=completed):
                result = measured_timeout({"completed_seconds": completed},
                                          margin=1.5, minimum=minimum)
                self.assertEqual(result["timeout_seconds"], expected)
                self.assertGreaterEqual(result["timeout_seconds"], result["p95_seconds"] * 1.5)
        with self.assertRaises(ContractError):
            measured_timeout({"completed_seconds": []}, margin=1.5, minimum=60)

    def test_consumer_phase_bounds_leave_room_in_actual_workflow_jobs(self):
        import yaml
        from ci_unit_tests import enumeration_budget
        from run_offline_unit_tests import INTERRUPT_GRACE_SECONDS
        workflow = yaml.safe_load((Path(__file__).resolve().parent.parent / ".github/workflows/ci-gate.yml").read_text())
        for platform in ("ios", "tvos"):
            budget = enumeration_budget("ci", platform, result_export_timeout_seconds=180)
            job_seconds = workflow["jobs"]["unit-" + platform]["timeout-minutes"] * 60
            self.assertEqual(budget["job_timeout_seconds"], job_seconds)
            self.assertLess(budget["simulator_boot_timeout_seconds"] + budget["timeout_seconds"] +
                            budget["test_timeout_seconds"] + INTERRUPT_GRACE_SECONDS +
                            budget["overhead_allowance_seconds"], job_seconds)

    def test_official_overall_result_cannot_be_hidden_by_passing_function_counts(self):
        from ci_unit_tests import judge_execution
        from ci_summary import observation, test_identity
        from run_offline_unit_tests import TestResultsSummary
        rows = [observation(test_identity("swift", "immichSlidesTests/A/a()", platform="ios"), "passed", 0)]
        for overall, expected_status, expected_code in (("Failed", "failed", 1), ("Unknown", "unverified", 1),
                                                        ("Passed", "passed", 0)):
            with self.subTest(overall=overall):
                summary = {"population": {}, "infrastructure": [], "status": "unverified"}
                code = judge_execution(summary, {"A/a()"}, rows, TestResultsSummary(1, 1, 0, 0, overall), 0)
                self.assertEqual((code, summary["status"]), (expected_code, expected_status))
        record = {"approver": "maintainer example", "date": "2026-10-08", "tier": "unit",
                  "link": "https://github.com/example/project/issues/1#issuecomment-1"}
        rule = {"kind": "swift", "key_pattern": rows[0]["identity"]["key"], "dimensions": {"platform": "ios"},
                "tier": "unit", "environment": "hermetic", "reason": "no fixture"}
        skipped = [observation(rows[0]["identity"], "skipped", 0, reason="no fixture")]
        for records, reason, rules, status, expected_code in (
                ([record], "no fixture", [rule], "passed", 0),
                ([], "no fixture", [rule], "unverified", 0),
                ([record], "changed reason", [rule], "failed", 1),
                ([record], "no fixture", [], "failed", 1)):
            with self.subTest(records=records, reason=reason, rules=rules):
                summary = {"population": {}, "infrastructure": [], "status": "unverified"}
                skipped[0]["attempts"][0]["reason"] = reason
                unit_policy = {"schema_version": 1, "approval_records": records, "expected_skips": rules, "deselections": []}
                code = judge_execution(summary, {"A/a()"}, skipped, TestResultsSummary(1, 0, 0, 1, "Passed"), 0, unit_policy)
                self.assertEqual((code, summary["status"]), (expected_code, status))

    def test_enumeration_errors_or_empty_unit_population_cannot_pass(self):
        from ci_unit_tests import enumeration_keys
        duplicate = {"errors": [], "values": [{"kind": "target", "name": "immichSlidesTests", "children": [
            {"kind": "class", "name": "A", "children": [{"kind": "test", "name": "a()"},
                                                         {"kind": "test", "name": "a()"}]}]}]}
        for payload in ({"errors": ["bootstrap failed"], "values": []}, {"errors": [], "values": []}, duplicate,
                        {"errors": [], "values": [{"kind": "target", "name": "immichSlidesUITests", "children": [
                            {"kind": "class", "name": "A", "children": [{"kind": "test", "name": "a()"}]}]}]}):
            with self.subTest(payload=payload), self.assertRaises(ContractError):
                enumeration_keys(payload)

    def test_compiled_missing_or_extra_execution_cannot_be_hidden_by_passing_counts(self):
        from ci_unit_tests import compare_execution
        for compiled, observed in (({"A/a()", "B/b()"}, {"A/a()"}), ({"A/a()"}, {"A/a()", "B/b()"})):
            with self.subTest(compiled=compiled), self.assertRaises(ContractError):
                compare_execution(compiled, observed)
        compare_execution({"A/a()"}, {"A/a()"})

    def test_official_failed_parameter_and_skip_reason_are_preserved(self):
        from ci_unit_tests import result_observations, judge_execution
        from run_offline_unit_tests import TestResultsSummary
        function_message = "Expectation failed: function value\nSecond diagnostic line"
        parameter_message = "Expectation failed: " + "x" * 250 + "\nSecond diagnostic line"
        payload = {"testNodes": [{"nodeType": "Unit test bundle", "name": "immichSlidesTests", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": "A/a()", "result": "Failed", "duration": "0.25s",
             "children": [{"nodeType": "Failure Message", "name": function_message},
                          {"nodeType": "Test Case Run", "nodeIdentifier": "A/a()/argument:2", "name": "argument:2",
                           "result": "Failed", "duration": "0.25s", "children": [
                               {"nodeType": "Failure Message", "name": parameter_message}]}]},
            {"nodeType": "Test Case", "nodeIdentifier": "B/b()", "result": "Skipped", "duration": "0s"},
        ]}]}
        rows = result_observations(payload, "ios", {"B/b()": "No local live config"})
        self.assertEqual([row["outcome"] for row in rows], ["failed", "failed", "skipped"])
        self.assertEqual(rows[1]["identity"]["dimensions"]["parameter"], "A/a()/argument:2")
        self.assertEqual(rows[2]["attempts"][0]["reason"], "No local live config")
        self.assertEqual(rows[0]["attempts"][0]["message"], function_message.splitlines()[0])
        self.assertEqual(rows[1]["attempts"][0]["message"], parameter_message.splitlines()[0][:200])
        summary = {"population": {}, "infrastructure": [], "status": "unverified"}
        code = judge_execution(summary, {"A/a()", "B/b()"}, rows, TestResultsSummary(2, 0, 1, 1, "Failed"), 65)
        self.assertEqual((code, summary["status"], summary["infrastructure"]), (65, "failed", []))
        with self.assertRaisesRegex(ContractError, "skip reason"):
            result_observations(payload, "ios", {})


class LiveBoundaryTests(unittest.TestCase):
    def test_live_scope_selects_from_the_full_catalog_but_refuses_unowned_or_missing_live_tests(self):
        import ci_live_tests as live
        from ci_summary import test_identity
        suite = live.SUITES[0]
        declared = [test_identity('swift', suite+'/works', platform='ios')]
        classes = [{'kind': 'class', 'name': suite, 'children': [{'kind': 'test', 'name': 'works()'}]},
                   {'kind': 'class', 'name': 'OfflineTests', 'children': [{'kind': 'test', 'name': 'offline()'}]}]
        def catalog(children):
            return {'errors': [], 'values': [{'kind': 'target', 'name': 'immichSlidesTests', 'children': children}]}
        self.assertEqual(live.compiled_live_keys(catalog(classes), declared), {suite+'/works()'})
        for children in (classes[1:], classes+[{'kind': 'class', 'name': 'UnownedLiveTests',
                                              'children': [{'kind': 'test', 'name': 'extra()'}]}]):
            with self.subTest(children=children), self.assertRaises(ContractError):
                live.compiled_live_keys(catalog(children), declared)

    def test_failed_canary_preparation_keeps_a_scanned_shared_failure_summary(self):
        import argparse
        import ci_live_tests as live
        from ci_summary import parse_summary
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            identity = {'schema_version': 1, 'event': 'pull_request', 'repository': 'owner/repo',
                        'pull_request': 2, 'merge_sha': 'a' * 40, 'base_sha': 'b' * 40,
                        'head_sha': 'c' * 40, 'tree_sha': 'd' * 40}
            selection = {'identity': identity, 'source': {'repository': 'owner/repo', 'event': 'pull_request',
                'workflow_path': live.WORKFLOW, 'fork_originated': False, 'ci_changing': None},
                'run_id': '123', 'attempt': 2, 'platform': 'ios', 'artifact_id': 7, 'producer_attempt': 1}
            args = argparse.Namespace(canary=True, output_dir=root/'public', private_dir=root/'private',
                                      relocated_path=root/'relocated', archive_dir=root/'archive', min_free_gib=80)
            url, key = live.canary_values('123', 2)
            env = {'CI_LIVE_URL': url, 'CI_LIVE_KEY': key, 'GITHUB_OUTPUT': str(root/'outputs')}
            with patch.dict('os.environ', env), patch.object(live.archive, 'workspace_preflight',
                    side_effect=ContractError(key)), redirect_stdout(io.StringIO()), self.assertRaises(ContractError):
                live.execute_live(args, selection)
            record = parse_summary((args.output_dir/'live-summary.json').read_text())
            self.assertEqual(record['status'], 'failed')
            self.assertEqual(record['infrastructure'][0]['code'], 'live-archive-failed')
            self.assertIn('records_safe=true', (root/'outputs').read_text())
            self.assertFalse((args.output_dir/'canary.json').exists())
            self.assertFalse(args.private_dir.exists())
            live.scan_tree(args.output_dir, live.secret_forms(url, key))

    def test_nightly_archive_provenance_and_live_suite_ownership_fail_closed(self):
        import ci_live_tests as live
        from ci_summary import test_identity
        self.assertEqual(archive.producer_workflow({"event": "schedule"}), live.WORKFLOW)
        self.assertEqual(archive.producer_workflow({"event": "pull_request"}), archive.WORKFLOW)
        with patch.dict('os.environ', {'GITHUB_WORKFLOW_REF': 'owner/repo/' + live.WORKFLOW + '@refs/pull/2/merge'}):
            self.assertEqual(archive.producer_workflow({'event': 'pull_request', 'repository': 'owner/repo'}), live.WORKFLOW)
        with patch.dict('os.environ', {'GITHUB_WORKFLOW_REF': 'other/repo/' + live.WORKFLOW + '@refs/pull/2/merge'}):
            self.assertEqual(archive.producer_workflow({'event': 'pull_request', 'repository': 'owner/repo'}), archive.WORKFLOW)
        declared = [test_identity("swift", suite + "/works", platform="ios")
                    for suite in (*live.SUITES, "PerformanceLiveIntegrationTests")]
        self.assertEqual(len(live.live_declarations(declared)), len(live.SUITES))
        for changed in (declared[:-2], declared + [test_identity("swift", "UnownedLiveTests/works", platform="ios")]):
            with self.subTest(count=len(changed)), self.assertRaises(ContractError):
                live.live_declarations(changed)

    def test_live_admission_refuses_events_actors_refs_and_non_main_ancestry(self):
        import ci_live_tests as live
        env = {"GITHUB_REPOSITORY": "sudoHG/immichSlides", "GITHUB_EVENT_NAME": "workflow_dispatch",
               "GITHUB_REF": "refs/heads/main", "GITHUB_ACTOR": "sudoHG", "GITHUB_TRIGGERING_ACTOR": "sudoHG",
               "GITHUB_WORKFLOW_REF": "sudoHG/immichSlides/.github/workflows/ci-nightly.yml@refs/heads/main",
               "GITHUB_SHA": "a" * 40}
        self.assertEqual(live.admission(env, {}, "a" * 40, True), "admitted")
        for key, value in (("GITHUB_EVENT_NAME", "push"), ("GITHUB_ACTOR", "outsider"),
                           ("GITHUB_TRIGGERING_ACTOR", "outsider"), ("GITHUB_REF", "refs/heads/branch"),
                           ("GITHUB_WORKFLOW_REF", "sudoHG/immichSlides/.github/workflows/other.yml@refs/heads/main"),
                           ("GITHUB_REPOSITORY", "fork/immichSlides")):
            with self.subTest(key=key), self.assertRaises(ContractError):
                live.admission(dict(env, **{key: value}), {}, "a" * 40, True)
        for head, ancestor in (("b" * 40, True), ("a" * 40, False)):
            with self.subTest(head=head, ancestor=ancestor), self.assertRaises(ContractError):
                live.admission(env, {}, head, ancestor)
        for fork in (False, True):
            event = {"pull_request": {"head": {"repo": {"full_name": "fork/repo" if fork else "sudoHG/immichSlides"}}}}
            self.assertEqual(live.admission(dict(env, GITHUB_EVENT_NAME="pull_request"), event, None, False),
                             "fork-skipped" if fork else "pr-skipped")

    def test_live_secret_scan_rejects_raw_and_transformed_bytes_across_chunk_boundaries(self):
        import ci_live_tests as live
        values = ("https://canary.invalid/a path?x=\"quoted\"", "canary-key-abcdefghijklmnop")
        needles = live.secret_forms(*values)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture"
            for value in values:
                for offset in range(3):
                    for encode in (base64.b64encode, base64.urlsafe_b64encode):
                        with self.subTest(offset=offset, alphabet=encode.__name__), self.assertRaises(ContractError):
                            path.write_bytes(encode(b'x' * offset + value.encode() + b'tail'))
                            live.scan_file(path, needles)
            path.write_bytes(b"safe compact record")
            live.scan_file(path, needles)
            for needle in needles:
                with self.subTest(length=len(needle)), self.assertRaises(ContractError):
                    path.write_bytes(b"x" * (1024 * 1024 - 2) + needle)
                    live.scan_file(path, needles)

    def test_canary_audit_requires_nonempty_logs_and_matching_run_attempt_results(self):
        import ci_live_tests as live
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in (root / 'missing', root):
                with self.subTest(path=path), self.assertRaises(ContractError):
                    live.audit_canary(path, '123', 2)
            logs = root / 'logs'
            logs.mkdir()
            (logs / 'job.txt').write_text('complete public job log')
            results = root / 'artifacts' / 'live-canary-ios-123-2'
            results.mkdir(parents=True)
            verdict = {'schema_version': 1, 'status': 'passed', 'run_id': '123', 'attempt': 2,
                       'platform': 'ios', 'execution_failed': True}
            (results / 'canary.json').write_text(json.dumps(verdict))
            with self.assertRaises(ContractError):
                live.audit_canary(root, '123', 2)
            identity = {'schema_version': 1, 'event': 'pull_request', 'repository': 'owner/repo',
                        'pull_request': 2, 'merge_sha': 'a' * 40, 'base_sha': 'b' * 40,
                        'head_sha': 'c' * 40, 'tree_sha': 'd' * 40}
            summary = archive.record({'identity': identity, 'source': {
                'repository': 'owner/repo', 'event': 'pull_request', 'workflow_path': live.WORKFLOW,
                'fork_originated': False, 'ci_changing': None}, 'run_id': '123', 'attempt': 2}, 'ios', 'live-canary')
            from ci_summary import observation, test_identity
            test = test_identity('swift', 'ExampleLiveTests/works', platform='ios')
            summary['run']['tier'] = 'live-unit'
            summary['population'].update(declared=[test], compiled=[test], observed=[observation(test, 'failed', 1, exit_code=65)])
            summary.update(status='failed')
            (results / 'live-summary.json').write_text(json.dumps(summary))
            (results / 'live-summary.md').write_text('Failed live pipeline summary')
            live.audit_canary(root, '123', 2)
            for mutation in ('attempt', 'empty-log', 'leak'):
                with self.subTest(mutation=mutation), self.assertRaises(ContractError):
                    if mutation == 'attempt':
                        live.audit_canary(root, '123', 3)
                    else:
                        (logs / 'job.txt').write_text('' if mutation == 'empty-log' else live.canary_values('123', 2)[1])
                        live.audit_canary(root, '123', 2)

    def test_live_summary_requires_complete_passing_function_and_parameter_outcomes(self):
        import ci_live_tests as live
        from ci_summary import observation, test_identity, validate_observation
        from run_offline_unit_tests import TestResultsSummary
        declared = [test_identity("swift", "ExampleLiveTests/works", platform="ios")]
        row = observation(test_identity("swift", "immichSlidesTests/ExampleLiveTests/works()", platform="ios"), "passed", 1)
        counts = TestResultsSummary(1, 1, 0, 0, "Passed")
        self.assertEqual(live.public_outcomes(declared, {"ExampleLiveTests/works()"}, [row], counts, 0)[0]["outcome"], "passed")
        parameter = copy.deepcopy(row)
        parameter["identity"]["dimensions"]["parameter"] = "private URL-bearing arguments"
        self.assertNotIn("private", json.dumps(live.public_outcomes(declared, {"ExampleLiveTests/works()"}, [row, parameter], counts, 0)))
        outcomes = live.public_outcomes(declared, {'ExampleLiveTests/works()'}, [row, parameter], counts, 0)
        for entry in outcomes:
            validate_observation(entry)
        self.assertEqual(outcomes[1]['identity']['dimensions']['parameter'], 'case-0')
        for rows, compiled, code, result in (([], {"ExampleLiveTests/works()"}, 0, counts),
                                            ([row], set(), 0, counts), ([row], {"ExampleLiveTests/works()"}, 65, counts),
                                            ([dict(row, outcome="skipped", reason="missing server")], {"ExampleLiveTests/works()"}, 0, counts),
                                            ([row, dict(parameter, outcome="failed")], {"ExampleLiveTests/works()"}, 0, counts),
                                            ([row, parameter, parameter], {"ExampleLiveTests/works()"}, 0, counts),
                                            ([row, dict(row, identity=test_identity('swift', 'immichSlidesTests/OtherTests/extra()', platform='ios'))],
                                             {'ExampleLiveTests/works()'}, 0, TestResultsSummary(2, 2, 0, 0, 'Passed')),
                                            ([dict(row, duration_seconds=float("inf"))], {"ExampleLiveTests/works()"}, 0, counts),
                                            ([row], {"ExampleLiveTests/works()"}, 0, TestResultsSummary(1, 1, 0, 0, "Failed"))):
            with self.subTest(code=code, rows=len(rows)), self.assertRaises(ContractError):
                live.public_outcomes(declared, compiled, rows, result, code)


if __name__ == "__main__":
    unittest.main()
