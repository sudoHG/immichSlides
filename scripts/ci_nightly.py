#!/usr/bin/env python3
"""Versioned strict matrix planning and fail-closed skeleton nightly aggregation."""

from __future__ import annotations

import argparse
import json
import math
import os
import time
from collections import Counter, defaultdict
from pathlib import Path

from ci_build_archive import file_hash, workspace_preflight
from ci_summary import (ContractError, decode, fields, identity_key, integer, observation,
                        parse_identity, parse_summary, require, string, test_identity)
from ci_verdict import tokens
from run_host_checks import run_identity, source_metadata

ROOT = Path(__file__).resolve().parent.parent
MATRIX = ROOT / "scripts/nightly-matrix.json"
POLICY = ROOT / "scripts/nightly-policy.json"
WORKFLOW = ".github/workflows/ci-nightly.yml"
CASE_FIELDS = {"platform", "device", "configuration", "suite", "scenario", "fixture"}
UNBUILT_TIERS = ("ui", "offline-performance", "live", "live-performance")


def contract_population():
    """Enumerate only combinations supported by the current runner contracts."""
    from run_strict_e2e import CommandError, resolve_suite_selector
    from strict_e2e_build import build_settings
    from strict_e2e_p2_contract import P2_CASES
    from strict_e2e_runner_support import (DUAL_SERVER_SUITES, RUNNER_SCENARIOS, RUNNER_SUITES,
                                           validate_suite_fixture, validate_suite_scenario)
    cases, exclusions = [], []
    for device, platform in (("iphone", "ios"), ("ipad", "ios"), ("tv", "tvos")):
        for suite in sorted(set(RUNNER_SUITES)):
            try:
                resolve_suite_selector(platform, suite)
            except CommandError:
                continue
            if suite in P2_CASES and device not in P2_CASES[suite].devices:
                continue
            for scenario in RUNNER_SCENARIOS:
                try:
                    validate_suite_scenario(suite, scenario)
                except CommandError:
                    continue
                configuration = build_settings(platform, suite)[2]
                for fixture in ("a", "b"):
                    case = dict(platform=platform, device=device, configuration=configuration,
                                suite=suite, scenario=scenario, fixture=fixture)
                    try:
                        validate_suite_fixture(suite, fixture)
                        if suite in DUAL_SERVER_SUITES and fixture != "a":
                            raise CommandError("Dual-server suites must start from fixture A.")
                    except CommandError as error:
                        exclusions.append({"case": case, "reason": str(error)})
                        continue
                    cases.append(case)
    return cases, exclusions


def case_identity(case):
    return test_identity("strict", case["suite"], **{key: case[key] for key in CASE_FIELDS - {"platform"}})


def parse_manifest(raw):
    manifest = decode(raw)
    fields(manifest, {"schema_version", "cases", "exclusions", "runner_exclusions", "informational", "shard_size"}, "nightly matrix")
    require(type(manifest["schema_version"]) is int and manifest["schema_version"] == 1, "unsupported matrix version")
    integer(manifest["shard_size"], 1, "shard size")
    require(manifest["shard_size"] <= 6, "shards exceed the bounded job budget")
    for name in ("cases", "exclusions", "runner_exclusions", "informational"):
        require(isinstance(manifest[name], list), name + " must be an array")
    for case in manifest["cases"]:
        fields(case, CASE_FIELDS, "matrix case")
        for value in case.values():
            string(value, "case dimension")
    for entry in manifest["exclusions"]:
        fields(entry, {"case", "reason"}, "matrix exclusion")
        fields(entry["case"], CASE_FIELDS, "excluded case")
        string(entry["reason"], "exclusion reason")
    expected, exclusions = contract_population()
    require(Counter(identity_key(case) for case in manifest["cases"]) == Counter(identity_key(case) for case in expected),
            "matrix does not equal current runner population (missing, duplicate or unsupported case)")
    require(Counter(identity_key(entry) for entry in manifest["exclusions"]) == Counter(identity_key(entry) for entry in exclusions),
            "matrix exclusions do not equal unsupported fixture combinations")
    runners = []
    for entry in manifest["runner_exclusions"]:
        fields(entry, {"runner", "reason"}, "runner exclusion")
        string(entry["reason"], "runner exclusion reason")
        runners.append(entry["runner"])
    require(sorted(runners) == ["run_access_lifecycle_ios.py", "run_access_lifecycle_tvos.py"],
            "unconverted standalone runners must be excluded explicitly")
    for entry in manifest["informational"]:
        fields(entry, {"suite", "reason"}, "informational suite")
        string(entry["reason"], "informational reason")
    require([entry["suite"] for entry in manifest["informational"]] == ["filter-vision"],
            "only the existing Vision gap is informational")
    return manifest


