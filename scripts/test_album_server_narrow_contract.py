#!/usr/bin/env python3
"""Host negative controls: wrong member, A/B mix, missing screenshot, zero/skip, packed counts cannot pass."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


SCRIPT_DIR = Path(__file__).resolve().parent

from album_server_narrow_contract import (  # noqa: E402
    EMPTY_FILTERED_COPY,
    SERVER_SWITCH_RECORDING_FILE,
    SERVER_SWITCH_SAVE_SUCCESS_PNG,
    SERVER_SWITCH_SELECTION_CLEARED_PNG,
    OFFICIAL_CASES,
    AlbumServerContractError,
    build_xcodebuild_command,
    count_official_executions,
    empty_album_id,
    empty_album_is_listed,
    evaluate_album_empty_evidence,
    evaluate_server_switch_evidence,
    official_case_count,
    official_device_command,
    reject_success_without_executions,
    validate_official_case_table,
)
from strict_e2e_filter_contract import (  # noqa: E402
    FROZEN_FIXTURE_SHA256,
    FilterContractError,
    write_member_manifest,
)
from strict_e2e_runner_support import CommandError, require_visual_identity  # noqa: E402
from strict_e2e_photo_identity import (  # noqa: E402
    IdentityAssertionError,
    classify_screenshot,
    public_frame_photos_from_bytes,
    public_frame_slot_count_from_bytes,
)
from strict_e2e_server import GLYPHS, PUBLIC_API_KEY, _fixture_data, fixture_manifest  # noqa: E402
from test_strict_e2e_server import RunningServer  # noqa: E402

TV_SCREEN = (1920, 1080)
TV_4K_SCREEN = (3840, 2160)
IPHONE_SCREEN = (1170, 2532)
IPAD_SCREEN = (1640, 2360)
UNMEASURED_SCREEN = (1206, 2622)


def _fixture_png(label: str, fixture_set: str = "a") -> bytes:
    return _fixture_data(fixture_set)["images"][f"asset-{fixture_set}-{label[-1]}"]


def _side_by_side(left: bytes, right: bytes) -> bytes:
    left_image = Image.open(io.BytesIO(left)).convert("RGB")
    right_image = Image.open(io.BytesIO(right)).convert("RGB")
    height = max(left_image.height, right_image.height)
    canvas = Image.new("RGB", (left_image.width + right_image.width, height), (0, 0, 0))
    canvas.paste(left_image, (0, 0))
    canvas.paste(right_image, (left_image.width, 0))
    buffer = io.BytesIO()
    canvas.save(buffer, format="PNG")
    return buffer.getvalue()


def _blurred_photo(png: bytes) -> bytes:
    """Heavy blur that keeps the original hue; simulates a photo still visible on the Smart Fill blurred background."""
    image = Image.open(io.BytesIO(png)).convert("RGB")
    blurred = image.filter(ImageFilter.GaussianBlur(radius=12))
    buffer = io.BytesIO()
    blurred.save(buffer, format="PNG")
    return buffer.getvalue()


def _photo_on_empty_background(background: bytes, photo: bytes) -> bytes:
    canvas = Image.open(io.BytesIO(background)).convert("RGB")
    image = Image.open(io.BytesIO(photo)).convert("RGB")
    width = max(1, canvas.width * 2 // 3)
    height = max(1, canvas.height * 2 // 3)
    fitted = image.resize((width, height), Image.Resampling.BILINEAR)
    canvas.paste(fitted, ((canvas.width - width) // 2, (canvas.height - height) // 2))
    buffer = io.BytesIO()
    canvas.save(buffer, format="PNG")
    return buffer.getvalue()


def _letterbox(png: bytes, canvas: tuple[int, int]) -> bytes:
    image = Image.open(io.BytesIO(png)).convert("RGB")
    canvas_image = Image.new("RGB", canvas, (0, 0, 0))
    scale = min(canvas[0] / image.width, canvas[1] / image.height)
    fitted = image.resize(
        (max(1, int(image.width * scale)), max(1, int(image.height * scale))),
        Image.Resampling.BILINEAR,
    )
    canvas_image.paste(
        fitted,
        ((canvas[0] - fitted.width) // 2, (canvas[1] - fitted.height) // 2),
    )
    buffer = io.BytesIO()
    canvas_image.save(buffer, format="PNG")
    return buffer.getvalue()


# Generated synthetic fixtures composed from the public fixture photos. They reproduce
# the classification property each test guards; they are not recorded simulator screenshots.


def _png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def _fixture_image(label: str, fixture_set: str = "a") -> Image.Image:
    return Image.open(io.BytesIO(_fixture_png(label, fixture_set))).convert("RGB")


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


def _single_on_own_blur(label: str, screen: tuple[int, int], fixture_set: str = "a") -> bytes:
    """A single photo whose blurred copy must not count as a second photo."""
    image = _fixture_image(label, fixture_set)
    canvas = _cover(image, screen).filter(ImageFilter.GaussianBlur(48))
    scale = min(screen[0] / image.width, screen[1] / image.height)
    fitted = image.resize(
        (max(1, round(image.width * scale)), max(1, round(image.height * scale))),
        Image.Resampling.BILINEAR,
    )
    canvas.paste(fitted, ((screen[0] - fitted.width) // 2, (screen[1] - fitted.height) // 2))
    return _png(canvas)


def _full_screen(label: str, screen: tuple[int, int], fixture_set: str = "a") -> bytes:
    return _png(_cover(_fixture_image(label, fixture_set), screen))


def _stacked_album_frame(fixture_set: str, top_mark: str = "A1", bottom_mark: str = "A3",
                         top_fixture: str | None = None, unreadable_top: bool = False) -> bytes:
    # Scanner-approved Debug iPad album-empty/filter-album captures: 1640x2360,
    # seam y=938, glyph bands y=93..839 and 1275..2024, control bar (478,2120)-(1162,2236).
    # A roughly 2008px-wide public original with a 179px horizontal crop reproduces
    # the observed SmartFill zoom/pan; use the same geometry for counterexamples.
    canvas = Image.new("RGB", IPAD_SCREEN)
    for mark, source, box, crop_top in (
        (top_mark, top_fixture or fixture_set, (0, 0, 1640, 938), 95),
        (bottom_mark, fixture_set, (0, 938, 1640, 2360), 292),
    ):
        photo = _fixture_image(mark, source)
        if unreadable_top and box[1] == 0:
            cell = max(8, min(photo.width // 18, photo.height // 10))
            left, top = (photo.width - 11 * cell) // 2, (photo.height - 7 * cell) // 2
            ImageDraw.Draw(photo).rectangle((left, top, left + 11 * cell - 1, top + 7 * cell - 1),
                                            fill=photo.getpixel((0, 0)))
        # Preserve the photographed A1/A3 crop, and fit other aspect ratios into the same slots.
        if mark in {"A1", "A3"}:
            height = round(photo.height * 2008 / photo.width)
            resized = photo.resize((2008, height), Image.Resampling.BILINEAR)
            slot = resized.crop((179, crop_top, 1819, crop_top + box[3] - box[1]))
        else:
            slot = _cover(photo, (box[2], box[3] - box[1]))
        canvas.paste(slot, (box[0], box[1]))
    ImageDraw.Draw(canvas, "RGBA").rounded_rectangle((478, 2120, 1162, 2236), radius=58,
                                                      fill=(255, 255, 255, 90))
    return _png(canvas)


def _with_home_indicator(frame: bytes, footer_patch: str | None = None) -> bytes:
    canvas = Image.open(io.BytesIO(frame)).convert("RGB")
    # Real iPad ink (547,2334)-(1093,2345), iPhone ink (377,2493)-(794,2508).
    # The sampled blend (100,52,90) collides with A1's palette over an A3 footer.
    left, top, right, bottom = (547, 2334, 1093, 2345) if canvas.size == IPAD_SCREEN else (377, 2493, 794, 2508)
    ImageDraw.Draw(canvas).rounded_rectangle((left, top, right - 1, bottom - 1), radius=5, fill=(100, 52, 90))
    if footer_patch:
        # Keep this photo patch just left of the ink plus its four-pixel margin.
        canvas.paste(_cover(_fixture_image("A1", footer_patch), (152, bottom - top + 8)), (left - 164, top - 4))
    return _png(canvas)


def _unmeasured_album_frame(fixture_set: str) -> bytes:
    # Scale the colliding indicator with the photo to exercise a size without a measured box.
    frame = _with_home_indicator(_full_screen("A3", IPHONE_SCREEN, fixture_set))
    with Image.open(io.BytesIO(frame)) as image:
        return _png(image.resize(UNMEASURED_SCREEN, Image.Resampling.BILINEAR))


def _iphone_control_split_frame(fixture_set: str, *, foreign_bottom_half: bool = False,
                                outside_gap: bool = False) -> bytes:
    # Real 1170x2532 capture: A2/A1 seam y=1824, A1 glyph (151,1893),
    # 80px cells, and control-bar ink (72,2130)-(1098,2310).
    canvas = Image.new("RGB", IPHONE_SCREEN)
    top = _fixture_image("A2", fixture_set).resize((1440, 2560), Image.Resampling.BILINEAR)
    canvas.paste(top.crop((135, 365, 1305, 2189)), (0, 0))
    photo = _fixture_image("A1", fixture_set)
    colors = (photo.getpixel((0, 0)), photo.getpixel((0, 48) if fixture_set == "b" else (48, 0)))
    for y in range(photo.height):
        for x in range(photo.width):
            if min(photo.getpixel((x, y))) >= 240:
                block = y // 48 if fixture_set == "b" else x // 48 + y // 48
                photo.putpixel((x, y), colors[block % 2])
    photo = photo.resize((1510, 849), Image.Resampling.BILINEAR)
    background = canvas.copy()
    background.paste(photo.crop((160, 73, 1330, 781)), (0, 1824))
    canvas = background.copy()
    draw = ImageDraw.Draw(canvas)
    for row in range(7):
        letter = ("B" if fixture_set == "a" else "A") if foreign_bottom_half and row >= 5 else fixture_set.upper()
        for character, origin in ((letter, 151), ("1", 631)):
            for column, ink in enumerate(GLYPHS[character][row]):
                if ink == "1":
                    x, y = origin + column * 80, 1893 + row * 80
                    draw.rectangle((x, y, x + 79, y + 79), fill="white")
    draw.rounded_rectangle((72, 2130, 1097, 2309), radius=90, fill=(178, 193, 180))
    if outside_gap:
        canvas.paste(background.crop((0, 2010, 1170, 2045)), (0, 2010))
    return _png(canvas)


def _empty_result_screen(screen: tuple[int, int]) -> bytes:
    """Empty-result message over a dark gray field with sparse blue and brown tiles.

    Matches the color mix measured on the recorded tvOS frame (luma about 0.22, about 70%
    gray, a little blue and brown), which was once misread as fixture A4.
    """
    width, height = screen
    canvas = Image.new("RGB", screen)
    draw = ImageDraw.Draw(canvas)
    tile = 96
    tile_colors = ((32, 46, 74), (32, 46, 74), (72, 52, 34)) + ((44, 44, 46),) * 9
    for top in range(0, height, tile):
        for left in range(0, width, tile):
            color = tile_colors[((left // tile) * 3 + (top // tile) * 7) % len(tile_colors)]
            draw.rectangle((left, top, left + tile, top + tile), fill=color)
    draw.rectangle(
        (round(width * 0.22), round(height * 0.47), round(width * 0.78), round(height * 0.53)),
        fill=(245, 245, 245),
    )
    return _png(canvas)


def _write_synthetic_album_empty_pack(directory: Path, play_1: bytes, play_2: bytes, empty_result: bytes) -> None:
    _write_album_empty_pass(directory)
    (directory / "album-play-1.png").write_bytes(play_1)
    (directory / "album-play-2.png").write_bytes(play_2)
    (directory / "empty-album-result.png").write_bytes(empty_result)


SERVER_SWITCH_MOVIE = (
    b"\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00qt  "
    b"\x00\x00\x00\x08mdat"
    b"\x00\x00\x00\x08moov"
)


def _write_server_switch_pass(directory: Path) -> None:
    write_member_manifest(directory / "member-manifest-a.json", "a")
    write_member_manifest(directory / "member-manifest-b.json", "b")
    (directory / "server-switch-a-play-1.png").write_bytes(_fixture_png("A1", "a"))
    (directory / "switch-b-play-1.png").write_bytes(_fixture_png("A1", "b"))
    (directory / "switch-b-play-2.png").write_bytes(_fixture_png("A2", "b"))
    (directory / SERVER_SWITCH_SAVE_SUCCESS_PNG).write_bytes(_fixture_png("A1", "a"))
    (directory / SERVER_SWITCH_SELECTION_CLEARED_PNG).write_bytes(_fixture_png("A2", "a"))
    (directory / SERVER_SWITCH_RECORDING_FILE).write_bytes(SERVER_SWITCH_MOVIE)
    (directory / "observed-ids.json").write_text(
        json.dumps(
            {
                "identity_source": "ui_accessibility_identifier",
                "ids": ["album-b-target", "album-b-non-target", "album-b-empty"],
                "raw_identifiers": [
                    "albumFilter.album.album-b-target.button",
                    "albumFilter.album.album-b-non-target.button",
                    "albumFilter.album.album-b-empty.button",
                ],
            }
        ),
        encoding="utf-8",
    )
    (directory / "display-before.png").write_bytes(_side_by_side(_fixture_png("A2", "b"), _fixture_png("A3", "b")))
    (directory / "display-after.png").write_bytes(_fixture_png("A2", "b"))
    (directory / "display-settings.png").write_bytes(_fixture_png("A1", "b"))
    (directory / "display-policy.json").write_text(
        json.dumps({
            "identity_source": "public_fixture_photo_mark", "setting_source": "accessibility_ui",
            "mode_before": "smartFill", "mode_after": "singlePhoto",
            "process_id_before": 44, "process_id_after": 44,
            "before_candidate_steps": ["display-before-candidate-01"],
            "selected_before_step": "display-before-candidate-01",
        }),
        encoding="utf-8",
    )
    (directory / "display-before-candidate-01.png").write_bytes((directory / "display-before.png").read_bytes())


def _write_album_empty_pass(directory: Path, fixture_set: str = "a") -> None:
    write_member_manifest(directory / "member-manifest.json", fixture_set)
    (directory / "album-play-1.png").write_bytes(_fixture_png("A1", fixture_set))
    (directory / "album-play-2.png").write_bytes(_fixture_png("A2", fixture_set))
    (directory / "empty-selection.json").write_text(
        json.dumps(
            {
                "album_ids": [],
                "person_filters": [],
                "start_enabled": False,
                "start_button_id": "filterSummary.startPlayback.button",
                "identity_source": "public_fixture_photo_mark",
            }
        ),
        encoding="utf-8",
    )
    (directory / "empty-album.json").write_text(
        json.dumps(
            {
                "album_id": empty_album_id(fixture_set),
                "start_enabled": True,
                "empty_copy": EMPTY_FILTERED_COPY,
                "identity_source": "public_fixture_photo_mark",
                "entry": "settings.playback.filterConfig.button",
            }
        ),
        encoding="utf-8",
    )
    Image.new("RGB", (320, 180), (12, 12, 12)).save(directory / "empty-album-result.png")


class OfficialCountTests(unittest.TestCase):
    def test_table_has_exactly_fifteen_distinct_cases(self) -> None:
        validate_official_case_table()
        self.assertEqual(official_case_count(), 15)
        self.assertEqual(len(OFFICIAL_CASES), 15)

    def test_one_execution_cannot_be_reported_as_three_passes(self) -> None:
        packed = [{"executed": 1, "failed": 0, "skipped": 0, "passed": 1}] * 3
        with self.assertRaises(AlbumServerContractError) as raised:
            count_official_executions(packed)
        self.assertIn("15", str(raised.exception))

    def test_zero_or_skipped_cannot_pass(self) -> None:
        with self.assertRaises(AlbumServerContractError):
            reject_success_without_executions({"executed": 0, "failed": 0, "skipped": 0, "passed": 0})
        with self.assertRaises(AlbumServerContractError):
            reject_success_without_executions({"executed": 1, "failed": 0, "skipped": 1, "passed": 0})

    def test_fifteen_independent_1_0_0_summaries_pass_count(self) -> None:
        summaries = [{"executed": 1, "failed": 0, "skipped": 0, "passed": 1} for _ in range(15)]
        self.assertEqual(count_official_executions(summaries)["executed"], 15)

    def test_server_switch_command_requires_peer_server(self) -> None:
        case = next(item for item in OFFICIAL_CASES if item["narrow"] == "server-switch" and item["platform"] == "iphone")
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(AlbumServerContractError):
                build_xcodebuild_command(
                    case=case,
                    destination="platform=iOS Simulator,id=SIM",
                    derived_data=Path(raw) / "dd",
                    result_bundle=Path(raw) / "out.xcresult",
                    evidence_dir=Path(raw) / "evidence",
                    server_url="http://127.0.0.1:1/api",
                )

    def test_auth_401_uses_wrong_public_key(self) -> None:
        case = next(item for item in OFFICIAL_CASES if item["narrow"] == "fail-401" and item["platform"] == "iphone")
        with tempfile.TemporaryDirectory() as raw:
            command = build_xcodebuild_command(
                case=case,
                destination="platform=iOS Simulator,id=SIM",
                derived_data=Path(raw) / "dd",
                result_bundle=Path(raw) / "out.xcresult",
                evidence_dir=Path(raw) / "evidence",
                server_url="http://127.0.0.1:1/api",
            )
        self.assertIn("STRICT_E2E_INPUT_PUBLIC_KEY=immichslides-public-e2e-wrong-key", command)
        self.assertNotIn(f"STRICT_E2E_INPUT_PUBLIC_KEY={PUBLIC_API_KEY}", command)


class EmptyAlbumFixtureTests(unittest.TestCase):
    def test_empty_album_is_listed_and_search_returns_legal_empty_array(self) -> None:
        self.assertTrue(empty_album_is_listed("a"))
        self.assertTrue(empty_album_is_listed("b"))
        self.assertEqual(empty_album_id("a"), "album-a-empty")
        self.assertEqual(empty_album_id("b"), "album-b-empty")
        with RunningServer() as server:
            status, _headers, body = server.request("/albums")
            self.assertEqual(status, 200)
            albums = json.loads(body)
            empty = [item for item in albums if item["id"] == "album-a-empty"]
            self.assertEqual(len(empty), 1)
            self.assertEqual(empty[0]["assetCount"], 0)
            status, _headers, body = server.request(
                "/search/random",
                method="POST",
                body={
                    "size": 10,
                    "isOffline": False,
                    "visibility": "timeline",
                    "withDeleted": False,
                    "withExif": True,
                    "withPeople": True,
                    "withStacked": True,
                    "albumIds": ["album-a-empty"],
                },
            )
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body), [])

    def test_empty_album_is_not_a_network_failure(self) -> None:
        with RunningServer() as server:
            status, headers, body = server.request(
                "/search/random",
                method="POST",
                body={
                    "size": 10,
                    "isOffline": False,
                    "visibility": "timeline",
                    "withDeleted": False,
                    "withExif": True,
                    "withPeople": True,
                    "withStacked": True,
                    "albumIds": ["album-a-empty"],
                },
            )
        self.assertEqual(status, 200)
        self.assertIn("application/json", headers["Content-Type"])
        self.assertNotIn(b"<!doctype html>", body)

    def test_png_seeds_did_not_change_with_empty_album(self) -> None:
        self.assertEqual(fixture_manifest("a")["fixture_sha256"], FROZEN_FIXTURE_SHA256["a"])
        self.assertEqual(
            [asset["label"] for asset in fixture_manifest("a")["assets"]],
            ["A1", "A2", "A3", "A4", "A5"],
        )


class AlbumEmptyNegativeTests(unittest.TestCase):
    def test_unreadable_playback_identifies_the_rejected_input(self) -> None:
        from ci_failure_diagnostics import public_validator_failure_message

        for name in ("album-play-1", "album-play-2"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_album_empty_pass(directory)
                (directory / f"{name}.png").write_bytes(_png(Image.new("RGB", IPAD_SCREEN, (40, 40, 40))))
                with self.assertRaisesRegex(
                    CommandError,
                    rf"public photo colors are missing or mixed; .*; screenshot {name}\.png$",
                ) as raised:
                    require_visual_identity(directory, "album-empty")
                self.assertRegex(
                    public_validator_failure_message(str(raised.exception.__cause__)),
                    rf"; screenshot {name}\.png$",
                )

    def test_wrong_member_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "album-play-2.png").write_bytes(_fixture_png("A4"))
            with self.assertRaises(Exception):
                evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)

    def test_missing_empty_result_screenshot_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").unlink()
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
            self.assertIn("Missing empty-album result screenshot", str(raised.exception))

    def test_unrecorded_start_state_fails(self) -> None:
        for filename in ("empty-selection.json", "empty-album.json"):
            for unrecorded in ("missing", None, 0):
                with self.subTest(filename=filename, unrecorded=unrecorded), tempfile.TemporaryDirectory() as raw:
                    directory = Path(raw)
                    _write_album_empty_pass(directory)
                    payload = json.loads((directory / filename).read_text(encoding="utf-8"))
                    if unrecorded == "missing":
                        del payload["start_enabled"]
                    else:
                        payload["start_enabled"] = unrecorded
                    (directory / filename).write_text(json.dumps(payload), encoding="utf-8")
                    with self.assertRaises(AlbumServerContractError) as raised:
                        evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
                    self.assertIn(f"{filename} start_enabled must be a recorded Boolean", str(raised.exception))

    def test_settings_editor_without_start_button_records_not_applicable(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            payload = json.loads((directory / "empty-album.json").read_text(encoding="utf-8"))
            payload["start_enabled"] = "not_applicable_settings_editor"
            (directory / "empty-album.json").write_text(json.dumps(payload), encoding="utf-8")
            result = evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
            self.assertEqual(result["verdict"], "PASS")
            self.assertEqual(result["start_enabled_after_empty_album"], "not_applicable_settings_editor")

    def test_not_applicable_start_state_is_rejected_outside_the_settings_editor(self) -> None:
        for filename, entry in (("empty-album.json", "playback.start"), ("empty-selection.json", None)):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_album_empty_pass(directory)
                payload = json.loads((directory / filename).read_text(encoding="utf-8"))
                payload["start_enabled"] = "not_applicable_settings_editor"
                if entry is not None:
                    payload["entry"] = entry
                (directory / filename).write_text(json.dumps(payload), encoding="utf-8")
                with self.assertRaises(AlbumServerContractError):
                    evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)

    def test_invented_empty_copy_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            payload = json.loads((directory / "empty-album.json").read_text(encoding="utf-8"))
            payload["empty_copy"] = "Invalid empty-album copy"
            (directory / "empty-album.json").write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(AlbumServerContractError):
                evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)

    def test_old_pool_photo_after_empty_album_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(_fixture_png("A1"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
            self.assertIn("old non-empty pool", str(raised.exception))

    def test_unrecorded_target_member_after_empty_album_still_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(_fixture_png("A3"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
            self.assertIn("old non-empty pool", str(raised.exception))

    def test_probe_identity_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            payload = json.loads((directory / "empty-album.json").read_text(encoding="utf-8"))
            payload["identity_source"] = "probe"
            (directory / "empty-album.json").write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(AlbumServerContractError):
                evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)

    def test_public_album_empty_pack_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            report = evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["empty_copy"], EMPTY_FILTERED_COPY)


class AlbumEmptyFixtureBTests(unittest.TestCase):
    def test_tv_album_empty_reads_every_slot_of_real_size_playback_frames(self) -> None:
        from test_strict_e2e_photo_identity import FrameGlyphBoundaryTests
        for fixture_set in ("a", "b"):
            with self.subTest(fixture=fixture_set), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_album_empty_pass(directory, fixture_set)
                # The observed 3840x2160 B3/B2 frame splits at x=2458.
                pair = FrameGlyphBoundaryTests._pair(fixture_set, 3, 2, horizontal=True, seam=2458)
                (directory / "album-play-1.png").write_bytes(pair)
                (directory / "album-play-2.png").write_bytes(_full_screen("A1", TV_SCREEN, fixture_set))
                report = require_visual_identity(directory, "tvos-album-empty", fixture_set=fixture_set)
                self.assertEqual(report["marks"], ["A3", "A2", "A1"])
                for case, options, message in (
                    ("wrong album", {"first": 4}, "Unexpected members cannot count as passing: A4"),
                    ("mixed", {"second_fixture": "b" if fixture_set == "a" else "a"}, "mixed public glyphs"),
                    ("unreadable", {"unreadable_slot": 1}, "unreadable public glyph slot"),
                ):
                    with self.subTest(case=case):
                        arguments = dict(fixture_set=fixture_set, first=3, second=2, horizontal=True, seam=2458)
                        arguments.update(options)
                        (directory / "album-play-1.png").write_bytes(FrameGlyphBoundaryTests._pair(**arguments))
                        with self.assertRaisesRegex(CommandError, message) as raised:
                            require_visual_identity(directory, "tvos-album-empty", fixture_set=fixture_set)
                        if case != "wrong album":
                            from ci_failure_diagnostics import public_validator_failure_message
                            context = str(raised.exception.__cause__)
                            self.assertIn("horizontal", context)
                            self.assertEqual(context, public_validator_failure_message(context))
                (directory / "album-play-1.png").write_bytes(pair)
                (directory / "album-play-2.png").write_bytes(pair)
                with self.assertRaisesRegex(CommandError, "The two playback screenshots must be different public identities"):
                    require_visual_identity(directory, "tvos-album-empty", fixture_set=fixture_set)
                (directory / "album-play-2.png").unlink()
                with self.assertRaisesRegex(CommandError, "The target album needs screenshots of at least two different public identities"):
                    require_visual_identity(directory, "tvos-album-empty", fixture_set=fixture_set)

    def test_unmeasured_geometry_keeps_main_without_background_or_palette_gates(self) -> None:
        from strict_e2e_filter_contract import TARGET_ALBUM_HOME_INDICATOR_BOXES
        self.assertNotIn(UNMEASURED_SCREEN, TARGET_ALBUM_HOME_INDICATOR_BOXES)
        for fixture_set in ("a", "b"):
            for shape, frame in (
                ("home indicator", _unmeasured_album_frame(fixture_set)),
                ("letterbox", _letterbox(_fixture_png("A3", fixture_set), UNMEASURED_SCREEN)),
            ):
                with self.subTest(fixture_set=fixture_set, shape=shape), tempfile.TemporaryDirectory() as raw:
                    directory = Path(raw)
                    _write_album_empty_pass(directory, fixture_set)
                    self.assertEqual(Image.open(io.BytesIO(frame)).size, UNMEASURED_SCREEN)
                    identity = classify_screenshot(frame)
                    self.assertEqual((identity.status, identity.mark), ("MATCH", "A3"))
                    with self.assertRaises(IdentityAssertionError):
                        public_frame_slot_count_from_bytes(frame)
                    (directory / "album-play-1.png").write_bytes(frame)
                    main_result = {
                        "verdict": "PASS", "suite": "album-empty", "marks": [identity.mark, "A2"],
                        "empty_copy": EMPTY_FILTERED_COPY, "empty_album_id": empty_album_id(fixture_set),
                        "start_enabled_after_empty_album": True,
                    }
                    report = require_visual_identity(directory, "album-empty", fixture_set=fixture_set)
                    self.assertEqual(json.loads((directory / "visual-identity-runner.json").read_text()), report)
                    self.assertEqual(report.pop("target_album_geometry"), "unmeasured")
                    self.assertEqual(report.pop("target_album_frame_geometry"), {
                        "album-play-1": "unmeasured", "album-play-2": "unmeasured"})
                    self.assertEqual(report, main_result)
        # Measured sizes retain the background gate even for a main-passing single photo.
        for screen in (IPHONE_SCREEN, IPAD_SCREEN):
            with self.subTest(measured_screen=screen), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_album_empty_pass(directory)
                frame = _letterbox(_fixture_png("A3"), screen)
                self.assertEqual(classify_screenshot(frame).status, "MATCH")
                (directory / "album-play-1.png").write_bytes(frame)
                with self.assertRaisesRegex(FilterContractError, "does not match.*blurred background"):
                    evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)

    def test_pinned_ios_devices_have_measured_target_album_geometries(self) -> None:
        from strict_e2e_filter_contract import TARGET_ALBUM_HOME_INDICATOR_BOXES
        pins = json.loads((SCRIPT_DIR / "ci-pins.json").read_text())
        measured_devices = {"iPhone 17e": IPHONE_SCREEN, "iPad Air 11-inch (M4)": IPAD_SCREEN}
        for role in ("iphone", "ipad"):
            device = pins["device_types"][role]
            with self.subTest(role=role, device=device):
                self.assertIn(device, measured_devices, "A newly pinned device needs target-album frame measurements")
                self.assertIn(measured_devices[device], TARGET_ALBUM_HOME_INDICATOR_BOXES)

    def test_single_slot_zoomed_glyph_keeps_the_main_whole_frame_result(self) -> None:
        from strict_e2e_filter_contract import TARGET_ALBUM_GLYPH_OVERLAY_BOXES
        for fixture_set in ("a", "b"):
            with self.subTest(fixture_set=fixture_set), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_album_empty_pass(directory, fixture_set)
                # The real iPhone B1 cover zoom clips the letter horizontally.
                frame = _full_screen("A1", IPHONE_SCREEN, fixture_set)
                self.assertEqual(Image.open(io.BytesIO(frame)).size, IPHONE_SCREEN)
                identity = classify_screenshot(frame)
                self.assertEqual((identity.status, identity.mark), ("MATCH", "A1"))
                self.assertEqual(public_frame_slot_count_from_bytes(frame), 1)
                with self.assertRaises(IdentityAssertionError):
                    public_frame_photos_from_bytes(frame, glyph_overlay_box=TARGET_ALBUM_GLYPH_OVERLAY_BOXES[IPHONE_SCREEN])
                (directory / "album-play-1.png").write_bytes(frame)
                main_result = {
                    "verdict": "PASS", "suite": "album-empty", "marks": [identity.mark, "A2"],
                    "empty_copy": EMPTY_FILTERED_COPY, "empty_album_id": empty_album_id(fixture_set),
                    "start_enabled_after_empty_album": True,
                }
                report = require_visual_identity(directory, "album-empty", fixture_set=fixture_set)
                self.assertEqual(json.loads((directory / "visual-identity-runner.json").read_text()), report)
                self.assertEqual(report.pop("target_album_geometry"), "unmeasured")
                self.assertEqual(report.pop("target_album_frame_geometry"), {
                    "album-play-1": "measured", "album-play-2": "unmeasured"})
                self.assertEqual(report, main_result)

    def test_measured_system_boxes_cannot_hide_a_photo_slot(self) -> None:
        from strict_e2e_filter_contract import TARGET_ALBUM_HOME_INDICATOR_BOXES
        self.assertEqual(TARGET_ALBUM_HOME_INDICATOR_BOXES, {
            IPAD_SCREEN: (543, 2330, 1097, 2349), IPHONE_SCREEN: (373, 2489, 798, 2512),
        })
        for screen, slot_heights in ((IPAD_SCREEN, (938, 1422)), (IPHONE_SCREEN, (1824, 708))):
            left, top, right, bottom = TARGET_ALBUM_HOME_INDICATOR_BOXES[screen]
            # Every reader slot spans the full image width, even an arbitrarily thin one.
            self.assertLess(right - left, screen[0])
            self.assertGreaterEqual((screen[0] - right + left) * 480 // screen[0], 18)
            for slot_height in slot_heights:
                self.assertLess(bottom - top, slot_height)

    def test_control_bar_split_glyph_requires_one_letter_and_a_bounded_gap(self) -> None:
        for fixture_set in ("a", "b"):
            with self.subTest(fixture_set=fixture_set), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_album_empty_pass(directory, fixture_set)
                frame = _iphone_control_split_frame(fixture_set)
                self.assertEqual(Image.open(io.BytesIO(frame)).size, IPHONE_SCREEN)
                with self.assertRaises(IdentityAssertionError):
                    public_frame_photos_from_bytes(frame)
                (directory / "album-play-1.png").write_bytes(frame)
                self.assertEqual(require_visual_identity(directory, "album-empty", fixture_set=fixture_set)["marks"],
                                 ["A2", "A1", "A2"])
                # The mixed lower letter pins glyph consistency; outside_gap is
                # a retained geometry control, not independent mutation coverage.
                for case in ("foreign_bottom_half", "outside_gap"):
                    with self.subTest(case=case):
                        invalid = _iphone_control_split_frame(fixture_set, **{case: True})
                        # Both photos now qualify, but the multi-slot path must
                        # still reject the damaged second glyph independently.
                        self.assertEqual(classify_screenshot(invalid).status, "TRANSITION")
                        (directory / "album-play-1.png").write_bytes(invalid)
                        with self.assertRaisesRegex(
                            CommandError,
                            r"^Visual assertion failed; cannot mark SUCCESS: unreadable public glyph slot; slot 2 \(vertical\)$",
                        ):
                            require_visual_identity(directory, "album-empty", fixture_set=fixture_set)

    def test_system_home_indicator_does_not_hide_a_footer_photo_patch(self) -> None:
        for fixture_set, screen in (
            ("a", IPAD_SCREEN), ("a", IPHONE_SCREEN), ("b", IPAD_SCREEN), ("b", IPHONE_SCREEN),
        ):
            with self.subTest(fixture_set=fixture_set, screen=screen), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_album_empty_pass(directory, fixture_set)
                photo = _stacked_album_frame(fixture_set) if screen == IPAD_SCREEN else _full_screen("A3", screen, fixture_set)
                frame = _with_home_indicator(photo)
                with self.assertRaisesRegex(IdentityAssertionError, "public photo colors are missing or mixed"):
                    public_frame_photos_from_bytes(frame)
                (directory / "album-play-1.png").write_bytes(frame)
                expected = ["A1", "A3", "A2"] if screen == IPAD_SCREEN else ["A3", "A2"]
                self.assertEqual(require_visual_identity(directory, "album-empty", fixture_set=fixture_set)["marks"], expected)
                for patch_fixture in (fixture_set, "b" if fixture_set == "a" else "a"):
                    with self.subTest(patch_fixture=patch_fixture):
                        (directory / "album-play-1.png").write_bytes(
                            _with_home_indicator(photo, patch_fixture))
                        with self.assertRaises(CommandError):
                            require_visual_identity(directory, "album-empty", fixture_set=fixture_set)

    def test_stacked_target_frames_keep_two_different_screenshots_and_empty_result(self) -> None:
        for fixture_set in ("a", "b"):
            with self.subTest(fixture_set=fixture_set), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_album_empty_pass(directory, fixture_set)
                stacked = _stacked_album_frame(fixture_set)
                self.assertEqual(Image.open(io.BytesIO(stacked)).size, IPAD_SCREEN)
                self.assertNotEqual(classify_screenshot(stacked).status, "MATCH")
                self.assertEqual([photo.mark for photo in public_frame_photos_from_bytes(stacked)], ["A1", "A3"])
                (directory / "album-play-1.png").write_bytes(stacked)
                (directory / "album-play-2.png").write_bytes(_full_screen("A2", IPAD_SCREEN, fixture_set))
                report = require_visual_identity(directory, "album-empty", fixture_set=fixture_set)
                self.assertEqual(report["verdict"], "PASS")
                self.assertEqual(report["marks"], ["A1", "A3", "A2"])
                self.assertEqual(report["target_album_geometry"], "measured")
                self.assertEqual(report["target_album_frame_geometry"], {
                    "album-play-1": "measured", "album-play-2": "measured"})
                self.assertEqual(json.loads((directory / "visual-identity-runner.json").read_text()), report)
                # One multi-photo screenshot cannot stand in for the second capture,
                # and repeating the same collage cannot prove navigation to a new identity.
                (directory / "album-play-2.png").unlink()
                with self.assertRaises(CommandError):
                    require_visual_identity(directory, "album-empty", fixture_set=fixture_set)
                (directory / "album-play-2.png").write_bytes(stacked)
                with self.assertRaises(CommandError):
                    require_visual_identity(directory, "album-empty", fixture_set=fixture_set)
                (directory / "album-play-2.png").write_bytes(_full_screen("A2", IPAD_SCREEN, fixture_set))
                (directory / "empty-album-result.png").write_bytes(stacked)
                with self.assertRaises(CommandError) as raised:
                    require_visual_identity(directory, "album-empty", fixture_set=fixture_set)
                self.assertIn("old non-empty pool", str(raised.exception))

    def test_every_stacked_target_slot_requires_album_membership_and_fixture_identity(self) -> None:
        for fixture_set, other in (("a", "b"), ("b", "a")):
            for case, frame in (
                ("wrong album", _stacked_album_frame(fixture_set, top_mark="A4")),
                ("mixed fixture", _stacked_album_frame(fixture_set, top_fixture=other)),
                ("other fixture", _stacked_album_frame(other)),
                ("unreadable slot", _stacked_album_frame(fixture_set, unreadable_top=True)),
                ("unreadable foreign slot", _stacked_album_frame(fixture_set, top_fixture=other, unreadable_top=True)),
            ):
                with self.subTest(fixture_set=fixture_set, case=case), tempfile.TemporaryDirectory() as raw:
                    directory = Path(raw)
                    _write_album_empty_pass(directory, fixture_set)
                    (directory / "album-play-1.png").write_bytes(frame)
                    with self.assertRaises(CommandError):
                        require_visual_identity(directory, "album-empty", fixture_set=fixture_set)
                    if case == "wrong album":
                        self.assertEqual({photo.mark for photo in public_frame_photos_from_bytes(frame)}, {"A4", "A3"})
                    if "unreadable" in case:
                        with self.assertRaisesRegex(IdentityAssertionError, "unreadable public glyph slot"):
                            public_frame_photos_from_bytes(frame)

    def test_fixture_b_pack_passes_when_the_active_fixture_is_carried_through(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory, "b")
            self.assertEqual(evaluate_album_empty_evidence(directory, "b", use_ios_album_geometry=True)["verdict"], "PASS")
            self.assertEqual(require_visual_identity(directory, "album-empty", fixture_set="b")["verdict"], "PASS")

    def test_fixture_b_pack_is_rejected_as_a_and_a_wrong_album_frame_is_rejected_for_both_fixtures(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory, "b")
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory, "a", use_ios_album_geometry=True)
            self.assertIn("does not match the requested fixture", str(raised.exception))
            with self.assertRaises(CommandError):
                require_visual_identity(directory, "album-empty")
        for fixture_set in ("a", "b"):
            with self.subTest(fixture_set=fixture_set), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_album_empty_pass(directory, fixture_set)
                (directory / "album-play-2.png").write_bytes(_fixture_png("A4", fixture_set))
                with self.assertRaises(FilterContractError):
                    evaluate_album_empty_evidence(directory, fixture_set, use_ios_album_geometry=True)


class EmptyResultIdentityTests(unittest.TestCase):
    def test_synthetic_tvos_empty_result_is_not_a_fixture_photo(self) -> None:
        identity = classify_screenshot(_empty_result_screen(TV_SCREEN))
        self.assertNotEqual(identity.status, "MATCH")
        self.assertIsNone(identity.mark)

    def test_synthetic_tvos_album_empty_pack_passes_offline(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_synthetic_album_empty_pack(
                directory,
                _full_screen("A1", TV_SCREEN),
                _single_on_own_blur("A2", TV_SCREEN),
                _empty_result_screen(TV_SCREEN),
            )
            report = require_visual_identity(directory, "tvos-album-empty")
        self.assertEqual(report["verdict"], "PASS")
        self.assertGreaterEqual(len(set(report["marks"])), 2)
        self.assertNotIn("target_album_geometry", report)
        self.assertNotIn("target_album_frame_geometry", report)

    def test_synthetic_iphone_album_empty_pack_passes_offline(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_synthetic_album_empty_pack(
                directory,
                _single_on_own_blur("A2", IPHONE_SCREEN),
                _single_on_own_blur("A3", IPHONE_SCREEN),
                _empty_result_screen(IPHONE_SCREEN),
            )
            report = evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
        self.assertEqual(report["verdict"], "PASS")
        self.assertGreaterEqual(len(set(report["marks"])), 2)

    def test_real_a_single_as_empty_result_still_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(_fixture_png("A4"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
            self.assertIn("old non-empty pool", str(raised.exception))

    def test_real_b_single_as_empty_result_still_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(_fixture_png("A1", "b"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
            self.assertIn("old non-empty pool", str(raised.exception))

    def test_multi_as_empty_result_still_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(
                _side_by_side(_fixture_png("A1"), _fixture_png("A2"))
            )
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
            self.assertIn("old non-empty pool", str(raised.exception))

    def test_blurred_real_photo_as_empty_result_still_fails(self) -> None:
        for mark in ("A4", "A2"):
            with self.subTest(mark=mark), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_album_empty_pass(directory)
                (directory / "empty-album-result.png").write_bytes(_blurred_photo(_fixture_png(mark)))
                with self.assertRaises(AlbumServerContractError) as raised:
                    evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
                self.assertIn("old non-empty pool", str(raised.exception))

    def test_empty_copy_with_real_photo_still_fails(self) -> None:
        background = _empty_result_screen(TV_SCREEN)
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(
                _photo_on_empty_background(background, _fixture_png("A1"))
            )
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory, use_ios_album_geometry=True)
            self.assertIn("old non-empty pool", str(raised.exception))


class DisplayPolicyNegativeTests(unittest.TestCase):
    def test_migrated_policy_requires_public_identity_and_original_captures(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            policy = directory / "display-policy.json"
            original = policy.read_bytes()
            payload = json.loads(original)
            for source in ("enum", "probe", "asset_id", "currentAssetId", "launch_argument",
                           "UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE", None, "unknown"):
                with self.subTest(source=source):
                    policy.write_text(json.dumps(payload | {"identity_source": source}))
                    with self.assertRaisesRegex(FilterContractError, "^display-policy screenshot identity must come from public fixture photo marks$"):
                        evaluate_server_switch_evidence(directory)
            for content, message in ((b"{", "^display-policy.json is unreadable:"),
                                     (b"[]", "^display-policy.json is not an object$")):
                with self.subTest(sidecar=content):
                    policy.write_bytes(content)
                    with self.assertRaisesRegex(FilterContractError, message):
                        evaluate_server_switch_evidence(directory)
            policy.write_bytes(original)
            for name in ("display-before.png", "display-settings.png", "display-after.png"):
                with self.subTest(missing=name):
                    path = directory / name
                    photo = path.read_bytes()
                    path.unlink()
                    with self.assertRaisesRegex(FilterContractError, "^Missing multi-photo before, real settings action, or stable single-photo after screenshot$"):
                        evaluate_server_switch_evidence(directory)
                    path.write_bytes(photo)

    def test_migrated_policy_rejects_false_multi_photo_before(self) -> None:
        from test_strict_e2e_photo_identity import FrameGlyphBoundaryTests
        from strict_e2e_filter_contract_test_fixtures import _full_frame_transition
        cases = [
            ("single", _fixture_png("A1", "b"), "^The before-change frame must actually show at least two different photos$"),
            ("same photo twice", _side_by_side(_fixture_png("A2", "b"), _fixture_png("A2", "b")),
             "^The before-change frame must actually show at least two different photos$"),
            ("transition", _full_frame_transition(_fixture_png("A1", "b"), _fixture_png("A3", "b")),
             "^unreadable public glyph slot"),
            ("unknown", _png(Image.new("RGB", (320, 568), (25, 25, 25))), "^unreadable public glyph slot: public photo colors are missing or mixed;"),
            ("black", _png(Image.new("RGB", (320, 568), (0, 0, 0))), "^unreadable public glyph slot: public photo colors are missing or mixed;"),
            ("blank", _png(Image.new("RGB", (320, 568), (255, 255, 255))), "^unreadable public glyph slot: public photo colors are missing or mixed;"),
            ("undecodable", b"not a PNG", "^display-policy screenshot regions cannot be classified: UnidentifiedImageError$"),
        ]
        for screen in (IPHONE_SCREEN, IPAD_SCREEN, TV_SCREEN):
            cases.append((f"letterbox {screen}", _letterbox(_fixture_png("A1", "b"), screen),
                          "^The before-change frame must actually show at least two different photos$" if screen == TV_SCREEN
                          else "does not match.*blurred background"))
        for screen in (IPHONE_SCREEN, IPAD_SCREEN):
            cases.append((f"own blur {screen}", _single_on_own_blur("A1", screen, "b"),
                          "^The before-change frame must actually show at least two different photos$"))
        for horizontal in (False, True):
            axis = "horizontal" if horizontal else "vertical"
            for slot in (1, 2):
                cases.append((f"unread slot {slot} {axis}", FrameGlyphBoundaryTests._pair(
                    "b", 3, 2, horizontal=horizontal, unreadable_slot=slot),
                    rf"^unreadable public glyph slot; slot {slot} \({axis}\)$"))
        for name, frame, message in cases:
            with self.subTest(defect=name), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_server_switch_pass(directory)
                (directory / "display-before.png").write_bytes(frame)
                (directory / "display-before-candidate-01.png").write_bytes(frame)
                with self.assertRaisesRegex(FilterContractError, message):
                    evaluate_server_switch_evidence(directory)

    def test_migrated_policy_rejects_unstable_multi_or_unchanged_after(self) -> None:
        from strict_e2e_filter_contract_test_fixtures import _full_frame_transition
        cases = [
            ("transition", _full_frame_transition(_fixture_png("A1", "b"), _fixture_png("A3", "b")),
             r"^after-change cannot use a transition or unknown frame as passing; screenshot display-after\.png$"),
            ("black", _png(Image.new("RGB", (320, 568), (0, 0, 0))),
             r"^after-change cannot use a transition or unknown frame as passing; screenshot display-after\.png$"),
            ("blank", _png(Image.new("RGB", (320, 568), (255, 255, 255))),
             r"^after-change cannot use a transition or unknown frame as passing; screenshot display-after\.png$"),
            ("unknown", _png(Image.new("RGB", (320, 568), (25, 25, 25))),
             r"^after-change cannot use a transition or unknown frame as passing; screenshot display-after\.png$"),
            ("undecodable", b"not a PNG", r"^after-change cannot use a transition or unknown frame as passing; screenshot display-after\.png$"),
            ("multi", _side_by_side(_fixture_png("A3", "b"), _fixture_png("A4", "b")),
             r"^after-change cannot use a transition or unknown frame as passing: the stable photo region is still transitioning; screenshot display-after\.png$"),
            ("unchanged", _side_by_side(_fixture_png("A2", "b"), _fixture_png("A3", "b")),
             r"^after-change cannot use a transition or unknown frame as passing; screenshot display-after\.png$"),
        ]
        for name, frame, message in cases:
            with self.subTest(defect=name), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_server_switch_pass(directory)
                (directory / "display-after.png").write_bytes(frame)
                with self.assertRaisesRegex(FilterContractError, message):
                    evaluate_server_switch_evidence(directory)

class ABMixTests(unittest.TestCase):
    def test_missing_a_playback_screenshot_fails_server_switch(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / "server-switch-a-play-1.png").unlink()
            with self.assertRaises(AlbumServerContractError):
                evaluate_server_switch_evidence(directory)

    def test_a_ids_on_b_fail_server_switch(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / "observed-ids.json").write_text(
                json.dumps(
                    {
                        "identity_source": "ui_accessibility_identifier",
                        "ids": ["album-a-target"],
                        "raw_identifiers": ["albumFilter.album.album-a-target.button"],
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(Exception):
                evaluate_server_switch_evidence(directory)

    def test_a_screenshot_cannot_pass_as_b(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / "switch-b-play-1.png").write_bytes(_fixture_png("A1", "a"))
            with self.assertRaisesRegex(AlbumServerContractError, "every slot must show the public glyph of fixture B"):
                evaluate_server_switch_evidence(directory)

    def test_a_and_b_panels_together_are_rejected(self) -> None:
        image = _side_by_side(_fixture_png("A3", "a"), _fixture_png("A2", "b"))
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / "switch-b-play-1.png").write_bytes(image)
            with self.assertRaisesRegex(AlbumServerContractError, "mixed public glyphs"):
                evaluate_server_switch_evidence(directory)

    def test_server_switch_pack_with_side_by_side_b_playback_passes(self) -> None:
        from test_strict_e2e_photo_identity import FrameGlyphBoundaryTests
        with self.subTest(shape="native iPad B6+B3 with control bevel"), tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            frame = Image.open(io.BytesIO(_stacked_album_frame("b", top_mark="A6"))).convert("RGB")
            # Native SHA 19c553410f9c4da9aea326a63f30af9b655c392a6b7695c31ec06017c4396ff6:
            # sampled row 629 crosses the B3 stripe seam and 22 pixels of the control-bar bevel.
            sample_width, sample_height = 480, round(480 * frame.height / frame.width)
            top = 629 * frame.height // sample_height
            bottom = (630 * frame.height + sample_height - 1) // sample_height
            draw = ImageDraw.Draw(frame)
            draw.rectangle((0, top, frame.width - 1, bottom - 1), fill=(139, 26, 94))
            colors = ((247, 129, 209), (247, 129, 209), (246, 128, 208), (246, 128, 208),
                      (246, 128, 208), (245, 128, 208), (245, 128, 208), (243, 129, 204),
                      (242, 129, 202), (240, 130, 200), (238, 130, 198))
            for offset, color in enumerate(colors):
                for column in (143 + offset, 336 - offset):
                    left = column * frame.width // sample_width
                    right = ((column + 1) * frame.width + sample_width - 1) // sample_width
                    draw.rectangle((left, top, right - 1, bottom - 1), fill=color)
            (directory / "switch-b-play-2.png").write_bytes(_png(frame))
            self.assertEqual(evaluate_server_switch_evidence(directory)["marks"], ["A1", "A6", "A3"])
        for horizontal in (False, True):
            with self.subTest(horizontal=horizontal), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_server_switch_pass(directory)
                panels = FrameGlyphBoundaryTests._pair("b", 3, 2, horizontal=horizontal,
                                                      seam=2458 if horizontal else None)
                (directory / "switch-b-play-1.png").write_bytes(panels)
                report = evaluate_server_switch_evidence(directory)
                self.assertEqual(report["marks"], ["A3", "A2", "A2"])
                self.assertEqual(report["b_pattern"], "b")
                for case, options, prefix in (
                    ("mixed", {"second_fixture": "a"}, "mixed public glyphs"),
                    ("unreadable", {"unreadable_slot": 1}, "unreadable public glyph slot"),
                ):
                    with self.subTest(case=case):
                        broken = FrameGlyphBoundaryTests._pair("b", 3, 2, horizontal=horizontal,
                                                              seam=2458 if horizontal else None, **options)
                        (directory / "switch-b-play-1.png").write_bytes(broken)
                        with self.assertRaisesRegex(AlbumServerContractError, prefix) as raised:
                            evaluate_server_switch_evidence(directory)
                        self.assertIn("screenshot switch-b-play-1.png", str(raised.exception))
                        self.assertIn("horizontal" if horizontal else "vertical", str(raised.exception))

    def test_server_switch_a_frame_checks_every_slot_for_both_orientations(self) -> None:
        from test_strict_e2e_photo_identity import FrameGlyphBoundaryTests
        with self.subTest(shape="native 4K A1 with TV EXIF edge"), tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            frame = Image.open(io.BytesIO(_full_screen("A1", TV_4K_SCREEN))).convert("RGB")
            # Native A1 capture SHA 9f44e8935770690cdcfec83ca491f163f0272cfc2db160d9e313d916a9245c44:
            # the EXIF top edge contributes 53 pixels on sampled row 7, including 52 at this exact RGB.
            ImageDraw.Draw(frame).rectangle((3008, 56, 3431, 63), fill=(216, 120, 216))
            (directory / "server-switch-a-play-1.png").write_bytes(_png(frame))
            self.assertEqual(evaluate_server_switch_evidence(directory)["verdict"], "PASS")
        with self.subTest(shape="native iPad A1+A3 with entry-hint edge"), tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            frame = Image.open(io.BytesIO(_stacked_album_frame("a"))).convert("RGB")
            photo = _fixture_image("A3", "a")
            height = round(photo.height * 2008 / photo.width)
            resized = photo.resize((2008, height), Image.Resampling.BILINEAR)
            # Keep the measured hint edge below the glyph by panning the real A3 original 150 px upward.
            frame.paste(resized.crop((179, 442, 1819, 1864)), (0, 938))
            # Native hint SHA 4e9f80924c9056f837e4a6824ca79005d6ce6fedac4368e38a25affbf7adf890.
            ImageDraw.Draw(frame).rectangle((600, 1990, 700, 1996), fill=(180, 115, 164))
            (directory / "server-switch-a-play-1.png").write_bytes(_png(frame))
            self.assertEqual(evaluate_server_switch_evidence(directory)["verdict"], "PASS")
        for horizontal in (False, True):
            with self.subTest(horizontal=horizontal), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_server_switch_pass(directory)
                positive = FrameGlyphBoundaryTests._pair("a", 2, 3, horizontal=horizontal, seam=1382 if horizontal else None)
                (directory / "server-switch-a-play-1.png").write_bytes(positive)
                self.assertEqual(evaluate_server_switch_evidence(directory)["verdict"], "PASS")
                for case, first, source, options in (("wrong album", 4, "a", {}),
                                                    ("other fixture", 2, "b", {}),
                                                    ("mixed", 2, "a", {"second_fixture": "b"}),
                                                    ("unreadable", 2, "a", {"unreadable_slot": 1})):
                    with self.subTest(case=case):
                        frame = FrameGlyphBoundaryTests._pair(source, first, 3, horizontal=horizontal, **options)
                        (directory / "server-switch-a-play-1.png").write_bytes(frame)
                        with self.assertRaises((AlbumServerContractError, FilterContractError)):
                            evaluate_server_switch_evidence(directory)

    def test_empty_observed_ids_fail_server_switch(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / "observed-ids.json").write_text(
                json.dumps({"identity_source": "ui_accessibility_identifier", "ids": [], "raw_identifiers": []}),
                encoding="utf-8",
            )
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_server_switch_evidence(directory)
            self.assertIn("Empty observations", str(raised.exception))

    def test_expected_manifest_ids_cannot_be_assembled(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / "observed-ids.json").write_text(
                json.dumps({"ids": ["album-b-target"]}),
                encoding="utf-8",
            )
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_server_switch_evidence(directory)
            self.assertIn("expected manifest", str(raised.exception))

    def test_missing_b_save_success_screenshot_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / SERVER_SWITCH_SAVE_SUCCESS_PNG).unlink()
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_server_switch_evidence(directory)
            self.assertIn("save-success", str(raised.exception))

    def test_missing_selection_cleared_screenshot_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / SERVER_SWITCH_SELECTION_CLEARED_PNG).unlink()
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_server_switch_evidence(directory)
            self.assertIn("old selection cleared", str(raised.exception))

    def test_missing_or_empty_recording_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / SERVER_SWITCH_RECORDING_FILE).unlink()
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_server_switch_evidence(directory)
            self.assertIn("continuous recording", str(raised.exception))
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / SERVER_SWITCH_RECORDING_FILE).write_bytes(b"")
            with self.assertRaises(AlbumServerContractError):
                evaluate_server_switch_evidence(directory)

    def test_public_server_switch_pack_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            report = evaluate_server_switch_evidence(directory)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["b_pattern"], "b")

    def test_server_switch_official_command_uses_recording_runner(self) -> None:
        case = next(item for item in OFFICIAL_CASES if item["narrow"] == "server-switch" and item["platform"] == "iphone")
        with tempfile.TemporaryDirectory() as raw:
            command = official_device_command(
                case=case,
                destination="platform=iOS Simulator,id=SIM",
                derived_data=Path(raw) / "dd",
                result_bundle=Path(raw) / "out.xcresult",
                evidence_dir=Path(raw) / "evidence",
                server_url="http://127.0.0.1:1/api",
                server_url_b="http://127.0.0.1:2/api",
            )
        self.assertEqual(command[0], "python3")
        self.assertIn("scripts/run_strict_e2e.py", command)
        self.assertIn("filter-switch", command)
        self.assertNotIn("xcodebuild", command)


if __name__ == "__main__":
    unittest.main()
