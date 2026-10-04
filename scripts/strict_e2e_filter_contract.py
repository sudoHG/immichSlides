#!/usr/bin/env python3
"""Shared filter contract.

Member labels must be checked against classify_screenshot; the final pool is the union of the per-object sets.
"""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping, Sequence

from strict_e2e_photo_identity import MARKS, classify_public_pattern, classify_screenshot, public_letter_from_bytes
from strict_e2e_server import PUBLIC_API_KEY, _fixture_data, fixture_manifest, public_visual_label

from strict_e2e_filter_manifest import (
    FROZEN_FIXTURE_SHA256,
    START_PLAYBACK_BUTTON_ID,
    MEMBER_MANIFEST_KIND,
    ALLOWED_IDENTITY_SOURCES,
    FILTER_VISUAL_SUITES,
    FILTER_ALBUM_STEPS,
    FILTER_PERSON_STEPS,
    FILTER_SWITCH_STEPS,
    FILTER_EDIT_SWITCH_STEPS,
    DISPLAY_REGION_BOXES,
    DISPLAY_REGION_PAIRS,
    DISPLAY_POLICY_CANDIDATE_PREFIX,
    REQUEST_LOG_LINE,
    FilterContractError,
    DISPLAY_MINIMUM_SURROUND_FRACTION,
    DISPLAY_REFERENCE_SAMPLE_PIXELS,
    DISPLAY_FOREGROUND_CHANNEL_TOLERANCE,
    DISPLAY_MINIMUM_FOREGROUND_MATCH_RATIO,
    DISPLAY_SURROUND_SAMPLE_WIDTH_PIXELS,
    DISPLAY_MINIMUM_SAMPLE_HEIGHT_PIXELS,
    DISPLAY_UI_WHITE_CHANNEL_THRESHOLD,
    DISPLAY_UI_BLACK_CHANNEL_THRESHOLD,
    DISPLAY_UI_INK_DILATION_PIXELS,
    DISPLAY_PUBLIC_COLOR_CHANNEL_TOLERANCE,
    DISPLAY_FOREGROUND_PADDING_PIXELS,
    DISPLAY_TEXTURE_EDGE_CHANNEL_DELTA,
    DISPLAY_TEXTURE_CELL_PIXELS,
    DISPLAY_COLOR_EDGE_CHANNEL_DELTA,
    DISPLAY_SHARP_COLOR_EDGE_LIMIT,
    DISPLAY_TEXTURE_AXIS_EDGE_LIMIT,
    DISPLAY_TEXTURE_BOTH_AXES_EDGE_LIMIT,
    DISPLAY_BACKGROUND_BLUR_FRACTIONS,
    DISPLAY_BACKGROUND_SAMPLE_STRIDE_PIXELS,
    DISPLAY_BACKGROUND_CHROMA_TOLERANCE,
    DISPLAY_MINIMUM_BACKGROUND_MATCH_RATIO,
    DISPLAY_MINIMUM_REGION_IMAGE_PIXELS,
    _labels_for,
    _asset_includes_person,
    _solo_only_qualified,
    _set_entry,
    _object_sets,
    _person_filter_items,
    _unique_extend,
    _classified_mark,
    _album_label_pairs,
    _assert_labels_match_photo_identity,
    member_manifest,
    write_member_manifest,
    load_member_manifest,
    require_photo_mark,
    assert_playback_marks_in_target,
    selection_is_empty,
    assert_empty_selection_cannot_start,
    assert_solo_only_not_vacuous,
    assert_foreign_server_ids_absent,
)



ALBUM_PLAYBACK_STEPS = ("album-playback-1", "album-playback-2", "album-playback-3")


