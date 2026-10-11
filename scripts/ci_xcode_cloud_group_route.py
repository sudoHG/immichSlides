"""Main-only grouped routing; registry absence leaves every group on GitHub."""

from __future__ import annotations

import json
import math
import os
import re
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from statistics import median
from urllib.error import URLError
from urllib.parse import urlencode

from ci_publish import positive, trusted_admissions
from ci_summary import ContractError, require
from ci_xcode_cloud import ROUTE_PATH, archive_evidence_run, trusted_artifact, uuid
from ci_xcode_cloud_route import (SupersededProducer, action_minutes, build_receipt, current_producer,
                                  refresh_producer, remaining_seconds, timestamp, write_phase)
from ci_xcode_cloud_schedule import MIN_JOB_SECONDS, choose_cloud, cloud_estimate, github_estimate, month_policy
import ci_xcode_cloud_groups as groups
import ci_xcode_cloud_state as state

FAILURES = (ContractError, KeyError, TypeError, ValueError, OSError, URLError, subprocess.SubprocessError)
RECONCILIATION_HOURS = 2
SCAN_RATE_RESERVE = 200
# Unmarked attempts only list artifacts; marked attempts also authenticate both
# receipts in both checks and look up their admission/producer.
SCAN_REQUESTS_UNMARKED = 1
SCAN_REQUESTS_PER_ATTEMPT = 16
UI_HISTORY_RUNS = 10
UI_HISTORY_PAGES = 3
CLOCK_SKEW_SECONDS = 10


def ui_job_estimates(base_sha, ui_inputs):
    """Other PRs' UI populations are unknown; model each base-owned shard/family."""
    from ci_publish_git import read_blob
    from ci_ui_packing import DURATIONS_PATH, OVERHEAD_SECONDS, parse_durations
    require(base_sha and ui_inputs, "UI queue estimation requires trusted base inputs")
    durations = parse_durations(read_blob(base_sha, DURATIONS_PATH))
    manifest = ui_inputs["manifest"]
    assignment = {selector: shard for shard, selectors in manifest["shards"].items() for selector in selectors}
    estimates = {}
    for device, entries in ui_inputs["base_populations"].items():
        loads = {shard: 0 for shard in manifest["shards"]}
        for entry in entries:
            key = entry["key"]
            shard = assignment.get(key, assignment.get(key.split("/")[0], manifest["default_shard"]))
            loads[shard] += durations["seconds"][device].get(key, durations["default_seconds"])
        values = {"ui-" + device + "-" + shard: seconds + OVERHEAD_SECONDS[device]
                  for shard, seconds in loads.items() if seconds > 0}
        if values:
            estimates.update(values)
            estimates["ui-" + device] = max(values.values())
    return estimates


def anchor(record, run):
    from ci_publish_git import workflow_contract
    source = record["workflows"][groups.legacy.UI_PATH]["base"]
    _, _, _, metadata = workflow_contract(source, run, metadata=True)
    names = [name for name, meta in metadata.items() if meta["population"] == "ui-selection"]
    require(len(names) == 1, "group routing requires the independent Linux selection producer")
    return names[0]


def selection_open(api, run, group):
    jobs = api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs")
    return not any(job["name"] == "ui-cloud-wait-" + group and job["status"] == "completed" for job in jobs)


