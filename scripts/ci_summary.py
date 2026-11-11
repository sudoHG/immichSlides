#!/usr/bin/env python3
"""Versioned producer records. Validation is structural, not a trusted CI verdict."""

from __future__ import annotations

import argparse
import copy
import json
import math
import re
from pathlib import Path

SCHEMA_VERSION = 1
NIGHTLY_RETRY_READER_VERSION = 1
NIGHTLY_RETRY_FIELD = "nightly_retry"
NIGHTLY_RETRY_FIRST_FIELD = "nightly_retry_first"
RETRY_FAILURE_FIELD = "retry_failure"
BOUNDED_DIAGNOSTICS_FIELD = "bounded_diagnostics"
OUTCOMES = {"passed", "failed", "skipped", "flaky-passed", "crashed", "timed-out", "not-run", "needs-human-review"}
ATTEMPT_OUTCOMES = OUTCOMES - {"flaky-passed"}
STRICT_DIMENSIONS = {"device", "configuration", "suite", "scenario", "fixture"}
NON_INFRASTRUCTURE_DIAGNOSTICS = {"coverage-failed": "Coverage", "policy-proposed": "Policy",
                                  "population-invalid": "Population"}
ARCHIVE_DOWNLOAD_FAILURES = frozenset({
    "archive-member-missing", "archive-member-extra", "archive-size-mismatch", "archive-hash-mismatch",
    "archive-identity-mismatch", "archive-toolchain-mismatch", "archive-manifest-invalid",
    "archive-download-incomplete", "archive-gate-timeout", "archive-publish-failed",
})
ARCHIVE_DOWNLOAD_MAX_MEMBER_BYTES = 128 * 1024 * 1024  # Boundary tests bind this to the existing UI download cap.
ARCHIVE_DOWNLOAD_MAX_SECONDS = 110 * 60
ARCHIVE_DOWNLOAD_MAX_DISK_BYTES = 2**50  # 1 PiB diagnostic ceiling.
ARCHIVE_DOWNLOAD_MAX_ARTIFACT_ID = 2**63 - 1


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


def validate_nightly_retry(entry):
    proof = entry[NIGHTLY_RETRY_FIELD]
    fields(proof, {"schema_version", "policy_version", "runner_hosted", "failed_case_count"}, "nightly retry: proof")
    require(type(proof["schema_version"]) is int and proof["schema_version"] == 1,
            "nightly retry: unsupported schema version")
    require(type(proof["policy_version"]) is int and proof["policy_version"] == 1,
            "nightly retry: unsupported policy version")
    require(proof["runner_hosted"] is True, "nightly retry: requires GitHub-hosted runner")
    require(type(proof["failed_case_count"]) is int and 1 <= proof["failed_case_count"] <= 3,
            "nightly retry: failed case count must be 1 through 3")
    from ci_flaky import ASSERTION_FAILURE, P2_REVIEW_SUITES, IOS_PENDING_REVIEW_SUITE
    attempts = entry.get("attempts", [])
    review_pending = False
    p2 = False
    if entry["identity"]["kind"] == "strict":
        p2 = entry["identity"]["dimensions"].get("suite") in P2_REVIEW_SUITES
        review_pending = (entry.get("outcome") == "needs-human-review"
                          and (p2 or entry["identity"]["dimensions"].get("suite") == IOS_PENDING_REVIEW_SUITE))
    require((entry.get("outcome") == "flaky-passed" or review_pending) and entry["identity"]["kind"] in {"strict", "ui"}
            and (not p2 or review_pending)
            and len(attempts) == 2 and attempts[0]["outcome"] == "failed" and attempts[0]["exit_code"] == 65
            and attempts[0]["reason"] == ASSERTION_FAILURE
            and attempts[1]["outcome"] == ("needs-human-review" if review_pending else "passed")
            and type(attempts[1]["exit_code"]) is int and attempts[1]["exit_code"] == 0
            and "environment_limit" not in entry and all(NIGHTLY_RETRY_FIELD not in attempt for attempt in attempts),
            "nightly retry: requires exactly one assertion failure then one passing retry")


def public_nightly_retry_failure(entry):
    from ci_failure_diagnostics import validate_failure_messages
    from ci_flaky import ASSERTION_FAILURE
    messages = entry.get("failure_messages") or entry["attempts"][0].get("failure_messages")
    try:
        validate_failure_messages(messages)
    except ContractError:
        return ASSERTION_FAILURE
    return "; ".join(messages)


