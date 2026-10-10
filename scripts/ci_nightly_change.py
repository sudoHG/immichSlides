#!/usr/bin/env python3
"""Decide whether a scheduled nightly has anything new to verify.

Runs on Linux from the checked-out main commit with the GitHub API only. The
baseline is the newest successful scheduled nightly on main. The nightly is
skipped when main is still that commit or when every change since it is
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
RECENT_RUNS = 20
API_DEADLINE_SECONDS = 120
AFFECTED_PATH_SAMPLE = 10


def artifact_name(run_id, attempt):
    return f"nightly-change-{run_id}-{attempt}"


def pick_baseline(runs, repository, current_run_id):
    """Newest successful scheduled main run; a failed or cancelled night never counts as verified."""
    candidates = [run for run in runs
                  if run.get("event") == "schedule" and run.get("head_branch") == "main"
                  and run.get("status") == "completed" and run.get("conclusion") == "success"
                  and run.get("id") != current_run_id
                  and (run.get("head_repository") or {}).get("full_name") == repository]
    if not candidates:
        return None
    newest = max(candidates, key=lambda run: (run["created_at"], run["id"]))
    sha(newest["head_sha"])
    require(type(newest["id"]) is int and newest["id"] > 0, "invalid baseline run")
    return {"run_id": newest["id"], "sha": newest["head_sha"], "created_at": newest["created_at"]}


def decide(*, event, head_sha, runs, repository, current_run_id, is_ancestor, classify):
    if event != "schedule":
        return {"decision": "run", "reason": "event-not-schedule", "baseline": None}
    baseline = pick_baseline(runs, repository, current_run_id)
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


def recent_scheduled_runs(repository, token):
    from ci_publish import RateLimitWaitingGitHub
    from urllib.parse import urlencode
    deadline = time.monotonic() + API_DEADLINE_SECONDS
    api = RateLimitWaitingGitHub(repository, token, lambda: deadline - time.monotonic())
    query = urlencode({"event": "schedule", "branch": "main", "status": "success", "per_page": RECENT_RUNS})
    return api.repo(f"actions/workflows/{NIGHTLY_WORKFLOW_FILE}/runs?{query}")["workflow_runs"]


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
        runs = (recent_scheduled_runs(repository, environment.get("GH_TOKEN") or environment.get("CI_REPORT_TOKEN"))
                if event == "schedule" else [])
        return decide(event=event, head_sha=head_sha, runs=runs, repository=repository,
                      current_run_id=int(environment.get("GITHUB_RUN_ID", "0")),
                      is_ancestor=git_is_ancestor, classify=classify_between)
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
    if not args.dry_run:
        github_output(environment, "run_nightly", "true")
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
    github_output(environment, "run_nightly", "false" if record["decision"] == "skip" else "true")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ContractError as error:
        print(f"Nightly change check refused: {error}", file=sys.stderr)
        raise SystemExit(1)
