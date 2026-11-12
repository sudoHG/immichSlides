#!/usr/bin/env python3
"""Read-only smoke shadow planning and raw first-result aggregation."""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

# The trusted entry point is staged outside the checkout before selecting a historical main SHA.
ROOT = Path(os.environ.get("GITHUB_WORKSPACE") or Path(__file__).resolve().parent.parent)
sys.path.insert(0, str(ROOT / "scripts"))
from ci_summary import ContractError, decode, markdown_text, require, sha
WORKFLOW = ".github/workflows/ci-smoke-shadow.yml"
NIGHTLY = ".github/workflows/ci-nightly.yml"
MANIFEST = "scripts/smoke-flows.json"
GROUP_BUDGET_SECONDS = 22 * 60  # The 25-minute job also reserves setup, upload and cleanup.


def shadow_context(environment):
    return {"id": environment.get("GITHUB_RUN_ID"),
            "attempt": int(environment.get("GITHUB_RUN_ATTEMPT", "1")),
            "event": environment.get("GITHUB_EVENT_NAME")}


def admit(environment, payload, run, workflow):
    from ci_nightly_change import FULL_MANUAL_TITLE
    require(environment.get("GITHUB_REF") == "refs/heads/main"
            and environment.get("GITHUB_EVENT_NAME") in {"workflow_run", "workflow_dispatch"},
            "smoke shadow is main-only with completion/manual triggers")
    require(shadow_context(environment)["attempt"] == 1, "smoke shadow records only the first attempt; dispatch a new run")
    repository = environment.get("GITHUB_REPOSITORY")
    require(run.get("repository", {}).get("full_name") == repository
            and (run.get("head_repository") or {}).get("full_name") == repository
            and run.get("head_branch") == "main" and run.get("event") in {"schedule", "workflow_dispatch"},
            "nightly source must be a same-repository main schedule or dispatch")
    require(run["event"] == "schedule" or run.get("display_title") == FULL_MANUAL_TITLE,
            "shadow requires a full scheduled or manual nightly")
    require(run.get("path") == workflow.get("path") == NIGHTLY and run.get("workflow_id") == workflow.get("id"),
            "nightly workflow path or ID differs")
    require(run.get("status") == "completed", "nightly must be completed before shadow execution")
    sha(run.get("head_sha"))
    if environment["GITHUB_EVENT_NAME"] == "workflow_run":
        event_run = payload.get("workflow_run", {})
        require(all(event_run.get(key) == run.get(key) for key in
                    ("id", "run_attempt", "head_sha", "head_branch", "path", "workflow_id", "event"))
                and (event_run.get("head_repository") or {}).get("full_name") == repository,
                "completion event differs from authoritative nightly attempt")
    else:
        requested = environment.get("SMOKE_NIGHTLY_RUN_ID", "")
        require(requested.isdecimal() and int(requested) > 0 and int(requested) == run.get("id"),
                "manual shadow requires a completed nightly run ID")
    return run["head_sha"]


def manifest_groups(manifest):
    groups = sorted({(flow["platform"], flow["device"], flow["configuration"]) for flow in manifest["flows"]})
    return [{"id": device + "-" + configuration.lower(), "platform": platform, "device": device,
             "configuration": configuration} for platform, device, configuration in groups]


def make_plan(environment, run, manifest, manifest_hash, nightly_execution, nightly_aggregate=None):
    execute = environment["GITHUB_EVENT_NAME"] == "workflow_dispatch" or nightly_execution != "skipped"
    return {"schema_version": 1, "repository": environment["GITHUB_REPOSITORY"], "head_sha": run["head_sha"],
            "shadow": shadow_context(environment), "started_epoch": time.time(),
            "manifest_sha256": manifest_hash, "flows": manifest["flows"],
            "groups": manifest_groups(manifest),
            "nightly": {"id": str(run["id"]), "attempt": run["run_attempt"], "head_sha": run["head_sha"],
                        "event": run["event"], "status": run["status"], "conclusion": run["conclusion"],
                        "execution": nightly_execution, "aggregate": nightly_aggregate},
            "execute": execute, "blocked_by_active_nightly": [],
            "not_run_reason": None if execute else "Nightly skipped unchanged source; automatic shadow was not run."}


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
        require(checkout_sha == plan["head_sha"], "tested checkout differs from nightly head SHA")
    if manifest_hash is not None:
        require(manifest_hash == plan["manifest_sha256"], "manifest binding differs from the planned nightly SHA")
    if manifest is not None:
        require(plan["flows"] == manifest["flows"] and plan["groups"] == manifest_groups(manifest),
                "manifest population differs from the planned nightly SHA")


