#!/usr/bin/env python3
"""Shared smoke fixture, simulator readiness and bounded process cleanup primitives."""

from __future__ import annotations

import json
import math
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Mapping, Sequence

from ci_execution_diagnostics import active

from strict_e2e_server import PUBLIC_API_KEY, fixture_manifest, write_member_manifest
import ctypes
import queue
from threading import Event, Thread
from ci_bounded_diagnostics import MAX_LOAD_AVERAGE, RESOURCE_CATEGORIES
from ci_execution_diagnostics import finite
from ci_bounded_diagnostics import (MAX_PROCESSES, public_runner_process_name, render_runner_group_members, validate_runner_group_members)
from ci_execution_diagnostics import TRUNCATION_PREFIX, TRUNCATION_REASONS, report_truncation
from run_host_checks import GROUP_TERM_GRACE_SECONDS, group_has_live_members, stop_group


MIN_DATA_GIB = 80
# xcodebuild timeout for compile plus one UI test. Diagnostic collection is disabled.
XCODEBUILD_TIMEOUT_SECONDS = 300
SIMULATOR_RESET_TIMEOUT_SECONDS = 120
SIMULATOR_COMMAND_TIMEOUT_SECONDS = 60
SIMULATOR_BOOT_TIMEOUT_SECONDS = 600
SIMULATOR_PREPARATION_TIMEOUT_SECONDS = 600
SIMULATOR_READINESS_TIMEOUT_SECONDS = 300
SIMULATOR_READINESS_INITIAL_QUERY_TIMEOUT_SECONDS = 10
BOOT_SETTLE_TIMEOUT_SECONDS = 360
BOOT_SETTLE_WINDOW_SECONDS = 60
BOOT_SETTLE_INTERVAL_SECONDS = 10
# About one minute of missing ticks tolerates transient boot contention, but not a dead probe.
BOOT_SETTLE_MAX_CONSECUTIVE_MISSES = 6
# Process-local fallback if the job marker is unavailable; the disk marker spans processes.
_BOOT_SETTLE_ATTEMPTED = False
SERVICE_STARTUP_TIMEOUT_SECONDS = 60
# Fixture preparation has its own bound before service health checks.
SERVICE_FIXTURE_BUILD_TIMEOUT_SECONDS = 120
WRONG_PUBLIC_API_KEY = "immichslides-public-e2e-wrong-key"
PRIVATE_RESULT_BUNDLE_ROOT = Path(tempfile.gettempdir()) / "immichSlides-strict-e2e-private"
FORBIDDEN_EXACT_KEYS = {
    "IMMICH_SERVER_URL",
    "IMMICH_API_KEY",
    "IMMICH_TEST_SERVER_URL",
    "IMMICH_TEST_URL",
    "IMMICH_TEST_API_KEY",
}
PLATFORM_SETTINGS = {
    "ios": ("immichSlides-iOS", "StrictE2E-iOS", None),
    "tvos": ("immichSlides-tvOS", "StrictE2E-tvOS", None),
}


class CommandError(Exception):
    def __init__(self, message: str, code: int = 2) -> None:
        super().__init__(message)
        self.code = code


class InfrastructureTimeout(CommandError):
    """Retain the phase without exposing subprocess arguments or captured output."""

    def __init__(self, phase: str, timeout_seconds: float) -> None:
        message = f"{phase} timed out after {timeout_seconds:.1f}s."
        super().__init__(message, code=124)
        self.entry = {"code": phase + "-timeout", "message": message}


def simulator_command(command: list[str], phase: str, *, deadline: float | None = None,
                      timeout_seconds: float = SIMULATOR_COMMAND_TIMEOUT_SECONDS,
                      accepts_nonzero: Callable[[subprocess.CompletedProcess], bool] | None = None):
    budget = min(timeout_seconds, deadline - time.monotonic()) if deadline is not None else timeout_seconds
    if budget <= 0:
        raise InfrastructureTimeout(phase, 0)
    recorder = active()
    recorder = recorder if phase in ("simulator-boot", "simulator-bootstatus", "simulator-container", "simulator-preparation") else None
    started, cpu = time.monotonic(), time.process_time()
    sequence = recorder.next_sequence() if recorder else 0
    def mark(state):
        if recorder:
            recorder.event("preparation", phase, state, sequence, elapsed=time.monotonic() - started,
                           cpu=time.process_time() - cpu)
    mark("started")
    try:
        completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=budget)
    except subprocess.TimeoutExpired as error:
        # run has already killed, waited and closed pipes; internal boundaries are unobserved.
        mark("timeout")
        mark("reap-completed")
        raise InfrastructureTimeout(phase, budget) from error
    if completed.returncode == 0 or (accepts_nonzero is not None and accepts_nonzero(completed)):
        mark("completed")
    return completed


def _is_forbidden_key(key: str) -> bool:
    for prefix in ("TEST_RUNNER_", "SIMCTL_CHILD_"):
        if key.startswith(prefix):
            return _is_forbidden_key(key[len(prefix):])
    return key.startswith("UI_TEST_") or key in FORBIDDEN_EXACT_KEYS


