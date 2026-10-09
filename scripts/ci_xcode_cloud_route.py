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

from ci_publish import authoritative_run, map_pr, trusted_admissions, verify_workflow
from ci_summary import ContractError, require
from ci_xcode_cloud import (IMPORT_PATH, ROUTE_PATH, UI_PATH, WORKFLOW_ID, admitted_population,
                            trusted_artifact, trusted_cloud, uuid, validate_evidence)
from ci_xcode_cloud_api import credential_context, jwt
import ci_xcode_cloud_state as state
from ci_xcode_cloud_client import RenewingAppStoreConnect, RetryingGitHub

ROUTING_ENABLED = True
CAP_MINUTES = 45 * 60
MAC_RUNNING_THRESHOLD = 5
QUEUE_SECONDS = 120
CLOUD_MINUTES = 100
IMPORT_MINUTES = 10
START_WINDOW_MINUTES = 30
FULL_PLAN_MINUTES = 69
WAIT_FACTOR = 1.3
MAX_BUILD_LIFE_MINUTES = 180
SCM_REPOSITORY_ID = "894b3bbd-682b-454d-b797-0b7f63a2dd73"


class SupersededProducer(ContractError):
    pass


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
        never_started = progress == "COMPLETE" and attributes.get("completionStatus") in {"SKIPPED", "CANCELED"}
        require(never_started or progress == "PENDING" and finished is None, "cloud usage has unknown action timing")
        if finished is not None:
            require(timestamp(finished) <= now, "cloud action has future timing")
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


def overflow_inventory(asc):
    runs = asc.pages("/v1/ciWorkflows/" + WORKFLOW_ID + "/buildRuns?limit=200")
    require(len({uuid(run["id"]) for run in runs}) == len(runs), "duplicate overflow build inventory")
    require(all(run["attributes"]["executionProgress"] in {"PENDING", "RUNNING", "COMPLETE"} for run in runs),
            "overflow inventory has unknown build state")
    return runs


def existing_build(inventory, head):
    matches = [run for run in inventory if (run["attributes"].get("sourceCommit") or {}).get("commitSha") == head]
    return max(matches, key=lambda run: timestamp(run["attributes"]["createdDate"])) if matches else None


def blocking_builds(inventory, now):
    return [run for run in inventory if run["attributes"]["executionProgress"] != "COMPLETE"
            and (now - timestamp(run["attributes"]["createdDate"])).total_seconds() < MAX_BUILD_LIFE_MINUTES * 60]


def month_usage(asc, now, *, inventory=None):
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    inventory = overflow_inventory(asc) if inventory is None else inventory
    actions, runs = {}, set()
    projected = sum(CLOUD_MINUTES for run in inventory if run["attributes"]["executionProgress"] != "COMPLETE")
    products = asc.pages("/v1/ciProducts?limit=200")
    require(products, "cloud usage product inventory is empty")
    for product in products:
        uuid(product["id"])
        for run in asc.pages("/v1/ciProducts/" + product["id"] + "/buildRuns?limit=200"):
            require(run["id"] not in runs, "duplicate cloud run across products")
            runs.add(run["id"])
            attributes = run["attributes"]
            progress = attributes["executionProgress"]
            require(progress in {"PENDING", "RUNNING", "COMPLETE"}, "cloud usage has unknown run state")
            finished = attributes.get("finishedDate")
            if progress == "COMPLETE" and finished is not None and timestamp(finished) <= month_start:
                continue
            # Completed actions, including failed work, are billed even when
            # their parent build is still active. Active overflow builds add a
            # separate fixed projection, including builds too old to block.
            billable = asc.pages("/v1/ciBuildRuns/" + uuid(run["id"]) + "/actions?limit=200")
            require(billable or run["attributes"]["executionProgress"] == "PENDING",
                    "active or completed cloud run has no action inventory")
            for action in billable:
                require(action["id"] not in actions, "duplicate cloud billable action")
                attributes = action["attributes"]
                minutes = action_minutes(attributes, month_start, now)
                actions[action["id"]] = minutes if attributes["executionProgress"] == "COMPLETE" else 0
    return {"month": month_start.strftime("%Y-%m"), "minutes": sum(actions.values()) + projected,
            "projected_minutes": projected,
            "cap_minutes": CAP_MINUTES, "products": len(products), "actions": len(actions)}


