"""Host-side simulator preference changes for the P2 Reduce Motion recording."""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from pathlib import Path

from strict_e2e_runner_support import CommandError

DOMAIN = "com.apple.Accessibility"
KEY = "ReduceMotionEnabled"
NOTIFICATION = "com.apple.accessibility.reduce.motion.status"
COMMAND_TIMEOUT_SECONDS = 10


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

    def _spawn(self, *arguments):
        try:
            return subprocess.run(["xcrun", "simctl", "spawn", self.udid, *arguments],
                                  capture_output=True, text=True, check=False, timeout=COMMAND_TIMEOUT_SECONDS)
        except (OSError, subprocess.SubprocessError) as error:
            raise CommandError("System Reduce Motion command did not complete.", code=2) from error

    def _read(self):
        result = self._spawn("defaults", "read", DOMAIN, KEY)
        if result.returncode == 0 and result.stdout.strip() in {"0", "1"}:
            return result.stdout.strip() == "1", True
        missing = f"Error: Could not find key '{KEY}' in domain '{DOMAIN}'."
        if result.returncode == 1 and result.stderr.strip() == missing:
            # The system default is off; retain absence so cleanup also restores the preference's shape.
            return False, False
        raise CommandError("System Reduce Motion original/readback is unavailable.", code=2)

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
        before, present = self._read()
        absent_original = restore and not self.original["was_present"]
        if absent_original:
            result = self._spawn("defaults", "delete", DOMAIN, KEY) if present else None
        else:
            result = self._spawn("defaults", "write", DOMAIN, KEY, "-bool", "true" if requested else "false")
        if result is not None and result.returncode != 0:
            raise CommandError("System Reduce Motion preference write failed.", code=2)
        if self._spawn("notifyutil", "-p", NOTIFICATION).returncode != 0:
            raise CommandError("System Reduce Motion notification failed.", code=2)
        after, now_present = self._read()
        if after != requested or (absent_original and now_present):
            raise CommandError("System Reduce Motion command readback mismatch.", code=2)
        self.changes.append(dict(phase=phase, requested=requested, before=before, after=after,
            started_wall_time=started, completed_wall_time=time.time(), app_state=app_state))
        self._record()

    def start(self):
        enabled, present = self._read()
        self.original = dict(is_enabled=enabled, was_present=present, wall_time=time.time())
        self._record()
        self._change("disabled", False, "not-running")
        self._write_json("motion-command-response.json", {"sequence": 0, "succeeded": True, "original": enabled})
        self.thread = threading.Thread(target=self._serve, name="reduce-motion-command", daemon=True)
        self.thread.start()

    def _serve(self):
        sequence = 0
        try:
            while not self.stop.wait(0.1):
                request_path = self.directory / "motion-command-request.json"
                if not request_path.is_file():
                    continue
                if request_path.stat().st_size > 1024:
                    raise ValueError("request exceeds bound")
                request = json.loads(request_path.read_text())
                if request.get("sequence") == sequence:
                    continue
                if (set(request) != {"sequence", "phase", "app_state"}
                    or type(request["sequence"]) is not int or request["sequence"] != sequence + 1
                    or sequence not in (0, 1) or request["app_state"] != "background"
                    or request["phase"] != ("enabled", "restored")[sequence]):
                    raise ValueError("invalid command order")
                sequence += 1
                requested = True if sequence == 1 else self.original["is_enabled"]
                self._change(request["phase"], requested, "background", restore=sequence == 2)
                forced_failure = self.force_failure_after_enable and sequence == 1
                self._write_json("motion-command-response.json", {"sequence": sequence, "succeeded": not forced_failure})
                if forced_failure:
                    self.failure = True
                    return
        except Exception:
            self.failure = True
            self._write_json("motion-command-response.json", {"sequence": max(1, sequence), "succeeded": False})

    def close(self):
        if self.closed:
            return
        self.stop.set()
        if self.thread is not None:
            # Four bounded simctl calls can still be in flight; never race cleanup against that writer.
            self.thread.join(4 * COMMAND_TIMEOUT_SECONDS + 1)
            if self.thread.is_alive():
                raise CommandError("System Reduce Motion command worker did not stop; restore unverified.", code=2)
        try:
            if self.original is not None:
                self._change("cleanup-restored", self.original["is_enabled"], "not-observed", restore=True)
        finally:
            self.closed = True
