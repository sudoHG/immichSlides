#!/usr/bin/env python3
"""Shared offline contract: fail-closed checks, PIN redaction and formal-storage PARTIAL must fail first."""

from __future__ import annotations

import gzip
import io
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Callable
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from run_offline_unit_tests import ACCESS_LIFECYCLE_HOST_SELECTORS  # noqa: E402
from sensitive_scan_test_support import compressed_byte_coincidence  # noqa: E402
from access_lifecycle_contract import (  # noqa: E402
    AccessLifecycleContractError,
    ALLOWED_SYSTEM_PAUSE_ACTIVATION,
    FROZEN_FIXTURE_SHA256,
    FORBIDDEN_DISPLAY_MODE_KEY,
    FORBIDDEN_SETTINGS_SOURCES,
    KNOWN_REQUESTS,
    NEW_STABLE_MARK_CONFIRM_WINDOW,
    NEW_STABLE_MARK_MIN_LUMA,
    NEW_STABLE_MARK_POLL_INTERVAL,
    PLAYBACK_LAYER_PREFIX,
    NON_PLAYBACK_LAYER_PREFIXES,
    HIDDEN_CONTROL_BAR_PLAYBACK_IDENTIFIER,
    MIN_STABLE_HIDDEN_WAKE_FOCUS_OBSERVATIONS,
    assert_appletv_double_layout_visible,
    assert_display_before_letterbox,
    assert_display_before_pool_burn,
    assert_display_strategy_visible,
    assert_returned_to_slideshow,
    assert_settings_open,
    assert_settings_return_wake,
    assert_system_pause_activation,
    assert_system_pause_identity_timing,
    assert_unshown_display_partners,
    capture_identity,
    classify_display_regions,
    confirm_wait,
    evaluate_access_lifecycle_evidence,
    inspect_display_strategy,
    is_confirmed_new_stable_mark,
    is_slideshow_layer,
    logical_content_bytes,
    poll_wait,
    scan_sensitive_evidence,
    wait_for_new_stable_mark,
    _zstd_cli_frame,
    _zstd_frame_size,
)

from PIL import Image, ImageDraw, ImageFilter  # noqa: E402

from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256 as FILTER_FROZEN_SHA256  # noqa: E402
from strict_e2e_photo_identity import classify_screenshot  # noqa: E402
from strict_e2e_server import _fixture_data  # noqa: E402


# Evidence bundles must never contain a PIN; tests synthesize it only in a temp directory.
# Source must not write a six-digit PIN as a literal.
SYNTHETIC_PIN = "".join(chr(ord("0") + digit) for digit in (2, 4, 6, 8, 0, 1))
# UI-test all-ones and all-zeroes values that once caused a false positive.
DEVICE_SYNTHETIC_PINS = [chr(ord("0") + 1) * 6, chr(ord("0") + 0) * 6]


def _zstd_content_frame(payload: bytes) -> bytes:
    completed = subprocess.run(
        ["zstd", "-q", "-c"],
        input=payload,
        check=True,
        capture_output=True,
    )
    return completed.stdout


def _zstd_skippable_frame(user_data: bytes) -> bytes:
    return (0x184D2A50).to_bytes(4, "little") + len(user_data).to_bytes(4, "little") + user_data


def _gzip_content_frame(payload: bytes) -> bytes:
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb") as handle:
        handle.write(payload)
    return buffer.getvalue()


# Synthetic large blob: densely packed fake gzip magic provokes repeated searching at every offset.
# Keep generated evidence bundles out of the repository.
LARGE_XCRESULT_NOISE_SIZE = 4 * 1024 * 1024
LARGE_XCRESULT_SCAN_DEADLINE_SECONDS = 8.0
_FALSE_GZIP_UNIT = b"\x1f\x8b\x08\x00" + b"\x00" * 12


def _large_xcresult_noise() -> bytes:
    repeats, leftover = divmod(LARGE_XCRESULT_NOISE_SIZE, len(_FALSE_GZIP_UNIT))
    return _FALSE_GZIP_UNIT * repeats + _FALSE_GZIP_UNIT[:leftover]


def _valid_payload(**overrides: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "status": "ran",
        "identity_source": "public_fixture_photo_mark",
        "settings": {
            "source": "real_settings_ui",
            "before": {
                "autoPlayEnabled": False,
                "intervalSeconds": 12,
                "showExif": False,
                "displayMode": "singlePhoto",
            },
            "after_restart": {
                "autoPlayEnabled": False,
                "intervalSeconds": 12,
                "showExif": False,
                "displayMode": "singlePhoto",
            },
        },
        "launch_environment": {},
        "scenes": {
            "pause": "A1",
            "after_next": "A2",
            "after_play": "A2",
            "before_background": "A2",
            "after_background": "A2",
            "before_wake": "A2",
            "after_wake": "A2",
        },
        "progress_after_play": 0,
        "requests": [
            "settings.open",
            "settings.save.autoplay",
            "playback.pause",
            "playback.next",
            "playback.play",
        ],
        "screenshots": {
            "pause": "pause.png",
            "after_next": "after-next.png",
            "after_play": "after-play.png",
            "after_background": "after-background.png",
            "after_wake": "after-wake.png",
        },
        "pin_flow": {
            "wrong_pin_entered": False,
            "cancel_still_protected": True,
            "correct_pin_entered": True,
            "restart_gated": True,
            "storage_kind": "uitest_userdefaults",
        },
        "xctest_config_present": True,
        "fixture_set": "a",
        "fixture_sha256": FILTER_FROZEN_SHA256["a"],
    }
    payload.update(overrides)
    return payload


def _device_payload(**overrides: object) -> dict[str, object]:
    payload = _valid_payload()
    screenshots = dict(payload["screenshots"])  # type: ignore[arg-type]
    screenshots.update(
        {
            "display_before": "display-before.png",
            "display_after": "display-after.png",
            "pin_restart_gate": "pin-restart-gate.png",
            "settings_after_restart": "settings-after-restart.png",
        }
    )
    payload["screenshots"] = screenshots
    payload["device"] = "iphone"
    payload["device_tests_run"] = True
    payload["retries_used_to_pass"] = False
    payload["display_policy"] = {
        "source": "real_settings_ui",
        "mode_before": "smartFill",
        "mode_after": "singlePhoto",
        "png_sha256_before": "a" * 64,
        "png_sha256_after": "b" * 64,
        "mark_before": "A2",
        "mark_after": "A2",
    }
    payload.update(overrides)
    return payload


def _system_pause_payload(**overrides: object) -> dict[str, object]:
    payload = _valid_payload()
    payload["system_pause_analog"] = "tvos_home_scene_phase"
    payload["system_pause_activation"] = "activate_existing_process"
    payload["process_rebuilt"] = False
    payload["home_left_app_running"] = True
    payload["screenshot_order"] = [
        "pause",
        "after-next",
        "after-play",
        "before-background",
        "after-background",
        "before-wake",
        "after-wake",
    ]
    payload.update(overrides)
    return payload


def _device_payload_ready_for_background(
    *,
    autoplay_enabled: bool = True,
    interval_seconds: int = 12,
    wait_seconds: float = 14,
    progress_after_next: float = 0,
    progress_after_play: float = 0,
) -> dict[str, object]:
    payload = _device_payload()
    screenshots = dict(payload["screenshots"])  # type: ignore[arg-type]
    screenshots["settings_at_background"] = "settings-at-background.png"
    payload["screenshots"] = screenshots
    payload["settings_at_background"] = {
        "source": "real_settings_ui",
        "autoPlayEnabled": autoplay_enabled,
        "intervalSeconds": interval_seconds,
        "showExif": False,
        "displayMode": "singlePhoto",
    }
    payload["background"] = {
        "wait_seconds": wait_seconds,
        "interval_seconds": interval_seconds,
    }
    payload["progress_after_next"] = progress_after_next
    payload["progress_after_play"] = progress_after_play
    payload["progress_source"] = "slideshow.smartfill.motionFrame.summary"
    payload["progress_raw_after_next"] = (
        "eventType=motionFrame;renderRole=stable;progress=0.000000"
    )
    payload["progress_raw_after_play"] = (
        "eventType=motionFrame;renderRole=stable;progress=0.000000"
    )
    settings = dict(payload["settings"])  # type: ignore[arg-type]
    settings["before"] = {
        "autoPlayEnabled": True,
        "intervalSeconds": interval_seconds,
        "showExif": False,
        "displayMode": "singlePhoto",
    }
    settings["after_restart"] = dict(settings["before"])  # type: ignore[arg-type]
    payload["settings"] = settings
    return payload


