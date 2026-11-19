#!/usr/bin/env python3
"""Versioned producer records. Validation is structural, not a trusted CI verdict."""

from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path

BOUNDED_DIAGNOSTICS_FIELD = "bounded_diagnostics"
OUTCOMES = {"passed", "failed", "skipped", "crashed", "timed-out", "not-run"}
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
        "schedule": {"ref", "commit_sha"},
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
    elif event == "schedule":
        require(payload["ref"] == "refs/heads/main", "schedule identity requires refs/heads/main")
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


def observation(identity, outcome, duration_seconds, *, reason=None, message=None, exit_code=0, failure_diagnostics=None):
    entry = {"identity": identity, "outcome": outcome, "duration_seconds": duration_seconds,
            "attempts": [{"number": 1, "outcome": outcome, "duration_seconds": duration_seconds,
                          "exit_code": exit_code, "reason": reason, "message": message}]}
    if failure_diagnostics is not None:
        from ci_failure_diagnostics import DIAGNOSTIC_FIELDS, validate_diagnostic_fields
        require(set(failure_diagnostics) == DIAGNOSTIC_FIELDS, "invalid failure diagnostic fields")
        validate_diagnostic_fields(failure_diagnostics)
        entry.update(failure_diagnostics)
        entry["attempts"][0].update(failure_diagnostics)
    return entry


def validate_observation(entry):
    from ci_failure_diagnostics import (DIAGNOSTIC_FIELDS, FIRST_FAILURE_FIELD, FAILURE_MESSAGES_FIELD,
                                        validate_diagnostic_fields)
    require(isinstance(entry, dict), "observation must be an object")
    validate_diagnostic_fields(entry)
    optional = DIAGNOSTIC_FIELDS | {FIRST_FAILURE_FIELD, FAILURE_MESSAGES_FIELD}
    fields(entry, {"identity", "outcome", "duration_seconds", "attempts"} | (optional & entry.keys()), "observation")
    validate_test_identity(entry["identity"])
    require(entry["outcome"] in OUTCOMES, "invalid outcome")
    require(isinstance(entry["attempts"], list) and len(entry["attempts"]) == 1, "one first-result attempt is required")
    attempt = entry["attempts"][0]
    fields(attempt, {"number", "outcome", "duration_seconds", "exit_code", "reason", "message"}
           | (optional & attempt.keys()), "attempt")
    require(type(attempt["number"]) is int and attempt["number"] == 1, "first attempt number must be one")
    require(attempt["outcome"] == entry["outcome"], "single outcome must match its attempt")
    require(attempt["exit_code"] is None or type(attempt["exit_code"]) is int, "invalid exit code")
    nullable_string(attempt["reason"], "reason")
    nullable_string(attempt["message"], "message")
    if attempt["outcome"] == "skipped":
        string(attempt["reason"], "skip reason")
    if attempt["outcome"] == "passed":
        require(attempt["exit_code"] in (0, None), "passed attempt cannot have a failing exit")
    for item in (entry, attempt):
        if item["duration_seconds"] is None:
            require(entry["identity"]["kind"] == "ui" and item["outcome"] in {"failed", "crashed"},
                    "unknown duration requires a failed UI result")
        else:
            duration(item["duration_seconds"])
        if FIRST_FAILURE_FIELD in item:
            require(entry["identity"]["kind"] == "ui" and item["outcome"] in {"failed", "crashed", "timed-out", "not-run"},
                    "first failure requires a failing UI observation")
            require((item["outcome"] == "not-run") == (item[FIRST_FAILURE_FIELD]["source"] == "preparation"),
                    "first failure source must match execution state")
        if FAILURE_MESSAGES_FIELD in item:
            require(entry["identity"]["kind"] == "ui" and item["outcome"] == "failed",
                    "failure messages require a failed UI observation")
    for field in optional:
        require((field in entry) == (field in attempt) and entry.get(field) == attempt.get(field),
                "attempt diagnostics must match observation")
    require(entry["duration_seconds"] == attempt["duration_seconds"], "total duration must account for every attempt")


def validate_summary_v1(payload):
    optional = {BOUNDED_DIAGNOSTICS_FIELD} & payload.keys()
    fields(payload, {"schema_version", "identity", "source", "run", "hashes", "toolchain", "population",
                     "infrastructure", "status"} | optional, "summary")
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
    if BOUNDED_DIAGNOSTICS_FIELD in payload:
        from ci_bounded_diagnostics import validate_receipt
        validate_receipt(payload[BOUNDED_DIAGNOSTICS_FIELD])


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
             "Producer report for build, unit and host results.", "",
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
        if "failure_messages" in entry:
            message = "; ".join(filter(None, [message, *entry["failure_messages"]]))
        outcome = entry["outcome"]
        hints = []
        label = entry["identity"]["key"]
        if hints:
            label += " (" + ", ".join(f"{key}={value}" for key, value in sorted(entry["identity"]["dimensions"].items())) + ")"
        detail = "; ".join(part for part in [markdown_text(message), *hints] if part)
        seconds = "unknown" if entry["duration_seconds"] is None else f"{entry['duration_seconds']:.3f}"
        lines.append(f"| {markdown_text(label)} | {outcome} | {seconds} | {detail} |")
    for entry in population["deselected"]:
        lines.append(f"| {markdown_text(entry['identity']['key'])} | deselected | — | {markdown_text(entry['reason'])}; owned by {markdown_text(entry['owning_tier'])} |")
    for entry in population["observed"]:
        if "first_failure" in entry:
            from ci_failure_diagnostics import render_first_failure
            lines.append("\nFirst failure: " + markdown_text(entry["identity"]["key"]) + ": "
                         + markdown_text(render_first_failure(entry["first_failure"])) + "\n")
    for entry in payload["infrastructure"]:
        category = NON_INFRASTRUCTURE_DIAGNOSTICS.get(entry["code"], "Infrastructure")
        lines.append(f"\n{category}: {markdown_text(entry['code'])}: {markdown_text(entry['message'])}")
    if BOUNDED_DIAGNOSTICS_FIELD in payload:
        from ci_bounded_diagnostics import render_receipt
        lines.append(render_receipt(payload[BOUNDED_DIAGNOSTICS_FIELD]))
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
    except (ValueError, OSError) as error:
        print(f"FAIL: {error}")
        return 1
    print("PASS: supported, structurally valid record (not a trusted verdict)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
