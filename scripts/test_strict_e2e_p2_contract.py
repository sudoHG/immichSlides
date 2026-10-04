#!/usr/bin/env python3
"""Strict end-to-end P2 evidence contract: missing evidence, wrong device, wrong version or no sign-off must fail closed."""

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
# Smallest finalizable QuickTime atom sequence: ftyp + mdat + moov.
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


class P2CaseTableTests(unittest.TestCase):
    def test_every_case_maps_devices_to_platform_selectors_and_required_outputs(self) -> None:
        expected_devices = {
            "p2-exif": ("iphone", "ipad", "tv"),
            "p2-cache": ("iphone", "tv"),
            "p2-cache-smoke": ("ipad",),
            "p2-reduce-motion": ("iphone", "tv"),
            "p2-ipad-layout": ("ipad",),
            "p2-rotation": ("iphone", "ipad"),
            "p2-orientation-selfcheck": ("iphone",),
        }
        self.assertEqual({suite: case.devices for suite, case in P2_CASES.items()}, expected_devices)
        for suite, case in P2_CASES.items():
            with self.subTest(suite=suite):
                self.assertTrue(case.pngs)
                self.assertEqual(sorted(case.step_order), sorted((*case.pngs, *case.marks)))
                platforms = {PLATFORM_OF[device] for device in case.devices}
                self.assertEqual(set(case.selectors), platforms)
                for selector in case.selectors.values():
                    bundle, test_class, method = selector.split("/")
                    self.assertEqual(bundle, "immichSlidesUITests")
                    self.assertTrue(test_class.endswith("UITests"), selector)
                    self.assertNotIn("PlaybackSmartFillVisualUITests", selector)
                    self.assertTrue(method.startswith("test"), selector)
        self.assertTrue(P2_CASES["p2-reduce-motion"].video)
        self.assertTrue(P2_CASES["p2-rotation"].video)
        self.assertEqual(
            P2_CASES["p2-cache"].selectors,
            {
                "ios": "immichSlidesUITests/CacheSettingsUITests/testClearDiskCacheFromSettingsIOS",
                "tvos": "immichSlidesUITests/CacheSettingsUITests/testClearDiskCacheFromSettingsTVOS",
            },
        )
        self.assertEqual(
            P2_CASES["p2-cache"].pngs,
            ("cache-before-confirm", "cache-cleared", "cache-returned"),
        )
        self.assertTrue(P2_CASES["p2-cache"].cache_clear)
        self.assertFalse(P2_CASES["p2-cache-smoke"].cache_clear)
        self.assertEqual(P2_CASES["p2-cache-smoke"].e2e_ids, ())

    def test_selector_rejects_platform_outside_case(self) -> None:
        for suite, platform in (
            ("p2-ipad-layout", "tvos"),
            ("p2-rotation", "tvos"),
            ("p2-cache-smoke", "tvos"),
            ("p2-exif", "macos"),
            ("unknown", "ios"),
        ):
            with self.subTest(suite=suite, platform=platform), self.assertRaises(P2ContractError):
                p2_selector(suite, platform)

    def test_device_class_comes_only_from_official_simulator_model(self) -> None:
        self.assertEqual(device_class_of(_device("iphone")), "iphone")
        self.assertEqual(device_class_of(_device("ipad")), "ipad")
        self.assertEqual(device_class_of(_device("tv")), "tv")
        for device in (
            {"modelName": "iPhone 17 Pro", "platform": "iOS"},
            {"modelName": "Mac", "platform": "macOS"},
            {"modelName": "Apple TV 4K", "platform": "iOS Simulator"},
            {"platform": "iOS Simulator"},
        ):
            with self.subTest(device=device), self.assertRaises(P2ContractError):
                device_class_of(device)


REPO_ROOT = SCRIPT_DIR.parent
# Every suite in the contract already has a Swift test; add new suites here as well.
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


