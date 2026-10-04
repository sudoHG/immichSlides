#!/usr/bin/env python3
"""Integration tests for the Git privacy gate using synthetic repositories."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("git_privacy_gate.py")
INSTALLER = Path(__file__).with_name("install_git_privacy_hooks.sh")
HOOKS_ROOT = Path(__file__).parent.parent / ".githooks"
REPOSITORY_ROOT = Path(__file__).parent.parent
TRUSTED_WORKFLOW = REPOSITORY_ROOT / ".github/workflows/privacy-preflight.yml"
BOOTSTRAP_WORKFLOW = (
    REPOSITORY_ROOT / ".github/workflows/privacy-preflight-bootstrap.yml"
)
TRUSTED_RUNNER = REPOSITORY_ROOT / "scripts/run_trusted_privacy_preflight.sh"
CONTRIBUTING = REPOSITORY_ROOT / "CONTRIBUTING.md"
SMART_FILL_UI_TESTS = (
    REPOSITORY_ROOT / "immichSlidesUITests/PlaybackSmartFillVisualUITests.swift"
)
ZERO_OID = "0" * 40
CANONICAL_LFS_POINTER = (
    b"version https://git-lfs.github.com/spec/v1\n"
    + b"oid sha256:"
    + (b"b" * 64)
    + b"\nsize 1234\n"
)


def make_minimal_pdf_payload() -> bytes:
    header = b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n"
    objects = (
        b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        b"2 0 obj\n<< /Type /Pages /Count 0 /Kids [] >>\nendobj\n",
    )
    offsets: list[int] = []
    payload = header
    for object_payload in objects:
        offsets.append(len(payload))
        payload += object_payload
    xref_offset = len(payload)
    xref_entries = b"".join(
        f"{offset:010d} 00000 n \n".encode("ascii")
        for offset in offsets
    )
    return (
        payload
        + b"xref\n0 3\n0000000000 65535 f \n"
        + xref_entries
        + b"trailer\n<< /Root 1 0 R /Size 3 >>\n"
        + f"startxref\n{xref_offset}\n%%EOF\n".encode("ascii")
    )


MINIMAL_PDF_PAYLOAD = make_minimal_pdf_payload()
MINIMAL_GIF_PAYLOAD = (
    b"GIF89a\x01\x00\x01\x00\x80\x00\x00"
    b"\x00\x00\x00\xff\xff\xff"
    b"!\xf9\x04\x01\x00\x00\x00\x00"
    b",\x00\x00\x00\x00\x01\x00\x01\x00\x00"
    b"\x02\x02D\x01\x00;"
)
PRINTABLE_DESCRIPTOR_GIF_PAYLOAD = (
    b"GIF89a!!!!!!!"
    b",\x00\x00\x00\x00\x01\x00\x01\x00\x80"
    b"\x00\x00\x00\xff\xff\xff"
    b"\x02\x02D\x01\x00;"
)


class GitPrivacyGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary_directory.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Privacy Gate Test")
        self.git("config", "user.email", "privacy-gate@example.invalid")
        self.write("Sources/App.swift", "struct App {}\n")
        self.commit("baseline")
        self.base_oid = self.git("rev-parse", "HEAD").stdout.strip()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

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
            "GIF89a 后面是逻辑屏幕描述符。\n".encode("utf-8"),
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

    def write(self, relative_path: str, content: str) -> None:
        path = self.repo / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-m", message)

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repo,
            check=True,
            capture_output=True,
            text=True,
        )

    def git_without_check(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

    def install_gate_files(self, *, configure: bool = True) -> None:
        scripts_directory = self.repo / "scripts"
        hooks_directory = self.repo / ".githooks"
        scripts_directory.mkdir(exist_ok=True)
        hooks_directory.mkdir(exist_ok=True)
        shutil.copy2(SCRIPT, scripts_directory / SCRIPT.name)
        shutil.copy2(INSTALLER, scripts_directory / INSTALLER.name)
        for hook_name in ("commit-msg", "pre-commit", "pre-push"):
            target = hooks_directory / hook_name
            shutil.copy2(HOOKS_ROOT / hook_name, target)
            target.chmod(0o755)
        if configure:
            subprocess.run(
                [str(scripts_directory / INSTALLER.name)],
                cwd=self.repo,
                check=True,
                capture_output=True,
                text=True,
            )

    def run_gate(
        self,
        *arguments: str,
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=self.repo,
            input=input_text,
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )

    def assert_allowed(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(
            result.returncode,
            0,
            msg=f"stdout={result.stdout}\nstderr={result.stderr}",
        )
        self.assertIn("PRIVACY_GATE_PASS", result.stdout)

    def assert_blocked(
        self,
        result: subprocess.CompletedProcess[str],
        reason: str,
    ) -> None:
        self.assertEqual(
            result.returncode,
            2,
            msg=f"stdout={result.stdout}\nstderr={result.stderr}",
        )
        self.assertIn("PRIVACY_GATE_BLOCKED", result.stderr)
        self.assertIn(reason, result.stderr)


class RepositoryPrivacyContractTests(unittest.TestCase):
    def test_trusted_workflow_executes_only_base_scanner(self) -> None:
        workflow = TRUSTED_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("pull_request_target:", workflow)
        trigger_line = next(
            line.strip()
            for line in workflow.splitlines()
            if line.strip().startswith("types:")
        )
        self.assertIn("edited", trigger_line)
        self.assertEqual(workflow.count("uses: actions/checkout@v4"), 1)
        self.assertIn(
            "ref: ${{ github.event.pull_request.base.sha }}",
            workflow,
        )
        self.assertIn(
            "run: scripts/run_trusted_privacy_preflight.sh",
            workflow,
        )
        self.assertNotIn(
            "ref: ${{ github.event.pull_request.head.sha }}",
            workflow,
        )
        self.assertNotIn("git checkout ", workflow)
        self.assertNotIn("git switch ", workflow)
        self.assertNotIn("git reset ", workflow)
        self.assertNotIn("git worktree ", workflow)
        self.assertNotIn("python3 scripts/git_privacy_gate.py", workflow)

    def test_trusted_runner_keeps_base_scanner_when_head_replaces_it(
        self,
    ) -> None:
        self.assertTrue(TRUSTED_RUNNER.is_file())
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory) / "trusted-runner"
            repository.mkdir()

            def git(*arguments: str) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    ["git", *arguments],
                    cwd=repository,
                    check=True,
                    capture_output=True,
                    text=True,
                )

            git("init", "-b", "main")
            git("config", "user.name", "Trusted Runner Test")
            git("config", "user.email", "trusted-runner@example.invalid")
            scripts_directory = repository / "scripts"
            scripts_directory.mkdir()
            shutil.copy2(
                TRUSTED_RUNNER,
                scripts_directory / TRUSTED_RUNNER.name,
            )
            (scripts_directory / "test_git_privacy_gate.py").write_text(
                "raise SystemExit(0)\n",
                encoding="utf-8",
            )
            marker_path = Path(temporary_directory) / "runner-marker"
            scanner_path = scripts_directory / SCRIPT.name
            scanner_path.write_text(
                (
                    "import os\n"
                    "from pathlib import Path\n"
                    "Path(os.environ['TRUST_MARKER']).write_text("
                    "'base', encoding='utf-8')\n"
                ),
                encoding="utf-8",
            )
            git("add", "-A")
            git("commit", "-m", "trusted base implementation")
            base_oid = git("rev-parse", "HEAD").stdout.strip()
            scanner_path.write_text(
                (
                    "import os\n"
                    "from pathlib import Path\n"
                    "Path(os.environ['TRUST_MARKER']).write_text("
                    "'head', encoding='utf-8')\n"
                ),
                encoding="utf-8",
            )
            git("add", "-A")
            git("commit", "-m", "candidate replacement")
            head_oid = git("rev-parse", "HEAD").stdout.strip()
            git("checkout", "--detach", base_oid)
            environment = os.environ.copy()
            environment.update(
                {
                    "PRIVACY_BASE_SHA": base_oid,
                    "PRIVACY_HEAD_SHA": head_oid,
                    "TRUST_MARKER": str(marker_path),
                }
            )

            result = subprocess.run(
                [str(scripts_directory / TRUSTED_RUNNER.name)],
                cwd=repository,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(
                result.returncode,
                0,
                msg=f"stdout={result.stdout}\nstderr={result.stderr}",
            )
            self.assertEqual(marker_path.read_text(encoding="utf-8"), "base")
            self.assertEqual(git("rev-parse", "HEAD").stdout.strip(), base_oid)

    def test_contributing_marks_trusted_check_as_post_merge_boundary(self) -> None:
        contributing = CONTRIBUTING.read_text(encoding="utf-8")

        self.assertIn("trusted only for subsequent pull requests after it is merged into `main`", contributing)
        self.assertIn("from the PR's base commit, never from the candidate tree", contributing)
        self.assertIn("not a substitute for the trusted check", contributing)

    def test_bootstrap_check_has_distinct_nontrusted_name(self) -> None:
        workflow = BOOTSTRAP_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("pull_request:", workflow)
        self.assertIn("name: privacy-preflight-bootstrap", workflow)
        self.assertNotIn("name: privacy-preflight-trusted", workflow)

    def test_playback_transition_evidence_uses_private_directory_resolver(self) -> None:
        source = SMART_FILL_UI_TESTS.read_text(encoding="utf-8")
        start = source.index("func playbackTransitionEvidenceDirectory()")
        end = source.index("\n    func waitUntil(", start)
        implementation = source[start:end]

        self.assertIn("PrivateEvidenceDirectory.resolve(", implementation)
        self.assertNotIn("URL(fileURLWithPath:", implementation)


if __name__ == "__main__":
    unittest.main()
