#!/usr/bin/env python3
"""Block sensitive artifacts from leaving this machine through Git commits or pushes."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Iterable


BLOCKED_EXIT_CODE = 2
ERROR_EXIT_CODE = 3
MAX_BLOB_BYTES = 1024 * 1024

BLOCKED_EXTENSIONS = {
    ".cer",
    ".csv",
    ".der",
    ".har",
    ".heic",
    ".jpeg",
    ".jpg",
    ".jsonl",
    ".key",
    ".log",
    ".mobileprovision",
    ".mov",
    ".mp4",
    ".p12",
    ".p8",
    ".pem",
    ".png",
    ".trace",
    ".tsv",
    ".xcresult",
}
BLOCKED_FILENAMES = {
    ".env",
    "env.xcconfig",
}
BLOCKED_PATH_COMPONENTS = {
    ".smartfill-runtime-evidence",
    "artifacts",
    "attachments",
    "evidence",
    "motion-runtime",
    "runtime-video",
    "screenshots",
    "ui-runtime",
    "unscoped-blob-ref",
    "xcresult",
    "xcresults",
}
BLOCKED_PATH_SUFFIXES = (
    "-evidence",
    "_evidence",
)

SECRET_ASSIGNMENT_PATTERN = re.compile(
    rb"(?i)\b(?:api[_ -]?key|access[_ -]?token|authorization|bearer)"
    rb"\s*[:=]\s*(?:\#*(?:\"\"\"|\"|')\s*)?(?P<value>[A-Za-z0-9_./+=-]{16,})"
)
SWIFT_REFERENCE_PATTERN = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*")
SWIFT_DECLARATION_PATTERN = re.compile(
    rb"\b(?:let|var)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*[:=]"
)
SWIFT_LITERAL_START_PATTERN = re.compile(rb'(\#*)("""|")')
SWIFT_REGEX_START_PATTERN = re.compile(rb'(\#*)/')
# A method call on a type or instance, e.g. `Bundle.main.object(` or `Service.shared.getApiKey(`.
# A bare token followed by `(` is not enough: it must be a dotted path rooted in a type name.
SWIFT_CALL_REFERENCE_PATTERN = re.compile(
    rb"[A-Z][A-Za-z0-9_]*(?:\.[a-z_][A-Za-z0-9_]*)+"
)
SWIFT_REFERENCE_END_PATTERN = re.compile(
    rb'[ \t]*(?:\?\?[ \t]*""[ \t]*)?(?:[,);}]|\r?\n|//|/\*|\Z)'
)

HIGH_CONFIDENCE_SECRET_PATTERNS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    SECRET_ASSIGNMENT_PATTERN,
    re.compile(rb"/" + rb"Users/[A-Za-z0-9._-]+/"),
)

BLOCKED_CONTENT_SIGNATURES = (
    b"\x89PNG\r\n\x1a\n",
    b"\xff\xd8\xff",
    b"GIF87a",
    b"GIF89a",
    b"%PDF-",
    b"PK\x03\x04",
    b"PK\x05\x06",
    b"PK\x07\x08",
    b"\x1f\x8b",
    b"7z\xbc\xaf\x27\x1c",
    b"Rar!\x1a\x07",
    b"SQLite format 3\x00",
)
EMBEDDED_BINARY_CONTENT_SIGNATURES = tuple(
    signature
    for signature in BLOCKED_CONTENT_SIGNATURES
    if signature not in (b"GIF87a", b"GIF89a", b"%PDF-")
)
PDF_HEADER_PATTERN = re.compile(rb"%PDF-[0-9]\.[0-9]")
PDF_OBJECT_PATTERN = re.compile(
    rb"(?m)^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+obj\b"
)
PDF_XREF_TABLE_PATTERN = re.compile(rb"(?m)^[ \t]*xref[ \t]*\r?$")
PDF_TRAILER_PATTERN = re.compile(rb"(?m)^[ \t]*trailer\b")
PDF_XREF_STREAM_PATTERN = re.compile(rb"/Type[ \t\r\n]*/XRef\b")
PDF_END_PATTERN = re.compile(rb"startxref[ \t\r\n]+[0-9]+[ \t\r\n]+%%EOF")
LFS_POINTER_BLOCK_PATTERN = re.compile(
    rb"version https://git-lfs.github.com/spec/v1\r?\n"
    rb"(?:ext-[^\r\n]+\r?\n)*"
    rb"oid sha256:[0-9a-fA-F]{64}\r?\n"
    rb"size [0-9]+(?:\r?\n|\Z)"
)


