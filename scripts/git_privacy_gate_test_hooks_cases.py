"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations

from git_privacy_gate_test_fixtures import (
    BOOTSTRAP_WORKFLOW,
    CANONICAL_LFS_POINTER,
    CONTRIBUTING,
    HOOKS_ROOT,
    INSTALLER,
    MINIMAL_GIF_PAYLOAD,
    MINIMAL_PDF_PAYLOAD,
    PRINTABLE_DESCRIPTOR_GIF_PAYLOAD,
    Path,
    REPOSITORY_ROOT,
    SCRIPT,
    SMART_FILL_UI_TESTS,
    TRUSTED_RUNNER,
    TRUSTED_WORKFLOW,
    ZERO_OID,
    make_minimal_pdf_payload,
    os,
    shutil,
    subprocess,
    sys,
    tempfile,
    unittest,
)

class GitPrivacyGateTestsCasesHooks:
    def test_installer_protects_existing_worktree_without_gate_files(self) -> None:
        self.install_gate_files(configure=False)
        secondary_worktree = Path(self.temporary_directory.name) / "secondary"
        self.git(
            "worktree",
            "add",
            "-b",
            "secondary",
            str(secondary_worktree),
            self.base_oid,
        )

        installer_result = subprocess.run(
            [str(self.repo / "scripts" / INSTALLER.name)],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(installer_result.returncode, 0, installer_result.stderr)
        configured_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        self.assertIn("immichSlides-privacy-gate/", configured_path)
        self.assertTrue(configured_path.endswith("/hooks"))

        secondary_result = subprocess.run(
            [
                "git",
                "-C",
                str(secondary_worktree),
                "config",
                "--get",
                "core.hooksPath",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            secondary_result.returncode,
            0,
            msg=(
                f"stdout={secondary_result.stdout}\n"
                f"stderr={secondary_result.stderr}"
            ),
        )
        self.assertEqual(secondary_result.stdout.strip(), configured_path)

        private_path = secondary_worktree / "private-evidence" / "frame.jpg"
        private_path.parent.mkdir()
        private_path.write_text("synthetic private frame\n", encoding="utf-8")
        subprocess.run(
            ["git", "-C", str(secondary_worktree), "add", "-A"],
            check=True,
        )
        commit_result = subprocess.run(
            [
                "git",
                "-C",
                str(secondary_worktree),
                "commit",
                "-m",
                "must be blocked in existing worktree",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(commit_result.returncode, 0)
        self.assertIn("PRIVACY_GATE_BLOCKED", commit_result.stderr)


    def test_installer_refuses_to_overwrite_existing_hook_path(self) -> None:
        self.install_gate_files(configure=False)
        self.git("config", "core.hooksPath", "custom-hooks")

        installer_result = subprocess.run(
            [str(self.repo / "scripts" / INSTALLER.name)],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(installer_result.returncode, 0)
        self.assertIn("refuses to replace", installer_result.stderr)
        configured_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        self.assertEqual(configured_path, "custom-hooks")


    def test_installer_refuses_to_disable_additional_configured_hook(self) -> None:
        self.install_gate_files(configure=False)
        self.git("config", "core.hooksPath", ".githooks")
        additional_hook = self.repo / ".githooks" / "post-commit"
        additional_hook.write_text(
            "#!/bin/sh\nexit 0\n",
            encoding="utf-8",
        )
        additional_hook.chmod(0o755)

        installer_result = subprocess.run(
            [str(self.repo / "scripts" / INSTALLER.name)],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(installer_result.returncode, 0)
        self.assertIn("additional executable hook", installer_result.stderr)
        configured_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        self.assertEqual(configured_path, ".githooks")
        self.assertTrue(additional_hook.exists())


    def test_installer_refuses_different_same_name_hook_in_worktree(
        self,
    ) -> None:
        self.install_gate_files(configure=False)
        self.git("config", "core.hooksPath", ".githooks")
        secondary_worktree = (
            Path(self.temporary_directory.name) / "secondary-same-name-hook"
        )
        self.git(
            "worktree",
            "add",
            "-b",
            "secondary-same-name-hook",
            str(secondary_worktree),
            self.base_oid,
        )
        secondary_hooks = secondary_worktree / ".githooks"
        secondary_hooks.mkdir()
        secondary_hook = secondary_hooks / "pre-commit"
        custom_hook = "#!/bin/sh\necho 'secondary custom check'\nexit 0\n"
        secondary_hook.write_text(custom_hook, encoding="utf-8")
        secondary_hook.chmod(0o755)

        installer_result = subprocess.run(
            [str(self.repo / "scripts" / INSTALLER.name)],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(installer_result.returncode, 0)
        self.assertIn("same name but different contents", installer_result.stderr)
        configured_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        self.assertEqual(configured_path, ".githooks")
        self.assertEqual(
            secondary_hook.read_text(encoding="utf-8"),
            custom_hook,
        )


    def test_installer_can_replace_an_existing_valid_gate_version(self) -> None:
        self.install_gate_files()
        previous_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()

        installer_result = subprocess.run(
            [str(self.repo / "scripts" / INSTALLER.name)],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            installer_result.returncode,
            0,
            msg=(
                f"stdout={installer_result.stdout}\n"
                f"stderr={installer_result.stderr}"
            ),
        )
        current_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        self.assertNotEqual(current_path, previous_path)


    def test_installer_rejects_secondary_worktree_hook_override(self) -> None:
        self.install_gate_files(configure=False)
        secondary_worktree = Path(self.temporary_directory.name) / "secondary-custom"
        self.git(
            "worktree",
            "add",
            "-b",
            "secondary-custom",
            str(secondary_worktree),
            self.base_oid,
        )
        self.git("config", "extensions.worktreeConfig", "true")
        subprocess.run(
            [
                "git",
                "-C",
                str(secondary_worktree),
                "config",
                "--worktree",
                "core.hooksPath",
                "custom-secondary-hooks",
            ],
            check=True,
        )

        installer_result = subprocess.run(
            [str(self.repo / "scripts" / INSTALLER.name)],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(installer_result.returncode, 0)
        self.assertIn("refuses to replace", installer_result.stderr)
        effective_path = subprocess.run(
            [
                "git",
                "-C",
                str(secondary_worktree),
                "config",
                "--get",
                "core.hooksPath",
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.assertEqual(effective_path, "custom-secondary-hooks")


    def test_installer_rejects_executable_default_hook(self) -> None:
        self.install_gate_files(configure=False)
        common_directory = Path(
            self.git("rev-parse", "--git-common-dir").stdout.strip()
        )
        if not common_directory.is_absolute():
            common_directory = self.repo / common_directory
        existing_hook = common_directory / "hooks" / "pre-commit"
        existing_hook.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        existing_hook.chmod(0o755)

        installer_result = subprocess.run(
            [str(self.repo / "scripts" / INSTALLER.name)],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(installer_result.returncode, 0)
        self.assertIn("existing executable hook", installer_result.stderr)
        self.assertEqual(existing_hook.read_text(encoding="utf-8"), "#!/bin/sh\nexit 0\n")


    def test_failed_installer_update_keeps_previous_gate_active(self) -> None:
        self.install_gate_files()
        previous_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        source_scanner = self.repo / "scripts" / SCRIPT.name
        source_scanner.write_text(
            "#!/usr/bin/env python3\nraise SystemExit(0)\n",
            encoding="utf-8",
        )
        source_pre_commit = self.repo / ".githooks" / "pre-commit"
        source_pre_commit.unlink()
        source_pre_commit.mkdir()

        installer_result = subprocess.run(
            [str(self.repo / "scripts" / INSTALLER.name)],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(installer_result.returncode, 0)
        current_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        self.assertEqual(current_path, previous_path)
        self.write("private-evidence/frame.jpg", "synthetic private frame\n")
        self.git("add", "-A")
        commit_result = self.git_without_check(
            "commit",
            "-m",
            "must still be blocked after failed update",
        )
        self.assertNotEqual(commit_result.returncode, 0)
        self.assertIn("PRIVACY_GATE_BLOCKED", commit_result.stderr)


    def test_installer_rejects_noop_candidate_that_spoofs_pass(self) -> None:
        self.install_gate_files()
        previous_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        source_scanner = self.repo / "scripts" / SCRIPT.name
        source_scanner.write_text(
            (
                "#!/usr/bin/env python3\n"
                "print('PRIVACY_GATE_PASS scanned_blobs=0 scanned_metadata=0')\n"
            ),
            encoding="utf-8",
        )

        installer_result = subprocess.run(
            [str(self.repo / "scripts" / INSTALLER.name)],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(installer_result.returncode, 0)
        current_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        self.assertEqual(current_path, previous_path)


    def test_installer_rejects_noop_candidate_hooks(self) -> None:
        self.install_gate_files()
        previous_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        original_hooks = {
            hook_name: (self.repo / ".githooks" / hook_name).read_text(
                encoding="utf-8"
            )
            for hook_name in ("commit-msg", "pre-commit", "pre-push")
        }
        for hook_name in ("commit-msg", "pre-commit", "pre-push"):
            source_hook = self.repo / ".githooks" / hook_name
            source_hook.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            source_hook.chmod(0o755)
            with self.subTest(hook_name=hook_name):
                installer_result = subprocess.run(
                    [str(self.repo / "scripts" / INSTALLER.name)],
                    cwd=self.repo,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(installer_result.returncode, 0)
                current_path = self.git(
                    "config",
                    "--get",
                    "core.hooksPath",
                ).stdout.strip()
                self.assertEqual(current_path, previous_path)
            source_hook.write_text(
                original_hooks[hook_name],
                encoding="utf-8",
            )
            source_hook.chmod(0o755)


    def test_installer_rejects_always_blocking_candidate_hooks(self) -> None:
        self.install_gate_files()
        previous_path = self.git(
            "config",
            "--get",
            "core.hooksPath",
        ).stdout.strip()
        original_hooks = {
            hook_name: (self.repo / ".githooks" / hook_name).read_text(
                encoding="utf-8"
            )
            for hook_name in ("commit-msg", "pre-commit", "pre-push")
        }
        blocking_hook = (
            "#!/bin/sh\n"
            "echo 'PRIVACY_GATE_BLOCKED findings=1' >&2\n"
            "exit 2\n"
        )

        for hook_name in ("commit-msg", "pre-commit", "pre-push"):
            source_hook = self.repo / ".githooks" / hook_name
            source_hook.write_text(blocking_hook, encoding="utf-8")
            source_hook.chmod(0o755)
            with self.subTest(hook_name=hook_name):
                installer_result = subprocess.run(
                    [str(self.repo / "scripts" / INSTALLER.name)],
                    cwd=self.repo,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(installer_result.returncode, 0)
                current_path = self.git(
                    "config",
                    "--get",
                    "core.hooksPath",
                ).stdout.strip()
                self.assertEqual(current_path, previous_path)
            source_hook.write_text(
                original_hooks[hook_name],
                encoding="utf-8",
            )
            source_hook.chmod(0o755)
