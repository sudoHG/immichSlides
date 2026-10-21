"""Guard coverage and admission decisions against accidental green verdicts."""

import ast
import copy
import json
import re
import unittest
from pathlib import Path
from unittest.mock import patch

import ci_summary
from run_host_checks import HOST_CHECKS
from ci_verdict import (classify_changes, evaluate_gate, evaluate_population, parse_policy, select_policy)
from test_ci_summary import valid_summary


class NightlyVerdictTests(unittest.TestCase):
    def test_fixture_ui_starts_after_archives_and_aggregates_wait_for_consumed_inputs(self):
        import yaml
        root = Path(__file__).parent.parent
        jobs = yaml.safe_load((root / ".github/workflows/ci-nightly.yml").read_text())["jobs"]

        def declared_needs(job):
            needs = job.get("needs", [])
            return {needs} if isinstance(needs, str) else set(needs)

        pending = list(declared_needs(jobs["ui-shards"]))
        dependencies = set()
        while pending:
            dependency = pending.pop()
            if dependency not in dependencies:
                dependencies.add(dependency)
                pending.extend(declared_needs(jobs[dependency]))
        self.assertNotIn("strict", dependencies, "UI shards must not wait for the strict matrix")
        for job_id, job in jobs.items():
            with self.subTest(job=job_id):
                referenced = set(re.findall(r"\bneeds\.([\w-]+)", yaml.safe_dump(job)))
                self.assertFalse(referenced - declared_needs(job),
                                 f"{job_id} references undeclared needs: {sorted(referenced - declared_needs(job))}")
        self.assertEqual({"change", "plan", "ui-archive", "ui-shards"}, set(jobs["ui-aggregate"]["needs"]))
        self.assertEqual({"change", "plan", "strict", "ui-aggregate"}, set(jobs["aggregate"]["needs"]))
        for job_id in ("strict", "ui-shards"):
            with self.subTest(job=job_id):
                self.assertEqual(2, jobs[job_id]["strategy"]["max-parallel"])

    def test_identity_failure_upload_is_standalone_and_only_runs_when_the_receipt_exists(self):
        import os
        import subprocess
        import tempfile
        import yaml
        root = Path(__file__).parent.parent
        jobs = yaml.safe_load((root / ".github/workflows/ci-nightly.yml").read_text())["jobs"]
        steps = jobs["strict"]["steps"]
        probe = next(step for step in steps if step.get("id") == "identity_failure")
        upload = next(step for step in steps if step.get("with", {}).get("name", "").startswith("nightly-identity-"))
        records = next(step for step in steps if step.get("with", {}).get("name", "").startswith("nightly-strict-"))
        review = next(step for step in steps if step.get("id") == "review")
        self.assertEqual("always()", probe["if"])
        self.assertEqual("always() && steps.identity_failure.outputs.exists == 'true'", upload["if"])
        for step in (records, review):
            self.assertEqual("always() && steps.identity_failure.outputs.exists != 'true'", step["if"])
        self.assertEqual("nightly-identity-${{ matrix.id }}-${{ github.run_id }}-${{ github.run_attempt }}", upload["with"]["name"])
        self.assertEqual(records["uses"], upload["uses"])
        self.assertEqual(records["with"]["path"].removesuffix("/records") + "/identity-failure.json", upload["with"]["path"])
        self.assertEqual(records["with"]["retention-days"], upload["with"]["retention-days"])
        self.assertEqual("error", upload["with"]["if-no-files-found"])
        accounting = next(step for step in steps if "--preparation-failed" in step.get("run", ""))
        cleanup = next(step for step in steps if "rm -rf" in step.get("run", ""))
        self.assertLess(steps.index(accounting), steps.index(probe))
        self.assertLess(steps.index(probe), steps.index(review))
        self.assertLess(steps.index(probe), steps.index(upload))
        self.assertLess(steps.index(upload), steps.index(cleanup))
        for exists in (False, True):
            with self.subTest(receipt_exists=exists), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                receipt = temporary / "nightly-strict/identity-failure.json"
                receipt.parent.mkdir()
                if exists:
                    receipt.write_text("{}")
                outputs = temporary / "step-output"
                completed = subprocess.run(["bash", "-eu", "-c", probe["run"]],
                    env={**os.environ, "RUNNER_TEMP": str(temporary), "GITHUB_OUTPUT": str(outputs)},
                    capture_output=True, text=True, timeout=5)
                self.assertEqual(0, completed.returncode, completed.stderr)
                self.assertEqual("exists=true\n" if exists else "", outputs.read_text() if outputs.exists() else "")

        ui_steps = jobs["ui-shards"]["steps"]
        ui_probe = next(step for step in ui_steps if step.get("id") == "identity_failure")
        ui_upload = next(step for step in ui_steps if step.get("with", {}).get("name", "").startswith("nightly-ui-identity-"))
        ui_records = next(step for step in ui_steps if step.get("with", {}).get("name", "").startswith("ui-${{ matrix.device }}-${{ matrix.shard }}-"))
        staging = next(step for step in ui_steps if step.get("id") == "staging")
        scan = next(step for step in ui_steps if step.get("id") == "scan")
        ui_cleanup = next(step for step in ui_steps if "rm -rf" in step.get("run", ""))
        self.assertIn("stage-download --device '${{ matrix.device }}' --shard '${{ matrix.shard }}'", staging["run"])
        self.assertEqual("always()", ui_probe["if"])
        self.assertEqual("always() && steps.identity_failure.outputs.exists == 'true'", ui_upload["if"])
        self.assertEqual("always() && steps.identity_failure.outputs.exists != 'true'", scan["if"])
        self.assertEqual("always() && steps.scan.outcome == 'success'", ui_records["if"])
        self.assertEqual("nightly-ui-identity-${{ matrix.device }}-${{ matrix.shard }}-${{ github.run_id }}-${{ github.run_attempt }}", ui_upload["with"]["name"])
        self.assertEqual(upload["uses"], ui_upload["uses"])
        self.assertEqual("${{ runner.temp }}/ui-identity/identity-failure.json", ui_upload["with"]["path"])
        self.assertEqual(upload["with"]["retention-days"], ui_upload["with"]["retention-days"])
        self.assertEqual("error", ui_upload["with"]["if-no-files-found"])
        self.assertLess(ui_steps.index(staging), ui_steps.index(ui_probe))
        self.assertLess(ui_steps.index(ui_probe), ui_steps.index(scan))
        self.assertLess(ui_steps.index(ui_probe), ui_steps.index(ui_upload))
        self.assertLess(ui_steps.index(ui_upload), ui_steps.index(ui_cleanup))
        for exists in (False, True):
            with self.subTest(ui_receipt_exists=exists), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                receipt = temporary / "ui-identity/identity-failure.json"
                receipt.parent.mkdir()
                if exists:
                    receipt.write_text("{}")
                outputs = temporary / "step-output"
                completed = subprocess.run(["bash", "-eu", "-c", ui_probe["run"]],
                    env={**os.environ, "RUNNER_TEMP": str(temporary), "GITHUB_OUTPUT": str(outputs)},
                    capture_output=True, text=True, timeout=5)
                self.assertEqual(0, completed.returncode, completed.stderr)
                self.assertEqual("exists=true\n" if exists else "", outputs.read_text() if outputs.exists() else "")

    def test_preparation_failure_keeps_all_cases_failed_and_zero_cases_executed(self):
        from ci_nightly import aggregate_nightly
        cases = [ci_summary.test_identity("strict", "p2-exif", device="ipad", configuration="Debug",
                 suite="p2-exif", scenario="normal", fixture=str(number)) for number in range(6)]
        summary = valid_summary()
        summary["population"].update(declared=cases, compiled=[], observed=[
            dict(ci_summary.observation(case, "not-run", 0, reason="simulator preparation infrastructure failure",
                                        exit_code=None), outcome="failed") for case in cases])
        summary["status"] = "failed"
        summary["infrastructure"] = [{"code": "simulator-preparation-failed", "message": "Preparation failed before tracer execution"}]
        for claimed_status in ("failed", "passed"):
            with self.subTest(claimed_status=claimed_status):
                summary["status"] = claimed_status
                result = aggregate_nightly(cases, [summary], live_in_scope=False)
                self.assertEqual("failed", result["status"])
                self.assertEqual(summary["population"]["observed"], result["observed"])
                self.assertEqual(6, result["matrix"]["scheduled"])
                self.assertEqual(0, result["matrix"]["executed"])
                self.assertFalse(result["matrix"]["equal"])
                self.assertEqual(6, len(result["matrix"]["missing"]))
                self.assertTrue(any(error.startswith("producer infrastructure failure:") for error in result["errors"]))
                self.assertFalse(result["release_eligible"])

    def test_ipad_smoke_exclusions_follow_the_selected_tests_phone_guard(self):
        from ci_nightly import contract_population
        cases, exclusions = contract_population()
        self.assertEqual([case for case in cases if case["device"] == "ipad" and case["suite"] == "smoke"], [])
        device_exclusions = [entry for entry in exclusions if entry["case"]["device"] == "ipad"
                             and entry["case"]["suite"] == "smoke"]
        self.assertEqual({entry["case"]["fixture"] for entry in device_exclusions}, {"a", "b"})
        from ci_nightly import require_smoke_phone_guard
        source = (Path(__file__).parent.parent / "immichSlidesUITests/StrictE2ESmokeUITests.swift").read_text()
        require_smoke_phone_guard(source)
        for changed in (source.replace("== .phone", "== .pad"),
                        source.replace("guard UIDevice", "// guard UIDevice"),
                        source.replace("throw XCTSkip", "XCTFail")):
            with self.subTest(source=changed), self.assertRaises(ci_summary.ContractError):
                require_smoke_phone_guard(changed)

    def test_informational_outcomes_are_reported_without_hiding_execution_or_infrastructure_failure(self):
        from ci_nightly import aggregate_nightly
        identity = ci_summary.test_identity("strict", "filter-vision", device="iphone", configuration="Debug",
                                            suite="filter-vision", scenario="normal", fixture="a")
        for outcome, infrastructure, expected in (("failed", [], "passed"), ("not-run", [], "failed"),
                ("passed", [{"code": "interrupted", "message": "cancelled"}], "failed")):
            with self.subTest(outcome=outcome, infrastructure=infrastructure):
                summary = valid_summary()
                summary["population"].update(declared=[identity], compiled=[identity],
                    observed=[ci_summary.observation(identity, outcome, 1)])
                summary["infrastructure"] = infrastructure
                result = aggregate_nightly([identity], [summary], live_in_scope=False, informational=["filter-vision"])
                self.assertEqual(result["status"], expected)
                self.assertEqual(len(result["informational"]), 1)

    def test_matrix_requires_exact_execution_without_duplicates_or_unrun_placeholders(self):
        from ci_nightly import matrix_equality
        identity = ci_summary.test_identity("strict", "smoke", device="iphone", configuration="Debug",
                                            suite="smoke", scenario="normal", fixture="a")
        good = ci_summary.observation(identity, "passed", 1)
        for entries, expected in (([good], True), ([], False), ([good, good], False),
                                  ([ci_summary.observation(identity, "not-run", 0)], False),
                                  ([dict(good, identity=dict(identity, key="unexpected"))], False)):
            with self.subTest(entries=entries):
                self.assertEqual(matrix_equality([identity], entries)["equal"], expected)

    def test_nightly_rules_keep_unbuilt_tiers_green_and_skeletons_ineligible(self):
        from ci_nightly import aggregate_nightly
        from ci_failure_diagnostics import environment_limit_evidence
        from test_ci_summary import hosted_timeout_summary
        yellow, resources = hosted_timeout_summary()
        row = yellow["population"]["observed"][0]
        proof = environment_limit_evidence(yellow, row, [resources], runner_hosted=True)
        row["environment_limit"] = row["attempts"][0]["environment_limit"] = proof
        case = row["identity"]
        result = aggregate_nightly([case], [yellow], live_in_scope=False)
        self.assertEqual("environment-limited", result["status"])
        self.assertEqual("failed", result["observed"][0]["outcome"])
        self.assertEqual([case], result["environment_limited"])
        import contextlib
        import io
        import os
        import tempfile
        import time
        from ci_nightly import main
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = root / "records" / "nightly-strict-iphone-debug-0-10-1"
            records.mkdir(parents=True)
            (records / "summary.json").write_text(json.dumps(yellow))
            (records / "p2-review-bindings.json").write_text(json.dumps({"schema_version": 1, "review_packages": []}))
            (records / "trace.json").write_text(json.dumps({"started_epoch": time.time() - 10, "finished_epoch": time.time()}))
            planned = [{"id": "iphone-debug-0", "cases": [{"platform": "ios", **case["dimensions"]}]}]
            hashes = {"manifests": {"nightly-matrix": "a" * 64}, "policies": {"nightly": "a" * 64}}
            plan = {"identity": yellow["identity"], "run": {"id": "10", "attempt": 1}, "hashes": hashes,
                "shards": planned, "started_epoch": time.time() - 20, "max_parallel": 2}
            (root / "plan.json").write_text(json.dumps(plan))
            stdout = io.StringIO()
            with patch("ci_nightly.workspace_preflight"), patch("ci_nightly.run_identity", return_value=yellow["identity"]), patch(
                    "ci_nightly.source_metadata", return_value=(yellow["source"]["workflow_path"], False)), patch(
                    "ci_nightly.file_hash", return_value="a" * 64), patch("ci_nightly.shards", return_value=planned), patch(
                    "ci_nightly.read_policy", return_value={"live_tier_in_scope": False, "built_tiers": ["strict"]}), patch(
                    "ci_nightly.validate_shard", return_value=yellow), patch.dict(os.environ, GITHUB_RUN_ID="10",
                    GITHUB_RUN_ATTEMPT="1"), contextlib.redirect_stdout(stdout):
                code = main(["aggregate", "--output-dir", str(root / "output"), "--plan", str(root / "plan.json"),
                    "--records-dir", str(root / "records"), "--matrix-job-result", "success"])
            self.assertEqual(0, code)
            self.assertIn("::warning title=Environment-limited strict timing::", stdout.getvalue())
            warning = (root / "output" / "nightly.md").read_text()
            self.assertIn("**WARNING: hosted timing failures are environment-limited", warning)
            self.assertIn(ci_summary.identity_key(case), warning)
            self.assertIn("idle=5%", warning)
        red = copy.deepcopy(yellow)
        red["population"]["observed"][0].pop("environment_limit")
        red["population"]["observed"][0]["attempts"][0].pop("environment_limit")
        red_row = red["population"]["observed"][0]
        red_row["identity"]["dimensions"]["fixture"] = "b"
        self.assertEqual("failed", aggregate_nightly([case, red_row["identity"]], [yellow, red], live_in_scope=False)["status"])
        for name, changed in (("legacy failure", red), ("infrastructure", copy.deepcopy(yellow))):
            if name == "infrastructure":
                changed["infrastructure"].append({"code": "cleanup-failed", "message": "cleanup failed"})
            with self.subTest(name=name):
                scheduled = changed["population"]["declared"]
                self.assertEqual("failed", aggregate_nightly(scheduled, [changed], live_in_scope=False)["status"])
        self.assertEqual("failed", aggregate_nightly([case], [yellow], live_in_scope=True)["status"])
        identity = ci_summary.test_identity("strict", "smoke", device="iphone", configuration="Debug",
                                            suite="smoke", scenario="normal", fixture="a")
        summary = valid_summary()
        summary["population"] = dict(summary["population"], declared=[identity], compiled=[identity],
                                     observed=[ci_summary.observation(identity, "passed", 1)])
        summary["run"].update(tier="strict", job="nightly-strict", shard="iphone-debug-0")
        for outcome, infrastructure, live, expected in (
                ("passed", [], False, "passed"), ("flaky-passed", [], False, "passed"),
                ("needs-human-review", [], False, "failed"), ("failed", [], False, "failed"),
                ("skipped", [], False, "failed"), ("not-run", [], False, "failed"),
                ("passed", [{"code": "interrupted", "message": "cancelled"}], False, "failed"),
                ("passed", [], True, "failed")):
            with self.subTest(outcome=outcome, live=live, infrastructure=infrastructure):
                changed = copy.deepcopy(summary)
                entry = ci_summary.observation(identity, outcome, 1, reason="unexpected skip")
                if outcome == "flaky-passed":
                    entry["attempts"] = [dict(entry["attempts"][0], number=1, outcome="failed", duration_seconds=.5),
                                          dict(entry["attempts"][0], number=2, outcome="passed", duration_seconds=.5)]
                changed["population"]["observed"] = [entry]
                changed["infrastructure"] = infrastructure
                changed["status"] = "unverified" if outcome == "needs-human-review" else "passed"
                result = aggregate_nightly([identity], [changed], live_in_scope=live)
                self.assertEqual(result["status"], expected)
                self.assertFalse(result["release_eligible"])
                self.assertEqual(result["tiers"]["ui"], "not yet in scope")
        summary["status"] = "unverified"
        self.assertEqual(aggregate_nightly([identity], [summary], live_in_scope=False)["status"], "failed")

    def test_p2_contracts_allow_review_pending_but_never_a_failed_producer(self):
        from ci_nightly import aggregate_nightly
        identity = ci_summary.test_identity("strict", "p2-rotation", device="iphone", configuration="Debug",
                                            suite="p2-rotation", scenario="normal", fixture="a")
        summary = valid_summary()
        summary["population"].update(declared=[identity], compiled=[identity],
                                     observed=[ci_summary.observation(identity, "needs-human-review", 1)])
        summary["status"] = "unverified"
        self.assertEqual(aggregate_nightly([identity], [summary], live_in_scope=False)["status"], "passed")
        summary["status"] = "failed"
        self.assertEqual(aggregate_nightly([identity], [summary], live_in_scope=False)["status"], "failed")

    def test_aggregate_rejects_wrong_provenance_and_declared_population(self):
        from ci_nightly import validate_shard
        summary = valid_summary()
        expected = summary["population"]["declared"]
        summary["run"].update(tier="strict", job="nightly-strict", shard="s")
        summary["hashes"] = {"manifests": {"nightly-matrix": "a" * 64},
                              "policies": {"nightly": "b" * 64}}
        for path, value in (("identity.tree_sha", "c" * 40), ("run.attempt", 2),
                            ("run.shard", "other"), ("hashes.manifests.nightly-matrix", "c" * 64),
                            ("population.declared", [])):
            with self.subTest(path=path):
                changed = copy.deepcopy(summary)
                target = changed
                parts = path.split(".")
                for part in parts[:-1]:
                    target = target[part]
                target[parts[-1]] = value
                with self.assertRaises(ci_summary.ContractError):
                    validate_shard(changed, summary["identity"], summary["run"], summary["hashes"], expected)

    def test_missing_compilation_fails_only_that_case_and_preserves_completed_results(self):
        from ci_nightly import aggregate_nightly, validate_shard
        identities = [ci_summary.test_identity("strict", "smoke", device="iphone", configuration="Debug",
                      suite="smoke", scenario="normal", fixture=str(number)) for number in range(6)]
        for outcome, executed in (("failed", 6), ("passed", 6), ("not-run", 5)):
            with self.subTest(outcome=outcome):
                summary = valid_summary()
                summary["run"].update(tier="strict", job="nightly-strict", shard="partial")
                summary["status"] = "failed"
                summary["population"].update(declared=identities, compiled=identities[:5], observed=[
                    *[ci_summary.observation(identity, "passed", 1) for identity in identities[:5]],
                    ci_summary.observation(identities[5], outcome, 2 if executed == 6 else 0,
                        reason="original result", exit_code=124 if outcome == "failed" else None)])
                original = copy.deepcopy(summary)
                accepted = validate_shard(summary, summary["identity"], summary["run"], summary["hashes"], identities)
                result = aggregate_nightly(identities, [accepted], live_in_scope=False)
                self.assertEqual(result["status"], "failed")
                expected_outcome = "not-run" if outcome == "not-run" else "failed"
                self.assertEqual([entry["outcome"] for entry in result["observed"]], ["passed"] * 5 + [expected_outcome])
                self.assertEqual(result["observed"][:5], original["population"]["observed"][:5])
                failed = result["observed"][5]
                if outcome == "not-run":
                    self.assertEqual(failed, original["population"]["observed"][5])
                else:
                    self.assertIn("declared-not-compiled", failed["attempts"][-1]["reason"])
                self.assertEqual(failed["duration_seconds"], original["population"]["observed"][5]["duration_seconds"])
                self.assertEqual(failed["attempts"][-1]["exit_code"], original["population"]["observed"][5]["attempts"][-1]["exit_code"])
                ci_summary.validate_observation(failed)
                self.assertEqual(result["matrix"]["executed"], executed)
                self.assertEqual(result["matrix"]["equal"], executed == 6)
                self.assertEqual(summary, original)

    def test_manifest_rejects_unknown_missing_and_duplicate_cases(self):
        from ci_nightly import parse_manifest
        raw = json.loads((Path(__file__).parent / "nightly-matrix.json").read_text())
        parse_manifest(raw)
        for mutation in (lambda x: x["cases"].pop(), lambda x: x["cases"].append(x["cases"][0]),
                         lambda x: x["cases"][0].update(suite="unknown"),
                         lambda x: x.update(schema_version=99)):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(raw)
                mutation(changed)
                with self.assertRaises(ci_summary.ContractError):
                    parse_manifest(changed)

    def test_nightly_early_boot_records_failures_without_waiting_for_readiness(self):
        import contextlib
        import io
        import os
        import subprocess
        import tempfile
        import yaml
        import strict_e2e_runner_support as support
        from strict_e2e_runner_support import SIMULATOR_COMMAND_TIMEOUT_SECONDS
        from ci_failure_diagnostics import preparation_first_failure
        job = yaml.safe_load((Path(__file__).parent.parent / ".github/workflows/ci-nightly.yml").read_text())["jobs"]["strict"]
        step = next(step for step in job["steps"] if step.get("id") == "simulator")
        source = step["run"].split("<<'PY'\n", 1)[1].rsplit("PY", 1)[0]
        for state in ("ready", "nonzero", "timeout"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as raw:
                calls, clock = [], [0.0]
                def run(command, **kwargs):
                    calls.append(command)
                    self.assertEqual(["xcrun", "simctl", "boot", "TEST"], command)
                    self.assertEqual(support.SIMULATOR_COMMAND_TIMEOUT_SECONDS, kwargs["timeout"])
                    if state == "timeout":
                        clock[0] += kwargs["timeout"]
                        raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                    return subprocess.CompletedProcess(command, int(state == "nonzero"), "", "")
                with patch.dict(os.environ, {"RUNNER_TEMP": raw, "NIGHTLY_SIMULATOR": "TEST"}), \
                        patch.object(support.subprocess, "run", side_effect=run), \
                        patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                        patch("ci_execution_diagnostics.system_sample", return_value=None), contextlib.redirect_stdout(io.StringIO()):
                    if state == "ready":
                        exec(source, {})
                    else:
                        with self.assertRaisesRegex(support.CommandError, "^Early simulator boot failed \\(exit 1\\)\\.$"
                                if state == "nonzero" else f"^simulator-boot timed out after {SIMULATOR_COMMAND_TIMEOUT_SECONDS:.1f}s\\.$"):
                            exec(source, {})
                self.assertEqual(1, len(calls), "early boot must not retry or run readiness")
                ledger = json.loads(Path(raw, "preparation-diagnostics.json").read_text())["receipt"]
                if state == "timeout":
                    receipt = preparation_first_failure(ledger)
                    self.assertEqual(("simulator-boot", SIMULATOR_COMMAND_TIMEOUT_SECONDS),
                                     (receipt["step"], receipt["timing"]["wait_elapsed_seconds"]))
                else:
                    self.assertEqual(["started", "completed"] if state == "ready" else ["started"],
                                     [event["state"] for event in ledger["events"]])

    def test_workflow_budgets_cover_preparation_execution_and_diagnostic_margin(self):
        from ci_ui_tests import ARCHIVE_GATE_SECONDS
        import yaml
        import shlex
        from ci_nightly import shards
        from strict_e2e_build import build_settings
        from strict_e2e_runner_support import (FILTER_PERSON_SESSIONS, SIMULATOR_READINESS_TIMEOUT_SECONDS,
                                             SIMULATOR_PREPARATION_TIMEOUT_SECONDS)
        raw = json.loads((Path(__file__).parent / "nightly-matrix.json").read_text())
        root = Path(__file__).parent.parent
        tracer = json.loads((root / "scripts/strict-tracer.json").read_text())
        for filename, job_name, groups, margin_minutes in (
                ("ci-nightly.yml", "strict", shards(raw), 7),
                ("ci-strict-tracer.yml", "tracer", [
                    {"cases": [case for case in tracer["cases"] if case["platform"] == platform]}
                    for platform in ("ios", "tvos")], 20)):
            job = yaml.safe_load((root / ".github/workflows" / filename).read_text())["jobs"][job_name]
            steps = job["steps"]
            setup = next(i for i, step in enumerate(steps) if "setup_ci_python.py" in step.get("run", ""))
            consumer = next(i for i, step in enumerate(steps) if "scripts/run_strict_ci_tracer.py" in step.get("run", ""))
            preparation = (consumer if filename == "ci-nightly.yml" else
                           next(i for i, step in enumerate(steps) if "prepare_simulator(" in step.get("run", "")))
            accounting = next(i for i, step in enumerate(steps) if "--preparation-failed" in step.get("run", ""))
            upload = next(i for i, step in enumerate(steps) if "actions/upload-artifact@" in step.get("uses", "")
                          and "/records" in step.get("with", {}).get("path", ""))
            creation = next(i for i, step in enumerate(steps) if "simctl create" in step.get("run", ""))
            self.assertLess(setup, creation if filename == "ci-nightly.yml" else preparation)
            self.assertLess(creation if filename == "ci-nightly.yml" else preparation, consumer)
            self.assertLess(consumer, accounting)
            self.assertLess(accounting, upload)
            self.assertEqual("simulator", steps[creation].get("id"))
            if filename == "ci-nightly.yml":
                from run_strict_ci_tracer import SIMULATOR_PREPARATION_HARD_TIMEOUT_SECONDS
                self.assertEqual(SIMULATOR_PREPARATION_TIMEOUT_SECONDS + 180, SIMULATOR_PREPARATION_HARD_TIMEOUT_SECONDS)
                self.assertIn("--simulator-boot-submitted", shlex.split(steps[consumer]["run"]),
                              "nightly must gate the early boot after the cold build")
                self.assertIn('"simctl", "boot"', steps[creation]["run"])
            else:
                self.assertEqual("preparation", steps[preparation].get("id"))
                self.assertGreaterEqual(steps[preparation]["timeout-minutes"] * 60,
                                        SIMULATOR_PREPARATION_TIMEOUT_SECONDS + 180)
            self.assertEqual("always() && steps.simulator.outcome == 'failure'" if filename == "ci-nightly.yml" else
                             "always() && (steps.simulator.outcome == 'failure' || steps.preparation.outcome == 'failure')",
                             steps[accounting]["if"])
            accounting_args = shlex.split(steps[accounting]["run"])
            output_dir = accounting_args[accounting_args.index("--output-dir") + 1]
            uploaded = steps[upload]["with"]["path"].strip().replace("${{ runner.temp }}", "$RUNNER_TEMP")
            self.assertEqual(output_dir + "/records", uploaded)
            command = next(step["run"] for step in job["steps"]
                           if "scripts/run_strict_ci_tracer.py" in step.get("run", ""))
            cold = int(re.search(r"--cold-timeout-seconds\s+(\d+)", command)[1])
            warm = int(re.search(r"--warm-timeout-seconds\s+(\d+)", command)[1])
            for group in groups:
                cases = group["cases"]
                builds = {build_settings(case["platform"], case["suite"], case["configuration"])[::2]
                          for case in cases}
                budget = (cold + 240) * len(builds) + sum(
                    (warm + SIMULATOR_READINESS_TIMEOUT_SECONDS)
                    * (len(FILTER_PERSON_SESSIONS) if case["suite"] == "filter-person" else 1) + 240
                    for case in cases)
                if filename == "ci-nightly.yml":
                    budget += SIMULATOR_PREPARATION_TIMEOUT_SECONDS
                with self.subTest(workflow=filename, cases=cases):
                    self.assertGreaterEqual(job["timeout-minutes"] * 60, budget + margin_minutes * 60)
        for filename in ("ci-ui.yml", "ci-nightly.yml"):
            jobs = yaml.safe_load((root / ".github/workflows" / filename).read_text())["jobs"]
            for name, job in jobs.items():
                commands = [step["run"] for step in job["steps"]
                            if "scripts/ci_ui_tests.py run " in step.get("run", "")]
                for command in commands:
                    shard_minutes = int(re.search(r"--total-timeout-minutes\s+(\d+)", command)[1])
                    with self.subTest(workflow=filename, job=name):
                        self.assertGreaterEqual(job["timeout-minutes"] * 60,
                                                shard_minutes * 60 + SIMULATOR_PREPARATION_TIMEOUT_SECONDS + 13 * 60
                                                + (ARCHIVE_GATE_SECONDS if filename == "ci-nightly.yml" else 0))


def policy():
    return {"schema_version": 1, "approval_records": [approval_record("host")], "expected_skips": [], "deselections": []}


def approval_record(tier):
    return {"approver": "maintainer example", "date": "2026-10-08", "tier": tier,
            "link": "https://github.com/example/project/issues/1#issuecomment-1"}


def expected_population(identities, tree_sha):
    return {"tree_sha": tree_sha, "identities": identities}


class PopulationVerdictTests(unittest.TestCase):
    def test_flaky_pass_requires_exact_trusted_registry_and_preserved_two_attempts(self):
        from datetime import date
        from test_ci_flaky import registry
        from ci_flaky import merge_retry
        base = registry()
        identity = base["entries"][0]["identity"]
        summary = valid_summary()
        summary["run"]["tier"] = "ui"
        summary["population"]["declared"] = summary["population"]["compiled"] = [identity]
        summary["population"]["observed"] = [merge_retry(ci_summary.observation(identity, "failed", 1,
                                                        reason="Official XCTest assertion failure", exit_code=65),
                                                        ci_summary.observation(identity, "passed", 2))]
        args = {"environment": "hermetic", "base_registry": base, "evaluated_on": date(2026, 10, 8)}
        self.assertEqual(evaluate_population(summary, [identity], policy(), **args)["status"], "passed")
        for override in ({"base_registry": None}, {"base_registry": dict(base, entries=[])},
                         {"evaluated_on": date(2026, 11, 8)}, {"evaluated_on": None}, {"environment": "live"}):
            with self.subTest(override=override):
                self.assertEqual(evaluate_population(summary, [identity], policy(), **(args | override))["status"], "failed")
        summary["run"]["tier"] = "host"
        self.assertEqual(evaluate_population(summary, [identity], policy(), **args)["status"], "failed")
        summary["run"]["tier"] = "ui"
        summary["population"]["observed"][0]["attempts"][0]["reason"] = "Unclassified failure"
        self.assertEqual(evaluate_population(summary, [identity], policy(), **args)["status"], "failed")

    def setUp(self):
        self.summary = valid_summary()
        self.expected = self.summary["population"]["declared"]
        self.policy = policy()

    def verdict(self):
        return evaluate_population(self.summary, self.expected, self.policy, environment="hermetic")

    def test_declared_compiled_and_executed_must_account_for_every_identity(self):
        self.assertEqual(self.verdict()["status"], "passed")
        for collection in ("declared", "compiled", "observed"):
            with self.subTest(collection=collection):
                original = self.summary["population"][collection]
                self.summary["population"][collection] = []
                self.assertEqual(self.verdict()["status"], "failed")
                self.summary["population"][collection] = original

    def test_expected_skip_requires_exact_reason_tier_environment_and_no_execution(self):
        identity = self.expected[0]
        self.policy["expected_skips"] = [{"kind": "host", "key_pattern": "format", "dimensions": {},
                                          "tier": "host", "environment": "hermetic", "reason": "no fixture"}]
        self.summary["status"] = "unverified"
        self.summary["population"]["observed"] = [ci_summary.observation(identity, "skipped", 0, reason="no fixture")]
        self.assertEqual(self.verdict()["status"], "passed")
        self.assertEqual(self.verdict()["expected_skips"], [identity])
        for field, value in (("reason", "different"), ("tier", "nightly"), ("environment", "live")):
            with self.subTest(field=field):
                original = self.policy["expected_skips"][0][field]
                self.policy["expected_skips"][0][field] = value
                self.assertEqual(self.verdict()["status"], "failed")
                self.policy["expected_skips"][0][field] = original
        self.summary["population"]["observed"] = [ci_summary.observation(identity, "passed", 0)]
        self.assertEqual(self.verdict()["status"], "failed")
        for tier, environment, test in (("unit", "hermetic", ci_summary.test_identity("swift", "Tests/skipped()", platform="ios")),
                                        ("ui", "fixture", ci_summary.test_identity("ui", "Tests/testSkipped", platform="ios", device="iphone"))):
            self.summary["run"]["tier"] = tier
            self.expected = self.summary["population"]["declared"] = self.summary["population"]["compiled"] = [test]
            self.summary["population"]["observed"] = [ci_summary.observation(test, "skipped", 0, reason="no fixture")]
            self.policy["expected_skips"] = [{"kind": test["kind"], "key_pattern": test["key"], "dimensions": test["dimensions"],
                                              "tier": tier, "environment": environment, "reason": "no fixture"}]
            for records, status in (([approval_record("host"), approval_record(tier)], "passed"),
                                    ([approval_record("host")], "failed")):
                with self.subTest(tier=tier, approval_tiers=[record["tier"] for record in records]):
                    self.policy["approval_records"] = records
                    verdict = evaluate_population(self.summary, self.expected, self.policy, environment=environment)
                    self.assertEqual(verdict["status"], status)
                    self.assertEqual(verdict["expected_skips"], [test] if status == "passed" else [])

    def test_deselections_require_compilation_reason_owner_and_exclusive_accounting(self):
        entry = {"identity": self.expected[0], "tier": "host", "environment": "hermetic",
                 "reason": "live only", "owning_tier": "nightly-live"}
        self.policy["deselections"] = [entry]
        self.summary["population"]["observed"] = []
        self.summary["population"]["deselected"] = [{k: v for k, v in entry.items() if k not in {"tier", "environment"}}]
        self.assertEqual(self.verdict()["status"], "passed")
        for field in ("reason", "owning_tier"):
            with self.subTest(field=field):
                self.summary["population"]["deselected"][0][field] = "wrong"
                self.assertEqual(self.verdict()["status"], "failed")
                self.summary["population"]["deselected"][0][field] = entry[field]
        self.summary["population"]["compiled"] = []
        self.assertEqual(self.verdict()["status"], "failed")
        self.summary["population"]["compiled"] = self.expected
        self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], "passed", 0)]
        self.assertEqual(self.verdict()["status"], "failed")

    def test_parameter_rows_do_not_hide_missing_compiled_parameters(self):
        function = ci_summary.test_identity("swift", "Tests/works", platform="ios")
        parameters = [ci_summary.test_identity("swift", "Tests/works", platform="ios", parameter=p) for p in ("a", "b")]
        self.expected = [function]
        self.summary["population"]["declared"] = [function]
        self.summary["population"]["compiled"] = parameters
        self.summary["population"]["observed"] = [ci_summary.observation(p, "passed", 0) for p in parameters]
        self.assertEqual(self.verdict()["status"], "passed")
        self.summary["population"]["observed"].pop()
        self.assertEqual(self.verdict()["status"], "failed")
        # Xcode enumerates functions and exports their individual arguments separately.
        compiled = ci_summary.test_identity("swift", "immichSlidesTests/Tests/`works`(value:)", platform="ios")
        parameters = [dict(compiled, dimensions={"platform": "ios", "parameter": p}) for p in ("a", "b")]
        self.summary["population"]["compiled"] = [compiled]
        rows = [ci_summary.observation(p, "passed", 0) for p in [compiled, *parameters]]
        self.summary["population"]["observed"] = rows
        self.assertEqual(self.verdict()["status"], "passed")
        for case in ("failed argument", "duplicate argument", "unknown parent", "no function result"):
            with self.subTest(case=case):
                changed = copy.deepcopy(rows)
                if case == "failed argument":
                    changed[1] = ci_summary.observation(parameters[0], "failed", 0, message="Expectation failed")
                elif case == "duplicate argument":
                    changed.append(copy.deepcopy(changed[1]))
                elif case == "unknown parent":
                    changed[1]["identity"]["key"] = "immichSlidesTests/Other/`works`(value:)"
                else:
                    changed.pop(0)
                self.summary["population"]["observed"] = changed
                self.assertEqual(self.verdict()["status"], "failed")

    def test_failures_infrastructure_partial_results_and_unregistered_retries_stay_red(self):
        for outcome in ("failed", "crashed", "timed-out", "not-run", "needs-human-review", "skipped"):
            with self.subTest(outcome=outcome):
                self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], outcome, 0, reason="unexpected")]
                self.assertEqual(self.verdict()["status"], "failed")
        self.summary = valid_summary()
        self.summary["status"] = "unverified"
        self.assertEqual(self.verdict()["status"], "failed")
        self.summary["status"] = "passed"
        self.summary["infrastructure"] = [{"code": "cancelled", "message": "job cancelled"}]
        self.assertEqual(self.verdict()["status"], "failed")
        self.summary = valid_summary()
        entry = self.summary["population"]["observed"][0]
        entry["outcome"] = "flaky-passed"
        entry["duration_seconds"] = 0.2
        entry["attempts"][0].update(outcome="failed", exit_code=1)
        entry["attempts"].append(dict(entry["attempts"][0], number=2, outcome="passed", exit_code=0))
        self.assertEqual(self.verdict()["status"], "failed")

    def test_proposed_or_ambiguous_policy_cannot_authorize_an_exception(self):
        self.policy["approval_records"] = []
        self.assertEqual(self.verdict()["status"], "passed")
        self.policy["expected_skips"] = [{"kind": "host", "key_pattern": "format", "dimensions": {},
                                          "tier": "host", "environment": "hermetic", "reason": "missing"}]
        self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], "skipped", 0, reason="missing")]
        self.assertEqual(self.verdict()["status"], "failed")
        self.policy = policy()
        rule = {"kind": "host", "key_pattern": "*", "dimensions": {}, "tier": "host",
                "environment": "hermetic", "reason": "missing"}
        self.policy["proposed"] = {"expected_skips": [rule], "deselections": []}
        self.assertEqual(parse_policy(self.policy)["proposed"], self.policy["proposed"])
        self.assertEqual(self.verdict()["status"], "failed")
        self.assertEqual(self.verdict()["errors"], ["skipped: format"])
        self.policy["expected_skips"] = [rule, dict(rule, key_pattern="format")]
        self.assertEqual(self.verdict()["status"], "failed")

    def test_proposed_section_is_validated_but_never_authorizes_deselections(self):
        entry = {"identity": self.expected[0], "tier": "host", "environment": "hermetic",
                 "reason": "fixture mismatch", "owning_tier": "nightly-live"}
        self.policy["proposed"] = {"expected_skips": [], "deselections": [entry]}
        self.assertEqual(parse_policy(self.policy), self.policy)
        self.assertEqual(self.verdict()["status"], "passed")
        self.summary["population"]["observed"] = []
        self.summary["population"]["deselected"] = [
            {key: value for key, value in entry.items() if key not in {"tier", "environment"}}]
        self.assertEqual(self.verdict()["status"], "failed")
        for proposed in ({"deselections": []}, {"expected_skips": [], "deselections": [dict(entry, owning_tier="host")]},
                         {"expected_skips": [], "deselections": [entry, entry]},
                         {"expected_skips": [], "deselections": [], "approval_state": "approved"}):
            with self.subTest(proposed=proposed), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(self.policy, proposed=proposed))

    def test_malformed_policy_versions_duplicate_rules_and_owner_are_rejected(self):
        record = {"approver": "maintainer example", "date": "2026-10-08", "tier": "host",
                  "link": "https://github.com/example/project/issues/1#issuecomment-1"}
        recorded = dict(policy(), approval_records=[record])
        self.assertEqual(parse_policy(recorded), recorded)
        for field, value in (("approver", ""), ("date", "2026-02-30"), ("date", "20261008"),
                             ("tier", ""), ("link", "http://github.com/example/project/issues/1#issuecomment-1"),
                             ("link", "https://example.com/approval"), ("unknown", "value")):
            with self.subTest(approval_field=field, value=value), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(recorded, approval_records=[dict(record, **{field: value})]))
        for malformed in (None, [], {}, {key: value for key, value in record.items() if key != "tier"}):
            with self.subTest(approval_record=malformed), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(recorded, approval_records=[malformed]))
        for records in (None, {}, [record, record]):
            with self.subTest(approval_records=records), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(recorded, approval_records=records))
        for version in (2, True, "1", None):
            with self.subTest(version=version), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(policy(), schema_version=version))
        rule = {"kind": "host", "key_pattern": "format", "dimensions": {}, "tier": "host",
                "environment": "hermetic", "reason": "no fixture"}
        for entries in ([rule, rule], [dict(rule, reason="")], [dict(rule, dimensions={"unknown": "x"})]):
            with self.subTest(entries=entries), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(policy(), expected_skips=entries))
        with self.assertRaises(ci_summary.ContractError):
            parse_policy(dict(policy(), deselections=[{"identity": self.expected[0], "tier": "host",
                         "environment": "hermetic", "reason": "elsewhere", "owning_tier": "host"}]))


