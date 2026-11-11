"""Shared readers for complete default-plan nightly fixture UI evidence."""

from __future__ import annotations

import argparse
import copy
import json
import os
import sys
import time
from collections import Counter
from datetime import date
from pathlib import Path

from ci_summary import (ContractError, decode, duration, fields, identity_key, integer,
                        observation, parse_identity, parse_nightly_summary, require, sha, validate_test_identity)
from ci_ui_shards import DEVICES, LABEL
from ci_verdict import evaluate_population, tokens

WORKFLOW = ".github/workflows/ci-nightly.yml"


def read_ui_retry_tests(read):
    """The retry export is optional evidence for a first-attempt failure."""
    try:
        calls = read("retry-invocations.json")["invocations"]
        require(isinstance(calls, list) and 2 <= len(calls) <= 4 and calls[0].get("exit_code") == 65,
                "nightly retry: invalid UI invocation count or initial exit")
    except (ValueError, KeyError, TypeError, AttributeError, OSError):
        return None
    results = []
    for number, call in enumerate(calls[1:], 2):
        try:
            official = read(f"official-tests-attempt-{number}.json")
        except (ValueError, KeyError, TypeError, OSError):
            official = None
        results.append({"official_tests": official, "invocation": call})
    return results


def bind_ui_nightly_retry(entry, observations, official, retries):
    """Match a retry to the original method, filtered invocation, and any official result."""
    from ci_flaky import official_ui_duration

    def checked_duration(node):
        try:
            return official_ui_duration(node)
        except ContractError as error:
            raise ContractError("nightly retry: official UI duration differs or is unknown") from error

    def cases(payload):
        require(isinstance(payload, dict) and isinstance(payload.get("testNodes"), list),
                "nightly retry: missing official UI evidence")
        found = {}
        def visit(node):
            require(isinstance(node, dict), "nightly retry: invalid official UI node")
            if node.get("nodeType") == "Test Case":
                key = str(node.get("nodeIdentifier", "")).removesuffix("()").removeprefix("immichSlidesUITests/")
                require(key not in found, "nightly retry: duplicate official UI method")
                found[key] = node
            for child in node.get("children", []):
                visit(child)
        for node in payload["testNodes"]:
            visit(node)
        return found
    initial = cases(official)
    require(set(initial) == {item["identity"]["key"] for item in observations}
            and all(node.get("result") in {"Passed", "Failed", "Skipped"} for node in initial.values()),
            "nightly retry: incomplete original official UI population")
    failed_count = sum(node.get("result") == "Failed" for node in initial.values())
    require(isinstance(retries, list) and 0 < len(retries) <= 3, "nightly retry: missing filtered UI exports")
    key = entry["identity"]["key"]
    selector = "-only-testing:immichSlidesUITests/" + key
    matched = []
    for raw in retries:
        call = raw.get("invocation", {})
        require(isinstance(call, dict) and isinstance(call.get("command"), list)
                and all(isinstance(arg, str) for arg in call["command"]),
                "nightly retry: missing UI invocation evidence")
        if selector in call["command"]:
            matched.append(raw)
    require(len(matched) == 1, "nightly retry: missing or duplicate filtered UI invocation")
    raw = matched[0]
    call = raw["invocation"]
    first = initial.get(key, {})
    proof = entry.get("nightly_retry")
    retry_failure = entry.get("retry_failure")
    retry_exit = retry_failure["exit_code"] if retry_failure is not None else 0
    require(type(call.get("exit_code")) is int and call["exit_code"] == retry_exit
            and [arg for arg in call["command"] if arg.startswith("-only-testing:")] == [selector],
            "nightly retry: UI retry exit or filtered selection differs")
    require(1 <= failed_count <= 3 and (proof is None or proof["failed_case_count"] == failed_count)
            and first.get("result") == "Failed" and first.get("retry_assertion") is True,
            "nightly retry: official UI assertion or failed count differs")
    require(checked_duration(first) == entry["attempts"][0]["duration_seconds"]
            and entry["attempts"][0]["duration_seconds"] is not None,
            "nightly retry: official UI first duration differs or is unknown")
    if "failure_messages" in entry:
        require(first.get("failure_messages") == entry["failure_messages"],
                "nightly retry: official UI first failure messages differ")
    if retry_failure is not None and retry_failure["outcome"] in {"timed-out", "not-run"}:
        require(call.get("outcome") == retry_failure["outcome"] and call.get("duration_seconds") == retry_failure["duration_seconds"],
                "nightly retry: UI interruption differs from the invocation")
        return
    selected = cases(raw["official_tests"])
    require(set(selected) == {key}, "nightly retry: retry export differs from the selected UI method")
    last = selected[key]
    if retry_failure is None:
        require(last.get("result") == "Passed" and checked_duration(last) == entry["attempts"][1]["duration_seconds"],
                "nightly retry: official UI passing retry differs")
        return
    post_test_crash = retry_failure["outcome"] == "crashed" and retry_exit != 0 and last.get("result") == "Passed"
    if post_test_crash:
        require(call.get("duration_seconds") == retry_failure["duration_seconds"],
                "nightly retry: UI post-test crash duration differs from the invocation")
    else:
        expected = {"failed": "Failed", "crashed": "Failed", "skipped": "Skipped"}[retry_failure["outcome"]]
        require(last.get("result") == expected and checked_duration(last) == retry_failure["duration_seconds"],
                "nightly retry: official UI nonpassing retry differs")
    for field in ("failure_messages", "first_failure"):
        if field in retry_failure:
            require(retry_failure[field] == last.get(field), "nightly retry: official UI retry diagnostics differ")