def queue_snapshot(api, now, selection, group, *, producer_run_id, head_sha, history=None, base_sha=None, ui_inputs=None):
    runs, jobs = {}, []
    for status in ("queued", "in_progress"):
        for run in api.pages("actions/runs", "workflow_runs", status=status):
            runs[run["id"]] = run
    for run in runs.values():
        for job in api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs"):
            if run["id"] == producer_run_id and not (job["status"] == "in_progress"
                    and type(job.get("runner_id")) is int and job["runner_id"] > 0 and job.get("steps")):
                continue  # These matrices wait for our choice and are modeled below.
            jobs.append(dict(job, run_id=run["id"]))
    if history is None:
        history, seen = {}, set()
        # Publishers and privacy runs dominate repository-wide history. Query
        # only macOS producers, once under the account lock, with bounded samples.
        for workflow in ("ci-gate.yml", "ci-ui.yml", "ci-nightly.yml", "ci-toolchain.yml"):
            ui_history = workflow == "ci-ui.yml"
            limit, recent = UI_HISTORY_RUNS if ui_history else 3, []
            for page in range(1, (UI_HISTORY_PAGES if ui_history else 1) + 1):
                query = (f"status=completed&event=pull_request&per_page={limit}&page={page}" if ui_history
                         else "status=success&per_page=3")
                rows = api.repo("actions/workflows/" + workflow + "/runs?" + query)["workflow_runs"]
                for run in rows:
                    if ((run.get("repository") or {}).get("full_name") != api.repository
                            or (run.get("head_repository") or {}).get("full_name") != api.repository
                            or run.get("path") != ".github/workflows/" + workflow
                            or run.get("event") not in {"pull_request", "push"}
                            or ui_history and (run["event"] != "pull_request" or run.get("conclusion") == "cancelled")):
                        continue  # Untrusted workflows cannot influence a Cloud spending decision.
                    recent.append(run)
                    if len(recent) == limit:
                        break
                if len(recent) == limit or len(rows) < limit:
                    break
            for run in recent:
                for job in api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs"):
                    if job["id"] in seen or job["conclusion"] != "success" or not job.get("runner_id"):
                        continue
                    seen.add(job["id"])
                    labels = job.get("labels", [])
                    if not ("xcode-27" in labels or any(label.startswith("macos-") for label in labels)):
                        continue
                    duration = (timestamp(job["completed_at"]) - timestamp(job["started_at"])).total_seconds()
                    require(duration > 0, "GitHub history has reversed execution timing")
                    scoped = re.match(r"^(ui-(iphone|ipad|appletv)-scoped)-", job["name"])
                    if scoped:
                        history.setdefault(scoped[1], []).append(duration)
                    elif not re.match(r"^ui-(iphone|ipad|appletv)-", job["name"]):
                        history.setdefault(job["name"], []).append(duration)
    else:
        history = {name: list(seconds) for name, seconds in history.items()}
    history = {name: seconds[-100:] for name, seconds in history.items()}
    ui_jobs = [job for job in jobs if job["status"] != "completed" and re.match(r"^ui-(iphone|ipad|appletv)-", job["name"])]
    static_jobs = [job for job in ui_jobs if not re.match(r"^ui-(iphone|ipad|appletv)-scoped-", job["name"])]
    estimates = ui_job_estimates(base_sha, ui_inputs) if static_jobs else {}
    for job in jobs:
        if job in ui_jobs:
            family = re.sub(r"^(ui-(?:iphone|ipad|appletv))-.*$", r"\1", job["name"])
            if job["name"].startswith(family + "-scoped-"):
                history[job["name"]] = [median(history.get(family + "-scoped", []) or [MIN_JOB_SECONDS])]
            else:
                require(job["name"] in estimates or family in estimates, "UI queue family has no trusted base duration estimate")
                history[job["name"]] = [estimates.get(job["name"], estimates[family])]
    seconds = {device: selection["packing"]["estimated_job_seconds"][device] for device in groups.GROUPS[group]}
    gates = api.repo("actions/workflows/ci-gate.yml/runs?event=pull_request&head_sha=" + head_sha + "&per_page=5")["workflow_runs"]
    gates = [run for run in gates if run["head_sha"] == head_sha and run["path"] == ".github/workflows/ci-gate.yml"]
    require(gates, "this head has no GitHub gate for an archive forecast")
    gate = max(gates, key=lambda run: run["id"])
    own_jobs = api.pages(f"actions/runs/{gate['id']}/attempts/{gate['run_attempt']}/jobs", "jobs")
    from ci_publish_git import ui_capacities
    capacities = ui_capacities({"selection": selection})
    result = github_estimate(jobs, now, seconds, history=history,
        matrix_cap={device: capacities[device] for device in seconds}, gate=dict(gate, jobs=own_jobs), platform=group)
    return dict(result, duration_history=history, duration_model="base-static-ui-scoped-median-non-ui-p90-or-floor",
                ui_duration_base_sha=base_sha if static_jobs else None)


def inventories(asc, registration):
    values = {}
    for group, registered in registration["groups"].items():
        workflow = asc.request("/v1/ciWorkflows/" + uuid(registered["workflow_id"]))["data"]
        require(workflow["id"] == registered["workflow_id"]
                and groups.canonical_hash(workflow["attributes"]) == registered["workflow_attributes_sha256"],
                "Cloud workflow configuration differs from reviewed read-back")
        rows = asc.pages("/v1/ciWorkflows/" + uuid(registered["workflow_id"]) + "/buildRuns?limit=200")
        require(len({uuid(row["id"]) for row in rows}) == len(rows)
                and all(row["attributes"]["executionProgress"] in {"PENDING", "RUNNING", "COMPLETE"} for row in rows),
                "Cloud group inventory is ambiguous")
        values[group] = rows
    return values


