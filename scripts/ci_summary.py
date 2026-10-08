#!/usr/bin/env python3
"""Versioned producer records. Validation is structural, not a trusted CI verdict."""

from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path

SCHEMA_VERSION = 1
OUTCOMES = {"passed", "failed", "skipped", "flaky-passed", "crashed", "timed-out", "not-run", "needs-human-review"}
ATTEMPT_OUTCOMES = OUTCOMES - {"flaky-passed"}
STRICT_DIMENSIONS = {"device", "configuration", "suite", "scenario", "fixture"}
NON_INFRASTRUCTURE_DIAGNOSTICS = {"coverage-failed": "Coverage", "policy-proposed": "Policy",
                                  "population-invalid": "Population"}


class ContractError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ContractError(message)


def fields(value, names, where):
    require(isinstance(value, dict) and set(value) == set(names), f"{where}: expected fields {sorted(names)}")


def string(value, where):
    require(isinstance(value, str) and bool(value.strip()), f"{where}: expected nonempty string")


def integer(value, minimum, where):
    require(type(value) is int and value >= minimum, f"{where}: expected integer >= {minimum}")


def duration(value):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0, "duration must be finite and nonnegative")


def nullable_string(value, where):
    if value is not None:
        string(value, where)


def sha(value, length=40):
    require(isinstance(value, str) and re.fullmatch(rf"[0-9a-f]{{{length}}}", value) is not None, f"expected {length}-digit hash")


def no_duplicates(pairs):
    payload = {}
    for key, value in pairs:
        require(key not in payload, f"duplicate JSON key: {key}")
        payload[key] = value
    return payload


def decode(raw):
    if isinstance(raw, str):
        try:
            return json.loads(raw, object_pairs_hook=no_duplicates,
                              parse_constant=lambda value: require(False, f"non-finite JSON value: {value}"))
        except (ValueError, TypeError) as error:
            raise ContractError(f"invalid JSON: {error}") from error
    require(isinstance(raw, dict), "record must be an object")
    return raw


def validate_identity_v1(payload):
    event = payload.get("event")
    common = {"schema_version", "event", "repository", "tree_sha"}
    variants = {
        "pull_request": {"pull_request", "merge_sha", "base_sha", "head_sha"},
        "push": {"ref", "pushed_sha"},
        "workflow_dispatch": {"ref", "commit_sha"},
        "local": {"commit_sha", "dirty"},
    }
    require(event in variants, "unsupported identity event")
    fields(payload, common | variants[event], "identity")
    require(payload["schema_version"] == 1 and type(payload["schema_version"]) is int, "invalid identity version")
    require((event == "local" and payload["repository"] is None) or
            (isinstance(payload["repository"], str) and re.fullmatch(r"[\w.-]+/[\w.-]+", payload["repository"]) is not None),
            "invalid repository")
    for key in payload:
        if key.endswith("_sha"):
            sha(payload[key])
    if event == "pull_request":
        integer(payload["pull_request"], 1, "pull_request")
    elif event == "push":
        require(payload["ref"] == "refs/heads/main", "push identity requires refs/heads/main")
    elif event == "workflow_dispatch":
        require(isinstance(payload["ref"], str) and re.fullmatch(r"refs/(heads|tags)/[^\s]+", payload["ref"]) is not None,
                "workflow_dispatch identity requires a branch or tag ref")
    else:
        require(type(payload["dirty"]) is bool, "dirty must be boolean")


def test_identity(kind, key, **dimensions):
    return {"kind": kind, "key": key, "dimensions": dimensions}


def validate_test_identity(identity):
    fields(identity, {"kind", "key", "dimensions"}, "test identity")
    require(identity["kind"] in {"host", "python", "swift", "ui", "strict"}, "unsupported test kind")
    string(identity["key"], "test key")
    require(isinstance(identity["dimensions"], dict), "dimensions must be an object")
    allowed = STRICT_DIMENSIONS if identity["kind"] == "strict" else STRICT_DIMENSIONS | {"platform", "parameter"}
    require(set(identity["dimensions"]) <= allowed, "unknown identity dimension")
    if identity["kind"] == "strict":
        require(set(identity["dimensions"]) == STRICT_DIMENSIONS, "strict identity requires all five dimensions")
    for value in identity["dimensions"].values():
        string(value, "dimension")


def identity_key(identity):
    return json.dumps(identity, sort_keys=True, separators=(",", ":"))


def observation(identity, outcome, duration_seconds, *, reason=None, message=None, exit_code=0):
    return {"identity": identity, "outcome": outcome, "duration_seconds": duration_seconds,
            "attempts": [{"number": 1, "outcome": outcome, "duration_seconds": duration_seconds,
                          "exit_code": exit_code, "reason": reason, "message": message}]}


