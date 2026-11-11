#!/usr/bin/env python3
"""Main-only CI reporting, daily history and idempotent failure issue lifecycle."""

from __future__ import annotations

import copy
import argparse
import hashlib
import http.client
import json
import os
import re
import time
import zipfile
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from ci_summary import (ARCHIVE_DOWNLOAD_FAILURES, ContractError, decode, identity_key, markdown_text, parse_identity,
                        parse_summary, require, validate_observation, validate_test_identity,
                        NON_INFRASTRUCTURE_DIAGNOSTICS, observation, test_identity, validate_nightly_retry, render_nightly_retry,
                        nightly_retry_outcome, public_retry_failure, render_retry_failure, validate_retry_failure,
                        parse_nightly_summary, fallback_nightly_retry)
from ci_publish import GitHub

REPORT_PATH = ".github/workflows/ci-report.yml"
NIGHTLY_PATH = ".github/workflows/ci-nightly.yml"
PRODUCER_PATHS = (".github/workflows/ci-gate.yml", ".github/workflows/ci-ui.yml", NIGHTLY_PATH)
LABEL = "ci-reported-failure"
MARKER = "<!-- ci-report-state:"
SECTION = "\n\n<!-- ci-report-managed -->\n"
FAILURES = {"failed", "crashed", "timed-out"}
NIGHTLY_INFRASTRUCTURE = {"kind": "host", "key": "Nightly infrastructure", "dimensions": {}}
EVIDENCE_DAYS = 7
ENVIRONMENT_YELLOW_NIGHTS_BEFORE_RED = 2
REQUEST_BUDGET = 150
EARLY_FAILURE_REASONS = {"identity-collection-failed", "hosted-runner-disconnected"}
# Reader-only; remove after the last pre-retirement night leaves seven-day retention (2026-10-24).
HISTORICAL_STRICT_SELECTORS = {
    ("ios", "server-switch-display"):
        "immichSlidesUITests/StrictE2EFilterIOSUITests/testServerSwitchDropsOldFiltersAndDisplayPolicyAppliesImmediately",
    ("tvos", "tvos-server-switch-display"):
        "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSServerSwitchDropsOldFiltersAndDisplayPolicyAppliesImmediately",
}


class RateLimitLow(RuntimeError):
    """Stop before exhausting the shared token's API allowance."""


class EvidenceExpired(ContractError):
    """Expired artifacts cannot change a previously verified report."""


class FixtureSourceDrift(ContractError):
    """Fixture hashes require the tested source to match the trusted reader."""


class ReportGitHub(GitHub):
    def __init__(self, repository, token, *, dry_run=False):
        self.request_count, self.remaining, self.rate_limit, self.dry_run = 0, None, 1000, dry_run
        self.binary_cache = {}
        self.artifact_sizes = {}
        self.diagnostic_nightly = False
        super().__init__(repository, token, response_headers=self.check_headers)

    def annotations(self, check_id):
        # Reuse the existing bounded GET retry policy only for annotation reads.
        previous = self.retry_reads
        self.retry_reads = True
        try:
            return self.pages(f"check-runs/{check_id}/annotations")
        finally:
            self.retry_reads = previous

    def check_headers(self, headers):
        remaining = headers.get("X-RateLimit-Remaining")
        if remaining is not None:
            self.remaining = int(remaining)
        limit = headers.get("X-RateLimit-Limit")
        if limit is not None:
            self.rate_limit = int(limit)
            require(self.rate_limit > 0, "invalid API quota")

    def budget_exhausted(self):
        return self.request_count >= REQUEST_BUDGET or self.remaining is not None and self.remaining <= (self.rate_limit + 1) // 2

    def _request(self, path, **options):
        if self.retry_reads and self._request_attempts:
            if self.budget_exhausted():
                raise RateLimitLow("API budget reserve reached")
            self.request_count += 1
        self._request_attempts += 1
        return super()._request(path, **options)

    def request(self, path, *, method="GET", **options):
        require(not self.dry_run or method == "GET", "dry-run refuses every API write")
        if method == "GET" and options.get("binary") and path in self.binary_cache:
            return self.binary_cache[path]
        if self.budget_exhausted():
            raise RateLimitLow("API budget reserve reached")
        self.request_count += 1
        self._request_attempts = 0
        try:
            result = super().request(path, method=method, **options)
        except ContractError:
            if self.budget_exhausted():
                raise RateLimitLow("API budget reserve reached") from None
            raise
        if method == "GET" and options.get("binary"):
            self.binary_cache = {path: result}
        match = re.search(r"/actions/runs/([1-9][0-9]*)/artifacts(?:\?|$)", path)
        if match and isinstance(result, dict) and "artifacts" in result:
            sizes = self.artifact_sizes.setdefault(int(match[1]), {})
            for artifact in result["artifacts"]:
                require(type(artifact["size_in_bytes"]) is int and artifact["size_in_bytes"] >= 0, "invalid artifact size")
                sizes[artifact["id"]] = artifact["size_in_bytes"]
        return result


def historical_strict_population(summary):
    """Bind retired identities to the night's tested matrix, never the current runner."""
    import subprocess
    commit = summary["identity"]["commit_sha"]
    try:
        tree = subprocess.check_output(["git", "rev-parse", commit + "^{tree}"], timeout=30).decode().strip()
        matrix = subprocess.check_output(["git", "show", commit + ":scripts/nightly-matrix.json"], timeout=30)
    except (OSError, subprocess.SubprocessError):
        raise ContractError("historical nightly tested source unavailable") from None
    require(tree == summary["identity"]["tree_sha"], "historical nightly tree differs from tested commit")
    require(hashlib.sha256(matrix).hexdigest() == summary["hashes"]["manifests"]["nightly-matrix"],
            "historical nightly matrix hash differs from tested source")
    return {identity_key(case) for case in decode(matrix.decode("utf-8"))["cases"]}


def method_observations(raw, trace, *, runner_hosted=False, verified_cases=None, review_bindings=None):
    summary = parse_nightly_summary(raw)
    population = summary["population"]
    phases = trace["warm"]
    discarded = set()
    from strict_e2e_p2_contract import P2_CASES
    bound_reviews = None if review_bindings is None else {identity_key(item["identity"]) for item in review_bindings}
    for index, row in enumerate(population["observed"]):
        backup = row.get("nightly_retry_first")
        supplemental = row.get("retry_failure")
        key = identity_key(row["identity"])
        pending_retry = ("nightly_retry" in row and row["outcome"] == "needs-human-review"
                         and row["identity"]["dimensions"]["suite"] in P2_CASES)
        if bound_reviews is not None and key not in bound_reviews and pending_retry:
            population["observed"][index] = fallback_nightly_retry(row)
            discarded.add(key)
            continue
        if backup is None and supplemental is None and not pending_retry:
            if len(row["attempts"]) == 1:
                discarded.add(key)
            continue
        scoped = {**summary, "population": {**population,
            "declared": [item for item in population["declared"] if identity_key(item) == key], "observed": [row]}}
        try:
            methods, missing = _method_observations(scoped, trace, runner_hosted=runner_hosted)
            field = "nightly_retry" if "nightly_retry" in row else "retry_failure"
            require(not missing and any(field in method for method in methods), "retry evidence is incomplete")
        except (ValueError, TypeError, KeyError, AttributeError, IndexError):
            discarded.add(key)
            if "nightly_retry" in row:
                population["observed"][index] = fallback_nightly_retry(row)
            else:
                row.pop("retry_failure")
    if discarded:
        phases = [{key: value for key, value in phase.items() if key != "retry"}
                  if identity_key(phase["identity"]) in discarded else phase for phase in phases]
    result = _method_observations(summary, {**trace, "warm": phases}, runner_hosted=runner_hosted)
    if verified_cases is not None:
        verified_cases.update({identity_key(row["identity"]): row for row in population["observed"]})
    return result


def _method_observations(raw, trace, *, runner_hosted=False):
    """A suite result never substitutes for an officially exported method result."""
    from run_strict_e2e import CommandError, FILTER_PERSON_SESSIONS, resolve_suite_selector
    from strict_e2e_p2_contract import P2_CASES
    summary = parse_summary(raw)
    phases = {identity_key(item["identity"]): item for item in trace["warm"]}
    require(len(phases) == len(trace["warm"]), "duplicate nightly case trace")
    observed, missing = [], []
    historical_cases = None
    compiled = {identity_key(item) for item in summary["population"]["compiled"]}
    outcomes = {identity_key(item["identity"]): item["outcome"] for item in summary["population"]["observed"]}
    case_records = {identity_key(item["identity"]): item for item in summary["population"]["observed"]}
    failed_count = sum(method.get("result") == "Failed" for phase in trace["warm"] for method in phase.get("official_methods", []))
    for case in summary["population"]["declared"]:
        case_record = case_records.get(identity_key(case), {})
        dimensions = case["dimensions"]
        suite = dimensions["suite"]
        platform = "tvos" if dimensions["device"] == "tv" else "ios"
        if suite == "filter-person":
            selectors = [item["selector"] for item in FILTER_PERSON_SESSIONS]
        else:
            try:
                selectors = [resolve_suite_selector(platform, suite)]
            except CommandError as error:
                historical_selector = HISTORICAL_STRICT_SELECTORS.get((platform, suite))
                if historical_selector is None or str(error) != f"Unknown strict E2E suite: {suite}.":
                    raise
                if historical_cases is None:
                    historical_cases = historical_strict_population(summary)
                if identity_key({"platform": platform, **dimensions}) not in historical_cases:
                    raise
                selectors = [historical_selector]
        wanted = {selector.split("/", 1)[1]: test_identity("strict", selector.split("/", 1)[1], **dimensions)
                  for selector in selectors}
        phase = phases.get(identity_key(case), {})
        methods = phase.get("official_methods", [])
        require(isinstance(methods, list), "invalid official method list")
        seen, counts = set(), Counter()
        for method in methods:
            from ci_failure_diagnostics import DIAGNOSTIC_FIELDS, FIRST_FAILURE_FIELD, FAILURE_MESSAGES_FIELD, validate_diagnostic_fields
            validate_diagnostic_fields({key: value for key, value in method.items() if key != FIRST_FAILURE_FIELD})
            require(set(method) == {"identifier", "result"} | ((DIAGNOSTIC_FIELDS | {FIRST_FAILURE_FIELD, FAILURE_MESSAGES_FIELD}) & method.keys()) and method["identifier"] in wanted
                    and method["identifier"] not in seen and method["result"] in {"Passed", "Failed", "Skipped"},
                    "unexpected or duplicate official method")
            seen.add(method["identifier"])
            counts[method["result"]] += 1
        if methods:
            official = phase["official_summary"]
            require(official["totalTestCount"] == len(methods) and official["passedTests"] == counts["Passed"]
                    and official["failedTests"] == counts["Failed"] and official["skippedTests"] == counts["Skipped"],
                    "official method counts differ from case")
            require(identity_key(case) in compiled, "official method case was not compiled")
        selected_retries = phase.get("retry_selected_methods", [phase.get("retry_method")])
        retry_records = {}
        if "retry" in phase:
            require(isinstance(selected_retries, list) and 0 < len(selected_retries) <= 3
                    and len(set(selected_retries)) == len(selected_retries)
                    and set(selected_retries) == {method["identifier"] for method in methods if method["result"] == "Failed"}
                    and set(selected_retries) <= set(phase.get("retry_assertion_methods", [])),
                    "nightly retry: selected original failed methods differ")
            for record in phase.get("retry_methods", []):
                validate_observation(record)
                key = record["identity"]["key"]
                require(key in selected_retries and key not in retry_records and record["identity"] == wanted[key],
                        "nightly retry: duplicate or unexpected method retry record")
                retry_records[key] = record
            require(not retry_records or set(retry_records) == set(selected_retries),
                    "nightly retry: incomplete method retry records")
        for method in methods:
            outcome = {"Passed": "passed", "Failed": "failed", "Skipped": "skipped"}[method["result"]]
            if outcome == "passed" and (phase.get("build_operations") != 0 or phase.get("products_unchanged") is not True
                    or phase.get("log_present") is not True or outcomes.get(identity_key(case)) not in {"passed", "needs-human-review"}
                    and not counts["Failed"]):
                outcome = "not-run"
            if outcome == "passed" and outcomes.get(identity_key(case)) == "needs-human-review":
                outcome = "needs-human-review"
            elif outcome == "passed" and suite in P2_CASES:
                outcome = "not-run"
            from ci_failure_diagnostics import unknown_diagnostics
            diagnostics = ({field: method[field] for field in DIAGNOSTIC_FIELDS}
                           if DIAGNOSTIC_FIELDS <= method.keys() else unknown_diagnostics())
            result = observation(wanted[method["identifier"]], outcome, 0,
                exit_code=phase.get("official_method_exit_codes", {}).get(method["identifier"], phase.get("exit_code")),
                reason="Official test was skipped" if outcome == "skipped" else None,
                failure_diagnostics=diagnostics if outcome == "failed" else None)
            if outcome == "failed" and FAILURE_MESSAGES_FIELD in method:
                result[FAILURE_MESSAGES_FIELD] = result["attempts"][0][FAILURE_MESSAGES_FIELD] = copy.deepcopy(method[FAILURE_MESSAGES_FIELD])
            from ci_failure_diagnostics import public_first_failure
            receipt = public_first_failure(method.get(FIRST_FAILURE_FIELD)) if outcome == "failed" else None
            if receipt is not None and receipt["source"] == "xctest":
                result[FIRST_FAILURE_FIELD] = result["attempts"][0][FIRST_FAILURE_FIELD] = copy.deepcopy(receipt)
            from ci_failure_diagnostics import environment_limit_evidence, VALIDATOR_FAILURE_FIELD
            claimed = case_record.get("environment_limit")
            if claimed is not None and outcome == "failed":
                if claimed["policy_version"] == 5 and suite == "filter-person":
                    from strict_e2e_runner_support import filter_person_first_attempt_complete
                    require(filter_person_first_attempt_complete(methods),
                            "environment limit requires a main-observable filter-person first attempt")
                require(not phase.get("infrastructure") and not phase.get("official_error")
                        and phase.get("exit_code") not in {124, 130} and phase.get("log_present") is True
                        and phase.get("build_operations") == 0 and phase.get("products_unchanged") is True
                        and (claimed["policy_version"] != 5 or not phase.get("automated_contract_failed")
                             and VALIDATOR_FAILURE_FIELD not in phase),
                        "environment limit cannot conceal strict invocation infrastructure")
                proof = environment_limit_evidence(summary, result,
                    phase.get("bounded_diagnostics", {}).get("case_resources", []), runner_hosted=runner_hosted,
                    policy_version=claimed["policy_version"])
                require(proof == claimed, "environment limit differs from official method or case resources")
                result["environment_limit"] = result["attempts"][0]["environment_limit"] = copy.deepcopy(proof)
            if "retry" in phase and method["identifier"] in selected_retries:
                method_claim = retry_records.get(method["identifier"])
                if "retry_failure" in case_record:
                    result["retry_failure"] = bind_strict_retry_failure(result, phase, case_record, failed_count, method_claim)
                else:
                    result = strict_retry_observation(result, phase, case_record,
                        wanted, failed_count, runner_hosted=runner_hosted, method_claim=method_claim)
                if "nightly_retry" in case_record:
                    require(result.get("nightly_retry") == case_record["nightly_retry"]
                            and result["outcome"] == case_record["outcome"] and phase["retry"].get("exit_code") == 0,
                            "nightly retry: strict case proof differs from verified methods")
            observed.append(result)
        if "retry" in phase or "nightly_retry" in case_record or "retry_failure" in case_record:
            require("retry" in phase and set(selected_retries) <= seen,
                    "nightly retry: selected original failed method is missing")
        missing.extend({"identity": wanted[key], "reason": "official-method-not-observed"} for key in sorted(wanted.keys() - seen))
        case_outcome = outcomes.get(identity_key(case))
        if case_outcome in FAILURES and not counts["Failed"]:
            contract_failed = (phase.get("automated_contract_failed") is True and seen == wanted.keys()
                and counts["Passed"] == len(wanted) and not phase.get("infrastructure")
                and not phase.get("official_error") and phase.get("exit_code") not in {124, 130}
                and phase.get("log_present") is True and phase.get("build_operations") == 0
                and phase.get("products_unchanged") is True)
            if contract_failed:
                failure = observation(case, case_outcome, 0, exit_code=phase.get("exit_code"), reason="strict-case-contract-failed")
                from ci_failure_diagnostics import VALIDATOR_FAILURE_FIELD, public_validator_failure_message
                if case_outcome == "failed" and VALIDATOR_FAILURE_FIELD in phase:
                    message = public_validator_failure_message(phase[VALIDATOR_FAILURE_FIELD])
                    failure[VALIDATOR_FAILURE_FIELD] = failure["attempts"][0][VALIDATOR_FAILURE_FIELD] = message
                from ci_failure_diagnostics import FIRST_FAILURE_FIELD, public_first_failure
                receipt = public_first_failure(phase.get(FIRST_FAILURE_FIELD))
                if receipt is not None and receipt["source"] == "validator":
                    failure[FIRST_FAILURE_FIELD] = failure["attempts"][0][FIRST_FAILURE_FIELD] = copy.deepcopy(receipt)
                observed.append(failure)
            else:
                missing.append({"identity": case, "reason": "strict-case-infrastructure-or-unverified-failure"})
        elif (case_outcome in {"passed", "needs-human-review"} and seen == wanted.keys()
              and counts["Passed"] == len(wanted) and phase.get("build_operations") == 0
              and phase.get("products_unchanged") is True and phase.get("log_present") is True):
            observed.append(observation(case, case_outcome, 0, exit_code=phase.get("exit_code")))
    return observed, missing


