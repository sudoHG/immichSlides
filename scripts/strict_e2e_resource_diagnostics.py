"""Bounded numeric-only strict E2E contention measurements; never a test verdict."""

from __future__ import annotations

import ctypes
import json
import os
import statistics
import subprocess
import sys
import threading
import time
from datetime import datetime

from ci_bounded_diagnostics import (COLLECTION_BUDGET_SECONDS, MAX_DIAGNOSTIC_SECONDS,
    MAX_LOAD_AVERAGE, MAX_PROCESS_CPU_PERCENT, MAX_RESOURCE_CASES, MAX_RESOURCE_SAMPLES,
    RESOURCE_CATEGORIES, validate_case_resources)
from ci_execution_diagnostics import BOOKKEEPING_RESERVE_SECONDS, finite
from ci_failure_diagnostics import NATIVE_ACTIVITY_FIELDS, public_first_failure

SAMPLE_INTERVAL_SECONDS = 2
SAMPLER_WALL_BUDGET_SECONDS = 180
SAMPLE_COMMAND_TIMEOUT_SECONDS = 0.15
STOP_TIMEOUT_SECONDS = 0.2
MAX_PROCESS_TABLE_BYTES = 2 * 1024 * 1024
MAX_PROCESS_ROWS = 65536
NATIVE_MATCH_TOLERANCE_SECONDS = 0.1


class HostCpu:
    """Read actual interval idle ticks; process CPU is ps's short-term estimate."""

    def __init__(self):
        self.library = None
        self.host = None
        self.previous = None
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
            return None
        previous, self.previous = self.previous, tuple(ticks)
        if previous is None:
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
    return ("/Devices/" + device + "/") in buffer.value.decode("utf-8", errors="replace")


def process_categories(raw, device, *, identify_app=None):
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
    for pid, (parent, cpu, name) in rows.items():
        category = "other"
        if name == "immichSlides":
            belongs = identify_app(pid, device)
            unknown_app |= belongs is None
            if belongs:
                category = "app"
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
    return {key: finite(value, MAX_PROCESS_CPU_PERCENT) for key, value in totals.items()}


def resource_sample(host_cpu, device, timeout):
    idle = host_cpu.idle()
    try:
        load = finite(os.getloadavg()[0], MAX_LOAD_AVERAGE)
    except OSError:
        load = None
    categories = dict.fromkeys(RESOURCE_CATEGORIES)
    if sys.platform == "darwin":
        try:
            completed = subprocess.run(["/bin/ps", "-A", "-o", "pid=,ppid=,%cpu=,ucomm="],
                capture_output=True, text=True, check=False, timeout=timeout)
            if completed.returncode == 0:
                categories = process_categories(completed.stdout, device)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return {"idle_percent": idle, "load_1m": load, "cpu_percent": categories}


