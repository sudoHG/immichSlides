"""Trusted UI verdict receipts and conservative identical-tree main-push reuse."""

from __future__ import annotations

import hashlib
import re
import subprocess
import zipfile

import yaml

from ci_publish_git import git, read_blob, workflow_contract
from ci_summary import ContractError, decode, fields, parse_identity, parse_summary, require

UI_WORKFLOW = ".github/workflows/ci-ui.yml"
PUBLISH_WORKFLOW = ".github/workflows/ci-publish.yml"
INPUT_PATHS = ("scripts/ci-ui-shards.json", "immichSlides-iOS.xctestplan", "immichSlides-tvOS.xctestplan",
               "scripts/ci-test-policy.json", "scripts/ci-known-flaky.json", "scripts/ci-classification.json",
               "scripts/ci-pins.json", UI_WORKFLOW)


def reuse_inputs(revision):
    return {path: hashlib.sha256(read_blob(revision, path).encode()).hexdigest() for path in INPUT_PATHS}


def device_shards(source, run):
    _, _, _, metadata = workflow_contract(source, run, metadata=True)
    return sorted(meta["device"] + "/" + meta["shard"] for meta in metadata.values() if meta["tier"] == "ui")


def validate_reuse(receipt, push, inputs, shards, pins, upstream, merged_pr):
    fields(receipt, {"schema_version", "identity", "source", "status", "inputs", "device_shards", "toolchains"},
           "UI verdict receipt")
    require(type(receipt["schema_version"]) is int and receipt["schema_version"] == 1, "unknown UI reuse receipt version")
    identity = parse_identity(receipt["identity"])
    source = receipt["source"]
    fields(source, {"repository", "workflow_path", "run_id", "attempt", "fork_originated", "ci_changing", "approval_based"},
           "UI verdict source")
    require(push["event"] == "push" and push["ref"] == "refs/heads/main", "reuse is main-push only")
    require(identity["event"] == "pull_request" and identity["repository"] == push["repository"] == source["repository"],
            "reuse requires a same-repository PR verdict")
    require(identity["pull_request"] == merged_pr["number"] and identity["head_sha"] == merged_pr["head"]["sha"],
            "reuse verdict does not match the PR and final head actually merged")
    require(receipt["status"] == "passed" and source["workflow_path"] == UI_WORKFLOW
            and all(source[key] is False for key in ("fork_originated", "ci_changing", "approval_based")),
            "reuse requires a green non-CI-changing verdict without approval")
    require(identity["tree_sha"] == push["tree_sha"] and receipt["inputs"] == inputs, "reuse tree, manifests or policies differ")
    require(shards and receipt["device_shards"] == sorted(shards) and set(receipt["toolchains"]) == set(shards),
            "reuse lacks the complete current device/shard set")
    require(upstream["id"] == source["run_id"] and upstream["run_attempt"] == source["attempt"]
            and upstream["status"] == "completed" and upstream["conclusion"] == "success"
            and upstream["event"] == "pull_request" and upstream["path"] == UI_WORKFLOW
            and upstream["head_sha"] == identity["head_sha"]
            and upstream["repository"]["full_name"] == upstream["head_repository"]["full_name"] == push["repository"],
            "reused producer is stale, rerunning, failed, cancelled or fork-originated")
    for toolchain in receipt["toolchains"].values():
        versions = toolchain["versions"]
        require(versions.get("xcode") == f"{pins['xcode']['version']} ({pins['xcode']['build']})"
                and versions.get("python") == pins["python"]
                and versions.get("pillow") == pins["python_packages"]["Pillow"]
                and isinstance(versions.get("zstd"), str)
                and re.search(r"(?<![\d.])" + re.escape(pins["zstd"]) + r"(?![\d.])", versions["zstd"]),
                "reuse observed toolchain differs from current pins")
    return receipt