def account_usage(asc, registration, now, window_start):
    start = timestamp(window_start)
    products = asc.pages("/v1/ciProducts?limit=200")
    ids = [uuid(product["id"]) for product in products]
    require(ids and len(ids) == len(set(ids)) and set(ids) == set(registration["account_product_ids"]),
            "Cloud account product coverage differs from reviewed inventory")
    counts = registration["account_action_destinations"]
    require(isinstance(counts, dict) and counts and all(isinstance(name, str) and type(count) is int
            and 0 < count <= 16 for name, count in counts.items()), "Cloud destination accounting is missing")
    reviewed = registration["account_workflow_attributes_sha256"]
    workflows = {}
    for product in products:
        for workflow in asc.pages("/v1/ciProducts/" + product["id"] + "/workflows?limit=200"):
            identifier = uuid(workflow["id"])
            require(identifier not in workflows, "duplicate Cloud account workflow")
            workflows[identifier] = groups.canonical_hash(workflow["attributes"])
    require(workflows and workflows == reviewed, "Cloud account workflow configuration changed")
    reserve = registration["unknown_active_minutes"]
    require(type(reserve) in {int, float} and math.isfinite(reserve) and reserve >= 110 * max(counts.values()) + 5,
            "unknown Cloud active work has no conservative reservation")
    runs, actions, elapsed, projected = set(), set(), 0, 0
    for product in products:
        for run in asc.pages("/v1/ciProducts/" + product["id"] + "/buildRuns?limit=200"):
            require(uuid(run["id"]) not in runs, "duplicate Cloud account run")
            runs.add(run["id"])
            attributes = run["attributes"]
            progress = attributes["executionProgress"]
            require(progress in {"PENDING", "RUNNING", "COMPLETE"}, "unknown Cloud account state")
            if progress == "COMPLETE" and attributes.get("finishedDate") is not None and timestamp(attributes["finishedDate"]) <= start:
                continue
            billable = asc.pages("/v1/ciBuildRuns/" + run["id"] + "/actions?limit=200")
            require(billable or progress == "PENDING", "Cloud account run has no actions")
            require(progress != "COMPLETE" or all(action["attributes"]["executionProgress"] == "COMPLETE" for action in billable),
                    "Cloud complete run contains unfinished actions")
            run_elapsed, destinations = 0, 0
            for action in billable:
                require(uuid(action["id"]) not in actions, "duplicate Cloud billable action")
                actions.add(action["id"])
                attributes = action["attributes"]
                require(attributes["name"] in counts, "Cloud account action lacks reviewed destination bound")
                count = counts[attributes["name"]]
                destinations += count
                run_elapsed += count * action_minutes(attributes, start, now)
            elapsed += run_elapsed
            if progress != "COMPLETE":
                projected += max(reserve, run_elapsed + 5 * max(1, destinations)) - run_elapsed
    return {"window_start": start.isoformat(), "minutes": elapsed + projected, "elapsed_minutes": elapsed,
            "projected_minutes": projected, "products": len(products), "actions": len(actions),
            "basis": "destination-wall-upper-bound"}


def unknown_starts(api, registration, inventory, *, current_uploader=None, history_snapshot=None, now=None):
    """Authenticate markers before bytes and recompute their reservation from admission."""
    now = now or datetime.now(timezone.utc)
    workflow, sources = history_snapshot or route_history(api)
    delay = visibility_delay(registration)
    require(set(inventory) == set(registration["groups"]), "Cloud reconciliation lacks a complete registered inventory")
    missing, visible = [], {row["id"] for rows in inventory.values() for row in rows}
    for source, artifacts in scheduling_attempts(api, sources, current_uploader=current_uploader):
        marker = state.receipt(api, artifacts, source, workflow, prefix=state.POST_PREFIX, member="post.json")
        if marker is None:
            continue
        started = state.receipt(api, artifacts, source, workflow, prefix=state.START_PREFIX, member="start.json")
        if started and started.get("cloud_run_id") in visible:
            continue
        if started and type(started.get("http_status")) is int and 400 <= started["http_status"] < 500:
            continue
        if started and started.get("schema_version") == 2 and started.get("post_attempted") is False:
            continue  # The authenticated main start refused before sending POST.
        group = marker.get("group", "tvos")
        require(group in inventory and marker["workflow_id"] == registration["groups"][group]["workflow_id"],
                "Cloud POST workflow has no complete reviewed inventory")
        rows = inventory[group]
        posted_at = (started or {}).get("posted_at", marker["posted_at"])
        matches = [row for row in rows
                   if (row["attributes"].get("sourceCommit") or {}).get("commitSha") == marker["head_sha"]
                   and -CLOCK_SKEW_SECONDS <= (timestamp(row["attributes"]["createdDate"]) - timestamp(posted_at)).total_seconds() <= 120]
        if len(matches) == 1:
            continue
        require(not matches, "Cloud unknown POST matches several builds")
        armed_at = timestamp(marker["posted_at"])
        deadline = timestamp(marker["start_deadline"]) if "start_deadline" in marker else armed_at + timedelta(minutes=state.START_TIMEOUT_MINUTES)
        require(armed_at <= deadline <= armed_at + timedelta(minutes=state.START_TIMEOUT_MINUTES),
                "Cloud POST start deadline differs from its bounded job")
        if now > deadline + timedelta(seconds=delay):
            # A complete refreshed inventory is negative evidence only after the
            # reviewed visibility bound. A late/unknown same-head row still blocks.
            possible = [row for row in rows if armed_at - timedelta(seconds=CLOCK_SKEW_SECONDS)
                        <= timestamp(row["attributes"]["createdDate"]) <= deadline + timedelta(seconds=delay)
                        and (row["attributes"].get("sourceCommit") or {}).get("commitSha") in {None, marker["head_sha"]}]
            require(not possible, "Cloud POST has a possible late build; absence is unproven")
            continue
        record = trusted_admissions(api, [positive(marker["producer_run_id"])]).get(marker["producer_run_id"])
        require(record is not None and record["identity"] == marker["identity"], "unknown POST has no matching trusted admission")
        run = api.repo("actions/runs/" + str(marker["producer_run_id"]))
        require(run["run_attempt"] >= marker["producer_attempt"] and run["head_sha"] == marker["head_sha"], "unknown POST producer differs")
        if marker.get("schema_version") == 2:
            run = dict(run, run_attempt=marker["producer_attempt"])
            descriptor = groups.selection(record, run, marker["group"], approved=False)
            require(marker["selection_sha256"] == groups.canonical_hash(descriptor)
                    and marker["workflow_id"] == descriptor["registration"]["workflow_id"], "unknown POST selection differs")
            reservation = cloud_estimate(descriptor, record["ui_inputs"]["base"]["selection"])["reservation_minutes"]
        else:
            reservation = 100
        missing.append({"uploader_run_id": source["id"], "uploader_attempt": source["run_attempt"], "minutes": reservation})
    return missing


