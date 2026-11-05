"""Simulator-only system settings control; no App launch input or state override."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import uuid


class SimulatorReduceMotionControl:
    ENVIRONMENT_KEY = "STRICT_E2E_REDUCE_MOTION_CONTROL_DIR"
    COMMAND_SECONDS = 3
    DOMAIN = "com.apple.Accessibility"
    KEY = "ReduceMotionEnabled"

    def __init__(self, simulator_udid):
        self.simulator_udid = simulator_udid
        self._temporary = tempfile.TemporaryDirectory(prefix="immichslides-system-motion-")
        self.directory = Path(self._temporary.name)
        self._stop = threading.Event()
        self._thread = None
        self._has_original = False

    def _command(self, arguments, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("Simulator Reduce Motion command timed out.")
        return subprocess.run(
            ["xcrun", "simctl", "spawn", self.simulator_udid, "defaults", *arguments],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=remaining, check=False,
        )

    def _read(self, deadline, *, allow_absent=False):
        completed = self._command(["read", self.DOMAIN, self.KEY], deadline)
        value = completed.stdout.strip().lower()
        if completed.returncode == 0 and value in {b"0", b"false", b"1", b"true"}:
            return value in {b"1", b"true"}
        absent = f"Error: Could not find key '{self.KEY}' in domain '{self.DOMAIN}'.".encode()
        if allow_absent and completed.returncode == 1 and completed.stderr.strip() == absent:
            return None
        raise RuntimeError("Simulator Reduce Motion value is unavailable.")

    def _write(self, is_on, deadline):
        completed = self._command(["write", self.DOMAIN, self.KEY, "-bool", "true" if is_on else "false"], deadline)
        if completed.returncode != 0 or self._read(deadline) != is_on:
            raise RuntimeError("Simulator Reduce Motion change did not read back.")

    def start(self):
        self._original = self._read(time.monotonic() + self.COMMAND_SECONDS, allow_absent=True)
        self._has_original = True
        self._thread = threading.Thread(target=self._serve, name="simulator-reduce-motion", daemon=True)
        self._thread.start()

    def _serve(self):
        while not self._stop.is_set():
            for request in self.directory.glob("request-*.json"):
                token = request.stem.removeprefix("request-")
                try:
                    if str(uuid.UUID(token)) != token:
                        continue
                    if request.stat().st_size > 256:
                        raise ValueError("oversized request")
                    payload = json.loads(request.read_text())
                    if not isinstance(payload, dict) or set(payload) != {"is_on"} or type(payload["is_on"]) is not bool:
                        raise ValueError("invalid request")
                    self._write(payload["is_on"], time.monotonic() + self.COMMAND_SECONDS)
                    reply = {"ok": True, "is_on": payload["is_on"]}
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                    reply = {"ok": False}
                temporary = self.directory / ("reply-" + token + ".tmp")
                temporary.write_text(json.dumps(reply))
                temporary.replace(self.directory / ("reply-" + token + ".json"))
                request.unlink(missing_ok=True)
            self._stop.wait(0.02)

    def close(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(self.COMMAND_SECONDS + 1)
            if self._thread.is_alive():
                raise RuntimeError("Simulator Reduce Motion control did not stop.")
        try:
            if self._has_original:
                deadline = time.monotonic() + self.COMMAND_SECONDS
                if self._original is None:
                    completed = self._command(["delete", self.DOMAIN, self.KEY], deadline)
                    if completed.returncode != 0:
                        raise RuntimeError("Simulator Reduce Motion original preference was not restored.")
                else:
                    self._write(self._original, deadline)
                if self._read(deadline, allow_absent=True) != self._original:
                    raise RuntimeError("Simulator Reduce Motion original preference did not read back.")
        finally:
            self._temporary.cleanup()