class PrivacyGateError(RuntimeError):
    """The gate could not reliably complete the scan."""


@dataclass(frozen=True)
class BlobCandidate:
    oid: str
    path: str
    source: str
    mode: str = ""


@dataclass(frozen=True)
class MetadataCandidate:
    payload: bytes
    label: str
    message_payload: bytes | None = None


@dataclass(frozen=True)
class Finding:
    reason: str
    path: str
    size: int | None


def run_git(
    *arguments: str,
    input_bytes: bytes | None = None,
) -> subprocess.CompletedProcess[bytes]:
    environment = os.environ.copy()
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    result = subprocess.run(
        ["git", *arguments],
        input=input_bytes,
        capture_output=True,
        check=False,
        env=environment,
    )
    if result.returncode != 0:
        command = "git " + " ".join(arguments)
        raise PrivacyGateError(
            f"{command} failed with exit {result.returncode}"
        )
    return result


def git_object_exists(oid: str) -> bool:
    environment = os.environ.copy()
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    result = subprocess.run(
        ["git", "cat-file", "-e", oid],
        capture_output=True,
        check=False,
        env=environment,
    )
    return result.returncode == 0


def git_commitish_exists(oid: str) -> bool:
    environment = os.environ.copy()
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    result = subprocess.run(
        ["git", "cat-file", "-e", f"{oid}^{{commit}}"],
        capture_output=True,
        check=False,
        env=environment,
    )
    return result.returncode == 0


def decode_path(raw_path: bytes) -> str:
    return raw_path.decode("utf-8", errors="surrogateescape")


def index_entries() -> tuple[dict[str, tuple[str, str]], list[str]]:
    blobs: dict[str, tuple[str, str]] = {}
    paths: list[str] = []
    for record in run_git("ls-files", "--stage", "-z").stdout.split(b"\0"):
        if not record or b"\t" not in record:
            continue
        metadata, raw_path = record.split(b"\t", maxsplit=1)
        fields = metadata.split()
        if len(fields) != 3 or fields[2] != b"0":
            continue
        path = decode_path(raw_path)
        paths.append(path)
        oid = fields[1].decode("ascii")
        if object_type(oid) == "blob":
            blobs[path] = (oid, fields[0].decode("ascii"))
    return blobs, paths


def staged_changed_paths() -> list[str]:
    return [
        decode_path(raw_path)
        for raw_path in run_git(
            "diff",
            "--cached",
            "--name-only",
            "--diff-filter=ACMRT",
            "-z",
        ).stdout.split(b"\0")
        if raw_path
    ]


def staged_candidates(
    changed_paths: Iterable[str],
    blobs: dict[str, tuple[str, str]],
) -> list[BlobCandidate]:
    return [
        BlobCandidate(oid=blobs[path][0], path=path, source="staged", mode=blobs[path][1])
        for path in changed_paths
        if path in blobs
    ]


def commits_for_range(revision_range: str) -> list[str]:
    output = run_git("rev-list", revision_range).stdout.decode("ascii")
    return [line for line in output.splitlines() if line]


