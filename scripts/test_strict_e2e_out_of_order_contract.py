#!/usr/bin/env python3
"""Shared out-of-order contract: timeline, input audit, public identification, negatives must fail first."""

from __future__ import annotations

import io
import json
import re
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent

from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256  # noqa: E402
from strict_e2e_out_of_order_contract import (  # noqa: E402
    APP_IMAGE_DOWNLOAD_TIMEOUT_MS,
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
    _fixture_data,
    fixture_manifest,
)
from test_strict_e2e_server import RunningServer, wait_for_request_started  # noqa: E402


def _fixture_png(label: str, fixture_set: str = "a") -> bytes:
    return _fixture_data(fixture_set)["images"][f"asset-{fixture_set}-{label[-1]}"]


def _stacked_fixture_png(top: str, bottom: str, fixture_set: str = "a") -> bytes:
    from PIL import Image

    canvas = Image.new("RGB", (360, 800))
    for label, y in ((top, 0), (bottom, 400)):
        with Image.open(io.BytesIO(_fixture_png(label, fixture_set))) as source:
            canvas.paste(source.convert("RGB").resize((360, 400)), (0, y))
    output = io.BytesIO()
    canvas.save(output, format="PNG")
    return output.getvalue()


def _capture_out_of_order_log(size: str) -> str:
    log_stream = io.StringIO()
    with RunningServer(scenario="out-of-order", log_stream=log_stream) as server:
        server.request("/test/late-image", method="POST", body={"action": "arm"})
        with ThreadPoolExecutor(max_workers=2) as executor:
            old_request = executor.submit(
                server.request,
                f"/assets/asset-a-1/thumbnail?size={size}",
                timeout=4,
            )
            wait_for_request_started(log_stream, asset_id="asset-a-1", size=size)
            server.request(f"/assets/asset-a-2/thumbnail?size={size}")
            time.sleep(0.01)
            server.request("/test/late-image", method="POST", body={"action": "release"})
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
    if "late_image_hold " not in log_text:
        # Recorded historical timelines get explicit fixture-control observations at playback entry.
        state = {"generation": 1, "armed": True, "armed_elapsed_ms": 2000, "asset_id": None,
                 "hold_started_elapsed_ms": None, "released_elapsed_ms": None,
                 "released": False, "expired": False, "pending": 0, "delivered": 0, "disconnected": 0}
        lines = log_text.splitlines()
        anchor = next(index for index, line in enumerate(lines)
                      if line.startswith("request_started ") and int(line.split("elapsed_ms=")[1].split()[0]) >= 2000)
        lines.insert(anchor, "late_image_hold " + json.dumps(state))
        started_ms = int(lines[anchor + 1].split("elapsed_ms=")[1].split()[0])
        state.update(asset_id=f"asset-{fixture_set}-1", released=True, delivered=1,
                     hold_started_elapsed_ms=started_ms, released_elapsed_ms=started_ms + 100)
        lines.append("late_image_hold " + json.dumps(state))
        log_text = "\n".join(lines) + "\n"
    (evidence / "ooo-current-scene.png").write_bytes(current)
    (evidence / "ooo-after-late.png").write_bytes(after_late)
    selected = [json.loads(line.removeprefix("late_image_hold "))["asset_id"]
                for line in log_text.splitlines() if line.startswith("late_image_hold ")][-1]
    (evidence / "late-image-initial-scene.json").write_text(json.dumps({
        "before_first_next": {"manifest": f"ledgerSceneAssets={selected}"},
        "fixture": {"asset_id": selected},
    }), encoding="utf-8")
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
    def test_initial_scene_evidence_rejects_a_held_prefetch(self) -> None:
        log_text = _capture_out_of_order_log("preview")
        for change, message in (
            ("missing", "Missing cold-launch scene evidence before the first Next"),
            ("malformed", "Invalid cold-launch scene evidence before the first Next"),
            ("prefetch", "Held asset must belong to the cold-launch scene before the first Next"),
        ):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory)
                _write_identity_evidence(evidence, current=_fixture_png("A3"), after_late=_fixture_png("A3"), log_text=log_text)
                self.assertEqual(evaluate_out_of_order_identity(evidence)["verdict"], "PASS")
                path = evidence / "late-image-initial-scene.json"
                if change == "missing":
                    path.unlink()
                elif change == "malformed":
                    path.write_text("{}", encoding="utf-8")
                else:
                    payload = json.loads(path.read_text())
                    payload["before_first_next"]["manifest"] = "ledgerSceneAssets=asset-a-2"
                    path.write_text(json.dumps(payload), encoding="utf-8")
                with self.assertRaisesRegex(OutOfOrderContractError, "^" + message):
                    evaluate_out_of_order_identity(evidence)

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
                    self.assertGreater(payload["delayed_complete_ms"], payload["immediate_complete_ms"])
                    self.assertLess(payload["delayed_start_ms"], payload["immediate_complete_ms"])
                    self.assertIn(f"size={size}", log_text)
                    self.assertRegex(
                        log_text,
                        rf"request elapsed_ms=\d+ method=GET path=/api/assets/<fixture-id>/thumbnail "
                        rf"status=200 range=absent fixture_asset_id=asset-a-1 size={size}",
                    )

    def test_overlapping_preview_and_fullsize_still_finish_old_last(self) -> None:
        log_stream = io.StringIO()
        with RunningServer(scenario="out-of-order", log_stream=log_stream) as server:
            server.request("/test/late-image", method="POST", body={"action": "arm"})
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
                wait_for_request_started(log_stream, asset_id="asset-a-1", size="preview")
                wait_for_request_started(log_stream, asset_id="asset-a-1", size="fullsize")
                new_preview = executor.submit(
                    server.request, "/assets/asset-a-2/thumbnail?size=preview"
                )
                new_fullsize = executor.submit(
                    server.request, "/assets/asset-a-2/thumbnail?size=fullsize"
                )
                for handle in (new_preview, new_fullsize):
                    self.assertEqual(handle.result(timeout=5)[0], 200)
                self.assertFalse(old_preview.done())
                self.assertFalse(old_fullsize.done())
                time.sleep(0.01)
                server.request("/test/late-image", method="POST", body={"action": "release"})
                for handle in (old_preview, old_fullsize):
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
            self.assertGreater(payload["delayed_complete_ms"], payload["immediate_complete_ms"])

    def test_timeline_cannot_be_used_as_photo_identity(self) -> None:
        log_text = _capture_out_of_order_log("fullsize")
        with self.assertRaisesRegex(OutOfOrderContractError, "Unrecognizable") as raised:
            assert_current_scene_holds(
                classify_screenshot(b""),
                classify_screenshot(b""),
            )
        self.assertIn("Unrecognizable", str(raised.exception))
        self.assertNotIn("asset-a-2", str(raised.exception))
        self.assertIn("fixture_asset_id=asset-a-2", log_text)