def route_sources(api, workflow):
    remaining = api.request("/rate_limit")["resources"]["core"]["remaining"]
    require(type(remaining) is int and remaining > SCAN_RATE_RESERVE,
            "GitHub rate budget is too low for Cloud reconciliation")
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=RECONCILIATION_HOURS)).isoformat()
    rows, count = [], None
    for page in range(1, 11):
        query = urlencode({"event": "workflow_dispatch", "created": ">=" + cutoff, "per_page": 100, "page": page})
        response = api.repo(f"actions/workflows/{workflow['id']}/runs?" + query)
        total, batch = response["total_count"], response["workflow_runs"]
        require(type(total) is int and 0 <= total < 1000 and (count is None or count == total),
                "recent Cloud reconciliation run list is truncated or changed during pagination")
        count = total
        require(max(1, math.ceil(count / 100)) + SCAN_REQUESTS_UNMARKED * count + SCAN_RATE_RESERVE <= remaining,
                "GitHub rate budget cannot cover recent Cloud reconciliation runs")
        require(isinstance(batch, list) and len(batch) == min(100, max(0, count - len(rows))),
                "recent Cloud reconciliation run page is incomplete")
        rows.extend(batch)
        if len(rows) == count:
            require(len({positive(row["id"]) for row in rows}) == count, "recent Cloud reconciliation run list has duplicates")
            return rows
    require(False, "recent Cloud reconciliation pagination is incomplete")


def route_history(api):
    workflow = api.repo("actions/workflows/ci-xcode-cloud-route.yml")
    return workflow, route_sources(api, workflow)


def visibility_delay(registration):
    delay = registration.get("asc_visibility_delay_seconds")
    require(type(delay) is int and 60 <= delay <= 3600, "reviewed ASC inventory visibility delay is required")
    return delay


def scheduling_attempts(api, sources, *, current_uploader=None):
    """Run lists expose only the latest attempt; retained markers bind older ones."""
    if not sources:
        return
    remaining = api.request("/rate_limit")["resources"]["core"]["remaining"]
    require(type(remaining) is int and SCAN_REQUESTS_UNMARKED * len(sources) + SCAN_RATE_RESERVE <= remaining,
            "GitHub reconciliation rate budget is unavailable or too low")
    cost = 0
    for source in sources:
        latest = positive(source["run_attempt"])
        require(latest <= 100, "Cloud scheduling run has excessive attempts")
        artifacts = api.pages(f"actions/runs/{source['id']}/artifacts", "artifacts")
        attempts, marked = {latest}, set()
        for artifact in artifacts:
            match = re.fullmatch(r"ci-xcc-(?:post|start)-" + str(positive(source["id"])) + r"-([1-9][0-9]*)", artifact.get("name", ""))
            if match:
                attempt = int(match[1])
                require(attempt <= latest, "Cloud scheduling artifact refers to a future attempt")
                attempts.add(attempt)
                marked.add(attempt)
        for attempt in sorted(attempts):
            if current_uploader == (source["id"], attempt):
                continue
            cost += SCAN_REQUESTS_PER_ATTEMPT if attempt in marked else SCAN_REQUESTS_UNMARKED
            require(cost + SCAN_RATE_RESERVE <= remaining,
                    "recent Cloud scheduling attempts exceed the remaining rate budget")
            yield dict(source, run_attempt=attempt), artifacts