def remote_commitish_oids(remote_name: str) -> list[str]:
    output = run_git("ls-remote", "--refs", remote_name).stdout
    advertised_refs: list[tuple[str, str]] = []
    missing_ref_oids: list[str] = []
    commitish_oids: set[str] = set()
    for line_number, line in enumerate(output.splitlines(), start=1):
        fields = line.split(maxsplit=1)
        if len(fields) != 2:
            raise PrivacyGateError(
                f"invalid ls-remote output at line {line_number}"
            )
        oid = fields[0].decode("ascii")
        remote_ref = decode_path(fields[1])
        advertised_refs.append((oid, remote_ref))
        if git_object_exists(oid) and git_commitish_exists(oid):
            commitish_oids.add(oid)
        elif remote_ref.startswith(("refs/heads/", "refs/tags/")):
            missing_ref_oids.append(oid)

    if missing_ref_oids:
        run_git(
            "fetch",
            "--quiet",
            "--no-tags",
            "--no-write-fetch-head",
            "--no-auto-maintenance",
            remote_name,
            *sorted(set(missing_ref_oids)),
        )

    for oid, remote_ref in advertised_refs:
        if not remote_ref.startswith(("refs/heads/", "refs/tags/")):
            continue
        if not git_object_exists(oid):
            raise PrivacyGateError("remote ref object unavailable after fetch")
        if remote_ref.startswith("refs/heads/") and not git_commitish_exists(oid):
            raise PrivacyGateError("remote branch tip unavailable after fetch")
        if git_commitish_exists(oid):
            commitish_oids.add(oid)
    return sorted(commitish_oids)


def peel_tag_chain(oid: str) -> tuple[str, list[MetadataCandidate]]:
    candidates: list[MetadataCandidate] = []
    visited: set[str] = set()
    current_oid = oid
    while object_type(current_oid) == "tag":
        if current_oid in visited:
            raise PrivacyGateError("cyclic annotated tag chain")
        visited.add(current_oid)
        tag_object = run_git("cat-file", "tag", current_oid).stdout
        header, separator, message = tag_object.partition(b"\n\n")
        if not separator:
            raise PrivacyGateError("invalid annotated tag object")
        candidates.append(
            MetadataCandidate(
                payload=tag_object,
                label=f"tag-metadata:{current_oid[:12]}",
                message_payload=message,
            )
        )
        target_match = re.search(rb"(?m)^object ([0-9a-fA-F]+)$", header)
        if target_match is None:
            raise PrivacyGateError("annotated tag target unavailable")
        current_oid = target_match.group(1).decode("ascii")
        if not git_object_exists(current_oid):
            raise PrivacyGateError("annotated tag target unavailable")
    return current_oid, candidates


def commits_for_pre_push(
    remote_name: str,
    hook_input: str,
) -> tuple[
    list[str],
    list[MetadataCandidate],
    list[BlobCandidate],
    list[str],
]:
    updates: list[tuple[int, str, str, str]] = []
    for line_number, line in enumerate(hook_input.splitlines(), start=1):
        fields = line.split()
        if len(fields) != 4:
            raise PrivacyGateError(
                f"invalid pre-push input at line {line_number}"
            )
        local_ref, local_oid, remote_ref, _ = fields
        if local_oid and set(local_oid) == {"0"}:
            continue
        updates.append((line_number, local_ref, local_oid, remote_ref))

    if not updates:
        return [], [], [], []

    remote_oids = remote_commitish_oids(remote_name)
    commits: set[str] = set()
    metadata: list[MetadataCandidate] = []
    direct_candidates: dict[tuple[str, str, str], BlobCandidate] = {}
    direct_paths: set[str] = set()
    for line_number, local_ref, local_oid, remote_ref in updates:
        if not git_object_exists(local_oid):
            raise PrivacyGateError(
                f"local object unavailable at pre-push line {line_number}"
            )
        metadata.extend(
            [
                MetadataCandidate(
                    payload=local_ref.encode("utf-8", errors="surrogateescape"),
                    label="local-ref-name",
                ),
                MetadataCandidate(
                    payload=remote_ref.encode("utf-8", errors="surrogateescape"),
                    label="remote-ref-name",
                ),
            ]
        )
        terminal_oid, tag_metadata = peel_tag_chain(local_oid)
        metadata.extend(tag_metadata)
        terminal_type = object_type(terminal_oid)
        if terminal_type == "commit":
            arguments = ["rev-list", terminal_oid]
            if remote_oids:
                arguments.extend(["--not", *remote_oids])
            output = run_git(*arguments).stdout.decode("ascii")
            commits.update(line for line in output.splitlines() if line)
        elif terminal_type == "blob":
            path = f"unscoped-blob-ref/{terminal_oid[:12]}"
            candidate = BlobCandidate(
                oid=terminal_oid,
                path=path,
                source=local_ref,
            )
            direct_candidates[(terminal_oid, path, candidate.mode)] = candidate
            direct_paths.add(path)
        elif terminal_type == "tree":
            blobs, paths = tree_entries(terminal_oid)
            direct_paths.update(paths)
            for path, (blob_oid, mode) in blobs.items():
                candidate = BlobCandidate(
                    oid=blob_oid,
                    path=path,
                    source=local_ref,
                    mode=mode,
                )
                direct_candidates[(blob_oid, path, mode)] = candidate
        else:
            raise PrivacyGateError(
                f"unsupported ref target type at pre-push line {line_number}"
            )
    return (
        sorted(commits),
        metadata,
        list(direct_candidates.values()),
        sorted(direct_paths),
    )


