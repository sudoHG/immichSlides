"""Read scoped Cloud evidence using only an immutable trusted admission.

This module neither schedules builds nor writes selection pointers. The registry
is optional until a separate maintainer/producer rollout registers real workflows.
"""

from __future__ import annotations

import copy
import hashlib
import json
import math
import re
from pathlib import PurePosixPath
from xml.etree import ElementTree

import ci_xcode_cloud as legacy
from ci_summary import decode, identity_key, require, sha, test_identity

REGISTRY_PATH = "scripts/ci-xcode-cloud-groups.json"
GROUPS = {"ios": ("iphone", "ipad"), "tvos": ("appletv",)}
PUBLISHER_LOGIN = "sudohg-ci[bot]"
PUBLISHER_ID = 339382712
MAINTAINER_LOGIN = "sudoHG"
MAINTAINER_ID = 279902076
POINTER_DESCRIPTION_PREFIX = "Selection only: "


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=True, allow_nan=False).encode()).hexdigest()


def registry(value):
    require(isinstance(value, dict) and type(value.get("schema_version")) is int
            and value["schema_version"] == 2 and isinstance(value.get("groups"), dict)
            and value["groups"] and set(value["groups"]) <= set(GROUPS), "unsupported Cloud group registry")
    workflows, check_names, plan_paths = set(), set(), set()
    for group, registration in value["groups"].items():
        if value.get("routing_enabled") is True or "queue_seconds_upper" in registration:
            queue = registration.get("queue_seconds_upper")
            require(type(queue) in {int, float} and math.isfinite(queue) and queue >= 0,
                    "Cloud group lacks a reviewed queue upper bound")
        workflow = legacy.uuid(registration["workflow_id"])
        require(workflow not in workflows, "Cloud groups cannot share a workflow")
        workflows.add(workflow)
        actions = registration["actions"]
        require(isinstance(actions, list) and 0 < len(actions) <= len(GROUPS[group]), "invalid registered Cloud actions")
        devices, names = set(), set()
        for action in actions:
            for field in ("name", "check_name"):
                require(isinstance(action[field], str) and 0 < len(action[field]) <= 256
                        and not any(ord(char) < 32 for char in action[field]), "invalid Cloud action/check name")
            require(action["name"] not in names and action["check_name"] not in check_names, "ambiguous Cloud action/check")
            names.add(action["name"])
            check_names.add(action["check_name"])
            for field, suffix in (("plan_path", ".xctestplan"), ("scheme_path", ".xcscheme")):
                path = action[field]
                require(isinstance(path, str) and len(path) <= 256 and path.endswith(suffix)
                        and not PurePosixPath(path).is_absolute() and ".." not in PurePosixPath(path).parts
                        and str(PurePosixPath(path)) == path, "invalid Cloud plan/scheme path")
            require(action["plan_path"] not in plan_paths, "Cloud actions need distinct plan templates")
            plan_paths.add(action["plan_path"])
            destinations = action["devices"]
            require(isinstance(destinations, dict) and destinations and set(destinations) <= set(GROUPS[group])
                    and not set(destinations) & devices, "Cloud destination registration overlaps groups/actions")
            labels = []
            for destination in destinations.values():
                require(set(destination) == {"device", "os"} and all(isinstance(item, str) and item
                        and len(item) <= 128 for item in destination.values()), "invalid registered Cloud destination")
                labels.append((destination["device"], destination["os"]))
            require(len(labels) == len(set(labels)), "ambiguous Cloud device labels")
            devices.update(destinations)
        require(devices == set(GROUPS[group]), "Cloud registration must cover the whole platform group")
    return value