def make_verdict(record, run, summaries, evaluation):
    source = evaluation.get("source")
    if (evaluation["state"] != "success" or not source or run["path"] != UI_WORKFLOW
            or record["identity"]["event"] != "pull_request"):
        return None
    ui = [summary for summary in summaries if summary["run"]["tier"] == "ui"]
    if not ui:
        return None
    # Evaluation has already checked every GitHub job and the full admitted
    # declared/compiled/observed union. The receipt is emitted only by main.
    return {"schema_version": 1, "identity": record["identity"], "status": "passed",
            "source": dict(source, ci_changing=record["classification"]["ci_changing"]),
            "inputs": reuse_inputs(record["identity"]["base_sha"]),
            "device_shards": sorted(summary["run"]["job"].removeprefix("ui-") + "/" + summary["run"]["shard"] for summary in ui),
            "toolchains": {summary["run"]["job"].removeprefix("ui-") + "/" + summary["run"]["shard"]: summary["toolchain"] for summary in ui}}


def trusted_uploader(api, artifact, workflow):
    from ci_publish import positive
    run = api.repo(f"actions/runs/{positive(artifact['workflow_run']['id'])}")
    require(run["workflow_id"] == workflow["id"] and run["path"] == PUBLISH_WORKFLOW
            and run["event"] in {"workflow_run", "workflow_dispatch"} and run["head_branch"] == "main"
            and run["repository"]["full_name"] == run["head_repository"]["full_name"] == api.repository,
            "UI verdict artifact was not uploaded by the trusted main publisher")
    require(subprocess.run(["git", "merge-base", "--is-ancestor", run["head_sha"], "FETCH_HEAD"],
                           capture_output=True, timeout=30).returncode == 0, "UI verdict publisher revision is not on main")


def find_reuse(api, push):
    """Missing, malformed, unavailable and obsolete proof always means run UI."""
    from ci_publish import authoritative_run, json_member, verify_workflow
    if push["event"] != "push":
        return None
    try:
        push = parse_identity(push)
        require(push["repository"] == api.repository, "reuse repository differs")
        revision = push["pushed_sha"]
        merged = [pr for pr in api.pages(f"commits/{revision}/pulls")
                  if pr["merge_commit_sha"] == revision and pr.get("merged_at")
                  and pr["base"]["ref"] == "main"
                  and pr["base"]["repo"]["full_name"] == api.repository
                  and pr["head"]["repo"] and pr["head"]["repo"]["full_name"] == api.repository]
        require(len(merged) == 1, "reuse needs exactly one same-repository PR actually merged by this push")
        inputs = reuse_inputs(revision)
        pins = decode(read_blob(revision, "scripts/ci-pins.json"))
        shards = device_shards(read_blob(revision, UI_WORKFLOW), {"id": 1, "run_attempt": 1})
        publisher = api.repo("actions/workflows/ci-publish.yml", missing=True)
        workflow = api.repo("actions/workflows/ci-ui.yml", missing=True)
        if publisher is None or workflow is None:
            return None
        require(publisher["path"] == PUBLISH_WORKFLOW and workflow["path"] == UI_WORKFLOW, "reuse workflow path differs")
        name = "ci-ui-verdict-" + push["tree_sha"]
        artifacts = api.pages("actions/artifacts", "artifacts", name=name)
        if not artifacts:
            return None
        git("fetch", "--no-tags", "origin", "refs/heads/main")
        for artifact in sorted(artifacts, key=lambda item: item["id"], reverse=True):
            if artifact["name"] != name or artifact["expired"]:
                continue
            try:
                trusted_uploader(api, artifact, publisher)
                receipt = json_member(api, artifact, "verdict.json")
                head = receipt["identity"]["head_sha"]
                runs = api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs", head_sha=head, event="pull_request")
                upstream = authoritative_run(runs, head, workflow, api.repository)
                require(upstream is not None, "reused producer is missing")
                verify_workflow(upstream, workflow, api.repository)
                validate_reuse(receipt, push, inputs, shards, pins, upstream, merged[0])
                return dict(receipt, artifact_id=artifact["id"], publisher_run_id=artifact["workflow_run"]["id"])
            except (OSError, ContractError, KeyError, ValueError, TypeError, zipfile.BadZipFile, subprocess.SubprocessError):
                continue
    except (OSError, ContractError, KeyError, ValueError, TypeError, zipfile.BadZipFile, subprocess.SubprocessError):
        return None
    return None


