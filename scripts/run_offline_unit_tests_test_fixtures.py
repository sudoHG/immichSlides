"""Moved fixtures and imports shared by the existing test classes."""

from __future__ import annotations


import argparse


import contextlib


import io


import json


import re


import shutil


import subprocess


import sys


import tempfile


import time


import unittest


from unittest.mock import patch


from pathlib import Path


from typing import Iterator


from xml.etree import ElementTree


SCRIPT_DIR = Path(__file__).resolve().parent


REPO_ROOT = SCRIPT_DIR.parent


sys.path.insert(0, str(SCRIPT_DIR))


from run_offline_unit_tests import (  # noqa: E402
    CommandError,
    DEFAULT_TIMEOUT_MINUTES,
    EXTERNAL_RUNTIME_TEST_SELECTOR,
    ACCESS_LIFECYCLE_HOST_SELECTORS,
    MIN_DATA_GIB,
    TIMEOUT_EXIT_CODE,
    build_test_command,
    classify_test_results,
    default_run,
    ensure_disk_for_xcodebuild,
    inspect_config,
    is_placeholder_config,
    main,
    parse_non_negative_int,
    parse_official_test_results_summary,
    prepare_example_config,
    read_official_test_results_summary,
    resolve_suite_selectors,
)


GENERIC_SCHEME = (
    REPO_ROOT / "immichSlides.xcodeproj/xcshareddata/xcschemes/immichSlides.xcscheme"
)


IOS_SCHEME = (
    REPO_ROOT / "immichSlides.xcodeproj/xcshareddata/xcschemes/immichSlides-iOS.xcscheme"
)


TVOS_SCHEME = (
    REPO_ROOT / "immichSlides.xcodeproj/xcshareddata/xcschemes/immichSlides-tvOS.xcscheme"
)


PBXPROJ = REPO_ROOT / "immichSlides.xcodeproj/project.pbxproj"


IOS_PLAN = REPO_ROOT / "immichSlides-iOS.xctestplan"


TVOS_PLAN = REPO_ROOT / "immichSlides-tvOS.xctestplan"


MISSING_GENERIC_PLAN = "immichSlides.xctestplan"


ZERO_COUNT_OFFICIAL_SUMMARY = {
    "totalTestCount": 0,
    "passedTests": 0,
    "failedTests": 0,
    "skippedTests": 0,
    "result": "unknown",
}


IOS_ONE_PASSED_OFFICIAL_SUMMARY = {
    "totalTestCount": 1,
    "passedTests": 1,
    "failedTests": 0,
    "skippedTests": 0,
    "result": "Passed",
}


TVOS_ONE_PASSED_OFFICIAL_SUMMARY = {
    "totalTestCount": 1,
    "passedTests": 1,
    "failedTests": 0,
    "skippedTests": 0,
    "result": "Passed",
}


def scheme_test_plan_names(scheme_path: Path) -> list[str]:
    tree = ElementTree.parse(scheme_path)
    names: list[str] = []
    for node in tree.iter("TestPlanReference"):
        reference = node.attrib.get("reference", "")
        prefix = "container:"
        if reference.startswith(prefix):
            names.append(reference[len(prefix) :])
    return names


def plan_target_names(plan_path: Path) -> set[str]:
    payload = json.loads(plan_path.read_text(encoding="utf-8"))
    return {target["target"]["name"] for target in payload["testTargets"]}


def business_targets(target_names: set[str]) -> list[str]:
    return sorted(
        name
        for name in target_names
        if name.endswith("Tests") and "UITests" not in name
    )


@contextlib.contextmanager
def fake_xcresulttool(
    summary: dict[str, object] | None = None,
    *,
    returncode: int = 0,
    stdout: str | None = None,
    stderr: str = "",
) -> Iterator[tuple[Path, list[list[str]]]]:
    """Yield an on-disk bundle path whose xcresulttool summary is `summary`, plus the recorded commands."""
    output = json.dumps(summary) if stdout is None else stdout
    calls: list[list[str]] = []

    def fake_run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        calls.append(list(command))
        return subprocess.CompletedProcess(command, returncode, output, stderr)

    with tempfile.TemporaryDirectory() as raw_directory:
        bundle = Path(raw_directory) / "offline.xcresult"
        bundle.mkdir()
        with patch("run_offline_unit_tests.subprocess.run", side_effect=fake_run):
            yield bundle, calls


def official_summary_command(bundle: Path) -> list[str]:
    return [
        "xcrun",
        "xcresulttool",
        "get",
        "test-results",
        "summary",
        "--path",
        str(bundle),
        "--compact",
    ]
