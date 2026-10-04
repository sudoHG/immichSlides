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

class GitPrivacyGateTestsCasesScanning:
    def test_staged_safe_swift_change_passes(self) -> None:
        self.write("Sources/App.swift", "struct App { let isReady = true }\n")
        self.git("add", "Sources/App.swift")

        result = self.run_gate("--staged")

        self.assert_allowed(result)


    def test_swift_symbol_references_pass_staged_and_range(self) -> None:
        key = "api" + "Key"
        self.write("Sources/References.swift", "\n".join([
            "guard let server = loadServer() else { return }",
            "let screenshotAPIKey = readEnvironment()",
            "private var pendingConnectionRetry: Retry?",
            f'{key} = server.immichApiKey ?? ""',
            f"{key} = screenshotAPIKey",
            f"save({key}: pendingConnectionRetry.apiKey, other: true)",
        ]) + "\n")
        self.git("add", "Sources/References.swift")
        self.assert_allowed(self.run_gate("--staged"))
        self.commit("save symbolic references")
        self.assert_allowed(self.run_gate("--range", f"{self.base_oid}..HEAD"))


    def test_swift_method_call_on_type_passes(self) -> None:
        key = "api" + "Key"
        self.write("Sources/Calls.swift", "\n".join([
            f"guard let {key} = ImmichAPIService.shared.getApiKey() else {{ return }}",
            f'let {key} = Bundle.main.object(forInfoDictionaryKey: "KEY") as? String',
        ]) + "\n")
        self.git("add", "Sources/Calls.swift")
        self.assert_allowed(self.run_gate("--staged"))


    def test_swift_call_exemption_needs_dotted_type_path(self) -> None:
        assignment = "api" + "Key = "
        payloads = [
            assignment + "S" * 32 + "()",
            assignment + "s" * 16 + ".value" + "()",
            assignment + '"' + "S" * 32 + '"' + ".lowercased()",
        ]
        for index, payload in enumerate(payloads):
            with self.subTest(case=index):
                self.write("Sources/Calls.swift", payload + "\n")
                self.git("add", "Sources/Calls.swift")
                self.assert_blocked(self.run_gate("--staged"), "high_confidence_secret")


    def test_swift_reference_requires_prior_code_declaration(self) -> None:
        reference = "S" * 32
        assignment = "api" + "Key = " + reference + "\n"
        declaration = "let " + reference + " = loadValue()\n"
        payloads = [
            assignment,
            assignment + declaration,
            "// " + declaration + assignment,
            "/* outer /* nested */ " + declaration + " */\n" + assignment,
            'let note = """\n' + declaration + '\n"""\n' + assignment,
        ]
        for index, payload in enumerate(payloads):
            with self.subTest(case=index):
                self.write("Sources/Undeclared.swift", payload)
                self.git("add", "Sources/Undeclared.swift")
                self.assert_blocked(self.run_gate("--staged"), "high_confidence_secret")


    def test_normal_commit_accepts_reference_but_rejects_literal(self) -> None:
        self.install_gate_files()
        assignment = "api" + "Key = "
        self.write("Sources/References.swift", "let screenshotAPIKey = readEnvironment()\n"
                   + assignment + "screenshotAPIKey\n")
        self.commit("save declared reference through hooks")
        self.write("Sources/References.swift", assignment + '"' + "S" * 32 + '"\n')
        self.git("add", "Sources/References.swift")
        result = self.git_without_check("commit", "-m", "reject synthetic secret")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("high_confidence_secret", result.stderr)


    def test_swift_literals_and_comments_still_block_generic_secrets(self) -> None:
        assignment = "api" + "Key = "
        secret = "S" * 32
        reference = "server.immichApiKey"
        payloads = [
            assignment + '"' + secret + '"',
            assignment + '#"' + secret + '"#',
            assignment + '"""\n' + secret + '\n"""',
            "// " + assignment + reference,
            "/* outer /* nested */ " + assignment + reference + " */",
            'let note = "' + assignment + reference + '"',
            'let note = "escaped \\"; ' + assignment + reference + ';"',
            'let note = ##"""\n' + assignment + reference + '\n"""##',
            "let pattern = #/" + assignment + reference + ",/#",
            "let pattern = /" + assignment + reference + ",/",
            "let pattern = ##/\n" + assignment + reference + ",\n/##",
            assignment + reference + ' ?? "' + secret + '"',
            assignment + reference + "\nlet token = \"ghp_" + "T" * 40 + '"',
            assignment + "ghp_" + "T" * 40,
        ]
        for index, payload in enumerate(payloads):
            with self.subTest(case=index):
                self.write("Sources/Protected.swift", "let server = loadServer()\n" + payload + "\n")
                self.git("add", "Sources/Protected.swift")
                result = self.run_gate("--staged")
                self.assert_blocked(result, "high_confidence_secret")
                self.assertNotIn(secret, result.stdout + result.stderr)


    def test_swift_utf16_literal_remains_blocked(self) -> None:
        payload = ("api" + "Key = \"" + "S" * 32 + '"').encode("utf-16")
        (self.repo / "Sources/Encoded.swift").write_bytes(payload)
        self.git("add", "Sources/Encoded.swift")
        self.assert_blocked(self.run_gate("--staged"), "high_confidence_secret")


    def test_symbol_reference_exception_does_not_apply_to_other_content(self) -> None:
        text = "api" + "Key = screenshotAPIKey"
        self.write("Notes.txt", text)
        self.git("add", "Notes.txt")
        self.assert_blocked(self.run_gate("--staged"), "high_confidence_secret")
        self.git("reset", "--", "Notes.txt")
        (self.repo / "Sources/Link.swift").symlink_to(text)
        self.git("add", "Sources/Link.swift")
        self.assert_blocked(self.run_gate("--staged"), "high_confidence_secret")
        message = Path(self.temporary_directory.name) / "message"
        message.write_text(text, encoding="utf-8")
        self.assert_blocked(self.run_gate("--message-file", str(message)), "high_confidence_secret")


    def test_same_blob_symlink_mode_survives_history_and_tree_deduplication(self) -> None:
        text = "let screenshotAPIKey = loadValue()\n" + "api" + "Key = screenshotAPIKey\n"
        self.write("Sources/Reference.swift", text)
        self.commit("save regular source")
        regular_tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        path = self.repo / "Sources/Reference.swift"
        path.unlink()
        path.symlink_to(text)
        self.commit("change source to synthetic symlink")
        symlink_tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.assert_blocked(self.run_gate("--range", f"{self.base_oid}..HEAD"),
                            "high_confidence_secret")

        remote = Path(self.temporary_directory.name) / "mode-remote.git"
        subprocess.run(["git", "init", "--bare", str(remote)],
                       check=True, capture_output=True, text=True)
        self.git("remote", "add", "origin", str(remote))
        for trees in ((symlink_tree, regular_tree), (regular_tree, symlink_tree)):
            hook_input = "".join(
                f"refs/tags/tree-{i} {tree} refs/tags/tree-{i} {ZERO_OID}\n"
                for i, tree in enumerate(trees)
            )
            self.assert_blocked(self.run_gate("--pre-push", "origin", input_text=hook_input),
                                "high_confidence_secret")


    def test_staged_runtime_image_is_blocked_without_echoing_payload(self) -> None:
        private_marker = "PRIVATE_SYNTHETIC_PAYLOAD_MUST_NOT_BE_ECHOED"
        image_path = self.repo / "TestSupport/sample-evidence/frame.png"
        image_path.parent.mkdir(parents=True)
        image_payload = b"\x89PNG\r\n\x1a\n" + private_marker.encode("utf-8")
        image_path.write_bytes(image_payload)
        self.git("add", str(image_path.relative_to(self.repo)))

        result = self.run_gate("--staged")

        self.assert_blocked(result, "blocked_artifact")
        self.assertIn(f"size={len(image_payload)}", result.stderr)
        self.assertNotIn("size=0", result.stderr)
        self.assertNotIn(private_marker, result.stdout + result.stderr)


    def test_staged_type_change_is_scanned(self) -> None:
        disguised_path = self.repo / "Fixtures" / "type-change.dat"
        disguised_path.parent.mkdir(parents=True)
        disguised_path.symlink_to("safe-target")
        self.commit("add synthetic symlink")
        disguised_path.unlink()
        synthetic_secret = "ghp_" + ("T" * 40)
        disguised_path.write_text(synthetic_secret, encoding="utf-8")
        self.git("add", "Fixtures/type-change.dat")

        result = self.run_gate("--staged")

        self.assert_blocked(result, "high_confidence_secret")


    def test_staged_scan_ignores_git_replace_objects(self) -> None:
        disguised_path = self.repo / "Fixtures" / "replace-hidden.dat"
        disguised_path.parent.mkdir(parents=True)
        disguised_path.write_bytes(b"\x89PNG\r\n\x1a\nsynthetic")
        self.git("add", "Fixtures/replace-hidden.dat")
        private_blob_oid = self.git(
            "rev-parse",
            ":Fixtures/replace-hidden.dat",
        ).stdout.strip()
        safe_blob_oid = self.git(
            "rev-parse",
            "HEAD:Sources/App.swift",
        ).stdout.strip()
        self.git("replace", private_blob_oid, safe_blob_oid)

        result = self.run_gate("--staged")

        self.assert_blocked(result, "blocked_content_signature")


    def test_prefixed_pdf_blob_is_blocked_in_all_git_scan_modes(self) -> None:
        disguised_path = self.repo / "Fixtures" / "prefixed-pdf.dat"
        disguised_path.parent.mkdir(parents=True)
        disguised_path.write_bytes(
            b"synthetic leading bytes\n" + MINIMAL_PDF_PAYLOAD
        )
        self.git("add", "Fixtures/prefixed-pdf.dat")
        staged_result = self.run_gate("--staged")
        self.git(
            "-c",
            "core.hooksPath=/dev/null",
            "commit",
            "-m",
            "add prefixed synthetic PDF",
        )
        local_oid = self.git("rev-parse", "HEAD").stdout.strip()
        range_result = self.run_gate(
            "--range",
            f"{self.base_oid}..{local_oid}",
        )
        bare_remote = Path(self.temporary_directory.name) / "pdf-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        hook_input = (
            f"refs/heads/main {local_oid} "
            f"refs/heads/main {ZERO_OID}\n"
        )
        pre_push_result = self.run_gate(
            "--pre-push",
            "origin",
            input_text=hook_input,
        )

        for mode, result in (
            ("staged", staged_result),
            ("range", range_result),
            ("pre-push", pre_push_result),
        ):
            with self.subTest(mode=mode):
                self.assert_blocked(result, "blocked_content_signature")


    def test_range_blocks_jsonl_added_then_deleted_in_later_commit(self) -> None:
        self.write(
            "TestSupport/sample-evidence/runtime.jsonl",
            '{"assetId":"synthetic-private-asset-value"}\n',
        )
        self.commit("add synthetic evidence")
        evidence_path = self.repo / "TestSupport/sample-evidence/runtime.jsonl"
        evidence_path.unlink()
        self.git("add", "-u")
        self.git("commit", "-m", "delete synthetic evidence")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "blocked_artifact")


    def test_range_blocks_oversized_blob(self) -> None:
        oversized_path = self.repo / "Fixtures/oversized.bin"
        oversized_path.parent.mkdir(parents=True)
        oversized_path.write_bytes(b"x" * (1024 * 1024 + 1))
        self.commit("add oversized fixture")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "oversized_blob")


    def test_range_blocks_private_key_file_by_extension(self) -> None:
        self.write("Signing/AuthKey_SYNTHETIC.p8", "synthetic key fixture\n")
        self.commit("add synthetic signing key")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "blocked_artifact")


    def test_range_blocks_high_confidence_secret_without_echoing_it(self) -> None:
        synthetic_secret = "ghp_" + ("A" * 40)
        self.write("Notes/internal.txt", f"credential={synthetic_secret}\n")
        self.commit("add synthetic secret")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "high_confidence_secret")
        self.assertNotIn(synthetic_secret, result.stdout + result.stderr)


    def test_range_blocks_secret_in_utf16_payload(self) -> None:
        synthetic_secret = "ghp_" + ("U" * 40)
        payload_path = self.repo / "Notes" / "utf16.dat"
        payload_path.parent.mkdir(parents=True)
        payload_path.write_bytes(synthetic_secret.encode("utf-16-le"))
        self.commit("add synthetic UTF-16 secret")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "high_confidence_secret")
        self.assertNotIn(synthetic_secret, result.stdout + result.stderr)


    def test_range_blocks_disguised_png_by_content_signature(self) -> None:
        payload_path = self.repo / "Fixtures" / "disguised.dat"
        payload_path.parent.mkdir(parents=True)
        payload_path.write_bytes(b"\x89PNG\r\n\x1a\nsynthetic")
        self.commit("add disguised synthetic image")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "blocked_content_signature")


    def test_range_blocks_unresolved_lfs_pointer(self) -> None:
        self.write(
            "Fixtures/private-payload.bin",
            (
                "version https://git-lfs.github.com/spec/v1\n"
                "oid sha256:" + ("a" * 64) + "\n"
                "size 1234\n"
            ),
        )
        self.commit("add synthetic LFS pointer")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "unscanned_lfs_pointer")


    def test_range_blocks_runtime_evidence_directories_and_tsv(self) -> None:
        self.write("ui-runtime/session.txt", "synthetic UI runtime evidence\n")
        self.write("motion-runtime/metrics.tsv", "frame\tvalue\n1\t2\n")
        self.commit("add synthetic runtime evidence")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "blocked_artifact")
        self.assertIn("ui-runtime/session.txt", result.stderr)
        self.assertIn("motion-runtime/metrics.tsv", result.stderr)


    def test_range_scans_type_change(self) -> None:
        disguised_path = self.repo / "Fixtures" / "range-type-change.dat"
        disguised_path.parent.mkdir(parents=True)
        disguised_path.symlink_to("safe-target")
        self.commit("add range symlink")
        disguised_path.unlink()
        synthetic_secret = "ghp_" + ("R" * 40)
        disguised_path.write_text(synthetic_secret, encoding="utf-8")
        self.commit("replace symlink with synthetic secret")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "high_confidence_secret")


    def test_range_blocks_secret_in_commit_message_without_echoing_it(self) -> None:
        synthetic_secret = "ghp_" + ("M" * 40)
        self.write("Sources/MessageSafe.swift", "struct MessageSafe {}\n")
        self.commit(f"synthetic message {synthetic_secret}")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "high_confidence_secret")
        self.assertNotIn(synthetic_secret, result.stdout + result.stderr)


    def test_range_blocks_secret_in_commit_headers_without_echoing_it(self) -> None:
        synthetic_secret = "ghp_" + ("H" * 40)
        self.git("config", "user.name", synthetic_secret)
        self.write("Sources/HeaderSafe.swift", "struct HeaderSafe {}\n")
        self.commit("safe visible message")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "high_confidence_secret")
        self.assertNotIn(synthetic_secret, result.stdout + result.stderr)


    def test_range_blocks_secret_in_filename_without_echoing_it(self) -> None:
        synthetic_secret = "ghp_" + ("F" * 40)
        self.write(f"Notes/{synthetic_secret}.txt", "safe payload\n")
        self.commit("add synthetic secret filename")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "high_confidence_secret")
        self.assertNotIn(synthetic_secret, result.stdout + result.stderr)


    def test_metadata_applies_binary_lfs_and_size_policies(self) -> None:
        payloads = (
            (
                (
                    b"synthetic metadata preface\n"
                    b"\x89PNG\r\n\x1a\nsynthetic metadata image\n"
                ),
                "blocked_content_signature",
            ),
            (
                (
                    b"synthetic metadata preface:"
                    + MINIMAL_PDF_PAYLOAD
                ),
                "blocked_content_signature",
            ),
            (
                (
                    b"synthetic metadata preface:"
                    + MINIMAL_GIF_PAYLOAD
                ),
                "blocked_content_signature",
            ),
            (
                (
                    b"synthetic metadata preface:"
                    + PRINTABLE_DESCRIPTOR_GIF_PAYLOAD
                ),
                "blocked_content_signature",
            ),
            (
                b"synthetic metadata preface:" + CANONICAL_LFS_POINTER,
                "unscanned_lfs_pointer",
            ),
            (b"x" * (1024 * 1024 + 1), "oversized_metadata"),
        )

        for index, (payload, reason) in enumerate(payloads):
            message_file = Path(self.temporary_directory.name) / f"message-{index}"
            message_file.write_bytes(payload)
            with self.subTest(reason=reason):
                result = self.run_gate(
                    "--message-file",
                    str(message_file),
                )
                self.assert_blocked(result, reason)


    def test_metadata_technical_signature_discussion_is_allowed(self) -> None:
        payloads = (
            b"Document handling of the %PDF- and GIF89a headers.\n",
            b"%PDF-1.7\n",
            "GIF89a is followed by the logical screen descriptor (width × height).\n".encode("utf-8"),
            (
                b"Discuss version "
                b"https://git-lfs.github.com/spec/v1 without pointer fields.\n"
            ),
        )

        for index, payload in enumerate(payloads):
            message_file = (
                Path(self.temporary_directory.name)
                / f"technical-message-{index}"
            )
            message_file.write_bytes(payload)
            with self.subTest(index=index):
                result = self.run_gate(
                    "--message-file",
                    str(message_file),
                )
                self.assert_allowed(result)


    def test_prefixed_lfs_commit_message_is_blocked_in_range(self) -> None:
        self.write(
            "Sources/PrefixedLFSMessage.swift",
            "struct PrefixedLFSMessage {}\n",
        )
        self.git("add", "-A")
        message_file = Path(self.temporary_directory.name) / "prefixed-lfs-message"
        message_file.write_bytes(
            b"synthetic metadata preface:" + CANONICAL_LFS_POINTER
        )
        subprocess.run(
            [
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "commit",
                "-F",
                str(message_file),
            ],
            cwd=self.repo,
            check=True,
            capture_output=True,
        )

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_blocked(result, "unscanned_lfs_pointer")


    def test_binary_commit_message_is_blocked_in_range_and_pre_push(self) -> None:
        bare_remote = Path(self.temporary_directory.name) / "metadata-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        self.git("config", "i18n.commitEncoding", "ISO-8859-1")
        self.write("Sources/BinaryMessage.swift", "struct BinaryMessage {}\n")
        self.git("add", "-A")
        marker = b"BINARY_METADATA_MARKER_MUST_NOT_BE_ECHOED"
        message_file = Path(self.temporary_directory.name) / "binary-message"
        message_file.write_bytes(
            b"synthetic metadata preface\n"
            b"\x89PNG\r\n\x1a\n"
            + marker
            + b"\n"
        )
        subprocess.run(
            [
                "git",
                "commit",
                "--cleanup=verbatim",
                "-F",
                str(message_file),
            ],
            cwd=self.repo,
            check=True,
            capture_output=True,
        )
        local_oid = self.git("rev-parse", "HEAD").stdout.strip()
        commit_object = subprocess.run(
            ["git", "cat-file", "commit", local_oid],
            cwd=self.repo,
            check=True,
            capture_output=True,
        ).stdout
        _, separator, commit_message = commit_object.partition(b"\n\n")
        self.assertTrue(separator)
        self.assertIn(b"\x89PNG\r\n\x1a\n", commit_message)
        hook_input = (
            f"refs/heads/main {local_oid} "
            f"refs/heads/main {self.base_oid}\n"
        )

        range_result = self.run_gate("--range", f"{self.base_oid}..HEAD")
        pre_push_result = self.run_gate(
            "--pre-push",
            "origin",
            input_text=hook_input,
        )

        for result in (range_result, pre_push_result):
            self.assert_blocked(result, "blocked_content_signature")
            self.assertNotIn(
                marker.decode("ascii"),
                result.stdout + result.stderr,
            )


    def test_binary_annotated_tag_message_is_blocked(self) -> None:
        bare_remote = Path(self.temporary_directory.name) / "tag-metadata-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        marker = b"TAG_METADATA_MARKER_MUST_NOT_BE_ECHOED"
        tag_object = (
            (
                f"object {self.base_oid}\n"
                "type commit\n"
                "tag binary-metadata\n"
                "tagger Privacy Gate Test "
                "<privacy-gate@example.invalid> 1700000000 +0000\n\n"
            ).encode("ascii")
            + b"synthetic metadata preface\n"
            + b"\x89PNG\r\n\x1a\n"
            + marker
            + b"\n"
        )
        tag_result = subprocess.run(
            ["git", "mktag"],
            cwd=self.repo,
            input=tag_object,
            check=True,
            capture_output=True,
        )
        tag_oid = tag_result.stdout.decode("ascii").strip()
        self.git("update-ref", "refs/tags/binary-metadata", tag_oid)
        self.git("fsck", "--strict", tag_oid)
        hook_input = (
            f"refs/tags/binary-metadata {tag_oid} "
            f"refs/tags/binary-metadata {ZERO_OID}\n"
        )

        result = self.run_gate(
            "--pre-push",
            "origin",
            input_text=hook_input,
        )

        self.assert_blocked(result, "blocked_content_signature")
        self.assertNotIn(
            marker.decode("ascii"),
            result.stdout + result.stderr,
        )


    def test_range_and_pre_push_ignore_git_replace_objects(self) -> None:
        bare_remote = Path(self.temporary_directory.name) / "replace-remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        self.write("private-evidence/leak.png", "synthetic image payload\n")
        self.commit("add synthetic private image")
        private_commit_oid = self.git("rev-parse", "HEAD").stdout.strip()
        safe_tree_oid = self.git(
            "rev-parse",
            f"{self.base_oid}^{{tree}}",
        ).stdout.strip()
        replacement_commit_oid = self.git(
            "commit-tree",
            safe_tree_oid,
            "-p",
            self.base_oid,
            "-m",
            "safe replacement",
        ).stdout.strip()
        self.git("replace", private_commit_oid, replacement_commit_oid)
        hook_input = (
            f"refs/heads/main {private_commit_oid} "
            f"refs/heads/main {self.base_oid}\n"
        )

        range_result = self.run_gate("--range", f"{self.base_oid}..HEAD")
        pre_push_result = self.run_gate(
            "--pre-push",
            "origin",
            input_text=hook_input,
        )

        self.assert_blocked(range_result, "blocked_artifact")
        self.assert_blocked(pre_push_result, "blocked_artifact")


    def test_range_allows_safe_commit(self) -> None:
        self.write("Sources/PrivacySafe.swift", "struct PrivacySafe {}\n")
        self.commit("add safe source")

        result = self.run_gate("--range", f"{self.base_oid}..HEAD")

        self.assert_allowed(result)


    def test_pre_push_new_branch_scans_outgoing_history(self) -> None:
        bare_remote = Path(self.temporary_directory.name) / "remote.git"
        subprocess.run(
            ["git", "init", "--bare", str(bare_remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.git("remote", "add", "origin", str(bare_remote))
        self.git("push", "-u", "origin", "main")
        self.git("switch", "-c", "feature/privacy-gate-test")
        self.write("local-evidence/runtime.trace", "synthetic trace\n")
        self.commit("add synthetic trace")
        local_oid = self.git("rev-parse", "HEAD").stdout.strip()
        hook_input = (
            f"refs/heads/feature/privacy-gate-test {local_oid} "
            f"refs/heads/feature/privacy-gate-test {ZERO_OID}\n"
        )

        result = self.run_gate("--pre-push", "origin", input_text=hook_input)

        self.assert_blocked(result, "blocked_artifact")