def snapshot(base, head, base_listing, head_listing, read_blob, head_tree):
    """Hash regular Git objects; never import or execute a head hook/generator."""
    paths = lambda listing: {entry["path"] for entry in listing if entry["type"] == "blob"
                             and entry["mode"] in {"100644", "100755"}}
    base_paths, head_paths = paths(base_listing), paths(head_listing)
    if REGISTRY_PATH not in base_paths:
        return None
    require(all(len({entry["path"].casefold() for entry in listing}) == len(listing)
                for listing in (base_listing, head_listing)), "ambiguous Cloud checkout paths")
    registration = registry(decode(read_blob(base, REGISTRY_PATH)))
    hook_entries = lambda listing: {(entry["path"], entry["mode"], entry["type"])
                                   for entry in listing if entry["path"].startswith("ci_scripts/")}
    require(hook_entries(base_listing) == hook_entries(head_listing), "Cloud hook population changed")
    hooks = {entry[0] for entry in hook_entries(base_listing)}
    required = hooks | {REGISTRY_PATH, "scripts/strict_e2e_server.py", "ci_scripts/fixture_server.py"}
    required |= {path for path in base_paths if path.startswith("scripts/ci_xcode_cloud") and path.endswith(".py")}
    required |= {"scripts/ci_ui_selection.py", "scripts/ci_ui_packing.py", "scripts/ci_ui_test_kinds.py",
                 "scripts/ci_ui_shards.py", "scripts/ci-ui-areas.json", "scripts/ci-ui-durations.json"}
    actions = [action for group in registration["groups"].values() for action in group["actions"]]
    required |= {action[field] for action in actions for field in ("plan_path", "scheme_path")}
    require(required <= base_paths and required <= head_paths, "Cloud trusted inputs are absent or not regular blobs")
    files, plans = {}, {}
    for path in sorted(required):
        raw = read_blob(base, path)
        require(raw == read_blob(head, path), "Cloud trusted input changed; use GitHub")
        files[path] = hashlib.sha256(raw.encode()).hexdigest()
    require(files["scripts/strict_e2e_server.py"] == files["ci_scripts/fixture_server.py"], "Cloud fixture copy differs")
    for action in actions:
        path = action["plan_path"]
        scheme = read_blob(base, action["scheme_path"])
        require(len(scheme.encode()) <= 1024 * 1024 and "<!DOCTYPE" not in scheme and "<!ENTITY" not in scheme,
                "unsupported Cloud scheme")
        root = ElementTree.fromstring(scheme)
        test_actions = root.findall("TestAction")
        require(root.tag == "Scheme" and len(test_actions) == 1
                and test_actions[0].find(".//PreActions") is None and test_actions[0].find(".//PostActions") is None,
                "Cloud scheme has ambiguous or executable TestActions")
        references = [item.get("reference", "") for item in test_actions[0].findall(".//TestPlanReference")
                      if PurePosixPath(item.get("reference", "").removeprefix("container:")).name.casefold()
                      == PurePosixPath(path).name.casefold()]
        matches = [item for item in head_paths if PurePosixPath(item).name.casefold() == PurePosixPath(path).name.casefold()]
        require(references == ["container:" + path] and matches == [path], "Cloud scheme redirects or shadows its plan")
        plans[path] = decode(read_blob(base, path))
    return {"registry": registration, "files": files, "plans": plans, "head_tree_sha": head_tree}