def bind_strict_retry_failure(first, phase, case, failed_count, method_claim):
    """Bind the supplemental failure while leaving the original v5 evidence intact."""
    retry = phase["retry"]
    claimed = case.get("retry_failure")
    require(claimed is not None and 1 <= failed_count <= 3 and phase.get("retry_failed_case_count") == failed_count
            and retry.get("identity") == phase["identity"] and retry.get("exit_code") == claimed["exit_code"]
            and retry.get("duration_seconds") == claimed["duration_seconds"],
            "retry failure: strict case evidence differs")
    methods = retry.get("official_methods", [])
    require(retry.get("exit_code") != 0 or retry.get("automated_contract_failed") or not retry.get("log_present")
            or retry.get("retry_collection_failed") is True
            or retry.get("build_operations") != 0 or retry.get("products_unchanged") is not True
            or any(method.get("result") != "Passed" for method in methods),
            "retry failure: strict retry completed successfully")
    if method_claim is None:
        return copy.deepcopy(claimed)
    key = first["identity"]["key"]
    require(method_claim["outcome"] == "failed" and len(method_claim["attempts"]) == 2
            and method_claim["attempts"][0]["outcome"] == "failed",
            "retry failure: strict retry method is not nonpassing")
    attempt = public_retry_failure(method_claim["attempts"][1])
    selected = [method for method in methods if method.get("identifier") == key]
    require(len(selected) == 1 and attempt["exit_code"] == claimed["exit_code"]
            and retry.get("official_method_durations", {}).get(key) == attempt["duration_seconds"]
            and (selected[0].get("result") != "Failed" or attempt["outcome"] == "failed")
            and ("failure_messages" not in attempt or attempt["failure_messages"] == selected[0].get("failure_messages")),
            "retry failure: strict method evidence differs")
    validate_retry_failure({**first, "retry_failure": attempt})
    return copy.deepcopy(attempt)


def strict_retry_observation(first, phase, case, wanted, failed_count, *, runner_hosted, method_claim=None):
    """Independently bind the filtered retry to both official method exports."""
    from ci_summary import duration
    from ci_flaky import ASSERTION_FAILURE, merge_retry
    from ci_failure_diagnostics import DIAGNOSTIC_FIELDS
    retry = phase["retry"]
    key = first["identity"]["key"]
    target = method_claim or case
    proof = target.get("nightly_retry")
    require(runner_hosted and 1 <= failed_count <= 3 and phase.get("retry_failed_case_count") == failed_count
            and key in phase.get("retry_assertion_methods", []) and first["outcome"] == "failed"
            and first["attempts"][0]["exit_code"] == 65
            and retry.get("identity") == phase["identity"] and len(target["attempts"]) == 2
            and (proof is None or proof["failed_case_count"] == failed_count),
            "nightly retry: original assertion, selection or failed count differs")
    require(not phase.get("infrastructure") and not phase.get("official_error")
            and not phase.get("automated_contract_failed") and phase.get("log_present") is True
            and phase.get("build_operations") == 0 and phase.get("products_unchanged") is True
            and phase.get("exit_code") == 65, "nightly retry: original invocation evidence differs")
    try:
        duration(phase.get("official_method_durations", {}).get(key))
    except ContractError as error:
        raise ContractError("nightly retry: unknown official method duration") from error
    first["duration_seconds"] = first["attempts"][0]["duration_seconds"] = phase["official_method_durations"][key]
    first["attempts"][0]["reason"] = ASSERTION_FAILURE
    first["attempts"][0]["message"] = "; ".join(first.get("failure_messages", [])) or phase.get("official_summary", {}).get("message")
    if target["outcome"] == "failed" and proof is None:
        # Missing retry exports remain red while preserving the verified original method failure.
        attempt = copy.deepcopy(target["attempts"][1])
        second = {"identity": first["identity"], "outcome": attempt["outcome"],
                  "duration_seconds": attempt["duration_seconds"], "attempts": [{**attempt, "number": 1}]}
        for field in ("failure_phase", "failure_class", "failure_messages", "first_failure", "validator_failure_message"):
            if field in attempt:
                second[field] = copy.deepcopy(attempt[field])
        return merge_retry(first, second)
    methods = retry.get("official_methods", [])
    counts = Counter(item.get("result") for item in methods)
    official = retry.get("official_summary") or {}
    require(len(methods) == len(wanted) and {item.get("identifier") for item in methods} == set(wanted)
            and official.get("totalTestCount") == len(methods)
            and all(official.get(field) == counts[outcome] for field, outcome in
                    (("passedTests", "Passed"), ("failedTests", "Failed"), ("skippedTests", "Skipped"))),
            "nightly retry: official retry methods or counts differ")
    for current in (phase, retry):
        require(not current.get("infrastructure") and not current.get("official_error")
                and not current.get("automated_contract_failed") and current.get("log_present") is True
                and current.get("build_operations") == 0 and current.get("products_unchanged") is True,
                "nightly retry: invocation infrastructure or warm reuse differs")
        seconds = current.get("official_method_durations", {}).get(key)
        try:
            duration(seconds)
        except ContractError as error:
            raise ContractError("nightly retry: unknown official method duration") from error
    require(phase.get("exit_code") == 65, "nightly retry: first invocation did not fail with an assertion")
    selected = next(item for item in methods if item["identifier"] == key)
    outcome = {"Passed": "passed", "Failed": "failed", "Skipped": "skipped"}.get(selected["result"])
    require(outcome is not None, "nightly retry: unsupported retry result")
    passing = target["outcome"] in {"flaky-passed", "needs-human-review"}
    retry_exit = retry.get("official_method_exit_codes", {}).get(key, retry.get("exit_code"))
    if passing:
        require(proof is not None and retry_exit == 0 and selected["result"] == "Passed"
                and (retry.get("exit_code") == 0 or retry.get("exit_code") == 65 and counts["Failed"] > 0),
                "nightly retry: passing claim differs from retry evidence")
        from strict_e2e_p2_contract import P2_CASES, RAW_VERDICT
        if first["identity"]["dimensions"].get("suite") in P2_CASES:
            require(retry.get("p2_verdict") == RAW_VERDICT,
                    "nightly retry: P2 automated contract evidence is missing or invalid")
    else:
        require(proof is None and outcome != "passed", "nightly retry: missing passing proof or red retry outcome")
    if outcome == "passed" and target["outcome"] == "needs-human-review":
        outcome = "needs-human-review"
    diagnostics = {field: selected[field] for field in DIAGNOSTIC_FIELDS} if DIAGNOSTIC_FIELDS <= selected.keys() and outcome == "failed" else None
    second = observation(first["identity"], outcome, retry["official_method_durations"][key],
        exit_code=retry_exit, reason="Official test was skipped" if outcome == "skipped" else
        ASSERTION_FAILURE if outcome == "failed" else None, failure_diagnostics=diagnostics)
    for field in ("first_failure", "failure_messages"):
        if outcome == "failed" and field in selected:
            second[field] = second["attempts"][0][field] = copy.deepcopy(selected[field])
    merged = merge_retry(first, second, nightly_proof=proof)
    require(merged["outcome"] == target["outcome"], "nightly retry: method outcome differs from case")
    return merged


def iso_day(value):
    require(isinstance(value, str) and date.fromisoformat(value).isoformat() == value, "invalid UTC day")
    return value