def producer_decision(api, record, run, *, approved, evidence_attempt=None, route_seen=False, transient_errors=False):
    try:
        from ci_xcode_cloud import archive_evidence_run
        evidence_run = archive_evidence_run(api, run) if evidence_attempt is None else dict(run, run_attempt=evidence_attempt)
        if not route_seen:
            route, _ = trusted_artifact(api, f"ci-xcc-route-{run['id']}-{evidence_run['run_attempt']}", ROUTE_PATH, "route.json")
            if route["decision"] != "routed":
                return "github"
        trusted_cloud(api, record, run, approved=approved, evidence_attempt=evidence_run["run_attempt"])
        return "routed"
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError) as error:
        from ci_xcode_cloud_client import transient
        if transient_errors and transient(error):
            raise
        return "github"


def current_producer(api, run):
    workflow = api.repo("actions/workflows/ci-ui.yml")
    verify_workflow(run, workflow, api.repository)
    require(run["path"] == UI_PATH and run["event"] == "pull_request"
            and run["head_repository"]["full_name"] == api.repository, "router refuses forks and main pushes")
    try:
        pr = map_pr(api, run, current=False)
    except ContractError as error:
        if str(error) == "producer has no unique current PR mapping":
            raise SupersededProducer("cloud producer PR is no longer current") from None
        raise
    if pr["head"]["sha"] != run["head_sha"]:
        raise SupersededProducer("cloud producer head was superseded")
    candidates = api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs", head_sha=run["head_sha"], event="pull_request")
    candidates = [candidate for candidate in candidates if (not candidate.get("pull_requests")
                  or any(item["number"] == pr["number"] for item in candidate["pull_requests"]))
                  and candidate["head_repository"]["full_name"] == api.repository]
    current = authoritative_run(candidates, run["head_sha"], workflow, api.repository)
    if current is None or current["id"] != run["id"] or current["run_attempt"] != run["run_attempt"]:
        raise SupersededProducer("router producer is not authoritative")
    if run["status"] == "completed" or api.repo("actions/runs/" + str(run["id"]))["run_attempt"] != run["run_attempt"]:
        raise SupersededProducer("router producer already completed or reran")
    return pr


def refresh_producer(api, run):
    fresh = api.repo("actions/runs/" + str(run["id"]))
    if not all(fresh[key] == run[key] for key in ("id", "run_attempt", "head_sha")):
        raise SupersededProducer("cloud producer head or attempt changed during routing")
    return current_producer(api, fresh)


def routing_control(mode, head, override):
    require(mode in {"auto", "github", "force-start-failure"}, "invalid route mode")
    control = {"source": "workflow-dispatch" if mode != "auto" else "automatic", "mode": mode}
    if mode == "auto" and override:
        match = re.fullmatch(r"([0-9a-f]{40}):(force-congestion|github|force-start-failure)", override)
        require(match is not None, "invalid trusted routing override")
        if match[1] == head:
            control = {"source": "repository-variable", "mode": match[2]}
    return control


def remaining_seconds(run, now):
    return max(0, START_WINDOW_MINUTES * 60 -
               (now - timestamp(run.get("run_started_at") or run["created_at"])).total_seconds())


def cloud_wait_deadline(cloud_created):
    duration = (WAIT_FACTOR * FULL_PLAN_MINUTES + IMPORT_MINUTES) * 60
    return cloud_created + duration


def selection_open(api, run):
    jobs = api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs")
    return not any(job["name"] == "ui-cloud-wait" and job["status"] == "completed" for job in jobs)


