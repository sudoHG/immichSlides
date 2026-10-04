#!/usr/bin/env python3
"""Offline unit test entry point: parse the real scheme/plan, not a copy of script strings."""

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
# Fields recorded from `xcresulttool get test-results summary` on real bundles;
# device identifiers are left out.
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


class RepoDiscoveryTests(unittest.TestCase):
    def test_generic_scheme_does_not_reference_missing_plan(self) -> None:
        self.assertNotIn(MISSING_GENERIC_PLAN, GENERIC_SCHEME.read_text(encoding="utf-8"))
        self.assertFalse((REPO_ROOT / MISSING_GENERIC_PLAN).exists())

    def test_pbxproj_does_not_reference_missing_plan(self) -> None:
        self.assertNotIn("path = immichSlides.xctestplan", PBXPROJ.read_text(encoding="utf-8"))

    def test_platform_scheme_plans_exist_on_disk(self) -> None:
        for scheme_path in (IOS_SCHEME, TVOS_SCHEME):
            names = scheme_test_plan_names(scheme_path)
            self.assertTrue(names, msg=scheme_path.name)
            for name in names:
                self.assertTrue((REPO_ROOT / name).is_file(), msg=name)

    def test_existing_plans_select_business_and_ui_targets(self) -> None:
        for plan_path in (IOS_PLAN, TVOS_PLAN):
            names = plan_target_names(plan_path)
            self.assertIn("immichSlidesTests", names)
            self.assertIn("immichSlidesUITests", names)


class CommandBuilderTests(unittest.TestCase):
    def test_default_ios_command_uses_discovered_scheme_plan_and_business_target(self) -> None:
        plan_name = scheme_test_plan_names(IOS_SCHEME)[0]
        expected_targets = business_targets(plan_target_names(REPO_ROOT / plan_name))
        command = build_test_command(
            repo_root=REPO_ROOT,
            platform="ios",
            destination="platform=iOS Simulator,id=DEST-IOS",
            derived_data_path=".derivedData/ticket-ios",
            result_bundle_path="/tmp/ticket-ios.xcresult",
        )

        self.assertEqual(command[0], "xcodebuild")
        self.assertEqual(command[1], "test")
        self.assertEqual(command[command.index("-scheme") + 1], IOS_SCHEME.stem)
        self.assertEqual(command[command.index("-testPlan") + 1], Path(plan_name).stem)
        self.assertEqual(command[command.index("-destination") + 1], "platform=iOS Simulator,id=DEST-IOS")
        self.assertEqual(command[command.index("-derivedDataPath") + 1], ".derivedData/ticket-ios")
        self.assertEqual(command[command.index("-resultBundlePath") + 1], "/tmp/ticket-ios.xcresult")
        for target in expected_targets:
            self.assertIn(f"-only-testing:{target}", command)
        self.assertFalse(any("UITests" in argument for argument in command))
        self.assertNotIn(MISSING_GENERIC_PLAN, " ".join(command))
        self.assertNotEqual(command[command.index("-scheme") + 1], "immichSlides")

    def test_default_command_explicitly_skips_external_runtime_gate(self) -> None:
        command = build_test_command(
            repo_root=REPO_ROOT,
            platform="ios",
            destination="platform=iOS Simulator,id=DEST-IOS",
        )

        self.assertIn(f"-skip-testing:{EXTERNAL_RUNTIME_TEST_SELECTOR}", command)

    def test_explicit_external_runtime_selector_is_rejected(self) -> None:
        with self.assertRaises(CommandError) as raised:
            build_test_command(
                repo_root=REPO_ROOT,
                platform="ios",
                destination="platform=iOS Simulator,id=DEST-IOS",
                only_testing=[EXTERNAL_RUNTIME_TEST_SELECTOR],
            )

        self.assertIn("Evidence test plan", str(raised.exception))

    def test_default_tvos_command_uses_discovered_scheme_and_plan(self) -> None:
        plan_name = scheme_test_plan_names(TVOS_SCHEME)[0]
        command = build_test_command(
            repo_root=REPO_ROOT,
            platform="tvos",
            destination="platform=tvOS Simulator,id=DEST-TV",
        )
        self.assertEqual(command[command.index("-scheme") + 1], TVOS_SCHEME.stem)
        self.assertEqual(command[command.index("-testPlan") + 1], Path(plan_name).stem)
        self.assertIn("-only-testing:immichSlidesTests", command)

    def test_full_plan_keeps_ui_target_available(self) -> None:
        command = build_test_command(
            repo_root=REPO_ROOT,
            platform="ios",
            destination="platform=iOS Simulator,id=DEST-IOS",
            full_plan=True,
        )
        self.assertFalse(any(argument.startswith("-only-testing:") for argument in command))
        self.assertEqual(command[command.index("-testPlan") + 1], Path(scheme_test_plan_names(IOS_SCHEME)[0]).stem)

    def test_access_lifecycle_suite_routes_protection_settings_and_lifecycle_selectors(self) -> None:
        selectors = resolve_suite_selectors("access-lifecycle")
        self.assertEqual(
            selectors,
            [
                "immichSlidesTests/AccessProtectionStoreTests",
                "immichSlidesTests/PlaybackSettingsViewModelTests",
                "immichSlidesTests/ManualPlaybackLifecycleTests",
                "immichSlidesTests/SceneLifecycleContractTests",
                "immichSlidesTests/StableMarkTimingTests",
            ],
        )
        self.assertEqual(selectors, ACCESS_LIFECYCLE_HOST_SELECTORS)
        command = build_test_command(
            repo_root=REPO_ROOT,
            platform="ios",
            destination="platform=iOS Simulator,id=DEST-IOS",
            only_testing=selectors,
        )
        for selector in selectors:
            self.assertIn(f"-only-testing:{selector}", command)
        self.assertFalse(any("UITests" in argument for argument in command))

    def test_access_lifecycle_suite_is_available_for_tvos_host_routing(self) -> None:
        command = build_test_command(
            repo_root=REPO_ROOT,
            platform="tvos",
            destination="platform=tvOS Simulator,id=DEST-TV",
            only_testing=resolve_suite_selectors("access-lifecycle"),
        )
        self.assertEqual(command[command.index("-scheme") + 1], TVOS_SCHEME.stem)
        self.assertIn(
            "-only-testing:immichSlidesTests/AccessProtectionStoreTests",
            command,
        )

    def test_unknown_suite_is_rejected(self) -> None:
        with self.assertRaises(CommandError) as raised:
            resolve_suite_selectors("strict-e2e")
        self.assertIn("Unknown offline suite:", str(raised.exception))
        self.assertIn("access-lifecycle", str(raised.exception))


