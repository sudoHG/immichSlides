"""Regression checks for build admission, artifact identity and extraction safety."""
import copy
import json
import plistlib
import platform
import tempfile
import unittest
from pathlib import Path

import ci_build_archive as archive
from ci_summary import ContractError


class BuildArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.identity = {"schema_version": 1, "event": "pull_request", "repository": "owner/repo",
                         "pull_request": 2, "merge_sha": "a" * 40, "base_sha": "b" * 40,
                         "head_sha": "c" * 40, "tree_sha": "d" * 40}
        self.products = self.root / "Products"
        self.app = self.products / "Debug-iphonesimulator/App.app"
        self.app.mkdir(parents=True)
        self.plist = self.app / "Info.plist"
        self.values = {"IMMICH_SERVER_URL": "", "IMMICH_API_KEY": "", "ENABLE_DEBUG_AUTO_SERVER": "0"}
        self.plist.write_bytes(plistlib.dumps(self.values))
        (self.app / "App").write_bytes(b"executable")
        (self.app / "App").chmod(0o755)
        (self.app / "link").symlink_to("App")
        (self.products / "App.xctestrun").write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"FormatVersion": 2}}))

    def manifest(self):
        return archive.make_manifest(self.products, identity=self.identity, run_id="123", attempt=1,
                                     platform="ios", architecture=[platform.machine()], xcode_build="27A266a",
                                     source_path=self.root / "source", archive_sha="e" * 64,
                                     pins_sha="f" * 64)

    def test_private_configuration_is_rejected_without_following_links(self):
        config = self.root / "Config/env.xcconfig"
        config.parent.mkdir()
        archive.workspace_preflight(self.root)
        for kind in ("file", "symlink", "dangling"):
            with self.subTest(kind=kind):
                if kind == "file":
                    config.write_text("unread private content")
                else:
                    config.symlink_to(self.plist if kind == "symlink" else self.root / "missing")
                with self.assertRaisesRegex(ContractError, "private configuration"):
                    archive.workspace_preflight(self.root)
                config.unlink()

    def test_structural_secret_checks_reject_configured_servers_and_debug_flags(self):
        archive.check_products(self.products)
        for key, value in (("IMMICH_SERVER_URL", "fixture.invalid"), ("IMMICH_API_KEY", "dummy"),
                           ("ENABLE_DEBUG_AUTO_SERVER", "1"), ("ENABLE_DEBUG_NEW_FLAG", True),
                           ("ENABLE_DEBUG_AUTO_SERVER", "$(UNRESOLVED)")):
            with self.subTest(key=key, value=value):
                values = dict(self.values, **{key: value})
                self.plist.write_bytes(plistlib.dumps(values))
                with self.assertRaises(ContractError):
                    archive.check_products(self.products)
        self.plist.write_bytes(plistlib.dumps({"IMMICH_SERVER_URL": ""}))
        with self.assertRaises(ContractError):
            archive.check_products(self.products)

    def test_archive_identity_refuses_another_base_even_with_the_same_head(self):
        manifest = self.manifest()
        archive.validate_manifest(manifest, self.identity, "123", 1, "ios", "27A266a", "f" * 64)
        for field, value in (("repository", "other/repo"), ("pull_request", 3), ("base_sha", "e" * 40),
                             ("head_sha", "e" * 40), ("tree_sha", "e" * 40), ("merge_sha", "e" * 40)):
            with self.subTest(field=field):
                expected = dict(self.identity, **{field: value})
                with self.assertRaises(ContractError):
                    archive.validate_manifest(manifest, expected, "123", 1, "ios", "27A266a", "f" * 64)
        for run, attempt, platform in (("124", 1, "ios"), ("123", 2, "ios"), ("123", 1, "tvos")):
            with self.subTest(run=run, attempt=attempt, platform=platform):
                with self.assertRaises(ContractError):
                    archive.validate_manifest(manifest, self.identity, run, attempt, platform, "27A266a", "f" * 64)

    def test_artifact_selection_requires_id_run_and_producer_attempt(self):
        metadata = {"id": 7, "name": archive.artifact_name("ios", "123", 1), "expired": False,
                    "workflow_run": {"id": 123, "head_sha": self.identity["head_sha"]}}
        archive.validate_artifact(metadata, self.identity, "123", 1, "ios", 7)
        for field, value in (("id", 8), ("name", archive.artifact_name("ios", "123", 2)), ("expired", True)):
            with self.subTest(field=field):
                candidate = dict(metadata, **{field: value})
                with self.assertRaises(ContractError):
                    archive.validate_artifact(candidate, self.identity, "123", 1, "ios", 7)
        candidate = copy.deepcopy(metadata)
        candidate["workflow_run"]["id"] = 124
        with self.assertRaises(ContractError):
            archive.validate_artifact(candidate, self.identity, "123", 1, "ios", 7)

    def test_tar_round_trip_preserves_modes_symlinks_and_detects_tampering(self):
        tar_path = self.root / "build.tar.gz"
        archive.pack_products(self.products, tar_path)
        manifest = self.manifest()
        manifest["archive_sha256"] = archive.file_hash(tar_path)
        relocated = self.root / "relocated"
        archive.extract_products(tar_path, relocated, manifest)
        self.assertEqual(archive.inventory(relocated / "Products"), manifest["files"])
        self.assertEqual((relocated / "Products/Debug-iphonesimulator/App.app/App").stat().st_mode & 0o777, 0o755)
        self.assertEqual((relocated / "Products/Debug-iphonesimulator/App.app/link").readlink(), Path("App"))
        manifest["files"][-1]["mode"] = 0
        with self.assertRaises(ContractError):
            archive.extract_products(tar_path, self.root / "tampered", manifest)

    def test_archive_rejects_links_outside_products_and_unlisted_entries(self):
        (self.app / "link").unlink()
        for target in ("/etc/passwd", "../../../outside"):
            with self.subTest(target=target):
                (self.app / "link").symlink_to(target)
                with self.assertRaises(ContractError):
                    archive.inventory(self.products)
                (self.app / "link").unlink()
        tar_path = self.root / "build.tar.gz"
        archive.pack_products(self.products, tar_path)
        manifest = self.manifest()
        manifest["archive_sha256"] = archive.file_hash(tar_path)
        manifest["files"].pop()
        with self.assertRaises(ContractError):
            archive.extract_products(tar_path, self.root / "extra", manifest)

    def test_local_disk_safety_cannot_use_the_hosted_ci_exception(self):
        from unittest.mock import patch
        for environment in ({}, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"}):
            with self.subTest(environment=environment), patch.dict(archive.os.environ, environment, clear=True):
                with self.assertRaisesRegex(ContractError, "local 80 GiB"):
                    archive.disk_check(30)


if __name__ == "__main__":
    unittest.main()
