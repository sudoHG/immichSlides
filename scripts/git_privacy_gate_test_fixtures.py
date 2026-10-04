"""Moved fixtures and imports shared by the existing test classes."""

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
