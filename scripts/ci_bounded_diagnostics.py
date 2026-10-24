"""Read-only contract for bounded, public infrastructure measurements."""

from __future__ import annotations

import json
import re
import statistics

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
MAX_RESOURCE_CASES = 64
MAX_RESOURCE_SAMPLES = 43201
MAX_FAILURE_RESOURCE_SAMPLES = 6
RESOURCE_CATEGORIES = ("app", "simulator_daemons", "test_tools", "other")
MAX_APP_HANG_STACK_BYTES = 4096
MAX_CONTINUE_WATCH_BYTES = 8192
MAX_CONTINUE_WATCH_FRAMES = 80
CONTINUE_WATCH_STATUSES = (None, "MATCH", "TRANSITION", "BLACK", "BLANK", "UNRECOGNIZABLE")
CONTINUE_WATCH_RESCUES = ("not_recorded", "not_evaluated", "rejected", "original_pass", "rescued")
APP_HANG_MODULES = frozenset(("immichSlides", "SwiftUI", "SwiftUICore", "UIKitCore", "UIKit", "AttributeGraph",
    "CoreFoundation", "Foundation", "QuartzCore", "CoreGraphics", "GraphicsServices", "dyld", "libdyld.dylib",
    "libswiftCore.dylib", "libswift_Concurrency.dylib", "libsystem_kernel.dylib", "libsystem_pthread.dylib",
    "libsystem_platform.dylib", "libsystem_c.dylib", "libdispatch.dylib", "libobjc.A.dylib"))


def public_stack_symbol(value):
    return (isinstance(value, str) and 0 < len(value) <= 160
            and re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*", value) is not None
            and re.search(r"\.(?:com|net|org|local|internal|invalid|test)(?:\.|$)", value, re.I) is None)


def validate_continue_watch(value):
    def numeric(item, ceiling=MAX_DIAGNOSTIC_SECONDS):
        return type(item) in (int, float) and 0 <= item <= ceiling
    valid = isinstance(value, dict) and set(value) == {"total_frames", "truncated", "frames", "indices", "rescue", "wake"}
    if valid:
        frames, indices, wake = value["frames"], value["indices"], value["wake"]
        valid = (type(value["total_frames"]) is int and 0 <= value["total_frames"] <= MAX_INTEGER
            and type(value["truncated"]) is bool and isinstance(frames, list)
            and len(frames) <= min(MAX_CONTINUE_WATCH_FRAMES, value["total_frames"])
            and value["truncated"] == (len(frames) < value["total_frames"])
            and isinstance(value["rescue"], str) and value["rescue"] in CONTINUE_WATCH_RESCUES
            and isinstance(indices, dict) and set(indices) <= {"anchor", "dim", "proof"}
            and all(type(index) is int and 0 <= index < len(frames) for index in indices.values())
            and (wake is None or (isinstance(wake, list) and len(wake) == 2
                 and all(numeric(item) for item in wake) and wake[0] <= wake[1])))
    if valid:
        previous = -1
        for frame in frames:
            valid = (isinstance(frame, list) and len(frame) == 9
                and all(numeric(item) for item in frame[:3]) and previous <= frame[0] <= frame[1] <= frame[2]
                and frame[3] in CONTINUE_WATCH_STATUSES
                and (frame[4] is None or (isinstance(frame[4], str) and re.fullmatch(r"A[1-8]", frame[4]) is not None))
                and (frame[5] is None or numeric(frame[5], 1))
                and (frame[6] is None or numeric(frame[6], 255))
                and (frame[7] is None or numeric(frame[7], 1))
                and (frame[8] is None or type(frame[8]) is bool))
            if not valid:
                break
            previous = frame[2]
    if valid:
        valid = len(json.dumps(value, separators=(",", ":")).encode()) <= MAX_CONTINUE_WATCH_BYTES
    require(valid, "continue watch: invalid projection")


def render_continue_watch(value):
    frames = value["frames"]
    gaps = [right[0] - left[0] for left, right in zip(frames, frames[1:])]
    gap = f"{round(statistics.median(gaps), 3):g}s" if gaps else "unavailable"
    dim = sum(frame[3] == "MATCH" and frame[6] is not None and frame[6] < 255 for frame in frames)
    return (f"continue-watch: frames={len(frames)}/{value['total_frames']}, median gap={gap}, "
            f"dim MATCH={dim}, rescue={value['rescue']}")


