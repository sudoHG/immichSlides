#!/usr/bin/env python3
"""Shared offline access-lifecycle contract. Formal settings/lifecycle accept only real entry points; PINs never enter evidence."""

from __future__ import annotations

import lzma
import os
import zlib
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Sequence, Optional, Tuple


from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256
from strict_e2e_photo_identity import MARKS, PhotoIdentity, classify_screenshot


class AccessLifecycleContractError(Exception):
    pass


ALLOWED_IDENTITY_SOURCE = "public_fixture_photo_mark"
ALLOWED_SETTINGS_SOURCE = "real_settings_ui"
FORBIDDEN_SETTINGS_SOURCES = frozenset({"launch_argument", "userdefaults_injection"})
FORBIDDEN_DISPLAY_MODE_KEY = "UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE"
SETTINGS_FIELDS = ("autoPlayEnabled", "intervalSeconds", "showExif", "displayMode")
DEFAULT_PLAYBACK_SETTINGS = {
    "autoPlayEnabled": True,
    "intervalSeconds": 5,
    "showExif": True,
    "displayMode": "smartFill",
}
INVALID_SCENE_MARKS = {
    "BLACK": "All-black output must not count as a pass",
    "BLANK": "Blank output must not count as a pass",
    "UNRECOGNIZABLE": "Unrecognizable input must not count as a pass",
    "TRANSITION": "An unstable transition frame must not count as a pass",
}
MEASURED_PROGRESS_ZERO_EPSILON = 0.001
DEVICE_REQUIRED_SCREENSHOTS = (
    "display_before",
    "display_after",
    "pin_restart_gate",
    "settings_after_restart",
    "settings_at_background",
)
INVALID_DISPLAY_STATUSES = {
    "BLACK": "All-black output must not count as a pass",
    "BLANK": "Blank output must not count as a pass",
    "UNRECOGNIZABLE": "Unrecognizable input must not count as a pass",
}
# Crop boxes are width/height fractions (0-1). Multi-photo is judged by region MATCHes with distinct partner_marks;
# a blended full screen may be TRANSITION. top_half/bottom_half are the whole upper/lower halves. Motion cropping can
# sweep the seam into the upper half and make it TRANSITION; the top strip may still MATCH the upper photo. Swift's 50%
# upper half classifies A1/A5 as TRANSITION, while the 0-40% upper region still MATCHes the upper photo.
DISPLAY_REGION_BOXES = {
    "center": (0.28, 0.18, 0.72, 0.82),
    "left": (0.0, 0.12, 0.18, 0.82),
    "right": (0.82, 0.12, 1.0, 0.82),
    "top": (0.20, 0.02, 0.80, 0.16),
    "upper": (0.0, 0.0, 1.0, 0.40),
    "mid_left": (0.18, 0.20, 0.42, 0.80),
    "mid_right": (0.58, 0.20, 0.82, 0.80),
    "top_half": (0.0, 0.0, 1.0, 0.50),
    "bottom_half": (0.0, 0.50, 1.0, 1.0),
}
CAPTURE_STACK_REGIONS = ("top", "upper", "top_half", "bottom_half")
CAPTURE_SIDE_REGIONS = ("left", "right")
# Crops that are too small cannot be identified; 8px matches classify_screenshot's minimum edge length.
MIN_DISPLAY_CROP_EDGE_PIXELS = 8
# A 16:9 A1 fills the screen, so no second public fixture shows; A5 at the pool end is alone.
# The comparison accepts only portrait A2 / square A3.
DISPLAY_LETTERBOX_MARKS = frozenset({"A2", "A3"})
DISPLAY_FULL_BLEED_MARK = "A1"
DISPLAY_POOL_END_MARK = "A5"
# Matches the product's PlaybackSmartFillLayoutPolicy and its planning unit tests; read-only, never change thresholds.
APPLE_TV_PLANNING_PIXEL_SIZE = (3840, 2160)
MINIMUM_EFFECTIVE_PIXEL_SCALE = 0.85
CROP_RETENTION_THRESHOLD = 0.60
HORIZONTAL_EQUAL_PRIMARY_SHARE = 0.50
REQUIRED_SCREENSHOTS = (
    "pause",
    "after_next",
    "after_play",
    "after_background",
    "after_wake",
)
KNOWN_REQUESTS = frozenset(
    {
        "settings.open",
        "settings.pin.enable",
        "settings.pin.confirm",
        "settings.pin.cancel",
        "settings.pin.unlock",
        "settings.save.autoplay",
        "settings.save.interval",
        "settings.save.exif",
        "settings.save.display_mode",
        "settings.about.licenses",
        "playback.pause",
        "playback.next",
        "playback.play",
        "playback.background",
        "playback.foreground",
        "playback.wake_controls",
    }
)
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
GZIP_MAGIC = b"\x1f\x8b"
GZIP_DEFLATE_CM = 8
XZ_MAGIC = b"\xfd7zXZ\x00"
ZSTD_SKIPPABLE_MAGIC_LO = 0x184D2A50
ZSTD_SKIPPABLE_MAGIC_HI = 0x184D2A5F
ZSTD_SKIPPABLE_MAGIC_TAIL = b"\x2a\x4d\x18"
DECOMPRESS_PROBE_BYTES = 512
DECOMPRESS_CHUNK_BYTES = 64 * 1024
PLAYBACK_LAYER_PREFIX = "slideshow."
NON_PLAYBACK_LAYER_PREFIXES = ("settings.", "pinEntry.", "firstboot.", "mode.")
HIDDEN_CONTROL_BAR_PLAYBACK_IDENTIFIER = "slideshow.hiddenWakeReceiver"
# The hidden receiver counts as stably focused only after 5 consecutive observations;
# the UI test focusPoll is 0.08s, about 0.4s in total.
MIN_STABLE_HIDDEN_WAKE_FOCUS_OBSERVATIONS = 5
ALLOWED_SYSTEM_PAUSE_ACTIVATION = "activate_existing_process"
# The task's own DerivedData is always deleted afterwards and is not final persistent evidence.
TASK_TRANSIENT_EVIDENCE_DIRECTORY = "DerivedData"
# Before backgrounding, wait for a new stable frame: the 0.8s confirmation must be reserved from the deadline
# budget and must never unconditionally overrun the deadline.
NEW_STABLE_MARK_POLL_INTERVAL = 0.1
NEW_STABLE_MARK_CONFIRM_WINDOW = 0.8
NEW_STABLE_MARK_MIN_LUMA = 0.20
# Wake evidence must finish before the next auto-advance; 2.5s covers one screenshot, a tap and another screenshot.
WAKE_EVIDENCE_BUDGET_SECONDS = 2.5


