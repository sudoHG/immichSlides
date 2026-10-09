"""Monthly health calculations over the reporter's verified, compact history."""

from __future__ import annotations

import calendar
import json
import math
import re
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from ci_summary import ContractError, require, validate_observation, markdown_text

METRICS = ("first_attempt_failures", "flaky_passed", "skipped", "unexpected_skips",
           "test_duration_seconds", "run_duration_seconds", "queue_seconds", "artifact_bytes")


def month_bounds(month, now):
    require(isinstance(month, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}", month), "invalid health month")
    try:
        start = date.fromisoformat(month + "-01")
    except ValueError:
        raise ContractError("invalid health month") from None
    require(start <= now, "health month is in the future")
    return start, min(now, date(start.year, start.month, calendar.monthrange(start.year, start.month)[1]))


def report_month(event_name, event, now):
    month = event.get("inputs", {}).get("health_month", "")
    if month:
        require(event_name == "workflow_dispatch", "explicit month requires dispatch")
        month_bounds(month, now)
        return month
    if event_name == "schedule" and now.day == 1:
        return (now - timedelta(days=1)).strftime("%Y-%m")
    return None


def observation_metrics(observed, *, unexpected_skips=None):
    if not observed:
        return dict.fromkeys(("first_attempt_failures", "flaky_passed", "skipped", "unexpected_skips", "test_duration_seconds")) | {"schema_version": 1}
    for item in observed:
        validate_observation(item)
    return {"schema_version": 1,
            "first_attempt_failures": sum(item["attempts"][0]["outcome"] in {"failed", "crashed", "timed-out"} for item in observed),
            "flaky_passed": sum(item["outcome"] == "flaky-passed" for item in observed),
            "skipped": sum(item["outcome"] == "skipped" for item in observed),
            "unexpected_skips": unexpected_skips,
            "test_duration_seconds": sum(item["duration_seconds"] for item in observed)}


def first_execution_metrics(entry):
    if entry is None:
        return {"schema_version": 1, "first_attempt_failures": None}
    if "first_execution_health" in entry:
        return dict(entry["first_execution_health"])
    first = next((item for item in entry.get("attempt_history", []) if item["run"]["attempt"] == 1), entry)
    health = first.get("health", {})
    # Legacy gate/UI health already retained attempt 1; nightly needs its history.
    if first["run"]["attempt"] != 1 and first["source"]["workflow_path"] == ".github/workflows/ci-nightly.yml":
        health = {}
    return {"schema_version": health.get("schema_version", 1), "first_attempt_failures": health.get("first_attempt_failures")}


def unexpected_skips(summaries, policy, environment):
    from ci_verdict import expected_skip_verdict, parse_policy, tier_approved
    if policy is None:
        return None
    policy = parse_policy(policy)
    count = 0
    for summary in summaries:
        tier = summary["run"]["tier"]
        rules = policy["expected_skips"] if tier_approved(policy, tier) else []
        for item in summary["population"]["observed"]:
            if item["outcome"] == "skipped":
                accepted, _ = expected_skip_verdict(item, rules, tier=tier, environment=environment)
                count += not accepted
    return count


def elapsed(start, end):
    if not start or not end:
        return None
    first, last = (datetime.fromisoformat(value.replace("Z", "+00:00")) for value in (start, end))
    require(first.tzinfo is not None and last.tzinfo is not None
            and first.utcoffset() == last.utcoffset() == timedelta(0), "invalid health timestamp")
    seconds = (last - first).total_seconds()
    require(seconds >= 0, "negative health interval")
    return seconds


def run_metrics(run, jobs=None):
    # updated_at is GitHub's completed-run timestamp, not CPU or billed time.
    queues = [elapsed(job.get("created_at"), job.get("started_at")) for job in (jobs or []) if job.get("conclusion") != "skipped"]
    return {"queue_seconds": sum(queues) if queues and all(value is not None for value in queues) else None,
            "run_duration_seconds": elapsed(run.get("run_started_at"), run.get("updated_at")) if run["status"] == "completed" else None}


def health_report(snapshot, registry, month, now):
    from ci_report import daily_rollup, iso_day, registry_checks, REPORT_PATH
    start, end = month_bounds(month, now)
    require(snapshot.get("schema_version") == 2 and isinstance(snapshot.get("days"), dict), "invalid health snapshot")
    entries, days = [], []
    repository = snapshot.get("producer", {}).get("repository", "sudoHG/immichSlides")
    for day, rollup in sorted(snapshot["days"].items()):
        require(daily_rollup(iso_day(day), rollup["entries"]) == rollup, "invalid health rollup")
        require(all(item["source"]["repository"] == repository for item in rollup["entries"]), "health repository mismatch")
        if start.isoformat() <= day <= end.isoformat():
            days.append(day)
            entries.extend(rollup["entries"])
    metrics = {}
    for key in METRICS:
        values = []
        for entry in entries:
            source = entry
            if key == "first_attempt_failures":
                health = first_execution_metrics(entry)
            else:
                health = source.get("health", {})
            if health:
                require(type(health.get("schema_version")) is int and health["schema_version"] == 1, "unsupported health metrics")
            value = health.get(key)
            if value is None and key in {"flaky_passed", "skipped"}:
                counts = entry["diagnostics"]["counts"]
                if type(counts.get("observed")) is int and counts["observed"] > 0:
                    value = counts.get("flaky-passed" if key == "flaky_passed" else "skipped", 0)
            if value is not None:
                require(type(value) in (int, float) and math.isfinite(value) and value >= 0, "invalid health metric")
                require(key.endswith("seconds") or type(value) is int, "health count must be integer")
                values.append(value)
        metrics[key] = {"value": sum(values) if values else None, "sampled_runs": len(values), "missing_runs": len(entries) - len(values)}
    states = {int(item["issue"].rsplit("/", 1)[-1]): item["issue_state"]
              for item in snapshot.get("registry", []) if item.get("issue_state") in {"open", "closed", "missing"}}
    checks = registry_checks(registry, now.isoformat(), states)
    return {"schema_version": 1, "month": month, "as_of": now.isoformat(),
            "source": {"workflow_path": REPORT_PATH, "producer": snapshot.get("producer"), "history_reset": snapshot.get("history_reset"),
                       "budget_stopped": snapshot.get("budget_stopped", False), "api_budget": snapshot.get("api_budget", {})},
            "coverage": {"start": start.isoformat(), "end": end.isoformat(), "calendar_days": (end - start).days + 1,
                         "rollup_days": days, "days_with_runs": sorted({entry["day"] for entry in entries}),
                         "missing_calendar_days": (end - start).days + 1 - len(days), "runs": len(entries),
                         "statuses": dict(Counter(entry["status"] for entry in entries)),
                         "incomplete_evidence_runs": sum(bool(entry["diagnostics"]["missing"] or entry["diagnostics"]["infrastructure"]
                                                              or entry["status"] in {"pending", "unverified"}) for entry in entries),
                         "diagnostic_runs": sum(bool(entry.get("diagnostic_shard")) for entry in entries)},
            "metrics": metrics,
            "registry": {"as_of": now.isoformat(), "issue_states_as_of": snapshot.get("registry_day"), "entries": checks,
                         "aged_30_days": sum(item["age_days"] is not None and item["age_days"] >= 30 for item in checks)},
            "storage": {"snapshot_json_bytes": len((json.dumps(snapshot, sort_keys=True, separators=(",", ":")) + "\n").encode()),
                        "month_rollup_json_bytes": sum(len((json.dumps(snapshot["days"][day], separators=(",", ":")) + "\n").encode()) for day in days)}}


def render_registry(checks):
    lines = ["| Test | Owner | Review by | Review | Issue state | Date eligible | Age (days) |",
             "| --- | --- | --- | --- | --- | --- | --- |"]
    for item in checks:
        lines.append(f"| {markdown_text(item['identity']['key'])} | {markdown_text(item['owner'])} | {item['review_by']} | "
                     f"{item['review_status']} | [{item['issue_state']}]({item['issue']}) | {item['date_eligible']} | {item['age_days']} |")
    return "\n".join(lines) + "\n"


def render_health(report):
    coverage = report["coverage"]
    lines = [f"# CI health: {report['month']}", "",
             f"As of {report['as_of']} UTC. Scope: verified main pushes and nightlies; PR runs are not collected.", "",
             f"Available: {len(coverage['rollup_days'])}/{coverage['calendar_days']} UTC rollup days, "
             f"{len(coverage['days_with_runs'])} days with runs, {coverage['runs']} runs ({coverage['diagnostic_runs']} diagnostic).",
             f"Range: {coverage['start']} through {coverage['end']}; statuses: {json.dumps(coverage['statuses'], sort_keys=True)}. "
             f"{coverage['incomplete_evidence_runs']} runs have incomplete evidence; totals cover only available observations.", "",
             "Missing history and metrics are unavailable, never zero or evidence of passing. Durations are summed seconds; "
             "test durations include automatic retries. First-attempt failures use GitHub attempt 1 and each test's first call. "
             "Nightly method durations are unavailable because official method exports have no measured durations. "
             "Flaky-passed and skip totals use the latest saved attempt. Queue time sums job creation-to-start intervals "
             "from the existing gate/UI job reader (nightly queue data is unavailable); "
             "run duration is run start to GitHub update at completion, not billed CPU time. "
             "Artifact bytes are all listed run artifacts at collection time, counted once per run; they are not current repository storage.", "",
             "| Metric | Total | Runs sampled | Runs unavailable |", "| --- | ---: | ---: | ---: |"]
    for key, metric in report["metrics"].items():
        lines.append(f"| {key} | {metric['value'] if metric['value'] is not None else 'unavailable'} | {metric['sampled_runs']} | {metric['missing_runs']} |")
    lines += ["", f"Compact storage: snapshot {report['storage']['snapshot_json_bytes']} bytes; "
              f"selected month rollups {report['storage']['month_rollup_json_bytes']} bytes.",
              f"Collection budget stopped: {report['source']['budget_stopped']}; incomplete collection can omit runs.", "",
              f"Registry dates as of {report['registry']['as_of']}; issue states from snapshot collection "
              f"{report['registry']['issue_states_as_of'] or '(date not recorded by legacy reporter)'}. "
              f"{report['registry']['aged_30_days']} entries aged at least 30 days. "
              "Issue state does not change retry eligibility. Expiry disables retry after the review-by UTC day.", "",
              render_registry(report["registry"]["entries"])]
    return "\n".join(lines) + "\n"


def write_health(output, snapshot, registry, month, now):
    report = health_report(snapshot, registry, month, now)
    output = Path(output) / "health"
    output.mkdir(parents=True, exist_ok=True)
    (output / (month + ".json")).write_text(json.dumps(report, sort_keys=True) + "\n")
    rendered = render_health(report)
    (output / (month + ".md")).write_text(rendered)
    return rendered