def group_started(api, run, group, *, current_uploader=None, history_snapshot=None):
    """Do not replay a selection, but allow a full rerun's new attempt."""
    workflow, sources = history_snapshot or route_history(api)
    title = f"xcc-route-{run['id']}-{run['run_attempt']}-{group}"
    matching = [source for source in sources if source.get("display_title") == title]
    for source, artifacts in scheduling_attempts(api, matching, current_uploader=current_uploader):
        for prefix, member in ((state.START_PREFIX, "start.json"), (state.POST_PREFIX, "post.json")):
            value = state.receipt(api, artifacts, source, workflow, prefix=prefix, member=member)
            if value is not None:
                require(value["producer_run_id"] == run["id"] and value["producer_attempt"] == run["run_attempt"]
                        and value["group"] == group and value["head_sha"] == run["head_sha"], "group start identity differs")
                return True
    return False


def prepare_group(api, asc_factory, run, group, *, mode="auto", sleep=time.sleep, monotonic=time.monotonic,
                  current_uploader=None, prepared=None):
    require(group in groups.GROUPS and mode in {"auto", "github", "force-start-failure"}, "invalid group routing input")
    current_producer(api, run)
    receipt = {"schema_version": 2, "identity": None, "head_sha": run["head_sha"], "producer_run_id": run["id"],
               "producer_attempt": run["run_attempt"], "group": group, "decision": "github", "reason": "admission-unavailable",
               "cloud_run_id": None, "control": {"mode": mode, "source": "workflow-dispatch"}}
    stage = "admission-unavailable"
    try:
        end = monotonic() + 300
        while True:
            record = trusted_admissions(api, [run["id"]]).get(run["id"])
            if record is not None:
                break
            require(monotonic() < end, "Cloud group admission did not arrive")
            sleep(15)
        receipt["identity"] = record["identity"]
        registration = (record.get("cloud_v2_inputs") or {}).get("registry") or {}
        if registration.get("routing_enabled") is not True or mode == "github":
            receipt["reason"] = "routing-inactive"
            return receipt
        stage = "cloud-registry-unavailable"
        descriptor = groups.selection(record, run, group, approved=False)
        receipt.update(workflow_id=descriptor["registration"]["workflow_id"], selection=descriptor,
                       selection_sha256=groups.canonical_hash(descriptor), runtime_plan_sha256=descriptor["runtime_plan_sha256"])
        selected_run = archive_evidence_run(api, run, selection_job=anchor(record, run))
        if selected_run["run_attempt"] != run["run_attempt"]:
            receipt["reason"] = "retained-selection-attempt"
            return receipt
        if selected_run["archive_job"]["status"] == "completed" and selected_run["archive_job"]["conclusion"] != "success":
            receipt["reason"] = "linux-selection-failed"
            return receipt
        if remaining_seconds(run, datetime.now(timezone.utc)) <= 0 or not selection_open(api, run, group):
            receipt["reason"] = "group-already-released"
            return receipt
        stage = "pointer-unavailable"
        while True:
            statuses = api.pages("commits/" + run["head_sha"] + "/statuses")
            matching = [status for status in statuses if status.get("context") == f"ci-xcc-selection/{run['id']}/{run['run_attempt']}/{group}"
                        and status.get("creator", {}).get("login") == groups.PUBLISHER_LOGIN
                        and status["creator"].get("id") == groups.PUBLISHER_ID]
            if matching:
                break
            require(monotonic() < end and selection_open(api, run, group), "group selection pointer did not arrive")
            refresh_producer(api, run)
            sleep(min(15, max(0, end - monotonic())))
        receipt["pointer_id"] = max(status["id"] for status in matching)
        groups.validate_pointer(record, run, group, receipt["selection_sha256"], statuses, pointer_id=receipt["pointer_id"])
        if prepared is not None:
            require(prepared["decision"] == "pending" and prepared["identity"] == receipt["identity"]
                    and prepared["selection_sha256"] == receipt["selection_sha256"]
                    and prepared["pointer_id"] == receipt["pointer_id"] and prepared["unresolved_starts"] == [],
                    "group preparation changed before POST")
        now = datetime.now(timezone.utc)
        selected = record["ui_inputs"]["base"]["selection"]
        stage = "github-queue-unavailable"
        receipt["capacity"] = queue_snapshot(api, now, selected, group, producer_run_id=run["id"], head_sha=run["head_sha"],
            base_sha=record["identity"]["base_sha"], ui_inputs=record["ui_inputs"]["base"],
            history=prepared["capacity"]["duration_history"] if prepared else None)
        if not receipt["capacity"]["can_prove_saturation"] or receipt["capacity"]["free_slots"]:
            receipt["reason"] = "github-capacity-or-queue-uncertain"
            return receipt
        stage = "cloud-budget-unavailable"
        require(isinstance(registration.get("billing_anchor"), dict) and "cap_minutes" in registration,
                "confirmed Cloud allowance and Apple billing anchor are required")
        require("queue_seconds_upper" in registration["groups"][group], "reviewed Cloud queue upper bound is required")
        visibility_delay(registration)
        policy = month_policy(now, registration["billing_anchor"], cap_minutes=registration["cap_minutes"])
        receipt["budget_policy"] = policy
        receipt["cloud_estimate"] = cloud_estimate(descriptor, selected,
            queue_seconds=registration["groups"][group]["queue_seconds_upper"])
        # A losing Cloud forecast needs no inventory or historical start reads.
        # Zero usage is optimistic for Cloud and can only refuse a possible start.
        early = choose_cloud(receipt["capacity"], receipt["cloud_estimate"], 0, policy)
        if not early["route"]:
            receipt.update(reason=early["reason"], estimate_decision=early)
            return receipt
        asc = asc_factory()
        stage = "cloud-inventory-unavailable"
        inventory = inventories(asc, registration)
        history_snapshot = route_history(api) if prepared is None else None
        if prepared is None and group_started(api, run, group, current_uploader=current_uploader, history_snapshot=history_snapshot):
            receipt["reason"] = "cloud-selection-already-started"
            return receipt
        if any(row["attributes"]["executionProgress"] != "COMPLETE" for row in inventory[group]):
            receipt["reason"] = "group-cloud-capacity-in-use"
            return receipt
        stage = "cloud-budget-unavailable"
        usage = [account_usage(asc, registration, now, start) for start, _ in policy["windows"]]
        unresolved = unknown_starts(api, registration, inventory, current_uploader=current_uploader,
            history_snapshot=history_snapshot, now=now) if prepared is None else []
        receipt.update(usage=usage, unresolved_starts=unresolved)
        if unresolved:
            receipt["reason"] = "unresolved-cloud-post"
            return receipt
        decision = choose_cloud(receipt["capacity"], receipt["cloud_estimate"], max(row["minutes"] for row in usage), policy)
        receipt["estimate_decision"] = decision
        if not decision["route"]:
            receipt["reason"] = decision["reason"]
            return receipt
        pr = refresh_producer(api, run)
        require(pr["user"]["login"] == groups.MAINTAINER_LOGIN and pr["user"]["id"] == groups.MAINTAINER_ID
                and pr["base"]["sha"] == record["identity"]["base_sha"],
                "group producer author or base moved")
        refs = asc.pages("/v1/scmRepositories/" + uuid(registration["scm_repository_id"]) + "/gitReferences?limit=200")
        refs = [ref for ref in refs if ref["attributes"].get("canonicalName") == "refs/heads/" + pr["head"]["ref"]]
        require(len(refs) == 1, "Cloud group branch is absent or ambiguous")
        receipt.update(decision="pending", reason="cloud-estimated-faster", reference_id=refs[0]["id"])
        return receipt
    except SupersededProducer:
        raise
    except FAILURES:
        receipt.update(decision="fallback", reason=stage)
        return receipt


