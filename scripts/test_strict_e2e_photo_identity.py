#!/usr/bin/env python3
"""On-screen photo identification of public fixtures: negative cases must fail; no relying on asset IDs or probes."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch
from collections.abc import Mapping
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageOps


SCRIPT_DIR = Path(__file__).resolve().parent

from strict_e2e_photo_identity import (  # noqa: E402
    IdentityAssertionError,
    assert_exif_correspondence,
    assert_pause_hold,
    assert_required_frames,
    assert_resumed_advanced,
    assert_round_trip,
    classify_public_pattern,
    classify_screenshot,
    evaluate_visual_identity,
    overlay_model_from_text,
    public_frame_letter_from_bytes,
    public_frame_photos_from_bytes,
    _public_bitmap_bands,
    _public_letters_for_cells,
    public_asset_reference,
    PUBLIC_SCENE_GEOMETRIES,
)
from strict_e2e_server import GLYPHS, _fixture_data, _png as fixture_png  # noqa: E402
from test_album_server_narrow_contract import IPHONE_SCREEN  # noqa: E402


REVIEWED_SCREENSHOT_RELATIVE_PATHS = (
    "iphone-history/01-auto-A2.png",
    "iphone-history/03-next-A3.png",
    "iphone-history/04-next-A4.png",
    "iphone-history/05-previous-A3.png",
    "iphone-history/06-previous-A2.png",
    "ipad-history/01-auto-A2.png",
    "ipad-history/03-next-A4.png",
    "ipad-history/04-next-A5.png",
    "ipad-history/05-previous-A4.png",
    "ipad-history/06-previous-A2.png",
    "ipad-pause-window/03-after-pause-A2-no-Fixture3.png",
    "ipad-pause-window/02-window-detected-A2-with-Fixture3-boundary.png",
    "tvos-pause/01-pause-immediate-A4.png",
    "tvos-pause/02-pause-after-11.860-seconds-A4.png",
    "tvos-pause/03-resumed-advanced-A5.png",
)


def resolve_reviewed_screenshots_root(env: Mapping[str, str]) -> Path:
    raw = env.get("STRICT_E2E_REVIEWED_SCREENSHOTS")
    if raw is None or not str(raw).strip():
        raise unittest.SkipTest("STRICT_E2E_REVIEWED_SCREENSHOTS is not set")
    root = Path(raw)
    if not root.is_dir():
        raise AssertionError(f"STRICT_E2E_REVIEWED_SCREENSHOTS is set but the directory does not exist: {root}")
    missing = [
        relative
        for relative in REVIEWED_SCREENSHOT_RELATIVE_PATHS
        if not (root / relative).is_file()
    ]
    if missing:
        raise AssertionError("Calibration screenshots missing: " + ", ".join(missing))
    return root


class ReviewedScreenshotRootResolutionTests(unittest.TestCase):
    def test_unset_env_skips_calibration(self) -> None:
        with self.assertRaises(unittest.SkipTest) as raised:
            resolve_reviewed_screenshots_root({})
        self.assertIn("STRICT_E2E_REVIEWED_SCREENSHOTS", str(raised.exception))

    def test_empty_env_skips_even_when_cwd_has_calibration_files(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            for relative in REVIEWED_SCREENSHOT_RELATIVE_PATHS:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"not-a-real-screenshot")
            previous = os.getcwd()
            try:
                os.chdir(root)
                with self.assertRaises(unittest.SkipTest):
                    resolve_reviewed_screenshots_root({})
                with self.assertRaises(unittest.SkipTest):
                    resolve_reviewed_screenshots_root({"STRICT_E2E_REVIEWED_SCREENSHOTS": ""})
                with self.assertRaises(unittest.SkipTest):
                    resolve_reviewed_screenshots_root({"STRICT_E2E_REVIEWED_SCREENSHOTS": "   "})
            finally:
                os.chdir(previous)

    def test_set_missing_directory_fails_instead_of_skip(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            missing = Path(raw_directory) / "absent"
            with self.assertRaises(AssertionError) as raised:
                resolve_reviewed_screenshots_root(
                    {"STRICT_E2E_REVIEWED_SCREENSHOTS": str(missing)}
                )
            self.assertIn("does not exist", str(raised.exception))
            self.assertNotIsInstance(raised.exception, unittest.SkipTest)

    def test_set_directory_missing_files_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            with self.assertRaises(AssertionError) as raised:
                resolve_reviewed_screenshots_root(
                    {"STRICT_E2E_REVIEWED_SCREENSHOTS": raw_directory}
                )
            self.assertIn("Calibration screenshots missing", str(raised.exception))
            self.assertIn("iphone-history/01-auto-A2.png", str(raised.exception))

    def test_set_complete_directory_returns_that_path(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            for relative in REVIEWED_SCREENSHOT_RELATIVE_PATHS:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"present")
            self.assertEqual(
                resolve_reviewed_screenshots_root(
                    {"STRICT_E2E_REVIEWED_SCREENSHOTS": str(root)}
                ),
                root,
            )


def _png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def _solid(color: tuple[int, int, int], size: tuple[int, int] = (320, 568)) -> bytes:
    return _png(Image.new("RGB", size, color))


def _fixture_png(label: str) -> bytes:
    return _fixture_data("a")["images"][f"asset-a-{label[-1]}"]


def _write_scene_sequence(evidence: Path, names_and_marks: list[tuple[str, tuple[str, ...]]], fixture_set: str = "a") -> None:
    from strict_e2e_filter_contract import write_member_manifest
    write_member_manifest(evidence / "member-manifest.json", fixture_set)
    for name, marks in names_and_marks:
        refs = ",".join(public_asset_reference(f"asset-{fixture_set}-{mark[-1]}") for mark in marks)
        publication = {"history-start": 1, "history-first-next": 2, "history-second-next": 3,
                       "history-first-previous": 4, "history-second-previous": 5,
                       "pause-immediate": 6, "pause-after-10s": 6, "resumed": 7}[name]
        observation = {"manifest": f"ledgerSceneAssets={refs};slotCount={len(marks)};slotReadiness={','.join(['ready'] * len(marks))};gapPixelCount=0;overlapPixelCount=0;canvasCoverage=1;emptyCanvasRatio=0;actionTimestamp={publication};scenePublishTimestamp={publication + 0.001};publishReason=next",
                       "render": "phase=stablePhoto;layerRoles=stable;loadingVisible=false",
                       "index": f"{marks[0][-1]}/5"}
        (evidence / f"{name}.scene.json").write_text(json.dumps({"before": observation, "after": observation}))


def _darken(png: bytes, factor: float) -> bytes:
    with Image.open(io.BytesIO(png)) as image:
        darkened = ImageEnhance.Brightness(image.convert("RGB")).enhance(factor)
        return _png(darkened)


def _crop_center(png: bytes, box_ratio: float = 0.55) -> bytes:
    with Image.open(io.BytesIO(png)) as image:
        rgb = image.convert("RGB")
        width, height = rgb.size
        crop_w = int(width * box_ratio)
        crop_h = int(height * box_ratio)
        left = (width - crop_w) // 2
        top = (height - crop_h) // 2
        return _png(rgb.crop((left, top, left + crop_w, top + crop_h)))


def _blend(left_png: bytes, right_png: bytes) -> bytes:
    with Image.open(io.BytesIO(left_png)) as left, Image.open(io.BytesIO(right_png)) as right:
        a = left.convert("RGB").resize((360, 640))
        b = right.convert("RGB").resize((360, 640))
        split = Image.new("RGB", (360, 640))
        split.paste(a.crop((0, 0, 180, 640)), (0, 0))
        split.paste(b.crop((180, 0, 360, 640)), (180, 0))
        return _png(split)


def _noise() -> bytes:
    image = Image.new("RGB", (320, 568))
    pixels = image.load()
    assert pixels is not None
    for y in range(568):
        for x in range(320):
            pixels[x, y] = ((x * 13 + y * 7) % 256, (x * 5 + y * 17) % 256, (x * 29 + y) % 256)
    return _png(image.filter(ImageFilter.GaussianBlur(radius=8)))


def _with_exif_card(png: bytes, model: str) -> bytes:
    with Image.open(io.BytesIO(png)) as image:
        rgb = image.convert("RGB").resize((390, 844))
        draw = ImageDraw.Draw(rgb, "RGBA")
        draw.rounded_rectangle((230, 24, 378, 150), radius=16, fill=(40, 80, 70, 180))
        draw.text((242, 40), f"immichSlides Synthetic {model}", fill=(255, 255, 255, 255))
        return _png(rgb.convert("RGB"))


class FrameGlyphBoundaryTests(unittest.TestCase):
    def test_scene_judgement_converts_a_second_clear_background_photo_to_identity_failure(self) -> None:
        photo = Image.open(io.BytesIO(_fixture_png("A1"))).convert("RGB")
        scene = ImageOps.fit(photo, (320, 696)).filter(ImageFilter.GaussianBlur(40))
        scene.paste(photo, (0, 258))
        foreign = Image.open(io.BytesIO(_fixture_png("A2"))).convert("RGB")
        scene.paste(ImageOps.fit(foreign, (112, 112)), (8, 100))
        names = ("history-start", "history-first-next", "history-second-next", "history-first-previous", "history-second-previous")
        for suite in ("journey-b", "tvos-flow"):
            with self.subTest(suite=suite), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                for name in names:
                    (evidence / f"{name}.png").write_bytes(_fixture_png("A1"))
                (evidence / "history-start.png").write_bytes(_png(scene))
                _write_scene_sequence(evidence, [(name, ("A1",)) for name in names])
                with self.assertRaisesRegex(IdentityAssertionError, "single-photo surround still"):
                    evaluate_visual_identity(evidence, suite)

    def test_palette_interpolation_is_unique_and_confined_to_eight_raw_edge_pixels(self) -> None:
        from strict_e2e_photo_identity import _public_palette_edge_assignment, _public_frame_slots
        self.assertEqual(_public_palette_edge_assignment((77, 74, 72)), "A1")
        for color in ((0, 0, 0), (255, 255, 255), (56, 140, 28)):
            with self.subTest(color=color):
                self.assertIsNone(_public_palette_edge_assignment(color))
        with patch("strict_e2e_photo_identity._public_photo_palettes", return_value={
            "A1": ((0, 50, 100), (100, 50, 0)), "A2": ((0, 50, 0), (100, 50, 100)),
        }):
            self.assertIsNone(_public_palette_edge_assignment((50, 50, 50)))
        for horizontal in (False, True):
            with self.subTest(horizontal=horizontal):
                frame = Image.open(io.BytesIO(_fixture_png("A1"))).convert("RGB")
                draw = ImageDraw.Draw(frame)
                box = (frame.width - 8, 0, frame.width - 1, frame.height - 1) if horizontal else (0, frame.height - 8, frame.width - 1, frame.height - 1)
                draw.rectangle(box, fill=(77, 74, 72))
                self.assertEqual(len(_public_frame_slots(frame, edge_band_pixels=(8, 8))[0]), 1)
                for color in ((0, 0, 0), (255, 255, 255), (56, 140, 28)):
                    draw.rectangle(box, fill=color)
                    with self.assertRaises(IdentityAssertionError):
                        _public_frame_slots(frame, edge_band_pixels=(8, 8))
                draw.rectangle(box, fill=(77, 74, 72))
                interior = Image.blend(frame, Image.open(io.BytesIO(_fixture_png("A2"))).convert("RGB").resize(frame.size), 0.5)
                with self.assertRaises(IdentityAssertionError):
                    _public_frame_slots(interior, edge_band_pixels=(8, 8))
                ImageDraw.Draw(interior).rectangle(box, fill=(77, 74, 72))
                with self.assertRaises(IdentityAssertionError):
                    _public_frame_slots(interior, edge_band_pixels=(8, 8))
                wider = (frame.width - 9, 0, frame.width - 1, frame.height - 1) if horizontal else (0, frame.height - 9, frame.width - 1, frame.height - 1)
                draw.rectangle(wider, fill=(77, 74, 72))
                with self.assertRaises(IdentityAssertionError):
                    _public_frame_slots(frame, edge_band_pixels=(8, 8))

    def test_overlay_fragments_are_joined_before_the_full_glyph_height_gate(self) -> None:
        source = Image.open(io.BytesIO(_fixture_png("A4"))).convert("RGB")
        # A measured overlay cuts a full-size glyph, leaving a tail shorter than ten sampled rows.
        frame = source.resize((900, 600), Image.Resampling.NEAREST)
        box = (0, 360, 900, 466)
        ImageDraw.Draw(frame).rectangle((0, 360, 899, 465), fill=(40, 40, 40))
        self.assertEqual([p.mark for p in public_frame_photos_from_bytes(_png(frame), glyph_overlay_box=box)], ["A4"])
        self.assertEqual(_public_bitmap_bands([[True]] * 2), [])

    def test_measured_tv_overlay_cannot_supply_a_missing_slot_glyph(self) -> None:
        from strict_e2e_photo_identity import public_scene_photos_from_bytes
        for fixture_set in ("a", "b"):
            for unreadable in (False, True):
                with self.subTest(fixture=fixture_set, unreadable=unreadable):
                    frame = Image.open(io.BytesIO(self._pair(fixture_set, 2, 3, horizontal=True, seam=1382, unreadable=unreadable))).convert("RGB")
                    draw = ImageDraw.Draw(frame)
                    # Measured hint and control rectangles, bounded by the registered four-pixel margin.
                    draw.rectangle((1330, 1440, 2086, 1650), fill="white")
                    draw.rectangle((1260, 1717, 2576, 1920), fill="white")
                    if unreadable:
                        with self.assertRaises(IdentityAssertionError):
                            public_scene_photos_from_bytes(_png(frame))
                    else:
                        self.assertEqual([p.mark for p in public_scene_photos_from_bytes(_png(frame))], ["A2", "A3"])

    def test_single_slot_clipped_glyph_uses_color_and_texture_on_every_geometry(self) -> None:
        from test_album_server_narrow_contract import _full_screen
        from strict_e2e_photo_identity import public_scene_photos_from_bytes
        for fixture_set in ("a", "b"):
            for size in ((1170, 2532), (1640, 2360), (3840, 2160)):
                with self.subTest(fixture=fixture_set, size=size):
                    frame = _full_screen("A1", size, fixture_set)
                    self.assertEqual(public_scene_photos_from_bytes(frame)[0].letter, fixture_set.upper())
                    self.assertEqual(public_scene_photos_from_bytes(frame)[0].mark, "A1")
                    for bad in (_solid((0, 0, 0), size), _solid((255, 255, 255), size)):
                        with self.assertRaises(IdentityAssertionError):
                            public_scene_photos_from_bytes(bad)

    def test_history_compares_all_slots_and_cross_checks_scene_probes(self) -> None:
        names = ("history-start", "history-first-next", "history-second-next", "history-first-previous", "history-second-previous")
        marks = [("A5",), ("A1", "A5"), ("A4",), ("A1", "A5"), ("A5",)]
        for fixture_set in ("a", "b"):
            with self.subTest(fixture=fixture_set), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                single = _fixture_data(fixture_set)["images"][f"asset-{fixture_set}-5"]
                pair = self._pair(fixture_set, 1, 5, horizontal=False)
                second = _fixture_data(fixture_set)["images"][f"asset-{fixture_set}-4"]
                for name, png in zip(names, (single, pair, second, pair, single)):
                    (evidence / f"{name}.png").write_bytes(png)
                _write_scene_sequence(evidence, list(zip(names, marks)), fixture_set)
                report = evaluate_visual_identity(evidence, "journey-b")
                self.assertEqual(report["steps"][names[0]]["signature"], [f"{fixture_set.upper()}5"])
                self.assertEqual(report["steps"][names[1]]["signature"], [f"{fixture_set.upper()}1", f"{fixture_set.upper()}5"])
                swapped = self._pair(fixture_set, 5, 1, horizontal=False)
                (evidence / f"{names[3]}.png").write_bytes(swapped)
                _write_scene_sequence(evidence, [(names[3], ("A5", "A1"))], fixture_set)
                with self.assertRaisesRegex(IdentityAssertionError, "first back step"):
                    evaluate_visual_identity(evidence, "journey-b")
                (evidence / f"{names[3]}.png").write_bytes(single)
                _write_scene_sequence(evidence, [(names[3], ("A5",))], fixture_set)
                with self.assertRaisesRegex(IdentityAssertionError, "first back step"):
                    evaluate_visual_identity(evidence, "journey-b")
                (evidence / f"{names[3]}.png").write_bytes(pair)
                _write_scene_sequence(evidence, [(names[3], ("A1", "A5"))], fixture_set)
                sidecar = evidence / f"{names[0]}.scene.json"
                original = sidecar.read_text()
                for field, value in (("manifest", "ledgerSceneAssets=foreign;slotCount=1;slotReadiness=ready"),
                                     ("render", "phase=transition;layerRoles=outgoing|incoming;loadingVisible=false")):
                    payload = json.loads(original)
                    payload["after"][field] = value
                    sidecar.write_text(json.dumps(payload))
                    with self.assertRaises(IdentityAssertionError):
                        evaluate_visual_identity(evidence, "journey-b")
                sidecar.unlink()
                with self.assertRaisesRegex(IdentityAssertionError, "scene sequence evidence"):
                    evaluate_visual_identity(evidence, "journey-b")

    def test_pinned_devices_have_measured_scene_geometries(self) -> None:
        pins = json.loads((SCRIPT_DIR / "ci-pins.json").read_text())
        sizes = {"iPhone 17e": (1170, 2532), "iPad Air 11-inch (M4)": (1640, 2360),
                 "Apple TV 4K (3rd generation)": (3840, 2160)}
        for device in pins["device_types"].values():
            self.assertIn(device, sizes, "A newly pinned device needs real scene-frame measurements")
            self.assertIn(sizes[device], PUBLIC_SCENE_GEOMETRIES)

    def test_real_tv_horizontal_slots_use_the_same_reader_as_vertical_slots(self) -> None:
        # Measured tvOS 27.0 captures: 3840x2160, A2/A3 seam x=1382,
        # A5/A3 seam x=1536. Reconstruct the public photos at those sizes.
        for fixture_set in ("a", "b"):
            for first, seam in ((2, 1382), (5, 1536)):
                with self.subTest(fixture=fixture_set, first=first):
                    frame = self._pair(fixture_set, first, 3, horizontal=True, seam=seam)
                    self.assertEqual(Image.open(io.BytesIO(frame)).size, (3840, 2160))
                    self.assertEqual([(p.letter, p.mark) for p in public_frame_photos_from_bytes(frame)],
                                     [(fixture_set.upper(), f"A{first}"), (fixture_set.upper(), "A3")])

    @staticmethod
    def _pair(fixture_set: str, first: int, second: int, *, horizontal: bool,
              seam: int | None = None, second_fixture: str | None = None,
              unreadable: bool = False) -> bytes:
        size = (3840, 2160) if horizontal else (1640, 2360)
        boundary = seam or (size[0] // 2 if horizontal else size[1] // 2)
        boxes = ((0, 0, boundary, size[1]), (boundary, 0, size[0], size[1])) if horizontal else (
            (0, 0, size[0], boundary), (0, boundary, size[0], size[1]))
        frame = Image.new("RGB", size)
        for index, source, box in zip((first, second), (fixture_set, second_fixture or fixture_set), boxes):
            photo = Image.open(io.BytesIO(_fixture_data(source)["images"][f"asset-{source}-{index}"]))
            if unreadable and box == boxes[0]:
                photo = Image.open(io.BytesIO(fixture_png(*photo.size, index, "", striped=source == "b")))
            frame.paste(ImageOps.fit(photo, (box[2] - box[0], box[3] - box[1]), method=Image.Resampling.BILINEAR), box)
        return _png(frame)

    def test_both_slot_orientations_reject_mixed_and_unreadable_fixtures(self) -> None:
        from strict_e2e_photo_identity import public_scene_photos_from_bytes
        for horizontal in (False, True):
            for fixture_set in ("a", "b"):
                other = "b" if fixture_set == "a" else "a"
                for name, options in (("mixed", {"second_fixture": other}),
                                      ("unreadable", {"unreadable": True}),
                                      ("foreign unreadable", {"second_fixture": other, "unreadable": True})):
                    with self.subTest(horizontal=horizontal, fixture=fixture_set, case=name):
                        with self.assertRaises(IdentityAssertionError):
                            public_frame_photos_from_bytes(self._pair(fixture_set, 5, 3, horizontal=horizontal, **options))
                with self.subTest(horizontal=horizontal, fixture=fixture_set, case="same photo number with unreadable foreign fixture"):
                    with self.assertRaises(IdentityAssertionError):
                        public_scene_photos_from_bytes(self._pair(fixture_set, 5, 5, horizontal=horizontal,
                                                                 second_fixture=other, unreadable=True))

    def test_two_dimensional_grid_and_blended_slots_fail_unreadable(self) -> None:
        grid = Image.new("RGB", (3840, 2160))
        for index, box in enumerate(((0, 0, 1920, 1080), (1920, 0, 3840, 1080),
                                     (0, 1080, 1920, 2160), (1920, 1080, 3840, 2160)), 1):
            photo = Image.open(io.BytesIO(_fixture_png(f"A{index}")))
            grid.paste(photo.resize((1920, 1080)), box)
        with self.assertRaisesRegex(IdentityAssertionError, "unreadable public glyph slot"):
            public_frame_photos_from_bytes(_png(grid))
        for horizontal in (False, True):
            frame = self._pair("a", 5, 3, horizontal=horizontal)
            with Image.open(io.BytesIO(frame)) as image:
                mixed = Image.blend(image, Image.new("RGB", image.size, (20, 20, 20)), 0.5)
                with self.assertRaises(IdentityAssertionError):
                    public_frame_photos_from_bytes(_png(mixed))

    def test_real_size_crop_requires_two_letter_columns_and_never_accepts_only_the_digit(self) -> None:
        for fixture_set in ("a", "b"):
            source = Image.open(io.BytesIO(_fixture_data(fixture_set)["images"][f"asset-{fixture_set}-4"])).convert("RGB")
            scale = IPHONE_SCREEN[1] / source.height
            enlarged = source.resize((round(source.width * scale), IPHONE_SCREEN[1]), Image.Resampling.BILINEAR)
            # A4/B4's letter starts at x=70 with 20px cells. Preserve the Release
            # scale and vertical crop; only pan horizontally at the column boundary.
            for case, source_left, expected in (("two letter columns", 130, fixture_set.upper()),
                                                 ("one letter column", 150, None), ("digit only", 190, None)):
                with self.subTest(fixture_set=fixture_set, case=case):
                    left = round(source_left * scale)
                    frame = enlarged.crop((left, 0, left + IPHONE_SCREEN[0], IPHONE_SCREEN[1]))
                    self.assertEqual(public_frame_letter_from_bytes(_png(frame)), expected)

    def test_observed_cell_and_ink_boundaries_reject_insufficient_evidence(self) -> None:
        for letter in ("A", "B"):
            glyph = GLYPHS[letter]
            observed = [(row, column, glyph[row][column] == "1") for row in range(7) for column in (0, 4)]
            with self.subTest(letter=letter, case="fourteen cells"):
                self.assertEqual(_public_letters_for_cells(observed), [letter])
                self.assertEqual(_public_letters_for_cells(observed[:-1]), [])
                self.assertEqual(_public_letters_for_cells(observed[::2]), [])
            ink = [cell for cell in observed if cell[2]]
            background = [(row, column, False) for row in range(7) for column in range(5) if glyph[row][column] == "0"]
            with self.subTest(letter=letter, case="five white cells"):
                self.assertEqual(_public_letters_for_cells(ink[:5] + background[:9]), [letter])
                self.assertEqual(_public_letters_for_cells(ink[:4] + background[:10]), [])

    def test_bitmap_bands_pin_minimum_height_and_four_blank_rows(self) -> None:
        self.assertEqual(_public_bitmap_bands([[True]] * 9), [])
        self.assertEqual(_public_bitmap_bands([[True]] * 10), [(0, 10)])
        self.assertEqual(_public_bitmap_bands([[True]] * 10 + [[False]] * 4 + [[True]] * 10), [(0, 24)])
        self.assertEqual(_public_bitmap_bands([[True]] * 10 + [[False]] * 5 + [[True]] * 10), [(0, 10), (15, 25)])

    def test_public_palette_tolerance_and_digit_agreement_fail_closed(self) -> None:
        for fixture_set in ("a", "b"):
            source = Image.open(io.BytesIO(_fixture_data(fixture_set)["images"][f"asset-{fixture_set}-4"])).convert("RGB")
            for delta, expected in ((12, fixture_set.upper()), (13, None)):
                with self.subTest(fixture_set=fixture_set, channel_delta=delta):
                    shifted = source.copy()
                    shifted.putdata([color if min(color) >= 240 else tuple(channel + delta for channel in color) for color in source.getdata()])
                    self.assertEqual(public_frame_letter_from_bytes(_png(shifted)), expected)
            with self.subTest(fixture_set=fixture_set, case="wrong visible digit"):
                self.assertIsNone(public_frame_letter_from_bytes(fixture_png(360, 240, 4, f"{fixture_set.upper()}2", striped=fixture_set == "b")))


class NegativeIdentityTests(unittest.TestCase):
    def test_all_black_is_rejected_not_matched(self) -> None:
        result = classify_screenshot(_solid((0, 0, 0)))
        self.assertEqual(result.status, "BLACK")
        self.assertIsNone(result.mark)
        with self.assertRaises(IdentityAssertionError) as raised:
            assert_round_trip([result] * 5)
        self.assertIn("BLACK", str(raised.exception))

    def test_blank_white_is_rejected_not_matched(self) -> None:
        result = classify_screenshot(_solid((255, 255, 255)))
        self.assertEqual(result.status, "BLANK")
        self.assertIsNone(result.mark)

    def test_empty_bytes_are_unreadable_not_success(self) -> None:
        result = classify_screenshot(b"")
        self.assertEqual(result.status, "UNRECOGNIZABLE")
        self.assertIsNone(result.mark)

    def test_noise_is_unrecognizable(self) -> None:
        result = classify_screenshot(_noise())
        self.assertEqual(result.status, "UNRECOGNIZABLE")
        self.assertIsNone(result.mark)

    def test_wrong_photo_fails_round_trip_return(self) -> None:
        start = classify_screenshot(_fixture_png("A2"))
        first = classify_screenshot(_fixture_png("A3"))
        second = classify_screenshot(_fixture_png("A4"))
        wrong_return = classify_screenshot(_fixture_png("A5"))
        with self.assertRaises(IdentityAssertionError) as raised:
            assert_round_trip([start, first, second, first, wrong_return])
        self.assertIn("return to the original photo", str(raised.exception))

    def test_unrecognizable_step_cannot_pass_round_trip(self) -> None:
        start = classify_screenshot(_fixture_png("A2"))
        with self.assertRaises(IdentityAssertionError):
            assert_round_trip(
                [
                    start,
                    classify_screenshot(_noise()),
                    classify_screenshot(_fixture_png("A4")),
                    classify_screenshot(_noise()),
                    start,
                ]
            )

    def test_transition_blend_is_not_a_match(self) -> None:
        result = classify_screenshot(_blend(_fixture_png("A2"), _fixture_png("A3")))
        self.assertIn(result.status, ("TRANSITION", "UNRECOGNIZABLE"))
        self.assertIsNone(result.mark)

    def test_wrong_exif_on_a2_is_rejected(self) -> None:
        identity = classify_screenshot(_fixture_png("A2"))
        self.assertEqual(identity.status, "MATCH")
        self.assertEqual(identity.mark, "A2")
        with self.assertRaises(IdentityAssertionError) as raised:
            assert_exif_correspondence(identity, "immichSlides Synthetic Fixture 3")
        self.assertIn("EXIF", str(raised.exception))

    def test_server_b_pattern_is_distinct_while_color_marks_stay(self) -> None:
        for index in range(1, 6):
            image_a = _fixture_data("a")["images"][f"asset-a-{index}"]
            image_b = _fixture_data("b")["images"][f"asset-b-{index}"]
            color_a = classify_screenshot(image_a)
            color_b = classify_screenshot(image_b)
            self.assertEqual(color_a.status, "MATCH")
            self.assertEqual(color_b.status, "MATCH")
            self.assertEqual(color_a.mark, f"A{index}")
            self.assertEqual(color_b.mark, f"A{index}")
            self.assertEqual(classify_public_pattern(image_a), "a")
            self.assertEqual(classify_public_pattern(image_b), "b")
            self.assertNotEqual(image_a, image_b)

    def test_missing_expected_exif_on_a3_is_rejected(self) -> None:
        identity = classify_screenshot(_fixture_png("A3"))
        with self.assertRaises(IdentityAssertionError):
            assert_exif_correspondence(identity, "")

    def test_wrong_exif_number_on_a3_is_rejected(self) -> None:
        identity = classify_screenshot(_fixture_png("A3"))
        with self.assertRaises(IdentityAssertionError):
            assert_exif_correspondence(identity, "Fixture 1")

    def test_unrecognizable_photo_cannot_pass_exif_check(self) -> None:
        identity = classify_screenshot(_solid((0, 0, 0)))
        with self.assertRaises(IdentityAssertionError):
            assert_exif_correspondence(identity, "")

    def test_pause_hold_rejects_changed_photo(self) -> None:
        with self.assertRaises(IdentityAssertionError):
            assert_pause_hold(
                classify_screenshot(_fixture_png("A4")),
                classify_screenshot(_fixture_png("A5")),
            )

    def test_pause_hold_rejects_black_after_wait(self) -> None:
        with self.assertRaises(IdentityAssertionError):
            assert_pause_hold(
                classify_screenshot(_fixture_png("A4")),
                classify_screenshot(_solid((0, 0, 0))),
            )

    def test_resume_rejects_same_photo(self) -> None:
        paused = classify_screenshot(_fixture_png("A4"))
        with self.assertRaises(IdentityAssertionError):
            assert_resumed_advanced(paused, paused)

    def test_missing_required_frames_cannot_succeed(self) -> None:
        with self.assertRaises(IdentityAssertionError) as raised:
            assert_required_frames(
                {"after-pause": True},
                required=("window-detected", "after-pause", "after-pause-0_3s"),
            )
        self.assertIn("window-detected", str(raised.exception))

    def test_overlay_parser_does_not_treat_asset_id_as_exif(self) -> None:
        self.assertIsNone(overlay_model_from_text("asset-a-3"))
        self.assertIsNone(overlay_model_from_text("currentAssetId=asset-a-3"))
        self.assertEqual(overlay_model_from_text("Fixture 3 | 50mm"), "Fixture 3")

    def test_evaluate_journey_b_rejects_missing_or_wrong_frames(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            with self.assertRaises(IdentityAssertionError) as raised:
                evaluate_visual_identity(evidence, "journey-b")
            self.assertIn("history-start.png", str(raised.exception))

            names = (
                "history-start",
                "history-first-next",
                "history-second-next",
                "history-first-previous",
                "history-second-previous",
            )
            pngs = [_fixture_png(label) for label in ("A2", "A3", "A4", "A3", "A5")]
            for name, payload in zip(names, pngs):
                (evidence / f"{name}.png").write_bytes(payload)
            _write_scene_sequence(evidence, list(zip(names, [(mark,) for mark in ("A2", "A3", "A4", "A3", "A5")])))
            (evidence / "history-start.png").write_bytes(_solid((0, 0, 0)))
            with self.assertRaises(IdentityAssertionError):
                evaluate_visual_identity(evidence, "journey-b")
            (evidence / "history-start.png").write_bytes(_fixture_png("A2"))
            with self.assertRaises(IdentityAssertionError) as raised:
                evaluate_visual_identity(evidence, "journey-b")
            self.assertIn("return to the original photo", str(raised.exception))

    def _write_pause_window(
        self,
        evidence: Path,
        *,
        window_png: bytes,
        overlay: str = "",
    ) -> None:
        (evidence / "window-detected.png").write_bytes(window_png)
        (evidence / "after-pause.png").write_bytes(_fixture_png("A2"))
        (evidence / "after-pause-0_3s.png").write_bytes(_fixture_png("A2"))
        (evidence / "after-pause.overlay.txt").write_text(overlay, encoding="utf-8")

    def test_evaluate_pause_window_rejects_missing_window_and_wrong_exif(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "after-pause.png").write_bytes(_fixture_png("A2"))
            (evidence / "after-pause-0_3s.png").write_bytes(_fixture_png("A2"))
            with self.assertRaises(IdentityAssertionError) as raised:
                evaluate_visual_identity(evidence, "pause-window")
            self.assertIn("window-detected", str(raised.exception))
            (evidence / "window-detected.png").write_bytes(_fixture_png("A2"))
            (evidence / "after-pause.overlay.txt").write_text("Fixture 3", encoding="utf-8")
            with self.assertRaises(IdentityAssertionError) as raised:
                evaluate_visual_identity(evidence, "pause-window")
            self.assertIn("EXIF", str(raised.exception))

    def test_evaluate_pause_window_rejects_wrong_or_unreadable_window_detected(self) -> None:
        cases = {
            "black": _solid((0, 0, 0)),
            "blank": _solid((255, 255, 255)),
            "unrecognizable": _noise(),
            "wrong-photo": _fixture_png("A5"),
        }
        for label, window_png in cases.items():
            with self.subTest(window=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                self._write_pause_window(evidence, window_png=window_png)
                with self.assertRaises(IdentityAssertionError) as raised:
                    evaluate_visual_identity(evidence, "pause-window")
                message = str(raised.exception)
                self.assertIn("Target window", message)
                if label == "wrong-photo":
                    self.assertIn("wrong image", message)
                else:
                    self.assertIn("not recognized", message)

    def test_evaluate_pause_window_allows_window_exif_mismatch_on_a2_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_pause_window(
                evidence,
                window_png=_with_exif_card(_fixture_png("A2"), "Fixture 3"),
            )
            report = evaluate_visual_identity(evidence, "pause-window")
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["steps"]["window-detected"]["mark"], "A2")
            self.assertEqual(report["steps"]["after-pause"]["mark"], "A2")

    def _write_tvos_history(self, evidence: Path, labels: tuple[str, ...] = ("A2", "A3", "A4", "A3", "A2")) -> None:
        for name, label in zip(
            (
                "history-start",
                "history-first-next",
                "history-second-next",
                "history-first-previous",
                "history-second-previous",
            ),
            labels,
        ):
            (evidence / f"{name}.png").write_bytes(_fixture_png(label))
        _write_scene_sequence(evidence, list(zip(("history-start", "history-first-next", "history-second-next", "history-first-previous", "history-second-previous"), [(mark,) for mark in labels])))

    def test_evaluate_tvos_flow_rejects_changed_pause_frame(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_tvos_history(evidence)
            (evidence / "pause-immediate.png").write_bytes(_fixture_png("A4"))
            (evidence / "pause-after-10s.png").write_bytes(_fixture_png("A5"))
            (evidence / "resumed.png").write_bytes(_fixture_png("A5"))
            _write_scene_sequence(evidence, [("pause-immediate", ("A4",)), ("pause-after-10s", ("A5",)), ("resumed", ("A5",))])
            with self.assertRaises(IdentityAssertionError):
                evaluate_visual_identity(evidence, "tvos-flow")

    def test_evaluate_tvos_flow_rejects_missing_history_frames(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "pause-immediate.png").write_bytes(_fixture_png("A4"))
            (evidence / "pause-after-10s.png").write_bytes(_fixture_png("A4"))
            (evidence / "resumed.png").write_bytes(_fixture_png("A5"))
            with self.assertRaises(IdentityAssertionError) as raised:
                evaluate_visual_identity(evidence, "tvos-flow")
            self.assertIn("history-start.png", str(raised.exception))


class PositiveIdentityTests(unittest.TestCase):
    def test_saturated_tv_index_uses_publications_for_next_pause_and_resume(self) -> None:
        names = ("history-start", "history-first-next", "history-second-next", "history-first-previous", "history-second-previous", "pause-immediate", "pause-after-10s", "resumed")
        marks = ("A1", "A2", "A3", "A2", "A1", "A4", "A4", "A5")
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            for name, mark in zip(names, marks):
                (evidence / f"{name}.png").write_bytes(_fixture_png(mark))
            _write_scene_sequence(evidence, list(zip(names, [(mark,) for mark in marks])))
            for name in names:
                path = evidence / f"{name}.scene.json"
                payload = json.loads(path.read_text())
                for point in ("before", "after"):
                    payload[point]["index"] = "5/5"
                path.write_text(json.dumps(payload))
            self.assertEqual(evaluate_visual_identity(evidence, "tvos-flow")["verdict"], "PASS")
            path = evidence / "history-start.scene.json"
            payload = json.loads(path.read_text())
            for point in ("before", "after"):
                fields = dict(item.split("=", 1) for item in payload[point]["manifest"].split(";"))
                fields.pop("actionTimestamp")
                fields.pop("scenePublishTimestamp")
                fields["publishReason"] = "initial"
                payload[point]["manifest"] = ";".join(f"{key}={value}" for key, value in fields.items())
            path.write_text(json.dumps(payload))
            self.assertEqual(evaluate_visual_identity(evidence, "tvos-flow")["verdict"], "PASS")

    def test_tv_publication_rejects_no_advance_pause_republication_and_unreadable_signals(self) -> None:
        names = ("history-start", "history-first-next", "history-second-next", "history-first-previous", "history-second-previous", "pause-immediate", "pause-after-10s", "resumed")
        marks = ("A1", "A2", "A3", "A2", "A1", "A4", "A4", "A5")
        cases = (("history-first-next", "1", "1.001"), ("history-second-next", "2", "2.001"),
                 ("resumed", "6", "6.001"), ("pause-after-10s", "8", "8.001"),
                 ("resumed", "nan", "nan"), ("resumed", "7", "6"),
                 ("resumed", None, None), ("resumed", "7", None))
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            for name, mark in zip(names, marks):
                (evidence / f"{name}.png").write_bytes(_fixture_png(mark))
            for saturated in (False, True):
                for name, action, published in cases:
                    with self.subTest(saturated=saturated, frame=name, action=action, published=published):
                        _write_scene_sequence(evidence, list(zip(names, [(mark,) for mark in marks])))
                        for frame in names:
                            path = evidence / f"{frame}.scene.json"
                            payload = json.loads(path.read_text())
                            for point in ("before", "after"):
                                if saturated:
                                    payload[point]["index"] = "5/5"
                                if frame == name:
                                    fields = dict(item.split("=", 1) for item in payload[point]["manifest"].split(";"))
                                    for key, value in (("actionTimestamp", action), ("scenePublishTimestamp", published)):
                                        if value is None:
                                            fields.pop(key)
                                        else:
                                            fields[key] = value
                                    payload[point]["manifest"] = ";".join(f"{key}={value}" for key, value in fields.items())
                            path.write_text(json.dumps(payload))
                        with self.assertRaises(IdentityAssertionError):
                            evaluate_visual_identity(evidence, "tvos-flow")

    def test_tvos_backward_history_does_not_rewind_the_forward_pool_cursor(self) -> None:
        names = ("history-start", "history-first-next", "history-second-next", "history-first-previous", "history-second-previous", "pause-immediate", "pause-after-10s", "resumed")
        labels = ("A1", "A2", "A3", "A2", "A1", "A4", "A4", "A5")
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            for name, label in zip(names, labels):
                (evidence / f"{name}.png").write_bytes(_fixture_png(label))
            _write_scene_sequence(evidence, list(zip(names, [(label,) for label in labels])))
            for name in names[3:5]:
                path = evidence / f"{name}.scene.json"
                data = json.loads(path.read_text())
                for point in ("before", "after"):
                    data[point]["index"] = "3/5"
                path.write_text(json.dumps(data))
            self.assertEqual(evaluate_visual_identity(evidence, "tvos-flow")["verdict"], "PASS")

    def test_vertical_photo_pair_requires_the_same_public_source(self) -> None:
        for first, second, expected in [("a", "a", "a"), ("b", "b", "b"),
                                         ("a", "b", None), ("b", "a", None)]:
            with self.subTest(first=first, second=second):
                image = Image.new("RGB", (400, 880), (0, 0, 0))
                for position, (source, index) in enumerate([(first, 3), (second, 2)]):
                    photo = Image.open(io.BytesIO(_fixture_data(source)["images"][f"asset-{source}-{index}"]))
                    image.paste(photo.resize((400, 400)), (0, 40 + position * 400))
                encoded = io.BytesIO()
                image.save(encoded, format="PNG")
                self.assertEqual(classify_public_pattern(encoded.getvalue()), expected)

    def test_vertical_pair_with_unreadable_source_letter_is_rejected(self) -> None:
        image = Image.new("RGB", (400, 880), (0, 0, 0))
        for position, index in enumerate([3, 2]):
            photo = Image.open(io.BytesIO(_fixture_data("a")["images"][f"asset-a-{index}"]))
            image.paste(photo.resize((400, 400)), (0, 40 + position * 400))
        ImageDraw.Draw(image).rectangle((80, 520, 320, 760), fill=(40, 40, 40))
        encoded = io.BytesIO()
        image.save(encoded, format="PNG")
        self.assertIsNone(classify_public_pattern(encoded.getvalue()))

    def test_original_public_fixtures_match_their_marks(self) -> None:
        for label in ("A1", "A2", "A3", "A4", "A5"):
            with self.subTest(label=label):
                result = classify_screenshot(_fixture_png(label))
                self.assertEqual(result.status, "MATCH", result.notes)
                self.assertEqual(result.mark, label)

    def test_cropped_and_dark_frames_keep_the_same_mark(self) -> None:
        for label in ("A2", "A3", "A4", "A5"):
            with self.subTest(label=label):
                cropped = classify_screenshot(_crop_center(_fixture_png(label)))
                dark = classify_screenshot(_darken(_fixture_png(label), 0.22))
                self.assertEqual(cropped.status, "MATCH", cropped.notes)
                self.assertEqual(cropped.mark, label)
                self.assertEqual(dark.status, "MATCH", dark.notes)
                self.assertEqual(dark.mark, label)

    def test_round_trip_does_not_assume_iphone_middle_sequence(self) -> None:
        iphone = [classify_screenshot(_fixture_png(label)) for label in ("A2", "A3", "A4", "A3", "A2")]
        ipad = [classify_screenshot(_fixture_png(label)) for label in ("A2", "A4", "A5", "A4", "A2")]
        assert_round_trip(iphone)
        assert_round_trip(ipad)
        self.assertNotEqual([item.mark for item in iphone[1:4]], [item.mark for item in ipad[1:4]])

    def test_matching_exif_is_accepted(self) -> None:
        assert_exif_correspondence(classify_screenshot(_fixture_png("A2")), "")
        assert_exif_correspondence(
            classify_screenshot(_fixture_png("A3")),
            "immichSlides Synthetic Fixture 3",
        )
        assert_exif_correspondence(
            classify_screenshot(_fixture_png("A5")),
            "Fixture 5",
        )

    def test_pause_hold_and_resume_on_public_marks(self) -> None:
        a4 = classify_screenshot(_fixture_png("A4"))
        a4_dark = classify_screenshot(_darken(_fixture_png("A4"), 0.3))
        a5 = classify_screenshot(_fixture_png("A5"))
        assert_pause_hold(a4, a4_dark)
        assert_resumed_advanced(a4, a5)

    def test_evaluate_visual_identity_accepts_public_fixture_sequences(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            for name, label in zip(
                (
                    "history-start",
                    "history-first-next",
                    "history-second-next",
                    "history-first-previous",
                    "history-second-previous",
                ),
                ("A2", "A4", "A5", "A4", "A2"),
            ):
                (evidence / f"{name}.png").write_bytes(_fixture_png(label))
            _write_scene_sequence(evidence, list(zip(("history-start", "history-first-next", "history-second-next", "history-first-previous", "history-second-previous"), [(mark,) for mark in ("A2", "A4", "A5", "A4", "A2")])))
            report = evaluate_visual_identity(evidence, "journey-b")
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["steps"]["history-first-next"]["signature"], ["A4"])

            pause = Path(raw_directory) / "pause"
            pause.mkdir()
            for name in ("window-detected", "after-pause", "after-pause-0_3s"):
                (pause / f"{name}.png").write_bytes(_fixture_png("A2"))
            (pause / "after-pause.overlay.txt").write_text("", encoding="utf-8")
            self.assertEqual(evaluate_visual_identity(pause, "pause-window")["verdict"], "PASS")

            tvos = Path(raw_directory) / "tvos"
            tvos.mkdir()
            for name, label in zip(
                (
                    "history-start",
                    "history-first-next",
                    "history-second-next",
                    "history-first-previous",
                    "history-second-previous",
                ),
                ("A4", "A5", "A1", "A5", "A4"),
            ):
                (tvos / f"{name}.png").write_bytes(_fixture_png(label))
            (tvos / "pause-immediate.png").write_bytes(_fixture_png("A4"))
            (tvos / "pause-after-10s.png").write_bytes(_fixture_png("A4"))
            (tvos / "resumed.png").write_bytes(_fixture_png("A5"))
            _write_scene_sequence(tvos, list(zip(("history-start", "history-first-next", "history-second-next", "history-first-previous", "history-second-previous", "pause-immediate", "pause-after-10s", "resumed"), [(mark,) for mark in ("A4", "A5", "A1", "A5", "A4", "A4", "A4", "A5")])))
            self.assertEqual(evaluate_visual_identity(tvos, "tvos-flow")["verdict"], "PASS")

    def test_exif_card_composite_does_not_change_a2_identity(self) -> None:
        result = classify_screenshot(_with_exif_card(_fixture_png("A2"), "Fixture 3"))
        self.assertEqual(result.status, "MATCH", result.notes)
        self.assertEqual(result.mark, "A2")
        with self.assertRaises(IdentityAssertionError):
            assert_exif_correspondence(result, "Fixture 3")


class ReviewedScreenshotCalibrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.root = resolve_reviewed_screenshots_root(os.environ)

    def _classify_file(self, relative: str):
        return classify_screenshot((self.root / relative).read_bytes())

    def test_iphone_history_round_trip_a2_a3_a4(self) -> None:
        steps = [
            self._classify_file("iphone-history/01-auto-A2.png"),
            self._classify_file("iphone-history/03-next-A3.png"),
            self._classify_file("iphone-history/04-next-A4.png"),
            self._classify_file("iphone-history/05-previous-A3.png"),
            self._classify_file("iphone-history/06-previous-A2.png"),
        ]
        self.assertEqual([item.mark for item in steps], ["A2", "A3", "A4", "A3", "A2"])
        assert_round_trip(steps)

    def test_ipad_history_round_trip_is_not_iphone_sequence(self) -> None:
        steps = [
            self._classify_file("ipad-history/01-auto-A2.png"),
            self._classify_file("ipad-history/03-next-A4.png"),
            self._classify_file("ipad-history/04-next-A5.png"),
            self._classify_file("ipad-history/05-previous-A4.png"),
            self._classify_file("ipad-history/06-previous-A2.png"),
        ]
        self.assertEqual([item.mark for item in steps], ["A2", "A4", "A5", "A4", "A2"])
        assert_round_trip(steps)

    def test_dark_paused_a2_is_still_a2_not_black(self) -> None:
        result = self._classify_file("ipad-pause-window/03-after-pause-A2-no-Fixture3.png")
        self.assertEqual(result.status, "MATCH", result.notes)
        self.assertEqual(result.mark, "A2")

    def test_transition_boundary_keeps_a2_and_rejects_fixture3(self) -> None:
        result = self._classify_file(
            "ipad-pause-window/02-window-detected-A2-with-Fixture3-boundary.png"
        )
        self.assertEqual(result.status, "MATCH", result.notes)
        self.assertEqual(result.mark, "A2")
        with self.assertRaises(IdentityAssertionError):
            assert_exif_correspondence(result, "Fixture 3")

    def test_tvos_pause_hold_and_resume(self) -> None:
        immediate = self._classify_file("tvos-pause/01-pause-immediate-A4.png")
        held = self._classify_file("tvos-pause/02-pause-after-11.860-seconds-A4.png")
        resumed = self._classify_file("tvos-pause/03-resumed-advanced-A5.png")
        self.assertEqual(immediate.mark, "A4")
        assert_pause_hold(immediate, held)
        assert_resumed_advanced(held, resumed)


if __name__ == "__main__":
    unittest.main()