class AdmissionVerdictTests(unittest.TestCase):
    def test_gate_classification_failure_keeps_macos_enabled_and_writes_failed_evidence(self):
        from ci_gate import main
        identity = {"schema_version": 1, "event": "pull_request", "repository": "example/photos",
                    "tree_sha": "d" * 40, "base_sha": "a" * 40, "head_sha": "b" * 40,
                    "merge_sha": "c" * 40, "pull_request": 7}
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            records = Path(directory) / "records"
            outputs = Path(directory) / "outputs"
            with patch("sys.argv", ["ci_gate.py", "classify", "--output-dir", str(records)]), \
                    patch.dict("os.environ", {"GITHUB_OUTPUT": str(outputs), "GITHUB_RUN_ID": "101", "GITHUB_RUN_ATTEMPT": "1"}), \
                    patch("ci_gate.run_identity", return_value=identity), \
                    patch("ci_gate.source_metadata", return_value=(".github/workflows/ci-gate.yml", False)), \
                    patch("ci_gate.read_blob", return_value='{"schema_version":1}'), \
                    patch("ci_gate.classify", side_effect=ci_summary.ContractError("unavailable base")):
                self.assertEqual(main(), 1)
            self.assertEqual(outputs.read_text(), "run_macos=true\n")
            summary = ci_summary.parse_summary((records / "summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertEqual(summary["identity"], identity)
            self.assertEqual(summary["infrastructure"][0]["code"], "classification-failed")

    def test_gate_scheduler_binds_the_base_reader_and_policy_and_both_target_trees(self):
        from ci_gate import classify
        from ci_publish_git import BASE_MODULES, OPTIONAL_BASE_MODULES
        modules = {name: Path(__file__).with_name(name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
        allowlist = Path(__file__).with_name("ci-classification.json").read_text()
        identity = {"event": "pull_request", "base_sha": "a" * 40, "head_sha": "b" * 40,
                    "merge_sha": "c" * 40}
        def repository_input(*args):
            if args[0] == "diff":
                return paths
            if args[-1] == identity["base_sha"]:
                return "immichSlides/base-only.swift\ndocs/base.md"
            return "immichSlides/merge-only.swift\ndocs/merge.md"

        for paths in ("docs/note.md", ""):
            with self.subTest(paths=paths), patch("ci_gate.revision_modules", return_value=modules) as reader, \
                    patch("ci_gate.read_blob", return_value=allowlist) as policy, \
                    patch("ci_gate.git", side_effect=repository_input) as diff, \
                    patch("ci_gate.base_reader", return_value={"app_affected": True, "ci_changing": False}) as evaluate:
                self.assertEqual(classify(identity), evaluate.return_value)
                reader.assert_called_once_with(identity["base_sha"])
                policy.assert_called_once_with(identity["base_sha"], "scripts/ci-classification.json")
                diff.assert_any_call("diff", "--name-only", "--no-renames",
                                     identity["base_sha"] + "..." + identity["head_sha"])
                diff.assert_any_call("ls-tree", "--name-only", "-r", identity["base_sha"])
                diff.assert_any_call("ls-tree", "--name-only", "-r", identity["merge_sha"])
                evaluate.assert_called_once_with(modules, {
                    "operation": "classify", "paths": [paths] if paths else ["__unknown_empty_diff__"],
                    "classification_policy": json.loads(allowlist),
                    "build_target_paths": ["immichSlides/base-only.swift", "immichSlides/merge-only.swift"]})
        with patch("ci_gate.git") as diff:
            self.assertTrue(classify({"event": "push"})["app_affected"])
            diff.assert_not_called()

    def test_nightly_change_check_skips_only_a_proven_unchanged_or_non_affecting_main(self):
        import ci_nightly_change as change
        head, old, older = "c" * 40, "b" * 40, "a" * 40
        def run(number, sha, created, conclusion="success", event="schedule", branch="main", repository="example/photos", status="completed"):
            return {"id": number, "event": event, "head_branch": branch, "status": status, "conclusion": conclusion, "run_attempt": 1,
                    "head_repository": {"full_name": repository}, "created_at": created, "head_sha": sha}
        verdicts = {1: "real", 2: "real", 3: "skipped", 4: "real", 5: None}
        ignored = [dict(run(20, head, "2026-10-04T21:15:00Z", event="workflow_dispatch"), display_title="ci-nightly diagnostic"),
                   run(21, head, "2026-10-04T21:16:00Z", branch="topic"), run(22, head, "2026-10-04T21:17:00Z", repository="other/photos")]
        calls = []
        def classify(baseline, source):
            calls.append((baseline, source))
            return affecting
        def decide(runs, **changes):
            options = {"event": "schedule", "head_sha": head, "runs": runs + ignored, "repository": "example/photos",
                       "current_run_id": 10, "is_ancestor": lambda *args: True, "classify": classify,
                       "evidence": lambda item: verdicts[item["id"]]}
            return change.decide(**{**options, **changes})
        def outcome(result):
            return result["decision"], result["reason"]
        affecting = {"app_affected": False, "ci_changing": False, "affected_paths": [], "ci_paths": [], "paths": 2}
        real_older, real_old = run(1, older, "2026-10-01T21:15:00Z"), run(2, old, "2026-10-02T21:15:00Z")
        self.assertEqual(("skip", "unchanged"), outcome(decide([real_older, run(4, head, "2026-10-04T21:15:00Z")])))
        self.assertEqual([], calls)
        self.assertEqual(("run", "no-baseline"), outcome(decide([])))
        self.assertEqual(("run", "event-not-schedule"), outcome(decide([real_old], event="workflow_dispatch")))
        self.assertEqual(("run", "event-not-schedule"), outcome(decide([real_old], event="pull_request")))
        # A skipped night is passed over to the real night behind it, so skips chain without moving the baseline.
        skipped = decide([real_older, real_old, run(3, head, "2026-10-03T21:15:00Z")], current_run_id=10)
        self.assertEqual(("skip", "non-affecting-changes"), outcome(skipped))
        self.assertEqual({"run_id": 2, "sha": old, "created_at": "2026-10-02T21:15:00Z"}, skipped["baseline"])
        self.assertEqual([(old, head)], calls)
        # A completed night that failed with a real result is a baseline.
        failed = decide([real_older, real_old, run(4, older, "2026-10-03T21:30:00Z", "failure")])
        self.assertEqual((4, older), (failed["baseline"]["run_id"], failed["baseline"]["sha"]))
        # The newest night that is cancelled, unfinished, unverifiable or concluded another way ends the search: run.
        for label, newest in (("cancelled", run(4, head, "2026-10-05T21:15:00Z", "cancelled")),
                              ("timed out", run(4, head, "2026-10-05T21:15:00Z", "timed_out")),
                              ("unfinished older commit", run(4, old, "2026-10-05T21:15:00Z", None, status="in_progress")),
                              ("unverified", run(5, head, "2026-10-05T21:15:00Z", "failure"))):
            with self.subTest(newest=label):
                self.assertEqual(("run", "no-baseline"), outcome(decide([real_older, real_old, newest])))
        self.assertEqual(("run", "baseline-not-ancestor"), outcome(decide([real_older, real_old], is_ancestor=lambda *args: False)))
        for flag in ("app_affected", "ci_changing"):
            with self.subTest(flag=flag):
                affecting = {**affecting, flag: True, "affected_paths": ["immichSlides/App.swift"], "ci_paths": [], "paths": 3}
                result = decide([real_older, real_old])
                self.assertEqual(("run", "changes-affect-app-or-ci"), outcome(result))
                self.assertEqual(["immichSlides/App.swift"], result["changes"]["affected"])
        # The current run is never its own baseline, so a rerun cannot skip itself.
        self.assertEqual(("run", "no-baseline"), outcome(decide([run(10, old, "2026-10-02T21:15:00Z")])))

        class Api:
            repository = "example/photos"
            def __init__(self, artifacts):
                self.artifacts = artifacts
            def pages(self, path, collection):
                return self.artifacts
        def artifact(name, expired=False):
            return {"name": name, "expired": expired}
        night = run(7, old, "2026-10-02T21:15:00Z", "failure")
        aggregate = {"schema_version": 1, "run": {"id": "7", "attempt": 1}, "status": "failed", "identity": {"commit_sha": old},
                     "matrix": {"equal": True}, "errors": []}
        skip_record = {"schema_version": 1, "decision": "skip", "reason": "unchanged", "event": "schedule",
                       "repository": "example/photos", "head_sha": old, "run": {"id": "7", "attempt": 1},
                       "baseline": {"run_id": 2, "sha": old, "created_at": "2026-10-01T21:15:00Z"}}
        def evidence(item, artifacts, member):
            with patch("ci_publish.json_member", return_value=member):
                return change.run_evidence(Api(artifacts), item)
        shard, aggregate_artifact = artifact("nightly-strict-a-7-1"), artifact("nightly-aggregate-7-1")
        self.assertEqual("real", evidence(night, [aggregate_artifact, shard], aggregate))
        self.assertEqual("real", evidence(dict(night, conclusion="success"), [aggregate_artifact], {**aggregate, "status": "passed"}))
        self.assertIsNone(evidence(dict(night, conclusion="success"), [aggregate_artifact],
            {**aggregate, "status": "environment-limited"}))
        self.assertIsNone(evidence(night, [aggregate_artifact], {**aggregate, "environment_limited": [{"key": "yellow"}]}))
        for label, artifacts, member, item in (
                ("no aggregate", [shard], aggregate, night),
                ("expired aggregate", [artifact("nightly-aggregate-7-1", True)], aggregate, night),
                ("other attempt", [artifact("nightly-aggregate-7-2")], aggregate, night),
                ("cancelled", [aggregate_artifact], aggregate, dict(night, conclusion="cancelled")),
                ("wrong commit", [aggregate_artifact], {**aggregate, "identity": {"commit_sha": head}}, night),
                ("wrong run", [aggregate_artifact], {**aggregate, "run": {"id": "8", "attempt": 1}}, night),
                ("matrix incomplete", [aggregate_artifact], {**aggregate, "matrix": {"equal": False}}, night),
                ("diagnostic manual", [aggregate_artifact], {**aggregate, "diagnostic_shard": "strict-only"},
                 dict(night, event="workflow_dispatch")),
                ("infrastructure error", [aggregate_artifact], {**aggregate, "errors": ["missing shard ui-a"]}, night),
                ("UI aggregate absent", [aggregate_artifact], {**aggregate, "schema_version": 2}, night),
                ("UI record unreadable", [aggregate_artifact], {**aggregate, "schema_version": 2, "ui": {}}, night)):
            with self.subTest(evidence=label):
                self.assertIsNone(evidence(item, artifacts, member))
        record_artifact = artifact("nightly-change-7-1")
        skipped_night = dict(night, conclusion="success")
        self.assertEqual("skipped", evidence(skipped_night, [record_artifact], skip_record))
        self.assertIsNone(evidence(skipped_night, [artifact("nightly-change-7-1", True)], skip_record))
        self.assertIsNone(evidence(skipped_night, [record_artifact, aggregate_artifact], skip_record))
        self.assertIsNone(evidence(dict(skipped_night, conclusion="failure"), [record_artifact], skip_record))
        with self.assertRaises(ci_summary.ContractError):
            evidence(skipped_night, [record_artifact], {**skip_record, "head_sha": head})

    def test_nightly_backup_uses_only_full_main_runs_for_the_same_commit(self):
        import ci_nightly_change as change
        head, old = "c" * 40, "b" * 40
        primary = {"id": 9, "event": "schedule", "head_branch": "main", "status": "in_progress", "conclusion": None,
                   "run_attempt": 1, "head_repository": {"full_name": "example/photos"}, "head_sha": head,
                   "created_at": "2026-10-13T14:00:00Z"}
        def decide(run, verdict=None):
            return change.decide(event="schedule", head_sha=head, runs=[run], repository="example/photos", current_run_id=10,
                                 is_ancestor=lambda *args: True,
                                 classify=lambda *args: {"app_affected": True, "ci_changing": False, "paths": 1,
                                                         "affected_paths": ["immichSlides/App.swift"], "ci_paths": []},
                                 evidence=lambda item: verdict)
        for status in ("queued", "in_progress", "waiting", "pending", "requested"):
            with self.subTest(status=status):
                result = decide({**primary, "status": status})
                self.assertEqual(("skip", "unchanged"), (result["decision"], result["reason"]))
                record = change.make_record(result, event="schedule", repository="example/photos", head_sha=head, run_id=10, attempt=1)
                change.validate_record(record, repository="example/photos", head_sha=head, run_id=10, attempt=1, event="schedule")
                self.assertEqual(9, record["baseline"]["run_id"])
        for conclusion in ("success", "failure"):
            with self.subTest(conclusion=conclusion):
                self.assertEqual("skip", decide({**primary, "status": "completed", "conclusion": conclusion}, "real")["decision"])
        for conclusion in ("cancelled", "timed_out", "failure", "success"):
            with self.subTest(no_result=conclusion):
                self.assertEqual("run", decide({**primary, "status": "completed", "conclusion": conclusion})["decision"])
        for status in ("in_progress", "completed"):
            with self.subTest(new_commit=status):
                self.assertEqual("run", decide({**primary, "head_sha": old, "status": status, "conclusion": "success"}, "real")["decision"])
        for changes in ({"event": "pull_request"}, {"head_branch": "topic"}, {"id": 10}, {"id": 11}, {"conclusion": "cancelled"},
                        {"head_repository": {"full_name": "other/photos"}}, {"status": "unknown"}):
            with self.subTest(untrusted=changes):
                self.assertEqual("run", decide({**primary, **changes})["decision"])
        manual = {**primary, "event": "workflow_dispatch", "display_title": "ci-nightly full"}
        self.assertEqual("skip", decide(manual)["decision"])
        self.assertEqual("skip", decide({**manual, "status": "queued"})["decision"])
        self.assertEqual("skip", decide({**manual, "status": "completed", "conclusion": "success"}, "real")["decision"])
        self.assertEqual("run", decide({**manual, "status": "completed", "conclusion": "failure"})["decision"])
        self.assertEqual("run", decide({**manual, "status": "completed", "conclusion": "cancelled"})["decision"])
        self.assertEqual("run", decide({**manual, "head_sha": old, "status": "completed", "conclusion": "success"}, "real")["decision"])
        # A later interrupted full dispatch cannot erase coverage already owned by the primary.
        interrupted = {**manual, "id": 11, "created_at": "2026-10-13T18:00:00Z", "status": "completed", "conclusion": "cancelled"}
        for status in ("in_progress", "completed"):
            with self.subTest(covered_primary=status):
                result = change.decide(event="schedule", head_sha=head,
                                       runs=[{**primary, "status": status, "conclusion": "success" if status == "completed" else None}, interrupted],
                                       repository="example/photos", current_run_id=12, is_ancestor=lambda *args: True,
                                       classify=lambda *args: self.fail("covered primary must not classify changes"),
                                       evidence=lambda item: "real" if item["id"] == 9 else None)
                self.assertEqual("skip", result["decision"])
        # Legacy full dispatches need real evidence; an ambiguous active dispatch cannot suppress the backup.
        legacy = {**manual, "display_title": "ci-nightly"}
        self.assertEqual("run", decide(legacy)["decision"])
        self.assertEqual("skip", decide({**legacy, "status": "completed", "conclusion": "success"}, "real")["decision"])
        for status in ("queued", "in_progress", "completed"):
            with self.subTest(diagnostic=status):
                self.assertEqual("run", decide({**manual, "display_title": "ci-nightly diagnostic", "status": status,
                                               "conclusion": "success"}, "real")["decision"])

        # Both histories must reach the real decision seam; querying only schedules loses manual coverage.
        from urllib.parse import parse_qs, urlsplit
        queries = []
        class Api:
            def __init__(self, *args):
                pass
            def repo(self, path):
                query = parse_qs(urlsplit(path).query)
                queries.append(query)
                return {"workflow_runs": [manual] if query["event"] == ["workflow_dispatch"] else []}
        with patch("ci_publish.RateLimitWaitingGitHub", Api):
            runs, evidence = change.scheduled_history("example/photos", "")
            result = change.decide(event="schedule", head_sha=head, runs=runs, repository="example/photos", current_run_id=10,
                                   is_ancestor=lambda *args: self.fail("same-SHA coverage must not classify changes"),
                                   classify=lambda *args: self.fail("same-SHA coverage must not classify changes"), evidence=evidence)
        self.assertEqual("skip", result["decision"])
        self.assertEqual(["schedule", "workflow_dispatch"], [query["event"][0] for query in queries])
        self.assertTrue(all(query["branch"] == ["main"] for query in queries))

    def test_nightly_change_check_fails_open_and_records_the_decision(self):
        import ci_nightly_change as change
        head, old = "c" * 40, "b" * 40
        environment = {"GITHUB_EVENT_NAME": "schedule", "GITHUB_REPOSITORY": "example/photos", "GITHUB_SHA": head,
                       "GITHUB_RUN_ID": "10", "GITHUB_RUN_ATTEMPT": "2"}
        import tempfile
        for outcome, expected in (("unchanged", ("skip", "unchanged", "skip=true\n")), ("unavailable", ("run", "decision-unavailable", "skip=false\n"))):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                output, records = Path(directory, "output"), Path(directory, "records")
                runs = [{"id": 2, "event": "schedule", "head_branch": "main", "status": "completed", "conclusion": "success",
                         "head_repository": {"full_name": "example/photos"}, "created_at": "2026-10-02T21:15:00Z", "head_sha": head}]
                reader = (patch.object(change, "scheduled_history", return_value=(runs, lambda item: "real")) if outcome == "unchanged"
                          else patch.object(change, "scheduled_history", side_effect=OSError("network down")))
                with reader, patch.dict("os.environ", {}, clear=True):
                    self.assertEqual(0, change.main(["--output-dir", str(records)], {**environment, "GITHUB_OUTPUT": str(output)}))
                decision, reason, exported = expected
                self.assertEqual(exported, output.read_text())
                record = json.loads((records / "nightly-change.json").read_text())
                self.assertEqual((decision, reason, {"id": "10", "attempt": 2}), (record["decision"], record["reason"], record["run"]))
                self.assertNotIn("network down", (records / "nightly-change.md").read_text())
                change.validate_record(record, repository="example/photos", run_id=10, attempt=2, event="schedule", head_sha=head)
                if decision == "skip":
                    self.assertIn(change.NO_CHANGE_REASON, (records / "nightly-change.md").read_text())
        # Nothing but the diagnostic prints and nothing is written or exported in a dry run.
        with tempfile.TemporaryDirectory() as directory, patch.object(change, "scheduled_history", return_value=([], lambda item: None)), \
                patch.dict("os.environ", {"GITHUB_OUTPUT": str(Path(directory, "output"))}):
            self.assertEqual(0, change.main(["--dry-run", "--repository", "example/photos", "--head-sha", head], {}))
            self.assertFalse(Path(directory, "output").exists())
        for changes in ({"decision": "skip", "reason": "unchanged"}, {"head_sha": old}, {"run": {"id": "11", "attempt": 2}},
                        {"repository": "other/photos"}, {"event": "workflow_dispatch"}):
            with self.subTest(changes=changes), self.assertRaises(ci_summary.ContractError):
                change.validate_record({"schema_version": 1, "decision": "skip", "reason": "non-affecting-changes",
                                        "event": "schedule", "repository": "example/photos", "head_sha": head,
                                        "run": {"id": "10", "attempt": 2},
                                        "baseline": {"run_id": 2, "sha": old, "created_at": "2026-10-02T21:15:00Z"}, **changes},
                                       repository="example/photos", run_id=10, attempt=2, event="schedule", head_sha=head)

    def test_nightly_change_classification_binds_the_baseline_reader_policy_and_both_trees(self):
        import ci_nightly_change as change
        from ci_publish_git import BASE_MODULES, OPTIONAL_BASE_MODULES
        modules = {name: Path(__file__).with_name(name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
        allowlist = Path(__file__).with_name("ci-classification.json").read_text()
        baseline, head = "a" * 40, "b" * 40
        def repository_input(*args, **options):
            if args[0] == "diff":
                return "docs/note.md\0docs/other.md\0"
            return "immichSlides/base-only.swift\ndocs/base.md" if args[-1] == baseline else "immichSlides/head-only.swift"
        with patch.object(change, "revision_modules", return_value=modules) as reader, \
                patch.object(change, "read_blob", return_value=allowlist) as policy, \
                patch.object(change, "git", side_effect=repository_input) as repository, \
                patch.object(change, "base_reader", return_value={"app_affected": False, "ci_changing": False,
                                                                  "affected_paths": [], "ci_paths": []}) as evaluate:
            self.assertEqual(2, change.classify_between(baseline, head)["paths"])
            reader.assert_called_once_with(baseline)
            policy.assert_called_once_with(baseline, "scripts/ci-classification.json")
            repository.assert_any_call("diff", "-z", "--name-only", "--no-renames", baseline + ".." + head)
            evaluate.assert_called_once_with(modules, {
                "operation": "classify", "paths": ["docs/note.md", "docs/other.md"],
                "classification_policy": json.loads(allowlist),
                "build_target_paths": ["immichSlides/base-only.swift", "immichSlides/head-only.swift"]})

    def setUp(self):
        self.summary = valid_summary()
        self.identity = self.summary["identity"]
        self.jobs = [{"tier": "host", "job": "host-checks", "shard": None, "run_id": None,
                      "attempt": 1, "workflow_paths": [None], "status": "completed", "conclusion": "success",
                      "expected": expected_population(self.summary["population"]["declared"], self.identity["tree_sha"])}]
        self.expected = self.summary["population"]["declared"]

    def verdict(self, **kwargs):
        trusted = {"fork_originated": False, "ci_changing": False, "app_affected": True,
                   "allowed_events": ("pull_request", "push", "local")}
        if self.identity["event"] == "pull_request":
            trusted["base_population"] = {"base_sha": self.identity["base_sha"], "identities": self.expected}
        trusted.update(kwargs)
        expected = trusted.pop("expected", expected_population(self.expected, self.identity["tree_sha"]))
        return evaluate_gate([self.summary], expected=expected, admission_identity=self.identity,
                             required_jobs=self.jobs, base_policy=policy(), environment="hermetic", **trusted)

    def test_default_admission_rejects_local_events_and_unclassified_inputs(self):
        default = evaluate_gate([self.summary], expected=expected_population(self.expected, self.identity["tree_sha"]), admission_identity=self.identity,
                                required_jobs=self.jobs, base_policy=policy(), environment="hermetic",
                                fork_originated=False, ci_changing=False, app_affected=True)
        self.assertEqual(default["status"], "failed")
        self.assertTrue(any("event is not admitted" in error for error in default["errors"]))
        self.assertEqual(self.verdict()["status"], "passed")
        for key in ("fork_originated", "ci_changing", "app_affected"):
            with self.subTest(key=key):
                self.assertEqual(self.verdict(**{key: None})["status"], "failed")

    def test_absent_artifacts_jobs_or_mismatched_run_identity_fail_closed(self):
        self.assertEqual(self.verdict()["status"], "passed")
        missing = evaluate_gate([], expected=expected_population(self.expected, self.identity["tree_sha"]), admission_identity=self.identity,
                                required_jobs=self.jobs, base_policy=policy(), environment="hermetic",
                                fork_originated=False, ci_changing=False, app_affected=True, allowed_events=("local",))
        self.assertEqual(missing["status"], "failed")
        self.assertTrue(any("missing required job/artifact" in error for error in missing["errors"]))
        admitted_job = self.jobs[0]
        for status, conclusion in (("completed", "failure"), ("completed", "cancelled"), ("completed", "timed_out"),
                                   ("completed", "skipped"), ("in_progress", "success"), ("queued", None),
                                   (None, None)):
            with self.subTest(status=status, conclusion=conclusion):
                self.jobs[0] = dict(admitted_job, status=status, conclusion=conclusion)
                verdict = self.verdict()
                self.assertEqual(verdict["status"], "failed")
                self.assertTrue(any("required job did not complete successfully" in error for error in verdict["errors"]))
                self.assertEqual(self.verdict(context="ui", app_affected=False)["status"], "failed")
        for field in ("status", "conclusion"):
            with self.subTest(missing_job_field=field):
                self.jobs[0] = {key: value for key, value in admitted_job.items() if key != field}
                self.assertEqual(self.verdict()["status"], "failed")
        self.jobs[0] = admitted_job
        self.assertEqual(self.verdict()["status"], "passed")
        for mutate in (lambda s: s["run"].update(attempt=2),
                       lambda s: s["identity"].update(tree_sha="c" * 40),
                       lambda s: s["source"].update(workflow_path=".github/workflows/renamed.yml")):
            with self.subTest(mutate=mutate):
                self.summary = valid_summary()
                mutate(self.summary)
                self.assertEqual(self.verdict()["status"], "failed")

    def test_exact_head_approval_controls_fork_and_candidate_policy(self):
        pr = {"schema_version": 1, "event": "pull_request", "repository": "sudoHG/immichSlides",
              "tree_sha": "b" * 40, "merge_sha": "a" * 40,
              "base_sha": "c" * 40, "head_sha": "d" * 40, "pull_request": 1}
        for approved in (None, "e" * 40, "d" * 40):
            with self.subTest(approved=approved):
                base = policy()
                candidate = dict(policy(), expected_skips=[])
                chosen = select_policy(base, candidate, pr, approved)
                self.assertEqual(chosen[1], approved == pr["head_sha"])
        self.assertEqual(self.verdict(fork_originated=True)["status"], "failed")
        self.assertEqual(self.verdict(ci_changing=True)["status"], "failed")
        self.identity = pr
        self.summary["identity"] = pr
        self.summary["source"].update(event="pull_request", fork_originated=True,
                                      workflow_path=".github/workflows/ci-gate.yml")
        self.summary["run"]["id"] = "42"
        self.jobs[0].update(run_id="42", workflow_paths=[".github/workflows/ci-gate.yml"])
        self.assertEqual(self.verdict(fork_originated=True)["status"], "failed")
        self.assertEqual(self.verdict(fork_originated=True, approved_head="e" * 40)["status"], "failed")
        verdict = self.verdict(fork_originated=True, approved_head=pr["head_sha"])
        self.assertEqual(verdict["status"], "passed")
        self.assertTrue(verdict["approval_based"])
        self.assertTrue(verdict["self_reported"])
        self.summary["source"]["fork_originated"] = False
        self.assertEqual(self.verdict(ci_changing=True)["status"], "failed")
        self.assertEqual(self.verdict(ci_changing=True, approved_head=pr["head_sha"])["status"], "passed")

    def test_candidate_exception_applies_only_after_exact_head_approval(self):
        pr = {"schema_version": 1, "event": "pull_request", "repository": "sudoHG/immichSlides",
              "tree_sha": "b" * 40, "merge_sha": "a" * 40, "base_sha": "c" * 40,
              "head_sha": "d" * 40, "pull_request": 1}
        self.identity = pr
        self.summary["identity"] = pr
        self.summary["source"].update(event="pull_request", workflow_path=".github/workflows/ci-gate.yml")
        self.summary["run"]["id"] = "42"
        self.jobs[0].update(run_id="42", workflow_paths=[".github/workflows/ci-gate.yml"])
        candidate = policy()
        candidate["approval_records"] = [approval_record("host")]
        candidate["expected_skips"] = [{"kind": "host", "key_pattern": "format", "dimensions": {},
                                        "tier": "host", "environment": "hermetic", "reason": "fixture unavailable"}]
        self.summary["status"] = "unverified"
        self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], "skipped", 0, reason="fixture unavailable")]
        for head, status in ((None, "failed"), ("e" * 40, "failed"), (pr["head_sha"], "passed")):
            with self.subTest(head=head):
                self.assertEqual(self.verdict(candidate_policy=candidate, approved_head=head)["status"], status)

    def test_another_shard_cannot_cover_a_tests_absence_from_its_assigned_job(self):
        extra = ci_summary.test_identity("host", "second")
        self.expected = self.expected + [extra]
        first = self.summary
        second = copy.deepcopy(first)
        second["run"]["shard"] = "second"
        second["population"]["declared"].append(extra)
        second["population"]["compiled"].append(extra)
        second["population"]["observed"].append(ci_summary.observation(extra, "passed", 0))
        self.jobs[0]["expected"] = expected_population(self.expected, self.identity["tree_sha"])
        self.jobs.append(dict(self.jobs[0], shard="second"))
        verdict = evaluate_gate([first, second], expected=expected_population(self.expected, self.identity["tree_sha"]), admission_identity=self.identity,
                                required_jobs=self.jobs, base_policy=policy(), environment="hermetic",
                                fork_originated=False, ci_changing=False, app_affected=True, allowed_events=("local",))
        self.assertEqual(verdict["status"], "failed")
        self.assertTrue(any("missing compiled" in error for error in verdict["errors"]))

    def test_removal_report_requires_the_admitted_base_and_does_not_gate_coverage(self):
        self.identity = {"schema_version": 1, "event": "pull_request", "repository": "sudoHG/immichSlides",
                         "tree_sha": "b" * 40, "merge_sha": "a" * 40,
                         "base_sha": "c" * 40, "head_sha": "d" * 40, "pull_request": 1}
        self.summary["identity"] = self.identity
        self.summary["source"].update(event="pull_request", workflow_path=".github/workflows/ci-gate.yml")
        self.summary["run"]["id"] = "42"
        self.jobs[0].update(run_id="42", workflow_paths=[".github/workflows/ci-gate.yml"])
        old = ci_summary.test_identity("host", "removed-on-pr")
        admitted_base = {"base_sha": self.identity["base_sha"], "identities": self.expected + [old]}
        before = self.verdict(base_population=admitted_base)
        added_on_main = ci_summary.test_identity("host", "new-on-main")
        later_main = {"base_sha": "e" * 40, "identities": admitted_base["identities"] + [added_on_main]}
        rejected = self.verdict(base_population=later_main)
        self.assertEqual(rejected["status"], "failed")
        self.assertEqual(rejected["removed_by_pr"], [])
        self.assertTrue(any("admitted base SHA" in error for error in rejected["errors"]))
        later_denominator = expected_population(self.expected + [added_on_main], "f" * 40)
        for location in ("overall", "job"):
            with self.subTest(location=location):
                if location == "overall":
                    rejected = self.verdict(base_population=admitted_base, expected=later_denominator)
                else:
                    admitted_job = self.jobs[0]["expected"]
                    self.jobs[0]["expected"] = later_denominator
                    rejected = self.verdict(base_population=admitted_base)
                    self.jobs[0]["expected"] = admitted_job
                self.assertEqual(rejected["status"], "failed")
                self.assertTrue(any("admitted tree SHA" in error for error in rejected["errors"]))
        for malformed in (None, self.expected, {}, expected_population(self.expected, "invalid"),
                          expected_population(None, self.identity["tree_sha"]),
                          expected_population(self.expected * 2, self.identity["tree_sha"])):
            with self.subTest(expected=malformed):
                self.assertEqual(self.verdict(base_population=admitted_base, expected=malformed)["status"], "failed")
                admitted_job = self.jobs[0]["expected"]
                self.jobs[0]["expected"] = malformed
                self.assertEqual(self.verdict(base_population=admitted_base)["status"], "failed")
                self.jobs[0]["expected"] = admitted_job
        after = self.verdict(base_population=admitted_base)
        self.assertEqual(after["status"], before["status"])
        self.assertEqual(after["status"], "passed")
        self.assertEqual(before["removed_by_pr"], [old])
        self.assertEqual(after["removed_by_pr"], [old])
        self.assertEqual(after["errors"], before["errors"])
        self.assertEqual(self.verdict()["status"], "passed")
        self.assertEqual(self.verdict()["removed_by_pr"], [])
        for malformed in (None, admitted_base["identities"], {},
                          dict(admitted_base, base_sha="invalid"), dict(admitted_base, identities=None),
                          dict(admitted_base, identities=[old, old]), dict(admitted_base, identities=[{}])):
            with self.subTest(base_population=malformed):
                verdict = self.verdict(base_population=malformed)
                self.assertEqual(verdict["status"], "failed")
                self.assertEqual(verdict["removed_by_pr"], [])

    def test_push_requires_pushed_identity_and_manual_dispatch_is_not_gate_evidence(self):
        pushed = {"schema_version": 1, "event": "push", "repository": "sudoHG/immichSlides",
                  "tree_sha": "b" * 40, "pushed_sha": "a" * 40, "ref": "refs/heads/main"}
        self.identity = pushed
        self.summary["identity"] = pushed
        self.summary["source"].update(event="push", workflow_path=".github/workflows/ci-gate.yml")
        self.summary["run"]["id"] = "42"
        self.jobs[0].update(run_id="42", workflow_paths=[".github/workflows/ci-gate.yml"])
        self.assertEqual(self.verdict(ci_changing=True, allowed_events=("pull_request", "push"))["status"], "passed")
        dispatched = dict(pushed, event="workflow_dispatch", commit_sha=pushed["pushed_sha"])
        del dispatched["pushed_sha"]
        self.identity = dispatched
        self.summary["identity"] = dispatched
        self.summary["source"]["event"] = "workflow_dispatch"
        self.assertEqual(self.verdict(allowed_events=("pull_request", "push"))["status"], "failed")

    def test_reader_first_accepts_installed_successor_and_rejects_malformed_versions(self):
        for version in (2, 99, True, "1", None):
            with self.subTest(version=version):
                self.summary["schema_version"] = version
                self.assertEqual(self.verdict()["status"], "failed")
        def successor(payload):
            normalized = copy.deepcopy(payload)
            normalized["schema_version"] = 1
            ci_summary.validate_summary_v1(normalized)
        self.summary["schema_version"] = 2
        with patch.dict(ci_summary.SUMMARY_READERS, {2: successor}):
            self.assertEqual(self.verdict()["status"], "passed")
            self.summary["run"]["attempt"] = 0
            self.assertEqual(self.verdict()["status"], "failed")

    def test_identity_successor_requires_installed_validator_before_acceptance(self):
        self.identity = dict(self.identity, schema_version=2)
        self.summary["identity"] = self.identity
        self.assertEqual(self.verdict()["status"], "failed")

        def successor(payload):
            normalized = copy.deepcopy(payload)
            normalized["schema_version"] = 1
            ci_summary.validate_identity_v1(normalized)

        with patch.dict(ci_summary.IDENTITY_READERS, {2: successor}):
            self.assertEqual(self.verdict()["status"], "passed")
            self.identity["tree_sha"] = "invalid"
            self.assertEqual(self.verdict()["status"], "failed")

    def test_only_verified_allowlisted_nonmembers_make_ui_not_applicable(self):
        allowlist = json.loads(Path(__file__).with_name("ci-classification.json").read_text(encoding="utf-8"))
        for paths, members, app, ci in ((["docs/README.md"], set(), False, False),
                                       (["review-records/sha/p2-cache/iphone/a.json"], set(), False, False),
                                       (["docs/bundled.md"], {"docs/bundled.md"}, True, False),
                                       (["immichSlides/Resources/privacy.html"], set(), True, False),
                                       (["scripts/ci-test-policy.json"], set(), True, True),
                                       (["scripts/ci_population.py"], set(), True, True),
                                       (["scripts/test_ci_summary.py"], set(), True, True),
                                       (["scripts/run_host_checks.py"], set(), True, True),
                                       (["scripts/ui_test_inventory.py"], set(), True, True),
                                       (["scripts/ci-pins.json"], set(), True, True),
                                       (["scripts/ci-ui-shards.json"], set(), True, True),
                                       (["scripts/test_timeout_allowlist.json"], set(), True, True),
                                       (["immichSlides-iOS.xctestplan"], set(), True, True),
                                       (["immichSlides-tvOS.xctestplan"], set(), True, True),
                                       (["other/XcodeCloud-UI-tvOS.xctestplan"], set(), True, True),
                                       (["Other.xctestplan"], set(), True, True),
                                       (["immichSlides.xcodeproj/xcshareddata/xcschemes/immichSlides-tvOS.xcscheme"], set(), True, True),
                                       ([".github/workflows/ci-gate.yml"], set(), True, True),
                                       ([".github/actions/check/action.yml", ".github/actions/check/check.py"], set(), True, True),
                                       ([".swift-format"], set(), True, True),
                                       (["scripts/check_test_conventions.py", "scripts/test_conventions_allowlist.json"], set(), True, True),
                                       (["AGENTS.md", "CLAUDE.md", ".github/ISSUE_TEMPLATE/bug.md"], set(), True, False),
                                       (["scripts/run_strict_e2e.py", "scripts/test_strict_e2e_photo_identity.py"], set(), True, True),
                                       (["scripts/clean_stale_catalog_entries.py", "scripts/test_clean_stale_catalog_entries.py"], set(), True, False),
                                       (["unknown.file"], set(), True, False)):
            with self.subTest(paths=paths):
                classification = classify_changes(paths, allowlist, build_target_paths=members)
                self.assertEqual((classification["app_affected"], classification["ci_changing"]), (app, ci))
        host_paths = [part for _, command in HOST_CHECKS for part in command if part.startswith("scripts/")]
        host_paths += ["scripts/test_check_test_conventions.py", "scripts/test_check_release_guards.py",
                       "scripts/test_validate_localization_catalog.py", "scripts/test_scan_chinese_strings.py",
                       "scripts/test_required_test_tools.py", "scripts/test_conventions_allowlist.json"]
        root = Path(__file__).resolve().parent.parent
        for workflow in (root / ".github/workflows").glob("*.yml"):
            source = workflow.read_text(encoding="utf-8")
            for reference in re.findall(r"\bscripts/[A-Za-z0-9_./*?\[\]-]+", source):
                if any(character in reference for character in "*?["):
                    matches = [str(path.relative_to(root)) for path in root.glob(reference) if path.is_file()]
                    self.assertTrue(matches, f"workflow path pattern has no files: {reference}")
                    host_paths += matches
                else:
                    host_paths.append(reference)
            for action in re.findall(r"\buses:\s*['\"]?\./([A-Za-z0-9_./-]+)", source):
                action_files = [str(path.relative_to(root)) for path in (root / action).rglob("*") if path.is_file()]
                self.assertTrue(action_files, f"local action path has no files: {action}")
                host_paths += action_files
            # Bare names in the source-free consumer toolset are CI inputs too.
            for copied in re.findall(r"for file in ([^;]+); do", source):
                host_paths += ["scripts/" + name for name in copied.split()]
        host_paths += ["scripts/test_check_all.py", "scripts/test_git_privacy_gate.py", "scripts/__init__.py"]
        host_paths += [str(path.relative_to(root)) for path in (root / "scripts").glob("git_privacy_gate_test_*.py")]
        host_paths += ["scripts/test_run_offline_unit_tests.py"]
        host_paths += [str(path.relative_to(root)) for path in (root / "scripts").glob("run_offline_unit_tests_test_*.py")]
        for path in host_paths:
            with self.subTest(host_path=path):
                self.assertTrue(classify_changes([path], allowlist, build_target_paths=set())["ci_changing"])
        local_modules = {path.stem: path for path in (root / "scripts").glob("*.py")}
        pending = [path for path in local_modules.values()
                   if classify_changes([str(path.relative_to(root))], allowlist, build_target_paths=set())["ci_changing"]]
        visited = set()
        while pending:
            path = pending.pop()
            if path in visited:
                continue
            visited.add(path)
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"), filename=str(path))):
                if isinstance(node, ast.Import):
                    names = [alias.name for alias in node.names]
                elif isinstance(node, ast.ImportFrom):
                    names = (["__init__"] + [alias.name for alias in node.names] if node.module == "scripts"
                             else [node.module] if node.module else [alias.name for alias in node.names])
                else:
                    continue
                for name in names:
                    module = name.removeprefix("scripts.").split(".")[0]
                    if module in local_modules:
                        dependency = local_modules[module]
                        relative = str(dependency.relative_to(root))
                        with self.subTest(importer=str(path.relative_to(root)), dependency=relative):
                            self.assertTrue(classify_changes([relative], allowlist, build_target_paths=set())["ci_changing"],
                                            "CI-trusted scripts must include their recursive local-import closure")
                        pending.append(dependency)
        for pattern in allowlist["ci_trusted"] + allowlist["app_unaffected"]:
            if not any(character in pattern for character in "*?["):
                with self.subTest(exact_path=pattern):
                    self.assertTrue((root / pattern).is_file(), "exact classification entries must exist")
        self.assertEqual(self.verdict(context="ui", app_affected=False)["status"], "not-applicable")
        with self.assertRaisesRegex(ci_summary.ContractError, "changed path list"):
            classify_changes([], allowlist, build_target_paths=set())
        for path in ("../README.md", "/README.md", "docs/../scripts/x.py"):
            with self.subTest(path=path), self.assertRaises(ci_summary.ContractError):
                classify_changes([path], allowlist, build_target_paths=set())


if __name__ == "__main__":
    unittest.main()
