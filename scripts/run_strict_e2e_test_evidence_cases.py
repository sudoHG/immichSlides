"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations


from run_strict_e2e_test_fixtures import CommandError, Path, WRONG_PUBLIC_API_KEY, choose_exit_code, compressed_byte_coincidence, json, mock, prepare_evidence_directory, reset_simulator_app, run_cleanup_actions, run_command, subprocess, tempfile, write_sensitive_scan

class StrictE2ERunnerTestsCasesEvidence:
    def test_reset_simulator_app_retries_uninstall_and_records_log(self) -> None:
        scenarios = ((0, 0, [10]), (3, 0, [10, 20, 40, 60]),
                     (0, 15, [10, 20]), (0, 54.2, [10, 20, 40, 60]))
        for installed, readiness_timeouts, query_latency, expected_caps in (
                (installed, *scenario) for installed in (False, True) for scenario in scenarios):
            with self.subTest(installed=installed, readiness_timeouts=readiness_timeouts, query_latency=query_latency):
                calls: list[list[str]] = []
                clock = [0.0]
                query_caps = []
                readiness_seconds = []

                def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
                    calls.append(command)
                    result = mock.Mock(returncode=0, stdout="", stderr="")
                    uninstall_count = sum(1 for item in calls if item[2] == "uninstall")
                    if command[2] == "terminate" and not installed:
                        # A cold device must not wait on termination of an app it never installed.
                        raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                    if command[2] == "uninstall" and uninstall_count == 1:
                        result.returncode = 149
                        result.stderr = "Failed to uninstall: Application not found"
                    elif command[2] == "get_app_container":
                        if uninstall_count == 0:
                            self.assertLessEqual(kwargs["timeout"], 60)
                            query_caps.append(kwargs["timeout"])
                            presence_count = sum(item[2] == "get_app_container" for item in calls)
                            duration = kwargs["timeout"] if presence_count <= readiness_timeouts else min(query_latency, kwargs["timeout"])
                            readiness_seconds.append(duration)
                            clock[0] += duration
                            if presence_count <= readiness_timeouts or query_latency > kwargs["timeout"]:
                                raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                        else:
                            clock[0] += query_latency
                        if installed and uninstall_count == 0:
                            result.stdout = "/sim/containers/immichSlides\n"
                        else:
                            result.returncode = 2
                            result.stderr = "No such container"
                    return result

                with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch(
                    "run_strict_e2e.time.sleep"
                ) as sleep, mock.patch("run_strict_e2e.time.monotonic", side_effect=lambda: clock[0]):
                    log = reset_simulator_app("SIM-UDID", platform="tvos")

                self.assertIn("simulator_id=SIM-UDID", log)
                self.assertIn("uninstall_exit=149", log)
                self.assertIn("uninstall_retry_exit=0", log)
                self.assertIn("app_container=absent", log)
                self.assertTrue(any(command[2] == "boot" for command in calls))
                self.assertEqual(sum(command[2] == "terminate" for command in calls), int(installed))
                self.assertEqual(sum(command[2] == "uninstall" for command in calls), 2)
                self.assertEqual(query_caps, expected_caps)
                self.assertEqual(sum(command[2] == "get_app_container" for command in calls), 1 + len(expected_caps))
                self.assertLessEqual(sum(readiness_seconds), 300)
                self.assertTrue(any(command[2] == "keychain" for command in calls))
                self.assertTrue(any(command[2] == "privacy" for command in calls))
                self.assertIn(f"simulator-readiness: passed; attempts={len(expected_caps)}; elapsed={sum(readiness_seconds):.1f}s", log)
                self.assertIn("deadline_overrun=0.0s", log)
                self.assertEqual(sleep.call_args_list, [mock.call(1), mock.call(1)])


    def test_reset_simulator_app_fails_when_container_still_exists(self) -> None:
        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.stderr = ""
            if command[:3] == ["xcrun", "simctl", "get_app_container"]:
                result.returncode = 0
                result.stdout = "/sim/containers/immichSlides\n"
            else:
                result.returncode = 0
                result.stdout = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            with self.assertRaises(CommandError) as raised:
                reset_simulator_app("SIM-UDID", platform="tvos")
        self.assertIn("App container is still accessible after uninstall", str(raised.exception))


    def test_nonempty_evidence_directory_is_rejected_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            evidence.mkdir()
            protected = evidence / "existing.json"
            protected.write_text('{"keep": true}\n', encoding="utf-8")

            with self.assertRaises(CommandError):
                prepare_evidence_directory(evidence)

            self.assertEqual(protected.read_text(encoding="utf-8"), '{"keep": true}\n')
            self.assertEqual([path.name for path in evidence.iterdir()], ["existing.json"])


    def test_sensitive_scan_records_only_key_names_and_rejects_values(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "safe.log").write_text(
                "STRICT_E2E_INPUT_PUBLIC_KEY=<redacted>\n",
                encoding="utf-8",
            )

            write_sensitive_scan(evidence, ["immichslides-public-e2e-key", WRONG_PUBLIC_API_KEY])

            scan_path = evidence / "sensitive-scan.json"
            scan_text = scan_path.read_text(encoding="utf-8")
            scan = json.loads(scan_text)
            self.assertEqual(scan["checked_key_names"], ["STRICT_E2E_INPUT_PUBLIC_KEY"])
            self.assertEqual(scan["matched_files"], [])
            self.assertNotIn("immichslides-public-e2e-key", scan_text)

            derived_data = evidence / "DerivedData"
            derived_data.mkdir()
            (derived_data / "unsafe.log").write_text(WRONG_PUBLIC_API_KEY, encoding="utf-8")
            with self.assertRaises(CommandError):
                write_sensitive_scan(evidence, ["immichslides-public-e2e-key", WRONG_PUBLIC_API_KEY])


    def test_sensitive_scan_rejects_unreadable_directory(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            unreadable = evidence / "unreadable"
            unreadable.mkdir()
            (unreadable / "hidden.log").write_text("hidden", encoding="utf-8")
            unreadable.chmod(0)
            try:
                with self.assertRaises(CommandError):
                    write_sensitive_scan(evidence, [WRONG_PUBLIC_API_KEY])
            finally:
                unreadable.chmod(0o700)


    def test_sensitive_scan_rejects_key_in_skippable_payload(self) -> None:
        logical = b"<?xml version=\"1.0\"?><plist><string>ok</string></plist>"
        skippable = (0x184D2A50).to_bytes(4, "little") + len(WRONG_PUBLIC_API_KEY).to_bytes(
            4, "little"
        ) + WRONG_PUBLIC_API_KEY.encode("utf-8")
        compressed = subprocess.run(
            ["zstd", "-q", "-c"],
            input=logical,
            check=True,
            capture_output=True,
        ).stdout
        blob = skippable + compressed
        self.assertIn(WRONG_PUBLIC_API_KEY.encode("utf-8"), blob)
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "xcresult-data.bin").write_bytes(blob)
            with self.assertRaises(CommandError) as raised:
                write_sensitive_scan(evidence, [WRONG_PUBLIC_API_KEY])
            self.assertNotIn(WRONG_PUBLIC_API_KEY, str(raised.exception))
            scan = json.loads((evidence / "sensitive-scan.json").read_text(encoding="utf-8"))
            self.assertEqual(scan["result"], "FAIL")
            self.assertEqual(scan["matched_files"], ["xcresult-data.bin"])
            self.assertNotIn(WRONG_PUBLIC_API_KEY, (evidence / "sensitive-scan.json").read_text(encoding="utf-8"))


    def test_sensitive_scan_passes_genuinely_compressed_key_pattern_with_clean_content(self) -> None:
        blob, logical, needle = compressed_byte_coincidence()
        self.assertIn(needle.encode(), blob)
        self.assertNotIn(needle.encode(), logical)
        self.assertEqual(subprocess.run(
            ["zstd", "-q", "-d", "-c"], input=blob, capture_output=True, check=True
        ).stdout, logical)
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "xcresult-data.bin").write_bytes(blob)
            write_sensitive_scan(evidence, [needle])
            scan_text = (evidence / "sensitive-scan.json").read_text(encoding="utf-8")
            scan = json.loads(scan_text)
            self.assertEqual(scan["result"], "PASS")
            self.assertEqual(scan["matched_files"], [])
            self.assertNotIn(needle, scan_text)


    def test_sensitive_scan_rejects_key_in_plaintext_tail_with_cli_only_decoder(self) -> None:
        blob = subprocess.run(
            ["zstd", "-q", "-c"], input=b"safe", check=True, capture_output=True
        ).stdout + WRONG_PUBLIC_API_KEY.encode()
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "xcresult-data.bin").write_bytes(blob)
            with mock.patch("run_strict_e2e._zstd_py314", return_value=None), mock.patch(
                "run_strict_e2e._load_libzstd", return_value=None
            ):
                with self.assertRaises(CommandError) as raised:
                    write_sensitive_scan(evidence, [WRONG_PUBLIC_API_KEY])
            self.assertNotIn(WRONG_PUBLIC_API_KEY, str(raised.exception))
            scan_text = (evidence / "sensitive-scan.json").read_text(encoding="utf-8")
            scan = json.loads(scan_text)
            self.assertEqual(scan["result"], "FAIL")
            self.assertEqual(scan["matched_files"], ["xcresult-data.bin"])
            self.assertNotIn(WRONG_PUBLIC_API_KEY, scan_text)


    def test_sensitive_scan_fails_when_decompressed_content_has_key(self) -> None:
        logical = f"key={WRONG_PUBLIC_API_KEY}\n".encode("utf-8")
        blob = subprocess.run(
            ["zstd", "-q", "-c"],
            input=logical,
            check=True,
            capture_output=True,
        ).stdout
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "xcresult-data.bin").write_bytes(blob)
            with self.assertRaises(CommandError) as raised:
                write_sensitive_scan(evidence, [WRONG_PUBLIC_API_KEY])
            self.assertNotIn(WRONG_PUBLIC_API_KEY, str(raised.exception))
            scan = json.loads((evidence / "sensitive-scan.json").read_text(encoding="utf-8"))
            self.assertEqual(scan["result"], "FAIL")
            self.assertEqual(scan["matched_files"], ["xcresult-data.bin"])
            self.assertNotIn(WRONG_PUBLIC_API_KEY, (evidence / "sensitive-scan.json").read_text(encoding="utf-8"))


    def test_cleanup_failure_never_replaces_primary_failure_exit_code(self) -> None:
        completed: list[str] = []

        def fail_cleanup() -> None:
            raise OSError("first cleanup failed")

        failures = run_cleanup_actions(
            [
                ("first", fail_cleanup),
                ("second", lambda: completed.append("second")),
            ]
        )

        self.assertEqual(completed, ["second"])
        self.assertEqual(len(failures), 1)
        self.assertEqual(choose_exit_code(65, ["cleanup failed"]), 65)
        self.assertEqual(choose_exit_code(0, ["cleanup failed"]), 2)
        self.assertEqual(choose_exit_code(0, []), 0)


    def test_run_command_times_out_instead_of_waiting_unbounded(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            log_path = Path(raw_directory) / "xcodebuild.log"
            with mock.patch(
                "run_strict_e2e.subprocess.run",
                return_value=mock.Mock(returncode=0),
            ) as mocked:
                exit_code = run_command(
                    ["xcodebuild", "test"],
                    cwd=Path(raw_directory),
                    environment={"PATH": "/usr/bin"},
                    log_path=log_path,
                )
            self.assertEqual(exit_code, 0)
            timeout = mocked.call_args.kwargs.get("timeout")
            self.assertIsNotNone(timeout)
            self.assertGreaterEqual(timeout, 240)
            self.assertLess(timeout, 600)

            with mock.patch(
                "run_strict_e2e.subprocess.run",
                side_effect=subprocess.TimeoutExpired(cmd=["xcodebuild"], timeout=300),
            ):
                with self.assertRaises(CommandError) as raised:
                    run_command(
                        ["xcodebuild", "test"],
                        cwd=Path(raw_directory),
                        environment={"PATH": "/usr/bin"},
                        log_path=log_path,
                    )
            self.assertIn("timed out", str(raised.exception))
