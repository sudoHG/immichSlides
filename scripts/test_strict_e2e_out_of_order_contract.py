#!/usr/bin/env python3
"""Shared out-of-order contract: timeline, input audit, public identification, negatives must fail first."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256  # noqa: E402
from strict_e2e_out_of_order_contract import (  # noqa: E402
    OUT_OF_ORDER_STEPS,
    OutOfOrderContractError,
    assert_current_scene_holds,
    assert_out_of_order_timeline,
    audit_runner_inputs,
    evaluate_out_of_order_identity,
)
from strict_e2e_photo_identity import classify_screenshot  # noqa: E402
from access_lifecycle_contract import capture_identity  # noqa: E402
from strict_e2e_server import (  # noqa: E402
    PUBLIC_API_KEY,
    TVOS_CONTINUE_TO_SECOND_SELECT_MS,
    _fixture_data,
    fixture_manifest,
)
from test_strict_e2e_server import RunningServer  # noqa: E402


def _fixture_png(label: str, fixture_set: str = "a") -> bytes:
    return _fixture_data(fixture_set)["images"][f"asset-{fixture_set}-{label[-1]}"]


def _stacked_fixture_png(top: str, bottom: str) -> bytes:
    from PIL import Image

    canvas = Image.new("RGB", (360, 800))
    for label, y in ((top, 0), (bottom, 400)):
        with Image.open(io.BytesIO(_fixture_png(label))) as source:
            canvas.paste(source.convert("RGB").resize((360, 400)), (0, y))
    output = io.BytesIO()
    canvas.save(output, format="PNG")
    return output.getvalue()


def _capture_out_of_order_log(size: str) -> str:
    log_stream = io.StringIO()
    with RunningServer(scenario="out-of-order", log_stream=log_stream) as server:
        with ThreadPoolExecutor(max_workers=2) as executor:
            old_request = executor.submit(
                server.request,
                f"/assets/asset-a-1/thumbnail?size={size}",
                timeout=4,
            )
            time.sleep(0.03)
            server.request(f"/assets/asset-a-2/thumbnail?size={size}")
            old_request.result(timeout=5)
    return log_stream.getvalue()


def _request_line(elapsed_ms: int, path: str, *, method: str = "GET", status: int = 200, size: str | None = None, asset: str = "none", started: bool = False) -> str:
    range_flag = "present" if started and size else "absent"
    if started:
        return (
            f"request_started elapsed_ms={elapsed_ms} method={method} path={path} "
            f"size={size} range={range_flag} fixture_asset_id={asset}"
        )
    size_suffix = f" size={size}" if size else ""
    return (
        f"request elapsed_ms={elapsed_ms} method={method} path={path} status={status} "
        f"range={range_flag} fixture_asset_id={asset}{size_suffix}"
    )


def _connection_then_save_random_log() -> str:
    # Connection test + save: one random each, plus a completed A1 preview/fullsize.
    lines = [
        _request_line(20, "/healthz"),
        _request_line(100, "/api/search/random", method="POST", asset="none"),
        _request_line(101, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-1", started=True),
        _request_line(401, "/api/assets/<fixture-id>/thumbnail", status=206, size="preview", asset="asset-a-1"),
        _request_line(402, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-1", started=True),
        _request_line(702, "/api/assets/<fixture-id>/thumbnail", status=206, size="fullsize", asset="asset-a-1"),
        _request_line(800, "/api/search/random", method="POST", asset="none"),
        _request_line(801, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-1", started=True),
        _request_line(1101, "/api/assets/<fixture-id>/thumbnail", status=206, size="preview", asset="asset-a-1"),
        _request_line(1102, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-1", started=True),
        _request_line(1402, "/api/assets/<fixture-id>/thumbnail", status=206, size="fullsize", asset="asset-a-1"),
    ]
    return "\n".join(lines) + "\n"


def _playback_continue_random_line(elapsed_ms: int = 2000) -> str:
    return _request_line(elapsed_ms, "/api/search/random", method="POST", asset="none") + "\n"


def _iphone_playback_fullsize_overlap_log() -> str:
    # After tapping Continue, A1 fullsize overlaps A2; the A1 request from the
    # connection test has already finished.
    return (
        _connection_then_save_random_log()
        + _playback_continue_random_line(2000)
        + "\n".join(
            [
                _request_line(2010, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-1", started=True),
                _request_line(2300, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-2", started=True),
                _request_line(2300, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-2"),
                _request_line(2310, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-1"),
                _request_line(2320, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-2", started=True),
                _request_line(2320, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-2"),
                _request_line(2321, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-1", started=True),
                _request_line(2621, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-1"),
            ]
        )
        + "\n"
    )


def _ipad_playback_preview_overlap_log() -> str:
    # After tapping Continue, A1 fullsize finishes first; A1 preview still overlaps the A2 from the two nexts.
    return (
        _connection_then_save_random_log()
        + _playback_continue_random_line(2000)
        + "\n".join(
            [
                _request_line(2010, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-1", started=True),
                _request_line(2310, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-1"),
                _request_line(2320, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-1", started=True),
                _request_line(2400, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-2", started=True),
                _request_line(2400, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-2"),
                _request_line(2410, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-2", started=True),
                _request_line(2410, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-2"),
                _request_line(2620, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-1"),
            ]
        )
        + "\n"
    )


def _playback_window_without_late_overlap_log() -> str:
    # After tapping Continue, both sizes of the old photo finish first, so the two nexts no longer overlap.
    return (
        _connection_then_save_random_log()
        + _playback_continue_random_line(2000)
        + "\n".join(
            [
                _request_line(2010, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-1", started=True),
                _request_line(2310, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-1"),
                _request_line(2311, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-1", started=True),
                _request_line(2611, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-1"),
                _request_line(2700, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-2", started=True),
                _request_line(2700, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-2"),
                _request_line(2701, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-2", started=True),
                _request_line(2701, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-2"),
            ]
        )
        + "\n"
    )


def _tvos_mid_playback_random_preview_overlap_log() -> str:
    # After Continue, another random request arrives while the A1 preview is still in flight; it must remain in the
    # playback window.
    return (
        _connection_then_save_random_log()
        + _playback_continue_random_line(2000)
        + "\n".join(
            [
                _request_line(2010, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-1", started=True),
                _request_line(2310, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-1"),
                _request_line(2320, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-1", started=True),
                _request_line(2400, "/api/search/random", method="POST", asset="none"),
                _request_line(2500, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-2", started=True),
                _request_line(2500, "/api/assets/<fixture-id>/thumbnail", size="fullsize", asset="asset-a-2"),
                _request_line(2510, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-2", started=True),
                _request_line(2510, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-2"),
                _request_line(2700, "/api/assets/<fixture-id>/thumbnail", size="preview", asset="asset-a-1"),
            ]
        )
        + "\n"
    )


def _write_identity_evidence(
    evidence: Path,
    *,
    current: bytes,
    after_late: bytes,
    log_text: str,
    fixture_set: str = "a",
    server_url: str = "http://127.0.0.1:9/api",
) -> None:
    (evidence / "ooo-current-scene.png").write_bytes(current)
    (evidence / "ooo-after-late.png").write_bytes(after_late)
    (evidence / "redacted-request.log").write_text(log_text, encoding="utf-8")
    manifest = fixture_manifest(fixture_set)
    (evidence / "fixture-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (evidence / "service-ready.json").write_text(
        json.dumps({"host": "127.0.0.1", "port": 9, "pid": 1}, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (evidence / "runner-server-url.txt").write_text(server_url + "\n", encoding="utf-8")


class OutOfOrderTimelineTests(unittest.TestCase):
    def test_preview_and_fullsize_logs_prove_old_request_finishes_last(self) -> None:
        self.assertEqual(OUT_OF_ORDER_STEPS, ("ooo-current-scene", "ooo-after-late"))
        for size in ("preview", "fullsize"):
            with self.subTest(size=size):
                first = _capture_out_of_order_log(size)
                second = _capture_out_of_order_log(size)
                for log_text in (first, second):
                    self.assertNotIn(PUBLIC_API_KEY, log_text)
                    payload = assert_out_of_order_timeline(
                        log_text,
                        delayed_asset_id="asset-a-1",
                        immediate_asset_id="asset-a-2",
                        size=size,
                    )
                    self.assertGreater(payload["delayed_complete_ms"] - payload["immediate_complete_ms"], 100)
                    self.assertLess(payload["delayed_start_ms"], payload["immediate_complete_ms"])
                    self.assertGreater(
                        payload["delayed_complete_ms"] - payload["delayed_start_ms"],
                        TVOS_CONTINUE_TO_SECOND_SELECT_MS,
                    )
                    self.assertIn(f"size={size}", log_text)
                    self.assertRegex(
                        log_text,
                        rf"request elapsed_ms=\d+ method=GET path=/api/assets/<fixture-id>/thumbnail "
                        rf"status=200 range=absent fixture_asset_id=asset-a-1 size={size}",
                    )

    def test_overlapping_preview_and_fullsize_still_finish_old_last(self) -> None:
        log_stream = io.StringIO()
        with RunningServer(scenario="out-of-order", log_stream=log_stream) as server:
            with ThreadPoolExecutor(max_workers=4) as executor:
                old_preview = executor.submit(
                    server.request,
                    "/assets/asset-a-1/thumbnail?size=preview",
                    timeout=4,
                )
                old_fullsize = executor.submit(
                    server.request,
                    "/assets/asset-a-1/thumbnail?size=fullsize",
                    timeout=4,
                )
                time.sleep(0.03)
                new_preview = executor.submit(
                    server.request, "/assets/asset-a-2/thumbnail?size=preview"
                )
                new_fullsize = executor.submit(
                    server.request, "/assets/asset-a-2/thumbnail?size=fullsize"
                )
                for handle in (old_preview, old_fullsize, new_preview, new_fullsize):
                    status, _, _ = handle.result(timeout=5)
                    self.assertEqual(status, 200)
        log_text = log_stream.getvalue()
        for size in ("preview", "fullsize"):
            payload = assert_out_of_order_timeline(
                log_text,
                delayed_asset_id="asset-a-1",
                immediate_asset_id="asset-a-2",
                size=size,
            )
            self.assertGreater(payload["delayed_complete_ms"] - payload["immediate_complete_ms"], 100)

    def test_timeline_cannot_be_used_as_photo_identity(self) -> None:
        log_text = _capture_out_of_order_log("fullsize")
        with self.assertRaises(OutOfOrderContractError) as raised:
            assert_current_scene_holds(
                classify_screenshot(b""),
                classify_screenshot(b""),
            )
        self.assertIn("Unrecognizable", str(raised.exception))
        self.assertNotIn("asset-a-2", str(raised.exception))
        self.assertIn("fixture_asset_id=asset-a-2", log_text)


class OutOfOrderIdentityTests(unittest.TestCase):
    def test_public_fixture_marks_at_key_times_must_hold_current_scene(self) -> None:
        current = classify_screenshot(_fixture_png("A3"))
        after = classify_screenshot(_fixture_png("A3"))
        self.assertEqual(assert_current_scene_holds(current, after), "A3")

    def test_evaluate_accepts_fixture_pngs_and_redacted_timeline(self) -> None:
        log_text = _capture_out_of_order_log("preview")
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_identity_evidence(
                evidence,
                current=_fixture_png("A4"),
                after_late=_fixture_png("A4"),
                log_text=log_text,
            )
            report = evaluate_out_of_order_identity(evidence)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["mark"], "A4")
        self.assertEqual(report["identity_source"], "public_fixture_photo_mark")
        self.assertTrue(report["request_log_is_not_identity"])
        self.assertNotEqual(report["mark"], "asset-a-1")

    def test_evaluate_accepts_unchanged_two_photo_scene(self) -> None:
        log_text = _capture_out_of_order_log("preview")
        scene = _stacked_fixture_png("A3", "A4")
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_identity_evidence(evidence, current=scene, after_late=scene, log_text=log_text)
            report = evaluate_out_of_order_identity(evidence)
        self.assertEqual(report["mark"], "A3+A4")

    def test_evaluate_ignores_connection_probe_and_accepts_playback_fullsize_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_identity_evidence(
                evidence,
                current=_fixture_png("A3"),
                after_late=_fixture_png("A3"),
                log_text=_iphone_playback_fullsize_overlap_log(),
            )
            report = evaluate_out_of_order_identity(evidence)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["mark"], "A3")
        self.assertIn("fullsize", report["timeline"])
        self.assertGreater(
            report["timeline"]["fullsize"]["delayed_complete_ms"],
            report["timeline"]["fullsize"]["immediate_complete_ms"],
        )
        self.assertGreaterEqual(report["timeline"]["fullsize"]["delayed_start_ms"], 2000)

    def test_evaluate_accepts_playback_preview_overlap_when_fullsize_already_finished(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_identity_evidence(
                evidence,
                current=_fixture_png("A3"),
                after_late=_fixture_png("A3"),
                log_text=_ipad_playback_preview_overlap_log(),
            )
            report = evaluate_out_of_order_identity(evidence)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["mark"], "A3")
        self.assertIn("preview", report["timeline"])
        self.assertGreater(
            report["timeline"]["preview"]["delayed_complete_ms"],
            report["timeline"]["preview"]["immediate_complete_ms"],
        )
        self.assertGreaterEqual(report["timeline"]["preview"]["delayed_start_ms"], 2000)

    def test_evaluate_keeps_in_flight_preview_when_mid_playback_random_arrives(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_identity_evidence(
                evidence,
                current=_fixture_png("A3"),
                after_late=_fixture_png("A3"),
                log_text=_tvos_mid_playback_random_preview_overlap_log(),
            )
            report = evaluate_out_of_order_identity(evidence)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["mark"], "A3")
        self.assertIn("preview", report["timeline"])
        self.assertGreaterEqual(report["timeline"]["preview"]["delayed_start_ms"], 2000)
        self.assertLess(report["timeline"]["preview"]["delayed_start_ms"], 2400)
        self.assertGreater(
            report["timeline"]["preview"]["delayed_complete_ms"],
            report["timeline"]["preview"]["immediate_complete_ms"],
        )


class OutOfOrderNegativeTests(unittest.TestCase):
    def test_unchanged_old_photo_cannot_pass(self) -> None:
        old = classify_screenshot(_fixture_png("A1"))
        with self.assertRaises(OutOfOrderContractError) as raised:
            assert_current_scene_holds(old, old)
        self.assertIn("Old photo", str(raised.exception))

    def test_old_photo_inside_two_photo_scene_cannot_pass(self) -> None:
        old_scene = _stacked_fixture_png("A1", "A3")
        with self.assertRaises(OutOfOrderContractError) as raised:
            assert_current_scene_holds(
                capture_identity(old_scene),
                capture_identity(old_scene),
            )
        self.assertIn("Old photo", str(raised.exception))

    def test_changed_second_photo_inside_two_photo_scene_cannot_pass(self) -> None:
        with self.assertRaises(OutOfOrderContractError) as raised:
            assert_current_scene_holds(
                capture_identity(_stacked_fixture_png("A3", "A4")),
                capture_identity(_stacked_fixture_png("A3", "A5")),
            )
        self.assertIn("Wrong image", str(raised.exception))

    def test_wrong_photo_after_late_request_fails(self) -> None:
        with self.assertRaises(OutOfOrderContractError) as raised:
            assert_current_scene_holds(
                classify_screenshot(_fixture_png("A3")),
                classify_screenshot(_fixture_png("A1")),
            )
        self.assertIn("Wrong image", str(raised.exception))

    def test_black_frame_cannot_pass(self) -> None:
        from PIL import Image

        buffer = io.BytesIO()
        Image.new("RGB", (320, 180), (0, 0, 0)).save(buffer, format="PNG")
        with self.assertRaises(OutOfOrderContractError) as raised:
            assert_current_scene_holds(
                classify_screenshot(_fixture_png("A3")),
                classify_screenshot(buffer.getvalue()),
            )
        self.assertIn("All black", str(raised.exception))

    def test_unrecognizable_frame_cannot_pass(self) -> None:
        with self.assertRaises(OutOfOrderContractError) as raised:
            assert_current_scene_holds(
                classify_screenshot(_fixture_png("A3")),
                classify_screenshot(b"not-a-png"),
            )
        self.assertIn("Unrecognizable", str(raised.exception))

    def test_missing_key_frame_cannot_pass(self) -> None:
        log_text = _capture_out_of_order_log("fullsize")
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_identity_evidence(
                evidence,
                current=_fixture_png("A2"),
                after_late=_fixture_png("A2"),
                log_text=log_text,
            )
            (evidence / "ooo-after-late.png").unlink()
            with self.assertRaises(OutOfOrderContractError) as raised:
                evaluate_out_of_order_identity(evidence)
        self.assertIn("Missing required timeline screenshots", str(raised.exception))

    def test_unknown_request_fails_the_batch(self) -> None:
        with self.assertRaises(OutOfOrderContractError) as raised:
            audit_runner_inputs(
                fixture_set="a",
                observed_hash=FROZEN_FIXTURE_SHA256["a"],
                service_log=(
                    "request elapsed_ms=1 method=GET path=/not-a-real-route "
                    "status=404 range=absent fixture_asset_id=none\n"
                ),
                server_url="http://127.0.0.1:9/api",
            )
        self.assertIn("Unknown request", str(raised.exception))

    def test_playback_window_without_late_overlap_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_identity_evidence(
                evidence,
                current=_fixture_png("A3"),
                after_late=_fixture_png("A3"),
                log_text=_playback_window_without_late_overlap_log(),
            )
            with self.assertRaises(OutOfOrderContractError) as raised:
                evaluate_out_of_order_identity(evidence)
        self.assertIn("The old request must complete after the current request", str(raised.exception))

    def test_evaluate_does_not_retry_a_failed_identity(self) -> None:
        log_text = _capture_out_of_order_log("preview")
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_identity_evidence(
                evidence,
                current=_fixture_png("A3"),
                after_late=_fixture_png("A1"),
                log_text=log_text,
            )
            with self.assertRaises(OutOfOrderContractError):
                evaluate_out_of_order_identity(evidence)
            with self.assertRaises(OutOfOrderContractError) as raised:
                evaluate_out_of_order_identity(evidence)
        self.assertIn("Wrong image", str(raised.exception))


class RunnerInputAuditTests(unittest.TestCase):
    def test_bad_body_and_hash_mismatch_fail_closed(self) -> None:
        with self.assertRaises(OutOfOrderContractError) as raised:
            audit_runner_inputs(
                fixture_set="a",
                observed_hash=FROZEN_FIXTURE_SHA256["a"],
                service_log=(
                    "request elapsed_ms=2 method=POST path=/api/search/random "
                    "status=400 range=absent fixture_asset_id=none\n"
                ),
                server_url="http://127.0.0.1:9/api",
            )
        self.assertIn("Request body does not match the contract", str(raised.exception))

        with self.assertRaises(OutOfOrderContractError) as raised:
            audit_runner_inputs(
                fixture_set="a",
                observed_hash="0" * 64,
                service_log="request elapsed_ms=1 method=GET path=/healthz status=200 range=absent fixture_asset_id=none\n",
                server_url="http://127.0.0.1:9/api",
            )
        self.assertIn("fixture hash", str(raised.exception))

    def test_real_server_fallback_is_rejected(self) -> None:
        with self.assertRaises(OutOfOrderContractError) as raised:
            audit_runner_inputs(
                fixture_set="a",
                observed_hash=FROZEN_FIXTURE_SHA256["a"],
                service_log="request elapsed_ms=1 method=GET path=/healthz status=200 range=absent fixture_asset_id=none\n",
                server_url="https://demo.immich.app/api",
            )
        self.assertIn("real server", str(raised.exception))

    def test_local_hash_matching_log_passes_without_using_ids_as_identity(self) -> None:
        log_text = (
            "request elapsed_ms=1 method=GET path=/healthz status=200 range=absent fixture_asset_id=none\n"
            "request elapsed_ms=2 method=GET path=/api/assets/<fixture-id>/thumbnail "
            "status=200 range=absent fixture_asset_id=asset-a-2\n"
        )
        payload = audit_runner_inputs(
            fixture_set="a",
            observed_hash=FROZEN_FIXTURE_SHA256["a"],
            service_log=log_text,
            server_url="http://127.0.0.1:9/api",
        )
        self.assertEqual(payload["verdict"], "PASS")
        self.assertTrue(payload["request_log_is_not_identity"])
        self.assertNotIn("x-api-key", log_text)
        self.assertEqual(observed_hash_from_live_fixture(), FROZEN_FIXTURE_SHA256["a"])


def observed_hash_from_live_fixture() -> str:
    return fixture_manifest("a")["fixture_sha256"]


if __name__ == "__main__":
    unittest.main()
