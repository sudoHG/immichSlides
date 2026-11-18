#!/usr/bin/env python3
"""Standalone smoke planning and raw first-result aggregation."""

from __future__ import annotations

import argparse
import io
from datetime import datetime
import hashlib
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import tarfile
from pathlib import Path
import zipfile
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

# The trusted entry point is staged outside the checkout before selecting a historical main SHA.
ROOT = Path(os.environ.get("GITHUB_WORKSPACE") or Path(__file__).resolve().parent.parent)
sys.path.insert(0, str(ROOT / "scripts"))
from ci_summary import ContractError, decode, markdown_text, require, sha

WORKFLOW = ".github/workflows/ci-smoke-shadow.yml"
MANIFEST = "scripts/smoke-flows.json"
GROUP_BUDGET_MINUTES = {"iphone-debug": 27, "iphone-release": 27, "ipad-debug": 27,
                        "ipad-release": 27, "tv-debug": 22, "tv-release": 22}
JOB_RESERVE_MINUTES = 3  # Keep upload and cleanup headroom outside the inner deadline.
ARCHIVE_MODE = "smoke-archive-v2"
PRODUCER_BUDGET_MINUTES = 27
SETUP_FAILURE_STEPS = {"job-clock", "preflight", "archive-verify", "simulator", "simulator-ready",
                       "archive-load", "runner-command"}
SETUP_FAILURE_COMMANDS = {"git", "xcrun-sdk", "simctl", "codesign", "readiness", "other"}
# Staged control must validate old tested heads without importing a new runner constant.
PRETEST_TIMEOUT_STEPS = frozenset({
    "simulator-reset:terminate",
    "simulator-reset:boot", "simulator-reset:bootstatus", "simulator-reset:readiness",
    "simulator-reset:uninstall", "simulator-reset:uninstall-retry", "simulator-reset:container",
    "simulator-reset:keychain", "simulator-reset:keychain-retry",
    "simulator-reset:privacy", "simulator-reset:privacy-retry",
    "simulator-reset:autofill-device", "simulator-reset:autofill-disable",
    "simulator-reset:autofill-readback", "simulator-reset:autofill-deadline",
    "fixture-service:a", "fixture-service:b",
})
PRETEST_STEPS = (PRETEST_TIMEOUT_STEPS - {"simulator-reset:autofill-deadline"}) | {
    "pretest-other", "simulator-reset:log", "fixture-artifacts:a", "fixture-artifacts:b",
    "private-result-bundle", "first-failure-spool", "prepare-run",
}
PRETEST_FAILURE_STEPS = PRETEST_STEPS | {step + ":timeout" for step in PRETEST_TIMEOUT_STEPS}
SIMULATOR_RECREATE_STEPS = {"simulator", "simulator-ready"}
# Caps from strict_e2e_build.load_smoke_archive and ci_build_archive.measure_signing:
# git x3, xcrun-sdk x2, simctl-list x3, codesign x1; xcode-select excluded because setup() exports DEVELOPER_DIR.
ARCHIVE_LOAD_OWN_CAP_SECONDS = 3 * 30 + 2 * 60 + 3 * 60 + 120


def smoke_artifact_name(configuration, control):
    require(configuration in {"Debug", "Release"}, "smoke build configuration differs")
    return f"smoke-build-{configuration.lower()}-{control['run_id']}-{control['attempt']}"


def source_at_commit(head):
    """Use the same path/content digest as the working-checkout reader, without checkout."""
    raw = subprocess.check_output(["git", "archive", "--format=tar", head], cwd=ROOT, timeout=60)
    entries = []
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        for member in archive.getmembers():
            if member.isdir() or "__pycache__" in Path(member.name).parts or member.name.endswith(".pyc"):
                continue
            require(member.isfile() or member.issym(), "unsupported tested source entry")
            value = os.fsencode(member.linkname) if member.issym() else hashlib.sha256(archive.extractfile(member).read()).hexdigest().encode()
            entries.append((os.fsencode(member.name), value))
    digest = hashlib.sha256()
    for name, value in sorted(entries):
        digest.update(name + b"\0" + value)
    return {"head_sha": head, "tree_sha": git("rev-parse", head + "^{tree}"),
            "source_sha256": digest.hexdigest(), "clean": True}


def authoritative_control(environment, api):
    run_id = environment["GITHUB_RUN_ID"]
    run = api.repo("actions/runs/" + run_id)
    workflow = api.repo("actions/workflows/ci-smoke-shadow.yml")
    repository = environment["GITHUB_REPOSITORY"]
    require(environment.get("GITHUB_REF") == "refs/heads/main" and environment.get("GITHUB_RUN_ATTEMPT") == "1"
            and environment.get("GITHUB_WORKFLOW_REF") == repository + "/" + WORKFLOW + "@refs/heads/main"
            and str(run.get("id")) == run_id and run.get("run_attempt") == 1
            and run.get("head_sha") == environment.get("GITHUB_SHA") and run.get("head_branch") == "main"
            and run.get("event") == environment.get("GITHUB_EVENT_NAME")
            and run.get("repository", {}).get("full_name") == repository
            and (run.get("head_repository") or {}).get("full_name") == repository
            and run.get("workflow_id") == workflow.get("id") and run.get("path") == workflow.get("path") == WORKFLOW,
            "shadow control API provenance differs")
    sha(run["head_sha"])
    require(subprocess.call(["git", "merge-base", "--is-ancestor", run["head_sha"], "origin/main"],
                            cwd=ROOT, timeout=30) == 0, "shadow API control head is not admitted main")
    stage = Path(environment["RUNNER_TEMP"]) / "smoke-control/stage.json"
    source = decode(stage.read_text())["head_sha"] if stage.is_file() else git("rev-parse", "HEAD")
    require(subprocess.call(["git", "merge-base", "--is-ancestor", source, "origin/main"], cwd=ROOT, timeout=30) == 0,
            "staged control source is not admitted main")
    return {"repository": repository, "run_id": run_id, "attempt": 1, "workflow_id": workflow["id"],
            "workflow_path": WORKFLOW, "api_head_sha": run["head_sha"], "control_source_sha": source,
            "main_admitted": True}


def validate_smoke_artifact(metadata, control, configuration, artifact_id, producer):
    require(type(artifact_id) is int and artifact_id > 0 and metadata.get("id") == artifact_id
            and metadata.get("expired") is False and metadata.get("name") == smoke_artifact_name(configuration, control),
            "smoke archive ID, expiry or configuration differs")
    run = metadata.get("workflow_run", {})
    require(str(run.get("id")) == control["run_id"] and run.get("head_sha") == control["api_head_sha"],
            "smoke archive API control source differs")
    require(producer.get("name") == "smoke-shadow-ios-" + configuration.lower()
            and producer.get("conclusion") == "success" and producer.get("run_attempt") == control["attempt"],
            "smoke archive producer did not succeed in this attempt")


def validate_build_provenance(provenance, plan, configuration):
    require(isinstance(provenance, dict) and set(provenance) == {
        "configuration", "artifact_id", "manifest_sha256", "archive_sha256", "control", "source", "producer_job"},
        "smoke archive build provenance fields differ")
    require(provenance["configuration"] == configuration and provenance["control"] == plan["control"]
            and provenance["source"] == plan["tested_source"]
            and provenance["producer_job"] == "smoke-shadow-ios-" + configuration.lower()
            and type(provenance["artifact_id"]) is int and provenance["artifact_id"] > 0,
            "smoke archive build provenance differs")
    sha(provenance["manifest_sha256"], 64)
    sha(provenance["archive_sha256"], 64)


def verify_smoke_archive(directory, derived, *, expected_identity, control, manifest_hash, archive_hash=None):
    from ci_build_archive import extract_products, file_hash, measure_signing
    from strict_e2e_build import SMOKE_RECEIPT, validate_smoke_receipt
    require(set(path.name for path in directory.iterdir()) == {"manifest.json", "build.tar.gz"}
            and all(path.is_file() and not path.is_symlink() for path in directory.iterdir()),
            "smoke archive must contain only a regular manifest and tar")
    sha(manifest_hash, 64)
    require(file_hash(directory / "manifest.json") == manifest_hash, "smoke manifest hash differs")
    receipt = decode((directory / "manifest.json").read_text())
    validate_smoke_receipt(receipt, expected_identity, control)
    if archive_hash is not None:
        sha(archive_hash, 64)
        require(receipt["archive_sha256"] == archive_hash, "smoke tar hash differs from producer output")
    extract_products(directory / "build.tar.gz", derived / "Build",
                     {"files": receipt["products"], "archive_sha256": receipt["archive_sha256"]},
                     configuration=expected_identity["configuration"])
    products = derived / "Build/Products"
    require(measure_signing(products / f"{expected_identity['configuration']}-iphonesimulator/immichSlides.app") == "adhoc",
            "smoke archive signature differs")
    write_json(derived / SMOKE_RECEIPT, receipt)
    return receipt


def plan_shared(scheduling, environment, api):
    support = git("show", scheduling["head_sha"] + ":scripts/strict_e2e_build.py")
    if any(capability not in support for capability in ("SMOKE_ARCHIVE_VERSION = 2",
            "SMOKE_SOURCE_PLIST_PREFLIGHT_VERSION = 1", "SMOKE_EXPECTED_CONTROL_VERSION = 1")):
        reason = "tested source predates the complete smoke archive v2 producer contract"
        print(reason, flush=True)
        scheduling.update(execute=False, not_run_reason=reason)
        return
    scheduling.update(build_mode=ARCHIVE_MODE, tested_source=source_at_commit(scheduling["head_sha"]),
                      control=authoritative_control(environment, api))


def current_control(scheduling, environment):
    api = GitHub(environment["GITHUB_REPOSITORY"], environment.get("SMOKE_TOKEN"))
    control = authoritative_control(environment, api)
    require(control == scheduling["control"], "shadow control changed since planning")
    return api, control


def producer_job(api, control, configuration):
    jobs = complete_attempt_jobs(api, {"id": int(control["run_id"]), "run_attempt": control["attempt"]})
    matches = [job for job in jobs if job.get("name") == "smoke-shadow-ios-" + configuration.lower()]
    require(len(matches) == 1, "smoke producer job is missing or ambiguous")
    return matches[0]