def selection(record, run, group, *, approved):
    """Reconstruct the pointer payload from base-owned rules and admitted data."""
    identity = record["identity"]
    require(group in GROUPS and run["path"] == legacy.UI_PATH and identity["event"] == run["event"] == "pull_request"
            and run["repository"]["full_name"] == run["head_repository"]["full_name"] == identity["repository"]
            and record.get("cloud_pr_author", {}).get("login") == MAINTAINER_LOGIN
            and type(record.get("cloud_pr_author", {}).get("id")) is int
            and record["cloud_pr_author"]["id"] == MAINTAINER_ID, "Cloud groups are maintainer PRs only")
    require(record["run_id"] == run["id"] and run["head_sha"] == identity["head_sha"]
            and type(run["run_attempt"]) is int and run["run_attempt"] > 0, "Cloud group producer is stale")
    for field in ("base_sha", "head_sha", "merge_sha", "tree_sha"):
        sha(identity[field])
    require(type(identity["pull_request"]) is int and identity["pull_request"] > 0, "Cloud PR identity is missing")
    inputs = record.get("cloud_v2_inputs")
    require(isinstance(inputs, dict) and inputs["head_tree_sha"] == identity["tree_sha"], "Cloud head differs from admitted merge tree")
    registration = registry(inputs["registry"])["groups"].get(group)
    require(registration is not None, "Cloud platform workflow is not registered on the trusted base")
    ui = record["ui_inputs"]["candidate" if approved else "base"]
    selected = ui["selection"]
    require(selected["mode"] == "scoped" and selected.get("coverage") == "functional"
            and selected["map_revision"] == identity["base_sha"] and selected.get("packing"),
            "Cloud requires a trusted packed functional selection")
    from ci_ui_test_kinds import method_kind
    populations = {}
    for device in GROUPS[group]:
        entries = [entry for shard in selected["shards"][device].values() for entry in shard]
        require(entries and all(entry == test_identity("ui", entry["key"], platform=group, device=device)
                and method_kind(entry["key"]) == "functional" for entry in entries)
                and len({identity_key(entry) for entry in entries}) == len(entries), "invalid or empty functional Cloud selection")
        populations[device] = sorted(entries, key=identity_key)
    plan_hashes = {}
    for action in registration["actions"]:
        keys = [{entry["key"] for entry in populations[device]} for device in action["devices"]]
        require(all(value == keys[0] for value in keys), "one Cloud action cannot run different per-device selections")
        plan = copy.deepcopy(inputs["plans"][action["plan_path"]])
        targets = plan.get("testTargets")
        require(isinstance(targets, list) and len(targets) == 1 and targets[0]["target"]["name"] == "immichSlidesUITests"
                and targets[0].get("enabled", True) is True, "Cloud plan needs one enabled UI target")
        targets[0]["selectedTests"] = [key + "()" for key in sorted(keys[0])]
        targets[0]["skippedTests"] = []
        plan_hashes[action["plan_path"]] = canonical_hash(plan)
    require(isinstance(inputs["files"], dict) and inputs["files"], "Cloud trusted input hashes are absent")
    for value in list(inputs["files"].values()) + [selected["map_sha256"], selected["packing"]["sha256"]]:
        sha(value, 64)
    return {"schema_version": 2, "identity": identity, "producer_run_id": run["id"],
            "producer_attempt": run["run_attempt"], "group": group, "registration": registration,
            "files": inputs["files"], "map_sha256": selected["map_sha256"],
            "packing_sha256": selected["packing"]["sha256"], "populations": populations,
            "runtime_plan_sha256": plan_hashes}


def validate_pointer(record, run, group, digest, statuses, *, pointer_id):
    identity = record["identity"]
    context = f"ci-xcc-selection/{run['id']}/{run['run_attempt']}/{group}"
    trusted = [status for status in statuses if status.get("context") == context
               and status.get("creator", {}).get("login") == PUBLISHER_LOGIN
               and status["creator"].get("id") == PUBLISHER_ID]
    require(trusted and all(type(status.get("id")) is int and status["id"] > 0 for status in trusted), "trusted Cloud selection pointer is absent")
    newest = max(status["id"] for status in trusted)
    require(type(pointer_id) is int and pointer_id == newest and len({status["id"] for status in trusted}) == len(trusted),
            "Cloud pointer was replaced or is ambiguous")
    for status in trusted:
        require(status["state"] == "success"
                and status.get("url") == "https://api.github.com/repos/" + identity["repository"] + "/statuses/" + identity["head_sha"]
                and status["description"] == POINTER_DESCRIPTION_PREFIX + identity["base_sha"] + " " + digest
                and status["target_url"] == "https://github.com/" + identity["repository"] + "/commit/" + identity["merge_sha"],
                "Cloud selection pointer differs from admission")


def validate_route(record, run, route, statuses, *, approved):
    group = route["group"]
    descriptor = selection(record, run, group, approved=approved)
    digest = canonical_hash(descriptor)
    registration = descriptor["registration"]
    require(type(route.get("schema_version")) is int and route["schema_version"] == 2
            and route["identity"] == record["identity"] and route["decision"] == "routed"
            and type(route["producer_run_id"]) is int and route["producer_run_id"] == run["id"]
            and type(route["producer_attempt"]) is int and route["producer_attempt"] == run["run_attempt"]
            and route["workflow_id"] == registration["workflow_id"] and route["selection_sha256"] == digest
            and route["runtime_plan_sha256"] == descriptor["runtime_plan_sha256"],
            "Cloud group route differs from trusted selection")
    validate_pointer(record, run, group, digest, statuses, pointer_id=route["pointer_id"])
    legacy.uuid(route["cloud_run_id"])
    return descriptor


