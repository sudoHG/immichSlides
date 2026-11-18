"""Discovery entry point preserving the existing test class identities."""

from __future__ import annotations

import sys
import copy
import hashlib
from contextlib import ExitStack
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

from run_strict_e2e_test_fixtures import CommandError, Path, REPO_ROOT, SCRIPT_DIR, TestResultsSummary, WRONG_PUBLIC_API_KEY, io, json, mock, os, re, shutil, signal, subprocess, sys, tempfile, unittest

from run_strict_e2e_test_configuration_cases import StrictE2ERunnerTestsCasesConfiguration
from run_strict_e2e_test_evidence_cases import StrictE2ERunnerTestsCasesEvidence

def setUpModule():
    global _gate_environment_patch
    # Hosted host-check jobs must not leak gate inputs into mocked preparations.
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("GITHUB_", "RUNNER_"))}
    _gate_environment_patch = mock.patch.dict(os.environ, environment, clear=True)
    _gate_environment_patch.start()


def tearDownModule():
    _gate_environment_patch.stop()


class StrictE2ERunnerTests(StrictE2ERunnerTestsCasesConfiguration, StrictE2ERunnerTestsCasesEvidence, unittest.TestCase):


    def test_fixture_build_has_its_own_deadline_before_health_and_cannot_hide_failures(self):
        import strict_e2e_runner_support as support
        from strict_e2e_runner_support import SERVICE_FIXTURE_BUILD_TIMEOUT_SECONDS, SERVICE_STARTUP_TIMEOUT_SECONDS
        for state in ("slow-build", "build-exit", "import-exit", "bind-exit", "unknown-exit",
                      "build-timeout", "late-build", "health-timeout", "strict-build-timeout", "strict-health-timeout"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                clock = [0.0]
                # Hosted build/health timeouts were censored at 126.6/68.3 seconds.
                build_seconds = 1 if state == "strict-health-timeout" else 127 if state == "strict-build-timeout" else 119
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
                    response.__enter__.return_value.status = 200 if state not in ("health-timeout", "strict-health-timeout") and clock[0] >= build_seconds + 59 else 503
                    return response
                with mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                        mock.patch.object(support.time, "sleep", side_effect=sleep), \
                        mock.patch.object(Path, "open", new=open_log), \
                        mock.patch.object(support.urllib.request, "urlopen", side_effect=request) as query, \
                        mock.patch("builtins.print") as report:
                    if state == "slow-build":
                        self.assertEqual(support.wait_for_service(ready, process, startup_log=startup_log, **budgets), ("127.0.0.1", 1234))
                        self.assertAlmostEqual(clock[0], 178, delta=.1)
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


import run_strict_e2e as strict_runner

class StrictE2EP2RunnerTests(unittest.TestCase):


    def test_non_strict_exports_keep_individual_budgets_without_timing_events(self):
        import ci_execution_diagnostics as diagnostics
        for explicit in (False, True):
            with self.subTest(explicit=explicit), tempfile.TemporaryDirectory() as raw, diagnostics.session() as recorder:
                root = Path(raw)
                calls = []
                def tool(command, **kwargs):
                    calls.append(kwargs["timeout"])
                    payload = ({} if "--legacy" in command else {"testNodes": [{"nodeType": "Test Case",
                        "nodeIdentifier": "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke()", "result": "Failed"}]}
                        if command[4] == "tests" else {
                        "totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0, "result": "Failed"})
                    encoded = json.dumps(payload)
                    return subprocess.CompletedProcess(command, 0, encoded if kwargs.get("text") else encoded.encode(), b"")
                bundle = root / "bundle.xcresult"
                bundle.mkdir()
                options = dict(summary_timeout_seconds=180, export_timeout_seconds=180) if explicit else {}
                with mock.patch.object(strict_runner.subprocess, "run", side_effect=tool):
                    strict_runner.export_private_result_bundle(bundle, root, [], enrich_failure_diagnostics=True, **options)
                self.assertEqual([180] * 3 if explicit else [60] * 3, calls)
                self.assertFalse(recorder.receipt()["events"])

    def test_failed_official_reads_spend_budget_without_success_timing(self):
        import ci_execution_diagnostics as diagnostics
        from run_offline_unit_tests import CommandError as SummaryReadError
        for failed_kind in ("summary", "tests", "legacy"):
            for error_kind in ("nonzero", "os-error"):
                with self.subTest(read=failed_kind, error=error_kind), tempfile.TemporaryDirectory() as raw, diagnostics.session() as recorder:
                    root, clock = Path(raw), [0.0]
                    budget = strict_runner.OfficialExportBudget()
                    bundle = root / "bundle.xcresult"
                    bundle.mkdir()
                    calls = []
                    def tool(command, **kwargs):
                        kind = "legacy" if "--legacy" in command else command[4]
                        calls.append(kind)
                        clock[0] += 20
                        if kind == failed_kind:
                            if error_kind == "os-error":
                                raise OSError("read failed")
                            if kwargs.get("check"):
                                raise subprocess.CalledProcessError(17, command)
                            return subprocess.CompletedProcess(command, 17, "", "read failed")
                        payload = ({"testNodes": [{"nodeType": "Test Case", "nodeIdentifier":
                            "StrictE2ESmokeUITests/testIOSStrictE2EConnectionSmoke()", "result": "Failed"}]}
                            if kind == "tests" else {"totalTestCount": 1, "passedTests": 0,
                                "failedTests": 1, "skippedTests": 0, "result": "Failed"})
                        encoded = json.dumps(payload)
                        return subprocess.CompletedProcess(command, 0, encoded if kwargs.get("text") else encoded.encode(), b"")
                    with mock.patch.object(strict_runner.subprocess, "run", side_effect=tool), \
                            mock.patch.object(strict_runner.time, "monotonic", side_effect=lambda: clock[0]):
                        if failed_kind == "legacy":
                            strict_runner.export_private_result_bundle(bundle, root, [], export_budget=budget,
                                                                      enrich_failure_diagnostics=True)
                            self.assertEqual("Failed", json.loads((root / "official-summary.json").read_text())["result"])
                        else:
                            with self.assertRaises((CommandError, SummaryReadError, OSError)) as raised:
                                if failed_kind == "summary":
                                    strict_runner.read_official_test_results_summary(bundle, export_budget=budget)
                                else:
                                    strict_runner.export_private_result_bundle(bundle, root, [], export_budget=budget,
                                                                              enrich_failure_diagnostics=True)
                            self.assertIn("read failed" if error_kind == "os-error" or failed_kind == "summary" else "exit 17", str(raised.exception))
                    self.assertEqual(20 * len(calls), budget.spent_seconds)
                    self.assertEqual(2 if failed_kind == "legacy" else 0, len(recorder.receipt()["events"]))

    def test_boot_settle_gate_requires_a_continuous_full_window_and_runs_once_per_job(self):
        import strict_e2e_runner_support as support
        import strict_e2e_runner_support as resources
        for event, defect, cores, expected in (("schedule", "idle", 3, 100), ("workflow_dispatch", "device", 3, 120),
                                              ("schedule", "steady", 3, 360), ("schedule", "steady", 4, 70),
                                              ("schedule", "missing-host", 4, 100),
                                              ("schedule", "missing-device", 4, 100),
                                              ("schedule", "separated-misses", 4, 200)):
            with self.subTest(event=event, defect=defect, cores=cores), tempfile.TemporaryDirectory() as raw:
                clock, reports, order = [0.0], [], []
                def idle():
                    # A bad point must restart the window, and 50 seconds must not pass.
                    if defect == "missing-host" and clock[0] == 30 or defect == "separated-misses" and clock[0] in (20, 40, 60, 80, 100, 130):
                        return None
                    return {"idle_percent": None if clock[0] == 0 else 32 if defect == "steady" or defect == "idle" and clock[0] == 30 else 40}
                def device(*args, **kwargs):
                    order.append("sample")
                    if defect == "missing-device" and clock[0] == 30:
                        raise subprocess.TimeoutExpired(["private-input"], 5)
                    return 130 if defect == "device" and clock[0] == 50 else 100
                with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                        "GITHUB_EVENT_NAME": event, "RUNNER_TEMP": raw}, clear=True), \
                        mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                        mock.patch.object(support.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                        mock.patch.object(support.os, "cpu_count", return_value=cores), \
                        mock.patch.object(resources.HostProbe, "sample", side_effect=idle), \
                        mock.patch.object(support, "_boot_manager_pid", return_value=10) as manager, \
                        mock.patch.object(support, "_boot_device_cpu", side_effect=device), \
                        mock.patch.object(support, "boot_simulator", return_value=""), \
                        mock.patch.object(support, "wait_for_simulator_service_response", side_effect=lambda *a, **kw: (order.append("ready"), "")), \
                        mock.patch.object(support, "_BOOT_SETTLE_ATTEMPTED", False):
                    support.prepare_simulator("device", report=reports.append, should_check_app=False,
                                              boot_submitted=True, should_settle_boot=True)
                    self.assertEqual(clock[0], expected)
                    self.assertEqual(order[0], "ready")
                    self.assertIn("outcome=" + ("timed-out" if expected == 360 else "settled"), "\n".join(reports))
                    self.assertIn("idle_threshold_percent=" + ("33.333" if cores == 3 else "30.000"), "\n".join(reports))
                    self.assertIn(f"logical_cores={cores};", "\n".join(reports))
                    self.assertIn("missed_points=" + ("6" if defect == "separated-misses" else "1" if defect.startswith("missing-") else "0"), "\n".join(reports))
                    manager.assert_called_once()
                    # Model the next runner process: the disk marker must still prevent a repeat.
                    support._BOOT_SETTLE_ATTEMPTED = False
                    support.prepare_simulator("device", report=reports.append, should_check_app=False,
                                              boot_submitted=True, should_settle_boot=True)
                    self.assertEqual(clock[0], expected)
                    self.assertIn("outcome=skipped-repeat", "\n".join(reports))

    def test_boot_settle_gate_caps_wait_and_fails_open_on_sampling_or_marker_errors(self):
        import strict_e2e_runner_support as support
        import strict_e2e_runner_support as resources
        for failure in ("busy", "remaining-budget", "device-at-cap", "host", "malformed-host", "device", "manager", "marker", "cores",
                        "unavailable-prime", "unavailable-tick"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as raw:
                clock, reports = [0.0], []
                def sample(probe):
                    if failure == "unavailable-prime" or failure == "unavailable-tick" and clock[0]:
                        probe.unavailable = True
                        return None
                    if failure == "host" and clock[0]:
                        return None
                    if failure == "malformed-host" and clock[0]:
                        return {"idle_percent": "private-input"}
                    return {"idle_percent": None if clock[0] == 0 else 0}
                def device(*args, **kwargs):
                    if failure == "device-at-cap":
                        clock[0] = 360
                        raise subprocess.TimeoutExpired(["private-input"], 5)
                    if failure == "device":
                        raise OSError("private-input")
                    return 100
                with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                        "GITHUB_EVENT_NAME": "schedule", "RUNNER_TEMP": raw + "/missing" if failure == "marker" else raw}, clear=True), \
                        mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                        mock.patch.object(support.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                        mock.patch.object(support.os, "cpu_count", return_value=None if failure == "cores" else 3), \
                        mock.patch.object(resources.HostProbe, "sample", autospec=True, side_effect=sample), \
                        mock.patch.object(support, "_boot_process_output", side_effect=OSError("private-input") if failure == "manager" else None,
                                          return_value="10\n"), \
                        mock.patch.object(support, "_boot_device_cpu", side_effect=device), \
                        mock.patch.object(support, "boot_simulator", return_value=""), \
                        mock.patch.object(support, "wait_for_simulator_app_response", side_effect=lambda *a, **kw: (
                            clock.__setitem__(0, 590) if failure == "remaining-budget" else None, "")), \
                        mock.patch.object(support, "_BOOT_SETTLE_ATTEMPTED", False):
                    support.prepare_simulator("device", report=reports.append, boot_submitted=True, should_settle_boot=True)
                log = "\n".join(reports)
                self.assertIn("outcome=" + ("timed-out" if failure in ("busy", "remaining-budget", "device-at-cap") else
                                           "sampling-failed" if failure in ("host", "malformed-host", "device", "unavailable-prime", "unavailable-tick") else "unavailable"), log)
                self.assertEqual(clock[0], 360 if failure in ("busy", "device-at-cap") else 600 if failure == "remaining-budget" else 60 if failure in ("host", "malformed-host", "device") else 10 if failure == "unavailable-tick" else 0)
                self.assertIn("missed_points=" + ("6" if failure in ("host", "malformed-host", "device") else "1" if failure in ("device-at-cap", "unavailable-tick") else "0"), log)
                self.assertIn("simulator-preparation: passed", log)
                self.assertNotIn("private-input", log)

    def test_boot_settle_gate_only_runs_for_opted_in_submitted_boots_in_hosted_full_runs(self):
        import strict_e2e_runner_support as support
        for environment in ({}, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_EVENT_NAME": "pull_request"},
                            {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted", "GITHUB_EVENT_NAME": "schedule"}):
            with self.subTest(environment=environment), mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch.object(support, "boot_simulator", return_value=""), \
                    mock.patch.object(support, "wait_for_simulator_app_response", return_value=(None, "")), \
                    mock.patch.object(support, "_boot_device_cpu") as device:
                _, log = support.prepare_simulator("device", report=lambda line: None, boot_submitted=True,
                                                  should_settle_boot=True)
                self.assertIn("outcome=skipped-environment", log)
                device.assert_not_called()
        for event in ("schedule", "workflow_dispatch"):
            for should_check_app in (False, True):
                for scope in ("strict", "ui-cold", "ui-submitted"):
                    with self.subTest(event=event, should_check_app=should_check_app, scope=scope), \
                            mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                                "GITHUB_EVENT_NAME": event}, clear=True), \
                            mock.patch.object(support, "boot_simulator", return_value=""), \
                            mock.patch.object(support, "wait_for_simulator_app_response", return_value=(None, "")), \
                            mock.patch.object(support, "wait_for_simulator_service_response", return_value=(None, "")), \
                            mock.patch.object(support, "_settle_simulator_boot",
                                return_value="simulator-boot-settle: outcome=settled") as gate:
                        options = {} if scope == "strict" else {"should_settle_boot": True}
                        _, log = support.prepare_simulator("device", should_check_app=should_check_app,
                            boot_submitted=scope != "ui-cold", report=lambda line: None, **options)
                        if scope == "ui-submitted":
                            gate.assert_called_once()
                            self.assertIn("simulator-boot-settle: outcome=settled", log)
                        else:
                            gate.assert_not_called()
                            self.assertNotIn("simulator-boot-settle:", log)

    def test_boot_device_cpu_counts_only_the_requested_subtree_and_rejects_missing_samples(self):
        import strict_e2e_runner_support as support
        for rows, expected in (("10 1 1\n11 10 40\n12 11 50\n20 1 900\n", 91),
                               ("20 1 900\n", None), ("10 1 nan\n", None), ("bad", None)):
            with self.subTest(rows=rows):
                def run(command, **kwargs):
                    self.assertLessEqual(kwargs["timeout"], 5)
                    return subprocess.CompletedProcess(command, 0, "10\n" if command[0] == "xcrun" else rows, "")
                with mock.patch.object(support.subprocess, "run", side_effect=run):
                    self.assertEqual(support._boot_device_cpu(10, support.time.monotonic() + 10), expected)

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


class FailureDiagnosticsTests(unittest.TestCase):


    def test_official_export_preserves_complete_public_failure_lists_before_class_folding(self):
        import run_strict_e2e as runner
        from ci_failure_diagnostics import failure_messages_diagnostics
        selector = "SmokeFlowIOSUITests/testFirstBoot"
        messages = ["Smoke flow: input must have keyboard focus.", "Smoke flow: selected mode must reach its destination."]
        tests = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": selector + "()", "result": "Failed",
                              "children": [{"nodeType": "Failure Message"} for _ in messages]}]}
        legacy = {"issues": {"testFailureSummaries": {"_values": [
            {"testCaseName": {"_value": selector + "()"}, "message": {"_value": message}} for message in messages]}}}
        def exported(command, **kwargs):
            payload = legacy if "--legacy" in command else tests
            return subprocess.CompletedProcess(command, 0, json.dumps(payload).encode(), b"")
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            with mock.patch.object(runner.subprocess, "run", side_effect=exported), mock.patch.object(runner,
                    "read_official_test_results_summary", return_value=TestResultsSummary(1, 0, 1, 0, "Failed")):
                runner.export_private_result_bundle(root / "private.xcresult", root, [], enrich_failure_diagnostics=True)
            node = json.loads((root / "official-tests.json").read_text())["testNodes"][0]
            self.assertEqual(node["failure_messages"], messages)
            self.assertEqual({key: node[key] for key in ("failure_phase", "failure_class")}, failure_messages_diagnostics(messages))
            self.assertEqual(json.loads((root / "official-summary.json").read_text())["result"], "Failed")




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


    def test_official_warnings_do_not_replace_the_selected_method_failure_diagnostics(self):
        from ci_failure_diagnostics import legacy_diagnostics
        name = {"_value": "Flow.testFailure()"}
        payload = {"issues": {
            "testFailureSummaries": {"_values": [{"testCaseName": name,
                "message": {"_value": "failed - Smoke flow: input must have keyboard focus."}}]},
            "testWarningSummaries": {"_values": [{"testCaseName": name,
                "message": {"_value": "private warning text"}}]}}}
        self.assertEqual(legacy_diagnostics(payload), {"Flow/testFailure": {
            "failure_phase": "unknown", "failure_class": "control_state"}})


    def test_scanner_accepts_enums_and_rejects_free_text_even_without_credentials(self):
        from ci_failure_diagnostics import FAILURE_PHASES, FAILURE_CLASSES
        from test_ci_summary import bounded_diagnostics_receipt
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
            for projection in (
                    [{"path": "/" + "Users/PRIVATE_SENTINEL/TestSupport/Timing.swift", "line": 1}],
                    [{"path": "file://PRIVATE_SENTINEL/TestSupport/Timing.swift", "line": 1}],
                    [{"path": "TestSupport/Timing.swift", "line": 1, "message": "PRIVATE_SENTINEL"}]):
                receipt = bounded_diagnostics_receipt(resources=True)
                receipt["case_resources"][0]["failure_locations"] = projection
                path.write_text(json.dumps({"bounded_diagnostics": receipt}))
                with self.subTest(projection=projection), self.assertRaisesRegex(CommandError,
                        "^The evidence redaction scan found API Key values or invalid public failure diagnostics: record.json$"):
                    strict_runner.write_sensitive_scan(evidence, [])
                self.assertEqual("FAIL", json.loads((evidence / "sensitive-scan.json").read_text())["result"])


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


    def test_host_probe_caps_hung_reads_and_total_wait_without_starting_more_workers(self):
        import strict_e2e_runner_support as resources
        for spent, expected_limit in ((0, 0.2), (9.95, 0.05), (10, None)):
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
        import strict_e2e_runner_support as resources
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
        real_thread = resources.Thread
        with mock.patch.object(resources, "HostCpu", return_value=host) as constructor, \
                mock.patch.object(resources, "Thread", wraps=real_thread) as worker, \
                mock.patch.object(resources.time, "monotonic", side_effect=[10, 10.005, 10.010, 11.010]), \
                mock.patch.object(resources.os, "getloadavg", return_value=(6, 5, 4)):
            probe = resources.HostProbe("device")
            try:
                self.assertIsNone(probe.sample())
                self.assertTrue(entered.wait(3))
                self.assertIsNone(probe.sample(), "an in-flight read must not start another worker")
                self.assertEqual(1, len(calls))
                self.assertEqual(1, probe.request_count, "busy ticks must not dilute the timeout cost")
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
                self.assertEqual(1, worker.call_count, "ticks must reuse the native worker after a timeout")
                self.assertEqual(3, probe.request_count, "the average must include the timed-out request")
            finally:
                release.set()
                probe.close()
                self.assertTrue(closed.wait(3))

    def test_host_probe_stops_with_queued_work_and_retries_failed_worker_start(self):
        import strict_e2e_runner_support as resources
        import threading
        from types import SimpleNamespace
        for shutdown in ("close", "exhausted"):
            with self.subTest(shutdown=shutdown):
                targets = []
                def deferred_worker(*, target, daemon):
                    targets.append(target)
                    return SimpleNamespace(start=lambda: None)
                with mock.patch.object(resources, "Thread", side_effect=deferred_worker), \
                        mock.patch.object(resources, "resource_sample") as read:
                    probe = resources.HostProbe("device")
                    self.assertIsNone(probe.sample())
                    self.assertTrue(probe.requests.full())
                    if shutdown == "close":
                        probe.close()
                        self.assertTrue(probe.done.is_set(), "shutdown must release the pending request")
                    else:
                        probe.spent = resources.HOST_WALL_BUDGET_SECONDS
                        self.assertIsNone(probe.sample())
                    worker = threading.Thread(target=targets[0], daemon=True)
                    worker.start()
                    try:
                        worker.join(1)
                        self.assertFalse(worker.is_alive(), "a full queue must not swallow shutdown")
                        read.assert_not_called()
                    finally:
                        probe.close()
                        worker.join(1)
        real_thread = resources.Thread
        starts = [RuntimeError("worker unavailable"), None]
        def worker(*, target, daemon):
            error = starts.pop(0)
            if error is not None:
                return SimpleNamespace(start=mock.Mock(side_effect=error))
            return real_thread(target=target, daemon=daemon)
        sample = {"idle_percent": 4, "load_1m": 6, "cpu_percent": dict.fromkeys(resources.RESOURCE_CATEGORIES)}
        with mock.patch.object(resources, "Thread", side_effect=worker), \
                mock.patch.object(resources, "HostCpu", return_value=SimpleNamespace(idle=lambda: None, close=lambda: None)), \
                mock.patch.object(resources, "resource_sample", return_value=sample):
            probe = resources.HostProbe("device")
            try:
                self.assertIsNone(probe.sample())
                self.assertEqual(sample, probe.sample(), "a failed start must allow a fresh worker")
            finally:
                probe.close()
                probe.worker.join(1)


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
        import strict_e2e_runner_support as tracer
        import ci_execution_diagnostics as diagnostics
        from types import SimpleNamespace
        line = "bounded-diagnostics truncated: io-timeout"
        reset_lines = ["keychain_reset_exit=1; stderr_class=posix-error",
                       "keychain_reset_retry_exit=0; stderr_class=empty",
                       "privacy_reset_exit=1; stderr_class=service-unavailable",
                       "privacy_reset_exit=1; stderr_class=device-unavailable",
                       "privacy_reset_exit=1; stderr_class=permission-denied",
                       "privacy_reset_exit=1; stderr_class=simulator-error",
                       "privacy_reset_retry_exit=1; stderr_class=unclassified"]
        for rejected in ("private-input", "event-cap", "bounded-diagnostics truncated: private-input /private/path",
                         line + " private-input"):
            with self.subTest(rejected=rejected), tempfile.TemporaryDirectory() as raw:
                def spawn(*args, **kwargs):
                    kwargs["stdout"].write(rejected + "\n" + line + "\nbounded-diagnostics truncated: event-cap\n"
                        + "\n".join(reset_lines) + "\nprivacy_reset_exit=1; stderr_class=unclassified /private/path\n"
                        + "privacy_reset_exit=private-input; stderr_class=empty\n")
                    kwargs["stdout"].flush()
                    return SimpleNamespace(pid=42, wait=lambda **kwargs: 65)
                stderr = io.StringIO()
                with mock.patch.object(tracer.subprocess, "Popen", side_effect=spawn), \
                        mock.patch.object(tracer, "stop_group"), \
                        mock.patch.object(tracer, "group_has_live_members", return_value=False), \
                        mock.patch.object(tracer.sys, "stderr", stderr), \
                        mock.patch.object(diagnostics.threading, "Thread", side_effect=lambda *, target, daemon: SimpleNamespace(start=target)), \
                        mock.patch.object(diagnostics.os, "write") as write:
                    self.assertEqual(65, tracer.run_runner(["unused"], Path(raw), Path(raw) / "runner.log", timeout_seconds=2))
                write.assert_called_once_with(2, (line + "\n").encode("ascii"))
                self.assertEqual(reset_lines, stderr.getvalue().splitlines())



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


    def test_official_exports_survive_runner_failure_and_malformed_counts_fail_closed(self):
        from ci_smoke_shadow import read_case_official
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


    def test_runner_escalates_late_survivors_in_its_own_group_and_verifies_their_exit(self):
        import strict_e2e_runner_support as tracer
        from types import SimpleNamespace
        for states, expected in (([False], []), ([True, True, False], [mock.call(42, signal.SIGKILL)])):
            with self.subTest(states=states), tempfile.TemporaryDirectory() as raw, \
                    mock.patch.object(tracer.subprocess, "Popen", return_value=SimpleNamespace(pid=42, wait=lambda **kwargs: 0)) as spawn, \
                    mock.patch.object(tracer, "stop_group"), \
                    mock.patch.object(tracer, "group_has_live_members", side_effect=states), \
                    mock.patch.object(tracer.os, "killpg") as kill, \
                    mock.patch.object(tracer.time, "sleep"):
                self.assertEqual(0, tracer.run_runner(["unused"], Path(raw), Path(raw) / "runner.log", timeout_seconds=2))
                self.assertEqual(expected, kill.call_args_list)
                self.assertTrue(spawn.call_args.kwargs["start_new_session"])
        for error in (ProcessLookupError(), PermissionError()):
            with self.subTest(signal_error=type(error).__name__), tempfile.TemporaryDirectory() as raw, \
                    mock.patch.object(tracer.subprocess, "Popen", return_value=SimpleNamespace(pid=42, wait=lambda **kwargs: 0)), \
                    mock.patch.object(tracer, "stop_group"), \
                    mock.patch.object(tracer, "group_has_live_members", side_effect=[True, False, False]), \
                    mock.patch.object(tracer.os, "killpg", side_effect=error) as kill:
                self.assertEqual(0, tracer.run_runner(["unused"], Path(raw), Path(raw) / "runner.log", timeout_seconds=2))
                kill.assert_called_once_with(42, signal.SIGKILL)
        with tempfile.TemporaryDirectory() as raw, \
                mock.patch.object(tracer.subprocess, "Popen", return_value=SimpleNamespace(pid=42, wait=lambda **kwargs: 0)), \
                mock.patch.object(tracer, "stop_group"), \
                mock.patch.object(tracer, "group_has_live_members", return_value=True), \
                mock.patch.object(tracer.os, "killpg", side_effect=PermissionError()), \
                mock.patch.object(tracer, "runner_group_members", return_value=([], False)):
            with self.assertRaisesRegex(tracer.RunnerGroupCleanupError, "cleanup failed: PermissionError"):
                tracer.run_runner(["unused"], Path(raw), Path(raw) / "runner.log", timeout_seconds=2)

    def test_macos_survivor_probe_targets_the_group_and_missing_parents_with_one_deadline(self):
        import strict_e2e_runner_support as tracer
        clock = [0.0]
        def probe(command, **kwargs):
            if "-axo" in command:
                raise subprocess.TimeoutExpired(command, 3)
            if "-g" in command:
                self.assertEqual(["ps", "-g", "42", "-o", "pid=,ppid=,pgid=,stat=,comm="], command)
                self.assertEqual(3, kwargs["timeout"])
                clock[0] += 2
                return "88 1 42 SE /Xcode/SWBBuildService\n89 1 42 Z /private/tool\n"
            self.assertEqual(["ps", "-p", "1", "-o", "pid=,ppid=,pgid=,stat=,comm="], command)
            self.assertEqual(1, kwargs["timeout"], "parent lookup must share the three-second allowance")
            return "1 0 1 S /sbin/launchd\n"
        with mock.patch.object(tracer.sys, "platform", "darwin"), \
                mock.patch.object(tracer.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(tracer.subprocess, "check_output", side_effect=probe):
            self.assertEqual(([{"name": "SWBBuildService", "parent": "launchd", "state": "exiting"}], False),
                             tracer.runner_group_members(42))
        for parent_error in (subprocess.TimeoutExpired("ps", 1),
                subprocess.CalledProcessError(1, ["ps"], output="", stderr="")):
            with self.subTest(parent_error=type(parent_error).__name__), \
                    mock.patch.object(tracer.sys, "platform", "darwin"), \
                    mock.patch.object(tracer.subprocess, "check_output", side_effect=[
                        "88 1 42 SE /Xcode/SWBBuildService\n", parent_error]):
                self.assertEqual(([{"name": "SWBBuildService", "parent": "unknown", "state": "exiting"}], False),
                                 tracer.runner_group_members(42))

    def test_runner_cleanup_error_identifies_survivors_without_private_process_metadata(self):
        import strict_e2e_runner_support as tracer
        from types import SimpleNamespace
        private = str(Path("/", "Users", "private-user"))
        table = (f"1 0 1 S /sbin/launchd\n77 1 77 S {private}/Python\n88 77 42 S /usr/bin/sample\n"
                 f"89 77 42 Z {private}/private-tool\n90 999 42 U {private}/private-tool\n"
                 "91 77 12 S /usr/bin/git\n92 1 42 SE /Xcode/SWBBuildService\n93 77 42 R /Xcode/swbuild\n")
        with tempfile.TemporaryDirectory() as raw, \
                mock.patch.object(tracer.subprocess, "Popen", return_value=SimpleNamespace(pid=42, wait=lambda **kwargs: 0)), \
                mock.patch.object(tracer.subprocess, "check_output", return_value=table), \
                mock.patch.object(tracer, "stop_group"), \
                mock.patch.object(tracer, "group_has_live_members", return_value=True), \
                mock.patch.object(tracer.os, "killpg"), \
                mock.patch.object(tracer, "GROUP_TERM_GRACE_SECONDS", 0):
            with self.assertRaisesRegex(tracer.RunnerGroupCleanupError, "Runner process group still has live members") as raised:
                tracer.run_runner(["unused"], Path(raw), Path(raw) / "runner.log", timeout_seconds=2)
        self.assertEqual([{"name": "sample", "parent": "Python", "state": "sleeping"},
                          {"name": "other", "parent": "unknown", "state": "uninterruptible"},
                          {"name": "SWBBuildService", "parent": "launchd", "state": "exiting"},
                          {"name": "swbuild", "parent": "Python", "state": "running"}], raised.exception.members)
        self.assertIn("sample(parent=Python,state=sleeping)", str(raised.exception))
        for rejected in (private, "private-tool", "git", "88", "999"):
            self.assertNotIn(rejected, str(raised.exception))
        for output, count, truncated in (("x" * (2 * 1024 * 1024 + 1), None, False),
                (subprocess.TimeoutExpired("ps", 3), None, False), ("", 0, False),
                *(("77 1 77 S /usr/bin/python3.9\n" + "".join(f"{100 + i} 77 42 S /usr/bin/sample\n" for i in range(n)), 64, n > 64)
                  for n in (64, 65))):
            with self.subTest(count=count, truncated=truncated), tempfile.TemporaryDirectory() as raw, \
                    mock.patch.object(tracer.subprocess, "Popen", return_value=SimpleNamespace(pid=42, wait=lambda **kwargs: 0)), \
                    mock.patch.object(tracer.subprocess, "check_output", **(
                        {"side_effect": output} if isinstance(output, Exception) else {"return_value": output})), \
                    mock.patch.object(tracer, "stop_group"), \
                    mock.patch.object(tracer, "group_has_live_members", return_value=True), \
                    mock.patch.object(tracer.os, "killpg"), \
                    mock.patch.object(tracer.sys, "stderr", io.StringIO()) as stderr, \
                    mock.patch.object(tracer, "GROUP_TERM_GRACE_SECONDS", 0):
                with self.assertRaisesRegex(tracer.RunnerGroupCleanupError, "Runner process group still has live members") as raised:
                    tracer.run_runner(["unused"], Path(raw), Path(raw) / "runner.log", timeout_seconds=2)
                self.assertGreater(tracer.subprocess.check_output.call_args.kwargs["timeout"], 0)
                self.assertLessEqual(tracer.subprocess.check_output.call_args.kwargs["timeout"], 3)
            self.assertEqual(truncated, raised.exception.members_truncated)
            if count is None:
                self.assertIsNone(raised.exception.members)
                self.assertIn("live members: unavailable", str(raised.exception))
                self.assertEqual("Runner member probe unavailable: "
                    + (type(output).__name__ if isinstance(output, Exception) else "ValueError") + "\n", stderr.getvalue())
            elif count:
                self.assertEqual(count, len(raised.exception.members))
                self.assertEqual({"python3.9"}, {member["parent"] for member in raised.exception.members})
                if truncated:
                    self.assertIn("truncated after 64 members", str(raised.exception))
            else:
                self.assertEqual([], raised.exception.members)
                self.assertIn("live members: none", str(raised.exception))



    def test_runner_exit_waits_for_capture_private_file_finalization(self):
        import strict_e2e_runner_support as runner
        code = """
import pathlib,sys,threading,time
root=pathlib.Path(sys.argv[1])
private=root/'private'
private.mkdir()
(private/'raw').write_bytes(b'private synthetic capture')
def finalize():
    time.sleep(0.1)
    (private/'raw').unlink()
    private.rmdir()
    (root/'finalized').touch()
threading.Thread(target=finalize,daemon=False).start()
"""
        for environment in ({}, {"CI": "true"},
                {"CI": "true", "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}):
            with self.subTest(environment=environment), mock.patch.dict(os.environ, environment, clear=True), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                code_result = runner.run_runner([sys.executable, "-B", "-c", code, str(root)], root,
                    root / "runner.log", timeout_seconds=10)
                self.assertEqual(0, code_result, (root / "runner.log").read_text())
                self.assertTrue((root / "finalized").is_file())
                self.assertFalse((root / "private").exists(), "runner exit must finish private raw-file cleanup")

    def test_runner_timeout_or_cancellation_stops_its_descendants(self):
        import contextlib
        import strict_e2e_runner_support as tracer
        from run_host_checks import group_has_live_members
        import time
        popen = subprocess.Popen
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                marker = root / "group"
                code = "import os,pathlib,subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); print('CommandError: fixture failure',flush=True); marker=pathlib.Path(sys.argv[1]); pending=marker.with_suffix('.pending'); pending.write_text(str(os.getpgrp())); pending.replace(marker); time.sleep(60)"
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
                with mock.patch("strict_e2e_runner_support.subprocess.Popen", side_effect=start), contextlib.redirect_stderr(stderr):
                    with self.assertRaises(KeyboardInterrupt if interrupted else subprocess.TimeoutExpired):
                        tracer.run_runner(command, root, root / "runner.log", timeout_seconds=2)
                self.assertTrue(marker.exists())
                self.assertFalse(group_has_live_members(int(marker.read_text())))
                self.assertIn("CommandError: fixture failure", stderr.getvalue())


class SmokeFlowResultTests(unittest.TestCase):
    def test_smoke_archive_compatibility_requires_the_pinned_ios_device_runtime_and_architecture(self):
        import strict_e2e_build as build
        pins = json.loads((Path(__file__).resolve().parent / "ci-pins.json").read_text())
        identity = {"destination": build.SMOKE_BUILD_DESTINATION, "platform": "ios",
                    "scheme": "immichSlides-iOS-settings-resume", "test_plan": "StrictE2E-iOS"}
        for device in ("iphone", "ipad"):
            execution = {"platform": "iOS Simulator", "udid": "synthetic", "device": device,
                         "device_type": pins["device_types"][device], "runtime": pins["simulators"]["ios"],
                         "architecture": "arm64"}
            build.validate_smoke_compatibility(identity, ["arm64", "x86_64"], execution, pins)
            for change in ({"platform": "iOS"}, {"platform": "tvOS Simulator"}, {"device": "tv"},
                           {"device_type": "iPhone Other"}, {"runtime": dict(execution["runtime"], build="wrong")},
                           {"architecture": "missing"}):
                with self.subTest(device=device, change=change), self.assertRaises(ValueError):
                    build.validate_smoke_compatibility(identity, ["arm64", "x86_64"], dict(execution, **change), pins)
            with self.assertRaises(ValueError):
                build.validate_smoke_compatibility(dict(identity, destination="platform=iOS Simulator,id=other"),
                                                   ["arm64"], execution, pins)

    def test_legacy_warm_receipt_still_requires_the_exact_destination(self):
        import strict_e2e_build as build
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            products = root / "Build/Products"
            products.mkdir(parents=True)
            (products / "one.xctestrun").write_bytes(b"synthetic")
            identity = {"destination": "platform=iOS Simulator,id=one"}
            receipt = {"schema_version": 1, "identity": identity, "products": build.inventory(products),
                       "xctestrun": "one.xctestrun"}
            build.write_json(root / build.RECEIPT, receipt)
            with mock.patch.object(build, "workspace_preflight"), mock.patch.object(build, "shard_identity",
                    return_value=dict(identity, destination="platform=iOS Simulator,id=two")):
                with self.assertRaisesRegex(build.CommandError, "does not match"):
                    build.load_warm_build(root, "ios", "smoke-flow", "Debug", "unused", root)

    def test_smoke_failure_vocabulary_covers_source_steps_and_redacts_runtime_values(self):
        from ci_failure_diagnostics import (SMOKE_FLOW_CONTROL_IDS, SMOKE_FLOW_FAILURE_MESSAGES,
                                            classify_messages, public_failure_messages,
                                            scan_diagnostic_json, validate_failure_messages)
        private_prefixes = ("albumFilter.album.", "personFilter.person.", "pinEntry.digit.")
        for value in (*SMOKE_FLOW_CONTROL_IDS, *SMOKE_FLOW_FAILURE_MESSAGES):
            with self.subTest(vocabulary=value):
                self.assertFalse(value.removeprefix("Smoke flow: ").startswith(private_prefixes))
                self.assertNotIn(r'\(', value)
        control_steps = ("required element must be available: ", "required element must be ready: ",
                         "control appears: ", "remote focus moves toward ", "remote cannot focus ")
        literal = r'"((?:\\.|[^"\\\n])*)"'
        step_patterns = (r'"(Smoke flow: (?:\\.|[^"\\\n])*)"',
                         r'\biosSmokeRequire\(\s*[^,]+,\s*' + literal,
                         r'\bstep:\s*' + literal,
                         r'\btvSmoke(?:Fail|Perform)\(\s*' + literal)
        id_patterns = (r'\biosSmoke(?:Ready|Tap|Snapshot)\(\s*[^,]+,\s*[^,]+,\s*' + literal,
                       r'\btvSmoke(?:Focus|Select)\(\s*' + literal)

        def check_message(message):
            if r'\(' in message:
                # Unknown runtime values must never become reviewed public vocabulary.
                message = re.sub(r'\\\([^)]*\)', 'private-runtime-value', message)
                self.assertEqual(public_failure_messages([message]), ["Smoke flow: "])
            else:
                self.assertTrue(message in SMOKE_FLOW_FAILURE_MESSAGES, "unreviewed smoke step: " + message)

        sources = sorted(REPO_ROOT.glob("immichSlidesUITests/SmokeFlow*.swift"))
        for name in ("SmokeFlowIOSUITests.swift", "SmokeFlowTVOSUITests.swift", "SmokeFlowTVOSUITests+Support.swift"):
            self.assertIn(name, {path.name for path in sources})
        match_counts = dict.fromkeys((*step_patterns, *id_patterns), 0)
        for path in sources:
            source = path.read_text()
            for pattern in step_patterns:
                for match in re.finditer(pattern, source):
                    match_counts[pattern] += 1
                    value = match.group(1)
                    with self.subTest(source=path.name, step=value):
                        check_message(value if value.startswith("Smoke flow: ") else "Smoke flow: " + value + ".")
            for pattern in id_patterns:
                for match in re.finditer(pattern, source):
                    match_counts[pattern] += 1
                    identifier = match.group(1)
                    with self.subTest(source=path.name, identifier=identifier):
                        is_private = identifier.startswith(private_prefixes) or r'\(' in identifier
                        if not is_private:
                            self.assertTrue(identifier in SMOKE_FLOW_CONTROL_IDS, "unreviewed smoke control: " + identifier)
                        identifier = re.sub(r'\\\([^)]*\)', 'private-runtime-value', identifier)
                        for step in control_steps:
                            message = "Smoke flow: " + step + identifier + "."
                            if is_private:
                                self.assertNotIn(message, SMOKE_FLOW_FAILURE_MESSAGES)
                                self.assertEqual(public_failure_messages([message]), ["Smoke flow: "])
                            else:
                                check_message(message)
        for pattern, count in match_counts.items():
            with self.subTest(pattern=pattern):
                self.assertGreater(count, 0, "smoke source scan must match every regex family")
        messages = ["XCTAssertTrue failed - Smoke flow: first boot synthetic-private-value."]
        self.assertEqual(["Smoke flow: "], public_failure_messages(messages))
        self.assertEqual({"failure_phase": "unknown", "failure_class": "control_state"}, classify_messages(messages))
        steps = (
            "required element must be ready: pinEntry.error.message",
            "required element must be available: firstboot.serverURL.field",
            "control appears: filterSummary.person.button",
            "remote focus moves toward settings.item.accessProtection",
            "remote cannot focus settings.playback.mode.filtered.button",
            "App accessibility snapshot must succeed",
            "action exceeded the shared hang guard",
            "wrong PIN keeps Settings locked",
            "Play/Pause state is play",
            "a B-exclusive photo must appear within the bounded Next path",
            "required element must be available: albumFilter.back.button",
        )
        for step in steps:
            with self.subTest(step=step):
                message = "Smoke flow: " + step + "."
                projected = public_failure_messages(["XCTAssertTrue failed - " + message])
                self.assertEqual(projected, [message])
                self.assertEqual(public_failure_messages(projected), projected)
                validate_failure_messages(projected)
                scan_diagnostic_json(json.dumps({"failure_messages": projected}).encode())
                self.assertEqual(classify_messages(projected),
                                 {"failure_phase": "unknown", "failure_class": "control_state"})
        refused = (
            "control appears: personFilter.person.private-person.button",
            "required element must be ready: pinEntry.digit.1.button",
            "peer:private-peer-label",
            "required element must be ready: pinEntry.error.message. private-peer-label",
            "control appears: filterSummary.person.button.\nprivate-peer-label",
            "wrong PIN keeps Settings locked. private-peer-label",
        )
        for step in refused:
            with self.subTest(refused=step):
                message = "Smoke flow: " + step + "."
                self.assertEqual(public_failure_messages([message]), ["Smoke flow: "])
                with self.assertRaises(ValueError):
                    scan_diagnostic_json(json.dumps({"failure_messages": [message]}).encode())

    @staticmethod
    def passed_official(selector):
        return ({"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "result": "Passed"},
                {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": selector + "()", "result": "Passed"}]})

    def execute_record(self, root, *, code=0, cleanup=False, invalid_official=False, official_failed=False,
                       failure_nodes=(), build_source_root=None, real_peer_requests=False, first_failure=None,
                       capture_format=None, first_failure_png=None, configure_runner=None, fixtures=None):
        import plistlib
        from types import SimpleNamespace
        import strict_e2e_smoke as smoke
        evidence = root / "evidence"
        evidence.mkdir()
        source = root / "source.xctestrun"
        source.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [
            {"BlueprintName": "immichSlidesUITests", **(capture_format or {})}]}]}))
        flow = {"id": "iphone-first-boot", "selector": "SmokeFlowIOSUITests/testFirstBoot",
                "fixtures": fixtures or (["a", "b"] if real_peer_requests else ["a"])}
        summary, tests = self.passed_official(flow["selector"])
        if official_failed:
            summary.update(passedTests=0, failedTests=1, result="Failed")
            tests["testNodes"][0].update(result="Failed", failure_messages=["Smoke flow: "], children=list(failure_nodes))
        elif failure_nodes:
            tests["testNodes"][0]["children"] = list(failure_nodes)
        if invalid_official:
            summary["totalTestCount"] = 0
        def export(bundle, directory, *args, **kwargs):
            smoke.write_json(directory / "official-summary.json", summary)
            if first_failure_png is not None:
                def official_export(command, **_kwargs):
                    payload = tests if "tests" in command else {}
                    return subprocess.CompletedProcess(command, 0, json.dumps(payload).encode())
                with mock.patch.object(strict_runner.subprocess, "run", side_effect=official_export):
                    return strict_runner.export_private_result_bundle(bundle, directory, *args,
                        **dict(kwargs, export_budget=None))
            if kwargs.get("first_failure_spool") is not None:
                from ci_failure_diagnostics import collect_first_failure_spool
                spool, selectors = kwargs["first_failure_spool"]
                collect_first_failure_spool(spool, selectors, [tests["testNodes"][0]] if official_failed else [],
                                            directory / "first-failure")
            smoke.write_json(directory / "official-tests.json", tests)
            return hashlib.sha256((directory / "official-tests.json").read_bytes()).hexdigest()
        fixture_commands = []
        actual_popen = subprocess.Popen
        def start(command, **kwargs):
            fixture_commands.append(command)
            if real_peer_requests:
                return actual_popen(command, **kwargs)
            Path(command[command.index("--log-file") + 1]).write_bytes(b"request GET synthetic-secret-url\nprivate-header\n")
            return mock.Mock()
        runner = SimpleNamespace(CommandError=CommandError, WRONG_PUBLIC_API_KEY=WRONG_PUBLIC_API_KEY,
            read_source_sha=mock.Mock(return_value="a" * 40), read_source_dirty_paths=mock.Mock(return_value=[]),
            destination_udid=mock.Mock(return_value="device"), reset_simulator_app=mock.Mock(return_value="reset"),
            wait_for_service=mock.Mock(return_value=("127.0.0.1", 1234)),
            write_fixture_artifacts=mock.Mock(return_value={"fixture_sha256": "b" * 64}),
            fixture_manifest=mock.Mock(return_value={}), write_member_manifest=mock.Mock(),
            make_test_environment=mock.Mock(return_value={}),
            prepare_private_result_bundle_path=mock.Mock(return_value=root / "holding/result.xcresult"),
            run_command=mock.Mock(return_value=code), OfficialExportBudget=mock.Mock(),
            export_private_result_bundle=mock.Mock(side_effect=export), stop_exact_process=mock.Mock(),
            finalize_private_result_bundle=mock.Mock(return_value=["failed"] if cleanup else []))
        runner.fixture_commands = fixture_commands
        if first_failure is not None:
            def capture(command, **_kwargs):
                target = plistlib.loads(Path(command[command.index("-xctestrun") + 1]).read_bytes())["TestConfigurations"][0]["TestTargets"][0]
                runner.prepared_target = target
                inputs = target["EnvironmentVariables"]
                if "STRICT_E2E_FIRST_FAILURE_DIR" in inputs:
                    (Path(inputs["STRICT_E2E_FIRST_FAILURE_DIR"]) / "0.json").write_text(json.dumps(first_failure))
                    if first_failure_png is not None:
                        (Path(inputs["STRICT_E2E_FIRST_FAILURE_DIR"]) / "0.png").write_bytes(first_failure_png)
                return code
            runner.run_command = mock.Mock(side_effect=capture)
        if real_peer_requests:
            import http.client
            from strict_e2e_server import PUBLIC_API_KEY
            (root / "scripts").mkdir()
            (root / "scripts/strict_e2e_server.py").write_bytes((Path(__file__).parent / "strict_e2e_server.py").read_bytes())
            runner.wait_for_service = strict_runner.wait_for_service
            runner.stop_exact_process = strict_runner.stop_exact_process
            def requests(*args, **kwargs):
                directory = evidence / flow["id"]
                for fixture, peer in (("a", "b"), ("b", "a")):
                    ready = json.loads((directory / ("service-" + fixture + "-ready.json")).read_text())
                    for identifier in ("asset-" + peer + "-1", "private-input-sentinel"):
                        connection = http.client.HTTPConnection(ready["host"], ready["port"], timeout=3)
                        try:
                            connection.request("GET", "/api/assets/" + identifier + "/thumbnail?size=thumbnail",
                                               headers={"x-api-key": PUBLIC_API_KEY})
                            response = connection.getresponse()
                            self.assertEqual(404, response.status)
                            self.assertNotIn(b"peer:", response.read())
                        finally:
                            connection.close()
                return code
            runner.run_command = mock.Mock(side_effect=requests)
        arguments = SimpleNamespace(destination="platform=iOS Simulator,id=device", platform="ios",
                                    configuration="Debug", simulator_boot_submitted=False)
        if configure_runner is not None:
            configure_runner(runner)
        with mock.patch("strict_e2e_smoke.subprocess.Popen", side_effect=start):
            record = smoke.execute_flow(flow, root, arguments, source, runner, evidence, build_source_root=build_source_root)
        if record["pretest_failure_step"] is not None:
            self.assertIn(record["pretest_failure_step"], smoke.PRETEST_FAILURE_STEPS)
        return record, runner, evidence

    def test_smoke_pretest_failures_publish_only_the_closed_step_and_timeout_variant(self):
        operations = (
            ("fixture-service:a", "wait_for_service", CommandError("private-input-sentinel"), 2),
            ("fixture-service:a:timeout", "wait_for_service", CommandError("private-input-sentinel", code=124), 124),
            ("fixture-artifacts:a", "write_fixture_artifacts", OSError("private-input-sentinel"), 2),
            ("fixture-artifacts:b", "write_member_manifest", OSError("private-input-sentinel"), 2),
            ("private-result-bundle", "prepare_private_result_bundle_path", OSError("private-input-sentinel"), 2),
        )
        for step, operation, error, expected_code in operations:
            with self.subTest(step=step), tempfile.TemporaryDirectory() as temporary:
                def configure(runner):
                    getattr(runner, operation).side_effect = error
                with mock.patch("strict_e2e_smoke.sys.stderr", io.StringIO()):
                    record, runner, evidence = self.execute_record(Path(temporary), configure_runner=configure, fixtures=["a", "b"])
                self.assertEqual(step, record["pretest_failure_step"])
                self.assertEqual(expected_code, record["exit_code"])
                self.assertEqual(("FAIL", "infrastructure", False, 0),
                    (record["outcome"], record["failure_kind"], record["official_execution_complete"], record["elapsed_seconds"]))
                self.assertEqual("Smoke flow infrastructure or official-result validation failed.", record["first_public_failure_message"])
                runner.run_command.assert_not_called()
                saved = json.loads((evidence / record["id"] / "case-manifest.json").read_text())
                self.assertEqual(record, saved["flow"])
                self.assertNotIn("private-input-sentinel", json.dumps(saved))

    def test_smoke_reset_substeps_keep_nonzero_exits_distinct_from_timeouts(self):
        from strict_e2e_runner_support import InfrastructureTimeout
        phases = {
            "terminate": "simulator-terminate", "uninstall": "simulator-uninstall",
            "uninstall-retry": "simulator-uninstall-retry", "container": "simulator-container",
            "keychain": "simulator-keychain-reset", "keychain-retry": "simulator-keychain-reset-retry",
            "privacy": "simulator-privacy-reset", "privacy-retry": "simulator-privacy-reset-retry",
            "autofill-device": "simulator-password-autofill-device",
            "autofill-disable": "simulator-password-autofill-disable",
            "autofill-readback": "simulator-password-autofill-readback",
        }
        for step, phase in phases.items():
            for timeout in (False, True):
                calls = []
                def command(argv, current, **kwargs):
                    calls.append(current)
                    # Reach an existing second attempt without introducing a new retry.
                    if current == phase.removesuffix("-retry") and phase.endswith("-retry"):
                        return subprocess.CompletedProcess(argv, 1, "", "private-input-sentinel")
                    if current == phase:
                        if timeout:
                            raise InfrastructureTimeout(current, 1)
                        if step in {"terminate", "uninstall", "keychain", "privacy"}:
                            raise OSError("private-input-sentinel")
                        return subprocess.CompletedProcess(argv, 1, "", "private-input-sentinel")
                    stdout = (json.dumps({"devices": {"runtime": [{"udid": "device", "dataPath": "/synthetic/device"}]}})
                              if current.endswith("autofill-device") else "false" if current.endswith("autofill-readback") else "")
                    return subprocess.CompletedProcess(argv, 2 if current == "simulator-container" else 0, stdout, "")
                def configure(runner):
                    runner.reset_simulator_app = strict_runner.reset_simulator_app
                with self.subTest(step=step, timeout=timeout), tempfile.TemporaryDirectory() as temporary, \
                        mock.patch("strict_e2e_runner_support.prepare_simulator", return_value=("installed", "")), \
                        mock.patch("strict_e2e_runner_support.simulator_command", side_effect=command), \
                        mock.patch("strict_e2e_runner_support.time.sleep"), mock.patch("builtins.print"):
                    record, runner, _ = self.execute_record(Path(temporary), configure_runner=configure)
                self.assertEqual("simulator-reset:" + step + (":timeout" if timeout else ""), record["pretest_failure_step"])
                self.assertEqual(("FAIL", "infrastructure", 124 if timeout else 2),
                                 (record["outcome"], record["failure_kind"], record["exit_code"]))
                self.assertIn(phase, calls)
                self.assertNotIn("private-input-sentinel", json.dumps(record))
                runner.run_command.assert_not_called()

    def test_smoke_pretest_file_and_run_preparation_failures_name_the_operation(self):
        import strict_e2e_smoke as smoke
        for step in ("flow-directory", "source-sha", "source-dirty-paths", "private-evidence",
                     "simulator-reset:log", "first-failure-spool", "fixture-service:b", "prepare-run"):
            with self.subTest(step=step), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                original_mkdir, original_write = Path.mkdir, Path.write_text
                error = OSError("private-input-sentinel")
                def mkdir(path, *args, **kwargs):
                    if ((step == "flow-directory" and path == root / "evidence/iphone-first-boot")
                            or step == "private-evidence" and path == root / "private/evidence/iphone-first-boot"
                            or step == "first-failure-spool" and path.name == "first-failure-spool"):
                        raise error
                    return original_mkdir(path, *args, **kwargs)
                def write(path, *args, **kwargs):
                    if step == "simulator-reset:log" and path.name == "simulator-reset.log":
                        raise error
                    return original_write(path, *args, **kwargs)
                def configure(runner):
                    if step == "fixture-service:b":
                        runner.wait_for_service.side_effect = [("127.0.0.1", 1234), error]
                    if step in {"source-sha", "source-dirty-paths"}:
                        operation = "read_source_sha" if step == "source-sha" else "read_source_dirty_paths"
                        getattr(runner, operation).side_effect = error
                with ExitStack() as stack:
                    stack.enter_context(mock.patch.object(Path, "mkdir", mkdir))
                    stack.enter_context(mock.patch.object(Path, "write_text", write))
                    stack.enter_context(mock.patch.object(smoke.sys, "stderr", io.StringIO()))
                    if step == "prepare-run":
                        stack.enter_context(mock.patch("strict_e2e_build.prepare_test_run", side_effect=error))
                    if step in {"flow-directory", "source-sha", "source-dirty-paths", "private-evidence"}:
                        with self.assertRaises(OSError):
                            self.execute_record(root, configure_runner=configure)
                        self.assertFalse((root / "evidence/iphone-first-boot/case-manifest.json").exists())
                        continue
                    record, runner, _ = self.execute_record(root, configure_runner=configure, fixtures=["a", "b"])
                self.assertEqual(step, record["pretest_failure_step"])
                self.assertNotIn("private-input-sentinel", json.dumps(record))
                runner.run_command.assert_not_called()

    def test_smoke_pretest_preparation_gates_and_autofill_deadline_are_attributed(self):
        from strict_e2e_runner_support import InfrastructureTimeout
        for step in ("boot", "bootstatus", "readiness", "autofill-deadline", "pretest-other", "autofill-report"):
            for timeout in (False, True):
                if step in {"pretest-other", "autofill-report"} and timeout or step == "autofill-deadline" and not timeout:
                    continue
                clock = [0.0]
                def command(argv, phase, **kwargs):
                    if phase == "simulator-" + step:
                        if timeout:
                            raise InfrastructureTimeout(phase, 1)
                        return subprocess.CompletedProcess(argv, 1, "", "private-input-sentinel")
                    if step in {"autofill-deadline", "autofill-report"} and phase == "simulator-password-autofill-readback":
                        clock[0] = 61
                    stdout = (json.dumps({"devices": {"runtime": [{"udid": "device", "dataPath": "/synthetic/device"}]}})
                              if phase.endswith("autofill-device") else "false" if phase.endswith("autofill-readback") else "")
                    return subprocess.CompletedProcess(argv, 2 if phase == "simulator-container" else 0, stdout, "")
                def configure(runner):
                    runner.reset_simulator_app = strict_runner.reset_simulator_app
                def report(line, **kwargs):
                    if (step == "pretest-other" and line.startswith("password_autofill=disabled;")
                            or step == "autofill-report" and line.startswith("password-autofill:")):
                        raise OSError("private-input-sentinel")
                with self.subTest(step=step, timeout=timeout), tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
                    stack.enter_context(mock.patch("strict_e2e_runner_support.simulator_command", side_effect=command))
                    stack.enter_context(mock.patch("strict_e2e_runner_support.time.sleep"))
                    stack.enter_context(mock.patch("strict_e2e_runner_support.time.monotonic", side_effect=lambda: clock[0]))
                    stack.enter_context(mock.patch("builtins.print", side_effect=report))
                    if step == "readiness":
                        error = InfrastructureTimeout("simulator-readiness", 1) if timeout else CommandError("private-input-sentinel")
                        stack.enter_context(mock.patch("strict_e2e_runner_support.wait_for_simulator_app_response", side_effect=error))
                    record, runner, _ = self.execute_record(Path(temporary), configure_runner=configure)
                expected = "pretest-other" if step in {"pretest-other", "autofill-report"} else "simulator-reset:" + step + (":timeout" if timeout else "")
                self.assertEqual(expected, record["pretest_failure_step"])
                self.assertNotIn("private-input-sentinel", json.dumps(record))
                runner.run_command.assert_not_called()

    def test_smoke_executed_flows_leave_pretest_diagnostics_null(self):
        cases = ((0, False, None), (65, True, None), (0, False, "run_command"),
                 (0, False, "export_private_result_bundle"))
        for code, official_failed, failing_operation in cases:
            with self.subTest(code=code, operation=failing_operation), tempfile.TemporaryDirectory() as temporary:
                def configure(runner):
                    if failing_operation is not None:
                        getattr(runner, failing_operation).side_effect = CommandError("private-input-sentinel", code=124)
                with mock.patch("strict_e2e_smoke.sys.stderr", io.StringIO()):
                    record, runner, _ = self.execute_record(Path(temporary), code=code, official_failed=official_failed,
                                                          configure_runner=configure)
                self.assertIsNone(record["pretest_failure_step"])
                self.assertEqual(1, runner.run_command.call_count)
                self.assertEqual(2, runner.read_source_sha.call_count)
                if failing_operation is not None:
                    expected_kind = "hang-guard" if failing_operation == "run_command" else "official-result"
                    self.assertEqual(("FAIL", 124, expected_kind),
                                     (record["outcome"], record["exit_code"], record["failure_kind"]))

    def test_smoke_exit_and_cleanup_failures_override_a_passing_official_method(self):
        for code, cleanup, invalid, expected in ((0, False, False, ("PASS", 0, "none")),
                (65, False, False, ("FAIL", 65, "infrastructure")),
                (0, True, False, ("FAIL", 2, "cleanup")), (0, False, True, ("FAIL", 2, "official-result"))):
            with self.subTest(code=code, cleanup=cleanup, invalid=invalid), tempfile.TemporaryDirectory() as temporary:
                record, runner, _ = self.execute_record(Path(temporary), code=code, cleanup=cleanup, invalid_official=invalid)
                self.assertEqual(expected, (record["outcome"], record["exit_code"], record["failure_kind"]))
                self.assertEqual(1, runner.run_command.call_count)

    def test_smoke_first_failure_spool_reaches_the_official_export_without_changing_the_first_result(self):
        from ci_failure_diagnostics import unavailable_first_failure
        receipt = unavailable_first_failure("xctest", step="query-element", element="slideshow.control.settings.button")
        receipt["action"] = "tap"
        receipt["timing"].update(since_action_issued_seconds=16, action_duration_seconds=9,
                                 wait_elapsed_seconds=7, deadline_seconds=7)
        receipt["screenshot"]["status"] = "withheld-privacy"
        for capture_format in ({}, {"PreferredScreenCaptureFormat": "video", "SystemAttachmentLifetime": "keepAlways"}):
            with self.subTest(capture_format=capture_format), tempfile.TemporaryDirectory() as temporary:
                record, runner, evidence = self.execute_record(Path(temporary), code=65, official_failed=True,
                    first_failure=receipt, capture_format=capture_format)
                self.assertEqual((record["outcome"], record["exit_code"], record["failure_kind"]), ("FAIL", 65, "test"))
                target = runner.prepared_target
                self.assertEqual({key: target[key] for key in ("PreferredScreenCaptureFormat", "SystemAttachmentLifetime")
                                  if key in target}, capture_format)
                self.assertFalse(any(key.startswith("STRICT_E2E_FIRST_FAILURE_")
                                     for key in runner.run_command.call_args.kwargs["environment"]))
                inputs = target["EnvironmentVariables"]
                self.assertEqual(inputs["STRICT_E2E_FIRST_FAILURE_SCREENSHOT"], "1")
                self.assertEqual(json.loads(inputs["STRICT_E2E_FIRST_FAILURE_TESTS"]), {record["selector"]: 0})
                spool, selectors = runner.export_private_result_bundle.call_args.kwargs["first_failure_spool"]
                self.assertEqual(str(spool), inputs["STRICT_E2E_FIRST_FAILURE_DIR"])
                self.assertEqual(selectors, [record["selector"]])
                public = json.loads((evidence / record["id"] / "official-tests.json").read_text())
                self.assertEqual(public["testNodes"][0]["first_failure"], receipt)
                self.assertFalse(spool.exists())

    def test_smoke_captured_first_failure_exports_the_single_method_image_path(self):
        from PIL import Image
        from ci_failure_diagnostics import unavailable_first_failure, validate_first_failure_image
        picture = io.BytesIO()
        Image.new("RGB", (64, 32), "blue").save(picture, format="PNG")
        png = picture.getvalue()
        receipt = unavailable_first_failure("xctest")
        receipt["state"].update(app="running-foreground", surface="playback")
        receipt["screenshot"].update(status="captured", width=64, height=32, bytes=len(png))
        with tempfile.TemporaryDirectory() as temporary:
            record, runner, evidence = self.execute_record(Path(temporary), code=65, official_failed=True,
                first_failure=receipt, first_failure_png=png)
            self.assertEqual((record["outcome"], record["exit_code"], record["failure_kind"]), ("FAIL", 65, "test"))
            image = evidence / record["id"] / "first-failure/0.png"
            self.assertEqual([path.relative_to(evidence).as_posix() for path in evidence.rglob("*.png")],
                             [record["id"] + "/first-failure/0.png"])
            public = json.loads((evidence / record["id"] / "official-tests.json").read_text())
            retained = public["testNodes"][0]["first_failure"]
            self.assertEqual(retained["screenshot"]["status"], "captured")
            validate_first_failure_image(image, retained)
            spool, _ = runner.export_private_result_bundle.call_args.kwargs["first_failure_spool"]
            self.assertFalse(spool.exists())

    def test_smoke_request_logs_are_private_and_only_fixed_metadata_is_public(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record, _, evidence = self.execute_record(root)
            private = root / "private/evidence/iphone-first-boot/service-a.log"
            self.assertTrue(private.is_file())
            self.assertFalse(any(path.name == "private" for path in evidence.rglob("*")))
            self.assertEqual(0o600, private.stat().st_mode & 0o777)
            self.assertEqual({"a": {"state": "present", "bytes": private.stat().st_size,
                "sha256": hashlib.sha256(private.read_bytes()).hexdigest(), "request_count": 1}}, record["request_logs"])
            self.assertNotIn("synthetic-secret-url", json.dumps(record))
            self.assertEqual([], record["source_dirty_paths"])

    def test_peer_fixture_labels_stay_in_private_logs_through_real_http_and_runner_projection(self):
        from contextlib import redirect_stderr
        from strict_e2e_server import create_server, main as server_main
        with self.assertRaisesRegex(ValueError, "Peer fixture must be a different public fixture"):
            create_server(host="127.0.0.1", port=0, fixture_set="a", scenario="normal", peer_fixture_set="a")
        errors = io.StringIO()
        with mock.patch("strict_e2e_server.create_server") as create, redirect_stderr(errors), self.assertRaises(SystemExit) as caught:
            server_main(["--port", "0", "--fixture-set", "a", "--peer-fixture-set", "a"])
        self.assertEqual(2, caught.exception.code)
        self.assertIn("--peer-fixture-set must differ", errors.getvalue())
        create.assert_not_called()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record, runner, evidence = self.execute_record(root, real_peer_requests=True)
            self.assertEqual("PASS", record["outcome"])
            for fixture, peer, label in (("a", "b", "B1"), ("b", "a", "A1")):
                private = root / "private/evidence/iphone-first-boot" / ("service-" + fixture + ".log")
                text = private.read_text()
                self.assertIn("fixture_asset_id=peer:" + label, text)
                self.assertNotIn("private-input-sentinel", text)
                command = next(command for command in runner.fixture_commands
                               if command[command.index("--fixture-set") + 1] == fixture)
                self.assertEqual(peer, command[command.index("--peer-fixture-set") + 1])
                self.assertEqual({"state", "bytes", "sha256", "request_count"}, set(record["request_logs"][fixture]))
                self.assertGreaterEqual(record["request_logs"][fixture]["request_count"], 2)
            self.assertNotIn("peer:", json.dumps(record))
            self.assertNotIn("private-input-sentinel", json.dumps(record))
            self.assertFalse(any(path.name.startswith("service-") and path.suffix == ".log" and "startup" not in path.name
                                 for path in evidence.rglob("*")))

    def test_smoke_failure_locations_are_reviewed_coordinates_bound_to_the_record_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            compiled = root / "retired-build-source"
            def failure(path, line):
                return {"nodeType": "Failure Message", "sourceLocation": {"filePath": str(path), "lineNumber": line}}
            first = failure(compiled / "immichSlidesUITests/SmokeFlowIOSUITests.swift", 25)
            nodes = [failure("/tmp/private-input-sentinel/foreign.swift", 7),
                      failure(root / "immichSlidesUITests/../foreign.swift", 8),
                      failure(root / "immichSlidesUITests/Invalid.swift", True),
                      failure(root / "immichSlidesUITests/Invalid.swift", 0),
                      failure(root / "immichSlidesUITests/Invalid.md", 9),
                      first, failure(root / "TestSupport/Wait.swift", 4), copy.deepcopy(first),
                      failure(root / "TestSupport/Third.swift", 5), failure(root / "TestSupport/Fourth.swift", 6)]
            foreign_resolutions = []
            original_resolve = Path.resolve
            def resolve(path, *args, **kwargs):
                if "private-input-sentinel" in str(path):
                    foreign_resolutions.append(str(path))
                return original_resolve(path, *args, **kwargs)
            with mock.patch.object(Path, "resolve", resolve):
                record, _, _ = self.execute_record(root, code=65, official_failed=True, failure_nodes=nodes,
                                                    build_source_root=compiled)
            self.assertEqual([], foreign_resolutions)
            self.assertEqual("FAIL", record["outcome"])
            self.assertEqual("a" * 40, record["source_sha"])
            self.assertEqual([{"path": "immichSlidesUITests/SmokeFlowIOSUITests.swift", "line": 25},
                              {"path": "TestSupport/Wait.swift", "line": 4},
                              {"path": "TestSupport/Third.swift", "line": 5}], record["failure_locations"])
            self.assertNotIn("private-input-sentinel", json.dumps(record))
        with tempfile.TemporaryDirectory() as temporary:
            record, _, _ = self.execute_record(Path(temporary), failure_nodes=[{
                "nodeType": "Failure Message", "sourceLocation": {"filePath": str(Path(temporary) / "TestSupport/Wait.swift"), "lineNumber": 4}}])
            self.assertIsNone(record["failure_locations"])

    def test_smoke_xctest_timeout_precedes_the_outer_startup_budget(self):
        import strict_e2e_smoke as smoke
        with tempfile.TemporaryDirectory() as temporary:
            _, runner, _ = self.execute_record(Path(temporary))
            command = runner.run_command.call_args.args[0]
            self.assertEqual("YES", command[command.index("-test-timeouts-enabled") + 1])
            for flag in ("-default-test-execution-time-allowance", "-maximum-test-execution-time-allowance"):
                self.assertEqual("180", command[command.index(flag) + 1])
            self.assertEqual(330, runner.run_command.call_args.kwargs["timeout_seconds"])
            self.assertEqual(150, smoke.STARTUP_OVERHEAD_SECONDS)

    def test_smoke_warm_source_root_stays_private_while_legacy_receipts_stay_unchanged(self):
        import plistlib
        import strict_e2e_build as build
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            identity = {"scheme": "immichSlides-iOS-settings-resume", "test_plan": "StrictE2E-iOS", "configuration": "Debug"}
            for suite in ("smoke", "smoke-flow"):
                derived, evidence = root / (suite + "-derived"), root / (suite + "-evidence")
                evidence.mkdir()
                def compile_products(*args, **kwargs):
                    products = derived / "Build/Products"
                    app = products / "Debug-iphonesimulator/immichSlides.app"
                    app.mkdir(parents=True)
                    (app / "Info.plist").write_bytes(plistlib.dumps({}))
                    (products / "input.xctestrun").write_bytes(plistlib.dumps({}))
                    return 0
                with mock.patch.object(build, "workspace_preflight"), mock.patch.object(build, "shard_identity", return_value=identity), \
                        mock.patch.object(build, "measure_signing", return_value="adhoc"), mock.patch.object(build, "inventory", return_value=[]):
                    receipt = build.warm_up(root=source, platform="ios", suite=suite, configuration="Debug",
                        destination="platform=iOS Simulator,id=device", derived=derived, packages=root / "packages",
                        evidence=evidence, timeout=300, execute=compile_products)
                saved = json.loads((derived / build.RECEIPT).read_text())
                self.assertEqual(receipt, saved)
                if suite == "smoke-flow":
                    self.assertEqual(str(source.resolve()), saved["source_root"])
                else:
                    self.assertNotIn("source_root", saved)
                public = json.loads((evidence / "warm-up.json").read_text())
                self.assertNotIn("source_root", public)
                self.assertNotIn(str(source), json.dumps(public))

    def run_group(self, root, *, single=False, failed=False, dirty=False, late=None, overrides=None):
        from types import SimpleNamespace
        import strict_e2e_smoke as smoke
        evidence = root / "evidence"
        flows = [{"id": "iphone-first-boot", "platform": "ios", "device": "iphone", "configuration": "Debug",
                  "fixtures": ["a"], "selector": "SmokeFlowIOSUITests/testFirstBoot"},
                 {"id": "iphone-connection-error", "platform": "ios", "device": "iphone", "configuration": "Debug",
                  "fixtures": ["a"], "selector": "SmokeFlowIOSUITests/testConnectionError"}]
        planned = [{k: flow[k] for k in ("id", "device", "configuration")} | {"fixture": "a"} for flow in flows]
        arguments = SimpleNamespace(smoke_device="iphone", configuration="Debug", platform="ios", listed_retry_device=None,
            nightly_retry_method=None, nightly_retry_source=None, scenario="normal", fixture_set="a",
            smoke_flow=flows[0]["id"] if single else None, min_free_gib=80,
            destination="platform=iOS Simulator,id=device", evidence_dir=evidence, derived_data_path=root / "derived",
            cloned_source_packages_path=root / "packages", test_without_building=True, warm_up_only=False)
        for key, value in (overrides or {}).items():
            setattr(arguments, key, value)
        if getattr(arguments, "smoke_archive", False):
            arguments.smoke_control_path = root / "expected-control.json"
            arguments.smoke_control_path.write_text(json.dumps({"id": "200"}))
        if late == "owned-cleanup":
            arguments.derived_data_path = None
            (root / "owned").mkdir()
        def assert_running(gate):
            for name in ("case-manifest.json", "smoke-flow-results.json"):
                payload = json.loads((evidence / name).read_text())
                self.assertEqual(("RUNNING", None), (payload["result"], payload["exit_code"]))
            self.assertFalse((evidence / "official-summary.json").exists())
            if gate == "privacy" and late in {"privacy-one", "privacy-root"}:
                smoke.write_json(evidence / "sensitive-scan.json", {"result": "FAIL", "matched_files":
                    ["iphone-first-boot/xcodebuild.log"] if late == "privacy-one" else ["official-tests.json"]})
                raise CommandError("sensitive scan failed")
            if late == gate:
                raise CommandError(gate + " failed")
        runner = SimpleNamespace(CommandError=CommandError, WRONG_PUBLIC_API_KEY=WRONG_PUBLIC_API_KEY,
            ensure_disk_for_xcodebuild=mock.Mock(), data_available_gib=mock.Mock(), destination_udid=mock.Mock(return_value="device"),
            prepare_evidence_directory=lambda path: path.mkdir(), read_source_sha=lambda path: "a" * 40,
            read_source_dirty_paths=lambda path: [" M changed.swift"] if dirty else [],
            write_case_manifest=lambda path, payload: smoke.write_json(path / "case-manifest.json", payload),
            write_sensitive_scan=mock.Mock(side_effect=lambda *args: assert_running("privacy")))
        original_write_json = smoke.write_json
        def write_json(path, payload):
            if late == "evidence-finalization" and path.resolve() == (evidence / "official-summary.json").resolve():
                raise OSError("final summary write failed")
            return original_write_json(path, payload)
        def execute(flow, *args, **kwargs):
            self.assertEqual("/retired/compilation-root", kwargs["build_source_root"])
            directory = evidence / flow["id"]
            directory.mkdir()
            summary, tests = self.passed_official(flow["selector"])
            if failed and flow == flows[0]:
                summary.update(passedTests=0, failedTests=1, result="Failed")
                tests["testNodes"][0]["result"] = "Failed"
            smoke.write_json(directory / "official-summary.json", summary)
            if late == "official-result" and flow == flows[0]:
                (directory / "official-summary.json").write_text("{invalid")
            smoke.write_json(directory / "official-tests.json", tests)
            record = dict(id=flow["id"], selector=flow["selector"], source_sha="a" * 40, source_dirty_paths=[],
                outcome="FAIL" if summary["failedTests"] else "PASS", exit_code=65 if summary["failedTests"] else 0,
                failure_kind="test" if summary["failedTests"] else "none", official_execution_complete=True,
                official_summary=summary, official_tests_sha256=hashlib.sha256((directory / "official-tests.json").read_bytes()).hexdigest(),
                elapsed_seconds=2)
            smoke.write_json(directory / "case-manifest.json", {"flow": record,
                "result": "Failed" if summary["failedTests"] else "Passed", "exit_code": record["exit_code"],
                "official_summary": summary})
            return record
        with mock.patch.object(smoke, "load_manifest", return_value=({"schema_version": 1, "flows": flows},
                {flow["selector"]: {"ios"} for flow in flows})), mock.patch.object(smoke, "validate_manifest", return_value=flows), mock.patch("ci_simulator.simulator_device_class"), \
                mock.patch("strict_e2e_build.validate_paths"), \
                mock.patch("strict_e2e_build.load_warm_build", return_value=({"identity": "warm", "source_root": "/retired/compilation-root"}, root / "run")), \
                mock.patch("strict_e2e_build.load_smoke_archive", side_effect=CommandError("archive rejected") if late == "archive" else None,
                    return_value=({"identity": "generic", "source_root": "/retired/compilation-root", "control": {"id": "200"},
                                   "archive_sha256": "b" * 64}, root / "run", {"device": "iphone"})) as archive_load, \
                mock.patch("strict_e2e_build.warm_up", side_effect=AssertionError("consumer compiled")), \
                mock.patch("strict_e2e_build.validate_warm_products", side_effect=lambda *args: assert_running("products")), \
                mock.patch.object(smoke.tempfile, "mkdtemp", return_value=str(root / "owned")), \
                mock.patch.object(smoke.shutil, "rmtree", side_effect=OSError("cleanup failed") if late == "owned-cleanup" else None), \
                mock.patch.object(smoke, "write_json", side_effect=write_json), \
                mock.patch.object(smoke, "execute_flow", side_effect=execute) as execution:
            try:
                code = smoke.run(arguments, root, runner, io.StringIO(), io.StringIO())
                if getattr(arguments, "smoke_archive", False):
                    self.assertEqual(archive_load.call_args.kwargs["control"], {"id": "200"})
            except (CommandError, OSError, ValueError):
                code = 2
            return code, flows, evidence, execution.call_count

    def test_smoke_archive_rejection_starts_no_flow_and_success_reuses_only_admitted_products(self):
        for rejected in (False, True):
            with self.subTest(rejected=rejected), tempfile.TemporaryDirectory() as raw:
                code, flows, evidence, calls = self.run_group(Path(raw), overrides={"smoke_archive": True},
                                                             late="archive" if rejected else None)
                self.assertEqual((code, calls), (2, 0) if rejected else (0, len(flows)))
                if not rejected:
                    case = json.loads((evidence / "case-manifest.json").read_text())
                    self.assertEqual(case["build_mode"], "smoke-archive-v2")
                    self.assertEqual(case["execution_identity"], {"device": "iphone"})
                    self.assertEqual(case["warm_build_identity"], "generic")
        for change in ({"test_without_building": False}, {"warm_up_only": True}, {"derived_data_path": None}):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as raw:
                code, _, _, calls = self.run_group(Path(raw), overrides={"smoke_archive": True, **change})
                self.assertEqual((code, calls), (2, 0))

    def test_smoke_group_aggregates_first_results_and_labels_single_flow(self):
        for single, failed in ((False, False), (True, False), (False, True)):
            with self.subTest(single=single, failed=failed), tempfile.TemporaryDirectory() as temporary:
                code, flows, evidence, calls = self.run_group(Path(temporary), single=single, failed=failed)
                result = json.loads((evidence / "smoke-flow-results.json").read_text())
                self.assertEqual(65 if failed else 0, code)
                self.assertEqual(1 if single else 2, calls)
                self.assertEqual([flow["id"] for flow in (flows[:1] if single else flows)], [r["id"] for r in result["flows"]])
                self.assertEqual("single-flow" if single else "group", result["selection"])
                self.assertEqual(("FAILED", 65) if failed else ("Passed", 0), (result["result"], result["exit_code"]))
                summary = json.loads((evidence / "official-summary.json").read_text())
                self.assertEqual((calls, calls - int(failed), int(failed), 0),
                                 tuple(summary[k] for k in ("totalTestCount", "passedTests", "failedTests", "skippedTests")))

    def test_smoke_late_gates_and_dirty_checkout_cannot_leave_a_passing_root(self):
        for late, dirty in (("privacy", False), ("privacy-one", False), ("privacy-root", False),
                            ("products", False), ("owned-cleanup", False), ("official-result", False),
                            ("evidence-finalization", False), (None, True)):
            with self.subTest(late=late, dirty=dirty), tempfile.TemporaryDirectory() as temporary:
                code, _, evidence, calls = self.run_group(Path(temporary), late=late, dirty=dirty)
                self.assertEqual(2, code)
                self.assertEqual(0 if dirty else 2, calls)
                for name in ("case-manifest.json", "smoke-flow-results.json"):
                    payload = json.loads((evidence / name).read_text())
                    self.assertEqual(("FAILED", 2), (payload["result"], payload["exit_code"]))
                if (evidence / "official-summary.json").exists():
                    self.assertEqual("Failed", json.loads((evidence / "official-summary.json").read_text())["result"])
                records = json.loads((evidence / "smoke-flow-results.json").read_text())["flows"]
                for index, record in enumerate(records):
                    affected = late != "privacy-one" or index == 0
                    expected = ("FAIL", 2) if affected else ("PASS", 0)
                    self.assertEqual(expected, (record["outcome"], record["exit_code"]))
                    saved = json.loads((evidence / record["id"] / "case-manifest.json").read_text())
                    self.assertEqual(record, saved["flow"])
                    self.assertEqual(("FAILED", 2) if affected else ("Passed", 0), (saved["result"], saved["exit_code"]))
                    self.assertEqual("Passed", saved["official_summary"]["result"])
                    if affected:
                        self.assertEqual({"products": "warm-products", "owned-cleanup": "build-cleanup",
                                          "official-result": "official-result", "evidence-finalization": "evidence-finalization"}.get(late, "sensitive-scan"),
                                         record["failure_kind"])

    def test_late_gate_keeps_the_first_test_failure_and_records_the_group_gate(self):
        for late in ("products", "privacy-one"):
            with self.subTest(late=late), tempfile.TemporaryDirectory() as temporary:
                code, _, evidence, _ = self.run_group(Path(temporary), failed=True, late=late)
                self.assertEqual(2, code)
                root = json.loads((evidence / "smoke-flow-results.json").read_text())
                first, second = root["flows"]
                self.assertEqual(("FAIL", 65, "test"), (first["outcome"], first["exit_code"], first["failure_kind"]))
                self.assertEqual("Failed", first["official_summary"]["result"])
                saved = json.loads((evidence / first["id"] / "case-manifest.json").read_text())
                self.assertEqual(("FAILED", 65, first), (saved["result"], saved["exit_code"], saved["flow"]))
                self.assertEqual("warm-products" if late == "products" else "sensitive-scan", root["group_failures"][0]["failure_kind"])
                self.assertEqual(("FAIL", 2) if late == "products" else ("PASS", 0), (second["outcome"], second["exit_code"]))

    def test_late_gate_preserves_the_first_hang_guard_failure(self):
        import strict_e2e_smoke as smoke
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            record = {"id": "iphone-first-boot", "outcome": "FAIL", "exit_code": 124,
                      "failure_kind": "hang-guard", "official_execution_complete": False}
            directory = evidence / record["id"]
            directory.mkdir()
            smoke.write_json(directory / "case-manifest.json", {"flow": record, "result": "FAILED", "exit_code": 124})
            gate = smoke.fail_gate_flows(evidence, [record], "evidence-finalization")
            self.assertEqual(("FAIL", 124, "hang-guard"), (record["outcome"], record["exit_code"], record["failure_kind"]))
            self.assertEqual({"failure_kind": "evidence-finalization", "exit_code": 2,
                              "flow_ids": [record["id"]]}, gate)
            self.assertEqual({"flow": record, "result": "FAILED", "exit_code": 124},
                             json.loads((directory / "case-manifest.json").read_text()))

    def test_cleanup_invalidates_passing_roots_before_a_per_flow_evidence_write_fails(self):
        import strict_e2e_smoke as smoke
        with tempfile.TemporaryDirectory() as temporary:
            code, _, evidence, _ = self.run_group(Path(temporary))
            self.assertEqual(0, code)
            original = smoke.write_json
            def write_json(path, payload):
                if path == evidence / "iphone-first-boot/case-manifest.json":
                    raise OSError("per-flow write failed")
                original(path, payload)
            with mock.patch.object(smoke, "write_json", side_effect=write_json), self.assertRaises(OSError):
                smoke.record_cleanup_failure(evidence, {"phase": "snapshot-occupancy", "error_type": "TimeoutExpired",
                                                        "retained_path": "/private/tmp/synthetic-source"})
            for name in ("case-manifest.json", "smoke-flow-results.json"):
                payload = json.loads((evidence / name).read_text())
                self.assertEqual(("FAILED", 2), (payload["result"], payload["exit_code"]))
                self.assertEqual("cleanup", payload["group_failures"][0]["failure_kind"])


    def test_smoke_group_validator_rejects_partial_dirty_wrong_or_changed_official_evidence(self):
        import strict_e2e_smoke as smoke
        with self.assertRaisesRegex(TypeError, "expected_source_sha"):
            smoke.validate_group_evidence(Path("unused"), [], "iphone", "Debug")
        mutations = (
            ("case-manifest.json", lambda p: p.update(selection="single-flow")),
            ("smoke-flow-results.json", lambda p: p.update(selection="single-flow")),
            ("smoke-flow-results.json", lambda p: p.update(result="RUNNING")),
            ("case-manifest.json", lambda p: p.update(exit_code=False)),
            ("case-manifest.json", lambda p: p.update(exit_code=65)),
            ("smoke-flow-results.json", lambda p: p.update(exit_code=False)),
            ("case-manifest.json", lambda p: p.update(result="FAILED")),
            ("case-manifest.json", lambda p: p.update(group_failures=[{"failure_kind": "warm-products"}])),
            ("case-manifest.json", lambda p: p.update(device="ipad")),
            ("smoke-flow-results.json", lambda p: p.update(configuration="Release")),
            ("case-manifest.json", lambda p: p.update(source_sha="invalid")),
            ("case-manifest.json", lambda p: p.update(source_dirty_paths=[" M file"])),
            ("smoke-flow-results.json", lambda p: p.update(source_sha="b" * 40)),
            ("smoke-flow-results.json", lambda p: p["flows"].reverse()),
            ("smoke-flow-results.json", lambda p: p["flows"].pop()),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(id="unknown")),
            ("case-manifest.json", lambda p: p["flows"].reverse()),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(official_execution_complete=False)),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(outcome="FAIL")),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(exit_code=65)),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(exit_code=False)),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(source_sha="b" * 40)),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(source_dirty_paths=[" M file"])),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(selector="Other/testWrong")),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(failure_kind="cleanup")),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(official_tests_sha256="b" * 64)),
            ("smoke-flow-results.json", lambda p: p["flows"][0].update(official_summary={})),
            ("iphone-first-boot/official-tests.json", lambda p: p["testNodes"][0].update(nodeIdentifier="Other/testWrong()")),
            ("iphone-first-boot/official-summary.json", lambda p: p.update(skippedTests=1)),
        )
        for filename, mutate in mutations:
            with self.subTest(filename=filename, mutate=mutate), tempfile.TemporaryDirectory() as temporary:
                code, flows, evidence, _ = self.run_group(Path(temporary))
                self.assertEqual(0, code)
                self.assertEqual(2, len(smoke.validate_group_evidence(evidence, flows, "iphone", "Debug", expected_source_sha="a" * 40)))
                with self.assertRaisesRegex(ValueError, "smoke-group-evidence"):
                    smoke.validate_group_evidence(evidence, flows, "iphone", "Debug", expected_source_sha="b" * 40)
                path = evidence / filename
                payload = json.loads(path.read_text())
                mutate(payload)
                smoke.write_json(path, payload)
                case = json.loads((evidence / "case-manifest.json").read_text())
                result = json.loads((evidence / "smoke-flow-results.json").read_text())
                if filename == "smoke-flow-results.json":
                    case["flows"] = copy.deepcopy(result["flows"])
                elif filename == "case-manifest.json" and case["source_sha"] == "invalid":
                    result["source_sha"] = "invalid"
                    for record in result["flows"]:
                        record["source_sha"] = "invalid"
                    case["flows"] = copy.deepcopy(result["flows"])
                elif filename.endswith("/official-tests.json"):
                    result["flows"][0]["official_tests_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                    case["flows"] = copy.deepcopy(result["flows"])
                elif filename.endswith("/official-summary.json"):
                    result["flows"][0]["official_summary"] = payload
                    case["flows"] = copy.deepcopy(result["flows"])
                smoke.write_json(evidence / "case-manifest.json", case)
                smoke.write_json(evidence / "smoke-flow-results.json", result)
                with self.assertRaisesRegex(ValueError, "smoke-group-evidence"):
                    smoke.validate_group_evidence(evidence, flows, "iphone", "Debug",
                                                  expected_source_sha="invalid" if case["source_sha"] == "invalid" else "a" * 40)

    def test_stuck_smoke_records_the_first_failure_without_retrying_or_claiming_execution(self):
        import plistlib
        from types import SimpleNamespace
        from strict_e2e_smoke import execute_flow
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.xctestrun"
            source.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [
                {"BlueprintName": "immichSlidesUITests"}]}]}))
            runner = SimpleNamespace(CommandError=CommandError, WRONG_PUBLIC_API_KEY=WRONG_PUBLIC_API_KEY,
                read_source_sha=mock.Mock(return_value="a" * 40), read_source_dirty_paths=mock.Mock(return_value=[]),
                destination_udid=mock.Mock(return_value="device"),
                reset_simulator_app=mock.Mock(return_value="reset"), wait_for_service=mock.Mock(return_value=("127.0.0.1", 1234)),
                write_fixture_artifacts=mock.Mock(return_value={"fixture_sha256": "b" * 64}),
                make_test_environment=mock.Mock(return_value={}),
                prepare_private_result_bundle_path=mock.Mock(return_value=root / "holding/result.xcresult"),
                run_command=mock.Mock(side_effect=CommandError("xcodebuild timed out")),
                export_private_result_bundle=mock.Mock(), stop_exact_process=mock.Mock(),
                finalize_private_result_bundle=mock.Mock(return_value=[]))
            arguments = SimpleNamespace(destination="platform=iOS Simulator,id=device", platform="ios",
                                        configuration="Debug", simulator_boot_submitted=False)
            flow = {"id": "iphone-first-boot", "selector": "SmokeFlowIOSUITests/testFirstBoot", "fixtures": ["a"]}
            evidence = root / "evidence"
            evidence.mkdir()
            with mock.patch("strict_e2e_smoke.subprocess.Popen"), mock.patch("strict_e2e_smoke.sys.stderr", io.StringIO()):
                result = execute_flow(flow, root, arguments, source, runner, evidence)
            self.assertEqual(("FAIL", 124, "hang-guard", False),
                             (result["outcome"], result["exit_code"], result["failure_kind"], result["official_execution_complete"]))
            self.assertEqual("Smoke flow execution exceeded its hang guard.", result["first_public_failure_message"])
            self.assertEqual(1, runner.run_command.call_count)
            runner.export_private_result_bundle.assert_not_called()
            self.assertEqual(1, runner.stop_exact_process.call_count)
            self.assertEqual({"a": {"state": "unavailable", "bytes": None, "sha256": None, "request_count": None}},
                             result["request_logs"])
            saved = json.loads((evidence / flow["id"] / "case-manifest.json").read_text())
            self.assertEqual(result, saved["flow"])

    def test_smoke_selects_the_whole_ordered_group_or_one_explicit_member(self):
        from strict_e2e_smoke import select_flows
        flows = [{"id": "a", "device": "iphone", "configuration": "Debug"},
                 {"id": "b", "device": "ipad", "configuration": "Debug"},
                 {"id": "c", "device": "iphone", "configuration": "Release"},
                 {"id": "d", "device": "iphone", "configuration": "Debug"}]
        self.assertEqual([flows[0], flows[3]], select_flows(flows, "iphone", "Debug"))
        self.assertEqual([flows[3]], select_flows(flows, "iphone", "Debug", "d"))
        for key in ("missing", "b", "c"):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "smoke-flow selection is empty or the requested flow"):
                select_flows(flows, "iphone", "Debug", key)

    def test_smoke_requires_the_selected_official_method_and_no_skip_or_extra_execution(self):
        from strict_e2e_smoke import official_flow_passed, official_flow_complete
        summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "result": "Passed"}
        tests = {"testNodes": [{"children": [{"nodeType": "Test Case", "nodeIdentifier": "BootUITests/testSave()",
                                             "result": "Passed"}]}]}
        self.assertTrue(official_flow_passed("BootUITests/testSave", summary, tests))
        self.assertTrue(official_flow_complete("BootUITests/testSave", summary, tests))
        failed_tests = copy.deepcopy(tests)
        failed_tests["testNodes"][0]["children"][0]["result"] = "Failed"
        failed_summary = dict(summary, passedTests=0, failedTests=1, result="Failed")
        self.assertTrue(official_flow_complete("BootUITests/testSave", failed_summary, failed_tests))
        self.assertFalse(official_flow_passed("BootUITests/testSave", failed_summary, failed_tests))
        for field, value in (("totalTestCount", 0), ("passedTests", 0), ("failedTests", 1), ("skippedTests", 1),
                             ("result", "Failed")):
            with self.subTest(field=field):
                self.assertFalse(official_flow_passed("BootUITests/testSave", dict(summary, **{field: value}), tests))
                self.assertFalse(official_flow_complete("BootUITests/testSave", dict(summary, **{field: value}), tests))
        self.assertFalse(official_flow_complete("BootUITests/testSave", dict(summary, totalTestCount=True), tests))
        for mutation in ("wrong-method", "failed", "skipped", "missing", "duplicate"):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(tests)
                nodes = changed["testNodes"][0]["children"]
                if mutation == "wrong-method":
                    nodes[0]["nodeIdentifier"] = "BootUITests/testOther()"
                elif mutation in ("failed", "skipped"):
                    nodes[0]["result"] = mutation.title()
                elif mutation == "missing":
                    nodes.clear()
                else:
                    nodes.append(copy.deepcopy(nodes[0]))
                self.assertFalse(official_flow_passed("BootUITests/testSave", summary, changed))
                self.assertFalse(official_flow_complete("BootUITests/testSave", summary, changed))


if __name__ == "__main__":
    unittest.main()
