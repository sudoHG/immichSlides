"""Fail-closed coverage and gate decisions; no publishing or GitHub operations.

Trusted consumers supply admitted tree populations, changed paths and policies.
Producer claims never select those inputs or grant approval.
"""

from __future__ import annotations

import fnmatch
from pathlib import PurePosixPath

from ci_summary import (ContractError, NON_INFRASTRUCTURE_DIAGNOSTICS, decode, fields, identity_key, integer, parse_identity,
                        parse_summary, require, sha, string, validate_test_identity)
from ci_population import removed_tests


def parse_policy(raw):
    policy = decode(raw)
    fields(policy, {"schema_version", "approval_state", "expected_skips", "deselections"}, "test policy")
    require(type(policy["schema_version"]) is int and policy["schema_version"] == 1, "unsupported test policy version")
    require(policy["approval_state"] in {"proposed", "approved"}, "invalid policy approval state")
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


def select_policy(base_policy, candidate_policy, admission_identity, approved_head):
    admission = parse_identity(admission_identity)
    base = parse_policy(base_policy)
    approved = admission["event"] == "pull_request" and approved_head == admission["head_sha"]
    return (parse_policy(candidate_policy), True) if approved and candidate_policy is not None else (base, False)


def function_identity(identity):
    # Only Swift Testing parameters expand a statically declared function.
    if identity["kind"] == "swift":
        return dict(identity, dimensions={key: value for key, value in identity["dimensions"].items() if key != "parameter"})
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
        approved = policy["approval_state"] == "approved"
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
            if token not in compiled:
                errors.append(f"observed without compilation: {label}")
            matches = [rule for rule in skips if skip_matches(rule, identity, tier, environment)]
            if len(matches) > 1:
                errors.append(f"ambiguous expected skip: {label}")
            elif matches:
                if entry["outcome"] == "skipped" and entry["attempts"][0]["reason"] == matches[0]["reason"]:
                    result["expected_skips"].append(identity)
                else:
                    errors.append(f"expected skip ran or reason differed: {label}")
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


def job_key(job):
    return (job["tier"], job["job"], job["shard"])


def admitted_population(record, tree_sha):
    fields(record, {"tree_sha", "identities"}, "expected population")
    sha(record["tree_sha"])
    require(record["tree_sha"] == tree_sha, "expected population differs from admitted tree SHA")
    require(isinstance(record["identities"], list), "expected population identities must be an array")
    tokens(record["identities"])
    return record["identities"]


def evaluate_gate(summaries, *, expected, admission_identity, required_jobs, base_policy,
                  environment, candidate_policy=None, approved_head=None, fork_originated=None,
                  ci_changing=None, app_affected=None, context="gate", base_population=None,
                  allowed_events=("pull_request", "push")):
    """Evaluate admitted summaries using trusted inputs; publishing belongs elsewhere.

    required_jobs describe tier/job/shard, run_id/attempt, supported workflow_paths
    and independently derived expected records {tree_sha, identities} for each job.
    Overall and per-job expected records must name admission_identity's tree_sha.
    For PRs admission_identity names the admitted merge/base/head/tree, not current main.
    base_population is a required PR record {base_sha, identities} from that base.
    No summary is used to determine classification, approval, provenance or policy.
    """
    result = {"status": "failed", "errors": [], "approval_based": False, "self_reported": fork_originated,
              "source": admission_identity, "expected_skips": [], "deselected": [], "removed_by_pr": []}
    try:
        admission = parse_identity(admission_identity)
        expected = admitted_population(expected, admission["tree_sha"])
        require(admission["event"] in allowed_events, "event is not admitted by this consumer")
        require(admission["event"] != "local" or not admission["dirty"], "dirty local identity cannot prove the tested tree")
        require(type(fork_originated) is bool and type(ci_changing) is bool and type(app_affected) is bool,
                "trusted classification must be explicit booleans")
        require(context in {"gate", "ui"}, "unsupported verdict context")
        approved = admission["event"] == "pull_request" and approved_head == admission["head_sha"]
        if (fork_originated or ci_changing) and admission["event"] == "pull_request" and not approved:
            result["errors"].append("exact PR head approval is required")
        elif fork_originated and admission["event"] != "pull_request":
            result["errors"].append("fork source requires a PR admission")
        elif ci_changing and admission["event"] == "local":
            result["errors"].append("local evaluation cannot authorize CI changes")
        policy, candidate_selected = select_policy(base_policy, candidate_policy, admission, approved_head)
        result["approval_based"] = approved and (fork_originated or ci_changing or candidate_selected)
        result["removed_by_pr"] = (removed_tests(base_population, expected, base_sha=admission["base_sha"])
                                   if admission["event"] == "pull_request" else [])
        if context == "ui" and not app_affected:
            require(not ci_changing, "CI-trusted changes cannot be not applicable")
            result["status"] = "failed" if result["errors"] else "not-applicable"
            return result
        require(bool(required_jobs), "required job set is empty")
        jobs = {}
        for job in required_jobs:
            fields(job, {"tier", "job", "shard", "run_id", "attempt", "workflow_paths", "expected"}, "required job")
            integer(job["attempt"], 1, "required attempt")
            require(isinstance(job["workflow_paths"], list) and bool(job["workflow_paths"]), "supported workflow paths required")
            require(job_key(job) not in jobs, "duplicate required job")
            job_expected = admitted_population(job["expected"], admission["tree_sha"])
            jobs[job_key(job)] = dict(job, expected=job_expected)
        scheduled = [identity for job in jobs.values() for identity in job["expected"]]
        require(set(tokens(scheduled, functions=True)) == set(tokens(expected, functions=True)),
                "required-job population differs from tested tree")
        parsed = [parse_summary(raw) for raw in summaries]
        seen, declared, compiled = set(), [], []
        for summary in parsed:
            key = job_key(summary["run"])
            require(key in jobs and key not in seen, "unexpected or duplicate job artifact")
            seen.add(key)
            job = jobs[key]
            require(summary["identity"] == admission, "producer differs from admitted identity (base moved or wrong tree)")
            require(summary["source"]["workflow_path"] in job["workflow_paths"], "unsupported workflow path")
            require(summary["source"]["fork_originated"] == fork_originated, "fork source mismatch")
            require(summary["run"]["id"] == job["run_id"] and summary["run"]["attempt"] == job["attempt"], "wrong run or attempt")
            population = summary["population"]
            coverage = evaluate_population(summary, job["expected"], policy, environment=environment)
            result["errors"].extend(coverage["errors"])
            result["expected_skips"].extend(coverage["expected_skips"])
            result["deselected"].extend(coverage["deselected"])
            declared.extend(population["declared"])
            compiled.extend(population["compiled"])
        require(seen == set(jobs), "missing required job/artifact (failed or cancelled job)")
        require(set(tokens(declared, functions=True)) == set(tokens(expected, functions=True)), "aggregate declared population differs from tested tree")
        require(set(tokens(compiled, functions=True)) == set(tokens(expected, functions=True)), "aggregate compiled population differs from tested tree")
        # Repeated compiled identities in separate device shards are legitimate; each
        # shard still has to account for every one of its own compiled identities.
        result["status"] = "failed" if result["errors"] else "passed"
    except (ContractError, TypeError, KeyError, ValueError) as error:
        result["errors"].append(f"invalid evidence: {error}")
    return result
