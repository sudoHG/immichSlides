#!/usr/bin/env python3
"""Main-only CI reporting, daily history and idempotent failure issue lifecycle."""

from __future__ import annotations

import copy
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
                        NON_INFRASTRUCTURE_DIAGNOSTICS)

REPORT_PATH = ".github/workflows/ci-report.yml"
NIGHTLY_PATH = ".github/workflows/ci-nightly.yml"
PRODUCER_PATHS = (".github/workflows/ci-gate.yml", ".github/workflows/ci-ui.yml", NIGHTLY_PATH)
LABEL = "ci-reported-failure"
MARKER = "<!-- ci-report-state:"
SECTION = "\n\n<!-- ci-report-managed -->\n"
APP_LOGIN = "sudohg-ci[bot]"
FAILURES = {"failed", "crashed", "timed-out"}
NIGHTLY_INFRASTRUCTURE = {"kind": "host", "key": "Nightly infrastructure", "dimensions": {}}


def iso_day(value):
    require(isinstance(value, str) and date.fromisoformat(value).isoformat() == value, "invalid UTC day")
    return value


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
    """Store dates, rather than delivery order, and count at most one pass per night."""
    state = copy.deepcopy(previous) if previous else {"schema_version": 1, "token": identity_token(identity),
             "identity": normalized_identity(identity), "nights": {}, "closed": False,
             "first_failure": None, "last_failure": None, "failure_nights": 0}
    require(state["schema_version"] == 1 and state["token"] == identity_token(identity), "wrong issue identity")
    for entry in entries:
        if entry["source"]["workflow_path"] != NIGHTLY_PATH or entry["status"] == "pending":
            continue
        matches = [item for item in entry["observed"] if identity_token(item["identity"]) == state["token"]]
        if identity == NIGHTLY_INFRASTRUCTURE:
            outcome = "failed" if entry["diagnostics"]["infrastructure"] else "passed" if entry["status"] == "passed" else "unverified"
            matches = [{"outcome": outcome}]
        if not matches:
            continue
        outcomes = {item["outcome"] for item in matches}
        outcome = "failed" if outcomes & FAILURES else "passed" if outcomes == {"passed"} else "unverified"
        if entry["diagnostics"]["infrastructure"] or entry["diagnostics"]["missing"]:
            if outcome == "passed":
                outcome = "unverified"
        night = state["nights"].setdefault(iso_day(entry["day"]), {})
        key = str(entry["run"]["id"])
        record = {"attempt": entry["run"]["attempt"], "outcome": outcome}
        old = night.get(key)
        if old is None or old["attempt"] <= record["attempt"]:
            # A red first attempt cannot become an explicit-pass night by rerunning.
            if old and old["outcome"] == "failed":
                record["outcome"] = "failed"
            night[key] = record
    failed = sorted(day for day, runs in state["nights"].items() if any(item["outcome"] == "failed" for item in runs.values()))
    state.update(first_failure=failed[0] if failed else None, last_failure=failed[-1] if failed else None,
                 failure_nights=len(failed))
    passes = sorted(day for day, runs in state["nights"].items() if failed and day > failed[-1]
                    and all(item["outcome"] == "passed" for item in runs.values()))
    state["explicit_pass_nights"] = passes
    if not failed:
        return {"action": "none", "state": previous}
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
    return [{"identity": entry["identity"], "issue": entry["issue"], "owner": entry["owner"],
             "review_by": entry["review_by"], "expired": entry["review_by"] < day,
             "issue_state": issue_states.get(int(entry["issue"].rsplit("/", 1)[-1]), "missing")}
            for entry in registry["entries"]]


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
            "source": {"repository": repository, "workflow_path": run["path"], "event": run["event"],
                       "workflow_id": run["workflow_id"],
                       "fork_originated": run["head_repository"]["full_name"] != repository,
                       "ci_changing": None, "approval_based": False},
            "status": "pending" if run["status"] != "completed" else "failed",
            "release_eligible": False, "observed": [], "diagnostics": summary_diagnostics([])}


