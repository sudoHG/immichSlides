#!/usr/bin/env python3
"""Run access-lifecycle checks on tvOS on the simulator given by --destination, with a per-run local fixture-server port and DerivedData; this is not part of the run_strict_e2e suite list."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Mapping, TextIO


from run_offline_unit_tests import (
    TestResultsSummary,
    parse_non_negative_int,
    read_official_test_results_summary,
)
from run_strict_e2e import (
    CommandError,
    choose_exit_code,
    cleanup_task_xcconfig,
    data_available_gib as strict_data_available_gib,
    destination_udid,
    make_test_environment,
    prepare_evidence_directory,
    prepare_task_xcconfig,
    read_source_sha,
    reset_simulator_app,
    run_cleanup_actions,
    stop_exact_process,
    wait_for_service,
    write_case_manifest,
    write_fixture_artifacts,
    write_sensitive_scan,
)
from access_lifecycle_contract import (
    AccessLifecycleContractError,
    FROZEN_FIXTURE_SHA256,
    assert_display_before_pool_burn,
    assert_unshown_display_partners,
    evaluate_access_lifecycle_evidence,
    inspect_display_strategy,
    scan_sensitive_evidence,
)
from strict_e2e_photo_identity import PhotoIdentity, classify_screenshot
from strict_e2e_server import PUBLIC_API_KEY


REPO_ROOT = Path(__file__).resolve().parent.parent
EXAMPLE_XCCONFIG = Path("Config/env.example.xcconfig")
TASK_XCCONFIG = Path("Config/env.xcconfig")
MIN_DATA_GIB = 80
# The PIN, settings restart, and playback lifecycle run longer than one late-image test.
XCODEBUILD_TIMEOUT_SECONDS = 900
TVOS_DEVICE_SELECTOR = (
    "immichSlidesUITests/AccessLifecycleTVOSUITests/"
    "testTVOSAccessProtectionSettingsAndLifecycle"
)
ISOLATED_TVOS_SCHEME = "AccessLifecycle-tvOS"
UNIT_TEST_TARGET = "immichSlidesTests"
UI_TEST_TARGET = "immichSlidesUITests"
APP_BLUEPRINT_ID = "120E64472F0CA2A5003B1480"
UI_TEST_BLUEPRINT_ID = "12F4D6672F6A9FF70049C717"
_OWNED_ISOLATED_SCHEMES: dict[Path, tuple[int, int, bytes]] = {}
SCENE_FILES = {
    "pause": "pause.png",
    "after_next": "after-next.png",
    "after_play": "after-play.png",
    "before_background": "before-background.png",
    "after_background": "after-background.png",
    "before_wake": "before-wake.png",
    "after_wake": "after-wake.png",
}
REQUIRED_SCREENSHOT_FILES = {
    "pause": "pause.png",
    "after_next": "after-next.png",
    "after_play": "after-play.png",
    "after_background": "after-background.png",
    "after_wake": "after-wake.png",
}
DISPLAY_BEFORE = "display-before.png"
DISPLAY_AFTER = "display-after.png"
VISUAL_IDENTITY_FILENAME = "visual-identity-runner.json"
SETTINGS_PIN_EVIDENCE = (
    "pin-gate.png",
    "settings-before-restart.png",
    "settings-after-restart.png",
)


def synthetic_pin_values() -> list[str]:
    # Use the same construction as the UI test: the valid digit is 1 and the invalid digit is 0.
    # Do not write a six-digit literal in source.
    return [chr(ord("0") + 1) * 6, chr(ord("0") + 0) * 6]


def isolated_scheme_path(repo_root: Path) -> Path:
    return (
        repo_root
        / "immichSlides.xcodeproj/xcshareddata/xcschemes"
        / f"{ISOLATED_TVOS_SCHEME}.xcscheme"
    )


def isolated_tvos_scheme_xml() -> str:
    # Do not reference immichSlides-tvOS.xctestplan: it includes unit tests that BuildAction would
    # compile into the build graph.
    # Do not edit the checked-in scheme; the runner writes this XML before the run and removes it afterward.
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2630"
   version = "2.1">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{APP_BLUEPRINT_ID}"
               BuildableName = "immichSlides.app"
               BlueprintName = "immichSlides"
               ReferencedContainer = "container:immichSlides.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Release"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <TestPlans>
         <TestPlanReference
            reference = "container:StrictE2E-tvOS.xctestplan"
            default = "YES">
         </TestPlanReference>
      </TestPlans>
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{UI_TEST_BLUEPRINT_ID}"
               BuildableName = "{UI_TEST_TARGET}.xctest"
               BlueprintName = "{UI_TEST_TARGET}"
               ReferencedContainer = "container:immichSlides.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Release"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{APP_BLUEPRINT_ID}"
            BuildableName = "immichSlides.app"
            BlueprintName = "immichSlides"
            ReferencedContainer = "container:immichSlides.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{APP_BLUEPRINT_ID}"
            BuildableName = "immichSlides.app"
            BlueprintName = "immichSlides"
            ReferencedContainer = "container:immichSlides.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Release">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def write_isolated_tvos_scheme(repo_root: Path) -> Path:
    path = isolated_scheme_path(repo_root)
    xml = isolated_tvos_scheme_xml()
    if UNIT_TEST_TARGET in xml:
        raise CommandError("The isolated scheme includes the unit-test target and cannot be written.")
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("x", encoding="utf-8") as handle:
            handle.write(xml)
            created_stat = os.fstat(handle.fileno())
    except FileExistsError as error:
        raise CommandError(f"The isolated scheme already exists: {path}. It will not be overwritten.") from error
    _OWNED_ISOLATED_SCHEMES[path] = (
        created_stat.st_dev,
        created_stat.st_ino,
        xml.encode("utf-8"),
    )
    return path


def remove_isolated_tvos_scheme(repo_root: Path) -> None:
    path = isolated_scheme_path(repo_root)
    ownership = _OWNED_ISOLATED_SCHEMES.pop(path, None)
    if ownership is None:
        return
    try:
        current_stat = path.lstat()
    except FileNotFoundError:
        return
    owned_device, owned_inode, owned_contents = ownership
    if (
        not stat.S_ISREG(current_stat.st_mode)
        or current_stat.st_dev != owned_device
        or current_stat.st_ino != owned_inode
    ):
        return
    try:
        if path.read_bytes() != owned_contents:
            return
    except OSError:
        return
    path.unlink()


def build_xcodebuild_command(
    *,
    repo_root: Path,
    destination: str,
    derived_data_path: Path,
    result_bundle_path: Path,
    server_url: str,
    public_key: str,
    evidence_dir: Path,
    cloned_source_packages: Path | None = None,
) -> list[str]:
    # Keep the public key only in the process environment to avoid writing it to xcodebuild-command.txt.
    _ = public_key
    # Release: Debug XCTest does not observe settings notifications by default; the
    # access-lifecycle process must match a user process.
    command = [
        "xcodebuild",
        "-project",
        str(repo_root / "immichSlides.xcodeproj"),
        "-scheme",
        ISOLATED_TVOS_SCHEME,
        "-testPlan",
        "StrictE2E-tvOS",
        "-configuration",
        "Release",
        "-destination",
        destination,
        "-derivedDataPath",
        str(derived_data_path),
        "-resultBundlePath",
        str(result_bundle_path),
        "-collect-test-diagnostics",
        "never",
    ]
    if cloned_source_packages is not None:
        # The isolated environment cannot use sandbox-exec; use cached SourcePackages without
        # downloading a runtime.
        command.extend(["-clonedSourcePackagesDirPath", str(cloned_source_packages)])
    command.extend(
        [
            f"STRICT_E2E_INPUT_SERVER_URL={server_url}",
            "STRICT_E2E_INPUT_SCENARIO=normal",
            f"STRICT_E2E_EVIDENCE_DIR={evidence_dir}",
            f"-only-testing:{TVOS_DEVICE_SELECTOR}",
            "test",
        ]
    )
    return command


def _assert_background_identity_not_after_hidden_wake(evidence_dir: Path) -> None:
    # hidden-control-wake can fall between the before-background and after-background screenshots.
    before = evidence_dir / "before-background.png"
    after = evidence_dir / "after-background.png"
    if not before.is_file() or not after.is_file():
        return
    before_mtime = before.stat().st_mtime
    after_mtime = after.stat().st_mtime
    for path in sorted(evidence_dir.glob("hidden-control-wake-*.png")):
        mtime = path.stat().st_mtime
        if before_mtime <= mtime <= after_mtime:
            raise CommandError("On background return, do not wake the control bar before checking identity.")


def _scene_mark(identity: PhotoIdentity) -> str:
    if identity.status in {"BLACK", "UNRECOGNIZABLE"}:
        return identity.status
    if identity.mark:
        return identity.mark
    return "UNRECOGNIZABLE"


def _classify_file(path: Path) -> PhotoIdentity:
    if not path.is_file():
        return PhotoIdentity("UNRECOGNIZABLE", None, {}, 0.0, ("missing",))
    return classify_screenshot(path.read_bytes())


def _write_visual_identity(evidence_dir: Path, payload: Mapping[str, Any]) -> None:
    (evidence_dir / VISUAL_IDENTITY_FILENAME).write_text(
        json.dumps(dict(payload), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def evaluate_device_evidence(evidence_dir: Path, *, fixture_set: str) -> dict[str, Any]:
    visual: dict[str, Any] = {
        "verdict": "FAIL",
        "classified": {},
        "error": None,
    }

    def persist_visual() -> None:
        try:
            _write_visual_identity(evidence_dir, visual)
        except OSError:
            pass

    try:
        payload_path = evidence_dir / "host-payload.json"
        if not payload_path.is_file():
            raise CommandError("host-payload.json is missing; an official green result alone is not enough to pass.")
        raw = json.loads(payload_path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise CommandError("host-payload.json must be a JSON object.")

        scenes: dict[str, str] = {}
        classified: dict[str, dict[str, object]] = {}
        for name, filename in SCENE_FILES.items():
            identity = _classify_file(evidence_dir / filename)
            mark = _scene_mark(identity)
            scenes[name] = mark
            classified[name] = {
                "file": filename,
                "status": identity.status,
                "mark": identity.mark,
                "notes": list(identity.notes),
            }
        visual["classified"] = classified
        visual["scenes"] = scenes

        display_before = evidence_dir / DISPLAY_BEFORE
        display_after = evidence_dir / DISPLAY_AFTER
        if not display_before.is_file() or not display_after.is_file():
            raise CommandError("Display mode evidence is missing the before-and-after screenshots; it cannot pass.")
        inspection = inspect_display_strategy(display_before.read_bytes(), display_after.read_bytes())
        if isinstance(inspection.get("before"), Mapping):
            classified["display_before"] = inspection["before"]
        if isinstance(inspection.get("after"), Mapping):
            classified["display_after"] = inspection["after"]
        visual["classified"] = classified
        visual["display"] = {
            "before_mark": inspection.get("before_mark"),
            "before_partner_marks": list(inspection.get("before_partner_marks") or []),
            "partner_marks": list(inspection.get("partner_marks") or []),
            "before_status": (
                inspection["before"].get("status")
                if isinstance(inspection.get("before"), Mapping)
                else None
            ),
            "after_status": (
                inspection["after"].get("status")
                if isinstance(inspection.get("after"), Mapping)
                else None
            ),
            "error": inspection.get("error"),
        }
        if inspection.get("error"):
            raise AccessLifecycleContractError(str(inspection["error"]))

        assert_display_before_pool_burn(raw.get("screenshot_order"))
        assert_unshown_display_partners(
            screenshot_order=raw.get("screenshot_order"),
            scenes=scenes,
            before_mark=str(inspection.get("before_mark") or ""),
        )

        missing_settings = [
            name for name in SETTINGS_PIN_EVIDENCE if not (evidence_dir / name).is_file()
        ]
        if missing_settings:
            raise CommandError("Settings or PIN screenshots are missing; this cannot pass: " + ", ".join(missing_settings))

        screenshots = {
            name: filename
            for name, filename in REQUIRED_SCREENSHOT_FILES.items()
            if (evidence_dir / filename).is_file()
        }
        after_play = scenes.get("after_play")
        after_next = scenes.get("after_next")
        pause = scenes.get("pause")
        progress = 0 if after_play == after_next and after_play != pause else 1
        _assert_background_identity_not_after_hidden_wake(evidence_dir)

        frozen = FROZEN_FIXTURE_SHA256.get(fixture_set)
        contract_payload = {
            "status": raw.get("status") or "ran",
            "identity_source": raw.get("identity_source") or "public_fixture_photo_mark",
            "settings": raw.get("settings"),
            "launch_environment": raw.get("launch_environment") or {},
            "scenes": scenes,
            "progress_after_play": progress,
            "requests": raw.get("requests"),
            "screenshots": screenshots,
            "pin_flow": raw.get("pin_flow"),
            "xctest_config_present": bool(raw.get("xctest_config_present")),
            "fixture_set": fixture_set,
            "fixture_sha256": frozen,
            "system_pause_analog": raw.get("system_pause_analog"),
            "system_pause_activation": raw.get("system_pause_activation"),
            "process_rebuilt": raw.get("process_rebuilt"),
            "home_left_app_running": raw.get("home_left_app_running"),
            "screenshot_order": raw.get("screenshot_order"),
        }
        result = evaluate_access_lifecycle_evidence(contract_payload)
        scan_sensitive_evidence(evidence_dir, synthetic_pin_values())
        result["scenes"] = scenes
        result["classified"] = classified
        result["display"] = {
            "before_mark": inspection.get("before_mark"),
            "partner_marks": list(inspection.get("partner_marks") or []),
            "before_status": visual["display"]["before_status"],
            "after_status": visual["display"]["after_status"],
        }
        result["progress_after_play"] = progress
        result["environment"] = str(raw.get("environment") or "simulator")
        result["system_pause_analog"] = str(raw.get("system_pause_analog") or "tvos_home_scene_phase")
        if result["environment"] == "apple_tv":
            raise CommandError("Simulator evidence must not be presented as evidence from a real Apple TV.")
        visual = result
        persist_visual()
        return result
    except (CommandError, AccessLifecycleContractError) as error:
        visual["error"] = str(error)
        visual["verdict"] = "FAIL"
        persist_visual()
        raise


def run_xcodebuild_command(
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
            raise CommandError(
                f"xcodebuild did not exit within {XCODEBUILD_TIMEOUT_SECONDS}s.",
                code=2,
            ) from error
    return completed.returncode


def require_official_pass(summary: TestResultsSummary) -> None:
    if (
        summary.total_test_count < 1
        or summary.passed_tests != summary.total_test_count
        or summary.failed_tests != 0
        or summary.skipped_tests != 0
        or summary.result.lower() != "passed"
    ):
        raise CommandError(
            "Official tvOS test counts must be nonzero with skip=0 and failed=0; "
            f"got total={summary.total_test_count} passed={summary.passed_tests} "
            f"failed={summary.failed_tests} skipped={summary.skipped_tests} result={summary.result}."
        )


def ensure_disk(data_available_gib: Callable[[], float], min_free_gib: int = MIN_DATA_GIB) -> None:
    available = data_available_gib()
    if available < min_free_gib:
        raise CommandError(
            f"Available space on /System/Volumes/Data is {available:.1f} GiB, below the "
            f"{min_free_gib} GiB threshold configured by --min-free-gib; stopping Xcode tests."
        )


def main(
    argv: list[str] | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
    run_xcodebuild: Callable[..., int] | None = None,
    data_available_gib: Callable[[], float] | None = None,
) -> int:
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    run_xcodebuild = run_xcodebuild_command if run_xcodebuild is None else run_xcodebuild
    data_available_gib = strict_data_available_gib if data_available_gib is None else data_available_gib
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("tvos",))
    parser.add_argument("--destination", required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--fixture-set", choices=("a", "b"), default="a")
    parser.add_argument("--cloned-source-packages", type=Path)
    parser.add_argument("--print-command", action="store_true")
    parser.add_argument(
        "--min-free-gib",
        type=parse_non_negative_int,
        default=MIN_DATA_GIB,
        metavar="N",
        help=f"minimum free GiB required before xcodebuild (default: {MIN_DATA_GIB})",
    )
    arguments = parser.parse_args(argv)

    if "Simulator" not in arguments.destination:
        print("tvOS only accepts Simulator destinations; they must not be presented as a real device.", file=stderr)
        return 2

    command_preview = build_xcodebuild_command(
        repo_root=REPO_ROOT,
        destination=arguments.destination,
        derived_data_path=arguments.evidence_dir / "DerivedData",
        result_bundle_path=arguments.evidence_dir / "access-lifecycle-tvos.xcresult",
        server_url="http://127.0.0.1:0/api",
        public_key=PUBLIC_API_KEY,
        evidence_dir=arguments.evidence_dir,
        cloned_source_packages=arguments.cloned_source_packages,
    )
    if arguments.print_command:
        print(shlex.join(command_preview), file=stdout)
        return 0

    try:
        ensure_disk(data_available_gib, arguments.min_free_gib)
    except CommandError as error:
        print(
            str(error),
            file=stderr,
        )
        return error.code

    config_path = REPO_ROOT / TASK_XCCONFIG
    did_create_config = False
    did_write_isolated_scheme = False
    owns_evidence_directory = False
    service_process = None
    derived_data_path = arguments.evidence_dir / "DerivedData"
    primary_exit_code = 0
    cleanup_failures: list[str] = []
    case_manifest: dict[str, object] | None = None
    try:
        simulator_udid = destination_udid(arguments.destination)
        write_isolated_tvos_scheme(REPO_ROOT)
        did_write_isolated_scheme = True
        prepare_evidence_directory(arguments.evidence_dir)
        owns_evidence_directory = True
        result_bundle_path = arguments.evidence_dir / "access-lifecycle-tvos.xcresult"
        case_manifest = {
            "source_sha": read_source_sha(REPO_ROOT),
            "platform": "tvos",
            "destination": arguments.destination,
            "os": "tvOS Simulator",
            "suite": "access-lifecycle-tvos",
            "e2e_ids": [
                "E2E-P1-01",
                "E2E-P1-02",
                "E2E-P1-03",
                "E2E-P1-04",
            # All six map to AccessLifecycleTVOSUITests.testTVOSAccessProtectionSettingsAndLifecycle
            # and the runner evidence checks named below.
                "E2E-P1-05",
                "E2E-P1-06",
            ],
            "human_review": "NOT_RUN",
            "result": "RUNNING",
            "environment": "simulator",
        }
        write_case_manifest(arguments.evidence_dir, case_manifest)

        xcconfig_audit = prepare_task_xcconfig(REPO_ROOT / EXAMPLE_XCCONFIG, config_path)
        did_create_config = True
        (arguments.evidence_dir / "xcconfig-audit.json").write_text(
            json.dumps(xcconfig_audit, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        for command in (["xcodebuild", "-checkFirstLaunchStatus"], ["xcodebuild", "-version"]):
            completed = subprocess.run(command, capture_output=True, text=True, check=False)
            if completed.returncode != 0:
                raise CommandError(f"{' '.join(command)} failed with exit code {completed.returncode}.")
            with (arguments.evidence_dir / "xcode-environment.log").open("a", encoding="utf-8") as log:
                log.write(f"$ {shlex.join(command)}\n{completed.stdout}")

        fixture_payload = write_fixture_artifacts(arguments.evidence_dir, arguments.fixture_set)
        case_manifest["fixture_sha256"] = fixture_payload["fixture_sha256"]
        write_case_manifest(arguments.evidence_dir, case_manifest)

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
        host, port = wait_for_service(ready_path, service_process)
        server_url = f"http://{host}:{port}/api"

        reset_log = reset_simulator_app(simulator_udid)
        (arguments.evidence_dir / "simulator-reset.log").write_text(reset_log, encoding="utf-8")

        environment = make_test_environment(
            os.environ,
            server_url=server_url,
            public_key=PUBLIC_API_KEY,
            scenario="normal",
        )
        environment["STRICT_E2E_EVIDENCE_DIR"] = str(arguments.evidence_dir)
        command = build_xcodebuild_command(
            repo_root=REPO_ROOT,
            destination=arguments.destination,
            derived_data_path=derived_data_path,
            result_bundle_path=result_bundle_path,
            server_url=server_url,
            public_key=PUBLIC_API_KEY,
            evidence_dir=arguments.evidence_dir,
            cloned_source_packages=arguments.cloned_source_packages,
        )
        (arguments.evidence_dir / "xcodebuild-command.txt").write_text(
            shlex.join(command) + "\n",
            encoding="utf-8",
        )
        case_manifest["command"] = shlex.join(command)
        write_case_manifest(arguments.evidence_dir, case_manifest)

        exit_code = run_xcodebuild(
            command,
            cwd=REPO_ROOT,
            environment=environment,
            log_path=arguments.evidence_dir / "xcodebuild.log",
        )
        if exit_code != 0:
            raise CommandError(f"xcodebuild access-lifecycle tvOS failed with exit code {exit_code}.", code=exit_code)

        summary = read_official_test_results_summary(result_bundle_path)
        require_official_pass(summary)
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
        visual = evaluate_device_evidence(arguments.evidence_dir, fixture_set=arguments.fixture_set)
        (arguments.evidence_dir / "visual-identity-runner.json").write_text(
            json.dumps(visual, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        case_manifest["result"] = "Passed"
        case_manifest["official_summary"] = {
            "totalTestCount": summary.total_test_count,
            "passedTests": summary.passed_tests,
            "failedTests": summary.failed_tests,
            "skippedTests": summary.skipped_tests,
            "result": summary.result,
        }
        case_manifest["visual_identity"] = {
            "verdict": visual["verdict"],
            "d01": visual["d01"],
            "identity_source": visual["identity_source"],
        }
        write_case_manifest(arguments.evidence_dir, case_manifest)
    except (CommandError, AccessLifecycleContractError) as error:
        print(str(error), file=stderr)
        primary_exit_code = getattr(error, "code", 2)
        if case_manifest is not None and owns_evidence_directory:
            case_manifest["result"] = "FAILED"
            case_manifest["error"] = str(error)
            try:
                write_case_manifest(arguments.evidence_dir, case_manifest)
            except OSError:
                pass
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Evidence or process I/O failed: {error}", file=stderr)
        primary_exit_code = 2
    finally:
        lifecycle: dict[str, object] = {}

        def stop_service() -> None:
            if service_process is None:
                return
            lifecycle["pid"] = service_process.pid
            lifecycle["exit"] = stop_exact_process(service_process)

        def write_lifecycle() -> None:
            if owns_evidence_directory and lifecycle:
                (arguments.evidence_dir / "service-lifecycle.json").write_text(
                    json.dumps(lifecycle, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )

        actions: list[tuple[str, Callable[[], None]]] = [
            ("stop_service", stop_service),
            ("write_service_lifecycle", write_lifecycle),
        ]
        if did_create_config:
            actions.append(
                (
                    "cleanup_task_xcconfig",
                    lambda: cleanup_task_xcconfig(REPO_ROOT / EXAMPLE_XCCONFIG, config_path),
                )
            )
        if did_write_isolated_scheme:
            actions.append(
                (
                    "remove_isolated_scheme",
                    lambda: remove_isolated_tvos_scheme(REPO_ROOT),
                )
            )
        if derived_data_path.exists():
            actions.append(("remove_derived_data", lambda: shutil.rmtree(derived_data_path)))
        cleanup_failures.extend(run_cleanup_actions(actions))
        if owns_evidence_directory:
            try:
                write_sensitive_scan(arguments.evidence_dir, [PUBLIC_API_KEY])
            except CommandError as error:
                cleanup_failures.append(f"sensitive_scan: {error}")
            try:
                scan_sensitive_evidence(arguments.evidence_dir, synthetic_pin_values())
                (arguments.evidence_dir / "pin-sensitive-scan.json").write_text(
                    json.dumps({"result": "PASS", "matched_files": []}, indent=2, sort_keys=True)
                    + "\n",
                    encoding="utf-8",
                )
            except AccessLifecycleContractError as error:
                cleanup_failures.append(f"pin_sensitive_scan: {error}")

    if cleanup_failures:
        print("Cleanup or evidence finalization failed: " + " | ".join(cleanup_failures), file=stderr)
    return choose_exit_code(primary_exit_code, cleanup_failures)


if __name__ == "__main__":
    raise SystemExit(main())