class ConfigInspectionTests(unittest.TestCase):
    def test_missing_env_and_example_placeholder_are_separate(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            config_dir = root / "Config"
            config_dir.mkdir(parents=True)
            shutil.copyfile(REPO_ROOT / "Config/env.example.xcconfig",
                            config_dir / "env.example.xcconfig")
            info = inspect_config(root)
        self.assertFalse(info.env_xcconfig_exists)
        self.assertTrue(info.example_xcconfig_exists)
        self.assertTrue(info.example_is_placeholder)
        self.assertIsNone(info.env_is_placeholder)

    def test_existing_env_placeholder_does_not_expose_secret(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            config_dir = root / "Config"
            config_dir.mkdir(parents=True)
            (config_dir / "env.example.xcconfig").write_text(
                "IMMICH_SERVER_URL = https://your-server.example.com/api\n"
                "IMMICH_API_KEY = YOUR_API_KEY\n",
                encoding="utf-8",
            )
            (config_dir / "env.xcconfig").write_text(
                "IMMICH_SERVER_URL = https://secret.example.invalid/api\n"
                "IMMICH_API_KEY = super-secret-canary\n",
                encoding="utf-8",
            )
            info = inspect_config(root)
            self.assertTrue(info.env_xcconfig_exists)
            self.assertFalse(info.env_is_placeholder)
            self.assertTrue(info.example_is_placeholder)
            self.assertNotIn("super-secret-canary", info.report)
            self.assertNotIn("secret.example.invalid", info.report)

    def test_escaped_example_server_url_is_recognized_as_placeholder(self) -> None:
        self.assertTrue(
            is_placeholder_config(
                {
                    "IMMICH_SERVER_URL": "https:/$()/your-server.example.com/api",
                    "IMMICH_API_KEY": "configured-key",
                }
            )
        )

    def test_prepare_example_config_preserves_and_recognizes_escaped_url(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            config_dir = root / "Config"
            config_dir.mkdir(parents=True)
            example_path = config_dir / "env.example.xcconfig"
            example_path.write_text(
                "IMMICH_SERVER_URL = https:/$()/your-server.example.com/api\n"
                "IMMICH_API_KEY = YOUR_API_KEY\n",
                encoding="utf-8",
            )
            copied, _ = prepare_example_config(root)
            info = inspect_config(root)
            self.assertTrue(copied)
            self.assertTrue(info.env_is_placeholder)
            self.assertEqual(
                (config_dir / "env.xcconfig").read_text(encoding="utf-8"),
                example_path.read_text(encoding="utf-8"),
            )

    def test_prepare_example_does_not_overwrite_existing_env(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            config_dir = root / "Config"
            config_dir.mkdir(parents=True)
            example = config_dir / "env.example.xcconfig"
            env_file = config_dir / "env.xcconfig"
            example.write_text("IMMICH_API_KEY = YOUR_API_KEY\n", encoding="utf-8")
            env_file.write_text("IMMICH_API_KEY = keep-me\n", encoding="utf-8")
            copied, message = prepare_example_config(root)
            self.assertFalse(copied)
            self.assertEqual(env_file.read_text(encoding="utf-8"), "IMMICH_API_KEY = keep-me\n")
            self.assertNotIn("keep-me", message)


class CLIMainTests(unittest.TestCase):
    def test_unknown_platform_fails_with_reason(self) -> None:
        stderr = io.StringIO()
        code = main(
            ["--platform", "watchos", "--destination", "platform=iOS Simulator,id=X", "--print-command"],
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("platform", stderr.getvalue())

    def test_missing_destination_fails_with_reason(self) -> None:
        stderr = io.StringIO()
        code = main(
            ["--platform", "ios", "--print-command"],
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("destination", stderr.getvalue())

    def test_check_parses_without_calling_xcode(self) -> None:
        calls: list[list[str]] = []
        stdout = io.StringIO()
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            # Copy only version-controlled entry files; maintainer credentials must not enter the test fixture.
            for source in (GENERIC_SCHEME, IOS_SCHEME, TVOS_SCHEME, PBXPROJ,
                           *REPO_ROOT.glob("*.xctestplan"),
                           REPO_ROOT / "Config/env.example.xcconfig",
                           REPO_ROOT / "Config/Debug.xcconfig"):
                target = root / source.relative_to(REPO_ROOT)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
            with patch("run_offline_unit_tests.REPO_ROOT", root):
                code = main(
                    ["--check"],
                    stdout=stdout,
                    stderr=stderr,
                    run=lambda argv: calls.append(argv) or 0,
                    data_available_gib=lambda: 200,
                )
                prepared_stdout = io.StringIO()
                prepared_stderr = io.StringIO()
                prepared_code = main(
                    ["--prepare-example-config", "--check"],
                    stdout=prepared_stdout,
                    stderr=prepared_stderr,
                    run=lambda argv: calls.append(argv) or 0,
                    data_available_gib=lambda: 200,
                )
        output = stdout.getvalue() + stderr.getvalue()
        prepared_output = prepared_stdout.getvalue() + prepared_stderr.getvalue()
        self.assertEqual(code, 0, output)
        self.assertEqual(prepared_code, 0, prepared_output)
        self.assertEqual(calls, [])
        self.assertNotIn("xcodebuild", output)
        self.assertIn("immichSlides-iOS", output)
        self.assertIn("immichSlides-tvOS", output)
        self.assertIn("env.xcconfig: missing", output)
        self.assertIn("Example placeholder check: is a placeholder", output)
        self.assertIn("Created env.xcconfig from env.example.xcconfig", prepared_output)
        self.assertIn("env.xcconfig: present", prepared_output)
        self.assertIn("Existing env.xcconfig is still a placeholder", prepared_output)
        self.assertIn("Example placeholder check: is a placeholder", prepared_output)
        self.assertIn("1 external evidence test not run", output)
        self.assertIn("Evidence test plan", output)

    def test_xcodebuild_exit_code_is_forwarded(self) -> None:
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
            ],
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            run=lambda _: 65,
            data_available_gib=lambda: 200,
        )
        self.assertEqual(code, 65)

    def test_low_disk_stops_before_xcodebuild(self) -> None:
        calls: list[list[str]] = []
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
            ],
            stderr=stderr,
            run=lambda argv: calls.append(argv) or 0,
            data_available_gib=lambda: 79,
        )
        self.assertNotEqual(code, 0)
        self.assertEqual(calls, [])
        self.assertTrue(re.search(r"80\s*Gi", stderr.getvalue()))
        self.assertIn("--min-free-gib", stderr.getvalue())

    def test_custom_minimum_free_space_is_respected(self) -> None:
        calls: list[list[str]] = []
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--min-free-gib",
                "70",
            ],
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            run=lambda argv: calls.append(argv) or 65,
            data_available_gib=lambda: 75,
        )
        self.assertEqual(code, 65)
        self.assertEqual(len(calls), 1)


