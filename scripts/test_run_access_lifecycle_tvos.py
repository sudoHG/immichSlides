#!/usr/bin/env python3
"""Tests for targeted tvOS access-lifecycle evidence routing and fail-closed behavior; the runner is not registered in the run_strict_e2e suite table."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import run_access_lifecycle_tvos as tvos_runner  # noqa: E402
from run_access_lifecycle_tvos import (  # noqa: E402
    CommandError,
    ISOLATED_TVOS_SCHEME,
    MIN_DATA_GIB,
    TVOS_DEVICE_SELECTOR,
    UNIT_TEST_TARGET,
    UI_TEST_TARGET,
    build_xcodebuild_command,
    evaluate_device_evidence,
    isolated_scheme_path,
    isolated_tvos_scheme_xml,
    main,
    remove_isolated_tvos_scheme,
    synthetic_pin_values,
    write_isolated_tvos_scheme,
)
from run_strict_e2e import RUNNER_SUITES  # noqa: E402
from access_lifecycle_contract import (  # noqa: E402
    AccessLifecycleContractError,
    FORBIDDEN_DISPLAY_MODE_KEY,
    FROZEN_FIXTURE_SHA256,
)
from strict_e2e_server import _fixture_data  # noqa: E402
from test_access_lifecycle_contract import (  # noqa: E402
    _pool_end_single_photo_display,
    _side_by_side_transition_display,
    _single_photo_swap_display,
    _unchanged_fullbleed_display,
)


def _fixture_png(label: str, fixture_set: str = "a") -> bytes:
    return _fixture_data(fixture_set)["images"][f"asset-{fixture_set}-{label[-1]}"]


def _png_bytes(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def _compose_smart_fill(center_label: str, partner_label: str) -> bytes:
    with Image.open(io.BytesIO(_fixture_png(center_label))) as center_image, Image.open(
        io.BytesIO(_fixture_png(partner_label))
    ) as partner_image:
        width, height = 1920, 1080
        canvas = Image.new("RGB", (width, height), (0, 0, 0))
        partner = partner_image.convert("RGB").resize((360, height))
        center = center_image.convert("RGB").resize((1200, height))
        canvas.paste(partner, (0, 0))
        canvas.paste(center, (360, 0))
        canvas.paste(partner, (1560, 0))
        return _png_bytes(canvas)


def _compose_side_partner(center_label: str, partner_label: str, strip: int = 280) -> bytes:
    with Image.open(io.BytesIO(_fixture_png(center_label))) as center_image, Image.open(
        io.BytesIO(_fixture_png(partner_label))
    ) as partner_image:
        width, height = 1920, 1080
        canvas = Image.new("RGB", (width, height), (0, 0, 0))
        partner = partner_image.convert("RGB").resize((strip, height))
        center = center_image.convert("RGB").resize((width - 2 * strip, height))
        canvas.paste(partner, (0, 0))
        canvas.paste(center, (strip, 0))
        canvas.paste(partner, (width - strip, 0))
        return _png_bytes(canvas)


def _checkerboard_mix(left_label: str, right_label: str, tile: int = 24) -> bytes:
    with Image.open(io.BytesIO(_fixture_png(left_label))) as left, Image.open(
        io.BytesIO(_fixture_png(right_label))
    ) as right:
        width, height = 960, 540
        a = left.convert("RGB").resize((width, height))
        b = right.convert("RGB").resize((width, height))
        canvas = Image.new("RGB", (width, height))
        for top in range(0, height, tile):
            for left_x in range(0, width, tile):
                source = a if ((left_x // tile) + (top // tile)) % 2 == 0 else b
                box = (left_x, top, min(left_x + tile, width), min(top + tile, height))
                canvas.paste(source.crop(box), box[:2])
        return _png_bytes(canvas)


def _solid(color: tuple[int, int, int], size: tuple[int, int] = (960, 540)) -> bytes:
    return _png_bytes(Image.new("RGB", size, color))


def _noise() -> bytes:
    image = Image.new("RGB", (320, 568))
    pixels = image.load()
    assert pixels is not None
    for y in range(568):
        for x in range(320):
            pixels[x, y] = ((x * 13 + y * 7) % 256, (x * 5 + y * 17) % 256, (x * 29 + y) % 256)
    from PIL import ImageFilter

    return _png_bytes(image.filter(ImageFilter.GaussianBlur(radius=8)))


def _side_by_side(left_label: str, right_label: str) -> bytes:
    with Image.open(io.BytesIO(_fixture_png(left_label))) as left, Image.open(
        io.BytesIO(_fixture_png(right_label))
    ) as right:
        width, height = 960, 540
        canvas = Image.new("RGB", (width, height))
        canvas.paste(left.convert("RGB").resize((width // 2, height)), (0, 0))
        canvas.paste(right.convert("RGB").resize((width // 2, height)), (width // 2, 0))
        return _png_bytes(canvas)


def _write_host_payload(root: Path) -> None:
    payload = {
        "status": "ran",
        "identity_source": "public_fixture_photo_mark",
        "settings": {
            "source": "real_settings_ui",
            "before": {
                "autoPlayEnabled": False,
                "intervalSeconds": 8,
                "showExif": False,
                "displayMode": "singlePhoto",
            },
            "after_restart": {
                "autoPlayEnabled": False,
                "intervalSeconds": 8,
                "showExif": False,
                "displayMode": "singlePhoto",
            },
        },
        "launch_environment": {},
        "requests": [
            "settings.open",
            "settings.pin.enable",
            "settings.pin.confirm",
            "settings.pin.cancel",
            "settings.pin.unlock",
            "settings.save.autoplay",
            "settings.save.interval",
            "settings.save.exif",
            "settings.save.display_mode",
            "playback.pause",
            "playback.next",
            "playback.play",
            "playback.background",
            "playback.foreground",
            "playback.wake_controls",
        ],
        "pin_flow": {
            "wrong_pin_entered": False,
            "cancel_still_protected": True,
            "correct_pin_entered": True,
            "restart_gated": True,
            "storage_kind": "uitest_userdefaults",
        },
        "xctest_config_present": True,
        "system_pause_analog": "tvos_home_scene_phase",
        "system_pause_activation": "activate_existing_process",
        "process_rebuilt": False,
        "home_left_app_running": True,
        "screenshot_order": [
            "display-before",
            "display-after",
            "pause",
            "after-next",
            "after-play",
            "before-background",
            "after-background",
            "before-wake",
            "after-wake",
        ],
        "environment": "simulator",
    }
    (root / "host-payload.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _write_required_pngs(root: Path, *, after_play: str = "A2", after_wake: str = "A2") -> None:
    (root / "pause.png").write_bytes(_fixture_png("A1"))
    (root / "after-next.png").write_bytes(_fixture_png("A2"))
    (root / "after-play.png").write_bytes(_fixture_png(after_play))
    (root / "before-background.png").write_bytes(_fixture_png("A2"))
    (root / "after-background.png").write_bytes(_fixture_png("A2"))
    (root / "before-wake.png").write_bytes(_fixture_png("A2"))
    (root / "after-wake.png").write_bytes(_fixture_png(after_wake))
    (root / "display-before.png").write_bytes(_fixture_png("A2"))
    (root / "display-after.png").write_bytes(_compose_smart_fill("A2", "A3"))
    (root / "pin-gate.png").write_bytes(_fixture_png("A1"))
    (root / "settings-before-restart.png").write_bytes(_fixture_png("A2"))
    (root / "settings-after-restart.png").write_bytes(_fixture_png("A2"))


class PrintCommandTests(unittest.TestCase):
    def test_print_command_does_not_call_xcodebuild(self) -> None:
        calls: list[list[str]] = []
        stdout = io.StringIO()
        scheme_before = isolated_scheme_path(SCRIPT_DIR.parent).exists()
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw) / "evidence"
            code = main(
                [
                    "--platform",
                    "tvos",
                    "--destination",
                    "platform=tvOS Simulator,id=DEST-TV",
                    "--evidence-dir",
                    str(evidence),
                    "--print-command",
                ],
                stdout=stdout,
                run_xcodebuild=lambda argv, **_kwargs: calls.append(argv) or 0,
                data_available_gib=lambda: 200,
            )
        self.assertEqual(code, 0)
        self.assertEqual(calls, [])
        self.assertEqual(isolated_scheme_path(SCRIPT_DIR.parent).exists(), scheme_before)
        output = stdout.getvalue()
        self.assertIn(f"-only-testing:{TVOS_DEVICE_SELECTOR}", output)
        self.assertIn("-configuration", output)
        self.assertIn("Release", output)
        self.assertIn(f"-scheme {ISOLATED_TVOS_SCHEME}", output)
        self.assertNotIn("-scheme immichSlides-tvOS", output)
        self.assertNotIn("ENABLE_TESTABILITY=YES", output)
        self.assertNotIn("SWIFT_ENABLE_TESTABILITY=YES", output)
        self.assertNotIn("immichSlidesTests", output)
        self.assertNotIn("run_strict_e2e.py", output)
        self.assertNotIn("late-image", output)
        self.assertNotIn(FORBIDDEN_DISPLAY_MODE_KEY, output)

    def test_command_uses_release_because_debug_xctest_skips_settings_observer(self) -> None:
        command = build_xcodebuild_command(
            repo_root=SCRIPT_DIR.parent,
            destination="platform=tvOS Simulator,id=DEST-TV",
            derived_data_path=Path("/tmp/dd"),
            result_bundle_path=Path("/tmp/result.xcresult"),
            server_url="http://127.0.0.1:9/api",
            public_key="immichslides-public-e2e-key",
            evidence_dir=Path("/tmp/evidence"),
        )
        self.assertEqual(command[command.index("-configuration") + 1], "Release")
        self.assertEqual(command[command.index("-testPlan") + 1], "StrictE2E-tvOS")
        self.assertEqual(command[command.index("-scheme") + 1], ISOLATED_TVOS_SCHEME)
        self.assertIn(f"-only-testing:{TVOS_DEVICE_SELECTOR}", command)

    def test_release_device_command_does_not_compile_immichSlidesTests(self) -> None:
        # The shared tvOS scheme still adds immichSlidesTests to the dependency graph.
        # -only-testing and ENABLE_TESTABILITY
        # do not prevent compilation; *ForTesting seams are absent in Release.
        command = build_xcodebuild_command(
            repo_root=SCRIPT_DIR.parent,
            destination="platform=tvOS Simulator,id=DEST-TV",
            derived_data_path=Path("/tmp/dd"),
            result_bundle_path=Path("/tmp/result.xcresult"),
            server_url="http://127.0.0.1:9/api",
            public_key="immichslides-public-e2e-key",
            evidence_dir=Path("/tmp/evidence"),
        )
        self.assertEqual(command[command.index("-configuration") + 1], "Release")
        self.assertEqual(command[command.index("-scheme") + 1], ISOLATED_TVOS_SCHEME)
        self.assertNotEqual(command[command.index("-scheme") + 1], "immichSlides-tvOS")
        self.assertEqual(command[command.index("-testPlan") + 1], "StrictE2E-tvOS")
        self.assertIn(f"-only-testing:{TVOS_DEVICE_SELECTOR}", command)
        self.assertNotIn("ENABLE_TESTABILITY=YES", command)
        self.assertNotIn("SWIFT_ENABLE_TESTABILITY=YES", command)
        self.assertFalse(any(UNIT_TEST_TARGET in part for part in command))
        xml = isolated_tvos_scheme_xml()
        self.assertNotIn(UNIT_TEST_TARGET, xml)
        self.assertNotIn("125906F62F5D4DF400188AB4", xml)
        self.assertNotIn("immichSlides-tvOS.xctestplan", xml)
        self.assertIn(UI_TEST_TARGET, xml)
        self.assertIn("StrictE2E-tvOS.xctestplan", xml)
        self.assertFalse(isolated_scheme_path(SCRIPT_DIR.parent).exists())
        plan = json.loads((SCRIPT_DIR.parent / "StrictE2E-tvOS.xctestplan").read_text(encoding="utf-8"))
        plan_targets = {target["target"]["name"] for target in plan["testTargets"]}
        self.assertEqual(plan_targets, {UI_TEST_TARGET})
        self.assertNotIn(UNIT_TEST_TARGET, plan_targets)

    def test_isolated_scheme_write_omits_unit_tests(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = write_isolated_tvos_scheme(root)
            self.assertEqual(path, isolated_scheme_path(root))
            text = path.read_text(encoding="utf-8")
            self.assertNotIn(UNIT_TEST_TARGET, text)
            self.assertIn(UI_TEST_TARGET, text)
            remove_isolated_tvos_scheme(root)
            self.assertFalse(path.exists())

    def test_existing_isolated_scheme_is_preserved_and_not_cleaned(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = isolated_scheme_path(root)
            path.parent.mkdir(parents=True)
            foreign_contents = "foreign scheme owned by another run\n"
            path.write_text(foreign_contents, encoding="utf-8")

            with self.assertRaises(CommandError) as raised:
                write_isolated_tvos_scheme(root)
            self.assertIn("already exists", str(raised.exception))

            remove_isolated_tvos_scheme(root)
            self.assertTrue(path.is_file())
            self.assertEqual(path.read_text(encoding="utf-8"), foreign_contents)

    def test_cleanup_preserves_replaced_or_rewritten_scheme(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = write_isolated_tvos_scheme(root)
            path.unlink()
            replacement_contents = "replacement from another run\n"
            path.write_text(replacement_contents, encoding="utf-8")
            remove_isolated_tvos_scheme(root)
            self.assertEqual(path.read_text(encoding="utf-8"), replacement_contents)

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = write_isolated_tvos_scheme(root)
            rewritten_contents = "same inode but rewritten by another run\n"
            path.write_text(rewritten_contents, encoding="utf-8")
            remove_isolated_tvos_scheme(root)
            self.assertTrue(path.is_file())
            self.assertEqual(path.read_text(encoding="utf-8"), rewritten_contents)

    def test_main_collision_preserves_foreign_scheme_in_temp_repository(self) -> None:
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory() as evidence_raw:
            root = Path(raw)
            path = isolated_scheme_path(root)
            path.parent.mkdir(parents=True)
            foreign_contents = "foreign scheme from a concurrent run\n"
            path.write_text(foreign_contents, encoding="utf-8")

            stderr = io.StringIO()
            with patch.object(tvos_runner, "REPO_ROOT", root):
                code = tvos_runner.main(
                    [
                        "--platform",
                        "tvos",
                        "--destination",
                        "platform=tvOS Simulator,id=DEST-TV",
                        "--evidence-dir",
                        str(Path(evidence_raw) / "evidence"),
                    ],
                    stdout=io.StringIO(),
                    stderr=stderr,
                    run_xcodebuild=lambda *_args, **_kwargs: 0,
                    data_available_gib=lambda: 200,
                )

            self.assertNotEqual(code, 0)
            self.assertIn("already exists", stderr.getvalue())
            self.assertEqual(path.read_text(encoding="utf-8"), foreign_contents)

    def test_shared_tvos_scheme_still_lists_unit_tests(self) -> None:
        shared = (
            SCRIPT_DIR.parent
            / "immichSlides.xcodeproj/xcshareddata/xcschemes/immichSlides-tvOS.xcscheme"
        )
        text = shared.read_text(encoding="utf-8")
        self.assertIn(UNIT_TEST_TARGET, text)
        self.assertIn("immichSlides-tvOS.xctestplan", text)

    def test_strict_e2e_suite_table_does_not_gain_the_access_lifecycle_runner(self) -> None:
        self.assertNotIn("access-lifecycle-tvos", RUNNER_SUITES)
        self.assertNotIn("access-lifecycle", RUNNER_SUITES)
        self.assertNotIn(TVOS_DEVICE_SELECTOR, RUNNER_SUITES)

    def test_non_simulator_destination_is_rejected(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "tvos",
                "--destination",
                "platform=tvOS,id=DEVICE",
                "--evidence-dir",
                "/tmp/nope",
                "--print-command",
            ],
            stdout=stdout,
            stderr=stderr,
            run_xcodebuild=lambda *_args, **_kwargs: 0,
            data_available_gib=lambda: 200,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("Simulator", stderr.getvalue())

    def test_disk_below_80_stops_before_xcode(self) -> None:
        self.assertEqual(MIN_DATA_GIB, 80)
        calls: list[list[str]] = []
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "tvos",
                "--destination",
                "platform=tvOS Simulator,id=DEST-TV",
                "--evidence-dir",
                "/tmp/nope",
            ],
            stderr=stderr,
            run_xcodebuild=lambda argv, **_kwargs: calls.append(argv) or 0,
            data_available_gib=lambda: 79.9,
        )
        self.assertEqual(code, 2)
        self.assertEqual(calls, [])
        self.assertIn("80", stderr.getvalue())
        self.assertIn("--min-free-gib", stderr.getvalue())

    def test_custom_minimum_free_space_is_respected(self) -> None:
        stderr = io.StringIO()
        with patch(
            "run_access_lifecycle_tvos.write_isolated_tvos_scheme",
            side_effect=CommandError("reached post-disk setup"),
        ) as write_scheme:
            code = main(
                [
                    "--platform",
                    "tvos",
                    "--destination",
                    "platform=tvOS Simulator,id=DEST-TV",
                    "--evidence-dir",
                    "/tmp/access-lifecycle-custom-disk",
                    "--min-free-gib",
                    "70",
                ],
                stderr=stderr,
                run_xcodebuild=lambda *_args, **_kwargs: 0,
                data_available_gib=lambda: 75,
            )
        self.assertEqual(code, 2)
        self.assertIn("reached post-disk setup", stderr.getvalue())
        write_scheme.assert_called_once()


class DeviceEvidenceTests(unittest.TestCase):
    def test_valid_screenshots_and_payload_pass_without_claiming_apple_tv(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            result = evaluate_device_evidence(root, fixture_set="a")
            self.assertEqual(result["verdict"], "PASS")
            self.assertEqual(result["d01"], "PARTIAL")
            self.assertEqual(result["environment"], "simulator")
            self.assertNotEqual(result["environment"], "apple_tv")
            self.assertEqual(result["fixture_sha256"], FROZEN_FIXTURE_SHA256["a"])
            self.assertEqual(result["scenes"]["after_play"], "A2")
            self.assertEqual(result["progress_after_play"], 0)
            self.assertEqual(result["system_pause_analog"], "tvos_home_scene_phase")
            self.assertEqual(result["classified"]["display_before"]["mark"], "A2")
            self.assertEqual(result["classified"]["display_before"]["status"], "MATCH")
            self.assertIn("A3", result["display"]["partner_marks"])
            self.assertFalse(result["display"].get("before_partner_marks"))
            self.assertEqual(result["display"]["before_mark"], "A2")

    def test_old_scene_after_play_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root, after_play="A1")
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("Returning to the previous scene", str(raised.exception))

    def test_wake_switch_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root, after_wake="A3")
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("Changing photos while waking the controls", str(raised.exception))

    def test_hidden_wake_between_background_identity_fails_closed(self) -> None:
        # hidden-control-wake-2 was captured before after-background.
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            wake = root / "hidden-control-wake-2-after.png"
            wake.write_bytes(_fixture_png("A2"))
            base = (root / "before-background.png").stat().st_mtime
            os.utime(root / "before-background.png", (base, base))
            os.utime(wake, (base + 1, base + 1))
            os.utime(root / "after-background.png", (base + 2, base + 2))
            with self.assertRaises(CommandError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("wake the control bar", str(raised.exception))
            self.assertIn("identity", str(raised.exception))

    def test_payload_wake_before_identity_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            payload = json.loads((root / "host-payload.json").read_text(encoding="utf-8"))
            payload["screenshot_order"] = [
                "display-before",
                "display-after",
                "before-background",
                "hidden-control-wake-2-after",
                "after-background",
            ]
            (root / "host-payload.json").write_text(
                json.dumps(payload, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            _write_required_pngs(root)
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("Capture identity after background return", str(raised.exception))
            self.assertIn("waking the control bar", str(raised.exception))

    def test_background_jump_still_fails_after_timing_fields(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "after-background.png").write_bytes(_fixture_png("A3"))
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("background return", str(raised.exception))
            self.assertIn("Changing photos", str(raised.exception))

    def test_missing_pin_or_settings_screenshots_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "pin-gate.png").unlink()
            with self.assertRaises(CommandError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("PIN", str(raised.exception))

    def test_missing_display_mode_screenshots_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-after.png").unlink()
            with self.assertRaises(CommandError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("Display mode", str(raised.exception))

    def test_identical_display_mode_screenshots_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-after.png").write_bytes((root / "display-before.png").read_bytes())
            with self.assertRaises((CommandError, AccessLifecycleContractError)) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("Display policy did not take effect", str(raised.exception))

    def test_single_photo_swap_display_pair_fails_as_host_negative(self) -> None:
        # Replacing A4 with A5 changes bytes, but both frames classify as MATCH and neither shows a partner, so they must not pass.
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_single_photo_swap_display("display-before.png"))
            (root / "display-after.png").write_bytes(_single_photo_swap_display("display-after.png"))
            with self.assertRaises((CommandError, AccessLifecycleContractError)) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            message = str(raised.exception)
            self.assertNotIn("Display policy did not take effect", message)
            self.assertTrue(
                "display-before must show a portrait or square photo" in message
                or "A settings round trip must not switch to a different single photo" in message
                or "The main photo must remain the public fixture shown before opening settings" in message
                or "Smart Fill must be visible in the after image" in message,
                message,
            )

    def test_pool_end_single_photo_display_pair_fails_as_host_negative(self) -> None:
        # A single A5 photo at the end of the pool is not smart fill.
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_pool_end_single_photo_display("display-before.png"))
            (root / "display-after.png").write_bytes(_pool_end_single_photo_display("display-after.png"))
            with self.assertRaises((CommandError, AccessLifecycleContractError)) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            message = str(raised.exception)
            self.assertIn("The comparison must not advance to the last pool photo A5", message)
            report = json.loads((root / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(report["verdict"], "FAIL")
            self.assertTrue(
                "The comparison must not advance to the last pool photo A5"
                in str(report.get("error") or ""),
                report.get("error"),
            )
            self.assertEqual(report["classified"]["display_before"]["mark"], "A5")
            self.assertEqual(report["classified"]["display_after"]["regions"]["center"]["mark"], "A5")
            self.assertFalse(report["classified"]["display_after"].get("partner_marks"))

    def test_side_by_side_transition_display_pair_passes_region_aggregate(self) -> None:
        # A2 on the left and A3 on the right pass by region even while the full frame is TRANSITION.
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_side_by_side_transition_display("display-before.png"))
            (root / "display-after.png").write_bytes(_side_by_side_transition_display("display-after.png"))
            result = evaluate_device_evidence(root, fixture_set="a")
            self.assertEqual(result["verdict"], "PASS")
            self.assertEqual(result["classified"]["display_before"]["mark"], "A2")
            self.assertEqual(result["classified"]["display_after"]["regions"]["full"]["status"], "TRANSITION")
            self.assertEqual(result["classified"]["display_after"]["regions"]["left"]["mark"], "A2")
            self.assertEqual(result["classified"]["display_after"]["regions"]["right"]["mark"], "A3")
            self.assertIn("A3", result["display"]["partner_marks"])
            self.assertIsNone(result["display"].get("error"))

    def test_unchanged_fullbleed_display_pair_fails_as_host_negative(self) -> None:
        # Identical full-screen A1 frames do not demonstrate that the display policy took effect.
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_unchanged_fullbleed_display("display-before.png"))
            (root / "display-after.png").write_bytes(_unchanged_fullbleed_display("display-after.png"))
            with self.assertRaises((CommandError, AccessLifecycleContractError)) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("Display policy did not take effect", str(raised.exception))
            report = json.loads((root / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(report["verdict"], "FAIL")
            self.assertEqual(report["classified"]["display_before"]["mark"], "A1")
            self.assertEqual(report["classified"]["display_after"]["mark"], "A1")
            self.assertFalse(report.get("display", {}).get("partner_marks"))

    def test_a1_fullbleed_before_with_smart_fill_after_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_fixture_png("A1"))
            (root / "display-after.png").write_bytes(_compose_smart_fill("A1", "A3"))
            with self.assertRaises((CommandError, AccessLifecycleContractError)) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("The comparison must not stop on full-bleed A1", str(raised.exception))
            self.assertIn("A1", str(raised.exception))

    def test_a5_pool_end_before_with_smart_fill_after_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_fixture_png("A5"))
            (root / "display-after.png").write_bytes(_compose_smart_fill("A5", "A2"))
            with self.assertRaises((CommandError, AccessLifecycleContractError)) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("The comparison must not advance to the last pool photo A5", str(raised.exception))

    def test_before_side_partner_is_not_letterbox(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_compose_side_partner("A2", "A3"))
            (root / "display-after.png").write_bytes(_compose_smart_fill("A2", "A4"))
            with self.assertRaises((CommandError, AccessLifecycleContractError)) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn(
                "The side margins in before must not already show the second public fixture",
                str(raised.exception),
            )

    def test_display_after_pool_burn_fails_even_with_smart_fill_pixels(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            payload = json.loads((root / "host-payload.json").read_text(encoding="utf-8"))
            payload["screenshot_order"] = [
                "pause",
                "after-next",
                "after-play",
                "before-background",
                "after-background",
                "before-wake",
                "after-wake",
                "display-before",
                "display-after",
            ]
            (root / "host-payload.json").write_text(
                json.dumps(payload, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            _write_required_pngs(root)
            with self.assertRaises((CommandError, AccessLifecycleContractError)) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("exhausts the playback pool", str(raised.exception))
            self.assertTrue((root / "visual-identity-runner.json").is_file())

    def test_display_failure_writes_visual_identity_runner_json(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-after.png").write_bytes((root / "display-before.png").read_bytes())
            with self.assertRaises((CommandError, AccessLifecycleContractError)):
                evaluate_device_evidence(root, fixture_set="a")
            report = json.loads((root / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(report["verdict"], "FAIL")
            self.assertIn("Display policy did not take effect", str(report.get("error") or ""))
            self.assertIn("regions", report["classified"]["display_after"])

    def test_two_match_singles_are_not_smart_fill(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_fixture_png("A2"))
            (root / "display-after.png").write_bytes(_fixture_png("A3"))
            with self.assertRaises((CommandError, AccessLifecycleContractError)) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("A settings round trip must not switch to a different single photo", str(raised.exception))

    def test_unrecognizable_or_garbage_display_after_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-after.png").write_bytes(_noise())
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("Unrecognizable input", str(raised.exception))
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-after.png").write_bytes(b"not-a-png")
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("Unrecognizable input", str(raised.exception))

    def test_side_by_side_public_fixtures_pass_despite_full_transition(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_fixture_png("A2"))
            (root / "display-after.png").write_bytes(_side_by_side("A2", "A3"))
            result = evaluate_device_evidence(root, fixture_set="a")
            self.assertEqual(result["verdict"], "PASS")
            self.assertEqual(result["classified"]["display_after"]["regions"]["full"]["status"], "TRANSITION")
            self.assertIn("A3", result["display"]["partner_marks"])
            self.assertEqual(result["classified"]["display_after"]["regions"]["left"]["mark"], "A2")
            self.assertEqual(result["classified"]["display_after"]["regions"]["right"]["mark"], "A3")

    def test_transition_overlay_is_not_smart_fill(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_fixture_png("A2"))
            (root / "display-after.png").write_bytes(_checkerboard_mix("A2", "A3"))
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("TRANSITION", str(raised.exception))

    def test_black_or_blank_display_after_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-after.png").write_bytes(_solid((0, 0, 0)))
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("All-black output", str(raised.exception))
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-after.png").write_bytes(_solid((255, 255, 255)))
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("Blank output", str(raised.exception))

    def test_same_single_photo_without_partner_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / "display-before.png").write_bytes(_fixture_png("A2"))
            from PIL import ImageEnhance

            darkened = ImageEnhance.Brightness(
                Image.open(io.BytesIO(_fixture_png("A2"))).convert("RGB")
            ).enhance(0.55)
            (root / "display-after.png").write_bytes(_png_bytes(darkened))
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("Smart Fill must be visible in the after image", str(raised.exception))

    def test_pin_in_filename_fails_without_echoing_pin(self) -> None:
        pins = synthetic_pin_values()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            (root / f"gate-{pins[0]}.png").write_bytes(_fixture_png("A1"))
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("PIN", str(raised.exception))
            for pin in pins:
                self.assertNotIn(pin, str(raised.exception))

    def test_derived_data_pin_does_not_fail_device_evidence(self) -> None:
        pins = synthetic_pin_values()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            derived = root / "DerivedData" / "Build" / "Products"
            derived.mkdir(parents=True)
            (derived / f"pin-{pins[0]}.log").write_text(f"PIN={pins[0]}\n", encoding="utf-8")
            result = evaluate_device_evidence(root, fixture_set="a")
            self.assertEqual(result["verdict"], "PASS")

    def test_persistent_command_pin_still_fails_with_derived_data_present(self) -> None:
        pins = synthetic_pin_values()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            _write_required_pngs(root)
            derived = root / "DerivedData" / "Logs"
            derived.mkdir(parents=True)
            (derived / "build.log").write_text(f"PIN={pins[0]}\n", encoding="utf-8")
            (root / "xcodebuild-command.txt").write_text(
                f"xcodebuild test PIN={pins[0]}\n",
                encoding="utf-8",
            )
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("PIN", str(raised.exception))
            for pin in pins:
                self.assertNotIn(pin, str(raised.exception))


class ForcedDisplayModeTests(unittest.TestCase):
    def test_host_payload_with_forced_display_mode_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _write_host_payload(root)
            payload = json.loads((root / "host-payload.json").read_text(encoding="utf-8"))
            payload["launch_environment"] = {FORBIDDEN_DISPLAY_MODE_KEY: "singlePhoto"}
            (root / "host-payload.json").write_text(
                json.dumps(payload, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            _write_required_pngs(root)
            with self.assertRaises(AccessLifecycleContractError) as raised:
                evaluate_device_evidence(root, fixture_set="a")
            self.assertIn("forced display mode", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
