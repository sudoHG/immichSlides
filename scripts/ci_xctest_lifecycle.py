"""Bounded, scanned fixture-only evidence for a live XCTest lifecycle failure."""

from __future__ import annotations

import json
import math
import os
import queue
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path

ACTIVITY_TIMEOUT_SECONDS = 15
CAPTURE_TIMEOUT_SECONDS = 20
MAX_CAPTURES = 3
MAX_FILE_BYTES = 256 * 1024
MAX_TOTAL_BYTES = 1024 * 1024
KINDS = {"processes", "app_sample", "simulator_log", "crash_reports"}
STATUSES = {"captured", "unavailable", "timeout", "withheld"}
PROCESS_NAMES = {"immichSlides", "SpringBoard", "launchd_sim", "ReportCrash", "testmanagerd"}
LOG_PREDICATE = ('process == "immichSlides" OR process == "SpringBoard" OR process == "launchd_sim" '
                 'OR subsystem CONTAINS[c] "RunningBoard" OR subsystem CONTAINS[c] "launchd" OR subsystem CONTAINS[c] "XCTest"')
FAILURE = re.compile(r"Failed to terminate|Failed to get matching snapshot|Timed out while evaluating UI query|\bcrashed\b", re.I)
ACTIVITY = re.compile(r"\s*t\s*=\s*[\d.]+s(\s+)(.*)")


class Trigger:
    def __init__(self):
        self.case = 0
        self.seen = set()
        self.pending = None

    def observe(self, line, now):
        if line.startswith("Test Case ") and " started" in line:
            self.case += 1
            self.pending = None
        if line.startswith("Test Case ") and (" passed" in line or " failed" in line):
            self.pending = None
        activity = ACTIVITY.match(line)
        if activity:
            depth, text = len(activity[1]), activity[2]
            if re.match(r"(?:Launch|Terminate) com\.331works\.immichSlides\b", text):
                if self.pending is None:
                    self.pending = (now, depth)
            elif self.pending is not None and depth <= self.pending[1]:
                self.pending = None
        reason = "native-failure" if FAILURE.search(line) else (
            "activity-timeout" if self.pending is not None and now - self.pending[0] >= ACTIVITY_TIMEOUT_SECONDS else None)
        if reason is None or self.case in self.seen or len(self.seen) >= MAX_CAPTURES:
            return None
        self.seen.add(self.case)
        return reason


def empty_capture(trigger):
    return {"trigger": trigger, "status": dict.fromkeys(sorted(KINDS), "unavailable"), "files": [],
            "trigger_to_capture_start_seconds": None, "trigger_to_capture_end_seconds": None}


def normalize(data):
    from run_fixture_ui_tests import redact_crash_report
    data = redact_crash_report(data, str(Path.home()))
    return re.sub(rb'/(?:Users|home)/[^/\s"\\]+', b"~", data)


def scan_bytes(data):
    from access_lifecycle_contract import logical_bytes_contain
    from ci_failure_diagnostics import scan_diagnostic_json
    from git_privacy_gate import contains_high_confidence_secret
    from strict_e2e_server import PUBLIC_API_KEY
    from strict_e2e_runner_support import WRONG_PUBLIC_API_KEY
    if logical_bytes_contain(data, [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY]) or contains_high_confidence_secret(data):
        raise ValueError("withheld")
    scan_diagnostic_json(data)


def publish_file(root, record, kind, name, raw, total):
    try:
        data = normalize(raw)
        scan_bytes(data)
    except Exception:
        record["status"][kind] = "withheld"
        return total
    data = data[:MAX_FILE_BYTES]
    if not data or total + len(data) > MAX_TOTAL_BYTES:
        if not any(item["kind"] == kind for item in record["files"]) and record["status"][kind] != "withheld":
            record["status"][kind] = "unavailable"
        return total
    root.mkdir(parents=True, exist_ok=True)
    path = root / name
    path.write_bytes(data)
    path.chmod(0o600)
    record["files"].append({"kind": kind, "name": name})
    record["status"][kind] = "withheld" if record["status"][kind] == "withheld" else "captured"
    return total + len(data)


def validate_summary(payload):
    if (set(payload) != {"schema_version", "captures"} or type(payload["schema_version"]) is not int or payload["schema_version"] != 1
            or not isinstance(payload["captures"], list) or len(payload["captures"]) > MAX_CAPTURES):
        raise ValueError("invalid lifecycle summary")
    names = set()
    for record in payload["captures"]:
        if (set(record) != {"trigger", "status", "files", "trigger_to_capture_start_seconds", "trigger_to_capture_end_seconds"}
                or record["trigger"] not in {"native-failure", "activity-timeout"}
                or set(record["status"]) != KINDS or any(value not in STATUSES for value in record["status"].values())
                or not isinstance(record["files"], list) or len(record["files"]) > 8):
            raise ValueError("invalid lifecycle capture")
        start, end = record["trigger_to_capture_start_seconds"], record["trigger_to_capture_end_seconds"]
        if not (start is None and end is None or all(type(value) in {int, float} and math.isfinite(value) and value >= 0
                for value in (start, end)) and end >= start):
            raise ValueError("invalid lifecycle capture lag")
        for item in record["files"]:
            if (set(item) != {"kind", "name"} or item["kind"] not in KINDS
                    or not re.fullmatch(r"[A-Za-z0-9_-]+\.(?:txt|log|ips|crash)", item["name"]) or item["name"] in names):
                raise ValueError("invalid lifecycle file")
            names.add(item["name"])


