"""Discovery entry point preserving the existing test class identities."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

from strict_e2e_p2_contract_test_fixtures import (
    Any,
    CACHE_CLEAR_REVIEW_CHECKS,
    DEVICES,
    FIXTURE,
    FROZEN_FIXTURE_SHA256,
    IMAGES,
    IMPLEMENTED_SWIFT_SUITES,
    LABEL_SHA256,
    MOVIE,
    ORIENTED_IMAGES,
    P2ContractError,
    P2_CASES,
    PLATFORM_GUARDS,
    PLATFORM_OF,
    Path,
    RAW_VERDICT,
    RECORDING_FILE,
    RECORDING_TIMING_FILE,
    REPO_ROOT,
    REVIEW_FILE,
    REVIEW_SCHEMA,
    SCRIPT_DIR,
    SOURCE_SHA,
    STEPS_FILE,
    STEPS_SCHEMA,
    UDID,
    _device,
    _facts,
    _fixture_data,
    _method_platforms,
    _move_step,
    _patch_json,
    _read_json,
    _rewrite_runner_report,
    _sha256,
    _verify,
    _write_json,
    _write_review,
    build_evidence,
    contract_main,
    device_class_of,
    hashlib,
    io,
    json,
    mock,
    os,
    p2_selector,
    re,
    read_xcresult_facts,
    require_official_execution,
    strict_e2e_p2_contract,
    subprocess,
    sys,
    tempfile,
    unittest,
    validate_raw_evidence,
    verify_evidence,
)

from strict_e2e_p2_contract_test_execution_cases import P2CaseTableTestsCases

class P2CaseTableTests(P2CaseTableTestsCases, unittest.TestCase):
    pass


from strict_e2e_p2_contract_test_execution_cases import P2SwiftSelectorTestsCases

class P2SwiftSelectorTests(P2SwiftSelectorTestsCases, unittest.TestCase):
    pass


from strict_e2e_p2_contract_test_execution_cases import OfficialExecutionTestsCases

class OfficialExecutionTests(OfficialExecutionTestsCases, unittest.TestCase):
    pass


from strict_e2e_p2_contract_test_evidence_cases import RawEvidenceTestsCases

class RawEvidenceTests(RawEvidenceTestsCases, unittest.TestCase):
    pass


from strict_e2e_p2_contract_test_evidence_cases import CacheClearTestsCases

class CacheClearTests(CacheClearTestsCases, unittest.TestCase):
    pass


from strict_e2e_p2_contract_test_evidence_cases import VerifyGateTestsCases

class VerifyGateTests(VerifyGateTestsCases, unittest.TestCase):
    pass


from strict_e2e_p2_contract_test_evidence_cases import VerifyCommandLineTestsCases

class VerifyCommandLineTests(VerifyCommandLineTestsCases, unittest.TestCase):
    def _run(self, evidence: Path, suite: str, device_class: str, facts: dict[str, Any]) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(strict_e2e_p2_contract, "read_xcresult_facts", return_value=facts):
            code = contract_main(
                [
                    "--evidence-dir",
                    str(evidence),
                    "--suite",
                    suite,
                    "--device-class",
                    device_class,
                    "--expected-sha",
                    SOURCE_SHA,
                ],
                stdout=stdout,
                stderr=stderr,
            )
        return code, stdout.getvalue(), stderr.getvalue()




class ReviewPackageTests(unittest.TestCase):
    def _package(self, root):
        from ci_review_packages import build_package
        evidence = build_evidence(root, "p2-cache", "iphone", review=False)
        (evidence / "strict-p2-cache.xcresult").rmdir()
        facts = _facts("p2-cache", "iphone")
        official = {"devices": facts["devices"], "testNodes": [{"nodeType": "Unit test bundle",
                    "name": "immichSlidesUITests", "children": [{"nodeType": "Test Case",
                    "nodeIdentifier": facts["test_cases"][0]["identifier"], "result": "Passed"}]}]}
        _write_json(evidence / "official-tests.json", official)
        digest = _sha256(evidence / "official-tests.json")
        _patch_json(evidence / "case-manifest.json", official_tests_sha256=digest)
        _write_json(evidence / "result-bundle-disposal.json", {
            "result_bundle_disposed": True, "official_tests_sha256": digest})
        context = {"source_sha": SOURCE_SHA, "tree_sha": "b" * 40, "repository": "sudoHG/immichSlides",
                   "workflow_path": ".github/workflows/ci-nightly.yml", "event": "workflow_dispatch",
                   "ref": "refs/heads/review-candidate", "run_id": "123", "run_attempt": 1,
                   "shard": "iphone-immichSlides-iOS-debug-7", "matrix_sha256": "c" * 64}
        case = {"platform": "ios", "device": "iphone", "configuration": "Debug", "suite": "p2-cache",
                "scenario": "normal", "fixture": "a"}
        package = root / "package"
        build_package(evidence, package, context, case)
        return evidence, package

    def test_package_rejects_changed_inputs_and_exports_only_fixture_allowlist(self):
        from ci_review_packages import build_package, read_package
        with tempfile.TemporaryDirectory() as directory:
            evidence, package = self._package(Path(directory))
            manifest = read_package(package)
            self.assertNotIn("official-tests.json", manifest["files"])
            self.assertNotIn("case-manifest.json", manifest["files"])
            self.assertTrue((package / "review.html").is_file())
            self.assertEqual(manifest["case"]["suite"], "p2-cache")
            self.assertNotIn(UDID, (package / "case.json").read_text())
            for filename in ("cache-returned.png", "case.json", "review.html"):
                path = package / filename
                original = path.read_bytes()
                path.write_bytes(original + b"changed")
                with self.subTest(filename=filename), self.assertRaises((ValueError, P2ContractError)):
                    read_package(package)
                path.write_bytes(original)
            (package / "extra.log").write_text("unexpected")
            with self.assertRaises(ValueError):
                read_package(package)
            (package / "extra.log").unlink()
            _patch_json(evidence / "case-manifest.json", source_dirty_paths=["changed.py"])
            with self.assertRaises((ValueError, P2ContractError)):
                build_package(evidence, Path(directory) / "refused", manifest["context"], manifest["case"])
            self.assertFalse((Path(directory) / "refused").exists())
            _patch_json(evidence / "case-manifest.json", source_dirty_paths=[])
            from strict_e2e_server import PUBLIC_API_KEY
            (evidence / "xcodebuild.log").write_text(PUBLIC_API_KEY)
            with self.assertRaises(ValueError):
                build_package(evidence, Path(directory) / "unsafe", manifest["context"], manifest["case"])
            self.assertFalse((Path(directory) / "unsafe").exists())

    def test_review_record_binds_human_signature_run_case_and_all_artifact_decisions(self):
        from ci_review_packages import read_package, record_path, validate_record
        import copy
        with tempfile.TemporaryDirectory() as directory:
            evidence, package = self._package(Path(directory))
            manifest = read_package(package)
            _write_review(evidence, "p2-cache", "iphone")
            review = _read_json(evidence / REVIEW_FILE)
            review["reviewer"] = "sudoHG"
            record = {"schema_version": 1, "context": manifest["context"], "case": manifest["case"],
                      "case_sha256": manifest["case_sha256"], "package_sha256": manifest["package_sha256"],
                      "reviewed_at": "2020-01-01T00:00:00Z", "signature": "I personally reviewed these images and recordings.",
                      "review": review}
            self.assertEqual(validate_record(record, package), "PASS")
            self.assertEqual(record_path(record), Path(SOURCE_SHA) / "p2-cache/iphone/a.json")
            changes = [("context.run_id", "456"), ("context.run_attempt", 2), ("context.run_attempt", True), ("case.fixture", "b"),
                       ("case_sha256", "0" * 64), ("package_sha256", "0" * 64), ("signature", ""),
                       ("review.reviewer", "agent"), ("review", None), ("review", []), ("review", "PASS"),
                       ("reviewed_at", "yesterday"),
                       ("review.artifacts.cache-returned.png.conclusion", "FAIL")]
            for key, value in changes:
                altered = copy.deepcopy(record)
                if key.endswith(".png.conclusion"):
                    altered["review"]["artifacts"]["cache-returned.png"]["conclusion"] = value
                else:
                    target = altered
                    parts = key.split(".")
                    for part in parts[:-1]:
                        target = target[part]
                    target[parts[-1]] = value
                with self.subTest(key=key), self.assertRaises((ValueError, P2ContractError)):
                    validate_record(altered, package)
            del record["review"]["artifacts"]["cache-returned.png"]
            with self.assertRaises((ValueError, P2ContractError)):
                validate_record(record, package)

    def test_key_reader_preserves_known_failure_when_other_fixture_is_missing(self):
        from ci_review_packages import main, read_package, record_path
        from contextlib import redirect_stdout
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, package = self._package(root)
            manifest = read_package(package)
            _write_review(evidence, "p2-cache", "iphone")
            review = _read_json(evidence / REVIEW_FILE)
            review["reviewer"] = "sudoHG"
            review["verdict"] = "FAIL"
            review["artifacts"]["cache-returned.png"]["conclusion"] = "FAIL"
            record = {"schema_version": 1, "context": manifest["context"], "case": manifest["case"],
                      "case_sha256": manifest["case_sha256"], "package_sha256": manifest["package_sha256"],
                      "reviewed_at": "2020-01-01T00:00:00Z", "signature": "I personally reviewed these images and recordings.",
                      "review": review}
            key = record_path(record)
            target = root / "packages" / key.with_suffix("")
            target.parent.mkdir(parents=True)
            package.rename(target)
            record_file = root / "records" / key
            record_file.parent.mkdir(parents=True)
            _write_json(record_file, record)
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                exit_code = main(["read", "--records-dir", str(root / "records"), "--sha", SOURCE_SHA,
                                  "--suite", "p2-cache", "--device-class", "iphone",
                                  "--packages-dir", str(root / "packages")])
            self.assertEqual(exit_code, 1)
            result = json.loads(stdout.getvalue())
            self.assertEqual(result["records"][0]["verdict"], "FAIL")
            self.assertEqual(result["missing_fixtures"], ["b"])
            self.assertEqual(result["status"], "FAIL")


if __name__ == "__main__":
    unittest.main()