def read_run(api, run, admissions):
    """Only bounded JSON data is read; artifact files are never extracted or executed."""
    from ci_publish import json_member, producer_evidence, approval_context
    from ci_publish_git import evaluate_records
    entry = report_base(run, api.repository)
    if run["status"] != "completed":
        return entry
    try:
        if run["event"] == "push":
            require(run["head_branch"] == "main" and run["head_repository"]["full_name"] == api.repository
                    and on_main(run["head_sha"]), "push is outside main history")
            entry["pushed_sha"] = run["head_sha"]
        if run["path"] == NIGHTLY_PATH:
            require(run["event"] in {"schedule", "workflow_dispatch"} and run["head_branch"] == "main"
                    and run["head_repository"]["full_name"] == api.repository and on_main(run["head_sha"]), "untrusted nightly source")
            name = f"nightly-aggregate-{run['id']}-{run['run_attempt']}"
            matches = [a for a in api.pages(f"actions/runs/{run['id']}/artifacts", "artifacts") if a["name"] == name and not a["expired"]]
            require(len(matches) == 1, "missing or duplicate nightly aggregate")
            raw = json_member(api, matches[0], "nightly.json")
            identity = parse_identity(raw["identity"])
            require(raw["schema_version"] == 1 and raw["run"] == {"id": str(run["id"]), "attempt": run["run_attempt"]}, "nightly run mismatch")
            require(identity["repository"] == api.repository and identity["event"] == run["event"]
                    and identity["ref"] == "refs/heads/main" and identity["commit_sha"] == run["head_sha"], "nightly identity mismatch")
            require(raw["source"]["workflow_path"] == NIGHTLY_PATH and raw["status"] in {"passed", "failed"}, "invalid nightly source or status")
            for item in raw["observed"]:
                validate_observation(item)
            entry.update(identity=identity, hashes=raw["hashes"], observed=raw["observed"],
                         status=raw["status"] if run["conclusion"] == "success" else "failed",
                         tiers=raw["tiers"], release_ineligible_reasons=raw["release_ineligible_reasons"])
            counts = Counter(item["outcome"] for item in raw["observed"])
            counts.update(declared=raw["matrix"].get("scheduled", 0), observed=len(raw["observed"]),
                          executed=raw["matrix"].get("executed", 0))
            entry["diagnostics"] = {"counts": dict(counts),
                "failures": [{"identity": item["identity"], "outcome": item["outcome"],
                              "exit_codes": [a["exit_code"] for a in item["attempts"]]}
                             for item in raw["observed"] if item["outcome"] in FAILURES],
                "missing": [{"identity": item["identity"], "reason": "not-observed"} for item in raw["observed"] if item["outcome"] == "not-run"],
                "infrastructure": [] if raw["matrix"].get("equal") else ["nightly matrix evidence incomplete"]}
            # Preserve structured categories, without copying producer error/log text.
            if any(error.startswith(("missing shard", "invalid or missing", "producer infrastructure", "single-shard")) for error in raw["errors"]):
                entry["diagnostics"]["infrastructure"].append("nightly infrastructure or scheduling failure")
            entry["observed"] = [item for item in entry["observed"] if item not in raw["informational"]]
        else:
            record = admissions.get(run["id"])
            require(record is not None, "trusted admission missing")
            require(record["workflow_path"] == run["path"] and record["workflow_id"] == run["workflow_id"], "admission workflow mismatch")
            identity = parse_identity(record["identity"])
            require(identity["repository"] == api.repository and identity["event"] == run["event"]
                    and identity.get("head_sha", identity.get("pushed_sha")) == run["head_sha"], "admission source mismatch")
            if run["event"] == "push":
                require(run["head_branch"] == "main" and on_main(run["head_sha"]), "push is outside main history")
            fork = entry["source"]["fork_originated"]
            changing = record["classification"]["ci_changing"]
            approved = False
            if run["event"] == "pull_request":
                context = approval_context(identity["pull_request"], identity["head_sha"])
                statuses = api.pages("commits/" + identity["head_sha"] + "/statuses")
                approval = next((s for s in statuses if s["context"] == context and s["creator"]["login"] == APP_LOGIN), None)
                approved = bool(approval and approval["state"] == "success")
            entry["source"].update(ci_changing=changing, approval_based=bool(approved and (fork or changing)))
            source = record["workflows"][run["path"]]["candidate" if approved else "base"]
            errors = []
            jobs, summaries = producer_evidence(api, run, source, diagnostics=errors)
            require(all(summary["identity"] == identity for summary in summaries), "summary identity differs from admission")
            entry.update(identity=identity, diagnostics=summary_diagnostics(summaries, errors),
                         observed=[item for summary in summaries for item in summary["population"]["observed"]])
            entry["hashes"] = [summary["hashes"] for summary in summaries]
            if not errors:
                if all(job["status"] == "completed" and job["conclusion"] == "success" for job in jobs):
                    result = evaluate_records(record, run, jobs, summaries, approved=approved, fork=fork)
                    entry["evaluation"] = result
                    entry["status"] = "passed" if result["state"] == "success" and run["conclusion"] == "success" else "failed"
                elif not entry["diagnostics"]["failures"]:
                    entry["diagnostics"]["infrastructure"].append("required job failed, skipped or cancelled without an official test failure")
            if (fork or changing) and not approved:
                entry["status"] = "failed"
                entry["diagnostics"]["infrastructure"].append("exact head approval required; producer evidence is unapproved")
    except (ContractError, KeyError, ValueError, TypeError) as error:
        entry["status"] = "failed"
        # Only reporter/base-controlled diagnostics cross this boundary.
        entry["diagnostics"]["infrastructure"].append("missing, invalid or untrusted evidence")
    # Raw runner messages can contain private values even in otherwise valid JSON.
    for item in entry["observed"]:
        for attempt in item["attempts"]:
            attempt["message"] = None
            attempt["reason"] = "skip reason withheld; consult trusted policy" if attempt["outcome"] == "skipped" else None
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
    # Label indexing can lag an accepted create. Read the repository collection
    # and filter labels locally; fetch bodies directly to avoid stale list state.
    return [api.repo(f"issues/{item['number']}") for item in
            api.pages("issues", state="all", sort="updated", direction="desc")
            if "pull_request" not in item and any(value["name"] == label for value in item.get("labels", []))]


