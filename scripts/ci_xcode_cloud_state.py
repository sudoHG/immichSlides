"""Main-authenticated immutable start reservations survive interrupted routers."""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone

from ci_publish import json_member, positive
from ci_summary import ContractError, require, sha
from ci_xcode_cloud import ROUTE_PATH, WORKFLOW_ID, on_main, uuid

RESERVATION_PREFIX = "ci-xcc-reservation-"
START_PREFIX = "ci-xcc-start-"
POST_PREFIX = "ci-xcc-post-"
JOURNAL_PREFIX = "ci-xcc-journal-"
STATE_DAYS = 90
RECONCILE_MINUTES = 10


def timestamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        require(parsed.utcoffset() is not None, "missing UTC offset")
        return parsed.astimezone(timezone.utc)
    except (AttributeError, ValueError, TypeError):
        raise ContractError("invalid reservation timestamp") from None


def authenticate_state(api, artifact, workflow, *, prefix):
    match = re.fullmatch(re.escape(prefix) + r"([1-9][0-9]*)-([1-9][0-9]*)", artifact["name"])
    require(match is not None, "invalid state artifact name")
    run_id, attempt = map(int, match.groups())
    require(artifact["workflow_run"]["id"] == run_id and attempt <= 100, "state uploader binding differs")
    run = api.repo(f"actions/runs/{run_id}/attempts/{attempt}")
    # Reservations must survive failed/cancelled workflow attempts. Their
    # main revision and dispatch provenance are checked before opening bytes.
    require(run["id"] == run_id and run["run_attempt"] == attempt
            and run["workflow_id"] == workflow["id"] and workflow["path"] == run["path"] == ROUTE_PATH
            and run["event"] == "workflow_dispatch" and run["head_branch"] == "main"
            and run["repository"]["full_name"] == run["head_repository"]["full_name"] == api.repository
            and on_main(run["head_sha"]), "state artifact is not from its trusted main attempt")
    require(not artifact["expired"], "persistent cloud reservation expired before reconciliation")
    return run_id, attempt


def read_state(api, artifact, workflow, *, prefix, member):
    run_id, attempt = authenticate_state(api, artifact, workflow, prefix=prefix)
    value = json_member(api, artifact, member)
    require(value["uploader_run_id"] == run_id and value["uploader_attempt"] == attempt,
            "state payload differs from authenticated attempt")
    return value


def validate_reservation(value):
    require(type(value["schema_version"]) is int and value["schema_version"] == 1
            and value["workflow_id"] == WORKFLOW_ID, "invalid persisted cloud reservation")
    for key in ("producer_run_id", "producer_attempt", "uploader_run_id", "uploader_attempt"):
        positive(value[key])
    sha(value["identity"]["head_sha"])
    timestamp(value["reserved_at"])
    require(isinstance(value["prior_run_ids"], list), "reservation lacks prior build inventory")
    for run_id in value["prior_run_ids"]:
        uuid(run_id)
    require(len(set(value["prior_run_ids"])) == len(value["prior_run_ids"]), "duplicate prior builds")
    return value


def reservations(api, *, now=None):
    """Read recent router runs until their latest trusted active-state checkpoint.

    The checkpoint omits released reservations. Old active reservations survive
    in it without re-opening or re-authenticating already processed artifacts.
    """
    workflow = api.repo("actions/workflows/ci-xcode-cloud-route.yml")
    since = (now or datetime.now(timezone.utc)) - timedelta(days=STATE_DAYS)
    runs = api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs", event="workflow_dispatch",
                     branch="main", created=">=" + since.isoformat())
    records = {}
    for run in sorted(runs, key=lambda item: (timestamp(item["created_at"]), item["id"]), reverse=True):
        artifacts = api.pages(f"actions/runs/{run['id']}/artifacts", "artifacts")
        journals = sorted([item for item in artifacts if item["name"].startswith(JOURNAL_PREFIX)],
                          key=lambda item: item["id"], reverse=True)
        checkpoint, released = False, set()
        for artifact in journals:
            try:
                value = read_state(api, artifact, workflow, prefix=JOURNAL_PREFIX, member="journal.json")
            except (KeyError, TypeError, ValueError):
                continue
            except ContractError as error:
                if str(error) == "persistent cloud reservation expired before reconciliation":
                    raise
                continue
            require(type(value["schema_version"]) is int and value["schema_version"] == 1
                    and isinstance(value["active"], list) and isinstance(value["released"], list), "invalid cloud state checkpoint")
            released = {positive(item) for item in value["released"]}
            for row in value["active"]:
                validate_reservation(row)
                positive(row["reservation_artifact_id"])
                records.setdefault(row["reservation_artifact_id"], row)
            checkpoint = True
            break
        for artifact in artifacts:
            if not artifact["name"].startswith(RESERVATION_PREFIX) or artifact["id"] in released:
                continue
            try:
                value = read_state(api, artifact, workflow, prefix=RESERVATION_PREFIX, member="reservation.json")
            except (KeyError, TypeError, ValueError):
                continue
            except ContractError as error:
                if str(error) == "persistent cloud reservation expired before reconciliation":
                    raise
                continue
            validate_reservation(value)
            value = dict(value, reservation_artifact_id=artifact["id"])
            require(artifact["id"] not in records or records[artifact["id"]] == value, "checkpoint reservation differs")
            records[artifact["id"]] = value
        if checkpoint:
            break
    records = list(records.values())
    require(len({(record["producer_run_id"], record["producer_attempt"]) for record in records}) == len(records),
            "cloud start reservations are duplicated")
    return records