def validate_app_hang_stack(stack):
    valid = (isinstance(stack, dict) and {"status", "sample_count", "frames"} <= set(stack)
             and set(stack) <= {"status", "sample_count", "frames", "hint"})
    if valid:
        frames = stack["frames"]
        valid = (stack["status"] in ("captured", "failure", "timeout", "cancelled")
                 and type(stack["sample_count"]) is int and 0 <= stack["sample_count"] <= MAX_INTEGER
                 and isinstance(frames, list) and len(frames) <= 30)
    if valid:
        valid = all(isinstance(frame, dict) and set(frame) == {"symbol", "module", "samples"}
                    and public_stack_symbol(frame["symbol"]) and isinstance(frame["module"], str)
                    and frame["module"] in APP_HANG_MODULES
                    and type(frame["samples"]) is int and 1 <= frame["samples"] <= MAX_INTEGER for frame in frames)
        valid = valid and (stack["status"] == "captured" or (not frames and stack["sample_count"] == 0))
        hint = stack.get("hint", [])
        valid = valid and isinstance(hint, list) and len(hint) <= 3
        if valid:
            valid = all(type(index) is int and 0 <= index < len(frames) for index in hint) and len(set(hint)) == len(hint)
    if valid:
        valid = len(json.dumps(stack, separators=(",", ":")).encode()) <= MAX_APP_HANG_STACK_BYTES
    require(valid, "app hang stack: invalid projection")


def render_app_hang_hint(stack):
    frames = stack["frames"]
    if "hint" in stack:
        selected = [frames[index] for index in stack["hint"]]
    else:
        # Older projections have no call-path relationship; show one frame without inventing a chain.
        selected = ([frame for frame in frames if frame["module"] == "immichSlides"] or frames)[:1]
    hint = " ← ".join("`" + frame["symbol"] + "`" for frame in selected) or stack["status"]
    count = f"{selected[0]['samples']}/{stack['sample_count']}" if selected else str(stack["sample_count"])
    return f"app-hang-stack: {hint} ({count} samples)"


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
    fields = {"schema_version", "collection_seconds", "truncated", "events"}
    if isinstance(receipt, dict) and "case_resources" in receipt:
        fields.add("case_resources")
    exact_fields(receipt, fields, "bounded diagnostics")
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
    if "case_resources" in receipt:
        validate_case_resources(receipt["case_resources"])


