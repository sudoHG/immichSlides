"""Discovery entry point preserving the existing test class identities."""

from __future__ import annotations

import sys
from contextlib import ExitStack
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

from run_strict_e2e_test_fixtures import (
    CASE_E2E_IDS,
    CommandError,
    FILTER_PERSON_SESSIONS,
    FROZEN_FIXTURE_SHA256,
    IMAGE_FAILURE_RECOVERY_SUITES,
    IOS_FILTER_SUITES,
    IOS_FIRST_BATCH_SUITES,
    IOS_LATE_IMAGE_SUITES,
    MIN_DATA_GIB,
    P2_CASES,
    P2_MOVIE,
    P2_UDID,
    PRIVATE_RESULT_BUNDLE_ROOT,
    Path,
    RAW_VERDICT,
    REPO_ROOT,
    RUNNER_SUITES,
    SCRIPT_DIR,
    TVOS_CONTROL_SUITES,
    TVOS_FILTER_SUITES,
    TVOS_FLOW_SUITES,
    TVOS_LATE_IMAGE_SUITES,
    TestResultsSummary,
    WRONG_PUBLIC_API_KEY,
    _fixture_data,
    _p2_facts,
    _rgb_png,
    _run_code_without_site,
    _run_runner_without_site,
    _swift_test_methods,
    _write_p2_ui_outputs,
    _write_pause_window_evidence,
    audit_out_of_order_runner_inputs,
    build_xcodebuild_command,
    choose_exit_code,
    cleanup_task_xcconfig,
    compressed_byte_coincidence,
    io,
    json,
    load_member_manifest,
    make_test_environment,
    merge_official_summaries,
    mock,
    os,
    prepare_evidence_directory,
    prepare_private_result_bundle_path,
    prepare_task_xcconfig,
    re,
    read_source_dirty_paths,
    read_source_sha,
    require_official_single_pass,
    require_visual_identity,
    reserve_unreachable_server_url,
    reset_simulator_app,
    result_bundle_name,
    run_cleanup_actions,
    run_command,
    runner_main,
    scenario_settings,
    shutil,
    signal,
    simulator_app_container,
    start_screen_recording,
    stat,
    stop_screen_recording,
    struct,
    subprocess,
    sys,
    tempfile,
    unittest,
    urllib,
    validate_app_launch_environment,
    validate_suite_fixture,
    validate_suite_scenario,
    write_case_manifest,
    write_fixture_artifacts,
    write_member_manifest,
    write_sensitive_scan,
    zlib,
)

from run_strict_e2e_test_configuration_cases import StrictE2ERunnerTestsCasesConfiguration
from run_strict_e2e_test_evidence_cases import StrictE2ERunnerTestsCasesEvidence

