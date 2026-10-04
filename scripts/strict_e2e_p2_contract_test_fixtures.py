"""Moved fixtures and imports shared by the existing test classes."""

from __future__ import annotations


import hashlib


import io


import json


import os


import re


import subprocess


import sys


import tempfile


import unittest


from pathlib import Path


from typing import Any


from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent


sys.path.insert(0, str(SCRIPT_DIR))


import strict_e2e_p2_contract  # noqa: E402


from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256  # noqa: E402


from strict_e2e_p2_contract import (  # noqa: E402
    CACHE_CLEAR_REVIEW_CHECKS,
    P2_CASES,
    P2ContractError,
    RAW_VERDICT,
    RECORDING_FILE,
    RECORDING_TIMING_FILE,
    REVIEW_FILE,
    REVIEW_SCHEMA,
    STEPS_FILE,
    STEPS_SCHEMA,
    device_class_of,
    main as contract_main,
    p2_selector,
    read_xcresult_facts,
    require_official_execution,
    validate_raw_evidence,
    verify_evidence,
)


from strict_e2e_server import _fixture_data  # noqa: E402


SOURCE_SHA = "0123456789abcdef0123456789abcdef01234567"


UDID = "SIM-P2-CONTRACT"


FIXTURE = _fixture_data("a")


IMAGES = FIXTURE["images"]


LABEL_SHA256 = {asset["label"]: asset["sha256"] for asset in FIXTURE["assets"]}


MOVIE = (
    b"\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00qt  "
    b"\x00\x00\x00\x08mdat"
    b"\x00\x00\x00\x08moov"
)


DEVICES = {
    "iphone": {"modelName": "iPhone 17 Pro", "platform": "iOS Simulator"},
    "ipad": {"modelName": "iPad Pro 13-inch (M5)", "platform": "iOS Simulator"},
    "tv": {"modelName": "Apple TV 4K (3rd generation)", "platform": "tvOS Simulator"},
}


PLATFORM_OF = {"iphone": "ios", "ipad": "ios", "tv": "tvos"}


ORIENTED_IMAGES = {"portrait": IMAGES["asset-a-5"], "landscape": IMAGES["asset-a-4"]}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_json(path: Path, payload: object) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _device(device_class: str, device_id: str = UDID) -> dict[str, str]:
    return {
        "deviceId": device_id,
        "deviceName": DEVICES[device_class]["modelName"],
        "osBuildNumber": "23E244",
        "osVersion": "26.4",
        **DEVICES[device_class],
    }


def _facts(
    suite: str,
    device_class: str,
    *,
    identifier: str | None = None,
    result: str = "Passed",
    devices: list[dict[str, str]] | None = None,
) -> dict[str, Any]:
    _bundle, test_class, method = p2_selector(suite, PLATFORM_OF[device_class]).split("/")
    return {
        "test_cases": [
            {
                "bundle": "immichSlidesUITests",
                "identifier": identifier or f"{test_class}/{method}()",
                "result": result,
            }
        ],
        "devices": devices if devices is not None else [_device(device_class)],
    }


def _write_review(
    evidence: Path,
    suite: str,
    device_class: str,
    *,
    verdict: str = "PASS",
    conclusion: str = "PASS",
    source_sha: str = SOURCE_SHA,
) -> None:
    case = P2_CASES[suite]
    artifacts: dict[str, Any] = {}
    for png in case.pngs:
        name = f"{png}.png"
        artifact: dict[str, Any] = {
            "sha256": _sha256(evidence / name),
            "controls": "settings controls visible" if name in {"cache-before-confirm.png", "cache-cleared.png"} else "hidden",
            "observation": {
                "cache-before-confirm.png": "before clearing, the page shows disk cache usage above 0",
                "cache-cleared.png": "after clearing, the page shows usage 0 and success feedback is visible",
                "cache-returned.png": "after returning, public pattern A3 is visible and playback is normal",
            }.get(name, "public pattern A3 fully visible"),
            "conclusion": conclusion,
        }
        if name not in {"cache-before-confirm.png", "cache-cleared.png"}:
            artifact["visible_marks"] = ["A3"]
            artifact["fixture_sha256"] = {"A3": LABEL_SHA256["A3"]}
        artifacts[name] = artifact
        required_checks = CACHE_CLEAR_REVIEW_CHECKS.get(name)
        if required_checks:
            artifacts[name]["checks"] = {check: conclusion for check in required_checks}
    if case.video:
        offsets = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))["mark_offsets"]
        artifacts[RECORDING_FILE] = {
            "sha256": _sha256(evidence / RECORDING_FILE),
            "observation": "continuous recording covers all actions",
            "conclusion": conclusion,
            "time_slices": [
                {
                    "start_s": max(0.0, offset - 0.5),
                    "end_s": offset + 0.5,
                    "observation": f"{mark}: stable before and after, no jumps",
                    "conclusion": conclusion,
                }
                for mark, offset in offsets.items()
            ],
        }
    _write_json(
        evidence / REVIEW_FILE,
        {
            "schema": REVIEW_SCHEMA,
            "reviewer": "Review | Re-review (not the author)",
            "suite": suite,
            "device_class": device_class,
            "source_sha": source_sha,
            "verdict": verdict,
            "artifacts": artifacts,
        },
    )


