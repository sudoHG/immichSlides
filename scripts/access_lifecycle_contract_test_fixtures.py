"""Moved fixtures and imports shared by the existing test classes."""

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


from sensitive_scan_test_support import compressed_byte_coincidence  # noqa: E402


from access_lifecycle_contract import (  # noqa: E402
    AccessLifecycleContractError,
    ALLOWED_SYSTEM_PAUSE_ACTIVATION,
    FROZEN_FIXTURE_SHA256,
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


SYNTHETIC_PIN = "".join(chr(ord("0") + digit) for digit in (2, 4, 6, 8, 0, 1))


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


def _fixture_png(label: str, fixture_set: str = "a") -> bytes:
    return _fixture_data(fixture_set)["images"][f"asset-{fixture_set}-{label[-1]}"]


def _png_bytes(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


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
    """A single photo whose blurred copy must not count as a second photo."""
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
    ("iphone-wake-pair", "before-wake.png"): lambda: _stacked_screen("A1", "A5", IPHONE_SCREEN, 0.25),
    ("iphone-wake-pair", "after-wake.png"): lambda: _stacked_screen("A1", "A5", IPHONE_SCREEN, 0.4),
    ("ipad-display-switch", "display-before.png"): lambda: _stacked_screen("A4", "A1", IPAD_SCREEN, 0.45),
    ("ipad-display-switch", "display-after.png"): lambda: _single_on_own_blur("A1", IPAD_SCREEN),
    ("iphone-pause-next-play", "pause.png"): lambda: _stacked_screen("A4", "A5", IPHONE_SCREEN, 0.4),
    # A dark band covers the top strip, so only the 0-40% upper region still sees A1.
    ("iphone-pause-next-play", "after-next.png"): lambda: _stacked_screen(
        "A1", "A5", IPHONE_SCREEN, 0.31, dark_top_band=0.18
    ),
    ("iphone-pause-next-play", "after-play.png"): lambda: _stacked_screen("A1", "A5", IPHONE_SCREEN, 0.4),
    ("ipad-stacked-after-next", "after-next.png"): lambda: _stacked_screen("A4", "A1", IPAD_SCREEN, 0.55),
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


class _MarkSample:
    def __init__(self, status: str, mark: str | None, mean_luma: float) -> None:
        self.status = status
        self.mark = mark
        self.mean_luma = mean_luma