def validate_case_resources(cases):
    require(isinstance(cases, list) and len(cases) <= MAX_RESOURCE_CASES, "case resources: invalid case count")
    sequences = set()
    for case in cases:
        fields = {"sequence", "duration_seconds", "sample_interval_seconds", "sample_count", "truncated",
            "idle_percent_min", "idle_percent_median", "load_1m_max", "app_cpu_percent_peak", "sampler_wall_seconds",
            "sampler_cpu_seconds", "first_failure_elapsed_seconds", "failure_samples"}
        if isinstance(case, dict) and "app_hang_stack" in case:
            fields.add("app_hang_stack")
            validate_app_hang_stack(case["app_hang_stack"])
        if isinstance(case, dict) and "continue_watch" in case:
            fields.add("continue_watch")
            validate_continue_watch(case["continue_watch"])
        exact_fields(case, fields, "case resources")
        number(case["sequence"], MAX_INTEGER, "case resources sequence", integral=True)
        require(case["sequence"] not in sequences, "case resources: duplicate sequence")
        sequences.add(case["sequence"])
        number(case["duration_seconds"], MAX_DIAGNOSTIC_SECONDS, "case resources duration")
        number(case["sample_interval_seconds"], MAX_DIAGNOSTIC_SECONDS, "case resources interval", minimum=0.001)
        number(case["sample_count"], MAX_RESOURCE_SAMPLES, "case resources sample count", integral=True)
        require(type(case["truncated"]) is bool, "case resources: truncated must be boolean")
        for field, ceiling, label in (("idle_percent_min", MAX_CPU_PERCENT, "idle"),
                ("idle_percent_median", MAX_CPU_PERCENT, "idle"), ("load_1m_max", MAX_LOAD_AVERAGE, "load"),
                ("app_cpu_percent_peak", MAX_PROCESS_CPU_PERCENT, "app cpu"),
                ("sampler_wall_seconds", MAX_DIAGNOSTIC_SECONDS, "wall cost"),
                ("sampler_cpu_seconds", MAX_CPU_SECONDS, "cpu cost"),
                ("first_failure_elapsed_seconds", MAX_DIAGNOSTIC_SECONDS, "failure time")):
            number(case[field], ceiling, "case resources " + label, nullable=True)
        low, median = case["idle_percent_min"], case["idle_percent_median"]
        require(low is None or median is None or low <= median, "case resources: idle statistics out of order")
        failure = case["first_failure_elapsed_seconds"]
        require(failure is None or failure <= case["duration_seconds"], "case resources: failure outside case")
        samples = case["failure_samples"]
        require(isinstance(samples, list) and len(samples) <= MAX_FAILURE_RESOURCE_SAMPLES,
                "case resources: invalid failure samples")
        require(len(samples) <= case["sample_count"], "case resources: samples exceed count")
        previous = -1
        for sample in samples:
            exact_fields(sample, {"elapsed_seconds", "idle_percent", "load_1m", "cpu_percent"}, "case resource sample")
            elapsed = sample["elapsed_seconds"]
            number(elapsed, MAX_DIAGNOSTIC_SECONDS, "case resources sample time")
            require(failure is not None and abs(elapsed - failure) <= 5, "case resources: sample outside failure window")
            require(elapsed <= case["duration_seconds"], "case resources: sample outside case")
            require(elapsed > previous, "case resources: samples out of order")
            previous = elapsed
            number(sample["idle_percent"], MAX_CPU_PERCENT, "case resources sample idle", nullable=True)
            number(sample["load_1m"], MAX_LOAD_AVERAGE, "case resources sample load", nullable=True)
            exact_fields(sample["cpu_percent"], RESOURCE_CATEGORIES, "case resource categories")
            for value in sample["cpu_percent"].values():
                number(value, MAX_PROCESS_CPU_PERCENT, "case resources category cpu", nullable=True)


def render_receipt(receipt):
    costs = []
    for scope, value in receipt["collection_seconds"].items():
        measurement = "unavailable" if value is None else f"{value:g} s"
        if value is not None and value > COLLECTION_BUDGET_SECONDS[scope]:
            measurement += " (over budget)"
        costs.append(f"{scope}={measurement}")
    latest = {}
    for event in receipt["events"]:
        sample = event["sample"]
        # A sampler's hosting marker does not establish that Xcode reached test execution.
        if (event["scope"] == "xcode" and event["phase"] == "test-execution" and event["state"] == "started"
                and event["elapsed_seconds"] == 0 and event["cpu_seconds"] is None
                and event["input_sha256"] is None and event["official_exports"] is None and sample is not None
                and all(sample[field] is None for field in ("cpu_percent", "memory_free_bytes", "load_average", "image_version"))
                and not sample["processes"]):
            continue
        latest[event["scope"]] = event
    phases = "; ".join(f"{scope}: {event['phase']}/{event['state']} at {event['elapsed_seconds']:g} s"
                       for scope, event in latest.items()) or "none"
    rendered = (f"\nBounded diagnostics (measurements only): {'; '.join(costs)}; events={len(receipt['events'])}; "
            f"truncated={'yes' if receipt['truncated'] else 'no'}. Last retained phase: {phases}\n")
    def measured(value):
        return "unavailable" if value is None else f"{value:g}"
    for case in receipt.get("case_resources", []):
        rendered += (f"\nCase resources {case['sequence']} (measurements only): samples={case['sample_count']}; "
            f"idle min/median={measured(case['idle_percent_min'])}/{measured(case['idle_percent_median'])}%; "
            f"max load 1m={measured(case['load_1m_max'])}; peak app cpu={measured(case['app_cpu_percent_peak'])}%; "
            f"sampler wall/cpu={measured(case['sampler_wall_seconds'])}/{measured(case['sampler_cpu_seconds'])}s; "
            f"failure samples={len(case['failure_samples'])}; truncated={'yes' if case['truncated'] else 'no'}.\n")
    return rendered
