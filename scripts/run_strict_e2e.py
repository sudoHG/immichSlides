#!/usr/bin/env python3
"""Run short public-fixture smoke flows with private official-result export and disposal."""

from __future__ import annotations

import argparse
import lzma
import zlib
from typing import Any, Iterator, Optional, Tuple
from contextlib import contextmanager
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, Mapping, TextIO

from ci_execution_diagnostics import active, diagnostic_session

from run_offline_unit_tests import TestResultsSummary, parse_non_negative_int, read_official_test_results_summary as read_unit_official_test_results_summary


from strict_e2e_runner_support import (CommandError, InfrastructureTimeout, MIN_DATA_GIB, XCODEBUILD_TIMEOUT_SECONDS, WRONG_PUBLIC_API_KEY, PRIVATE_RESULT_BUNDLE_ROOT, PLATFORM_SETTINGS, _is_forbidden_key, prepare_evidence_directory, read_source_sha, read_source_dirty_paths, write_case_manifest, write_fixture_artifacts, prepare_simulator, reset_simulator_app, destination_udid, wait_for_service, stop_exact_process)
from strict_e2e_server import fixture_manifest, write_member_manifest

REPO_ROOT = Path(__file__).resolve().parent.parent


# First-boot interaction can place even public fixture keys in XCTest's private activity archive.
# Read-only Apple-tool allowance; evidence and capacity limits are in docs/CI_STRICT_RUNNER.md.
OFFICIAL_EXPORT_TIMEOUT_SECONDS = 180


class OfficialExportBudget:
    def __init__(self):
        self.spent_seconds = 0.0

    def remaining(self, phase):
        remaining = OFFICIAL_EXPORT_TIMEOUT_SECONDS - self.spent_seconds
        if remaining <= 0:
            raise InfrastructureTimeout(phase, 0)
        return remaining


@contextmanager
def measured_official_export(budget=None):
    if budget is None:
        yield
        return
    recorder = active()
    sequence = recorder.next_sequence() if recorder is not None else None
    started = time.monotonic()
    state = "completed"
    try:
        yield
    except (subprocess.TimeoutExpired, InfrastructureTimeout):
        state = "timeout"
        raise
    except Exception:
        # The existing reader has no failed state; preserve the error without a success timing.
        state = None
        raise
    finally:
        elapsed = time.monotonic() - started
        if budget is not None:
            budget.spent_seconds += max(0, elapsed)
        if recorder is not None and state is not None:
            try:
                from ci_execution_diagnostics import finite
                from ci_bounded_diagnostics import MAX_DIAGNOSTIC_SECONDS
                measured = finite(elapsed, MAX_DIAGNOSTIC_SECONDS)
                if measured is not None:
                    # Clock-only bookkeeping survives exhausted process/ledger collection budgets.
                    recorder.retain({"scope": "xcode", "phase": "official-export", "state": state,
                        "sequence": sequence, "elapsed_seconds": measured, "cpu_seconds": None,
                        "sample": None, "input_sha256": None, "official_exports": None})
            except Exception:
                # Optional numeric diagnostics must not replace the original result or timeout.
                pass


def read_official_test_results_summary(bundle: Path, *, export_budget=None) -> TestResultsSummary:
    timeout = export_budget.remaining("official-summary-export") if export_budget is not None else 60
    try:
        with measured_official_export(export_budget):
            return read_unit_official_test_results_summary(bundle, timeout_seconds=timeout)
    except subprocess.TimeoutExpired as error:
        raise InfrastructureTimeout("official-summary-export", timeout) from error