def build_evidence(root: Path, suite: str, device_class: str, *, review: bool = True) -> Path:
    """Build a tooling-complete synthetic evidence pack; it proves the contract only and shows no product screen."""
    case = P2_CASES[suite]
    platform = PLATFORM_OF[device_class]
    evidence = root / f"{suite}-{device_class}"
    evidence.mkdir()
    (evidence / f"strict-{suite}.xcresult").mkdir()
    _write_json(
        evidence / "case-manifest.json",
        {
            "source_sha": SOURCE_SHA,
            "source_dirty_paths": [],
            "platform": platform,
            "destination": f"platform={'tvOS' if platform == 'tvos' else 'iOS'} Simulator,id={UDID}",
            "suite": suite,
            "scenario": "normal",
            "fixture_set": "a",
            "fixture_sha256": FROZEN_FIXTURE_SHA256["a"],
            "result": "Passed",
            "exit_code": 0,
        },
    )
    steps: list[dict[str, Any]] = []
    wall_time = 1000.0
    for name in case.step_order:
        wall_time += 1
        step: dict[str, Any] = {
            "index": len(steps) + 1,
            "name": name,
            "wall_time": wall_time,
            "orientation": case.png_orientations.get(name, "not_applicable"),
        }
        if name in case.pngs:
            (evidence / f"{name}.png").write_bytes(ORIENTED_IMAGES.get(step["orientation"], IMAGES["asset-a-3"]))
            step["png"] = f"{name}.png"
        steps.append(step)
    _write_json(evidence / STEPS_FILE, {"schema": STEPS_SCHEMA, "steps": steps})
    if case.video:
        (evidence / RECORDING_FILE).write_bytes(MOVIE)
        _write_json(
            evidence / RECORDING_TIMING_FILE,
            {"started_wall_time": 900.0, "stopped_wall_time": 5000.0, "stop_exit": 0},
        )
    _write_json(evidence / "visual-identity-runner.json", validate_raw_evidence(evidence, suite, "a"))
    _write_json(evidence / "sensitive-scan.json", {"result": "PASS", "matched_files": []})
    if review:
        _write_review(evidence, suite, device_class)
    return evidence


def _verify(evidence: Path, suite: str, device_class: str, **overrides: Any) -> dict[str, Any]:
    facts = overrides.pop("facts", None) or _facts(suite, device_class)
    return verify_evidence(
        evidence,
        suite=suite,
        device_class=overrides.pop("check_device_class", device_class),
        expected_sha=overrides.pop("expected_sha", SOURCE_SHA),
        read_facts=lambda _bundle: facts,
    )


def _patch_json(path: Path, **changes: Any) -> None:
    payload = _read_json(path)
    payload.update(changes)
    _write_json(path, payload)


def _rewrite_runner_report(evidence: Path, suite: str) -> None:
    _write_json(evidence / "visual-identity-runner.json", validate_raw_evidence(evidence, suite, "a"))


def _move_step(evidence: Path, name: str, to_position: int) -> None:
    payload = _read_json(evidence / STEPS_FILE)
    steps = payload["steps"]
    moving = next(step for step in steps if step["name"] == name)
    steps.remove(moving)
    steps.insert(to_position, moving)
    for position, step in enumerate(steps, 1):
        step["index"], step["wall_time"] = position, 1000.0 + position
    _write_json(evidence / STEPS_FILE, payload)


REPO_ROOT = SCRIPT_DIR.parent


IMPLEMENTED_SWIFT_SUITES = (
    "p2-exif",
    "p2-cache",
    "p2-cache-smoke",
    "p2-reduce-motion",
    "p2-ipad-layout",
    "p2-rotation",
    "p2-orientation-selfcheck",
)


PLATFORM_GUARDS = {"#if os(iOS)": "ios", "#if os(tvOS)": "tvos"}


def _method_platforms(source: str, method: str) -> list[str | None]:
    # Only #if os(...) / #endif nesting is accepted; #else makes the platform ambiguous, so it is rejected.
    stack: list[str | None] = []
    found: list[str | None] = []
    for line in source.splitlines():
        text = line.strip()
        if text.startswith(("#else", "#elseif")):
            raise ValueError(f"unsupported {text}")
        if text.startswith("#if"):
            stack.append(PLATFORM_GUARDS.get(text))
        elif text.startswith("#endif"):
            stack.pop()
        elif re.search(rf"\bfunc {re.escape(method)}\(\)", text):
            found.append(next((guard for guard in reversed(stack) if guard), None))
    return found
