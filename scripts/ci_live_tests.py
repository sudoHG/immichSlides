#!/usr/bin/env python3
"""Main-only live admission, private execution and allowlisted public results."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote, quote_plus, urlsplit

import ci_build_archive as archive
import ci_unit_tests as units
from ci_summary import decode, duration, observation, parse_summary, render_markdown, require, test_identity
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


def latest_artifact(entries, platform, run_id, attempt):
    matches = []
    for entry in entries:
        match = re.fullmatch(rf'build-{platform}-{re.escape(run_id)}-([1-9][0-9]*)', entry.get('name', ''))
        if match and entry.get('expired') is False and int(match[1]) <= attempt:
            matches.append((int(match[1]), entry['id']))
    require(bool(matches), 'live archive unavailable; rerun all jobs')
    newest = max(number for number, _ in matches)
    chosen = [artifact_id for number, artifact_id in matches if number == newest]
    require(len(chosen) == 1 and type(chosen[0]) is int and chosen[0] > 0, 'live archive selection ambiguous')
    return chosen[0], newest


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
        # Ignore boundary quartets: surrounding bytes can change their bits and padding.
        for offset in range(3):
            for encode in (base64.b64encode, base64.urlsafe_b64encode):
                encoded = encode(b'\0' * offset + value.encode()).decode()
                forms.add(encoded[4 if offset else 0:len(encoded) - (4 if '=' in encoded else 0)])
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
    require(path.is_dir() and not path.is_symlink(), "live scan directory missing")
    for item in path.rglob("*"):
        require(not any(needle in str(item.relative_to(path)).encode() for needle in needles), "live sensitive path refused")
        require(not item.is_symlink() or item.resolve().is_relative_to(path.resolve()), "live scan refuses external links")
        require(item.is_file() or item.is_dir(), 'live scan refuses unscanned filesystem entries')
        if item.is_file() and not item.is_symlink():
            scan_file(item, needles)


def compiled_live_keys(payload, declared):
    catalog = units.enumeration_keys(payload)
    owners = {name.split('/')[0] for name in catalog if 'Live' in name.split('/')[0]}
    require(owners <= set(SUITES) | {'PerformanceLiveIntegrationTests'}, 'compiled live suite ownership changed')
    selected = {name for name in catalog if name.split('/')[0] in SUITES}
    identities = [test_identity('swift', units.UNIT_TARGET+'/'+name, platform=declared[0]['dimensions']['platform'])
                  for name in selected]
    require(set(tokens(identities, functions=True)) == set(tokens(declared, functions=True)), 'live selection mismatch')
    return selected


def validate_outcome_population(declared, compiled, rows, counts):
    tokens([row["identity"] for row in rows])
    expected = tokens(declared, functions=True)
    compiled_ids = [test_identity("swift", units.UNIT_TARGET + "/" + key,
                                  platform=declared[0]["dimensions"]["platform"]) for key in compiled]
    require(set(tokens(compiled_ids, functions=True)) == set(expected), "live declared/compiled mismatch")
    functions = [row for row in rows if "parameter" not in row["identity"]["dimensions"]]
    require(set(tokens([row["identity"] for row in functions], functions=True)) == set(expected)
            and len(functions) == len(expected), "live compiled/executed mismatch")
    require(counts.total_test_count == len(functions) and
            counts.passed_tests == sum(row['outcome'] == 'passed' for row in functions) and
            counts.failed_tests == sum(row['outcome'] == 'failed' for row in functions) and
            counts.skipped_tests == sum(row['outcome'] == 'skipped' for row in functions), 'live official counts mismatch')


def public_outcomes(declared, compiled, rows, counts, code):
    validate_outcome_population(declared, compiled, rows, counts)
    require(code == 0 and counts.result.casefold() == "passed"
            and counts.passed_tests == len(declared) and counts.failed_tests == 0 and counts.skipped_tests == 0,
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
        entries = [(identity, outcome, functions[0]["duration_seconds"] if len(functions) == 1 else 0)]
        entries.extend((dict(identity, dimensions=dict(identity["dimensions"], parameter=f"case-{index}")),
                        row["outcome"], row["duration_seconds"]) for index, row in enumerate(parameters))
        for test, outcome, seconds in entries:
            result.append(observation(test, outcome, seconds,
                          reason="Live test skipped; private reason withheld." if outcome == "skipped" else None,
                          message="Live test failed; private diagnostic withheld." if outcome == "failed" else None,
                          exit_code=0 if outcome == "passed" else None if outcome == "not-run" else 1))
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
    if args.canary:
        require(selection['source']['workflow_path'] == WORKFLOW, "canary workflow refused")
        require((os.environ.get('CI_LIVE_URL'), os.environ.get('CI_LIVE_KEY')) ==
                canary_values(selection['run_id'], selection['attempt']), "canary credentials refused")
    else:
        admission(os.environ, {}, identity["commit_sha"], True)
    return execute_live(args, selection)


def execute_live(args, selection):
    identity = selection['identity']
    url = os.environ.pop("CI_LIVE_URL", "")
    key = os.environ.pop("CI_LIVE_KEY", "")
    needles = secret_forms(url, key)
    clean = {name: value for name, value in os.environ.items()
             if not name.startswith(("IMMICH", "TEST_RUNNER_IMMICH", "SIMCTL_CHILD_IMMICH", "CI_LIVE_", "ENABLE_DEBUG_"))}
    args.output_dir.mkdir(parents=True, exist_ok=False)
    private = args.private_dir
    private.mkdir(mode=0o700, parents=True, exist_ok=False)
    platform = selection["platform"]
    record = archive.record(selection, platform, os.environ.get('GITHUB_JOB', 'live-unit'))
    record['run']['tier'] = 'live-unit'
    record['status'] = 'failed'
    record['hashes']['policies'].update({'live-runner': archive.file_hash(Path(__file__)),
                                       'test-policy': archive.file_hash(Path(__file__).with_name('ci-test-policy.json'))})
    population = record['population']
    provenance = {'schema_version': 1, 'run_id': selection['run_id'], 'attempt': selection['attempt'],
                  'platform': platform, 'artifact_id': selection['artifact_id'],
                  'producer_attempt': selection['producer_attempt'], 'exit_code': 1, 'release_eligible': False}
    simulator = None
    coverage_verified = False
    phase = "archive"
    try:
        archive.workspace_preflight(ROOT)
        require(not (ROOT / "immichSlides.xcodeproj").exists(), "live source checkout must be absent")
        declared = live_declarations(units.read_declarations(ROOT, selection))
        require(bool(declared) and all(any(item["key"].startswith(suite + "/") for item in declared) for suite in SUITES),
                "live suite declarations missing")
        population["declared"] = declared
        population["observed"] = sanitized_outcomes(declared, [])
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
        provenance['archive_sha256'] = manifest['archive_sha256']
        record["hashes"]["manifests"] = {"build": archive.file_hash(args.archive_dir / 'manifest.json'),
            "unit-declarations": archive.file_hash(ROOT / 'unit-declarations.json'), "ci-pins": archive.file_hash(pins_path)}
        record["toolchain"] = toolchain()
        archive.record_signing(record, "adhoc")
        record["toolchain"]["versions"]["simulator_runtime"] = pins["simulators"][platform]["runtime"]
        runtime = pins["simulators"][platform]["runtime"]
        device = pins["device_types"]["iphone" if platform == "ios" else "appletv"]
        simulator = subprocess.check_output(["xcrun", "simctl", "create", "immichSlides-live-unit", device, runtime],
                                            env=clean, stderr=subprocess.DEVNULL, timeout=60, text=True).strip()
        budget = units.enumeration_budget("ci", platform)
        phase = "boot"
        print('Live phase: boot.', flush=True)
        require(capture(["xcrun", "simctl", "bootstatus", simulator, "-b"], private / "boot.log", env=clean,
                        timeout=budget["simulator_boot_timeout_seconds"]) == 0, "live boot failed")
        base = ["xcodebuild", "test-without-building", "-xctestrun", str(next(products.glob("*.xctestrun"))),
                "-destination", f"platform={archive.DESTINATIONS[platform]},id={simulator}",
                "-derivedDataPath", str(private / "derived"), "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never", *["-only-testing:immichSlidesTests/" + suite for suite in SUITES]]
        phase = "enumeration"
        print('Live phase: enumeration.', flush=True)
        archive.disk_check(args.min_free_gib)
        enum_path = private / "enumeration.json"
        require(capture([*base, "-enumerate-tests", "-test-enumeration-format", "json", "-test-enumeration-output-path", str(enum_path)],
                        private / "enumeration.log", env=clean, timeout=budget["timeout_seconds"]) == 0, "live enumeration failed")
        # Enumeration returns the whole target catalog even with class selectors.
        compiled = compiled_live_keys(decode(enum_path.read_text()), declared)
        compiled_ids = [test_identity("swift", "immichSlidesTests/" + name, platform=platform) for name in compiled]
        require(set(tokens(compiled_ids, functions=True)) == set(tokens(declared, functions=True)), "live selection mismatch")
        population["compiled"] = sorted(tokens(compiled_ids, functions=True).values(), key=lambda item: item["key"])
        phase = "execution"
        print('Live phase: execution.', flush=True)
        live_env = dict(clean, TEST_RUNNER_IMMICH_TEST_SERVER_URL=url, TEST_RUNNER_IMMICH_TEST_API_KEY=key,
                        TEST_RUNNER_IMMICHSLIDES_EVIDENCE="1")
        bundle = private / "live.xcresult"
        archive.disk_check(args.min_free_gib)
        code = capture([*base, "-resultBundlePath", str(bundle)], private / "execution.log", env=live_env, timeout=900)
        provenance["exit_code"] = code
        phase = "official-results"
        print('Live phase: official-results.', flush=True)
        for kind in ("tests", "summary"):
            # stderr is private too; malformed or failed exports cannot be used as evidence.
            require(capture(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", str(bundle), "--compact"],
                            private / ("official-" + kind + ".json"), env=clean, timeout=60) == 0, "live export failed")
        rows, counts = units.read_results(private, platform)
        population["observed"] = sanitized_outcomes(declared, rows)
        provenance["official_counts"] = {"total": counts.total_test_count, "passed": counts.passed_tests,
                                     "failed": counts.failed_tests, "skipped": counts.skipped_tests}
        validate_outcome_population(declared, compiled, rows, counts)
        coverage_verified = True
        phase = 'verdict'
        population["observed"] = public_outcomes(declared, compiled, rows, counts, code)
        record['status'] = 'passed'
    except Exception:
        # Never serialize exception text, subprocess output or runtime test arguments.
        record['infrastructure'].append({'code': 'coverage-failed' if phase == 'verdict' else 'live-' + phase + '-failed',
                                         'message': 'Live phase failed; private diagnostics withheld.'})
    finally:
        if simulator:
            for action, timeout in (("shutdown", 15), ("delete", 60)):
                try:
                    if capture(["xcrun", "simctl", action, simulator], private / (action + ".log"), env=clean, timeout=timeout):
                        record.update(status="failed")
                        record['infrastructure'].append({'code': 'live-cleanup-failed', 'message': 'Live simulator cleanup failed.'})
                except Exception:
                    record.update(status="failed")
                    record['infrastructure'].append({'code': 'live-cleanup-failed', 'message': 'Live simulator cleanup failed.'})
        # This runner owns every private input; no raw live material is publishable, even after failure.
        shutil.rmtree(private)
        shutil.rmtree(args.relocated_path, ignore_errors=True)
        parse_summary(record)
        archive.write_json(args.output_dir / "live-summary.json", record)
        archive.write_json(args.output_dir / 'live-provenance.json', provenance)
        (args.output_dir / "live-summary.md").write_text(render_markdown(record) +
            f"\nProcess exit: {provenance['exit_code']}; release eligibility remains disabled.\n")
        canary_passed = (phase == 'verdict' and coverage_verified and provenance['exit_code'] != 0 and
                    provenance.get('official_counts', {}).get('failed', 0) > 0 and
                    bool(population['compiled']) and record['status'] == 'failed' and
                    not any(entry['code'] == 'live-cleanup-failed' for entry in record['infrastructure']))
        if args.canary and canary_passed:
            archive.write_json(args.output_dir / 'canary.json', {'schema_version': 1, 'status': 'passed',
                'run_id': selection['run_id'], 'attempt': selection['attempt'], 'platform': platform, 'execution_failed': True})
        scan_tree(args.output_dir, needles)
        archive.output("records_safe", "true")
        print(f"Live finalization: {record['status']}; phase={phase}; process-exit={provenance['exit_code']}.", flush=True)
        require(not args.canary or canary_passed, 'canary did not exercise a failed live execution')
    return 0 if args.canary or record["status"] == "passed" else 1


def prepare_canary():
    require(os.environ.get('GITHUB_ACTIONS') == 'true', 'canary preparation is GitHub-only')
    url, key = canary_values(os.environ['GITHUB_RUN_ID'], int(os.environ['GITHUB_RUN_ATTEMPT']))
    for value in (url, key):
        print("::add-mask::" + value, flush=True)
    with Path(os.environ['GITHUB_ENV']).open('a') as handle:
        handle.write(f'CI_LIVE_URL={url}\nCI_LIVE_KEY={key}\n')
    return 0


def canary_values(run_id, attempt=1):
    seed = hashlib.sha256((f"immichslides-live-canary:{run_id}:{attempt}").encode()).hexdigest()
    return "https://" + seed[:24] + ".invalid/a path?quoted=\"x\"", seed[16:]


def audit_canary(path, run_id, attempt):
    require(path.is_dir() and not path.is_symlink(), 'canary audit directory missing')
    files = list(path.rglob('*'))
    require(not any(item.is_symlink() for item in files), 'canary audit refuses unscanned links')
    logs = list((path / 'logs').rglob('*.txt'))
    require(bool(logs) and all(item.stat().st_size > 0 for item in logs), 'canary extracted logs missing or empty')
    result = path / 'artifacts' / f'live-canary-ios-{run_id}-{attempt}'
    verdict = decode((result / 'canary.json').read_text()) if (result / 'canary.json').is_file() else {}
    require(verdict == {'schema_version': 1, 'status': 'passed', 'run_id': run_id, 'attempt': attempt,
                       'platform': 'ios', 'execution_failed': True}, 'canary result run or attempt mismatch')
    require((result / 'live-summary.json').is_file() and (result / 'live-summary.md').is_file() and
            (result / 'live-summary.md').stat().st_size > 0, 'canary summaries missing or empty')
    summary = parse_summary((result / 'live-summary.json').read_text())
    require(summary['run']['id'] == run_id and summary['run']['attempt'] == attempt and
            summary['run']['tier'] == 'live-unit' and summary['run']['shard'] == 'ios' and summary['status'] == 'failed' and
            bool(summary['population']['declared']) and bool(summary['population']['compiled']) and
            any(row['outcome'] == 'failed' for row in summary['population']['observed']), 'canary summary provenance mismatch')
    scan_tree(path, secret_forms(*canary_values(run_id, attempt)))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("admit")
    sub.add_parser('prepare-canary')
    choose = sub.add_parser('choose-artifact')
    choose.add_argument('--metadata', type=Path, required=True)
    choose.add_argument('--platform', choices=('ios', 'tvos'), required=True)
    audit = sub.add_parser("audit-canary")
    audit.add_argument("--run-id", required=True)
    audit.add_argument('--attempt', type=int, required=True)
    audit.add_argument("--path", type=Path, required=True)
    run = sub.add_parser("run")
    for name in ("selection-path", "archive-dir", "relocated-path", "output-dir", "private-dir"):
        run.add_argument("--" + name, type=Path, required=True)
    run.add_argument("--min-free-gib", type=float, default=80)
    run.add_argument('--canary', action='store_true')
    args = parser.parse_args(argv)
    try:
        if args.command == 'choose-artifact':
            pages = json.loads(args.metadata.read_text())
            entries = [entry for page in pages for entry in page['artifacts']]
            artifact_id, attempt = latest_artifact(entries, args.platform, os.environ['GITHUB_RUN_ID'],
                                                  int(os.environ['GITHUB_RUN_ATTEMPT']))
            archive.output('artifact_id', artifact_id)
            archive.output('producer_attempt', attempt)
            print(f'Selected immutable live artifact {artifact_id} from producer attempt {attempt}.')
            return 0
        if args.command == "audit-canary":
            audit_canary(args.path, args.run_id, args.attempt)
            print("Downloaded canary logs, summaries and artifacts: raw and transformed scan PASS.")
            return 0
        return admit() if args.command == "admit" else prepare_canary() if args.command == 'prepare-canary' else run_live(args)
    except Exception:
        print("Live boundary refused; no private diagnostics published.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