def step_seconds(job, name):
    # Actions may still report an uploaded/downloaded step as in progress.
    try:
        steps = [step for step in job.get("steps", []) if step.get("name") == name]
        if len(steps) != 1 or steps[0].get("conclusion") != "success":
            return None
        def timestamp(key):
            value = datetime.fromisoformat(steps[0][key].replace("Z", "+00:00"))
            require(value.tzinfo is not None, "smoke transfer clock is invalid")
            return value.timestamp()
        return diagnostic_seconds(timestamp("completed_at") - timestamp("started_at"))
    except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
        return None


def diagnostic_seconds(value):
    return value if type(value) in (int, float) and math.isfinite(value) and value >= 0 else None


def read_transfer_timings(scheduling, producers, records, environment):
    """Read completed jobs only; diagnostics never authorize or invalidate execution."""
    if scheduling.get("build_mode") != ARCHIVE_MODE or not scheduling["execute"]:
        return
    try:
        api = GitHub(environment["GITHUB_REPOSITORY"], environment.get("SMOKE_TOKEN"))
        jobs = complete_attempt_jobs(api, {"id": int(scheduling["shadow"]["id"]), "run_attempt": 1})
        def elapsed(name, step):
            matches = [job for job in jobs if job.get("name") == name]
            return step_seconds(matches[0], step) if len(matches) == 1 else None
        for producer in producers:
            if isinstance(producer, dict) and isinstance(producer.get("timing"), dict):
                producer["timing"]["upload_seconds"] = elapsed("smoke-shadow-ios-" + producer["configuration"].lower(),
                                                                "Publish the immutable configuration archive")
        for record in records:
            if isinstance(record, dict) and record.get("timing_mode") == ARCHIVE_MODE:
                record["transfer_seconds"] = elapsed("smoke-shadow-" + record["group"]["id"],
                                                       "Download the selected configuration archive")
    except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError, subprocess.SubprocessError):
        # Unreadable/partial diagnostics retain the producer/consumer's unknown values.
        return


def run_producer(scheduling, environment, temporary):
    from strict_e2e_runner_support import RunnerGroupCleanupError, run_runner
    from strict_e2e_build import build_smoke_archive, smoke_source_identity
    from ci_build_archive import disk_check, workspace_preflight
    configuration = environment["SMOKE_CONFIGURATION"]
    api, control = current_control(scheduling, environment)
    require(scheduling.get("build_mode") == ARCHIVE_MODE and scheduling["execute"], "smoke producer is not admitted")
    require(smoke_source_identity(ROOT) == scheduling["tested_source"], "smoke producer tested source differs")
    started = job_started_epoch(environment, "ios-" + configuration.lower())
    environment.pop("SMOKE_TOKEN", None)
    os.environ.pop("SMOKE_TOKEN", None)
    workspace_preflight(ROOT)
    disk_check(30)
    root = temporary / "smoke-producer"
    require(not root.exists(), "smoke producer output must be fresh")
    root.mkdir()
    write_json(root / "ownership.json", scheduling["shadow"])
    def execute(command, **options):
        remaining = started + PRODUCER_BUDGET_MINUTES * 60 - time.time()
        require(remaining > 0, "smoke producer inner budget exhausted")
        try:
            return run_runner(command, ROOT, options["log_path"], timeout_seconds=min(1200, remaining),
                              environment=options.get("environment"))
        except RunnerGroupCleanupError:
            (temporary / "smoke-cleanup-blocked").touch()
            raise
    receipt, measurements = build_smoke_archive(root=ROOT, configuration=configuration, control=control,
        derived=root / "derived", packages=root / "packages", output=root / "output", execute=execute)
    require(time.time() <= started + PRODUCER_BUDGET_MINUTES * 60, "smoke producer inner budget exhausted")
    write_json(root / "build.json", {"configuration": configuration, "job_started_epoch": started,
                                     "source": receipt["identity"]["source"], "measurements": measurements})
    output(environment, "manifest_sha256", measurements["manifest_sha256"])
    output(environment, "archive_sha256", measurements["archive_sha256"])
    output(environment, "artifact_name", smoke_artifact_name(configuration, control))
    output(environment, "archive_safe", "true")
    return 0


def finish_producer(scheduling, environment, temporary):
    configuration = environment["SMOKE_CONFIGURATION"]
    record = {"schema_version": 1, "configuration": configuration, "outcome": "failed", "provenance": None,
              "timing": None, "control": scheduling["control"], "source": scheduling["tested_source"]}
    try:
        api, control = current_control(scheduling, environment)
        build = decode((temporary / "smoke-producer/build.json").read_text())
        require(build["configuration"] == configuration and build["source"] == scheduling["tested_source"],
                "smoke producer build record differs")
        artifact_id = int(environment["SMOKE_ARTIFACT_ID"])
        metadata = api.repo("actions/artifacts/" + str(artifact_id))
        job = producer_job(api, control, configuration)
        # The build record and immutable upload ID exist; consumers require overall job success later.
        validate_smoke_artifact(metadata, control, configuration, artifact_id,
                                dict(job, conclusion="success"))
        measured = build["measurements"]
        provenance = {"configuration": configuration, "artifact_id": artifact_id,
                      "manifest_sha256": measured["manifest_sha256"], "archive_sha256": measured["archive_sha256"],
                      "control": control, "source": build["source"], "producer_job": job["name"]}
        validate_build_provenance(provenance, scheduling, configuration)
        job_started = diagnostic_seconds(build.get("job_started_epoch"))
        record.update(outcome="passed", provenance=provenance,
                      timing={"build_seconds": diagnostic_seconds(measured.get("build_seconds")),
                              "pack_seconds": diagnostic_seconds(measured.get("pack_seconds")),
                              "upload_seconds": None, "job_elapsed_seconds": max(0, time.time() - job_started)
                              if job_started is not None else None})
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        pass
    directory = temporary / "smoke-producer-records"
    write_json(directory / "producer.json", record)
    scan_records(directory)
    output(environment, "records_safe", "true")
    return int(record["outcome"] != "passed")


def select_archive(scheduling, environment, temporary):
    from strict_e2e_build import smoke_build_identity
    configuration = next(group for group in scheduling["groups"] if group["id"] == environment["SMOKE_GROUP"])["configuration"]
    api, control = current_control(scheduling, environment)
    require(scheduling.get("build_mode") == ARCHIVE_MODE and scheduling["execute"], "smoke archive selection is not admitted")
    prefix = "SMOKE_" + configuration.upper()
    artifact_id = int(environment[prefix + "_ARTIFACT_ID"])
    metadata = api.repo("actions/artifacts/" + str(artifact_id))
    validate_smoke_artifact(metadata, control, configuration, artifact_id, producer_job(api, control, configuration))
    identity = smoke_build_identity(ROOT, configuration)
    require(identity["source"] == scheduling["tested_source"], "smoke consumer tested source differs")
    selection = {"configuration": configuration, "artifact_id": artifact_id,
                 "manifest_sha256": environment[prefix + "_MANIFEST_SHA256"],
                 "archive_sha256": environment[prefix + "_ARCHIVE_SHA256"], "control": control,
                 "source": scheduling["tested_source"], "producer_job": "smoke-shadow-ios-" + configuration.lower()}
    validate_build_provenance(selection, scheduling, configuration)
    write_json(temporary / "smoke-archive-selection.json", {"provenance": selection, "identity": identity,
                                                           "transfer_started_epoch": time.time()})
    output(environment, "artifact_id", str(artifact_id))
    return 0


def shadow_context(environment):
    return {"id": environment.get("GITHUB_RUN_ID"),
            "attempt": int(environment.get("GITHUB_RUN_ATTEMPT", "1")),
            "event": environment.get("GITHUB_EVENT_NAME")}


def admit(environment):
    require(environment.get("GITHUB_REF") == "refs/heads/main"
            and environment.get("GITHUB_EVENT_NAME") in {"schedule", "workflow_dispatch"},
            "smoke is main-only with scheduled/manual triggers")
    require(shadow_context(environment)["attempt"] == 1, "smoke shadow records only the first attempt; dispatch a new run")
    sha(environment.get("GITHUB_SHA"))
    return environment["GITHUB_SHA"]


def manifest_groups(manifest):
    groups = sorted({(flow["platform"], flow["device"], flow["configuration"]) for flow in manifest["flows"]})
    return [{"id": device + "-" + configuration.lower(), "platform": platform, "device": device,
             "configuration": configuration,
             "timeout_minutes": GROUP_BUDGET_MINUTES[device + "-" + configuration.lower()] + JOB_RESERVE_MINUTES}
            for platform, device, configuration in groups]


def make_plan(environment, manifest, manifest_hash):
    from strict_e2e_smoke import select_scope
    scope = environment.get("SMOKE_SCOPE") or ("full" if environment["GITHUB_EVENT_NAME"] == "workflow_dispatch" else "core")
    selected = select_scope(manifest["flows"], scope)
    return {"schema_version": 1, "repository": environment["GITHUB_REPOSITORY"], "head_sha": environment["GITHUB_SHA"],
            "shadow": shadow_context(environment), "started_epoch": time.time(),
            "manifest_sha256": manifest_hash, "scope": scope, "flows": selected,
            "groups": manifest_groups({"flows": selected}), "execute": True, "not_run_reason": None}


def group_flows(plan, group_id):
    groups = [group for group in plan["groups"] if group["id"] == group_id]
    require(len(groups) == 1, "unknown smoke group")
    group = groups[0]
    return [flow for flow in plan["flows"]
            if all(flow[key] == group[key] for key in ("platform", "device", "configuration"))]


def validate_plan(plan, environment, *, checkout_sha=None, manifest_hash=None, manifest=None):
    require(plan.get("schema_version") == 1 and plan.get("repository") == environment.get("GITHUB_REPOSITORY")
            and plan.get("shadow") == shadow_context(environment), "shadow plan context differs")
    sha(plan["head_sha"])
    if checkout_sha is not None:
        require(checkout_sha == plan["head_sha"], "tested checkout differs from run head SHA")
    if manifest_hash is not None:
        require(manifest_hash == plan["manifest_sha256"], "manifest binding differs from the planned run SHA")
    if manifest is not None:
        selected = make_plan(dict(environment, SMOKE_SCOPE=plan["scope"]), manifest, plan["manifest_sha256"])
        require(plan["flows"] == selected["flows"] and plan["groups"] == selected["groups"],
                "manifest population differs from the planned run SHA")