def render_nightly_retry(entry):
    return f"{nightly_retry_outcome(entry)}: first failure: {public_nightly_retry_failure(entry)}. One retry passed."


def nightly_retry_outcome(entry):
    return "needs-human-review (flaky; yellow)" if entry["outcome"] == "needs-human-review" else "flaky (yellow)"


def public_retry_failure(attempt):
    """Retain the second nonpassing attempt's structured evidence without runner text."""
    from ci_failure_diagnostics import DIAGNOSTIC_FIELDS, FAILURE_MESSAGES_FIELD, FIRST_FAILURE_FIELD, VALIDATOR_FAILURE_FIELD
    optional = DIAGNOSTIC_FIELDS | {FAILURE_MESSAGES_FIELD, FIRST_FAILURE_FIELD, VALIDATOR_FAILURE_FIELD}
    return {"number": 2, "outcome": attempt["outcome"], "duration_seconds": attempt["duration_seconds"],
            "exit_code": attempt["exit_code"], "message": None,
            "reason": "Official test was skipped" if attempt["outcome"] == "skipped" else None,
            **{key: attempt[key] for key in optional & attempt.keys()}}


def validate_retry_failure(entry):
    require(entry.get("outcome") == "failed" and entry["identity"]["kind"] in {"strict", "ui"}
            and ("attempts" not in entry or len(entry["attempts"]) == 1 and entry["attempts"][0]["outcome"] == "failed"),
            "retry failure: requires one failed strict or UI attempt")
    retry = entry[RETRY_FAILURE_FIELD]
    try:
        require(isinstance(retry, dict) and type(retry.get("number")) is int and retry["number"] == 2
                and retry == public_retry_failure(retry), "expected one sanitized second attempt")
        require(retry["outcome"] in {"failed", "skipped", "crashed", "timed-out", "not-run"}, "expected a nonpassing retry")
        standalone = {"identity": entry["identity"], "outcome": retry["outcome"],
                      "duration_seconds": retry["duration_seconds"], "attempts": [{**retry, "number": 1}]}
        for key in ("failure_messages", "first_failure", "validator_failure_message"):
            if key in retry:
                standalone[key] = retry[key]
        validate_observation(standalone)
    except (ContractError, KeyError, TypeError) as error:
        message = str(error) if isinstance(error, ContractError) else "invalid second attempt"
        raise ContractError("retry failure: " + message) from error


def validate_nightly_retry_first(entry):
    first = entry[NIGHTLY_RETRY_FIRST_FIELD]
    require(NIGHTLY_RETRY_FIELD in entry and isinstance(first, dict)
            and not {NIGHTLY_RETRY_FIELD, NIGHTLY_RETRY_FIRST_FIELD, RETRY_FAILURE_FIELD} & first.keys(),
            "nightly retry first: requires a passing retry and a standalone first observation")
    validate_observation(first)
    primary = entry["attempts"][0]
    require(first["identity"] == entry["identity"] and first["outcome"] == "failed"
            and first.get("environment_limit", {}).get("policy_version") == 5
            and all(first["attempts"][0][field] == primary[field] for field in ("duration_seconds", "exit_code")),
            "nightly retry first: v5 observation differs from the original attempt")


def render_retry_failure(attempt):
    seconds = attempt["duration_seconds"]
    elapsed = "unknown" if seconds is None else f"{seconds:.3f}s"
    details = [*attempt.get("failure_messages", [])]
    if "validator_failure_message" in attempt:
        details.append(attempt["validator_failure_message"])
    label = f"Retry outcome {attempt['outcome']}, exit {attempt['exit_code']}, duration {elapsed}."
    return " ".join([label, *details])