def route_run(api, asc_factory, run, *, mode="auto", override="", sleep=time.sleep, monotonic=time.monotonic):
    """Decide from the ASC build inventory under the short account lock."""
    current_producer(api, run)
    receipt = {"schema_version": 1, "identity": None, "head_sha": run["head_sha"],
               "producer_run_id": run["id"], "producer_attempt": run["run_attempt"],
               "decision": "github", "reason": "admission-unavailable",
               "workflow_id": WORKFLOW_ID, "plan_sha256": None, "cloud_run_id": None}
    stage = "admission-unavailable"
    try:
        deadline = monotonic() + 300
        while True:
            records = trusted_admissions(api, [run["id"]])
            if run["id"] in records:
                break
            require(monotonic() < deadline, "cloud routing admission did not arrive")
            sleep(15)
        record = records[run["id"]]
        receipt.update(identity=record["identity"], plan_sha256=(record.get("cloud_inputs") or {}).get("plan_sha256"))
        stage = "invalid-routing-control"
        receipt["control"] = routing_control(mode, run["head_sha"], override)
        mode = receipt["control"]["mode"]
        if not ROUTING_ENABLED or mode == "github":
            receipt["reason"] = "routing-disabled"
            return receipt
        if record["classification"].get("app_affected") is not True:
            receipt["reason"] = "trusted-app-unaffected"
            return receipt
        stage = "invalid-admission"
        from ci_xcode_cloud import archive_evidence_run
        evidence_run = archive_evidence_run(api, run)
        if evidence_run["run_attempt"] != run["run_attempt"]:
            receipt["reason"] = "retained-archive-selection"
            return receipt
        archive = evidence_run["archive_job"]
        if archive["status"] == "completed" and archive["conclusion"] != "success":
            receipt["reason"] = "archive-selection-failed"
            return receipt
        inputs = record["cloud_inputs"]
        require(inputs is not None and inputs["head_tree_sha"] == record["identity"]["tree_sha"], "head/merge tree mismatch")
        admitted_population(record, approved=False)
        now = datetime.now(timezone.utc)
        if remaining_seconds(run, now) <= 0 or not selection_open(api, run):
            receipt["reason"] = "producer-selection-too-late"
            return receipt
        stage = "github-capacity-unavailable"
        receipt["capacity"] = github_capacity(api, now)
        if mode == "auto" and not receipt["capacity"]["congested"]:
            receipt["reason"] = "github-capacity-available"
            return receipt
        asc = asc_factory()
        stage = "cloud-inventory-unavailable"
        inventory = overflow_inventory(asc)
        existing = existing_build(inventory, run["head_sha"])
        if existing is not None:
            receipt.update(build_receipt(asc, existing, "resumed-existing-build"))
            return receipt
        if blocking_builds(inventory, now):
            receipt["reason"] = "overflow-build-in-flight"
            return receipt
        stage = "cloud-usage-unavailable"
        receipt["usage"] = month_usage(asc, now, inventory=inventory)
        if receipt["usage"]["minutes"] + CLOUD_MINUTES > CAP_MINUTES:
            receipt["reason"] = "monthly-cap-reached"
            return receipt
        refresh_producer(api, run)
        if remaining_seconds(run, datetime.now(timezone.utc)) <= 0 or not selection_open(api, run):
            receipt["reason"] = "producer-selection-too-late"
            return receipt
        stage = "cloud-branch-unavailable"
        pr = current_producer(api, run)
        refs = asc.pages("/v1/scmRepositories/" + SCM_REPOSITORY_ID + "/gitReferences?limit=200")
        refs = [ref for ref in refs if ref["attributes"].get("canonicalName") == "refs/heads/" + pr["head"]["ref"]]
        require(len(refs) == 1, "cloud branch is absent or ambiguous")
        receipt.update(decision="pending", reason="inventory-allows-start", reference_id=refs[0]["id"])
        return receipt
    except SupersededProducer:
        raise
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError):
        receipt.update(decision="fallback", reason=stage)
        return receipt


def build_receipt(asc, build, reason):
    run_id = uuid(build["id"])
    created = build.get("attributes", {}).get("createdDate")
    if created is None:
        fetched = asc.request("/v1/ciBuildRuns/" + run_id)["data"]
        require(fetched["id"] == run_id, "cloud build metadata has another run")
        created = fetched["attributes"]["createdDate"]
    timestamp(created)
    return {"decision": "pending", "reason": reason, "cloud_run_id": run_id, "cloud_created_at": created}


def start_cloud(asc, prepared, *, before_post=lambda: None):
    """Recheck ASC inventory; issue at most one POST in this router run."""
    inventory = overflow_inventory(asc)
    existing = existing_build(inventory, prepared["identity"]["head_sha"])
    if existing is not None:
        return build_receipt(asc, existing, "resumed-existing-build")
    now = datetime.now(timezone.utc)
    if blocking_builds(inventory, now):
        return {"decision": "github", "reason": "overflow-build-in-flight", "cloud_run_id": None}
    if month_usage(asc, now, inventory=inventory)["minutes"] + CLOUD_MINUTES > CAP_MINUTES:
        return {"decision": "github", "reason": "monthly-cap-reached", "cloud_run_id": None}
    reference = ("invalid-reference" if prepared.get("control", {}).get("mode") == "force-start-failure"
                 else prepared["reference_id"])
    try:
        before_post()
    except SupersededProducer:
        raise
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError):
        return {"decision": "fallback", "reason": "producer-selection-too-late", "cloud_run_id": None}
    try:
        response = asc.request("/v1/ciBuildRuns", method="POST", payload={"data": {
            "type": "ciBuildRuns", "attributes": {}, "relationships": {
                "workflow": {"data": {"type": "ciWorkflows", "id": WORKFLOW_ID}},
                "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": reference}}}}})
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError) as error:
        status = re.search(r"HTTP ([0-9]{3})", str(error)) if isinstance(error, ContractError) else None
        rejected = bool(status and 400 <= int(status[1]) < 500)
        return {"decision": "fallback" if rejected else "pending", "reason": "cloud-start-failed" if rejected else "start-outcome-unknown",
                "cloud_run_id": None,
                **({"http_status": int(status[1])} if status else {})}
    # A metadata GET failure after an accepted POST is not a rejected start.
    return build_receipt(asc, response["data"], "cloud-started")