def write_sensitive_scan(evidence_dir: Path, sensitive_values: list[str], *, output_path: Path | None = None) -> None:
    from ci_failure_diagnostics import scan_diagnostic_json
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
        if path.suffix == ".json":
            try:
                scan_diagnostic_json(data)
            except ValueError:
                matched_files.append(str(path.relative_to(evidence_dir)))
    payload = {
        "checked_key_names": ["STRICT_E2E_INPUT_PUBLIC_KEY"],
        "matched_files": matched_files,
        "result": "PASS" if not matched_files else "FAIL",
    }
    try:
        (output_path or evidence_dir / "sensitive-scan.json").write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except OSError as error:
        raise CommandError(f"Could not write the redaction scan results: {error}") from error
    if matched_files:
        raise CommandError("The evidence redaction scan found API Key values or invalid public failure diagnostics: " + ", ".join(matched_files))


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
    export_timeout_seconds: float | None = None,
    export_budget=None,
    enrich_failure_diagnostics: bool = False,
    first_failure_spool=None,
    first_failure_images=None,
) -> str:
    from run_offline_unit_tests import official_result_step
    timeout = (export_budget.remaining("official-tests-export") if export_budget is not None else 60)
    if export_timeout_seconds is not None:
        timeout = min(timeout, export_timeout_seconds) if export_budget is not None else export_timeout_seconds
    try:
        with measured_official_export(export_budget), official_result_step("export"):
            completed = subprocess.run(
                ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle), "--compact"],
                capture_output=True, check=False, timeout=timeout,
            )
            if completed.returncode != 0:
                raise CommandError(f"Official test export failed with exit {completed.returncode}.")
    except subprocess.TimeoutExpired as error:
        if summary_timeout_seconds is not None:
            raise
        raise InfrastructureTimeout("official-tests-export", timeout) from error
    payload = json.loads(completed.stdout)
    if not isinstance(payload, dict):
        raise CommandError("Official test export is not a JSON object.")
    if logical_bytes_contain(completed.stdout, sensitive_values):
        raise CommandError("Official test export contains test credentials; refusing to retain it.")
    exported = completed.stdout
    (evidence_dir / f"official-tests{suffix}.json").write_bytes(exported)
    summary_path = evidence_dir / f"official-summary{suffix}.json"
    if not summary_path.exists():
        # Required official outcomes must be available before optional legacy diagnostics run.
        summary = (read_unit_official_test_results_summary(bundle, timeout_seconds=summary_timeout_seconds)
                   if summary_timeout_seconds is not None else read_official_test_results_summary(bundle, export_budget=export_budget))
        summary_path.write_text(json.dumps({
            "totalTestCount": summary.total_test_count, "passedTests": summary.passed_tests,
            "failedTests": summary.failed_tests, "skippedTests": summary.skipped_tests,
            "result": summary.result,
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if enrich_failure_diagnostics:
        from ci_failure_diagnostics import (legacy_diagnostics,
                                            legacy_failure_messages, unknown_diagnostics,
                                            public_failure_messages, failure_messages_diagnostics, first_failure_test_key,
                                            official_failure_count)
        failed = []
        def visit(node):
            if isinstance(node, dict):
                if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
                    failed.append(node)
                children = node.get("children", [])
                for child in children if isinstance(children, list) else []:
                    visit(child)
        nodes = payload.get("testNodes", [])
        for node in nodes if isinstance(nodes, list) else []:
            visit(node)
        if failed:
            diagnostics = {}
            raw_messages = {}
            legacy_root = {}
            try:
                timeout = export_timeout_seconds if export_timeout_seconds is not None else 60
                if export_budget is not None:
                    timeout = min(60, timeout, export_budget.remaining("official-tests-export"))
                with measured_official_export(export_budget):
                    details = subprocess.run(["xcrun", "xcresulttool", "get", "object", "--legacy", "--path", str(bundle), "--format", "json"],
                                             capture_output=True, check=True, timeout=timeout)
                legacy_root = json.loads(details.stdout)
                raw_messages = legacy_failure_messages(legacy_root)
                diagnostics = legacy_diagnostics(legacy_root)
            except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError, InfrastructureTimeout):
                # Diagnostic availability must not change the official result or runner exit.
                pass
            for node in failed:
                key = first_failure_test_key(node.get("nodeIdentifier", ""))
                node.update(diagnostics.get(key, unknown_diagnostics()))
                messages = public_failure_messages(raw_messages.get(key))
                if messages is not None and official_failure_count(node) == len(messages):
                    node["failure_messages"] = messages
                    node.update(failure_messages_diagnostics(messages))
            if first_failure_spool is not None:
                from ci_failure_diagnostics import collect_first_failure_spool
                directory, selectors = first_failure_spool
                collect_first_failure_spool(directory, selectors, failed,
                    first_failure_images or evidence_dir / ("first-failure" + suffix))
            exported = (json.dumps(payload, sort_keys=True) + "\n").encode()
    (evidence_dir / f"official-tests{suffix}.json").write_bytes(exported)
    if enrich_failure_diagnostics:
        summary_payload = json.loads(summary_path.read_text())
        summary_payload.pop("message", None)
        summary_path.write_text(json.dumps(summary_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return hashlib.sha256(exported).hexdigest()


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


def run_command(command: list[str], *, cwd: Path, environment: Mapping[str, str], log_path: Path,
                timeout_seconds: int = XCODEBUILD_TIMEOUT_SECONDS) -> int:
    with log_path.open("w", encoding="utf-8") as log_file:
        recorder = active()
        started = time.monotonic()
        sequence = recorder.next_sequence() if recorder else 0
        if recorder:
            recorder.event("xcode", "xcodebuild", "started", sequence)
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
            if recorder:
                recorder.event("xcode", "xcodebuild", "timeout", sequence, elapsed=time.monotonic() - started)
                bundles = [Path(command[command.index("-resultBundlePath") + 1])] if "-resultBundlePath" in command else []
                recorder.xcode_snapshot("after-reap", started, sequence, log_path, bundles)
            raise CommandError(f"xcodebuild timed out after {timeout_seconds:.1f}s.") from error
        if recorder and completed.returncode == 0:
            recorder.event("xcode", "xcodebuild", "completed", sequence, elapsed=time.monotonic() - started)
    return completed.returncode


@diagnostic_session
def main(argv: list[str] | None = None, stdout: TextIO | None = None, stderr: TextIO | None = None) -> int:
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("ios", "tvos"))
    parser.add_argument("--destination", required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--diagnostics-receipt", type=Path, help="shared job measurement ledger")
    parser.add_argument("--simulator-boot-submitted", action="store_true",
                        help="Reuse a dedicated device's submitted boot; still require bootstatus, readiness and resets")
    parser.add_argument("--suite", choices=("smoke-flow",), default="smoke-flow")
    parser.add_argument("--smoke-device", choices=("iphone", "ipad", "tv"))
    parser.add_argument("--smoke-scope", choices=("core", "full"), default="full")
    parser.add_argument("--smoke-flow", help="Debug one manifest flow; never a complete smoke group")
    parser.add_argument("--smoke-archive", action="store_true", help="Explicitly admit relocated smoke archive v2 products")
    parser.add_argument("--smoke-control-path", type=Path, help="Independent expected smoke archive control JSON")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--warm-up-only", action="store_true", help="build this shard once without starting a test or recording")
    mode.add_argument("--test-without-building", action="store_true", help="require and reuse an explicit shard warm-up")
    parser.add_argument("--derived-data-path", type=Path, help="shard-scoped DerivedData outside evidence; retained for reuse")
    parser.add_argument("--cloned-source-packages-path", type=Path, help="shared package downloads outside DerivedData and evidence")
    parser.add_argument("--configuration", choices=("Debug", "Release"), help="explicit shard configuration; defaults to the existing suite setting")
    parser.add_argument("--cold-timeout-seconds", type=parse_non_negative_int, help="explicit warm-up budget (default: 300 seconds)")
    parser.add_argument("--warm-timeout-seconds", type=parse_non_negative_int,
                        help="warm reuse budget (default: 300 seconds)")
    parser.add_argument(
        "--min-free-gib",
        type=parse_non_negative_int,
        default=MIN_DATA_GIB,
        metavar="N",
        help=f"minimum free GiB required before xcodebuild (default: {MIN_DATA_GIB})",
    )
    arguments = parser.parse_args(argv)
    if arguments.suite == "smoke-flow":
        from strict_e2e_smoke import run
        arguments.cold_timeout_seconds = arguments.cold_timeout_seconds or XCODEBUILD_TIMEOUT_SECONDS
        try:
            return run(arguments, REPO_ROOT, sys.modules[__name__], stdout, stderr)
        except (CommandError, ValueError, OSError, subprocess.SubprocessError) as error:
            print(f"CommandError: {error}", file=stderr)
            return getattr(error, "code", 2)


ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
GZIP_MAGIC = b"\x1f\x8b"
GZIP_DEFLATE_CM = 8
XZ_MAGIC = b"\xfd7zXZ\x00"
ZSTD_SKIPPABLE_MAGIC_LO = 0x184D2A50
ZSTD_SKIPPABLE_MAGIC_HI = 0x184D2A5F
ZSTD_SKIPPABLE_MAGIC_TAIL = b"\x2a\x4d\x18"
DECOMPRESS_PROBE_BYTES = 512
DECOMPRESS_CHUNK_BYTES = 64 * 1024
_LIBZSTD: Any = "unset"

def logical_bytes_contain(data: bytes, values: Sequence[str]) -> bool:
    # Decode valid frames; scan cleartext metadata and any bytes that cannot be decoded.
    # Scan chunk by chunk without joining the whole blob.
    needles = [value.encode("utf-8") for value in values if value]
    if not needles:
        return False
    overlap = max(len(needle) for needle in needles) - 1
    tail = b""
    for part in _iter_logical_parts(data):
        window = tail + part if tail else part
        if any(needle in window for needle in needles):
            return True
        tail = window[-overlap:] if overlap > 0 else b""
    return False

def logical_content_bytes(data: bytes) -> bytes:
    """Decode valid frames while retaining skippable metadata and undecodable raw bytes."""
    return b"".join(_iter_logical_parts(data))

def _iter_logical_parts(data: bytes) -> Iterator[bytes]:
    if not data:
        return
    starts = _compression_magic_offsets(data)
    index = 0
    cursor = 0
    length = len(data)
    while index < length:
        while cursor < len(starts) and starts[cursor] < index:
            cursor += 1
        at_magic = cursor < len(starts) and starts[cursor] == index
        if at_magic:
            frame = _decompress_frame_at(data, index)
            if frame is not None:
                payload, consumed = frame
                if consumed <= 0:
                    yield data[index : index + 1]
                    index += 1
                    continue
                if payload:
                    yield payload
                index += consumed
                continue
            # Failed decoding cannot prove these bytes are safe to discard.
            cursor += 1
        nxt = starts[cursor] if cursor < len(starts) else length
        if nxt <= index:
            yield data[index : index + 1]
            index += 1
            continue
        yield data[index:nxt]
        index = nxt

def _compression_magic_offsets(data: bytes) -> list[int]:
    # One forward find pass per magic; never rerun several finds over the remaining bytes for each offset.
    found: set[int] = set()
    for magic in (ZSTD_MAGIC, GZIP_MAGIC, XZ_MAGIC):
        start = 0
        while True:
            at = data.find(magic, start)
            if at < 0:
                break
            found.add(at)
            start = at + 1
    for prefix in range(0x50, 0x60):
        magic = bytes((prefix,)) + ZSTD_SKIPPABLE_MAGIC_TAIL
        start = 0
        while True:
            at = data.find(magic, start)
            if at < 0:
                break
            found.add(at)
            start = at + 1
    return sorted(found)

def _decompress_frame_at(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    skippable = _zstd_skippable_size(data, offset)
    if skippable is not None:
        # Zstd skips this metadata, but it is stored as cleartext in the evidence.
        return data[offset + 8 : offset + skippable], skippable
    if data.startswith(ZSTD_MAGIC, offset):
        return _decompress_zstd_frame(data, offset)
    if data.startswith(GZIP_MAGIC, offset):
        return _decompress_gzip_frame(data, offset)
    if data.startswith(XZ_MAGIC, offset):
        return _decompress_xz_frame(data, offset)
    return None

def _zstd_skippable_size(data: bytes, offset: int) -> Optional[int]:
    if offset + 8 > len(data):
        return None
    magic = int.from_bytes(data[offset : offset + 4], "little")
    if magic < ZSTD_SKIPPABLE_MAGIC_LO or magic > ZSTD_SKIPPABLE_MAGIC_HI:
        return None
    size = int.from_bytes(data[offset + 4 : offset + 8], "little")
    consumed = 8 + size
    if offset + consumed > len(data):
        return None
    return consumed

def _decompress_zstd_frame(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    remaining = len(data) - offset
    if remaining <= 0:
        return None
    py314 = _zstd_py314()
    if py314 is not None:
        errors: tuple[type[BaseException], ...] = (ValueError, OSError, AttributeError, TypeError)
        zstd_error = getattr(py314, "ZstdError", None)
        if isinstance(zstd_error, type):
            errors = errors + (zstd_error,)
        try:
            view = memoryview(data)[offset:]
            consumed = int(py314.get_frame_size(view))
            if 0 < consumed <= remaining:
                payload = py314.decompress(data[offset : offset + consumed])
                return payload, consumed
        except errors:
            pass
    ctypes_frame = _zstd_ctypes_frame(data, offset)
    if ctypes_frame is not None:
        return ctypes_frame
    # Once ctypes/py314 has ruled out a valid frame, do not hand the whole remaining blob to the CLI.
    if py314 is None and _load_libzstd() is None:
        return _zstd_cli_frame(data, offset)
    return None

def _zstd_py314() -> Any:
    try:
        from compression import zstd as module
    except ImportError:
        return None
    return module

def _zstd_source_pointer(data: bytes, offset: int) -> Optional[int]:
    import ctypes

    pythonapi = ctypes.pythonapi
    pythonapi.PyBytes_AsString.restype = ctypes.c_void_p
    pythonapi.PyBytes_AsString.argtypes = [ctypes.py_object]
    base = pythonapi.PyBytes_AsString(data)
    if not base:
        return None
    return int(base) + offset

def _zstd_ctypes_frame(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    lib = _load_libzstd()
    if lib is None:
        return None
    import ctypes

    remaining = len(data) - offset
    if remaining <= 0:
        return None
    src = _zstd_source_pointer(data, offset)
    if src is None:
        return None
    consumed = lib.ZSTD_findFrameCompressedSize(src, remaining)
    if lib.ZSTD_isError(consumed):
        return None
    consumed_i = int(consumed)
    if consumed_i <= 0 or consumed_i > remaining:
        return None
    content_size = lib.ZSTD_getFrameContentSize(src, consumed_i)
    if content_size in (2**64 - 1, 2**64 - 2):
        dst_capacity = max(consumed_i * 8, 64)
    else:
        dst_capacity = max(int(content_size), 1)
    dst = ctypes.create_string_buffer(dst_capacity)
    written = lib.ZSTD_decompress(dst, dst_capacity, src, consumed_i)
    if lib.ZSTD_isError(written):
        return None
    return dst.raw[: int(written)], consumed_i

def _load_libzstd() -> Any:
    global _LIBZSTD
    if _LIBZSTD != "unset":
        return _LIBZSTD
    import ctypes

    for path in (
        "/opt/homebrew/lib/libzstd.dylib",
        "/usr/local/lib/libzstd.dylib",
        "libzstd.dylib",
        "libzstd.so.1",
        "libzstd.so",
    ):
        try:
            lib = ctypes.CDLL(path)
        except OSError:
            continue
        lib.ZSTD_findFrameCompressedSize.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        lib.ZSTD_findFrameCompressedSize.restype = ctypes.c_size_t
        lib.ZSTD_getFrameContentSize.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        lib.ZSTD_getFrameContentSize.restype = ctypes.c_ulonglong
        lib.ZSTD_decompress.argtypes = [
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_void_p,
            ctypes.c_size_t,
        ]
        lib.ZSTD_decompress.restype = ctypes.c_size_t
        lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
        lib.ZSTD_isError.restype = ctypes.c_uint
        _LIBZSTD = lib
        return lib
    _LIBZSTD = None
    return None

def _zstd_cli_frame(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    import shutil
    import subprocess

    consumed = _zstd_frame_size(data, offset)
    if consumed is None:
        return None
    binary = shutil.which("zstd")
    if binary is None:
        return None
    blob = data[offset : offset + consumed]
    completed = subprocess.run(
        [binary, "-d", "-c", "-q"],
        input=blob,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout, consumed

def _zstd_frame_size(data: bytes, offset: int) -> Optional[int]:
    # Walk framing only; the CLI still validates and decompresses the exact frame.
    # Format: https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md
    if not data.startswith(ZSTD_MAGIC, offset) or offset + 5 > len(data):
        return None
    descriptor = data[offset + 4]
    if descriptor & 0x08:  # Reserved bit must be zero.
        return None
    single_segment = bool(descriptor & 0x20)
    content_size_flag = descriptor >> 6
    content_size_bytes = (int(single_segment), 2, 4, 8)[content_size_flag]
    dictionary_id_bytes = (0, 1, 2, 4)[descriptor & 3]
    cursor = offset + 5 + int(not single_segment) + dictionary_id_bytes + content_size_bytes
    if cursor > len(data):
        return None
    while cursor + 3 <= len(data):
        header = int.from_bytes(data[cursor : cursor + 3], "little")
        cursor += 3
        block_type = (header >> 1) & 3
        if block_type == 3:
            return None
        block_size = header >> 3
        cursor += 1 if block_type == 1 else block_size
        if cursor > len(data):
            return None
        if header & 1:
            cursor += 4 if descriptor & 4 else 0
            return cursor - offset if cursor <= len(data) else None
    return None

def _decompress_gzip_frame(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    remaining = len(data) - offset
    if remaining < 3 or data[offset + 2] != GZIP_DEFLATE_CM:
        return None
    return _decompress_chunked(
        data,
        offset,
        zlib.decompressobj(16 + zlib.MAX_WBITS),
        zlib.error,
    )

def _decompress_xz_frame(data: bytes, offset: int) -> Optional[Tuple[bytes, int]]:
    return _decompress_chunked(data, offset, lzma.LZMADecompressor(), lzma.LZMAError)

def _decompress_chunked(
    data: bytes,
    offset: int,
    decoder: Any,
    error_type: type[BaseException],
) -> Optional[Tuple[bytes, int]]:
    remaining = len(data) - offset
    if remaining <= 0:
        return None
    parts: list[bytes] = []
    consumed = 0
    try:
        first = min(DECOMPRESS_PROBE_BYTES, remaining)
        parts.append(decoder.decompress(data[offset : offset + first]))
        consumed = first
        unused = decoder.unused_data
        if unused:
            consumed -= len(unused)
        else:
            while consumed < remaining:
                if getattr(decoder, "eof", False):
                    break
                take = min(DECOMPRESS_CHUNK_BYTES, remaining - consumed)
                parts.append(
                    decoder.decompress(data[offset + consumed : offset + consumed + take])
                )
                consumed += take
                unused = decoder.unused_data
                if unused:
                    consumed -= len(unused)
                    break
        flush = getattr(decoder, "flush", None)
        if callable(flush):
            parts.append(flush())
    except error_type:
        return None
    if consumed <= 0:
        return None
    return b"".join(parts), consumed

if __name__ == "__main__":
    from ci_local import local_main
    raise SystemExit(local_main(main, __file__))