def _clamped_wait(requested: float, remaining: float) -> float:
    if remaining <= 0 or requested <= 0:
        return 0.0
    return min(requested, remaining)


def poll_wait(remaining: float) -> float:
    return _clamped_wait(NEW_STABLE_MARK_POLL_INTERVAL, remaining)


def confirm_wait(remaining: float) -> float:
    return _clamped_wait(NEW_STABLE_MARK_CONFIRM_WINDOW, remaining)


def is_confirmed_new_stable_mark(
    *,
    status: str,
    mark: Optional[str],
    candidate_mark: str,
    initial_mark: str,
    mean_luma: float,
) -> bool:
    if status != "MATCH" or not mark:
        return False
    if mark != candidate_mark or mark == initial_mark:
        return False
    return mean_luma >= NEW_STABLE_MARK_MIN_LUMA


def hide_wait_for_wake(
    *,
    hide_seconds: float,
    remaining_to_autoplay: float,
    evidence_budget: float,
) -> float:
    max_wait = remaining_to_autoplay - evidence_budget
    if hide_seconds <= 0 or max_wait <= 0:
        return 0.0
    return min(hide_seconds, max_wait)


def should_wait_for_autoplay_before_wake(
    *,
    remaining_to_autoplay: float,
    evidence_budget: float,
) -> bool:
    return remaining_to_autoplay <= evidence_budget