def validate_evidence(record, run, route, evidence, checks, statuses, *, approved):
    descriptor = validate_route(record, run, route, statuses, approved=approved)
    group, registration = descriptor["group"], descriptor["registration"]
    require(evidence["id"] == route["cloud_run_id"] and evidence["workflow_id"] == registration["workflow_id"]
            and evidence["head_sha"] == record["identity"]["head_sha"] and evidence.get("is_pull_request_build") is False
            and evidence["progress"] == "COMPLETE" and evidence["status"] == "SUCCEEDED", "Cloud group run is incomplete or stale")
    wall = legacy.duration(evidence["started"], evidence["finished"])
    actions = evidence["actions"]
    require(isinstance(actions, list) and len(actions) == len(registration["actions"])
            and len({action["id"] for action in actions}) == len(actions)
            and len({action["name"] for action in actions}) == len(actions), "Cloud test actions differ from registry")
    observed, result_ids, action_proofs = [], set(), []
    for registered in registration["actions"]:
        matches = [action for action in actions if action["name"] == registered["name"]]
        require(len(matches) == 1, "registered Cloud test action is missing")
        action = matches[0]
        legacy.uuid(action["id"])
        require(action["type"] == "TEST" and action["progress"] == "COMPLETE" and action["status"] == "SUCCEEDED", "Cloud test action did not pass")
        compute = legacy.duration(action["started"], action["finished"])
        require(compute <= wall, "Cloud action exceeds run duration")
        legacy.duration(evidence["started"], action["started"])
        legacy.duration(action["finished"], evidence["finished"])
        tests = action["tests"]
        require(isinstance(tests, list) and tests, "Cloud method evidence is missing")
        for test in tests:
            require(isinstance(test["id"], str) and test["id"] and test["id"] not in result_ids, "duplicate Cloud API results")
            result_ids.add(test["id"])
            require(isinstance(test["class"], str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", test["class"])
                    and isinstance(test["method"], str) and re.fullmatch(r"test[A-Za-z0-9_]+\(\)", test["method"])
                    and test["status"] == "SUCCESS", "invalid, failed or skipped Cloud method")
            destinations = test["destinations"]
            require(isinstance(destinations, list) and len(destinations) == len(registered["devices"]), "Cloud method destination population differs")
            seen = set()
            for destination in destinations:
                matches = [device for device, label in registered["devices"].items() if destination == dict(label, status="SUCCESS")]
                require(len(matches) == 1 and matches[0] not in seen, "Cloud method destination is failed, duplicated or unexpected")
                seen.add(matches[0])
                observed.append(test_identity("ui", test["class"] + "/" + test["method"][:-2], platform=group, device=matches[0]))
        details = ("https://appstoreconnect.apple.com/teams/" + legacy.TEAM_ID + "/apps/" + legacy.APPLE_APP_ID
                   + "/ci/builds/" + evidence["id"] + "/action/" + action["id"])
        matching = [check for check in checks if check.get("app", {}).get("id") == legacy.APP_ID
                    and check["app"].get("slug") == "xcode-cloud" and check.get("name") == registered["check_name"]
                    and check.get("head_sha") == record["identity"]["head_sha"]]
        require(matching and all(type(check.get("id")) is int and check["id"] > 0 for check in matching), "Cloud app check is absent")
        newest = [check for check in matching if check["id"] == max(item["id"] for item in matching)]
        require(len(newest) == 1 and newest[0]["status"] == "completed" and newest[0]["conclusion"] == "success"
                and newest[0].get("details_url") == details, "newest Cloud app check differs from this action")
        action_proofs.append({"action_id": action["id"], "details_url": details, "action_minutes": compute,
                              "compute_upper_minutes": len(registered["devices"]) * compute})
    population = sorted([entry for entries in descriptor["populations"].values() for entry in entries], key=identity_key)
    require(len({identity_key(entry) for entry in observed}) == len(observed)
            and sorted(observed, key=identity_key) == population, "Cloud executed per-device selection differs from admission")
    return {"group": group, "identities": population, "selection_sha256": canonical_hash(descriptor),
            "runtime_plan_sha256": descriptor["runtime_plan_sha256"], "pointer_id": route["pointer_id"],
            "cloud_run_id": evidence["id"], "actions": action_proofs, "wall_minutes": wall,
            "action_minutes": sum(action["action_minutes"] for action in action_proofs),
            "compute_upper_minutes": sum(action["compute_upper_minutes"] for action in action_proofs)}


def trusted_groups(api, record, run, groups, *, approved):
    """Keep artifact authentication before bytes and reread live app/pointer state."""
    require(groups and set(groups) <= set(GROUPS), "unknown Cloud groups")
    from ci_publish_git import workflow_contract
    source = record["workflows"][legacy.UI_PATH]["candidate" if approved else "base"]
    _, _, _, metadata = workflow_contract(source, run, metadata=True)
    anchors = [name for name, meta in metadata.items() if meta["population"] in {"ui-archive", "ui-selection"}]
    require(len(anchors) == 1, "Cloud group selection execution is ambiguous")
    run = legacy.archive_evidence_run(api, run, selection_job=anchors[0])
    proofs = {}
    for group in sorted(groups):
        suffix = f"{run['id']}-{run['run_attempt']}-{group}"
        route, route_id = legacy.trusted_artifact(api, "ci-xcc-route-" + suffix, legacy.ROUTE_PATH, "route.json")
        require(route["group"] == group, "Cloud route artifact belongs to another group")
        statuses = api.pages("commits/" + record["identity"]["head_sha"] + "/statuses")
        descriptor = validate_route(record, run, route, statuses, approved=approved)
        receipt, import_id = legacy.trusted_artifact(api, "ci-xcc-import-" + suffix, legacy.IMPORT_PATH, "cloud.json")
        require(type(receipt.get("schema_version")) is int and receipt["schema_version"] == 2
                and type(receipt.get("route_artifact_id")) is int and receipt["route_artifact_id"] == route_id
                and receipt.get("selection") == descriptor
                and receipt.get("runtime_plan_sha256") == receipt["selection"]["runtime_plan_sha256"],
                "Cloud receipt descriptor/route binding differs")
        for field in ("identity", "producer_run_id", "producer_attempt", "group", "selection_sha256", "pointer_id"):
            require(type(receipt[field]) is type(route[field]) and receipt[field] == route[field], "Cloud import receipt binding differs")
        checks = api.pages("commits/" + record["identity"]["head_sha"] + "/check-runs", "check_runs", filter="all")
        statuses = api.pages("commits/" + record["identity"]["head_sha"] + "/statuses")
        proof = validate_evidence(record, run, route, receipt["evidence"], checks, statuses, approved=approved)
        proofs[group] = dict(proof, route_artifact_id=route_id, import_artifact_id=import_id, evidence_attempt=run["run_attempt"])
    identities = sorted([entry for proof in proofs.values() for entry in proof["identities"]], key=identity_key)
    return {"schema_version": 2, "groups": proofs, "identities": identities}


def cloud_devices(proof):
    if proof is None:
        return set()
    if proof.get("schema_version") != 2:
        return {"appletv"}
    require(proof.get("groups") and set(proof["groups"]) <= set(GROUPS), "invalid Cloud proof groups")
    return {device for group in proof["groups"] for device in GROUPS[group]}


def skipped_groups(source, run, jobs, record, *, approved):
    """Do not require Cloud evidence for a base-selected empty platform matrix."""
    ui = record["ui_inputs"]["candidate" if approved else "base"]
    selected = (ui.get("selection") or {}).get("shards", {})
    return {group for group, devices in GROUPS.items()
            if any(entries for device in devices for entries in selected.get(device, {}).values())
            and any(job["conclusion"] == "skipped" and job["name"] in skip_names(source, run, devices) for job in jobs)}


def skip_names(source, run, devices):
    import yaml
    from check_workflow_policy import WorkflowLoader
    from ci_publish_git import workflow_contract
    workflow = yaml.load(source, Loader=WorkflowLoader)
    _, _, _, metadata = workflow_contract(source, run, metadata=True)
    names = {name for name, meta in metadata.items() if meta.get("device") in devices}
    for key, job in workflow["jobs"].items():
        if not job.get("strategy", {}).get("matrix"):
            continue
        _, _, _, entries = workflow_contract(yaml.safe_dump({"jobs": {key: job}}), run, metadata=True)
        if entries and all(meta.get("device") in devices for meta in entries.values()):
            names.add(job.get("name", key))
    return names
