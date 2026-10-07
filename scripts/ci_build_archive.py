#!/usr/bin/env python3
"""Produce and consume identity-bound, secret-free simulator test archives."""
from __future__ import annotations

import argparse
from collections import deque
import hashlib
import json
import os
import platform as host_platform
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path, PurePosixPath

from ci_summary import (ContractError, decode, fields, integer, observation, parse_identity,
                        require, sha, test_identity, write_summary)
from run_host_checks import run_identity, source_metadata, toolchain
from run_offline_unit_tests import (CommandError, classify_test_results, default_data_available_gib,
                                    default_run, ensure_disk_for_xcodebuild, read_official_test_results_summary)

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ".github/workflows/ci-gate.yml"
SCHEMES = {"ios": "immichSlides-iOS", "tvos": "immichSlides-tvOS"}
DESTINATIONS = {"ios": "iOS Simulator", "tvos": "tvOS Simulator"}
PROOF_SELECTORS = [
    "immichSlidesTests/ImmichAssetMetadataDecoderTests/`" + name + "`()" for name in (
        "complete metadata decodes asset dimensions, EXIF dimensions, orientation, and person face boxes",
        "old JSON missing metadata keeps the new fields nil",
        "nil, zero, unknown fields, and numeric orientation decode safely",
        "a person missing the faces field keeps faces nil",
    )
] + ["immichSlidesTests/SlideShowViewModelVisibleSceneIdentityTests/"
     "`pause hold after visible A2 and completed A3 keeps decoded size, view model ids, and overlay model on A2`()"]
MANIFEST_FIELDS = {"schema_version", "identity", "producer", "platform", "configuration", "architectures",
                   "xcode_build", "pins_sha256", "signing_mode", "private_configuration_present",
                   "source_path", "products_path", "archive_sha256", "files"}
RERUN_ADVICE = "use Re-run all jobs"


class WorkspacePreflightError(ContractError):
    pass


class ArchiveUnavailableError(ContractError):
    pass


def workspace_preflight(root):
    # lexists/lstat deliberately reject dangling links without opening private content.
    if os.path.lexists(root / "Config/env.xcconfig"):
        raise WorkspacePreflightError("private configuration is forbidden at build time")
    if any(key.startswith(("IMMICH", "TEST_RUNNER_IMMICH", "SIMCTL_CHILD_IMMICH", "ENABLE_DEBUG_")) for key in os.environ):
        raise WorkspacePreflightError("ambient server/debug configuration is forbidden")


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_path(name):
    require(isinstance(name, str) and name and "\\" not in name, "invalid archive path")
    path = PurePosixPath(name)
    require(not path.is_absolute() and str(path) == name and all(part not in {".", ".."} for part in path.parts),
            "archive path escapes Products")
    require(path.parts[0] == "Products", "archive must contain only Products")
    return path


def safe_link(name, target):
    require(isinstance(target, str) and target and not target.startswith("/") and "\\" not in target and "\x00" not in target,
            "archive symlink escapes Products")


def validate_links(entries):
    by_path = {entry["path"]: entry for entry in entries}
    require(len(by_path) == len(entries), "duplicate file entry")
    require(by_path.get("Products", {}).get("kind") == "directory", "missing Products root")
    for entry in entries:
        path = safe_path(entry["path"])
        for parent in path.parents:
            if str(parent) != ".":
                require(by_path.get(str(parent), {}).get("kind") == "directory", "archive parent is not a directory")
        if entry["kind"] == "symlink":
            safe_link(entry["path"], entry["target"])
    for entry in entries:
        if entry["kind"] != "symlink":
            continue
        resolved = list(PurePosixPath(entry["path"]).parent.parts)
        active = {entry["path"]}
        pending = deque([*entry["target"].split("/"), (entry["path"],)])
        # Expand links before processing '..'; end markers allow finite repeated links.
        while pending:
            component = pending.popleft()
            if isinstance(component, tuple):
                active.remove(component[0])
                continue
            if component in {"", "."}:
                continue
            require(by_path.get("/".join(resolved), {}).get("kind") == "directory",
                    "archive symlink target parent is not a directory")
            if component == "..":
                require(len(resolved) > 1, "archive symlink escapes Products")
                resolved.pop()
                continue
            name = "/".join([*resolved, component])
            target = by_path.get(name)
            require(target is not None, "archive symlink target is not in the file list")
            if target["kind"] == "symlink":
                require(name not in active, "archive symlink loop")
                active.add(name)
                pending.extendleft(reversed([*target["target"].split("/"), (name,)]))
            else:
                resolved.append(component)


