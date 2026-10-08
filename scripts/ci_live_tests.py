#!/usr/bin/env python3
"""Main-only live admission, private execution and allowlisted public results."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote, quote_plus, urlsplit

import ci_build_archive as archive
import ci_unit_tests as units
from ci_summary import ContractError, decode, duration, require, test_identity
from ci_verdict import function_identity, tokens
from run_host_checks import git, toolchain
from run_offline_unit_tests import _stop_process_group

WORKFLOW = ".github/workflows/ci-nightly.yml"
REPOSITORY = "sudoHG/immichSlides"
SUITES = ("PlaybackPoolResolverLiveIntegrationTests", "SlideShowViewModelLiveIntegrationTests", "FaceBoxLiveProbeTests")
ROOT = Path(__file__).resolve().parent.parent


def live_declarations(declared):
    live_suites = {item["key"].split("/")[0] for item in declared if "Live" in item["key"].split("/")[0]}
    require(live_suites == set(SUITES) | {"PerformanceLiveIntegrationTests"}, "live suite ownership changed")
    return [item for item in declared if item["key"].split("/")[0] in SUITES]


def admission(env, event, head, ancestor):
    require(env.get("GITHUB_REPOSITORY") == REPOSITORY, "live repository refused")
    if env.get("GITHUB_EVENT_NAME") == "pull_request":
        repo = event["pull_request"]["head"]["repo"]
        return "fork-skipped" if repo is None or repo.get("full_name") != REPOSITORY else "pr-skipped"
    require(env.get("GITHUB_EVENT_NAME") in {"schedule", "workflow_dispatch"}, "live event refused")
    require(env.get("GITHUB_ACTOR") == "sudoHG" and env.get("GITHUB_TRIGGERING_ACTOR") == "sudoHG", "live actor refused")
    require(env.get("GITHUB_REF") == "refs/heads/main", "live ref refused")
    require(env.get("GITHUB_WORKFLOW_REF") == REPOSITORY + "/" + WORKFLOW + "@refs/heads/main", "live workflow refused")
    require(head == env.get("GITHUB_SHA") and ancestor, "live checkout or main ancestry refused")
    return "admitted"


def admit():
    event = decode(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    head = git("rev-parse", "HEAD")
    ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", head, "origin/main"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30).returncode == 0
    result = admission(os.environ, event, head, ancestor)
    archive.output("admitted", "true" if result == "admitted" else "false")
    print("Live admission: " + result + "; pull requests have no live secret access." if result != "admitted"
          else "Live admission: admitted; checkout verified on main before secret injection.")
    return 0


def secret_forms(url, key):
    require(bool(url) and len(key) >= 8, "live credentials missing or invalid")
    host = urlsplit(url).hostname
    require(bool(host), "live URL missing host")
    forms = {host, key[:8], key[:12]}
    for value in (url, key):
        forms.update((value, quote(value, safe=""), quote(value), quote_plus(value),
                      json.dumps(value, ensure_ascii=True)[1:-1], value.replace("/", "\\/"),
                      base64.b64encode(value.encode()).decode()))
    return {value.encode(encoding) for value in forms for encoding in ("utf-8", "utf-16-le", "utf-16-be") if value}


def scan_file(path, needles):
    overlap = max(map(len, needles)) - 1
    tail = b""
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            data = tail + block
            require(not any(needle in data for needle in needles), "live sensitive scan refused publication or archive use")
            tail = data[-overlap:] if overlap else b""


def scan_tree(path, needles):
    for item in path.rglob("*"):
        require(not any(needle in str(item.relative_to(path)).encode() for needle in needles), "live sensitive path refused")
        if item.is_file() and not item.is_symlink():
            scan_file(item, needles)


def public_outcomes(declared, compiled, rows, counts, code):
    tokens([row["identity"] for row in rows])
    expected = tokens(declared, functions=True)
    compiled_ids = [test_identity("swift", units.UNIT_TARGET + "/" + key,
                                  platform=declared[0]["dimensions"]["platform"]) for key in compiled]
    require(set(tokens(compiled_ids, functions=True)) == set(expected), "live declared/compiled mismatch")
    functions = [row for row in rows if "parameter" not in row["identity"]["dimensions"]]
    require(set(tokens([row["identity"] for row in functions], functions=True)) == set(expected)
            and len(functions) == len(expected), "live compiled/executed mismatch")
    require(code == 0 and counts.result.casefold() == "passed" and counts.total_test_count == len(functions)
            and counts.passed_tests == len(functions) and counts.failed_tests == 0 and counts.skipped_tests == 0,
            "live process or official counts failed")
    require(all(row["outcome"] == "passed" for row in rows), "live function or parameter did not pass")
    return sanitized_outcomes(declared, rows)


def sanitized_outcomes(declared, rows):
    # Official arguments, failure messages, skip reasons and URLs never cross this seam.
    expected = tokens(declared, functions=True)
    for row in rows:
        duration(row["duration_seconds"])
    result = []
    for identity in sorted(expected.values(), key=lambda item: item["key"]):
        functions = [row for row in rows if "parameter" not in row["identity"]["dimensions"]
                     and function_identity(row["identity"]) == identity]
        parameters = [row for row in rows if "parameter" in row["identity"]["dimensions"]
                      and function_identity(row["identity"]) == identity]
        outcome = functions[0]["outcome"] if len(functions) == 1 else "not-run"
        require(outcome in {"passed", "failed", "skipped", "not-run"}, "unknown live outcome")
        result.append({"identity": identity, "outcome": outcome,
                       "duration_seconds": functions[0]["duration_seconds"] if len(functions) == 1 else 0,
                       "parameters": [{"index": index, "outcome": row["outcome"], "duration_seconds": row["duration_seconds"]}
                                      for index, row in enumerate(parameters)]})
    return result


def capture(command, path, *, env, timeout):
    with path.open("wb") as output:
        process = subprocess.Popen(command, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _stop_process_group(process, 120)
            return 124
        except BaseException:
            _stop_process_group(process, 120)
            raise


def run_live(args):
    # The workflow repeats admission in a credential-free step before invoking this entry point.
    require(os.environ.get("GITHUB_ACTIONS") == "true", "real live execution is GitHub-only")
    selection = decode(args.selection_path.read_text())
    identity = selection["identity"]
    admission(os.environ, {}, identity["commit_sha"], True)
    url = os.environ.pop("CI_LIVE_URL", "")
    key = os.environ.pop("CI_LIVE_KEY", "")
    needles = secret_forms(url, key)
    clean = {name: value for name, value in os.environ.items()
             if not name.startswith(("IMMICH", "TEST_RUNNER_IMMICH", "SIMCTL_CHILD_IMMICH", "CI_LIVE_", "ENABLE_DEBUG_"))}
    args.output_dir.mkdir(parents=True, exist_ok=False)
    private = args.private_dir
    private.mkdir(mode=0o700, parents=True, exist_ok=False)
    platform = selection["platform"]
    record = {"schema_version": 1, "tier": "live-unit", "status": "failed", "identity": identity,
              "source": selection["source"],
              "run_id": selection["run_id"], "attempt": selection["attempt"], "platform": platform,
              "artifact_id": selection["artifact_id"], "producer_attempt": selection["producer_attempt"],
              "declared": [], "compiled": [], "observed": [], "exit_code": 1,
              "hashes": {"manifests": {}, "policies": {"live-runner": archive.file_hash(Path(__file__)),
                         "test-policy": archive.file_hash(Path(__file__).with_name("ci-test-policy.json"))}},
              "toolchain": {"versions": {}, "signing_mode": "not-applicable"},
              "diagnostic": "live-infrastructure-failed", "release_eligible": False}
    simulator = None
    phase = "archive"
    try:
        archive.workspace_preflight(ROOT)
        require(not (ROOT / "immichSlides.xcodeproj").exists(), "live source checkout must be absent")
        declared = live_declarations(units.read_declarations(ROOT, selection))
        require(bool(declared) and all(any(item["key"].startswith(suite + "/") for item in declared) for suite in SUITES),
                "live suite declarations missing")
        record["declared"] = declared
        record["observed"] = sanitized_outcomes(declared, [])
        manifest = decode((args.archive_dir / "manifest.json").read_text())
        pins_path = Path(__file__).with_name("ci-pins.json")
        pins = decode(pins_path.read_text())
        developer = Path(clean["DEVELOPER_DIR"])
        xcode_build = plistlib.loads((developer.parent / "version.plist").read_bytes())["ProductBuildVersion"]
        archive.validate_manifest(manifest, identity, selection["run_id"], selection["producer_attempt"], platform,
                                  xcode_build, archive.file_hash(pins_path))
        require(selection["pins_sha256"] == archive.file_hash(pins_path), "live selection pins mismatch")
        require(not os.path.lexists(manifest["source_path"]) and not os.path.lexists(manifest["products_path"]),
                "producer source or Products still present")
        scan_tree(args.archive_dir, needles)
        archive.disk_check(args.min_free_gib)
        archive.extract_products(args.archive_dir / "build.tar.gz", args.relocated_path, manifest)
        scan_tree(args.relocated_path, needles)
        products = args.relocated_path / "Products"
        require(archive.measure_signing(next(products.glob("Debug-*simulator/immichSlides.app"))) == "adhoc", "live signing failed")
        record["archive_sha256"] = manifest["archive_sha256"]
        record["manifest_sha256"] = archive.file_hash(args.archive_dir / "manifest.json")
        record["declarations_sha256"] = archive.file_hash(ROOT / "unit-declarations.json")
        record["hashes"]["manifests"] = {"build": record["manifest_sha256"],
            "unit-declarations": record["declarations_sha256"], "ci-pins": archive.file_hash(pins_path)}
        record["toolchain"] = toolchain()
        archive.record_signing(record, "adhoc")
        record["toolchain"]["versions"]["simulator_runtime"] = pins["simulators"][platform]["runtime"]
        record["signing_mode"] = "sign-to-run-locally"
        runtime = pins["simulators"][platform]["runtime"]
        device = pins["device_types"]["iphone" if platform == "ios" else "appletv"]
        simulator = subprocess.check_output(["xcrun", "simctl", "create", "immichSlides-live-unit", device, runtime],
                                            env=clean, stderr=subprocess.DEVNULL, timeout=60, text=True).strip()
        budget = units.enumeration_budget("ci", platform)
        phase = "boot"
        require(capture(["xcrun", "simctl", "bootstatus", simulator, "-b"], private / "boot.log", env=clean,
                        timeout=budget["simulator_boot_timeout_seconds"]) == 0, "live boot failed")
        base = ["xcodebuild", "test-without-building", "-xctestrun", str(next(products.glob("*.xctestrun"))),
                "-destination", f"platform={archive.DESTINATIONS[platform]},id={simulator}",
                "-derivedDataPath", str(private / "derived"), "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never", *["-only-testing:immichSlidesTests/" + suite for suite in SUITES]]
        phase = "enumeration"
        archive.disk_check(args.min_free_gib)
        enum_path = private / "enumeration.json"
        require(capture([*base, "-enumerate-tests", "-test-enumeration-format", "json", "-test-enumeration-output-path", str(enum_path)],
                        private / "enumeration.log", env=clean, timeout=budget["timeout_seconds"]) == 0, "live enumeration failed")
        compiled = units.enumeration_keys(decode(enum_path.read_text()))
        compiled_ids = [test_identity("swift", "immichSlidesTests/" + name, platform=platform) for name in compiled]
        require(set(tokens(compiled_ids, functions=True)) == set(tokens(declared, functions=True)), "live selection mismatch")
        record["compiled"] = sorted(tokens(compiled_ids, functions=True).values(), key=lambda item: item["key"])
        phase = "execution"
        live_env = dict(clean, TEST_RUNNER_IMMICH_TEST_SERVER_URL=url, TEST_RUNNER_IMMICH_TEST_API_KEY=key,
                        TEST_RUNNER_IMMICHSLIDES_EVIDENCE="1")
        bundle = private / "live.xcresult"
        archive.disk_check(args.min_free_gib)
        code = capture([*base, "-resultBundlePath", str(bundle)], private / "execution.log", env=live_env, timeout=900)
        record["exit_code"] = code
        phase = "official-results"
        for kind in ("tests", "summary"):
            # stderr is private too; malformed or failed exports cannot be used as evidence.
            require(capture(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", str(bundle), "--compact"],
                            private / ("official-" + kind + ".json"), env=clean, timeout=60) == 0, "live export failed")
        rows, counts = units.read_results(private, platform)
        record["observed"] = sanitized_outcomes(declared, rows)
        record["official_counts"] = {"total": counts.total_test_count, "passed": counts.passed_tests,
                                     "failed": counts.failed_tests, "skipped": counts.skipped_tests}
        record["observed"] = public_outcomes(declared, compiled, rows, counts, code)
        record.update(status="passed", diagnostic=None)
    except Exception:
        # Never serialize exception text, subprocess output or runtime test arguments.
        record["diagnostic"] = "live-" + phase + "-failed"
    finally:
        if simulator:
            for action, timeout in (("shutdown", 15), ("delete", 60)):
                try:
                    if capture(["xcrun", "simctl", action, simulator], private / (action + ".log"), env=clean, timeout=timeout):
                        record.update(status="failed", diagnostic="live-cleanup-failed")
                except Exception:
                    record.update(status="failed", diagnostic="live-cleanup-failed")
        # This runner owns every private input; no raw live material is publishable, even after failure.
        shutil.rmtree(private)
        shutil.rmtree(args.relocated_path, ignore_errors=True)
        archive.write_json(args.output_dir / "live-summary.json", record)
        (args.output_dir / "live-summary.md").write_text(
            f"Live unit {platform}: {record['status']}; {sum(row['outcome'] == 'passed' for row in record['observed'])}/{len(record['declared'])} functions passed. "
            f"Process exit: {record['exit_code']}; diagnostic: {record['diagnostic'] or 'none'}.\n"
            "Real live coverage requires this main-only run; release eligibility remains disabled.\n")
        scan_tree(args.output_dir, needles)
        archive.output("records_safe", "true")
    return 0 if record["status"] == "passed" else 1


def canary(args):
    url, key = canary_values(os.environ.get("GITHUB_RUN_ID", "local"))
    for value in (url, key):
        print("::add-mask::" + value, flush=True)
    needles = secret_forms(url, key)
    args.output_dir.mkdir(parents=True, exist_ok=False)
    private = args.output_dir.parent / (args.output_dir.name + "-private")
    private.mkdir(mode=0o700)
    try:
        # Exercise a failing subprocess through the same private capture used by live Xcode.
        child = "import os,sys; sys.stdout.buffer.write(bytes.fromhex(os.environ['CANARY_BYTES'])); sys.exit(65)"
        code = capture([sys.executable, "-c", child], private / "failure.log",
                       env=dict(os.environ, CANARY_BYTES=b"\n".join(needles).hex()), timeout=30)
        require(code == 65, "canary failure was not exercised")
        blocked = False
        try:
            scan_file(private / "failure.log", needles)
        except ContractError:
            blocked = True
        require(blocked, "canary scanner missed private failure")
        archive.write_json(args.output_dir / "canary.json", {"schema_version": 1, "status": "passed",
                           "captured_failure_exit": code, "raw_and_transformed_capture_refused": True})
        scan_tree(args.output_dir, needles)
        print("Live canary: captured failure 65; raw and transformed publication scan PASS.")
    finally:
        shutil.rmtree(private)
    return 0


def canary_values(run_id):
    seed = hashlib.sha256(("immichslides-live-canary:" + run_id).encode()).hexdigest()
    return "https://" + seed[:24] + ".invalid/a path?quoted=\"x\"", seed[16:]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("admit")
    probe = sub.add_parser("canary")
    probe.add_argument("--output-dir", type=Path, required=True)
    audit = sub.add_parser("audit-canary")
    audit.add_argument("--run-id", required=True)
    audit.add_argument("--path", type=Path, required=True)
    run = sub.add_parser("run")
    for name in ("selection-path", "archive-dir", "relocated-path", "output-dir", "private-dir"):
        run.add_argument("--" + name, type=Path, required=True)
    run.add_argument("--min-free-gib", type=float, default=80)
    args = parser.parse_args(argv)
    try:
        if args.command == "audit-canary":
            scan_tree(args.path, secret_forms(*canary_values(args.run_id)))
            print("Downloaded canary logs, summaries and artifacts: raw and transformed scan PASS.")
            return 0
        return admit() if args.command == "admit" else canary(args) if args.command == "canary" else run_live(args)
    except Exception:
        print("Live boundary refused; no private diagnostics published.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