def tree_entries(treeish: str) -> tuple[dict[str, tuple[str, str]], list[str]]:
    blobs: dict[str, tuple[str, str]] = {}
    paths: list[str] = []
    for record in run_git(
        "ls-tree",
        "-r",
        "-z",
        "--full-tree",
        treeish,
    ).stdout.split(b"\0"):
        if not record or b"\t" not in record:
            continue
        metadata, raw_path = record.split(b"\t", maxsplit=1)
        fields = metadata.split()
        if len(fields) != 3:
            continue
        path = decode_path(raw_path)
        paths.append(path)
        if fields[1] == b"blob":
            blobs[path] = (fields[2].decode("ascii"), fields[0].decode("ascii"))
    return blobs, paths


def candidates_for_commits(
    commits: Iterable[str],
) -> tuple[list[BlobCandidate], list[str]]:
    candidates: dict[tuple[str, str, str], BlobCandidate] = {}
    all_changed_paths: set[str] = set()
    for commit in commits:
        changed_paths = [
            decode_path(raw_path)
            for raw_path in run_git(
                "diff-tree",
                "--root",
                "-m",
                "--no-commit-id",
                "--name-only",
                "--diff-filter=ACMRT",
                "-r",
                "-z",
                commit,
            ).stdout.split(b"\0")
            if raw_path
        ]
        blobs, tree_paths = tree_entries(commit)
        current_paths = set(tree_paths)
        current_changed_paths = [
            path for path in changed_paths if path in current_paths
        ]
        all_changed_paths.update(current_changed_paths)
        for path in current_changed_paths:
            entry = blobs.get(path)
            if entry is None:
                continue
            oid, mode = entry
            candidate = BlobCandidate(oid=oid, path=path, source=commit, mode=mode)
            candidates[(oid, path, mode)] = candidate
    return list(candidates.values()), sorted(all_changed_paths)


def metadata_for_commits(commits: Iterable[str]) -> list[MetadataCandidate]:
    candidates: list[MetadataCandidate] = []
    for commit in commits:
        commit_object = run_git("cat-file", "commit", commit).stdout
        _, separator, message = commit_object.partition(b"\n\n")
        if not separator:
            raise PrivacyGateError("invalid commit object")
        candidates.append(
            MetadataCandidate(
                payload=commit_object,
                label=f"commit-metadata:{commit[:12]}",
                message_payload=message,
            )
        )
    return candidates


def object_type(oid: str) -> str:
    return run_git("cat-file", "-t", oid).stdout.decode("ascii").strip()


def blob_size(oid: str) -> int:
    return int(run_git("cat-file", "-s", oid).stdout.decode("ascii").strip())


def blob_contents(oid: str) -> bytes:
    return run_git("cat-file", "blob", oid).stdout


def is_blocked_artifact_path(path: str) -> bool:
    normalized_path = PurePosixPath(path)
    lowered_components = [component.lower() for component in normalized_path.parts]
    lowered_name = normalized_path.name.lower()
    if lowered_name in BLOCKED_FILENAMES or lowered_name.startswith(".env."):
        return True
    if normalized_path.suffix.lower() in BLOCKED_EXTENSIONS:
        return True
    for component in lowered_components:
        if component in BLOCKED_PATH_COMPONENTS:
            return True
        if component.endswith(BLOCKED_PATH_SUFFIXES):
            return True
        if component.endswith(".xcresult"):
            return True
    return False


