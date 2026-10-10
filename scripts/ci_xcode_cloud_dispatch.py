#!/usr/bin/env python3
"""Credential-free main dispatches to fixed cloud evidence workflows."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import URLError

from ci_publish import git, json_member, positive
from ci_summary import ContractError, require
from ci_xcode_cloud import IMPORT_PATH, ROUTE_PATH, UI_PATH, validate_uploader_provenance
from ci_xcode_cloud_route import SupersededProducer, current_producer
from ci_xcode_cloud_client import RetryingGitHub

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


def forward_import(api, env, event):
    """Wake the importer directly; it still requires a successful uploader."""
    require(env.get("GITHUB_REF") == "refs/heads/main"
            and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and env.get("GITHUB_WORKFLOW_REF") == api.repository + "/" + ROUTE_PATH + "@refs/heads/main"
            and env.get("GITHUB_JOB") == "dispatch-import", "import forwarder requires its main router job")
    router_id, attempt = positive(int(env["GITHUB_RUN_ID"])), positive(int(env["GITHUB_RUN_ATTEMPT"]))
    inputs = event["inputs"]
    for key in ("producer_run_id", "producer_attempt"):
        value = inputs[key]
        require(isinstance(value, str) and value.isdecimal() and 0 < int(value) < 10**15, "invalid import dispatch input")
    producer_id, evidence_attempt = int(inputs["producer_run_id"]), int(inputs["producer_attempt"])
    source = api.repo("actions/runs/" + str(router_id))
    git("fetch", "--no-tags", "origin", "refs/heads/main")
    validate_uploader_provenance(source, api.repo("actions/workflows/ci-xcode-cloud-route.yml"), api.repository, ROUTE_PATH)
    require(source["id"] == router_id and source["run_attempt"] == attempt and source["status"] in {"queued", "in_progress"},
            "import forwarder router execution differs")
    jobs = [job for job in api.pages(f"actions/runs/{router_id}/attempts/{attempt}/jobs", "jobs") if job["name"] == "route"]
    require(len(jobs) == 1 and jobs[0]["status"] == "completed" and jobs[0]["conclusion"] == "success",
            "import forwarder requires a successful route job")
    name = f"ci-xcc-route-{producer_id}-{evidence_attempt}"
    artifacts = [item for item in api.pages(f"actions/runs/{router_id}/artifacts", "artifacts")
                 if item["name"] == name and not item["expired"]]
    require(len(artifacts) == 1 and artifacts[0]["workflow_run"]["id"] == router_id,
            "import forwarder has no unique current routing artifact")
    receipt = json_member(api, artifacts[0], "route.json")
    require(type(receipt["schema_version"]) is int and receipt["schema_version"] == 1 and receipt["terminal"] is True
            and receipt["uploader_run_id"] == router_id and receipt["uploader_attempt"] == attempt
            and receipt["producer_run_id"] == producer_id and receipt["producer_attempt"] == evidence_attempt,
            "import forwarder receipt or input differs")
    if receipt["decision"] != "routed":
        return
    producer = api.repo("actions/runs/" + str(producer_id))
    require(producer["head_sha"] == receipt["head_sha"], "import forwarder head differs")
    current_producer(api, producer)
    api.dispatch(IMPORT_PATH, {"producer_run_id": str(producer_id), "producer_attempt": str(evidence_attempt)})


def main():
    try:
        if sys.argv[1:] == ["import"]:
            event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
            api = RetryingGitHub(os.environ["GITHUB_REPOSITORY"], os.environ["CI_WORKFLOW_TOKEN"], time.monotonic() + 4 * 60)
            forward_import(api, os.environ, event)
            return 0
        require(len(sys.argv) == 1, "invalid cloud dispatch phase")
        require(os.environ.get("GITHUB_REF") == "refs/heads/main"
                and os.environ.get("GITHUB_EVENT_NAME") == "workflow_run"
                and os.environ.get("GITHUB_WORKFLOW_REF") == os.environ.get("GITHUB_REPOSITORY", "") +
                "/" + PATH + "@refs/heads/main", "cloud bridge requires its main workflow")
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        dispatch(RetryingGitHub(os.environ["GITHUB_REPOSITORY"], os.environ["CI_WORKFLOW_TOKEN"], time.monotonic() + 4 * 60), event)
        return 0
    except SupersededProducer:
        print("Cloud producer superseded; no dispatch")
        return 0
    except (ContractError, KeyError, TypeError, ValueError, OSError, URLError, subprocess.SubprocessError):
        print("Cloud event dispatch refused; GitHub Apple TV remains required", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
