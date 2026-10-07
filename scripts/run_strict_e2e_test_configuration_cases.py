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

class StrictE2ERunnerTestsCasesConfiguration:
    def test_private_result_bundles_use_the_system_temporary_directory(self) -> None:
        self.assertEqual(
            PRIVATE_RESULT_BUNDLE_ROOT,
            Path(tempfile.gettempdir()) / "immichSlides-strict-e2e-private",
        )
        with tempfile.TemporaryDirectory() as raw_directory:
            private_root = Path(raw_directory) / "private"
            with mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", private_root):
                bundle_path = prepare_private_result_bundle_path("smoke")
            self.assertEqual(bundle_path.parent.parent, private_root)
            self.assertEqual(stat.S_IMODE(private_root.stat().st_mode), 0o700)


    def test_default_minimum_free_space_is_80_gib(self) -> None:
        self.assertEqual(MIN_DATA_GIB, 80)
        with tempfile.TemporaryDirectory() as temporary_directory:
            stderr = io.StringIO()
            with mock.patch("run_strict_e2e.data_available_gib", return_value=79.9), mock.patch(
                "run_strict_e2e.prepare_evidence_directory",
                side_effect=AssertionError("low disk must stop before evidence setup"),
            ):
                exit_code = runner_main(
                    [
                        "--platform", "ios",
                        "--destination", "platform=iOS Simulator,id=SIM",
                        "--evidence-dir", str(Path(temporary_directory) / "evidence"),
                    ],
                    stderr=stderr,
                )
        self.assertEqual(exit_code, 2)
        self.assertIn("--min-free-gib", stderr.getvalue())


    def test_custom_minimum_free_space_is_respected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            stderr = io.StringIO()
            with mock.patch("run_strict_e2e.data_available_gib", return_value=75), mock.patch(
                "run_strict_e2e.prepare_evidence_directory",
                side_effect=CommandError("reached post-disk setup"),
            ) as prepare_evidence:
                exit_code = runner_main(
                    [
                        "--platform", "ios",
                        "--destination", "platform=iOS Simulator,id=SIM",
                        "--evidence-dir", str(Path(temporary_directory) / "evidence"),
                        "--min-free-gib", "70",
                    ],
                    stderr=stderr,
                )
        self.assertEqual(exit_code, 2)
        self.assertIn("reached post-disk setup", stderr.getvalue())
        prepare_evidence.assert_called_once()


    def test_lifecycle_wrong_platform_fails_before_evidence_or_runtime_setup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            evidence = Path(temporary_directory) / "evidence"
            stderr = io.StringIO()
            with mock.patch(
                "run_strict_e2e.prepare_evidence_directory",
                side_effect=AssertionError("evidence setup must not run"),
            ) as prepare_evidence, mock.patch(
                "run_strict_e2e.write_fixture_artifacts",
                side_effect=AssertionError("fixture service setup must not run"),
            ) as write_fixture, mock.patch(
                "run_strict_e2e.reset_simulator_app",
                side_effect=AssertionError("simulator reset must not run"),
            ) as reset_app, mock.patch(
                "run_strict_e2e.subprocess.Popen",
                side_effect=AssertionError("fixture service must not start"),
            ) as start_process:
                exit_code = runner_main(
                    [
                        "--platform", "tvos",
                        "--destination", "platform=tvOS Simulator,id=TEST",
                        "--suite", "ios-lifecycle-settings",
                        "--evidence-dir", str(evidence),
                    ],
                    stderr=stderr,
                )

            self.assertNotEqual(exit_code, 0)
            self.assertIn("can only run on the ios platform", stderr.getvalue())
            prepare_evidence.assert_not_called()
            write_fixture.assert_not_called()
            reset_app.assert_not_called()
            start_process.assert_not_called()
            self.assertFalse(evidence.exists())


    def test_lifecycle_entries_run_existing_release_methods_and_reject_wrong_inputs(self) -> None:
        from run_strict_e2e import IOS_CASES, TVOS_CASES

        for platform, mapping in (("ios", IOS_CASES), ("tvos", TVOS_CASES)):
            for case, selector in mapping.items():
                suite = f"{platform}-lifecycle-{case}"
                with self.subTest(suite=suite):
                    self.assertIn(suite, RUNNER_SUITES)
                    validate_suite_scenario(suite, "normal")
                    with self.assertRaises(CommandError):
                        validate_suite_scenario(suite, "auth-401")
                    with self.assertRaises(CommandError):
                        validate_suite_fixture(suite, "b")
                    arguments = dict(
                        repo_root=REPO_ROOT, platform=platform, suite=suite,
                        destination="platform=iOS Simulator,id=TEST",
                        derived_data_path=Path("/evidence/DerivedData"),
                        result_bundle_path=Path("/evidence/result.xcresult"),
                        server_url="http://127.0.0.1:12345/api",
                    )
                    command = build_xcodebuild_command(**arguments)
                    self.assertIn(f"-only-testing:{selector}", command)
                    self.assertEqual(command[command.index("-configuration") + 1], "Release")
                    self.assertEqual(command[command.index("-scheme") + 1], f"immichSlides-{'iOS' if platform == 'ios' else 'tvOS'}-settings-resume")
                    self.assertIn("-skip-testing:immichSlidesTests", command)
                    target, class_name, method = selector.split("/")
                    self.assertIn(method, _swift_test_methods(f"{target}/{class_name}.swift"))
                    arguments["platform"] = "tvos" if platform == "ios" else "ios"
                    with self.assertRaises(CommandError):
                        build_xcodebuild_command(**arguments)


    def test_display_policy_suites_are_single_fixture_a_only(self) -> None:
        for suite in ("display-policy", "tvos-display-policy"):
            with self.subTest(suite=suite):
                validate_suite_fixture(suite, "a")
                with self.assertRaises(CommandError) as raised:
                    validate_suite_fixture(suite, "b")
                self.assertIn("must use public fixture A", str(raised.exception))
                self.assertEqual(CASE_E2E_IDS[suite], ["display-policy"])


    def test_tvos_album_suite_is_fixture_a_only(self) -> None:
        validate_suite_fixture("tvos-album", "a")
        with self.assertRaises(CommandError) as raised:
            validate_suite_fixture("tvos-album", "b")
        self.assertIn("must use public fixture A", str(raised.exception))


    def test_album_edit_switch_is_routed_as_a_normal_visual_ui_suite(self) -> None:
        expected = {
            "ios": (
                "filter-edit-switch",
                "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom",
            ),
            "tvos": (
                "tvos-edit-switch",
                "immichSlidesUITests/StrictE2EFilterTVOSUITests/testTVOSFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom",
            ),
        }
        common = {
            "repo_root": Path("/repo"),
            "derived_data_path": Path("/evidence/DerivedData"),
            "result_bundle_path": Path("/evidence/strict.xcresult"),
            "server_url": "http://127.0.0.1:12345/api",
            "evidence_dir": Path("/evidence"),
        }
        for platform, (suite, selector) in expected.items():
            with self.subTest(platform=platform):
                suites = IOS_FILTER_SUITES if platform == "ios" else TVOS_FILTER_SUITES
                self.assertEqual(suites.get(suite), selector)
                self.assertIn(suite, RUNNER_SUITES)
                self.assertEqual(CASE_E2E_IDS.get(suite), ["E2E-P0-04"])
                validate_suite_scenario(suite, "normal")
                with self.assertRaises(CommandError):
                    validate_suite_scenario(suite, "auth-401")
                command = build_xcodebuild_command(
                    **{
                        **common,
                        "destination": f"platform={'iOS' if platform == 'ios' else 'tvOS'} Simulator,id=SIM-{platform}",
                    },
                    platform=platform,
                    suite=suite,
                )
                self.assertIn(f"-only-testing:{selector}", command)
                self.assertIn("immichSlides-iOS-settings-resume" if platform == "ios" else "immichSlides-tvOS-settings-resume", command)
                self.assertIn("-configuration", command)
                self.assertIn("Release", command)
                self.assertIn("-skip-testing:immichSlidesTests", command)
                self.assertEqual(result_bundle_name(suite), f"strict-{suite}.xcresult")


    def test_settings_observing_suites_use_release_settings_resume_scheme(self) -> None:
        cases = (
            ("ios", "filter-edit-switch", "immichSlides-iOS-settings-resume"),
            ("ios", "filter-switch", "immichSlides-iOS-settings-resume"),
            ("ios", "display-policy", "immichSlides-iOS-settings-resume"),
            ("tvos", "tvos-edit-switch", "immichSlides-tvOS-settings-resume"),
            ("tvos", "tvos-switch", "immichSlides-tvOS-settings-resume"),
            ("tvos", "tvos-display-policy", "immichSlides-tvOS-settings-resume"),
        )
        for platform, suite, expected_scheme in cases:
            with self.subTest(platform=platform, suite=suite):
                command = build_xcodebuild_command(
                    repo_root=Path("/repo"),
                    platform=platform,
                    destination=f"platform={'iOS' if platform == 'ios' else 'tvOS'} Simulator,id=SIM-{platform}",
                    derived_data_path=Path("/evidence/DerivedData"),
                    result_bundle_path=Path("/evidence/strict.xcresult"),
                    server_url="http://127.0.0.1:12345/api",
                    suite=suite,
                )
                scheme_index = command.index("-scheme") + 1
                self.assertEqual(command[scheme_index], expected_scheme)
                self.assertEqual(command[command.index("-configuration") + 1], "Release")
                self.assertIn("-skip-testing:immichSlidesTests", command)
                self.assertIn("-parallel-testing-enabled", command)
                self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "NO")

        ordinary = build_xcodebuild_command(
            repo_root=Path("/repo"),
            platform="ios",
            destination="platform=iOS Simulator,id=SIM-ios",
            derived_data_path=Path("/evidence/DerivedData"),
            result_bundle_path=Path("/evidence/strict.xcresult"),
            server_url="http://127.0.0.1:12345/api",
            suite="filter-album",
        )
        self.assertEqual(ordinary[ordinary.index("-scheme") + 1], "immichSlides-iOS")
        self.assertNotIn("-configuration", ordinary)
        self.assertNotIn("-skip-testing:immichSlidesTests", ordinary)


    def test_task_xcconfig_is_copied_only_from_managed_example_and_flags_are_zero(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            example = root / "env.example.xcconfig"
            destination = root / "env.xcconfig"
            example.write_text(
                "IMMICH_SERVER_URL = https://your-server.example.com/api\n"
                "IMMICH_API_KEY = YOUR_API_KEY\n"
                "ENABLE_DEBUG_AUTO_SERVER = 0\n"
                "ENABLE_DEBUG_FILL_APIKEY_BUTTON = 0\n",
                encoding="utf-8",
            )

            audit = prepare_task_xcconfig(example, destination)

            self.assertEqual(destination.read_bytes(), example.read_bytes())
            self.assertEqual(audit["ENABLE_DEBUG_AUTO_SERVER"], "0")
            self.assertEqual(audit["ENABLE_DEBUG_FILL_APIKEY_BUTTON"], "0")
            self.assertEqual(len(audit["source_sha256"]), 64)


    def test_existing_or_unsafe_xcconfig_fails_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            example = root / "env.example.xcconfig"
            destination = root / "env.xcconfig"
            example.write_text(
                "ENABLE_DEBUG_AUTO_SERVER = 1\nENABLE_DEBUG_FILL_APIKEY_BUTTON = 0\n",
                encoding="utf-8",
            )
            destination.write_text("PRIVATE = keep\n", encoding="utf-8")

            with self.assertRaises(CommandError):
                prepare_task_xcconfig(example, destination)
            self.assertEqual(destination.read_text(encoding="utf-8"), "PRIVATE = keep\n")

            destination.unlink()
            with self.assertRaises(CommandError):
                prepare_task_xcconfig(example, destination)
            self.assertFalse(destination.exists())


    def test_cleanup_only_deletes_unchanged_copy_of_managed_example(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            example = root / "env.example.xcconfig"
            destination = root / "env.xcconfig"
            example.write_text(
                "ENABLE_DEBUG_AUTO_SERVER = 0\nENABLE_DEBUG_FILL_APIKEY_BUTTON = 0\n",
                encoding="utf-8",
            )
            prepare_task_xcconfig(example, destination)
            cleanup_task_xcconfig(example, destination)
            self.assertFalse(destination.exists())

            destination.write_text("PRIVATE = keep\n", encoding="utf-8")
            with self.assertRaises(CommandError):
                cleanup_task_xcconfig(example, destination)
            self.assertEqual(destination.read_text(encoding="utf-8"), "PRIVATE = keep\n")


    def test_test_environment_keeps_inputs_in_runner_and_removes_forbidden_keys(self) -> None:
        source = {
            "PATH": os.environ.get("PATH", ""),
            "UI_TEST_RESET_STATE": "1",
            "IMMICH_TEST_SERVER_URL": "private",
            "IMMICH_TEST_API_KEY": "private",
            "TEST_RUNNER_UI_TEST_RESET_STATE": "1",
            "TEST_RUNNER_IMMICH_TEST_SERVER_URL": "private",
            "TEST_RUNNER_IMMICH_TEST_API_KEY": "private",
            "SIMCTL_CHILD_IMMICH_SERVER_URL": "private",
        }
        environment = make_test_environment(
            source,
            server_url="http://127.0.0.1:12345/api",
            public_key="public-key",
        )

        self.assertEqual(environment["STRICT_E2E_INPUT_SERVER_URL"], "http://127.0.0.1:12345/api")
        self.assertEqual(environment["STRICT_E2E_INPUT_PUBLIC_KEY"], "public-key")
        self.assertEqual(environment["STRICT_E2E_INPUT_SCENARIO"], "normal")
        self.assertFalse(any(key.startswith("UI_TEST_") for key in environment))
        self.assertNotIn("IMMICH_TEST_SERVER_URL", environment)
        self.assertNotIn("IMMICH_TEST_API_KEY", environment)
        self.assertEqual(set(environment), {
            "PATH", "STRICT_E2E_INPUT_SERVER_URL", "STRICT_E2E_INPUT_PUBLIC_KEY", "STRICT_E2E_INPUT_SCENARIO",
        })


    def test_app_launch_environment_rejects_every_forbidden_key_family(self) -> None:
        validate_app_launch_environment({})
        for key in (
            "UI_TEST_RESET_STATE",
            "UI_TEST_ANY_FUTURE_KEY",
            "IMMICH_TEST_SERVER_URL",
            "IMMICH_TEST_URL",
            "IMMICH_TEST_API_KEY",
            "TEST_RUNNER_UI_TEST_ANY_FUTURE_KEY",
            "TEST_RUNNER_IMMICH_TEST_SERVER_URL",
            "TEST_RUNNER_IMMICH_TEST_API_KEY",
            "SIMCTL_CHILD_IMMICH_SERVER_URL",
        ):
            with self.subTest(key=key), self.assertRaises(CommandError):
                validate_app_launch_environment({key: "present"})


    def test_xcodebuild_command_targets_one_platform_smoke_and_independent_outputs(self) -> None:
        for platform, scheme, test_method in (
            ("ios", "immichSlides-iOS", "testIOSStrictE2EConnectionSmoke"),
            ("tvos", "immichSlides-tvOS", "testTVOSStrictE2EConnectionSmoke"),
        ):
            with self.subTest(platform=platform):
                command = build_xcodebuild_command(
                    repo_root=Path("/repo"),
                    platform=platform,
                    destination=f"platform={platform} Simulator,id=SIM-{platform}",
                    derived_data_path=Path(f"/evidence/{platform}/DerivedData"),
                    result_bundle_path=Path(f"/evidence/{platform}/strict.xcresult"),
                    server_url="http://127.0.0.1:12345/api",
                )
                self.assertIn(scheme, command)
                self.assertIn(f"StrictE2E-{'iOS' if platform == 'ios' else 'tvOS'}", command)
                self.assertIn("STRICT_E2E_INPUT_SERVER_URL=http://127.0.0.1:12345/api", command)
                self.assertIn("STRICT_E2E_INPUT_SCENARIO=normal", command)
                self.assertFalse(any("PUBLIC_KEY" in argument for argument in command))
                self.assertIn(
                    f"-only-testing:immichSlidesUITests/StrictE2ESmokeUITests/{test_method}",
                    command,
                )
                self.assertIn(f"/evidence/{platform}/DerivedData", command)
                self.assertIn(f"/evidence/{platform}/strict.xcresult", command)


    def test_ios_test_plan_forwards_runner_scenario_into_test_process(self) -> None:
        plan = json.loads((SCRIPT_DIR.parent / "StrictE2E-iOS.xctestplan").read_text(encoding="utf-8"))
        entries = plan["defaultOptions"]["environmentVariableEntries"]
        keys = {entry["key"]: entry["value"] for entry in entries}
        self.assertEqual(keys["STRICT_E2E_INPUT_SCENARIO"], "$(STRICT_E2E_INPUT_SCENARIO)")
        self.assertEqual(keys["STRICT_E2E_INPUT_SERVER_URL"], "$(STRICT_E2E_INPUT_SERVER_URL)")
        self.assertEqual(keys["STRICT_E2E_INPUT_PUBLIC_KEY"], "$(STRICT_E2E_INPUT_PUBLIC_KEY)")
        self.assertEqual(keys["STRICT_E2E_EVIDENCE_DIR"], "$(STRICT_E2E_EVIDENCE_DIR)")
        self.assertEqual(keys["STRICT_E2E_INPUT_SERVER_URL_B"], "$(STRICT_E2E_INPUT_SERVER_URL_B)")
        tvos_plan = json.loads((SCRIPT_DIR.parent / "StrictE2E-tvOS.xctestplan").read_text(encoding="utf-8"))
        tvos_keys = {entry["key"]: entry["value"] for entry in tvos_plan["defaultOptions"]["environmentVariableEntries"]}
        self.assertEqual(tvos_keys["STRICT_E2E_EVIDENCE_DIR"], "$(STRICT_E2E_EVIDENCE_DIR)")
        self.assertEqual(tvos_keys["STRICT_E2E_INPUT_SERVER_B_URL"], "$(STRICT_E2E_INPUT_SERVER_B_URL)")


    def test_xcodebuild_command_targets_ios_first_batch_journeys_and_rejects_tvos(self) -> None:
        common = {
            "repo_root": Path("/repo"),
            "destination": "platform=iOS Simulator,id=SIM-ios",
            "derived_data_path": Path("/evidence/ios/DerivedData"),
            "result_bundle_path": Path("/evidence/ios/strict.xcresult"),
            "server_url": "http://127.0.0.1:12345/api",
        }
        suites = {
            "journey-a": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testFirstBootSetupSurvivesColdRelaunch",
            "journey-b": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testRandomModeReachesPlaybackWithCorrectControlState",
            "firstboot-failure": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testFirstBootFailureStaysOnFirstBoot",
            "pause-window": "immichSlidesUITests/StrictE2EFirstBatchIOSUITests/testSinglePhotoOutgoingPauseWindowCapture",
            "filter-album": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterAlbumTargetMembers",
            "filter-edit-switch": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom",
            "filter-empty": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterEmptySelectionCannotStart",
            "filter-person": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterPersonNormalMatch",
            "filter-switch": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterServerSwitchIsolation",
            "display-policy": "immichSlidesUITests/StrictE2EFilterIOSUITests/testSmartFillDisplayPolicyChangesMultiToSingle",
            "filter-vision": "immichSlidesUITests/StrictE2EFilterIOSUITests/testFilterVisionSoloOnlyOnDevice",
        }
        for suite, selector in suites.items():
            with self.subTest(suite=suite):
                command = build_xcodebuild_command(platform="ios", suite=suite, scenario="auth-401", **common)
                self.assertIn(f"-only-testing:{selector}", command)
                self.assertIn("STRICT_E2E_INPUT_SCENARIO=auth-401", command)
                self.assertFalse(any("PUBLIC_KEY" in argument for argument in command))
                self.assertNotIn("StrictE2ESmokeUITests", " ".join(command))
                with self.assertRaises(CommandError):
                    build_xcodebuild_command(platform="tvos", suite=suite, **common)
                self.assertEqual(result_bundle_name("smoke"), "strict-smoke.xcresult")
                self.assertEqual(result_bundle_name(suite), f"strict-{suite}.xcresult")


    def test_filter_person_sessions_are_independent_first_boot_selectors(self) -> None:
        methods = _swift_test_methods("immichSlidesUITests/StrictE2EFilterIOSUITests.swift")
        self.assertNotIn("testFilterPersonRules", methods)
        self.assertEqual(
            [session["name"] for session in FILTER_PERSON_SESSIONS],
            ["normal", "conflict-normal", "nofaces"],
        )
        expected_methods = {
            "normal": "testFilterPersonNormalMatch",
            "conflict-normal": "testFilterPersonConflictNormal",
            "nofaces": "testFilterPersonNoFaces",
        }
        common = {
            "repo_root": Path("/repo"),
            "platform": "ios",
            "destination": "platform=iOS Simulator,id=SIM-ios",
            "derived_data_path": Path("/evidence/ios/DerivedData"),
            "server_url": "http://127.0.0.1:12345/api",
            "suite": "filter-person",
            "evidence_dir": Path("/evidence/ios"),
        }
        seen_selectors: list[str] = []
        for session in FILTER_PERSON_SESSIONS:
            method = expected_methods[session["name"]]
            selector = f"immichSlidesUITests/StrictE2EFilterIOSUITests/{method}"
            self.assertEqual(session["selector"], selector)
            self.assertIn(method, methods)
            bundle = Path(f"/evidence/ios/strict-filter-person-{session['name']}.xcresult")
            command = build_xcodebuild_command(
                **common,
                only_testing=selector,
                result_bundle_path=bundle,
            )
            self.assertIn(f"-only-testing:{selector}", command)
            self.assertIn(str(bundle), command)
            self.assertNotIn("testFilterPersonRules", " ".join(command))
            seen_selectors.append(selector)
        self.assertEqual(len(set(seen_selectors)), 3)
        self.assertEqual(IOS_FILTER_SUITES["filter-person"], seen_selectors[0])
        merged = merge_official_summaries(
            [
                TestResultsSummary(1, 1, 0, 0, "Passed"),
                TestResultsSummary(1, 1, 0, 0, "Passed"),
                TestResultsSummary(1, 1, 0, 0, "Passed"),
            ]
        )
        self.assertEqual(merged["totalTestCount"], 3)
        self.assertEqual(merged["passedTests"], 3)
        self.assertEqual(merged["failedTests"], 0)
        self.assertEqual(merged["skippedTests"], 0)
        self.assertEqual(merged["result"].lower(), "passed")


    def test_failure_scenarios_select_401_html_unreachable_timeout_and_out_of_order(self) -> None:
        self.assertEqual(scenario_settings("auth-401"), ("normal", WRONG_PUBLIC_API_KEY, True))
        self.assertEqual(scenario_settings("html-200"), ("html-200", "immichslides-public-e2e-key", True))
        self.assertEqual(scenario_settings("timeout"), ("timeout", "immichslides-public-e2e-key", True))
        self.assertEqual(
            scenario_settings("out-of-order"),
            ("out-of-order", "immichslides-public-e2e-key", True),
        )
        self.assertEqual(scenario_settings("unreachable")[2], False)

        url, reservation = reserve_unreachable_server_url()
        try:
            with self.assertRaises(urllib.error.URLError):
                urllib.request.urlopen(url.removesuffix("/api") + "/healthz", timeout=0.2)
        finally:
            reservation.close()


    def test_illegal_suite_scenario_combinations_are_rejected(self) -> None:
        validate_suite_scenario("firstboot-failure", "auth-401")
        validate_suite_scenario("firstboot-failure", "html-200")
        validate_suite_scenario("firstboot-failure", "unreachable")
        validate_suite_scenario("firstboot-failure", "timeout")
        validate_suite_scenario("journey-a", "normal")
        validate_suite_scenario("journey-b", "normal")
        validate_suite_scenario("pause-window", "normal")
        validate_suite_scenario("filter-album", "normal")
        validate_suite_scenario("filter-switch", "normal")
        validate_suite_scenario("filter-vision", "normal")
        validate_suite_scenario("tvos-flow", "normal")
        validate_suite_scenario("tvos-album", "normal")
        validate_suite_scenario("tvos-person", "normal")
        validate_suite_scenario("tvos-switch", "normal")
        validate_suite_scenario("smoke", "normal")
        validate_suite_scenario("late-image", "out-of-order")
        for suite, scenario in (
            ("firstboot-failure", "normal"),
            ("firstboot-failure", "out-of-order"),
            ("late-image", "normal"),
            ("late-image", "auth-401"),
            ("late-image", "timeout"),
            ("journey-a", "auth-401"),
            ("journey-b", "timeout"),
            ("pause-window", "auth-401"),
            ("filter-album", "timeout"),
            ("filter-switch", "auth-401"),
            ("tvos-flow", "timeout"),
            ("tvos-album", "auth-401"),
            ("tvos-person", "timeout"),
            ("tvos-switch", "html-200"),
            ("smoke", "html-200"),
        ):
            with self.subTest(suite=suite, scenario=scenario), self.assertRaises(CommandError) as raised:
                validate_suite_scenario(suite, scenario)
            self.assertIn("Invalid combination", str(raised.exception))

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory) / "evidence"
            stderr = io.StringIO()
            exit_code = runner_main(
                [
                    "--platform",
                    "ios",
                    "--destination",
                    "platform=iOS Simulator,id=SIM-1",
                    "--evidence-dir",
                    str(evidence),
                    "--suite",
                    "firstboot-failure",
                    "--scenario",
                    "normal",
                ],
                stderr=stderr,
            )
        self.assertEqual(exit_code, 2)
        self.assertIn("Invalid combination", stderr.getvalue())
        self.assertFalse(evidence.exists())


    def test_simulator_app_container_distinguishes_absent_from_device_error(self) -> None:
        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            if command[:3] == ["xcrun", "simctl", "get_app_container"]:
                result.returncode = 1
                result.stdout = ""
                result.stderr = "Unable to lookup in current state: Shutdown"
                return result
            result.returncode = 0
            result.stdout = ""
            result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run):
            with self.assertRaises(CommandError) as raised:
                simulator_app_container("SIM-UDID", "com.331works.immichSlides")
        self.assertIn("Could not determine whether the App container exists", str(raised.exception))
        self.assertIn("Shutdown", str(raised.exception))

        def absent_run(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.returncode = 2
            result.stdout = ""
            result.stderr = "No such container"
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=absent_run):
            self.assertIsNone(simulator_app_container("SIM-UDID", "com.331works.immichSlides"))


    def test_reset_simulator_app_stops_on_second_uninstall_failure(self) -> None:
        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.stdout = ""
            if command[:3] == ["xcrun", "simctl", "uninstall"]:
                result.returncode = 149
                result.stderr = "Failed to uninstall: device service unavailable"
            else:
                result.returncode = 0
                result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            with self.assertRaises(CommandError) as raised:
                reset_simulator_app("SIM-UDID")
        self.assertIn("Second uninstall failed", str(raised.exception))
        self.assertIn("uninstall_retry_exit=149", str(raised.exception))

    def test_reset_refuses_to_continue_with_keychain_or_privacy_state(self) -> None:
        for failed_step in ("keychain", "privacy"):
            with self.subTest(failed_step=failed_step):
                calls = []

                def fake_run(command, **kwargs):
                    calls.append(command)
                    code = 1 if command[2] == failed_step else 0
                    if command[2] == "get_app_container":
                        code = 2
                    return subprocess.CompletedProcess(command, code, "", "reset unavailable" if code == 1 else "")

                with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch("run_strict_e2e.time.sleep"):
                    with self.assertRaises(CommandError):
                        reset_simulator_app("SIM-UDID")
                self.assertIn(["xcrun", "simctl", failed_step, "SIM-UDID", "reset", *(["all"] if failed_step == "privacy" else [])], calls)

    def test_warm_products_and_per_case_environment_cannot_silently_change(self) -> None:
        import plistlib
        from strict_e2e_build import prepare_test_run, validate_warm_products

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            products = root / "Build/Products"
            products.mkdir(parents=True)
            xctestrun = products / "strict.xctestrun"
            xctestrun.write_bytes(plistlib.dumps({
                "TestConfigurations": [{"TestTargets": [{
                    "BlueprintName": "immichSlidesUITests",
                    "EnvironmentVariables": {"LANG": "en_US.UTF-8", "STRICT_E2E_INPUT_SCENARIO": "old", "TEST_RUNNER_UI_TEST_RESET_STATE": "1"},
                    "UITargetAppEnvironmentVariables": {"UI_TEST_RESET_STATE": "1", "STRICT_E2E_INPUT_SERVER_URL": "stale"},
                }]}],
            }))
            from ci_build_archive import inventory
            receipt = {"products": inventory(products)}
            validate_warm_products(root, receipt)
            run = prepare_test_run(xctestrun, root / "case", {
                "STRICT_E2E_INPUT_SERVER_URL": "http://127.0.0.1:1234/api",
                "STRICT_E2E_INPUT_SCENARIO": "normal",
                "PATH": "kept out of test inputs",
            })
            target = plistlib.loads(run.read_bytes())["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(target["EnvironmentVariables"], {
                "LANG": "en_US.UTF-8", "STRICT_E2E_INPUT_SERVER_URL": "http://127.0.0.1:1234/api", "STRICT_E2E_INPUT_SCENARIO": "normal",
            })
            self.assertEqual(target["UITargetAppEnvironmentVariables"], {})
            xctestrun.write_bytes(b"changed products")
            with self.assertRaises(CommandError):
                validate_warm_products(root, receipt)

    def test_warm_build_rejects_a_different_source_or_shard(self):
        from strict_e2e_build import load_warm_build, RECEIPT
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            identity = {"scheme": "immichSlides-iOS", "configuration": "Debug", "source_sha256": "a"}
            (root / RECEIPT).write_text(json.dumps({"schema_version": 1, "identity": identity}))
            for key in identity:
                with self.subTest(key=key), mock.patch("strict_e2e_build.workspace_preflight"), mock.patch(
                    "strict_e2e_build.shard_identity", return_value={**identity, key: "changed"}
                ), mock.patch("strict_e2e_build.validate_warm_products") as products:
                    with self.assertRaises(CommandError):
                        load_warm_build(root, "ios", "smoke", "Debug", "destination", root)
                    products.assert_not_called()


    def test_reset_simulator_app_stops_on_boot_failure_but_accepts_already_booted(self) -> None:
        def boot_fail(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.stdout = ""
            if command[:3] == ["xcrun", "simctl", "boot"]:
                result.returncode = 1
                result.stderr = "Unable to boot device in current state: Shutdown"
            else:
                result.returncode = 0
                result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=boot_fail), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            with self.assertRaises(CommandError) as raised:
                reset_simulator_app("SIM-UDID")
        self.assertIn("Simulator boot failed", str(raised.exception))

        calls: list[list[str]] = []

        def already_booted(command: list[str], **kwargs: object) -> mock.Mock:
            calls.append(command)
            result = mock.Mock()
            result.stdout = ""
            if command[:3] == ["xcrun", "simctl", "boot"]:
                result.returncode = 149
                result.stderr = "Unable to boot device in current state: Booted"
            elif command[:3] == ["xcrun", "simctl", "get_app_container"]:
                result.returncode = 2
                result.stderr = "No such container"
            else:
                result.returncode = 0
                result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=already_booted), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            log = reset_simulator_app("SIM-UDID")
        self.assertIn("app_container=absent", log)
        self.assertIn("boot_exit=149", log)


    def test_case_manifest_records_source_sha(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            with mock.patch(
                "run_strict_e2e.subprocess.run",
                return_value=mock.Mock(returncode=0, stdout="08aa575ed2ff28cfb0a05c6315d1d4c416440069\n", stderr=""),
            ):
                sha = read_source_sha(Path("/repo"))
            self.assertEqual(sha, "08aa575ed2ff28cfb0a05c6315d1d4c416440069")
            write_case_manifest(
                evidence,
                {
                    "source_sha": sha,
                    "platform": "ios",
                    "suite": "firstboot-failure",
                    "scenario": "auth-401",
                },
            )
            payload = json.loads((evidence / "case-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(payload["source_sha"], "08aa575ed2ff28cfb0a05c6315d1d4c416440069")
            self.assertEqual(payload["scenario"], "auth-401")

        with mock.patch(
            "run_strict_e2e.subprocess.run",
            return_value=mock.Mock(returncode=128, stdout="", stderr="not a git repo"),
        ):
            with self.assertRaises(CommandError):
                read_source_sha(Path("/repo"))


    def test_fixture_artifacts_write_independently_readable_member_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            payload = write_fixture_artifacts(evidence, "a")
            fixture = json.loads((evidence / "fixture-manifest.json").read_text(encoding="utf-8"))
            members = load_member_manifest(evidence / "member-manifest.json")
            self.assertEqual(payload["fixture_sha256"], FROZEN_FIXTURE_SHA256["a"])
            self.assertEqual(fixture["fixture_sha256"], FROZEN_FIXTURE_SHA256["a"])
            self.assertEqual(members["target_album"]["labels"], ["A1", "A2", "A3"])
            self.assertEqual(
                members["object_sets"]["albums"]["album-a-target"]["labels"],
                ["A1", "A2", "A3"],
            )
            self.assertEqual(
                members["object_sets"]["people"]["person-a-solo"]["normal"]["labels"],
                ["A2", "A3", "A5"],
            )
            self.assertEqual(
                members["object_sets"]["people"]["person-a-solo"]["soloOnly"]["labels"],
                ["A2"],
            )
            self.assertNotIn("wins", members)
            self.assertNotIn("public_api_key", fixture)
            self.assertNotIn("public_api_key", members)