def expand_skipped_ui_matrix(source, run, jobs):
    """Map a real whole-matrix skip to its trusted literal shard population."""
    from check_workflow_policy import WorkflowLoader
    names, _, _, metadata = workflow_contract(source, run, metadata=True)
    actual = {job["name"]: job for job in jobs}
    require(len(actual) == len(jobs), "duplicate reuse jobs")
    if (run["path"] == UI_WORKFLOW and run["event"] == "push" and run["head_branch"] == "main"):
        workflow = yaml.load(source, Loader=WorkflowLoader)
        for key, job in workflow["jobs"].items():
            raw_name = job.get("name", key)
            if not job.get("strategy", {}).get("matrix") or raw_name not in actual or raw_name in names:
                continue
            skipped = actual.pop(raw_name)
            expanded, _, _, evidence = workflow_contract(yaml.safe_dump({"jobs": {key: job}}), run, metadata=True)
            require(skipped["status"] == "completed" and skipped["conclusion"] == "skipped"
                    and expanded and all(meta["tier"] == "ui" for meta in evidence.values())
                    and not set(expanded).intersection(actual), "whole-matrix skip overlaps execution or is invalid")
            # Preserve the one real API job's ID, timestamps and attempt on every
            # logical shard. This mapping never supplies test observations.
            actual.update({name: dict(skipped, name=name, unexpanded_name=raw_name) for name in expanded})
    require(set(actual) == set(names), "required job set mismatch")
    return list(actual.values())


def evaluate_reused_push(api, record, run, jobs, summaries):
    source = record["workflows"][UI_WORKFLOW]["base"]
    jobs = expand_skipped_ui_matrix(source, run, jobs)
    names, _, _, metadata = workflow_contract(source, run, metadata=True)
    require(len(jobs) == len(names) and {job["name"] for job in jobs} == set(names), "reuse job set differs")
    for job in jobs:
        require(job["status"] == "completed" and job["conclusion"] ==
                ("skipped" if metadata[job["name"]]["tier"] == "ui" else "success"), "reuse skipped an infrastructure job or ran an incomplete shard")
    require(len(summaries) == 1, "reuse needs one bound archive-selection summary")
    summary = parse_summary(summaries[0])
    from ci_summary import test_identity
    expected = [test_identity("host", "UI archive selection")]
    require(summary["identity"] == record["identity"] and summary["status"] == "passed" and not summary["infrastructure"]
            and summary["source"]["workflow_path"] == UI_WORKFLOW and summary["source"]["fork_originated"] is False
            and summary["run"]["tier"] == "ui-infrastructure" and summary["run"]["job"] == "ui-archive"
            and summary["run"]["shard"] is None and summary["population"]["declared"] == expected
            and summary["population"]["compiled"] == expected and not summary["population"]["deselected"]
            and len(summary["population"]["observed"]) == 1
            and summary["population"]["observed"][0]["identity"] == expected[0]
            and summary["population"]["observed"][0]["outcome"] == "passed"
            and summary["hashes"]["manifests"].get("ui-shards") == record["ui_inputs"]["base"]["manifest_sha256"],
            "reuse selection evidence is incomplete or invalid")
    receipt = find_reuse(api, record["identity"])
    require(receipt is not None, "skipped UI shards have no complete trusted identical-tree verdict")
    return {"state": "success", "description": "UI reused: complete trusted identical-tree PR verdict",
            "target_url": f"https://github.com/{api.repository}/actions/runs/{receipt['source']['run_id']}",
            "reuse": {"producer_run_id": receipt["source"]["run_id"], "producer_attempt": receipt["source"]["attempt"],
                      "verdict_artifact_id": receipt["artifact_id"], "tree_sha": receipt["identity"]["tree_sha"],
                      **{key: receipt["source"][key] for key in ("approval_based", "fork_originated", "ci_changing")}}}
