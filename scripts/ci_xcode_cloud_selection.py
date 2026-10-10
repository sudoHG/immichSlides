"""Trusted selection pointers and runtime plans; no candidate Python execution."""

from __future__ import annotations

import copy
import hashlib

import ci_xcode_cloud_groups as groups
from ci_summary import require


def write_pointer(api, app, record, run, group):
    descriptor = groups.selection(record, run, group, approved=False)
    digest = groups.canonical_hash(descriptor)
    context = f"ci-xcc-selection/{run['id']}/{run['run_attempt']}/{group}"
    statuses = api.pages("commits/" + run["head_sha"] + "/statuses")
    trusted = [status for status in statuses if status.get("context") == context
               and status.get("creator", {}).get("login") == groups.PUBLISHER_LOGIN
               and status["creator"].get("id") == groups.PUBLISHER_ID]
    if not trusted:
        app.status(run["head_sha"], context, "success", groups.POINTER_DESCRIPTION_PREFIX + record["identity"]["base_sha"] + " " + digest,
                   "https://github.com/" + api.repository + "/commit/" + record["identity"]["merge_sha"])
        statuses = api.pages("commits/" + run["head_sha"] + "/statuses")
        trusted = [status for status in statuses if status.get("context") == context
                   and status.get("creator", {}).get("login") == groups.PUBLISHER_LOGIN
                   and status["creator"].get("id") == groups.PUBLISHER_ID]
    require(trusted, "selection pointer write is not visible")
    pointer_id = max(status["id"] for status in trusted)
    groups.validate_pointer(record, run, group, digest, statuses, pointer_id=pointer_id)
    return pointer_id


def runtime_plans(record, descriptor):
    plans = {}
    for action in descriptor["registration"]["actions"]:
        path = action["plan_path"]
        keys = [{entry["key"] for entry in descriptor["populations"][device]} for device in action["devices"]]
        require(keys and keys[0] and all(value == keys[0] for value in keys), "Cloud action needs equal nonempty device selections")
        plan = copy.deepcopy(record["cloud_v2_inputs"]["plans"][path])
        require(len(plan["testTargets"]) == 1 and plan["testTargets"][0]["target"]["name"] == "immichSlidesUITests",
                "runtime plan needs one UI target")
        plan["testTargets"][0].update(selectedTests=[key + "()" for key in sorted(keys[0])], skippedTests=[])
        require(groups.canonical_hash(plan) == descriptor["runtime_plan_sha256"][path], "runtime plan hash differs")
        plans[path] = plan
    return plans


def recompute(identity, run, author, *, listing, read_blob, changed_paths, head_tree):
    """Repeat admission's functional selector using base rules and static merge data."""
    from ci_population import ui_identities
    from ci_ui_packing import pack_scoped_selection
    from ci_ui_selection import platform_sources_from_project, select_ui_population
    base, head, merge = identity["base_sha"], identity["head_sha"], identity["merge_sha"]
    base_listing, head_listing, merged_listing = listing(base), listing(head), listing(merge)
    inputs = groups.snapshot(base, head, base_listing, head_listing, read_blob, head_tree)
    require(inputs is not None, "Cloud registry is absent from the trusted base")
    sources = {entry["path"]: read_blob(merge, entry["path"]) for entry in merged_listing
               if entry["path"].startswith("immichSlidesUITests/") and entry["path"].endswith(".swift")
               and entry["mode"] in {"100644", "100755"}}
    populations = {"ui-" + platform: ui_identities(sources, platform) for platform in ("ios", "tvos")}
    members = sorted({entry["path"] for entry in base_listing + merged_listing
                      if entry["path"].startswith("immichSlides/")})
    raw_map = read_blob(base, "scripts/ci-ui-areas.json")
    selected = select_ui_population(changed_paths or ["__unknown_empty_diff__"],
        groups.decode(read_blob(base, "scripts/ci-classification.json")), build_target_paths=members,
        area_map=raw_map, populations=populations, plans={platform: read_blob(base,
            "immichSlides-" + suffix + ".xctestplan") for platform, suffix in (("ios", "iOS"), ("tvos", "tvOS"))},
        event="pull_request", platform_scoped=True, functional_only=True,
        platform_sources=platform_sources_from_project(read_blob(base, "immichSlides.xcodeproj/project.pbxproj")),
        expected_skips=groups.decode(read_blob(base, "scripts/ci-test-policy.json"))["expected_skips"])
    require(selected["mode"] == "scoped", "Cloud functional selection could not be reconstructed")
    packing = pack_scoped_selection(selected["populations"], read_blob(base, "scripts/ci-ui-durations.json"))
    selected.update(map_revision=base, map_sha256=hashlib.sha256(raw_map.encode()).hexdigest(),
                    shards=packing["shards"], packing=packing)
    return {"identity": identity, "run_id": run["id"], "cloud_pr_author": author,
            "cloud_v2_inputs": inputs, "ui_inputs": {"base": {"selection": selected}}}


def publish_pointers(api, app, pr_number):
    """Called only by the existing main publisher credential job, under its lock."""
    from ci_publish import authoritative_run, trusted_admissions
    from ci_summary import ContractError
    if not pr_number:
        return
    pr = api.repo(f"pulls/{pr_number}")
    if (pr["state"] != "open" or pr["user"]["login"] != groups.MAINTAINER_LOGIN
            or pr["user"]["id"] != groups.MAINTAINER_ID
            or pr["head"]["repo"]["full_name"] != api.repository):
        return
    workflow = api.repo("actions/workflows/ci-ui.yml")
    runs = api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs",
                     head_sha=pr["head"]["sha"], event="pull_request")
    run = authoritative_run(runs, pr["head"]["sha"], workflow, api.repository)
    if run is None or run["status"] == "completed":
        return
    record = trusted_admissions(api, [run["id"]]).get(run["id"])
    inputs = (record or {}).get("cloud_v2_inputs") or {}
    registration = inputs.get("registry") or {}
    if registration.get("routing_enabled") is not True:
        return
    require(record["identity"]["base_sha"] == pr["base"]["sha"]
            and record["identity"]["merge_sha"] == pr["merge_commit_sha"], "Cloud pointer admission base moved")
    for group in registration["groups"]:
        try:
            groups.selection(record, run, group, approved=False)
        except (ContractError, KeyError, TypeError, ValueError):
            continue  # Empty or unsupported groups retain complete GitHub selection.
        fresh = api.repo(f"pulls/{pr_number}")
        current = api.repo("actions/runs/" + str(run["id"]))
        require(fresh["head"]["sha"] == run["head_sha"] and fresh["base"]["sha"] == record["identity"]["base_sha"]
                and fresh["user"] == pr["user"]
                and current["run_attempt"] == run["run_attempt"] and current["status"] != "completed",
                "Cloud pointer producer changed before write")
        write_pointer(api, app, record, run, group)