def wait_for_issue_visibility(api, number, label):
    deadline = time.monotonic() + 60
    while True:
        rows = api.pages("issues", state="all", sort="updated", direction="desc")
        if any(item["number"] == number and any(value["name"] == label for value in item.get("labels", [])) for item in rows):
            return
        require(time.monotonic() < deadline, "created issue is not yet visible; refusing further writes")
        time.sleep(min(2, max(0, deadline - time.monotonic())))


def synchronize_issues(api, entries, registry, *, label=LABEL):
    ensure_label(api, label)
    issues = visible_issues(api, label)
    registry_issues = {int(item["issue"].rsplit("/", 1)[-1]) for item in registry["entries"]}
    by_number = {item["number"]: item for item in issues if "pull_request" not in item}
    for number in registry_issues:
        issue = api.repo(f"issues/{number}", missing=True)
        if issue:
            by_number[number] = issue
    by_token = {}
    for issue in by_number.values():
        state = read_state(issue)
        if state:
            require(state["token"] not in by_token, "duplicate tracking issues; reconciliation required")
            by_token[state["token"]] = issue
    registry_tokens = {identity_token(item["identity"]): int(item["issue"].rsplit("/", 1)[-1]) for item in registry["entries"]}
    identities = {identity_token(item["identity"]): item["identity"] for report in entries
                  if report["source"]["workflow_path"] == NIGHTLY_PATH for item in report["observed"]}
    if any(report["source"]["workflow_path"] == NIGHTLY_PATH for report in entries):
        identities[identity_token(NIGHTLY_INFRASTRUCTURE)] = NIGHTLY_INFRASTRUCTURE
    receipts = []
    for token, identity in sorted(identities.items()):
        issue = by_token.get(token)
        registered = registry_tokens.get(token)
        if registered:
            require(registered in by_number, "registry issue is missing; refusing duplicate issue")
            require(not issue or issue["number"] == registered, "registry points to another issue; reconciliation required")
            issue = by_number[registered]
        state = read_state(issue) if issue else None
        decision = issue_decision(state, identity, entries, registry_referenced=bool(issue and issue["number"] in registry_issues))
        if decision["action"] == "none":
            continue
        state = decision["state"]
        payload = {"body": issue_body(issue, state, api.repository), "state": "closed" if state["closed"] else "open"}
        if issue:
            labels = [item["name"] for item in issue.get("labels", [])]
            if label not in labels:
                # A reused registry issue must remain discoverable after removal.
                payload["labels"] = labels + [label]
            api.repo(f"issues/{issue['number']}", method="PATCH", payload=payload)
        else:
            payload.pop("state")
            payload.update(title="CI nightly failure: " + identity["key"][:180], labels=[label])
            issue = api.repo("issues", method="POST", payload=payload)
            wait_for_issue_visibility(api, issue["number"], label)
        receipts.append({"issue": issue["number"], "action": decision["action"], "token": token})
    # One notification per failing main push SHA, shared across gate/UI reruns.
    pushes = {}
    for entry in entries:
        if entry["source"]["event"] == "push" and entry["status"] == "failed":
            pushed = entry.get("pushed_sha") or entry.get("identity", {}).get("pushed_sha")
            if pushed:
                pushes.setdefault(pushed, []).append(entry)
    for pushed, reports in sorted(pushes.items()):
        marker = "<!-- ci-report-post-merge:" + pushed + " -->"
        matching = [issue for issue in issues if marker in (issue.get("body") or "")]
        require(len(matching) <= 1, "duplicate post-merge issues")
        body = "A post-merge CI aggregate on main failed.\n\n" + marker + "\n\n" + "\n".join(render_entry(item) for item in reports)
        if matching:
            issue = matching[0]
            if issue["body"] != body:
                api.repo(f"issues/{issue['number']}", method="PATCH", payload={"body": body})
        else:
            issue = api.repo("issues", method="POST", payload={"title": "CI post-merge failure: " + pushed[:12], "body": body, "labels": [label]})
            wait_for_issue_visibility(api, issue["number"], label)
        receipts.append({"issue": issue["number"], "action": "post-merge", "sha": pushed})
    return receipts, {number: issue["state"] for number, issue in by_number.items()}


