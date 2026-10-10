#!/usr/bin/env python3
"""Decide whether a scheduled nightly has anything new to verify.

Runs on Linux from the scheduled main commit with the GitHub API only; the
workflow never runs it for another event. The baseline is the newest scheduled
nightly on main that completed with a verified real result (pass or fail).
Nights skipped by this check are passed over; the first cancelled, unfinished,
infrastructure-incomplete or unverifiable night ends the search. The nightly is
skipped when main is still the baseline commit or when every change since it is
classified as not affecting the app or its tests by the baseline's own
classification policy and reader. Any doubt means the nightly runs.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from ci_publish_git import base_reader, git, read_blob, revision_modules
from ci_summary import ContractError, require, sha

NIGHTLY_WORKFLOW_FILE = "ci-nightly.yml"
RECORD_FILE = "nightly-change.json"
NO_CHANGE_REASON = "no change since the last nightly"
SKIP_REASONS = {"unchanged", "non-affecting-changes"}
RUN_REASONS = {"event-not-schedule", "no-baseline", "baseline-not-ancestor", "changes-affect-app-or-ci",
               "decision-unavailable"}
REAL_RESULT_CONCLUSIONS = {"success", "failure"}
INFRASTRUCTURE_ERROR_PREFIXES = ("missing shard", "invalid or missing", "producer infrastructure", "single-shard")
EXECUTION_ARTIFACT_PREFIXES = ("nightly-aggregate-", "nightly-strict-", "nightly-ui-aggregate-")
RECENT_RUNS = 20
API_DEADLINE_SECONDS = 120
AFFECTED_PATH_SAMPLE = 10


def artifact_name(run_id, attempt):
    return f"nightly-change-{run_id}-{attempt}"


def ui_tier_complete(ui):
    """The UI tier ran every planned shard and sample; only genuine test failures remain in its verdict."""
    from ci_report import FAILURES
    from ci_summary import identity_key
    from ci_verdict import identity_label
    try:
        verdict, planned_shards = ui["verdict"], ui["plan"]["shards"]
        matrix = verdict["matrix"]
        if (matrix["equal"] is not True or matrix["missing"] or matrix["unexpected"] or matrix["duplicates"]
                or len(verdict["shards"]) != len(planned_shards)):
            return False
        shard_prefixes = tuple(item["device"] + "/" + item["shard"] + ": " for item in planned_shards)
        if any(not error.startswith(shard_prefixes + ("nightly UI matrix jobs did not all succeed: ",)) for error in verdict["errors"]):
            return False
        failed_somewhere = False
        for shard, planned in zip(verdict["shards"], planned_shards):
            if (shard["device"], shard["shard"]) != (planned["device"], planned["shard"]):
                return False
            declared = {identity_key(item) for item in planned["declared"]}
            failures = [item for item in verdict["observed"]
                        if identity_key(item["identity"]) in declared and item["outcome"] in FAILURES]
            failed_somewhere = failed_somewhere or bool(failures)
            expected = {item["outcome"] + ": " + identity_label(item["identity"]) for item in failures}
            if failures:
                expected.add("producer status is failed")
            if any(error not in expected for error in shard["verdict"]["errors"]):
                return False
        if {item["shard"] for item in ui["capacity"]["shard_intervals"]} != {
                item["device"] + "/" + item["shard"] for item in planned_shards}:
            return False
        return ui["matrix_job_result"] == "success" or failed_somewhere
    except (KeyError, TypeError, ValueError, AttributeError):
        return False


def run_evidence(api, run):
    """'real' for a verified executed night, 'skipped' for a verified skipped night, None when unsure."""
    from ci_publish import json_member
    attempt, run_id = run["run_attempt"], run["id"]
    suffix = f"-{run_id}-{attempt}"
    artifacts = api.pages(f"actions/runs/{run_id}/artifacts", "artifacts")
    executed = [item for item in artifacts if item["name"].startswith(EXECUTION_ARTIFACT_PREFIXES) and item["name"].endswith(suffix)]
    records = [item for item in artifacts if item["name"] == artifact_name(run_id, attempt)]
    if records and not executed:
        if len(records) != 1 or records[0]["expired"] or run.get("conclusion") != "success":
            return None
        record = validate_record(json_member(api, records[0], RECORD_FILE), repository=api.repository, run_id=run_id,
                                 attempt=attempt, event=run["event"], head_sha=run["head_sha"])
        return "skipped" if record["decision"] == "skip" else None
    aggregates = [item for item in executed if item["name"] == f"nightly-aggregate{suffix}"]
    if len(aggregates) != 1 or aggregates[0]["expired"] or run.get("conclusion") not in REAL_RESULT_CONCLUSIONS:
        return None
    raw = json_member(api, aggregates[0], "nightly.json")
    identity = raw.get("identity")
    matrix = raw.get("matrix")
    if (raw.get("run") != {"id": str(run_id), "attempt": attempt} or raw.get("status") not in {"passed", "failed"}
            or not isinstance(identity, dict) or identity.get("commit_sha") != run["head_sha"]
            or not isinstance(matrix, dict) or matrix.get("equal") is not True or not isinstance(raw.get("errors"), list)
            or any(not isinstance(error, str) or error.startswith(INFRASTRUCTURE_ERROR_PREFIXES) for error in raw["errors"])
            or (raw.get("schema_version") == 2) != ("ui" in raw) or raw.get("schema_version") not in {1, 2}
            or ("ui" in raw and not ui_tier_complete(raw["ui"]))):
        return None
    return "real"


def pick_baseline(runs, repository, current_run_id, evidence):
    """Newest verified real-result scheduled main night; skipped nights are passed over and doubt ends the search."""
    candidates = sorted((run for run in runs
                         if run.get("event") == "schedule" and run.get("head_branch") == "main"
                         and run.get("id") != current_run_id
                         and (run.get("head_repository") or {}).get("full_name") == repository),
                        key=lambda run: (run["created_at"], run["id"]), reverse=True)
    for run in candidates:
        if run.get("status") != "completed" or run.get("conclusion") not in REAL_RESULT_CONCLUSIONS:
            return None
        verdict = evidence(run)
        if verdict == "skipped":
            continue
        if verdict != "real":
            return None
        sha(run["head_sha"])
        require(type(run["id"]) is int and run["id"] > 0, "invalid baseline run")
        return {"run_id": run["id"], "sha": run["head_sha"], "created_at": run["created_at"]}
    return None


def decide(*, event, head_sha, runs, repository, current_run_id, is_ancestor, classify, evidence):
    if event != "schedule":
        return {"decision": "run", "reason": "event-not-schedule", "baseline": None}
    baseline = pick_baseline(runs, repository, current_run_id, evidence)
    if baseline is None:
        return {"decision": "run", "reason": "no-baseline", "baseline": None}
    result = {"baseline": baseline}
    if baseline["sha"] == head_sha:
        return {**result, "decision": "skip", "reason": "unchanged"}
    if not is_ancestor(baseline["sha"], head_sha):
        return {**result, "decision": "run", "reason": "baseline-not-ancestor"}
    classification = classify(baseline["sha"], head_sha)
    affected = classification["app_affected"] or classification["ci_changing"]
    result["changes"] = {"paths": classification["paths"],
                         "affected": sorted(set(classification["affected_paths"] + classification["ci_paths"]))[:AFFECTED_PATH_SAMPLE]}
    return {**result, "decision": "run" if affected else "skip",
            "reason": "changes-affect-app-or-ci" if affected else "non-affecting-changes"}


def git_is_ancestor(ancestor, descendant):
    return subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, descendant],
                          capture_output=True, timeout=30).returncode == 0


def classify_between(baseline_sha, head_sha):
    """The baseline's reader and policy judge the diff, so the diff cannot weaken its own classification."""
    paths = [path for path in git("diff", "-z", "--name-only", "--no-renames", baseline_sha + ".." + head_sha).split("\0") if path]
    members = {path for revision in (baseline_sha, head_sha)
               for path in git("ls-tree", "--name-only", "-r", revision).splitlines()
               if path.startswith("immichSlides/")}
    classification = base_reader(revision_modules(baseline_sha), {
        "operation": "classify", "paths": paths or ["__unknown_empty_diff__"],
        "classification_policy": json.loads(read_blob(baseline_sha, "scripts/ci-classification.json")),
        "build_target_paths": sorted(members)})
    require(type(classification["app_affected"]) is bool and type(classification["ci_changing"]) is bool,
            "classification must contain explicit booleans")
    return {**classification, "paths": len(paths)}


