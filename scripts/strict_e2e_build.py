"""Shard-local warm builds, with immutable Products and per-invocation test inputs."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import subprocess
import time
from pathlib import Path

from ci_build_archive import file_hash, inventory, measure_signing, workspace_preflight
from strict_e2e_runner_support import CommandError, PLATFORM_SETTINGS, SETTINGS_RESUME_SUITES, _is_forbidden_key

RECEIPT = "strict-warm-build.json"


def build_settings(platform, suite, configuration=None):
    scheme, plan, _ = PLATFORM_SETTINGS[platform]
    if suite in SETTINGS_RESUME_SUITES:
        scheme += "-settings-resume"
        if configuration not in (None, "Release"):
            raise CommandError("Settings-resume suites require Release.")
        configuration = "Release"
    return scheme, plan, configuration or "Debug"


def source_fingerprint(root):
    # Includes intended uncommitted source without following ignored private configuration.
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root,
    ).split(b"\0")
    digest = hashlib.sha256()
    for name in sorted(set(names) - {b""}):
        path = root / os.fsdecode(name)
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        digest.update(name + b"\0")
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(file_hash(path).encode())
        else:
            digest.update(b"deleted")
    return digest.hexdigest()


def shard_identity(root, platform, suite, configuration, destination):
    scheme, plan, configuration = build_settings(platform, suite, configuration)
    developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    developer = os.environ.get("DEVELOPER_DIR", developer)
    return {
        "source_sha256": source_fingerprint(root), "scheme": scheme, "test_plan": plan,
        "configuration": configuration, "destination": destination,
        "xcode_version_sha256": file_hash(Path(developer).parent / "version.plist"),
    }


def validate_paths(root, derived, evidence, packages):
    derived, evidence, packages = derived.resolve(), evidence.resolve(), packages.resolve()
    for left, right in ((derived, evidence), (packages, evidence), (derived, packages)):
        if left == right or left in right.parents or right in left.parents:
            raise CommandError("DerivedData, cloned packages and evidence must be separate directories.")
    if root.resolve() == evidence or root.resolve() in evidence.parents:
        raise CommandError("Warm evidence must be outside the source checkout.")


def write_json(path, payload):
    path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def warm_up(*, root, platform, suite, configuration, destination, derived, packages,
            evidence, timeout, execute):
    workspace_preflight(root)
    validate_paths(root, derived, evidence, packages)
    if os.path.lexists(derived):
        raise CommandError("Warm-up requires fresh shard DerivedData; refusing to overwrite.")
    identity = shard_identity(root, platform, suite, configuration, destination)
    command = [
        "xcodebuild", "build-for-testing", "-project", str(root / "immichSlides.xcodeproj"),
        "-scheme", identity["scheme"], "-testPlan", identity["test_plan"],
        "-configuration", identity["configuration"], "-destination", destination,
        "-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", str(packages),
        "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
        "-parallel-testing-enabled", "NO", "-only-testing:immichSlidesUITests",
    ]
    environment = {key: value for key, value in os.environ.items()
                   if not _is_forbidden_key(key) and "STRICT_E2E_" not in key}
    started = time.monotonic()
    code = execute(command, cwd=root, environment=environment,
                   log_path=evidence / "warm-up.log", timeout_seconds=timeout)
    if code:
        raise CommandError(f"Shard warm-up failed with exit {code}.", code=code)
    workspace_preflight(root)
    if shard_identity(root, platform, suite, configuration, destination) != identity:
        raise CommandError("Source or toolchain changed during warm-up.")
    products = derived / "Build/Products"
    runs = list(products.glob("*.xctestrun"))
    if len(runs) != 1:
        raise CommandError("Warm-up must produce exactly one xctestrun.")
    apps = list(products.glob(f"{identity['configuration']}-*simulator/immichSlides.app"))
    if len(apps) != 1:
        raise CommandError("Warm-up app is missing or ambiguous.")
    # Use the archive signing inspection, retaining default Sign to Run Locally.
    signature = measure_signing(apps[0])
    for app_plist in apps[0].rglob("Info.plist"):
        values = plistlib.loads(app_plist.read_bytes())
        if any(values.get(key, "") != "" for key in ("IMMICH_SERVER_URL", "IMMICH_API_KEY")):
            raise CommandError("Warm-up app contains server configuration.")
    receipt = {"schema_version": 1, "identity": identity, "signing_mode": signature,
               "xctestrun": runs[0].name, "products": inventory(products),
               "duration_seconds": time.monotonic() - started, "timeout_seconds": timeout}
    write_json(derived / RECEIPT, receipt)
    write_json(evidence / "warm-up.json", {key: value for key, value in receipt.items() if key != "products"})
    return receipt


def validate_warm_products(derived, receipt):
    if inventory(derived / "Build/Products") != receipt["products"]:
        raise CommandError("Warm Products changed; refusing stale or rebuilt test input.")


def load_warm_build(root, platform, suite, configuration, destination, derived):
    workspace_preflight(root)
    try:
        receipt = json.loads((derived / RECEIPT).read_text())
        if receipt["schema_version"] != 1 or receipt["identity"] != shard_identity(root, platform, suite, configuration, destination):
            raise CommandError("Warm build does not match source, toolchain, scheme, configuration or device.")
        validate_warm_products(derived, receipt)
        run = derived / "Build/Products" / receipt["xctestrun"]
        if run.parent != derived / "Build/Products" or not run.is_file():
            raise CommandError("Warm xctestrun is missing or invalid.")
        return receipt, run
    except (OSError, KeyError, ValueError) as error:
        raise CommandError("Warm build receipt is missing or invalid; run an explicit warm-up.") from error


def prepare_test_run(source, directory, environment):
    # xctestrun resolves __TESTROOT__ against its own parent. Absolutize it before
    # writing the per-case copy outside immutable Products.
    directory.mkdir(parents=True, exist_ok=True)
    payload = plistlib.loads(source.read_bytes())

    def relocate(value):
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(source.parent))
        if isinstance(value, list):
            return [relocate(item) for item in value]
        if isinstance(value, dict):
            return {key: relocate(item) for key, item in value.items()}
        return value

    payload = relocate(payload)
    targets = [target for configuration in payload.get("TestConfigurations", [])
               for target in configuration.get("TestTargets", [])]
    if not targets:
        targets = [value for key, value in payload.items()
                   if key != "__xctestrun_metadata__" and isinstance(value, dict)]
    selected = [target for target in targets if target.get("BlueprintName") == "immichSlidesUITests"]
    if len(selected) != 1:
        raise CommandError("Warm test run must contain one UI target.")
    for target in targets:
        for field in ("EnvironmentVariables", "UITargetAppEnvironmentVariables", "TestingEnvironmentVariables"):
            target[field] = {key: value for key, value in target.get(field, {}).items()
                             if not _is_forbidden_key(key) and "STRICT_E2E_" not in key}
    selected[0]["EnvironmentVariables"].update(
        {key: value for key, value in environment.items() if key.startswith("STRICT_E2E_")}
    )
    path = directory / "case.xctestrun"
    path.write_bytes(plistlib.dumps(payload))
    return path


def warm_test_command(run, destination, bundle, selector):
    return ["xcodebuild", "test-without-building", "-xctestrun", str(run),
            "-destination", destination, "-resultBundlePath", str(bundle),
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            f"-only-testing:{selector}"]
