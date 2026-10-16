"""Best-effort producers for the public bounded-diagnostics contract.

Only diagnostic work runs in capped daemon workers. Product deadlines and cleanup
remain owned by the runners. A shared receipt carries spent budgets across cases.
"""

from __future__ import annotations

import contextvars
import copy
import functools
import json
import math
import os
import re
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path

from ci_bounded_diagnostics import (COLLECTION_BUDGET_SECONDS, MAX_DIAGNOSTIC_SECONDS, MAX_EVENTS,
    MAX_CPU_SECONDS, MAX_MEMORY_BYTES, MAX_PROCESS_CPU_PERCENT, MAX_LOAD_AVERAGE, MAX_CPU_PERCENT,
    MAX_PROCESSES, MAX_PROCESS_COUNT, PROCESS_NAMES, validate_receipt)
from ci_summary import BOUNDED_DIAGNOSTICS_FIELD

SAMPLE_CAP_SECONDS = 0.25
IO_CAP_SECONDS = 0.1
FIXTURE_READ_CAP_SECONDS = 0.25
FIXTURE_DRAIN_CAP_SECONDS = 0.01
FIXTURE_PREFIX = "fixture-diagnostic: "
MAX_RECEIPT_BYTES = 512 * 1024
BOOKKEEPING_RESERVE_SECONDS = 0.01
LEDGER_ALLOWANCE_SECONDS = 1.5
LEDGER_IO_CAP_SECONDS = 0.02
ANOMALY_SAMPLE_RESERVE_SECONDS = 0.5
SYSTEM_COMMAND_CAP_SECONDS = 0.08
FIXTURE_EMISSION_CAP_SECONDS = 0.2
FIXTURE_HARVEST_RESERVE_SECONDS = 0.3
FIXTURE_MIN_ALLOWANCE_SECONDS = 0.04
MAX_PROGRESS_BYTES = 64 * 1024
EXECUTABLE_NAMES = {name: name for name in PROCESS_NAMES} | {
    "com.apple.CoreSimulator.CoreSimulatorService": "CoreSimulatorService"}
_ACTIVE = contextvars.ContextVar("execution_diagnostics", default=None)


def finite(value, ceiling, *, integral=False, default=None):
    if type(value) not in ((int,) if integral else (int, float)):
        return default
    return value if math.isfinite(value) and 0 <= value <= ceiling else default


def system_sample():
    """Read fixed ps columns; discard paths and every non-allowlisted process."""
    groups, total_cpu = {}, 0.0
    completed = subprocess.run(["/bin/ps", "-A", "-o", "%cpu=,rss=,stat=,comm="],
                               capture_output=True, text=True, timeout=SYSTEM_COMMAND_CAP_SECONDS, check=False)
    for line in completed.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) != 4:
            continue
        cpu, rss, raw_state, executable = parts
        try:
            total_cpu += float(cpu)
        except ValueError:
            continue
        name = EXECUTABLE_NAMES.get(executable.rsplit("/", 1)[-1])
        if name is None:
            continue
        state = {"R": "running", "S": "sleeping", "I": "sleeping", "U": "uninterruptible",
                 "D": "uninterruptible", "T": "stopped", "Z": "zombie"}.get(raw_state[:1], "unknown")
        try:
            row = groups.setdefault((name, state), [0, 0.0, 0])
            row[0] += 1
            row[1] += float(cpu)
            row[2] += int(rss) * 1024
        except ValueError:
            continue
    processes = [{"name": name, "state": state, "count": min(values[0], MAX_PROCESS_COUNT),
                  "cpu_percent": finite(values[1], MAX_PROCESS_CPU_PERCENT), "rss_bytes": finite(values[2], MAX_MEMORY_BYTES, integral=True)}
                 for (name, state), values in sorted(groups.items())][:MAX_PROCESSES]
    memory = None
    try:
        stats = subprocess.run(["/usr/bin/vm_stat"], capture_output=True, text=True, timeout=SYSTEM_COMMAND_CAP_SECONDS, check=False).stdout
        page = re.search(r"page size of (\d+) bytes", stats)
        free = re.search(r"Pages free:\s+(\d+)", stats)
        if page and free:
            memory = finite(int(page[1]) * int(free[1]), MAX_MEMORY_BYTES, integral=True)
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    try:
        load = [finite(value, MAX_LOAD_AVERAGE) for value in os.getloadavg()]
        if any(value is None for value in load):
            load = None
    except OSError:
        load = None
    image = os.environ.get("ImageVersion", "")
    version = [int(value) for value in image.split(".")] if re.fullmatch(r"\d{1,9}\.\d{1,9}\.\d{1,9}", image) else None
    cpu_percent = finite(total_cpu / (os.cpu_count() or 1), MAX_CPU_PERCENT)
    return {"cpu_percent": cpu_percent, "memory_free_bytes": memory, "load_average": load,
            "runner_hosted": {"github-hosted": True, "self-hosted": False}.get(os.environ.get("RUNNER_ENVIRONMENT")),
            "image_version": version, "processes": processes}


