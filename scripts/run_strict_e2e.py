#!/usr/bin/env python3
"""Start the public controlled service and run one strict E2E suite without injecting state into the app."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Callable, Mapping, Sequence, TextIO

from run_offline_unit_tests import (
    CommandError as OfflineCommandError,
    TestResultsSummary,
    parse_non_negative_int,
    read_official_test_results_summary,
)
from album_server_narrow_contract import (
    AlbumServerContractError,
    evaluate_album_empty_evidence,
    evaluate_server_switch_evidence,
)
from strict_e2e_filter_contract import (
    FILTER_VISUAL_SUITES,
    FilterContractError,
    evaluate_filter_visual_identity,
    write_member_manifest,
)
from strict_e2e_out_of_order_contract import (
    OUT_OF_ORDER_VISUAL_SUITES,
    OutOfOrderContractError,
    audit_runner_inputs,
    evaluate_out_of_order_identity,
)
from strict_e2e_p2_contract import (
    P2_CASES,
    RECORDING_FILE,
    RECORDING_TIMING_FILE,
    P2ContractError,
    p2_selector,
    read_xcresult_facts,
    require_official_execution,
    validate_raw_evidence,
)
from strict_e2e_photo_identity import (
    IdentityAssertionError,
    VISUAL_SUITES,
    evaluate_visual_identity,
)
from access_lifecycle_contract import logical_bytes_contain
from strict_e2e_server import PUBLIC_API_KEY, fixture_manifest


REPO_ROOT = Path(__file__).resolve().parent.parent
EXAMPLE_XCCONFIG = Path("Config/env.example.xcconfig")
TASK_XCCONFIG = Path("Config/env.xcconfig")
MIN_DATA_GIB = 80
# xcodebuild timeout for compile plus one UI test. Diagnostic collection is disabled.
XCODEBUILD_TIMEOUT_SECONDS = 300
# simctl writes Recording started only after processing the first frame; after SIGINT, wait for in-flight frames to write the moov atom.
RECORDING_START_TIMEOUT_SECONDS = 15
RECORDING_STOP_TIMEOUT_SECONDS = 30
WRONG_PUBLIC_API_KEY = "immichslides-public-e2e-wrong-key"
PRIVATE_RESULT_BUNDLE_ROOT = Path(tempfile.gettempdir()) / "immichSlides-strict-e2e-private"
RUNNER_SCENARIOS = ("normal", "auth-401", "html-200", "unreachable", "timeout", "out-of-order")
FORBIDDEN_EXACT_KEYS = {
    "IMMICH_TEST_SERVER_URL",
    "IMMICH_TEST_URL",
    "IMMICH_TEST_API_KEY",
}
PLATFORM_SETTINGS = {
    "ios": ("immichSlides-iOS", "StrictE2E-iOS", "testIOSStrictE2EConnectionSmoke"),
    "tvos": ("immichSlides-tvOS", "StrictE2E-tvOS", "testTVOSStrictE2EConnectionSmoke"),
}
IOS_FIRST_BATCH_SUITES = {
    "journey-a": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testFirstBootSetupSurvivesColdRelaunch",
    "journey-b": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testRandomModeReachesPlaybackWithCorrectControlState",
    "firstboot-failure": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testFirstBootFailureStaysOnFirstBoot",
    "pause-window": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testSinglePhotoOutgoingPauseWindowCapture",
    "pause-stage": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testRandomPlaybackPauseStageCapture",
}
# Run each person rule in a separate xcodebuild; official counts remain 1/0 per run and are combined at suite level.
FILTER_PERSON_SESSIONS = (
    {
        "name": "normal",
        "selector": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterPersonNormalMatch",
    },
    {
        "name": "conflict-normal",
        "selector": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterPersonConflictNormal",
    },
    {
        "name": "nofaces",
        "selector": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterPersonNoFaces",
    },
)
IOS_FILTER_SUITES = {
    "display-policy": "immichSlidesUITests/StrictE2EFilterIOSUITests/testSmartFillDisplayPolicyChangesMultiToSingle",
    "filter-album": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterAlbumTargetMembers",
    "filter-edit-switch": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom",
    "filter-empty": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterEmptySelectionCannotStart",
    "filter-person": FILTER_PERSON_SESSIONS[0]["selector"],
    "filter-switch": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterServerSwitchIsolation",
    "filter-vision": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterVisionSoloOnlyOnDevice",
    "filter-person-return": "immichSlidesUITests/StrictE2EFilterIOSUITests/testPersonSelectionStaysOnPersonPageAndReturnsToSummary",
    "filter-person-solo-persist": "immichSlidesUITests/StrictE2EFilterIOSUITests/testPersonSoloOnlyTogglePersistsAcrossReturn",
    "album-empty": "immichSlidesUITests/StrictE2EFilterIOSUITests/testTargetAlbumPlaysAndEmptyAlbumShowsEmptyResult",
    "server-switch-display": "immichSlidesUITests/StrictE2EFilterIOSUITests/testServerSwitchDropsOldFiltersAndDisplayPolicyAppliesImmediately",
}
TVOS_FLOW_SUITES = {
    "tvos-flow": "immichSlidesUITests/StrictE2ETVOSFlowUITests/testTVOSFirstBootModeSelectionAndCorePlayback",
    "tvos-n1-cold": "immichSlidesUITests/StrictE2ETVOSFlowUITests/testTVOSFirstBootSaveAndConfiguredColdLaunch",
    "tvos-firstboot-failure": "immichSlidesUITests/StrictE2ETVOSFlowUITests/testTVOSAlbumServerFirstBootFailureHTML200",
}
# The directional-wake check lives in the tvOS visual test class and only needs the standard strict inputs.
TVOS_CONTROL_SUITES = {
    "tvos-directional-wake": "immichSlidesUITests/FilterSummaryTVOSVisualUITests/testTVOSSlideShowControlBarCanWakeByAnyDirectionalPress",
}
TVOS_FILTER_SUITES = {
    "tvos-album": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSTargetAlbumPlaybackAndEmptyStart",
    "tvos-display-policy": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSSmartFillDisplayPolicyChangesMultiToSingle",
    "tvos-edit-switch": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom",
    "tvos-person": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSPersonRules",
    "tvos-switch": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSServerSwitchIsolation",
    "tvos-album-empty": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSTargetAlbumPlaysAndEmptyAlbumShowsEmptyResult",
    "tvos-server-switch-display": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSServerSwitchDropsOldFiltersAndDisplayPolicyAppliesImmediately",
}
IOS_LATE_IMAGE_SUITES = {
    "late-image": "immichSlidesUITests/StrictE2ELateImageIOSUITests/testLateImageKeepsCurrentSceneAfterLateRequest",
}
TVOS_LATE_IMAGE_SUITES = {
    "late-image": "immichSlidesUITests/StrictE2ELateImageTVOSUITests/testTVOSLateImageDoesNotFlashBack",
}
IOS_CASES = {
    "settings": "immichSlidesUITests/AccessLifecycleIOSUITests/testSettingsPersistAfterTerminateLaunch",
    "pause": "immichSlidesUITests/AccessLifecycleIOSUITests/testPauseNextContinueVisibleTiming",
    "background": "immichSlidesUITests/AccessLifecycleIOSUITests/testBackgroundReturnPreservesScene",
    "first-wake": "immichSlidesUITests/AccessLifecycleIOSUITests/testFirstWakeRequiresHiddenControlsAndPreservesVisibleScene",
}
TVOS_CASES = {
    "settings": "immichSlidesUITests/AccessLifecycleTVOSUITests/testTVOSSettingsPersistAfterTerminateLaunch",
    "pause": "immichSlidesUITests/AccessLifecycleTVOSUITests/testTVOSPauseNextContinueVisibleTiming",
    "background": "immichSlidesUITests/AccessLifecycleTVOSUITests/testTVOSBackgroundReturnPreservesScene",
}
LIFECYCLE_SUITES = {
    f"{platform}-lifecycle-{case}": (platform, selector)
    for platform, cases in (("ios", IOS_CASES), ("tvos", TVOS_CASES))
    for case, selector in cases.items()
}
RUNNER_SUITES = (
    "smoke",
    *LIFECYCLE_SUITES,
    *IOS_FIRST_BATCH_SUITES,
    *IOS_FILTER_SUITES,
    *TVOS_FLOW_SUITES,
    *TVOS_CONTROL_SUITES,
    *TVOS_FILTER_SUITES,
    *IOS_LATE_IMAGE_SUITES,
    *TVOS_LATE_IMAGE_SUITES,
    *P2_CASES,
)
FAILURE_SCENARIOS = ("auth-401", "html-200", "unreachable", "timeout")
SUCCESS_SUITES = (
    "smoke",
    *LIFECYCLE_SUITES,
    "journey-a",
    "journey-b",
    "pause-window",
    "pause-stage",
    "tvos-flow",
    "tvos-directional-wake",
    *IOS_FILTER_SUITES,
    "tvos-album",
    "tvos-display-policy",
    "tvos-edit-switch",
    "tvos-person",
    "tvos-switch",
    "album-empty",
    "server-switch-display",
    "tvos-n1-cold",
    "tvos-album-empty",
    "tvos-server-switch-display",
    *P2_CASES,
)
DUAL_SERVER_SUITES = ("filter-switch", "tvos-switch", "server-switch-display", "tvos-server-switch-display")
ALBUM_EMPTY_SUITES = ("album-empty", "tvos-album-empty")
SERVER_SWITCH_DISPLAY_SUITES = ("server-switch-display", "tvos-server-switch-display")
DISPLAY_POLICY_SUITES = ("display-policy", "tvos-display-policy")
SETTINGS_RESUME_SUITES = (
    *LIFECYCLE_SUITES,
    "display-policy",
    "filter-edit-switch",
    "filter-switch",
    "tvos-display-policy",
    "tvos-edit-switch",
    "tvos-switch",
)
# Manifest IDs written into case-manifest.json. Each ID names coverage already
# implemented by the mapped XCTest selector; they are not a separate spec.
# E2E-P0-01: first-boot server setup (journey-a/b, firstboot-failure).
# E2E-P0-02: first-boot setup survives cold relaunch (journey-a).
# E2E-P0-03: random/core playback reached (journey-b, tvos-flow).
# E2E-P0-04: album filter members, empty album, or album edit-switch.
# E2E-P0-05: person filter rules, including vision soloOnly.
# E2E-P0-06: server-switch isolation.
# E2E-P0-07: late image keeps the current scene.
# E2E-P0-08 / E2E-P0-09: playback control state on journey-b and tvos-flow.
# N1: tvOS first-boot save and configured cold launch.
CASE_E2E_IDS = {
    **{suite: [f"access-lifecycle-{suite}"] for suite in LIFECYCLE_SUITES},
    "smoke": ["connection-smoke"],
    "journey-a": ["E2E-P0-01", "E2E-P0-02"],
    "journey-b": ["E2E-P0-01", "E2E-P0-03", "E2E-P0-08", "E2E-P0-09"],
    "firstboot-failure": ["E2E-P0-01"],
    "pause-window": [],
    "pause-stage": [],
    "tvos-flow": ["E2E-P0-03", "E2E-P0-08", "E2E-P0-09"],
    "display-policy": ["display-policy"],
    "filter-album": ["E2E-P0-04"],
    "filter-edit-switch": ["E2E-P0-04"],
    "filter-empty": ["E2E-P0-04"],
    "filter-person": ["E2E-P0-05"],
    "filter-switch": ["E2E-P0-06"],
    "filter-vision": ["E2E-P0-05"],
    "tvos-album": ["E2E-P0-04"],
    "tvos-display-policy": ["display-policy"],
    "tvos-edit-switch": ["E2E-P0-04"],
    "tvos-person": ["E2E-P0-05"],
    "tvos-switch": ["E2E-P0-06"],
    "album-empty": ["album-empty"],
    "server-switch-display": ["server-switch"],
    "tvos-n1-cold": ["N1"],
    "tvos-album-empty": ["album-empty"],
    "tvos-server-switch-display": ["server-switch"],
    "tvos-firstboot-failure": ["fail-html-200"],
    "late-image": ["E2E-P0-07"],
    **{suite: list(case.e2e_ids) for suite, case in P2_CASES.items()},
}


class CommandError(Exception):
    def __init__(self, message: str, code: int = 2) -> None:
        super().__init__(message)
        self.code = code


def parse_xcconfig(content: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//") or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def prepare_task_xcconfig(example_path: Path, destination_path: Path) -> dict[str, str]:
    if destination_path.exists():
        raise CommandError("Task env.xcconfig already exists; strict E2E refuses to start to avoid reading or overwriting private configuration.")
    if not example_path.is_file():
        raise CommandError("The version-controlled env.example.xcconfig is missing.")
    content = example_path.read_text(encoding="utf-8")
    values = parse_xcconfig(content)
    required_flags = ("ENABLE_DEBUG_AUTO_SERVER", "ENABLE_DEBUG_FILL_APIKEY_BUTTON")
    if any(values.get(key) != "0" for key in required_flags):
        raise CommandError("Both Debug switches in env.example.xcconfig must be 0.")
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    destination_path.write_text(content, encoding="utf-8")
    copied_values = parse_xcconfig(destination_path.read_text(encoding="utf-8"))
    if any(copied_values.get(key) != "0" for key in required_flags):
        destination_path.unlink(missing_ok=True)
        raise CommandError("Failed to read back task env.xcconfig, or a Debug switch is not 0.")
    return {
        "source_sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
        **{key: copied_values[key] for key in required_flags},
    }


def cleanup_task_xcconfig(example_path: Path, destination_path: Path) -> None:
    if not destination_path.exists():
        return
    if not example_path.is_file() or destination_path.read_bytes() != example_path.read_bytes():
        raise CommandError("Task env.xcconfig was modified; keeping the file and stopping to avoid deleting configuration from another run.")
    destination_path.unlink()


def _is_forbidden_key(key: str) -> bool:
    return key.startswith("UI_TEST_") or key in FORBIDDEN_EXACT_KEYS


def validate_app_launch_environment(environment: Mapping[str, str]) -> None:
    forbidden = sorted(key for key in environment if _is_forbidden_key(key))
    if forbidden:
        raise CommandError("Forbidden keys found in the App launchEnvironment: " + ", ".join(forbidden))


def prepare_evidence_directory(evidence_dir: Path) -> None:
    evidence_dir.mkdir(parents=True, exist_ok=True)
    if any(evidence_dir.iterdir()):
        raise CommandError("The evidence directory is not empty; strict E2E refuses to start to avoid overwriting or mixing files.")
    (evidence_dir / ".strict-e2e-run.json").write_text(
        json.dumps({"format": 1}, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def scenario_settings(scenario: str) -> tuple[str, str, bool]:
    if scenario not in RUNNER_SCENARIOS:
        raise CommandError(f"Unknown strict E2E scenario: {scenario}.")
    if scenario == "auth-401":
        return "normal", WRONG_PUBLIC_API_KEY, True
    if scenario == "unreachable":
        return "normal", PUBLIC_API_KEY, False
    return scenario, PUBLIC_API_KEY, True


def validate_suite_scenario(suite: str, scenario: str) -> None:
    if suite == "firstboot-failure":
        if scenario not in FAILURE_SCENARIOS:
            raise CommandError(f"Invalid combination: --suite {suite} cannot be used with --scenario {scenario}.")
        return
    if suite == "tvos-firstboot-failure":
        if scenario != "html-200":
            raise CommandError(f"Invalid combination: --suite {suite} cannot be used with --scenario {scenario}.")
        return
    if suite == "late-image":
        if scenario != "out-of-order":
            raise CommandError(f"Invalid combination: --suite {suite} cannot be used with --scenario {scenario}.")
        return
    if suite in SUCCESS_SUITES and scenario != "normal":
        raise CommandError(f"Invalid combination: --suite {suite} cannot be used with --scenario {scenario}.")
    if suite not in RUNNER_SUITES:
        raise CommandError(f"Unknown strict E2E suite: {suite}.")
    if scenario not in RUNNER_SCENARIOS:
        raise CommandError(f"Unknown strict E2E scenario: {scenario}.")


def validate_suite_fixture(suite: str, fixture_set: str) -> None:
    if suite in (*DISPLAY_POLICY_SUITES, *LIFECYCLE_SUITES) and fixture_set != "a":
        raise CommandError(f"{suite} must use public fixture A; data from different servers cannot be mixed.")


def read_source_sha(repo_root: Path) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repo_root), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    sha = completed.stdout.strip()
    if completed.returncode != 0 or len(sha) != 40 or any(char not in "0123456789abcdef" for char in sha.lower()):
        raise CommandError("Could not read the current source SHA.")
    return sha


def read_source_dirty_paths(repo_root: Path) -> list[str]:
    completed = subprocess.run(
        ["git", "-C", str(repo_root), "status", "--porcelain=v1", "--untracked-files=all"],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise CommandError("Could not read the current working tree status.")
    return [line for line in completed.stdout.splitlines() if line]


def write_case_manifest(evidence_dir: Path, payload: Mapping[str, object]) -> None:
    (evidence_dir / "case-manifest.json").write_text(
        json.dumps(dict(payload), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_fixture_artifacts(evidence_dir: Path, fixture_set: str) -> dict[str, object]:
    fixture_payload = fixture_manifest(fixture_set)
    (evidence_dir / "fixture-manifest.json").write_text(
        json.dumps(fixture_payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_member_manifest(evidence_dir / "member-manifest.json", fixture_set)
    return fixture_payload


def reserve_unreachable_server_url() -> tuple[str, socket.socket]:
    reservation = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        reservation.bind(("127.0.0.1", 0))
        host, port = reservation.getsockname()
        return f"http://{host}:{port}/api", reservation
    except Exception:
        reservation.close()
        raise


def write_sensitive_scan(evidence_dir: Path, sensitive_values: list[str]) -> None:
    values = [value for value in sensitive_values if value]
    matched_files: list[str] = []

    def raise_walk_error(error: OSError) -> None:
        raise error

    try:
        paths = sorted(
            Path(root) / filename
            for root, _, filenames in os.walk(evidence_dir, onerror=raise_walk_error)
            for filename in filenames
        )
    except OSError as error:
        raise CommandError(f"The redaction scan could not traverse the evidence directory: {error}") from error
    for path in paths:
        if not path.is_file():
            continue
        try:
            data = path.read_bytes()
        except OSError as error:
            raise CommandError(f"The redaction scan could not read {path.relative_to(evidence_dir)}: {error}") from error
        if logical_bytes_contain(data, values):
            matched_files.append(str(path.relative_to(evidence_dir)))
    payload = {
        "checked_key_names": ["STRICT_E2E_INPUT_PUBLIC_KEY"],
        "matched_files": matched_files,
        "result": "PASS" if not matched_files else "FAIL",
    }
    try:
        (evidence_dir / "sensitive-scan.json").write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except OSError as error:
        raise CommandError(f"Could not write the redaction scan results: {error}") from error
    if matched_files:
        raise CommandError("The evidence redaction scan found API Key values: " + ", ".join(matched_files))


def prepare_private_result_bundle_path(suite: str) -> Path:
    PRIVATE_RESULT_BUNDLE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    holding_dir = Path(tempfile.mkdtemp(prefix=f"{suite}-", dir=PRIVATE_RESULT_BUNDLE_ROOT))
    return holding_dir / result_bundle_name(suite)


def run_cleanup_actions(actions: list[tuple[str, Callable[[], None]]]) -> list[str]:
    failures: list[str] = []
    for name, action in actions:
        try:
            action()
        except Exception as error:
            failures.append(f"{name}: {type(error).__name__}: {error}")
    return failures


def choose_exit_code(primary_exit_code: int, cleanup_failures: list[str]) -> int:
    if primary_exit_code != 0:
        return primary_exit_code
    return 2 if cleanup_failures else 0


def make_test_environment(
    source: Mapping[str, str],
    *,
    server_url: str,
    public_key: str,
    scenario: str = "normal",
    server_url_b: str | None = None,
    server_b_url: str | None = None,
) -> dict[str, str]:
    environment = {key: value for key, value in source.items() if not _is_forbidden_key(key)}
    environment["STRICT_E2E_INPUT_SERVER_URL"] = server_url
    environment["STRICT_E2E_INPUT_PUBLIC_KEY"] = public_key
    environment["STRICT_E2E_INPUT_SCENARIO"] = scenario
    peer = server_url_b or server_b_url
    if peer:
        environment["STRICT_E2E_INPUT_SERVER_URL_B"] = peer
        environment["STRICT_E2E_INPUT_SERVER_B_URL"] = peer
    return environment


def result_bundle_name(suite: str) -> str:
    if suite not in RUNNER_SUITES:
        raise CommandError(f"Unknown strict E2E suite: {suite}.")
    return f"strict-{suite}.xcresult"


def resolve_suite_selector(platform: str, suite: str) -> str:
    settings = PLATFORM_SETTINGS.get(platform)
    if settings is None:
        raise CommandError("platform must be ios or tvos.")
    if suite in LIFECYCLE_SUITES:
        required_platform, selector = LIFECYCLE_SUITES[suite]
        if platform != required_platform:
            raise CommandError(f"{suite} can only run on the {required_platform} platform.")
        return selector
    if suite in P2_CASES:
        try:
            return p2_selector(suite, platform)
        except P2ContractError as error:
            raise CommandError(str(error)) from error
    if suite == "smoke":
        _scheme, _test_plan, test_method = settings
        return f"immichSlidesUITests/StrictE2ESmokeUITests/{test_method}"
    tvos_selector = (
        TVOS_FLOW_SUITES.get(suite) or TVOS_CONTROL_SUITES.get(suite) or TVOS_FILTER_SUITES.get(suite)
    )
    if tvos_selector is not None:
        if platform != "tvos":
            raise CommandError("The tvOS flow can only run on the tvos platform.")
        return tvos_selector
    if platform == "tvos":
        late_selector = TVOS_LATE_IMAGE_SUITES.get(suite)
        if late_selector is not None:
            return late_selector
    selector = (
        IOS_FIRST_BATCH_SUITES.get(suite)
        or IOS_FILTER_SUITES.get(suite)
        or IOS_LATE_IMAGE_SUITES.get(suite)
    )
    if selector is None:
        raise CommandError(f"Unknown strict E2E suite: {suite}.")
    if platform != "ios":
        raise CommandError("The iPhone/iPad journey can only run on the ios platform.")
    return selector


def merge_official_summaries(summaries: Sequence[TestResultsSummary]) -> dict[str, object]:
    if not summaries:
        raise CommandError("Official test counts are missing; cannot merge.")
    return {
        "totalTestCount": sum(item.total_test_count for item in summaries),
        "passedTests": sum(item.passed_tests for item in summaries),
        "failedTests": sum(item.failed_tests for item in summaries),
        "skippedTests": sum(item.skipped_tests for item in summaries),
        "result": summaries[-1].result if all(item.result.lower() == "passed" for item in summaries) else "failed",
    }


def build_xcodebuild_command(
    *,
    repo_root: Path,
    platform: str,
    destination: str,
    derived_data_path: Path,
    result_bundle_path: Path,
    server_url: str,
    suite: str = "smoke",
    scenario: str = "normal",
    evidence_dir: Path | None = None,
    server_url_b: str | None = None,
    server_b_url: str | None = None,
    only_testing: str | None = None,
) -> list[str]:
    settings = PLATFORM_SETTINGS.get(platform)
    if settings is None:
        raise CommandError("platform must be ios or tvos.")
    scheme, test_plan, _test_method = settings
    uses_settings_resume = suite in SETTINGS_RESUME_SUITES
    if uses_settings_resume:
        scheme = (
            "immichSlides-iOS-settings-resume"
            if platform == "ios"
            else "immichSlides-tvOS-settings-resume"
        )
    selector = only_testing or resolve_suite_selector(platform, suite)
    command = [
        "xcodebuild",
        "-project",
        str(repo_root / "immichSlides.xcodeproj"),
        "-scheme",
        scheme,
        "-testPlan",
        test_plan,
        *(["-configuration", "Release"] if uses_settings_resume else []),
        "-destination",
        destination,
        "-derivedDataPath",
        str(derived_data_path),
        "-resultBundlePath",
        str(result_bundle_path),
        "-collect-test-diagnostics",
        "never",
        f"STRICT_E2E_INPUT_SERVER_URL={server_url}",
        f"STRICT_E2E_INPUT_SCENARIO={scenario}",
    ]
    if uses_settings_resume:
        command.extend(["-parallel-testing-enabled", "NO", "-skip-testing:immichSlidesTests"])
    if evidence_dir is not None:
        command.append(f"STRICT_E2E_EVIDENCE_DIR={evidence_dir}")
    peer = server_url_b or server_b_url
    if peer:
        command.append(f"STRICT_E2E_INPUT_SERVER_URL_B={peer}")
        command.append(f"STRICT_E2E_INPUT_SERVER_B_URL={peer}")
    command.extend([f"-only-testing:{selector}", "test"])
    return command


def data_available_gib() -> float:
    return shutil.disk_usage("/System/Volumes/Data").free / (1024**3)


def ensure_disk_for_xcodebuild(
    data_available_gib: Callable[[], float], min_free_gib: int = MIN_DATA_GIB
) -> None:
    available = data_available_gib()
    if available < min_free_gib:
        raise CommandError(
            f"Available space on /System/Volumes/Data is {available:.1f} GiB, below the "
            f"{min_free_gib} GiB threshold configured by --min-free-gib; stopping Xcode tests."
        )


def _is_already_booted(stderr: str) -> bool:
    text = stderr.lower()
    return "current state: booted" in text or "already booted" in text


def reset_simulator_app(simulator_udid: str, bundle_id: str = "com.331works.immichSlides") -> str:
    # The fixed sleep waits for simctl to release the container lock; Booted is not a boot failure, but a second uninstall failure must stop the run.
    lines = [f"simulator_id={simulator_udid}"]
    boot = subprocess.run(
        ["xcrun", "simctl", "boot", simulator_udid],
        capture_output=True,
        text=True,
        check=False,
    )
    lines.append(f"boot_exit={boot.returncode}")
    if boot.stderr.strip():
        lines.append(f"boot_stderr={boot.stderr.strip()}")
    if boot.returncode != 0 and not _is_already_booted(boot.stderr):
        raise CommandError("Simulator boot failed; cannot continue with a clean install.\n" + "\n".join(lines))
    bootstatus = subprocess.run(
        ["xcrun", "simctl", "bootstatus", simulator_udid, "-b"],
        capture_output=True,
        text=True,
        check=False,
    )
    lines.append(f"bootstatus_exit={bootstatus.returncode}")
    if bootstatus.returncode != 0:
        if bootstatus.stderr.strip():
            lines.append(f"bootstatus_stderr={bootstatus.stderr.strip()}")
        raise CommandError("Simulator did not become available; cannot continue with a clean install.\n" + "\n".join(lines))
    terminate = subprocess.run(
        ["xcrun", "simctl", "terminate", simulator_udid, bundle_id],
        capture_output=True,
        text=True,
        check=False,
    )
    lines.append(f"terminate_exit={terminate.returncode}")
    uninstall = subprocess.run(
        ["xcrun", "simctl", "uninstall", simulator_udid, bundle_id],
        capture_output=True,
        text=True,
        check=False,
    )
    lines.append(f"uninstall_exit={uninstall.returncode}")
    if uninstall.returncode != 0:
        time.sleep(1)
        retry = subprocess.run(
            ["xcrun", "simctl", "uninstall", simulator_udid, bundle_id],
            capture_output=True,
            text=True,
            check=False,
        )
        lines.append(f"uninstall_retry_exit={retry.returncode}")
        if retry.stderr.strip():
            lines.append(f"uninstall_retry_stderr={retry.stderr.strip()}")
        if retry.returncode != 0:
            raise CommandError("Second uninstall failed; cannot continue with a clean install.\n" + "\n".join(lines))
    if uninstall.stderr.strip():
        lines.append(f"uninstall_stderr={uninstall.stderr.strip()}")
    time.sleep(1)
    container = simulator_app_container(simulator_udid, bundle_id)
    if container:
        lines.append(f"app_container={container}")
        raise CommandError(
            "App container is still accessible after uninstall; cannot continue with a clean install.\n" + "\n".join(lines)
        )
    lines.append("app_container=absent")
    return "\n".join(lines) + "\n"


def simulator_app_container(simulator_udid: str, bundle_id: str) -> str | None:
    completed = subprocess.run(
        ["xcrun", "simctl", "get_app_container", simulator_udid, bundle_id],
        capture_output=True,
        text=True,
        check=False,
    )
    path = completed.stdout.strip()
    if completed.returncode == 0 and path:
        return path
    if completed.returncode == 2:
        return None
    detail = completed.stderr.strip() or completed.stdout.strip()
    message = f"Could not determine whether the App container exists (simctl get_app_container exit {completed.returncode})."
    if detail:
        message += " " + detail
    raise CommandError(message)


def destination_udid(destination: str) -> str:
    for component in destination.split(","):
        key, separator, value = component.strip().partition("=")
        if separator and key == "id" and value:
            return value
    raise CommandError("destination must explicitly include a Simulator id.")


def wait_for_service(ready_path: Path, process: subprocess.Popen[bytes]) -> tuple[str, int]:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise CommandError(f"Test service exited early with exit {process.returncode}.")
        if ready_path.is_file():
            try:
                payload = json.loads(ready_path.read_text(encoding="utf-8"))
                if payload.get("pid") != process.pid:
                    raise CommandError("The PID in the test service ready file does not match the started child process.")
                host = payload["host"]
                port = payload["port"]
                with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=1) as response:
                    if response.status == 200:
                        return str(host), int(port)
            except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
                pass
        time.sleep(0.05)
    raise CommandError("Test service health check timed out.")


def stop_exact_process(process: subprocess.Popen[bytes]) -> int:
    if process.poll() is None:
        process.terminate()
        try:
            return process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    return process.wait(timeout=5)


def start_screen_recording(
    simulator_udid: str, video_path: Path, log_path: Path
) -> tuple[subprocess.Popen[bytes], float]:
    with log_path.open("wb") as log_file:
        process = subprocess.Popen(
            ["xcrun", "simctl", "io", simulator_udid, "recordVideo", "--codec=h264", "--force", str(video_path)],
            stdout=log_file,
            stderr=subprocess.STDOUT,
        )
    deadline = time.monotonic() + RECORDING_START_TIMEOUT_SECONDS
    did_start = False
    try:
        while True:
            if b"Recording started" in log_path.read_bytes():
                did_start = True
                return process, time.time()
            if process.poll() is not None:
                raise CommandError(f"Simulator recording exited early with exit {process.returncode}.")
            if time.monotonic() >= deadline:
                raise CommandError(f"Simulator recording did not start within {RECORDING_START_TIMEOUT_SECONDS}s; continuous recording is unavailable.")
            time.sleep(0.1)
    finally:
        if not did_start:
            stop_exact_process(process)


def stop_screen_recording(process: subprocess.Popen[bytes]) -> int:
    if process.poll() is not None:
        raise CommandError(f"Simulator recording exited before the test finished (exit {process.returncode}); the recording is not continuous.")
    process.send_signal(signal.SIGINT)
    try:
        return process.wait(timeout=RECORDING_STOP_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        process.kill()
        process.wait(timeout=5)
        raise CommandError("Simulator recording did not finish after SIGINT; the recording is unreliable.") from error


def audit_out_of_order_runner_inputs(
    *,
    fixture_set: str,
    observed_hash: str,
    service_log: str,
    server_url: str,
) -> dict[str, object]:
    # Promote input audit failures to runner failures in out-of-order scenarios to avoid silently continuing.
    try:
        return audit_runner_inputs(
            fixture_set=fixture_set,
            observed_hash=observed_hash,
            service_log=service_log,
            server_url=server_url,
        )
    except OutOfOrderContractError as error:
        raise CommandError(str(error), code=2) from error


def require_visual_identity(evidence_dir: Path, suite: str) -> dict[str, object]:
    if suite in OUT_OF_ORDER_VISUAL_SUITES:
        try:
            payload = evaluate_out_of_order_identity(evidence_dir)
        except OutOfOrderContractError as error:
            failed = {"verdict": "FAIL", "suite": suite, "error": str(error)}
            _write_visual_runner_report(evidence_dir, failed)
            raise CommandError(f"Visual assertion failed; cannot mark SUCCESS: {error}", code=2) from error
        if payload.get("verdict") != "PASS":
            _write_visual_runner_report(evidence_dir, payload)
            raise CommandError("Visual assertion did not pass; cannot mark SUCCESS.", code=2)
        _write_visual_runner_report(evidence_dir, payload)
        return payload
    if suite in ALBUM_EMPTY_SUITES:
        try:
            payload = evaluate_album_empty_evidence(evidence_dir)
        except (AlbumServerContractError, FilterContractError) as error:
            failed = {"verdict": "FAIL", "suite": suite, "error": str(error)}
            _write_visual_runner_report(evidence_dir, failed)
            raise CommandError(f"Visual assertion failed; cannot mark SUCCESS: {error}", code=2) from error
        if payload.get("verdict") != "PASS":
            _write_visual_runner_report(evidence_dir, payload)
            raise CommandError("Visual assertion did not pass; cannot mark SUCCESS.", code=2)
        _write_visual_runner_report(evidence_dir, payload)
        return payload
    if suite in SERVER_SWITCH_DISPLAY_SUITES:
        try:
            payload = evaluate_server_switch_evidence(evidence_dir)
        except (AlbumServerContractError, FilterContractError) as error:
            failed = {"verdict": "FAIL", "suite": suite, "error": str(error)}
            _write_visual_runner_report(evidence_dir, failed)
            raise CommandError(f"Visual assertion failed; cannot mark SUCCESS: {error}", code=2) from error
        if payload.get("verdict") != "PASS":
            _write_visual_runner_report(evidence_dir, payload)
            raise CommandError("Visual assertion did not pass; cannot mark SUCCESS.", code=2)
        _write_visual_runner_report(evidence_dir, payload)
        return payload
    if suite in FILTER_VISUAL_SUITES:
        try:
            payload = evaluate_filter_visual_identity(evidence_dir, suite)
        except FilterContractError as error:
            failed = {"verdict": "FAIL", "suite": suite, "error": str(error)}
            _write_visual_runner_report(evidence_dir, failed)
            raise CommandError(f"Visual assertion failed; cannot mark SUCCESS: {error}", code=2) from error
        if payload.get("verdict") == "PARTIAL" and suite == "tvos-person":
            vision = payload.get("vision") if isinstance(payload.get("vision"), dict) else {}
            if vision.get("verdict") == "UNVERIFIED":
                _write_visual_runner_report(evidence_dir, payload)
                return payload
        allowed = {"UNVERIFIED", "BLOCKED_ENV", "PASS"} if suite == "filter-vision" else {"PASS"}
        if payload.get("verdict") not in allowed:
            _write_visual_runner_report(evidence_dir, payload)
            raise CommandError("Visual assertion did not pass; cannot mark SUCCESS.", code=2)
        if suite == "filter-vision" and payload.get("verdict") == "PASS" and payload.get("environment") != "device":
            _write_visual_runner_report(evidence_dir, payload)
            raise CommandError("Simulator Vision cannot be marked PASS.", code=2)
        _write_visual_runner_report(evidence_dir, payload)
        return payload
    if suite not in VISUAL_SUITES:
        payload = {"verdict": "NOT_REQUIRED", "suite": suite}
        _write_visual_runner_report(evidence_dir, payload)
        return payload
    try:
        payload = evaluate_visual_identity(evidence_dir, suite)
    except IdentityAssertionError as error:
        failed = {"verdict": "FAIL", "suite": suite, "error": str(error)}
        _write_visual_runner_report(evidence_dir, failed)
        raise CommandError(f"Visual assertion failed; cannot mark SUCCESS: {error}", code=2) from error
    if payload.get("verdict") != "PASS":
        _write_visual_runner_report(evidence_dir, payload)
        raise CommandError("Visual assertion did not pass; cannot mark SUCCESS.", code=2)
    _write_visual_runner_report(evidence_dir, payload)
    return payload


def require_p2_evidence(
    evidence_dir: Path,
    *,
    suite: str,
    platform: str,
    simulator_udid: str,
    fixture_set: str,
    result_bundle_path: Path,
) -> dict[str, object]:
    try:
        execution = require_official_execution(
            read_xcresult_facts(result_bundle_path),
            suite=suite,
            platform=platform,
            simulator_udid=simulator_udid,
        )
        payload = validate_raw_evidence(evidence_dir, suite, fixture_set)
    except P2ContractError as error:
        _write_visual_runner_report(evidence_dir, {"verdict": "FAIL", "suite": suite, "error": str(error)})
        raise CommandError(f"P2 raw evidence is incomplete; cannot mark SUCCESS: {error}", code=2) from error
    payload["execution"] = execution
    _write_visual_runner_report(evidence_dir, payload)
    return payload


def _write_visual_runner_report(evidence_dir: Path, payload: Mapping[str, object]) -> None:
    (evidence_dir / "visual-identity-runner.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def require_official_single_pass(summary: TestResultsSummary) -> None:
    if (
        summary.total_test_count != 1
        or summary.passed_tests != 1
        or summary.failed_tests != 0
        or summary.skipped_tests != 0
        or summary.result.lower() != "passed"
    ):
        raise CommandError(
            "strict E2E official counts must be total=1, passed=1, failed=0, skipped=0; "
            f"actual total={summary.total_test_count} passed={summary.passed_tests} "
            f"failed={summary.failed_tests} skipped={summary.skipped_tests} result={summary.result}."
        )


def run_command(command: list[str], *, cwd: Path, environment: Mapping[str, str], log_path: Path) -> int:
    with log_path.open("w", encoding="utf-8") as log_file:
        try:
            completed = subprocess.run(
                command,
                cwd=cwd,
                env=dict(environment),
                stdout=log_file,
                stderr=subprocess.STDOUT,
                check=False,
                timeout=XCODEBUILD_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            raise CommandError(
                f"xcodebuild timed out after {XCODEBUILD_TIMEOUT_SECONDS}s without exiting.",
                code=2,
            ) from error
    return completed.returncode


def main(argv: list[str] | None = None, stdout: TextIO | None = None, stderr: TextIO | None = None) -> int:
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=sorted(PLATFORM_SETTINGS))
    parser.add_argument("--destination", required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--fixture-set", choices=("a", "b"), default="a")
    parser.add_argument("--scenario", choices=RUNNER_SCENARIOS, default="normal")
    parser.add_argument("--suite", choices=RUNNER_SUITES, default="smoke")
    parser.add_argument(
        "--min-free-gib",
        type=parse_non_negative_int,
        default=MIN_DATA_GIB,
        metavar="N",
        help=f"minimum free GiB required before xcodebuild (default: {MIN_DATA_GIB})",
    )
    arguments = parser.parse_args(argv)
    try:
        validate_suite_scenario(arguments.suite, arguments.scenario)
        validate_suite_fixture(arguments.suite, arguments.fixture_set)
        if arguments.suite in P2_CASES or arguments.suite in LIFECYCLE_SUITES:
            resolve_suite_selector(arguments.platform, arguments.suite)
    except CommandError as error:
        print(str(error), file=stderr)
        return error.code

    config_path = REPO_ROOT / TASK_XCCONFIG
    did_create_config = False
    owns_evidence_directory = False
    service_process: subprocess.Popen[bytes] | None = None
    service_process_b: subprocess.Popen[bytes] | None = None
    recording_process: subprocess.Popen[bytes] | None = None
    unreachable_reservation: socket.socket | None = None
    server_url_b: str | None = None
    service_log_b_path: Path | None = None
    derived_data_path = arguments.evidence_dir / "DerivedData"
    primary_exit_code = 0
    cleanup_failures: list[str] = []
    case_manifest: dict[str, object] | None = None
    result_bundle_path: Path | None = None
    private_result_bundle: Path | None = None
    official_tests_digest: str | None = None
    try:
        ensure_disk_for_xcodebuild(data_available_gib, arguments.min_free_gib)
        if "Simulator" not in arguments.destination:
            raise CommandError("strict E2E only accepts Simulator destinations.")
        simulator_udid = destination_udid(arguments.destination)
        prepare_evidence_directory(arguments.evidence_dir)
        owns_evidence_directory = True
        result_bundle_path = (
            prepare_private_result_bundle_path(arguments.suite)
            if arguments.suite in P2_CASES
            else arguments.evidence_dir / result_bundle_name(arguments.suite)
        )
        case_manifest = {
            "source_sha": read_source_sha(REPO_ROOT),
            "platform": arguments.platform,
            "destination": arguments.destination,
            "os": "iOS Simulator" if arguments.platform == "ios" else "tvOS Simulator",
            "suite": arguments.suite,
            "scenario": arguments.scenario,
            "fixture_set": arguments.fixture_set,
            "e2e_ids": CASE_E2E_IDS.get(arguments.suite, []),
            "human_review": "NOT_RUN",
            "result": "RUNNING",
        }
        if arguments.suite in P2_CASES:
            case_manifest["source_dirty_paths"] = read_source_dirty_paths(REPO_ROOT)
        write_case_manifest(arguments.evidence_dir, case_manifest)

        xcconfig_audit = prepare_task_xcconfig(REPO_ROOT / EXAMPLE_XCCONFIG, config_path)
        did_create_config = True
        (arguments.evidence_dir / "xcconfig-audit.json").write_text(
            json.dumps(xcconfig_audit, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        validate_app_launch_environment({})
        (arguments.evidence_dir / "app-launch-environment-audit.json").write_text(
            json.dumps({"forbidden_keys_present": [], "launch_environment_keys": []}, indent=2) + "\n",
            encoding="utf-8",
        )

        for command in (["xcodebuild", "-checkFirstLaunchStatus"], ["xcodebuild", "-version"]):
            completed = subprocess.run(command, capture_output=True, text=True, check=False)
            if completed.returncode != 0:
                raise CommandError(f"{' '.join(command)} failed with exit {completed.returncode}.")
            with (arguments.evidence_dir / "xcode-environment.log").open("a", encoding="utf-8") as log:
                log.write(f"$ {shlex.join(command)}\n{completed.stdout}")

        ready_path = arguments.evidence_dir / "service-ready.json"
        service_log_path = arguments.evidence_dir / "service.log"
        fixture_payload = write_fixture_artifacts(arguments.evidence_dir, arguments.fixture_set)
        validate_suite_fixture(arguments.suite, str(fixture_payload["fixture_set"]))
        if arguments.suite in DUAL_SERVER_SUITES and arguments.fixture_set != "a":
            raise CommandError(f"{arguments.suite} must start from server A; use --fixture-set a.")
        if arguments.suite in DUAL_SERVER_SUITES:
            write_member_manifest(arguments.evidence_dir / "member-manifest-a.json", "a")
            write_member_manifest(arguments.evidence_dir / "member-manifest-b.json", "b")
            peer_fixture = fixture_manifest("b")
            (arguments.evidence_dir / "fixture-manifest-b.json").write_text(
                json.dumps(peer_fixture, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        if case_manifest is not None:
            case_manifest["fixture_sha256"] = fixture_payload["fixture_sha256"]
            write_case_manifest(arguments.evidence_dir, case_manifest)
        service_scenario, input_key, starts_service = scenario_settings(arguments.scenario)
        if starts_service:
            service_process = subprocess.Popen(
                [
                    sys.executable,
                    str(REPO_ROOT / "scripts/strict_e2e_server.py"),
                    "--host",
                    "127.0.0.1",
                    "--port",
                    "0",
                    "--fixture-set",
                    arguments.fixture_set,
                    "--scenario",
                    service_scenario,
                    "--ready-file",
                    str(ready_path),
                    "--log-file",
                    str(service_log_path),
                ],
                cwd=REPO_ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            host, port = wait_for_service(ready_path, service_process)
            server_url = f"http://{host}:{port}/api"
            if arguments.suite in DUAL_SERVER_SUITES:
                ready_b = arguments.evidence_dir / "service-b-ready.json"
                service_log_b_path = arguments.evidence_dir / "service-b.log"
                service_process_b = subprocess.Popen(
                    [
                        sys.executable,
                        str(REPO_ROOT / "scripts/strict_e2e_server.py"),
                        "--host",
                        "127.0.0.1",
                        "--port",
                        "0",
                        "--fixture-set",
                        "b",
                        "--scenario",
                        service_scenario,
                        "--ready-file",
                        str(ready_b),
                        "--log-file",
                        str(service_log_b_path),
                    ],
                    cwd=REPO_ROOT,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                host_b, port_b = wait_for_service(ready_b, service_process_b)
                server_url_b = f"http://{host_b}:{port_b}/api"
        else:
            server_url, unreachable_reservation = reserve_unreachable_server_url()
            ready_path.write_text(
                json.dumps({"listening": False, "scenario": "unreachable"}, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            service_log_path.write_text("scenario=unreachable listening=false\n", encoding="utf-8")

        reset_log = reset_simulator_app(simulator_udid)
        (arguments.evidence_dir / "simulator-reset.log").write_text(reset_log, encoding="utf-8")

        environment = make_test_environment(
            os.environ,
            server_url=server_url,
            public_key=input_key,
            scenario=arguments.scenario,
            server_url_b=server_url_b,
        )
        (arguments.evidence_dir / "runner-input-audit.json").write_text(
            json.dumps(
                {
                    "input_keys_present": [
                        key
                        for key in (
                            "STRICT_E2E_INPUT_PUBLIC_KEY",
                            "STRICT_E2E_INPUT_SCENARIO",
                            "STRICT_E2E_INPUT_SERVER_URL",
                            "STRICT_E2E_INPUT_SERVER_URL_B",
                            "STRICT_E2E_INPUT_SERVER_B_URL",
                        )
                        if key in environment
                    ],
                    "scenario": arguments.scenario,
                    "suite": arguments.suite,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        person_summaries: list[TestResultsSummary] | None = None
        # Give each person rule a clean install and first launch; clearing the selection is not an intermediate state, or playback mode reverts to random.
        if arguments.suite == "filter-person":
            reset_logs = [reset_log]
            commands: list[str] = []
            summaries: list[TestResultsSummary] = []
            log_parts: list[str] = []
            for index, session in enumerate(FILTER_PERSON_SESSIONS):
                if index > 0:
                    reset_logs.append(reset_simulator_app(simulator_udid))
                session_bundle = arguments.evidence_dir / f"strict-filter-person-{session['name']}.xcresult"
                session_log = arguments.evidence_dir / f"xcodebuild-{session['name']}.log"
                command = build_xcodebuild_command(
                    repo_root=REPO_ROOT,
                    platform=arguments.platform,
                    destination=arguments.destination,
                    derived_data_path=derived_data_path,
                    result_bundle_path=session_bundle,
                    server_url=server_url,
                    suite=arguments.suite,
                    scenario=arguments.scenario,
                    evidence_dir=arguments.evidence_dir,
                    server_url_b=server_url_b,
                    only_testing=session["selector"],
                )
                commands.append(shlex.join(command))
                exit_code = run_command(
                    command,
                    cwd=REPO_ROOT,
                    environment=environment,
                    log_path=session_log,
                )
                if exit_code != 0:
                    (arguments.evidence_dir / "xcodebuild.log").write_text(
                        "\n".join([*log_parts, session_log.read_text(encoding="utf-8")]),
                        encoding="utf-8",
                    )
                    (arguments.evidence_dir / "xcodebuild-command.txt").write_text(
                        "\n".join(commands) + "\n", encoding="utf-8"
                    )
                    (arguments.evidence_dir / "simulator-reset.log").write_text(
                        "\n".join(reset_logs) + "\n", encoding="utf-8"
                    )
                    raise CommandError(f"xcodebuild strict E2E failed with exit {exit_code}.", code=exit_code)
                summary = read_official_test_results_summary(session_bundle)
                require_official_single_pass(summary)
                summaries.append(summary)
                log_parts.append(session_log.read_text(encoding="utf-8"))
            (arguments.evidence_dir / "xcodebuild-command.txt").write_text(
                "\n".join(commands) + "\n", encoding="utf-8"
            )
            if case_manifest is not None:
                case_manifest["command"] = "\n".join(commands)
                write_case_manifest(arguments.evidence_dir, case_manifest)
            (arguments.evidence_dir / "xcodebuild.log").write_text("\n".join(log_parts), encoding="utf-8")
            (arguments.evidence_dir / "simulator-reset.log").write_text(
                "\n".join(reset_logs) + "\n", encoding="utf-8"
            )
            person_summaries = summaries
        else:
            command = build_xcodebuild_command(
                repo_root=REPO_ROOT,
                platform=arguments.platform,
                destination=arguments.destination,
                derived_data_path=derived_data_path,
                result_bundle_path=result_bundle_path,
                server_url=server_url,
                suite=arguments.suite,
                scenario=arguments.scenario,
                evidence_dir=arguments.evidence_dir,
                server_url_b=server_url_b,
            )
            (arguments.evidence_dir / "xcodebuild-command.txt").write_text(
                shlex.join(command) + "\n", encoding="utf-8"
            )
            if case_manifest is not None:
                case_manifest["command"] = shlex.join(command)
                write_case_manifest(arguments.evidence_dir, case_manifest)
            if (arguments.suite in P2_CASES and P2_CASES[arguments.suite].video) or arguments.suite in SERVER_SWITCH_DISPLAY_SUITES:
                recording_process, recording_started = start_screen_recording(
                    simulator_udid,
                    arguments.evidence_dir / RECORDING_FILE,
                    arguments.evidence_dir / "screen-recording.log",
                )
            exit_code = run_command(
                command,
                cwd=REPO_ROOT,
                environment=environment,
                log_path=arguments.evidence_dir / "xcodebuild.log",
            )
            if recording_process is not None:
                finished_recording, recording_process = recording_process, None
                recording_exit = stop_screen_recording(finished_recording)
                (arguments.evidence_dir / RECORDING_TIMING_FILE).write_text(
                    json.dumps(
                        {
                            "started_wall_time": recording_started,
                            "stopped_wall_time": time.time(),
                            "stop_exit": recording_exit,
                        },
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
            if exit_code != 0:
                raise CommandError(f"xcodebuild strict E2E failed with exit {exit_code}.", code=exit_code)
            summary = read_official_test_results_summary(result_bundle_path)
            require_official_single_pass(summary)
        if service_log_path.is_file():
            (arguments.evidence_dir / "redacted-request.log").write_bytes(service_log_path.read_bytes())
        if arguments.scenario == "out-of-order":
            log_text = (
                service_log_path.read_text(encoding="utf-8") if service_log_path.is_file() else ""
            )
            audit_payload = audit_out_of_order_runner_inputs(
                fixture_set=arguments.fixture_set,
                observed_hash=str(fixture_payload["fixture_sha256"]),
                service_log=log_text,
                server_url=server_url,
            )
            (arguments.evidence_dir / "runner-input-audit.json").write_text(
                json.dumps(audit_payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
        if service_log_b_path is not None and service_log_b_path.is_file():
            (arguments.evidence_dir / "request-log-b.log").write_bytes(service_log_b_path.read_bytes())
        if person_summaries is not None:
            summary_payload = merge_official_summaries(person_summaries)
        else:
            summary_payload = {
                "totalTestCount": summary.total_test_count,
                "passedTests": summary.passed_tests,
                "failedTests": summary.failed_tests,
                "skippedTests": summary.skipped_tests,
                "result": summary.result,
            }
        (arguments.evidence_dir / "official-summary.json").write_text(
            json.dumps(summary_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        if arguments.suite in P2_CASES:
            visual_payload = require_p2_evidence(
                arguments.evidence_dir,
                suite=arguments.suite,
                platform=arguments.platform,
                simulator_udid=simulator_udid,
                fixture_set=arguments.fixture_set,
                result_bundle_path=result_bundle_path,
            )
            if case_manifest is not None:
                case_manifest.update(visual_payload["execution"])
        else:
            visual_payload = require_visual_identity(arguments.evidence_dir, arguments.suite)
        if case_manifest is not None:
            case_manifest["result"] = summary.result
            case_manifest["exit_code"] = 0
            case_manifest["official_summary"] = summary_payload
            case_manifest["visual_identity"] = visual_payload
            write_case_manifest(arguments.evidence_dir, case_manifest)
        print(json.dumps(summary_payload, sort_keys=True), file=stdout)
    except (CommandError, OfflineCommandError) as error:
        print(str(error), file=stderr)
        primary_exit_code = error.code
        if owns_evidence_directory and case_manifest is not None:
            case_manifest["result"] = "FAILED"
            case_manifest["exit_code"] = primary_exit_code
            try:
                write_case_manifest(arguments.evidence_dir, case_manifest)
            except OSError as write_error:
                cleanup_failures.append(f"write_case_manifest: {type(write_error).__name__}: {write_error}")
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Evidence or process I/O failed: {error}", file=stderr)
        primary_exit_code = 2
    finally:
        lifecycle: dict[str, object] = {}

        def export_and_hold_p2_bundle() -> None:
            nonlocal private_result_bundle, official_tests_digest
            if arguments.suite not in P2_CASES or result_bundle_path is None or not result_bundle_path.is_dir():
                return
            private_result_bundle = result_bundle_path
            completed = subprocess.run(
                ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result_bundle_path), "--compact"],
                capture_output=True,
                check=False,
                timeout=60,
            )
            if completed.returncode != 0:
                raise CommandError(f"Official test export failed with exit {completed.returncode}.")
            payload = json.loads(completed.stdout)
            if not isinstance(payload, dict):
                raise CommandError("Official test export is not a JSON object.")
            if logical_bytes_contain(completed.stdout, [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY]):
                raise CommandError("Official test export contains test credentials; refusing to retain it.")
            exported = arguments.evidence_dir / "official-tests.json"
            exported.write_bytes(completed.stdout)
            official_tests_digest = hashlib.sha256(completed.stdout).hexdigest()
            summary_path = arguments.evidence_dir / "official-summary.json"
            if not summary_path.exists():
                test_summary = read_official_test_results_summary(result_bundle_path)
                summary_path.write_text(
                    json.dumps(
                        {
                            "totalTestCount": test_summary.total_test_count,
                            "passedTests": test_summary.passed_tests,
                            "failedTests": test_summary.failed_tests,
                            "skippedTests": test_summary.skipped_tests,
                            "result": test_summary.result,
                        },
                        indent=2,
                        sort_keys=True,
                    ) + "\n",
                    encoding="utf-8",
                )
            if case_manifest is not None and official_tests_digest is not None:
                case_manifest["official_tests_sha256"] = official_tests_digest
                write_case_manifest(arguments.evidence_dir, case_manifest)

        def stop_recording() -> None:
            if recording_process is not None:
                stop_screen_recording(recording_process)

        def stop_service() -> None:
            if service_process is None:
                return
            lifecycle["pid"] = service_process.pid
            lifecycle["exit"] = stop_exact_process(service_process)

        def stop_service_b() -> None:
            if service_process_b is None:
                return
            lifecycle["pid_b"] = service_process_b.pid
            lifecycle["exit_b"] = stop_exact_process(service_process_b)

        def close_unreachable_reservation() -> None:
            if unreachable_reservation is not None:
                unreachable_reservation.close()

        def write_lifecycle() -> None:
            if owns_evidence_directory and lifecycle:
                (arguments.evidence_dir / "service-lifecycle.json").write_text(
                    json.dumps(lifecycle, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )

        actions: list[tuple[str, Callable[[], None]]] = [
            ("stop_screen_recording", stop_recording),
            ("stop_service", stop_service),
            ("stop_service_b", stop_service_b),
            ("close_unreachable_reservation", close_unreachable_reservation),
            ("write_service_lifecycle", write_lifecycle),
        ]
        if did_create_config:
            actions.append(
                (
                    "cleanup_task_xcconfig",
                    lambda: cleanup_task_xcconfig(REPO_ROOT / EXAMPLE_XCCONFIG, config_path),
                )
            )
        if derived_data_path.exists():
            actions.append(("remove_derived_data", lambda: shutil.rmtree(derived_data_path)))
        actions.append(("export_and_hold_p2_bundle", export_and_hold_p2_bundle))
        cleanup_failures.extend(run_cleanup_actions(actions))

        if owns_evidence_directory:
            if cleanup_failures:
                try:
                    (arguments.evidence_dir / "cleanup-failures.json").write_text(
                        json.dumps({"failures": cleanup_failures}, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )
                except OSError as error:
                    cleanup_failures.append(f"write_cleanup_failures: {type(error).__name__}: {error}")
            try:
                write_sensitive_scan(
                    arguments.evidence_dir,
                    [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY],
                )
            except CommandError as error:
                cleanup_failures.append(f"sensitive_scan: {error}")

        def record_private_quarantine() -> None:
            if private_result_bundle is None:
                return
            (arguments.evidence_dir / "result-bundle-quarantine.json").write_text(
                json.dumps(
                    {"private_path": str(private_result_bundle), "result_bundle_disposed": False},
                    indent=2,
                    sort_keys=True,
                ) + "\n",
                encoding="utf-8",
            )

        if private_result_bundle is not None:
            if primary_exit_code == 0 and not cleanup_failures:
                try:
                    (arguments.evidence_dir / "result-bundle-disposal.json").write_text(
                        json.dumps(
                            {
                                "reason": "The original XCTest result bundle may contain test credentials entered through normal UI input",
                                "official_tests_command": "xcrun xcresulttool get test-results tests --compact",
                                "official_tests_sha256": official_tests_digest,
                                "private_path": str(private_result_bundle),
                                "result_bundle_disposed": True,
                            },
                            indent=2,
                            sort_keys=True,
                            ensure_ascii=False,
                        ) + "\n",
                        encoding="utf-8",
                    )
                    shutil.rmtree(private_result_bundle)
                    private_result_bundle.parent.rmdir()
                except OSError as error:
                    cleanup_failures.append(f"dispose_private_result_bundle: {type(error).__name__}: {error}")
                    if private_result_bundle.exists():
                        try:
                            (arguments.evidence_dir / "result-bundle-disposal.json").unlink(missing_ok=True)
                        except OSError as record_error:
                            cleanup_failures.append(f"remove_incomplete_disposal_record: {type(record_error).__name__}: {record_error}")
                        try:
                            record_private_quarantine()
                        except OSError as record_error:
                            cleanup_failures.append(f"write_result_bundle_quarantine: {type(record_error).__name__}: {record_error}")
            else:
                try:
                    record_private_quarantine()
                except OSError as error:
                    cleanup_failures.append(f"write_result_bundle_quarantine: {type(error).__name__}: {error}")

        if arguments.suite in P2_CASES and result_bundle_path is not None and not result_bundle_path.exists():
            try:
                result_bundle_path.parent.rmdir()
            except OSError:
                pass

        if owns_evidence_directory and cleanup_failures:
            try:
                (arguments.evidence_dir / "cleanup-failures.json").write_text(
                    json.dumps({"failures": cleanup_failures}, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            except OSError as error:
                cleanup_failures.append(f"write_cleanup_failures: {type(error).__name__}: {error}")

    if cleanup_failures:
        print("Cleanup or evidence finalization failed: " + " | ".join(cleanup_failures), file=stderr)
    return choose_exit_code(primary_exit_code, cleanup_failures)


if __name__ == "__main__":
    raise SystemExit(main())
