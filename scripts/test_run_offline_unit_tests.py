"""Discovery entry point preserving the existing test class identities."""

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

from run_offline_unit_tests_test_configuration_cases import RepoDiscoveryTestsCases

class RepoDiscoveryTests(RepoDiscoveryTestsCases, unittest.TestCase):
    pass


from run_offline_unit_tests_test_configuration_cases import CommandBuilderTestsCases

class CommandBuilderTests(CommandBuilderTestsCases, unittest.TestCase):
    pass


from run_offline_unit_tests_test_configuration_cases import ConfigInspectionTestsCases

class ConfigInspectionTests(ConfigInspectionTestsCases, unittest.TestCase):
    pass


from run_offline_unit_tests_test_configuration_cases import CLIMainTestsCases

class CLIMainTests(CLIMainTestsCases, unittest.TestCase):
    pass


from run_offline_unit_tests_test_configuration_cases import DiskThresholdTestsCases

class DiskThresholdTests(DiskThresholdTestsCases, unittest.TestCase):
    pass


from run_offline_unit_tests_test_configuration_cases import RunWatchdogTestsCases

class RunWatchdogTests(RunWatchdogTestsCases, unittest.TestCase):
    IOS_ARGS = ["--platform", "ios", "--destination", "platform=iOS Simulator,id=DEST-IOS"]




from run_offline_unit_tests_test_results_cases import OfficialResultSummaryTestsCases

class OfficialResultSummaryTests(OfficialResultSummaryTestsCases, unittest.TestCase):
    pass


from run_offline_unit_tests_test_results_cases import IndependentVerdictTestsCases

class IndependentVerdictTests(IndependentVerdictTestsCases, unittest.TestCase):
    pass


from run_offline_unit_tests_test_results_cases import OfficialSummaryReaderTestsCases

class OfficialSummaryReaderTests(OfficialSummaryReaderTestsCases, unittest.TestCase):
    pass


from run_offline_unit_tests_test_results_cases import ResultGuardCLITestsCases

class ResultGuardCLITests(ResultGuardCLITestsCases, unittest.TestCase):
    pass


if __name__ == "__main__":
    unittest.main()
