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
) -> None:
    (evidence / "person-normal.png").write_bytes(_fixture_png("A1"))
    for index, label in enumerate(conflict):
        name = "person-conflict-normal.png" if index == 0 else f"person-conflict-normal-{index + 1}.png"
        (evidence / name).write_bytes(_fixture_png(label))
    (evidence / "person-no-faces.png").write_bytes(_fixture_png("A4"))
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
