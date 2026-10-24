"""Bounded strict E2E contention measurements and public stacks; never a test verdict."""

from __future__ import annotations

import ctypes
import json
import math
import os
import queue
import re
import statistics
import subprocess
import sys
import threading
import time
import tempfile
from datetime import datetime
from pathlib import Path
from threading import Event, Thread

from ci_bounded_diagnostics import (MAX_DIAGNOSTIC_SECONDS,
    MAX_LOAD_AVERAGE, MAX_PROCESS_CPU_PERCENT, MAX_RESOURCE_CASES, MAX_RESOURCE_SAMPLES,
    RESOURCE_CATEGORIES, validate_case_resources, APP_HANG_MODULES, MAX_APP_HANG_STACK_BYTES,
    MAX_INTEGER, public_stack_symbol, validate_app_hang_stack)
from ci_bounded_diagnostics import (MAX_CONTINUE_WATCH_BYTES, MAX_CONTINUE_WATCH_FRAMES,
                                    CONTINUE_WATCH_STATUSES, validate_continue_watch)
from ci_execution_diagnostics import finite
from ci_failure_diagnostics import NATIVE_ACTIVITY_FIELDS, public_first_failure

SAMPLE_INTERVAL_SECONDS = 2
PROCESS_SAMPLE_INTERVAL_SECONDS = 10
SAMPLER_WALL_BUDGET_SECONDS = 180
HOST_SAMPLE_TIMEOUT_SECONDS = 0.2
HOST_IDLE_MIN_INTERVAL_SECONDS = 1
HOST_WALL_BUDGET_SECONDS = 10
MAX_HOST_SAMPLE_INTERVAL_SECONDS = 4
SAMPLE_COMMAND_TIMEOUT_SECONDS = 0.5
# Stop must outlast one in-flight sample command, or a slow `ps` leaves the sampler unfinished and voids the budget.
STOP_TIMEOUT_SECONDS = HOST_SAMPLE_TIMEOUT_SECONDS + SAMPLE_COMMAND_TIMEOUT_SECONDS + 0.1
MAX_PROCESS_TABLE_BYTES = 2 * 1024 * 1024
MAX_PROCESS_ROWS = 65536
NATIVE_MATCH_TOLERANCE_SECONDS = 0.1
NATIVE_CASE_BUDGET_SECONDS = 2
NATIVE_JOB_BUDGET_SECONDS = 20
CLOCK_DRIFT_TOLERANCE_SECONDS = 0.5
# Matches the runner's default xcodebuild deadline; callers pass the invocation's actual deadline.
DEFAULT_DURATION_LIMIT_SECONDS = 300
APP_HANG_CPU_PERCENT = 85
APP_HANG_SUSTAINED_SECONDS = 8
APP_HANG_MAX_GAP_SECONDS = 4.5
APP_HANG_JOB_CAP = 3
APP_HANG_TIMEOUT_SECONDS = 3
MAX_RAW_SAMPLE_BYTES = 2 * 1024 * 1024


def attach_continue_watch(receipt, evidence_dir, *, platform, suite, result, sequence):
    """Read only the failed case's numeric evidence; never publish its raw JSON or notes."""
    if platform != "tvos" or suite != "tvos-lifecycle-pause" or result != "FAILED":
        return
    try:
        cases = [case for case in receipt.get("case_resources", []) if case["sequence"] == sequence]
        if len(cases) != 1:
            return
        path = evidence_dir / "continue-watch-diagnostic.json"
        if path.is_symlink():
            return
        with path.open("rb") as source:
            encoded = source.read(MAX_RAW_SAMPLE_BYTES + 1)
        if len(encoded) > MAX_RAW_SAMPLE_BYTES:
            return
        raw = json.loads(encoded)
        frames, samples = raw["frames"], raw["samples"]
        if not isinstance(frames, list) or not isinstance(samples, list):
            return
        def rounded(value):
            if value is None:
                return None
            if type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError("invalid numeric measurement")
            return round(value, 3)
        rows = []
        for index, frame in enumerate(frames[:MAX_CONTINUE_WATCH_FRAMES]):
            # Classification stops at the first stable image; later captured frames remain unclassified.
            sample = samples[index] if index < len(samples) else {}
            if not isinstance(frame, dict) or not isinstance(sample, dict):
                return
            if sample and (sample["request"] != frame["request"] or sample["returned"] != frame["returned"]):
                return
            mark = sample.get("mark")
            if mark in CONTINUE_WATCH_STATUSES:
                mark = None
            rows.append([*(rounded(frame[key]) for key in ("request", "captured", "returned")),
                sample.get("status"), mark, rounded(sample.get("luma", frame.get("photo_decoded_mean_luma"))),
                rounded(frame.get("photo_q95")),
                rounded(frame.get("photo_white_core_fraction")), sample.get("controls")])
        wake = raw.get("control_bar_wake")
        projection = {"total_frames": len(frames), "truncated": len(rows) < len(frames), "frames": rows,
            "indices": raw.get("rescue_indices", {}), "rescue": raw.get("rescue_outcome", "not_recorded"),
            "wake": [rounded(wake[key]) for key in ("issued", "returned")] if wake is not None else None}
        # Validate before trimming so malformed optional metadata is never laundered by the cap.
        indices = projection["indices"]
        if not isinstance(indices, dict) or set(indices) - {"anchor", "dim", "proof"} or any(
                type(index) is not int or not 0 <= index < len(frames) for index in indices.values()):
            return
        while len(json.dumps(projection, separators=(",", ":")).encode()) > MAX_CONTINUE_WATCH_BYTES and rows:
            rows.pop()
        projection["truncated"] = len(rows) < len(frames)
        projection["indices"] = {key: index for key, index in indices.items() if index < len(rows)}
        validate_continue_watch(projection)
        cases[0]["continue_watch"] = projection
    except (OSError, ValueError, TypeError, KeyError, OverflowError):
        pass  # Optional malformed evidence cannot discard the other diagnostics or alter the case verdict.


