"""Exact known-flaky policy and one filtered, reset-separated XCTest retry.

Trusted consumers supply the base registry; producer observations never grant
eligibility. The shared executor is usable by UI shards and the strict runner.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import date
from functools import partial
from pathlib import Path

from ci_summary import (ContractError, decode, duration, fields, identity_key, observation,
                        require, string, test_identity, validate_observation, validate_test_identity)

REGISTRY_PATH = "scripts/ci-known-flaky.json"
EMPTY_REGISTRY = {"schema_version": 1, "entries": []}
FORBIDDEN_FLAGS = {"-retry-tests-on-failure", "-run-tests-until-failure", "-test-iterations",
                   "-maximum-test-iterations", "-test-repetition-relaunch-enabled"}
METHOD = re.compile(r"[A-Za-z_]\w*/test[A-Za-z_]\w*")
ASSERTION_FAILURE = "Official XCTest assertion failure"


def calendar_date(value):
    string(value, "calendar date")
    try:
        parsed = date.fromisoformat(value)
    except ValueError as error:
        raise ContractError("date must be ISO calendar date") from error
    require(parsed.isoformat() == value, "date must be ISO calendar date")
    return parsed


def parse_registry(raw):
    payload = decode(raw)
    fields(payload, {"schema_version", "entries"}, "flaky registry")
    require(type(payload["schema_version"]) is int and payload["schema_version"] == 1,
            "unsupported flaky registry version")
    require(isinstance(payload["entries"], list), "registry entries must be an array")
    seen = set()
    for entry in payload["entries"]:
        fields(entry, {"identity", "scope", "issue", "owner", "review_by", "symptom", "evidence", "added_on"}, "flaky entry")
        identity = entry["identity"]
        validate_test_identity(identity)
        require(identity["kind"] in {"ui", "strict"}, "only UI and strict identities may be registered")
        require(METHOD.fullmatch(identity["key"]) is not None, "registry identity must name one exact XCTest method")
        if identity["kind"] == "ui":
            require(identity["dimensions"].get("platform") in {"ios", "tvos"}, "UI registry requires platform")
            require(set(identity["dimensions"]) == {"platform"}, "UI registry uses exact platform method identities")
        else:
            require(identity["dimensions"]["device"] in {"iphone", "ipad", "tv"}, "unknown strict device")
            require(identity["dimensions"]["configuration"] in {"Debug", "Release"}, "unknown strict configuration")
        fields(entry["scope"], {"tier", "environment"}, "flaky scope")
        require(entry["scope"]["tier"] == identity["kind"], "flaky tier must match identity kind")
        require(entry["scope"]["environment"] in {"hermetic", "live"}, "unknown flaky environment")
        string(entry["issue"], "tracking issue")
        require(re.fullmatch(r"https://github\.com/sudoHG/immichSlides/issues/[1-9][0-9]*", entry["issue"]) is not None,
                "tracking issue must belong to immichSlides")
        string(entry["owner"], "owner")
        require(re.fullmatch(r"[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*", entry["owner"]) is not None, "invalid owner")
        string(entry["symptom"], "symptom")
        require(isinstance(entry["evidence"], list) and bool(entry["evidence"]), "evidence must be nonempty")
        for evidence in entry["evidence"]:
            string(evidence, "evidence")
        require(calendar_date(entry["added_on"]) <= calendar_date(entry["review_by"]), "review date precedes added date")
        token = identity_key({"identity": identity, "scope": entry["scope"]})
        require(token not in seen, "duplicate registry identity and scope")
        seen.add(token)
    return payload


def validate_registry_population(registry, populations):
    for entry in parse_registry(registry)["entries"]:
        identity = entry["identity"]
        platform = (identity["dimensions"]["platform"] if identity["kind"] == "ui" else
                    "tvos" if identity["dimensions"]["device"] == "tv" else "ios")
        require(any(item["kind"] == "ui" and item["key"] == identity["key"]
                    and item["dimensions"].get("platform") == platform for item in populations[platform]),
                f"registered test no longer exists on {platform}: {identity['key']}")
        if identity["kind"] == "strict":
            from run_strict_e2e import resolve_suite_selector
            from strict_e2e_runner_support import FILTER_PERSON_SESSIONS, validate_suite_scenario, validate_suite_fixture
            from strict_e2e_build import build_settings
            dimensions = identity["dimensions"]
            build_settings(platform, dimensions["suite"], dimensions["configuration"])
            validate_suite_scenario(dimensions["suite"], dimensions["scenario"])
            validate_suite_fixture(dimensions["suite"], dimensions["fixture"])
            selectors = ([item["selector"] for item in FILTER_PERSON_SESSIONS] if dimensions["suite"] == "filter-person"
                         else [resolve_suite_selector(platform, dimensions["suite"])])
            require(any(selector == "immichSlidesUITests/" + identity["key"] or
                        (selector.count("/") == 1 and identity["key"].startswith(selector.split("/")[1] + "/"))
                        for selector in selectors), "registered method is outside its strict suite")


def eligible_entry(registry, identity, *, tier, environment, today):
    entries = parse_registry(registry)["entries"]
    return next((entry for entry in entries if entry["identity"] == identity
                 and entry["scope"] == {"tier": tier, "environment": environment}
                 and calendar_date(entry["review_by"]) >= today), None)


def nightly_findings(registry, *, today, issue_states):
    findings = []
    for entry in parse_registry(registry)["entries"]:
        if calendar_date(entry["review_by"]) < today:
            findings.append({"code": "expired", "issue": entry["issue"], "identity": entry["identity"]})
        number = int(entry["issue"].rsplit("/", 1)[1])
        state = issue_states.get(number)
        if state != "open":
            findings.append({"code": "issue-closed" if state == "closed" else "issue-state-unknown",
                             "issue": entry["issue"], "identity": entry["identity"]})
    return findings


def merge_retry(first, second):
    validate_observation(first)
    require(first["outcome"] == "failed" and len(first["attempts"]) == 1, "retry requires one failed first attempt")
    if second is None:
        second = observation(first["identity"], "not-run", 0, reason="Retry result missing or invalid", exit_code=None)
    validate_observation(second)
    require(second["identity"] == first["identity"] and len(second["attempts"]) == 1, "retry result identity/attempt mismatch")
    merged = copy.deepcopy(first)
    merged["attempts"].append(dict(second["attempts"][0], number=2))
    merged["duration_seconds"] += second["duration_seconds"]
    merged["outcome"] = "flaky-passed" if second["outcome"] == "passed" else "failed"
    validate_observation(merged)
    return merged


def retry_observations(first, registry, *, tier, environment, today, reset, execute):
    seen = set()
    merged = []
    for record in first:
        validate_observation(record)
        token = identity_key(record["identity"])
        require(token not in seen, "duplicate first-attempt identity")
        seen.add(token)
        if (record["outcome"] == "failed" and len(record["attempts"]) == 1
                and record["attempts"][0]["reason"] == ASSERTION_FAILURE
                and eligible_entry(registry, record["identity"], tier=tier, environment=environment, today=today)):
            reset()
            record = merge_retry(record, execute(record["identity"]))
        merged.append(record)
    return merged


def check_retry_flags(command):
    require(not any(item.split("=", 1)[0] in FORBIDDEN_FLAGS for item in command), "global retry/iteration flags are forbidden")


def retry_command(command, key, result_bundle):
    check_retry_flags(command)
    require(METHOD.fullmatch(key) is not None, "retry selector must name one exact method")
    require(command.count("test") + command.count("test-without-building") == 1, "one test action required")
    require(command.count("-resultBundlePath") == 1, "one result bundle path required")
    filtered = []
    iterator = iter(command)
    for item in iterator:
        if item == "-resultBundlePath":
            next(iterator)
            filtered.extend([item, str(result_bundle)])
        elif item in {"-only-testing", "-skip-testing"}:
            next(iterator)
        elif item.startswith(("-only-testing:", "-skip-testing:")):
            continue
        else:
            filtered.append("test-without-building" if item == "test" else item)
    filtered.append("-only-testing:immichSlidesUITests/" + key)
    return filtered


def registry_revision(root, environment, local_ref=None):
    event = environment.get("GITHUB_EVENT_NAME") if environment.get("GITHUB_ACTIONS") == "true" else "local"
    if event != "local":
        require(local_ref is None, "CI cannot override the base registry revision")
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        require(head == environment.get("GITHUB_SHA"), "checkout differs from GITHUB_SHA")
        if event == "pull_request":
            headers = subprocess.check_output(["git", "cat-file", "commit", head], cwd=root, text=True).partition("\n\n")[0]
            parents = [line[7:] for line in headers.splitlines() if line.startswith("parent ")]
            require(len(parents) == 2, "PR registry requires the merge commit's base parent")
            return parents[0]
        require(event in {"push", "workflow_dispatch", "schedule"} and environment.get("GITHUB_REF") == "refs/heads/main",
                "CI registry consumption requires PR or main")
        return head
    ref = local_ref or "HEAD"
    require(not ref.startswith("-") and ":" not in ref, "invalid local registry revision")
    return subprocess.check_output(["git", "rev-parse", "--verify", ref + "^{commit}"], cwd=root, text=True).strip()


def load_registry(root, revision):
    listed = subprocess.check_output(["git", "ls-tree", "--name-only", revision, "--", REGISTRY_PATH], cwd=root, text=True).strip()
    if not listed:
        raw = json.dumps(EMPTY_REGISTRY).encode()
    else:
        raw = subprocess.check_output(["git", "show", revision + ":" + REGISTRY_PATH], cwd=root)
    return parse_registry(raw.decode()), hashlib.sha256(raw).hexdigest()


def simulator_device_class(udid, expected=None):
    completed = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                               capture_output=True, check=True, timeout=60)
    payload = json.loads(completed.stdout)
    devices = [device for group in payload.get("devices", {}).values() for device in group if device.get("udid") == udid]
    require(len(devices) == 1, "target UDID must identify one available simulator")
    identifier = devices[0].get("deviceTypeIdentifier", "")
    classes = {"iPhone-": "iphone", "iPad-": "ipad", "Apple-TV-": "tv"}
    actual = next((kind for prefix, kind in classes.items()
                   if identifier.startswith("com.apple.CoreSimulator.SimDeviceType." + prefix)), None)
    require(actual is not None, "target simulator has an unknown device class")
    require(expected is None or actual == expected, "listed retry device does not match target simulator")
    return actual


def official_assertion_keys(payload):
    # The typed legacy issue summaries distinguish assertions from crashes. Never
    # infer eligibility from failure text, which can also contain private values.
    keys = {}
    blocked = False
    def walk(value):
        nonlocal blocked
        if isinstance(value, dict):
            if "errorSummaries" in value and value["errorSummaries"].get("_values"):
                blocked = True
            if "testCaseName" in value:
                require(isinstance(value["testCaseName"], dict) and isinstance(value.get("issueType"), dict),
                        "invalid official failure summary")
                name = value["testCaseName"].get("_value", "")
                kind = value.get("issueType", {}).get("_value")
                key = name.removesuffix("()").replace(".", "/")
                keys.setdefault(key, []).append(kind)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(payload)
    return set() if blocked else {key for key, kinds in keys.items()
                                 if kinds and all(kind == "Assertion Failure" for kind in kinds)}


def read_xcode_observations(bundle, identity_for_key, elapsed, invocation_exit, *, expected_device=None):
    from strict_e2e_p2_contract import official_tests_facts, device_class_of, P2ContractError
    completed = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle), "--compact"],
                               capture_output=True, check=True, timeout=60)
    payload = json.loads(completed.stdout)
    facts = official_tests_facts(payload)
    if expected_device is not None:
        udid, device_class = expected_device
        require(len(facts["devices"]) == 1 and facts["devices"][0].get("deviceId") == udid,
                "official result device does not match target UDID")
        try:
            actual_class = device_class_of(facts["devices"][0])
        except P2ContractError as error:
            raise ContractError("official result has an unknown simulator class") from error
        require(actual_class == device_class, "official result device class does not match target simulator")
    assertion_keys = set()
    if any(case["result"] == "Failed" for case in facts["test_cases"]):
        details = subprocess.run(["xcrun", "xcresulttool", "get", "object", "--legacy", "--path", str(bundle), "--format", "json"],
                                 capture_output=True, check=True, timeout=60)
        assertion_keys = official_assertion_keys(json.loads(details.stdout))
    durations = {}
    def collect_durations(nodes):
        require(isinstance(nodes, list), "invalid official result children")
        for node in nodes:
            require(isinstance(node, dict), "invalid official result node")
            if node.get("nodeType") == "Test Case":
                durations[node.get("nodeIdentifier")] = node.get("durationInSeconds")
            collect_durations(node.get("children", []))
    collect_durations(payload.get("testNodes", []))
    records = []
    seen = set()
    for case in facts["test_cases"]:
        require(case["bundle"] == "immichSlidesUITests", "unexpected result bundle target")
        raw_key = case["identifier"]
        require(isinstance(raw_key, str) and raw_key.endswith("()"), "unknown XCTest method identity")
        key = raw_key[:-2]
        require(METHOD.fullmatch(key) is not None and key not in seen, "invalid or repeated XCTest identity")
        seen.add(key)
        outcome = {"Passed": "passed", "Failed": "failed", "Skipped": "skipped"}.get(case["result"])
        require(outcome is not None, "unknown XCTest outcome")
        duration(durations.get(raw_key))
        records.append(observation(identity_for_key(key), outcome, durations[raw_key],
                                   reason=("Official XCTest skip" if outcome == "skipped" else
                                           ASSERTION_FAILURE if outcome == "failed" and key in assertion_keys else
                                           "Official non-assertion or unclassified failure" if outcome == "failed" else None),
                                   exit_code=0 if outcome == "passed" else invocation_exit))
    require(bool(records), "official XCTest result contains no tests")
    return records


def run_xcode_attempts(command, registry, *, tier, environment, today, identity_for_key,
                       reset, execute, allocate_bundle, read=read_xcode_observations):
    """Execute once, then retry each eligible assertion failure once; retain both calls.

    execute(command) returns (exit_code, elapsed_seconds). allocate_bundle()
    returns a fresh private directory's bundle path for each retry. A consumer
    exports and disposes every invocation's bundle after reading this result.
    """
    check_retry_flags(command)
    bundle = Path(command[command.index("-resultBundlePath") + 1])
    invocations = []
    def invoke(call, path, retry_identity=None):
        from strict_e2e_runner_support import CommandError
        started = time.monotonic()
        invocation = {"command": call, "result_bundle": str(path)}
        invocations.append(invocation)
        try:
            code, elapsed = execute(call)
        except (CommandError, OSError, subprocess.SubprocessError) as error:
            timed_out = (isinstance(error, subprocess.TimeoutExpired) or
                         isinstance(error.__cause__, subprocess.TimeoutExpired) or
                         str(error).startswith("xcodebuild timed out after "))
            code, elapsed = (124 if timed_out else getattr(error, "code", 2)), time.monotonic() - started
            outcome = "timed-out" if timed_out else "not-run"
            invocation.update(exit_code=code, duration_seconds=elapsed, outcome=outcome)
            rows = ([observation(retry_identity, outcome, elapsed, reason="Xcode execution did not complete", exit_code=code)]
                    if retry_identity is not None else [])
            return rows, code
        invocation.update(exit_code=code, duration_seconds=elapsed)
        try:
            return read(path, identity_for_key, elapsed, code), code
        except (ContractError, OSError, ValueError, subprocess.SubprocessError):
            return [], code or 1
    first, first_exit = invoke(command, bundle)
    effective_bundle = bundle
    def retry(identity):
        nonlocal effective_bundle
        retry_bundle = Path(allocate_bundle())
        require(retry_bundle.parent not in {Path(call["result_bundle"]).parent for call in invocations},
                "Every retry bundle requires an independent private directory")
        records, code = invoke(retry_command(command, identity["key"], retry_bundle), retry_bundle, identity)
        if len(records) != 1 or records[0]["identity"] != identity:
            return None
        effective_bundle = retry_bundle
        if code and records[0]["outcome"] == "passed":
            return observation(identity, "crashed", invocations[-1]["duration_seconds"],
                               reason="Retry invocation failed despite passing test row", exit_code=code)
        return records[0]
    # Exit 65 with official assertion failures is retryable. Infrastructure exits
    # and first-call skips/crashes/missing results never obtain a second call.
    observed = retry_observations(first, registry, tier=tier, environment=environment, today=today,
                                  reset=reset, execute=retry) if first_exit == 65 else first
    successful = bool(observed) and all(item["outcome"] in {"passed", "flaky-passed"} for item in observed)
    code = 0 if successful and (first_exit == 0 or (first_exit == 65 and len(invocations) > 1)) else first_exit or 1
    return {"exit_code": code, "observed": observed, "invocations": invocations,
            "effective_bundle": str(effective_bundle)}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate the candidate known-flaky registry; dates and issue state do not gate PRs")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--xctestrun", type=Path, help="Run a built UI target with listed-only retries")
    parser.add_argument("--destination")
    parser.add_argument("--platform", choices=("ios", "tvos"))
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--only-testing", action="append", default=[])
    parser.add_argument("--registry-ref", help="Explicit local registry commit; forbidden in CI")
    parser.add_argument("--timeout-seconds", type=int, default=300)
    args = parser.parse_args(argv)
    if args.xctestrun:
        if not args.destination or not args.platform or not args.output_dir or args.timeout_seconds <= 0:
            parser.error("UI execution requires destination, platform, fresh output-dir and positive timeout")
        return run_ui(args)
    if args.registry_ref or args.destination or args.platform or args.output_dir or args.only_testing:
        parser.error("execution options require --xctestrun")
    try:
        from ci_population import ui_identities
        files = {str(path.relative_to(args.root)): path.read_text(encoding="utf-8")
                 for directory in ("immichSlidesUITests", "TestSupport") for path in (args.root / directory).rglob("*.swift")}
        registry = parse_registry((args.root / REGISTRY_PATH).read_text(encoding="utf-8"))
        validate_registry_population(registry, {platform: ui_identities(files, platform) for platform in ("ios", "tvos")})
    except (ContractError, OSError, ValueError, RuntimeError) as error:
        print(f"FAIL: flaky registry: {error}", file=sys.stderr)
        return 1
    print(f"PASS: flaky registry format, duplicates and population ({len(registry['entries'])} entries)")
    return 0


def run_ui(args):
    from run_host_checks import run_identity, source_metadata, toolchain
    from ci_summary import write_summary
    from run_strict_e2e import (run_command, export_private_result_bundle, finalize_private_result_bundle,
                                prepare_private_result_bundle_path, ensure_disk_for_xcodebuild, data_available_gib)
    from strict_e2e_runner_support import CommandError, destination_udid, reset_simulator_app
    from ci_build_archive import workspace_preflight
    from strict_e2e_server import PUBLIC_API_KEY
    from run_strict_e2e import WRONG_PUBLIC_API_KEY, write_sensitive_scan
    output = args.output_dir.resolve()
    root = args.root.resolve()
    require(output != root and root not in output.parents and not os.path.lexists(output), "UI output must be fresh and outside checkout")
    output.mkdir(parents=True)
    invocations = []
    result = None
    summary = None
    try:
        workspace_preflight(root)
        revision = registry_revision(root, os.environ, args.registry_ref)
        registry, digest = load_registry(root, revision)
        identity = run_identity(os.environ, ci=os.environ.get("GITHUB_ACTIONS") == "true")
        workflow, fork = source_metadata(identity, os.environ, None)
        summary = {"schema_version": 1, "identity": identity,
                   "source": {"repository": identity["repository"], "workflow_path": workflow,
                              "event": identity["event"], "fork_originated": fork, "ci_changing": None},
                   "run": {"id": os.environ.get("GITHUB_RUN_ID"), "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
                           "tier": "ui", "job": "ui-tests", "shard": args.platform},
                   "hashes": {"manifests": {}, "policies": {"known-flaky": digest}},
                   "toolchain": toolchain(), "population": {"declared": [], "compiled": [], "observed": [],
                                                              "deselected": [], "removed_by_pr": []},
                   "infrastructure": [], "status": "failed"}
        summary["toolchain"]["signing_mode"] = "sign-to-run-locally"
        write_summary(summary, output)
        udid = destination_udid(args.destination)
        device_class = simulator_device_class(udid)
        require((device_class == "tv") == (args.platform == "tvos"), "UI platform does not match target simulator")
        def reset():
            with (output / "app-reset.log").open("a") as log:
                log.write(reset_simulator_app(udid))
        reset()
        bundle = prepare_private_result_bundle_path("ui-flaky")
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(args.xctestrun.resolve()),
                   "-destination", args.destination, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                   "-resultBundlePath", str(bundle)]
        for selector in args.only_testing:
            command.append("-only-testing:" + selector)
        def execute(call):
            ensure_disk_for_xcodebuild(data_available_gib)
            path = Path(call[call.index("-resultBundlePath") + 1])
            invocations.append(path)
            started = time.monotonic()
            from strict_e2e_runner_support import _is_forbidden_key
            environment = {key: value for key, value in os.environ.items() if not _is_forbidden_key(key)}
            code = run_command(call, cwd=root, environment=environment,
                               log_path=output / f"attempt-{len(invocations)}.log", timeout_seconds=args.timeout_seconds)
            return code, time.monotonic() - started
        result = run_xcode_attempts(command, registry, tier="ui", environment="hermetic", today=date.today(),
                                   identity_for_key=lambda key: test_identity("ui", key, platform=args.platform),
                                   reset=reset, execute=execute,
                                   read=partial(read_xcode_observations, expected_device=(udid, device_class)),
                                   allocate_bundle=lambda: prepare_private_result_bundle_path("ui-flaky-retry"))
        summary["population"]["observed"] = result["observed"]
        (output / "retry-invocations.json").write_text(json.dumps(dict(result, registry_revision=revision), indent=2) + "\n")
        # The shard owner supplies independently compiled and declared selections.
        # This local adapter enumerates the selected compiled bundle below.
        ensure_disk_for_xcodebuild(data_available_gib)
        subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", str(args.xctestrun.resolve()),
                                      "-destination", args.destination, "-enumerate-tests", "-test-enumeration-format", "json",
                                      "-test-enumeration-output-path", str(output / "compiled.json"),
                                      *["-only-testing:" + selector for selector in args.only_testing]],
                                     capture_output=True, check=True, timeout=60)
        compiled = enumerated_ui_keys(json.loads((output / "compiled.json").read_text()))
        summary["population"]["compiled"] = [test_identity("ui", key.removeprefix("immichSlidesUITests/").removesuffix("()"), platform=args.platform)
                                                 for key in compiled]
        summary["population"]["declared"] = list(summary["population"]["compiled"])
        observed_tokens = {identity_key(item["identity"]) for item in result["observed"]}
        if observed_tokens != {identity_key(item) for item in summary["population"]["compiled"]}:
            result["exit_code"] = result["exit_code"] or 1
            summary["infrastructure"].append({"code": "coverage-failed", "message": "Compiled selection differs from observed tests"})
        summary["status"] = "passed" if result["exit_code"] == 0 else "failed"
        write_summary(summary, output)
        for record in result["observed"]:
            print(f"{record['identity']['key']}: {record['outcome']}, attempts={len(record['attempts'])}", flush=True)
        return result["exit_code"]
    except (CommandError, ContractError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        if summary is not None:
            summary["status"] = "failed"
            summary["infrastructure"].append({"code": "ui-runner-failed", "message": str(error)})
            write_summary(summary, output)
        print(f"FAIL: UI retry runner: {error}", file=sys.stderr)
        return 1
    finally:
        finalization_errors = []
        for number, bundle in enumerate(invocations, 1):
            digest = None
            exported = False
            if bundle.exists():
                try:
                    digest = export_private_result_bundle(bundle, output, [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY], suffix=f"-attempt-{number}")
                    write_sensitive_scan(output, [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY])
                    exported = True
                except (CommandError, ContractError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                    finalization_errors.append(f"Attempt {number}: {type(error).__name__}: {error}")
            try:
                failures = finalize_private_result_bundle(bundle, output, digest, successful=exported, suffix=f"-attempt-{number}")
                finalization_errors.extend(f"Attempt {number}: {error}" for error in failures)
            except (CommandError, ContractError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                finalization_errors.append(f"Attempt {number}: {type(error).__name__}: {error}")
        if finalization_errors:
            if summary is not None:
                summary["status"] = "failed"
                summary["infrastructure"].extend({"code": "bundle-finalization-failed", "message": error}
                                                 for error in finalization_errors)
                write_summary(summary, output)
            for error in finalization_errors:
                print(f"FAIL: {error}", file=sys.stderr)
            return 1


def enumerated_ui_keys(payload):
    require(isinstance(payload, dict) and payload.get("errors") == [], "compiled enumeration reported errors")
    keys = []
    def walk(value, parents):
        if isinstance(value, list):
            for node in value:
                walk(node, parents)
        elif isinstance(value, dict):
            disabled = value.get("disabled", False)
            require(type(disabled) is bool, "invalid enumeration disabled flag")
            if disabled:
                return
            name = value.get("name")
            lineage = parents + ([name] if isinstance(name, str) else [])
            if name and isinstance(name, str) and name.startswith("test") and name.endswith("()"):
                require("immichSlidesUITests" in lineage and len(parents) >= 2, "unexpected compiled test target")
                key = parents[-1] + "/" + name[:-2]
                require(METHOD.fullmatch(key) is not None and key not in keys, "invalid/duplicate compiled identity")
                keys.append(key)
            for field in ("values", "children"):
                if field in value:
                    walk(value[field], lineage)
    walk(payload, [])
    require(bool(keys), "compiled UI enumeration contains no tests")
    return keys


if __name__ == "__main__":
    raise SystemExit(main())