def scheduled_history(repository, token):
    """Recent scheduled main runs plus the evidence reader that shares their rate-limit budget."""
    from ci_publish import RateLimitWaitingGitHub
    from urllib.parse import urlencode
    deadline = time.monotonic() + API_DEADLINE_SECONDS
    api = RateLimitWaitingGitHub(repository, token, lambda: deadline - time.monotonic())
    query = urlencode({"event": "schedule", "branch": "main", "per_page": RECENT_RUNS})
    runs = api.repo(f"actions/workflows/{NIGHTLY_WORKFLOW_FILE}/runs?{query}")["workflow_runs"]
    return runs, lambda run: run_evidence(api, run)


def make_record(result, *, event, repository, head_sha, run_id, attempt):
    record = {"schema_version": 1, "decision": result["decision"], "reason": result["reason"], "event": event,
              "repository": repository, "head_sha": head_sha, "run": {"id": str(run_id), "attempt": attempt},
              "baseline": result.get("baseline")}
    if "changes" in result:
        record["changes"] = result["changes"]
    return record


def validate_record(raw, *, repository, run_id, attempt, event, head_sha):
    """Reporter-side proof that a skip record belongs to this exact run attempt and source commit."""
    require(isinstance(raw, dict) and raw.get("schema_version") == 1, "unsupported nightly change record")
    require(raw.get("decision") in {"skip", "run"}, "invalid nightly change decision")
    require(raw["reason"] in (SKIP_REASONS if raw["decision"] == "skip" else RUN_REASONS), "invalid nightly change reason")
    require(raw.get("repository") == repository and raw.get("event") == event and raw.get("head_sha") == head_sha
            and raw.get("run") == {"id": str(run_id), "attempt": attempt}, "nightly change record mismatch")
    if raw["decision"] == "skip":
        require(event == "schedule", "only a scheduled nightly can be skipped")
        baseline = raw.get("baseline")
        require(isinstance(baseline, dict) and set(baseline) == {"run_id", "sha", "created_at"}
                and type(baseline["run_id"]) is int and baseline["run_id"] > 0 and isinstance(baseline["created_at"], str),
                "skip requires a baseline")
        sha(baseline["sha"])
        require((raw["reason"] == "unchanged") == (baseline["sha"] == head_sha), "skip reason differs from the baseline")
    return raw