def normalized_secret_payloads(payload: bytes) -> list[bytes]:
    candidates = [payload]
    if b"\0" not in payload:
        return candidates
    candidates.append(payload.replace(b"\0", b""))
    for encoding in ("utf-16", "utf-16-le", "utf-16-be"):
        try:
            normalized = payload.decode(encoding).encode("utf-8")
        except (UnicodeDecodeError, UnicodeError):
            continue
        candidates.append(normalized)
    return candidates


def swift_code_mask(payload: bytes) -> bytearray:
    """Mark only unambiguous code regions; protect interpolation and slash ambiguities to avoid exempting literals as code."""
    mask = bytearray(b"\x01") * len(payload)
    offset = 0
    while offset < len(payload):
        start = offset
        if payload.startswith(b"//", offset):
            end = payload.find(b"\n", offset)
            offset = end if end >= 0 else len(payload)
        elif payload.startswith(b"/*", offset):
            depth = 1
            offset += 2
            while offset < len(payload) and depth:
                if payload.startswith(b"/*", offset):
                    depth += 1
                    offset += 2
                elif payload.startswith(b"*/", offset):
                    depth -= 1
                    offset += 2
                else:
                    offset += 1
        else:
            regex_opener = SWIFT_REGEX_START_PATTERN.match(payload, offset)
            if regex_opener is not None:
                hashes = regex_opener.group(1)
                if hashes:
                    end = payload.rfind(b"/" + hashes, regex_opener.end())
                    offset = end + 1 + len(hashes) if end >= 0 else len(payload)
                else:
                    end = payload.find(b"\n", regex_opener.end())
                    offset = end if end >= 0 else len(payload)
                mask[start:offset] = b"\0" * (offset - start)
                continue
            opener = SWIFT_LITERAL_START_PATTERN.match(payload, offset)
            if opener is None:
                offset += 1
                continue
            hashes, quotes = opener.groups()
            closing = quotes + hashes
            escape = b"\\" + hashes
            offset = opener.end()
            while offset < len(payload):
                if payload.startswith(escape, offset):
                    offset += len(escape) + 1
                elif payload.startswith(closing, offset):
                    offset += len(closing)
                    break
                else:
                    offset += 1
        mask[start:offset] = b"\0" * (min(offset, len(payload)) - start)
    return mask


def contains_high_confidence_secret(payload: bytes, *, swift_source: bool = False) -> bool:
    for candidate_payload in normalized_secret_payloads(payload):
        code_mask = None
        declarations: dict[bytes, int] = {}
        for pattern in HIGH_CONFIDENCE_SECRET_PATTERNS:
            for match in pattern.finditer(candidate_payload):
                if swift_source and pattern is SECRET_ASSIGNMENT_PATTERN:
                    if code_mask is None:
                        code_mask = swift_code_mask(candidate_payload)
                        for declaration in SWIFT_DECLARATION_PATTERN.finditer(candidate_payload):
                            if all(code_mask[declaration.start():declaration.end()]):
                                declarations.setdefault(declaration.group("name"), declaration.start())
                    root_symbol = match.group("value").split(b".", maxsplit=1)[0]
                    if all(code_mask[match.start():match.end()]) and (
                        (
                            SWIFT_REFERENCE_PATTERN.fullmatch(match.group("value"))
                            and declarations.get(root_symbol, match.start()) < match.start()
                            and SWIFT_REFERENCE_END_PATTERN.match(candidate_payload, match.end())
                        )
                        or (
                            SWIFT_CALL_REFERENCE_PATTERN.fullmatch(match.group("value"))
                            and candidate_payload[match.end():match.end() + 1] == b"("
                        )
                    ):
                        continue
                return True
    return False