def post_group(asc, prepared):
    """One POST only; an ambiguous result retains its authenticated marker."""
    reference = "invalid-reference" if prepared.get("control", {}).get("mode") == "force-start-failure" else prepared["reference_id"]
    try:
        response = asc.request("/v1/ciBuildRuns", method="POST", payload={"data": {"type": "ciBuildRuns", "attributes": {},
            "relationships": {"workflow": {"data": {"type": "ciWorkflows", "id": prepared["workflow_id"]}},
                              "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": reference}}}}})
    except FAILURES as error:
        status = re.search(r"HTTP ([0-9]{3})", str(error)) if isinstance(error, ContractError) else None
        rejected = bool(status and 400 <= int(status[1]) < 500)
        return {"decision": "fallback", "reason": "cloud-start-failed" if rejected else "start-outcome-unknown",
                "cloud_run_id": None, **({"http_status": int(status[1])} if status else {})}
    try:
        return build_receipt(asc, response["data"], "cloud-group-started")
    except FAILURES:
        return {"decision": "fallback", "reason": "start-outcome-unknown", "cloud_run_id": None}


def poll_group(api, asc, record, run, receipt, *, sleep=time.sleep, monotonic=time.monotonic):
    if receipt["decision"] in {"github", "fallback"}:
        return receipt
    from ci_xcode_cloud_client import transient
    value = dict(receipt)
    end = monotonic() + min(100 * 60, max(0, timestamp(receipt["cloud_created_at"]).timestamp()
                         + 100 * 60 - datetime.now(timezone.utc).timestamp()))
    try:
        while monotonic() < end:
            try:
                refresh_producer(api, run)
                require(selection_open(api, run, receipt["group"]), "group already released to GitHub")
                data = asc.request("/v1/ciBuildRuns/" + uuid(receipt["cloud_run_id"]))["data"]
                attributes = data["attributes"]
                if (attributes.get("sourceCommit") or {}).get("commitSha") is not None:
                    require(attributes["sourceCommit"]["commitSha"] == run["head_sha"], "Cloud branch advanced before checkout")
                if attributes["executionProgress"] == "COMPLETE":
                    value["terminal"] = True
                    require(attributes["completionStatus"] == "SUCCEEDED", "Cloud group build failed")
                    evidence = asc.evidence(receipt["cloud_run_id"], workflow_id=receipt["workflow_id"])
                    statuses = api.pages("commits/" + run["head_sha"] + "/statuses")
                    checks = api.pages("commits/" + run["head_sha"] + "/check-runs", "check_runs", filter="all")
                    # Cloud replaces in-progress checks with a new completed ID.
                    expected = {action["check_name"] for action in receipt["selection"]["registration"]["actions"]}
                    newest = {}
                    for check in checks:
                        if check.get("name") in expected and check.get("app", {}).get("id") == groups.legacy.APP_ID:
                            require(type(check.get("id")) is int, "Cloud app check has no ID")
                            if check["id"] > newest.get(check["name"], {}).get("id", 0):
                                newest[check["name"]] = check
                    ready = set(newest) == expected and all(check.get("status") == "completed"
                            and "/ci/builds/" + receipt["cloud_run_id"] + "/action/" in check.get("details_url", "")
                            for check in newest.values())
                    if ready:
                        groups.validate_evidence(record, run, dict(value, decision="routed"), evidence, checks, statuses, approved=False)
                        value.update(decision="routed", reason="cloud-group-population-completed")
                        return value
            except SupersededProducer:
                raise
            except FAILURES as error:
                if not transient(error):
                    raise
            sleep(min(60, max(0, end - monotonic())))
        raise ContractError("Cloud group timed out")
    except SupersededProducer:
        raise
    except FAILURES:
        value.update(decision="fallback", reason="cloud-group-evidence-unavailable")
        return value