def write_summary(root, payload):
    validate_summary(payload)
    root.mkdir(parents=True, exist_ok=True)
    (root / "summary.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def prepare_publication(root):
    """Recheck optional evidence before the ordinary scan; drop a refused file, keeping a closed receipt."""
    try:
        return _prepare_publication(root)
    except Exception:
        # This directory contains only optional captures owned by this runner.
        shutil.rmtree(root, ignore_errors=True)
        return False


def _prepare_publication(root):
    found = False
    for summary in root.rglob("summary.json"):
        payload = json.loads(summary.read_text())
        validate_summary(payload)
        total = 0
        for record in payload["captures"]:
            retained = []
            for item in record["files"]:
                path = summary.parent / item["name"]
                try:
                    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_FILE_BYTES:
                        raise ValueError("withheld")
                    data = path.read_bytes()
                    scan_bytes(data)
                    total += len(data)
                    if total > MAX_TOTAL_BYTES:
                        raise ValueError("withheld")
                    retained.append(item)
                except Exception:
                    path.unlink(missing_ok=True)
                    record["status"][item["kind"]] = "withheld"
            record["files"] = retained
        allowed = {"summary.json"} | {item["name"] for record in payload["captures"] for item in record["files"]}
        for path in summary.parent.iterdir():
            if path.name not in allowed:
                path.unlink()
        write_summary(summary.parent, payload)
        found = True
    return found


def process_state(raw, root):
    rows = {}
    for line in raw.splitlines():
        pid, parent, state, cpu, elapsed, name = line.split(None, 5)
        pid, parent, cpu = int(pid), int(parent), float(cpu)
        if pid <= 0 or parent < 0 or not math.isfinite(cpu) or cpu < 0:
            raise ValueError("invalid process state")
        rows[pid] = (parent, state, cpu, elapsed, Path(name).name)
    if root not in rows:
        raise ValueError("unavailable simulator root")
    owned, pending = set(), [root]
    while pending:
        pid = pending.pop()
        owned.add(pid)
        pending.extend(child for child, row in rows.items() if row[0] == pid and child not in owned)
    selected = [(pid, *rows[pid]) for pid in sorted(owned) if rows[pid][-1] in PROCESS_NAMES]
    apps = [row[0] for row in selected if row[-1] == "immichSlides"]
    text = "pid ppid state cpu elapsed name\n" + "".join(" ".join(map(str, row)) + "\n" for row in selected)
    return text, apps[0] if len(apps) == 1 else None


def crash_reports(home, udid, baseline):
    device = home / "Library/Developer/CoreSimulator/Devices" / udid / "data/Library/Logs"
    directories = [(home / "Library/Logs/DiagnosticReports", False), (device / "CrashReporter", True),
                   (device / "DiagnosticReports", True)]
    count = 0
    for directory, scoped in directories:
        for path in directory.rglob("*"):
            if (path.is_symlink() or not path.is_file() or path.suffix.lower() not in {".ips", ".crash"}
                    or not any(path.name.startswith(name) for name in PROCESS_NAMES) or path.stat().st_mtime < baseline):
                continue
            with path.open("rb") as source:
                prefix = source.read(MAX_FILE_BYTES + 1)
            if not scoped and udid.lower().encode() not in prefix.lower():
                continue
            yield path
            count += 1
            if count >= 5:
                return


def command_output(command, path, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return "timeout", b""
    try:
        with path.open("wb") as output:
            completed = subprocess.run(command, stdout=output, stderr=subprocess.DEVNULL, timeout=min(5, remaining), check=False)
        with path.open("rb") as source:
            raw = source.read(MAX_FILE_BYTES)
        if not raw or completed.returncode and completed.returncode != -signal.SIGXFSZ:
            return "unavailable", b""
        return "captured", raw
    except subprocess.TimeoutExpired:
        return "timeout", b""
    except OSError:
        return "unavailable", b""


def collect(udid, baseline, root, trigger):
    """Runs only in a killable private subprocess; no raw command output enters the public tree."""
    record, total = empty_capture(trigger), 0
    deadline = time.monotonic() + CAPTURE_TIMEOUT_SECONDS - 2
    def output(kind, name, command):
        nonlocal total
        status, raw = command_output(command, root / "raw", deadline)
        record["status"][kind] = status
        if raw:
            total = publish_file(root, record, kind, name, raw, total)
        return status, raw
    try:
        state, manager = command_output(["xcrun", "simctl", "spawn", udid, "launchctl", "managerpid"], root / "raw", deadline)
        if state != "captured":
            record["status"]["processes"] = state
        else:
            state, raw = command_output(["/bin/ps", "-A", "-o", "pid=,ppid=,state=,%cpu=,etime=,comm="], root / "raw", deadline)
            record["status"]["processes"] = state
            if state == "captured":
                text, pid = process_state(raw.decode("utf-8", errors="replace"), int(manager.strip()))
                total = publish_file(root, record, "processes", "processes.txt", text.encode(), total)
                if pid is not None:
                    output("app_sample", "app-sample.txt", ["/usr/bin/sample", str(pid), "1", "10"])
    except (OSError, ValueError):
        record["status"]["processes"] = "unavailable"
    output("simulator_log", "simulator.log", ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "3m",
           "--style", "compact", "--predicate", LOG_PREDICATE])
    try:
        for number, path in enumerate(crash_reports(Path.home(), udid, baseline), 1):
            if time.monotonic() >= deadline:
                record["status"]["crash_reports"] = "timeout"
                break
            with path.open("rb") as source:
                raw = source.read(MAX_FILE_BYTES + 1)
            total = publish_file(root, record, "crash_reports", "crash-" + str(number) + path.suffix.lower(), raw, total)
    except OSError:
        record["status"]["crash_reports"] = "unavailable"
    (root / "raw").unlink(missing_ok=True)
    write_summary(root, {"schema_version": 1, "captures": [record]})


def capture(udid, baseline, destination, trigger, number, total):
    record = empty_capture(trigger)
    deadline = time.monotonic() + CAPTURE_TIMEOUT_SECONDS
    with tempfile.TemporaryDirectory(prefix="immichSlides-lifecycle-") as directory:
        private = Path(directory)
        process = subprocess.Popen([sys.executable, "-B", str(Path(__file__).resolve()), udid, str(baseline), directory, trigger],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            code = process.wait(timeout=max(0, deadline - time.monotonic() - 1))
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=max(0, deadline - time.monotonic()))
            record["status"] = dict.fromkeys(sorted(KINDS), "timeout")
            return record, total
        if code:
            return record, total
        payload = json.loads((private / "summary.json").read_text())
        validate_summary(payload)
        record = payload["captures"][0]
        items, record["files"] = record["files"], []
        for item in items:
            if time.monotonic() >= deadline:
                record["status"][item["kind"]] = "timeout"
                continue
            total = publish_file(destination, record, item["kind"], f"capture-{number}-" + item["name"],
                                 (private / item["name"]).read_bytes(), total)
    return record, total


class Monitor:
    def __init__(self, log, udid, destination):
        self.log, self.udid, self.destination = log, udid, destination
        self.baseline = time.time()
        self.trigger = Trigger()
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.watch, name="fixture-lifecycle")
        self.worker = threading.Thread(target=self.collect_requests, name="fixture-lifecycle-capture")
        self.requests = queue.Queue(maxsize=MAX_CAPTURES + 1)
        self.payload = {"schema_version": 1, "captures": []}
        self.total = 0

    def watch(self):
        try:
            with self.log.open(encoding="utf-8", errors="replace") as log:
                self.worker.start()
                try:
                    while True:
                        line = log.readline(8192)
                        observed_at = time.monotonic()
                        reason = self.trigger.observe(line, observed_at)
                        if reason:
                            self.requests.put_nowait((reason, observed_at))
                        if not line and self.stopped.wait(0.1):
                            return
                finally:
                    self.requests.put_nowait(None)
                    self.worker.join()
        except Exception:
            # Optional evidence cannot replace the XCTest exit or prevent bundle finalization.
            return

    def collect_requests(self):
        while True:
            request = self.requests.get()
            if request is None:
                return
            reason, observed_at = request
            started_at = time.monotonic()
            try:
                record, self.total = capture(self.udid, self.baseline, self.destination, reason,
                                            len(self.payload["captures"]) + 1, self.total)
            except Exception:
                record = empty_capture(reason)
            record["trigger_to_capture_start_seconds"] = started_at - observed_at
            record["trigger_to_capture_end_seconds"] = time.monotonic() - observed_at
            self.payload["captures"].append(record)
            try:
                write_summary(self.destination, self.payload)
            except Exception:
                # A failed optional receipt write cannot escape into the runner's verdict.
                pass


@contextmanager
def monitor_invocation(command, log, udid, destination):
    monitor = None
    try:
        if "test-without-building" in command and "-enumerate-tests" not in command:
            monitor = Monitor(log, udid, destination)
            monitor.thread.start()
    except Exception:
        monitor = None
    try:
        yield
    finally:
        if monitor is not None:
            monitor.stopped.set()
            monitor.thread.join()


if __name__ == "__main__":
    import resource
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_FILE_BYTES, MAX_FILE_BYTES))
    collect(sys.argv[1], float(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