def utc_timestamp(value):
    require(isinstance(value, str), "missing UTC timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None and parsed.utcoffset() == timedelta(0), "invalid UTC timestamp")
    return parsed


def reset_notification_point(api, reset):
    if not reset:
        return None
    owner = api.repository.split("/", 1)[0]
    require(reset["actor"] == owner, "untrusted history reset")
    iso_day(reset["day"])
    if not reset.get("created_at") and reset.get("run"):
        run_id = int(reset["run"])
        run = api.repo(f"actions/runs/{run_id}")
        require(run["id"] == run_id and run["path"] == REPORT_PATH and run["event"] == "workflow_dispatch"
                and run["head_branch"] == "main" and run["repository"]["full_name"] == api.repository
                and run["head_repository"]["full_name"] == api.repository
                and run["actor"]["login"] == run["triggering_actor"]["login"] == owner,
                "reset run provenance mismatch")
        require(utc_timestamp(run["created_at"]).date().isoformat() <= reset["day"], "reset run date mismatch")
        reset["created_at"] = run["created_at"]
    if reset.get("created_at"):
        require(utc_timestamp(reset["created_at"]).date().isoformat() <= reset["day"], "reset timestamp date mismatch")
    return reset.get("created_at")


def normalized_identity(identity):
    validate_test_identity(identity)
    result = copy.deepcopy(identity)
    # The UI registry owns one platform/method issue across device shards.
    if result["kind"] == "ui":
        result["dimensions"].pop("device", None)
    return result


def identity_token(identity):
    return hashlib.sha256(identity_key(normalized_identity(identity)).encode()).hexdigest()


def summary_diagnostics(summaries, evidence_errors=()):
    from ci_verdict import function_identity
    counts, failures, missing, infrastructure, skips, deselections = Counter(), [], [], list(evidence_errors), [], []
    for raw in summaries:
        summary = parse_summary(raw)
        population = summary["population"]
        declared = {identity_key(item): item for item in population["declared"]}
        compiled = {identity_key(item) for item in population["compiled"]}
        observed = {identity_key(item["identity"]): item for item in population["observed"]}
        deselected = {identity_key(item["identity"]) for item in population["deselected"]}
        compiled_functions = {identity_key(function_identity(item)) for item in population["compiled"]}
        observed_functions = {identity_key(function_identity(item["identity"])) for item in population["observed"]}
        deselected_functions = {identity_key(function_identity(item["identity"])) for item in population["deselected"]}
        counts.update(declared=len(declared), compiled=len(compiled), observed=len(observed), deselected=len(deselected))
        for token, item in declared.items():
            function = identity_key(function_identity(item))
            if function not in compiled_functions or function not in observed_functions and function not in deselected_functions:
                missing.append({"identity": item, "reason": "declared-not-compiled" if function not in compiled_functions else "not-observed"})
        for item in observed.values():
            counts[item["outcome"]] += 1
            if item["outcome"] in FAILURES or "nightly_retry" in item:
                failures.append(failure_details(item))
            elif item["outcome"] == "skipped":
                # Candidate error messages are never copied into issues or history.
                skips.append(item["identity"])
        deselections.extend(population["deselected"])
        infrastructure.extend(item["code"] for item in summary["infrastructure"]
                              if item["code"] not in NON_INFRASTRUCTURE_DIAGNOSTICS)
    return {"counts": dict(counts), "failures": failures, "missing": missing,
            "infrastructure": infrastructure, "skipped": skips, "deselected": deselections}


def cloud_pr_diagnostics(summaries, *, cloud):
    """PR diagnostics receive the proof already verified for this evaluation.

    Daily history remains main-push only. A cloud PR is never promoted into that
    history or the identical-tree reuse cache using an app check alone.
    """
    require(isinstance(cloud, dict) and isinstance(cloud.get("identities"), list), "verified cloud proof is missing")
    diagnostics = summary_diagnostics(summaries)
    count = len(cloud["identities"])
    for key in ("declared", "observed", "passed"):
        diagnostics["counts"][key] = diagnostics["counts"].get(key, 0) + count
    diagnostics["counts"]["compiled_not_exposed_by_api"] = count
    diagnostics["xcode_cloud"] = {key: value for key, value in cloud.items() if key != "identities"}
    if cloud.get("schema_version") == 2:
        diagnostics["xcode_cloud"]["groups"] = {
            group: {key: value for key, value in proof.items() if key != "identities"}
            for group, proof in cloud["groups"].items()}
    return diagnostics


def daily_rollup(day, entries):
    iso_day(day)
    selected = {}
    for entry in entries:
        require(entry["schema_version"] == 1, "unsupported report entry")
        if entry["day"] != day:
            continue
        source, run = entry["source"], entry["run"]
        require(source["workflow_path"] in PRODUCER_PATHS, "unknown report producer")
        require(type(run["id"]) is int and run["id"] > 0 and type(run["attempt"]) is int and run["attempt"] > 0,
                "invalid report run identity")
        for key in ("fork_originated", "ci_changing", "approval_based"):
            require(type(source[key]) is bool or key == "ci_changing" and source[key] is None, "invalid report source")
        key = (source["repository"], source["workflow_path"], run["id"])
        previous = selected.get(key)
        if previous and previous["run"]["attempt"] == run["attempt"]:
            require(previous == entry, "conflicting report for the same run attempt")
        if not previous or previous["run"]["attempt"] < run["attempt"]:
            selected[key] = copy.deepcopy(entry)
    return {"schema_version": 1, "day": day, "retention_days": 90,
            "entries": [selected[key] for key in sorted(selected)]}


def issue_decision(previous, identity, entries, *, registry_referenced):
    """Count verified nights, retain recent replay state, and respect manual closure."""
    from strict_e2e_p2_contract import P2_CASES
    state = copy.deepcopy(previous) if previous else {"schema_version": 1, "token": identity_token(identity),
             "identity": normalized_identity(identity), "nights": {}, "closed": False,
             "first_failure": None, "last_failure": None, "failure_nights": 0}
    require(state["schema_version"] == 1 and state["token"] == identity_token(identity), "wrong issue identity")
    previous_failed = set(state.get("recent_failure_days", [day for day, runs in state["nights"].items()
                          if any(item["outcome"] in {"failed", "flaky"} for item in runs.values())]))
    if state["last_failure"]:
        previous_failed.add(state["last_failure"])
    new_failure = False
    entries = environment_history(entries)
    deliveries = [attempt for report in entries if issue_eligible(report)
                  for attempt in report.get("attempt_history", [report]) if issue_eligible(attempt)]
    for entry in deliveries:
        if entry["source"]["workflow_path"] != NIGHTLY_PATH:
            continue
        matches = [item for item in entry["observed"] if identity_token(item["identity"]) == state["token"]]
        if identity == NIGHTLY_INFRASTRUCTURE:
            outcome = "failed" if entry["diagnostics"]["infrastructure"] else "passed" if entry["status"] == "passed" else "unverified"
            matches = [{"outcome": outcome}]
        day, key = iso_day(entry["day"]), str(entry["run"]["id"])
        old = state["nights"].get(day, {}).get(key)
        if not matches and not old:
            continue
        outcomes = {"failed" if item.get("environment_limit_escalation") or item.get("nightly_retry_rejection")
                    else "flaky" if "nightly_retry" in item
                    else "environment-limited" if "environment_limit" in item else item["outcome"] for item in matches}
        passes = {"passed"}
        if identity["kind"] == "strict" and identity["dimensions"].get("suite") in P2_CASES:
            passes.add("needs-human-review")
        outcome = ("failed" if outcomes & FAILURES else "passed" if outcomes and outcomes <= passes
                   else "flaky" if "flaky" in outcomes and outcomes <= {"flaky", "passed", "environment-limited"}
                   else "environment-limited" if outcomes == {"environment-limited"} else "unverified")
        if entry["diagnostics"]["infrastructure"] or entry["diagnostics"]["missing"]:
            if outcome == "passed":
                outcome = "unverified"
        night = state["nights"].setdefault(day, {})
        record = {"attempt": entry["run"]["attempt"], "outcome": outcome}
        if any("nightly_retry" in item for item in matches):
            record["nightly_retry"] = True
        if identity == NIGHTLY_INFRASTRUCTURE:
            reasons = (set(entry["diagnostics"]["infrastructure"])
                       | set((old or {}).get("archive_failure_reasons", []))) & ARCHIVE_DOWNLOAD_FAILURES
            if reasons:
                record["archive_failure_reasons"] = sorted(reasons)
            early = (set(entry["diagnostics"]["infrastructure"])
                     | set((old or {}).get("early_failure_reasons", []))) & EARLY_FAILURE_REASONS
            if early:
                record["early_failure_reasons"] = sorted(early)
        if old is None or old["attempt"] <= record["attempt"]:
            if outcome == "failed" and (old is None or old["outcome"] != "failed" or old["attempt"] < record["attempt"]):
                new_failure |= state["last_failure"] is None or day >= state["last_failure"]
            # A red first attempt cannot become an explicit-pass night by rerunning.
            if old and old["outcome"] in {"failed", "flaky"}:
                record["outcome"] = "failed" if "failed" in {old["outcome"], outcome} else "flaky"
                if old.get("nightly_retry") is True:
                    record["nightly_retry"] = True
            night[key] = record
    failed = sorted(day for day, runs in state["nights"].items() if any(item["outcome"] in {"failed", "flaky"} for item in runs.values()))
    if failed:
        state["first_failure"] = min(filter(None, [state["first_failure"], failed[0]]))
        state["last_failure"] = max(filter(None, [state["last_failure"], failed[-1]]))
        state["failure_nights"] += len(set(failed) - previous_failed)
    passes = sorted(day for day, runs in state["nights"].items() if state["last_failure"] and day > state["last_failure"]
                    and all(item["outcome"] == "passed" for item in runs.values()))
    state["explicit_pass_nights"] = passes[-3:]
    if not state["last_failure"]:
        return {"action": "none", "state": previous}
    if previous and previous["closed"] and not new_failure:
        return {"action": "none", "state": previous}
    newest = max(state["nights"], default=state["last_failure"])
    cutoff = (date.fromisoformat(newest) - timedelta(days=EVIDENCE_DAYS)).isoformat()
    state["recent_failure_days"] = sorted(day for day in previous_failed | set(failed) if day >= cutoff)
    state["nights"] = {day: runs for day, runs in state["nights"].items() if day >= state["last_failure"]
                       and (day >= cutoff or day == state["last_failure"] or day in state["explicit_pass_nights"])}
    should_close = len(passes) >= 3 and not registry_referenced
    state["closed"] = should_close
    if previous is None:
        action = "open"
    elif previous["closed"] and not should_close:
        action = "reopen"
    elif not previous["closed"] and should_close:
        action = "close"
    else:
        action = "update" if state != previous else "none"
    return {"action": action, "state": state}


def registry_checks(registry, day, issue_states):
    iso_day(day)
    checks = []
    for entry in registry["entries"]:
        remaining = (date.fromisoformat(entry["review_by"]) - date.fromisoformat(day)).days
        state = issue_states.get(int(entry["issue"].rsplit("/", 1)[-1]), "unknown")
        require(state in {"open", "closed", "missing", "unknown"}, "invalid registry issue state")
        status = "expired" if remaining < 0 else "review-due" if remaining <= 7 else "active"
        checks.append({"identity": entry["identity"], "issue": entry["issue"], "owner": entry["owner"],
                       "review_by": entry["review_by"], "expired": remaining < 0, "date_eligible": remaining >= 0,
                       "review_status": status, "days_until_review": remaining, "issue_state": state,
                       "age_days": (date.fromisoformat(day) - date.fromisoformat(entry["added_on"])).days if "added_on" in entry else None})
    return checks


def text(value):
    return markdown_text(value).replace("@", "&#64;").replace("[", "&#91;").replace("]", "&#93;")


def scrub_attempt_text(attempt, *, keep_assertion=False):
    from ci_flaky import ASSERTION_FAILURE
    reason = attempt.get("reason")
    if attempt.get("outcome") == "skipped":
        reason = "skip reason withheld; consult trusted policy"
    elif reason != "strict-case-contract-failed" and not (keep_assertion and reason == ASSERTION_FAILURE):
        reason = None
    attempt.update(reason=reason, message=None)


def scrub_report_attempts(record, *, retry_only=False):
    rows = [*record.get("observed", []), *record.get("diagnostics", {}).get("failures", [])]
    for row in rows:
        row.pop("nightly_retry_first", None)
        has_retry = "nightly_retry" in row
        if not retry_only or has_retry or "retry_failure" in row:
            attempts = row.get("attempts")
            if isinstance(attempts, list):
                for index, attempt in enumerate(attempts):
                    if isinstance(attempt, dict):
                        scrub_attempt_text(attempt, keep_assertion=has_retry and index == 0)


def failure_details(item):
    from ci_failure_diagnostics import FIRST_FAILURE_FIELD, VALIDATOR_FAILURE_FIELD, FAILURE_MESSAGES_FIELD
    details = {"identity": item["identity"], "outcome": item["outcome"],
               "exit_codes": [attempt["exit_code"] for attempt in item["attempts"]]}
    if VALIDATOR_FAILURE_FIELD in item:
        details[VALIDATOR_FAILURE_FIELD] = item[VALIDATOR_FAILURE_FIELD]
    if FIRST_FAILURE_FIELD in item:
        details[FIRST_FAILURE_FIELD] = copy.deepcopy(item[FIRST_FAILURE_FIELD])
    if "environment_limit" in item:
        details["environment_limit"] = copy.deepcopy(item["environment_limit"])
    if "nightly_retry" in item:
        details.update({key: copy.deepcopy(item[key]) for key in ("nightly_retry", "duration_seconds")})
        details["attempts"] = [{key: copy.deepcopy(attempt[key]) for key in
                                ("number", "outcome", "exit_code", "duration_seconds", "reason")}
                               for attempt in item["attempts"]]
        for index, attempt in enumerate(details["attempts"]):
            scrub_attempt_text(attempt, keep_assertion=index == 0)
    if "retry_failure" in item:
        details["duration_seconds"] = item["duration_seconds"]
        details["retry_failure"] = copy.deepcopy(item["retry_failure"])
        details["exit_codes"].append(item["retry_failure"]["exit_code"])
    if FAILURE_MESSAGES_FIELD in item:
        details[FAILURE_MESSAGES_FIELD] = copy.deepcopy(item[FAILURE_MESSAGES_FIELD])
        details.update({key: item[key] for key in ("failure_phase", "failure_class")})
    return details


def render_entry(entry):
    entry = environment_history([entry])[0]
    source, run, diagnostics = entry["source"], entry["run"], entry["diagnostics"]
    url = f"https://github.com/{source['repository']}/actions/runs/{run['id']}"
    lines = [f"## {text(source['workflow_path'])}: {entry['status']}", "",
             f"[Run {run['id']}, attempt {run['attempt']}]({url}); UTC day {entry['day']}.",
             f"Source: {text(source['repository'])}; {source['event']}; fork-originated: {source['fork_originated']}; "
             f"CI-changing: {source['ci_changing']}; approval-based: {source['approval_based']}.",
             "", "Counts: " + "; ".join(f"{key} {value}" for key, value in sorted(diagnostics["counts"].items())) + "."]
    if source["fork_originated"]:
        lines.append("Fork results are self-reported; approval is separate from test evidence.")
    if entry.get("not_evaluated_reason"):
        lines.append("Not evaluated: " + text(entry["not_evaluated_reason"]) + ".")
    lines += ["", "| Failing identity | Outcome | Exit codes | Validator failure |", "| --- | --- | --- | --- |"]
    lines.extend(f"| {text(identity_key(item['identity']))} | "
                 f"{'failed' if item.get('environment_limit_escalation') or item.get('nightly_retry_rejection') else nightly_retry_outcome(item) if 'nightly_retry' in item else 'failed (environment-limited; yellow)' if 'environment_limit' in item else item['outcome']} | {text(item['exit_codes'])} | "
                 f"{text(item['validator_failure_message']) if 'validator_failure_message' in item else '—'} |"
                 for item in diagnostics["failures"][:50])
    from ci_failure_diagnostics import FIRST_FAILURE_FIELD, render_first_failure
    lines.extend("\nFirst failure: " + text(identity_key(item["identity"])) + ": "
                 + text(render_first_failure(item[FIRST_FAILURE_FIELD])) + "."
                 for item in diagnostics["failures"][:50] if FIRST_FAILURE_FIELD in item)
    lines.extend("\nOfficial failures: " + text(identity_key(item["identity"])) + ": "
                 + "; ".join(text(message) for message in item["failure_messages"])
                 for item in diagnostics["failures"] if "failure_messages" in item)
    lines.extend("\n" + text(identity_key(item["identity"]) + ": " + render_retry_failure(item["retry_failure"]))
                 for item in diagnostics["failures"] if "retry_failure" in item)
    lines.extend(f"Missing evidence: {text(identity_key(item['identity']))}: {item['reason']}."
                 for item in diagnostics["missing"][:50])
    lines.extend(f"Infrastructure: {text(item)}." for item in diagnostics["infrastructure"])
    from ci_failure_diagnostics import render_environment_limit
    if any("environment_limit" in item and not item.get("environment_limit_escalation") for item in diagnostics["failures"]):
        category = ("timing or XCTest/Apple tool" if any(item.get("environment_limit", {}).get("kind") == "xctest-tool"
                    for item in diagnostics["failures"]) else "timing")
        lines.append(f"\n> **WARNING: hosted {category} failures are environment-limited (yellow), never passes.**")
    lines.extend("\nWARNING: " + text(identity_key(item["identity"])) + ": "
                 + text(render_environment_limit(item["environment_limit"]))
                 for item in diagnostics["failures"] if "environment_limit" in item and not item.get("environment_limit_escalation"))
    lines.extend("\nRED: " + text(identity_key(item["identity"])) + ": " + item["environment_limit_rejection"]
                 for item in diagnostics["failures"] if item.get("environment_limit_rejection"))
    lines.extend("\nRED: repeated environment limit: " + text(identity_key(item["identity"]))
                 + f"; {ENVIRONMENT_YELLOW_NIGHTS_BEFORE_RED} consecutive nights; normal failure tracking applies."
                 for item in diagnostics["failures"] if item.get("environment_limit_escalation"))
    lines.extend("\nWARNING: " + text(identity_key(item["identity"])) + ": " + text(render_nightly_retry(item))
                 for item in diagnostics["failures"] if "nightly_retry" in item and not item.get("environment_limit_escalation"))
    lines.extend("\nRED: " + text(identity_key(item["identity"])) + ": " + item["nightly_retry_rejection"]
                 for item in diagnostics["failures"] if item.get("nightly_retry_rejection"))
    if diagnostics.get("skipped"):
        lines.append("Skipped identities (policy acceptance recorded separately): " + text(diagnostics["skipped"][:50]))
    for item in diagnostics.get("deselected", [])[:50]:
        lines.append(f"Deselected: {text(identity_key(item['identity']))}; owned by {text(item['owning_tier'])}; {text(item['reason'])}.")
    if any(len(diagnostics.get(key, [])) > 50 for key in ("failures", "missing", "skipped", "deselected")):
        lines.append("Readable lists show the first 50 entries per category; the per-run JSON retains every identity.")
    return "\n".join(lines) + "\n"


def check_context(environment):
    require(environment.get("GITHUB_REF") == "refs/heads/main", "reporting requires main")
    require(environment.get("GITHUB_WORKFLOW_REF") == environment.get("GITHUB_REPOSITORY", "") + "/" + REPORT_PATH + "@refs/heads/main",
            "reporting requires its exact trusted workflow")
    require(environment.get("GITHUB_EVENT_NAME") in {"workflow_run", "workflow_dispatch", "schedule"}, "unsupported reporter event")


def on_main(revision):
    import subprocess
    from ci_publish_git import git
    from ci_summary import sha
    sha(revision)
    git("fetch", "--no-tags", "origin", "refs/heads/main")
    return subprocess.run(["git", "merge-base", "--is-ancestor", revision, "FETCH_HEAD"],
                          capture_output=True, timeout=30).returncode == 0


def report_base(run, repository):
    return {"schema_version": 1, "day": iso_day(run["created_at"][:10]),
            "run": {"id": run["id"], "attempt": run["run_attempt"]},
            "created_at": run["created_at"], "conclusion": run.get("conclusion"), "head_sha": run.get("head_sha"),
            "source": {"repository": repository, "workflow_path": run["path"], "event": run["event"],
                       "workflow_id": run["workflow_id"],
                       "fork_originated": run["head_repository"]["full_name"] != repository,
                       "ci_changing": None, "approval_based": False},
            "status": "pending" if run["status"] != "completed" else "unverified" if run.get("conclusion") == "cancelled" else "failed",
            "release_eligible": False, "observed": [], "diagnostics": summary_diagnostics([]),
            "diagnostic_shard": "unverified-dispatch-plan" if run["path"] == NIGHTLY_PATH and run["event"] == "workflow_dispatch" else None}


def nightly_skip_attempt(api, run, attempt, artifacts):
    """A skipped night is `not-run`: it carries no evidence for its source commit and is never a pass."""
    from ci_nightly_change import NO_CHANGE_REASON, RECORD_FILE, artifact_name, validate_record
    from ci_publish import json_member
    matches = [item for item in artifacts if item["name"] == artifact_name(run["id"], attempt)]
    if not matches:
        return None  # Runs before the change check, or a failed check that fell open to running.
    require(len(matches) == 1, "duplicate nightly change record")
    aggregate = f"nightly-aggregate-{run['id']}-{attempt}"
    if matches[0]["expired"]:
        if any(item["name"] == aggregate for item in artifacts):
            return None
        raise EvidenceExpired("nightly change record expired")
    raw = validate_record(json_member(api, matches[0], RECORD_FILE), repository=api.repository, run_id=run["id"],
                          attempt=attempt, event=run["event"], head_sha=run["head_sha"])
    if raw["decision"] != "skip":
        return None
    require(not any(item["name"] == aggregate or item["name"].startswith(("nightly-strict-", "nightly-ui-aggregate-"))
                    and item["name"].endswith(f"-{run['id']}-{attempt}") for item in artifacts),
            "skipped nightly has execution evidence")
    require(on_main(raw["baseline"]["sha"]), "skip baseline is outside main history")
    entry = report_base({**run, "run_attempt": attempt}, api.repository)
    entry.update(status="not-run", not_evaluated_reason=NO_CHANGE_REASON, diagnostic_shard=None)
    return entry


def dispatch_shard(api, run, attempt, artifacts):
    from ci_publish import json_member
    if run["event"] != "workflow_dispatch":
        return None
    matches = [item for item in artifacts if item["name"] == f"nightly-plan-{run['id']}-{attempt}"]
    require(len(matches) == 1 and not matches[0]["expired"], "nightly dispatch plan unavailable")
    plan = json_member(api, matches[0], "plan.json")
    identity = parse_identity(plan["identity"])
    require(plan["schema_version"] == 1 and plan["run"] == {"id": str(run["id"]), "attempt": attempt}
            and identity["repository"] == api.repository and identity["event"] == run["event"]
            and identity["commit_sha"] == run["head_sha"] and nightly_ref_allowed(api, run, identity)
            and plan["source"]["workflow_path"] == NIGHTLY_PATH and plan["source"]["fork_originated"] is False,
            "nightly dispatch plan provenance mismatch")
    shard = plan["diagnostic_shard"]
    require(shard is None or isinstance(shard, str) and bool(shard), "invalid diagnostic shard")
    return shard


def nightly_ref_allowed(api, run, identity):
    return identity["ref"] == "refs/heads/" + run["head_branch"] and (
        run["head_branch"] == "main" or getattr(api, "diagnostic_nightly", False)
        and getattr(api, "dry_run", False) and run["event"] == "workflow_dispatch")


def nightly_ui_attempt(api, run, attempt, artifacts, raw):
    import subprocess
    from ci_population import ui_identities
    from ci_nightly_ui import parse_ui_plan, read_ui_retry_tests, validate_ui_record
    from ci_publish import json_member
    from ci_ui_shards import DEVICES, MANIFEST_PATH, shard_populations
    from ci_verdict import identity_label
    from strict_e2e_server import fixture_manifest
    ui = raw["ui"]
    plan = parse_ui_plan(ui["plan"])
    require(plan["identity"] == raw["identity"] and plan["run"] == raw["run"], "UI aggregate differs from nightly identity")
    require(plan["source"] == {"repository": api.repository, "workflow_path": NIGHTLY_PATH, "event": run["event"],
                               "fork_originated": False, "ci_changing": None}, "nightly UI source binding differs")
    require(raw["source"] == {**plan["source"], "approval_based": False}
            and raw["source"]["approval_based"] is False, "nightly UI outer source binding differs")
    def tested_git(*arguments):
        try:
            return subprocess.check_output(["git", *arguments], timeout=30)
        except (OSError, subprocess.SubprocessError):
            raise ContractError("nightly UI tested source unavailable") from None
    def blob(path):
        return tested_git("show", run["head_sha"] + ":" + path)
    require(tested_git("rev-parse", run["head_sha"] + "^{tree}").decode().strip() == plan["identity"]["tree_sha"],
            "nightly UI tree differs from tested commit")
    if blob("scripts/strict_e2e_server.py") != Path(__file__).with_name("strict_e2e_server.py").read_bytes():
        raise FixtureSourceDrift("fixture-source-drift")
    sources = {}
    listing = tested_git("ls-tree", "-rz", "--full-tree", run["head_sha"], "--", "immichSlidesUITests")
    for entry in filter(None, listing.split(b"\0")):
        metadata, path = entry.split(b"\t", 1)
        mode, kind, _ = metadata.decode("ascii").split()
        path = path.decode("utf-8")
        require(path.startswith("immichSlidesUITests/"), "UI source lies outside the tested target")
        if path.endswith(".swift"):
            require(mode in {"100644", "100755"} and kind == "blob", "UI source is not a regular blob")
            sources[path] = blob(path).decode("utf-8")
    manifest = blob(MANIFEST_PATH)
    expected_shards, expected_hashes = [], {}
    for device, platform in DEVICES.items():
        test_plan = blob("immichSlides-" + ("iOS" if platform == "ios" else "tvOS") + ".xctestplan")
        populations = shard_populations(ui_identities(sources, platform), test_plan.decode(), manifest.decode(), device)
        expected_shards.extend({"device": device, "shard": shard, "declared": declared} for shard, declared in populations.items())
        expected_hashes[device] = {"ui-shards": hashlib.sha256(manifest).hexdigest(),
                                   "test-plan": hashlib.sha256(test_plan).hexdigest(),
                                   "fixture-c": fixture_manifest("c")["fixture_sha256"]}
    require(plan["shards"] == expected_shards, "nightly UI plan differs from tested default-plan population")
    require(all(plan["hashes"][device]["manifests"] == hashes for device, hashes in expected_hashes.items()),
            "nightly UI manifest hashes differ from tested source")
    matches = [item for item in artifacts if item["name"] == f"nightly-ui-aggregate-{run['id']}-{attempt}"]
    require(len(matches) == 1, "missing or duplicate nightly UI aggregate")
    if matches[0]["expired"]:
        raise EvidenceExpired("nightly UI aggregate expired")
    require(json_member(api, matches[0], "nightly-ui.json") == ui, "nightly UI aggregate binding differs")
    summaries, official_tests, retry_tests = [], {}, {}
    hosted_jobs = None
    for shard in plan["shards"]:
        name = f"ui-{shard['device']}-{shard['shard']}-{run['id']}-{attempt}"
        matches = [item for item in artifacts if item["name"] == name]
        require(len(matches) <= 1, "duplicate nightly UI shard")
        if not matches:
            continue
        if matches[0]["expired"]:
            raise EvidenceExpired("nightly UI shard expired")
        summary = parse_nightly_summary(json_member(api, matches[0], "summary.json"))
        require(summary["identity"] == plan["identity"] and summary["source"] == plan["source"]
                and summary["run"] == {**plan["run"], "tier": "ui", "job": "ui-" + shard["device"], "shard": shard["shard"]}
                and summary["hashes"] == plan["hashes"][shard["device"]], "nightly UI shard source binding differs")
        summaries.append(summary)
        environment = any("environment_limit" in item for item in summary["population"]["observed"])
        flaky = any("nightly_retry" in item for item in summary["population"]["observed"])
        failed_retry = any("retry_failure" in item for item in summary["population"]["observed"])
        if environment or flaky:
            from ci_publish import complete_attempt_jobs
            if hosted_jobs is None:
                hosted_jobs = complete_attempt_jobs(api, {**run, "run_attempt": attempt})
            matching = [job for job in hosted_jobs if job["name"] == f"ui-{shard['device']}-{shard['shard']}"]
            require(len(matching) == 1 and matching[0].get("runner_group_name") == "GitHub Actions"
                    and "self-hosted" not in matching[0].get("labels", []),
                    "environment limit requires a verified GitHub-hosted UI job" if environment else
                    "nightly retry: requires a verified GitHub-hosted UI job")
            official_tests[(shard["device"], shard["shard"])] = json_member(api, matches[0], "official-tests.json")
        if flaky or failed_retry:
            artifact = matches[0]
            retry_tests[(shard["device"], shard["shard"])] = read_ui_retry_tests(lambda name: json_member(api, artifact, name))
            if not (environment or flaky):
                try:
                    official_tests[(shard["device"], shard["shard"])] = json_member(api, artifact, "official-tests.json")
                except (ValueError, KeyError, TypeError, OSError):
                    pass  # An ordinary failed result does not depend on its optional retry receipt.
    values = {}
    for name, path in (("policy", "scripts/ci-test-policy.json"), ("registry", "scripts/ci-known-flaky.json")):
        content = blob(path)
        label = "test-policy" if name == "policy" else "known-flaky"
        require(all(hashes["policies"][label] == hashlib.sha256(content).hexdigest() for hashes in plan["hashes"].values()),
                "nightly UI policy differs from tested source")
        values[name] = decode(content.decode())
    verified = validate_ui_record(ui, summaries, **values, evaluated_on=date.fromisoformat(run["created_at"][:10]),
                                  official_tests=official_tests, retry_tests=retry_tests)
    require(raw["tiers"]["ui"] == ui["verdict"]["status"]
            and (ui["verdict"]["status"] != "failed" or raw["status"] == "failed"), "nightly UI status differs")
    verdict = copy.deepcopy(verified["verdict"])
    verdict["infrastructure"] = []
    # Only validated closed-set receipt reasons cross the public reporting boundary.
    verdict["infrastructure"].extend(sorted({summary["archive_download"]["failure_reason"] for summary in summaries
        if summary.get("archive_download", {}).get("failure_reason") is not None}))
    for shard, planned in zip(verdict["shards"], plan["shards"]):
        declared = {identity_key(item) for item in planned["declared"]}
        failures = [item for item in verdict["observed"] if identity_key(item["identity"]) in declared and item["outcome"] in FAILURES]
        failure_errors = {item["outcome"] + ": " + identity_label(item["identity"]) for item in failures}
        if failures:
            failure_errors.add("producer status is failed")
        other_errors = [error for error in shard["verdict"]["errors"] if error not in failure_errors]
        if other_errors:
            categories = set()
            for error in other_errors:
                category = next((label for prefix, label in (
                    ("missing ", "missing-population"), ("unexpected ", "unexpected-population"),
                    ("infrastructure ", "producer-infrastructure"), ("policy ", "policy"),
                    ("population ", "population"), ("coverage ", "coverage"),
                    ("producer status", "unverified-producer")) if error.startswith(prefix)), "invalid-evidence")
                categories.add(category)
            verdict["infrastructure"].append("nightly UI evidence incomplete: " + shard["device"] + "/" + shard["shard"]
                                             + " (" + ", ".join(sorted(categories)) + ")")
    intervals = {item["shard"] for item in ui["capacity"]["shard_intervals"]}
    if intervals != {item["device"] + "/" + item["shard"] for item in plan["shards"]}:
        verdict["infrastructure"].append("nightly UI timing evidence incomplete")
    if ui["matrix_job_result"] != "success" and not any(item["outcome"] in FAILURES for item in verdict["observed"]):
        verdict["infrastructure"].append("nightly UI matrix execution incomplete")
    return verdict


def nightly_failure_reasons(api, run, attempt, artifacts, raw, missing):
    """Bind fail-only diagnostics to this attempt without admitting untrusted execution."""
    from ci_nightly import case_identity, parse_identity_failure, parse_manifest, shards
    from ci_publish import complete_attempt_jobs, json_member
    import subprocess
    absent = {identity_key(item["identity"]) for item in missing}
    reasons, jobs = {}, {}
    ui = raw.get("ui", {})
    ui_summary_shards = {item["shard"] for item in ui.get("capacity", {}).get("shard_intervals", [])}
    # nightly_ui_attempt has already bound this plan to tested source and available records.
    for shard in ui.get("plan", {}).get("shards", []):
        job_name = f"ui-{shard['device']}-{shard['shard']}"
        keys = {identity_key(item) for item in shard["declared"]}
        has_records = shard["device"] + "/" + shard["shard"] in ui_summary_shards or any(
            item["name"] == f"{job_name}-{run['id']}-{attempt}" for item in artifacts)
        if not has_records:
            jobs[job_name] = keys
        matches = [item for item in artifacts if item["name"] == f"nightly-ui-identity-{shard['device']}-{shard['shard']}-{run['id']}-{attempt}"]
        if not has_records and len(matches) == 1 and not matches[0]["expired"]:
            try:
                receipt = parse_identity_failure(json_member(api, matches[0], "identity-failure.json"),
                    {"id": str(run["id"]), "attempt": attempt}, shard["shard"], shard["declared"], job="ui-" + shard["device"])
                reasons.update({key: receipt["reason"] for key in keys})
            except (ContractError, KeyError, TypeError, ValueError, OSError, EOFError, http.client.HTTPException, zipfile.BadZipFile):
                pass  # Invalid untrusted diagnostics never replace missing evidence.
    plans = [item for item in artifacts if item["name"] == f"nightly-plan-{run['id']}-{attempt}"]
    summary_shards = {item["shard"] for item in raw["capacity"]["shard_intervals"]}
    if raw.get("diagnostic_shard") in {None, "strict-only"} and raw["matrix"].get("missing", []) and len(plans) == 1 and not plans[0]["expired"]:
        try:
            plan = json_member(api, plans[0], "plan.json")
            require(type(plan["schema_version"]) is int and plan["schema_version"] == 1
                    and plan["identity"] == raw["identity"] and plan["run"] == {"id": str(run["id"]), "attempt": attempt}
                    and plan["source"] == raw["source"] and plan["hashes"] == raw["hashes"], "early scheduling record differs")
            matrix = subprocess.check_output(["git", "show", run["head_sha"] + ":scripts/nightly-matrix.json"], timeout=30)
            require(hashlib.sha256(matrix).hexdigest() == plan["hashes"]["manifests"]["nightly-matrix"],
                    "early scheduling matrix differs")
            require(subprocess.check_output(["git", "rev-parse", run["head_sha"] + "^{tree}"], timeout=30).decode().strip()
                    == plan["identity"]["tree_sha"], "early scheduling tree differs")
            require(plan["shards"] == shards(parse_manifest(matrix.decode())), "early scheduling shards differ")
            for shard in plan["shards"]:
                declared = [case_identity(case) for case in shard["cases"]]
                keys = {identity_key(item) for item in declared}
                matches = [item for item in artifacts if item["name"] == f"nightly-identity-{shard['id']}-{run['id']}-{attempt}"]
                has_records = shard["id"] in summary_shards or any(
                    item["name"] == f"nightly-strict-{shard['id']}-{run['id']}-{attempt}" for item in artifacts)
                if not has_records:
                    jobs["nightly-strict-" + shard["id"]] = keys
                if not has_records and len(matches) == 1 and not matches[0]["expired"]:
                    try:
                        receipt = parse_identity_failure(json_member(api, matches[0], "identity-failure.json"),
                            {"id": str(run["id"]), "attempt": attempt}, shard["id"], declared)
                        reasons.update({key: receipt["reason"] for key in keys})
                    except (ContractError, KeyError, TypeError, ValueError, EOFError, http.client.HTTPException, zipfile.BadZipFile):
                        pass  # Invalid untrusted diagnostics never replace missing evidence.
        except (ContractError, KeyError, TypeError, ValueError, OSError, EOFError, http.client.HTTPException, subprocess.SubprocessError, zipfile.BadZipFile):
            pass
    candidates = {name: keys & absent for name, keys in jobs.items() if keys & absent}
    if not candidates:
        return reasons
    try:
        for job in complete_attempt_jobs(api, {**run, "run_attempt": attempt}):
            if job["name"] not in candidates or job["status"] != "completed" or job["conclusion"] != "failure":
                continue
            check = re.fullmatch(r"https://api\.github\.com/repos/" + re.escape(api.repository)
                                 + r"/check-runs/([1-9][0-9]*)", job.get("check_run_url", ""))
            if check is None:
                continue
            annotations = api.annotations(int(check[1]))
            if any(isinstance(item, dict) and item.get("annotation_level") == "failure"
                   and isinstance(item.get("message"), str)
                   and item["message"].startswith("The hosted runner lost communication with the server") for item in annotations):
                reasons.update({key: "hosted-runner-disconnected" for key in candidates[job["name"]]})
    except (ContractError, KeyError, ValueError, TypeError, OSError, AttributeError):
        pass  # Unavailable annotation facts leave the existing fail-closed reason intact.
    return reasons


def nightly_attempt(api, run, attempt, artifacts):
    from ci_health import observation_metrics
    from ci_nightly_change import INFRASTRUCTURE_ERROR_PREFIXES
    from ci_publish import json_member
    entry = report_base({**run, "run_attempt": attempt}, api.repository)
    name = f"nightly-aggregate-{run['id']}-{attempt}"
    matches = [item for item in artifacts if item["name"] == name]
    require(len(matches) == 1, "missing or duplicate nightly aggregate")
    if matches[0]["expired"]:
        raise EvidenceExpired("nightly aggregate expired")
    raw = json_member(api, matches[0], "nightly.json")
    identity = parse_identity(raw["identity"])
    require(type(raw["schema_version"]) is int and raw["schema_version"] in {1, 2}
            and raw["run"] == {"id": str(run["id"]), "attempt": attempt}, "nightly run mismatch")
    require((raw["schema_version"] == 2) == ("ui" in raw), "nightly UI successor shape mismatch")
    require(identity["repository"] == api.repository and identity["event"] == run["event"]
            and nightly_ref_allowed(api, run, identity) and identity["commit_sha"] == run["head_sha"], "nightly identity mismatch")
    require(raw["source"]["workflow_path"] == NIGHTLY_PATH and raw["source"]["repository"] == api.repository
            and raw["source"]["event"] == run["event"] and raw["source"]["fork_originated"] is False
            and raw["status"] in {"passed", "failed", "environment-limited"}, "invalid nightly source or status")
    for item in raw["observed"]:
        validate_observation({key: value for key, value in item.items() if key not in {"retry_failure", "nightly_retry_first"}})
    entry.update(identity=identity, hashes=raw["hashes"], status=raw["status"], tiers=raw["tiers"],
                 release_ineligible_reasons=raw["release_ineligible_reasons"], diagnostic_shard=raw.get("diagnostic_shard"))
    require(entry["diagnostic_shard"] is None or run["event"] == "workflow_dispatch"
            and isinstance(entry["diagnostic_shard"], str) and bool(entry["diagnostic_shard"]), "invalid nightly diagnostic")
    require(not entry["diagnostic_shard"] or not any("nightly_retry" in item or "retry_failure" in item for item in [
        *raw["observed"], *raw.get("ui", {}).get("verdict", {}).get("observed", [])]),
        "nightly retry: requires a full nightly run")
    observed, missing = [], []
    case_keys = {identity_key(item["identity"]) for item in raw["observed"]}
    informational = {identity_key(item["identity"]) for item in raw["informational"]}
    shards = {item["shard"] for item in raw["capacity"]["shard_intervals"]}
    summary_cases, yellow_cases, flaky_cases, restored = set(), {}, {}, {}
    jobs = None
    for shard in sorted(shards):
        name = f"nightly-strict-{shard}-{run['id']}-{attempt}"
        matches = [item for item in artifacts if item["name"] == name]
        require(len(matches) == 1, "missing or duplicate nightly shard")
        if matches[0]["expired"]:
            raise EvidenceExpired("nightly shard expired")
        summary = parse_nightly_summary(json_member(api, matches[0], "summary.json"))
        require(summary["identity"] == identity and summary["hashes"] == raw["hashes"]
                and summary["source"]["workflow_path"] == NIGHTLY_PATH and not summary["source"]["fork_originated"]
                and summary["run"] == {"id": str(run["id"]), "attempt": attempt, "tier": "strict", "job": "nightly-strict", "shard": shard},
                "nightly shard provenance mismatch")
        declared = summary["population"]["declared"]
        require(all(identity_key(item) in case_keys for item in declared), "shard cases differ from aggregate")
        summary_cases.update(identity_key(item) for item in declared)
        summary["population"]["declared"] = [item for item in declared if identity_key(item) not in informational]
        trace = json_member(api, matches[0], "trace.json")
        yellow = [item for item in summary["population"]["observed"] if "environment_limit" in item]
        flaky = [item for item in summary["population"]["observed"] if "nightly_retry" in item]
        hosted = False
        if yellow or flaky or any("retry" in phase for phase in trace.get("warm", [])):
            from ci_publish import complete_attempt_jobs
            if jobs is None:
                jobs = complete_attempt_jobs(api, {**run, "run_attempt": attempt})
            matching = [job for job in jobs if job["name"] == "nightly-strict-" + shard]
            hosted = (len(matching) == 1 and matching[0].get("runner_group_name") == "GitHub Actions"
                      and "self-hosted" not in matching[0].get("labels", []))
            require(hosted, "environment limit requires a verified GitHub-hosted strict job" if yellow else
                    "nightly retry: requires a verified GitHub-hosted strict job")
        verified = {}
        methods, absent = method_observations(summary, trace, runner_hosted=hosted, verified_cases=verified,
                                              review_bindings=raw.get("review_packages", []))
        yellow_cases.update({key: item["environment_limit"] for key, item in verified.items() if "environment_limit" in item})
        flaky_cases.update({key: item["nightly_retry"] for key, item in verified.items() if "nightly_retry" in item})
        for claim in flaky:
            key = identity_key(claim["identity"])
            if key in verified and "nightly_retry" not in verified[key]:
                restored[key] = claim["nightly_retry"]
        observed.extend(methods)
        missing.extend(absent)
    ui = nightly_ui_attempt(api, run, attempt, artifacts, raw) if raw["schema_version"] == 2 else None
    if ui is not None:
        observed.extend(ui["observed"])
        missing.extend({"identity": item, "reason": "nightly-ui-sample-missing"} for item in ui["matrix"]["missing"])
    # Valid interval summaries already own their method-level not-run accounting.
    represented = {identity_key(item["identity"]) for item in observed + missing} | summary_cases
    if raw.get("diagnostic_shard") in {None, "strict-only"}:
        for case in raw["matrix"].get("missing", []):
            validate_test_identity(case)
            if identity_key(case) not in represented:
                missing.append({"identity": case, "reason": "missing or invalid shard evidence"})
    reasons = nightly_failure_reasons(api, run, attempt, artifacts, raw, missing)
    for item in missing:
        item["reason"] = reasons.get(identity_key(item["identity"]), item["reason"])
    counts = Counter(item["outcome"] for item in observed)
    declared_keys = {identity_key(item["identity"]) for item in observed + missing}
    if ui is not None:
        declared_keys.update(identity_key(item["identity"]) for item in ui["deselected"])
    counts.update(declared=len(declared_keys), observed=len(observed),
                  scheduled_cases=raw["matrix"].get("scheduled", 0), executed_cases=raw["matrix"].get("executed", 0))
    infrastructure = [] if raw["matrix"].get("equal") else ["nightly matrix evidence incomplete"]
    if any(error.startswith(INFRASTRUCTURE_ERROR_PREFIXES) for error in raw["errors"]):
        infrastructure.append("nightly infrastructure or scheduling failure")
    if missing:
        infrastructure.append("nightly official method evidence incomplete")
    infrastructure.extend(sorted(set(reasons.values())))
    if ui is not None:
        counts.update(ui_scheduled=ui["matrix"]["scheduled"], ui_executed=ui["matrix"]["executed"],
                      ui_deselected=ui["matrix"]["deselected"])
        infrastructure.extend(ui["infrastructure"])
    raw_yellow = {identity_key(item["identity"]): item["environment_limit"] for item in raw["observed"]
                  if "environment_limit" in item}
    strict_yellow = bool(yellow_cases)
    strict_flaky = bool(flaky_cases)
    raw_flaky = {identity_key(item["identity"]): item["nightly_retry"] for item in raw["observed"] if "nightly_retry" in item}
    if ui is not None:
        ui_yellow = {identity_key(item["identity"]): item["environment_limit"] for item in ui["observed"]
                     if "environment_limit" in item}
        yellow_cases.update(ui_yellow)
        ui_flaky = {identity_key(item["identity"]): item["nightly_retry"] for item in ui["observed"] if "nightly_retry" in item}
        flaky_cases.update(ui_flaky)
        for item in raw["ui"]["verdict"]["observed"]:
            key = identity_key(item["identity"])
            if "environment_limit" in item:
                raw_yellow[key] = item["environment_limit"]
            if "nightly_retry" in item:
                raw_flaky[key] = item["nightly_retry"]
                if key in ui_yellow:
                    restored[key] = item["nightly_retry"]
    require(len(raw.get("environment_limited", [])) == len(raw_yellow) and set(raw_yellow) == {
        identity_key(item) for item in raw.get("environment_limited", [])}, "nightly environment limit bindings differ")
    require(len(raw.get("flaky", [])) == len(raw_flaky) and set(raw_flaky) == {
        identity_key(item) for item in raw.get("flaky", [])}, "nightly retry: aggregate bindings differ")
    for key, claim in restored.items():
        if raw_flaky.get(key) == claim:
            raw_flaky.pop(key)
            if key in yellow_cases:
                raw_yellow[key] = yellow_cases[key]
    require(raw_yellow == yellow_cases, "nightly environment limit bindings differ")
    require(raw_flaky == flaky_cases, "nightly retry: aggregate bindings differ")
    if any(key not in yellow_cases for key in restored):
        entry["status"] = "failed"
        entry["tiers"] = {**entry["tiers"], "strict": "failed"}
    if raw["status"] == "environment-limited" and entry["status"] == "environment-limited":
        require(bool(yellow_cases or flaky_cases) and not raw["errors"] and not infrastructure and not missing
                and not any(item["outcome"] in FAILURES and "environment_limit" not in item for item in observed)
                and all(item["outcome"] in {"passed", "flaky-passed", "needs-human-review"}
                        or "environment_limit" in item for item in raw["observed"]),
                "nightly environment limit cannot conceal red or incomplete evidence")
    require(raw["status"] != "passed" or not (yellow_cases or flaky_cases), "environment-limited nightly cannot count as passed")
    if yellow_cases or flaky_cases:
        if strict_yellow or strict_flaky:
            require(raw["tiers"]["strict"] in {"failed", "environment-limited"}, "environment-limited strict tier cannot count as passed")
        if ui is not None and (ui.get("environment_limited") or ui.get("flaky")):
            require(raw["tiers"]["ui"] in {"failed", "environment-limited"}, "environment-limited UI tier cannot count as passed")
        counts["environment-limited"] = sum("environment_limit" in item for item in observed)
    if any("nightly_retry" in item for item in observed):
        counts["flaky"] = sum("nightly_retry" in item for item in observed)
    entry.update(observed=observed, diagnostics={"counts": dict(counts), "missing": missing, "infrastructure": infrastructure,
        "failures": [failure_details(item) for item in observed if item["outcome"] in FAILURES or "nightly_retry" in item]})
    # The strict aggregate accepts explicit passes/flaky-passes only, not skips.
    accepted_skips = sum(len(item["verdict"].get("expected_skips", [])) for item in ui["shards"]) if ui is not None else 0
    entry["health"] = observation_metrics(observed, unexpected_skips=counts["skipped"] - accepted_skips)
    # Official methods have no timing; case invocation wall time measures a different interval.
    entry["health"]["test_duration_seconds"] = None
    return entry


def read_run(api, run, admissions, previous=None):
    """Only bounded JSON data is read; artifact files are never extracted or executed."""
    from ci_publish import producer_evidence, cancelled_unstarted_run, archive_blocked_ui
    from ci_publish_git import evaluate_records
    from ci_health import first_execution_metrics, observation_metrics, run_metrics, unexpected_skips
    entry = report_base(run, api.repository)
    saved_first = first_execution_metrics(previous)
    jobs = None
    if run["status"] != "completed" or run.get("conclusion") == "cancelled":
        entry["first_execution_health"] = saved_first
        if run["status"] == "completed" and run.get("conclusion") == "cancelled":
            try:
                if cancelled_unstarted_run(api, run) and on_main(run["head_sha"]):
                    entry.update(status="not-run", pushed_sha=run["head_sha"],
                                 not_evaluated_reason=("gate" if run["path"] == PRODUCER_PATHS[0] else "UI run")
                                 + " cancelled before any job executed")
            except RateLimitLow:
                raise
            except (ContractError, KeyError, ValueError, TypeError):
                pass  # Incomplete proof retains the ordinary unverified cancellation.
        if run.get("conclusion") != "cancelled" and previous and previous.get("attempt_history"):
            entry["attempt_history"] = [copy.deepcopy(item) for item in previous["attempt_history"]
                                        if item["run"]["attempt"] < run["run_attempt"]] + [copy.deepcopy(entry)]
            for record in entry["attempt_history"]:
                scrub_report_attempts(record)
        return entry
    try:
        if run["event"] == "push":
            require(run["head_branch"] == "main" and run["head_repository"]["full_name"] == api.repository
                    and on_main(run["head_sha"]), "push is outside main history")
            entry["pushed_sha"] = run["head_sha"]
        if run["path"] == NIGHTLY_PATH:
            diagnostic_branch = (getattr(api, "diagnostic_nightly", False) and getattr(api, "dry_run", False)
                                 and run["event"] == "workflow_dispatch" and run["head_branch"] != "main")
            require(run["event"] in {"schedule", "workflow_dispatch"}
                    and run["head_repository"]["full_name"] == api.repository
                    and (diagnostic_branch or run["head_branch"] == "main" and on_main(run["head_sha"])), "untrusted nightly source")
            artifacts = api.pages(f"actions/runs/{run['id']}/artifacts", "artifacts")
            history = []
            cached = {item["run"]["attempt"]: item for item in (previous or {}).get("attempt_history", [])}
            for attempt in range(1, run["run_attempt"] + 1):
                diagnostic = "unverified-dispatch-plan" if run["event"] == "workflow_dispatch" else None
                try:
                    value = nightly_skip_attempt(api, run, attempt, artifacts)
                    if value is None:
                        diagnostic = dispatch_shard(api, run, attempt, artifacts)
                        value = nightly_attempt(api, run, attempt, artifacts)
                        require(value.get("diagnostic_shard") == diagnostic, "aggregate differs from dispatch plan")
                except EvidenceExpired:
                    if attempt not in cached:
                        raise
                    value = copy.deepcopy(cached[attempt])
                except RateLimitLow:
                    raise
                except (ContractError, KeyError, ValueError, TypeError) as error:
                    value = report_base({**run, "run_attempt": attempt}, api.repository)
                    value["diagnostic_shard"] = diagnostic
                    value["diagnostics"]["infrastructure"] = ["fixture-source-drift" if isinstance(error, FixtureSourceDrift)
                                                             else "nightly attempt evidence unavailable"]
                history.append(value)
            if any(item["diagnostics"]["infrastructure"] for item in history):
                history[-1]["diagnostics"]["infrastructure"].append("nightly attempt history incomplete")
            entry = copy.deepcopy(history[-1])
            entry["attempt_history"] = history
            if diagnostic_branch:
                entry["diagnostic_shard"] = "branch-dispatch-read-only"
                for value in history:
                    value["diagnostic_shard"] = "branch-dispatch-read-only"
            if run["conclusion"] != "success":
                entry["status"] = "failed"
        else:
            record = admissions.get(run["id"])
            require(record is not None, "trusted admission missing")
            require(record["workflow_path"] == run["path"] and record["workflow_id"] == run["workflow_id"], "admission workflow mismatch")
            identity = parse_identity(record["identity"])
            require(identity["repository"] == api.repository and identity["event"] == run["event"]
                    and identity.get("head_sha", identity.get("pushed_sha")) == run["head_sha"], "admission source mismatch")
            if run["event"] == "push":
                require(run["head_branch"] == "main" and on_main(run["head_sha"]), "push is outside main history")
            require(run["event"] == "push", "reporter reads main pushes only")
            entry["source"]["ci_changing"] = record["classification"]["ci_changing"]
            source = record["workflows"][run["path"]]["base"]
            errors = []
            jobs, summaries = producer_evidence(api, run, source, diagnostics=errors)
            if any(item.startswith("required artifact expired:") for item in errors):
                entry["evidence_expired"] = True
            require(all(summary["identity"] == identity for summary in summaries), "summary identity differs from admission")
            if not errors and archive_blocked_ui(api, record, run, jobs, summaries):
                entry.update(identity=identity, status="not-run",
                             first_execution_health=saved_first,
                             not_evaluated_reason="archive unavailable for superseded unexecuted gate")
                return entry
            entry.update(identity=identity, diagnostics=summary_diagnostics(summaries, errors),
                         observed=[item for summary in summaries for item in summary["population"]["observed"]])
            entry["hashes"] = [summary["hashes"] for summary in summaries]
            entry["health"] = observation_metrics(entry["observed"], unexpected_skips=unexpected_skips(
                summaries, record.get("base_policy"), "fixture" if run["path"] == PRODUCER_PATHS[1] else "hermetic"))
            if run["run_attempt"] != 1:
                # Gate/UI compact history predates metrics and does not retain
                # every original observation after a GitHub job rerun.
                entry["health"]["first_attempt_failures"] = saved_first["first_attempt_failures"]
            if entry.get("evidence_expired"):
                entry["status"] = "unverified"
                entry["diagnostics"]["infrastructure"] = []
            if not errors:
                reused_ui = run["path"] == ".github/workflows/ci-ui.yml" and any(job["conclusion"] == "skipped" for job in jobs)
                if reused_ui or all(job["status"] == "completed" and job["conclusion"] == "success" for job in jobs):
                    if reused_ui:
                        from ci_ui_reuse import evaluate_reused_push
                        result = evaluate_reused_push(api, record, run, jobs, summaries)
                    else:
                        result = evaluate_records(record, run, jobs, summaries, approved=False, fork=False)
                    entry["evaluation"] = result
                    if reused_ui and result["state"] == "pending" and result.get("deferred_to") == "nightly-ui":
                        entry.update(status="not-run", not_evaluated_reason=result["description"])
                    else:
                        entry["status"] = "passed" if result["state"] == "success" and run["conclusion"] == "success" else "failed"
                elif not entry["diagnostics"]["failures"]:
                    entry["diagnostics"]["infrastructure"].append("required job failed, skipped or cancelled without an official test failure")
    except EvidenceExpired:
        entry["evidence_expired"] = True
        entry["status"] = "unverified"
        entry["diagnostics"]["infrastructure"] = []
    except RateLimitLow:
        raise
    except (ContractError, KeyError, ValueError, TypeError):
        entry["status"] = "failed"
        # Only reporter/base-controlled diagnostics cross this boundary.
        entry["diagnostics"]["infrastructure"].append("missing, invalid or untrusted evidence")
    # Raw runner messages can contain private values even in otherwise valid JSON.
    for record in [entry, *entry.get("attempt_history", [])]:
        scrub_report_attempts(record)
    entry["first_execution_health"] = (saved_first if saved_first["first_attempt_failures"] is not None
                                       else first_execution_metrics(entry))
    if "health" in entry:
        entry["health"].update(run_metrics(run, jobs))
        sizes = getattr(api, "artifact_sizes", {}).get(run["id"])
        entry["health"]["artifact_bytes"] = sum(sizes.values()) if sizes is not None else None
    return entry


def ensure_label(api, label):
    from urllib.parse import quote
    if api.repo("labels/" + quote(label, safe=""), missing=True) is None:
        api.repo("labels", method="POST", payload={"name": label, "color": "B60205", "description": "CI reporter managed failure tracking"})


def read_state(issue):
    body = issue.get("body") or ""
    matches = re.findall(re.escape(MARKER) + r"(.*?) -->", body)
    require(len(matches) <= 1, "duplicate issue state marker")
    if not matches:
        return None
    state = decode(matches[0])
    require(state["schema_version"] == 1, "unsupported issue state")
    state["closed"] = issue["state"] == "closed"
    return state


def issue_body(issue, state, repository):
    existing = ((issue or {}).get("body") or "").split(SECTION)[0]
    archive_column = state["identity"] == NIGHTLY_INFRASTRUCTURE
    archive_header = " Archive gate reason | Early infrastructure reason |" if archive_column else ""
    archive_separator = " --- | --- |" if archive_column else ""
    lines = ["CI nightly tracking: " + text(identity_key(state["identity"])) + ".", "",
             f"Failure nights: {state['failure_nights']}; first: {state['first_failure']}; last: {state['last_failure']}.",
             "Explicit pass nights after the last failure: " + ", ".join(state["explicit_pass_nights"]) + ".",
             "Closure requires three distinct UTC nights with explicit passes and no registry reference.", "",
             "| UTC night | Run | Outcome |" + archive_header, "| --- | --- | --- |" + archive_separator]
    from ci_flaky import ASSERTION_FAILURE
    for day, runs in sorted(state["nights"].items()):
        for run, item in sorted(runs.items()):
            reasons = sorted(set(item.get("archive_failure_reasons", [])) & ARCHIVE_DOWNLOAD_FAILURES)
            early = sorted(set(item.get("early_failure_reasons", [])) & EARLY_FAILURE_REASONS)
            archive_cell = " " + (", ".join(reasons) or "—") + " | " + (", ".join(early) or "—") + " |" if archive_column else ""
            outcome = item["outcome"]
            if item.get("nightly_retry") is True:
                outcome += f". {ASSERTION_FAILURE}, one retry passed."
            lines.append(f"| {day} | [Run {run}, attempt {item['attempt']}](https://github.com/{repository}/actions/runs/{run}) | {outcome} |" + archive_cell)
    lines.append(MARKER + json.dumps(state, sort_keys=True, separators=(",", ":")) + " -->")
    body = existing + SECTION + "\n".join(lines)
    require(len(body.encode()) < 65000, "issue history exceeds GitHub limit; human reconciliation needed")
    return body


def visible_issues(api, label):
    return [item for item in api.pages("issues", state="open", labels=label, sort="updated", direction="desc")
            if "pull_request" not in item and any(value["name"] == label for value in item.get("labels", []))]


def matching_issues(api, label, title):
    from urllib.parse import urlencode
    query = f'repo:{api.repository} is:issue label:"{label}" in:title {json.dumps(title)}'
    result = api.request("/search/issues?" + urlencode({"q": query, "per_page": 100}))
    require(result.get("incomplete_results") is False and result["total_count"] <= 100,
            "issue identity search is incomplete; reconciliation required")
    return result["items"]


def wait_for_issue_visibility(api, number, label):
    deadline = time.monotonic() + 60
    while True:
        rows = api.pages("issues", state="open", labels=label, sort="updated", direction="desc")
        if any(item["number"] == number and any(value["name"] == label for value in item.get("labels", [])) for item in rows):
            return
        require(time.monotonic() < deadline, "created issue is not yet visible; refusing further writes")
        time.sleep(min(2, max(0, deadline - time.monotonic())))


def completed_nightlies_collected(api, snapshot_path, now):
    """One bounded GET must establish coverage before saved passes can close issues."""
    from urllib.parse import urlencode
    cutoff = (now - timedelta(days=EVIDENCE_DAYS - 1)).isoformat()
    try:
        response = api.repo("actions/workflows/ci-nightly.yml/runs?" + urlencode({
            "branch": "main", "status": "completed", "per_page": 100, "page": 1,
            "created": cutoff + "T00:00:00Z.." + now.isoformat() + "T23:59:59Z"}))
        total, runs = response["total_count"], response["workflow_runs"]
        if type(total) is not int or not 0 <= total <= 100 or not isinstance(runs, list) or len(runs) != total:
            return False
        snapshot = decode(snapshot_path.read_text())
        saved = {entry["run"]["id"]: entry for rollup in snapshot["days"].values() for entry in rollup["entries"]
                 if entry["source"]["workflow_path"] == NIGHTLY_PATH}
        seen = set()
        for run in runs:
            if type(run["id"]) is not int or run["id"] <= 0 or run["id"] in seen:
                return False
            seen.add(run["id"])
            if run["path"] != NIGHTLY_PATH:
                return False
            if run["status"] != "completed" or not eligible_run(run, api.repository):
                continue
            day = utc_timestamp(run["created_at"]).date().isoformat()
            if not cutoff <= day <= now.isoformat():
                continue
            previous = saved.get(run["id"])
            if (type(run["run_attempt"]) is not int or run["run_attempt"] <= 0 or not previous
                    or previous["run"]["attempt"] != run["run_attempt"] or previous["status"] == "pending"
                    or previous.get("conclusion") != run["conclusion"] or not run["conclusion"]
                    or previous.get("created_at") != run["created_at"] or previous["source"]["event"] != run["event"]
                    or previous["source"]["repository"] != api.repository):
                return False
        return True
    except RateLimitLow:
        raise
    except (ContractError, KeyError, TypeError, ValueError, OSError, EOFError, http.client.HTTPException):
        return False


def sync_identity(api, token, identity, entries, registry_issues, registry_tokens, by_number, by_token, label, *, allow_closures=True):
    issue = by_token.get(token)
    registered = registry_tokens.get(token)
    if registered:
        require(registered in by_number, "registry issue is missing; refusing duplicate issue")
        require(not issue or issue["number"] == registered, "registry points to another issue; reconciliation required")
        issue = by_number[registered]
    if issue:
        issue = api.repo(f"issues/{issue['number']}")
        by_number[issue["number"]] = issue
    state = read_state(issue) if issue else None
    require(not state or state["token"] == token, "tracking identity changed before synchronization")
    decision = issue_decision(state, identity, entries, registry_referenced=bool(issue and issue["number"] in registry_issues))
    if issue and issue["state"] == "closed" and state is None and decision["action"] == "open" and not any(
            record["outcome"] == "failed" for runs in decision["state"]["nights"].values() for record in runs.values()):
        return None  # Adopting a closed issue does not turn a flaky event into a new verified red failure.
    deferred_close = decision["action"] == "close" and not allow_closures
    if deferred_close:
        decision["state"]["closed"] = False
        decision["action"] = "update" if decision["state"] != state else "none"
    if decision["action"] == "none":
        return None
    state = decision["state"]
    payload = {"body": issue_body(issue, state, api.repository), "state": "closed" if state["closed"] else "open"}
    if deferred_close:
        payload.pop("state")
    if issue:
        labels = [item["name"] for item in issue.get("labels", [])]
        if label not in labels:
            payload["labels"] = labels + [label]
        api.repo(f"issues/{issue['number']}", method="PATCH", payload=payload)
    else:
        payload.pop("state")
        payload.update(title="CI nightly failure: " + identity["key"][:180], labels=[label])
        issue = api.repo("issues", method="POST", payload=payload)
        wait_for_issue_visibility(api, issue["number"], label)
    return {"issue": issue["number"], "action": decision["action"], "token": token}


def synchronize_issues(api, entries, registry, *, label=LABEL, errors=None, inventory=None, issue_index=None, post_merge_since=None,
                       allow_closures=True):
    entries = [entry for entry in notification_entries(entries, post_merge_since)
               if issue_eligible(entry) and entry["source"]["repository"] == api.repository]
    if not entries:
        return [], {}
    raise_errors = errors is None
    errors = [] if errors is None else errors
    issue_index = {} if issue_index is None else issue_index
    ensure_label(api, label)
    issues = visible_issues(api, label) if inventory is None else inventory
    registry_issues = {int(item["issue"].rsplit("/", 1)[-1]) for item in registry["entries"]}
    by_number = {item["number"]: item for item in issues if "pull_request" not in item}
    for number in registry_issues:
        issue = by_number.get(number) or api.repo(f"issues/{number}", missing=True)
        if issue:
            by_number[number] = issue
    by_token, invalid_tokens = {}, set()
    for issue in by_number.values():
        try:
            state = read_state(issue)
            if state:
                if state["token"] in by_token:
                    invalid_tokens.add(state["token"])
                by_token[state["token"]] = issue
        except (ContractError, KeyError, ValueError, TypeError):
            errors.append({"issue": issue["number"], "code": "invalid-issue-state"})
    registry_tokens = {identity_token(item["identity"]): int(item["issue"].rsplit("/", 1)[-1]) for item in registry["entries"]}
    identities = {identity_token(item["identity"]): item["identity"] for report in entries
                  if report["source"]["workflow_path"] == NIGHTLY_PATH
                  for attempt in report.get("attempt_history", [report]) if issue_eligible(attempt) for item in attempt["observed"]}
    # A missing newer observation must still revoke a tracked run's old pass.
    identities.update({token: read_state(issue)["identity"] for token, issue in by_token.items()})
    identities.update({identity_token(item["identity"]): item["identity"] for item in registry["entries"]})
    if any(report["source"]["workflow_path"] == NIGHTLY_PATH for report in entries):
        identities[identity_token(NIGHTLY_INFRASTRUCTURE)] = NIGHTLY_INFRASTRUCTURE
    receipts = []
    for token, identity in sorted(identities.items()):
        try:
            if token not in by_token and token not in registry_tokens:
                if issue_decision(None, identity, entries, registry_referenced=False)["action"] == "none":
                    continue
                if token in issue_index:
                    issue = api.repo(f"issues/{issue_index[token]}", missing=True)
                    require(issue and (read_state(issue) or {}).get("token") == token,
                            "indexed issue is missing or changed; refusing a duplicate")
                    matches = [issue]
                else:
                    matches = [issue for issue in matching_issues(api, label, "CI nightly failure: " + identity["key"][:180])
                               if (read_state(issue) or {}).get("token") == token]
                require(len(matches) <= 1, "duplicate tracking identity")
                if matches:
                    by_token[token] = matches[0]
                    by_number[matches[0]["number"]] = matches[0]
            require(token not in invalid_tokens, "duplicate tracking identity")
            receipt = sync_identity(api, token, identity, entries, registry_issues, registry_tokens, by_number, by_token, label,
                                    allow_closures=allow_closures)
            if receipt:
                receipts.append(receipt)
        except RateLimitLow:
            errors.append({"code": "api-budget-low"})
            break
        except (ContractError, KeyError, ValueError, TypeError, OSError):
            errors.append({"token": token, "code": "identity-sync-failed"})
    # One notification per failing main push SHA, shared across gate/UI reruns.
    pushes = {}
    for entry in entries:
        if entry["source"]["event"] == "push" and entry["status"] == "failed":
            pushed = entry.get("pushed_sha") or entry.get("identity", {}).get("pushed_sha")
            if pushed:
                pushes.setdefault(pushed, []).append(entry)
    for pushed, reports in sorted(pushes.items()):
        marker = "<!-- ci-report-post-merge:" + pushed + " -->"
        try:
            matching = [issue for issue in issues if marker in (issue.get("body") or "")]
            if not matching:
                matching = [issue for issue in matching_issues(api, label, "CI post-merge failure: " + pushed[:12])
                            if marker in (issue.get("body") or "")]
            require(len(matching) <= 1, "duplicate post-merge issues")
            body = "A post-merge CI aggregate on main failed.\n\n" + marker + "\n\n" + "\n".join(render_entry(item) for item in reports)
            require(len(body.encode()) < 65000, "post-merge notification exceeds GitHub limit")
            if matching:
                issue = api.repo(f"issues/{matching[0]['number']}")
                if issue["body"] != body:
                    api.repo(f"issues/{issue['number']}", method="PATCH", payload={"body": body})
            else:
                issue = api.repo("issues", method="POST", payload={"title": "CI post-merge failure: " + pushed[:12], "body": body, "labels": [label]})
                wait_for_issue_visibility(api, issue["number"], label)
            receipts.append({"issue": issue["number"], "action": "post-merge", "sha": pushed})
        except RateLimitLow:
            errors.append({"code": "api-budget-low"})
            break
        except (ContractError, KeyError, ValueError, TypeError, OSError):
            errors.append({"sha": pushed, "code": "notification-sync-failed"})
    if raise_errors:
        require(not errors, "issue synchronization failed; unrelated identities were still processed")
    return receipts, {number: issue["state"] for number, issue in by_number.items()}


def without_first_failure_receipts(value):
    # Per-night shard/trace artifacts retain receipts; the 89-day snapshot retains none.
    if isinstance(value, dict):
        return {key: without_first_failure_receipts(item) for key, item in value.items()
                if key != "first_failure" or not isinstance(item, dict)}
    if isinstance(value, list):
        return [without_first_failure_receipts(item) for item in value]
    return value


def environment_history(entries):
    """Recheck retained proofs without losing readable red evidence; escalate by UTC night and identity."""
    from ci_failure_diagnostics import validate_environment_limit
    result = copy.deepcopy(entries)
    reports = [attempt for entry in result for attempt in [entry, *entry.get("attempt_history", [])]]
    by_case = {}
    for report in reports:
        scrub_report_attempts(report, retry_only=True)
        rejected = set()
        rejected_retries = set()
        items = [*report.get("observed", []), *report.get("diagnostics", {}).get("failures", [])]
        for item in items:
            if "retry_failure" in item:
                try:
                    validate_retry_failure(item)
                except (ValueError, TypeError, KeyError, AttributeError):
                    # Supplemental evidence cannot invalidate the independently bound first attempt.
                    item.pop("retry_failure")
                    if "exit_codes" in item:
                        item["exit_codes"] = item["exit_codes"][:1]
            if "nightly_retry" in item:
                try:
                    validate_nightly_retry(item)
                except (ValueError, TypeError, KeyError, AttributeError):
                    rejected_retries.add(identity_key(item["identity"]))
            if "environment_limit" not in item:
                continue
            try:
                validate_environment_limit(item["environment_limit"])
                proof = item["environment_limit"]
                if proof["policy_version"] == 5:
                    require(item.get("outcome") == "failed" and "validator_failure_message" not in item
                            and item.get("failure_messages") == proof["failure_messages"]
                            and all(item.get(key) == proof[key] for key in ("failure_phase", "failure_class")),
                            "environment limit: retained failure messages differ")
                    if "attempts" in item:
                        attempts = item["attempts"]
                        require(len(attempts) == 1 and attempts[0]["outcome"] == "failed"
                                and "validator_failure_message" not in attempts[0]
                                and attempts[0].get("environment_limit") == proof
                                and all(attempts[0].get(key) == item[key]
                                        for key in ("failure_phase", "failure_class", "failure_messages")),
                                "environment limit: retained attempt differs")
            except (ValueError, TypeError, KeyError, AttributeError):
                rejected.add(identity_token(item["identity"]))
        for item in items:
            if identity_key(item["identity"]) in rejected_retries:
                item.pop("nightly_retry", None)
                item["outcome"] = "failed"
                item["nightly_retry_rejection"] = "RED: invalid or obsolete nightly-retry proof under the current policy"
            if identity_token(item["identity"]) in rejected:
                item.pop("environment_limit", None)
                item.pop("retry_failure", None)
                item["environment_limit_rejection"] = "RED: invalid or obsolete environment-limit proof under the current policy"
                for target in [item, *item.get("attempts", [])]:
                    if "failure_messages" in target:
                        from ci_failure_diagnostics import validate_failure_messages, UNRECOGNIZED_FAILURE_MESSAGE
                        try:
                            validate_failure_messages(target["failure_messages"])
                        except (ValueError, TypeError, KeyError, AttributeError):
                            target["failure_messages"] = [UNRECOGNIZED_FAILURE_MESSAGE]
                for attempt in item.get("attempts", []):
                    attempt.pop("environment_limit", None)
        if rejected or rejected_retries:
            report["status"] = "failed"
            for item in items:
                if (identity_token(item["identity"]) in rejected or identity_key(item["identity"]) in rejected_retries
                        ) and item["identity"]["kind"] in report.get("tiers", {}):
                    report["tiers"][item["identity"]["kind"]] = "failed"
        if not issue_eligible(report) or report["source"]["workflow_path"] != NIGHTLY_PATH:
            continue
        for item in report["observed"]:
            token = identity_token(item["identity"])
            by_case.setdefault(token, {}).setdefault(report["day"], []).append(item)
    for nights in by_case.values():
        streak, previous_day = 0, None
        for day, items in sorted(nights.items()):
            current = date.fromisoformat(day)
            yellow = all("environment_limit" in item or "nightly_retry" in item for item in items)
            streak = (streak + 1 if previous_day == current - timedelta(days=1) else 1) if yellow else 0
            previous_day = current
            if streak >= ENVIRONMENT_YELLOW_NIGHTS_BEFORE_RED:
                for item in items:
                    item["environment_limit_escalation"] = True
    for report in reports:
        escalated = {identity_token(item["identity"]) for item in report.get("observed", [])
                     if item.get("environment_limit_escalation")}
        for item in report.get("diagnostics", {}).get("failures", []):
            if identity_token(item["identity"]) in escalated:
                item["environment_limit_escalation"] = True
        if escalated:
            report["status"] = "failed"
            for item in report.get("observed", []):
                if item.get("environment_limit_escalation") and item["identity"]["kind"] in report.get("tiers", {}):
                    report["tiers"][item["identity"]["kind"]] = "failed"
        if any("environment_limit_rejection" in item or "environment_limit_escalation" in item or "nightly_retry_rejection" in item
               for item in report.get("observed", [])):
            report["diagnostics"]["counts"]["environment-limited"] = sum(
                "environment_limit" in item and not item.get("environment_limit_escalation") for item in report["observed"])
            report["diagnostics"]["counts"]["flaky"] = sum(
                "nightly_retry" in item and not item.get("environment_limit_escalation") for item in report["observed"])
    return result


def compact_entry(entry, tracked):
    tracked = tracked | {identity_token(item["identity"]) for attempt in entry.get("attempt_history", [entry])
                         for item in attempt["observed"] if item["outcome"] in FAILURES or "nightly_retry" in item}
    result = {key: copy.deepcopy(value) for key, value in entry.items() if key in {
        "schema_version", "day", "source", "run", "identity", "hashes", "status", "release_eligible",
        "tiers", "release_ineligible_reasons", "pushed_sha", "evidence_expired", "diagnostic_shard", "first_execution_health",
        "created_at", "conclusion", "head_sha", "not_evaluated_reason"}}
    if "health" in entry:
        result["health"] = copy.deepcopy(entry["health"])
    result["diagnostics"] = {key: copy.deepcopy(entry["diagnostics"].get(key, [] if key != "counts" else {}))
                             for key in ("counts", "failures", "missing", "infrastructure")}
    result["observed"] = [copy.deepcopy(item) for item in entry["observed"]
                          if entry["source"]["workflow_path"] == NIGHTLY_PATH
                          and (item["outcome"] in FAILURES or "nightly_retry" in item or identity_token(item["identity"]) in tracked)]
    if "evaluation" in entry:
        result["evaluation"] = {key: entry["evaluation"][key] for key in ("state", "description") if key in entry["evaluation"]}
    if "attempt_history" in entry:
        result["attempt_history"] = [compact_entry(value, tracked) for value in entry["attempt_history"]]
    scrub_report_attempts(result, retry_only=True)
    return without_first_failure_receipts(result)


def merge_snapshot(previous, entries, now):
    from ci_health import first_execution_metrics
    snapshot = without_first_failure_receipts(previous) if previous else {"schema_version": 2, "days": {}, "issue_index": {}}
    require(snapshot["schema_version"] == 2 and isinstance(snapshot["days"], dict), "invalid prior snapshot")
    cutoff = (now - timedelta(days=89)).isoformat()
    snapshot["days"] = {day: value for day, value in snapshot["days"].items() if iso_day(day) >= cutoff}
    for entry in entries:
        if entry.get("evidence_expired") or entry["day"] < cutoff:
            continue
        day = iso_day(entry["day"])
        prior = snapshot["days"].get(day, {}).get("entries", [])
        selected = {item["run"]["id"]: item for item in prior}
        old = selected.get(entry["run"]["id"])
        if old and old["run"]["attempt"] > entry["run"]["attempt"]:
            continue
        if old and old.get("identity") and entry.get("identity"):
            require(old["identity"] == entry["identity"], "saved producer identity changed")
        replacement = without_first_failure_receipts(entry)
        first = first_execution_metrics(old)
        if first["first_attempt_failures"] is not None:
            replacement["first_execution_health"] = first
        selected[entry["run"]["id"]] = replacement
        snapshot["days"][day] = daily_rollup(day, list(selected.values()))
    snapshot["days"].setdefault(now.isoformat(), daily_rollup(now.isoformat(), []))
    retained = [entry for rollup in snapshot["days"].values() for entry in rollup["entries"]]
    checked = environment_history(retained)
    for day, rollup in snapshot["days"].items():
        rollup["entries"] = [entry for entry in checked if entry["day"] == day]
    return snapshot


def issue_eligible(entry):
    source = entry["source"]
    return (source.get("fork_originated") is False and not entry.get("diagnostic_shard") and entry.get("status") != "not-run"
            and entry.get("conclusion") != "cancelled"
            and (source["workflow_path"] == NIGHTLY_PATH and source["event"] in {"schedule", "workflow_dispatch"}
                 or source["workflow_path"] in PRODUCER_PATHS[:2] and source["event"] == "push"))


def eligible_run(run, repository):
    return (run["repository"]["full_name"] == repository and run["head_repository"]["full_name"] == repository
            and run["head_branch"] == "main" and issue_eligible({"source": {
                "workflow_path": run["path"], "event": run["event"], "fork_originated": False}}))


def notification_entries(entries, post_merge_since):
    newest = {}
    for entry in entries:
        if entry["source"]["event"] != "push":
            continue
        pushed = entry.get("pushed_sha") or entry.get("identity", {}).get("pushed_sha") or entry.get("head_sha")
        key = (entry["source"]["repository"], entry["source"]["workflow_path"], pushed)
        rank = (utc_timestamp(entry.get("created_at", entry["day"] + "T00:00:00Z")), entry["run"]["id"], entry["run"]["attempt"])
        if key not in newest or rank > newest[key][0]:
            newest[key] = rank, entry
    result = [entry for entry in entries if entry["source"]["event"] != "push"]
    if post_merge_since:
        boundary = utc_timestamp(post_merge_since)
        result.extend(entry for _, entry in newest.values() if entry["status"] == "failed"
                      and entry.get("pushed_sha", entry.get("identity", {}).get("pushed_sha"))
                      and entry["diagnostics"]["failures"] and entry.get("conclusion") != "cancelled"
                      and entry.get("created_at") and utc_timestamp(entry["created_at"]) >= boundary)
    return result


def decision_entries(entries, now, *, post_merge_since=None):
    cutoff = (now - timedelta(days=EVIDENCE_DAYS - 1)).isoformat()
    return [entry for entry in notification_entries(entries, post_merge_since) if cutoff <= entry["day"] <= now.isoformat()
            and not entry.get("evidence_expired") and issue_eligible(entry)]


def discover_runs(api, event_name, event, now):
    if event_name == "workflow_run":
        triggering = api.repo(f"actions/runs/{event['workflow_run']['id']}")
        return [triggering] if eligible_run(triggering, api.repository) else []
    runs = {}
    for path in (NIGHTLY_PATH, *PRODUCER_PATHS[:2]):
        workflow = api.repo("actions/workflows/" + path.rsplit("/", 1)[-1], missing=True)
        if workflow is None:
            continue
        require(workflow["path"] == path, "producer workflow path mismatch")
        start = (now - timedelta(days=EVIDENCE_DAYS - 1)).isoformat()
        for run in api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs",
                             branch="main", **({"event": "push"} if path != NIGHTLY_PATH else {}),
                             created=start + "T00:00:00Z.." + now.isoformat() + "T23:59:59Z"):
            require(run["workflow_id"] == workflow["id"] and run["path"] == path
                    and run["repository"]["full_name"] == api.repository, "producer ID/path/repository mismatch")
            if not eligible_run(run, api.repository):
                continue
            runs[run["id"]] = run
    return sorted(runs.values(), key=lambda item: item["id"])


