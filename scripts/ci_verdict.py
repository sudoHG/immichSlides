"""Fail-closed coverage and gate decisions; no publishing or GitHub operations.

Trusted consumers supply admitted tree populations, changed paths and policies.
Producer claims never select those inputs or grant approval.
"""

from __future__ import annotations

import fnmatch
import re
from datetime import date
from pathlib import PurePosixPath

from ci_summary import ContractError, NON_INFRASTRUCTURE_DIAGNOSTICS, decode, fields, identity_key, parse_summary, require, string, validate_test_identity


def parse_policy(raw):
    policy = decode(raw)
    names = {"schema_version", "approval_records", "expected_skips", "deselections"}
    if isinstance(policy, dict) and "proposed" in policy:
        names.add("proposed")
    fields(policy, names, "test policy")
    require(type(policy["schema_version"]) is int and policy["schema_version"] == 1, "unsupported test policy version")
    if "proposed" in policy:
        fields(policy["proposed"], {"expected_skips", "deselections"}, "proposed policy")
        # Keep proposal grammar separate from the active lists, regardless of tier records.
        parse_policy(dict(policy["proposed"], schema_version=1, approval_records=[]))
    require(isinstance(policy["approval_records"], list), "approval records must be an array")
    approved_tiers = set()
    for record in policy["approval_records"]:
        # Historical metadata does not authenticate approval or approve a new head.
        fields(record, {"approver", "date", "tier", "link"}, "approval record")
        for key in record:
            string(record[key], "approval " + key)
        try:
            require(date.fromisoformat(record["date"]).isoformat() == record["date"], "approval date must be ISO calendar date")
        except ValueError as error:
            raise ContractError("approval date must be ISO calendar date") from error
        require(re.fullmatch(r"https://github\.com/[^/\s]+/[^/\s]+/(?:issues|pull)/[1-9][0-9]*#issuecomment-[1-9][0-9]*",
                             record["link"]) is not None, "approval link must name a GitHub issue or PR comment")
        require(record["tier"] not in approved_tiers, "duplicate tier approval record")
        approved_tiers.add(record["tier"])
    for collection in ("expected_skips", "deselections"):
        require(isinstance(policy[collection], list), f"{collection} must be an array")
        seen = set()
        for entry in policy[collection]:
            common = {"tier", "environment", "reason"}
            if collection == "expected_skips":
                fields(entry, common | {"kind", "key_pattern", "dimensions"}, "expected skip")
                validate_test_identity({"kind": entry["kind"], "key": entry["key_pattern"], "dimensions": entry["dimensions"]})
            else:
                fields(entry, common | {"identity", "owning_tier"}, "policy deselection")
                validate_test_identity(entry["identity"])
                string(entry["owning_tier"], "owning tier")
                require(entry["owning_tier"] != entry["tier"], "deselection must have another owning tier")
            for key in common:
                string(entry[key], key)
            token = identity_key(entry)
            require(token not in seen, "duplicate policy entry")
            seen.add(token)
    return policy


def classify_changes(paths, policy, *, build_target_paths):
    """The caller supplies static build membership for the tested tree and both diff sides.

    PR paths come from base...head; push paths from before..after, including both
    rename paths. Unknown files and every CI-trusted path affect the app.
    """
    policy = decode(policy)
    fields(policy, {"schema_version", "app_unaffected", "ci_trusted"}, "classification policy")
    require(type(policy["schema_version"]) is int and policy["schema_version"] == 1, "unsupported classification version")
    for key in ("app_unaffected", "ci_trusted"):
        require(isinstance(policy[key], list), f"{key} must be an array")
        for pattern in policy[key]:
            string(pattern, "path pattern")
            require(not pattern.startswith("/") and ".." not in pattern.split("/"), "invalid path pattern")
    require(build_target_paths is not None, "build membership is required")
    paths = list(paths)
    require(paths, "changed path list is required")
    affected, trusted = [], []
    for path in paths:
        string(path, "changed path")
        require(not PurePosixPath(path).is_absolute() and ".." not in path.split("/")
                and "\\" not in path and str(PurePosixPath(path)) == path, "invalid changed path")
        is_trusted = any(fnmatch.fnmatchcase(path, pattern) for pattern in policy["ci_trusted"])
        if is_trusted:
            trusted.append(path)
        if is_trusted or path in build_target_paths or not any(fnmatch.fnmatchcase(path, pattern) for pattern in policy["app_unaffected"]):
            affected.append(path)
    return {"app_affected": bool(affected), "ci_changing": bool(trusted),
            "affected_paths": sorted(set(affected)), "ci_paths": sorted(set(trusted))}


def function_identity(identity):
    # Only Swift Testing parameters expand a statically declared function.
    if identity["kind"] == "swift":
        key = identity["key"]
        if key.startswith("immichSlidesTests/"):
            owner, separator, name = key.removeprefix("immichSlidesTests/").rpartition("/")
            signature = re.fullmatch(r"(`[^`]+`|[^()`]+)\([^()]*\)", name)
            require(signature is not None, "unsupported official Swift function identity")
            key = owner + separator + signature[1].strip("`")
        return dict(identity, key=key, dimensions={key: value for key, value in identity["dimensions"].items() if key != "parameter"})
    return identity