def sanitized_finding_path(path: str) -> str:
    raw_path = path.encode("utf-8", errors="surrogateescape")
    if contains_high_confidence_secret(raw_path):
        return "<redacted-path>"
    return "".join(
        character if character.isprintable() else "?"
        for character in path
    )


def has_blocked_content_signature(payload: bytes) -> bool:
    if any(payload.startswith(signature) for signature in BLOCKED_CONTENT_SIGNATURES):
        return True
    if len(payload) >= 12 and payload[4:8] == b"ftyp":
        return True
    return has_embedded_pdf_document(payload)


def has_embedded_pdf_document(payload: bytes) -> bool:
    for header_match in PDF_HEADER_PATTERN.finditer(payload):
        document = payload[header_match.start():]
        object_match = PDF_OBJECT_PATTERN.search(document)
        if object_match is None:
            continue
        end_object_offset = document.find(b"endobj", object_match.end())
        if end_object_offset < 0:
            continue
        end_match = PDF_END_PATTERN.search(document, end_object_offset)
        if end_match is None:
            continue
        xref_table_match = PDF_XREF_TABLE_PATTERN.search(
            document,
            end_object_offset,
            end_match.start(),
        )
        if xref_table_match is not None:
            trailer_match = PDF_TRAILER_PATTERN.search(
                document,
                xref_table_match.end(),
                end_match.start(),
            )
            if trailer_match is not None:
                return True
        if PDF_XREF_STREAM_PATTERN.search(
            document,
            object_match.end(),
            end_match.start(),
        ):
            return True
    return False


def gif_sub_blocks_end(payload: bytes, offset: int) -> int | None:
    while offset < len(payload):
        block_size = payload[offset]
        offset += 1
        if block_size == 0:
            return offset
        offset += block_size
        if offset > len(payload):
            return None
    return None


def gif_document_end(payload: bytes, start: int) -> int | None:
    logical_screen_start = start + 6
    logical_screen_end = logical_screen_start + 7
    if logical_screen_end > len(payload):
        return None
    width = int.from_bytes(
        payload[logical_screen_start:logical_screen_start + 2],
        "little",
    )
    height = int.from_bytes(
        payload[logical_screen_start + 2:logical_screen_start + 4],
        "little",
    )
    if width == 0 or height == 0:
        return None
    packed_fields = payload[logical_screen_start + 4]
    offset = logical_screen_end
    if packed_fields & 0x80:
        color_table_size = 3 * (2 ** ((packed_fields & 0x07) + 1))
        offset += color_table_size
        if offset > len(payload):
            return None

    saw_image = False
    while offset < len(payload):
        introducer = payload[offset]
        offset += 1
        if introducer == 0x3B:
            return offset if saw_image else None
        if introducer == 0x21:
            if offset >= len(payload):
                return None
            offset += 1
            next_offset = gif_sub_blocks_end(payload, offset)
            if next_offset is None:
                return None
            offset = next_offset
            continue
        if introducer != 0x2C:
            return None

        image_descriptor_end = offset + 9
        if image_descriptor_end > len(payload):
            return None
        image_width = int.from_bytes(payload[offset + 4:offset + 6], "little")
        image_height = int.from_bytes(payload[offset + 6:offset + 8], "little")
        if image_width == 0 or image_height == 0:
            return None
        image_packed_fields = payload[offset + 8]
        offset = image_descriptor_end
        if image_packed_fields & 0x80:
            local_table_size = 3 * (2 ** ((image_packed_fields & 0x07) + 1))
            offset += local_table_size
            if offset > len(payload):
                return None
        if offset >= len(payload) or not 1 <= payload[offset] <= 8:
            return None
        offset += 1
        next_offset = gif_sub_blocks_end(payload, offset)
        if next_offset is None:
            return None
        offset = next_offset
        saw_image = True
    return None


def has_embedded_gif_document(payload: bytes) -> bool:
    for gif_signature in (b"GIF87a", b"GIF89a"):
        search_offset = 0
        while True:
            signature_offset = payload.find(gif_signature, search_offset)
            if signature_offset < 0:
                break
            if gif_document_end(payload, signature_offset) is not None:
                return True
            search_offset = signature_offset + 1
    return False


