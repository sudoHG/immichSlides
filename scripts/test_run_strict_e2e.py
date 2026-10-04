"""Discovery entry point preserving the existing test class identities."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

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

from run_strict_e2e_test_configuration_cases import StrictE2ERunnerTestsCasesConfiguration
from run_strict_e2e_test_evidence_cases import StrictE2ERunnerTestsCasesEvidence

class StrictE2ERunnerTests(StrictE2ERunnerTestsCasesConfiguration, StrictE2ERunnerTestsCasesEvidence, unittest.TestCase):
    pass


from run_strict_e2e_test_p2_cases import StrictE2EP2RunnerTestsCases

class StrictE2EP2RunnerTests(StrictE2EP2RunnerTestsCases, unittest.TestCase):
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
        create_result_bundle: bool = False,
        export_exit: int = 0,
    ) -> tuple[int, str, str, dict[str, mock.Mock]]:
        destination = f"platform={'tvOS' if platform == 'tvos' else 'iOS'} Simulator,id={P2_UDID}"
        selector = P2_CASES[suite].selectors[platform]
        recording_process = mock.Mock(pid=9876)

        def fake_run_command(command: list[str], **_: object) -> int:
            self.assertEqual([item for item in command if item.startswith("-only-testing:")], [f"-only-testing:{selector}"])
            _write_p2_ui_outputs(evidence, suite, skip=skip)
            if create_result_bundle:
                bundle = Path(command[command.index("-resultBundlePath") + 1])
                self.assertEqual(bundle.parent.parent, evidence.parent / "private")
                bundle.mkdir()
                (bundle / "raw.bin").write_bytes(b"raw diagnostics")
            return xcodebuild_exit

        def fake_subprocess(command: list[str], **_: object) -> subprocess.CompletedProcess[object]:
            if command[:2] == ["xcrun", "xcresulttool"]:
                return subprocess.CompletedProcess(command, export_exit, b'{"testNodes":[]}', b"")
            return subprocess.CompletedProcess(command, 0, "", "")

        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", evidence.parent / "private"), mock.patch(
            "run_strict_e2e.data_available_gib", return_value=100
        ), mock.patch(
            "run_strict_e2e.read_source_sha", return_value="0" * 40
        ), mock.patch("run_strict_e2e.read_source_dirty_paths", return_value=[]) as dirty, mock.patch(
            "run_strict_e2e.prepare_task_xcconfig", return_value={}
        ), mock.patch("run_strict_e2e.cleanup_task_xcconfig"), mock.patch(
            "run_strict_e2e.subprocess.run", side_effect=fake_subprocess
        ), mock.patch("run_strict_e2e.reset_simulator_app", return_value="reset\n"), mock.patch(
            "run_strict_e2e.run_command", side_effect=fake_run_command
        ), mock.patch(
            "run_strict_e2e.read_official_test_results_summary",
            return_value=TestResultsSummary(1, 1, 0, 0, "Passed"),
        ), mock.patch(
            "run_strict_e2e.read_xcresult_facts",
            return_value=_p2_facts(suite, platform, model, facts_device_id),
        ) as facts, mock.patch(
            "run_strict_e2e.start_screen_recording", return_value=(recording_process, 900.0)
        ) as start, mock.patch("run_strict_e2e.stop_screen_recording", return_value=0) as stop:
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




if __name__ == "__main__":
    unittest.main()