class Recorder:
    def __init__(self):
        self.cost = {scope: 0.0 for scope in COLLECTION_BUDGET_SECONDS}
        self.charged = dict(self.cost)
        # One prepaid IO pool survives exhausted sampling scopes; each ledger
        # operation spends at most 20 ms of it, including crashed writers.
        self.charged["preparation"] = LEDGER_ALLOWANCE_SECONDS
        self.ledger_remaining = LEDGER_ALLOWANCE_SECONDS
        self.unavailable = set()
        self.events = []
        self.truncated = False
        self.sequence = 0
        self.xcode_timed_out = False

    def collect(self, scope, operation, *, cap):
        remaining = COLLECTION_BUDGET_SECONDS[scope] - self.charged[scope]
        # Leave room for bookkeeping and do not start work after a scope is spent.
        limit = min(cap, remaining - BOOKKEEPING_RESERVE_SECONDS)
        if limit <= 0:
            self.truncated = True
            return None
        started = time.perf_counter()
        done, values = threading.Event(), []
        def work():
            try:
                values.append(operation())
            except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
                pass
            finally:
                done.set()
        try:
            threading.Thread(target=work, daemon=True).start()
            finished = done.wait(max(0, limit - (time.perf_counter() - started)))
        except (OSError, RuntimeError):
            finished = False
        elapsed = time.perf_counter() - started
        self.cost[scope] += elapsed
        self.charged[scope] += elapsed
        if not finished:
            self.truncated = True
        return values[0] if finished and values else None

    def event(self, scope, phase, state, sequence, *, elapsed=0, cpu=None, sample=None, digest=None, exports=None):
        started = time.perf_counter()
        if self.charged[scope] >= COLLECTION_BUDGET_SECONDS[scope] - BOOKKEEPING_RESERVE_SECONDS:
            self.truncated = True
            return
        event = {"scope": scope, "phase": phase, "state": state, "sequence": sequence,
                            "elapsed_seconds": finite(elapsed, MAX_DIAGNOSTIC_SECONDS, default=0),
                            "cpu_seconds": finite(cpu, MAX_CPU_SECONDS), "sample": sample,
                            "input_sha256": digest, "official_exports": exports}
        self.retain(event)
        elapsed = time.perf_counter() - started
        self.cost[scope] += elapsed
        self.charged[scope] += elapsed
        return event

    @staticmethod
    def is_anomaly(event):
        return event["state"] not in ("started", "completed") or event["sample"] is not None or event["phase"] == "official-export"

    def retain(self, event):
        if len(self.events) >= MAX_EVENTS:
            self.truncated = True
            oldest_success = next((index for index, previous in enumerate(self.events) if not self.is_anomaly(previous)), None)
            if oldest_success is None and not self.is_anomaly(event):
                return
            self.events.pop(oldest_success if oldest_success is not None else 0)
        self.events.append(event)

    def next_sequence(self):
        self.sequence += 1
        return self.sequence

    def sample(self, scope, *, initial=False):
        cap = SAMPLE_CAP_SECONDS
        if initial:
            cap = min(cap, COLLECTION_BUDGET_SECONDS[scope] - self.charged[scope]
                      - ANOMALY_SAMPLE_RESERVE_SECONDS - BOOKKEEPING_RESERVE_SECONDS)
        return self.collect(scope, system_sample, cap=cap)

    def ledger_io(self, operation):
        limit = min(LEDGER_IO_CAP_SECONDS, self.ledger_remaining)
        if limit <= 0:
            self.truncated = True
            return None
        self.ledger_remaining -= limit
        started = time.perf_counter()
        done, values = threading.Event(), []
        def work():
            try:
                values.append(operation())
            except (OSError, ValueError, TypeError, KeyError):
                pass
            finally:
                done.set()
        try:
            threading.Thread(target=work, daemon=True).start()
            finished = done.wait(max(0, limit - (time.perf_counter() - started)))
        except (OSError, RuntimeError):
            finished = False
        self.cost["preparation"] += time.perf_counter() - started
        if not finished:
            self.truncated = True
        return values[0] if finished and values else None

    def receipt(self):
        receipt = {"schema_version": 1, "collection_seconds": {
            scope: None if scope in self.unavailable else finite(value, MAX_DIAGNOSTIC_SECONDS)
            for scope, value in self.cost.items()},
            "truncated": self.truncated, "events": copy.deepcopy(self.events)}
        try:
            validate_receipt(receipt)
            return receipt
        except (ValueError, TypeError, KeyError):
            return None

    def attach(self, summary):
        summary.pop(BOUNDED_DIAGNOSTICS_FIELD, None)
        receipt = self.receipt()
        if receipt is not None and (receipt["events"] or receipt["truncated"]):
            summary[BOUNDED_DIAGNOSTICS_FIELD] = receipt

    def load(self, path):
        def read():
            with Path(path).open("rb") as stream:
                raw = stream.read(MAX_RECEIPT_BYTES + 1)
            if len(raw) > MAX_RECEIPT_BYTES:
                return None
            ledger = json.loads(raw)
            validate_receipt(ledger["receipt"])
            remaining = ledger["remaining_seconds"]
            if finite(ledger["ledger_remaining_seconds"], LEDGER_ALLOWANCE_SECONDS) is None:
                return None
            if set(remaining) != set(COLLECTION_BUDGET_SECONDS) or any(
                    finite(remaining[scope], budget) is None for scope, budget in COLLECTION_BUDGET_SECONDS.items()):
                return None
            return ledger
        previous_cost = self.cost["preparation"]
        previous_remaining = self.ledger_remaining
        ledger = self.ledger_io(read)
        io_charge = previous_remaining - self.ledger_remaining
        overhead = self.cost["preparation"] - previous_cost
        if ledger is None:
            # Missing accounting must not grant a child fresh per-job budgets.
            self.charged = dict(COLLECTION_BUDGET_SECONDS)
            self.ledger_remaining = 0
            self.unavailable = set(COLLECTION_BUDGET_SECONDS)
            self.truncated = True
            return
        receipt = ledger["receipt"]
        self.cost = {scope: value if value is not None else 0 for scope, value in receipt["collection_seconds"].items()}
        self.unavailable = {scope for scope, value in receipt["collection_seconds"].items() if value is None}
        self.cost["preparation"] += overhead
        self.charged = {scope: budget - ledger["remaining_seconds"][scope] for scope, budget in COLLECTION_BUDGET_SECONDS.items()}
        # The read consumed part of the inherited IO pool, not a fresh loan.
        self.ledger_remaining = min(self.ledger_remaining, max(0, ledger["ledger_remaining_seconds"] - io_charge))
        self.events, self.truncated = receipt["events"], receipt["truncated"]
        self.sequence = max((event["sequence"] for event in self.events), default=0)

    def save(self, path):
        receipt = self.receipt()
        if receipt is None:
            return
        self._write(path, {"receipt": self.receipt(), "remaining_seconds": {
            scope: max(0, budget - self.charged[scope]) for scope, budget in COLLECTION_BUDGET_SECONDS.items()}})

    def reserve(self, path):
        """Spend the loan durably before collecting; release unused time on exit."""
        receipt = self.receipt()
        if receipt is None:
            return
        receipt["collection_seconds"] = dict.fromkeys(COLLECTION_BUDGET_SECONDS, None)
        ledger = {"receipt": receipt, "remaining_seconds": dict.fromkeys(COLLECTION_BUDGET_SECONDS, 0)}
        if not self._write(path, ledger):
            self.charged = dict(COLLECTION_BUDGET_SECONDS)
            self.unavailable = set(COLLECTION_BUDGET_SECONDS)
            self.truncated = True

    def _write(self, path, receipt):
        cancelled = threading.Event()
        path = Path(path)
        temporary = path.with_name(path.name + "." + str(os.getpid()) + ".tmp")
        def write():
            try:
                receipt["ledger_remaining_seconds"] = self.ledger_remaining
                temporary.write_text(json.dumps(receipt, separators=(",", ":")) + "\n")
                if not cancelled.is_set():
                    temporary.replace(path)
                    return True
            finally:
                temporary.unlink(missing_ok=True)
        committed = self.ledger_io(write)
        cancelled.set()
        return committed is True

    def fixture_log(self, path):
        if path is None:
            return
        def read():
            # Health has already been decided. Let the async writer seal its
            # file within this collection's own cap, never the ready deadline.
            deadline = time.perf_counter() + FIXTURE_DRAIN_CAP_SECONDS
            for _ in range(3):
                try:
                    with path.open("rb") as stream:
                        raw = stream.read(MAX_RECEIPT_BYTES)
                except FileNotFoundError:
                    raw = b""
                text = raw.decode("utf-8", errors="replace")
                if "fixture-collection-completed: true\n" in text or time.perf_counter() >= deadline:
                    return text
                threading.Event().wait(min(0.005, max(0, deadline - time.perf_counter())))
            return text
        text = self.collect("fixture", read, cap=FIXTURE_READ_CAP_SECONDS)
        if text is None:
            self.truncated = True
            self.unavailable.add("fixture")
            return
        mapping = {}
        emission_seconds = None
        completed = False
        for line in text.splitlines():
            if self.charged["fixture"] >= COLLECTION_BUDGET_SECONDS["fixture"] - BOOKKEEPING_RESERVE_SECONDS:
                self.truncated = True
                break
            if line.startswith("fixture-collection-seconds: "):
                try:
                    emission_seconds = finite(float(line.removeprefix("fixture-collection-seconds: ")), FIXTURE_EMISSION_CAP_SECONDS)
                except ValueError:
                    pass
            if line == "fixture-collection-truncated: true":
                self.truncated = True
            if line == "fixture-collection-completed: true":
                completed = True
            if not line.startswith(FIXTURE_PREFIX):
                continue
            started = time.perf_counter()
            try:
                event = json.loads(line[len(FIXTURE_PREFIX):])
                validate_receipt({"schema_version": 1, "collection_seconds": dict.fromkeys(COLLECTION_BUDGET_SECONDS, 0),
                                  "truncated": False, "events": [event]})
                if event["scope"] != "fixture":
                    continue
                original = event["sequence"]
                if original not in mapping:
                    mapping[original] = self.next_sequence()
                event["sequence"] = mapping[original]
                self.retain(event)
            except (ValueError, TypeError, KeyError):
                continue
            finally:
                elapsed = time.perf_counter() - started
                self.cost["fixture"] += elapsed
                self.charged["fixture"] += elapsed
        if emission_seconds is None:
            self.unavailable.add("fixture")
        else:
            self.cost["fixture"] += emission_seconds
        self.truncated |= not completed

    def xcode_snapshot(self, state, started, sequence, log_path, bundles=()):
        def progress():
            with log_path.open("rb") as stream:
                stream.seek(0, 2)
                stream.seek(max(0, stream.tell() - MAX_PROGRESS_BYTES))
                lines = stream.read(MAX_PROGRESS_BYTES).decode("utf-8", errors="replace").splitlines()
            phase = "xcodebuild"
            for line in lines:
                if line.startswith(("SwiftCompile ", "CompileC ", "Ld ", "Build description signature:")):
                    phase = "build"
                elif line.startswith(("Testing started", "Test session results")):
                    phase = "test-launch"
                elif line.startswith(("Test Suite ", "Test Case ")):
                    phase = "test-execution"
            return phase
        phase = self.collect("xcode", progress, cap=IO_CAP_SECONDS) or "unknown"
        exports = self.collect("xcode", lambda: official_exports(log_path.parent, bundles), cap=IO_CAP_SECONDS)
        self.event("xcode", phase, state, sequence, elapsed=time.monotonic() - started,
                   sample=self.sample("xcode"), exports=exports)
        self.xcode_timed_out = True


