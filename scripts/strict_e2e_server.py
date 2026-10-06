#!/usr/bin/env python3
"""Public, deterministic Immich-compatible server for strict E2E use only."""

from __future__ import annotations

import argparse
import copy
import functools
import hashlib
import json
import logging
import math
import os
import socket
import struct
import sys
import threading
import time
import zlib
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, BinaryIO
from urllib.parse import parse_qs, urlparse


PUBLIC_API_KEY = "immichslides-public-e2e-key"
FIXTURE_SETS = ("a", "b")
SCENARIOS = ("normal", "html-200", "timeout", "out-of-order")
MAX_REQUEST_BODY_BYTES = 64 * 1024
REQUEST_BODY_TIMEOUT_SECONDS = 5
# An earlier timing run measured Continue→second Select at 1100ms; 1600ms leaves tvOS a 500ms margin for two nexts.
TVOS_CONTINUE_TO_SECOND_SELECT_MS = 1100
OUT_OF_ORDER_DELAY_MARGIN_MS = 500
OUT_OF_ORDER_DELAYED_ASSET_MS = TVOS_CONTINUE_TO_SECOND_SELECT_MS + OUT_OF_ORDER_DELAY_MARGIN_MS
REQUIRED_SEARCH_VALUES = {
    "isOffline": False,
    "visibility": "timeline",
    "withDeleted": False,
    "withExif": True,
    "withPeople": True,
    "withStacked": True,
}


def server_argument_error(port: int, timeout_seconds: float) -> str | None:
    if not 0 <= port <= 65535:
        return "port must be in 0...65535"
    if not math.isfinite(timeout_seconds) or timeout_seconds < 0:
        return "timeout-seconds must be a nonnegative finite value"
    return None


