"""Host-side simulator preference changes for the P2 Reduce Motion recording."""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from enum import Enum
from pathlib import Path

from strict_e2e_runner_support import (CommandError, SIMULATOR_COMMAND_TIMEOUT_SECONDS,
    REDUCE_MOTION_CHANGE_TIMEOUT_SECONDS, REDUCE_MOTION_RESPONSE_TIMEOUT_SECONDS,
    REDUCE_MOTION_JOIN_TIMEOUT_SECONDS)

DOMAIN = "com.apple.Accessibility"
KEY = "ReduceMotionEnabled"
NOTIFICATION = "com.apple.accessibility.reduce.motion.status"

class MotionFailureReason(str, Enum):
    WRITE = "write"
    NOTIFY = "notify"
    READBACK = "readback"
    TIMEOUT = "timeout"
    REQUEST_INVALID = "request-invalid"


class MotionCommandError(CommandError):
    def __init__(self, reason: MotionFailureReason):
        self.reason = reason
        super().__init__(f"System Reduce Motion command failed: {reason.value}.", code=2)


class MotionCommandSession:
    """One bounded serial handshake; restoration belongs to the host, including XCTest failure."""

    def __init__(self, udid: str, directory: Path, *, force_failure_after_enable: bool = False):
        self.udid = udid
        self.directory = directory
        self.force_failure_after_enable = force_failure_after_enable
        self.original = None
        self.changes = []
        self.failure = False
        self.closed = False
        self.stop = threading.Event()
        self.thread = None
        self.sequence = 0
        self.last_request = None

    def _spawn(self, *arguments, deadline=None, reason=MotionFailureReason.READBACK):
        timeout = SIMULATOR_COMMAND_TIMEOUT_SECONDS
        if deadline is not None:
            timeout = min(timeout, deadline - time.monotonic())
        if timeout <= 0:
            raise MotionCommandError(MotionFailureReason.TIMEOUT)
        try:
            return subprocess.run(["xcrun", "simctl", "spawn", self.udid, *arguments],
                                  capture_output=True, text=True, check=False, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise MotionCommandError(MotionFailureReason.TIMEOUT) from error
        except (OSError, subprocess.SubprocessError) as error:
            raise MotionCommandError(reason) from error

    def _read(self, deadline=None):
        result = self._spawn("defaults", "read", DOMAIN, KEY, deadline=deadline)
        if result.returncode == 0 and result.stdout.strip() in {"0", "1"}:
            return result.stdout.strip() == "1", True
        missing = f"Error: Could not find key '{KEY}' in domain '{DOMAIN}'."
        if result.returncode == 1 and result.stderr.strip() == missing:
            # The system default is off; retain absence so cleanup also restores the preference's shape.
            return False, False
        raise MotionCommandError(MotionFailureReason.READBACK)

    def _write_json(self, name, payload):
        temporary = self.directory / (name + ".tmp")
        temporary.write_text(json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + "\n")
        os.replace(temporary, self.directory / name)

    def _record(self):
        self._write_json("motion-system-command.json", {
            "schema": "strict-e2e-motion-command-v1", "mechanism": "simctl-defaults-notify",
            "domain": DOMAIN, "key": KEY, "notification": NOTIFICATION,
            "original": self.original, "changes": self.changes,
        })

    def _change(self, phase, requested, app_state, *, restore=False):
        started = time.time()
        deadline = time.monotonic() + REDUCE_MOTION_CHANGE_TIMEOUT_SECONDS
        before, present = self._read(deadline)
        absent_original = restore and not self.original["was_present"]
        if absent_original:
            result = self._spawn("defaults", "delete", DOMAIN, KEY, deadline=deadline,
                                 reason=MotionFailureReason.WRITE) if present else None
        else:
            result = self._spawn("defaults", "write", DOMAIN, KEY, "-bool", "true" if requested else "false",
                                 deadline=deadline, reason=MotionFailureReason.WRITE)
        if result is not None and result.returncode != 0:
            raise MotionCommandError(MotionFailureReason.WRITE)
        if self._spawn("notifyutil", "-p", NOTIFICATION, deadline=deadline,
                       reason=MotionFailureReason.NOTIFY).returncode != 0:
            raise MotionCommandError(MotionFailureReason.NOTIFY)
        after, now_present = self._read(deadline)
        if after != requested or (absent_original and now_present):
            raise MotionCommandError(MotionFailureReason.READBACK)
        self.changes.append(dict(phase=phase, requested=requested, before=before, after=after,
            started_wall_time=started, completed_wall_time=time.time(), app_state=app_state))
        self._record()

    def start(self):
        enabled, present = self._read()
        self.original = dict(is_enabled=enabled, was_present=present, wall_time=time.time())
        self._record()
        self._change("disabled", False, "not-running")
        self._reply(0, original=enabled, request_timeout_seconds=REDUCE_MOTION_RESPONSE_TIMEOUT_SECONDS)
        writer = threading.Thread(target=self._serve, name="reduce-motion-command", daemon=True)
        writer.start()
        self.thread = writer

    def _reply(self, sequence, reason=None, **fields):
        self._write_json("motion-command-response.json", {
            "sequence": sequence, "succeeded": reason is None,
            "failure_reason": reason.value if reason is not None else None, **fields})

    def _serve(self):
        received_sequence = self.sequence + 1
        try:
            while not self.stop.wait(0.1):
                received_sequence = self.sequence + 1
                request_path = self.directory / "motion-command-request.json"
                if not request_path.is_file():
                    continue
                if request_path.stat().st_size > 1024:
                    raise ValueError("request exceeds bound")
                request = json.loads(request_path.read_text())
                if isinstance(request, dict) and type(request.get("sequence")) is int and request["sequence"] > 0:
                    received_sequence = request["sequence"]
                if request == self.last_request:
                    continue
                if (not isinstance(request, dict) or set(request) != {"sequence", "phase", "app_state"}
                    or type(request["sequence"]) is not int or request["sequence"] != self.sequence + 1
                    or self.sequence not in (0, 1) or request["app_state"] != "background"
                    or request["phase"] != ("enabled", "restored")[self.sequence]):
                    raise MotionCommandError(MotionFailureReason.REQUEST_INVALID)
                requested = True if received_sequence == 1 else self.original["is_enabled"]
                self._change(request["phase"], requested, "background", restore=received_sequence == 2)
                self.sequence = received_sequence
                self.last_request = request
                forced_failure = self.force_failure_after_enable and received_sequence == 1
                self._reply(received_sequence, MotionFailureReason.READBACK if forced_failure else None)
                if forced_failure:
                    self.failure = True
                    return
        except Exception as error:
            self.failure = True
            reason = error.reason if isinstance(error, MotionCommandError) else MotionFailureReason.REQUEST_INVALID
            self._reply(received_sequence, reason)

    def close(self):
        if self.closed:
            return
        self.stop.set()
        if self.thread is not None:
            # Four bounded simctl calls can still be in flight; never race cleanup against that writer.
            self.thread.join(REDUCE_MOTION_JOIN_TIMEOUT_SECONDS)
            if self.thread.is_alive():
                # The outer finalizer must not restart this full join budget or race the unjoined writer.
                self.closed = True
                raise CommandError("System Reduce Motion command worker did not stop; restore unverified.", code=2)
        try:
            if self.original is not None:
                self._change("cleanup-restored", self.original["is_enabled"], "not-observed", restore=True)
        finally:
            self.closed = True