def wake_window_crosses_autoplay(
    *,
    elapsed_before: float,
    elapsed_after: float,
    interval_seconds: float,
) -> bool:
    if interval_seconds <= 0 or elapsed_after <= elapsed_before:
        return False
    tick = (int(elapsed_before // interval_seconds) + 1) * interval_seconds
    return elapsed_before < tick <= elapsed_after


def wait_for_new_stable_mark(
    *,
    timeout: float,
    initial_mark: str,
    observe: Callable[[float], Any],
) -> str:
    elapsed = 0.0
    deadline = timeout
    while True:
        remaining = deadline - elapsed
        if remaining <= 0:
            break
        elapsed += poll_wait(remaining)
        sample = observe(elapsed)
        mark = str(getattr(sample, "mark", "") or "")
        if getattr(sample, "status", "") == "MATCH" and mark and mark != initial_mark:
            remaining = deadline - elapsed
            if remaining <= 0:
                break
            elapsed += confirm_wait(remaining)
            confirmed = observe(elapsed)
            confirmed_mark = str(getattr(confirmed, "mark", "") or "")
            if is_confirmed_new_stable_mark(
                status=str(getattr(confirmed, "status", "")),
                mark=confirmed_mark,
                candidate_mark=mark,
                initial_mark=initial_mark,
                mean_luma=float(getattr(confirmed, "mean_luma", 0.0)),
            ):
                return confirmed_mark
            continue
    raise AccessLifecycleContractError("No new stable frame was observed before backgrounding")


def is_slideshow_layer(identifiers: Sequence[str]) -> bool:
    present = [str(item) for item in identifiers if item]
    if any(
        item.startswith(prefix)
        for item in present
        for prefix in NON_PLAYBACK_LAYER_PREFIXES
    ):
        return False
    return any(item.startswith(PLAYBACK_LAYER_PREFIX) for item in present)


def assert_returned_to_slideshow(layer: Mapping[str, Any]) -> None:
    # Returning to playback is judged by the playback layer; a hidden control bar still counts as playback.
    # Photo changes on wake are checked separately.
    if layer.get("require_settings_button") is True:
        raise AccessLifecycleContractError("Returning to playback must not require the control bar to be visible")
    identifiers = layer.get("identifiers")
    if not isinstance(identifiers, Sequence) or isinstance(identifiers, (str, bytes)):
        raise AccessLifecycleContractError("Returning to playback requires confirmation of the playback layer")
    if not is_slideshow_layer([str(item) for item in identifiers]):
        raise AccessLifecycleContractError("Returning to playback requires confirmation of the playback layer")


def assert_settings_open(layer: Mapping[str, Any]) -> None:
    # After opening settings, either the PIN gate or the settings page is valid;
    # while the gate is still up, do not require the playback settings button yet.
    identifiers = layer.get("identifiers")
    if not isinstance(identifiers, Sequence) or isinstance(identifiers, (str, bytes)):
        raise AccessLifecycleContractError("After opening settings, the PIN gate or settings page must be confirmed")
    present = [str(item) for item in identifiers if item]
    pin_present = any(item.startswith("pinEntry.") for item in present)
    settings_present = any(item.startswith("settings.") for item in present)
    if not pin_present and not settings_present:
        raise AccessLifecycleContractError("After opening settings, the PIN gate or settings page must be confirmed")
    if pin_present and layer.get("require_playback_item") is True:
        raise AccessLifecycleContractError("Do not require playback settings while the PIN gate is still visible")


def assert_settings_return_wake(event: Mapping[str, Any]) -> None:
    # After returning from settings, wait until the transition finishes and the hidden receiver is stably focused,
    # then press a direction key once; never press twice.
    assert_returned_to_slideshow(
        {
            "identifiers": event.get("identifiers"),
            "require_settings_button": False,
        }
    )
    if event.get("transition_complete") is not True:
        raise AccessLifecycleContractError("Do not press a direction key before the transition from settings is complete")
    consecutive = event.get("consecutive_focused_observations")
    try:
        consecutive_count = int(consecutive)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        consecutive_count = 0
    if (
        event.get("hidden_wake_receiver_focused") is not True
        or event.get("hidden_wake_receiver_focus_stable") is not True
        or consecutive_count < MIN_STABLE_HIDDEN_WAKE_FOCUS_OBSERVATIONS
    ):
        raise AccessLifecycleContractError("The hidden receiver must be stably focused after returning from settings")
    press_count = event.get("directional_press_count")
    try:
        presses = int(press_count)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        presses = 0
    if presses != 1:
        raise AccessLifecycleContractError("Do not press twice to mask a failed first wake")
    screenshots = event.get("screenshots")
    if not isinstance(screenshots, Mapping):
        raise AccessLifecycleContractError("Wake evidence after returning from settings is missing before or after screenshots")
    before = str(screenshots.get("before") or "")
    after = str(screenshots.get("after") or "")
    if not before or not after:
        raise AccessLifecycleContractError("Wake evidence after returning from settings is missing before or after screenshots")


def assert_system_pause_identity_timing(order: object) -> None:
    # The identity after returning from background must be captured right after reaching the playback layer;
    # waking the control bar before capturing it must fail.
    if not isinstance(order, list) or not order:
        raise AccessLifecycleContractError("Background-return identity timing is missing")
    names = [str(item) for item in order]
    try:
        before = names.index("before-background")
        after = names.index("after-background")
    except ValueError as error:
        raise AccessLifecycleContractError("Background-return identity timing is missing") from error
    if after <= before:
        raise AccessLifecycleContractError("Background-return identity timing is missing")
    window = names[before + 1 : after]
    if any("wake" in item for item in window):
        raise AccessLifecycleContractError("Capture identity after background return before waking the control bar")


def assert_system_pause_activation(payload: Mapping[str, Any]) -> None:
    # app.activate() only activates an existing process; if the process exited after Home,
    # activate will Open/rebuild it.
    if payload.get("system_pause_activation") != ALLOWED_SYSTEM_PAUSE_ACTIVATION:
        raise AccessLifecycleContractError(
            "A system-pause analogy must activate the existing process without opening or rebuilding it"
        )
    if payload.get("process_rebuilt") is True:
        raise AccessLifecycleContractError("A system-pause analogy must not rebuild the process")
    if payload.get("home_left_app_running") is not True:
        raise AccessLifecycleContractError("Process exited after Home; activate would Open/rebuild it")


def evaluate_access_lifecycle_evidence(payload: Mapping[str, Any]) -> dict[str, Any]:
    # Skips, missing screenshots, unknown requests and faked persistence always fail;
    # a D-01 formal storage failure stays PARTIAL.
    status = str(payload.get("status") or "")
    if status.lower() == "skip":
        raise AccessLifecycleContractError("skip must not count as a pass")

    if payload.get("identity_source") != ALLOWED_IDENTITY_SOURCE:
        raise AccessLifecycleContractError("Identity must come from public fixture images, not logs or indexes")

    fixture_set = str(payload.get("fixture_set") or "")
    observed_hash = str(payload.get("fixture_sha256") or "")
    frozen = FROZEN_FIXTURE_SHA256.get(fixture_set)
    if frozen is None or observed_hash != frozen:
        raise AccessLifecycleContractError("fixture hash mismatch; this batch fails")

    if payload.get("retries_used_to_pass") is True:
        raise AccessLifecycleContractError("Retry masking must not count as passing")
    device_tests_run = bool(payload.get("device_tests_run"))
    _assert_settings(payload.get("settings"))
    _assert_no_forced_display_mode(payload.get("launch_environment"))
    _assert_requests(payload.get("requests"))
    _assert_screenshots(payload.get("screenshots"), device_tests_run=device_tests_run)
    _assert_scenes(
        payload.get("scenes"),
        payload.get("progress_after_play"),
        require_play_progress_zero=not device_tests_run,
    )
    if payload.get("system_pause_analog"):
        assert_system_pause_activation(payload)
        assert_system_pause_identity_timing(payload.get("screenshot_order"))
    pin_flow = _pin_flow(payload.get("pin_flow"))
    d01 = _assert_pin_flow(
        pin_flow,
        xctest_config_present=bool(payload.get("xctest_config_present")),
    )
    if device_tests_run:
        _assert_display_policy(payload.get("display_policy"))
        _assert_ipad_license_return(payload)
        _assert_background_preconditions(payload)
        _assert_measured_progress(payload)
    verdict = "PARTIAL" if pin_flow.get("storage_kind") == "keychain_failure" else "PASS"
    return {
        "verdict": verdict,
        "d01": d01,
        "identity_source": ALLOWED_IDENTITY_SOURCE,
        "fixture_set": fixture_set,
        "fixture_sha256": observed_hash,
        "device_tests_run": device_tests_run,
        "skip_counted_as_pass": False,
    }


def scan_sensitive_evidence(root: Path, pin_values: Sequence[str]) -> dict[str, Any]:
    # Report only the kind of place where a PIN appeared; never write the PIN back into errors or scan results.
    if not pin_values:
        raise AccessLifecycleContractError("Sensitive scan has no PIN values; cannot prove redaction")
    pins = [value for value in pin_values if value]
    if not pins:
        raise AccessLifecycleContractError("Sensitive scan has no PIN values; cannot prove redaction")
    matched: list[str] = []
    for path in _iter_persistent_evidence_files(root):
        relative = str(path.relative_to(root))
        if _contains_any_pin(relative, pins):
            matched.append(relative)
            continue
        try:
            data = path.read_bytes()
        except OSError as error:
            raise AccessLifecycleContractError(f"Evidence unreadable: {relative}") from error
        if logical_bytes_contain(data, pins):
            matched.append(relative)
    if matched:
        raise AccessLifecycleContractError("PIN appears in a file name, command, log or attachment")
    return {"result": "PASS", "matched_files": []}


def _iter_persistent_evidence_files(root: Path) -> Iterator[Path]:
    def raise_walk_error(error: OSError) -> None:
        raise AccessLifecycleContractError(f"Evidence unreadable: {error.filename}") from error

    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(
        root,
        onerror=raise_walk_error,
        followlinks=False,
    ):
        dirnames[:] = [name for name in dirnames if name != TASK_TRANSIENT_EVIDENCE_DIRECTORY]
        current = Path(dirpath)
        for filename in filenames:
            files.append(current / filename)
    yield from sorted(files)


def _assert_settings(raw: object) -> None:
    if not isinstance(raw, Mapping):
        raise AccessLifecycleContractError("Missing settings evidence")
    source = str(raw.get("source") or "")
    if source in FORBIDDEN_SETTINGS_SOURCES or source != ALLOWED_SETTINGS_SOURCE:
        raise AccessLifecycleContractError("Launch arguments or UserDefaults cannot impersonate formal persistence")
    before = raw.get("before")
    after = raw.get("after_restart")
    if not isinstance(before, Mapping) or not isinstance(after, Mapping):
        raise AccessLifecycleContractError("Missing settings evidence")
    for field in SETTINGS_FIELDS:
        if field not in before or field not in after:
            raise AccessLifecycleContractError("Missing settings evidence")
        if before[field] != after[field]:
            raise AccessLifecycleContractError("Settings were not persisted")
    if all(before[field] == DEFAULT_PLAYBACK_SETTINGS[field] for field in SETTINGS_FIELDS):
        raise AccessLifecycleContractError("Settings were not persisted")


def _assert_no_forced_display_mode(raw: object) -> None:
    environment = raw if isinstance(raw, Mapping) else {}
    if FORBIDDEN_DISPLAY_MODE_KEY in environment:
        raise AccessLifecycleContractError("A forced display mode cannot replace the persisted settings path")


def _identity_payload(identity: PhotoIdentity) -> dict[str, object]:
    return {
        "status": identity.status,
        "mark": identity.mark,
        "notes": list(identity.notes),
    }


def _crop_png_bytes(image_bytes: bytes, box: Tuple[float, float, float, float]) -> bytes:
    import io

    from PIL import Image

    with Image.open(io.BytesIO(image_bytes)) as image:
        width, height = image.size
        left, top, right, bottom = box
        cropped = image.crop(
            (
                int(width * left),
                int(height * top),
                max(int(width * left) + MIN_DISPLAY_CROP_EDGE_PIXELS, int(width * right)),
                max(int(height * top) + MIN_DISPLAY_CROP_EDGE_PIXELS, int(height * bottom)),
            )
        )
        buffer = io.BytesIO()
        cropped.save(buffer, format="PNG")
        return buffer.getvalue()


def classify_display_regions(image_bytes: bytes) -> dict[str, PhotoIdentity]:
    regions = {"full": classify_screenshot(image_bytes)}
    for name, box in DISPLAY_REGION_BOXES.items():
        try:
            cropped = _crop_png_bytes(image_bytes, box)
        except (OSError, ValueError) as error:
            regions[name] = PhotoIdentity(
                "UNRECOGNIZABLE",
                None,
                {},
                0.0,
                (f"crop-failed:{type(error).__name__}",),
            )
            continue
        regions[name] = classify_screenshot(cropped)
    return regions


def _ordered_match_marks(
    regions: Mapping[str, PhotoIdentity],
    names: Sequence[str],
) -> list[str]:
    marks: list[str] = []
    for name in names:
        identity = regions.get(name)
        if (
            identity is not None
            and identity.status == "MATCH"
            and identity.mark in MARKS
            and identity.mark not in marks
        ):
            marks.append(identity.mark)
    return marks


def capture_identity(image_bytes: bytes) -> PhotoIdentity:
    # A combined identity needs at least two region MATCHes; a full-screen TRANSITION/BLACK/BLANK or no region MATCH
    # must not be promoted.
    regions = classify_display_regions(image_bytes)
    full = regions["full"]
    stack_marks = _ordered_match_marks(regions, CAPTURE_STACK_REGIONS)
    if len(stack_marks) >= 2:
        return PhotoIdentity(
            "MATCH",
            "+".join(stack_marks),
            dict(full.scores),
            full.mean_luma,
            ("stack-region-match",) + tuple(full.notes),
        )
    side_marks = _ordered_match_marks(regions, CAPTURE_SIDE_REGIONS)
    if len(side_marks) >= 2:
        return PhotoIdentity(
            "MATCH",
            "+".join(side_marks),
            dict(full.scores),
            full.mean_luma,
            ("side-region-match",) + tuple(full.notes),
        )
    return full


def scene_mark_from_bytes(image_bytes: bytes) -> str:
    identity = capture_identity(image_bytes)
    if identity.status == "MATCH" and identity.mark:
        return identity.mark
    if identity.status in INVALID_SCENE_MARKS:
        return identity.status
    return "UNRECOGNIZABLE"


def scene_mark_from_png(path: Path) -> str:
    if not path.is_file():
        raise AccessLifecycleContractError("Missing screenshots must not count as passing")
    return scene_mark_from_bytes(path.read_bytes())


def _reject_invalid_display(identity: PhotoIdentity, label: str) -> None:
    invalid = INVALID_DISPLAY_STATUSES.get(identity.status)
    if invalid is not None:
        raise AccessLifecycleContractError(f"{invalid}: {label}")
    if identity.status == "MATCH" and identity.mark not in MARKS:
        raise AccessLifecycleContractError(f"Non-public fixture must not count as a pass: {label}")


POOL_BURN_SCREENSHOTS = (
    "pause",
    "after-next",
    "after-play",
    "before-background",
    "after-background",
    "before-wake",
    "after-wake",
)
SCREENSHOT_TO_SCENE = {
    "pause": "pause",
    "after-next": "after_next",
    "after-play": "after_play",
    "before-background": "before_background",
    "after-background": "after_background",
    "before-wake": "before_wake",
    "after-wake": "after_wake",
}


def inspect_display_strategy(
    before_bytes: bytes,
    after_bytes: bytes,
) -> dict[str, Any]:
    # Keep the per-region identification even on failure instead of raising a one-line error.
    report: dict[str, Any] = {
        "error": None,
        "before": None,
        "after": None,
        "before_mark": None,
        "before_partner_marks": [],
        "partner_marks": [],
    }
    if not before_bytes or not after_bytes:
        report["error"] = "Missing screenshots must not count as passing"
        return report

    identical = before_bytes == after_bytes
    before_regions = classify_display_regions(before_bytes)
    after_regions = classify_display_regions(after_bytes)
    before_full = before_regions["full"]
    after_full = after_regions["full"]
    after_center = after_regions["center"]
    before_mark = before_full.mark if before_full.status == "MATCH" else None
    before_partner_marks = _side_partner_marks(before_regions, before_mark)
    partner_marks = sorted(
        {
            identity.mark
            for name, identity in after_regions.items()
            if name != "full"
            and identity.status == "MATCH"
            and identity.mark in MARKS
            and identity.mark != before_mark
        }
    )
    report["before"] = {
        "file": "display-before.png",
        **_identity_payload(before_full),
        "regions": {
            name: _identity_payload(identity) for name, identity in before_regions.items()
        },
    }
    report["after"] = {
        "file": "display-after.png",
        **_identity_payload(after_full),
        "center_mark": after_center.mark if after_center.status == "MATCH" else None,
        "partner_marks": partner_marks,
        "regions": {
            name: _identity_payload(identity) for name, identity in after_regions.items()
        },
    }
    report["before_mark"] = before_mark
    report["before_partner_marks"] = before_partner_marks
    report["partner_marks"] = partner_marks
    if identical:
        report["error"] = "Display policy did not take effect"
        return report
    try:
        _reject_invalid_display(before_full, "display-before")
        _reject_invalid_display(after_full, "display-after")
    except AccessLifecycleContractError as error:
        report["error"] = str(error)
        return report
    if before_full.status != "MATCH" or before_full.mark not in MARKS:
        report["error"] = "display-before must be a single public fixture photo"
        return report
    letterbox_error = _display_before_letterbox_error(before_mark, before_partner_marks)
    if letterbox_error:
        report["error"] = letterbox_error
        return report
    before_still_visible = any(
        identity.status == "MATCH" and identity.mark == before_mark
        for name, identity in after_regions.items()
        if name != "full"
    )
    visible_multi_image = before_still_visible and bool(partner_marks)
    if after_full.status == "TRANSITION" and not visible_multi_image:
        report["error"] = "TRANSITION must not count as a display strategy pass"
        return report
    if not visible_multi_image:
        if after_full.status == "MATCH" and after_full.mark != before_mark:
            report["error"] = "A settings round trip must not switch to a different single photo"
        elif not before_still_visible:
            report["error"] = "The main photo must remain the public fixture shown before opening settings"
        else:
            report["error"] = "Smart Fill must be visible in the after image"
        return report
    return report


def _side_partner_marks(
    regions: Mapping[str, PhotoIdentity],
    before_mark: Optional[str],
) -> list[str]:
    return sorted(
        {
            identity.mark
            for name in ("left", "right")
            if (identity := regions.get(name)) is not None
            and identity.status == "MATCH"
            and identity.mark in MARKS
            and identity.mark != before_mark
        }
    )


def _display_before_letterbox_error(
    before_mark: Optional[str],
    before_partner_marks: Sequence[str],
) -> Optional[str]:
    if before_mark == DISPLAY_FULL_BLEED_MARK:
        return "The comparison must not stop on full-bleed A1"
    if before_mark == DISPLAY_POOL_END_MARK:
        return "The comparison must not advance to the last pool photo A5"
    if before_mark not in DISPLAY_LETTERBOX_MARKS:
        return "display-before must show a portrait or square photo"
    if any(mark != before_mark and mark in MARKS for mark in before_partner_marks):
        return "The side margins in before must not already show the second public fixture"
    return None


def assert_display_before_letterbox(
    before_mark: object,
    before_partner_marks: object = (),
) -> None:
    mark = str(before_mark or "") or None
    if isinstance(before_partner_marks, Sequence) and not isinstance(
        before_partner_marks, (str, bytes)
    ):
        partners = [str(item) for item in before_partner_marks if item]
    else:
        partners = []
    error = _display_before_letterbox_error(mark, partners)
    if error:
        raise AccessLifecycleContractError(error)


def assert_display_strategy_visible(
    before_bytes: bytes,
    after_bytes: bytes,
) -> dict[str, Any]:
    # Accept only public fixture frames: the photo from before settings still MATCHes in a region,
    # and another public fixture appears as well.
    report = inspect_display_strategy(before_bytes, after_bytes)
    error = report.get("error")
    if error:
        raise AccessLifecycleContractError(str(error))
    return report


def assert_display_before_pool_burn(screenshot_order: object) -> None:
    if not isinstance(screenshot_order, list) or not screenshot_order:
        raise AccessLifecycleContractError("Compare the display before autoplay exhausts the playback pool")
    names = [str(item) for item in screenshot_order]
    try:
        display_at = names.index("display-before")
    except ValueError as error:
        raise AccessLifecycleContractError("Compare the display before autoplay exhausts the playback pool") from error
    for name in POOL_BURN_SCREENSHOTS:
        try:
            index = names.index(name)
        except ValueError:
            continue
        if index < display_at:
            raise AccessLifecycleContractError("Compare the display before autoplay exhausts the playback pool")


def _centered_cover_crop(
    source_width: int,
    source_height: int,
    slot_aspect: float,
) -> Tuple[float, float]:
    image_aspect = source_width / source_height
    if image_aspect > slot_aspect:
        crop_width = max(0.0, min(1.0, slot_aspect / image_aspect))
        return crop_width, 1.0
    crop_height = max(0.0, min(1.0, image_aspect / slot_aspect))
    return 1.0, crop_height


def _effective_pixels_too_low(
    source_width: int,
    source_height: int,
    crop_width: float,
    crop_height: float,
    frame_width: float,
    frame_height: float,
) -> bool:
    source_crop_width = source_width * crop_width
    source_crop_height = source_height * crop_height
    display_width = APPLE_TV_PLANNING_PIXEL_SIZE[0] * frame_width
    display_height = APPLE_TV_PLANNING_PIXEL_SIZE[1] * frame_height
    return (
        source_crop_width < display_width * MINIMUM_EFFECTIVE_PIXEL_SCALE
        or source_crop_height < display_height * MINIMUM_EFFECTIVE_PIXEL_SCALE
    )


def assert_appletv_double_layout_visible(
    originals: Sequence[Tuple[str, int, int]],
) -> None:
    # Even 50/50 left/right split: the smallest double-photo slot in which a portrait/square photo leaves room
    # for a second public fixture.
    if len(originals) < 2:
        raise AccessLifecycleContractError("A visible multi-photo layout needs metadata for at least two originals")
    frames = (HORIZONTAL_EQUAL_PRIMARY_SHARE, 1.0 - HORIZONTAL_EQUAL_PRIMARY_SHARE)
    reasons: list[str] = []
    surface_width, surface_height = APPLE_TV_PLANNING_PIXEL_SIZE
    for (mark, width, height), frame_width in zip(originals, frames):
        if width <= 0 or height <= 0:
            reasons.append(f"{mark} is missing original pixel dimensions")
            continue
        slot_aspect = (surface_width * frame_width) / surface_height
        crop_width, crop_height = _centered_cover_crop(width, height, slot_aspect)
        if crop_width * crop_height < CROP_RETENTION_THRESHOLD:
            reasons.append(f"{mark} crop retention is too low")
            continue
        if _effective_pixels_too_low(
            width,
            height,
            crop_width,
            crop_height,
            frame_width,
            1.0,
        ):
            reasons.append(f"{mark} effective pixels too low")
    if reasons:
        raise AccessLifecycleContractError("Original metadata cannot form a visible multi-photo layout: " + ", ".join(reasons))


def assert_unshown_display_partners(
    *,
    screenshot_order: object,
    scenes: Mapping[str, Any],
    before_mark: str,
) -> None:
    if before_mark not in MARKS:
        raise AccessLifecycleContractError("display-before must be a single public fixture photo")
    names = [str(item) for item in screenshot_order] if isinstance(screenshot_order, list) else []
    display_at = names.index("display-before") if "display-before" in names else 0
    shown: set[str] = set()
    for name in names[:display_at]:
        key = SCREENSHOT_TO_SCENE.get(name)
        if key is None:
            continue
        mark = scenes.get(key)
        if isinstance(mark, str) and mark in MARKS:
            shown.add(mark)
    remaining = set(MARKS) - shown - {before_mark}
    if not remaining:
        raise AccessLifecycleContractError("No unshown partner remains after the current frame")


def _assert_requests(raw: object) -> None:
    if not isinstance(raw, list) or not raw:
        raise AccessLifecycleContractError("Missing request evidence")
    for item in raw:
        request = str(item)
        if request not in KNOWN_REQUESTS:
            raise AccessLifecycleContractError(f"Unknown request; batch failed: {request}")


def _assert_screenshots(raw: object, *, device_tests_run: bool) -> None:
    if not isinstance(raw, Mapping):
        raise AccessLifecycleContractError("Missing screenshots must not count as passing")
    required = REQUIRED_SCREENSHOTS + (DEVICE_REQUIRED_SCREENSHOTS if device_tests_run else ())
    missing = [name for name in required if not raw.get(name)]
    if missing:
        raise AccessLifecycleContractError("Missing screenshots must not count as passing: " + ", ".join(missing))


def _assert_display_policy(raw: object) -> None:
    if not isinstance(raw, Mapping):
        raise AccessLifecycleContractError("The display policy must take effect before it can pass")
    if str(raw.get("source") or "") != ALLOWED_SETTINGS_SOURCE:
        raise AccessLifecycleContractError("Launch arguments or UserDefaults cannot impersonate formal persistence")
    mode_before = str(raw.get("mode_before") or "")
    mode_after = str(raw.get("mode_after") or "")
    if not mode_before or not mode_after or mode_before == mode_after:
        raise AccessLifecycleContractError("The display policy must take effect before it can pass")
    before_hash = str(raw.get("png_sha256_before") or "")
    after_hash = str(raw.get("png_sha256_after") or "")
    if len(before_hash) != 64 or len(after_hash) != 64 or before_hash == after_hash:
        raise AccessLifecycleContractError("The display policy must take effect before it can pass")
    for name in ("mark_before", "mark_after"):
        mark = str(raw.get(name) or "")
        if not mark:
            raise AccessLifecycleContractError("Missing screenshots must not count as passing")
        invalid = INVALID_SCENE_MARKS.get(mark)
        if invalid is not None:
            raise AccessLifecycleContractError(f"{invalid}: {name}")


def _assert_ipad_license_return(payload: Mapping[str, Any]) -> None:
    if str(payload.get("device") or "") != "ipad":
        return
    raw = payload.get("ipad_license_return")
    if not isinstance(raw, Mapping) or raw.get("stack_preserved") is not True:
        raise AccessLifecycleContractError("The iPad open-source license return stack must not be missing")


def _assert_scenes(
    raw: object,
    progress_after_play: object,
    *,
    require_play_progress_zero: bool = True,
) -> None:
    if not isinstance(raw, Mapping):
        raise AccessLifecycleContractError("Missing screenshots must not count as passing")
    required = (
        "pause",
        "after_next",
        "after_play",
        "before_background",
        "after_background",
        "before_wake",
        "after_wake",
    )
    for name in required:
        mark = raw.get(name)
        if not isinstance(mark, str) or not mark:
            raise AccessLifecycleContractError("Missing screenshots must not count as passing")
        invalid = INVALID_SCENE_MARKS.get(mark)
        if invalid is not None:
            raise AccessLifecycleContractError(f"{invalid}: {name}")
    if raw["after_next"] == raw["pause"]:
        raise AccessLifecycleContractError("next after pause must switch to a new scene")
    if raw["after_play"] == raw["pause"] or raw["after_play"] != raw["after_next"]:
        raise AccessLifecycleContractError("Returning to the previous scene must not count as passing")
    if require_play_progress_zero and progress_after_play != 0:
        raise AccessLifecycleContractError("Play must resume from progress 0 on the new scene")
    if raw["after_background"] != raw["before_background"]:
        raise AccessLifecycleContractError("Changing photos after background return must not count as passing")
    if raw["after_wake"] != raw["before_wake"]:
        raise AccessLifecycleContractError("Changing photos while waking the controls must not count as passing")


def _assert_background_preconditions(payload: Mapping[str, Any]) -> None:
    settings = payload.get("settings_at_background")
    if not isinstance(settings, Mapping):
        raise AccessLifecycleContractError("Missing settings evidence at the moment of backgrounding")
    if str(settings.get("source") or "") != ALLOWED_SETTINGS_SOURCE:
        raise AccessLifecycleContractError("Launch arguments or UserDefaults cannot impersonate formal persistence")
    if settings.get("autoPlayEnabled") is not True:
        raise AccessLifecycleContractError("Autoplay must be enabled when backgrounding")
    interval = _require_number(settings.get("intervalSeconds"), "read interval")
    background = payload.get("background")
    if not isinstance(background, Mapping):
        raise AccessLifecycleContractError("Background wait must be bound to the read interval")
    bound_interval = _require_number(background.get("interval_seconds"), "read interval")
    wait_seconds = _require_number(background.get("wait_seconds"), "background wait")
    if bound_interval != interval:
        raise AccessLifecycleContractError("Background wait must be bound to the read interval")
    if wait_seconds <= interval:
        raise AccessLifecycleContractError("Background wait must exceed one read interval")
    after_restart = payload.get("settings")
    if isinstance(after_restart, Mapping):
        persisted = after_restart.get("after_restart")
        if isinstance(persisted, Mapping) and persisted.get("autoPlayEnabled") is not True:
            raise AccessLifecycleContractError("Settings were not persisted")


def _assert_measured_progress(payload: Mapping[str, Any]) -> None:
    if "progress_after_next" not in payload:
        raise AccessLifecycleContractError("Progress must be measured")
    if not str(payload.get("progress_source") or "").strip():
        raise AccessLifecycleContractError("Progress must be measured")
    progress_after_next = _require_number(payload.get("progress_after_next"), "progress")
    _require_number(payload.get("progress_after_play"), "progress")
    if abs(progress_after_next) > MEASURED_PROGRESS_ZERO_EPSILON:
        raise AccessLifecycleContractError("Next while paused must preserve progress at 0")
    raw_next = str(payload.get("progress_raw_after_next") or "")
    raw_play = str(payload.get("progress_raw_after_play") or "")
    if not _raw_has_measured_progress(raw_next) or not _raw_has_measured_progress(raw_play):
        raise AccessLifecycleContractError("Progress must be measured")


def _raw_has_measured_progress(raw: str) -> bool:
    if not raw or "progress=missing" in raw or "motionRawProgress=none" in raw:
        return False
    return "progress=" in raw or "motionRawProgress=" in raw


def _require_number(raw: object, label: str) -> float:
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        raise AccessLifecycleContractError(f"{label} must be measured")
    return float(raw)


def _pin_flow(raw: object) -> Mapping[str, Any]:
    if not isinstance(raw, Mapping):
        raise AccessLifecycleContractError("Missing PIN flow evidence")
    return raw


def _assert_pin_flow(raw: object, *, xctest_config_present: bool) -> str:
    flow = raw if isinstance(raw, Mapping) else _pin_flow(raw)
    if flow.get("wrong_pin_entered"):
        raise AccessLifecycleContractError("An incorrect PIN must not open settings")
    if flow.get("cancel_still_protected") is not True:
        raise AccessLifecycleContractError("Protection must remain after cancelling")
    if flow.get("correct_pin_entered") is not True:
        raise AccessLifecycleContractError("The correct PIN must open settings")
    if flow.get("restart_gated") is not True:
        raise AccessLifecycleContractError("The gate must still be active after restart")
    storage = str(flow.get("storage_kind") or "")
    if storage == "keychain" and xctest_config_present:
        raise AccessLifecycleContractError("Test UserDefaults must not pose as the formal Keychain")
    if storage == "keychain_failure":
        return "PARTIAL"
    if storage != "uitest_userdefaults":
        raise AccessLifecycleContractError("Unknown PIN storage kind; this batch fails")
    return "PARTIAL"


def _contains_any_pin(text: str, pins: Sequence[str]) -> bool:
    return any(pin in text for pin in pins)


def logical_bytes_contain(data: bytes, values: Sequence[str]) -> bool:
    # Decode valid frames; scan cleartext metadata and any bytes that cannot be decoded.
    # Scan chunk by chunk without joining the whole blob.
    needles = [value.encode("utf-8") for value in values if value]
    if not needles:
        return False
    overlap = max(len(needle) for needle in needles) - 1
    tail = b""
    for part in _iter_logical_parts(data):
        window = tail + part if tail else part
        if any(needle in window for needle in needles):
            return True
        tail = window[-overlap:] if overlap > 0 else b""
    return False


def logical_content_bytes(data: bytes) -> bytes:
    """Decode valid frames while retaining skippable metadata and undecodable raw bytes."""
    return b"".join(_iter_logical_parts(data))


def _iter_logical_parts(data: bytes) -> Iterator[bytes]:
    if not data:
        return
    starts = _compression_magic_offsets(data)
    index = 0
    cursor = 0
    length = len(data)
    while index < length:
        while cursor < len(starts) and starts[cursor] < index:
            cursor += 1
        at_magic = cursor < len(starts) and starts[cursor] == index
        if at_magic:
            frame = _decompress_frame_at(data, index)
            if frame is not None:
                payload, consumed = frame
                if consumed <= 0:
                    yield data[index : index + 1]
                    index += 1
                    continue
                if payload:
                    yield payload
                index += consumed
                continue
            # Failed decoding cannot prove these bytes are safe to discard.
            cursor += 1
        nxt = starts[cursor] if cursor < len(starts) else length
        if nxt <= index:
            yield data[index : index + 1]
            index += 1
            continue
        yield data[index:nxt]
        index = nxt


def _compression_magic_offsets(data: bytes) -> list[int]:
    # One forward find pass per magic; never rerun several finds over the remaining bytes for each offset.
    found: set[int] = set()
    for magic in (ZSTD_MAGIC, GZIP_MAGIC, XZ_MAGIC):
        start = 0
        while True:
            at = data.find(magic, start)
            if at < 0:
                break
            found.add(at)
            start = at + 1
    for prefix in range(0x50, 0x60):
        magic = bytes((prefix,)) + ZSTD_SKIPPABLE_MAGIC_TAIL
        start = 0
        while True:
            at = data.find(magic, start)
            if at < 0:
                break
            found.add(at)
            start = at + 1
    return sorted(found)


def _decompress_frame_at(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    skippable = _zstd_skippable_size(data, offset)
    if skippable is not None:
        # Zstd skips this metadata, but it is stored as cleartext in the evidence.
        return data[offset + 8 : offset + skippable], skippable
    if data.startswith(ZSTD_MAGIC, offset):
        return _decompress_zstd_frame(data, offset)
    if data.startswith(GZIP_MAGIC, offset):
        return _decompress_gzip_frame(data, offset)
    if data.startswith(XZ_MAGIC, offset):
        return _decompress_xz_frame(data, offset)
    return None


def _zstd_skippable_size(data: bytes, offset: int) -> Optional[int]:
    if offset + 8 > len(data):
        return None
    magic = int.from_bytes(data[offset : offset + 4], "little")
    if magic < ZSTD_SKIPPABLE_MAGIC_LO or magic > ZSTD_SKIPPABLE_MAGIC_HI:
        return None
    size = int.from_bytes(data[offset + 4 : offset + 8], "little")
    consumed = 8 + size
    if offset + consumed > len(data):
        return None
    return consumed


def _decompress_zstd_frame(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    remaining = len(data) - offset
    if remaining <= 0:
        return None
    py314 = _zstd_py314()
    if py314 is not None:
        errors: tuple[type[BaseException], ...] = (ValueError, OSError, AttributeError, TypeError)
        zstd_error = getattr(py314, "ZstdError", None)
        if isinstance(zstd_error, type):
            errors = errors + (zstd_error,)
        try:
            view = memoryview(data)[offset:]
            consumed = int(py314.get_frame_size(view))
            if 0 < consumed <= remaining:
                payload = py314.decompress(data[offset : offset + consumed])
                return payload, consumed
        except errors:
            pass
    ctypes_frame = _zstd_ctypes_frame(data, offset)
    if ctypes_frame is not None:
        return ctypes_frame
    # Once ctypes/py314 has ruled out a valid frame, do not hand the whole remaining blob to the CLI.
    if py314 is None and _load_libzstd() is None:
        return _zstd_cli_frame(data, offset)
    return None


def _zstd_py314() -> Any:
    try:
        from compression import zstd as module
    except ImportError:
        return None
    return module


def _zstd_source_pointer(data: bytes, offset: int) -> Optional[int]:
    import ctypes

    pythonapi = ctypes.pythonapi
    pythonapi.PyBytes_AsString.restype = ctypes.c_void_p
    pythonapi.PyBytes_AsString.argtypes = [ctypes.py_object]
    base = pythonapi.PyBytes_AsString(data)
    if not base:
        return None
    return int(base) + offset


def _zstd_ctypes_frame(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    lib = _load_libzstd()
    if lib is None:
        return None
    import ctypes

    remaining = len(data) - offset
    if remaining <= 0:
        return None
    src = _zstd_source_pointer(data, offset)
    if src is None:
        return None
    consumed = lib.ZSTD_findFrameCompressedSize(src, remaining)
    if lib.ZSTD_isError(consumed):
        return None
    consumed_i = int(consumed)
    if consumed_i <= 0 or consumed_i > remaining:
        return None
    content_size = lib.ZSTD_getFrameContentSize(src, consumed_i)
    if content_size in (2**64 - 1, 2**64 - 2):
        dst_capacity = max(consumed_i * 8, 64)
    else:
        dst_capacity = max(int(content_size), 1)
    dst = ctypes.create_string_buffer(dst_capacity)
    written = lib.ZSTD_decompress(dst, dst_capacity, src, consumed_i)
    if lib.ZSTD_isError(written):
        return None
    return dst.raw[: int(written)], consumed_i


_LIBZSTD: Any = "unset"


def _load_libzstd() -> Any:
    global _LIBZSTD
    if _LIBZSTD != "unset":
        return _LIBZSTD
    import ctypes

    for path in (
        "/opt/homebrew/lib/libzstd.dylib",
        "/usr/local/lib/libzstd.dylib",
        "libzstd.dylib",
        "libzstd.so.1",
        "libzstd.so",
    ):
        try:
            lib = ctypes.CDLL(path)
        except OSError:
            continue
        lib.ZSTD_findFrameCompressedSize.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        lib.ZSTD_findFrameCompressedSize.restype = ctypes.c_size_t
        lib.ZSTD_getFrameContentSize.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        lib.ZSTD_getFrameContentSize.restype = ctypes.c_ulonglong
        lib.ZSTD_decompress.argtypes = [
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_void_p,
            ctypes.c_size_t,
        ]
        lib.ZSTD_decompress.restype = ctypes.c_size_t
        lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
        lib.ZSTD_isError.restype = ctypes.c_uint
        _LIBZSTD = lib
        return lib
    _LIBZSTD = None
    return None


def _zstd_cli_frame(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    import shutil
    import subprocess

    consumed = _zstd_frame_size(data, offset)
    if consumed is None:
        return None
    binary = shutil.which("zstd")
    if binary is None:
        return None
    blob = data[offset : offset + consumed]
    completed = subprocess.run(
        [binary, "-d", "-c", "-q"],
        input=blob,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout, consumed


def _zstd_frame_size(data: bytes, offset: int) -> Optional[int]:
    # Walk framing only; the CLI still validates and decompresses the exact frame.
    # Format: https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md
    if not data.startswith(ZSTD_MAGIC, offset) or offset + 5 > len(data):
        return None
    descriptor = data[offset + 4]
    if descriptor & 0x08:  # Reserved bit must be zero.
        return None
    single_segment = bool(descriptor & 0x20)
    content_size_flag = descriptor >> 6
    content_size_bytes = (int(single_segment), 2, 4, 8)[content_size_flag]
    dictionary_id_bytes = (0, 1, 2, 4)[descriptor & 3]
    cursor = offset + 5 + int(not single_segment) + dictionary_id_bytes + content_size_bytes
    if cursor > len(data):
        return None
    while cursor + 3 <= len(data):
        header = int.from_bytes(data[cursor : cursor + 3], "little")
        cursor += 3
        block_type = (header >> 1) & 3
        if block_type == 3:
            return None
        block_size = header >> 3
        cursor += 1 if block_type == 1 else block_size
        if cursor > len(data):
            return None
        if header & 1:
            cursor += 4 if descriptor & 4 else 0
            return cursor - offset if cursor <= len(data) else None
    return None


def _decompress_gzip_frame(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    remaining = len(data) - offset
    if remaining < 3 or data[offset + 2] != GZIP_DEFLATE_CM:
        return None
    return _decompress_chunked(
        data,
        offset,
        zlib.decompressobj(16 + zlib.MAX_WBITS),
        zlib.error,
    )


def _decompress_xz_frame(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    return _decompress_chunked(data, offset, lzma.LZMADecompressor(), lzma.LZMAError)


def _decompress_chunked(
    data: bytes,
    offset: int,
    decoder: Any,
    error_type: type[BaseException],
) -> Optional[Tuple[bytes, int]]:
    remaining = len(data) - offset
    if remaining <= 0:
        return None
    parts: list[bytes] = []
    consumed = 0
    try:
        first = min(DECOMPRESS_PROBE_BYTES, remaining)
        parts.append(decoder.decompress(data[offset : offset + first]))
        consumed = first
        unused = decoder.unused_data
        if unused:
            consumed -= len(unused)
        else:
            while consumed < remaining:
                if getattr(decoder, "eof", False):
                    break
                take = min(DECOMPRESS_CHUNK_BYTES, remaining - consumed)
                parts.append(
                    decoder.decompress(data[offset + consumed : offset + consumed + take])
                )
                consumed += take
                unused = decoder.unused_data
                if unused:
                    consumed -= len(unused)
                    break
        flush = getattr(decoder, "flush", None)
        if callable(flush):
            parts.append(flush())
    except error_type:
        return None
    if consumed <= 0:
        return None
    return b"".join(parts), consumed
