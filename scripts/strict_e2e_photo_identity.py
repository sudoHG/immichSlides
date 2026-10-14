#!/usr/bin/env python3
"""Public fixture identity from pixels; rendered-scene probes corroborate pixel signatures."""

from __future__ import annotations

import functools
import io
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping, Sequence


MARKS = ("A1", "A2", "A3", "A4", "A5")
KEY_COLORS = {
    "A1": frozenset({"green", "purple"}),
    "A2": frozenset({"green", "gray"}),
    "A3": frozenset({"magenta", "brown"}),
    "A4": frozenset({"blue", "brown"}),
    "A5": frozenset({"green", "blue"}),
}
EXPECTED_EXIF_MODEL = {
    "A1": "Fixture 1",
    "A2": None,
    "A3": "Fixture 3",
    "A4": None,
    "A5": "Fixture 5",
}
JOURNEY_B_STEPS = (
    "history-start",
    "history-first-next",
    "history-second-next",
    "history-first-previous",
    "history-second-previous",
)
PAUSE_WINDOW_STEPS = ("after-pause", "after-pause-0_3s")
TVOS_FLOW_STEPS = ("pause-immediate", "pause-after-10s", "resumed")
VISUAL_SUITES = ("journey-b", "pause-window", "tvos-flow", "tvos-album", "tvos-person", "tvos-switch")


IDENTITY_MINIMUM_IMAGE_PIXELS = 8
IDENTITY_SAMPLE_WIDTH_PIXELS = 96
IDENTITY_VISIBLE_HEIGHT_FRACTION = 0.86
IDENTITY_CONTROLS_LEFT_FRACTION = 0.72
IDENTITY_CONTROLS_BOTTOM_FRACTION = 0.22
IDENTITY_MINIMUM_LUMA = 0.035
IDENTITY_MAXIMUM_LUMA = 0.94
IDENTITY_GRAY_SATURATION_THRESHOLD = 0.16
IDENTITY_GREEN_HUE_MIN_DEGREES = 70
IDENTITY_GREEN_HUE_MAX_DEGREES = 170
IDENTITY_BLUE_HUE_MIN_DEGREES = 185
IDENTITY_BLUE_HUE_MAX_DEGREES = 255
IDENTITY_PURPLE_HUE_MIN_DEGREES = 265
IDENTITY_PURPLE_HUE_MAX_DEGREES = 345
IDENTITY_MAGENTA_SATURATION_THRESHOLD = 0.35
IDENTITY_MAGENTA_LUMA_THRESHOLD = 0.55
IDENTITY_BROWN_HUE_MIN_DEGREES = 8
IDENTITY_BROWN_HUE_MAX_DEGREES = 50
IDENTITY_OBSERVED_WIDTH_FRACTION = 0.85
IDENTITY_MINIMUM_CHROMATIC_PIXEL_COUNT = 18
IDENTITY_BLACK_LUMA_THRESHOLD = 0.10
IDENTITY_BLANK_LUMA_THRESHOLD = 0.86
IDENTITY_DARK_WASH_LUMA_THRESHOLD = 0.30
IDENTITY_DARK_WASH_GRAY_FRACTION = 0.60
IDENTITY_MINIMUM_MATCH_SCORE = 0.045
IDENTITY_MIXED_SECOND_SCORE_THRESHOLD = 0.05
IDENTITY_AMBIGUOUS_SCORE_RATIO = 1.18
IDENTITY_AMBIGUOUS_SCORE_MARGIN = 0.035

class IdentityAssertionError(Exception):
    pass


@dataclass(frozen=True)
class PhotoIdentity:
    status: str
    mark: str | None
    scores: dict[str, float]
    mean_luma: float
    notes: tuple[str, ...]


def overlay_model_from_text(overlay_text: str) -> str | None:
    text = overlay_text or ""
    for model in ("Fixture 1", "Fixture 3", "Fixture 5"):
        if model in text:
            return model
    return None


def _pil_image():
    # Load Pillow only when identifying pixels, so --help / smoke do not fail with ModuleNotFoundError when it is
    # not installed.
    try:
        from PIL import Image
    except ModuleNotFoundError as error:
        raise IdentityAssertionError(
            "Visual suites need Pillow. Run python3 -m pip install Pillow first, "
            "then run journey-b / pause-window / tvos-flow / tvos-album / tvos-person / tvos-switch."
        ) from error
    return Image