class FailClosedTests(unittest.TestCase):
    def test_skip_cannot_pass(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(_valid_payload(status="skip"))
        self.assertIn("skip", str(raised.exception))
        self.assertNotIn("PASS", str(raised.exception))

    def test_missing_screenshot_cannot_pass(self) -> None:
        payload = _valid_payload()
        screenshots = dict(payload["screenshots"])  # type: ignore[arg-type]
        del screenshots["after_play"]
        payload["screenshots"] = screenshots
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Missing screenshots", str(raised.exception))

    def test_unknown_request_cannot_pass(self) -> None:
        payload = _valid_payload(requests=["settings.open", "/not-a-real-route"])
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Unknown request", str(raised.exception))
        self.assertIn("/not-a-real-route", str(raised.exception))

    def test_unchanged_default_settings_cannot_pass_as_persisted(self) -> None:
        payload = _valid_payload()
        defaults = {
            "autoPlayEnabled": True,
            "intervalSeconds": 5,
            "showExif": True,
            "displayMode": "smartFill",
        }
        settings = dict(payload["settings"])  # type: ignore[arg-type]
        settings["before"] = defaults
        settings["after_restart"] = dict(defaults)
        payload["settings"] = settings
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Settings were not persisted", str(raised.exception))

    def test_black_or_unrecognizable_scene_cannot_pass(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_play"] = "BLACK"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("All-black output", str(raised.exception))

        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_wake"] = "UNRECOGNIZABLE"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Unrecognizable input", str(raised.exception))

    def test_blank_scene_cannot_pass(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["pause"] = "BLANK"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Blank output", str(raised.exception))

    def test_retry_masking_cannot_pass(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(_valid_payload(retries_used_to_pass=True))
        self.assertIn("Retry", str(raised.exception))

    def test_ipad_missing_license_stack_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background()
        payload["device"] = "ipad"
        payload.pop("ipad_license_return", None)
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("return stack", str(raised.exception))

    def test_display_policy_same_png_cannot_pass_when_device_ran(self) -> None:
        payload = _device_payload_ready_for_background()
        display = dict(payload["display_policy"])  # type: ignore[arg-type]
        display["png_sha256_after"] = display["png_sha256_before"]
        payload["display_policy"] = display
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("display policy", str(raised.exception))

    def test_valid_device_payload_marks_device_tests_run(self) -> None:
        result = evaluate_access_lifecycle_evidence(_device_payload_ready_for_background())
        self.assertTrue(result["device_tests_run"])
        self.assertEqual(result["d01"], "PARTIAL")
        self.assertEqual(result["verdict"], "PASS")

    def test_settings_not_persisted_cannot_pass(self) -> None:
        payload = _valid_payload()
        settings = dict(payload["settings"])  # type: ignore[arg-type]
        settings["after_restart"] = {
            "autoPlayEnabled": True,
            "intervalSeconds": 5,
            "showExif": True,
            "displayMode": "smartFill",
        }
        payload["settings"] = settings
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Settings were not persisted", str(raised.exception))

    def test_launch_argument_cannot_impersonate_settings(self) -> None:
        payload = _valid_payload()
        settings = dict(payload["settings"])  # type: ignore[arg-type]
        settings["source"] = "launch_argument"
        payload["settings"] = settings
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("formal persistence", str(raised.exception))

    def test_userdefaults_injection_cannot_impersonate_settings(self) -> None:
        payload = _valid_payload()
        settings = dict(payload["settings"])  # type: ignore[arg-type]
        settings["source"] = "userdefaults_injection"
        payload["settings"] = settings
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("formal persistence", str(raised.exception))

    def test_old_scene_return_after_play_cannot_pass(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_play"] = "A1"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("previous scene", str(raised.exception))

    def test_background_jump_cannot_pass(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_background"] = "A3"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("background return", str(raised.exception))

    def test_wake_switch_cannot_pass(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_wake"] = "A3"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("waking the controls", str(raised.exception))

    def test_stacked_mark_wake_switch_still_fail_closed(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes.update(
            {
                "after_next": "A4+A1",
                "after_play": "A4+A1",
                "before_background": "A4+A1",
                "after_background": "A4+A1",
                "before_wake": "A4+A1",
                "after_wake": "A5",
            }
        )
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Changing photos while waking the controls", str(raised.exception))

    def test_stacked_region_scene_marks_are_not_unrecognizable(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes.update(
            {
                "after_next": "A4+A1",
                "after_play": "A4+A1",
                "before_background": "A4+A1",
                "after_background": "A4+A1",
                "before_wake": "A4+A1",
                "after_wake": "A4+A1",
            }
        )
        payload["scenes"] = scenes
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")

    def test_forced_display_mode_cannot_pass(self) -> None:
        payload = _valid_payload(
            launch_environment={"UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE": "singlePhoto"}
        )
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("forced display mode", str(raised.exception))

    def test_progress_after_play_must_be_zero(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(_valid_payload(progress_after_play=3))
        self.assertIn("progress", str(raised.exception))

    def test_device_missing_settings_at_background_screenshot_cannot_pass(self) -> None:
        payload = _device_payload()
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Missing screenshots", str(raised.exception))
        self.assertIn("settings_at_background", str(raised.exception))

    def test_device_autoplay_off_at_background_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background(autoplay_enabled=False)
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Autoplay", str(raised.exception))

    def test_device_wait_equal_to_read_interval_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background(
            interval_seconds=14,
            wait_seconds=14,
        )
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("interval", str(raised.exception))

    def test_device_wait_not_bound_to_read_interval_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background(interval_seconds=12, wait_seconds=16)
        background = dict(payload["background"])  # type: ignore[arg-type]
        background["interval_seconds"] = 14
        payload["background"] = background
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("interval", str(raised.exception))

    def test_device_missing_progress_after_next_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background()
        payload.pop("progress_after_next", None)
        payload["progress_after_play"] = 0
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Progress", str(raised.exception))

    def test_device_progress_after_next_nonzero_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background(progress_after_next=0.4)
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("progress", str(raised.exception))

    def test_device_progress_without_probe_raw_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background()
        payload["progress_raw_after_next"] = ""
        payload["progress_raw_after_play"] = ""
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Progress", str(raised.exception))

    def test_device_presentation_probe_raw_counts_as_measured_progress(self) -> None:
        payload = _device_payload_ready_for_background()
        payload["progress_source"] = "slideshow.scenePresentation.contract.summary"
        payload["progress_raw_after_next"] = (
            "schemaVersion=scene-presentation-contract-probe-v1;"
            "phase=stablePhoto;motionRawProgress=0.000000"
        )
        payload["progress_raw_after_play"] = (
            "schemaVersion=scene-presentation-contract-probe-v1;"
            "phase=stablePhoto;motionRawProgress=0.000000"
        )
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")

    def test_device_restart_autoplay_off_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background()
        settings = dict(payload["settings"])  # type: ignore[arg-type]
        settings["before"] = {
            "autoPlayEnabled": False,
            "intervalSeconds": 12,
            "showExif": False,
            "displayMode": "singlePhoto",
        }
        settings["after_restart"] = dict(settings["before"])  # type: ignore[arg-type]
        payload["settings"] = settings
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Settings were not persisted", str(raised.exception))

    def test_device_measured_play_progress_may_advance_on_new_scene(self) -> None:
        payload = _device_payload_ready_for_background(progress_after_play=0.05)
        payload["progress_raw_after_play"] = (
            "eventType=motionFrame;renderRole=stable;progress=0.050000"
        )
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")

    def test_official_iphone_shape_cannot_pass_as_executed_spec(self) -> None:
        payload = _device_payload()
        payload["progress_after_play"] = 0
        payload["settings"] = {
            "source": "real_settings_ui",
            "before": {
                "autoPlayEnabled": False,
                "intervalSeconds": 14,
                "showExif": False,
                "displayMode": "smartFill",
            },
            "after_restart": {
                "autoPlayEnabled": False,
                "intervalSeconds": 14,
                "showExif": False,
                "displayMode": "smartFill",
            },
        }
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        error = str(raised.exception)
        self.assertTrue(
            "Missing screenshots" in error or "Autoplay" in error or "Progress" in error or "interval" in error,
            error,
        )

    def test_log_or_index_cannot_be_identity(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(_valid_payload(identity_source="asset_id"))
        self.assertIn("Identity", str(raised.exception))

    def test_wrong_pin_entry_cannot_pass(self) -> None:
        payload = _valid_payload()
        pin_flow = dict(payload["pin_flow"])  # type: ignore[arg-type]
        pin_flow["wrong_pin_entered"] = True
        payload["pin_flow"] = pin_flow
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("incorrect PIN", str(raised.exception))
        self.assertNotIn(SYNTHETIC_PIN, str(raised.exception))

    def test_cancel_dropping_protection_cannot_pass(self) -> None:
        payload = _valid_payload()
        pin_flow = dict(payload["pin_flow"])  # type: ignore[arg-type]
        pin_flow["cancel_still_protected"] = False
        payload["pin_flow"] = pin_flow
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("cancelling", str(raised.exception))

    def test_uitest_storage_cannot_claim_formal_keychain(self) -> None:
        payload = _valid_payload()
        pin_flow = dict(payload["pin_flow"])  # type: ignore[arg-type]
        pin_flow["storage_kind"] = "keychain"
        payload["pin_flow"] = pin_flow
        payload["xctest_config_present"] = True
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Keychain", str(raised.exception))

    def test_keychain_failure_stays_partial(self) -> None:
        payload = _valid_payload()
        pin_flow = dict(payload["pin_flow"])  # type: ignore[arg-type]
        pin_flow["storage_kind"] = "keychain_failure"
        payload["pin_flow"] = pin_flow
        payload["xctest_config_present"] = False
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["d01"], "PARTIAL")
        self.assertNotEqual(result["verdict"], "PASS")
        self.assertEqual(result["verdict"], "PARTIAL")

    def test_valid_host_contract_passes_without_claiming_device_ui(self) -> None:
        result = evaluate_access_lifecycle_evidence(_valid_payload())
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["d01"], "PARTIAL")
        self.assertEqual(result["fixture_sha256"], FROZEN_FIXTURE_SHA256["a"])
        self.assertFalse(result["device_tests_run"])
        self.assertFalse(result["skip_counted_as_pass"])


class SensitiveScanTests(unittest.TestCase):
    def test_pin_in_filename_fails_without_echoing_pin(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / f"gate-{SYNTHETIC_PIN}.png").write_bytes(b"not-an-image")
            with self.assertRaises(AccessLifecycleContractError) as raised:
                scan_sensitive_evidence(root, [SYNTHETIC_PIN])
            self.assertIn("PIN", str(raised.exception))
            self.assertNotIn(SYNTHETIC_PIN, str(raised.exception))

    def test_pin_in_command_log_or_attachment_fails(self) -> None:
        cases = {
            "commands.txt": f"xcodebuild test -only-testing PIN={SYNTHETIC_PIN}\n",
            "service.log": f"entered pin {SYNTHETIC_PIN}\n",
            "notes.json": json.dumps({"attachment": SYNTHETIC_PIN}),
        }
        for name, content in cases.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as raw:
                    root = Path(raw)
                    (root / name).write_text(content, encoding="utf-8")
                    with self.assertRaises(AccessLifecycleContractError) as raised:
                        scan_sensitive_evidence(root, [SYNTHETIC_PIN])
                    self.assertIn("PIN", str(raised.exception))
                    self.assertNotIn(SYNTHETIC_PIN, str(raised.exception))

    def test_task_derived_data_is_not_final_persistent_evidence(self) -> None:
        # DerivedData remained under the evidence root while device evidence was evaluated.
        pin = DEVICE_SYNTHETIC_PINS[0]
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            derived = root / "DerivedData" / "Build" / "Intermediates.noindex"
            derived.mkdir(parents=True)
            (derived / f"pin-{pin}.log").write_text(f"PIN={pin}\n", encoding="utf-8")
            (root / "xcodebuild-command.txt").write_text(
                "xcodebuild -derivedDataPath DerivedData test\n",
                encoding="utf-8",
            )
            result = scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)
            self.assertEqual(result["result"], "PASS")
            self.assertEqual(result["matched_files"], [])

    def test_persistent_pin_leak_still_fails_when_derived_data_also_leaks(self) -> None:
        pin = DEVICE_SYNTHETIC_PINS[0]
        cases = {
            "xcodebuild-command.txt": f"xcodebuild test PIN={pin}\n",
            "xcodebuild.log": f"entered pin {pin}\n",
            "service.log": f"pin {pin}\n",
            "notes.json": json.dumps({"attachment": pin}),
            f"gate-{pin}.png": "not-an-image",
        }
        for name, content in cases.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as raw:
                    root = Path(raw)
                    derived = root / "DerivedData" / "Logs"
                    derived.mkdir(parents=True)
                    (derived / "build.log").write_text(f"PIN={pin}\n", encoding="utf-8")
                    (root / name).write_text(content, encoding="utf-8")
                    with self.assertRaises(AccessLifecycleContractError) as raised:
                        scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)
                    self.assertIn("PIN", str(raised.exception))
                    for value in DEVICE_SYNTHETIC_PINS:
                        self.assertNotIn(value, str(raised.exception))

    def test_xcresult_pin_still_fails_when_derived_data_present(self) -> None:
        pin = DEVICE_SYNTHETIC_PINS[0]
        logical = f"entered pin {pin}\n".encode("utf-8")
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            derived = root / "DerivedData" / "Build"
            derived.mkdir(parents=True)
            (derived / f"pin-{pin}.bin").write_bytes(logical)
            payload = root / "access-lifecycle-tvos.xcresult" / "Data" / "payload.bin"
            payload.parent.mkdir(parents=True)
            payload.write_bytes(_zstd_content_frame(logical))
            with self.assertRaises(AccessLifecycleContractError) as raised:
                scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)
            self.assertIn("PIN", str(raised.exception))
            for value in DEVICE_SYNTHETIC_PINS:
                self.assertNotIn(value, str(raised.exception))

    def test_redacted_evidence_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "commands.txt").write_text(
                "python3 scripts/test_access_lifecycle_contract.py -v\n",
                encoding="utf-8",
            )
            (root / "pin-gate.png").write_bytes(b"redacted")
            (root / "notes.json").write_text(
                json.dumps({"pin": "<redacted-pin>"}),
                encoding="utf-8",
            )
            result = scan_sensitive_evidence(root, [SYNTHETIC_PIN])
            self.assertEqual(result["result"], "PASS")
            self.assertEqual(result["matched_files"], [])

    def test_skippable_payload_with_pin_fails(self) -> None:
        pin = DEVICE_SYNTHETIC_PINS[0]
        logical = b"<?xml version=\"1.0\"?><plist><string>no-pin</string></plist>"
        blob = _zstd_skippable_frame(pin.encode("utf-8")) + _zstd_content_frame(logical)
        self.assertIn(pin.encode("utf-8"), blob)
        self.assertNotIn(pin.encode("utf-8"), logical)
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "xcresult-data.bin").write_bytes(blob)
            with self.assertRaises(AccessLifecycleContractError):
                scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)

    def test_undecodable_zstd_with_plaintext_pin_fails(self) -> None:
        pin = DEVICE_SYNTHETIC_PINS[0]
        blob = b"\x28\xb5\x2f\xfd" + pin.encode("utf-8") + b"not-a-frame"
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "xcresult-data.bin").write_bytes(blob)
            with self.assertRaises(AccessLifecycleContractError):
                scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)

    def test_genuinely_compressed_pattern_with_clean_logical_content_passes(self) -> None:
        blob, logical, needle = compressed_byte_coincidence()
        self.assertIn(needle.encode(), blob)
        self.assertNotIn(needle.encode(), logical)
        self.assertEqual(subprocess.run(
            ["zstd", "-q", "-d", "-c"], input=blob, capture_output=True, check=True
        ).stdout, logical)
        self.assertEqual(_zstd_cli_frame(blob, 0), (logical, len(blob)))
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "xcresult-data.bin").write_bytes(blob)
            result = scan_sensitive_evidence(root, [needle])
            self.assertEqual(result["result"], "PASS")
            self.assertEqual(result["matched_files"], [])

    def test_cli_only_zstd_plaintext_tail_with_pin_fails(self) -> None:
        blob = _zstd_content_frame(b"safe") + DEVICE_SYNTHETIC_PINS[0].encode()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "xcresult-data.bin").write_bytes(blob)
            with mock.patch("access_lifecycle_contract._zstd_py314", return_value=None), mock.patch(
                "access_lifecycle_contract._load_libzstd", return_value=None
            ):
                with self.assertRaises(AccessLifecycleContractError):
                    scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)

    def test_zstd_cli_accounts_for_header_fields_and_raw_rle_blocks(self) -> None:
        for single_segment in (False, True):
            for size_flag in range(4):
                for dictionary_flag, dictionary_bytes in enumerate((0, 1, 2, 4)):
                    with self.subTest(single=single_segment, size=size_flag, dictionary=dictionary_flag):
                        size = 256 if size_flag == 1 else 6
                        descriptor = (size_flag << 6) | (int(single_segment) << 5) | dictionary_flag
                        content_bytes = (int(single_segment), 2, 4, 8)[size_flag]
                        encoded_size = size - 256 if size_flag == 1 else size
                        header = b"\x28\xb5\x2f\xfd" + bytes([descriptor])
                        header += b"" if single_segment else b"\x00"
                        header += bytes(dictionary_bytes)
                        if content_bytes:
                            header += encoded_size.to_bytes(content_bytes, "little")
                        for block_type in (0, 1):
                            logical = b"A" * size
                            block = ((size << 3) | (block_type << 1) | 1).to_bytes(3, "little")
                            block += b"A" if block_type == 1 else logical
                            frame = header + block
                            data = b"prefix" + frame + b"cleartext tail"
                            self.assertEqual(_zstd_frame_size(data, 6), len(frame))
                            self.assertEqual(_zstd_cli_frame(data, 6), (logical, len(frame)))

    def test_zstd_cli_preserves_concatenated_frames_metadata_and_plaintext(self) -> None:
        blob, logical, _ = compressed_byte_coincidence()
        first = _zstd_content_frame(b"first")
        second = _zstd_content_frame(b"second" * 100000)
        data = b"prefix" + first + _zstd_skippable_frame(b"metadata") + second + blob + b"tail"
        with mock.patch("access_lifecycle_contract._zstd_py314", return_value=None), mock.patch(
            "access_lifecycle_contract._load_libzstd", return_value=None
        ):
            self.assertEqual(_zstd_cli_frame(data, 6), (b"first", len(first)))
            self.assertEqual(logical_content_bytes(data), b"prefixfirstmetadata" + b"second" * 100000 + logical + b"tail")

    def test_zstd_truncation_and_missing_decoder_preserve_raw_bytes(self) -> None:
        frame = _zstd_content_frame(b"safe")
        for truncated_size in range(1, len(frame)):
            with self.subTest(truncated_size=truncated_size):
                truncated = frame[:truncated_size]
                self.assertIsNone(_zstd_frame_size(truncated, 0))
                self.assertEqual(logical_content_bytes(truncated), truncated)
        data = frame + DEVICE_SYNTHETIC_PINS[0].encode()
        with mock.patch("access_lifecycle_contract._zstd_py314", return_value=None), mock.patch(
            "access_lifecycle_contract._load_libzstd", return_value=None
        ), mock.patch("shutil.which", return_value=None):
            self.assertEqual(logical_content_bytes(data), data)

    def test_all_skippable_magic_variants_preserve_payload_and_truncated_frames(self) -> None:
        payload = DEVICE_SYNTHETIC_PINS[0].encode()
        for magic in range(0x184D2A50, 0x184D2A60):
            with self.subTest(magic=magic):
                frame = magic.to_bytes(4, "little") + len(payload).to_bytes(4, "little") + payload
                self.assertEqual(logical_content_bytes(frame + b"tail"), payload + b"tail")
                truncated = magic.to_bytes(4, "little") + (len(payload) + 1).to_bytes(4, "little") + payload
                self.assertEqual(logical_content_bytes(truncated), truncated)

    def test_zstd_reserved_headers_and_failed_checksum_are_scanned_raw(self) -> None:
        frame = _zstd_content_frame(b"safe")
        malformed = [
            frame[:4] + bytes([frame[4] | 8]) + frame[5:],
            frame[:-1] + bytes([frame[-1] ^ 1]),
            b"\x28\xb5\x2f\xfd\x20\x00\x07\x00\x00",
        ]
        with mock.patch("access_lifecycle_contract._zstd_py314", return_value=None), mock.patch(
            "access_lifecycle_contract._load_libzstd", return_value=None
        ):
            for blob in malformed:
                with self.subTest(blob=blob):
                    data = blob + DEVICE_SYNTHETIC_PINS[0].encode()
                    self.assertEqual(logical_content_bytes(data), data)

    def test_decompressed_logical_content_with_pin_fails_without_echoing_pin(self) -> None:
        pin = DEVICE_SYNTHETIC_PINS[0]
        logical = f"entered pin {pin}\n".encode("utf-8")
        blob = _zstd_content_frame(logical)
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "xcresult-data.bin").write_bytes(blob)
            with self.assertRaises(AccessLifecycleContractError) as raised:
                scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)
            self.assertIn("PIN", str(raised.exception))
            for value in DEVICE_SYNTHETIC_PINS:
                self.assertNotIn(value, str(raised.exception))

    def test_large_xcresult_like_blob_scan_is_bounded(self) -> None:
        # A failed device assertion still triggered a sensitive scan that repeatedly searched a large xcresult.
        pin = DEVICE_SYNTHETIC_PINS[0]
        pin_bytes = pin.encode("utf-8")
        noise = _large_xcresult_noise()
        self.assertGreaterEqual(len(noise), LARGE_XCRESULT_NOISE_SIZE)
        self.assertNotIn(pin_bytes, noise)
        compressed_ok, logical_ok, coincidence = compressed_byte_coincidence()
        pass_blob = noise + _zstd_skippable_frame(b"safe metadata") + compressed_ok
        self.assertIn(coincidence.encode(), pass_blob)
        self.assertNotIn(coincidence.encode(), logical_ok)
        self.assertNotIn(pin_bytes, logical_ok)
        logical_bad = f"entered pin {pin}\n".encode("utf-8")
        fail_blob = noise + _gzip_content_frame(logical_bad)

        def scan_blob(blob: bytes, values: list[str] = DEVICE_SYNTHETIC_PINS) -> tuple[float, object]:
            with tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                payload = root / "Test.xcresult" / "Data" / "payload.bin"
                payload.parent.mkdir(parents=True)
                payload.write_bytes(blob)
                started = time.perf_counter()
                try:
                    result = scan_sensitive_evidence(root, values)
                except AccessLifecycleContractError as error:
                    elapsed = time.perf_counter() - started
                    return elapsed, error
                elapsed = time.perf_counter() - started
                return elapsed, result

        elapsed, result = scan_blob(pass_blob, [*DEVICE_SYNTHETIC_PINS, coincidence])
        self.assertLess(elapsed, LARGE_XCRESULT_SCAN_DEADLINE_SECONDS)
        self.assertEqual(result["result"], "PASS")
        self.assertEqual(result["matched_files"], [])

        elapsed, error = scan_blob(fail_blob)
        self.assertLess(elapsed, LARGE_XCRESULT_SCAN_DEADLINE_SECONDS)
        self.assertIsInstance(error, AccessLifecycleContractError)
        self.assertIn("PIN", str(error))
        for value in DEVICE_SYNTHETIC_PINS:
            self.assertNotIn(value, str(error))