def validate_observation(entry):
    fields(entry, {"identity", "outcome", "duration_seconds", "attempts"}, "observation")
    validate_test_identity(entry["identity"])
    require(entry["outcome"] in OUTCOMES, "invalid outcome")
    duration(entry["duration_seconds"])
    require(isinstance(entry["attempts"], list) and bool(entry["attempts"]), "attempts must be nonempty")
    for number, attempt in enumerate(entry["attempts"], 1):
        fields(attempt, {"number", "outcome", "duration_seconds", "exit_code", "reason", "message"}, "attempt")
        integer(attempt["number"], 1, "attempt number")
        require(attempt["number"] == number, "attempts must be consecutive")
        require(attempt["outcome"] in ATTEMPT_OUTCOMES, "invalid attempt outcome")
        duration(attempt["duration_seconds"])
        require(attempt["exit_code"] is None or type(attempt["exit_code"]) is int, "invalid exit code")
        nullable_string(attempt["reason"], "reason")
        nullable_string(attempt["message"], "message")
        if attempt["outcome"] == "skipped":
            string(attempt["reason"], "skip reason")
        if attempt["outcome"] == "passed":
            require(attempt["exit_code"] in (0, None), "passed attempt cannot have a failing exit")
    require(math.isclose(entry["duration_seconds"], sum(a["duration_seconds"] for a in entry["attempts"]), abs_tol=0.001),
            "total duration must account for every attempt")
    if entry["outcome"] == "flaky-passed":
        require(len(entry["attempts"]) == 2 and entry["attempts"][0]["outcome"] == "failed"
                and entry["attempts"][1]["outcome"] == "passed", "flaky pass requires failed then passed attempts")
    elif entry["outcome"] == "failed":
        require(entry["attempts"][-1]["outcome"] in {"failed", "skipped", "crashed", "timed-out", "not-run"},
                "failed aggregate requires a nonpassing final attempt")
    else:
        require(len(entry["attempts"]) == 1 and entry["outcome"] == entry["attempts"][0]["outcome"],
                "single outcome must match its attempt")


def validate_summary_v1(payload):
    fields(payload, {"schema_version", "identity", "source", "run", "hashes", "toolchain", "population",
                     "infrastructure", "status"}, "summary")
    require(type(payload["schema_version"]) is int and payload["schema_version"] == 1, "invalid summary version")
    identity = parse_identity(payload["identity"])
    source = payload["source"]
    fields(source, {"repository", "workflow_path", "event", "fork_originated", "ci_changing"}, "source")
    require(source["repository"] == identity["repository"] and source["event"] == identity["event"], "source/identity mismatch")
    nullable_string(source["workflow_path"], "workflow path")
    for key in ("fork_originated", "ci_changing"):
        require(source[key] is None or type(source[key]) is bool, f"{key} must be boolean or null (unclassified)")
    if source["event"] != "local":
        require(isinstance(source["workflow_path"], str) and source["workflow_path"].startswith(".github/workflows/"),
                "CI source requires workflow path")
        require(type(source["fork_originated"]) is bool, "CI fork source must be recorded")
    run = payload["run"]
    fields(run, {"id", "attempt", "tier", "job", "shard"}, "run")
    nullable_string(run["id"], "run id")
    integer(run["attempt"], 1, "run attempt")
    for key in ("tier", "job"):
        string(run[key], key)
    nullable_string(run["shard"], "shard")
    require(source["event"] == "local" or run["id"] is not None, "CI requires run id")
    fields(payload["hashes"], {"manifests", "policies"}, "hashes")
    for hashes in payload["hashes"].values():
        require(isinstance(hashes, dict), "hash collection must be an object")
        for name, value in hashes.items():
            string(name, "hash name")
            sha(value, 64)
    toolchain = payload["toolchain"]
    fields(toolchain, {"versions", "signing_mode"}, "toolchain")
    require(isinstance(toolchain["versions"], dict) and bool(toolchain["versions"]), "versions must be nonempty")
    for name, value in toolchain["versions"].items():
        string(name, "tool name")
        nullable_string(value, "tool version")
    require(toolchain["signing_mode"] in {"not-applicable", "sign-to-run-locally"}, "unsupported signing mode")
    population = payload["population"]
    fields(population, {"declared", "compiled", "observed", "deselected", "removed_by_pr"}, "population")
    for key, entries in population.items():
        require(isinstance(entries, list), f"{key} must be a list")
        seen = set()
        for entry in entries:
            if key == "observed":
                validate_observation(entry)
                test = entry["identity"]
            elif key == "deselected":
                fields(entry, {"identity", "reason", "owning_tier"}, "deselection")
                string(entry["reason"], "deselection reason")
                string(entry["owning_tier"], "owning tier")
                test = entry["identity"]
            else:
                test = entry
            validate_test_identity(test)
            token = identity_key(test)
            require(token not in seen, f"duplicate {key} identity: {test['key']}")
            seen.add(token)
    require(isinstance(payload["infrastructure"], list), "infrastructure must be a list")
    for entry in payload["infrastructure"]:
        fields(entry, {"code", "message"}, "infrastructure outcome")
        string(entry["code"], "infrastructure code")
        string(entry["message"], "infrastructure message")
    require(payload["status"] in {"passed", "failed", "unverified"}, "invalid producer status")


