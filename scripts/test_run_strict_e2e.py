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
    def test_service_timeout_reports_only_bounded_allowlisted_startup_phases(self):
        import strict_e2e_runner_support as support
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            startup_log = root / "startup.log"
            safe = "fixture-startup: phase=fixture-build; state=started; elapsed=0.000s; total=0.123s"
            startup_log.write_text("private-input /private/path\n" + safe + "\n" +
                safe + " private-input\n" + "x" * 4096 + "\n" +
                "fixture-startup: phase=ready-write; state=completed; elapsed=0.001s; total=0.124s\n")
            clock = [0.0]
            process = mock.Mock(pid=7)
            process.poll.return_value = None
            with mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                    mock.patch.object(support.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                    mock.patch("builtins.print") as report, self.assertRaises(CommandError) as error:
                support.wait_for_service(root / "ready.json", process, startup_log=startup_log)
            output = "\n".join(call.args[0] for call in report.call_args_list)
            self.assertEqual(output, safe)
            self.assertNotIn("private-input", str(error.exception) + output)
            self.assertIn("startup_phase=fixture-build; startup_state=started", str(error.exception))
            self.assertGreaterEqual(clock[0], 60)

    def test_service_startup_accepts_slow_health_but_preserves_failure_checks(self):
        import strict_e2e_runner_support as support
        from urllib.error import HTTPError

        for state in ("slow", "health-delay", "missing", "invalid", "unhealthy", "connection", "pid", "exited", "late"):
            with self.subTest(state=state):
                clock = [0.0]
                ready = mock.Mock()
                ready.is_file.side_effect = lambda: state != "missing" and (state != "slow" or clock[0] >= 20)
                ready.read_text.return_value = "invalid" if state == "invalid" else json.dumps({
                    "pid": 8 if state == "pid" else 7, "host": "127.0.0.1", "port": 1234,
                })
                process = mock.Mock(pid=7)
                process.poll.return_value = 3 if state == "exited" else None
                process.returncode = 3 if state == "exited" else None
                response = mock.MagicMock()
                response.__enter__.return_value.status = 200

                def request(*args, **kwargs):
                    self.assertGreater(kwargs["timeout"], 0)
                    self.assertLessEqual(kwargs["timeout"], 1)
                    if state == "unhealthy":
                        raise HTTPError("http://127.0.0.1/healthz", 503, "busy", {}, None)
                    if state == "connection":
                        raise OSError("unavailable")
                    if state == "late":
                        clock[0] = 61
                    response.__enter__.return_value.status = 503 if state == "health-delay" and clock[0] < 20 else 200
                    return response

                with mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                        mock.patch.object(support.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                        mock.patch.object(support.urllib.request, "urlopen", side_effect=request) as query, \
                        mock.patch("builtins.print") as report:
                    if state in ("slow", "health-delay"):
                        self.assertEqual(support.wait_for_service(ready, process), ("127.0.0.1", 1234))
                        self.assertAlmostEqual(clock[0], 20, delta=.05)
                        self.assertIn("elapsed=20.0s", report.call_args.args[0])
                    else:
                        with self.assertRaises(CommandError) as error:
                            support.wait_for_service(ready, process)
                        if state in ("pid", "exited"):
                            self.assertIn("PID" if state == "pid" else "exit 3", str(error.exception))
                            query.assert_not_called()
                            self.assertEqual(clock[0], 0)
                        else:
                            self.assertGreaterEqual(clock[0], 60)
                            self.assertLessEqual(clock[0], 61)
                            self.assertIn("last_state=", str(error.exception))
                            self.assertIn({"missing": "ready-file-missing", "invalid": "JSONDecodeError",
                                           "unhealthy": "health-http-503", "connection": "OSError",
                                           "late": "health-http-200"}[state], str(error.exception))

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
    def test_service_failure_exposes_private_startup_phase_for_either_server(self):
        import contextlib
        import strict_e2e_runner_support as support
        for failed_server in (1, 2):
            with self.subTest(failed_server=failed_server), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw) / "evidence"
                logs = []
                def launch(command, **kwargs):
                    phase = "fixture-build" if not logs else "bind"
                    line = f"fixture-startup: phase={phase}; state=started; elapsed=0.000s; total=0.123s\n"
                    log = kwargs["stdout"]
                    logs.append(Path(log.name) if log is not None else None)
                    if log is not None:
                        log.write(("private-input /private/path\n" + line).encode())
                        log.flush()
                    process = mock.Mock(pid=100 + len(logs))
                    process.poll.return_value = 0
                    process.wait.return_value = 0
                    return process
                def wait(ready, process):
                    if len(logs) == failed_server:
                        raise CommandError("Test service health check timed out (last_state=ready-file-missing).")
                    return "127.0.0.1", 1234
                with mock.patch("run_strict_e2e.subprocess.Popen", side_effect=launch), \
                        mock.patch.object(support, "_wait_for_service", side_effect=wait), \
                        contextlib.redirect_stdout(io.StringIO()):
                    code, _, stderr, _ = self._run_p2_main(
                        evidence, suite="filter-switch", platform="ios", model="iPhone")
                self.assertEqual(code, 2, stderr)
                phase = "fixture-build" if failed_server == 1 else "bind"
                self.assertIn(f"CommandError: Test service health check timed out (last_state=ready-file-missing). "
                              f"startup_phase={phase}; startup_state=started.", stderr)
                self.assertNotIn("private-input", stderr)
                self.assertNotIn("/private/path", stderr)
                expected = [evidence / "service-startup.log", evidence / "service-b-startup.log"][:failed_server]
                self.assertEqual(logs, expected)
                for log in logs:
                    self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)

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
        late_image_attempt=None,
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
            (selector if suite == "late-image" else FILTER_PERSON_SESSIONS[0]["selector"]).split("/", 1)[1],
            device="iphone", configuration="Debug", suite=suite if suite == "late-image" else "filter-person",
            scenario="out-of-order" if suite == "late-image" else "normal", fixture="a")

        def fake_run_command(command: list[str], **kwargs: object) -> int:
            kwargs["log_path"].write_text("test run\n", encoding="utf-8")
            invocations.append(command)
            if late_image_attempt is not None:
                late_image_attempt(kwargs["environment"], len(invocations))
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

        def fake_preparation(udid, *, report):
            report("simulator-preparation: " + ("failed" if timeout_phase in {"simulator-bootstatus", "simulator-readiness"} else "passed"))
            if timeout_phase in {"simulator-bootstatus", "simulator-readiness"}:
                raise strict_runner.InfrastructureTimeout(timeout_phase, 60)
            return None, "ready\n"

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
        ), mock.patch("run_strict_e2e.prepare_simulator", side_effect=fake_preparation) as prepare, mock.patch(
            "run_strict_e2e.reset_simulator_app", return_value="reset\n"
        ), mock.patch(
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
            def device_class(*args):
                prepare.assert_called_once()
                return "iphone"
            stack.enter_context(mock.patch("ci_flaky.simulator_device_class", side_effect=device_class))
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
                    *(["--scenario", "out-of-order"] if suite == "late-image" else []),
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

    def test_listed_late_image_retry_resets_and_isolates_hold_generations(self):
        import time
        import urllib.request
        from concurrent.futures import ThreadPoolExecutor
        with tempfile.TemporaryDirectory() as raw, ThreadPoolExecutor(max_workers=1) as executor:
            evidence = Path(raw) / "evidence"
            held = []
            generations = []

            def attempt(environment, number):
                base = environment["STRICT_E2E_INPUT_SERVER_URL"]
                def request(path, action=None):
                    headers = {"x-api-key": strict_runner.PUBLIC_API_KEY}
                    body = None
                    if action is not None:
                        headers["Content-Type"] = "application/json"
                        body = json.dumps({"action": action}).encode()
                    with urllib.request.urlopen(urllib.request.Request(base + path, data=body, headers=headers), timeout=5) as response:
                        return response.read()
                state = json.loads(request("/test/late-image", "arm"))
                generations.append(state.get("generation", 1))
                held.append(executor.submit(request, "/assets/asset-a-4/thumbnail?size=preview"))
                deadline = time.monotonic() + 5
                while json.loads(request("/test/late-image"))["pending"] != 1:
                    if time.monotonic() >= deadline:
                        self.fail("The listed retry must have an in-flight hold to reset")
                    time.sleep(.005)
                request("/assets/asset-a-2/thumbnail?size=preview")
                if number == 2:
                    request("/test/late-image", "release")
                    self.assertTrue(held[-1].result(timeout=5))

            code, _, stderr, _ = self._run_p2_main(evidence, suite="late-image", platform="ios", model="iPhone",
                                                  warm=True, retry=True, late_image_attempt=attempt)
            self.assertEqual(code, 0, stderr)
            self.assertEqual(generations, [1, 2])
            current = (evidence / "redacted-request.log").read_text()
            archived = (evidence / "attempt-1/xcodebuild/service.log").read_text()
            states = lambda text: [json.loads(line.removeprefix("late_image_hold ")) for line in text.splitlines()
                                   if line.startswith("late_image_hold ")]
            self.assertEqual({state["generation"] for state in states(current)}, {2})
            self.assertEqual({state["generation"] for state in states(archived)}, {1})
            self.assertEqual((states(archived)[-1]["pending"], states(current)[-1]["pending"]), (0, 0))
            self.assertTrue(all(future.result(timeout=5) for future in held))
            sessions = json.loads((evidence / "retry-invocations.json").read_text())["sessions"]
            self.assertEqual(len(sessions["xcodebuild"]["invocations"]), 2)

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
            self.assertEqual((evidence / "simulator-preparation.log").read_text(), "ready\n")
            self.assertEqual(list((root / "private").iterdir()), [])

    def test_inner_timeout_records_its_phase_and_finishes_private_cleanup(self):
        for phase in ("simulator-bootstatus", "simulator-readiness", "official-tests-export", "official-summary-export"):
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
                if phase.startswith("simulator-"):
                    self.assertIn("simulator-preparation: failed", (evidence / "simulator-preparation.log").read_text())
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
            "get_app_container": "simulator-readiness", "keychain": "simulator-keychain-reset",
            "privacy": "simulator-privacy-reset",
        }
        scenarios = [(step, phase, 0) for step, phase in (
            *commands.items(), ("get_app_container_after_uninstall", "simulator-container"))]
        scenarios.append(("get_app_container", "simulator-readiness", 70))
        for step, phase, query_overrun in scenarios:
            with self.subTest(step=step, query_overrun=query_overrun):
                container_calls = []
                clock = [0.0]
                calls = []

                def run(command, **kwargs):
                    calls.append(command)
                    if command[2] == "get_app_container":
                        container_calls.append(command)
                    timed_step = "get_app_container" if step == "get_app_container_after_uninstall" else step
                    if command[2] == timed_step and (step == timed_step or len(container_calls) == 2):
                        self.assertGreater(kwargs.get("timeout", 0), 0)
                        clock[0] += kwargs["timeout"]
                        if step == "get_app_container" and clock[0] >= 300:
                            clock[0] += query_overrun
                        raise subprocess.TimeoutExpired(["private-test-input"], kwargs["timeout"],
                                                        output=b"private-test-input")
                    if command[2] == "get_app_container":
                        if len(container_calls) == 1:
                            return subprocess.CompletedProcess(command, 0, "/sim/containers/immichSlides\n", "")
                    return subprocess.CompletedProcess(command, 2 if command[2] == "get_app_container" else 0, "", "")
                with mock.patch("strict_e2e_runner_support.subprocess.run", side_effect=run), mock.patch(
                    "strict_e2e_runner_support.time.sleep"
                ), mock.patch("strict_e2e_runner_support.time.monotonic", side_effect=lambda: clock[0]), mock.patch(
                    "builtins.print"
                ) as report, self.assertRaises(CommandError) as raised:
                    reset_simulator_app("SIM-UDID")
                self.assertEqual(raised.exception.entry["code"], phase + "-timeout")
                self.assertNotIn("private-test-input", str(raised.exception))
                if step == "get_app_container":
                    self.assertEqual(clock[0], 300 + query_overrun)
                    self.assertIn(f"deadline_overrun={query_overrun:.1f}s", "\n".join(call.args[0] for call in report.call_args_list))
                    self.assertFalse(any(command[2] in ("terminate", "uninstall", "keychain", "privacy") for command in calls))
        # A long boot must consume the same gate budget as post-boot queries.
        clock, calls = [0.0], []
        def cold(command, **kwargs):
            calls.append(command[2])
            if command[2] == "bootstatus":
                clock[0] += 550
            if command[2] == "get_app_container":
                clock[0] += kwargs["timeout"]
                raise subprocess.TimeoutExpired(command, kwargs["timeout"])
            return subprocess.CompletedProcess(command, 0, "", "")
        with mock.patch("strict_e2e_runner_support.subprocess.run", side_effect=cold), mock.patch(
            "strict_e2e_runner_support.time.monotonic", side_effect=lambda: clock[0]
        ), mock.patch("builtins.print"), self.assertRaises(CommandError):
            reset_simulator_app("SIM-UDID")
        self.assertEqual(clock[0], 600)
        self.assertFalse(set(calls) & {"terminate", "uninstall", "keychain", "privacy"})
        from strict_e2e_runner_support import prepare_simulator
        clock, calls = [0.0], []
        def submitted(command, **kwargs):
            calls.append(command[2])
            self.assertNotEqual(command[2], "boot", "an early-submitted boot must go straight to bootstatus")
            if command[2] == "bootstatus":
                self.assertEqual(kwargs["timeout"], 600)
                clock[0] += 197.2
            return subprocess.CompletedProcess(command, 2 if command[2] == "get_app_container" else 0, "", "")
        with mock.patch("strict_e2e_runner_support.subprocess.run", side_effect=submitted), mock.patch(
            "strict_e2e_runner_support.time.monotonic", side_effect=lambda: clock[0]
        ), mock.patch("builtins.print"):
            container, log = prepare_simulator("SIM-UDID", boot_submitted=True)
        self.assertIsNone(container)
        self.assertEqual(calls, ["bootstatus", "get_app_container"])
        self.assertIn("simulator-preparation: passed; elapsed=197.2s", log)
        calls.clear()
        with mock.patch("strict_e2e_runner_support.subprocess.run", side_effect=submitted), mock.patch(
            "strict_e2e_runner_support.time.monotonic", side_effect=lambda: clock[0]
        ), mock.patch("strict_e2e_runner_support.time.sleep"), mock.patch("builtins.print"):
            reset_simulator_app("SIM-UDID", boot_submitted=True)
        self.assertEqual(calls, ["bootstatus", "get_app_container", "uninstall", "get_app_container", "keychain", "privacy"])
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