GLYPHS = {
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "B": ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    "1": ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    "2": ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    "3": ("11110", "00001", "00001", "01110", "00001", "00001", "11110"),
    "4": ("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    "5": ("11111", "10000", "10000", "11110", "00001", "00001", "11110"),
}


def public_visual_label(fixture_set: str, index: int) -> str:
    letter = "B" if fixture_set == "b" else "A"
    return f"{letter}{index}"


def _png(width: int, height: int, seed: int, label: str, *, striped: bool = False) -> bytes:
    """Keep on-screen fixture identity deterministic without fonts or third-party image generators."""
    scale = max(8, min(width // 18, height // 10))
    label_width = (len(label) * 5 + len(label) - 1) * scale
    label_height = 7 * scale
    label_x = (width - label_width) // 2
    label_y = (height - label_height) // 2

    def is_label_pixel(x: int, y: int) -> bool:
        relative_x = x - label_x
        relative_y = y - label_y
        if not 0 <= relative_x < label_width or not 0 <= relative_y < label_height:
            return False
        character_stride = 6 * scale
        character_index, character_x = divmod(relative_x, character_stride)
        if character_index >= len(label) or character_x >= 5 * scale:
            return False
        glyph = GLYPHS[label[character_index]]
        return glyph[relative_y // scale][character_x // scale] == "1"

    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            if is_label_pixel(x, y):
                rows.extend((255, 255, 255))
            else:
                # A uses a checkerboard and B horizontal stripes; hue seeds are unchanged, so color
                # identification still recognizes A1-A5.
                block = (y // 48) % 2 if striped else ((x // 48) + (y // 48)) % 2
                rows.extend(
                    (
                        (seed * 37 + block * 54) % 180,
                        (seed * 61 + (1 - block) * 48) % 180,
                        (seed * 19 + block * 72) % 180,
                    )
                )

    def chunk(kind: bytes, payload: bytes) -> bytes:
        checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(
        b"IDAT", zlib.compress(bytes(rows), level=9)
    ) + chunk(b"IEND", b"")


def _fixture_data(name: str) -> dict[str, Any]:
    # Callers get a copy so no caller can corrupt the shared cache; PNG bytes are immutable and are not duplicated.
    return copy.deepcopy(_cached_fixture_data(name))


# Building a fixture set draws every PNG pixel by pixel and is deterministic, so build each set once.
@functools.lru_cache(maxsize=None)
def _cached_fixture_data(name: str) -> dict[str, Any]:
    if name not in FIXTURE_SETS:
        raise ValueError(f"Unknown fixture set: {name}")

    # Public PNGs keep small identity color blocks; the API width/height are scaled 12x to simulate 4K-class
    # originals.
    png_dimensions = [(320, 180), (180, 320), (300, 300), (360, 240), (240, 360)]
    original_dimension_scale = 12
    delays = [OUT_OF_ORDER_DELAYED_ASSET_MS, 0, 0, 0, 0]
    people = [
        {
            "id": f"person-{name}-normal",
            "name": "Normal Synthetic",
            "isHidden": False,
            "isFavorite": True,
            "faces": [{"id": f"face-{name}-normal"}],
        },
        {
            "id": f"person-{name}-solo",
            "name": "Solo Synthetic",
            "isHidden": False,
            "isFavorite": False,
            "faces": [{"id": f"face-{name}-solo"}],
        },
        {
            "id": f"person-{name}-other",
            "name": "Other Synthetic",
            "isHidden": False,
            "isFavorite": False,
            "faces": [{"id": f"face-{name}-other"}],
        },
        {
            "id": f"person-{name}-no-faces",
            "name": "No Faces Synthetic",
            "isHidden": False,
            "isFavorite": False,
            "faces": [],
        },
    ]
    asset_people = [[people[0]], [people[1]], [people[1], people[2]], [people[3]], [people[1]]]
    unassigned_faces = [[], [], [], [], [{"id": f"unassigned-{name}-1"}]]
    assets: list[dict[str, Any]] = []
    images: dict[str, bytes] = {}
    for index, ((png_width, png_height), delay) in enumerate(zip(png_dimensions, delays), start=1):
        asset_id = f"asset-{name}-{index}"
        # Color identity stays A1-A5 for screenshot classification; B screens use the B glyph and stripes.
        label = f"A{index}"
        visual_label = public_visual_label(name, index)
        width = png_width * original_dimension_scale
        height = png_height * original_dimension_scale
        image = _png(png_width, png_height, index, visual_label, striped=(name == "b"))
        images[asset_id] = image
        exif_info = (
            {
                "make": "immichSlides Synthetic",
                "model": f"Fixture {index}",
                "fNumber": 2.8,
                "exposureTime": "1/125",
                "iso": 100,
                "focalLength": 50.0,
                "dateTimeOriginal": f"2026-01-{index:02d}T12:00:00.000Z",
                "city": "Fixture City",
                "state": "Fixture State",
                "country": "Synthetic",
                "exifImageWidth": width,
                "exifImageHeight": height,
                "orientation": "1",
            }
            if index % 2 == 1
            else {}
        )
        assets.append(
            {
                "id": asset_id,
                "label": label,
                "type": "IMAGE",
                "isFavorite": index % 2 == 1,
                "isTrashed": False,
                "isArchived": False,
                "width": width,
                "height": height,
                "thumbhash": None,
                "livePhotoVideoID": None,
                "unassignedFaces": unassigned_faces[index - 1],
                "tags": ["public-synthetic", name],
                "people": asset_people[index - 1],
                "exifInfo": exif_info,
                "synthetic": True,
                "fullsize_delay_ms": delay,
                "sha256": hashlib.sha256(image).hexdigest(),
            }
        )

    albums = [
        {
            "id": f"album-{name}-target",
            "albumName": "Target Synthetic Album B" if name == "b" else "Target Synthetic Album",
            "fixture_role": "target",
            "albumThumbnailAssetId": assets[0]["id"],
            "assetCount": 3,
            "assets": [],
            "assetIds": [asset["id"] for asset in assets[:3]],
        },
        {
            "id": f"album-{name}-non-target",
            "albumName": "Non-target Synthetic Album B" if name == "b" else "Non-target Synthetic Album",
            "fixture_role": "non_target",
            "albumThumbnailAssetId": assets[3]["id"],
            "assetCount": 2,
            "assets": [],
            "assetIds": [asset["id"] for asset in assets[3:]],
        },
        {
            "id": f"album-{name}-empty",
            "albumName": "Empty Synthetic Album B" if name == "b" else "Empty Synthetic Album",
            "fixture_role": "empty",
            "albumThumbnailAssetId": None,
            "assetCount": 0,
            "assets": [],
            "assetIds": [],
        },
    ]
    person_cases = {
        "normal_match": [assets[0]["id"]],
        "solo_only_qualified": [assets[1]["id"]],
        "multiple_people_disqualified": [assets[2]["id"]],
        "no_faces": [assets[3]["id"]],
    }
    return {
        "name": name,
        "assets": assets,
        "albums": albums,
        "people": people,
        "person_cases": person_cases,
        "images": images,
    }


def fixture_manifest(name: str) -> dict[str, Any]:
    fixture = _fixture_data(name)
    manifest: dict[str, Any] = {
        "schema_version": 1,
        "fixture_set": name,
        "asset_ids": [asset["id"] for asset in fixture["assets"]],
        "album_ids": [album["id"] for album in fixture["albums"]],
        "person_ids": [person["id"] for person in fixture["people"]],
        "assets": fixture["assets"],
        "albums": fixture["albums"],
        "people": fixture["people"],
        "person_cases": fixture["person_cases"],
    }
    canonical = json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode(
        "utf-8"
    )
    manifest["fixture_sha256"] = hashlib.sha256(canonical).hexdigest()
    return manifest


class StrictE2EServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        server_address: tuple[str, int],
        *,
        fixture_set: str,
        scenario: str,
        timeout_seconds: float,
        logger: logging.Logger,
    ) -> None:
        if scenario not in SCENARIOS:
            raise ValueError(f"Unknown scenario: {scenario}")
        self.fixture = _fixture_data(fixture_set)
        self.scenario = scenario
        self.timeout_seconds = timeout_seconds
        self.contract_logger = logger
        self.started_at = time.monotonic()
        self.image_response_lock = threading.Lock()
        self.image_response: dict[str, Any] = {"mode": "normal", "asset_id": None, "failures": 0}
        super().__init__(server_address, StrictE2ERequestHandler)


class StrictE2ERequestHandler(BaseHTTPRequestHandler):
    server: StrictE2EServer

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self._json(HTTPStatus.OK, {"status": "ok", "fixture_set": self.server.fixture["name"]})
            return
        if not self._is_authorized():
            return

        if parsed.path == "/api/test/image-response":
            with self.server.image_response_lock:
                response = dict(self.server.image_response)
            self._json(HTTPStatus.OK, response)
            return

        if parsed.path == "/api/albums":
            albums = [{key: value for key, value in album.items() if key != "assetIds"} for album in self.server.fixture["albums"]]
            self._json(HTTPStatus.OK, albums)
            return
        if parsed.path == "/api/people":
            people = self.server.fixture["people"]
            requested_size = parse_qs(parsed.query).get("size", [None])[0]
            if requested_size is not None:
                try:
                    people = people[: max(0, int(requested_size))]
                except ValueError:
                    self._error(HTTPStatus.BAD_REQUEST, "size must be an integer")
                    return
            self._json(HTTPStatus.OK, {"people": people})
            return
        if parsed.path == "/api/api-keys/me":
            self._json(
                HTTPStatus.OK,
                {"permissions": ["asset.read", "asset.view", "asset.download", "album.read", "album.statistics", "person.read", "person.statistics"]},
            )
            return

        parts = parsed.path.strip("/").split("/")
        if len(parts) == 4 and parts[:2] == ["api", "people"] and parts[3] == "thumbnail":
            person_id = parts[2]
            matching_assets = [
                asset
                for asset in self.server.fixture["assets"]
                if person_id in {person["id"] for person in asset["people"]}
            ]
            if not matching_assets:
                self._error(HTTPStatus.NOT_FOUND, "Person not found")
                return
            asset_id = matching_assets[0]["id"]
            self._image(self.server.fixture["images"][asset_id], fixture_asset_id=asset_id)
            return
        if len(parts) == 4 and parts[:2] == ["api", "people"] and parts[3] == "statistics":
            person_id = parts[2]
            if person_id not in {person["id"] for person in self.server.fixture["people"]}:
                self._error(HTTPStatus.NOT_FOUND, "Person not found")
                return
            count = sum(
                person_id in {person["id"] for person in asset["people"]}
                for asset in self.server.fixture["assets"]
            )
            self._json(HTTPStatus.OK, {"assets": count})
            return
        if len(parts) == 3 and parts[:2] == ["api", "assets"]:
            asset = self._asset(parts[2])
            if asset is None:
                return
            self._json(HTTPStatus.OK, self._public_asset(asset))
            return
        if len(parts) == 4 and parts[:2] == ["api", "assets"] and parts[3] == "thumbnail":
            asset = self._asset(parts[2])
            if asset is None:
                return
            size = parse_qs(parsed.query).get("size", [None])[0]
            if size not in {"thumbnail", "preview", "fullsize"}:
                self._error(HTTPStatus.BAD_REQUEST, "size does not match the contract")
                return
            self._log_request_started(size=size, fixture_asset_id=asset["id"])
            with self.server.image_response_lock:
                control = self.server.image_response
                mode = control["mode"] if control["asset_id"] == asset["id"] and size == "fullsize" else "normal"
                if mode != "normal":
                    control["failures"] += 1
            if mode != "normal":
                self._send(
                    HTTPStatus.SERVICE_UNAVAILABLE if mode == "http" else HTTPStatus.OK,
                    b"controlled image failure", "image/png",
                    fixture_asset_id=asset["id"], size=size,
                )
                return
            if self.server.scenario == "out-of-order" and size in {"preview", "fullsize"}:
                time.sleep(asset["fullsize_delay_ms"] / 1000)
            self._image(
                self.server.fixture["images"][asset["id"]],
                fixture_asset_id=asset["id"],
                size=size,
            )
            return

        self._error(HTTPStatus.NOT_FOUND, "Unknown route")

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if not self._is_authorized():
            return
        if parsed.path == "/api/test/image-response":
            body = self._json_body()
            if body is None:
                return
            mode, asset_id = body.get("mode"), body.get("asset_id")
            known_ids = {asset["id"] for asset in self.server.fixture["assets"]}
            if not isinstance(mode, str) or mode not in {"normal", "http", "decode"} or (
                mode != "normal" and (not isinstance(asset_id, str) or asset_id not in known_ids)
            ):
                self._error(HTTPStatus.BAD_REQUEST, "Invalid image response control")
                return
            with self.server.image_response_lock:
                self.server.image_response = {"mode": mode, "asset_id": asset_id, "failures": 0}
            self._json(HTTPStatus.OK, {"mode": mode, "asset_id": asset_id, "failures": 0})
            return
        if parsed.path != "/api/search/random":
            self._error(HTTPStatus.NOT_FOUND, "Unknown route")
            return
        if self.server.scenario == "timeout":
            time.sleep(self.server.timeout_seconds)
        if self.server.scenario == "html-200":
            self._send(HTTPStatus.OK, b"<!doctype html><title>synthetic gateway</title>", "text/html; charset=utf-8")
            return

        body = self._json_body()
        if body is None:
            return
        if not isinstance(body.get("size"), int) or body["size"] < 1:
            self._error(HTTPStatus.BAD_REQUEST, "size does not match the contract")
            return
        for key, expected_value in REQUIRED_SEARCH_VALUES.items():
            if body.get(key) != expected_value:
                self._error(HTTPStatus.BAD_REQUEST, f"{key} does not match the contract")
                return

        assets = self.server.fixture["assets"]
        album_ids = body.get("albumIds")
        if album_ids is not None:
            if not isinstance(album_ids, list):
                self._error(HTTPStatus.BAD_REQUEST, "albumIds does not match the contract")
                return
            known_albums = {album["id"]: album for album in self.server.fixture["albums"]}
            if any(album_id not in known_albums for album_id in album_ids):
                self._error(HTTPStatus.BAD_REQUEST, "albumIds contains an unknown ID")
                return
            allowed = {asset_id for album_id in album_ids for asset_id in known_albums[album_id]["assetIds"]}
            assets = [asset for asset in assets if asset["id"] in allowed]

        person_ids = body.get("personIds")
        if person_ids is not None:
            known_people = {person["id"] for person in self.server.fixture["people"]}
            if not isinstance(person_ids, list) or any(person_id not in known_people for person_id in person_ids):
                self._error(HTTPStatus.BAD_REQUEST, "personIds does not match the contract")
                return
            selected_people = set(person_ids)
            assets = [
                asset
                for asset in assets
                if selected_people.intersection(person["id"] for person in asset["people"])
            ]

        self._json(HTTPStatus.OK, [self._public_asset(asset) for asset in assets[: body["size"]]])

    def _is_authorized(self) -> bool:
        if self.headers.get("x-api-key") == PUBLIC_API_KEY:
            return True
        self._error(HTTPStatus.UNAUTHORIZED, "Invalid API key")
        return False

    def _json_body(self) -> dict[str, Any] | None:
        if "application/json" not in self.headers.get("Content-Type", "").lower():
            self._error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "Content-Type must be application/json")
            return None
        lengths = self.headers.get_all("Content-Length", [])
        length_text = lengths[0].strip(" \t") if len(lengths) == 1 else ""
        if (
            self.headers.get("Transfer-Encoding") is not None
            or len(lengths) != 1
            or not length_text.isascii()
            or not length_text.isdecimal()
        ):
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "Invalid request body framing")
            return None
        try:
            length = int(length_text)
        except ValueError:
            length = MAX_REQUEST_BODY_BYTES + 1
        if length > MAX_REQUEST_BODY_BYTES:
            self.close_connection = True
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Request body exceeds the fixture limit")
            return None

        previous_timeout = self.connection.gettimeout()
        deadline = time.monotonic() + REQUEST_BODY_TIMEOUT_SECONDS
        payload = bytearray()
        read_status = None
        try:
            while len(payload) < length:
                remaining_seconds = deadline - time.monotonic()
                if remaining_seconds <= 0:
                    raise TimeoutError
                self.connection.settimeout(remaining_seconds)
                chunk = self.rfile.read1(length - len(payload))
                if not chunk:
                    read_status = HTTPStatus.BAD_REQUEST
                    break
                payload.extend(chunk)
        except (TimeoutError, socket.timeout):
            read_status = HTTPStatus.REQUEST_TIMEOUT
        except OSError:
            read_status = HTTPStatus.BAD_REQUEST
        finally:
            self.connection.settimeout(previous_timeout)
        if read_status is not None:
            self.close_connection = True
            self._error(read_status, "Incomplete JSON request body")
            return None
        try:
            body = json.loads(payload)
        except (ValueError, json.JSONDecodeError):
            self._error(HTTPStatus.BAD_REQUEST, "Invalid JSON request body")
            return None
        if not isinstance(body, dict):
            self._error(HTTPStatus.BAD_REQUEST, "JSON request body must be an object")
            return None
        return body

    def _asset(self, asset_id: str) -> dict[str, Any] | None:
        for asset in self.server.fixture["assets"]:
            if asset["id"] == asset_id:
                return asset
        self._error(HTTPStatus.NOT_FOUND, "Asset not found")
        return None

    @staticmethod
    def _public_asset(asset: dict[str, Any]) -> dict[str, Any]:
        return {
            key: value
            for key, value in asset.items()
            if key not in {"synthetic", "fullsize_delay_ms", "sha256"}
        }

    def _redacted_path(self) -> str:
        log_parts = urlparse(self.path).path.strip("/").split("/")
        if len(log_parts) >= 3 and log_parts[:2] in (["api", "assets"], ["api", "people"]):
            log_parts[2] = "<fixture-id>"
        return "/" + "/".join(log_parts)

    def _log_request_started(self, *, size: str, fixture_asset_id: str) -> None:
        # The start time only proves the request timeline; path is redacted and cannot serve as on-screen identity.
        self.server.contract_logger.info(
            "request_started elapsed_ms=%d method=%s path=%s size=%s range=%s fixture_asset_id=%s",
            int((time.monotonic() - self.server.started_at) * 1000),
            self.command,
            self._redacted_path(),
            size,
            "present" if self.headers.get("Range") else "absent",
            fixture_asset_id,
        )

    def _image(self, image: bytes, *, fixture_asset_id: str, size: str | None = None) -> None:
        range_header = self.headers.get("Range")
        if range_header is None:
            self._send(
                HTTPStatus.OK,
                image,
                "image/png",
                extra_headers={"Accept-Ranges": "bytes"},
                fixture_asset_id=fixture_asset_id,
                size=size,
            )
            return
        if not range_header.startswith("bytes=") or "," in range_header:
            self._error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, "Range does not match the contract")
            return
        try:
            start_text, end_text = range_header.removeprefix("bytes=").split("-", maxsplit=1)
            start = int(start_text)
            end = min(int(end_text) if end_text else len(image) - 1, len(image) - 1)
        except ValueError:
            self._error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, "Range does not match the contract")
            return
        if start < 0 or start > end or start >= len(image):
            self._error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, "Range exceeds the image")
            return
        payload = image[start : end + 1]
        self._send(
            HTTPStatus.PARTIAL_CONTENT,
            payload,
            "image/png",
            extra_headers={
                "Accept-Ranges": "bytes",
                "Content-Range": f"bytes {start}-{end}/{len(image)}",
            },
            fixture_asset_id=fixture_asset_id,
            size=size,
        )

    def _json(self, status: HTTPStatus, payload: object) -> None:
        self._send(
            status,
            json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8"),
            "application/json; charset=utf-8",
        )

    def _error(self, status: HTTPStatus, message: str) -> None:
        self._json(status, {"error": message, "statusCode": int(status)})

    def _send(
        self,
        status: HTTPStatus,
        payload: bytes,
        content_type: str,
        *,
        extra_headers: dict[str, str] | None = None,
        fixture_asset_id: str | None = None,
        size: str | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
        self.end_headers()
        logged_path = self._redacted_path()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            self.server.contract_logger.info(
                "client_disconnected method=%s path=%s", self.command, logged_path
            )
        # fixture_asset_id can only come from public synthetic data generated by this server; any ID from the
        # request input is already redacted in path.
        size_suffix = f" size={size}" if size else ""
        self.server.contract_logger.info(
            "request elapsed_ms=%d method=%s path=%s status=%d range=%s fixture_asset_id=%s%s",
            int((time.monotonic() - self.server.started_at) * 1000),
            self.command,
            logged_path,
            int(status),
            "present" if self.headers.get("Range") else "absent",
            fixture_asset_id or "none",
            size_suffix,
        )

    def log_message(self, _format: str, *_args: object) -> None:
        return


def create_server(
    *,
    host: str,
    port: int,
    fixture_set: str,
    scenario: str,
    timeout_seconds: float = 25,
    log_stream: BinaryIO | None = None,
) -> StrictE2EServer:
    logger = logging.getLogger(f"strict-e2e-{id(log_stream)}-{port}")
    logger.handlers.clear()
    handler: logging.Handler
    if log_stream is None:
        handler = logging.NullHandler()
    else:
        handler = logging.StreamHandler(log_stream)
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False
    return StrictE2EServer(
        (host, port),
        fixture_set=fixture_set,
        scenario=scenario,
        timeout_seconds=timeout_seconds,
        logger=logger,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--fixture-set", choices=FIXTURE_SETS, default="a")
    parser.add_argument("--scenario", choices=SCENARIOS, default="normal")
    parser.add_argument("--timeout-seconds", type=float, default=25)
    parser.add_argument("--manifest-out", type=Path)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--log-file", type=Path)
    arguments = parser.parse_args(argv)

    if argument_error := server_argument_error(arguments.port, arguments.timeout_seconds):
        print(f"Invalid server arguments: {argument_error}.", file=sys.stderr)
        return 2

    log_handle = None
    try:
        manifest = fixture_manifest(arguments.fixture_set)
        if arguments.manifest_out:
            arguments.manifest_out.parent.mkdir(parents=True, exist_ok=True)
            arguments.manifest_out.write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

        log_handle = arguments.log_file.open("a", encoding="utf-8") if arguments.log_file else None
        server = create_server(
            host=arguments.host,
            port=arguments.port,
            fixture_set=arguments.fixture_set,
            scenario=arguments.scenario,
            timeout_seconds=arguments.timeout_seconds,
            log_stream=log_handle,
        )
        if arguments.ready_file:
            arguments.ready_file.parent.mkdir(parents=True, exist_ok=True)
            host, port = server.server_address
            arguments.ready_file.write_text(
                json.dumps({"host": host, "port": port, "pid": os.getpid()}, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        server.serve_forever()
        return 0
    except OSError as error:
        print(f"Server file I/O failed: {error}", file=sys.stderr)
        return 2
    finally:
        if log_handle is not None:
            log_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