@functools.lru_cache(maxsize=4096)
def classify_screenshot(image_bytes: bytes) -> PhotoIdentity:
    if not image_bytes:
        return PhotoIdentity("UNRECOGNIZABLE", None, {}, 0.0, ("empty-bytes",))
    Image = _pil_image()
    try:
        with Image.open(io.BytesIO(image_bytes)) as image:
            rgb = image.convert("RGB")
            width, height = rgb.size
            if width < IDENTITY_MINIMUM_IMAGE_PIXELS or height < IDENTITY_MINIMUM_IMAGE_PIXELS:
                return PhotoIdentity("UNRECOGNIZABLE", None, {}, 0.0, ("too-small",))
            sample = rgb.resize((IDENTITY_SAMPLE_WIDTH_PIXELS, max(IDENTITY_MINIMUM_IMAGE_PIXELS, int(IDENTITY_SAMPLE_WIDTH_PIXELS * height / width))), Image.Resampling.BILINEAR)
    except Exception as error:
        return PhotoIdentity("UNRECOGNIZABLE", None, {}, 0.0, (f"unreadable:{type(error).__name__}",))

    pixels = list(sample.getdata())
    sample_w, sample_h = sample.size
    counts = {"green": 0, "gray": 0, "magenta": 0, "blue": 0, "brown": 0, "purple": 0}
    luma_sum = 0.0
    chromatic = 0
    for index, (red, green, blue) in enumerate(pixels):
        row, col = divmod(index, sample_w)
        if row > int(sample_h * IDENTITY_VISIBLE_HEIGHT_FRACTION):
            continue
        if col > int(sample_w * IDENTITY_CONTROLS_LEFT_FRACTION) and row < int(sample_h * IDENTITY_CONTROLS_BOTTOM_FRACTION):
            continue
        luma = (0.299 * red + 0.587 * green + 0.114 * blue) / 255.0
        luma_sum += luma
        hue, saturation = _hue_saturation(red, green, blue)
        if luma < IDENTITY_MINIMUM_LUMA or luma > IDENTITY_MAXIMUM_LUMA:
            continue
        if saturation < IDENTITY_GRAY_SATURATION_THRESHOLD:
            counts["gray"] += 1
            chromatic += 1
            continue
        if hue is None:
            counts["gray"] += 1
            chromatic += 1
            continue
        if IDENTITY_GREEN_HUE_MIN_DEGREES <= hue <= IDENTITY_GREEN_HUE_MAX_DEGREES:
            counts["green"] += 1
        elif IDENTITY_BLUE_HUE_MIN_DEGREES <= hue <= IDENTITY_BLUE_HUE_MAX_DEGREES:
            counts["blue"] += 1
        elif IDENTITY_PURPLE_HUE_MIN_DEGREES <= hue <= IDENTITY_PURPLE_HUE_MAX_DEGREES:
            if saturation > IDENTITY_MAGENTA_SATURATION_THRESHOLD and luma < IDENTITY_MAGENTA_LUMA_THRESHOLD:
                counts["magenta"] += 1
            else:
                counts["purple"] += 1
        elif IDENTITY_BROWN_HUE_MIN_DEGREES <= hue <= IDENTITY_BROWN_HUE_MAX_DEGREES:
            counts["brown"] += 1
        else:
            continue
        chromatic += 1

    observed = max(1, int(sample_w * sample_h * IDENTITY_VISIBLE_HEIGHT_FRACTION * IDENTITY_OBSERVED_WIDTH_FRACTION))
    mean_luma = luma_sum / observed
    if chromatic < IDENTITY_MINIMUM_CHROMATIC_PIXEL_COUNT:
        if mean_luma < IDENTITY_BLACK_LUMA_THRESHOLD:
            return PhotoIdentity("BLACK", None, {}, mean_luma, ("low-chroma-dark",))
        if mean_luma > IDENTITY_BLANK_LUMA_THRESHOLD:
            return PhotoIdentity("BLANK", None, {}, mean_luma, ("low-chroma-bright",))
        return PhotoIdentity("UNRECOGNIZABLE", None, {}, mean_luma, ("low-chroma",))

    total = float(chromatic)
    fraction = {key: value / total for key, value in counts.items()}
    scores = {
        "A1": min(fraction["green"], fraction["purple"]) + 0.15 * min(fraction["green"], fraction["purple"]),
        "A2": max(
            0.0,
            min(fraction["green"], fraction["gray"])
            + 0.12 * fraction["green"]
            - 0.55 * fraction["magenta"]
            - 0.40 * fraction["blue"]
            - 0.20 * fraction["brown"],
        ),
        "A3": min(fraction["magenta"], fraction["brown"]) + 0.20 * fraction["magenta"],
        "A4": min(fraction["blue"], fraction["brown"]) + 0.15 * fraction["blue"],
        "A5": max(
            0.0,
            min(fraction["green"], fraction["blue"])
            + 0.12 * fraction["blue"]
            - 0.45 * fraction["brown"]
            - 0.25 * fraction["magenta"],
        ),
    }
    ranked = sorted(scores.items(), key=lambda item: item[1], reverse=True)
    best_mark, best_score = ranked[0]
    second_mark, second_score = ranked[1]
    notes = (
        f"luma={mean_luma:.3f}",
        f"best={best_mark}:{best_score:.3f}",
        f"second={second_mark}:{second_score:.3f}",
        *(f"{key}={value:.3f}" for key, value in fraction.items()),
    )
    # The dark blurred background of an empty result has some blue/brown noise; a gray wash must not read as A4.
    if mean_luma <= IDENTITY_DARK_WASH_LUMA_THRESHOLD and fraction.get("gray", 0.0) >= IDENTITY_DARK_WASH_GRAY_FRACTION:
        return PhotoIdentity(
            "UNRECOGNIZABLE",
            None,
            scores,
            mean_luma,
            notes + ("dark-gray-wash",),
        )
    if best_score < IDENTITY_MINIMUM_MATCH_SCORE:
        return PhotoIdentity("UNRECOGNIZABLE", None, scores, mean_luma, notes)
    mixed = (
        second_score >= IDENTITY_MIXED_SECOND_SCORE_THRESHOLD
        and KEY_COLORS[best_mark].isdisjoint(KEY_COLORS[second_mark])
    )
    close = second_score > 0 and best_score < second_score * IDENTITY_AMBIGUOUS_SCORE_RATIO and (best_score - second_score) < IDENTITY_AMBIGUOUS_SCORE_MARGIN
    if mixed or close:
        return PhotoIdentity("TRANSITION", None, scores, mean_luma, notes)
    return PhotoIdentity("MATCH", best_mark, scores, mean_luma, notes)


_PATTERN_GLYPH_A = ("01110", "10001", "10001", "11111", "10001", "10001", "10001")
_PATTERN_GLYPH_B = ("11110", "10001", "10001", "11110", "10001", "10001", "11110")
FRAME_PALETTE_CHANNEL_TOLERANCE = 12
FRAME_GLYPH_MINIMUM_OBSERVED_CELLS = 14
FRAME_GLYPH_MINIMUM_WHITE_CELLS = 5
FRAME_GLYPH_MAXIMUM_BLANK_ROWS = 4
FRAME_GLYPH_MINIMUM_BAND_HEIGHT = 10
FRAME_TEXTURE_MAXIMUM_CELL_DRIFT_PIXELS = 2
FRAME_PALETTE_EDGE_BAND_RAW_PIXELS = 8

# Scanner-approved captures; TV has no home indicator. Its entry hint and
# control bar share this bounded rectangle, which cannot hide a full-span slot.
PUBLIC_SCENE_GEOMETRIES = {
    (1170, 2532): ((373, 2489, 798, 2512), (68, 2126, 1102, 2314)),
    (1640, 2360): ((543, 2330, 1097, 2349), None),
    (3840, 2160): ((1256, 1436, 2580, 1925), (1256, 1436, 2580, 1925)),
}

@dataclass(frozen=True)
class PublicFramePhoto:
    letter: str
    mark: str


