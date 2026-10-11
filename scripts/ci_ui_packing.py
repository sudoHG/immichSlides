"""Deterministic base-owned packing for scoped UI; full partitions stay unchanged."""

from __future__ import annotations

import hashlib
import itertools
import json
import math

from ci_summary import decode, fields, identity_key, require, validate_test_identity
from ci_ui_shards import DEVICES, LABEL, SELECTOR

DURATIONS_PATH = "scripts/ci-ui-durations.json"
PACKING_INTENT = "--pack-scoped-ui"
ALGORITHM = "capacity-v1"
ACCELERATION_INTENT = "--scoped-ui-v2"
TEST_SECONDS_PER_SHARD = 15 * 60
MAX_SHARDS = 6
MAX_JOB_SECONDS = 28 * 60
# Five minutes remain for the gate build; estimates never establish the 30-minute acceptance criterion.
TARGET_UI_SECONDS = 25 * 60
OVERHEAD_SECONDS = {"iphone": 9 * 60, "ipad": 9 * 60, "appletv": 4 * 60}
DEVICE_SLOTS = {"iphone": 2, "ipad": 1, "appletv": 1}
V2_OVERHEAD_SECONDS = {"iphone": 345, "ipad": 190, "appletv": 200}
V2_DEVICE_MAX_SLOTS = {device: 2 for device in DEVICES}
V2_MACOS_SLOTS = 5
V2_READY_SECONDS = {"iphone": 270, "ipad": 270, "appletv": 300}
V2_UNIT_FINISH_SECONDS = (450, 750)
V2_PUBLICATION_SECONDS = 60
V2_TARGET_PUSH_SECONDS = 30 * 60


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def parse_durations(raw):
    durations = decode(raw)
    fields(durations, {"schema_version", "revision", "default_seconds", "seconds"}, "UI durations")
    require(type(durations["schema_version"]) is int and durations["schema_version"] == 1,
            "unsupported UI duration version")
    require(isinstance(durations["revision"], str) and LABEL.fullmatch(durations["revision"]) is not None,
            "invalid UI duration revision")
    def positive(value):
        return type(value) in {int, float} and math.isfinite(value) and 0 < value <= 3600
    require(positive(durations["default_seconds"]), "invalid default UI duration")
    fields(durations["seconds"], set(DEVICES), "UI duration devices")
    for weights in durations["seconds"].values():
        require(isinstance(weights, dict) and len(weights) <= 4096, "UI durations need bounded method weights")
        for key, seconds in weights.items():
            require(isinstance(key, str) and "/" in key and SELECTOR.fullmatch(key) is not None
                    and positive(seconds), "invalid UI method duration")
    return durations


def capacity_v2_time(jobs, device_slots):
    """Model the PR's own two unit consumers alongside UI on five hosted slots."""
    pending = [{"device": device, "index": index, "release": V2_READY_SECONDS[device], "seconds": seconds}
               for device, loads in jobs.items() for index, seconds in enumerate(loads)]
    if not pending:
        return 0, 0
    first = min(job["release"] for job in pending)
    running = [{"device": "unit", "finish": finish} for finish in V2_UNIT_FINISH_SECONDS]
    now, ui_finish = first, 0
    while pending or running:
        running = [job for job in running if job["finish"] > now]
        pending.sort(key=lambda job: (job["release"], -job["seconds"], job["device"], job["index"]))
        while len(running) < V2_MACOS_SLOTS:
            index = next((index for index, job in enumerate(pending) if job["release"] <= now
                          and sum(item["device"] == job["device"] for item in running)
                          < device_slots[job["device"]]), None)
            if index is None:
                break
            job = pending.pop(index)
            finish = now + job["seconds"]
            running.append({"device": job["device"], "finish": finish})
            ui_finish = max(ui_finish, finish)
        future = ([job["finish"] for job in running]
                  + [job["release"] for job in pending if job["release"] > now])
        if future:
            now = min(future)
        else:
            require(not pending, "capacity model cannot schedule scoped UI")
    return ui_finish - first, ui_finish + V2_PUBLICATION_SECONDS