def valid_setup_failure(record):
    step = record.get("setup_failure_step")
    valid_step = (step is None or isinstance(step, str) and step in SETUP_FAILURE_STEPS
            and type(record.get("runner_exit_code")) is int and record["runner_exit_code"] != 0
            and not any(row.get("executed") is True for row in record.get("flows", [])))
    if not valid_step:
        return False
    if "setup_failure_command" not in record:
        return True
    command, errors = record["setup_failure_command"], record.get("errors")
    setup_timeout = (step is not None and record.get("runner_exit_code") == 124
                     and isinstance(errors, list) and "setup-step-timeout" in errors)
    return (isinstance(command, str) and command in SETUP_FAILURE_COMMANDS if setup_timeout else command is None)


def valid_pretest_failure(row):
    step = row.get("pretest_failure_step")
    return (step is None or isinstance(step, str) and step in PRETEST_FAILURE_STEPS
            and row.get("outcome") in {"FAIL", "failed"} and row.get("official_execution_complete") is False
            and row.get("elapsed_seconds") == 0 and row.get("failure_kind") in {"infrastructure", "cleanup"}
            and type(row.get("exit_code")) is int and row["exit_code"] != 0)


def timeout_command(argv):
    if isinstance(argv, (list, tuple)):
        for prefix, command in ((["git"], "git"), (["xcrun", "--sdk"], "xcrun-sdk"),
                                (["xcrun", "simctl"], "simctl"), (["codesign"], "codesign")):
            if list(argv[:len(prefix)]) == prefix:
                return command
    return "other"


def valid_simulator_recreate(value):
    return (value is None or isinstance(value, dict) and set(value) == {"step", "command"}
            and isinstance(value["step"], str) and value["step"] in SIMULATOR_RECREATE_STEPS
            and isinstance(value["command"], str) and value["command"] in SETUP_FAILURE_COMMANDS)


def setup_failure_command(error, step):
    from strict_e2e_runner_support import InfrastructureTimeout
    if isinstance(error, InfrastructureTimeout):
        return "readiness"
    if isinstance(error, subprocess.SubprocessError):
        return timeout_command(getattr(error, "cmd", None))
    # The create/boot helper converts its simctl failures to ContractError.
    return "simctl" if step == "simulator" else "other"


def can_recreate_simulator(group_id, archive, started, *, retiring=True):
    from ci_simulator import SIMULATOR_SETUP_COMMAND_TIMEOUT_SECONDS
    from strict_e2e_runner_support import SIMULATOR_COMMAND_TIMEOUT_SECONDS, SIMULATOR_PREPARATION_TIMEOUT_SECONDS
    remaining = started + GROUP_BUDGET_MINUTES[group_id] * 60 - time.time()
    setup = 2 * SIMULATOR_SETUP_COMMAND_TIMEOUT_SECONDS
    setup += SIMULATOR_PREPARATION_TIMEOUT_SECONDS if archive else 0
    retirement = 2 * SIMULATOR_COMMAND_TIMEOUT_SECONDS if retiring else 0
    # Warm-up and flows receive the remaining inner budget through run_runner.
    return remaining >= retirement + setup


def create_group_simulator(group, environment):
    from ci_simulator import create_and_boot_simulator
    environment.pop("UI_SIMULATOR", None)
    publication = Path(environment["GITHUB_ENV"]) if environment.get("GITHUB_ENV") else None
    offset = publication.stat().st_size if publication and publication.exists() else 0
    udid = None
    try:
        udid = create_and_boot_simulator("appletv" if group["device"] == "tv" else group["device"], "smoke-" + group["id"])
        return udid
    finally:
        # Boot can fail after the helper publishes ownership but before returning the UDID.
        if publication and publication.exists():
            with publication.open() as handle:
                handle.seek(offset)
                for line in handle:
                    key, separator, value = line.rstrip("\n").partition("=")
                    if separator and key in {"UI_SIMULATOR", "UI_DESTINATION", "UI_PLATFORM"}:
                        environment[key] = value
        if udid:
            environment["UI_SIMULATOR"] = udid


def retire_group_simulator(udid):
    from strict_e2e_runner_support import simulator_command, SIMULATOR_COMMAND_TIMEOUT_SECONDS
    for action in ("shutdown", "delete"):
        completed = simulator_command(["xcrun", "simctl", action, udid], "simulator-retire",
                                      timeout_seconds=SIMULATOR_COMMAND_TIMEOUT_SECONDS)
        if completed.returncode != 0 and (action != "shutdown" or
                "current state: shutdown" not in completed.stderr.lower()):
            return False
    return True


def clear_retired_simulator(environment):
    # Empty exports keep always-run cleanup correct if the next create never publishes a device.
    keys = ("UI_SIMULATOR", "UI_DESTINATION", "UI_PLATFORM")
    if environment.get("GITHUB_ENV"):
        with open(environment["GITHUB_ENV"], "a") as handle:
            handle.write("".join(key + "=\n" for key in keys))
    for key in keys:
        environment.pop(key, None)


def aggregate(plan, records, matrix_result, *, producers=None, producer_results=None):
    from ci_bounded_diagnostics import public_failure_locations
    from ci_failure_diagnostics import validate_first_failure
    errors, observed, seen = [], {}, set()
    validations = {}
    timings = {}
    builds, admitted_builds = {}, {}
    if plan.get("build_mode") == ARCHIVE_MODE and plan["execute"]:
        for configuration in sorted({group["configuration"] for group in plan["groups"] if group["platform"] == "ios"}):
            candidates = [record for record in producers or [] if record.get("configuration") == configuration]
            try:
                require(len(candidates) == 1, "missing or duplicate producer")
                producer = candidates[0]
                builds[configuration] = producer
                require(producer.get("schema_version") == 1 and producer.get("outcome") == "passed"
                        and (producer_results or {}).get(configuration) == "success", "producer did not succeed")
                validate_build_provenance(producer.get("provenance"), plan, configuration)
                timing = producer.get("timing")
                timing = timing if isinstance(timing, dict) else {}
                builds[configuration] = dict(producer, timing={key: diagnostic_seconds(timing.get(key)) for key in
                    ("build_seconds", "pack_seconds", "upload_seconds", "job_elapsed_seconds")})
                admitted_builds[configuration] = producer["provenance"]
            except (ValueError, TypeError, KeyError):
                errors.append("missing or failed smoke producer: " + configuration)
    groups = {group["id"]: group for group in plan["groups"]}
    if plan["execute"]:
        for record in records:
            if not isinstance(record, dict) or not isinstance(record.get("group"), dict):
                errors.append("invalid group record")
                continue
            group = record.get("group", {})
            group_id = group.get("id")
            if group_id not in groups or group != groups[group_id]:
                errors.append("unknown group")
                continue
            if group_id in seen:
                errors.append("duplicate group: " + group_id)
                continue
            seen.add(group_id)
            archive_mode = plan.get("build_mode") == ARCHIVE_MODE and group["platform"] == "ios"
            archive_admitted = (not archive_mode or group["configuration"] in admitted_builds
                                and record.get("build_provenance") == admitted_builds[group["configuration"]])
            if not archive_admitted:
                errors.append("archive admission failed: " + group_id)
            if (record.get("schema_version") != (2 if archive_mode else 1) or record.get("shadow") != plan["shadow"]
                    or record.get("head_sha") != plan["head_sha"]
                    or record.get("manifest_sha256") != plan["manifest_sha256"]):
                errors.append("group provenance differs: " + group_id)
                continue
            if record.get("selection") != "group":
                errors.append("group selection is not complete: " + group_id)
            expected = group_flows(plan, group_id)
            rows = record.get("flows", [])
            if (not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows) or len(rows) != len(expected)
                    or [(row.get("id"), row.get("selector")) for row in rows] != [
                        (flow["id"], flow["selector"]) for flow in expected]):
                errors.append("flow population differs: " + group_id)
                continue
            for row in rows:
                outcome, elapsed = row.get("outcome"), row.get("elapsed_seconds")
                if outcome not in {"passed", "failed", "crashed", "timed-out", "not-run", "skipped"}:
                    errors.append("invalid raw outcome: " + row["id"])
                    continue
                if not (elapsed is None and outcome == "not-run") and not (
                        type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0):
                    errors.append("invalid flow duration: " + row["id"])
                    continue
                if type(row.get("executed")) is not bool or outcome == "passed" and row["executed"] is not True:
                    errors.append("passing flow was not executed: " + row["id"])
                    continue
                if row.get("official_execution_complete") is not row["executed"]:
                    errors.append("official execution completeness differs: " + row["id"])
                    continue
                if outcome in {"not-run", "skipped"} and row["executed"]:
                    errors.append("non-executed outcome claims execution: " + row["id"])
                    continue
                if (row.get("failure_category") not in {None, "infra", "xctest-tool", "assertion", "unknown"}
                        or row.get("first_failure_message") is not None and not isinstance(row["first_failure_message"], str)):
                    errors.append("invalid public failure: " + row["id"])
                    continue
                if row.get("failure_locations") is not None and public_failure_locations(row["failure_locations"]) is None:
                    errors.append("invalid public failure locations: " + row["id"])
                    continue
                if not valid_pretest_failure(row):
                    errors.append("invalid pretest failure step: " + row["id"])
                    continue
                if "first_failure" in row:
                    try:
                        validate_first_failure(row["first_failure"])
                    except (ContractError, ValueError, TypeError, KeyError, OverflowError):
                        # Optional diagnostics from older tested heads cannot invalidate first results.
                        row = {key: value for key, value in row.items() if key != "first_failure"}
                if archive_admitted:
                    observed[row["id"]] = row
            record_errors = record.get("errors")
            setup_valid = valid_setup_failure(record)
            if not setup_valid:
                errors.append("invalid group setup failure: " + group_id)
            if not isinstance(record_errors, list) or any(not isinstance(error, str) for error in record_errors):
                errors.append("invalid group errors: " + group_id)
            else:
                errors.extend(group_id + ": " + error for error in record_errors)
            validation = record.get("group_validation")
            if (not isinstance(validation, dict) or validation.get("outcome") not in {"passed", "failed"}
                    or not isinstance(validation.get("reason"), (str, type(None)))):
                errors.append("invalid group validation: " + group_id)
            elif validation["outcome"] != "passed" and all(row.get("outcome") == "passed" for row in rows):
                errors.append("runner group validation rejected passing rows: " + group_id)
            if isinstance(validation, dict) and validation.get("outcome") in {"passed", "failed"}:
                validations[group_id] = validation
            clock = [record.get(key) for key in ("job_started_epoch", "job_elapsed_seconds")]
            phases = record.get("phases")
            valid_timing = (all(type(value) in (int, float) and math.isfinite(value) and value >= 0 for value in clock)
                and isinstance(phases, list) and len(phases) <= 2
                and all(isinstance(phase, dict) and set(phase) == {"name", "elapsed_seconds", "exit_code"}
                        and type(phase["elapsed_seconds"]) in (int, float) and math.isfinite(phase["elapsed_seconds"])
                        and phase["elapsed_seconds"] >= 0 and type(phase["exit_code"]) is int for phase in phases)
                and [phase["name"] for phase in phases] == ["archive-verify" if archive_mode else "warm-up", "flows"][:len(phases)]
                and (not all(row.get("executed") is True for row in rows) or len(phases) == 2))
            if archive_mode:
                valid_timing &= (record.get("timing_mode") == ARCHIVE_MODE
                    and isinstance(phases, list) and len(phases) <= 2
                    and all(isinstance(phase, dict) and set(phase) == {"name", "elapsed_seconds", "exit_code"}
                            and type(phase["exit_code"]) is int for phase in phases)
                    and [phase["name"] for phase in phases] == ["archive-verify", "flows"][:len(phases)]
                    and (not all(row.get("executed") is True for row in rows) or len(phases) == 2))
            if not valid_timing:
                errors.append("invalid group job timing: " + group_id)
            timings[group_id] = ({key: record.get(key) for key in ("job_started_epoch", "job_elapsed_seconds", "phases")}
                                 if valid_timing else {"job_started_epoch": None, "job_elapsed_seconds": None, "phases": []})
            for key in ("setup_failure_step", "setup_failure_command"):
                if setup_valid and key in record:
                    timings[group_id][key] = record[key]
            recreate = record.get("simulator_recreate")
            if valid_simulator_recreate(recreate):
                timings[group_id]["simulator_recreate"] = recreate
            else:
                errors.append("invalid simulator recreate: " + group_id)
            if archive_mode and valid_timing:
                timings[group_id].update({key: record.get(key) for key in ("timing_mode", "build_provenance")})
                timings[group_id].update({key: diagnostic_seconds(record.get(key)) for key in
                                          ("job_started_epoch", "job_elapsed_seconds", "transfer_seconds", "verify_seconds")})
                timings[group_id]["phases"] = [dict(phase, elapsed_seconds=diagnostic_seconds(phase.get("elapsed_seconds")))
                                                for phase in phases]
            code = record.get("runner_exit_code")
            if type(code) is not int or code != 0 and all(row.get("outcome") == "passed" for row in rows):
                errors.append("runner failed without a failing flow: " + group_id)
        for group_id in groups.keys() - seen:
            errors.append("missing group: " + group_id)
        if matrix_result != "success" and not any(row["outcome"] in {"failed", "crashed", "timed-out"}
                                                   for row in observed.values()):
            errors.append("matrix jobs did not succeed")
    elif records or matrix_result not in {"skipped", "success"}:
        errors.append("unexpected execution on skipped smoke")
    flows = []
    for flow in plan["flows"]:
        row = observed.get(flow["id"], {"id": flow["id"], "selector": flow["selector"], "outcome": "not-run",
                                       "elapsed_seconds": None, "executed": False, "official_execution_complete": False,
                                       "failure_category": "infra",
                                       "first_failure_message": "No first-result evidence." if plan["execute"]
                                       else plan["not_run_reason"]})
        flows.append(dict(row, device=flow["device"], configuration=flow["configuration"]))
    executed = plan["execute"] and all(row["executed"] and row["outcome"] in {"passed", "failed", "crashed", "timed-out"}
                                       for row in flows)
    outcome = ("not-run" if not plan["execute"] and not errors else "passed" if not errors
               and all(row["outcome"] == "passed" for row in flows) else "failed")
    return {"schema_version": 1, "repository": plan["repository"], "head_sha": plan["head_sha"],
            "manifest_sha256": plan["manifest_sha256"], "shadow": plan["shadow"], "scope": plan["scope"],
            "not_run_reason": plan["not_run_reason"],
            "outcome": outcome, "executed": executed,
            "wall_seconds": max(0, time.time() - plan["started_epoch"]),
            "matrix_job_result": matrix_result, "errors": errors, "group_validation": validations,
            "group_timings": timings, "flows": flows,
            **({"build_mode": ARCHIVE_MODE, "build_producers": builds,
                "shared_build_runner_seconds": (sum(builds[configuration]["timing"]["job_elapsed_seconds"]
                                                    for configuration in admitted_builds)
                    if all(builds[configuration]["timing"]["job_elapsed_seconds"] is not None
                           for configuration in admitted_builds) else None)}
               if plan.get("build_mode") == ARCHIVE_MODE else {})}