def main():
    from ci_publish import GitHub, trusted_admissions
    from ci_flaky import parse_registry
    check_context(os.environ)
    repository = os.environ["GITHUB_REPOSITORY"]
    api = GitHub(repository, os.environ["CI_REPORT_TOKEN"])
    now = datetime.now(timezone.utc).date()
    days = {now.isoformat(), (now - timedelta(days=1)).isoformat()}
    event = decode(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    if os.environ["GITHUB_EVENT_NAME"] == "workflow_run":
        triggering = api.repo(f"actions/runs/{event['workflow_run']['id']}")
        require(triggering["repository"]["full_name"] == repository and triggering["path"] in PRODUCER_PATHS, "unknown triggering workflow")
        # Branch nightly acceptance is diagnostic only, including the existing #158 runs.
        if triggering["path"] == NIGHTLY_PATH and triggering["head_branch"] != "main":
            print("Branch nightly is diagnostic; no reporting or issue writes.")
            return 0
        days.add(iso_day(triggering["created_at"][:10]))
    runs = {}
    for path in PRODUCER_PATHS:
        workflow = api.repo("actions/workflows/" + path.rsplit("/", 1)[-1], missing=True)
        if workflow is None:
            continue
        require(workflow["path"] == path, "producer workflow path mismatch")
        for day in sorted(days):
            for run in api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs", created=day + "T00:00:00Z.." + day + "T23:59:59Z"):
                require(run["workflow_id"] == workflow["id"] and run["path"] == path and run["repository"]["full_name"] == repository, "producer ID/path/repository mismatch")
                if path == NIGHTLY_PATH:
                    if run["head_branch"] != "main" or run["event"] not in {"schedule", "workflow_dispatch"}:
                        continue
                elif run["event"] not in {"pull_request", "push"} or run["event"] == "push" and run["head_branch"] != "main":
                    continue
                runs[run["id"]] = run
    admissions = trusted_admissions(api, [run["id"] for run in runs.values() if run["path"] != NIGHTLY_PATH])
    entries = [read_run(api, run, admissions) for run in sorted(runs.values(), key=lambda item: item["id"])]
    registry = parse_registry(Path("scripts/ci-known-flaky.json").read_text())
    receipts, states = synchronize_issues(api, entries, registry)
    checks = registry_checks(registry, now.isoformat(), states)
    output = Path(os.environ["RUNNER_TEMP"]) / "ci-report"
    for kind in ("daily", "pull-requests", "runs"):
        (output / kind).mkdir(parents=True, exist_ok=True)
    for day in sorted(days):
        rollup = daily_rollup(day, entries)
        rollup.update(registry=checks, issue_actions=receipts)
        (output / "daily" / (day + ".json")).write_text(json.dumps(rollup, indent=2) + "\n")
    for entry in entries:
        kind = "pull-requests" if entry["source"]["event"] == "pull_request" else "runs"
        stem = str(entry["run"]["id"]) + "-" + str(entry["run"]["attempt"])
        (output / kind / (stem + ".json")).write_text(json.dumps(entry, indent=2) + "\n")
        (output / kind / (stem + ".md")).write_text(render_entry(entry))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as handle:
            handle.write("# CI daily reporting\n\nDaily history: 90 days; PR summaries: 30 days; other summaries: 7 days.\n\n")
            for entry in entries:
                handle.write(render_entry(entry))
            handle.write("\nRegistry review: " + text(checks) + "\n\nIssue actions: " + text(receipts) + "\n")
    print(f"Reported {len(entries)} runs across {len(days)} UTC days; {len(receipts)} issue actions.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError, ValueError, KeyError, TypeError):
        # Neither credentials nor API/candidate payloads are included in failures.
        raise SystemExit("CI reporting refused: invalid context, evidence or issue state") from None
