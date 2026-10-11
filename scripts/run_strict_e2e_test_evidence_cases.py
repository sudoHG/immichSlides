"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations

from run_strict_e2e_test_fixtures import (
    CASE_E2E_IDS,
    CommandError,
    FILTER_PERSON_SESSIONS,
    FROZEN_FIXTURE_SHA256,
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

class StrictE2ERunnerTestsCasesEvidence:
    def test_reset_simulator_app_retries_uninstall_and_records_log(self) -> None:
        for installed in (False, True):
            with self.subTest(installed=installed):
                calls: list[list[str]] = []

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
                        if installed and uninstall_count == 0:
                            result.stdout = "/sim/containers/immichSlides\n"
                        else:
                            result.returncode = 2
                            result.stderr = "No such container"
                    return result

                with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch(
                    "run_strict_e2e.time.sleep"
                ):
                    log = reset_simulator_app("SIM-UDID")

                self.assertIn("simulator_id=SIM-UDID", log)
                self.assertIn("uninstall_exit=149", log)
                self.assertIn("uninstall_retry_exit=0", log)
                self.assertIn("app_container=absent", log)
                self.assertTrue(any(command[2] == "boot" for command in calls))
                self.assertEqual(sum(command[2] == "terminate" for command in calls), int(installed))
                self.assertEqual(sum(command[2] == "uninstall" for command in calls), 2)
                self.assertEqual(sum(command[2] == "get_app_container" for command in calls), 2)
                self.assertTrue(any(command[2] == "keychain" for command in calls))
                self.assertTrue(any(command[2] == "privacy" for command in calls))
                self.assertIn("simulator-app-presence: elapsed=", log)


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
                reset_simulator_app("SIM-UDID")
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
            with mock.patch("access_lifecycle_contract._zstd_py314", return_value=None), mock.patch(
                "access_lifecycle_contract._load_libzstd", return_value=None
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


    def test_sensitive_scan_failure_never_replaces_primary_failure_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            stderr = io.StringIO()
            with (
                mock.patch("run_strict_e2e.data_available_gib", return_value=100),
                mock.patch(
                    "run_strict_e2e.prepare_task_xcconfig",
                    side_effect=CommandError("primary xcodebuild failure", code=65),
                ),
                mock.patch("run_strict_e2e.os.walk", side_effect=OSError("scan traversal failed")),
            ):
                exit_code = runner_main(
                    [
                        "--platform",
                        "ios",
                        "--destination",
                        "platform=iOS Simulator,id=SIM-1",
                        "--evidence-dir",
                        str(evidence),
                    ],
                    stderr=stderr,
                )

            self.assertEqual(exit_code, 65)
            self.assertIn("primary xcodebuild failure", stderr.getvalue())
            self.assertIn("sensitive_scan", stderr.getvalue())


    def test_runner_reports_evidence_io_failure_without_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            blocking_file = Path(raw_directory) / "not-a-directory"
            blocking_file.write_text("keep", encoding="utf-8")
            stderr = io.StringIO()
            with mock.patch("run_strict_e2e.data_available_gib", return_value=100):
                exit_code = runner_main(
                    [
                        "--platform",
                        "ios",
                        "--destination",
                        "platform=iOS Simulator,id=SIM-1",
                        "--evidence-dir",
                        str(blocking_file / "evidence"),
                    ],
                    stderr=stderr,
                )

            self.assertEqual(exit_code, 2)
            self.assertIn("Evidence or process I/O failed", stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())


    def test_tvos_flow_suite_targets_core_playback_and_rejects_ios(self) -> None:
        command = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="tvos",
            destination="platform=tvOS Simulator,id=SIM-tvos",
            derived_data_path=Path("/evidence/tvos/DerivedData"),
            result_bundle_path=Path("/evidence/tvos/strict.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="tvos-flow",
            evidence_dir=Path("/evidence/tvos"),
        )
        self.assertIn(
            "-only-testing:immichSlidesUITests/StrictE2ETVOSFlowUITests/testTVOSFirstBootModeSelectionAndCorePlayback",
            command,
        )
        self.assertIn("STRICT_E2E_EVIDENCE_DIR=/evidence/tvos", command)
        self.assertEqual(result_bundle_name("tvos-flow"), "strict-tvos-flow.xcresult")
        with self.assertRaises(CommandError) as raised:
            build_xcodebuild_command(
                repo_root=Path("/repo"),
                platform="ios",
                destination="platform=iOS Simulator,id=SIM-ios",
                derived_data_path=Path("/evidence/ios/DerivedData"),
                result_bundle_path=Path("/evidence/ios/strict.xcresult"),
                server_url="http://127.0.0.1:12345/api",
                suite="tvos-flow",
            )
        self.assertIn("tvOS flow", str(raised.exception))


    def test_tvos_filter_suites_target_filter_class_and_reject_ios(self) -> None:
        common = {
            "repo_root": Path("/repo"),
            "destination": "platform=tvOS Simulator,id=SIM-tvos",
            "derived_data_path": Path("/evidence/tvos/DerivedData"),
            "result_bundle_path": Path("/evidence/tvos/strict.xcresult"),
            "server_url": "http://127.0.0.1:12345/api",
            "evidence_dir": Path("/evidence/tvos"),
        }
        expected = {
            "tvos-album": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSTargetAlbumPlaybackAndEmptyStart",
            "tvos-edit-switch": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom",
            "tvos-person": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSPersonRules",
            "tvos-switch": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSServerSwitchIsolation",
            "tvos-display-policy": "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSSmartFillDisplayPolicyChangesMultiToSingle",
        }
        for suite, selector in expected.items():
            with self.subTest(suite=suite):
                command = build_xcodebuild_command(platform="tvos", suite=suite, **common)
                self.assertIn(f"-only-testing:{selector}", command)
                self.assertEqual(result_bundle_name(suite), f"strict-{suite}.xcresult")
                with self.assertRaises(CommandError):
                    build_xcodebuild_command(
                        platform="ios",
                        suite=suite,
                        repo_root=Path("/repo"),
                        destination="platform=iOS Simulator,id=SIM-ios",
                        derived_data_path=Path("/evidence/ios/DerivedData"),
                        result_bundle_path=Path("/evidence/ios/strict.xcresult"),
                        server_url="http://127.0.0.1:12345/api",
                    )
        command = build_xcodebuild_command(
            platform="tvos",
            suite="tvos-switch",
            server_b_url="http://127.0.0.1:23456/api",
            **common,
        )
        self.assertIn("STRICT_E2E_INPUT_SERVER_B_URL=http://127.0.0.1:23456/api", command)
        environment = make_test_environment(
            {"PATH": "/bin"},
            server_url="http://127.0.0.1:12345/api",
            public_key="immichslides-public-e2e-key",
            server_b_url="http://127.0.0.1:23456/api",
        )
        self.assertEqual(environment["STRICT_E2E_INPUT_SERVER_B_URL"], "http://127.0.0.1:23456/api")


    def test_late_image_ios_selector_allows_out_of_order(self) -> None:
        self.assertIn("late-image", RUNNER_SUITES)
        self.assertEqual(CASE_E2E_IDS["late-image"], ["E2E-P0-07"])
        self.assertEqual(
            IOS_LATE_IMAGE_SUITES["late-image"],
            "immichSlidesUITests/StrictE2ELateImageIOSUITests/testLateImageKeepsCurrentSceneAfterLateRequest",
        )
        validate_suite_scenario("late-image", "out-of-order")
        with self.assertRaises(CommandError) as raised:
            validate_suite_scenario("late-image", "normal")
        self.assertIn("Invalid combination", str(raised.exception))
        command = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="ios",
            destination="platform=iOS Simulator,id=SIM-ios",
            derived_data_path=Path("/evidence/ios/DerivedData"),
            result_bundle_path=Path("/evidence/ios/strict-late-image.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="late-image",
            scenario="out-of-order",
        )
        self.assertIn(
            "-only-testing:immichSlidesUITests/StrictE2ELateImageIOSUITests/testLateImageKeepsCurrentSceneAfterLateRequest",
            command,
        )
        self.assertIn("STRICT_E2E_INPUT_SCENARIO=out-of-order", command)
        self.assertEqual(result_bundle_name("late-image"), "strict-late-image.xcresult")
        self.assertNotIn("StrictE2ELateImageTVOSUITests", " ".join(command))
        methods = _swift_test_methods("immichSlidesUITests/StrictE2ELateImageIOSUITests.swift")
        self.assertIn("testLateImageKeepsCurrentSceneAfterLateRequest", methods)


    def test_late_image_tvos_selector_allows_out_of_order(self) -> None:
        command = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="tvos",
            destination="platform=tvOS Simulator,id=SIM-tvos",
            derived_data_path=Path("/evidence/tvos/DerivedData"),
            result_bundle_path=Path("/evidence/tvos/strict-late-image.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="late-image",
            scenario="out-of-order",
            evidence_dir=Path("/evidence/tvos"),
        )
        self.assertIn(
            "-only-testing:immichSlidesUITests/StrictE2ELateImageTVOSUITests/testTVOSLateImageDoesNotFlashBack",
            command,
        )
        self.assertIn("STRICT_E2E_INPUT_SCENARIO=out-of-order", command)
        self.assertEqual(result_bundle_name("late-image"), "strict-late-image.xcresult")
        self.assertEqual(
            TVOS_LATE_IMAGE_SUITES["late-image"],
            "immichSlidesUITests/StrictE2ELateImageTVOSUITests/testTVOSLateImageDoesNotFlashBack",
        )
        self.assertNotIn("StrictE2ELateImageIOSUITests", " ".join(command))
        methods = _swift_test_methods("immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift")
        self.assertIn("testTVOSLateImageDoesNotFlashBack", methods)


    def test_xcodebuild_command_never_collects_test_diagnostics(self) -> None:
        command = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="ios",
            destination="platform=iOS Simulator,id=SIM-ios",
            derived_data_path=Path("/evidence/ios/DerivedData"),
            result_bundle_path=Path("/evidence/ios/strict-late-image.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="late-image",
            scenario="out-of-order",
        )
        flag_index = command.index("-collect-test-diagnostics")
        self.assertEqual(command[flag_index + 1], "never")
        self.assertLess(flag_index, command.index("test"))


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


    def test_runner_suite_selectors_equal_swift_test_funcs(self) -> None:
        suites = (
            (
                IOS_FIRST_BATCH_SUITES,
                "immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift",
                "StrictE2EFirstBatchIOSUITests",
            ),
            (
                IOS_FILTER_SUITES,
                "immichSlidesUITests/StrictE2EFilterIOSUITests.swift",
                "StrictE2EFilterIOSUITests",
            ),
            (
                IOS_LATE_IMAGE_SUITES,
                "immichSlidesUITests/StrictE2ELateImageIOSUITests.swift",
                "StrictE2ELateImageIOSUITests",
            ),
            (
                TVOS_FLOW_SUITES,
                "immichSlidesUITests/StrictE2ETVOSFlowUITests.swift",
                "StrictE2ETVOSFlowUITests",
            ),
            (
                TVOS_LATE_IMAGE_SUITES,
                "immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift",
                "StrictE2ELateImageTVOSUITests",
            ),
            (
                TVOS_CONTROL_SUITES,
                "immichSlidesUITests/FilterSummaryTVOSVisualUITests.swift",
                "FilterSummaryTVOSVisualUITests",
            ),
            (
                TVOS_FILTER_SUITES,
                "immichSlidesUITests/StrictE2EFilterTVOSUITests.swift",
                "StrictE2EFilterTVOSUITests",
            ),
        )
        for mapping, swift_file, class_name in suites:
            methods = _swift_test_methods(swift_file)
            for suite, selector in mapping.items():
                with self.subTest(suite=suite):
                    prefix = f"immichSlidesUITests/{class_name}/"
                    self.assertTrue(selector.startswith(prefix), selector)
                    method = selector[len(prefix) :]
                    self.assertIn(method, methods)


    def test_filter_suites_forward_peer_url_and_accept_simulator_vision_unverified(self) -> None:
        command = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="ios",
            destination="platform=iOS Simulator,id=SIM-ios",
            derived_data_path=Path("/evidence/ios/DerivedData"),
            result_bundle_path=Path("/evidence/ios/strict.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="filter-switch",
            evidence_dir=Path("/evidence/ios"),
            server_url_b="http://127.0.0.1:12346/api",
        )
        self.assertIn(
            "-only-testing:immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterServerSwitchIsolation",
            command,
        )
        self.assertIn("STRICT_E2E_INPUT_SERVER_URL_B=http://127.0.0.1:12346/api", command)
        environment = make_test_environment(
            {},
            server_url="http://127.0.0.1:12345/api",
            public_key="immichslides-public-e2e-key",
            server_url_b="http://127.0.0.1:12346/api",
        )
        self.assertEqual(environment["STRICT_E2E_INPUT_SERVER_URL_B"], "http://127.0.0.1:12346/api")
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            write_member_manifest(evidence / "member-manifest.json", "a")
            (evidence / "vision-environment.json").write_text(
                json.dumps({"environment": "simulator", "vision_available": True}),
                encoding="utf-8",
            )
            report = require_visual_identity(evidence, "filter-vision")
            self.assertEqual(report["verdict"], "UNVERIFIED")
            self.assertNotEqual(report["verdict"], "PASS")


    def test_out_of_order_runner_audit_and_identity_fail_closed(self) -> None:
        with self.assertRaises(CommandError) as raised:
            audit_out_of_order_runner_inputs(
                fixture_set="a",
                observed_hash=FROZEN_FIXTURE_SHA256["a"],
                service_log=(
                    "request elapsed_ms=1 method=GET path=/unknown-route "
                    "status=404 range=absent fixture_asset_id=none\n"
                ),
                server_url="http://127.0.0.1:9/api",
            )
        self.assertIn("Unknown request", str(raised.exception))

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            with self.assertRaises(CommandError) as raised:
                require_visual_identity(evidence, "late-image")
            self.assertIn("Visual assertion failed; cannot mark SUCCESS", str(raised.exception))
            self.assertIn("Missing required timeline screenshots", str(raised.exception))
            report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(report["verdict"], "FAIL")

            current = _fixture_data("a")["images"]["asset-a-3"]
            (evidence / "ooo-current-scene.png").write_bytes(current)
            (evidence / "ooo-after-late.png").write_bytes(current)
            (evidence / "redacted-request.log").write_text(
                "request_started elapsed_ms=10 method=GET path=/api/assets/<fixture-id>/thumbnail "
                "size=preview range=absent fixture_asset_id=asset-a-1\n"
                "request_started elapsed_ms=40 method=GET path=/api/assets/<fixture-id>/thumbnail "
                "size=preview range=absent fixture_asset_id=asset-a-2\n"
                "request elapsed_ms=45 method=GET path=/api/assets/<fixture-id>/thumbnail "
                "status=200 range=absent fixture_asset_id=asset-a-2\n"
                "request elapsed_ms=320 method=GET path=/api/assets/<fixture-id>/thumbnail "
                "status=200 range=absent fixture_asset_id=asset-a-1\n",
                encoding="utf-8",
            )
            write_fixture_artifacts(evidence, "a")
            (evidence / "runner-server-url.txt").write_text("http://127.0.0.1:9/api\n", encoding="utf-8")
            report = require_visual_identity(evidence, "late-image")
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["mark"], "A3")
            self.assertEqual(report["identity_source"], "public_fixture_photo_mark")

            (evidence / "ooo-after-late.png").write_bytes(_fixture_data("a")["images"]["asset-a-1"])
            with self.assertRaises(CommandError) as flashback:
                require_visual_identity(evidence, "late-image")
            self.assertIn("Wrong image", str(flashback.exception))
            flashback_report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(flashback_report["verdict"], "FAIL")


    def test_visual_identity_blocks_success_when_screenshots_are_missing_or_wrong(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            skipped = require_visual_identity(evidence, "smoke")
            self.assertEqual(skipped["verdict"], "NOT_REQUIRED")
            with self.assertRaises(CommandError) as raised:
                require_visual_identity(evidence, "journey-b")
            self.assertIn("Visual assertion failed; cannot mark SUCCESS", str(raised.exception))
            report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(report["verdict"], "FAIL")

            with self.assertRaises(CommandError) as raised:
                require_visual_identity(evidence, "tvos-album")
            self.assertIn("Visual assertion failed; cannot mark SUCCESS", str(raised.exception))

            with self.assertRaises(CommandError) as raised:
                require_visual_identity(evidence, "tvos-person")
            self.assertIn("Visual assertion failed; cannot mark SUCCESS", str(raised.exception))


    def test_pause_window_rejects_wrong_or_unreadable_window_detected(self) -> None:
        a5 = _fixture_data("a")["images"]["asset-a-5"]
        cases = {
            "black": _rgb_png((0, 0, 0)),
            "blank": _rgb_png((255, 255, 255)),
            "unrecognizable": b"not-a-png",
            "wrong-photo": a5,
        }
        for label, window_png in cases.items():
            with self.subTest(window=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                _write_pause_window_evidence(evidence, window_png)
                with self.assertRaises(CommandError) as raised:
                    require_visual_identity(evidence, "pause-window")
                self.assertIn("Visual assertion failed; cannot mark SUCCESS", str(raised.exception))
                self.assertIn("Target window", str(raised.exception))
                report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
                self.assertEqual(report["verdict"], "FAIL")


    def test_help_and_smoke_do_not_need_pillow(self) -> None:
        help_result = _run_runner_without_site("--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertNotIn("ModuleNotFoundError", help_result.stderr)
        self.assertNotIn("No module named 'PIL'", help_result.stderr + help_result.stdout)
        self.assertIn("usage:", help_result.stdout.lower())

        smoke = _run_code_without_site(
            "\n".join(
                [
                    "import sys, tempfile",
                    "from pathlib import Path",
                    "sys.path.insert(0, sys.argv[1])",
                    "from run_strict_e2e import require_visual_identity",
                    "report = require_visual_identity(Path(tempfile.mkdtemp()), 'smoke')",
                    "assert report['verdict'] == 'NOT_REQUIRED', report",
                    "print('SMOKE_OK')",
                ]
            )
        )
        self.assertEqual(smoke.returncode, 0, smoke.stderr)
        self.assertIn("SMOKE_OK", smoke.stdout)
        self.assertNotIn("ModuleNotFoundError", smoke.stderr)
        self.assertNotIn("No module named 'PIL'", smoke.stderr + smoke.stdout)


    def test_visual_suite_without_pillow_fails_with_install_hint(self) -> None:
        result = _run_code_without_site(
            "\n".join(
                [
                    "import sys, tempfile",
                    "from pathlib import Path",
                    "sys.path.insert(0, sys.argv[1])",
                    "from run_strict_e2e import CommandError, require_visual_identity",
                    "from strict_e2e_server import _fixture_data",
                    "png = _fixture_data('a')['images']['asset-a-2']",
                    "evidence = Path(tempfile.mkdtemp())",
                    "for name in ('window-detected', 'after-pause', 'after-pause-0_3s'):",
                    "    (evidence / f'{name}.png').write_bytes(png)",
                    "try:",
                    "    require_visual_identity(evidence, 'pause-window')",
                    "except CommandError as error:",
                    "    text = str(error)",
                    "    print(text)",
                    "    raise SystemExit(0 if 'Pillow' in text else 2)",
                    "print('UNEXPECTED_PASS')",
                    "raise SystemExit(3)",
                ]
            )
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Pillow", result.stdout)
        self.assertNotIn("UNEXPECTED_PASS", result.stdout)
        self.assertNotIn("Traceback", result.stderr)


    def test_official_count_requires_exactly_one_non_skipped_pass(self) -> None:
        require_official_single_pass(TestResultsSummary(1, 1, 0, 0, "Passed"))
        for summary in (
            TestResultsSummary(0, 0, 0, 0, "Passed"),
            TestResultsSummary(1, 0, 0, 1, "Passed"),
            TestResultsSummary(1, 0, 1, 0, "Failed"),
        ):
            with self.subTest(summary=summary), self.assertRaises(CommandError):
                require_official_single_pass(summary)
