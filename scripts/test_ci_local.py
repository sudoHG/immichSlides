"""Regression coverage for local configuration isolation and tested-tree identity."""

import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from ci_local import clean_environment, select_mode, snapshot


class LocalModeTests(unittest.TestCase):
    def test_entry_point_tests_the_snapshot_and_explicit_mode_without_recursing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory, "repo")
            scripts = root / "scripts"
            scripts.mkdir(parents=True)
            shutil.copyfile(Path(__file__).with_name("ci_local.py"), scripts / "ci_local.py")
            runner = scripts / "run.py"
            runner.write_text("import os\nfrom pathlib import Path\nfrom ci_local import local_main\n"
                              "def main():\n"
                              "    private = os.path.lexists(Path(__file__).resolve().parent.parent / 'Config/env.xcconfig')\n"
                              "    return 0 if private == (os.environ.get('IMMICH_TEST_EXPECT_PRIVATE') == '1') "
                              "and os.environ.get('IMMICH_TEST_API_KEY') == 'explicit' else 1\n"
                              "if __name__ == '__main__':\n    raise SystemExit(local_main(main, __file__))\n")
            (root / ".gitignore").write_text("Config/env.xcconfig\n")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            for key, value in (("user.name", "sudoHG"), ("user.email", "by331works@gmail.com")):
                subprocess.run(["git", "config", key, value], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "initial"], cwd=root, check=True)
            (root / "Config").mkdir()
            (root / "Config/env.xcconfig").symlink_to(root / "never-open-this")
            (root / "untracked").write_text("working-tree change")
            import sys
            for mode in ("snapshot", "strict", "private"):
                with self.subTest(mode=mode):
                    record = Path(directory, mode + ".json")
                    args = [sys.executable, "-B", str(runner), "--config", "IMMICH_TEST_API_KEY=explicit",
                            "--snapshot-record", str(record)]
                    if mode == "strict":
                        args += ["--strict-ci"]
                    elif mode == "private":
                        args += ["--allow-private-config", "--config", "IMMICH_TEST_EXPECT_PRIVATE=1"]
                    completed = subprocess.run(args, cwd=root, env={**os.environ, "IMMICH_TEST_API_KEY": "ambient"},
                                               capture_output=True, text=True, timeout=15)
                    self.assertEqual(completed.returncode, 2 if mode == "strict" else 0, completed.stderr)
                    if mode != "strict":
                        receipt = json.loads(record.read_text())
                        self.assertEqual(receipt["mode"], mode)
                        self.assertEqual(receipt["exit_code"], 0)
                        self.assertNotIn("explicit", record.read_text().replace("explicit_configuration_keys", ""))
            self.assertTrue((root / "Config/env.xcconfig").is_symlink())

    def test_private_configuration_requires_explicit_opt_in(self):
        self.assertEqual(select_mode([]), "snapshot")
        self.assertEqual(select_mode(["--strict-ci"]), "strict")
        self.assertEqual(select_mode(["--allow-private-config"]), "private")
        with self.assertRaises(ValueError):
            select_mode(["--strict-ci", "--allow-private-config"])

    def test_ambient_inputs_are_removed_and_only_explicit_inputs_are_restored(self):
        source = {"PATH": "/bin", "IMMICH_TEST_API_KEY": "ambient",
                  "TEST_RUNNER_SIMCTL_CHILD_IMMICH_SERVER_URL": "ambient",
                  "STRICT_E2E_REVIEWED_SCREENSHOTS": "/ambient", "ENABLE_DEBUG_AUTO_SERVER": "1",
                  "UI_TEST_EVIDENCE_DIR": "/ambient", "XCODE_XCCONFIG_FILE": "/private"}
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
            git("config", "user.name", "sudoHG")
            git("config", "user.email", "by331works@gmail.com")
            (root / ".gitignore").write_text("Config/env.xcconfig\nignored\n")
            (root / "tracked").write_text("committed")
            (root / "deleted").write_text("committed")
            git("add", ".")
            git("commit", "-qm", "initial")
            head = git("rev-parse", "HEAD")
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


if __name__ == "__main__":
    unittest.main()
