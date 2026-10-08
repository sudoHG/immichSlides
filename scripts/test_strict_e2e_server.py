#!/usr/bin/env python3
"""HTTP contract tests for the public controlled Immich test server."""

from __future__ import annotations

import json
import http.client
import io
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import zlib
from contextlib import redirect_stderr
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent

import strict_e2e_server  # noqa: E402
from strict_e2e_server import (  # noqa: E402
    PUBLIC_API_KEY,
    TVOS_CONTINUE_TO_SECOND_SELECT_MS,
    create_server,
    fixture_manifest,
    main as server_main,
)


def png_white_pixel_bounds(payload: bytes) -> tuple[int, int, int, int, int]:
    width = int.from_bytes(payload[16:20], "big")
    height = int.from_bytes(payload[20:24], "big")
    offset = 8
    compressed = bytearray()
    while offset < len(payload):
        length = int.from_bytes(payload[offset : offset + 4], "big")
        kind = payload[offset + 4 : offset + 8]
        data = payload[offset + 8 : offset + 8 + length]
        if kind == b"IDAT":
            compressed.extend(data)
        offset += 12 + length
    raw = zlib.decompress(bytes(compressed))
    stride = width * 3 + 1
    white_pixels: list[tuple[int, int]] = []
    for y in range(height):
        row = raw[y * stride : (y + 1) * stride]
        if row[0] != 0:
            raise ValueError("Test images must use PNG rows without filters.")
        for x in range(width):
            pixel = row[1 + x * 3 : 1 + (x + 1) * 3]
            if pixel == b"\xff\xff\xff":
                white_pixels.append((x, y))
    if not white_pixels:
        raise ValueError("Test image is missing the white public label.")
    xs = [pixel[0] for pixel in white_pixels]
    ys = [pixel[1] for pixel in white_pixels]
    return min(xs), max(xs), min(ys), max(ys), len(white_pixels)


class RunningServer:
    def __init__(
        self,
        *,
        fixture_set: str = "a",
        scenario: str = "normal",
        log_stream: io.StringIO | None = None,
    ) -> None:
        self.server = create_server(
            host="127.0.0.1",
            port=0,
            fixture_set=fixture_set,
            scenario=scenario,
            timeout_seconds=0.2,
            log_stream=log_stream,
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> "RunningServer":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    @property
    def base_url(self) -> str:
        host, port = self.server.server_address
        return f"http://{host}:{port}/api"

    def request(
        self,
        path: str,
        *,
        method: str = "GET",
        body: object | None = None,
        api_key: str = PUBLIC_API_KEY,
        headers: dict[str, str] | None = None,
        timeout: float = 2,
    ) -> tuple[int, dict[str, str], bytes]:
        request_headers = {"x-api-key": api_key}
        if headers:
            request_headers.update(headers)
        encoded_body = None
        if body is not None:
            encoded_body = json.dumps(body).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=encoded_body,
            headers=request_headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, dict(response.headers), response.read()
        except urllib.error.HTTPError as error:
            return error.code, dict(error.headers), error.read()

    def health(self) -> tuple[int, dict[str, str], bytes]:
        host, port = self.server.server_address
        with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=2) as response:
            return response.status, dict(response.headers), response.read()


LOG_WAIT_DEADLINE_SECONDS = 10.0
LOG_POLL_INTERVAL_SECONDS = 0.005


def wait_for_request_started(log_stream: io.StringIO, *, asset_id: str, size: str) -> None:
    """Block until the server logged the start of this request, or fail at a deadline."""
    deadline = time.monotonic() + LOG_WAIT_DEADLINE_SECONDS
    while not any(
        line.startswith("request_started ")
        and f"size={size} " in line
        and line.endswith(f"fixture_asset_id={asset_id}")
        for line in log_stream.getvalue().splitlines()
    ):
        if time.monotonic() >= deadline:
            raise AssertionError(f"Server never logged the start of {asset_id} {size} before the deadline.")
        time.sleep(LOG_POLL_INTERVAL_SECONDS)


