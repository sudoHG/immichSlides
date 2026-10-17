"""Moved fixtures and imports shared by the existing test classes."""

from __future__ import annotations


import io


import json


import subprocess


import sys


import tempfile


import unittest


from pathlib import Path


from PIL import Image, ImageFilter, ImageOps


SCRIPT_DIR = Path(__file__).resolve().parent


from strict_e2e_filter_contract import (  # noqa: E402
    DISPLAY_POLICY_CANDIDATE_PREFIX,
    FILTER_VISUAL_SUITES,
    FROZEN_FIXTURE_SHA256,
    START_PLAYBACK_BUTTON_ID,
    FilterContractError,
    album_selection_labels,
    assert_empty_selection_cannot_start,
    assert_final_pool_equals_union,
    assert_foreign_id_tokens_absent,
    assert_foreign_server_ids_absent,
    assert_playback_marks_in_target,
    assert_playback_marks_in_union,
    assert_request_log_contract,
    assert_solo_only_not_vacuous,
    evaluate_filter_visual_identity,
    load_member_manifest,
    member_manifest,
    person_selection_labels,
    require_photo_mark,
    union_selection_labels,
    write_member_manifest,
)


from strict_e2e_photo_identity import classify_screenshot  # noqa: E402


from strict_e2e_server import PUBLIC_API_KEY, _fixture_data, fixture_manifest  # noqa: E402


from test_strict_e2e_server import RunningServer  # noqa: E402


# Real public-fixture chrome, sampled by dominant RGB bins without averaging.
# The origin identifies the photo palette underneath each translucent overlay.
PUBLIC_APP_CHROME_SAMPLES = {
    # switch-b-play-2.png, ffafdacdbc9d56bdc45cb2f6ca66b89caa83c56d8732eda7505e7ac64ac5d57b, (477,2164,1163,2245).
    "ipad-glass": ("a", 3, (
        (255, 122, 223), (255, 120, 219), (255, 116, 232), (0, 0, 0),
        (163, 3, 127), (255, 123, 222), (164, 3, 128), (255, 129, 252),
        (141, 2, 108), (43, 20, 39), (192, 93, 168), (219, 100, 198),
        (223, 60, 185), (119, 2, 87), (66, 30, 60), (171, 78, 155))),
    # switch-b-play-1.png, 3a9f1302c0c4e5da8665d94460c322c3c48ab6cc4d1461632dd1ea80f400c142, (884,60,1580,442).
    "ipad-exif": ("b", 7, (
        (255, 133, 244), (255, 255, 255), (232, 121, 222), (236, 123, 226),
        (223, 116, 213), (255, 207, 254), (185, 51, 144), (233, 166, 227),
        (229, 141, 221), (187, 98, 187), (223, 140, 223), (233, 95, 233),
        (229, 164, 223), (221, 84, 184), (234, 95, 197), (226, 90, 191))),
    # server-switch-a-play-1.png, cc34b34054eb297817ad847fe0adad24df66773a35ff20866bcadecce4824de2, (68,2126,1102,2314).
    "iphone-glass": ("a", 1, (
        (0, 0, 0), (37, 109, 19), (91, 61, 91), (255, 255, 255),
        (27, 86, 14), (183, 166, 182), (155, 187, 146), (226, 239, 222),
        (174, 192, 167), (139, 189, 126), (156, 207, 143), (142, 200, 127),
        (165, 211, 153), (160, 179, 152), (223, 238, 219), (192, 223, 184))),
    # switch-b-play-1.png, 4a43319ef30e268941c2dbe81096629c2805f206a293c8bb0f7dbd1c476060fa, (329,186,1130,591).
    "iphone-exif": ("b", 7, (
        (152, 57, 255), (255, 255, 255), (226, 62, 160), (223, 61, 158),
        (233, 64, 165), (224, 62, 159), (133, 50, 223), (255, 147, 255),
        (255, 180, 255), (254, 121, 239), (161, 63, 255), (164, 65, 255),
        (251, 83, 194), (120, 30, 245), (46, 5, 166), (83, 18, 205))),
    # TV server-switch-a-play-1.png, e5a20b2cc56c32612c4a32a449ad32ebf66bb1b351304f6aa5e795dbc7af205a.
    # Entry hint (1332,1440,2080,1648); focus glass (1256,1716,2580,1925); EXIF (2930,62,3620,442).
    "tv-entry-hint": ("a", 1, (
        (252, 251, 252), (90, 55, 90), (31, 112, 9), (96, 62, 96),
        (34, 114, 13), (98, 64, 98), (95, 77, 95), (96, 62, 95),
        (177, 177, 177), (95, 62, 96), (30, 88, 15), (127, 102, 127),
        (192, 192, 191), (193, 193, 192), (193, 191, 191), (216, 229, 212))),
    "tv-focus-glass": ("a", 1, (
        (255, 255, 255), (109, 79, 109), (68, 132, 52), (58, 131, 39),
        (55, 125, 37), (213, 213, 213), (0, 0, 0), (35, 103, 18),
        (78, 52, 78), (32, 95, 17), (65, 126, 50), (130, 88, 130),
        (172, 102, 172), (157, 97, 157), (208, 123, 208), (105, 149, 94))),
    "tv-exif": ("a", 1, (
        (113, 82, 113), (255, 255, 255), (58, 131, 39), (52, 118, 35),
        (91, 61, 91), (37, 109, 19), (129, 88, 129), (95, 69, 95),
        (162, 100, 162), (155, 99, 155), (50, 149, 24), (160, 144, 160),
        (41, 169, 7), (29, 195, 0), (156, 139, 156), (126, 104, 126))),
    # display-after.png, a393b61561f17328c4dde1d718376f73a2a665a2d39a4d850c5d8acb19daa009, (543,2330,1097,2349).
    "home-indicator": (None, None, (
        (84, 62, 91), (88, 62, 97), (136, 74, 156), (127, 69, 144),
        (100, 65, 111), (94, 64, 104), (96, 63, 106))),
}