def inventory(products):
    require(products.is_dir() and not products.is_symlink(), "Products must be a regular directory")
    entries = []
    for path in [products, *sorted(products.rglob("*"))]:
        name = "Products" if path == products else "Products/" + path.relative_to(products).as_posix()
        metadata = path.lstat()
        entry = {"path": name, "mode": stat.S_IMODE(metadata.st_mode)}
        require(entry["mode"] & 0o7000 == 0, "special permission bits are forbidden")
        if path.is_symlink():
            entry.update(kind="symlink", target=os.readlink(path))
        elif path.is_file():
            entry.update(kind="file", sha256=file_hash(path), size=metadata.st_size)
        elif path.is_dir():
            entry.update(kind="directory")
        else:
            raise ContractError("unsupported archive entry")
        entries.append(entry)
    validate_links(entries)
    return entries


def check_products(products):
    apps = list(products.glob("Debug-*simulator/immichSlides.app/Info.plist"))
    # Also support synthetic product names in contract tests; nested frameworks are inspected separately.
    if not apps:
        apps = list(products.glob("Debug-*simulator/*.app/Info.plist"))
    require(bool(apps), "archive has no app Info.plist")
    for path in products.rglob("*.plist"):
        require(not path.is_symlink(), "plist symlinks are unsupported")
        values = plistlib.loads(path.read_bytes())
        require(isinstance(values, dict), "product plist must be a dictionary")
        for key in ("IMMICH_SERVER_URL", "IMMICH_API_KEY"):
            if path in apps or key in values:
                require(values.get(key) == "", "product contains nonempty server configuration")
        for key, value in values.items():
            if key.startswith("ENABLE_DEBUG_"):
                require(value in ("", "0", 0, False), "product has an enabled or unresolved debug flag")
    require(len(list(products.glob("*.xctestrun"))) == 1, "archive must have exactly one xctestrun")


def artifact_name(platform, run_id, attempt):
    return f"build-{platform}-{run_id}-{attempt}"


def measure_signing(app):
    display = subprocess.run(["codesign", "-dv", "--verbose=2", str(app)],
                             capture_output=True, text=True, timeout=120)
    require(display.returncode == 0, "built app is unsigned or its signature cannot be inspected")
    signatures = [line.partition("=")[2] for line in (display.stdout + display.stderr).splitlines()
                  if line.startswith("Signature=")]
    require(signatures == ["adhoc"], "built app must have Signature=adhoc")
    return signatures[0]


def record_signing(summary, signature):
    require(signature == "adhoc", "built app must have Signature=adhoc")
    summary["toolchain"]["versions"]["codesign_signature"] = signature
    # Keep the canonical summary enum, deriving it only from the measured signature.
    summary["toolchain"]["signing_mode"] = "sign-to-run-locally"


def make_manifest(products, *, identity, run_id, attempt, platform, architecture, xcode_build,
                  source_path, archive_sha, pins_sha, signing_mode):
    return {"schema_version": 1, "identity": parse_identity(identity),
            "producer": {"run_id": run_id, "attempt": attempt, "workflow_path": WORKFLOW,
                         "artifact_name": artifact_name(platform, run_id, attempt)},
            "platform": platform, "configuration": "Debug", "architectures": architecture,
            "xcode_build": xcode_build, "pins_sha256": pins_sha, "signing_mode": signing_mode,
            "private_configuration_present": False, "source_path": str(source_path.resolve()),
            "products_path": str(products.resolve()),
            "archive_sha256": archive_sha, "files": inventory(products)}


