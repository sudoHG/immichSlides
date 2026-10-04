#!/usr/bin/env python3
"""Tests for the strict E2E runner's safety boundaries."""

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
    source = (REPO_ROOT / relative).read_text(encoding="utf-8")
    return set(re.findall(r"func (test\w+)\s*\(", source))


class StrictE2ERunnerTests(unittest.TestCase):
    def test_private_result_bundles_use_the_system_temporary_directory(self) -> None:
        self.assertEqual(
            PRIVATE_RESULT_BUNDLE_ROOT,
            Path(tempfile.gettempdir()) / "immichSlides-strict-e2e-private",
        )
        with tempfile.TemporaryDirectory() as raw_directory:
            private_root = Path(raw_directory) / "private"
            with mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", private_root):
                bundle_path = prepare_private_result_bundle_path("smoke")
            self.assertEqual(bundle_path.parent.parent, private_root)
            self.assertEqual(stat.S_IMODE(private_root.stat().st_mode), 0o700)

    def test_default_minimum_free_space_is_80_gib(self) -> None:
        self.assertEqual(MIN_DATA_GIB, 80)
        with tempfile.TemporaryDirectory() as temporary_directory:
            stderr = io.StringIO()
            with mock.patch("run_strict_e2e.data_available_gib", return_value=79.9), mock.patch(
                "run_strict_e2e.prepare_evidence_directory",
                side_effect=AssertionError("low disk must stop before evidence setup"),
            ):
                exit_code = runner_main(
                    [
                        "--platform", "ios",
                        "--destination", "platform=iOS Simulator,id=SIM",
                        "--evidence-dir", str(Path(temporary_directory) / "evidence"),
                    ],
                    stderr=stderr,
                )
        self.assertEqual(exit_code, 2)
        self.assertIn("--min-free-gib", stderr.getvalue())

    def test_custom_minimum_free_space_is_respected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            stderr = io.StringIO()
            with mock.patch("run_strict_e2e.data_available_gib", return_value=75), mock.patch(
                "run_strict_e2e.prepare_evidence_directory",
                side_effect=CommandError("reached post-disk setup"),
            ) as prepare_evidence:
                exit_code = runner_main(
                    [
                        "--platform", "ios",
                        "--destination", "platform=iOS Simulator,id=SIM",
                        "--evidence-dir", str(Path(temporary_directory) / "evidence"),
                        "--min-free-gib", "70",
                    ],
                    stderr=stderr,
                )
        self.assertEqual(exit_code, 2)
        self.assertIn("reached post-disk setup", stderr.getvalue())
        prepare_evidence.assert_called_once()

    def test_lifecycle_wrong_platform_fails_before_evidence_or_runtime_setup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            evidence = Path(temporary_directory) / "evidence"
            stderr = io.StringIO()
            with mock.patch(
                "run_strict_e2e.prepare_evidence_directory",
                side_effect=AssertionError("evidence setup must not run"),
            ) as prepare_evidence, mock.patch(
                "run_strict_e2e.write_fixture_artifacts",
                side_effect=AssertionError("fixture service setup must not run"),
            ) as write_fixture, mock.patch(
                "run_strict_e2e.reset_simulator_app",
                side_effect=AssertionError("simulator reset must not run"),
            ) as reset_app, mock.patch(
                "run_strict_e2e.subprocess.Popen",
                side_effect=AssertionError("fixture service must not start"),
            ) as start_process:
                exit_code = runner_main(
                    [
                        "--platform", "tvos",
                        "--destination", "platform=tvOS Simulator,id=TEST",
                        "--suite", "ios-lifecycle-settings",
                        "--evidence-dir", str(evidence),
                    ],
                    stderr=stderr,
                )

            self.assertNotEqual(exit_code, 0)
            self.assertIn("can only run on the ios platform", stderr.getvalue())
            prepare_evidence.assert_not_called()
            write_fixture.assert_not_called()
            reset_app.assert_not_called()
            start_process.assert_not_called()
            self.assertFalse(evidence.exists())

    def test_lifecycle_entries_run_existing_release_methods_and_reject_wrong_inputs(self) -> None:
        from run_strict_e2e import IOS_CASES, TVOS_CASES

        for platform, mapping in (("ios", IOS_CASES), ("tvos", TVOS_CASES)):
            for case, selector in mapping.items():
                suite = f"{platform}-lifecycle-{case}"
                with self.subTest(suite=suite):
                    self.assertIn(suite, RUNNER_SUITES)
                    validate_suite_scenario(suite, "normal")
                    with self.assertRaises(CommandError):
                        validate_suite_scenario(suite, "auth-401")
                    with self.assertRaises(CommandError):
                        validate_suite_fixture(suite, "b")
                    arguments = dict(
                        repo_root=REPO_ROOT, platform=platform, suite=suite,
                        destination="platform=iOS Simulator,id=TEST",
                        derived_data_path=Path("/evidence/DerivedData"),
                        result_bundle_path=Path("/evidence/result.xcresult"),
                        server_url="http://127.0.0.1:12345/api",
                    )
                    command = build_xcodebuild_command(**arguments)
                    self.assertIn(f"-only-testing:{selector}", command)
                    self.assertEqual(command[command.index("-configuration") + 1], "Release")
                    self.assertEqual(command[command.index("-scheme") + 1], f"immichSlides-{'iOS' if platform == 'ios' else 'tvOS'}-settings-resume")
                    self.assertIn("-skip-testing:immichSlidesTests", command)
                    target, class_name, method = selector.split("/")
                    self.assertIn(method, _swift_test_methods(f"{target}/{class_name}.swift"))
                    arguments["platform"] = "tvos" if platform == "ios" else "ios"
                    with self.assertRaises(CommandError):
                        build_xcodebuild_command(**arguments)

    def test_display_policy_suites_are_single_fixture_a_only(self) -> None:
        for suite in ("display-policy", "tvos-display-policy"):
            with self.subTest(suite=suite):
                validate_suite_fixture(suite, "a")
                with self.assertRaises(CommandError) as raised:
                    validate_suite_fixture(suite, "b")
                self.assertIn("must use public fixture A", str(raised.exception))
                self.assertEqual(CASE_E2E_IDS[suite], ["display-policy"])

    def test_album_edit_switch_is_routed_as_a_normal_visual_ui_suite(self) -> None:
        expected = {
            "ios": (
                "filter-edit-switch",
                "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom",
            ),
            "tvos": (
                "tvos-edit-switch",
                "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom",
            ),
        }
        common = {
            "repo_root": Path("/repo"),
            "derived_data_path": Path("/evidence/DerivedData"),
            "result_bundle_path": Path("/evidence/strict.xcresult"),
            "server_url": "http://127.0.0.1:12345/api",
            "evidence_dir": Path("/evidence"),
        }
        for platform, (suite, selector) in expected.items():
            with self.subTest(platform=platform):
                suites = IOS_FILTER_SUITES if platform == "ios" else TVOS_FILTER_SUITES
                self.assertEqual(suites.get(suite), selector)
                self.assertIn(suite, RUNNER_SUITES)
                self.assertEqual(CASE_E2E_IDS.get(suite), ["E2E-P0-04"])
                validate_suite_scenario(suite, "normal")
                with self.assertRaises(CommandError):
                    validate_suite_scenario(suite, "auth-401")
                command = build_xcodebuild_command(
                    **{
                        **common,
                        "destination": f"platform={'iOS' if platform == 'ios' else 'tvOS'} Simulator,id=SIM-{platform}",
                    },
                    platform=platform,
                    suite=suite,
                )
                self.assertIn(f"-only-testing:{selector}", command)
                self.assertIn("immichSlides-iOS-settings-resume" if platform == "ios" else "immichSlides-tvOS-settings-resume", command)
                self.assertIn("-configuration", command)
                self.assertIn("Release", command)
                self.assertIn("-skip-testing:immichSlidesTests", command)
                self.assertEqual(result_bundle_name(suite), f"strict-{suite}.xcresult")

    def test_settings_observing_suites_use_release_settings_resume_scheme(self) -> None:
        cases = (
            ("ios", "filter-edit-switch", "immichSlides-iOS-settings-resume"),
            ("ios", "filter-switch", "immichSlides-iOS-settings-resume"),
            ("ios", "display-policy", "immichSlides-iOS-settings-resume"),
            ("tvos", "tvos-edit-switch", "immichSlides-tvOS-settings-resume"),
            ("tvos", "tvos-switch", "immichSlides-tvOS-settings-resume"),
            ("tvos", "tvos-display-policy", "immichSlides-tvOS-settings-resume"),
        )
        for platform, suite, expected_scheme in cases:
            with self.subTest(platform=platform, suite=suite):
                command = build_xcodebuild_command(
                    repo_root=Path("/repo"),
                    platform=platform,
                    destination=f"platform={'iOS' if platform == 'ios' else 'tvOS'} Simulator,id=SIM-{platform}",
                    derived_data_path=Path("/evidence/DerivedData"),
                    result_bundle_path=Path("/evidence/strict.xcresult"),
                    server_url="http://127.0.0.1:12345/api",
                    suite=suite,
                )
                scheme_index = command.index("-scheme") + 1
                self.assertEqual(command[scheme_index], expected_scheme)
                self.assertEqual(command[command.index("-configuration") + 1], "Release")
                self.assertIn("-skip-testing:immichSlidesTests", command)
                self.assertIn("-parallel-testing-enabled", command)
                self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "NO")

        ordinary = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="ios",
            destination="platform=iOS Simulator,id=SIM-ios",
            derived_data_path=Path("/evidence/DerivedData"),
            result_bundle_path=Path("/evidence/strict.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="filter-album",
        )
        self.assertEqual(ordinary[ordinary.index("-scheme") + 1], "immichSlides-iOS")
        self.assertNotIn("-configuration", ordinary)
        self.assertNotIn("-skip-testing:immichSlidesTests", ordinary)

    def test_task_xcconfig_is_copied_only_from_managed_example_and_flags_are_zero(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            example = root / "env.example.xcconfig"
            destination = root / "env.xcconfig"
            example.write_text(
                "IMMICH_SERVER_URL = https://your-server.example.com/api\n"
                "IMMICH_API_KEY = YOUR_API_KEY\n"
                "ENABLE_DEBUG_AUTO_SERVER = 0\n"
                "ENABLE_DEBUG_FILL_APIKEY_BUTTON = 0\n",
                encoding="utf-8",
            )

            audit = prepare_task_xcconfig(example, destination)

            self.assertEqual(destination.read_bytes(), example.read_bytes())
            self.assertEqual(audit["ENABLE_DEBUG_AUTO_SERVER"], "0")
            self.assertEqual(audit["ENABLE_DEBUG_FILL_APIKEY_BUTTON"], "0")
            self.assertEqual(len(audit["source_sha256"]), 64)

    def test_existing_or_unsafe_xcconfig_fails_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            example = root / "env.example.xcconfig"
            destination = root / "env.xcconfig"
            example.write_text(
                "ENABLE_DEBUG_AUTO_SERVER = 1\nENABLE_DEBUG_FILL_APIKEY_BUTTON = 0\n",
                encoding="utf-8",
            )
            destination.write_text("PRIVATE = keep\n", encoding="utf-8")

            with self.assertRaises(CommandError):
                prepare_task_xcconfig(example, destination)
            self.assertEqual(destination.read_text(encoding="utf-8"), "PRIVATE = keep\n")

            destination.unlink()
            with self.assertRaises(CommandError):
                prepare_task_xcconfig(example, destination)
            self.assertFalse(destination.exists())

    def test_cleanup_only_deletes_unchanged_copy_of_managed_example(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            example = root / "env.example.xcconfig"
            destination = root / "env.xcconfig"
            example.write_text(
                "ENABLE_DEBUG_AUTO_SERVER = 0\nENABLE_DEBUG_FILL_APIKEY_BUTTON = 0\n",
                encoding="utf-8",
            )
            prepare_task_xcconfig(example, destination)
            cleanup_task_xcconfig(example, destination)
            self.assertFalse(destination.exists())

            destination.write_text("PRIVATE = keep\n", encoding="utf-8")
            with self.assertRaises(CommandError):
                cleanup_task_xcconfig(example, destination)
            self.assertEqual(destination.read_text(encoding="utf-8"), "PRIVATE = keep\n")

    def test_test_environment_keeps_inputs_in_runner_and_removes_forbidden_keys(self) -> None:
        source = {
            "PATH": os.environ.get("PATH", ""),
            "UI_TEST_RESET_STATE": "1",
            "IMMICH_TEST_SERVER_URL": "private",
            "IMMICH_TEST_API_KEY": "private",
        }
        environment = make_test_environment(
            source,
            server_url="http://127.0.0.1:12345/api",
            public_key="public-key",
        )

        self.assertEqual(environment["STRICT_E2E_INPUT_SERVER_URL"], "http://127.0.0.1:12345/api")
        self.assertEqual(environment["STRICT_E2E_INPUT_PUBLIC_KEY"], "public-key")
        self.assertEqual(environment["STRICT_E2E_INPUT_SCENARIO"], "normal")
        self.assertFalse(any(key.startswith("UI_TEST_") for key in environment))
        self.assertNotIn("IMMICH_TEST_SERVER_URL", environment)
        self.assertNotIn("IMMICH_TEST_API_KEY", environment)

    def test_app_launch_environment_rejects_every_forbidden_key_family(self) -> None:
        validate_app_launch_environment({})
        for key in (
            "UI_TEST_RESET_STATE",
            "UI_TEST_ANY_FUTURE_KEY",
            "IMMICH_TEST_SERVER_URL",
            "IMMICH_TEST_URL",
            "IMMICH_TEST_API_KEY",
        ):
            with self.subTest(key=key), self.assertRaises(CommandError):
                validate_app_launch_environment({key: "present"})

    def test_xcodebuild_command_targets_one_platform_smoke_and_independent_outputs(self) -> None:
        for platform, scheme, test_method in (
            ("ios", "immichSlides-iOS", "testIOSStrictE2EConnectionSmoke"),
            ("tvos", "immichSlides-tvOS", "testTVOSStrictE2EConnectionSmoke"),
        ):
            with self.subTest(platform=platform):
                command = build_xcodebuild_command(
                    repo_root=Path("/repo"),
                    platform=platform,
                    destination=f"platform={platform} Simulator,id=SIM-{platform}",
                    derived_data_path=Path(f"/evidence/{platform}/DerivedData"),
                    result_bundle_path=Path(f"/evidence/{platform}/strict.xcresult"),
                    server_url="http://127.0.0.1:12345/api",
                )
                self.assertIn(scheme, command)
                self.assertIn(f"StrictE2E-{'iOS' if platform == 'ios' else 'tvOS'}", command)
                self.assertIn("STRICT_E2E_INPUT_SERVER_URL=http://127.0.0.1:12345/api", command)
                self.assertIn("STRICT_E2E_INPUT_SCENARIO=normal", command)
                self.assertFalse(any("PUBLIC_KEY" in argument for argument in command))
                self.assertIn(
                    f"-only-testing:immichSlidesUITests/StrictE2ESmokeUITests/{test_method}",
                    command,
                )
                self.assertIn(f"/evidence/{platform}/DerivedData", command)
                self.assertIn(f"/evidence/{platform}/strict.xcresult", command)

    def test_ios_test_plan_forwards_runner_scenario_into_test_process(self) -> None:
        plan = json.loads((SCRIPT_DIR.parent / "StrictE2E-iOS.xctestplan").read_text(encoding="utf-8"))
        entries = plan["defaultOptions"]["environmentVariableEntries"]
        keys = {entry["key"]: entry["value"] for entry in entries}
        self.assertEqual(keys["STRICT_E2E_INPUT_SCENARIO"], "$(STRICT_E2E_INPUT_SCENARIO)")
        self.assertEqual(keys["STRICT_E2E_INPUT_SERVER_URL"], "$(STRICT_E2E_INPUT_SERVER_URL)")
        self.assertEqual(keys["STRICT_E2E_INPUT_PUBLIC_KEY"], "$(STRICT_E2E_INPUT_PUBLIC_KEY)")
        self.assertEqual(keys["STRICT_E2E_EVIDENCE_DIR"], "$(STRICT_E2E_EVIDENCE_DIR)")
        self.assertEqual(keys["STRICT_E2E_INPUT_SERVER_URL_B"], "$(STRICT_E2E_INPUT_SERVER_URL_B)")
        tvos_plan = json.loads((SCRIPT_DIR.parent / "StrictE2E-tvOS.xctestplan").read_text(encoding="utf-8"))
        tvos_keys = {entry["key"]: entry["value"] for entry in tvos_plan["defaultOptions"]["environmentVariableEntries"]}
        self.assertEqual(tvos_keys["STRICT_E2E_EVIDENCE_DIR"], "$(STRICT_E2E_EVIDENCE_DIR)")
        self.assertEqual(tvos_keys["STRICT_E2E_INPUT_SERVER_B_URL"], "$(STRICT_E2E_INPUT_SERVER_B_URL)")

    def test_xcodebuild_command_targets_ios_first_batch_journeys_and_rejects_tvos(self) -> None:
        common = {
            "repo_root": Path("/repo"),
            "destination": "platform=iOS Simulator,id=SIM-ios",
            "derived_data_path": Path("/evidence/ios/DerivedData"),
            "result_bundle_path": Path("/evidence/ios/strict.xcresult"),
            "server_url": "http://127.0.0.1:12345/api",
        }
        suites = {
            "journey-a": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testFirstBootSetupSurvivesColdRelaunch",
            "journey-b": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testRandomModeReachesPlaybackWithCorrectControlState",
            "firstboot-failure": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testFirstBootFailureStaysOnFirstBoot",
            "pause-window": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testSinglePhotoOutgoingPauseWindowCapture",
            "filter-album": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterAlbumTargetMembers",
            "filter-edit-switch": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom",
            "filter-empty": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterEmptySelectionCannotStart",
            "filter-person": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterPersonNormalMatch",
            "filter-switch": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterServerSwitchIsolation",
            "display-policy": "immichSlidesUITests/StrictE2EFilterIOSUITests/testSmartFillDisplayPolicyChangesMultiToSingle",
            "filter-vision": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterVisionSoloOnlyOnDevice",
        }
        for suite, selector in suites.items():
            with self.subTest(suite=suite):
                command = build_xcodebuild_command(platform="ios", suite=suite, scenario="auth-401", **common)
                self.assertIn(f"-only-testing:{selector}", command)
                self.assertIn("STRICT_E2E_INPUT_SCENARIO=auth-401", command)
                self.assertFalse(any("PUBLIC_KEY" in argument for argument in command))
                self.assertNotIn("StrictE2ESmokeUITests", " ".join(command))
                with self.assertRaises(CommandError):
                    build_xcodebuild_command(platform="tvos", suite=suite, **common)
                self.assertEqual(result_bundle_name("smoke"), "strict-smoke.xcresult")
                self.assertEqual(result_bundle_name(suite), f"strict-{suite}.xcresult")

    def test_filter_person_sessions_are_independent_first_boot_selectors(self) -> None:
        methods = _swift_test_methods("immichSlidesUITests/StrictE2EFilterIOSUITests.swift")
        self.assertNotIn("testFilterPersonRules", methods)
        self.assertEqual(
            [session["name"] for session in FILTER_PERSON_SESSIONS],
            ["normal", "conflict-normal", "nofaces"],
        )
        expected_methods = {
            "normal": "testFilterPersonNormalMatch",
            "conflict-normal": "testFilterPersonConflictNormal",
            "nofaces": "testFilterPersonNoFaces",
        }
        common = {
            "repo_root": Path("/repo"),
            "platform": "ios",
            "destination": "platform=iOS Simulator,id=SIM-ios",
            "derived_data_path": Path("/evidence/ios/DerivedData"),
            "server_url": "http://127.0.0.1:12345/api",
            "suite": "filter-person",
            "evidence_dir": Path("/evidence/ios"),
        }
        seen_selectors: list[str] = []
        for session in FILTER_PERSON_SESSIONS:
            method = expected_methods[session["name"]]
            selector = f"immichSlidesUITests/StrictE2EFilterIOSUITests/{method}"
            self.assertEqual(session["selector"], selector)
            self.assertIn(method, methods)
            bundle = Path(f"/evidence/ios/strict-filter-person-{session['name']}.xcresult")
            command = build_xcodebuild_command(
                **common,
                only_testing=selector,
                result_bundle_path=bundle,
            )
            self.assertIn(f"-only-testing:{selector}", command)
            self.assertIn(str(bundle), command)
            self.assertNotIn("testFilterPersonRules", " ".join(command))
            seen_selectors.append(selector)
        self.assertEqual(len(set(seen_selectors)), 3)
        self.assertEqual(IOS_FILTER_SUITES["filter-person"], seen_selectors[0])
        merged = merge_official_summaries(
            [
                TestResultsSummary(1, 1, 0, 0, "Passed"),
                TestResultsSummary(1, 1, 0, 0, "Passed"),
                TestResultsSummary(1, 1, 0, 0, "Passed"),
            ]
        )
        self.assertEqual(merged["totalTestCount"], 3)
        self.assertEqual(merged["passedTests"], 3)
        self.assertEqual(merged["failedTests"], 0)
        self.assertEqual(merged["skippedTests"], 0)
        self.assertEqual(merged["result"].lower(), "passed")

    def test_failure_scenarios_select_401_html_unreachable_timeout_and_out_of_order(self) -> None:
        self.assertEqual(scenario_settings("auth-401"), ("normal", WRONG_PUBLIC_API_KEY, True))
        self.assertEqual(scenario_settings("html-200"), ("html-200", "immichslides-public-e2e-key", True))
        self.assertEqual(scenario_settings("timeout"), ("timeout", "immichslides-public-e2e-key", True))
        self.assertEqual(
            scenario_settings("out-of-order"),
            ("out-of-order", "immichslides-public-e2e-key", True),
        )
        self.assertEqual(scenario_settings("unreachable")[2], False)

        url, reservation = reserve_unreachable_server_url()
        try:
            with self.assertRaises(urllib.error.URLError):
                urllib.request.urlopen(url.removesuffix("/api") + "/healthz", timeout=0.2)
        finally:
            reservation.close()

    def test_illegal_suite_scenario_combinations_are_rejected(self) -> None:
        validate_suite_scenario("firstboot-failure", "auth-401")
        validate_suite_scenario("firstboot-failure", "html-200")
        validate_suite_scenario("firstboot-failure", "unreachable")
        validate_suite_scenario("firstboot-failure", "timeout")
        validate_suite_scenario("journey-a", "normal")
        validate_suite_scenario("journey-b", "normal")
        validate_suite_scenario("pause-window", "normal")
        validate_suite_scenario("filter-album", "normal")
        validate_suite_scenario("filter-switch", "normal")
        validate_suite_scenario("filter-vision", "normal")
        validate_suite_scenario("tvos-flow", "normal")
        validate_suite_scenario("tvos-album", "normal")
        validate_suite_scenario("tvos-person", "normal")
        validate_suite_scenario("tvos-switch", "normal")
        validate_suite_scenario("smoke", "normal")
        validate_suite_scenario("late-image", "out-of-order")
        for suite, scenario in (
            ("firstboot-failure", "normal"),
            ("firstboot-failure", "out-of-order"),
            ("late-image", "normal"),
            ("late-image", "auth-401"),
            ("late-image", "timeout"),
            ("journey-a", "auth-401"),
            ("journey-b", "timeout"),
            ("pause-window", "auth-401"),
            ("filter-album", "timeout"),
            ("filter-switch", "auth-401"),
            ("tvos-flow", "timeout"),
            ("tvos-album", "auth-401"),
            ("tvos-person", "timeout"),
            ("tvos-switch", "html-200"),
            ("smoke", "html-200"),
        ):
            with self.subTest(suite=suite, scenario=scenario), self.assertRaises(CommandError) as raised:
                validate_suite_scenario(suite, scenario)
            self.assertIn("Invalid combination", str(raised.exception))

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            stderr = io.StringIO()
            exit_code = runner_main(
                [
                    "--platform",
                    "ios",
                    "--destination",
                    "platform=iOS Simulator,id=SIM-1",
                    "--evidence-dir",
                    str(evidence),
                    "--suite",
                    "firstboot-failure",
                    "--scenario",
                    "normal",
                ],
                stderr=stderr,
            )
        self.assertEqual(exit_code, 2)
        self.assertIn("Invalid combination", stderr.getvalue())
        self.assertFalse(evidence.exists())

    def test_simulator_app_container_distinguishes_absent_from_device_error(self) -> None:
        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            if command[:3] == ["xcrun", "simctl", "get_app_container"]:
                result.returncode = 1
                result.stdout = ""
                result.stderr = "Unable to lookup in current state: Shutdown"
                return result
            result.returncode = 0
            result.stdout = ""
            result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run):
            with self.assertRaises(CommandError) as raised:
                simulator_app_container("SIM-UDID", "com.331works.immichSlides")
        self.assertIn("Could not determine whether the App container exists", str(raised.exception))
        self.assertIn("Shutdown", str(raised.exception))

        def absent_run(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.returncode = 2
            result.stdout = ""
            result.stderr = "No such container"
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=absent_run):
            self.assertIsNone(simulator_app_container("SIM-UDID", "com.331works.immichSlides"))

    def test_reset_simulator_app_stops_on_second_uninstall_failure(self) -> None:
        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.stdout = ""
            if command[:3] == ["xcrun", "simctl", "uninstall"]:
                result.returncode = 149
                result.stderr = "Failed to uninstall: device service unavailable"
            else:
                result.returncode = 0
                result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            with self.assertRaises(CommandError) as raised:
                reset_simulator_app("SIM-UDID")
        self.assertIn("Second uninstall failed", str(raised.exception))
        self.assertIn("uninstall_retry_exit=149", str(raised.exception))

    def test_reset_simulator_app_stops_on_boot_failure_but_accepts_already_booted(self) -> None:
        def boot_fail(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.stdout = ""
            if command[:3] == ["xcrun", "simctl", "boot"]:
                result.returncode = 1
                result.stderr = "Unable to boot device in current state: Shutdown"
            else:
                result.returncode = 0
                result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=boot_fail), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            with self.assertRaises(CommandError) as raised:
                reset_simulator_app("SIM-UDID")
        self.assertIn("Simulator boot failed", str(raised.exception))

        calls: list[list[str]] = []

        def already_booted(command: list[str], **kwargs: object) -> mock.Mock:
            calls.append(command)
            result = mock.Mock()
            result.stdout = ""
            if command[:3] == ["xcrun", "simctl", "boot"]:
                result.returncode = 149
                result.stderr = "Unable to boot device in current state: Booted"
            elif command[:3] == ["xcrun", "simctl", "get_app_container"]:
                result.returncode = 2
                result.stderr = "No such container"
            else:
                result.returncode = 0
                result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=already_booted), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            log = reset_simulator_app("SIM-UDID")
        self.assertIn("app_container=absent", log)
        self.assertIn("boot_exit=149", log)

    def test_case_manifest_records_source_sha(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            with mock.patch(
                "run_strict_e2e.subprocess.run",
                return_value=mock.Mock(returncode=0, stdout="08aa575ed2ff28cfb0a05c6315d1d4c416440069\n", stderr=""),
            ):
                sha = read_source_sha(Path("/repo"))
            self.assertEqual(sha, "08aa575ed2ff28cfb0a05c6315d1d4c416440069")
            write_case_manifest(
                evidence,
                {
                    "source_sha": sha,
                    "platform": "ios",
                    "suite": "firstboot-failure",
                    "scenario": "auth-401",
                },
            )
            payload = json.loads((evidence / "case-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(payload["source_sha"], "08aa575ed2ff28cfb0a05c6315d1d4c416440069")
            self.assertEqual(payload["scenario"], "auth-401")

        with mock.patch(
            "run_strict_e2e.subprocess.run",
            return_value=mock.Mock(returncode=128, stdout="", stderr="not a git repo"),
        ):
            with self.assertRaises(CommandError):
                read_source_sha(Path("/repo"))

    def test_fixture_artifacts_write_independently_readable_member_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            payload = write_fixture_artifacts(evidence, "a")
            fixture = json.loads((evidence / "fixture-manifest.json").read_text(encoding="utf-8"))
            members = load_member_manifest(evidence / "member-manifest.json")
            self.assertEqual(payload["fixture_sha256"], FROZEN_FIXTURE_SHA256["a"])
            self.assertEqual(fixture["fixture_sha256"], FROZEN_FIXTURE_SHA256["a"])
            self.assertEqual(members["target_album"]["labels"], ["A1", "A2", "A3"])
            self.assertEqual(
                members["object_sets"]["albums"]["album-a-target"]["labels"],
                ["A1", "A2", "A3"],
            )
            self.assertEqual(
                members["object_sets"]["people"]["person-a-solo"]["normal"]["labels"],
                ["A2", "A3", "A5"],
            )
            self.assertEqual(
                members["object_sets"]["people"]["person-a-solo"]["soloOnly"]["labels"],
                ["A2"],
            )
            self.assertNotIn("wins", members)
            self.assertNotIn("public_api_key", fixture)
            self.assertNotIn("public_api_key", members)

    def test_reset_simulator_app_retries_uninstall_and_records_log(self) -> None:
        calls: list[list[str]] = []

        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            calls.append(command)
            result = mock.Mock()
            result.stdout = ""
            uninstall_count = sum(1 for item in calls if item[:3] == ["xcrun", "simctl", "uninstall"])
            if command[:3] == ["xcrun", "simctl", "uninstall"] and uninstall_count == 1:
                result.returncode = 149
                result.stderr = "Failed to uninstall: Application not found"
            elif command[:3] == ["xcrun", "simctl", "get_app_container"]:
                result.returncode = 2
                result.stderr = "No such container"
            else:
                result.returncode = 0
                result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            log = reset_simulator_app("SIM-UDID")

        self.assertIn("simulator_id=SIM-UDID", log)
        self.assertIn("uninstall_exit=149", log)
        self.assertIn("uninstall_retry_exit=0", log)
        self.assertIn("app_container=absent", log)
        self.assertTrue(any(command[:3] == ["xcrun", "simctl", "boot"] for command in calls))
        self.assertTrue(any(command[:3] == ["xcrun", "simctl", "terminate"] for command in calls))
        self.assertEqual(sum(1 for command in calls if command[:3] == ["xcrun", "simctl", "uninstall"]), 2)

    def test_reset_simulator_app_fails_when_container_still_exists(self) -> None:
        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.stderr = ""
            if command[:3] == ["xcrun", "simctl", "get_app_container"]:
                result.returncode = 0
                result.stdout = "/sim/containers/immichSlides\n"
            else:
                result.returncode = 0
                result.stdout = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            with self.assertRaises(CommandError) as raised:
                reset_simulator_app("SIM-UDID")
        self.assertIn("App container is still accessible after uninstall", str(raised.exception))

    def test_nonempty_evidence_directory_is_rejected_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            evidence.mkdir()
            protected = evidence / "existing.json"
            protected.write_text('{"keep": true}\n', encoding="utf-8")

            with self.assertRaises(CommandError):
                prepare_evidence_directory(evidence)

            self.assertEqual(protected.read_text(encoding="utf-8"), '{"keep": true}\n')
            self.assertEqual([path.name for path in evidence.iterdir()], ["existing.json"])

    def test_sensitive_scan_records_only_key_names_and_rejects_values(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "safe.log").write_text(
                "STRICT_E2E_INPUT_PUBLIC_KEY=<redacted>\n",
                encoding="utf-8",
            )

            write_sensitive_scan(evidence, ["immichslides-public-e2e-key", WRONG_PUBLIC_API_KEY])

            scan_path = evidence / "sensitive-scan.json"
            scan_text = scan_path.read_text(encoding="utf-8")
            scan = json.loads(scan_text)
            self.assertEqual(scan["checked_key_names"], ["STRICT_E2E_INPUT_PUBLIC_KEY"])
            self.assertEqual(scan["matched_files"], [])
            self.assertNotIn("immichslides-public-e2e-key", scan_text)

            derived_data = evidence / "DerivedData"
            derived_data.mkdir()
            (derived_data / "unsafe.log").write_text(WRONG_PUBLIC_API_KEY, encoding="utf-8")
            with self.assertRaises(CommandError):
                write_sensitive_scan(evidence, ["immichslides-public-e2e-key", WRONG_PUBLIC_API_KEY])

    def test_sensitive_scan_rejects_unreadable_directory(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            unreadable = evidence / "unreadable"
            unreadable.mkdir()
            (unreadable / "hidden.log").write_text("hidden", encoding="utf-8")
            unreadable.chmod(0)
            try:
                with self.assertRaises(CommandError):
                    write_sensitive_scan(evidence, [WRONG_PUBLIC_API_KEY])
            finally:
                unreadable.chmod(0o700)

    def test_sensitive_scan_ignores_key_pattern_in_compressed_bytes(self) -> None:
        logical = b"<?xml version=\"1.0\"?><plist><string>ok</string></plist>"
        skippable = (0x184D2A50).to_bytes(4, "little") + len(WRONG_PUBLIC_API_KEY).to_bytes(
            4, "little"
        ) + WRONG_PUBLIC_API_KEY.encode("utf-8")
        compressed = subprocess.run(
            ["zstd", "-q", "-c"],
            input=logical,
            check=True,
            capture_output=True,
        ).stdout
        blob = skippable + compressed
        self.assertIn(WRONG_PUBLIC_API_KEY.encode("utf-8"), blob)
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "xcresult-data.bin").write_bytes(blob)
            write_sensitive_scan(evidence, [WRONG_PUBLIC_API_KEY])
            scan = json.loads((evidence / "sensitive-scan.json").read_text(encoding="utf-8"))
            self.assertEqual(scan["result"], "PASS")
            self.assertEqual(scan["matched_files"], [])
            self.assertNotIn(WRONG_PUBLIC_API_KEY, (evidence / "sensitive-scan.json").read_text(encoding="utf-8"))

    def test_sensitive_scan_fails_when_decompressed_content_has_key(self) -> None:
        logical = f"key={WRONG_PUBLIC_API_KEY}\n".encode("utf-8")
        blob = subprocess.run(
            ["zstd", "-q", "-c"],
            input=logical,
            check=True,
            capture_output=True,
        ).stdout
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "xcresult-data.bin").write_bytes(blob)
            with self.assertRaises(CommandError) as raised:
                write_sensitive_scan(evidence, [WRONG_PUBLIC_API_KEY])
            self.assertNotIn(WRONG_PUBLIC_API_KEY, str(raised.exception))
            scan = json.loads((evidence / "sensitive-scan.json").read_text(encoding="utf-8"))
            self.assertEqual(scan["result"], "FAIL")
            self.assertEqual(scan["matched_files"], ["xcresult-data.bin"])
            self.assertNotIn(WRONG_PUBLIC_API_KEY, (evidence / "sensitive-scan.json").read_text(encoding="utf-8"))

    def test_cleanup_failure_never_replaces_primary_failure_exit_code(self) -> None:
        completed: list[str] = []

        def fail_cleanup() -> None:
            raise OSError("first cleanup failed")

        failures = run_cleanup_actions(
            [
                ("first", fail_cleanup),
                ("second", lambda: completed.append("second")),
            ]
        )

        self.assertEqual(completed, ["second"])
        self.assertEqual(len(failures), 1)
        self.assertEqual(choose_exit_code(65, ["cleanup failed"]), 65)
        self.assertEqual(choose_exit_code(0, ["cleanup failed"]), 2)
        self.assertEqual(choose_exit_code(0, []), 0)

    def test_sensitive_scan_failure_never_replaces_primary_failure_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            stderr = io.StringIO()
            with (
                mock.patch("run_strict_e2e.data_available_gib", return_value=100),
                mock.patch(
                    "run_strict_e2e.prepare_task_xcconfig",
                    side_effect=CommandError("primary xcodebuild failure", code=65),
                ),
                mock.patch("run_strict_e2e.os.walk", side_effect=OSError("scan traversal failed")),
            ):
                exit_code = runner_main(
                    [
                        "--platform",
                        "ios",
                        "--destination",
                        "platform=iOS Simulator,id=SIM-1",
                        "--evidence-dir",
                        str(evidence),
                    ],
                    stderr=stderr,
                )

            self.assertEqual(exit_code, 65)
            self.assertIn("primary xcodebuild failure", stderr.getvalue())
            self.assertIn("sensitive_scan", stderr.getvalue())

    def test_runner_reports_evidence_io_failure_without_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            blocking_file = Path(raw_directory) / "not-a-directory"
            blocking_file.write_text("keep", encoding="utf-8")
            stderr = io.StringIO()
            with mock.patch("run_strict_e2e.data_available_gib", return_value=100):
                exit_code = runner_main(
                    [
                        "--platform",
                        "ios",
                        "--destination",
                        "platform=iOS Simulator,id=SIM-1",
                        "--evidence-dir",
                        str(blocking_file / "evidence"),
                    ],
                    stderr=stderr,
                )

            self.assertEqual(exit_code, 2)
            self.assertIn("Evidence or process I/O failed", stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())

    def test_tvos_flow_suite_targets_core_playback_and_rejects_ios(self) -> None:
        command = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="tvos",
            destination="platform=tvOS Simulator,id=SIM-tvos",
            derived_data_path=Path("/evidence/tvos/DerivedData"),
            result_bundle_path=Path("/evidence/tvos/strict.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="tvos-flow",
            evidence_dir=Path("/evidence/tvos"),
        )
        self.assertIn(
            "-only-testing:immichSlidesUITests/StrictE2ETVOSFlowUITests/testTVOSFirstBootModeSelectionAndCorePlayback",
            command,
        )
        self.assertIn("STRICT_E2E_EVIDENCE_DIR=/evidence/tvos", command)
        self.assertEqual(result_bundle_name("tvos-flow"), "strict-tvos-flow.xcresult")
        with self.assertRaises(CommandError) as raised:
            build_xcodebuild_command(
                repo_root=Path("/repo"),
                platform="ios",
                destination="platform=iOS Simulator,id=SIM-ios",
                derived_data_path=Path("/evidence/ios/DerivedData"),
                result_bundle_path=Path("/evidence/ios/strict.xcresult"),
                server_url="http://127.0.0.1:12345/api",
                suite="tvos-flow",
            )
        self.assertIn("tvOS flow", str(raised.exception))

    def test_tvos_filter_suites_target_filter_class_and_reject_ios(self) -> None:
        common = {
            "repo_root": Path("/repo"),
            "destination": "platform=tvOS Simulator,id=SIM-tvos",
            "derived_data_path": Path("/evidence/tvos/DerivedData"),
            "result_bundle_path": Path("/evidence/tvos/strict.xcresult"),
            "server_url": "http://127.0.0.1:12345/api",
            "evidence_dir": Path("/evidence/tvos"),
        }
        expected = {
            "tvos-album": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSTargetAlbumPlaybackAndEmptyStart",
            "tvos-edit-switch": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom",
            "tvos-person": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSPersonRules",
            "tvos-switch": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSServerSwitchIsolation",
            "tvos-display-policy": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSSmartFillDisplayPolicyChangesMultiToSingle",
        }
        for suite, selector in expected.items():
            with self.subTest(suite=suite):
                command = build_xcodebuild_command(platform="tvos", suite=suite, **common)
                self.assertIn(f"-only-testing:{selector}", command)
                self.assertEqual(result_bundle_name(suite), f"strict-{suite}.xcresult")
                with self.assertRaises(CommandError):
                    build_xcodebuild_command(
                        platform="ios",
                        suite=suite,
                        repo_root=Path("/repo"),
                        destination="platform=iOS Simulator,id=SIM-ios",
                        derived_data_path=Path("/evidence/ios/DerivedData"),
                        result_bundle_path=Path("/evidence/ios/strict.xcresult"),
                        server_url="http://127.0.0.1:12345/api",
                    )
        command = build_xcodebuild_command(
            platform="tvos",
            suite="tvos-switch",
            server_b_url="http://127.0.0.1:23456/api",
            **common,
        )
        self.assertIn("STRICT_E2E_INPUT_SERVER_B_URL=http://127.0.0.1:23456/api", command)
        environment = make_test_environment(
            {"PATH": "/bin"},
            server_url="http://127.0.0.1:12345/api",
            public_key="immichslides-public-e2e-key",
            server_b_url="http://127.0.0.1:23456/api",
        )
        self.assertEqual(environment["STRICT_E2E_INPUT_SERVER_B_URL"], "http://127.0.0.1:23456/api")

    def test_late_image_ios_selector_allows_out_of_order(self) -> None:
        self.assertIn("late-image", RUNNER_SUITES)
        self.assertEqual(CASE_E2E_IDS["late-image"], ["E2E-P0-07"])
        self.assertEqual(
            IOS_LATE_IMAGE_SUITES["late-image"],
            "immichSlidesUITests/StrictE2ELateImageIOSUITests/testLateImageKeepsCurrentSceneAfterLateRequest",
        )
        validate_suite_scenario("late-image", "out-of-order")
        with self.assertRaises(CommandError) as raised:
            validate_suite_scenario("late-image", "normal")
        self.assertIn("Invalid combination", str(raised.exception))
        command = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="ios",
            destination="platform=iOS Simulator,id=SIM-ios",
            derived_data_path=Path("/evidence/ios/DerivedData"),
            result_bundle_path=Path("/evidence/ios/strict-late-image.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="late-image",
            scenario="out-of-order",
        )
        self.assertIn(
            "-only-testing:immichSlidesUITests/StrictE2ELateImageIOSUITests/testLateImageKeepsCurrentSceneAfterLateRequest",
            command,
        )
        self.assertIn("STRICT_E2E_INPUT_SCENARIO=out-of-order", command)
        self.assertEqual(result_bundle_name("late-image"), "strict-late-image.xcresult")
        self.assertNotIn("StrictE2ELateImageTVOSUITests", " ".join(command))
        methods = _swift_test_methods("immichSlidesUITests/StrictE2ELateImageIOSUITests.swift")
        self.assertIn("testLateImageKeepsCurrentSceneAfterLateRequest", methods)

    def test_late_image_tvos_selector_allows_out_of_order(self) -> None:
        command = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="tvos",
            destination="platform=tvOS Simulator,id=SIM-tvos",
            derived_data_path=Path("/evidence/tvos/DerivedData"),
            result_bundle_path=Path("/evidence/tvos/strict-late-image.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="late-image",
            scenario="out-of-order",
            evidence_dir=Path("/evidence/tvos"),
        )
        self.assertIn(
            "-only-testing:immichSlidesUITests/StrictE2ELateImageTVOSUITests/testTVOSLateImageDoesNotFlashBack",
            command,
        )
        self.assertIn("STRICT_E2E_INPUT_SCENARIO=out-of-order", command)
        self.assertEqual(result_bundle_name("late-image"), "strict-late-image.xcresult")
        self.assertEqual(
            TVOS_LATE_IMAGE_SUITES["late-image"],
            "immichSlidesUITests/StrictE2ELateImageTVOSUITests/testTVOSLateImageDoesNotFlashBack",
        )
        self.assertNotIn("StrictE2ELateImageIOSUITests", " ".join(command))
        methods = _swift_test_methods("immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift")
        self.assertIn("testTVOSLateImageDoesNotFlashBack", methods)

    def test_xcodebuild_command_never_collects_test_diagnostics(self) -> None:
        command = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="ios",
            destination="platform=iOS Simulator,id=SIM-ios",
            derived_data_path=Path("/evidence/ios/DerivedData"),
            result_bundle_path=Path("/evidence/ios/strict-late-image.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="late-image",
            scenario="out-of-order",
        )
        flag_index = command.index("-collect-test-diagnostics")
        self.assertEqual(command[flag_index + 1], "never")
        self.assertLess(flag_index, command.index("test"))

    def test_run_command_times_out_instead_of_waiting_unbounded(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            log_path = Path(raw_directory) / "xcodebuild.log"
            with mock.patch(
                "run_strict_e2e.subprocess.run",
                return_value=mock.Mock(returncode=0),
            ) as mocked:
                exit_code = run_command(
                    ["xcodebuild", "test"],
                    cwd=Path(raw_directory),
                    environment={"PATH": "/usr/bin"},
                    log_path=log_path,
                )
            self.assertEqual(exit_code, 0)
            timeout = mocked.call_args.kwargs.get("timeout")
            self.assertIsNotNone(timeout)
            self.assertGreaterEqual(timeout, 240)
            self.assertLess(timeout, 600)

            with mock.patch(
                "run_strict_e2e.subprocess.run",
                side_effect=subprocess.TimeoutExpired(cmd=["xcodebuild"], timeout=300),
            ):
                with self.assertRaises(CommandError) as raised:
                    run_command(
                        ["xcodebuild", "test"],
                        cwd=Path(raw_directory),
                        environment={"PATH": "/usr/bin"},
                        log_path=log_path,
                    )
            self.assertIn("timed out", str(raised.exception))

    def test_runner_suite_selectors_equal_swift_test_funcs(self) -> None:
        suites = (
            (
                IOS_FIRST_BATCH_SUITES,
                "immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift",
                "StrictE2EFirstBatchIOSUITests",
            ),
            (
                IOS_FILTER_SUITES,
                "immichSlidesUITests/StrictE2EFilterIOSUITests.swift",
                "StrictE2EFilterIOSUITests",
            ),
            (
                IOS_LATE_IMAGE_SUITES,
                "immichSlidesUITests/StrictE2ELateImageIOSUITests.swift",
                "StrictE2ELateImageIOSUITests",
            ),
            (
                TVOS_FLOW_SUITES,
                "immichSlidesUITests/StrictE2ETVOSFlowUITests.swift",
                "StrictE2ETVOSFlowUITests",
            ),
            (
                TVOS_LATE_IMAGE_SUITES,
                "immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift",
                "StrictE2ELateImageTVOSUITests",
            ),
            (
                TVOS_CONTROL_SUITES,
                "immichSlidesUITests/FilterSummaryTVOSVisualUITests.swift",
                "FilterSummaryTVOSVisualUITests",
            ),
            (
                TVOS_FILTER_SUITES,
                "immichSlidesUITests/StrictE2EFilterTVOSUITests.swift",
                "StrictE2EFilterTVOSUITests",
            ),
        )
        for mapping, swift_file, class_name in suites:
            methods = _swift_test_methods(swift_file)
            for suite, selector in mapping.items():
                with self.subTest(suite=suite):
                    prefix = f"immichSlidesUITests/{class_name}/"
                    self.assertTrue(selector.startswith(prefix), selector)
                    method = selector[len(prefix) :]
                    self.assertIn(method, methods)

    def test_filter_suites_forward_peer_url_and_accept_simulator_vision_unverified(self) -> None:
        command = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="ios",
            destination="platform=iOS Simulator,id=SIM-ios",
            derived_data_path=Path("/evidence/ios/DerivedData"),
            result_bundle_path=Path("/evidence/ios/strict.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="filter-switch",
            evidence_dir=Path("/evidence/ios"),
            server_url_b="http://127.0.0.1:12346/api",
        )
        self.assertIn(
            "-only-testing:immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterServerSwitchIsolation",
            command,
        )
        self.assertIn("STRICT_E2E_INPUT_SERVER_URL_B=http://127.0.0.1:12346/api", command)
        environment = make_test_environment(
            {},
            server_url="http://127.0.0.1:12345/api",
            public_key="immichslides-public-e2e-key",
            server_url_b="http://127.0.0.1:12346/api",
        )
        self.assertEqual(environment["STRICT_E2E_INPUT_SERVER_URL_B"], "http://127.0.0.1:12346/api")
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            write_member_manifest(evidence / "member-manifest.json", "a")
            (evidence / "vision-environment.json").write_text(
                json.dumps({"environment": "simulator", "vision_available": True}),
                encoding="utf-8",
            )
            report = require_visual_identity(evidence, "filter-vision")
            self.assertEqual(report["verdict"], "UNVERIFIED")
            self.assertNotEqual(report["verdict"], "PASS")

    def test_out_of_order_runner_audit_and_identity_fail_closed(self) -> None:
        with self.assertRaises(CommandError) as raised:
            audit_out_of_order_runner_inputs(
                fixture_set="a",
                observed_hash=FROZEN_FIXTURE_SHA256["a"],
                service_log=(
                    "request elapsed_ms=1 method=GET path=/unknown-route "
                    "status=404 range=absent fixture_asset_id=none\n"
                ),
                server_url="http://127.0.0.1:9/api",
            )
        self.assertIn("Unknown request", str(raised.exception))

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            with self.assertRaises(CommandError) as raised:
                require_visual_identity(evidence, "late-image")
            self.assertIn("Visual assertion failed; cannot mark SUCCESS", str(raised.exception))
            self.assertIn("Missing required timeline screenshots", str(raised.exception))
            report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(report["verdict"], "FAIL")

            current = _fixture_data("a")["images"]["asset-a-3"]
            (evidence / "ooo-current-scene.png").write_bytes(current)
            (evidence / "ooo-after-late.png").write_bytes(current)
            (evidence / "redacted-request.log").write_text(
                "request_started elapsed_ms=10 method=GET path=/api/assets/<fixture-id>/thumbnail "
                "size=preview range=absent fixture_asset_id=asset-a-1\n"
                "request_started elapsed_ms=40 method=GET path=/api/assets/<fixture-id>/thumbnail "
                "size=preview range=absent fixture_asset_id=asset-a-2\n"
                "request elapsed_ms=45 method=GET path=/api/assets/<fixture-id>/thumbnail "
                "status=200 range=absent fixture_asset_id=asset-a-2\n"
                "request elapsed_ms=320 method=GET path=/api/assets/<fixture-id>/thumbnail "
                "status=200 range=absent fixture_asset_id=asset-a-1\n",
                encoding="utf-8",
            )
            write_fixture_artifacts(evidence, "a")
            (evidence / "runner-server-url.txt").write_text("http://127.0.0.1:9/api\n", encoding="utf-8")
            report = require_visual_identity(evidence, "late-image")
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["mark"], "A3")
            self.assertEqual(report["identity_source"], "public_fixture_photo_mark")

            (evidence / "ooo-after-late.png").write_bytes(_fixture_data("a")["images"]["asset-a-1"])
            with self.assertRaises(CommandError) as flashback:
                require_visual_identity(evidence, "late-image")
            self.assertIn("Wrong image", str(flashback.exception))
            flashback_report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(flashback_report["verdict"], "FAIL")

    def test_visual_identity_blocks_success_when_screenshots_are_missing_or_wrong(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            skipped = require_visual_identity(evidence, "smoke")
            self.assertEqual(skipped["verdict"], "NOT_REQUIRED")
            with self.assertRaises(CommandError) as raised:
                require_visual_identity(evidence, "journey-b")
            self.assertIn("Visual assertion failed; cannot mark SUCCESS", str(raised.exception))
            report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(report["verdict"], "FAIL")

            with self.assertRaises(CommandError) as raised:
                require_visual_identity(evidence, "tvos-album")
            self.assertIn("Visual assertion failed; cannot mark SUCCESS", str(raised.exception))

            with self.assertRaises(CommandError) as raised:
                require_visual_identity(evidence, "tvos-person")
            self.assertIn("Visual assertion failed; cannot mark SUCCESS", str(raised.exception))

    def test_pause_window_rejects_wrong_or_unreadable_window_detected(self) -> None:
        a5 = _fixture_data("a")["images"]["asset-a-5"]
        cases = {
            "black": _rgb_png((0, 0, 0)),
            "blank": _rgb_png((255, 255, 255)),
            "unrecognizable": b"not-a-png",
            "wrong-photo": a5,
        }
        for label, window_png in cases.items():
            with self.subTest(window=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                _write_pause_window_evidence(evidence, window_png)
                with self.assertRaises(CommandError) as raised:
                    require_visual_identity(evidence, "pause-window")
                self.assertIn("Visual assertion failed; cannot mark SUCCESS", str(raised.exception))
                self.assertIn("Target window", str(raised.exception))
                report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
                self.assertEqual(report["verdict"], "FAIL")

    def test_help_and_smoke_do_not_need_pillow(self) -> None:
        help_result = _run_runner_without_site("--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertNotIn("ModuleNotFoundError", help_result.stderr)
        self.assertNotIn("No module named 'PIL'", help_result.stderr + help_result.stdout)
        self.assertIn("usage:", help_result.stdout.lower())

        smoke = _run_code_without_site(
            "\n".join(
                [
                    "import sys, tempfile",
                    "from pathlib import Path",
                    "sys.path.insert(0, sys.argv[1])",
                    "from run_strict_e2e import require_visual_identity",
                    "report = require_visual_identity(Path(tempfile.mkdtemp()), 'smoke')",
                    "assert report['verdict'] == 'NOT_REQUIRED', report",
                    "print('SMOKE_OK')",
                ]
            )
        )
        self.assertEqual(smoke.returncode, 0, smoke.stderr)
        self.assertIn("SMOKE_OK", smoke.stdout)
        self.assertNotIn("ModuleNotFoundError", smoke.stderr)
        self.assertNotIn("No module named 'PIL'", smoke.stderr + smoke.stdout)

    def test_visual_suite_without_pillow_fails_with_install_hint(self) -> None:
        result = _run_code_without_site(
            "\n".join(
                [
                    "import sys, tempfile",
                    "from pathlib import Path",
                    "sys.path.insert(0, sys.argv[1])",
                    "from run_strict_e2e import CommandError, require_visual_identity",
                    "from strict_e2e_server import _fixture_data",
                    "png = _fixture_data('a')['images']['asset-a-2']",
                    "evidence = Path(tempfile.mkdtemp())",
                    "for name in ('window-detected', 'after-pause', 'after-pause-0_3s'):",
                    "    (evidence / f'{name}.png').write_bytes(png)",
                    "try:",
                    "    require_visual_identity(evidence, 'pause-window')",
                    "except CommandError as error:",
                    "    text = str(error)",
                    "    print(text)",
                    "    raise SystemExit(0 if 'Pillow' in text else 2)",
                    "print('UNEXPECTED_PASS')",
                    "raise SystemExit(3)",
                ]
            )
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Pillow", result.stdout)
        self.assertNotIn("UNEXPECTED_PASS", result.stdout)
        self.assertNotIn("Traceback", result.stderr)

    def test_official_count_requires_exactly_one_non_skipped_pass(self) -> None:
        require_official_single_pass(TestResultsSummary(1, 1, 0, 0, "Passed"))
        for summary in (
            TestResultsSummary(0, 0, 0, 0, "Passed"),
            TestResultsSummary(1, 0, 0, 1, "Passed"),
            TestResultsSummary(1, 0, 1, 0, "Failed"),
        ):
            with self.subTest(summary=summary), self.assertRaises(CommandError):
                require_official_single_pass(summary)


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


class StrictE2EP2RunnerTests(unittest.TestCase):
    def test_p2_suites_route_to_selected_method_and_record_e2e_ids(self) -> None:
        common = {
            "repo_root": Path("/repo"),
            "derived_data_path": Path("/evidence/DerivedData"),
            "result_bundle_path": Path("/evidence/strict.xcresult"),
            "server_url": "http://127.0.0.1:12345/api",
            "evidence_dir": Path("/evidence"),
        }
        for suite, case in P2_CASES.items():
            self.assertIn(suite, RUNNER_SUITES)
            self.assertEqual(result_bundle_name(suite), f"strict-{suite}.xcresult")
            self.assertEqual(CASE_E2E_IDS[suite], list(case.e2e_ids))
            validate_suite_scenario(suite, "normal")
            for platform, selector in case.selectors.items():
                with self.subTest(suite=suite, platform=platform):
                    destination = f"platform={'tvOS' if platform == 'tvos' else 'iOS'} Simulator,id=SIM"
                    command = build_xcodebuild_command(
                        platform=platform, destination=destination, suite=suite, **common
                    )
                    self.assertEqual([item for item in command if item.startswith("-only-testing:")], [f"-only-testing:{selector}"])
                    self.assertIn("STRICT_E2E_EVIDENCE_DIR=/evidence", command)
        with self.assertRaises(CommandError):
            build_xcodebuild_command(
                platform="tvos", destination="platform=tvOS Simulator,id=SIM", suite="p2-rotation", **common
            )
        with self.assertRaises(CommandError):
            validate_suite_scenario("p2-cache", "timeout")

    def test_wrong_platform_or_scenario_fails_before_any_side_effect(self) -> None:
        for arguments in (
            ["--platform", "tvos", "--destination", "platform=tvOS Simulator,id=SIM", "--suite", "p2-ipad-layout"],
            ["--platform", "tvos", "--destination", "platform=tvOS Simulator,id=SIM", "--suite", "p2-rotation"],
            ["--platform", "ios", "--destination", "platform=iOS Simulator,id=SIM", "--suite", "p2-exif", "--scenario", "timeout"],
        ):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory) / "evidence"
                stderr = io.StringIO()
                with mock.patch("run_strict_e2e.data_available_gib") as disk, mock.patch(
                    "run_strict_e2e.reset_simulator_app"
                ) as reset:
                    exit_code = runner_main([*arguments, "--evidence-dir", str(evidence)], stderr=stderr)
                self.assertEqual(exit_code, 2)
                self.assertFalse(evidence.exists())
                disk.assert_not_called()
                reset.assert_not_called()
                self.assertTrue(stderr.getvalue().strip())

    def test_source_dirty_paths_come_from_git_porcelain_and_fail_closed(self) -> None:
        with mock.patch(
            "run_strict_e2e.subprocess.run",
            return_value=subprocess.CompletedProcess([], 0, " M scripts/a.py\n?? scripts/new.py\n", ""),
        ) as mocked:
            self.assertEqual(read_source_dirty_paths(Path("/repo")), [" M scripts/a.py", "?? scripts/new.py"])
        self.assertEqual(
            mocked.call_args.args[0],
            ["git", "-C", "/repo", "status", "--porcelain=v1", "--untracked-files=all"],
        )
        with mock.patch(
            "run_strict_e2e.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "", "")
        ):
            self.assertEqual(read_source_dirty_paths(Path("/repo")), [])
        with mock.patch(
            "run_strict_e2e.subprocess.run", return_value=subprocess.CompletedProcess([], 128, "", "fatal")
        ), self.assertRaises(CommandError):
            read_source_dirty_paths(Path("/repo"))

    def test_screen_recording_waits_for_start_and_sigints_the_exact_process(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            video = Path(raw_directory) / "screen-recording.mov"
            log = Path(raw_directory) / "screen-recording.log"
            process = mock.Mock(pid=4321)
            process.poll.return_value = None
            process.wait.return_value = 0

            def fake_popen(command: list[str], **kwargs: object) -> mock.Mock:
                kwargs["stdout"].write(b"Recording started\n")
                return process

            with mock.patch("run_strict_e2e.subprocess.Popen", side_effect=fake_popen) as popen:
                started_process, started_wall_time = start_screen_recording("SIM-1", video, log)
            self.assertIs(started_process, process)
            self.assertGreater(started_wall_time, 0)
            self.assertEqual(
                popen.call_args.args[0],
                ["xcrun", "simctl", "io", "SIM-1", "recordVideo", "--codec=h264", "--force", str(video)],
            )

            self.assertEqual(stop_screen_recording(process), 0)
            process.send_signal.assert_called_once_with(signal.SIGINT)
            process.terminate.assert_not_called()
            process.kill.assert_not_called()

            stuck = mock.Mock(pid=4322)
            stuck.poll.return_value = None
            stuck.wait.side_effect = [subprocess.TimeoutExpired(cmd="simctl", timeout=1), -9]
            with self.assertRaises(CommandError) as raised:
                stop_screen_recording(stuck)
            self.assertIn("recording", str(raised.exception))
            stuck.kill.assert_called_once()

            silent = mock.Mock(pid=4323)
            silent.poll.return_value = None
            silent.wait.return_value = 0
            with mock.patch("run_strict_e2e.subprocess.Popen", return_value=silent), mock.patch(
                "run_strict_e2e.RECORDING_START_TIMEOUT_SECONDS", 0.2
            ), self.assertRaises(CommandError):
                start_screen_recording("SIM-1", video, log)
            self.assertTrue(silent.send_signal.called or silent.terminate.called or silent.kill.called)

            exited = mock.Mock(pid=4324, returncode=1)
            exited.poll.return_value = 1
            with mock.patch("run_strict_e2e.subprocess.Popen", return_value=exited), self.assertRaises(
                CommandError
            ) as raised:
                start_screen_recording("SIM-1", video, log)
            self.assertIn("exit 1", str(raised.exception))

            unreadable = mock.Mock(pid=4325)
            unreadable.poll.return_value = None
            unreadable.wait.return_value = 0
            with mock.patch("run_strict_e2e.subprocess.Popen", return_value=unreadable), mock.patch.object(
                Path, "read_bytes", side_effect=OSError("log unreadable")
            ), self.assertRaises(OSError):
                start_screen_recording("SIM-1", video, log)
            unreadable.terminate.assert_called_once()

            ended_early = mock.Mock(pid=4326, returncode=0)
            ended_early.poll.return_value = 0
            with self.assertRaises(CommandError) as raised:
                stop_screen_recording(ended_early)
            self.assertIn("before the test finished", str(raised.exception))
            ended_early.send_signal.assert_not_called()

    def _run_p2_main(
        self,
        evidence: Path,
        *,
        suite: str,
        platform: str,
        model: str,
        skip: tuple[str, ...] = (),
        facts_device_id: str = P2_UDID,
        xcodebuild_exit: int = 0,
        create_result_bundle: bool = False,
        export_exit: int = 0,
    ) -> tuple[int, str, str, dict[str, mock.Mock]]:
        destination = f"platform={'tvOS' if platform == 'tvos' else 'iOS'} Simulator,id={P2_UDID}"
        selector = P2_CASES[suite].selectors[platform]
        recording_process = mock.Mock(pid=9876)

        def fake_run_command(command: list[str], **_: object) -> int:
            self.assertEqual([item for item in command if item.startswith("-only-testing:")], [f"-only-testing:{selector}"])
            _write_p2_ui_outputs(evidence, suite, skip=skip)
            if create_result_bundle:
                bundle = Path(command[command.index("-resultBundlePath") + 1])
                self.assertEqual(bundle.parent.parent, evidence.parent / "private")
                bundle.mkdir()
                (bundle / "raw.bin").write_bytes(b"raw diagnostics")
            return xcodebuild_exit

        def fake_subprocess(command: list[str], **_: object) -> subprocess.CompletedProcess[object]:
            if command[:2] == ["xcrun", "xcresulttool"]:
                return subprocess.CompletedProcess(command, export_exit, b'{"testNodes":[]}', b"")
            return subprocess.CompletedProcess(command, 0, "", "")

        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", evidence.parent / "private"), mock.patch(
            "run_strict_e2e.data_available_gib", return_value=100
        ), mock.patch(
            "run_strict_e2e.read_source_sha", return_value="0" * 40
        ), mock.patch("run_strict_e2e.read_source_dirty_paths", return_value=[]) as dirty, mock.patch(
            "run_strict_e2e.prepare_task_xcconfig", return_value={}
        ), mock.patch("run_strict_e2e.cleanup_task_xcconfig"), mock.patch(
            "run_strict_e2e.subprocess.run", side_effect=fake_subprocess
        ), mock.patch("run_strict_e2e.reset_simulator_app", return_value="reset\n"), mock.patch(
            "run_strict_e2e.run_command", side_effect=fake_run_command
        ), mock.patch(
            "run_strict_e2e.read_official_test_results_summary",
            return_value=TestResultsSummary(1, 1, 0, 0, "Passed"),
        ), mock.patch(
            "run_strict_e2e.read_xcresult_facts",
            return_value=_p2_facts(suite, platform, model, facts_device_id),
        ) as facts, mock.patch(
            "run_strict_e2e.start_screen_recording", return_value=(recording_process, 900.0)
        ) as start, mock.patch("run_strict_e2e.stop_screen_recording", return_value=0) as stop:
            exit_code = runner_main(
                [
                    "--platform",
                    platform,
                    "--destination",
                    destination,
                    "--evidence-dir",
                    str(evidence),
                    "--suite",
                    suite,
                ],
                stdout=stdout,
                stderr=stderr,
            )
        return exit_code, stdout.getvalue(), stderr.getvalue(), {
            "dirty": dirty,
            "facts": facts,
            "start": start,
            "stop": stop,
            "recording_process": recording_process,
        }

    def test_p2_main_runs_selected_method_and_only_reports_review_required(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "p2-exif-iphone"
            exit_code, _stdout, stderr, mocks = self._run_p2_main(
                evidence, suite="p2-exif", platform="ios", model="iPhone 17 Pro"
            )
            self.assertEqual(exit_code, 0, stderr)
            manifest = json.loads((evidence / "case-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["suite"], "p2-exif")
            self.assertEqual(manifest["source_dirty_paths"], [])
            self.assertEqual(manifest["e2e_ids"], ["E2E-P2-01"])
            self.assertEqual(manifest["result"], "Passed")
            self.assertEqual(manifest["human_review"], "NOT_RUN")
            self.assertEqual(manifest["executed_tests"], ["ExifToggleUITests/testExifToggleOwnershipIOS()"])
            self.assertEqual(manifest["device"]["udid"], P2_UDID)
            report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(report["verdict"], RAW_VERDICT)
            self.assertNotEqual(report["verdict"], "PASS")
            self.assertEqual(report["execution"]["executed_tests"], ["ExifToggleUITests/testExifToggleOwnershipIOS()"])
            self.assertEqual(report["execution"]["device"]["class"], "iphone")
            facts_path = mocks["facts"].call_args.args[0]
            self.assertEqual(facts_path.name, "strict-p2-exif.xcresult")
            self.assertEqual(facts_path.parent.parent, evidence.parent / "private")
            mocks["start"].assert_not_called()
            self.assertTrue((evidence / "sensitive-scan.json").is_file())

    def test_p2_main_fails_closed_on_missing_png_or_other_simulator(self) -> None:
        for label, kwargs in (
            ("Missing PNG", {"skip": ("exif-off",)}),
            ("Official results came from another simulator", {"facts_device_id": "SIM-OTHER"}),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory) / "p2-exif-ipad"
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPad Pro 13-inch (M5)",
                    **kwargs,
                )
                self.assertEqual(exit_code, 2)
                self.assertNotIn("Traceback", stderr)
                manifest = json.loads((evidence / "case-manifest.json").read_text(encoding="utf-8"))
                self.assertEqual(manifest["result"], "FAILED")
                if label == "Missing PNG":
                    self.assertIn("exif-off.png", stderr)
                    report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
                    self.assertEqual(report["verdict"], "FAIL")

    def test_p2_video_case_records_whole_run_and_stops_even_when_xcodebuild_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "p2-reduce-motion-tv"
            exit_code, _stdout, stderr, mocks = self._run_p2_main(
                evidence,
                suite="p2-reduce-motion",
                platform="tvos",
                model="Apple TV 4K (3rd generation)",
            )
            self.assertEqual(exit_code, 0, stderr)
            mocks["start"].assert_called_once_with(
                P2_UDID, evidence / "screen-recording.mov", evidence / "screen-recording.log"
            )
            mocks["stop"].assert_called_once_with(mocks["recording_process"])
            timing = json.loads((evidence / "screen-recording-timing.json").read_text(encoding="utf-8"))
            self.assertEqual(timing["started_wall_time"], 900.0)
            self.assertEqual(timing["stop_exit"], 0)
            self.assertGreater(timing["stopped_wall_time"], timing["started_wall_time"])

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "p2-rotation-iphone"
            exit_code, _stdout, _stderr, mocks = self._run_p2_main(
                evidence,
                suite="p2-rotation",
                platform="ios",
                model="iPhone 17 Pro",
                xcodebuild_exit=65,
            )
            self.assertEqual(exit_code, 65)
            mocks["stop"].assert_called_once_with(mocks["recording_process"])

    def test_p2_result_bundle_is_private_on_failure_and_disposed_only_after_success(self) -> None:
        for label, xcodebuild_exit, export_exit, expected_exit in (
            ("test-failed", 65, 0, 65),
            ("export-failed", 0, 1, 2),
            ("success", 0, 0, 0),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                root = Path(raw_directory)
                evidence = root / "evidence"
                private_root = root / "private"
                with mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", private_root):
                    exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                        evidence,
                        suite="p2-exif",
                        platform="ios",
                        model="iPhone 17 Pro",
                        xcodebuild_exit=xcodebuild_exit,
                        create_result_bundle=True,
                        export_exit=export_exit,
                    )
                self.assertEqual(exit_code, expected_exit, stderr)
                self.assertFalse((evidence / "strict-p2-exif.xcresult").exists())
                self.assertEqual(json.loads((evidence / "sensitive-scan.json").read_text())["result"], "PASS")
                if expected_exit == 0:
                    self.assertEqual(list(private_root.rglob("raw.bin")), [])
                    self.assertTrue((evidence / "result-bundle-disposal.json").is_file())
                else:
                    quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
                    self.assertEqual(Path(quarantine["private_path"]).joinpath("raw.bin").read_bytes(), b"raw diagnostics")
                    self.assertEqual(len(list(private_root.rglob("raw.bin"))), 1)
                    self.assertFalse((evidence / "result-bundle-disposal.json").exists())

        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            evidence = root / "evidence"
            private_root = root / "private"
            with mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", private_root), mock.patch(
                "run_strict_e2e.write_sensitive_scan", side_effect=CommandError("scan failed")
            ):
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPhone 17 Pro",
                    create_result_bundle=True,
                )
            self.assertEqual(exit_code, 2, stderr)
            self.assertIn("sensitive_scan", stderr)
            failures = json.loads((evidence / "cleanup-failures.json").read_text())["failures"]
            self.assertTrue(any(failure.startswith("sensitive_scan:") for failure in failures))
            quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
            self.assertEqual(Path(quarantine["private_path"]).joinpath("raw.bin").read_bytes(), b"raw diagnostics")
            self.assertFalse((evidence / "result-bundle-disposal.json").exists())

    def test_p2_bundle_is_private_even_when_isolation_step_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            with mock.patch("run_strict_e2e.shutil.move", side_effect=OSError("move denied")) as move:
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPhone 17 Pro",
                    xcodebuild_exit=65,
                    create_result_bundle=True,
                )
            self.assertEqual(exit_code, 65, stderr)
            move.assert_not_called()
            self.assertFalse((evidence / "strict-p2-exif.xcresult").exists())
            quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
            self.assertEqual(Path(quarantine["private_path"]).joinpath("raw.bin").read_bytes(), b"raw diagnostics")

    def test_p2_disposal_record_failure_preserves_private_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            write_text = Path.write_text

            def fail_disposal_record(path: Path, content: str, **kwargs: object) -> int:
                if path.name == "result-bundle-disposal.json":
                    raise OSError("record denied")
                return write_text(path, content, **kwargs)

            with mock.patch.object(Path, "write_text", fail_disposal_record):
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPhone 17 Pro",
                    create_result_bundle=True,
                )
            self.assertEqual(exit_code, 2, stderr)
            self.assertIn("dispose_private_result_bundle", stderr)
            self.assertFalse((evidence / "result-bundle-disposal.json").exists())
            quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
            self.assertEqual(Path(quarantine["private_path"]).joinpath("raw.bin").read_bytes(), b"raw diagnostics")

    def test_p2_private_directory_failure_stops_before_xcodebuild(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            with mock.patch(
                "run_strict_e2e.prepare_private_result_bundle_path", side_effect=OSError("private denied")
            ), mock.patch("run_strict_e2e.run_command") as run_command:
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPhone 17 Pro",
                )
            self.assertEqual(exit_code, 2, stderr)
            run_command.assert_not_called()
            self.assertFalse((evidence / "strict-p2-exif.xcresult").exists())

    def test_p2_disposal_failure_keeps_private_bundle_indexed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            remove_tree = shutil.rmtree

            def fail_private_disposal(path: Path, *args: object, **kwargs: object) -> None:
                if str(path).endswith(".xcresult"):
                    raise OSError("dispose denied")
                remove_tree(path, *args, **kwargs)

            with mock.patch("run_strict_e2e.shutil.rmtree", side_effect=fail_private_disposal):
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPhone 17 Pro",
                    create_result_bundle=True,
                )
            self.assertEqual(exit_code, 2, stderr)
            self.assertIn("dispose_private_result_bundle", stderr)
            self.assertFalse((evidence / "result-bundle-disposal.json").exists())
            quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
            self.assertEqual(Path(quarantine["private_path"]).joinpath("raw.bin").read_bytes(), b"raw diagnostics")


if __name__ == "__main__":
    unittest.main()