def has_embedded_blocked_content_signature(payload: bytes) -> bool:
    if any(
        signature in payload
        for signature in EMBEDDED_BINARY_CONTENT_SIGNATURES
    ):
        return True
    if has_embedded_pdf_document(payload):
        return True
    if has_embedded_gif_document(payload):
        return True
    search_offset = 0
    while True:
        signature_offset = payload.find(b"ftyp", search_offset)
        if signature_offset < 0:
            return False
        search_offset = signature_offset + 1
        if signature_offset < 4:
            continue
        box_start = signature_offset - 4
        available_size = len(payload) - box_start
        box_size = int.from_bytes(payload[box_start:signature_offset], "big")
        if box_size == 0:
            return True
        if box_size == 1:
            extended_size_end = signature_offset + 12
            if extended_size_end > len(payload):
                continue
            extended_size = int.from_bytes(
                payload[signature_offset + 4:extended_size_end],
                "big",
            )
            if 16 <= extended_size <= available_size:
                return True
        elif 8 <= box_size <= available_size:
            return True


def is_lfs_pointer(payload: bytes) -> bool:
    return LFS_POINTER_BLOCK_PATTERN.fullmatch(payload) is not None


def contains_embedded_lfs_pointer(payload: bytes) -> bool:
    return LFS_POINTER_BLOCK_PATTERN.search(payload) is not None


def scan_paths(
    paths: Iterable[str],
    blob_paths: set[str],
) -> list[Finding]:
    findings: set[Finding] = set()
    for path in paths:
        if path in blob_paths:
            continue
        finding_path = sanitized_finding_path(path)
        if is_blocked_artifact_path(path):
            findings.add(
                Finding(
                    reason="blocked_artifact",
                    path=finding_path,
                    size=None,
                )
            )
        if contains_high_confidence_secret(
            path.encode("utf-8", errors="surrogateescape")
        ):
            findings.add(
                Finding(
                    reason="high_confidence_secret",
                    path=finding_path,
                    size=None,
                )
            )
    return sorted(findings, key=lambda finding: (finding.path, finding.reason))


def scan_candidates(candidates: Iterable[BlobCandidate]) -> tuple[list[Finding], int]:
    findings: set[Finding] = set()
    scanned_blob_oids: set[str] = set()
    size_cache: dict[str, int] = {}
    payload_cache: dict[str, bytes] = {}
    for candidate in candidates:
        if candidate.oid not in size_cache:
            size_cache[candidate.oid] = blob_size(candidate.oid)
        size = size_cache[candidate.oid]
        finding_path = sanitized_finding_path(candidate.path)
        scanned_blob_oids.add(candidate.oid)
        if is_blocked_artifact_path(candidate.path):
            findings.add(
                Finding(
                    reason="blocked_artifact",
                    path=finding_path,
                    size=size,
                )
            )
        if contains_high_confidence_secret(
            candidate.path.encode("utf-8", errors="surrogateescape")
        ):
            findings.add(
                Finding(
                    reason="high_confidence_secret",
                    path=finding_path,
                    size=size,
                )
            )
        if size > MAX_BLOB_BYTES:
            findings.add(
                Finding(
                    reason="oversized_blob",
                    path=finding_path,
                    size=size,
                )
            )
            continue
        if candidate.oid not in payload_cache:
            payload_cache[candidate.oid] = blob_contents(candidate.oid)
        payload = payload_cache[candidate.oid]
        if is_lfs_pointer(payload):
            findings.add(
                Finding(
                    reason="unscanned_lfs_pointer",
                    path=finding_path,
                    size=size,
                )
            )
        if has_blocked_content_signature(payload):
            findings.add(
                Finding(
                    reason="blocked_content_signature",
                    path=finding_path,
                    size=size,
                )
            )
        if contains_high_confidence_secret(
            payload,
            swift_source=candidate.mode in {"100644", "100755"}
            and PurePosixPath(candidate.path).suffix == ".swift",
        ):
            findings.add(
                Finding(
                    reason="high_confidence_secret",
                    path=finding_path,
                    size=size,
                )
            )
    return sorted(findings, key=lambda finding: (finding.path, finding.reason)), len(
        scanned_blob_oids
    )


