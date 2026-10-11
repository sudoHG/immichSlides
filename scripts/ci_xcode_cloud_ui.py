"""Independent Linux selection and per-group Cloud-or-GitHub archive waits."""

from __future__ import annotations

import json
import os
import subprocess
import time
from datetime import timedelta
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlencode

from ci_summary import ContractError, decode, observation, require, test_identity, write_summary
from ci_xcode_cloud import ROUTE_PATH, archive_evidence_run, trusted_artifact
from ci_xcode_cloud_client import RetryingGitHub, transient
from ci_xcode_cloud_schedule import timestamp
import ci_xcode_cloud_groups as groups

FAILURES = (ContractError, KeyError, TypeError, ValueError, OSError, URLError, subprocess.SubprocessError)


def infrastructure(ctx, name, manifest_hash, *, packing=None):
    label = "UI selection" if name == "ui-selection" else "UI cloud selection (" + name.removeprefix("ui-cloud-wait-") + ")"
    item = test_identity("host", label)
    ctx["run"]["job"] = name
    from ci_ui_tests import summary_for
    summary = summary_for(ctx, manifest_hash)
    summary["population"].update(declared=[item], compiled=[item])
    if packing:
        summary["hashes"]["manifests"]["ui-scoped-plan"] = packing["sha256"]
    return summary


def select(args):
    import ci_ui_tests as producer
    ctx = producer.context()
    directory = args.output_dir.resolve()
    require(producer.ROOT != directory and producer.ROOT not in directory.parents, "UI selection output must be outside checkout")
    directory.mkdir(parents=True, exist_ok=False)
    summary = infrastructure(ctx, "ui-selection", producer.file_hash(producer.ROOT / producer.MANIFEST_PATH))
    started, code = time.monotonic(), 1
    try:
        producer.workspace_preflight(producer.ROOT)
        planned = producer.planned_ui_selection(ctx["identity"], pack_scoped_ui=args.pack_scoped_ui,
                                               scoped_ui_v2=getattr(args, "scoped_ui_v2", False))
        affected = producer.app_affected(ctx["identity"])
        producer.output("app_affected", str(affected).lower())
        producer.output("selection_artifact", f"ui-selection-{ctx['run']['id']}-{ctx['run']['attempt']}")
        if planned["packing"]:
            summary["hashes"]["manifests"]["ui-scoped-plan"] = planned["packing"]["sha256"]
        for device, shards in planned["device_shards"].items():
            producer.output(device + "_shards", json.dumps(shards, separators=(",", ":")))
            from ci_publish_git import ui_capacities
            producer.output(device + "_capacity", str(ui_capacities({"selection": {"packing": planned["packing"]}})[device]))
        producer.output("scoped_plan_sha256", planned["packing"]["sha256"] if planned["packing"] else "")
        run_ui = affected
        if ctx["identity"]["event"] == "push":
            from ci_ui_reuse import find_reuse
            api = RetryingGitHub(ctx["identity"]["repository"], os.environ["GH_TOKEN"], time.monotonic() + 5 * 60)
            reuse = find_reuse(api, ctx["identity"])
            deferred = args.defer_main_ui and ctx["identity"]["ref"] == "refs/heads/main"
            run_ui = affected and reuse is None and not deferred
            if reuse is not None or deferred:
                producer.write_json(directory / "archive-selection.json", {"schema_version": 1, "identity": ctx["identity"],
                    "status": "reused" if reuse else "deferred-to-nightly", **({"verdict": reuse} if reuse else
                        {"verification_workflow": producer.NIGHTLY_WORKFLOW})})
        producer.output("run_ui", str(run_ui).lower())
        producer.write_json(directory / "ui-selection.json", {"schema_version": 1, "identity": ctx["identity"],
                            "run_ui": run_ui, **planned})
        for group in groups.GROUPS:
            producer.output("run_" + group, str(run_ui and bool(planned["platform_shards"][group])).lower())
        summary["status"], code = "passed", 0
    except FAILURES:
        summary["infrastructure"].append({"code": "ui-selection-failed", "message": "Functional UI plan could not be derived"})
    finally:
        summary["population"]["observed"] = [observation(summary["population"]["declared"][0], "passed" if code == 0 else "failed",
            time.monotonic() - started, reason=None if code == 0 else "UI selection failed", exit_code=code)]
        write_summary(summary, directory)
    return code


