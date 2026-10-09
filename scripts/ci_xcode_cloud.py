"""Trusted Apple TV evidence; candidate JSON and Git objects are data only."""

from __future__ import annotations

import re
import subprocess
from datetime import datetime

from ci_summary import ContractError, require, sha

UI_PATH = ".github/workflows/ci-ui.yml"
IMPORT_PATH = ".github/workflows/ci-xcode-cloud-import.yml"
ROUTE_PATH = ".github/workflows/ci-xcode-cloud-route.yml"
PLAN_PATH = "XcodeCloud-UI-tvOS.xctestplan"
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
                and check.get("head_sha") == record["identity"]["head_sha"] and check.get("details_url") == details]
    require(len(matching) == 1 and matching[0]["status"] == "completed" and matching[0]["conclusion"] == "success",
            "exact-head overflow check from the Xcode Cloud app is missing, ambiguous or not successful")
    return {"identities": population, "cloud_run_id": evidence["id"], "action_id": action["id"],
            "wall_minutes": wall, "compute_minutes": compute, "details_url": details,
            "plan_sha256": record["cloud_inputs"]["plan_sha256"]}


def on_main(revision):
    sha(revision)
    return subprocess.run(["git", "merge-base", "--is-ancestor", revision, "FETCH_HEAD"],
                          capture_output=True, timeout=30).returncode == 0


def validate_uploader(run, workflow, repository, path, attempt):
    require(type(attempt) is int and attempt > 0 and run["run_attempt"] == attempt,
            "cloud evidence importer attempt is stale")
    require(workflow["path"] == path and run["path"] == path and run["workflow_id"] == workflow["id"]
            and run["event"] == "workflow_dispatch" and run["head_branch"] == "main"
            and run["repository"]["full_name"] == run["head_repository"]["full_name"] == repository
            and run["status"] == "completed" and run["conclusion"] == "success" and on_main(run["head_sha"]),
            "cloud evidence uploader is not a successful trusted main workflow")


def trusted_artifact(api, name, path, member):
    from ci_publish import git, json_member, positive
    workflow = api.repo("actions/workflows/" + path.rsplit("/", 1)[-1], missing=True)
    require(workflow is not None and workflow["path"] == path, "trusted cloud workflow is unavailable")
    git("fetch", "--no-tags", "origin", "refs/heads/main")
    candidates = []
    for artifact in api.pages("actions/artifacts", "artifacts", name=name):
        if artifact["name"] != name or artifact["expired"]:
            continue
        uploader = api.repo("actions/runs/" + str(positive(artifact["workflow_run"]["id"])))
        # A hostile producer can upload a colliding name; never open its bytes.
        if uploader["path"] != path or uploader["workflow_id"] != workflow["id"] or uploader["head_branch"] != "main":
            continue
        receipt = json_member(api, artifact, member)
        validate_uploader(uploader, workflow, api.repository, path, receipt["uploader_attempt"])
        require(receipt["uploader_run_id"] == uploader["id"], "cloud artifact uploader differs")
        candidates.append((receipt, artifact["id"]))
    require(len(candidates) == 1, "trusted cloud evidence is missing, expired, duplicated or conflicting")
    return candidates[0]


def trusted_cloud(api, record, run, *, approved):
    route, route_artifact = trusted_artifact(api, f"ci-xcc-route-{run['id']}-{run['run_attempt']}", ROUTE_PATH, "route.json")
    validate_route(record, run, route)
    receipt, import_artifact = trusted_artifact(api, f"ci-xcc-import-{run['id']}-{run['run_attempt']}", IMPORT_PATH, "cloud.json")
    require(type(receipt.get("schema_version")) is int and receipt["schema_version"] == 1
            and receipt["identity"] == record["identity"] and receipt["producer_run_id"] == run["id"]
            and receipt["producer_attempt"] == run["run_attempt"] and receipt["route_artifact_id"] == route_artifact,
            "cloud importer receipt is not bound to this route, admission and attempt")
    # Re-read app checks when publishing: importer success cannot cover a later
    # stale, failed or ambiguous app check or a replaced routing artifact.
    checks = api.pages("commits/" + record["identity"]["head_sha"] + "/check-runs", "check_runs", filter="all")
    result = validate_evidence(record, run, route, receipt["evidence"], checks, approved=approved)
    return dict(result, route_artifact_id=route_artifact, import_artifact_id=import_artifact)


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