class StrictE2ERunnerTests(StrictE2ERunnerTestsCasesConfiguration, StrictE2ERunnerTestsCasesEvidence, unittest.TestCase):
    def test_clean_retry_cannot_hide_first_attempt_request_contract_violation(self):
        from run_strict_e2e import StrictRetryEvidence
        for violation in (
            "",
            "request elapsed_ms=10 method=GET path=/unknown status=200 range=absent fixture_asset_id=none\n",
            "request elapsed_ms=10 method=GET path=/healthz status=400 range=absent fixture_asset_id=none\n",
            "x-api-key: forbidden\n",
            "request elapsed_ms=10 method=GET path=/api/assets/<fixture-id>/thumbnail status=200 range=absent fixture_asset_id=asset-a-1\n",
        ):
            with self.subTest(violation=violation), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory)
                service = evidence / "service.log"
                service_b = evidence / "service-b.log"
                service.write_text("")
                service_b.write_text("")
                dual_server = not violation or "asset-a-1" in violation
                state = StrictRetryEvidence(evidence, "xcodebuild", [service, service_b] if dual_server else [service])
                clean = "request elapsed_ms=20 method=GET path=/healthz status=200 range=absent fixture_asset_id=none\n"
                service.write_text(clean if "asset-a-1" in violation else clean + violation)
                service_b.write_text(clean + violation if "asset-a-1" in violation else clean)
                state.before_retry()
                for path in (service, service_b):
                    with path.open("a") as log:
                        log.write(clean)
                state.finish()
                arguments = dict(suite="filter-switch" if dual_server else "late-image",
                    scenario="normal" if dual_server else "out-of-order", fixture_set="a",
                    fixture_hash=FROZEN_FIXTURE_SHA256["a"], server_url="http://127.0.0.1:1234/api")
                if violation:
                    with self.assertRaises(CommandError):
                        state.audit(**arguments)
                else:
                    state.audit(**arguments)

    def test_recording_retry_is_rejected_before_any_device_or_evidence_work(self):
        from contextlib import redirect_stderr
        from strict_e2e_runner_support import SERVER_SWITCH_DISPLAY_SUITES
        suites = [suite for suite, case in P2_CASES.items() if case.video] + list(SERVER_SWITCH_DISPLAY_SUITES)
        for suite in suites:
            with self.subTest(suite=suite), tempfile.TemporaryDirectory() as directory, redirect_stderr(io.StringIO()):
                evidence = Path(directory) / "evidence"
                with self.assertRaises(SystemExit) as error:
                    runner_main(["--platform", "ios", "--destination", "platform=iOS Simulator,id=" + P2_UDID,
                        "--suite", suite, "--test-without-building", "--listed-retry-device", "iphone",
                        "--derived-data-path", str(Path(directory) / "derived"), "--evidence-dir", str(evidence)])
                self.assertEqual(error.exception.code, 2)
                self.assertFalse(evidence.exists())

    def test_retry_cannot_borrow_first_attempt_out_of_order_timeline_or_screenshots(self):
        from run_strict_e2e import StrictRetryEvidence
        from strict_e2e_out_of_order_contract import assert_out_of_order_timeline, OutOfOrderContractError
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            service = evidence / "service.log"
            service.write_text("")
            state = StrictRetryEvidence(evidence, "xcodebuild", [service])
            timeline = (
                "request_started elapsed_ms=10 method=GET path=/api/assets/<fixture-id>/thumbnail size=preview range=absent fixture_asset_id=asset-a-1\n"
                "request_started elapsed_ms=20 method=GET path=/api/assets/<fixture-id>/thumbnail size=preview range=absent fixture_asset_id=asset-a-2\n"
                "request elapsed_ms=30 method=GET path=/api/assets/<fixture-id>/thumbnail status=200 range=absent fixture_asset_id=asset-a-2 size=preview\n"
                "request elapsed_ms=40 method=GET path=/api/assets/<fixture-id>/thumbnail status=200 range=absent fixture_asset_id=asset-a-1 size=preview\n")
            service.write_text(timeline)
            (evidence / "ooo-current-scene.png").write_bytes(b"first screenshot")
            (evidence / "simulator-reset.log").write_text("first reset\n")
            state.before_retry()
            self.assertFalse((evidence / "ooo-current-scene.png").exists())
            self.assertEqual((evidence / "attempt-1/xcodebuild/ooo-current-scene.png").read_bytes(), b"first screenshot")
            with (evidence / "simulator-reset.log").open("a") as log:
                log.write("retry reset\n")
            with service.open("a") as log:
                log.write("request elapsed_ms=50 method=GET path=/healthz status=200 range=absent fixture_asset_id=none\n")
            state.finish()
            arguments = dict(delayed_asset_id="asset-a-1", immediate_asset_id="asset-a-2", size="preview")
            self.assertEqual(assert_out_of_order_timeline(service.read_text(), **arguments)["delayed_complete_ms"], 40)
            with self.assertRaises(OutOfOrderContractError):
                assert_out_of_order_timeline((evidence / "redacted-request.log").read_text(), **arguments)
            self.assertIn("retry reset", (evidence / "simulator-reset.log").read_text())


from run_strict_e2e_test_p2_cases import StrictE2EP2RunnerTestsCases
import run_strict_e2e as strict_runner