def markdown(record):
    from ci_failure_diagnostics import render_first_failure
    if record["outcome"] == "not-run":
        return "Smoke skipped: " + markdown_text(record["not_run_reason"]) + "\n"
    lines = ["## Smoke: " + record["outcome"].upper(), "",
             f"Source `{record['head_sha']}`; scope `{record['scope']}`; executed: {record['executed']}. "
             "Informational only; results never block merges; first results, no retries or yellow.", "",
             "| Flow | Device | Configuration | Outcome | Elapsed (s) | Failure class | Pre-test failure step | First public failure | First failure context |",
             "|---|---|---|---|---:|---|---|---|---|"]
    if record.get("not_run_reason"):
        lines[6:6] = ["Not run: " + markdown_text(record["not_run_reason"]), ""]
    for row in record["flows"]:
        values = [row["id"], row["device"], row["configuration"], row["outcome"], row["elapsed_seconds"],
                  row.get("failure_category"),
                  (row["pretest_failure_step"] or "none") if "pretest_failure_step" in row else "unknown",
                  row.get("first_failure_message"),
                  render_first_failure(row["first_failure"]) if "first_failure" in row else None]
        lines.append("| " + " | ".join(markdown_text(value) if value is not None else "unknown" for value in values) + " |")
    if record["group_timings"]:
        lines += ["", "| Group | Warm-up/build (s) | Transfer (s) | Archive verify (s) | Job elapsed (s) | Simulator re-create | Failed setup step | Timed-out setup command |", "|---|---:|---:|---:|---:|---|---|---|"]
        for group_id, timing in record["group_timings"].items():
            warm = next((phase["elapsed_seconds"] for phase in timing.get("phases") or [] if phase["name"] == "warm-up"), None)
            setup = [("none" if timing[key] is None else timing[key]) if key in timing else "unknown"
                     for key in ("setup_failure_step", "setup_failure_command")]
            recreate = timing.get("simulator_recreate")
            recreate = (recreate["step"] + "/" + recreate["command"] if recreate else "none") if valid_simulator_recreate(recreate) else "unknown"
            lines.append("| " + " | ".join(markdown_text(value) if value is not None else "unknown"
                         for value in (group_id, warm, timing.get("transfer_seconds"), timing.get("verify_seconds"), timing["job_elapsed_seconds"],
                                       recreate, *setup)) + " |")
    if "build_producers" in record:
        lines += ["", "| Producer | Build (s) | Pack (s) | Upload (s) | Artifact ID | Manifest SHA-256 | Tar SHA-256 |",
                  "|---|---:|---:|---:|---|---|---|"]
        for configuration, producer in record["build_producers"].items():
            timing, provenance = producer.get("timing") or {}, producer.get("provenance") or {}
            lines.append("| " + " | ".join(markdown_text(value) if value is not None else "unknown" for value in (
                configuration, timing.get("build_seconds"), timing.get("pack_seconds"), timing.get("upload_seconds"),
                provenance.get("artifact_id"), provenance.get("manifest_sha256"), provenance.get("archive_sha256"))) + " |")
        lines += ["", f"Shared build runner seconds (counted once): {record['shared_build_runner_seconds'] if record['shared_build_runner_seconds'] is not None else 'unknown'}. ",
                  "Capacity: 100-minute envelope (5 + 30 + 60 + 5), 230 runner minutes; observed-workload estimate saves about 21–35 runner minutes, NOT_VERIFIED on this graph."]
    if record["errors"]:
        lines += ["", "Errors: " + "; ".join(markdown_text(error) for error in record["errors"])]
    return "\n".join(lines) + "\n"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True, timeout=30).strip()


def manifest_at_head(head):
    from strict_e2e_smoke import validate_manifest
    raw = subprocess.check_output(["git", "show", head + ":" + MANIFEST], cwd=ROOT, timeout=30)
    manifest = decode(raw.decode("utf-8"))
    validate_manifest(manifest)
    return manifest, hashlib.sha256(raw).hexdigest()


def write_json(path, record):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")