class OutOfOrderIdentityTests(unittest.TestCase):
    def test_evaluate_uses_actual_first_requested_asset_in_both_fixture_sets(self) -> None:
        for fixture_set in ("a", "b"):
            with self.subTest(fixture=fixture_set), tempfile.TemporaryDirectory() as directory:
                log_stream = io.StringIO()
                with RunningServer(scenario="out-of-order", fixture_set=fixture_set, log_stream=log_stream) as server:
                    server.request("/test/late-image", method="POST", body={"action": "arm"})
                    with ThreadPoolExecutor(max_workers=1) as executor:
                        old = executor.submit(server.request, f"/assets/asset-{fixture_set}-4/thumbnail?size=preview")
                        wait_for_request_started(log_stream, asset_id=f"asset-{fixture_set}-4", size="preview")
                        server.request(f"/assets/asset-{fixture_set}-2/thumbnail?size=preview")
                        time.sleep(0.01)
                        server.request("/test/late-image", method="POST", body={"action": "release"})
                        self.assertEqual(old.result(timeout=5)[0], 200)
                evidence = Path(directory)
                scene = _stacked_fixture_png("A2", "A3", fixture_set)
                _write_identity_evidence(evidence, current=scene, after_late=scene,
                                         log_text=log_stream.getvalue(), fixture_set=fixture_set)
                self.assertEqual(evaluate_out_of_order_identity(evidence)["verdict"], "PASS")

    def test_held_asset_inside_current_scene_cannot_pass(self) -> None:
        log_text = _capture_out_of_order_log("preview").replace("asset-a-1", "asset-a-4")
        scene = _stacked_fixture_png("A3", "A4")
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            _write_identity_evidence(evidence, current=scene, after_late=scene, log_text=log_text)
            with self.assertRaisesRegex(OutOfOrderContractError, "Held photo A4 is still in the current scene"):
                evaluate_out_of_order_identity(evidence)

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
    def test_invalid_hold_evidence_cannot_pass(self) -> None:
        log_text = _capture_out_of_order_log("preview")
        lines = log_text.splitlines()
        final_index = max(index for index, line in enumerate(lines) if line.startswith("late_image_hold "))
        valid = json.loads(lines[final_index].removeprefix("late_image_hold "))
        cases = {
            "missing": (None, "Missing late image hold record"),
            "malformed": ("{", "Malformed late image hold record"),
            "expired": (dict(valid, expired=True), "Late image hold was not armed or expired"),
            "never-delivered": (dict(valid, delivered=0), "no confirmed release and delivery"),
            "still-pending": (dict(valid, pending=1), "no confirmed release and delivery"),
            "disconnected": (dict(valid, disconnected=1), "no confirmed release and delivery"),
            "changed-selection": (dict(valid, asset_id="asset-a-5"), "changed its request selection"),
        }
        for name, (state, message) in cases.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory)
                _write_identity_evidence(evidence, current=_fixture_png("A3"), after_late=_fixture_png("A3"), log_text=log_text)
                changed = list(lines)
                if state is None:
                    changed = [line for line in changed if not line.startswith("late_image_hold ")]
                else:
                    changed[final_index] = "late_image_hold " + (state if isinstance(state, str) else json.dumps(state))
                (evidence / "redacted-request.log").write_text("\n".join(changed) + "\n")
                with self.assertRaisesRegex(OutOfOrderContractError, message):
                    evaluate_out_of_order_identity(evidence)

    def test_consistent_hold_selection_must_match_actual_first_request(self) -> None:
        lines = _capture_out_of_order_log("preview").splitlines()
        for index, line in enumerate(lines):
            if line.startswith("late_image_hold "):
                state = json.loads(line.removeprefix("late_image_hold "))
                if state["asset_id"] is not None:
                    state["asset_id"] = "asset-a-5"
                lines[index] = "late_image_hold " + json.dumps(state)
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            _write_identity_evidence(evidence, current=_fixture_png("A3"), after_late=_fixture_png("A3"),
                                     log_text="\n".join(lines))
            with self.assertRaisesRegex(OutOfOrderContractError, "Held asset was not the first image requested"):
                evaluate_out_of_order_identity(evidence)

    def test_hold_must_finish_before_the_app_image_download_timeout(self) -> None:
        support = (SCRIPT_DIR.parent / "immichSlidesUITests/StrictE2ELateImageSupport.swift").read_text()
        timeout = re.search(r"downloadTimeoutSeconds: TimeInterval = TestWait.seconds\(\.product\((\d+)\)\)", support)
        self.assertIsNotNone(timeout)
        self.assertEqual(int(timeout.group(1)) * 1000, APP_IMAGE_DOWNLOAD_TIMEOUT_MS)
        original = _capture_out_of_order_log("preview").splitlines()
        for duration in (14_999, 15_000, 15_001):
            with self.subTest(duration=duration), tempfile.TemporaryDirectory() as directory:
                lines = list(original)
                for index, line in enumerate(lines):
                    if line.startswith("late_image_hold "):
                        state = json.loads(line.removeprefix("late_image_hold "))
                        if state["released"]:
                            state["released_elapsed_ms"] = state.get("hold_started_elapsed_ms", 0) + duration
                            lines[index] = "late_image_hold " + json.dumps(state)
                evidence = Path(directory)
                _write_identity_evidence(evidence, current=_fixture_png("A3"), after_late=_fixture_png("A3"),
                                         log_text="\n".join(lines))
                if duration < 15_000:
                    self.assertEqual(evaluate_out_of_order_identity(evidence)["verdict"], "PASS")
                else:
                    with self.assertRaisesRegex(OutOfOrderContractError, "15-second image download timeout"):
                        evaluate_out_of_order_identity(evidence)

    def test_previous_generation_expiry_cannot_poison_current_generation(self) -> None:
        original = _capture_out_of_order_log("preview")
        first_start = next(int(line.split("elapsed_ms=")[1].split()[0]) for line in original.splitlines()
                           if line.startswith("request_started "))
        previous, current = [], []
        for line in original.splitlines():
            if line.startswith("late_image_hold "):
                state = json.loads(line.removeprefix("late_image_hold "))
                state["generation"] = 1
                state["expired"] = True
                previous.append("late_image_hold " + json.dumps(state))
                state["generation"] = 2
                state["expired"] = False
                line = "late_image_hold " + json.dumps(state)
            else:
                previous_line = line
                if line.startswith("request ") and "fixture_asset_id=asset-a-1" in line:
                    elapsed = line.split("elapsed_ms=")[1].split()[0]
                    previous_line = line.replace("elapsed_ms=" + elapsed, "elapsed_ms=" + str(first_start), 1)
                previous.append(previous_line)
            current.append(line)
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            _write_identity_evidence(evidence, current=_fixture_png("A3"), after_late=_fixture_png("A3"),
                                     log_text="\n".join(previous + ["late_image_hold_expired generation=1"] + current))
            self.assertEqual(evaluate_out_of_order_identity(evidence)["verdict"], "PASS")

    def test_unchanged_old_photo_cannot_pass(self) -> None:
        old = classify_screenshot(_fixture_png("A1"))
        with self.assertRaisesRegex(OutOfOrderContractError, "Old photo") as raised:
            assert_current_scene_holds(old, old)
        self.assertIn("Old photo", str(raised.exception))

    def test_old_photo_inside_two_photo_scene_cannot_pass(self) -> None:
        old_scene = _stacked_fixture_png("A1", "A3")
        with self.assertRaisesRegex(OutOfOrderContractError, "Old photo") as raised:
            assert_current_scene_holds(
                capture_identity(old_scene),
                capture_identity(old_scene),
            )
        self.assertIn("Old photo", str(raised.exception))

    def test_changed_second_photo_inside_two_photo_scene_cannot_pass(self) -> None:
        with self.assertRaisesRegex(OutOfOrderContractError, "Wrong image") as raised:
            assert_current_scene_holds(
                capture_identity(_stacked_fixture_png("A3", "A4")),
                capture_identity(_stacked_fixture_png("A3", "A5")),
            )
        self.assertIn("Wrong image", str(raised.exception))

    def test_wrong_photo_after_late_request_fails(self) -> None:
        with self.assertRaisesRegex(OutOfOrderContractError, "Wrong image") as raised:
            assert_current_scene_holds(
                classify_screenshot(_fixture_png("A3")),
                classify_screenshot(_fixture_png("A1")),
            )
        self.assertIn("Wrong image", str(raised.exception))

    def test_black_frame_cannot_pass(self) -> None:
        from PIL import Image

        buffer = io.BytesIO()
        Image.new("RGB", (320, 180), (0, 0, 0)).save(buffer, format="PNG")
        with self.assertRaisesRegex(OutOfOrderContractError, "All black") as raised:
            assert_current_scene_holds(
                classify_screenshot(_fixture_png("A3")),
                classify_screenshot(buffer.getvalue()),
            )
        self.assertIn("All black", str(raised.exception))

    def test_unrecognizable_frame_cannot_pass(self) -> None:
        with self.assertRaisesRegex(OutOfOrderContractError, "Unrecognizable") as raised:
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
            with self.assertRaisesRegex(OutOfOrderContractError, "Missing required timeline screenshots") as raised:
                evaluate_out_of_order_identity(evidence)
        self.assertIn("Missing required timeline screenshots", str(raised.exception))

    def test_unknown_request_fails_the_batch(self) -> None:
        with self.assertRaisesRegex(OutOfOrderContractError, "Unknown request") as raised:
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

    def test_error_status_cannot_count_as_a_completion(self) -> None:
        for delayed_status, immediate_status in ((200, 404), (500, 200)):
            with self.subTest(delayed=delayed_status, immediate=immediate_status):
                thumbnail = "/api/assets/<fixture-id>/thumbnail"
                log_text = "\n".join(
                    [
                        _request_line(100, thumbnail, size="preview", asset="asset-a-1", started=True),
                        _request_line(150, thumbnail, size="preview", asset="asset-a-2", started=True),
                        _request_line(200, thumbnail, status=immediate_status, size="preview", asset="asset-a-2"),
                        _request_line(500, thumbnail, status=delayed_status, size="preview", asset="asset-a-1"),
                    ]
                ) + "\n"
                with self.assertRaisesRegex(OutOfOrderContractError, "must succeed") as raised:
                    assert_out_of_order_timeline(
                        log_text,
                        delayed_asset_id="asset-a-1",
                        immediate_asset_id="asset-a-2",
                        size="preview",
                    )
                self.assertIn("must succeed", str(raised.exception))

    def test_unknown_started_request_path_fails_the_batch(self) -> None:
        with self.assertRaisesRegex(OutOfOrderContractError, "Unknown request") as raised:
            audit_runner_inputs(
                fixture_set="a",
                observed_hash=FROZEN_FIXTURE_SHA256["a"],
                service_log=(
                    "request_started elapsed_ms=1 method=GET path=/not-a-real-route "
                    "size=preview range=absent fixture_asset_id=none\n"
                    "request elapsed_ms=2 method=GET path=/healthz status=200 range=absent fixture_asset_id=none\n"
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
            with self.assertRaisesRegex(OutOfOrderContractError, "The old request must complete after the current request") as raised:
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
            with self.assertRaisesRegex(OutOfOrderContractError, "Wrong image"):
                evaluate_out_of_order_identity(evidence)
            with self.assertRaisesRegex(OutOfOrderContractError, "Wrong image") as raised:
                evaluate_out_of_order_identity(evidence)
        self.assertIn("Wrong image", str(raised.exception))


class RunnerInputAuditTests(unittest.TestCase):
    def test_bad_body_and_hash_mismatch_fail_closed(self) -> None:
        with self.assertRaisesRegex(OutOfOrderContractError, "Request body does not match the contract") as raised:
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

        with self.assertRaisesRegex(OutOfOrderContractError, "fixture hash") as raised:
            audit_runner_inputs(
                fixture_set="a",
                observed_hash="0" * 64,
                service_log="request elapsed_ms=1 method=GET path=/healthz status=200 range=absent fixture_asset_id=none\n",
                server_url="http://127.0.0.1:9/api",
            )
        self.assertIn("fixture hash", str(raised.exception))

    def test_real_server_fallback_is_rejected(self) -> None:
        with self.assertRaisesRegex(OutOfOrderContractError, "real server") as raised:
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
