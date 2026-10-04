#!/usr/bin/env python3
"""On-screen photo identification of public fixtures: negative cases must fail; no relying on asset IDs or probes."""

from __future__ import annotations

import io
import os
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Mapping
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

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
)
from strict_e2e_server import _fixture_data  # noqa: E402


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

    def test_evaluate_tvos_flow_rejects_changed_pause_frame(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_tvos_history(evidence)
            (evidence / "pause-immediate.png").write_bytes(_fixture_png("A4"))
            (evidence / "pause-after-10s.png").write_bytes(_fixture_png("A5"))
            (evidence / "resumed.png").write_bytes(_fixture_png("A5"))
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
            report = evaluate_visual_identity(evidence, "journey-b")
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["steps"]["history-first-next"]["mark"], "A4")

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
            (tvos / "pause-after-10s.png").write_bytes(_darken(_fixture_png("A4"), 0.4))
            (tvos / "resumed.png").write_bytes(_fixture_png("A5"))
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


def _extract_swift_func(source: str, name: str) -> str:
    needle = f"func {name}("
    start = source.find(needle)
    if start < 0:
        raise AssertionError(f"iOS UITest lacks {name}; nil marks must not reach JSON via a heterogeneous array")
    line_start = source.rfind("\n", 0, start) + 1
    brace = source.find("{", start)
    if brace < 0:
        raise AssertionError(f"{name} has no function body")
    depth = 0
    for index in range(brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[line_start : index + 1].strip()
    raise AssertionError(f"{name} function body is not closed")


def _run_swift(source: str) -> str:
    with tempfile.TemporaryDirectory() as raw_directory:
        path = Path(raw_directory) / "nil_mark_json.swift"
        path.write_text(source, encoding="utf-8")
        completed = subprocess.run(
            ["swift", str(path)],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    if completed.returncode != 0:
        raise AssertionError((completed.stderr or completed.stdout).strip())
    return completed.stdout


class IOSVisualIdentityJSONEncodingTests(unittest.TestCase):
    def test_nil_mark_is_valid_json_object(self) -> None:
        source = (
            REPO_ROOT / "immichSlidesUITests" / "StrictE2EFirstBatchIOSUITests.swift"
        ).read_text(encoding="utf-8")
        helper = _extract_swift_func(source, "jsonSafeMarks")
        output = _run_swift(
            "\n".join(
                [
                    "import Foundation",
                    helper,
                    "let payload: [String: Any] = [",
                    '    "marks": jsonSafeMarks([nil, "A2", nil])',
                    "]",
                    "guard JSONSerialization.isValidJSONObject(payload) else {",
                    '    fputs("invalid JSON object\\n", stderr)',
                    "    exit(1)",
                    "}",
                    "let data = try JSONSerialization.data(withJSONObject: payload)",
                    "let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]",
                    'let marks = object["marks"] as! [Any]',
                    'guard marks[0] is NSNull, marks[1] as? String == "A2", marks[2] is NSNull else {',
                    "    fputs(String(data: data, encoding: .utf8) ?? \"\", stderr)",
                    "    exit(1)",
                    "}",
                    'print("OK")',
                ]
            )
        )
        self.assertIn("OK", output)


if __name__ == "__main__":
    unittest.main()