def validate_observation(entry):
    from ci_failure_diagnostics import DIAGNOSTIC_FIELDS, VALIDATOR_FAILURE_FIELD, FIRST_FAILURE_FIELD, validate_diagnostic_fields
    require(isinstance(entry, dict), "observation must be an object")
    try:
        validate_diagnostic_fields(entry)
    except ValueError as error:
        raise ContractError(str(error)) from error
    from ci_failure_diagnostics import ENVIRONMENT_LIMIT_FIELD, FAILURE_MESSAGES_FIELD, validate_environment_limit
    optional = DIAGNOSTIC_FIELDS | {VALIDATOR_FAILURE_FIELD, FIRST_FAILURE_FIELD, ENVIRONMENT_LIMIT_FIELD, FAILURE_MESSAGES_FIELD,
                                    NIGHTLY_RETRY_FIELD}
    fields(entry, {"identity", "outcome", "duration_seconds", "attempts"}
           | ((optional | {RETRY_FAILURE_FIELD, NIGHTLY_RETRY_FIRST_FIELD}) & entry.keys()), "observation")
    validate_test_identity(entry["identity"])
    require(entry["outcome"] in OUTCOMES, "invalid outcome")
    if NIGHTLY_RETRY_FIELD in entry:
        validate_nightly_retry(entry)
    if NIGHTLY_RETRY_FIRST_FIELD in entry:
        validate_nightly_retry_first(entry)
    if RETRY_FAILURE_FIELD in entry:
        validate_retry_failure(entry)
    if ENVIRONMENT_LIMIT_FIELD in entry:
        validate_environment_limit(entry[ENVIRONMENT_LIMIT_FIELD])
        require((entry["identity"]["kind"] == "strict" or entry["identity"]["kind"] == "ui"
                 and entry[ENVIRONMENT_LIMIT_FIELD]["policy_version"] == 5)
                and entry["outcome"] == "failed"
                and len(entry["attempts"]) == 1
                and entry["attempts"][0]["outcome"] == "failed"
                and entry["attempts"][0].get(ENVIRONMENT_LIMIT_FIELD) == entry[ENVIRONMENT_LIMIT_FIELD],
                "environment limit requires one matching failed strict attempt")
        if entry[ENVIRONMENT_LIMIT_FIELD]["policy_version"] == 5:
            attempt = entry["attempts"][0]
            require(VALIDATOR_FAILURE_FIELD not in attempt and all(attempt.get(key) == entry.get(key)
                    for key in (*DIAGNOSTIC_FIELDS, FIRST_FAILURE_FIELD, FAILURE_MESSAGES_FIELD)),
                    "environment limit: v5 attempt differs from observation")
    if FAILURE_MESSAGES_FIELD in entry:
        require(entry["identity"]["kind"] in {"strict", "ui"}
                and (entry["outcome"] == "failed" or NIGHTLY_RETRY_FIELD in entry)
                and entry["attempts"][0].get(FAILURE_MESSAGES_FIELD) == entry[FAILURE_MESSAGES_FIELD],
                "failure messages require one matching failed attempt")
    if FIRST_FAILURE_FIELD in entry:
        require(entry["identity"]["kind"] in {"strict", "ui"}
                and (entry["outcome"] in {"failed", "flaky-passed", "crashed", "timed-out", "not-run"}
                     or entry["outcome"] == "needs-human-review" and NIGHTLY_RETRY_FIELD in entry),
                "first failure requires a failing strict or UI observation")
    if VALIDATOR_FAILURE_FIELD in entry:
        require(entry["identity"]["kind"] == "strict" and entry["outcome"] == "failed",
                "validator failure message requires a failed strict observation")
    require(isinstance(entry["attempts"], list) and bool(entry["attempts"]), "attempts must be nonempty")
    for item in (entry, *entry["attempts"]):
        receipt = item.get(FIRST_FAILURE_FIELD, {})
        if {"album_capture", "native_tap_failure"} & receipt.keys():
            require(entry["identity"]["kind"] == "strict"
                and entry["identity"]["dimensions"].get("suite") == "filter-album",
                "album diagnostics require strict filter-album identity")
            if "album_capture" in receipt:
                require(receipt["album_capture"]["fixture"] == entry["identity"]["dimensions"].get("fixture"),
                    "album capture diagnostic: fixture differs from strict identity")
        if item["duration_seconds"] is None:
            require(entry["identity"]["kind"] == "ui" and item["outcome"] in {"failed", "crashed"}
                    and ENVIRONMENT_LIMIT_FIELD not in entry,
                    "unknown duration requires a failed UI result without environment limit")
        else:
            duration(item["duration_seconds"])
    for number, attempt in enumerate(entry["attempts"], 1):
        require(isinstance(attempt, dict), "attempt must be an object")
        fields(attempt, {"number", "outcome", "duration_seconds", "exit_code", "reason", "message"}
               | (optional & attempt.keys()), "attempt")
        require(NIGHTLY_RETRY_FIELD not in attempt, "nightly retry: proof belongs to observation only")
        if FIRST_FAILURE_FIELD in attempt:
            require(entry["identity"]["kind"] in {"strict", "ui"}
                    and attempt["outcome"] in {"failed", "crashed", "timed-out", "not-run"},
                    "first failure requires a failing strict or UI attempt")
            require((attempt["outcome"] == "not-run") == (attempt[FIRST_FAILURE_FIELD]["source"] == "preparation"),
                    "first failure source must match execution state")
        if ENVIRONMENT_LIMIT_FIELD in attempt:
            require(ENVIRONMENT_LIMIT_FIELD in entry, "environment limit attempt requires observation evidence")
        if FAILURE_MESSAGES_FIELD in attempt:
            require(FAILURE_MESSAGES_FIELD in entry, "failure messages attempt requires observation evidence")
        if VALIDATOR_FAILURE_FIELD in attempt:
            require(entry["identity"]["kind"] == "strict" and attempt["outcome"] == "failed",
                    "validator failure message requires a failed strict attempt")
        integer(attempt["number"], 1, "attempt number")
        require(attempt["number"] == number, "attempts must be consecutive")
        require(attempt["outcome"] in ATTEMPT_OUTCOMES, "invalid attempt outcome")
        require(attempt["exit_code"] is None or type(attempt["exit_code"]) is int, "invalid exit code")
        nullable_string(attempt["reason"], "reason")
        nullable_string(attempt["message"], "message")
        if attempt["outcome"] == "skipped":
            string(attempt["reason"], "skip reason")
        if attempt["outcome"] == "passed":
            require(attempt["exit_code"] in (0, None), "passed attempt cannot have a failing exit")
    seconds = [attempt["duration_seconds"] for attempt in entry["attempts"]]
    require((entry["duration_seconds"] is None if None in seconds else
             entry["duration_seconds"] is not None and math.isclose(entry["duration_seconds"], sum(seconds), abs_tol=0.001)),
            "total duration must account for every attempt")
    first = next((attempt for attempt in entry["attempts"] if attempt["outcome"] in {"failed", "crashed", "timed-out", "not-run"}), {})
    if FIRST_FAILURE_FIELD in entry or any(FIRST_FAILURE_FIELD in attempt for attempt in entry["attempts"]):
        require(FIRST_FAILURE_FIELD in entry and FIRST_FAILURE_FIELD in first
                and entry[FIRST_FAILURE_FIELD] == first[FIRST_FAILURE_FIELD],
                "first failure must match the first failing attempt")
    if entry["outcome"] == "flaky-passed" or entry["outcome"] == "needs-human-review" and NIGHTLY_RETRY_FIELD in entry:
        require(len(entry["attempts"]) == 2 and entry["attempts"][0]["outcome"] == "failed"
                and entry["attempts"][1]["outcome"] == ("needs-human-review" if entry["outcome"] == "needs-human-review" else "passed"),
                "flaky pass requires failed then passed attempts")
    elif entry["outcome"] == "failed":
        require(entry["attempts"][-1]["outcome"] in {"failed", "skipped", "crashed", "timed-out", "not-run"},
                "failed aggregate requires a nonpassing final attempt")
    else:
        require(len(entry["attempts"]) == 1 and entry["outcome"] == entry["attempts"][0]["outcome"],
                "single outcome must match its attempt")


