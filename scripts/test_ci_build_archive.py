"""Regression checks for workspace preflight, artifact selection and extraction safety."""
import copy
import io
import json
import plistlib
import platform
import subprocess
import tarfile
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

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
                                     pins_sha="f" * 64, signing_mode="adhoc")

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
        (self.products / "sub").mkdir()
        (self.products / "sub/up").symlink_to("..")
        (self.products / "alias").symlink_to("sub/up/Debug-iphonesimulator/App.app/link")
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
        tar_path.write_bytes(tar_path.read_bytes() + b"modified")
        with self.assertRaisesRegex(ContractError, "archive hash"):
            archive.extract_products(tar_path, self.root / "corrupt", manifest)

    def test_archive_rejects_links_outside_products_and_unlisted_entries(self):
        (self.app / "link").unlink()
        for target in ("/etc/passwd", "../../../outside"):
            with self.subTest(target=target):
                (self.app / "link").symlink_to(target)
                with self.assertRaises(ContractError):
                    archive.inventory(self.products)
                (self.app / "link").unlink()
        base_manifest = self.manifest()
        sub = self.products / "sub"
        sub.mkdir()
        for case, links in (
            ("combined escape", {"sub/link": "..", "escape": "sub/link/../outside"}),
            ("self loop", {"escape": "escape"}),
            ("chain loop", {"sub/link": "../escape", "escape": "sub/link"}),
        ):
            with self.subTest(case=case):
                for name, target in links.items():
                    (self.products / name).symlink_to(target)
                try:
                    candidate = copy.deepcopy(base_manifest)
                    candidate["files"].append({"path": "Products/sub", "kind": "directory", "mode": 0o755})
                    candidate["files"].extend({"path": "Products/" + name, "kind": "symlink", "mode": 0o755,
                                               "target": target} for name, target in links.items())
                    with self.assertRaisesRegex(ContractError, "symlink (escapes|loop)"):
                        archive.inventory(self.products)
                    with self.assertRaisesRegex(ContractError, "symlink (escapes|loop)"):
                        archive.validate_manifest(candidate, self.identity, "123", 1, "ios", "27A266a", "f" * 64)
                    unsafe_tar = self.root / "unsafe.tar.gz"
                    with tarfile.open(unsafe_tar, "w:gz", dereference=False) as handle:
                        handle.add(self.products, arcname="Products")
                    candidate["archive_sha256"] = archive.file_hash(unsafe_tar)
                    with self.assertRaisesRegex(ContractError, "symlink (escapes|loop)"):
                        archive.extract_products(unsafe_tar, self.root / case, candidate)
                    self.assertFalse((self.root / case).exists())
                finally:
                    for name in links:
                        (self.products / name).unlink()
        sub.rmdir()
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

    def test_manifest_rejects_unknown_versions_unsafe_paths_and_false_secret_claims(self):
        manifest = self.manifest()
        for key, value in (("schema_version", 2), ("private_configuration_present", True),
                           ("signing_mode", "disabled"), ("unexpected", "field")):
            with self.subTest(key=key):
                candidate = dict(manifest, **{key: value})
                with self.assertRaises(ContractError):
                    archive.validate_manifest(candidate, self.identity, "123", 1, "ios", "27A266a", "f" * 64)
        for name in ("/Products/App", "Products/../outside", "Products//App", "Other/App"):
            with self.subTest(path=name):
                with self.assertRaises(ContractError):
                    archive.safe_path(name)

    def test_ambient_server_configuration_is_rejected_without_echoing_values(self):
        from unittest.mock import patch
        for key in ("IMMICH_SERVER_URL", "TEST_RUNNER_IMMICH_API_KEY", "SIMCTL_CHILD_IMMICH_API_KEY", "ENABLE_DEBUG_AUTO_SERVER"):
            with self.subTest(key=key), patch.dict(archive.os.environ, {key: "unread dummy value"}, clear=True):
                with self.assertRaisesRegex(ContractError, "ambient server/debug configuration is forbidden"):
                    archive.workspace_preflight(self.root)

    def test_unsigned_or_non_adhoc_apps_cannot_claim_local_simulator_signing(self):
        for code, display in ((1, "code object is not signed at all"), (0, "Signature=Developer ID"), (0, "")):
            with self.subTest(code=code, display=display), patch.object(archive.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], code, stdout="", stderr=display)):
                with self.assertRaises(ContractError):
                    archive.measure_signing(self.app)
        with patch.object(archive.subprocess, "run",
                          return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="Signature=adhoc\n")):
            self.assertEqual(archive.measure_signing(self.app), "adhoc")

    def test_failed_entry_points_leave_failed_records_and_rerun_all_advice(self):
        workspace = self.root / "source"
        (workspace / "Config").mkdir(parents=True)
        ctx = {"identity": self.identity, "source": {"repository": "owner/repo", "event": "pull_request",
               "workflow_path": archive.WORKFLOW, "fork_originated": False, "ci_changing": None},
               "run_id": "123", "attempt": 2}
        private = workspace / "Config/env.xcconfig"
        private.symlink_to(workspace / "missing")
        metadata = {"id": 7, "name": archive.artifact_name("ios", "123", 1), "expired": True,
                    "workflow_run": {"id": 123, "head_sha": self.identity["head_sha"]}}
        for name in ("preflight", "expired", "absent", "identity"):
            output = self.root / name
            command = ["preflight", "--platform", "ios", "--output-dir", str(output)] if name == "preflight" else [
                "select", "--platform", "ios", "--artifact-id", "7", "--producer-attempt", "1",
                "--selection-path", str(self.root / (name + ".json")), "--output-dir", str(output)]
            candidate = copy.deepcopy(metadata)
            candidate["expired"] = name == "expired"
            if name == "identity":
                candidate["workflow_run"]["head_sha"] = "e" * 40
            response = io.BytesIO(json.dumps(candidate).encode())
            missing = urllib.error.HTTPError("https://api.github.com/artifact", 404, "Not Found", None, None)
            with self.subTest(entry=name), patch.object(archive, "ROOT", workspace), patch.object(
                    archive, "context", return_value=ctx), patch.object(archive, "toolchain") as versions, patch.dict(
                    archive.os.environ, {"GH_TOKEN": "dummy"}), patch.object(archive.urllib.request, "urlopen",
                    side_effect=missing if name == "absent" else None, return_value=response), redirect_stderr(io.StringIO()):
                self.assertEqual(archive.main(command), 1)
                versions.assert_not_called()
                summary = json.loads((output / "summary.json").read_text())
                self.assertEqual(summary["status"], "failed")
                failure = summary["infrastructure"][0]
                expected_code = "workspace-preflight-failed" if name == "preflight" else (
                    "archive-identity-mismatch" if name == "identity" else "archive-unavailable")
                self.assertEqual(failure["code"], expected_code)
                self.assertIn("use Re-run all jobs", failure["message"])
                self.assertNotIn("dummy", failure["message"])
                self.assertIn("use Re-run all jobs", (output / "summary.md").read_text())
            if name == "preflight":
                private.unlink()
        archive_dir = self.root / "archive"
        archive_dir.mkdir()
        manifest = copy.deepcopy(self.manifest())
        manifest["identity"]["base_sha"] = "e" * 40
        (archive_dir / "manifest.json").write_text(json.dumps(manifest))
        selection = dict(ctx, platform="ios", producer_attempt=1, artifact_id=7,
                         pins_sha256=archive.file_hash(Path(archive.__file__).with_name("ci-pins.json")))
        selection_path = self.root / "selected.json"
        selection_path.write_text(json.dumps(selection))
        developer = self.root / "Xcode/Contents/Developer"
        developer.mkdir(parents=True)
        (developer.parent / "version.plist").write_bytes(plistlib.dumps({"ProductBuildVersion": "27A266a"}))
        output = self.root / "proof-failure"
        relocated = self.root / "relocated-failure"
        with patch.object(archive, "ROOT", workspace), patch.dict(archive.os.environ, {"DEVELOPER_DIR": str(developer)}), \
                patch.object(archive, "extract_products") as extract, redirect_stderr(io.StringIO()):
            self.assertEqual(archive.main(["proof", "--selection-path", str(selection_path), "--archive-dir", str(archive_dir),
                                           "--relocated-path", str(relocated), "--output-dir", str(output)]), 1)
            extract.assert_not_called()
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertEqual(summary["infrastructure"][0]["code"], "archive-identity-mismatch")
            self.assertIn("use Re-run all jobs", summary["infrastructure"][0]["message"])
            self.assertFalse(relocated.exists())


if __name__ == "__main__":
    unittest.main()
