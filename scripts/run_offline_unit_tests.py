#!/usr/bin/env python3
"""Offline business unit test entry point for clean checkouts. Do not treat the generic scheme or a missing test plan as runnable."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import functools
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
from typing import Callable, TextIO
from xml.etree import ElementTree


REPO_ROOT = Path(__file__).resolve().parent.parent
PROJECT = "immichSlides.xcodeproj"
SCHEMES_DIR = Path("immichSlides.xcodeproj/xcshareddata/xcschemes")
GENERIC_PLAN_NAME = "immichSlides.xctestplan"
ENV_XCCONFIG = Path("Config/env.xcconfig")
EXAMPLE_XCCONFIG = Path("Config/env.example.xcconfig")
PLACEHOLDER_URL = "https://your-server.example.com/api"
ESCAPED_PLACEHOLDER_URL = "https:/$()/your-server.example.com/api"
PLACEHOLDER_KEY = "YOUR_API_KEY"
MIN_DATA_GIB = 80
# A healthy tvOS unit run takes about 10 minutes; a hung one never ends on its own.
DEFAULT_TIMEOUT_MINUTES = 45
# Time for xcodebuild to finalize the result bundle after SIGINT before it is killed.
INTERRUPT_GRACE_SECONDS = 120
TIMEOUT_EXIT_CODE = 124
PLATFORM_SCHEME_SUFFIX = {
    "ios": "-iOS.xcscheme",
    "tvos": "-tvOS.xcscheme",
}
EXTERNAL_RUNTIME_TEST_SELECTOR = (
    "immichSlidesTests/PlaybackRuntimeEvidenceManifestTests/"
    "externalRuntimeJSONLPassesValidator()"
)
EXTERNAL_RUNTIME_TEST_SELECTOR_WITHOUT_ARGUMENTS = EXTERNAL_RUNTIME_TEST_SELECTOR[:-2]
ACCESS_LIFECYCLE_HOST_SELECTORS = [
    "immichSlidesTests/AccessProtectionStoreTests",
    "immichSlidesTests/PlaybackSettingsViewModelTests",
    "immichSlidesTests/ManualPlaybackLifecycleTests",
    "immichSlidesTests/SceneLifecycleContractTests",
    "immichSlidesTests/StableMarkTimingTests",
]
OFFLINE_SUITES = {
    "access-lifecycle": ACCESS_LIFECYCLE_HOST_SELECTORS,
}


class CommandError(Exception):
    def __init__(self, message: str, code: int = 2) -> None:
        super().__init__(message)
        self.code = code


def parse_non_negative_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a non-negative integer") from error
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    return parsed


@dataclass(frozen=True)
class ConfigInspection:
    env_xcconfig_exists: bool
    example_xcconfig_exists: bool
    example_is_placeholder: bool
    env_is_placeholder: bool | None
    report: str


@dataclass(frozen=True)
class TestResultsSummary:
    total_test_count: int
    passed_tests: int
    failed_tests: int
    skipped_tests: int
    result: str


def parse_xcconfig(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//") or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def is_placeholder_config(values: dict[str, str]) -> bool:
    url = values.get("IMMICH_SERVER_URL", "")
    api_key = values.get("IMMICH_API_KEY", "")
    return url in (PLACEHOLDER_URL, ESCAPED_PLACEHOLDER_URL) or api_key == PLACEHOLDER_KEY


def inspect_config(repo_root: Path) -> ConfigInspection:
    env_path = repo_root / ENV_XCCONFIG
    example_path = repo_root / EXAMPLE_XCCONFIG
    env_exists = os.path.lexists(env_path)
    example_exists = example_path.is_file()
    example_placeholder = example_exists and is_placeholder_config(parse_xcconfig(example_path))
    # Presence is sufficient; never open a private file or follow its symlink.
    env_placeholder = None

    lines = [
        f"env.xcconfig: {'present' if env_exists else 'missing'}.",
        f"env.example.xcconfig: {'present' if example_exists else 'missing'}.",
    ]
    if not env_exists:
        lines.append("Offline business unit tests do not require real credentials.")
        if example_exists:
            lines.append(
                "For local live/UI configuration, use --prepare-example-config; "
                "copy from the version-controlled example only when env.xcconfig is missing; do not overwrite an existing file."
            )
    else:
        lines.append("Existing env.xcconfig is present. This entry point does not read or print its server URL or key.")
    if example_exists:
        lines.append(
            "Example placeholder check: "
            + ("is a placeholder." if example_placeholder else "does not match the audited example placeholder.")
        )
    return ConfigInspection(
        env_xcconfig_exists=env_exists,
        example_xcconfig_exists=example_exists,
        example_is_placeholder=example_placeholder,
        env_is_placeholder=env_placeholder,
        report="\n".join(lines),
    )


def prepare_example_config(repo_root: Path) -> tuple[bool, str]:
    env_path = repo_root / ENV_XCCONFIG
    example_path = repo_root / EXAMPLE_XCCONFIG
    if os.path.lexists(env_path):
        return False, "env.xcconfig already exists; not overwritten."
    if not example_path.is_file():
        raise CommandError("Config/env.example.xcconfig is missing; cannot create local configuration.")
    env_path.write_text(example_path.read_text(encoding="utf-8"), encoding="utf-8")
    return True, "Created env.xcconfig from env.example.xcconfig; no existing files were overwritten."


def parse_scheme_test_plans(scheme_path: Path) -> list[str]:
    # xcscheme is XML and must not be parsed as a plist.
    tree = ElementTree.parse(scheme_path)
    names: list[str] = []
    for node in tree.iter("TestPlanReference"):
        reference = node.attrib.get("reference", "")
        prefix = "container:"
        if reference.startswith(prefix):
            names.append(reference[len(prefix) :])
    return names


def plan_target_names(plan_path: Path) -> set[str]:
    payload = json.loads(plan_path.read_text(encoding="utf-8"))
    return {target["target"]["name"] for target in payload["testTargets"]}


def business_targets(target_names: set[str]) -> list[str]:
    return sorted(
        name
        for name in target_names
        if name.endswith("Tests") and "UITests" not in name
    )


def find_platform_scheme(repo_root: Path, platform: str) -> Path:
    suffix = PLATFORM_SCHEME_SUFFIX.get(platform)
    if suffix is None:
        raise CommandError("Unsupported platform; only ios and tvos are allowed.")
    matches = sorted((repo_root / SCHEMES_DIR).glob(f"*{suffix}"))
    if not matches:
        raise CommandError(f"No scheme found for {platform}.")
    if len(matches) > 1:
        raise CommandError(f"{platform} has multiple matching schemes: {', '.join(path.name for path in matches)}")
    return matches[0]


def resolve_suite_selectors(suite: str) -> list[str]:
    selectors = OFFLINE_SUITES.get(suite)
    if selectors is None:
        known = ", ".join(sorted(OFFLINE_SUITES))
        raise CommandError(f"Unknown offline suite: {suite}. Currently supported: {known}.")
    return list(selectors)


def is_external_runtime_test_selector(value: str) -> bool:
    selector = value.strip()
    if selector.startswith("-only-testing:"):
        selector = selector[len("-only-testing:") :]
    return selector in {
        EXTERNAL_RUNTIME_TEST_SELECTOR,
        EXTERNAL_RUNTIME_TEST_SELECTOR_WITHOUT_ARGUMENTS,
    }


def build_test_command(
    *,
    repo_root: Path,
    platform: str,
    destination: str,
    derived_data_path: str | None = None,
    result_bundle_path: str | None = None,
    full_plan: bool = False,
    only_testing: list[str] | None = None,
    project: str = PROJECT,
    skip_external_runtime_gate: bool = True,
) -> list[str]:
    if platform not in PLATFORM_SCHEME_SUFFIX:
        raise CommandError("Unsupported platform; only ios and tvos are allowed.")
    if not destination or not destination.strip():
        raise CommandError("--destination is required (the actual simulator id or name); do not guess the default device.")
    if full_plan and only_testing:
        raise CommandError("--full-plan and --only-testing cannot be used together.")
    if skip_external_runtime_gate and only_testing:
        if any(is_external_runtime_test_selector(value) for value in only_testing):
            raise CommandError(
                "externalRuntimeJSONLPassesValidator() is external evidence tooling and cannot be "
                "selected through the offline runner; run it from the Evidence test plan with "
                "IMMICHSLIDES_RUNTIME_JSONL_FOR_VALIDATION set to the JSONL path."
            )

    scheme_path = find_platform_scheme(repo_root, platform)
    plan_names = parse_scheme_test_plans(scheme_path)
    if not plan_names:
        raise CommandError(f"{scheme_path.name} does not reference a test plan.")
    plan_file = plan_names[0]
    plan_path = repo_root / plan_file
    if not plan_path.is_file():
        raise CommandError(f"Test plan does not exist: {plan_file}")

    command = [
        "xcodebuild",
        "test",
        "-disableAutomaticPackageResolution",
        "-onlyUsePackageVersionsFromResolvedFile",
        "-project",
        project,
        "-scheme",
        scheme_path.stem,
        "-testPlan",
        Path(plan_file).stem,
        "-destination",
        destination,
    ]
    if not full_plan:
        selected = only_testing or business_targets(plan_target_names(plan_path))
        if not selected:
            raise CommandError(f"{plan_file} has no business targets that can be selected by default.")
        for target in selected:
            if target.startswith("-only-testing:"):
                command.append(target)
            else:
                command.append(f"-only-testing:{target}")
    if skip_external_runtime_gate:
        command.append(f"-skip-testing:{EXTERNAL_RUNTIME_TEST_SELECTOR}")
    if derived_data_path:
        command.extend(["-derivedDataPath", derived_data_path])
    if result_bundle_path:
        command.extend(["-resultBundlePath", result_bundle_path])
    return command


def generic_plan_refs_remain(repo_root: Path) -> list[str]:
    leftovers: list[str] = []
    generic_scheme = repo_root / SCHEMES_DIR / "immichSlides.xcscheme"
    if GENERIC_PLAN_NAME in generic_scheme.read_text(encoding="utf-8"):
        leftovers.append(str(generic_scheme.relative_to(repo_root)))
    pbxproj = repo_root / "immichSlides.xcodeproj/project.pbxproj"
    if "path = immichSlides.xctestplan" in pbxproj.read_text(encoding="utf-8"):
        leftovers.append("immichSlides.xcodeproj/project.pbxproj")
    return leftovers


def default_data_available_gib() -> float:
    stats = os.statvfs("/System/Volumes/Data")
    return (stats.f_bavail * stats.f_frsize) / (1024**3)


def ensure_disk_for_xcodebuild(
    data_available_gib: Callable[[], float], min_free_gib: int = MIN_DATA_GIB
) -> None:
    available = data_available_gib()
    if available < min_free_gib:
        raise CommandError(
            f"/System/Volumes/Data has {available:.1f} Gi available, below the {min_free_gib} Gi threshold configured by --min-free-gib; xcodebuild will not start."
        )


def check_repo(repo_root: Path, stdout: TextIO, stderr: TextIO) -> None:
    leftovers = generic_plan_refs_remain(repo_root)
    if leftovers:
        raise CommandError(
            "Still references missing "
            + GENERIC_PLAN_NAME
            + ": "
            + ", ".join(leftovers)
            + ". Do not add an empty generic plan; run tests with the iOS/tvOS schemes."
        )
    for platform in ("ios", "tvos"):
        scheme_path = find_platform_scheme(repo_root, platform)
        plan_names = parse_scheme_test_plans(scheme_path)
        if not plan_names:
            raise CommandError(f"{scheme_path.name} is missing a test plan.")
        for name in plan_names:
            if not (repo_root / name).is_file():
                raise CommandError(f"{scheme_path.name} references {name}, which does not exist.")
        targets = plan_target_names(repo_root / plan_names[0])
        print(
            f"{platform}: scheme {scheme_path.stem} / plan {Path(plan_names[0]).stem} / "
            f"targets {', '.join(sorted(targets))}",
            file=stdout,
        )
    print("The generic immichSlides scheme is for build/run/archive only, not for running tests.", file=stdout)
    print(
        "By default, the entry point selects only business targets in the plan; the full plan includes UI, and live tests within business targets are enabled according to configuration.",
        file=stdout,
    )
    print(
        "1 external evidence test not run; run it from the Evidence test plan with IMMICHSLIDES_RUNTIME_JSONL_FOR_VALIDATION set.",
        file=stdout,
    )
    print(inspect_config(repo_root).report, file=stdout)
    print(
        "Signing and physical devices are not verified by this entry point; pass the actual local simulator destination and task-specific DerivedData/resultBundle paths.",
        file=stdout,
    )


def _stop_process_group(process: subprocess.Popen, grace_seconds: float) -> None:
    try:
        os.killpg(process.pid, signal.SIGINT)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def default_run(
    argv: list[str],
    timeout_seconds: float | None = None,
    grace_seconds: float = INTERRUPT_GRACE_SECONDS,
) -> int:
    # Own process group so a timeout stops xcodebuild and every child it spawned.
    process = subprocess.Popen(argv, cwd=str(REPO_ROOT), start_new_session=True)
    try:
        return process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        _stop_process_group(process, grace_seconds)
        return TIMEOUT_EXIT_CODE
    except KeyboardInterrupt:
        # The child no longer shares the terminal's process group, so forward Ctrl-C.
        _stop_process_group(process, grace_seconds)
        raise


def _require_official_int(payload: dict[str, object], key: str) -> int:
    if key not in payload:
        raise CommandError("This run's official xcresult test summary is unparseable.")
    value = payload[key]
    if isinstance(value, bool) or not isinstance(value, int):
        raise CommandError("This run's official xcresult test summary is unparseable.")
    return value


def parse_official_test_results_summary(raw: str | dict[str, object]) -> TestResultsSummary:
    # Use only structured fields from xcresulttool test-results summary;
    # do not infer Swift Testing counts from XCTest's "Executed 0 tests" text.
    payload: object
    if isinstance(raw, str):
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise CommandError("This run's official xcresult test summary is unparseable.") from error
    else:
        payload = raw
    if not isinstance(payload, dict):
        raise CommandError("This run's official xcresult test summary is unparseable.")
    result = payload.get("result")
    if not isinstance(result, str) or not result:
        raise CommandError("This run's official xcresult test summary is unparseable.")
    return TestResultsSummary(
        total_test_count=_require_official_int(payload, "totalTestCount"),
        passed_tests=_require_official_int(payload, "passedTests"),
        failed_tests=_require_official_int(payload, "failedTests"),
        skipped_tests=_require_official_int(payload, "skippedTests"),
        result=result,
    )


def classify_test_results(summary: TestResultsSummary) -> str:
    """Map official counts to an independent verdict; do not treat process exit 0 as proof that tests passed."""
    if summary.failed_tests > 0 or summary.result.casefold() == "failed":
        return "failed"
    if summary.total_test_count <= 0:
        return "unverified"
    if summary.skipped_tests >= summary.total_test_count and summary.passed_tests == 0 and summary.failed_tests == 0:
        return "unverified"
    if (
        summary.total_test_count > 0
        and summary.passed_tests == summary.total_test_count
        and summary.failed_tests == 0
        and summary.skipped_tests == 0
        and summary.result.casefold() == "passed"
    ):
        return "passed"
    if summary.passed_tests > 0 or summary.failed_tests > 0:
        return "partial"
    return "unverified"


def format_test_results_summary(
    summary: TestResultsSummary,
    *,
    only_testing: list[str] | None,
    full_plan: bool,
) -> str:
    return (
        f"Offline test verdict: {classify_test_results(summary)}; "
        f"totalTestCount={summary.total_test_count} "
        f"passedTests={summary.passed_tests} "
        f"failedTests={summary.failed_tests} "
        f"skippedTests={summary.skipped_tests} "
        f"result={summary.result}; "
        f"{describe_test_filters(only_testing, full_plan)}."
    )


def read_official_test_results_summary(bundle_path: Path, *, timeout_seconds: float | None = None) -> TestResultsSummary:
    if not bundle_path.exists():
        raise CommandError(
            f"The test command succeeded, but this run's separate xcresult does not exist: {bundle_path}. Missing results cannot be treated as a pass."
        )
    completed = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(bundle_path),
            "--compact",
        ],
        capture_output=True,
        text=True,
        check=False,
        **({"timeout": timeout_seconds} if timeout_seconds is not None else {}),
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
        raise CommandError(f"Unable to read this run's official xcresult test summary; it is unparseable: {detail}")
    if not completed.stdout.strip():
        raise CommandError("This run's official xcresult test summary is unparseable.")
    return parse_official_test_results_summary(completed.stdout)


def describe_test_filters(only_testing: list[str] | None, full_plan: bool) -> str:
    if only_testing:
        return "Filter: " + ", ".join(only_testing)
    if full_plan:
        return "Filter: full platform plan (without -only-testing)"
    return "Filter: default business targets"


def confirm_successful_run(
    *,
    result_bundle_path: str | None,
    only_testing: list[str] | None,
    full_plan: bool,
    read_summary: Callable[[Path], TestResultsSummary],
) -> TestResultsSummary:
    # xcodebuild exit 0 means only that the command succeeded; the verdict is calculated separately from official counts.
    if not result_bundle_path:
        raise CommandError(
            "The test command succeeded, but there is no separate xcresult for this run (--result-bundle-path was not specified). "
            "Missing results cannot be treated as a pass."
        )
    summary = read_summary(Path(result_bundle_path))
    if summary.total_test_count == 0:
        raise CommandError(
            "This run's official xcresult summary has totalTestCount=0 "
            f"(result={summary.result}). "
            f"{describe_test_filters(only_testing, full_plan)}. "
            "The filter matched no tests; this cannot be treated as a pass. "
            "Swift Testing test identifiers usually need parentheses, for example normalizeServerURLWorks()."
        )
    return summary


def main(
    argv: list[str] | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
    run: Callable[[list[str]], int] | None = None,
    data_available_gib: Callable[[], float] | None = None,
    read_summary: Callable[[Path], TestResultsSummary] | None = None,
) -> int:
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    run_override = run
    data_available_gib = default_data_available_gib if data_available_gib is None else data_available_gib
    read_summary = read_official_test_results_summary if read_summary is None else read_summary
    parser = argparse.ArgumentParser(
        description="Run offline business unit tests without private credentials; business targets by default, with live tests enabled according to configuration."
    )
    parser.add_argument("--platform", help="ios or tvos")
    parser.add_argument("--destination", help="Actual simulator destination passed to xcodebuild")
    parser.add_argument("--derived-data-path")
    parser.add_argument("--result-bundle-path")
    parser.add_argument("--full-plan", action="store_true", help="Use the full platform test plan, including UI")
    parser.add_argument("--only-testing", action="append", help="Override default business targets; repeatable")
    parser.add_argument("--suite", help="Named offline suite; currently only access-lifecycle")
    parser.add_argument("--check", action="store_true", help="Parse scheme/plan/config only; do not call Xcode")
    parser.add_argument("--print-command", action="store_true", help="Print the xcodebuild command and exit")
    parser.add_argument("--prepare-example-config", action="store_true")
    parser.add_argument("--project", default=PROJECT)
    parser.add_argument(
        "--min-free-gib",
        type=parse_non_negative_int,
        default=MIN_DATA_GIB,
        metavar="N",
        help=f"minimum free GiB required before xcodebuild (default: {MIN_DATA_GIB})",
    )
    parser.add_argument(
        "--timeout-minutes",
        type=float,
        default=DEFAULT_TIMEOUT_MINUTES,
        help=f"stop xcodebuild after this many minutes (default {DEFAULT_TIMEOUT_MINUTES}; 0 disables)",
    )
    args = parser.parse_args(argv)
    if run_override is not None:
        run = run_override
    else:
        timeout_seconds = args.timeout_minutes * 60 if args.timeout_minutes > 0 else None
        run = functools.partial(default_run, timeout_seconds=timeout_seconds)

    try:
        if args.prepare_example_config:
            _, message = prepare_example_config(REPO_ROOT)
            print(message, file=stdout)
            if not args.check and not args.platform:
                return 0

        if args.check:
            # --check parses scheme/plan/config only; it does not call Xcode.
            check_repo(REPO_ROOT, stdout, stderr)
            return 0

        if args.platform is None:
            raise CommandError("--platform ios or tvos must be specified.")
        only_testing = args.only_testing
        if args.suite:
            if args.only_testing or args.full_plan:
                raise CommandError("--suite cannot be used with --only-testing or --full-plan.")
            only_testing = resolve_suite_selectors(args.suite)
        command = build_test_command(
            repo_root=REPO_ROOT,
            platform=args.platform,
            destination=args.destination or "",
            derived_data_path=args.derived_data_path,
            result_bundle_path=args.result_bundle_path,
            full_plan=args.full_plan,
            only_testing=only_testing,
            project=args.project,
        )
        if args.print_command:
            if f"-skip-testing:{EXTERNAL_RUNTIME_TEST_SELECTOR}" in command:
                print(
                    "1 external evidence test not run; run it from the Evidence test plan with IMMICHSLIDES_RUNTIME_JSONL_FOR_VALIDATION set.",
                    file=stdout,
                )
            print(shlex.join(command), file=stdout)
            return 0
        ensure_disk_for_xcodebuild(data_available_gib, args.min_free_gib)
        print("Running: " + shlex.join(command), file=stdout)
        if f"-skip-testing:{EXTERNAL_RUNTIME_TEST_SELECTOR}" in command:
            print(
                "1 external evidence test not run; run it from the Evidence test plan with IMMICHSLIDES_RUNTIME_JSONL_FOR_VALIDATION set.",
                file=stdout,
            )
        stdout.flush()
        exit_code = run(command)
        if exit_code == TIMEOUT_EXIT_CODE:
            print(
                f"TIMEOUT: xcodebuild did not finish within {args.timeout_minutes:g} minutes and was stopped. "
                "This run is NOT a pass. Look in the result bundle staging logs for tests that started "
                "but never finished.",
                file=stderr,
            )
        if exit_code != 0:
            return exit_code
        summary = confirm_successful_run(
            result_bundle_path=args.result_bundle_path,
            only_testing=only_testing,
            full_plan=args.full_plan,
            read_summary=read_summary,
        )
        print(
            format_test_results_summary(
                summary,
                only_testing=only_testing,
                full_plan=args.full_plan,
            ),
            file=stdout,
        )
        return 0
    except CommandError as error:
        print(str(error), file=stderr)
        return error.code


if __name__ == "__main__":
    from ci_local import local_main
    raise SystemExit(local_main(main, __file__))