def identity_label(identity):
    dimensions = ", ".join(f"{key}={value}" for key, value in sorted(identity["dimensions"].items()))
    return identity["key"] + (f" ({dimensions})" if dimensions else "")


def tokens(identities, *, functions=False):
    result = {}
    for identity in identities:
        validate_test_identity(identity)
        normalized = function_identity(identity) if functions else identity
        token = identity_key(normalized)
        require(functions or token not in result, "duplicate trusted population identity")
        result[token] = normalized
    return result


def skip_matches(rule, identity, tier, environment):
    return (rule["tier"] == tier and rule["environment"] == environment and rule["kind"] == identity["kind"]
            and fnmatch.fnmatchcase(identity["key"], rule["key_pattern"])
            and rule["dimensions"] == identity["dimensions"])


def tier_approved(policy, tier):
    return any(record["tier"] == tier for record in policy["approval_records"])


def expected_skip_verdict(entry, rules, *, tier, environment):
    identity = entry["identity"]
    matches = [rule for rule in rules if skip_matches(rule, identity, tier, environment)]
    if len(matches) > 1:
        return False, f"ambiguous expected skip: {identity_label(identity)}"
    if matches:
        if entry["outcome"] == "skipped" and entry["attempts"][0]["reason"] == matches[0]["reason"]:
            return True, None
        return False, f"expected skip ran or reason differed: {identity_label(identity)}"
    return False, None


def evaluate_population(raw, expected, policy, *, environment):
    """Compare one producer's declared, compiled and executed populations.

    Proposed exceptions stay inactive. All discrepancies are retained by identity.
    A legacy unverified result can pass only when matching skips explain it fully.
    Deselections never excuse a missing compiled declaration.
    """
    result = {"status": "failed", "errors": [], "expected_skips": [], "deselected": [],
              "missing_compiled": [], "missing_executed": []}
    try:
        summary = parse_summary(raw)
        policy = parse_policy(policy)
        expected_by_function = tokens(expected, functions=True)
        tokens(expected)
        require(bool(expected_by_function), "empty expected population")
        population = summary["population"]
        declared = tokens(population["declared"], functions=True)
        compiled = tokens(population["compiled"])
        compiled_functions = tokens(population["compiled"], functions=True)
        observed = {identity_key(entry["identity"]): entry for entry in population["observed"]}
        deselected = {identity_key(entry["identity"]): entry for entry in population["deselected"]}
        tier = summary["run"]["tier"]
        approved = tier_approved(policy, tier)
        skips = policy["expected_skips"] if approved else []
        deselections = policy["deselections"] if approved else []
        errors = result["errors"]
        for label, actual in (("declared", declared), ("compiled", compiled_functions)):
            for token in sorted(set(expected_by_function) - set(actual)):
                identity = expected_by_function[token]
                errors.append(f"missing {label}: {identity_label(identity)}")
                if label == "compiled":
                    result["missing_compiled"].append(identity)
            for token in sorted(set(actual) - set(expected_by_function)):
                errors.append(f"unexpected {label}: {identity_label(actual[token])}")
        for token, entry in deselected.items():
            identity = entry["identity"]
            label = identity_label(identity)
            matches = [rule for rule in deselections if rule["tier"] == tier and rule["environment"] == environment
                       and rule["identity"] == identity]
            if len(matches) != 1 or any(entry[key] != matches[0][key] for key in ("reason", "owning_tier")):
                errors.append(f"unapproved or mismatched deselection: {label}")
            else:
                result["deselected"].append(entry)
            if token not in compiled or token in observed:
                errors.append(f"deselection is not exclusively compiled and unexecuted: {label}")
        for rule in deselections:
            if rule["tier"] == tier and rule["environment"] == environment:
                token = identity_key(rule["identity"])
                if identity_key(function_identity(rule["identity"])) in expected_by_function and token not in deselected:
                    errors.append(f"required deselection missing: {identity_label(rule['identity'])}")
        for token, identity in compiled.items():
            if token not in observed and token not in deselected:
                errors.append(f"missing executed: {identity_label(identity)}")
                result["missing_executed"].append(identity)
        for token, entry in observed.items():
            identity = entry["identity"]
            label = identity_label(identity)
            parent = identity_key(function_identity(identity))
            if token not in compiled and not (identity["kind"] == "swift" and "parameter" in identity["dimensions"]
                                               and parent in compiled_functions):
                errors.append(f"observed without compilation: {label}")
            expected_skip, skip_error = expected_skip_verdict(entry, skips, tier=tier, environment=environment)
            if skip_error:
                errors.append(skip_error)
            elif expected_skip:
                result["expected_skips"].append(identity)
            elif entry["outcome"] != "passed":
                errors.append(f"{entry['outcome']}: {label}")
        for entry in summary["infrastructure"]:
            category = NON_INFRASTRUCTURE_DIAGNOSTICS.get(entry["code"], "Infrastructure").lower()
            errors.append(f"{category} {entry['code']}: {entry['message']}")
        if summary["status"] == "failed" or (summary["status"] == "unverified" and not result["expected_skips"]):
            errors.append(f"producer status is {summary['status']}")
        result["status"] = "failed" if errors else "passed"
    except (ContractError, TypeError, KeyError, ValueError) as error:
        result["errors"].append(f"invalid evidence: {error}")
    return result