def snapshot_artifacts(api, workflow):
    def metadata(path, collection=None, **filters):
        previous = getattr(api, "retry_reads", False)
        api.retry_reads = True
        try:
            return api.pages(path, collection, **filters)
        finally:
            api.retry_reads = previous

    # An old run can upload the newest snapshot on rerun, even across listing pages.
    # Workflow-run search filters silently cap the listing at 1000 results.
    uploaders = metadata(f"actions/workflows/{workflow['id']}/runs", "workflow_runs")
    uploaders.sort(key=lambda run: utc_timestamp(run["updated_at"]), reverse=True)
    artifacts = []
    for uploader in uploaders:
        upper = utc_timestamp(uploader["updated_at"])
        artifacts.sort(key=lambda item: item[:3], reverse=True)
        # Serialized reporter jobs cannot upload newer bytes after this metadata read.
        while artifacts and artifacts[0][0] > upper:
            yield artifacts.pop(0)
        for artifact in metadata(f"actions/runs/{uploader['id']}/artifacts", "artifacts"):
            match = re.fullmatch(r"ci-report-daily-([1-9][0-9]*)-([1-9][0-9]*)", artifact["name"])
            if not match or artifact.get("workflow_run", {}).get("head_branch") != "main":
                continue
            created = datetime.fromisoformat(artifact["created_at"].replace("Z", "+00:00"))
            require(created.tzinfo is not None and created.utcoffset() == timedelta(0), "invalid snapshot creation time")
            require(artifact["workflow_run"]["id"] == int(match[1]) == uploader["id"], "snapshot artifact run mismatch")
            artifacts.append((created, int(match[1]), int(match[2]), artifact))
    yield from sorted(artifacts, key=lambda item: item[:3], reverse=True)


