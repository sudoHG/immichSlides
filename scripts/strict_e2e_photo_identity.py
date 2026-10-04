#!/usr/bin/env python3
"""On-screen identification of public marked fixtures. Uses only pixels and visible EXIF text, never asset IDs."""

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
            if width < 8 or height < 8:
                return PhotoIdentity("UNRECOGNIZABLE", None, {}, 0.0, ("too-small",))
            sample = rgb.resize((96, max(8, int(96 * height / width))), Image.Resampling.BILINEAR)
    except Exception as error:
        return PhotoIdentity("UNRECOGNIZABLE", None, {}, 0.0, (f"unreadable:{type(error).__name__}",))

    pixels = list(sample.getdata())
    sample_w, sample_h = sample.size
    counts = {"green": 0, "gray": 0, "magenta": 0, "blue": 0, "brown": 0, "purple": 0}
    luma_sum = 0.0
    chromatic = 0
    for index, (red, green, blue) in enumerate(pixels):
        row, col = divmod(index, sample_w)
        if row > int(sample_h * 0.86):
            continue
        if col > int(sample_w * 0.72) and row < int(sample_h * 0.22):
            continue
        luma = (0.299 * red + 0.587 * green + 0.114 * blue) / 255.0
        luma_sum += luma
        hue, saturation = _hue_saturation(red, green, blue)
        if luma < 0.035 or luma > 0.94:
            continue
        if saturation < 0.16:
            counts["gray"] += 1
            chromatic += 1
            continue
        if hue is None:
            counts["gray"] += 1
            chromatic += 1
            continue
        if 70 <= hue <= 170:
            counts["green"] += 1
        elif 185 <= hue <= 255:
            counts["blue"] += 1
        elif 265 <= hue <= 345:
            if saturation > 0.35 and luma < 0.55:
                counts["magenta"] += 1
            else:
                counts["purple"] += 1
        elif 8 <= hue <= 50:
            counts["brown"] += 1
        else:
            continue
        chromatic += 1

    observed = max(1, int(sample_w * sample_h * 0.86 * 0.85))
    mean_luma = luma_sum / observed
    if chromatic < 18:
        if mean_luma < 0.10:
            return PhotoIdentity("BLACK", None, {}, mean_luma, ("low-chroma-dark",))
        if mean_luma > 0.86:
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
    if mean_luma <= 0.30 and fraction.get("gray", 0.0) >= 0.60:
        return PhotoIdentity(
            "UNRECOGNIZABLE",
            None,
            scores,
            mean_luma,
            notes + ("dark-gray-wash",),
        )
    if best_score < 0.045:
        return PhotoIdentity("UNRECOGNIZABLE", None, scores, mean_luma, notes)
    mixed = (
        second_score >= 0.05
        and KEY_COLORS[best_mark].isdisjoint(KEY_COLORS[second_mark])
    )
    close = second_score > 0 and best_score < second_score * 1.18 and (best_score - second_score) < 0.035
    if mixed or close:
        return PhotoIdentity("TRANSITION", None, scores, mean_luma, notes)
    return PhotoIdentity("MATCH", best_mark, scores, mean_luma, notes)


_PATTERN_GLYPH_A = ("01110", "10001", "10001", "11111", "10001", "10001", "10001")
_PATTERN_GLYPH_B = ("11110", "10001", "10001", "11110", "10001", "10001", "11110")


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
            if width < 8 or height < 8:
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
            if width < 8 or height < 8:
                return None
            if width > 480:
                rgb = rgb.resize((480, max(8, int(480 * height / width))), Image.Resampling.NEAREST)
            letter = _center_public_letter(rgb)
            return letter if letter in {"A", "B"} else None
    except Exception:
        return None


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
    if suite == "journey-b":
        identities = [_classify_named(evidence_dir, name) for name in JOURNEY_B_STEPS]
        assert_round_trip(identities)
        return _report(suite, dict(zip(JOURNEY_B_STEPS, identities)))
    if suite == "tvos-flow":
        history = [_classify_named(evidence_dir, name) for name in JOURNEY_B_STEPS]
        assert_round_trip(history)
        identities = [_classify_named(evidence_dir, name) for name in TVOS_FLOW_STEPS]
        assert_pause_hold(identities[0], identities[1])
        assert_resumed_advanced(identities[1], identities[2])
        steps = dict(zip(JOURNEY_B_STEPS, history))
        steps.update(dict(zip(TVOS_FLOW_STEPS, identities)))
        return _report(suite, steps)

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