def output(environment, key, value):
    if environment.get("GITHUB_OUTPUT"):
        with open(environment["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(key + "=" + value + "\n")


def scan_records(directory):
    from run_strict_e2e import write_sensitive_scan, WRONG_PUBLIC_API_KEY
    from strict_e2e_server import PUBLIC_API_KEY
    write_sensitive_scan(directory, [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY])


def copy_first_failure_images(evidence, records, rows):
    """Copy only the recorder's validated single-method image, never arbitrary attachments."""
    from ci_failure_diagnostics import validate_first_failure, validate_first_failure_image
    for index, row in enumerate(rows):
        receipt = row.get("first_failure")
        if receipt is None or receipt["screenshot"]["status"] != "captured":
            continue
        source = evidence / row["id"] / "first-failure/0.png"
        target = records / "failure-screenshots/first-failure-attempt-1" / f"{index}.png"
        try:
            validate_first_failure(receipt)
            require(all(folder.is_dir() and not folder.is_symlink() for folder in
                        (evidence, source.parent.parent, source.parent)), "invalid first failure source directory")
            validate_first_failure_image(source, receipt)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        except (OSError, ValueError):
            target.unlink(missing_ok=True)
            if target.parent.is_dir() and not any(target.parent.iterdir()):
                target.parent.rmdir()
            # Optional image loss does not replace the official first result or its safe timing facts.
            receipt["screenshot"] = {"status": "unavailable", "width": None, "height": None, "bytes": None}


def check_group_upload(directory, record):
    from ci_failure_diagnostics import validate_first_failure, validate_ui_first_failure_images
    require(valid_setup_failure(record), "invalid group setup failure")
    require(all(valid_pretest_failure(row) for row in record["flows"]), "invalid pretest failure step")
    require(valid_simulator_recreate(record.get("simulator_recreate")), "invalid simulator recreate")
    declared = [{"key": row["selector"]} for row in record["flows"]]
    observed = []
    for identity, row in zip(declared, record["flows"]):
        if "first_failure" in row:
            validate_first_failure(row["first_failure"])
            observed.append({"identity": identity, "attempts": [{"number": 1, "first_failure": row["first_failure"]}]})
    scan_records(directory)
    validate_ui_first_failure_images(directory / "failure-screenshots",
                                     {"population": {"declared": declared, "observed": observed}})


def setup(environment):
    from ci_build_archive import workspace_preflight
    workspace_preflight(ROOT)
    directory = Path(environment["RUNNER_TEMP"]) / "smoke-python"
    if sys.platform == "darwin":
        pins = decode((ROOT / "scripts/ci-pins.json").read_text())
        developer = pins["xcode"]["developer_dir"]
        environment["DEVELOPER_DIR"] = developer
        with open(environment["GITHUB_ENV"], "a", encoding="utf-8") as handle:
            handle.write("DEVELOPER_DIR=" + developer + "\n")
        command = ["setup_ci_python.py", "--python", "/usr/bin/python3", "--verify-toolchain"]
    else:
        command = ["setup_ci_publisher_python.py", "--host-checks"]
    return subprocess.call([sys.executable, "-B", "scripts/" + command[0], *command[1:], "--venv", str(directory)],
                           cwd=ROOT, env=environment)


def already_tested(api, scheduling):
    """Require actual first results and completed groups before suppressing a schedule."""
    repository, head = scheduling["repository"], scheduling["head_sha"]
    expected = {flow["id"] for flow in scheduling["flows"]}
    groups = {"smoke-shadow-" + group["id"] for group in scheduling["groups"]}
    try:
        for run in api.pages("actions/workflows/ci-smoke-shadow.yml/runs", "workflow_runs",
                             branch="main", status="completed", head_sha=head):
            if (type(run.get("id")) is not int or not 0 < run["id"] < int(scheduling["shadow"]["id"])
                    or run.get("head_sha") != head
                    or run.get("path") != WORKFLOW or run.get("head_branch") != "main"
                    or run.get("repository", {}).get("full_name") != repository
                    or (run.get("head_repository") or {}).get("full_name") != repository
                    or run.get("status") != "completed" or run.get("conclusion") not in {"success", "failure"}
                    or run.get("event") not in {"schedule", "workflow_dispatch"}):
                continue
            name = f"smoke-shadow-{run['id']}-{run['run_attempt']}"
            artifacts = [item for item in api.pages(f"actions/runs/{run['id']}/artifacts", "artifacts")
                         if item.get("name") == name and item.get("expired") is False]
            if len(artifacts) != 1:
                continue
            record = json_member(api, artifacts[0], "shadow.json")
            if (record.get("repository") != repository or record.get("head_sha") != head
                    or record.get("shadow") != {"id": str(run["id"]), "attempt": run["run_attempt"], "event": run["event"]}
                    or record.get("executed") is not True or record.get("outcome") not in {"passed", "failed"}):
                continue
            executed = {row["id"] for row in record["flows"] if row.get("executed") is True
                        and row.get("official_execution_complete") is True
                        and row.get("outcome") in {"passed", "failed", "crashed", "timed-out"}}
            jobs = complete_attempt_jobs(api, run)
            completed = {job["name"] for job in jobs if job.get("status") == "completed"
                         and job.get("conclusion") in {"success", "failure"}}
            if expected <= executed and groups <= completed:
                return {"id": str(run["id"]), "attempt": run["run_attempt"], "outcome": record["outcome"]}
    except Exception:
        # Any exception while reading history means not tested; execute this run.
        return None
    return None


def plan_run(environment, directory, *, shared=False):
    head = admit(environment)
    api = GitHub(environment["GITHUB_REPOSITORY"], environment.get("SMOKE_TOKEN"))
    require(subprocess.call(["git", "merge-base", "--is-ancestor", head, "origin/main"], cwd=ROOT, timeout=30) == 0,
            "run source is not an ancestor of main")
    manifest, manifest_hash = manifest_at_head(head)
    scheduling = make_plan(environment, manifest, manifest_hash)
    if environment["GITHUB_EVENT_NAME"] == "schedule":
        tested = already_tested(api, scheduling)
        if tested:
            url = f"https://github.com/{scheduling['repository']}/actions/runs/{tested['id']}/attempts/{tested['attempt']}"
            scheduling.update(execute=False, not_run_reason=(
                f"Main head already tested by [run {tested['id']}, attempt {tested['attempt']}]({url}) "
                f"({tested['outcome'].upper()}); all groups skipped."))
    if shared and scheduling["execute"]:
        plan_shared(scheduling, environment, api)
    if shared:
        scheduling["control_source_sha"] = git("rev-parse", "HEAD")
        require(scheduling["control_source_sha"] == head, "planned control differs from run head")
    write_json(directory / "plan.json", scheduling)
    scan_records(directory)
    output(environment, "head_sha", head)
    if shared:
        output(environment, "control_sha", scheduling["control_source_sha"])
    output(environment, "execute", str(scheduling["execute"]).lower())
    for configuration in ("Debug", "Release"):
        selected = scheduling["execute"] and any(group["platform"] == "ios" and group["configuration"] == configuration
                                                for group in scheduling["groups"])
        output(environment, "ios_" + configuration.lower(), str(selected).lower())
    output(environment, "matrix", json.dumps({"include": scheduling["groups"]}, separators=(",", ":")))
    output(environment, "records_safe", "true")
    return 0


def job_started_epoch(environment, group_id):
    run_id, attempt = environment.get("GITHUB_RUN_ID", ""), environment.get("GITHUB_RUN_ATTEMPT", "")
    require(run_id.isdecimal() and int(run_id) > 0 and attempt == "1", "shadow job clock context differs")
    api = GitHub(environment["GITHUB_REPOSITORY"], environment.get("SMOKE_TOKEN"))
    jobs = complete_attempt_jobs(api, {"id": int(run_id), "run_attempt": int(attempt)})
    matches = [job for job in jobs if job.get("name") == "smoke-shadow-" + group_id]
    require(len(matches) == 1 and isinstance(matches[0].get("started_at"), str), "shadow job start is unavailable")
    try:
        started = datetime.fromisoformat(matches[0]["started_at"].replace("Z", "+00:00"))
    except ValueError as error:
        raise ContractError("shadow job start timestamp differs") from error
    require(started.tzinfo is not None and 0 <= started.timestamp() <= time.time(), "shadow job start timestamp differs")
    return started.timestamp()


def runner_command(group, destination, root, evidence, *, warm, archive=False, scope="full"):
    return [sys.executable, "-B", str(ROOT / "scripts/run_strict_e2e.py"), "--suite", "smoke-flow",
            "--platform", group["platform"], "--smoke-device", group["device"],
            "--smoke-scope", scope,
            "--configuration", group["configuration"], "--destination", destination,
            "--derived-data-path", str(root / "derived"), "--cloned-source-packages-path", str(root / "packages"),
            "--evidence-dir", str(evidence), "--min-free-gib", "20" if os.environ.get("GITHUB_ACTIONS") == "true" else "80",
            *(["--smoke-archive", "--smoke-control-path", str(root / "expected-control.json")] if archive else []),
            *(["--test-without-building", "--warm-timeout-seconds", "600", "--simulator-boot-submitted"] if warm
              else ["--warm-up-only", "--cold-timeout-seconds", "1200"])]


def read_runner_flows(evidence, scheduling, selected, destination, *, validation=None):
    from ci_bounded_diagnostics import public_failure_locations
    from ci_build_archive import file_hash
    from ci_failure_diagnostics import (failure_messages_diagnostics, public_failure_messages, test_node_diagnostics,
                                        xctest_tool_class, FAILURE_MESSAGES_FIELD)
    from strict_e2e_smoke import validate_group_evidence
    case = decode((evidence / "case-manifest.json").read_text())
    group = selected[0]
    expected_source = {"source_sha": scheduling["head_sha"], "suite": "smoke-flow", "destination": destination,
                       **{key: group[key] for key in ("platform", "device", "configuration")}}
    require(all(case.get(key) == value for key, value in expected_source.items()), "smoke runner source binding differs")
    raw = decode((evidence / "smoke-flow-results.json").read_text())
    require(case.get("selection") == raw.get("selection") == "group", "smoke runner selection is not a complete group")
    require(raw.get("source_sha") == scheduling["head_sha"], "smoke runner first-result source binding differs")
    require(raw.get("schema_version") == 1 and isinstance(raw.get("flows"), list) and case.get("flows") == raw["flows"],
            "smoke runner first-result record differs from its case manifest")
    require(case.get("source_dirty_paths") == raw.get("source_dirty_paths") == []
            and raw.get("device") == group["device"] and raw.get("configuration") == group["configuration"],
            "smoke runner source state or group differs")
    require([item.get("id") for item in raw["flows"]] == [item["id"] for item in selected[:len(raw["flows"])]],
            "smoke runner ordered flow population differs")
    expected = {flow["id"]: flow for flow in selected}
    group_failures = raw.get("group_failures", [])
    require(case.get("group_failures", []) == group_failures and isinstance(group_failures, list)
            and all(isinstance(failure, dict) and set(failure) == {"failure_kind", "exit_code", "flow_ids"}
                    and failure["failure_kind"] in {"warm-products", "sensitive-scan", "build-cleanup", "evidence-finalization", "official-result"}
                    and type(failure["exit_code"]) is int and failure["exit_code"] == 2
                    and isinstance(failure["flow_ids"], list) and failure["flow_ids"]
                    and all(isinstance(flow_id, str) and flow_id in expected for flow_id in failure["flow_ids"])
                    and len(failure["flow_ids"]) == len(set(failure["flow_ids"])) for failure in group_failures),
            "smoke runner group gate evidence differs")
    rows, errors, seen = [], [], set()
    if case.get("result") not in {"Passed", "FAILED"}:
        errors.append("runner-group-finalization-incomplete")
    root_tests = evidence / "official-tests.json"
    if not root_tests.is_file() or case.get("official_tests_sha256") != file_hash(root_tests):
        errors.append("runner-group-official-hash-mismatch")
    for result in raw["flows"]:
        require(isinstance(result, dict) and result.get("id") in expected and result["id"] not in seen,
                "smoke runner flow population differs")
        flow = expected[result["id"]]
        seen.add(flow["id"])
        require(result.get("source_sha") == scheduling["head_sha"] and result.get("source_dirty_paths") == [],
                "smoke runner flow source differs")
        require(result.get("selector") == flow["selector"] and result.get("outcome") in {"PASS", "FAIL"}
                and type(result.get("exit_code")) is int and (result["outcome"] == "PASS") == (result["exit_code"] == 0),
                "smoke runner raw outcome differs")
        require(result.get("failure_kind") in {"none", "test", "hang-guard", "infrastructure", "official-result", "cleanup",
                                               "build-cleanup", "evidence-finalization", "warm-products", "sensitive-scan"}
                and (result["failure_kind"] == "none") == (result["outcome"] == "PASS")
                and type(result.get("official_execution_complete")) is bool,
                "smoke runner flow metadata differs")
        require(valid_pretest_failure(result), "smoke runner pretest failure step differs")
        locations = result.get("failure_locations")
        require(locations is None or public_failure_locations(locations) is not None,
                "smoke runner public failure locations differ")
        row = {"id": flow["id"], "selector": flow["selector"], "runner_outcome": result["outcome"],
               "source_sha": result["source_sha"], "failure_kind": result["failure_kind"],
               "failure_locations": locations,
               "runner_official_execution_complete": result["official_execution_complete"],
               "outcome": "passed" if result["outcome"] == "PASS" else "failed", "exit_code": result["exit_code"],
               "elapsed_seconds": result.get("elapsed_seconds"), "total_elapsed_seconds": result.get("total_elapsed_seconds"),
               "executed": False, "official_execution_complete": False,
               "failure_category": None if result["outcome"] == "PASS" else "infra",
               "first_failure_message": None}
        if "pretest_failure_step" in result:
            row["pretest_failure_step"] = result["pretest_failure_step"]
        fixed_messages = {"Smoke flow execution exceeded its hang guard.",
                          "Smoke flow infrastructure or official-result validation failed."}
        message = result.get("first_public_failure_message")
        if isinstance(message, str):
            projected = public_failure_messages([message])
            row["first_failure_message"] = message if message in fixed_messages else projected[0] if projected else None
        try:
            directory = evidence / flow["id"]
            per_flow = decode((directory / "case-manifest.json").read_text())
            require(all(per_flow.get(key) == value for key, value in expected_source.items() if key != "device")
                    and per_flow.get("source_dirty_paths") == []
                    and per_flow.get("flow") == result and per_flow.get("exit_code") == result["exit_code"]
                    and per_flow.get("result") == ("Passed" if result["outcome"] == "PASS" else "FAILED"),
                    "flow source binding differs")
            tests_path = directory / "official-tests.json"
            require(per_flow.get("official_tests_sha256") == result.get("official_tests_sha256") == file_hash(tests_path),
                    "flow official hash differs")
            tests = decode(tests_path.read_text())
            official = read_case_official(directory)
            require(official is not None and per_flow.get("official_summary") == result.get("official_summary") == official,
                    "flow official summary differs")
            facts = official_tests_facts(tests)["test_cases"]
            require(len(facts) == 1 and facts[0]["bundle"] == "immichSlidesUITests"
                    and facts[0]["identifier"] == flow["selector"] + "()"
                    and facts[0]["result"] in {"Passed", "Failed", "Skipped"}, "flow official identity differs")
            counts = {"totalTestCount": 1, "passedTests": 0, "failedTests": 0, "skippedTests": 0}
            counts[{"Passed": "passedTests", "Failed": "failedTests", "Skipped": "skippedTests"}[facts[0]["result"]]] = 1
            require(all(official[key] == value for key, value in counts.items()), "flow official counts differ")
            require(result["official_execution_complete"] is True and facts[0]["result"] in {"Passed", "Failed"},
                    "flow official execution incomplete")
            require(result["outcome"] != "PASS" or facts[0]["result"] == "Passed", "flow pass contradicts official result")
            row["executed"] = row["official_execution_complete"] = True
            row["official_summary"] = official
            detail = test_node_diagnostics(tests).get(flow["selector"], {})
            if "first_failure" in detail:
                row["first_failure"] = detail["first_failure"]
            messages = detail.get(FAILURE_MESSAGES_FIELD, [])
            if messages:
                row["diagnostics"] = failure_messages_diagnostics(messages)
            if result["failure_kind"] == "test" and facts[0]["result"] == "Failed":
                row["failure_category"] = ("xctest-tool" if messages and all(xctest_tool_class(item) for item in messages)
                    else "assertion" if detail.get("failure_class", "unknown") not in {"unknown", "process_lifetime", "snapshot_query"}
                    else "unknown")
        except (OSError, ValueError, KeyError, TypeError) as error:
            public_errors = {"flow source binding differs", "flow official hash differs", "flow official summary differs",
                             "flow official identity differs", "flow official counts differ", "flow pass contradicts official result",
                             "flow official execution incomplete",
                             "official counts do not add up", "invalid official result", "passing official result has nonpassing counts"}
            reason = str(error) if isinstance(error, ContractError) and str(error) in public_errors else "official export unavailable or invalid"
            errors.append("flow-official-evidence-invalid: " + flow["id"] + ": " + reason)
            row.update(outcome="failed", executed=False, official_execution_complete=False, failure_category="infra")
        rows.append(row)
    if case.get("result") in {"Passed", "FAILED"}:
        exit_code = next((item["exit_code"] for item in raw["flows"] if item["exit_code"]), 0)
        valid_verdict = (type(case.get("exit_code")) is int and case["exit_code"] != 0 and case["result"] == "FAILED"
                         if group_failures else case.get("exit_code") == exit_code
                         and case["result"] == ("Passed" if not exit_code else "FAILED"))
        if (not valid_verdict
                or raw.get("result") != case["result"] or raw.get("exit_code") != case["exit_code"]):
            errors.append("runner-group-verdict-mismatch")
    verdict = {"outcome": "passed", "reason": None, "group_failures": group_failures}
    try:
        validate_group_evidence(evidence, scheduling.get("flows", selected), group["device"], group["configuration"],
                                expected_source_sha=scheduling["head_sha"])
    except (OSError, ValueError, KeyError, TypeError) as error:
        reason = str(error)
        public_reasons = {
            "smoke-group-evidence: group verdict, selection, source state or device differs",
            "smoke-group-evidence: invalid source SHA", "smoke-group-evidence: source SHA differs",
            "smoke-group-evidence: ordered flow population differs",
            *("smoke-group-evidence: incomplete or failed " + flow["id"] for flow in selected)}
        verdict = {"outcome": "failed", "group_failures": group_failures, "reason": reason if reason in public_reasons
                   else "smoke-group-evidence: official export unavailable or invalid"}
        # Valid official failures remain first results; a rejected all-pass group can never pass.
        if not errors and all(row["outcome"] == "passed" for row in rows):
            errors.append("runner-group-validation-failed: " + verdict["reason"])
    if validation is not None:
        validation.update(verdict)
    return rows, errors


def run_group(scheduling, environment, temporary):
    from strict_e2e_runner_support import RunnerGroupCleanupError, run_runner
    from ci_build_archive import file_hash, workspace_preflight
    from run_offline_unit_tests import CommandError as OfflineCommandError, default_data_available_gib, ensure_disk_for_xcodebuild
    from strict_e2e_runner_support import CommandError, InfrastructureTimeout, prepare_simulator
    validate_plan(scheduling, environment, checkout_sha=git("rev-parse", "HEAD"),
                  manifest_hash=file_hash(ROOT / MANIFEST))
    group_id = environment["SMOKE_GROUP"]
    flows = group_flows(scheduling, group_id)
    group = next(group for group in scheduling["groups"] if group["id"] == group_id)
    archive_mode = scheduling.get("build_mode") == ARCHIVE_MODE and group["platform"] == "ios"
    require(scheduling["execute"], "suppressed shadow plan cannot execute a smoke group")
    root, records = temporary / "smoke-execution.noindex", temporary / "smoke-records"
    require(not os.path.lexists(root) and not os.path.lexists(records), "smoke group output must be fresh")
    records.mkdir()
    root.mkdir()
    write_json(root / "ownership.json", scheduling["shadow"])
    record = {"schema_version": 1, "shadow": scheduling["shadow"], "head_sha": scheduling["head_sha"],
              "manifest_sha256": scheduling["manifest_sha256"], "group": group, "runner_exit_code": 1,
              "group_validation": {"outcome": "unavailable", "reason": "No group evidence."},
              "selection": "unavailable", "elapsed_seconds": 0, "errors": [], "flows": [],
              "job_started_epoch": None, "job_elapsed_seconds": None, "phases": [], "setup_failure_step": None,
              "setup_failure_command": None, "simulator_recreate": None}
    if archive_mode:
        record.update(schema_version=2, timing_mode=ARCHIVE_MODE, build_provenance=None,
                      transfer_seconds=None, verify_seconds=None)
    started = time.monotonic()
    attempted_flows = False
    setup_step = "job-clock"

    def interrupt(_signum, _frame):
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        try:
            record["job_started_epoch"] = job_started_epoch(environment, group_id)
        finally:
            os.environ.pop("SMOKE_TOKEN", None)
            environment.pop("SMOKE_TOKEN", None)
        setup_step = "preflight"
        workspace_preflight(ROOT)
        ensure_disk_for_xcodebuild(default_data_available_gib, 20)
        if archive_mode:
            from strict_e2e_build import load_smoke_archive, smoke_build_identity
            setup_step = "archive-verify"
            phase_started = time.monotonic()
            phase = {"name": "archive-verify", "exit_code": None}
            try:
                selection = decode((temporary / "smoke-archive-selection.json").read_text())
                require(0 <= time.time() - selection["transfer_started_epoch"] <= 120,
                        "smoke archive transfer/verification allowance exhausted")
                provenance = selection["provenance"]
                validate_build_provenance(provenance, scheduling, group["configuration"])
                identity = smoke_build_identity(ROOT, group["configuration"])
                require(identity == selection["identity"] and identity["source"] == scheduling["tested_source"],
                        "smoke archive execution source differs")
                verify_smoke_archive(temporary / "ci-artifacts/smoke-build", root / "derived",
                    expected_identity=identity, control=scheduling["control"],
                    manifest_hash=provenance["manifest_sha256"], archive_hash=provenance["archive_sha256"])
                require(time.time() - selection["transfer_started_epoch"] <= 120,
                        "smoke archive transfer/verification allowance exhausted")
                write_json(root / "expected-control.json", scheduling["control"])
                phase["exit_code"] = 0
            finally:
                phase["elapsed_seconds"] = time.monotonic() - phase_started
                record["phases"].append(phase)
                record["verify_seconds"] = phase["elapsed_seconds"]
        for attempt in range(2):
            try:
                setup_step = "simulator"
                udid = create_group_simulator(group, environment)
                destination = "platform=" + ("tvOS" if group["platform"] == "tvos" else "iOS") + " Simulator,id=" + udid
                if archive_mode:
                    setup_step = "simulator-ready"
                    # Archive consumers have no cold build to absorb first-boot work before identity reads.
                    prepare_simulator(udid, boot_submitted=True, should_check_app=False)
                break
            except (CommandError, OfflineCommandError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                failed_udid = environment.get("UI_SIMULATOR")
                if (attempt != 0 or not failed_udid or not can_recreate_simulator(
                        group_id, archive_mode, record["job_started_epoch"])):
                    raise
                try:
                    retired = retire_group_simulator(failed_udid)
                    if retired:
                        clear_retired_simulator(environment)
                except (CommandError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                    # Retirement never replaces the original setup failure or its timeout attribution.
                    raise error
                if not retired or not can_recreate_simulator(group_id, archive_mode,
                        record["job_started_epoch"], retiring=False):
                    raise
                command = setup_failure_command(error, setup_step)
                record["simulator_recreate"] = {"step": setup_step, "command": command}
                print(f"setup-recreate: step={setup_step}; command={command}; attempt=1", file=sys.stderr, flush=True)
        if archive_mode:
            remaining = record["job_started_epoch"] + GROUP_BUDGET_MINUTES[group_id] * 60 - time.time()
            if record["simulator_recreate"] is not None and remaining < ARCHIVE_LOAD_OWN_CAP_SECONDS:
                setup_step = None
                raise subprocess.TimeoutExpired([], 0)
            setup_step = "archive-load"
            load_smoke_archive(ROOT, group["configuration"], destination, group["device"], root / "derived",
                               control=scheduling["control"])
            record["build_provenance"] = provenance
        for warm, name in ((False, "archive-verify" if archive_mode else "warm-up"), (True, "flows")):
            if archive_mode and not warm:
                continue
            setup_step = "runner-command"
            remaining = record["job_started_epoch"] + GROUP_BUDGET_MINUTES[group_id] * 60 - time.time()
            command = runner_command(group, destination, root, root / name, warm=warm, archive=archive_mode,
                                     scope=scheduling["scope"])
            setup_step = None
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, 0)
            attempted_flows = warm
            phase_started = time.monotonic()
            phase = {"name": name, "exit_code": None}
            try:
                code = run_runner(command, ROOT, root / (name + ".log"), timeout_seconds=remaining)
                phase["exit_code"] = code
            finally:
                phase["elapsed_seconds"] = time.monotonic() - phase_started
                record["phases"].append(phase)
            record["runner_exit_code"] = code
            if not warm and code:
                record["errors"].append("archive-verification-failed" if archive_mode else "cold-build-failed")
            if code:
                break
    except RunnerGroupCleanupError:
        (temporary / "smoke-cleanup-blocked").touch()
        record["errors"].append("runner-group-cleanup-unverified")
        record["runner_exit_code"] = 1
    except (subprocess.TimeoutExpired, InfrastructureTimeout) as error:
        record["errors"].append("setup-step-timeout" if setup_step is not None else "group-budget-exhausted")
        record["runner_exit_code"] = 124
        if setup_step is not None:
            command = setup_failure_command(error, setup_step)
            record["setup_failure_command"] = command
            timeout = f"; timeout={int(error.timeout)}s" if isinstance(error, subprocess.TimeoutExpired) else ""
            print(f"setup-step-timeout: step={setup_step}; command={command}{timeout}", file=sys.stderr, flush=True)
    except KeyboardInterrupt:
        record["errors"].append("group-interrupted")
        record["runner_exit_code"] = 130
    except (CommandError, OfflineCommandError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        record["errors"].append("group-execution-or-official-evidence-failed")
        record["runner_exit_code"] = 1
    finally:
        signal.signal(signal.SIGTERM, previous)
        if record["runner_exit_code"] != 0:
            record["setup_failure_step"] = setup_step
        if attempted_flows and not (temporary / "smoke-cleanup-blocked").exists():
            try:
                evidence = root / "flows"
                selection = decode((evidence / "case-manifest.json").read_text()).get("selection")
                record["selection"] = selection if selection in {"group", "single-flow"} else "unavailable"
                record["flows"], reader_errors = read_runner_flows(evidence, scheduling, flows, destination,
                                                                  validation=record["group_validation"])
                record["errors"].extend(reader_errors)
            except (OSError, ValueError, KeyError, TypeError):
                record["errors"].append("group-first-result-evidence-invalid")
        record["elapsed_seconds"] = time.monotonic() - started
        if record["job_started_epoch"] is not None:
            record["job_elapsed_seconds"] = max(0, time.time() - record["job_started_epoch"])
        for phase in record["phases"]:
            if phase["exit_code"] is None:
                phase["exit_code"] = record["runner_exit_code"]
        observed = {row["id"]: row for row in record["flows"]}
        record["flows"] = [observed.get(flow["id"], {
            "id": flow["id"], "selector": flow["selector"], "outcome": "not-run", "elapsed_seconds": None,
            "executed": False, "official_execution_complete": False,
            "failure_category": "infra", "first_failure_message": "No first-result evidence."}) for flow in flows]
        copy_first_failure_images(root / "flows", records, record["flows"])
        write_json(records / "group.json", record)
        check_group_upload(records, record)
        output(environment, "records_safe", "true")
    return 0 if record["runner_exit_code"] == 0 and not record["errors"] and all(
        row["outcome"] == "passed" for row in record["flows"]) else 1


def cleanup_holder_families(commands):
    families = set()
    for field in commands.splitlines():
        if not field.startswith(b"c"):
            continue
        name = field[1:]
        if name.startswith((b"mds", b"mdworker")):
            family = "spotlight"
        elif name.startswith((b"CoreSimulator", b"com.apple.CoreSimulator")) or name in {b"launchd_sim", b"simctl"}:
            family = "simulator"
        elif name in {b"xcodebuild", b"XCBBuildService", b"testmanagerd"}:
            family = "xcode"
        elif name.lower().startswith(b"python"):
            family = "python"
        else:
            family = "other"
        families.add(family)
    return sorted(families or {"other"})


def cleanup(environment, temporary):
    step = "runner-cleanup"
    holder_commands = b""
    try:
        require(not (temporary / "smoke-cleanup-blocked").exists(), "runner cleanup unverified; retain owned inputs")
        step = "ownership"
        root = temporary / ("smoke-producer" if environment.get("SMOKE_CONFIGURATION") else "smoke-execution.noindex")
        if root.exists():
            require(decode((root / "ownership.json").read_text()) == shadow_context(environment), "cleanup ownership differs")
        udid = environment.get("UI_SIMULATOR")
        if udid:
            step = "simctl-shutdown"
            subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False, timeout=60,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            step = "simctl-delete"
            subprocess.run(["xcrun", "simctl", "delete", udid], check=True, timeout=60)
        if root.exists():
            step = "lsof-probe"
            try:
                holders = subprocess.run(["lsof", "-Fc", "+D", str(root)], capture_output=True, timeout=30)
                if (holders.returncode == 0 and holders.stdout and not holders.stderr
                        and cleanup_holder_families(holders.stdout) == ["spotlight"]):
                    print("cleanup-retry: family=spotlight attempt=1", file=sys.stderr, flush=True)
                    time.sleep(5)
                    holders = subprocess.run(["lsof", "-Fc", "+D", str(root)], capture_output=True, timeout=30)
            except subprocess.TimeoutExpired:
                step = "lsof-timeout"
                raise
            holder_commands = holders.stdout
            if holders.returncode in {0, 1} and holder_commands:
                step = "lsof-holders"
            require(holders.returncode == 1 and not holders.stdout and not holders.stderr,
                    "owned build inputs still open or holder check unavailable; retain them")
            step = "remove"
            shutil.rmtree(root)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print(f"cleanup-failed: step={step}", file=sys.stderr, flush=True)
        if step == "lsof-holders":
            for family in cleanup_holder_families(holder_commands):
                print(f"cleanup-holder: family={family}", file=sys.stderr, flush=True)
        raise
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("stage", "setup", "plan", "plan-shared", "build", "producer-record",
                                          "select-archive", "build-local", "verify-local", "run", "aggregate", "cleanup"))
    parser.add_argument("--configuration", choices=("Debug", "Release"))
    parser.add_argument("--derived-data-path", type=Path)
    parser.add_argument("--packages-path", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--archive-dir", type=Path)
    parser.add_argument("--relocated-path", type=Path)
    parser.add_argument("--manifest-sha256")
    parser.add_argument("--archive-sha256")
    args = parser.parse_args(argv)
    environment = dict(os.environ)
    try:
        if args.phase not in {"build-local", "verify-local"}:
            require(bool(environment.get("RUNNER_TEMP")), "RUNNER_TEMP is required for hosted shadow stages")
        temporary = Path(environment.get("RUNNER_TEMP") or "/tmp")
        if args.phase == "verify-local":
            from strict_e2e_build import smoke_build_identity
            require(os.environ.get("GITHUB_ACTIONS") != "true" and args.configuration and args.archive_dir
                    and args.relocated_path and args.manifest_sha256 and args.archive_sha256,
                    "local archive verification requires explicit configuration, paths and producer hashes")
            verify_smoke_archive(args.archive_dir.resolve(), args.relocated_path.resolve(),
                expected_identity=smoke_build_identity(ROOT, args.configuration),
                control={"mode": "local", "head_sha": git("rev-parse", "HEAD")},
                manifest_hash=args.manifest_sha256, archive_hash=args.archive_sha256)
            print("Relocated smoke archive verified; no compilation", flush=True)
            return 0
        if args.phase == "build-local":
            from ci_build_archive import disk_check
            from strict_e2e_build import build_smoke_archive
            from run_strict_e2e import run_command
            require(os.environ.get("GITHUB_ACTIONS") != "true" and args.configuration is not None
                    and args.derived_data_path and args.packages_path and args.output_dir,
                    "local smoke build requires configuration and explicit owned paths")
            disk_check(80)
            _, measurements = build_smoke_archive(root=ROOT, configuration=args.configuration,
                control={"mode": "local", "head_sha": git("rev-parse", "HEAD")},
                derived=args.derived_data_path.resolve(), packages=args.packages_path.resolve(),
                output=args.output_dir.resolve(), execute=run_command)
            print(json.dumps(measurements, sort_keys=True), flush=True)
            return 0
        if args.phase == "stage":
            head = git("rev-parse", "HEAD")
            require(subprocess.call(["git", "merge-base", "--is-ancestor", head, "origin/main"], cwd=ROOT, timeout=30) == 0,
                    "staged control source is not admitted main")
            destination = temporary / "smoke-control"
            destination.mkdir()
            shutil.copyfile(Path(__file__), destination / "ci_smoke_shadow.py")
            write_json(destination / "stage.json", {"head_sha": head})
            return 0
        if args.phase == "setup":
            return setup(environment)
        if args.phase in {"plan", "plan-shared"}:
            return plan_run(environment, temporary / "smoke-plan", shared=args.phase == "plan-shared")
        if args.phase == "cleanup":
            return cleanup(environment, temporary)
        scheduling = decode((temporary / "ci-artifacts/smoke-plan/plan.json").read_text())
        validate_plan(scheduling, environment)
        sha(scheduling["control_source_sha"])
        staged = temporary / "smoke-control/stage.json"
        source = decode(staged.read_text())["head_sha"] if staged.is_file() else git("rev-parse", "HEAD")
        require(source == scheduling["control_source_sha"], "shadow control checkout differs from plan")
        require(subprocess.call(["git", "merge-base", "--is-ancestor", source, "origin/main"], cwd=ROOT, timeout=30) == 0,
                "planned control source is not admitted main")
        manifest, manifest_hash = manifest_at_head(scheduling["head_sha"])
        validate_plan(scheduling, environment, manifest_hash=manifest_hash, manifest=manifest)
        if args.phase == "build":
            return run_producer(scheduling, environment, temporary)
        if args.phase == "producer-record":
            return finish_producer(scheduling, environment, temporary)
        if args.phase == "select-archive":
            return select_archive(scheduling, environment, temporary)
        if args.phase == "run":
            return run_group(scheduling, environment, temporary)
        if args.phase == "aggregate":
            records, unreadable = [], False
            for path in sorted((temporary / "ci-artifacts/smoke-groups").glob("*/group.json")):
                try:
                    records.append(decode(path.read_text()))
                except (OSError, ValueError):
                    unreadable = True
            producers = []
            for path in sorted((temporary / "ci-artifacts/smoke-producers").glob("*/producer.json")):
                try:
                    producers.append(decode(path.read_text()))
                except (OSError, ValueError):
                    unreadable = True
            read_transfer_timings(scheduling, producers, records, environment)
            record = aggregate(scheduling, records, environment.get("SMOKE_MATRIX_RESULT", "unknown"), producers=producers,
                               producer_results={configuration: environment.get("SMOKE_" + configuration.upper() + "_RESULT")
                                                 for configuration in ("Debug", "Release")})
            if unreadable:
                record["errors"].append("unreadable group record")
                record.update(outcome="failed")
            destination = temporary / "smoke-shadow"
            write_json(destination / "shadow.json", record)
            (destination / "summary.md").write_text(markdown(record), encoding="utf-8")
            scan_records(destination)
            output(environment, "records_safe", "true")
            with open(environment["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
                handle.write(markdown(record))
            return int(record["outcome"] == "failed")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print("Smoke shadow failed closed; inspect the raw first-result records and job phase.", file=sys.stderr)
        return 1


MAX_JSON_BYTES = 16 * 1024 * 1024


class ArtifactRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        from urllib.parse import urlsplit
        parsed = urlsplit(new_url)
        require(parsed.scheme == "https", "artifact redirect must use HTTPS")
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if parsed.hostname != "api.github.com":
            redirected.remove_header("Authorization")
        return redirected

def positive(value):
    require(type(value) is int and value > 0, "positive integer required")
    return value

def complete_attempt_jobs(api, run):
    """Require the API's explicit count, including for an empty attempt."""
    jobs, seen, total = [], set(), None
    for page in range(1, 101):
        response = api.repo(f"actions/runs/{positive(run['id'])}/attempts/{positive(run['run_attempt'])}/jobs?"
                            + urlencode({"per_page": 100, "page": page}))
        count, batch = response["total_count"], response["jobs"]
        require(type(count) is int and 0 <= count <= 10000 and (total is None or count == total),
                "invalid or changing attempt job count")
        require(isinstance(batch, list) and len(batch) <= 100, "invalid attempt jobs")
        total = count
        for job in batch:
            job_id = positive(job["id"])
            require(job_id not in seen and positive(job["run_id"]) == run["id"]
                    and positive(job["run_attempt"]) == run["run_attempt"], "unexpected attempt job")
            seen.add(job_id)
        jobs.extend(batch)
        require(len(seen) <= total, "attempt jobs exceed total count")
        if len(batch) < 100 or len(seen) == total:
            require(len(seen) == total, "incomplete attempt jobs")
            return jobs
    raise ContractError("attempt jobs pagination limit reached")

class GitHub:
    def __init__(self, repository, token, *, response_headers=None):
        require(re.fullmatch(r"[\w.-]+/[\w.-]+", repository) is not None, "invalid repository")
        self.repository, self.token = repository, token
        self.response_headers = response_headers

    def request(self, path, *, method="GET", payload=None, binary=False, missing=False, timeout=45):
        return self._request(path, method=method, payload=payload, binary=binary, missing=missing, timeout=timeout)

    def _request(self, path, *, method, payload, binary, missing, timeout):
        require(method == "GET" and payload is None, "smoke GitHub client is read-only")
        url = "https://api.github.com" + path
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = Request(url, data=data, method=method, headers=headers)
        try:
            with build_opener(ArtifactRedirect()).open(request, timeout=timeout) as response:
                if self.response_headers:
                    self.response_headers(response.headers)
                raw = response.read(MAX_JSON_BYTES + 1)
        except HTTPError as error:
            if self.response_headers:
                self.response_headers(error.headers)
            if missing and error.code == 404:
                return None
            # Never echo response bodies, headers, request objects or credentials.
            message = f"GitHub API {method} refused request (HTTP {error.code})"
            raise ContractError(message) from None
        require(len(raw) <= MAX_JSON_BYTES, "GitHub payload exceeds limit")
        return raw if binary else json.loads(raw) if raw else None

    def repo(self, path, **options):
        return self.request("/repos/" + self.repository + "/" + path, **options)

    def pages(self, path, collection=None, **filters):
        rows = []
        for page in range(1, 101):
            response = self.repo(path + "?" + urlencode(dict(filters, per_page=100, page=page)))
            batch = response[collection] if collection else response
            rows.extend(batch)
            if len(batch) < 100:
                return rows
        raise ContractError("GitHub pagination limit reached; publication refused")


def json_member(api, artifact, filename, *, optional=False):
    require(not artifact["expired"] and artifact["size_in_bytes"] <= MAX_JSON_BYTES, "artifact expired or oversized")
    archive = api.repo(f"actions/artifacts/{positive(artifact['id'])}/zip", binary=True)
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        members = [entry for entry in zipped.infolist() if entry.filename == filename]
        if optional and not members:
            require(not any(entry.filename.rsplit("/", 1)[-1] == filename for entry in zipped.infolist()),
                    "artifact member has an unexpected path")
            return None
        require(len(members) == 1 and members[0].file_size <= MAX_JSON_BYTES, "artifact member missing, duplicated or oversized")
        value = json.loads(zipped.read(members[0]))
        require(not optional or value is not None, "optional artifact member cannot be null")
        return value


def official_tests_facts(payload: dict) -> dict:
    test_cases: list[dict] = []

    def walk(nodes: object, bundle_name: object) -> None:
        for node in nodes if isinstance(nodes, list) else []:
            if not isinstance(node, dict):
                continue
            node_type = node.get("nodeType")
            if node_type == "Test Case":
                test_cases.append(
                    {"bundle": bundle_name, "identifier": node.get("nodeIdentifier"), "result": node.get("result")}
                )
                continue
            walk(node.get("children"), node.get("name") if str(node_type).endswith("test bundle") else bundle_name)

    walk(payload.get("testNodes"), None)
    devices = payload.get("devices")
    return {"test_cases": test_cases, "devices": devices if isinstance(devices, list) else []}

def read_case_official(evidence):
    """Read exported results after finalization, including nonzero runner exits."""
    def read(path):
        payload = decode(path.read_text())
        counts = ("totalTestCount", "passedTests", "failedTests", "skippedTests")
        for name in counts:
            require(type(payload.get(name)) is int and payload[name] >= 0, "invalid official count: " + name)
        require(payload["totalTestCount"] == sum(payload[name] for name in counts[1:]), "official counts do not add up")
        require(payload.get("result") in {"Passed", "Failed", "Skipped", "Unknown"}, "invalid official result")
        require(payload["result"] != "Passed" or (payload["passedTests"] == payload["totalTestCount"]
                and payload["totalTestCount"] > 0), "passing official result has nonpassing counts")
        result = {name: payload[name] for name in (*counts, "result")}
        return result

    path = evidence / "official-summary.json"
    top = read(path) if path.is_file() else None
    return top


if __name__ == "__main__":
    if sys.argv[1:2] in (["build-local"], ["verify-local"]):
        from ci_local import local_main
        raise SystemExit(local_main(main, __file__))
    raise SystemExit(main())
