"""Read-only contract for bounded, public infrastructure measurements."""

from __future__ import annotations

import re

from ci_summary import require

COLLECTION_BUDGET_SECONDS = {"preparation": 5, "xcode": 10, "fixture": 2}
MAX_DIAGNOSTIC_SECONDS = 86400
MAX_CPU_SECONDS = 10**12
MAX_MEMORY_BYTES = 2**50
MAX_PROCESS_CPU_PERCENT = 10**6
MAX_LOAD_AVERAGE = 10**6
MAX_CPU_PERCENT = 100
MAX_INTEGER = 2**31 - 1
MAX_PROCESSES = 64
MAX_PROCESS_COUNT = 65536
PHASES = {
    "preparation": ("simulator-preparation", "simulator-readiness", "simulator-boot", "simulator-bootstatus", "simulator-container"),
    "xcode": ("unknown", "xcodebuild", "build", "test-launch", "test-execution", "official-export"),
    "fixture": ("import", "fixture-build", "image-generation", "fixture-generation", "manifest", "bind", "ready-write"),
}
STATES = ("started", "completed", "spawn-started", "spawn-completed", "communicate-started", "timeout",
          "kill-started", "kill-completed", "reap-started", "reap-completed", "before-kill", "after-reap")
PROCESS_NAMES = ("simctl", "CoreSimulatorService", "Simulator", "launchd_sim", "xcodebuild", "xctest",
                 "testmanagerd", "immichSlides", "immichSlidesUITests-Runner", "swift-frontend")
PROCESS_STATES = ("running", "sleeping", "uninterruptible", "stopped", "zombie", "unknown")
MAX_EVENTS = 512


def exact_fields(value, names, where):
    require(isinstance(value, dict) and set(value) == set(names), where + ": invalid fields")


def number(value, ceiling, where, *, integral=False, minimum=0, nullable=False):
    valid = value is None and nullable
    if type(value) in ((int,) if integral else (int, float)):
        valid = minimum <= value <= ceiling
    require(valid, where + ": invalid number")


def vector(value, where):
    require(isinstance(value, list) and len(value) == 3, where + ": invalid vector")


def validate_sample(sample):
    exact_fields(sample, {"cpu_percent", "memory_free_bytes", "load_average", "runner_hosted", "image_version", "processes"},
                 "bounded diagnostic sample")
    number(sample["cpu_percent"], MAX_CPU_PERCENT, "bounded diagnostic cpu", nullable=True)
    number(sample["memory_free_bytes"], MAX_MEMORY_BYTES, "bounded diagnostic memory", integral=True, nullable=True)
    require(sample["runner_hosted"] is None or type(sample["runner_hosted"]) is bool,
            "bounded diagnostic sample: invalid runner flag")
    if sample["image_version"] is not None:
        vector(sample["image_version"], "bounded diagnostic image version")
        for component in sample["image_version"]:
            number(component, MAX_INTEGER, "bounded diagnostic image component", integral=True)
    if sample["load_average"] is not None:
        vector(sample["load_average"], "bounded diagnostic load")
        for value in sample["load_average"]:
            number(value, MAX_LOAD_AVERAGE, "bounded diagnostic load")
    processes = sample["processes"]
    require(isinstance(processes, list) and len(processes) <= MAX_PROCESSES, "bounded diagnostic sample: invalid process count")
    for process in processes:
        exact_fields(process, {"name", "state", "count", "cpu_percent", "rss_bytes"}, "bounded diagnostic process")
        require(process["name"] in PROCESS_NAMES, "bounded diagnostic process: invalid name")
        require(process["state"] in PROCESS_STATES, "bounded diagnostic process: invalid state")
        number(process["count"], MAX_PROCESS_COUNT, "bounded diagnostic process count", integral=True, minimum=1)
        number(process["cpu_percent"], MAX_PROCESS_CPU_PERCENT, "bounded diagnostic process cpu", nullable=True)
        number(process["rss_bytes"], MAX_MEMORY_BYTES, "bounded diagnostic process memory", integral=True, nullable=True)


def validate_receipt(receipt):
    exact_fields(receipt, {"schema_version", "collection_seconds", "truncated", "events"}, "bounded diagnostics")
    require(type(receipt["schema_version"]) is int and receipt["schema_version"] == 1,
            "bounded diagnostics: unsupported version")
    exact_fields(receipt["collection_seconds"], COLLECTION_BUDGET_SECONDS, "bounded diagnostics collection")
    for scope in COLLECTION_BUDGET_SECONDS:
        number(receipt["collection_seconds"][scope], MAX_DIAGNOSTIC_SECONDS, "bounded diagnostics " + scope + " collection", nullable=True)
    require(type(receipt["truncated"]) is bool, "bounded diagnostics: truncated must be boolean")
    events = receipt["events"]
    require(isinstance(events, list) and len(events) <= MAX_EVENTS, "bounded diagnostics: invalid event count")
    for event in events:
        exact_fields(event, {"scope", "phase", "state", "sequence", "elapsed_seconds", "cpu_seconds", "sample",
                             "input_sha256", "official_exports"}, "bounded diagnostic event")
        scope = event["scope"]
        require(isinstance(scope, str) and scope in PHASES, "bounded diagnostic event: invalid scope")
        require(event["phase"] in PHASES[scope], "bounded diagnostic event: invalid phase")
        require(event["state"] in STATES, "bounded diagnostic event: invalid state")
        number(event["sequence"], MAX_INTEGER, "bounded diagnostic sequence", integral=True)
        number(event["elapsed_seconds"], MAX_DIAGNOSTIC_SECONDS, "bounded diagnostic elapsed_seconds")
        number(event["cpu_seconds"], MAX_CPU_SECONDS, "bounded diagnostic cpu_seconds", nullable=True)
        digest = event["input_sha256"]
        require(digest is None or (scope == "fixture" and event["phase"] in ("image-generation", "fixture-generation")
                and isinstance(digest, str)
                and re.fullmatch(r"[0-9a-f]{64}", digest) is not None), "bounded diagnostic event: invalid public input hash")
        exports = event["official_exports"]
        if exports is not None:
            require(scope == "xcode", "bounded diagnostic event: exports require xcode scope")
            exact_fields(exports, {"bundle", "summary", "tests"}, "bounded diagnostic exports")
            require(all(type(value) is bool for value in exports.values()), "bounded diagnostic exports: invalid boolean")
        if event["sample"] is not None:
            validate_sample(event["sample"])


def render_receipt(receipt):
    costs = []
    for scope, value in receipt["collection_seconds"].items():
        measurement = "unavailable" if value is None else f"{value:g} s"
        if value is not None and value > COLLECTION_BUDGET_SECONDS[scope]:
            measurement += " (over budget)"
        costs.append(f"{scope}={measurement}")
    latest = {event["scope"]: event for event in receipt["events"]}
    phases = "; ".join(f"{scope}: {event['phase']}/{event['state']} at {event['elapsed_seconds']:g} s"
                       for scope, event in latest.items()) or "none"
    return (f"\nBounded diagnostics (measurements only): {'; '.join(costs)}; events={len(receipt['events'])}; "
            f"truncated={'yes' if receipt['truncated'] else 'no'}. Last retained phase: {phases}\n")
