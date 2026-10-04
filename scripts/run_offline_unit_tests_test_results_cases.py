"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations

from run_offline_unit_tests_test_fixtures import (
    ACCESS_LIFECYCLE_HOST_SELECTORS,
    CommandError,
    DEFAULT_TIMEOUT_MINUTES,
    EXTERNAL_RUNTIME_TEST_SELECTOR,
    ElementTree,
    GENERIC_SCHEME,
    IOS_ONE_PASSED_OFFICIAL_SUMMARY,
    IOS_PLAN,
    IOS_SCHEME,
    Iterator,
    MIN_DATA_GIB,
    MISSING_GENERIC_PLAN,
    PBXPROJ,
    Path,
    REPO_ROOT,
    SCRIPT_DIR,
    TIMEOUT_EXIT_CODE,
    TVOS_ONE_PASSED_OFFICIAL_SUMMARY,
    TVOS_PLAN,
    TVOS_SCHEME,
    ZERO_COUNT_OFFICIAL_SUMMARY,
    argparse,
    build_test_command,
    business_targets,
    classify_test_results,
    contextlib,
    default_run,
    ensure_disk_for_xcodebuild,
    fake_xcresulttool,
    inspect_config,
    io,
    is_placeholder_config,
    json,
    main,
    official_summary_command,
    parse_non_negative_int,
    parse_official_test_results_summary,
    patch,
    plan_target_names,
    prepare_example_config,
    re,
    read_official_test_results_summary,
    resolve_suite_selectors,
    scheme_test_plan_names,
    shutil,
    subprocess,
    sys,
    tempfile,
    time,
    unittest,
)

class OfficialResultSummaryTestsCases:
    def test_zero_count_official_json_is_zero(self) -> None:
        summary = parse_official_test_results_summary(ZERO_COUNT_OFFICIAL_SUMMARY)
        self.assertEqual(summary.total_test_count, 0)
        self.assertEqual(summary.passed_tests, 0)
        self.assertEqual(summary.result, "unknown")


    def test_ios_one_passed_official_json_is_one_passed(self) -> None:
        summary = parse_official_test_results_summary(IOS_ONE_PASSED_OFFICIAL_SUMMARY)
        self.assertEqual(summary.total_test_count, 1)
        self.assertEqual(summary.passed_tests, 1)
        self.assertEqual(summary.skipped_tests, 0)
        self.assertEqual(summary.result, "Passed")


    def test_tvos_one_passed_official_json_is_one_passed(self) -> None:
        summary = parse_official_test_results_summary(TVOS_ONE_PASSED_OFFICIAL_SUMMARY)
        self.assertEqual(summary.total_test_count, 1)
        self.assertEqual(summary.passed_tests, 1)
        self.assertEqual(summary.result, "Passed")


    def test_explicit_skip_with_cases_is_not_empty(self) -> None:
        summary = parse_official_test_results_summary(
            {
                "totalTestCount": 2,
                "passedTests": 0,
                "failedTests": 0,
                "skippedTests": 2,
                "result": "Skipped",
            }
        )
        self.assertEqual(summary.total_test_count, 2)
        self.assertEqual(summary.skipped_tests, 2)
        self.assertEqual(summary.result, "Skipped")


    def test_xctest_executed_zero_text_is_unparseable(self) -> None:
        with self.assertRaises(CommandError) as raised:
            parse_official_test_results_summary(
                "Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds"
            )
        self.assertIn("unparseable", str(raised.exception))


    def test_missing_result_field_is_unparseable(self) -> None:
        with self.assertRaises(CommandError):
            parse_official_test_results_summary(
                {
                    "totalTestCount": 1,
                    "passedTests": 1,
                    "failedTests": 0,
                    "skippedTests": 0,
                }
            )


class IndependentVerdictTestsCases:
    def test_all_skipped_summary_is_unverified(self) -> None:
        summary = parse_official_test_results_summary(
            {
                "totalTestCount": 2,
                "passedTests": 0,
                "failedTests": 0,
                "skippedTests": 2,
                "result": "Skipped",
            }
        )
        self.assertEqual(classify_test_results(summary), "unverified")


    def test_zero_count_summary_is_unverified(self) -> None:
        summary = parse_official_test_results_summary(ZERO_COUNT_OFFICIAL_SUMMARY)
        self.assertEqual(classify_test_results(summary), "unverified")


    def test_mixed_pass_and_skip_summary_is_partial(self) -> None:
        summary = parse_official_test_results_summary(
            {
                "totalTestCount": 2,
                "passedTests": 1,
                "failedTests": 0,
                "skippedTests": 1,
                "result": "Passed",
            }
        )
        self.assertEqual(classify_test_results(summary), "partial")


    def test_failed_summary_is_failed_even_when_some_tests_passed(self) -> None:
        summary = parse_official_test_results_summary(
            {
                "totalTestCount": 2,
                "passedTests": 1,
                "failedTests": 1,
                "skippedTests": 0,
                "result": "Failed",
            }
        )
        self.assertEqual(classify_test_results(summary), "failed")


    def test_failed_result_is_failed_even_without_failed_count(self) -> None:
        summary = parse_official_test_results_summary(
            {
                "totalTestCount": 1,
                "passedTests": 0,
                "failedTests": 0,
                "skippedTests": 0,
                "result": "Failed",
            }
        )
        self.assertEqual(classify_test_results(summary), "failed")


    def test_clean_pass_summary_is_passed(self) -> None:
        summary = parse_official_test_results_summary(IOS_ONE_PASSED_OFFICIAL_SUMMARY)
        self.assertEqual(classify_test_results(summary), "passed")