class DiskThresholdTests(unittest.TestCase):
    def test_default_minimum_free_space_is_80_gib(self) -> None:
        self.assertEqual(MIN_DATA_GIB, 80)
        with self.assertRaises(CommandError):
            ensure_disk_for_xcodebuild(lambda: 79.9)

    def test_custom_minimum_free_space_is_respected_by_disk_check(self) -> None:
        ensure_disk_for_xcodebuild(lambda: 75, min_free_gib=70)

    def test_disk_check_message_names_option(self) -> None:
        with self.assertRaises(CommandError) as error:
            ensure_disk_for_xcodebuild(lambda: 69, min_free_gib=70)
        self.assertIn("--min-free-gib", str(error.exception))

    def test_minimum_free_space_parser_rejects_negative_and_fractional_values(self) -> None:
        self.assertEqual(parse_non_negative_int("70"), 70)
        for value in ("-1", "1.5"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                parse_non_negative_int(value)


class RunWatchdogTests(unittest.TestCase):
    IOS_ARGS = ["--platform", "ios", "--destination", "platform=iOS Simulator,id=DEST-IOS"]

    def test_normal_child_exit_code_is_returned(self) -> None:
        code = default_run([sys.executable, "-c", "import sys; sys.exit(3)"], timeout_seconds=30)
        self.assertEqual(code, 3)

    def test_hung_child_is_interrupted_and_reported_as_timeout(self) -> None:
        started = time.monotonic()
        code = default_run(
            [sys.executable, "-c", "import time; time.sleep(60)"],
            timeout_seconds=0.5,
            grace_seconds=10,
        )
        self.assertEqual(code, TIMEOUT_EXIT_CODE)
        self.assertLess(time.monotonic() - started, 30)

    def test_child_ignoring_sigint_is_killed_after_grace(self) -> None:
        script = "import signal, time; signal.signal(signal.SIGINT, signal.SIG_IGN); time.sleep(60)"
        started = time.monotonic()
        code = default_run([sys.executable, "-c", script], timeout_seconds=0.5, grace_seconds=0.5)
        self.assertEqual(code, TIMEOUT_EXIT_CODE)
        self.assertLess(time.monotonic() - started, 30)

    def test_timeout_exit_is_reported_as_not_a_pass(self) -> None:
        stderr = io.StringIO()
        code = main(
            self.IOS_ARGS,
            stdout=io.StringIO(),
            stderr=stderr,
            run=lambda _: TIMEOUT_EXIT_CODE,
            data_available_gib=lambda: 200,
        )
        self.assertEqual(code, TIMEOUT_EXIT_CODE)
        self.assertIn("NOT a pass", stderr.getvalue())

    def test_default_runner_gets_timeout_from_flag(self) -> None:
        recorded: list[float | None] = []

        def fake_default_run(argv: list[str], timeout_seconds: float | None = None) -> int:
            recorded.append(timeout_seconds)
            return 65

        with patch("run_offline_unit_tests.default_run", fake_default_run):
            for extra in ([], ["--timeout-minutes", "2"], ["--timeout-minutes", "0"]):
                code = main(
                    self.IOS_ARGS + extra,
                    stdout=io.StringIO(),
                    stderr=io.StringIO(),
                    data_available_gib=lambda: 200,
                )
                self.assertEqual(code, 65)
        self.assertEqual(recorded, [DEFAULT_TIMEOUT_MINUTES * 60, 120, None])


class OfficialResultSummaryTests(unittest.TestCase):
    def test_zero_count_official_json_is_zero(self) -> None:
        summary = parse_official_test_results_summary(ZERO_COUNT_OFFICIAL_SUMMARY)
        self.assertEqual(summary.total_test_count, 0)
        self.assertEqual(summary.passed_tests, 0)
        self.assertEqual(summary.result, "unknown")

    def test_ios_one_passed_official_json_is_one_passed(self) -> None:
        summary = parse_official_test_results_summary(IOS_ONE_PASSED_OFFICIAL_SUMMARY)
        self.assertEqual(summary.total_test_count, 1)
        self.assertEqual(summary.passed_tests, 1)
        self.assertEqual(summary.skipped_tests, 0)
        self.assertEqual(summary.result, "Passed")

    def test_tvos_one_passed_official_json_is_one_passed(self) -> None:
        summary = parse_official_test_results_summary(TVOS_ONE_PASSED_OFFICIAL_SUMMARY)
        self.assertEqual(summary.total_test_count, 1)
        self.assertEqual(summary.passed_tests, 1)
        self.assertEqual(summary.result, "Passed")

    def test_explicit_skip_with_cases_is_not_empty(self) -> None:
        summary = parse_official_test_results_summary(
            {
                "totalTestCount": 2,
                "passedTests": 0,
                "failedTests": 0,
                "skippedTests": 2,
                "result": "Skipped",
            }
        )
        self.assertEqual(summary.total_test_count, 2)
        self.assertEqual(summary.skipped_tests, 2)
        self.assertEqual(summary.result, "Skipped")

    def test_xctest_executed_zero_text_is_unparseable(self) -> None:
        with self.assertRaises(CommandError) as raised:
            parse_official_test_results_summary(
                "Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds"
            )
        self.assertIn("unparseable", str(raised.exception))

    def test_missing_result_field_is_unparseable(self) -> None:
        with self.assertRaises(CommandError):
            parse_official_test_results_summary(
                {
                    "totalTestCount": 1,
                    "passedTests": 1,
                    "failedTests": 0,
                    "skippedTests": 0,
                }
            )


class IndependentVerdictTests(unittest.TestCase):
    def test_all_skipped_summary_is_unverified(self) -> None:
        summary = parse_official_test_results_summary(
            {
                "totalTestCount": 2,
                "passedTests": 0,
                "failedTests": 0,
                "skippedTests": 2,
                "result": "Skipped",
            }
        )
        self.assertEqual(classify_test_results(summary), "unverified")

    def test_zero_count_summary_is_unverified(self) -> None:
        summary = parse_official_test_results_summary(ZERO_COUNT_OFFICIAL_SUMMARY)
        self.assertEqual(classify_test_results(summary), "unverified")

    def test_mixed_pass_and_skip_summary_is_partial(self) -> None:
        summary = parse_official_test_results_summary(
            {
                "totalTestCount": 2,
                "passedTests": 1,
                "failedTests": 0,
                "skippedTests": 1,
                "result": "Passed",
            }
        )
        self.assertEqual(classify_test_results(summary), "partial")

    def test_failed_summary_is_failed_even_when_some_tests_passed(self) -> None:
        summary = parse_official_test_results_summary(
            {
                "totalTestCount": 2,
                "passedTests": 1,
                "failedTests": 1,
                "skippedTests": 0,
                "result": "Failed",
            }
        )
        self.assertEqual(classify_test_results(summary), "failed")

    def test_failed_result_is_failed_even_without_failed_count(self) -> None:
        summary = parse_official_test_results_summary(
            {
                "totalTestCount": 1,
                "passedTests": 0,
                "failedTests": 0,
                "skippedTests": 0,
                "result": "Failed",
            }
        )
        self.assertEqual(classify_test_results(summary), "failed")

    def test_clean_pass_summary_is_passed(self) -> None:
        summary = parse_official_test_results_summary(IOS_ONE_PASSED_OFFICIAL_SUMMARY)
        self.assertEqual(classify_test_results(summary), "passed")


class OfficialSummaryReaderTests(unittest.TestCase):
    def test_zero_count_bundle_reads_official_zero(self) -> None:
        with fake_xcresulttool(ZERO_COUNT_OFFICIAL_SUMMARY) as (bundle, calls):
            summary = read_official_test_results_summary(bundle)
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertEqual(summary.total_test_count, 0)
        self.assertEqual(summary.passed_tests, 0)
        self.assertEqual(summary.result, "unknown")

    def test_ios_one_passed_bundle_reads_official_one(self) -> None:
        with fake_xcresulttool(IOS_ONE_PASSED_OFFICIAL_SUMMARY) as (bundle, calls):
            summary = read_official_test_results_summary(bundle)
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertEqual(summary.total_test_count, 1)
        self.assertEqual(summary.passed_tests, 1)
        self.assertEqual(summary.result, "Passed")

    def test_tvos_one_passed_bundle_reads_official_one(self) -> None:
        with fake_xcresulttool(TVOS_ONE_PASSED_OFFICIAL_SUMMARY) as (bundle, calls):
            summary = read_official_test_results_summary(bundle)
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertEqual(summary.total_test_count, 1)
        self.assertEqual(summary.passed_tests, 1)
        self.assertEqual(summary.result, "Passed")

    def test_missing_bundle_fails_without_calling_xcresulttool(self) -> None:
        with fake_xcresulttool(IOS_ONE_PASSED_OFFICIAL_SUMMARY) as (bundle, calls):
            missing = bundle.parent / "missing.xcresult"
            with self.assertRaises(CommandError) as raised:
                read_official_test_results_summary(missing)
        self.assertEqual(calls, [])
        self.assertIn(str(missing), str(raised.exception))

    def test_xcresulttool_failure_is_unparseable(self) -> None:
        with fake_xcresulttool(returncode=1, stdout="", stderr="boom") as (bundle, _):
            with self.assertRaises(CommandError) as raised:
                read_official_test_results_summary(bundle)
        self.assertIn("boom", str(raised.exception))

    def test_empty_xcresulttool_output_is_unparseable(self) -> None:
        with fake_xcresulttool(stdout="  \n") as (bundle, _):
            with self.assertRaises(CommandError):
                read_official_test_results_summary(bundle)


class ResultGuardCLITests(unittest.TestCase):
    def test_injected_zero_count_summary_fails_without_historical_bundle(self) -> None:
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--result-bundle-path",
                "/tmp/zero-count-injected.xcresult",
                "--only-testing",
                "immichSlidesTests/PlaybackPoolResolverTests/normalizeServerURLWorks",
            ],
            stdout=io.StringIO(),
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
            read_summary=lambda _: parse_official_test_results_summary(ZERO_COUNT_OFFICIAL_SUMMARY),
        )
        self.assertNotEqual(code, 0)
        message = stderr.getvalue()
        self.assertIn("totalTestCount=0", message)
        self.assertIn("The filter matched no tests", message)
        self.assertIn("normalizeServerURLWorks", message)

    def test_zero_count_bundle_fails_after_xcode_success(self) -> None:
        stderr = io.StringIO()
        with fake_xcresulttool(ZERO_COUNT_OFFICIAL_SUMMARY) as (bundle, calls):
            code = main(
                [
                    "--platform",
                    "ios",
                    "--destination",
                    "platform=iOS Simulator,id=DEST-IOS",
                    "--result-bundle-path",
                    str(bundle),
                    "--only-testing",
                    "immichSlidesTests/PlaybackPoolResolverTests/normalizeServerURLWorks",
                ],
                stdout=io.StringIO(),
                stderr=stderr,
                run=lambda _: 0,
                data_available_gib=lambda: 200,
            )
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertNotEqual(code, 0)
        message = stderr.getvalue()
        self.assertIn("totalTestCount=0", message)
        self.assertIn("normalizeServerURLWorks", message)

    def test_ios_one_passed_bundle_stays_success(self) -> None:
        with fake_xcresulttool(IOS_ONE_PASSED_OFFICIAL_SUMMARY) as (bundle, calls):
            code = main(
                [
                    "--platform",
                    "ios",
                    "--destination",
                    "platform=iOS Simulator,id=DEST-IOS",
                    "--result-bundle-path",
                    str(bundle),
                    "--only-testing",
                    "immichSlidesTests/PlaybackPoolResolverTests/normalizeServerURLWorks()",
                ],
                stdout=io.StringIO(),
                stderr=io.StringIO(),
                run=lambda _: 0,
                data_available_gib=lambda: 200,
            )
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertEqual(code, 0)

    def test_tvos_one_passed_bundle_stays_success(self) -> None:
        with fake_xcresulttool(TVOS_ONE_PASSED_OFFICIAL_SUMMARY) as (bundle, calls):
            code = main(
                [
                    "--platform",
                    "tvos",
                    "--destination",
                    "platform=tvOS Simulator,id=DEST-TV",
                    "--result-bundle-path",
                    str(bundle),
                    "--only-testing",
                    "immichSlidesTests/PlaybackPoolResolverTests/normalizeServerURLWorks()",
                ],
                stdout=io.StringIO(),
                stderr=io.StringIO(),
                run=lambda _: 0,
                data_available_gib=lambda: 200,
            )
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertEqual(code, 0)

    def test_explicit_skip_with_cases_is_not_failure(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--result-bundle-path",
                "/tmp/skipped.xcresult",
            ],
            stdout=stdout,
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
            read_summary=lambda _: parse_official_test_results_summary(
                {
                    "totalTestCount": 1,
                    "passedTests": 0,
                    "failedTests": 0,
                    "skippedTests": 1,
                    "result": "Skipped",
                }
            ),
        )
        self.assertEqual(code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("unverified", stdout.getvalue())
        self.assertNotIn("PASS", stdout.getvalue())

    def test_missing_bundle_after_success_fails(self) -> None:
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
            ],
            stdout=io.StringIO(),
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("Missing results", stderr.getvalue())

    def test_unparseable_bundle_after_success_fails(self) -> None:
        stderr = io.StringIO()

        def boom(_: Path) -> object:
            raise CommandError("This run's official xcresult test summary is unparseable.")

        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--result-bundle-path",
                "/tmp/broken.xcresult",
            ],
            stdout=io.StringIO(),
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
            read_summary=boom,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("unparseable", stderr.getvalue())

    def test_xcode_failure_is_kept_without_result_guard(self) -> None:
        reads: list[Path] = []
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--result-bundle-path",
                "unused-after-xcode-failure.xcresult",
            ],
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            run=lambda _: 65,
            data_available_gib=lambda: 200,
            read_summary=lambda path: reads.append(path) or parse_official_test_results_summary(
                ZERO_COUNT_OFFICIAL_SUMMARY
            ),
        )
        self.assertEqual(code, 65)
        self.assertEqual(reads, [])

    def test_suite_cannot_combine_with_only_testing_or_full_plan(self) -> None:
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--suite",
                "access-lifecycle",
                "--only-testing",
                "immichSlidesTests",
                "--print-command",
            ],
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("--suite", stderr.getvalue())

        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--suite",
                "access-lifecycle",
                "--full-plan",
                "--print-command",
            ],
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("--suite", stderr.getvalue())

    def test_print_command_access_lifecycle_suite_does_not_call_xcode(self) -> None:
        calls: list[list[str]] = []
        stdout = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--suite",
                "access-lifecycle",
                "--print-command",
            ],
            stdout=stdout,
            run=lambda argv: calls.append(argv) or 0,
            data_available_gib=lambda: 200,
        )
        output = stdout.getvalue()
        self.assertEqual(code, 0)
        self.assertEqual(calls, [])
        self.assertIn("-only-testing:immichSlidesTests/AccessProtectionStoreTests", output)
        self.assertIn("-only-testing:immichSlidesTests/PlaybackSettingsViewModelTests", output)
        self.assertNotIn("UITests", output)

    def test_print_command_does_not_read_result_bundle(self) -> None:
        reads: list[Path] = []
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--print-command",
            ],
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            run=lambda _: 0,
            data_available_gib=lambda: 200,
            read_summary=lambda path: reads.append(path) or parse_official_test_results_summary(
                ZERO_COUNT_OFFICIAL_SUMMARY
            ),
        )
        self.assertEqual(code, 0)
        self.assertEqual(reads, [])

    def test_check_does_not_read_result_bundle(self) -> None:
        reads: list[Path] = []
        code = main(
            ["--check"],
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            run=lambda _: 0,
            data_available_gib=lambda: 200,
            read_summary=lambda path: reads.append(path) or parse_official_test_results_summary(
                ZERO_COUNT_OFFICIAL_SUMMARY
            ),
        )
        self.assertEqual(code, 0)
        self.assertEqual(reads, [])


if __name__ == "__main__":
    unittest.main()
