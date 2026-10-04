#!/usr/bin/env python3
"""Tests for the targeted iPhone/iPad access-lifecycle runner, which is not registered in the run_strict_e2e suite table."""

from __future__ import annotations

import io
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from run_access_lifecycle_ios import (  # noqa: E402
    DEVICE_SELECTOR,
    MIN_DATA_GIB,
    SYNTHETIC_PIN,
    build_test_command,
    main,
)
from access_lifecycle_contract import FROZEN_FIXTURE_SHA256  # noqa: E402
import run_strict_e2e  # noqa: E402


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
        png = _stand_in_png("ipad-85c0537a", "after-next.png")
        self.assertEqual(scene_mark_from_bytes(png), "A4+A1")
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "after-next.png"
            path.write_bytes(png)
            self.assertEqual(scene_mark_from_png(path), "A4+A1")
            black = Path(raw) / "black.png"
            black.write_bytes(_png_bytes(Image.new("RGB", (64, 64), (0, 0, 0))))
            self.assertEqual(scene_mark_from_png(black), "BLACK")


if __name__ == "__main__":
    unittest.main()