def public_scene_photos_from_bytes(image_bytes: bytes) -> tuple[PublicFramePhoto, ...]:
    from strict_e2e_filter_contract import _display_foreground_png

    # The existing foreground reader verifies both the original and blurred surround.
    try:
        foreground = _display_foreground_png(image_bytes)
    except (OSError, ValueError) as error:
        raise IdentityAssertionError("Unrecognizable input: unreadable public glyph slot: screenshot cannot be decoded") from error
    with _pil_image().open(io.BytesIO(foreground)) as image:
        color_box, glyph_box = PUBLIC_SCENE_GEOMETRIES.get(image.size, (None, None))
        rgb = _public_frame_sample(image)
        slots, patterns = _public_frame_slots(rgb, _public_frame_sample_box(color_box, image.size, rgb.size),
                                              edge_band_pixels=_public_frame_edge_band(image.size, rgb.size))
    # Preserve #381's one-photo boundary uniformly across capture geometries.
    # Segmentation still precedes this path, so mixed/unreadable layouts cannot fall back.
    if len(slots) == 1:
        identity = classify_screenshot(image_bytes)
        pattern = patterns.get(slots[0][0])
        if identity.status != "MATCH" or identity.mark != slots[0][0] or pattern not in {"A", "B"}:
            raise IdentityAssertionError("unreadable public glyph slot: single photo color or public texture is missing")
        return (PublicFramePhoto(pattern, identity.mark),)
    return public_frame_photos_from_bytes(foreground, color_exclusion_box=color_box, glyph_overlay_box=glyph_box)


def public_asset_reference(asset_id: str) -> str:
    value = 14_695_981_039_346_656_037
    for byte in asset_id.encode("utf-8"):
        value = ((value ^ byte) * 1_099_511_628_211) & ((1 << 64) - 1)
    return f"asset-{value:016x}"


def _scene_fields(raw: str) -> dict[str, str]:
    if not isinstance(raw, str):
        raise ValueError("Scene probe fields must be text")
    return dict(part.strip().split("=", 1) for part in raw.split(";") if "=" in part)


def _named_scene_signature(evidence_dir: Path, name: str, fixture_set: str, *, tvos: bool) -> tuple[str, ...]:
    path = evidence_dir / f"{name}.png"
    if not path.is_file():
        raise IdentityAssertionError(f"Missing identification input {name}.png")
    photos = public_scene_photos_from_bytes(path.read_bytes())
    if any(photo.letter != fixture_set.upper() for photo in photos):
        raise IdentityAssertionError(f"{name}: frame must show only fixture {fixture_set.upper()} in every slot")
    sidecar = evidence_dir / f"{name}.scene.json"
    try:
        payload = json.loads(sidecar.read_text(encoding="utf-8"))
        observations = [payload[key] for key in ("before", "after")]
        expected_refs = {public_asset_reference(f"asset-{fixture_set}-{photo.mark[-1]}") for photo in photos}
        for observation in observations:
            manifest = _scene_fields(observation["manifest"])
            render = _scene_fields(observation["render"])
            refs = manifest["ledgerSceneAssets"].split(",")
            if (set(refs) != expected_refs or len(refs) != len(photos)
                    or int(manifest["slotCount"]) != len(photos)
                    or manifest["slotReadiness"].split(",") != ["ready"] * len(photos)
                    or int(manifest["gapPixelCount"]) != 0 or int(manifest["overlapPixelCount"]) != 0
                    or not float(manifest["canvasCoverage"]) >= 0.999_999
                    or not float(manifest["emptyCanvasRatio"]) <= 0.000_001
                    or render["phase"] != "stablePhoto" or render["layerRoles"] != "stable"
                    or render["loadingVisible"] != "false"):
                raise IdentityAssertionError(f"{name}: pixels and complete stable scene probes disagree")
        if observations[0]["manifest"] != observations[1]["manifest"]:
            # Motion/readback metadata can change; the photo references must remain the same.
            if _scene_fields(observations[0]["manifest"])["ledgerSceneAssets"] != _scene_fields(observations[1]["manifest"])["ledgerSceneAssets"]:
                raise IdentityAssertionError(f"{name}: scene changed during pixel capture")
        if tvos:
            index = observations[0]["index"]
            cursor, count = map(int, index.split("/"))
            if not 1 <= cursor <= count or observations[1]["index"] != index:
                raise IdentityAssertionError(f"{name}: index changed during pixel capture")
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise IdentityAssertionError(f"{name}: missing or unreadable scene sequence evidence") from error
    return tuple(f"{photo.letter}{photo.mark[-1]}" for photo in photos)


def _scene_fixture(evidence_dir: Path) -> str:
    from strict_e2e_filter_contract import load_member_manifest
    return str(load_member_manifest(evidence_dir / "member-manifest.json")["fixture_set"])


@functools.lru_cache(maxsize=1)
def _public_photo_palettes() -> dict[str, tuple[tuple[int, int, int], ...]]:
    from strict_e2e_server import _fixture_data

    Image = _pil_image()
    palettes = {}
    for image_bytes in _fixture_data("a")["images"].values():
        with Image.open(io.BytesIO(image_bytes)) as image:
            rgb = image.convert("RGB")
            palettes[classify_screenshot(image_bytes).mark] = tuple(sorted({color for color in rgb.getdata() if min(color) < 240}))
    return palettes


@functools.lru_cache(maxsize=4096)
def _public_palette_assignment(color: tuple[int, int, int]) -> tuple[str, int] | None:
    matches = [(mark, index) for mark, palette in _public_photo_palettes().items()
               for index, reference in enumerate(palette)
               if max(abs(a - b) for a, b in zip(color, reference)) <= FRAME_PALETTE_CHANNEL_TOLERANCE]
    return matches[0] if len(matches) == 1 else None


def _public_palette_edge_assignment(color: tuple[int, int, int]) -> str | None:
    """Only segmentation may use a unique same-photo interpolation at an edge."""
    matches = []
    for mark, (first, second) in _public_photo_palettes().items():
        delta = tuple(b - a for a, b in zip(first, second))
        fraction = sum((c - a) * d for c, a, d in zip(color, first, delta)) / sum(d * d for d in delta)
        if (0 < fraction < 1
                and max(abs(c - (a + fraction * d)) for c, a, d in zip(color, first, delta)) <= FRAME_PALETTE_CHANNEL_TOLERANCE):
            matches.append(mark)
    return matches[0] if len(matches) == 1 else None


def _public_frame_edge_band(original_size: tuple[int, int], sample_size: tuple[int, int]) -> tuple[int, int]:
    return tuple(FRAME_PALETTE_EDGE_BAND_RAW_PIXELS * sample // original
                 for original, sample in zip(original_size, sample_size))