def scan_metadata(candidates: Iterable[MetadataCandidate]) -> list[Finding]:
    findings: set[Finding] = set()
    for candidate in candidates:
        size = len(candidate.payload)
        if size > MAX_BLOB_BYTES:
            findings.add(
                Finding(
                    reason="oversized_metadata",
                    path=candidate.label,
                    size=size,
                )
            )
            continue
        if contains_high_confidence_secret(candidate.payload):
            findings.add(
                Finding(
                    reason="high_confidence_secret",
                    path=candidate.label,
                    size=size,
                )
            )
        if candidate.message_payload is None:
            continue
        message_size = len(candidate.message_payload)
        if contains_embedded_lfs_pointer(candidate.message_payload):
            findings.add(
                Finding(
                    reason="unscanned_lfs_pointer",
                    path=candidate.label,
                    size=message_size,
                )
            )
        if has_embedded_blocked_content_signature(candidate.message_payload):
            findings.add(
                Finding(
                    reason="blocked_content_signature",
                    path=candidate.label,
                    size=message_size,
                )
            )
    return sorted(findings, key=lambda finding: (finding.path, finding.reason))


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Scan staged or outgoing Git content before it leaves the machine."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--staged", action="store_true")
    mode.add_argument("--range", dest="revision_range")
    mode.add_argument("--pre-push", metavar="REMOTE_NAME")
    mode.add_argument("--message-file", metavar="FILE")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    candidates: list[BlobCandidate] = []
    changed_paths: list[str] = []
    metadata_candidates: list[MetadataCandidate] = []
    try:
        if arguments.staged:
            staged_paths = staged_changed_paths()
            blobs, index_paths = index_entries()
            current_paths = set(index_paths)
            changed_paths = [
                path for path in staged_paths if path in current_paths
            ]
            candidates = staged_candidates(changed_paths, blobs)
        elif arguments.revision_range:
            commits = commits_for_range(arguments.revision_range)
            candidates, changed_paths = candidates_for_commits(commits)
            metadata_candidates = metadata_for_commits(commits)
        elif arguments.pre_push:
            (
                commits,
                metadata_candidates,
                direct_candidates,
                direct_paths,
            ) = commits_for_pre_push(
                arguments.pre_push,
                sys.stdin.read(),
            )
            commit_candidates, commit_paths = candidates_for_commits(commits)
            candidates = [*direct_candidates, *commit_candidates]
            changed_paths = [*direct_paths, *commit_paths]
            metadata_candidates.extend(metadata_for_commits(commits))
        else:
            message_payload = Path(arguments.message_file).read_bytes()
            metadata_candidates = [
                MetadataCandidate(
                    payload=message_payload,
                    label="commit-message",
                    message_payload=message_payload,
                )
            ]
        blob_paths = {candidate.path for candidate in candidates}
        path_findings = scan_paths(changed_paths, blob_paths)
        blob_findings, scanned_blob_count = scan_candidates(candidates)
        metadata_findings = scan_metadata(metadata_candidates)
        findings = sorted(
            [*path_findings, *blob_findings, *metadata_findings],
            key=lambda finding: (finding.path, finding.reason),
        )
    except (OSError, PrivacyGateError, ValueError) as error:
        print(
            f"PRIVACY_GATE_ERROR {type(error).__name__}",
            file=sys.stderr,
        )
        return ERROR_EXIT_CODE

    if findings:
        print(
            f"PRIVACY_GATE_BLOCKED findings={len(findings)}",
            file=sys.stderr,
        )
        for finding in findings:
            size = "unknown" if finding.size is None else str(finding.size)
            print(
                f"- {finding.reason} path={finding.path} size={size}",
                file=sys.stderr,
            )
        return BLOCKED_EXIT_CODE

    print(
        "PRIVACY_GATE_PASS "
        f"scanned_blobs={scanned_blob_count} "
        f"scanned_metadata={len(metadata_candidates)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