def latest_check_ready(checks, head, cloud_id):
    from ci_xcode_cloud import APP_ID, CHECK_NAME
    matching = [check for check in checks if check.get("app", {}).get("id") == APP_ID
                and check.get("name") == CHECK_NAME and check.get("head_sha") == head]
    if not matching or any(type(check.get("id")) is not int for check in matching):
        return False
    newest = max(check["id"] for check in matching)
    matching = [check for check in matching if check["id"] == newest]
    return (len(matching) == 1 and matching[0].get("status") == "completed"
            and "/ci/builds/" + cloud_id + "/action/" in matching[0].get("details_url", ""))


def poll_route(api, asc, record, run, receipt, *, sleep=time.sleep, monotonic=time.monotonic):
    """Poll the producer build; a failed read round has no conclusion."""
    if receipt["decision"] in {"github", "fallback"}:
        return receipt
    receipt = dict(receipt)
    deadline = monotonic() + CLOUD_MINUTES * 60
    stage = "cloud-start-outcome-unknown"
    try:
        while monotonic() < deadline:
            try:
                refresh_producer(api, run)
                require(selection_open(api, run), "producer already chose GitHub")
                if receipt.get("cloud_run_id") is None:
                    existing = existing_build(overflow_inventory(asc), run["head_sha"])
                    if existing is not None:
                        receipt.update(build_receipt(asc, existing, "resumed-existing-build"))
                if receipt.get("cloud_run_id") is not None:
                    stage = "cloud-run-failed-or-timed-out"
                    attributes = asc.request("/v1/ciBuildRuns/" + uuid(receipt["cloud_run_id"]))["data"]["attributes"]
                    commit = (attributes.get("sourceCommit") or {}).get("commitSha")
                    if commit is not None:
                        require(commit == run["head_sha"], "cloud branch advanced before start")
                    if attributes.get("executionProgress") == "COMPLETE":
                        receipt["terminal"] = True
                        require(attributes.get("completionStatus") == "SUCCEEDED", "cloud run failed")
                        stage = "cloud-population-or-app-check-refused"
                        evidence = asc.evidence(receipt["cloud_run_id"])
                        checks = api.pages("commits/" + run["head_sha"] + "/check-runs", "check_runs", filter="all")
                        if latest_check_ready(checks, run["head_sha"], receipt["cloud_run_id"]):
                            validate_evidence(record, run, dict(receipt, decision="routed"), evidence, checks, approved=False)
                            receipt.update(decision="routed", reason="cloud-run-and-population-completed")
                            return receipt
            except SupersededProducer:
                raise
            except (ContractError, KeyError, TypeError, ValueError, OSError, URLError) as error:
                from ci_xcode_cloud_client import transient
                if not transient(error):
                    raise
            print("Cloud poll has no conclusion; waiting for the next round", flush=True)
            sleep(min(120, max(0, deadline - monotonic())))
        raise ContractError("cloud run deadline exceeded")
    except SupersededProducer:
        raise
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError):
        receipt.update(decision="fallback", reason=stage)
        return receipt


def write_phase(phase, value):
    directory = Path(os.environ["RUNNER_TEMP"], "ci-xcc-route")
    directory.mkdir(mode=0o700, exist_ok=True)
    (directory / (phase + ".json")).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    return value


def recorded_decision(api, run):
    try:
        value, _ = trusted_artifact(api, f"ci-xcc-route-{run['id']}-{run['run_attempt']}", ROUTE_PATH, "route.json")
        return (value.get("producer_run_id") == run["id"] and value.get("producer_attempt") == run["run_attempt"]
                and value.get("head_sha") == run["head_sha"] and value.get("decision") in {"github", "fallback", "routed"})
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError):
        return False