def _fixture_png(label: str, fixture_set: str = "a") -> bytes:
    return _fixture_data(fixture_set)["images"][f"asset-{fixture_set}-{label[-1]}"]


def _side_by_side(first_png: bytes, second_png: bytes) -> bytes:
    with Image.open(io.BytesIO(first_png)) as first, Image.open(io.BytesIO(second_png)) as second:
        first_rgb = first.convert("RGB").resize((160, 568))
        second_rgb = second.convert("RGB").resize((160, 568))
        scene = Image.new("RGB", (320, 568))
        scene.paste(first_rgb, (0, 0))
        scene.paste(second_rgb, (160, 0))
        buffer = io.BytesIO()
        scene.save(buffer, format="PNG")
        return buffer.getvalue()


def _full_frame_transition(first_png: bytes, second_png: bytes) -> bytes:
    with Image.open(io.BytesIO(first_png)) as first, Image.open(io.BytesIO(second_png)) as second:
        first_rgb = first.convert("RGB").resize((320, 568))
        second_rgb = second.convert("RGB").resize((320, 568))
        blend = Image.blend(first_rgb, second_rgb, 0.5)
        buffer = io.BytesIO()
        blend.save(buffer, format="PNG")
        return buffer.getvalue()


def _solid_png(color: tuple[int, int, int]) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (320, 568), color).save(buffer, format="PNG")
    return buffer.getvalue()


def _write_person_suite(
    evidence: Path,
    *,
    conflict: list[str],
    fixture_set: str = "a",
) -> None:
    write_member_manifest(evidence / "member-manifest.json", fixture_set)
    (evidence / "person-normal.png").write_bytes(_fixture_png("A1", fixture_set))
    for index, label in enumerate(conflict):
        name = "person-conflict-normal.png" if index == 0 else f"person-conflict-normal-{index + 1}.png"
        (evidence / name).write_bytes(_fixture_png(label, fixture_set))
    (evidence / "person-no-faces.png").write_bytes(_fixture_png("A4", fixture_set))
    payload = {"environment": "simulator", "vision_available": False}
    (evidence / "vision-environment.json").write_text(json.dumps(payload), encoding="utf-8")


def _write_switch_display_bridge(
    evidence: Path,
    *,
    screenshot: bytes | None = None,
    setting_source: str = "accessibility_ui",
    mode_after: str = "singlePhoto",
    process_id_after: int = 44,
) -> None:
    (evidence / "switch-b-single-after.png").write_bytes(
        _fixture_png("A1", "b") if screenshot is None else screenshot
    )
    (evidence / "display-policy-after-switch.json").write_text(
        json.dumps(
            {
                "identity_source": "public_fixture_photo_mark",
                "setting_source": setting_source,
                "mode_after": mode_after,
                "process_id_before": 44,
                "process_id_after": process_id_after,
            }
        ),
        encoding="utf-8",
    )
