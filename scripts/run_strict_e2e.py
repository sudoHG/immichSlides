#!/usr/bin/env python3
"""Start the public controlled service and run one strict E2E suite without injecting state into the app."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Callable, Mapping, Sequence, TextIO

from run_offline_unit_tests import (
    CommandError as OfflineCommandError,
    TestResultsSummary,
    parse_non_negative_int,
    read_official_test_results_summary,
)
from album_server_narrow_contract import (
    AlbumServerContractError,
    evaluate_album_empty_evidence,
    evaluate_server_switch_evidence,
)
from strict_e2e_filter_contract import (
    FILTER_VISUAL_SUITES,
    FilterContractError,
    evaluate_filter_visual_identity,
    write_member_manifest,
)
from strict_e2e_out_of_order_contract import (
    OUT_OF_ORDER_VISUAL_SUITES,
    OutOfOrderContractError,
    audit_runner_inputs,
    evaluate_out_of_order_identity,
)
from strict_e2e_p2_contract import (
    P2_CASES,
    RECORDING_FILE,
    RECORDING_TIMING_FILE,
    P2ContractError,
    p2_selector,
    read_xcresult_facts,
    require_official_execution,
    validate_raw_evidence,
)
from strict_e2e_photo_identity import (
    IdentityAssertionError,
    VISUAL_SUITES,
    evaluate_visual_identity,
)
from access_lifecycle_contract import logical_bytes_contain
from strict_e2e_server import PUBLIC_API_KEY, fixture_manifest

from strict_e2e_runner_support import (
    EXAMPLE_XCCONFIG,
    TASK_XCCONFIG,
    MIN_DATA_GIB,
    XCODEBUILD_TIMEOUT_SECONDS,
    RECORDING_START_TIMEOUT_SECONDS,
    RECORDING_STOP_TIMEOUT_SECONDS,
    WRONG_PUBLIC_API_KEY,
    PRIVATE_RESULT_BUNDLE_ROOT,
    RUNNER_SCENARIOS,
    FORBIDDEN_EXACT_KEYS,
    PLATFORM_SETTINGS,
    IOS_FIRST_BATCH_SUITES,
    FILTER_PERSON_SESSIONS,
    IOS_FILTER_SUITES,
    TVOS_FLOW_SUITES,
    TVOS_CONTROL_SUITES,
    TVOS_FILTER_SUITES,
    IOS_LATE_IMAGE_SUITES,
    TVOS_LATE_IMAGE_SUITES,
    IOS_CASES,
    TVOS_CASES,
    LIFECYCLE_SUITES,
    IMAGE_FAILURE_RECOVERY_SUITES,
    RUNNER_SUITES,
    FAILURE_SCENARIOS,
    SUCCESS_SUITES,
    DUAL_SERVER_SUITES,
    ALBUM_EMPTY_SUITES,
    SERVER_SWITCH_DISPLAY_SUITES,
    DISPLAY_POLICY_SUITES,
    FIXTURE_A_ONLY_FILTER_SUITES,
    SETTINGS_RESUME_SUITES,
    CASE_E2E_IDS,
    CommandError,
    parse_xcconfig,
    prepare_task_xcconfig,
    cleanup_task_xcconfig,
    _is_forbidden_key,
    validate_app_launch_environment,
    prepare_evidence_directory,
    scenario_settings,
    validate_suite_scenario,
    validate_suite_fixture,
    read_source_sha,
    read_source_dirty_paths,
    write_case_manifest,
    write_fixture_artifacts,
    _is_already_booted,
    reset_simulator_app,
    simulator_app_container,
    destination_udid,
    wait_for_service,
    stop_exact_process,
    audit_out_of_order_runner_inputs,
    require_visual_identity,
    _write_visual_runner_report,
    require_official_single_pass,
)


REPO_ROOT = Path(__file__).resolve().parent.parent




# First-boot interaction can place even public fixture keys in XCTest's private activity archive.
PRIVATE_RESULT_BUNDLE_SUITES = RUNNER_SUITES


def reserve_unreachable_server_url() -> tuple[str, socket.socket]:
    reservation = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        reservation.bind(("127.0.0.1", 0))
        host, port = reservation.getsockname()
        return f"http://{host}:{port}/api", reservation
    except Exception:
        reservation.close()
        raise


def write_sensitive_scan(evidence_dir: Path, sensitive_values: list[str]) -> None:
    values = [value for value in sensitive_values if value]
    matched_files: list[str] = []

    def raise_walk_error(error: OSError) -> None:
        raise error

    try:
        paths = sorted(
            Path(root) / filename
            for root, _, filenames in os.walk(evidence_dir, onerror=raise_walk_error)
            for filename in filenames
        )
    except OSError as error:
        raise CommandError(f"The redaction scan could not traverse the evidence directory: {error}") from error
    for path in paths:
        if not path.is_file():
            continue
        try:
            data = path.read_bytes()
        except OSError as error:
            raise CommandError(f"The redaction scan could not read {path.relative_to(evidence_dir)}: {error}") from error
        if logical_bytes_contain(data, values):
            matched_files.append(str(path.relative_to(evidence_dir)))
    payload = {
        "checked_key_names": ["STRICT_E2E_INPUT_PUBLIC_KEY"],
        "matched_files": matched_files,
        "result": "PASS" if not matched_files else "FAIL",
    }
    try:
        (evidence_dir / "sensitive-scan.json").write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except OSError as error:
        raise CommandError(f"Could not write the redaction scan results: {error}") from error
    if matched_files:
        raise CommandError("The evidence redaction scan found API Key values: " + ", ".join(matched_files))


def prepare_private_result_bundle_path(suite: str) -> Path:
    PRIVATE_RESULT_BUNDLE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    if PRIVATE_RESULT_BUNDLE_ROOT.is_symlink():
        raise CommandError("The private result root must not be a symlink.")
    PRIVATE_RESULT_BUNDLE_ROOT.chmod(0o700)
    holding_dir = Path(tempfile.mkdtemp(prefix=f"{suite}-", dir=PRIVATE_RESULT_BUNDLE_ROOT))
    return holding_dir / f"strict-{suite}.xcresult"


def export_private_result_bundle(
    bundle: Path, evidence_dir: Path, sensitive_values: list[str], *, suffix: str = "",
    summary_timeout_seconds: float | None = None,
) -> str:
    completed = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle), "--compact"],
        capture_output=True, check=False, timeout=60,
    )
    if completed.returncode != 0:
        raise CommandError(f"Official test export failed with exit {completed.returncode}.")
    payload = json.loads(completed.stdout)
    if not isinstance(payload, dict):
        raise CommandError("Official test export is not a JSON object.")
    if logical_bytes_contain(completed.stdout, sensitive_values):
        raise CommandError("Official test export contains test credentials; refusing to retain it.")
    (evidence_dir / f"official-tests{suffix}.json").write_bytes(completed.stdout)
    summary_path = evidence_dir / f"official-summary{suffix}.json"
    if not summary_path.exists():
        summary = (read_official_test_results_summary(bundle, timeout_seconds=summary_timeout_seconds)
                   if summary_timeout_seconds is not None else read_official_test_results_summary(bundle))
        summary_path.write_text(json.dumps({
            "totalTestCount": summary.total_test_count, "passedTests": summary.passed_tests,
            "failedTests": summary.failed_tests, "skippedTests": summary.skipped_tests,
            "result": summary.result,
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return hashlib.sha256(completed.stdout).hexdigest()


def finalize_private_result_bundle(
    bundle: Path, evidence_dir: Path, digest: str | None, *, successful: bool, suffix: str = ""
) -> list[str]:
    failures: list[str] = []
    disposal_path = evidence_dir / f"result-bundle-disposal{suffix}.json"
    quarantine_path = evidence_dir / f"result-bundle-quarantine{suffix}.json"
    if not bundle.exists():
        try:
            bundle.parent.rmdir()
        except OSError:
            pass
        return failures
    if successful and digest is not None:
        try:
            disposal_path.write_text(json.dumps({
                "reason": "The original XCTest result bundle may contain test credentials entered through normal UI input",
                "official_tests_command": "xcrun xcresulttool get test-results tests --compact",
                "official_tests_sha256": digest, "private_path": str(bundle),
                "result_bundle_disposed": True,
            }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            shutil.rmtree(bundle)
            bundle.parent.rmdir()
        except OSError as error:
            failures.append(f"dispose_private_result_bundle: {type(error).__name__}: {error}")
    if bundle.exists():
        try:
            disposal_path.unlink(missing_ok=True)
        except OSError as error:
            failures.append(f"remove_incomplete_disposal_record: {type(error).__name__}: {error}")
        try:
            quarantine_path.write_text(json.dumps({
                "private_path": str(bundle), "result_bundle_disposed": False,
            }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        except OSError as error:
            failures.append(f"write_result_bundle_quarantine: {type(error).__name__}: {error}")
    return failures


def run_cleanup_actions(actions: list[tuple[str, Callable[[], None]]]) -> list[str]:
    failures: list[str] = []
    for name, action in actions:
        try:
            action()
        except Exception as error:
            failures.append(f"{name}: {type(error).__name__}: {error}")
    return failures


def choose_exit_code(primary_exit_code: int, cleanup_failures: list[str]) -> int:
    if primary_exit_code != 0:
        return primary_exit_code
    return 2 if cleanup_failures else 0


def make_test_environment(
    source: Mapping[str, str],
    *,
    server_url: str,
    public_key: str,
    scenario: str = "normal",
    server_url_b: str | None = None,
    server_b_url: str | None = None,
) -> dict[str, str]:
    environment = {key: value for key, value in source.items() if not _is_forbidden_key(key)}
    environment["STRICT_E2E_INPUT_SERVER_URL"] = server_url
    environment["STRICT_E2E_INPUT_PUBLIC_KEY"] = public_key
    environment["STRICT_E2E_INPUT_SCENARIO"] = scenario
    peer = server_url_b or server_b_url
    if peer:
        environment["STRICT_E2E_INPUT_SERVER_URL_B"] = peer
        environment["STRICT_E2E_INPUT_SERVER_B_URL"] = peer
    return environment


def result_bundle_name(suite: str) -> str:
    if suite not in RUNNER_SUITES:
        raise CommandError(f"Unknown strict E2E suite: {suite}.")
    return f"strict-{suite}.xcresult"


def resolve_suite_selector(platform: str, suite: str) -> str:
    settings = PLATFORM_SETTINGS.get(platform)
    if settings is None:
        raise CommandError("platform must be ios or tvos.")
    if suite in IMAGE_FAILURE_RECOVERY_SUITES:
        required_platform, selector = IMAGE_FAILURE_RECOVERY_SUITES[suite]
        if platform != required_platform:
            raise CommandError(f"{suite} can only run on the {required_platform} platform.")
        return selector
    if suite in LIFECYCLE_SUITES:
        required_platform, selector = LIFECYCLE_SUITES[suite]
        if platform != required_platform:
            raise CommandError(f"{suite} can only run on the {required_platform} platform.")
        return selector
    if suite in P2_CASES:
        try:
            return p2_selector(suite, platform)
        except P2ContractError as error:
            raise CommandError(str(error)) from error
    if suite == "smoke":
        _scheme, _test_plan, test_method = settings
        return f"immichSlidesUITests/StrictE2ESmokeUITests/{test_method}"
    tvos_selector = (
        TVOS_FLOW_SUITES.get(suite) or TVOS_CONTROL_SUITES.get(suite) or TVOS_FILTER_SUITES.get(suite)
    )
    if tvos_selector is not None:
        if platform != "tvos":
            raise CommandError("The tvOS flow can only run on the tvos platform.")
        return tvos_selector
    if platform == "tvos":
        late_selector = TVOS_LATE_IMAGE_SUITES.get(suite)
        if late_selector is not None:
            return late_selector
    selector = (
        IOS_FIRST_BATCH_SUITES.get(suite)
        or IOS_FILTER_SUITES.get(suite)
        or IOS_LATE_IMAGE_SUITES.get(suite)
    )
    if selector is None:
        raise CommandError(f"Unknown strict E2E suite: {suite}.")
    if platform != "ios":
        raise CommandError("The iPhone/iPad journey can only run on the ios platform.")
    return selector


def merge_official_summaries(summaries: Sequence[TestResultsSummary]) -> dict[str, object]:
    if not summaries:
        raise CommandError("Official test counts are missing; cannot merge.")
    return {
        "totalTestCount": sum(item.total_test_count for item in summaries),
        "passedTests": sum(item.passed_tests for item in summaries),
        "failedTests": sum(item.failed_tests for item in summaries),
        "skippedTests": sum(item.skipped_tests for item in summaries),
        "result": summaries[-1].result if all(item.result.lower() == "passed" for item in summaries) else "failed",
    }


def build_xcodebuild_command(
    *,
    repo_root: Path,
    platform: str,
    destination: str,
    derived_data_path: Path,
    result_bundle_path: Path,
    server_url: str,
    suite: str = "smoke",
    scenario: str = "normal",
    evidence_dir: Path | None = None,
    server_url_b: str | None = None,
    server_b_url: str | None = None,
    only_testing: str | None = None,
) -> list[str]:
    settings = PLATFORM_SETTINGS.get(platform)
    if settings is None:
        raise CommandError("platform must be ios or tvos.")
    scheme, test_plan, _test_method = settings
    uses_settings_resume = suite in SETTINGS_RESUME_SUITES
    if uses_settings_resume:
        scheme = (
            "immichSlides-iOS-settings-resume"
            if platform == "ios"
            else "immichSlides-tvOS-settings-resume"
        )
    selector = only_testing or resolve_suite_selector(platform, suite)
    command = [
        "xcodebuild",
        "-disableAutomaticPackageResolution",
        "-onlyUsePackageVersionsFromResolvedFile",
        "-project",
        str(repo_root / "immichSlides.xcodeproj"),
        "-scheme",
        scheme,
        "-testPlan",
        test_plan,
        *(["-configuration", "Release"] if uses_settings_resume else []),
        "-destination",
        destination,
        "-derivedDataPath",
        str(derived_data_path),
        "-resultBundlePath",
        str(result_bundle_path),
        "-collect-test-diagnostics",
        "never",
        f"STRICT_E2E_INPUT_SERVER_URL={server_url}",
        f"STRICT_E2E_INPUT_SCENARIO={scenario}",
    ]
    if uses_settings_resume:
        command.extend(["-parallel-testing-enabled", "NO", "-skip-testing:immichSlidesTests"])
    if evidence_dir is not None:
        command.append(f"STRICT_E2E_EVIDENCE_DIR={evidence_dir}")
    peer = server_url_b or server_b_url
    if peer:
        command.append(f"STRICT_E2E_INPUT_SERVER_URL_B={peer}")
        command.append(f"STRICT_E2E_INPUT_SERVER_B_URL={peer}")
    command.extend([f"-only-testing:{selector}", "test"])
    return command


def data_available_gib() -> float:
    return shutil.disk_usage("/System/Volumes/Data").free / (1024**3)


def ensure_disk_for_xcodebuild(
    data_available_gib: Callable[[], float], min_free_gib: int = MIN_DATA_GIB
) -> None:
    available = data_available_gib()
    if available < min_free_gib:
        raise CommandError(
            f"Available space on /System/Volumes/Data is {available:.1f} GiB, below the "
            f"{min_free_gib} GiB threshold configured by --min-free-gib; stopping Xcode tests."
        )




def start_screen_recording(
    simulator_udid: str, video_path: Path, log_path: Path
) -> tuple[subprocess.Popen[bytes], float]:
    with log_path.open("wb") as log_file:
        process = subprocess.Popen(
            ["xcrun", "simctl", "io", simulator_udid, "recordVideo", "--codec=h264", "--force", str(video_path)],
            stdout=log_file,
            stderr=subprocess.STDOUT,
        )
    deadline = time.monotonic() + RECORDING_START_TIMEOUT_SECONDS
    did_start = False
    try:
        while True:
            if b"Recording started" in log_path.read_bytes():
                did_start = True
                return process, time.time()
            if process.poll() is not None:
                raise CommandError(f"Simulator recording exited early with exit {process.returncode}.")
            if time.monotonic() >= deadline:
                raise CommandError(f"Simulator recording did not start within {RECORDING_START_TIMEOUT_SECONDS}s; continuous recording is unavailable.")
            time.sleep(0.1)
    finally:
        if not did_start:
            stop_exact_process(process)


def stop_screen_recording(process: subprocess.Popen[bytes]) -> int:
    if process.poll() is not None:
        raise CommandError(f"Simulator recording exited before the test finished (exit {process.returncode}); the recording is not continuous.")
    process.send_signal(signal.SIGINT)
    try:
        return process.wait(timeout=RECORDING_STOP_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        process.kill()
        process.wait(timeout=5)
        raise CommandError("Simulator recording did not finish after SIGINT; the recording is unreliable.") from error





def require_p2_evidence(
    evidence_dir: Path,
    *,
    suite: str,
    platform: str,
    simulator_udid: str,
    fixture_set: str,
    result_bundle_path: Path,
) -> dict[str, object]:
    try:
        execution = require_official_execution(
            read_xcresult_facts(result_bundle_path),
            suite=suite,
            platform=platform,
            simulator_udid=simulator_udid,
        )
        payload = validate_raw_evidence(evidence_dir, suite, fixture_set)
    except P2ContractError as error:
        _write_visual_runner_report(evidence_dir, {"verdict": "FAIL", "suite": suite, "error": str(error)})
        raise CommandError(f"P2 raw evidence is incomplete; cannot mark SUCCESS: {error}", code=2) from error
    payload["execution"] = execution
    _write_visual_runner_report(evidence_dir, payload)
    return payload


def run_command(command: list[str], *, cwd: Path, environment: Mapping[str, str], log_path: Path,
                timeout_seconds: int = XCODEBUILD_TIMEOUT_SECONDS) -> int:
    with log_path.open("w", encoding="utf-8") as log_file:
        try:
            completed = subprocess.run(
                command,
                cwd=cwd,
                env=dict(environment),
                stdout=log_file,
                stderr=subprocess.STDOUT,
                check=False,
                timeout=timeout_seconds,
            )
        except subprocess.TimeoutExpired as error:
            raise CommandError(
                f"xcodebuild timed out after {timeout_seconds}s without exiting.",
                code=2,
            ) from error
    return completed.returncode


def main(argv: list[str] | None = None, stdout: TextIO | None = None, stderr: TextIO | None = None) -> int:
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=sorted(PLATFORM_SETTINGS))
    parser.add_argument("--destination", required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--fixture-set", choices=("a", "b"), default="a")
    parser.add_argument("--scenario", choices=RUNNER_SCENARIOS, default="normal")
    parser.add_argument("--suite", choices=RUNNER_SUITES, default="smoke")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--warm-up-only", action="store_true", help="build this shard once without starting a test or recording")
    mode.add_argument("--test-without-building", action="store_true", help="require and reuse an explicit shard warm-up")
    parser.add_argument("--derived-data-path", type=Path, help="shard-scoped DerivedData outside evidence; retained for reuse")
    parser.add_argument("--cloned-source-packages-path", type=Path, help="shared package downloads outside DerivedData and evidence")
    parser.add_argument("--configuration", choices=("Debug", "Release"), help="explicit shard configuration; defaults to the existing suite setting")
    parser.add_argument("--cold-timeout-seconds", type=parse_non_negative_int, help="explicit warm-up budget (default: 300 seconds)")
    parser.add_argument("--warm-timeout-seconds", type=parse_non_negative_int, help="explicit reuse budget (default: 300 seconds)")
    parser.add_argument(
        "--min-free-gib",
        type=parse_non_negative_int,
        default=MIN_DATA_GIB,
        metavar="N",
        help=f"minimum free GiB required before xcodebuild (default: {MIN_DATA_GIB})",
    )
    arguments = parser.parse_args(argv)
    if not (arguments.warm_up_only or arguments.test_without_building) and (arguments.cold_timeout_seconds is not None or arguments.warm_timeout_seconds is not None):
        parser.error("cold/warm timeout options require explicit warm-up/reuse")
    arguments.cold_timeout_seconds = XCODEBUILD_TIMEOUT_SECONDS if arguments.cold_timeout_seconds is None else arguments.cold_timeout_seconds
    arguments.warm_timeout_seconds = XCODEBUILD_TIMEOUT_SECONDS if arguments.warm_timeout_seconds is None else arguments.warm_timeout_seconds
    if not arguments.cold_timeout_seconds or not arguments.warm_timeout_seconds:
        parser.error("cold and warm timeouts must be positive")
    if (arguments.warm_up_only or arguments.test_without_building) and not arguments.derived_data_path:
        parser.error("warm-up/reuse requires --derived-data-path")
    if arguments.derived_data_path and not (arguments.warm_up_only or arguments.test_without_building):
        parser.error("--derived-data-path requires explicit warm-up/reuse")
    if (arguments.configuration or arguments.cloned_source_packages_path) and not arguments.derived_data_path:
        parser.error("configuration/shared packages require explicit warm-up/reuse")
    try:
        validate_suite_scenario(arguments.suite, arguments.scenario)
        validate_suite_fixture(arguments.suite, arguments.fixture_set)
        if arguments.suite in (*P2_CASES, *LIFECYCLE_SUITES, *IMAGE_FAILURE_RECOVERY_SUITES):
            resolve_suite_selector(arguments.platform, arguments.suite)
    except CommandError as error:
        print(f"CommandError: {error}", file=stderr)
        return error.code

    if arguments.warm_up_only:
        from strict_e2e_build import warm_up
        try:
            ensure_disk_for_xcodebuild(data_available_gib, arguments.min_free_gib)
            if "Simulator" not in arguments.destination:
                raise CommandError("strict E2E only accepts Simulator destinations.")
            destination_udid(arguments.destination)
            # Preflight before creating output or invoking Xcode, including dangling links.
            from ci_build_archive import workspace_preflight
            workspace_preflight(REPO_ROOT)
            prepare_evidence_directory(arguments.evidence_dir)
            derived = arguments.derived_data_path.resolve()
            packages = (arguments.cloned_source_packages_path or derived.parent / "SourcePackages").resolve()
            warm_up(root=REPO_ROOT, platform=arguments.platform, suite=arguments.suite,
                    configuration=arguments.configuration, destination=arguments.destination,
                    derived=derived, packages=packages, evidence=arguments.evidence_dir,
                    timeout=arguments.cold_timeout_seconds, execute=run_command)
            write_sensitive_scan(arguments.evidence_dir, [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY])
            return 0
        except (CommandError, ValueError, OSError, subprocess.SubprocessError) as error:
            print(f"CommandError: {error}", file=stderr)
            return getattr(error, "code", 2)

    config_path = REPO_ROOT / TASK_XCCONFIG
    did_create_config = False
    owns_evidence_directory = False
    service_process: subprocess.Popen[bytes] | None = None
    service_process_b: subprocess.Popen[bytes] | None = None
    recording_process: subprocess.Popen[bytes] | None = None
    unreachable_reservation: socket.socket | None = None
    server_url_b: str | None = None
    service_log_b_path: Path | None = None
    derived_data_path = (arguments.derived_data_path or arguments.evidence_dir / "DerivedData").resolve()
    warm_receipt = None
    primary_exit_code = 0
    did_complete_checks = False
    cleanup_failures: list[str] = []
    case_manifest: dict[str, object] | None = None
    result_bundle_path: Path | None = None
    private_bundles: list[tuple[Path, str]] = []
    private_test_runs: list[Path] = []
    official_tests_digests: dict[str, str] = {}
    try:
        ensure_disk_for_xcodebuild(data_available_gib, arguments.min_free_gib)
        if "Simulator" not in arguments.destination:
            raise CommandError("strict E2E only accepts Simulator destinations.")
        simulator_udid = destination_udid(arguments.destination)
        if arguments.derived_data_path:
            from strict_e2e_build import load_warm_build, validate_paths, prepare_test_run, warm_test_command, validate_warm_products
            packages = (arguments.cloned_source_packages_path or derived_data_path.parent / "SourcePackages").resolve()
            validate_paths(REPO_ROOT, derived_data_path, arguments.evidence_dir, packages)
            if arguments.test_without_building:
                warm_receipt, warm_run = load_warm_build(
                    REPO_ROOT, arguments.platform, arguments.suite, arguments.configuration,
                    arguments.destination, derived_data_path,
                )
        prepare_evidence_directory(arguments.evidence_dir)
        owns_evidence_directory = True
        if arguments.suite != "filter-person":
            result_bundle_path = prepare_private_result_bundle_path(arguments.suite)
            private_bundles.append((result_bundle_path, ""))
        case_manifest = {
            "source_sha": read_source_sha(REPO_ROOT),
            "platform": arguments.platform,
            "destination": arguments.destination,
            "os": "iOS Simulator" if arguments.platform == "ios" else "tvOS Simulator",
            "suite": arguments.suite,
            "scenario": arguments.scenario,
            "fixture_set": arguments.fixture_set,
            "e2e_ids": CASE_E2E_IDS.get(arguments.suite, []),
            "human_review": "NOT_RUN",
            "result": "RUNNING",
        }
        if arguments.suite in PRIVATE_RESULT_BUNDLE_SUITES:
            case_manifest["source_dirty_paths"] = read_source_dirty_paths(REPO_ROOT)
        write_case_manifest(arguments.evidence_dir, case_manifest)

        if warm_receipt is None:
            xcconfig_audit = prepare_task_xcconfig(REPO_ROOT / EXAMPLE_XCCONFIG, config_path)
            did_create_config = True
        else:
            xcconfig_audit = {"private_configuration_present": False, "warm_build": True}
        (arguments.evidence_dir / "xcconfig-audit.json").write_text(
            json.dumps(xcconfig_audit, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        validate_app_launch_environment({})
        (arguments.evidence_dir / "app-launch-environment-audit.json").write_text(
            json.dumps({"forbidden_keys_present": [], "launch_environment_keys": []}, indent=2) + "\n",
            encoding="utf-8",
        )

        for command in (["xcodebuild", "-checkFirstLaunchStatus"], ["xcodebuild", "-version"]):
            completed = subprocess.run(command, capture_output=True, text=True, check=False)
            if completed.returncode != 0:
                raise CommandError(f"{' '.join(command)} failed with exit {completed.returncode}.")
            with (arguments.evidence_dir / "xcode-environment.log").open("a", encoding="utf-8") as log:
                log.write(f"$ {shlex.join(command)}\n{completed.stdout}")

        ready_path = arguments.evidence_dir / "service-ready.json"
        service_log_path = arguments.evidence_dir / "service.log"
        fixture_payload = write_fixture_artifacts(arguments.evidence_dir, arguments.fixture_set)
        validate_suite_fixture(arguments.suite, str(fixture_payload["fixture_set"]))
        if arguments.suite in DUAL_SERVER_SUITES and arguments.fixture_set != "a":
            raise CommandError(f"{arguments.suite} must start from server A; use --fixture-set a.")
        if arguments.suite in DUAL_SERVER_SUITES:
            write_member_manifest(arguments.evidence_dir / "member-manifest-a.json", "a")
            write_member_manifest(arguments.evidence_dir / "member-manifest-b.json", "b")
            peer_fixture = fixture_manifest("b")
            (arguments.evidence_dir / "fixture-manifest-b.json").write_text(
                json.dumps(peer_fixture, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        if case_manifest is not None:
            case_manifest["fixture_sha256"] = fixture_payload["fixture_sha256"]
            write_case_manifest(arguments.evidence_dir, case_manifest)
        service_scenario, input_key, starts_service = scenario_settings(arguments.scenario)
        if starts_service:
            service_process = subprocess.Popen(
                [
                    sys.executable,
                    str(REPO_ROOT / "scripts/strict_e2e_server.py"),
                    "--host",
                    "127.0.0.1",
                    "--port",
                    "0",
                    "--fixture-set",
                    arguments.fixture_set,
                    "--scenario",
                    service_scenario,
                    "--ready-file",
                    str(ready_path),
                    "--log-file",
                    str(service_log_path),
                ],
                cwd=REPO_ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            host, port = wait_for_service(ready_path, service_process)
            server_url = f"http://{host}:{port}/api"
            if arguments.suite in DUAL_SERVER_SUITES:
                ready_b = arguments.evidence_dir / "service-b-ready.json"
                service_log_b_path = arguments.evidence_dir / "service-b.log"
                service_process_b = subprocess.Popen(
                    [
                        sys.executable,
                        str(REPO_ROOT / "scripts/strict_e2e_server.py"),
                        "--host",
                        "127.0.0.1",
                        "--port",
                        "0",
                        "--fixture-set",
                        "b",
                        "--scenario",
                        service_scenario,
                        "--ready-file",
                        str(ready_b),
                        "--log-file",
                        str(service_log_b_path),
                    ],
                    cwd=REPO_ROOT,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                host_b, port_b = wait_for_service(ready_b, service_process_b)
                server_url_b = f"http://{host_b}:{port_b}/api"
        else:
            server_url, unreachable_reservation = reserve_unreachable_server_url()
            ready_path.write_text(
                json.dumps({"listening": False, "scenario": "unreachable"}, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            service_log_path.write_text("scenario=unreachable listening=false\n", encoding="utf-8")

        reset_log = reset_simulator_app(simulator_udid)
        (arguments.evidence_dir / "simulator-reset.log").write_text(reset_log, encoding="utf-8")

        environment = make_test_environment(
            os.environ,
            server_url=server_url,
            public_key=input_key,
            scenario=arguments.scenario,
            server_url_b=server_url_b,
        )
        environment["STRICT_E2E_EVIDENCE_DIR"] = str(arguments.evidence_dir.resolve())
        if warm_receipt is not None:
            case_manifest["warm_build_identity"] = warm_receipt["identity"]

        def execute_case(command, log_path):
            started = time.monotonic()
            code = run_command(command, cwd=REPO_ROOT, environment=environment, log_path=log_path,
                               timeout_seconds=arguments.warm_timeout_seconds if warm_receipt is not None else XCODEBUILD_TIMEOUT_SECONDS)
            if warm_receipt is not None:
                validate_warm_products(derived_data_path, warm_receipt)
                from strict_e2e_build import write_json
                write_json(arguments.evidence_dir / (log_path.stem + "-reuse.json"), {
                    "duration_seconds": time.monotonic() - started, "exit_code": code,
                    "timeout_seconds": arguments.warm_timeout_seconds,
                    "action": "test-without-building", "products_unchanged": True,
                })
            return code
        (arguments.evidence_dir / "runner-input-audit.json").write_text(
            json.dumps(
                {
                    "input_keys_present": [
                        key
                        for key in (
                            "STRICT_E2E_INPUT_PUBLIC_KEY",
                            "STRICT_E2E_INPUT_SCENARIO",
                            "STRICT_E2E_INPUT_SERVER_URL",
                            "STRICT_E2E_INPUT_SERVER_URL_B",
                            "STRICT_E2E_INPUT_SERVER_B_URL",
                        )
                        if key in environment
                    ],
                    "scenario": arguments.scenario,
                    "suite": arguments.suite,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        person_summaries: list[TestResultsSummary] | None = None
        # Give each person rule a clean install and first launch; clearing the selection is not an intermediate state, or playback mode reverts to random.
        if arguments.suite == "filter-person":
            reset_logs = [reset_log]
            commands: list[str] = []
            summaries: list[TestResultsSummary] = []
            log_parts: list[str] = []
            for index, session in enumerate(FILTER_PERSON_SESSIONS):
                if index > 0:
                    reset_logs.append(reset_simulator_app(simulator_udid))
                session_bundle = prepare_private_result_bundle_path(f"filter-person-{session['name']}")
                private_bundles.append((session_bundle, f"-{session['name']}"))
                session_log = arguments.evidence_dir / f"xcodebuild-{session['name']}.log"
                command = build_xcodebuild_command(
                    repo_root=REPO_ROOT,
                    platform=arguments.platform,
                    destination=arguments.destination,
                    derived_data_path=derived_data_path,
                    result_bundle_path=session_bundle,
                    server_url=server_url,
                    suite=arguments.suite,
                    scenario=arguments.scenario,
                    evidence_dir=arguments.evidence_dir,
                    server_url_b=server_url_b,
                    only_testing=session["selector"],
                )
                if warm_receipt is not None:
                    run = prepare_test_run(warm_run, session_bundle.parent, environment)
                    private_test_runs.append(run)
                    command = warm_test_command(run, arguments.destination, session_bundle, session["selector"])
                commands.append(shlex.join(command))
                exit_code = execute_case(command, session_log)
                primary_exit_code = exit_code
                if exit_code != 0:
                    (arguments.evidence_dir / "xcodebuild.log").write_text(
                        "\n".join([*log_parts, session_log.read_text(encoding="utf-8")]),
                        encoding="utf-8",
                    )
                    (arguments.evidence_dir / "xcodebuild-command.txt").write_text(
                        "\n".join(commands) + "\n", encoding="utf-8"
                    )
                    (arguments.evidence_dir / "simulator-reset.log").write_text(
                        "\n".join(reset_logs) + "\n", encoding="utf-8"
                    )
                    raise CommandError(f"xcodebuild strict E2E failed with exit {exit_code}.", code=exit_code)
                summary = read_official_test_results_summary(session_bundle)
                require_official_single_pass(summary)
                summaries.append(summary)
                log_parts.append(session_log.read_text(encoding="utf-8"))
            (arguments.evidence_dir / "xcodebuild-command.txt").write_text(
                "\n".join(commands) + "\n", encoding="utf-8"
            )
            if case_manifest is not None:
                case_manifest["command"] = "\n".join(commands)
                write_case_manifest(arguments.evidence_dir, case_manifest)
            (arguments.evidence_dir / "xcodebuild.log").write_text("\n".join(log_parts), encoding="utf-8")
            (arguments.evidence_dir / "simulator-reset.log").write_text(
                "\n".join(reset_logs) + "\n", encoding="utf-8"
            )
            person_summaries = summaries
        else:
            command = build_xcodebuild_command(
                repo_root=REPO_ROOT,
                platform=arguments.platform,
                destination=arguments.destination,
                derived_data_path=derived_data_path,
                result_bundle_path=result_bundle_path,
                server_url=server_url,
                suite=arguments.suite,
                scenario=arguments.scenario,
                evidence_dir=arguments.evidence_dir,
                server_url_b=server_url_b,
            )
            if warm_receipt is not None:
                run = prepare_test_run(warm_run, result_bundle_path.parent, environment)
                private_test_runs.append(run)
                command = warm_test_command(run, arguments.destination, result_bundle_path,
                                            resolve_suite_selector(arguments.platform, arguments.suite))
            (arguments.evidence_dir / "xcodebuild-command.txt").write_text(
                shlex.join(command) + "\n", encoding="utf-8"
            )
            if case_manifest is not None:
                case_manifest["command"] = shlex.join(command)
                write_case_manifest(arguments.evidence_dir, case_manifest)
            if (arguments.suite in P2_CASES and P2_CASES[arguments.suite].video) or arguments.suite in SERVER_SWITCH_DISPLAY_SUITES:
                recording_process, recording_started = start_screen_recording(
                    simulator_udid,
                    arguments.evidence_dir / RECORDING_FILE,
                    arguments.evidence_dir / "screen-recording.log",
                )
            exit_code = execute_case(command, arguments.evidence_dir / "xcodebuild.log")
            primary_exit_code = exit_code
            if recording_process is not None:
                finished_recording, recording_process = recording_process, None
                recording_exit = stop_screen_recording(finished_recording)
                (arguments.evidence_dir / RECORDING_TIMING_FILE).write_text(
                    json.dumps(
                        {
                            "started_wall_time": recording_started,
                            "stopped_wall_time": time.time(),
                            "stop_exit": recording_exit,
                        },
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
            if exit_code != 0:
                raise CommandError(f"xcodebuild strict E2E failed with exit {exit_code}.", code=exit_code)
            summary = read_official_test_results_summary(result_bundle_path)
            require_official_single_pass(summary)
        if service_log_path.is_file():
            (arguments.evidence_dir / "redacted-request.log").write_bytes(service_log_path.read_bytes())
        if arguments.scenario == "out-of-order":
            log_text = (
                service_log_path.read_text(encoding="utf-8") if service_log_path.is_file() else ""
            )
            audit_payload = audit_out_of_order_runner_inputs(
                fixture_set=arguments.fixture_set,
                observed_hash=str(fixture_payload["fixture_sha256"]),
                service_log=log_text,
                server_url=server_url,
            )
            (arguments.evidence_dir / "runner-input-audit.json").write_text(
                json.dumps(audit_payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
        if service_log_b_path is not None and service_log_b_path.is_file():
            (arguments.evidence_dir / "request-log-b.log").write_bytes(service_log_b_path.read_bytes())
        if person_summaries is not None:
            summary_payload = merge_official_summaries(person_summaries)
        else:
            summary_payload = {
                "totalTestCount": summary.total_test_count,
                "passedTests": summary.passed_tests,
                "failedTests": summary.failed_tests,
                "skippedTests": summary.skipped_tests,
                "result": summary.result,
            }
        (arguments.evidence_dir / "official-summary.json").write_text(
            json.dumps(summary_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        if arguments.suite in P2_CASES:
            visual_payload = require_p2_evidence(
                arguments.evidence_dir,
                suite=arguments.suite,
                platform=arguments.platform,
                simulator_udid=simulator_udid,
                fixture_set=arguments.fixture_set,
                result_bundle_path=result_bundle_path,
            )
            if case_manifest is not None:
                case_manifest.update(visual_payload["execution"])
        else:
            visual_payload = require_visual_identity(arguments.evidence_dir, arguments.suite)
        if case_manifest is not None:
            case_manifest["result"] = summary.result
            case_manifest["exit_code"] = 0
            case_manifest["official_summary"] = summary_payload
            case_manifest["visual_identity"] = visual_payload
            write_case_manifest(arguments.evidence_dir, case_manifest)
        print(json.dumps(summary_payload, sort_keys=True), file=stdout)
        did_complete_checks = True
    except (CommandError, OfflineCommandError, ValueError) as error:
        print(f"{type(error).__name__}: {error}", file=stderr)
        primary_exit_code = primary_exit_code or getattr(error, "code", 2)
        if owns_evidence_directory and case_manifest is not None:
            case_manifest["result"] = "FAILED"
            case_manifest["exit_code"] = primary_exit_code
            try:
                write_case_manifest(arguments.evidence_dir, case_manifest)
            except OSError as write_error:
                cleanup_failures.append(f"write_case_manifest: {type(write_error).__name__}: {write_error}")
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Evidence or process I/O failed: {error}", file=stderr)
        primary_exit_code = primary_exit_code or 2
    finally:
        lifecycle: dict[str, object] = {}

        def export_and_hold_bundle(bundle: Path, suffix: str) -> None:
            if not bundle.is_dir():
                if primary_exit_code == 0:
                    raise CommandError("Missing private result bundle; cannot finalize a successful run.")
                return
            digest = export_private_result_bundle(
                bundle, arguments.evidence_dir, [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY], suffix=suffix
            )
            official_tests_digests[suffix] = digest
            if case_manifest is not None:
                if suffix:
                    case_manifest["official_session_tests_sha256"] = dict(official_tests_digests)
                else:
                    case_manifest["official_tests_sha256"] = digest
                write_case_manifest(arguments.evidence_dir, case_manifest)

        def stop_recording() -> None:
            if recording_process is not None:
                stop_screen_recording(recording_process)

        def stop_service() -> None:
            if service_process is None:
                return
            lifecycle["pid"] = service_process.pid
            lifecycle["exit"] = stop_exact_process(service_process)

        def stop_service_b() -> None:
            if service_process_b is None:
                return
            lifecycle["pid_b"] = service_process_b.pid
            lifecycle["exit_b"] = stop_exact_process(service_process_b)

        def close_unreachable_reservation() -> None:
            if unreachable_reservation is not None:
                unreachable_reservation.close()

        def write_lifecycle() -> None:
            if owns_evidence_directory and lifecycle:
                (arguments.evidence_dir / "service-lifecycle.json").write_text(
                    json.dumps(lifecycle, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )

        actions: list[tuple[str, Callable[[], None]]] = [
            ("stop_screen_recording", stop_recording),
            ("stop_service", stop_service),
            ("stop_service_b", stop_service_b),
            ("close_unreachable_reservation", close_unreachable_reservation),
            ("write_service_lifecycle", write_lifecycle),
        ]
        if did_create_config:
            actions.append(
                (
                    "cleanup_task_xcconfig",
                    lambda: cleanup_task_xcconfig(REPO_ROOT / EXAMPLE_XCCONFIG, config_path),
                )
            )
        if not arguments.derived_data_path and derived_data_path.exists():
            actions.append(("remove_derived_data", lambda: shutil.rmtree(derived_data_path)))
        for run in private_test_runs:
            actions.append(("remove_private_test_run", lambda path=run: path.unlink(missing_ok=True)))
        for bundle, suffix in private_bundles:
            actions.append(("export_and_hold_bundle" + suffix, lambda b=bundle, s=suffix: export_and_hold_bundle(b, s)))
        cleanup_failures.extend(run_cleanup_actions(actions))

        if owns_evidence_directory:
            if cleanup_failures:
                try:
                    (arguments.evidence_dir / "cleanup-failures.json").write_text(
                        json.dumps({"failures": cleanup_failures}, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )
                except OSError as error:
                    cleanup_failures.append(f"write_cleanup_failures: {type(error).__name__}: {error}")
            try:
                write_sensitive_scan(
                    arguments.evidence_dir,
                    [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY],
                )
            except CommandError as error:
                cleanup_failures.append(f"sensitive_scan: {error}")

        successful = did_complete_checks and primary_exit_code == 0 and not cleanup_failures
        for bundle, suffix in private_bundles:
            cleanup_failures.extend(finalize_private_result_bundle(
                bundle, arguments.evidence_dir, official_tests_digests.get(suffix),
                successful=successful and not cleanup_failures, suffix=suffix,
            ))

        if owns_evidence_directory and cleanup_failures:
            try:
                (arguments.evidence_dir / "cleanup-failures.json").write_text(
                    json.dumps({"failures": cleanup_failures}, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            except OSError as error:
                cleanup_failures.append(f"write_cleanup_failures: {type(error).__name__}: {error}")

    if cleanup_failures:
        print("Cleanup or evidence finalization failed: " + " | ".join(cleanup_failures), file=stderr)
    return choose_exit_code(primary_exit_code, cleanup_failures)


if __name__ == "__main__":
    raise SystemExit(main())
