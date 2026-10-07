#!/usr/bin/env python3
"""Tests for the targeted iPhone/iPad access-lifecycle runner, which is not registered in the run_strict_e2e suite table."""

from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from run_access_lifecycle_ios import (  # noqa: E402
    DEVICE_SELECTOR,
    MIN_DATA_GIB,
    SYNTHETIC_PIN,
    build_test_command,
    main,
)
from access_lifecycle_contract import FROZEN_FIXTURE_SHA256  # noqa: E402
import run_access_lifecycle_ios  # noqa: E402
import run_access_lifecycle_tvos  # noqa: E402
import run_strict_e2e  # noqa: E402
from run_offline_unit_tests import TestResultsSummary  # noqa: E402


class RoutingTests(unittest.TestCase):
    def test_default_minimum_free_space_is_80_gib_and_message_names_option(self) -> None:
        self.assertEqual(MIN_DATA_GIB, 80)
        calls: list[list[str]] = []
        stderr = io.StringIO()
        code = main(
            [
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--evidence-dir",
                "/tmp/access-lifecycle-low-disk",
            ],
            stderr=stderr,
            run=lambda argv: calls.append(argv) or 0,
            data_available_gib=lambda: 79.9,
        )
        self.assertEqual(code, 2)
        self.assertEqual(calls, [])
        self.assertIn("--min-free-gib", stderr.getvalue())

    def test_custom_minimum_free_space_is_respected(self) -> None:
        calls: list[list[str]] = []
        code = main(
            [
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--evidence-dir",
                "/tmp/access-lifecycle-custom-disk",
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

    def test_selector_points_at_the_ios_access_lifecycle_ui_class(self) -> None:
        self.assertEqual(
            DEVICE_SELECTOR,
            "immichSlidesUITests/AccessLifecycleIOSUITests/"
            "testAccessProtectionSettingsAndLifecycle",
        )

    def test_print_command_does_not_invoke_xcodebuild(self) -> None:
        calls: list[list[str]] = []
        stdout = io.StringIO()
        code = main(
            [
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--evidence-dir",
                "/tmp/access-lifecycle-print",
                "--print-command",
            ],
            stdout=stdout,
            run=lambda argv: calls.append(argv) or 0,
            data_available_gib=lambda: 200,
        )
        self.assertEqual(code, 0)
        self.assertEqual(calls, [])
        output = stdout.getvalue()
        self.assertIn("-only-testing:" + DEVICE_SELECTOR, output)
        self.assertIn("-testPlan StrictE2E-iOS", output.replace("\n", " "))
        self.assertIn("xcodebuild", output)
        self.assertNotIn(SYNTHETIC_PIN, output)
        self.assertNotIn("run_strict_e2e.py", output)

    def test_existing_local_xcconfig_is_rejected_before_anything_starts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            (root / "Config").mkdir()
            (root / "Config/env.xcconfig").write_text("PRIVATE_PLACEHOLDER = 1\n", encoding="utf-8")
            (root / "Config/env.example.xcconfig").write_text(
                "ENABLE_DEBUG_AUTO_SERVER = 0\nENABLE_DEBUG_FILL_APIKEY_BUTTON = 0\n", encoding="utf-8"
            )
            stderr = io.StringIO()
            with mock.patch.object(run_access_lifecycle_ios, "REPO_ROOT", root):
                code = main(
                    ["--destination", "platform=iOS Simulator,id=DEST-IOS", "--evidence-dir", str(root / "evidence")],
                    stdout=io.StringIO(),
                    stderr=stderr,
                    data_available_gib=lambda: 200,
                )

            self.assertNotEqual(code, 0)
            self.assertIn("already exists", stderr.getvalue())
            self.assertEqual((root / "Config/env.xcconfig").read_text(encoding="utf-8"), "PRIVATE_PLACEHOLDER = 1\n")

    def test_build_command_does_not_embed_pin_or_forced_display_mode(self) -> None:
        command = build_test_command(
            destination="platform=iOS Simulator,id=DEST-IOS",
            derived_data_path="/tmp/dd",
            result_bundle_path="/tmp/bundle.xcresult",
            server_url="http://127.0.0.1:5555/api",
            evidence_dir="/tmp/evidence",
        )
        joined = " ".join(command)
        self.assertNotIn(SYNTHETIC_PIN, joined)
        self.assertNotIn("UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE", joined)
        self.assertNotIn("UI_TEST_SERVER_URL", joined)
        self.assertNotIn(run_access_lifecycle_ios.PUBLIC_API_KEY, joined)
        self.assertIn("STRICT_E2E_INPUT_SERVER_URL=http://127.0.0.1:5555/api", joined)
        self.assertIn("-scheme", command)
        self.assertEqual(command[command.index("-scheme") + 1], "immichSlides-iOS")

    def test_not_registered_on_strict_e2e_suite_table(self) -> None:
        self.assertNotIn("access-lifecycle-ios", run_strict_e2e.RUNNER_SUITES)
        self.assertNotIn("access-lifecycle", run_strict_e2e.RUNNER_SUITES)

    def test_frozen_fixture_hash_unchanged(self) -> None:
        # Fixture A's published digest is pinned here. Pixel seeds stay fixed; regenerating
        # metadata still changes the hash, so sign-off cannot reuse older screenshots.
        self.assertEqual(
            FROZEN_FIXTURE_SHA256["a"],
            "44f9dc4b144e5fcc5dd14a98b76ba1bf1ca8829648555aebe738c3e2b3048989",
        )

    def test_runner_requires_settings_at_background_screenshot(self) -> None:
        from access_lifecycle_contract import DEVICE_REQUIRED_SCREENSHOTS

        self.assertIn("settings_at_background", DEVICE_REQUIRED_SCREENSHOTS)

    def test_scene_mark_from_png_uses_capture_identity_not_full_classify(self) -> None:
        import tempfile

        from PIL import Image

        from run_access_lifecycle_ios import scene_mark_from_png
        from access_lifecycle_contract import scene_mark_from_bytes
        from test_access_lifecycle_contract import _stand_in_png, _png_bytes

        # A frame stacking two public fixtures must report both marks, not what a
        # full-screen classify_screenshot gives.
        png = _stand_in_png("ipad-stacked-after-next", "after-next.png")
        self.assertEqual(scene_mark_from_bytes(png), "A4+A1")
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "after-next.png"
            path.write_bytes(png)
            self.assertEqual(scene_mark_from_png(path), "A4+A1")
            black = Path(raw) / "black.png"
            black.write_bytes(_png_bytes(Image.new("RGB", (64, 64), (0, 0, 0))))
            self.assertEqual(scene_mark_from_png(black), "BLACK")

    def test_evidence_exceptions_quarantine_raw_bundles_and_preserve_xcode_failure(self) -> None:
        # A truncated payload or an unexpected validator error must not dispose failed-run diagnostics.
        routes = (
            (run_access_lifecycle_ios, "ios", None),
            (run_access_lifecycle_tvos, "tvos", None),
            (run_strict_e2e, "ios", "smoke"),
            (run_strict_e2e, "ios", "filter-person"),
        )
        for runner, platform, suite in routes:
            for outcome in ("success", "truncated_json", "unexpected_error"):
                exits = (0, 65) if runner is run_access_lifecycle_ios and outcome != "success" else (0,)
                for xcode_exit in exits:
                    with self.subTest(runner=runner.__name__, suite=suite, outcome=outcome, exit=xcode_exit):
                        with tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
                            root = Path(raw)
                            evidence = root / "evidence"
                            bundles: list[Path] = []

                            def fake_build(command: list[str], **kwargs: object) -> int:
                                bundle = Path(command[command.index("-resultBundlePath") + 1])
                                bundle.mkdir()
                                (bundle / "raw.bin").write_bytes(b"raw XCTest diagnostics")
                                bundles.append(bundle)
                                kwargs["log_path"].write_text("test run\n", encoding="utf-8")
                                (evidence / "access-lifecycle.json").write_text("{", encoding="utf-8")
                                return xcode_exit

                            def validate(*args: object, **kwargs: object) -> dict[str, str]:
                                if outcome == "unexpected_error":
                                    raise RuntimeError("Evidence validator interrupted")
                                if outcome == "truncated_json":
                                    json.loads((evidence / "access-lifecycle.json").read_text())
                                return {
                                    "verdict": "PASS",
                                    "d01": "PARTIAL",
                                    "identity_source": "public_fixture_photo_mark",
                                }

                            def fake_subprocess(command: list[str], **kwargs: object) -> subprocess.CompletedProcess:
                                output = b'{"testNodes":[]}' if command[:2] == ["xcrun", "xcresulttool"] else ""
                                return subprocess.CompletedProcess(command, 0, output, "")

                            patches = {
                                "REPO_ROOT": root,
                                "prepare_task_xcconfig": {},
                                "cleanup_task_xcconfig": None,
                                "write_fixture_artifacts": {"fixture_set": "a", "fixture_sha256": "a" * 64},
                                "wait_for_service": ("127.0.0.1", 8888),
                                "reset_simulator_app": "reset\n",
                                "stop_exact_process": 0,
                            }
                            for name, value in patches.items():
                                patch = (
                                    mock.patch.object(runner, name, value) if name == "REPO_ROOT"
                                    else mock.patch.object(runner, name, return_value=value)
                                )
                                stack.enter_context(patch)
                            stack.enter_context(mock.patch.object(
                                run_strict_e2e, "PRIVATE_RESULT_BUNDLE_ROOT", root / "private"
                            ))
                            stack.enter_context(mock.patch.object(
                                runner.subprocess, "Popen", return_value=mock.Mock(pid=9876)
                            ))
                            stack.enter_context(mock.patch.object(runner.subprocess, "run", side_effect=fake_subprocess))
                            for module in {runner, run_strict_e2e}:
                                stack.enter_context(mock.patch.object(
                                    module, "read_official_test_results_summary",
                                    return_value=TestResultsSummary(1, 1, 0, 0, "Passed"),
                                ))
                            if runner is not run_access_lifecycle_tvos:
                                build_name = "run_command" if runner is run_strict_e2e else "run_xcodebuild"
                                stack.enter_context(mock.patch.object(runner, build_name, side_effect=fake_build))
                            validator = "require_visual_identity" if runner is run_strict_e2e else "evaluate_device_evidence"
                            if runner is run_strict_e2e or outcome != "truncated_json":
                                stack.enter_context(mock.patch.object(runner, validator, side_effect=validate))
                            if runner is run_strict_e2e:
                                stack.enter_context(mock.patch.object(runner, "data_available_gib", return_value=200))
                                stack.enter_context(mock.patch.object(runner, "read_source_sha", return_value="b" * 40))
                                stack.enter_context(mock.patch.object(runner, "read_source_dirty_paths", return_value=[]))
                            elif runner is run_access_lifecycle_tvos:
                                stack.enter_context(mock.patch.object(runner, "write_isolated_tvos_scheme"))
                                stack.enter_context(mock.patch.object(runner, "remove_isolated_tvos_scheme"))
                                stack.enter_context(mock.patch.object(runner, "read_source_sha", return_value="b" * 40))
                            arguments = [
                                "--destination", f"platform={'tvOS' if platform == 'tvos' else 'iOS'} Simulator,id=DEST",
                                "--evidence-dir", str(evidence),
                            ]
                            kwargs = {"stdout": io.StringIO(), "stderr": io.StringIO()}
                            if runner is run_access_lifecycle_tvos:
                                kwargs["run_xcodebuild"] = fake_build
                            if runner is not run_access_lifecycle_ios:
                                arguments.extend(["--platform", platform])
                            if suite is not None:
                                arguments.extend(["--suite", suite])
                            if runner is not run_strict_e2e:
                                kwargs["data_available_gib"] = lambda: 200
                            if outcome == "unexpected_error":
                                with self.assertRaisesRegex(RuntimeError, "Evidence validator interrupted"):
                                    runner.main(arguments, **kwargs)
                            else:
                                code = runner.main(arguments, **kwargs)
                                self.assertEqual(
                                    code, 0 if outcome == "success" else xcode_exit or 2,
                                    kwargs["stderr"].getvalue(),
                                )
                            self.assertEqual(len(bundles), 3 if suite == "filter-person" else 1)
                            for index, bundle in enumerate(bundles):
                                suffix = (
                                    "-" + run_strict_e2e.FILTER_PERSON_SESSIONS[index]["name"]
                                    if suite == "filter-person" else ""
                                )
                                disposal = evidence / f"result-bundle-disposal{suffix}.json"
                                quarantine = evidence / f"result-bundle-quarantine{suffix}.json"
                                self.assertEqual(bundle.exists(), outcome != "success")
                                self.assertEqual(disposal.exists(), outcome == "success")
                                self.assertEqual(quarantine.exists(), outcome != "success")
                                receipt = json.loads((disposal if outcome == "success" else quarantine).read_text())
                                self.assertEqual(receipt["result_bundle_disposed"], outcome == "success")
                                self.assertEqual(receipt["private_path"], str(bundle))


if __name__ == "__main__":
    unittest.main()
