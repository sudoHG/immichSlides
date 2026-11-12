"""Guard per-test fixture coverage against missing, duplicate and skipped results."""

import copy
import contextlib
import io
import itertools
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import run_fixture_ui_tests as runner
from ci_summary import ContractError
from run_fixture_ui_tests import clean_environment, compiled_tests, coverage_rows, declared_tests, problem_reason


class LifecycleCaptureTests(unittest.TestCase):
    def test_stream_keeps_the_recent_log_tail_and_projects_processes_before_capping(self):
        import ci_xctest_lifecycle as capture
        import sys
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(capture, "MAX_FILE_BYTES", 100):
                with patch.object(capture, "bounded_tail", wraps=capture.bounded_tail) as tail:
                    status, raw = capture.command_output([sys.executable, "-c",
                        "print('old line\\n' * 100); print('recent trigger')"], root / "raw", capture.time.monotonic() + 5)
                self.assertLessEqual(len(tail.call_args.args[0]), 100, "stream retention must remain bounded before final projection")
                self.assertEqual(status, "captured")
                self.assertTrue(raw.startswith(capture.TRUNCATED))
                self.assertTrue(raw.endswith(b"recent trigger\n"))
                self.assertLessEqual(len(raw), 100)
                self.assertTrue(all(line in {b"old line", b"", b"recent trigger"}
                                    for line in raw[len(capture.TRUNCATED):].splitlines()))
                status, raw = capture.command_output([sys.executable, "-c",
                    "print('10 1 S 0 00:10 launchd_sim'); "
                    "print('99 1 S 0 00:01 unrelated\\n' * 100); print('11 10 R 5 00:01 immichSlides')"],
                    root / "raw", capture.time.monotonic() + 5, process_root=10)
                self.assertEqual(status, "captured")
                self.assertIn(b"11 10 R 5.0 00:01 immichSlides", raw)
                self.assertNotIn(b"unrelated", raw)

    def test_split_log_lines_and_final_remainder_preserve_method_deduplication(self):
        import ci_xctest_lifecycle as capture
        import threading
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "xcode.log"
            log.write_text("Test Ca")
            seen = threading.Event()
            observe = capture.Trigger.observe
            def observed(trigger, line, now):
                answer = observe(trigger, line, now)
                if answer:
                    seen.set()
                return answer
            with patch.object(capture.Trigger, "observe", observed), patch.object(capture, "capture",
                    side_effect=lambda *args, **kwargs: (capture.empty_capture(args[3]), args[5])) as operation:
                with capture.monitor_invocation(["test-without-building"], log, "target", root / "public"):
                    with log.open("a") as output:
                        output.write("se '-[Flow testA]' started.\nFailed to get matching snap")
                    self.assertFalse(seen.wait(0.15))
                    with log.open("a") as output:
                        output.write("shot\nTest Case '-[Flow testB]' started.\nFailed to terminate app")
                    self.assertTrue(seen.wait(1))
                self.assertEqual(operation.call_count, 2)

    def test_low_invocation_budget_skips_capture_and_shutdown_records_a_bounded_join_timeout(self):
        import ci_xctest_lifecycle as capture
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            monitor = capture.Monitor(root / "log", "target", root / "public", deadline=19)
            monitor.requests.put_nowait(("native-failure", 0, None))
            monitor.requests.put_nowait(None)
            with patch.object(capture.time, "monotonic", return_value=0), patch.object(capture, "capture") as operation:
                monitor.collect_requests()
            operation.assert_not_called()
            self.assertEqual(set(monitor.payload["captures"][0]["status"].values()), {"skipped"})
            admitted = capture.Monitor(root / "log", "target", root / "admitted", deadline=20)
            admitted.requests.put_nowait(("native-failure", 0, None))
            admitted.requests.put_nowait(None)
            with patch.object(capture.time, "monotonic", return_value=0), \
                    patch.object(capture, "capture", return_value=(capture.empty_capture("native-failure"), 0)) as operation:
                admitted.collect_requests()
            self.assertEqual(operation.call_args.kwargs["deadline"], 20)
            with patch.object(capture, "Monitor", return_value=monitor), \
                    patch.object(monitor.thread, "start"), patch.object(monitor.thread, "join") as join, \
                    patch.object(monitor.thread, "is_alive", return_value=True):
                with capture.monitor_invocation(["test-without-building"], root / "log", "target", root / "public"):
                    pass
            join.assert_called_once_with(timeout=capture.JOIN_TIMEOUT_SECONDS)
            self.assertLessEqual(capture.JOIN_TIMEOUT_SECONDS, 70)
            self.assertEqual(json.loads((root / "public/summary.json").read_text())["monitor_status"], "timeout")
            monitor.log.write_text("")
            with patch.object(monitor.worker, "start"), patch.object(monitor.worker, "join") as join, \
                    patch.object(monitor.worker, "is_alive", return_value=True), \
                    patch.object(monitor, "mark_join_timeout", wraps=monitor.mark_join_timeout) as timeout:
                monitor.watch()
            join.assert_called_once_with(timeout=capture.JOIN_TIMEOUT_SECONDS)
            timeout.assert_called_once_with()

    def test_activity_capture_is_released_by_native_failure_and_reader_stop_is_a_fixed_boundary(self):
        import ci_xctest_lifecycle as capture
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            monitor = capture.Monitor(root / "log", "target", root / "public")
            with patch.object(capture.time, "monotonic", side_effect=[0, 0, 15, 16]):
                monitor.observe("Test Case '-[Flow testA]' started.")
                monitor.observe("t = 0.0s     Launch com.331works.immichSlides")
                monitor.observe("")
                request = monitor.requests.get_nowait()
                self.assertFalse(request[2].is_set())
                monitor.observe("Failed to get matching snapshot")
                self.assertTrue(request[2].is_set())
                self.assertTrue(monitor.requests.empty(), "the native failure must release the same capture")
            monitor.log.write_text("one line\n")
            monitor.stopped.set()
            def growing(_line):
                with monitor.log.open("a") as log:
                    log.write("another line\n")
            with patch.object(monitor, "observe", side_effect=growing) as observe:
                monitor.watch()
            observe.assert_called_once_with("one line")
            self.assertTrue(request[2].is_set())

    def test_idle_reader_observes_a_pending_launch_without_another_output_line(self):
        import ci_xctest_lifecycle as capture
        import threading
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "log"
            log.write_text("Test Case '-[Flow testA]' started.\nt = 0.0s     Launch com.331works.immichSlides\n")
            monitor = capture.Monitor(log, "target", root / "public")
            idle, captured, clock = threading.Event(), threading.Event(), [0]
            wait = monitor.stopped.wait
            def pause(_timeout):
                idle.set()
                return wait(0.05)
            def collect(*args, **kwargs):
                captured.set()
                return capture.empty_capture(args[3]), args[5]
            try:
                with patch.object(monitor.stopped, "wait", side_effect=pause), \
                        patch.object(capture.time, "monotonic", side_effect=lambda: clock[0]), \
                        patch.object(capture, "capture", side_effect=collect):
                    monitor.thread.start()
                    self.assertTrue(idle.wait(1))
                    clock[0] = 15
                    self.assertTrue(captured.wait(1), "an idle log must still trigger the launch deadline")
                    monitor.stopped.set()
                    monitor.thread.join(timeout=2)
                self.assertFalse(monitor.thread.is_alive())
            finally:
                monitor.stopped.set()
                monitor.thread.join(timeout=2)

    def test_collector_defers_expensive_tools_until_native_failure_or_exit_and_saves_incrementally(self):
        import ci_xctest_lifecycle as capture
        for released in (False, True, "later"):
            with self.subTest(released=released), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                release = root / "release"
                if released is True:
                    release.touch()
                clock, calls = [0], []
                def command(argv, _path, deadline, **kwargs):
                    self.assertEqual(deadline, 10)
                    calls.append(argv)
                    if "managerpid" in argv:
                        return "captured", b"10\n"
                    if "/bin/ps" in argv:
                        return "captured", b"pid ppid state cpu elapsed name\n10 1 S 0 00:10 launchd_sim\n11 10 S 0 00:01 immichSlides\n"
                    self.assertEqual(json.loads((root / "summary.json").read_text())["captures"][0]["status"]["processes"],
                                     "captured", "process evidence must survive a later tool failure")
                    return "captured", b"synthetic log"
                def wait(_seconds):
                    if released == "later":
                        release.touch()
                    else:
                        clock[0] = 10
                with patch.object(capture, "command_output", side_effect=command), \
                        patch.object(capture.time, "monotonic", side_effect=lambda: clock[0]), \
                        patch.object(capture.time, "sleep", side_effect=wait), \
                        patch.object(capture, "crash_reports", return_value=iter([])):
                    capture.collect("target", 0, root, "activity-timeout", 10, release)
                record = json.loads((root / "summary.json").read_text())["captures"][0]
                self.assertEqual(record["status"]["processes"], "captured")
                self.assertEqual(record["status"]["simulator_log"], "captured" if released else "skipped")
                self.assertEqual(any("/usr/bin/sample" in call for call in calls), bool(released))
                self.assertTrue(all(call[:3] == ["/usr/bin/nice", "-n", "10"] for call in calls))
                if released:
                    self.assertIn("60s", next(call for call in calls if "show" in call))

    def test_crash_traversal_stops_at_deadline_and_publication_omits_oversize_and_duplicates(self):
        import ci_xctest_lifecycle as capture
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(capture.time, "monotonic", return_value=10), patch.object(Path, "rglob", return_value=iter([root])):
                with self.assertRaises(TimeoutError):
                    list(capture.crash_reports(root, "target", 0, deadline=10))
            record = capture.empty_capture("native-failure")
            self.assertEqual(capture.publish_file(root, record, "crash_reports", "large.ips",
                b"x" * (capture.MAX_FILE_BYTES + 1), 0), 0)
            self.assertFalse((root / "large.ips").exists())
            self.assertEqual(record["status"]["crash_reports"], "oversized")
            with patch.object(capture, "normalize", return_value=b"small"):
                capture.publish_file(root, record, "crash_reports", "shrunken.ips", b"x" * (capture.MAX_FILE_BYTES + 1), 0)
            self.assertFalse((root / "shrunken.ips").exists())
            with patch.object(capture, "normalize", return_value=b"x" * (capture.MAX_FILE_BYTES + 1)):
                capture.publish_file(root, record, "crash_reports", "expanded.ips", b"small", 0)
            self.assertFalse((root / "expanded.ips").exists())
            seen = set()
            record = capture.empty_capture("native-failure")
            total = capture.publish_file(root, record, "crash_reports", "first.ips", b"synthetic crash", 0, seen)
            next_record = capture.empty_capture("native-failure")
            self.assertEqual(capture.publish_file(root, next_record, "crash_reports", "second.ips", b"synthetic crash", total, seen), total)
            self.assertEqual(next_record["status"]["crash_reports"], "duplicate")
            self.assertFalse((root / "second.ips").exists())

    def test_live_trigger_deduplicates_methods_and_bounds_invocations(self):
        from ci_xctest_lifecycle import Trigger
        trigger = Trigger()
        failures = ("Failed to terminate app", "Failed to get matching snapshots", "Timed out while evaluating UI query", "Test crashed")
        self.assertIsNone(trigger.observe("ordinary assertion failed", 0))
        self.assertIsNone(trigger.observe("crashedly", 0))
        for failure in failures:
            self.assertEqual(Trigger().observe(failure, 0), "native-failure")
        for index, failure in enumerate(failures):
            trigger.observe(f"Test Case '-[Flow test{index}]' started.", index)
            self.assertEqual(trigger.observe(failure, index), "native-failure" if index < 3 else None)
            self.assertIsNone(trigger.observe(failure, index))

    def test_launch_watch_expires_only_while_the_activity_is_pending(self):
        from ci_xctest_lifecycle import Trigger, ACTIVITY_TIMEOUT_SECONDS
        for action in ("Launch", "Terminate"):
            for completion in (None, "t = 1.0s     Find the Application", "Test Case '-[Flow testA]' passed."):
                with self.subTest(action=action, completion=completion):
                    trigger = Trigger()
                    trigger.observe("Test Case '-[Flow testA]' started.", 0)
                    trigger.observe(f"t = 0.0s     {action} com.331works.immichSlides", 0)
                    trigger.observe("t = 0.1s         Waiting for accessibility", 0.1)
                    self.assertIsNone(trigger.observe("", ACTIVITY_TIMEOUT_SECONDS - 0.01))
                    if completion:
                        trigger.observe(completion, 1)
                    self.assertEqual(trigger.observe("", ACTIVITY_TIMEOUT_SECONDS), "activity-timeout" if completion is None else None)

    def test_process_projection_excludes_other_simulators_and_argv(self):
        from ci_xctest_lifecycle import process_state
        raw = ("10 1 S 0.0 00:10 /runtime/launchd_sim\n11 10 R 99.0 00:09 /app/immichSlides\n"
               "12 10 S 0.0 00:09 /runtime/SpringBoard\n13 10 S 0.0 00:09 /runtime/ReportCrash\n"
               "14 10 S 0.0 00:09 /runtime/testmanagerd\n15 10 S 0.0 00:09 /runtime/unrelated\n"
               "21 20 R 90.0 00:09 /other/immichSlides\n")
        text, pid = process_state(raw, 10)
        self.assertEqual(pid, 11)
        self.assertEqual(len(text.splitlines()), 6)
        self.assertNotIn("21", text)
        self.assertNotIn("/runtime/", text)
        self.assertNotIn("unrelated", text)
        for invalid in ("broken", raw.replace("99.0", "nan"), raw.replace("10 1 S", "20 1 S")):
            with self.assertRaises(ValueError):
                process_state(invalid, 10)
        self.assertIsNone(process_state(raw.replace("/app/immichSlides", "/app/other"), 10)[1])

    def test_files_are_normalized_scanned_and_bounded_before_publication(self):
        import ci_xctest_lifecycle as capture
        from strict_e2e_server import PUBLIC_API_KEY
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = capture.empty_capture("native-failure")
            total = 0
            for number, (data, expected) in enumerate(((b"/" + b"Users/synthetic/file\n", "captured"),
                    (PUBLIC_API_KEY.encode(), "withheld"), (b"x\n" * capture.MAX_FILE_BYTES, "captured"))):
                total = capture.publish_file(root, record, "simulator_log", f"log-{number}.txt", data, total)
                self.assertEqual(record["status"]["simulator_log"], expected)
            self.assertNotIn(b"/Users/", (root / "log-0.txt").read_bytes())
            self.assertFalse((root / "log-1.txt").exists())
            self.assertTrue((root / "log-2.txt").read_bytes().startswith(capture.TRUNCATED))
            self.assertLessEqual((root / "log-2.txt").stat().st_size, 256 * 1024)
            before = total
            self.assertEqual(capture.publish_file(root, record, "app_sample", "full.txt", b"extra", capture.MAX_TOTAL_BYTES), capture.MAX_TOTAL_BYTES)
            self.assertFalse((root / "full.txt").exists())
            self.assertEqual(record["status"]["app_sample"], "budget-exhausted")
            self.assertEqual(total, before)
            with patch.object(capture, "scan_bytes", side_effect=OSError("scan failed")):
                capture.publish_file(root, record, "processes", "scan.txt", b"safe", total)
            self.assertEqual(record["status"]["processes"], "withheld")
            self.assertFalse((root / "scan.txt").exists())
            capture.publish_file(root, record, "processes", "empty.txt", b"", total)
            self.assertEqual(record["status"]["processes"], "withheld")
            self.assertFalse((root / "empty.txt").exists())
            record = capture.empty_capture("native-failure")
            total = 0
            for index in range(5):
                total = capture.publish_file(root, record, "crash_reports", f"crash-{index}.ips", b"x" * (256 * 1024), total)
            self.assertEqual(total, 1024 * 1024)
            self.assertEqual(len(record["files"]), 4)
            self.assertEqual(record["status"]["crash_reports"], "budget-exhausted")
            self.assertFalse((root / "crash-4.ips").exists())

    def test_simulator_crash_folders_use_the_invocation_baseline_and_device_scope(self):
        import ci_xctest_lifecycle as capture
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            device = "AAAAAAAA-0000-0000-0000-000000000001"
            own = home / "Library/Developer/CoreSimulator/Devices" / device / "data/Library/Logs/CrashReporter"
            host = home / "Library/Logs/DiagnosticReports"
            other = own.parents[4] / "other/data/Library/Logs/CrashReporter"
            for folder in (own, host, other):
                folder.mkdir(parents=True)
            for folder, name, content, stamp in ((own, "SpringBoard-new.ips", "synthetic crash", 11),
                    (own, "immichSlides-old.ips", "old crash", 9), (host, "immichSlides-new.ips", device, 11),
                    (host, "immichSlides-other.ips", "other-device", 11), (other, "immichSlides-other.ips", device, 11),
                    (own, "unrelated.ips", "irrelevant", 11)):
                path = folder / name
                path.write_text(content)
                os.utime(path, (stamp, stamp))
            own.joinpath("ReportCrash-link.ips").symlink_to(host / "immichSlides-new.ips")
            reports = list(capture.crash_reports(home, device, 10))
            self.assertEqual({path.name for path in reports}, {"SpringBoard-new.ips", "immichSlides-new.ips"})
            for index in range(7):
                path = own / f"immichSlides-burst-{index}.ips"
                path.write_text("synthetic")
                os.utime(path, (11, 11))
            self.assertEqual(len(list(capture.crash_reports(home, device, 10))), 5)

    def test_capture_commands_share_one_deadline_and_fail_without_changing_verdicts(self):
        import ci_xctest_lifecycle as capture
        import sys
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command = [sys.executable, "-c", "print('synthetic output', end='')"]
            with patch.object(capture.time, "monotonic", return_value=5):
                self.assertEqual(capture.command_output(command, root / "raw", 10), ("captured", b"synthetic output"))
                self.assertEqual(capture.command_output(["synthetic"], root / "raw", 5), ("timeout", b""))
            for failure, status in ((subprocess.TimeoutExpired("synthetic", 1), "timeout"), (OSError(), "unavailable")):
                with patch.object(capture.subprocess, "Popen", side_effect=failure):
                    self.assertEqual(capture.command_output(["synthetic"], root / "raw", float("inf")), (status, b""))
            for script in ("print('failed output'); raise SystemExit(2)", "pass"):
                self.assertEqual(capture.command_output([sys.executable, "-c", script], root / "raw", float("inf")), ("unavailable", b""))
            for script in ("import time; time.sleep(1)", "import os,time; os.close(1); time.sleep(1)"):
                self.assertEqual(capture.command_output([sys.executable, "-c", script],
                    root / "raw", capture.time.monotonic() + 0.05), ("timeout", b""))

    def test_stream_closes_pipes_and_reaps_unusable_process_output(self):
        import ci_xctest_lifecycle as capture
        import sys
        launch, children = capture.subprocess.Popen, []
        def launched(*args, **kwargs):
            process = launch(*args, **kwargs)
            children.append(process)
            return process
        try:
            with tempfile.TemporaryDirectory() as directory, patch.object(capture.subprocess, "Popen", side_effect=launched):
                root = Path(directory)
                for script, expected, process_root in (
                        ("print('safe')", "captured", None),
                        ("import os,time; os.close(1); time.sleep(1)", "timeout", None),
                        ("import time; print('bad\\n' * 100001, flush=True); time.sleep(1)", "unavailable", 10),
                        ("print('10 1 S 0 00:10 launchd_sim'); "
                         "[print(f'{p} 10 S 0 00:01 immichSlides') for p in range(11, 30)]", "unavailable", 10)):
                    with self.subTest(expected=expected, process_root=process_root), patch.object(capture, "MAX_FILE_BYTES", 256):
                        status, _ = capture.command_output([sys.executable, "-c", script], root / "raw",
                            capture.time.monotonic() + 0.2, process_root=process_root)
                        self.assertEqual(status, expected)
                        self.assertIsNotNone(children[-1].poll(), "every command must be reaped")
                        self.assertTrue(children[-1].stdout.closed, "repeated captures must not leak pipes")
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.wait()
                child.stdout.close()

    def test_summary_has_only_closed_statuses_and_publishes_without_a_screenshot(self):
        import ci_xctest_lifecycle as capture
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertFalse(capture.prepare_publication(root))
            record = capture.empty_capture("native-failure")
            capture.publish_file(root, record, "processes", "processes.txt", b"pid ppid state cpu elapsed name\n", 0)
            payload = {"schema_version": 1, "captures": [record]}
            capture.write_summary(root, payload)
            self.assertTrue(capture.prepare_publication(root))
            for field in capture.KINDS:
                self.assertIn(record["status"][field], capture.STATUSES)
            for change in ({"extra": "private"}, {"status": {"processes": "arbitrary"}}, {"trigger": "private text"}):
                invalid = copy.deepcopy(payload)
                invalid["captures"][0].update(change)
                with self.assertRaises(ValueError):
                    capture.validate_summary(invalid)
            for change in ({"schema_version": 2}, {"schema_version": True}, {"captures": [record] * 4},
                           {"extra": "private"}, {"monitor_status": "arbitrary"}):
                with self.assertRaises(ValueError):
                    capture.validate_summary({**payload, **change})
            for item in ({"kind": "unknown", "name": "processes.txt"}, {"kind": "processes", "name": "../escape.txt"},
                         {"kind": "processes", "name": "private.json"}, {"kind": "processes", "name": "safe.txt", "extra": 1}):
                invalid = copy.deepcopy(payload)
                invalid["captures"][0]["files"] = [item]
                with self.assertRaises(ValueError):
                    capture.validate_summary(invalid)
            invalid = copy.deepcopy(payload)
            invalid["captures"][0]["files"] *= 2
            with self.assertRaises(ValueError):
                capture.validate_summary(invalid)
            (root / "processes.txt").write_bytes(__import__("strict_e2e_server").PUBLIC_API_KEY.encode())
            self.assertTrue(capture.prepare_publication(root))
            self.assertEqual(json.loads((root / "summary.json").read_text())["captures"][0]["status"]["processes"], "withheld")
            self.assertFalse((root / "processes.txt").exists())

    def test_capture_projects_each_source_and_preserves_unavailable_or_timeout_status(self):
        import ci_xctest_lifecycle as capture
        raw = b"pid ppid state cpu elapsed name\n10 1 S 0 00:10 launchd_sim\n11 10 R 99 00:01 immichSlides\n"
        for failure in (None, "manager", "ps", "missing-app", "bad-ps", "log", "crash-deadline", "crash-traversal", "crash-io"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                crash = root / "new.ips"
                crash.write_text("synthetic crash")
                calls = []
                clock = [0]
                def command(argv, _path, _deadline, **kwargs):
                    calls.append(argv)
                    if "managerpid" in argv:
                        return ("timeout", b"") if failure == "manager" else ("captured", b"10\n")
                    if "/bin/ps" in argv:
                        return (("unavailable", b"") if failure == "ps" else
                                ("captured", b"bad") if failure == "bad-ps" else
                                ("captured", raw.replace(b"immichSlides", b"other") if failure == "missing-app" else raw))
                    if "show" in argv:
                        if failure == "crash-deadline":
                            clock[0] = 100
                        return ("timeout", b"") if failure == "log" else ("captured", b"synthetic log")
                    return "captured", b"synthetic main-thread stack"
                with patch.object(capture, "command_output", side_effect=command), \
                        patch.object(capture, "crash_reports", side_effect=(OSError() if failure == "crash-io" else
                                     TimeoutError() if failure == "crash-traversal" else None),
                                     return_value=iter([crash])), \
                        patch.object(capture.time, "monotonic", side_effect=lambda: clock[0]):
                    capture.collect("target", 0, root, "native-failure", 18)
                record = json.loads((root / "summary.json").read_text())["captures"][0]
                expected_process = "timeout" if failure == "manager" else "unavailable" if failure in {"ps", "bad-ps"} else "captured"
                self.assertEqual(record["status"]["processes"], expected_process)
                self.assertEqual(record["status"]["app_sample"], "unavailable" if failure in {"manager", "ps", "bad-ps", "missing-app"} else "captured")
                self.assertEqual(record["status"]["simulator_log"], "timeout" if failure == "log" else "captured")
                self.assertEqual((root / "simulator.log").exists(), failure != "log")
                self.assertEqual(record["status"]["crash_reports"], "timeout" if failure in {"crash-deadline", "crash-traversal"} else "unavailable" if failure == "crash-io" else "captured")
                log = next(call for call in calls if "show" in call)
                self.assertEqual(log[:11], ["/usr/bin/nice", "-n", "10", "xcrun", "simctl", "spawn", "target", "log", "show", "--last", "60s"])
                self.assertIn("XCTest", log[-1])
                self.assertIn("RunningBoard", log[-1])
                self.assertEqual(log[-1].count("CONTAINS[c]"), 3)
                if failure not in {"manager", "ps", "bad-ps", "missing-app"}:
                    self.assertIn(["/usr/bin/nice", "-n", "10", "/usr/bin/sample", "11", "1", "10", "-file", "/dev/stdout"], calls)

    def test_capture_watchdog_reaps_the_group_and_bounds_total_published_bytes(self):
        import ci_xctest_lifecycle as capture
        from types import SimpleNamespace
        import threading
        for outcome in ("captured", "timeout", "nonzero", "copy-timeout", "full", "missing-summary", "parent-deadline", "activity", "activity-later"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                clock = [0]
                def launch(argv, **kwargs):
                    self.assertTrue(kwargs["start_new_session"])
                    private = Path(argv[-4])
                    self.assertEqual(float(argv[-2]), 9 if outcome == "parent-deadline" else 19)
                    self.assertEqual(argv[-1], str(private / "release") if outcome.startswith("activity") else "")
                    record = capture.empty_capture("native-failure")
                    record["status"]["app_sample"] = "withheld"
                    capture.publish_file(private, record, "processes", "processes.txt", b"synthetic", 0)
                    if outcome != "missing-summary":
                        capture.write_summary(private, {"schema_version": 1, "captures": [record]})
                    def wait(timeout):
                        self.assertLessEqual(timeout, 20)
                        if not killed:
                            self.assertEqual(timeout, 0.1 if outcome.startswith("activity") else 9 if outcome == "parent-deadline" else 19)
                        if outcome == "activity-later" and not release.is_set():
                            release.set()
                            raise subprocess.TimeoutExpired(argv, timeout)
                        if outcome.startswith("activity"):
                            self.assertTrue(Path(argv[-1]).exists(), "native failure must release the deferred collector")
                        if outcome == "timeout" and not killed:
                            raise subprocess.TimeoutExpired(argv, timeout)
                        if outcome == "copy-timeout":
                            clock[0] = 21
                        return 1 if outcome in {"nonzero", "missing-summary"} else 0
                    return SimpleNamespace(pid=123, wait=wait)
                killed = []
                before = capture.MAX_TOTAL_BYTES if outcome == "full" else 0
                with patch.object(capture.subprocess, "Popen", side_effect=launch), \
                        patch.object(capture.os, "killpg", side_effect=lambda *args: killed.append(args)), \
                        patch.object(capture.time, "monotonic", side_effect=lambda: clock[0]):
                    release = threading.Event() if outcome.startswith("activity") else None
                    if outcome == "activity":
                        release.set()
                    record, total = capture.capture("target", 10, Path(directory), "native-failure", 2, before,
                        deadline=10 if outcome == "parent-deadline" else None, release=release)
                expected = {"captured": "captured", "timeout": "captured", "nonzero": "captured", "copy-timeout": "timeout",
                            "full": "budget-exhausted", "missing-summary": "unavailable", "parent-deadline": "captured",
                            "activity": "captured", "activity-later": "captured"}[outcome]
                self.assertEqual(record["status"]["processes"], expected)
                self.assertEqual(total, len(b"synthetic") if outcome in {"captured", "timeout", "nonzero", "parent-deadline", "activity", "activity-later"} else before)
                if outcome != "missing-summary":
                    self.assertEqual(record["status"]["app_sample"], "withheld")
                    self.assertEqual(record["status"]["crash_reports"], "timeout" if outcome == "timeout" else "unavailable")
                self.assertEqual(bool(killed), outcome == "timeout")
                if outcome == "captured":
                    self.assertEqual((Path(directory) / "capture-2-processes.txt").read_bytes(), b"synthetic")

    def test_collector_entry_passes_the_absolute_parent_deadline_and_optional_release(self):
        import ci_xctest_lifecycle as capture
        for release in ("", "/synthetic/release"):
            with patch.object(capture, "collect") as collect:
                capture.main(["target", "1", "/synthetic/capture", "activity-timeout", "20", release])
            collect.assert_called_once_with("target", 1, Path("/synthetic/capture"), "activity-timeout", 20,
                                            Path(release) if release else None)

    def test_live_monitor_captures_before_returning_and_never_changes_the_test_exit(self):
        import ci_xctest_lifecycle as capture
        for command in (["xcodebuild", "build-for-testing"], ["xcodebuild", "test-without-building", "-enumerate-tests"],
                        ["xcodebuild", "test-without-building"]):
            for broken in (False, True):
                with self.subTest(command=command, broken=broken), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    log, destination = root / "xcode.log", root / "public"
                    log.write_text("Test Case '-[Flow testA]' started.\nFailed to get matching snapshot\n")
                    record = capture.empty_capture("native-failure")
                    with patch.object(capture, "capture", side_effect=OSError() if broken else None, return_value=(record, 0)) as operation:
                        with self.assertRaisesRegex(RuntimeError, "original test exit"), \
                                capture.monitor_invocation(command, log, "target", destination):
                            raise RuntimeError("original test exit")
                        active = "test-without-building" in command and "-enumerate-tests" not in command
                        self.assertEqual(operation.call_count, int(active))
                    self.assertEqual((destination / "summary.json").exists(), active)
                    if active:
                        self.assertEqual(json.loads((destination / "summary.json").read_text()).get("monitor_status", "complete"), "complete")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            monitor = capture.Monitor(root / "missing.log", "target", root)
            monitor.watch()
            self.assertEqual(monitor.payload["captures"], [])
            with patch.object(capture, "Monitor", side_effect=OSError()):
                with capture.monitor_invocation(["test-without-building"], root / "log", "target", root):
                    pass

    def test_upload_recheck_drops_invalid_optional_evidence_and_unlisted_files(self):
        import ci_xctest_lifecycle as capture
        for refused in ("oversize", "symlink", "total", "invalid-summary", "extra"):
            with self.subTest(refused=refused), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "public"
                record = capture.empty_capture("native-failure")
                capture.publish_file(root, record, "processes", "processes.txt", b"safe", 0)
                capture.write_summary(root, {"schema_version": 1, "captures": [record]})
                path = root / "processes.txt"
                if refused == "oversize":
                    path.write_bytes(b"x" * (capture.MAX_FILE_BYTES + 1))
                elif refused == "symlink":
                    path.unlink()
                    path.symlink_to(Path(directory) / "absent")
                elif refused == "invalid-summary":
                    (root / "summary.json").write_text("invalid")
                elif refused == "extra":
                    (root / "unlisted.txt").write_text("private")
                with patch.object(capture, "MAX_TOTAL_BYTES", 1 if refused == "total" else capture.MAX_TOTAL_BYTES):
                    self.assertEqual(capture.prepare_publication(root), refused != "invalid-summary")
                if refused in {"oversize", "symlink", "total"}:
                    self.assertFalse(path.exists())
                    self.assertEqual(json.loads((root / "summary.json").read_text())["captures"][0]["status"]["processes"],
                                     "budget-exhausted" if refused == "total" else "withheld")
                if refused == "extra":
                    self.assertFalse((root / "unlisted.txt").exists())

    def test_queued_capture_lags_are_closed_and_include_time_waiting_for_the_prior_capture(self):
        import ci_xctest_lifecycle as capture
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            monitor = capture.Monitor(root / "log", "target", root / "public")
            for request in (("native-failure", 10, None), ("activity-timeout", 11, None), None):
                monitor.requests.put_nowait(request)
            with patch.object(capture.time, "monotonic", side_effect=[12, 15, 20, 25]), \
                    patch.object(capture, "capture", side_effect=[(capture.empty_capture("native-failure"), 0),
                                                                (capture.empty_capture("activity-timeout"), 0)]):
                monitor.collect_requests()
            records = json.loads((root / "public/summary.json").read_text())["captures"]
            self.assertEqual([(record["trigger_to_capture_start_seconds"], record["trigger_to_capture_end_seconds"])
                              for record in records], [(2, 5), (9, 14)])
            for start, end in ((-1, 1), (1, -1), (2, 1), (None, 1), (1, None), (True, 1), (float("nan"), 1), (1, float("inf"))):
                invalid = copy.deepcopy(monitor.payload)
                invalid["captures"][0].update(trigger_to_capture_start_seconds=start, trigger_to_capture_end_seconds=end)
                with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                    capture.validate_summary(invalid)
            failed_write = capture.Monitor(root / "log", "target", root / "unavailable")
            failed_write.requests.put_nowait(("native-failure", 10, None))
            failed_write.requests.put_nowait(None)
            with patch.object(capture.time, "monotonic", side_effect=[12, 15]), \
                    patch.object(capture, "capture", return_value=(capture.empty_capture("native-failure"), 0)), \
                    patch.object(capture, "write_summary", side_effect=OSError("receipt unavailable")):
                failed_write.collect_requests()
            self.assertEqual(failed_write.payload["captures"][0]["trigger_to_capture_end_seconds"], 5)

    def test_live_output_keeps_observing_triggers_while_an_earlier_capture_is_running(self):
        import ci_xctest_lifecycle as capture
        import threading
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "xcode.log"
            log.write_text("Test Case '-[Flow testA]' started.\nFailed to get matching snapshot\n")
            started, second_seen, release, second_finished = (threading.Event() for _ in range(4))
            observe = capture.Trigger.observe
            def observed(trigger, line, now):
                reason = observe(trigger, line, now)
                if reason and trigger.case == 2:
                    second_seen.set()
                return reason
            def collect(_udid, _baseline, _destination, reason, number, total, **kwargs):
                if number == 1:
                    started.set()
                    self.assertTrue(release.wait(2), "the reader must keep observing while capture is blocked")
                else:
                    second_finished.set()
                return capture.empty_capture(reason), total
            try:
                with patch.object(capture.Trigger, "observe", observed), patch.object(capture, "capture", side_effect=collect) as operation:
                    with capture.monitor_invocation(["xcodebuild", "test-without-building"], log, "target", root / "public"):
                        self.assertTrue(started.wait(1), "capture must start before invocation end")
                        with log.open("a") as output:
                            output.write("Test Case '-[Flow testB]' started.\nFailed to terminate app\n")
                        self.assertTrue(second_seen.wait(1), "live observation must not wait for a previous capture")
                        release.set()
                    self.assertTrue(second_finished.is_set(), "all queued captures must finish before runner return")
                    self.assertEqual(operation.call_count, 2)
            finally:
                release.set()

    def test_upload_includes_a_closed_lifecycle_receipt_without_any_image(self):
        import ci_ui_tests
        import ci_xctest_lifecycle as capture
        from test_ci_summary import hosted_v5_summary
        for present in (False, True):
            with self.subTest(present=present), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                summary, _ = hosted_v5_summary(ui=True, tool=True)
                (root / "summary.json").write_text(json.dumps(summary))
                if present:
                    record = capture.empty_capture("native-failure")
                    record["status"] = dict.fromkeys(capture.KINDS, "timeout")
                    capture.write_summary(root / "failure-screenshots/lifecycle/test", {"schema_version": 1, "captures": [record]})
                with patch.object(ci_ui_tests, "output") as outputs:
                    self.assertEqual(ci_ui_tests.main(["check-upload", "--output-dir", str(root)]), 0)
                outputs.assert_any_call("has_screenshots", str(present).lower())


class FixtureCoverageTests(unittest.TestCase):
    def test_nightly_retry_artifact_failures_use_the_original_tool_verdict(self):
        for phase, outcome, tool in (("failed-retry", "failed", True), ("export", "timed-out", True),
                                    ("disposal", "not-run", True), ("failed-retry-disposal", "failed", True),
                                    ("failed-retry-disposal", "not-run", False)):
            with self.subTest(phase=phase, tool=tool):
                self._assert_nightly_retry_artifact_failure(phase, outcome, tool=tool)

    def _assert_nightly_retry_artifact_failure(self, phase, outcome, *, tool):
        from types import SimpleNamespace
        from ci_flaky import ASSERTION_FAILURE
        from ci_summary import observation, parse_summary
        from test_ci_summary import hosted_v5_summary, first_failure_receipt
        from PIL import Image
        import ci_ui_tests

        seed, _ = hosted_v5_summary(ui=True, tool=tool)
        row = seed["population"]["observed"][0]
        identity = row["identity"]
        diagnostics = {key: row[key] for key in ("failure_phase", "failure_class")}
        first = observation(identity, "failed", 12, exit_code=65, reason=ASSERTION_FAILURE, failure_diagnostics=diagnostics)
        retry_failed = phase.startswith("failed-retry")
        second = observation(identity, "failed" if retry_failed else "passed", 9, exit_code=65 if retry_failed else 0)
        receipts, images = [], []
        for size, color in (((64, 32), "blue"), ((48, 24), "red")):
            pixels = io.BytesIO()
            Image.new("RGB", size, color).save(pixels, format="PNG")
            receipt = first_failure_receipt()
            receipt["screenshot"].update(width=size[0], height=size[1], bytes=len(pixels.getvalue()))
            receipts.append(receipt)
            images.append(pixels.getvalue())
        receipts[1]["step"] = "capture-frame"
        official = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": identity["key"] + "()",
            "result": "Failed", "durationInSeconds": 12, "failure_messages": row["failure_messages"], **diagnostics,
            "first_failure": receipts[0],
            "children": [{"nodeType": "Failure Message", "name": "failure"}]}]}
        retry_official = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": identity["key"] + "()",
            "result": "Failed" if retry_failed else "Passed", "durationInSeconds": 9,
            **({"first_failure": receipts[1]} if retry_failed else {})}]}
        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        inputs = {"hashes": seed["hashes"], "population": dict(seed["population"], compiled=[], observed=[]),
            "policy": policy, "discovery_policy": policy, "deselections": [], "registry": {"schema_version": 1, "entries": []},
            "registry_revision": "b" * 40}
        inputs["hashes"]["policies"]["known-flaky"] = "f" * 64
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            root, output = Path(directory, "checkout"), Path(directory, "output")
            source = root / "Products/app.xctestrun"
            (source.parent / "Debug-iphonesimulator/immichSlides.app").mkdir(parents=True)
            source.touch()
            bundles = [Path(directory, f"private/attempt-{i}/test.xcresult") for i in (1, 2)]
            for bundle in bundles:
                bundle.mkdir(parents=True)
            def process(command, **_kwargs):
                if "-enumerate-tests" in command:
                    enumeration = {"errors": [], "values": [{"enabledTests": [
                        {"identifier": "immichSlidesUITests/" + identity["key"]}]}]}
                    Path(command[command.index("-test-enumeration-output-path") + 1]).write_text(json.dumps(enumeration))
                    return SimpleNamespace(wait=lambda **_kwargs: 0, pid=42)
                first_run = str(bundles[0]) in command
                return SimpleNamespace(wait=lambda **_kwargs: 65 if first_run or retry_failed else 0, pid=42)
            def export(path, *_args, **kwargs):
                number = bundles.index(path)
                if number == 0 or retry_failed or phase == "export":
                    image = kwargs["first_failure_images"] / "0.png"
                    image.parent.mkdir(parents=True, exist_ok=True)
                    image.write_bytes(images[number])
                if path == bundles[1]:
                    if phase == "export":
                        raise subprocess.TimeoutExpired(["xcresulttool", "get"], 180)
                    (output / "official-tests-attempt-2.json").write_text(json.dumps(retry_official))
                else:
                    (output / "official-tests.json").write_text(json.dumps(official))
                return "f" * 64
            stack.enter_context(patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
                                                        "RUNNER_ENVIRONMENT": "github-hosted"}))
            stack.enter_context(patch("ci_flaky.nightly_retry_enabled", return_value=True))
            stack.enter_context(patch.object(runner, "ROOT", root))
            for name, value in (("run_identity", seed["identity"]), ("source_metadata", (".github/workflows/ci-nightly.yml", False)),
                    ("fixture_inputs", inputs), ("toolchain", seed["toolchain"]), ("prepare_simulator", None),
                    ("verify_simulator_device", None), ("verify_official_device", None), ("simulator_inventory", {}),
                    ("wait_for_service", ("127.0.0.1", 1234)), ("disk_check", None), ("check_products", None),
                    ("measure_signing", "adhoc"), ("prepare_test_run", source), ("reset_simulator_app", None),
                    ("crash_report_directories", []), ("crash_report_snapshot", {}), ("read_problem_reason", "fixture assertion"),
                    ("stop_exact_process", None), ("write_sensitive_scan", None)):
                stack.enter_context(patch.object(runner, name, return_value=value))
            stack.enter_context(patch.object(runner, "finalize_fixture_run", side_effect=lambda path, *_args, **_kwargs:
                ["Synthetic quarantine failure"] if phase.endswith("disposal") and path == bundles[1] else []))
            stack.enter_context(patch.object(runner, "prepare_fixture_result_bundle", side_effect=bundles))
            stack.enter_context(patch.object(runner, "read_xcode_observations", side_effect=[[first], [second]]))
            stack.enter_context(patch.object(runner, "export_private_result_bundle", side_effect=export))
            stack.enter_context(patch.object(runner.subprocess, "Popen", side_effect=process))
            lifecycle = stack.enter_context(patch.object(runner, "monitor_invocation", wraps=runner.monitor_invocation))
            stdout = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            code = runner.main(["--device", "iphone", "--destination", "platform=iOS Simulator,id=target",
                "--output-dir", str(output), "--xctestrun", str(source), "--shard", "navigation", "--mode", "measure",
                "--shard-manifest", str(root / "manifest.json"), "--total-timeout-minutes", "85"])
            self.assertTrue(lifecycle.called)
            self.assertTrue(all(call.args[0] == [] for call in lifecycle.call_args_list))
            actual = parse_summary((output / "summary.json").read_text())
            self.assertEqual((code, actual["infrastructure"]), (0 if tool else 65, []))
            observed = actual["population"]["observed"][0]
            self.assertEqual(observed["retry_failure"]["outcome"], outcome)
            self.assertEqual(tool, "environment_limit" in observed)
            self.assertNotIn("nightly_retry", observed)
            self.assertEqual(("failed", 12, 1), (observed["outcome"], observed["duration_seconds"], len(observed["attempts"])))
            self.assertEqual(receipts[0], observed["attempts"][0]["first_failure"])
            self.assertEqual("environment-limited" if tool else "failed",
                             json.loads((output / "coverage-verdict.json").read_text())["status"])
            if retry_failed and tool:
                self.assertEqual(receipts[1], observed["retry_failure"]["first_failure"])
            with patch.object(ci_ui_tests, "output"), contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(0, ci_ui_tests.main(["check-upload", "--output-dir", str(output)]), errors.getvalue())
            self.assertEqual(retry_failed and tool, (output / "failure-screenshots/first-failure-attempt-2/0.png").exists())
            if retry_failed and tool:
                retry_image = output / "failure-screenshots/first-failure-attempt-2/0.png"
                retry_image.write_bytes(images[0])
                with patch.object(ci_ui_tests, "output"), contextlib.redirect_stderr(io.StringIO()) as errors:
                    self.assertEqual(1, ci_ui_tests.main(["check-upload", "--output-dir", str(output)]))
                self.assertIn("first failure package image differs", errors.getvalue())
            self.assertEqual(tool, "Environment-limited XCTest tool" in stdout.getvalue())

    def test_nightly_retry_phase_problems_leave_the_first_ui_verdict(self):
        from datetime import date
        from ci_failure_diagnostics import failure_messages_diagnostics
        from ci_flaky import ASSERTION_FAILURE, run_xcode_attempts
        from ci_summary import observation
        from strict_e2e_runner_support import CommandError
        from test_ci_summary import hosted_v5_summary

        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        problems = {"reset": "not-run", "timeout": "timed-out", "read": "not-run", "nonzero-pass": "crashed"}
        for tool, problem in itertools.product((True, False), problems):
            with self.subTest(tool=tool, problem=problem):
                summary, _ = hosted_v5_summary(ui=True, tool=True)
                original = summary["population"]["observed"][0]
                identity = original["identity"]
                messages = original["failure_messages"] if tool else ["App timeline:"]
                diagnostics = failure_messages_diagnostics(messages)
                first = observation(identity, "failed", 12, reason=ASSERTION_FAILURE, exit_code=65,
                                    failure_diagnostics=diagnostics)
                def reset():
                    if problem == "reset":
                        raise CommandError("Synthetic retry reset failure")
                def execute(call):
                    return (65 if "-only-testing:immichSlidesUITests/" + identity["key"] not in call
                            else {"timeout": 124, "read": 0, "nonzero-pass": 1}[problem]), 9
                def read(path, _identify, _elapsed, _exit):
                    if path.name == "first.xcresult":
                        return [copy.deepcopy(first)]
                    if problem == "read":
                        raise ContractError("Synthetic retry export failure")
                    return [observation(identity, "passed", 9, exit_code=0)]
                result = run_xcode_attempts(["xcodebuild", "test-without-building", "-resultBundlePath", "first.xcresult"],
                    {"schema_version": 1, "entries": []}, tier="ui", environment="fixture", today=date(2026, 11, 11),
                    identity_for_key=lambda _: identity, reset=reset, execute=execute, read=read,
                    allocate_bundle=lambda: Path("retry/result.xcresult"), nightly_retry=True)
                summary["population"]["observed"] = result["observed"]
                summary["infrastructure"] = result["infrastructure"]
                official = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": identity["key"] + "()",
                    "result": "Failed", "durationInSeconds": 12, "failure_messages": messages, **diagnostics,
                    "children": [{"nodeType": "Failure Message", "name": "failure"}]}]}
                verdict, code = runner.finish_fixture_coverage(summary, official, [identity], policy,
                    exit_code=result["exit_code"], runner_hosted=True, nightly_retry=True)
                self.assertEqual((verdict["status"], code), ("environment-limited", 0) if tool else ("failed", 65))
                self.assertEqual(summary["infrastructure"], [])
                actual = summary["population"]["observed"][0]
                self.assertEqual((actual["outcome"], len(actual["attempts"]), actual["duration_seconds"]), ("failed", 1, 12))
                self.assertEqual(actual["retry_failure"]["outcome"], problems[problem])
                self.assertNotIn("nightly_retry", actual)

    def test_nightly_failed_retry_keeps_first_tool_yellow_and_other_failures_red(self):
        from ci_flaky import ASSERTION_FAILURE, merge_retry
        from ci_failure_diagnostics import failure_messages_diagnostics
        from ci_summary import observation, parse_summary
        from test_ci_summary import hosted_v5_summary

        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        for tool, retry_passed in ((True, False), (False, False), (True, True)):
            with self.subTest(tool=tool, retry_passed=retry_passed):
                summary, _ = hosted_v5_summary(ui=True, tool=True)
                original = summary["population"]["observed"][0]
                identity = original["identity"]
                messages = original["failure_messages"] if tool else ["App timeline:"]
                diagnostics = failure_messages_diagnostics(messages)
                first = observation(identity, "failed", 12, reason=ASSERTION_FAILURE, exit_code=65,
                                    failure_diagnostics=diagnostics)
                second = observation(identity, "passed" if retry_passed else "failed", 9,
                                     message=None if retry_passed else "raw retry text", exit_code=0 if retry_passed else 65)
                summary["population"]["observed"] = [merge_retry(first, second,
                    nightly_proof={"schema_version": 1, "policy_version": 1, "runner_hosted": True, "failed_case_count": 1})]
                official = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": identity["key"] + "()",
                    "result": "Failed", "durationInSeconds": 12, "failure_messages": messages, **diagnostics,
                    "children": [{"nodeType": "Failure Message", "name": "failure"}]}]}
                verdict, code = runner.finish_fixture_coverage(summary, official, [identity], policy,
                    exit_code=0 if retry_passed else 65, runner_hosted=True, nightly_retry=True)
                actual = parse_summary(summary)["population"]["observed"][0]
                self.assertEqual((verdict["status"], code), ("environment-limited", 0) if tool else ("failed", 65))
                if retry_passed:
                    self.assertEqual(actual["outcome"], "flaky-passed")
                    self.assertIn("nightly_retry", actual)
                    self.assertNotIn("environment_limit", actual)
                elif tool:
                    self.assertEqual(actual["environment_limit"]["failure_messages"], messages)
                    self.assertEqual((len(actual["attempts"]), actual["duration_seconds"]), (1, 12))
                    self.assertEqual(actual["retry_failure"]["exit_code"], 65)
                    self.assertIsNone(actual["retry_failure"]["message"])
                else:
                    self.assertNotIn("environment_limit", actual)
                    self.assertEqual(len(actual["attempts"]), 2)

    def test_nightly_tool_yellow_keeps_raw_failed_and_only_clean_complete_shards_exit_zero(self):
        from test_ci_summary import hosted_v5_summary
        from ci_summary import parse_summary
        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        for defect in (None, "bundle-prefix", "mixed", "retry", "too-many", "raw-count", "infrastructure", "timeout", "ci-ui", "not-hosted", "unknown-duration", "missing-official-duration"):
            with self.subTest(defect=defect):
                summary, _ = hosted_v5_summary(ui=True, tool=True)
                row = summary["population"]["observed"][0]
                messages = row["failure_messages"]
                if defect == "mixed":
                    messages.append("App timeline:")
                elif defect == "too-many":
                    messages *= 17
                elif defect == "retry":
                    row["attempts"].append(dict(row["attempts"][0], number=2))
                    row["duration_seconds"] *= 2
                elif defect == "infrastructure":
                    summary["infrastructure"].append({"code": "cleanup-failed", "message": "Synthetic cleanup failure"})
                elif defect == "ci-ui":
                    summary["source"]["workflow_path"] = ".github/workflows/ci-ui.yml"
                elif defect == "unknown-duration":
                    row["duration_seconds"] = row["attempts"][0]["duration_seconds"] = None
                from ci_failure_diagnostics import failure_messages_diagnostics
                node = {"nodeType": "Test Case", "nodeIdentifier": row["identity"]["key"] + "()", "result": "Failed",
                    "durationInSeconds": 12,
                    **failure_messages_diagnostics(messages),
                    "children": [{"nodeType": "Failure Message", "name": "failure"} for _ in messages]}
                if defect != "too-many":
                    node["failure_messages"] = messages
                if defect == "bundle-prefix":
                    node["nodeIdentifier"] = "immichSlidesUITests/" + node["nodeIdentifier"]
                if defect == "raw-count":
                    node["children"] = []
                if defect == "missing-official-duration":
                    node.pop("durationInSeconds")
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    verdict, code = runner.finish_fixture_coverage(summary, {"testNodes": [node]},
                        summary["population"]["declared"], policy, exit_code=124 if defect == "timeout" else 65,
                        runner_hosted=defect != "not-hosted")
                if defect in {"retry", "too-many"}:
                    self.assertNotIn("failure_messages", row)
                    self.assertTrue(all("failure_messages" not in attempt for attempt in row["attempts"]))
                yellow = defect in {None, "bundle-prefix"}
                self.assertEqual(0 if yellow else 124 if defect == "timeout" else 65, code)
                self.assertEqual("failed", summary["status"])
                parse_summary(summary)
                self.assertEqual("environment-limited" if yellow else "failed", verdict["status"])
                self.assertEqual(yellow, "environment_limit" in row)
                self.assertNotIn("::warning", output.getvalue(), "Coverage judgement must wait for runner finalization before publishing")

    def test_same_named_target_and_class_keeps_failure_identity_through_summary(self):
        from ci_failure_diagnostics import first_failure_environment, collect_first_failure_spool, attach_first_failures
        from ci_summary import observation, test_identity, write_summary, parse_summary
        from test_ci_summary import first_failure_receipt, valid_summary
        method = "testPlaybackSettingsBlocksFilteredModeWhenSelectionEmpty"
        key = "immichSlidesUITests/" + method
        identity = test_identity("ui", key, platform="ios")
        receipt = first_failure_receipt()
        receipt["screenshot"] = {"status": "unavailable", "width": None, "height": None, "bytes": None}
        for selector, official_key in itertools.product((key, "immichSlidesUITests/" + key), repeat=2):
            for defect in (None, "wrong-method", "wrong-attempt"):
                with self.subTest(selector=selector, official_key=official_key, defect=defect), tempfile.TemporaryDirectory() as raw:
                    root = Path(raw)
                    mapping = json.loads(first_failure_environment(root, [selector])["STRICT_E2E_FIRST_FAILURE_TESTS"])
                    # This is the Class/method key constructed from XCTestCase type and name in Swift.
                    swift_key = "/".join(("immichSlidesUITests", method))
                    self.assertEqual({swift_key: 0}, mapping)
                    (root / "0.json").write_text(json.dumps(receipt))
                    original = official_key + ("Other()" if defect == "wrong-method" else "()")
                    node = {"nodeType": "Test Case", "nodeIdentifier": original, "result": "Failed"}
                    collect_first_failure_spool(root, [selector], [node], root)
                    entry = observation(identity, "failed", 1, exit_code=65)
                    attach_first_failures([entry], {"testNodes": [node]}, 2 if defect == "wrong-attempt" else 1)
                    self.assertEqual(original, node["nodeIdentifier"])
                    summary = valid_summary()
                    summary["run"].update(tier="ui", job="ui-iphone")
                    summary["population"].update(declared=[identity], compiled=[identity], observed=[entry])
                    summary["status"] = "failed"
                    write_summary(summary, root)
                    entry = parse_summary((root / "summary.json").read_text())["population"]["observed"][0]
                    self.assertEqual(65, entry["attempts"][0]["exit_code"])
                    if defect is None:
                        self.assertEqual(receipt, entry["first_failure"])
                        self.assertEqual(receipt, entry["attempts"][0]["first_failure"])
                    else:
                        self.assertNotIn("first_failure", entry)

    def test_slow_official_result_steps_keep_phase_elapsed_and_missing_identities(self):
        from types import SimpleNamespace
        from ci_summary import parse_summary, test_identity
        from ci_verdict import parse_policy
        from test_ci_summary import archive_download_summary
        for phase in ("tests-read", "export", "summary-read", "details-read", "attachments-export",
                      "tool-yellow", "tool-yellow-scan-failed", "tool-yellow-bundle-failed", "tool-yellow-unknown-duration"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                tool_yellow = phase.startswith("tool-yellow")
                root, output = Path(directory, "checkout"), Path(directory, "output")
                root.mkdir()
                bundle = Path(directory, "private/result/fixture.xcresult")
                bundle.mkdir(parents=True)
                source = root / "Products/app.xctestrun"
                source.parent.mkdir()
                source.touch()
                (source.parent / "Debug-iphonesimulator/immichSlides.app").mkdir(parents=True)
                seed = archive_download_summary()
                tool = "Application 'com.331works.immichSlides' does not have a process ID"
                if tool_yellow:
                    seed["identity"].update(event="schedule", ref="refs/heads/main")
                    seed["identity"].pop("dirty", None)
                declared = [test_identity("ui", "NavigationUITests/testMethod" + str(index),
                            platform="ios", device="ipad") for index in range(21)]
                official = {"devices": [{"deviceId": "target", "modelName": "iPad Pro", "platform": "iOS Simulator"}],
                    "testNodes": [{"nodeType": "UI test bundle", "name": "immichSlidesUITests", "children": [
                        {"nodeType": "Test Case", "nodeIdentifier": entry["key"] + "()", "durationInSeconds": 1,
                         "result": "Passed" if index == 0 else "Skipped"} for index, entry in enumerate(declared)]}]}
                counts = {"totalTestCount": 21, "passedTests": 1, "failedTests": 0, "skippedTests": 20, "result": "Passed"}
                if tool_yellow:
                    nodes = official["testNodes"][0]["children"]
                    for index, node in enumerate(nodes):
                        node["result"] = "Failed" if index == 0 else "Passed"
                    nodes[0]["children"] = [{"nodeType": "Failure Message", "name": tool}]
                    if phase == "tool-yellow-unknown-duration":
                        nodes[0].pop("durationInSeconds")
                    counts.update(passedTests=20, failedTests=1, skippedTests=0, result="Failed")
                issues = {"testFailureSummaries": {"_values": [{
                    "testCaseName": {"_value": declared[0]["key"].replace("/", ".") + "()"},
                    "issueType": {"_value": "Uncategorized"},
                    "message": {"_value": tool}}]}}
                legacy = {"issues": issues, "actions": {"_values": [{"actionResult": {"issues": issues}}]}}
                policy = parse_policy((runner.ROOT / "scripts/ci-test-policy.json").read_text())
                inputs = {"hashes": seed["hashes"], "population": dict(seed["population"], declared=declared,
                    compiled=[], observed=[]), "policy": policy, "discovery_policy": policy, "deselections": [],
                    "registry": {"schema_version": 1, "entries": []}, "registry_revision": "b" * 40}
                inputs["hashes"]["policies"]["known-flaky"] = "f" * 64
                clock, tests_reads, executions = [0.0], [], []
                def process(command, **kwargs):
                    if command[0] == "xcodebuild":
                        if "-enumerate-tests" in command:
                            enumeration = {"errors": [], "values": [{"enabledTests": [
                                {"identifier": "immichSlidesUITests/" + entry["key"]} for entry in declared]}]}
                            Path(command[command.index("-test-enumeration-output-path") + 1]).write_text(json.dumps(enumeration))
                        else:
                            executions.append(command)
                    return SimpleNamespace(wait=lambda **kwargs: 65 if tool_yellow and "-enumerate-tests" not in command else 0, pid=42)
                def read(command, **kwargs):
                    self.assertEqual(command[:2], ["xcrun", "xcresulttool"])
                    self.assertEqual(kwargs["timeout"], 180)
                    if "--legacy" in command:
                        return subprocess.CompletedProcess(command, 0, json.dumps(legacy).encode())
                    if command[4] == "tests":
                        tests_reads.append(command)
                    current = ("attachments-export" if command[2] == "export" else "details-read" if command[4] == "test-details"
                               else "summary-read" if command[4] == "summary" else "tests-read" if len(tests_reads) == 1 else "export")
                    if current == phase:
                        clock[0] += 184.7
                        raise subprocess.TimeoutExpired(command, kwargs["timeout"], output=b"PRIVATE_SENTINEL", stderr=b"PRIVATE_SENTINEL")
                    clock[0] += 0.44
                    detail = ({"testIdentifier": command[command.index("--test-id") + 1], "testResult": "Skipped", "testRuns": [
                        {"nodeType": "Test Case Run", "result": "Skipped", "name": "Official skip"}]} if current == "details-read" else {})
                    if tool_yellow and current == "details-read":
                        detail = {"testIdentifier": command[command.index("--test-id") + 1], "testResult": "Failed",
                                  "testRuns": [{"nodeType": "Test Case Run", "result": "Failed", "name": tool}]}
                    payload = json.dumps(counts if command[4] == "summary" else detail if current == "details-read" else official)
                    return subprocess.CompletedProcess(command, 0, payload if kwargs.get("text") else payload.encode())
                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2",
                                                              "RUNNER_ENVIRONMENT": "github-hosted"}))
                    for name, value in (("ROOT", root), ("run_identity", seed["identity"]),
                        ("source_metadata", (".github/workflows/ci-nightly.yml", False)), ("fixture_inputs", inputs),
                        ("toolchain", seed["toolchain"]), ("prepare_fixture_result_bundle", bundle),
                        ("prepare_simulator", None), ("verify_simulator_device", None), ("simulator_inventory", {}),
                        ("wait_for_service", ("127.0.0.1", 1234)), ("disk_check", None), ("check_products", None),
                        ("measure_signing", "adhoc"), ("prepare_test_run", source), ("reset_simulator_app", None),
                        ("crash_report_directories", []), ("crash_report_snapshot", {}),
                        ("stop_exact_process", None), ("finalize_fixture_run", [])):
                        stack.enter_context(patch.object(runner, name, value if name == "ROOT" else unittest.mock.Mock(return_value=value)))
                    stack.enter_context(patch.object(runner.subprocess, "Popen", side_effect=process))
                    lifecycle = stack.enter_context(patch.object(runner, "monitor_invocation", wraps=runner.monitor_invocation))
                    stack.enter_context(patch.object(runner.subprocess, "run", side_effect=read))
                    stack.enter_context(patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]))
                    stdout = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                    stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                    if tool_yellow:
                        scan = runner.write_sensitive_scan
                        def sensitive_scan(*args, **kwargs):
                            self.assertNotIn("::warning", stdout.getvalue(), "Warning precedes sensitive scan")
                            if phase == "tool-yellow-scan-failed":
                                raise ValueError("Synthetic sensitive scan failure")
                            return scan(*args, **kwargs)
                        def finalize(*args, **kwargs):
                            self.assertNotIn("::warning", stdout.getvalue(), "Warning precedes private bundle handling")
                            return ["Synthetic quarantine failure"] if phase == "tool-yellow-bundle-failed" else []
                        stack.enter_context(patch.object(runner, "write_sensitive_scan", side_effect=sensitive_scan))
                        runner.finalize_fixture_run.side_effect = finalize
                    code = runner.main(["--device", "ipad", "--destination", "platform=iOS Simulator,id=target",
                        "--output-dir", str(output), "--xctestrun", str(source), "--shard", "navigation",
                        "--shard-manifest", str(root / "manifest.json"), "--listed-only-retry",
                        "--result-export-timeout-seconds", "180", "--failure-screenshots",
                        "--timeout-minutes", "65", "--total-timeout-minutes", "85"])
                    self.assertTrue(any("test-without-building" in call.args[0] and "-enumerate-tests" not in call.args[0]
                                        for call in lifecycle.call_args_list))
                    self.assertTrue(all(isinstance(call.kwargs.get("deadline"), (int, float))
                                        and call.kwargs["deadline"] < float("inf") for call in lifecycle.call_args_list))
                    self.assertEqual({call.kwargs["deadline"] for call in lifecycle.call_args_list}, {65 * 60})
                    retained = runner.finalize_fixture_run.call_args
                if tool_yellow:
                    yellow = phase == "tool-yellow"
                    self.assertEqual(0 if yellow else 65 if phase == "tool-yellow-unknown-duration" else 1, code)
                    result = parse_summary((output / "summary.json").read_text())
                    self.assertEqual("failed", result["status"])
                    if phase == "tool-yellow-unknown-duration":
                        row = result["population"]["observed"][0]
                        self.assertIsNone(row["duration_seconds"])
                        self.assertEqual(65, row["attempts"][0]["exit_code"])
                        self.assertNotIn("environment_limit", row)
                        self.assertEqual(21, len(result["population"]["observed"]))
                        self.assertIn("| failed | unknown |", (output / "fixture-coverage.md").read_text())
                        self.assertNotIn("::warning", stdout.getvalue())
                        self.assertEqual([], json.loads((output / "coverage-verdict.json").read_text())["missing_executed"])
                        self.assertNotIn("official-result-read-failed", [item["code"] for item in result["infrastructure"]])
                        self.assertEqual(1, len(executions))
                        continue
                    self.assertIn("environment_limit", result["population"]["observed"][0])
                    self.assertEqual(False, retained.kwargs["successful"])
                    if yellow:
                        self.assertIn(tool, stdout.getvalue())
                        self.assertIn("::warning title=Environment-limited XCTest tool::", stdout.getvalue())
                    else:
                        self.assertIn("sensitive-scan-failed" if phase == "tool-yellow-scan-failed" else "cleanup-failed",
                                      [item["code"] for item in result["infrastructure"]])
                        self.assertNotIn("::warning", stdout.getvalue())
                    continue
                self.assertEqual(code, 1)
                result = parse_summary((output / "summary.json").read_text())
                self.assertEqual(result["status"], "failed")
                self.assertEqual(result["population"]["declared"], declared)
                self.assertCountEqual(result["population"]["compiled"], declared)
                self.assertIn("xcresult-export-timeout", [item["code"] for item in result["infrastructure"]], result["infrastructure"])
                timeout = next(item for item in result["infrastructure"] if item["code"] == "xcresult-export-timeout")
                self.assertEqual(timeout["message"], "Official result export exceeded its budget; phase=" + phase + "; elapsed_seconds=184.700")
                self.assertEqual(len(executions), 1, "An official result timeout must not retry XCTest")
                self.assertEqual(len(tests_reads), 1 if phase == "attachments-export" else 2,
                                 "Result export is separate from normalized tests reading")
                observed = result["population"]["observed"]
                self.assertEqual(len(observed), 0 if phase == "tests-read" else 21)
                rows = json.loads((output / "fixture-coverage.json").read_text())["tests"]
                self.assertEqual(len(rows), len(observed))
                self.assertNotIn(str(bundle), json.dumps(result["infrastructure"]))
                self.assertNotIn("PRIVATE_SENTINEL", json.dumps(result))
                if phase == "tests-read":
                    self.assertTrue((output / "official-summary.json").exists(), result["infrastructure"])
                    self.assertEqual(json.loads((output / "official-summary.json").read_text()), counts)
                    self.assertEqual(json.loads((output / "export-read-timing.json").read_text())["attempts"][0]["elapsed_seconds"], 184.7)
                    self.assertAlmostEqual(json.loads((output / "export-timing.json").read_text())["official_export_seconds"], 0.88)

    def test_inventory_timeouts_use_bounded_readiness_without_retrying_invalid_results(self):
        import strict_e2e_runner_support as support
        for state in ("recovered", "timeout", "late", "exit", "invalid"):
            with self.subTest(state=state):
                clock, calls, reports = [0.0], [], []
                def query(command, **kwargs):
                    calls.append(kwargs["timeout"])
                    self.assertEqual(command, ["xcrun", "simctl", "list", "devices", "available", "--json"])
                    if state == "timeout" or state == "recovered" and len(calls) == 1:
                        clock[0] += kwargs["timeout"]
                        raise subprocess.TimeoutExpired(["private-input"], kwargs["timeout"], output=b"private-input")
                    if state == "late":
                        clock[0] = 301
                    return subprocess.CompletedProcess(command, 2 if state == "exit" else 0,
                        "private-input" if state == "invalid" else '{"devices":{}}', "private-input")
                with patch.object(support.subprocess, "run", side_effect=query), \
                        patch.object(support.time, "monotonic", side_effect=lambda: clock[0]):
                    if state == "recovered":
                        self.assertEqual(support.simulator_inventory(report=reports.append), {"devices": {}})
                        self.assertEqual(calls, [10, 20])
                    else:
                        with self.assertRaises(support.CommandError) as error:
                            support.simulator_inventory(report=reports.append)
                        self.assertNotIn("private-input", str(error.exception))
                        if state == "timeout":
                            self.assertEqual(clock[0], 300)
                            self.assertLessEqual(max(calls), 60)
                            self.assertEqual(error.exception.entry["code"], "simulator-inventory-timeout")
                        else:
                            self.assertEqual(len(calls), 1)
                self.assertNotIn("private-input", "\n".join(reports))

    def test_early_fixture_failures_keep_registry_date_and_nonpassing_coverage(self):
        from datetime import date
        from strict_e2e_runner_support import InfrastructureTimeout
        from test_ci_summary import discovery_summary
        from ci_summary import parse_summary
        from ci_verdict import parse_policy
        for stage in ("simulator", "inventory", "service"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as directory:
                root, output = Path(directory, "checkout"), Path(directory, "output")
                root.mkdir()
                bundle = Path(directory, "private/result/fixture.xcresult")
                bundle.mkdir(parents=True)
                seed = discovery_summary()
                policy = parse_policy((runner.ROOT / "scripts/ci-test-policy.json").read_text())
                inputs = {"hashes": seed["hashes"], "population": dict(seed["population"], compiled=[], observed=[]),
                          "policy": policy, "discovery_policy": policy, "deselections": [],
                          "registry": {"schema_version": 1, "entries": []}, "registry_revision": "b" * 40}
                error = runner.CommandError("Synthetic " + stage + " preparation failure")
                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}))
                    for name, value in (("ROOT", root), ("run_identity", seed["identity"]),
                                        ("source_metadata", (".github/workflows/ci-ui.yml", False)),
                                        ("fixture_inputs", inputs), ("toolchain", seed["toolchain"]),
                                        ("prepare_fixture_result_bundle", bundle), ("verify_simulator_device", None),
                                        ("stop_exact_process", None), ("finalize_fixture_run", [])):
                        stack.enter_context(patch.object(runner, name, value if name == "ROOT" else unittest.mock.Mock(return_value=value)))
                    clock = stack.enter_context(patch.object(runner, "date"))
                    clock.today.return_value = date(2026, 10, 13)
                    stack.enter_context(patch.object(runner, "prepare_simulator", side_effect=error if stage == "simulator" else None))
                    stack.enter_context(patch.object(runner, "simulator_inventory", return_value={},
                        side_effect=InfrastructureTimeout("simulator-inventory", 60) if stage == "inventory" else None))
                    stack.enter_context(patch.object(runner.subprocess, "Popen"))
                    stack.enter_context(patch.object(runner, "wait_for_service", side_effect=error))
                    launch = stack.enter_context(patch.object(runner, "run_xcode_attempts"))
                    scan = stack.enter_context(patch.object(runner, "write_sensitive_scan"))
                    evaluate = stack.enter_context(patch.object(runner, "evaluate_population", wraps=runner.evaluate_population))
                    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                    stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                    code = runner.main(["--device", "iphone", "--destination", "platform=iOS Simulator,id=target",
                        "--output-dir", str(output), "--xctestrun", str(root / "unused.xctestrun"), "--shard", "scoped-a",
                        "--shard-manifest", str(root / "unused.json"), "--scoped-plan-sha256", "e" * 64,
                        "--compiled-from-official-results", "--listed-only-retry"])
                self.assertNotEqual(code, 0)
                launch.assert_not_called()
                scan.assert_called_once()
                self.assertEqual(evaluate.call_args.kwargs["evaluated_on"], date(2026, 10, 13))
                result = parse_summary((output / "summary.json").read_text())
                self.assertEqual(result["status"], "failed")
                self.assertTrue(any(stage in item["message"] for item in result["infrastructure"]))
                self.assertTrue(all(item["outcome"] == "not-run" for item in result["population"]["observed"]))
                verdict = json.loads((output / "coverage-verdict.json").read_text())
                self.assertEqual(verdict["status"], "failed")
                self.assertFalse(any("trusted producer evaluation date" in message for message in verdict["errors"]))

    def test_listed_only_retry_main_preserves_legacy_labels_for_failed_and_flaky_passed_methods(self):
        from types import SimpleNamespace
        from ci_flaky import ASSERTION_FAILURE
        from ci_summary import observation, parse_summary
        from ci_verdict import parse_policy
        from test_ci_flaky import registry
        from test_ci_summary import discovery_summary, first_failure_receipt
        from ci_failure_diagnostics import configure_first_failure_attempt
        for retried, retry_read_failed, retry_two, configure_failed, first_missing in (
                (False, False, False, False, False), (True, False, False, False, False),
                (True, True, False, False, False), (True, False, True, False, False),
                (True, False, True, True, False), (True, False, True, False, True)):
            for diagnostics in ({"failure_phase": "interval_setup", "failure_class": "interval_readback"},
                                {"failure_phase": "unknown", "failure_class": "unknown"}):
                with self.subTest(retried=retried, retry_read_failed=retry_read_failed, retry_two=retry_two,
                                  configure_failed=configure_failed, first_missing=first_missing,
                                  diagnostics=diagnostics), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory, "checkout").resolve()
                    root.mkdir()
                    output = Path(directory, "output")
                    source = root / "Products" / "app.xctestrun"
                    source.parent.mkdir()
                    source.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [
                        {"BlueprintName": "immichSlidesUITests", "EnvironmentVariables": {}}]}]}))
                    (source.parent / "Debug-iphonesimulator" / "immichSlides.app").mkdir(parents=True)
                    seed = discovery_summary()
                    entry = seed["population"]["declared"][0]
                    if retry_read_failed:
                        missing = dict(entry, key="SettingsUITests/testMissing")
                        seed["population"]["declared"].append(missing)
                    official = seed["compiled_evidence"]["official_tests"]
                    official["testNodes"][0]["children"][0].update(result="Failed", **diagnostics)
                    if retry_two:
                        second = dict(entry, key=entry["key"] + "Second")
                        seed["population"]["declared"].append(second)
                        official["testNodes"][0]["children"].append({"nodeType": "Test Case",
                            "nodeIdentifier": second["key"] + "()", "result": "Failed", "durationInSeconds": 1, **diagnostics})
                    trusted = registry()
                    trusted["entries"][0]["identity"] = dict(entry, dimensions={"platform": "ios"})
                    trusted["entries"][0]["review_by"] = "2099-01-01"
                    if retry_two:
                        trusted["entries"].append(copy.deepcopy(trusted["entries"][0]))
                        trusted["entries"][-1]["identity"] = dict(second, dimensions={"platform": "ios"})
                    if not retried:
                        trusted["entries"] = []
                    policy = parse_policy((runner.ROOT / "scripts/ci-test-policy.json").read_text())
                    inputs = {"hashes": seed["hashes"], "population": dict(seed["population"], compiled=[], observed=[]),
                              "policy": policy, "discovery_policy": policy, "deselections": [], "registry": trusted,
                              "registry_revision": "b" * 40}
                    inputs["hashes"]["policies"]["known-flaky"] = "f" * 64
                    failed = observation(entry, "failed", 1, exit_code=65, reason=ASSERTION_FAILURE,
                                         failure_diagnostics=diagnostics)
                    passed = observation(entry, "passed", 1)
                    first_receipt = first_failure_receipt()
                    first_receipt["screenshot"] = {"status": "unavailable", "width": None, "height": None, "bytes": None}
                    if retry_two:
                        from PIL import Image
                        pixels = io.BytesIO()
                        Image.new("RGB", (64, 32), "blue").save(pixels, format="PNG")
                        first_receipt["screenshot"] = {"status": "captured", "width": 64, "height": 32,
                                                       "bytes": len(pixels.getvalue())}
                    bundles, invocations = [], []
                    def configure(call, spool, selectors, **kwargs):
                        if configure_failed and spool.name != "attempt-1":
                            original_write = Path.write_bytes
                            def fail_write(path, payload):
                                original_write(path, payload[:8])
                                raise OSError("Synthetic partial attempt configuration write")
                            with patch.object(Path, "write_bytes", fail_write):
                                return configure_first_failure_attempt(call, spool, selectors, **kwargs)
                        return configure_first_failure_attempt(call, spool, selectors, **kwargs)
                    def allocate():
                        bundle = Path(directory, "private", str(len(bundles)), "fixture.xcresult")
                        bundle.mkdir(parents=True)
                        bundles.append(bundle)
                        return bundle
                    def process(command, **kwargs):
                        if command[0] == "xcodebuild":
                            invocations.append(command)
                            target = plistlib.loads(Path(command[command.index("-xctestrun") + 1]).read_bytes())["TestConfigurations"][0]["TestTargets"][0]
                            environment = target["EnvironmentVariables"]
                            number = len(invocations)
                            if configure_failed and number > 1:
                                self.assertNotEqual("1", environment.get("STRICT_E2E_FIRST_FAILURE_ENABLED"))
                                self.assertNotIn("STRICT_E2E_FIRST_FAILURE_DIR", environment)
                            else:
                                self.assertEqual("1", environment["STRICT_E2E_FIRST_FAILURE_ENABLED"])
                                spool = Path(environment["STRICT_E2E_FIRST_FAILURE_DIR"])
                                self.assertEqual(spool, Path(directory, "private/first-failure-spool", "attempt-" + str(number)))
                        code = 65 if len(invocations) == 1 or retry_two else 0
                        return SimpleNamespace(wait=lambda **kwargs: code, pid=42)
                    def export(bundle, *args, **kwargs):
                        self.assertIs(kwargs["enrich_failure_diagnostics"], True)
                        self.assertEqual(kwargs["export_timeout_seconds"], 60)
                        suffix = kwargs["suffix"]
                        number = bundles.index(bundle) + 1
                        self.assertEqual(kwargs["first_failure_spool"], None if configure_failed and number > 1 else
                            (Path(directory, "private/first-failure-spool", "attempt-" + str(number)),
                             [item["key"] for item in seed["population"]["declared"]]))
                        payload = copy.deepcopy(official)
                        for node in payload["testNodes"][0]["children"]:
                            if not first_missing:
                                node["first_failure"] = copy.deepcopy(first_receipt)
                        if bundle != bundles[0]:
                            retried_entry = second if retry_two and bundle == bundles[2] else entry
                            payload["testNodes"][0]["children"][0] = {
                                "nodeType": "Test Case", "nodeIdentifier": retried_entry["key"] + "()",
                                "result": "Failed" if retry_two else "Passed", "durationInSeconds": 1}
                            payload["testNodes"][0]["children"] = payload["testNodes"][0]["children"][:1]
                            if retry_two and not configure_failed:
                                payload["testNodes"][0]["children"][0]["first_failure"] = {
                                    **copy.deepcopy(first_receipt), "step": "capture-frame"}
                        (output / ("official-tests" + suffix + ".json")).write_text(json.dumps(payload))
                        if retry_two:
                            for node in payload["testNodes"][0]["children"]:
                                if "first_failure" not in node:
                                    continue
                                index = 1 if node["nodeIdentifier"] == second["key"] + "()" else 0
                                image = kwargs["first_failure_images"] / (str(index) + ".png")
                                image.parent.mkdir(parents=True, exist_ok=True)
                                image.write_bytes(pixels.getvalue())
                        return "f" * 64
                    # Test-details text disagrees with legacy summaries; it must never replace their labels.
                    detail = ("Failed to get matching snapshot: private detail" if diagnostics["failure_phase"] != "unknown"
                              else "The iOS slider must be settable to 30 seconds. conflicting failure")
                    with contextlib.ExitStack() as stack:
                        stack.enter_context(patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}))
                        for name, value in (("ROOT", root), ("run_identity", seed["identity"]),
                                            ("source_metadata", (".github/workflows/ci-ui.yml", False)),
                                            ("fixture_inputs", inputs), ("toolchain", seed["toolchain"]),
                                            ("prepare_simulator", None), ("verify_simulator_device", None),
                                            ("wait_for_service", ("127.0.0.1", 1234)), ("disk_check", None),
                                            ("check_products", None), ("measure_signing", "adhoc"),
                                            ("reset_simulator_app", None),
                                            ("crash_report_directories", []), ("crash_report_snapshot", {}),
                                            ("read_problem_reason", detail), ("stop_exact_process", None)):
                            stack.enter_context(patch.object(runner, name, value if name == "ROOT"
                                                            else unittest.mock.Mock(return_value=value)))
                        stack.enter_context(patch.object(runner, "prepare_fixture_result_bundle", side_effect=allocate))
                        reads = ([copy.deepcopy([failed, observation(second, "failed", 1, exit_code=65, reason=ASSERTION_FAILURE,
                                   failure_diagnostics=diagnostics)]), [observation(entry, "failed", 1, exit_code=65)],
                                   [observation(second, "failed", 1, exit_code=65)]] if retry_two else
                                 [copy.deepcopy([failed]), subprocess.TimeoutExpired("xcresulttool", 60)
                                  if retry_read_failed else [passed]])
                        stack.enter_context(patch.object(runner, "read_xcode_observations", side_effect=reads))
                        stack.enter_context(patch.object(runner.subprocess, "Popen", side_effect=process))
                        stack.enter_context(patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"{}")))
                        stack.enter_context(patch.object(runner, "simulator_inventory", return_value={}))
                        stack.enter_context(patch.object(runner, "export_private_result_bundle", side_effect=export))
                        stack.enter_context(patch("ci_failure_diagnostics.configure_first_failure_attempt", side_effect=configure))
                        stack.enter_context(patch.object(runner, "finalize_fixture_run", return_value=[]))
                        stack.enter_context(patch.object(runner, "write_sensitive_scan"))
                        stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                        stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                        code = runner.main(["--device", "iphone", "--destination", "platform=iOS Simulator,id=target",
                            "--output-dir", str(output), "--xctestrun", str(source), "--shard", "scoped-a",
                            "--shard-manifest", str(root / "manifest.json"), "--scoped-plan-sha256", "e" * 64,
                            "--compiled-from-official-results", "--listed-only-retry", *(["--failure-screenshots"] if retry_two else [])])
                    self.assertEqual(code, 0 if retried and not retry_read_failed and not retry_two else 65)
                    self.assertEqual(len(invocations), 3 if retry_two else 2 if retried else 1)
                    result = parse_summary((output / "summary.json").read_text())
                    actual = result["population"]["observed"][0]
                    self.assertEqual(actual["outcome"], "flaky-passed" if retried and not retry_read_failed and not retry_two else "failed")
                    if first_missing:
                        self.assertNotIn("first_failure", actual)
                        self.assertTrue(all("first_failure" not in item for item in actual["attempts"]))
                    else:
                        self.assertEqual(first_receipt, actual["first_failure"])
                    if retry_two:
                        self.assertEqual(2, len(result["population"]["observed"]))
                        for record in result["population"]["observed"]:
                            if first_missing:
                                self.assertNotIn("first_failure", record)
                            else:
                                self.assertEqual(first_receipt, record["first_failure"])
                                if configure_failed:
                                    self.assertNotIn("first_failure", record["attempts"][1])
                                else:
                                    self.assertEqual("capture-frame", record["attempts"][1]["first_failure"]["step"])
                        import ci_ui_tests
                        with patch.object(ci_ui_tests, "output"), contextlib.redirect_stderr(io.StringIO()):
                            self.assertEqual(0, ci_ui_tests.main(["check-upload", "--output-dir", str(output)]))
                    for field, value in diagnostics.items():
                        self.assertEqual(actual[field], value)
                        self.assertEqual(actual["attempts"][0][field], value)
                        rows = json.loads((output / "fixture-coverage.json").read_text())["tests"]
                        self.assertEqual(rows[0][field], value)
                    if retry_read_failed:
                        self.assertEqual((rows[-1]["identity"], rows[-1]["outcome"], rows[-1]["reason"]),
                                         (missing, "not-run", "compiled but no official result"))
                    if retried:
                        self.assertNotIn("failure_phase", actual["attempts"][1])

    def test_failed_ui_method_diagnostics_survive_coverage_and_summary_without_free_text(self):
        from ci_summary import observation, test_identity, validate_observation
        identity = test_identity("ui", "Flow/testFailure", platform="ios")
        diagnostics = {"failure_phase": "interval_setup", "failure_class": "interval_readback"}
        node = {"nodeType": "Test Case", "nodeIdentifier": "Flow/testFailure()", "result": "Failed",
                "durationInSeconds": 1, **diagnostics}
        for extra in (diagnostics, {}):
            with self.subTest(extra=extra):
                official = {"testNodes": [{key: value for key, value in node.items()
                                           if key not in diagnostics or key in extra}]}
                row = coverage_rows([identity], [identity], official, "iphone")[0]
                expected = diagnostics if extra else {"failure_phase": "unknown", "failure_class": "unknown"}
                self.assertEqual({field: row[field] for field in expected}, expected)
                entry = observation(identity, row["outcome"], row["duration_seconds"], exit_code=65, failure_diagnostics=expected)
                validate_observation(entry)
                self.assertEqual(entry["outcome"], "failed")
                self.assertEqual(entry["attempts"][0]["exit_code"], 65)
                for field in expected:
                    self.assertEqual(entry[field], entry["attempts"][0][field])
                entry["attempts"][0]["failure_class"] = "private assertion text"
                with self.assertRaises(ContractError):
                    validate_observation(entry)
        with self.assertRaises(ValueError):
            coverage_rows([identity], [identity], {"testNodes": [dict(node, failure_phase="private assertion text")]}, "iphone")

    def test_candidate_deselection_changes_cannot_override_base_discovery_eligibility(self):
        import hashlib
        from test_ci_summary import discovery_summary
        from ci_summary import parse_summary
        from ci_summary import test_identity
        policy = json.loads((runner.ROOT / "scripts/ci-test-policy.json").read_text())
        entry = test_identity("ui", "Flow/testFirst", platform="ios", device="iphone")
        rule = {"tier": "ui", "environment": "fixture", "identity": entry,
                "reason": "Reviewed fixture exception", "owning_tier": "nightly"}
        for base_has_rule in (False, True):
            with self.subTest(base_has_rule=base_has_rule), tempfile.TemporaryDirectory() as directory:
                root = Path(directory, "checkout").resolve()
                root.mkdir()
                (root / "scripts").mkdir()
                (root / "immichSlidesUITests").mkdir()
                (root / "immichSlidesUITests" / "Tests.swift").write_text(
                    "class Flow: XCTestCase { func testFirst() {} }")
                (root / "immichSlides-iOS.xctestplan").write_text(json.dumps({"testTargets": [
                    {"target": {"name": "immichSlidesUITests"}}]}))
                base, candidate = copy.deepcopy(policy), copy.deepcopy(policy)
                base["deselections"] = [rule] if base_has_rule else []
                candidate["deselections"] = [] if base_has_rule else [rule]
                candidate["expected_skips"] = [{"kind": "ui", "key_pattern": entry["key"],
                    "dimensions": entry["dimensions"], "tier": "ui", "environment": "fixture", "reason": "Candidate skip"}]
                candidate_text = json.dumps(candidate, indent=2)
                candidate_bytes = candidate_text.replace("\n", "\r\n").encode()
                (root / "scripts/ci-test-policy.json").write_bytes(candidate_bytes)
                with patch("ci_publish_git.read_blob", return_value=json.dumps(base)) as blob:
                    result = runner.fixture_inputs(root, "iphone", [], mode="pr", policy_revision="b" * 40)
                blob.assert_called_once_with("b" * 40, "scripts/ci-test-policy.json")
                self.assertEqual(result["official_discovery_eligible"], not base_has_rule)
                self.assertEqual(result["deselections"], [] if base_has_rule else [rule])
                self.assertEqual(result["policy"], candidate)
                self.assertEqual(result["hashes"]["policies"]["test-policy"], hashlib.sha256(candidate_bytes).hexdigest())
                if not base_has_rule:
                    result["hashes"]["manifests"]["ui-scoped-plan"] = "e" * 64
                    seed = discovery_summary()
                    output = Path(directory, "conflict")
                    stderr = io.StringIO()
                    with patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}), \
                            patch.object(runner, "ROOT", root), patch.object(runner, "fixture_inputs", return_value=result), \
                            patch.object(runner, "run_identity", return_value=seed["identity"]), \
                            patch.object(runner, "source_metadata", return_value=(".github/workflows/ci-ui.yml", False)), \
                            patch.object(runner, "toolchain") as tools, patch.object(runner.subprocess, "run") as host, \
                            patch.object(runner.subprocess, "Popen") as launch, \
                            contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                        self.assertEqual(runner.main(["--device", "iphone", "--destination", "platform=iOS Simulator,id=target",
                            "--output-dir", str(output), "--xctestrun", str(root / "unused.xctestrun"), "--shard", "scoped-a",
                            "--shard-manifest", str(root / "unused.json"), "--compiled-from-official-results"]), 1)
                    tools.assert_not_called()
                    host.assert_not_called()
                    launch.assert_not_called()
                    conflict = parse_summary((output / "summary.json").read_text())
                    self.assertEqual(conflict["status"], "failed")
                    self.assertIn("candidate fixture deselection conflicts with base", conflict["infrastructure"][0]["message"])
                    self.assertIn(conflict["infrastructure"][0]["message"], stderr.getvalue())

    def test_scoped_execution_skips_enumeration_and_rejected_proofs_still_scan_and_dispose(self):
        from types import SimpleNamespace
        from test_ci_summary import discovery_summary
        from ci_summary import observation, parse_summary
        from ci_verdict import parse_policy
        for raw, shape in ((0, "complete"), (0, "expected-skip"), (65, "missing-export"), (124, "empty"),
                           (0, "empty"), (65, "complete"), (65, "unknown"), (65, "malformed"), (2, "launch")):
            with self.subTest(raw=raw, shape=shape), tempfile.TemporaryDirectory() as directory:
                root = Path(directory, "checkout").resolve()
                root.mkdir()
                output, work = Path(directory, "output"), Path(directory, "private")
                work.mkdir()
                bundle = work / "result" / "fixture.xcresult"
                bundle.mkdir(parents=True)
                source = root / "Products" / "app.xctestrun"
                source.parent.mkdir()
                source.touch()
                (source.parent / "Debug-iphonesimulator" / "immichSlides.app").mkdir(parents=True)
                seed = discovery_summary()
                entry = seed["population"]["declared"][0]
                official = seed["compiled_evidence"]["official_tests"]
                if shape == "empty":
                    official["testNodes"][0]["children"] = []
                elif shape == "unknown":
                    official["testNodes"][0]["children"][0]["result"] = "Unknown"
                elif shape == "malformed":
                    official["testNodes"] = None
                elif shape == "expected-skip":
                    official["testNodes"][0]["children"][0]["result"] = "Skipped"
                policy = parse_policy((runner.ROOT / "scripts/ci-test-policy.json").read_text())
                discovery_policy = copy.deepcopy(policy)
                if shape == "expected-skip":
                    policy["expected_skips"].append({"kind": "ui", "key_pattern": entry["key"],
                        "dimensions": entry["dimensions"], "tier": "ui", "environment": "fixture", "reason": "Candidate skip"})
                inputs = {"hashes": seed["hashes"], "population": dict(seed["population"], compiled=[], observed=[]),
                          "policy": policy, "discovery_policy": discovery_policy, "deselections": [], "registry": {"schema_version": 1, "entries": []},
                          "registry_revision": "b" * 40}
                inputs["hashes"]["policies"]["known-flaky"] = "f" * 64
                def export(*args, **kwargs):
                    if shape in {"missing-export", "launch"}:
                        raise runner.CommandError("Synthetic export unavailable")
                    (output / "official-tests.json").write_text(json.dumps(official))
                    return "f" * 64
                commands = []
                gate_finished = []
                def gate(udid, *, boot_submitted=False):
                    self.assertEqual(udid, "target")
                    self.assertEqual(boot_submitted, shape == "complete")
                    gate_finished.append(True)
                def process(command, **kwargs):
                    self.assertTrue(gate_finished, "fixture launch must wait for simulator readiness")
                    commands.append(command)
                    if shape == "launch" and command[0] == "xcodebuild":
                        raise OSError("Synthetic launch failure")
                    return SimpleNamespace(wait=lambda **kwargs: raw, pid=42)
                observed = [observation(entry, "passed", 1)] if shape == "complete" else []
                if shape == "expected-skip":
                    observed = [observation(entry, "skipped", 1, reason="Candidate skip")]
                argv = ["--device", "iphone", "--destination", "platform=iOS Simulator,id=target",
                        "--output-dir", str(output), "--xctestrun", str(source), "--shard", "scoped-a",
                        "--shard-manifest", str(root / "manifest.json"), "--scoped-plan-sha256", "e" * 64,
                        "--compiled-from-official-results", "--listed-only-retry", "--failure-screenshots"]
                attachments = []
                inventory_calls = []
                def run(command, **kwargs):
                    self.assertTrue(gate_finished, "simulator inventory must wait for readiness")
                    if command[:3] == ["xcrun", "simctl", "list"]:
                        inventory_calls.append(command)
                        if len(inventory_calls) == 1:
                            raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                    if "attachments" in command:
                        attachments.append(command)
                        from PIL import Image
                        exported = Path(command[command.index("--output-path") + 1]) / "legacy.png"
                        exported.parent.mkdir(parents=True, exist_ok=True)
                        Image.new("RGB", (2000, 100), "blue").save(exported, format="PNG", icc_profile=b"PRIVATE_PROFILE")
                    return SimpleNamespace(returncode=0, stdout=b"{}")
                stderr = io.StringIO()
                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}))
                    for name, value in (("ROOT", root), ("run_identity", seed["identity"]),
                                        ("source_metadata", (".github/workflows/ci-ui.yml", False)),
                                        ("fixture_inputs", inputs), ("toolchain", seed["toolchain"]),
                                        ("prepare_fixture_result_bundle", bundle), ("verify_simulator_device", None),
                                        ("wait_for_service", ("127.0.0.1", 1234)), ("disk_check", None),
                                        ("check_products", None), ("measure_signing", "adhoc"),
                                        ("prepare_test_run", source), ("reset_simulator_app", None),
                                        ("crash_report_directories", []), ("crash_report_snapshot", {}),
                                        ("read_xcode_observations", observed), ("read_problem_reason", "Candidate skip"),
                                        ("stop_exact_process", None)):
                        stack.enter_context(patch.object(runner, name, value if name == "ROOT" else unittest.mock.Mock(return_value=value)))
                    stack.enter_context(patch.object(runner.subprocess, "Popen", side_effect=process))
                    stack.enter_context(patch.object(runner.subprocess, "run", side_effect=run))
                    stack.enter_context(patch.object(runner, "prepare_simulator", side_effect=gate))
                    stack.enter_context(patch.object(runner, "export_private_result_bundle", side_effect=export))
                    scan = stack.enter_context(patch.object(runner, "write_sensitive_scan"))
                    dispose = stack.enter_context(patch.object(runner, "finalize_fixture_run", return_value=[]))
                    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                    stack.enter_context(contextlib.redirect_stderr(stderr))
                    code = runner.main(argv, simulator_prepared=shape == "complete")
                    runner.reset_simulator_app.assert_called_once_with("target", platform="ios", boot_submitted=True)
                    runner.wait_for_service.assert_called_once_with(work / "ready.json", unittest.mock.ANY,
                                                                    startup_log=work / "service.log",
                                                                    fixture_build_timeout_seconds=runner.SERVICE_FIXTURE_BUILD_TIMEOUT_SECONDS,
                                                                    startup_timeout_seconds=runner.SERVICE_STARTUP_TIMEOUT_SECONDS)
                self.assertEqual(len(inventory_calls), 2)
                tests = [command for command in commands if command[0] == "xcodebuild"]
                self.assertEqual(len(tests), 1)
                self.assertNotIn("-enumerate-tests", tests[0])
                self.assertEqual(len(attachments), 1)
                from PIL import Image
                exported = output / "failure-screenshots/attempt-1/legacy.png"
                with Image.open(exported) as image:
                    self.assertLessEqual(max(image.size), 1536)
                    self.assertEqual({}, image.info)
                self.assertLessEqual(exported.stat().st_size, 1048576)
                scan.assert_called_once()
                dispose.assert_called_once()
                self.assertEqual(code, 0 if raw == 0 and shape in {"complete", "expected-skip"} else raw or 1)
                result = json.loads((output / "summary.json").read_text())
                self.assertEqual(result["compiled_evidence"]["first_exit_code"], raw)
                self.assertEqual(result["status"], "passed" if code == 0 else "failed")
                if shape in {"missing-export", "launch"} or raw == 124 or code == 0:
                    parse_summary(result)
                else:
                    with self.assertRaises(ContractError):
                        parse_summary(result)
                    rejection = next(entry for entry in result["infrastructure"] if entry["code"] == "discovery-record-invalid")
                    self.assertIn(rejection["message"], (output / "summary.md").read_text())
                    self.assertIn(rejection["message"], stderr.getvalue())
                import ci_ui_tests as producer
                with patch.object(producer, "output"), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(producer.main(["check-upload", "--output-dir", str(output)]), 0)
                    if shape in {"empty", "complete", "unknown", "malformed"} and code != 0 and raw != 124:
                        for mutation in ("unmarked", "passed", "metadata"):
                            with self.subTest(mutation=mutation):
                                rejected = copy.deepcopy(result)
                                if mutation == "unmarked":
                                    rejected["infrastructure"] = [item for item in rejected["infrastructure"]
                                                                 if item["code"] != "discovery-record-invalid"]
                                elif mutation == "passed":
                                    rejected["status"] = "passed"
                                else:
                                    rejected["toolchain"]["versions"] = {}
                                (output / "summary.json").write_text(json.dumps(rejected))
                                with patch("run_strict_e2e.write_sensitive_scan") as guard:
                                    self.assertEqual(producer.main(["check-upload", "--output-dir", str(output)]), 1)
                                    guard.assert_not_called()
                        (output / "summary.json").write_text(json.dumps(result))
                    (output / "sensitive.txt").write_text(runner.PUBLIC_API_KEY)
                    with self.assertRaises(runner.CommandError):
                        producer.main(["check-upload", "--output-dir", str(output)])
                self.assertEqual(json.loads((output / "sensitive-scan.json").read_text())["result"], "FAIL")

    def test_official_discovery_starts_only_for_bound_scoped_pr_without_base_deselection(self):
        from test_ci_summary import discovery_summary
        from ci_verdict import parse_policy
        summary = discovery_summary()
        summary.pop("compiled_evidence")
        summary["schema_version"] = 1
        policy = parse_policy((runner.ROOT / "scripts/ci-test-policy.json").read_text())
        self.assertTrue(runner.start_official_discovery(summary, "target", policy, enabled=True))
        self.assertEqual(summary["schema_version"], 2)
        self.assertEqual(summary["compiled_evidence"]["official_tests"], None)
        self.assertEqual(summary["population"]["compiled"], [])
        conflict = discovery_summary()
        conflict["population"]["deselected"] = [{"identity": conflict["population"]["declared"][0],
            "reason": "Candidate deselection", "owning_tier": "nightly"}]
        with self.assertRaisesRegex(ContractError, "candidate fixture deselection conflicts with base"):
            runner.start_official_discovery(conflict, "target", policy, enabled=True)
        for mutate in (lambda value: value["run"].update(shard="visual-a"),
                       lambda value: value["identity"].update(event="push"),
                       lambda value: value["source"].update(workflow_path=".github/workflows/ci-nightly.yml"),
                       lambda value: value["hashes"]["manifests"].pop("ui-scoped-plan")):
            other = discovery_summary()
            other["schema_version"] = 1
            other.pop("compiled_evidence")
            mutate(other)
            self.assertFalse(runner.start_official_discovery(other, "target", policy, enabled=True))
            self.assertEqual(other["schema_version"], 1)
        base = copy.deepcopy(policy)
        base["deselections"] = [{"tier": "ui", "environment": "fixture", "identity": summary["population"]["declared"][0]}]
        self.assertFalse(runner.start_official_discovery(discovery_summary(), "target", base, enabled=True))

    def test_fixture_launch_inputs_never_mutate_the_archived_run_or_unit_target(self):
        payload = {"TestConfigurations": [{"TestTargets": [
            {"BlueprintName": "immichSlidesUITests", "EnvironmentVariables": {},
             "TestingEnvironmentVariables": {}, "UITargetAppEnvironmentVariables": {}},
            {"BlueprintName": "immichSlidesTests", "EnvironmentVariables": {},
             "TestingEnvironmentVariables": {}, "UITargetAppEnvironmentVariables": {}}]}]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "archive.xctestrun"
            original = plistlib.dumps(payload)
            source.write_bytes(original)
            screenshots = root / "screenshots"
            screenshots.mkdir()
            prepared = runner.prepare_test_run(source, screenshots, {"IMMICH_TEST_API_KEY": "public-fixture-input"},
                failure_screenshots=True, first_failure_spool=(root / "private-spool", ["FlowUITests/testPlayback"]))
            targets = plistlib.loads(prepared.read_bytes())["TestConfigurations"][0]["TestTargets"]
            environment = targets[0]["EnvironmentVariables"]
            self.assertEqual(environment["STRICT_E2E_FIRST_FAILURE_ENABLED"], "1")
            self.assertEqual(environment["STRICT_E2E_FIRST_FAILURE_DIR"], str(root / "private-spool"))
            self.assertEqual(json.loads(environment["STRICT_E2E_FIRST_FAILURE_TESTS"]), {"FlowUITests/testPlayback": 0})
            self.assertNotIn("STRICT_E2E_FIRST_FAILURE_ENABLED", targets[0]["UITargetAppEnvironmentVariables"])
            self.assertEqual(targets[1], payload["TestConfigurations"][0]["TestTargets"][1])
            self.assertEqual(source.read_bytes(), original)

    def test_crash_reports_keep_only_new_reports_of_this_simulator_within_bounds(self):
        mine, other = "AAAAAAAA-0000-0000-0000-000000000001", "BBBBBBBB-0000-0000-0000-000000000002"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = root / "reports"
            retired = reports / "Retired"
            retired.mkdir(parents=True)
            def write(name, text, folder=reports, age=0):
                path = folder / name
                path.write_text(text) if isinstance(text, str) else path.write_bytes(text)
                stamp = baseline["started"] + age
                os.utime(path, (stamp, stamp))
            baseline = {"started": 1_000_000.0}
            write("immichSlides-old.ips", f"CoreSimulator/Devices/{mine}", age=-100)
            moved = reports / "immichSlides-moved.ips"
            write(moved.name, f"CoreSimulator/Devices/{mine}", age=-100)
            baseline = runner.crash_report_snapshot([reports, retired])
            self.assertIn(moved.name, baseline["names"])
            baseline["started"] = 1_000_000.0
            moved.rename(retired / moved.name)
            write("immichSlides-unlisted-old.ips", f"CoreSimulator/Devices/{mine}", folder=retired, age=-100)
            write("immichSlides-this.ips", f'"procPath" : "{root}/CoreSimulator/Devices/{mine}/immichSlides"\n'
                  f'"crashReporterKey" : "D2604435-10B2-A3CB-5A7F-F0079E1980C1"\n'
                  f'CrashReporter Key:   D2604435-10B2-A3CB-5A7F-F0079E1980C1\nAnonymous UUID:  1234\n'
                  f'"uuid" : "13bf61dd-c45c-3fbf-94a2-7219a8e7abf4"', age=1)
            write("immichSlides-other-simulator.ips", f"CoreSimulator/Devices/{other}", age=1)
            write("accountsd-this.ips", f"CoreSimulator/Devices/{mine}", age=1)
            write("immichSlides-huge.ips", b"x" * (runner.MAX_CRASH_REPORT_BYTES + 1), age=1)
            destination = root / "out"
            collected, omitted = runner.collect_crash_reports(mine, baseline, destination, [reports, retired], home=root)
            self.assertEqual([item["name"] for item in collected], ["immichSlides-this.ips"])
            self.assertEqual([item["name"] for item in omitted], ["immichSlides-huge.ips"])
            self.assertEqual(sorted(path.name for path in destination.iterdir()), ["immichSlides-this.ips", "manifest.json"])
            text = (destination / "immichSlides-this.ips").read_text()
            for private in (str(root), "D2604435", "1234"):
                self.assertNotIn(private, text)
            self.assertIn("13bf61dd-c45c-3fbf-94a2-7219a8e7abf4", text)
            for number in range(runner.MAX_CRASH_REPORTS + 2):
                write(f"immichSlides-burst-{number}.ips", f"CoreSimulator/Devices/{mine}", age=2 + number)
            bounded, _ = runner.collect_crash_reports(mine, baseline, root / "bounded", [reports, retired], home=root)
            self.assertEqual(len(bounded), runner.MAX_CRASH_REPORTS)
            self.assertNotIn("immichSlides-unlisted-old.ips", [item["name"] for item in bounded])

    def test_crash_report_collection_failure_never_escapes_into_the_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = root / "reports"
            reports.mkdir()
            (reports / "immichSlides-this.ips").write_text("CoreSimulator/Devices/UDID")
            blocker = root / "blocker"
            blocker.write_text("a file where the destination parent should be")
            baseline = {"started": 0.0, "names": set()}
            self.assertEqual(runner.collect_crash_reports("UDID", baseline, blocker / "crash-logs", [reports]), ([], []))
            with patch.object(Path, "iterdir", side_effect=PermissionError):
                self.assertEqual(runner.crash_report_snapshot([reports])["names"], set())

    def test_successful_private_disposal_removes_bundle_and_sibling_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private = root / "private"
            private.mkdir()
            output = root / "public"
            output.mkdir()
            with patch.object(runner, "prepare_private_result_bundle_path", return_value=private / "result.xcresult"):
                bundle = runner.prepare_fixture_result_bundle()
            bundle.mkdir()
            (bundle / "Data").write_text("synthetic result")
            (private / "test.log").write_text("synthetic log")
            (private / "fixture.xctestrun").write_text("synthetic launch inputs")
            self.assertEqual(runner.finalize_fixture_run(bundle, output, "0" * 64, successful=True), [])
            self.assertFalse(private.exists())
            self.assertTrue((output / "result-bundle-disposal.json").exists())
            private.mkdir()
            with patch.object(runner, "prepare_private_result_bundle_path", return_value=private / "result.xcresult"):
                bundle = runner.prepare_fixture_result_bundle()
            bundle.mkdir()
            (private / "test.log").write_text("failed-run diagnostic")
            self.assertEqual(runner.finalize_fixture_run(bundle, output, None, successful=False), [])
            self.assertTrue(bundle.exists())
            self.assertTrue((private / "test.log").exists())
            self.assertTrue((output / "result-bundle-quarantine.json").exists())

    def test_device_labels_require_matching_simulator_type_and_official_device(self):
        for label, model, type_name, platform in (
                ("iphone", "iPhone 17e", "iPhone-17e", "iOS Simulator"),
                ("ipad", "iPad Air", "iPad-Air", "iOS Simulator"),
                ("appletv", "Apple TV 4K", "Apple-TV-4K", "tvOS Simulator")):
            device = {"udid": "target", "isAvailable": True,
                      "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + type_name}
            inventory = {"devices": {"runtime": [device]}}
            official = {"devices": [{"deviceId": "target", "modelName": model, "platform": platform}]}
            with self.subTest(label=label):
                runner.verify_simulator_device(inventory, "target", label)
                runner.verify_official_device(official, "target", label)
                for other in set(runner.DEVICES) - {label}:
                    with self.assertRaises(ContractError):
                        runner.verify_simulator_device(inventory, "target", other)
                    with self.assertRaises(ContractError):
                        runner.verify_official_device(official, "target", other)
                for bad in ({"devices": {}}, {"devices": {"runtime": [device, device]}},
                            {"devices": {"runtime": [dict(device, isAvailable=False)]}},
                            {"devices": {"runtime": [dict(device, deviceTypeIdentifier="unknown")]}}):
                    with self.assertRaises(ContractError):
                        runner.verify_simulator_device(bad, "target", label)
                for bad in ({}, {"devices": []}, {"devices": official["devices"] * 2},
                            {"devices": [dict(official["devices"][0], deviceId="other")]},
                            {"devices": [dict(official["devices"][0], platform="physical")]},
                            {"devices": [dict(official["devices"][0], modelName=None)]}):
                    with self.assertRaises(ContractError):
                        runner.verify_official_device(bad, "target", label)

    def test_ambient_and_prefixed_server_ui_and_debug_inputs_cannot_reach_fixture_runs(self):
        for prefix in ("", "TEST_RUNNER_", "SIMCTL_CHILD_", "TEST_RUNNER_SIMCTL_CHILD_"):
            for key in ("IMMICH_API_KEY", "IMMICH_TEST_SERVER_URL", "UI_TEST_SERVER_URL", "ENABLE_DEBUG_FILL_APIKEY",
                        "STRICT_E2E_INPUT_SERVER_URL"):
                with self.subTest(prefix=prefix, key=key):
                    self.assertEqual(clean_environment({prefix + key: "ambient", "PATH": "/bin"}), {"PATH": "/bin"})

    def test_compiled_enumeration_does_not_count_disabled_tests_or_ignore_errors(self):
        expected = [{"kind": "ui", "key": "Flow/testFirst", "dimensions": {"platform": "ios"}}]
        payload = {"errors": [], "values": [{"enabledTests": [{"identifier": "immichSlidesUITests/Flow/testFirst()"}],
                                             "disabledTests": [{"identifier": "immichSlidesUITests/Flow/testOther()"}]}]}
        self.assertEqual(compiled_tests(payload, expected), expected)
        with self.assertRaises(ContractError):
            compiled_tests(dict(payload, errors=["enumeration failed"]), expected)

    def test_enumeration_is_rerun_once_only_after_a_runner_bootstrap_crash(self):
        crash = {"errors": ["Runner (1) encountered an error. (Underlying Error: Early unexpected exit, operation never "
                            "finished bootstrapping - no restart will be attempted. (Underlying Error: Test crashed with "
                            "signal abrt while preparing to run tests.))"], "values": []}
        other = {"errors": ["enumeration failed"], "values": []}
        clean = {"errors": [], "values": []}
        for name, outputs, calls, retried in (("recovered", [crash, clean], 2, True), ("persistent", [crash, crash], 2, True),
                                              ("other error", [other, clean], 1, False), ("clean", [clean, clean], 1, False)):
            with self.subTest(name), tempfile.TemporaryDirectory() as directory:
                enumeration = Path(directory) / "compiled-tests.json"
                names = []
                def run(command_name):
                    enumeration.write_text(json.dumps(outputs[len(names)]))
                    names.append(command_name)
                    return 0
                code, record = runner.enumerate_tests_with_bootstrap_retry(run, enumeration)
                self.assertEqual((code, len(names), record is not None), (0, calls, retried))
                self.assertEqual(json.loads(enumeration.read_text()), outputs[calls - 1])
                if retried:
                    self.assertEqual((names, record["code"]), (["enumerate", "enumerate-retry"], "enumeration-bootstrap-retry"))
                    self.assertEqual(json.loads((Path(directory) / "compiled-tests-attempt-1.json").read_text()), crash)
        with self.assertRaises(ContractError):
            compiled_tests(crash, [])

    def test_default_plan_exclusions_and_explicit_selection_define_the_population(self):
        files = {"Tests.swift": "class Flow: XCTestCase { func testFirst() {} func testSecond() {} }"}
        plan = {"testTargets": [{"target": {"name": "immichSlidesUITests"},
                                 "skippedTests": ["Flow/testSecond()"]}]}
        self.assertEqual([entry["key"] for entry in declared_tests(files, "ios", plan, [])], ["Flow/testFirst"])
        with self.assertRaises(ContractError):
            declared_tests(files, "ios", plan, ["immichSlidesUITests/Flow/testSecond"])
        selected = {"testTargets": [{"target": {"name": "immichSlidesUITests"},
                                    "selectedTests": ["Flow/testSecond()"]}]}
        self.assertEqual([entry["key"] for entry in declared_tests(files, "ios", selected, [])], ["Flow/testSecond"])
        with self.assertRaises(ContractError):
            declared_tests(files, "ios", selected, ["immichSlidesUITests/Flow/testFirst"])
        selected["testTargets"][0]["enabled"] = False
        with self.assertRaises(ContractError):
            declared_tests(files, "ios", selected, [])

    def test_missing_duplicate_unexpected_and_skipped_results_cannot_be_covered(self):
        expected = [{"kind": "ui", "key": "Flow/testFirst", "dimensions": {"platform": "ios"}}]
        nodes = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "Flow/testFirst()",
                                "result": "Passed", "duration": "1秒", "durationInSeconds": 1.25}]}
        rows = coverage_rows(expected, expected, nodes, "iphone")
        self.assertEqual(rows[0]["outcome"], "passed")
        self.assertEqual(rows[0]["duration_seconds"], 1.25)
        interrupted = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "Flow/testFirst()",
            "result": "Failed", "children": [{"name": "Test crashed with signal term.", "nodeType": "Failure Message"}]}]}
        failed = coverage_rows(expected, expected, interrupted, "iphone")[0]
        self.assertEqual("failed", failed["outcome"])
        self.assertIsNone(failed["duration_seconds"])
        same_name = [{"kind": "ui", "key": "immichSlidesUITests/testFirst", "dimensions": {"platform": "ios"}}]
        same_node = {"testNodes": [dict(nodes["testNodes"][0], nodeIdentifier="immichSlidesUITests/testFirst()")]}
        self.assertEqual(coverage_rows(same_name, same_name, same_node, "iphone")[0]["identity"], same_name[0])
        enumeration = {"errors": [], "values": [{"enabledTests": [
            {"identifier": "immichSlidesUITests/immichSlidesUITests/testFirst()"}]}]}
        self.assertEqual(compiled_tests(enumeration, same_name), same_name)
        missing = coverage_rows(expected, expected, {"testNodes": []}, "iphone")
        self.assertEqual(missing[0]["outcome"], "not-run")
        skipped = copy.deepcopy(nodes)
        skipped["testNodes"][0]["result"] = "Skipped"
        self.assertEqual(coverage_rows(expected, expected, skipped, "iphone")[0]["outcome"], "skipped")
        for malformed in ({"testNodes": nodes["testNodes"] * 2},
                          {"testNodes": [dict(nodes["testNodes"][0], nodeIdentifier="Flow/testOther()")]},
                          {"testNodes": [dict(nodes["testNodes"][0], result="Unknown")]},
                          {"testNodes": [dict(nodes["testNodes"][0], children=None)]},
                          {"testNodes": [dict(nodes["testNodes"][0], durationInSeconds="bad")]}):
            with self.subTest(malformed=malformed), self.assertRaises(ContractError):
                coverage_rows(expected, expected, malformed, "iphone")
        uncompiled = coverage_rows(expected, [], {"testNodes": []}, "iphone")
        self.assertEqual(uncompiled[0]["outcome"], "not-run")
        self.assertIn("not compiled", uncompiled[0]["reason"])
        unattempted = coverage_rows(expected, None, {"testNodes": []}, "iphone")
        self.assertEqual(unattempted[0]["outcome"], "not-run")
        self.assertEqual(unattempted[0]["reason"], "not attempted")

    def test_official_problem_details_keep_skip_reasons_and_require_matching_identity(self):
        payload = {"testIdentifier": "Flow/testFirst()", "testResult": "Skipped", "testRuns": [
            {"nodeType": "Device", "children": [{"nodeType": "Test Plan Configuration", "children": [
                {"nodeType": "Test Case Run", "result": "Skipped", "name": "Test skipped - opt-in is disabled"}]}]}]}
        self.assertEqual(problem_reason(payload, "Flow/testFirst"), "Test skipped - opt-in is disabled")
        for invalid in (dict(payload, testIdentifier="Flow/testOther()"), dict(payload, testRuns=[])):
            with self.subTest(invalid=invalid), self.assertRaises(ContractError):
                problem_reason(invalid, "Flow/testFirst")


class WaitFactorPolicyTests(unittest.TestCase):
    def test_nonfinite_out_of_range_and_non_numeric_factors_are_refused(self):
        from ci_wait_policy import wait_configuration
        for value in (float("nan"), float("inf"), 0, 0.5, 4.01, True, "2", None):
            with self.subTest(value=value), self.assertRaises(ContractError):
                wait_configuration(value)
        for value in (1, 2, 4):
            with self.subTest(value=value):
                self.assertEqual(value, wait_configuration(value)["infrastructure_factor"])
                self.assertEqual(1, wait_configuration(value)["product_factor"])


if __name__ == "__main__":
    unittest.main()