class FailureDiagnosticsTests(unittest.TestCase):
    def test_hosted_flow_prefixes_publish_only_the_reviewed_phase_and_class(self):
        from ci_failure_diagnostics import (
            FAILURE_CLASSES, FAILURE_PHASES, PREFIX_RULES, classify_messages, unknown_diagnostics,
        )
        self.assertEqual(FAILURE_PHASES, {phase for _, phase, _ in PREFIX_RULES})
        self.assertEqual(FAILURE_CLASSES, {kind for _, _, kind in PREFIX_RULES})
        # Fixed expectations catch missing/misclassified rows; source checks catch stale prefixes.
        cases = (
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The first-boot page must show the Save Settings button.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "After a successful save, the app must reach mode selection.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "A fresh install must reach the normal first-boot page.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The first-boot page must show the API Key field.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The first-boot page must show the Test Connection button.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "Save must become enabled after a real connection test succeeds.", "firstboot_setup", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "A cold launch with saved settings must not return to the first-boot page.", "cold_relaunch", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "A configured cold launch must go straight to the playback page.", "cold_relaunch", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The mode page must offer ", "mode_selection", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "Chose filter but reached the playback page, so the mode card tap did not register.", "mode_selection", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "Still on the mode page after Continue; filter mode did not start.", "mode_selection", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "Filter mode must reach the filter summary page.", "mode_selection", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "Going back from the filter summary must return to mode selection.", "mode_selection", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Random mode must reach the playback page.", "playback_entry", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "The playback page must show the Previous button.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "After auto-advance, the playback controls must be revealable.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "The playback page must show Play/Pause.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "After pausing, the playback controls must still be revealable.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "After pausing, the control value must be play.", "control_action", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Resuming must continue from the current photo, with the control value back to pause.", "control_action", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Previous must be disabled at the history boundary when playback starts.", "history_navigation", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "After two Next taps, Previous must be enabled.", "history_navigation", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "After a pause of at least 10 seconds, autoplay must not resume on its own.", "paused_hold", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "probe_hit=MISS: frame-synchronized probe never saw outgoing translucent and incoming opacity=0 in 7 s.", "pause_window", "timing_window"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "visual_verdict=MISSING_FRAMES: missing a window-detected, after-pause, after-pause-0_3s or play-to-pause keepAlways frame.", "pause_window", "evidence_capture"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "visual_verdict=BLACK_OR_BLANK: synced probe missing after pause, or outgoing opacity already 0.", "pause_window", "probe_readback"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "After pausing, the synced probe does not meet outgoing opacity>0 and incoming opacity=0.", "pause_window", "probe_readback"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "The paused pause-window probe identity must not change.", "pause_window", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Paused pause-window frames must be pixel-identical.", "pause_window", "scene_identity"),
            ("immichSlidesUITests/StrictE2ELateImageIOSUITests.swift", "After late completion the current public mark must stay: no flash back, all black or unreadable: ", "late_image", "scene_identity"),
            ("immichSlidesUITests/StrictE2ELateImageIOSUITests.swift", "Next must be tappable twice right after entering the slideshow, before old image requests finish.", "late_image", "navigation"),
            ("immichSlidesUITests/ScenePresentationContractUITests.swift", "The fixture must actually deliver a failing image response", "image_recovery", "fixture_response"),
            ("immichSlidesUITests/ScenePresentationContractUITests.swift", "Fixture control must acknowledge its response mode", "image_recovery", "fixture_response"),
            ("immichSlidesUITests/ExifToggleUITests.swift", "After turning EXIF off, the info card in the upper-right area of the public photo must disappear from the screen.", "exif_ownership", "exif_visibility"),
            ("immichSlidesUITests/ExifToggleUITests.swift", "The required PNG with EXIF off still shows the info card.", "exif_ownership", "exif_visibility"),
            ("TestSupport/StrictE2EPhotoIdentity.swift", "Can't check EXIF: photo status ", "unknown", "scene_identity"),
            ("TestSupport/StrictE2EPhotoIdentity.swift", "EXIF does not match the photo: mark=", "unknown", "exif_correspondence"),
            ("immichSlidesUITests/IOSDriver.swift", "The EXIF toggle must reach the target state through the real settings.", "unknown", "control_state"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Default focus on the mode selection page must land on random playback.", "mode_selection", "focus"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Focus on the mode page must be able to move to filtered playback.", "mode_selection", "focus"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After choosing a mode, focus must be able to move down to the Continue button.", "mode_selection", "focus"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After returning to mode selection, default focus must go back to random playback.", "mode_selection", "focus"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After Continue, the app must reach the playback page and show the control bar.", "playback_entry", "navigation"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Before sending the wake arrow key, the hidden receiver layer must have system focus.", "hidden_controls", "focus"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After the control bar wakes again, focus must land on Play/Pause.", "hidden_controls", "focus"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After pressing Down, the hint and the control bar must hide.", "hidden_controls", "hidden_controls"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "With the control bar hidden, an arrow key must wake it again.", "hidden_controls", "hidden_controls"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Default focus on the filter summary must land on the album filter.", "filter_selection", "focus"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Focus must land on the target album.", "unknown", "focus"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Start Playback must be disabled with an empty selection.", "filter_selection", "control_state"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Start Playback must be disabled with 0 albums / 0 people.", "filter_selection", "control_state"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Start Playback must be enabled after selecting the target album.", "filter_selection", "control_state"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Filtered playback must be startable after selecting the target album", "filter_selection", "control_state"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "The album filter entry must be shown.", "unknown", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "The person filter entry must be shown.", "unknown", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Opening the album filter must show album cards or a loading state.", "unknown", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Back from the people list must return to the filter screen.", "filter_selection", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Back from the album list must return to the filter screen.", "unknown", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests+Support.swift", "Focus must land on the target person.", "filter_selection", "focus"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests+Support.swift", "Start Playback must open the playback screen.", "unknown", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Clear selection must actually receive remote focus", "filter_edit", "focus"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "The editor's Done must actually receive remote focus", "filter_edit", "focus"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "After Clear, both target and non-target albums must really become unselected; re-tapping each card must not stand in for the clear result", "filter_edit", "control_state"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "The filter settings editor must offer a Done entry", "filter_edit", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Finishing the edit must return to the real playback settings screen", "filter_edit", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "Server B must clear A's album selection", "server_switch", "control_state"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "After switching servers the UI must not keep server A album/person IDs: ", "server_switch", "control_state"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "The display mode's selected state must be read back.", "display_policy", "control_state"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "No two distinct photos seen within four public album candidates; all failing originals are kept.", "display_policy", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "After the change, a still frame taken mid-transition must not pass", "display_policy", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "After changing the display mode, playback must still be on screen in the same live process.", "display_policy", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterIOSUITests.swift", "No two distinct target-album photos were seen in one full four-frame candidate rotation; all candidate originals were kept.", "display_policy", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFilterIOSUITests.swift", "After the change it must be a stable single photo from the target album, not a transition or multi-photo", "display_policy", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFilterIOSUITests.swift", "The same live app process must run before and after the display policy change", "display_policy", "process_lifetime"),
            ("immichSlidesUITests/StrictE2EFilterIOSUITests.swift", "After the server switch, single-photo mode must show a stable single photo from B's target album", "server_switch", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFilterIOSUITests.swift", "The same process must run before and after applying single-photo mode after the server switch", "server_switch", "process_lifetime"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift", "SmartFill must expose the complete manifest, stable visible render state and history cursor together", "visible_scene_capture", "probe_readback"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift", "After tapping next, the fully visible SmartFill scene identity did not change in ", "history_navigation", "scene_identity"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift", "scene identity did not change", "history_navigation", "scene_identity"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests.swift", "Pausing must freeze the current transform progress", "paused_hold", "scene_identity"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests.swift", "The new scene from a manual next while paused must stay still at p=0", "paused_hold", "scene_identity"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests.swift", "The scene from a manual previous while paused must stay still at p=0", "paused_hold", "scene_identity"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests.swift", "Play must make the current still scene start moving from p=0 immediately", "control_action", "scene_identity"),
            ("immichSlidesUITests/FilterSummaryIOSVisualUITests+Launch.swift", "After starting playback, the playback page should open and show the control bar", "playback_entry", "navigation"),
        )
        failure_prefixes = {
            "A fresh install must reach the normal first-boot page.",
            "Chose filter but reached the playback page, so the mode card tap did not register.",
            "Still on the mode page after Continue; filter mode did not start.",
            "Filter mode must reach the filter summary page.",
            "Going back from the filter summary must return to mode selection.",
            "probe_hit=MISS: frame-synchronized probe never saw outgoing translucent and incoming opacity=0 in 7 s.",
            "visual_verdict=MISSING_FRAMES: missing a window-detected, after-pause, after-pause-0_3s or play-to-pause keepAlways frame.",
            "visual_verdict=BLACK_OR_BLANK: synced probe missing after pause, or outgoing opacity already 0.",
            "After pausing, the synced probe does not meet outgoing opacity>0 and incoming opacity=0.",
            "After late completion the current public mark must stay: no flash back, all black or unreadable: ",
            "Can't check EXIF: photo status ",
            "EXIF does not match the photo: mark=",
            "SmartFill must expose the complete manifest, stable visible render state and history cursor together",
            "After tapping next, the fully visible SmartFill scene identity did not change in ",
            "scene identity did not change",
        }
        false_prefixes = {
            "A cold launch with saved settings must not return to the first-boot page.",
            "Previous must be disabled at the history boundary when playback starts.",
            "Start Playback must be disabled with an empty selection.",
            "Start Playback must be disabled with 0 albums / 0 people.",
            "After switching servers the UI must not keep server A album/person IDs: ",
        }
        equal_prefixes = {
            "After a pause of at least 10 seconds, autoplay must not resume on its own.",
            "Fixture control must acknowledge its response mode",
            "The same live app process must run before and after the display policy change",
            "The same process must run before and after applying single-photo mode after the server switch",
            "Pausing must freeze the current transform progress",
        }
        caught_prefixes = {
            "No two distinct photos seen within four public album candidates; all failing originals are kept.",
            "No two distinct target-album photos were seen in one full four-frame candidate rotation; all candidate originals were kept.",
        }
        root = Path(__file__).resolve().parents[1]
        for source, prefix, phase, kind in cases:
            with self.subTest(source=source, prefix=prefix):
                self.assertIn('"' + prefix, (root / source).read_text())
                expected = {"failure_phase": phase, "failure_class": kind}
                # Match each wrapper to its public call site.
                if prefix in failure_prefixes:
                    wrappers = ("failed - ",)
                elif prefix in false_prefixes:
                    wrappers = ("XCTAssertFalse failed - ",)
                elif prefix in equal_prefixes:
                    wrappers = ("XCTAssertEqual failed: (PRIVATE_SENTINEL) - ",)
                elif prefix in caught_prefixes:
                    wrappers = ('failed: caught error: "message(\\"',)
                elif prefix == "The fixture must actually deliver a failing image response":
                    wrappers = ("XCTAssertGreaterThan failed: (PRIVATE_SENTINEL) - ",)
                elif prefix == "After the change, a still frame taken mid-transition must not pass":
                    wrappers = ("XCTAssertNotEqual failed: (PRIVATE_SENTINEL) - ",)
                else:
                    wrappers = ("XCTAssertTrue failed - ",)
                if prefix == "EXIF does not match the photo: mark=":
                    wrappers += ('failed: caught error: "message(\\"',)
                for wrapper in wrappers:
                    message = wrapper + prefix + " PRIVATE_SENTINEL /private/path asset-private"
                    if prefix in caught_prefixes or wrapper.startswith('failed: caught error:'):
                        message += '\\")"'
                    self.assertEqual(classify_messages([message]), expected)
                    self.assertEqual(classify_messages([message, message + " other-private-value"]), expected)
                    for conflicting in ("unreviewed PRIVATE_SENTINEL",
                                        "The iOS slider must be settable to PRIVATE_SENTINEL"):
                        self.assertEqual(classify_messages([message, conflicting]), unknown_diagnostics())
                        self.assertEqual(classify_messages([conflicting, message]), unknown_diagnostics())
        self.assertEqual(
            classify_messages(["failed - EXIF does not match the photo: mark=PRIVATE_SENTINEL"]),
            {"failure_phase": "unknown", "failure_class": "exif_correspondence"},
        )
        for message in (
            'Failure(message: "Fixture image response control timed out")',
            'failed: caught error: "Failure(message: \\"Fixture image response control timed out\\")"',
            'failed: caught error: "Fixture image response control timed out"',
            'failed: caught error: "message(\\"' + "Can\\'t check EXIF: photo status PRIVATE_SENTINEL" + '\\")"',
        ):
            with self.subTest(message=message):
                self.assertEqual(classify_messages([message]), unknown_diagnostics())

    def test_shared_export_without_opt_in_preserves_failed_bytes_and_two_export_budget(self):
        import subprocess
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            bundle = evidence / "private.xcresult"
            bundle.mkdir()
            payload = b'{"testNodes":[{"nodeType":"Test Case","nodeIdentifier":"Unit/works()","result":"Failed"}]}'
            commands = []
            def export(command, **kwargs):
                commands.append(command)
                self.assertEqual(kwargs["timeout"], 180)
                self.assertNotIn("--legacy", command)
                body = (json.dumps({"totalTestCount": 1, "passedTests": 0, "failedTests": 1,
                                    "skippedTests": 0, "result": "Failed"})
                        if "summary" in command else payload)
                return subprocess.CompletedProcess(command, 0, body, "" if kwargs.get("text") else b"")
            with mock.patch("run_strict_e2e.subprocess.run", side_effect=export):
                digest = strict_runner.export_private_result_bundle(
                    bundle, evidence, [], summary_timeout_seconds=180, export_timeout_seconds=180)
            self.assertEqual(len(commands), 2)
            self.assertEqual((evidence / "official-tests.json").read_bytes(), payload)
            self.assertEqual(digest, strict_runner.hashlib.sha256(payload).hexdigest())
            self.assertEqual(json.loads((evidence / "official-summary.json").read_text())["failedTests"], 1)

    def test_capture_and_control_state_assertions_do_not_claim_identity_or_navigation(self):
        from ci_failure_diagnostics import classify_messages, unknown_diagnostics
        for message in ("Screenshot must not be empty: before-background",
                        "Turning off Autoplay in settings must take effect immediately"):
            with self.subTest(message=message):
                self.assertEqual(classify_messages([message]), unknown_diagnostics())

    def test_official_warnings_do_not_replace_the_selected_method_failure_diagnostics(self):
        from ci_failure_diagnostics import legacy_diagnostics
        name = {"_value": "Flow.testFailure()"}
        payload = {"issues": {
            "testFailureSummaries": {"_values": [{"testCaseName": name,
                "message": {"_value": "failed - The iOS slider must be settable to 30 seconds."}}]},
            "testWarningSummaries": {"_values": [{"testCaseName": name,
                "message": {"_value": "private warning text"}}]}}}
        self.assertEqual(legacy_diagnostics(payload), {"Flow/testFailure": {
            "failure_phase": "interval_setup", "failure_class": "interval_readback"}})

    def test_reviewed_prefixes_map_private_values_and_unmatched_messages_stay_unknown(self):
        from ci_failure_diagnostics import classify_messages, PREFIX_RULES, unknown_diagnostics
        for prefix, phase, kind in PREFIX_RULES:
            with self.subTest(prefix=prefix):
                expected = {"failure_phase": phase, "failure_class": kind}
                # Exercise wrapper stripping; the test above uses the public call-site forms.
                for message in (prefix + " private-value", "XCTAssertTrue failed - " + prefix + " private-value",
                                'failed: caught error: "message(\\"' + prefix + '\\")"',
                                'failed - message("' + prefix + '")'):
                    self.assertEqual(classify_messages([message]), expected)
        for messages in ([], ["unreviewed private text"], ["interval_setup"], [None],
                         ["The iOS slider must be settable to 30 seconds.", "unreviewed private text"],
                         ["The iOS slider must be settable to 30 seconds.", "Failed to get matching snapshot"]):
            with self.subTest(messages=messages):
                self.assertEqual(classify_messages(messages), unknown_diagnostics())
        self.assertEqual(classify_messages(["XCTAssertTrue failed - The iOS slider must be settable to 30 seconds."]),
                         {"failure_phase": "interval_setup", "failure_class": "interval_readback"})
        self.assertEqual(classify_messages(["Failed to get matching snapshot: PRIVATE_SENTINEL"]),
                         {"failure_phase": "unknown", "failure_class": "snapshot_query"})
        self.assertEqual(classify_messages(["XCTAssertEqual failed: (PRIVATE_SENTINEL) - After pausing, the rendered transform/frame of every SmartFill slot must stay frozen"]),
                         {"failure_phase": "paused_hold", "failure_class": "scene_identity"})
        self.assertEqual(
            classify_messages(['failed - message("System pause analog must not rebuild the process")']),
            {"failure_phase": "background_return", "failure_class": "process_lifetime"},
        )

    def test_private_export_and_tracer_publish_only_enums_without_changing_failure(self):
        import subprocess
        from run_strict_ci_tracer import validate_case_export
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            name = "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke"
            payload = {"testNodes": [{"nodeType": "Unit test bundle", "name": "immichSlidesUITests", "children": [
                {"nodeType": "Test Case", "nodeIdentifier": name + "()", "result": "Failed"}]}]}
            legacy = {"issues": {"testFailureSummaries": {"_values": [{
                "testCaseName": {"_value": name.replace("/", ".") + "()"},
                "message": {"_value": "XCTAssertTrue failed - The iOS slider must be settable to 30 seconds. PRIVATE_SENTINEL"}}]}}}
            def export(command, **kwargs):
                return subprocess.CompletedProcess(command, 0, json.dumps(legacy if "--legacy" in command else payload).encode(), b"")
            summary = TestResultsSummary(1, 0, 1, 0, "Failed")
            with mock.patch("run_strict_e2e.subprocess.run", side_effect=export), \
                    mock.patch("run_strict_e2e.read_official_test_results_summary", return_value=summary):
                strict_runner.export_private_result_bundle(evidence / "private.xcresult", evidence, ["PRIVATE_SENTINEL"],
                                                           enrich_failure_diagnostics=True)
            exported = (evidence / "official-tests.json").read_text()
            self.assertNotIn("PRIVATE_SENTINEL", exported)
            self.assertNotIn("slider", exported)
            self.assertEqual(validate_case_export(evidence, "ios", "smoke"), [{"identifier": name, "result": "Failed",
                "failure_phase": "interval_setup", "failure_class": "interval_readback"}])
            strict_runner.write_sensitive_scan(evidence, ["PRIVATE_SENTINEL"])
            self.assertEqual(json.loads((evidence / "sensitive-scan.json").read_text())["result"], "PASS")

    def test_scanner_accepts_enums_and_rejects_free_text_even_without_credentials(self):
        from ci_failure_diagnostics import FAILURE_PHASES, FAILURE_CLASSES
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            path = evidence / "record.json"
            for phase in FAILURE_PHASES:
                for kind in FAILURE_CLASSES:
                    path.write_text(json.dumps({"methods": [{"failure_phase": phase, "failure_class": kind}]}))
                    strict_runner.write_sensitive_scan(evidence, ["PRIVATE_SENTINEL"])
            for value in ("private assertion text", "interval_setup PRIVATE_SENTINEL", None, ["unknown"]):
                for field in ("failure_phase", "failure_class"):
                    with self.subTest(field=field, value=value):
                        path.write_text(json.dumps({"failure_phase": "unknown", "failure_class": "unknown", field: value}))
                        with self.assertRaises(CommandError):
                            strict_runner.write_sensitive_scan(evidence, ["PRIVATE_SENTINEL"])
                        self.assertEqual(json.loads((evidence / "sensitive-scan.json").read_text())["result"], "FAIL")
            for raw_json in ('{"failure_phase":"private text","failure_phase":"unknown","failure_class":"unknown"}',
                             '{"failure_phase":"unknown"}', '{"failure_phase":"private text"'):
                with self.subTest(raw_json=raw_json):
                    path.write_text(raw_json)
                    with self.assertRaises(CommandError):
                        strict_runner.write_sensitive_scan(evidence, ["PRIVATE_SENTINEL"])

    def test_scanner_checks_validator_receipts_including_duplicate_and_malformed_json(self):
        message = "unreadable public glyph slot; slot 1 (horizontal); screenshot person-normal.png"
        overlong = ("no public glyph; screenshot person-normal.png" + "; context unresolved" * 16
                    + "; slot 1 (horizontal)" * 7).replace("slot 1 (", "slot 10 (", 1)
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            path = evidence / "record.json"
            for value in (message, "unresolved", "[redacted validator failure]"):
                path.write_text(json.dumps({"validator_failure_message": value}))
                strict_runner.write_sensitive_scan(evidence, ["PRIVATE_SENTINEL"])
                self.assertEqual("PASS", json.loads((evidence / "sensitive-scan.json").read_text())["result"])
            for raw_json in (json.dumps({"validator_failure_message": message + "; server 192.0.2.1"}),
                             json.dumps({"validator_failure_message": message + "; pixels (0, 0, 0)"}),
                             json.dumps({"validator_failure_message": overlong}),
                             '{"validator_failure_message":"unresolved","validator_failure_message":"unresolved"}',
                             '{"validator_failure_message":"unresolved"'):
                with self.subTest(raw_json=raw_json):
                    path.write_text(raw_json)
                    with self.assertRaisesRegex(CommandError, "redaction scan found") as raised:
                        strict_runner.write_sensitive_scan(evidence, ["PRIVATE_SENTINEL"])
                    self.assertNotIn("192.0.2.1", str(raised.exception))
                    self.assertEqual("FAIL", json.loads((evidence / "sensitive-scan.json").read_text())["result"])

    def test_validator_receipt_vocabularies_match_contract_sources(self):
        import ast
        import ci_failure_diagnostics as diagnostics
        from strict_e2e_filter_manifest import FROZEN_FIXTURE_SHA256
        from strict_e2e_photo_identity import MARKS

        def tree(name):
            return ast.parse((SCRIPT_DIR / name).read_text())

        def fixed_messages(module):
            messages = set()
            for node in ast.walk(module):
                argument = None
                if isinstance(node, ast.Raise) and isinstance(node.exc, ast.Call) and node.exc.args:
                    argument = node.exc.args[0]
                elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                      and node.func.id == "_require_named_png"):
                    argument = node.args[2]
                if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
                    messages.add(argument.value)
            return messages

        original_modules = ("album_server_narrow_contract.py", "strict_e2e_photo_identity.py",
                            "strict_e2e_filter_contract.py")
        self.assertEqual(set(diagnostics.VALIDATOR_FIXED_PREFIXES),
                         set().union(*(fixed_messages(tree(name)) for name in original_modules)))
        self.assertEqual(set(diagnostics.VALIDATOR_MANIFEST_PREFIXES),
                         fixed_messages(tree("strict_e2e_filter_manifest.py")))
        identity_tree = tree("strict_e2e_photo_identity.py")
        classifier = next(node for node in identity_tree.body
                          if isinstance(node, ast.FunctionDef) and node.name == "classify_screenshot")
        identities = [node for node in ast.walk(classifier) if isinstance(node, ast.Call)
                      and isinstance(node.func, ast.Name) and node.func.id == "PhotoIdentity"]
        self.assertEqual(set(diagnostics.VALIDATOR_IDENTITY_STATUSES),
                         {ast.literal_eval(node.args[0]) for node in identities})
        self.assertEqual(set(diagnostics.VALIDATOR_IDENTITY_MARKS), set(MARKS) | {
            ast.literal_eval(node.args[1]) for node in identities if isinstance(node.args[1], ast.Constant)})
        pattern_classifier = next(node for node in identity_tree.body
                                  if isinstance(node, ast.FunctionDef) and node.name == "classify_public_pattern")
        patterns = {node.value.value for node in ast.walk(pattern_classifier)
                    if isinstance(node, ast.Return) and isinstance(node.value, ast.Constant)}
        self.assertEqual(set(diagnostics.VALIDATOR_FIXTURE_PATTERNS), patterns)
        self.assertEqual(set(diagnostics.VALIDATOR_FIXTURE_PATTERNS), set(FROZEN_FIXTURE_SHA256) | {None})

    def test_closed_server_switch_failures_are_public_and_unknown_values_redact(self):
        from album_server_narrow_contract import AlbumServerContractError, evaluate_server_switch_evidence
        from strict_e2e_filter_manifest import FilterContractError
        from test_album_server_narrow_contract import _fixture_png, _side_by_side, _write_server_switch_pass
        from ci_failure_diagnostics import public_validator_failure_message

        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            _write_server_switch_pass(evidence)
            (evidence / "switch-b-play-1.png").write_bytes(
                _side_by_side(_fixture_png("A1", "a"), _fixture_png("A1", "b")))
            with self.assertRaisesRegex(AlbumServerContractError,
                                       "^switch-b-play-1 public pattern must be b, got None$") as raised:
                evaluate_server_switch_evidence(evidence)
            pattern_message = str(raised.exception)
            self.assertEqual(pattern_message + "; context unresolved", public_validator_failure_message(pattern_message))

            _write_server_switch_pass(evidence)
            manifest_path = evidence / "member-manifest-b.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["fixture_sha256"] = "0" * 64
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(FilterContractError,
                                       "^member manifest fixture hash does not match the frozen contract$") as raised:
                evaluate_server_switch_evidence(evidence)
            manifest_message = str(raised.exception)
            self.assertEqual(manifest_message + "; context unresolved", public_validator_failure_message(manifest_message))

            _write_server_switch_pass(evidence)
            (evidence / "switch-b-play-1.png").write_bytes(b"unreadable public fixture")
            with self.assertRaisesRegex(FilterContractError,
                                       "^Unrecognizable input cannot count as passing: status=UNRECOGNIZABLE mark=None$") as raised:
                evaluate_server_switch_evidence(evidence)
            identity_message = str(raised.exception)
            self.assertEqual(identity_message + "; context unresolved", public_validator_failure_message(identity_message))
        for message in (pattern_message.replace("switch-b-play-1", "private-screenshot"),
                        pattern_message.replace("must be b", "must be private-pattern"),
                        pattern_message.replace("got None", "got private-pattern"),
                        identity_message.replace("UNRECOGNIZABLE", "private-status"),
                        identity_message.replace("mark=None", "mark=private-mark")):
            with self.subTest(message=message):
                self.assertEqual("[redacted validator failure]", public_validator_failure_message(message))

    def test_real_contract_failures_keep_public_context_and_redact_dynamic_identifiers(self):
        from album_server_narrow_contract import AlbumServerContractError, evaluate_server_switch_evidence
        from strict_e2e_filter_contract import FilterContractError, evaluate_filter_visual_identity
        from strict_e2e_photo_identity import IdentityAssertionError, public_frame_photos_from_bytes
        from strict_e2e_filter_contract_test_fixtures import _write_person_suite
        from test_album_server_narrow_contract import _fixture_png, _write_server_switch_pass
        from test_strict_e2e_photo_identity import FrameGlyphBoundaryTests
        from ci_failure_diagnostics import public_validator_failure_message, validate_validator_failure_message
        frame = FrameGlyphBoundaryTests._pair("a", 2, 3, horizontal=True, unreadable_slot=1)
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            _write_server_switch_pass(evidence)
            (evidence / "server-switch-a-play-1.png").write_bytes(frame)
            with self.assertRaisesRegex(AlbumServerContractError, "^unreadable public glyph slot") as raised:
                evaluate_server_switch_evidence(evidence)
            message = str(raised.exception)
            validate_validator_failure_message(message)
            self.assertEqual(message, public_validator_failure_message(message))
            self.assertIn("screenshot server-switch-a-play-1.png", message)
            _write_person_suite(evidence, conflict=["A1", "A2", "A3"])
            (evidence / "person-normal.png").write_bytes(frame)
            with self.assertRaisesRegex(FilterContractError, "^unreadable public glyph slot") as raised:
                evaluate_filter_visual_identity(evidence, "tvos-person", fixture_set="a")
            message = str(raised.exception)
            validate_validator_failure_message(message)
            self.assertEqual(message, public_validator_failure_message(message))
            self.assertIn("screenshot person-normal.png", message)
            _write_server_switch_pass(evidence)
            (evidence / "display-before.png").write_bytes(_fixture_png("A1", "b"))
            with self.assertRaisesRegex(AlbumServerContractError, "^The fixture yields no multi-photo screen;") as raised:
                evaluate_server_switch_evidence(evidence)
            message = str(raised.exception) + "; context unresolved"
            validate_validator_failure_message(message)
            self.assertEqual(message, public_validator_failure_message(str(raised.exception)))
            _write_server_switch_pass(evidence)
            (evidence / "observed-ids.json").write_text(json.dumps({
                "identity_source": "ui_accessibility_identifier", "ids": ["album-a-private-name"],
                "raw_identifiers": ["albumFilter.album.album-a-private-name.button"]}))
            with self.assertRaisesRegex(FilterContractError, "^Cross-server stale IDs remain:") as raised:
                evaluate_server_switch_evidence(evidence)
            self.assertEqual("[redacted validator failure]", public_validator_failure_message(str(raised.exception)))
        with self.assertRaisesRegex(IdentityAssertionError, "^unreadable public glyph: UnidentifiedImageError$") as raised:
            public_frame_photos_from_bytes(b"unreadable fixture")
        message = str(raised.exception) + "; context unresolved"
        validate_validator_failure_message(message)
        self.assertEqual(message, public_validator_failure_message(str(raised.exception)))
        self.assertEqual("[redacted validator failure]",
                         public_validator_failure_message("unreadable public glyph: PrivateServerError; context unresolved"))

    def test_diagnostic_read_failure_retains_official_failure_and_unknown_enums(self):
        import subprocess
        from ci_failure_diagnostics import unknown_diagnostics
        for private_failure in (ValueError("PRIVATE_SENTINEL"), subprocess.TimeoutExpired("private-command", 60)):
            with self.subTest(private_failure=type(private_failure).__name__), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                payload = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "Flow/testFailure()", "result": "Failed"}]}
                def export(command, **kwargs):
                    if "--legacy" in command:
                        raise private_failure
                    return subprocess.CompletedProcess(command, 0, json.dumps(payload).encode(), b"")
                with mock.patch("run_strict_e2e.subprocess.run", side_effect=export), \
                        mock.patch("run_strict_e2e.read_official_test_results_summary", return_value=TestResultsSummary(1, 0, 1, 0, "Failed")):
                    digest = strict_runner.export_private_result_bundle(evidence / "private.xcresult", evidence, ["PRIVATE_SENTINEL"],
                                                                        enrich_failure_diagnostics=True)
                node = json.loads((evidence / "official-tests.json").read_text())["testNodes"][0]
                self.assertEqual({field: node[field] for field in unknown_diagnostics()}, unknown_diagnostics())
                self.assertEqual(node["result"], "Failed")
                self.assertEqual(json.loads((evidence / "official-summary.json").read_text())["failedTests"], 1)
                self.assertEqual(digest, strict_runner.hashlib.sha256((evidence / "official-tests.json").read_bytes()).hexdigest())
                self.assertNotIn("PRIVATE_SENTINEL", (evidence / "official-tests.json").read_text())


