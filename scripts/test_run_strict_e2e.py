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
    def test_fixture_build_has_its_own_deadline_before_health_and_cannot_hide_failures(self):
        import strict_e2e_runner_support as support
        from run_fixture_ui_tests import SERVICE_FIXTURE_BUILD_TIMEOUT_SECONDS, SERVICE_STARTUP_TIMEOUT_SECONDS
        for state in ("slow-build", "build-exit", "import-exit", "bind-exit", "unknown-exit",
                      "build-timeout", "late-build", "health-timeout", "strict-build-timeout", "strict-health-timeout"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                clock = [0.0]
                # Hosted build/health timeouts were censored at 126.6/68.3 seconds.
                build_seconds = 1 if state == "strict-health-timeout" else 127
                budgets = {} if state.startswith("strict-") else {
                    "fixture_build_timeout_seconds": SERVICE_FIXTURE_BUILD_TIMEOUT_SECONDS,
                    "startup_timeout_seconds": SERVICE_STARTUP_TIMEOUT_SECONDS}
                build_budget = budgets.get("fixture_build_timeout_seconds", 120)
                health_budget = budgets.get("startup_timeout_seconds", 60)
                startup_log = Path(directory, "startup.log")
                started = "fixture-startup: phase=fixture-build; state=started; elapsed=0.000s; total=0.000s\n"
                completed = f"fixture-startup: phase=fixture-build; state=completed; elapsed={build_seconds:.3f}s; total={build_seconds:.3f}s\n"
                exit_phase = {"build-exit": "fixture-build", "import-exit": "import",
                              "bind-exit": "bind", "unknown-exit": "unknown"}.get(state)
                initial = ("" if state == "unknown-exit" else
                           started.replace("fixture-build", "import") if state == "import-exit" else
                           started + completed + started.replace("fixture-build", "bind") if state == "bind-exit" else started)
                startup_log.write_text(initial)
                real_open, late_reads = Path.open, []
                def open_log(path, mode="r", *args, **kwargs):
                    if state == "late-build" and path == startup_log and mode == "rb" and not late_reads:
                        with real_open(path) as handle:
                            self.assertEqual(handle.read(), started)
                        late_reads.append(clock[0])
                        clock[0] = build_budget + 1
                        with real_open(path, "w") as handle:
                            handle.write(started + completed)
                    return real_open(path, mode, *args, **kwargs)
                def sleep(seconds):
                    previous = clock[0]
                    clock[0] += seconds
                    if state not in ("build-exit", "build-timeout", "late-build") and previous < build_seconds <= clock[0]:
                        startup_log.write_text(started + completed)
                process = mock.Mock(pid=7)
                process.poll.side_effect = lambda: 3 if exit_phase and (state != "build-exit" or clock[0] >= 20) else None
                ready = mock.Mock()
                ready.is_file.side_effect = lambda: clock[0] >= build_seconds
                ready.read_text.return_value = json.dumps({"pid": 7, "host": "127.0.0.1", "port": 1234})
                response = mock.MagicMock()
                def request(*args, **kwargs):
                    response.__enter__.return_value.status = 200 if state != "health-timeout" and clock[0] >= build_seconds + 69 else 503
                    return response
                with mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                        mock.patch.object(support.time, "sleep", side_effect=sleep), \
                        mock.patch.object(Path, "open", new=open_log), \
                        mock.patch.object(support.urllib.request, "urlopen", side_effect=request) as query, \
                        mock.patch("builtins.print") as report:
                    if state == "slow-build":
                        self.assertEqual(support.wait_for_service(ready, process, startup_log=startup_log, **budgets), ("127.0.0.1", 1234))
                        self.assertAlmostEqual(clock[0], 196, delta=.1)
                        self.assertTrue(any("build completed;" in call.args[0] and "budget=" in call.args[0]
                                            for call in report.call_args_list))
                    else:
                        message = (f"exited early during {exit_phase} with exit 3" if exit_phase else
                                   "health check timed out" if state in ("health-timeout", "strict-health-timeout") else "fixture build timed out")
                        with self.assertRaisesRegex(CommandError, message) as error:
                            support.wait_for_service(ready, process, startup_log=startup_log, **budgets)
                        if state in ("health-timeout", "strict-health-timeout"):
                            self.assertAlmostEqual(clock[0], build_seconds + health_budget, delta=.1)
                        else:
                            query.assert_not_called()
                            if state in ("build-timeout", "strict-build-timeout"):
                                self.assertAlmostEqual(clock[0], build_budget, delta=.1)
                        self.assertEqual(error.exception.code, 2 if exit_phase else 124)
                        if state == "late-build":
                            self.assertEqual(late_reads, [0.0])
                            self.assertEqual(startup_log.read_text(), started + completed)

    def test_service_timeout_reports_only_bounded_allowlisted_startup_phases(self):
        import strict_e2e_runner_support as support
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            startup_log = root / "startup.log"
            safe = ("fixture-startup: phase=fixture-build; state=started; elapsed=0.000s; total=0.123s\n"
                    "fixture-startup: phase=fixture-build; state=completed; elapsed=0.001s; total=0.124s")
            startup_log.write_text("private-input /private/path\n" + safe + "\n" +
                safe.splitlines()[0] + " private-input\n" + "x" * 4096 + "\n" +
                "fixture-startup: phase=ready-write; state=completed; elapsed=0.001s; total=0.124s\n")
            clock = [0.0]
            process = mock.Mock(pid=7)
            process.poll.return_value = None
            with mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                    mock.patch.object(support.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                    mock.patch("builtins.print") as report, self.assertRaisesRegex(CommandError, "health check timed out") as error:
                support.wait_for_service(root / "ready.json", process, startup_log=startup_log)
            output = "\n".join(call.args[0] for call in report.call_args_list)
            build_budget = support.SERVICE_FIXTURE_BUILD_TIMEOUT_SECONDS
            self.assertEqual(output, f"fixture-service: build started; budget={build_budget}s\n"
                             f"fixture-service: build completed; elapsed=0.0s; budget={build_budget}s\n" + safe)
            self.assertNotIn("private-input", str(error.exception) + output)
            self.assertIn("startup_phase=fixture-build; startup_state=completed", str(error.exception))
            self.assertEqual(error.exception.code, 124)
            self.assertAlmostEqual(clock[0], support.SERVICE_STARTUP_TIMEOUT_SECONDS)

    def test_service_startup_accepts_slow_health_but_preserves_failure_checks(self):
        import strict_e2e_runner_support as support
        from urllib.error import HTTPError

        for state in ("slow", "health-delay", "missing", "invalid", "unhealthy", "connection", "pid", "exited", "late"):
            with self.subTest(state=state):
                clock = [0.0]
                ready = mock.Mock()
                ready.is_file.side_effect = lambda: state != "missing" and (state != "slow" or clock[0] >= 59)
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
                        clock[0] = support.SERVICE_STARTUP_TIMEOUT_SECONDS + 1
                    response.__enter__.return_value.status = 503 if state == "health-delay" and clock[0] < 59 else 200
                    return response

                with mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                        mock.patch.object(support.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                        mock.patch.object(support.urllib.request, "urlopen", side_effect=request) as query, \
                        mock.patch("builtins.print") as report:
                    if state in ("slow", "health-delay"):
                        self.assertEqual(support.wait_for_service(ready, process), ("127.0.0.1", 1234))
                        self.assertAlmostEqual(clock[0], 59, delta=.05)
                        self.assertIn("elapsed=59.0s", report.call_args.args[0])
                    else:
                        with self.assertRaises(CommandError) as error:
                            support.wait_for_service(ready, process)
                        if state in ("pid", "exited"):
                            self.assertIn("PID" if state == "pid" else "exit 3", str(error.exception))
                            query.assert_not_called()
                            self.assertEqual(clock[0], 0)
                        else:
                            self.assertEqual(error.exception.code, 124)
                            self.assertGreaterEqual(clock[0], support.SERVICE_STARTUP_TIMEOUT_SECONDS)
                            self.assertLessEqual(clock[0], support.SERVICE_STARTUP_TIMEOUT_SECONDS + 1)
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
        suites = [suite for suite, case in P2_CASES.items() if case.video] + ["filter-switch", "tvos-switch"]
        for suite in suites:
            stderr = io.StringIO()
            with self.subTest(suite=suite), tempfile.TemporaryDirectory() as directory, redirect_stderr(stderr):
                evidence = Path(directory) / "evidence"
                with self.assertRaises(SystemExit) as error:
                    runner_main(["--platform", "tvos" if suite == "tvos-switch" else "ios",
                        "--destination", "platform=iOS Simulator,id=" + P2_UDID,
                        "--suite", suite, "--test-without-building", "--listed-retry-device", "tv" if suite == "tvos-switch" else "iphone",
                        "--derived-data-path", str(Path(directory) / "derived"), "--evidence-dir", str(evidence)])
                self.assertEqual(error.exception.code, 2)
                self.assertIn("recording suites cannot use listed-only retry", stderr.getvalue())
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
                def wait(ready, process, timeout_seconds):
                    self.assertEqual(timeout_seconds, 60)
                    if len(logs) == failed_server:
                        raise CommandError("Test service health check timed out (last_state=ready-file-missing).")
                    return "127.0.0.1", 1234
                with mock.patch("run_strict_e2e.subprocess.Popen", side_effect=launch), \
                        mock.patch.object(support, "_wait_for_fixture_build") as build, \
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
                self.assertEqual([call.args[1:] for call in build.call_args_list], [(log, 120) for log in expected])
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
        boot_submitted: bool = False,
        configuration: str = "Debug",
        native_failure_epoch=None,
    ) -> tuple[int, str, str, dict[str, mock.Mock]]:
        destination = f"platform={'tvOS' if platform == 'tvos' else 'iOS'} Simulator,id={P2_UDID}"
        selector = (
            P2_CASES[suite].selectors[platform] if suite in P2_CASES
            else strict_runner.resolve_suite_selector(platform, suite)
        )
        recording_process = mock.Mock(pid=9876)
        invocations = []
        attempt_environments = []
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
            if "-xctestrun" in command:
                import plistlib
                payload = plistlib.loads(Path(command[command.index("-xctestrun") + 1]).read_bytes())
                attempt_environments.append(payload["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"])
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
            if timeout_phase == "xcodebuild":
                with mock.patch("run_strict_e2e.subprocess.run", side_effect=subprocess.TimeoutExpired(command, 600)), \
                        mock.patch("ci_execution_diagnostics.system_sample", return_value=None):
                    return run_command(command, **kwargs)
            if failure_session is not None and kwargs["log_path"].name != f"xcodebuild-{failure_session}.log":
                return 0
            if retry:
                return 65 if len(invocations) == 1 else 0
            return xcodebuild_exit

        def fake_subprocess(command: list[str], **_: object) -> subprocess.CompletedProcess[object]:
            if command[:2] == ["xcrun", "xcresulttool"]:
                if timeout_phase == "official-tests-export":
                    raise subprocess.TimeoutExpired(["private-test-input"], 60, output=b"private-test-input")
                if native_failure_epoch is not None:
                    from datetime import datetime, timezone
                    identifier = selector.split("/", 1)[1] + "()"
                    if "--legacy" not in command:
                        payload = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": identifier, "result": "Failed"}]}
                    elif "--id" not in command:
                        payload = {"actions": {"_values": [{"actionResult": {"testsRef": {"id": {"_value": "tests"}}}}]}}
                    elif command[command.index("--id") + 1] == "tests":
                        payload = {"summaries": {"_values": [{"identifier": {"_value": identifier},
                            "summaryRef": {"id": {"_value": "method"}}}]}}
                    else:
                        payload = {"failureSummaries": {"_values": [{"uuid": {"_value": "failure"},
                            "timestamp": {"_value": datetime.fromtimestamp(native_failure_epoch(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f%z")}}]}}
                    return subprocess.CompletedProcess(command, export_exit, json.dumps(payload).encode(), b"")
                return subprocess.CompletedProcess(command, export_exit, b'{"testNodes":[]}', b"")
            return subprocess.CompletedProcess(command, 0, "", "")

        def fake_test_run(source, directory, environment):
            import plistlib
            run = directory / "case.xctestrun"
            run.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [
                {"BlueprintName": "immichSlidesUITests", "EnvironmentVariables": {}}]}]}))
            return run

        def fake_preparation(udid, *, report, boot_submitted=False):
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
        ) as reset, mock.patch(
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
            "strict_e2e_build.load_warm_build", return_value=({"identity": {"configuration": configuration}}, Path("warm.xctestrun"))
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
                    *(["--configuration", configuration] if warm else []),
                    "--destination",
                    destination,
                    "--evidence-dir",
                    str(evidence),
                    "--suite",
                    suite,
                    *(["--scenario", "out-of-order"] if suite == "late-image" else []),
                    *(["--test-without-building", "--derived-data-path", str(evidence.parent / "derived")] if warm else []),
                    *(["--listed-retry-device", "iphone"] if retry else []),
                    *(["--simulator-boot-submitted"] if boot_submitted else []),
                    *(["--warm-timeout-seconds", "600"] if timeout_phase == "xcodebuild" else []),
                ],
                stdout=stdout,
                stderr=stderr,
            )
        return exit_code, stdout.getvalue(), stderr.getvalue(), {
            "dirty": dirty,
            "prepare": prepare,
            "reset": reset,
            "facts": facts,
            "start": start,
            "stop": stop,
            "recording_process": recording_process,
            "invocations": invocations,
            "attempt_environments": attempt_environments,
        }

    def test_warm_runner_reuses_submitted_boot_for_every_reset(self):
        for submitted, suite, retry, resets in (
                (False, "smoke", False, 1), (True, "smoke", False, 1),
                (True, "filter-person", False, 3), (True, "filter-person", True, 4),
                (True, "late-image", True, 2)):
            with self.subTest(boot_submitted=submitted, suite=suite, retry=retry), tempfile.TemporaryDirectory() as raw:
                def request_preview(environment, _number):
                    import urllib.request
                    request = urllib.request.Request(environment["STRICT_E2E_INPUT_SERVER_URL"] +
                        "/assets/asset-a-2/thumbnail?size=preview", headers={"x-api-key": strict_runner.PUBLIC_API_KEY})
                    with urllib.request.urlopen(request, timeout=5) as response:
                        response.read()
                code, _, stderr, calls = self._run_p2_main(Path(raw) / "evidence", suite=suite,
                    platform="ios", model="iPhone", warm=True, boot_submitted=submitted, retry=retry,
                    late_image_attempt=request_preview if suite == "late-image" else None)
                self.assertEqual(0, code, stderr)
                self.assertEqual(submitted, calls["prepare"].call_args.kwargs.get("boot_submitted", False))
                calls["prepare"].assert_called_once()
                self.assertEqual([mock.call(P2_UDID, boot_submitted=True)] * resets, calls["reset"].call_args_list)

    def test_strict_retry_configures_independent_spools_and_disables_a_failed_reconfiguration(self):
        from ci_failure_diagnostics import configure_first_failure_attempt
        for failed in (None, 2, 4):
            with self.subTest(reconfiguration_failed=failed), tempfile.TemporaryDirectory() as raw:
                configured = []
                def configure(call, spool, selectors, **kwargs):
                    configured.append(spool)
                    if len(configured) == failed:
                        original_write = Path.write_bytes
                        def fail_write(path, payload):
                            original_write(path, payload[:8])
                            raise OSError("Synthetic partial attempt configuration write")
                        with mock.patch.object(Path, "write_bytes", fail_write):
                            return configure_first_failure_attempt(call, spool, selectors, **kwargs)
                    return configure_first_failure_attempt(call, spool, selectors, **kwargs)
                with mock.patch("ci_failure_diagnostics.configure_first_failure_attempt", side_effect=configure), \
                        mock.patch.object(strict_runner, "export_private_result_bundle",
                                          wraps=strict_runner.export_private_result_bundle) as export:
                    code, _, stderr, calls = self._run_p2_main(Path(raw) / "evidence", suite="filter-person",
                        platform="ios", model="iPhone", warm=True, retry=True)
                self.assertEqual(0, code, stderr)
                self.assertEqual(4, len(configured))
                self.assertNotEqual(configured[0], configured[1])
                for index, (command, environment) in enumerate(zip(calls["invocations"], calls["attempt_environments"])):
                    bundle = Path(command[command.index("-resultBundlePath") + 1])
                    self.assertEqual(configured[index], bundle.parent / "first-failure-spool")
                    if index + 1 == failed:
                        self.assertNotIn("STRICT_E2E_FIRST_FAILURE_ENABLED", environment)
                        self.assertNotIn("STRICT_E2E_FIRST_FAILURE_DIR", environment)
                    else:
                        self.assertEqual(environment["STRICT_E2E_FIRST_FAILURE_ENABLED"], "1")
                        self.assertEqual(environment["STRICT_E2E_FIRST_FAILURE_DIR"], str(configured[index]))
                    exported = next(call for call in export.call_args_list if call.args[0] == bundle)
                    self.assertEqual(None if index + 1 == failed else
                        (configured[index], [session["selector"] for session in FILTER_PERSON_SESSIONS]),
                        exported.kwargs["first_failure_spool"])

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

    def test_debug_and_release_keep_failure_window_samples_when_diagnostic_ledger_is_unavailable(self):
        import ci_execution_diagnostics as diagnostics
        import strict_e2e_resource_diagnostics as resources
        import threading
        from types import SimpleNamespace
        original_start = resources.CaseSampler.start
        for platform, model, configuration in ((platform, model, configuration) for platform, model in
                (("ios", "iPhone"), ("tvos", "Apple TV")) for configuration in ("Debug", "Release")):
            with self.subTest(platform=platform, configuration=configuration), tempfile.TemporaryDirectory() as raw, diagnostics.session() as recorder:
                # The hosted preparation IO timeout leaves inherited Xcode accounting unavailable.
                recorder.unavailable.add("xcode")
                recorder.charged["xcode"] = diagnostics.COLLECTION_BUDGET_SECONDS["xcode"]
                ready, samplers = threading.Event(), []
                def start(sampler):
                    samplers.append(sampler)
                    return original_start(sampler)
                def read_host():
                    if samplers[0].samples:
                        ready.set()
                    return {"idle_percent": 40, "load_1m": 3, "cpu_percent": dict.fromkeys(resources.RESOURCE_CATEGORIES)}
                def xcode(*args):
                    self.assertTrue(ready.wait(2), "Release lifecycle execution must receive host samples")
                with mock.patch.object(resources, "SAMPLE_INTERVAL_SECONDS", 0.001), \
                        mock.patch.object(resources.CaseSampler, "start", start), \
                        mock.patch.object(resources, "HostProbe", return_value=SimpleNamespace(sample=read_host, close=lambda: None, unavailable=False)), \
                        mock.patch.object(resources, "process_sample") as ps:
                    code, _, stderr, _ = self._run_p2_main(Path(raw) / "evidence",
                        suite="smoke" if configuration == "Debug" else f"{platform}-lifecycle-settings",
                        platform=platform, model=model, configuration=configuration, warm=True, xcodebuild_exit=65,
                        late_image_attempt=xcode, native_failure_epoch=lambda: samplers[0].epoch + samplers[0].duration / 2)
                self.assertEqual(65, code, stderr)
                self.assertEqual(1, len(samplers))
                sampler = samplers[0]
                case = recorder.receipt()["case_resources"][0]
                self.assertGreater(case["sample_count"], 0)
                self.assertTrue(case["failure_samples"])
                self.assertEqual(40, case["idle_percent_min"])
                self.assertTrue(all(value is None for row in case["failure_samples"] for value in row["cpu_percent"].values()))
                self.assertEqual(0, case["sampler_wall_seconds"])
                ps.assert_not_called()

    def test_warm_test_inputs_do_not_prevent_private_bundle_disposal(self):
        import ci_execution_diagnostics as diagnostics
        with tempfile.TemporaryDirectory() as raw, diagnostics.session() as recorder:
            for sequence in range(diagnostics.MAX_EVENTS):
                recorder.event("xcode", "test-execution", "timeout", sequence)
            root = Path(raw)
            evidence = root / "evidence"
            code, _, stderr, _ = self._run_p2_main(evidence, suite="smoke", platform="ios", model="iPhone", warm=True)
            self.assertEqual(code, 0, stderr)
            manifest = evidence / "case-manifest.json"
            self.assertLessEqual(manifest.stat().st_size, 65536, "case evidence must fit the first-failure exporter cap")
            self.assertEqual([], json.loads(manifest.read_text())["bounded_diagnostics"]["events"])
            self.assertEqual(diagnostics.MAX_EVENTS, len(recorder.receipt()["events"]))
            self.assertEqual((evidence / "simulator-preparation.log").read_text(), "ready\n")
            self.assertEqual(list((root / "private").iterdir()), [])

        for xcode_exit in (0, 65):
            with self.subTest(xcode_exit=xcode_exit), tempfile.TemporaryDirectory() as raw, \
                    diagnostics.session() as recorder, \
                    mock.patch("strict_e2e_resource_diagnostics.CaseSampler.publish", side_effect=RuntimeError("PRIVATE_SENTINEL")):
                code, _, stderr, _ = self._run_p2_main(Path(raw) / "evidence", suite="smoke", platform="ios",
                                                      model="iPhone", warm=True, xcodebuild_exit=xcode_exit)
                self.assertEqual(xcode_exit, code, stderr)
                self.assertIsNone(recorder.receipt()["collection_seconds"]["xcode"])
                self.assertTrue(recorder.truncated)
                self.assertNotIn("PRIVATE_SENTINEL", stderr)

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
        import ci_execution_diagnostics as diagnostics
        with tempfile.TemporaryDirectory() as raw, diagnostics.session() as recorder, \
                mock.patch("strict_e2e_resource_diagnostics.CaseSampler.publish", side_effect=RuntimeError("PRIVATE_SENTINEL")):
            evidence = Path(raw) / "evidence"
            code, _, stderr, _ = self._run_p2_main(evidence, suite="smoke", platform="ios", model="iPhone",
                                                  warm=True, timeout_phase="xcodebuild")
            self.assertEqual(2, code, stderr)
            self.assertIn("xcodebuild timed out after 600.0s.", stderr)
            self.assertEqual("FAILED", json.loads((evidence / "case-manifest.json").read_text())["result"])
            exported = [event for event in recorder.events if event["phase"] == "official-export"]
            self.assertEqual(1, len(exported))
            self.assertEqual({"bundle": True, "summary": True, "tests": True}, exported[0]["official_exports"])
            self.assertIsNone(recorder.receipt()["collection_seconds"]["xcode"])
            self.assertNotIn("PRIVATE_SENTINEL", stderr)

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

    def test_prebuild_preparation_checks_launch_services_without_a_container_lookup(self):
        import ci_execution_diagnostics as diagnostics
        import strict_e2e_runner_support as support
        for mode in ("ready", "missing-service", "recover", "timeout", "late-response", "long-boot",
                     "timeout-then-missing-service"):
            with self.subTest(mode=mode):
                clock, commands, reports = [0.0], [], []
                def run(command, **kwargs):
                    commands.append(command)
                    if command[2] == "bootstatus" and mode == "long-boot":
                        clock[0] += 550
                    if command[2] == "spawn":
                        self.assertEqual(command, ["xcrun", "simctl", "spawn", "SIM-UDID",
                                                   "launchctl", "print", "system/com.apple.lsd"])
                        if mode in ("timeout", "long-boot") or mode in ("recover", "timeout-then-missing-service") and len(commands) == 3:
                            clock[0] += kwargs["timeout"]
                            raise subprocess.TimeoutExpired(["private-input"], kwargs["timeout"])
                        if mode == "late-response":
                            clock[0] += 301
                        elif mode in ("ready", "recover"):
                            clock[0] += 0.125
                        return subprocess.CompletedProcess(command, 113 if mode in ("missing-service", "timeout-then-missing-service") else 0,
                                                           "private-input", "private-input")
                    self.assertIn(command[2], ("boot", "bootstatus"), "prebuild must not query app containers")
                    return subprocess.CompletedProcess(command, 0, "Booting device...\n"
                        if command[2] == "bootstatus" and mode == "ready" else "", "")
                with diagnostics.session() as recorder, \
                        mock.patch.object(diagnostics, "system_sample", return_value=None), \
                        mock.patch.object(support.subprocess, "run", side_effect=run), \
                        mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]):
                    if mode in ("ready", "recover"):
                        container, log = support.prepare_simulator("SIM-UDID", report=reports.append,
                                                                  should_check_app=False)
                        self.assertIsNone(container)
                        self.assertIn("simulator-preparation: passed", log)
                        self.assertEqual(mode == "ready", "simulator-bootstatus: started-device=true" in log)
                        self.assertEqual(mode == "ready", "simulator-bootstatus: started-device=true" in reports)
                        self.assertIn("query completed; attempt=" + ("2" if mode == "recover" else "1") +
                                      "; query_elapsed=0.125s", log)
                        self.assertEqual(["boot", "bootstatus", "spawn"] + (["spawn"] if mode == "recover" else []),
                                         [command[2] for command in commands])
                    else:
                        message = (r"^Simulator LaunchServices registration check failed \(exit 113\)\.$"
                                   if mode in ("missing-service", "timeout-then-missing-service") else
                                   "^simulator-readiness timed out after " + ("50" if mode == "long-boot" else "300") + r"\.0s\.$")
                        with self.assertRaisesRegex(CommandError, message) as raised:
                            support.prepare_simulator("SIM-UDID", report=reports.append, should_check_app=False)
                        self.assertNotIn("private-input", str(raised.exception))
                        self.assertFalse(any("passed" in line for line in reports if line.startswith("simulator-preparation:")))
                        if mode in ("timeout", "long-boot"):
                            self.assertEqual(clock[0], 600 if mode == "long-boot" else 300)
                if mode in ("recover", "timeout", "long-boot", "timeout-then-missing-service"):
                    self.assertTrue(any(event["phase"] == "simulator-preparation" and event["state"] == "reap-completed"
                                        for event in recorder.events), "timed-out service queries must retain cleanup diagnostics")
                if mode == "timeout-then-missing-service":
                    from ci_failure_diagnostics import preparation_first_failure
                    receipt = preparation_first_failure(recorder.receipt())
                    self.assertEqual("unknown", receipt["step"], "a recovered query timeout must not replace a later command failure")
                    self.assertIsNone(receipt["timing"]["wait_elapsed_seconds"])

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
    def test_reader_adds_only_fixed_display_after_and_person_screenshot_contexts(self):
        from ci_failure_diagnostics import public_validator_failure_message, validate_validator_failure_message
        # Existing person names and historical prefixes remain valid alongside display-after.
        for name in ("display-after", "person-normal", "person-no-faces", "person-conflict-normal",
                     "person-conflict-normal-2", "person-conflict-normal-99", "person-normal-1",
                     "person-nofaces-1", "vision-solo-1"):
            message = "unreadable public glyph slot; slot 1 (horizontal); screenshot " + name + ".png"
            with self.subTest(name=name):
                self.assertEqual(message, public_validator_failure_message(message))
                validate_validator_failure_message(message)
        for name in ("display-before", "display-after-1", "display-after.png/private", "Display-after",
                     "display-after-private", "../display-after", "person-conflict-normal-0",
                     "person-conflict-normal-100", "person-normal-private", "person-normal-2", "person-nofaces-2",
                     "person-solo", "person-conflict-solo", "person-solo-1", "person-conflict-solo-1",
                     "vision-solo", "vision-solo-0", "vision-solo-2", "vision-solo-1-private"):
            message = "unreadable public glyph slot; slot 1 (horizontal); screenshot " + name + ".png"
            with self.subTest(name=name):
                self.assertEqual("[redacted validator failure]", public_validator_failure_message(message))
                with self.assertRaisesRegex(ValueError, "not public context"):
                    validate_validator_failure_message(message)

    def test_validator_failure_retains_its_actual_input_without_claiming_an_app_snapshot(self):
        from unittest.mock import patch
        from PIL import Image
        import run_strict_e2e as runner
        from ci_failure_diagnostics import public_fixture_validator_scope, validate_first_failure, validate_first_failure_image
        from strict_e2e_p2_contract_test_fixtures import build_evidence, _facts, UDID
        with tempfile.TemporaryDirectory() as directory:
            evidence = build_evidence(Path(directory), "p2-cache", "iphone", review=False)
            Image.new("RGB", (320, 180), "black").save(evidence / "cache-returned.png", format="PNG")
            with patch.object(runner, "read_xcresult_facts", return_value=_facts("p2-cache", "iphone")):
                with self.assertRaises(runner.CommandError) as raised:
                    with public_fixture_validator_scope(evidence, screenshots=True):
                        runner.require_p2_evidence(evidence, suite="p2-cache", platform="ios", simulator_udid=UDID,
                            fixture_set="a", result_bundle_path=evidence / "strict-p2-cache.xcresult")
            self.assertEqual(2, raised.exception.code)
            receipt = json.loads((evidence / "first-failure-validator.json").read_text())
            validate_first_failure(receipt)
            self.assertEqual(("validator", "unavailable", "unknown", "validated-input"),
                (receipt["source"], receipt["state"]["observation"], receipt["state"]["app"], receipt["screenshot"]["status"]))
            self.assertTrue(all(value is None for value in receipt["timing"].values()))
            path = evidence / "first-failure-validator.png"
            validate_first_failure_image(path, receipt)
            with Image.open(path) as image:
                self.assertEqual(((0, 0), (0, 0), (0, 0)), image.getextrema())
            runner.write_sensitive_scan(evidence, ["PRIVATE_SENTINEL"])

    def test_export_retains_only_a_valid_official_fixture_failure_and_canonical_image(self):
        import io
        import ci_execution_diagnostics as diagnostics
        from unittest.mock import patch
        import run_strict_e2e as runner
        from PIL import Image
        from test_ci_summary import first_failure_receipt
        selector = "immichSlidesUITests/FlowUITests/testPlayback"
        for defect in (None, "private-element", "passed", "oversized-receipt", "symlink", "image-budget", "invalid-image", "wrong-source"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                spool, output = root / "private-spool", root / "public"
                spool.mkdir()
                output.mkdir()
                image = io.BytesIO()
                Image.new("RGB", (64, 32), "blue").save(image, format="PNG", icc_profile=b"PRIVATE_PROFILE")
                raw = image.getvalue()
                receipt = first_failure_receipt()
                receipt["screenshot"].update(width=64, height=32, bytes=len(raw))
                if defect == "private-element":
                    receipt["element"] = "PRIVATE_SENTINEL"
                if defect == "wrong-source":
                    from ci_failure_diagnostics import unavailable_first_failure
                    receipt = unavailable_first_failure("validator")
                receipt_path = spool / "0.json"
                receipt_path.write_text(json.dumps(receipt).ljust(8193) if defect == "oversized-receipt" else json.dumps(receipt))
                if defect == "symlink":
                    receipt_path.rename(spool / "other.json")
                    receipt_path.symlink_to(spool / "other.json")
                (spool / "0.png").write_bytes(b"not an image" if defect == "invalid-image" else raw)
                official = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "FlowUITests/testPlayback()",
                    "result": "Passed" if defect == "passed" else "Failed"}]}
                (output / "official-summary.json").write_text("{}")
                def export(command, **kwargs):
                    payload = official if "tests" in command else {}
                    return subprocess.CompletedProcess(command, 0, json.dumps(payload).encode())
                with diagnostics.session() as recorder, patch.object(runner.subprocess, "run", side_effect=export):
                    from ci_failure_diagnostics import normalize_ui_failure_images
                    legacy = output / "legacy/earlier-attempt.png"
                    legacy.parent.mkdir()
                    legacy.write_bytes(raw)
                    charged = recorder.charged["xcode"]
                    normalize_ui_failure_images(legacy.parent)
                    self.assertEqual(charged, recorder.charged["xcode"], "legacy images cannot crowd out a later first-failure image")
                    self.assertTrue(legacy.is_file())
                    if defect == "image-budget":
                        recorder.charged["xcode"] = 5
                        legacy.write_bytes(raw)
                        normalize_ui_failure_images(legacy.parent)
                        self.assertTrue(legacy.is_file(), "spent first-failure budget cannot remove a legacy image")
                    runner.export_private_result_bundle(root / "test.xcresult", output, [], enrich_failure_diagnostics=True,
                        first_failure_spool=(spool, [selector]))
                node = json.loads((output / "official-tests.json").read_text())["testNodes"][0]
                if defect in {"image-budget", "invalid-image"}:
                    self.assertEqual(receipt["timing"], node["first_failure"]["timing"])
                    self.assertEqual({"status": "unavailable", "width": None, "height": None, "bytes": None},
                                     node["first_failure"]["screenshot"])
                    self.assertFalse((output / "first-failure/0.png").exists())
                elif defect is not None:
                    self.assertNotIn("first_failure", node)
                    self.assertFalse((output / "first-failure/0.png").exists())
                else:
                    kept = node["first_failure"]
                    public_image = output / "first-failure/0.png"
                    self.assertEqual(kept["screenshot"]["bytes"], public_image.stat().st_size)
                    self.assertEqual(kept["timing"], receipt["timing"])
                    with Image.open(public_image) as picture:
                        self.assertEqual(picture.info, {})
                    runner.write_sensitive_scan(output, ["PRIVATE_SENTINEL", "PRIVATE_PROFILE"])

    def test_hosted_flow_prefixes_publish_only_the_reviewed_phase_and_class(self):
        from ci_failure_diagnostics import (
            FAILURE_CLASSES, FAILURE_PHASES, PREFIX_RULES, classify_messages, unknown_diagnostics,
        )
        self.assertEqual(FAILURE_PHASES, {phase for _, phase, _ in PREFIX_RULES})
        self.assertEqual(FAILURE_CLASSES, {kind for _, _, kind in PREFIX_RULES})
        # Fixed expectations catch missing/misclassified rows; source checks catch stale prefixes.
        capture_cases = (
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Visual ID failed history-start:", "history_start_capture", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Visual ID failed history-first-next:", "history_first_next_capture", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Visual ID failed history-second-next:", "history_second_next_capture", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Visual ID failed history-first-previous:", "history_first_previous_capture", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Visual ID failed history-second-previous:", "history_second_previous_capture", "scene_identity"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Visual ID failed history-start:", "history_start_capture", "scene_identity"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Visual ID failed history-first-next:", "history_first_next_capture", "scene_identity"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Visual ID failed history-second-next:", "history_second_next_capture", "scene_identity"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Visual ID failed history-first-previous:", "history_first_previous_capture", "scene_identity"),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Visual ID failed history-second-previous:", "history_second_previous_capture", "scene_identity"),
            ("immichSlidesUITests/RotationUITests.swift", "rotation-start-portrait did not stabilize within the ", "rotation_start_capture", "timing_window"),
            ("immichSlidesUITests/RotationUITests.swift", "rotation-landscape-stable did not stabilize within the ", "rotation_landscape_capture", "timing_window"),
            ("immichSlidesUITests/RotationUITests.swift", "rotation-portrait-stable did not stabilize within the ", "rotation_portrait_capture", "timing_window"),
            ("immichSlidesUITests/RotationUITests.swift", "Could not recognize a public photo on screen within ", "visible_scene_capture", "scene_identity"),
            ("immichSlidesUITests/RotationUITests.swift", "The public photo on screen did not change after next;", "history_navigation", "scene_identity"),
            ("immichSlidesUITests/RotationUITests.swift", "Before rotating, the play button value must be pause (playing),", "control_action", "control_state"),
            ("immichSlidesUITests/RotationUITests.swift", "The rotation sequence took ", "unknown", "timing_window"),
            ("immichSlidesUITests/RotationUITests.swift", "Orientation API: after setting ", "unknown", "navigation"),
            ("immichSlidesUITests/IOSDriver.swift", "Fresh install must open the normal first-boot page.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/IOSDriver.swift", "First-boot page must show the API Key field.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/IOSDriver.swift", "The API Key must be entered into the secure field.", "firstboot_setup", "control_state"),
            ("immichSlidesUITests/IOSDriver.swift", "First-boot page must show Test Connection.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/IOSDriver.swift", "First-boot page must show the Save Settings button.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/IOSDriver.swift", "A successful save must lead to mode selection.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/IOSDriver.swift", "The interval must be set to 30 seconds with the real slider.", "interval_setup", "interval_readback"),
            ("immichSlidesUITests/IOSDriver.swift", "Playback settings must have display mode segments.", "display_policy", "navigation"),
            ("immichSlidesUITests/IOSDriver.swift", "Display mode must offer the target option.", "display_policy", "navigation"),
            ("immichSlidesUITests/IOSDriver.swift", "Display mode must switch to the target option.", "display_policy", "control_state"),
            ("immichSlidesUITests/IOSDriver.swift", "Must be able to return from settings to playback.", "settings_navigation", "navigation"),
            ("immichSlidesUITests/IOSDriver.swift", "Settings list must have the playback settings entry.", "settings_navigation", "navigation"),
            ("immichSlidesUITests/IOSDriver.swift", "After opening playback settings, the auto-play toggle or the playback settings title must be visible.", "settings_navigation", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The mode page must also offer the filter entry.", "mode_selection", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "Playback page after uninstall means a dirty install container;", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The public test URL must be entered verbatim,", "firstboot_setup", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "API Key must reach the secure field;", "firstboot_setup", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "iPad must rotate to landscape to record split-view evidence.", "unknown", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The first-boot filter summary must offer a way back to mode selection.", "mode_selection", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The iOS filter summary should no longer use a bottom back button,", "mode_selection", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "Connection test showed a failure alert:", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Pause again before history actions so the 5-second timer does not interfere.", "control_action", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "A nil mark must encode into JSON,", "visible_scene_capture", "evidence_capture"),
        )
        cases = capture_cases + (
            ("immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift", "Album capture preparation must reach a stable scene before Pause.", "control_action", "timing_window"),
            ("immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift", "Album capture preparation paused during a transition; Pause freezes the current layers.", "control_action", "control_state"),
            ("immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift", "Album capture preparation must observe paused playback after one Pause.", "control_action", "control_state"),
            ("immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift", "Album capture preparation must reach a complete paused scene within the playback capture budget.", "visible_scene_capture", "probe_readback"),
            ("immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift", "Album Next must advance the paused scene within the playback capture budget.", "history_navigation", "navigation"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Midpoint pause tap must return before T-2;", "continue_timing", "timing_window"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "The playback page must have play/pause.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Play/pause must be hittable.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Play/pause must be hittable before continuing.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Play/pause value must be readable before acting.", "control_action", "probe_readback"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Play/pause must be paused before continuing.", "continue_timing", "control_state"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Must be playing before the mid-interval timing.", "continue_timing", "control_state"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Must be paused after the midpoint.", "control_action", "control_state"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Should be playing after Continue.", "continue_timing", "control_state"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "This narrow entry must not enable a password.", "settings_navigation", "control_state"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Playback settings must provide the autoplay toggle.", "unknown", "hidden_controls"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Settings.swift", "Playback settings must provide the autoplay toggle.", "unknown", "hidden_controls"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Autoplay must be turned on through the real settings.", "interval_setup", "control_state"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Autoplay must be on for the pause/background cases.", "interval_setup", "control_state"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "The pause/background cases must be able to switch to single-photo mode.", "interval_setup", "hidden_controls"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "The display policy should offer single-photo mode.", "unknown", "hidden_controls"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Settings.swift", "The display policy should offer single-photo mode.", "unknown", "hidden_controls"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Must return to the playback page after settings.", "settings_navigation", "navigation"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Failed to persist iPad watch sample diagnostics:", "continue_timing", "evidence_capture"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "First-half-window evidence after Continue crossed the window;", "continue_timing", "timing_window"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Auto advance came before T-2;", "continue_timing", "timing_window"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "A black screen with no new photo cannot pass automatically", "continue_timing", "scene_identity"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "The iPad transition criterion is missing the original photo luma before Continue", "continue_timing", "evidence_capture"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Next-photo stable confirmation does not match the current raw screenshot", "visible_scene_capture", "evidence_capture"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Next photo did not form a stable new MATCH within ", "visible_scene_capture", "scene_identity"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Screenshot cannot be used as identity;", "visible_scene_capture", "scene_identity"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Navigation.swift", "Must be able to return from settings to the playback page.", "settings_navigation", "navigation"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Navigation.swift", "The settings list must provide the playback settings entry", "settings_navigation", "navigation"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Navigation.swift", "After opening playback settings, the autoplay toggle or the playback settings title must be visible.", "settings_navigation", "navigation"),
            ("TestSupport/AccessLifecycleContract+Controls.swift", "Must not use the internal progress probe as the final criterion", "unknown", "evidence_capture"),
            ("TestSupport/AccessLifecycleContract+Controls.swift", "launchEnvironment must not force-override the settings under test", "unknown", "evidence_capture"),
            ("TestSupport/AccessLifecycleContract+Controls.swift", "Must not use the internal progress value instead of time and the screen", "control_action", "evidence_capture"),
            ("TestSupport/AccessLifecycleContract+Controls.swift", "Photo changes while paused must not be judged by control value changes alone", "control_action", "evidence_capture"),
            ("TestSupport/AccessLifecycleContract+Controls.swift", "The next photo after pause must show a different public pattern", "control_action", "scene_identity"),
            ("TestSupport/AccessLifecycleContract+Controls.swift", "Tap the canvas to wake it before confirming play/pause", "control_action", "hidden_controls"),
            ("TestSupport/AccessLifecycleContract+Controls.swift", "Do not tap again and toggle playback", "control_action", "control_state"),
            ("TestSupport/AccessLifecycleContract+Controls.swift", "The confirmation wait must not happen before continueAt", "continue_timing", "timing_window"),
            ("TestSupport/AccessLifecycleContract+Controls.swift", "A leftover settings button must not stand in for operable play/pause controls", "control_action", "hidden_controls"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "The click return time must not be earlier than the press", "continue_timing", "timing_window"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "Evidence crossing the window must not pass automatically", "continue_timing", "timing_window"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "Black screen without a new photo must not pass automatically", "continue_timing", "scene_identity"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "Black screen, zoom, control bar gone or unrecognized is not a transition", "continue_timing", "scene_identity"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "An in-window start was detected but not signed off", "continue_timing", "evidence_capture"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "Uncertain samples must remain pending video review; do not default to PASS", "continue_timing", "evidence_capture"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "Too early/late transition or missing start cannot pass automatically", "continue_timing", "timing_window"),
            ("immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift", "Automatic photo change occurred before T-2;", "continue_timing", "timing_window"),
            ("immichSlidesUITests/UITestSupport.swift", "First-boot mode navigation must dismiss the exact password prompt,", "mode_selection", "navigation"),
            ("immichSlidesUITests/UITestSupport.swift", "Mode departure failed after one hittable Continue without a password prompt;", "playback_entry", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterIOSUITests+Playback.swift", "Person selection preparation must provide an actionable card;", "filter_selection", "control_state"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "tvOS pause-continue evidence is invalid;", "continue_timing", "evidence_capture"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "iPhone pause-continue evidence is invalid;", "continue_timing", "evidence_capture"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "tvOS new photo must be stably identifiable within 4 s of transition start", "continue_timing", "scene_identity"),
            ("TestSupport/AccessLifecycleContract+TransitionTiming.swift", "iPhone new photo must be stably identifiable within 4 s of transition start", "continue_timing", "scene_identity"),
            ("TestSupport/AccessLifecycleContract.swift", "All black must not count as a pass", "unknown", "scene_identity"),
            ("TestSupport/AccessLifecycleContract.swift", "Blank must not count as a pass", "unknown", "scene_identity"),
            ("TestSupport/AccessLifecycleContract.swift", "Unrecognizable input must not count as a pass", "unknown", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The first-boot page must show the Save Settings button.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "After a successful save, the app must reach mode selection.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "A fresh install must reach the normal first-boot page.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The first-boot page must show the API Key field.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "The first-boot page must show the Test Connection button.", "firstboot_setup", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift", "Save must become enabled after a real connection test succeeds.", "firstboot_setup", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "A cold launch with saved settings must not return to the first-boot page.", "cold_relaunch", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "A configured cold launch must go straight to the playback page.", "cold_relaunch", "navigation"),
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
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Pause window bright proof must show A2.", "pause_window", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Pause window bright proof must be one frozen opaque scene.", "pause_window", "probe_readback"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Pause window midpoint must contain visible photo pixels.", "pause_window", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "Target window shows the wrong image; cannot count as SUCCESS.", "pause_window", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "The control bar must be visible before opening settings.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "The control bar must be visible before starting pause-window playback.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "After tapping Play, the button value must become pause.", "control_action", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "Pause before opening settings or identifying photos, so autoplay does not move away.", "control_action", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "visual_verdict=LATE: a complete A3 is visible after pause.", "pause_window", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "After injecting the public fixture, the app must reach the mode page.", "mode_selection", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "After returning to the playback page, the control bar must be revealed again.", "settings_navigation", "hidden_controls"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift", "The midpoint hook must leave the frame-synchronized probe paused.", "pause_window", "probe_readback"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "The settings button must be tappable.", "settings_navigation", "hidden_controls"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "The settings list must offer the playback settings entry", "settings_navigation", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "Could not return from playback settings to the playback page", "settings_navigation", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "Playback settings must offer the display mode segmented control.", "display_policy", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "Display mode must offer single photo mode.", "display_policy", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "The segmented control must remain after selecting single photo mode.", "display_policy", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "The display mode option must keep its Simplified Chinese copy.", "display_policy", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "Playback settings must offer the EXIF toggle.", "settings_navigation", "navigation"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "Show EXIF info must be on.", "interval_setup", "control_state"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "The playback interval must be 5 seconds.", "interval_setup", "interval_readback"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "After identifying A2, Next must be tappable to check its successor.", "pause_window", "hidden_controls"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "PRECONDITION_FAIL: order became A2→", "pause_window", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "PRECONDITION_FAIL: A2 successor is not A3 (", "pause_window", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "PRECONDITION_FAIL: not the large-text A2 after returning.", "pause_window", "scene_identity"),
            ("immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift", "PRECONDITION_FAIL: could not identify the large-text A2 using Next.", "pause_window", "scene_identity"),
            ("TestSupport/StrictE2EPhotoIdentity.swift", "Window missed or required frames missing: ", "pause_window", "evidence_capture"),
            ("immichSlidesUITests/StrictE2ELateImageIOSUITests.swift", "After late completion the current public mark must stay: no flash back, all black or unreadable: ", "late_image", "scene_identity"),
            ("immichSlidesUITests/StrictE2ELateImageIOSUITests.swift", "Next must be tappable twice right after entering the slideshow, before old image requests finish.", "late_image", "navigation"),
            ("immichSlidesUITests/ScenePresentationContractUITests.swift", "The fixture must actually deliver a failing image response", "image_recovery", "fixture_response"),
            ("immichSlidesUITests/ScenePresentationContractUITests.swift", "Fixture control must acknowledge its response mode", "image_recovery", "fixture_response"),
            ("immichSlidesUITests/ExifToggleUITests.swift", "After turning EXIF off, the info card in the upper-right area of the public photo must disappear from the screen.", "exif_ownership", "exif_visibility"),
            ("immichSlidesUITests/ExifToggleUITests.swift", "The required PNG with EXIF off still shows the info card.", "exif_ownership", "exif_visibility"),
            ("TestSupport/StrictE2EPhotoIdentity.swift", "Can't check EXIF: photo status ", "unknown", "scene_identity"),
            ("TestSupport/StrictE2EPhotoIdentity.swift", "EXIF does not match the photo: mark=", "unknown", "exif_correspondence"),
            ("immichSlidesUITests/IOSDriver.swift", "The EXIF toggle must reach the target state through the real settings.", "unknown", "control_state"),
            ("immichSlidesUITests/IOSDriver.swift", "Final Next preparation must provide an actionable control.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/IOSDriver.swift", "The current scene must be readable before tapping Next.", "visible_scene_capture", "scene_identity"),
            ("immichSlidesUITests/IOSDriver.swift", "One Next tap must change the visible scene.", "control_action", "scene_identity"),
            ("immichSlidesUITests/IOSDriver.swift", "Play/pause value must be readable before pausing.", "control_action", "probe_readback"),
            ("immichSlidesUITests/IOSDriver.swift", "Playback page must provide play/pause.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/IOSDriver.swift", "Playback page must provide the settings entry.", "settings_navigation", "hidden_controls"),
            ("immichSlidesUITests/IOSDriver.swift", "Tapping settings must open the settings page.", "settings_navigation", "navigation"),
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
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "The album list must show ", "unknown", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests+Support.swift", "The album list must show ", "unknown", "navigation"),
            ("immichSlidesUITests/StrictE2EFilterTVOSUITests.swift", "An empty album must show the frozen existing production empty-result copy and must not keep the old non-empty pool", "filter_edit", "scene_identity"),
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
            ("immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift", "Editor album card must show the manifest-selected album and photo counts", "server_switch", "control_state"),
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
            ("immichSlidesUITests/PlaybackHistoryIOSUITests.swift", "SmartFill Pause preparation was rejected before the deadline.", "control_action", "timing_window"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests.swift", "The new scene from a manual next while paused must stay still at p=0", "paused_hold", "scene_identity"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests.swift", "The scene from a manual previous while paused must stay still at p=0", "paused_hold", "scene_identity"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests.swift", "Play must make the current still scene start moving from p=0 immediately", "control_action", "scene_identity"),
            ("immichSlidesUITests/FilterSummaryIOSVisualUITests+Launch.swift", "After starting playback, the playback page should open and show the control bar", "playback_entry", "navigation"),
            ("immichSlidesUITests/UITestSupport.swift", "The slideshow control never became tappable before the deadline.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/ScenePresentationContractUITests.swift", "The slideshow control never became tappable before the deadline.", "control_action", "hidden_controls"),
            ("immichSlidesUITests/UITestSupport.swift", "The slideshow Settings tap had no observed outcome before the deadline.", "settings_navigation", "navigation"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift", "The slideshow Settings button must be ready before opening playback settings.", "settings_navigation", "hidden_controls"),
            ("immichSlidesUITests/FilterSummaryIOSVisualUITests+Navigation.swift", "Playback page should show the settings button", "unknown", "hidden_controls"),
            ("immichSlidesUITests/FilterSummaryIOSVisualUITests+Navigation.swift", "After entering the playback page, the settings button should be visible", "playback_entry", "navigation"),
            ("immichSlidesUITests/FilterSummaryIOSVisualUITests+Exif.swift", "Before each screenshot, the playback control bar should wake up reliably", "visible_scene_capture", "hidden_controls"),
            ("immichSlidesUITests/FilterSummaryIOSVisualUITests+Exif.swift", "The control bar may have auto-hidden while waiting for the sampling overlay; it should wake up again before tapping next", "visible_scene_capture", "hidden_controls"),
            ("immichSlidesUITests/FilterSummaryIOSVisualUITests+Exif.swift", "Before retrying next, the playback control bar should wake up again", "control_action", "hidden_controls"),
            ("immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift", "Could not return from the playback settings page to the slideshow", "settings_navigation", "navigation"),
        )
        failure_prefixes = {
            "SmartFill Pause preparation was rejected before the deadline.",
            "PRECONDITION_FAIL: order became A2→",
            "PRECONDITION_FAIL: A2 successor is not A3 (",
            "PRECONDITION_FAIL: not the large-text A2 after returning.",
            "PRECONDITION_FAIL: could not identify the large-text A2 using Next.",
            "Failed to persist iPad watch sample diagnostics:",
            "Playback page after uninstall means a dirty install container;",
            "Connection test showed a failure alert:",
            "Album capture preparation must reach a stable scene before Pause.",
            "Album capture preparation paused during a transition; Pause freezes the current layers.",
            "Album capture preparation must observe paused playback after one Pause.",
            "Album capture preparation must reach a complete paused scene within the playback capture budget.",
            "Album Next must advance the paused scene within the playback capture budget.",
            "First-boot mode navigation must dismiss the exact password prompt,",
            "Mode departure failed after one hittable Continue without a password prompt;",
            "Person selection preparation must provide an actionable card;",
            "The slideshow control never became tappable before the deadline.",
            "The slideshow Settings tap had no observed outcome before the deadline.",
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
            "Window missed or required frames missing: ",
            "SmartFill must expose the complete manifest, stable visible render state and history cursor together",
            "After tapping next, the fully visible SmartFill scene identity did not change in ",
            "scene identity did not change",
        }
        false_prefixes = {
            "This narrow entry must not enable a password.",
            "The iOS filter summary should no longer use a bottom back button,",
            "A cold launch with saved settings must not return to the first-boot page.",
            "Previous must be disabled at the history boundary when playback starts.",
            "Start Playback must be disabled with an empty selection.",
            "Start Playback must be disabled with 0 albums / 0 people.",
            "After switching servers the UI must not keep server A album/person IDs: ",
        }
        equal_prefixes = {
            "The display mode option must keep its Simplified Chinese copy.",
            "The public test URL must be entered verbatim,",
            "After a pause of at least 10 seconds, autoplay must not resume on its own.",
            "Fixture control must acknowledge its response mode",
            "The same live app process must run before and after the display policy change",
            "The same process must run before and after applying single-photo mode after the server switch",
            "Pausing must freeze the current transform progress",
        }
        caught_prefixes = {
            "First-half-window evidence after Continue crossed the window;",
            "Auto advance came before T-2;",
            "A black screen with no new photo cannot pass automatically",
            "The iPad transition criterion is missing the original photo luma before Continue",
            "Next-photo stable confirmation does not match the current raw screenshot",
            "Next photo did not form a stable new MATCH within ",
            "Screenshot cannot be used as identity;",
            "The playback page must have play/pause.",
            "Play/pause must be hittable.",
            "Play/pause must be hittable before continuing.",
            "Play/pause value must be readable before acting.",
            "Play/pause must be paused before continuing.",
            "No two distinct photos seen within four public album candidates; all failing originals are kept.",
            "No two distinct target-album photos were seen in one full four-frame candidate rotation; all candidate originals were kept.",
        }
        root = Path(__file__).resolve().parents[1]
        for source, prefix, phase, kind in cases:
            with self.subTest(source=source, prefix=prefix):
                if prefix.startswith("Visual ID failed history-"):
                    self.assertIn('"Visual ID failed \\(name): ',
                                  (root / "TestSupport/StrictE2ETestSupport.swift").read_text())
                    name = prefix.removeprefix("Visual ID failed ").removesuffix(":")
                    if source.endswith("/StrictE2ETVOSFlowUITests.swift"):
                        self.assertRegex((root / source).read_text(),
                                         r'captureVisualIdentity\(\s*app: app,\s*evidenceName: "' + re.escape(name) + '"')
                        self.assertIn('captureStrictSceneFrame(app: app, name: evidenceName, attachmentName: attachmentName)',
                                      (root / source).read_text())
                    else:
                        self.assertIn('captureHistoryIdentity(app: app, step: "' + name + '")',
                                      (root / source).read_text())
                        self.assertIn('captureStrictSceneFrame(app: app, name: step, attachmentName: step)',
                                      (root / "immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift").read_text())
                elif prefix.startswith("rotation-"):
                    self.assertIn('"\\(name) did not stabilize within the ', (root / source).read_text())
                    self.assertRegex((root / source).read_text(),
                                     r'captureStable\(\s*"' + re.escape(prefix.split()[0]) + '",')
                else:
                    self.assertIn('"' + prefix, (root / source).read_text())
                expected = {"failure_phase": phase, "failure_class": kind}
                # Match each wrapper to its public call site.
                if source.endswith("/RotationUITests.swift"):
                    wrappers = ('Failure(message: "', 'failed: caught error: "Failure(message: \\"',
                                'failed: caught error: "Failure(message: "', 'Failure(message: \\"')
                elif prefix in failure_prefixes:
                    wrappers = ("failed - ",)
                elif prefix in false_prefixes:
                    wrappers = ("XCTAssertFalse failed - ",)
                elif prefix in equal_prefixes:
                    wrappers = ("XCTAssertEqual failed: (PRIVATE_SENTINEL) - ",)
                elif prefix in caught_prefixes or source.startswith("TestSupport/AccessLifecycleContract"):
                    wrappers = ('failed: caught error: "message(\\"',)
                elif prefix == "Midpoint pause tap must return before T-2;":
                    wrappers = ("XCTAssertLessThan failed: (PRIVATE_SENTINEL) - ",)
                elif prefix == "Automatic photo change occurred before T-2;":
                    wrappers = ("XCTAssertEqual failed: (PRIVATE_SENTINEL) - ",)
                elif prefix == "The fixture must actually deliver a failing image response":
                    wrappers = ("XCTAssertGreaterThan failed: (PRIVATE_SENTINEL) - ",)
                elif prefix == "After the change, a still frame taken mid-transition must not pass":
                    wrappers = ("XCTAssertNotEqual failed: (PRIVATE_SENTINEL) - ",)
                else:
                    wrappers = ("XCTAssertTrue failed - ",)
                if prefix == "EXIF does not match the photo: mark=":
                    wrappers += ('failed: caught error: "message(\\"',)
                # Pin wrapper groups to the nearest emitting assertion in these reviewed flows.
                if prefix.startswith("Visual ID failed history-"):
                    assertion_source = (root / "TestSupport/StrictE2ETestSupport.swift").read_text()
                    message_start = assertion_source.index('"Visual ID failed \\(name): ')
                elif prefix == "Must be paused after the midpoint.":
                    assertion_source = (root / source).read_text()
                    self.assertIn('message: "' + prefix, assertion_source)
                    self.assertRegex(assertion_source, r'XCTAssertTrue\(\s*waitForPlayPauseState\([^\n]+\), message\)')
                    message_start = assertion_source.index('waitForPlayPauseState(app: app, expected: expected')
                elif (source, prefix, phase, kind) in capture_cases or "AccessLifecycle" in source:
                    assertion_source = (root / source).read_text()
                    template = ('\\(name) did not stabilize within the '
                                if prefix.startswith("rotation-") else prefix)
                    message_start = assertion_source.index('"' + template)
                else:
                    assertion_source = None
                if assertion_source is not None:
                    emitters = list(re.finditer(r'(XCTAssert\w+|XCTFail|throw Failure|throw (?:AccessLifecycleContract\.)?AssertionError\.message)\s*\(',
                                               assertion_source[:message_start]))
                    if wrappers[0].startswith('failed: caught error: "message('):
                        expected_emitter = ("throw AccessLifecycleContract.AssertionError.message"
                                            if source.startswith("immichSlidesUITests/") else
                                            "throw AssertionError.message")
                    else:
                        expected_emitter = ("throw Failure" if wrappers[0].startswith("Failure(") else
                                            "XCTFail" if wrappers[0] == "failed - " else
                                            wrappers[0].split()[0])
                    self.assertEqual(emitters[-1].group(1), expected_emitter)
                for wrapper in wrappers:
                    message = wrapper + prefix + " PRIVATE_SENTINEL /private/path asset-private"
                    if prefix in caught_prefixes or wrapper.startswith('failed: caught error:'):
                        message += '\\")"'
                    self.assertEqual(classify_messages([message]), expected)
                    self.assertEqual(classify_messages([message, message + " other-private-value"]), expected)
                    conflicting_classification_message = (
                        "The first wake should only bring up the control bar."
                        if phase == "interval_setup" else
                        "The iOS slider must be settable to PRIVATE_SENTINEL")
                    for conflicting in ("unreviewed PRIVATE_SENTINEL", conflicting_classification_message):
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
            'failed: caught error: "message(\\"' + "Do not use click return time to hide the action\\'s elapsed time" + '\\")"',
        ):
            with self.subTest(message=message):
                self.assertEqual(classify_messages([message]), unknown_diagnostics())

    def test_tvos_flow_and_pause_assertion_prefixes_match_their_sources(self):
        from ci_failure_diagnostics import PREFIX_RULES, classify_messages, unknown_diagnostics
        import subprocess
        # Missing reader rows must stay red even when XCTest retains only a bounded receipt.
        cases = (
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The playback index probe is empty, so autoplay and retained-history cannot be proven.", "history_navigation", "probe_readback", 'XCTUnwrap failed: expected non-nil value of type "String" - '),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "Settings subpage must show target option ", "settings_navigation", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "Must be able to focus ", "unknown", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "After choosing settings.playback.", "unknown", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "Playback page must show the settings button.", "settings_navigation", "hidden_controls", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "Settings button must have focus before opening.", "settings_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "After Select on settings, must enter settings or the PIN gate.", "settings_navigation", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "After returning from settings, must wait for the playback transition to finish.", "settings_navigation", "timing_window", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "After returning from settings with the bar hidden, the hidden receiver must have stable focus.", "settings_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "After returning from settings, the playback transition must finish before a directional press.", "unknown", "timing_window", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "After returning from settings, confirm stable hidden receiver focus before one directional press.", "unknown", "focus", "failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "First directional press must only wake controls.", "unknown", "hidden_controls", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "Settings page must have ", "settings_navigation", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "Directional key must wake the playback controls.", "hidden_controls", "hidden_controls", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "The field must be focused before input.", "firstboot_setup", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "System keyboard must show Next or Done.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "Must focus the system keyboard submit button before submitting text.", "firstboot_setup", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift", "After submitting text, focus must return to the field.", "firstboot_setup", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "A clean install must open the first-boot form.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "First-boot form must show the API Key field.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "URL submitted; focus must move down to API Key.", "firstboot_setup", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "First-boot form must show Test Connection.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "With the real controlled service reachable, the connection test must show as passed.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "After connecting, the Save Settings button must show.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "After a successful connection, Save Settings must be enabled.", "firstboot_setup", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "After saving settings, mode selection must open.", "mode_selection", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "Mode selection focus must start on random playback.", "mode_selection", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "After choosing random play, Continue must show.", "mode_selection", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "After choosing random play, Continue must be enabled.", "mode_selection", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift", "After choosing random play, focus must move down to Continue.", "mode_selection", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", "Settings home must show playback settings.", "settings_navigation", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", "Must return to playback settings.", "settings_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", "Focus must reach play/pause.", "control_action", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", "At midpoint, focus must reach play/pause.", "control_action", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", "After pause, focus must reach next.", "control_action", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", "Focus must return to play/pause after next.", "control_action", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", "Screenshot before-pause cannot serve as identity:", "visible_scene_capture", "scene_identity", "failed: caught error: \"message(\\\""),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", "Screenshot after-next cannot serve as identity:", "visible_scene_capture", "scene_identity", "failed: caught error: \"message(\\\""),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", "Screenshot before-background cannot serve as identity:", "visible_scene_capture", "scene_identity", "failed: caught error: \"message(\\\""),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", "Screenshot after-background cannot serve as identity:", "visible_scene_capture", "scene_identity", "failed: caught error: \"message(\\\""),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests.swift", "Pause/continue tvOS must run on a tvOS Simulator.", "unknown", "unknown", "failed - "),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests.swift", "Control bar must show after random playback.", "playback_entry", "hidden_controls", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The full tvOS flow must run on a tvOS Simulator.", "unknown", "unknown", "failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After saving settings, the app must reach the mode selection page.", "mode_selection", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After choosing filtered playback, the Continue button must appear.", "mode_selection", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After choosing filtered playback, the Continue button must be enabled.", "mode_selection", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Focus on the filter summary page must be able to move to Back to Mode Selection.", "mode_selection", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Going back from the filter summary must return to the mode selection page.", "mode_selection", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After choosing random playback, the Continue button must be enabled.", "mode_selection", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After choosing random playback, focus must be able to move down to the Continue button.", "mode_selection", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The first playback round must show the one-time remote hint.", "playback_entry", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "While the one-time hint is shown, default focus must land on the settings button.", "playback_entry", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The playback control bar must show the previous button.", "control_action", "hidden_controls", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "At the initial history boundary, previous must be disabled.", "history_navigation", "control_state", "XCTAssertFalse failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Before the history chain starts, focus must be able to move to Play/Pause.", "history_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Autoplay must be paused before the history chain starts.", "history_navigation", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After the control bar hides, the wake focus receiver layer must appear.", "hidden_controls", "hidden_controls", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The playback page must expose the read-only index probe.", "history_navigation", "probe_readback", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The start of the history chain must show the previous button.", "history_navigation", "hidden_controls", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "A must be at the history start of the current playback session.", "history_navigation", "control_state", "XCTAssertFalse failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Focus must be able to move from Play/Pause to Next.", "history_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The first next must advance the playback cursor.", "history_navigation", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After the first next settles, focus must be able to move to Next again.", "history_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The second next must advance the playback cursor further.", "history_navigation", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Focus must be able to move from Next back to Play/Pause.", "history_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Once history exists, focus must be able to move to Previous.", "history_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After the first previous, one earlier history entry remains, so the button must stay enabled.", "history_navigation", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After going back once, focus must be able to move to Previous again.", "history_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The end of the history chain must show the previous button.", "history_navigation", "hidden_controls", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After the second previous returns to the history start, the button must be disabled again.", "history_navigation", "control_state", "XCTAssertFalse failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Before checking autoplay, focus must be able to move to Next.", "control_action", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After consuming one step of forward history, focus must be able to move to Next again.", "history_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "At the history frontier, focus must be able to move to Play/Pause.", "history_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Pressing Select again after pausing must resume autoplay.", "control_action", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After auto-advance, focus on wake must return to Play/Pause.", "control_action", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The index probe must change after a playback action.", "history_navigation", "probe_readback", "XCTAssertNotNil failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Pressing Select after auto-advance must pause playback.", "control_action", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Pausing must not advance an extra photo.", "paused_hold", "scene_identity", "XCTAssertEqual failed: (PRIVATE_SENTINEL) - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The paused-frame comparison must span at least 10 seconds.", "paused_hold", "timing_window", "XCTAssertGreaterThanOrEqual failed: (PRIVATE_SENTINEL) - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "During a pause of at least 10 seconds, autoplay must not catch up.", "paused_hold", "scene_identity", "XCTAssertEqual failed: (PRIVATE_SENTINEL) - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After the pause wait, focus on wake must return to Play/Pause.", "control_action", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After the pause wait, autoplay must be resumable.", "control_action", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After autoplay resumes, focus on wake must return to Play/Pause.", "control_action", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After resuming, playback must advance to another photo.", "history_navigation", "probe_readback", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Autoplay must be pausable again before entering settings.", "control_action", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Focus in the playback control bar must be able to move to Settings.", "settings_navigation", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The settings button must open the settings page.", "settings_navigation", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Pressing Back/Menu on the settings page must return to the playback page.", "settings_navigation", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "A clean install must reach the first-boot form.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The first-boot form must show the API Key field.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After submitting the URL, focus must be able to move down to API Key.", "firstboot_setup", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The first-boot form must show the Test Connection button.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Once the real controlled service is reachable, the connection-test-passed status must show.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Select must not accidentally hit the API Key help sheet.", "firstboot_setup", "navigation", "XCTAssertFalse failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After a successful connection, the Save Settings button must appear.", "firstboot_setup", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After a successful connection, Save Settings must be enabled.", "firstboot_setup", "control_state", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The field must be focused before typing.", "unknown", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The system keyboard must show Next or Done.", "unknown", "navigation", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "Focus the system keyboard submit button before submitting text.", "firstboot_setup", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The server address must be submitted verbatim.", "firstboot_setup", "control_state", "XCTAssertEqual failed: (PRIVATE_SENTINEL) - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "After submitting text, focus must return to the original field.", "unknown", "focus", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "An arrow key must wake the playback control bar.", "hidden_controls", "hidden_controls", "XCTAssertTrue failed - "),
            ("immichSlidesUITests/StrictE2ETVOSFlowUITests.swift", "The index probe must change after a playback action. advanceObserved=", "history_navigation", "probe_readback", "failed - "),
            ("TestSupport/AccessLifecycleContract+Controls.swift", "Interval options are missing", "interval_setup", "interval_readback", "failed: caught error: \"message(\\\""),
            ("TestSupport/AccessLifecycleContract.swift", "Identity comes only from public fixture photos, never from logs or index", "visible_scene_capture", "evidence_capture", "failed: caught error: \"message(\\\""),
            ("TestSupport/AccessLifecycleContract.swift", "A forced display mode must not replace the real settings path", "visible_scene_capture", "evidence_capture", "failed: caught error: \"message(\\\""),
            ("TestSupport/AccessLifecycleContract.swift", "Returning to playback must not require the control bar to be visible", "settings_navigation", "evidence_capture", "failed: caught error: \"message(\\\""),
            ("TestSupport/AccessLifecycleContract.swift", "Returning to playback must confirm the playback layer", "unknown", "navigation", "failed: caught error: \"message(\\\""),
            ("TestSupport/AccessLifecycleContract.swift", "After settings return, no direction key until the transition completes", "unknown", "timing_window", "failed: caught error: \"message(\\\""),
            ("TestSupport/AccessLifecycleContract.swift", "After settings return, must confirm the hidden receiver holds focus stably", "unknown", "focus", "failed: caught error: \"message(\\\""),
            ("TestSupport/AccessLifecycleContract.swift", "Must not press twice to mask the first wake", "unknown", "hidden_controls", "failed: caught error: \"message(\\\""),
            ("TestSupport/AccessLifecycleContract.swift", "Wake after settings return is missing before/after screenshots", "unknown", "evidence_capture", "failed: caught error: \"message(\\\""),
            ("TestSupport/AccessLifecycleContract.swift", "A missing image must not count as a pass", "visible_scene_capture", "scene_identity", "failed: caught error: \"message(\\\""),
        )
        root = Path(__file__).resolve().parents[1]
        documentation = (root / "docs/CI_STRICT_RUNNER.md").read_text()
        for _, prefix, phase, kind, _ in cases:
            self.assertIn(f"| `{prefix}` | `{phase}` | `{kind}` |", documentation)
        # Scan every tracked Swift source, including App, unit and non-strict UI suites.
        # A new emitter must be reviewed even if its text is in a different test file.
        sources = {path: (root / path).read_text() for path in subprocess.check_output(
            ["git", "ls-files", "--", "*.swift"], cwd=root, text=True).splitlines()}
        tokens = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z_][\w.]*\s*\(|[()]', re.S)
        literals = []
        for path, text in sources.items():
            calls = []
            for token in tokens.finditer(text):
                value = token.group()
                if value.startswith(('//', '/*')):
                    continue
                if value.startswith('"'):
                    functions = list(re.finditer(r'\bfunc\s+(\w+)\s*\(', text[:token.start()]))
                    owner = functions[-1].group(1) if functions else None
                    literals.append((path, owner, value[1:-1], tuple(calls)))
                elif value.endswith('('):
                    calls.append(value[:-1].strip())
                elif value == ')' and calls:
                    calls.pop()

        dynamic_templates = {
            "After choosing settings.playback.": r"After choosing \(option), it must be selected.",
            **{f"Screenshot {name} cannot serve as identity:": r"Screenshot \(name) cannot serve as identity: \(mark)"
               for name in ("before-pause", "after-next", "before-background", "after-background")},
        }
        shared_owners = {
            "First directional press must only wake controls.": {"exerciseDirectionalWake", "wakeHiddenControlBarOnce"},
            "Must be able to focus ": {"selectPlaybackToggle", "moveFocusToSettingsControl", "focusSettingsControl",
                "changePlaybackSettingsThroughRealUI", "enablePinThroughRealUI", "enablePasswordFromSettingsUI"},
            "After choosing settings.playback.": {"selectPlaybackToggle", "choose"},
            "The field must be focused before input.": {"replaceFocusedText"},
            "A clean install must open the first-boot form.": {"configureServerThroughFirstBoot", "launchToPlayback"},
            "First-boot form must show the API Key field.": {"configureServerThroughFirstBoot", "launchToPlayback"},
            "After a successful connection, Save Settings must be enabled.": {"configureServerThroughFirstBoot", "launchToPlayback"},
            "Settings home must show playback settings.": {"changePlaybackSettingsThroughRealUI", "enterPlaybackSettings", "ensureInsidePlaybackSettingsPage"},
            "Must return to playback settings.": {"exerciseDisplayModeImmediate", "turnAutoplayOnThroughRealUI", "enterPlaybackSettings"},
            **{prefix: {"exercisePauseNextPlay", "exerciseTVOSPauseNextContinueVisibleTiming"} for prefix in (
                "Focus must reach play/pause.", "After pause, focus must reach next.", "Focus must return to play/pause after next.")},
            "Control bar must show after random playback.": {"testTVOSAccessProtectionSettingsAndLifecycle",
                "testTVOSPasswordProtectionNormalUI", "testTVOSSettingsPersistAfterTerminateLaunch",
                "testTVOSPauseNextContinueVisibleTiming", "testTVOSBackgroundReturnPreservesScene"},
            "The full tvOS flow must run on a tvOS Simulator.": {"testTVOSFirstBootSaveAndConfiguredColdLaunch",
                "testTVOSAlbumServerFirstBootFailureHTML200", "testTVOSFirstBootModeSelectionAndCorePlayback"},
            "After saving settings, the app must reach the mode selection page.": {
                "testTVOSFirstBootSaveAndConfiguredColdLaunch", "testTVOSFirstBootModeSelectionAndCorePlayback"},
            **{prefix: {"testTVOSAlbumServerFirstBootFailureHTML200", "configureServerThroughFirstBoot"} for prefix in (
                "A clean install must reach the first-boot form.", "The first-boot form must show the API Key field.",
                "After submitting the URL, focus must be able to move down to API Key.", "The first-boot form must show the Test Connection button.")},
            "The field must be focused before typing.": {"replaceFocusedText", "replaceFocusedTVOSText"},
            "The system keyboard must show Next or Done.": {"replaceFocusedText"},
            "After submitting text, focus must return to the original field.": {"replaceFocusedText"},
        }
        # Independently reviewed additional emitters: values are their call-site phases.
        shared_sources = {
            "Must be able to focus ": {"AccessLifecycleTVOSUITests+Settings.swift": "settings_navigation",
                                      "TVDriver.swift": "unknown"},
            "After choosing settings.playback.": {"TVDriver.swift": "unknown"},
            "The field must be focused before input.": {"TVDriver.swift": "firstboot_setup"},
            "A clean install must open the first-boot form.": {"TVDriver.swift": "firstboot_setup"},
            "First-boot form must show the API Key field.": {"TVDriver.swift": "firstboot_setup"},
            "After a successful connection, Save Settings must be enabled.": {
                "AccessLifecycleTVOSUITests+Settings.swift": "firstboot_setup",
                "StrictE2ELateImageTVOSUITests.swift": "firstboot_setup",
                "StrictE2ETVOSFlowUITests.swift": "firstboot_setup", "TVDriver.swift": "firstboot_setup"},
            "Settings home must show playback settings.": {"AccessLifecycleTVOSUITests+Settings.swift": "settings_navigation"},
            "Must return to playback settings.": {"AccessLifecycleTVOSUITests+Navigation.swift": "settings_navigation",
                                                 "AccessLifecycleTVOSUITests+Settings.swift": "settings_navigation"},
            **{prefix: {"AccessLifecycleTVOSUITests+Navigation.swift": "control_action"} for prefix in (
                "Focus must reach play/pause.", "After pause, focus must reach next.",
                "Focus must return to play/pause after next.")},
            "The field must be focused before typing.": {"StrictE2ELateImageTVOSUITests.swift": "firstboot_setup",
                "StrictE2EFilterTVOSUITests+Support.swift": "server_switch", "StrictE2ESmokeUITests.swift": "firstboot_setup"},
            "The system keyboard must show Next or Done.": {"StrictE2ELateImageTVOSUITests.swift": "firstboot_setup",
                "StrictE2EFilterTVOSUITests+Support.swift": "server_switch", "TVDriver.swift": "firstboot_setup"},
            "After submitting text, focus must return to the original field.": {
                "StrictE2ELateImageTVOSUITests.swift": "firstboot_setup", "StrictE2EFilterTVOSUITests+Support.swift": "server_switch"},
        }
        reviewed = {}
        for source, prefix, phase, kind, wrapper in cases:
            reviewed.setdefault(prefix, set()).add(source)
        for prefix, extra in shared_sources.items():
            reviewed[prefix].update("immichSlidesUITests/" + path for path in extra)
        for source, prefix, phase, kind, wrapper in cases:
            with self.subTest(source=source, prefix=prefix):
                active_prefix = next((row[0] for row in PREFIX_RULES if prefix.startswith(row[0])), None)
                self.assertIsNotNone(active_prefix, "missing classification for reviewed assertion")
                template = dynamic_templates.get(active_prefix, active_prefix)
                emitters = [(path, owner, literal, calls) for path, owner, literal, calls in literals
                            if literal.startswith(template)]
                self.assertTrue(emitters, prefix)
                self.assertEqual({path for path, _, _, _ in emitters}, reviewed[prefix],
                                 "prefix matches unreviewed Swift emitters in another phase")
                phases = {phase, *shared_sources.get(prefix, {}).values()}
                if len(phases) > 1:
                    self.assertEqual(phase, "unknown", "shared emitters disagree on phase")
                if prefix in shared_owners:
                    self.assertEqual({owner for _, owner, _, _ in emitters}, shared_owners[prefix])
                if prefix == "The index probe must change after a playback action.":
                    self.assertCountEqual([calls[-1] for _, _, _, calls in emitters],
                                          ["XCTAssertTrue", "XCTAssertNotNil", "XCTFail"])
                for emitter_source, owner, literal, calls in emitters:
                    if wrapper.startswith('failed: caught error:'):
                        self.assertTrue(calls[-1].endswith("AssertionError.message"), (literal, calls))
                        # Swift's thrown error description escapes apostrophes.
                        self.assertNotIn("'", literal)
                    elif calls[-1] in {"moveFocus", "focus"}:
                        self.assertEqual(wrapper, "XCTAssertTrue failed - ")
                        driver_source = (sources["immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift"]
                                         if "AccessLifecycleTVOSUITests" in emitter_source else sources[emitter_source])
                        declaration = re.search(r'\bfunc\s+' + calls[-1] + r'\s*\(', driver_source)
                        self.assertIsNotNone(declaration)
                        body = re.split(r'\bfunc\s+', driver_source[declaration.end():], maxsplit=1)[0]
                        self.assertRegex(body, r'XCTAssertTrue\(\s*waitForFocus\([^;]+?\), message\)')
                    else:
                        emitter = "XCTFail" if wrapper == "failed - " else wrapper.split()[0]
                        if prefix == "The index probe must change after a playback action.":
                            emitter = calls[-1]
                            actual_wrapper = "failed - " if emitter == "XCTFail" else emitter + " failed - "
                            self.assertEqual(classify_messages([actual_wrapper + literal]),
                                             {"failure_phase": phase, "failure_class": kind})
                        self.assertEqual(calls[-1], emitter, (literal, calls))
                        if emitter == "XCTFail":
                            self.assertEqual(classify_messages(["failed - " + literal]),
                                             {"failure_phase": phase, "failure_class": kind})
                message = wrapper + prefix + ' PRIVATE_SENTINEL /private/path'
                self.assertEqual(classify_messages([message]),
                                 {"failure_phase": phase, "failure_class": kind})
                self.assertEqual(classify_messages([message, "unreviewed PRIVATE_SENTINEL"]),
                                 unknown_diagnostics())

        # Bind interpolated screenshot names to all actual callers, including forwarding.
        capture_calls = []
        for path, text in sources.items():
            for call in re.finditer(r'(?<!func )\bcaptureTVOS(?:Immediate|NewStable)Mark\(\s*app: app,\s*name: ([^,\n)]+)', text):
                capture_calls.append((path, call.group(1)))
        self.assertCountEqual(capture_calls, [
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", '"before-pause"'),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", '"after-next"'),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift", 'name'),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests.swift", '"before-background"'),
            ("immichSlidesUITests/AccessLifecycleTVOSUITests.swift", '"after-background"'),
        ])
        navigation = sources["immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift"]
        wake_callers = []
        for call in re.finditer(r'(?<!func )\bwakeHiddenControlBarOnce\(\s*app:', navigation):
            wake_callers.append(list(re.finditer(r'\bfunc\s+(\w+)\(', navigation[:call.start()]))[-1].group(1))
        self.assertCountEqual(wake_callers, ["openSettingsFromSlideShow", "ensureControlBarVisible"])
        timing = sources["immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift"]
        self.assertIn("ensureControlBarVisible(app: app, playPauseButton: playPauseButton)", timing)
        self.assertIn("try AccessLifecycleContract.assertSettingsReturnWake(", navigation)
        self.assertIn("XCTFail(String(describing: error))", navigation)
        # The first/second-next outer assertions follow an earlier failing XCTFail.
        flow = sources["immichSlidesUITests/StrictE2ETVOSFlowUITests.swift"]
        self.assertIn("continueAfterFailure = false", flow)
        advance = flow[flow.index("private func waitForScenePublicationAdvance"):]
        self.assertIn("XCTFail(", advance)

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

    def test_native_dates_accept_legacy_offsets_colon_offsets_and_utc(self):
        from strict_e2e_resource_diagnostics import native_time
        for value in ("2021-03-03T14:43:24.000+0100", "2021-03-03T14:43:24.000+01:00",
                      "2021-03-03T12:43:24.000-0100", "2021-03-03T12:43:24.000-01:00",
                      "2021-03-03T13:43:24.000Z", "2021-03-03T13:43:24Z"):
            with self.subTest(value=value):
                self.assertEqual(1614779004, native_time({"timestamp": {"_value": value}}, "timestamp"))
        for value in ("2021-03-03T13:43:24.000", "2021-03-03", "2021-03-03T13:43:24.000+0099",
                      "2021-03-03T13:43:24.000+0000Z", "2021-03-03T13:43:24.000Z\n"):
            with self.subTest(value=value):
                self.assertIsNone(native_time({"timestamp": {"_value": value}}, "timestamp"))

    def test_private_export_and_tracer_publish_only_enums_without_changing_failure(self):
        import subprocess
        from datetime import datetime, timezone
        import ci_execution_diagnostics as diagnostics
        from test_ci_summary import first_failure_receipt
        from run_strict_ci_tracer import validate_case_export
        with tempfile.TemporaryDirectory() as raw:
            evidence = Path(raw)
            name = "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke"
            payload = {"testNodes": [{"nodeType": "Unit test bundle", "name": "immichSlidesUITests", "children": [
                {"nodeType": "Test Case", "nodeIdentifier": name + "()", "result": "Failed"}]}]}
            legacy = {"issues": {"testFailureSummaries": {"_values": [{
                "testCaseName": {"_value": name.replace("/", ".") + "()"},
                "message": {"_value": "XCTAssertTrue failed - The iOS slider must be settable to 30 seconds. PRIVATE_SENTINEL"}}]}}}
            epoch = 1792530000
            def native(title, start, finish, children=()):
                return {"title": {"_value": title},
                    "start": {"_value": datetime.fromtimestamp(epoch + start, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f%z")},
                    "finish": {"_value": datetime.fromtimestamp(epoch + finish, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f%z")},
                    "subactivities": {"_values": list(children)}}
            legacy["actions"] = {"_values": [{"actionResult": {"testsRef": {"id": {"_value": "tests"}}}}]}
            tests = {"summaries": {"_values": [{"identifier": {"_value": name + "()"},
                                               "summaryRef": {"id": {"_value": "method"}}}]}}
            native_summary = {"failureSummaries": {"_values": [{"uuid": {"_value": "first"},
                "timestamp": {"_value": datetime.fromtimestamp(epoch + 24.55, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f%z")}}]},
                "activitySummaries": {"_values": [native("Find the Target Application PRIVATE_SENTINEL", 0.94, 0.99),
                    native("Tap PRIVATE_SENTINEL", 1, 24.47, [native("Wait for com.331works.immichSlides to idle", 1, 1.01),
                        native("Find the Window PRIVATE_SENTINEL", 1.01, 1.03, [native("Find the Window nested", 1.015, 1.025)]),
                        native("Synthesize event", 1.06, 1.42), native("Wait for com.331works.immichSlides to idle", 1.42, 24.47)]),
                    native("Find the Target Application PRIVATE_SENTINEL", 24.47, 24.52)]}}
            receipt = first_failure_receipt()
            receipt.update(step="select", action="tap")
            receipt["timing"].update(action_duration_seconds=23.47,
                                    since_action_issued_seconds=24, since_action_returned_seconds=0.53)
            receipt["screenshot"] = {"status": "unavailable", "width": None, "height": None, "bytes": None}
            spool = evidence / "spool"
            spool.mkdir()
            (spool / "0.json").write_text(json.dumps(receipt))
            def export(command, **kwargs):
                body = (tests if command[command.index("--id") + 1] == "tests" else native_summary) if "--id" in command else (
                    legacy if "--legacy" in command else payload)
                return subprocess.CompletedProcess(command, 0, json.dumps(body).encode(), b"")
            summary = TestResultsSummary(1, 0, 1, 0, "Failed")
            sampler = mock.Mock()
            with diagnostics.session() as recorder, mock.patch("run_strict_e2e.subprocess.run", side_effect=export), \
                    mock.patch("run_strict_e2e.read_official_test_results_summary", return_value=summary):
                recorder.unavailable.add("xcode")
                recorder.charged["xcode"] = diagnostics.COLLECTION_BUDGET_SECONDS["xcode"]
                strict_runner.export_private_result_bundle(evidence / "private.xcresult", evidence, ["PRIVATE_SENTINEL"],
                    enrich_failure_diagnostics=True, first_failure_spool=(spool, ["immichSlidesUITests/" + name]),
                    resource_sampler=sampler)
            sampler.bind_failure.assert_called_once_with(epoch + 24.55)
            self.assertEqual(0, recorder.cost["xcode"], "native extraction has its own bounded allowance")
            receipt["native_activity_seconds"] = {"pre_event_idle": 0.01, "find_window": 0.02,
                "synthesize_event": 0.36, "post_event_idle": 23.05, "ax_root_acquisition": 0.1}
            exported = (evidence / "official-tests.json").read_text()
            self.assertNotIn("PRIVATE_SENTINEL", exported)
            self.assertNotIn("slider", exported)
            self.assertEqual(validate_case_export(evidence, "ios", "smoke"), [{"identifier": name, "result": "Failed",
                "failure_phase": "interval_setup", "failure_class": "interval_readback", "first_failure": receipt}])
            for ambiguity in ("matching-method", "failure-time", "missing-time", "partial-time", "synthesis", "read-timeout"):
                with self.subTest(native_failure=ambiguity), diagnostics.session() as recorder:
                    sampler.reset_mock()
                    original_rows = native_summary["failureSummaries"]["_values"]
                    original_metadata = tests["summaries"]["_values"]
                    tap = native_summary["activitySummaries"]["_values"][1]
                    original_children = tap["subactivities"]["_values"]
                    if ambiguity == "failure-time":
                        native_summary["failureSummaries"]["_values"] = original_rows * 2
                    elif ambiguity == "missing-time":
                        native_summary["failureSummaries"]["_values"] = []
                    elif ambiguity == "partial-time":
                        native_summary["failureSummaries"]["_values"] = original_rows + [{"uuid": {"_value": "unknown"}}]
                    elif ambiguity == "matching-method":
                        tests["summaries"]["_values"] = original_metadata * 2
                    elif ambiguity == "synthesis":
                        tap["subactivities"]["_values"] = original_children + [native("Synthesize event", 1.1, 1.2)]
                    def ambiguous_export(command, **kwargs):
                        if ambiguity == "read-timeout" and "--id" in command:
                            raise subprocess.TimeoutExpired(["private-command"], 2)
                        return export(command, **kwargs)
                    with mock.patch("run_strict_e2e.subprocess.run", side_effect=ambiguous_export):
                        strict_runner.export_private_result_bundle(evidence / "private.xcresult", evidence, ["PRIVATE_SENTINEL"],
                            enrich_failure_diagnostics=True, first_failure_spool=(spool, ["immichSlidesUITests/" + name]),
                            resource_sampler=sampler)
                    sampler.bind_failure.assert_not_called()
                    native_summary["failureSummaries"]["_values"] = original_rows
                    tests["summaries"]["_values"] = original_metadata
                    tap["subactivities"]["_values"] = original_children
            native_summary["activitySummaries"]["_values"].insert(0, native("Tap earlier PRIVATE_SENTINEL", -24, -0.53))
            sampler.reset_mock()
            with diagnostics.session(), mock.patch("run_strict_e2e.subprocess.run", side_effect=export):
                strict_runner.export_private_result_bundle(evidence / "private.xcresult", evidence, ["PRIVATE_SENTINEL"],
                    enrich_failure_diagnostics=True, first_failure_spool=(spool, ["immichSlidesUITests/" + name]),
                    resource_sampler=sampler)
            ambiguous = json.loads((evidence / "official-tests.json").read_text())["testNodes"][0]["children"][0]
            sampler.bind_failure.assert_not_called()
            self.assertEqual("Failed", ambiguous["result"])
            self.assertTrue(all(value is None for value in ambiguous["first_failure"]["native_activity_seconds"].values()))
            with diagnostics.session() as recorder, mock.patch("run_strict_e2e.subprocess.run", side_effect=export), \
                    mock.patch("strict_e2e_resource_diagnostics.collect_native_activity", side_effect=RuntimeError("PRIVATE_SENTINEL")):
                strict_runner.export_private_result_bundle(evidence / "private.xcresult", evidence, ["PRIVATE_SENTINEL"],
                    enrich_failure_diagnostics=True, first_failure_spool=(spool, ["immichSlidesUITests/" + name]),
                    resource_sampler=sampler)
            unavailable = json.loads((evidence / "official-tests.json").read_text())["testNodes"][0]["children"][0]
            self.assertEqual("Failed", unavailable["result"])
            self.assertNotIn("native_activity_seconds", unavailable["first_failure"])
            self.assertIsNone(recorder.receipt()["collection_seconds"]["xcode"])
            self.assertTrue(recorder.truncated)
            import shutil
            shutil.rmtree(spool)
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
        live_messages = set().union(*(fixed_messages(tree(name)) for name in
                                    original_modules + ("strict_e2e_filter_manifest.py",)))
        historical_receipts = (
            "member-manifest labels do not match classify_screenshot: must cover all five photos",
            "member-manifest labels do not match classify_screenshot: all five must MATCH and tell A1–A5 apart",
            "An A screen must not pass as B",
            "Display policy cannot pass on enum/probe alone",
            "The fixture yields no multi-photo screen; fix the fixture/preconditions first",
            "A still frame mid-transition cannot pass",
            "After the change the screen must be a stable single-photo public identity",
            "Still multi-photo after the change; cannot pass as single-photo",
            "Display policy did not take effect",
            "server-switch-a-play-1: every slot must show the public pattern a",
        )
        for prefix in historical_receipts:
            with self.subTest(historical_receipt=prefix):
                try:
                    diagnostics.validate_validator_failure_message(prefix + "; context unresolved")
                except ValueError as error:
                    self.fail(f"Historical public receipt was rejected: {error}")
                self.assertNotIn(prefix, live_messages, "Historical receipt must have no nightly validator raise site")
        self.assertEqual(set(diagnostics.VALIDATOR_HISTORICAL_PREFIXES), set(historical_receipts))
        self.assertEqual(set(diagnostics.VALIDATOR_FIXED_PREFIXES),
                         set().union(*(fixed_messages(tree(name)) for name in original_modules)))
        self.assertEqual(set(diagnostics.VALIDATOR_MANIFEST_PREFIXES),
                         fixed_messages(tree("strict_e2e_filter_manifest.py")))
        identity_tree = tree("strict_e2e_photo_identity.py")
        # Qualified and rejection entry points share this status-producing implementation.
        classifier = next(node for node in identity_tree.body
                          if isinstance(node, ast.FunctionDef) and node.name == "_classify_screenshot")
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
                                       "^unreadable public glyph slot: conflicting public background patterns; slot 1 \\(both axes\\); screenshot switch-b-play-1.png$") as raised:
                evaluate_server_switch_evidence(evidence)
            pattern_message = str(raised.exception)
            self.assertEqual(pattern_message, public_validator_failure_message(pattern_message))

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
                                       "^Unrecognizable input: unreadable public glyph slot: screenshot cannot be decoded; screenshot switch-b-play-1.png$") as raised:
                evaluate_server_switch_evidence(evidence)
            identity_message = str(raised.exception)
            self.assertEqual(identity_message, public_validator_failure_message(identity_message))
        for message in (pattern_message.replace("switch-b-play-1", "private-screenshot"),
                        pattern_message.replace("conflicting public background patterns", "private-pattern"),
                        pattern_message.replace("slot 1", "slot private"),
                        identity_message.replace("screenshot cannot be decoded", "private-status"),
                        identity_message.replace("switch-b-play-1.png", "private-mark.png")):
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
            single_before = _fixture_png("A1", "b")
            (evidence / "display-before.png").write_bytes(single_before)
            (evidence / "display-before-candidate-01.png").write_bytes(single_before)
            with self.assertRaisesRegex(FilterContractError, "^The before-change frame must actually show at least two different photos$") as raised:
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
    def test_submitted_boot_settles_during_cold_build_and_gates_every_warm_case(self):
        import run_strict_ci_tracer as tracer
        import strict_e2e_runner_support as support
        from ci_summary import parse_summary
        identity = {"schema_version": 1, "event": "local", "repository": "sudoHG/immichSlides",
                    "commit_sha": "0" * 40, "tree_sha": "0" * 40, "dirty": False}
        for failure in (None, "readiness", "service", "cold", "hard-timeout"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as raw:
                root, order, clock = Path(raw), [], [0.0]
                case = dict(platform="ios", device="ipad", configuration="Debug", suite="journey-a",
                            scenario="normal", fixture="a")
                manifest = root / "manifest.json"
                manifest.write_text(json.dumps({"cases": [case, dict(case, suite="journey-b")], "exclusions": []}))
                def run(command, *_args, **_kwargs):
                    if "--prepare-simulator-only" in command:
                        self.assertEqual(support.SIMULATOR_PREPARATION_TIMEOUT_SECONDS + 180, _kwargs["timeout_seconds"])
                        if failure == "hard-timeout":
                            order.append("child-timeout")
                            raise subprocess.TimeoutExpired(command, _kwargs["timeout_seconds"])
                        return tracer.main(command[3:])
                    if "--warm-up-only" in command:
                        order.append("cold")
                        self.assertNotIn("--simulator-boot-submitted", command)
                        clock[0] += 420
                        derived = Path(command[command.index("--derived-data-path") + 1])
                        derived.mkdir(parents=True)
                        (derived / "strict-warm-build.json").write_text(json.dumps({"signing_mode": "adhoc"}))
                        return 1 if failure == "cold" else 0
                    order.append("warm")
                    self.assertEqual("2", command[command.index("--native-diagnostics-allowance-seconds") + 1])
                    self.assertIn("--simulator-boot-submitted", command)
                    evidence = Path(command[command.index("--evidence-dir") + 1])
                    evidence.mkdir(parents=True)
                    suite = command[command.index("--suite") + 1]
                    bundle, method = tracer.resolve_suite_selector("ios", suite).split("/", 1)
                    (evidence / "xcodebuild.log").write_text("test-without-building\n")
                    (evidence / "xcodebuild-reuse.json").write_text(json.dumps({"products_unchanged": True}))
                    (evidence / "official-summary.json").write_text(json.dumps({"totalTestCount": 1, "passedTests": 1,
                        "failedTests": 0, "skippedTests": 0, "result": "Passed"}))
                    (evidence / "official-tests.json").write_text(json.dumps({"testNodes": [{
                        "nodeType": "Unit test bundle", "name": bundle, "children": [{"nodeType": "Test Case",
                        "nodeIdentifier": method + "()", "result": "Passed"}]}]}))
                    return 0
                def simctl(command, **kwargs):
                    order.append(command[2])
                    self.assertIn(command[2], ("bootstatus", "spawn"), "never resubmit boot or query the cold app container")
                    self.assertEqual(order[0], "cold", "readiness must start after the cold build")
                    if command[2] == "spawn":
                        if failure == "readiness":
                            clock[0] += kwargs["timeout"]
                            raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                        return subprocess.CompletedProcess(command, int(failure == "service"), "", "")
                    return subprocess.CompletedProcess(command, 0, "", "")
                output = root / "trace"
                with mock.patch.object(tracer, "run_runner", side_effect=run), \
                        mock.patch.object(tracer, "workspace_preflight"), mock.patch.object(tracer, "run_identity", return_value=identity), \
                        mock.patch.object(tracer, "source_metadata", return_value=(None, False)), \
                        mock.patch.object(tracer.shutil, "disk_usage", return_value=mock.Mock(total=200 * 1024**3, free=100 * 1024**3)), \
                        mock.patch.object(tracer, "toolchain", return_value={"versions": {"python": "test"}, "signing_mode": "not-applicable"}), \
                        mock.patch.object(support.subprocess, "run", side_effect=simctl), \
                        mock.patch("ci_execution_diagnostics.system_sample", return_value=None), \
                        mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                        mock.patch("builtins.print"):
                    code = tracer.main(["--platform", "ios", "--destination", "platform=iOS Simulator,id=TEST",
                        "--manifest", str(manifest), "--output-dir", str(output), "--simulator-boot-submitted"])
                summary = parse_summary((output / "records/summary.json").read_text())
                if failure is None:
                    self.assertEqual(0, code)
                    self.assertEqual("passed", summary["status"])
                    self.assertEqual(["cold", "bootstatus", "spawn", "warm", "warm"], order)
                else:
                    self.assertEqual(1, code)
                    self.assertNotIn("warm", order)
                    if failure == "cold":
                        self.assertEqual(["cold"], order)
                        continue
                    self.assertEqual(0 if failure == "hard-timeout" else 1, order.count("bootstatus"),
                                     "failed preparation must not retry the shard")
                    self.assertEqual("simulator-preparation-failed", summary["infrastructure"][0]["code"])
                    for item in summary["population"]["observed"]:
                        self.assertEqual(("failed", "not-run", None),
                            (item["outcome"], item["attempts"][0]["outcome"], item["attempts"][0]["exit_code"]))
                        receipt = item["first_failure"]
                        self.assertEqual(receipt, item["attempts"][0]["first_failure"])
                        self.assertEqual(("simulator-readiness", 300) if failure == "readiness" else ("unknown", None),
                            (receipt["step"], receipt["timing"]["wait_elapsed_seconds"]))
                    self.assertEqual([], summary["population"]["compiled"])

    def test_pause_timing_signature_survives_runner_tracer_nightly_and_method_reporting(self):
        import copy
        import ci_report
        import run_strict_ci_tracer as tracer
        from ci_nightly import aggregate_nightly, case_identity, parse_manifest, shards
        from test_ci_summary import bounded_diagnostics_receipt

        signed = {"name": "first_transition_start", "status": "detected", "official_signed": True,
                  "request_elapsed": 15.2, "elapsed": 15.2, "mark": "A5", "identity_status": "MATCH"}
        pending = {"name": "first_transition_start", "status": "pending_video_review", "official_signed": False,
                   "reason": "No usable start in window; post-window new photo does not count"}
        variants = [("signed", signed, 0, "passed"), ("pending", pending, 0, "needs-human-review"),
                    ("legacy visual receipt", pending, 0, "needs-human-review"),
                    ("legacy signed visual receipt", signed, 0, "passed"),
                    ("unsigned detected", dict(signed, official_signed=False), 0, "needs-human-review"),
                    ("pending signed", dict(pending, official_signed=True), 0, "needs-human-review"),
                    ("nonboolean signature", dict(signed, official_signed=1), 0, "needs-human-review"),
                    ("missing signature", {key: value for key, value in signed.items() if key != "official_signed"}, 0, "needs-human-review"),
                    ("wrong start name", dict(signed, name="other"), 0, "needs-human-review"),
                    ("duplicate start", signed, 0, "needs-human-review"),
                    ("wrong receipt suite", signed, 0, "needs-human-review"),
                    ("unreadable receipt", signed, 0, "needs-human-review"),
                    ("missing receipt", None, 0, "needs-human-review"),
                    ("runner failed", pending, 65, "failed")]
        for device, nightly in (("iphone", False), ("iphone", True), ("ipad", True)):
            for label, start, runner_exit, outcome in variants:
                with self.subTest(device=device, nightly=nightly, defect=label), tempfile.TemporaryDirectory() as raw:
                    root = Path(raw)
                    case = dict(platform="ios", device=device, configuration="Release", suite="ios-lifecycle-pause",
                                scenario="normal", fixture="a")
                    matrix = json.loads((tracer.ROOT / "scripts/nightly-matrix.json").read_text())
                    matrix["shard_size"] = 1
                    selected = next(shard for shard in shards(parse_manifest(matrix)) if shard["cases"] == [case])
                    manifest = root / "manifest.json"
                    manifest.write_text(json.dumps(matrix if nightly else {"cases": [case], "exclusions": []}))
                    identity = {"schema_version": 1, "event": "schedule" if nightly else "local",
                                "repository": "sudoHG/immichSlides", "commit_sha": "a" * 40, "tree_sha": "b" * 40}
                    identity.update({"ref": "refs/heads/main"} if nightly else {"dirty": False})
                    counts = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "result": "Passed"}
                    method = "AccessLifecycleIOSUITests/testPauseNextContinueVisibleTiming"
                    receipt = {"suite": "pause-next-continue", "status": "PASS", "device": device,
                               "interval_requested": 15, "interval_actual": 15, "desktop_closeout_required": False,
                               "timeline": [{"name": "continue_press", "issued_elapsed": 0, "returned_elapsed": .339},
                                            start, {"name": "new_image_confirmation", "mark": "A5", "request_elapsed": 18.322}]}
                    if label == "duplicate start":
                        receipt["timeline"].append(dict(start))
                    if label == "wrong receipt suite":
                        receipt["suite"] = "other"

                    def runner(command, *_args, **_kwargs):
                        evidence = Path(command[command.index("--evidence-dir") + 1])
                        derived = Path(command[command.index("--derived-data-path") + 1])
                        if "--warm-up-only" in command:
                            derived.mkdir(parents=True)
                            (derived / "strict-warm-build.json").write_text(json.dumps({"signing_mode": "adhoc"}))
                            return 0
                        evidence.mkdir(parents=True)
                        if start is not None:
                            (evidence / "pause-next-continue.json").write_text("{" if label == "unreadable receipt" else json.dumps(receipt))
                        visual = require_visual_identity(evidence, case["suite"])
                        self.assertEqual("PASS" if outcome == "passed" else "UNVERIFIED", visual["verdict"])
                        (evidence / "case-manifest.json").write_text(json.dumps({"visual_identity":
                            {**visual, "verdict": "NOT_REQUIRED"} if label.startswith("legacy ") else visual,
                            "bounded_diagnostics": bounded_diagnostics_receipt(resources=True)}))
                        (evidence / "xcodebuild.log").write_text("test-without-building\n")
                        (evidence / "xcodebuild-reuse.json").write_text(json.dumps({"products_unchanged": True}))
                        (evidence / "official-summary.json").write_text(json.dumps(counts))
                        (evidence / "official-tests.json").write_text(json.dumps({"testNodes": [{
                            "nodeType": "Unit test bundle", "name": "immichSlidesUITests", "children": [{
                                "nodeType": "Test Case", "nodeIdentifier": method + "()", "result": "Passed"}]}]}))
                        return runner_exit

                    output = root / "trace"
                    with mock.patch.object(tracer, "run_runner", side_effect=runner), \
                            mock.patch.object(tracer, "workspace_preflight"), mock.patch.object(tracer, "run_identity", return_value=identity), \
                            mock.patch.object(tracer, "source_metadata", return_value=(ci_report.NIGHTLY_PATH if nightly else None, False)), \
                            mock.patch.object(tracer.shutil, "disk_usage", return_value=mock.Mock(total=200 * 1024**3, free=100 * 1024**3)), \
                            mock.patch.object(tracer, "toolchain", return_value={"versions": {"python": "test"}, "signing_mode": "not-applicable"}), \
                            mock.patch.dict(os.environ, {"GITHUB_RUN_ID": "10", "GITHUB_RUN_ATTEMPT": "1"}):
                        code = tracer.main(["--platform", "ios", "--destination", "unused", "--manifest", str(manifest),
                            "--output-dir", str(output)] + (["--shard", selected["id"]] if nightly else []))
                    self.assertEqual(int(runner_exit != 0), code)
                    summary = json.loads((output / "records/summary.json").read_text())
                    trace = json.loads((output / "records/trace.json").read_text())
                    self.assertEqual(bounded_diagnostics_receipt(resources=True), trace["warm"][0]["bounded_diagnostics"])
                    self.assertEqual(outcome, summary["population"]["observed"][0]["outcome"])
                    if outcome == "needs-human-review":
                        self.assertEqual("Pause timing requires signed transition-start evidence",
                                         summary["population"]["observed"][0]["attempts"][0]["reason"])
                    self.assertEqual("unverified" if outcome == "needs-human-review" else outcome, summary["status"])
                    self.assertEqual(counts, trace["warm"][0]["official_summary"])
                    self.assertEqual(runner_exit, trace["warm"][0]["exit_code"])
                    self.assertEqual([{"identifier": method, "result": "Passed"}], trace["warm"][0]["official_methods"])
                    aggregate = aggregate_nightly([case_identity(case)], [summary], live_in_scope=False)
                    self.assertEqual("failed" if runner_exit else "passed", aggregate["status"])
                    self.assertEqual([case_identity(case)] if outcome == "needs-human-review" else [], aggregate["needs_human_review"])
                    if nightly and not runner_exit:
                        aggregate.update(identity=identity, hashes=summary["hashes"], run={"id": "10", "attempt": 1},
                            source=summary["source"], capacity={"shard_intervals": [{"shard": selected["id"]}]})
                        members = {("nightly-aggregate-10-1", "nightly.json"): aggregate,
                                   (f"nightly-strict-{selected['id']}-10-1", "summary.json"): summary,
                                   (f"nightly-strict-{selected['id']}-10-1", "trace.json"): trace}
                        artifacts = [{"name": name, "expired": False} for name in sorted({name for name, _ in members})]
                        run = {"id": 10, "workflow_id": 123, "run_attempt": 1, "created_at": "2026-10-18T00:00:00Z",
                               "head_sha": identity["commit_sha"], "path": ci_report.NIGHTLY_PATH, "event": "schedule",
                               "head_branch": "main", "head_repository": {"full_name": identity["repository"]},
                               "status": "completed", "conclusion": "success"}
                        with mock.patch("ci_publish.json_member", side_effect=lambda _api, artifact, name: copy.deepcopy(members[(artifact["name"], name)])):
                            report = ci_report.nightly_attempt(type("API", (), {"repository": identity["repository"]})(), run, 1, artifacts)
                        self.assertEqual([], report["diagnostics"]["missing"])
                        self.assertEqual({method, case["suite"]}, {item["identity"]["key"] for item in report["observed"]})
                        self.assertEqual([outcome, outcome], [item["outcome"] for item in report["observed"]])

    def test_identity_success_writes_no_early_failure_receipt_even_when_a_later_case_fails(self):
        for nightly, runner_exit in ((True, 0), (True, 2)):
            with self.subTest(nightly=nightly, runner_exit=runner_exit), tempfile.TemporaryDirectory() as directory:
                code, records, _trace, summary = self._produce_validator_records(
                    Path(directory), "no public glyph", nightly=nightly, runner_exit=runner_exit)
                self.assertEqual(0 if runner_exit == 0 else 1, code)
                self.assertEqual("passed" if runner_exit == 0 else "failed", summary["status"])
                self.assertFalse((records.parent / "identity-failure.json").exists())

    def test_nightly_cancellation_and_later_source_metadata_failure_do_not_write_an_identity_receipt(self):
        import run_strict_ci_tracer as tracer
        from ci_local import Interrupted
        from ci_summary import ContractError
        identity = {"schema_version": 1, "event": "schedule", "repository": "sudoHG/immichSlides",
                    "ref": "refs/heads/main", "commit_sha": "0" * 40, "tree_sha": "0" * 40}
        for phase, failure in (("identity", Interrupted(signal.SIGTERM)),
                               ("source", ContractError("GITHUB_WORKFLOW_REF does not identify this repository's workflow"))):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory, \
                    mock.patch.object(tracer, "run_identity", return_value=identity,
                                      side_effect=failure if phase == "identity" else None), \
                    mock.patch.object(tracer, "workspace_preflight"), \
                    mock.patch.object(tracer, "source_metadata", side_effect=failure if phase == "source" else None), \
                    mock.patch.object(tracer, "run_runner") as runner:
                output = Path(directory) / "trace"
                with self.assertRaisesRegex(type(failure), "^" + re.escape(str(failure)) + "$") as raised:
                    tracer.main(["--platform", "ios", "--destination", "unused",
                        "--manifest", str(tracer.ROOT / "scripts/nightly-matrix.json"),
                        "--shard", "iphone-immichSlides-iOS-debug-0", "--output-dir", str(output)])
                self.assertIs(failure, raised.exception)
                self.assertEqual([], list(output.iterdir()))
                runner.assert_not_called()

    def test_preparation_failure_accounting_identity_timeout_keeps_no_identity_receipt(self):
        import run_strict_ci_tracer as tracer
        timeout = subprocess.TimeoutExpired(["git", "rev-parse", "HEAD"], 30)
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {
                "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "schedule", "GITHUB_REPOSITORY": "sudoHG/immichSlides"}), \
                mock.patch("run_host_checks.subprocess.check_output", side_effect=timeout) as identity_process, \
                mock.patch.object(tracer, "run_runner") as runner:
            output = Path(directory) / "trace"
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                tracer.main(["--platform", "ios", "--destination", "unused",
                    "--manifest", str(tracer.ROOT / "scripts/nightly-matrix.json"),
                    "--shard", "iphone-immichSlides-iOS-debug-0", "--output-dir", str(output), "--preparation-failed"])
            self.assertIs(timeout, raised.exception)
            identity_process.assert_called_once()
            self.assertEqual([], list(output.iterdir()))
            runner.assert_not_called()

    def test_non_nightly_identity_timeout_keeps_the_original_failure_without_a_receipt(self):
        import run_strict_ci_tracer as tracer
        timeout = subprocess.TimeoutExpired(["git", "rev-parse", "HEAD"], 30)
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {
                "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "schedule", "GITHUB_REPOSITORY": "sudoHG/immichSlides"}), \
                mock.patch("run_host_checks.subprocess.check_output", side_effect=timeout):
            output = Path(directory) / "trace"
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                tracer.main(["--platform", "ios", "--destination", "unused", "--output-dir", str(output)])
            self.assertIs(timeout, raised.exception)
            self.assertEqual([], list(output.iterdir()))

    def test_hosted_timing_producer_round_trips_only_qualified_failures(self):
        import copy
        import contextlib
        import io
        from ci_summary import parse_summary
        from ci_nightly import aggregate_nightly
        from ci_report import method_observations
        from test_ci_summary import hosted_timeout_summary

        mutations = (None, "informational", "local", "self-hosted", "missing host", "conflicting host", "missing samples",
            "unbound epoch", "one-sided", "idle above limit", "null idle", "outside window", "ambiguous invocation",
            "unknown surface", "wrong surface", "wrong element", "wrong step", "snapshot hang", "visible controls",
            "BLACK", "BLANK", "UNRECOGNIZABLE", "process", "validator", "scene_identity", "control_state",
            "interval_readback", "history_navigation", "continue_timing", "firstboot_setup", "mode-departure",
            "not timed out", "missing deadline", "post-event idle only", "outer timeout", "interrupted",
            "missing log", "rebuild", "changed products", "official error", "case infrastructure", "missing method")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as raw:
                seed, _ = hosted_timeout_summary()
                row = seed["population"]["observed"][0]
                ledger = seed["strict_case_evidence"][0]["bounded_diagnostics"]
                receipt = row["first_failure"]
                resource = ledger["case_resources"][0]
                if mutation in {"self-hosted", "missing host"}:
                    ledger["events"][0]["sample"]["runner_hosted"] = False if mutation == "self-hosted" else None
                elif mutation == "conflicting host":
                    event = copy.deepcopy(ledger["events"][0])
                    event["sample"]["runner_hosted"] = False
                    ledger["events"].append(event)
                elif mutation in {"missing samples", "unbound epoch"}:
                    resource["failure_samples"] = []
                    if mutation == "unbound epoch":
                        resource["first_failure_elapsed_seconds"] = None
                elif mutation == "one-sided":
                    resource["failure_samples"][1]["elapsed_seconds"] = 7
                elif mutation in {"idle above limit", "null idle"}:
                    resource["failure_samples"][1]["idle_percent"] = 5.01 if mutation == "idle above limit" else None
                elif mutation == "outside window":
                    resource["failure_samples"][0]["elapsed_seconds"] = 2.99
                elif mutation == "ambiguous invocation":
                    ledger["case_resources"].append(dict(resource, sequence=5))
                elif mutation in {"unknown surface", "wrong surface"}:
                    receipt["state"]["surface"] = "unknown" if mutation == "unknown surface" else "mode"
                elif mutation == "wrong element":
                    receipt["element"] = "settings.item.playback"
                elif mutation == "wrong step":
                    receipt["step"] = "capture-frame"
                elif mutation == "snapshot hang":
                    row.update(failure_phase="unknown", failure_class="snapshot_query")
                elif mutation == "visible controls":
                    row.update(failure_phase="hidden_controls", failure_class="hidden_controls")
                    receipt["state"]["control_bar"] = "visible"
                elif mutation in {"BLACK", "BLANK", "UNRECOGNIZABLE"}:
                    receipt["state"]["scene_status"] = mutation
                elif mutation == "process":
                    receipt["state"]["app"] = "not-running"
                elif mutation == "validator":
                    row["validator_failure_message"] = "All black must not count as a pass"
                elif mutation in {"scene_identity", "control_state", "interval_readback"}:
                    row["failure_class"] = mutation
                elif mutation in {"history_navigation", "continue_timing", "firstboot_setup"}:
                    row["failure_phase"] = mutation
                elif mutation == "mode-departure":
                    row.update(failure_phase="playback_entry")
                    receipt.update(step="mode-departure")
                elif mutation == "not timed out":
                    receipt["timing"]["wait_elapsed_seconds"] = 4.99
                elif mutation == "missing deadline":
                    receipt["timing"]["deadline_seconds"] = None
                elif mutation == "post-event idle only":
                    receipt["timing"]["wait_elapsed_seconds"] = None
                    receipt["native_activity_seconds"] = {key: None for key in (
                        "pre_event_idle", "find_window", "synthesize_event", "post_event_idle", "ax_root_acquisition")}
                    receipt["native_activity_seconds"]["post_event_idle"] = 30
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    code, records, trace, summary = self._produce_validator_records(Path(raw), "unused",
                        receipt_suite=None, runner_exit=124 if mutation == "outer timeout" else 130 if mutation == "interrupted" else 65,
                        nightly=mutation != "local", invocation_fault=mutation,
                        timing_failure=(row, ledger), case=dict(platform="ios", device="iphone", configuration="Debug",
                            suite="filter-vision" if mutation == "informational" else "smoke", scenario="normal", fixture="a"))
                observed = parse_summary((records / "summary.json").read_text())["population"]["observed"][0]
                self.assertEqual("failed", observed["outcome"])
                self.assertEqual(124 if mutation == "outer timeout" else 130 if mutation == "interrupted" else 65,
                    observed["attempts"][0]["exit_code"])
                self.assertEqual(0 if mutation in {None, "informational"} else 1, code)
                self.assertEqual(mutation is None, "environment_limit" in observed)
                self.assertEqual(mutation is None, "::warning title=Environment-limited strict timing::" in output.getvalue())
                informational = [item["suite"] for item in json.loads((Path(raw) / "manifest.json").read_text()).get("informational", [])]
                aggregate = aggregate_nightly(summary["population"]["declared"], [summary], live_in_scope=False,
                    informational=informational)
                self.assertEqual("environment-limited" if mutation is None else "passed" if mutation == "informational" else "failed",
                    aggregate["status"])
                if mutation == "informational":
                    self.assertEqual("passed", summary["status"])
                    self.assertEqual([observed], aggregate["informational"])
                if mutation is None:
                    methods, missing = method_observations(summary, trace, runner_hosted=True)
                    self.assertEqual([], missing)
                    self.assertEqual(observed["environment_limit"], methods[0]["environment_limit"])
                    self.assertEqual(observed["environment_limit"], observed["attempts"][0]["environment_limit"])
                    self.assertIn("ENVIRONMENT-LIMITED", (records / "summary.md").read_text())
                else:
                    self.assertNotIn("environment_limit", observed["attempts"][0])

    def test_environment_producer_keeps_mixed_and_incomplete_shards_red_and_rejects_bad_projection(self):
        import copy
        from ci_summary import observation, parse_summary
        from run_strict_ci_tracer import evaluate_tracer, produce_environment_limits
        with tempfile.TemporaryDirectory() as raw:
            from test_ci_summary import hosted_timeout_summary
            seed, _ = hosted_timeout_summary()
            row = seed["population"]["observed"][0]
            _, _, trace, summary = self._produce_validator_records(Path(raw), "unused", receipt_suite=None,
                runner_exit=65, nightly=True, timing_failure=(row, seed["strict_case_evidence"][0]["bounded_diagnostics"]),
                case=dict(platform="ios", device="iphone", configuration="Debug", suite="smoke", scenario="normal", fixture="a"))
        for mutation in ("mixed", "missing", "missing observation", "infrastructure", "bad projection"):
            with self.subTest(mutation=mutation):
                candidate = copy.deepcopy(summary)
                candidate.pop("strict_case_evidence")
                candidate["population"]["observed"], candidate["status"] = evaluate_tracer(
                    candidate["population"]["declared"], trace["warm"])
                if mutation in {"mixed", "missing", "missing observation"}:
                    extra = copy.deepcopy(candidate["population"]["declared"][0])
                    extra["dimensions"]["fixture"] = "b"
                    candidate["population"]["declared"].append(extra)
                    if mutation != "missing observation":
                        candidate["population"]["observed"].append(observation(extra,
                            "failed" if mutation == "mixed" else "not-run", 0, exit_code=65 if mutation == "mixed" else None))
                elif mutation == "infrastructure":
                    candidate["infrastructure"].append({"code": "cleanup-failed", "message": "Synthetic cleanup failure"})
                proof = dict(summary["population"]["observed"][0]["environment_limit"], unexpected="refused")
                with mock.patch("ci_failure_diagnostics.environment_limit_evidence", return_value=proof) if mutation == "bad projection" else ExitStack():
                    self.assertEqual(1, produce_environment_limits(candidate, trace["warm"]))
                observed = parse_summary(candidate)["population"]["observed"][0]
                self.assertEqual(mutation != "bad projection", "environment_limit" in observed)
                self.assertEqual("failed", observed["outcome"])

    def _produce_validator_records(self, directory, error, *, verdict="FAIL", runner_exit=2,
                                   receipt_suite="tvos-switch", nightly=False, child_load_timeout=False, case=None,
                                   timing_failure=None, invocation_fault=None):
        import run_strict_ci_tracer as tracer
        case = case or {"platform": "tvos", "device": "tv", "configuration": "Release",
                "suite": "tvos-switch", "scenario": "normal", "fixture": "a"}
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

        real_runner = tracer.run_runner
        def runner(command, *_args, **_kwargs):
            derived = Path(command[command.index("--derived-data-path") + 1])
            evidence = Path(command[command.index("--evidence-dir") + 1])
            if "--warm-up-only" in command:
                derived.mkdir(parents=True)
                (derived / "strict-warm-build.json").write_text(json.dumps({"signing_mode": "adhoc"}))
                return 0
            if child_load_timeout:
                receipt = command[command.index("--diagnostics-receipt") + 1]
                child = '''
import sys
from pathlib import Path
from unittest import mock
import ci_execution_diagnostics as diagnostics
path = Path(sys.argv[1])
before = path.read_bytes()
with mock.patch.object(diagnostics.threading.Thread, "start"), \\
        mock.patch.object(diagnostics.threading, "Event", return_value=mock.Mock(wait=mock.Mock(return_value=False))), \\
        mock.patch.object(diagnostics, "report_truncation", side_effect=lambda reason: print(
            diagnostics.TRUNCATION_PREFIX + reason, file=sys.stderr, flush=True)):
    with diagnostics.session(path, reuse=True) as recorder:
        assert recorder.truncated
assert path.read_bytes() == before
raise SystemExit(65)
'''
                self.assertEqual(65, real_runner([sys.executable, "-B", "-c", child, receipt],
                    SCRIPT_DIR, directory / "child.log", **_kwargs))
            evidence.mkdir(parents=True)
            details = {"infrastructure": [],
                "source_sha": identity["commit_sha"], "platform": case["platform"], "suite": case["suite"],
                "scenario": case["scenario"], "fixture_set": case["fixture"],
                "fixture_sha256": FROZEN_FIXTURE_SHA256[case["fixture"]]}
            if timing_failure is not None:
                details["bounded_diagnostics"] = timing_failure[1]
            if invocation_fault == "case infrastructure":
                details["infrastructure"] = [{"code": "cleanup-failed", "message": "Synthetic cleanup failure"}]
            (evidence / "case-manifest.json").write_text(json.dumps(details))
            if receipt_suite is not None:
                message = error(evidence) if callable(error) else error
                (evidence / "visual-identity-runner.json").write_text(json.dumps({
                    "suite": receipt_suite, "verdict": verdict, "error": message}))
            if invocation_fault != "missing log":
                (evidence / "xcodebuild.log").write_text("SwiftCompile synthetic\n" if invocation_fault == "rebuild" else "test-without-building\n")
            (evidence / "xcodebuild-reuse.json").write_text(json.dumps({"products_unchanged": True}))
            sessions = [("-" + entry["name"], entry["selector"]) for entry in FILTER_PERSON_SESSIONS] if case["suite"] == "filter-person" else [
                ("", tracer.resolve_suite_selector(case["platform"], case["suite"]))]
            (evidence / "official-summary.json").write_text(json.dumps({"totalTestCount": len(sessions),
                "passedTests": 0 if timing_failure else len(sessions), "failedTests": len(sessions) if timing_failure else 0,
                "skippedTests": 0, "result": "Failed" if timing_failure else "Passed"}))
            for suffix, selector in sessions:
                (evidence / ("xcodebuild" + suffix + "-reuse.json")).write_text(json.dumps({"products_unchanged": invocation_fault != "changed products"}))
                bundle, method = selector.split("/", 1)
                failure = ({key: timing_failure[0][key] for key in ("failure_phase", "failure_class", "first_failure")}
                           if timing_failure else {})
                (evidence / ("official-tests" + suffix + ".json")).write_text(json.dumps({"testNodes": [{
                    "nodeType": "Unit test bundle", "name": bundle, "children": [{
                        "nodeType": "Test Case", "nodeIdentifier": method + "()",
                        "result": "Failed" if timing_failure else "Passed", **failure}]}]}))
            if timing_failure and "validator_failure_message" in timing_failure[0]:
                (evidence / "visual-identity-runner.json").write_text(json.dumps({"suite": case["suite"],
                    "verdict": "FAIL", "error": timing_failure[0]["validator_failure_message"]}))
            if invocation_fault == "official error":
                (evidence / "official-summary.json").write_text("{}")
            if invocation_fault == "missing method":
                (evidence / "official-tests.json").unlink()
            return runner_exit

        with mock.patch.object(tracer, "run_runner", side_effect=runner), \
                mock.patch.object(tracer, "workspace_preflight"), mock.patch.object(tracer, "run_identity", return_value=identity), \
                mock.patch.object(tracer, "source_metadata", return_value=(".github/workflows/ci-nightly.yml" if nightly else None, False)), \
                mock.patch.object(tracer.shutil, "disk_usage", return_value=mock.Mock(total=200 * 1024**3, free=100 * 1024**3)), \
                mock.patch.object(tracer, "toolchain", return_value={"versions": {"python": "test"}, "signing_mode": "not-applicable"}), \
                mock.patch.dict(os.environ, {"GITHUB_RUN_ID": "10", "GITHUB_RUN_ATTEMPT": "1"}):
            exit_code = tracer.main(["--platform", case["platform"], "--destination", "unused", "--manifest", str(manifest),
                                     "--output-dir", str(output)] + options)
        return exit_code, output / "records", json.loads((output / "records/trace.json").read_text()), \
            json.loads((output / "records/summary.json").read_text())

    def test_person_and_display_rejections_publish_the_whole_failing_input(self):
        import hashlib
        from PIL import Image, ImageOps, ImageFilter
        from ci_failure_diagnostics import public_fixture_validator_scope, canonical_first_failure_png
        from ci_review_packages import export_shard, read_failure_package
        from strict_e2e_filter_contract import target_album_frame_identity
        from strict_e2e_filter_contract_test_fixtures import _fixture_png, _side_by_side, _write_switch_display_bridge
        from test_strict_e2e_filter_contract import DisplayPolicyVisualContractTests, AlbumEditSwitchVisualContractTests
        from test_album_server_narrow_contract import _write_server_switch_pass

        def display_frame(fixture, mark="A3", side_gap=True):
            with Image.open(io.BytesIO(_fixture_png(mark, fixture))) as source:
                photo = source.convert("RGB")
            frame = ImageOps.fit(photo, (1170, 2532)).filter(ImageFilter.GaussianBlur(146.25))
            fitted = ImageOps.contain(photo, frame.size)
            top = (frame.height - fitted.height) // 2
            frame.paste(fitted, (0, top))
            # Three native columns inside the left photo region fail the side-gap check,
            # while the full-photo match still permits the real foreground crop.
            if side_gap:
                frame.paste((0, 0, 0), (84, top, 87, top + fitted.height))
            buffer = io.BytesIO()
            frame.save(buffer, format="PNG")
            return buffer.getvalue()

        black = io.BytesIO()
        Image.new("RGB", (320, 180), "black").save(black, format="PNG")
        displays = {fixture: display_frame(fixture) for fixture in ("a", "b")}
        cases = (("ios", "iphone", "filter-person", "a", "person-normal-1", "person"),
                 ("ios", "iphone", "filter-person", "b", "person-conflict-normal-1", "person"),
                 ("ios", "iphone", "filter-person", "a", "person-nofaces-1", "person"),
                 ("ios", "iphone", "filter-vision", "a", "vision-solo-1", "vision"),
                 ("ios", "iphone", "display-policy", "a", "display-after", "display"),
                 ("tvos", "tv", "tvos-display-policy", "a", "display-after", "display"),
                 ("tvos", "tv", "tvos-switch", "a", "display-after", "display"),
                 ("ios", "iphone", "filter-person", "a", "person-normal-1", "malformed"),
                 ("ios", "iphone", "filter-person", "a", "person-conflict-normal-1", "missing"),
                 ("ios", "iphone", "filter-person", "a", "person-conflict-normal-1", "unreadable"),
                 ("ios", "iphone", "display-policy", "a", "display-after", "display-black"),
                 ("ios", "iphone", "display-policy", "a", "display-after", "display-malformed"),
                 ("ios", "iphone", "filter-edit-switch", "a", "album-switch-b-play-1", "edit"),
                 ("ios", "iphone", "filter-edit-switch", "a", "album-switch-b-play-1", "edit-member"),
                 ("ios", "iphone", "filter-person", "a", "person-nofaces-1", "person-json"),
                 ("ios", "iphone", "filter-vision", "a", "vision-solo-1", "vision-json"),
                 ("tvos", "tv", "tvos-switch", "a", "switch-b-single-after", "switch-single"),
                 ("tvos", "tv", "tvos-switch", "a", "display-before-candidate-01", "candidate"),
                 ("tvos", "tv", "tvos-switch", "a", "display-before-candidate-01", "candidate-malformed"))
        for platform, device, suite, fixture, name, kind in cases:
            with self.subTest(suite=suite, fixture=fixture, name=name, kind=kind), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                picture_fixture = "b" if suite == "tvos-switch" else fixture
                failing = displays[picture_fixture] if kind == "display" else (
                    b"malformed public PNG" if kind in {"malformed", "display-malformed", "candidate-malformed"} else
                    _fixture_png("A4", "b") if kind == "edit" else
                    _fixture_png("A1") if kind == "edit-member" else
                    _fixture_png("A4") if kind == "person-json" else
                    _fixture_png("A2") if kind == "vision-json" else
                    display_frame("a", "A2", side_gap=False) if kind == "candidate" else
                    _fixture_png("A2") if kind in {"missing", "unreadable"} else black.getvalue())
                case = {"platform": platform, "device": device, "configuration": "Debug" if suite in {"filter-person", "filter-vision"} else "Release",
                        "suite": suite, "scenario": "normal", "fixture": fixture}
                status = "UNRECOGNIZABLE" if kind == "malformed" else "BLACK"
                expected = ("The after-change frame must be a recognizable, stable single-photo frame" if kind == "display" else
                            f"Unrecognizable input cannot count as passing: status={status} mark=None")
                expected = {
                    "missing": "Missing visual input person-conflict-normal-1.png",
                    "unreadable": "cannot read visual input person-conflict-normal-1.png: synthetic unreadable PNG",
                    "display-black": "after-change cannot use a transition or unknown frame as passing",
                    "display-malformed": "after-change cannot use a transition or unknown frame as passing",
                    "edit": "frames after the album switch must show the public glyph of fixture A: album-switch-b-play-1",
                    "edit-member": "frames after the album switch must belong to non-target album album-a-non-target: ['A1', 'A5']",
                    "person-json": "Simulator Vision cannot substitute for a device; soloOnly must not be marked PASS",
                    "vision-json": "Vision unavailable; soloOnly must not pass by accident",
                    "switch-single": "single photo after server switch cannot use a transition or unknown frame as passing",
                    "candidate": "every slot must show the public glyph of fixture B; observed fixture A in all 1 slot (both axes)",
                    "candidate-malformed": "display-policy screenshot regions cannot be classified: UnidentifiedImageError",
                }.get(kind, expected)
                before = _fixture_png("A3", fixture)
                def reject(evidence):
                    if suite == "filter-person":
                        write_member_manifest(evidence / "member-manifest.json", fixture)
                        for step, mark in (("person-normal-1", "A1"), ("person-conflict-normal-1", "A2"), ("person-nofaces-1", "A4")):
                            (evidence / (step + ".png")).write_bytes(_fixture_png(mark, fixture))
                        (evidence / "person-results.json").write_text(json.dumps({"cases": {
                            "solo_only": {"environment": "simulator", "verdict": "PASS" if kind == "person-json" else "UNVERIFIED"}}}))
                    elif suite == "filter-vision":
                        write_member_manifest(evidence / "member-manifest.json", fixture)
                        (evidence / "vision-environment.json").write_text(json.dumps({
                            "environment": "device", "vision_available": kind != "vision-json",
                            "qualified_marks": ["A2"], "face_counts": {"A2": 1}}))
                    elif suite == "filter-edit-switch":
                        AlbumEditSwitchVisualContractTests()._write_valid_evidence(evidence, fixture)
                    elif suite == "tvos-switch":
                        _write_server_switch_pass(evidence)
                        _write_switch_display_bridge(evidence)
                        (evidence / "switch-b-playback.png").write_bytes(_fixture_png("A1", "b"))
                        (evidence / "observed-ids-after-switch.json").write_bytes((evidence / "observed-ids.json").read_bytes())
                        (evidence / "empty-selection-after-switch.json").write_text(json.dumps({
                            "selection_source": "accessibility_ui", "album_summary": "筛选相册 0 个相册 · 0 张照片",
                            "person_summary": "筛选人物 0 个人物 · 0 张照片"}))
                        if kind in {"candidate", "candidate-malformed"}:
                            (evidence / "display-before-candidate-02.png").write_bytes((evidence / "display-before.png").read_bytes())
                            policy_path = evidence / "display-policy.json"
                            policy = json.loads(policy_path.read_text())
                            policy.update(before_candidate_steps=["display-before-candidate-01", "display-before-candidate-02"],
                                          selected_before_step="display-before-candidate-02")
                            policy_path.write_text(json.dumps(policy))
                            (evidence / (name + ".png")).write_bytes(display_frame("b", "A2", side_gap=False))
                            self.assertEqual("PASS", require_visual_identity(evidence, suite, fixture_set=fixture)["verdict"])
                    else:
                        DisplayPolicyVisualContractTests()._write_evidence(evidence,
                            before=_side_by_side(_fixture_png("A1"), _fixture_png("A2")), after=displays["a"])
                    failing_path = evidence / (name + ".png")
                    failing_path.write_bytes(failing)
                    if kind == "missing":
                        failing_path.unlink()
                    with ExitStack() as stack:
                        if kind == "unreadable":
                            original_read = Path.read_bytes
                            def read_bytes(path):
                                if path == failing_path:
                                    raise PermissionError("synthetic unreadable PNG")
                                return original_read(path)
                            stack.enter_context(mock.patch.object(Path, "read_bytes", read_bytes))
                        stack_error = stack.enter_context(self.assertRaisesRegex(CommandError,
                            "^Visual assertion failed; cannot mark SUCCESS: " + re.escape(expected)))
                        with public_fixture_validator_scope(evidence, screenshots=True):
                            # A real previous input must not survive a later image rejection.
                            target_album_frame_identity(before, fixture, screenshot_name="album-play-1.png")
                            require_visual_identity(evidence, suite, fixture_set=fixture)
                    return str(stack_error.exception.__cause__)
                code, records, trace, summary = self._produce_validator_records(
                    root, reject, case=case, receipt_suite=suite, nightly=True)
                expected_shard = (0, "passed", 2) if suite == "filter-vision" else (1, "failed", 2)
                self.assertEqual(expected_shard, (code, summary["status"], trace["warm"][0]["exit_code"]))
                self.assertTrue(trace["warm"][0]["automated_contract_failed"])
                methods = trace["warm"][0]["official_methods"]
                self.assertEqual(3 if suite == "filter-person" else 1, len(methods))
                self.assertTrue(all(method["result"] == "Passed" for method in methods))
                failed = summary["population"]["observed"][0]
                self.assertEqual("failed", failed["outcome"])
                self.assertEqual(2, failed["attempts"][0]["exit_code"])
                if kind in {"missing", "unreadable", "edit", "edit-member", "switch-single", "display-black", "display-malformed", "candidate-malformed"}:
                    self.assertEqual("[redacted validator failure]", failed["validator_failure_message"])
                elif kind in {"person-json", "vision-json"}:
                    self.assertEqual(expected + "; context unresolved", failed["validator_failure_message"])
                elif kind == "candidate":
                    self.assertEqual(expected, failed["validator_failure_message"])
                else:
                    self.assertIn("screenshot " + name + ".png", failed["validator_failure_message"])
                published = root / "published"
                self.assertEqual(0, export_shard(records.parent, published))
                if kind in {"malformed", "missing", "unreadable", "display-malformed", "candidate-malformed", "person-json", "vision-json"}:
                    self.assertEqual("unavailable", failed["first_failure"]["screenshot"]["status"])
                    self.assertEqual([], list(published.rglob("first-failure.png")))
                else:
                    self.assertEqual("validated-input", failed["first_failure"]["screenshot"]["status"])
                    package = next(published.rglob("attempt-1"))
                    manifest = read_failure_package(package, summary)
                    expected_sha = hashlib.sha256(canonical_first_failure_png(failing)[0]).hexdigest()
                    self.assertEqual(expected_sha, manifest["image_sha256"])
                    self.assertEqual(expected_sha, hashlib.sha256((package / "first-failure.png").read_bytes()).hexdigest())
                    self.assertNotEqual(manifest["image_sha256"], hashlib.sha256(canonical_first_failure_png(before)[0]).hexdigest())
                    if kind in {"edit", "edit-member"}:
                        self.assertNotEqual(manifest["image_sha256"],
                            hashlib.sha256(canonical_first_failure_png(_fixture_png("A5", fixture))[0]).hexdigest())

    def test_target_album_rejection_exports_its_actual_input_bound_to_the_failed_attempt(self):
        from PIL import Image
        from ci_failure_diagnostics import public_fixture_validator_scope
        from ci_review_packages import export_shard, main as package_main
        from strict_e2e_filter_manifest import FILTER_ALBUM_STEPS
        from strict_e2e_filter_contract_test_fixtures import _fixture_png
        case = {"platform": "ios", "device": "ipad", "configuration": "Debug",
                "suite": "filter-album", "scenario": "normal", "fixture": "a"}
        for failed_step in FILTER_ALBUM_STEPS:
            with self.subTest(step=failed_step), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                def reject(evidence):
                    write_member_manifest(evidence / "member-manifest.json", "a")
                    for name in FILTER_ALBUM_STEPS:
                        (evidence / f"{name}.png").write_bytes(_fixture_png("A3"))
                    Image.new("RGB", (1640, 2360), "black").save(evidence / f"{failed_step}.png")
                    with self.assertRaisesRegex(CommandError,
                            rf"0 completed slots.*screenshot {failed_step}\.png") as raised:
                        with public_fixture_validator_scope(evidence, screenshots=True):
                            require_visual_identity(evidence, "filter-album")
                    return str(raised.exception.__cause__)
                code, records, _trace, summary = self._produce_validator_records(
                    root, reject, case=case, receipt_suite="filter-album", nightly=True)
                self.assertEqual(1, code)
                failed = summary["population"]["observed"][0]
                self.assertEqual("validated-input", failed["first_failure"]["screenshot"]["status"])
                self.assertIn(f"screenshot {failed_step}.png", failed["validator_failure_message"])
                published = root / "published"
                self.assertEqual(0, export_shard(records.parent, published))
                package = next(published.rglob("attempt-1"))
                self.assertEqual(0, package_main(["read-failure", "--package", str(package),
                                                  "--summary", str(records / "summary.json")]))
                with Image.open(package / "first-failure.png") as image:
                    self.assertEqual(((0, 0), (0, 0), (0, 0)), image.getextrema())

    def test_empty_album_rejection_publishes_the_result_image_instead_of_the_last_playback_frame(self):
        import hashlib
        from PIL import Image
        from ci_failure_diagnostics import public_fixture_validator_scope
        from ci_review_packages import export_shard, main as package_main
        from test_album_server_narrow_contract import _fixture_png, _write_album_empty_pass
        for platform, device, suite in (("ios", "ipad", "album-empty"), ("tvos", "tv", "tvos-album-empty")):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                case = {"platform": platform, "device": device, "configuration": "Debug",
                        "suite": suite, "scenario": "normal", "fixture": "a"}
                def reject(evidence):
                    _write_album_empty_pass(evidence)
                    # A1 differs from the last successfully validated playback frame, A2.
                    (evidence / "empty-album-result.png").write_bytes(_fixture_png("A1"))
                    with self.assertRaisesRegex(CommandError,
                            "After the empty album, photos from the old non-empty pool must not keep playing") as raised:
                        with public_fixture_validator_scope(evidence, screenshots=True):
                            require_visual_identity(evidence, suite)
                    return str(raised.exception.__cause__)
                code, records, _trace, summary = self._produce_validator_records(
                    root, reject, case=case, receipt_suite=suite, nightly=True)
                self.assertEqual(1, code)
                self.assertEqual("validated-input", summary["population"]["observed"][0]["first_failure"]["screenshot"]["status"])
                published = root / "published"
                self.assertEqual(0, export_shard(records.parent, published))
                package = next(published.rglob("attempt-1"))
                self.assertEqual(0, package_main(["read-failure", "--package", str(package),
                                                  "--summary", str(records / "summary.json")]))
                with Image.open(io.BytesIO(_fixture_png("A1"))) as expected, \
                        Image.open(package / "first-failure.png") as actual:
                    self.assertEqual(expected.size, actual.size)
                    self.assertEqual(hashlib.sha256(expected.convert("RGB").tobytes()).hexdigest(),
                                     hashlib.sha256(actual.convert("RGB").tobytes()).hexdigest())

    def test_warm_child_preparation_timeout_keeps_a_receipt_and_counts_as_missing(self):
        import ci_execution_diagnostics as diagnostics
        import run_strict_ci_tracer as tracer
        import run_strict_e2e as runner
        import strict_e2e_runner_support as support
        from ci_summary import parse_summary
        from ci_nightly import aggregate_nightly
        case = {"platform": "ios", "device": "iphone", "configuration": "Debug",
                "suite": "filter-person", "scenario": "normal", "fixture": "a"}
        identity = {"schema_version": 1, "event": "local", "repository": "sudoHG/immichSlides",
                    "commit_sha": "0" * 40, "tree_sha": "0" * 40, "dirty": False}
        for failed_stage in ("initial-boot", "reset-bootstatus", "reset-readiness", "reset-uninstall"):
            with self.subTest(stage=failed_stage), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                manifest = root / "manifest.json"
                manifest.write_text(json.dumps({"cases": [case], "exclusions": []}))
                output = root / "trace"
                def invoke(command, *_args, **_kwargs):
                    derived = Path(command[command.index("--derived-data-path") + 1])
                    if "--warm-up-only" in command:
                        derived.mkdir(parents=True)
                        (derived / "strict-warm-build.json").write_text(json.dumps({"signing_mode": "adhoc"}))
                        # A reused job ledger must not attribute an earlier case's timeout to this child.
                        ledger = Path(command[command.index("--diagnostics-receipt") + 1])
                        with diagnostics.session(ledger, reuse=True) as recorder:
                            recorder.event("preparation", "simulator-readiness", "timeout", recorder.next_sequence(), elapsed=299)
                        return 0
                    clock = [0.0]
                    boot_calls = []
                    def preparation_command(call, **kwargs):
                        if call[0] == "xcodebuild":
                            self.assertIn(call[1], ("-checkFirstLaunchStatus", "-version"))
                            return subprocess.CompletedProcess(call, 0, "", "")
                        self.assertEqual(["xcrun", "simctl"], call[:2])
                        step = call[2]
                        if step == "bootstatus":
                            boot_calls.append(call)
                        should_timeout = ((failed_stage == "initial-boot" and step == "boot")
                            or (len(boot_calls) == 2 and ((failed_stage == "reset-bootstatus" and step == "bootstatus")
                                or (failed_stage == "reset-readiness" and step == "get_app_container")
                                or (failed_stage == "reset-uninstall" and step == "uninstall"))))
                        if should_timeout:
                            clock[0] += kwargs["timeout"]
                            raise subprocess.TimeoutExpired(call, kwargs["timeout"])
                        return subprocess.CompletedProcess(call, 2 if step == "get_app_container" else 0, "", "")
                    with mock.patch("strict_e2e_build.validate_paths"), \
                            mock.patch("strict_e2e_build.load_warm_build", return_value=({}, root / "unused.xctestrun")), \
                            mock.patch.object(runner, "ensure_disk_for_xcodebuild"), \
                            mock.patch.object(runner, "read_source_sha", return_value=identity["commit_sha"]), \
                            mock.patch.object(runner, "read_source_dirty_paths", return_value=[]), \
                            mock.patch.object(runner.subprocess, "Popen", return_value=mock.Mock()), \
                            mock.patch.object(runner, "wait_for_service", return_value=("127.0.0.1", 12345)), \
                            mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                            mock.patch("ci_execution_diagnostics.Recorder.sample", return_value=None), \
                            mock.patch.object(support.subprocess, "run", side_effect=preparation_command):
                        code = runner.main(command[3:], stdout=io.StringIO(), stderr=io.StringIO())
                    self.assertEqual(124, code)
                    self.assertEqual(0 if failed_stage == "initial-boot" else 2, len(boot_calls))
                    child_manifest = json.loads(Path(command[command.index("--evidence-dir") + 1], "case-manifest.json").read_text())
                    self.assertEqual(("FAILED", 124), (child_manifest["result"], child_manifest["exit_code"]))
                    return code
                with mock.patch.object(tracer, "run_runner", side_effect=invoke), \
                        mock.patch.object(tracer, "workspace_preflight"), mock.patch.object(tracer, "run_identity", return_value=identity), \
                        mock.patch.object(tracer, "source_metadata", return_value=(None, False)), \
                        mock.patch.object(tracer.shutil, "disk_usage", return_value=mock.Mock(total=200 * 1024**3, free=100 * 1024**3)), \
                        mock.patch.object(tracer, "toolchain", return_value={"versions": {"python": "test"}, "signing_mode": "not-applicable"}):
                    self.assertEqual(1, tracer.main(["--platform", "ios", "--destination", "platform=iOS Simulator,id=TEST",
                        "--manifest", str(manifest), "--output-dir", str(output)]))
                summary = parse_summary((output / "records/summary.json").read_text())
                self.assertEqual([], summary["population"]["compiled"])
                failed = summary["population"]["observed"][0]
                self.assertEqual(("failed", "not-run", 124),
                    (failed["outcome"], failed["attempts"][0]["outcome"], failed["attempts"][0]["exit_code"]))
                receipt = failed["first_failure"]
                self.assertEqual(receipt, failed["attempts"][0]["first_failure"])
                expected_step, expected_elapsed = (("simulator-readiness", support.SIMULATOR_READINESS_TIMEOUT_SECONDS)
                    if failed_stage == "reset-readiness" else ("unknown", None) if failed_stage == "reset-uninstall"
                    else ("simulator-bootstatus", support.SIMULATOR_BOOT_TIMEOUT_SECONDS) if failed_stage == "reset-bootstatus"
                    else ("simulator-boot", support.SIMULATOR_COMMAND_TIMEOUT_SECONDS))
                self.assertEqual(("preparation", expected_step, expected_elapsed),
                    (receipt["source"], receipt["step"], receipt["timing"]["wait_elapsed_seconds"]))
                self.assertEqual("not-applicable", receipt["screenshot"]["status"])
                trace = json.loads((output / "records/trace.json").read_text())
                self.assertEqual((124, []), (trace["warm"][0]["exit_code"], trace["warm"][0]["official_methods"]))
                self.assertFalse(trace["warm"][0]["log_present"])
                aggregate = aggregate_nightly(summary["population"]["declared"], [summary], live_in_scope=False)
                self.assertEqual("failed", aggregate["status"])
                self.assertEqual({"equal": False, "scheduled": 1, "executed": 0,
                    "missing": summary["population"]["declared"], "unexpected": [], "duplicates": []}, aggregate["matrix"])
                from ci_summary import identity_key
                self.assertEqual(["producer infrastructure failure: " + str(summary["infrastructure"]),
                    "producer failed: " + summary["run"]["shard"], "executed matrix differs from scheduled matrix",
                    "failed: " + identity_key(failed["identity"])], aggregate["errors"])

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

    def test_tracer_checkpoints_retain_a_child_load_timeout_that_persisted_nothing(self):
        import run_strict_ci_tracer as tracer
        checkpoints = []
        write_summary = tracer.write_summary
        def capture(summary, records):
            checkpoints.append(json.loads(json.dumps(summary)))
            return write_summary(summary, records)
        with tempfile.TemporaryDirectory() as raw, mock.patch.object(tracer, "write_summary", side_effect=capture):
            code, records, trace, summary = self._produce_validator_records(Path(raw), None,
                receipt_suite=None, runner_exit=65, child_load_timeout=True)
            self.assertEqual((1, "failed", 65), (code, summary["status"], trace["warm"][0]["exit_code"]))
            self.assertEqual("failed", summary["population"]["observed"][0]["outcome"])
            self.assertTrue(summary.get("bounded_diagnostics", {}).get("truncated"))
            ledger = json.loads((records.parent / "bounded-diagnostics.json").read_text())
            self.assertTrue(ledger["receipt"]["truncated"])
            after_child = [entry for entry in checkpoints if entry["population"]["observed"][0]["outcome"] == "failed"]
            self.assertGreater(len(after_child), 1)
            self.assertTrue(all(entry.get("bounded_diagnostics", {}).get("truncated") for entry in after_child))

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
                                       "^unreadable public glyph slot: conflicting public background patterns; slot 1 \\(both axes\\); screenshot switch-b-play-1.png$") as raised:
                evaluate_server_switch_evidence(evidence)
            return str(raised.exception)

        expected = "unreadable public glyph slot: conflicting public background patterns; slot 1 (both axes); screenshot switch-b-play-1.png"
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
        import ci_execution_diagnostics as diagnostics
        import strict_e2e_runner_support as support
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
            receipt_path = Path(raw) / "preparation.json"
            clock, query_budgets = [0.0], []
            def stats(command, **kwargs):
                if command[0] == "xcrun":
                    self.assertEqual(command, ["xcrun", "simctl", "spawn", "private-input",
                                               "launchctl", "print", "system/com.apple.lsd"])
                    query_budgets.append(kwargs["timeout"])
                    clock[0] += kwargs["timeout"]
                    raise subprocess.TimeoutExpired(["private-input"], kwargs["timeout"], output="private-input")
                return subprocess.CompletedProcess(command, 0,
                    "12 10 R /private-input/xcodebuild\n4 30 S /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/com.apple.CoreSimulator.CoreSimulatorService\n9 20 S /private-input/unknown-name\n" if command[0] == "/bin/ps"
                    else "Mach Virtual Memory Statistics: (page size of 4096 bytes)\nPages free: 10.\n", "")
            with diagnostics.session(receipt_path) as recorder, \
                    mock.patch.object(support, "boot_simulator", return_value=""), \
                    mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                    mock.patch.object(diagnostics.subprocess, "run", side_effect=stats), \
                    mock.patch.dict(os.environ, {"ImageVersion": "20261016.1.2"}):
                with self.assertRaisesRegex(support.InfrastructureTimeout, "simulator-readiness timed out after 300.0s"):
                    support.prepare_simulator("private-input", report=lambda line: None, should_check_app=False)
            self.assertEqual([10, 20, 40, 60, 60, 60, 50], query_budgets)
            self.assertEqual(1, tracer.main(["--platform", "ios", "--destination", "unavailable",
                "--manifest", str(tracer.ROOT / "scripts/nightly-matrix.json"), "--shard", selected["id"],
                "--output-dir", str(output), "--preparation-failed", "--preparation-diagnostics", str(receipt_path)]))
            runner.assert_not_called()
            summary = parse_summary((output / "records/summary.json").read_text())
            validate_shard(summary, identity, summary["run"], summary["hashes"], expected)
            self.assertEqual(expected, summary["population"]["declared"])
            self.assertEqual([], summary["population"]["compiled"])
            self.assertEqual(expected, [entry["identity"] for entry in summary["population"]["observed"]])
            self.assertEqual("failed", summary["status"])
            self.assertEqual("simulator-preparation-failed", summary["infrastructure"][0]["code"])
            for item in summary["population"]["observed"]:
                receipt = item["first_failure"]
                self.assertEqual(receipt, item["attempts"][0]["first_failure"])
                self.assertEqual(("preparation", "simulator-readiness", None),
                    (receipt["source"], receipt["step"], receipt["timing"]["deadline_seconds"]))
                self.assertAlmostEqual(300, receipt["timing"]["wait_elapsed_seconds"], places=1)
                self.assertEqual("not-applicable", receipt["screenshot"]["status"])
                self.assertEqual("unknown", receipt["state"]["app"])
            events = summary["bounded_diagnostics"]["events"]
            self.assertIsNone(summary["bounded_diagnostics"]["collection_seconds"]["fixture"])
            self.assertEqual([300], [event["elapsed_seconds"] for event in events
                                     if event["phase"] == "simulator-readiness" and event["state"] == "timeout"])
            queries = [event for event in events if event["phase"] == "simulator-preparation"
                       and event["state"] == "reap-completed"]
            self.assertEqual(query_budgets, [event["elapsed_seconds"] for event in queries])
            for query in queries:
                self.assertEqual(["started", "timeout", "reap-completed"],
                                 [event["state"] for event in events if event["sequence"] == query["sequence"]])
            self.assertNotIn("private-input", json.dumps(summary["bounded_diagnostics"]))
            samples = [event["sample"] for event in events if event["sample"] is not None]
            self.assertEqual(2, len(samples))
            self.assertEqual([20261016, 1, 2], samples[0]["image_version"])
            self.assertEqual(40960, samples[0]["memory_free_bytes"])
            self.assertEqual([{"name": "CoreSimulatorService", "state": "sleeping", "count": 1,
                              "cpu_percent": 4.0, "rss_bytes": 30720},
                             {"name": "xcodebuild", "state": "running", "count": 1,
                              "cpu_percent": 12.0, "rss_bytes": 10240}], samples[0]["processes"])
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

    def test_preparation_sampling_precedes_deadline_and_non_timeout_failure_has_no_end_state(self):
        import ci_execution_diagnostics as diagnostics
        import strict_e2e_runner_support as support
        clock = [0.0]
        def sample():
            clock[0] += 0.2
            return None
        def boot(*args, **kwargs):
            self.assertEqual(600.2, kwargs["deadline"])
            raise CommandError("Simulator boot failed (exit 65).")
        with diagnostics.session() as recorder, mock.patch.object(diagnostics, "system_sample", side_effect=sample), \
                mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(support, "boot_simulator", side_effect=boot):
            with self.assertRaisesRegex(CommandError, r"^Simulator boot failed \(exit 65\)\.$"):
                support.prepare_simulator("unused", report=lambda line: None)
            self.assertEqual(["started"], [event["state"] for event in recorder.events])

    def test_xcode_timeout_retains_bounded_public_progress_without_changing_failure(self):
        import ci_execution_diagnostics as diagnostics
        import run_strict_e2e as runner
        from ci_bounded_diagnostics import validate_receipt
        clock = [0.0]
        with tempfile.TemporaryDirectory() as raw, diagnostics.session() as recorder, \
                mock.patch.object(runner.subprocess, "run") as run, \
                mock.patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(diagnostics, "system_sample", return_value=None):
            log = Path(raw) / "xcode.log"
            bundle = Path(raw) / "private-input.xcresult"
            bundle.mkdir()
            def timeout(*args, **kwargs):
                clock[0] = 600
                log.write_text("private-input\nTest Suite 'All tests' started\n")
                raise subprocess.TimeoutExpired(["private-input"], 600)
            run.side_effect = timeout
            for index in range(diagnostics.MAX_EVENTS):
                recorder.event("preparation", "simulator-container", "completed", index)
            with self.assertRaisesRegex(CommandError, "xcodebuild timed out after 600.0s") as failure:
                runner.run_command(["xcodebuild", "-resultBundlePath", str(bundle)], cwd=Path(raw), environment={},
                                   log_path=log, timeout_seconds=600)
            self.assertEqual(2, failure.exception.code)
            self.assertIsInstance(failure.exception.__cause__, subprocess.TimeoutExpired)
            receipt = recorder.receipt()
            validate_receipt(receipt)
            self.assertIsNone(receipt["collection_seconds"]["fixture"])
            events = receipt["events"]
            self.assertEqual(["timeout", "after-reap"], [event["state"] for event in events[-2:]])
            self.assertEqual("test-execution", events[-1]["phase"])
            self.assertEqual(600, events[-1]["elapsed_seconds"])
            self.assertEqual({"bundle": True, "summary": False, "tests": False}, events[-1]["official_exports"])
            self.assertEqual(diagnostics.MAX_EVENTS, len(events))
            self.assertTrue(receipt["truncated"])
            from ci_bounded_diagnostics import render_receipt
            self.assertIn("xcode: test-execution/after-reap at 600 s", render_receipt(receipt))
            self.assertNotIn("private-input", json.dumps(receipt))
        with tempfile.TemporaryDirectory() as raw, diagnostics.session() as recorder, \
                mock.patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 65)):
            self.assertEqual(65, runner.run_command(["xcodebuild"], cwd=Path(raw), environment={},
                                                  log_path=Path(raw) / "passed.log", timeout_seconds=600))
            self.assertNotIn("completed", [event["state"] for event in recorder.events])

    def test_successful_preparation_keeps_anomaly_headroom_and_evictable_start_events(self):
        import ci_execution_diagnostics as diagnostics
        import strict_e2e_runner_support as support
        sample = {"cpu_percent": 1, "memory_free_bytes": 1, "load_average": [1, 1, 1],
                  "runner_hosted": False, "image_version": None, "processes": []}
        with diagnostics.session() as recorder, mock.patch.object(diagnostics, "system_sample", return_value=sample), \
                mock.patch.object(support, "boot_simulator", return_value=""), \
                mock.patch.object(support, "wait_for_simulator_app_response", return_value=(None, "")):
            support.prepare_simulator("unused", report=lambda line: None)
            self.assertEqual(["started", "completed"], [event["state"] for event in recorder.events])
            self.assertIsNone(recorder.events[0]["sample"])
            recorder.charged["preparation"] = 4.7
            with mock.patch.object(diagnostics, "system_sample", return_value=sample) as collect, \
                    mock.patch.object(support, "boot_simulator", side_effect=support.InfrastructureTimeout("simulator-boot", 60)):
                with self.assertRaisesRegex(support.InfrastructureTimeout, "simulator-boot timed out after 60.0s"):
                    support.prepare_simulator("unused", report=lambda line: None)
                self.assertEqual(["started", "timeout"], [event["state"] for event in recorder.events[-2:]])
                self.assertIsNone(recorder.events[-2]["sample"])
                self.assertEqual(sample, recorder.events[-1]["sample"])
                collect.assert_called_once_with()
        recorder = diagnostics.Recorder()
        recorder.event("preparation", "simulator-preparation", "timeout", 0, sample=sample)
        for index in range(1, 512):
            recorder.event("preparation", "simulator-container", "completed", index)
        recorder.event("preparation", "simulator-container", "completed", 512)
        self.assertEqual([0, *range(2, 513)], [event["sequence"] for event in recorder.events])
        recorder = diagnostics.Recorder()
        for index in range(512):
            recorder.event("preparation", "simulator-preparation", "timeout", index)
        recorder.event("preparation", "simulator-container", "completed", 512)
        self.assertEqual(list(range(512)), [event["sequence"] for event in recorder.events])

    def test_semantically_successful_nonzero_simulator_commands_finish_their_events(self):
        import ci_execution_diagnostics as diagnostics
        import strict_e2e_runner_support as support
        responses = [subprocess.CompletedProcess([], 149, "", "Current state: Booted"),
                     subprocess.CompletedProcess([], 0, "", ""), subprocess.CompletedProcess([], 2, "", "absent")]
        with diagnostics.session() as recorder, mock.patch.object(support.subprocess, "run", side_effect=responses):
            support.boot_simulator("unused")
            self.assertIsNone(support.simulator_app_container("unused", "public.bundle", deadline=1000000000000))
        self.assertEqual([("simulator-boot", "started"), ("simulator-boot", "completed"),
                          ("simulator-bootstatus", "started"), ("simulator-bootstatus", "completed"),
                          ("simulator-container", "started"), ("simulator-container", "completed")],
                         [(event["phase"], event["state"]) for event in recorder.events])
        with diagnostics.session() as recorder, mock.patch.object(support.subprocess, "run", return_value=
                subprocess.CompletedProcess([], 149, "", "Unable to boot")):
            with self.assertRaisesRegex(CommandError, r"Simulator boot failed \(exit 149\)"):
                support.boot_simulator("unused", report=lambda line: None)
            self.assertEqual([("simulator-boot", "started")], [(event["phase"], event["state"]) for event in recorder.events])
        with diagnostics.session() as recorder, mock.patch.object(support.subprocess, "run", return_value=
                subprocess.CompletedProcess([], 1, "", "Unable to read container")):
            with self.assertRaisesRegex(CommandError, r"Could not determine whether the App container exists \(simctl get_app_container exit 1\)"):
                support.simulator_app_container("unused", "public.bundle")
            self.assertEqual([("simulator-container", "started")], [(event["phase"], event["state"]) for event in recorder.events])


    def test_hung_diagnostic_is_capped_and_invalid_measurements_cannot_break_a_summary(self):
        import ci_execution_diagnostics as diagnostics
        from ci_summary import parse_summary
        from test_ci_summary import valid_summary
        for scope, budget in {"preparation": 5, "xcode": 10}.items():
            with self.subTest(scope=scope):
                recorder = diagnostics.Recorder()
                recorder.charged[scope] = budget - 0.04
                clock = [0.0]
                def wait(seconds):
                    clock[0] += seconds
                    return False
                done = mock.Mock(wait=mock.Mock(side_effect=wait))
                with mock.patch.object(diagnostics.threading, "Event", return_value=done), \
                        mock.patch.object(diagnostics.threading.Thread, "start"), \
                        mock.patch.object(diagnostics.time, "perf_counter", side_effect=lambda: clock[0]):
                    self.assertIsNone(recorder.collect(scope, lambda: 1, cap=0.5))
                self.assertAlmostEqual(0.03, done.wait.call_args.args[0])
                self.assertAlmostEqual(budget - 0.01, recorder.charged[scope])
        with diagnostics.session() as recorder:
            done = mock.Mock(wait=mock.Mock(return_value=False))
            with mock.patch.object(diagnostics.threading, "Event", return_value=done), \
                    mock.patch.object(diagnostics.threading.Thread, "start"), \
                    mock.patch.object(diagnostics.time, "perf_counter", return_value=0):
                self.assertIsNone(recorder.collect("preparation", lambda: 1, cap=0.02))
                done.wait.assert_called_once_with(0.02)
            with mock.patch.object(diagnostics.threading.Thread, "start", side_effect=RuntimeError("private-input")):
                self.assertIsNone(recorder.collect("preparation", lambda: 1, cap=0.02))
            recorder.event("preparation", "simulator-preparation", "timeout", 0, elapsed=float("inf"), cpu=float("nan"))
            summary = valid_summary()
            recorder.attach(summary)
            parse_summary(json.dumps(summary))
            self.assertTrue(summary["bounded_diagnostics"]["truncated"])
            self.assertEqual(0, summary["bounded_diagnostics"]["events"][0]["elapsed_seconds"])
            recorder.events[0]["phase"] = "private-input"
            recorder.attach(summary)
            self.assertNotIn("bounded_diagnostics", summary)
        recorder = diagnostics.Recorder()
        recorder.ledger_remaining = 0.015
        clock = [0.0]
        def stalled(seconds):
            clock[0] += seconds
            return False
        done = mock.Mock(wait=mock.Mock(side_effect=stalled))
        with mock.patch.object(diagnostics.threading, "Event", return_value=done), \
                mock.patch.object(diagnostics.threading.Thread, "start") as start, \
                mock.patch.object(diagnostics, "_TRUNCATION_REPORTED", False), \
                mock.patch.object(diagnostics, "report_truncation") as report, \
                mock.patch.object(diagnostics.time, "perf_counter", side_effect=lambda: clock[0]):
            self.assertIsNone(recorder.ledger_io(lambda: True))
            done.wait.assert_called_once_with(0.015)
            report.assert_called_once_with("io-timeout")
            start.reset_mock()
            self.assertIsNone(recorder.ledger_io(lambda: True))
            start.assert_not_called()
        self.assertEqual(0, recorder.ledger_remaining)
        self.assertTrue(recorder.truncated)

    def test_case_sampler_preserves_numeric_categories_and_failure_windows(self):
        import ci_execution_diagnostics as diagnostics
        from ci_summary import parse_summary
        from test_ci_summary import valid_summary
        import strict_e2e_resource_diagnostics as resources
        from types import SimpleNamespace
        rows = "10 1 1 launchd_sim    \n11 10 30 immichSlides   \n12 10 5 daemon         \n13 10 7 testmanagerd_sim\n14 1 11 xcodebuild      \n15 1 13 PRIVATE_SENTINEL process\n"
        with mock.patch.object(resources.sys, "platform", "darwin"), \
                mock.patch.object(resources, "app_on_device", return_value=True), \
                mock.patch.object(resources.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=rows)) as ps, \
                mock.patch.object(resources.os, "getloadavg", return_value=(4, 3, 2)):
            # Use the public sampling seam, including parser and category precedence.
            sample = resources.resource_sample(SimpleNamespace(idle=lambda: 25), "device", 0.1)
        self.assertEqual({"idle_percent": 25, "load_1m": 4,
                          "cpu_percent": {"app": 30, "simulator_daemons": 6, "test_tools": 18, "other": 13}}, sample)
        self.assertNotIn("PRIVATE_SENTINEL", json.dumps(sample))
        self.assertIn("ucomm=", ps.call_args.args[0][-1])
        for process_rows, belongs, expected in (
                (rows, False, None), (rows.replace("11 10 30 immichSlides   \n", ""), True, None),
                (rows.replace("30 immichSlides", "0 immichSlides"), True, 0)):
            with self.subTest(app_membership=belongs, app_cpu=expected), \
                    mock.patch.object(resources.sys, "platform", "darwin"), \
                    mock.patch.object(resources, "app_on_device", return_value=belongs), \
                    mock.patch.object(resources.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=process_rows)):
                observation = resources.resource_sample(SimpleNamespace(idle=lambda: 25), "device", 0.1)
                self.assertEqual(expected, observation["cpu_percent"]["app"])
                with mock.patch.object(resources.time, "monotonic", side_effect=[0, 2]), \
                        mock.patch.object(resources.time, "time", side_effect=[100, 102]):
                    sampler = resources.CaseSampler(diagnostics.Recorder(), "device")
                    sampler.samples = [{"elapsed_seconds": 2, **observation}]
                    sampler.stop()
                    sampler.bind_failure(sampler.epoch + 2)
                case = sampler.recorder.receipt()["case_resources"][0]
                self.assertEqual(expected, case["app_cpu_percent_peak"])
                self.assertEqual(expected, case["failure_samples"][0]["cpu_percent"]["app"])
        clock = [0.0]
        waits = [False, False, False, True]
        def tick(seconds):
            clock[0] += seconds
            return waits.pop(0)
        event = SimpleNamespace(wait=tick, set=lambda: None, is_set=lambda: False)
        recorder = diagnostics.Recorder()
        with mock.patch.object(resources.threading, "Event", return_value=event), \
                mock.patch.object(resources.threading, "Thread", side_effect=lambda *, target, daemon: SimpleNamespace(start=target, join=lambda timeout: None)), \
                mock.patch.object(resources, "HostProbe", return_value=SimpleNamespace(sample=lambda: sample, close=lambda: None, unavailable=False)), \
                mock.patch.object(resources, "resource_sample", return_value=sample), \
                mock.patch.object(resources, "process_sample", return_value=sample["cpu_percent"]), \
                mock.patch.object(resources.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(resources.time, "time", side_effect=lambda: 100 + clock[0]), \
                mock.patch.object(resources.time, "perf_counter", return_value=0):
            sampler = resources.CaseSampler(recorder, "device").start()
            sampler.stop()
            sampler.bind_failure(104)
        summary = valid_summary()
        recorder.attach(summary)
        parse_summary(json.dumps(summary))
        case = summary["bounded_diagnostics"]["case_resources"][0]
        self.assertEqual((3, 25, 25, 4, 30), (case["sample_count"], case["idle_percent_min"],
                         case["idle_percent_median"], case["load_1m_max"], case["app_cpu_percent_peak"]))
        self.assertEqual([2, 4, 6], [row["elapsed_seconds"] for row in case["failure_samples"]])
        self.assertEqual(0, recorder.charged["xcode"], "sampling must preserve the Xcode diagnostic allowance")
        # An App that is absent for part of a case (before launch, relaunch, exit) is not sampler truncation.
        absent_app = {**sample, "cpu_percent": {**sample["cpu_percent"], "app": None}}
        clock = [0.0]
        waits = [False] * 6 + [True]
        event = SimpleNamespace(wait=tick, set=lambda: None, is_set=lambda: False)
        partial = diagnostics.Recorder()
        with mock.patch.object(resources.threading, "Event", return_value=event), \
                mock.patch.object(resources.threading, "Thread", side_effect=lambda *, target, daemon: SimpleNamespace(start=target, join=lambda timeout: None)), \
                mock.patch.object(resources, "HostProbe", return_value=SimpleNamespace(sample=lambda: absent_app, close=lambda: None, unavailable=False)), \
                mock.patch.object(resources, "resource_sample", return_value=absent_app), \
                mock.patch.object(resources, "process_sample", side_effect=[absent_app["cpu_percent"], sample["cpu_percent"]]), \
                mock.patch.object(resources.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(resources.time, "time", side_effect=lambda: 100 + clock[0]), \
                mock.patch.object(resources.time, "perf_counter", return_value=0):
            sampler = resources.CaseSampler(partial, "device").start()
            sampler.stop()
        case = partial.case_resources[0]
        self.assertEqual((6, 30), (case["sample_count"], case["app_cpu_percent_peak"]))
        self.assertFalse(case["truncated"], "a temporarily absent App must not mark the case truncated")
        self.assertGreater(resources.STOP_TIMEOUT_SECONDS, resources.HOST_SAMPLE_TIMEOUT_SECONDS + resources.SAMPLE_COMMAND_TIMEOUT_SECONDS,
                           "stop must outlast the bounded host read and one in-flight process snapshot")
        for defect in ("bad row", rows.replace("30 immichSlides", "nan immichSlides")):
            with mock.patch.object(resources.sys, "platform", "darwin"), \
                    mock.patch.object(resources.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=defect)):
                unavailable = resources.resource_sample(SimpleNamespace(idle=lambda: None), "device", 0.1)
            self.assertTrue(all(value is None for value in unavailable["cpu_percent"].values()))

    def test_slow_process_snapshots_preserve_late_samples_across_a_long_shard(self):
        import ci_execution_diagnostics as diagnostics
        import strict_e2e_resource_diagnostics as resources
        from types import SimpleNamespace
        sample = {"idle_percent": 25, "load_1m": 4, "cpu_percent": dict.fromkeys(resources.RESOURCE_CATEGORIES)}
        clock = [0.0]
        end = [360.0]
        def long_wait(seconds):
            clock[0] = min(end[0], clock[0] + seconds)
            return clock[0] >= end[0]
        def slow_ps(*args, **kwargs):
            clock[0] += 1.1
            return SimpleNamespace(returncode=0, stdout="10 1 4 xcodebuild\n")
        def host_sample():
            clock[0] += 0.02
            return sample
        event = SimpleNamespace(wait=long_wait, set=lambda: None, is_set=lambda: False)
        recorder = diagnostics.Recorder()
        recorder.charged["xcode"] = diagnostics.COLLECTION_BUDGET_SECONDS["xcode"]
        with mock.patch.object(resources.threading, "Event", return_value=event), \
                mock.patch.object(resources.threading, "Thread", side_effect=lambda *, target, daemon: SimpleNamespace(start=target, join=lambda timeout: None)), \
                mock.patch.object(resources, "HostProbe", return_value=SimpleNamespace(sample=host_sample, close=lambda: None, unavailable=False)), \
                mock.patch.object(resources, "resource_sample", return_value=sample), \
                mock.patch.object(resources.sys, "platform", "darwin"), \
                mock.patch.object(resources.subprocess, "run", side_effect=slow_ps) as ps, \
                mock.patch.object(resources.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(resources.time, "time", side_effect=lambda: 100 + clock[0]), \
                mock.patch.object(resources.time, "perf_counter", side_effect=lambda: clock[0]):
            for index in range(5):
                sampler = resources.CaseSampler(recorder, "device").start()
                sampler.stop()
                sampler.bind_failure(sampler.epoch + 358)
                end[0] += 360
        case = recorder.case_resources[-1]
        self.assertTrue(all(case["sample_count"] >= 170 for case in recorder.case_resources))
        self.assertTrue(case["failure_samples"], "late failure must retain nearby resource evidence")
        self.assertGreater(case["failure_samples"][-1]["elapsed_seconds"], 355)
        self.assertTrue(all(case["sampler_wall_seconds"] < 45 for case in recorder.case_resources))
        self.assertLess(sum(case["sampler_wall_seconds"] for case in recorder.case_resources), 181.1)
        self.assertLessEqual(ps.call_count, 164)
        self.assertGreater(ps.call_count, 100)
        self.assertFalse(recorder.case_resources[0]["truncated"], "ticks between process snapshots are intentionally partial")
        self.assertAlmostEqual(ps.call_count * 1.1, sum(case["sampler_wall_seconds"] for case in recorder.case_resources))
        self.assertAlmostEqual(10, recorder.charged["xcode"])
        self.assertEqual(0, recorder.cost["xcode"], "periodic sampling must not consume native diagnostic allowance")
        for previous_cost in (179.6, 180, None):
            recorder = diagnostics.Recorder()
            recorder.case_resources = [{**case, "sequence": 0, "sampler_wall_seconds": previous_cost}]
            with mock.patch.object(resources.threading, "Thread") as thread:
                successor = resources.CaseSampler(recorder, "device").start()
                successor.stop()
            thread.return_value.start.assert_called_once()
            self.assertEqual(0, successor.reserved)
            self.assertTrue(recorder.case_resources[-1]["truncated"])
        missing = diagnostics.Recorder()
        with tempfile.TemporaryDirectory() as raw:
            missing.load(Path(raw) / "absent-ledger.json")
        with mock.patch.object(resources.threading, "Thread") as thread:
            sampler = resources.CaseSampler(missing, "device").start()
            thread.return_value.start.assert_called_once()
            self.assertEqual(0, sampler.reserved)
            sampler.stop()
        self.assertTrue(missing.case_resources[0]["truncated"])

    def test_host_probe_caps_hung_reads_and_total_wait_without_starting_more_workers(self):
        import strict_e2e_resource_diagnostics as resources
        for spent, expected_limit in ((0, 0.2), (4.95, 0.05), (5, None)):
            with self.subTest(spent=spent), mock.patch.object(resources, "Event") as event, \
                    mock.patch.object(resources, "Thread") as worker, \
                    mock.patch.object(resources.time, "perf_counter", return_value=0):
                event.return_value.wait.return_value = False
                event.return_value.is_set.return_value = False
                probe = resources.HostProbe("device")
                probe.spent = spent
                self.assertIsNone(probe.sample())
                self.assertIsNone(probe.sample())
                if expected_limit is None:
                    worker.assert_not_called()
                else:
                    worker.return_value.start.assert_called_once()
                    self.assertAlmostEqual(expected_limit, event.return_value.wait.call_args.args[0])

    def test_host_probe_returns_real_thread_values_and_resumes_after_a_slow_read(self):
        import strict_e2e_resource_diagnostics as resources
        import threading
        from types import SimpleNamespace
        entered, release, closed = threading.Event(), threading.Event(), threading.Event()
        calls = []
        def host_statistics(host, flavor, ticks, count):
            calls.append(True)
            if len(calls) == 1:
                entered.set()
                if not release.wait(3):
                    raise OSError("test release deadline")
            ticks[:] = (65, 0, 37, 0) if len(calls) == 4 else (len(calls) - 1, 0, 0, 0)
            return 0
        with mock.patch.object(resources.sys, "platform", "linux"):
            host = resources.HostCpu()
        host.library = SimpleNamespace(host_statistics=host_statistics)
        host.close = closed.set
        with mock.patch.object(resources, "HostCpu", return_value=host) as constructor, \
                mock.patch.object(resources.time, "monotonic", side_effect=[10, 10.005, 10.010, 11.010]), \
                mock.patch.object(resources.os, "getloadavg", return_value=(6, 5, 4)):
            probe = resources.HostProbe("device")
            try:
                self.assertIsNone(probe.sample())
                self.assertTrue(entered.wait(3))
                self.assertIsNone(probe.sample(), "an in-flight read must not start another worker")
                self.assertEqual(1, len(calls))
                release.set()
                self.assertTrue(probe.done.wait(3))
                before = probe.spent
                observation = probe.sample()
                self.assertIsNotNone(observation, "sampling must resume after the slow worker finishes")
                self.assertEqual((None, 6), (observation["idle_percent"], observation["load_1m"]),
                                 "a quick read after the late worker must not report zero idle")
                self.assertGreater(probe.spent, before)
                recovered = probe.sample()
                self.assertIsNotNone(recovered)
                self.assertEqual(37, recovered["idle_percent"], "a full interval must restore idle evidence")
                constructor.assert_called_once()
            finally:
                release.set()
                probe.close()
                self.assertTrue(closed.wait(3))

    def test_case_sampler_skips_busy_ticks_and_does_not_start_process_reads_after_stop(self):
        import ci_execution_diagnostics as diagnostics
        import strict_e2e_resource_diagnostics as resources
        from types import SimpleNamespace
        sample = {"idle_percent": 25, "load_1m": 4, "cpu_percent": dict.fromkeys(resources.RESOURCE_CATEGORIES)}
        for stop_during_read in (False, True):
            with self.subTest(stop_during_read=stop_during_read):
                clock = [0.0]
                stopped = [False]
                reads = []
                def wait(seconds):
                    clock[0] += seconds
                    return stopped[0] or clock[0] >= 8
                def read():
                    reads.append(True)
                    if len(reads) <= 2:
                        return None
                    stopped[0] = stop_during_read
                    return sample
                event = SimpleNamespace(wait=wait, set=lambda: None, is_set=lambda: stopped[0])
                with mock.patch.object(resources.threading, "Event", return_value=event), \
                        mock.patch.object(resources.threading, "Thread", side_effect=lambda *, target, daemon: SimpleNamespace(start=target, join=lambda timeout: None)), \
                        mock.patch.object(resources, "HostProbe", return_value=SimpleNamespace(sample=read, close=lambda: None, unavailable=False)), \
                        mock.patch.object(resources, "process_sample", return_value=sample["cpu_percent"]) as ps, \
                        mock.patch.object(resources.time, "monotonic", side_effect=lambda: clock[0]), \
                        mock.patch.object(resources.time, "time", side_effect=lambda: 100 + clock[0]):
                    recorder = diagnostics.Recorder()
                    sampler = resources.CaseSampler(recorder, "device").start()
                    sampler.stop()
                if stop_during_read:
                    ps.assert_not_called()
                    self.assertEqual(0, recorder.case_resources[0]["sample_count"])
                else:
                    self.assertEqual(2, recorder.case_resources[0]["sample_count"])
                    self.assertTrue(recorder.case_resources[0]["truncated"])

    def test_case_sampler_refuses_failure_binding_when_wall_clock_jumps(self):
        import ci_execution_diagnostics as diagnostics
        import strict_e2e_resource_diagnostics as resources
        for drift in (-0.51, -0.49, 0, 0.49, 0.51):
            with self.subTest(drift=drift), \
                    mock.patch.object(resources.time, "monotonic", side_effect=[10, 20]), \
                    mock.patch.object(resources.time, "time", side_effect=[100, 110 + drift]):
                recorder = diagnostics.Recorder()
                sampler = resources.CaseSampler(recorder, "device")
                sampler.samples = [{"elapsed_seconds": 5, "idle_percent": 25, "load_1m": 4,
                                    "cpu_percent": dict.fromkeys(resources.RESOURCE_CATEGORIES)}]
                sampler.stop()
                sampler.bind_failure(105)
                case = recorder.case_resources[0]
                self.assertEqual(5 if abs(drift) < 0.5 else None, case["first_failure_elapsed_seconds"])
                self.assertEqual(abs(drift) < 0.5, bool(case["failure_samples"]))

    def test_completed_ledger_io_refunds_unused_precharge(self):
        import ci_execution_diagnostics as diagnostics
        recorder = diagnostics.Recorder()
        clock = [0.0]
        def operation():
            self.assertAlmostEqual(diagnostics.LEDGER_ALLOWANCE_SECONDS - diagnostics.LEDGER_IO_CAP_SECONDS,
                                   recorder.ledger_remaining, msg="precharge remains held until IO completes")
            clock[0] += 0.005
            return True
        with mock.patch.object(diagnostics.time, "perf_counter", side_effect=lambda: clock[0]):
            self.assertTrue(recorder.ledger_io(operation))
        self.assertAlmostEqual(diagnostics.LEDGER_ALLOWANCE_SECONDS - 0.005, recorder.ledger_remaining)
        self.assertAlmostEqual(0.005, recorder.cost["preparation"])
        self.assertFalse(recorder.truncated)

    def test_native_allowance_precharges_timeouts_and_stops_after_twenty_seconds(self):
        import strict_e2e_resource_diagnostics as resources
        from types import SimpleNamespace
        clock = [0.0]
        def wait(seconds):
            clock[0] += seconds
            return False
        with mock.patch.object(resources.threading, "Event", return_value=SimpleNamespace(wait=wait, set=lambda: None)), \
                mock.patch.object(resources.threading, "Thread") as worker, \
                mock.patch.object(resources.time, "perf_counter", side_effect=lambda: clock[0]):
            budget = resources.NativeActivityBudget()
            operation = mock.Mock()
            for sequence in range(10):
                self.assertIsNone(budget.collect(sequence, operation, cap=2))
                self.assertIsNone(budget.collect(sequence, operation, cap=2), "one failed case cannot obtain a second loan")
            self.assertAlmostEqual(20, clock[0])
            self.assertEqual(0, budget.remaining_seconds)
            self.assertEqual(10, worker.return_value.start.call_count)
            self.assertIsNone(budget.collect(10, operation, cap=2))
            self.assertEqual(10, worker.return_value.start.call_count)
            operation.assert_not_called()
        parent = resources.NativeActivityBudget()
        self.assertEqual([2] * 10 + [0], [parent.reserve_case() for _ in range(11)])

    def test_ledger_io_rejects_delayed_results_and_precharges_the_total_pool(self):
        import ci_execution_diagnostics as diagnostics
        from types import SimpleNamespace
        clock = [0.0]
        def delayed(seconds):
            self.assertAlmostEqual(0.1, seconds)
            clock[0] += seconds
            return False
        def start(*, target, daemon):
            target()
            return SimpleNamespace(start=lambda: None)
        recorder = diagnostics.Recorder()
        with mock.patch.object(diagnostics.threading, "Thread", side_effect=start), \
                mock.patch.object(diagnostics.threading, "Event", return_value=SimpleNamespace(wait=delayed, set=lambda: None)), \
                mock.patch.object(diagnostics.time, "perf_counter", side_effect=lambda: clock[0]):
            self.assertIsNone(recorder.ledger_io(lambda: True), "a result outside the wait deadline must not refund its loan")
        self.assertAlmostEqual(1.4, recorder.ledger_remaining)
        self.assertAlmostEqual(0.1, recorder.cost["preparation"])
        clock = [0.0]
        def timeout(seconds):
            clock[0] += seconds
            return False
        recorder = diagnostics.Recorder()
        with mock.patch.object(diagnostics.threading, "Thread") as worker, \
                mock.patch.object(diagnostics.threading, "Event", return_value=SimpleNamespace(wait=timeout)), \
                mock.patch.object(diagnostics, "report_truncation"), \
                mock.patch.object(diagnostics.time, "perf_counter", side_effect=lambda: clock[0]):
            for _ in range(17):
                self.assertIsNone(recorder.ledger_io(lambda: True))
            self.assertLessEqual(worker.return_value.start.call_count, 16)
        self.assertAlmostEqual(1.5, clock[0])
        self.assertEqual(0, recorder.ledger_remaining)

    def test_truncation_logs_one_closed_reason_per_process_without_private_values(self):
        import ci_execution_diagnostics as diagnostics
        from types import SimpleNamespace
        reasons = {"collection-budget-exhausted", "sample-timeout", "collection-timeout", "worker-unavailable",
                   "event-budget-exhausted", "event-cap", "io-pool-exhausted", "io-timeout", "ledger-unavailable",
                   "reserve-failed", "inherited"}
        self.assertEqual(reasons, diagnostics.TRUNCATION_REASONS)
        for reason in sorted(reasons):
            with self.subTest(reason=reason), mock.patch.object(diagnostics, "_TRUNCATION_REPORTED", False), \
                    mock.patch.object(diagnostics.threading, "Thread", side_effect=lambda *, target, daemon: SimpleNamespace(start=target)), \
                    mock.patch.object(diagnostics.os, "write") as write:
                first, second = diagnostics.Recorder(), diagnostics.Recorder()
                diagnostics.report_truncation("private-input /private/path")
                write.assert_not_called()
                first.truncate("private-input /private/path")
                write.assert_not_called()
                first.truncate(reason)
                second.truncate("inherited")
                first.truncate(reason)
                write.assert_called_once_with(2, ("bounded-diagnostics truncated: " + reason + "\n").encode("ascii"))
                self.assertTrue(first.truncated)
                self.assertTrue(second.truncated)

    def test_blocked_truncation_stderr_preserves_the_child_exit_code(self):
        import ci_execution_diagnostics as diagnostics
        child = '''
import importlib.util
import os
import sys
import threading
spec = importlib.util.spec_from_file_location("diagnostics", sys.argv[1])
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)
os.set_blocking(2, False)
try:
    while True:
        os.write(2, b"x" * 4096)
except BlockingIOError:
    pass
os.set_blocking(2, True)
started = threading.Event()
original_thread = threading.Thread
def thread(*, target, daemon):
    def work():
        started.set()
        target()
    return original_thread(target=work, daemon=daemon)
diagnostics.threading.Thread = thread
# The worker keeps the GIL from its signal until the full pipe blocks its write.
sys.setswitchinterval(60)
diagnostics.report_truncation("io-timeout")
assert started.wait(2)
raise SystemExit(65)
'''
        process = subprocess.Popen([sys.executable, "-B", "-c", child, str(Path(diagnostics.__file__).resolve())],
                                   cwd=SCRIPT_DIR, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            self.assertEqual(65, process.wait(timeout=10))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stderr.close()

    def test_runner_forwards_only_one_closed_truncation_line_from_its_child_log(self):
        import run_strict_ci_tracer as tracer
        import ci_execution_diagnostics as diagnostics
        from types import SimpleNamespace
        line = "bounded-diagnostics truncated: io-timeout"
        for rejected in ("private-input", "event-cap", "bounded-diagnostics truncated: private-input /private/path",
                         line + " private-input"):
            with self.subTest(rejected=rejected), tempfile.TemporaryDirectory() as raw:
                def spawn(*args, **kwargs):
                    kwargs["stdout"].write(rejected + "\n" + line + "\nbounded-diagnostics truncated: event-cap\n")
                    kwargs["stdout"].flush()
                    return SimpleNamespace(pid=42, wait=lambda **kwargs: 65)
                with mock.patch.object(tracer.subprocess, "Popen", side_effect=spawn), \
                        mock.patch.object(tracer, "stop_group"), \
                        mock.patch.object(tracer, "group_has_live_members", return_value=False), \
                        mock.patch.object(diagnostics.threading, "Thread", side_effect=lambda *, target, daemon: SimpleNamespace(start=target)), \
                        mock.patch.object(diagnostics.os, "write") as write:
                    self.assertEqual(65, tracer.run_runner(["unused"], Path(raw), Path(raw) / "runner.log", timeout_seconds=2))
                write.assert_called_once_with(2, (line + "\n").encode("ascii"))

    def test_failed_child_reservation_preserves_the_previous_ledger(self):
        import ci_execution_diagnostics as diagnostics
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "job.json"
            with diagnostics.session(path) as recorder:
                recorder.event("preparation", "simulator-preparation", "completed", 1)
            previous = json.loads(path.read_text())
            original_write = Path.write_text
            writes = []
            def fail_reserve(target, *args, **kwargs):
                writes.append(target)
                if len(writes) == 1:
                    raise OSError("reserve write failed")
                return original_write(target, *args, **kwargs)
            with mock.patch.object(Path, "write_text", fail_reserve), \
                    mock.patch.object(diagnostics.Recorder, "save", autospec=True) as save:
                with diagnostics.session(path, reuse=True) as child:
                    self.assertTrue(child.truncated)
                    self.assertEqual(diagnostics.COLLECTION_BUDGET_SECONDS, child.charged)
                save.assert_not_called()
            restored = json.loads(path.read_text())
            self.assertEqual(previous["remaining_seconds"], restored["remaining_seconds"])
            self.assertEqual(previous["receipt"]["collection_seconds"], restored["receipt"]["collection_seconds"])
            self.assertLessEqual(restored["ledger_remaining_seconds"], previous["ledger_remaining_seconds"])
            successor = diagnostics.Recorder()
            successor.load(path)
            self.assertTrue(successor.truncated)

    def test_failed_refund_write_keeps_the_conservative_ledger_balance(self):
        import ci_execution_diagnostics as diagnostics
        for failure in ("error", "late"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as raw:
                recorder = diagnostics.Recorder()
                path = Path(raw) / "job.json"
                clock = [0.0]
                original_write = Path.write_text
                calls = []
                def write(target, *args, **kwargs):
                    calls.append(True)
                    if len(calls) == 2:
                        if failure == "error":
                            raise OSError("refund write failed")
                        clock[0] += diagnostics.LEDGER_REFUND_CAP_SECONDS + 0.001
                    return original_write(target, *args, **kwargs)
                with mock.patch.object(Path, "write_text", write), \
                        mock.patch.object(diagnostics.time, "perf_counter", side_effect=lambda: clock[0]):
                    ledger = {"receipt": recorder.receipt(), "remaining_seconds": {
                        scope: budget - recorder.charged[scope] for scope, budget in diagnostics.COLLECTION_BUDGET_SECONDS.items()}}
                    self.assertIs(recorder._write(path, ledger), True)
                self.assertEqual(2, len(calls))
                self.assertAlmostEqual(diagnostics.LEDGER_ALLOWANCE_SECONDS - diagnostics.LEDGER_IO_CAP_SECONDS,
                                       json.loads(path.read_text())["ledger_remaining_seconds"])

    def test_interleaved_ledger_writers_cannot_replace_or_remove_each_others_temporary_file(self):
        import ci_execution_diagnostics as diagnostics
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "job.json"
            first, second = diagnostics.Recorder(), diagnostics.Recorder()
            first_ledger = {"receipt": first.receipt(), "remaining_seconds": dict(diagnostics.COLLECTION_BUDGET_SECONDS)}
            second_ledger = {"receipt": second.receipt(), "remaining_seconds": dict(diagnostics.COLLECTION_BUDGET_SECONDS)}
            second_ledger["receipt"]["truncated"] = True
            original_replace = Path.replace
            interleaved = []
            def replace(temporary, destination):
                if not interleaved:
                    interleaved.append(True)
                    self.assertIs(second._write(path, second_ledger), True)
                return original_replace(temporary, destination)
            # Run workers synchronously to pause the first at replace and
            # finish the second writer without scheduler-dependent timing.
            with mock.patch.object(diagnostics.threading, "Thread", side_effect=lambda *, target, daemon: SimpleNamespace(start=target)), \
                    mock.patch.object(Path, "replace", replace):
                self.assertIs(first._write(path, first_ledger), True)
            self.assertEqual([True], interleaved)
            self.assertFalse(json.loads(path.read_text())["receipt"]["truncated"])

    def test_serial_children_cannot_reuse_a_lost_diagnostic_allowance(self):
        import ci_execution_diagnostics as diagnostics
        from ci_bounded_diagnostics import COLLECTION_BUDGET_SECONDS
        from test_ci_summary import bounded_diagnostics_receipt
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "job.json"
            with diagnostics.session(path) as recorder:
                recorder.event("preparation", "simulator-preparation", "started", 1)
                recorder.case_resources = bounded_diagnostics_receipt(resources=True)["case_resources"]
            previous = json.loads(path.read_text())["receipt"]["collection_seconds"]["preparation"]
            with diagnostics.session(path, reuse=True) as recorder:
                self.assertGreater(recorder.cost["preparation"], previous)
                self.assertEqual([4], [case["sequence"] for case in recorder.case_resources])
                self.assertGreater(recorder.next_sequence(), 4)
                # A successor seeing a crashed child must treat its loan as spent.
                successor = diagnostics.Recorder()
                successor.load(path)
                for scope in COLLECTION_BUDGET_SECONDS:
                    operation = mock.Mock()
                    self.assertIsNone(successor.collect(scope, operation, cap=0.01))
                    operation.assert_not_called()
                self.assertTrue(successor.truncated)
            stale_reader = diagnostics.Recorder()
            stale_reader.ledger_remaining = 0.04
            clock = [0.0]
            original_open = Path.open
            def slow_open(*args, **kwargs):
                clock[0] += 0.02
                return original_open(*args, **kwargs)
            with mock.patch.object(Path, "open", slow_open), \
                    mock.patch.object(diagnostics.time, "perf_counter", side_effect=lambda: clock[0]):
                stale_reader.load(path)
                stale_reader.load(path)
            operation = mock.Mock()
            stale_reader.ledger_io(operation)
            operation.assert_not_called()
            invalid = json.loads(path.read_text())
            invalid["ledger_remaining_seconds"] = float("inf")
            path.write_text(json.dumps(invalid))
            invalid_reader = diagnostics.Recorder()
            invalid_reader.load(path)
            invalid_reader.collect("xcode", operation, cap=0.01)
            invalid_reader.ledger_io(operation)
            operation.assert_not_called()
            self.assertTrue(invalid_reader.truncated)
            successor = diagnostics.Recorder()
            successor.load(Path(raw) / "missing.json")
            operation = mock.Mock()
            self.assertIsNone(successor.collect("xcode", operation, cap=0.01))
            operation.assert_not_called()
            from test_ci_summary import valid_summary
            summary = valid_summary()
            successor.attach(summary)
            self.assertEqual([], summary["bounded_diagnostics"]["events"])
            self.assertTrue(summary["bounded_diagnostics"]["truncated"])
            with diagnostics.session(path) as exhausted:
                exhausted.charged["preparation"] = COLLECTION_BUDGET_SECONDS["preparation"]
                exhausted.event("xcode", "test-execution", "timeout", 1, elapsed=600)
            successor = diagnostics.Recorder()
            successor.load(path)
            self.assertEqual([("xcode", "timeout")],
                             [(event["scope"], event["state"]) for event in successor.events])
            self.assertIsNone(successor.receipt()["collection_seconds"]["fixture"])

    def test_failed_runner_keeps_official_counts_and_compilation_without_becoming_passed(self):
        import run_strict_ci_tracer as tracer
        from ci_failure_diagnostics import unavailable_first_failure
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
                    (evidence / "case-manifest.json").write_text(json.dumps({"infrastructure": infrastructure,
                        "first_failure": unavailable_first_failure("preparation", element="simulator")}))
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
                            "result": official_result, "failure_phase": "playback_entry", "failure_class": "navigation"}]}]}))
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
                    method.update(failure_phase="playback_entry", failure_class="navigation")
                failed = summary["population"]["observed"][0]
                self.assertNotIn("first_failure", failed, "Preparation evidence cannot replace an executed method")
                self.assertNotIn("first_failure", trace["warm"][0])
                for entry in (failed, failed["attempts"][0]):
                    if official_result == "Failed":
                        self.assertEqual(("playback_entry", "navigation"),
                            (entry.get("failure_phase"), entry.get("failure_class")))
                    else:
                        self.assertNotIn("failure_phase", entry)
                        self.assertNotIn("failure_class", entry)
                self.assertEqual([method],
                                 trace["warm"][0]["official_methods"])
                self.assertEqual(trace["warm"][0]["exit_code"], 124 if infrastructure else 65)
                self.assertEqual(summary["infrastructure"], infrastructure)
                self.assertEqual(trace["warm"][0]["infrastructure"], infrastructure)
                self.assertEqual(contract == "FAIL", trace["warm"][0]["automated_contract_failed"])
                self.assertNotIn("private runner details", json.dumps(trace))

    def test_six_case_nightly_shard_retains_its_last_child_timeout_without_truncation(self):
        import run_strict_ci_tracer as tracer
        import ci_execution_diagnostics as diagnostics
        from ci_nightly import parse_manifest, shards
        from types import SimpleNamespace
        matrix = tracer.ROOT / "scripts/nightly-matrix.json"
        selected = next(shard for shard in shards(parse_manifest(matrix.read_text()))
                        if shard["id"] == "iphone-immichSlides-iOS-debug-0")
        self.assertEqual(6, len(selected["cases"]))
        identity = {"schema_version": 1, "event": "local", "repository": "sudoHG/immichSlides",
                    "commit_sha": "0" * 40, "tree_sha": "0" * 40, "dirty": False}
        warm = []
        cold = []
        io_count = []
        clock = [0.0]
        original_io = diagnostics.Recorder.ledger_io
        def measured_io(recorder, operation):
            def work():
                io_count.append(operation.__name__)
                clock[0] += 0.015
                return operation()
            return original_io(recorder, work)
        def runner(command, *_args, **_kwargs):
            receipt = Path(command[command.index("--diagnostics-receipt") + 1])
            with diagnostics.session(receipt, reuse=True) as child:
                if "--warm-up-only" in command:
                    cold.append(command[command.index("--configuration") + 1])
                    derived = Path(command[command.index("--derived-data-path") + 1])
                    derived.mkdir(parents=True)
                    (derived / "strict-warm-build.json").write_text(json.dumps({"signing_mode": "adhoc"}))
                    return 0
                warm.append(command[command.index("--suite") + 1])
                last = len(warm) == len(selected["cases"])
                if last:
                    child.event("xcode", "test-execution", "timeout", child.next_sequence(), elapsed=600)
                evidence = Path(command[command.index("--evidence-dir") + 1])
                evidence.mkdir(parents=True)
                (evidence / "xcodebuild.log").write_text("test-without-building\n")
                (evidence / "xcodebuild-reuse.json").write_text(json.dumps({"products_unchanged": True}))
                result = "Failed" if last else "Passed"
                (evidence / "official-summary.json").write_text(json.dumps({"totalTestCount": 1,
                    "passedTests": int(not last), "failedTests": int(last), "skippedTests": 0, "result": result}))
                bundle, method = tracer.resolve_suite_selector("ios", warm[-1]).split("/", 1)
                (evidence / "official-tests.json").write_text(json.dumps({"testNodes": [{
                    "nodeType": "Unit test bundle", "name": bundle, "children": [{
                    "nodeType": "Test Case", "nodeIdentifier": method + "()", "result": result}]}]}))
                return 124 if last else 0
        # The fake IO clock must not race real worker scheduling or Event.wait timeouts.
        with tempfile.TemporaryDirectory() as raw, \
                mock.patch.object(diagnostics.Recorder, "ledger_io", measured_io), \
                mock.patch.object(diagnostics.time, "perf_counter", side_effect=lambda: clock[0]), \
                mock.patch.object(diagnostics, "threading", SimpleNamespace(
                    Event=diagnostics.threading.Event,
                    Thread=lambda *, target, daemon: SimpleNamespace(start=target))), \
                mock.patch.object(tracer, "run_runner", side_effect=runner), mock.patch.object(tracer, "workspace_preflight"), \
                mock.patch.object(tracer, "run_identity", return_value=identity), \
                mock.patch.object(tracer, "source_metadata", return_value=(None, False)), \
                mock.patch.object(tracer.shutil, "disk_usage", return_value=mock.Mock(total=200 * 1024**3, free=100 * 1024**3)), \
                mock.patch.object(tracer, "toolchain", return_value={"versions": {"python": "test"}, "signing_mode": "not-applicable"}):
            preparation = Path(raw) / "preparation.json"
            with diagnostics.session(preparation):
                pass
            output = Path(raw) / "trace"
            self.assertEqual(1, tracer.main(["--platform", "ios", "--destination", "unused", "--manifest", str(matrix),
                "--shard", selected["id"], "--preparation-diagnostics", str(preparation), "--output-dir", str(output)]))
            summary = json.loads((output / "records/summary.json").read_text())
            self.assertEqual(["Debug"], cold)
            self.assertEqual(6, len(warm))
            # Six warm cases (9 IO each), one cold (5), preparation/start/final (7).
            self.assertEqual(66, len(io_count))
            self.assertEqual(["passed"] * 5 + ["failed"], [item["outcome"] for item in summary["population"]["observed"]])
            receipt = summary["bounded_diagnostics"]
            self.assertEqual([("xcode", "test-execution", "timeout")],
                [(event["scope"], event["phase"], event["state"]) for event in receipt["events"]])
            self.assertFalse(receipt["truncated"])
            ledger = json.loads((output / "bounded-diagnostics.json").read_text())
            self.assertGreater(ledger["ledger_remaining_seconds"], 0)
            self.assertGreaterEqual(ledger["ledger_remaining_seconds"], diagnostics.LEDGER_ALLOWANCE_SECONDS - clock[0]
                                    - io_count.count("write") * diagnostics.LEDGER_REFUND_CAP_SECONDS)
            self.assertLess(ledger["ledger_remaining_seconds"], diagnostics.LEDGER_ALLOWANCE_SECONDS - clock[0])

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
