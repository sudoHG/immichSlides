"""Bounded queue predictions and conservative Cloud start accounting."""

from __future__ import annotations

import calendar
import math
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from ci_summary import require

SLOTS = 5
CAP_MINUTES = 45 * 60
RESERVE_MINUTES = 120
BUILD_SECONDS = 13 * 60
IMPORT_SECONDS = 3 * 60
MIN_JOB_SECONDS = 120
OVERHEAD_SECONDS = {"iphone": 9 * 60, "ipad": 9 * 60, "appletv": 4 * 60}


def timestamp(value):
    require(isinstance(value, str), "missing scheduling timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.utcoffset() is not None, "scheduling timestamp needs an offset")
    return parsed.astimezone(timezone.utc)


def positive(value):
    require(type(value) in {int, float} and math.isfinite(value) and value > 0,
            "invalid scheduling duration")
    return value


def github_estimate(jobs, now, test_seconds, *, history, matrix_cap=3, gate=None, platform=None):
    """Simulate visible slots; fewer than five occupied slots cannot prove congestion.

    Unknown dependency/concurrency jobs without labels prevent proving saturation;
    the own gate's declared archive/unit dependencies can still be modeled. The
    estimate is repository-visible and assumes ready jobs are scheduled by age;
    neither account-wide free capacity nor GitHub FIFO is exposed by this API.
    """
    caps = matrix_cap if isinstance(matrix_cap, dict) else {"group": matrix_cap}
    require(caps and all(type(cap) is int and 0 < cap <= SLOTS for cap in caps.values()), "invalid matrix capacity")
    rows = {}
    for job in jobs:
        require(type(job["id"]) is int and job["id"] > 0, "invalid queue job ID")
        if job["id"] in rows:
            require(rows[job["id"]] == job, "conflicting retained job execution")
        rows[job["id"]] = job
    gate_jobs = {} if gate is None else {job["name"]: job for job in gate["jobs"]
                                        if job["name"] in {"build-ios", "build-tvos", "unit-ios", "unit-tvos"}}
    if gate is not None:
        require(platform in {"ios", "tvos"} and "build-" + platform in gate_jobs, "this head has no gate archive job")
        next_id = max(rows.keys() | {job["id"] for job in gate_jobs.values()}) + 1
        for name, build in list(gate_jobs.items()):
            unit = name.replace("build-", "unit-")
            if name.startswith("build-") and unit not in gate_jobs:
                require(gate.get("status") != "completed", "completed gate has no unit execution")
                gate_jobs[unit] = {"id": next_id, "name": unit, "status": "queued", "labels": [],
                                   "created_at": build.get("created_at", now.isoformat()), "synthetic": True}
                next_id += 1
        for job in gate_jobs.values():
            rows[job["id"]] = job
    gate_ids = {job["id"]: name for name, job in gate_jobs.items()}
    running, queued, unknown, completed = [], [], 0, {}
    for job in rows.values():
        own = gate_ids.get(job["id"])
        if job["status"] == "completed":
            if own:
                require(job["conclusion"] == "success", "this head's gate job failed or was skipped")
                completed[own] = 0
            continue
        labels = job.get("labels")
        require(isinstance(labels, list) and all(isinstance(label, str) for label in labels), "missing queue labels")
        if not (own or "xcode-27" in labels or any(label.startswith("macos-") for label in labels)):
            unknown += int(not labels and job["status"] in {"queued", "in_progress"})
            continue
        # Unknown macOS workloads may only shorten the GitHub forecast. Refusing
        # them would disable overflow precisely when nightly fills the queue.
        samples = history.get(job["name"], []) or [MIN_JOB_SECONDS]
        require(len(samples) <= 100, "queue job has unbounded duration history")
        ordered = sorted(positive(value) for value in samples)
        duration = ordered[max(0, math.ceil(len(ordered) * .9) - 1)]
        if job["status"] == "in_progress" and type(job.get("runner_id")) is int and job["runner_id"] > 0 and job.get("steps"):
            elapsed = (now - timestamp(job["started_at"])).total_seconds()
            require(elapsed >= 0, "queue execution starts in the future")
            remaining = max(MIN_JOB_SECONDS, duration - elapsed)
            running.append(remaining)
            if own:
                completed[own] = remaining
        elif job["status"] in {"queued", "in_progress"}:
            created = timestamp(job["created_at"])
            require(created <= now, "queued job has future creation time")
            dependency = "build-" + own.removeprefix("unit-") if own and own.startswith("unit-") else None
            require(dependency is None or dependency in gate_jobs, "gate unit job has no archive dependency")
            queued.append((created, job["id"], duration, own, dependency, None))
    require(len(running) <= SLOTS, "visible running jobs exceed configured hosted capacity")
    lanes = sorted(running + [0] * (SLOTS - len(running)))
    group_lanes = {group: [0] * cap for group, cap in caps.items()}
    planned = ([(duration, group) for group, seconds in test_seconds.items() for duration in seconds]
               if isinstance(test_seconds, dict) else [(duration, "group") for duration in test_seconds])
    pending, finish = list(queued), 0
    next_id = max(rows, default=0) + 1
    for duration, group in sorted(((positive(duration), group) for duration, group in planned), reverse=True):
        require(group in group_lanes, "missing UI matrix capacity")
        pending.append((now, next_id, duration, None, "build-" + platform if gate is not None else None, group))
        next_id += 1
    while pending:
        ready = [item for item in pending if item[4] is None or item[4] in completed]
        require(ready, "gate dependency forecast is unresolved")
        # Respect dependencies even when the API reports an unassigned unit job
        # as queued. Choose the oldest job that can use the next available slot.
        slot = min(range(SLOTS), key=lambda i: lanes[i])
        release = lambda item: max(completed[item[4]] if item[4] else 0,
                                   min(group_lanes[item[5]]) if item[5] else 0)
        eligible = [item for item in ready if release(item) <= lanes[slot]]
        item = min(eligible or ready, key=(lambda item: (item[0], item[1])) if eligible
                   else (lambda item: (release(item), item[0], item[1])))
        lanes[slot] = max(lanes[slot], release(item)) + item[2]
        if item[3]:
            completed[item[3]] = lanes[slot]
        if item[5]:
            group_slot = min(range(len(group_lanes[item[5]])), key=lambda i: group_lanes[item[5]][i])
            group_lanes[item[5]][group_slot] = lanes[slot]
            finish = max(finish, lanes[slot])
        pending.remove(item)
    archive_ready = completed["build-" + platform] if gate is not None else 0
    return {"seconds": max(finish, archive_ready) + 60, "running_mac_jobs": len(running),
            "queued_mac_jobs": len(queued), "unclassified_jobs": unknown, "free_slots": SLOTS - len(running),
            "can_prove_saturation": len(running) == SLOTS and unknown == 0,
            "scope": "repository-visible", "duration_model": "recent-job-p90", "ordering": "ready-job-age-estimate",
            "archive_ready_seconds": archive_ready, "gate_job_finish_seconds": completed,
            "gate_run_id": gate["id"] if gate else None, "gate_attempt": gate["run_attempt"] if gate else None,
            "other_group_ui": "not-modeled"}


def cloud_estimate(descriptor, selection, *, queue_seconds=0):
    require(type(queue_seconds) in {int, float} and math.isfinite(queue_seconds) and queue_seconds >= 0,
            "invalid Cloud queue estimate")
    predicted, usage = [], 0
    registration = descriptor["registration"]
    for field in ("destinations_parallel", "actions_parallel"):
        require(field not in registration or type(registration[field]) is bool, "invalid reviewed Cloud parallelism")
    for action in descriptor["registration"]["actions"]:
        durations = [positive(selection["packing"]["estimated_test_seconds"][device]) + OVERHEAD_SECONDS[device]
                     for device in action["devices"]]
        wall = BUILD_SECONDS + (max(durations) if registration.get("destinations_parallel") is True else sum(durations))
        predicted.append(wall)
        usage += len(durations) * wall / 60
    reservation = 5 * math.ceil((1.3 * usage + 5) / 5)
    return {"seconds": queue_seconds + (max(predicted) if registration.get("actions_parallel") is True else sum(predicted)) + IMPORT_SECONDS,
            "reservation_minutes": reservation, "destination_count": sum(len(a["devices"])
                for a in descriptor["registration"]["actions"]), "compute_estimate": "destination-wall-upper-bound",
            "queue_seconds": queue_seconds, "build_seconds": BUILD_SECONDS}


def month_policy(now, billing_anchor, *, cap_minutes=CAP_MINUTES):
    require(type(cap_minutes) in {int, float} and 0 < cap_minutes <= CAP_MINUTES, "invalid Cloud allowance")
    utc_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    utc_end = (utc_start + timedelta(days=calendar.monthrange(now.year, now.month)[1]))
    windows = [(utc_start, utc_end)]
    expires = False
    if billing_anchor is not None:
        require(isinstance(billing_anchor, dict) and type(billing_anchor.get("day")) is int
                and 1 <= billing_anchor["day"] <= 31 and isinstance(billing_anchor.get("time_zone"), str)
                and 0 < len(billing_anchor["time_zone"]) <= 64, "invalid confirmed Apple billing anchor")
        zone, day = ZoneInfo(billing_anchor["time_zone"]), billing_anchor["day"]
        local = now.astimezone(zone)
        def boundary(year, month):
            return datetime(year, month, min(day, calendar.monthrange(year, month)[1]), tzinfo=zone).astimezone(timezone.utc)
        month = local.year * 12 + local.month - 1
        if now < boundary(local.year, local.month):
            month -= 1
        year, offset = divmod(month, 12)
        start = boundary(year, offset + 1)
        year, offset = divmod(month + 1, 12)
        end = boundary(year, offset + 1)
        windows.append((start, end))
        expires = now >= utc_end - timedelta(days=3) and now >= end - timedelta(days=3)
    return {"windows": [(start.isoformat(), end.isoformat()) for start, end in windows],
            "cap_minutes": cap_minutes, "reserve_minutes": 0 if expires else RESERVE_MINUTES,
            "margin_seconds": 0 if expires else 120, "confirmed_expiry_window": expires}


def choose_cloud(github, cloud, usage_minutes, policy, *, unresolved_minutes=0):
    require(all(type(value) in {int, float} and math.isfinite(value) and value >= 0
                for value in (usage_minutes, unresolved_minutes)), "invalid Cloud usage estimate")
    reason = "cloud-faster"
    if github["free_slots"] > 0 or not github["can_prove_saturation"]:
        reason = "github-capacity-or-queue-uncertain"
    elif cloud["seconds"] + policy["margin_seconds"] >= github["seconds"]:
        reason = "github-estimated-faster"
    elif usage_minutes + unresolved_minutes + cloud["reservation_minutes"] + policy["reserve_minutes"] > policy["cap_minutes"]:
        reason = "monthly-cap-or-reserve"
    return {"route": reason == "cloud-faster", "reason": reason,
            "github_seconds": github["seconds"], "cloud_seconds": cloud["seconds"],
            "margin_seconds": policy["margin_seconds"], "reserve_minutes": policy["reserve_minutes"]}