def official_exports(directory, bundles=()):
    return {"bundle": any(path.is_dir() for path in bundles),
            "summary": any(path.is_file() for path in directory.glob("official-summary*.json")),
            "tests": any(path.is_file() for path in directory.glob("official-tests*.json"))}


def active():
    return _ACTIVE.get()


def fixture_environment(environment, path):
    """Reserve child emission time before spawn; repeated services share one budget."""
    environment = dict(environment)
    recorder = active()
    allowance = max(0, min(FIXTURE_EMISSION_CAP_SECONDS, COLLECTION_BUDGET_SECONDS["fixture"] - recorder.charged["fixture"] - FIXTURE_HARVEST_RESERVE_SECONDS)) if recorder else 0
    if allowance < FIXTURE_MIN_ALLOWANCE_SECONDS:
        allowance = 0
    if recorder:
        recorder.charged["fixture"] += allowance
        recorder.truncated |= allowance == 0
    environment["IMMICHSLIDES_FIXTURE_DIAGNOSTIC_SECONDS"] = str(allowance)
    environment["IMMICHSLIDES_FIXTURE_DIAGNOSTIC_FILE"] = str(path)
    return environment


@contextmanager
def session(path=None, *, reuse=False):
    if active() is not None:
        yield active()
        return
    recorder = Recorder()
    if reuse and path is not None:
        recorder.load(path)
        recorder.reserve(path)
    token = _ACTIVE.set(recorder)
    try:
        yield recorder
    finally:
        if path is not None:
            recorder.save(path)
        _ACTIVE.reset(token)


def diagnostic_session(function):
    @functools.wraps(function)
    def wrapped(*args, **kwargs):
        argv = args[0] if args and isinstance(args[0], list) else kwargs.get("argv")
        argv = sys.argv[1:] if argv is None else argv
        index = argv.index("--diagnostics-receipt") + 1 if "--diagnostics-receipt" in argv else len(argv)
        path = Path(argv[index]) if index < len(argv) else None
        with session(path, reuse=path is not None):
            return function(*args, **kwargs)
    return wrapped
