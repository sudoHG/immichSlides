"""Trusted Apple TV evidence; candidate JSON and Git objects are data only."""

from __future__ import annotations

import re
import subprocess
from datetime import datetime
from pathlib import PurePosixPath
from xml.etree import ElementTree

from ci_summary import ContractError, require, sha

UI_PATH = ".github/workflows/ci-ui.yml"
IMPORT_PATH = ".github/workflows/ci-xcode-cloud-import.yml"
ROUTE_PATH = ".github/workflows/ci-xcode-cloud-route.yml"
PLAN_PATH = "XcodeCloud-UI-tvOS.xctestplan"
SCHEME_PATH = "immichSlides.xcodeproj/xcshareddata/xcschemes/immichSlides-tvOS.xcscheme"
WORKFLOW_ID = "72574ec0-c168-4317-b469-d3090357ab21"
APP_ID = 117084
APPLE_APP_ID = "6764543664"
TEAM_ID = "26bc1fd1-130b-41f7-95dc-baf955cbbc17"
ACTION_NAME = "XcodeCloud-UI-tvOS - tvOS"
CHECK_NAME = "immichSlides | UI - Apple TV (overflow) | " + ACTION_NAME
DEVICE_NAME = "Apple TV 4K (3rd generation)"


def uuid(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value),
            "invalid Xcode Cloud identifier")
    return value


def duration(started, finished):
    try:
        start, end = (datetime.fromisoformat(value.replace("Z", "+00:00")) for value in (started, finished))
        require(start.utcoffset() is not None and end.utcoffset() is not None and end >= start,
                "invalid Xcode Cloud action timestamps")
        return (end - start).total_seconds() / 60
    except (AttributeError, TypeError, ValueError):
        raise ContractError("missing or invalid Xcode Cloud action timestamps") from None


def validate_plan_resolution(scheme, plan_paths):
    require(isinstance(scheme, str) and len(scheme.encode()) <= 1024 * 1024
            and "<!DOCTYPE" not in scheme and "<!ENTITY" not in scheme,
            "cloud scheme is absent or unsupported")
    try:
        root = ElementTree.fromstring(scheme)
    except ElementTree.ParseError:
        raise ContractError("cloud scheme is malformed") from None
    actions = root.findall("TestAction")
    require(root.tag == "Scheme" and len(actions) == 1, "cloud scheme needs one TestAction")
    action = actions[0]
    require(action.find(".//PreActions") is None and action.find(".//PostActions") is None,
            "cloud scheme TestAction cannot run pre/post actions")
    references = [item.get("reference", "") for item in action.findall(".//TestPlanReference")
                  if PurePosixPath(item.get("reference", "").removeprefix("container:")).name.casefold() == PLAN_PATH.casefold()]
    require(references == ["container:" + PLAN_PATH] and plan_paths == [PLAN_PATH],
            "cloud scheme redirects or ambiguously resolves the admitted plan")


def applied_deselections(record, *, approved):
    from ci_verdict import parse_policy, tier_approved
    ui = record["ui_inputs"]["candidate" if approved else "base"]
    entries = [entry for identities in ui["populations"]["appletv"].values() for entry in identities]
    policy = parse_policy(record["candidate_policy"] if approved else record["base_policy"])
    return [{key: item[key] for key in ("identity", "reason", "owning_tier")}
            for item in policy["deselections"] if tier_approved(policy, "ui")
            and item["tier"] == "ui" and item["environment"] == "fixture" and item["identity"] in entries]