class OfficialSummaryReaderTestsCases:
    def test_zero_count_bundle_reads_official_zero(self) -> None:
        with fake_xcresulttool(ZERO_COUNT_OFFICIAL_SUMMARY) as (bundle, calls):
            summary = read_official_test_results_summary(bundle)
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertEqual(summary.total_test_count, 0)
        self.assertEqual(summary.passed_tests, 0)
        self.assertEqual(summary.result, "unknown")


    def test_ios_one_passed_bundle_reads_official_one(self) -> None:
        with fake_xcresulttool(IOS_ONE_PASSED_OFFICIAL_SUMMARY) as (bundle, calls):
            summary = read_official_test_results_summary(bundle)
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertEqual(summary.total_test_count, 1)
        self.assertEqual(summary.passed_tests, 1)
        self.assertEqual(summary.result, "Passed")


    def test_tvos_one_passed_bundle_reads_official_one(self) -> None:
        with fake_xcresulttool(TVOS_ONE_PASSED_OFFICIAL_SUMMARY) as (bundle, calls):
            summary = read_official_test_results_summary(bundle)
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertEqual(summary.total_test_count, 1)
        self.assertEqual(summary.passed_tests, 1)
        self.assertEqual(summary.result, "Passed")


    def test_missing_bundle_fails_without_calling_xcresulttool(self) -> None:
        with fake_xcresulttool(IOS_ONE_PASSED_OFFICIAL_SUMMARY) as (bundle, calls):
            missing = bundle.parent / "missing.xcresult"
            with self.assertRaises(CommandError) as raised:
                read_official_test_results_summary(missing)
        self.assertEqual(calls, [])
        self.assertIn(str(missing), str(raised.exception))


    def test_xcresulttool_failure_is_unparseable(self) -> None:
        with fake_xcresulttool(returncode=1, stdout="", stderr="boom") as (bundle, _):
            with self.assertRaises(CommandError) as raised:
                read_official_test_results_summary(bundle)
        self.assertIn("boom", str(raised.exception))


    def test_empty_xcresulttool_output_is_unparseable(self) -> None:
        with fake_xcresulttool(stdout="  \n") as (bundle, _):
            with self.assertRaises(CommandError):
                read_official_test_results_summary(bundle)