def parse_ui_plan(raw):
    plan = decode(raw)
    fields(plan, {"schema_version", "identity", "source", "run", "hashes", "shards", "max_parallel", "started_epoch"},
           "nightly UI plan")
    require(type(plan["schema_version"]) is int and plan["schema_version"] == 1, "unsupported nightly UI plan")
    identity = parse_identity(plan["identity"])
    require(identity["event"] in {"schedule", "workflow_dispatch", "local", "pull_request"}, "unsupported nightly UI event")
    fields(plan["source"], {"repository", "workflow_path", "event", "fork_originated", "ci_changing"}, "UI plan source")
    require(plan["source"]["repository"] == identity["repository"] and plan["source"]["event"] == identity["event"]
            and plan["source"]["workflow_path"] == (None if identity["event"] == "local" else WORKFLOW), "UI plan source differs")
    require(type(plan["source"]["fork_originated"]) is bool, "invalid UI plan fork flag")
    fields(plan["run"], {"id", "attempt"}, "UI plan run")
    integer(plan["run"]["attempt"], 1, "UI attempt")
    require(plan["run"]["id"] is None if identity["event"] == "local" else
            isinstance(plan["run"]["id"], str) and plan["run"]["id"].isdigit(), "invalid UI run ID")
    require(type(plan["max_parallel"]) is int and plan["max_parallel"] == 2, "nightly UI concurrency differs")
    duration(plan["started_epoch"])
    fields(plan["hashes"], DEVICES, "UI device hashes")
    for hashes in plan["hashes"].values():
        fields(hashes, {"manifests", "policies"}, "UI hashes")
        for values in hashes.values():
            require(isinstance(values, dict), "invalid UI hash collection")
            for value in values.values():
                sha(value, 64)
    require(isinstance(plan["shards"], list), "UI shards must be an array")
    pairs, declared = [], []
    for shard in plan["shards"]:
        fields(shard, {"device", "shard", "declared"}, "UI shard plan")
        device = shard["device"]
        require(device in DEVICES and isinstance(shard["shard"], str)
                and LABEL.fullmatch(shard["shard"]) is not None, "unsupported UI shard")
        require(isinstance(shard["declared"], list) and shard["declared"], "empty UI shard population")
        for item in shard["declared"]:
            validate_test_identity(item)
            require(item["kind"] == "ui" and item["dimensions"] == {"platform": DEVICES[device], "device": device},
                    "UI population differs from device")
        declared.extend(shard["declared"])
        pairs.append((device, shard["shard"]))
    names = {shard for _, shard in pairs}
    require(0 < len(names) <= 16 and Counter(pairs) == Counter((device, shard) for device in DEVICES for shard in names),
            "nightly UI plan must cover every device/shard exactly once")
    tokens(declared)
    return plan