class P2SwiftSelectorTests(unittest.TestCase):
    def test_implemented_selectors_resolve_to_one_platform_guarded_swift_method(self) -> None:
        self.assertEqual(sorted(IMPLEMENTED_SWIFT_SUITES), sorted(P2_CASES))
        for suite in IMPLEMENTED_SWIFT_SUITES:
            for platform, selector in P2_CASES[suite].selectors.items():
                with self.subTest(suite=suite, platform=platform):
                    bundle, test_class, method = selector.split("/")
                    source = (REPO_ROOT / bundle / f"{test_class}.swift").read_text(encoding="utf-8")
                    self.assertEqual(len(re.findall(rf"\bfinal class {test_class}: XCTestCase\b", source)), 1)
                    self.assertEqual(_method_platforms(source, method), [platform])

    def test_guard_reader_rejects_wrong_missing_or_ambiguous_platform(self) -> None:
        source = "#if os(iOS)\nfunc testA() {}\n#endif\nfunc testB() {}\n#if os(tvOS)\n#if DEBUG\nfunc testC() {}\n#endif\n#endif\n"
        self.assertEqual(_method_platforms(source, "testA"), ["ios"])
        self.assertEqual(_method_platforms(source, "testB"), [None])
        self.assertEqual(_method_platforms(source, "testC"), ["tvos"])
        self.assertEqual(_method_platforms(source, "testD"), [])
        with self.assertRaises(ValueError):
            _method_platforms("#if os(iOS)\n#else\nfunc testA() {}\n#endif\n", "testA")