def start_result(api, reservation):
    # Only the creator can issue the first POST. Later routers reconcile through
    # ASC, so read its exact immutable receipt instead of scanning every journal.
    workflow = api.repo("actions/workflows/ci-xcode-cloud-route.yml")
    run_id, attempt = reservation["uploader_run_id"], reservation["uploader_attempt"]
    name = f"ci-xcc-start-{run_id}-{attempt}"
    artifacts = [item for item in api.pages(f"actions/runs/{run_id}/artifacts", "artifacts") if item["name"] == name]
    require(len(artifacts) <= 1, "cloud start results conflict")
    if not artifacts:
        return None
    value = read_state(api, artifacts[0], workflow, prefix=START_PREFIX, member="start.json")
    require(value.get("reservation_artifact_id") == reservation["reservation_artifact_id"]
            and value["identity"] == reservation["identity"]
            and value["producer_run_id"] == reservation["producer_run_id"]
            and value["producer_attempt"] == reservation["producer_attempt"], "start result differs from reservation")
    return value


def never_posted(api, reservation):
    if post_marker(api, reservation) is not None:
        return False
    jobs = api.pages(f"actions/runs/{reservation['uploader_run_id']}/attempts/{reservation['uploader_attempt']}/jobs", "jobs")
    starts = [job for job in jobs if job["name"] == "xcc-start"]
    # Start requires the independently uploaded marker before POST. Once the
    # creator job has ended, a missing marker proves no POST, including failure.
    return len(starts) == 1 and starts[0]["status"] == "completed"


def post_marker(api, reservation):
    run_id, attempt = reservation["uploader_run_id"], reservation["uploader_attempt"]
    name = f"{POST_PREFIX}{run_id}-{attempt}"
    artifacts = [row for row in api.pages(f"actions/runs/{run_id}/artifacts", "artifacts") if row["name"] == name]
    require(len(artifacts) <= 1, "cloud POST markers conflict")
    if not artifacts:
        return None
    value = read_state(api, artifacts[0], api.repo("actions/workflows/ci-xcode-cloud-route.yml"),
                       prefix=POST_PREFIX, member="post.json")
    require(value["reservation_artifact_id"] == reservation["reservation_artifact_id"]
            and value["identity"] == reservation["identity"], "POST marker differs from reservation")
    return value


def reconcile(asc, reservation, result=None, *, inventory=None, now=None):
    """Separate terminal quota release from head/population evidence acceptance."""
    if result and result.get("start_rejected") is True:
        return {"state": "released", "cloud_run_id": None}
    runs = inventory if inventory is not None else asc.pages("/v1/ciWorkflows/" + WORKFLOW_ID + "/buildRuns?limit=200")
    if result and result.get("cloud_run_id"):
        matches = [run for run in runs if run["id"] == uuid(result["cloud_run_id"])]
    else:
        prior = set(reservation["prior_run_ids"])
        newer = [run for run in runs if run["id"] not in prior]
        # A pending build may not yet expose its source commit. Do not guess
        # which start it represents or issue a second POST during that gap.
        if any(not run["attributes"].get("sourceCommit", {}).get("commitSha") for run in newer):
            return {"state": "unresolved", "cloud_run_id": None, "can_start": False}
        matches = [run for run in newer if run["attributes"].get("sourceCommit", {}).get("commitSha")
                   == reservation["identity"]["head_sha"]]
        if (not newer and not any(not run["attributes"].get("sourceCommit", {}).get("commitSha") for run in runs)
                and ((now or datetime.now(timezone.utc)) - timestamp(reservation["reserved_at"])).total_seconds()
                >= RECONCILE_MINUTES * 60):
            return {"state": "released", "cloud_run_id": None}
    if len(matches) != 1:
        return {"state": "unresolved", "cloud_run_id": None, "can_start": not matches}
    run = matches[0]
    return {"state": "released" if run["attributes"]["executionProgress"] == "COMPLETE" else "in-flight",
            "cloud_run_id": uuid(run["id"]), "cloud_created_at": run["attributes"].get("createdDate"),
            "cloud_started_at": run["attributes"].get("startedDate")}


def inflight_start(api, run, evidence_attempt, workflow):
    """Wait scheduling uses main-authenticated start metadata, never a verdict."""
    from ci_publish import git
    git("fetch", "--no-tags", "origin", "refs/heads/main")
    runs = api.repo(f"actions/workflows/{workflow['id']}/runs?event=workflow_dispatch&per_page=100")["workflow_runs"]
    matches = [row for row in runs if row.get("display_title") == f"xcc-route-{run['id']}-{evidence_attempt}"]
    for source in sorted(matches, key=lambda row: row["id"], reverse=True):
        name = f"{START_PREFIX}{source['id']}-{source['run_attempt']}"
        artifacts = [row for row in api.pages(f"actions/runs/{source['id']}/artifacts", "artifacts") if row["name"] == name]
        require(len(artifacts) <= 1, "cloud scheduling receipts conflict")
        if not artifacts:
            continue
        value = read_state(api, artifacts[0], workflow, prefix=START_PREFIX, member="start.json")
        require(value["producer_run_id"] == run["id"] and value["producer_attempt"] == evidence_attempt
                and value["head_sha"] == run["head_sha"], "cloud scheduling receipt has another producer")
        if value.get("cloud_run_id") is not None:
            uuid(value["cloud_run_id"])
            timestamp(value["cloud_created_at"])
            return value
    return None
