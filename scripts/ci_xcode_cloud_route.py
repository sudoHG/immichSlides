#!/usr/bin/env python3
"""Main-context congestion routing; any uncertainty leaves Apple TV on GitHub."""

from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import URLError

from ci_publish import GitHub, authoritative_run, map_pr, trusted_admissions, verify_workflow
from ci_summary import ContractError, require
from ci_xcode_cloud import (IMPORT_PATH, ROUTE_PATH, UI_PATH, WORKFLOW_ID, admitted_population,
                            trusted_artifact, trusted_cloud, uuid, validate_evidence)
from ci_xcode_cloud_api import AppStoreConnect, credential_context, jwt

ROUTING_ENABLED = True
CAP_MINUTES = 45 * 60
MAC_RUNNING_THRESHOLD = 5
QUEUE_SECONDS = 120
SCM_REPOSITORY_ID = "894b3bbd-682b-454d-b797-0b7f63a2dd73"


def timestamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        require(parsed.utcoffset() is not None, "missing UTC offset")
        return parsed.astimezone(timezone.utc)
    except (AttributeError, ValueError, TypeError):
        raise ContractError("invalid routing timestamp") from None


def congestion(jobs, now):
    running, old_queue = set(), set()
    for job in jobs:
        labels = job["labels"]
        require(isinstance(labels, list) and all(isinstance(label, str) for label in labels), "missing job runner labels")
        mac = "xcode-27" in labels or any(label.startswith("macos-") for label in labels)
        if not mac:
            continue
        if job["status"] == "in_progress":
            running.add(job["id"])
        elif job["status"] == "queued" and (now - timestamp(job["created_at"])).total_seconds() >= QUEUE_SECONDS:
            old_queue.add(job["id"])
    return {"congested": len(running) >= MAC_RUNNING_THRESHOLD and bool(old_queue),
            "running_mac_jobs": len(running), "old_queued_mac_jobs": len(old_queue),
            "running_threshold": MAC_RUNNING_THRESHOLD, "queue_seconds": QUEUE_SECONDS}


def github_capacity(api, now):
    runs = {}
    for status in ("queued", "in_progress"):
        for run in api.pages("actions/runs", "workflow_runs", status=status):
            runs[run["id"]] = run
    jobs = []
    for run in runs.values():
        jobs.extend(api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs"))
    return congestion(jobs, now)


def action_minutes(attributes, month_start, now):
    started, finished = attributes.get("startedDate"), attributes.get("finishedDate")
    progress = attributes.get("executionProgress")
    if started is None:
        require(progress == "PENDING" and finished is None, "cloud usage has unknown action timing")
        return 0
    start = timestamp(started)
    if finished is None:
        require(progress == "RUNNING", "completed cloud action lacks finished timestamp")
        end = now
    else:
        require(progress == "COMPLETE", "cloud action timing disagrees with completion")
        end = timestamp(finished)
    require(start <= end <= now, "cloud action has reversed or future timing")
    return max(0, (end - max(start, month_start)).total_seconds()) / 60


def month_usage(asc, now):
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    actions, runs = {}, set()
    products = asc.pages("/v1/ciProducts?limit=200")
    require(products, "cloud usage product inventory is empty")
    for product in products:
        uuid(product["id"])
        for run in asc.pages("/v1/ciProducts/" + product["id"] + "/buildRuns?limit=200"):
            require(run["id"] not in runs, "duplicate cloud run across products")
            runs.add(run["id"])
            # A run that started in a prior month may have billable actions now.
            # Inspect every action, including failed and currently running work.
            billable = asc.pages("/v1/ciBuildRuns/" + uuid(run["id"]) + "/actions?limit=200")
            require(billable or run["attributes"]["executionProgress"] == "PENDING",
                    "active or completed cloud run has no action inventory")
            for action in billable:
                require(action["id"] not in actions, "duplicate cloud billable action")
                actions[action["id"]] = action_minutes(action["attributes"], month_start, now)
    return {"month": month_start.strftime("%Y-%m"), "minutes": sum(actions.values()),
            "cap_minutes": CAP_MINUTES, "products": len(products), "actions": len(actions)}


def producer_decision(api, record, run, *, approved):
    try:
        route, _ = trusted_artifact(api, f"ci-xcc-route-{run['id']}-{run['run_attempt']}", ROUTE_PATH, "route.json")
        if route["decision"] != "routed":
            return "github"
        trusted_cloud(api, record, run, approved=approved)
        return "routed"
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError):
        return "github"


