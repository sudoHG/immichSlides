#!/usr/bin/env python3
"""Wait for identity-bound gate archives and run manifest-selected fixture UI shards."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import platform
import subprocess
import sys
import tempfile
import time
import urllib.error
import zipfile
from pathlib import Path
from urllib.request import Request, build_opener

from ci_build_archive import (artifact_name, check_products, extract_products, file_hash, measure_signing,
                              output, validate_artifact, validate_manifest, workspace_preflight)
from ci_publish import ArtifactRedirect, GitHub, json_member, verify_workflow
from ci_summary import (ContractError, decode, observation, parse_identity, parse_summary, require, test_identity, write_summary)
from ci_ui_shards import DEVICES, MANIFEST_PATH, parse_shard_manifest, shard_populations
from ci_verdict import classify_changes
from run_host_checks import run_identity, source_metadata, toolchain

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ".github/workflows/ci-ui.yml"
GATE_WORKFLOW = ".github/workflows/ci-gate.yml"
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def git_blob(revision, path):
    return subprocess.check_output(["git", "show", revision + ":" + path], cwd=ROOT, timeout=60)


def context():
    ci = os.environ.get("GITHUB_ACTIONS") == "true"
    identity = run_identity(os.environ, ci=ci)
    require(identity["event"] in {"pull_request", "push", "local"}, "UI producer accepts only PR or main pushes")
    workflow, fork = source_metadata(identity, os.environ, WORKFLOW if ci else None)
    return {"identity": identity,
            "source": {"repository": identity["repository"], "workflow_path": workflow,
                       "event": identity["event"], "fork_originated": fork, "ci_changing": None},
            "run": {"id": os.environ.get("GITHUB_RUN_ID"), "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
                    "tier": "ui-infrastructure", "job": "ui-archive", "shard": None}}


def summary_for(ctx, manifest_hash):
    step = test_identity("host", "UI archive selection")
    return {"schema_version": 1, **ctx,
            "hashes": {"manifests": {"ui-shards": manifest_hash}, "policies": {}},
            "toolchain": toolchain(tier="pr" if ctx["identity"]["event"] != "local" else None),
            "population": {"declared": [step], "compiled": [step], "observed": [], "deselected": [], "removed_by_pr": []},
            "infrastructure": [], "status": "failed"}


def app_affected(identity):
    if identity["event"] != "pull_request":
        return True
    base = identity["base_sha"]
    paths = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", base + "..." + identity["head_sha"]],
                                    cwd=ROOT, text=True, timeout=60).splitlines()
    members = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", "HEAD", "--", "immichSlides"],
                                      cwd=ROOT, text=True, timeout=60).splitlines()
    return classify_changes(paths or ["__unknown_empty_diff__"], decode(git_blob(base, "scripts/ci-classification.json").decode()),
                            build_target_paths=members)["app_affected"]


def downloaded_archive(api, artifact):
    require(artifact["expired"] is False and 0 < artifact["size_in_bytes"] <= MAX_ARCHIVE_BYTES,
            "build archive is expired or exceeds the bounded download")
    request = Request(f"https://api.github.com/repos/{api.repository}/actions/artifacts/{artifact['id']}/zip",
                      headers={"Authorization": "Bearer " + api.token, "Accept": "application/vnd.github+json"})
    try:
        with build_opener(ArtifactRedirect()).open(request, timeout=60) as response:
            raw = response.read(MAX_ARCHIVE_BYTES + 1)
    except urllib.error.HTTPError as error:
        raise ContractError(f"Archive download refused (HTTP {error.code})") from None
    require(len(raw) <= MAX_ARCHIVE_BYTES, "build archive download exceeds limit")
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entries = archive.infolist()
        require(len(entries) == 2 and {entry.filename for entry in entries} == {"manifest.json", "build.tar.gz"},
                "unexpected build archive ZIP contents")
        require(all(entry.file_size <= MAX_ARCHIVE_BYTES for entry in entries), "oversized build archive member")
        require(next(entry.file_size for entry in entries if entry.filename == "manifest.json") <= 4 * 1024 * 1024,
                "build manifest exceeds limit")
        manifest_raw, tar_raw = archive.read("manifest.json"), archive.read("build.tar.gz")
        require(len(manifest_raw) <= 4 * 1024 * 1024, "build manifest exceeds limit")
        manifest = decode(manifest_raw.decode())
        require(hashlib.sha256(tar_raw).hexdigest() == manifest["archive_sha256"], "build archive hash differs")
        return manifest, hashlib.sha256(manifest_raw).hexdigest()


def check_cross_run_identity(manifest, identity, run, attempt, pins, pins_hash):
    require(parse_identity(manifest["identity"]) == parse_identity(identity), "archive-identity-mismatch: same head has another base or tree")
    require(manifest["producer"] == {"run_id": str(run["id"]), "attempt": attempt, "workflow_path": GATE_WORKFLOW,
                                     "artifact_name": artifact_name("ios", str(run["id"]), attempt)}, "archive producer differs")
    require(manifest["platform"] == "ios" and manifest["configuration"] == "Debug", "archive platform/configuration differs")
    require(manifest["xcode_build"] == pins["xcode"]["build"] and manifest["pins_sha256"] == pins_hash,
            "archive toolchain/pins differ")
    require(manifest["signing_mode"] == "adhoc" and manifest["private_configuration_present"] is False,
            "archive is not secret-free and locally signed")


def build_job_attempt(api, run):
    retained = None
    require(0 < run["run_attempt"] <= 100, "gate attempts exceed bound")
    for attempt in range(1, run["run_attempt"] + 1):
        matches = [job for job in api.pages(f"actions/runs/{run['id']}/attempts/{attempt}/jobs", "jobs") if job["name"] == "build-ios"]
        require(len(matches) <= 1, "duplicate gate iOS producer job")
        if not matches:
            continue
        job = matches[0]
        same = retained and all(job.get(key) and job[key] == retained.get(key) for key in ("started_at", "completed_at", "runner_id"))
        retained = dict(job, evidence_attempt=retained["evidence_attempt"] if same else attempt)
    return retained


def select_archive(api, identity, *, timeout_seconds, poll_seconds=20, record_refusals=None):
    workflow = api.repo("actions/workflows/ci-gate.yml")
    require(workflow["path"] == GATE_WORKFLOW and workflow["state"] == "active", "gate workflow is not active at its expected path")
    head = identity.get("head_sha", identity.get("pushed_sha"))
    head_repository = (api.repo(f"pulls/{identity['pull_request']}")["head"]["repo"]["full_name"]
                       if identity["event"] == "pull_request" else api.repository)
    started, refusals = time.monotonic(), []
    from setup_ci_python import load_pins
    pins = load_pins(ROOT / "scripts/ci-pins.json", tier="pr")
    def refuse(run, outcome, **details):
        refusal = {"run_id": run["id"], "head_sha": head, "consumer_identity": identity,
                   "outcome": outcome, **details}
        if refusal not in refusals:
            refusals.append(refusal)
            if record_refusals:
                record_refusals(refusals)
            print(f"Refused same-head archive from run {run['id']}: {outcome}", flush=True)
    while time.monotonic() - started < timeout_seconds:
        runs = api.pages(f"actions/workflows/{workflow['id']}/runs", "workflow_runs", head_sha=head, event=identity["event"])
        runs = [run for run in runs if run.get("head_sha") == head and
                (identity["event"] != "pull_request" or not run.get("pull_requests") or
                 any(pr["number"] == identity["pull_request"] for pr in run["pull_requests"]))]
        # Refuse older-base artifacts instead of reusing an arbitrary same-head build.
        # The newest available matching identity is selected; newer in-progress
        # matching runs must finish their build before older runs can be reused.
        for run in sorted(runs, key=lambda value: value["id"], reverse=True):
            verify_workflow(run, workflow, api.repository)
            if run["head_repository"]["full_name"] != head_repository:
                refuse(run, "archive-head-repository-mismatch", producer_head_repository=run["head_repository"]["full_name"])
                continue
            job = build_job_attempt(api, run)
            attempt = job["evidence_attempt"] if job else run["run_attempt"]
            artifacts = api.pages(f"actions/runs/{run['id']}/artifacts", "artifacts")
            name = f"build-ios-records-{run['id']}-{attempt}"
            records = [artifact for artifact in artifacts if artifact["name"] == name and not artifact["expired"]]
            if not records:
                # A cancelled build may have no summary; its recorded PR base can
                # still prove refusal, but cannot establish an exact identity.
                pr = next((pr for pr in run.get("pull_requests", []) if pr["number"] == identity.get("pull_request")), None)
                base = pr.get("base", {}).get("sha") if pr else None
                if base and base != identity.get("base_sha"):
                    refuse(run, "archive-identity-mismatch", producer_attempt=attempt, producer_base_sha=base)
                    continue
                break
            require(len(records) == 1, "duplicate gate build record")
            build = parse_summary(json_member(api, records[0], "summary.json"))
            require(build["source"]["workflow_path"] == GATE_WORKFLOW and build["source"]["repository"] == api.repository
                    and build["source"]["event"] == identity["event"]
                    and build["source"]["fork_originated"] == (head_repository != api.repository)
                    and build["identity"].get("head_sha", build["identity"].get("pushed_sha")) == head
                    and build["run"] == {"id": str(run["id"]), "attempt": attempt, "tier": "build", "job": "build-ios", "shard": "ios"},
                    "invalid gate build record provenance")
            if build["identity"] != identity:
                refuse(run, "archive-identity-mismatch", producer_attempt=attempt, producer_identity=build["identity"])
                continue
            if job is None or job["status"] != "completed":
                break
            require(job["conclusion"] == "success" and build["status"] == "passed", "newest exact-identity gate iOS build did not succeed")
            archives = [artifact for artifact in artifacts if artifact["name"] == artifact_name("ios", str(run["id"]), attempt)]
            require(len(archives) == 1, "matching archive is missing or duplicated")
            archive = archives[0]
            validate_artifact(archive, identity, str(run["id"]), attempt, "ios", archive["id"])
            manifest, manifest_hash = downloaded_archive(api, archive)
            check_cross_run_identity(manifest, identity, run, attempt, pins, file_hash(ROOT / "scripts/ci-pins.json"))
            require(build["hashes"]["manifests"]["build"] == manifest_hash, "gate record and downloaded manifest differ")
            return {"schema_version": 1, "identity": identity, "producer_run_id": str(run["id"]),
                    "producer_attempt": attempt, "artifact_id": archive["id"], "artifact_name": archive["name"],
                    "build_manifest_sha256": manifest_hash, "pins_sha256": file_hash(ROOT / "scripts/ci-pins.json"),
                    "wait_seconds": time.monotonic() - started, "refusals": refusals}
        print("Waiting for the matching ci-gate iOS archive", flush=True)
        time.sleep(min(poll_seconds, max(0, timeout_seconds - (time.monotonic() - started))))
    error = "archive-identity-mismatch" if refusals else "archive-unavailable"
    raise ContractError(error + ": no exact-identity gate archive before timeout")


def wait_archive(args):
    ctx = context()
    records = args.output_dir.resolve()
    require(ROOT != records and ROOT not in records.parents, "UI output must be outside checkout")
    records.mkdir(parents=True, exist_ok=False)
    manifest_hash = file_hash(ROOT / MANIFEST_PATH)
    parse_shard_manifest((ROOT / MANIFEST_PATH).read_text())
    summary = summary_for(ctx, manifest_hash)
    started, code = time.monotonic(), 1
    try:
        workspace_preflight(ROOT)
        affected = app_affected(ctx["identity"])
        output("app_affected", str(affected).lower())
        output("selection_artifact", f"ui-archive-{ctx['run']['id']}-{ctx['run']['attempt']}")
        if affected:
            api = GitHub(ctx["identity"]["repository"], os.environ["GH_TOKEN"])
            selection = select_archive(api, ctx["identity"], timeout_seconds=args.timeout_minutes * 60,
                                       record_refusals=lambda rows: write_json(records / "archive-refusals.json", rows))
            for key in ("artifact_id", "producer_run_id", "producer_attempt"):
                output(key, selection[key])
            write_json(records / "archive-selection.json", selection)
        else:
            write_json(records / "archive-selection.json", {"schema_version": 1, "identity": ctx["identity"], "status": "not-applicable"})
        summary["status"], code = "passed", 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        summary["infrastructure"].append({"code": "archive-selection-failed", "message": str(error)[:200]})
    finally:
        step = summary["population"]["declared"][0]
        summary["population"]["observed"] = [observation(step, "passed" if code == 0 else "failed", time.monotonic() - started,
                    reason=None if code == 0 else "UI archive selection failed", exit_code=code)]
        write_summary(summary, records)
    return code


def run_shard(args):
    from run_fixture_ui_tests import declared_tests, main as fixture_main
    ctx = context()
    workspace_preflight(ROOT)
    platform_name = DEVICES[args.device]
    manifest_raw = git_blob(args.manifest_revision, MANIFEST_PATH) if args.manifest_revision else (ROOT / MANIFEST_PATH).read_bytes()
    manifest = parse_shard_manifest(manifest_raw.decode())
    require(args.shard in manifest["shards"], "shard is absent from the requested manifest revision")
    plan_path = ROOT / ("immichSlides-" + ("iOS" if platform_name == "ios" else "tvOS") + ".xctestplan")
    plan = decode(plan_path.read_text())
    ui_root = ROOT / "immichSlidesUITests"
    population = declared_tests({path.relative_to(ui_root).as_posix(): path.read_text() for path in ui_root.rglob("*.swift")}, platform_name, plan, [])
    shard = shard_populations(population, plan, manifest, args.device)[args.shard]
    require(shard, "requested UI shard has no declared tests")
    require(not os.environ.get("GITHUB_ACTIONS") or args.manifest_revision is None, "CI cannot override the admitted manifest")
    with tempfile.TemporaryDirectory(prefix="ui-shard-manifest-") as manifest_directory:
        manifest_path = Path(manifest_directory, "manifest.json")
        manifest_path.write_bytes(manifest_raw)
        if args.archive_dir:
            require(args.device == "iphone", "archive producer currently supports iPhone only")
            selection = decode(args.selection_path.read_text())
            require(parse_identity(selection["identity"]) == ctx["identity"], "UI selection differs from the consumer identity")
            manifest_build_path = args.archive_dir / "manifest.json"
            require(file_hash(manifest_build_path) == selection["build_manifest_sha256"], "selected build manifest changed")
            build = decode(manifest_build_path.read_text())
            from setup_ci_python import load_pins
            pins = load_pins(ROOT / "scripts/ci-pins.json", tier="pr")
            validate_manifest(build, ctx["identity"], selection["producer_run_id"], selection["producer_attempt"],
                              platform_name, pins["xcode"]["build"], file_hash(ROOT / "scripts/ci-pins.json"))
            require(not os.path.lexists(build["source_path"]) and not os.path.lexists(build["products_path"]),
                    "build-time checkout or Products path remains present")
            require(str((args.relocated_path / "Products").resolve()) != build["products_path"], "UI relocation path is not distinct")
            extract_products(args.archive_dir / "build.tar.gz", args.relocated_path, build)
            products = args.relocated_path / "Products"
            check_products(products)
            apps = list(products.glob("Debug-*simulator/immichSlides.app"))
            require(len(apps) == 1 and measure_signing(apps[0]) == build["signing_mode"], "relocated app signing differs")
            runs = list(products.glob("*.xctestrun"))
            require(len(runs) == 1, "archive needs one default-plan test run")
            xctestrun = runs[0]
        else:
            xctestrun = args.xctestrun
        command = ["--device", args.device, "--destination", args.destination, "--output-dir", str(args.output_dir),
                   "--xctestrun", str(xctestrun), "--shard", args.shard, "--shard-manifest", str(manifest_path),
                   "--timeout-minutes", str(args.timeout_minutes), "--total-timeout-minutes", str(args.total_timeout_minutes),
                   "--result-export-timeout-seconds", str(args.result_export_timeout_seconds),
                   "--min-free-gib", str(args.min_free_gib), "--listed-only-retry", "--failure-screenshots"]
        for entry in shard:
            command += ["--only-testing", "immichSlidesUITests/" + entry["key"]]
        started = time.monotonic()
        code = fixture_main(command)
        write_json(args.output_dir / "shard-timing.json", {"schema_version": 1, "device": args.device, "shard": args.shard,
                   "wall_seconds": time.monotonic() - started, "exit_code": code,
                   "max_parallel": 2, "invocation_timeout_minutes": args.timeout_minutes,
                   "total_timeout_minutes": args.total_timeout_minutes, "result_export_timeout_seconds": args.result_export_timeout_seconds})
        return code


def failed_shard(args, error):
    directory = args.output_dir.resolve()
    if ROOT == directory or ROOT in directory.parents or os.path.lexists(directory):
        return
    directory.mkdir(parents=True, mode=0o700)
    ctx = context()
    ctx["run"].update(tier="ui", job="ui-" + args.device, shard=args.shard)
    summary = summary_for(ctx, file_hash(ROOT / MANIFEST_PATH))
    summary["population"].update(declared=[], compiled=[], observed=[])
    summary["infrastructure"] = [{"code": "ui-shard-preflight-failed", "message": str(error)[:200]}]
    write_summary(summary, directory)


def verify_reproduction_pins(source, destination, environment, *, tier="pr"):
    from strict_e2e_runner_support import destination_udid
    from setup_ci_python import load_pins
    pins = load_pins(source / "scripts/ci-pins.json", tier=tier)
    # A local installation may have a different bundle path from hosted macOS.
    # Freeze the selected path, then verify its pinned version/build.
    try:
        environment["DEVELOPER_DIR"] = environment.get("DEVELOPER_DIR") or subprocess.check_output(
            ["xcode-select", "-p"], env=environment, text=True, timeout=60).strip()
        observed = subprocess.check_output(["xcodebuild", "-version"], env=environment, text=True, timeout=60).strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise ContractError("reproduction Xcode pin check failed: selected toolchain unavailable") from error
    expected = f"Xcode {pins['xcode']['version']}\nBuild version {pins['xcode']['build']}"
    require(observed == expected, f"reproduction Xcode pin mismatch: expected {expected!r}, observed {observed!r}")
    require(destination.startswith("platform=iOS Simulator,"), "reproduction needs an iOS Simulator destination")
    udid = destination_udid(destination)
    inventory = decode(subprocess.check_output(["xcrun", "simctl", "list", "--json"], env=environment, text=True, timeout=60))
    pin = pins["simulators"]["ios"]
    runtimes = [runtime for runtime in inventory["runtimes"] if runtime["identifier"] == pin["runtime"]
                and runtime.get("isAvailable") and runtime["version"] == pin["version"] and runtime["buildversion"] == pin["build"]]
    require(len(runtimes) == 1, "reproduction simulator runtime pin mismatch")
    devices = [(runtime, device) for runtime, devices in inventory["devices"].items() for device in devices if device["udid"] == udid]
    types = [device["identifier"] for device in inventory["devicetypes"] if device["name"] == pins["device_types"]["iphone"]]
    require(len(devices) == 1 and devices[0][0] == pin["runtime"] and devices[0][1].get("isAvailable") is True,
            "reproduction destination runtime pin mismatch or unavailable simulator")
    require(len(types) == 1 and devices[0][1].get("deviceTypeIdentifier") == types[0], "reproduction destination device type pin mismatch")
    print("Verified reproduction Xcode, runtime and destination device pins", flush=True)
    return pins


def reproduce(args):
    revision = subprocess.check_output(["git", "rev-parse", "--verify", args.manifest_revision + "^{commit}"], cwd=ROOT,
                                       text=True, timeout=60).strip()
    output_root = args.output_dir.resolve()
    require(ROOT != output_root and ROOT not in output_root.parents, "reproduction output must be outside checkout")
    output_root.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="ui-reproduction-", dir=output_root) as directory:
        source = Path(directory, "source")
        subprocess.run(["git", "clone", "--quiet", "--no-local", str(ROOT), str(source)], check=True, timeout=120)
        subprocess.run(["git", "checkout", "--quiet", "--detach", revision], cwd=source, check=True, timeout=60)
        workspace_preflight(source)
        manifest = parse_shard_manifest((source / MANIFEST_PATH).read_text())
        require(args.shard in manifest["shards"], "reproduction shard is missing at that revision")
        # The clean checkout contains no private symlink or ambient local inputs.
        from run_fixture_ui_tests import clean_environment
        environment = clean_environment(os.environ)
        environment["CI_TOOLCHAIN_TIER"] = args.toolchain_profile
        pins = verify_reproduction_pins(source, args.destination, environment, tier=args.toolchain_profile)
        write_json(output_root / "reproduction.json", {
            "schema_version": 1, "revision": revision, "shard": args.shard, "destination": args.destination,
            "toolchain_profile": args.toolchain_profile, "resolved_profile": pins.get("profile", pins["runner"]),
            "pins_sha256": file_hash(source / "scripts/ci-pins.json"),
            "xcode_version": pins["xcode"]["version"], "xcode_build": pins["xcode"]["build"],
            "ios_runtime": pins["simulators"]["ios"], "device_type": pins["device_types"]["iphone"]})
        derived = Path(directory, "derived")
        build_records = Path(directory, "build")
        completed = subprocess.run([sys.executable, "-B", str(source / "scripts/ci_build_archive.py"), "build", "--platform", "ios",
                                   "--derived-data-path", str(derived), "--output-dir", str(build_records)], cwd=source,
                                   env=environment, check=False)
        if completed.returncode:
            return completed.returncode
        runs = list((derived / "Build/Products").glob("*.xctestrun"))
        require(len(runs) == 1, "reproduction build needs one default plan")
        return subprocess.run([sys.executable, "-B", str(source / "scripts/ci_ui_tests.py"), "run", "--device", "iphone",
                               "--shard", args.shard, "--manifest-revision", revision, "--destination", args.destination,
                               "--xctestrun", str(runs[0]), "--output-dir", str(output_root / "records")], cwd=source,
                               env=environment, check=False).returncode


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    wait = commands.add_parser("wait-archive")
    wait.add_argument("--output-dir", type=Path, required=True)
    wait.add_argument("--timeout-minutes", type=float, default=35)
    run = commands.add_parser("run")
    run.add_argument("--device", choices=DEVICES, required=True)
    run.add_argument("--shard", required=True)
    run.add_argument("--destination", required=True)
    run.add_argument("--output-dir", type=Path, required=True)
    run.add_argument("--manifest-revision")
    source = run.add_mutually_exclusive_group(required=True)
    source.add_argument("--archive-dir", type=Path)
    source.add_argument("--xctestrun", type=Path)
    run.add_argument("--selection-path", type=Path)
    run.add_argument("--relocated-path", type=Path)
    run.add_argument("--timeout-minutes", type=float, default=65)
    run.add_argument("--total-timeout-minutes", type=float, default=85)
    run.add_argument("--result-export-timeout-seconds", type=float, default=60)
    run.add_argument("--min-free-gib", type=int, default=80)
    local = commands.add_parser("reproduce")
    local.add_argument("--manifest-revision", required=True)
    local.add_argument("--shard", required=True)
    local.add_argument("--destination", required=True)
    local.add_argument("--output-dir", type=Path, required=True)
    local.add_argument("--toolchain-profile", choices=("pr", "nightly"), default="pr")
    simulator = commands.add_parser("simulator")
    simulator.add_argument("--shard", required=True)
    upload = commands.add_parser("check-upload")
    upload.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if hasattr(args, "timeout_minutes"):
            require(math.isfinite(args.timeout_minutes) and args.timeout_minutes > 0, "timeout must be finite and positive")
        if getattr(args, "manifest_revision", None):
            require(not args.manifest_revision.startswith("-") and ":" not in args.manifest_revision, "invalid manifest revision")
        if args.command == "wait-archive":
            return wait_archive(args)
        if args.command == "simulator":
            require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
                    "automatic simulator creation is hosted-only")
            from setup_ci_python import load_pins
            pins = load_pins(ROOT / "scripts/ci-pins.json", tier="pr")
            udid = subprocess.check_output(["xcrun", "simctl", "create", "ui-iphone-" + args.shard,
                    pins["device_types"]["iphone"], pins["simulators"]["ios"]["runtime"]], text=True, timeout=60).strip()
            with open(os.environ["GITHUB_ENV"], "a") as handle:
                handle.write(f"UI_SIMULATOR={udid}\nUI_DESTINATION=platform=iOS Simulator,id={udid}\n")
            return 0
        if args.command == "check-upload":
            from run_strict_e2e import write_sensitive_scan
            from strict_e2e_server import PUBLIC_API_KEY
            parse_summary((args.output_dir / "summary.json").read_text())
            write_sensitive_scan(args.output_dir, [PUBLIC_API_KEY])
            output("has_screenshots", str(any(path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg"}
                    for path in (args.output_dir / "failure-screenshots").rglob("*"))).lower())
            return 0
        if args.command == "reproduce":
            return reproduce(args)
        require(not args.archive_dir or (args.selection_path and args.relocated_path), "archive shards need selection and relocation paths")
        return run_shard(args)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        if args.command == "run":
            failed_shard(args, error)
        print(f"UI producer refused: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