def read_snapshot(api):
    from ci_publish import json_member
    workflow = api.repo("actions/workflows/ci-report.yml", missing=True)
    if workflow is None:
        return None
    require(workflow["path"] == REPORT_PATH, "reporter workflow path mismatch")
    runs = {}
    for created, run_id, attempt, artifact in snapshot_artifacts(api, workflow):
        run = runs.setdefault(run_id, None)
        if run is None:
            run = runs[run_id] = api.repo(f"actions/runs/{run_id}")
        if not (run["id"] == run_id and run["path"] == REPORT_PATH and run["workflow_id"] == workflow["id"] and run["head_branch"] == "main"
                and run["repository"]["full_name"] == api.repository and run["head_repository"]["full_name"] == api.repository
                and run["event"] in {"schedule", "workflow_dispatch", "workflow_run"} and on_main(run["head_sha"])):
            continue
        require(attempt <= run["run_attempt"], "snapshot attempt is ahead of its run")
        # Exact-name lookup checks duplicates beyond the discovery page without crawling unrelated artifacts.
        matches = api.pages("actions/artifacts", "artifacts", name=artifact["name"])
        require(sum(item["name"] == artifact["name"] and item.get("workflow_run", {}).get("head_branch") == "main"
                    for item in matches) == 1, "duplicate reporter snapshot")
        require(not artifact["expired"], "previous reporter snapshot expired")
        snapshot = json_member(api, artifact, "history.json")
        require(snapshot["schema_version"] == 2 and snapshot["producer"] == {
            "repository": api.repository, "workflow_path": REPORT_PATH,
            "run": {"id": str(run_id), "attempt": attempt}, "commit_sha": run["head_sha"]},
            "snapshot provenance mismatch")
        for day, value in snapshot["days"].items():
            require(daily_rollup(iso_day(day), value["entries"]) == value, "invalid saved daily rollup")
        return snapshot
    require(not api.repo(f"actions/workflows/{workflow['id']}/runs?branch=main&per_page=1")["workflow_runs"],
            "previous reporter runs exist but their snapshot could not be read")
    return None