class OfficialExecutionTests(unittest.TestCase):
    def test_exactly_the_selected_method_must_pass_on_the_destination_device(self) -> None:
        execution = require_official_execution(
            _facts("p2-exif", "ipad"), suite="p2-exif", platform="ios", simulator_udid=UDID
        )
        self.assertEqual(execution["executed_tests"], ["ExifToggleUITests/testExifToggleOwnershipIOS()"])
        self.assertEqual(execution["device"]["class"], "ipad")
        self.assertEqual(execution["device"]["os_version"], "26.4")

    def test_wrong_method_count_result_or_device_fails_closed(self) -> None:
        passing = _facts("p2-cache", "iphone")
        cases = {
            "old method impersonation": _facts("p2-cache", "iphone", identifier="CacheSettingsUITests/testOther()"),
            "missing parentheses is not an official identifier": _facts(
                "p2-cache", "iphone", identifier="CacheSettingsUITests/testClearCacheReloadsVisiblePhotoIOS"
            ),
            "old cache reload selector": _facts(
                "p2-cache", "iphone", identifier="CacheSettingsUITests/testClearCacheReloadsVisiblePhotoIOS()"
            ),
            "skipped": _facts("p2-cache", "iphone", result="Skipped"),
            "failed": _facts("p2-cache", "iphone", result="Failed"),
            "zero executions": {"test_cases": [], "devices": passing["devices"]},
            "two executions": {"test_cases": passing["test_cases"] * 2, "devices": passing["devices"]},
            "wrong bundle": {
                "test_cases": [dict(passing["test_cases"][0], bundle="immichSlidesTests")],
                "devices": passing["devices"],
            },
            "iPad impersonating iPhone for cache clear": _facts("p2-cache", "iphone", devices=[_device("ipad")]),
            "another simulator": _facts("p2-cache", "iphone", devices=[_device("iphone", "SIM-OTHER")]),
            "two devices": _facts("p2-cache", "iphone", devices=[_device("iphone"), _device("iphone")]),
            "tvOS device running the iOS selector": _facts("p2-cache", "iphone", devices=[_device("tv")]),
        }
        for label, facts in cases.items():
            with self.subTest(label=label), self.assertRaises(P2ContractError):
                require_official_execution(facts, suite="p2-cache", platform="ios", simulator_udid=UDID)

    def test_xcresult_reader_collects_test_cases_and_devices_from_official_json(self) -> None:
        official = {
            "devices": [_device("tv")],
            "testNodes": [
                {
                    "nodeType": "Test Plan",
                    "name": "immichSlides-tvOS",
                    "children": [
                        {
                            "nodeType": "UI test bundle",
                            "name": "immichSlidesUITests",
                            "children": [
                                {
                                    "nodeType": "Test Suite",
                                    "name": "ExifToggleUITests",
                                    "children": [
                                        {
                                            "nodeType": "Test Case",
                                            "name": "testExifToggleOwnershipTVOS()",
                                            "nodeIdentifier": "ExifToggleUITests/testExifToggleOwnershipTVOS()",
                                            "result": "Passed",
                                            "children": [{"nodeType": "Repetition", "name": "1"}],
                                        }
                                    ],
                                }
                            ],
                        }
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory() as raw_directory:
            bundle = Path(raw_directory) / "strict-p2-exif.xcresult"
            bundle.mkdir()

            def fake_run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
                self.assertEqual(command[:5], ["xcrun", "xcresulttool", "get", "test-results", "tests"])
                return subprocess.CompletedProcess(command, 0, json.dumps(official), "")

            facts = read_xcresult_facts(bundle, run=fake_run)
            self.assertEqual(
                facts["test_cases"],
                [
                    {
                        "bundle": "immichSlidesUITests",
                        "identifier": "ExifToggleUITests/testExifToggleOwnershipTVOS()",
                        "result": "Passed",
                    }
                ],
            )
            require_official_execution(facts, suite="p2-exif", platform="tvos", simulator_udid=UDID)

            for label, completed in (
                ("tool failure", subprocess.CompletedProcess([], 1, "", "boom")),
                ("empty output", subprocess.CompletedProcess([], 0, "", "")),
                ("not JSON", subprocess.CompletedProcess([], 0, "not json", "")),
            ):
                with self.subTest(label=label), self.assertRaises(P2ContractError):
                    read_xcresult_facts(bundle, run=lambda *_args, _c=completed, **_kw: _c)
        with self.assertRaises(P2ContractError):
            read_xcresult_facts(Path("/nonexistent/strict-p2-exif.xcresult"), run=fake_run)


class RawEvidenceTests(unittest.TestCase):
    def test_complete_raw_evidence_is_only_ever_review_required(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            for suite, case in P2_CASES.items():
                device_class = case.devices[0]
                with self.subTest(suite=suite):
                    evidence = build_evidence(Path(raw_directory), suite, device_class)
                    payload = validate_raw_evidence(evidence, suite, "a")
                    self.assertEqual(payload["verdict"], RAW_VERDICT)
                    self.assertNotEqual(payload["verdict"], "PASS")
                    for png in case.pngs:
                        self.assertEqual(
                            payload["artifacts"][f"{png}.png"]["sha256"], _sha256(evidence / f"{png}.png")
                        )
                    if case.video:
                        self.assertIn(RECORDING_FILE, payload["artifacts"])
                    if case.cache_clear:
                        self.assertEqual(payload["cache_clear"], {"target_mark": "A3"})
                        self.assertFalse((evidence / "service.log").exists())

    def test_missing_empty_or_corrupt_required_png_fails(self) -> None:
        for label, mutate in (
            ("missing file", lambda path: path.unlink()),
            ("empty file", lambda path: path.write_bytes(b"")),
            ("not a PNG", lambda path: path.write_bytes(b"not-a-png")),
            ("zero-size PNG", lambda path: path.write_bytes(IMAGES["asset-a-3"][:16] + b"\x00" * 8)),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone", review=False)
                mutate(evidence / "exif-off.png")
                with self.assertRaises(P2ContractError) as raised:
                    validate_raw_evidence(evidence, "p2-exif", "a")
                self.assertIn("exif-off.png", str(raised.exception))

    def test_step_record_must_bind_every_required_png_and_mark(self) -> None:
        def drop_png_reference(steps: list[dict[str, Any]]) -> None:
            steps[0].pop("png")

        def duplicate_png_reference(steps: list[dict[str, Any]]) -> None:
            steps[1]["png"] = steps[0]["png"]

        def drop_mark(steps: list[dict[str, Any]]) -> None:
            steps[:] = [step for step in steps if step["name"] != "rotate-to-portrait"]

        def reverse_time(steps: list[dict[str, Any]]) -> None:
            steps[1]["wall_time"] = steps[0]["wall_time"] - 1

        def repeat_index(steps: list[dict[str, Any]]) -> None:
            steps[1]["index"] = steps[0]["index"]

        def wrong_orientation(steps: list[dict[str, Any]]) -> None:
            for step in steps:
                if step.get("png") == "rotation-landscape-stable.png":
                    step["orientation"] = "portrait"

        def unknown_orientation(steps: list[dict[str, Any]]) -> None:
            steps[0]["orientation"] = "faceUp"

        def missing_referenced_png(steps: list[dict[str, Any]]) -> None:
            steps.append(dict(steps[-1], index=99, wall_time=4000.0, name="extra", png="extra.png"))

        def non_finite_time(steps: list[dict[str, Any]]) -> None:
            steps[-1]["wall_time"] = "NaN"

        def outside_recording(steps: list[dict[str, Any]]) -> None:
            steps[-1]["wall_time"] = 6000.0

        for mutate in (
            drop_png_reference,
            duplicate_png_reference,
            drop_mark,
            reverse_time,
            repeat_index,
            wrong_orientation,
            unknown_orientation,
            missing_referenced_png,
            non_finite_time,
            outside_recording,
        ):
            with self.subTest(mutate=mutate.__name__), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-rotation", "iphone", review=False)
                payload = json.loads((evidence / STEPS_FILE).read_text(encoding="utf-8"))
                mutate(payload["steps"])
                _write_json(evidence / STEPS_FILE, payload)
                with self.assertRaises(P2ContractError):
                    validate_raw_evidence(evidence, "p2-rotation", "a")

        for label, suite, mutate_evidence in (
            ("rotation before the initial portrait frame", "p2-rotation", lambda evidence: _move_step(evidence, "rotate-to-landscape", 0)),
            (
                "Reduce Motion enabled before the off-state observation",
                "p2-reduce-motion",
                lambda evidence: _move_step(evidence, "motion-system-enabled", 1),
            ),
            (
                "portrait frame pixels are landscape",
                "p2-rotation",
                lambda evidence: (evidence / "rotation-start-portrait.png").write_bytes(ORIENTED_IMAGES["landscape"]),
            ),
            (
                "landscape frame is square",
                "p2-ipad-layout",
                lambda evidence: (evidence / "layout-landscape-multi.png").write_bytes(IMAGES["asset-a-3"]),
            ),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), suite, P2_CASES[suite].devices[-1], review=False)
                mutate_evidence(evidence)
                with self.assertRaises(P2ContractError):
                    validate_raw_evidence(evidence, suite, "a")

        for label, mutate_file in (
            ("missing steps file", lambda path: path.unlink()),
            ("empty steps file", lambda path: path.write_text("", encoding="utf-8")),
            ("wrong schema", lambda path: _patch_json(path, schema="other")),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-exif", "tv", review=False)
                mutate_file(evidence / STEPS_FILE)
                with self.assertRaises(P2ContractError):
                    validate_raw_evidence(evidence, "p2-exif", "a")

    def test_video_cases_require_finalized_recording_and_timing(self) -> None:
        for label, mutate in (
            ("missing recording", lambda evidence: (evidence / RECORDING_FILE).unlink()),
            ("empty recording", lambda evidence: (evidence / RECORDING_FILE).write_bytes(b"")),
            ("unfinalized recording", lambda evidence: (evidence / RECORDING_FILE).write_bytes(MOVIE[:-8])),
            ("missing recording timing", lambda evidence: (evidence / RECORDING_TIMING_FILE).unlink()),
            (
                "recording times reversed",
                lambda evidence: _patch_json(evidence / RECORDING_TIMING_FILE, stopped_wall_time=800.0),
            ),
            ("recording stop exit code is not 0", lambda evidence: _patch_json(evidence / RECORDING_TIMING_FILE, stop_exit=1)),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-reduce-motion", "tv", review=False)
                mutate(evidence)
                with self.assertRaises(P2ContractError):
                    validate_raw_evidence(evidence, "p2-reduce-motion", "a")


class CacheClearTests(unittest.TestCase):
    def test_cache_clear_accepts_ui_evidence_without_network_log(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
            self.assertFalse((evidence / "service.log").exists())
            payload = validate_raw_evidence(evidence, "p2-cache", "a")
            self.assertEqual(payload["cache_clear"], {"target_mark": "A3"})

    def test_cache_before_confirm_is_not_identity_classified(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
            (evidence / "cache-before-confirm.png").write_bytes(IMAGES["asset-a-4"])
            payload = validate_raw_evidence(evidence, "p2-cache", "a")
            self.assertEqual(payload["cache_clear"], {"target_mark": "A3"})

    def test_cache_settings_frames_must_be_decodable_png(self) -> None:
        for name in ("cache-before-confirm.png", "cache-cleared.png"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
                (evidence / name).write_bytes(IMAGES["asset-a-3"][:24])
                with self.assertRaisesRegex(P2ContractError, "cannot be fully decoded"):
                    validate_raw_evidence(evidence, "p2-cache", "a")

    def test_returned_frame_must_show_a_recognized_public_photo(self) -> None:
        for label, returned, expected_mark in (
            ("returned frame shows another public photo", IMAGES["asset-a-4"], "A4"),
            ("returned frame is unrecognizable", b"\x89PNG\r\n\x1a\n" + b"\x00" * 64, None),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
                (evidence / "cache-returned.png").write_bytes(returned)
                if expected_mark is None:
                    with self.assertRaises(P2ContractError):
                        validate_raw_evidence(evidence, "p2-cache", "a")
                else:
                    payload = validate_raw_evidence(evidence, "p2-cache", "a")
                    self.assertEqual(payload["cache_clear"], {"target_mark": expected_mark})

    def test_legacy_before_clear_png_name_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
            (evidence / "cache-before-confirm.png").rename(evidence / "cache-before-clear.png")
            with self.assertRaisesRegex(P2ContractError, "cache-before-confirm.png"):
                validate_raw_evidence(evidence, "p2-cache", "a")

    def test_cache_screenshot_steps_must_keep_the_required_order(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
            _move_step(evidence, "cache-cleared", 0)
            with self.assertRaisesRegex(P2ContractError, "Step order must be"):
                validate_raw_evidence(evidence, "p2-cache", "a")

    def test_cache_clear_pass_requires_image_bound_manual_checks(self) -> None:
        mutations = (
            ("cache-before-confirm.png", "disk_usage_nonzero_before_confirm", None),
            ("cache-cleared.png", "disk_usage_zero_after_clear", "PARTIAL"),
            ("cache-cleared.png", "success_feedback_visible", None),
            ("cache-returned.png", "playback_normal_after_return", "NEEDS_HUMAN_REVIEW"),
        )
        for image_name, check_name, value in mutations:
            with self.subTest(image=image_name, check=check_name), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone")
                review = _read_json(evidence / REVIEW_FILE)
                checks = review["artifacts"][image_name]["checks"]
                if value is None:
                    checks.pop(check_name)
                else:
                    checks[check_name] = value
                _write_json(evidence / REVIEW_FILE, review)
                with self.assertRaises(P2ContractError):
                    _verify(evidence, "p2-cache", "iphone")


class VerifyGateTests(unittest.TestCase):
    def test_sanitized_official_export_replaces_credential_bearing_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone")
            _bundle, test_class, method = p2_selector("p2-exif", "ios").split("/")
            payload = {
                "testNodes": [{
                    "nodeType": "UI test bundle",
                    "name": "immichSlidesUITests",
                    "children": [{
                        "nodeType": "Test Case",
                        "nodeIdentifier": f"{test_class}/{method}()",
                        "result": "Passed",
                    }],
                }],
                "devices": [_device("iphone")],
            }
            exported = evidence / "official-tests.json"
            _write_json(exported, payload)
            digest = _sha256(exported)
            _patch_json(evidence / "case-manifest.json", official_tests_sha256=digest)
            _write_json(evidence / "result-bundle-disposal.json", {"official_tests_sha256": digest, "result_bundle_disposed": True})
            (evidence / "strict-p2-exif.xcresult").rmdir()
            self.assertEqual(
                verify_evidence(evidence, suite="p2-exif", device_class="iphone", expected_sha=SOURCE_SHA)["verdict"],
                "PASS",
            )
            exported.write_text(exported.read_text(encoding="utf-8") + " ", encoding="utf-8")
            with self.assertRaises(P2ContractError):
                verify_evidence(evidence, suite="p2-exif", device_class="iphone", expected_sha=SOURCE_SHA)

    def test_signed_complete_evidence_passes_for_every_case_and_device(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            for suite, case in P2_CASES.items():
                for device_class in case.devices:
                    with self.subTest(suite=suite, device_class=device_class):
                        evidence = build_evidence(Path(raw_directory), suite, device_class)
                        result = _verify(evidence, suite, device_class)
                        self.assertEqual(result["verdict"], "PASS")
                        self.assertEqual(result["source_sha"], SOURCE_SHA)
                        self.assertEqual(result["device"]["class"], device_class)

    def test_unsigned_evidence_never_passes_even_with_review_environment(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone", review=False)
            with mock.patch.dict(
                os.environ,
                {"REVIEWED_PASS": "1", "STRICT_E2E_REVIEWED_PASS": "1", "TEST_RUNNER_REVIEWED_PASS": "1"},
            ), self.assertRaises(P2ContractError) as raised:
                _verify(evidence, "p2-exif", "iphone")
            self.assertIn("Missing sign-off", str(raised.exception))

    def test_review_bound_to_other_evidence_or_stale_hash_fails(self) -> None:
        def modify_png(evidence: Path) -> None:
            (evidence / "rotation-landscape-stable.png").write_bytes(IMAGES["asset-a-1"])
            _rewrite_runner_report(evidence, "p2-rotation")

        def modify_video(evidence: Path) -> None:
            (evidence / RECORDING_FILE).write_bytes(MOVIE + b"\x00\x00\x00\x08free")
            _rewrite_runner_report(evidence, "p2-rotation")

        def uncovered_mark(evidence: Path) -> None:
            payload = json.loads((evidence / REVIEW_FILE).read_text(encoding="utf-8"))
            payload["artifacts"][RECORDING_FILE]["time_slices"] = payload["artifacts"][RECORDING_FILE]["time_slices"][:1]
            _write_json(evidence / REVIEW_FILE, payload)

        def drop_video_entry(evidence: Path) -> None:
            payload = json.loads((evidence / REVIEW_FILE).read_text(encoding="utf-8"))
            del payload["artifacts"][RECORDING_FILE]
            _write_json(evidence / REVIEW_FILE, payload)

        def patch_entry(**changes: Any):
            def mutate(evidence: Path) -> None:
                payload = json.loads((evidence / REVIEW_FILE).read_text(encoding="utf-8"))
                payload["artifacts"]["rotation-start-portrait.png"].update(changes)
                _write_json(evidence / REVIEW_FILE, payload)

            return mutate

        def patch_slices(slices: object):
            def mutate(evidence: Path) -> None:
                payload = json.loads((evidence / REVIEW_FILE).read_text(encoding="utf-8"))
                payload["artifacts"][RECORDING_FILE]["time_slices"] = slices
                _write_json(evidence / REVIEW_FILE, payload)

            return mutate

        cases = {
            "image changed after sign-off": modify_png,
            "recording changed after sign-off": modify_video,
            "sign-off omits the recording": drop_video_entry,
            "sign-off bound to the wrong suite": lambda evidence: _patch_json(evidence / REVIEW_FILE, suite="p2-exif"),
            "sign-off bound to the wrong device": lambda evidence: _patch_json(evidence / REVIEW_FILE, device_class="ipad"),
            "sign-off bound to the wrong candidate": lambda evidence: _patch_json(evidence / REVIEW_FILE, source_sha="f" * 40),
            "wrong sign-off schema": lambda evidence: _patch_json(evidence / REVIEW_FILE, schema="other"),
            "no reviewer": lambda evidence: _patch_json(evidence / REVIEW_FILE, reviewer=""),
            "unknown overall verdict": lambda evidence: _patch_json(evidence / REVIEW_FILE, verdict="LOOKS_OK"),
            "empty observation": patch_entry(observation=""),
            "unknown per-item conclusion": patch_entry(conclusion="OK"),
            "wrong pattern fixture hash": patch_entry(fixture_sha256={"A3": "0" * 64}),
            "pattern is not a public mark": patch_entry(visible_marks=["Z9"], fixture_sha256={"Z9": "0" * 64}),
            "missing control bar state": patch_entry(controls=""),
            "recording has no time slices": patch_slices([]),
            "time slices miss the rotate-back-to-portrait mark": uncovered_mark,
            "time slice reversed": patch_slices([{"start_s": 5, "end_s": 1, "observation": "x", "conclusion": "PASS"}]),
            "empty sign-off file": lambda evidence: (evidence / REVIEW_FILE).write_text("", encoding="utf-8"),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-rotation", "iphone")
                mutate(evidence)
                with self.assertRaises(P2ContractError):
                    _verify(evidence, "p2-rotation", "iphone")

    def test_runner_record_cleanup_and_manifest_types_fail_closed(self) -> None:
        def replace_after_run_and_resign(evidence: Path) -> None:
            (evidence / "exif-off.png").write_bytes(IMAGES["asset-a-1"])
            _write_review(evidence, "p2-exif", "iphone")

        def edit_steps_after_run(evidence: Path) -> None:
            payload = json.loads((evidence / STEPS_FILE).read_text(encoding="utf-8"))
            payload["steps"][0]["name"] = "exif-full-on"
            payload["steps"][0]["wall_time"] = 1000.5
            _write_json(evidence / STEPS_FILE, payload)

        cases = {
            "image replaced after the run and re-signed": replace_after_run_and_resign,
            "step record edited after the run": edit_steps_after_run,
            "missing runner report": lambda evidence: (evidence / "visual-identity-runner.json").unlink(),
            "runner report changed to PASS": lambda evidence: _patch_json(evidence / "visual-identity-runner.json", verdict="PASS"),
            "runner cleanup failed": lambda evidence: _write_json(evidence / "cleanup-failures.json", {"failures": ["x"]}),
            "fixture_set is not a string": lambda evidence: _patch_json(evidence / "case-manifest.json", fixture_set=["a"]),
            "fixture service is not the normal scenario": lambda evidence: _patch_json(evidence / "case-manifest.json", scenario="timeout"),
            "runner report suite changed": lambda evidence: _patch_json(evidence / "visual-identity-runner.json", suite="p2-cache"),
            "runner report has extra records": lambda evidence: _patch_json(evidence / "visual-identity-runner.json", mark_offsets={}),
            "sensitive scan PASS but lists matched files": lambda evidence: _patch_json(evidence / "sensitive-scan.json", matched_files=["x"]),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone")
                mutate(evidence)
                with self.assertRaises(P2ContractError):
                    _verify(evidence, "p2-exif", "iphone")

    def test_non_pass_review_is_reported_and_inconsistent_pass_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-ipad-layout", "ipad")
            _write_review(evidence, "p2-ipad-layout", "ipad", verdict="PARTIAL", conclusion="PARTIAL")
            self.assertEqual(_verify(evidence, "p2-ipad-layout", "ipad")["verdict"], "PARTIAL")
            _write_review(evidence, "p2-ipad-layout", "ipad", verdict="PASS", conclusion="NEEDS_HUMAN_REVIEW")
            with self.assertRaises(P2ContractError):
                _verify(evidence, "p2-ipad-layout", "ipad")

    def test_wrong_device_or_version_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            exif = build_evidence(Path(raw_directory), "p2-exif", "iphone")
            layout = build_evidence(Path(raw_directory), "p2-ipad-layout", "ipad")
            cases = {
                "iPhone directory holds an iPad official result": (exif, "p2-exif", "iphone", {"facts": _facts("p2-exif", "ipad")}),
                "device class not allowed for this suite": (layout, "p2-ipad-layout", "ipad", {"check_device_class": "iphone"}),
                "candidate SHA mismatch": (exif, "p2-exif", "iphone", {"expected_sha": "f" * 40}),
                "candidate SHA is not the full 40 characters": (exif, "p2-exif", "iphone", {"expected_sha": SOURCE_SHA[:12]}),
            }
            for label, (evidence, suite, device_class, overrides) in cases.items():
                with self.subTest(label=label), self.assertRaises(P2ContractError):
                    _verify(evidence, suite, device_class, **overrides)

    def test_manifest_version_run_state_and_scan_fail_closed(self) -> None:
        cases = {
            "workspace dirty at run time": {"source_dirty_paths": [" M scripts/run_strict_e2e.py"]},
            "workspace state not recorded": {"source_dirty_paths": None},
            "manifest SHA differs from sign-off": {"source_sha": "e" * 40},
            "manifest is for another suite": {"suite": "p2-cache"},
            "runner did not succeed": {"result": "FAILED", "exit_code": 65},
            "fixture hash changed": {"fixture_sha256": "0" * 64},
            "unknown fixture set": {"fixture_set": "z"},
            "destination has no UDID": {"destination": "platform=iOS Simulator,name=iPhone"},
        }
        for label, changes in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone")
                _patch_json(evidence / "case-manifest.json", **changes)
                with self.assertRaises(P2ContractError):
                    _verify(evidence, "p2-exif", "iphone")
        for label, mutate in (
            ("missing manifest", lambda evidence: (evidence / "case-manifest.json").unlink()),
            ("missing official xcresult", lambda evidence: (evidence / "strict-p2-exif.xcresult").rmdir()),
            ("missing sensitive scan", lambda evidence: (evidence / "sensitive-scan.json").unlink()),
            ("sensitive scan FAIL", lambda evidence: _patch_json(evidence / "sensitive-scan.json", result="FAIL")),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone")
                mutate(evidence)
                with self.assertRaises(P2ContractError):
                    _verify(evidence, "p2-exif", "iphone")


class VerifyCommandLineTests(unittest.TestCase):
    def _run(self, evidence: Path, suite: str, device_class: str, facts: dict[str, Any]) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(strict_e2e_p2_contract, "read_xcresult_facts", return_value=facts):
            code = contract_main(
                [
                    "--evidence-dir",
                    str(evidence),
                    "--suite",
                    suite,
                    "--device-class",
                    device_class,
                    "--expected-sha",
                    SOURCE_SHA,
                ],
                stdout=stdout,
                stderr=stderr,
            )
        return code, stdout.getvalue(), stderr.getvalue()

    def test_exit_codes_distinguish_pass_reviewed_non_pass_and_contract_failure(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache", "tv")
            facts = _facts("p2-cache", "tv")
            code, stdout, _ = self._run(evidence, "p2-cache", "tv", facts)
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(stdout)["verdict"], "PASS")

            _write_review(evidence, "p2-cache", "tv", verdict="NEEDS_HUMAN_REVIEW", conclusion="NEEDS_HUMAN_REVIEW")
            code, stdout, _ = self._run(evidence, "p2-cache", "tv", facts)
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(stdout)["verdict"], "NEEDS_HUMAN_REVIEW")

            (evidence / REVIEW_FILE).unlink()
            code, stdout, stderr = self._run(evidence, "p2-cache", "tv", facts)
            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("Missing sign-off", stderr)
            self.assertNotIn("Traceback", stderr)


if __name__ == "__main__":
    unittest.main()