def shards(manifest):
    from strict_e2e_build import build_settings
    groups = defaultdict(list)
    for case in manifest["cases"]:
        scheme, _, configuration = build_settings(case["platform"], case["suite"], case["configuration"])
        groups[(case["device"], case["platform"], scheme, configuration)].append(case)
    result = []
    for (device, platform, scheme, configuration), cases in sorted(groups.items()):
        for offset in range(0, len(cases), manifest["shard_size"]):
            number = offset // manifest["shard_size"]
            result.append({"id": f"{device}-{scheme}-{configuration.lower()}-{number}",
                           "device": device, "platform": platform,
                           "cases": cases[offset:offset + manifest["shard_size"]]})
    return result


def matrix_equality(scheduled, observed):
    wanted = tokens(scheduled)
    executed = [identity_key(entry["identity"]) for entry in observed if entry["outcome"] != "not-run"]
    counts = Counter(executed)
    return {"equal": bool(wanted) and set(wanted) == set(counts) and all(n == 1 for n in counts.values()),
            "scheduled": len(wanted), "executed": len(executed),
            "missing": [wanted[key] for key in sorted(set(wanted) - set(counts))],
            "unexpected": sorted(set(counts) - set(wanted)),
            "duplicates": sorted(key for key, count in counts.items() if count != 1)}


def aggregate_nightly(scheduled, summaries, *, live_in_scope, informational=()):
    from strict_e2e_p2_contract import P2_CASES
    result = {"schema_version": 1, "status": "failed", "release_eligible": False,
              "release_ineligible_reasons": ["skeleton nightly: mandatory tiers are not built"],
              "tiers": {"strict": "failed", **{tier: "not yet in scope" for tier in UNBUILT_TIERS}},
              "matrix": {}, "observed": [], "needs_human_review": [], "informational": [], "errors": []}
    try:
        require(type(live_in_scope) is bool, "live scope must be explicit")
        for raw in summaries:
            summary = parse_summary(raw)
            result["observed"].extend(summary["population"]["observed"])
            if summary["infrastructure"]:
                result["errors"].append("producer infrastructure failure: " + str(summary["infrastructure"]))
            if summary["status"] == "failed":
                result["errors"].append("producer failed: " + str(summary["run"]["shard"]))
            if summary["status"] == "unverified" and not any(
                    entry["outcome"] == "needs-human-review" and entry["identity"]["dimensions"]["suite"] in P2_CASES
                    for entry in summary["population"]["observed"]):
                result["errors"].append("unverified producer has no passing P2 contract")
        result["matrix"] = matrix_equality(scheduled, result["observed"])
        if not result["matrix"]["equal"]:
            result["errors"].append("executed matrix differs from scheduled matrix")
        for entry in result["observed"]:
            suite = entry["identity"]["dimensions"]["suite"]
            if suite in informational:
                result["informational"].append(entry)
            elif entry["outcome"] == "needs-human-review" and suite in P2_CASES:
                result["needs_human_review"].append(entry["identity"])
            elif entry["outcome"] not in {"passed", "flaky-passed"}:
                result["errors"].append(entry["outcome"] + ": " + identity_key(entry["identity"]))
        if live_in_scope:
            result["tiers"]["live"] = "failed"
            result["errors"].append("live tier is in scope but no live runner/results are built")
        result["status"] = "failed" if result["errors"] else "passed"
        result["tiers"]["strict"] = result["status"]
    except (ContractError, TypeError, KeyError, ValueError) as error:
        result["errors"].append("invalid nightly evidence: " + str(error))
    return result


