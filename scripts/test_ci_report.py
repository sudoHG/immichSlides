"""Reporter decisions guard duplicate notifications, premature closure and lost provenance."""

import copy
import json
import hashlib
import os
import plistlib
import subprocess
import tempfile
import time
import unittest
from datetime import date, datetime, timezone
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import Mock, patch

import ci_report
from ci_summary import ContractError, observation, test_identity
from ci_report import (daily_rollup, identity_token, issue_decision, registry_checks,
                       render_entry, summary_diagnostics, synchronize_issues, read_state,
                       read_run, check_context, NIGHTLY_INFRASTRUCTURE)
from test_ci_summary import archive_download_summary, valid_summary


IDENTITY = {"kind": "strict", "key": "ExampleUITests/testPlayback",
            "dimensions": {"device": "iphone", "configuration": "Debug", "suite": "smoke",
                           "scenario": "normal", "fixture": "a"}}


def entry(day="2026-10-01", outcome="failed", run=10, attempt=1):
    return {"schema_version": 1, "day": day, "run": {"id": run, "attempt": attempt},
            "source": {"repository": "sudoHG/immichSlides", "workflow_path": ".github/workflows/ci-nightly.yml",
                       "event": "schedule", "fork_originated": False, "ci_changing": False,
                       "approval_based": False},
            "status": "failed" if outcome == "failed" else "passed", "release_eligible": False,
            "observed": [observation(IDENTITY, outcome, 1, exit_code=65 if outcome == "failed" else 0)],
            "diagnostics": {"counts": {}, "failures": [], "missing": [], "infrastructure": []}}