def admitted_population(record, *, approved):
    from check_xcode_cloud_ui import validate_plan
    from ci_verdict import parse_policy, tier_approved
    ui = record["ui_inputs"]["candidate" if approved else "base"]
    require(ui is not None and "error" not in ui, "Apple TV population is not admitted")
    entries = [entry for identities in ui["populations"]["appletv"].values() for entry in identities]
    require(entries and len({entry["key"] for entry in entries}) == len(entries), "invalid admitted Apple TV shard union")
    policy = parse_policy(record["candidate_policy"] if approved else record["base_policy"])
    deselected = [item["identity"] for item in policy["deselections"]
                  if tier_approved(policy, "ui") and item["tier"] == "ui" and item["environment"] == "fixture"]
    entries = [entry for entry in entries if entry not in deselected]
    inputs = record.get("cloud_inputs")
    require(isinstance(inputs, dict), "cloud plan is absent from trusted admission")
    validate_plan_resolution(inputs["scheme"], inputs["plan_paths"])
    sha(inputs["plan_sha256"], 64)
    require(inputs["fixture_sha256"] == inputs["source_sha256"], "cloud fixture copy differs from the source")
    validate_plan(inputs["plan"], {"admitted": entries})
    # Preserve the admitted GitHub identity, including its Apple TV device.
    return sorted(entries, key=lambda entry: entry["key"])


def validate_route(record, run, route):
    identity = record["identity"]
    require(run["event"] == identity["event"] == "pull_request" and run["path"] == UI_PATH,
            "Xcode Cloud is pull-request Apple TV only")
    require(run["repository"]["full_name"] == run["head_repository"]["full_name"] == identity["repository"],
            "Xcode Cloud does not admit forks")
    require(record["run_id"] == run["id"] and run["head_sha"] == identity["head_sha"], "cloud producer is stale")
    require(type(route.get("schema_version")) is int and route["schema_version"] == 1
            and route["decision"] == "routed" and route["identity"] == identity
            and type(route["producer_run_id"]) is int and route["producer_run_id"] == run["id"]
            and type(route["producer_attempt"]) is int and route["producer_attempt"] == run["run_attempt"]
            and route["workflow_id"] == WORKFLOW_ID, "cloud routing decision is absent or stale")
    uuid(route["cloud_run_id"])
    inputs = record.get("cloud_inputs")
    require(inputs is not None and route["plan_sha256"] == inputs["plan_sha256"], "cloud plan differs from admission")
    require(inputs["head_tree_sha"] == identity["tree_sha"], "cloud head tree differs from admitted merge tree; run GitHub")