def validate_shard(raw, identity, run, hashes, expected):
    summary = parse_summary(raw)
    require(summary["identity"] == identity, "shard tested a different tree/commit/event")
    require(summary["run"] == run, "wrong shard, run or attempt")
    require(summary["hashes"] == hashes, "shard manifest/policy mismatch")
    if identity["event"] != "local":
        require(summary["source"]["workflow_path"] == WORKFLOW and summary["source"]["fork_originated"] is False,
                "unexpected shard workflow/source")
    wanted = set(tokens(expected))
    for name in ("declared", "compiled"):
        require(set(tokens(summary["population"][name])) == wanted, name + " matrix differs from scheduled shard")
    require(not summary["population"]["deselected"], "strict shard must not deselect cases")
    return summary


def read_policy():
    policy = decode(POLICY.read_text())
    fields(policy, {"schema_version", "live_tier_in_scope", "built_tiers"}, "nightly policy")
    require(type(policy["schema_version"]) is int and policy["schema_version"] == 1, "unsupported nightly policy")
    require(type(policy["live_tier_in_scope"]) is bool, "live scope must be boolean")
    require(policy["built_tiers"] == ["strict"], "skeleton only implements strict")
    return policy


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "aggregate"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--records-dir", type=Path)
    parser.add_argument("--matrix-job-result", choices=("success", "failure", "cancelled", "skipped"))
    args = parser.parse_args(argv)
    output = args.output_dir.resolve()
    require(output != ROOT and ROOT not in output.parents and not os.path.lexists(output), "output must be fresh and outside checkout")
    output.mkdir(parents=True)
    workspace_preflight(ROOT)
    identity = run_identity(os.environ, ci=os.environ.get("GITHUB_ACTIONS") == "true")
    workflow, fork = source_metadata(identity, os.environ, WORKFLOW if identity["event"] != "local" else None)
    manifest = parse_manifest(MATRIX.read_text())
    policy = read_policy()
    hashes = {"manifests": {"nightly-matrix": file_hash(MATRIX)}, "policies": {"nightly": file_hash(POLICY)}}
    run = {"id": os.environ.get("GITHUB_RUN_ID"), "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1"))}
    source = {"repository": identity["repository"], "workflow_path": workflow, "event": identity["event"],
              "fork_originated": fork, "ci_changing": None, "approval_based": False}
    planned = shards(manifest)
    if args.command == "plan":
        plan = {"schema_version": 1, "identity": identity, "source": source, "run": run, "hashes": hashes,
                "shards": planned, "max_parallel": 2, "started_epoch": time.time()}
        write_json(output / "plan.json", plan)
        matrix = {"include": [{key: shard[key] for key in ("id", "platform", "device")} for shard in planned]}
        print(json.dumps(matrix, separators=(",", ":")))
        return 0
    require(args.plan is not None and args.records_dir is not None, "aggregate needs plan and records")
    summaries, errors, traces = [], [], []
    try:
        plan = decode(args.plan.read_text())
        require(plan["identity"] == identity and plan["run"] == run and plan["hashes"] == hashes
                and plan["shards"] == planned, "plan differs from workflow checkout, run or matrix")
        require(type(plan["started_epoch"]) in (int, float) and math.isfinite(plan["started_epoch"])
                and plan["started_epoch"] <= time.time() and plan["max_parallel"] == 2, "invalid plan capacity")
    except (ValueError, OSError, KeyError) as error:
        errors.append("invalid or missing scheduling record: " + str(error))
        plan = {"started_epoch": time.time(), "max_parallel": 2}
    scheduled = [case_identity(case) for shard in planned for case in shard["cases"]]
    expected_artifacts = {f"nightly-strict-{shard['id']}-{run['id']}-{run['attempt']}" for shard in planned}
    actual_artifacts = {path.name for path in args.records_dir.iterdir()} if args.records_dir.is_dir() else set()
    if actual_artifacts - expected_artifacts:
        errors.append("unexpected shard artifacts: " + str(sorted(actual_artifacts - expected_artifacts)))
    for shard in planned:
        paths = list(args.records_dir.glob(f"nightly-strict-{shard['id']}-{run['id']}-{run['attempt']}/summary.json"))
        if len(paths) != 1:
            errors.append("missing shard artifact: " + shard["id"])
            continue
        expected = [case_identity(case) for case in shard["cases"]]
        try:
            summaries.append(validate_shard(paths[0].read_text(), identity,
                {**run, "tier": "strict", "job": "nightly-strict", "shard": shard["id"]}, hashes, expected))
            trace = decode((paths[0].parent / "trace.json").read_text())
            require(all(type(trace[key]) in (int, float) and math.isfinite(trace[key]) for key in ("started_epoch", "finished_epoch")),
                    "invalid shard clock")
            require(trace["finished_epoch"] >= trace["started_epoch"], "shard ended before it started")
            traces.append({"shard": shard["id"], "started_epoch": trace["started_epoch"], "finished_epoch": trace["finished_epoch"]})
        except (ValueError, OSError, KeyError) as error:
            errors.append(shard["id"] + ": " + str(error))
    result = aggregate_nightly(scheduled, summaries, live_in_scope=policy["live_tier_in_scope"],
                               informational=[item["suite"] for item in manifest["informational"]])
    if args.matrix_job_result != "success":
        errors.append("matrix jobs did not all succeed: " + str(args.matrix_job_result))
    if errors:
        result["errors"].extend(errors)
        result["status"] = result["tiers"]["strict"] = "failed"
    observed_keys = {identity_key(entry["identity"]) for entry in result["observed"]}
    result["observed"].extend(observation(item, "not-run", 0, reason="missing or invalid shard evidence", exit_code=None)
                              for item in scheduled if identity_key(item) not in observed_keys)
    result.update(identity=identity, source=source, run=run, hashes=hashes, live_tier_in_scope=policy["live_tier_in_scope"],
                  exclusions=manifest["exclusions"], runner_exclusions=manifest["runner_exclusions"])
    result["capacity"] = {"max_parallel": plan["max_parallel"], "shards": len(planned),
                          "minimum_shard_waves": math.ceil(len(planned) / plan["max_parallel"]),
                          "shard_intervals": traces,
                          "wall_seconds": time.time() - plan["started_epoch"]}
    intervals = sorted(traces, key=lambda item: item["started_epoch"])
    result["capacity"]["start_order_waves"] = [[item["shard"] for item in intervals[index:index + 2]]
                                               for index in range(0, len(intervals), 2)]
    result["rollup_entry"] = {"repository": source["repository"], "workflow_path": WORKFLOW,
                             "event": source["event"], "fork_originated": fork, "ci_changing": None,
                             "approval_based": False, "identity": identity, "run": run,
                             "status": result["status"], "release_eligible": False,
                             "release_ineligible_reasons": result["release_ineligible_reasons"], "hashes": hashes}
    write_json(output / "nightly.json", result)
    lines = [f"# Nightly: {result['status']}", "", "Release eligible: **no — skeleton nightly**", "",
             f"Matrix equality: {result['matrix'].get('equal', False)}; scheduled {len(scheduled)}, executed {result['matrix'].get('executed', 0)}.",
             f"Shards: {len(planned)}; max-parallel: 2; minimum waves: {result['capacity']['minimum_shard_waves']}; wall: {result['capacity']['wall_seconds']:.1f}s.",
             "Queue delay and final job teardown are reported separately by the Actions job timestamps.", "", "| Tier | Status |", "|---|---|"]
    lines.extend(f"| {tier} | {status} |" for tier, status in result["tiers"].items())
    lines.extend(["", f"P2 contracts needing human review: {len(result['needs_human_review'])}.",
                  f"Informational Vision outcomes: {len(result['informational'])}.", "", "| Case | Outcome |", "|---|---|"])
    lines.extend(f"| {identity_key(item['identity'])} | {item['outcome']} |" for item in result["observed"])
    lines.extend(["", *result["errors"]])
    (output / "nightly.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:14]))
    return 1 if result["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