def logged_request_events(log: str, *, size: str) -> list[tuple[str, str, int]]:
    """Return (kind, fixture asset id, server elapsed ms) in log order for one image size."""
    events: list[tuple[str, str, int]] = []
    for line in log.splitlines():
        if f"size={size}" not in line.split() or "fixture_asset_id=" not in line:
            continue
        if line.startswith("request_started "):
            kind = "started"
        elif line.startswith("request "):
            kind = "completed"
        else:
            continue
        asset_id = line.split("fixture_asset_id=", 1)[1].split()[0]
        elapsed = int(line.split("elapsed_ms=", 1)[1].split()[0])
        events.append((kind, asset_id, elapsed))
    return events


class StrictE2EServerContractTests(unittest.TestCase):
    def raw_post(self, server: RunningServer, headers: bytes, body: bytes = b"", *, truncate: bool = False) -> bytes:
        with socket.create_connection(server.server.server_address, timeout=2) as connection:
            connection.sendall(
                b"POST /api/search/random HTTP/1.0\r\n"
                + f"x-api-key: {PUBLIC_API_KEY}\r\n".encode()
                + b"Content-Type: application/json\r\n" + headers + b"\r\n" + body
            )
            if truncate:
                connection.shutdown(socket.SHUT_WR)
            response = bytearray()
            while chunk := connection.recv(65536):
                response.extend(chunk)
            return bytes(response)

    def test_request_body_rejects_invalid_framing_and_oversized_lengths(self) -> None:
        with RunningServer() as server:
            for headers, status in [
                (b"Content-Length: -1\r\n", 400),
                (b"Content-Length: invalid\r\n", 400),
                (b"Content-Length: 2\r\nContent-Length: 2\r\n", 400),
                (b"Transfer-Encoding: chunked\r\n", 400),
                (b"Content-Length: 65537\r\n", 413),
            ]:
                with self.subTest(headers=headers):
                    self.assertIn(f" {status} ".encode(), self.raw_post(server, headers))
            self.assertEqual(server.health()[0], 200)

    def test_request_body_rejects_truncation_and_invalid_json_without_crashing(self) -> None:
        with RunningServer() as server:
            for length, body in [(20, b"{}"), (2, b"\xff\xff"), (2, b"[]"), (0, b"")]:
                with self.subTest(body=body):
                    response = self.raw_post(server, f"Content-Length: {length}\r\n".encode(), body, truncate=True)
                    self.assertIn(b" 400 ", response)
            self.assertEqual(server.health()[0], 200)

    def test_request_body_times_out_without_blocking_other_requests(self) -> None:
        with mock.patch.object(strict_e2e_server, "REQUEST_BODY_TIMEOUT_SECONDS", 0.2, create=True):
            with RunningServer() as server:
                started = time.monotonic()
                response = self.raw_post(server, b"Content-Length: 20\r\n", b"{")
                self.assertIn(b" 408 ", response)
                self.assertLess(time.monotonic() - started, 1.5)
                self.assertEqual(server.health()[0], 200)

    def test_valid_json_body_can_arrive_in_separate_network_writes(self) -> None:
        body = json.dumps({"size": 5, **strict_e2e_server.REQUIRED_SEARCH_VALUES}).encode()
        with RunningServer() as server:
            with socket.create_connection(server.server.server_address, timeout=2) as connection:
                connection.sendall(
                    b"POST /api/search/random HTTP/1.0\r\n"
                    + f"x-api-key: {PUBLIC_API_KEY}\r\n".encode()
                    + b"Content-Type: application/json\r\n"
                    + f"Content-Length: {len(body)}\r\n\r\n".encode() + body[:1]
                )
                connection.sendall(body[1:])
                response = bytearray()
                while chunk := connection.recv(65536):
                    response.extend(chunk)
                self.assertIn(b" 200 ", response)
                self.assertEqual(len(json.loads(response.split(b"\r\n\r\n", 1)[1])), 5)

    def test_body_deadline_is_not_reset_by_trickling_bytes(self) -> None:
        with mock.patch.object(strict_e2e_server, "REQUEST_BODY_TIMEOUT_SECONDS", 0.2):
            with RunningServer() as server:
                with socket.create_connection(server.server.server_address, timeout=2) as connection:
                    connection.sendall(
                        b"POST /api/search/random HTTP/1.0\r\n"
                        + f"x-api-key: {PUBLIC_API_KEY}\r\n".encode()
                        + b"Content-Type: application/json\r\nContent-Length: 20\r\n\r\n"
                    )
                    finished = threading.Event()

                    def trickle() -> None:
                        for _ in range(20):
                            if finished.wait(0.03):
                                return
                            try:
                                connection.sendall(b" ")
                            except OSError:
                                return

                    sender = threading.Thread(target=trickle)
                    sender.start()
                    started = time.monotonic()
                    try:
                        response = http.client.HTTPResponse(connection)
                        response.begin()
                        finished.set()
                        self.assertEqual(response.status, 408)
                        self.assertEqual(json.loads(response.read())["statusCode"], 408)
                        self.assertLess(time.monotonic() - started, 0.5)
                    finally:
                        finished.set()
                        sender.join(timeout=2)
                    self.assertFalse(sender.is_alive())

    def test_request_body_accepts_the_size_boundary(self) -> None:
        body = json.dumps({"size": 5, **strict_e2e_server.REQUIRED_SEARCH_VALUES}).encode()
        body = body.ljust(strict_e2e_server.MAX_REQUEST_BODY_BYTES, b" ")
        with RunningServer() as server:
            response = self.raw_post(server, f"Content-Length: {len(body)}\r\n".encode(), body)
            self.assertIn(b" 200 ", response)
            self.assertEqual(len(json.loads(response.split(b"\r\n\r\n", 1)[1])), 5)

    def test_content_length_accepts_surrounding_http_whitespace(self) -> None:
        body = json.dumps({"size": 5, **strict_e2e_server.REQUIRED_SEARCH_VALUES}).encode()
        with RunningServer() as server:
            response = self.raw_post(server, f"Content-Length: \t{len(body)} \t\r\n".encode(), body)
            self.assertIn(b" 200 ", response)
            self.assertEqual(len(json.loads(response.split(b"\r\n\r\n", 1)[1])), 5)

    def test_server_reports_output_io_failure_without_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            blocking_file = Path(raw_directory) / "not-a-directory"
            blocking_file.write_text("keep", encoding="utf-8")
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                exit_code = server_main(
                    [
                        "--port",
                        "0",
                        "--manifest-out",
                        str(blocking_file / "manifest.json"),
                    ]
                )

            self.assertEqual(exit_code, 2)
            self.assertIn("Server file I/O failed", stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())

    def test_server_rejects_invalid_ports_and_timeouts_without_traceback(self) -> None:
        self.assertIn("finite", strict_e2e_server.server_argument_error(0, float("nan")) or "")
        self.assertIn("finite", strict_e2e_server.server_argument_error(0, float("inf")) or "")
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            exit_code = server_main(["--port", "70000"])
        self.assertEqual(exit_code, 2)
        self.assertIn("port must be in", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

        stderr = io.StringIO()
        with redirect_stderr(stderr):
            exit_code = server_main(["--port", "0", "--timeout-seconds", "-0.1"])
        self.assertEqual(exit_code, 2)
        self.assertIn("timeout-seconds must be a nonnegative finite value", stderr.getvalue())

    def test_fixture_sets_are_public_deterministic_and_mutually_exclusive(self) -> None:
        server_a = fixture_manifest("a")
        server_b = fixture_manifest("b")

        self.assertEqual(server_a["asset_ids"], [f"asset-a-{index}" for index in range(1, 6)])
        self.assertEqual(server_b["asset_ids"], [f"asset-b-{index}" for index in range(1, 6)])
        self.assertEqual([asset["label"] for asset in server_a["assets"]], ["A1", "A2", "A3", "A4", "A5"])
        self.assertEqual([asset["label"] for asset in server_b["assets"]], ["A1", "A2", "A3", "A4", "A5"])
        from strict_e2e_server import public_visual_label, _fixture_data

        live_a = _fixture_data("a")
        live_b = _fixture_data("b")
        self.assertEqual(
            [public_visual_label("b", index) for index in range(1, 6)],
            ["B1", "B2", "B3", "B4", "B5"],
        )
        self.assertNotEqual(live_a["images"]["asset-a-1"], live_b["images"]["asset-b-1"])
        self.assertNotEqual(live_a["assets"][0]["sha256"], live_b["assets"][0]["sha256"])
        self.assertEqual(live_b["albums"][0]["albumName"], "Target Synthetic Album B")
        self.assertTrue(set(server_a["asset_ids"]).isdisjoint(server_b["asset_ids"]))
        self.assertTrue(set(server_a["album_ids"]).isdisjoint(server_b["album_ids"]))
        self.assertTrue(set(server_a["person_ids"]).isdisjoint(server_b["person_ids"]))
        self.assertEqual(server_a, fixture_manifest("a"))
        self.assertEqual(len(server_a["fixture_sha256"]), 64)
        self.assertNotIn("public_api_key", server_a)

        albums = {album["fixture_role"]: album for album in server_a["albums"]}
        self.assertEqual(albums["target"]["assetIds"], ["asset-a-1", "asset-a-2", "asset-a-3"])
        self.assertEqual(albums["non_target"]["assetIds"], ["asset-a-4", "asset-a-5"])
        self.assertEqual(albums["empty"]["assetIds"], [])
        self.assertEqual(albums["empty"]["assetCount"], 0)
        self.assertEqual(albums["empty"]["id"], "album-a-empty")

        cases = server_a["person_cases"]
        self.assertEqual(cases["normal_match"], ["asset-a-1"])
        self.assertEqual(cases["solo_only_qualified"], ["asset-a-2"])
        self.assertEqual(cases["multiple_people_disqualified"], ["asset-a-3"])
        self.assertEqual(cases["no_faces"], ["asset-a-4"])
        self.assertEqual(
            server_a["assets"][0]["exifInfo"],
            {
                "make": "immichSlides Synthetic",
                "model": "Fixture 1",
                "fNumber": 2.8,
                "exposureTime": "1/125",
                "iso": 100,
                "focalLength": 50.0,
                "dateTimeOriginal": "2026-01-01T12:00:00.000Z",
                "city": "Fixture City",
                "state": "Fixture State",
                "country": "Synthetic",
                "exifImageWidth": 3840,
                "exifImageHeight": 2160,
                "orientation": "1",
            },
        )
        self.assertEqual(server_a["assets"][1]["exifInfo"], {})
        self.assertEqual((server_a["assets"][1]["width"], server_a["assets"][1]["height"]), (2160, 3840))
        self.assertEqual((server_a["assets"][2]["width"], server_a["assets"][2]["height"]), (3600, 3600))

    def test_normal_contract_covers_health_filters_permissions_and_range(self) -> None:
        with RunningServer() as server:
            status, headers, body = server.health()
            self.assertEqual(status, 200)
            self.assertIn("application/json", headers["Content-Type"])
            self.assertEqual(json.loads(body)["status"], "ok")

            status, headers, body = server.request(
                "/search/random",
                method="POST",
                body={
                    "size": 5,
                    "albumIds": ["album-a-target"],
                    "personIds": ["person-a-normal"],
                    "isOffline": False,
                    "visibility": "timeline",
                    "withDeleted": False,
                    "withExif": True,
                    "withPeople": True,
                    "withStacked": True,
                },
                headers={"Accept": "application/json"},
            )
            assets = json.loads(body)
            self.assertEqual(status, 200)
            self.assertIn("application/json", headers["Content-Type"])
            self.assertGreaterEqual(len(assets), 1)
            self.assertEqual([asset["id"] for asset in assets], ["asset-a-1"])
            self.assertEqual(assets[0]["people"][0]["id"], "person-a-normal")
            self.assertIn("exifInfo", assets[0])

            status, headers, body = server.request("/albums")
            self.assertEqual(status, 200)
            self.assertIn("application/json", headers["Content-Type"])
            self.assertGreaterEqual(len(json.loads(body)), 2)

            status, headers, body = server.request("/people?size=1")
            self.assertEqual(status, 200)
            self.assertIn("application/json", headers["Content-Type"])
            self.assertEqual(len(json.loads(body)["people"]), 1)

            status, headers, body = server.request("/people/person-a-normal/statistics")
            self.assertEqual(status, 200)
            self.assertIn("application/json", headers["Content-Type"])
            self.assertGreater(json.loads(body)["assets"], 0)

            status, headers, body = server.request("/people/person-a-normal/thumbnail")
            self.assertEqual(status, 200)
            self.assertIn("image/png", headers["Content-Type"])
            self.assertEqual(body[:8], b"\x89PNG\r\n\x1a\n")

            status, headers, body = server.request("/api-keys/me")
            self.assertEqual(status, 200)
            self.assertIn("application/json", headers["Content-Type"])
            self.assertEqual(
                json.loads(body)["permissions"],
                [
                    "asset.read",
                    "asset.view",
                    "asset.download",
                    "album.read",
                    "album.statistics",
                    "person.read",
                    "person.statistics",
                ],
            )

            status, headers, body = server.request("/assets/asset-a-1")
            self.assertEqual(status, 200)
            self.assertIn("application/json", headers["Content-Type"])
            self.assertEqual(json.loads(body)["id"], "asset-a-1")

            for size in ("thumbnail", "preview"):
                status, headers, body = server.request(
                    f"/assets/asset-a-1/thumbnail?size={size}"
                )
                self.assertEqual(status, 200)
                self.assertIn("image/png", headers["Content-Type"])
                self.assertEqual(body[:8], b"\x89PNG\r\n\x1a\n")

            status, headers, body = server.request(
                "/assets/asset-a-1/thumbnail?size=fullsize",
                headers={"Range": "bytes=0-31"},
            )
            self.assertEqual(status, 206)
            self.assertEqual(headers["Content-Range"].split("/")[0], "bytes 0-31")
            self.assertEqual(len(body), 32)
            self.assertEqual(body[:8], b"\x89PNG\r\n\x1a\n")

            status, headers, _ = server.request(
                "/assets/asset-a-1/thumbnail?size=fullsize",
                headers={"Range": "bytes=999999-"},
            )
            self.assertEqual(status, 416)
            self.assertIn("application/json", headers["Content-Type"])

            status, _, body = server.request("/assets/asset-a-1/thumbnail?size=fullsize")
            self.assertEqual(status, 200)
            min_x, max_x, min_y, max_y, white_count = png_white_pixel_bounds(body)
            self.assertAlmostEqual((min_x + max_x) / 2, 160, delta=20)
            self.assertAlmostEqual((min_y + max_y) / 2, 90, delta=20)
            self.assertGreater(white_count, 500)

    def test_controlled_fullsize_failures_leave_other_fixture_responses_unchanged(self) -> None:
        with RunningServer() as server:
            status, _, _ = server.request(
                "/test/image-response", method="POST", body={"asset_id": "asset-a-1", "mode": "http"},
            )
            self.assertEqual(status, 200)
            for _ in range(4):
                status, _, payload = server.request("/assets/asset-a-1/thumbnail?size=fullsize")
                self.assertEqual(status, 503)
                self.assertNotEqual(payload[:8], b"\x89PNG\r\n\x1a\n")
            status, _, payload = server.request("/test/image-response")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(payload)["failures"], 4)
            for asset_id, size in (("asset-a-1", "preview"), ("asset-a-2", "fullsize")):
                status, _, payload = server.request(f"/assets/{asset_id}/thumbnail?size={size}")
                self.assertEqual(status, 200)
                self.assertEqual(payload, server.server.fixture["images"][asset_id])
            server.request("/test/image-response", method="POST", body={"mode": "normal"})
            status, _, payload = server.request("/assets/asset-a-1/thumbnail?size=fullsize")
            self.assertEqual(status, 200)
            self.assertEqual(payload, server.server.fixture["images"]["asset-a-1"])

    def test_invalid_auth_bad_contract_and_unknown_route_fail_closed(self) -> None:
        log_stream = io.StringIO()
        with RunningServer(log_stream=log_stream) as server:
            status, headers, _ = server.request(
                "/search/random",
                method="POST",
                body={"size": 1},
                api_key="wrong-key",
            )
            self.assertEqual(status, 401)
            self.assertIn("application/json", headers["Content-Type"])

            status, _, _ = server.request(
                "/search/random",
                method="POST",
                body={"size": 1, "visibility": "archive"},
            )
            self.assertEqual(status, 400)

            status, _, _ = server.request("/not-a-real-route")
            self.assertEqual(status, 404)

            server.request("/assets/asset-a-1/thumbnail?size=preview")

        log = log_stream.getvalue()
        self.assertIn("elapsed_ms=", log)
        self.assertIn("fixture_asset_id=asset-a-1", log)
        self.assertNotIn(PUBLIC_API_KEY, log)

    def test_html_timeout_and_out_of_order_scenarios_are_deterministic(self) -> None:
        with RunningServer(scenario="html-200") as server:
            status, headers, body = server.request(
                "/search/random",
                method="POST",
                body={
                    "size": 1,
                    "isOffline": False,
                    "visibility": "timeline",
                    "withDeleted": False,
                    "withExif": True,
                    "withPeople": True,
                    "withStacked": True,
                },
            )
            self.assertEqual(status, 200)
            self.assertIn("text/html", headers["Content-Type"])
            self.assertTrue(body.startswith(b"<!doctype html>"))

        with RunningServer(scenario="timeout") as server:
            started = time.monotonic()
            with self.assertRaises((TimeoutError, socket.timeout)):
                server.request(
                    "/search/random",
                    method="POST",
                    body={},
                    timeout=0.05,
                )
            self.assertLess(time.monotonic() - started, 0.2)

    def test_out_of_order_logs_start_and_complete_timeline_without_secrets(self) -> None:
        log_stream = io.StringIO()
        with RunningServer(scenario="out-of-order", log_stream=log_stream) as server:
            with ThreadPoolExecutor(max_workers=2) as executor:
                old_request = executor.submit(
                    server.request,
                    "/assets/asset-a-1/thumbnail?size=preview",
                    timeout=4,
                )
                time.sleep(0.03)
                server.request("/assets/asset-a-2/thumbnail?size=preview")
                old_request.result(timeout=5)

        log = log_stream.getvalue()
        self.assertNotIn(PUBLIC_API_KEY, log)
        self.assertIn("request_started", log)
        self.assertRegex(
            log,
            r"request_started elapsed_ms=\d+ method=GET path=/api/assets/<fixture-id>/thumbnail size=preview range=absent fixture_asset_id=asset-a-1",
        )
        self.assertRegex(
            log,
            r"request_started elapsed_ms=\d+ method=GET path=/api/assets/<fixture-id>/thumbnail size=preview range=absent fixture_asset_id=asset-a-2",
        )
        completes: dict[str, int] = {}
        starts: dict[str, int] = {}
        for line in log.splitlines():
            if "fixture_asset_id=asset-a-" not in line or "elapsed_ms=" not in line:
                continue
            elapsed = int(line.split("elapsed_ms=", 1)[1].split()[0])
            asset_id = "asset-a-1" if "fixture_asset_id=asset-a-1" in line else "asset-a-2"
            if line.startswith("request_started "):
                starts[asset_id] = elapsed
            elif line.startswith("request "):
                completes[asset_id] = elapsed
        self.assertIn("size=preview", log)
        self.assertRegex(
            log,
            r"request elapsed_ms=\d+ method=GET path=/api/assets/<fixture-id>/thumbnail "
            r"status=200 range=absent fixture_asset_id=asset-a-1 size=preview",
        )
        self.assertEqual(set(starts), {"asset-a-1", "asset-a-2"})
        self.assertEqual(set(completes), {"asset-a-1", "asset-a-2"})
        self.assertLess(starts["asset-a-1"], completes["asset-a-2"])
        self.assertLess(completes["asset-a-2"], completes["asset-a-1"])
        self.assertGreater(
            completes["asset-a-1"] - starts["asset-a-1"],
            TVOS_CONTINUE_TO_SECOND_SELECT_MS,
        )

    def test_normal_scenario_logs_asset_request_start_for_cache_reload_pairing(self) -> None:
        log_stream = io.StringIO()
        with RunningServer(log_stream=log_stream) as server:
            server.request("/assets/asset-a-3/thumbnail?size=preview")
            server.request("/people/person-a-normal/thumbnail")

        lines = log_stream.getvalue().splitlines()
        started = [line for line in lines if line.startswith("request_started ")]
        self.assertEqual(len(started), 1, lines)
        self.assertRegex(
            started[0],
            r"^request_started elapsed_ms=\d+ method=GET path=/api/assets/<fixture-id>/thumbnail "
            r"size=preview range=absent fixture_asset_id=asset-a-3$",
        )
        completed = [line for line in lines if line.startswith("request ")]
        self.assertLess(lines.index(started[0]), lines.index(completed[0]))

    def test_out_of_order_does_not_delay_thumbnail(self) -> None:
        log_stream = io.StringIO()
        with RunningServer(scenario="out-of-order", log_stream=log_stream) as server:
            with ThreadPoolExecutor(max_workers=1) as executor:
                delayed_preview = executor.submit(
                    server.request, "/assets/asset-a-1/thumbnail?size=preview", timeout=10
                )
                wait_for_request_started(log_stream, asset_id="asset-a-1", size="preview")
                status, _, body = server.request("/assets/asset-a-1/thumbnail?size=thumbnail")
                self.assertFalse(
                    delayed_preview.done(),
                    "The thumbnail must be served while the delayed preview is still held back.",
                )
                delayed_preview.result(timeout=10)
        self.assertEqual(status, 200)
        self.assertEqual(body[:8], b"\x89PNG\r\n\x1a\n")
        log_lines = log_stream.getvalue().splitlines()
        thumbnail_done = next(
            index
            for index, line in enumerate(log_lines)
            if line.startswith("request ") and "size=thumbnail" in line
        )
        preview_done = next(
            index
            for index, line in enumerate(log_lines)
            if line.startswith("request ") and "size=preview" in line
        )
        self.assertLess(thumbnail_done, preview_done)

    def test_out_of_order_delays_preview_and_fullsize_repeatably(self) -> None:
        for size in ("preview", "fullsize"):
            with self.subTest(size=size):
                for _ in range(2):
                    self._assert_out_of_order_completion(size)

    def _assert_out_of_order_completion(self, size: str) -> None:
        log_stream = io.StringIO()
        with RunningServer(scenario="out-of-order", log_stream=log_stream) as server:
            with ThreadPoolExecutor(max_workers=1) as executor:
                old_request = executor.submit(
                    server.request, f"/assets/asset-a-1/thumbnail?size={size}", timeout=10
                )
                wait_for_request_started(log_stream, asset_id="asset-a-1", size=size)
                new_status, _, _ = server.request(f"/assets/asset-a-2/thumbnail?size={size}")
                self.assertFalse(
                    old_request.done(),
                    "The newer request must finish while the older one is still held back.",
                )
                old_status, _, _ = old_request.result(timeout=10)
        self.assertEqual((old_status, new_status), (200, 200))
        events = logged_request_events(log_stream.getvalue(), size=size)
        self.assertEqual(
            [(kind, asset_id) for kind, asset_id, _ in events],
            [
                ("started", "asset-a-1"),
                ("started", "asset-a-2"),
                ("completed", "asset-a-2"),
                ("completed", "asset-a-1"),
            ],
        )
        old_started, _, new_completed, old_completed = (elapsed for _, _, elapsed in events)
        self.assertGreater(old_completed - old_started, TVOS_CONTINUE_TO_SECOND_SELECT_MS)
        self.assertGreater(old_completed - new_completed, 100)


if __name__ == "__main__":
    unittest.main()