def _public_axis_slots(rgb: object, color_exclusion_box: tuple[int, int, int, int] | None,
                       *, horizontal: bool, edge_band_pixels: int = 0) -> list[tuple[str, tuple[int, int, int, int]]]:
    """A clean axis must identify one palette along every full-span line."""
    palettes = _public_photo_palettes()
    slots: list[tuple[str, int, int]] = []
    row_marks: list[str | None] = []
    exact_row_marks: list[str | None] = []
    pixels = rgb.load()
    span = rgb.height if horizontal else rgb.width
    extent = rgb.width if horizontal else rgb.height
    for line in range(extent):
        counts = {mark: [0, 0] for mark in palettes}
        exact_counts = {mark: 0 for mark in palettes}
        for offset in range(span):
            x, y = (line, offset) if horizontal else (offset, line)
            if color_exclusion_box is not None:
                left, top, right, bottom = color_exclusion_box
                if left <= x < right and top <= y < bottom:
                    continue
            color = pixels[x, y]
            assignment = _public_palette_assignment(color)
            if assignment is not None:
                mark, index = assignment
                counts[mark][index] += 1
                exact_counts[mark] += 1
            elif line < edge_band_pixels or line >= extent - edge_band_pixels:
                mark = _public_palette_edge_assignment(color)
                if mark is not None:
                    counts[mark][0] += 1
        marks = [mark for mark, count in counts.items() if sum(count) >= IDENTITY_MINIMUM_CHROMATIC_PIXEL_COUNT]
        exact_row_marks.append(next((mark for mark, count in exact_counts.items()
                                     if count >= IDENTITY_MINIMUM_CHROMATIC_PIXEL_COUNT), None))
        if len(marks) > 1:
            raise IdentityAssertionError("unreadable public glyph slot: public photo colors are missing or mixed")
        if not marks:
            row_marks.append(None)
            continue
        mark = marks[0]
        row_marks.append(mark)
    for y, mark in enumerate(row_marks):
        if mark is None:
            following = next((item for item in exact_row_marks[y + 1:] if item is not None), None)
            preceding = next((item for item in reversed(exact_row_marks[:y]) if item is not None), None)
            # Bilinear texture edges and overlay ink can obscure a row. Keep it in the
            # same slot only when both surrounding rows independently identify that photo.
            if preceding is None or preceding != following:
                raise IdentityAssertionError("unreadable public glyph slot: public photo colors are missing or mixed")
            mark = preceding
        if slots and slots[-1][0] == mark:
            slots[-1] = (mark, slots[-1][1], y + 1)
        else:
            slots.append((mark, y, y + 1))
    return [(mark, (top, 0, bottom, rgb.height) if horizontal else (0, top, rgb.width, bottom))
            for mark, top, bottom in slots]


def _public_slot_pattern(rgb: object, mark: str, exclusion: tuple[int, int, int, int] | None) -> str | None:
    # Texture always uses photo rows: fixture B's stripes do not rotate with the slot axis.
    pixels = rgb.load()
    pattern = None
    for y in range(rgb.height):
        count = [0, 0]
        has_white = False
        transitions = []
        previous = None
        previous_x = 0
        unknown_run = maximum_unknown_run = 0
        for x in range(rgb.width):
            if exclusion and exclusion[0] <= x < exclusion[2] and exclusion[1] <= y < exclusion[3]:
                continue
            color = pixels[x, y]
            has_white |= min(color) >= 240
            assignment = _public_palette_assignment(color)
            if assignment is not None and assignment[0] == mark:
                count[assignment[1]] += 1
                if previous is not None and assignment[1] != previous:
                    transitions.append((previous_x + x) / 2)
                previous, previous_x = assignment[1], x
                unknown_run = 0
            else:
                unknown_run += 1
                maximum_unknown_run = max(maximum_unknown_run, unknown_run)
        if not has_white and sum(count) >= rgb.width * IDENTITY_OBSERVED_WIDTH_FRACTION:
            observed = "A" if min(count) >= IDENTITY_MINIMUM_CHROMATIC_PIXEL_COUNT else "B"
            # Checker cells are periodic in each unobstructed row. A foreign stripe
            # beside the same photo number must not borrow the checker half's glyph.
            if (observed == "A" and len(transitions) >= 2
                    and maximum_unknown_run <= FRAME_TEXTURE_MAXIMUM_CELL_DRIFT_PIXELS
                    and not (exclusion and exclusion[1] <= y < exclusion[3])):
                widths = [right - left for left, right in zip(transitions, transitions[1:])]
                period = min(widths)
                if (max(widths) - period > FRAME_TEXTURE_MAXIMUM_CELL_DRIFT_PIXELS
                        or max(transitions[0], rgb.width - 1 - transitions[-1]) > period + FRAME_TEXTURE_MAXIMUM_CELL_DRIFT_PIXELS):
                    raise IdentityAssertionError("unreadable public glyph slot: conflicting public background patterns")
            if pattern is not None and pattern != observed:
                raise IdentityAssertionError("unreadable public glyph slot: conflicting public background patterns")
            pattern = observed
    return pattern


def _relative_box(box: tuple[int, int, int, int] | None,
                  slot: tuple[int, int, int, int]) -> tuple[int, int, int, int] | None:
    return (box[0] - slot[0], box[1] - slot[1], box[2] - slot[0], box[3] - slot[1]) if box else None


def _public_frame_slots(rgb: object, color_exclusion_box: tuple[int, int, int, int] | None = None, *,
                        edge_band_pixels: tuple[int, int] = (0, 0)
                        ) -> tuple[list[tuple[str, tuple[int, int, int, int]]], dict[str, str]]:
    candidates = []
    for horizontal in (False, True):
        try:
            candidates.append(_public_axis_slots(rgb, color_exclusion_box, horizontal=horizontal,
                                                  edge_band_pixels=edge_band_pixels[0 if horizontal else 1]))
        except IdentityAssertionError:
            continue
    # One axis alone cannot justify a single photo: it could overlook a full-width
    # blank band or foreign footer. Both axes must agree for a one-slot frame.
    if (not candidates or (len(candidates) == 1 and len(candidates[0]) == 1)
            or any(candidate != candidates[0] for candidate in candidates[1:])):
        raise IdentityAssertionError("unreadable public glyph slot: public photo colors are missing or mixed")
    slots = candidates[0]
    patterns = {}
    for mark, box in slots:
        pattern = _public_slot_pattern(rgb.crop(box), mark, _relative_box(color_exclusion_box, box))
        if pattern is not None:
            if mark in patterns and patterns[mark] != pattern:
                raise IdentityAssertionError("unreadable public glyph slot: conflicting public background patterns")
            patterns[mark] = pattern
    return slots, patterns