def counts_as_shadow(plan, *, executed, errors, matrix_result):
    """Count new first execution independently of the old nightly's health/baseline verdict."""
    from ci_nightly_change import REAL_RESULT_CONCLUSIONS
    return (executed and not errors and matrix_result in {"success", "failure"}
            and plan["shadow"]["attempt"] == 1 and plan["nightly"]["status"] == "completed"
            and plan["nightly"]["head_sha"] == plan["head_sha"] and plan["nightly"]["execution"] != "skipped"
            and plan["nightly"]["conclusion"] in REAL_RESULT_CONCLUSIONS)


def aggregate(plan, records, matrix_result):
    from ci_bounded_diagnostics import public_failure_locations
    errors, observed, seen = [], {}, set()
    validations = {}
    timings = {}
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
            if (record.get("schema_version") != 1 or record.get("shadow") != plan["shadow"]
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
                observed[row["id"]] = row
            record_errors = record.get("errors")
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
                and [phase["name"] for phase in phases] == ["warm-up", "flows"][:len(phases)]
                and (not all(row.get("executed") is True for row in rows) or len(phases) == 2))
            if not valid_timing:
                errors.append("invalid group job timing: " + group_id)
            timings[group_id] = ({key: record[key] for key in ("job_started_epoch", "job_elapsed_seconds", "phases")}
                                 if valid_timing else {"job_started_epoch": None, "job_elapsed_seconds": None, "phases": []})
            code = record.get("runner_exit_code")
            if type(code) is not int or code != 0 and all(row.get("outcome") == "passed" for row in rows):
                errors.append("runner failed without a failing flow: " + group_id)
        for group_id in groups.keys() - seen:
            errors.append("missing group: " + group_id)
        if matrix_result != "success" and not any(row["outcome"] in {"failed", "crashed", "timed-out"}
                                                   for row in observed.values()):
            errors.append("matrix jobs did not succeed")
    elif records or matrix_result not in {"skipped", "success"}:
        errors.append("unexpected execution on skipped nightly")
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
            "manifest_sha256": plan["manifest_sha256"], "shadow": plan["shadow"], "nightly": plan["nightly"],
            "nightly_run_id": plan["nightly"]["id"], "not_run_reason": plan["not_run_reason"],
            "blocked_by_active_nightly": plan["blocked_by_active_nightly"],
            "outcome": outcome, "executed": executed,
            "comparison_eligible": counts_as_shadow(plan, executed=executed, errors=errors, matrix_result=matrix_result),
            "wall_seconds": max(0, time.time() - plan["started_epoch"]),
            "matrix_job_result": matrix_result, "errors": errors, "group_validation": validations,
            "group_timings": timings, "flows": flows}


