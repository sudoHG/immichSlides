#!/usr/bin/env python3
"""Start the public controlled service and run one strict E2E suite without injecting state into the app."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Mapping, Sequence, TextIO

from ci_execution_diagnostics import active

from run_offline_unit_tests import (
    CommandError as OfflineCommandError,
    TestResultsSummary,
    parse_non_negative_int,
    read_official_test_results_summary,
)
from album_server_narrow_contract import (
    AlbumServerContractError,
    evaluate_album_empty_evidence,
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
from ci_flaky import SERVER_SWITCH_RECORDING_SUITES


EXAMPLE_XCCONFIG = Path("Config/env.example.xcconfig")
TASK_XCCONFIG = Path("Config/env.xcconfig")
MIN_DATA_GIB = 80
IOS_LIFECYCLE_PAUSE_SUITE = "ios-lifecycle-pause"
# xcodebuild timeout for compile plus one UI test. Diagnostic collection is disabled.
XCODEBUILD_TIMEOUT_SECONDS = 300
SIMULATOR_RESET_TIMEOUT_SECONDS = 120
SIMULATOR_COMMAND_TIMEOUT_SECONDS = 60
SIMULATOR_BOOT_TIMEOUT_SECONDS = 600
SIMULATOR_PREPARATION_TIMEOUT_SECONDS = 600
SIMULATOR_READINESS_TIMEOUT_SECONDS = 300
SIMULATOR_READINESS_INITIAL_QUERY_TIMEOUT_SECONDS = 10
BOOT_SETTLE_TIMEOUT_SECONDS = 360
BOOT_SETTLE_WINDOW_SECONDS = 60
BOOT_SETTLE_INTERVAL_SECONDS = 10
# About one minute of missing ticks tolerates transient boot contention, but not a dead probe.
BOOT_SETTLE_MAX_CONSECUTIVE_MISSES = 6
# Process-local fallback if the job marker is unavailable; the disk marker spans processes.
_BOOT_SETTLE_ATTEMPTED = False
SERVICE_STARTUP_TIMEOUT_SECONDS = 60
# Preserve strict/tracer preparation limits under their existing outer budgets.
SERVICE_FIXTURE_BUILD_TIMEOUT_SECONDS = 120
# simctl writes Recording started only after processing the first frame; after SIGINT, wait for in-flight frames to write the moov atom.
RECORDING_START_TIMEOUT_SECONDS = 15
RECORDING_STOP_TIMEOUT_SECONDS = 30
WRONG_PUBLIC_API_KEY = "immichslides-public-e2e-wrong-key"
PRIVATE_RESULT_BUNDLE_ROOT = Path(tempfile.gettempdir()) / "immichSlides-strict-e2e-private"
RUNNER_SCENARIOS = ("normal", "auth-401", "html-200", "unreachable", "timeout", "out-of-order")
FORBIDDEN_EXACT_KEYS = {
    "IMMICH_SERVER_URL",
    "IMMICH_API_KEY",
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
TIMELINE_LIFECYCLE_SUITES = {
    "ios-lifecycle-pause-timeline": (
        "ios", "immichSlidesUITests/AccessLifecycleIOSUITests/testPauseNextContinueAppTimeline"),
    "tvos-lifecycle-pause-timeline": (
        "tvos", "immichSlidesUITests/AccessLifecycleTVOSUITests/testTVOSPauseNextContinueAppTimeline"),
}
LIFECYCLE_SUITES.update(TIMELINE_LIFECYCLE_SUITES)
IMAGE_FAILURE_RECOVERY_SUITES = {
    "image-failure-recovery": ("ios", "immichSlidesUITests/ScenePresentationContractUITests/testIOSImageFailureRecovery"),
}
RUNNER_SUITES = (
    "smoke",
    *LIFECYCLE_SUITES,
    *IMAGE_FAILURE_RECOVERY_SUITES,
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
    *IMAGE_FAILURE_RECOVERY_SUITES,
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
    "tvos-n1-cold",
    "tvos-album-empty",
    *P2_CASES,
)
DUAL_SERVER_SUITES = ("filter-switch", "tvos-switch")
ALBUM_EMPTY_SUITES = ("album-empty", "tvos-album-empty")
DISPLAY_POLICY_SUITES = ("display-policy", "tvos-display-policy")
# The test selects fixture A ids and the Python evaluator checks marks against fixture A.
FIXTURE_A_ONLY_FILTER_SUITES = ("tvos-album",)
SETTINGS_RESUME_SUITES = (
    *(suite for suite in LIFECYCLE_SUITES if suite not in TIMELINE_LIFECYCLE_SUITES),
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
    **{suite: ["image-failure-recovery"] for suite in IMAGE_FAILURE_RECOVERY_SUITES},
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
    "filter-switch": ["E2E-P0-06", "server-switch"],
    "filter-vision": ["E2E-P0-05"],
    "tvos-album": ["E2E-P0-04"],
    "tvos-display-policy": ["display-policy"],
    "tvos-edit-switch": ["E2E-P0-04"],
    "tvos-person": ["E2E-P0-05"],
    "tvos-switch": ["E2E-P0-06", "server-switch"],
    "album-empty": ["album-empty"],
    "tvos-n1-cold": ["N1"],
    "tvos-album-empty": ["album-empty"],
    "tvos-firstboot-failure": ["fail-html-200"],
    "late-image": ["E2E-P0-07"],
    **{suite: list(case.e2e_ids) for suite, case in P2_CASES.items()},
}
class CommandError(Exception):
    def __init__(self, message: str, code: int = 2) -> None:
        super().__init__(message)
        self.code = code


class InfrastructureTimeout(CommandError):
    """Retain the phase without exposing subprocess arguments or captured output."""

    def __init__(self, phase: str, timeout_seconds: float) -> None:
        message = f"{phase} timed out after {timeout_seconds:.1f}s."
        super().__init__(message, code=124)
        self.entry = {"code": phase + "-timeout", "message": message}


def simulator_command(command: list[str], phase: str, *, deadline: float | None = None,
                      timeout_seconds: float = SIMULATOR_COMMAND_TIMEOUT_SECONDS,
                      accepts_nonzero: Callable[[subprocess.CompletedProcess], bool] | None = None):
    budget = min(timeout_seconds, deadline - time.monotonic()) if deadline is not None else timeout_seconds
    if budget <= 0:
        raise InfrastructureTimeout(phase, 0)
    recorder = active()
    recorder = recorder if phase in ("simulator-boot", "simulator-bootstatus", "simulator-container", "simulator-preparation") else None
    started, cpu = time.monotonic(), time.process_time()
    sequence = recorder.next_sequence() if recorder else 0
    def mark(state):
        if recorder:
            recorder.event("preparation", phase, state, sequence, elapsed=time.monotonic() - started,
                           cpu=time.process_time() - cpu)
    mark("started")
    try:
        completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=budget)
    except subprocess.TimeoutExpired as error:
        # run has already killed, waited and closed pipes; internal boundaries are unobserved.
        mark("timeout")
        mark("reap-completed")
        raise InfrastructureTimeout(phase, budget) from error
    if completed.returncode == 0 or (accepts_nonzero is not None and accepts_nonzero(completed)):
        mark("completed")
    return completed


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
    if os.path.lexists(destination_path):
        raise CommandError("Task env.xcconfig already exists; strict E2E refuses to start to avoid reading or overwriting private configuration.")
    from ci_local import CONTEXT
    if os.environ.get(CONTEXT) == str(destination_path.parent.parent.resolve()):
        # CI-equivalent snapshots use project defaults and explicit fixture runtime inputs.
        return {"private_configuration_present": False, "ENABLE_DEBUG_AUTO_SERVER": "0",
                "ENABLE_DEBUG_FILL_APIKEY_BUTTON": "0"}
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
    for prefix in ("TEST_RUNNER_", "SIMCTL_CHILD_"):
        if key.startswith(prefix):
            return _is_forbidden_key(key[len(prefix):])
    return key.startswith("UI_TEST_") or key in FORBIDDEN_EXACT_KEYS


def strict_app_launch_environment(suite: str | None) -> dict[str, str | None]:
    """Declare Swift launch keys; None is the runner-provided loopback server URL."""
    if suite == "late-image":
        return {"UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE": "1", "UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT": "1"}
    if suite in {"album-empty", "filter-person", "journey-b", "tvos-flow", "tvos-person", "ios-lifecycle-first-wake"}:
        return {"UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE": "1"}
    if suite in {"pause-window", "tvos-directional-wake"}:
        environment = {"UI_TEST_SERVER_URL": None, "UI_TEST_API_KEY": PUBLIC_API_KEY,
                       "UI_TEST_RESET_STATE": "1", "UI_TEST_FORCE_MODE_SELECTION": "1"}
        key = "UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE" if suite == "pause-window" else "UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"
        if suite == "pause-window":
            environment["UI_TEST_PAUSE_AT_AUTOMATIC_FADE_MIDPOINT"] = "1"
        return {**environment, key: "1"}
    return {}


def write_app_launch_environment_audit(evidence_dir: Path, suite: str) -> None:
    """Write the static launch declaration, not an observed runtime validation."""
    environment = strict_app_launch_environment(suite)
    (evidence_dir / "app-launch-environment-audit.json").write_text(
        json.dumps({"declaration_kind": "static_swift_launch_keys",
                    "launch_environment_keys": sorted(environment)}, indent=2) + "\n",
        encoding="utf-8",
    )


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
    if suite in (*DISPLAY_POLICY_SUITES, *LIFECYCLE_SUITES, *FIXTURE_A_ONLY_FILTER_SUITES, *IMAGE_FAILURE_RECOVERY_SUITES) and fixture_set != "a":
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
def _is_already_booted(stderr: str) -> bool:
    text = stderr.lower()
    return "current state: booted" in text or "already booted" in text


def boot_simulator(simulator_udid: str, *, report: Callable[[str], None] | None = None,
                   deadline: float | None = None, boot_submitted: bool = False) -> str:
    """Give cold boot its own deadline before any app-reset clock starts."""
    started = time.monotonic()
    deadline = min(deadline, started + SIMULATOR_BOOT_TIMEOUT_SECONDS) if deadline is not None else started + SIMULATOR_BOOT_TIMEOUT_SECONDS
    lines = []
    # A submitted early boot needs no second short command during the cold-device stall.
    steps = [("bootstatus", SIMULATOR_BOOT_TIMEOUT_SECONDS)]
    if not boot_submitted:
        steps.insert(0, ("boot", SIMULATOR_COMMAND_TIMEOUT_SECONDS))
    for step, cap in steps:
        phase = "simulator-" + step
        phase_started = time.monotonic()
        outcome = "failed"
        try:
            completed = simulator_command(["xcrun", "simctl", step, simulator_udid, *(["-b"] if step == "bootstatus" else [])],
                                          phase, deadline=deadline, timeout_seconds=cap,
                                          accepts_nonzero=lambda result: step == "boot" and _is_already_booted(result.stderr))
            lines.append(f"{step}_exit={completed.returncode}")
            if step == "bootstatus" and "Booting device..." in (completed.stdout or ""):
                line = "simulator-bootstatus: started-device=true"
                lines.append(line)
                if report is not None:
                    report(line)
            if completed.returncode and not (step == "boot" and _is_already_booted(completed.stderr)):
                message = "Simulator boot failed" if step == "boot" else "Simulator did not become available"
                raise CommandError(f"{message} (exit {completed.returncode}); cannot continue with a clean install.")
            outcome = "passed"
        finally:
            line = (f"{phase}: {outcome}; elapsed={time.monotonic() - phase_started:.1f}s; "
                    f"total={time.monotonic() - started:.1f}s; total budget={SIMULATOR_BOOT_TIMEOUT_SECONDS}s")
            lines.append(line)
            if report is not None:
                report(line)
    return "\n".join(lines) + "\n"


def wait_for_simulator_app_response(simulator_udid: str, bundle_id: str, *, report: Callable[[str], None],
                                    deadline: float | None = None) -> tuple[str | None, str]:
    """Let timed-out post-boot queries recover before the clean-reset clock starts."""
    return _wait_for_simulator_response(
        lambda deadline, timeout: simulator_app_container(simulator_udid, bundle_id, deadline=deadline,
                                                          timeout_seconds=timeout),
        "simulator-readiness", report=report, deadline=deadline)


def wait_for_simulator_service_response(simulator_udid: str, *, report: Callable[[str], None],
                                       deadline: float):
    """Check the bootstrap service before builds without querying the cold app database."""
    def query(deadline, timeout):
        # simctl resolves a bare executable in the device; absolute paths refer to the host.
        completed = simulator_command(
            ["xcrun", "simctl", "spawn", simulator_udid, "launchctl", "print", "system/com.apple.lsd"],
            "simulator-preparation", deadline=deadline, timeout_seconds=timeout)
        if completed.returncode:
            raise CommandError(f"Simulator LaunchServices registration check failed (exit {completed.returncode}).")
    return _wait_for_simulator_response(query, "simulator-readiness", report=report, deadline=deadline)


def simulator_inventory(*, report: Callable[[str], None] | None = None) -> dict:
    """Apply the existing readiness retry only to timed-out inventory queries."""
    def query(deadline, timeout):
        completed = simulator_command(["xcrun", "simctl", "list", "devices", "available", "--json"],
                                      "simulator-inventory", deadline=deadline, timeout_seconds=timeout)
        if completed.returncode:
            raise CommandError(f"Simulator inventory failed (exit {completed.returncode}).")
        try:
            return json.loads(completed.stdout)
        except (TypeError, ValueError) as error:
            raise CommandError("Simulator inventory returned invalid JSON.") from error
    inventory, _ = _wait_for_simulator_response(query, "simulator-inventory",
        report=report or (lambda line: print(line, flush=True)))
    return inventory


def _wait_for_simulator_response(query, phase: str, *, report: Callable[[str], None],
                                 deadline: float | None = None):
    started = time.monotonic()
    deadline = min(deadline, started + SIMULATOR_READINESS_TIMEOUT_SECONDS) if deadline is not None else started + SIMULATOR_READINESS_TIMEOUT_SECONDS
    budget = max(0, deadline - started)
    attempts = 0
    query_timeout = SIMULATOR_READINESS_INITIAL_QUERY_TIMEOUT_SECONDS
    outcome = "failed"
    lines = []
    recorder = active() if phase == "simulator-readiness" else None
    sequence = recorder.next_sequence() if recorder else 0
    if recorder:
        recorder.event("preparation", phase, "started", sequence)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise InfrastructureTimeout(phase, budget)
            attempts += 1
            query_budget = min(query_timeout, remaining)
            query_started = time.monotonic()
            try:
                response = query(deadline, query_budget)
            except InfrastructureTimeout:
                line = (f"{phase}: query timed out; attempt={attempts}; timeout={query_budget:.1f}s; "
                        f"query_elapsed={time.monotonic() - query_started:.1f}s; elapsed={time.monotonic() - started:.1f}s")
                lines.append(line)
                report(line)
                query_timeout = min(query_timeout * 2, SIMULATOR_COMMAND_TIMEOUT_SECONDS)
                continue
            if time.monotonic() >= deadline:
                raise InfrastructureTimeout(phase, budget)
            line = (f"{phase}: query completed; attempt={attempts}; "
                    f"query_elapsed={time.monotonic() - query_started:.3f}s; elapsed={time.monotonic() - started:.3f}s")
            lines.append(line)
            report(line)
            outcome = "passed"
            break
    finally:
        elapsed = time.monotonic() - started
        if recorder and (outcome == "passed" or isinstance(sys.exc_info()[1], InfrastructureTimeout)):
            recorder.event("preparation", phase, "timeout" if outcome != "passed" else "completed", sequence,
                           elapsed=elapsed)
        line = (f"{phase}: {outcome}; attempts={attempts}; elapsed={elapsed:.1f}s; "
                f"total budget={budget:g}s; "
                f"deadline_overrun={max(0, elapsed - budget):.1f}s")
        lines.append(line)
        report(line)
    return response, "\n".join(lines) + "\n"


def _boot_process_output(command: Sequence[str], deadline: float) -> str:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError
    completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=min(5, remaining))
    if completed.returncode:
        raise ValueError
    return completed.stdout


def _boot_manager_pid(device: str, deadline: float) -> int:
    root = int(_boot_process_output(["xcrun", "simctl", "spawn", device, "launchctl", "managerpid"], deadline).strip())
    if root <= 0:
        raise ValueError
    return root


def _boot_device_cpu(root: int, deadline: float) -> float | None:
    """Read numeric process ancestry for this device without collecting names or argv."""
    rows = {}
    raw = _boot_process_output(["/bin/ps", "-A", "-o", "pid=,ppid=,%cpu="], deadline)
    if len(raw) > 2 * 1024 * 1024:
        return None
    for line in raw.splitlines():
        try:
            pid, parent, cpu = line.split()
            pid, parent, cpu = int(pid), int(parent), float(cpu)
        except ValueError:
            return None
        if pid <= 0 or parent < 0 or pid in rows or not math.isfinite(cpu) or cpu < 0:
            return None
        rows[pid] = (parent, cpu)
    if root not in rows:
        return None
    owned, pending = {root}, [root]
    children = {}
    for pid, (parent, _) in rows.items():
        children.setdefault(parent, []).append(pid)
    while pending:
        for pid in children.get(pending.pop(), []):
            if pid not in owned:
                owned.add(pid)
                pending.append(pid)
    return sum(rows[pid][1] for pid in owned)


def _settle_simulator_boot(device: str, deadline: float) -> str:
    """Best-effort job-once admission, wholly inside the existing preparation budget."""
    global _BOOT_SETTLE_ATTEMPTED
    started = time.monotonic()
    outcome, idle, cpu, cores, threshold = "unavailable", None, None, None, None
    missed_points = consecutive_misses = 0
    probe = None
    try:
        if not (os.environ.get("GITHUB_ACTIONS") == "true"
                and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
                and os.environ.get("GITHUB_EVENT_NAME") in {"schedule", "workflow_dispatch"}):
            outcome = "skipped-environment"
        elif _BOOT_SETTLE_ATTEMPTED:
            outcome = "skipped-repeat"
        else:
            _BOOT_SETTLE_ATTEMPTED = True
            # RUNNER_TEMP is job-scoped, so repeated preparations share one attempt.
            marker = Path(os.environ["RUNNER_TEMP"]) / "immichslides-boot-settle-attempted"
            try:
                descriptor = os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                outcome = "skipped-repeat"
            else:
                os.close(descriptor)
                cores = os.cpu_count()
                if not cores or cores < 1:
                    raise ValueError
                threshold = max(30.0, 100.0 / cores)
                deadline = min(deadline, started + BOOT_SETTLE_TIMEOUT_SECONDS)
                # The device's manager PID is stable throughout this boot.
                root = _boot_manager_pid(device, deadline)
                from strict_e2e_resource_diagnostics import HostProbe
                # HostProbe bounds each Mach read to 0.2 seconds and abandons stalled workers.
                probe = HostProbe(device)
                probe.sample()
                qualifying_since = None
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        outcome = "timed-out"
                        break
                    if probe.unavailable:
                        outcome = "sampling-failed"
                        break
                    time.sleep(min(BOOT_SETTLE_INTERVAL_SECONDS, remaining))
                    if time.monotonic() >= deadline:
                        outcome = "timed-out"
                        break
                    idle = cpu = None
                    try:
                        sample = probe.sample()
                        idle = sample.get("idle_percent") if sample else None
                        cpu = _boot_device_cpu(root, deadline)
                        if (idle is None or cpu is None or not math.isfinite(idle) or not 0 <= idle <= 100
                                or not math.isfinite(cpu) or cpu < 0):
                            raise ValueError
                    except (OSError, ValueError, TypeError, AttributeError, KeyError, RuntimeError, subprocess.SubprocessError):
                        missed_points += 1
                        consecutive_misses += 1
                        qualifying_since = None
                        if time.monotonic() >= deadline:
                            outcome = "timed-out"
                            break
                        if consecutive_misses >= BOOT_SETTLE_MAX_CONSECUTIVE_MISSES:
                            outcome = "sampling-failed"
                            break
                        continue
                    consecutive_misses = 0
                    now = time.monotonic()
                    if now >= deadline:
                        outcome = "timed-out"
                        break
                    if idle >= threshold and cpu <= 120:
                        if qualifying_since is None:
                            qualifying_since = now
                        if now - qualifying_since >= BOOT_SETTLE_WINDOW_SECONDS:
                            outcome = "settled"
                            break
                    else:
                        qualifying_since = None
    except (ImportError, OSError, ValueError, TypeError, AttributeError, KeyError, RuntimeError, subprocess.SubprocessError):
        # Never publish exception text, commands, process identities or a new verdict.
        outcome = "timed-out" if time.monotonic() >= deadline else "unavailable"
    finally:
        if probe is not None:
            probe.close()
    def number(value):
        return f"{value:.3f}" if isinstance(value, (int, float)) and math.isfinite(value) else "null"
    return (f"simulator-boot-settle: outcome={outcome}; duration_seconds={time.monotonic() - started:.3f}; "
            f"idle_percent={number(idle)}; device_cpu_percent={number(cpu)}; "
            f"logical_cores={cores if isinstance(cores, int) else 'null'}; idle_threshold_percent={number(threshold)}; "
            f"missed_points={missed_points}")


def prepare_simulator(simulator_udid: str, bundle_id: str = "com.331works.immichSlides", *,
                      report: Callable[[str], None] | None = None, boot_submitted: bool = False,
                      should_check_app: bool = True, should_settle_boot: bool = False) -> tuple[str | None, str]:
    """Gate preparation; prebuild callers may request service registration only, returning no container fact."""
    report = report or (lambda line: print(line, flush=True))
    recorder = active()
    initial_sample = recorder.sample("preparation", initial=True) if recorder else None
    started = time.monotonic()
    deadline = started + SIMULATOR_PREPARATION_TIMEOUT_SECONDS
    lines = [f"simulator_id={simulator_udid}"]
    outcome = "failed"
    sequence = recorder.next_sequence() if recorder else 0
    if recorder:
        start_event = recorder.event("preparation", "simulator-preparation", "started", sequence)
    try:
        lines.extend(boot_simulator(simulator_udid, report=report, deadline=deadline, boot_submitted=boot_submitted).splitlines())
        if should_check_app:
            container, readiness_log = wait_for_simulator_app_response(simulator_udid, bundle_id, report=report, deadline=deadline)
        else:
            line = "simulator-readiness: probe=launch-services-registration"
            lines.append(line)
            report(line)
            container, readiness_log = wait_for_simulator_service_response(simulator_udid, report=report, deadline=deadline)
        lines.extend(readiness_log.splitlines())
        if should_settle_boot and boot_submitted:
            line = _settle_simulator_boot(simulator_udid, deadline)
            lines.append(line)
            report(line)
        outcome = "passed"
    finally:
        elapsed = time.monotonic() - started
        if recorder:
            if outcome != "passed" and start_event is not None:
                start_event["sample"] = initial_sample
            if outcome == "passed" or isinstance(sys.exc_info()[1], InfrastructureTimeout):
                recorder.event("preparation", "simulator-preparation", "timeout" if outcome != "passed" else "completed",
                               sequence, elapsed=elapsed, sample=recorder.sample("preparation") if outcome != "passed" else None)
        line = (f"simulator-preparation: {outcome}; elapsed={elapsed:.1f}s; "
                f"total budget={SIMULATOR_PREPARATION_TIMEOUT_SECONDS}s; "
                f"deadline_overrun={max(0, elapsed - SIMULATOR_PREPARATION_TIMEOUT_SECONDS):.1f}s")
        lines.append(line)
        report(line)
    return container, "\n".join(lines) + "\n"


def _disable_password_autofill(simulator_udid: str, reset_deadline: float, report: Callable[[str], None]) -> list[str]:
    started = time.monotonic()
    deadline = min(reset_deadline, started + SIMULATOR_COMMAND_TIMEOUT_SECONDS)
    budget = max(0, deadline - started)
    lines, outcome = [], "failed"

    def command(argv: list[str], step: str):
        step_started = time.monotonic()
        try:
            return simulator_command(argv, "simulator-password-autofill-" + step, deadline=deadline)
        finally:
            line = f"password-autofill-{step}: elapsed={time.monotonic() - step_started:.3f}s"
            lines.append(line)
            report(line)

    try:
        inventory = command(["xcrun", "simctl", "list", "devices", "--json"], "device")
        if inventory.returncode:
            raise CommandError(f"Simulator password AutoFill device lookup failed (exit {inventory.returncode}); "
                               f"stderr={inventory.stderr.strip()!r}.")
        try:
            devices = [entry for entries in json.loads(inventory.stdout)["devices"].values() for entry in entries
                       if entry.get("udid") == simulator_udid]
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            raise CommandError("Simulator password AutoFill device lookup returned invalid JSON.") from error
        if (len(devices) != 1 or not isinstance(devices[0].get("dataPath"), str)
                or not Path(devices[0]["dataPath"]).is_absolute()):
            raise CommandError("Simulator password AutoFill device lookup did not identify one absolute data path.")
        preference = Path(devices[0]["dataPath"]) / "Library/Preferences/com.apple.WebUI.plist"
        disabled = command(["xcrun", "simctl", "spawn", simulator_udid, "defaults", "write",
                            "com.apple.WebUI", "AutoFillPasswords", "-bool", "NO"], "disable")
        lines.append(f"password_autofill_write_exit={disabled.returncode}; stderr={disabled.stderr.strip()!r}")
        if disabled.returncode:
            raise CommandError("Simulator password AutoFill disable failed; cannot continue with isolated state.\n" + "\n".join(lines))
        # Read the persisted boolean on the host; a second device spawn can exhaust a starved reset.
        readback = command(["/usr/bin/plutil", "-extract", "AutoFillPasswords", "raw", "-expect", "bool",
                            "-o", "-", str(preference)], "readback")
        lines.append(f"password_autofill_read_exit={readback.returncode}; stderr={readback.stderr.strip()!r}; "
                     f"value={readback.stdout.strip()!r}")
        if readback.returncode or readback.stdout.strip() != "false":
            raise CommandError("Simulator password AutoFill readback failed; cannot continue with isolated state.\n" + "\n".join(lines))
        if time.monotonic() >= deadline:
            raise InfrastructureTimeout("simulator-password-autofill", budget)
        lines.append("password_autofill=disabled; domain=com.apple.WebUI; key=AutoFillPasswords; readback=false; verifier=host-plutil")
        report(lines[-1])
        outcome = "passed"
    finally:
        line = (f"password-autofill: {outcome}; elapsed={time.monotonic() - started:.3f}s; budget={budget:.3f}s; "
                f"reset_remaining={max(0, reset_deadline - time.monotonic()):.3f}s")
        lines.append(line)
        report(line)
    return lines


def reset_simulator_app(simulator_udid: str, bundle_id: str = "com.331works.immichSlides", *,
                        platform: str, boot_submitted: bool = False) -> str:
    if platform not in ("ios", "tvos"):
        raise CommandError(f"Unsupported simulator platform {platform!r}; expected 'ios' or 'tvos'.")
    # The fixed sleep waits for simctl to release the container lock; a second uninstall failure must stop the run.
    report = lambda line: print(line, flush=True)
    container, preparation_log = prepare_simulator(simulator_udid, bundle_id, report=report, boot_submitted=boot_submitted)
    lines = preparation_log.splitlines()
    installed = container is not None
    started = time.monotonic()
    deadline = started + SIMULATOR_RESET_TIMEOUT_SECONDS
    # Terminate stalled after cold boot on hosted runners; skip it only when the app is absent.
    if installed:
        terminate = simulator_command(
            ["xcrun", "simctl", "terminate", simulator_udid, bundle_id], "simulator-terminate", deadline=deadline,
        )
        lines.append(f"terminate_exit={terminate.returncode}")
    else:
        lines.append("terminate_skipped=app-absent")
        report(lines[-1])
    uninstall = simulator_command(
        ["xcrun", "simctl", "uninstall", simulator_udid, bundle_id], "simulator-uninstall", deadline=deadline,
    )
    lines.append(f"uninstall_exit={uninstall.returncode}")
    if uninstall.returncode != 0:
        time.sleep(1)
        retry = simulator_command(
            ["xcrun", "simctl", "uninstall", simulator_udid, bundle_id], "simulator-uninstall-retry", deadline=deadline,
        )
        lines.append(f"uninstall_retry_exit={retry.returncode}")
        if retry.stderr.strip():
            lines.append(f"uninstall_retry_stderr={retry.stderr.strip()}")
        if retry.returncode != 0:
            raise CommandError("Second uninstall failed; cannot continue with a clean install.\n" + "\n".join(lines))
    if uninstall.stderr.strip():
        lines.append(f"uninstall_stderr={uninstall.stderr.strip()}")
    time.sleep(1)
    container = simulator_app_container(simulator_udid, bundle_id, deadline=deadline)
    if container:
        lines.append(f"app_container={container}")
        raise CommandError(
            "App container is still accessible after uninstall; cannot continue with a clean install.\n" + "\n".join(lines)
        )
    lines.append("app_container=absent")
    # These devices are dedicated to strict tests: uninstall alone leaves keychain and TCC state.
    for step, command in (
        ("keychain", ["xcrun", "simctl", "keychain", simulator_udid, "reset"]),
        ("privacy", ["xcrun", "simctl", "privacy", simulator_udid, "reset", "all"]),
    ):
        completed = simulator_command(command, f"simulator-{step}-reset", deadline=deadline)
        lines.append(f"{step}_reset_exit={completed.returncode}")
        if completed.returncode != 0:
            raise CommandError(f"Simulator {step} reset failed; cannot continue with isolated state.\n" + "\n".join(lines))
    if platform == "ios":
        lines.extend(_disable_password_autofill(simulator_udid, deadline, report))
    lines.append(f"simulator-reset: elapsed={time.monotonic() - started:.1f}s; total budget={SIMULATOR_RESET_TIMEOUT_SECONDS}s")
    report(lines[-1])
    return "\n".join(lines) + "\n"


def simulator_app_container(simulator_udid: str, bundle_id: str, *, deadline: float | None = None,
                            timeout_seconds: float = SIMULATOR_COMMAND_TIMEOUT_SECONDS) -> str | None:
    completed = simulator_command(
        ["xcrun", "simctl", "get_app_container", simulator_udid, bundle_id], "simulator-container", deadline=deadline,
        timeout_seconds=timeout_seconds,
        accepts_nonzero=lambda result: result.returncode == 2,
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


def wait_for_service(ready_path: Path, process: subprocess.Popen[bytes], *,
                     startup_log: Path | None = None,
                     fixture_build_timeout_seconds: float = SERVICE_FIXTURE_BUILD_TIMEOUT_SECONDS,
                     startup_timeout_seconds: float = SERVICE_STARTUP_TIMEOUT_SECONDS) -> tuple[str, int]:
    try:
        if startup_log is not None:
            _wait_for_fixture_build(process, startup_log, fixture_build_timeout_seconds)
        return _wait_for_service(ready_path, process, startup_timeout_seconds)
    except CommandError as error:
        lines = _service_startup_diagnostics(startup_log)
        if lines:
            phase, state = re.search(r"phase=([^;]+); state=([^;]+)", lines[-1]).groups()
            raise CommandError(f"{error} startup_phase={phase}; startup_state={state}.", code=error.code) from error
        raise
    finally:
        for line in _service_startup_diagnostics(startup_log):
            print(line, flush=True)


def _service_startup_diagnostics(path: Path | None) -> list[str]:
    if path is None:
        return []
    try:
        with path.open("rb") as handle:
            text = handle.read(4096).decode("utf-8", errors="replace")
    except OSError:
        return []
    pattern = (r"fixture-startup: phase=(import|fixture-build|bind|ready-write); state=(started|completed); "
               r"elapsed=\d{1,9}\.\d{3}s; total=\d{1,9}\.\d{3}s")
    return [line for line in text.splitlines() if re.fullmatch(pattern, line)][:8]


def _wait_for_fixture_build(process: subprocess.Popen[bytes], startup_log: Path, timeout_seconds: float) -> None:
    started = time.monotonic()
    deadline = started + timeout_seconds
    print(f"fixture-service: build started; budget={timeout_seconds}s", flush=True)
    while time.monotonic() < deadline:
        exit_code = process.poll()
        lines = _service_startup_diagnostics(startup_log)
        if exit_code is not None:
            phase = re.search(r"phase=([^;]+);", lines[-1]).group(1) if lines else "unknown"
            raise CommandError(f"Test service exited early during {phase} with exit {exit_code}.")
        if any("phase=fixture-build; state=completed;" in line for line in lines) and time.monotonic() < deadline:
            print(f"fixture-service: build completed; elapsed={time.monotonic() - started:.1f}s; "
                  f"budget={timeout_seconds}s", flush=True)
            return
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    raise CommandError(f"Test service fixture build timed out after {time.monotonic() - started:.1f}s "
                       f"(budget={timeout_seconds}s).", code=124)


def _wait_for_service(ready_path: Path, process: subprocess.Popen[bytes], timeout_seconds: float) -> tuple[str, int]:
    started = time.monotonic()
    deadline = started + timeout_seconds
    last_state = "ready-file-missing"
    while time.monotonic() < deadline:
        exit_code = process.poll()
        if exit_code is not None:
            raise CommandError(f"Test service exited early with exit {exit_code}.")
        last_state = "ready-file-missing"
        if ready_path.is_file():
            last_state = "ready-file-invalid"
            try:
                payload = json.loads(ready_path.read_text(encoding="utf-8"))
                if payload.get("pid") != process.pid:
                    raise CommandError("The PID in the test service ready file does not match the started child process.")
                host = payload["host"]
                port = int(payload["port"])
                last_state = "health-check-pending"
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=min(1, remaining)) as response:
                    last_state = f"health-http-{response.status}"
                    if response.status == 200 and time.monotonic() < deadline:
                        print(f"fixture-service: healthy; elapsed={time.monotonic() - started:.1f}s; "
                              f"total budget={timeout_seconds}s", flush=True)
                        return str(host), port
            except urllib.error.HTTPError as error:
                last_state = f"health-http-{error.code}"
            except (OSError, KeyError, TypeError, ValueError) as error:
                last_state += f":{type(error).__name__}"
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    raise CommandError(f"Test service health check timed out after {time.monotonic() - started:.1f}s "
                       f"(budget={timeout_seconds}s; last_state={last_state}).", code=124)


def stop_exact_process(process: subprocess.Popen[bytes]) -> int:
    if process.poll() is None:
        process.terminate()
        try:
            return process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    return process.wait(timeout=5)
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


def pause_timing_verdict(evidence_dir: Path) -> str:
    """Read the existing timing signature without reinterpreting screenshot samples."""
    try:
        receipt = json.loads((evidence_dir / "pause-next-continue.json").read_text())
        timeline = receipt.get("timeline")
        starts = [item for item in timeline if isinstance(item, dict) and item.get("name") == "first_transition_start"]
        signed = (receipt.get("suite") == "pause-next-continue" and len(starts) == 1
                  and starts[0].get("status") == "detected" and starts[0].get("official_signed") is True)
    except (OSError, ValueError, TypeError, AttributeError):
        signed = False
    return "PASS" if signed else "UNVERIFIED"


def app_timeline_verdict(evidence_dir: Path) -> str:
    """Bind the official Swift judge receipt to its immutable event prefix and content PNGs.

    Timing rules live only in LifecycleTimelineJudge.swift. This reader never promotes
    an absent/malformed signature, and never reinterprets the legacy Release signature.
    """
    def check(condition):
        if not condition:
            raise ValueError("invalid App timeline signature")

    try:
        receipt = json.loads((evidence_dir / "app-timeline-verdict.json").read_text())
        check(type(receipt["schema_version"]) is int and receipt["schema_version"] == 1 and receipt["verdict"] == "PASS")
        check(receipt["suite"] == "lifecycle-pause-app-timeline")
        count = receipt["event_count"]
        check(type(count) is int and count > 0)
        lines = (evidence_dir / "playback-lifecycle-timeline.jsonl").read_bytes().splitlines(keepends=True)[:count]
        check(len(lines) == count and all(line.endswith(b"\n") for line in lines))
        check(hashlib.sha256(b"".join(lines)).hexdigest() == receipt["timeline_sha256"])
        events = [json.loads(line) for line in lines]
        check(events[0]["kind"] == "timelineStarted"
              and all(isinstance(receipt[key], str) and receipt[key] for key in ("case_nonce", "launch_nonce")))
        previous = -math.inf
        for sequence, event in enumerate(events, 1):
            check(event["schemaVersion"] == 1 and event["sequence"] == sequence)
            check(event["launchNonce"] == receipt["launch_nonce"] and event["caseNonce"] == receipt["case_nonce"])
            check(type(event["uptime"]) in (float, int) and math.isfinite(event["uptime"]) and event["uptime"] >= previous)
            previous = event["uptime"]
        judgment = receipt["judgment"]
        for key, kind in (("continueSequence", "continueReceived"), ("onsetSequence", "renderFadeStarted"),
                          ("stableSequence", "sceneStable")):
            check(type(judgment[key]) is int and 1 <= judgment[key] <= count)
            check(events[judgment[key] - 1]["kind"] == kind)
        proofs = receipt["content_checks"]
        handshake = [proof for proof in proofs if proof["name"] == "clock-handshake"]
        check(len(handshake) == 1)
        clock = handshake[0]
        check(clock["runner_request"] <= clock["app_uptime"] <= clock["runner_return"])
        check(any(event["kind"] == "clockHandshake" and event["request"] == clock["request"]
                  and event["uptime"] == clock["app_uptime"] for event in events))
        names = ("timeline-start", "timeline-midpoint-pause", "timeline-after-next", "timeline-after-hold",
                 "timeline-continue-early", "timeline-after-auto")
        for name in names:
            matches = [proof for proof in proofs if proof["name"] == name]
            check(len(matches) == 1)
            proof = matches[0]
            check(proof["status"] in {"MATCH", "FROZEN"} and proof["request"] <= proof["return"] <= events[-1]["uptime"])
            check(hashlib.sha256((evidence_dir / (name + ".png")).read_bytes()).hexdigest() == proof["png_sha256"])
            if proof["status"] == "FROZEN":
                check(hashlib.sha256((evidence_dir / (name + "-frozen-reference.png")).read_bytes()).hexdigest()
                      == proof["frozen_proof"]["frozen_reference_sha256"])
        return "PASS"
    except (OSError, ValueError, KeyError, TypeError, IndexError, AssertionError):
        return "UNVERIFIED"


def require_visual_identity(evidence_dir: Path, suite: str, *, fixture_set: str = "a") -> dict[str, object]:
    if suite in TIMELINE_LIFECYCLE_SUITES:
        payload = {"verdict": app_timeline_verdict(evidence_dir), "suite": suite}
        if payload["verdict"] != "PASS":
            payload["verdict"] = "FAIL"
            _write_visual_runner_report(evidence_dir, payload)
            raise CommandError("App timeline: missing or invalid signed evidence", code=2)
        _write_visual_runner_report(evidence_dir, payload)
        return payload
    if suite == IOS_LIFECYCLE_PAUSE_SUITE:
        payload = {"verdict": pause_timing_verdict(evidence_dir), "suite": suite}
        _write_visual_runner_report(evidence_dir, payload)
        return payload
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
            payload = evaluate_album_empty_evidence(evidence_dir, fixture_set, use_ios_album_geometry=(suite == "album-empty"))
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
            payload = evaluate_filter_visual_identity(evidence_dir, suite, fixture_set=fixture_set)
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
