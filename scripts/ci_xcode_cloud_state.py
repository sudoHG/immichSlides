"""Main-authenticated immutable start reservations survive interrupted routers."""

from __future__ import annotations

import re
from datetime import datetime, timezone

from ci_publish import json_member, positive
from ci_summary import ContractError, require, sha
from ci_xcode_cloud import ROUTE_PATH, WORKFLOW_ID, on_main, uuid

RESERVATION_PREFIX = "ci-xcc-reservation-"
START_PREFIX = "ci-xcc-start-"


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


def reservations(api):
    workflow = api.repo("actions/workflows/ci-xcode-cloud-route.yml")
    records = []
    for artifact in api.pages("actions/artifacts", "artifacts"):
        if not artifact["name"].startswith(RESERVATION_PREFIX):
            continue
        # An untrusted colliding artifact cannot block or authorize a start.
        try:
            run_id, attempt = authenticate_state(api, artifact, workflow, prefix=RESERVATION_PREFIX)
        except (KeyError, TypeError, ValueError):
            continue
        except ContractError as error:
            if str(error) == "persistent cloud reservation expired before reconciliation":
                raise
            continue
        value = json_member(api, artifact, "reservation.json")
        require(value["uploader_run_id"] == run_id and value["uploader_attempt"] == attempt
                and type(value["schema_version"]) is int and value["schema_version"] == 1
                and value["workflow_id"] == WORKFLOW_ID, "invalid persisted cloud reservation")
        positive(value["producer_run_id"])
        positive(value["producer_attempt"])
        sha(value["identity"]["head_sha"])
        timestamp(value["reserved_at"])
        require(isinstance(value["prior_run_ids"], list), "reservation lacks prior build inventory")
        for run_id in value["prior_run_ids"]:
            uuid(run_id)
        require(len(set(value["prior_run_ids"])) == len(value["prior_run_ids"]), "duplicate prior builds")
        records.append(dict(value, reservation_artifact_id=artifact["id"]))
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
    jobs = api.pages(f"actions/runs/{reservation['uploader_run_id']}/attempts/{reservation['uploader_attempt']}/jobs", "jobs")
    starts = [step for job in jobs if job["name"] == "xcc-start" for step in job.get("steps", [])
              if step["name"] == "Start or reconcile the reserved build"]
    # An absent or interrupted step is uncertain. Only GitHub's explicit
    # unexecuted step state proves that the POST could not have happened.
    return len(starts) == 1 and starts[0]["status"] == "completed" and starts[0]["conclusion"] == "skipped"


def reconcile(asc, reservation, result=None, *, inventory=None):
    """Unknown POST outcomes never authorize another POST or release quota."""
    runs = inventory if inventory is not None else asc.pages("/v1/ciWorkflows/" + WORKFLOW_ID + "/buildRuns?limit=200")
    if result and result.get("cloud_run_id"):
        matches = [run for run in runs if run["id"] == uuid(result["cloud_run_id"])]
    else:
        prior = set(reservation["prior_run_ids"])
        newer = [run for run in runs if run["id"] not in prior
                 and timestamp(run["attributes"]["createdDate"]) >= timestamp(reservation["reserved_at"])]
        # A pending build may not yet expose its source commit. Do not guess
        # which start it represents or issue a second POST during that gap.
        if any(not run["attributes"].get("sourceCommit", {}).get("commitSha") for run in newer):
            return {"state": "unresolved", "cloud_run_id": None, "can_start": False}
        matches = [run for run in newer if run["attributes"].get("sourceCommit", {}).get("commitSha")
                   == reservation["identity"]["head_sha"]]
        if not matches and result and result.get("start_rejected") is True:
            return {"state": "released", "cloud_run_id": None}
    if len(matches) != 1:
        return {"state": "unresolved", "cloud_run_id": None, "can_start": not matches}
    run = matches[0]
    require(run["attributes"].get("sourceCommit", {}).get("commitSha") == reservation["identity"]["head_sha"],
            "reconciled build has another head")
    return {"state": "released" if run["attributes"]["executionProgress"] == "COMPLETE" else "in-flight",
            "cloud_run_id": uuid(run["id"])}
