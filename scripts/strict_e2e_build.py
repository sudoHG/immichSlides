"""Shard-local warm builds, with immutable Products and per-invocation test inputs."""

from __future__ import annotations

import hashlib
import json
import os
import platform as host_platform
import plistlib
import subprocess
import time
from pathlib import Path

from ci_build_archive import check_products, file_hash, inventory, measure_signing, pack_products, workspace_preflight
from ci_summary import require, sha
from strict_e2e_runner_support import CommandError, PLATFORM_SETTINGS, SETTINGS_RESUME_SUITES, _is_forbidden_key

RECEIPT = "strict-warm-build.json"
SMOKE_RECEIPT = "strict-smoke-archive.json"
SMOKE_ARCHIVE_VERSION = 2
SMOKE_SOURCE_PLIST_PREFLIGHT_VERSION = 1
SMOKE_BUILD_DESTINATION = "generic/platform=iOS Simulator"


def smoke_source_identity(root):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root, text=True, timeout=30).strip()
    require(git("status", "--porcelain") == "", "smoke archive requires a clean tested checkout")
    return {"head_sha": git("rev-parse", "HEAD"), "tree_sha": git("rev-parse", "HEAD^{tree}"),
            "source_sha256": source_fingerprint(root), "clean": True}


def smoke_build_identity(root, configuration):
    require(configuration in {"Debug", "Release"}, "smoke archive configuration differs")
    def read(*args):
        return subprocess.check_output(list(args), text=True, timeout=60).strip()
    developer = Path(os.environ.get("DEVELOPER_DIR") or read("xcode-select", "-p"))
    version = developer.parent / "version.plist"
    pins = json.loads((root / "scripts/ci-pins.json").read_text())
    xcode_build = plistlib.loads(version.read_bytes())["ProductBuildVersion"]
    require(xcode_build == pins["xcode"]["build"], "smoke archive requires the pinned Xcode")
    return {"source": smoke_source_identity(root), "platform": "ios",
            "scheme": "immichSlides-iOS-settings-resume", "test_plan": "StrictE2E-iOS",
            "configuration": configuration, "destination": SMOKE_BUILD_DESTINATION,
            "toolchain": {"xcode_version_sha256": file_hash(version), "xcode_build": xcode_build,
                          "pins_sha256": file_hash(root / "scripts/ci-pins.json"),
                          "sdk_version": read("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"),
                          "sdk_build": read("xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"),
                          "package_lock_sha256": file_hash(root / "immichSlides.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")}}


def smoke_execution_identity(root, destination, device):
    require(destination.startswith("platform=iOS Simulator,id=") and destination.count(",") == 1,
            "smoke archive requires a concrete iOS Simulator destination")
    udid = destination.partition(",id=")[2]
    def listing(name):
        return json.loads(subprocess.check_output(["xcrun", "simctl", "list", name, "--json"], text=True, timeout=60))
    devices, runtimes, types = listing("devices"), listing("runtimes"), listing("devicetypes")
    matches = [(runtime, item) for runtime, items in devices["devices"].items() for item in items
               if item.get("udid") == udid and item.get("isAvailable") is True]
    require(len(matches) == 1, "smoke archive execution device is unavailable")
    runtime_id, item = matches[0]
    runtime = [value for value in runtimes["runtimes"] if value["identifier"] == runtime_id and value.get("isAvailable") is True]
    device_types = [value for value in types["devicetypes"] if value["identifier"] == item.get("deviceTypeIdentifier")]
    require(len(runtime) == len(device_types) == 1, "smoke archive execution runtime or device type is unavailable")
    return {"platform": "iOS Simulator", "udid": udid, "device": device, "device_type": device_types[0]["name"],
            "runtime": {"runtime": runtime_id, "version": runtime[0]["version"], "build": runtime[0]["buildversion"]},
            "architecture": host_platform.machine()}


def validate_smoke_compatibility(identity, architectures, execution, pins):
    require(identity.get("destination") == SMOKE_BUILD_DESTINATION and identity.get("platform") == "ios"
            and identity.get("scheme") == "immichSlides-iOS-settings-resume"
            and identity.get("test_plan") == "StrictE2E-iOS", "smoke archive generic build semantics differ")
    device = execution.get("device")
    require(device in {"iphone", "ipad"} and execution.get("platform") == "iOS Simulator"
            and execution.get("device_type") == pins["device_types"].get(device)
            and execution.get("runtime") == pins["simulators"]["ios"] and bool(execution.get("udid")),
            "smoke archive is incompatible with the pinned execution target")
    require(isinstance(architectures, list) and architectures and len(architectures) == len(set(architectures))
            and set(architectures) <= {"arm64", "x86_64"} and execution.get("architecture") in architectures,
            "smoke archive execution architecture is absent")