def validate_manifest(manifest, expected_identity, run_id, attempt, platform, xcode_build, pins_sha):
    fields(manifest, MANIFEST_FIELDS, "build manifest")
    require(type(manifest["schema_version"]) is int and manifest["schema_version"] == 1,
            "unsupported build manifest version")
    require(parse_identity(manifest["identity"]) == parse_identity(expected_identity), "build identity mismatch")
    require(manifest["producer"] == {"run_id": run_id, "attempt": attempt, "workflow_path": WORKFLOW,
                                     "artifact_name": artifact_name(platform, run_id, attempt)},
            "producer run or attempt mismatch")
    integer(manifest["producer"]["attempt"], 1, "producer attempt")
    require(manifest["platform"] == platform and manifest["configuration"] == "Debug", "build platform mismatch")
    require(manifest["xcode_build"] == xcode_build and manifest["pins_sha256"] == pins_sha,
            "build toolchain/pins mismatch")
    require(manifest["signing_mode"] == "adhoc" and manifest["private_configuration_present"] is False,
            "archive was not built secret-free with local simulator signing")
    require(isinstance(manifest["architectures"], list) and bool(manifest["architectures"])
            and all(arch in {"arm64", "x86_64"} for arch in manifest["architectures"])
            and len(set(manifest["architectures"])) == len(manifest["architectures"])
            and host_platform.machine() in manifest["architectures"],
            "archive architecture mismatch")
    require(isinstance(manifest["source_path"], str) and Path(manifest["source_path"]).is_absolute(),
            "missing absolute build source path")
    require(isinstance(manifest["products_path"], str) and Path(manifest["products_path"]).is_absolute(),
            "missing absolute build Products path")
    sha(manifest["archive_sha256"], 64)
    sha(manifest["pins_sha256"], 64)
    entries = manifest["files"]
    require(isinstance(entries, list) and bool(entries), "missing file manifest")
    names = set()
    for entry in entries:
        require(isinstance(entry, dict), "invalid file entry")
        kind = entry.get("kind")
        extra = {"sha256", "size"} if kind == "file" else {"target"} if kind == "symlink" else set()
        require(kind in {"file", "directory", "symlink"}, "invalid entry kind")
        fields(entry, {"path", "kind", "mode"} | extra, "file entry")
        safe_path(entry["path"])
        require(entry["path"] not in names, "duplicate file entry")
        names.add(entry["path"])
        integer(entry["mode"], 0, "mode")
        require(entry["mode"] <= 0o777, "invalid file permission")
        if kind == "file":
            sha(entry["sha256"], 64)
            integer(entry["size"], 0, "size")
        elif kind == "symlink":
            safe_link(entry["path"], entry["target"])
    require(any(entry["path"] == "Products" and entry["kind"] == "directory" for entry in entries),
            "missing Products root")
    validate_links(entries)


def validate_artifact(metadata, identity, run_id, attempt, platform, artifact_id):
    integer(artifact_id, 1, "artifact ID")
    integer(attempt, 1, "producer attempt")
    if metadata.get("expired") is not False:
        raise ArchiveUnavailableError("artifact ID absent or expired")
    require(metadata.get("id") == artifact_id, "artifact ID mismatch")
    require(metadata.get("name") == artifact_name(platform, run_id, attempt), "artifact producer attempt mismatch")
    run = metadata.get("workflow_run", {})
    require(str(run.get("id")) == run_id, "artifact run mismatch")
    # The artifact API records a PR head; checkout/build identity records its merge.
    commit = identity.get("head_sha", identity.get("pushed_sha"))
    require(commit is not None and run.get("head_sha") == commit, "artifact commit mismatch")


def pack_products(products, path):
    inventory(products)
    with tarfile.open(path, "w:gz", dereference=False) as handle:
        handle.add(products, arcname="Products")


def extract_products(path, destination, manifest):
    validate_links(manifest["files"])
    require(file_hash(path) == manifest["archive_sha256"], "archive hash mismatch")
    require(not os.path.lexists(destination), "extraction path must be fresh")
    expected = {entry["path"]: entry for entry in manifest["files"]}
    with tarfile.open(path, "r:gz") as handle:
        members = handle.getmembers()
        require(len(members) == len(expected), "archive member count mismatch")
        seen = set()
        for member in members:
            safe_path(member.name)
            require(member.name in expected and member.name not in seen, "unlisted or duplicate archive member")
            seen.add(member.name)
            entry = expected[member.name]
            kind = "directory" if member.isdir() else "file" if member.isfile() else "symlink" if member.issym() else None
            require(kind == entry["kind"] and member.mode == entry["mode"], "archive type or mode mismatch")
            if member.issym():
                require(member.linkname == entry["target"], "archive symlink mismatch")
                safe_link(member.name, member.linkname)
            elif member.isfile():
                require(member.size == entry["size"], "archive size mismatch")
            for parent in PurePosixPath(member.name).parents:
                if str(parent) != ".":
                    require(expected.get(str(parent), {}).get("kind") == "directory", "archive parent is not a directory")
        destination.mkdir(parents=True)
        # All members, link chains and ancestors are checked; hard links/devices are forbidden.
        for member in sorted(members, key=lambda item: (not item.isdir(), len(PurePosixPath(item.name).parts))):
            handle.extract(member, destination, set_attrs=True)
    require(inventory(destination / "Products") == manifest["files"], "extracted file hashes or metadata mismatch")
    check_products(destination / "Products")


