"""Fail-closed guards for the release archive's cloud environment."""

import io
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

import check_xcode_cloud_archive as cloud


class XcodeCloudArchiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.developer = self.root / "Xcode.app/Contents/Developer"
        self.developer.mkdir(parents=True)
        self.version = self.developer.parent / "version.plist"
        self.xcode = {"CFBundleShortVersionString": "27.0", "ProductBuildVersion": "27A266a"}
        self.version.write_bytes(plistlib.dumps(self.xcode))
        pins = self.root / "scripts/ci-pins.json"
        pins.parent.mkdir()
        pins.write_bytes(cloud.ROOT.joinpath("scripts/ci-pins.json").read_bytes())
        self.lock = self.root / cloud.LOCK_PATH
        self.lock.parent.mkdir(parents=True)
        self.lock.write_text('{"pins": []}\n')
        for command in (
            ["git", "init", "-q"],
            ["git", "add", "."],
            ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"],
        ):
            subprocess.run(command, cwd=self.root, check=True, capture_output=True, timeout=10)
        self.environment = {"CI_XCODE_CLOUD": "TRUE", "CI_XCODEBUILD_ACTION": "archive",
                            "CI_PRODUCT_PLATFORM": "iOS", "CI_XCODE_SCHEME": "immichSlides"}

    def test_both_archive_platforms_accept_the_pinned_clean_environment(self):
        for platform in ("iOS", "tvOS"):
            with self.subTest(platform=platform):
                environment = dict(self.environment, CI_PRODUCT_PLATFORM=platform)
                version, build, digest = cloud.validate_environment(self.root, environment, self.developer)
                self.assertEqual((version, build), ("27.0", "27A266a"))
                self.assertEqual(len(digest), 64)

    def test_private_configuration_is_rejected_without_opening_files_or_links(self):
        config = self.root / "Config/env.xcconfig"
        config.parent.mkdir()
        for kind in ("file", "link", "dangling"):
            with self.subTest(kind=kind):
                if kind == "file":
                    config.write_text("unread fixture content")
                else:
                    config.symlink_to(self.lock if kind == "link" else self.root / "missing")
                with patch.object(Path, "read_bytes", side_effect=AssertionError("must not read files")):
                    with self.assertRaisesRegex(cloud.ArchivePreflightError, "private configuration"):
                        cloud.validate_environment(self.root, self.environment, self.developer)
                config.unlink()

    def test_ambient_server_and_debug_configuration_is_rejected_without_echoing_values(self):
        for name in ("IMMICH_API_KEY", "TEST_RUNNER_IMMICH_SERVER_URL", "SIMCTL_CHILD_IMMICH_API_KEY",
                     "ENABLE_DEBUG_AUTO_SERVER"):
            with self.subTest(name=name):
                environment = dict(self.environment, **{name: "private-fixture-value"})
                output = io.StringIO()
                with patch.dict(os.environ, environment, clear=True), patch.object(cloud, "ROOT", self.root):
                    with redirect_stderr(output):
                        self.assertEqual(cloud.main(), 1)
                self.assertIn("ambient server/debug configuration", output.getvalue())
                self.assertNotIn("private-fixture-value", output.getvalue())

    def test_unintended_cloud_actions_fail_before_archiving(self):
        for name, value in (("CI_XCODE_CLOUD", "FALSE"), ("CI_XCODEBUILD_ACTION", "build"),
                            ("CI_PRODUCT_PLATFORM", "macOS"), ("CI_XCODE_SCHEME", "immichSlides-iOS")):
            with self.subTest(name=name):
                with self.assertRaises(cloud.ArchivePreflightError):
                    cloud.validate_environment(self.root, dict(self.environment, **{name: value}), self.developer)

    def test_unavailable_or_different_xcode_pins_are_rejected(self):
        for contents in (b"invalid plist", plistlib.dumps({}),
                         plistlib.dumps(dict(self.xcode, ProductBuildVersion="different")),
                         plistlib.dumps(dict(self.xcode, CFBundleShortVersionString="different"))):
            with self.subTest(contents=contents):
                self.version.write_bytes(contents)
                with self.assertRaises((cloud.ArchivePreflightError, plistlib.InvalidFileException)):
                    cloud.validate_environment(self.root, self.environment, self.developer)
        self.version.unlink()
        with self.assertRaises(OSError):
            cloud.validate_environment(self.root, self.environment, self.developer)

    def test_package_resolution_must_exist_and_match_the_commit(self):
        original = self.lock.read_bytes()
        self.lock.write_text("changed resolution")
        with self.assertRaisesRegex(cloud.ArchivePreflightError, "committed package resolution"):
            cloud.validate_environment(self.root, self.environment, self.developer)
        self.lock.unlink()
        for kind in ("missing", "link"):
            with self.subTest(kind=kind):
                if kind == "link":
                    target = self.root / "alternate-resolution"
                    target.write_bytes(original)
                    self.lock.symlink_to(target)
                with self.assertRaisesRegex(cloud.ArchivePreflightError, "regular package resolution"):
                    cloud.validate_environment(self.root, self.environment, self.developer)


if __name__ == "__main__":
    unittest.main()
