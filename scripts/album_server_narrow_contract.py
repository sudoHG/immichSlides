#!/usr/bin/env python3
"""Album and server narrow-test contract: 15 official methods, empty album, immediate policy, negative controls."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping, Sequence

from access_lifecycle_contract import (
    classify_display_regions,
)
from strict_e2e_filter_contract import (
    FilterContractError,
    _display_foreground_png,
    _evaluate_display_policy,
    _scene_slot_marks,
    START_PLAYBACK_BUTTON_ID,
    assert_empty_selection_cannot_start,
    assert_foreign_server_ids_absent,
    assert_playback_marks_in_target,
    load_member_manifest,
    member_manifest,
    target_album_frame_identity,
)
from strict_e2e_photo_identity import (
    MARKS,
    classify_screenshot,
)
from strict_e2e_server import PUBLIC_API_KEY, fixture_manifest


class AlbumServerContractError(FilterContractError):
    pass


EMPTY_FILTERED_COPY = "当前筛选条件没有找到可播放照片，请换一组相册或人物再试。"
START_NOT_APPLICABLE_SETTINGS_EDITOR = "not_applicable_settings_editor"
SETTINGS_FILTER_ENTRY_ID = "settings.playback.filterConfig.button"
FORBIDDEN_IDENTITY_SOURCES = frozenset(
    {
        "probe",
        "enum",
        "asset_id",
        "currentAssetId",
        "launch_argument",
        "UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE",
    }
)
IOS_SCHEME = "immichSlides-iOS"
TVOS_SCHEME = "immichSlides-tvOS"
IOS_PLAN = "StrictE2E-iOS"
TVOS_PLAN = "StrictE2E-tvOS"

IOS_FIRST_BOOT_COLD_RELAUNCH = "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testFirstBootSetupSurvivesColdRelaunch"
IOS_ALBUM_EMPTY = "immichSlidesUITests/StrictE2EFilterIOSUITests/testTargetAlbumPlaysAndEmptyAlbumShowsEmptyResult"
IOS_SERVER_SWITCH = "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterServerSwitchIsolation"
IOS_FAILURE = "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testFirstBootFailureStaysOnFirstBoot"
TVOS_FIRST_BOOT_COLD_RELAUNCH = "immichSlidesUITests/StrictE2ETVOSFlowUITests/testTVOSFirstBootSaveAndConfiguredColdLaunch"
TVOS_ALBUM_EMPTY = "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSTargetAlbumPlaysAndEmptyAlbumShowsEmptyResult"
TVOS_SERVER_SWITCH = "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSServerSwitchIsolation"
TVOS_FAILURE = "immichSlidesUITests/StrictE2ETVOSFlowUITests/testTVOSAlbumServerFirstBootFailureHTML200"
SERVER_SWITCH_RECORDING_FILE = "screen-recording.mov"
SERVER_SWITCH_SAVE_SUCCESS_PNG = "server-switch-b-save-success.png"
SERVER_SWITCH_SELECTION_CLEARED_PNG = "server-switch-b-selection-cleared.png"
SERVER_SWITCH_OBSERVED_SOURCE = "ui_accessibility_identifier"
SERVER_SWITCH_SUITE_BY_PLATFORM = {
    "iphone": "filter-switch",
    "ipad": "filter-switch",
    "tvos": "tvos-switch",
}
SERVER_SWITCH_RUNNER_PLATFORM = {
    "iphone": "ios",
    "ipad": "ios",
    "tvos": "tvos",
}

OFFICIAL_CASES: tuple[dict[str, str], ...] = (
    {
        "id": "1",
        "platform": "iphone",
        "narrow": "first-boot-cold-relaunch",
        "selector": IOS_FIRST_BOOT_COLD_RELAUNCH,
        "scenario": "normal",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
    {
        "id": "2",
        "platform": "iphone",
        "narrow": "album-empty",
        "selector": IOS_ALBUM_EMPTY,
        "scenario": "normal",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
    {
        "id": "3",
        "platform": "iphone",
        "narrow": "server-switch",
        "selector": IOS_SERVER_SWITCH,
        "scenario": "normal",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
    {
        "id": "4",
        "platform": "iphone",
        "narrow": "fail-401",
        "selector": IOS_FAILURE,
        "scenario": "auth-401",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
    {
        "id": "5",
        "platform": "iphone",
        "narrow": "fail-html-200",
        "selector": IOS_FAILURE,
        "scenario": "html-200",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
    {
        "id": "6",
        "platform": "iphone",
        "narrow": "fail-unreachable",
        "selector": IOS_FAILURE,
        "scenario": "unreachable",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
    {
        "id": "7",
        "platform": "iphone",
        "narrow": "fail-timeout",
        "selector": IOS_FAILURE,
        "scenario": "timeout",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
    {
        "id": "8",
        "platform": "tvos",
        "narrow": "first-boot-cold-relaunch",
        "selector": TVOS_FIRST_BOOT_COLD_RELAUNCH,
        "scenario": "normal",
        "scheme": TVOS_SCHEME,
        "plan": TVOS_PLAN,
    },
    {
        "id": "9",
        "platform": "tvos",
        "narrow": "album-empty",
        "selector": TVOS_ALBUM_EMPTY,
        "scenario": "normal",
        "scheme": TVOS_SCHEME,
        "plan": TVOS_PLAN,
    },
    {
        "id": "10",
        "platform": "tvos",
        "narrow": "server-switch",
        "selector": TVOS_SERVER_SWITCH,
        "scenario": "normal",
        "scheme": TVOS_SCHEME,
        "plan": TVOS_PLAN,
    },
    {
        "id": "11",
        "platform": "tvos",
        "narrow": "fail-html-200",
        "selector": TVOS_FAILURE,
        "scenario": "html-200",
        "scheme": TVOS_SCHEME,
        "plan": TVOS_PLAN,
    },
    {
        "id": "12",
        "platform": "ipad",
        "narrow": "first-boot-cold-relaunch",
        "selector": IOS_FIRST_BOOT_COLD_RELAUNCH,
        "scenario": "normal",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
    {
        "id": "13",
        "platform": "ipad",
        "narrow": "album-empty",
        "selector": IOS_ALBUM_EMPTY,
        "scenario": "normal",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
    {
        "id": "14",
        "platform": "ipad",
        "narrow": "server-switch",
        "selector": IOS_SERVER_SWITCH,
        "scenario": "normal",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
    {
        "id": "15",
        "platform": "ipad",
        "narrow": "fail-401",
        "selector": IOS_FAILURE,
        "scenario": "auth-401",
        "scheme": IOS_SCHEME,
        "plan": IOS_PLAN,
    },
)


EXPECTED_OFFICIAL_CASE_COUNT = 15

def official_case_count() -> int:
    return len(OFFICIAL_CASES)


def official_case_key(case: Mapping[str, str]) -> tuple[str, str, str]:
    return (case["platform"], case["selector"], case["scenario"])


def validate_official_case_table() -> None:
    if official_case_count() != EXPECTED_OFFICIAL_CASE_COUNT:
        raise AlbumServerContractError(f"There must be {EXPECTED_OFFICIAL_CASE_COUNT} official methods, got {official_case_count()}")
    keys = [official_case_key(case) for case in OFFICIAL_CASES]
    if len(set(keys)) != EXPECTED_OFFICIAL_CASE_COUNT:
        raise AlbumServerContractError(f"The platform+selector+scenario of the {EXPECTED_OFFICIAL_CASE_COUNT} official methods must all be distinct")
    if any(case["selector"].count("/") < 2 for case in OFFICIAL_CASES):
        raise AlbumServerContractError("Selectors must be Target/Class/method")


def count_official_executions(summaries: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    """Each official method needs its own 1/0/0. One execution must never be reported as three passes."""
    validate_official_case_table()
    if len(summaries) != EXPECTED_OFFICIAL_CASE_COUNT:
        raise AlbumServerContractError(
            f"Need exactly {EXPECTED_OFFICIAL_CASE_COUNT} official execution summaries, got {len(summaries)}; 1 execution cannot count as 3 passes"
        )
    seen: set[tuple[str, str, str]] = set()
    executed_total = 0
    for index, summary in enumerate(summaries):
        case = OFFICIAL_CASES[index]
        key = official_case_key(case)
        if key in seen:
            raise AlbumServerContractError("The same official method was counted more than once")
        seen.add(key)
        executed = int(summary.get("executed", -1))
        failed = int(summary.get("failed", -1))
        skipped = int(summary.get("skipped", -1))
        passed = int(summary.get("passed", executed - failed - skipped if executed >= 0 else -1))
        if executed != 1 or failed != 0 or skipped != 0 or passed != 1:
            raise AlbumServerContractError(
                f"Case {case['id']} must be 1/0/0, got executed={executed} failed={failed} skipped={skipped} passed={passed}"
            )
        executed_total += executed
    if executed_total != EXPECTED_OFFICIAL_CASE_COUNT:
        raise AlbumServerContractError(f"Official execution count must be {EXPECTED_OFFICIAL_CASE_COUNT}, got {executed_total}")
    return {"executed": EXPECTED_OFFICIAL_CASE_COUNT, "failed": 0, "skipped": 0, "passed": EXPECTED_OFFICIAL_CASE_COUNT}


def reject_success_without_executions(summary: Mapping[str, Any]) -> None:
    executed = int(summary.get("executed", 0))
    skipped = int(summary.get("skipped", 0))
    if executed == 0 or skipped > 0:
        raise AlbumServerContractError("Zero executions or skips cannot be reported as success")


def empty_album_id(fixture_set: str) -> str:
    return str(member_manifest(fixture_set)["empty_album"]["id"])


def empty_album_is_listed(fixture_set: str) -> bool:
    albums = fixture_manifest(fixture_set)["albums"]
    empty = [album for album in albums if album.get("fixture_role") == "empty"]
    return len(empty) == 1 and empty[0]["assetCount"] == 0 and empty[0]["assetIds"] == []


def _recorded_start_enabled(payload: Mapping[str, Any], source: str) -> bool:
    # A missing or null value means the Start button was never observed; it must not read as "disabled".
    value = payload.get("start_enabled")
    if not isinstance(value, bool):
        raise AlbumServerContractError(f"{source} start_enabled must be a recorded Boolean")
    return value


def _empty_album_start_state(payload: Mapping[str, Any]) -> bool | str:
    # The Settings filter editor never presents Start Playback, so there the producer records an explicit marker.
    value = payload.get("start_enabled")
    if value == START_NOT_APPLICABLE_SETTINGS_EDITOR:
        if payload.get("entry") != SETTINGS_FILTER_ENTRY_ID:
            raise AlbumServerContractError(
                "empty-album.json start_enabled may be not applicable only for the Settings filter editor entry"
            )
        return value
    if not isinstance(value, bool):
        raise AlbumServerContractError(
            "empty-album.json start_enabled must be a recorded Boolean or the Settings editor not-applicable marker"
        )
    return value


def evaluate_album_empty_evidence(evidence_dir: Path, fixture_set: str = "a", *,
                                  use_ios_album_geometry: bool) -> dict[str, Any]:
    manifest = load_member_manifest(evidence_dir / "member-manifest.json")
    if str(manifest["fixture_set"]) != fixture_set:
        raise AlbumServerContractError("Album-empty member-manifest does not match the requested fixture")
    empty_selection = _read_json(evidence_dir / "empty-selection.json", "empty-selection.json")
    if empty_selection.get("start_button_id") != START_PLAYBACK_BUTTON_ID:
        raise AlbumServerContractError("Empty-selection start button id does not match the frozen contract")
    if empty_selection.get("identity_source") in FORBIDDEN_IDENTITY_SOURCES:
        raise AlbumServerContractError("Request logs, index or probes cannot serve as identity truth")
    assert_empty_selection_cannot_start(
        album_ids=list(empty_selection.get("album_ids") or []),
        person_filters=list(empty_selection.get("person_filters") or []),
        start_enabled=_recorded_start_enabled(empty_selection, "empty-selection.json"),
    )
    playback_names = [
        name
        for name in ("album-play-1", "album-play-2")
        if (evidence_dir / f"{name}.png").is_file()
    ]
    if len(playback_names) < 2:
        raise AlbumServerContractError("The target album needs screenshots of at least two different public identities")
    frame_marks = []
    frame_geometry = {}
    for name in playback_names:
        if use_ios_album_geometry:
            marks, geometry = target_album_frame_identity((evidence_dir / f"{name}.png").read_bytes(), fixture_set)
            frame_geometry[name] = geometry
        else:
            # tvOS uses the scene reader; iOS retains its measured/unmeasured boundary above.
            marks = _scene_slot_marks((evidence_dir / f"{name}.png").read_bytes(), fixture_set)
        frame_marks.append(marks)
    marks = [mark for frame in frame_marks for mark in frame]
    if len(set(marks)) < 2 or len({frozenset(frame) for frame in frame_marks}) < 2:
        raise AlbumServerContractError("The two playback screenshots must be different public identities; an asset ID is not visual proof")
    assert_playback_marks_in_target(marks, fixture_set)

    empty_payload = _read_json(evidence_dir / "empty-album.json", "empty-album.json")
    if empty_payload.get("album_id") != empty_album_id(fixture_set):
        raise AlbumServerContractError("The empty album must be the controlled empty fixture; the selection cannot be faked")
    if empty_payload.get("identity_source") in FORBIDDEN_IDENTITY_SOURCES:
        raise AlbumServerContractError("The empty-album branch cannot use a probe or enum in place of the screen")
    copy = str(empty_payload.get("empty_copy") or "")
    if copy != EMPTY_FILTERED_COPY:
        raise AlbumServerContractError("The empty-result copy must come from the frozen existing production resource")
    result_path = evidence_dir / "empty-album-result.png"
    if not result_path.is_file():
        raise AlbumServerContractError("Missing empty-album result screenshot")
    if _empty_result_shows_fixture_photo(result_path.read_bytes()):
        raise AlbumServerContractError("After the empty album, photos from the old non-empty pool must not keep playing")
    report = {
        "verdict": "PASS",
        "suite": "album-empty",
        "marks": marks,
        "empty_copy": copy,
        "empty_album_id": empty_payload["album_id"],
        "start_enabled_after_empty_album": _empty_album_start_state(empty_payload),
    }
    if use_ios_album_geometry:
        report["target_album_geometry"] = "measured" if set(frame_geometry.values()) == {"measured"} else "unmeasured"
        report["target_album_frame_geometry"] = frame_geometry
    return report


def evaluate_server_switch_evidence(evidence_dir: Path, *, suite: str = "filter-switch") -> dict[str, Any]:
    load_member_manifest(evidence_dir / "member-manifest-a.json")
    manifest_b = load_member_manifest(evidence_dir / "member-manifest-b.json")
    if not (evidence_dir / "server-switch-a-play-1.png").is_file():
        raise AlbumServerContractError("Missing screenshot of A's selected scope and photo")
    try:
        a_marks = _scene_slot_marks((evidence_dir / "server-switch-a-play-1.png").read_bytes(), "a",
                                    screenshot_name="server-switch-a-play-1.png")
    except FilterContractError as error:
        raise AlbumServerContractError(str(error)) from error
    assert_playback_marks_in_target(a_marks, "a")
    b_names = [name for name in ("switch-b-play-1", "switch-b-play-2") if (evidence_dir / f"{name}.png").is_file()]
    if not b_names:
        raise AlbumServerContractError("After switching servers there must be a screenshot of B's public pattern")
    marks = []
    for name in b_names:
        try:
            marks.extend(_scene_slot_marks((evidence_dir / f"{name}.png").read_bytes(), "b",
                                           screenshot_name=f"{name}.png"))
        except FilterContractError as error:
            raise AlbumServerContractError(str(error)) from error
    assert_playback_marks_in_target(marks, str(manifest_b["fixture_set"]))
    a_bytes = (evidence_dir / "server-switch-a-play-1.png").read_bytes()
    b_bytes = (evidence_dir / f"{b_names[0]}.png").read_bytes()
    if a_bytes == b_bytes:
        raise AlbumServerContractError("After switching servers the screen is still the same as A")
    _require_named_png(evidence_dir, SERVER_SWITCH_SAVE_SUCCESS_PNG, "Missing B save-success screen")
    _require_named_png(evidence_dir, SERVER_SWITCH_SELECTION_CLEARED_PNG, "Missing screen showing the old selection cleared")
    observed = _read_json(evidence_dir / "observed-ids.json", "observed-ids.json")
    assert_server_switch_observed_ids(observed, str(manifest_b["fixture_set"]))
    _require_server_switch_recording(evidence_dir)
    finite_rotation = _evaluate_display_policy(evidence_dir, suite, manifest=manifest_b)
    display = {
        "verdict": finite_rotation["verdict"],
        "before_marks": finite_rotation["before_marks"],
        "after_mark": finite_rotation["after_mark"],
        "before_status": classify_screenshot((evidence_dir / "display-before.png").read_bytes()).status,
        "after_status": classify_screenshot(_display_foreground_png((evidence_dir / "display-after.png").read_bytes())).status,
        "finite_rotation": finite_rotation,
    }
    return {
        "verdict": "PASS",
        "suite": "server-switch",
        "marks": marks,
        "display": display,
        "b_pattern": "b",
    }


def assert_server_switch_observed_ids(observed: Mapping[str, Any], fixture_set: str) -> None:
    observed_ids = observed.get("ids")
    if not isinstance(observed_ids, list) or any(not isinstance(item, str) for item in observed_ids):
        raise AlbumServerContractError("ids in observed-ids.json must be a list of strings")
    if not observed_ids:
        raise AlbumServerContractError("Empty observations cannot pass")
    source = str(observed.get("identity_source") or "")
    raw = observed.get("raw_identifiers")
    if source != SERVER_SWITCH_OBSERVED_SOURCE:
        raise AlbumServerContractError("Observations assembled from the expected manifest cannot pass")
    if not isinstance(raw, list) or not raw or any(not isinstance(item, str) for item in raw):
        raise AlbumServerContractError("Observations assembled from the expected manifest cannot pass")
    joined = " ".join(raw)
    for item in observed_ids:
        if item not in joined:
            raise AlbumServerContractError("Observations assembled from the expected manifest cannot pass")
    assert_foreign_server_ids_absent(observed_ids, fixture_set)


def _require_named_png(evidence_dir: Path, filename: str, message: str) -> None:
    path = evidence_dir / filename
    if not path.is_file() or path.stat().st_size == 0:
        raise AlbumServerContractError(message)


def _require_server_switch_recording(evidence_dir: Path) -> None:
    path = evidence_dir / SERVER_SWITCH_RECORDING_FILE
    if not path.is_file() or path.stat().st_size == 0:
        raise AlbumServerContractError("A server switch requires a non-empty continuous recording")
    if b"moov" not in path.read_bytes():
        raise AlbumServerContractError("The server-switch recording was not finalized")


# Empty results only check the full screen and the main photo regions. top/upper/top_half are overlay strips,
# and the blue-gray gradient at the top of an empty result would be misread as A4.
EMPTY_RESULT_PHOTO_REGIONS = (
    "full",
    "center",
    "left",
    "right",
    "mid_left",
    "mid_right",
    "bottom_half",
)


def _empty_result_shows_fixture_photo(image_bytes: bytes) -> bool:
    import io

    from PIL import Image

    # Region classification tolerates decoding errors; unreadable evidence cannot prove an empty result.
    try:
        with Image.open(io.BytesIO(image_bytes)) as image:
            image.load()
    except (OSError, ValueError) as error:
        raise AlbumServerContractError("Unrecognizable input: empty-album result screenshot cannot be decoded") from error
    # Still identify photos: full screen plus main regions. The empty-result copy is no reason to skip
    # classification.
    regions = classify_display_regions(image_bytes)
    identities = [regions[name] for name in EMPTY_RESULT_PHOTO_REGIONS if name in regions]
    return any(item.status == "MATCH" and item.mark in MARKS for item in identities)


def _read_json(path: Path, name: str) -> dict[str, Any]:
    if not path.is_file():
        raise AlbumServerContractError(f"Missing {name}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise AlbumServerContractError(f"{name} is not JSON") from error
    if not isinstance(payload, dict):
        raise AlbumServerContractError(f"{name} must be an object")
    return payload


def build_xcodebuild_command(
    *,
    case: Mapping[str, str],
    destination: str,
    derived_data: Path,
    result_bundle: Path,
    evidence_dir: Path,
    server_url: str,
    server_url_b: str | None = None,
) -> list[str]:
    command = [
        "xcodebuild",
        "test",
        "-project",
        "immichSlides.xcodeproj",
        "-scheme",
        case["scheme"],
        "-testPlan",
        case["plan"],
        "-destination",
        destination,
        "-derivedDataPath",
        str(derived_data),
        "-resultBundlePath",
        str(result_bundle),
        "-parallel-testing-enabled",
        "NO",
        "-collect-test-diagnostics",
        "never",
        "-skip-testing:immichSlidesTests",
        f"-only-testing:{case['selector']}",
        f"STRICT_E2E_INPUT_SERVER_URL={server_url}",
        f"STRICT_E2E_INPUT_PUBLIC_KEY={'immichslides-public-e2e-wrong-key' if case['scenario'] == 'auth-401' else PUBLIC_API_KEY}",
        f"STRICT_E2E_INPUT_SCENARIO={case['scenario']}",
        f"STRICT_E2E_EVIDENCE_DIR={evidence_dir}",
        "STRICT_E2E_INPUT_FIXTURE_SET=a",
    ]
    if case["narrow"] == "server-switch":
        if not server_url_b:
            raise AlbumServerContractError("A server switch requires the B server URL")
        command.append(f"STRICT_E2E_INPUT_SERVER_URL_B={server_url_b}")
        command.append(f"STRICT_E2E_INPUT_SERVER_B_URL={server_url_b}")
    return command


def build_server_switch_runner_command(
    *,
    case: Mapping[str, str],
    destination: str,
    evidence_dir: Path,
) -> list[str]:
    suite = SERVER_SWITCH_SUITE_BY_PLATFORM.get(case["platform"])
    platform = SERVER_SWITCH_RUNNER_PLATFORM.get(case["platform"])
    if suite is None or platform is None:
        raise AlbumServerContractError("A server switch must use the suite runner with screen recording")
    return [
        "python3",
        "scripts/run_strict_e2e.py",
        "--platform",
        platform,
        "--destination",
        destination,
        "--evidence-dir",
        str(evidence_dir),
        "--suite",
        suite,
        "--fixture-set",
        "a",
    ]


def official_device_command(
    *,
    case: Mapping[str, str],
    destination: str,
    derived_data: Path,
    result_bundle: Path,
    evidence_dir: Path,
    server_url: str,
    server_url_b: str | None = None,
) -> list[str]:
    if case["narrow"] == "server-switch":
        return build_server_switch_runner_command(case=case, destination=destination, evidence_dir=evidence_dir)
    return build_xcodebuild_command(
        case=case,
        destination=destination,
        derived_data=derived_data,
        result_bundle=result_bundle,
        evidence_dir=evidence_dir,
        server_url=server_url,
        server_url_b=server_url_b,
    )