def write_report(output, snapshot, entries, registry, states, *, stopped, now=None, inventory=()):
    retained = {(entry["run"]["id"], entry["run"]["attempt"]): entry
                for rollup in snapshot["days"].values() for entry in rollup["entries"]}
    entries = [retained.get((entry["run"]["id"], entry["run"]["attempt"]), entry) for entry in entries]
    encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":")) + "\n"
    require(len(encoded.encode()) <= 16 * 1024 * 1024, "reporter snapshot exceeds readable artifact limit")
    for kind in ("daily", "runs"):
        (output / kind).mkdir(parents=True, exist_ok=True)
    (output / "daily/history.json").write_text(encoded)
    for day, rollup in sorted(snapshot["days"].items()):
        (output / "daily" / (day + ".json")).write_text(json.dumps(rollup, separators=(",", ":")) + "\n")
    for entry in entries:
        kind = "runs"
        stem = str(entry["run"]["id"]) + "-" + str(entry["run"]["attempt"])
        (output / kind / (stem + ".json")).write_text(json.dumps(entry, separators=(",", ":")) + "\n")
        (output / kind / (stem + ".md")).write_text(render_entry(entry))
    now = now or datetime.now(timezone.utc).date()
    candidates = [entry for rollup in snapshot["days"].values() for entry in rollup["entries"]
                  if entry["source"]["event"] == "push" or entry["source"]["workflow_path"] == NIGHTLY_PATH]
    since = snapshot.get("history_reset", {}).get("created_at")
    plan = {"schema_version": 2, "entries": [] if stopped else decision_entries(candidates, now, post_merge_since=since),
            "registry": registry, "issue_inventory": list(inventory), "issue_index": snapshot.get("issue_index", {}), "budget_stopped": stopped,
            "api_budget": snapshot.get("api_budget", {}), "post_merge_since": since}
    (output / "sync.json").write_text(json.dumps(plan) + "\n")
    return entries