class CaseSampler:
    """Share a bounded sampling allowance across cases, independently of test waits."""

    def __init__(self, recorder, device):
        self.recorder = recorder
        self.device = device
        self.sequence = recorder.next_sequence() if recorder is not None else 0
        self.origin = time.monotonic()
        self.epoch = time.time()
        self.duration = 0.0
        self.samples = []
        self.spent = 0.0
        self.truncated = False
        self.first_failure = None
        self.stopped = threading.Event()
        self.thread = None
        self.reserved = 0.0
        self.finished = False
        self.closed = False

    def start(self):
        if (self.recorder is None or "xcode" in self.recorder.unavailable
                or len(self.recorder.case_resources) >= MAX_RESOURCE_CASES):
            self.truncated = True
            return self
        # Persisted numeric costs carry this allowance across serial case processes.
        spent = sum(case["sampler_wall_seconds"] if case["sampler_wall_seconds"] is not None
                    else SAMPLER_WALL_BUDGET_SECONDS for case in self.recorder.case_resources)
        self.reserved = max(0, SAMPLER_WALL_BUDGET_SECONDS - spent)
        if self.reserved <= SAMPLE_COMMAND_TIMEOUT_SECONDS:
            self.truncated = True
            return self
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
            started = time.perf_counter()
            host = HostCpu()
            host.idle()
            self.spent += time.perf_counter() - started
            while not self.stopped.wait(SAMPLE_INTERVAL_SECONDS):
                remaining = self.reserved - self.spent
                if len(self.samples) >= MAX_RESOURCE_SAMPLES or remaining <= SAMPLE_COMMAND_TIMEOUT_SECONDS:
                    self.truncated = True
                    break
                started = time.perf_counter()
                sample = resource_sample(host, self.device, min(SAMPLE_COMMAND_TIMEOUT_SECONDS, remaining))
                elapsed = time.monotonic() - self.origin
                self.spent += time.perf_counter() - started
                self.truncated |= (sample["idle_percent"] is None or sample["load_1m"] is None
                                   or any(value is None for value in sample["cpu_percent"].values()))
                if self.stopped.is_set():
                    break
                if elapsed > MAX_DIAGNOSTIC_SECONDS:
                    self.truncated = True
                    break
                self.samples.append({"elapsed_seconds": elapsed, **sample})
        except (OSError, ValueError, TypeError, AttributeError):
            self.truncated = True
        finally:
            if host is not None:
                host.close()
            self.finished = True

    def stop(self):
        if self.closed:
            return
        self.closed = True
        self.duration = min(MAX_DIAGNOSTIC_SECONDS, max(0, time.monotonic() - self.origin))
        self.stopped.set()
        if self.thread is not None:
            self.thread.join(STOP_TIMEOUT_SECONDS)
        if self.recorder is not None:
            if self.thread is not None and not self.finished:
                self.truncated = True
            self.publish()

    def bind_failure(self, epoch):
        elapsed = finite(epoch - self.epoch, self.duration) if type(epoch) in (int, float) else None
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
            "app_cpu_percent_peak": max(app) if app else None, "sampler_wall_seconds": self.spent if self.finished else None,
            "sampler_cpu_seconds": None, "first_failure_elapsed_seconds": self.first_failure, "failure_samples": near[:6]}
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
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, OverflowError):
        return None


def native_breakdown(summary, receipt):
    """Match native bounds, refusing ambiguity rather than estimating durations."""
    empty = dict.fromkeys(NATIVE_ACTIVITY_FIELDS)
    failures = [(native_time(row, "timestamp"), legacy_value(row, "uuid"))
                for row in legacy_rows(summary, "failureSummaries")]
    failures = [(at, identifier) for at, identifier in failures if at is not None]
    if not failures:
        return empty, None
    failed_at, failure_id = min(failures, key=lambda row: row[0])
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
    duration = receipt["timing"]["action_duration_seconds"]
    if receipt["step"] == "select" and receipt["action"] == "tap" and duration is not None:
        candidates = [(node, bounds(node)) for node, _ in flattened
                      if str(legacy_value(node, "title") or "").startswith("Tap ")]
        candidates = [(node, interval) for node, interval in candidates if interval is not None
                      and interval[1] <= failed_at and abs(interval[1] - interval[0] - duration) <= NATIVE_MATCH_TOLERANCE_SECONDS]
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
    if action is None or bounds(action) is None:
        return empty, failed_at
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
        return empty, failed_at
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
    timeout = min(timeout, COLLECTION_BUDGET_SECONDS["xcode"] - recorder.charged["xcode"] - BOOKKEEPING_RESERVE_SECONDS)
    if timeout <= 0:
        recorder.truncate("collection-budget-exhausted")
        return
    def read(reference, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return {}
        result = subprocess.run(["xcrun", "xcresulttool", "get", "object", "--legacy", "--path", str(bundle),
            "--id", reference, "--format", "json"], capture_output=True, check=True, timeout=remaining)
        if len(result.stdout) > 16 * 1024 * 1024:
            return {}
        return json.loads(result.stdout)
    def operation():
        deadline = time.monotonic() + timeout
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
                dates = [native_time(row, "timestamp") for row in legacy_rows(summary, "failureSummaries")]
                dates = [value for value in dates if value is not None]
                projected.append((node, None, min(dates) if dates else None))
            else:
                numeric, failed_at = native_breakdown(summary, receipt)
                enriched = {**receipt, "native_activity_seconds": numeric}
                if public_first_failure(enriched) is not None:
                    projected.append((node, enriched, failed_at))
        return projected
    projected = recorder.collect("xcode", operation, cap=timeout)
    for node, receipt, failed_at in projected or []:
        if receipt is not None:
            node["first_failure"] = receipt
        sampler.bind_failure(failed_at)