def validate_evidence(record, run, route, evidence, checks, *, approved):
    validate_route(record, run, route)
    population = admitted_population(record, approved=approved)
    require(evidence["id"] == route["cloud_run_id"] and evidence["workflow_id"] == WORKFLOW_ID
            and evidence["head_sha"] == record["identity"]["head_sha"]
            and evidence.get("is_pull_request_build") is False
            and evidence["progress"] == "COMPLETE" and evidence["status"] == "SUCCEEDED",
            "cloud run did not complete successfully on the admitted head")
    wall = duration(evidence["started"], evidence["finished"])
    actions = evidence["actions"]
    require(isinstance(actions, list) and len(actions) == 1, "overflow workflow must have exactly one test action")
    action = actions[0]
    uuid(action["id"])
    require(action["name"] == ACTION_NAME and action["type"] == "TEST"
            and action["progress"] == "COMPLETE" and action["status"] == "SUCCEEDED",
            "cloud action is incomplete, failed or outside the overflow plan")
    compute = duration(action["started"], action["finished"])
    require(compute <= wall, "cloud action exceeds run duration")
    tests = action["tests"]
    require(isinstance(tests, list) and tests, "cloud method results are missing")
    keys, result_ids = [], []
    for test in tests:
        require(isinstance(test["id"], str) and test["id"], "cloud result has no API identity")
        result_ids.append(test["id"])
        require(isinstance(test["class"], str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", test["class"])
                and isinstance(test["method"], str) and re.fullmatch(r"test[A-Za-z0-9_]+\(\)", test["method"]),
                "unsupported cloud method identity")
        keys.append(test["class"] + "/" + test["method"][:-2])
        require(test["status"] == "SUCCESS", "cloud method failed, skipped or has unknown outcome")
        destinations = test["destinations"]
        require(isinstance(destinations, list) and len(destinations) == 1
                and destinations[0] == {"device": DEVICE_NAME, "os": "27.0", "status": "SUCCESS"},
                "cloud method has missing, extra, failed or unexpected destinations")
    require(len(set(keys)) == len(keys) and len(set(result_ids)) == len(result_ids), "duplicate cloud method results")
    require(set(keys) == {entry["key"] for entry in population}, "cloud executed population differs from admission")
    details = ("https://appstoreconnect.apple.com/teams/" + TEAM_ID + "/apps/" + APPLE_APP_ID +
               "/ci/builds/" + evidence["id"] + "/action/" + action["id"])
    matching = [check for check in checks if check.get("app", {}).get("id") == APP_ID
                and check["app"].get("slug") == "xcode-cloud" and check.get("name") == CHECK_NAME
                and check.get("head_sha") == record["identity"]["head_sha"]]
    require(matching and all(type(check.get("id")) is int and check["id"] > 0 for check in matching),
            "cloud app check has no authoritative API identity")
    newest_id = max(check["id"] for check in matching)
    newest = [check for check in matching if check["id"] == newest_id]
    require(len(newest) == 1 and newest[0]["status"] == "completed" and newest[0]["conclusion"] == "success"
            and newest[0].get("details_url") == details,
            "exact-head overflow check from the Xcode Cloud app is missing, ambiguous or not successful")
    return {"identities": population, "cloud_run_id": evidence["id"], "action_id": action["id"],
            "wall_minutes": wall, "compute_minutes": compute, "details_url": details,
            "plan_sha256": record["cloud_inputs"]["plan_sha256"]}


def on_main(revision):
    sha(revision)
    return subprocess.run(["git", "merge-base", "--is-ancestor", revision, "FETCH_HEAD"],
                          capture_output=True, timeout=30).returncode == 0


def validate_uploader_provenance(run, workflow, repository, path):
    require(workflow["path"] == path and run["path"] == path and run["workflow_id"] == workflow["id"]
            and run["event"] == "workflow_dispatch" and run["head_branch"] == "main"
            and run["repository"]["full_name"] == run["head_repository"]["full_name"] == repository
            and on_main(run["head_sha"]), "cloud evidence uploader is not a trusted main workflow")


def validate_uploader(run, workflow, repository, path, attempt):
    validate_uploader_provenance(run, workflow, repository, path)
    require(type(attempt) is int and attempt > 0 and run["run_attempt"] == attempt,
            "cloud evidence importer attempt is stale")
    require(run["status"] == "completed" and run["conclusion"] == "success",
            "cloud evidence uploader is not a successful trusted main workflow")


def archive_evidence_run(api, run):
    """Bind cloud proof to the actual retained archive-selection execution."""
    require(type(run["run_attempt"]) is int and 0 < run["run_attempt"] <= 100, "too many UI attempts")
    retained, evidence_attempt = None, None
    for attempt in range(1, run["run_attempt"] + 1):
        jobs = api.pages(f"actions/runs/{run['id']}/attempts/{attempt}/jobs", "jobs")
        matches = [job for job in jobs if job["name"] == "ui-archive"]
        require(len(matches) <= 1, "duplicate UI archive jobs")
        if not matches:
            continue
        job = matches[0]
        require(type(job["id"]) is int and job["id"] > 0, "archive job has no execution identity")
        execution = ("started_at", "completed_at", "runner_id")
        same_execution = retained and (all(job.get(key) and job[key] == retained.get(key) for key in execution)
                                      or job["id"] == retained["id"] and all(job.get(key) == retained.get(key) for key in execution))
        # GitHub can regenerate IDs for retained successful jobs on a rerun.
        if not same_execution:
            evidence_attempt = attempt
        retained = job
    require(retained is not None, "UI archive selection has no execution")
    return dict(run, run_attempt=evidence_attempt, producer_latest_attempt=run["run_attempt"], archive_job=retained)


def trusted_artifact(api, name, path, member, *, refresh_main=True):
    from ci_publish import git, json_member, positive
    workflow = api.repo("actions/workflows/" + path.rsplit("/", 1)[-1], missing=True)
    require(workflow is not None and workflow["path"] == path, "trusted cloud workflow is unavailable")
    if refresh_main:
        git("fetch", "--no-tags", "origin", "refs/heads/main")
    candidates = []
    for artifact in api.pages("actions/artifacts", "artifacts", name=name):
        if artifact["name"] != name or artifact["expired"]:
            continue
        uploader = api.repo("actions/runs/" + str(positive(artifact["workflow_run"]["id"])))
        # Authenticate all provenance before opening even a colliding artifact.
        try:
            validate_uploader_provenance(uploader, workflow, api.repository, path)
        except (ContractError, KeyError, TypeError, ValueError):
            continue
        receipt = json_member(api, artifact, member)
        attempt = receipt["uploader_attempt"]
        historical = api.repo(f"actions/runs/{uploader['id']}/attempts/{positive(attempt)}")
        validate_uploader(historical, workflow, api.repository, path, attempt)
        require(type(receipt["uploader_run_id"]) is int and receipt["uploader_run_id"] == uploader["id"]
                and type(attempt) is int and attempt <= uploader["run_attempt"],
                "cloud artifact uploader run or attempt differs")
        candidates.append((receipt, artifact["id"]))
    require(candidates, "trusted cloud evidence is missing or expired")
    if path == IMPORT_PATH and member == "cloud.json":
        content = lambda receipt: {key: value for key, value in receipt.items()
                                   if key not in {"uploader_run_id", "uploader_attempt"}}
        require(all(content(receipt) == content(candidates[0][0]) for receipt, _ in candidates),
                "trusted cloud import receipts conflict")
    else:
        require(len(candidates) == 1, "trusted cloud routing decision is duplicated or conflicting")
    return min(candidates, key=lambda item: item[1])


def trusted_cloud(api, record, run, *, approved, evidence_attempt=None, refresh_main=True):
    if evidence_attempt is None:
        run = archive_evidence_run(api, run)
    else:
        require(type(evidence_attempt) is int and 0 < evidence_attempt <= run["run_attempt"], "invalid archive evidence attempt")
        run = dict(run, run_attempt=evidence_attempt)
    route, route_artifact = trusted_artifact(api, f"ci-xcc-route-{run['id']}-{run['run_attempt']}", ROUTE_PATH, "route.json",
                                             refresh_main=refresh_main)
    validate_route(record, run, route)
    receipt, import_artifact = trusted_artifact(api, f"ci-xcc-import-{run['id']}-{run['run_attempt']}", IMPORT_PATH, "cloud.json",
                                               refresh_main=refresh_main)
    require(type(receipt.get("schema_version")) is int and receipt["schema_version"] == 1
            and receipt["identity"] == record["identity"] and receipt["producer_run_id"] == run["id"]
            and receipt["producer_attempt"] == run["run_attempt"] and receipt["route_artifact_id"] == route_artifact,
            "cloud importer receipt is not bound to this route, admission and attempt")
    # Re-read app checks when publishing: importer success cannot cover a later
    # stale, failed or ambiguous app check or a replaced routing artifact.
    checks = api.pages("commits/" + record["identity"]["head_sha"] + "/check-runs", "check_runs", filter="all")
    result = validate_evidence(record, run, route, receipt["evidence"], checks, approved=approved)
    return dict(result, route_artifact_id=route_artifact, import_artifact_id=import_artifact,
                evidence_attempt=run["run_attempt"])


def apple_tv_skip_names(source, run):
    """Recognize a collapsed TV-only matrix without admitting its skip."""
    import yaml
    from check_workflow_policy import WorkflowLoader
    from ci_publish_git import workflow_contract
    workflow = yaml.load(source, Loader=WorkflowLoader)
    _, _, _, metadata = workflow_contract(source, run, metadata=True)
    names = {name for name, meta in metadata.items() if meta.get("device") == "appletv"}
    for key, job in workflow["jobs"].items():
        if not job.get("strategy", {}).get("matrix"):
            continue
        _, _, _, entries = workflow_contract(yaml.safe_dump({"jobs": {key: job}}), run, metadata=True)
        if entries and all(meta.get("device") == "appletv" for meta in entries.values()):
            names.add(job.get("name", key))
    return names
