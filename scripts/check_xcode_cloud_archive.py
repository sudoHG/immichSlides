#!/usr/bin/env python3
"""Validate a secret-free, pinned Xcode Cloud archive without building or uploading."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path
from setup_ci_python import load_pins

ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = "immichSlides.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


class ArchivePreflightError(ValueError):
    pass


def validate_workspace(root, environment):
    # Reject even dangling links before opening any files; never inspect private values.
    if os.path.lexists(root / "Config/env.xcconfig"):
        raise ArchivePreflightError("private configuration is forbidden at archive time")
    if any(name.startswith(("IMMICH", "TEST_RUNNER_IMMICH", "SIMCTL_CHILD_IMMICH", "ENABLE_DEBUG_"))
           for name in environment):
        raise ArchivePreflightError("ambient server/debug configuration is forbidden")


def validate_environment(root, environment, developer):
    validate_workspace(root, environment)
    if environment.get("CI_XCODE_CLOUD") != "TRUE":
        raise ArchivePreflightError("this entry point requires Xcode Cloud")
    if (environment.get("CI_XCODEBUILD_ACTION") != "archive"
            or environment.get("CI_PRODUCT_PLATFORM") not in {"iOS", "tvOS"}
            or environment.get("CI_XCODE_SCHEME") != "immichSlides"):
        raise ArchivePreflightError("expected an iOS or tvOS archive of the immichSlides scheme")

    pins = load_pins(root / "scripts/ci-pins.json", tier="release")["xcode"]
    version = plistlib.loads((developer.parent / "version.plist").read_bytes())
    # Cloud's Xcode installation path differs from GitHub's; compare the version/build.
    if (not isinstance(pins["version"], str) or not pins["version"]
            or not isinstance(pins["build"], str) or not pins["build"]
            or version.get("CFBundleShortVersionString") != pins["version"]
            or version.get("ProductBuildVersion") != pins["build"]):
        raise ArchivePreflightError("selected Xcode does not match scripts/ci-pins.json")

    lock = root / LOCK_PATH
    if lock.is_symlink() or not lock.is_file():
        raise ArchivePreflightError("a regular package resolution file is required")
    committed = subprocess.run(["git", "show", "HEAD:" + LOCK_PATH], cwd=root,
                               capture_output=True, check=True, timeout=30).stdout
    if lock.read_bytes() != committed:
        raise ArchivePreflightError("package resolution differs from the committed package resolution")
    return pins["version"], pins["build"], hashlib.sha256(committed).hexdigest()


def main():
    try:
        # Do the privacy checks before running a tool that may inspect configuration.
        environment = dict(os.environ)
        validate_workspace(ROOT, environment)
        selected = environment.get("DEVELOPER_DIR")
        if not selected:
            selected = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True,
                                      check=True, timeout=30).stdout.strip()
        version, build, digest = validate_environment(ROOT, environment, Path(selected))
        print(f"Xcode Cloud archive preflight PASS: Xcode {version} ({build}), Package.resolved sha256={digest}")
        return 0
    except ArchivePreflightError as error:
        print(f"Xcode Cloud archive preflight FAIL: {error}", file=sys.stderr)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
        # Parser/tool exceptions can contain paths or configuration; log only their type.
        print(f"Xcode Cloud archive preflight FAIL: {type(error).__name__}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
