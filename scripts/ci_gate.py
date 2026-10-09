#!/usr/bin/env python3
"""Classify gate PR changes with the isolated base reader before scheduling builds."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import sys
import time
from pathlib import Path

from ci_publish_git import base_reader, git, read_blob, revision_modules
from ci_summary import ContractError, observation, require, test_identity, write_summary
from run_host_checks import REPO_ROOT, run_identity, source_metadata

WORKFLOW = ".github/workflows/ci-gate.yml"


def classify(identity):
    # Main still runs every gate job, including on an empty or unavailable diff.
    if identity["event"] != "pull_request":
        return {"app_affected": True, "ci_changing": False,
                "affected_paths": ["__main_gate__"], "ci_paths": []}
    base = identity["base_sha"]
    paths = git("diff", "--name-only", "--no-renames", base + "..." + identity["head_sha"]).splitlines()
    members = {path for revision in (base, identity["merge_sha"])
               for path in git("ls-tree", "--name-only", "-r", revision).splitlines()
               if path.startswith("immichSlides/")}
    return base_reader(revision_modules(base), {
        "operation": "classify", "paths": paths or ["__unknown_empty_diff__"],
        "classification_policy": json.loads(read_blob(base, "scripts/ci-classification.json")),
        "build_target_paths": sorted(members)})


def output(name, value):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    command = subparsers.add_parser("classify")
    command.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    output("run_macos", "true")
    summary = None
    try:
        records = args.output_dir.resolve()
        require(records != REPO_ROOT and REPO_ROOT not in records.parents, "records must be outside the repository")
        require(not records.exists(), "classification records must be fresh")
        records.mkdir(parents=True)
        identity = run_identity(os.environ, ci=True)
        workflow, fork = source_metadata(identity, os.environ, WORKFLOW)
        step = test_identity("host", "Gate change classification")
        base = identity.get("base_sha", identity.get("pushed_sha"))
        policy = read_blob(base, "scripts/ci-classification.json")
        summary = {"schema_version": 1, "identity": identity,
                   "source": {"repository": identity["repository"], "workflow_path": workflow,
                              "event": identity["event"], "fork_originated": fork, "ci_changing": None},
                   "run": {"id": os.environ["GITHUB_RUN_ID"], "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
                           "tier": "gate-infrastructure", "job": "gate-classification", "shard": None},
                   "hashes": {"manifests": {}, "policies": {"classification": hashlib.sha256(policy.encode()).hexdigest()}},
                   "toolchain": {"versions": {"python": platform.python_version()}, "signing_mode": "not-applicable"},
                   "population": {"declared": [step], "compiled": [step], "observed": [], "deselected": [], "removed_by_pr": []},
                   "infrastructure": [], "status": "failed"}
        write_summary(summary, records)
        started = time.monotonic()
        classification = classify(identity)
        require(type(classification["app_affected"]) is bool and type(classification["ci_changing"]) is bool,
                "classification must contain explicit booleans")
        run_macos = classification["app_affected"] or classification["ci_changing"]
        summary["population"]["observed"] = [observation(step, "passed", time.monotonic() - started)]
        summary["status"] = "passed"
        write_summary(summary, records)
        output("run_macos", str(run_macos).lower())
        print("Gate classification: " + ("run app build/unit jobs" if run_macos else "app build/unit jobs not applicable"))
        return 0
    except Exception:
        # Do not echo candidate Git paths or exception text into public records.
        if summary is not None:
            summary["infrastructure"] = [{"code": "classification-failed", "message": "Gate classification unavailable; app jobs remain required"}]
            write_summary(summary, records)
        print("Gate classification failed; app jobs remain required", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