# A successor needs an installed validator before it is admitted by a reader.
IDENTITY_READERS = {1: validate_identity_v1}
SUMMARY_READERS = {1: validate_summary_v1}


def parse_record(raw, readers):
    payload = decode(raw)
    require(isinstance(payload, dict), "record must be an object")
    version = payload.get("schema_version")
    require(type(version) is int and version in readers, "unsupported schema_version")
    try:
        readers[version](payload)
    except (TypeError, KeyError, AttributeError) as error:
        raise ContractError(f"malformed schema {version}: {type(error).__name__}") from error
    return payload


def parse_identity(raw):
    return parse_record(raw, IDENTITY_READERS)


def parse_summary(raw):
    return parse_record(raw, SUMMARY_READERS)


def markdown_text(value):
    # Keep candidate-controlled text inside table cells; never render raw HTML.
    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("|", "&#124;").replace("\n", " ").replace("`", "&#96;")


def render_markdown(payload):
    parse_summary(payload)
    population = payload["population"]
    lines = [f"## {markdown_text(payload['run']['job'])}: {payload['status'].upper()}", "",
             "Producer report; trusted publication and approval are evaluated separately.", "",
             f"Source: {markdown_text(payload['source']['repository'])}, {payload['source']['event']}; "
             f"run {markdown_text(payload['run']['id'])}, attempt {payload['run']['attempt']}.",
             f"Fork-originated: {payload['source']['fork_originated']}; CI-changing: {payload['source']['ci_changing']} (null means unclassified).",
             "", f"Declared: {len(population['declared'])}; compiled/discovered: {len(population['compiled'])}; "
             f"observed: {len(population['observed'])}; deselected: {len(population['deselected'])}.", "",
             "| Check or test | Outcome | Seconds | Reason or failure |", "| --- | --- | ---: | --- |"]
    # Successful Python and Swift identities stay in JSON; Markdown stays short.
    for entry in population["observed"]:
        if entry["identity"]["kind"] in {"python", "swift"} and entry["outcome"] == "passed":
            continue
        message = "; ".join(detail for attempt in entry["attempts"]
                            for detail in (attempt["reason"], attempt["message"]) if detail)
        lines.append(f"| {markdown_text(entry['identity']['key'])} | {entry['outcome']} | {entry['duration_seconds']:.3f} | {markdown_text(message)} |")
    for entry in population["deselected"]:
        lines.append(f"| {markdown_text(entry['identity']['key'])} | deselected | — | {markdown_text(entry['reason'])}; owned by {markdown_text(entry['owning_tier'])} |")
    for entry in payload["infrastructure"]:
        category = NON_INFRASTRUCTURE_DIAGNOSTICS.get(entry["code"], "Infrastructure")
        lines.append(f"\n{category}: {markdown_text(entry['code'])}: {markdown_text(entry['message'])}")
    return "\n".join(lines) + "\n"


def write_summary(payload, output_dir):
    parse_summary(payload)
    output_dir.mkdir(parents=True, exist_ok=True)
    for name, content in (("summary.json", json.dumps(payload, indent=2, allow_nan=False) + "\n"),
                          ("summary.md", render_markdown(payload)),
                          ("run-identity.json", json.dumps(payload["identity"], indent=2) + "\n")):
        temporary = output_dir / (name + ".tmp")
        temporary.write_text(content, encoding="utf-8")
        temporary.replace(output_dir / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--identity", action="store_true")
    args = parser.parse_args()
    try:
        (parse_identity if args.identity else parse_summary)(args.path.read_text(encoding="utf-8"))
    except (ContractError, OSError) as error:
        print(f"FAIL: {error}")
        return 1
    print("PASS: supported, structurally valid record (not a trusted verdict)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
