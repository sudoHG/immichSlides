"""Shared readers for complete default-plan nightly fixture UI evidence."""

from __future__ import annotations

import copy
from collections import Counter

from ci_summary import (ContractError, decode, duration, fields, identity_key, integer,
                        observation, parse_identity, parse_summary, require, sha, validate_test_identity)
from ci_ui_shards import DEVICES, LABEL
from ci_verdict import evaluate_population, tokens

WORKFLOW = ".github/workflows/ci-nightly.yml"


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


def judge_ui(raw_plan, raw_summaries, *, policy, registry, evaluated_on, matrix_job_result):
    plan = parse_ui_plan(raw_plan)
    result = {"status": "failed", "matrix": {}, "shards": [], "observed": [], "deselected": [], "errors": []}
    wanted = {(item["device"], item["shard"]): item for item in plan["shards"]}
    summaries = {}
    for raw in raw_summaries:
        try:
            summary = parse_summary(raw)
            device = summary["run"]["job"].removeprefix("ui-")
            pair = (device, summary["run"]["shard"])
            require(pair in wanted and pair not in summaries, "unexpected or duplicate UI shard")
            require(summary["identity"] == plan["identity"] and summary["source"] == plan["source"]
                    and summary["run"] == {**plan["run"], "tier": "ui", "job": "ui-" + device, "shard": pair[1]}
                    and summary["hashes"] == plan["hashes"][device], "nightly UI shard provenance mismatch")
            summaries[pair] = summary
        except (ContractError, KeyError, TypeError, ValueError) as error:
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
    return result


def validate_ui_record(raw, summaries, *, policy, registry, evaluated_on):
    record = decode(raw)
    fields(record, {"schema_version", "plan", "verdict", "matrix_job_result", "capacity"}, "nightly UI aggregate")
    require(type(record["schema_version"]) is int and record["schema_version"] == 1, "unsupported nightly UI aggregate")
    require(record["matrix_job_result"] in {"success", "failure", "cancelled", "skipped"}, "invalid UI job result")
    expected = judge_ui(record["plan"], summaries, policy=policy, registry=registry, evaluated_on=evaluated_on,
                        matrix_job_result=record["matrix_job_result"])
    require(record["verdict"] == expected, "nightly UI aggregate differs from bound shard evidence")
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
    require(expected["status"] != "passed" or set(pairs) == wanted, "passing UI aggregate lacks timing samples")
    return record