def markdown(record):
    nightly = record["nightly"]
    old_status = (nightly.get("aggregate") or {}).get("status", "unknown")
    url = f"https://github.com/{record['repository']}/actions/runs/{nightly['id']}/attempts/{nightly['attempt']}"
    lines = ["## Smoke shadow: " + record["outcome"].upper(), "",
             f"Source `{record['head_sha']}`; [old nightly {nightly['id']}, attempt {nightly['attempt']}]({url}) "
             f"({nightly['conclusion']}; evidence: {nightly['execution']}; aggregate: {markdown_text(old_status)}).", "",
             f"Executed: {record['executed']}; comparable executed shadow: {record['comparison_eligible']}. "
             "Informational only; first results, no retries or yellow.", "",
             "| Flow | Device | Configuration | Outcome | Elapsed (s) | Failure class | First public failure |",
             "|---|---|---|---|---:|---|---|"]
    for row in record["flows"]:
        values = [row["id"], row["device"], row["configuration"], row["outcome"], row["elapsed_seconds"],
                  row.get("failure_category"), row.get("first_failure_message")]
        lines.append("| " + " | ".join(markdown_text(value) if value is not None else "unknown" for value in values) + " |")
    if record["group_timings"]:
        lines += ["", "| Group | Warm-up/build phase (s) | Job elapsed (s) |", "|---|---:|---:|"]
        for group_id, timing in record["group_timings"].items():
            warm = next((phase["elapsed_seconds"] for phase in timing.get("phases") or [] if phase["name"] == "warm-up"), None)
            lines.append("| " + " | ".join(markdown_text(value) if value is not None else "unknown"
                         for value in (group_id, warm, timing["job_elapsed_seconds"])) + " |")
    if record["errors"]:
        lines += ["", "Errors: " + "; ".join(markdown_text(error) for error in record["errors"])]
    return "\n".join(lines) + "\n"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True, timeout=30).strip()


def manifest_at_head(head):
    from strict_e2e_smoke import validate_manifest
    raw = subprocess.check_output(["git", "show", head + ":" + MANIFEST], cwd=ROOT, timeout=30)
    manifest = decode(raw.decode("utf-8"))
    planned = decode(git("show", head + ":scripts/ci-test-tiers.json"))["smoke_flows"]
    validate_manifest(manifest, planned)
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


def paired_nightly_aggregate(api, run):
    from ci_publish import json_member
    name = f"nightly-aggregate-{run['id']}-{run['run_attempt']}"
    matches = [item for item in api.pages(f"actions/runs/{run['id']}/artifacts", "artifacts") if item["name"] == name]
    if len(matches) != 1 or matches[0].get("expired") is not False:
        return {"availability": "unavailable"}
    raw = json_member(api, matches[0], "nightly.json")
    require(isinstance(raw, dict), "paired nightly aggregate source differs")
    identity = raw.get("identity", {})
    require(isinstance(identity, dict) and raw.get("run") == {"id": str(run["id"]), "attempt": run["run_attempt"]}
            and identity.get("repository") == api.repository and identity.get("commit_sha") == run["head_sha"],
            "paired nightly aggregate source differs")
    # Preserve the old verdict and diagnostics as reported; none is a new-shadow health gate.
    return {"availability": "present", **{key: raw.get(key) for key in
            ("status", "environment_limited", "errors", "matrix", "tiers")}}


def plan_run(environment, directory):
    from ci_publish import GitHub
    from ci_nightly_change import run_evidence, ACTIVE_RUN_STATUSES, REAL_RESULT_CONCLUSIONS
    payload = decode(Path(environment["GITHUB_EVENT_PATH"]).read_text())
    automatic = environment.get("GITHUB_EVENT_NAME") == "workflow_run"
    requested = str(payload.get("workflow_run", {}).get("id", "")) if automatic else environment.get("SMOKE_NIGHTLY_RUN_ID", "")
    require(requested.isdecimal() and int(requested) > 0, "manual shadow requires a completed nightly run ID")
    api = GitHub(environment["GITHUB_REPOSITORY"], environment.get("SMOKE_TOKEN"))
    run = api.repo("actions/runs/" + requested)
    workflow = api.repo("actions/workflows/ci-nightly.yml")
    head = admit(environment, payload, run, workflow)
    require(subprocess.call(["git", "merge-base", "--is-ancestor", head, "origin/main"], cwd=ROOT, timeout=30) == 0,
            "nightly source is not an ancestor of main")
    manifest, manifest_hash = manifest_at_head(head)
    try:
        execution = run_evidence(api, run) or "unverified"
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        # Incomplete old-nightly evidence cannot suppress the new raw smoke observation.
        execution = "unverified"
    try:
        old_aggregate = paired_nightly_aggregate(api, run)
    except (OSError, ValueError, KeyError, TypeError):
        old_aggregate = {"availability": "unverified"}
    scheduling = make_plan(environment, run, manifest, manifest_hash, execution, old_aggregate)
    active = set()
    for status in sorted(ACTIVE_RUN_STATUSES):
        for candidate in api.pages("actions/workflows/ci-nightly.yml/runs", "workflow_runs", branch="main", status=status):
            require(isinstance(candidate, dict) and candidate.get("head_branch") == "main"
                    and candidate.get("status") == status and candidate.get("path") == NIGHTLY
                    and candidate.get("workflow_id") == workflow["id"]
                    and type(candidate.get("id")) is int and candidate["id"] > 0,
                    "active nightly listing differs")
            active.add(str(candidate["id"]))
    if active:
        scheduling.update(execute=False, blocked_by_active_nightly=sorted(active),
                          not_run_reason="Main nightly is active; shadow was not run.")
    if run.get("conclusion") not in REAL_RESULT_CONCLUSIONS:
        scheduling.update(execute=False, not_run_reason="Nightly conclusion is not success/failure; shadow was not run.")
    write_json(directory / "plan.json", scheduling)
    scan_records(directory)
    output(environment, "head_sha", head)
    output(environment, "execute", str(scheduling["execute"]).lower())
    output(environment, "matrix", json.dumps({"include": scheduling["groups"]}, separators=(",", ":")))
    output(environment, "records_safe", "true")
    return 0


