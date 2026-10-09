#!/usr/bin/env python3
"""Strict end-to-end evidence contract for the dedicated P2 UI cases.

The runner only collects raw evidence; PASS can only come from an independent sign-off.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import re
import struct
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, TextIO

from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256
from strict_e2e_photo_identity import MARKS, IdentityAssertionError, classify_screenshot
from strict_e2e_server import fixture_manifest
from ci_flaky import P2_RECORDING_SUITES


UI_BUNDLE = "immichSlidesUITests"
STEPS_FILE = "p2-steps.json"
STEPS_SCHEMA = "strict-e2e-steps-v1"
RECORDING_FILE = "screen-recording.mov"
RECORDING_TIMING_FILE = "screen-recording-timing.json"
REVIEW_FILE = "visual-review.json"
REVIEW_SCHEMA = "strict-e2e-visual-review-v1"
# The runner itself never produces PASS; a visual verdict can only come from visual-review.json.
RAW_VERDICT = "VISUAL_REVIEW_REQUIRED"
VERDICTS = ("PASS", "PARTIAL", "FAIL", "BLOCKED_ENV", "NOT_RUN", "NEEDS_HUMAN_REVIEW", "VISUAL_UNVERIFIED")
ORIENTATIONS = ("portrait", "landscape", "not_applicable")
DEVICE_PLATFORM = {"iphone": "ios", "ipad": "ios", "tv": "tvos"}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


class P2ContractError(Exception):
    pass


@dataclass(frozen=True)
class P2Case:
    e2e_ids: tuple[str, ...]
    devices: tuple[str, ...]
    selectors: Mapping[str, str]
    pngs: tuple[str, ...]
    marks: tuple[str, ...] = ()
    png_orientations: Mapping[str, str] = field(default_factory=dict)
    video: bool = False
    cache_clear: bool = False
    cache_return: bool = False
    sequence: tuple[str, ...] = ()

    @property
    def step_order(self) -> tuple[str, ...]:
        return self.sequence or (*self.pngs, *self.marks)


P2_CASES = {
    "p2-exif": P2Case(
        e2e_ids=("E2E-P2-01",),
        devices=("iphone", "ipad", "tv"),
        selectors={
            "ios": f"{UI_BUNDLE}/ExifToggleUITests/testExifToggleOwnershipIOS",
            "tvos": f"{UI_BUNDLE}/ExifToggleUITests/testExifToggleOwnershipTVOS",
        },
        pngs=("exif-full-on", "exif-off", "exif-reenabled", "exif-empty", "exif-smartfill-multi"),
    ),
    "p2-cache": P2Case(
        e2e_ids=("E2E-P2-02",),
        devices=("iphone", "tv"),
        selectors={
            "ios": f"{UI_BUNDLE}/CacheSettingsUITests/testClearDiskCacheFromSettingsIOS",
            "tvos": f"{UI_BUNDLE}/CacheSettingsUITests/testClearDiskCacheFromSettingsTVOS",
        },
        pngs=("cache-before-confirm", "cache-cleared", "cache-returned"),
        cache_clear=True,
    ),
    # iPad covers page completion and rendered return, without P2-02's disk-usage review.
    "p2-cache-smoke": P2Case(
        e2e_ids=(),
        devices=("ipad",),
        selectors={"ios": f"{UI_BUNDLE}/CacheSettingsUITests/testCacheSettingsPageSmokeIPad"},
        pngs=("cache-page-smoke", "cache-returned"),
        cache_return=True,
    ),
    "p2-reduce-motion": P2Case(
        e2e_ids=("E2E-P2-03",),
        devices=("iphone", "tv"),
        selectors={
            "ios": f"{UI_BUNDLE}/ReduceMotionUITests/testSystemReduceMotionIOS",
            "tvos": f"{UI_BUNDLE}/ReduceMotionUITests/testSystemReduceMotionTVOS",
        },
        pngs=("motion-system-original", "motion-system-enabled", "motion-system-restored"),
        marks=(
            "motion-off-single",
            "motion-off-smartfill",
            "motion-on-smartfill",
            "motion-on-smartfill-next",
            "motion-on-single",
            "motion-on-single-next",
        ),
        video="p2-reduce-motion" in P2_RECORDING_SUITES,
        sequence=(
            "motion-system-original",
            "motion-off-single",
            "motion-off-smartfill",
            "motion-system-enabled",
            "motion-on-smartfill",
            "motion-on-smartfill-next",
            "motion-on-single",
            "motion-on-single-next",
            "motion-system-restored",
        ),
    ),
    "p2-ipad-layout": P2Case(
        e2e_ids=("E2E-P2-04",),
        devices=("ipad",),
        selectors={"ios": f"{UI_BUNDLE}/RotationUITests/testSmartFillLayoutBothOrientationsIPad"},
        pngs=("layout-landscape-multi", "layout-portrait-multi"),
        png_orientations={"layout-landscape-multi": "landscape", "layout-portrait-multi": "portrait"},
    ),
    "p2-rotation": P2Case(
        e2e_ids=("E2E-P2-05",),
        devices=("iphone", "ipad"),
        selectors={"ios": f"{UI_BUNDLE}/RotationUITests/testRotationDuringPlaybackIOS"},
        pngs=("rotation-start-portrait", "rotation-landscape-stable", "rotation-portrait-stable"),
        marks=("rotate-to-landscape", "rotate-to-portrait"),
        png_orientations={
            "rotation-start-portrait": "portrait",
            "rotation-landscape-stable": "landscape",
            "rotation-portrait-stable": "portrait",
        },
        video="p2-rotation" in P2_RECORDING_SUITES,
        sequence=(
            "rotation-start-portrait",
            "rotate-to-landscape",
            "rotation-landscape-stable",
            "rotate-to-portrait",
            "rotation-portrait-stable",
        ),
    ),
    # Self-check of the evidence tooling: the window and screenshots settle in each orientation.
    "p2-orientation-selfcheck": P2Case(
        e2e_ids=(),
        devices=("iphone",),
        selectors={"ios": f"{UI_BUNDLE}/RotationUITests/testOrientationChangeReachesStableFrameIOS"},
        pngs=(
            "selfcheck-orientation-portrait",
            "selfcheck-orientation-landscape",
            "selfcheck-orientation-portrait-again",
        ),
        png_orientations={
            "selfcheck-orientation-portrait": "portrait",
            "selfcheck-orientation-landscape": "landscape",
            "selfcheck-orientation-portrait-again": "portrait",
        },
    ),
}

CACHE_CLEAR_REVIEW_CHECKS = {
    "cache-before-confirm.png": ("disk_usage_nonzero_before_confirm",),
    "cache-cleared.png": ("disk_usage_zero_after_clear", "success_feedback_visible"),
    "cache-returned.png": ("playback_normal_after_return",),
}


def p2_selector(suite: str, platform: str) -> str:
    case = P2_CASES.get(suite)
    if case is None:
        raise P2ContractError(f"Unknown P2 suite: {suite}.")
    selector = case.selectors.get(platform)
    if selector is None:
        raise P2ContractError(f"{suite} cannot run on {platform}; allowed devices: {', '.join(case.devices)}.")
    return selector


def device_class_of(device: Mapping[str, Any]) -> str:
    model = str(device.get("modelName") or "")
    platform = device.get("platform")
    if platform == "iOS Simulator" and model.startswith("iPhone"):
        return "iphone"
    if platform == "iOS Simulator" and model.startswith("iPad"):
        return "ipad"
    if platform == "tvOS Simulator" and model.startswith("Apple TV"):
        return "tv"
    raise P2ContractError(f"Official device is not an allowed simulator class: platform={platform} model={model or 'missing'}.")


def read_xcresult_facts(
    bundle: Path,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, Any]:
    if not bundle.is_dir():
        raise P2ContractError(f"Missing official result bundle: {bundle.name}.")
    try:
        completed = run(
            ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle), "--compact"],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise P2ContractError(f"Cannot run xcresulttool: {error}") from error
    if completed.returncode != 0:
        raise P2ContractError(f"xcresulttool read failed, exit {completed.returncode}.")
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise P2ContractError("xcresulttool output is not JSON.") from error
    if not isinstance(payload, dict):
        raise P2ContractError("xcresulttool output top level is not an object.")
    return official_tests_facts(payload)


def official_tests_facts(payload: Mapping[str, Any]) -> dict[str, Any]:
    test_cases: list[dict[str, Any]] = []

    def walk(nodes: object, bundle_name: object) -> None:
        for node in nodes if isinstance(nodes, list) else []:
            if not isinstance(node, dict):
                continue
            node_type = node.get("nodeType")
            if node_type == "Test Case":
                test_cases.append(
                    {"bundle": bundle_name, "identifier": node.get("nodeIdentifier"), "result": node.get("result")}
                )
                continue
            walk(node.get("children"), node.get("name") if str(node_type).endswith("test bundle") else bundle_name)

    walk(payload.get("testNodes"), None)
    devices = payload.get("devices")
    return {"test_cases": test_cases, "devices": devices if isinstance(devices, list) else []}


def read_official_tests_export(path: Path) -> dict[str, Any]:
    payload = _load_json(path.parent, path.name)
    return official_tests_facts(payload)


def require_official_execution(
    facts: Mapping[str, Any], *, suite: str, platform: str, simulator_udid: str
) -> dict[str, Any]:
    _bundle, test_class, method = p2_selector(suite, platform).split("/")
    expected = f"{test_class}/{method}()"
    cases = facts.get("test_cases")
    if not isinstance(cases, list) or len(cases) != 1:
        count = len(cases) if isinstance(cases, list) else "unreadable"
        raise P2ContractError(f"Official results must execute exactly 1 test method, got {count}.")
    case = cases[0]
    if (
        not isinstance(case, Mapping)
        or case.get("bundle") != UI_BUNDLE
        or case.get("identifier") != expected
        or case.get("result") != "Passed"
    ):
        raise P2ContractError(f"Official executed method mismatch: expected {UI_BUNDLE}/{expected} Passed, got {case}.")
    devices = facts.get("devices")
    if not isinstance(devices, list) or len(devices) != 1 or not isinstance(devices[0], Mapping):
        raise P2ContractError("Official results must record exactly 1 device.")
    device = devices[0]
    if device.get("deviceId") != simulator_udid:
        raise P2ContractError("Official device UDID does not match the runner destination.")
    device_class = device_class_of(device)
    if device_class not in P2_CASES[suite].devices or DEVICE_PLATFORM[device_class] != platform:
        raise P2ContractError(f"{suite} cannot be counted on {device_class} / {platform}.")
    return {
        "executed_tests": [expected],
        "device": {
            "class": device_class,
            "model": device.get("modelName"),
            "os_version": device.get("osVersion"),
            "os_build": device.get("osBuildNumber"),
            "udid": simulator_udid,
        },
    }


def _read_required(evidence_dir: Path, name: str) -> bytes:
    path = evidence_dir / name
    if not path.is_file():
        raise P2ContractError(f"Missing required artifact: {name}.")
    try:
        data = path.read_bytes()
    except OSError as error:
        raise P2ContractError(f"Cannot read {name}: {error}") from error
    if not data:
        raise P2ContractError(f"Required artifact is an empty file: {name}.")
    return data


def _load_json(evidence_dir: Path, name: str, schema: str | None = None) -> dict[str, Any]:
    try:
        payload = json.loads(_read_required(evidence_dir, name).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise P2ContractError(f"{name} is not valid JSON.") from error
    if not isinstance(payload, dict):
        raise P2ContractError(f"{name} top level must be an object.")
    if schema is not None and payload.get("schema") != schema:
        raise P2ContractError(f"{name} schema must be {schema}.")
    return payload


def _png_size(data: bytes, name: str) -> tuple[int, int]:
    if len(data) < 24 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        raise P2ContractError(f"Required PNG is corrupt: {name}.")
    width, height = struct.unpack(">II", data[16:24])
    if width == 0 or height == 0:
        raise P2ContractError(f"Required PNG has zero size: {name}.")
    return width, height


def _require_png(evidence_dir: Path, name: str) -> bytes:
    data = _read_required(evidence_dir, name)
    _png_size(data, name)
    return data


def _number(value: object, context: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise P2ContractError(f"{context} must be a finite number.")
    return float(value)


def _integer(value: object, context: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise P2ContractError(f"{context} must be an integer.")
    return value


def _text(value: object, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise P2ContractError(f"{context} must not be empty.")
    return value


def _digest(data: bytes) -> dict[str, Any]:
    return {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def _validate_steps(evidence_dir: Path, case: P2Case) -> tuple[list[dict[str, Any]], dict[str, float]]:
    steps = _load_json(evidence_dir, STEPS_FILE, STEPS_SCHEMA).get("steps")
    if not isinstance(steps, list) or not steps:
        raise P2ContractError(f"{STEPS_FILE} has no steps.")
    referenced: dict[str, str] = {}
    first_seen: dict[str, tuple[int, float]] = {}
    last_index, last_time = 0, -math.inf
    for position, step in enumerate(steps, 1):
        context = f"{STEPS_FILE} step {position}"
        if not isinstance(step, dict):
            raise P2ContractError(f"{context} is not an object.")
        index = _integer(step.get("index"), f"{context} index")
        if index <= last_index:
            raise P2ContractError(f"{context} index must strictly increase.")
        wall_time = _number(step.get("wall_time"), f"{context} wall_time")
        if wall_time < last_time:
            raise P2ContractError(f"{context} wall_time went backwards.")
        key = _text(step.get("name"), f"{context} name")
        orientation = step.get("orientation")
        if orientation not in ORIENTATIONS:
            raise P2ContractError(f"{context} orientation must be {'/'.join(ORIENTATIONS)}.")
        png = step.get("png")
        if png is not None:
            if not isinstance(png, str) or Path(png).name != png or not png.endswith(".png") or png in referenced:
                raise P2ContractError(f"{context} png must be a PNG file name in this directory, referenced only once.")
            width, height = _png_size(_require_png(evidence_dir, png), png)
            if (orientation == "landscape" and width <= height) or (orientation == "portrait" and height <= width):
                raise P2ContractError(f"{png} pixels {width}x{height} do not match the declared orientation {orientation}.")
            referenced[png] = str(orientation)
            key = png[: -len(".png")]
        first_seen.setdefault(key, (position, wall_time))
        last_index, last_time = index, wall_time
    for png in case.pngs:
        name = f"{png}.png"
        if name not in referenced:
            raise P2ContractError(f"Required PNG is not referenced by the step record: {name}.")
        expected = case.png_orientations.get(png)
        if expected is not None and referenced[name] != expected:
            raise P2ContractError(f"{name} orientation must be {expected}, got {referenced[name]}.")
    missing_marks = [mark for mark in case.marks if mark not in first_seen]
    if missing_marks:
        raise P2ContractError(f"Step record is missing required marks: {', '.join(missing_marks)}.")
    positions = [first_seen[name][0] for name in case.step_order]
    if positions != sorted(positions):
        raise P2ContractError(f"Step order must be: {' → '.join(case.step_order)}.")
    return steps, {name: first_seen[name][1] for name in case.step_order}


def _movie_atoms(data: bytes) -> list[bytes]:
    atoms: list[bytes] = []
    offset = 0
    while offset < len(data):
        if len(data) - offset < 8:
            raise P2ContractError(f"Recording atom structure is truncated: {RECORDING_FILE}.")
        size, kind = struct.unpack(">I4s", data[offset : offset + 8])
        header = 8
        if size == 1:
            if len(data) - offset < 16:
                raise P2ContractError(f"Recording atom structure is truncated: {RECORDING_FILE}.")
            size = struct.unpack(">Q", data[offset + 8 : offset + 16])[0]
            header = 16
        elif size == 0:
            size = len(data) - offset
        if size < header or offset + size > len(data):
            raise P2ContractError(f"Recording atom structure is truncated: {RECORDING_FILE}.")
        atoms.append(kind)
        offset += size
    return atoms


def _validate_recording(
    evidence_dir: Path, steps: list[dict[str, Any]], times: Mapping[str, float], marks: tuple[str, ...]
) -> tuple[bytes, dict[str, float]]:
    data = _read_required(evidence_dir, RECORDING_FILE)
    # simctl writes moov only after SIGINT; without moov the recording is unfinished and cannot be played back.
    if b"moov" not in _movie_atoms(data):
        raise P2ContractError(f"Recording not finalized (missing moov): {RECORDING_FILE}.")
    timing = _load_json(evidence_dir, RECORDING_TIMING_FILE)
    started = _number(timing.get("started_wall_time"), f"{RECORDING_TIMING_FILE} started_wall_time")
    stopped = _number(timing.get("stopped_wall_time"), f"{RECORDING_TIMING_FILE} stopped_wall_time")
    if _integer(timing.get("stop_exit"), f"{RECORDING_TIMING_FILE} stop_exit") != 0:
        raise P2ContractError(f"{RECORDING_TIMING_FILE} stop_exit is non-zero; the screen recording did not finish cleanly.")
    if stopped <= started:
        raise P2ContractError(f"{RECORDING_TIMING_FILE} stop time is not later than start time.")
    outside = [str(step.get("name")) for step in steps if not started <= float(step["wall_time"]) <= stopped]
    if outside:
        raise P2ContractError(f"Steps outside the recording window: {', '.join(outside)}.")
    return data, {mark: times[mark] - started for mark in marks}


def _classify_mark(evidence_dir: Path, name: str) -> str:
    try:
        identity = classify_screenshot(_require_png(evidence_dir, name))
    except IdentityAssertionError as error:
        raise P2ContractError(str(error)) from error
    if identity.status != "MATCH" or identity.mark not in MARKS:
        raise P2ContractError(f"{name} cannot be recognized as a public mark ({identity.status}).")
    return str(identity.mark)


def _validate_cache_clear(evidence_dir: Path, fixture_set: str) -> dict[str, Any]:
    for name in ("cache-before-confirm.png", "cache-cleared.png"):
        data = _require_png(evidence_dir, name)
        try:
            from PIL import Image

            with Image.open(io.BytesIO(data)) as image:
                image.verify()
        except Exception as error:
            raise P2ContractError(f"Required PNG cannot be fully decoded: {name}.") from error
    return _validate_returned_mark(evidence_dir, fixture_set)


def _validate_returned_mark(evidence_dir: Path, fixture_set: str) -> dict[str, Any]:
    returned = _classify_mark(evidence_dir, "cache-returned.png")
    fixture_marks = {asset["label"] for asset in fixture_manifest(fixture_set)["assets"]}
    if returned not in fixture_marks:
        raise P2ContractError(f"Public mark {returned} shown after return is not in fixture {fixture_set}.")
    return {"target_mark": returned}


def validate_raw_evidence(evidence_dir: Path, suite: str, fixture_set: str) -> dict[str, Any]:
    case = P2_CASES.get(suite)
    if case is None:
        raise P2ContractError(f"Unknown P2 suite: {suite}.")
    if fixture_set not in FROZEN_FIXTURE_SHA256:
        raise P2ContractError(f"Unknown fixture set: {fixture_set}.")
    artifacts = {f"{png}.png": _digest(_require_png(evidence_dir, f"{png}.png")) for png in case.pngs}
    steps, times = _validate_steps(evidence_dir, case)
    records = {STEPS_FILE: _digest(_read_required(evidence_dir, STEPS_FILE))}
    payload: dict[str, Any] = {"verdict": RAW_VERDICT, "suite": suite, "artifacts": artifacts, "records": records}
    if case.video:
        movie, payload["mark_offsets"] = _validate_recording(evidence_dir, steps, times, case.marks)
        artifacts[RECORDING_FILE] = _digest(movie)
        records[RECORDING_TIMING_FILE] = _digest(_read_required(evidence_dir, RECORDING_TIMING_FILE))
    if case.cache_clear:
        payload["cache_clear"] = _validate_cache_clear(evidence_dir, fixture_set)
    if case.cache_return:
        payload["cache_return"] = _validate_returned_mark(evidence_dir, fixture_set)
    return payload


def evaluate_review(
    evidence_dir: Path,
    *,
    suite: str,
    device_class: str,
    source_sha: str,
    fixture_set: str,
    artifacts: Mapping[str, Mapping[str, Any]],
    mark_offsets: Mapping[str, float],
    cache_target_mark: str | None = None,
) -> str:
    if not (evidence_dir / REVIEW_FILE).is_file():
        raise P2ContractError(f"Missing sign-off: {REVIEW_FILE} is required; verdict can only be VISUAL_UNVERIFIED.")
    review = _load_json(evidence_dir, REVIEW_FILE, REVIEW_SCHEMA)
    _text(review.get("reviewer"), f"{REVIEW_FILE} reviewer")
    for key, expected in (("suite", suite), ("device_class", device_class), ("source_sha", source_sha)):
        if review.get(key) != expected:
            raise P2ContractError(f"The {key} bound in the sign-off does not match the evidence.")
    verdict = review.get("verdict")
    if verdict not in VERDICTS:
        raise P2ContractError(f"Overall sign-off verdict must be {'/'.join(VERDICTS)}.")
    entries = review.get("artifacts")
    if not isinstance(entries, Mapping):
        raise P2ContractError(f"{REVIEW_FILE} is missing artifacts.")
    fixture_hashes = {asset["label"]: asset["sha256"] for asset in fixture_manifest(fixture_set)["assets"]}
    conclusions: list[object] = []
    for name, facts in artifacts.items():
        entry = entries.get(name)
        if not isinstance(entry, Mapping):
            raise P2ContractError(f"Sign-off is missing an item: {name}.")
        if entry.get("sha256") != facts["sha256"]:
            raise P2ContractError(f"Artifact changed after sign-off, or the sign-off is not for this artifact: {name}.")
        _text(entry.get("observation"), f"{name} observation")
        conclusions.append(entry.get("conclusion"))
        if name == RECORDING_FILE:
            slices = entry.get("time_slices")
            if not isinstance(slices, list) or not slices:
                raise P2ContractError(f"{name} is missing time-slice sign-off.")
            spans: list[tuple[float, float]] = []
            for piece in slices:
                if not isinstance(piece, Mapping):
                    raise P2ContractError(f"{name} time slice is not an object.")
                start = _number(piece.get("start_s"), f"{name} start_s")
                end = _number(piece.get("end_s"), f"{name} end_s")
                if not 0 <= start < end:
                    raise P2ContractError(f"{name} time slice start/end is invalid.")
                _text(piece.get("observation"), f"{name} time slice observation")
                conclusions.append(piece.get("conclusion"))
                spans.append((start, end))
            uncovered = [
                mark for mark, offset in mark_offsets.items() if not any(start <= offset <= end for start, end in spans)
            ]
            if uncovered:
                raise P2ContractError(f"{name} time slices do not cover marks: {', '.join(uncovered)}.")
            continue
        is_cache_settings_frame = suite == "p2-cache" and name in {
            "cache-before-confirm.png",
            "cache-cleared.png",
        }
        visible = entry.get("visible_marks")
        hashes = entry.get("fixture_sha256")
        if not is_cache_settings_frame:
            if (
                not isinstance(visible, list)
                or not isinstance(hashes, Mapping)
                or any(mark not in MARKS for mark in visible)
                or set(hashes) != set(visible)
                or any(hashes[mark] != fixture_hashes.get(mark) for mark in visible)
            ):
                raise P2ContractError(f"{name} visible marks or fixture hashes do not match the public data.")
            if name == "cache-returned.png" and entry.get("conclusion") == "PASS":
                if cache_target_mark is None or visible != [cache_target_mark]:
                    raise P2ContractError("cache-returned.png manual mark sign-off does not match the machine-recognized returned photo.")
        _text(entry.get("controls"), f"{name} controls")
        required_checks = CACHE_CLEAR_REVIEW_CHECKS.get(name) if suite == "p2-cache" else None
        if required_checks:
            checks = entry.get("checks")
            if not isinstance(checks, Mapping) or set(checks) != set(required_checks):
                raise P2ContractError(f"{name} is missing the matching manual cache-clear checks: {', '.join(required_checks)}.")
            for check_name in required_checks:
                check_verdict = checks[check_name]
                if check_verdict not in VERDICTS:
                    raise P2ContractError(f"{name} manual check {check_name} has an invalid verdict.")
                conclusions.append(check_verdict)
    if any(conclusion not in VERDICTS for conclusion in conclusions):
        raise P2ContractError(f"Per-item verdicts must be {'/'.join(VERDICTS)}.")
    if verdict == "PASS" and any(conclusion != "PASS" for conclusion in conclusions):
        raise P2ContractError("Overall verdict PASS is inconsistent with the per-item verdicts.")
    return str(verdict)


def _destination_udid(destination: object) -> str:
    for component in str(destination or "").split(","):
        key, separator, value = component.strip().partition("=")
        if separator and key == "id" and value:
            return value
    raise P2ContractError("case-manifest.json destination is missing the Simulator id.")


def verify_evidence(
    evidence_dir: Path,
    *,
    suite: str,
    device_class: str,
    expected_sha: str,
    read_facts: Callable[[Path], Mapping[str, Any]] | None = None,
) -> dict[str, Any]:
    case = P2_CASES.get(suite)
    if case is None:
        raise P2ContractError(f"Unknown P2 suite: {suite}.")
    if device_class not in case.devices:
        raise P2ContractError(f"{suite} does not allow device class {device_class}.")
    if not SHA_PATTERN.fullmatch(expected_sha):
        raise P2ContractError("--expected-sha must be a full 40-character lowercase hex string.")
    manifest = _load_json(evidence_dir, "case-manifest.json")
    if manifest.get("suite") != suite:
        raise P2ContractError("case-manifest.json is not for this case.")
    if manifest.get("source_sha") != expected_sha:
        raise P2ContractError("Evidence candidate SHA does not match --expected-sha.")
    if manifest.get("source_dirty_paths") != []:
        raise P2ContractError("The worktree had uncommitted changes at run time, or its state was not recorded.")
    if str(manifest.get("result", "")).lower() != "passed" or manifest.get("exit_code") != 0:
        raise P2ContractError("Runner did not finish successfully.")
    if manifest.get("scenario") != "normal":
        raise P2ContractError("P2 evidence can only come from the fixture service in the normal scenario.")
    fixture_set = manifest.get("fixture_set")
    if (
        not isinstance(fixture_set, str)
        or fixture_set not in FROZEN_FIXTURE_SHA256
        or manifest.get("fixture_sha256") != FROZEN_FIXTURE_SHA256[fixture_set]
    ):
        raise P2ContractError("Fixture set or hash does not match the frozen value.")
    platform = DEVICE_PLATFORM[device_class]
    if manifest.get("platform") != platform:
        raise P2ContractError("case-manifest.json platform does not match the device class.")
    simulator_udid = _destination_udid(manifest.get("destination"))
    if (evidence_dir / "cleanup-failures.json").exists():
        raise P2ContractError("Runner cleanup failed (cleanup-failures.json exists); the evidence is not closed out.")
    raw = validate_raw_evidence(evidence_dir, suite, fixture_set)
    runner_report = _load_json(evidence_dir, "visual-identity-runner.json")
    if {key: value for key, value in runner_report.items() if key != "execution"} != raw:
        raise P2ContractError("Artifacts or step record differ from the SHA-256 the runner recorded (replaced after the run, or runner not closed out).")
    scan = _load_json(evidence_dir, "sensitive-scan.json")
    if scan.get("result") != "PASS" or scan.get("matched_files") != []:
        raise P2ContractError("Sensitive scan is not PASS.")
    verdict = evaluate_review(
        evidence_dir,
        suite=suite,
        device_class=device_class,
        source_sha=expected_sha,
        fixture_set=fixture_set,
        artifacts=raw["artifacts"],
        mark_offsets=raw.get("mark_offsets", {}),
        cache_target_mark=(raw.get("cache_clear") or raw.get("cache_return") or {}).get("target_mark"),
    )
    bundle = evidence_dir / f"strict-{suite}.xcresult"
    if bundle.is_dir():
        facts = (read_facts or read_xcresult_facts)(bundle)
    else:
        exported = evidence_dir / "official-tests.json"
        if not exported.is_file():
            raise P2ContractError(f"Missing official result bundle and export: {bundle.name}.")
        disposal = _load_json(evidence_dir, "result-bundle-disposal.json")
        if disposal.get("result_bundle_disposed") is not True:
            raise P2ContractError("Credential isolation of the official result bundle was not closed out.")
        expected_digest = manifest.get("official_tests_sha256")
        if not isinstance(expected_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
            raise P2ContractError("Missing official result export hash.")
        if disposal.get("official_tests_sha256") != expected_digest:
            raise P2ContractError("Result bundle disposal record does not match the manifest hash.")
        if hashlib.sha256(exported.read_bytes()).hexdigest() != expected_digest:
            raise P2ContractError("Official result export content does not match the run manifest hash.")
        facts = read_official_tests_export(exported)
    execution = require_official_execution(facts, suite=suite, platform=platform, simulator_udid=simulator_udid)
    if execution["device"]["class"] != device_class:
        raise P2ContractError("Official device class does not match --device-class.")
    result = {"verdict": verdict, "suite": suite, "source_sha": expected_sha, **execution, "artifacts": raw["artifacts"]}
    if "cache_clear" in raw:
        result["cache_clear"] = raw["cache_clear"]
    return result


def main(argv: list[str] | None = None, stdout: TextIO | None = None, stderr: TextIO | None = None) -> int:
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--suite", required=True, choices=sorted(P2_CASES))
    parser.add_argument("--device-class", required=True, choices=sorted(DEVICE_PLATFORM))
    parser.add_argument("--expected-sha", required=True)
    arguments = parser.parse_args(argv)
    try:
        result = verify_evidence(
            arguments.evidence_dir,
            suite=arguments.suite,
            device_class=arguments.device_class,
            expected_sha=arguments.expected_sha,
        )
    except P2ContractError as error:
        print(f"P2 evidence contract failed: {error}", file=stderr)
        return 2
    except OSError as error:
        print(f"P2 evidence read failed: {error}", file=stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True), file=stdout)
    return 0 if result["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
