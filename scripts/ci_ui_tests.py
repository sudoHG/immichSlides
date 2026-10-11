#!/usr/bin/env python3
"""Wait for identity-bound gate archives and run manifest-selected fixture UI shards."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import platform
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.error
import zipfile
from pathlib import Path
from urllib.request import Request, build_opener

from ci_build_archive import (artifact_name, check_products, extract_products, file_hash, measure_signing,
                              output, validate_artifact, validate_manifest, workspace_preflight)
from ci_publish import ArtifactRedirect, RateLimitWaitingGitHub, json_member, rate_limit_wait, verify_workflow
from ci_summary import (ContractError, decode, observation, parse_identity, parse_summary, require, test_identity, write_summary)
from ci_summary import identity_key, validate_test_identity
from ci_ui_shards import DEVICES, MANIFEST_PATH, parse_shard_manifest, shard_populations
from ci_verdict import classify_changes
from run_host_checks import run_identity, source_metadata
from ci_wait_policy import wait_configuration

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ".github/workflows/ci-ui.yml"
GATE_WORKFLOW = ".github/workflows/ci-gate.yml"
NIGHTLY_WORKFLOW = ".github/workflows/ci-nightly.yml"
GATE_PENDING_PAUSE_SECONDS = 50 * 60  # 120 + 50 = 170-minute cap leaves 15 minutes of the 185-minute job for final reads and downloads
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def git_blob(revision, path):
    return subprocess.check_output(["git", "show", revision + ":" + path], cwd=ROOT, timeout=60)


def context():
    ci = os.environ.get("GITHUB_ACTIONS") == "true"
    identity = run_identity(os.environ, ci=ci)
    require(identity["event"] in {"pull_request", "push", "local", "schedule", "workflow_dispatch"}, "unsupported UI producer event")
    expected_workflow = NIGHTLY_WORKFLOW if identity["event"] in {"schedule", "workflow_dispatch"} else WORKFLOW
    workflow, fork = source_metadata(identity, os.environ, expected_workflow if ci else None)
    return {"identity": identity,
            "source": {"repository": identity["repository"], "workflow_path": workflow,
                       "event": identity["event"], "fork_originated": fork, "ci_changing": None},
            "run": {"id": os.environ.get("GITHUB_RUN_ID"), "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
                    "tier": "ui-infrastructure", "job": "ui-archive", "shard": None}}


def summary_for(ctx, manifest_hash):
    step = test_identity("host", "Apple TV cloud selection" if ctx["run"]["job"] == "ui-cloud-wait" else "UI archive selection")
    return {"schema_version": 1, **ctx,
            "hashes": {"manifests": {"ui-shards": manifest_hash}, "policies": {}},
            "toolchain": {"versions": {"python": platform.python_version()}, "signing_mode": "not-applicable"},
            "population": {"declared": [step], "compiled": [step], "observed": [], "deselected": [], "removed_by_pr": []},
            "infrastructure": [], "status": "failed"}


def app_affected(identity):
    if identity["event"] != "pull_request":
        return True
    base = identity["base_sha"]
    paths = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", base + "..." + identity["head_sha"]],
                                    cwd=ROOT, text=True, timeout=60).splitlines()
    members = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", "HEAD", "--", "immichSlides"],
                                      cwd=ROOT, text=True, timeout=60).splitlines()
    return classify_changes(paths or ["__unknown_empty_diff__"], decode(git_blob(base, "scripts/ci-classification.json").decode()),
                            build_target_paths=members)["app_affected"]


def shard_selection(identity):
    """Mirror admission's trusted selection: per-platform shard lists and selected keys (None when full).

    Admission binds the workflow to the same lists from base data; any difference fails closed there.
    """
    order = list(parse_shard_manifest((ROOT / MANIFEST_PATH).read_text())["shards"])
    full = ({platform: order for platform in ("ios", "tvos")}, {platform: None for platform in ("ios", "tvos")}, "full")
    if identity["event"] != "pull_request":
        return full
    from ci_population import ui_identities
    from ci_ui_selection import AREA_MAP_PATH, select_ui_population
    from ci_ui_shards import default_plan_population
    base, head = identity["base_sha"], identity["head_sha"]
    try:
        area_map = git_blob(base, AREA_MAP_PATH).decode()
    except subprocess.CalledProcessError:
        return full  # historical bases without a map stay full-only
    try:
        paths = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", base + "..." + head],
                                        cwd=ROOT, text=True, timeout=60).splitlines()
        members = {path for revision in ("HEAD", base) for path in subprocess.check_output(
            ["git", "ls-tree", "-r", "--name-only", revision, "--", "immichSlides"], cwd=ROOT, text=True, timeout=60).splitlines()}
        ui_root = ROOT / "immichSlidesUITests"
        sources = {path.relative_to(ROOT).as_posix(): path.read_text(encoding="utf-8") for path in ui_root.rglob("*.swift")}
        populations = {"ui-" + platform: ui_identities(sources, platform) for platform in ("ios", "tvos")}
        plans = {platform: git_blob(base, "immichSlides-" + suffix + ".xctestplan").decode()
                 for platform, suffix in (("ios", "iOS"), ("tvos", "tvOS"))}
        manifest = git_blob(base, MANIFEST_PATH).decode()
        selection = select_ui_population(paths or ["__unknown_empty_diff__"],
                                         decode(git_blob(base, "scripts/ci-classification.json").decode()),
                                         build_target_paths=sorted(members), area_map=area_map,
                                         populations=populations, plans=plans, event="pull_request")
    except (ContractError, ValueError, KeyError, subprocess.SubprocessError):
        return full  # a selection error keeps the complete population, as admission does
    if selection["mode"] == "full":
        return full
    lists, keys = {}, {}
    order = list(parse_shard_manifest(manifest)["shards"])
    for platform in ("ios", "tvos"):
        devices = [device for device, item in DEVICES.items() if item == platform]
        chosen = {tuple(entry["key"] for entry in selection["populations"][device]) for device in devices}
        require(len(chosen) == 1, "devices of one platform selected different tests")
        keys[platform] = sorted(chosen.pop())
        shards = shard_populations(populations["ui-" + platform], plans[platform], manifest, devices[0])
        lists[platform] = [shard for shard in order if any(entry["key"] in keys[platform] for entry in shards[shard])]
        require(set(keys[platform]) <= {entry["key"] for entry in default_plan_population(
            populations["ui-" + platform], plans[platform])}, "selection is outside the default plan")
    return lists, keys, selection["mode"]


def planned_ui_selection(identity, *, pack_scoped_ui=False, scoped_ui_v2=False):
    """Repeat the admitted base protocol; publication independently checks this exact plan."""
    if not pack_scoped_ui or identity["event"] != "pull_request":
        lists, keys, mode = shard_selection(identity)
        return {"mode": mode, "platform_shards": lists, "keys": keys, "packing": None,
                "device_shards": {device: lists[platform] for device, platform in DEVICES.items()}}
    from ci_population import ui_identities
    from ci_ui_selection import AREA_MAP_PATH, platform_sources_from_project, select_ui_population
    from ci_ui_packing import DURATIONS_PATH, pack_scoped_selection
    base = identity["base_sha"]
    paths = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", base + "..." + identity["head_sha"]],
                                    cwd=ROOT, text=True, timeout=60).splitlines()
    members = {path for revision in ("HEAD", base) for path in subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", revision, "--", "immichSlides"], cwd=ROOT, text=True, timeout=60).splitlines()}
    sources = {path.relative_to(ROOT).as_posix(): path.read_text(encoding="utf-8")
               for path in (ROOT / "immichSlidesUITests").rglob("*.swift")}
    populations = {"ui-" + platform: ui_identities(sources, platform) for platform in ("ios", "tvos")}
    plans = {platform: git_blob(base, "immichSlides-" + suffix + ".xctestplan").decode()
             for platform, suffix in (("ios", "iOS"), ("tvos", "tvOS"))}
    try:
        project = git_blob(base, "immichSlides.xcodeproj/project.pbxproj").decode()
    except subprocess.CalledProcessError:
        project = ""  # Missing platform proof remains shared, never an excluded platform.
    selection = select_ui_population(paths or ["__unknown_empty_diff__"],
        decode(git_blob(base, "scripts/ci-classification.json").decode()), build_target_paths=sorted(members),
        area_map=git_blob(base, AREA_MAP_PATH).decode(), populations=populations, plans=plans, event="pull_request",
        platform_scoped=True, platform_sources=platform_sources_from_project(project), functional_only=True,
        expected_skips=decode(git_blob(base, "scripts/ci-test-policy.json").decode())["expected_skips"])
    packing = (pack_scoped_selection(selection["populations"], git_blob(base, DURATIONS_PATH).decode(),
                                    **({"algorithm": "capacity-v2"} if scoped_ui_v2 else {}))
               if selection["mode"] == "scoped" else None)
    device_shards = {device: list(packing["shards"][device]) if packing else [] for device in DEVICES}
    lists = {platform: sorted({name for device in DEVICES if DEVICES[device] == platform
                              for name in device_shards[device]}) for platform in ("ios", "tvos")}
    keys = {platform: sorted({entry["key"] for device in DEVICES if DEVICES[device] == platform
                             for entry in selection["populations"][device]}) for platform in ("ios", "tvos")}
    return {"mode": selection["mode"], "coverage": "functional", "platform_shards": lists,
            "device_shards": device_shards, "keys": keys, "packing": packing}


def selected_shard(population, plan, manifest, device, name, selection=None):
    """Validate packed selectors before executing the unchanged fixture runner."""
    from ci_ui_packing import canonical_hash
    from ci_ui_shards import default_plan_population
    packing = (selection or {}).get("packing")
    if packing is None:
        require(name in manifest["shards"], "shard is absent from the requested manifest revision")
        entries = shard_populations(population, plan, manifest, device)[name]
        keys = (selection or {}).get("selected_keys")
        return [entry for entry in entries if keys is None or entry["key"] in set(keys)]
    require(packing.get("sha256") == canonical_hash({key: value for key, value in packing.items() if key != "sha256"}),
            "packed UI plan hash differs")
    require(device in packing["shards"] and name in packing["shards"][device], "packed UI shard is absent")
    entries = packing["shards"][device][name]
    allowed = {entry["key"] for entry in default_plan_population(population, plan)}
    for entry in entries:
        validate_test_identity(entry)
        require(entry["kind"] == "ui" and entry["dimensions"] == {"platform": DEVICES[device], "device": device}
                and entry["key"] in allowed, "packed UI method differs from its default-plan device")
    require(len({identity_key(entry) for entry in entries}) == len(entries), "duplicate packed UI method")
    return entries


def downloaded_archive(api, artifact):
    require(artifact["expired"] is False and 0 < artifact["size_in_bytes"] <= MAX_ARCHIVE_BYTES,
            "build archive is expired or exceeds the bounded download")
    request = Request(f"https://api.github.com/repos/{api.repository}/actions/artifacts/{artifact['id']}/zip",
                      headers={"Authorization": "Bearer " + api.token, "Accept": "application/vnd.github+json"})
    timeout = 60
    while True:
        try:
            with build_opener(ArtifactRedirect()).open(request, timeout=timeout) as response:
                raw = response.read(MAX_ARCHIVE_BYTES + 1)
            break
        except urllib.error.HTTPError as error:
            wait = rate_limit_wait(error)
            if wait is None or not isinstance(api, RateLimitWaitingGitHub) or not api.pause_for(wait):
                raise ContractError(f"Archive download refused (HTTP {error.code})") from None
            timeout = api.retry_timeout(timeout)
    require(len(raw) <= MAX_ARCHIVE_BYTES, "build archive download exceeds limit")
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entries = archive.infolist()
        require(len(entries) == 2 and {entry.filename for entry in entries} == {"manifest.json", "build.tar.gz"},
                "unexpected build archive ZIP contents")
        require(all(entry.file_size <= MAX_ARCHIVE_BYTES for entry in entries), "oversized build archive member")
        require(next(entry.file_size for entry in entries if entry.filename == "manifest.json") <= 4 * 1024 * 1024,
                "build manifest exceeds limit")
        manifest_raw, tar_raw = archive.read("manifest.json"), archive.read("build.tar.gz")
        require(len(manifest_raw) <= 4 * 1024 * 1024, "build manifest exceeds limit")
        manifest = decode(manifest_raw.decode())
        require(hashlib.sha256(tar_raw).hexdigest() == manifest["archive_sha256"], "build archive hash differs")
        return manifest, hashlib.sha256(manifest_raw).hexdigest()


def check_cross_run_identity(manifest, identity, run, attempt, pins, pins_hash, *, platform_name="ios"):
    require(parse_identity(manifest["identity"]) == parse_identity(identity), "archive-identity-mismatch: same head has another base or tree")
    require(manifest["producer"] == {"run_id": str(run["id"]), "attempt": attempt, "workflow_path": GATE_WORKFLOW,
                                     "artifact_name": artifact_name(platform_name, str(run["id"]), attempt)}, "archive producer differs")
    require(manifest["platform"] == platform_name and manifest["configuration"] == "Debug", "archive platform/configuration differs")
    require(manifest["xcode_build"] == pins["xcode"]["build"] and manifest["pins_sha256"] == pins_hash,
            "archive toolchain/pins differ")
    require(manifest["signing_mode"] == "adhoc" and manifest["private_configuration_present"] is False,
            "archive is not secret-free and locally signed")


def build_job_attempt(api, run, *, platform_name="ios"):
    retained = None
    require(0 < run["run_attempt"] <= 100, "gate attempts exceed bound")
    for attempt in range(1, run["run_attempt"] + 1):
        matches = [job for job in api.pages(f"actions/runs/{run['id']}/attempts/{attempt}/jobs", "jobs") if job["name"] == "build-" + platform_name]
        require(len(matches) <= 1, "duplicate gate platform producer job")
        if not matches:
            continue
        job = matches[0]
        same = retained and all(job.get(key) and job[key] == retained.get(key) for key in ("started_at", "completed_at", "runner_id"))
        retained = dict(job, evidence_attempt=retained["evidence_attempt"] if same else attempt)
    return retained


class ArchiveWait:
    """One deadline shared by both platforms; pending-gate pauses extend it up to a single allowance."""

    def __init__(self, timeout_seconds):
        self.deadline = time.monotonic() + timeout_seconds
        self.paused = 0.0

    def remaining(self):
        return self.deadline - time.monotonic()

    def pause(self, seconds):
        granted = max(0.0, min(seconds, GATE_PENDING_PAUSE_SECONDS - self.paused))
        self.paused += granted
        self.deadline += granted


# Polling backs off because every waiting UI run shares the repository's 1,000 requests per hour.
POLL_SECONDS, MAX_POLL_SECONDS = 30, 300


def select_archive(api, identity, *, timeout_seconds=0, platform_name="ios", poll_seconds=POLL_SECONDS,
                   max_poll_seconds=MAX_POLL_SECONDS, record_refusals=None, wait=None):
    wait = wait or ArchiveWait(timeout_seconds)
    require(platform_name in {"ios", "tvos"}, "unsupported UI archive platform")
    workflow = api.repo("actions/workflows/ci-gate.yml")
    require(workflow["path"] == GATE_WORKFLOW and workflow["state"] == "active", "gate workflow is not active at its expected path")
    head = identity.get("head_sha", identity.get("pushed_sha"))
    head_repository = (api.repo(f"pulls/{identity['pull_request']}")["head"]["repo"]["full_name"]
                       if identity["event"] == "pull_request" else api.repository)
    started, refusals, delay = time.monotonic(), [], poll_seconds
    pins = decode((ROOT / "scripts/ci-pins.json").read_text())
    def refuse(run, outcome, **details):
        refusal = {"run_id": run["id"], "head_sha": head, "consumer_identity": identity,
                   "outcome": outcome, **details}
        if refusal not in refusals:
            refusals.append(refusal)
            if record_refusals:
                record_refusals(refusals)
            print(f"Refused same-head archive from run {run['id']}: {outcome}", flush=True)
    while True:
        runs = api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs", head_sha=head, event=identity["event"])
        runs = [run for run in runs if run.get("head_sha") == head and
                (identity["event"] != "pull_request" or not run.get("pull_requests") or
                 any(pr["number"] == identity["pull_request"] for pr in run["pull_requests"]))]
        newest = max(runs, key=lambda value: value["id"], default=None)
        # Main-push gate runs queue behind the previous main run (see docs/CI_UI.md). The wait for a
        # gate that GitHub holds pending is not counted against the deadline, and a cancelled gate never
        # produces an archive, so that wait ends at once instead of idling for the full deadline.
        main_push = identity["event"] == "push" and newest is not None
        held = main_push and newest.get("status") == "pending"
        superseded = (main_push and newest.get("status") == "completed" and newest.get("conclusion") == "cancelled")
        # Refuse older-base artifacts instead of reusing an arbitrary same-head build.
        # The newest available matching identity is selected; newer in-progress
        # matching runs must finish their build before older runs can be reused.
        for run in sorted(runs, key=lambda value: value["id"], reverse=True):
            verify_workflow(run, workflow, api.repository)
            if run["head_repository"]["full_name"] != head_repository:
                refuse(run, "archive-head-repository-mismatch", producer_head_repository=run["head_repository"]["full_name"])
                continue
            job = build_job_attempt(api, run, platform_name=platform_name)
            attempt = job["evidence_attempt"] if job else run["run_attempt"]
            # Artifacts exist only once the build job finished, so an unfinished build costs no artifact listing.
            finished = job is not None and job["status"] == "completed"
            artifacts = api.pages(f"actions/runs/{run['id']}/artifacts", "artifacts") if finished else []
            name = f"build-{platform_name}-records-{run['id']}-{attempt}"
            records = [artifact for artifact in artifacts if artifact["name"] == name and not artifact["expired"]]
            if not records:
                # A cancelled build may have no summary; its recorded PR base can
                # still prove refusal, but cannot establish an exact identity.
                pr = next((pr for pr in run.get("pull_requests", []) if pr["number"] == identity.get("pull_request")), None)
                base = pr.get("base", {}).get("sha") if pr else None
                if base and base != identity.get("base_sha"):
                    refuse(run, "archive-identity-mismatch", producer_attempt=attempt, producer_base_sha=base)
                    continue
                break
            require(len(records) == 1, "duplicate gate build record")
            build = parse_summary(json_member(api, records[0], "summary.json"))
            require(build["source"]["workflow_path"] == GATE_WORKFLOW and build["source"]["repository"] == api.repository
                    and build["source"]["event"] == identity["event"]
                    and build["source"]["fork_originated"] == (head_repository != api.repository)
                    and build["identity"].get("head_sha", build["identity"].get("pushed_sha")) == head
                    and build["run"] == {"id": str(run["id"]), "attempt": attempt, "tier": "build", "job": "build-" + platform_name, "shard": platform_name},
                    "invalid gate build record provenance")
            if build["identity"] != identity:
                refuse(run, "archive-identity-mismatch", producer_attempt=attempt, producer_identity=build["identity"])
                continue
            require(job["conclusion"] == "success" and build["status"] == "passed", "newest exact-identity gate " + platform_name + " build did not succeed")
            archives = [artifact for artifact in artifacts if artifact["name"] == artifact_name(platform_name, str(run["id"]), attempt)]
            require(len(archives) == 1, "matching archive is missing or duplicated")
            archive = archives[0]
            validate_artifact(archive, identity, str(run["id"]), attempt, platform_name, archive["id"])
            manifest, manifest_hash = downloaded_archive(api, archive)
            check_cross_run_identity(manifest, identity, run, attempt, pins, file_hash(ROOT / "scripts/ci-pins.json"), platform_name=platform_name)
            require(build["hashes"]["manifests"]["build"] == manifest_hash, "gate record and downloaded manifest differ")
            return {"schema_version": 1, "identity": identity, "platform": platform_name, "producer_run_id": str(run["id"]),
                    "producer_attempt": attempt, "artifact_id": archive["id"], "artifact_name": archive["name"],
                    "build_manifest_sha256": manifest_hash, "pins_sha256": file_hash(ROOT / "scripts/ci-pins.json"),
                    "wait_seconds": time.monotonic() - started, "refusals": refusals}
        if superseded:
            break
        if held:
            wait.pause(delay)
        remaining = wait.remaining()
        if remaining <= 0:
            break
        print("Waiting for the matching ci-gate " + platform_name + " archive", flush=True)
        time.sleep(min(delay, remaining))
        delay = min(max_poll_seconds, delay * 2)
    error = "archive-identity-mismatch" if refusals else "archive-unavailable"
    raise ContractError(error + ": no exact-identity gate archive before timeout")


def select_nightly_archive(api, ctx, platform_name):
    run = ctx["run"]
    workflow = api.repo("actions/workflows/ci-nightly.yml")
    producer = api.repo("actions/runs/" + run["id"])
    require(workflow["path"] == NIGHTLY_WORKFLOW and producer["path"] == NIGHTLY_WORKFLOW
            and producer["workflow_id"] == workflow["id"] and producer["repository"]["full_name"] == api.repository
            and producer["head_repository"]["full_name"] == api.repository
            and producer["event"] == ctx["identity"]["event"] and producer["head_sha"] == ctx["identity"]["commit_sha"]
            and producer["run_attempt"] == run["attempt"], "nightly archive producer provenance differs")
    artifacts = api.pages(f"actions/runs/{run['id']}/artifacts", "artifacts")
    matches = [item for item in artifacts if item["name"] == artifact_name(platform_name, run["id"], run["attempt"])]
    require(len(matches) == 1, "missing or duplicate current-attempt nightly archive")
    artifact = matches[0]
    validate_artifact(artifact, ctx["identity"], run["id"], run["attempt"], platform_name, artifact["id"])
    manifest, manifest_hash = downloaded_archive(api, artifact)
    pins = decode((ROOT / "scripts/ci-pins.json").read_text())
    validate_manifest(manifest, ctx["identity"], run["id"], run["attempt"], platform_name,
                      pins["xcode"]["build"], file_hash(ROOT / "scripts/ci-pins.json"))
    return {"schema_version": 1, "identity": ctx["identity"], "platform": platform_name,
            "producer_run_id": run["id"], "producer_attempt": run["attempt"], "artifact_id": artifact["id"],
            "artifact_name": artifact["name"], "build_manifest_sha256": manifest_hash,
            "pins_sha256": file_hash(ROOT / "scripts/ci-pins.json"), "wait_seconds": 0, "refusals": []}


def wait_archive(args):
    ctx = context()
    records = args.output_dir.resolve()
    require(ROOT != records and ROOT not in records.parents, "UI output must be outside checkout")
    records.mkdir(parents=True, exist_ok=False)
    manifest_hash = file_hash(ROOT / MANIFEST_PATH)
    parse_shard_manifest((ROOT / MANIFEST_PATH).read_text())
    summary = summary_for(ctx, manifest_hash)
    started, code = time.monotonic(), 1
    try:
        workspace_preflight(ROOT)
        affected = app_affected(ctx["identity"])
        output("app_affected", str(affected).lower())
        output("selection_artifact", f"ui-archive-{ctx['run']['id']}-{ctx['run']['attempt']}")
        planned = planned_ui_selection(ctx["identity"], pack_scoped_ui=getattr(args, "pack_scoped_ui", False),
                                       scoped_ui_v2=getattr(args, "scoped_ui_v2", False))
        lists, keys, mode = planned["platform_shards"], planned["keys"], planned["mode"]
        if planned["packing"]:
            summary["hashes"]["manifests"]["ui-scoped-plan"] = planned["packing"]["sha256"]
        output("scoped_plan_sha256", planned["packing"]["sha256"] if planned["packing"] else "")
        for device in DEVICES:
            output(device + "_shards", json.dumps(planned["device_shards"][device], separators=(",", ":")))
            from ci_publish_git import ui_capacities
            output(device + "_capacity", str(ui_capacities({"selection": {"packing": planned["packing"]}})[device]))
        for platform_name in ("ios", "tvos"):
            output(platform_name + "_shards", json.dumps(lists[platform_name], separators=(",", ":")))
        write_json(records / "ui-selection.json", {"schema_version": 1, "identity": ctx["identity"], "mode": mode,
                   "shards": lists, "keys": keys, "device_shards": planned["device_shards"], "packing": planned["packing"]})
        print(f"UI selection: {mode}; " + "; ".join(
            f"{name} {len(keys[name]) if keys[name] is not None else 'all'} tests in {len(lists[name])} shards"
            for name in ("ios", "tvos")), flush=True)
        if affected:
            wait = ArchiveWait(max(0, started + args.timeout_minutes * 60 - time.monotonic()))
            api = RateLimitWaitingGitHub(ctx["identity"]["repository"], os.environ["GH_TOKEN"], wait.remaining)
            from ci_ui_reuse import find_reuse
            nightly = ctx["identity"]["event"] in {"schedule", "workflow_dispatch"}
            reuse = find_reuse(api, ctx["identity"]) if ctx["identity"]["event"] == "push" else None
            deferred = (getattr(args, "defer_main_ui", False) and ctx["identity"]["event"] == "push"
                        and ctx["identity"]["ref"] == "refs/heads/main")
            output("run_ui", str(reuse is None and not deferred).lower())
            for platform_name in ("ios", "tvos"):
                output("run_" + platform_name, str(reuse is None and not deferred and bool(lists[platform_name])).lower())
            if reuse is not None:
                write_json(records / "archive-selection.json", {"schema_version": 1, "identity": ctx["identity"],
                           "status": "reused", "verdict": reuse})
                print(f"Reused trusted UI verdict from run {reuse['source']['run_id']}", flush=True)
            elif deferred:
                write_json(records / "archive-selection.json", {"schema_version": 1, "identity": ctx["identity"],
                           "status": "deferred-to-nightly", "verification_workflow": NIGHTLY_WORKFLOW})
                print("UI deferred to nightly: no trusted identical-tree PR verdict", flush=True)
            else:
                for platform_name in ("ios", "tvos"):
                    if not lists[platform_name]:
                        continue
                    selection = select_nightly_archive(api, ctx, platform_name) if nightly else select_archive(api, ctx["identity"], wait=wait,
                                               platform_name=platform_name,
                                               record_refusals=lambda rows, name=platform_name: write_json(records / ("archive-refusals-" + name + ".json"), rows))
                    selection["timeout_minutes"] = args.timeout_minutes
                    selection["selected_keys"] = keys[platform_name]
                    if planned["packing"]:
                        selection["packing"] = planned["packing"]
                    for key in ("artifact_id", "producer_run_id", "producer_attempt"):
                        output(platform_name + "_" + key, selection[key])
                    write_json(records / ("archive-selection-" + platform_name + ".json"), selection)
        else:
            for name in ("run_ui", "run_ios", "run_tvos"):
                output(name, "false")
            write_json(records / "archive-selection.json", {"schema_version": 1, "identity": ctx["identity"], "status": "not-applicable"})
        summary["status"], code = "passed", 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        summary["infrastructure"].append({"code": "archive-selection-failed", "message": str(error)[:200]})
    finally:
        step = summary["population"]["declared"][0]
        summary["population"]["observed"] = [observation(step, "passed" if code == 0 else "failed", time.monotonic() - started,
                    reason=None if code == 0 else "UI archive selection failed", exit_code=code)]
        write_summary(summary, records)
    return code


def wait_cloud(ctx, api):
    """Only this Linux job waits; every rerun revalidates retained archive proof."""
    if ctx["identity"]["event"] != "pull_request" or ctx["source"]["fork_originated"]:
        return "github"
    from datetime import datetime, timezone
    from ci_publish import trusted_admissions
    from ci_xcode_cloud_route import producer_decision, timestamp
    from ci_xcode_cloud import ROUTE_PATH, archive_evidence_run, trusted_artifact
    from ci_xcode_cloud_client import RetryingGitHub, transient
    from ci_xcode_cloud_state import inflight_start, START_TIMEOUT_MINUTES
    from ci_xcode_cloud_route import cloud_wait_deadline
    try:
        run = api.repo("actions/runs/" + ctx["run"]["id"])
        verify_workflow(run, api.repo("actions/workflows/ci-ui.yml"), api.repository)
        require(run["run_attempt"] == ctx["run"]["attempt"] and run["head_sha"] == ctx["identity"]["head_sha"], "UI producer changed")
        record = trusted_admissions(api, [run["id"]]).get(run["id"])
        require(record is not None and record["identity"] == ctx["identity"], "UI admission differs from producer")
        evidence_run = archive_evidence_run(api, run)
        evidence_attempt = evidence_run["run_attempt"]
        if evidence_run["archive_job"]["conclusion"] != "success":
            return "github"
        # Admission fetched main once. Every later receipt uses that same
        # ancestry snapshot, including retries while the build is running.
        if producer_decision(api, record, run, approved=False, evidence_attempt=evidence_attempt, refresh_main=False) == "routed":
            return "routed"
        if evidence_attempt != run["run_attempt"] or record["classification"].get("app_affected") is not True:
            return "github"
        workflows = {role: api.repo("actions/workflows/ci-xcode-cloud-" + role + ".yml") for role in ("route", "import")}
        if any(workflow["state"] != "active" for workflow in workflows.values()):
            return "github"
        start = inflight_start(api, run, evidence_attempt, workflows["route"])
        while start is not None and start.get("awaiting_start"):
            require(start["identity"] == ctx["identity"], "cloud POST marker identity differs from producer")
            if producer_decision(api, record, run, approved=False, evidence_attempt=evidence_attempt, refresh_main=False) == "routed":
                return "routed"
            end = timestamp(start["posted_at"]).timestamp() + START_TIMEOUT_MINUTES * 60
            remaining = end - datetime.now(timezone.utc).timestamp()
            if remaining <= 0:
                return "github"
            time.sleep(min(60, remaining))
            try:
                start = inflight_start(api, run, evidence_attempt, workflows["route"])
            except (ContractError, urllib.error.URLError, TimeoutError) as error:
                if not transient(error):
                    raise
        # Reruns emit no requested event. No build and no POST marker mean
        # GitHub immediately; receipts here only schedule a bounded wait.
        if start is None:
            return "github"
        require(start["identity"] == ctx["identity"], "cloud start identity differs from producer")
        cloud_created = timestamp(start["cloud_created_at"]).timestamp()
        end = cloud_wait_deadline(cloud_created)
        deadline = time.monotonic() + max(0, end - datetime.now(timezone.utc).timestamp())
        if isinstance(api, RetryingGitHub):
            api.deadline = deadline
        delay = 60
        while True:
            try:
                fresh = api.repo("actions/runs/" + str(run["id"]))
                require(all(fresh[key] == run[key] for key in ("id", "run_attempt", "head_sha"))
                        and fresh["status"] != "completed", "UI producer superseded or completed")
                route = None
                try:
                    route, _ = trusted_artifact(api, f"ci-xcc-route-{run['id']}-{evidence_attempt}", ROUTE_PATH, "route.json",
                                                refresh_main=False)
                    if route["decision"] != "routed":
                        return "github"
                    if producer_decision(api, record, run, approved=False, evidence_attempt=evidence_attempt,
                                         route_seen=True, transient_errors=True, refresh_main=False) == "routed":
                        return "routed"
                except (ContractError, KeyError, TypeError, ValueError, OSError, urllib.error.URLError, subprocess.SubprocessError) as error:
                    if isinstance(error, subprocess.SubprocessError):
                        return "github"
                    if transient(error):
                        raise
                role = "import" if route is not None else "route"
                runs = api.repo(f"actions/workflows/{workflows[role]['id']}/runs?event=workflow_dispatch&per_page=100")["workflow_runs"]
                matches = [item for item in runs if item.get("display_title") == f"xcc-{role}-{run['id']}-{evidence_attempt}"]
                if matches and all(item["status"] == "completed" for item in matches):
                    return "github"
            except (ContractError, urllib.error.URLError, TimeoutError) as error:
                if not transient(error):
                    raise
            if time.monotonic() >= deadline:
                return "github"
            time.sleep(min(delay, max(0, deadline - time.monotonic())))
            delay = min(300, delay * 2)
    except (ContractError, KeyError, TypeError, ValueError, OSError, urllib.error.URLError, subprocess.SubprocessError):
        return "github"


def cloud_selection(args):
    ctx = context()
    ctx["run"]["job"] = "ui-cloud-wait"
    records = args.output_dir.resolve()
    require(ROOT != records and ROOT not in records.parents, "UI output must be outside checkout")
    records.mkdir(parents=True, exist_ok=False)
    summary = summary_for(ctx, file_hash(ROOT / MANIFEST_PATH))
    if getattr(args, "scoped_plan_sha256", None):
        summary["hashes"]["manifests"]["ui-scoped-plan"] = args.scoped_plan_sha256
    started = time.monotonic()
    from ci_xcode_cloud_client import RetryingGitHub
    decision = wait_cloud(ctx, RetryingGitHub(ctx["identity"]["repository"], os.environ["GH_TOKEN"], time.monotonic() + 120 * 60,
                                                    wait_out_rate_limits=True))
    output("appletv_routed", str(decision == "routed").lower())
    summary["status"] = "passed"
    summary["population"]["observed"] = [observation(summary["population"]["declared"][0], "passed", time.monotonic() - started)]
    write_summary(summary, records)
    return 0


def run_shard(args):
    from run_fixture_ui_tests import declared_tests, main as fixture_main
    ctx = context()
    workspace_preflight(ROOT)
    platform_name = DEVICES[args.device]
    manifest_raw = git_blob(args.manifest_revision, MANIFEST_PATH) if args.manifest_revision else (ROOT / MANIFEST_PATH).read_bytes()
    manifest = parse_shard_manifest(manifest_raw.decode())
    plan_path = ROOT / ("immichSlides-" + ("iOS" if platform_name == "ios" else "tvOS") + ".xctestplan")
    plan = decode(plan_path.read_text())
    ui_root = ROOT / "immichSlidesUITests"
    population = declared_tests({path.relative_to(ui_root).as_posix(): path.read_text() for path in ui_root.rglob("*.swift")}, platform_name, plan, [])
    selection = decode(args.selection_path.read_text()) if args.selection_path else None
    shard = selected_shard(population, plan, manifest, args.device, args.shard, selection)
    require(shard, "requested UI shard has no declared tests")
    require(not os.environ.get("GITHUB_ACTIONS") or args.manifest_revision is None, "CI cannot override the admitted manifest")
    with tempfile.TemporaryDirectory(prefix="ui-shard-manifest-") as manifest_directory:
        manifest_path = Path(manifest_directory, "manifest.json")
        manifest_path.write_bytes(manifest_raw)
        if args.archive_dir:
            selection = decode(args.selection_path.read_text())
            require(selection["platform"] == platform_name, "UI archive selection platform differs from device")
            require(parse_identity(selection["identity"]) == ctx["identity"], "UI selection differs from the consumer identity")
            manifest_build_path = args.archive_dir / "manifest.json"
            require(file_hash(manifest_build_path) == selection["build_manifest_sha256"], "selected build manifest changed")
            build = decode(manifest_build_path.read_text())
            pins = decode((ROOT / "scripts/ci-pins.json").read_text())
            validate_manifest(build, ctx["identity"], selection["producer_run_id"], selection["producer_attempt"],
                              platform_name, pins["xcode"]["build"], file_hash(ROOT / "scripts/ci-pins.json"))
            require(not os.path.lexists(build["source_path"]) and not os.path.lexists(build["products_path"]),
                    "build-time checkout or Products path remains present")
            require(str((args.relocated_path / "Products").resolve()) != build["products_path"], "UI relocation path is not distinct")
            extract_products(args.archive_dir / "build.tar.gz", args.relocated_path, build)
            products = args.relocated_path / "Products"
            check_products(products)
            apps = list(products.glob("Debug-*simulator/immichSlides.app"))
            require(len(apps) == 1 and measure_signing(apps[0]) == build["signing_mode"], "relocated app signing differs")
            runs = list(products.glob("*.xctestrun"))
            require(len(runs) == 1, "archive needs one default-plan test run")
            xctestrun = runs[0]
        else:
            xctestrun = args.xctestrun
        command = ["--device", args.device, "--destination", args.destination, "--output-dir", str(args.output_dir),
                   "--xctestrun", str(xctestrun), "--shard", args.shard, "--shard-manifest", str(manifest_path),
                   "--timeout-minutes", str(args.timeout_minutes), "--total-timeout-minutes", str(args.total_timeout_minutes),
                   "--result-export-timeout-seconds", str(args.result_export_timeout_seconds),
                   "--wait-factor", str(args.wait_factor),
                   "--min-free-gib", str(args.min_free_gib), "--listed-only-retry", "--failure-screenshots"]
        for entry in shard:
            command += ["--only-testing", "immichSlidesUITests/" + entry["key"]]
        if selection and selection.get("packing"):
            command += ["--scoped-plan-sha256", selection["packing"]["sha256"]]
            if getattr(args, "compiled_from_official_results", False):
                command += ["--compiled-from-official-results"]
        started, started_epoch = time.monotonic(), time.time()
        code = fixture_main(command)
        write_json(args.output_dir / "shard-timing.json", {"schema_version": 1, "device": args.device, "shard": args.shard,
                   "wall_seconds": time.monotonic() - started, "exit_code": code,
                   "started_epoch": started_epoch, "finished_epoch": time.time(),
                   "max_parallel": args.max_parallel, "invocation_timeout_minutes": args.timeout_minutes,
                   "total_timeout_minutes": args.total_timeout_minutes, "result_export_timeout_seconds": args.result_export_timeout_seconds})
        return code


def failed_shard(args, error):
    from run_fixture_ui_tests import fixture_inputs, start_official_discovery, write_fixture_summary
    directory = args.output_dir.resolve()
    if ROOT == directory or ROOT in directory.parents or os.path.lexists(directory):
        return
    try:
        ctx = context()
        require(args.manifest_revision is None, "failed CI shards cannot override the admitted manifest")
        selection_path = getattr(args, "selection_path", None)
        selection = decode(selection_path.read_text()) if selection_path else None
        selectors, plan_hash = [], None
        if selection and selection.get("packing"):
            platform = DEVICES[args.device]
            plan = decode((ROOT / ("immichSlides-" + ("iOS" if platform == "ios" else "tvOS") + ".xctestplan")).read_text())
            from run_fixture_ui_tests import declared_tests
            sources = {path.relative_to(ROOT / "immichSlidesUITests").as_posix(): path.read_text()
                       for path in (ROOT / "immichSlidesUITests").rglob("*.swift")}
            population = declared_tests(sources, platform, plan, [])
            shard = selected_shard(population, plan, decode((ROOT / MANIFEST_PATH).read_text()),
                                   args.device, args.shard, selection)
            require(shard, "failed packed UI shard has no tests")
            selectors = ["immichSlidesUITests/" + entry["key"] for entry in shard]
            plan_hash = selection["packing"]["sha256"]
        inputs = fixture_inputs(ROOT, args.device, selectors, shard=args.shard, shard_manifest=ROOT / MANIFEST_PATH,
                                listed_only_retry=True, scoped_plan_sha256=plan_hash,
                                policy_revision=ctx["identity"]["base_sha"]
                                if getattr(args, "compiled_from_official_results", False) else None)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Unbound evidence must stay absent so it cannot discard other shards.
        return
    directory.mkdir(parents=True, mode=0o700)
    ctx["run"].update(tier="ui", job="ui-" + args.device, shard=args.shard)
    summary = summary_for(ctx, inputs["hashes"]["manifests"]["ui-shards"])
    summary.update(hashes=inputs["hashes"], population=inputs["population"])
    if getattr(args, "compiled_from_official_results", False):
        from strict_e2e_runner_support import destination_udid
        try:
            start_official_discovery(summary, destination_udid(args.destination), inputs["discovery_policy"], enabled=True)
        except ContractError as policy_error:
            error = policy_error
    summary["status"] = "failed"
    summary["infrastructure"] = [{"code": "ui-shard-preflight-failed", "message": str(error)[:200]}]
    write_fixture_summary(summary, directory)


def verify_reproduction_pins(source, destination, environment, device="iphone"):
    from strict_e2e_runner_support import destination_udid
    from setup_ci_python import load_pins
    pins = load_pins(source / "scripts/ci-pins.json")
    # A local installation may have a different bundle path from hosted macOS.
    # Freeze the selected path, then verify its pinned version/build.
    try:
        environment["DEVELOPER_DIR"] = environment.get("DEVELOPER_DIR") or subprocess.check_output(
            ["xcode-select", "-p"], env=environment, text=True, timeout=60).strip()
        observed = subprocess.check_output(["xcodebuild", "-version"], env=environment, text=True, timeout=60).strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise ContractError("reproduction Xcode pin check failed: selected toolchain unavailable") from error
    expected = f"Xcode {pins['xcode']['version']}\nBuild version {pins['xcode']['build']}"
    require(observed == expected, f"reproduction Xcode pin mismatch: expected {expected!r}, observed {observed!r}")
    platform_name = DEVICES[device]
    destination_platform = "iOS Simulator" if platform_name == "ios" else "tvOS Simulator"
    require(destination.startswith("platform=" + destination_platform + ","), "reproduction destination platform differs from device")
    udid = destination_udid(destination)
    inventory = decode(subprocess.check_output(["xcrun", "simctl", "list", "--json"], env=environment, text=True, timeout=60))
    pin = pins["simulators"][platform_name]
    runtimes = [runtime for runtime in inventory["runtimes"] if runtime["identifier"] == pin["runtime"]
                and runtime.get("isAvailable") and runtime["version"] == pin["version"] and runtime["buildversion"] == pin["build"]]
    require(len(runtimes) == 1, "reproduction simulator runtime pin mismatch")
    devices = [(runtime, device) for runtime, devices in inventory["devices"].items() for device in devices if device["udid"] == udid]
    types = [entry["identifier"] for entry in inventory["devicetypes"] if entry["name"] == pins["device_types"][device]]
    require(len(devices) == 1 and devices[0][0] == pin["runtime"] and devices[0][1].get("isAvailable") is True,
            "reproduction destination runtime pin mismatch or unavailable simulator")
    require(len(types) == 1 and devices[0][1].get("deviceTypeIdentifier") == types[0], "reproduction destination device type pin mismatch")
    print("Verified reproduction Xcode, runtime and destination device pins", flush=True)


def reproduction_wait_arguments(source, factor, environment):
    # Legacy revisions have the original fixed budgets and no factor option.
    if factor == 1:
        return []
    help_text = subprocess.check_output([sys.executable, "-B", str(source / "scripts/ci_ui_tests.py"), "run", "--help"],
                                        cwd=source, env=environment, text=True, timeout=30)
    require("--wait-factor" in help_text.split(),
            "selected revision predates configurable test waits; use factor 1 or select a newer revision")
    return ["--wait-factor", str(factor)]


def reproduce(args):
    selection_path = getattr(args, "selection_path", None)
    revision = subprocess.check_output(["git", "rev-parse", "--verify", (args.manifest_revision or "HEAD") + "^{commit}"], cwd=ROOT,
                                       text=True, timeout=60).strip()
    output_root = args.output_dir.resolve()
    require(ROOT != output_root and ROOT not in output_root.parents, "reproduction output must be outside checkout")
    output_root.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="ui-reproduction-", dir=output_root) as directory:
        source = ROOT
        if args.manifest_revision:
            source = Path(directory, "source")
            subprocess.run(["git", "clone", "--quiet", "--no-local", str(ROOT), str(source)], check=True, timeout=120)
            subprocess.run(["git", "checkout", "--quiet", "--detach", revision], cwd=source, check=True, timeout=60)
        workspace_preflight(source)
        manifest = parse_shard_manifest((source / MANIFEST_PATH).read_text())
        if selection_path:
            selection = decode(selection_path.read_text())
            tree = subprocess.check_output(["git", "rev-parse", revision + "^{tree}"], cwd=source,
                                           text=True, timeout=60).strip()
            require(selection.get("identity", {}).get("tree_sha") == tree,
                    "packed UI selection differs from the tested tree")
            from ci_population import ui_identities
            sources = {path.relative_to(source).as_posix(): path.read_text()
                       for path in (source / "immichSlidesUITests").rglob("*.swift")}
            platform = DEVICES[args.device]
            plan = decode((source / ("immichSlides-" + ("iOS" if platform == "ios" else "tvOS") + ".xctestplan")).read_text())
            selected_shard(ui_identities(sources, platform), plan, manifest, args.device, args.shard,
                           selection)
        else:
            require(args.shard in manifest["shards"], "reproduction shard is missing at that revision")
        # The clean checkout contains no private symlink or ambient local inputs.
        from run_fixture_ui_tests import clean_environment
        environment = clean_environment(os.environ)
        wait_arguments = reproduction_wait_arguments(source, args.wait_factor, environment)
        # The selected source is already isolated, including explicit historical reproduction.
        from ci_local import CONTEXT
        environment[CONTEXT] = str(source)
        verify_reproduction_pins(source, args.destination, environment, args.device)
        from strict_e2e_runner_support import wait_for_service, stop_exact_process
        ready = Path(directory, "fixture-preflight.json")
        service = subprocess.Popen([sys.executable, "-B", str(source / "scripts/strict_e2e_server.py"),
                                   "--fixture-set", "c", "--host", "127.0.0.1", "--port", "0",
                                   "--ready-file", str(ready)], env=environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            host, port = wait_for_service(ready, service)
            print(f"Reproduction fixture preflight ready: http://{host}:{port}/api (public set C)", flush=True)
        finally:
            stop_exact_process(service)
        derived = Path(directory, "derived")
        build_records = Path(directory, "build")
        build_command = [sys.executable, "-B", str(source / "scripts/ci_build_archive.py"), "build", "--platform", DEVICES[args.device],
                         "--derived-data-path", str(derived), "--output-dir", str(build_records)]
        print("Reproduction build command: " + shlex.join(build_command), flush=True)
        completed = subprocess.run(build_command, cwd=source, env=environment, check=False)
        if completed.returncode:
            return completed.returncode
        runs = list((derived / "Build/Products").glob("*.xctestrun"))
        require(len(runs) == 1, "reproduction build needs one default plan")
        shard_command = [sys.executable, "-B", str(source / "scripts/ci_ui_tests.py"), "run", "--device", args.device,
                         "--shard", args.shard, "--manifest-revision", revision, "--destination", args.destination,
                         "--xctestrun", str(runs[0]), "--output-dir", str(output_root / "records")] + wait_arguments
        if selection_path:
            shard_command += ["--selection-path", str(selection_path.resolve())]
        print("Reproduction shard command: " + shlex.join(shard_command), flush=True)
        code = subprocess.run(shard_command, cwd=source, env=environment, check=False).returncode
        write_json(output_root / "reproduction.json", {"schema_version": 1, "commit_sha": revision,
                   "tree_sha": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=source, text=True).strip(),
                   "historical_revision": args.manifest_revision, "shard": args.shard, "exit_code": code})
        return code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    selection = commands.add_parser("select")
    selection.add_argument("--output-dir", type=Path, required=True)
    selection.add_argument("--pack-scoped-ui", action="store_true")
    selection.add_argument("--scoped-ui-v2", action="store_true", help="Use base-owned five-slot scoped capacity planning")
    selection.add_argument("--defer-main-ui", action="store_true")
    group_wait = commands.add_parser("wait-group")
    group_wait.add_argument("--group", choices=("ios", "tvos"), required=True)
    group_wait.add_argument("--selection-path", type=Path, required=True)
    group_wait.add_argument("--output-dir", type=Path, required=True)
    group_wait.add_argument("--timeout-minutes", type=float, default=180)
    group_wait.add_argument("--defer-main-ui", action="store_true")
    wait = commands.add_parser("wait-archive")
    wait.add_argument("--output-dir", type=Path, required=True)
    wait.add_argument("--timeout-minutes", type=float, default=120)
    wait.add_argument("--defer-main-ui", action="store_true",
                      help="Main pushes reuse trusted PR UI evidence or defer verification to nightly")
    wait.add_argument("--pack-scoped-ui", action="store_true", help="Use the trusted functional-only packed PR protocol")
    wait.add_argument("--scoped-ui-v2", action="store_true", help="Use base-owned five-slot scoped capacity planning")
    cloud_wait = commands.add_parser("wait-cloud")
    cloud_wait.add_argument("--output-dir", type=Path, required=True)
    cloud_wait.add_argument("--scoped-plan-sha256")
    run = commands.add_parser("run")
    run.add_argument("--device", choices=DEVICES, required=True)
    run.add_argument("--shard", required=True)
    run.add_argument("--destination", required=True)
    run.add_argument("--output-dir", type=Path, required=True)
    run.add_argument("--manifest-revision")
    source = run.add_mutually_exclusive_group(required=True)
    source.add_argument("--archive-dir", type=Path)
    source.add_argument("--xctestrun", type=Path)
    run.add_argument("--selection-path", type=Path)
    run.add_argument("--relocated-path", type=Path)
    run.add_argument("--timeout-minutes", type=float, default=65)
    run.add_argument("--total-timeout-minutes", type=float, default=85)
    run.add_argument("--result-export-timeout-seconds", type=float, default=60)
    run.add_argument("--wait-factor", type=float, default=1)
    run.add_argument("--min-free-gib", type=int, default=80)
    run.add_argument("--max-parallel", type=int, default=2, help="Workflow matrix cap recorded in shard timing")
    run.add_argument("--compiled-from-official-results", action="store_true", help="Use admitted official scoped discovery")
    local = commands.add_parser("reproduce")
    local.add_argument("--device", choices=DEVICES, default="iphone")
    local.add_argument("--manifest-revision", help="Explicit historical commit; default tests the current working-tree snapshot")
    local.add_argument("--shard", required=True)
    local.add_argument("--selection-path", type=Path, help="Retained ui-selection.json for an exact packed PR shard")
    local.add_argument("--destination", required=True)
    local.add_argument("--output-dir", type=Path, required=True)
    local.add_argument("--wait-factor", type=float, default=1)
    simulator = commands.add_parser("simulator")
    simulator.add_argument("--device", choices=DEVICES, required=True)
    simulator.add_argument("--shard", required=True)
    upload = commands.add_parser("check-upload")
    upload.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        require(not getattr(args, "scoped_ui_v2", False) or args.pack_scoped_ui,
                "scoped UI acceleration requires functional packing")
        if args.command in {"run", "reproduce"}:
            wait_configuration(args.wait_factor)
        if hasattr(args, "timeout_minutes"):
            require(math.isfinite(args.timeout_minutes) and args.timeout_minutes > 0, "timeout must be finite and positive")
        if getattr(args, "manifest_revision", None):
            require(not args.manifest_revision.startswith("-") and ":" not in args.manifest_revision, "invalid manifest revision")
        if args.command == "wait-archive":
            return wait_archive(args)
        if args.command in {"select", "wait-group"}:
            import ci_xcode_cloud_ui
            return (ci_xcode_cloud_ui.select if args.command == "select" else ci_xcode_cloud_ui.wait_group)(args)
        if args.command == "wait-cloud":
            return cloud_selection(args)
        if args.command == "simulator":
            require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
                    "automatic simulator creation is hosted-only")
            pins = decode((ROOT / "scripts/ci-pins.json").read_text())
            platform_name = DEVICES[args.device]
            udid = subprocess.check_output(["xcrun", "simctl", "create", "ui-" + args.device + "-" + args.shard,
                    pins["device_types"][args.device], pins["simulators"][platform_name]["runtime"]], text=True, timeout=60).strip()
            destination_platform = "tvOS Simulator" if platform_name == "tvos" else "iOS Simulator"
            with open(os.environ["GITHUB_ENV"], "a") as handle:
                handle.write(f"UI_SIMULATOR={udid}\nUI_DESTINATION=platform={destination_platform},id={udid}\n")
            return 0
        if args.command == "check-upload":
            from run_strict_e2e import write_sensitive_scan
            from strict_e2e_server import PUBLIC_API_KEY
            summary = decode((args.output_dir / "summary.json").read_text())
            try:
                parse_summary(summary)
            except ContractError:
                require(isinstance(summary, dict) and type(summary.get("schema_version")) is int
                        and summary["schema_version"] == 2 and summary.get("status") == "failed"
                        and isinstance(summary.get("infrastructure"), list)
                        and any(isinstance(entry, dict) and entry.get("code") == "discovery-record-invalid"
                                for entry in summary["infrastructure"]), "unmarked invalid discovery diagnostics")
                # Only the proof may be invalid; ordinary metadata must still parse before scanning.
                diagnostic = {key: value for key, value in summary.items() if key != "compiled_evidence"}
                diagnostic["schema_version"] = 1
                parse_summary(diagnostic)
            write_sensitive_scan(args.output_dir, [PUBLIC_API_KEY])
            output("has_screenshots", str(any(path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg", ".ips", ".crash"}
                    for path in (args.output_dir / "failure-screenshots").rglob("*"))).lower())
            return 0
        if args.command == "reproduce":
            return reproduce(args)
        require(args.max_parallel > 0, "matrix cap must be positive")
        require(not args.archive_dir or (args.selection_path and args.relocated_path), "archive shards need selection and relocation paths")
        return run_shard(args)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        if args.command == "run":
            failed_shard(args, error)
        print(f"UI producer refused: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    from ci_local import local_main
    raise SystemExit(local_main(main, __file__))