def _read_json_object(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        raise FilterContractError(f"missing {label}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FilterContractError(f"{label} is unreadable: {error}") from error
    if not isinstance(payload, dict):
        raise FilterContractError(f"{label} is not an object")
    return payload


def _classify_named_png(evidence_dir: Path, name: str) -> Any:
    path = evidence_dir / f"{name}.png"
    if not path.is_file():
        raise FilterContractError(f"Missing visual input {name}.png")
    try:
        payload = path.read_bytes()
    except OSError as error:
        raise FilterContractError(f"cannot read visual input {name}.png: {error}") from error
    return classify_screenshot(payload)


def album_selection_labels(fixture_set: str, album_id: str) -> list[str]:
    albums = member_manifest(fixture_set)["object_sets"]["albums"]
    if album_id not in albums:
        raise FilterContractError(f"unknown album: {album_id}")
    return list(albums[album_id]["labels"])


def person_selection_labels(fixture_set: str, person_id: str, mode: str) -> list[str]:
    people = member_manifest(fixture_set)["object_sets"]["people"]
    person = people.get(person_id)
    if not isinstance(person, Mapping) or mode not in person:
        raise FilterContractError(f"unknown person or mode: {person_id} {mode}")
    return list(person[mode]["labels"])


def union_selection_labels(
    fixture_set: str,
    album_ids: Sequence[str],
    person_filters: Sequence[object],
) -> list[str]:
    labels: list[str] = []
    for album_id in album_ids:
        _unique_extend(labels, album_selection_labels(fixture_set, album_id))
    for person_id, mode in _person_filter_items(person_filters):
        _unique_extend(labels, person_selection_labels(fixture_set, person_id, mode))
    return labels


def assert_playback_marks_in_union(
    marks: Sequence[str],
    fixture_set: str,
    album_ids: Sequence[str],
    person_filters: Sequence[object],
    *,
    allow_repeats: bool = True,
) -> None:
    if not marks:
        raise FilterContractError("Empty playback membership cannot count as passing")
    if not allow_repeats and len(marks) != len(set(marks)):
        raise FilterContractError("Repeated members cannot count as passing")
    allowed = set(union_selection_labels(fixture_set, album_ids, person_filters))
    wrong = [mark for mark in marks if mark not in allowed]
    if wrong:
        raise FilterContractError("Members outside the selection union cannot count as passing: " + ", ".join(wrong))


def assert_final_pool_equals_union(
    marks: Sequence[str],
    fixture_set: str,
    album_ids: Sequence[str],
    person_filters: Sequence[object],
) -> None:
    if len(marks) != len(set(marks)):
        raise FilterContractError("Repeated members cannot count as passing")
    expected = set(union_selection_labels(fixture_set, album_ids, person_filters))
    observed = set(marks)
    wrong = sorted(observed - expected)
    if wrong:
        raise FilterContractError("Members outside the selection union cannot count as passing: " + ", ".join(wrong))
    missing = sorted(expected - observed)
    if missing:
        raise FilterContractError("Missing selection-union members cannot count as passing: " + ", ".join(missing))


def _person_conflict_normal_paths(evidence_dir: Path) -> list[Path]:
    first = evidence_dir / "person-conflict-normal.png"
    if not first.is_file():
        raise FilterContractError("missing visual input person-conflict-normal.png")
    numbered: list[tuple[int, Path]] = []
    for path in evidence_dir.glob("person-conflict-normal-*.png"):
        if not path.is_file():
            continue
        suffix = path.stem.removeprefix("person-conflict-normal-")
        if suffix.isdigit():
            numbered.append((int(suffix), path))
    numbered.sort()
    return [first, *(path for _, path in numbered)]


def _classify_person_conflict_normal(evidence_dir: Path) -> tuple[Any, list[str]]:
    # This suite selects only person-a-solo in normal mode; the allowed set comes from that person's own set,
    # so a missing A2 must not fail it.
    person_id = member_manifest("a")["person_cases"]["normal_plus_solo_conflict"]["person_id"]
    paths = _person_conflict_normal_paths(evidence_dir)
    identities = []
    marks: list[str] = []
    for path in paths:
        identity = _classify_named_png(evidence_dir, path.stem)
        marks.append(
            require_photo_mark("public_fixture_photo_mark", identity.status, identity.mark)
        )
        identities.append(identity)
    assert_playback_marks_in_union(
        marks,
        "a",
        [],
        [{"person_id": person_id, "mode": "normal"}],
        allow_repeats=True,
    )
    return identities[0], marks


@lru_cache(maxsize=1)
def _display_reference_photos() -> tuple[bytes, ...]:
    return tuple(image for name in ("a", "b") for image in _fixture_data(name)["images"].values())


@lru_cache(maxsize=8)
def _display_foreground_png(image_bytes: bytes) -> bytes:
    # Exclude the surround from the photo regions only when both the full public original
    # and its blurred surround match.
    import io
    from PIL import Image, ImageFilter, ImageOps

    with Image.open(io.BytesIO(image_bytes)) as image:
        rgb = image.convert("RGB")
        width, height = rgb.size
        for reference_bytes in _display_reference_photos():
            with Image.open(io.BytesIO(reference_bytes)) as reference:
                reference = reference.convert("RGB")
                scale = min(width / reference.width, height / reference.height)
                fit_width, fit_height = round(reference.width * scale), round(reference.height * scale)
                left, top = (width - fit_width) // 2, (height - fit_height) // 2
                if max(left, top) < min(width, height) * DISPLAY_MINIMUM_SURROUND_FRACTION:
                    continue
                foreground = rgb.crop((left, top, left + fit_width, top + fit_height))
                observed = list(foreground.resize((DISPLAY_REFERENCE_SAMPLE_PIXELS, DISPLAY_REFERENCE_SAMPLE_PIXELS)).getdata())
                expected = list(reference.resize((DISPLAY_REFERENCE_SAMPLE_PIXELS, DISPLAY_REFERENCE_SAMPLE_PIXELS)).getdata())
                matched = sum(max(abs(a[c] - b[c]) for c in range(3)) <= DISPLAY_FOREGROUND_CHANNEL_TOLERANCE for a, b in zip(observed, expected))
                if matched / len(expected) < DISPLAY_MINIMUM_FOREGROUND_MATCH_RATIO:
                    continue
                outer_boxes = (
                    ((0, 0, width, top), (0, top + fit_height, width, height))
                    if top else ((0, 0, left, height), (left + fit_width, 0, width, height))
                )
                for box in outer_boxes:
                    buffer = io.BytesIO()
                    rgb.crop(box).save(buffer, format="PNG")
                    if public_letter_from_bytes(buffer.getvalue()) is not None:
                        raise FilterContractError("single-photo surround still shows a sharp public photo mark; a second photo cannot count as background")
                sample_size = (DISPLAY_SURROUND_SAMPLE_WIDTH_PIXELS, max(DISPLAY_MINIMUM_SAMPLE_HEIGHT_PIXELS, round(height * DISPLAY_SURROUND_SAMPLE_WIDTH_PIXELS / width)))
                sample = rgb.resize(sample_size)
                pixels = sample.load()
                ui_ink = Image.new("L", sample_size)
                ui_ink.putdata([255 if min(pixel) > DISPLAY_UI_WHITE_CHANNEL_THRESHOLD or max(pixel) < DISPLAY_UI_BLACK_CHANNEL_THRESHOLD else 0 for pixel in sample.getdata()])
                ui_ink_pixels = ui_ink.filter(ImageFilter.MaxFilter(DISPLAY_UI_INK_DILATION_PIXELS)).load()
                palette = tuple(
                    ((seed * 37 + block * 54) % 180,
                     (seed * 61 + (1 - block) * 48) % 180,
                     (seed * 19 + block * 72) % 180)
                    for seed in range(1, 6) for block in (0, 1)
                )

                def is_public_color(pixel: tuple[int, ...]) -> bool:
                    return any(max(abs(pixel[c] - color[c]) for c in range(3)) <= DISPLAY_PUBLIC_COLOR_CHANNEL_TOLERANCE for color in palette)

                sharp_edges = 0
                texture_cells: dict[tuple[int, int], list[int]] = {}
                padding = width * DISPLAY_FOREGROUND_PADDING_PIXELS / sample.width
                for y in range(0, sample.height - 2):
                    for x in range(0, sample.width - 2):
                        original_x, original_y = x * width / sample.width, y * height / sample.height
                        if left - padding <= original_x <= left + fit_width + padding and top - padding <= original_y <= top + fit_height + padding:
                            continue
                        pixel = pixels[x, y]
                        for direction, (nx, ny) in enumerate(((x + 2, y), (x, y + 2))):
                            neighbor = pixels[nx, ny]
                            difference = max(abs(pixel[c] - neighbor[c]) for c in range(3))
                            if not ui_ink_pixels[x, y] and not ui_ink_pixels[nx, ny] and difference > DISPLAY_TEXTURE_EDGE_CHANNEL_DELTA:
                                texture_cells.setdefault((x // DISPLAY_TEXTURE_CELL_PIXELS, y // DISPLAY_TEXTURE_CELL_PIXELS), [0, 0])[direction] += 1
                            if is_public_color(pixel) and is_public_color(neighbor) and difference > DISPLAY_COLOR_EDGE_CHANNEL_DELTA:
                                sharp_edges += 1
                if sharp_edges >= DISPLAY_SHARP_COLOR_EDGE_LIMIT:
                    raise FilterContractError("single-photo surround still has sharp public photo color-block edges; it cannot count as a blurred background")
                if any(max(edges) >= DISPLAY_TEXTURE_AXIS_EDGE_LIMIT or min(edges) >= DISPLAY_TEXTURE_BOTH_AXES_EDGE_LIMIT for edges in texture_cells.values()):
                    raise FilterContractError("single-photo surround still has unexplained sharp texture; it cannot be cropped away as blurred background")
                best_background_score = 0.0
                for blur_fraction in DISPLAY_BACKGROUND_BLUR_FRACTIONS:
                    background = ImageOps.fit(reference, sample_size).filter(ImageFilter.GaussianBlur(DISPLAY_SURROUND_SAMPLE_WIDTH_PIXELS * blur_fraction))
                    background_pixels = background.load()
                    hits = total = 0
                    for y in range(0, sample.height, DISPLAY_BACKGROUND_SAMPLE_STRIDE_PIXELS):
                        for x in range(0, sample.width, DISPLAY_BACKGROUND_SAMPLE_STRIDE_PIXELS):
                            original_x, original_y = x * width / sample.width, y * height / sample.height
                            if left - DISPLAY_FOREGROUND_PADDING_PIXELS <= original_x <= left + fit_width + DISPLAY_FOREGROUND_PADDING_PIXELS and top - DISPLAY_FOREGROUND_PADDING_PIXELS <= original_y <= top + fit_height + DISPLAY_FOREGROUND_PADDING_PIXELS:
                                continue
                            actual, predicted = pixels[x, y], background_pixels[x, y]
                            if min(actual) > DISPLAY_UI_WHITE_CHANNEL_THRESHOLD:
                                continue
                            total += 1
                            hits += max(
                                abs(255 * actual[c] / max(1, sum(actual)) - 255 * predicted[c] / max(1, sum(predicted)))
                                for c in range(3)
                            ) <= DISPLAY_BACKGROUND_CHROMA_TOLERANCE
                    best_background_score = max(best_background_score, hits / max(1, total))
                if best_background_score < DISPLAY_MINIMUM_BACKGROUND_MATCH_RATIO:
                    raise FilterContractError("single-photo surround does not match this photo's blurred background; multi-photo or unknown-frame risk remains")
                buffer = io.BytesIO()
                foreground.save(buffer, format="PNG")
                return buffer.getvalue()
    return image_bytes


def _classify_display_regions(image_bytes: bytes) -> dict[str, Any]:
    try:
        from PIL import Image
        import io

        with Image.open(io.BytesIO(_display_foreground_png(image_bytes))) as image:
            rgb = image.convert("RGB")
            width, height = rgb.size
            if width < DISPLAY_MINIMUM_REGION_IMAGE_PIXELS or height < DISPLAY_MINIMUM_REGION_IMAGE_PIXELS:
                raise FilterContractError("display-policy screenshot is too small to check photo regions")
            regions: dict[str, Any] = {}
            for name, (left, top, right, bottom) in DISPLAY_REGION_BOXES.items():
                crop = rgb.crop(
                    (
                        int(width * left),
                        int(height * top),
                        max(int(width * left) + 1, int(width * right)),
                        max(int(height * top) + 1, int(height * bottom)),
                    )
                )
                buffer = io.BytesIO()
                crop.save(buffer, format="PNG")
                regions[name] = classify_screenshot(buffer.getvalue())
    except FilterContractError:
        raise
    except Exception as error:
        raise FilterContractError(f"display-policy screenshot regions cannot be classified: {type(error).__name__}") from error

    return regions


def _display_region_marks(regions: Mapping[str, Any]) -> list[str]:
    def mark(name: str) -> str | None:
        identity = regions.get(name)
        return identity.mark if identity is not None and identity.status == "MATCH" else None

    distinct: list[str] = []

    def add(value: str | None) -> None:
        if value is not None and value not in distinct:
            distinct.append(value)

    for first_name, second_name in DISPLAY_REGION_PAIRS:
        first = mark(first_name)
        second = mark(second_name)
        if first is not None and second is not None and first != second:
            add(first)
            add(second)

    top_half = mark("top_half")
    bottom_half = mark("bottom_half")
    center = mark("center")
    top = mark("top")
    real_stacked_halves = top is not None and top == top_half
    if top_half is not None and bottom_half is not None and top_half != bottom_half:
        if center != bottom_half or real_stacked_halves:
            add(top_half)
            add(bottom_half)
    return distinct


def _distinct_display_region_marks(image_bytes: bytes) -> list[str]:
    return _display_region_marks(_classify_display_regions(image_bytes))


def assert_foreign_id_tokens_absent(texts: Sequence[str], local_fixture_set: str) -> None:
    foreign_set = "b" if local_fixture_set == "a" else "a"
    foreign = member_manifest(foreign_set)
    tokens = list(foreign["all_asset_ids"]) + list(foreign["all_album_ids"]) + list(foreign["all_person_ids"])
    blob = "\n".join(str(item) for item in texts)
    found = [token for token in tokens if token in blob]
    if found:
        raise FilterContractError("Cross-server stale IDs remain: " + ", ".join(found))


def evaluate_filter_visual_identity(evidence_dir: Path, suite: str) -> dict[str, Any]:
    if suite in {"display-policy", "tvos-display-policy"}:
        return _evaluate_display_policy(evidence_dir, suite)
    if suite == "tvos-album":
        return _evaluate_tvos_album(evidence_dir)
    if suite == "tvos-person":
        return _evaluate_tvos_person(evidence_dir)
    if suite == "tvos-switch":
        return _evaluate_tvos_switch(evidence_dir)
    if suite == "filter-album":
        return _evaluate_filter_album(evidence_dir)
    if suite in {"filter-edit-switch", "tvos-edit-switch"}:
        return _evaluate_filter_edit_switch(evidence_dir, suite)
    if suite == "filter-empty":
        return _evaluate_filter_empty(evidence_dir)
    if suite == "filter-person":
        return _evaluate_filter_person(evidence_dir)
    if suite == "filter-switch":
        return _evaluate_filter_switch(evidence_dir)
    if suite == "filter-vision":
        return _evaluate_filter_vision(evidence_dir)
    raise FilterContractError(f"unknown filter visual suite: {suite}")


def _require_same_process(payload: Mapping[str, Any], label: str) -> int:
    before = payload.get("process_id_before")
    after = payload.get("process_id_after")
    if (
        not isinstance(before, int)
        or isinstance(before, bool)
        or before <= 0
        or not isinstance(after, int)
        or isinstance(after, bool)
        or after != before
    ):
        raise FilterContractError(f"{label} must prove the same App process remained alive before and after settings")
    return before


def _display_photo_identity(image_bytes: bytes, *, fixture_set: str, labels: Sequence[str], label: str) -> str:
    image_bytes = _display_foreground_png(image_bytes)
    identity = classify_screenshot(image_bytes)
    if identity.status != "MATCH" or identity.mark not in MARKS:
        raise FilterContractError(f"{label} cannot use a transition or unknown frame as passing")
    mark = require_photo_mark("public_fixture_photo_mark", identity.status, identity.mark)
    if mark not in labels or classify_public_pattern(image_bytes) != fixture_set:
        raise FilterContractError(f"{label} frame must contain only target album photos from fixture {fixture_set.upper()}")
    return mark


def _evaluate_display_policy(evidence_dir: Path, suite: str) -> dict[str, Any]:
    manifest = load_member_manifest(evidence_dir / "member-manifest.json")
    fixture_set = str(manifest["fixture_set"])
    if fixture_set != "a":
        raise FilterContractError("standalone display-policy suite must use fixture A only")
    allowed = manifest["target_album"]["labels"]
    visual_labels = manifest["target_album"]["visual_labels"]
    payload = _read_json_object(evidence_dir / "display-policy.json", "display-policy.json")
    if payload.get("identity_source") != "public_fixture_photo_mark":
        raise FilterContractError("display-policy screenshot identity must come from public fixture photo marks")
    if payload.get("setting_source") != "accessibility_ui":
        raise FilterContractError("Display strategy must be set through the real UI")
    if payload.get("mode_before") != "smartFill" or payload.get("mode_after") != "singlePhoto":
        raise FilterContractError("display policy must change from SmartFill to single-photo mode")
    process_id = _require_same_process(payload, "display strategy run evidence")

    candidate_steps = payload.get("before_candidate_steps")
    if not isinstance(candidate_steps, list) or not candidate_steps:
        raise FilterContractError("missing the finite list of before-change candidate screenshots")
    maximum_candidates = len(visual_labels) + 1
    if len(candidate_steps) > maximum_candidates:
        raise FilterContractError("Before-change screenshot candidates exceed one complete finite rotation of the target album")
    expected_steps = [
        f"{DISPLAY_POLICY_CANDIDATE_PREFIX}{index:02d}"
        for index in range(1, len(candidate_steps) + 1)
    ]
    if candidate_steps != expected_steps:
        raise FilterContractError("before-change candidate screenshots must be numbered consecutively in real order")

    candidate_marks: list[list[str]] = []
    candidate_bytes: list[bytes] = []
    candidate_regions: list[dict[str, Any]] = []
    for step in candidate_steps:
        path = evidence_dir / f"{step}.png"
        if not path.is_file():
            raise FilterContractError(f"missing raw candidate screenshot {step}.png")
        image_bytes = path.read_bytes()
        candidate_bytes.append(image_bytes)
        regions = _classify_display_regions(image_bytes)
        region_marks = _display_region_marks(regions)
        if region_marks:
            for mark in region_marks:
                if mark not in allowed:
                    raise FilterContractError(f"before-change multi-photo frame contains a photo outside the target album: {mark}")
            if classify_public_pattern(image_bytes) not in (None, fixture_set):
                raise FilterContractError(f"before-change multi-photo frame must not mix in another server fixture: {step}")
        candidate_marks.append(region_marks)
        candidate_regions.append(regions)

    selected_step = payload.get("selected_before_step")
    if selected_step != candidate_steps[-1]:
        raise FilterContractError("must use the first candidate screenshot in the finite rotation that meets the before-change multi-photo condition")
    if any(len(marks) >= 2 for marks in candidate_marks[:-1]):
        raise FilterContractError("found extra candidate screenshots after the first one that met the condition")
    before_path = evidence_dir / "display-before.png"
    if not before_path.is_file() or before_path.read_bytes() != candidate_bytes[-1]:
        raise FilterContractError("display-before.png must keep the raw screenshot of the first valid candidate")
    before_marks = candidate_marks[-1]
    if len(before_marks) < 2:
        before_identity = classify_screenshot(candidate_bytes[-1])
        if before_identity.status == "UNRECOGNIZABLE":
            raise FilterContractError("The before-change frame must be recognizable as a public fixture photo")
        if before_identity.status == "TRANSITION" or any(
            identity.status == "TRANSITION" for identity in candidate_regions[-1].values()
        ):
            raise FilterContractError("Multiple before-change photos cannot be faked by a transition")
        raise FilterContractError("The before-change frame must actually show at least two different photos")
    if classify_public_pattern(candidate_bytes[-1]) != fixture_set:
        raise FilterContractError("The before-change frame must contain only fixture A; do not mix fixtures A and B or unknown content")

    after_bytes = (evidence_dir / "display-after.png").read_bytes() if (evidence_dir / "display-after.png").is_file() else b""
    after_mark = _display_photo_identity(
        after_bytes,
        fixture_set=fixture_set,
        labels=allowed,
        label="after-change",
    )
    after_regions = _classify_display_regions(after_bytes)
    stable_regions = [
        after_regions[name]
        for name in ("center", "left", "right", "mid_left", "mid_right", "upper")
    ]
    if any(identity.status == "TRANSITION" for identity in stable_regions):
        raise FilterContractError("after-change cannot use a transition or unknown frame as passing: the stable photo region is still transitioning")
    for identity in stable_regions:
        if identity.status != "MATCH" or identity.mark != after_mark:
            raise FilterContractError("The after-change frame must be a recognizable, stable single-photo frame")
    after_marks = _display_region_marks(after_regions)
    if len(after_marks) >= 2:
        raise FilterContractError("after-change frame must be a recognizable single-photo frame")
    return {
        "verdict": "PASS",
        "suite": suite,
        "identity_source": "public_fixture_photo_mark",
        "setting_source": "accessibility_ui",
        "fixture_set": fixture_set,
        "process_id": process_id,
        "before_marks": before_marks,
        "after_mark": after_mark,
        "before_candidate_steps": candidate_steps,
    }


def _step_payload(name: str, identity: Any) -> dict[str, Any]:
    return {
        "name": name,
        "status": identity.status,
        "mark": identity.mark,
        "mean_luma": identity.mean_luma,
        "notes": list(identity.notes),
    }


def _evaluate_tvos_album(evidence_dir: Path) -> dict[str, Any]:
    identities = [_classify_named_png(evidence_dir, name) for name in ALBUM_PLAYBACK_STEPS]
    marks = [
        require_photo_mark("public_fixture_photo_mark", identity.status, identity.mark)
        for identity in identities
    ]
    assert_playback_marks_in_target(marks, "a")
    selection = _read_json_object(evidence_dir / "empty-selection.json", "empty-selection.json")
    if selection.get("identity_source") not in (None, "public_fixture_photo_mark"):
        raise FilterContractError("Request logs, indexes, and probes cannot be used as identity truth")
    start_enabled = selection.get("start_enabled")
    if not isinstance(start_enabled, bool):
        raise FilterContractError("empty-selection.json start_enabled must be a Boolean")
    assert_empty_selection_cannot_start(
        album_ids=list(selection.get("album_ids") or []),
        person_filters=list(selection.get("person_filters") or []),
        start_enabled=start_enabled,
    )
    return {
        "verdict": "PASS",
        "suite": "tvos-album",
        "identity_source": "public_fixture_photo_mark",
        "marks": marks,
        "steps": {
            name: _step_payload(name, identity)
            for name, identity in zip(ALBUM_PLAYBACK_STEPS, identities)
        },
    }


def _evaluate_tvos_person(evidence_dir: Path) -> dict[str, Any]:
    cases = member_manifest("a")["person_cases"]
    normal = _classify_named_png(evidence_dir, "person-normal")
    normal_mark = require_photo_mark("public_fixture_photo_mark", normal.status, normal.mark)
    if normal_mark not in set(cases["normal_match"]["labels"]):
        raise FilterContractError(f"wrong member cannot count as a pass: {normal_mark}")

    conflict_normal, conflict_marks = _classify_person_conflict_normal(evidence_dir)

    no_faces = _classify_named_png(evidence_dir, "person-no-faces")
    no_faces_mark = require_photo_mark("public_fixture_photo_mark", no_faces.status, no_faces.mark)
    if no_faces_mark not in set(cases["no_faces"]["labels"]):
        raise FilterContractError(f"wrong member cannot count as a pass: {no_faces_mark}")

    vision = _read_json_object(evidence_dir / "vision-environment.json", "vision-environment.json")
    if vision.get("wins") is not None:
        raise FilterContractError("wins is not a product filter outcome")
    if vision.get("environment") == "device" and vision.get("vision_available") is True:
        raise FilterContractError("Simulator Vision cannot substitute for a device; soloOnly must not be marked PASS")
    if (evidence_dir / "solo-only-pass.json").is_file():
        raise FilterContractError("Simulator Vision cannot substitute for a device; soloOnly must not be marked PASS")

    conflict_step = _step_payload("person-conflict-normal", conflict_normal)
    conflict_step["marks"] = conflict_marks
    steps = {
        "person-normal": _step_payload("person-normal", normal),
        "person-conflict-normal": conflict_step,
        "person-no-faces": _step_payload("person-no-faces", no_faces),
    }
    for name in ("person-solo", "person-conflict-solo"):
        path = evidence_dir / f"{name}.png"
        if not path.is_file():
            continue
        identity = classify_screenshot(path.read_bytes())
        payload = _step_payload(name, identity)
        payload["verdict"] = "UNVERIFIED"
        steps[name] = payload

    return {
        "verdict": "PARTIAL",
        "suite": "tvos-person",
        "identity_source": "public_fixture_photo_mark",
        "vision": {
            "verdict": "UNVERIFIED",
            "environment": vision.get("environment"),
            "reason": "Simulator Vision cannot substitute for a device; soloOnly must not be marked PASS",
        },
        "steps": steps,
    }


def _evaluate_tvos_switch(evidence_dir: Path) -> dict[str, Any]:
    manifest_b = load_member_manifest(evidence_dir / "member-manifest-b.json")
    identity = _classify_named_png(evidence_dir, "switch-b-playback")
    mark = require_photo_mark("public_fixture_photo_mark", identity.status, identity.mark)
    assert_playback_marks_in_target([mark], "b")
    observed = _read_json_object(evidence_dir / "observed-ids-after-switch.json", "observed-ids-after-switch.json")
    if observed.get("identity_source") not in (None, "ui_accessibility_identifier"):
        raise FilterContractError("Request logs, indexes, and probes cannot be used as identity truth")
    texts = list(observed.get("ids") or []) + list(observed.get("raw_identifiers") or [])
    log_path = evidence_dir / "service-b.log"
    if log_path.is_file():
        texts.append(log_path.read_text(encoding="utf-8"))
    assert_foreign_id_tokens_absent(texts, "b")
    after_switch = _read_json_object(
        evidence_dir / "empty-selection-after-switch.json",
        "empty-selection-after-switch.json",
    )
    if after_switch.get("start_enabled") is True:
        raise FilterContractError("An empty selection cannot start playback")
    if after_switch.get("selection_source") != "accessibility_ui":
        raise FilterContractError("empty selection after server switch must come from the actual filter editor")
    for field, unit in (("album_summary", "个相册"), ("person_summary", "个人物")):
        summary = after_switch.get(field)
        counts = re.findall(rf"(\d+) {unit} · (\d+) 张照片", summary) if isinstance(summary, str) else []
        if counts != [("0", "0")]:
            raise FilterContractError(f"empty selection after server switch lacks real zero counts or keeps an old selection: {field}")
    bridge = _evaluate_switch_display_policy(evidence_dir, manifest_b)
    return {
        "verdict": "PASS",
        "suite": "tvos-switch",
        "identity_source": "public_fixture_photo_mark",
        "marks": [mark],
        "post_switch_single_photo": bridge,
        "steps": {"switch-b-playback": _step_payload("switch-b-playback", identity)},
    }



def _classified_mark_from_png(evidence_dir: Path, name: str) -> str:
    identity = _classify_named_png(evidence_dir, name)
    return require_photo_mark("public_fixture_photo_mark", identity.status, identity.mark)


def _extract_ids_from_request_log(log_text: str) -> list[str]:
    found: list[str] = []
    for match in re.finditer(r"(asset|album|person)-[ab]-[a-z0-9-]+", log_text):
        found.append(match.group(0))
    return found


def _evaluate_filter_album(evidence_dir: Path) -> dict[str, Any]:
    manifest = load_member_manifest(evidence_dir / "member-manifest.json")
    fixture_set = str(manifest["fixture_set"])
    marks = [_classified_mark_from_png(evidence_dir, name) for name in FILTER_ALBUM_STEPS]
    assert_playback_marks_in_target(marks, fixture_set)
    return {
        "verdict": "PASS",
        "suite": "filter-album",
        "identity_source": "public_fixture_photo_mark",
        "fixture_set": fixture_set,
        "marks": marks,
    }


def _evaluate_filter_edit_switch(evidence_dir: Path, suite: str) -> dict[str, Any]:
    manifest = load_member_manifest(evidence_dir / "member-manifest.json")
    modes = _read_json_object(evidence_dir / "album-edit-modes.json", "album-edit-modes.json")
    if modes.get("identity_source") != "accessibility_ui":
        raise FilterContractError("album replacement identity must come from real UI accessibility identifiers")
    selected_album_id = modes.get("selected_album_id_after_replace")
    expected_album_id = manifest["non_target_album"]["id"]
    if selected_album_id != expected_album_id:
        raise FilterContractError("after replacement, UI identifiers must confirm the non-target album is selected")
    if modes.get("mode_after_replace") != "filtered":
        raise FilterContractError("after switching to the non-target album, the default mode must still be filtered playback")
    if modes.get("mode_after_clear_and_exit") != "random":
        raise FilterContractError("after clearing filters and leaving the editor, the default mode must return to random playback")

    marks = [_classified_mark_from_png(evidence_dir, name) for name in FILTER_EDIT_SWITCH_STEPS]
    allowed = set(manifest["non_target_album"]["visual_labels"])
    if not allowed or not set(marks).issubset(allowed):
        raise FilterContractError(f"frames after the album switch must belong to non-target album {expected_album_id}: {marks}")
    return {
        "verdict": "PASS",
        "suite": suite,
        "identity_source": "public_fixture_photo_mark",
        "selected_album_id_after_replace": selected_album_id,
        "mode_after_replace": "filtered",
        "mode_after_clear_and_exit": "random",
        "marks": marks,
    }


def _evaluate_filter_empty(evidence_dir: Path) -> dict[str, Any]:
    load_member_manifest(evidence_dir / "member-manifest.json")
    payload = _read_json_object(evidence_dir / "empty-selection.json", "empty-selection.json")
    if payload.get("start_button_id") != START_PLAYBACK_BUTTON_ID:
        raise FilterContractError("start button id does not match the frozen contract")
    album_ids = payload.get("album_ids")
    person_filters = payload.get("person_filters")
    start_enabled = payload.get("start_enabled")
    if not isinstance(album_ids, list) or not isinstance(person_filters, list) or not isinstance(start_enabled, bool):
        raise FilterContractError("empty-selection.json fields are incomplete")
    if not all(isinstance(item, str) for item in album_ids):
        raise FilterContractError("empty-selection.json album_ids must contain only strings")
    assert_empty_selection_cannot_start(
        album_ids=album_ids,
        person_filters=person_filters,
        start_enabled=start_enabled,
    )
    return {
        "verdict": "PASS",
        "suite": "filter-empty",
        "start_enabled": start_enabled,
        "start_button_id": START_PLAYBACK_BUTTON_ID,
    }


def _evaluate_filter_person(evidence_dir: Path) -> dict[str, Any]:
    manifest = load_member_manifest(evidence_dir / "member-manifest.json")
    results = _read_json_object(evidence_dir / "person-results.json", "person-results.json")
    if "wins" in results:
        raise FilterContractError("wins is not a product filter outcome and cannot be asserted as a filter result")
    cases = results.get("cases")
    if not isinstance(cases, dict):
        raise FilterContractError("person-results.json is missing cases")

    normal = _classified_mark_from_png(evidence_dir, FILTER_PERSON_STEPS["normal_match"])
    expected_normal = manifest["person_cases"]["normal_match"]["labels"]
    if [normal] != expected_normal:
        raise FilterContractError(f"normal person playback member is not in the manifest: {normal}")

    conflict = _classified_mark_from_png(evidence_dir, FILTER_PERSON_STEPS["conflict_normal"])
    conflict_case = manifest["person_cases"]["normal_plus_solo_conflict"]
    conflict_person_id = conflict_case["person_id"]
    expected_conflict = set(
        manifest["object_sets"]["people"][conflict_person_id]["normal"]["labels"]
    )
    if conflict not in expected_conflict:
        raise FilterContractError(f"conflict person normal selection shows a member outside that person: {conflict}")

    no_faces = _classified_mark_from_png(evidence_dir, FILTER_PERSON_STEPS["no_faces"])
    expected_no_faces = manifest["person_cases"]["no_faces"]["labels"]
    if [no_faces] != expected_no_faces:
        raise FilterContractError(f"no-faces person normal playback member is not in the manifest: {no_faces}")

    solo_case = cases.get("solo_only")
    if not isinstance(solo_case, dict):
        raise FilterContractError("person-results.json is missing solo_only")
    environment = solo_case.get("environment")
    solo_verdict = solo_case.get("verdict")
    if environment != "device" and solo_verdict == "PASS":
        raise FilterContractError("Simulator Vision cannot substitute for a device; soloOnly must not be marked PASS")
    if environment != "device" and solo_verdict not in {"UNVERIFIED", "BLOCKED_ENV"}:
        raise FilterContractError("simulator Vision must fail or be UNVERIFIED")

    return {
        "verdict": "PASS",
        "suite": "filter-person",
        "identity_source": "public_fixture_photo_mark",
        "normal_match": normal,
        "conflict_normal": conflict,
        "no_faces": no_faces,
        "solo_only_verdict": solo_verdict,
        "solo_only_environment": environment,
    }


def _evaluate_filter_switch(evidence_dir: Path) -> dict[str, Any]:
    manifest_b = load_member_manifest(evidence_dir / "member-manifest-b.json")
    load_member_manifest(evidence_dir / "member-manifest-a.json")
    fixture_set = str(manifest_b["fixture_set"])
    marks = [_classified_mark_from_png(evidence_dir, name) for name in FILTER_SWITCH_STEPS]
    assert_playback_marks_in_target(marks, fixture_set)

    observed = _read_json_object(evidence_dir / "observed-ids.json", "observed-ids.json")
    observed_ids = observed.get("ids")
    if not isinstance(observed_ids, list) or any(not isinstance(item, str) for item in observed_ids):
        raise FilterContractError("observed-ids.json ids must be a list of strings")
    assert_foreign_server_ids_absent(observed_ids, fixture_set)

    log_path = evidence_dir / "request-log-b.log"
    if log_path.is_file():
        log_text = log_path.read_text(encoding="utf-8")
        assert_request_log_contract(log_text, forbidden=(PUBLIC_API_KEY, "x-api-key"))
        assert_foreign_server_ids_absent(_extract_ids_from_request_log(log_text), fixture_set)

    bridge = _evaluate_switch_display_policy(evidence_dir, manifest_b)

    return {
        "verdict": "PASS",
        "suite": "filter-switch",
        "identity_source": "public_fixture_photo_mark",
        "fixture_set": fixture_set,
        "marks": marks,
        "post_switch_single_photo": bridge,
    }


def _evaluate_switch_display_policy(
    evidence_dir: Path,
    manifest_b: Mapping[str, Any],
) -> dict[str, Any]:
    payload = _read_json_object(
        evidence_dir / "display-policy-after-switch.json",
        "display-policy-after-switch.json",
    )
    if payload.get("identity_source") != "public_fixture_photo_mark":
        raise FilterContractError("single-photo identity after server switch must come from public fixture photo marks")
    if payload.get("setting_source") != "accessibility_ui" or payload.get("mode_after") != "singlePhoto":
        raise FilterContractError("Single-photo mode must be applied through the real UI after switching servers")
    process_id = _require_same_process(payload, "single-photo run evidence after server switch")
    screenshot_path = evidence_dir / "switch-b-single-after.png"
    image_bytes = screenshot_path.read_bytes() if screenshot_path.is_file() else b""
    mark = _display_photo_identity(
        image_bytes,
        fixture_set="b",
        labels=manifest_b["target_album"]["labels"],
        label="single photo after server switch",
    )
    if len(_distinct_display_region_marks(image_bytes)) >= 2:
        raise FilterContractError("single-photo frame after server switch still shows multiple photos")
    return {"process_id": process_id, "fixture_set": "b", "mark": mark, "mode": "singlePhoto"}


def _evaluate_filter_vision(evidence_dir: Path) -> dict[str, Any]:
    load_member_manifest(evidence_dir / "member-manifest.json")
    payload = _read_json_object(evidence_dir / "vision-environment.json", "vision-environment.json")
    environment = payload.get("environment")
    vision_available = payload.get("vision_available")
    if environment != "device":
        return {
            "verdict": "UNVERIFIED",
            "suite": "filter-vision",
            "environment": environment,
            "reason": "simulator Vision does not replace a real device",
        }
    if not isinstance(vision_available, bool):
        raise FilterContractError("vision-environment.json is missing vision_available")
    qualified = payload.get("qualified_marks")
    face_counts = payload.get("face_counts")
    if not isinstance(qualified, list) or not isinstance(face_counts, dict):
        raise FilterContractError("device Vision is missing qualified_marks / face_counts")
    marks = [item for item in qualified if isinstance(item, str)]
    if not all(isinstance(value, int) and not isinstance(value, bool) for value in face_counts.values()):
        raise FilterContractError("device Vision face_counts must contain only integers")
    counts = {str(key): value for key, value in face_counts.items()}
    mark = _classified_mark_from_png(evidence_dir, "vision-solo-1")
    if mark not in marks:
        raise FilterContractError(f"device Vision screenshot mark is not in qualified_marks: {mark}")
    assert_solo_only_not_vacuous(
        environment="device",
        vision_available=vision_available,
        qualified_marks=marks,
        face_counts=counts,
        fixture_set="a",
    )
    return {
        "verdict": "PASS",
        "suite": "filter-vision",
        "environment": "device",
        "identity_source": "public_fixture_photo_mark",
        "mark": mark,
    }


def assert_request_log_contract(log_text: str, *, forbidden: Sequence[str]) -> None:
    lowered = log_text.lower()
    for item in forbidden:
        if item.lower() in lowered:
            raise FilterContractError(f"request log contains a forbidden field: {item}")
    request_lines = [line for line in log_text.splitlines() if line.startswith("request ")]
    if not request_lines:
        raise FilterContractError("request log has no checkable lines")
    for line in request_lines:
        if REQUEST_LOG_LINE.match(line) is None:
            raise FilterContractError(f"request log format is not frozen: {line}")