class SlideshowReturnTests(unittest.TestCase):
    def test_hidden_control_bar_is_still_slideshow_layer(self) -> None:
        # After Menu, the app is already on the playback layer even when the control bar is hidden.
        self.assertTrue(
            is_slideshow_layer(
                [
                    "slideshow.hiddenWakeReceiver",
                    "slideshow.exifForegroundTone.flag",
                ]
            )
        )

    def test_settings_button_is_not_required_to_return(self) -> None:
        assert_returned_to_slideshow(
            {
                "identifiers": ["slideshow.hiddenWakeReceiver"],
                "control_bar_visible": False,
                "settings_button_visible": False,
            }
        )

    def test_requiring_settings_button_cannot_pass_as_return(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_returned_to_slideshow(
                {
                    "identifiers": ["slideshow.hiddenWakeReceiver"],
                    "control_bar_visible": False,
                    "settings_button_visible": False,
                    "require_settings_button": True,
                }
            )
        self.assertIn("control bar", str(raised.exception))
        self.assertIn("playback", str(raised.exception))

    def test_system_pause_analog_return_requiring_settings_button_cannot_pass(self) -> None:
        # After Home and activation, the control bar is already hidden, but the old check still required settings and
        # play buttons before counting the return.
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_returned_to_slideshow(
                {
                    "identifiers": ["slideshow.hiddenWakeReceiver"],
                    "control_bar_visible": False,
                    "settings_button_visible": False,
                    "play_button_visible": False,
                    "require_settings_button": True,
                    "system_pause_analog": True,
                }
            )
        self.assertIn("control bar", str(raised.exception))
        self.assertIn("playback", str(raised.exception))

    def test_settings_or_pin_layer_is_not_slideshow(self) -> None:
        for identifiers in (
            ["settings.item.playback"],
            ["settings.playback.autoPlay.link"],
            ["pinEntry.close.button"],
            ["firstboot.serverURL.field"],
            ["mode.random.button"],
            ["slideshow.hiddenWakeReceiver", "settings.item.playback"],
        ):
            with self.subTest(identifiers=identifiers):
                self.assertFalse(is_slideshow_layer(identifiers))
                with self.assertRaises(AccessLifecycleContractError) as raised:
                    assert_returned_to_slideshow({"identifiers": identifiers})
                self.assertIn("playback layer", str(raised.exception))

    def test_visible_control_bar_still_counts_as_slideshow(self) -> None:
        assert_returned_to_slideshow(
            {
                "identifiers": ["slideshow.control.settings.button"],
                "control_bar_visible": True,
                "settings_button_visible": True,
            }
        )

    def test_hidden_bar_return_does_not_waive_wake_scene_check(self) -> None:
        assert_returned_to_slideshow(
            {
                "identifiers": ["slideshow.hiddenWakeReceiver"],
                "control_bar_visible": False,
                "settings_button_visible": False,
            }
        )
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_wake"] = "A3"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("waking the controls", str(raised.exception))

    def test_layer_prefixes_stay_locked(self) -> None:
        self.assertEqual(PLAYBACK_LAYER_PREFIX, "slideshow.")
        self.assertEqual(
            NON_PLAYBACK_LAYER_PREFIXES,
            ("settings.", "pinEntry.", "firstboot.", "mode."),
        )


def _valid_settings_return_wake(**overrides: object) -> dict[str, object]:
    event: dict[str, object] = {
        "identifiers": [HIDDEN_CONTROL_BAR_PLAYBACK_IDENTIFIER],
        "transition_complete": True,
        "hidden_wake_receiver_focused": True,
        "hidden_wake_receiver_focus_stable": True,
        "consecutive_focused_observations": MIN_STABLE_HIDDEN_WAKE_FOCUS_OBSERVATIONS,
        "directional_press_count": 1,
        "screenshots": {
            "before": "settings-return-wake-before.png",
            "after": "settings-return-wake-after.png",
        },
    }
    event.update(overrides)
    return event


class SettingsReturnWakeTests(unittest.TestCase):
    def test_immediate_up_during_menu_transition_cannot_pass(self) -> None:
        # Up was pressed about 0.56s after Menu, before the playback transition finished or the receiver gained stable focus.
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(
                    transition_complete=False,
                    hidden_wake_receiver_focused=False,
                    hidden_wake_receiver_focus_stable=False,
                    consecutive_focused_observations=0,
                    screenshots={"before": "", "after": ""},
                )
            )
        self.assertIn("transition", str(raised.exception))

    def test_settings_layer_during_return_cannot_be_woken(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(identifiers=["settings.item.playback"])
            )
        self.assertIn("playback layer", str(raised.exception))

    def test_mixed_settings_and_slideshow_identifiers_cannot_be_woken(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(
                    identifiers=[
                        HIDDEN_CONTROL_BAR_PLAYBACK_IDENTIFIER,
                        "settings.item.playback",
                    ]
                )
            )
        self.assertIn("playback layer", str(raised.exception))

    def test_unfocused_hidden_receiver_cannot_be_woken(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(
                    hidden_wake_receiver_focused=False,
                    hidden_wake_receiver_focus_stable=False,
                )
            )
        self.assertIn("stably focused", str(raised.exception))

    def test_one_shot_focus_is_not_stable(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(
                    hidden_wake_receiver_focus_stable=False,
                    consecutive_focused_observations=1,
                )
            )
        self.assertIn("stably focused", str(raised.exception))

    def test_double_press_cannot_mask_first_wake(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(_valid_settings_return_wake(directional_press_count=2))
        self.assertIn("press twice", str(raised.exception))
        self.assertIn("first wake", str(raised.exception))

    def test_missing_before_after_screenshots_cannot_pass(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(screenshots={"before": "", "after": "after.png"})
            )
        self.assertIn("screenshots", str(raised.exception))

    def test_ready_hidden_receiver_allows_single_press_with_screenshots(self) -> None:
        assert_settings_return_wake(_valid_settings_return_wake())

    def test_stable_observation_floor_stays_locked(self) -> None:
        self.assertGreaterEqual(MIN_STABLE_HIDDEN_WAKE_FOCUS_OBSERVATIONS, 5)
        self.assertEqual(
            HIDDEN_CONTROL_BAR_PLAYBACK_IDENTIFIER,
            "slideshow.hiddenWakeReceiver",
        )


class SystemPauseAnalogTimingTests(unittest.TestCase):
    def test_wake_before_background_identity_cannot_pass(self) -> None:
        # After activation, Up woke the hidden control before after-background was captured.
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_system_pause_identity_timing(
                [
                    "before-background",
                    "hidden-control-wake-2-before",
                    "hidden-control-wake-2-after",
                    "after-background",
                ]
            )
        self.assertIn("waking the control bar", str(raised.exception))
        self.assertIn("identity", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(
                _system_pause_payload(
                    screenshot_order=[
                        "pause",
                        "after-next",
                        "after-play",
                        "before-background",
                        "hidden-control-wake-2-before",
                        "hidden-control-wake-2-after",
                        "after-background",
                        "before-wake",
                        "after-wake",
                    ]
                )
            )
        self.assertIn("waking the control bar", str(raised.exception))
        self.assertIn("identity", str(raised.exception))

    def test_identity_before_independent_wake_can_pass_timing(self) -> None:
        assert_system_pause_identity_timing(
            [
                "before-background",
                "after-background",
                "hidden-control-wake-2-before",
                "hidden-control-wake-2-after",
                "before-wake",
                "after-wake",
            ]
        )
        result = evaluate_access_lifecycle_evidence(_system_pause_payload())
        self.assertEqual(result["verdict"], "PASS")

    def test_missing_identity_timing_cannot_pass_system_pause(self) -> None:
        payload = _system_pause_payload()
        del payload["screenshot_order"]
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("timing", str(raised.exception))

    def test_background_jump_still_fails_with_correct_identity_timing(self) -> None:
        payload = _system_pause_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_background"] = "A3"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("background return", str(raised.exception))
        self.assertIn("Changing photos", str(raised.exception))

    def test_launch_or_rebuilt_process_is_not_desktop_pid_analog(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_system_pause_activation(
                {
                    "system_pause_activation": "launch",
                    "process_rebuilt": False,
                    "home_left_app_running": True,
                }
            )
        self.assertIn("rebuild", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(
                _system_pause_payload(system_pause_activation="launch")
            )
        self.assertIn("rebuild", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(_system_pause_payload(process_rebuilt=True))
        self.assertIn("rebuild", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(
                _system_pause_payload(home_left_app_running=False)
            )
        self.assertIn("Open", str(raised.exception))

    def test_activate_existing_process_is_allowed(self) -> None:
        assert_system_pause_activation(
            {
                "system_pause_activation": ALLOWED_SYSTEM_PAUSE_ACTIVATION,
                "process_rebuilt": False,
                "home_left_app_running": True,
            }
        )


def _fixture_png(label: str, fixture_set: str = "a") -> bytes:
    return _fixture_data(fixture_set)["images"][f"asset-{fixture_set}-{label[-1]}"]


def _png_bytes(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


# Stand-ins for screenshots once recorded on simulators, keyed by the recorded run and file
# name. Each is composed from the public fixture photos and reproduces the classification of
# the recorded frame that the test guards.
TV_SCREEN = (1920, 1080)
IPHONE_SCREEN = (1170, 2532)
IPAD_SCREEN = (1640, 2360)


def _fixture_image(label: str) -> Image.Image:
    return Image.open(io.BytesIO(_fixture_png(label))).convert("RGB")


def _cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    width, height = size
    scale = max(width / image.width, height / image.height)
    resized = image.resize(
        (max(width, round(image.width * scale)), max(height, round(image.height * scale))),
        Image.Resampling.BILINEAR,
    )
    left = (resized.width - width) // 2
    top = (resized.height - height) // 2
    return resized.crop((left, top, left + width, top + height))


def _single_on_own_blur(label: str, screen: tuple[int, int]) -> Image.Image:
    """One photo fitted to the screen over a blurred copy of itself."""
    image = _fixture_image(label)
    canvas = _cover(image, screen).filter(ImageFilter.GaussianBlur(48))
    scale = min(screen[0] / image.width, screen[1] / image.height)
    fitted = image.resize(
        (max(1, round(image.width * scale)), max(1, round(image.height * scale))),
        Image.Resampling.BILINEAR,
    )
    canvas.paste(fitted, ((screen[0] - fitted.width) // 2, (screen[1] - fitted.height) // 2))
    return canvas


def _with_bottom_controls(image: Image.Image) -> Image.Image:
    framed = image.copy()
    width, height = framed.size
    ImageDraw.Draw(framed, "RGBA").rectangle((0, round(height * 0.9), width, height), fill=(0, 0, 0, 160))
    return framed


def _stacked_screen(
    top: str,
    bottom: str,
    screen: tuple[int, int],
    top_share: float,
    dark_top_band: float = 0.0,
) -> Image.Image:
    width, height = screen
    top_height = round(height * top_share)
    canvas = Image.new("RGB", screen, (0, 0, 0))
    canvas.paste(_cover(_fixture_image(top), (width, top_height)), (0, 0))
    canvas.paste(_cover(_fixture_image(bottom), (width, height - top_height)), (0, top_height))
    if dark_top_band:
        ImageDraw.Draw(canvas).rectangle((0, 0, width, round(height * dark_top_band)), fill=(0, 0, 0))
    return canvas


def _side_by_side_screen(left: str, right: str, screen: tuple[int, int], left_share: float) -> Image.Image:
    width, height = screen
    left_width = round(width * left_share)
    canvas = Image.new("RGB", screen, (0, 0, 0))
    canvas.paste(_cover(_fixture_image(left), (left_width, height)), (0, 0))
    canvas.paste(_cover(_fixture_image(right), (width - left_width, height)), (left_width, 0))
    return canvas


def _dissolve_screen() -> Image.Image:
    """A1 strip on top while the rest dissolves between A2 and A3: only the top strip matches."""
    width, height = IPHONE_SCREEN
    tile = 24
    canvas = Image.new("RGB", IPHONE_SCREEN, (0, 0, 0))
    outgoing = _cover(_fixture_image("A2"), IPHONE_SCREEN)
    incoming = _cover(_fixture_image("A3"), IPHONE_SCREEN)
    for top in range(0, height, tile):
        for left in range(0, width, tile):
            source = outgoing if ((left // tile) + (top // tile)) % 2 == 0 else incoming
            box = (left, top, min(left + tile, width), min(top + tile, height))
            canvas.paste(source.crop(box), box[:2])
    canvas.paste(_cover(_fixture_image("A1"), (width, round(height * 0.17))), (0, 0))
    return canvas


_STAND_IN_FRAMES: dict[tuple[str, ...], Callable[[], Image.Image]] = {
    # tvOS display-strategy cases.
    ("single-photo-swap", "display-before.png"): lambda: _single_on_own_blur("A4", TV_SCREEN),
    ("single-photo-swap", "display-after.png"): lambda: _single_on_own_blur("A5", TV_SCREEN),
    ("pool-end-single-photo", "display-before.png"): lambda: _single_on_own_blur("A5", TV_SCREEN),
    ("pool-end-single-photo", "display-after.png"): lambda: _with_bottom_controls(
        _single_on_own_blur("A5", TV_SCREEN)
    ),
    ("unchanged-fullbleed", "display-before.png"): lambda: _with_bottom_controls(
        _cover(_fixture_image("A1"), TV_SCREEN)
    ),
    ("unchanged-fullbleed", "display-after.png"): lambda: _with_bottom_controls(
        _cover(_fixture_image("A1"), TV_SCREEN)
    ),
    ("side-by-side-transition", "display-before.png"): lambda: _single_on_own_blur("A2", TV_SCREEN),
    ("side-by-side-transition", "display-after.png"): lambda: _side_by_side_screen("A2", "A3", TV_SCREEN, 0.4),
    # iPhone and iPad stacked smart fill.
    ("ipad-stacked-smart-fill", "after-next.png"): lambda: _stacked_screen("A4", "A1", IPAD_SCREEN, 0.5),
    ("iphone", "failure-late-frames", "late-160.png"): _dissolve_screen,
    ("iphone", "failure-late-frames", "late-178.png"): lambda: _stacked_screen("A3", "A5", IPHONE_SCREEN, 0.5),
    ("iphone", "failure-late-frames", "late-184.png"): lambda: _stacked_screen("A4", "A5", IPHONE_SCREEN, 0.4),
    # Before wake A1 sits at its fitted height, so the 0-50% half also sees A5 and only the top
    # strip sees A1 alone. After wake the same pair is laid out 40/60.
    ("iphone-5e012fe5", "before-wake.png"): lambda: _stacked_screen("A1", "A5", IPHONE_SCREEN, 0.25),
    ("iphone-5e012fe5", "after-wake.png"): lambda: _stacked_screen("A1", "A5", IPHONE_SCREEN, 0.4),
    ("ipad-5e012fe5", "display-before.png"): lambda: _stacked_screen("A4", "A1", IPAD_SCREEN, 0.45),
    ("ipad-5e012fe5", "display-after.png"): lambda: _single_on_own_blur("A1", IPAD_SCREEN),
    ("iphone-9d4e01fe", "pause.png"): lambda: _stacked_screen("A4", "A5", IPHONE_SCREEN, 0.4),
    # A dark band covers the top strip, so only the 0-40% upper region still sees A1.
    ("iphone-9d4e01fe", "after-next.png"): lambda: _stacked_screen(
        "A1", "A5", IPHONE_SCREEN, 0.31, dark_top_band=0.18
    ),
    ("iphone-9d4e01fe", "after-play.png"): lambda: _stacked_screen("A1", "A5", IPHONE_SCREEN, 0.4),
    ("ipad-85c0537a", "after-next.png"): lambda: _stacked_screen("A4", "A1", IPAD_SCREEN, 0.55),
}


def _stand_in_png(*key: str) -> bytes:
    return _png_bytes(_STAND_IN_FRAMES[key]())


def _single_photo_swap_display(name: str) -> bytes:
    return _stand_in_png("single-photo-swap", name)


def _pool_end_single_photo_display(name: str) -> bytes:
    return _stand_in_png("pool-end-single-photo", name)


def _unchanged_fullbleed_display(name: str) -> bytes:
    return _stand_in_png("unchanged-fullbleed", name)


def _side_by_side_transition_display(name: str) -> bytes:
    return _stand_in_png("side-by-side-transition", name)


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


def _side_by_side(left_label: str, right_label: str) -> bytes:
    with Image.open(io.BytesIO(_fixture_png(left_label))) as left, Image.open(
        io.BytesIO(_fixture_png(right_label))
    ) as right:
        width, height = 960, 540
        canvas = Image.new("RGB", (width, height))
        canvas.paste(left.convert("RGB").resize((width // 2, height)), (0, 0))
        canvas.paste(right.convert("RGB").resize((width // 2, height)), (width // 2, 0))
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


class DisplayStrategyContractTests(unittest.TestCase):
    def test_single_photo_swap_pair_fails_closed(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _single_photo_swap_display("display-before.png"),
                _single_photo_swap_display("display-after.png"),
            )
        message = str(raised.exception)
        self.assertTrue("portrait or square photo" in message or "single public fixture photo" in message, message)

    def test_pool_end_single_photo_pair_fails_closed(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _pool_end_single_photo_display("display-before.png"),
                _pool_end_single_photo_display("display-after.png"),
            )
        message = str(raised.exception)
        self.assertTrue("last pool photo" in message or "Smart Fill" in message, message)

    def test_pool_end_single_photo_inspection_keeps_region_classification(self) -> None:
        report = inspect_display_strategy(
            _pool_end_single_photo_display("display-before.png"),
            _pool_end_single_photo_display("display-after.png"),
        )
        error = str(report.get("error") or "")
        self.assertTrue("last pool photo" in error or "Smart Fill" in error, error)
        self.assertEqual(report["before"]["mark"], "A5")
        self.assertEqual(report["after"]["regions"]["center"]["mark"], "A5")
        self.assertEqual(report["after"]["regions"]["left"]["mark"], "A5")
        self.assertEqual(report["partner_marks"], [])

    def test_unchanged_fullbleed_pair_fails_closed(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _unchanged_fullbleed_display("display-before.png"),
                _unchanged_fullbleed_display("display-after.png"),
            )
        self.assertIn("Display policy did not take effect", str(raised.exception))

    def test_a1_fullbleed_before_fails_even_with_smart_fill_after(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _fixture_png("A1"),
                _compose_smart_fill("A1", "A3"),
            )
        self.assertIn("full-bleed A1", str(raised.exception))
        self.assertIn("A1", str(raised.exception))

    def test_a5_pool_end_before_fails_even_with_smart_fill_after(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _fixture_png("A5"),
                _compose_smart_fill("A5", "A2"),
            )
        self.assertIn("last pool photo A5", str(raised.exception))

    def test_a4_landscape_before_is_not_letterbox_surface(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _fixture_png("A4"),
                _compose_smart_fill("A4", "A2"),
            )
        self.assertIn("portrait or square photo", str(raised.exception))

    def test_before_side_partner_is_not_letterbox(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _compose_side_partner("A2", "A3"),
                _compose_smart_fill("A2", "A4"),
            )
        self.assertIn("second public fixture", str(raised.exception))

    def test_assert_display_before_letterbox_rejects_fullbleed_and_pool_end(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_before_letterbox("A1", [])
        self.assertIn("full-bleed A1", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_before_letterbox("A5", [])
        self.assertIn("last pool photo A5", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_before_letterbox("A4", [])
        self.assertIn("portrait or square photo", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_before_letterbox("A2", ["A3"])
        self.assertIn("second public fixture", str(raised.exception))
        assert_display_before_letterbox("A2", [])
        assert_display_before_letterbox("A3", [])

    def test_side_by_side_regions_pass_during_full_screen_transition(self) -> None:
        # A2 on the left and A3 on the right match by region even when the full-screen color mix is TRANSITION.
        report = assert_display_strategy_visible(
            _side_by_side_transition_display("display-before.png"),
            _side_by_side_transition_display("display-after.png"),
        )
        self.assertIsNone(report.get("error"))
        self.assertEqual(report["before_mark"], "A2")
        self.assertIn("A3", report["partner_marks"])
        self.assertEqual(report["after"]["regions"]["full"]["status"], "TRANSITION")
        self.assertEqual(report["after"]["regions"]["left"]["status"], "MATCH")
        self.assertEqual(report["after"]["regions"]["left"]["mark"], "A2")
        self.assertEqual(report["after"]["regions"]["right"]["status"], "MATCH")
        self.assertEqual(report["after"]["regions"]["right"]["mark"], "A3")
        self.assertFalse(report.get("before_partner_marks"))

    def test_side_by_side_public_fixtures_pass_despite_full_transition(self) -> None:
        report = assert_display_strategy_visible(
            _fixture_png("A2"),
            _side_by_side("A2", "A3"),
        )
        self.assertIsNone(report.get("error"))
        self.assertEqual(report["before_mark"], "A2")
        self.assertIn("A3", report["partner_marks"])
        self.assertEqual(report["after"]["regions"]["full"]["status"], "TRANSITION")
        self.assertEqual(report["after"]["regions"]["left"]["mark"], "A2")
        self.assertEqual(report["after"]["regions"]["right"]["mark"], "A3")

    def test_checkerboard_transition_without_anchor_match_fails_closed(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _fixture_png("A2"),
                _checkerboard_mix("A2", "A3"),
            )
        self.assertIn("TRANSITION", str(raised.exception))

    def test_letterbox_a2_before_with_partner_after_passes(self) -> None:
        report = assert_display_strategy_visible(
            _fixture_png("A2"),
            _compose_smart_fill("A2", "A3"),
        )
        self.assertIsNone(report.get("error"))
        self.assertEqual(report["before_mark"], "A2")
        self.assertIn("A3", report["partner_marks"])
        self.assertFalse(report.get("before_partner_marks"))

    def test_display_after_pause_fails_pool_burn(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_before_pool_burn(
                [
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
            )
        self.assertIn("exhausts the playback pool", str(raised.exception))

    def test_display_before_pause_is_allowed(self) -> None:
        assert_display_before_pool_burn(
            [
                "display-before",
                "display-after",
                "pause",
                "after-next",
                "after-play",
                "before-background",
                "after-background",
                "before-wake",
                "after-wake",
            ]
        )

    def test_hidden_control_wake_before_display_is_not_pool_burn(self) -> None:
        # After a restart the control bar may already be hidden; waking does not advance the random pool, so it is not
        # pool burning.
        assert_display_before_pool_burn(
            [
                "hidden-control-wake-2-before",
                "hidden-control-wake-2-after",
                "display-before",
                "display-after",
                "pause",
            ]
        )

    def test_exhausted_pool_has_no_unshown_partner(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_unshown_display_partners(
                screenshot_order=[
                    "pause",
                    "after-next",
                    "after-play",
                    "after-background",
                    "after-wake",
                    "display-before",
                ],
                scenes={
                    "pause": "A1",
                    "after_next": "A2",
                    "after_play": "A2",
                    "after_background": "A3",
                    "after_wake": "A4",
                },
                before_mark="A5",
            )
        self.assertIn("unshown partner", str(raised.exception))

    def test_display_first_keeps_unshown_partners(self) -> None:
        assert_unshown_display_partners(
            screenshot_order=["display-before", "display-after", "pause"],
            scenes={"pause": "A1"},
            before_mark="A1",
        )


class PublicFixtureOriginalMetadataTests(unittest.TestCase):
    def test_old_low_resolution_original_metadata_is_rejected(self) -> None:
        # A2 at 180x320 and A3 at 300x300 cannot reach 0.85 effective pixels in Apple TV's two-photo slots.
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_appletv_double_layout_visible((("A2", 180, 320), ("A3", 300, 300)))
        self.assertIn("effective pixels too low", str(raised.exception))

    def test_letterbox_fixture_originals_plan_visible_double(self) -> None:
        assets = {asset["label"]: asset for asset in _fixture_data("a")["assets"]}
        assert_appletv_double_layout_visible(
            (
                ("A2", int(assets["A2"]["width"]), int(assets["A2"]["height"])),
                ("A3", int(assets["A3"]["width"]), int(assets["A3"]["height"])),
            )
        )

    def test_public_fixture_png_identity_pixels_stay_small(self) -> None:
        fixture = _fixture_data("a")
        images = fixture["images"]
        by_label = {asset["label"]: asset for asset in fixture["assets"]}
        a2 = Image.open(io.BytesIO(images[by_label["A2"]["id"]]))
        a3 = Image.open(io.BytesIO(images[by_label["A3"]["id"]]))
        self.assertEqual(a2.size, (180, 320))
        self.assertEqual(a3.size, (300, 300))
        self.assertEqual(classify_screenshot(images[by_label["A2"]["id"]]).mark, "A2")
        self.assertEqual(classify_screenshot(images[by_label["A3"]["id"]]).mark, "A3")


class SettingsOpenOrderTests(unittest.TestCase):
    def test_pin_gate_cannot_require_playback_item_first(self) -> None:
        # The PIN gate covers the settings page, but the old check waited for settings.item.playback first.
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_open(
                {
                    "identifiers": ["pinEntry.close.button"],
                    "require_playback_item": True,
                }
            )
        self.assertIn("PIN", str(raised.exception))
        self.assertIn("playback settings", str(raised.exception))

    def test_pin_gate_is_a_legal_settings_open_state(self) -> None:
        assert_settings_open(
            {
                "identifiers": ["pinEntry.close.button"],
                "require_playback_item": False,
            }
        )

    def test_settings_home_may_require_playback_item(self) -> None:
        assert_settings_open(
            {
                "identifiers": ["settings.item.playback"],
                "require_playback_item": True,
            }
        )

class _MarkSample:
    def __init__(self, status: str, mark: str | None, mean_luma: float) -> None:
        self.status = status
        self.mark = mark
        self.mean_luma = mean_luma


class NewStableMarkTimingTests(unittest.TestCase):
    def test_confirm_wait_is_reserved_inside_remaining_budget(self) -> None:
        self.assertEqual(NEW_STABLE_MARK_POLL_INTERVAL, 0.1)
        self.assertEqual(NEW_STABLE_MARK_CONFIRM_WINDOW, 0.8)
        self.assertEqual(NEW_STABLE_MARK_MIN_LUMA, 0.20)
        self.assertEqual(confirm_wait(2.0), 0.8)
        self.assertEqual(confirm_wait(0.5), 0.5)
        self.assertEqual(confirm_wait(0.0), 0.0)
        self.assertEqual(confirm_wait(-1.0), 0.0)
        self.assertEqual(poll_wait(2.0), 0.1)
        self.assertEqual(poll_wait(0.04), 0.04)
        self.assertEqual(poll_wait(0.0), 0.0)

    def test_unconditional_confirm_window_is_the_documented_miss(self) -> None:
        # The old helper always waited 0.8s: with 0.5s left, confirming overran the deadline and could no longer sample
        # the now-stable new frame.
        self.assertGreater(NEW_STABLE_MARK_CONFIRM_WINDOW, 0.5)
        self.assertLess(confirm_wait(0.5), NEW_STABLE_MARK_CONFIRM_WINDOW)

    def test_late_switch_after_failed_confirm_is_sampled_before_deadline(self) -> None:
        # The sample missed a new MATCH at 15.5s because the unconditional 0.8s confirm landed at 16.3s,
        # past the deadline.
        def observe(elapsed: float) -> _MarkSample:
            if elapsed < 15.5:
                return _MarkSample("MATCH", "A3", 0.5)
            if elapsed < 16.0:
                return _MarkSample("MATCH", "A4", 0.5)
            if elapsed < 16.2:
                return _MarkSample("MATCH", "A4", 0.5)
            return _MarkSample("TRANSITION", None, 0.12)

        mark = wait_for_new_stable_mark(
            timeout=16.0,
            initial_mark="A3",
            observe=observe,
        )
        self.assertEqual(mark, "A4")

    def test_unchanged_mark_still_fail_closed(self) -> None:
        def observe(_elapsed: float) -> _MarkSample:
            return _MarkSample("MATCH", "A3", 0.5)

        with self.assertRaises(AccessLifecycleContractError) as raised:
            wait_for_new_stable_mark(timeout=2.0, initial_mark="A3", observe=observe)
        self.assertIn("No new stable frame was observed before backgrounding", str(raised.exception))

    def test_transition_flash_without_stable_confirm_fail_closed(self) -> None:
        def observe(elapsed: float) -> _MarkSample:
            if 0.3 <= elapsed < 0.35:
                return _MarkSample("MATCH", "A4", 0.5)
            return _MarkSample("TRANSITION", None, 0.12)

        with self.assertRaises(AccessLifecycleContractError) as raised:
            wait_for_new_stable_mark(timeout=1.0, initial_mark="A3", observe=observe)
        self.assertIn("No new stable frame was observed before backgrounding", str(raised.exception))

    def test_low_luma_confirm_is_not_stable(self) -> None:
        def observe(elapsed: float) -> _MarkSample:
            if elapsed < 0.2:
                return _MarkSample("MATCH", "A3", 0.5)
            if elapsed < 0.3:
                return _MarkSample("MATCH", "A4", 0.5)
            return _MarkSample("MATCH", "A4", 0.10)

        with self.assertRaises(AccessLifecycleContractError):
            wait_for_new_stable_mark(timeout=2.0, initial_mark="A3", observe=observe)
        self.assertFalse(
            is_confirmed_new_stable_mark(
                status="MATCH",
                mark="A4",
                candidate_mark="A4",
                initial_mark="A3",
                mean_luma=0.10,
            )
        )

    def test_timeout_budget_is_not_lengthened(self) -> None:
        observed_at: list[float] = []

        def observe(elapsed: float) -> _MarkSample:
            observed_at.append(elapsed)
            return _MarkSample("MATCH", "A3", 0.5)

        with self.assertRaises(AccessLifecycleContractError):
            wait_for_new_stable_mark(timeout=1.0, initial_mark="A3", observe=observe)
        self.assertLessEqual(max(observed_at), 1.0)

class ModeContinueAndWakeHelperTests(unittest.TestCase):
    def test_wake_helper_isolates_evidence_from_autoplay_boundary(self) -> None:
        from access_lifecycle_contract import (
            WAKE_EVIDENCE_BUDGET_SECONDS,
            hide_wait_for_wake,
            should_wait_for_autoplay_before_wake,
            wake_window_crosses_autoplay,
        )

        self.assertEqual(WAKE_EVIDENCE_BUDGET_SECONDS, 2.5)
        self.assertTrue(
            wake_window_crosses_autoplay(
                elapsed_before=11.48,
                elapsed_after=13.66,
                interval_seconds=12,
            )
        )
        self.assertFalse(
            wake_window_crosses_autoplay(
                elapsed_before=9.0,
                elapsed_after=10.5,
                interval_seconds=12,
            )
        )
        self.assertEqual(
            hide_wait_for_wake(
                hide_seconds=9,
                remaining_to_autoplay=9.5,
                evidence_budget=2.5,
            ),
            7.0,
        )
        self.assertEqual(
            hide_wait_for_wake(
                hide_seconds=9,
                remaining_to_autoplay=12,
                evidence_budget=2.5,
            ),
            9.0,
        )
        self.assertEqual(
            hide_wait_for_wake(
                hide_seconds=9,
                remaining_to_autoplay=2.0,
                evidence_budget=2.5,
            ),
            0.0,
        )
        self.assertTrue(
            should_wait_for_autoplay_before_wake(
                remaining_to_autoplay=2.0,
                evidence_budget=2.5,
            )
        )
        self.assertFalse(
            should_wait_for_autoplay_before_wake(
                remaining_to_autoplay=9.5,
                evidence_budget=2.5,
            )
        )


class CaptureRegionIdentityTests(unittest.TestCase):
    def test_ipad_after_next_full_screen_is_transition(self) -> None:
        png = _stand_in_png("ipad-stacked-smart-fill", "after-next.png")
        full = classify_screenshot(png)
        self.assertEqual(full.status, "TRANSITION")
        self.assertIsNone(full.mark)

    def test_ipad_after_next_left_right_boxes_miss_stacked_pair(self) -> None:
        png = _stand_in_png("ipad-stacked-smart-fill", "after-next.png")
        regions = classify_display_regions(png)
        self.assertEqual(regions["left"].status, "TRANSITION")
        self.assertEqual(regions["right"].status, "TRANSITION")
        self.assertNotEqual({regions["left"].mark, regions["right"].mark}, {"A4", "A1"})

    def test_ipad_after_next_capture_identity_is_stacked_a4_a1(self) -> None:
        identity = capture_identity(_stand_in_png("ipad-stacked-smart-fill", "after-next.png"))
        self.assertEqual(identity.status, "MATCH")
        self.assertEqual(identity.mark, "A4+A1")

    def test_iphone_late_frames_composite_identity_changes(self) -> None:
        before = capture_identity(_stand_in_png("iphone", "failure-late-frames", "late-178.png"))
        after = capture_identity(_stand_in_png("iphone", "failure-late-frames", "late-184.png"))
        self.assertEqual(before.status, "MATCH")
        self.assertEqual(after.status, "MATCH")
        self.assertEqual(before.mark, "A3+A5")
        self.assertEqual(after.mark, "A4+A5")
        self.assertNotEqual(before.mark, after.mark)
        full_after = classify_screenshot(
            _stand_in_png("iphone", "failure-late-frames", "late-184.png")
        )
        self.assertEqual(full_after.status, "MATCH")
        self.assertEqual(full_after.mark, "A5")
        self.assertNotEqual(after.mark, full_after.mark)

    def test_capture_new_stable_mark_does_not_miss_composite_change(self) -> None:
        before_png = _stand_in_png("iphone", "failure-late-frames", "late-178.png")
        after_png = _stand_in_png("iphone", "failure-late-frames", "late-184.png")
        initial = capture_identity(before_png)

        def observe(elapsed: float) -> object:
            png = before_png if elapsed < 0.5 else after_png
            return capture_identity(png)

        mark = wait_for_new_stable_mark(
            timeout=2.0,
            initial_mark=str(initial.mark),
            observe=observe,
        )
        self.assertEqual(mark, "A4+A5")

    def test_full_screen_classify_misses_iphone_composite_change(self) -> None:
        before_png = _stand_in_png("iphone", "failure-late-frames", "late-178.png")
        after_png = _stand_in_png("iphone", "failure-late-frames", "late-184.png")
        initial = classify_screenshot(before_png)
        self.assertEqual(initial.status, "TRANSITION")

        def observe(elapsed: float) -> _MarkSample:
            identity = classify_screenshot(before_png if elapsed < 0.5 else after_png)
            return _MarkSample(identity.status, identity.mark, identity.mean_luma)

        mark = wait_for_new_stable_mark(
            timeout=2.0,
            initial_mark="UNRECOGNIZABLE",
            observe=observe,
        )
        self.assertEqual(mark, "A5")

    def test_transition_without_region_match_is_not_capture_pass(self) -> None:
        identity = capture_identity(_checkerboard_mix("A2", "A3"))
        self.assertEqual(identity.status, "TRANSITION")
        self.assertIsNone(identity.mark)

    def test_unrecognizable_late_frame_is_not_promoted(self) -> None:
        identity = capture_identity(_stand_in_png("iphone", "failure-late-frames", "late-160.png"))
        self.assertIn(identity.status, {"UNRECOGNIZABLE", "BLANK", "BLACK", "TRANSITION"})
        self.assertIsNone(identity.mark)
        self.assertNotEqual(identity.status, "MATCH")

    def test_black_bytes_stay_fail_closed(self) -> None:
        canvas = Image.new("RGB", (64, 64), (0, 0, 0))
        identity = capture_identity(_png_bytes(canvas))
        self.assertEqual(identity.status, "BLACK")
        self.assertIsNone(identity.mark)

    def test_single_fixture_still_uses_full_match(self) -> None:
        identity = capture_identity(_fixture_png("A2"))
        self.assertEqual(identity.status, "MATCH")
        self.assertEqual(identity.mark, "A2")

    def test_iphone_5e012fe5_wake_pair_keeps_stacked_identity(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        before_png = _stand_in_png("iphone-5e012fe5", "before-wake.png")
        after_png = _stand_in_png("iphone-5e012fe5", "after-wake.png")
        before_full = classify_screenshot(before_png)
        before_regions = classify_display_regions(before_png)
        self.assertEqual(before_full.status, "MATCH")
        self.assertEqual(before_full.mark, "A5")
        self.assertEqual(before_regions["top_half"].status, "TRANSITION")
        self.assertEqual(before_regions["top"].status, "MATCH")
        self.assertEqual(before_regions["top"].mark, "A1")
        self.assertEqual(before_regions["bottom_half"].status, "MATCH")
        self.assertEqual(before_regions["bottom_half"].mark, "A5")
        before = capture_identity(before_png)
        after = capture_identity(after_png)
        self.assertEqual(before.status, "MATCH")
        self.assertEqual(after.status, "MATCH")
        self.assertEqual(before.mark, "A1+A5")
        self.assertEqual(after.mark, "A1+A5")
        self.assertEqual(scene_mark_from_bytes(before_png), "A1+A5")
        self.assertEqual(scene_mark_from_bytes(after_png), "A1+A5")

    def test_iphone_5e012fe5_wake_pair_does_not_report_switch(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["before_wake"] = scene_mark_from_bytes(
            _stand_in_png("iphone-5e012fe5", "before-wake.png")
        )
        scenes["after_wake"] = scene_mark_from_bytes(
            _stand_in_png("iphone-5e012fe5", "after-wake.png")
        )
        payload["scenes"] = scenes
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")

    def test_ipad_5e012fe5_display_before_is_stacked_not_unrecognizable(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        before_png = _stand_in_png("ipad-5e012fe5", "display-before.png")
        after_png = _stand_in_png("ipad-5e012fe5", "display-after.png")
        full = classify_screenshot(before_png)
        self.assertEqual(full.status, "TRANSITION")
        self.assertIsNone(full.mark)
        before = capture_identity(before_png)
        after = capture_identity(after_png)
        self.assertEqual(before.status, "MATCH")
        self.assertEqual(before.mark, "A4+A1")
        self.assertEqual(after.status, "MATCH")
        self.assertEqual(after.mark, "A1")
        self.assertEqual(scene_mark_from_bytes(before_png), "A4+A1")
        self.assertEqual(scene_mark_from_bytes(after_png), "A1")
        payload = _device_payload_ready_for_background()
        display = dict(payload["display_policy"])  # type: ignore[arg-type]
        display["mark_before"] = "A4+A1"
        display["mark_after"] = "A1"
        payload["display_policy"] = display
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")

    def test_iphone_9d4e01fe_pause_next_play_is_stacked_new_scene(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        pause_png = _stand_in_png("iphone-9d4e01fe", "pause.png")
        after_next_png = _stand_in_png("iphone-9d4e01fe", "after-next.png")
        after_play_png = _stand_in_png("iphone-9d4e01fe", "after-play.png")
        full_next = classify_screenshot(after_next_png)
        self.assertEqual(full_next.status, "MATCH")
        self.assertEqual(full_next.mark, "A5")
        pause = scene_mark_from_bytes(pause_png)
        after_next = scene_mark_from_bytes(after_next_png)
        after_play = scene_mark_from_bytes(after_play_png)
        self.assertEqual(pause, "A4+A5")
        self.assertEqual(after_next, "A1+A5")
        self.assertEqual(after_play, "A1+A5")
        regions = classify_display_regions(after_next_png)
        self.assertEqual(regions["upper"].status, "MATCH")
        self.assertEqual(regions["upper"].mark, "A1")
        self.assertEqual(regions["bottom_half"].status, "MATCH")
        self.assertEqual(regions["bottom_half"].mark, "A5")
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["pause"] = pause
        scenes["after_next"] = after_next
        scenes["after_play"] = after_play
        payload["scenes"] = scenes
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")

    def test_stacked_after_play_returning_to_pause_still_fail_closed(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes.update(
            {
                "pause": "A4+A5",
                "after_next": "A1+A5",
                "after_play": "A4+A5",
                "before_background": "A1+A5",
                "after_background": "A1+A5",
                "before_wake": "A1+A5",
                "after_wake": "A1+A5",
            }
        )
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("previous scene", str(raised.exception))

    def test_ipad_85c0537a_after_next_scene_mark_is_stacked_match(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        png = _stand_in_png("ipad-85c0537a", "after-next.png")
        full = classify_screenshot(png)
        self.assertEqual(full.status, "TRANSITION")
        self.assertIsNone(full.mark)
        self.assertEqual(scene_mark_from_bytes(png), "A4+A1")

    def test_scene_mark_does_not_promote_transition_or_black(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        mixed = scene_mark_from_bytes(_checkerboard_mix("A2", "A3"))
        self.assertIn(mixed, {"TRANSITION", "UNRECOGNIZABLE", "BLACK", "BLANK"})
        self.assertNotEqual(mixed, "A2")
        self.assertNotEqual(mixed, "A3")
        self.assertNotIn("+", mixed)
        black = scene_mark_from_bytes(_png_bytes(Image.new("RGB", (64, 64), (0, 0, 0))))
        self.assertEqual(black, "BLACK")
        single = scene_mark_from_bytes(_fixture_png("A2"))
        self.assertEqual(single, "A2")


if __name__ == "__main__":
    unittest.main()
