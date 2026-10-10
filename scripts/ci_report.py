#!/usr/bin/env python3
"""Main-only CI reporting, daily history and idempotent failure issue lifecycle."""

from __future__ import annotations

import copy
import argparse
import hashlib
import json
import os
import re
import time
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from ci_summary import (ContractError, decode, identity_key, markdown_text, parse_identity,
                        parse_summary, require, validate_observation, validate_test_identity,
                        NON_INFRASTRUCTURE_DIAGNOSTICS, observation, test_identity)
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
REQUEST_BUDGET = 150


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

    def request(self, path, *, method="GET", **options):
        require(not self.dry_run or method == "GET", "dry-run refuses every API write")
        if method == "GET" and options.get("binary") and path in self.binary_cache:
            return self.binary_cache[path]
        if self.budget_exhausted():
            raise RateLimitLow("API budget reserve reached")
        self.request_count += 1
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


def method_observations(raw, trace):
    """A suite result never substitutes for an officially exported method result."""
    from run_strict_e2e import FILTER_PERSON_SESSIONS, resolve_suite_selector
    from strict_e2e_p2_contract import P2_CASES
    summary = parse_summary(raw)
    phases = {identity_key(item["identity"]): item for item in trace["warm"]}
    require(len(phases) == len(trace["warm"]), "duplicate nightly case trace")
    observed, missing = [], []
    compiled = {identity_key(item) for item in summary["population"]["compiled"]}
    outcomes = {identity_key(item["identity"]): item["outcome"] for item in summary["population"]["observed"]}
    for case in summary["population"]["declared"]:
        dimensions = case["dimensions"]
        suite = dimensions["suite"]
        platform = "tvos" if dimensions["device"] == "tv" else "ios"
        selectors = ([item["selector"] for item in FILTER_PERSON_SESSIONS] if suite == "filter-person"
                     else [resolve_suite_selector(platform, suite)])
        wanted = {selector.split("/", 1)[1]: test_identity("strict", selector.split("/", 1)[1], **dimensions)
                  for selector in selectors}
        phase = phases.get(identity_key(case), {})
        methods = phase.get("official_methods", [])
        require(isinstance(methods, list), "invalid official method list")
        seen, counts = set(), Counter()
        for method in methods:
            require(set(method) == {"identifier", "result"} and method["identifier"] in wanted
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
        for method in methods:
            outcome = {"Passed": "passed", "Failed": "failed", "Skipped": "skipped"}[method["result"]]
            if outcome == "passed" and (phase.get("build_operations") != 0 or phase.get("products_unchanged") is not True
                    or phase.get("log_present") is not True or outcomes.get(identity_key(case)) not in {"passed", "needs-human-review"}
                    and not counts["Failed"]):
                outcome = "not-run"
            if outcome == "passed" and suite in P2_CASES:
                outcome = "needs-human-review" if outcomes.get(identity_key(case)) == "needs-human-review" else "not-run"
            observed.append(observation(wanted[method["identifier"]], outcome, 0,
                exit_code=phase.get("exit_code"), reason="Official test was skipped" if outcome == "skipped" else None))
        missing.extend({"identity": wanted[key], "reason": "official-method-not-observed"} for key in sorted(wanted.keys() - seen))
        case_outcome = outcomes.get(identity_key(case))
        if case_outcome in FAILURES and not counts["Failed"]:
            contract_failed = (phase.get("automated_contract_failed") is True and seen == wanted.keys()
                and counts["Passed"] == len(wanted) and not phase.get("infrastructure")
                and not phase.get("official_error") and phase.get("exit_code") not in {124, 130}
                and phase.get("log_present") is True and phase.get("build_operations") == 0
                and phase.get("products_unchanged") is True)
            if contract_failed:
                observed.append(observation(case, case_outcome, 0, exit_code=phase.get("exit_code"), reason="strict-case-contract-failed"))
            else:
                missing.append({"identity": case, "reason": "strict-case-infrastructure-or-unverified-failure"})
        elif (case_outcome in {"passed", "needs-human-review"} and seen == wanted.keys()
              and counts["Passed"] == len(wanted) and phase.get("build_operations") == 0
              and phase.get("products_unchanged") is True and phase.get("log_present") is True):
            observed.append(observation(case, case_outcome, 0, exit_code=phase.get("exit_code")))
    return observed, missing


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
            if item["outcome"] in FAILURES:
                failures.append({"identity": item["identity"], "outcome": item["outcome"],
                                 "exit_codes": [attempt["exit_code"] for attempt in item["attempts"]]})
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
                          if any(item["outcome"] == "failed" for item in runs.values())]))
    if state["last_failure"]:
        previous_failed.add(state["last_failure"])
    new_failure = False
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
        outcomes = {item["outcome"] for item in matches}
        passes = {"passed"}
        if identity["kind"] == "strict" and identity["dimensions"].get("suite") in P2_CASES:
            passes.add("needs-human-review")
        outcome = "failed" if outcomes & FAILURES else "passed" if outcomes and outcomes <= passes else "unverified"
        if entry["diagnostics"]["infrastructure"] or entry["diagnostics"]["missing"]:
            if outcome == "passed":
                outcome = "unverified"
        night = state["nights"].setdefault(day, {})
        record = {"attempt": entry["run"]["attempt"], "outcome": outcome}
        if old is None or old["attempt"] <= record["attempt"]:
            if outcome == "failed" and (old is None or old["outcome"] != "failed" or old["attempt"] < record["attempt"]):
                new_failure |= state["last_failure"] is None or day >= state["last_failure"]
            # A red first attempt cannot become an explicit-pass night by rerunning.
            if old and old["outcome"] == "failed":
                record["outcome"] = "failed"
            night[key] = record
    failed = sorted(day for day, runs in state["nights"].items() if any(item["outcome"] == "failed" for item in runs.values()))
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