def current_producer(api, run):
    workflow = api.repo("actions/workflows/ci-ui.yml")
    verify_workflow(run, workflow, api.repository)
    require(run["path"] == UI_PATH and run["event"] == "pull_request"
            and run["head_repository"]["full_name"] == api.repository, "router refuses forks and main pushes")
    pr = map_pr(api, run)
    candidates = api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs", head_sha=run["head_sha"], event="pull_request")
    candidates = [candidate for candidate in candidates if (not candidate.get("pull_requests")
                  or any(item["number"] == pr["number"] for item in candidate["pull_requests"]))
                  and candidate["head_repository"]["full_name"] == api.repository]
    current = authoritative_run(candidates, run["head_sha"], workflow, api.repository)
    require(current is not None and current["id"] == run["id"] and current["run_attempt"] == run["run_attempt"],
            "router producer is not authoritative")
    require(run["status"] != "completed" and api.repo("actions/runs/" + str(run["id"]))["run_attempt"] == run["run_attempt"],
            "router producer already completed or reran")
    return pr


def refresh_producer(api, run):
    fresh = api.repo("actions/runs/" + str(run["id"]))
    require(all(fresh[key] == run[key] for key in ("id", "run_attempt", "head_sha")),
            "cloud producer head or attempt changed during routing")
    return current_producer(api, fresh)


def route_run(api, asc_factory, run, *, mode="auto", sleep=time.sleep, monotonic=time.monotonic):
    pr = current_producer(api, run)
    # Admission is immutable and can arrive shortly after workflow_run requested.
    deadline = monotonic() + 300
    while True:
        records = trusted_admissions(api, [run["id"]])
        if run["id"] in records:
            break
        require(monotonic() < deadline, "cloud routing admission did not arrive")
        sleep(15)
    record = records[run["id"]]
    receipt = {"schema_version": 1, "identity": record["identity"], "producer_run_id": run["id"],
               "producer_attempt": run["run_attempt"], "decision": "github", "reason": "routing-disabled",
               "workflow_id": WORKFLOW_ID, "plan_sha256": (record.get("cloud_inputs") or {}).get("plan_sha256"),
               "cloud_run_id": None}
    if not ROUTING_ENABLED or mode == "github":
        return receipt
    stage = "invalid-admission"
    try:
        inputs = record["cloud_inputs"]
        require(inputs is not None and inputs["head_tree_sha"] == record["identity"]["tree_sha"], "head/merge tree mismatch")
        # Both admissible policies are checked by the importer/publication reader;
        # a changed population cannot route merely by shrinking the cloud plan.
        admitted_population(record, approved=False)
        now = datetime.now(timezone.utc)
        stage = "github-capacity-unavailable"
        receipt["capacity"] = github_capacity(api, now)
        if not receipt["capacity"]["congested"]:
            receipt["reason"] = "github-capacity-available"
            return receipt
        asc = asc_factory()
        stage = "cloud-usage-unavailable"
        receipt["usage"] = month_usage(asc, now)
        if receipt["usage"]["minutes"] >= CAP_MINUTES:
            receipt["reason"] = "monthly-cap-reached"
            return receipt
        refresh_producer(api, run)
        stage = "cloud-branch-unavailable"
        refs = asc.pages("/v1/scmRepositories/" + SCM_REPOSITORY_ID + "/gitReferences?limit=200")
        refs = [ref for ref in refs if ref["attributes"].get("canonicalName") == "refs/heads/" + pr["head"]["ref"]]
        require(len(refs) == 1, "cloud branch is absent or ambiguous")
        # This main-only diagnostic exercises a real rejected API start request;
        # it cannot create a valid run or cause a producer to skip Apple TV.
        reference = "invalid-reference" if mode == "force-start-failure" else refs[0]["id"]
        stage = "cloud-start-failed"
        response = asc.request("/v1/ciBuildRuns", method="POST", payload={"data": {
            "type": "ciBuildRuns", "attributes": {}, "relationships": {
                "workflow": {"data": {"type": "ciWorkflows", "id": WORKFLOW_ID}},
                "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": reference}}}}})
        require(mode != "force-start-failure", "forced API start unexpectedly accepted")
        cloud_id = uuid(response["data"]["id"])
        receipt["cloud_run_id"] = cloud_id
        stage = "cloud-run-failed-or-timed-out"
        deadline, refreshed = monotonic() + 100 * 60, monotonic()
        while monotonic() < deadline:
            if monotonic() - refreshed >= 8 * 60:
                asc, refreshed = asc_factory(), monotonic()
            attributes = asc.request("/v1/ciBuildRuns/" + cloud_id)["data"]["attributes"]
            commit = attributes.get("sourceCommit", {}).get("commitSha")
            if commit is not None:
                require(commit == run["head_sha"], "cloud branch advanced before start")
            if attributes.get("executionProgress") == "COMPLETE":
                require(attributes.get("completionStatus") == "SUCCEEDED", "cloud run failed")
                refresh_producer(api, run)
                stage = "cloud-population-or-app-check-refused"
                evidence = asc.evidence(cloud_id)
                checks = api.pages("commits/" + run["head_sha"] + "/check-runs", "check_runs", filter="all")
                # A short app-check propagation delay retains GitHub fallback;
                # it never relaxes the completed/successful check requirement.
                if not any(check.get("name") == "immichSlides | UI - Apple TV (overflow) | XcodeCloud-UI-tvOS - tvOS"
                           and check.get("status") == "completed" for check in checks):
                    sleep(30)
                    continue
                validate_evidence(record, run, dict(receipt, decision="routed"), evidence, checks, approved=False)
                receipt.update(decision="routed", reason="cloud-run-and-population-completed")
                return receipt
            sleep(30)
        raise ContractError("cloud run deadline exceeded")
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError) as error:
        receipt.update(decision="fallback", reason=stage)
        status = re.search(r"HTTP ([0-9]{3})", str(error)) if isinstance(error, ContractError) else None
        if status:
            receipt["http_status"] = int(status[1])
        return receipt