def registration_hint(group):
    """Candidate configuration may release GitHub work, never authorize Cloud."""
    from ci_ui_tests import ROOT
    path = ROOT / groups.REGISTRY_PATH
    try:
        if not path.is_file() or path.is_symlink():
            return False
        registration = decode(path.read_text())
        return registration.get("routing_enabled") is True and group in registration.get("groups", {})
    except FAILURES:
        return False


def wait_cloud_group(ctx, api, group, *, sleep=time.sleep, monotonic=time.monotonic):
    """Return routed only after the same reader accepts complete imported evidence."""
    if ctx["identity"]["event"] != "pull_request" or ctx["source"]["fork_originated"]:
        return "github"
    if not registration_hint(group):
        return "github"
    from ci_publish import trusted_admissions, verify_workflow
    from ci_xcode_cloud_group_route import anchor
    try:
        run = api.repo("actions/runs/" + ctx["run"]["id"])
        verify_workflow(run, api.repo("actions/workflows/ci-ui.yml"), api.repository)
        require(run["run_attempt"] == ctx["run"]["attempt"] and run["head_sha"] == ctx["identity"]["head_sha"], "group producer changed")
        admission_deadline = monotonic() + 5 * 60
        while True:
            record = trusted_admissions(api, [run["id"]]).get(run["id"])
            if record is not None:
                break
            require(monotonic() < admission_deadline, "group admission did not arrive")
            fresh = api.repo("actions/runs/" + str(run["id"]))
            require(fresh["run_attempt"] == run["run_attempt"] and fresh["head_sha"] == run["head_sha"]
                    and fresh["status"] != "completed", "group producer superseded before admission")
            sleep(min(15, max(0, admission_deadline - monotonic())))
        require(record["identity"] == ctx["identity"], "group admission differs")
        registration = (record.get("cloud_v2_inputs") or {}).get("registry") or {}
        if registration.get("routing_enabled") is not True:
            return "github"
        evidence_run = archive_evidence_run(api, run, selection_job=anchor(record, run))
        descriptor = groups.selection(record, evidence_run, group, approved=False)
        suffix = f"{run['id']}-{evidence_run['run_attempt']}-{group}"
        workflow = api.repo("actions/workflows/ci-xcode-cloud-route.yml")
        importer = api.repo("actions/workflows/ci-xcode-cloud-import.yml")
        if workflow["state"] != "active" or importer["state"] != "active":
            return "github"
        cutoff = timestamp(run["run_started_at"]) - timedelta(minutes=5)
        query = urlencode({"event": "workflow_dispatch", "created": ">=" + cutoff.isoformat(), "per_page": 100})
        deadline, start_deadline = monotonic() + 110 * 60, monotonic() + 5 * 60
        delay = 60
        while monotonic() < deadline:
            try:
                fresh = api.repo("actions/runs/" + str(run["id"]))
                require(fresh["run_attempt"] == run["run_attempt"] and fresh["head_sha"] == run["head_sha"]
                        and fresh["status"] != "completed", "group producer superseded")
                route = None
                try:
                    route, _ = trusted_artifact(api, "ci-xcc-route-" + suffix, ROUTE_PATH, "route.json", refresh_main=False)
                    require(route["identity"] == ctx["identity"] and route["group"] == group, "group route identity differs")
                    if route["decision"] != "routed":
                        return "github"
                    groups.trusted_groups(api, record, run, [group], approved=False)
                    return "routed"
                except FAILURES as error:
                    if transient(error):
                        raise
                    # A route alone never authorizes skipped GitHub tests. A
                    # still-running importer may yet produce complete evidence.
                    if route is not None:
                        imports = api.repo(f"actions/workflows/{importer['id']}/runs?" + query)["workflow_runs"]
                        matching = [row for row in imports if row.get("display_title") == "xcc-import-" + suffix]
                        if matching and all(row["status"] == "completed" for row in matching):
                            return "github"
                if evidence_run["run_attempt"] != run["run_attempt"]:
                    return "github"  # Retained evidence is usable only if revalidation already passed.
                sources = api.repo(f"actions/workflows/{workflow['id']}/runs?" + query)["workflow_runs"]
                matching = [row for row in sources if row.get("display_title") == "xcc-route-" + suffix]
                if matching:
                    if all(row["status"] == "completed" for row in matching) and route is None:
                        return "github"
                    import ci_xcode_cloud_state as state
                    source = max(matching, key=lambda row: row["id"])
                    artifacts = api.pages(f"actions/runs/{source['id']}/artifacts", "artifacts")
                    started = state.receipt(api, artifacts, source, workflow, prefix=state.START_PREFIX, member="start.json")
                    if started is not None:
                        require(started["group"] == group and started["identity"] == ctx["identity"]
                                and started["selection_sha256"] == groups.canonical_hash(descriptor), "group start selection differs")
                        if started["decision"] in {"github", "fallback"}:
                            return "github"
                elif monotonic() >= start_deadline or run["run_attempt"] > 1:
                    return "github"
            except FAILURES as error:
                if not transient(error):
                    raise
            sleep(min(delay, max(0, deadline - monotonic())))
            delay = min(300, delay * 2)
        return "github"
    except FAILURES:
        return "github"


