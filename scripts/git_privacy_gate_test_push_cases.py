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

class GitPrivacyGateTestsCasesPush:
    def test_pre_push_ignores_stale_remote_tracking_ref(self) -> None:
        bare_remote = Path(self.temporary_directory.name) / "stale-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        self.git("switch", "-c", "feature/stale-tracking")
        self.write("private-evidence/runtime.trace", "synthetic trace\n")
        self.commit("add synthetic trace behind stale ref")
        local_oid = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("update-ref", "refs/remotes/origin/stale-only", local_oid)
        hook_input = (
            f"refs/heads/feature/stale-tracking {local_oid} "
            f"refs/heads/feature/stale-tracking {ZERO_OID}\n"
        )

        result = self.run_gate("--pre-push", "origin", input_text=hook_input)

        self.assert_blocked(result, "blocked_artifact")


    def test_pre_push_fetches_missing_remote_tip_without_updating_tracking_ref(
        self,
    ) -> None:
        bare_remote = Path(self.temporary_directory.name) / "advanced-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.write("Assets/legacy.png", "legacy remote artifact\n")
        self.commit("add legacy remote artifact")
        legacy_oid = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")

        collaborator = Path(self.temporary_directory.name) / "collaborator"
        subprocess.run(
            [
                "git",
                "clone",
                "-q",
                "--branch",
                "main",
                str(bare_remote),
                str(collaborator),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            ["git", "-C", str(collaborator), "config", "user.name", "Collaborator"],
            check=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(collaborator),
                "config",
                "user.email",
                "collaborator@example.invalid",
            ],
            check=True,
        )
        collaborator_file = collaborator / "Sources" / "RemoteSafe.swift"
        collaborator_file.parent.mkdir(parents=True, exist_ok=True)
        collaborator_file.write_text(
            "struct RemoteSafe {}\n",
            encoding="utf-8",
        )
        subprocess.run(
            ["git", "-C", str(collaborator), "add", "-A"],
            check=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(collaborator),
                "commit",
                "-q",
                "-m",
                "advance remote safely",
            ],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(collaborator), "push", "-q", "origin", "main"],
            check=True,
        )
        remote_tip = subprocess.run(
            ["git", "-C", str(collaborator), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        object_before = subprocess.run(
            ["git", "cat-file", "-e", remote_tip],
            cwd=self.repo,
            check=False,
            capture_output=True,
        )
        self.assertNotEqual(object_before.returncode, 0)
        fetch_head_path = Path(
            self.git("rev-parse", "--git-path", "FETCH_HEAD").stdout.strip()
        )
        if not fetch_head_path.is_absolute():
            fetch_head_path = self.repo / fetch_head_path
        fetch_head_before = (
            fetch_head_path.read_bytes()
            if fetch_head_path.exists()
            else None
        )

        self.git("switch", "-c", "feature/from-stale-base")
        self.write("Sources/LocalSafe.swift", "struct LocalSafe {}\n")
        self.commit("add local safe feature")
        local_oid = self.git("rev-parse", "HEAD").stdout.strip()
        hook_input = (
            f"refs/heads/feature/from-stale-base {local_oid} "
            f"refs/heads/feature/from-stale-base {ZERO_OID}\n"
        )

        result = self.run_gate(
            "--pre-push",
            "origin",
            input_text=hook_input,
        )

        self.assert_allowed(result)
        tracking_oid = self.git(
            "rev-parse",
            "refs/remotes/origin/main",
        ).stdout.strip()
        self.assertEqual(tracking_oid, legacy_oid)
        self.assertEqual(
            self.git("cat-file", "-t", remote_tip).stdout.strip(),
            "commit",
        )
        fetch_head_after = (
            fetch_head_path.read_bytes()
            if fetch_head_path.exists()
            else None
        )
        self.assertEqual(fetch_head_after, fetch_head_before)


    def test_pre_push_fetches_missing_annotated_tag_history(self) -> None:
        self.write("Assets/legacy.png", "legacy tagged artifact\n")
        self.commit("add tagged legacy artifact")
        legacy_oid = self.git("rev-parse", "HEAD").stdout.strip()
        bare_remote = Path(self.temporary_directory.name) / "tag-only-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")

        collaborator = Path(self.temporary_directory.name) / "tag-collaborator"
        subprocess.run(
            [
                "git",
                "clone",
                "-q",
                "--branch",
                "main",
                str(bare_remote),
                str(collaborator),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            ["git", "-C", str(collaborator), "config", "user.name", "Tagger"],
            check=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(collaborator),
                "config",
                "user.email",
                "tagger@example.invalid",
            ],
            check=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(collaborator),
                "tag",
                "-a",
                "release-only",
                "-m",
                "retain released history",
            ],
            check=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(collaborator),
                "push",
                "-q",
                "origin",
                "refs/tags/release-only",
            ],
            check=True,
        )
        tag_oid = subprocess.run(
            [
                "git",
                "-C",
                str(collaborator),
                "rev-parse",
                "refs/tags/release-only",
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        subprocess.run(
            [
                "git",
                "--git-dir",
                str(bare_remote),
                "update-ref",
                "-d",
                "refs/heads/main",
            ],
            check=True,
        )
        self.assertNotEqual(
            subprocess.run(
                ["git", "cat-file", "-e", tag_oid],
                cwd=self.repo,
                check=False,
                capture_output=True,
            ).returncode,
            0,
        )
        fetch_head_path = Path(
            self.git("rev-parse", "--git-path", "FETCH_HEAD").stdout.strip()
        )
        if not fetch_head_path.is_absolute():
            fetch_head_path = self.repo / fetch_head_path
        fetch_head_before = (
            fetch_head_path.read_bytes()
            if fetch_head_path.exists()
            else None
        )

        self.git("switch", "-c", "feature/from-tagged-base")
        self.write("Sources/TaggedBaseSafe.swift", "struct TaggedBaseSafe {}\n")
        self.commit("add safe maintenance change")
        local_oid = self.git("rev-parse", "HEAD").stdout.strip()
        hook_input = (
            f"refs/heads/feature/from-tagged-base {local_oid} "
            f"refs/heads/feature/from-tagged-base {ZERO_OID}\n"
        )

        result = self.run_gate(
            "--pre-push",
            "origin",
            input_text=hook_input,
        )

        self.assert_allowed(result)
        self.assertEqual(self.git("cat-file", "-t", tag_oid).stdout.strip(), "tag")
        self.assertNotEqual(
            subprocess.run(
                [
                    "git",
                    "show-ref",
                    "--verify",
                    "--quiet",
                    "refs/tags/release-only",
                ],
                cwd=self.repo,
                check=False,
            ).returncode,
            0,
        )
        fetch_head_after = (
            fetch_head_path.read_bytes()
            if fetch_head_path.exists()
            else None
        )
        self.assertEqual(fetch_head_after, fetch_head_before)
        self.assertEqual(
            self.git("rev-parse", "refs/remotes/origin/main").stdout.strip(),
            legacy_oid,
        )


    def test_pre_push_ref_deletion_needs_no_remote_lookup(self) -> None:
        hook_input = (
            f"(delete) {ZERO_OID} "
            f"refs/heads/obsolete {self.base_oid}\n"
        )

        result = self.run_gate(
            "--pre-push",
            "missing-remote",
            input_text=hook_input,
        )

        self.assert_allowed(result)
        self.assertIn("scanned_metadata=0", result.stdout)


    def test_renaming_legacy_artifact_out_of_blocked_path_passes(self) -> None:
        self.write("Diagnostics/legacy.log", "legacy remote text\n")
        self.commit("add legacy log")
        legacy_oid = self.git("rev-parse", "HEAD").stdout.strip()
        bare_remote = Path(self.temporary_directory.name) / "rename-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        self.git(
            "mv",
            "Diagnostics/legacy.log",
            "Sources/LegacyNotes.txt",
        )

        staged_result = self.run_gate("--staged")
        self.git("commit", "-m", "move legacy log into source notes")
        local_oid = self.git("rev-parse", "HEAD").stdout.strip()
        range_result = self.run_gate("--range", f"{legacy_oid}..HEAD")
        hook_input = (
            f"refs/heads/main {local_oid} "
            f"refs/heads/main {legacy_oid}\n"
        )
        pre_push_result = self.run_gate(
            "--pre-push",
            "origin",
            input_text=hook_input,
        )

        for result in (staged_result, range_result, pre_push_result):
            self.assert_allowed(result)


    def test_pre_push_blocks_secret_in_annotated_tag_message(self) -> None:
        bare_remote = Path(self.temporary_directory.name) / "tag-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        synthetic_secret = "ghp_" + ("G" * 40)
        self.git("tag", "-a", "private-tag", "-m", f"synthetic tag {synthetic_secret}")
        local_oid = self.git("rev-parse", "refs/tags/private-tag").stdout.strip()
        hook_input = (
            f"refs/tags/private-tag {local_oid} "
            f"refs/tags/private-tag {ZERO_OID}\n"
        )

        result = self.run_gate("--pre-push", "origin", input_text=hook_input)

        self.assert_blocked(result, "high_confidence_secret")
        self.assertNotIn(synthetic_secret, result.stdout + result.stderr)


    def test_pre_push_blocks_secret_in_ref_name_without_echoing_it(self) -> None:
        bare_remote = Path(self.temporary_directory.name) / "ref-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        synthetic_secret = "ghp_" + ("N" * 40)
        local_oid = self.git("rev-parse", "HEAD").stdout.strip()
        local_ref = f"refs/heads/{synthetic_secret}"
        hook_input = f"{local_ref} {local_oid} {local_ref} {ZERO_OID}\n"

        result = self.run_gate("--pre-push", "origin", input_text=hook_input)

        self.assert_blocked(result, "high_confidence_secret")
        self.assertNotIn(synthetic_secret, result.stdout + result.stderr)


    def test_pre_push_scans_lightweight_and_annotated_tags_to_blob(self) -> None:
        bare_remote = Path(self.temporary_directory.name) / "blob-tag-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        payload_path = self.repo / "private-tag-payload.dat"
        payload_path.write_bytes(b"\x89PNG\r\n\x1a\nsynthetic")
        blob_oid = self.git(
            "hash-object",
            "-w",
            str(payload_path),
        ).stdout.strip()
        payload_path.unlink()
        self.git("update-ref", "refs/tags/private-blob", blob_oid)
        self.git(
            "tag",
            "-a",
            "annotated-private-blob",
            blob_oid,
            "-m",
            "safe annotated tag metadata",
        )

        for tag_name in ("private-blob", "annotated-private-blob"):
            local_oid = self.git(
                "rev-parse",
                f"refs/tags/{tag_name}",
            ).stdout.strip()
            hook_input = (
                f"refs/tags/{tag_name} {local_oid} "
                f"refs/tags/{tag_name} {ZERO_OID}\n"
            )
            with self.subTest(tag_name=tag_name):
                result = self.run_gate(
                    "--pre-push",
                    "origin",
                    input_text=hook_input,
                )
                self.assert_blocked(result, "blocked_content_signature")


    def test_pre_push_rejects_blob_ref_without_path_context(self) -> None:
        bare_remote = Path(self.temporary_directory.name) / "safe-blob-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        blob_oid = self.git(
            "rev-parse",
            "HEAD:Sources/App.swift",
        ).stdout.strip()
        self.git("update-ref", "refs/tags/unscoped-blob", blob_oid)
        hook_input = (
            f"refs/tags/unscoped-blob {blob_oid} "
            f"refs/tags/unscoped-blob {ZERO_OID}\n"
        )

        result = self.run_gate(
            "--pre-push",
            "origin",
            input_text=hook_input,
        )

        self.assert_blocked(result, "blocked_artifact")


    def test_gitlink_secret_path_is_scanned_in_all_modes(self) -> None:
        bare_remote = Path(self.temporary_directory.name) / "gitlink-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        synthetic_secret = "ghp_" + ("S" * 40)
        gitlink_path = f"Modules/{synthetic_secret}"
        self.git(
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{self.base_oid},{gitlink_path}",
        )
        staged_result = self.run_gate("--staged")
        self.git("commit", "-m", "add synthetic gitlink")
        local_oid = self.git("rev-parse", "HEAD").stdout.strip()
        range_result = self.run_gate("--range", f"{self.base_oid}..HEAD")
        hook_input = (
            f"refs/heads/main {local_oid} "
            f"refs/heads/main {self.base_oid}\n"
        )
        pre_push_result = self.run_gate(
            "--pre-push",
            "origin",
            input_text=hook_input,
        )

        for result in (staged_result, range_result, pre_push_result):
            self.assert_blocked(result, "high_confidence_secret")
            self.assertIn("size=unknown", result.stderr)
            self.assertNotIn(synthetic_secret, result.stdout + result.stderr)


    def test_installed_pre_commit_hook_blocks_git_commit(self) -> None:
        self.install_gate_files()
        self.write("TestSupport/private-evidence/runtime.jsonl", '{"synthetic":"value"}\n')
        self.git("add", "-A")

        result = self.git_without_check("commit", "-m", "must be blocked")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PRIVACY_GATE_BLOCKED", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.base_oid)


    def test_installed_commit_message_hook_blocks_secret_message(self) -> None:
        self.install_gate_files()
        synthetic_secret = "ghp_" + ("C" * 40)
        self.write("Sources/CommitMessage.swift", "struct CommitMessage {}\n")
        self.git("add", "-A")

        result = self.git_without_check(
            "commit",
            "-m",
            f"synthetic message {synthetic_secret}",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PRIVACY_GATE_BLOCKED", result.stderr)
        self.assertNotIn(synthetic_secret, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.base_oid)


    def test_installed_pre_push_hook_blocks_bypassed_commit(self) -> None:
        self.install_gate_files()
        self.commit("install privacy gate")
        bare_remote = Path(self.temporary_directory.name) / "hook-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        self.git("switch", "-c", "feature/hook-bypass-test")
        self.write("private-evidence/frame.jpg", "synthetic image payload\n")
        self.git("add", "-A")
        self.git("commit", "--no-verify", "-m", "bypass pre-commit")

        result = self.git_without_check(
            "push",
            "origin",
            "feature/hook-bypass-test",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PRIVACY_GATE_BLOCKED", result.stderr)
        remote_ref = subprocess.run(
            [
                "git",
                "--git-dir",
                str(bare_remote),
                "show-ref",
                "--verify",
                "--quiet",
                "refs/heads/feature/hook-bypass-test",
            ],
            check=False,
        )
        self.assertNotEqual(remote_ref.returncode, 0)


    def test_installed_hooks_fail_closed_when_versioned_scanner_is_missing(
        self,
    ) -> None:
        self.install_gate_files()
        hooks_directory = Path(
            self.git("config", "--get", "core.hooksPath").stdout.strip()
        )
        installed_scanner = hooks_directory.parent / SCRIPT.name
        installed_scanner.unlink()
        worktree_scanner = self.repo / "scripts" / SCRIPT.name
        worktree_scanner.write_text(
            (
                "#!/usr/bin/env python3\n"
                "print('PRIVACY_GATE_PASS scanned_blobs=0 scanned_metadata=0')\n"
            ),
            encoding="utf-8",
        )
        self.write("Sources/ScannerMissing.swift", "struct ScannerMissing {}\n")
        self.git("add", "-A")
        message_file = Path(self.temporary_directory.name) / "safe-message"
        message_file.write_text("safe message\n", encoding="utf-8")
        invocations = (
            ([str(hooks_directory / "pre-commit")], None),
            (
                [
                    str(hooks_directory / "commit-msg"),
                    str(message_file),
                ],
                None,
            ),
            ([str(hooks_directory / "pre-push"), "origin"], ""),
        )

        for command, input_text in invocations:
            with self.subTest(hook=Path(command[0]).name):
                result = subprocess.run(
                    command,
                    cwd=self.repo,
                    input=input_text,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 3)
                self.assertIn(
                    "PRIVACY_GATE_ERROR scanner unavailable",
                    result.stderr,
                )


    def test_source_hooks_use_worktree_scanner(self) -> None:
        self.install_gate_files(configure=False)
        self.git("config", "core.hooksPath", ".githooks")
        root_scanner = self.repo / SCRIPT.name
        root_scanner.write_text(
            "raise SystemExit(71)\n",
            encoding="utf-8",
        )
        self.write("Sources/SourceHook.swift", "struct SourceHook {}\n")
        self.git("add", "-A")
        message_file = Path(self.temporary_directory.name) / "source-message"
        message_file.write_text("safe source message\n", encoding="utf-8")
        hooks_directory = self.repo / ".githooks"
        invocations = (
            ([str(hooks_directory / "pre-commit")], None),
            (
                [
                    str(hooks_directory / "commit-msg"),
                    str(message_file),
                ],
                None,
            ),
            ([str(hooks_directory / "pre-push"), "origin"], ""),
        )

        for command, input_text in invocations:
            with self.subTest(hook=Path(command[0]).name):
                result = subprocess.run(
                    command,
                    cwd=self.repo,
                    input=input_text,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assert_allowed(result)