def validate_archive_download(receipt, summary):
    fields(receipt, {"schema_version", "artifact_id", "action_outcome",
                     "member_bytes", "digests_matched", "size_matched", "transfer_extract_seconds", "gate_seconds",
                     "free_disk_bytes", "failure_reason"}, "archive download receipt")
    require(type(receipt["schema_version"]) is int and receipt["schema_version"] == 1,
            "unsupported archive download receipt")
    run = summary["run"]
    require(summary["source"]["workflow_path"] == ".github/workflows/ci-nightly.yml"
            and summary["identity"]["event"] in {"schedule", "workflow_dispatch"} and run["tier"] == "ui"
            and run["job"] in {"ui-iphone", "ui-ipad", "ui-appletv"} and bool(run["shard"]),
            "archive download receipt requires a nightly UI shard")
    integer(receipt["artifact_id"], 1, "archive artifact ID")
    require(receipt["artifact_id"] <= ARCHIVE_DOWNLOAD_MAX_ARTIFACT_ID, "archive artifact ID exceeds bound")
    require(receipt["action_outcome"] in ("success", "failure", "cancelled", "skipped"),
            "invalid archive download action outcome")
    reason = receipt["failure_reason"]
    require(reason is None or reason in tuple(ARCHIVE_DOWNLOAD_FAILURES), "invalid archive download failure reason")
    fields(receipt["member_bytes"], {"manifest.json", "build.tar.gz"}, "archive member bytes")
    for value in receipt["member_bytes"].values():
        if value is not None:
            integer(value, 0, "archive member bytes")
            require(value <= ARCHIVE_DOWNLOAD_MAX_MEMBER_BYTES, "archive member bytes exceed bound")
    fields(receipt["digests_matched"], {"manifest", "tar"}, "archive digest matches")
    for value in receipt["digests_matched"].values():
        require(value is None or type(value) is bool, "archive digest match must be boolean or null")
    require(receipt["size_matched"] is None or type(receipt["size_matched"]) is bool,
            "archive size match must be boolean or null")
    for key in ("transfer_extract_seconds", "gate_seconds"):
        if receipt[key] is not None:
            duration(receipt[key])
            require(receipt[key] <= ARCHIVE_DOWNLOAD_MAX_SECONDS, "archive elapsed seconds exceed bound")
    if receipt["free_disk_bytes"] is not None:
        integer(receipt["free_disk_bytes"], 0, "archive free disk bytes")
        require(receipt["free_disk_bytes"] <= ARCHIVE_DOWNLOAD_MAX_DISK_BYTES, "archive free disk bytes exceed bound")
    if reason is None:
        require(receipt["action_outcome"] == "success" and receipt["size_matched"] is True
                and all(value is True for value in receipt["digests_matched"].values())
                and all(value is not None and value > 0 for value in receipt["member_bytes"].values()),
                "successful archive gate requires complete integrity checks")
    else:
        require(summary["status"] == "failed" and any(item["code"] == reason for item in summary["infrastructure"])
                and not summary["population"]["compiled"]
                and all(attempt["outcome"] == "not-run" for item in summary["population"]["observed"]
                        for attempt in item["attempts"]),
                "failed archive gate requires failed infrastructure and no executed or compiled tests")


