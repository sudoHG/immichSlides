"""Moved fixtures and imports shared by the existing test classes."""

from __future__ import annotations


import io


import json


import os


import re


import shutil


import signal


import stat


import struct


import subprocess


import sys


import tempfile


import unittest


import urllib.error


import urllib.request


import zlib


from pathlib import Path


from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent


REPO_ROOT = SCRIPT_DIR.parent


sys.path.insert(0, str(SCRIPT_DIR))


from run_strict_e2e import (  # noqa: E402
    CASE_E2E_IDS,
    CommandError,
    FILTER_PERSON_SESSIONS,
    IOS_FILTER_SUITES,
    IOS_FIRST_BATCH_SUITES,
    IOS_LATE_IMAGE_SUITES,
    MIN_DATA_GIB,
    PRIVATE_RESULT_BUNDLE_ROOT,
    RUNNER_SUITES,
    TVOS_FILTER_SUITES,
    TVOS_CONTROL_SUITES,
    TVOS_FLOW_SUITES,
    TVOS_LATE_IMAGE_SUITES,
    WRONG_PUBLIC_API_KEY,
    audit_out_of_order_runner_inputs,
    build_xcodebuild_command,
    choose_exit_code,
    cleanup_task_xcconfig,
    make_test_environment,
    merge_official_summaries,
    prepare_evidence_directory,
    prepare_private_result_bundle_path,
    prepare_task_xcconfig,
    read_source_dirty_paths,
    read_source_sha,
    require_official_single_pass,
    require_visual_identity,
    reset_simulator_app,
    reserve_unreachable_server_url,
    result_bundle_name,
    run_cleanup_actions,
    validate_suite_fixture,
    run_command,
    scenario_settings,
    simulator_app_container,
    start_screen_recording,
    stop_screen_recording,
    validate_app_launch_environment,
    validate_suite_scenario,
    write_case_manifest,
    write_fixture_artifacts,
    write_sensitive_scan,
    main as runner_main,
)


from run_offline_unit_tests import TestResultsSummary  # noqa: E402


from sensitive_scan_test_support import compressed_byte_coincidence  # noqa: E402


from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256, load_member_manifest, write_member_manifest  # noqa: E402


from strict_e2e_p2_contract import P2_CASES, RAW_VERDICT  # noqa: E402


from strict_e2e_server import _fixture_data  # noqa: E402


def _rgb_png(color: tuple[int, int, int], width: int = 32, height: int = 32) -> bytes:
    rows = bytearray()
    for _ in range(height):
        rows.append(0)
        rows.extend(color * width)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + chunk(b"IEND", b"")
    )


def _write_pause_window_evidence(evidence: Path, window_png: bytes) -> None:
    a2 = _fixture_data("a")["images"]["asset-a-2"]
    (evidence / "window-detected.png").write_bytes(window_png)
    (evidence / "after-pause.png").write_bytes(a2)
    (evidence / "after-pause-0_3s.png").write_bytes(a2)
    (evidence / "after-pause.overlay.txt").write_text("", encoding="utf-8")


def _run_runner_without_site(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-S", str(SCRIPT_DIR / "run_strict_e2e.py"), *args],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        timeout=20,
        check=False,
    )


def _run_code_without_site(source: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-S", "-c", source, str(SCRIPT_DIR)],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        timeout=20,
        check=False,
    )


def _swift_test_methods(relative: str) -> set[str]:
    path = REPO_ROOT / relative
    source = "\n".join(
        candidate.read_text(encoding="utf-8")
        for candidate in [path, *sorted(path.parent.glob(f"{path.stem}+*.swift"))]
    )
    return set(re.findall(r"func (test\w+)\s*\(", source))


P2_UDID = "SIM-P2-RUNNER"


P2_MOVIE = b"\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00qt  \x00\x00\x00\x08mdat\x00\x00\x00\x08moov"


def _p2_facts(suite: str, platform: str, model: str, device_id: str = P2_UDID) -> dict[str, object]:
    _bundle, test_class, method = P2_CASES[suite].selectors[platform].split("/")
    return {
        "test_cases": [
            {"bundle": "immichSlidesUITests", "identifier": f"{test_class}/{method}()", "result": "Passed"}
        ],
        "devices": [
            {
                "deviceId": device_id,
                "deviceName": model,
                "modelName": model,
                "osVersion": "26.4",
                "osBuildNumber": "23E244",
                "platform": "tvOS Simulator" if platform == "tvos" else "iOS Simulator",
            }
        ],
    }


def _write_p2_ui_outputs(evidence: Path, suite: str, *, skip: tuple[str, ...] = ()) -> None:
    """Simulate a UI test process writing files; this only proves runner completion, not the product's appearance."""
    case = P2_CASES[suite]
    images = {"portrait": _rgb_png((120, 60, 30), 20, 40), "landscape": _rgb_png((120, 60, 30), 40, 20)}
    steps: list[dict[str, object]] = []
    for position, name in enumerate(case.step_order, 1):
        orientation = case.png_orientations.get(name, "not_applicable")
        step: dict[str, object] = {"index": position, "name": name, "wall_time": 1000.0 + position, "orientation": orientation}
        if name in case.pngs:
            if name not in skip:
                (evidence / f"{name}.png").write_bytes(images.get(orientation, _fixture_data("a")["images"]["asset-a-3"]))
            step["png"] = f"{name}.png"
        steps.append(step)
    (evidence / "p2-steps.json").write_text(
        json.dumps({"schema": "strict-e2e-steps-v1", "steps": steps}), encoding="utf-8"
    )
    if case.video:
        (evidence / "screen-recording.mov").write_bytes(P2_MOVIE)