def render_entry(entry):
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
    lines += ["", "| Failing identity | Outcome | Exit codes |", "| --- | --- | --- |"]
    lines.extend(f"| {text(identity_key(item['identity']))} | {item['outcome']} | {text(item['exit_codes'])} |"
                 for item in diagnostics["failures"][:50])
    lines.extend(f"Missing evidence: {text(identity_key(item['identity']))}: {item['reason']}."
                 for item in diagnostics["missing"][:50])
    lines.extend(f"Infrastructure: {text(item)}." for item in diagnostics["infrastructure"])
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
    from ci_nightly_ui import parse_ui_plan, validate_ui_record
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
    summaries = []
    for shard in plan["shards"]:
        name = f"ui-{shard['device']}-{shard['shard']}-{run['id']}-{attempt}"
        matches = [item for item in artifacts if item["name"] == name]
        require(len(matches) <= 1, "duplicate nightly UI shard")
        if not matches:
            continue
        if matches[0]["expired"]:
            raise EvidenceExpired("nightly UI shard expired")
        summary = parse_summary(json_member(api, matches[0], "summary.json"))
        require(summary["identity"] == plan["identity"] and summary["source"] == plan["source"]
                and summary["run"] == {**plan["run"], "tier": "ui", "job": "ui-" + shard["device"], "shard": shard["shard"]}
                and summary["hashes"] == plan["hashes"][shard["device"]], "nightly UI shard source binding differs")
        summaries.append(summary)
    values = {}
    for name, path in (("policy", "scripts/ci-test-policy.json"), ("registry", "scripts/ci-known-flaky.json")):
        content = blob(path)
        label = "test-policy" if name == "policy" else "known-flaky"
        require(all(hashes["policies"][label] == hashlib.sha256(content).hexdigest() for hashes in plan["hashes"].values()),
                "nightly UI policy differs from tested source")
        values[name] = decode(content.decode())
    validate_ui_record(ui, summaries, **values, evaluated_on=date.fromisoformat(run["created_at"][:10]))
    require(raw["tiers"]["ui"] == ui["verdict"]["status"]
            and (ui["verdict"]["status"] != "failed" or raw["status"] == "failed"), "nightly UI status differs")
    verdict = copy.deepcopy(ui["verdict"])
    verdict["infrastructure"] = []
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


