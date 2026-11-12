"""Bounded, scanned fixture-only evidence for a live XCTest lifecycle failure."""

from __future__ import annotations

import hashlib
import json
import math
import os
import queue
import re
import selectors
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
MAX_READER_BYTES = 64 * 1024
JOIN_TIMEOUT_SECONDS = MAX_CAPTURES * CAPTURE_TIMEOUT_SECONDS + 5
TRUNCATED = b"[truncated: earlier output omitted]\n"
KINDS = {"processes", "app_sample", "simulator_log", "crash_reports"}
STATUSES = {"captured", "unavailable", "timeout", "withheld", "skipped", "budget-exhausted", "oversized", "duplicate"}
PROCESS_NAMES = {"immichSlides", "SpringBoard", "launchd_sim", "ReportCrash", "testmanagerd"}
LOG_PREDICATE = ('process == "immichSlides" OR process == "SpringBoard" OR process == "launchd_sim" '
                 'OR subsystem CONTAINS[c] "RunningBoard" OR subsystem CONTAINS[c] "launchd" OR subsystem CONTAINS[c] "XCTest"')
FAILURE = re.compile(r"Failed to terminate|Failed to get matching snapshot|Timed out while evaluating UI query|\bcrashed\b", re.I)
ACTIVITY = re.compile(r"\s*t\s*=\s*[\d.]+s(\s+)(.*)")


class Trigger:
    def __init__(self):
        self.case = 0
        self.seen = set()
        self.activity_seen = set()
        self.capture_count = 0
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
        if reason == "activity-timeout" and self.case in self.activity_seen:
            return None
        return self.reserve(self.case, reason)

    def reserve(self, case, reason):
        if reason is None or case in self.seen or self.capture_count >= MAX_CAPTURES:
            return None
        self.seen.add(case)
        self.capture_count += 1
        if reason == "activity-timeout":
            self.activity_seen.add(case)
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


def publish_file(root, record, kind, name, raw, total, seen_crashes=None):
    if kind == "crash_reports" and len(raw) > MAX_FILE_BYTES:
        record["status"][kind] = "oversized"
        return total
    try:
        data = normalize(raw)
        scan_bytes(data)
    except Exception:
        record["status"][kind] = "withheld"
        return total
    if kind == "crash_reports" and len(data) > MAX_FILE_BYTES:
        record["status"][kind] = "oversized"
        return total
    data = bounded_tail(data)
    fingerprint = hashlib.sha256(data).hexdigest()
    if kind == "crash_reports" and seen_crashes is not None and fingerprint in seen_crashes:
        record["status"][kind] = "duplicate"
        return total
    if total + len(data) > MAX_TOTAL_BYTES:
        record["status"][kind] = "budget-exhausted"
        return total
    if not data:
        return total
    root.mkdir(parents=True, exist_ok=True)
    path = root / name
    path.write_bytes(data)
    path.chmod(0o600)
    record["files"].append({"kind": kind, "name": name})
    # Status describes the latest source result; the file list identifies every retained file.
    record["status"][kind] = "captured"
    if kind == "crash_reports" and seen_crashes is not None:
        seen_crashes.add(fingerprint)
    return total + len(data)


