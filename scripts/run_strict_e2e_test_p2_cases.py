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

class StrictE2EP2RunnerTestsCases:
    def test_p2_suites_route_to_selected_method_and_record_e2e_ids(self) -> None:
        common = {
            "repo_root": Path("/repo"),
            "derived_data_path": Path("/evidence/DerivedData"),
            "result_bundle_path": Path("/evidence/strict.xcresult"),
            "server_url": "http://127.0.0.1:12345/api",
            "evidence_dir": Path("/evidence"),
        }
        for suite, case in P2_CASES.items():
            self.assertIn(suite, RUNNER_SUITES)
            self.assertEqual(result_bundle_name(suite), f"strict-{suite}.xcresult")
            self.assertEqual(CASE_E2E_IDS[suite], list(case.e2e_ids))
            validate_suite_scenario(suite, "normal")
            for platform, selector in case.selectors.items():
                with self.subTest(suite=suite, platform=platform):
                    destination = f"platform={'tvOS' if platform == 'tvos' else 'iOS'} Simulator,id=SIM"
                    command = build_xcodebuild_command(
                        platform=platform, destination=destination, suite=suite, **common
                    )
                    self.assertEqual([item for item in command if item.startswith("-only-testing:")], [f"-only-testing:{selector}"])
                    self.assertIn("STRICT_E2E_EVIDENCE_DIR=/evidence", command)
        with self.assertRaises(CommandError):
            build_xcodebuild_command(
                platform="tvos", destination="platform=tvOS Simulator,id=SIM", suite="p2-rotation", **common
            )
        with self.assertRaises(CommandError):
            validate_suite_scenario("p2-cache", "timeout")


    def test_wrong_platform_or_scenario_fails_before_any_side_effect(self) -> None:
        for arguments in (
            ["--platform", "tvos", "--destination", "platform=tvOS Simulator,id=SIM", "--suite", "p2-ipad-layout"],
            ["--platform", "tvos", "--destination", "platform=tvOS Simulator,id=SIM", "--suite", "p2-rotation"],
            ["--platform", "tvos", "--destination", "platform=tvOS Simulator,id=SIM", "--suite", "image-failure-recovery"],
            ["--platform", "ios", "--destination", "platform=iOS Simulator,id=SIM", "--suite", "p2-exif", "--scenario", "timeout"],
        ):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory) / "evidence"
                stderr = io.StringIO()
                with mock.patch("run_strict_e2e.data_available_gib") as disk, mock.patch(
                    "run_strict_e2e.reset_simulator_app"
                ) as reset:
                    exit_code = runner_main([*arguments, "--evidence-dir", str(evidence)], stderr=stderr)
                self.assertEqual(exit_code, 2)
                self.assertFalse(evidence.exists())
                disk.assert_not_called()
                reset.assert_not_called()
                self.assertTrue(stderr.getvalue().strip())


    def test_source_dirty_paths_come_from_git_porcelain_and_fail_closed(self) -> None:
        with mock.patch(
            "run_strict_e2e.subprocess.run",
            return_value=subprocess.CompletedProcess([], 0, " M scripts/a.py\n?? scripts/new.py\n", ""),
        ) as mocked:
            self.assertEqual(read_source_dirty_paths(Path("/repo")), [" M scripts/a.py", "?? scripts/new.py"])
        self.assertEqual(
            mocked.call_args.args[0],
            ["git", "-C", "/repo", "status", "--porcelain=v1", "--untracked-files=all"],
        )
        with mock.patch(
            "run_strict_e2e.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "", "")
        ):
            self.assertEqual(read_source_dirty_paths(Path("/repo")), [])
        with mock.patch(
            "run_strict_e2e.subprocess.run", return_value=subprocess.CompletedProcess([], 128, "", "fatal")
        ), self.assertRaises(CommandError):
            read_source_dirty_paths(Path("/repo"))


    def test_screen_recording_waits_for_start_and_sigints_the_exact_process(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            video = Path(raw_directory) / "screen-recording.mov"
            log = Path(raw_directory) / "screen-recording.log"
            process = mock.Mock(pid=4321)
            process.poll.return_value = None
            process.wait.return_value = 0

            def fake_popen(command: list[str], **kwargs: object) -> mock.Mock:
                kwargs["stdout"].write(b"Recording started\n")
                return process

            with mock.patch("run_strict_e2e.subprocess.Popen", side_effect=fake_popen) as popen:
                started_process, started_wall_time = start_screen_recording("SIM-1", video, log)
            self.assertIs(started_process, process)
            self.assertGreater(started_wall_time, 0)
            self.assertEqual(
                popen.call_args.args[0],
                ["xcrun", "simctl", "io", "SIM-1", "recordVideo", "--codec=h264", "--force", str(video)],
            )

            self.assertEqual(stop_screen_recording(process), 0)
            process.send_signal.assert_called_once_with(signal.SIGINT)
            process.terminate.assert_not_called()
            process.kill.assert_not_called()

            stuck = mock.Mock(pid=4322)
            stuck.poll.return_value = None
            stuck.wait.side_effect = [subprocess.TimeoutExpired(cmd="simctl", timeout=1), -9]
            with self.assertRaises(CommandError) as raised:
                stop_screen_recording(stuck)
            self.assertIn("recording", str(raised.exception))
            stuck.kill.assert_called_once()

            silent = mock.Mock(pid=4323)
            silent.poll.return_value = None
            silent.wait.return_value = 0
            with mock.patch("run_strict_e2e.subprocess.Popen", return_value=silent), mock.patch(
                "run_strict_e2e.RECORDING_START_TIMEOUT_SECONDS", 0.2
            ), self.assertRaises(CommandError):
                start_screen_recording("SIM-1", video, log)
            self.assertTrue(silent.send_signal.called or silent.terminate.called or silent.kill.called)

            exited = mock.Mock(pid=4324, returncode=1)
            exited.poll.return_value = 1
            with mock.patch("run_strict_e2e.subprocess.Popen", return_value=exited), self.assertRaises(
                CommandError
            ) as raised:
                start_screen_recording("SIM-1", video, log)
            self.assertIn("exit 1", str(raised.exception))

            unreadable = mock.Mock(pid=4325)
            unreadable.poll.return_value = None
            unreadable.wait.return_value = 0
            with mock.patch("run_strict_e2e.subprocess.Popen", return_value=unreadable), mock.patch.object(
                Path, "read_bytes", side_effect=OSError("log unreadable")
            ), self.assertRaises(OSError):
                start_screen_recording("SIM-1", video, log)
            unreadable.terminate.assert_called_once()

            ended_early = mock.Mock(pid=4326, returncode=0)
            ended_early.poll.return_value = 0
            with self.assertRaises(CommandError) as raised:
                stop_screen_recording(ended_early)
            self.assertIn("before the test finished", str(raised.exception))
            ended_early.send_signal.assert_not_called()


    def test_p2_main_runs_selected_method_and_only_reports_review_required(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "p2-exif-iphone"
            exit_code, _stdout, stderr, mocks = self._run_p2_main(
                evidence, suite="p2-exif", platform="ios", model="iPhone 17 Pro"
            )
            self.assertEqual(exit_code, 0, stderr)
            manifest = json.loads((evidence / "case-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["suite"], "p2-exif")
            self.assertEqual(manifest["source_dirty_paths"], [])
            self.assertEqual(manifest["e2e_ids"], ["E2E-P2-01"])
            self.assertEqual(manifest["result"], "Passed")
            self.assertEqual(manifest["human_review"], "NOT_RUN")
            self.assertEqual(manifest["executed_tests"], ["ExifToggleUITests/testExifToggleOwnershipIOS()"])
            self.assertEqual(manifest["device"]["udid"], P2_UDID)
            report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
            self.assertEqual(report["verdict"], RAW_VERDICT)
            self.assertNotEqual(report["verdict"], "PASS")
            self.assertEqual(report["execution"]["executed_tests"], ["ExifToggleUITests/testExifToggleOwnershipIOS()"])
            self.assertEqual(report["execution"]["device"]["class"], "iphone")
            facts_path = mocks["facts"].call_args.args[0]
            self.assertEqual(facts_path.name, "strict-p2-exif.xcresult")
            self.assertEqual(facts_path.parent.parent, evidence.parent / "private")
            mocks["start"].assert_not_called()
            self.assertTrue((evidence / "sensitive-scan.json").is_file())


    def test_p2_main_fails_closed_on_missing_png_or_other_simulator(self) -> None:
        for label, kwargs in (
            ("Missing PNG", {"skip": ("exif-off",)}),
            ("Official results came from another simulator", {"facts_device_id": "SIM-OTHER"}),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory) / "p2-exif-ipad"
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPad Pro 13-inch (M5)",
                    **kwargs,
                )
                self.assertEqual(exit_code, 2)
                self.assertNotIn("Traceback", stderr)
                manifest = json.loads((evidence / "case-manifest.json").read_text(encoding="utf-8"))
                self.assertEqual(manifest["result"], "FAILED")
                if label == "Missing PNG":
                    self.assertIn("exif-off.png", stderr)
                    report = json.loads((evidence / "visual-identity-runner.json").read_text(encoding="utf-8"))
                    self.assertEqual(report["verdict"], "FAIL")


    def test_p2_video_case_records_whole_run_and_stops_even_when_xcodebuild_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "p2-reduce-motion-tv"
            exit_code, _stdout, stderr, mocks = self._run_p2_main(
                evidence,
                suite="p2-reduce-motion",
                platform="tvos",
                model="Apple TV 4K (3rd generation)",
            )
            self.assertEqual(exit_code, 0, stderr)
            mocks["start"].assert_called_once_with(
                P2_UDID, evidence / "screen-recording.mov", evidence / "screen-recording.log"
            )
            mocks["stop"].assert_called_once_with(mocks["recording_process"])
            timing = json.loads((evidence / "screen-recording-timing.json").read_text(encoding="utf-8"))
            self.assertEqual(timing["started_wall_time"], 900.0)
            self.assertEqual(timing["stop_exit"], 0)
            self.assertGreater(timing["stopped_wall_time"], timing["started_wall_time"])

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "p2-rotation-iphone"
            exit_code, _stdout, _stderr, mocks = self._run_p2_main(
                evidence,
                suite="p2-rotation",
                platform="ios",
                model="iPhone 17 Pro",
                xcodebuild_exit=65,
            )
            self.assertEqual(exit_code, 65)
            mocks["stop"].assert_called_once_with(mocks["recording_process"])


    def test_p2_result_bundle_is_private_on_failure_and_disposed_only_after_success(self) -> None:
        for label, xcodebuild_exit, export_exit, expected_exit in (
            ("test-failed", 65, 0, 65),
            ("export-failed", 0, 1, 2),
            ("success", 0, 0, 0),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                root = Path(raw_directory)
                evidence = root / "evidence"
                private_root = root / "private"
                with mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", private_root):
                    exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                        evidence,
                        suite="p2-exif",
                        platform="ios",
                        model="iPhone 17 Pro",
                        xcodebuild_exit=xcodebuild_exit,
                        create_result_bundle=True,
                        export_exit=export_exit,
                    )
                self.assertEqual(exit_code, expected_exit, stderr)
                self.assertFalse((evidence / "strict-p2-exif.xcresult").exists())
                self.assertEqual(json.loads((evidence / "sensitive-scan.json").read_text())["result"], "PASS")
                if expected_exit == 0:
                    self.assertEqual(list(private_root.rglob("raw.bin")), [])
                    self.assertTrue((evidence / "result-bundle-disposal.json").is_file())
                else:
                    quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
                    self.assertEqual(Path(quarantine["private_path"]).joinpath("raw.bin").read_bytes(), b"raw diagnostics")
                    self.assertEqual(len(list(private_root.rglob("raw.bin"))), 1)
                    self.assertFalse((evidence / "result-bundle-disposal.json").exists())

        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            evidence = root / "evidence"
            private_root = root / "private"
            with mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", private_root), mock.patch(
                "run_strict_e2e.write_sensitive_scan", side_effect=CommandError("scan failed")
            ):
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPhone 17 Pro",
                    create_result_bundle=True,
                )
            self.assertEqual(exit_code, 2, stderr)
            self.assertIn("sensitive_scan", stderr)
            failures = json.loads((evidence / "cleanup-failures.json").read_text())["failures"]
            self.assertTrue(any(failure.startswith("sensitive_scan:") for failure in failures))
            quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
            self.assertEqual(Path(quarantine["private_path"]).joinpath("raw.bin").read_bytes(), b"raw diagnostics")
            self.assertFalse((evidence / "result-bundle-disposal.json").exists())


    def test_p2_bundle_is_private_even_when_isolation_step_fails(self) -> None:
        for suite in ("p2-exif", "image-failure-recovery"):
            with self.subTest(suite=suite), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory) / "evidence"
                with mock.patch("run_strict_e2e.shutil.move", side_effect=OSError("move denied")) as move:
                    exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                        evidence,
                        suite=suite,
                        platform="ios",
                        model="iPhone 17 Pro",
                        xcodebuild_exit=65,
                        create_result_bundle=True,
                    )
                self.assertEqual(exit_code, 65, stderr)
                move.assert_not_called()
                self.assertFalse((evidence / result_bundle_name(suite)).exists())
                quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
                self.assertEqual(Path(quarantine["private_path"]).joinpath("raw.bin").read_bytes(), b"raw diagnostics")


    def test_p2_disposal_record_failure_preserves_private_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            write_text = Path.write_text

            def fail_disposal_record(path: Path, content: str, **kwargs: object) -> int:
                if path.name == "result-bundle-disposal.json":
                    raise OSError("record denied")
                return write_text(path, content, **kwargs)

            with mock.patch.object(Path, "write_text", fail_disposal_record):
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPhone 17 Pro",
                    create_result_bundle=True,
                )
            self.assertEqual(exit_code, 2, stderr)
            self.assertIn("dispose_private_result_bundle", stderr)
            self.assertFalse((evidence / "result-bundle-disposal.json").exists())
            quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
            self.assertEqual(Path(quarantine["private_path"]).joinpath("raw.bin").read_bytes(), b"raw diagnostics")


    def test_p2_private_directory_failure_stops_before_xcodebuild(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            with mock.patch(
                "run_strict_e2e.prepare_private_result_bundle_path", side_effect=OSError("private denied")
            ), mock.patch("run_strict_e2e.run_command") as run_command:
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPhone 17 Pro",
                )
            self.assertEqual(exit_code, 2, stderr)
            run_command.assert_not_called()
            self.assertFalse((evidence / "strict-p2-exif.xcresult").exists())


    def test_p2_disposal_failure_keeps_private_bundle_indexed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            remove_tree = shutil.rmtree

            def fail_private_disposal(path: Path, *args: object, **kwargs: object) -> None:
                if str(path).endswith(".xcresult"):
                    raise OSError("dispose denied")
                remove_tree(path, *args, **kwargs)

            with mock.patch("run_strict_e2e.shutil.rmtree", side_effect=fail_private_disposal):
                exit_code, _stdout, stderr, _mocks = self._run_p2_main(
                    evidence,
                    suite="p2-exif",
                    platform="ios",
                    model="iPhone 17 Pro",
                    create_result_bundle=True,
                )
            self.assertEqual(exit_code, 2, stderr)
            self.assertIn("dispose_private_result_bundle", stderr)
            self.assertFalse((evidence / "result-bundle-disposal.json").exists())
            quarantine = json.loads((evidence / "result-bundle-quarantine.json").read_text())
            self.assertEqual(Path(quarantine["private_path"]).joinpath("raw.bin").read_bytes(), b"raw diagnostics")