def summary_markdown(record):
    lines = ["## Nightly change check", "",
             f"Decision: **{'skip (' + NO_CHANGE_REASON + ')' if record['decision'] == 'skip' else 'run'}**; reason: `{record['reason']}`.",
             f"Source commit: `{record['head_sha']}`; event: `{record['event']}`."]
    baseline = record.get("baseline")
    if baseline:
        lines.append(f"Baseline: nightly run {baseline['run_id']} at `{baseline['sha']}`.")
    changes = record.get("changes")
    if changes:
        lines.append(f"{changes['paths']} paths changed since the baseline; app- or CI-affecting examples: "
                     + (", ".join(f"`{path}`" for path in changes["affected"]) or "none") + ".")
    if record["decision"] == "skip":
        lines += ["", "No macOS job runs. This records no evidence for the source commit; it is not a pass."]
    return "\n".join(lines) + "\n"


def github_output(environment, name, value):
    if environment.get("GITHUB_OUTPUT"):
        with open(environment["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def evaluate(environment, *, event, repository, head_sha):
    """Fail open: an unavailable decision always runs the nightly."""
    try:
        sha(head_sha)
        runs, evidence = (scheduled_history(repository, environment.get("GH_TOKEN") or environment.get("CI_REPORT_TOKEN"))
                          if event == "schedule" else ([], None))
        return decide(event=event, head_sha=head_sha, runs=runs, repository=repository,
                      current_run_id=int(environment.get("GITHUB_RUN_ID", "0")),
                      is_ancestor=git_is_ancestor, classify=classify_between, evidence=evidence)
    except Exception:
        # Do not echo API or Git details into public records.
        print("Nightly change decision unavailable; the nightly runs", file=sys.stderr)
        return {"decision": "run", "reason": "decision-unavailable", "baseline": None}


def main(argv=None, environment=None):
    environment = os.environ if environment is None else environment
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, help="fresh directory for the change record and summary")
    parser.add_argument("--dry-run", action="store_true",
                        help="read the real run history and print the decision; write nothing and set no workflow output")
    parser.add_argument("--event", help="event to simulate in a dry run (default: schedule)")
    parser.add_argument("--head-sha", help="commit to simulate as the scheduled source in a dry run (default: HEAD)")
    parser.add_argument("--repository", help="owner/name; defaults to GITHUB_REPOSITORY")
    args = parser.parse_args(argv)
    if args.dry_run:
        event = args.event or "schedule"
        head_sha = args.head_sha or git("rev-parse", "HEAD")
    else:
        require(args.output_dir is not None, "--output-dir is required outside a dry run")
        require(args.event is None and args.head_sha is None, "event and commit overrides are dry-run only")
        event, head_sha = environment.get("GITHUB_EVENT_NAME", ""), environment.get("GITHUB_SHA", "")
    repository = args.repository or environment.get("GITHUB_REPOSITORY", "")
    require(repository, "a repository is required")
    run_id, attempt = environment.get("GITHUB_RUN_ID", "0"), int(environment.get("GITHUB_RUN_ATTEMPT", "1"))
    result = evaluate(environment, event=event, repository=repository, head_sha=head_sha)
    record = make_record(result, event=event, repository=repository, head_sha=head_sha, run_id=run_id, attempt=attempt)
    print(summary_markdown(record))
    if args.dry_run:
        print(json.dumps(record, indent=2, sort_keys=True))
        return 0
    output = args.output_dir.resolve()
    require(not output.exists(), "change records must be fresh")
    output.mkdir(parents=True)
    (output / RECORD_FILE).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (output / "nightly-change.md").write_text(summary_markdown(record), encoding="utf-8")
    github_output(environment, "skip", "true" if record["decision"] == "skip" else "false")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ContractError as error:
        print(f"Nightly change check refused: {error}", file=sys.stderr)
        raise SystemExit(1)
