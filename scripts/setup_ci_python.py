#!/usr/bin/env python3
"""Create or verify an isolated Python environment using the versioned CI pins."""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path


PINS_PATH = Path(__file__).resolve().with_name("ci-pins.json")


def run(command, *, env=None, timeout=120):
    completed = subprocess.run(command, check=True, capture_output=True, text=True, env=env, timeout=timeout)
    return completed.stdout.strip()


def load_pins(path=PINS_PATH, *, tier=None):
    pins = json.loads(path.read_text(encoding="utf-8"))
    selected_tier = tier or os.environ.get("CI_TOOLCHAIN_TIER", "pr")
    if selected_tier not in {"pr", "nightly", "release"}:
        raise ValueError("Unknown CI toolchain tier")
    if pins.get("schema_version") == 2:
        if set(pins["tiers"]) != {"pr", "nightly", "release"}:
            raise ValueError("Expected complete CI toolchain tier mappings")
        name = pins["tiers"][selected_tier]
        if not isinstance(name, str) or name not in pins["profiles"]:
            raise ValueError("Unknown CI toolchain profile")
        profile = pins["profiles"][name]
        if set(profile) != {"runner", "xcode", "simulators", "device_types"}:
            raise ValueError("Expected complete CI toolchain profile")
        if profile["runner"] not in {"macos-26", "xcode-27"}:
            raise ValueError("Unreviewed CI runner label")
        pins = {"schema_version": 2, **{key: pins[key] for key in ("python", "python_packages", "zstd")},
                **profile, "tier": selected_tier, "profile": name}
    elif pins.get("schema_version") != 1:
        raise ValueError("Unsupported CI pins schema")
    versions = [pins["python"], pins["zstd"]]
    if not all(isinstance(value, str) and re.fullmatch(r"\d+\.\d+\.\d+", value) for value in versions):
        raise ValueError("Python and zstd pins must be exact three-part versions")
    if not all(isinstance(value, str) and re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value)
               for value in pins["python_packages"].values()):
        raise ValueError("Python package pins must be exact release versions")
    if set(pins["python_packages"]) != {"pip", "Pillow", "PyYAML"}:
        raise ValueError("Expected the complete Python dependency pins")
    return pins


def verify_python(executable, expected):
    observed = run([executable, "-I", "-c", "import platform; print(platform.python_version())"])
    if observed != expected:
        raise ValueError(f"Python pin mismatch: expected {expected}, observed {observed}")
    print(f"Python {observed}")


def verify_zstd(expected):
    output = run(["zstd", "--version"])
    match = re.search(r"\bv(\d+\.\d+\.\d+)\b", output)
    if match is None or match[1] != expected:
        raise ValueError(f"zstd pin mismatch: expected {expected}")
    print(f"zstd {match[1]}")


def verify_environment(executable, pins):
    verify_python(executable, pins["python"])
    observed = json.loads(run([executable, "-I", "-c",
        "import importlib.metadata,json; print(json.dumps({name: importlib.metadata.version(name) "
        "for name in ['pip','Pillow','PyYAML']}))"]))
    if observed != pins["python_packages"]:
        raise ValueError(f"Python package pin mismatch: expected {pins['python_packages']}, observed {observed}")
    print("Python packages: " + json.dumps(observed, sort_keys=True))
    run([executable, "-I", "-m", "pip", "--isolated", "check"])


def verify_toolchain(pins):
    # This is an inventory check only: it never builds, boots or installs a simulator.
    environment = dict(os.environ, DEVELOPER_DIR=pins["xcode"]["developer_dir"])
    version_path = Path(pins["xcode"]["developer_dir"]).parent / "version.plist"
    metadata = plistlib.loads(version_path.read_bytes())
    observed = (metadata["CFBundleShortVersionString"], metadata["ProductBuildVersion"])
    expected = (pins["xcode"]["version"], pins["xcode"]["build"])
    if observed != expected:
        raise ValueError(f"Xcode pin mismatch: expected {expected!r}, observed {observed!r}")
    print(f"Xcode {observed[0]}\nBuild version {observed[1]}")
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "--json"], env=environment))["runtimes"]
    for platform, pin in pins["simulators"].items():
        matches = [runtime for runtime in runtimes if runtime["identifier"] == pin["runtime"]
                   and runtime.get("isAvailable") and runtime["version"] == pin["version"]
                   and runtime["buildversion"] == pin["build"]]
        if len(matches) != 1:
            raise ValueError(f"Missing or mismatched {platform} runtime pin: {pin}")
        print(f"{platform} runtime: {pin['runtime']} {pin['version']} ({pin['build']})")
    devices = json.loads(run(["xcrun", "simctl", "list", "devicetypes", "--json"], env=environment))["devicetypes"]
    names = {device["name"] for device in devices}
    for device in pins["device_types"].values():
        if device not in names:
            raise ValueError(f"Missing simulator device type: {device}")
        print(f"Device type: {device}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--venv", required=True, type=Path, help="Task-owned virtual environment directory")
    parser.add_argument("--python", default="python3", help="Already provisioned interpreter at the pinned version")
    parser.add_argument("--check", action="store_true", help="Verify an existing environment without modifying it")
    parser.add_argument("--verify-toolchain", action="store_true", help="Also verify Xcode and simulator inventory pins")
    args = parser.parse_args(argv)
    try:
        pins = load_pins(PINS_PATH)
        verify_zstd(pins["zstd"])
        if args.verify_toolchain:
            verify_toolchain(pins)
        executable = str(args.venv.resolve() / "bin/python3")
        if args.check:
            verify_environment(executable, pins)
        else:
            verify_python(args.python, pins["python"])
            if args.venv.exists() or args.venv.is_symlink():
                raise ValueError("Refusing to modify an existing venv path; use --check or choose a new path")
            run([args.python, "-I", "-m", "venv", str(args.venv.resolve())])
            # No ambient indexes, user config, source builds, dependency resolution or shared caches.
            packages = [f"{name}=={version}" for name, version in pins["python_packages"].items()]
            install_environment = {key: value for key, value in os.environ.items()
                                   if not key.startswith(("PIP_", "PYTHON"))}
            install_environment["PIP_CONFIG_FILE"] = os.devnull
            run([executable, "-I", "-m", "pip", "--isolated", "install", "--disable-pip-version-check",
                 "--index-url", "https://pypi.org/simple", "--only-binary=:all:", "--no-deps", "--no-cache-dir",
                 *packages], env=install_environment, timeout=300)
            verify_environment(executable, pins)
        print(f"CI Python environment PASS: {args.venv.resolve()}")
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Do not echo subprocess output; setup failures can contain ambient configuration.
        print(f"CI Python environment FAIL: {error if isinstance(error, ValueError) else type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