def collect_report(api, event_name, event, now, output, *, run_ids=()):
    from ci_publish import trusted_admissions
    from ci_flaky import parse_registry
    from ci_health import report_month, write_health, render_registry
    month = report_month(event_name, event, now)
    registry = parse_registry(Path("scripts/ci-known-flaky.json").read_text())
    snapshot, entries, states, stopped, history_loaded = None, [], {}, False, False
    inventory = []
    reset = event.get("inputs", {}).get("reset_history") in {True, "true"}
    history_reset = None
    if reset:
        owner = api.repository.split("/", 1)[0]
        require(event_name == "workflow_dispatch" and os.environ.get("GITHUB_ACTOR") == owner
                and os.environ.get("GITHUB_TRIGGERING_ACTOR") == owner, "history reset requires a maintainer dispatch")
    try:
        api.request("/rate_limit")
        snapshot = None if reset else read_snapshot(api)
        require(snapshot is not None or reset or getattr(api, "dry_run", False), "initial history requires an explicit maintainer reset")
        history_loaded = True
        index = copy.deepcopy((snapshot or {}).get("issue_index", {}))
        history_reset = ({"actor": os.environ["GITHUB_ACTOR"], "day": now.isoformat(), "run": os.environ.get("GITHUB_RUN_ID")}
                         if reset else copy.deepcopy((snapshot or {}).get("history_reset")))
        reset_notification_point(api, history_reset)
        inventory = visible_issues(api, LABEL)
        tracked = {identity_token(item["identity"]) for item in registry["entries"]}
        tracked.update(identity_token(item["identity"]) for rollup in (snapshot or {}).get("days", {}).values()
                       for entry in rollup["entries"] for item in entry["observed"])
        for issue in inventory:
            state = read_state(issue)
            if state:
                tracked.add(state["token"])
                index[state["token"]] = issue["number"]
            states[issue["number"]] = issue["state"]
        for item in registry["entries"]:
            number = int(item["issue"].rsplit("/", 1)[-1])
            if number not in states:
                issue = api.repo(f"issues/{number}", missing=True)
                states[number] = issue["state"] if issue else "missing"
                if issue:
                    inventory.append(issue)
        saved = {entry["run"]["id"]: entry for value in (snapshot or {}).get("days", {}).values() for entry in value["entries"]}
        runs = ([run for run_id in run_ids for run in discover_runs(api, "workflow_run", {"workflow_run": {"id": run_id}}, now)]
                if run_ids else discover_runs(api, event_name, event, now))
        if event_name != "workflow_run":
            ids = {run["id"] for run in runs}
            for entry in saved.values():
                if (entry["status"] == "pending" and entry["run"]["id"] not in ids
                        and (now - timedelta(days=EVIDENCE_DAYS - 1)).isoformat() <= entry["day"] <= now.isoformat()):
                    runs.append(api.repo(f"actions/runs/{entry['run']['id']}"))
        for run in runs:
            if not eligible_run(run, api.repository):
                continue
            if run["created_at"][:10] < (now - timedelta(days=EVIDENCE_DAYS - 1)).isoformat():
                continue
            previous = saved.get(run["id"])
            if (previous and previous["run"]["attempt"] == run["run_attempt"] and previous["status"] != "pending"
                    and previous.get("identity") and "conclusion" in previous and "created_at" in previous):
                continue
            admissions = trusted_admissions(api, [run["id"]]) if run["path"] != NIGHTLY_PATH and run.get("conclusion") != "cancelled" else {}
            report = read_run(api, run, admissions, previous)
            tracked.update(identity_token(item["identity"]) for attempt in report.get("attempt_history", [report])
                           for item in attempt["observed"] if item["outcome"] in FAILURES)
            entries.append(compact_entry(report, tracked))
        snapshot = merge_snapshot(snapshot, entries, now)
        snapshot["issue_index"] = index
    except RateLimitLow:
        if not history_loaded:
            raise
        stopped = True
        snapshot = merge_snapshot(snapshot, entries, now)
        snapshot["issue_index"] = index
    snapshot["registry"] = registry_checks(registry, now.isoformat(), states)
    snapshot["registry_day"] = now.isoformat()
    stopped |= api.budget_exhausted()
    snapshot["budget_stopped"] = stopped
    snapshot["api_budget"] = {"requests": api.request_count, "remaining": api.remaining,
                              "limit": getattr(api, "rate_limit", 1000)}
    if history_reset:
        snapshot["history_reset"] = history_reset
    if os.environ.get("GITHUB_ACTIONS") == "true":
        snapshot["producer"] = {"repository": api.repository, "workflow_path": REPORT_PATH,
            "run": {"id": os.environ["GITHUB_RUN_ID"], "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"])},
            "commit_sha": os.environ["GITHUB_SHA"]}
    entries = write_report(output, snapshot, entries, registry, states, stopped=stopped, now=now, inventory=inventory)
    rendered_health = write_health(output, snapshot, registry, month, now) if month else ""
    if month and os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as handle:
            handle.write("health_month=" + month + "\n")
    checks = snapshot["registry"]
    (output / "runs/registry.json").write_text(json.dumps({"day": now.isoformat(), "entries": checks, "budget_stopped": stopped}) + "\n")
    (output / "runs/registry.md").write_text(render_registry(checks))
    for item in checks:
        if item["review_status"] != "active" or item["issue_state"] in {"closed", "missing", "unknown"}:
            number = item["issue"].rsplit("/", 1)[-1]
            print(f"::warning title=Known-flaky registry::Issue {number}: {item['review_status']}; review by {item['review_by']}; "
                  f"issue state {item['issue_state']}; date eligible {item['date_eligible']}")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as handle:
            handle.write("# CI daily reporting\n\nDaily history: 90 days; main/nightly summaries: 7 days. PR producers retain their own summaries for 30 days.\n\n")
            for entry in entries:
                handle.write(render_entry(entry))
            handle.write("\n## Registry review\n\n" + render_registry(checks) + "\n" + rendered_health)
    receipt = {"writes": False, "requests": api.request_count, "rate_remaining": api.remaining,
               "budget_stopped": stopped, "runs_read": len(entries), "days": len(snapshot["days"]),
               "rollup_bytes": (output / "daily/history.json").stat().st_size}
    print(json.dumps(receipt, sort_keys=True))
    return 0


