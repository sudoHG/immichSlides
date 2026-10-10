"""Main-authenticated POST and start receipts schedule waiting, never quota."""

from __future__ import annotations

import re

from ci_publish import json_member
from ci_summary import require
from ci_xcode_cloud import ROUTE_PATH, on_main, uuid

START_PREFIX = "ci-xcc-start-"
POST_PREFIX = "ci-xcc-post-"
START_TIMEOUT_MINUTES = 20


def read_state(api, artifact, workflow, *, prefix, member):
    match = re.fullmatch(re.escape(prefix) + r"([1-9][0-9]*)-([1-9][0-9]*)", artifact["name"])
    require(match is not None, "invalid scheduling artifact name")
    run_id, attempt = map(int, match.groups())
    require(artifact["workflow_run"]["id"] == run_id and attempt <= 100, "scheduling uploader binding differs")
    run = api.repo(f"actions/runs/{run_id}/attempts/{attempt}")
    # Interrupted main starts can schedule a bounded wait. They cannot prove
    # test acceptance, which still requires successful route/import attempts.
    require(run["id"] == run_id and run["run_attempt"] == attempt
            and run["workflow_id"] == workflow["id"] and workflow["path"] == run["path"] == ROUTE_PATH
            and run["event"] == "workflow_dispatch" and run["head_branch"] == "main"
            and run["repository"]["full_name"] == run["head_repository"]["full_name"] == api.repository
            and on_main(run["head_sha"]), "scheduling artifact is not from its trusted main attempt")
    require(not artifact["expired"], "cloud scheduling receipt expired")
    value = json_member(api, artifact, member)
    require(value["uploader_run_id"] == run_id and value["uploader_attempt"] == attempt,
            "scheduling payload differs from authenticated attempt")
    return value


def receipt(api, artifacts, source, workflow, *, prefix, member):
    name = f"{prefix}{source['id']}-{source['run_attempt']}"
    matches = [row for row in artifacts if row["name"] == name]
    require(len(matches) <= 1, "cloud scheduling receipts conflict")
    return read_state(api, matches[0], workflow, prefix=prefix, member=member) if matches else None


def inflight_start(api, run, evidence_attempt, workflow):
    """A POST marker bridges the short gap before the immutable start receipt."""
    from ci_xcode_cloud_route import timestamp
    runs = api.repo(f"actions/workflows/{workflow['id']}/runs?event=workflow_dispatch&per_page=100")["workflow_runs"]
    matches = [row for row in runs if row.get("display_title") == f"xcc-route-{run['id']}-{evidence_attempt}"]
    for source in sorted(matches, key=lambda row: row["id"], reverse=True):
        artifacts = api.pages(f"actions/runs/{source['id']}/artifacts", "artifacts")
        start = receipt(api, artifacts, source, workflow, prefix=START_PREFIX, member="start.json")
        marker = None if start and start.get("cloud_run_id") else receipt(
            api, artifacts, source, workflow, prefix=POST_PREFIX, member="post.json")
        for value in (start, marker):
            if value is not None:
                require(value["producer_run_id"] == run["id"] and value["producer_attempt"] == evidence_attempt
                        and value["head_sha"] == run["head_sha"], "cloud scheduling receipt has another producer")
        if start and start.get("cloud_run_id"):
            uuid(start["cloud_run_id"])
            timestamp(start["cloud_created_at"])
            return start
        if start and start["decision"] in {"github", "fallback"}:
            return None
        if marker:
            timestamp(marker["posted_at"])
            return dict(marker, awaiting_start=True)
    return None
