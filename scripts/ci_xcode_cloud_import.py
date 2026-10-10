#!/usr/bin/env python3
"""Import method outcomes in main context; never execute PR files or artifacts."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from urllib.error import URLError

from ci_publish import map_pr, positive, trusted_admissions, verify_workflow
from ci_summary import ContractError, require
from ci_xcode_cloud import (IMPORT_PATH, ROUTE_PATH, UI_PATH, archive_evidence_run, trusted_artifact, validate_evidence, validate_route)
from ci_xcode_cloud_api import credential_context, jwt
from ci_xcode_cloud_client import RenewingAppStoreConnect, RetryingGitHub
import time


ROUTER_FINALIZATION_SECONDS = 120
ROUTER_POLL_SECONDS = 5


def completed_route(api, run, *, group=None, sleep=time.sleep, monotonic=time.monotonic):
    # A direct dispatch may start before the router's final job has ended.
    # Poll the existing strict reader; a running uploader is never accepted.
    deadline = monotonic() + ROUTER_FINALIZATION_SECONDS
    while True:
        try:
            suffix = f"{run['id']}-{run['run_attempt']}" + ("-" + group if group else "")
            return trusted_artifact(api, "ci-xcc-route-" + suffix, ROUTE_PATH, "route.json",
                                    refresh_main=False)
        except ContractError:
            remaining = deadline - monotonic()
            if remaining <= 0:
                raise
            sleep(min(ROUTER_POLL_SECONDS, remaining))


def import_run(api, asc, run_id, evidence_attempt=None):
    run = api.repo("actions/runs/" + str(positive(run_id)))
    verify_workflow(run, api.repo("actions/workflows/ci-ui.yml"), api.repository)
    require(run["path"] == UI_PATH and run["event"] == "pull_request"
            and run["repository"]["full_name"] == run["head_repository"]["full_name"] == api.repository,
            "importer accepts only same-repository PR UI producers")
    pr = map_pr(api, run)
    records = trusted_admissions(api, [run["id"]])
    require(run["id"] in records, "cloud producer has no trusted admission")
    record = records[run["id"]]
    latest_attempt = run["run_attempt"]
    run = archive_evidence_run(api, run)
    require(evidence_attempt is None or run["run_attempt"] == evidence_attempt, "import input differs from archive evidence attempt")
    require(record["identity"]["head_sha"] == pr["head"]["sha"], "PR changed before cloud import")
    route, artifact_id = completed_route(api, run)
    validate_route(record, run, route)
    evidence = asc.evidence(route["cloud_run_id"])
    checks = api.pages("commits/" + record["identity"]["head_sha"] + "/check-runs", "check_runs", filter="all")
    # The importer records API evidence, not approval or the ci-ui verdict.
    # Publication independently selects the admitted policy using exact-head
    # approval and repeats the complete identity comparison against that policy.
    refused = []
    for approved in (False, True):
        try:
            validate_evidence(record, run, route, evidence, checks, approved=approved)
            break
        except (ContractError, KeyError, TypeError, ValueError):
            refused.append(approved)
    require(len(refused) < 2, "API results do not prove an admitted Apple TV population and app check")
    fresh = api.repo("actions/runs/" + str(run["id"]))
    require(fresh["run_attempt"] == latest_attempt and fresh["head_sha"] == run["head_sha"]
            and api.repo(f"pulls/{pr['number']}")["head"]["sha"] == run["head_sha"], "producer or PR changed during cloud import")
    return {"schema_version": 1, "identity": record["identity"], "producer_run_id": run["id"],
            "producer_attempt": run["run_attempt"], "route_artifact_id": artifact_id, "evidence": evidence}


def import_group(api, asc, run_id, evidence_attempt, group):
    import ci_xcode_cloud_groups as groups
    from ci_xcode_cloud_group_route import anchor
    require(group in groups.GROUPS, "import refuses unknown Cloud group")
    run = api.repo("actions/runs/" + str(positive(run_id)))
    verify_workflow(run, api.repo("actions/workflows/ci-ui.yml"), api.repository)
    pr = map_pr(api, run)
    record = trusted_admissions(api, [run["id"]]).get(run["id"])
    require(record is not None and record["identity"]["head_sha"] == pr["head"]["sha"], "Cloud group admission is stale")
    latest_attempt = run["run_attempt"]
    run = archive_evidence_run(api, run, selection_job=anchor(record, run))
    require(run["run_attempt"] == evidence_attempt, "group import evidence attempt differs")
    route, artifact_id = completed_route(api, run, group=group)
    require(route["group"] == group, "group import route differs")
    statuses = api.pages("commits/" + run["head_sha"] + "/statuses")
    descriptor = groups.validate_route(record, run, route, statuses, approved=False)
    evidence = asc.evidence(route["cloud_run_id"], workflow_id=descriptor["registration"]["workflow_id"])
    checks = api.pages("commits/" + run["head_sha"] + "/check-runs", "check_runs", filter="all")
    statuses = api.pages("commits/" + run["head_sha"] + "/statuses")
    groups.validate_evidence(record, run, route, evidence, checks, statuses, approved=False)
    fresh = api.repo("actions/runs/" + str(run["id"]))
    current = api.repo(f"pulls/{pr['number']}")
    require(fresh["run_attempt"] == latest_attempt and fresh["head_sha"] == run["head_sha"]
            and current["head"]["sha"] == run["head_sha"] and current["base"]["sha"] == record["identity"]["base_sha"]
            and current["user"]["login"] == groups.MAINTAINER_LOGIN and current["user"]["id"] == groups.MAINTAINER_ID,
            "group producer or base changed during import")
    return {**{field: route[field] for field in ("schema_version", "identity", "producer_run_id", "producer_attempt", "group",
                                                "selection_sha256", "pointer_id", "runtime_plan_sha256")},
            "route_artifact_id": artifact_id, "selection": descriptor, "evidence": evidence}


def main():
    try:
        credential_context(os.environ, IMPORT_PATH)
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        run_id = event["inputs"]["producer_run_id"]
        require(isinstance(run_id, str) and run_id.isdecimal() and 0 < int(run_id) < 10**15, "invalid UI producer run ID")
        api = RetryingGitHub(os.environ["GITHUB_REPOSITORY"], os.environ["CI_WORKFLOW_TOKEN"], time.monotonic() + 9 * 60)
        attempt = event["inputs"]["producer_attempt"]
        require(isinstance(attempt, str) and attempt.isdecimal(), "invalid evidence attempt input")
        asc = RenewingAppStoreConnect(lambda: jwt(os.environ, IMPORT_PATH), time.monotonic() + 9 * 60)
        group = event["inputs"].get("group", "")
        receipt = (import_group(api, asc, int(run_id), positive(int(attempt)), group) if group
                   else import_run(api, asc, int(run_id), positive(int(attempt))))
        receipt.update(uploader_run_id=int(os.environ["GITHUB_RUN_ID"]),
                       uploader_attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]))
        directory = Path(os.environ["RUNNER_TEMP"], "ci-xcc-import")
        directory.mkdir(mode=0o700, exist_ok=False)
        (directory / "cloud.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"imported=true\nproducer_run_id={receipt['producer_run_id']}\nproducer_attempt={receipt['producer_attempt']}\ngroup={group}\n")
        print("Xcode Cloud import verified the complete admitted method population and app check")
        return 0
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError):
        print("Xcode Cloud import refused incomplete, stale or untrusted evidence; use the group's GitHub selection", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
