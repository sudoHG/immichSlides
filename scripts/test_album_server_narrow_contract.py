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
    evaluate_immediate_display_policy,
    evaluate_album_empty_evidence,
    evaluate_server_switch_evidence,
    official_case_count,
    official_device_command,
    reject_success_without_executions,
    validate_official_case_table,
)
from strict_e2e_filter_contract import (  # noqa: E402
    FROZEN_FIXTURE_SHA256,
    write_member_manifest,
)
from strict_e2e_photo_identity import classify_public_pattern, classify_screenshot  # noqa: E402
from strict_e2e_server import PUBLIC_API_KEY, _fixture_data, fixture_manifest  # noqa: E402
from test_strict_e2e_server import RunningServer  # noqa: E402

TV_SCREEN = (1920, 1080)
TV_4K_SCREEN = (3840, 2160)
IPHONE_SCREEN = (1170, 2532)


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


def _stack_vertical_lower_bias(top: bytes, bottom: bytes, canvas: tuple[int, int] = IPHONE_SCREEN) -> bytes:
    """Top photo ~40%, bottom ~60%, so center lands on the bottom one; simulates iPhone portrait Smart Fill."""
    top_image = Image.open(io.BytesIO(top)).convert("RGB")
    bottom_image = Image.open(io.BytesIO(bottom)).convert("RGB")
    canvas_image = Image.new("RGB", canvas, (0, 0, 0))
    top_height = max(1, int(canvas[1] * 0.4))
    bottom_height = canvas[1] - top_height

    def fit(image: Image.Image, box_width: int, box_height: int) -> Image.Image:
        scale = min(box_width / image.width, box_height / image.height)
        return image.resize(
            (max(1, int(image.width * scale)), max(1, int(image.height * scale))),
            Image.Resampling.BILINEAR,
        )

    fitted_top = fit(top_image, canvas[0], top_height)
    fitted_bottom = fit(bottom_image, canvas[0], bottom_height)
    canvas_image.paste(
        fitted_top,
        ((canvas[0] - fitted_top.width) // 2, (top_height - fitted_top.height) // 2),
    )
    canvas_image.paste(
        fitted_bottom,
        (
            (canvas[0] - fitted_bottom.width) // 2,
            top_height + (bottom_height - fitted_bottom.height) // 2,
        ),
    )
    buffer = io.BytesIO()
    canvas_image.save(buffer, format="PNG")
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


def _smart_fill_single(png: bytes, canvas: tuple[int, int] = IPHONE_SCREEN) -> bytes:
    """One photo over its own blurred background; simulates a Smart Fill single photo, not two separate photos."""
    image = Image.open(io.BytesIO(png)).convert("RGB")
    background = image.resize(canvas, Image.Resampling.BILINEAR).filter(ImageFilter.GaussianBlur(radius=48))
    scale = canvas[0] / image.width
    fitted = image.resize(
        (canvas[0], max(1, int(image.height * scale))),
        Image.Resampling.BILINEAR,
    )
    top = (canvas[1] - fitted.height) // 2
    background.paste(fitted, (0, top))
    buffer = io.BytesIO()
    background.save(buffer, format="PNG")
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


def _stacked_screen(top: str, bottom: str, screen: tuple[int, int], fixture_set: str = "a") -> bytes:
    width, height = screen
    canvas = Image.new("RGB", screen, (0, 0, 0))
    canvas.paste(_cover(_fixture_image(top, fixture_set), (width, height // 2)), (0, 0))
    canvas.paste(_cover(_fixture_image(bottom, fixture_set), (width, height - height // 2)), (0, height // 2))
    return _png(canvas)


def _side_by_side_screen(
    left: str,
    right: str,
    screen: tuple[int, int],
    left_share: float,
    fixture_set: str = "a",
) -> Image.Image:
    width, height = screen
    left_width = round(width * left_share)
    canvas = Image.new("RGB", screen, (0, 0, 0))
    canvas.paste(_cover(_fixture_image(left, fixture_set), (left_width, height)), (0, 0))
    canvas.paste(_cover(_fixture_image(right, fixture_set), (width - left_width, height)), (left_width, 0))
    return canvas


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


def _tvos_b_pair_screen(next_button_focused: bool) -> bytes:
    canvas = _side_by_side_screen("A3", "A2", TV_4K_SCREEN, 0.65, "b")
    if next_button_focused:
        width, height = TV_4K_SCREEN
        ImageDraw.Draw(canvas).rounded_rectangle(
            (round(width * 0.90), round(height * 0.88), round(width * 0.96), round(height * 0.95)),
            radius=24,
            fill=(240, 240, 240),
        )
    return _png(canvas)


def _write_display_pack(directory: Path, before: bytes, after: bytes) -> None:
    (directory / "display-before.png").write_bytes(before)
    (directory / "display-after.png").write_bytes(after)
    (directory / "display-settings.png").write_bytes(_fixture_png("A1", "b"))
    (directory / "display-policy.json").write_text(
        json.dumps({"identity_source": "public_fixture_photo_mark"}),
        encoding="utf-8",
    )


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
        json.dumps({"identity_source": "public_fixture_photo_mark"}),
        encoding="utf-8",
    )


def _write_album_empty_pass(directory: Path) -> None:
    write_member_manifest(directory / "member-manifest.json", "a")
    (directory / "album-play-1.png").write_bytes(_fixture_png("A1"))
    (directory / "album-play-2.png").write_bytes(_fixture_png("A2"))
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
                "album_id": empty_album_id("a"),
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
    def test_wrong_member_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "album-play-2.png").write_bytes(_fixture_png("A4"))
            with self.assertRaises(Exception):
                evaluate_album_empty_evidence(directory)

    def test_missing_empty_result_screenshot_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").unlink()
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory)
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
                        evaluate_album_empty_evidence(directory)
                    self.assertIn(f"{filename} start_enabled must be a recorded Boolean", str(raised.exception))

    def test_settings_editor_without_start_button_records_not_applicable(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            payload = json.loads((directory / "empty-album.json").read_text(encoding="utf-8"))
            payload["start_enabled"] = "not_applicable_settings_editor"
            (directory / "empty-album.json").write_text(json.dumps(payload), encoding="utf-8")
            result = evaluate_album_empty_evidence(directory)
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
                    evaluate_album_empty_evidence(directory)

    def test_invented_empty_copy_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            payload = json.loads((directory / "empty-album.json").read_text(encoding="utf-8"))
            payload["empty_copy"] = "Invalid empty-album copy"
            (directory / "empty-album.json").write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(AlbumServerContractError):
                evaluate_album_empty_evidence(directory)

    def test_old_pool_photo_after_empty_album_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(_fixture_png("A1"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory)
            self.assertIn("old non-empty pool", str(raised.exception))

    def test_unrecorded_target_member_after_empty_album_still_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(_fixture_png("A3"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory)
            self.assertIn("old non-empty pool", str(raised.exception))

    def test_probe_identity_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            payload = json.loads((directory / "empty-album.json").read_text(encoding="utf-8"))
            payload["identity_source"] = "probe"
            (directory / "empty-album.json").write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(AlbumServerContractError):
                evaluate_album_empty_evidence(directory)

    def test_public_album_empty_pack_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            report = evaluate_album_empty_evidence(directory)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["empty_copy"], EMPTY_FILTERED_COPY)


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
            report = evaluate_album_empty_evidence(directory)
        self.assertEqual(report["verdict"], "PASS")
        self.assertGreaterEqual(len(set(report["marks"])), 2)

    def test_synthetic_iphone_album_empty_pack_passes_offline(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_synthetic_album_empty_pack(
                directory,
                _single_on_own_blur("A2", IPHONE_SCREEN),
                _single_on_own_blur("A3", IPHONE_SCREEN),
                _empty_result_screen(IPHONE_SCREEN),
            )
            report = evaluate_album_empty_evidence(directory)
        self.assertEqual(report["verdict"], "PASS")
        self.assertGreaterEqual(len(set(report["marks"])), 2)

    def test_real_a_single_as_empty_result_still_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(_fixture_png("A4"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory)
            self.assertIn("old non-empty pool", str(raised.exception))

    def test_real_b_single_as_empty_result_still_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(_fixture_png("A1", "b"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory)
            self.assertIn("old non-empty pool", str(raised.exception))

    def test_multi_as_empty_result_still_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(
                _side_by_side(_fixture_png("A1"), _fixture_png("A2"))
            )
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory)
            self.assertIn("old non-empty pool", str(raised.exception))

    def test_blurred_real_photo_as_empty_result_still_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_album_empty_pass(directory)
            (directory / "empty-album-result.png").write_bytes(_blurred_photo(_fixture_png("A4")))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_album_empty_evidence(directory)
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
                evaluate_album_empty_evidence(directory)
            self.assertIn("old non-empty pool", str(raised.exception))


class DisplayPolicyNegativeTests(unittest.TestCase):
    def test_enum_only_cannot_pass(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / "display-policy.json").write_text(
                json.dumps({"displayMode": "singlePhoto", "identity_source": "enum"}),
                encoding="utf-8",
            )
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_immediate_display_policy(directory)
            self.assertIn("enum", str(raised.exception))

    def test_missing_screenshots_fail(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(AlbumServerContractError):
                evaluate_immediate_display_policy(Path(raw))

    def test_transition_after_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / "display-before.png").write_bytes(_side_by_side(_fixture_png("A2"), _fixture_png("A3")))
            (directory / "display-settings.png").write_bytes(_fixture_png("A1"))
            mixed = _side_by_side(_fixture_png("A2"), _fixture_png("A1"))
            (directory / "display-after.png").write_bytes(mixed)
            try:
                evaluate_immediate_display_policy(directory)
            except AlbumServerContractError as error:
                self.assertTrue("transition" in str(error) or "multi-photo" in str(error) or "single-photo" in str(error))
            else:
                self.fail("Must fail when the after screen is not a stable single photo")

    def test_identical_before_after_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            multi = _side_by_side(_fixture_png("A2"), _fixture_png("A3"))
            (directory / "display-before.png").write_bytes(multi)
            (directory / "display-after.png").write_bytes(multi)
            (directory / "display-settings.png").write_bytes(_fixture_png("A1"))
            with self.assertRaises(AlbumServerContractError):
                evaluate_immediate_display_policy(directory)

    def test_stable_single_after_multi_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / "display-before.png").write_bytes(_side_by_side(_fixture_png("A2"), _fixture_png("A3")))
            (directory / "display-after.png").write_bytes(_fixture_png("A2"))
            (directory / "display-settings.png").write_bytes(_fixture_png("A1"))
            (directory / "display-policy.json").write_text(
                json.dumps({"identity_source": "public_fixture_photo_mark"}),
                encoding="utf-8",
            )
            report = evaluate_immediate_display_policy(directory)
        self.assertEqual(report["verdict"], "PASS")
        self.assertGreaterEqual(len(report["before_marks"]), 2)
        self.assertEqual(report["after_mark"], "A2")

    def test_single_b1_cannot_count_as_before_multi(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_display_pack(directory, _fixture_png("A1", "b"), _fixture_png("A2", "b"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_immediate_display_policy(directory)
            self.assertIn("multi-photo", str(raised.exception))

    def test_letterboxed_b1_cannot_count_as_before_multi(self) -> None:
        b1 = _fixture_png("A1", "b")
        b2 = _fixture_png("A2", "b")
        for canvas in ((1170, 2532), (1640, 2360), (1920, 1080)):
            with self.subTest(canvas=canvas), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                _write_display_pack(directory, _letterbox(b1, canvas), b2)
                with self.assertRaises(AlbumServerContractError) as raised:
                    evaluate_immediate_display_policy(directory)
                self.assertIn("multi-photo", str(raised.exception))

    def test_two_distinct_b_side_by_side_still_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            before = _side_by_side(_fixture_png("A2", "b"), _fixture_png("A3", "b"))
            _write_display_pack(directory, before, _fixture_png("A2", "b"))
            report = evaluate_immediate_display_policy(directory)
        self.assertEqual(report["verdict"], "PASS")
        self.assertGreaterEqual(len(report["before_marks"]), 2)

    def test_two_distinct_b_stacked_on_iphone_still_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            before = _stack_vertical_lower_bias(_fixture_png("A3", "b"), _fixture_png("A2", "b"))
            _write_display_pack(directory, before, _fixture_png("A2", "b"))
            report = evaluate_immediate_display_policy(directory)
        self.assertEqual(report["verdict"], "PASS")
        self.assertGreaterEqual(len(report["before_marks"]), 2)

    def test_server_switch_pack_with_single_b1_before_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / "display-before.png").write_bytes(_fixture_png("A1", "b"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_server_switch_evidence(directory)
            self.assertIn("multi-photo", str(raised.exception))

    def test_smart_fill_single_after_stacked_multi_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            before = _stack_vertical_lower_bias(_fixture_png("A3", "b"), _fixture_png("A2", "b"))
            after = _smart_fill_single(_fixture_png("A1", "b"))
            _write_display_pack(directory, before, after)
            report = evaluate_immediate_display_policy(directory)
        self.assertEqual(report["verdict"], "PASS")
        self.assertGreaterEqual(len(report["before_marks"]), 2)
        self.assertEqual(report["after_status"], "MATCH")

    def test_synthetic_iphone_server_switch_blurred_single_is_not_multi(self) -> None:
        # After the switch the blurred copy of one photo must not count as a second photo.
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_display_pack(
                directory,
                _stacked_screen("A3", "A2", IPHONE_SCREEN, "b"),
                _single_on_own_blur("A1", IPHONE_SCREEN, "b"),
            )
            report = evaluate_immediate_display_policy(directory)
        self.assertEqual(report["verdict"], "PASS")
        self.assertGreaterEqual(len(report["before_marks"]), 2)
        self.assertEqual(report["after_status"], "MATCH")
        self.assertIn(report["after_mark"], {"A1", "A2", "A3", "A4", "A5"})


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
            (directory / "switch-b-play-2.png").write_bytes(_fixture_png("A2", "a"))
            with self.assertRaises(AlbumServerContractError) as raised:
                evaluate_server_switch_evidence(directory)
            self.assertIn("pass as B", str(raised.exception))

    def test_two_b_panels_are_public_pattern_b(self) -> None:
        image = _side_by_side(_fixture_png("A3", "b"), _fixture_png("A2", "b"))
        self.assertEqual(classify_public_pattern(image), "b")

    def test_a_and_b_panels_together_are_rejected(self) -> None:
        image = _side_by_side(_fixture_png("A3", "a"), _fixture_png("A2", "b"))
        self.assertIsNone(classify_public_pattern(image))
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            (directory / "switch-b-play-1.png").write_bytes(image)
            (directory / "switch-b-play-2.png").write_bytes(image)
            with self.assertRaises(AlbumServerContractError):
                evaluate_server_switch_evidence(directory)

    def test_server_switch_pack_with_side_by_side_b_playback_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            _write_server_switch_pass(directory)
            panels = _side_by_side(_fixture_png("A3", "b"), _fixture_png("A2", "b"))
            (directory / "switch-b-play-1.png").write_bytes(panels)
            (directory / "switch-b-play-2.png").write_bytes(panels)
            report = evaluate_server_switch_evidence(directory)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["b_pattern"], "b")

    def test_synthetic_tvos_server_switch_frames_are_pattern_b(self) -> None:
        for next_button_focused in (False, True):
            frame = _tvos_b_pair_screen(next_button_focused)
            self.assertEqual(classify_public_pattern(frame), "b", next_button_focused)

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
        self.assertIn("server-switch-display", command)
        self.assertNotIn("xcodebuild", command)


if __name__ == "__main__":
    unittest.main()