def disk_check(min_free_gib):
    if min_free_gib < 80:
        require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
                "only GitHub-hosted CI may use a disk threshold below the local 80 GiB default")
    subprocess.run(["df", "-h", "/System/Volumes/Data"], check=True)
    ensure_disk_for_xcodebuild(default_data_available_gib, min_free_gib)
    return default_data_available_gib()


def write_json(path, payload):
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def output(key, value):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"{key}={value}\n")


def context(*, require_clean=True):
    ci = os.environ.get("GITHUB_ACTIONS") == "true"
    identity = run_identity(os.environ, ci=ci)
    require(identity["event"] in {"pull_request", "push", "local"}, "ci-gate accepts only PR/main push identities")
    if require_clean:
        require(identity.get("dirty") is not True, "build archives require a clean committed tree")
    workflow, fork = source_metadata(identity, os.environ, WORKFLOW if ci else None)
    return {"identity": identity, "source": {"repository": identity["repository"], "event": identity["event"],
            "workflow_path": workflow, "fork_originated": fork, "ci_changing": None},
            "run_id": os.environ.get("GITHUB_RUN_ID") if ci else None,
            "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")) if ci else 1}


def record(context, platform, job):
    # Preflight/selection failures must be recorded without starting Xcode or setup.
    versions = {"versions": {"python": host_platform.python_version()}, "signing_mode": "not-applicable"}
    return {"schema_version": 1, "identity": context["identity"], "source": context["source"],
            "run": {"id": context["run_id"], "attempt": context["attempt"], "tier": "build", "job": job, "shard": platform},
            "hashes": {"manifests": {}, "policies": {"build-archive": file_hash(Path(__file__))}},
            "toolchain": versions, "population": {"declared": [], "compiled": [], "observed": [],
                                                    "deselected": [], "removed_by_pr": []},
            "infrastructure": [], "status": "unverified"}


def record_failure(summary, step, error, code, started, infrastructure_code):
    if isinstance(error, WorkspacePreflightError):
        infrastructure_code = "workspace-preflight-failed"
    elif isinstance(error, (ArchiveUnavailableError, FileNotFoundError)) or (
            isinstance(error, urllib.error.HTTPError) and error.code in {404, 410}):
        infrastructure_code = "archive-unavailable"
    elif isinstance(error, ContractError) and (infrastructure_code == "archive-selection-failed" or
                                             str(error) == "build identity mismatch"):
        infrastructure_code = "archive-identity-mismatch"
    message = str(error) if isinstance(error, (ContractError, CommandError)) else type(error).__name__
    message += "; " + RERUN_ADVICE
    summary["status"] = "failed"
    summary["infrastructure"] = [{"code": infrastructure_code, "message": message}]
    summary["population"]["observed"] = [observation(step, "timed-out" if code == 124 else "failed",
                                                     time.monotonic() - started, exit_code=code)]
    print(message, file=sys.stderr)


def run_preflight(args):
    ctx = context(require_clean=False)
    summary = record(ctx, args.platform, "workspace-preflight")
    step = test_identity("host", "workspace preflight", **({"platform": args.platform} if args.platform else {}))
    summary["population"]["declared"] = [step]
    summary["population"]["compiled"] = [step]
    summary["population"]["observed"] = [observation(step, "not-run", 0, reason="workspace preflight has not completed", exit_code=None)]
    write_summary(summary, args.output_dir)
    started = time.monotonic()
    code = 1
    try:
        workspace_preflight(ROOT)
        summary["status"] = "passed"
        summary["population"]["observed"] = [observation(step, "passed", time.monotonic() - started)]
        print("Build workspace preflight PASS: no private configuration")
        code = 0
    except (OSError, ValueError) as error:
        record_failure(summary, step, error, code, started, "workspace-preflight-failed")
    finally:
        write_summary(summary, args.output_dir)
    return code