def nightly_attempt(api, run, attempt, artifacts):
    from ci_health import observation_metrics
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
            and raw["status"] in {"passed", "failed"}, "invalid nightly source or status")
    for item in raw["observed"]:
        validate_observation(item)
    entry.update(identity=identity, hashes=raw["hashes"], status=raw["status"], tiers=raw["tiers"],
                 release_ineligible_reasons=raw["release_ineligible_reasons"], diagnostic_shard=raw.get("diagnostic_shard"))
    require(entry["diagnostic_shard"] is None or run["event"] == "workflow_dispatch"
            and isinstance(entry["diagnostic_shard"], str) and bool(entry["diagnostic_shard"]), "invalid nightly diagnostic")
    observed, missing = [], []
    case_keys = {identity_key(item["identity"]) for item in raw["observed"]}
    informational = {identity_key(item["identity"]) for item in raw["informational"]}
    shards = {item["shard"] for item in raw["capacity"]["shard_intervals"]}
    for shard in sorted(shards):
        name = f"nightly-strict-{shard}-{run['id']}-{attempt}"
        matches = [item for item in artifacts if item["name"] == name]
        require(len(matches) == 1, "missing or duplicate nightly shard")
        if matches[0]["expired"]:
            raise EvidenceExpired("nightly shard expired")
        summary = parse_summary(json_member(api, matches[0], "summary.json"))
        require(summary["identity"] == identity and summary["hashes"] == raw["hashes"]
                and summary["source"]["workflow_path"] == NIGHTLY_PATH and not summary["source"]["fork_originated"]
                and summary["run"] == {"id": str(run["id"]), "attempt": attempt, "tier": "strict", "job": "nightly-strict", "shard": shard},
                "nightly shard provenance mismatch")
        declared = summary["population"]["declared"]
        require(all(identity_key(item) in case_keys for item in declared), "shard cases differ from aggregate")
        summary["population"]["declared"] = [item for item in declared if identity_key(item) not in informational]
        trace = json_member(api, matches[0], "trace.json")
        methods, absent = method_observations(summary, trace)
        observed.extend(methods)
        missing.extend(absent)
    ui = nightly_ui_attempt(api, run, attempt, artifacts, raw) if raw["schema_version"] == 2 else None
    if ui is not None:
        observed.extend(ui["observed"])
        missing.extend({"identity": item, "reason": "nightly-ui-sample-missing"} for item in ui["matrix"]["missing"])
    counts = Counter(item["outcome"] for item in observed)
    declared_keys = {identity_key(item["identity"]) for item in observed + missing}
    if ui is not None:
        declared_keys.update(identity_key(item["identity"]) for item in ui["deselected"])
    counts.update(declared=len(declared_keys), observed=len(observed),
                  scheduled_cases=raw["matrix"].get("scheduled", 0), executed_cases=raw["matrix"].get("executed", 0))
    infrastructure = [] if raw["matrix"].get("equal") else ["nightly matrix evidence incomplete"]
    if any(error.startswith(("missing shard", "invalid or missing", "producer infrastructure", "single-shard")) for error in raw["errors"]):
        infrastructure.append("nightly infrastructure or scheduling failure")
    if missing:
        infrastructure.append("nightly official method evidence incomplete")
    if ui is not None:
        counts.update(ui_scheduled=ui["matrix"]["scheduled"], ui_executed=ui["matrix"]["executed"],
                      ui_deselected=ui["matrix"]["deselected"])
        infrastructure.extend(ui["infrastructure"])
    entry.update(observed=observed, diagnostics={"counts": dict(counts), "missing": missing, "infrastructure": infrastructure,
        "failures": [{"identity": item["identity"], "outcome": item["outcome"],
                      "exit_codes": [a["exit_code"] for a in item["attempts"]]} for item in observed if item["outcome"] in FAILURES]})
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
        for item in record["observed"]:
            for attempt in item["attempts"]:
                attempt["message"] = None
                attempt["reason"] = ("skip reason withheld; consult trusted policy" if attempt["outcome"] == "skipped"
                                     else "strict-case-contract-failed" if attempt.get("reason") == "strict-case-contract-failed" else None)
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
    lines = ["CI nightly tracking: " + text(identity_key(state["identity"])) + ".", "",
             f"Failure nights: {state['failure_nights']}; first: {state['first_failure']}; last: {state['last_failure']}.",
             "Explicit pass nights after the last failure: " + ", ".join(state["explicit_pass_nights"]) + ".",
             "Closure requires three distinct UTC nights with explicit passes and no registry reference.", "",
             "| UTC night | Run | Outcome |", "| --- | --- | --- |"]
    for day, runs in sorted(state["nights"].items()):
        for run, item in sorted(runs.items()):
            lines.append(f"| {day} | [Run {run}, attempt {item['attempt']}](https://github.com/{repository}/actions/runs/{run}) | {item['outcome']} |")
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