def wait_group(args):
    import ci_ui_tests as producer
    ctx = producer.context()
    directory = args.output_dir.resolve()
    require(producer.ROOT != directory and producer.ROOT not in directory.parents, "group wait output must be outside checkout")
    directory.mkdir(parents=True, exist_ok=False)
    planned = decode(args.selection_path.read_text())
    require(planned["identity"] == ctx["identity"] and args.group in groups.GROUPS, "group selection identity differs")
    summary = infrastructure(ctx, "ui-cloud-wait-" + args.group, producer.file_hash(producer.ROOT / producer.MANIFEST_PATH),
                             packing=planned.get("packing"))
    started, code = time.monotonic(), 1
    try:
        producer.workspace_preflight(producer.ROOT)
        wait = producer.ArchiveWait(args.timeout_minutes * 60)
        api = RetryingGitHub(ctx["identity"]["repository"], os.environ["GH_TOKEN"], wait.deadline, wait_out_rate_limits=True)
        enabled = bool(planned["platform_shards"][args.group]) and planned.get("run_ui", True)
        # Main push selection explicitly records deferral/reuse before this wait.
        if ctx["identity"]["event"] == "push" and args.defer_main_ui:
            enabled = False
        decision = wait_cloud_group(ctx, api, args.group) if enabled else "github"
        producer.output("routed", str(decision == "routed").lower())
        producer.output("run_github", str(enabled and decision != "routed").lower())
        producer.output("selection_artifact", f"ui-group-{ctx['run']['id']}-{ctx['run']['attempt']}-{args.group}")
        if enabled and decision != "routed":
            selection = producer.select_archive(api, ctx["identity"], platform_name=args.group, wait=wait,
                record_refusals=lambda rows: producer.write_json(directory / "archive-refusals.json", rows))
            selection.update(timeout_minutes=args.timeout_minutes, selected_keys=planned["keys"][args.group])
            if planned.get("packing"):
                selection["packing"] = planned["packing"]
            for key in ("artifact_id", "producer_run_id", "producer_attempt"):
                producer.output(key, selection[key])
            producer.write_json(directory / ("archive-selection-" + args.group + ".json"), selection)
        producer.write_json(directory / "group-selection.json", {"schema_version": 2, "identity": ctx["identity"],
            "group": args.group, "decision": decision, "run_github": enabled and decision != "routed"})
        summary["status"], code = "passed", 0
    except FAILURES:
        summary["infrastructure"].append({"code": "ui-group-selection-failed", "message": "No complete Cloud proof or matching GitHub archive"})
    finally:
        summary["population"]["observed"] = [observation(summary["population"]["declared"][0], "passed" if code == 0 else "failed",
            time.monotonic() - started, reason=None if code == 0 else "UI group selection failed", exit_code=code)]
        write_summary(summary, directory)
    return code