def checked_command(command, timeout=120):
    return subprocess.check_output(command, cwd=ROOT, text=True, stderr=subprocess.DEVNULL, timeout=timeout).strip()


def run_build(args):
    ctx = context()
    summary = record(ctx, args.platform, "build-" + args.platform)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    records = args.output_dir / "records"
    step = test_identity("host", "secret-free build archive", platform=args.platform, configuration="Debug")
    summary["population"]["declared"] = [step]
    summary["population"]["compiled"] = [step]
    summary["population"]["observed"] = [observation(step, "not-run", 0, reason="build has not completed", exit_code=None)]
    write_summary(summary, records)
    started = time.monotonic()
    code = 1
    try:
        workspace_preflight(ROOT)
        require(not os.path.lexists(args.derived_data_path), "DerivedData path must be fresh")
        pins_path = ROOT / "scripts/ci-pins.json"
        pins_sha = file_hash(pins_path)
        summary["hashes"]["manifests"]["ci-pins"] = pins_sha
        disk_before = disk_check(args.min_free_gib)
        summary["toolchain"] = toolchain()
        command = ["xcodebuild", "build-for-testing", "-project", str(ROOT / "immichSlides.xcodeproj"),
                   "-scheme", SCHEMES[args.platform], "-testPlan", SCHEMES[args.platform],
                   "-configuration", "Debug", "-destination", "generic/platform=" + DESTINATIONS[args.platform],
                   "-derivedDataPath", str(args.derived_data_path.resolve()),
                   "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile"]
        code = default_run(command, timeout_seconds=1800)
        require(code == 0, f"build-for-testing failed (exit {code})")
        workspace_preflight(ROOT)
        require(file_hash(pins_path) == pins_sha, "pins changed during build")
        require(checked_command(["git", "status", "--porcelain"]) == "", "build changed the checkout or package lock")
        products = args.derived_data_path / "Build/Products"
        check_products(products)
        binary = next(products.glob("Debug-*simulator/immichSlides.app/immichSlides"))
        signature = measure_signing(binary.parent)
        record_signing(summary, signature)
        print("Measured app signature: " + signature, flush=True)
        architectures = checked_command(["xcrun", "lipo", "-archs", str(binary)]).split()
        developer = Path(os.environ.get("DEVELOPER_DIR") or checked_command(["xcode-select", "-p"]))
        xcode_build = plistlib.loads((developer.parent / "version.plist").read_bytes())["ProductBuildVersion"]
        archive_dir = args.output_dir / "archive"
        archive_dir.mkdir()
        archive_path = archive_dir / "build.tar.gz"
        pack_products(products, archive_path)
        manifest = make_manifest(products, identity=ctx["identity"], run_id=ctx["run_id"] or "local", attempt=ctx["attempt"],
                                 platform=args.platform, architecture=architectures, xcode_build=xcode_build,
                                 source_path=ROOT, archive_sha=file_hash(archive_path), pins_sha=pins_sha, signing_mode=signature)
        write_json(archive_dir / "manifest.json", manifest)
        disk = {"before_gib": disk_before, "after_gib": default_data_available_gib(),
                "products_bytes": sum(entry.get("size", 0) for entry in manifest["files"]),
                "archive_bytes": archive_path.stat().st_size, "min_free_gib": args.min_free_gib}
        records.mkdir(exist_ok=True)
        write_json(records / "disk.json", disk)
        print("Build disk measurement: " + json.dumps(disk), flush=True)
        output("producer_attempt", ctx["attempt"])
        output("artifact_name", manifest["producer"]["artifact_name"])
        summary["hashes"]["manifests"]["build"] = file_hash(archive_dir / "manifest.json")
        summary["status"] = "passed"
        summary["population"]["observed"] = [observation(step, "passed", time.monotonic() - started)]
        code = 0
    except (OSError, ValueError, CommandError, subprocess.SubprocessError) as error:
        code = code or 1
        record_failure(summary, step, error, code, started, "build-archive-failed")
    finally:
        write_summary(summary, records)
    return code