def reduce_main_thread_sample(raw):
    """Retain App frames and an observed callee-to-caller path, without raw metadata."""
    result = {"status": "captured", "sample_count": 0, "frames": [], "hint": []}
    in_main = False
    counts, depths, nodes, ancestors = {}, {}, [], []
    for line in raw.splitlines():
        header = re.fullmatch(r"\s*(\d+) Thread_\d+(?:[ :](?!\s*\(in ).*)?", line)
        if header is not None:
            if in_main:
                break
            if "com.apple.main-thread" in line:
                result["sample_count"] = min(MAX_INTEGER, int(header[1]))
                in_main = True
            continue
        if not in_main:
            continue
        if line and not line[0].isspace():
            break
        frame = re.fullmatch(r"([+|!: ]*)(\d+) (.*?)  \(in ([^)]+)\).*", line)
        if frame is None:
            continue
        depth, count, symbol, module = len(frame[1]), min(MAX_INTEGER, int(frame[2])), frame[3], frame[4]
        while ancestors and ancestors[-1]["depth"] >= depth:
            ancestors.pop()
        node = {"depth": depth, "count": count, "key": None, "parent": ancestors[-1] if ancestors else None}
        nodes.append(node)
        ancestors.append(node)
        if module == "immichSlides.debug.dylib":
            module = "immichSlides"
        if module not in APP_HANG_MODULES:
            continue
        if any(character in symbol for character in ('/', '\\', '@', '"', "'")):
            continue
        objc = re.fullmatch(r"[-+]\[([A-Za-z_][A-Za-z0-9_]*) ([A-Za-z_][A-Za-z0-9_:]*)\]", symbol)
        if objc:
            symbol = objc[1] + "." + objc[2].replace(":", "_")
        else:
            # Demangled generic arguments and closure descriptions are not public identifiers.
            while re.search(r"<[^<>]*>", symbol):
                symbol = re.sub(r"<[^<>]*>", "", symbol)
            symbol = symbol.split(" in ")[-1].split("(")[0].strip().split(" ")[-1]
        if not public_stack_symbol(symbol):
            continue
        if count > 0:
            key = symbol, module
            node["key"] = key
            counts[key] = min(MAX_INTEGER, counts.get(key, 0) + count)
            depths[key] = max(depth, depths.get(key, 0))
    public = [node for node in nodes if node["key"] is not None]
    app = [node for node in public if node["key"][1] == "immichSlides"]
    candidates = app or public
    path = []
    if candidates:
        heavy = max(node["count"] for node in candidates) * 0.8
        bodies = [node for node in app if node["count"] >= heavy and re.search(r"\.body(?:\.|$)", node["key"][0])]
        if bodies:
            anchor = max(bodies, key=lambda node: node["depth"])
        elif app:
            anchor = max(app, key=lambda node: (node["count"], node["depth"]))
        else:
            anchor = max((node for node in public if node["count"] >= heavy), key=lambda node: node["depth"])
        while anchor is not None:
            if anchor["key"] is not None and anchor["key"] not in path:
                path.append(anchor["key"])
            anchor = anchor["parent"]
        path = path[:3]
    keys = sorted(counts, key=lambda key: (key != (path[0] if path else None),
        key[1] != "immichSlides", key not in path, -counts[key], -depths[key]))[:30]
    for symbol, module in keys:
        result["frames"].append({"symbol": symbol, "module": module, "samples": counts[(symbol, module)]})
    while True:
        result["hint"] = [keys.index(key) for key in path if key in keys]
        if len(json.dumps(result, separators=(",", ":")).encode()) <= MAX_APP_HANG_STACK_BYTES:
            break
        result["frames"].pop()
        keys.pop()
    return result


