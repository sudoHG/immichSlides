"""Regression coverage for local configuration isolation and tested-tree identity."""

import os
import json
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import ci_local
from ci_local import SnapshotCleanupError, clean_environment, local_main, select_mode, snapshot


class LocalModeTests(unittest.TestCase):
    def test_interrupt_finalizes_detached_build_before_disposing_the_snapshot(self):
        for signum in (None, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum), tempfile.TemporaryDirectory() as directory:
                root = Path(directory, "repo")
                scripts = root / "scripts"
                scripts.mkdir(parents=True)
                for name in ("ci_local.py", "run_offline_unit_tests.py"):
                    shutil.copyfile(Path(__file__).with_name(name), scripts / name)
                runner = scripts / "run_fixture_ui_tests.py"
                runner.write_text("import json, subprocess, sys, time\nfrom pathlib import Path\n"
                                  "from ci_local import local_main\n"
                                  "from run_offline_unit_tests import default_run\n"
                                  "def main():\n"
                                  "    output = Path(sys.argv[2])\n"
                                  "    code = \"import json, os, time; from pathlib import Path\\n\"\n"
                                  "    code += \"root = Path.cwd(); output = Path(\" + repr(str(output)) + \")\\n\"\n"
                                  "    code += \"(output / 'ready.json').write_text(json.dumps({'pid': os.getpid(), 'root': str(root)}))\\n\"\n"
                                  "    code += \"try: time.sleep(300)\\nfinally: (output / 'finalized.json').write_text(json.dumps({'snapshot_present': root.exists()}))\\n\"\n"
                                  "    if output.name == 'normal':\n"
                                  "        subprocess.Popen([sys.executable, '-c', code], start_new_session=True)\n"
                                  "        time.sleep(1.5)\n"
                                  "        return 0\n"
                                  "    return default_run([sys.executable, '-c', code], grace_seconds=2)\n"
                                  "if __name__ == '__main__': raise SystemExit(local_main(main, __file__))\n")
                subprocess.run(["git", "init", "-q", str(root)], check=True)
                for key, value in (("user.name", "immichSlides local snapshot"), ("user.email", "local-snapshot@invalid")):
                    subprocess.run(["git", "config", key, value], cwd=root, check=True)
                subprocess.run(["git", "add", "."], cwd=root, check=True)
                subprocess.run(["git", "commit", "-qm", "initial"], cwd=root, check=True)
                output = Path(directory, "normal" if signum is None else "output")
                output.mkdir()
                with (output / "runner.log").open("w") as log:
                    process = subprocess.Popen([sys.executable, "-B", str(runner), "--output-dir", str(output)],
                                               cwd=root, env=clean_environment(os.environ), stdout=log,
                                               stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        deadline = time.monotonic() + 15
                        while not (output / "ready.json").exists() and time.monotonic() < deadline:
                            if process.poll() is not None:
                                break
                            time.sleep(.05)
                        self.assertTrue((output / "ready.json").exists(), (output / "runner.log").read_text())
                        ready = json.loads((output / "ready.json").read_text())
                        if signum is not None:
                            process.send_signal(signum)
                        self.assertEqual(process.wait(timeout=15), 0 if signum is None else 128 + signum,
                                         (output / "runner.log").read_text())
                        self.assertTrue(json.loads((output / "finalized.json").read_text())["snapshot_present"])
                        self.assertFalse(Path(ready["root"]).exists())
                        with self.assertRaises(ProcessLookupError):
                            os.kill(ready["pid"], 0)
                    finally:
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                        if (output / "ready.json").exists():
                            build_pid = json.loads((output / "ready.json").read_text())["pid"]
                            try:
                                os.killpg(build_pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass

    def test_entry_point_tests_the_snapshot_and_explicit_mode_without_recursing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory, "repo")
            scripts = root / "scripts"
            scripts.mkdir(parents=True)
            shutil.copyfile(Path(__file__).with_name("ci_local.py"), scripts / "ci_local.py")
            runner = scripts / "run_offline_unit_tests.py"
            runner.write_text("import argparse, os\nfrom pathlib import Path\nfrom ci_local import local_main\n"
                              "def main():\n"
                              "    root = Path(__file__).resolve().parent.parent\n"
                              "    parser = argparse.ArgumentParser(allow_abbrev=False)\n"
                              "    parser.add_argument('--project')\n"
                              "    parser.add_argument('--derived-data-path')\n"
                              "    parser.add_argument('--result-bundle-path')\n"
                              "    parser.add_argument('--prepare-example-config', action='store_true')\n"
                              "    parser.add_argument('--platform')\n"
                              "    parser.add_argument('--full-plan', action='store_true')\n"
                              "    parser.add_argument('--check', action='store_true')\n"
                              "    parser.add_argument('--manifest')\n"
                              "    parser.add_argument('--ui-record')\n"
                              "    parser.add_argument('--output-dir')\n"
                              "    parser.add_argument('--shard')\n"
                              "    parser.add_argument('command', nargs='?')\n"
                              "    args = parser.parse_args()\n"
                              "    print('DERIVED_DATA=' + str(args.derived_data_path))\n"
                              "    print('RESULT_BUNDLE=' + str(args.result_bundle_path))\n"
                              "    print('MANIFEST=' + str(args.manifest))\n"
                              "    print('UI_RECORD=' + str(args.ui_record))\n"
                              "    if args.prepare_example_config and (args.platform or args.full_plan):\n"
                              "        return 71\n"
                              "    if args.project and Path(args.project).resolve() != root / 'immichSlides.xcodeproj':\n"
                              "        return 3\n"
                              "    private = os.path.lexists(root / 'Config/env.xcconfig')\n"
                              "    return 0 if private == (os.environ.get('IMMICH_TEST_EXPECT_PRIVATE') == '1') "
                              "and os.environ.get('IMMICH_TEST_API_KEY') == 'explicit' else 1\n"
                              "if __name__ == '__main__':\n    raise SystemExit(local_main(main, __file__))\n")
            shutil.copyfile(runner, scripts / "ci_ui_tests.py")
            (root / ".gitignore").write_text("Config/env.xcconfig\n")
            (root / "immichSlides.xcodeproj").mkdir()
            (root / "immichSlides.xcodeproj/project.pbxproj").write_text("synthetic project")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            for key, value in (("user.name", "immichSlides local snapshot"), ("user.email", "local-snapshot@invalid")):
                subprocess.run(["git", "config", key, value], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "initial"], cwd=root, check=True)
            (root / "Config").mkdir()
            (root / "Config/env.xcconfig").symlink_to(root / "never-open-this")
            (root / "untracked").write_text("working-tree change")
            test_environment = {**clean_environment(os.environ), "IMMICH_TEST_API_KEY": "ambient"}
            for mode, flag in (("snapshot", None), ("strict", "--strict-ci"),
                               ("private", "--allow-private-config")):
                with self.subTest(mode=mode, flag=flag):
                    record = Path(directory, (flag or mode).replace("-", "") + ".json")
                    args = [sys.executable, "-B", str(runner), "--config", "IMMICH_TEST_API_KEY=explicit",
                            "--snapshot-record", str(record)]
                    if flag:
                        args += [flag]
                    if mode == "private":
                        args += ["--config", "IMMICH_TEST_EXPECT_PRIVATE=1"]
                    completed = subprocess.run(args, cwd=root, env=test_environment,
                                               capture_output=True, text=True, timeout=15)
                    self.assertEqual(completed.returncode, 2 if mode == "strict" else 0, completed.stderr)
                    if mode != "strict":
                        receipt = json.loads(record.read_text())
                        self.assertEqual(receipt["mode"], mode)
                        self.assertEqual(receipt["exit_code"], 0)
                        self.assertNotIn("explicit", record.read_text().replace("explicit_configuration_keys", ""))
                        original_record = record.read_bytes()
                        repeated = subprocess.run(args, cwd=root, env=test_environment, capture_output=True, text=True, timeout=15)
                        self.assertEqual(repeated.returncode, 2)
                        self.assertEqual(record.read_bytes(), original_record)
            self.assertTrue((root / "Config/env.xcconfig").is_symlink())
            for project_args in (["--project", str(root / "immichSlides.xcodeproj")],
                                 ["--project=" + str(root / "immichSlides.xcodeproj")]):
                with self.subTest(project_args=project_args):
                    completed = subprocess.run([sys.executable, "-B", str(runner), "--config",
                                                "IMMICH_TEST_API_KEY=explicit", *project_args], cwd=root,
                                               env=test_environment, capture_output=True, text=True, timeout=15)
                    self.assertEqual(completed.returncode, 0, completed.stderr)
            for project_args in (["--project", str(Path(directory, "outside.xcodeproj"))],
                                 ["--project=" + str(Path(directory, "outside.xcodeproj"))]):
                with self.subTest(outside_project=project_args):
                    completed = subprocess.run([sys.executable, "-B", str(runner), *project_args], cwd=root,
                                               env=test_environment, capture_output=True, text=True, timeout=15)
                    self.assertEqual(completed.returncode, 2, completed.stderr)
            for setup_args in (["--prepare-example-config"], ["--prepare-example-config", "--check"]):
                with self.subTest(setup_only=setup_args):
                    completed = subprocess.run([sys.executable, "-B", str(runner), *setup_args,
                                                "--config", "IMMICH_TEST_API_KEY=explicit", "--config",
                                                "IMMICH_TEST_EXPECT_PRIVATE=1"], cwd=root, env=test_environment,
                                               capture_output=True, text=True, timeout=15)
                    self.assertEqual(completed.returncode, 0, completed.stderr)
            for setup_args in (["--prepare-example-config", "--platform=ios"],
                               ["--prepare-example-config", "--platform", "ios"],
                               ["--prepare-example-config", "--full-plan"]):
                with self.subTest(setup_build=setup_args):
                    completed = subprocess.run([sys.executable, "-B", str(runner), *setup_args], cwd=root,
                                               env=test_environment, capture_output=True, text=True, timeout=15)
                    self.assertEqual(completed.returncode, 2, completed.stderr)
            for flags in (["--derived-data-path", "cache", "--result-bundle-path", "results.xcresult"],
                          ["--derived-data=cache", "--result-bundle=results.xcresult"]):
                with self.subTest(paths=flags):
                    completed = subprocess.run([sys.executable, "-B", str(runner), "--config",
                                                "IMMICH_TEST_API_KEY=explicit", *flags], cwd=root,
                                               env=test_environment, capture_output=True, text=True, timeout=15)
                    self.assertEqual(completed.returncode, 0, completed.stderr)
                    self.assertIn("DERIVED_DATA=" + str((root / "cache").resolve()), completed.stdout)
                    self.assertIn("RESULT_BUNDLE=" + str((root / "results.xcresult").resolve()), completed.stdout)
            completed = subprocess.run([sys.executable, "-B", str(runner), "--config",
                                        "IMMICH_TEST_API_KEY=explicit"], cwd=root, env=test_environment,
                                       capture_output=True, text=True, timeout=15)
            self.assertIn("DERIVED_DATA=" + str((root / ".derivedData/offline-local").resolve()), completed.stdout)
            for input_args, label, filename in ((["--manifest", "m.json"], "MANIFEST", "m.json"),
                                                (["--manifest=m.json"], "MANIFEST", "m.json"),
                                                (["--ui-record", "ui.json"], "UI_RECORD", "ui.json"),
                                                (["--ui-record=ui.json"], "UI_RECORD", "ui.json")):
                with self.subTest(input_args=input_args):
                    completed = subprocess.run([sys.executable, "-B", str(runner), "--config",
                                                "IMMICH_TEST_API_KEY=explicit", *input_args], cwd=scripts,
                                               env=test_environment, capture_output=True, text=True, timeout=15)
                    self.assertEqual(completed.returncode, 0, completed.stderr)
                    self.assertIn(label + "=" + str((scripts / filename).resolve()), completed.stdout)
            written = Path(directory, "written")
            written.mkdir()
            receipt_path = written / "local-snapshot.json"
            receipt_path.write_text("earlier run receipt\n")
            ui_runner = scripts / "ci_ui_tests.py"
            for arguments, expected in ((["check-upload", "--output-dir", str(written)], 0),
                                        (["run", "--shard", "check-upload", "--output-dir", str(written)], 2)):
                with self.subTest(arguments=arguments):
                    completed = subprocess.run([sys.executable, "-B", str(ui_runner), *arguments, "--config",
                                                "IMMICH_TEST_API_KEY=explicit"], cwd=root, env=test_environment,
                                               capture_output=True, text=True, timeout=15)
                    self.assertEqual(completed.returncode, expected, completed.stderr)
                    self.assertEqual(receipt_path.read_text(), "earlier run receipt\n")

    def test_slow_process_probe_does_not_interrupt_a_running_child(self):
        probe = ci_local.process_states
        calls = []

        def times_out_once():
            calls.append(None)
            if len(calls) == 1:
                raise subprocess.TimeoutExpired("ps", 30)
            return probe()

        with tempfile.TemporaryDirectory() as directory:
            finished = Path(directory, "finished")
            child = [sys.executable, "-c", f"import time; time.sleep(2.5); open({str(finished)!r}, 'w').close()"]
            environment = {**os.environ, ci_local.RUN_TOKEN: "slow-probe-token"}
            with patch("ci_local.process_states", side_effect=times_out_once):
                self.assertEqual(ci_local.run_child(child, directory, environment), 0)
            self.assertTrue(finished.exists())
            self.assertGreater(len(calls), 1)

    def test_group_orphaned_during_a_failed_probe_is_stopped_or_reported(self):
        token = "orphan-probe-token"
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory, "orphan.pid")
            orphan = "import time\ntry:\n    time.sleep(60)\nexcept KeyboardInterrupt:\n    pass"
            child = [sys.executable, "-c",
                     "import subprocess, sys; "
                     f"p = subprocess.Popen([sys.executable, '-c', {orphan!r}], start_new_session=True); "
                     f"open({str(pid_file)!r}, 'w').write(str(p.pid))"]
            environment = {**os.environ, ci_local.RUN_TOKEN: token}
            probe = ci_local.process_states
            calls = []

            def fails_first():
                calls.append(None)
                if len(calls) == 1:
                    raise subprocess.TimeoutExpired("ps", 30)
                return probe()

            try:
                with patch("ci_local.process_states", side_effect=fails_first):
                    self.assertEqual(ci_local.run_child(child, directory, environment), 0)
                orphan_pid = int(pid_file.read_text())
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try:
                        os.kill(orphan_pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(.05)
                else:
                    self.fail("the orphaned process group survived cleanup")
            finally:
                if pid_file.exists():
                    try:
                        os.kill(int(pid_file.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_private_configuration_requires_explicit_opt_in(self):
        with self.assertRaises(ValueError):
            select_mode(["--strict-ci", "--allow-private-config"])

    def test_ambient_inputs_are_removed_and_only_explicit_inputs_are_restored(self):
        source = {"PATH": "/bin", "IMMICH_TEST_API_KEY": "ambient",
                  "TEST_RUNNER_SIMCTL_CHILD_IMMICH_SERVER_URL": "ambient",
                  "STRICT_E2E_REVIEWED_SCREENSHOTS": "/ambient", "ENABLE_DEBUG_AUTO_SERVER": "1",
                  "UI_TEST_EVIDENCE_DIR": "/ambient", "XCODE_XCCONFIG_FILE": "/private",
                  "GITHUB_ACTIONS": "true", "GITHUB_OUTPUT": "/ambient"}
        self.assertEqual(clean_environment(source), {"PATH": "/bin"})
        self.assertEqual(clean_environment(source, ["IMMICH_TEST_API_KEY=explicit"]),
                         {"PATH": "/bin", "IMMICH_TEST_API_KEY": "explicit"})
        for invalid in ("missing-value", "PATH=/other", "IMMICH_TEST_API_KEY=a\nvalue"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                clean_environment(source, [invalid])

    def test_snapshot_tests_working_files_without_moving_refs_or_index_or_reading_private_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory, "repo")
            root.mkdir()
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True).strip()
            git("init", "-q")
            git("config", "user.name", "immichSlides local snapshot")
            git("config", "user.email", "local-snapshot@invalid")
            (root / ".gitignore").write_text("Config/env.xcconfig\nignored\nforced\n")
            (root / "tracked").write_text("committed")
            (root / "deleted").write_text("committed")
            git("add", ".")
            git("commit", "-qm", "initial")
            head = git("rev-parse", "HEAD")
            (root / "forced").write_text("force-added working content")
            git("add", "--force", "forced")
            (root / "tracked").write_text("staged")
            git("add", "tracked")
            (root / "tracked").write_text("uncommitted failure")
            (root / "deleted").unlink()
            git("add", "deleted")
            (root / "staged then deleted").write_text("staged new")
            git("add", "staged then deleted")
            (root / "staged then deleted").unlink()
            index = (root / ".git/index").read_bytes()
            (root / "new file").write_text("new")
            (root / "ignored").write_text("ignore")
            (root / "Config").mkdir()
            # A dangling link proves snapshot construction never opens its target.
            (root / "Config/env.xcconfig").symlink_to(root / "unreadable-private-target")
            with snapshot(root) as (checkout, receipt):
                self.assertEqual((checkout / "tracked").read_text(), "uncommitted failure")
                self.assertEqual((checkout / "new file").read_text(), "new")
                self.assertEqual((checkout / "forced").read_text(), "force-added working content")
                self.assertEqual(subprocess.check_output(["git", "show", "-s", "--format=%an <%ae>"],
                                                         cwd=checkout, text=True).strip(),
                                 "immichSlides local snapshot <local-snapshot@invalid>")
                self.assertFalse((checkout / "deleted").exists())
                self.assertFalse((checkout / "staged then deleted").exists())
                self.assertFalse((checkout / "ignored").exists())
                self.assertFalse(os.path.lexists(checkout / "Config/env.xcconfig"))
                self.assertEqual(subprocess.check_output(["git", "status", "--porcelain"], cwd=checkout), b"")
                self.assertEqual(subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=checkout,
                                                        text=True).strip(), receipt["tree_sha"])
                self.assertTrue(receipt["source_dirty"])
            self.assertFalse(checkout.exists())
            self.assertEqual(git("rev-parse", "HEAD"), head)
            self.assertEqual((root / ".git/index").read_bytes(), index)
            self.assertTrue((root / "Config/env.xcconfig").is_symlink())
            with snapshot(root) as (_, repeated):
                self.assertEqual(repeated["tree_sha"], receipt["tree_sha"])
                self.assertEqual(repeated["commit_sha"], receipt["commit_sha"])
            with self.assertRaises(ValueError):
                with snapshot(root, strict=True):
                    self.fail("strict mode accepted a dirty tree")
            retained = None
            try:
                with self.assertRaises(SnapshotCleanupError):
                    with snapshot(root) as (retained, _):
                        raise SnapshotCleanupError("synthetic unverified cleanup")
                self.assertTrue(retained.is_dir())
                self.assertIn(str(retained), git("worktree", "list", "--porcelain"))
            finally:
                if retained is not None:
                    git("worktree", "remove", "--force", str(retained))
                    shutil.rmtree(retained.parent)
            entry = root / "scripts/run_fixture_ui_tests.py"
            entry.parent.mkdir()
            entry.write_text("pass\n")
            record = Path(directory, "receipt.json")
            held = {}
            def escaped_child(command, checkout, environment):
                held["root"] = checkout
                held["process"] = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                                   cwd=checkout, start_new_session=True)
                return 0
            try:
                # Exercise local launch even when this suite runs on hosted CI.
                with patch.dict(os.environ, clean_environment(os.environ), clear=True), \
                        patch("ci_local.run_child", side_effect=escaped_child), \
                        patch.object(sys, "argv", [str(entry), "--snapshot-record", str(record)]):
                    self.assertEqual(local_main(lambda: 0, str(entry)), 2)
                retained = held["root"]
                self.assertTrue(retained.is_dir())
                self.assertEqual(json.loads(record.read_text())["exit_code"], 2)
            finally:
                process = held.get("process")
                if process is not None and process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                retained = held.get("root")
                if retained is not None and retained.exists():
                    git("worktree", "remove", "--force", str(retained))
                if retained is not None and retained.parent.exists():
                    shutil.rmtree(retained.parent)


if __name__ == "__main__":
    unittest.main()