def job_started_epoch(environment, group_id):
    from ci_publish import GitHub, complete_attempt_jobs
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


def runner_command(group, destination, root, evidence, *, warm):
    return [sys.executable, "-B", str(ROOT / "scripts/run_strict_e2e.py"), "--suite", "smoke-flow",
            "--platform", group["platform"], "--smoke-device", group["device"],
            "--configuration", group["configuration"], "--destination", destination,
            "--derived-data-path", str(root / "derived"), "--cloned-source-packages-path", str(root / "packages"),
            "--evidence-dir", str(evidence), "--min-free-gib", "20" if os.environ.get("GITHUB_ACTIONS") == "true" else "80",
            *(["--test-without-building", "--warm-timeout-seconds", "600", "--simulator-boot-submitted"] if warm
              else ["--warm-up-only", "--cold-timeout-seconds", "1200"])]


def read_runner_flows(evidence, scheduling, selected, destination, *, validation=None):
    from ci_bounded_diagnostics import public_failure_locations
    from ci_build_archive import file_hash
    from ci_failure_diagnostics import (failure_messages_diagnostics, public_failure_messages, test_node_diagnostics,
                                        xctest_tool_class, FAILURE_MESSAGES_FIELD)
    from run_strict_ci_tracer import read_case_official
    from strict_e2e_p2_contract import official_tests_facts
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
            official = read_case_official(directory, "smoke-flow")
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
    from ci_build_archive import file_hash, workspace_preflight
    from ci_simulator import create_and_boot_simulator
    from run_offline_unit_tests import default_data_available_gib, ensure_disk_for_xcodebuild
    from run_strict_ci_tracer import run_runner, RunnerGroupCleanupError
    validate_plan(scheduling, environment, checkout_sha=git("rev-parse", "HEAD"),
                  manifest_hash=file_hash(ROOT / MANIFEST))
    group_id = environment["SMOKE_GROUP"]
    flows = group_flows(scheduling, group_id)
    group = next(group for group in scheduling["groups"] if group["id"] == group_id)
    require(scheduling["execute"], "suppressed shadow plan cannot execute a smoke group")
    root, records = temporary / "smoke-execution", temporary / "smoke-records"
    require(not os.path.lexists(root) and not os.path.lexists(records), "smoke group output must be fresh")
    records.mkdir()
    root.mkdir()
    write_json(root / "ownership.json", scheduling["shadow"])
    record = {"schema_version": 1, "shadow": scheduling["shadow"], "head_sha": scheduling["head_sha"],
              "manifest_sha256": scheduling["manifest_sha256"], "group": group, "runner_exit_code": 1,
              "group_validation": {"outcome": "unavailable", "reason": "No group evidence."},
              "selection": "unavailable", "elapsed_seconds": 0, "errors": [], "flows": [],
              "job_started_epoch": None, "job_elapsed_seconds": None, "phases": []}
    started = time.monotonic()
    attempted_flows = False

    def interrupt(_signum, _frame):
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        try:
            record["job_started_epoch"] = job_started_epoch(environment, group_id)
        finally:
            os.environ.pop("SMOKE_TOKEN", None)
            environment.pop("SMOKE_TOKEN", None)
        workspace_preflight(ROOT)
        ensure_disk_for_xcodebuild(default_data_available_gib, 20)
        udid = create_and_boot_simulator("appletv" if group["device"] == "tv" else group["device"], "smoke-" + group_id)
        destination = "platform=" + ("tvOS" if group["platform"] == "tvos" else "iOS") + " Simulator,id=" + udid
        for warm, name in ((False, "warm-up"), (True, "flows")):
            remaining = record["job_started_epoch"] + GROUP_BUDGET_SECONDS - time.time()
            command = runner_command(group, destination, root, root / name, warm=warm)
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
                record["errors"].append("cold-build-failed")
            if code:
                break
    except RunnerGroupCleanupError:
        (temporary / "smoke-cleanup-blocked").touch()
        record["errors"].append("runner-group-cleanup-unverified")
        record["runner_exit_code"] = 1
    except subprocess.TimeoutExpired:
        record["errors"].append("group-budget-exhausted")
        record["runner_exit_code"] = 124
    except KeyboardInterrupt:
        record["errors"].append("group-interrupted")
        record["runner_exit_code"] = 130
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        record["errors"].append("group-execution-or-official-evidence-failed")
        record["runner_exit_code"] = 1
    finally:
        signal.signal(signal.SIGTERM, previous)
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
        write_json(records / "group.json", record)
        scan_records(records)
        output(environment, "records_safe", "true")
    return 0 if record["runner_exit_code"] == 0 and not record["errors"] and all(
        row["outcome"] == "passed" for row in record["flows"]) else 1