class StrictCITracerTests(unittest.TestCase):
    def _produce_validator_records(self, directory, error, *, verdict="FAIL", runner_exit=2,
                                   receipt_suite="tvos-server-switch-display", nightly=False):
        import run_strict_ci_tracer as tracer
        case = {"platform": "tvos", "device": "tv", "configuration": "Debug",
                "suite": "tvos-server-switch-display", "scenario": "normal", "fixture": "a"}
        identity = {"schema_version": 1, "event": "local", "repository": "sudoHG/immichSlides",
                    "commit_sha": "0" * 40, "tree_sha": "0" * 40, "dirty": False}
        output = directory / "trace"
        manifest = directory / "manifest.json"
        manifest.write_text(json.dumps({"cases": [case], "exclusions": []}))
        options = []
        if nightly:
            from ci_nightly import parse_manifest, shards
            matrix = json.loads((tracer.ROOT / "scripts/nightly-matrix.json").read_text())
            matrix["shard_size"] = 1
            selected = next(shard for shard in shards(parse_manifest(matrix)) if shard["cases"] == [case])
            manifest.write_text(json.dumps(matrix))
            options = ["--shard", selected["id"]]
            identity = {"schema_version": 1, "event": "schedule", "repository": "sudoHG/immichSlides",
                        "ref": "refs/heads/main", "commit_sha": "0" * 40, "tree_sha": "0" * 40}

        def runner(command, *_args, **_kwargs):
            derived = Path(command[command.index("--derived-data-path") + 1])
            evidence = Path(command[command.index("--evidence-dir") + 1])
            if "--warm-up-only" in command:
                derived.mkdir(parents=True)
                (derived / "strict-warm-build.json").write_text(json.dumps({"signing_mode": "adhoc"}))
                return 0
            evidence.mkdir(parents=True)
            (evidence / "case-manifest.json").write_text(json.dumps({"infrastructure": []}))
            if receipt_suite is not None:
                message = error(evidence) if callable(error) else error
                (evidence / "visual-identity-runner.json").write_text(json.dumps({
                    "suite": receipt_suite, "verdict": verdict, "error": message}))
            (evidence / "xcodebuild.log").write_text("test-without-building\n")
            (evidence / "xcodebuild-reuse.json").write_text(json.dumps({"products_unchanged": True}))
            (evidence / "official-summary.json").write_text(json.dumps({"totalTestCount": 1, "passedTests": 1,
                "failedTests": 0, "skippedTests": 0, "result": "Passed"}))
            selector = tracer.resolve_suite_selector(case["platform"], case["suite"])
            bundle, method = selector.split("/", 1)
            (evidence / "official-tests.json").write_text(json.dumps({"testNodes": [{
                "nodeType": "Unit test bundle", "name": bundle, "children": [{
                    "nodeType": "Test Case", "nodeIdentifier": method + "()", "result": "Passed"}]}]}))
            return runner_exit

        with mock.patch.object(tracer, "run_runner", side_effect=runner), \
                mock.patch.object(tracer, "workspace_preflight"), mock.patch.object(tracer, "run_identity", return_value=identity), \
                mock.patch.object(tracer, "source_metadata", return_value=(".github/workflows/ci-nightly.yml" if nightly else None, False)), \
                mock.patch.object(tracer.shutil, "disk_usage", return_value=mock.Mock(total=200 * 1024**3, free=100 * 1024**3)), \
                mock.patch.object(tracer, "toolchain", return_value={"versions": {"python": "test"}, "signing_mode": "not-applicable"}), \
                mock.patch.dict(os.environ, {"GITHUB_RUN_ID": "10", "GITHUB_RUN_ATTEMPT": "1"}):
            exit_code = tracer.main(["--platform", "tvos", "--destination", "unused", "--manifest", str(manifest),
                                     "--output-dir", str(output)] + options)
        return exit_code, output / "records", json.loads((output / "records/trace.json").read_text()), \
            json.loads((output / "records/summary.json").read_text())

    def test_tracer_redacts_private_validator_errors_before_writing_public_records(self):
        from ci_nightly import aggregate_nightly
        private_values = ("https://private.invalid/api", "/private/validator/secret.json", "asset-private-nonfixture", "192.0.2.1")
        message = "switch-b-play-1 public pattern must be b, got None; context unresolved"
        cases = [(message + "; " + value, "[redacted validator failure]") for value in private_values]
        for error, expected in cases + [(None, "unresolved")]:
            with self.subTest(error=error), tempfile.TemporaryDirectory() as raw:
                exit_code, records, trace, summary = self._produce_validator_records(Path(raw), error)
                self.assertEqual(1, exit_code)
                self.assertEqual("failed", summary["status"])
                phase = trace["warm"][0]
                self.assertEqual(2, phase["exit_code"])
                self.assertTrue(phase["automated_contract_failed"])
                self.assertEqual("Passed", phase["official_summary"]["result"])
                self.assertEqual(expected, phase.get("validator_failure_message"))
                failed = summary["population"]["observed"][0]
                self.assertEqual(("failed", 2), (failed["outcome"], failed["attempts"][0]["exit_code"]))
                self.assertEqual(expected, failed.get("validator_failure_message"))
                self.assertEqual(expected, failed["attempts"][0].get("validator_failure_message"))
                aggregate = aggregate_nightly(summary["population"]["declared"], [summary], live_in_scope=False)
                self.assertEqual(expected, aggregate["observed"][0].get("validator_failure_message"))
                self.assertEqual(expected, aggregate["observed"][0]["attempts"][0].get("validator_failure_message"))
                for path in records.iterdir():
                    for value in private_values:
                        self.assertNotIn(value, path.read_text())
                for value in private_values:
                    self.assertNotIn(value, json.dumps(aggregate))

    def test_real_validator_failure_reaches_nightly_aggregation_and_report(self):
        from html import unescape
        import ci_report
        from ci_nightly import aggregate_nightly
        from album_server_narrow_contract import AlbumServerContractError, evaluate_server_switch_evidence
        from test_album_server_narrow_contract import _fixture_png, _side_by_side, _write_server_switch_pass

        def fail_contract(evidence):
            _write_server_switch_pass(evidence)
            (evidence / "switch-b-play-1.png").write_bytes(
                _side_by_side(_fixture_png("A1", "a"), _fixture_png("A1", "b")))
            with self.assertRaisesRegex(AlbumServerContractError,
                                       "^switch-b-play-1 public pattern must be b, got None$") as raised:
                evaluate_server_switch_evidence(evidence)
            return str(raised.exception)

        expected = "switch-b-play-1 public pattern must be b, got None; context unresolved"
        with tempfile.TemporaryDirectory() as raw:
            exit_code, _records, trace, summary = self._produce_validator_records(Path(raw), fail_contract, nightly=True)
            self.assertEqual(1, exit_code)
            self.assertEqual(expected, trace["warm"][0].get("validator_failure_message"))
            failed = summary["population"]["observed"][0]
            self.assertEqual(expected, failed.get("validator_failure_message"))
            self.assertEqual(expected, failed["attempts"][0].get("validator_failure_message"))
            aggregate = aggregate_nightly(summary["population"]["declared"], [summary], live_in_scope=False)
            self.assertEqual(expected, aggregate["observed"][0].get("validator_failure_message"))
            shard = summary["run"]["shard"]
            aggregate.update(identity=summary["identity"], hashes=summary["hashes"], source=summary["source"],
                             run={"id": "10", "attempt": 1}, capacity={"shard_intervals": [{"shard": shard}]})
            api = type("API", (), {"repository": "sudoHG/immichSlides"})()
            run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-01T10:00:00Z",
                   "head_sha": summary["identity"]["commit_sha"], "path": ci_report.NIGHTLY_PATH,
                   "event": "schedule", "head_branch": "main", "head_repository": {"full_name": api.repository},
                   "status": "completed", "conclusion": "failure"}
            artifacts = [{"name": name, "expired": False}
                         for name in ("nightly-aggregate-10-1", f"nightly-strict-{shard}-10-1")]
            with mock.patch("ci_publish.json_member", side_effect=[aggregate, summary, trace]):
                report = ci_report.nightly_attempt(api, run, 1, artifacts)
            self.assertEqual([], report["diagnostics"]["missing"])
            self.assertEqual([], report["diagnostics"]["infrastructure"])
            contract = next(item for item in report["observed"] if item["identity"] == failed["identity"])
            self.assertEqual(("failed", 2, "strict-case-contract-failed"),
                (contract["outcome"], contract["attempts"][0]["exit_code"], contract["attempts"][0]["reason"]))
            self.assertEqual(expected, contract.get("validator_failure_message"))
            self.assertEqual(expected, contract["attempts"][0].get("validator_failure_message"))
            compact = ci_report.compact_entry(report, set())
            self.assertEqual(expected, compact["observed"][-1].get("validator_failure_message"))
            self.assertIn(expected, unescape(ci_report.render_entry(compact)))

    def test_tracer_omits_receipts_without_both_a_failed_contract_and_failed_case(self):
        for changed in ({"verdict": "PASS"}, {"receipt_suite": "smoke"}, {"receipt_suite": None}, {"runner_exit": 0}):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as raw:
                exit_code, _records, trace, summary = self._produce_validator_records(Path(raw), "no public glyph", **changed)
                self.assertEqual(0 if changed.get("runner_exit") == 0 else 1, exit_code)
                self.assertNotIn("validator_failure_message", trace["warm"][0])
                observed = summary["population"]["observed"][0]
                self.assertNotIn("validator_failure_message", observed)
                self.assertNotIn("validator_failure_message", observed["attempts"][0])

    def test_preparation_failure_records_every_planned_case_without_starting_a_runner(self):
        import run_strict_ci_tracer as tracer
        from ci_nightly import case_identity, parse_manifest, shards, validate_shard
        from ci_review_packages import export_shard
        from ci_summary import parse_summary
        identity = {"schema_version": 1, "event": "local", "repository": "sudoHG/immichSlides",
                    "commit_sha": "0" * 40, "tree_sha": "0" * 40, "dirty": False}
        selected = next(shard for shard in shards(parse_manifest(tracer.ROOT.joinpath("scripts/nightly-matrix.json").read_text()))
                        if shard["id"] == "ipad-immichSlides-iOS-debug-4")
        expected = [case_identity(case) for case in selected["cases"]]
        with tempfile.TemporaryDirectory() as raw, mock.patch.object(tracer, "run_runner") as runner, \
                mock.patch.object(tracer, "workspace_preflight"), mock.patch.object(tracer, "run_identity", return_value=identity), \
                mock.patch.object(tracer, "source_metadata", return_value=(None, False)), \
                mock.patch.object(tracer, "toolchain", return_value={"versions": {"python": "test"}, "signing_mode": "not-applicable"}):
            output = Path(raw) / "trace"
            self.assertEqual(1, tracer.main(["--platform", "ios", "--destination", "unavailable",
                "--manifest", str(tracer.ROOT / "scripts/nightly-matrix.json"), "--shard", selected["id"],
                "--output-dir", str(output), "--preparation-failed"]))
            runner.assert_not_called()
            summary = parse_summary((output / "records/summary.json").read_text())
            validate_shard(summary, identity, summary["run"], summary["hashes"], expected)
            self.assertEqual(expected, summary["population"]["declared"])
            self.assertEqual([], summary["population"]["compiled"])
            self.assertEqual(expected, [entry["identity"] for entry in summary["population"]["observed"]])
            self.assertEqual("failed", summary["status"])
            self.assertEqual("simulator-preparation-failed", summary["infrastructure"][0]["code"])
            for entry in summary["population"]["observed"]:
                self.assertEqual("failed", entry["outcome"])
                self.assertEqual("not-run", entry["attempts"][0]["outcome"])
                self.assertIsNone(entry["attempts"][0]["exit_code"])
                self.assertIn("infrastructure", entry["attempts"][0]["reason"])
                self.assertEqual(0, entry["duration_seconds"])
            trace = json.loads((output / "records/trace.json").read_text())
            self.assertEqual([], trace["cold"])
            self.assertEqual([], trace["warm"])
            self.assertGreaterEqual(trace["finished_epoch"], trace["started_epoch"])
            self.assertEqual(0, export_shard(output, Path(raw) / "packages"))
            self.assertEqual([], json.loads((output / "records/p2-review-bindings.json").read_text())["review_packages"])

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
                    from strict_e2e_runner_support import SIMULATOR_READINESS_TIMEOUT_SECONDS, SIMULATOR_RESET_TIMEOUT_SECONDS
                    execution_budget = int(command[command.index("--warm-timeout-seconds") + 1])
                    self.assertGreaterEqual(_kwargs["timeout_seconds"], execution_budget + SIMULATOR_READINESS_TIMEOUT_SECONDS
                                            + SIMULATOR_RESET_TIMEOUT_SECONDS)
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
                        mock.patch.object(tracer.shutil, "disk_usage", return_value=mock.Mock(total=200 * 1024**3, free=100 * 1024**3)), \
                        mock.patch.object(tracer, "toolchain", return_value={"versions": {"python": "test"}, "signing_mode": "not-applicable"}):
                    self.assertEqual(tracer.main(["--platform", "ios", "--destination", "unused", "--manifest", str(manifest),
                                                  "--output-dir", str(output)]), 1)
                summary = json.loads((output / "records/summary.json").read_text())
                trace = json.loads((output / "records/trace.json").read_text())
                self.assertEqual(summary["population"]["compiled"], summary["population"]["declared"])
                self.assertEqual(summary["population"]["observed"][0]["outcome"], "failed")
                self.assertEqual(trace["warm"][0]["official_summary"]["totalTestCount"], 1)
                method = {"identifier": "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke", "result": official_result}
                if official_result == "Failed":
                    method.update(failure_phase="unknown", failure_class="unknown")
                self.assertEqual([method],
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
            self.assertEqual([{"identifier": "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke", "result": "Failed",
                               "failure_phase": "unknown", "failure_class": "unknown"}],
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
                "run_strict_ci_tracer.shutil.disk_usage", return_value=mock.Mock(total=200 * 1024**3, free=100 * 1024**3)
            ), mock.patch(
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