@functools.lru_cache(maxsize=4096)
def classify_public_pattern(image_bytes: bytes) -> str | None:
    """Tell from the screen whether the public pattern is A or B. Color identity still uses classify_screenshot."""
    if not image_bytes:
        return None
    Image = _pil_image()
    try:
        with Image.open(io.BytesIO(image_bytes)) as image:
            rgb = image.convert("RGB")
            width, height = rgb.size
            if width < IDENTITY_MINIMUM_IMAGE_PIXELS or height < IDENTITY_MINIMUM_IMAGE_PIXELS:
                return None
            working = rgb
            if width > 480:
                working = rgb.resize((480, max(8, int(480 * height / width))), Image.Resampling.NEAREST)
            working_width, working_height = working.size
            vertical_halves = [
                working.crop((0, 0, working_width, working_height // 2)),
                working.crop((0, working_height // 2, working_width, working_height)),
            ]
            half_marks = []
            for half in vertical_halves:
                encoded = io.BytesIO()
                half.save(encoded, format="PNG")
                identity = classify_screenshot(encoded.getvalue())
                half_marks.append(identity.mark if identity.status == "MATCH" else None)
            # When top and bottom really are different photos, check each letter; left/right texture inference
            # must not override the real source.
            if all(half_marks) and half_marks[0] != half_marks[1]:
                letters = [_center_public_letter(half) for half in vertical_halves]
                if letters[0] in {"A", "B"} and letters[0] == letters[1]:
                    return letters[0].lower()
                return None
            left_s, right_s = _edge_spatials(rgb)
            if left_s in {"a", "b"} and right_s in {"a", "b"} and left_s != right_s:
                return None
            letters = [
                item
                for item in (
                    _center_public_letter(working),
                    *(_center_public_letter(crop) for crop in _pattern_crops(working)),
                )
                if item in {"A", "B"}
            ]
            unique = set(letters)
            if unique == {"B"}:
                return "b"
            if unique == {"A"}:
                return "a"
            if unique == {"A", "B"}:
                return None
            if left_s in {"a", "b"} and left_s == right_s:
                return left_s
            spatial = _spatial_public_pattern(rgb)
            return spatial if spatial in {"a", "b"} else None
    except Exception:
        return None


@functools.lru_cache(maxsize=4096)
def public_letter_from_bytes(image_bytes: bytes) -> str | None:
    """Public letter on a region crop. A blurred background has no recognizable glyph."""
    if not image_bytes:
        return None
    Image = _pil_image()
    try:
        with Image.open(io.BytesIO(image_bytes)) as image:
            rgb = image.convert("RGB")
            width, height = rgb.size
            if width < IDENTITY_MINIMUM_IMAGE_PIXELS or height < IDENTITY_MINIMUM_IMAGE_PIXELS:
                return None
            if width > 480:
                rgb = rgb.resize((480, max(8, int(480 * height / width))), Image.Resampling.NEAREST)
            letter = _center_public_letter(rgb)
            return letter if letter in {"A", "B"} else None
    except Exception:
        return None


@functools.lru_cache(maxsize=4096)
def public_frame_letter_from_bytes(image_bytes: bytes) -> str | None:
    """Return a letter only when every visible photo has a readable public glyph."""
    try:
        return public_frame_photos_from_bytes(image_bytes)[0].letter
    except IdentityAssertionError:
        return None


def _public_frame_sample(image: object) -> object:
    rgb = image.convert("RGB")
    width, height = rgb.size
    if width < IDENTITY_MINIMUM_IMAGE_PIXELS or height < IDENTITY_MINIMUM_IMAGE_PIXELS:
        raise IdentityAssertionError("no public glyph")
    if width > 480:
        rgb = rgb.resize((480, max(8, round(480 * height / width))), _pil_image().Resampling.NEAREST)
    return rgb


def _public_frame_sample_box(box: tuple[int, int, int, int] | None,
                             original_size: tuple[int, int], sample_size: tuple[int, int]) -> tuple[int, int, int, int] | None:
    if box is None:
        return None
    width, height = original_size
    sample_width, sample_height = sample_size
    left, top, right, bottom = box
    if not (0 <= left < right <= width and 0 <= top < bottom <= height):
        raise IdentityAssertionError("system overlay box is outside the public frame")
    return (left * sample_width // width, top * sample_height // height,
            (right * sample_width + width - 1) // width, (bottom * sample_height + height - 1) // height)


@functools.lru_cache(maxsize=4096)
def public_frame_slot_count_from_bytes(image_bytes: bytes, *,
                                      color_exclusion_box: tuple[int, int, int, int] | None = None) -> int:
    """Count palette-defined slots without requiring a readable letter or digit."""
    if not image_bytes:
        raise IdentityAssertionError("no public glyph")
    Image = _pil_image()
    try:
        with Image.open(io.BytesIO(image_bytes)) as image:
            rgb = _public_frame_sample(image)
            slots, _ = _public_frame_slots(rgb, _public_frame_sample_box(color_exclusion_box, image.size, rgb.size),
                                           edge_band_pixels=_public_frame_edge_band(image.size, rgb.size))
            return len(slots)
    except IdentityAssertionError:
        raise
    except Exception as error:
        raise IdentityAssertionError(f"unreadable public glyph: {type(error).__name__}") from error


@functools.lru_cache(maxsize=4096)
def public_frame_photos_from_bytes(image_bytes: bytes, *,
                                  color_exclusion_box: tuple[int, int, int, int] | None = None,
                                  glyph_overlay_box: tuple[int, int, int, int] | None = None) -> tuple[PublicFramePhoto, ...]:
    """Read each sharp public slot's letter and color identity; cross-check its background pattern."""
    if not image_bytes:
        raise IdentityAssertionError("no public glyph")
    Image = _pil_image()
    try:
        with Image.open(io.BytesIO(image_bytes)) as image:
            rgb = _public_frame_sample(image)
            slots, patterns = _public_frame_slots(rgb, _public_frame_sample_box(color_exclusion_box, image.size, rgb.size),
                                                  edge_band_pixels=_public_frame_edge_band(image.size, rgb.size))
            overlay = _public_frame_sample_box(glyph_overlay_box, image.size, rgb.size)
            photos = []
            for mark, box in slots:
                slot_photos = _read_public_slot(rgb.crop(box), mark, _relative_box(overlay, box))
                if not slot_photos:
                    raise IdentityAssertionError("no public glyph" if len(slots) == 1 else "unreadable public glyph slot")
                photos.extend(slot_photos)
            if len({photo.letter for photo in photos}) != 1:
                raise IdentityAssertionError("mixed public glyphs")
            if any(pattern != photos[0].letter for pattern in patterns.values()):
                raise IdentityAssertionError("unreadable public glyph slot: foreign public background pattern")
            return tuple(photos)
    except IdentityAssertionError:
        raise
    except Exception as error:
        raise IdentityAssertionError(f"unreadable public glyph: {type(error).__name__}") from error


def _read_public_slot(rgb: object, mark: str, glyph_overlay_box: tuple[int, int, int, int] | None = None) -> list[PublicFramePhoto]:
    from strict_e2e_server import GLYPHS

    width, height = rgb.size
    pixels = rgb.load()
    def is_observed(x: int, y: int) -> bool:
        return not (glyph_overlay_box is not None
                    and glyph_overlay_box[0] <= x < glyph_overlay_box[2]
                    and glyph_overlay_box[1] <= y < glyph_overlay_box[3])

    white_rows = [[is_observed(x, y) and min(pixels[x, y]) >= 240 for x in range(width)] for y in range(height)]
    photos: list[PublicFramePhoto] = []
    bands: list[tuple[int, int]] = []
    # Short fragments can belong to a full-size glyph cut by the measured overlay.
    # The ten-pixel gate applies to the joined candidate, never to a lone fragment.
    minimum_fragment_height = 1 if glyph_overlay_box is not None else FRAME_GLYPH_MINIMUM_BAND_HEIGHT
    for top, bottom in _public_bitmap_bands(white_rows, minimum_height=minimum_fragment_height):
        # Only a gap wholly inside the measured control-bar rows can join ink.
        # This operates on one color slot; a merged candidate must prove one glyph.
        if bands and glyph_overlay_box is not None and glyph_overlay_box[1] <= bands[-1][1] <= top <= glyph_overlay_box[3]:
            bands[-1] = (bands[-1][0], bottom)
        else:
            bands.append((top, bottom))
    for top, bottom in bands:
        if bottom - top < FRAME_GLYPH_MINIMUM_BAND_HEIGHT:
            continue
        cell = (bottom - top) / 7
        band_photos = []
        origins: set[float] = set()
        for row_index in range(7):
            row = white_rows[int(top + (row_index + 0.5) * cell)]
            for x in range(1, width):
                y = int(top + (row_index + 0.5) * cell)
                if is_observed(x, y) and is_observed(x - 1, y) and row[x] != row[x - 1]:
                    origins.update(round(x - column * cell, 1) for column in range(6))
        for origin in origins:
            observed = []
            for row_index in range(7):
                y = int(top + (row_index + 0.5) * cell)
                for column in range(5):
                    x = round(origin + (column + 0.5) * cell)
                    if 0 <= x < width and is_observed(x, y):
                        observed.append((row_index, column, white_rows[y][x]))
            for letter in _public_letters_for_cells(observed):
                # A visible digit must agree with this slot's color identity, so
                # an isolated digit cannot be mistaken for a cropped letter.
                digit = GLYPHS[mark[-1]]
                if any(
                    (digit[row][column] == "1") != white_rows[int(top + (row + 0.5) * cell)][x]
                    for row in range(7) for column in range(5)
                    if 0 <= (x := round(origin + (6 + column + 0.5) * cell)) < width
                    and is_observed(x, int(top + (row + 0.5) * cell))
                ):
                    continue
                band_photos.append(PublicFramePhoto(letter, mark))
        if not band_photos:
            ink_x = [x for y in range(top, bottom) for x, white in enumerate(white_rows[y]) if white]
            if max(ink_x) - min(ink_x) + 1 <= (bottom - top) * 11 / 7 + 2:
                raise IdentityAssertionError("unreadable public glyph slot")
        photos.extend(band_photos)
    return list(dict.fromkeys(photos))


def _public_bitmap_bands(white_rows: Sequence[Sequence[bool]], *,
                         minimum_height: int = FRAME_GLYPH_MINIMUM_BAND_HEIGHT) -> list[tuple[int, int]]:
    bands: list[list[int]] = []
    for y, row in enumerate(white_rows):
        if any(row):
            if not bands or y > bands[-1][1] + FRAME_GLYPH_MAXIMUM_BLANK_ROWS:
                bands.append([y, y + 1])
            else:
                bands[-1][1] = y + 1
    return [(top, bottom) for top, bottom in bands if bottom - top >= minimum_height]


def _public_letters_for_cells(observed: Sequence[tuple[int, int, bool]]) -> list[str]:
    # One surviving column or a few white pixels cannot identify a cropped fixture.
    if len(observed) < FRAME_GLYPH_MINIMUM_OBSERVED_CELLS or sum(white for _, _, white in observed) < FRAME_GLYPH_MINIMUM_WHITE_CELLS:
        return []
    return [letter for letter, glyph in (("A", _PATTERN_GLYPH_A), ("B", _PATTERN_GLYPH_B))
            if all((glyph[row][column] == "1") == white for row, column, white in observed)]


def _pattern_crops(rgb: object) -> list[object]:
    width, height = rgb.size
    if width < 16:
        return []
    mid = width // 2
    return [
        rgb.crop((0, 0, mid, height)),
        rgb.crop((mid, 0, width, height)),
        rgb.crop((int(width * 0.2), int(height * 0.15), int(width * 0.8), int(height * 0.85))),
    ]


def _edge_spatials(rgb: object) -> tuple[str | None, str | None]:
    """Stripes or checkerboard at each of the left and right edges. Two photos side by side make the whole
    screen look like a checkerboard, so the whole screen cannot serve as identity."""
    width, height = rgb.size
    if width < 16:
        return None, None
    y0 = int(height * 0.12)
    y1 = max(y0 + 1, int(height * 0.82))
    left = rgb.crop((0, y0, max(8, int(width * 0.18)), y1))
    right = rgb.crop((int(width * 0.82), y0, width, y1))
    return _spatial_public_pattern(left), _spatial_public_pattern(right)


def _spatial_public_pattern(rgb: object) -> str | None:
    width, height = rgb.size
    pixels = rgb.load()
    stripe_votes = 0
    checker_votes = 0
    step_y = max(1, height // 24)
    step_x = max(1, width // 40)
    for y in range(0, height, step_y):
        row_colors: set[tuple[int, int, int]] = set()
        for x in range(0, width, step_x):
            red, green, blue = pixels[x, y][:3]
            luma = (0.299 * red + 0.587 * green + 0.114 * blue) / 255.0
            if luma < 0.08 or luma > 0.92:
                continue
            row_colors.add((red // 24, green // 24, blue // 24))
        if len(row_colors) >= 2:
            checker_votes += 1
        elif len(row_colors) == 1:
            stripe_votes += 1
    if stripe_votes >= 3 and stripe_votes > checker_votes:
        return "b"
    if checker_votes >= 3 and checker_votes > stripe_votes:
        return "a"
    return None


def _center_public_letter(rgb: object) -> str | None:
    width, height = rgb.size
    pixels = rgb.load()
    left = int(width * 0.18)
    right = int(width * 0.82)
    top = int(height * 0.18)
    bottom = int(height * 0.82)
    whites: list[tuple[int, int]] = []
    for y in range(top, max(top + 1, bottom)):
        for x in range(left, max(left + 1, right)):
            red, green, blue = pixels[x, y][:3]
            if red >= 240 and green >= 240 and blue >= 240:
                whites.append((x, y))
    if len(whites) < 24:
        return None
    xs = [item[0] for item in whites]
    ys = [item[1] for item in whites]
    min_x, max_x, min_y, max_y = min(xs), max(xs), min(ys), max(ys)
    box_width = max_x - min_x + 1
    box_height = max_y - min_y + 1
    if box_width < 10 or box_height < 10:
        return None
    # The label has two cells, letter + digit; the letter takes about 5/11 of the width.
    letter_width = max(8, int(box_width * 5 / 11))
    score_a = _glyph_overlap(pixels, min_x, min_y, letter_width, box_height, _PATTERN_GLYPH_A, width, height)
    score_b = _glyph_overlap(pixels, min_x, min_y, letter_width, box_height, _PATTERN_GLYPH_B, width, height)
    if score_a < 0.58 and score_b < 0.58:
        return None
    if abs(score_a - score_b) < 0.06:
        return None
    return "A" if score_a > score_b else "B"


def _glyph_overlap(
    pixels: object,
    origin_x: int,
    origin_y: int,
    glyph_width: int,
    glyph_height: int,
    glyph: tuple[str, ...],
    image_width: int,
    image_height: int,
) -> float:
    rows = len(glyph)
    cols = len(glyph[0])
    hits = 0
    total = 0
    for row_index, row in enumerate(glyph):
        for col_index, cell in enumerate(row):
            expected_white = cell == "1"
            x0 = origin_x + int(col_index * glyph_width / cols)
            x1 = origin_x + int((col_index + 1) * glyph_width / cols)
            y0 = origin_y + int(row_index * glyph_height / rows)
            y1 = origin_y + int((row_index + 1) * glyph_height / rows)
            white = 0
            counted = 0
            for y in range(max(0, y0), min(image_height, max(y0 + 1, y1))):
                for x in range(max(0, x0), min(image_width, max(x0 + 1, x1))):
                    red, green, blue = pixels[x, y][:3]
                    counted += 1
                    if red >= 240 and green >= 240 and blue >= 240:
                        white += 1
            if counted == 0:
                continue
            actual_white = (white / counted) >= 0.35
            total += 1
            if actual_white == expected_white:
                hits += 1
    return hits / max(1, total)


def assert_exif_correspondence(identity: PhotoIdentity, overlay_text: str) -> None:
    if identity.status != "MATCH" or identity.mark not in EXPECTED_EXIF_MODEL:
        raise IdentityAssertionError(
            f"Can't check EXIF: photo status {identity.status} mark={identity.mark}"
        )
    expected = EXPECTED_EXIF_MODEL[identity.mark]
    actual = overlay_model_from_text(overlay_text)
    if expected != actual:
        raise IdentityAssertionError(
            f"EXIF does not match the photo: mark={identity.mark} expected={expected!r} actual={actual!r}"
        )


def assert_round_trip(identities: Sequence[PhotoIdentity]) -> None:
    if len(identities) != 5:
        raise IdentityAssertionError(f"Round trip must have five steps, got {len(identities)}")
    marks = _require_marks(identities, context="Round trip")
    start, first_next, second_next, first_prev, second_prev = marks
    if first_next == start:
        raise IdentityAssertionError("Still the original photo after the first forward step")
    if second_next == first_next:
        raise IdentityAssertionError("Still the same photo after the second forward step")
    if first_prev != first_next:
        raise IdentityAssertionError("The first back step must return to the first forward photo")
    if second_prev != start:
        raise IdentityAssertionError(f"Second previous step must return to the original photo {start}, got {second_prev}")


def assert_pause_hold(immediate: PhotoIdentity, after: PhotoIdentity) -> None:
    left, right = _require_marks((immediate, after), context="Pause hold")
    if left != right:
        raise IdentityAssertionError(f"Photo changed after pausing over 10 seconds: {left} → {right}")


def assert_resumed_advanced(paused: PhotoIdentity, resumed: PhotoIdentity) -> None:
    left, right = _require_marks((paused, resumed), context="Resume advance")
    if left == right:
        raise IdentityAssertionError(f"Still {left} after resuming playback; it did not advance")


def assert_required_frames(present: Mapping[str, object], required: Iterable[str]) -> None:
    missing = [name for name in required if not present.get(name)]
    if missing:
        raise IdentityAssertionError("Window missed or required frames missing: " + ", ".join(missing))


def evaluate_visual_identity(evidence_dir: Path, suite: str) -> dict[str, object]:
    if suite not in VISUAL_SUITES:
        return {"verdict": "NOT_REQUIRED", "suite": suite}
    if suite in {"tvos-album", "tvos-person", "tvos-switch"}:
        from strict_e2e_filter_contract import FilterContractError, evaluate_filter_visual_identity

        try:
            return evaluate_filter_visual_identity(evidence_dir, suite)
        except FilterContractError as error:
            raise IdentityAssertionError(str(error)) from error
    if suite in {"journey-b", "tvos-flow"}:
        # Missing screenshots keep their original diagnostic before sidecar checks.
        for name in JOURNEY_B_STEPS:
            if not (evidence_dir / f"{name}.png").is_file():
                raise IdentityAssertionError(f"Missing identification input {name}.png")
        from strict_e2e_filter_contract import FilterContractError
        try:
            fixture_set = _scene_fixture(evidence_dir)
            names = JOURNEY_B_STEPS + (TVOS_FLOW_STEPS if suite == "tvos-flow" else ())
            steps = {name: _named_scene_signature(evidence_dir, name, fixture_set, tvos=suite == "tvos-flow") for name in names}
        except FilterContractError as error:
            raise IdentityAssertionError(str(error)) from error
        start, first, second, back_first, back_start = [steps[name] for name in JOURNEY_B_STEPS]
        if first == start:
            raise IdentityAssertionError("Still the original photo after the first forward step")
        if second == first:
            raise IdentityAssertionError("Still the same photo after the second forward step")
        if back_first != first:
            raise IdentityAssertionError("The first back step must return to the first forward photo")
        if back_start != start:
            raise IdentityAssertionError(f"Second previous step must return to the original photo {start}, got {back_start}")
        if suite == "tvos-flow":
            if steps[TVOS_FLOW_STEPS[0]] != steps[TVOS_FLOW_STEPS[1]]:
                raise IdentityAssertionError("Photo changed after pausing over 10 seconds")
            if steps[TVOS_FLOW_STEPS[1]] == steps[TVOS_FLOW_STEPS[2]]:
                raise IdentityAssertionError("Still the same photo after resuming playback; it did not advance")
            indexes = {name: json.loads((evidence_dir / f"{name}.scene.json").read_text())["before"]["index"] for name in names}
            # This probe is the forward pool cursor, which history Previous does not rewind.
            # Backward identity is proven by the complete pixel signature and ledger refs above.
            for left, right in (TVOS_FLOW_STEPS[:2],):
                if indexes[left] != indexes[right]:
                    raise IdentityAssertionError("Scene round-trip pixels and index sequence disagree")
            for left, right in zip(JOURNEY_B_STEPS[:2], JOURNEY_B_STEPS[1:3]):
                if indexes[left] == indexes[right]:
                    raise IdentityAssertionError("Scene advance pixels and index sequence disagree")
            if indexes[TVOS_FLOW_STEPS[1]] == indexes[TVOS_FLOW_STEPS[2]]:
                raise IdentityAssertionError("Scene resume pixels and index sequence disagree")
        return {"verdict": "PASS", "suite": suite, "steps": {name: {"signature": list(signature)} for name, signature in steps.items()}}

    # The target window must show an allowed public mark; at that moment EXIF may differ from the photo
    # (A2+Fixture 3 transition boundary).
    window = _classify_named(evidence_dir, "window-detected")
    identities = [_classify_named(evidence_dir, name) for name in PAUSE_WINDOW_STEPS]
    if window.status != "MATCH" or window.mark not in MARKS:
        raise IdentityAssertionError(
            f"Target window image is not recognized; cannot count as SUCCESS: status={window.status} mark={window.mark}"
        )
    overlay_text = _overlay_text(evidence_dir)
    assert_exif_correspondence(identities[0], overlay_text)
    assert_exif_correspondence(identities[1], overlay_text)
    assert_pause_hold(identities[0], identities[1])
    if window.mark != identities[0].mark:
        raise IdentityAssertionError(
            f"Target window shows the wrong image; cannot count as SUCCESS: window={window.mark} after-pause={identities[0].mark}"
        )
    steps = {"window-detected": window}
    steps.update(dict(zip(PAUSE_WINDOW_STEPS, identities)))
    payload = _report(suite, steps)
    payload["overlay_text_after_pause"] = overlay_text
    payload["overlay_model"] = overlay_model_from_text(overlay_text)
    return payload


def _classify_named(evidence_dir: Path, name: str) -> PhotoIdentity:
    path = evidence_dir / f"{name}.png"
    if not path.is_file():
        raise IdentityAssertionError(f"Missing identification input {name}.png")
    try:
        payload = path.read_bytes()
    except OSError as error:
        raise IdentityAssertionError(f"Cannot read identification input {name}.png: {error}") from error
    return classify_screenshot(payload)


def _overlay_text(evidence_dir: Path) -> str:
    sidecar = evidence_dir / "after-pause.overlay.txt"
    if sidecar.is_file():
        return sidecar.read_text(encoding="utf-8")
    report = evidence_dir / "visual-identity.json"
    if report.is_file():
        try:
            payload = json.loads(report.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return ""
        if isinstance(payload, dict):
            return str(payload.get("overlay_text_after_pause") or "")
    return ""


def _report(suite: str, steps: Mapping[str, PhotoIdentity]) -> dict[str, object]:
    return {
        "verdict": "PASS",
        "suite": suite,
        "steps": {
            name: {
                "status": identity.status,
                "mark": identity.mark,
                "mean_luma": identity.mean_luma,
                "notes": list(identity.notes),
            }
            for name, identity in steps.items()
        },
    }


def _require_marks(identities: Sequence[PhotoIdentity], *, context: str) -> list[str]:
    marks: list[str] = []
    for index, identity in enumerate(identities):
        if identity.status != "MATCH" or identity.mark not in MARKS:
            raise IdentityAssertionError(
                f"{context} step {index + 1} cannot be identified: status={identity.status} mark={identity.mark}"
            )
        marks.append(identity.mark)
    return marks


def _hue_saturation(red: int, green: int, blue: int) -> tuple[float | None, float]:
    maximum = max(red, green, blue)
    minimum = min(red, green, blue)
    if maximum == 0:
        return None, 0.0
    saturation = (maximum - minimum) / maximum
    chroma = maximum - minimum
    if chroma == 0:
        return None, saturation
    rf, gf, bf = red / 255.0, green / 255.0, blue / 255.0
    mx, mn = max(rf, gf, bf), min(rf, gf, bf)
    delta = mx - mn
    if mx == rf:
        hue = ((gf - bf) / delta) % 6.0
    elif mx == gf:
        hue = (bf - rf) / delta + 2.0
    else:
        hue = (rf - gf) / delta + 4.0
    return hue * 60.0, saturation