def main():
    try:
        credential_context(os.environ, ROUTE_PATH)
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        api = GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["CI_WORKFLOW_TOKEN"])
        mode = event.get("inputs", {}).get("mode", "auto")
        require(mode in {"auto", "github", "force-start-failure"}, "invalid route diagnostic mode")
        run_id = event.get("inputs", {}).get("producer_run_id") if "inputs" in event else str(event["workflow_run"]["id"])
        require(isinstance(run_id, str) and run_id.isdecimal() and 0 < int(run_id) < 10**15, "invalid producer ID")
        run = api.repo("actions/runs/" + run_id)
        verify_workflow(run, api.repo("actions/workflows/ci-ui.yml"), api.repository)
        existing = api.pages("actions/artifacts", "artifacts", name=f"ci-xcc-route-{run['id']}-{run['run_attempt']}")
        workflow = api.repo("actions/workflows/ci-xcode-cloud-route.yml")
        for artifact in existing:
            if artifact["expired"] or artifact["name"] != f"ci-xcc-route-{run['id']}-{run['run_attempt']}":
                continue
            uploader = api.repo("actions/runs/" + str(artifact["workflow_run"]["id"]))
            if uploader["path"] == ROUTE_PATH and uploader["workflow_id"] == workflow["id"] and uploader["head_branch"] == "main":
                decision, _ = trusted_artifact(api, artifact["name"], ROUTE_PATH, "route.json")
                require(decision["producer_run_id"] == run["id"] and decision["producer_attempt"] == run["run_attempt"]
                        and decision["identity"]["head_sha"] == run["head_sha"], "existing decision differs from producer")
                print("Cloud routing decision is already immutable; no second start or artifact")
                return 0
        # The API client is created only after same-repository PR admission.
        receipt = route_run(api, lambda: AppStoreConnect(jwt(os.environ, ROUTE_PATH)), run, mode=mode)
        receipt.update(uploader_run_id=int(os.environ["GITHUB_RUN_ID"]), uploader_attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]))
        directory = Path(os.environ["RUNNER_TEMP"], "ci-xcc-route")
        directory.mkdir(mode=0o700, exist_ok=False)
        (directory / "route.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"recorded=true\nproducer_run_id={receipt['producer_run_id']}\nproducer_attempt={receipt['producer_attempt']}\n")
        print("Apple TV routing decision: " + receipt["decision"] + " (" + receipt["reason"] + ")")
        return 0
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError):
        print("Cloud router refused this source; GitHub Apple TV remains required", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
