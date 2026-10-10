"""Bounded queue predictions and conservative Cloud start accounting."""

from __future__ import annotations

import calendar
import math
from datetime import datetime, timedelta, timezone

from ci_summary import require

SLOTS = 5
CAP_MINUTES = 45 * 60
RESERVE_MINUTES = 120
BUILD_SECONDS = 13 * 60
IMPORT_SECONDS = 3 * 60
ARCHIVE_SECONDS = 5 * 60
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


def github_estimate(jobs, now, test_seconds, *, history, matrix_cap=3):
    """Simulate visible slots; fewer than five occupied slots cannot prove congestion.

    Queued dependency/concurrency jobs without runner labels are excluded. The
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
    running, queued, unknown = [], [], 0
    for job in rows.values():
        labels = job.get("labels")
        require(isinstance(labels, list) and all(isinstance(label, str) for label in labels), "missing queue labels")
        if not ("xcode-27" in labels or any(label.startswith("macos-") for label in labels)):
            unknown += int(not labels and job["status"] in {"queued", "in_progress"})
            continue
        samples = history.get(job["name"], [])
        require(samples and len(samples) <= 100, "queue job has no bounded duration history")
        ordered = sorted(positive(value) for value in samples)
        duration = ordered[max(0, math.ceil(len(ordered) * .9) - 1)]
        if job["status"] == "in_progress" and type(job.get("runner_id")) is int and job["runner_id"] > 0 and job.get("steps"):
            elapsed = (now - timestamp(job["started_at"])).total_seconds()
            require(elapsed >= 0, "queue execution starts in the future")
            running.append(max(120, duration - elapsed))
        elif job["status"] in {"queued", "in_progress"}:
            created = timestamp(job["created_at"])
            require(created <= now, "queued job has future creation time")
            queued.append((created, job["id"], duration))
    require(len(running) <= SLOTS, "visible running jobs exceed configured hosted capacity")
    lanes = sorted(running + [0] * (SLOTS - len(running)))
    for _, _, duration in sorted(queued):
        index = min(range(SLOTS), key=lambda i: lanes[i])
        lanes[index] += duration
    # A gate archive must precede every GitHub UI job. This deliberately counts
    # a full archive rather than declaring a merely queued gate already ready.
    index = min(range(SLOTS), key=lambda i: lanes[i])
    archive_ready = lanes[index] + ARCHIVE_SECONDS
    lanes[index] = archive_ready
    group_lanes = {group: [archive_ready] * cap for group, cap in caps.items()}
    planned = ([(duration, group) for group, seconds in test_seconds.items() for duration in seconds]
               if isinstance(test_seconds, dict) else [(duration, "group") for duration in test_seconds])
    finish = archive_ready
    for duration, group in sorted(((positive(duration), group) for duration, group in planned), reverse=True):
        require(group in group_lanes, "missing UI matrix capacity")
        slot = min(range(SLOTS), key=lambda i: lanes[i])
        group_slot = min(range(len(group_lanes[group])), key=lambda i: group_lanes[group][i])
        end = max(archive_ready, lanes[slot], group_lanes[group][group_slot]) + duration
        lanes[slot] = group_lanes[group][group_slot] = end
        finish = max(finish, end)
    return {"seconds": max(finish, archive_ready) + 60, "running_mac_jobs": len(running),
            "queued_mac_jobs": len(queued), "unclassified_jobs": unknown, "free_slots": SLOTS - len(running),
            "can_prove_saturation": len(running) == SLOTS and unknown == 0,
            "scope": "repository-visible", "duration_model": "recent-job-p90", "ordering": "ready-job-age-estimate"}


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


def month_policy(now, billing_window, *, cap_minutes=CAP_MINUTES):
    require(type(cap_minutes) in {int, float} and 0 < cap_minutes <= CAP_MINUTES, "invalid Cloud allowance")
    utc_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    utc_end = (utc_start + timedelta(days=calendar.monthrange(now.year, now.month)[1]))
    windows = [(utc_start, utc_end)]
    expires = False
    if billing_window is not None:
        start, end = timestamp(billing_window["start"]), timestamp(billing_window["end"])
        require(start <= now < end and timedelta(days=27) <= end - start <= timedelta(days=32),
                "confirmed Apple billing window is stale or invalid")
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