def cleanup(environment, temporary):
    require(not (temporary / "smoke-cleanup-blocked").exists(), "runner cleanup unverified; retain owned inputs")
    root = temporary / "smoke-execution"
    if root.exists():
        require(decode((root / "ownership.json").read_text()) == shadow_context(environment), "cleanup ownership differs")
    udid = environment.get("UI_SIMULATOR")
    if udid:
        subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False, timeout=60,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "delete", udid], check=True, timeout=60)
    if root.exists():
        holders = subprocess.run(["lsof", "-Fpc", "+D", str(root)], capture_output=True, timeout=30)
        require(holders.returncode == 1 and not holders.stdout and not holders.stderr,
                "owned build inputs still open or holder check unavailable; retain them")
        shutil.rmtree(root)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("stage", "setup", "plan", "run", "aggregate", "cleanup"))
    args = parser.parse_args(argv)
    environment = dict(os.environ)
    temporary = Path(environment["RUNNER_TEMP"])
    try:
        if args.phase == "stage":
            destination = temporary / "smoke-control"
            destination.mkdir()
            shutil.copyfile(Path(__file__), destination / "ci_smoke_shadow.py")
            return 0
        if args.phase == "setup":
            return setup(environment)
        if args.phase == "plan":
            return plan_run(environment, temporary / "smoke-plan")
        if args.phase == "cleanup":
            return cleanup(environment, temporary)
        scheduling = decode((temporary / "ci-artifacts/smoke-plan/plan.json").read_text())
        validate_plan(scheduling, environment)
        manifest, manifest_hash = manifest_at_head(scheduling["head_sha"])
        validate_plan(scheduling, environment, manifest_hash=manifest_hash, manifest=manifest)
        if args.phase == "run":
            return run_group(scheduling, environment, temporary)
        if args.phase == "aggregate":
            records, unreadable = [], False
            for path in sorted((temporary / "ci-artifacts/smoke-groups").glob("*/group.json")):
                try:
                    records.append(decode(path.read_text()))
                except (OSError, ValueError):
                    unreadable = True
            record = aggregate(scheduling, records, environment.get("SMOKE_MATRIX_RESULT", "unknown"))
            if unreadable:
                record["errors"].append("unreadable group record")
                record.update(outcome="failed", comparison_eligible=False)
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


if __name__ == "__main__":
    raise SystemExit(main())