def judge_ui(raw_plan, raw_summaries, *, policy, registry, evaluated_on, matrix_job_result, official_tests=None, retry_tests=None):
    plan = parse_ui_plan(raw_plan)
    result = {"status": "failed", "matrix": {}, "shards": [], "observed": [], "deselected": [], "errors": []}
    wanted = {(item["device"], item["shard"]): item for item in plan["shards"]}
    summaries = {}
    for raw in raw_summaries:
        try:
            summary = parse_nightly_summary(raw)
            device = summary["run"]["job"].removeprefix("ui-")
            pair = (device, summary["run"]["shard"])
            require(pair in wanted and pair not in summaries, "unexpected or duplicate UI shard")
            require(summary["identity"] == plan["identity"] and summary["source"] == plan["source"]
                    and summary["run"] == {**plan["run"], "tier": "ui", "job": "ui-" + device, "shard": pair[1]}
                    and summary["hashes"] == plan["hashes"][device], "nightly UI shard provenance mismatch")
            if any("environment_limit" in item for item in summary["population"]["observed"]):
                from ci_failure_diagnostics import bind_ui_environment_limits
                bind_ui_environment_limits(summary, (official_tests or {}).get(pair))
            observations = summary["population"]["observed"]
            for index, item in enumerate(observations):
                if "nightly_retry" not in item and "retry_failure" not in item:
                    continue
                original = (official_tests or {}).get(pair)
                try:
                    bind_ui_nightly_retry(item, observations, original, (retry_tests or {}).get(pair))
                except (ValueError, KeyError, TypeError, AttributeError):
                    if "retry_failure" in item:
                        item.pop("retry_failure")
                    elif "nightly_retry_first" in item:
                        from ci_failure_diagnostics import bind_ui_environment_limits
                        first = item["nightly_retry_first"]
                        scoped = {**summary, "population": {**summary["population"], "observed": [first]}}
                        bind_ui_environment_limits(scoped, original)
                        observations[index] = first
                    else:
                        raise
            summaries[pair] = summary
        except (ContractError, KeyError, TypeError, ValueError, AttributeError) as error:
            result["errors"].append("invalid UI shard: " + str(error))
    for pair, planned in wanted.items():
        summary = summaries.get(pair)
        if summary is None:
            verdict = {"status": "failed", "errors": ["missing UI shard"]}
        else:
            verdict = evaluate_population(summary, planned["declared"], policy, environment="fixture",
                                          base_registry=registry, evaluated_on=evaluated_on)
            result["observed"].extend(copy.deepcopy(summary["population"]["observed"]))
            result["deselected"].extend(copy.deepcopy(verdict["deselected"]))
        result["shards"].append({"device": pair[0], "shard": pair[1], "verdict": verdict})
        result["errors"].extend(pair[0] + "/" + pair[1] + ": " + error for error in verdict["errors"])
    scheduled = [item for shard in plan["shards"] for item in shard["declared"]]
    expected = tokens(scheduled)
    executed = Counter(identity_key(item["identity"]) for item in result["observed"]
                       if any(attempt["outcome"] != "not-run" for attempt in item["attempts"]))
    deselected = {identity_key(item["identity"]) for item in result["deselected"]}
    missing = set(expected) - set(executed) - deselected
    result["matrix"] = {"equal": not missing and set(executed) | deselected == set(expected)
                       and not (set(executed) & deselected) and all(count == 1 for count in executed.values()),
                        "scheduled": len(expected), "executed": sum(executed.values()), "deselected": len(deselected),
                        "missing": [expected[key] for key in sorted(missing)],
                        "unexpected": sorted(set(executed) - set(expected)),
                        "duplicates": sorted(key for key, count in executed.items() if count != 1)}
    if not result["matrix"]["equal"]:
        result["errors"].append("nightly UI samples differ from the complete default-plan population")
    if matrix_job_result != "success":
        result["errors"].append("nightly UI matrix jobs did not all succeed: " + str(matrix_job_result))
    present = {identity_key(item["identity"]) for item in result["observed"]}
    result["observed"].extend(observation(expected[key], "not-run", 0, reason="missing UI sample", exit_code=None)
                              for key in sorted(set(expected) - present - deselected))
    result["status"] = "failed" if result["errors"] else "passed"
    yellow = [item["identity"] for item in result["observed"] if "environment_limit" in item]
    if yellow:
        result["environment_limited"] = yellow
    flaky = [item["identity"] for item in result["observed"] if "nightly_retry" in item]
    if flaky:
        result["flaky"] = flaky
    if yellow or flaky:
        if not result["errors"]:
            result["status"] = "environment-limited"
    return result


