#!/usr/bin/env python3
"""Credential-free main event bridge to dispatch-only cloud evidence jobs."""

import json
import os
import sys
from pathlib import Path
from urllib.error import URLError

from ci_publish import GitHub, git, json_member, positive
from ci_summary import ContractError, require
from ci_xcode_cloud import IMPORT_PATH, ROUTE_PATH, UI_PATH, validate_uploader
from ci_xcode_cloud_route import current_producer

PATH = ".github/workflows/ci-xcode-cloud-dispatch.yml"


def dispatch(api, event):
    source = api.repo("actions/runs/" + str(positive(event["workflow_run"]["id"])))
    require(source["repository"]["full_name"] == source["head_repository"]["full_name"] == api.repository,
            "cloud bridge refuses forks")
    if source["path"] == UI_PATH and source["event"] != "pull_request":
        return
    if source["path"] == UI_PATH and event["action"] == "requested":
        current_producer(api, source)
        api.dispatch(ROUTE_PATH, {"producer_run_id": str(source["id"]), "producer_attempt": str(source["run_attempt"]), "mode": "auto"})
    elif source["path"] == ROUTE_PATH and event["action"] == "completed":
        workflow = api.repo("actions/workflows/ci-xcode-cloud-route.yml")
        git("fetch", "--no-tags", "origin", "refs/heads/main")
        validate_uploader(source, workflow, api.repository, ROUTE_PATH, source["run_attempt"])
        artifacts = [item for item in api.pages(f"actions/runs/{source['id']}/artifacts", "artifacts")
                     if item["name"].startswith("ci-xcc-route-") and not item["expired"]]
        if not artifacts:
            return
        require(len(artifacts) == 1, "cloud bridge has no unique routing decision")
        receipt = json_member(api, artifacts[0], "route.json")
        require(receipt["uploader_run_id"] == source["id"] and receipt["uploader_attempt"] == source["run_attempt"]
                and artifacts[0]["name"] == f"ci-xcc-route-{positive(receipt['producer_run_id'])}-{positive(receipt['producer_attempt'])}",
                "cloud bridge route run or attempt differs")
        if receipt["decision"] == "routed":
            api.dispatch(IMPORT_PATH, {"producer_run_id": str(receipt["producer_run_id"]),
                                       "producer_attempt": str(receipt["producer_attempt"])})


def main():
    try:
        require(os.environ.get("GITHUB_REF") == "refs/heads/main"
                and os.environ.get("GITHUB_EVENT_NAME") == "workflow_run"
                and os.environ.get("GITHUB_WORKFLOW_REF") == os.environ.get("GITHUB_REPOSITORY", "") +
                "/" + PATH + "@refs/heads/main", "cloud bridge requires its main workflow")
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        dispatch(GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["CI_WORKFLOW_TOKEN"]), event)
        return 0
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError):
        print("Cloud event dispatch refused; GitHub Apple TV remains required", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