def sync_identity(api, token, identity, entries, registry_issues, registry_tokens, by_number, by_token, label):
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
    if decision["action"] == "none":
        return None
    state = decision["state"]
    payload = {"body": issue_body(issue, state, api.repository), "state": "closed" if state["closed"] else "open"}
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


def synchronize_issues(api, entries, registry, *, label=LABEL, errors=None, inventory=None, issue_index=None, post_merge_since=None):
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
            receipt = sync_identity(api, token, identity, entries, registry_issues, registry_tokens, by_number, by_token, label)
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


def compact_entry(entry, tracked):
    tracked = tracked | {identity_token(item["identity"]) for attempt in entry.get("attempt_history", [entry])
                         for item in attempt["observed"] if item["outcome"] in FAILURES}
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
                          and (item["outcome"] in FAILURES or identity_token(item["identity"]) in tracked)]
    if "evaluation" in entry:
        result["evaluation"] = {key: entry["evaluation"][key] for key in ("state", "description") if key in entry["evaluation"]}
    if "attempt_history" in entry:
        result["attempt_history"] = [compact_entry(value, tracked) for value in entry["attempt_history"]]
    return result


def merge_snapshot(previous, entries, now):
    from ci_health import first_execution_metrics
    snapshot = copy.deepcopy(previous) if previous else {"schema_version": 2, "days": {}, "issue_index": {}}
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
        replacement = copy.deepcopy(entry)
        first = first_execution_metrics(old)
        if first["first_attempt_failures"] is not None:
            replacement["first_execution_health"] = first
        selected[entry["run"]["id"]] = replacement
        snapshot["days"][day] = daily_rollup(day, list(selected.values()))
    snapshot["days"].setdefault(now.isoformat(), daily_rollup(now.isoformat(), []))
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
        start = (now - timedelta(days=1)).isoformat()
        for run in api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs",
                             branch="main", **({"event": "push"} if path != NIGHTLY_PATH else {}),
                             created=start + "T00:00:00Z.." + now.isoformat() + "T23:59:59Z"):
            require(run["workflow_id"] == workflow["id"] and run["path"] == path
                    and run["repository"]["full_name"] == api.repository, "producer ID/path/repository mismatch")
            if not eligible_run(run, api.repository):
                continue
            runs[run["id"]] = run
    return sorted(runs.values(), key=lambda item: item["id"])


def read_snapshot(api):
    from ci_publish import json_member
    workflow = api.repo("actions/workflows/ci-report.yml", missing=True)
    if workflow is None:
        return None
    require(workflow["path"] == REPORT_PATH, "reporter workflow path mismatch")
    artifacts = []
    for artifact in api.pages("actions/artifacts", "artifacts"):
        match = re.fullmatch(r"ci-report-daily-([1-9][0-9]*)-([1-9][0-9]*)", artifact["name"])
        if not match or artifact.get("workflow_run", {}).get("head_branch") != "main":
            continue
        created = datetime.fromisoformat(artifact["created_at"].replace("Z", "+00:00"))
        require(created.tzinfo is not None and created.utcoffset() == timedelta(0), "invalid snapshot creation time")
        require(artifact["workflow_run"]["id"] == int(match[1]), "snapshot artifact run mismatch")
        artifacts.append((created, int(match[1]), int(match[2]), artifact))
    runs = {}
    for created, run_id, attempt, artifact in sorted(artifacts, key=lambda item: item[:3], reverse=True):
        run = runs.setdefault(run_id, None)
        if run is None:
            run = runs[run_id] = api.repo(f"actions/runs/{run_id}")
        if not (run["id"] == run_id and run["path"] == REPORT_PATH and run["workflow_id"] == workflow["id"] and run["head_branch"] == "main"
                and run["repository"]["full_name"] == api.repository and run["head_repository"]["full_name"] == api.repository
                and run["event"] in {"schedule", "workflow_dispatch", "workflow_run"} and on_main(run["head_sha"])):
            continue
        require(attempt <= run["run_attempt"], "snapshot attempt is ahead of its run")
        require(sum(item[3]["name"] == artifact["name"] for item in artifacts) == 1, "duplicate reporter snapshot")
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
    write_report(output, snapshot, entries, registry, states, stopped=stopped, now=now, inventory=inventory)
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
        receipts, states = synchronize_issues(api, plan["entries"], plan["registry"], errors=errors,
                                            inventory=plan.get("issue_inventory", []), issue_index=plan.get("issue_index", {}),
                                            post_merge_since=plan.get("post_merge_since"))
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