def validate_ui_record(raw, summaries, *, policy, registry, evaluated_on, official_tests=None, retry_tests=None):
    record = decode(raw)
    fields(record, {"schema_version", "plan", "verdict", "matrix_job_result", "capacity"}, "nightly UI aggregate")
    require(type(record["schema_version"]) is int and record["schema_version"] == 1, "unsupported nightly UI aggregate")
    require(record["matrix_job_result"] in {"success", "failure", "cancelled", "skipped"}, "invalid UI job result")
    expected = judge_ui(record["plan"], summaries, policy=policy, registry=registry, evaluated_on=evaluated_on,
                        matrix_job_result=record["matrix_job_result"], official_tests=official_tests, retry_tests=retry_tests)
    actual = copy.deepcopy(record["verdict"])
    comparison = copy.deepcopy(expected)
    verified = {identity_key(item["identity"]): item for item in comparison["observed"]}
    restored = set()
    for index, item in enumerate(actual["observed"]):
        key = identity_key(item["identity"])
        backup = item.pop("nightly_retry_first", None)
        item.pop("retry_failure", None)
        if "nightly_retry" in item and backup is not None and backup == verified.get(key):
            actual["observed"][index] = copy.deepcopy(backup)
            restored.add(key)
    for item in comparison["observed"]:
        item.pop("retry_failure", None)
        item.pop("nightly_retry_first", None)
    if restored:
        for verdict in (actual, comparison):
            for scope in (verdict, *(shard["verdict"] for shard in verdict["shards"])):
                for field in ("environment_limited", "flaky"):
                    if field in scope:
                        kept = [item for item in scope[field] if identity_key(item) not in restored]
                        if kept:
                            scope[field] = kept
                        else:
                            scope.pop(field)
    require(actual == comparison, "nightly UI aggregate differs from bound shard evidence")
    capacity = record["capacity"]
    fields(capacity, {"max_parallel", "shards", "minimum_shard_waves", "start_order_waves", "shard_intervals", "wall_seconds"},
           "nightly UI capacity")
    shard_count, parallel = len(record["plan"]["shards"]), record["plan"]["max_parallel"]
    require(capacity["max_parallel"] == parallel and capacity["shards"] == shard_count
            and capacity["minimum_shard_waves"] == (shard_count + parallel - 1) // parallel,
            "invalid UI capacity")
    duration(capacity["wall_seconds"])
    pairs = []
    for interval in capacity["shard_intervals"]:
        fields(interval, {"shard", "started_epoch", "finished_epoch"}, "UI interval")
        duration(interval["started_epoch"])
        duration(interval["finished_epoch"])
        require(interval["finished_epoch"] >= interval["started_epoch"], "UI shard ended before it started")
        pairs.append(interval["shard"])
    wanted = {item["device"] + "/" + item["shard"] for item in record["plan"]["shards"]}
    require(len(pairs) == len(set(pairs)) and set(pairs) <= wanted, "invalid UI timing shard")
    ordered = sorted(capacity["shard_intervals"], key=lambda item: item["started_epoch"])
    require(capacity["start_order_waves"] == [[item["shard"] for item in ordered[index:index + 2]]
                                             for index in range(0, len(ordered), 2)], "invalid UI wave accounting")
    require(expected["status"] == "failed" or set(pairs) == wanted, "passing UI aggregate lacks timing samples")
    return {**record, "verdict": expected}


def default_plan_populations(root, devices=DEVICES):
    from ci_population import ui_identities
    from ci_ui_shards import MANIFEST_PATH, shard_populations
    ui_root = root / "immichSlidesUITests"
    sources = {path.relative_to(ui_root).as_posix(): path.read_text() for path in ui_root.rglob("*.swift")}
    manifest = (root / MANIFEST_PATH).read_text()
    populations = {}
    for device in devices:
        platform = DEVICES[device]
        test_plan = root / ("immichSlides-" + ("iOS" if platform == "ios" else "tvOS") + ".xctestplan")
        populations[device] = shard_populations(ui_identities(sources, platform), test_plan.read_text(), manifest, device)
    return populations