def capture_main_thread(pid, stopped, *, device):
    """Keep raw output in a private temporary directory, never in an evidence tree."""
    result = {"status": "failure", "sample_count": 0, "frames": []}
    process = None
    deadline = time.monotonic() + APP_HANG_TIMEOUT_SECONDS
    try:
        with tempfile.TemporaryDirectory(prefix="strict-app-hang-") as directory:
            path = Path(directory) / "sample.txt"
            try:
                if stopped.is_set():
                    return {**result, "status": "cancelled"}
                if app_on_device(pid, device) is not True:
                    return result
                process = subprocess.Popen(["/usr/bin/sample", str(pid), "1", "10", "-file", str(path)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                while True:
                    if stopped.is_set():
                        return {**result, "status": "cancelled"}
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        return {**result, "status": "timeout"}
                    try:
                        code = process.wait(timeout=min(0.05, remaining))
                        break
                    except subprocess.TimeoutExpired:
                        continue
                if code == 0 and path.stat().st_size <= MAX_RAW_SAMPLE_BYTES:
                    raw = path.read_bytes()[:MAX_RAW_SAMPLE_BYTES + 1]
                    if len(raw) <= MAX_RAW_SAMPLE_BYTES and time.monotonic() < deadline:
                        return reduce_main_thread_sample(raw.decode("utf-8", errors="replace"))
            finally:
                if process is not None and process.poll() is None:
                    process.kill()
                    try:
                        process.wait(timeout=0.1)
                    except subprocess.SubprocessError:
                        pass
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        pass
    return result


class AppHangCapture:
    """One prepaid background capture, with a durable job-wide attempt cap."""

    def __init__(self, recorder, stopped, *, forced=False, case_state=None, device=None):
        self.recorder, self.stopped, self.forced = recorder, stopped, forced
        self.device = device
        self.case_state = {} if case_state is None else case_state
        self.previous = None
        self.since = None
        self.attempted = False
        self.result = None
        self.worker = None
        self.charge = 0.0
        self.wall_seconds = None

    def can_capture(self, remaining_seconds):
        return (not self.attempted and not self.case_state.get("attempted", False) and not self.stopped.is_set()
            and self.recorder.app_hang_capture_attempts < APP_HANG_JOB_CAP and remaining_seconds >= APP_HANG_TIMEOUT_SECONDS)

    def observe(self, pid, cpu, elapsed, *, remaining_seconds):
        if not self.can_capture(remaining_seconds):
            return
        threshold = 0 if self.forced else APP_HANG_CPU_PERCENT
        if pid is None or cpu is None or cpu < threshold:
            self.previous, self.since = None, None
            return
        if self.previous is None or self.previous[0] != pid or not 0 < elapsed - self.previous[1] <= APP_HANG_MAX_GAP_SECONDS:
            self.since = elapsed
        self.previous = pid, elapsed
        if elapsed - self.since < (0 if self.forced else APP_HANG_SUSTAINED_SECONDS):
            return
        self.attempted = True
        self.case_state["attempted"] = True
        self.recorder.app_hang_capture_attempts += 1
        self.charge = APP_HANG_TIMEOUT_SECONDS
        def collect():
            started = time.perf_counter()
            try:
                self.result = capture_main_thread(pid, self.stopped, device=self.device)
            except (OSError, ValueError, TypeError, RuntimeError, subprocess.SubprocessError):
                self.result = {"status": "failure", "sample_count": 0, "frames": []}
            finally:
                self.wall_seconds = time.perf_counter() - started
        try:
            self.worker = threading.Thread(target=collect, daemon=True)
            self.worker.start()
        except (OSError, RuntimeError):
            self.result = {"status": "failure", "sample_count": 0, "frames": []}
            self.wall_seconds = 0.0

    @property
    def cost(self):
        return self.charge if self.wall_seconds is None else self.wall_seconds


class NativeActivityBudget:
    """Precharge child loans and bound native reads without trusting the diagnostic ledger."""

    def __init__(self, seconds=NATIVE_JOB_BUDGET_SECONDS):
        self.remaining_seconds = finite(seconds, NATIVE_JOB_BUDGET_SECONDS, default=0)
        self.case_remaining = {}

    def reserve_case(self):
        allowance = min(NATIVE_CASE_BUDGET_SECONDS, self.remaining_seconds)
        self.remaining_seconds -= allowance
        return allowance

    def collect(self, sequence, operation, *, cap):
        case_remaining = self.case_remaining.setdefault(sequence, NATIVE_CASE_BUDGET_SECONDS)
        limit = min(cap, case_remaining, self.remaining_seconds)
        if limit <= 0:
            return None
        self.remaining_seconds -= limit
        self.case_remaining[sequence] -= limit
        started = time.perf_counter()
        done, values = threading.Event(), []
        def read():
            try:
                values.append(operation(max(0, limit - (time.perf_counter() - started))))
            except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
                pass
            finally:
                done.set()
        try:
            threading.Thread(target=read, daemon=True).start()
            finished = done.wait(max(0, limit - (time.perf_counter() - started)))
        except (OSError, RuntimeError):
            finished = False
        elapsed = time.perf_counter() - started
        if finished:
            refund = max(0, limit - elapsed)
            self.remaining_seconds += refund
            self.case_remaining[sequence] += refund
        return values[0] if finished and elapsed <= limit and values else None


class HostCpu:
    """Read actual interval idle ticks; process CPU is ps's short-term estimate."""

    def __init__(self):
        self.library = None
        self.host = None
        self.previous = None
        self.previous_read_at = None
        if sys.platform == "darwin":
            self.library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            self.library.mach_host_self.restype = ctypes.c_uint32
            self.library.host_statistics.argtypes = [ctypes.c_uint32, ctypes.c_int,
                ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
            self.host = self.library.mach_host_self()

    def idle(self):
        if self.library is None:
            return None
        ticks = (ctypes.c_uint32 * 4)()
        count = ctypes.c_uint32(4)
        if self.library.host_statistics(self.host, 3, ticks, ctypes.byref(count)) != 0 or count.value != 4:
            self.previous = None
            self.previous_read_at = None
            return None
        read_at = time.monotonic()
        previous, self.previous = self.previous, tuple(ticks)
        previous_read_at, self.previous_read_at = self.previous_read_at, read_at
        # A late worker can leave only a few milliseconds of ticks before the next read.
        if previous is None or previous_read_at is None or read_at - previous_read_at < HOST_IDLE_MIN_INTERVAL_SECONDS:
            return None
        delta = [(current - old) & 0xffffffff for old, current in zip(previous, ticks)]
        return 100 * delta[2] / sum(delta) if sum(delta) else None

    def close(self):
        if self.library is not None and self.host is not None:
            task = ctypes.c_uint32.in_dll(self.library, "mach_task_self_").value
            self.library.mach_port_deallocate(task, self.host)
            self.host = None


def app_on_device(pid, device):
    """Inspect only the candidate App executable's path; never request argv or environment."""
    if sys.platform != "darwin":
        return None
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    path = buffer.value.decode("utf-8", errors="replace")
    return ("/Devices/" + device + "/") in path and Path(path).name == "immichSlides"


def process_categories(raw, device, *, identify_app=None, app_processes=None):
    identify_app = app_on_device if identify_app is None else identify_app
    if len(raw.encode()) > MAX_PROCESS_TABLE_BYTES:
        return dict.fromkeys(RESOURCE_CATEGORIES)
    rows = {}
    for line in raw.splitlines():
        parts = line.split(None, 3)
        if len(parts) != 4 or len(rows) >= MAX_PROCESS_ROWS:
            return dict.fromkeys(RESOURCE_CATEGORIES)
        try:
            pid, parent, cpu = int(parts[0]), int(parts[1]), float(parts[2])
        except ValueError:
            return dict.fromkeys(RESOURCE_CATEGORIES)
        if pid <= 0 or parent < 0 or finite(cpu, MAX_PROCESS_CPU_PERCENT) is None or pid in rows:
            return dict.fromkeys(RESOURCE_CATEGORIES)
        rows[pid] = (parent, cpu, parts[3].strip())
    totals = dict.fromkeys(RESOURCE_CATEGORIES, 0.0)
    unknown_app = False
    found_app = False
    for pid, (parent, cpu, name) in rows.items():
        category = "other"
        if name == "immichSlides":
            belongs = identify_app(pid, device)
            unknown_app |= belongs is None
            if belongs:
                found_app = True
                category = "app"
                if app_processes is not None:
                    app_processes.append((pid, cpu))
        elif name == "xcodebuild" or name.startswith(("xctest", "testmanagerd", "immichSlidesUIT")):
            category = "test_tools"
        if category == "other":
            seen, ancestor = set(), pid
            while ancestor in rows and ancestor not in seen:
                seen.add(ancestor)
                next_parent, _, ancestor_name = rows[ancestor]
                if ancestor_name == "launchd_sim":
                    category = "simulator_daemons"
                    break
                ancestor = next_parent
        totals[category] += cpu
    if not rows:
        return dict.fromkeys(RESOURCE_CATEGORIES)
    if unknown_app:
        # An inaccessible candidate cannot be counted as definitely absent or as another category.
        return dict.fromkeys(RESOURCE_CATEGORIES)
    if not found_app:
        totals["app"] = None
    return {key: finite(value, MAX_PROCESS_CPU_PERCENT) for key, value in totals.items()}


def resource_sample(host_cpu, device, timeout):
    idle = host_cpu.idle()
    try:
        load = finite(os.getloadavg()[0], MAX_LOAD_AVERAGE)
    except OSError:
        load = None
    categories = process_sample(device, timeout) if timeout is not None else dict.fromkeys(RESOURCE_CATEGORIES)
    return {"idle_percent": idle, "load_1m": load, "cpu_percent": categories}


def process_sample(device, timeout, *, app_processes=None):
    categories = dict.fromkeys(RESOURCE_CATEGORIES)
    if sys.platform == "darwin":
        try:
            completed = subprocess.run(["/bin/ps", "-A", "-o", "pid=,ppid=,%cpu=,ucomm="],
                capture_output=True, text=True, check=False, timeout=timeout)
            if completed.returncode == 0:
                categories = process_categories(completed.stdout, device, app_processes=app_processes)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return categories


class HostProbe:
    """Bound native host reads independently of the inherited process-snapshot pool."""

    def __init__(self, device):
        self.device = device
        self.host = None
        self.spent = 0.0
        self.unavailable = False
        self.done = None
        self.worker = None
        self.requests = queue.Queue(maxsize=1)
        self.request_count = 0

    def _run(self):
        try:
            while True:
                request = self.requests.get()
                if request is None or self.unavailable:
                    break
                done, values = request
                try:
                    if self.host is None:
                        self.host = HostCpu()
                        self.host.idle()
                    values.append(resource_sample(self.host, self.device, None))
                except (OSError, ValueError, TypeError, AttributeError):
                    pass
                finally:
                    done.set()
        finally:
            if self.host is not None:
                self.host.close()

    def sample(self):
        remaining = HOST_WALL_BUDGET_SECONDS - self.spent
        if self.unavailable or remaining <= 0:
            self.unavailable = True
            return None
        # A slow native read may finish between ticks; never overlap it with a new worker.
        if self.done is not None and not self.done.is_set():
            return None
        done, values = Event(), []
        self.done = done
        started = time.perf_counter()
        self.request_count += 1
        try:
            # Pay thread startup once; per-tick startup can exhaust the cap on a loaded host.
            if self.worker is None:
                worker = Thread(target=self._run, daemon=True)
                worker.start()
                self.worker = worker
            self.requests.put_nowait((done, values))
            finished = done.wait(max(0, min(HOST_SAMPLE_TIMEOUT_SECONDS, remaining)
                                        - (time.perf_counter() - started)))
        except (OSError, RuntimeError, queue.Full):
            finished = False
            if self.worker is None:
                done.set()
        self.spent += time.perf_counter() - started
        self.unavailable = finished and not values
        return values[0] if finished and values else None

    def close(self):
        self.unavailable = True
        # Wake an idle worker; an in-flight read observes shutdown before taking more work.
        try:
            self.requests.put_nowait(None)
        except queue.Full:
            # Replace queued work with shutdown so a late worker cannot block on get().
            try:
                pending = self.requests.get_nowait()
                if pending is not None:
                    pending[0].set()
            except queue.Empty:
                pass
            try:
                self.requests.put_nowait(None)
            except queue.Full:
                pass


class CaseSampler:
    """Share a bounded sampling allowance across cases, independently of test waits."""

    def __init__(self, recorder, device, *, duration_limit_seconds=DEFAULT_DURATION_LIMIT_SECONDS,
                 force_app_hang_capture=False, app_hang_case_state=None):
        self.recorder = recorder
        self.device = device
        self.sequence = recorder.next_sequence() if recorder is not None else 0
        self.origin = time.monotonic()
        self.epoch = time.time()
        self.duration = 0.0
        self.samples = []
        self.spent = 0.0
        self.host_spent = 0.0
        self.previous_process_spent = 0.0
        self.truncated = False
        self.first_failure = None
        self.stopped = threading.Event()
        self.thread = None
        self.reserved = 0.0
        self.finished = False
        self.closed = False
        self.clock_stable = False
        self.duration_limit = min(MAX_DIAGNOSTIC_SECONDS, duration_limit_seconds)
        hosted = os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
        # Local opt-in is ignored in any CI environment, including a hosted metadata mismatch.
        forced = force_app_hang_capture and not any(os.environ.get(key) for key in ("CI", "GITHUB_ACTIONS", "RUNNER_ENVIRONMENT"))
        self.hang = AppHangCapture(recorder, self.stopped, forced=forced,
            case_state=app_hang_case_state, device=device) if recorder is not None and (hosted or forced) else None

    def start(self):
        if self.recorder is None or len(self.recorder.case_resources) >= MAX_RESOURCE_CASES:
            self.truncated = True
            return self
        # Hosting is metadata, independent of the exhausted diagnostic collection allowances.
        try:
            self.recorder.retain({"scope": "xcode", "phase": "test-execution", "state": "started",
                "sequence": self.sequence, "elapsed_seconds": 0, "cpu_seconds": None,
                "input_sha256": None, "official_exports": None,
                "sample": {"runner_hosted": {"github-hosted": True, "self-hosted": False}.get(
                    os.environ.get("RUNNER_ENVIRONMENT")), "cpu_percent": None, "memory_free_bytes": None,
                    "load_average": None, "image_version": None, "processes": []}})
        except (OSError, RuntimeError, TypeError, ValueError):
            pass
        # Older ledgers lack process-only accounting; retain their conservative combined charge.
        self.previous_process_spent = self.recorder.process_sampler_wall_seconds
        if self.previous_process_spent is None:
            self.previous_process_spent = sum(case["sampler_wall_seconds"] if case["sampler_wall_seconds"] is not None
                else SAMPLER_WALL_BUDGET_SECONDS for case in self.recorder.case_resources)
        self.reserved = max(0, SAMPLER_WALL_BUDGET_SECONDS - self.previous_process_spent)
        if "xcode" in self.recorder.unavailable:
            self.reserved = 0.0
        if self.reserved <= SAMPLE_COMMAND_TIMEOUT_SECONDS:
            self.truncated = True
            self.reserved = 0.0
        try:
            self.thread = threading.Thread(target=self._run, daemon=True)
            self.thread.start()
        except (OSError, RuntimeError):
            self.truncated = True
            self.thread = None
        return self

    def _run(self):
        host = None
        try:
            host = HostProbe(self.device)
            if host.sample() is None:
                self.truncated = True
            next_tick = time.monotonic() + SAMPLE_INTERVAL_SECONDS
            next_process = next_tick
            while not self.stopped.wait(max(0, next_tick - time.monotonic())):
                sample = host.sample()
                elapsed = time.monotonic() - self.origin
                if sample is None:
                    self.truncated = True
                    interval = self._host_interval(host, elapsed)
                    if interval is None:
                        break
                    next_tick = time.monotonic() + interval
                    continue
                sample = dict(sample)
                sample["cpu_percent"] = dict.fromkeys(RESOURCE_CATEGORIES)
                if not self.stopped.is_set() and time.monotonic() >= next_process:
                    remaining = self.reserved - self.spent - (self.hang.charge if self.hang is not None else 0)
                    if remaining > SAMPLE_COMMAND_TIMEOUT_SECONDS:
                        started = time.perf_counter()
                        if self.hang is None:
                            sample["cpu_percent"] = process_sample(self.device, min(SAMPLE_COMMAND_TIMEOUT_SECONDS, remaining))
                        else:
                            processes = []
                            sample["cpu_percent"] = process_sample(self.device, min(SAMPLE_COMMAND_TIMEOUT_SECONDS, remaining),
                                app_processes=processes)
                        self.spent += time.perf_counter() - started
                        self.truncated |= any(value is None for key, value in sample["cpu_percent"].items() if key != "app")
                        if self.hang is not None:
                            pid, cpu = processes[0] if len(processes) == 1 and sample["cpu_percent"]["app"] is not None else (None, None)
                            self.hang.observe(pid, cpu, time.monotonic() - self.origin,
                                remaining_seconds=self.reserved - self.spent)
                    else:
                        self.truncated = True
                    fast = (self.hang is not None and self.hang.can_capture(self.reserved - self.spent)
                        and self.hang.previous is not None and sample["cpu_percent"]["app"] is not None
                        and sample["cpu_percent"]["app"] >= APP_HANG_CPU_PERCENT)
                    process_interval = SAMPLE_INTERVAL_SECONDS if fast else PROCESS_SAMPLE_INTERVAL_SECONDS
                    next_process += process_interval
                    if next_process <= time.monotonic():
                        next_process = time.monotonic() + process_interval
                # The App is legitimately absent before launch, across relaunches and after exit; only a
                # missing host or non-App category means the sample itself was limited.
                self.truncated |= sample["idle_percent"] is None or sample["load_1m"] is None
                if self.stopped.is_set():
                    break
                if elapsed > MAX_DIAGNOSTIC_SECONDS:
                    self.truncated = True
                    break
                self.samples.append({"elapsed_seconds": elapsed, **sample})
                if len(self.samples) > MAX_RESOURCE_SAMPLES:
                    self.truncated = True
                    del self.samples[0]
                interval = self._host_interval(host, elapsed)
                if interval is None:
                    break
                next_tick += interval
                # Skip missed deadlines instead of issuing a burst after host descheduling.
                if next_tick <= time.monotonic():
                    next_tick = time.monotonic() + interval
        except (OSError, ValueError, TypeError, AttributeError):
            self.truncated = True
        finally:
            if host is not None:
                host.close()
                self.host_spent = host.spent
            self.finished = True

    def _host_interval(self, host, elapsed):
        remaining = HOST_WALL_BUDGET_SECONDS - host.spent - HOST_SAMPLE_TIMEOUT_SECONDS
        if remaining <= 0:
            self.truncated = True
            return None
        average_cost = host.spent / host.request_count if host.request_count else 0
        needed = max(0, self.duration_limit - elapsed) * average_cost / remaining
        # Prefer recent evidence to stretching gaps across the entire timeout horizon.
        interval = min(MAX_HOST_SAMPLE_INTERVAL_SECONDS,
            SAMPLE_INTERVAL_SECONDS * max(1, math.ceil(needed / SAMPLE_INTERVAL_SECONDS)))
        self.truncated |= interval > SAMPLE_INTERVAL_SECONDS
        return interval

    def stop(self):
        if self.closed:
            return
        self.closed = True
        elapsed = time.monotonic() - self.origin
        self.clock_stable = abs((time.time() - self.epoch) - elapsed) <= CLOCK_DRIFT_TOLERANCE_SECONDS
        self.duration = min(MAX_DIAGNOSTIC_SECONDS, max(0, elapsed))
        self.stopped.set()
        stop_deadline = time.monotonic() + STOP_TIMEOUT_SECONDS if self.hang is not None else None
        if self.thread is not None:
            self.thread.join(STOP_TIMEOUT_SECONDS)
        if self.hang is not None:
            if self.hang.worker is not None:
                self.hang.worker.join(max(0, stop_deadline - time.monotonic()))
            self.spent += self.hang.cost
        if self.recorder is not None:
            if self.thread is not None and not self.finished:
                self.truncated = True
            self.recorder.process_sampler_wall_seconds = self.previous_process_spent + self.spent if self.finished else None
            self.publish()

    def bind_failure(self, epoch):
        elapsed = finite(epoch - self.epoch, self.duration) if self.clock_stable and type(epoch) in (int, float) else None
        if elapsed is not None and (self.first_failure is None or elapsed < self.first_failure):
            self.first_failure = elapsed
        self.publish()

    def publish(self):
        if self.recorder is None:
            return
        samples = list(self.samples)
        def values(field):
            return [sample[field] for sample in samples if sample[field] is not None]
        idle, load = values("idle_percent"), values("load_1m")
        app = [sample["cpu_percent"]["app"] for sample in samples if sample["cpu_percent"]["app"] is not None]
        near = [sample for sample in samples if self.first_failure is not None
                and sample["elapsed_seconds"] <= self.duration and abs(sample["elapsed_seconds"] - self.first_failure) <= 5]
        case = {"sequence": self.sequence, "duration_seconds": self.duration, "sample_interval_seconds": SAMPLE_INTERVAL_SECONDS,
            "sample_count": len(samples), "truncated": self.truncated, "idle_percent_min": min(idle) if idle else None,
            "idle_percent_median": statistics.median(idle) if idle else None, "load_1m_max": max(load) if load else None,
            "app_cpu_percent_peak": max(app) if app else None, "sampler_wall_seconds": self.spent + self.host_spent if self.finished else None,
            "sampler_cpu_seconds": None, "first_failure_elapsed_seconds": self.first_failure, "failure_samples": near[:6]}
        if self.hang is not None and self.hang.result is not None:
            try:
                validate_app_hang_stack(self.hang.result)
                case["app_hang_stack"] = self.hang.result
            except (ValueError, TypeError, KeyError):
                pass  # A stack projection must never discard numeric failure-window evidence.
        try:
            validate_case_resources([case])
        except (ValueError, TypeError, KeyError):
            self.recorder.truncate("collection-timeout")
            return
        for index, previous in enumerate(self.recorder.case_resources):
            if previous["sequence"] == self.sequence:
                self.recorder.case_resources[index] = case
                return
        if len(self.recorder.case_resources) < MAX_RESOURCE_CASES:
            self.recorder.case_resources.append(case)
        else:
            self.recorder.truncate("event-cap")


def legacy_value(node, field):
    if not isinstance(node, dict):
        return None
    value = node.get(field)
    return value.get("_value") if isinstance(value, dict) else None


def legacy_rows(node, field):
    if not isinstance(node, dict):
        return []
    value = node.get(field)
    rows = value.get("_values", []) if isinstance(value, dict) else []
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def native_time(node, field):
    value = legacy_value(node, field)
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?"
                         r"(?:Z|[+-][0-9]{2}:?(?P<offset_minutes>[0-9]{2}))", value)
    if match is None or (match["offset_minutes"] is not None and int(match["offset_minutes"]) >= 60):
        return None
    try:
        value = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", value)
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        parsed = datetime.fromisoformat(value)
        return parsed.timestamp() if parsed.tzinfo is not None and parsed.utcoffset() is not None else None
    except (ValueError, OverflowError):
        return None


def native_first_failure(summary):
    """Use the earliest recorded failure only when its timestamp identifies one failure."""
    failures = [(native_time(row, "timestamp"), legacy_value(row, "uuid"))
                for row in legacy_rows(summary, "failureSummaries")]
    if not failures or any(at is None for at, _ in failures):
        return None, None
    earliest = min(at for at, _ in failures)
    matches = [row for row in failures if row[0] == earliest]
    return matches[0] if len(matches) == 1 else (None, None)


def native_breakdown(summary, receipt):
    """Match native bounds, refusing ambiguity rather than estimating durations."""
    empty = dict.fromkeys(NATIVE_ACTIVITY_FIELDS)
    failed_at, failure_id = native_first_failure(summary)
    if failed_at is None:
        return empty, None
    flattened = []
    def visit(nodes, ancestors=()):
        for node in nodes:
            flattened.append((node, ancestors))
            visit(legacy_rows(node, "subactivities"), (*ancestors, node))
    visit(legacy_rows(summary, "activitySummaries"))
    def bounds(node):
        start, end = native_time(node, "start"), native_time(node, "finish")
        if start is None or end is None or not 0 <= end - start <= MAX_DIAGNOSTIC_SECONDS:
            return None
        return start, end
    action = None
    ambiguous_action = False
    duration = receipt["timing"]["action_duration_seconds"]
    if receipt["step"] == "select" and receipt["action"] == "tap" and duration is not None:
        candidates = [(node, bounds(node)) for node, _ in flattened
                      if str(legacy_value(node, "title") or "").startswith("Tap ")]
        candidates = [(node, interval) for node, interval in candidates if interval is not None
                      and interval[1] <= failed_at and abs(interval[1] - interval[0] - duration) <= NATIVE_MATCH_TOLERANCE_SECONDS]
        ambiguous_action = len(candidates) > 1
        # The current tap is the latest preceding tap, and its duration must uniquely bind it.
        latest = max((bounds(node)[1] for node, _ in flattened if bounds(node) is not None
                      and str(legacy_value(node, "title") or "").startswith("Tap ") and bounds(node)[1] <= failed_at), default=None)
        if len(candidates) == 1 and candidates[0][1][1] == latest:
            action = candidates[0][0]
    if action is None:
        # A query failure is usable only when XCTest binds the failure to that native activity.
        associated = [node for node, _ in flattened if failure_id is not None
                      and any(row.get("_value") == failure_id for row in legacy_rows(node, "failureSummaryIDs"))]
        if len(associated) == 1:
            action = associated[0]
        elif len(associated) > 1:
            ambiguous_action = True
    if action is None or bounds(action) is None:
        return empty, None if ambiguous_action else failed_at
    descendants = []
    def gather(node):
        for child in legacy_rows(node, "subactivities"):
            descendants.append(child)
            gather(child)
    gather(action)
    if str(legacy_value(action, "title") or "").startswith("Find the Target Application"):
        descendants.insert(0, action)
    action_start, action_end = bounds(action)
    for node, _ in flattened:
        interval = bounds(node)
        if interval is not None and str(legacy_value(node, "title") or "").startswith("Find the Target Application"):
            start, end = interval
            if end <= failed_at and (0 <= action_start - end <= NATIVE_MATCH_TOLERANCE_SECONDS
                                    or 0 <= start - action_end <= NATIVE_MATCH_TOLERANCE_SECONDS):
                descendants.append(node)
    syntheses = [bounds(node) for node in descendants if legacy_value(node, "title") == "Synthesize event" and bounds(node) is not None]
    if len(syntheses) > 1:
        return empty, None
    synthesis = syntheses[0] if syntheses else None
    intervals = {key: [] for key in NATIVE_ACTIVITY_FIELDS}
    for node in descendants:
        interval = bounds(node)
        title = legacy_value(node, "title")
        if interval is None or not isinstance(title, str):
            continue
        start, end = interval
        if title == "Synthesize event":
            intervals["synthesize_event"].append(interval)
        elif title.startswith("Find the Window"):
            intervals["find_window"].append(interval)
        elif title.startswith("Find the Target Application"):
            intervals["ax_root_acquisition"].append(interval)
        elif title == "Wait for com.331works.immichSlides to idle" and synthesis is not None:
            if end <= synthesis[0]:
                intervals["pre_event_idle"].append(interval)
            elif start >= synthesis[1]:
                intervals["post_event_idle"].append(interval)
    # Union intervals within each category, so nested native activities count once.
    for key, values in intervals.items():
        if not values:
            continue
        total, low, high = 0.0, None, None
        for start, end in sorted(values):
            if high is None or start > high:
                if high is not None:
                    total += high - low
                low, high = start, end
            else:
                high = max(high, end)
        empty[key] = round(total + high - low, 6)
    return empty, failed_at


def collect_native_activity(bundle, root, failed_nodes, sampler, *, recorder, timeout):
    """Inspect retained private xcresult objects; publish only checked numeric projections."""
    if sampler is None or recorder is None or not failed_nodes:
        return
    budget = getattr(recorder, "native_activity_budget", None)
    if budget is None:
        budget = recorder.native_activity_budget = NativeActivityBudget(NATIVE_CASE_BUDGET_SECONDS)
    def read(reference, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return {}
        result = subprocess.run(["xcrun", "xcresulttool", "get", "object", "--legacy", "--path", str(bundle),
            "--id", reference, "--format", "json"], capture_output=True, check=True, timeout=remaining)
        if len(result.stdout) > 16 * 1024 * 1024:
            return {}
        return json.loads(result.stdout)
    def operation(limit):
        deadline = time.monotonic() + limit
        references = []
        for action in legacy_rows(root, "actions"):
            action_result = action.get("actionResult", {})
            tests = action_result.get("testsRef", {}) if isinstance(action_result, dict) else {}
            reference = legacy_value(tests, "id") if isinstance(tests, dict) else None
            if isinstance(reference, str):
                references.append(reference)
        if len(references) != 1:
            return []
        tests = read(references[0], deadline)
        metadata = []
        def find(node):
            if isinstance(node, dict):
                if "summaryRef" in node and isinstance(legacy_value(node, "identifier"), str):
                    metadata.append(node)
                for value in node.values():
                    find(value)
            elif isinstance(node, list):
                for value in node:
                    find(value)
        find(tests)
        projected = []
        for node in failed_nodes:
            receipt = public_first_failure(node.get("first_failure"))
            key = str(node.get("nodeIdentifier", "")).removesuffix("()")
            matched = [item for item in metadata if str(legacy_value(item, "identifier")).removesuffix("()") == key]
            if not matched and len(metadata) == 1:
                matched = [item for item in metadata if str(legacy_value(item, "identifier")).removesuffix("()") == key.rsplit("/", 1)[-1]]
            if len(matched) != 1:
                continue
            reference = legacy_value(matched[0].get("summaryRef", {}), "id")
            if not isinstance(reference, str):
                continue
            summary = read(reference, deadline)
            if receipt is None or receipt["source"] != "xctest":
                failed_at, _ = native_first_failure(summary)
                projected.append((node, None, failed_at))
            else:
                numeric, failed_at = native_breakdown(summary, receipt)
                enriched = {**receipt, "native_activity_seconds": numeric}
                if public_first_failure(enriched) is not None:
                    projected.append((node, enriched, failed_at))
        return projected
    projected = budget.collect(sampler.sequence, operation, cap=min(timeout, NATIVE_CASE_BUDGET_SECONDS))
    for node, receipt, failed_at in projected or []:
        if receipt is not None:
            node["first_failure"] = receipt
        if failed_at is not None:
            sampler.bind_failure(failed_at)