def validate_smoke_receipt(receipt, expected_identity, control):
    require(set(receipt) == {"schema_version", "kind", "identity", "control", "architectures", "signing_mode",
                             "private_configuration_present", "xctestrun", "products", "archive_sha256", "source_root"},
            "smoke archive receipt fields differ")
    require(type(receipt["schema_version"]) is int and receipt["schema_version"] == 2
            and receipt["kind"] == "smoke-archive", "smoke archive receipt version differs")
    require(receipt["identity"] == expected_identity, "smoke archive tested source or build identity differs")
    require(receipt["control"] == control, "smoke archive control provenance differs")
    require(receipt["signing_mode"] == "adhoc" and receipt["private_configuration_present"] is False,
            "smoke archive signing or private configuration differs")
    sha(receipt["archive_sha256"], 64)
    require(isinstance(receipt["source_root"], str) and Path(receipt["source_root"]).is_absolute(),
            "smoke archive compilation root differs")
    name = receipt["xctestrun"]
    require(isinstance(name, str) and Path(name).name == name and name.endswith(".xctestrun"),
            "smoke archive xctestrun differs")
    from ci_build_archive import validate_links
    validate_links(receipt["products"])


def check_smoke_source_plist(root):
    path = root / "immichSlides/Info.plist"
    require(path.is_file() and not path.is_symlink(), "source app plist must be a regular file")
    values = plistlib.loads(path.read_bytes())
    require(isinstance(values, dict) and all(values.get(key) == "$(" + key + ")"
            for key in ("IMMICH_SERVER_URL", "IMMICH_API_KEY")), "source app plist server fields differ")


def build_smoke_archive(*, root, configuration, control, derived, packages, output, execute, timeout=1200):
    """A distinct envelope; never broaden the schema-1 exact-destination reader."""
    workspace_preflight(root)
    check_smoke_source_plist(root)
    require(not output.exists(), "smoke archive output must be fresh")
    output.mkdir(parents=True)
    identity = smoke_build_identity(root, configuration)
    started = time.monotonic()
    warm = warm_up(root=root, platform="ios", suite="smoke-flow", configuration=configuration,
                   destination=SMOKE_BUILD_DESTINATION, derived=derived, packages=packages,
                   evidence=output, timeout=timeout, execute=execute)
    build_seconds = time.monotonic() - started
    workspace_preflight(root)
    check_smoke_source_plist(root)
    require(smoke_build_identity(root, configuration) == identity, "smoke build changed source, lock or toolchain")
    products = derived / "Build/Products"
    check_products(products, configuration=configuration)
    binary = products / f"{configuration}-iphonesimulator/immichSlides.app/immichSlides"
    architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True, timeout=60).split()
    archive = output / "archive"
    archive.mkdir()
    started = time.monotonic()
    pack_products(products, archive / "build.tar.gz")
    receipt = {"schema_version": 2, "kind": "smoke-archive", "identity": identity, "control": control,
               "architectures": architectures, "signing_mode": warm["signing_mode"],
               "private_configuration_present": False, "xctestrun": warm["xctestrun"],
               "products": inventory(products), "archive_sha256": file_hash(archive / "build.tar.gz"),
               "source_root": str(root.resolve())}
    validate_smoke_receipt(receipt, identity, control)
    write_json(archive / "manifest.json", receipt)
    return receipt, {"build_seconds": build_seconds, "pack_seconds": time.monotonic() - started,
                     "manifest_sha256": file_hash(archive / "manifest.json"),
                     "archive_sha256": receipt["archive_sha256"], "archive_bytes": (archive / "build.tar.gz").stat().st_size}


def load_smoke_archive(root, configuration, destination, device, derived):
    workspace_preflight(root)
    receipt = json.loads((derived / SMOKE_RECEIPT).read_text())
    identity = smoke_build_identity(root, configuration)
    validate_smoke_receipt(receipt, identity, receipt["control"])
    execution = smoke_execution_identity(root, destination, device)
    validate_smoke_compatibility(identity, receipt["architectures"], execution,
                                 json.loads((root / "scripts/ci-pins.json").read_text()))
    validate_warm_products(derived, receipt)
    products = derived / "Build/Products"
    check_products(products, configuration=configuration)
    require(measure_signing(products / f"{configuration}-iphonesimulator/immichSlides.app") == "adhoc",
            "smoke archive signature differs")
    run = products / receipt["xctestrun"]
    require(run.is_file() and not run.is_symlink(), "smoke archive xctestrun is unavailable")
    return receipt, run, execution


def build_settings(platform, suite, configuration=None):
    scheme, plan, _ = PLATFORM_SETTINGS[platform]
    if suite == "smoke-flow":
        # The UI-only scheme avoids compiling @testable unit targets against a Release app.
        scheme += "-settings-resume"
    elif suite in SETTINGS_RESUME_SUITES:
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
    if suite == "smoke-flow":
        # Reused local builds can outlive their isolated compilation checkout.
        receipt["source_root"] = str(root.resolve())
    write_json(derived / RECEIPT, receipt)
    write_json(evidence / "warm-up.json", {key: value for key, value in receipt.items()
                                         if key not in {"products", "source_root"}})
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