def current_plan(root):
    from ci_build_archive import file_hash
    from ci_ui_shards import MANIFEST_PATH
    from run_host_checks import run_identity, source_metadata
    from strict_e2e_server import fixture_manifest
    identity = run_identity(os.environ, ci=os.environ.get("GITHUB_ACTIONS") == "true")
    workflow, fork = source_metadata(identity, os.environ, WORKFLOW if identity["event"] != "local" else None)
    plan = {"schema_version": 1, "identity": identity,
            "source": {"repository": identity["repository"], "workflow_path": workflow, "event": identity["event"],
                       "fork_originated": fork, "ci_changing": None},
            "run": {"id": os.environ.get("GITHUB_RUN_ID"), "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1"))},
            "shards": [], "hashes": {}, "max_parallel": 2, "started_epoch": time.time()}
    populations = default_plan_populations(root)
    for device, platform in DEVICES.items():
        test_plan = root / ("immichSlides-" + ("iOS" if platform == "ios" else "tvOS") + ".xctestplan")
        plan["shards"].extend({"device": device, "shard": shard, "declared": declared} for shard, declared in populations[device].items())
        plan["hashes"][device] = {"manifests": {"fixture-c": fixture_manifest("c")["fixture_sha256"],
                                               "test-plan": file_hash(test_plan), "ui-shards": file_hash(root / MANIFEST_PATH)},
                                  "policies": {"test-policy": file_hash(root / "scripts/ci-test-policy.json"),
                                               "known-flaky": file_hash(root / "scripts/ci-known-flaky.json")}}
    return parse_ui_plan(plan)


def aggregate_ui(plan, records, *, matrix_job_result, root):
    from ci_summary import duration
    summaries, intervals, errors, official_tests, retry_tests = [], [], [], {}, {}
    expected = {f"ui-{item['device']}-{item['shard']}-{plan['run']['id']}-{plan['run']['attempt']}" for item in plan["shards"]}
    actual = {path.name for path in records.iterdir()} if records.is_dir() else set()
    require(actual <= expected, "unexpected nightly UI artifact directories")
    for item in plan["shards"]:
        directory = records / f"ui-{item['device']}-{item['shard']}-{plan['run']['id']}-{plan['run']['attempt']}"
        if not (directory / "summary.json").is_file():
            continue
        try:
            summaries.append(parse_nightly_summary((directory / "summary.json").read_text()))
            if any("environment_limit" in row or "nightly_retry" in row for row in summaries[-1]["population"]["observed"]):
                official_tests[(item["device"], item["shard"])] = decode((directory / "official-tests.json").read_text())
            if any("nightly_retry" in row or "retry_failure" in row for row in summaries[-1]["population"]["observed"]):
                pair = (item["device"], item["shard"])
                if pair not in official_tests:
                    try:
                        official_tests[pair] = decode((directory / "official-tests.json").read_text())
                    except (ValueError, OSError):
                        pass
                retry_tests[pair] = read_ui_retry_tests(lambda name: decode((directory / name).read_text()))
            timing = decode((directory / "shard-timing.json").read_text())
            require(timing["device"] == item["device"] and timing["shard"] == item["shard"], "UI timing differs from shard")
            for key in ("started_epoch", "finished_epoch"):
                duration(timing[key])
            require(timing["started_epoch"] <= timing["finished_epoch"] <= time.time(), "invalid UI timing interval")
            intervals.append({"shard": item["device"] + "/" + item["shard"],
                              "started_epoch": timing["started_epoch"], "finished_epoch": timing["finished_epoch"]})
        except (OSError, ValueError, KeyError, TypeError) as error:
            errors.append(item["device"] + "/" + item["shard"] + ": " + str(error))
    if errors or len(intervals) != len(plan["shards"]):
        matrix_job_result = "failure"
    policy = decode((root / "scripts/ci-test-policy.json").read_text())
    registry = decode((root / "scripts/ci-known-flaky.json").read_text())
    evaluated_on = date.today()
    if os.environ.get("GITHUB_ACTIONS") == "true":
        from ci_publish import GitHub
        run = GitHub(plan["identity"]["repository"], os.environ["GH_TOKEN"]).repo("actions/runs/" + plan["run"]["id"])
        require(run["head_sha"] == plan["identity"]["commit_sha"], "UI evaluation date source differs")
        evaluated_on = date.fromisoformat(run["created_at"][:10])
    verdict = judge_ui(plan, summaries, policy=policy, registry=registry, evaluated_on=evaluated_on,
                       matrix_job_result=matrix_job_result, official_tests=official_tests, retry_tests=retry_tests)
    ordered = sorted(intervals, key=lambda item: item["started_epoch"])
    parallel, count = plan["max_parallel"], len(plan["shards"])
    record = {"schema_version": 1, "plan": plan, "verdict": verdict, "matrix_job_result": matrix_job_result,
              "capacity": {"max_parallel": parallel, "shards": count, "minimum_shard_waves": (count + parallel - 1) // parallel, "shard_intervals": intervals,
                           "start_order_waves": [[item["shard"] for item in ordered[index:index + parallel]] for index in range(0, len(ordered), parallel)],
                           "wall_seconds": time.time() - plan["started_epoch"]}}
    validate_ui_record(record, summaries, policy=policy, registry=registry, evaluated_on=evaluated_on,
                       official_tests=official_tests, retry_tests=retry_tests)
    return record


