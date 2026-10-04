#!/usr/bin/env python3
"""Targeted iPhone/iPad access-lifecycle run using the public server and StrictE2E-iOS plan; not registered in the run_strict_e2e suite table."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Callable, Mapping, TextIO

from run_offline_unit_tests import parse_non_negative_int, read_official_test_results_summary
from run_strict_e2e import (
    CommandError,
    cleanup_task_xcconfig,
    destination_udid,
    make_test_environment,
    prepare_task_xcconfig,
    require_official_single_pass,
    reset_simulator_app,
    stop_exact_process,
    wait_for_service,
    write_fixture_artifacts,
    EXAMPLE_XCCONFIG,
    TASK_XCCONFIG,
)
from access_lifecycle_contract import (
    AccessLifecycleContractError,
    FROZEN_FIXTURE_SHA256,
    evaluate_access_lifecycle_evidence,
    scan_sensitive_evidence,
    scene_mark_from_png,
)
from strict_e2e_server import PUBLIC_API_KEY


REPO_ROOT = Path(__file__).resolve().parent.parent
DEVICE_SELECTOR = (
    "immichSlidesUITests/AccessLifecycleIOSUITests/"
    "testAccessProtectionSettingsAndLifecycle"
)
SYNTHETIC_PIN = "".join(chr(ord("0") + digit) for digit in (2, 4, 6, 8, 0, 1))
WRONG_PIN = "".join(chr(ord("0") + digit) for digit in (1, 3, 5, 7, 9, 0))
XCODEBUILD_TIMEOUT_SECONDS = 1200
MIN_DATA_GIB = 80
SCENE_SCREENSHOTS = (
    "pause",
    "after_next",
    "after_play",
    "before_background",
    "after_background",
    "before_wake",
    "after_wake",
)


def default_data_available_gib() -> float:
    return shutil.disk_usage("/System/Volumes/Data").free / (1024**3)


def ensure_disk(
    data_available_gib: Callable[[], float], min_free_gib: int = MIN_DATA_GIB
) -> None:
    available = data_available_gib()
    if available < min_free_gib:
        raise CommandError(
            f"/System/Volumes/Data has {available:.1f} Gi free, below the {min_free_gib} Gi threshold configured by --min-free-gib; not starting xcodebuild."
        )


def build_test_command(
    *,
    destination: str,
    derived_data_path: str,
    result_bundle_path: str,
    server_url: str,
    evidence_dir: str,
    fixture_set: str = "a",
) -> list[str]:
    return [
        "xcodebuild",
        "-project",
        str(REPO_ROOT / "immichSlides.xcodeproj"),
        "-scheme",
        "immichSlides-iOS",
        "-testPlan",
        "StrictE2E-iOS",
        "-destination",
        destination,
        "-derivedDataPath",
        derived_data_path,
        "-resultBundlePath",
        result_bundle_path,
        "-collect-test-diagnostics",
        "never",
        f"STRICT_E2E_INPUT_SERVER_URL={server_url}",
        f"STRICT_E2E_INPUT_PUBLIC_KEY={PUBLIC_API_KEY}",
        "STRICT_E2E_INPUT_SCENARIO=normal",
        f"STRICT_E2E_EVIDENCE_DIR={evidence_dir}",
        f"STRICT_E2E_INPUT_FIXTURE_SET={fixture_set}",
        f"-only-testing:{DEVICE_SELECTOR}",
        "test",
    ]


def png_sha256(path: Path) -> str:
    if not path.is_file():
        raise AccessLifecycleContractError("A missing image must not count as a pass")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evaluate_device_evidence(evidence_dir: Path, *, device: str) -> dict[str, object]:
    payload_path = evidence_dir / "access-lifecycle.json"
    if not payload_path.is_file():
        raise AccessLifecycleContractError("A missing image must not count as a pass")
    payload = json.loads(payload_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise AccessLifecycleContractError("A missing image must not count as a pass")
    screenshots = payload.get("screenshots")
    if not isinstance(screenshots, dict):
        raise AccessLifecycleContractError("A missing image must not count as a pass")
    scenes: dict[str, str] = {}
    for name in SCENE_SCREENSHOTS:
        relative = screenshots.get(name)
        if not isinstance(relative, str) or not relative:
            raise AccessLifecycleContractError(f"A missing image must not count as a pass: {name}")
        scenes[name] = scene_mark_from_png(evidence_dir / relative)
    payload["scenes"] = scenes
    payload["device"] = device
    payload["device_tests_run"] = True
    payload["identity_source"] = "public_fixture_photo_mark"
    payload["fixture_set"] = str(payload.get("fixture_set") or "a")
    payload["fixture_sha256"] = FROZEN_FIXTURE_SHA256[str(payload["fixture_set"])]
    display = payload.get("display_policy")
    if isinstance(display, dict):
        before = screenshots.get("display_before")
        after = screenshots.get("display_after")
        if isinstance(before, str) and isinstance(after, str):
            display["png_sha256_before"] = png_sha256(evidence_dir / before)
            display["png_sha256_after"] = png_sha256(evidence_dir / after)
            display["mark_before"] = scene_mark_from_png(evidence_dir / before)
            display["mark_after"] = scene_mark_from_png(evidence_dir / after)
            payload["display_policy"] = display
    try:
        result = evaluate_access_lifecycle_evidence(payload)
    except AccessLifecycleContractError as error:
        result = {
            "verdict": "FAIL",
            "error": str(error),
            "device_tests_run": True,
            "skip_counted_as_pass": False,
        }
        (evidence_dir / "access-lifecycle-result.json").write_text(
            json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        raise
    (evidence_dir / "access-lifecycle-result.json").write_text(
        json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return result


def run_xcodebuild(
    command: list[str],
    *,
    cwd: Path,
    environment: Mapping[str, str],
    log_path: Path,
) -> int:
    with log_path.open("w", encoding="utf-8") as log_file:
        try:
            completed = subprocess.run(
                command,
                cwd=cwd,
                env=dict(environment),
                stdout=log_file,
                stderr=subprocess.STDOUT,
                check=False,
                timeout=XCODEBUILD_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            raise CommandError(f"xcodebuild did not exit within the {XCODEBUILD_TIMEOUT_SECONDS}s timeout.") from error
    return completed.returncode


def main(
    argv: list[str] | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
    run: Callable[[list[str]], int] | None = None,
    data_available_gib: Callable[[], float] | None = None,
) -> int:
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    data_available_gib = default_data_available_gib if data_available_gib is None else data_available_gib
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--device", choices=("iphone", "ipad"), default="iphone")
    parser.add_argument("--fixture-set", choices=("a", "b"), default="a")
    parser.add_argument("--print-command", action="store_true")
    parser.add_argument(
        "--min-free-gib",
        type=parse_non_negative_int,
        default=MIN_DATA_GIB,
        metavar="N",
        help=f"minimum free GiB required before xcodebuild (default: {MIN_DATA_GIB})",
    )
    arguments = parser.parse_args(argv)

    try:
        derived_data_path = arguments.evidence_dir / "DerivedData"
        result_bundle_path = arguments.evidence_dir / "access-lifecycle-ios.xcresult"
        command = build_test_command(
            destination=arguments.destination,
            derived_data_path=str(derived_data_path),
            result_bundle_path=str(result_bundle_path),
            server_url="http://127.0.0.1:0/api",
            evidence_dir=str(arguments.evidence_dir),
            fixture_set=arguments.fixture_set,
        )
        if arguments.print_command:
            print(shlex.join(command), file=stdout)
            return 0

        ensure_disk(data_available_gib, arguments.min_free_gib)
        if run is not None:
            return run(command)

        arguments.evidence_dir.mkdir(parents=True, exist_ok=True)
        if any(path.name != ".DS_Store" for path in arguments.evidence_dir.iterdir()):
            raise CommandError("Evidence directory is not empty; refusing to start to avoid overwriting or mixing evidence.")
        config_path = REPO_ROOT / TASK_XCCONFIG
        example_path = REPO_ROOT / EXAMPLE_XCCONFIG
        prepare_task_xcconfig(example_path, config_path)
        write_fixture_artifacts(arguments.evidence_dir, arguments.fixture_set)
        ready_path = arguments.evidence_dir / "service-ready.json"
        service_log_path = arguments.evidence_dir / "service.log"
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
                "normal",
                "--ready-file",
                str(ready_path),
                "--log-file",
                str(service_log_path),
            ],
            cwd=REPO_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            host, port = wait_for_service(ready_path, service_process)
            server_url = f"http://{host}:{port}/api"
            simulator_udid = destination_udid(arguments.destination)
            reset_log = reset_simulator_app(simulator_udid)
            (arguments.evidence_dir / "simulator-reset.log").write_text(reset_log, encoding="utf-8")
            command = build_test_command(
                destination=arguments.destination,
                derived_data_path=str(derived_data_path),
                result_bundle_path=str(result_bundle_path),
                server_url=server_url,
                evidence_dir=str(arguments.evidence_dir),
                fixture_set=arguments.fixture_set,
            )
            (arguments.evidence_dir / "xcodebuild-command.txt").write_text(
                shlex.join(command) + "\n",
                encoding="utf-8",
            )
            if SYNTHETIC_PIN in shlex.join(command) or WRONG_PIN in shlex.join(command):
                raise CommandError("PIN appears in a file name, command, log or attachment")
            environment = make_test_environment(
                os.environ,
                server_url=server_url,
                public_key=PUBLIC_API_KEY,
                scenario="normal",
            )
            environment["STRICT_E2E_EVIDENCE_DIR"] = str(arguments.evidence_dir)
            environment["STRICT_E2E_INPUT_PUBLIC_KEY"] = PUBLIC_API_KEY
            log_path = arguments.evidence_dir / "xcodebuild.log"
            exit_code = run_xcodebuild(
                command,
                cwd=REPO_ROOT,
                environment=environment,
                log_path=log_path,
            )
            summary = None
            if result_bundle_path.exists():
                try:
                    summary = read_official_test_results_summary(result_bundle_path)
                    (arguments.evidence_dir / "official-summary.json").write_text(
                        json.dumps(
                            {
                                "totalTestCount": summary.total_test_count,
                                "passedTests": summary.passed_tests,
                                "failedTests": summary.failed_tests,
                                "skippedTests": summary.skipped_tests,
                                "result": summary.result,
                            },
                            indent=2,
                            sort_keys=True,
                        )
                        + "\n",
                        encoding="utf-8",
                    )
                except Exception as error:
                    print(str(error), file=stderr)
            json_path = arguments.evidence_dir / "access-lifecycle.json"
            if json_path.is_file():
                evaluate_device_evidence(arguments.evidence_dir, device=arguments.device)
                scan = scan_sensitive_evidence(arguments.evidence_dir, [SYNTHETIC_PIN, WRONG_PIN])
                (arguments.evidence_dir / "sensitive-scan.json").write_text(
                    json.dumps(scan, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
                    encoding="utf-8",
                )
            if exit_code != 0:
                return exit_code
            if summary is None:
                raise CommandError("Missing official counts.")
            require_official_single_pass(summary)
            if not json_path.is_file():
                raise AccessLifecycleContractError("A missing image must not count as a pass")
            return 0
        finally:
            stop_exact_process(service_process)
            cleanup_task_xcconfig(example_path, config_path)
    except (CommandError, AccessLifecycleContractError) as error:
        print(str(error), file=stderr)
        if SYNTHETIC_PIN in str(error) or WRONG_PIN in str(error):
            print("PIN appears in a file name, command, log or attachment", file=stderr)
            return 2
        return getattr(error, "code", 2)


if __name__ == "__main__":
    raise SystemExit(main())