class ResultGuardCLITestsCases:
    def test_injected_zero_count_summary_fails_without_historical_bundle(self) -> None:
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--result-bundle-path",
                "/tmp/zero-count-injected.xcresult",
                "--only-testing",
                "immichSlidesTests/PlaybackPoolResolverTests/normalizeServerURLWorks",
            ],
            stdout=io.StringIO(),
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
            read_summary=lambda _: parse_official_test_results_summary(ZERO_COUNT_OFFICIAL_SUMMARY),
        )
        self.assertNotEqual(code, 0)
        message = stderr.getvalue()
        self.assertIn("totalTestCount=0", message)
        self.assertIn("The filter matched no tests", message)
        self.assertIn("normalizeServerURLWorks", message)


    def test_zero_count_bundle_fails_after_xcode_success(self) -> None:
        stderr = io.StringIO()
        with fake_xcresulttool(ZERO_COUNT_OFFICIAL_SUMMARY) as (bundle, calls):
            code = main(
                [
                    "--platform",
                    "ios",
                    "--destination",
                    "platform=iOS Simulator,id=DEST-IOS",
                    "--result-bundle-path",
                    str(bundle),
                    "--only-testing",
                    "immichSlidesTests/PlaybackPoolResolverTests/normalizeServerURLWorks",
                ],
                stdout=io.StringIO(),
                stderr=stderr,
                run=lambda _: 0,
                data_available_gib=lambda: 200,
            )
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertNotEqual(code, 0)
        message = stderr.getvalue()
        self.assertIn("totalTestCount=0", message)
        self.assertIn("normalizeServerURLWorks", message)


    def test_ios_one_passed_bundle_stays_success(self) -> None:
        with fake_xcresulttool(IOS_ONE_PASSED_OFFICIAL_SUMMARY) as (bundle, calls):
            code = main(
                [
                    "--platform",
                    "ios",
                    "--destination",
                    "platform=iOS Simulator,id=DEST-IOS",
                    "--result-bundle-path",
                    str(bundle),
                    "--only-testing",
                    "immichSlidesTests/PlaybackPoolResolverTests/normalizeServerURLWorks()",
                ],
                stdout=io.StringIO(),
                stderr=io.StringIO(),
                run=lambda _: 0,
                data_available_gib=lambda: 200,
            )
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertEqual(code, 0)


    def test_tvos_one_passed_bundle_stays_success(self) -> None:
        with fake_xcresulttool(TVOS_ONE_PASSED_OFFICIAL_SUMMARY) as (bundle, calls):
            code = main(
                [
                    "--platform",
                    "tvos",
                    "--destination",
                    "platform=tvOS Simulator,id=DEST-TV",
                    "--result-bundle-path",
                    str(bundle),
                    "--only-testing",
                    "immichSlidesTests/PlaybackPoolResolverTests/normalizeServerURLWorks()",
                ],
                stdout=io.StringIO(),
                stderr=io.StringIO(),
                run=lambda _: 0,
                data_available_gib=lambda: 200,
            )
        self.assertEqual(calls, [official_summary_command(bundle)])
        self.assertEqual(code, 0)


    def test_explicit_skip_with_cases_is_not_failure(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--result-bundle-path",
                "/tmp/skipped.xcresult",
            ],
            stdout=stdout,
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
            read_summary=lambda _: parse_official_test_results_summary(
                {
                    "totalTestCount": 1,
                    "passedTests": 0,
                    "failedTests": 0,
                    "skippedTests": 1,
                    "result": "Skipped",
                }
            ),
        )
        self.assertEqual(code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("unverified", stdout.getvalue())
        self.assertNotIn("PASS", stdout.getvalue())


    def test_missing_bundle_after_success_fails(self) -> None:
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
            ],
            stdout=io.StringIO(),
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("Missing results", stderr.getvalue())


    def test_unparseable_bundle_after_success_fails(self) -> None:
        stderr = io.StringIO()

        def boom(_: Path) -> object:
            raise CommandError("This run's official xcresult test summary is unparseable.")

        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--result-bundle-path",
                "/tmp/broken.xcresult",
            ],
            stdout=io.StringIO(),
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
            read_summary=boom,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("unparseable", stderr.getvalue())


    def test_xcode_failure_is_kept_without_result_guard(self) -> None:
        reads: list[Path] = []
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--result-bundle-path",
                "unused-after-xcode-failure.xcresult",
            ],
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            run=lambda _: 65,
            data_available_gib=lambda: 200,
            read_summary=lambda path: reads.append(path) or parse_official_test_results_summary(
                ZERO_COUNT_OFFICIAL_SUMMARY
            ),
        )
        self.assertEqual(code, 65)
        self.assertEqual(reads, [])


    def test_suite_cannot_combine_with_only_testing_or_full_plan(self) -> None:
        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--suite",
                "access-lifecycle",
                "--only-testing",
                "immichSlidesTests",
                "--print-command",
            ],
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("--suite", stderr.getvalue())

        stderr = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--suite",
                "access-lifecycle",
                "--full-plan",
                "--print-command",
            ],
            stderr=stderr,
            run=lambda _: 0,
            data_available_gib=lambda: 200,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("--suite", stderr.getvalue())


    def test_print_command_access_lifecycle_suite_does_not_call_xcode(self) -> None:
        calls: list[list[str]] = []
        stdout = io.StringIO()
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--suite",
                "access-lifecycle",
                "--print-command",
            ],
            stdout=stdout,
            run=lambda argv: calls.append(argv) or 0,
            data_available_gib=lambda: 200,
        )
        output = stdout.getvalue()
        self.assertEqual(code, 0)
        self.assertEqual(calls, [])
        self.assertIn("-only-testing:immichSlidesTests/AccessProtectionStoreTests", output)
        self.assertIn("-only-testing:immichSlidesTests/PlaybackSettingsViewModelTests", output)
        self.assertNotIn("UITests", output)


    def test_print_command_does_not_read_result_bundle(self) -> None:
        reads: list[Path] = []
        code = main(
            [
                "--platform",
                "ios",
                "--destination",
                "platform=iOS Simulator,id=DEST-IOS",
                "--print-command",
            ],
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            run=lambda _: 0,
            data_available_gib=lambda: 200,
            read_summary=lambda path: reads.append(path) or parse_official_test_results_summary(
                ZERO_COUNT_OFFICIAL_SUMMARY
            ),
        )
        self.assertEqual(code, 0)
        self.assertEqual(reads, [])


    def test_check_does_not_read_result_bundle(self) -> None:
        reads: list[Path] = []
        code = main(
            ["--check"],
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            run=lambda _: 0,
            data_available_gib=lambda: 200,
            read_summary=lambda path: reads.append(path) or parse_official_test_results_summary(
                ZERO_COUNT_OFFICIAL_SUMMARY
            ),
        )
        self.assertEqual(code, 0)
        self.assertEqual(reads, [])