def main():
    try:
        phase = sys.argv[1]
        require(len(sys.argv) == 2 and phase in {"prepare", "arm", "start", "poll"}, "invalid router phase")
        credential_context(os.environ, ROUTE_PATH)
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        from ci_publish import git, positive
        run_id = event["inputs"]["producer_run_id"]
        attempt = event["inputs"]["producer_attempt"]
        require(isinstance(run_id, str) and run_id.isdecimal() and isinstance(attempt, str) and attempt.isdecimal(), "invalid producer input")
        run_id, attempt = positive(int(run_id)), positive(int(attempt))
        phase_minutes = 109 if phase == "poll" else 19
        api = RetryingGitHub(os.environ["GITHUB_REPOSITORY"], os.environ["CI_WORKFLOW_TOKEN"], time.monotonic() + phase_minutes * 60)
        git("fetch", "--no-tags", "origin", "refs/heads/main")
        run = api.repo("actions/runs/" + str(run_id))
        if run["run_attempt"] != attempt:
            raise SupersededProducer("router producer attempt changed")
        verify_workflow(run, api.repo("actions/workflows/ci-ui.yml"), api.repository)
        uploader = {"uploader_run_id": int(os.environ["GITHUB_RUN_ID"]), "uploader_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"])}
        asc = RenewingAppStoreConnect(lambda: jwt(os.environ, ROUTE_PATH), time.monotonic() + phase_minutes * 60)
        directory = Path(os.environ["RUNNER_TEMP"], "ci-xcc-route")
        if phase in {"prepare", "poll"} and recorded_decision(api, run):
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write("recorded=false\npost=false\n")
            print("Existing trusted decision retained; no duplicate start or receipt")
            return 0
        if phase == "prepare":
            value = route_run(api, lambda: asc, run, mode=event["inputs"].get("mode", "auto"),
                              override=os.environ.get("CI_XCC_ROUTING_OVERRIDE", ""))
            write_phase("prepared", dict(value, **uploader))
            value.update(uploader)
        elif phase in {"arm", "start"}:
            prepared = json.loads((directory / "prepared.json").read_text())
            require(prepared["producer_run_id"] == run_id and prepared["producer_attempt"] == attempt, "prepared producer differs")
            value = dict(prepared)
            if prepared["decision"] == "pending":
                needs_post = prepared.get("cloud_run_id") is None
                def before_post():
                    refresh_producer(api, run)
                    require(selection_open(api, run) and remaining_seconds(run, datetime.now(timezone.utc)) > 0,
                            "producer selection expired before POST")
                if phase == "arm":
                    if needs_post:
                        before_post()
                        write_phase("post", dict(prepared, posted_at=datetime.now(timezone.utc).isoformat()))
                    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                        output.write("post=" + str(needs_post).lower() + "\n")
                    return 0
                try:
                    before_post()
                    if needs_post:
                        artifacts = api.pages(f"actions/runs/{uploader['uploader_run_id']}/artifacts", "artifacts")
                        marker = state.receipt(api, artifacts, {"id": uploader["uploader_run_id"], "run_attempt": uploader["uploader_attempt"]},
                            api.repo("actions/workflows/ci-xcode-cloud-route.yml"), prefix=state.POST_PREFIX, member="post.json")
                        require(marker is not None and all(marker[key] == prepared[key]
                                for key in ("identity", "producer_run_id", "producer_attempt", "head_sha", "reference_id")),
                                "POST marker differs from prepared producer")
                        value.update(start_cloud(asc, prepared, before_post=before_post))
                except SupersededProducer:
                    raise
                except (ContractError, KeyError, TypeError, ValueError, OSError, URLError):
                    value.update(decision="fallback", reason="cloud-start-unavailable")
            value.update(uploader)
            write_phase("start", value)
        else:
            own = {"name": f"ci-xcc-start-{uploader['uploader_run_id']}-{uploader['uploader_attempt']}"}
            artifacts = api.pages(f"actions/runs/{uploader['uploader_run_id']}/artifacts", "artifacts")
            matches = [item for item in artifacts if item["name"] == own["name"]]
            require(len(matches) == 1, "poll has no unique persisted start result")
            prepared = state.read_state(api, matches[0], api.repo("actions/workflows/ci-xcode-cloud-route.yml"),
                                        prefix=state.START_PREFIX, member="start.json")
            require(prepared["producer_run_id"] == run_id and prepared["producer_attempt"] == attempt, "start result differs from producer")
            record = trusted_admissions(api, [run_id]).get(run_id)
            value = poll_route(api, asc, record, run, prepared)
            value.update(uploader)
            write_phase("route", value)
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"recorded=true\nproducer_run_id={run_id}\nproducer_attempt={attempt}\n")
            if phase == "prepare":
                output.write("post=" + str(value["decision"] == "pending" and value.get("cloud_run_id") is None).lower() + "\n")
        print("Apple TV " + phase + ": " + value["decision"] + " (" + value["reason"] + ")")
        return 0
    except SupersededProducer:
        print("Cloud producer superseded; no new start or verdict")
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("recorded=false\npost=false\n")
        return 0
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError):
        print("Cloud router refused this source; GitHub Apple TV remains required", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