class ReporterTests(unittest.TestCase):
    def test_early_identity_receipts_and_runner_annotations_only_explain_current_missing_cases(self):
        from ci_nightly import aggregate_nightly, case_identity, shards
        from ci_publish import json_member
        from run_strict_e2e import FILTER_PERSON_SESSIONS, resolve_suite_selector
        from strict_e2e_p2_contract import P2_CASES
        matrix_path = Path(__file__).with_name("nightly-matrix.json")
        matrix = matrix_path.read_bytes()
        planned = shards(json.loads(matrix))
        target = next(item for item in planned if item["id"] == "iphone-immichSlides-iOS-debug-1")
        cases = [case_identity(case) for case in target["cases"]]
        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
               "head_sha": "a" * 40, "path": ci_report.NIGHTLY_PATH, "event": "schedule", "head_branch": "main",
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "status": "completed", "conclusion": "failure"}
        identity = {"schema_version": 1, "repository": "sudoHG/immichSlides", "event": "schedule",
                    "ref": "refs/heads/main", "commit_sha": run["head_sha"], "tree_sha": "b" * 40}
        hashes = {"manifests": {"nightly-matrix": hashlib.sha256(matrix).hexdigest()}, "policies": {"nightly": "c" * 64}}
        source = {"repository": identity["repository"], "workflow_path": ci_report.NIGHTLY_PATH, "event": "schedule",
                  "fork_originated": False, "ci_changing": None}
        plan = {"schema_version": 1, "identity": identity, "run": {"id": "10", "attempt": 1},
                "source": {**source, "approval_based": False}, "hashes": hashes, "shards": planned}
        summaries, members, intervals = [], {}, []
        for shard in planned:
            declared = [case_identity(case) for case in shard["cases"]]
            summary = valid_summary()
            summary.update(identity=identity, source=source, hashes=hashes,
                           run={"id": "10", "attempt": 1, "tier": "strict", "job": "nightly-strict", "shard": shard["id"]})
            observed = [observation(case, "needs-human-review" if case["dimensions"]["suite"] in P2_CASES else "passed", 1)
                        for case in declared]
            summary["population"].update(declared=declared, compiled=declared, observed=observed)
            summary["status"] = "unverified" if any(item["outcome"] == "needs-human-review" for item in observed) else "passed"
            warm = []
            for case in declared:
                suite = case["dimensions"]["suite"]
                selected = ([item["selector"] for item in FILTER_PERSON_SESSIONS] if suite == "filter-person" else
                            [resolve_suite_selector(shard["platform"], suite)])
                warm.append({"identity": case, "exit_code": 0, "build_operations": 0, "products_unchanged": True,
                    "log_present": True, "official_methods": [{"identifier": item.split("/", 1)[1], "result": "Passed"} for item in selected],
                    "official_summary": {"totalTestCount": len(selected), "passedTests": len(selected), "failedTests": 0, "skippedTests": 0}})
            if shard == target:
                target_summary, target_trace = summary, {"cold": [], "warm": warm}
                continue
            summaries.append(summary)
            artifact = "nightly-strict-" + shard["id"] + "-10-1"
            members[(artifact, "summary.json")] = summary
            members[(artifact, "trace.json")] = {"cold": [], "warm": warm}
            intervals.append({"shard": shard["id"]})
        failed_summary = next(item for item in summaries if item["population"]["declared"][0]["dimensions"]["suite"]
                              not in {*P2_CASES, "filter-vision"})
        failed_case = failed_summary["population"]["declared"][0]
        failed_summary["population"]["observed"][0] = observation(failed_case, "failed", 1, exit_code=65)
        failed_summary["status"] = "failed"
        failed_phase = members[("nightly-strict-" + failed_summary["run"]["shard"] + "-10-1", "trace.json")]["warm"][0]
        failed_phase["official_methods"][0]["result"] = "Failed"
        failed_phase["official_summary"]["passedTests"] -= 1
        failed_phase["official_summary"]["failedTests"] += 1
        failed_method = test_identity("strict", failed_phase["official_methods"][0]["identifier"], **failed_case["dimensions"])
        baseline_keys = {ci_report.identity_key(item) for summary in summaries for item in summary["population"]["declared"]
                         if item["dimensions"]["suite"] != "filter-vision"}
        baseline_keys.update(ci_report.identity_key(test_identity("strict", method["identifier"], **phase["identity"]["dimensions"]))
            for (name, member), trace in members.items() if member == "trace.json" for phase in trace["warm"]
            if phase["identity"]["dimensions"]["suite"] != "filter-vision" for method in phase["official_methods"])
        baseline_keys.discard(ci_report.identity_key(failed_case))
        stopped_missing = [{"identity": test_identity("strict", method["identifier"], **phase["identity"]["dimensions"]),
                            "reason": "official-method-not-observed"}
                           for phase in target_trace["warm"] for method in sorted(phase["official_methods"], key=lambda item: item["identifier"])]
        aggregate = aggregate_nightly([case_identity(case) for case in json.loads(matrix)["cases"]], summaries,
                                      live_in_scope=False, informational=["filter-vision"])
        aggregate.update(identity=identity, hashes=hashes, run=plan["run"], source=plan["source"],
                         capacity={"shard_intervals": intervals})
        members[("nightly-aggregate-10-1", "nightly.json")] = aggregate
        members[("nightly-plan-10-1", "plan.json")] = copy.deepcopy(plan)
        import run_strict_ci_tracer as tracer
        from ci_nightly import parse_identity_failure
        for failure in (subprocess.CalledProcessError(128, ["git", "rev-parse", "HEAD"],
                            output=b"private identity output", stderr=b"private identity error"),
                        subprocess.TimeoutExpired(["git", "rev-parse", "HEAD"], 30,
                            output=b"private identity output", stderr=b"private identity error")):
            def identity_failure(command, **options):
                self.assertEqual(["git", "rev-parse", "HEAD"], command)
                self.assertEqual(30, options["timeout"])
                raise failure
            with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
                    "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "schedule", "GITHUB_REPOSITORY": identity["repository"],
                    "GITHUB_RUN_ID": plan["run"]["id"], "GITHUB_RUN_ATTEMPT": str(plan["run"]["attempt"]),
                    "GITHUB_SHA": "f" * 40, "GITHUB_REF": "refs/heads/main"}), \
                    patch("run_host_checks.subprocess.check_output", side_effect=identity_failure) as identity_process:
                output = Path(directory) / "trace"
                with self.assertRaises(type(failure)) as raised:
                    tracer.main(["--platform", target["platform"], "--destination", "unused",
                                 "--manifest", str(matrix_path), "--shard", target["id"], "--output-dir", str(output)])
                self.assertIs(failure, raised.exception)
                identity_process.assert_called_once()
                self.assertEqual(["identity-failure.json"], [path.name for path in output.iterdir()])
                receipt = json.loads((output / "identity-failure.json").read_text())
                self.assertEqual({"schema_version": 1, "job": "nightly-strict", "shard": target["id"],
                    "run": plan["run"], "phase": "identity-collection", "reason": "identity-collection-failed", "declared": cases}, receipt)
                self.assertEqual(receipt, parse_identity_failure(receipt, plan["run"], target["id"], cases))
        receipt_name = "nightly-identity-" + target["id"] + "-10-1"
        variants = {"identity": "identity-collection-failed", "runner": "hosted-runner-disconnected",
            **{name: None for name in ("receipt-run", "receipt-attempt", "receipt-attempt-bool", "receipt-job", "receipt-shard", "receipt-version",
                "receipt-phase", "receipt-reason", "receipt-cases", "receipt-extra", "receipt-expired", "receipt-duplicate", "receipt-executed",
                "matrix-empty", "summary-not-run", "receipt-summary-not-run", "receipt-summary-failed", "receipt-record-present", "receipt-corrupt",
                "runner-summary-failed", "plan-corrupt",
                "previous-attempt", "plan-run", "plan-hashes", "annotation-level", "annotation-message",
                "plan-identity", "plan-source", "plan-version", "plan-shards", "plan-tree", "matrix-source", "plan-expired", "plan-duplicate", "plan-absent",
                "job-attempt", "job-status", "job-conclusion", "job-name", "check-url", "annotations-unavailable")},
            "annotation-retry": "hosted-runner-disconnected"}
        for variant, reason in variants.items():
            with self.subTest(variant=variant):
                saved = copy.deepcopy(members)
                supplied = copy.deepcopy(receipt)
                active_receipt_name = receipt_name
                if variant.startswith("receipt-"):
                    changes = {"receipt-job": ("job", "other"), "receipt-shard": ("shard", "other"),
                        "receipt-version": ("schema_version", True), "receipt-phase": ("phase", "other"),
                        "receipt-reason": ("reason", "private-reason"), "receipt-cases": ("declared", cases[:-1]),
                        "receipt-extra": ("path", "private-path")}
                    if variant in changes:
                        supplied[changes[variant][0]] = changes[variant][1]
                    if variant == "receipt-run":
                        supplied["run"]["id"] = "11"
                    if variant == "receipt-attempt":
                        supplied["run"]["attempt"] = 2
                    if variant == "receipt-attempt-bool":
                        supplied["run"]["attempt"] = True
                if variant == "receipt-executed":
                    supplied["shard"] = planned[0]["id"]
                    supplied["declared"] = [case_identity(case) for case in planned[0]["cases"]]
                    active_receipt_name = "nightly-identity-" + planned[0]["id"] + "-10-1"
                saved[(active_receipt_name, "identity-failure.json")] = supplied
                if variant == "matrix-empty":
                    saved[("nightly-aggregate-10-1", "nightly.json")]["matrix"] = {}
                stopped = variant in {"receipt-summary-not-run", "receipt-summary-failed", "runner-summary-failed"}
                if stopped or variant == "receipt-record-present":
                    summary = copy.deepcopy(target_summary)
                    summary["population"].update(compiled=[], observed=[observation(case, "not-run", 0,
                        exit_code=None, reason="strict-tracer-failed") for case in cases])
                    summary["status"] = "failed"
                    if variant in {"receipt-summary-failed", "runner-summary-failed"}:
                        for item in summary["population"]["observed"]:
                            item["outcome"] = "failed"
                    saved[("nightly-strict-" + target["id"] + "-10-1", "summary.json")] = summary
                    saved[("nightly-strict-" + target["id"] + "-10-1", "trace.json")] = {"cold": [], "warm": []}
                    if stopped:
                        raw = saved[("nightly-aggregate-10-1", "nightly.json")]
                        raw["capacity"]["shard_intervals"].append({"shard": target["id"]})
                        raw["observed"].extend(summary["population"]["observed"])
                if variant == "summary-not-run":
                    informational_shard = next(shard for shard in planned if shard["id"] != failed_summary["run"]["shard"]
                        and any(case["suite"] == "filter-vision" for case in shard["cases"]))
                    name = "nightly-strict-" + informational_shard["id"] + "-10-1"
                    summary = saved[(name, "summary.json")]
                    informational_cases = summary["population"]["declared"]
                    informational_keys = {ci_report.identity_key(case) for case in informational_cases}
                    expected_missing = [{"identity": case, "reason": "missing or invalid shard evidence"} for case in cases]
                    expected_missing.extend({"identity": test_identity("strict", method["identifier"], **phase["identity"]["dimensions"]),
                        "reason": "official-method-not-observed"} for phase in saved[(name, "trace.json")]["warm"]
                        if phase["identity"]["dimensions"]["suite"] != "filter-vision" for method in phase["official_methods"])
                    summary["population"].update(compiled=[], observed=[observation(case, "not-run", 0,
                        exit_code=None, reason="strict-tracer-failed") for case in informational_cases])
                    summary["status"] = "failed"
                    saved[(name, "trace.json")] = {"cold": [], "warm": []}
                    raw = saved[("nightly-aggregate-10-1", "nightly.json")]
                    raw["matrix"]["missing"].extend(informational_cases)
                    raw["matrix"]["executed"] -= len(informational_cases)
                    for collection in ("observed", "informational"):
                        raw[collection] = [item for item in raw[collection] if ci_report.identity_key(item["identity"]) not in informational_keys]
                        raw[collection].extend(item for item in summary["population"]["observed"]
                            if collection == "observed" or item["identity"]["dimensions"]["suite"] == "filter-vision")
                if variant == "plan-run":
                    saved[("nightly-plan-10-1", "plan.json")]["run"]["attempt"] = 2
                if variant == "plan-hashes":
                    saved[("nightly-plan-10-1", "plan.json")]["hashes"]["policies"]["nightly"] = "d" * 64
                if variant == "plan-identity":
                    saved[("nightly-plan-10-1", "plan.json")]["identity"]["commit_sha"] = "d" * 40
                if variant == "plan-source":
                    saved[("nightly-plan-10-1", "plan.json")]["source"]["fork_originated"] = True
                if variant == "plan-version":
                    saved[("nightly-plan-10-1", "plan.json")]["schema_version"] = True
                if variant == "plan-shards":
                    saved[("nightly-plan-10-1", "plan.json")]["shards"] = planned[:-1]
                use_receipt = variant == "identity" or variant.startswith(("receipt-", "plan-")) or variant in {"previous-attempt", "matrix-source"}
                artifacts = [{"id": number + 1, "name": name, "size_in_bytes": 1,
                              "expired": (variant == "receipt-expired" and name == active_receipt_name)
                              or (variant == "plan-expired" and name == "nightly-plan-10-1")}
                             for number, name in enumerate(sorted({name for name, member in saved if use_receipt or name != active_receipt_name}))]
                if variant == "receipt-duplicate":
                    artifacts.append({"id": 1000, "name": active_receipt_name, "size_in_bytes": 1, "expired": False})
                if variant == "plan-duplicate":
                    artifacts.append({"id": 1001, "name": "nightly-plan-10-1", "size_in_bytes": 1, "expired": False})
                if variant == "plan-absent":
                    artifacts = [item for item in artifacts if item["name"] != "nightly-plan-10-1"]
                if variant == "previous-attempt":
                    next(item for item in artifacts if item["name"] == receipt_name)["name"] = receipt_name[:-1] + "2"
                    saved[(receipt_name[:-1] + "2", "identity-failure.json")] = saved.pop((receipt_name, "identity-failure.json"))
                job = {"id": 99, "run_id": 10, "run_attempt": 2 if variant == "job-attempt" else 1,
                       "name": "nightly-strict-" + target["id"], "status": "completed", "conclusion": "failure",
                       "check_run_url": "https://api.github.com/repos/sudoHG/immichSlides/check-runs/99"}
                if variant == "check-url":
                    job["check_run_url"] = job["check_run_url"].replace("sudoHG/immichSlides", "other/repository")
                if variant == "job-status":
                    job["status"] = "in_progress"
                if variant == "job-conclusion":
                    job["conclusion"] = "success"
                if variant == "job-name":
                    job["name"] = "unrelated"
                # Recorded shape from check-run 116180291564; only the fixed marker is retained.
                annotations = [{"path": ".github", "start_line": 1, "end_line": 1, "start_column": None, "end_column": None,
                    "annotation_level": "warning" if variant == "annotation-level" else "failure", "title": "",
                    "message": ("Unrelated failure" if variant == "annotation-message" else
                        "The hosted runner lost communication with the server") + ". private-annotation-detail",
                    "raw_details": "private-raw-detail", "blob_href": ""}]
                class API(ci_report.ReportGitHub):
                    def __init__(self):
                        super().__init__(identity["repository"], "", dry_run=True)
                        self.annotation_calls = 0
                    def respond(self, path, **options):
                        if "/artifacts?" in path:
                            return {"artifacts": artifacts}
                        if "/jobs?" in path:
                            return {"total_count": 1, "jobs": [job]}
                        if "/annotations?" in path:
                            self.annotation_calls += 1
                            if variant == "annotations-unavailable":
                                raise ContractError("private-api-error")
                            if variant == "annotation-retry" and self.annotation_calls == 1:
                                from ci_publish import GitHubRequestError
                                raise GitHubRequestError("private-transient-error", http_status=503, retry_delay=1)
                            return annotations
                        if variant in {"receipt-corrupt", "plan-corrupt"} and path.endswith("/zip"):
                            return b"not a ZIP archive"
                        raise AssertionError(path)
                api = API()
                if use_receipt or variant == "summary-not-run":
                    job["name"] = "unrelated"
                def git_output(command, **options):
                    if command[1] == "rev-parse":
                        return (b"d" if variant == "plan-tree" else b"b") * 40 + b"\n"
                    return matrix + (b" " if variant == "matrix-source" else b"")
                def read_member(api, artifact, member):
                    if (artifact["expired"] or variant == "receipt-corrupt" and member == "identity-failure.json"
                            or variant == "plan-corrupt" and member == "plan.json"):
                        return json_member(api, artifact, member)
                    return saved[(artifact["name"], member)]
                with patch("ci_publish.json_member", side_effect=read_member), \
                        patch("ci_report.on_main", return_value=True), patch("subprocess.check_output", side_effect=git_output), \
                        patch("ci_publish.GitHub._request", side_effect=api.respond), \
                        patch("ci_publish.time.sleep"):
                    report = read_run(api, run, {})
                self.assertEqual("failed", report["status"])
                self.assertIn(failed_method, [item["identity"] for item in report["observed"] if item["outcome"] == "failed"])
                expected_executed = 0 if variant == "matrix-empty" else 129 - len(informational_cases) if variant == "summary-not-run" else 129
                self.assertEqual(expected_executed, report["diagnostics"]["counts"]["executed_cases"])
                if variant == "matrix-empty":
                    self.assertEqual([], report["diagnostics"]["missing"])
                elif variant == "summary-not-run":
                    self.assertCountEqual(expected_missing, report["diagnostics"]["missing"])
                    self.assertEqual(len((baseline_keys - informational_keys)
                        | {ci_report.identity_key(item["identity"]) for item in expected_missing}), report["diagnostics"]["counts"]["declared"])
                elif stopped:
                    expected = stopped_missing + ([{"identity": case, "reason": "strict-case-infrastructure-or-unverified-failure"}
                        for case in cases] if variant in {"receipt-summary-failed", "runner-summary-failed"} else [])
                    self.assertCountEqual(expected, report["diagnostics"]["missing"])
                    self.assertEqual(len(baseline_keys | {ci_report.identity_key(item["identity"]) for item in expected}),
                                     report["diagnostics"]["counts"]["declared"])
                else:
                    self.assertEqual(6, len(report["diagnostics"]["missing"]))
                    self.assertCountEqual(cases, [item["identity"] for item in report["diagnostics"]["missing"]])
                self.assertTrue(report["observed"], "other shards' verified results must survive")
                self.assertTrue(all(item["outcome"] != "not-run" for item in report["observed"]))
                if not stopped and variant != "summary-not-run":
                    self.assertTrue(all(item["reason"] == (reason or "missing or invalid shard evidence")
                                        for item in report["diagnostics"]["missing"]))
                if reason:
                    self.assertIn(reason, report["diagnostics"]["infrastructure"])
                    state = issue_decision(None, NIGHTLY_INFRASTRUCTURE, [report], registry_referenced=False)["state"]
                    visible = ci_report.issue_body(None, state, api.repository).split(ci_report.MARKER)[0]
                    self.assertIn("| UTC night | Run | Outcome | Archive gate reason | Early infrastructure reason |", visible)
                    self.assertIn("| --- | --- | --- | --- | --- |", visible)
                    self.assertIn("| failed | — | " + reason + " |", visible)
                    edited = copy.deepcopy(state)
                    edited["nights"][report["day"]]["10"]["early_failure_reasons"] = ["private-manual-reason"]
                    self.assertNotIn("private", ci_report.issue_body(None, edited, api.repository).split(ci_report.MARKER)[0])
                    later = copy.deepcopy(report)
                    later.pop("attempt_history")
                    later["run"]["attempt"] = 2
                    later["status"] = "passed"
                    later["diagnostics"]["infrastructure"] = []
                    later_state = issue_decision(state, NIGHTLY_INFRASTRUCTURE, [later], registry_referenced=False)["state"]
                    later_visible = ci_report.issue_body(None, later_state, api.repository).split(ci_report.MARKER)[0]
                    self.assertIn("Run 10, attempt 2", later_visible)
                    self.assertIn("| failed | — | " + reason + " |", later_visible)
                else:
                    self.assertFalse({"identity-collection-failed", "hosted-runner-disconnected"}
                                     & set(report["diagnostics"]["infrastructure"]))
                self.assertNotIn("private", json.dumps(ci_report.compact_entry(report, set())))
                self.assertFalse(api.retry_reads)
                if variant in {"job-name", "job-status", "job-conclusion", "check-url", "job-attempt", "runner-summary-failed"}:
                    self.assertEqual(0, api.annotation_calls)
                if variant == "annotation-retry":
                    self.assertEqual(2, api.annotation_calls)
                    self.assertEqual(4, api.request_count)

    def test_validator_receipt_survives_case_aggregation_compaction_and_report(self):
        from html import unescape
        from ci_nightly import aggregate_nightly
        case = test_identity("strict", "smoke", **IDENTITY["dimensions"])
        message = "unreadable public glyph slot; slot 1 (horizontal); screenshot person-normal.png"
        shard = valid_summary()
        shard["population"].update(declared=[case], compiled=[case], observed=[observation(case, "failed", 1, exit_code=2)])
        shard["status"] = "failed"
        phase = {"identity": case, "exit_code": 2, "automated_contract_failed": True,
                 "build_operations": 0, "products_unchanged": True, "log_present": True,
                 "official_methods": [{"identifier": "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke", "result": "Passed"}],
                 "official_summary": {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}}
        historical, _ = ci_report.method_observations(shard, {"warm": [phase]})
        self.assertTrue(all("validator_failure_message" not in item for item in historical))
        overlong = ("no public glyph; screenshot person-normal.png" + "; context unresolved" * 16
                    + "; slot 1 (horizontal)" * 7).replace("slot 1 (", "slot 10 (", 1)
        cases = ((message, message), (None, "unresolved"),
                 (message + "; https://private.invalid/api", "[redacted validator failure]"),
                 (message.replace("person-normal.png", "/private/person-normal.png"), "[redacted validator failure]"),
                 (overlong, "[redacted validator failure]"))
        for supplied, expected in cases:
            with self.subTest(supplied=supplied):
                warm = dict(phase)
                warm["validator_failure_message"] = supplied
                observed, missing = ci_report.method_observations(shard, {"warm": [warm]})
                self.assertEqual([], missing)
                failed = next(item for item in observed if item["identity"] == case)
                self.assertEqual(expected, failed["validator_failure_message"])
                self.assertEqual(expected, failed["attempts"][0]["validator_failure_message"])
                self.assertEqual(("failed", 2, "strict-case-contract-failed"),
                    (failed["outcome"], failed["attempts"][0]["exit_code"], failed["attempts"][0]["reason"]))
                shard["population"]["observed"] = [failed]
                aggregate = aggregate_nightly([case], [shard], live_in_scope=False)
                self.assertEqual(expected, aggregate["observed"][0]["validator_failure_message"])
                report = entry()
                report["observed"] = observed
                report["diagnostics"] = summary_diagnostics([shard])
                compact = ci_report.compact_entry(report, set())
                self.assertEqual(expected, compact["observed"][-1]["validator_failure_message"])
                self.assertIn("| Validator failure |", render_entry(compact))
                self.assertIn(expected, unescape(render_entry(compact)))
                self.assertNotIn("private.invalid", json.dumps(compact))
        for outcome in ("crashed", "timed-out"):
            with self.subTest(outcome=outcome):
                shard["population"]["observed"] = [observation(case, outcome, 1, exit_code=2)]
                observed, _ = ci_report.method_observations(shard, {"warm": [{**phase, "validator_failure_message": message}]})
                failed = next(item for item in observed if item["identity"] == case)
                ci_report.validate_observation(failed)
                self.assertEqual(outcome, failed["outcome"])

    def test_nightly_preparation_failure_tracks_missing_cases_under_one_infrastructure_issue(self):
        from ci_nightly import aggregate_nightly
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
               "head_sha": "a" * 40, "path": ci_report.NIGHTLY_PATH, "event": "schedule", "head_branch": "main",
               "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "failure"}
        identity = {"schema_version": 1, "repository": api.repository, "event": "schedule", "ref": "refs/heads/main",
                    "commit_sha": run["head_sha"], "tree_sha": "b" * 40}
        cases = [test_identity("strict", "p2-exif", **{**IDENTITY["dimensions"], "device": "ipad",
                  "suite": "p2-exif", "fixture": str(number)}) for number in range(6)]
        summary = valid_summary()
        summary["identity"] = identity
        summary["source"].update(event="schedule", workflow_path=ci_report.NIGHTLY_PATH)
        summary["run"] = {"id": "10", "attempt": 1, "tier": "strict", "job": "nightly-strict", "shard": "ipad"}
        summary["population"].update(declared=cases, compiled=[], observed=[
            dict(observation(case, "not-run", 0, reason="simulator preparation infrastructure failure", exit_code=None),
                 outcome="failed") for case in cases])
        summary["status"] = "failed"
        summary["infrastructure"] = [{"code": "simulator-preparation-failed", "message": "Preparation failed before tracer execution"}]
        aggregate = aggregate_nightly(cases, [summary], live_in_scope=False)
        aggregate.update(identity=identity, hashes=summary["hashes"], run={"id": "10", "attempt": 1},
                         source=summary["source"], capacity={"shard_intervals": [{"shard": "ipad"}]})
        artifacts = [{"name": name, "expired": False} for name in ("nightly-aggregate-10-1", "nightly-strict-ipad-10-1")]
        with patch("ci_publish.json_member", side_effect=[aggregate, summary, {"cold": [], "warm": []}]):
            report = ci_report.nightly_attempt(api, run, 1, artifacts)
        self.assertEqual("failed", report["status"])
        self.assertEqual([], report["observed"])
        self.assertEqual(0, report["diagnostics"]["counts"]["executed_cases"])
        self.assertEqual([], report["diagnostics"]["failures"])
        self.assertTrue(report["diagnostics"]["infrastructure"])
        missing_cases = [item for item in report["diagnostics"]["missing"]
                         if item["reason"] == "strict-case-infrastructure-or-unverified-failure"]
        self.assertEqual(cases, [item["identity"] for item in missing_cases])
        from run_strict_e2e import resolve_suite_selector
        missing_methods = [item["identity"] for item in report["diagnostics"]["missing"]
                           if item["reason"] == "official-method-not-observed"]
        expected_methods = [test_identity("strict", resolve_suite_selector("ios", case["dimensions"]["suite"]).split("/", 1)[1],
                            **case["dimensions"]) for case in cases]
        self.assertCountEqual(expected_methods, missing_methods)
        for case in cases:
            with self.subTest(case=case):
                self.assertEqual("none", issue_decision(None, case, [report], registry_referenced=False)["action"])
        self.assertEqual("open", issue_decision(None, NIGHTLY_INFRASTRUCTURE, [report], registry_referenced=False)["action"])

    def test_nightly_producer_failure_paths_preserve_other_shards_and_diagnostic_identity(self):
        import ci_nightly
        import ci_nightly_ui
        import ci_ui_tests
        import run_fixture_ui_tests as fixture
        from run_strict_e2e import resolve_suite_selector
        current_plan = ci_nightly_ui.current_plan
        repository = "sudoHG/immichSlides"
        identity = {"schema_version": 1, "repository": repository, "event": "workflow_dispatch",
                    "ref": "refs/heads/candidate", "commit_sha": "a" * 40, "tree_sha": "b" * 40}
        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
               "head_sha": identity["commit_sha"], "path": ci_report.NIGHTLY_PATH, "event": "workflow_dispatch",
               "head_branch": "candidate", "head_repository": {"full_name": repository},
               "status": "completed", "conclusion": "failure"}
        api = type("API", (), {"repository": repository, "dry_run": True, "diagnostic_nightly": True})()
        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        registry = {"schema_version": 1, "entries": []}
        project = Path(__file__).resolve().parent.parent
        blobs = {"scripts/ci-test-policy.json": json.dumps(policy).encode(),
                 "scripts/ci-known-flaky.json": json.dumps(registry).encode(),
                 "scripts/strict_e2e_server.py": project.joinpath("scripts/strict_e2e_server.py").read_bytes(),
                 "scripts/ci-ui-shards.json": json.dumps({"schema_version": 1, "revision": "example-v1",
                     "default_shard": "default", "shards": {"default": [], "navigation": ["NavigationUITests"],
                                                           "visual": ["VisualUITests"]}}).encode(),
                 "immichSlidesUITests/Example.swift": b"\n".join(
                     ("final class " + name + "UITests: XCTestCase { func testPlayback() {} }").encode()
                     for name in ("Default", "Navigation", "Visual"))}
        for platform in ("iOS", "tvOS"):
            blobs["immichSlides-" + platform + ".xctestplan"] = json.dumps(
                {"testTargets": [{"target": {"name": "immichSlidesUITests"}}]}).encode()
        def git_output(command, **kwargs):
            if command[1] == "ls-tree":
                return b"100644 blob " + b"d" * 40 + b"\timmichSlidesUITests/Example.swift\0"
            if command[1] == "rev-parse":
                return b"b" * 40 + b"\n"
            return blobs[command[-1].split(":", 1)[1]]
        for mode in ("ui-only", "consumer-preflight", "strict-only", "single-shard", "missing-ui"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory, "source")
                for name, blob in blobs.items():
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(blob)
                records = Path(directory, "records")
                records.mkdir()
                environment = {"GITHUB_RUN_ID": "10", "GITHUB_RUN_ATTEMPT": "1"}
                with patch.dict(os.environ, environment, clear=True), \
                        patch("run_host_checks.run_identity", return_value=identity), \
                        patch("run_host_checks.source_metadata", return_value=(ci_report.NIGHTLY_PATH, False)), \
                        patch.object(ci_nightly, "run_identity", return_value=identity), \
                        patch.object(ci_nightly, "source_metadata", return_value=(ci_report.NIGHTLY_PATH, False)), \
                        patch.object(ci_nightly, "workspace_preflight"), \
                        patch.object(ci_nightly_ui, "current_plan", side_effect=lambda ignored: current_plan(root)):
                    ui_plan = ci_nightly_ui.current_plan(root)
                    members = {}
                    if mode in {"ui-only", "consumer-preflight"}:
                        for number, item in enumerate(ui_plan["shards"]):
                            device, shard = item["device"], item["shard"]
                            name = f"ui-{device}-{shard}-10-1"
                            output = records / name
                            test = item["declared"][0]
                            if number == 0 and mode == "consumer-preflight":
                                args = type("Args", (), {"device": device, "shard": shard, "output_dir": output,
                                                        "manifest_revision": None})()
                                with patch.object(ci_ui_tests, "ROOT", root), \
                                        patch.object(ci_ui_tests, "context", return_value=copy.deepcopy({
                                            "identity": identity, "source": ui_plan["source"], "run": ui_plan["run"]})), \
                                        patch.object(fixture, "registry_revision", return_value="HEAD"), \
                                        patch.object(fixture, "load_registry", return_value=(registry, hashlib.sha256(
                                            blobs["scripts/ci-known-flaky.json"]).hexdigest())):
                                    ci_ui_tests.failed_shard(args, OSError("archive relocation failed"))
                            else:
                                products = Path(directory, "products")
                                (products / "Debug-simulator/immichSlides.app").mkdir(parents=True, exist_ok=True)
                                xctestrun = products / "tests.xctestrun"
                                xctestrun.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [
                                    {"BlueprintName": "immichSlidesUITests"}]}]}))
                                bundle = Path(directory, "private", name, "results", "test.xcresult")
                                bundle.parent.mkdir(parents=True)
                                def popen(command, **kwargs):
                                    if "-enumerate-tests" in command:
                                        path = Path(command[command.index("-test-enumeration-output-path") + 1])
                                        path.write_text(json.dumps({"errors": [], "values": [{"enabledTests": [
                                            {"identifier": "immichSlidesUITests/" + test["key"]}]}]}))
                                    return Mock(wait=Mock(return_value=0))
                                outcome = "failed" if number == 1 else "passed"
                                retry = {"observed": [observation(test, outcome, 2, exit_code=65 if outcome == "failed" else 0)],
                                         "infrastructure": [], "exit_code": 65 if outcome == "failed" else 0,
                                         "invocations": [{"exit_code": 65 if outcome == "failed" else 0}]}
                                execution_day = [date(2026, 10, 1)]
                                def simulator_preflight(*args):
                                    fixture.prepare_simulator.assert_called_once()
                                    execution_day[0] = date(2026, 10, 2)
                                    if number == 0:
                                        raise OSError("simulator unavailable")
                                retry_runner = Mock(return_value=retry)
                                with ExitStack() as stack:
                                    patches = [patch.object(fixture, "ROOT", root), patch.object(fixture, "run_identity", return_value=identity),
                                        patch.object(fixture, "source_metadata", return_value=(ci_report.NIGHTLY_PATH, False)),
                                        patch.object(fixture, "toolchain", return_value={"versions": {}, "signing_mode": "not-applicable"}),
                                        patch.object(fixture, "prepare_simulator", return_value=(None, "ready\n")),
                                        patch.object(fixture, "registry_revision", return_value="HEAD"),
                                        patch.object(fixture, "load_registry", return_value=(registry, hashlib.sha256(
                                            blobs["scripts/ci-known-flaky.json"]).hexdigest())),
                                        patch.object(fixture.subprocess, "run", return_value=Mock(returncode=0, stdout=b"{}")),
                                        patch.object(fixture, "verify_simulator_device", side_effect=simulator_preflight),
                                        patch.object(fixture, "date", Mock(today=Mock(side_effect=lambda: execution_day[0]))),
                                        patch.object(fixture, "prepare_fixture_result_bundle", return_value=bundle),
                                        patch.object(fixture.subprocess, "Popen", side_effect=popen),
                                        patch.object(fixture, "wait_for_service", return_value=("127.0.0.1", 1)),
                                        patch.object(fixture, "check_products"), patch.object(fixture, "measure_signing", return_value="adhoc"),
                                        patch.object(fixture, "disk_check"), patch.object(fixture, "reset_simulator_app"),
                                        patch.object(fixture, "run_xcode_attempts", retry_runner),
                                        patch.object(fixture, "stop_exact_process"), patch.object(fixture, "finalize_fixture_run", return_value=[])]
                                    for applied in patches:
                                        stack.enter_context(applied)
                                    result = fixture.main(["--device", device, "--destination", "platform=" + (
                                        "tvOS" if device == "appletv" else "iOS") + " Simulator,id=" + "A" * 8 + "-" + "B" * 4 + "-" +
                                        "C" * 4 + "-" + "D" * 4 + "-" + "E" * 12, "--xctestrun", str(xctestrun),
                                        "--output-dir", str(output), "--shard", shard, "--shard-manifest", str(root / "scripts/ci-ui-shards.json"),
                                        "--only-testing", "immichSlidesUITests/" + test["key"], "--listed-only-retry"])
                                self.assertEqual(1 if number == 0 else 65 if number == 1 else 0, result)
                                if number != 0:
                                    self.assertEqual(date(2026, 10, 2), retry_runner.call_args.kwargs["today"])
                            summary = json.loads((output / "summary.json").read_text())
                            self.assertEqual(ui_plan["hashes"][device], summary["hashes"])
                            self.assertEqual(item["declared"], summary["population"]["declared"])
                            members[(name, "summary.json")] = summary
                            (output / "shard-timing.json").write_text(json.dumps({"device": device, "shard": shard,
                                "started_epoch": ui_plan["started_epoch"], "finished_epoch": time.time()}))
                        ui = ci_nightly_ui.aggregate_ui(ui_plan, records, matrix_job_result="failure", root=root)
                        ui_path = Path(directory, "nightly-ui.json")
                        ui_path.write_text(json.dumps(ui))
                        members[("nightly-ui-aggregate-10-1", "nightly-ui.json")] = ui
                    else:
                        ui_path = Path(directory, "absent-ui.json")
                    plan_dir = Path(directory, "plan")
                    selected = ci_nightly.shards(ci_nightly.parse_manifest(ci_nightly.MATRIX.read_text()))[0]
                    option = ["--only-shard", selected["id"]] if mode == "single-shard" else ["--diagnostic-tier", "strict" if mode == "strict-only" else "ui"]
                    ci_nightly.main(["plan", "--output-dir", str(plan_dir)] + option)
                    plan = json.loads((plan_dir / "plan.json").read_text())
                    members[("nightly-plan-10-1", "plan.json")] = plan
                    strict_records = Path(directory, "strict-records")
                    strict_records.mkdir()
                    if mode in {"strict-only", "single-shard"}:
                        cases = [ci_nightly.case_identity(case) for case in selected["cases"]]
                        summary = valid_summary()
                        summary.update(identity=identity, hashes=plan["hashes"], source=ui_plan["source"],
                                       run={**plan["run"], "tier": "strict", "job": "nightly-strict", "shard": selected["id"]})
                        summary["population"].update(declared=cases, compiled=cases, observed=[observation(case, "passed", 2) for case in cases])
                        trace = {"started_epoch": plan["started_epoch"], "finished_epoch": time.time(), "warm": [
                            {"identity": case, "official_methods": [{"identifier": resolve_suite_selector("ios", case["dimensions"]["suite"]).split("/", 1)[1], "result": "Passed"}],
                             "official_summary": {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0},
                             "build_operations": 0, "products_unchanged": True, "log_present": True, "exit_code": 0} for case in cases]}
                        shard_records = strict_records / f"nightly-strict-{selected['id']}-10-1"
                        shard_records.mkdir()
                        for member, value in (("summary.json", summary), ("trace.json", trace), ("p2-review-bindings.json", {"schema_version": 1, "review_packages": []})):
                            shard_records.joinpath(member).write_text(json.dumps(value))
                            members[(f"nightly-strict-{selected['id']}-10-1", member)] = value
                    aggregate_dir = Path(directory, "aggregate")
                    self.assertEqual(1, ci_nightly.main(["aggregate", "--output-dir", str(aggregate_dir), "--plan", str(plan_dir / "plan.json"),
                        "--records-dir", str(strict_records), "--matrix-job-result", "failure", "--ui-record", str(ui_path)]))
                    raw = json.loads((aggregate_dir / "nightly.json").read_text())
                    members[("nightly-aggregate-10-1", "nightly.json")] = raw
                    artifacts = [{"name": name, "expired": False} for name in sorted({name for name, _ in members})]
                    with patch("ci_publish.json_member", side_effect=lambda api, artifact, member: members[(artifact["name"], member)]) as member_reader, \
                            patch("subprocess.check_output", side_effect=git_output):
                        report = ci_report.nightly_attempt(api, run, 1, artifacts)
                    self.assertEqual(plan["diagnostic_shard"], report["diagnostic_shard"])
                    self.assertEqual("failed", report["status"])
                    if mode in {"ui-only", "consumer-preflight"}:
                        self.assertEqual("ui-only", report["diagnostic_shard"])
                        self.assertEqual((9, 8), (report["diagnostics"]["counts"]["ui_scheduled"], report["diagnostics"]["counts"]["ui_executed"]))
                        self.assertEqual([ui_plan["shards"][0]["declared"][0]], [item["identity"] for item in report["diagnostics"]["missing"]])
                        self.assertEqual([ui_plan["shards"][1]["declared"][0]], [item["identity"] for item in report["diagnostics"]["failures"]])
                        self.assertEqual(ui, raw["ui"])
                    else:
                        self.assertEqual(1, raw["schema_version"])
                        self.assertNotIn("ui", raw)
                        if mode == "missing-ui":
                            self.assertIn("nightly infrastructure or scheduling failure", report["diagnostics"]["infrastructure"])
                        else:
                            self.assertEqual(2 * len(cases), len(report["observed"]))
                            self.assertTrue(all(item["outcome"] == "passed" for item in report["observed"]))
                            if mode == "single-shard":
                                self.assertEqual([], report["diagnostics"]["missing"])
                                self.assertEqual(2 * len(cases), report["diagnostics"]["counts"]["declared"])
                                self.assertFalse(any(call.args[2] == "plan.json" for call in member_reader.call_args_list))

    def test_nightly_ui_reader_rejects_missing_samples_and_foreign_shards(self):
        from ci_nightly_ui import judge_ui, parse_ui_plan, validate_ui_record
        identity = {"schema_version": 1, "repository": "sudoHG/immichSlides", "event": "schedule",
                    "ref": "refs/heads/main", "commit_sha": "a" * 40, "tree_sha": "b" * 40}
        plan = {"schema_version": 1, "identity": identity, "run": {"id": "10", "attempt": 1},
                "source": {"repository": identity["repository"], "workflow_path": ci_report.NIGHTLY_PATH,
                           "event": "schedule", "fork_originated": False, "ci_changing": None},
                "hashes": {}, "shards": [], "max_parallel": 2, "started_epoch": 1}
        summaries = []
        for device, platform in (("iphone", "ios"), ("ipad", "ios"), ("appletv", "tvos")):
            plan["hashes"][device] = {"manifests": {"ui-shards": "c" * 64}, "policies": {}}
            for shard in ("default", "navigation", "visual"):
                test = test_identity("ui", "ExampleUITests/test" + shard.capitalize(), platform=platform, device=device)
                plan["shards"].append({"device": device, "shard": shard, "declared": [test]})
                summary = valid_summary()
                summary.update(identity=identity, source=plan["source"], hashes=plan["hashes"][device],
                               run={**plan["run"], "tier": "ui", "job": "ui-" + device, "shard": shard})
                summary["population"].update(declared=[test], compiled=[test], observed=[observation(test, "passed", 2)])
                summaries.append(summary)
        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        good = judge_ui(plan, summaries, policy=policy, registry={"schema_version": 1, "entries": []},
                        evaluated_on=date(2026, 10, 1), matrix_job_result="success")
        self.assertEqual("passed", good["status"])
        self.assertEqual(9, good["matrix"]["executed"])
        expanded, expanded_summaries = copy.deepcopy(plan), copy.deepcopy(summaries)
        for device, platform in (("iphone", "ios"), ("ipad", "ios"), ("appletv", "tvos")):
            next(item for item in expanded["shards"] if item["device"] == device and item["shard"] == "visual")["shard"] = "visual-1"
            original = next(item for item in expanded_summaries if item["run"]["job"] == "ui-" + device and item["run"]["shard"] == "visual")
            original["run"]["shard"] = "visual-1"
            extra = test_identity("ui", "ExampleUITests/testVisualMore", platform=platform, device=device)
            expanded["shards"].append({"device": device, "shard": "visual-2", "declared": [extra]})
            summary = copy.deepcopy(original)
            summary["run"]["shard"] = "visual-2"
            summary["population"].update(declared=[extra], compiled=[extra], observed=[observation(extra, "passed", 1)])
            expanded_summaries.append(summary)
        expanded_good = judge_ui(expanded, expanded_summaries, policy=policy, registry={"schema_version": 1, "entries": []},
                                 evaluated_on=date(2026, 10, 1), matrix_job_result="success")
        self.assertEqual(("passed", 12), (expanded_good["status"], expanded_good["matrix"]["executed"]))
        intervals = [{"shard": item["device"] + "/" + item["shard"], "started_epoch": index + 1, "finished_epoch": index + 2}
                     for index, item in enumerate(expanded["shards"])]
        expanded_record = {"schema_version": 1, "plan": expanded, "verdict": expanded_good, "matrix_job_result": "success",
            "capacity": {"max_parallel": 2, "shards": 12, "minimum_shard_waves": 6, "shard_intervals": intervals,
                         "start_order_waves": [[item["shard"] for item in intervals[index:index + 2]] for index in range(0, 12, 2)],
                         "wall_seconds": 14}}
        validate_ui_record(expanded_record, expanded_summaries, policy=policy, registry={"schema_version": 1, "entries": []},
                           evaluated_on=date(2026, 10, 1))
        stale_capacity = copy.deepcopy(expanded_record)
        stale_capacity["capacity"].update(shards=9, minimum_shard_waves=5)
        with self.assertRaises(ContractError):
            validate_ui_record(stale_capacity, expanded_summaries, policy=policy, registry={"schema_version": 1, "entries": []},
                               evaluated_on=date(2026, 10, 1))
        from ci_nightly_change import ui_tier_complete
        def ui_record(verdict, job_result, skip_interval=None):
            return {"plan": plan, "verdict": verdict, "matrix_job_result": job_result, "capacity": {"shard_intervals": [
                {"shard": item["device"] + "/" + item["shard"], "started_epoch": 1, "finished_epoch": 2}
                for item in plan["shards"] if item["device"] + "/" + item["shard"] != skip_interval]}}
        self.assertTrue(ui_tier_complete(ui_record(good, "success")))
        genuine = copy.deepcopy(summaries)
        genuine[-1]["population"]["observed"] = [observation(genuine[-1]["population"]["declared"][0], "failed", 2)]
        genuine_result = judge_ui(plan, genuine, policy=policy, registry={"schema_version": 1, "entries": []},
                                  evaluated_on=date(2026, 10, 1), matrix_job_result="failure")
        self.assertEqual("failed", genuine_result["status"])
        self.assertTrue(ui_tier_complete(ui_record(genuine_result, "failure")))
        for change in ("missing-shard", "missing-sample", "step-timeout", "foreign-attempt", "duplicate-shard", "failed-job"):
            records = copy.deepcopy(summaries)
            job_result = "success"
            if change == "missing-shard":
                records.pop()
            elif change == "step-timeout":
                records[-1]["status"] = "unverified"
                records[-1]["population"]["observed"] = []
                job_result = "failure"
            elif change == "missing-sample":
                records[-1]["population"]["observed"] = []
            elif change == "foreign-attempt":
                records[-1]["run"]["attempt"] = 2
            elif change == "duplicate-shard":
                records.append(records[-1])
            else:
                job_result = "failure"
            with self.subTest(change=change):
                result = judge_ui(plan, records, policy=policy, registry={"schema_version": 1, "entries": []},
                                  evaluated_on=date(2026, 10, 1), matrix_job_result=job_result)
                self.assertEqual("failed", result["status"])
                self.assertTrue(result["errors"])
                self.assertEqual(9, len(result["shards"]))
                self.assertFalse(ui_tier_complete(ui_record(result, job_result)))
                self.assertFalse(ui_tier_complete(ui_record(result, job_result, skip_interval="appletv/visual")))
        for version in (True, "1", 2):
            with self.subTest(version=version), self.assertRaises(ContractError):
                parse_ui_plan(dict(plan, schema_version=version))
        incomplete = copy.deepcopy(plan)
        incomplete["shards"] = incomplete["shards"][:-1]
        with self.assertRaises(ContractError):
            parse_ui_plan(incomplete)

    def test_nightly_ui_successor_is_bound_to_artifacts_and_diagnostics_cannot_write(self):
        import hashlib
        from ci_nightly import aggregate_nightly
        from ci_nightly_ui import judge_ui
        from ci_publish import json_member
        from strict_e2e_server import fixture_manifest
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
               "head_sha": "a" * 40, "path": ci_report.NIGHTLY_PATH, "event": "schedule", "head_branch": "main",
               "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "failure"}
        identity = {"schema_version": 1, "repository": api.repository, "event": "schedule", "ref": "refs/heads/main",
                    "commit_sha": run["head_sha"], "tree_sha": "b" * 40}
        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        registry = {"schema_version": 1, "entries": []}
        blobs = {"scripts/ci-test-policy.json": json.dumps(policy).encode(), "scripts/ci-known-flaky.json": json.dumps(registry).encode()}
        blobs["scripts/strict_e2e_server.py"] = Path(__file__).with_name("strict_e2e_server.py").read_bytes()
        blobs.update({"scripts/ci-ui-shards.json": json.dumps({"schema_version": 1, "revision": "example-v1",
            "default_shard": "default", "shards": {"default": [], "navigation": ["NavigationUITests"], "visual": ["VisualUITests"]}}).encode(),
            "immichSlides-iOS.xctestplan": json.dumps({"testTargets": [{"target": {"name": "immichSlidesUITests"}}]}).encode(),
            "immichSlides-tvOS.xctestplan": json.dumps({"testTargets": [{"target": {"name": "immichSlidesUITests"}}]}).encode(),
            "immichSlidesUITests/Example.swift": b"\n".join(
                ("final class " + shard.capitalize() + "UITests: XCTestCase { func test" + shard.capitalize() + "() {} }").encode()
                for shard in ("default", "navigation", "visual"))})
        hashes = {"manifests": {"ui-shards": hashlib.sha256(blobs["scripts/ci-ui-shards.json"]).hexdigest(),
                  "test-plan": hashlib.sha256(blobs["immichSlides-iOS.xctestplan"]).hexdigest(),
                  "fixture-c": fixture_manifest("c")["fixture_sha256"]}, "policies": {
            name: hashlib.sha256(blobs[path]).hexdigest() for name, path in (
                ("test-policy", "scripts/ci-test-policy.json"), ("known-flaky", "scripts/ci-known-flaky.json"))}}
        source = {"repository": api.repository, "workflow_path": ci_report.NIGHTLY_PATH, "event": "schedule",
                  "fork_originated": False, "ci_changing": None}
        plan = {"schema_version": 1, "identity": identity, "source": source, "run": {"id": "10", "attempt": 1},
                "hashes": {device: hashes for device in ("iphone", "ipad", "appletv")},
                "shards": [], "max_parallel": 2, "started_epoch": 1}
        members, summaries, intervals = {}, [], []
        for device, platform in (("iphone", "ios"), ("ipad", "ios"), ("appletv", "tvos")):
            for shard in ("default", "navigation", "visual"):
                test = test_identity("ui", shard.capitalize() + "UITests/test" + shard.capitalize(), device=device, platform=platform)
                plan["shards"].append({"device": device, "shard": shard, "declared": [test]})
                summary = valid_summary()
                summary.update(identity=identity, source=source, hashes=hashes,
                               run={**plan["run"], "tier": "ui", "job": "ui-" + device, "shard": shard})
                outcome = "failed" if device == "appletv" and shard == "visual" else "passed"
                summary["population"].update(declared=[test], compiled=[test], observed=[observation(
                    test, outcome, 2, message="private-runner-failure-text" if outcome == "failed" else None,
                    reason="private-runner-reason" if outcome == "failed" else None)])
                summaries.append(summary)
                members[(f"ui-{device}-{shard}-10-1", "summary.json")] = summary
                intervals.append({"shard": device + "/" + shard, "started_epoch": len(intervals) + 1, "finished_epoch": len(intervals) + 2})
        ui = {"schema_version": 1, "plan": plan, "matrix_job_result": "failure",
              "verdict": judge_ui(plan, summaries, policy=policy, registry=registry, evaluated_on=date(2026, 10, 1), matrix_job_result="failure"),
              "capacity": {"max_parallel": 2, "shards": 9, "minimum_shard_waves": 5, "shard_intervals": intervals,
                           "start_order_waves": [[item["shard"] for item in intervals[index:index + 2]] for index in range(0, 9, 2)], "wall_seconds": 10}}
        raw = aggregate_nightly([], [], live_in_scope=False)
        raw.update(schema_version=2, identity=identity, source={**source, "approval_based": False}, hashes=hashes, run=plan["run"], ui=ui,
                   capacity={"shard_intervals": []})
        raw["matrix"]["equal"] = True
        raw["errors"] = []
        raw["tiers"]["ui"] = "failed"
        members[("nightly-aggregate-10-1", "nightly.json")] = raw
        members[("nightly-ui-aggregate-10-1", "nightly-ui.json")] = ui
        artifacts = [{"name": name, "expired": False} for name in sorted({name for name, _ in members})]
        def git_output(command, **kwargs):
            if command[1] == "ls-tree":
                return b"100644 blob " + b"d" * 40 + b"\timmichSlidesUITests/Example.swift\0"
            if command[1] == "rev-parse":
                return b"b" * 40 + b"\n"
            return blobs[command[-1].split(":", 1)[1]]
        with patch("ci_publish.json_member", side_effect=lambda api, artifact, member: members[(artifact["name"], member)]), \
                patch("subprocess.check_output", side_effect=git_output), patch("ci_report.on_main", return_value=True):
            from test_ci_summary import bounded_diagnostics_receipt
            ui_without_receipt = ci_report.nightly_ui_attempt(api, run, 1, artifacts, raw)
            for summary in summaries:
                summary["bounded_diagnostics"] = bounded_diagnostics_receipt()
            self.assertEqual(ci_report.nightly_ui_attempt(api, run, 1, artifacts, raw), ui_without_receipt)
            report = ci_report.nightly_attempt(api, run, 1, artifacts)
            self.assertEqual(9, report["diagnostics"]["counts"]["ui_executed"])
            failed = [item for item in report["observed"] if item["outcome"] == "failed"]
            self.assertEqual("appletv", failed[0]["identity"]["dimensions"]["device"])
            self.assertEqual("open", issue_decision(None, failed[0]["identity"], [report], registry_referenced=False)["action"])
            self.assertEqual(9, report["diagnostics"]["counts"]["declared"])
            retained_verdict, retained_capacity = ui["verdict"], ui["capacity"]
            ui["verdict"] = judge_ui(plan, summaries[1:], policy=policy, registry=registry,
                evaluated_on=date(2026, 10, 1), matrix_job_result="failure")
            ui["capacity"] = {**retained_capacity, "shard_intervals": intervals[1:],
                              "start_order_waves": [[item["shard"] for item in intervals[1:][index:index + 2]]
                                                    for index in range(0, len(intervals) - 1, 2)]}
            lost_artifacts = [item for item in artifacts if item["name"] != "ui-iphone-default-10-1"]
            lost_job = {"id": 99, "run_id": 10, "run_attempt": 1, "name": "ui-iphone-default",
                "status": "completed", "conclusion": "failure",
                "check_run_url": "https://api.github.com/repos/sudoHG/immichSlides/check-runs/99"}
            with patch.object(api, "repo", return_value={"total_count": 1, "jobs": [lost_job]}, create=True), \
                    patch.object(api, "annotations", return_value=[{"annotation_level": "failure",
                        "message": "The hosted runner lost communication with the server. private-detail"}], create=True):
                disconnected = ci_report.nightly_attempt(api, run, 1, lost_artifacts)
            self.assertEqual([{"identity": plan["shards"][0]["declared"][0], "reason": "hosted-runner-disconnected"}],
                             disconnected["diagnostics"]["missing"])
            self.assertIn(failed[0], disconnected["observed"])
            self.assertNotIn("private-detail", json.dumps(disconnected))
            api.pages = lambda path, collection: lost_artifacts
            missing_report = read_run(api, run, {})
            import io
            import zipfile
            receipt_name = "nightly-ui-identity-iphone-default-10-1"
            import ci_ui_tests as ui_producer
            for failure in (subprocess.CalledProcessError(128, ["git", "rev-parse", "HEAD^{tree}"],
                                output="private identity output", stderr="private identity error"),
                            subprocess.TimeoutExpired(["git", "rev-parse", "HEAD^{tree}"], 30,
                                output="private identity output", stderr="private identity error")):
                with tempfile.TemporaryDirectory() as directory:
                    temporary = Path(directory)
                    checkout = temporary / "source"
                    for name, content in blobs.items():
                        path = checkout / name
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(content)
                    def identity_output(command, **options):
                        self.assertEqual(30, options["timeout"])
                        if command == ["git", "rev-parse", "HEAD"]:
                            return "a" * 40
                        self.assertEqual(["git", "rev-parse", "HEAD^{tree}"], command)
                        raise failure
                    environment = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "schedule", "GITHUB_REPOSITORY": api.repository,
                        "GITHUB_SHA": run["head_sha"], "GITHUB_REF": "refs/heads/main", "GITHUB_RUN_ID": "10", "GITHUB_RUN_ATTEMPT": "1",
                        "RUNNER_TEMP": str(temporary)}
                    with patch.dict(os.environ, environment, clear=True), patch.object(ui_producer, "ROOT", checkout), \
                            patch("run_host_checks.subprocess.check_output", side_effect=identity_output) as git_process:
                        self.assertEqual(1, ui_producer.main(["stage-download", "--device", "iphone", "--shard", "default"]))
                    self.assertEqual(2, git_process.call_count)
                    self.assertEqual(["ui-identity/identity-failure.json"],
                        [path.relative_to(temporary).as_posix() for path in temporary.rglob("*") if path.is_file() and checkout not in path.parents])
                    receipt = json.loads((temporary / "ui-identity/identity-failure.json").read_text())
                    from ci_nightly import parse_identity_failure
                    self.assertEqual(receipt, parse_identity_failure(receipt, plan["run"], "default", plan["shards"][0]["declared"], job="ui-iphone"))
            for defect in ("valid", "run", "attempt", "attempt-bool", "job", "shard", "version", "phase", "reason",
                           "declared", "extra", "duplicate", "expired", "previous-attempt", "foreign-device", "foreign-shard",
                           "corrupt", "invalid-json", "unavailable", "summary-present", "records-present"):
                with self.subTest(ui_identity_receipt=defect):
                    saved_capacity, saved_verdict, saved_pages = ui["capacity"], ui["verdict"], api.pages
                    saved_summary = members[("ui-iphone-default-10-1", "summary.json")]
                    try:
                        supplied = copy.deepcopy(receipt)
                        receipt_artifact = {"name": receipt_name, "id": 99, "size_in_bytes": 1024, "expired": False}
                        candidate_artifacts = [*lost_artifacts, receipt_artifact]
                        if defect in {"run", "attempt", "attempt-bool"}:
                            supplied["run"]["id" if defect == "run" else "attempt"] = (
                                "11" if defect == "run" else True if defect == "attempt-bool" else 2)
                        for field, value in (("job", "ui-ipad"), ("shard", "navigation"), ("version", True),
                                             ("phase", "archive-download"), ("reason", "private-reason"),
                                             ("declared", []), ("extra", "private-path")):
                            if defect == field:
                                supplied["schema_version" if field == "version" else "path" if field == "extra" else field] = value
                        if defect == "duplicate":
                            candidate_artifacts.append(dict(receipt_artifact))
                        if defect == "expired":
                            receipt_artifact["expired"] = True
                        if defect == "previous-attempt":
                            receipt_artifact["name"] = receipt_name[:-1] + "2"
                        if defect == "foreign-device":
                            receipt_artifact["name"] = receipt_name.replace("iphone", "ipad")
                        if defect == "foreign-shard":
                            receipt_artifact["name"] = receipt_name.replace("default", "navigation")
                        if defect == "summary-present":
                            ui["capacity"] = retained_capacity
                        if defect == "records-present":
                            recorded = copy.deepcopy(summaries[0])
                            recorded["population"]["observed"] = []
                            members[("ui-iphone-default-10-1", "summary.json")] = recorded
                            candidate_artifacts.append({"name": "ui-iphone-default-10-1", "expired": False})
                            ui["verdict"] = judge_ui(plan, [recorded, *summaries[1:]], policy=policy, registry=registry,
                                evaluated_on=date(2026, 10, 1), matrix_job_result="failure")
                        packed = io.BytesIO()
                        with zipfile.ZipFile(packed, "w") as zipped:
                            zipped.writestr("identity-failure.json", "{" if defect == "invalid-json" else json.dumps(supplied))
                        def read_member(client, artifact, member):
                            if member == "identity-failure.json":
                                return json_member(client, artifact, member)
                            return members[(artifact["name"], member)]
                        def read_api(path, **options):
                            if path.endswith("/zip"):
                                if defect == "unavailable":
                                    raise OSError("private-download-error")
                                return b"not a ZIP" if defect == "corrupt" else packed.getvalue()
                            return {"total_count": 1, "jobs": [lost_job]} if defect == "summary-present" else {"total_count": 0, "jobs": []}
                        api.pages = lambda path, collection: candidate_artifacts
                        with patch("ci_publish.json_member", side_effect=read_member), \
                                patch.object(api, "repo", side_effect=read_api, create=True), \
                                patch.object(api, "annotations", return_value=[{"annotation_level": "failure",
                                    "message": "The hosted runner lost communication with the server. private-detail"}], create=True) as annotations:
                            explained = read_run(api, run, {})
                        if defect == "summary-present":
                            annotations.assert_not_called()
                        expected_reason = "identity-collection-failed" if defect == "valid" else "nightly-ui-sample-missing"
                        self.assertEqual([{"identity": receipt["declared"][0], "reason": expected_reason}],
                                         explained["diagnostics"]["missing"])
                        self.assertEqual(missing_report["observed"], explained["observed"])
                        self.assertEqual(missing_report["diagnostics"]["counts"], explained["diagnostics"]["counts"])
                        self.assertNotIn("private-path", json.dumps(explained))
                        self.assertNotIn("private-reason", json.dumps(explained))
                        self.assertNotIn("private-download-error", json.dumps(explained))
                    finally:
                        ui["capacity"], ui["verdict"], api.pages = saved_capacity, saved_verdict, saved_pages
                        members[("ui-iphone-default-10-1", "summary.json")] = saved_summary
            ui["verdict"], ui["capacity"] = retained_verdict, retained_capacity
            api.pages = lambda path, collection: artifacts
            history = ci_report.read_run(api, run, {})
            self.assertNotIn("private-runner-failure-text", json.dumps(ci_report.compact_entry(history, set())["attempt_history"]))
            self.assertNotIn("private-runner-reason", json.dumps(ci_report.compact_entry(history, set())["attempt_history"]))
            outer_source = raw["source"]
            for field, value in (("repository", "foreign/repository"), ("workflow_path", ci_report.REPORT_PATH),
                                 ("event", "workflow_dispatch"), ("fork_originated", True), ("ci_changing", True),
                                 ("approval_based", True), ("approval_based", 0), ("unknown", "untrusted")):
                raw["source"] = {**outer_source, field: value}
                with self.subTest(outer_source=field, value=value), self.assertRaises(ContractError):
                    ci_report.nightly_attempt(api, run, 1, artifacts)
            raw["source"] = {key: value for key, value in outer_source.items() if key != "approval_based"}
            with self.subTest(outer_source="missing approval_based"), self.assertRaises(ContractError):
                ci_report.nightly_attempt(api, run, 1, artifacts)
            raw["source"] = outer_source
            fixture_source = blobs["scripts/strict_e2e_server.py"]
            blobs["scripts/strict_e2e_server.py"] += b"\n# different tested fixture source\n"
            with self.assertRaisesRegex(ContractError, "fixture-source-drift"):
                ci_report.nightly_attempt(api, run, 1, artifacts)
            drift = ci_report.read_run(api, run, {})
            self.assertEqual("failed", drift["status"])
            self.assertIn("fixture-source-drift", drift["diagnostics"]["infrastructure"])
            self.assertNotIn("different tested fixture source", json.dumps(drift))
            blobs["scripts/strict_e2e_server.py"] = fixture_source
            for change in ("unverified shard plus a real failure in another shard", "missing sample", "missing compilation"):
                changed = copy.deepcopy(summaries)
                if change.startswith("unverified"):
                    changed[0]["status"] = "unverified"
                elif change == "missing sample":
                    changed[0]["population"]["observed"] = []
                else:
                    changed[0]["population"]["compiled"] = []
                ui["verdict"] = judge_ui(plan, changed, policy=policy, registry=registry,
                    evaluated_on=date(2026, 10, 1), matrix_job_result="failure")
                for index, item in enumerate(plan["shards"]):
                    members[(f"ui-{item['device']}-{item['shard']}-10-1", "summary.json")] = changed[index]
                with self.subTest(change=change):
                    incomplete = ci_report.nightly_attempt(api, run, 1, artifacts)
                    self.assertTrue(any("nightly UI" in error for error in incomplete["diagnostics"]["infrastructure"]))
                    self.assertEqual(9, incomplete["diagnostics"]["counts"]["declared"])
                    if change == "missing sample":
                        with patch.object(api, "repo", return_value={"total_count": 1, "jobs": [lost_job]}, create=True), \
                                patch.object(api, "annotations", return_value=[{"annotation_level": "failure",
                                    "message": "The hosted runner lost communication with the server. private-detail"}], create=True) as annotation_reader:
                            retained = ci_report.nightly_attempt(api, run, 1, artifacts)
                        self.assertEqual([{"identity": plan["shards"][0]["declared"][0], "reason": "nightly-ui-sample-missing"}],
                                         retained["diagnostics"]["missing"])
                        self.assertEqual(incomplete["diagnostics"], retained["diagnostics"])
                        self.assertNotIn("private-detail", json.dumps(retained))
                        annotation_reader.assert_not_called()
                    tracked = plan["shards"][1]["declared"][0]
                    opened = issue_decision(None, tracked, [entry(outcome="failed") | {
                        "observed": [observation(tracked, "failed", 1)]}], registry_referenced=False)["state"]
                    incomplete["day"] = "2026-10-02"
                    self.assertEqual([], issue_decision(opened, tracked, [incomplete], registry_referenced=False)["state"]["explicit_pass_nights"])
            for reason in ("archive-hash-mismatch",):
                changed = copy.deepcopy(summaries)
                failed = changed[4]
                failed["status"] = "failed"
                failed["population"].update(compiled=[], observed=[observation(
                    failed["population"]["declared"][0], "not-run", 0, reason=reason)])
                failed["infrastructure"] = [{"code": reason, "message": "private-download-error-text"}]
                receipt = archive_download_summary()["archive_download"]
                receipt.update(failure_reason=reason, digests_matched={"manifest": True, "tar": False})
                failed["archive_download"] = receipt
                ui["verdict"] = judge_ui(plan, changed, policy=policy, registry=registry,
                    evaluated_on=date(2026, 10, 1), matrix_job_result="failure")
                for index, item in enumerate(plan["shards"]):
                    members[(f"ui-{item['device']}-{item['shard']}-10-1", "summary.json")] = changed[index]
                with self.subTest(archive_reason=reason):
                    report = ci_report.nightly_attempt(api, run, 1, artifacts)
                    self.assertIn(reason, report["diagnostics"]["infrastructure"])
                    self.assertNotIn("private-download-error-text", json.dumps(report))
                    state = issue_decision(None, NIGHTLY_INFRASTRUCTURE, [report], registry_referenced=False)["state"]
                    self.assertEqual([reason], state["nights"][report["day"]]["10"]["archive_failure_reasons"])
                    body = ci_report.issue_body(None, state, api.repository)
                    self.assertIn("| Archive gate reason |", body)
                    self.assertIn("| failed | " + reason + " |", body)
                    edited = copy.deepcopy(state)
                    edited["nights"][report["day"]]["10"]["archive_failure_reasons"] = ["hand-edited-download-error"]
                    self.assertIn("| failed | — |", ci_report.issue_body(None, edited, api.repository))
                    later = copy.deepcopy(report)
                    later["run"]["attempt"] = 2
                    later["status"] = "passed"
                    later["diagnostics"]["infrastructure"] = []
                    later_state = issue_decision(state, NIGHTLY_INFRASTRUCTURE, [later], registry_referenced=False)["state"]
                    self.assertIn("| failed | " + reason + " |", ci_report.issue_body(None, later_state, api.repository))
            for index, item in enumerate(plan["shards"]):
                members[(f"ui-{item['device']}-{item['shard']}-10-1", "summary.json")] = summaries[index]
            skipped = summaries[0]["population"]["declared"][0]
            policy["approval_records"] = [{"tier": "ui", "approver": "example maintainer", "date": "2026-10-01",
                                            "link": "https://github.com/sudoHG/immichSlides/issues/123#issuecomment-123"}]
            policy["expected_skips"] = [{"kind": "ui", "key_pattern": skipped["key"], "dimensions": skipped["dimensions"],
                                         "tier": "ui", "environment": "fixture", "reason": "approved device skip"}]
            blobs["scripts/ci-test-policy.json"] = json.dumps(policy).encode()
            hashes["policies"]["test-policy"] = hashlib.sha256(blobs["scripts/ci-test-policy.json"]).hexdigest()
            summaries[0]["population"]["observed"] = [observation(skipped, "skipped", 1, reason="approved device skip")]
            ui["verdict"] = judge_ui(plan, summaries, policy=policy, registry=registry,
                evaluated_on=date(2026, 10, 1), matrix_job_result="failure")
            skipped_report = ci_report.nightly_attempt(api, run, 1, artifacts)
            self.assertEqual(0, skipped_report["health"]["unexpected_skips"])
            for path in ("immichSlidesUITests/Example.swift", "scripts/ci-ui-shards.json",
                         "immichSlides-iOS.xctestplan", "immichSlides-tvOS.xctestplan"):
                original = blobs[path]
                blobs[path] = (original.replace(b"testDefault", b"testInvented") if path.endswith(".swift")
                               else original + b" ")
                with self.subTest(path=path), self.assertRaises(ContractError):
                    ci_report.nightly_attempt(api, run, 1, artifacts)
                blobs[path] = original
            for field, value in (("fork_originated", True), ("ci_changing", True)):
                plan["source"][field] = value
                with self.subTest(field=field), self.assertRaises(ContractError):
                    ci_report.nightly_attempt(api, run, 1, artifacts)
                plan["source"][field] = False if field == "fork_originated" else None
            for error in (subprocess.CalledProcessError(128, ["git", "show"]),
                          subprocess.TimeoutExpired(["git", "show"], 30), OSError("source unavailable")):
                def unavailable_source(command, **kwargs):
                    if command[1] == "show":
                        raise error
                    return git_output(command, **kwargs)
                with self.subTest(error=type(error).__name__), patch("subprocess.check_output", side_effect=unavailable_source):
                    unavailable = ci_report.read_run(api, run, {})
                    self.assertEqual("failed", unavailable["status"])
                    self.assertIn("nightly attempt evidence unavailable", unavailable["diagnostics"]["infrastructure"])
            for version in (True, "2", 3):
                with self.subTest(version=version), self.assertRaises(ContractError):
                    raw["schema_version"] = version
                    ci_report.nightly_attempt(api, run, 1, artifacts)
            raw["schema_version"] = 2
            with self.assertRaises(ContractError):
                ci_report.nightly_attempt(api, run, 1, artifacts[:-1])
        branch = dict(run, event="workflow_dispatch", head_branch="nightly-candidate")
        branch_identity = dict(identity, event="workflow_dispatch", ref="refs/heads/nightly-candidate")
        self.assertFalse(ci_report.nightly_ref_allowed(api, branch, branch_identity))
        api.diagnostic_nightly = True
        self.assertFalse(ci_report.nightly_ref_allowed(api, branch, branch_identity))
        api.dry_run = True
        self.assertTrue(ci_report.nightly_ref_allowed(api, branch, branch_identity))
        api.request_count = 0
        branch["repository"] = {"full_name": api.repository}
        api.repo = lambda path: {"id": 123, "path": ci_report.NIGHTLY_PATH} if path.startswith("actions/workflows/") else branch
        with tempfile.TemporaryDirectory() as directory, patch("ci_report.read_run", return_value=report):
            output = Path(directory, "diagnostic")
            self.assertEqual(0, ci_report.diagnose_nightly(api, [10], output))
            self.assertEqual([report], json.loads((output / "runs.json").read_text()))
            branch["workflow_id"] = 124
            with self.assertRaises(ContractError):
                ci_report.diagnose_nightly(api, [10], Path(directory, "foreign"))
            with self.assertRaisesRegex(ContractError, "outside checkout"):
                ci_report.diagnose_nightly(api, [10], Path(ci_report.__file__).resolve().parent.parent / "reader-diagnostic")
        for arguments in (["--diagnostic-nightly"], ["--dry-run", "--diagnostic-nightly"],
                          ["--dry-run", "--diagnostic-nightly", "--run-id", "10", "--phase", "sync"]):
            with self.subTest(arguments=arguments), self.assertRaises(ContractError):
                ci_report.main(arguments)

    def test_cloud_pr_diagnostics_require_trusted_proof_and_keep_compiled_inventory_unknown(self):
        identity = test_identity("ui", "ExampleTests/testExample", platform="tvos", device="appletv")
        proof = {"identities": [identity], "cloud_run_id": "verified-run"}
        with patch("ci_xcode_cloud.trusted_cloud", side_effect=AssertionError("second API read")) as reader:
            diagnostics = ci_report.cloud_pr_diagnostics([], cloud=proof)
        reader.assert_not_called()
        self.assertEqual(diagnostics["counts"], {"declared": 1, "observed": 1, "passed": 1,
                                               "compiled_not_exposed_by_api": 1})
        self.assertNotIn("compiled", diagnostics["counts"])
        with self.assertRaises(ContractError):
            ci_report.cloud_pr_diagnostics([], cloud=None)

    def test_archive_unavailable_ui_cannot_notify_for_a_superseded_unexecuted_gate(self):
        from ci_health import health_report
        from test_ci_publish import UnavailableUIAPI
        api = UnavailableUIAPI()
        with patch("ci_report.on_main", return_value=True):
            report = read_run(api, api.ui, {201: api.record})
        self.assertEqual("not-run", report["status"])
        self.assertEqual([], report["observed"])
        self.assertEqual([], report["diagnostics"]["failures"])
        self.assertEqual({"schema_version": 1, "first_attempt_failures": None}, report["first_execution_health"])
        self.assertIn("Not evaluated", render_entry(ci_report.compact_entry(report, set())))
        snapshot = ci_report.merge_snapshot(None, [ci_report.compact_entry(report, set())], date(2026, 10, 9))
        snapshot["producer"] = {"repository": api.repository}
        health = health_report(snapshot, {"entries": []}, "2026-10", date(2026, 10, 9))
        self.assertEqual({"not-run": 1}, health["coverage"]["statuses"])
        self.assertEqual(1, health["coverage"]["incomplete_evidence_runs"])
        with patch("ci_report.ensure_label") as writes:
            self.assertEqual(([], {}), synchronize_issues(api, [report], {"entries": []}))
        writes.assert_not_called()
        api.refusals = [{"outcome": "archive-identity-mismatch"}]
        with patch("ci_report.on_main", return_value=True):
            rejected = read_run(api, api.ui, {201: api.record})
        self.assertEqual("failed", rejected["status"])
        self.assertTrue(ci_report.issue_eligible(rejected))

    def test_replaced_pending_main_ui_run_is_not_run_and_never_notifies(self):
        from test_ci_publish import RUN, UnstartedGateAPI
        ui_path = ".github/workflows/ci-ui.yml"
        run = dict(RUN, id=201, workflow_id=43, path=ui_path, event="push", head_branch="main",
                   conclusion="cancelled", created_at="2026-10-09T02:57:13Z")
        api = UnstartedGateAPI()
        api.workflow = {"id": 43, "path": ui_path, "state": "active"}
        api.newer = [dict(run, id=202, head_sha="e" * 40, status="in_progress", conclusion=None)]
        api.jobs, api.total_count = [], 0
        with patch("ci_report.on_main", return_value=True):
            report = read_run(api, run, {})
        self.assertEqual("not-run", report["status"])
        self.assertIn("UI run cancelled before any job executed", report["not_evaluated_reason"])
        self.assertFalse(ci_report.issue_eligible(report))
        with patch("ci_report.ensure_label", side_effect=AssertionError("replaced run cannot notify")):
            self.assertEqual(([], {}), synchronize_issues(api, [report], {"entries": []},
                                                        post_merge_since="2026-10-09T00:00:00Z"))

    def test_unstarted_main_gate_is_not_run_and_all_cancellations_remain_ineligible(self):
        from test_ci_publish import RUN, UNSTARTED_GATE_JOBS, UnstartedGateAPI
        run = dict(RUN, event="push", head_branch="main", conclusion="cancelled",
                   created_at="2026-10-09T02:57:13Z")
        api = UnstartedGateAPI()
        with patch("ci_report.on_main", return_value=True):
            report = read_run(api, run, {})
        self.assertEqual("not-run", report["status"])
        self.assertEqual(run["head_sha"], report["pushed_sha"])
        self.assertEqual([], report["observed"])
        self.assertEqual([], report["diagnostics"]["infrastructure"])
        self.assertIn("Not evaluated", render_entry(report))
        compact = ci_report.compact_entry(report, set())
        self.assertEqual(report["not_evaluated_reason"], compact["not_evaluated_reason"])
        self.assertEqual({"schema_version": 1, "first_attempt_failures": None}, compact["first_execution_health"])
        self.assertEqual("cancelled", compact["conclusion"])
        self.assertEqual(run["created_at"], compact["created_at"])
        self.assertEqual(run["head_sha"], compact["head_sha"])
        self.assertIn("Not evaluated", render_entry(compact))
        saved = ci_report.merge_snapshot(None, [compact], date(2026, 10, 9))
        self.assertEqual("not-run", saved["days"]["2026-10-09"]["entries"][0]["status"])
        with patch("ci_report.ensure_label") as writes:
            self.assertEqual(([], {}), synchronize_issues(api, [report], {"entries": []}))
        writes.assert_not_called()
        for mutation in ({"runner_id": 123}, {"steps": [{"status": "completed"}]},
                         {"conclusion": "failure"}):
            api.jobs = [dict(UNSTARTED_GATE_JOBS[0], **mutation)]
            api.total_count = 1
            with patch("ci_report.on_main", return_value=True):
                started = read_run(api, run, {})
            self.assertEqual("unverified", started["status"])
            self.assertEqual([], started["observed"])
            self.assertEqual([], started["diagnostics"]["infrastructure"])
            self.assertFalse(ci_report.issue_eligible(started))
            with patch("ci_report.ensure_label", side_effect=AssertionError("cancelled push cannot notify")):
                self.assertEqual(([], {}), synchronize_issues(api, [started], {"entries": []},
                                                            post_merge_since="2026-10-09T00:00:00Z"))
        api.jobs = UNSTARTED_GATE_JOBS
        api.total_count = len(api.jobs)
        api.newer = []
        with patch("ci_report.on_main", return_value=True):
            self.assertEqual("unverified", read_run(api, run, {})["status"])
        api.newer = UnstartedGateAPI().newer
        with patch("ci_report.on_main", return_value=False):
            self.assertEqual("unverified", read_run(api, run, {})["status"])

    def transition(self, state, report, referenced=False):
        return issue_decision(state, IDENTITY, [report], registry_referenced=referenced)

    def test_snapshot_uses_upload_time_and_survives_an_interrupted_new_attempt(self):
        runs = {number: {"id": number, "workflow_id": 20, "path": ci_report.REPORT_PATH,
            "head_branch": "main", "repository": {"full_name": "sudoHG/immichSlides"},
            "head_repository": {"full_name": "sudoHG/immichSlides"}, "event": "schedule",
            "head_sha": "a" * 40, "run_attempt": 1} for number in (10, 20)}
        artifacts = [{"name": f"ci-report-daily-{number}-1", "expired": False,
            "created_at": created, "workflow_run": {"id": number, "head_branch": "main"}}
            for number, created in ((20, "2026-10-01T10:00:00Z"), (10, "2026-10-01T11:00:00Z"))]
        snapshots = {}
        for number in runs:
            saved = ci_report.merge_snapshot(None, [entry(run=number)], date(2026, 10, 1))
            saved["producer"] = {"repository": "sudoHG/immichSlides", "workflow_path": ci_report.REPORT_PATH,
                "run": {"id": str(number), "attempt": 1}, "commit_sha": "a" * 40}
            snapshots[f"ci-report-daily-{number}-1"] = saved
        class API:
            repository = "sudoHG/immichSlides"
            def repo(self, path, **options):
                if path == "actions/workflows/ci-report.yml":
                    return {"id": 20, "path": ci_report.REPORT_PATH}
                if path.startswith("actions/runs/"):
                    return runs[int(path.rsplit("/", 1)[-1])]
                return {"workflow_runs": [runs[20], runs[10]]}
            def pages(self, path, *args, **options):
                return artifacts if path == "actions/artifacts" else [item for item in artifacts
                    if item["workflow_run"]["id"] == int(path.split("/")[2])]
        for attempt in (1, 2):
            runs[10]["run_attempt"] = attempt
            with self.subTest(attempt=attempt), patch("ci_report.on_main", return_value=True), \
                    patch("ci_publish.json_member", side_effect=lambda api, artifact, member: snapshots[artifact["name"]]):
                self.assertEqual(snapshots["ci-report-daily-10-1"], ci_report.read_snapshot(API()))

    def test_closed_issue_history_does_not_expand_reads_and_collect_inventory_is_reused(self):
        from urllib.parse import parse_qs, urlparse
        state = self.transition(None, entry())["state"]
        state["closed"] = True
        target = {"number": 135, "state": "closed", "labels": [{"name": ci_report.LABEL}],
                  "body": ci_report.issue_body(None, state, "sudoHG/immichSlides")}
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.reads, self.searches, self.listings = [], [], []
            def pages(self, path, **filters):
                self.listings.append(filters)
                return [] if filters.get("state") == "open" else [target] * 1000
            def request(self, path, **options):
                query = parse_qs(urlparse(path).query)["q"][0]
                self.searches.append(query)
                return {"total_count": 1, "incomplete_results": False, "items": [target]}
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {}
                if path != "issues/135":
                    raise AssertionError("only the touched closed issue may be read or updated")
                if method == "GET":
                    self.reads.append(path)
                else:
                    target.update(payload)
                return target
        api = API()
        inventory = ci_report.visible_issues(api, ci_report.LABEL)
        self.assertEqual([], inventory)
        receipts, _ = synchronize_issues(api, [entry("2026-10-02", run=11)], {"entries": []}, inventory=inventory)
        self.assertEqual(["reopen"], [item["action"] for item in receipts])
        self.assertEqual(1, len(api.listings))
        self.assertEqual(["issues/135"], api.reads)
        self.assertEqual(1, len(api.searches))
        self.assertIn('label:"ci-reported-failure"', api.searches[0])
        self.assertIn('in:title "CI nightly failure: ExampleUITests/testPlayback"', api.searches[0])
        # Adopted registry issues retain their maintainer title after registry removal.
        target["state"] = "closed"
        target["title"] = "Existing maintainer diagnosis"
        api = API()
        target["body"] = ci_report.issue_body(None, state, api.repository)
        receipts, _ = synchronize_issues(api, [entry("2026-10-02", run=11)], {"entries": []}, inventory=[],
                                         issue_index={identity_token(IDENTITY): 135})
        self.assertEqual(["reopen"], [item["action"] for item in receipts])
        self.assertEqual([], api.searches)
        self.assertEqual(2, len(api.reads))

    def test_timeouts_and_missing_exports_are_infrastructure_not_contract_failures(self):
        method = test_identity("strict", "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke", **IDENTITY["dimensions"])
        case = test_identity("strict", "smoke", **IDENTITY["dimensions"])
        shard = valid_summary()
        shard["population"].update(declared=[case], compiled=[case], observed=[observation(case, "failed", 1, exit_code=124)])
        base = {"identity": case, "exit_code": 124, "build_operations": 0, "products_unchanged": True,
                "log_present": True, "official_methods": [{"identifier": method["key"], "result": "Passed"}],
                "official_summary": {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}}
        for changes in ({"automated_contract_failed": True, "infrastructure": [{"code": "step-timeout", "message": "timeout"}]},
                        {"automated_contract_failed": True, "exit_code": 65, "official_error": "export failed"},
                        {"automated_contract_failed": True, "exit_code": 65, "official_methods": []}, {"exit_code": 65}):
            with self.subTest(changes=changes):
                observed, missing = ci_report.method_observations(shard, {"warm": [{**base, **changes}]})
                self.assertFalse(any(item["outcome"] == "failed" for item in observed))
                self.assertTrue(missing)
        failed = copy.deepcopy(base)
        failed["official_methods"][0]["result"] = "Failed"
        failed["official_summary"].update(passedTests=0, failedTests=1)
        observed, _ = ci_report.method_observations(shard, {"warm": [failed]})
        self.assertEqual([method], [item["identity"] for item in observed if item["outcome"] == "failed"])
        self.assertEqual(observed[0]["failure_phase"], "unknown")
        failed["official_methods"][0].update(failure_phase="interval_setup", failure_class="interval_readback")
        observed, missing = ci_report.method_observations(shard, {"warm": [failed]})
        self.assertEqual(observed[0]["failure_phase"], "interval_setup")
        self.assertEqual(observed[0]["attempts"][0]["failure_class"], "interval_readback")
        self.assertEqual(observed[0]["attempts"][0]["exit_code"], 124)
        self.assertEqual(missing, [])
        failed["official_methods"][0]["failure_phase"] = "private assertion text"
        with self.assertRaises(ValueError):
            ci_report.method_observations(shard, {"warm": [failed]})

    def test_failures_open_update_and_reopen_one_identity_and_replays_do_not_count(self):
        first = self.transition(None, entry())
        self.assertEqual("open", first["action"])
        replay = self.transition(first["state"], entry())
        self.assertEqual("none", replay["action"])
        second = self.transition(first["state"], entry("2026-10-02", run=11))
        self.assertEqual("update", second["action"])
        self.assertEqual(2, second["state"]["failure_nights"])
        closed = copy.deepcopy(second["state"])
        closed["closed"] = True
        self.assertEqual("reopen", self.transition(closed, entry("2026-10-03", run=12))["action"])

    def test_only_three_distinct_later_explicit_pass_nights_can_close(self):
        state = self.transition(None, entry())["state"]
        for day, run in (("2026-10-02", 11), ("2026-10-02", 12), ("2026-10-03", 13)):
            decision = self.transition(state, entry(day, "passed", run))
            self.assertNotEqual("close", decision["action"])
            state = decision["state"]
        self.assertEqual("close", self.transition(state, entry("2026-10-04", "passed", 14))["action"])

    def test_flaky_skipped_missing_and_infrastructure_nights_cannot_close(self):
        for outcome in ("flaky-passed", "skipped", "not-run", "failed"):
            with self.subTest(outcome=outcome):
                state = self.transition(None, entry())["state"]
                for day, run in (("2026-10-02", 11), ("2026-10-03", 12)):
                    state = self.transition(state, entry(day, "passed", run))["state"]
                report = entry("2026-10-04", "passed", 13)
                report["observed"][0]["outcome"] = outcome
                self.assertNotEqual("close", self.transition(state, report)["action"])
        report = entry("2026-10-04", "passed", 13)
        report["diagnostics"]["infrastructure"] = ["missing-evidence"]
        self.assertNotEqual("close", self.transition(state, report)["action"])

    def test_registry_reference_blocks_closure_even_after_review_date(self):
        state = self.transition(None, entry())["state"]
        for day, run in (("2026-10-02", 11), ("2026-10-03", 12), ("2026-10-04", 13)):
            state = self.transition(state, entry(day, "passed", run), True)["state"]
        self.assertFalse(state["closed"])
        self.assertEqual("close", self.transition(state, entry("2026-10-05", "passed", 14))["action"])

    def test_older_failure_delivery_cannot_erase_later_failure_or_pass_history(self):
        state = self.transition(None, entry("2026-10-04", run=14))["state"]
        state = self.transition(state, entry("2026-10-01", run=10))["state"]
        self.assertEqual("2026-10-04", state["last_failure"])
        self.assertEqual("2026-10-01", state["first_failure"])
        for day, run in (("2026-10-05", 15), ("2026-10-06", 16)):
            state = self.transition(state, entry(day, "passed", run))["state"]
        self.assertEqual("close", self.transition(state, entry("2026-10-07", "passed", 17))["action"])

    def test_ui_devices_share_platform_registry_identity_but_strict_dimensions_remain_distinct(self):
        iphone = test_identity("ui", "ExampleUITests/testPlayback", platform="ios", device="iphone")
        ipad = test_identity("ui", "ExampleUITests/testPlayback", platform="ios", device="ipad")
        self.assertEqual(identity_token(iphone), identity_token(ipad))
        tv = copy.deepcopy(IDENTITY)
        tv["dimensions"]["device"] = "tv"
        self.assertNotEqual(identity_token(IDENTITY), identity_token(tv))

    def test_rollup_is_idempotent_selects_latest_attempt_and_preserves_source(self):
        old, new = entry(), entry(attempt=2, outcome="passed")
        new["source"].update(fork_originated=True, ci_changing=True, approval_based=True)
        report = daily_rollup("2026-10-01", [old, new, new])
        self.assertEqual([new], report["entries"])
        self.assertEqual(90, report["retention_days"])
        with self.assertRaises(ContractError):
            conflicting = copy.deepcopy(new)
            conflicting["status"] = "failed"
            daily_rollup("2026-10-01", [new, conflicting])

    def test_diagnostics_keep_failed_identities_counts_exit_codes_and_missing_evidence(self):
        from ci_publish import GitHub, producer_evidence
        from ci_publish_git import workflow_contract
        from test_ci_publish import gate_fixture, REPOSITORY, RUN
        record, jobs, summaries = gate_fixture(units=False)
        source = record["workflows"][RUN["path"]]["base"]
        _, _, names = workflow_contract(source, RUN, details=True)
        artifacts = [{"name": name, "expired": False} for values in names.values() for name in values]
        invalid_summaries = copy.deepcopy(summaries)
        invalid_summaries[0]["run"]["id"] = "999"
        for publisher in (False, True):
            api = GitHub(REPOSITORY, "", retry_reads=publisher)
            failures, evidence_errors = [], []
            with self.subTest(publisher=publisher), patch.object(api, "pages", side_effect=[jobs, artifacts]), \
                    patch("ci_publish.json_member", side_effect=copy.deepcopy(invalid_summaries)), \
                    patch("builtins.print") as output:
                _, accepted = producer_evidence(api, RUN, source, diagnostics=evidence_errors, failures=failures)
                self.assertEqual(accepted, summaries[1:])
                self.assertEqual(len(evidence_errors), 1)
                self.assertEqual(failures, [{"stage": "artifact-binding", "exception_type": "ContractError", "http_status": None}])
                lines = [call.args[0] for call in output.call_args_list
                         if call.args and call.args[0].startswith("Trusted CI failure: ")]
                self.assertEqual(len(lines), int(publisher))
        summary = valid_summary()
        summary["population"]["observed"][0] = observation(summary["population"]["declared"][0], "failed", 1, exit_code=65)
        summary["status"] = "failed"
        summary["population"]["compiled"] = []
        diagnostics = summary_diagnostics([summary], ["required artifact missing"])
        self.assertEqual(1, diagnostics["counts"]["failed"])
        self.assertEqual([65], diagnostics["failures"][0]["exit_codes"])
        self.assertTrue(diagnostics["missing"])
        self.assertIn("required artifact missing", diagnostics["infrastructure"])
        report = entry()
        report["diagnostics"] = diagnostics
        rendered = render_entry(report)
        self.assertIn("65", rendered)
        self.assertIn("Infrastructure", rendered)

    def test_registry_checks_report_expiration_and_closed_or_missing_issues_without_gating_tests(self):
        registry = {"entries": [{"identity": IDENTITY, "issue": "https://github.com/sudoHG/immichSlides/issues/135",
                                  "review_by": "2026-10-01", "owner": "sudoHG"}]}
        checks = registry_checks(registry, "2026-10-02", {135: "closed"})
        self.assertTrue(checks[0]["expired"])
        self.assertEqual("closed", checks[0]["issue_state"])
        self.assertFalse(registry_checks(registry, "2026-10-01", {135: "open"})[0]["expired"])

    def test_registry_warning_and_expiry_match_retry_dates_without_editing_entries(self):
        from ci_flaky import eligible_entry
        from test_ci_flaky import registry
        payload = registry()
        original = copy.deepcopy(payload)
        item = payload["entries"][0]
        for day, status, eligible in (("2026-10-30", "active", True),
                                      ("2026-10-31", "review-due", True),
                                      ("2026-11-07", "review-due", True),
                                      ("2026-11-08", "expired", False)):
            for states, expected in (({123: "open"}, "open"), ({123: "closed"}, "closed"),
                                     ({123: "missing"}, "missing"), ({}, "unknown")):
                with self.subTest(day=day, state=expected):
                    check = registry_checks(payload, day, states)[0]
                    self.assertEqual(status, check["review_status"])
                    self.assertEqual(expected, check["issue_state"])
                    self.assertEqual(eligible, check["date_eligible"])
                    self.assertEqual(eligible, eligible_entry(payload, item["identity"],
                        tier="ui", environment="hermetic", today=date.fromisoformat(day)) is not None)
        self.assertEqual(original, payload)

    def test_health_keeps_first_failure_after_rerun_and_reports_missing_legacy_metrics(self):
        from ci_health import health_report, observation_metrics
        first = entry("2026-10-01")
        first["health"] = observation_metrics(first["observed"], unexpected_skips=0)
        last = entry("2026-10-01", "passed", attempt=2)
        last["health"] = observation_metrics(last["observed"], unexpected_skips=0)
        last["attempt_history"] = [first, copy.deepcopy(last)]
        legacy = entry("2026-10-02", "passed", run=11)
        snapshot = ci_report.merge_snapshot(None, [last, legacy], date(2026, 10, 9))
        result = health_report(snapshot, {"entries": []}, "2026-10", date(2026, 10, 9))
        self.assertEqual(2, result["coverage"]["runs"])
        self.assertEqual(["2026-10-01", "2026-10-02"], result["coverage"]["days_with_runs"])
        self.assertEqual(6, result["coverage"]["missing_calendar_days"])
        self.assertEqual({"value": 1, "sampled_runs": 1, "missing_runs": 1}, result["metrics"]["first_attempt_failures"])
        self.assertEqual({"value": None, "sampled_runs": 0, "missing_runs": 2}, result["metrics"]["queue_seconds"])
        self.assertGreater(result["storage"]["snapshot_json_bytes"], 0)
        malformed = copy.deepcopy(snapshot)
        malformed["days"]["2026-10-01"]["retention_days"] = 7
        with self.assertRaises(ContractError):
            health_report(malformed, {"entries": []}, "2026-10", date(2026, 10, 9))

    def test_health_counts_retry_first_calls_before_compaction_and_rejects_bad_metrics(self):
        from ci_health import health_report, observation_metrics
        from ci_flaky import merge_retry
        report = entry()
        report["observed"] = [merge_retry(report["observed"][0], observation(IDENTITY, "passed", 2))]
        report["health"] = observation_metrics(report["observed"], unexpected_skips=0)
        compact = ci_report.compact_entry(report, set())
        snapshot = ci_report.merge_snapshot(None, [compact], date(2026, 10, 1))
        result = health_report(snapshot, {"entries": []}, "2026-10", date(2026, 10, 1))
        for key, expected in (("first_attempt_failures", 1), ("flaky_passed", 1), ("test_duration_seconds", 3)):
            self.assertEqual(expected, result["metrics"][key]["value"])
        for invalid in (-1, float("nan"), True):
            broken = copy.deepcopy(snapshot)
            broken["days"]["2026-10-01"]["entries"][0]["health"]["test_duration_seconds"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ContractError):
                health_report(broken, {"entries": []}, "2026-10", date(2026, 10, 1))

    def test_first_failure_survives_pending_snapshot_before_gate_or_ui_rerun_passes(self):
        from ci_health import health_report
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        now = date(2026, 10, 1)
        for path in ci_report.PRODUCER_PATHS[:2]:
            for status in ("queued", "in_progress"):
                with self.subTest(path=path, status=status):
                    run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
                           "head_sha": "a" * 40, "path": path, "event": "push", "head_branch": "main",
                           "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "failure"}
                    identity = {"schema_version": 1, "repository": api.repository, "event": "push", "ref": "refs/heads/main",
                                "pushed_sha": run["head_sha"], "tree_sha": "b" * 40}
                    record = {"workflow_id": 123, "workflow_path": path, "identity": identity,
                              "classification": {"ci_changing": False}, "workflows": {path: {"base": "trusted workflow"}}}
                    summary = valid_summary()
                    summary["identity"] = identity
                    summary["source"].update(event="push", workflow_path=path)
                    summary["run"]["id"] = str(run["id"])
                    test = summary["population"]["observed"][0]["identity"]
                    summary["population"]["observed"] = [observation(test, "failed", 2, exit_code=1)]
                    jobs = [{"status": "completed", "conclusion": "failure"}]
                    with patch("ci_report.on_main", return_value=True), \
                            patch("ci_publish.producer_evidence", return_value=(jobs, [summary])) as producer, \
                            patch("ci_publish_git.evaluate_records", return_value={"state": "success"}):
                        failed = read_run(api, run, {10: record})
                        snapshot = ci_report.merge_snapshot(None, [ci_report.compact_entry(failed, set())], now)
                        saved = snapshot["days"][now.isoformat()]["entries"][0]
                        pending = read_run(api, {**run, "run_attempt": 2, "status": status}, {10: record}, saved)
                        self.assertEqual(1, producer.call_count)
                        snapshot = ci_report.merge_snapshot(snapshot, [ci_report.compact_entry(pending, set())], now)
                        metrics = health_report(snapshot, {"entries": []}, "2026-10", now)["metrics"]
                        self.assertEqual({"value": 1, "sampled_runs": 1, "missing_runs": 0}, metrics["first_attempt_failures"])
                        saved = snapshot["days"][now.isoformat()]["entries"][0]
                        summary["run"]["attempt"] = 2
                        summary["population"]["observed"] = [observation(test, "passed", 3)]
                        jobs[0]["conclusion"] = "success"
                        passed = read_run(api, {**run, "run_attempt": 2, "conclusion": "success"}, {10: record}, saved)
                    self.assertEqual("passed", passed["status"])
                    snapshot = ci_report.merge_snapshot(snapshot, [ci_report.compact_entry(passed, set())], now)
                    metrics = health_report(snapshot, {"entries": []}, "2026-10", now)["metrics"]
                    self.assertEqual({"value": 1, "sampled_runs": 1, "missing_runs": 0}, metrics["first_attempt_failures"])

    def test_nightly_method_placeholder_durations_are_unavailable_after_compaction(self):
        from ci_health import health_report
        from ci_nightly import aggregate_nightly
        from run_strict_e2e import resolve_suite_selector
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
               "head_sha": "a" * 40, "path": ci_report.NIGHTLY_PATH, "event": "schedule", "head_branch": "main",
               "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "success"}
        identity = {"schema_version": 1, "repository": api.repository, "event": "schedule", "ref": "refs/heads/main",
                    "commit_sha": run["head_sha"], "tree_sha": "b" * 40}
        case = test_identity("strict", "smoke", **IDENTITY["dimensions"])
        summary = valid_summary()
        summary["identity"] = identity
        summary["source"].update(event="schedule", workflow_path=ci_report.NIGHTLY_PATH)
        summary["run"] = {"id": "10", "attempt": 1, "tier": "strict", "job": "nightly-strict", "shard": "iphone"}
        # A measured case invocation is not an individual method duration.
        summary["population"].update(declared=[case], compiled=[case], observed=[observation(case, "passed", 37)])
        aggregate = aggregate_nightly([case], [summary], live_in_scope=False)
        aggregate.update(identity=identity, hashes=summary["hashes"], run={"id": "10", "attempt": 1},
                         source=summary["source"], capacity={"shard_intervals": [{"shard": "iphone"}]})
        trace = {"warm": [{"identity": case, "official_methods": [
            {"identifier": resolve_suite_selector("ios", "smoke").split("/", 1)[1], "result": "Passed"}],
            "build_operations": 0, "products_unchanged": True, "log_present": True, "exit_code": 0,
            "official_summary": {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}}]}
        artifacts = [{"name": name, "expired": False} for name in ("nightly-aggregate-10-1", "nightly-strict-iphone-10-1")]
        with patch("ci_publish.json_member", side_effect=[aggregate, summary, trace]):
            report = ci_report.nightly_attempt(api, run, 1, artifacts)
        self.assertTrue(report["observed"])
        compact = ci_report.compact_entry(report, set())
        snapshot = ci_report.merge_snapshot(None, [compact], date(2026, 10, 1))
        metrics = health_report(snapshot, {"entries": []}, "2026-10", date(2026, 10, 1))["metrics"]
        self.assertEqual({"value": None, "sampled_runs": 0, "missing_runs": 1}, metrics["test_duration_seconds"])
        self.assertEqual({"value": 0, "sampled_runs": 1, "missing_runs": 0}, metrics["first_attempt_failures"])

    def test_monthly_due_date_handles_year_boundary_and_explicit_partial_month(self):
        from ci_health import report_month
        self.assertEqual("2025-12", report_month("schedule", {}, date(2026, 1, 1)))
        self.assertIsNone(report_month("schedule", {}, date(2026, 1, 2)))
        self.assertIsNone(report_month("workflow_run", {}, date(2026, 1, 1)))
        self.assertEqual("2026-01", report_month("workflow_dispatch", {"inputs": {"health_month": "2026-01"}}, date(2026, 1, 2)))
        for month in ("2026-02", "2026-13", "2026-1", "candidate text"):
            with self.subTest(month=month), self.assertRaises(ContractError):
                report_month("workflow_dispatch", {"inputs": {"health_month": month}}, date(2026, 1, 2))

    def test_health_skip_classification_uses_approved_rules_and_exact_reasons(self):
        from ci_health import unexpected_skips, run_metrics
        summary = valid_summary()
        identity = summary["population"]["observed"][0]["identity"]
        summary["population"]["observed"] = [observation(identity, "skipped", 0, reason="fixture unavailable")]
        rule = {"kind": identity["kind"], "key_pattern": identity["key"], "dimensions": identity["dimensions"],
                "tier": summary["run"]["tier"], "environment": "hermetic", "reason": "fixture unavailable"}
        policy = {"schema_version": 1, "expected_skips": [rule], "deselections": [],
                  "approval_records": [{"approver": "sudoHG", "date": "2026-10-01", "tier": summary["run"]["tier"],
                                        "link": "https://github.com/sudoHG/immichSlides/issues/83#issuecomment-123"}]}
        self.assertEqual(0, unexpected_skips([summary], policy, "hermetic"))
        self.assertEqual(1, unexpected_skips([summary], policy, "live"))
        policy["approval_records"] = []
        self.assertEqual(1, unexpected_skips([summary], policy, "hermetic"))
        self.assertIsNone(unexpected_skips([summary], None, "hermetic"))
        run = {"run_attempt": 1, "status": "completed", "created_at": "2026-10-01T00:00:00Z",
               "run_started_at": "2026-10-01T00:00:10Z", "updated_at": "2026-10-01T00:01:10Z"}
        jobs = [{"conclusion": "success", "created_at": "2026-10-01T00:00:10Z", "started_at": "2026-10-01T00:00:40Z"},
                {"conclusion": "success", "created_at": "2026-10-01T00:00:10Z", "started_at": "2026-10-01T00:00:50Z"}]
        self.assertEqual({"queue_seconds": 70, "run_duration_seconds": 60}, run_metrics(run, jobs))
        self.assertIsNone(run_metrics(run)["queue_seconds"])
        self.assertEqual(70, run_metrics({**run, "run_attempt": 2}, jobs)["queue_seconds"])
        from ci_health import observation_metrics
        self.assertIsNone(observation_metrics([], unexpected_skips=0)["first_attempt_failures"])
        self.assertIsNone(observation_metrics([], unexpected_skips=0)["test_duration_seconds"])

    def test_read_only_health_stops_on_quota_and_never_bootstraps_missing_history(self):
        for snapshot, error in ((None, ContractError), (ci_report.RateLimitLow(), None)):
            with self.subTest(snapshot=snapshot), tempfile.TemporaryDirectory() as temporary:
                api = ci_report.ReportGitHub("sudoHG/immichSlides", "synthetic", dry_run=True)
                with patch("ci_report.ReportGitHub", return_value=api), patch.dict("os.environ", {"CI_REPORT_TOKEN": "synthetic"}), \
                        patch.object(api, "request", return_value={}), patch("ci_report.read_snapshot", return_value=snapshot,
                            side_effect=snapshot if isinstance(snapshot, Exception) else None):
                    args = ["--phase", "health", "--dry-run", "--month", "2026-10", "--output-dir", temporary]
                    if error:
                        with self.assertRaises(error):
                            ci_report.main(args)
                    else:
                        self.assertEqual(0, ci_report.main(args))
                    self.assertEqual([], list(Path(temporary).iterdir()))

    def test_artifact_storage_reuses_listed_metadata_without_counting_pages_twice(self):
        api = ci_report.ReportGitHub("sudoHG/immichSlides", "synthetic", dry_run=True)
        response = {"artifacts": [{"id": 1, "size_in_bytes": 12}, {"id": 2, "size_in_bytes": 8}]}
        with patch("ci_publish.GitHub.request", return_value=response):
            api.repo("actions/runs/10/artifacts?per_page=100&page=1")
            api.repo("actions/runs/10/artifacts?per_page=100&page=1")
        self.assertEqual(20, sum(api.artifact_sizes[10].values()))
        self.assertEqual(2, api.request_count)

    def test_missing_nightly_evidence_is_infrastructure_and_not_an_invented_test_result(self):
        report = entry()
        report["observed"] = []
        report["diagnostics"]["infrastructure"] = ["missing aggregate"]
        decision = issue_decision(None, NIGHTLY_INFRASTRUCTURE, [report], registry_referenced=False)
        self.assertEqual("open", decision["action"])
        self.assertEqual([], report["observed"])

    def test_github_lifecycle_reuses_registry_issue_preserves_body_and_reconciles_manual_closure(self):
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.issues = {135: {"number": 135, "body": "Existing maintainer diagnosis.", "state": "open",
                                     "labels": [{"name": "known-flaky"}]}}
                self.created = 0
            def pages(self, path, **filters):
                return list(self.issues.values())
            def request(self, path, **options):
                return {"total_count": 0, "incomplete_results": False, "items": []}
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {"name": "ci-reported-failure"}
                if path == "issues":
                    self.created += 1
                    return {"number": 136, **payload}
                number = int(path.rsplit("/", 1)[-1])
                if method == "PATCH":
                    updated = copy.deepcopy(payload)
                    if "labels" in updated:
                        updated["labels"] = [{"name": name} for name in updated["labels"]]
                    self.issues[number].update(updated)
                return self.issues[number]
        api = API()
        registry = {"entries": [{"identity": IDENTITY, "issue": "https://github.com/sudoHG/immichSlides/issues/135"}]}
        receipts, _ = synchronize_issues(api, [entry()], registry)
        self.assertEqual(135, receipts[0]["issue"])
        self.assertEqual(0, api.created)
        self.assertTrue(api.issues[135]["body"].startswith("Existing maintainer diagnosis."))
        receipts, _ = synchronize_issues(api, [entry()], registry)
        self.assertEqual([], receipts)
        api.issues[135]["state"] = "closed"
        receipts, _ = synchronize_issues(api, [entry("2026-10-02", run=11)], registry)
        self.assertEqual("reopen", receipts[0]["action"])
        self.assertFalse(read_state(api.issues[135])["closed"])
        for day, run in (("2026-10-03", 12), ("2026-10-04", 13), ("2026-10-05", 14)):
            synchronize_issues(api, [entry(day, "passed", run)], registry)
        self.assertEqual("open", api.issues[135]["state"])
        receipts, _ = synchronize_issues(api, [entry("2026-10-06", "passed", 15)], {"entries": []})
        self.assertEqual(["close"], [receipt["action"] for receipt in receipts])
        self.assertEqual(135, receipts[0]["issue"])
        self.assertEqual(0, api.created)
        self.assertEqual({"known-flaky", "ci-reported-failure"}, {label["name"] for label in api.issues[135]["labels"]})

    def test_failed_main_push_without_admission_still_has_a_verified_notification_sha(self):
        run = {"id": 12, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z", "head_sha": "a" * 40,
               "path": ".github/workflows/ci-gate.yml", "event": "push", "head_branch": "main",
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "status": "completed", "conclusion": "failure"}
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        with patch("ci_report.on_main", return_value=True):
            report = read_run(api, run, {})
        self.assertEqual("a" * 40, report["pushed_sha"])
        self.assertTrue(report["diagnostics"]["infrastructure"])
        with patch("ci_report.on_main", return_value=False):
            self.assertNotIn("pushed_sha", read_run(api, run, {}))
        identity = {"schema_version": 1, "repository": api.repository, "event": "push",
                    "ref": "refs/heads/main", "pushed_sha": run["head_sha"], "tree_sha": "b" * 40}
        record = {"workflow_id": run["workflow_id"], "workflow_path": run["path"], "identity": identity,
                  "classification": {"ci_changing": True}, "workflows": {run["path"]: {"base": "trusted workflow"}}}
        summary = valid_summary()
        summary["identity"] = identity
        summary["source"].update(event="push", workflow_path=run["path"])
        summary["run"]["id"] = str(run["id"])
        with patch("ci_report.on_main", return_value=True), patch("ci_publish.producer_evidence", return_value=([], [summary])), \
                patch("ci_publish_git.evaluate_records", return_value={"state": "success"}):
            verified = read_run(api, {**run, "conclusion": "success"}, {run["id"]: record})
        self.assertEqual("passed", verified["status"])
        self.assertEqual([], verified["diagnostics"]["infrastructure"])

    def test_post_merge_plan_requires_failure_identity_after_exact_reset_point(self):
        point = "2026-10-09T01:14:43Z"
        report = entry("2026-10-08", run=37759065943)
        report["source"].update(workflow_path=ci_report.PRODUCER_PATHS[0], event="push")
        report.update(pushed_sha="3f84ad734e632f7cabd6fcd2743d03e0c323b52a",
                      created_at="2026-10-08T09:47:17Z", conclusion="success", observed=[])
        report["diagnostics"].update(counts={"declared": 1051, "compiled": 1051, "observed": 1051,
                                           "passed": 1046, "skipped": 5},
                                     infrastructure=["missing required unit tier"])
        genuine = copy.deepcopy(report)
        genuine.update(day="2026-10-09", created_at="2026-10-09T02:00:00Z", conclusion="failure")
        genuine["diagnostics"]["counts"].update(passed=1045, failed=1)
        genuine["diagnostics"]["failures"] = [{"identity": test_identity("host", "format"), "outcome": "failed", "exit_codes": [1]}]
        cases = [(report, point, False), (genuine, point, True), (genuine, None, False)]
        for timestamp, accepted in (("2026-10-09T01:14:42Z", False), (point, True)):
            cases.append(({**genuine, "created_at": timestamp}, point, accepted))
        cases += [({key: value for key, value in genuine.items() if key != "created_at"}, point, False),
                  ({**genuine, "conclusion": "cancelled"}, point, False),
                  ({**genuine, "diagnostics": report["diagnostics"]}, point, False)]
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        for value, since, accepted in cases:
            with self.subTest(created=value.get("created_at"), since=since, accepted=accepted), tempfile.TemporaryDirectory() as temporary:
                snapshot = ci_report.merge_snapshot(None, [value], date(2026, 10, 9))
                if since:
                    snapshot["history_reset"] = {"actor": "sudoHG", "day": "2026-10-09", "run": "37868827278", "created_at": since}
                ci_report.write_report(Path(temporary), snapshot, [value], {"entries": []}, {}, stopped=False, now=date(2026, 10, 9))
                plan = json.loads((Path(temporary) / "sync.json").read_text())
                self.assertEqual([value] if accepted else [], plan["entries"])
                if not accepted:
                    with patch("ci_report.ensure_label", side_effect=AssertionError("no false-notification writes")):
                        self.assertEqual(([], {}), synchronize_issues(api, [value], {"entries": []}, post_merge_since=since))

    def test_newer_same_sha_producer_supersedes_a_saved_push_failure(self):
        first = entry()
        first["source"].update(workflow_path=ci_report.PRODUCER_PATHS[0], event="push")
        first.update(pushed_sha="a" * 40, created_at="2026-10-01T10:00:00Z", conclusion="failure")
        first["diagnostics"]["failures"] = [{"identity": test_identity("host", "format"), "outcome": "failed", "exit_codes": [1]}]
        newer = copy.deepcopy(first)
        newer.update(run={"id": 11, "attempt": 1}, created_at="2026-10-01T11:00:00Z", status="passed", conclusion="success")
        newer["diagnostics"]["failures"] = []
        since = "2026-10-01T00:00:00Z"
        self.assertEqual([first], ci_report.decision_entries([first], date(2026, 10, 1), post_merge_since=since))
        for status in ("passed", "pending", "unverified"):
            with self.subTest(status=status):
                latest = {**newer, "status": status}
                self.assertEqual([], ci_report.decision_entries([first, latest], date(2026, 10, 1), post_merge_since=since))
                api = type("API", (), {"repository": "sudoHG/immichSlides"})()
                with patch("ci_report.ensure_label", side_effect=AssertionError("no superseded notification")):
                    self.assertEqual(([], {}), synchronize_issues(api, [first, latest], {"entries": []}, post_merge_since=since))

    def test_verified_gate_and_ui_failures_after_reset_notify_once_per_sha(self):
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.issues, self.writes = [], []
            def pages(self, *args, **kwargs):
                return self.issues
            def request(self, path, **kwargs):
                return {"total_count": 0, "incomplete_results": False, "items": []}
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {}
                if path == "issues" and method == "POST":
                    self.writes.append(payload)
                    issue = {"number": 1, "state": "open", "body": payload["body"], "labels": [{"name": ci_report.LABEL}]}
                    self.issues.append(issue)
                    return issue
                if path == "issues/1" and method == "GET":
                    return self.issues[0]
                raise AssertionError("unexpected issue write")
        api, reports = API(), []
        for number, path in enumerate(ci_report.PRODUCER_PATHS[:2], 10):
            report = entry(run=number)
            report["source"].update(event="push", workflow_path=path)
            report.update(pushed_sha="a" * 40, created_at="2026-10-01T10:00:00Z", conclusion="failure")
            report["diagnostics"]["failures"] = [{"identity": test_identity("host", "format"), "outcome": "failed", "exit_codes": [1]}]
            reports.append(report)
        with patch("ci_report.wait_for_issue_visibility"):
            for _ in range(2):
                receipts, _ = synchronize_issues(api, reports, {"entries": []}, post_merge_since="2026-10-01T09:00:00Z")
                self.assertEqual(["post-merge"], [receipt["action"] for receipt in receipts])
        self.assertEqual(1, len(api.writes))
        self.assertIn("format", api.writes[0]["body"])
        self.assertIn(ci_report.PRODUCER_PATHS[0], api.writes[0]["body"])
        self.assertIn(ci_report.PRODUCER_PATHS[1], api.writes[0]["body"])

    def test_cancelled_nightly_or_push_does_not_read_missing_artifacts_or_track_failures(self):
        api = type("API", (), {"repository": "sudoHG/immichSlides",
                    "pages": lambda *args: self.fail("cancelled run must not read artifacts")})()
        for path, event in ((ci_report.NIGHTLY_PATH, "schedule"), (ci_report.PRODUCER_PATHS[0], "push")):
            run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
                   "head_sha": "a" * 40, "path": path, "event": event, "head_branch": "main",
                   "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "cancelled"}
            with self.subTest(path=path), patch("ci_report.on_main", return_value=True):
                report = ci_report.compact_entry(read_run(api, run, {}), set())
                self.assertEqual("unverified", report["status"])
                self.assertEqual("cancelled", report["conclusion"])
                self.assertEqual([], report["diagnostics"]["infrastructure"])
                self.assertFalse(ci_report.issue_eligible(report))
                self.assertEqual("none", issue_decision(None, NIGHTLY_INFRASTRUCTURE, [report], registry_referenced=False)["action"])

    def test_skipped_nightly_is_not_run_without_a_pass_or_an_issue_outcome(self):
        import ci_nightly_change as change
        repository, head, baseline = "sudoHG/immichSlides", "a" * 40, "b" * 40
        record = {"schema_version": 1, "decision": "skip", "reason": "non-affecting-changes", "event": "schedule",
                  "repository": repository, "head_sha": head, "run": {"id": "10", "attempt": 1},
                  "baseline": {"run_id": 2, "sha": baseline, "created_at": "2026-10-01T21:15:00Z"}}
        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-02T21:15:00Z", "head_sha": head,
               "path": ci_report.NIGHTLY_PATH, "event": "schedule", "head_branch": "main",
               "head_repository": {"full_name": repository}, "status": "completed", "conclusion": "success"}
        def artifact(name, expired=False):
            return {"id": 1, "name": name, "expired": expired, "size_in_bytes": 10}
        change_name = change.artifact_name(10, 1)
        for label, artifacts, saved, expected in (
                ("skipped", [artifact(change_name)], record, "not-run"),
                ("executed", [artifact(change_name)], {**record, "decision": "run", "reason": "changes-affect-app-or-ci"}, "failed"),
                ("no record", [], record, "failed"),
                ("skip with execution evidence", [artifact(change_name), artifact("nightly-aggregate-10-1")], record, "failed"),
                ("foreign run", [artifact(change_name)], {**record, "run": {"id": "11", "attempt": 1}}, "failed"),
                ("other commit", [artifact(change_name)], {**record, "head_sha": baseline}, "failed"),
                ("baseline outside main", [artifact(change_name)], record, "failed")):
            api = type("API", (), {"repository": repository, "pages": lambda *args, found=artifacts: found})()
            with self.subTest(label), patch("ci_publish.json_member", return_value=saved), \
                    patch("ci_report.on_main", side_effect=lambda revision: label != "baseline outside main"):
                report = read_run(api, run, {})
                self.assertEqual(expected, report["status"])
                if expected == "not-run":
                    self.assertEqual(change.NO_CHANGE_REASON, report["not_evaluated_reason"])
                    compact = ci_report.compact_entry(report, set())
                    self.assertEqual(change.NO_CHANGE_REASON, compact["not_evaluated_reason"])
                    self.assertFalse(ci_report.issue_eligible(compact))
                    self.assertEqual([], compact["observed"])
                    self.assertIn("Not evaluated: " + change.NO_CHANGE_REASON, ci_report.render_entry(report))
                    self.assertEqual("none", issue_decision(None, NIGHTLY_INFRASTRUCTURE, [compact], registry_referenced=False)["action"])
                else:
                    self.assertTrue(report["diagnostics"]["infrastructure"])

    def test_legacy_reset_point_uses_one_verified_read_and_is_cached_for_replay(self):
        reset = {"actor": "sudoHG", "day": "2026-10-09", "run": "37868827278"}
        run = {"id": 37868827278, "path": ci_report.REPORT_PATH, "event": "workflow_dispatch",
               "created_at": "2026-10-09T01:14:43Z", "head_branch": "main", "repository": {"full_name": "sudoHG/immichSlides"},
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "actor": {"login": "sudoHG"}, "triggering_actor": {"login": "sudoHG"}}
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        with patch.object(api, "repo", return_value=run, create=True) as reader:
            self.assertEqual(run["created_at"], ci_report.reset_notification_point(api, reset))
            self.assertEqual(run["created_at"], ci_report.reset_notification_point(api, reset))
            reader.assert_called_once_with("actions/runs/37868827278")
        for changes in ({"path": ci_report.PRODUCER_PATHS[0]}, {"actor": {"login": "other"}}):
            with self.subTest(changes=changes), patch.object(api, "repo", return_value={**run, **changes}, create=True), self.assertRaises(ContractError):
                ci_report.reset_notification_point(api, {key: value for key, value in reset.items() if key != "created_at"})
        limited = ci_report.ReportGitHub(api.repository, "", dry_run=True)
        limited.check_headers({"X-RateLimit-Remaining": "500", "X-RateLimit-Limit": "1000"})
        with self.assertRaises(ci_report.RateLimitLow):
            ci_report.reset_notification_point(limited, {key: value for key, value in reset.items() if key != "created_at"})
        self.assertEqual(0, limited.request_count)
        snapshot = ci_report.merge_snapshot(None, [], date(2026, 10, 9))
        snapshot["history_reset"] = {key: value for key, value in reset.items() if key != "created_at"}
        with tempfile.TemporaryDirectory() as temporary, patch("ci_report.read_snapshot", return_value=snapshot), \
                patch.object(limited, "request", return_value=None), patch.object(limited, "repo", side_effect=ci_report.RateLimitLow):
            self.assertEqual(0, ci_report.collect_report(limited, "schedule", {}, date(2026, 10, 9), Path(temporary)))
            saved = json.loads((Path(temporary) / "daily/history.json").read_text())
            self.assertEqual(snapshot["days"], saved["days"])
            self.assertTrue(saved["budget_stopped"])
            self.assertEqual([], json.loads((Path(temporary) / "sync.json").read_text())["entries"])

    def test_immediate_issue_replay_survives_label_index_delay(self):
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.issues, self.created = {}, 0
                self.index_lag = False
            def pages(self, path, **filters):
                if self.index_lag and "labels" in filters:
                    self.index_lag = False
                    return []
                return list(self.issues.values())
            def request(self, path, **options):
                return {"total_count": 0, "incomplete_results": False, "items": []}
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {"name": "ci-reported-failure"}
                if path == "issues":
                    self.created += 1
                    issue = {"number": self.created, "body": payload["body"], "state": "open",
                             "labels": [{"name": name} for name in payload["labels"]]}
                    self.issues[self.created] = issue
                    self.index_lag = True
                    return issue
                number = int(path.rsplit("/", 1)[-1])
                if method == "PATCH":
                    self.issues[number].update(payload)
                return self.issues[number]
        api = API()
        with patch("ci_report.time.sleep"):
            synchronize_issues(api, [entry()], {"entries": []})
        self.assertEqual([], synchronize_issues(api, [entry()], {"entries": []})[0])
        self.assertEqual(1, api.created)

    def test_main_ui_skips_require_the_existing_trusted_reuse_verdict(self):
        api = type("API", (), {"repository": "sudoHG/immichSlides"})()
        run = {"id": 12, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
               "head_sha": "a" * 40, "path": ".github/workflows/ci-ui.yml", "event": "push", "head_branch": "main",
               "head_repository": {"full_name": api.repository}, "status": "completed", "conclusion": "success"}
        identity = {"schema_version": 1, "repository": api.repository, "event": "push", "ref": "refs/heads/main",
                    "pushed_sha": run["head_sha"], "tree_sha": "b" * 40}
        record = {"workflow_id": 123, "workflow_path": run["path"], "identity": identity,
                  "classification": {"ci_changing": False}, "workflows": {run["path"]: {"base": "trusted workflow"}}}
        jobs = [{"name": "ui-archive", "status": "completed", "conclusion": "success"},
                {"name": "ui-iphone-default", "status": "completed", "conclusion": "skipped"}]
        summary = valid_summary()
        summary["identity"] = identity
        summary["source"].update(event="push", workflow_path=run["path"])
        summary["run"]["id"] = str(run["id"])
        for verdict, status in (({"state": "success", "reuse": {"producer_run_id": 10}}, "passed"),
                                ({"state": "pending", "deferred_to": "nightly-ui",
                                  "description": "UI deferred to nightly: no trusted identical-tree PR verdict"}, "not-run"),
                                ({"state": "pending"}, "failed"), (ContractError("no trusted proof"), "failed")):
            with self.subTest(verdict=verdict), patch("ci_report.on_main", return_value=True), \
                    patch("ci_publish.producer_evidence", return_value=(jobs, [summary])), \
                    patch("ci_ui_reuse.evaluate_reused_push", side_effect=verdict if isinstance(verdict, Exception) else None,
                          return_value=verdict) as reuse:
                report = read_run(api, run, {12: record})
                self.assertEqual(status, report["status"])
                reuse.assert_called_once_with(api, record, run, jobs, [summary])
                if status == "not-run":
                    self.assertIn("deferred to nightly", report["not_evaluated_reason"])
                    self.assertFalse(ci_report.issue_eligible(report))
                    self.assertEqual([], ci_report.notification_entries([report], "2026-09-01T00:00:00Z"))
                    self.assertEqual(report["not_evaluated_reason"], ci_report.compact_entry(report, set())["not_evaluated_reason"])

    def test_parameterized_swift_observations_cover_the_declared_function(self):
        summary = valid_summary()
        declared = test_identity("swift", "ExampleTests/loads photo", platform="ios")
        compiled = test_identity("swift", "immichSlidesTests/ExampleTests/`loads photo`(input:)", platform="ios")
        parameter = copy.deepcopy(compiled)
        parameter["dimensions"]["parameter"] = "input=1"
        summary["population"].update(declared=[declared], compiled=[compiled],
                                     observed=[observation(parameter, "passed", 1)])
        self.assertEqual([], summary_diagnostics([summary])["missing"])

    def test_reporter_credential_context_refuses_branch_events_and_other_workflows(self):
        environment = {"GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": "sudoHG/immichSlides",
                       "GITHUB_WORKFLOW_REF": "sudoHG/immichSlides/.github/workflows/ci-report.yml@refs/heads/main",
                       "GITHUB_EVENT_NAME": "workflow_run"}
        check_context(environment)
        for key, value in (("GITHUB_REF", "refs/heads/feature"), ("GITHUB_EVENT_NAME", "pull_request"),
                           ("GITHUB_WORKFLOW_REF", "sudoHG/immichSlides/.github/workflows/ci-gate.yml@refs/heads/main")):
            with self.subTest(key=key), self.assertRaises(ContractError):
                check_context({**environment, key: value})

    def test_real_nightly_suite_records_require_verified_method_results_for_registry_reuse(self):
        from ci_nightly import aggregate_nightly
        method = test_identity("strict", "StrictE2EFilterIOSUITests/testFilterPersonNormalMatch",
                               **{**IDENTITY["dimensions"], "suite": "filter-person"})
        case = test_identity("strict", "filter-person", **method["dimensions"])
        shard = valid_summary()
        shard["population"].update(declared=[case], compiled=[case],
                                   observed=[observation(case, "failed", 1, exit_code=65)])
        aggregate = aggregate_nightly([case], [shard], live_in_scope=False)
        trace = {"warm": [{"identity": case, "official_methods": [
            {"identifier": method["key"], "result": "Failed"}],
            "build_operations": 0, "products_unchanged": True, "log_present": True, "exit_code": 65,
            "official_summary": {"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0}}]}
        observed, missing = ci_report.method_observations(shard, trace)
        self.assertEqual(method, observed[0]["identity"])
        self.assertEqual("failed", observed[0]["outcome"])
        self.assertEqual(identity_token(method), identity_token(observed[0]["identity"]))
        self.assertNotEqual(identity_token(aggregate["observed"][0]["identity"]), identity_token(method))
        self.assertTrue(missing)  # The other filter-person invocations were not observed.
        from run_strict_e2e import FILTER_PERSON_SESSIONS
        trace["warm"][0]["official_methods"] += [{"identifier": item["selector"].split("/", 1)[1], "result": "Passed"}
                                               for item in FILTER_PERSON_SESSIONS[1:]]
        trace["warm"][0]["official_summary"].update(totalTestCount=3, passedTests=2)
        methods, missing = ci_report.method_observations(shard, trace)
        self.assertEqual([], missing)
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.issue = {"number": 133, "state": "open", "body": "Existing person-filter diagnosis.", "labels": []}
            def pages(self, *args, **kwargs):
                return []
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {}
                self.assert_path(path, method)
                if method == "PATCH":
                    self.issue.update(payload)
                return self.issue
            def assert_path(self, path, method):
                if path != "issues/133" or method not in {"GET", "PATCH"}:
                    raise AssertionError("method failure must reuse registry issue 133")
        api = API()
        report = entry()
        report["observed"] = methods
        receipts, _ = synchronize_issues(api, [report], {"entries": [{"identity": method,
            "issue": "https://github.com/sudoHG/immichSlides/issues/133"}]})
        self.assertEqual([133], [receipt["issue"] for receipt in receipts])
        self.assertEqual(identity_token(method), receipts[0]["token"])
        trace["warm"][0]["official_methods"][0]["result"] = "Passed"
        trace["warm"][0]["official_summary"].update(failedTests=0, passedTests=3)
        trace["warm"][0]["automated_contract_failed"] = True
        outcomes = ci_report.method_observations(shard, trace)[0]
        self.assertEqual([case], [item["identity"] for item in outcomes if item["outcome"] == "failed"])
        self.assertEqual("strict-case-contract-failed", outcomes[-1]["attempts"][0]["reason"])
        trace["warm"][0].pop("official_methods")
        observed, missing = ci_report.method_observations(shard, trace)
        self.assertEqual([], observed)
        self.assertTrue(missing)

    def test_newer_attempt_without_observation_revokes_a_saved_pass_and_keeps_first_failure(self):
        state = self.transition(None, entry())["state"]
        state = self.transition(state, entry("2026-10-02", "passed", 11))["state"]
        rerun = entry("2026-10-02", "passed", 11, 2)
        rerun["observed"] = []
        state = self.transition(state, rerun)["state"]
        self.assertEqual("unverified", state["nights"]["2026-10-02"]["11"]["outcome"])
        self.assertEqual([], state["explicit_pass_nights"])
        fresh = entry(attempt=2, outcome="passed")
        fresh["attempt_history"] = [entry(), fresh.copy()]
        self.assertEqual("open", self.transition(None, fresh)["action"])
        self.assertEqual("failed", self.transition(None, fresh)["state"]["nights"]["2026-10-01"]["10"]["outcome"])
        run = {"id": 10, "workflow_id": 123, "run_attempt": 2, "created_at": "2026-10-01T10:00:00Z", "head_sha": "a" * 40,
               "path": ci_report.NIGHTLY_PATH, "event": "schedule", "head_branch": "main",
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "status": "completed", "conclusion": "success"}
        api = type("API", (), {"repository": "sudoHG/immichSlides", "pages": lambda *args: []})()
        with patch("ci_report.on_main", return_value=True), patch("ci_report.nightly_attempt",
                side_effect=[entry(), entry(attempt=2, outcome="passed")]) as reader:
            observed = read_run(api, run, {})
        self.assertEqual([1, 2], [call.args[2] for call in reader.call_args_list])
        self.assertEqual("failed", self.transition(None, observed)["state"]["nights"]["2026-10-01"]["10"]["outcome"])
        compact = ci_report.compact_entry(observed, set())
        self.assertEqual([IDENTITY], [item["identity"] for item in compact["observed"]])
        with patch("ci_report.ensure_label"), patch("ci_report.visible_issues", return_value=[]), \
                patch("ci_report.matching_issues", return_value=[]), \
                patch("ci_report.sync_identity", return_value=None) as sync:
            synchronize_issues(api, [compact], {"entries": []})
        self.assertIn(IDENTITY, [call.args[2] for call in sync.call_args_list])

    def test_three_p2_contract_pass_nights_close_without_granting_release_authority(self):
        identity = copy.deepcopy(IDENTITY)
        identity["dimensions"]["suite"] = "p2-rotation"
        def report(day, outcome, run):
            value = entry(day, outcome, run)
            value["observed"][0]["identity"] = identity
            return value
        state = issue_decision(None, identity, [report("2026-10-01", "failed", 10)], registry_referenced=False)["state"]
        for day, run in (("2026-10-02", 11), ("2026-10-03", 12), ("2026-10-04", 13)):
            value = report(day, "needs-human-review", run)
            decision = issue_decision(state, identity, [value], registry_referenced=False)
            state = decision["state"]
            self.assertFalse(value["release_eligible"])
        self.assertEqual("close", decision["action"])

    def test_manual_closure_survives_passes_and_replay_and_history_starts_at_last_failure(self):
        state = self.transition(None, entry())["state"]
        closed = copy.deepcopy(state)
        closed["closed"] = True
        self.assertEqual("none", self.transition(closed, entry())["action"])
        self.assertEqual("none", self.transition(closed, entry("2026-10-02", "passed", 11))["action"])
        state = self.transition(state, entry("2026-10-03", run=12))["state"]
        self.assertEqual(["2026-10-03"], sorted(state["nights"]))
        self.assertEqual(2, state["failure_nights"])
        self.assertEqual("2026-10-01", state["first_failure"])

    def test_expired_evidence_does_not_rebuild_or_downgrade_the_verified_snapshot(self):
        saved = entry("2026-09-01", "passed")
        expired = copy.deepcopy(saved)
        expired.update(status="failed", evidence_expired=True)
        snapshot = {"schema_version": 2, "days": {saved["day"]: daily_rollup(saved["day"], [saved])}, "issue_index": {}}
        result = ci_report.merge_snapshot(snapshot, [expired], date(2026, 10, 1))
        self.assertEqual([saved], result["days"][saved["day"]]["entries"])
        self.assertEqual([], ci_report.decision_entries([expired], date(2026, 10, 1)))

    def test_compact_rollups_keep_failures_and_tracked_passes_without_full_populations(self):
        value = entry(outcome="passed")
        other = test_identity("strict", "OtherUITests/testOther", **IDENTITY["dimensions"])
        value["observed"].append(observation(other, "passed", 1))
        compact = ci_report.compact_entry(value, {identity_token(IDENTITY)})
        self.assertEqual([value["observed"][0]], compact["observed"])
        self.assertNotIn("population", compact)

    def test_workflow_completions_read_only_the_trigger_and_prior_snapshot(self):
        run = {"id": 10, "path": ci_report.NIGHTLY_PATH, "head_branch": "main",
               "event": "schedule", "head_repository": {"full_name": "sudoHG/immichSlides"},
               "repository": {"full_name": "sudoHG/immichSlides"}}
        api = type("API", (), {"repository": "sudoHG/immichSlides", "repo": lambda self, path: run,
                               "pages": lambda *args, **kwargs: self.fail("completion must not enumerate producer days")})()
        self.assertEqual([run], ci_report.discover_runs(api, "workflow_run", {"workflow_run": {"id": 10}}, date(2026, 10, 1)))
        for changes in ({"head_repository": {"full_name": "contributor/immichSlides"}},
                        {"event": "pull_request"}, {"path": ci_report.PRODUCER_PATHS[0], "event": "pull_request"},
                        {"head_branch": "feature"}):
            with self.subTest(changes=changes), patch.object(api, "repo", return_value={**run, **changes}):
                self.assertEqual([], ci_report.discover_runs(api, "workflow_run", {"workflow_run": {"id": 10}}, date(2026, 10, 1)))
        for changes in ({"fork_originated": True}, {"event": "pull_request"}):
            report = entry()
            report["source"].update(changes)
            with self.subTest(changes=changes), patch("ci_report.ensure_label", side_effect=AssertionError("no writes")):
                self.assertEqual(([], {}), synchronize_issues(api, [report], {"entries": []}))

    def test_dry_run_refuses_writes_and_low_api_budget_stops_before_another_request(self):
        api = ci_report.ReportGitHub("sudoHG/immichSlides", "", dry_run=True)
        with self.assertRaises(ContractError):
            api.repo("issues", method="POST", payload={"title": "must not write"})
        self.assertEqual(0, api.request_count)
        api.check_headers({"X-RateLimit-Remaining": "500", "X-RateLimit-Limit": "1000"})
        with patch("ci_publish.GitHub.request", side_effect=AssertionError("no request allowed")), \
                self.assertRaises(ci_report.RateLimitLow):
            api.repo("actions/runs/10")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with self.assertRaises(ci_report.RateLimitLow):
                ci_report.collect_report(api, "schedule", {}, date(2026, 10, 1), output)
            self.assertEqual([], list(output.iterdir()))
        self.assertEqual(0, api.request_count)
        self.assertLessEqual(ci_report.REQUEST_BUDGET, 150)
        api.check_headers({"X-RateLimit-Remaining": "900", "X-RateLimit-Limit": "1000"})
        api.request_count = 150
        with patch("ci_publish.GitHub.request", side_effect=AssertionError("run budget exhausted")), self.assertRaises(ci_report.RateLimitLow):
            api.repo("actions/runs/10")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "runs").mkdir()
            value = entry(day=datetime.now(timezone.utc).date().isoformat())
            (output / "sync.json").write_text(json.dumps({"schema_version": 2, "entries": [value], "registry": {"entries": []},
                "budget_stopped": False, "api_budget": {"requests": 150, "remaining": 900, "limit": 1000}}))
            with patch("ci_report.check_context"), patch("ci_report.ReportGitHub", return_value=api), \
                    patch.dict("os.environ", {"CI_REPORT_TOKEN": "synthetic-test-token", "GITHUB_REPOSITORY": api.repository}), \
                    patch("ci_publish.GitHub.request", side_effect=AssertionError("sync cannot reset the run budget")):
                self.assertEqual(0, ci_report.main(["--phase", "sync", "--output-dir", str(output)]))
            self.assertEqual(150, json.loads((output / "runs/issue-actions.json").read_text())["requests"])
        from ci_publish import GitHubRequestError
        api.request_count = 149
        with patch("ci_publish.GitHub._request", side_effect=GitHubRequestError(
                "synthetic transient failure", http_status=503, retry_delay=1)) as request, \
                patch("ci_publish.time.sleep"), self.assertRaises(ci_report.RateLimitLow):
            api.annotations(99)
        self.assertEqual(1, request.call_count)
        self.assertEqual(150, api.request_count)
        self.assertFalse(api.retry_reads)

    def test_unread_history_fails_without_outputs_but_loaded_history_survives_budget_stop(self):
        saved = ci_report.merge_snapshot(None, [entry()], date(2026, 10, 1))
        api = type("API", (), {"repository": "sudoHG/immichSlides", "request_count": 2, "remaining": 501,
                               "request": lambda *args: None, "budget_exhausted": lambda *args: False})()
        for previous, expected in ((None, "fail"), (saved, "preserve")):
            with tempfile.TemporaryDirectory() as temporary, patch("ci_flaky.parse_registry", return_value={"entries": []}), \
                    patch("ci_report.read_snapshot", side_effect=ci_report.RateLimitLow() if previous is None else None,
                          return_value=previous), patch("ci_report.visible_issues", side_effect=ci_report.RateLimitLow()):
                output = Path(temporary)
                if expected == "fail":
                    with self.assertRaises(ci_report.RateLimitLow):
                        ci_report.collect_report(api, "schedule", {}, date(2026, 10, 1), output)
                    self.assertFalse((output / "daily/history.json").exists())
                else:
                    ci_report.collect_report(api, "schedule", {}, date(2026, 10, 1), output)
                    snapshot = json.loads((output / "daily/history.json").read_text())
                    self.assertEqual(saved["days"], snapshot["days"])
                    self.assertTrue(snapshot["budget_stopped"])

    def test_history_search_paginates_and_missing_snapshots_require_explicit_maintainer_reset(self):
        run = {"id": 10, "workflow_id": 20, "path": ci_report.REPORT_PATH, "head_branch": "main",
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "repository": {"full_name": "sudoHG/immichSlides"},
               "event": "schedule", "head_sha": "a" * 40, "run_attempt": 1}
        saved = ci_report.merge_snapshot(None, [entry()], date(2026, 10, 1))
        saved["producer"] = {"repository": "sudoHG/immichSlides", "workflow_path": ci_report.REPORT_PATH,
                             "run": {"id": "10", "attempt": 1}, "commit_sha": "a" * 40}
        class API:
            repository = "sudoHG/immichSlides"
            def repo(self, path, **options):
                if path == "actions/workflows/ci-report.yml":
                    return {"id": 20, "path": ci_report.REPORT_PATH}
                if path == "actions/runs/10":
                    return run
                if path.startswith("actions/artifacts?"):
                    from urllib.parse import parse_qs, urlparse
                    return {"artifacts": [{"name": "unrelated"}] * 100 if parse_qs(urlparse(path).query)["page"] == ["1"] else [{
                        "name": "ci-report-daily-10-1", "expired": False, "created_at": "2026-10-01T10:00:00Z",
                        "workflow_run": {"id": 10, "head_branch": "main"}}]}
                return {"workflow_runs": [run]}
            def pages(self, path, *args, **options):
                return ci_report.GitHub.pages(self, path, *args, **options)
        with patch("ci_report.on_main", return_value=True), patch("ci_publish.json_member", return_value=saved):
            self.assertEqual(saved, ci_report.read_snapshot(API()))
        with patch("ci_report.on_main", return_value=True), patch.object(API, "pages", return_value=[]), self.assertRaises(ContractError):
            ci_report.read_snapshot(API())
        api = type("EmptyAPI", (), {"repository": "sudoHG/immichSlides", "request_count": 1, "remaining": 900,
                                   "request": lambda *args: None, "budget_exhausted": lambda *args: False})()
        for event, actor, allowed in (("schedule", "sudoHG", False), ("workflow_dispatch", "other", False),
                                      ("workflow_dispatch", "sudoHG", True)):
            with self.subTest(event=event, actor=actor), tempfile.TemporaryDirectory() as temporary, \
                    patch("ci_flaky.parse_registry", return_value={"entries": []}), patch("ci_report.read_snapshot", return_value=None), \
                    patch("ci_report.visible_issues", return_value=[]), patch("ci_report.discover_runs", return_value=[]), \
                    patch.dict("os.environ", {"GITHUB_ACTOR": actor, "GITHUB_TRIGGERING_ACTOR": actor, "GITHUB_RUN_ID": ""}, clear=False):
                output = Path(temporary)
                if allowed:
                    ci_report.collect_report(api, event, {"inputs": {"reset_history": True}}, date(2026, 10, 1), output)
                    self.assertEqual("sudoHG", json.loads((output / "daily/history.json").read_text())["history_reset"]["actor"])
                else:
                    with self.assertRaises(ContractError):
                        ci_report.collect_report(api, event, {"inputs": {"reset_history": True}}, date(2026, 10, 1), output)

    def test_diagnostic_nightly_is_retained_but_never_writes_or_recovers_an_issue(self):
        report = entry()
        report["diagnostic_shard"] = "ios-iphone-0"
        compact = ci_report.compact_entry(report, set())
        self.assertEqual("ios-iphone-0", compact["diagnostic_shard"])
        self.assertEqual([], ci_report.decision_entries([compact], date(2026, 10, 1)))
        with patch("ci_report.ensure_label", side_effect=AssertionError("no diagnostic writes")):
            self.assertEqual(([], {}), synchronize_issues(object(), [compact], {"entries": []}))
        self.assertEqual("none", self.transition(None, compact)["action"])
        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z", "head_sha": "a" * 40,
               "path": ci_report.NIGHTLY_PATH, "event": "workflow_dispatch", "head_branch": "main",
               "head_repository": {"full_name": "sudoHG/immichSlides"}, "status": "completed", "conclusion": "failure"}
        api = type("API", (), {"repository": "sudoHG/immichSlides", "pages": lambda *args: []})()
        with patch("ci_report.on_main", return_value=True):
            unavailable = read_run(api, run, {})
        self.assertEqual("unverified-dispatch-plan", unavailable["diagnostic_shard"])
        self.assertFalse(ci_report.issue_eligible(unavailable))
        plan = {"schema_version": 1, "identity": {"schema_version": 1, "repository": api.repository,
                "event": "workflow_dispatch", "ref": "refs/heads/main", "commit_sha": "a" * 40, "tree_sha": "b" * 40},
                "source": {"workflow_path": ci_report.NIGHTLY_PATH, "fork_originated": False},
                "run": {"id": "10", "attempt": 1}, "diagnostic_shard": "ios-iphone-0"}
        with patch("ci_report.on_main", return_value=True), patch.object(api, "pages", return_value=[{
                "name": "nightly-plan-10-1", "expired": False}]), patch("ci_publish.json_member", return_value=plan):
            failed_aggregate = read_run(api, run, {})
        self.assertEqual("ios-iphone-0", failed_aggregate["diagnostic_shard"])
        self.assertFalse(ci_report.issue_eligible(failed_aggregate))

    def test_rollup_is_written_before_issue_sync_and_sync_errors_preserve_other_identities(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            snapshot = ci_report.merge_snapshot(None, [entry()], date(2026, 10, 1))
            ci_report.write_report(output, snapshot, [entry()], {"entries": []}, {}, stopped=False, now=date(2026, 10, 1))
            self.assertTrue((output / "daily/history.json").is_file())
            self.assertTrue((output / "sync.json").is_file())
            ci_report.write_report(output, snapshot, [], {"entries": []}, {}, stopped=False, now=date(2026, 10, 1))
            self.assertEqual([entry()], json.loads((output / "sync.json").read_text())["entries"])
        errors = []
        class API:
            repository = "sudoHG/immichSlides"
            def __init__(self):
                self.created = []
            def pages(self, *args, **kwargs):
                return []
            def request(self, path, **options):
                return {"total_count": 0, "incomplete_results": False, "items": []}
            def repo(self, path, method="GET", payload=None, missing=False):
                if path.startswith("labels/"):
                    return {}
                if method == "POST":
                    self.created.append(payload)
                    return {"number": len(self.created), "state": "open", "body": payload["body"],
                            "labels": [{"name": "ci-reported-failure"}]}
                return None
        api = API()
        second = entry(run=11)
        second["observed"][0]["identity"] = test_identity("strict", "OtherUITests/testOther", **IDENTITY["dimensions"])
        real_body = ci_report.issue_body
        def bounded_body(issue, state, repository):
            if state["identity"] == IDENTITY:
                raise ContractError("issue history exceeds GitHub limit")
            return real_body(issue, state, repository)
        with patch("ci_report.issue_body", side_effect=bounded_body), patch("ci_report.wait_for_issue_visibility"):
            receipts, _ = synchronize_issues(api, [entry(), second], {"entries": []}, errors=errors)
        self.assertEqual(1, len(errors))
        self.assertEqual(1, len(receipts))
        self.assertEqual(1, len(api.created))


if __name__ == "__main__":
    unittest.main()