class StrictE2EP2RunnerTests(StrictE2EP2RunnerTestsCases, unittest.TestCase):
    def _run_p2_main(
        self,
        evidence: Path,
        *,
        suite: str,
        platform: str,
        model: str,
        skip: tuple[str, ...] = (),
        facts_device_id: str = P2_UDID,
        xcodebuild_exit: int = 0,
        create_result_bundle: bool = True,
        export_exit: int = 0,
        failure_session: str | None = None,
        warm: bool = False,
        retry: bool = False,
        timeout_phase: str | None = None,
    ) -> tuple[int, str, str, dict[str, mock.Mock]]:
        destination = f"platform={'tvOS' if platform == 'tvos' else 'iOS'} Simulator,id={P2_UDID}"
        selector = (
            P2_CASES[suite].selectors[platform] if suite in P2_CASES
            else strict_runner.resolve_suite_selector(platform, suite)
        )
        recording_process = mock.Mock(pid=9876)
        invocations = []
        from test_ci_flaky import registry
        from ci_summary import test_identity
        retry_registry = registry()
        retry_registry["entries"][0]["scope"]["tier"] = "strict"
        retry_registry["entries"][0]["identity"] = test_identity("strict",
            FILTER_PERSON_SESSIONS[0]["selector"].split("/", 1)[1], device="iphone", configuration="Debug",
            suite="filter-person", scenario="normal", fixture="a")

        def fake_run_command(command: list[str], **kwargs: object) -> int:
            kwargs["log_path"].write_text("test run\n", encoding="utf-8")
            invocations.append(command)
            if suite != "filter-person":
                self.assertEqual([item for item in command if item.startswith("-only-testing:")], [f"-only-testing:{selector}"])
            if suite in P2_CASES:
                _write_p2_ui_outputs(evidence, suite, skip=skip)
            if create_result_bundle:
                bundle = Path(command[command.index("-resultBundlePath") + 1])
                self.assertEqual(bundle.parent.parent, evidence.parent / "private")
                bundle.mkdir()
                (bundle / "raw.bin").write_bytes(b"raw diagnostics")
            if failure_session is not None and kwargs["log_path"].name != f"xcodebuild-{failure_session}.log":
                return 0
            if retry:
                return 65 if len(invocations) == 1 else 0
            return xcodebuild_exit

        def fake_subprocess(command: list[str], **_: object) -> subprocess.CompletedProcess[object]:
            if command[:2] == ["xcrun", "xcresulttool"]:
                if timeout_phase == "official-tests-export":
                    raise subprocess.TimeoutExpired(["private-test-input"], 60, output=b"private-test-input")
                return subprocess.CompletedProcess(command, export_exit, b'{"testNodes":[]}', b"")
            return subprocess.CompletedProcess(command, 0, "", "")

        def fake_test_run(source, directory, environment):
            run = directory / "case.xctestrun"
            run.write_bytes(b"private test inputs")
            return run

        def retry_results(bundle, identity_for_key, elapsed, code, **kwargs):
            from ci_summary import observation
            key = next(item.split(":", 1)[1].split("/", 1)[1] for item in invocations[-1]
                       if item.startswith("-only-testing:"))
            return [observation(identity_for_key(key), "failed" if code == 65 else "passed", elapsed,
                                reason="Official XCTest assertion failure" if code == 65 else None, exit_code=code)]

        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", evidence.parent / "private"), mock.patch(
            "run_strict_e2e.data_available_gib", return_value=100
        ), mock.patch(
            "run_strict_e2e.read_source_sha", return_value="0" * 40
        ), mock.patch("run_strict_e2e.read_source_dirty_paths", return_value=[]) as dirty, mock.patch(
            "run_strict_e2e.prepare_task_xcconfig", return_value={}
        ), mock.patch("run_strict_e2e.cleanup_task_xcconfig"), mock.patch(
            "run_strict_e2e.subprocess.run", side_effect=fake_subprocess
        ), mock.patch("run_strict_e2e.reset_simulator_app", return_value="reset\n",
                      side_effect=strict_runner.InfrastructureTimeout(timeout_phase, 60)
                      if timeout_phase == "simulator-bootstatus" else None), mock.patch(
            "run_strict_e2e.run_command", side_effect=fake_run_command
        ), mock.patch(
            "run_strict_e2e.read_official_test_results_summary",
            return_value=TestResultsSummary(1, 1, 0, 0, "Passed"),
            side_effect=strict_runner.InfrastructureTimeout(timeout_phase, 60)
            if timeout_phase == "official-summary-export" else None,
        ), mock.patch(
            "run_strict_e2e.read_xcresult_facts",
            return_value=_p2_facts(suite, platform, model, facts_device_id) if suite in P2_CASES else {},
        ) as facts, mock.patch("run_strict_e2e.require_visual_identity", return_value={}), mock.patch(
            "run_strict_e2e.start_screen_recording", return_value=(recording_process, 900.0)
        ) as start, mock.patch("run_strict_e2e.stop_screen_recording", return_value=0) as stop, mock.patch(
            "strict_e2e_build.load_warm_build", return_value=({"identity": {"configuration": "Debug"}}, Path("warm.xctestrun"))
        ), mock.patch("strict_e2e_build.validate_warm_products"), mock.patch(
            "strict_e2e_build.prepare_test_run", side_effect=fake_test_run
        ), ExitStack() as stack:
            stack.enter_context(mock.patch("ci_flaky.simulator_device_class", return_value="iphone"))
            stack.enter_context(mock.patch("ci_flaky.read_xcode_observations", side_effect=retry_results))
            stack.enter_context(mock.patch("ci_flaky.registry_revision", return_value="b" * 40))
            stack.enter_context(mock.patch("ci_flaky.load_registry", return_value=(retry_registry, "a" * 64)))
            exit_code = runner_main(
                [
                    "--platform",
                    platform,
                    "--destination",
                    destination,
                    "--evidence-dir",
                    str(evidence),
                    "--suite",
                    suite,
                    *(["--test-without-building", "--derived-data-path", str(evidence.parent / "derived")] if warm else []),
                    *(["--listed-retry-device", "iphone"] if retry else []),
                ],
                stdout=stdout,
                stderr=stderr,
            )
        return exit_code, stdout.getvalue(), stderr.getvalue(), {
            "dirty": dirty,
            "facts": facts,
            "start": start,
            "stop": stop,
            "recording_process": recording_process,
        }

    def test_retry_records_keep_all_person_sessions_and_each_warm_receipt(self):
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw) / "evidence"
            code, _, stderr, _ = self._run_p2_main(evidence, suite="filter-person", platform="ios",
                                                  model="iPhone", warm=True, retry=True)
            self.assertEqual(code, 0, stderr)
            sessions = json.loads((evidence / "retry-invocations.json").read_text())["sessions"]
            self.assertEqual({key: len(value["invocations"]) for key, value in sessions.items()},
                             {"xcodebuild-normal": 2, "xcodebuild-conflict-normal": 1, "xcodebuild-nofaces": 1})
            receipts = [evidence / (key + "-reuse.json") for key in sessions]
            receipts.append(evidence / "attempt-1/xcodebuild-normal/xcodebuild-normal-reuse.json")
            for path in receipts:
                receipt = json.loads(path.read_text())
                self.assertTrue(receipt["products_unchanged"])
                self.assertEqual(receipt["timeout_seconds"], 300)
                self.assertGreaterEqual(receipt["duration_seconds"], 0)
            self.assertEqual([json.loads(path.read_text())["exit_code"] for path in receipts], [0, 0, 0, 65])

    def test_warm_test_inputs_do_not_prevent_private_bundle_disposal(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            evidence = root / "evidence"
            code, _, stderr, _ = self._run_p2_main(evidence, suite="smoke", platform="ios", model="iPhone", warm=True)
            self.assertEqual(code, 0, stderr)
            self.assertEqual(list((root / "private").iterdir()), [])

    def test_inner_timeout_records_its_phase_and_finishes_private_cleanup(self):
        for phase in ("simulator-bootstatus", "official-tests-export", "official-summary-export"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                evidence = root / "evidence"
                code, _, stderr, _ = self._run_p2_main(
                    evidence, suite="smoke", platform="ios", model="iPhone", warm=True,
                    timeout_phase=phase,
                )
                self.assertNotEqual(code, 0, stderr)
                record = json.loads((evidence / "case-manifest.json").read_text())
                self.assertEqual(record["result"], "FAILED")
                self.assertEqual(record["infrastructure"][0]["code"], phase + "-timeout")
                self.assertNotIn("private-test-input", json.dumps(record) + stderr)
                self.assertEqual(json.loads((evidence / "sensitive-scan.json").read_text())["result"], "PASS")
                self.assertEqual(list((root / "derived").glob("strict-case-*/case.xctestrun")), [])
                if phase.startswith("official-"):
                    quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
                    self.assertFalse(quarantine["result_bundle_disposed"])
                    self.assertTrue(Path(quarantine["private_path"]).is_dir())

    def test_xcode_execution_timeout_remains_a_case_failure_without_infrastructure_diagnostics(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            with mock.patch("run_strict_e2e.subprocess.run", side_effect=subprocess.TimeoutExpired(
                    ["private-test-input"], 600, output=b"private-test-input")), self.assertRaises(CommandError) as raised:
                run_command(["xcodebuild"], cwd=root, environment={}, log_path=root / "xcodebuild.log", timeout_seconds=600)
            self.assertNotIsInstance(raised.exception, strict_runner.InfrastructureTimeout)
            self.assertNotIn("private-test-input", str(raised.exception))
            self.assertNotEqual(raised.exception.code, 0)

    def test_simulator_and_summary_timeouts_name_the_hung_phase_without_command_output(self):
        commands = {
            "boot": "simulator-boot", "bootstatus": "simulator-bootstatus",
            "terminate": "simulator-terminate", "uninstall": "simulator-uninstall",
            "get_app_container": "simulator-container", "keychain": "simulator-keychain-reset",
            "privacy": "simulator-privacy-reset",
        }
        for step, phase in commands.items():
            with self.subTest(step=step):
                def run(command, **kwargs):
                    if command[2] == step:
                        self.assertGreater(kwargs.get("timeout", 0), 0)
                        raise subprocess.TimeoutExpired(["private-test-input"], kwargs["timeout"],
                                                        output=b"private-test-input")
                    return subprocess.CompletedProcess(command, 2 if command[2] == "get_app_container" else 0, "", "")
                with mock.patch("strict_e2e_runner_support.subprocess.run", side_effect=run), mock.patch(
                    "strict_e2e_runner_support.time.sleep"
                ), self.assertRaises(CommandError) as raised:
                    reset_simulator_app("SIM-UDID")
                self.assertEqual(raised.exception.entry["code"], phase + "-timeout")
                self.assertNotIn("private-test-input", str(raised.exception))
        with tempfile.TemporaryDirectory() as raw:
            bundle = Path(raw) / "result.xcresult"
            bundle.mkdir()
            def export(command, **kwargs):
                self.assertEqual(kwargs.get("timeout"), 60)
                raise subprocess.TimeoutExpired(["private-test-input"], 60, output=b"private-test-input")
            with mock.patch("run_offline_unit_tests.subprocess.run", side_effect=export), self.assertRaises(CommandError) as raised:
                strict_runner.read_official_test_results_summary(bundle)
            self.assertEqual(raised.exception.entry["code"], "official-summary-export-timeout")

    def test_ordinary_and_person_results_never_expose_raw_bundles(self) -> None:
        # Raw XCTest activities may retain UI-entered credentials even in failed sessions.
        for suite, count in (("smoke", 1), ("filter-person", 3)):
            cases = [(0, None, count), (65, None, 1)]
            if suite == "filter-person":
                cases.append((65, "conflict-normal", 2))
            for test_exit, failure_session, actual_count in cases:
                with self.subTest(suite=suite, test_exit=test_exit, failure_session=failure_session), tempfile.TemporaryDirectory() as raw:
                    evidence = Path(raw) / "evidence"
                    code, _, stderr, _ = self._run_p2_main(
                        evidence, suite=suite, platform="ios", model="iPhone",
                        create_result_bundle=True, xcodebuild_exit=test_exit,
                        failure_session=failure_session,
                    )
                    self.assertEqual(code, test_exit, stderr)
                    self.assertEqual(list(evidence.rglob("*.xcresult")), [])
                    self.assertEqual(json.loads((evidence / "sensitive-scan.json").read_text())["result"], "PASS")
                    self.assertEqual(len(list(evidence.glob("official-tests*.json"))), actual_count)
                    records = list(evidence.glob("result-bundle-*.json"))
                    self.assertEqual(len(records), actual_count)
                    for record in records:
                        payload = json.loads(record.read_text())
                        self.assertEqual(payload["result_bundle_disposed"], test_exit == 0)
                        self.assertEqual(Path(payload["private_path"]).exists(), test_exit != 0)

    def test_sensitive_official_export_is_refused_and_raw_bundle_stays_private(self) -> None:
        for value in ("test-private-pin", WRONG_PUBLIC_API_KEY):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                evidence = root / "evidence"
                evidence.mkdir()
                bundle = root / "private" / "run" / "tests.xcresult"
                bundle.mkdir(parents=True)
                (bundle / "activities.bin").write_bytes(value.encode())
                completed = subprocess.CompletedProcess([], 0, json.dumps({"failure": value}).encode(), b"")
                with mock.patch("run_strict_e2e.subprocess.run", return_value=completed), self.assertRaises(CommandError):
                    strict_runner.export_private_result_bundle(bundle, evidence, [value])
                self.assertEqual(list(evidence.iterdir()), [])
                self.assertEqual(strict_runner.finalize_private_result_bundle(bundle, evidence, None, successful=False), [])
                self.assertTrue(bundle.is_dir())
                self.assertFalse(json.loads((evidence / "result-bundle-quarantine.json").read_text())["result_bundle_disposed"])




class StrictCITracerTests(unittest.TestCase):
    def test_failed_runner_keeps_official_counts_and_compilation_without_becoming_passed(self):
        import run_strict_ci_tracer as tracer
        case = {"platform": "ios", "device": "iphone", "configuration": "Debug", "suite": "smoke", "scenario": "normal", "fixture": "a"}
        identity = {"schema_version": 1, "event": "local", "repository": "sudoHG/immichSlides",
                    "commit_sha": "0" * 40, "tree_sha": "0" * 40, "dirty": False}
        timeout = {"code": "official-tests-export-timeout", "message": "official-tests-export timed out after 60.0s."}
        for official_result, infrastructure, contract in (("Passed", [], None), ("Passed", [], "FAIL"),
                                                        ("Failed", [], None), ("Failed", [timeout], None)):
            with self.subTest(result=official_result, infrastructure=infrastructure), tempfile.TemporaryDirectory() as raw:
                output = Path(raw) / "trace"
                manifest = Path(raw) / "manifest.json"
                manifest.write_text(json.dumps({"cases": [case], "exclusions": []}))

                def runner(command, *_args, **_kwargs):
                    derived = Path(command[command.index("--derived-data-path") + 1])
                    evidence = Path(command[command.index("--evidence-dir") + 1])
                    if "--warm-up-only" in command:
                        derived.mkdir(parents=True)
                        (derived / "strict-warm-build.json").write_text(json.dumps({"signing_mode": "adhoc"}))
                        return 0
                    evidence.mkdir(parents=True)
                    (evidence / "case-manifest.json").write_text(json.dumps({"infrastructure": infrastructure}))
                    if contract:
                        (evidence / "visual-identity-runner.json").write_text(json.dumps({
                            "suite": "smoke", "verdict": contract, "error": "private runner details"}))
                    (evidence / "xcodebuild.log").write_text("test-without-building\n")
                    (evidence / "xcodebuild-reuse.json").write_text(json.dumps({"products_unchanged": True}))
                    counts = {"totalTestCount": 1, "passedTests": int(official_result == "Passed"),
                              "failedTests": int(official_result == "Failed"), "skippedTests": 0, "result": official_result}
                    (evidence / "official-summary.json").write_text(json.dumps(counts))
                    (evidence / "official-tests.json").write_text(json.dumps({"testNodes": [{
                        "nodeType": "Unit test bundle", "name": "immichSlidesUITests", "children": [{
                            "nodeType": "Test Case", "nodeIdentifier": "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke()",
                            "result": official_result}]}]}))
                    return 124 if infrastructure else 65

                with mock.patch.object(tracer, "run_runner", side_effect=runner), mock.patch.object(tracer, "workspace_preflight"), \
                        mock.patch.object(tracer, "run_identity", return_value=identity), \
                        mock.patch.object(tracer, "source_metadata", return_value=(None, False)), \
                        mock.patch.object(tracer, "toolchain", return_value={"versions": {"python": "test"}, "signing_mode": "not-applicable"}):
                    self.assertEqual(tracer.main(["--platform", "ios", "--destination", "unused", "--manifest", str(manifest),
                                                  "--output-dir", str(output)]), 1)
                summary = json.loads((output / "records/summary.json").read_text())
                trace = json.loads((output / "records/trace.json").read_text())
                self.assertEqual(summary["population"]["compiled"], summary["population"]["declared"])
                self.assertEqual(summary["population"]["observed"][0]["outcome"], "failed")
                self.assertEqual(trace["warm"][0]["official_summary"]["totalTestCount"], 1)
                self.assertEqual([{"identifier": "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke", "result": official_result}],
                                 trace["warm"][0]["official_methods"])
                self.assertEqual(trace["warm"][0]["exit_code"], 124 if infrastructure else 65)
                self.assertEqual(summary["infrastructure"], infrastructure)
                self.assertEqual(trace["warm"][0]["infrastructure"], infrastructure)
                self.assertEqual(contract == "FAIL", trace["warm"][0]["automated_contract_failed"])
                self.assertNotIn("private runner details", json.dumps(trace))

    def test_official_export_rejects_another_selected_test_even_when_counts_match(self):
        from run_strict_ci_tracer import validate_case_export
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            payload = {"testNodes": [{"nodeType": "Unit test bundle", "name": "immichSlidesUITests", "children": [
                {"nodeType": "Test Case", "nodeIdentifier": "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke()", "result": "Failed"}]}]}
            (evidence / "official-tests.json").write_text(json.dumps(payload))
            self.assertEqual([{"identifier": "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke", "result": "Failed"}],
                             validate_case_export(evidence, "ios", "smoke"))
            with self.assertRaises(ValueError):
                validate_case_export(evidence, "ios", "smoke", {
                    "totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0})
            payload["testNodes"][0]["children"][0]["nodeIdentifier"] = "OtherTests/testWrong()"
            (evidence / "official-tests.json").write_text(json.dumps(payload))
            with self.assertRaises(ValueError):
                validate_case_export(evidence, "ios", "smoke")

    def test_official_exports_survive_runner_failure_and_malformed_counts_fail_closed(self):
        from run_strict_ci_tracer import read_case_official
        good = {"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0, "result": "Failed"}
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            (evidence / "official-summary.json").write_text(json.dumps(good))
            self.assertEqual(read_case_official(evidence, "smoke"), good)
            for counts in (dict(good, totalTestCount=True), dict(good, failedTests=-1),
                           dict(good, totalTestCount=2), dict(good, result="Passed")):
                with self.subTest(counts=counts):
                    (evidence / "official-summary.json").write_text(json.dumps(counts))
                    with self.assertRaises(ValueError):
                        read_case_official(evidence, "smoke")

    def test_person_official_exports_preserve_partial_execution_and_three_session_counts(self):
        from run_strict_ci_tracer import read_case_official
        good = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "result": "Passed"}
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            for session in ("normal", "conflict-normal", "nofaces"):
                (evidence / f"official-summary-{session}.json").write_text(json.dumps(good))
            self.assertEqual(read_case_official(evidence, "filter-person")["totalTestCount"], 3)
            (evidence / "official-summary-nofaces.json").unlink()
            self.assertEqual(read_case_official(evidence, "filter-person")["totalTestCount"], 2)

    def test_tracer_rejects_incomplete_or_failed_checks(self):
        from ci_summary import test_identity
        from run_strict_ci_tracer import evaluate_tracer
        from strict_e2e_p2_contract import RAW_VERDICT
        identity = test_identity("strict", "smoke", configuration="Debug", device="iphone", fixture="a", scenario="normal", suite="smoke")
        p2 = test_identity("strict", "p2-rotation", configuration="Debug", device="iphone", fixture="a", scenario="normal", suite="p2-rotation")
        good = {"identity": identity, "duration_seconds": 1, "exit_code": 0, "log_present": True,
                "build_operations": 0, "products_unchanged": True,
                "official_summary": {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "result": "Passed"}}
        cases = [
            ("complete", [identity], [good], False, "passed", ["passed"]),
            ("empty manifest", [], [], False, "failed", []),
            ("p2", [p2], [{**good, "identity": p2, "p2_verdict": RAW_VERDICT}], False, "unverified", ["needs-human-review"]),
            ("build in log", [identity], [{**good, "build_operations": 1}], False, "failed", ["failed"]),
            ("Products changed", [identity], [{**good, "products_unchanged": False}], False, "failed", ["failed"]),
            ("log missing", [identity], [{**good, "log_present": False}], False, "failed", ["failed"]),
            ("P2 verdict mismatch", [p2], [{**good, "identity": p2, "p2_verdict": "passed"}], False, "failed", ["failed"]),
            ("official results missing", [identity], [{**good, "official_summary": None}], False, "failed", ["failed"]),
            ("incomplete results", [identity, p2], [good], False, "failed", ["passed", "not-run"]),
            ("interruption", [identity, p2], [good], True, "failed", ["passed", "not-run"]),
            ("interruption after checks", [identity], [good], True, "failed", ["passed"]),
        ]
        for name, declared, results, interrupted, status, outcomes in cases:
            with self.subTest(name=name):
                observed, actual = evaluate_tracer(declared, results, interrupted=interrupted)
                self.assertEqual(actual, status)
                self.assertEqual([entry["outcome"] for entry in observed], outcomes)

    def test_tracer_interruptions_record_failed_status_and_unrun_cases(self):
        import run_strict_ci_tracer as tracer
        identity = {"schema_version": 1, "event": "local", "repository": "sudoHG/immichSlides",
                    "commit_sha": "0" * 40, "tree_sha": "0" * 40, "dirty": False}
        for error in (KeyboardInterrupt(), KeyError("unexpected state")):
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as raw, mock.patch(
                "run_strict_ci_tracer.run_runner", side_effect=error
            ), mock.patch("run_strict_ci_tracer.workspace_preflight"), mock.patch(
                "run_strict_ci_tracer.run_identity", return_value=identity
            ), mock.patch("run_strict_ci_tracer.source_metadata", return_value=(None, False)), mock.patch(
                "run_strict_ci_tracer.toolchain", return_value={"versions": {"python": "test"}, "signing_mode": "not-applicable"}
            ):
                output = Path(raw) / "trace"
                self.assertEqual(tracer.main(["--platform", "ios", "--destination", "unused", "--output-dir", str(output)]), 1)
                summary = json.loads((output / "records/summary.json").read_text())
                self.assertEqual(summary["status"], "failed")
                self.assertEqual(summary["infrastructure"][0]["code"], "interrupted")
                self.assertEqual(len(summary["population"]["observed"]), 3)
                self.assertTrue(all(entry["outcome"] == "not-run" for entry in summary["population"]["observed"]))
                self.assertTrue((output / "records/trace.json").is_file())

    def test_runner_timeout_or_cancellation_stops_its_descendants(self):
        import contextlib
        import run_strict_ci_tracer as tracer
        from run_host_checks import group_has_live_members
        import time
        popen = subprocess.Popen
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                marker = root / "group"
                code = "import os,pathlib,subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); print('CommandError: fixture failure',flush=True); pathlib.Path(sys.argv[1]).write_text(str(os.getpgrp())); time.sleep(60)"
                command = [sys.executable, "-c", code, str(marker)]

                def start(*args, **kwargs):
                    process = popen(*args, **kwargs)
                    wait = process.wait

                    def interrupt_after_start(*args, **kwargs):
                        deadline = time.monotonic() + 5
                        while not marker.exists() and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(marker.exists(), "runner must start its child before cancellation")
                        process.wait = wait
                        raise KeyboardInterrupt()

                    if interrupted and args[0] == command:
                        process.wait = interrupt_after_start
                    return process

                stderr = io.StringIO()
                with mock.patch("run_strict_ci_tracer.subprocess.Popen", side_effect=start), contextlib.redirect_stderr(stderr):
                    with self.assertRaises(KeyboardInterrupt if interrupted else subprocess.TimeoutExpired):
                        tracer.run_runner(command, root, root / "runner.log", timeout_seconds=2)
                self.assertTrue(marker.exists())
                self.assertFalse(group_has_live_members(int(marker.read_text())))
                self.assertIn("CommandError: fixture failure", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