def phase(api, asc, run, event, name, uploader, *, deadline=None):
    group = event["inputs"]["group"]
    require(group in groups.GROUPS, "unknown routing group")
    directory = Path(os.environ["RUNNER_TEMP"], "ci-xcc-route")
    if name == "prepare":
        value = prepare_group(api, lambda: asc, run, group, mode=event["inputs"].get("mode", "auto"))
        write_phase("prepared", dict(value, **uploader))
    elif name in {"arm", "start"}:
        value = json.loads((directory / "prepared.json").read_text())
        require(value["producer_run_id"] == run["id"] and value["producer_attempt"] == run["run_attempt"]
                and value["group"] == group, "group prepared identity differs")
        if value["decision"] == "pending" and name == "arm":
            require(deadline is not None, "Cloud marker requires its runner job deadline")
            pr = refresh_producer(api, run)
            require(pr["user"]["login"] == groups.MAINTAINER_LOGIN and pr["user"]["id"] == groups.MAINTAINER_ID
                    and pr["base"]["sha"] == value["identity"]["base_sha"]
                    and selection_open(api, run, group) and remaining_seconds(run, datetime.now(timezone.utc)) > 0,
                    "group changed before marker")
            groups.validate_pointer({"identity": value["identity"]}, run, group, value["selection_sha256"],
                api.pages("commits/" + run["head_sha"] + "/statuses"), pointer_id=value["pointer_id"])
            value["start_deadline"] = deadline.isoformat()
            # Seed refusal evidence before exposing the marker. Even a killed
            # start step can upload this record using the arm output alone.
            write_phase("start", dict(value, decision="github", reason="armed-before-post", post_attempted=False, cloud_run_id=None, **uploader))
            write_phase("post", dict(value, posted_at=datetime.now(timezone.utc).isoformat(), **uploader))
        if name == "start":
            if value["decision"] == "pending":
                started = json.loads((directory / "start.json").read_text())
                require(started.get("post_attempted") is False and all(started[key] == value[key]
                        for key in ("identity", "producer_run_id", "producer_attempt", "group", "selection_sha256"))
                        and all(started[key] == expected for key, expected in uploader.items()),
                        "Cloud POST lacks its armed unposted record or was already attempted")
            value["post_attempted"] = False
        if value["decision"] == "pending" and name == "start":
            try:
                # The whole job holds the account lock: other starts cannot add
                # historical markers between prepare and POST. Refresh only
                # mutable evidence, preserving the validated history snapshot.
                fresh = prepare_group(api, lambda: asc, run, group, mode=event["inputs"].get("mode", "auto"), prepared=value,
                    current_uploader=(uploader["uploader_run_id"], uploader["uploader_attempt"]))
                if fresh["decision"] == "pending":
                    require(all(fresh[key] == value[key] for key in ("identity", "selection_sha256", "pointer_id", "reference_id")),
                            "group changed before POST")
                value.update(fresh)
                if value["decision"] == "pending":
                    artifacts = api.pages(f"actions/runs/{uploader['uploader_run_id']}/artifacts", "artifacts")
                    marker = state.receipt(api, artifacts, {"id": uploader["uploader_run_id"], "run_attempt": uploader["uploader_attempt"]},
                        api.repo("actions/workflows/ci-xcode-cloud-route.yml"), prefix=state.POST_PREFIX, member="post.json")
                    require(marker is not None and all(marker[key] == value[key] for key in ("identity", "group", "selection_sha256", "pointer_id")),
                            "Cloud group POST marker differs")
                    value.update(post_attempted=True, posted_at=datetime.now(timezone.utc).isoformat())
                    # Persist before invoking the single POST. An unexpected
                    # exception after this point must never write a refund.
                    write_phase("start", dict(value, **uploader))
                    value.update(post_group(asc, value))
            except Exception:
                if value["post_attempted"]:
                    raise
                value.update(decision="github", reason="refused-before-post", cloud_run_id=None)
        if name == "arm":
            write_phase("prepared", dict(value, **uploader))
        else:
            write_phase("start", dict(value, **uploader))
    else:
        require(name == "poll", "unknown group phase")
        artifacts = api.pages(f"actions/runs/{uploader['uploader_run_id']}/artifacts", "artifacts")
        prepared = state.receipt(api, artifacts, {"id": uploader["uploader_run_id"], "run_attempt": uploader["uploader_attempt"]},
            api.repo("actions/workflows/ci-xcode-cloud-route.yml"), prefix=state.START_PREFIX, member="start.json")
        require(prepared is not None and prepared["group"] == group and prepared["producer_run_id"] == run["id"]
                and prepared["producer_attempt"] == run["run_attempt"], "group persisted start differs")
        record = trusted_admissions(api, [run["id"]]).get(run["id"])
        value = poll_group(api, asc, record, run, prepared)
        write_phase("route", dict(value, **uploader))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"recorded=true\nproducer_run_id={run['id']}\nproducer_attempt={run['run_attempt']}\ngroup={group}\n")
        if name in {"prepare", "arm"}:
            output.write("post=" + str(value["decision"] == "pending").lower() + "\n")
        if name == "start":
            output.write("start_recorded=true\npoll=" + str(value["decision"] == "pending" and bool(value["cloud_run_id"])).lower() + "\n")
    print(f"Cloud {group} {name}: {value['decision']} ({value['reason']})")
    return 0


def refuse_unposted_start(event, uploader):
    """Main-job local state also covers failures before the group phase begins."""
    directory = Path(os.environ["RUNNER_TEMP"], "ci-xcc-route")
    marker_path = directory / "post.json"
    if not marker_path.exists():
        return False
    marker = json.loads(marker_path.read_text())
    require(marker["schema_version"] == 2 and marker["producer_run_id"] == int(event["inputs"]["producer_run_id"])
            and marker["producer_attempt"] == int(event["inputs"]["producer_attempt"])
            and marker["group"] == event["inputs"]["group"]
            and all(marker[key] == value for key, value in uploader.items()), "local POST marker binding differs")
    start_path = directory / "start.json"
    started = json.loads(start_path.read_text()) if start_path.exists() else None
    if started is not None:
        require(all(started[key] == marker[key] for key in ("identity", "producer_run_id", "producer_attempt", "group", *uploader)),
                "local start binding differs")
    attempted = started is not None and started.get("post_attempted") is True
    if not attempted:
        write_phase("start", dict(marker, decision="github", reason="refused-before-post", post_attempted=False, cloud_run_id=None))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write("start_recorded=true\npoll=false\n")
    return not attempted