def prepare_evidence_directory(evidence_dir: Path) -> None:
    evidence_dir.mkdir(parents=True, exist_ok=True)
    if any(evidence_dir.iterdir()):
        raise CommandError("The evidence directory is not empty; strict E2E refuses to start to avoid overwriting or mixing files.")
    (evidence_dir / ".strict-e2e-run.json").write_text(
        json.dumps({"format": 1}, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def read_source_sha(repo_root: Path) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repo_root), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    sha = completed.stdout.strip()
    if completed.returncode != 0 or len(sha) != 40 or any(char not in "0123456789abcdef" for char in sha.lower()):
        raise CommandError("Could not read the current source SHA.")
    return sha


def read_source_dirty_paths(repo_root: Path) -> list[str]:
    completed = subprocess.run(
        ["git", "-C", str(repo_root), "status", "--porcelain=v1", "--untracked-files=all"],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise CommandError("Could not read the current working tree status.")
    return [line for line in completed.stdout.splitlines() if line]


def write_case_manifest(evidence_dir: Path, payload: Mapping[str, object]) -> None:
    (evidence_dir / "case-manifest.json").write_text(
        json.dumps(dict(payload), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_fixture_artifacts(evidence_dir: Path, fixture_set: str) -> dict[str, object]:
    fixture_payload = fixture_manifest(fixture_set)
    (evidence_dir / "fixture-manifest.json").write_text(
        json.dumps(fixture_payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_member_manifest(evidence_dir / "member-manifest.json", fixture_set)
    return fixture_payload
def _is_already_booted(stderr: str) -> bool:
    text = stderr.lower()
    return "current state: booted" in text or "already booted" in text


def boot_simulator(simulator_udid: str, *, report: Callable[[str], None] | None = None,
                   deadline: float | None = None, boot_submitted: bool = False,
                   report_step: Callable[[str], None] | None = None) -> str:
    """Give cold boot its own deadline before any app-reset clock starts."""
    started = time.monotonic()
    deadline = min(deadline, started + SIMULATOR_BOOT_TIMEOUT_SECONDS) if deadline is not None else started + SIMULATOR_BOOT_TIMEOUT_SECONDS
    lines = []
    # A submitted early boot needs no second short command during the cold-device stall.
    steps = [("bootstatus", SIMULATOR_BOOT_TIMEOUT_SECONDS)]
    if not boot_submitted:
        steps.insert(0, ("boot", SIMULATOR_COMMAND_TIMEOUT_SECONDS))
    for step, cap in steps:
        if report_step is not None:
            report_step("simulator-reset:" + step)
        phase = "simulator-" + step
        phase_started = time.monotonic()
        outcome = "failed"
        try:
            completed = simulator_command(["xcrun", "simctl", step, simulator_udid, *(["-b"] if step == "bootstatus" else [])],
                                          phase, deadline=deadline, timeout_seconds=cap,
                                          accepts_nonzero=lambda result: step == "boot" and _is_already_booted(result.stderr))
            lines.append(f"{step}_exit={completed.returncode}")
            if step == "bootstatus" and "Booting device..." in (completed.stdout or ""):
                line = "simulator-bootstatus: started-device=true"
                lines.append(line)
                if report is not None:
                    report(line)
            if completed.returncode and not (step == "boot" and _is_already_booted(completed.stderr)):
                message = "Simulator boot failed" if step == "boot" else "Simulator did not become available"
                raise CommandError(f"{message} (exit {completed.returncode}); cannot continue with a clean install.")
            outcome = "passed"
        finally:
            line = (f"{phase}: {outcome}; elapsed={time.monotonic() - phase_started:.1f}s; "
                    f"total={time.monotonic() - started:.1f}s; total budget={SIMULATOR_BOOT_TIMEOUT_SECONDS}s")
            lines.append(line)
            if report is not None:
                report(line)
    return "\n".join(lines) + "\n"


def wait_for_simulator_app_response(simulator_udid: str, bundle_id: str, *, report: Callable[[str], None],
                                    deadline: float | None = None) -> tuple[str | None, str]:
    """Let timed-out post-boot queries recover before the clean-reset clock starts."""
    return _wait_for_simulator_response(
        lambda deadline, timeout: simulator_app_container(simulator_udid, bundle_id, deadline=deadline,
                                                          timeout_seconds=timeout),
        "simulator-readiness", report=report, deadline=deadline)


def wait_for_simulator_service_response(simulator_udid: str, *, report: Callable[[str], None],
                                       deadline: float):
    """Check the bootstrap service before builds without querying the cold app database."""
    def query(deadline, timeout):
        # simctl resolves a bare executable in the device; absolute paths refer to the host.
        completed = simulator_command(
            ["xcrun", "simctl", "spawn", simulator_udid, "launchctl", "print", "system/com.apple.lsd"],
            "simulator-preparation", deadline=deadline, timeout_seconds=timeout)
        if completed.returncode:
            raise CommandError(f"Simulator LaunchServices registration check failed (exit {completed.returncode}).")
    return _wait_for_simulator_response(query, "simulator-readiness", report=report, deadline=deadline)


def _wait_for_simulator_response(query, phase: str, *, report: Callable[[str], None],
                                 deadline: float | None = None):
    started = time.monotonic()
    deadline = min(deadline, started + SIMULATOR_READINESS_TIMEOUT_SECONDS) if deadline is not None else started + SIMULATOR_READINESS_TIMEOUT_SECONDS
    budget = max(0, deadline - started)
    attempts = 0
    query_timeout = SIMULATOR_READINESS_INITIAL_QUERY_TIMEOUT_SECONDS
    outcome = "failed"
    lines = []
    recorder = active() if phase == "simulator-readiness" else None
    sequence = recorder.next_sequence() if recorder else 0
    if recorder:
        recorder.event("preparation", phase, "started", sequence)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise InfrastructureTimeout(phase, budget)
            attempts += 1
            query_budget = min(query_timeout, remaining)
            query_started = time.monotonic()
            try:
                response = query(deadline, query_budget)
            except InfrastructureTimeout:
                line = (f"{phase}: query timed out; attempt={attempts}; timeout={query_budget:.1f}s; "
                        f"query_elapsed={time.monotonic() - query_started:.1f}s; elapsed={time.monotonic() - started:.1f}s")
                lines.append(line)
                report(line)
                query_timeout = min(query_timeout * 2, SIMULATOR_COMMAND_TIMEOUT_SECONDS)
                continue
            if time.monotonic() >= deadline:
                raise InfrastructureTimeout(phase, budget)
            line = (f"{phase}: query completed; attempt={attempts}; "
                    f"query_elapsed={time.monotonic() - query_started:.3f}s; elapsed={time.monotonic() - started:.3f}s")
            lines.append(line)
            report(line)
            outcome = "passed"
            break
    finally:
        elapsed = time.monotonic() - started
        if recorder and (outcome == "passed" or isinstance(sys.exc_info()[1], InfrastructureTimeout)):
            recorder.event("preparation", phase, "timeout" if outcome != "passed" else "completed", sequence,
                           elapsed=elapsed)
        line = (f"{phase}: {outcome}; attempts={attempts}; elapsed={elapsed:.1f}s; "
                f"total budget={budget:g}s; "
                f"deadline_overrun={max(0, elapsed - budget):.1f}s")
        lines.append(line)
        report(line)
    return response, "\n".join(lines) + "\n"


def _boot_process_output(command: Sequence[str], deadline: float) -> str:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError
    completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=min(5, remaining))
    if completed.returncode:
        raise ValueError
    return completed.stdout


def _boot_manager_pid(device: str, deadline: float) -> int:
    root = int(_boot_process_output(["xcrun", "simctl", "spawn", device, "launchctl", "managerpid"], deadline).strip())
    if root <= 0:
        raise ValueError
    return root


def _boot_device_cpu(root: int, deadline: float) -> float | None:
    """Read numeric process ancestry for this device without collecting names or argv."""
    rows = {}
    raw = _boot_process_output(["/bin/ps", "-A", "-o", "pid=,ppid=,%cpu="], deadline)
    if len(raw) > 2 * 1024 * 1024:
        return None
    for line in raw.splitlines():
        try:
            pid, parent, cpu = line.split()
            pid, parent, cpu = int(pid), int(parent), float(cpu)
        except ValueError:
            return None
        if pid <= 0 or parent < 0 or pid in rows or not math.isfinite(cpu) or cpu < 0:
            return None
        rows[pid] = (parent, cpu)
    if root not in rows:
        return None
    owned, pending = {root}, [root]
    children = {}
    for pid, (parent, _) in rows.items():
        children.setdefault(parent, []).append(pid)
    while pending:
        for pid in children.get(pending.pop(), []):
            if pid not in owned:
                owned.add(pid)
                pending.append(pid)
    return sum(rows[pid][1] for pid in owned)


def _settle_simulator_boot(device: str, deadline: float) -> str:
    """Best-effort job-once admission, wholly inside the existing preparation budget."""
    global _BOOT_SETTLE_ATTEMPTED
    started = time.monotonic()
    outcome, idle, cpu, cores, threshold = "unavailable", None, None, None, None
    missed_points = consecutive_misses = 0
    probe = None
    try:
        if not (os.environ.get("GITHUB_ACTIONS") == "true"
                and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
                and os.environ.get("GITHUB_EVENT_NAME") in {"schedule", "workflow_dispatch"}):
            outcome = "skipped-environment"
        elif _BOOT_SETTLE_ATTEMPTED:
            outcome = "skipped-repeat"
        else:
            _BOOT_SETTLE_ATTEMPTED = True
            # RUNNER_TEMP is job-scoped, so repeated preparations share one attempt.
            marker = Path(os.environ["RUNNER_TEMP"]) / "immichslides-boot-settle-attempted"
            try:
                descriptor = os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                outcome = "skipped-repeat"
            else:
                os.close(descriptor)
                cores = os.cpu_count()
                if not cores or cores < 1:
                    raise ValueError
                threshold = max(30.0, 100.0 / cores)
                deadline = min(deadline, started + BOOT_SETTLE_TIMEOUT_SECONDS)
                # The device's manager PID is stable throughout this boot.
                root = _boot_manager_pid(device, deadline)
                # HostProbe bounds each Mach read to 0.2 seconds and abandons stalled workers.
                probe = HostProbe(device)
                probe.sample()
                qualifying_since = None
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        outcome = "timed-out"
                        break
                    if probe.unavailable:
                        outcome = "sampling-failed"
                        break
                    time.sleep(min(BOOT_SETTLE_INTERVAL_SECONDS, remaining))
                    if time.monotonic() >= deadline:
                        outcome = "timed-out"
                        break
                    idle = cpu = None
                    try:
                        sample = probe.sample()
                        idle = sample.get("idle_percent") if sample else None
                        cpu = _boot_device_cpu(root, deadline)
                        if (idle is None or cpu is None or not math.isfinite(idle) or not 0 <= idle <= 100
                                or not math.isfinite(cpu) or cpu < 0):
                            raise ValueError
                    except (OSError, ValueError, TypeError, AttributeError, KeyError, RuntimeError, subprocess.SubprocessError):
                        missed_points += 1
                        consecutive_misses += 1
                        qualifying_since = None
                        if time.monotonic() >= deadline:
                            outcome = "timed-out"
                            break
                        if consecutive_misses >= BOOT_SETTLE_MAX_CONSECUTIVE_MISSES:
                            outcome = "sampling-failed"
                            break
                        continue
                    consecutive_misses = 0
                    now = time.monotonic()
                    if now >= deadline:
                        outcome = "timed-out"
                        break
                    if idle >= threshold and cpu <= 120:
                        if qualifying_since is None:
                            qualifying_since = now
                        if now - qualifying_since >= BOOT_SETTLE_WINDOW_SECONDS:
                            outcome = "settled"
                            break
                    else:
                        qualifying_since = None
    except (ImportError, OSError, ValueError, TypeError, AttributeError, KeyError, RuntimeError, subprocess.SubprocessError):
        # Never publish exception text, commands, process identities or a new verdict.
        outcome = "timed-out" if time.monotonic() >= deadline else "unavailable"
    finally:
        if probe is not None:
            probe.close()
    def number(value):
        return f"{value:.3f}" if isinstance(value, (int, float)) and math.isfinite(value) else "null"
    return (f"simulator-boot-settle: outcome={outcome}; duration_seconds={time.monotonic() - started:.3f}; "
            f"idle_percent={number(idle)}; device_cpu_percent={number(cpu)}; "
            f"logical_cores={cores if isinstance(cores, int) else 'null'}; idle_threshold_percent={number(threshold)}; "
            f"missed_points={missed_points}")


def prepare_simulator(simulator_udid: str, bundle_id: str = "com.331works.immichSlides", *,
                      report: Callable[[str], None] | None = None, boot_submitted: bool = False,
                      should_check_app: bool = True, should_settle_boot: bool = False,
                      report_step: Callable[[str], None] | None = None) -> tuple[str | None, str]:
    """Gate preparation; prebuild callers may request service registration only, returning no container fact."""
    report = report or (lambda line: print(line, flush=True))
    recorder = active()
    initial_sample = recorder.sample("preparation", initial=True) if recorder else None
    started = time.monotonic()
    deadline = started + SIMULATOR_PREPARATION_TIMEOUT_SECONDS
    lines = [f"simulator_id={simulator_udid}"]
    outcome = "failed"
    sequence = recorder.next_sequence() if recorder else 0
    if recorder:
        start_event = recorder.event("preparation", "simulator-preparation", "started", sequence)
    try:
        lines.extend(boot_simulator(simulator_udid, report=report, deadline=deadline,
                                    boot_submitted=boot_submitted, report_step=report_step).splitlines())
        if report_step is not None:
            report_step("simulator-reset:readiness")
        if should_check_app:
            container, readiness_log = wait_for_simulator_app_response(simulator_udid, bundle_id, report=report, deadline=deadline)
        else:
            line = "simulator-readiness: probe=launch-services-registration"
            lines.append(line)
            report(line)
            container, readiness_log = wait_for_simulator_service_response(simulator_udid, report=report, deadline=deadline)
        lines.extend(readiness_log.splitlines())
        if should_settle_boot and boot_submitted:
            line = _settle_simulator_boot(simulator_udid, deadline)
            lines.append(line)
            report(line)
        outcome = "passed"
    finally:
        elapsed = time.monotonic() - started
        if recorder:
            if outcome != "passed" and start_event is not None:
                start_event["sample"] = initial_sample
            if outcome == "passed" or isinstance(sys.exc_info()[1], InfrastructureTimeout):
                recorder.event("preparation", "simulator-preparation", "timeout" if outcome != "passed" else "completed",
                               sequence, elapsed=elapsed, sample=recorder.sample("preparation") if outcome != "passed" else None)
        line = (f"simulator-preparation: {outcome}; elapsed={elapsed:.1f}s; "
                f"total budget={SIMULATOR_PREPARATION_TIMEOUT_SECONDS}s; "
                f"deadline_overrun={max(0, elapsed - SIMULATOR_PREPARATION_TIMEOUT_SECONDS):.1f}s")
        lines.append(line)
        report(line)
    return container, "\n".join(lines) + "\n"


def _disable_password_autofill(simulator_udid: str, reset_deadline: float, report: Callable[[str], None], *,
                               report_step: Callable[[str], None] | None = None) -> list[str]:
    report_step = report_step or (lambda step: None)
    started = time.monotonic()
    deadline = min(reset_deadline, started + SIMULATOR_COMMAND_TIMEOUT_SECONDS)
    budget = max(0, deadline - started)
    lines, outcome = [], "failed"

    def command(argv: list[str], step: str):
        report_step("simulator-reset:autofill-" + step)
        step_started = time.monotonic()
        try:
            return simulator_command(argv, "simulator-password-autofill-" + step, deadline=deadline)
        finally:
            line = f"password-autofill-{step}: elapsed={time.monotonic() - step_started:.3f}s"
            lines.append(line)
            report(line)

    try:
        inventory = command(["xcrun", "simctl", "list", "devices", "--json"], "device")
        if inventory.returncode:
            raise CommandError(f"Simulator password AutoFill device lookup failed (exit {inventory.returncode}); "
                               f"stderr={inventory.stderr.strip()!r}.")
        try:
            devices = [entry for entries in json.loads(inventory.stdout)["devices"].values() for entry in entries
                       if entry.get("udid") == simulator_udid]
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            raise CommandError("Simulator password AutoFill device lookup returned invalid JSON.") from error
        if (len(devices) != 1 or not isinstance(devices[0].get("dataPath"), str)
                or not Path(devices[0]["dataPath"]).is_absolute()):
            raise CommandError("Simulator password AutoFill device lookup did not identify one absolute data path.")
        preference = Path(devices[0]["dataPath"]) / "Library/Preferences/com.apple.WebUI.plist"
        disabled = command(["xcrun", "simctl", "spawn", simulator_udid, "defaults", "write",
                            "com.apple.WebUI", "AutoFillPasswords", "-bool", "NO"], "disable")
        lines.append(f"password_autofill_write_exit={disabled.returncode}; stderr={disabled.stderr.strip()!r}")
        if disabled.returncode:
            raise CommandError("Simulator password AutoFill disable failed; cannot continue with isolated state.\n" + "\n".join(lines))
        # Read the persisted boolean on the host; a second device spawn can exhaust a starved reset.
        readback = command(["/usr/bin/plutil", "-extract", "AutoFillPasswords", "raw", "-expect", "bool",
                            "-o", "-", str(preference)], "readback")
        lines.append(f"password_autofill_read_exit={readback.returncode}; stderr={readback.stderr.strip()!r}; "
                     f"value={readback.stdout.strip()!r}")
        if readback.returncode or readback.stdout.strip() != "false":
            raise CommandError("Simulator password AutoFill readback failed; cannot continue with isolated state.\n" + "\n".join(lines))
        report_step("simulator-reset:autofill-deadline")
        if time.monotonic() >= deadline:
            raise InfrastructureTimeout("simulator-password-autofill", budget)
        report_step("pretest-other")
        lines.append("password_autofill=disabled; domain=com.apple.WebUI; key=AutoFillPasswords; readback=false; verifier=host-plutil")
        report(lines[-1])
        outcome = "passed"
    finally:
        line = (f"password-autofill: {outcome}; elapsed={time.monotonic() - started:.3f}s; budget={budget:.3f}s; "
                f"reset_remaining={max(0, reset_deadline - time.monotonic()):.3f}s")
        lines.append(line)
        try:
            report(line)
        except (OSError, ValueError):
            report_step("pretest-other")
            raise
    return lines


def _simulator_reset_stderr_class(stderr: str) -> str:
    text = stderr.strip().lower()
    for classification, fragments in (
        ("service-unavailable", ("service connection", "service unavailable", "connection invalid", "connection interrupted")),
        ("device-unavailable", ("invalid device", "current state", "device unavailable", "shutdown")),
        ("permission-denied", ("permission denied", "operation not permitted")),
        ("posix-error", ("nsposixerrordomain",)),
        ("simulator-error", ("com.apple.coresimulator.simerror",)),
    ):
        if any(fragment in text for fragment in fragments):
            return classification
    return "unclassified" if text else "empty"


def reset_simulator_app(simulator_udid: str, bundle_id: str = "com.331works.immichSlides", *,
                        platform: str, boot_submitted: bool = False,
                        report_step: Callable[[str], None] | None = None) -> str:
    report_step = report_step or (lambda step: None)
    report_step("pretest-other")
    if platform not in ("ios", "tvos"):
        raise CommandError(f"Unsupported simulator platform {platform!r}; expected 'ios' or 'tvos'.")
    # The fixed sleep waits for simctl to release the container lock; a second uninstall failure must stop the run.
    report = lambda line: print(line, flush=True)
    container, preparation_log = prepare_simulator(simulator_udid, bundle_id, report=report,
        boot_submitted=boot_submitted, report_step=report_step)
    lines = preparation_log.splitlines()
    installed = container is not None
    started = time.monotonic()
    deadline = started + SIMULATOR_RESET_TIMEOUT_SECONDS
    # Terminate stalled after cold boot on hosted runners; skip it only when the app is absent.
    if installed:
        report_step("simulator-reset:terminate")
        terminate = simulator_command(
            ["xcrun", "simctl", "terminate", simulator_udid, bundle_id], "simulator-terminate", deadline=deadline,
        )
        lines.append(f"terminate_exit={terminate.returncode}")
    else:
        lines.append("terminate_skipped=app-absent")
        report(lines[-1])
    report_step("simulator-reset:uninstall")
    uninstall = simulator_command(
        ["xcrun", "simctl", "uninstall", simulator_udid, bundle_id], "simulator-uninstall", deadline=deadline,
    )
    lines.append(f"uninstall_exit={uninstall.returncode}")
    if uninstall.returncode != 0:
        report_step("simulator-reset:uninstall-retry")
        time.sleep(1)
        retry = simulator_command(
            ["xcrun", "simctl", "uninstall", simulator_udid, bundle_id], "simulator-uninstall-retry", deadline=deadline,
        )
        lines.append(f"uninstall_retry_exit={retry.returncode}")
        if retry.stderr.strip():
            lines.append(f"uninstall_retry_stderr={retry.stderr.strip()}")
        if retry.returncode != 0:
            raise CommandError("Second uninstall failed; cannot continue with a clean install.\n" + "\n".join(lines))
    if uninstall.stderr.strip():
        lines.append(f"uninstall_stderr={uninstall.stderr.strip()}")
    report_step("simulator-reset:container")
    time.sleep(1)
    container = simulator_app_container(simulator_udid, bundle_id, deadline=deadline)
    if container:
        lines.append(f"app_container={container}")
        raise CommandError(
            "App container is still accessible after uninstall; cannot continue with a clean install.\n" + "\n".join(lines)
        )
    lines.append("app_container=absent")
    # These devices are dedicated to strict tests: uninstall alone leaves keychain and TCC state.
    for step, command in (
        ("keychain", ["xcrun", "simctl", "keychain", simulator_udid, "reset"]),
        ("privacy", ["xcrun", "simctl", "privacy", simulator_udid, "reset", "all"]),
    ):
        report_step("simulator-reset:" + step)
        completed = simulator_command(command, f"simulator-{step}-reset", deadline=deadline)
        lines.append(f"{step}_reset_exit={completed.returncode}; stderr_class={_simulator_reset_stderr_class(completed.stderr)}")
        report(lines[-1])
        if completed.returncode != 0:
            report_step("simulator-reset:" + step + "-retry")
            time.sleep(min(1, max(0, deadline - time.monotonic())))
            completed = simulator_command(command, f"simulator-{step}-reset-retry", deadline=deadline)
            lines.append(f"{step}_reset_retry_exit={completed.returncode}; stderr_class={_simulator_reset_stderr_class(completed.stderr)}")
            report(lines[-1])
        if completed.returncode != 0:
            raise CommandError(f"Simulator {step} reset failed; cannot continue with isolated state.\n" + "\n".join(lines))
    if platform == "ios":
        lines.extend(_disable_password_autofill(simulator_udid, deadline, report, report_step=report_step))
    lines.append(f"simulator-reset: elapsed={time.monotonic() - started:.1f}s; total budget={SIMULATOR_RESET_TIMEOUT_SECONDS}s")
    report(lines[-1])
    return "\n".join(lines) + "\n"


def simulator_app_container(simulator_udid: str, bundle_id: str, *, deadline: float | None = None,
                            timeout_seconds: float = SIMULATOR_COMMAND_TIMEOUT_SECONDS) -> str | None:
    completed = simulator_command(
        ["xcrun", "simctl", "get_app_container", simulator_udid, bundle_id], "simulator-container", deadline=deadline,
        timeout_seconds=timeout_seconds,
        accepts_nonzero=lambda result: result.returncode == 2,
    )
    path = completed.stdout.strip()
    if completed.returncode == 0 and path:
        return path
    if completed.returncode == 2:
        return None
    detail = completed.stderr.strip() or completed.stdout.strip()
    message = f"Could not determine whether the App container exists (simctl get_app_container exit {completed.returncode})."
    if detail:
        message += " " + detail
    raise CommandError(message)


def destination_udid(destination: str) -> str:
    for component in destination.split(","):
        key, separator, value = component.strip().partition("=")
        if separator and key == "id" and value:
            return value
    raise CommandError("destination must explicitly include a Simulator id.")


def wait_for_service(ready_path: Path, process: subprocess.Popen[bytes], *,
                     startup_log: Path | None = None,
                     fixture_build_timeout_seconds: float = SERVICE_FIXTURE_BUILD_TIMEOUT_SECONDS,
                     startup_timeout_seconds: float = SERVICE_STARTUP_TIMEOUT_SECONDS) -> tuple[str, int]:
    try:
        if startup_log is not None:
            _wait_for_fixture_build(process, startup_log, fixture_build_timeout_seconds)
        return _wait_for_service(ready_path, process, startup_timeout_seconds)
    except CommandError as error:
        lines = _service_startup_diagnostics(startup_log)
        if lines:
            phase, state = re.search(r"phase=([^;]+); state=([^;]+)", lines[-1]).groups()
            raise CommandError(f"{error} startup_phase={phase}; startup_state={state}.", code=error.code) from error
        raise
    finally:
        for line in _service_startup_diagnostics(startup_log):
            print(line, flush=True)


def _service_startup_diagnostics(path: Path | None) -> list[str]:
    if path is None:
        return []
    try:
        with path.open("rb") as handle:
            text = handle.read(4096).decode("utf-8", errors="replace")
    except OSError:
        return []
    pattern = (r"fixture-startup: phase=(import|fixture-build|bind|ready-write); state=(started|completed); "
               r"elapsed=\d{1,9}\.\d{3}s; total=\d{1,9}\.\d{3}s")
    return [line for line in text.splitlines() if re.fullmatch(pattern, line)][:8]


def _wait_for_fixture_build(process: subprocess.Popen[bytes], startup_log: Path, timeout_seconds: float) -> None:
    started = time.monotonic()
    deadline = started + timeout_seconds
    print(f"fixture-service: build started; budget={timeout_seconds}s", flush=True)
    while time.monotonic() < deadline:
        exit_code = process.poll()
        lines = _service_startup_diagnostics(startup_log)
        if exit_code is not None:
            phase = re.search(r"phase=([^;]+);", lines[-1]).group(1) if lines else "unknown"
            raise CommandError(f"Test service exited early during {phase} with exit {exit_code}.")
        if any("phase=fixture-build; state=completed;" in line for line in lines) and time.monotonic() < deadline:
            print(f"fixture-service: build completed; elapsed={time.monotonic() - started:.1f}s; "
                  f"budget={timeout_seconds}s", flush=True)
            return
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    raise CommandError(f"Test service fixture build timed out after {time.monotonic() - started:.1f}s "
                       f"(budget={timeout_seconds}s).", code=124)


def _wait_for_service(ready_path: Path, process: subprocess.Popen[bytes], timeout_seconds: float) -> tuple[str, int]:
    started = time.monotonic()
    deadline = started + timeout_seconds
    last_state = "ready-file-missing"
    while time.monotonic() < deadline:
        exit_code = process.poll()
        if exit_code is not None:
            raise CommandError(f"Test service exited early with exit {exit_code}.")
        last_state = "ready-file-missing"
        if ready_path.is_file():
            last_state = "ready-file-invalid"
            try:
                payload = json.loads(ready_path.read_text(encoding="utf-8"))
                if payload.get("pid") != process.pid:
                    raise CommandError("The PID in the test service ready file does not match the started child process.")
                host = payload["host"]
                port = int(payload["port"])
                last_state = "health-check-pending"
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=min(1, remaining)) as response:
                    last_state = f"health-http-{response.status}"
                    if response.status == 200 and time.monotonic() < deadline:
                        print(f"fixture-service: healthy; elapsed={time.monotonic() - started:.1f}s; "
                              f"total budget={timeout_seconds}s", flush=True)
                        return str(host), port
            except urllib.error.HTTPError as error:
                last_state = f"health-http-{error.code}"
            except (OSError, KeyError, TypeError, ValueError) as error:
                last_state += f":{type(error).__name__}"
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    raise CommandError(f"Test service health check timed out after {time.monotonic() - started:.1f}s "
                       f"(budget={timeout_seconds}s; last_state={last_state}).", code=124)


def stop_exact_process(process: subprocess.Popen[bytes]) -> int:
    if process.poll() is None:
        process.terminate()
        try:
            return process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    return process.wait(timeout=5)


HOST_SAMPLE_TIMEOUT_SECONDS = 0.2
HOST_IDLE_MIN_INTERVAL_SECONDS = 1
HOST_WALL_BUDGET_SECONDS = 10


class HostCpu:
    """Read actual interval idle ticks; process CPU is ps's short-term estimate."""

    def __init__(self):
        self.library = None
        self.host = None
        self.previous = None
        self.previous_read_at = None
        if sys.platform == "darwin":
            self.library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            self.library.mach_host_self.restype = ctypes.c_uint32
            self.library.host_statistics.argtypes = [ctypes.c_uint32, ctypes.c_int,
                ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
            self.host = self.library.mach_host_self()

    def idle(self):
        if self.library is None:
            return None
        ticks = (ctypes.c_uint32 * 4)()
        count = ctypes.c_uint32(4)
        if self.library.host_statistics(self.host, 3, ticks, ctypes.byref(count)) != 0 or count.value != 4:
            self.previous = None
            self.previous_read_at = None
            return None
        read_at = time.monotonic()
        previous, self.previous = self.previous, tuple(ticks)
        previous_read_at, self.previous_read_at = self.previous_read_at, read_at
        # A late worker can leave only a few milliseconds of ticks before the next read.
        if previous is None or previous_read_at is None or read_at - previous_read_at < HOST_IDLE_MIN_INTERVAL_SECONDS:
            return None
        delta = [(current - old) & 0xffffffff for old, current in zip(previous, ticks)]
        return 100 * delta[2] / sum(delta) if sum(delta) else None

    def close(self):
        if self.library is not None and self.host is not None:
            task = ctypes.c_uint32.in_dll(self.library, "mach_task_self_").value
            self.library.mach_port_deallocate(task, self.host)
            self.host = None

def resource_sample(host_cpu, device, timeout):
    idle = host_cpu.idle()
    try:
        load = finite(os.getloadavg()[0], MAX_LOAD_AVERAGE)
    except OSError:
        load = None
    return {"idle_percent": idle, "load_1m": load, "cpu_percent": dict.fromkeys(RESOURCE_CATEGORIES)}


class HostProbe:
    """Bound native host reads independently of the inherited process-snapshot pool."""

    def __init__(self, device):
        self.device = device
        self.host = None
        self.spent = 0.0
        self.unavailable = False
        self.done = None
        self.worker = None
        self.requests = queue.Queue(maxsize=1)
        self.request_count = 0

    def _run(self):
        try:
            while True:
                request = self.requests.get()
                if request is None or self.unavailable:
                    break
                done, values = request
                try:
                    if self.host is None:
                        self.host = HostCpu()
                        self.host.idle()
                    values.append(resource_sample(self.host, self.device, None))
                except (OSError, ValueError, TypeError, AttributeError):
                    pass
                finally:
                    done.set()
        finally:
            if self.host is not None:
                self.host.close()

    def sample(self):
        remaining = HOST_WALL_BUDGET_SECONDS - self.spent
        if self.unavailable or remaining <= 0:
            self.unavailable = True
            return None
        # A slow native read may finish between ticks; never overlap it with a new worker.
        if self.done is not None and not self.done.is_set():
            return None
        done, values = Event(), []
        self.done = done
        started = time.perf_counter()
        self.request_count += 1
        try:
            # Pay thread startup once; per-tick startup can exhaust the cap on a loaded host.
            if self.worker is None:
                worker = Thread(target=self._run, daemon=True)
                worker.start()
                self.worker = worker
            self.requests.put_nowait((done, values))
            finished = done.wait(max(0, min(HOST_SAMPLE_TIMEOUT_SECONDS, remaining)
                                        - (time.perf_counter() - started)))
        except (OSError, RuntimeError, queue.Full):
            finished = False
            if self.worker is None:
                done.set()
        self.spent += time.perf_counter() - started
        self.unavailable = finished and not values
        return values[0] if finished and values else None

    def close(self):
        self.unavailable = True
        # Wake an idle worker; an in-flight read observes shutdown before taking more work.
        try:
            self.requests.put_nowait(None)
        except queue.Full:
            # Replace queued work with shutdown so a late worker cannot block on get().
            try:
                pending = self.requests.get_nowait()
                if pending is not None:
                    pending[0].set()
            except queue.Empty:
                pass
            try:
                self.requests.put_nowait(None)
            except queue.Full:
                pass


RUNNER_MEMBER_PROBE_TIMEOUT_SECONDS = 3
MAX_RUNNER_PROCESS_TABLE_BYTES = 2 * 1024 * 1024


class RunnerGroupCleanupError(RuntimeError):
    """Build paths must be retained if runner descendants cannot be stopped."""

    def __init__(self, reason, *, members=None, truncated=False):
        self.members = members
        self.members_truncated = truncated
        super().__init__(reason + "; live members: " + render_runner_group_members(members, truncated=truncated))

def runner_group_members(group_id):
    """A failure-only ps projection: no arguments, paths, PIDs or arbitrary names survive."""
    try:
        deadline = time.monotonic() + RUNNER_MEMBER_PROBE_TIMEOUT_SECONDS
        table_bytes = 0
        def read_rows(selection):
            nonlocal table_bytes
            command = ["ps", *selection, "-o", "pid=,ppid=,pgid=,stat=,comm="]
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, 0)
            try:
                table = subprocess.check_output(command, text=True, stderr=subprocess.PIPE, timeout=remaining)
            except subprocess.CalledProcessError as error:
                if selection[0] in {"-g", "-p"} and error.returncode == 1 and error.output == "" and error.stderr == "":
                    return {}
                raise
            table_bytes += len(table.encode())
            if table_bytes > MAX_RUNNER_PROCESS_TABLE_BYTES:
                raise ValueError("runner process table exceeds parse limit")
            rows = [line.split(None, 4) for line in table.splitlines()]
            return {row[0]: row for row in rows if len(row) == 5 and all(value.isdecimal() for value in row[:3])}

        # Darwin's -g selects a process group; procps uses it for sessions instead.
        rows = read_rows(["-g", str(group_id)] if sys.platform == "darwin" else ["-ax"])
        live = [row for row in rows.values() if row[2] == str(group_id) and not row[3].startswith("Z")]
        parents = sorted({row[1] for row in live[:MAX_PROCESSES] if row[1] != "0" and row[1] not in rows})
        if parents:
            try:
                rows.update(read_rows(["-p", ",".join(parents)]))
            except (OSError, ValueError, subprocess.SubprocessError):
                # Parent lookup is optional; keep the known survivors if its remaining budget runs out.
                pass
        members = []
        for row in live[:MAX_PROCESSES]:
            parent = rows.get(row[1])
            members.append({"name": public_runner_process_name(row[4]),
                "parent": public_runner_process_name(parent[4]) if parent else "unknown",
                "state": "exiting" if "E" in row[3] else {"R": "running", "S": "sleeping", "I": "sleeping", "U": "uninterruptible",
                          "D": "uninterruptible", "T": "stopped"}.get(row[3][:1], "unknown")})
        return members, len(live) > MAX_PROCESSES
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Runner member probe unavailable: " + type(error).__name__, file=sys.stderr, flush=True)
        return None, False

def run_runner(command, repo_root, log_path, *, timeout_seconds, truncation_seen=None, environment=None):
    with log_path.open("a+") as log:
        offset = log.tell()
        process = subprocess.Popen(command, cwd=repo_root, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                                   **({"env": environment} if environment is not None else {}))
        code = None
        try:
            code = process.wait(timeout=timeout_seconds)
        finally:
            try:
                stop_group(process)
                deadline = time.monotonic() + GROUP_TERM_GRACE_SECONDS
                alive = group_has_live_members(process.pid)
                if alive:
                    # Cover survivors appearing after the shared helper's last group observation.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    except PermissionError:
                        if group_has_live_members(process.pid):
                            raise
                    alive = group_has_live_members(process.pid)
                while alive:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Runner process group still has live members")
                    time.sleep(0.05)
                    alive = group_has_live_members(process.pid)
            except BaseException as error:
                reason = ("RuntimeError: Runner process group still has live members" if str(error) == "Runner process group still has live members"
                          else type(error).__name__)
                try:
                    members, truncated = runner_group_members(process.pid)
                    validate_runner_group_members(members)
                except BaseException:
                    # A second cancellation must never authorize deleting live build inputs.
                    members, truncated = None, False
                raise RunnerGroupCleanupError("Runner process group cleanup failed: " + reason,
                    members=members, truncated=truncated) from None
            log.seek(offset)
            lines = log.read().splitlines()
            for line in lines:
                if re.fullmatch(r"(?:keychain|privacy)_reset(?:_retry)?_exit=-?(?:0|[1-9][0-9]{0,2}); "
                                r"stderr_class=(?:empty|service-unavailable|device-unavailable|permission-denied|posix-error|simulator-error|unclassified)", line):
                    print(line, file=sys.stderr, flush=True)
            truncation = next((line for line in lines if line.startswith(TRUNCATION_PREFIX)
                               and line.removeprefix(TRUNCATION_PREFIX) in TRUNCATION_REASONS), None)
            if truncation is not None:
                if truncation_seen is not None:
                    truncation_seen.set()
                report_truncation(truncation.removeprefix(TRUNCATION_PREFIX))
            errors = [line for line in lines if line.startswith(("CommandError: ", "OfflineCommandError: ", "InfrastructureTimeout: "))]
            if errors:
                print(errors[-1], file=sys.stderr, flush=True)
    return code
