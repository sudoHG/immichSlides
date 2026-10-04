#!/usr/bin/env python3
"""Shared out-of-order contract. Timeline only from redacted logs; identity only from public image regions."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256
from strict_e2e_photo_identity import MARKS, PhotoIdentity
from strict_e2e_server import PUBLIC_API_KEY, fixture_manifest
from access_lifecycle_contract import capture_identity


OUT_OF_ORDER_STEPS = ("ooo-current-scene", "ooo-after-late")
OUT_OF_ORDER_VISUAL_SUITES = ("late-image",)
DELAYED_SIZES = ("preview", "fullsize")
REQUEST_STARTED_LINE = re.compile(
    r"^request_started elapsed_ms=(?P<elapsed>\d+) method=(?P<method>GET|POST) "
    r"path=(?P<path>\S+) size=(?P<size>thumbnail|preview|fullsize) "
    r"range=(?P<range>present|absent) fixture_asset_id=(?P<asset>\S+)$"
)
REQUEST_COMPLETED_LINE = re.compile(
    r"^request elapsed_ms=(?P<elapsed>\d+) method=(?P<method>GET|POST) "
    r"path=(?P<path>\S+) status=(?P<status>\d+) "
    r"range=(?P<range>present|absent) fixture_asset_id=(?P<asset>\S+)"
    r"(?: size=(?P<size>thumbnail|preview|fullsize))?$"
)
KNOWN_PATH = re.compile(
    r"^/(?:healthz|api/albums|api/people|api/api-keys/me|api/search/random|"
    r"api/people/<fixture-id>/(?:thumbnail|statistics)|"
    r"api/assets/<fixture-id>(?:/thumbnail)?)$"
)


class OutOfOrderContractError(Exception):
    pass


@dataclass(frozen=True)
class _LogEvent:
    elapsed_ms: int
    path: str
    asset_id: str
    size: str | None
    status: int | None


def delayed_asset_id(fixture_set: str) -> str:
    return f"asset-{fixture_set}-1"


def immediate_asset_id(fixture_set: str) -> str:
    return f"asset-{fixture_set}-2"


def assert_current_scene_holds(current: PhotoIdentity, after_late: PhotoIdentity) -> str:
    # Identity at key time points comes only from public fixture images; after the late request completes,
    # the current scene must still hold.
    for identity, name in ((current, "ooo-current-scene"), (after_late, "ooo-after-late")):
        if identity.status == "BLACK":
            raise OutOfOrderContractError(f"All black must not count as a pass: {name}")
        scene_marks = identity.mark.split("+") if identity.mark else []
        if (
            identity.status != "MATCH"
            or not scene_marks
            or len(scene_marks) != len(set(scene_marks))
            or any(mark not in MARKS for mark in scene_marks)
        ):
            raise OutOfOrderContractError(
                f"Unrecognizable input must not count as a pass: {name} status={identity.status} mark={identity.mark}"
            )
    if current.mark != after_late.mark:
        raise OutOfOrderContractError(
            f"Wrong image: the late request changed the current scene from {current.mark} to {after_late.mark}"
        )
    if current.mark is not None and "A1" in current.mark.split("+"):
        raise OutOfOrderContractError("Old photo A1 is still in the current scene; must not count as a pass")
    return str(current.mark)


def assert_out_of_order_timeline(
    log_text: str,
    *,
    delayed_asset_id: str,
    immediate_asset_id: str,
    size: str,
    window_start_ms: int = 0,
) -> dict[str, int]:
    if size not in DELAYED_SIZES:
        raise OutOfOrderContractError(f"The out-of-order contract does not cover size={size}")
    if PUBLIC_API_KEY in log_text or "x-api-key" in log_text.lower():
        raise OutOfOrderContractError("Request log contains a forbidden field")
    starts, completes = _parse_timeline(log_text)
    delayed_starts = [
        item
        for item in starts
        if item.asset_id == delayed_asset_id and item.size == size and item.elapsed_ms >= window_start_ms
    ]
    immediate_starts = [
        item
        for item in starts
        if item.asset_id == immediate_asset_id and item.size == size and item.elapsed_ms >= window_start_ms
    ]
    if not delayed_starts or not immediate_starts:
        raise OutOfOrderContractError(f"Missing key time point: {size} start record")
    delayed_start = delayed_starts[0]
    immediate_start = immediate_starts[0]
    delayed_completes = _completes_for(completes, delayed_asset_id, size, delayed_start.elapsed_ms)
    immediate_completes = _completes_for(completes, immediate_asset_id, size, immediate_start.elapsed_ms)
    if not delayed_completes or not immediate_completes:
        raise OutOfOrderContractError(f"Missing key time point: {size} completion record")
    delayed_complete = delayed_completes[0]
    immediate_complete = immediate_completes[0]
    for complete in (delayed_complete, immediate_complete):
        if complete.status is None or not 200 <= complete.status < 300:
            raise OutOfOrderContractError(
                f"The {size} image response must succeed to count as a completion: status={complete.status}"
            )
    if delayed_start.elapsed_ms >= immediate_complete.elapsed_ms:
        raise OutOfOrderContractError("The old request must start before the current request completes")
    if delayed_complete.elapsed_ms <= immediate_complete.elapsed_ms:
        raise OutOfOrderContractError("The old request must complete after the current request")
    return {
        "delayed_start_ms": delayed_start.elapsed_ms,
        "immediate_start_ms": immediate_start.elapsed_ms,
        "immediate_complete_ms": immediate_complete.elapsed_ms,
        "delayed_complete_ms": delayed_complete.elapsed_ms,
    }


def audit_runner_inputs(
    *,
    fixture_set: str,
    observed_hash: str,
    service_log: str,
    server_url: str,
) -> dict[str, Any]:
    # Unknown requests, bad request bodies, hash drift or a URL that is not the local controlled server fail
    # the batch; never fall back to a real server.
    frozen = FROZEN_FIXTURE_SHA256.get(fixture_set)
    live = fixture_manifest(fixture_set)["fixture_sha256"] if fixture_set in FROZEN_FIXTURE_SHA256 else None
    if frozen is None or observed_hash != frozen or observed_hash != live:
        raise OutOfOrderContractError("fixture hash mismatch, this batch fails")
    _assert_local_controlled_url(server_url)
    if PUBLIC_API_KEY in service_log or "x-api-key" in service_log.lower():
        raise OutOfOrderContractError("Request log contains a forbidden field")
    request_lines = [line for line in service_log.splitlines() if line.startswith("request ")]
    if not request_lines:
        raise OutOfOrderContractError("Request log has no verifiable lines")
    for line in service_log.splitlines():
        if line.startswith("request_started "):
            started = REQUEST_STARTED_LINE.match(line)
            if started is None:
                raise OutOfOrderContractError(f"Request log format is not frozen: {line}")
            if KNOWN_PATH.match(started.group("path")) is None:
                raise OutOfOrderContractError(f"Unknown request; this batch fails: {started.group('path')}")
            continue
        if not line.startswith("request "):
            continue
        matched = REQUEST_COMPLETED_LINE.match(line)
        if matched is None:
            raise OutOfOrderContractError(f"Request log format is not frozen: {line}")
        path = matched.group("path")
        status = int(matched.group("status"))
        if KNOWN_PATH.match(path) is None:
            raise OutOfOrderContractError(f"Unknown request; this batch fails: {path}")
        if status == 400:
            raise OutOfOrderContractError("Request body does not match the contract, this batch fails")
    return {
        "verdict": "PASS",
        "request_log_is_not_identity": True,
        "fixture_set": fixture_set,
        "fixture_sha256": observed_hash,
    }


def evaluate_out_of_order_identity(evidence_dir: Path) -> dict[str, Any]:
    # Screenshots establish photo identity; logs only verify the timeline and never identify photos.
    missing = [name for name in OUT_OF_ORDER_STEPS if not (evidence_dir / f"{name}.png").is_file()]
    if missing:
        raise OutOfOrderContractError("Missing required timeline screenshots: " + ", ".join(missing))
    current = capture_identity((evidence_dir / "ooo-current-scene.png").read_bytes())
    after_late = capture_identity((evidence_dir / "ooo-after-late.png").read_bytes())
    mark = assert_current_scene_holds(current, after_late)

    log_path = evidence_dir / "redacted-request.log"
    if not log_path.is_file():
        log_path = evidence_dir / "service.log"
    if not log_path.is_file():
        raise OutOfOrderContractError("Missing key time point: redacted-request.log")
    log_text = log_path.read_text(encoding="utf-8")

    fixture_set, observed_hash = _read_fixture_hash(evidence_dir)
    delayed = delayed_asset_id(fixture_set)
    immediate = immediate_asset_id(fixture_set)
    window_start_ms = _playback_window_start_ms(log_text, delayed, immediate)
    timeline: dict[str, dict[str, int]] = {}
    last_error: OutOfOrderContractError | None = None
    for size in DELAYED_SIZES:
        try:
            timeline[size] = assert_out_of_order_timeline(
                log_text,
                delayed_asset_id=delayed,
                immediate_asset_id=immediate,
                size=size,
                window_start_ms=window_start_ms,
            )
        except OutOfOrderContractError as error:
            last_error = error
    if not timeline:
        if last_error is not None:
            raise last_error
        raise OutOfOrderContractError("Missing key time point: preview/fullsize timeline")
    audit = audit_runner_inputs(
        fixture_set=fixture_set,
        observed_hash=observed_hash,
        service_log=log_text,
        server_url=_read_server_url(evidence_dir),
    )
    return {
        "verdict": "PASS",
        "suite": "late-image",
        "identity_source": "public_fixture_photo_mark",
        "request_log_is_not_identity": True,
        "mark": mark,
        "timeline": timeline,
        "audit": audit,
    }


def _playback_window_start_ms(log_text: str, delayed_asset_id: str, immediate_asset_id: str) -> int:
    # Connection test and save are not part of this scene; a mid-playback random must not push the old
    # photo's still in-flight preview/fullsize out of the window.
    random_ms: list[int] = []
    for line in log_text.splitlines():
        matched = REQUEST_COMPLETED_LINE.match(line)
        if matched is not None and matched.group("path") == "/api/search/random":
            random_ms.append(int(matched.group("elapsed")))
    if not random_ms:
        return 0
    starts, completes = _parse_timeline(log_text)
    immediate_starts = [item.elapsed_ms for item in starts if item.asset_id == immediate_asset_id]
    if not immediate_starts:
        return random_ms[-1]
    first_immediate = min(immediate_starts)
    in_flight: list[int] = []
    for start in starts:
        if start.asset_id != delayed_asset_id or start.size not in DELAYED_SIZES:
            continue
        if start.elapsed_ms > first_immediate:
            continue
        finished = _completes_for(completes, delayed_asset_id, start.size, start.elapsed_ms)
        if not finished or finished[0].elapsed_ms > first_immediate:
            in_flight.append(start.elapsed_ms)
    anchor = min([first_immediate, *in_flight])
    before = [ms for ms in random_ms if ms <= anchor]
    return before[-1] if before else 0


def _parse_timeline(log_text: str) -> tuple[list[_LogEvent], list[_LogEvent]]:
    starts: list[_LogEvent] = []
    completes: list[_LogEvent] = []
    for line in log_text.splitlines():
        started = REQUEST_STARTED_LINE.match(line)
        if started is not None:
            starts.append(
                _LogEvent(
                    elapsed_ms=int(started.group("elapsed")),
                    path=started.group("path"),
                    asset_id=started.group("asset"),
                    size=started.group("size"),
                    status=None,
                )
            )
            continue
        completed = REQUEST_COMPLETED_LINE.match(line)
        if completed is not None:
            completes.append(
                _LogEvent(
                    elapsed_ms=int(completed.group("elapsed")),
                    path=completed.group("path"),
                    asset_id=completed.group("asset"),
                    size=completed.group("size"),
                    status=int(completed.group("status")),
                )
            )
    return starts, completes


def _completes_for(
    completes: list[_LogEvent],
    asset_id: str,
    size: str,
    start_ms: int,
) -> list[_LogEvent]:
    # When completion lines carry size, pair by size so interleaved preview/fullsize are not mismatched.
    matching = [
        item
        for item in completes
        if item.asset_id == asset_id and item.elapsed_ms >= start_ms and item.size == size
    ]
    if matching:
        return matching
    return [
        item
        for item in completes
        if item.asset_id == asset_id and item.elapsed_ms >= start_ms and item.size is None
    ]


def _assert_local_controlled_url(server_url: str) -> None:
    parsed = urlparse(server_url)
    # This fixture contract only accepts loopback URLs; it does not run against a real-device server.
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"127.0.0.1", "localhost"}
        or parsed.path.rstrip("/") != "/api"
    ):
        raise OutOfOrderContractError("Must not silently fall back to a real server")


def _read_fixture_hash(evidence_dir: Path) -> tuple[str, str]:
    path = evidence_dir / "fixture-manifest.json"
    if not path.is_file():
        raise OutOfOrderContractError("Missing key time point: fixture-manifest.json")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise OutOfOrderContractError(f"fixture-manifest is unreadable: {error}") from error
    fixture_set = payload.get("fixture_set")
    observed_hash = payload.get("fixture_sha256")
    if fixture_set not in FROZEN_FIXTURE_SHA256 or not isinstance(observed_hash, str):
        raise OutOfOrderContractError("fixture hash mismatch, this batch fails")
    return str(fixture_set), observed_hash


def _read_server_url(evidence_dir: Path) -> str:
    url_path = evidence_dir / "runner-server-url.txt"
    if url_path.is_file():
        return url_path.read_text(encoding="utf-8").strip()
    ready_path = evidence_dir / "service-ready.json"
    if ready_path.is_file():
        try:
            payload = json.loads(ready_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise OutOfOrderContractError(f"service-ready is unreadable: {error}") from error
        host = payload.get("host")
        port = payload.get("port")
        if isinstance(host, str) and isinstance(port, int):
            return f"http://{host}:{port}/api"
    raise OutOfOrderContractError("Missing key time point: controlled server URL")
