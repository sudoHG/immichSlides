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
# The test selects fixture A ids and the Python evaluator checks marks against fixture A.
FIXTURE_A_ONLY_FILTER_SUITES = ("tvos-album",)
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
    if suite in (*DISPLAY_POLICY_SUITES, *LIFECYCLE_SUITES, *FIXTURE_A_ONLY_FILTER_SUITES) and fixture_set != "a":
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