def run_select(args):
    ctx = context(require_clean=False)
    summary = record(ctx, args.platform, "artifact-selection")
    step = test_identity("host", "artifact selection", platform=args.platform)
    summary["population"]["declared"] = [step]
    summary["population"]["compiled"] = [step]
    summary["population"]["observed"] = [observation(step, "not-run", 0, reason="artifact selection has not completed", exit_code=None)]
    write_summary(summary, args.output_dir)
    started = time.monotonic()
    code = 1
    try:
        workspace_preflight(ROOT)
        require(ctx["identity"].get("dirty") is not True, "build archives require a clean committed tree")
        require(ctx["run_id"] is not None, "artifact selection requires a CI run")
        require(args.producer_attempt <= ctx["attempt"], "producer attempt is in the future")
        repository = ctx["identity"]["repository"]
        request = urllib.request.Request(f"https://api.github.com/repos/{repository}/actions/artifacts/{args.artifact_id}",
                                         headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"],
                                                  "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(request, timeout=60) as response:
            metadata = json.load(response)
        validate_artifact(metadata, ctx["identity"], ctx["run_id"], args.producer_attempt, args.platform, args.artifact_id)
        ctx.update(artifact_id=args.artifact_id, producer_attempt=args.producer_attempt, platform=args.platform,
                   pins_sha256=file_hash(ROOT / "scripts/ci-pins.json"))
        write_json(args.selection_path, ctx)
        print(f"Selected artifact ID {args.artifact_id}, producer attempt {args.producer_attempt}, consumer attempt {ctx['attempt']}")
        summary["status"] = "passed"
        summary["population"]["observed"] = [observation(step, "passed", time.monotonic() - started)]
        code = 0
    except (OSError, ValueError, KeyError) as error:
        record_failure(summary, step, error, code, started, "archive-selection-failed")
    finally:
        write_summary(summary, args.output_dir)
    return code


def run_proof(args):
    ctx = decode(args.selection_path.read_text(encoding="utf-8"))
    summary = record(ctx, ctx["platform"], "archive-relocation")
    step = test_identity("host", "relocated fixture tests", platform=ctx["platform"], configuration="Debug")
    summary["population"]["declared"] = [step]
    summary["population"]["compiled"] = [step]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    summary["population"]["observed"] = [observation(step, "not-run", 0, reason="relocation has not completed", exit_code=None)]
    write_summary(summary, args.output_dir)
    started = time.monotonic()
    simulator = None
    code = 1
    try:
        require(not (ROOT / "immichSlides.xcodeproj").exists(), "consumer tooling must not contain a source checkout")
        manifest_path = args.archive_dir / "manifest.json"
        manifest = decode(manifest_path.read_text(encoding="utf-8"))
        pins_path = Path(__file__).with_name("ci-pins.json")
        pins = json.loads(pins_path.read_text(encoding="utf-8"))
        developer = Path(os.environ["DEVELOPER_DIR"])
        xcode_build = plistlib.loads((developer.parent / "version.plist").read_bytes())["ProductBuildVersion"]
        require(file_hash(pins_path) == ctx["pins_sha256"], "consumer pins changed after selection")
        validate_manifest(manifest, ctx["identity"], ctx["run_id"], ctx["producer_attempt"], ctx["platform"],
                          xcode_build, ctx["pins_sha256"])
        require(not os.path.lexists(manifest["source_path"]), "build-time source checkout is present on consumer")
        require(not Path(os.environ["GITHUB_WORKSPACE"]).joinpath("consumer-source").exists(), "consumer source checkout still present")
        require(str((args.relocated_path / "Products").resolve()) != manifest["products_path"], "relocation path is not distinct")
        require(not os.path.lexists(manifest["products_path"]), "build-time Products path is present on consumer")
        extract_products(args.archive_dir / "build.tar.gz", args.relocated_path, manifest)
        summary["hashes"]["manifests"] = {"ci-pins": ctx["pins_sha256"], "build": file_hash(manifest_path)}
        before = disk_check(args.min_free_gib)
        summary["toolchain"] = toolchain()
        app = next((args.relocated_path / "Products").glob("Debug-*simulator/immichSlides.app"))
        signature = measure_signing(app)
        require(signature == manifest["signing_mode"], "relocated app signing mode mismatch")
        record_signing(summary, signature)
        devices = json.loads(checked_command(["xcrun", "simctl", "list", "devicetypes", "--json"]))["devicetypes"]
        device_name = pins["device_types"]["iphone" if ctx["platform"] == "ios" else "appletv"]
        device = next(item["identifier"] for item in devices if item["name"] == device_name)
        simulator = checked_command(["xcrun", "simctl", "create", "immichSlides-archive-proof", device,
                                     pins["simulators"][ctx["platform"]]["runtime"]])
        xctestrun = next((args.relocated_path / "Products").glob("*.xctestrun"))
        result_path = args.output_dir / "private.xcresult"
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                   "-destination", f"platform={DESTINATIONS[ctx['platform']]},id={simulator}",
                   "-resultBundlePath", str(result_path), *["-only-testing:" + selector for selector in PROOF_SELECTORS]]
        disk_check(args.min_free_gib)
        code = default_run(command, timeout_seconds=900)
        require(code == 0, f"relocated tests failed (exit {code})")
        official = read_official_test_results_summary(result_path)
        tests = json.loads(checked_command(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result_path), "--compact"]))
        proof = {"artifact_id": ctx["artifact_id"], "producer_attempt": ctx["producer_attempt"],
                 "consumer_attempt": ctx["attempt"], "identity": ctx["identity"], "signing_mode": signature,
                 "build_source_absent": True, "relocated_path": str(args.relocated_path),
                 "selectors": PROOF_SELECTORS, "official_counts": official.__dict__, "official_tests": tests,
                 "disk_before_gib": before, "disk_after_gib": default_data_available_gib()}
        write_json(args.output_dir / "relocation-proof.json", proof)
        print("Official relocated counts: " + json.dumps(official.__dict__), flush=True)
        require(classify_test_results(official) == "passed" and official.total_test_count == len(PROOF_SELECTORS),
                "relocation proof requires all five fixture tests to pass without skips")
        print(f"Relocation PASS: artifact ID {ctx['artifact_id']}, producer attempt {ctx['producer_attempt']}, "
              f"consumer attempt {ctx['attempt']}; {official.total_test_count} tests passed, no skips, source absent")
        summary["status"] = "passed"
        summary["population"]["observed"] = [observation(step, "passed", time.monotonic() - started)]
        code = 0
    except (OSError, ValueError, CommandError, subprocess.SubprocessError) as error:
        code = code or 1
        record_failure(summary, step, error, code, started, "relocation-failed")
    finally:
        if simulator:
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["xcrun", "simctl", "delete", simulator], check=True)
        shutil.rmtree(args.output_dir / "private.xcresult", ignore_errors=True)
        write_summary(summary, args.output_dir)
    return code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preflight = commands.add_parser("preflight")
    preflight.add_argument("--platform", choices=SCHEMES)
    preflight.add_argument("--output-dir", type=Path, required=True)
    build = commands.add_parser("build")
    build.add_argument("--platform", choices=SCHEMES, required=True)
    build.add_argument("--output-dir", type=Path, required=True)
    build.add_argument("--derived-data-path", type=Path, required=True)
    build.add_argument("--min-free-gib", type=int, default=80)
    select = commands.add_parser("select")
    select.add_argument("--platform", choices=SCHEMES, required=True)
    select.add_argument("--artifact-id", type=int, required=True)
    select.add_argument("--producer-attempt", type=int, required=True)
    select.add_argument("--selection-path", type=Path, required=True)
    select.add_argument("--output-dir", type=Path, required=True)
    proof = commands.add_parser("proof")
    proof.add_argument("--selection-path", type=Path, required=True)
    proof.add_argument("--archive-dir", type=Path, required=True)
    proof.add_argument("--relocated-path", type=Path, required=True)
    proof.add_argument("--output-dir", type=Path, required=True)
    proof.add_argument("--min-free-gib", type=int, default=80)
    args = parser.parse_args(argv)
    try:
        if hasattr(args, "min_free_gib"):
            require(args.min_free_gib >= 0, "disk threshold must be nonnegative")
        for name in ("output_dir", "derived_data_path", "selection_path", "archive_dir", "relocated_path"):
            if hasattr(args, name):
                path = getattr(args, name).resolve()
                require(path != ROOT and ROOT not in path.parents, "archive outputs must be outside the source checkout")
                setattr(args, name, path)
        return {"preflight": run_preflight, "build": run_build, "select": run_select, "proof": run_proof}[args.command](args)
    except (OSError, ValueError, CommandError, subprocess.SubprocessError) as error:
        print(f"Build archive FAIL: {error if isinstance(error, (ContractError, CommandError)) else type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