def diagnose_nightly(api, run_ids, output):
    from ci_summary import sha
    require(api.dry_run and api.diagnostic_nightly, "nightly diagnostics require read-only API access")
    require(output is not None, "nightly diagnostic output is required")
    output = output.resolve()
    root = Path(__file__).resolve().parent.parent
    require(root != output and root not in output.parents and not os.path.lexists(output),
            "nightly diagnostic output must be fresh and outside checkout")
    workflow = api.repo("actions/workflows/ci-nightly.yml")
    require(workflow["path"] == NIGHTLY_PATH, "nightly diagnostic workflow differs")
    reports = []
    for run_id in run_ids:
        run = api.repo(f"actions/runs/{run_id}")
        require(run["repository"]["full_name"] == api.repository and run["workflow_id"] == workflow["id"]
                and run["path"] == NIGHTLY_PATH and run["id"] == run_id, "nightly diagnostic provenance differs")
        sha(run["head_sha"])
        require(run["event"] == "workflow_dispatch" and run["head_repository"]["full_name"] == api.repository,
                "nightly diagnostics require same-repository dispatches")
        reports.append(read_run(api, run, {}))
    output.mkdir(parents=True)
    (output / "runs.json").write_text(json.dumps(reports, indent=2, sort_keys=True) + "\n")
    (output / "report.md").write_text("\n".join(render_entry(report) for report in reports))
    print(json.dumps({"writes": False, "runs_read": len(reports), "requests": api.request_count,
                      "statuses": [report["status"] for report in reports]}))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=("collect", "sync", "health"), default="collect")
    parser.add_argument("--month", help="UTC calendar month, YYYY-MM; required for read-only health")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "sudoHG/immichSlides"))
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--run-id", type=int, action="append", default=[])
    parser.add_argument("--diagnostic-nightly", action="store_true", help="Read branch nightly dispatches without issue or rollup writes")
    args = parser.parse_args(argv)
    require(not args.dry_run or args.phase in {"collect", "health"}, "dry-run cannot synchronize issues")
    require((args.phase == "health") == bool(args.month), "health requires one month")
    require(args.phase != "health" or args.dry_run, "standalone health is read-only")
    require(not args.run_id or args.dry_run and all(run_id > 0 for run_id in args.run_id), "run selection is dry-run only")
    require(not args.diagnostic_nightly or args.dry_run and args.phase == "collect" and args.run_id,
            "branch nightly diagnostics require read-only collection of explicit runs")
    if not args.dry_run:
        check_context(os.environ)
        require(args.repository == os.environ["GITHUB_REPOSITORY"], "report repository differs from workflow")
    token = os.environ.get("CI_REPORT_TOKEN")
    if token is None and args.dry_run:
        import subprocess
        token = subprocess.check_output(["gh", "auth", "token"], text=True, stderr=subprocess.DEVNULL, timeout=30).strip()
    require(bool(token), "missing reporting token")
    api = ReportGitHub(args.repository, token, dry_run=args.dry_run)
    api.diagnostic_nightly = args.diagnostic_nightly
    output = args.output_dir or Path(os.environ["RUNNER_TEMP"]) / "ci-report"
    if args.diagnostic_nightly:
        return diagnose_nightly(api, args.run_id, output)
    if args.phase == "health":
        from ci_health import write_health
        from ci_flaky import parse_registry
        now = datetime.now(timezone.utc).date()
        try:
            api.request("/rate_limit")
            snapshot = read_snapshot(api)
            require(snapshot is not None, "health requires real reporter history")
        except RateLimitLow:
            print("Health deferred: API reserve reached before history was verified; no report written.")
            return 0
        rendered = write_health(output, snapshot, parse_registry(Path("scripts/ci-known-flaky.json").read_text()), args.month, now)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as handle:
                handle.write(rendered)
        print(json.dumps({"writes": False, "requests": api.request_count, "month": args.month,
                          "source": snapshot["producer"], "days": sorted(snapshot["days"])}))
        return 0
    if args.phase == "collect":
        event_name = "schedule" if args.dry_run else os.environ["GITHUB_EVENT_NAME"]
        event = {} if args.dry_run else decode(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        return collect_report(api, event_name, event, datetime.now(timezone.utc).date(), output, run_ids=args.run_id)
    plan = decode((output / "sync.json").read_text())
    require(plan["schema_version"] == 2, "invalid issue synchronization plan")
    budget = plan["api_budget"]
    require(type(budget.get("requests")) is int and 0 <= budget["requests"] <= REQUEST_BUDGET
            and type(budget.get("limit")) is int and budget["limit"] > 0, "invalid shared API budget")
    api.request_count, api.remaining, api.rate_limit = budget["requests"], budget["remaining"], budget["limit"]
    plan["entries"] = decision_entries(plan["entries"], datetime.now(timezone.utc).date(), post_merge_since=plan.get("post_merge_since"))
    if plan["budget_stopped"] or not plan["entries"]:
        print("No issue synchronization: no new eligible evidence or API budget reserved.")
        return 0
    errors = []
    try:
        allow_closures = completed_nightlies_collected(api, output / "daily/history.json", datetime.now(timezone.utc).date())
        receipts, states = synchronize_issues(api, plan["entries"], plan["registry"], errors=errors,
                                            inventory=plan.get("issue_inventory", []), issue_index=plan.get("issue_index", {}),
                                            post_merge_since=plan.get("post_merge_since"), allow_closures=allow_closures)
    except RateLimitLow:
        receipts, states = [], {}
        errors.append({"code": "api-budget-low"})
    result = {"schema_version": 2, "actions": receipts, "states": states, "errors": errors,
              "requests": api.request_count, "rate_remaining": api.remaining}
    (output / "runs/issue-actions.json").write_text(json.dumps(result, sort_keys=True) + "\n")
    require(all(item["code"] == "api-budget-low" for item in errors), "issue synchronization failed; rollup was already uploaded")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, RateLimitLow, OSError, ValueError, KeyError, TypeError):
        # Neither credentials nor API/candidate payloads are included in failures.
        raise SystemExit("CI reporting refused: invalid context, evidence or issue state") from None