def validate_summary_v1(payload):
    optional = {"archive_download", BOUNDED_DIAGNOSTICS_FIELD, "strict_case_evidence"} & payload.keys()
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
    from ci_failure_diagnostics import ENVIRONMENT_LIMIT_FIELD, environment_limit_evidence
    case_evidence = payload.get("strict_case_evidence", [])
    require(isinstance(case_evidence, list), "invalid strict case evidence")
    evidence_by_case = {}
    for case in case_evidence:
        from ci_bounded_diagnostics import validate_receipt
        fields(case, {"identity", BOUNDED_DIAGNOSTICS_FIELD}, "strict case evidence")
        validate_test_identity(case["identity"])
        token = identity_key(case["identity"])
        require(case["identity"]["kind"] == "strict" and token not in evidence_by_case,
                "invalid or duplicate strict case evidence")
        validate_receipt(case[BOUNDED_DIAGNOSTICS_FIELD])
        evidence_by_case[token] = case[BOUNDED_DIAGNOSTICS_FIELD]
    for entry in population["observed"]:
        if NIGHTLY_RETRY_FIELD in entry or RETRY_FAILURE_FIELD in entry:
            require(source["workflow_path"] == ".github/workflows/ci-nightly.yml"
                    and identity["event"] in {"schedule", "workflow_dispatch"} and identity["ref"] == "refs/heads/main"
                    and source["fork_originated"] is False and run["tier"] == entry["identity"]["kind"]
                    and ((run["tier"] == "strict" and run["job"] == "nightly-strict") or
                         (run["tier"] == "ui" and run["job"] in {"ui-iphone", "ui-ipad", "ui-appletv"}))
                    and bool(run["shard"]),
                    "nightly retry: requires a main nightly shard")
    for row in population["observed"]:
        entry = row.get(NIGHTLY_RETRY_FIRST_FIELD, row)
        if ENVIRONMENT_LIMIT_FIELD in entry:
            proof = entry[ENVIRONMENT_LIMIT_FIELD]
            require(environment_limit_evidence(payload, entry, [] if proof["resources"] is None else [proof["resources"]], runner_hosted=proof["runner_hosted"],
                    policy_version=proof["policy_version"]) == proof,
                    "environment limit differs from scoped first failure evidence")
            if proof.get("kind") == "xctest-tool":
                continue
            evidence = evidence_by_case.get(identity_key(entry["identity"]), {})
            sequence = proof["resources"]["sequence"]
            samples = [event["sample"] for event in evidence.get("events", [])
                       if event["scope"] == "xcode" and event["sequence"] == sequence and event["sample"] is not None]
            require([resource for resource in evidence.get("case_resources", []) if resource["sequence"] == sequence]
                    == [proof["resources"]] and bool(samples) and all(sample["runner_hosted"] is True for sample in samples),
                    "environment limit differs from summary case evidence")
    if "archive_download" in payload:
        validate_archive_download(payload["archive_download"], payload)
    if BOUNDED_DIAGNOSTICS_FIELD in payload:
        from ci_bounded_diagnostics import validate_receipt
        validate_receipt(payload[BOUNDED_DIAGNOSTICS_FIELD])