def main(argv=None):
    from ci_build_archive import workspace_preflight
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "aggregate"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--records-dir", type=Path)
    parser.add_argument("--matrix-job-result", choices=("success", "failure", "cancelled", "skipped"))
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    workspace_preflight(root)
    output = args.output_dir.resolve()
    require(root != output and root not in output.parents and not output.exists(), "UI output must be fresh and outside checkout")
    output.mkdir(parents=True)
    plan = current_plan(root)
    if args.command == "plan":
        (output / "plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
        count, parallel = len(plan["shards"]), plan["max_parallel"]
        print(f"Nightly UI: {count} shards, max-parallel {parallel}, minimum {(count + parallel - 1) // parallel} waves; complete default plans", file=sys.stderr)
        print(json.dumps({"include": [{"device": item["device"], "shard": item["shard"]} for item in plan["shards"]]}, separators=(",", ":")))
        return 0
    require(args.plan is not None and args.records_dir is not None and args.matrix_job_result is not None,
            "UI aggregate needs scheduling record, records and Actions job result")
    stored = parse_ui_plan(args.plan.read_text())
    require(all(stored[key] == plan[key] for key in ("identity", "source", "run", "hashes", "shards", "max_parallel")),
            "nightly UI plan differs from tested checkout or attempt")
    record = aggregate_ui(stored, args.records_dir, matrix_job_result=args.matrix_job_result, root=root)
    (output / "nightly-ui.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    verdict, capacity = record["verdict"], record["capacity"]
    from ci_summary import markdown_text, render_nightly_retry, render_retry_failure
    lines = ["# Nightly UI: " + verdict["status"], "", f"Scheduled {verdict['matrix']['scheduled']}; executed {verdict['matrix']['executed']}; deselected {verdict['matrix']['deselected']}; missing {len(verdict['matrix']['missing'])}.",
             f"{capacity['shards']} shards; max-parallel {capacity['max_parallel']}; minimum {capacity['minimum_shard_waves']} waves; observed start-order waves {len(capacity['start_order_waves'])}; wall {capacity['wall_seconds']:.1f}s.", "",
             "| Device | Shard | Verdict |", "|---|---|---|"]
    lines.extend(f"| {item['device']} | {item['shard']} | {item['verdict']['status']} |" for item in verdict["shards"])
    if verdict.get("flaky"):
        lines.extend("\nWARNING: " + markdown_text(identity_key(item["identity"])) + ": "
                     + markdown_text(render_nightly_retry(item))
                     for item in verdict["observed"] if "nightly_retry" in item)
    if verdict.get("environment_limited"):
        from ci_failure_diagnostics import render_environment_limit
        lines.append("\n> **WARNING: hosted XCTest/Apple tool failures are environment-limited (yellow), never passes.**")
        lines.extend("\nWARNING: " + markdown_text(identity_key(item["identity"])) + ": "
                     + markdown_text(render_environment_limit(item["environment_limit"]))
                     for item in verdict["observed"] if "environment_limit" in item)
    lines.extend("\n" + markdown_text(identity_key(item["identity"]) + ": " + render_retry_failure(item["retry_failure"]))
                 for item in verdict["observed"] if "retry_failure" in item)
    lines.extend(["", *verdict["errors"]])
    (output / "nightly-ui.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:4]))
    return 1 if verdict["status"] == "failed" else 0


if __name__ == "__main__":
    from ci_local import local_main
    raise SystemExit(local_main(main, __file__))