def validate_summary(payload):
    if (set(payload) - {"monitor_status"} != {"schema_version", "captures"}
            or payload.get("monitor_status", "complete") not in {"complete", "timeout"}
            or type(payload["schema_version"]) is not int or payload["schema_version"] != 1
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
    with tempfile.NamedTemporaryFile(mode="w", dir=root, delete=False) as receipt:
        temporary = Path(receipt.name)
        try:
            receipt.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
            receipt.close()
            temporary.replace(root / "summary.json")
        finally:
            temporary.unlink(missing_ok=True)


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
                    if total + len(data) > MAX_TOTAL_BYTES:
                        path.unlink()
                        record["status"][item["kind"]] = "budget-exhausted"
                        continue
                    total += len(data)
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
        if not line.strip():
            continue
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


def crash_reports(home, udid, baseline, deadline=float("inf"), seen_paths=()):
    device = home / "Library/Developer/CoreSimulator/Devices" / udid / "data/Library/Logs"
    directories = [(home / "Library/Logs/DiagnosticReports", False), (device / "CrashReporter", True),
                   (device / "DiagnosticReports", True)]
    count = 0
    for directory, scoped in directories:
        for path in directory.rglob("*"):
            if time.monotonic() >= deadline:
                raise TimeoutError("crash traversal deadline")
            if (str(path) in seen_paths or path.is_symlink() or not path.is_file() or path.suffix.lower() not in {".ips", ".crash"}
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


def bounded_tail(raw, truncated=False):
    if len(raw) <= MAX_FILE_BYTES and not truncated:
        return raw
    tail = raw[-(MAX_FILE_BYTES - len(TRUNCATED)):]
    # Drop the partial oldest line; the newest complete lines contain the trigger window.
    return TRUNCATED + tail.partition(b"\n")[2]


def command_output(command, path, deadline, *, process_root=None):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return "timeout", b""
    process = None
    try:
        command_deadline = min(deadline, time.monotonic() + 5)
        raw, partial, rows, truncated = b"", b"", [], False
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = command_deadline - time.monotonic()
                if remaining <= 0:
                    process.kill()
                    process.wait()
                    return "timeout", b""
                for key, _ in selector.select(remaining):
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if process_root is not None:
                        partial += chunk
                        lines = partial.split(b"\n")
                        rows.extend(lines[:-1])
                        partial = lines[-1]
                        if len(rows) > 100000 or len(partial) > MAX_FILE_BYTES:
                            raise ValueError("invalid process population")
                    else:
                        raw += chunk
                        if len(raw) > MAX_FILE_BYTES:
                            raw, truncated = raw[-MAX_FILE_BYTES:], True
            code = process.wait(timeout=max(0, command_deadline - time.monotonic()))
        if code:
            return "unavailable", b""
        if process_root is not None:
            text, _ = process_state(b"\n".join(rows + [partial]).decode("utf-8", errors="replace"), process_root)
            raw = text.encode()
            if len(raw) > MAX_FILE_BYTES:
                return "unavailable", b""
        else:
            raw = bounded_tail(raw, truncated)
        return ("captured", raw) if raw else ("unavailable", b"")
    except subprocess.TimeoutExpired:
        if process is not None:
            process.kill()
            process.wait()
        return "timeout", b""
    except (OSError, ValueError):
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        return "unavailable", b""
    finally:
        if process is not None and process.stdout is not None:
            process.stdout.close()


def collect(udid, baseline, root, trigger, deadline, release_path=None, seen_crash_paths=()):
    """Runs only in a killable private subprocess; no raw command output enters the public tree."""
    record, total = empty_capture(trigger), 0
    seen_crash_paths = set(seen_crash_paths)
    def save():
        write_summary(root, {"schema_version": 1, "captures": [record]})
    save()
    def output(kind, name, command):
        nonlocal total
        status, raw = command_output(command, root / "raw", deadline)
        record["status"][kind] = status
        if raw:
            total = publish_file(root, record, kind, name, raw, total)
        save()
        return status, raw
    pid = None
    try:
        state, manager = command_output(["xcrun", "simctl", "spawn", udid, "launchctl", "managerpid"], root / "raw", deadline)
        if state != "captured":
            record["status"]["processes"] = state
        else:
            state, raw = command_output(["/bin/ps", "-A", "-c", "-o", "pid=,ppid=,state=,%cpu=,etime=,comm="],
                                        root / "raw", deadline, process_root=int(manager.strip()))
            record["status"]["processes"] = state
            if state == "captured":
                text, pid = process_state(raw.decode("utf-8", errors="replace").partition("\n")[2], int(manager.strip()))
                total = publish_file(root, record, "processes", "processes.txt", text.encode(), total)
    except (OSError, ValueError):
        record["status"]["processes"] = "unavailable"
    save()
    if release_path is not None:
        while not release_path.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if not release_path.exists():
            for kind in KINDS - {"processes"}:
                record["status"][kind] = "skipped"
            save()
            return
    if pid is not None:
        output("app_sample", "app-sample.txt", ["/usr/bin/sample", str(pid), "1", "10", "-file", "/dev/stdout"])
    output("simulator_log", "simulator.log", ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "60s",
           "--style", "compact", "--predicate", LOG_PREDICATE])
    try:
        for number, path in enumerate(crash_reports(Path.home(), udid, baseline, deadline, seen_crash_paths), 1):
            if time.monotonic() >= deadline:
                record["status"]["crash_reports"] = "timeout"
                break
            with path.open("rb") as source:
                raw = source.read(MAX_FILE_BYTES + 1)
            seen_crash_paths.add(str(path))
            paths_receipt = root / "crash-paths.json.tmp"
            paths_receipt.write_text(json.dumps(sorted(seen_crash_paths)))
            paths_receipt.replace(root / "crash-paths.json")
            total = publish_file(root, record, "crash_reports", "crash-" + str(number) + path.suffix.lower(), raw, total)
            save()
    except TimeoutError:
        record["status"]["crash_reports"] = "timeout"
    except OSError:
        record["status"]["crash_reports"] = "unavailable"
    (root / "raw").unlink(missing_ok=True)
    write_summary(root, {"schema_version": 1, "captures": [record]})


def capture(udid, baseline, destination, trigger, number, total, *, deadline=None, release=None, seen_crashes=None,
            seen_crash_paths=None):
    record = empty_capture(trigger)
    deadline = min(deadline if deadline is not None else float("inf"), time.monotonic() + CAPTURE_TIMEOUT_SECONDS)
    with tempfile.TemporaryDirectory(prefix="immichSlides-lifecycle-") as directory:
        private = Path(directory)
        release_path = private / "release" if release is not None else None
        process = subprocess.Popen(["/usr/bin/nice", "-n", "10", sys.executable, "-B", str(Path(__file__).resolve()), udid,
                                    str(baseline), directory, trigger, str(deadline - 2), str(release_path) if release_path else "",
                                    json.dumps(sorted(seen_crash_paths or ()))],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            while True:
                if release_path is not None and release.is_set():
                    release_path.touch()
                remaining = max(0, deadline - time.monotonic() - 1)
                try:
                    code = process.wait(timeout=min(0.1, remaining) if release_path is not None else remaining)
                    break
                except subprocess.TimeoutExpired:
                    if release_path is None or time.monotonic() >= deadline - 1:
                        raise
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=max(0, deadline - time.monotonic()))
            code = -signal.SIGKILL
            record["status"] = dict.fromkeys(sorted(KINDS), "timeout")
        if seen_crash_paths is not None and (private / "crash-paths.json").is_file():
            seen_crash_paths.update(json.loads((private / "crash-paths.json").read_text()))
        if not (private / "summary.json").is_file():
            return record, total
        payload = json.loads((private / "summary.json").read_text())
        validate_summary(payload)
        record = payload["captures"][0]
        if code:
            for kind in KINDS:
                if record["status"][kind] == "unavailable":
                    record["status"][kind] = "timeout" if code == -signal.SIGKILL else "unavailable"
        items, record["files"] = record["files"], []
        for item in items:
            if time.monotonic() >= deadline:
                record["status"][item["kind"]] = "timeout"
                continue
            total = publish_file(destination, record, item["kind"], f"capture-{number}-" + item["name"],
                                 (private / item["name"]).read_bytes(), total, seen_crashes)
    return record, total


class Monitor:
    def __init__(self, log, udid, destination, deadline=float("inf")):
        self.log, self.udid, self.destination = log, udid, destination
        self.deadline = deadline
        self.shutdown_deadline = float("inf")
        self.baseline = time.time()
        self.trigger = Trigger()
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.watch, name="fixture-lifecycle", daemon=True)
        self.worker = threading.Thread(target=self.collect_requests, name="fixture-lifecycle-capture", daemon=True)
        self.requests = queue.Queue(maxsize=MAX_CAPTURES + 1)
        self.payload = {"schema_version": 1, "captures": []}
        self.total = 0
        self.releases = {}
        self.native_failures = {}
        self.lock = threading.Lock()
        self.seen_crashes = set()
        self.seen_crash_paths = set()

    def observe(self, line):
        now = time.monotonic()
        with self.lock:
            reason = self.trigger.observe(line, now)
            case = self.trigger.case
            release = self.releases.get(case)
            if release is not None and FAILURE.search(line):
                self.native_failures.setdefault(case, now)
                release.set()
            if reason:
                release = threading.Event() if reason == "activity-timeout" else None
                if release is not None:
                    self.releases[case] = release
                self.requests.put_nowait((reason, now, release, case))

    def stop(self):
        self.shutdown_deadline = time.monotonic() + JOIN_TIMEOUT_SECONDS
        self.stopped.set()

    def mark_join_timeout(self):
        self.payload["monitor_status"] = "timeout"
        try:
            write_summary(self.destination, self.payload)
        except Exception:
            pass

    def watch(self):
        try:
            with self.log.open("rb") as log:
                self.worker.start()
                try:
                    buffer, stop_position = b"", None
                    while True:
                        if self.stopped.is_set() and stop_position is None:
                            stop_position = os.fstat(log.fileno()).st_size
                        remaining = 8192 if stop_position is None else max(0, stop_position - log.tell())
                        chunk = log.read(min(8192, remaining))
                        buffer = (buffer + chunk)[-MAX_READER_BYTES:]
                        lines = buffer.split(b"\n")
                        buffer = lines[-1]
                        for line in lines[:-1]:
                            self.observe(line.decode("utf-8", errors="replace"))
                        if stop_position is not None and log.tell() >= stop_position:
                            if buffer:
                                self.observe(buffer.decode("utf-8", errors="replace"))
                            return
                        if not chunk:
                            self.observe("")
                            self.stopped.wait(0.1)
                finally:
                    with self.lock:
                        for release in self.releases.values():
                            release.set()
                        self.requests.put_nowait(None)
                    self.worker.join(timeout=JOIN_TIMEOUT_SECONDS)
                    if self.worker.is_alive():
                        self.mark_join_timeout()
        except Exception:
            # Optional evidence cannot replace the XCTest exit or prevent bundle finalization.
            return

    def collect_requests(self):
        followup = None
        while True:
            request = followup if followup is not None else self.requests.get()
            followup = None
            if request is None:
                return
            reason, observed_at, release, case = request
            started_at = time.monotonic()
            deadline = min(self.deadline, self.shutdown_deadline)
            try:
                if deadline - started_at < CAPTURE_TIMEOUT_SECONDS:
                    record = empty_capture(reason)
                    record["status"] = dict.fromkeys(sorted(KINDS), "skipped")
                else:
                    record, self.total = capture(self.udid, self.baseline, self.destination, reason,
                        len(self.payload["captures"]) + 1, self.total, deadline=deadline,
                        release=release, seen_crashes=self.seen_crashes, seen_crash_paths=self.seen_crash_paths)
            except Exception:
                record = empty_capture(reason)
            record["trigger_to_capture_start_seconds"] = started_at - observed_at
            record["trigger_to_capture_end_seconds"] = time.monotonic() - observed_at
            self.payload["captures"].append(record)
            if release is not None:
                with self.lock:
                    self.releases.pop(case, None)
                    failure_at = self.native_failures.pop(case, None)
                    if not release.is_set() or all(record["status"][kind] == "skipped" for kind in KINDS - {"processes"}):
                        self.trigger.seen.discard(case)
                        if failure_at is not None and self.trigger.reserve(case, "native-failure"):
                            followup = ("native-failure", failure_at, None, case)
            try:
                write_summary(self.destination, self.payload)
            except Exception:
                # A failed optional receipt write cannot escape into the runner's verdict.
                pass


@contextmanager
def monitor_invocation(command, log, udid, destination, deadline=float("inf")):
    monitor = None
    try:
        if "test-without-building" in command and "-enumerate-tests" not in command:
            monitor = Monitor(log, udid, destination, deadline)
            monitor.thread.start()
    except Exception:
        monitor = None
    try:
        yield
    finally:
        if monitor is not None:
            monitor.stop()
            monitor.thread.join(timeout=JOIN_TIMEOUT_SECONDS)
            if monitor.thread.is_alive():
                monitor.mark_join_timeout()


def main(arguments):
    collect(arguments[0], float(arguments[1]), Path(arguments[2]), arguments[3], float(arguments[4]),
            Path(arguments[5]) if arguments[5] else None, set(json.loads(arguments[6])))


if __name__ == "__main__":
    main(sys.argv[1:])