# A successor needs an installed validator before it is admitted by a reader.
IDENTITY_READERS = {1: validate_identity_v1}


def validate_summary_v2(payload):
    require(type(payload.get("schema_version")) is int and payload["schema_version"] == 2, "invalid summary version")
    require("compiled_evidence" in payload, "missing compiled discovery evidence")
    legacy = {key: value for key, value in payload.items() if key != "compiled_evidence"}
    legacy["schema_version"] = 1
    validate_summary_v1(legacy)
    from ci_ui_discovery import validate_discovery_summary
    validate_discovery_summary(payload)


SUMMARY_READERS = {1: validate_summary_v1, 2: validate_summary_v2}


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


def parse_nightly_summary(raw):
    """Validate the producer record independently of optional retry evidence."""
    payload = copy.deepcopy(decode(raw))
    backups = []
    for entry in payload["population"]["observed"]:
        if RETRY_FAILURE_FIELD in entry:
            try:
                validate_retry_failure(entry)
            except (ValueError, KeyError, TypeError, AttributeError):
                entry.pop(RETRY_FAILURE_FIELD)
        if NIGHTLY_RETRY_FIRST_FIELD in entry:
            backups.append((entry, entry.pop(NIGHTLY_RETRY_FIRST_FIELD)))
    parse_summary(payload)
    for entry, backup in backups:
        entry[NIGHTLY_RETRY_FIRST_FIELD] = backup
        try:
            parse_summary(payload)
        except (ValueError, KeyError, TypeError, AttributeError):
            entry.pop(NIGHTLY_RETRY_FIRST_FIELD)
    return payload


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
        if "failure_messages" in entry:
            message = "; ".join(filter(None, [message, *entry["failure_messages"]]))
        if NIGHTLY_RETRY_FIELD in entry:
            message = public_nightly_retry_failure(entry)
        outcome = (nightly_retry_outcome(entry) if NIGHTLY_RETRY_FIELD in entry else
                   "failed (environment-limited; yellow)" if "environment_limit" in entry else entry["outcome"])
        hints = []
        if payload.get("strict_case_evidence"):
            from ci_bounded_diagnostics import render_app_hang_hint, render_continue_watch
            hints = [render_app_hang_hint(resource["app_hang_stack"])
                for case in payload["strict_case_evidence"] if case["identity"] == entry["identity"]
                for resource in case[BOUNDED_DIAGNOSTICS_FIELD].get("case_resources", []) if "app_hang_stack" in resource]
            hints += [render_continue_watch(resource["continue_watch"])
                for case in payload["strict_case_evidence"] if case["identity"] == entry["identity"]
                for resource in case[BOUNDED_DIAGNOSTICS_FIELD].get("case_resources", []) if "continue_watch" in resource]
            if entry["outcome"] == "failed":
                from ci_bounded_diagnostics import render_simulator_processes
                hints += [render_simulator_processes(resource["simulator_processes"])
                    for case in payload["strict_case_evidence"] if case["identity"] == entry["identity"]
                    for resource in case[BOUNDED_DIAGNOSTICS_FIELD].get("case_resources", []) if "simulator_processes" in resource]
                hints += ["pause-window assertions: " + ", ".join(resource["pause_window_assertions"])
                    for case in payload["strict_case_evidence"] if case["identity"] == entry["identity"]
                    for resource in case[BOUNDED_DIAGNOSTICS_FIELD].get("case_resources", []) if "pause_window_assertions" in resource]
                hints += ["failed at " + ", ".join(f"{location['path']}:{location['line']}"
                                                  for location in resource["failure_locations"])
                    for case in payload["strict_case_evidence"] if case["identity"] == entry["identity"]
                    for resource in case[BOUNDED_DIAGNOSTICS_FIELD].get("case_resources", []) if "failure_locations" in resource]
        label = entry["identity"]["key"]
        if hints:
            label += " (" + ", ".join(f"{key}={value}" for key, value in sorted(entry["identity"]["dimensions"].items())) + ")"
        detail = "; ".join(part for part in [markdown_text(message), *hints] if part)
        seconds = "unknown" if entry["duration_seconds"] is None else f"{entry['duration_seconds']:.3f}"
        lines.append(f"| {markdown_text(label)} | {outcome} | {seconds} | {detail} |")
    for entry in population["deselected"]:
        lines.append(f"| {markdown_text(entry['identity']['key'])} | deselected | — | {markdown_text(entry['reason'])}; owned by {markdown_text(entry['owning_tier'])} |")
    if any("environment_limit" in entry for entry in population["observed"]):
        category = ("timing or XCTest/Apple tool" if any(entry.get("environment_limit", {}).get("kind") == "xctest-tool"
                    for entry in population["observed"]) else "timing")
        lines.append(f"\n> **WARNING: hosted {category} failures are environment-limited (yellow), never passes.**")
    for entry in population["observed"]:
        if NIGHTLY_RETRY_FIELD in entry:
            lines.append("\nWARNING: " + markdown_text(entry["identity"]["key"]) + ": "
                         + markdown_text(render_nightly_retry(entry)) + "\n")
        if "first_failure" in entry:
            from ci_failure_diagnostics import render_first_failure
            lines.append("\nFirst failure: " + markdown_text(entry["identity"]["key"]) + ": "
                         + markdown_text(render_first_failure(entry["first_failure"])) + "\n")
        if "environment_limit" in entry:
            from ci_failure_diagnostics import render_environment_limit
            lines.append("\n" + markdown_text(entry["identity"]["key"]) + ": "
                         + markdown_text(render_environment_limit(entry["environment_limit"])) + "\n")
        if RETRY_FAILURE_FIELD in entry:
            lines.append(markdown_text(entry["identity"]["key"] + ": " + render_retry_failure(entry[RETRY_FAILURE_FIELD])))
    for entry in payload["infrastructure"]:
        category = NON_INFRASTRUCTURE_DIAGNOSTICS.get(entry["code"], "Infrastructure")
        lines.append(f"\n{category}: {markdown_text(entry['code'])}: {markdown_text(entry['message'])}")
    if "archive_download" in payload:
        receipt = payload["archive_download"]
        matches = {key: "unknown" if value is None else "yes" if value else "no"
                   for key, value in {**receipt["digests_matched"], "size": receipt["size_matched"]}.items()}
        measurements = {}
        for key, value in {**receipt["member_bytes"], "transfer_extract_seconds": receipt["transfer_extract_seconds"],
                           "gate_seconds": receipt["gate_seconds"], "free_disk_bytes": receipt["free_disk_bytes"]}.items():
            unit = " s" if key in {"transfer_extract_seconds", "gate_seconds"} else " bytes" if key == "free_disk_bytes" else ""
            measurements[key] = "unavailable" if value is None else str(value) + unit
        sizes = "; ".join(f"{key}={measurements[key]}" for key in receipt["member_bytes"])
        lines.append(f"\nArchive download: action={receipt['action_outcome']}; {sizes}; "
                     f"manifest digest={matches['manifest']}; tar digest={matches['tar']}; size={matches['size']}; "
                     f"transfer/extract={measurements['transfer_extract_seconds']}; gate={measurements['gate_seconds']}; "
                     f"free disk={measurements['free_disk_bytes']}; failure={receipt['failure_reason'] or 'none'}.")
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