def pack_scoped_selection(populations, raw_durations, *, algorithm=ALGORITHM):
    """Minimize jobs if the latency budget fits; otherwise minimize predicted UI time within the caps."""
    require(algorithm in {ALGORITHM, "capacity-v2"}, "unknown scoped UI packing algorithm")
    durations = parse_durations(raw_durations)
    overhead = V2_OVERHEAD_SECONDS if algorithm == "capacity-v2" else OVERHEAD_SECONDS
    fields(populations, set(DEVICES), "scoped UI devices")
    ordered, weights, totals = {}, {}, {}
    for device, platform in DEVICES.items():
        entries = populations[device]
        require(isinstance(entries, list), "scoped UI population must be an array")
        for entry in entries:
            validate_test_identity(entry)
            require(entry["kind"] == "ui" and entry["dimensions"] == {"platform": platform, "device": device},
                    "scoped UI identity differs from its device")
        require(len({identity_key(entry) for entry in entries}) == len(entries), "duplicate scoped UI identity")
        weights[device] = {entry["key"]: durations["seconds"][device].get(entry["key"], durations["default_seconds"])
                           for entry in entries}
        ordered[device] = sorted(entries, key=lambda entry: (-weights[device][entry["key"]], identity_key(entry)))
        totals[device] = math.fsum(weights[device][key] for key in sorted(weights[device]))

    def counts(device):
        if not ordered[device]:
            return [0]
        cap = min(MAX_SHARDS, len(ordered[device]), math.ceil(totals[device] / TEST_SECONDS_PER_SHARD))
        return range(1, cap + 1)

    def partition(device, count):
        bins, loads = [[] for _ in range(count)], [0] * count
        for entry in ordered[device]:
            index = min(range(count), key=lambda index: (loads[index], index))
            bins[index].append(entry)
            loads[index] += weights[device][entry["key"]]
        return ({"scoped-" + chr(ord("a") + index): sorted(entries, key=identity_key)
                 for index, entries in enumerate(bins)}, [load + overhead[device] for load in loads])

    def wall_time(loads, slots):
        lanes = [0] * slots
        for load in sorted(loads, reverse=True):
            index = min(range(slots), key=lambda index: (lanes[index], index))
            lanes[index] += load
        return max(lanes)

    candidates = []
    for device_counts in itertools.product(*(counts(device) for device in DEVICES)):
        shards, jobs = {}, {}
        for device, count in zip(DEVICES, device_counts):
            shards[device], jobs[device] = partition(device, count) if count else ({}, [])
        if any(load > MAX_JOB_SECONDS for loads in jobs.values() for load in loads):
            continue
        profiles = ([dict(zip(DEVICES, slots))
                     for slots in itertools.product(*(range(1, min(V2_DEVICE_MAX_SLOTS[device],
                         max(1, len(jobs[device]))) + 1) for device in DEVICES)) if sum(slots) <= V2_MACOS_SLOTS]
                    if algorithm == "capacity-v2" else [DEVICE_SLOTS])
        for device_slots in profiles:
            if algorithm == "capacity-v2":
                wall, push = capacity_v2_time(jobs, device_slots)
            else:
                wall, push = max(wall_time(jobs[device], device_slots[device]) for device in DEVICES), None
            candidate = {"algorithm": algorithm, "durations_sha256": canonical_hash(durations),
                           "shards": shards, "estimated_test_seconds": totals, "estimated_job_seconds": jobs,
                           "estimated_ui_seconds": wall, "estimated_runner_seconds": sum(map(sum, jobs.values())),
                           "fits_target": wall <= TARGET_UI_SECONDS if push is None else push <= V2_TARGET_PUSH_SECONDS}
            if push is not None:
                candidate.update(estimated_push_seconds=push,
                    capacity={"macos_slots": V2_MACOS_SLOTS, "device_slots": device_slots,
                              "ready_seconds": dict(V2_READY_SECONDS), "unit_finish_seconds": list(V2_UNIT_FINISH_SECONDS),
                              "publication_seconds": V2_PUBLICATION_SECONDS})
            candidates.append(candidate)
    require(candidates, "scoped UI cannot fit the job budget within its per-device shard cap")
    def rank(candidate):
        count = sum(len(shards) for shards in candidate["shards"].values())
        wall = candidate.get("estimated_push_seconds", candidate["estimated_ui_seconds"])
        return ((0, count, candidate["estimated_runner_seconds"], wall)
                if candidate["fits_target"] else
                (1, wall, candidate["estimated_runner_seconds"], count))
    plan = min(candidates, key=rank)
    return dict(plan, sha256=canonical_hash(plan))
