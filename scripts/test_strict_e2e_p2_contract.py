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
    def _package(self, root, fixture="a", suite="p2-cache"):
        from ci_review_packages import build_package
        evidence = build_evidence(root, suite, "iphone", review=False)
        if fixture == "b":
            (evidence / "cache-returned.png").write_bytes(_fixture_data("b")["images"]["asset-b-3"])
            _patch_json(evidence / "case-manifest.json", fixture_set="b", fixture_sha256=FROZEN_FIXTURE_SHA256["b"])
            _write_json(evidence / "visual-identity-runner.json", validate_raw_evidence(evidence, "p2-cache", "b"))
        (evidence / f"strict-{suite}.xcresult").rmdir()
        facts = _facts(suite, "iphone")
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
                   "ref": "refs/heads/main", "run_id": "123", "run_attempt": 1,
                   "shard": "iphone-immichSlides-iOS-debug-7", "matrix_sha256": "c" * 64}
        case = {"platform": "ios", "device": "iphone", "configuration": "Debug", "suite": suite,
                "scenario": "normal", "fixture": fixture}
        package = root / "package"
        build_package(evidence, package, context, case)
        return evidence, package

    def test_package_rejects_changed_inputs_and_exports_only_fixture_allowlist(self):
        from ci_review_packages import build_package, read_package
        with tempfile.TemporaryDirectory() as directory:
            evidence, package = self._package(Path(directory))
            manifest = read_package(package)
            original_files = {p.name: p.read_bytes() for p in package.iterdir()}
            read_package(package)
            self.assertEqual({p.name: p.read_bytes() for p in package.iterdir()}, original_files)
            self.assertNotIn("sensitive-scan.json", original_files)
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
            record = {"schema_version": 2, "package_manifest": manifest, "context": manifest["context"], "case": manifest["case"],
                      "case_sha256": manifest["case_sha256"], "package_sha256": manifest["package_sha256"],
                      "reviewed_at": "2020-01-01T00:00:00Z", "signature": "These review decisions and observations are my own.",
                      "review": review}
            self.assertEqual(validate_record(record, package), "PASS")
            self.assertEqual(record_path(record), Path(SOURCE_SHA) / "p2-cache/iphone/a.json")
            changes = [("context.run_id", "456"), ("context.run_attempt", 2), ("context.run_attempt", True), ("case.fixture", "b"),
                       ("case_sha256", "0" * 64), ("package_sha256", "0" * 64), ("signature", ""),
                       ("review.reviewer", "agent"), ("review", None), ("review", []), ("review", "PASS"),
                       ("review.artifacts", ["cache-before-confirm.png", "cache-cleared.png", "cache-returned.png"]),
                       ("review.artifacts", None),
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
                if key == "review.artifacts":
                    from ci_review_packages import main
                    from contextlib import redirect_stderr
                    malformed = Path(directory) / "malformed-record.json"
                    _write_json(malformed, altered)
                    with redirect_stderr(io.StringIO()):
                        self.assertEqual(main(["validate-record", "--record", str(malformed), "--package", str(package)]), 2)
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
            record = {"schema_version": 2, "package_manifest": manifest, "context": manifest["context"], "case": manifest["case"],
                      "case_sha256": manifest["case_sha256"], "package_sha256": manifest["package_sha256"],
                      "reviewed_at": "2020-01-01T00:00:00Z", "signature": "These review decisions and observations are my own.",
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

    def test_expired_media_preserves_records_and_requires_compact_hashes_and_main_nightly(self):
        from ci_review_packages import digest, main, read_package, record_path
        from contextlib import redirect_stdout
        import copy
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindings, saved = [], []
            for fixture in ("a", "b"):
                case_root = root / fixture
                case_root.mkdir()
                evidence, package = self._package(case_root, fixture)
                manifest = read_package(package)
                _write_review(evidence, "p2-cache", "iphone")
                review = _read_json(evidence / REVIEW_FILE)
                review["reviewer"] = "sudoHG"
                mark = manifest["facts"]["raw"]["cache_clear"]["target_mark"]
                review["artifacts"]["cache-returned.png"].update(visible_marks=[mark],
                    fixture_sha256={mark: manifest["fixture_marks"][mark]})
                record = {"schema_version": 2, "package_manifest": manifest, "context": manifest["context"],
                          "case": manifest["case"], "case_sha256": manifest["case_sha256"],
                          "package_sha256": manifest["package_sha256"], "reviewed_at": "2020-01-01T00:00:00Z",
                          "signature": "These review decisions and observations are my own.", "review": review}
                path = root / "records" / record_path(record)
                path.parent.mkdir(parents=True, exist_ok=True)
                _write_json(path, record); saved.append((path, record))
                bindings.append({"identity": {"kind": "strict", "key": "p2-cache",
                    "dimensions": {k: v for k, v in manifest["case"].items() if k != "platform"}},
                    "context": manifest["context"], "case_sha256": manifest["case_sha256"],
                    "package_sha256": manifest["package_sha256"]})
            binding_path = root / "bindings.json"
            _write_json(binding_path, {"schema_version": 1, "review_packages": bindings})
            args = ["read", "--records-dir", str(root / "records"), "--sha", SOURCE_SHA,
                    "--suite", "p2-cache", "--device-class", "iphone", "--packages-dir", str(root / "expired"),
                    "--bindings", str(binding_path)]
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(main(args), 0)
            result = json.loads(output.getvalue())
            self.assertEqual(result["status"], "PASS")
            self.assertEqual([r["media_status"] for r in result["records"]], ["package-expired"] * 2)
            with redirect_stdout(io.StringIO()):
                self.assertEqual(main(args[:-2]), 1)
            for event, ref, workflow in (("workflow_dispatch", "refs/heads/candidate", ".github/workflows/ci-nightly.yml"),
                    ("pull_request", "refs/pull/168/merge", ".github/workflows/ci-p2-review.yml"),
                    ("local", None, None)):
                changed_bindings = copy.deepcopy(bindings)
                for index, (path, original) in enumerate(saved):
                    record = copy.deepcopy(original)
                    record["context"].update(event=event, ref=ref, workflow_path=workflow, run_id=None if event == "local" else "123")
                    manifest = record["package_manifest"]
                    manifest["package_sha256"] = digest({k: v for k, v in manifest.items() if k != "package_sha256"})
                    record["package_sha256"] = manifest["package_sha256"]
                    changed_bindings[index].update(context=record["context"], package_sha256=record["package_sha256"])
                    _write_json(path, record)
                _write_json(binding_path, {"schema_version": 1, "review_packages": changed_bindings})
                output = io.StringIO()
                with self.subTest(event=event), redirect_stdout(output):
                    self.assertEqual(main(args), 1)
                self.assertFalse(json.loads(output.getvalue())["qualifying"])
            for path, original in saved:
                _write_json(path, original)
            bindings[0]["package_sha256"] = "0" * 64
            _write_json(binding_path, {"schema_version": 1, "review_packages": bindings})
            with redirect_stdout(io.StringIO()):
                self.assertEqual(main(args), 2)

    def test_human_disagreement_partial_notes_and_review_chronology_are_enforced(self):
        from ci_review_packages import read_package, validate_record
        import copy
        with tempfile.TemporaryDirectory() as directory:
            evidence, package = self._package(Path(directory))
            manifest = read_package(package)
            _write_review(evidence, "p2-cache", "iphone")
            review = _read_json(evidence / REVIEW_FILE)
            review["reviewer"] = "sudoHG"
            record = {"schema_version": 2, "package_manifest": manifest, "context": manifest["context"],
                      "case": manifest["case"], "case_sha256": manifest["case_sha256"], "package_sha256": manifest["package_sha256"],
                      "reviewed_at": "2020-01-01T00:00:00Z", "signature": "These review decisions and observations are my own.", "review": review}
            for conclusion in ("FAIL", "PARTIAL"):
                changed = copy.deepcopy(record)
                changed["review"]["verdict"] = conclusion
                entry = changed["review"]["artifacts"]["cache-returned.png"]
                entry.update(conclusion=conclusion, visible_marks=[], fixture_sha256={},
                             observation="The returned photo is absent." if conclusion == "FAIL" else "I have not reviewed this item yet.")
                self.assertEqual(validate_record(changed, package), conclusion)
                entry["observation"] = ""
                with self.assertRaises((ValueError, P2ContractError)):
                    validate_record(changed, package)
                entry["observation"] = "The returned photo is absent."
                entry["conclusion"] = "PASS"
                with self.assertRaises((ValueError, P2ContractError)):
                    validate_record(changed, package)
            for reviewed_at in ("1970-01-01T00:00:00Z", "2999-01-01T00:00:00Z"):
                changed = copy.deepcopy(record); changed["reviewed_at"] = reviewed_at
                with self.subTest(reviewed_at=reviewed_at), self.assertRaises((ValueError, P2ContractError)):
                    validate_record(changed, package)
            changed = copy.deepcopy(record)
            changed["review"]["artifacts"]["cache-returned.png"]["controls"] = "not-reviewed"
            with self.assertRaises(ValueError):
                validate_record(changed, package)
            changed = copy.deepcopy(record)
            changed["review"]["verdict"] = "PARTIAL"
            entry = changed["review"]["artifacts"]["cache-returned.png"]
            entry["checks"]["playback_normal_after_return"] = "PARTIAL"
            entry["observation"] = "No note entered; reviewer selected PASS."
            with self.assertRaises(ValueError):
                validate_record(changed, package)
            entry["observation"] = "I have not reviewed playback after return."
            self.assertEqual(validate_record(changed, package), "PARTIAL")
            video_root = Path(directory) / "video"; video_root.mkdir()
            video_evidence, video_package = self._package(video_root, suite="p2-rotation")
            video_manifest = read_package(video_package)
            _write_review(video_evidence, "p2-rotation", "iphone")
            video_review = _read_json(video_evidence / REVIEW_FILE)
            video_review["reviewer"] = "sudoHG"; video_review["verdict"] = "PARTIAL"
            piece = video_review["artifacts"][RECORDING_FILE]["time_slices"][0]
            piece.update(conclusion="PARTIAL", observation="I have not watched this rotation yet.")
            video_record = dict(record, package_manifest=video_manifest, context=video_manifest["context"],
                case=video_manifest["case"], case_sha256=video_manifest["case_sha256"],
                package_sha256=video_manifest["package_sha256"], review=video_review)
            self.assertEqual(validate_record(video_record, video_package), "PARTIAL")
            piece["observation"] = "No note entered; reviewer selected PASS."
            with self.assertRaises(ValueError):
                validate_record(video_record, video_package)

    def test_shard_exports_compact_bindings_for_aggregate_before_media_upload(self):
        from ci_review_packages import export_shard, read_package, validate_bindings
        from ci_nightly import aggregate_nightly, case_identity
        from ci_summary import observation
        from test_ci_summary import valid_summary
        import copy
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, package = self._package(root)
            manifest = read_package(package)
            context = manifest["context"]
            item = case_identity(manifest["case"])
            summary = valid_summary()
            summary["identity"] = {"schema_version": 1, "event": context["event"], "repository": context["repository"],
                                   "tree_sha": context["tree_sha"], "commit_sha": context["source_sha"], "ref": context["ref"]}
            summary["source"].update(repository=context["repository"], event=context["event"],
                workflow_path=context["workflow_path"], fork_originated=False)
            summary["run"].update(id=context["run_id"], attempt=context["run_attempt"], tier="strict", job="nightly-strict", shard=context["shard"])
            summary["hashes"] = {"manifests": {"nightly-matrix": context["matrix_sha256"]}, "policies": {}}
            summary["population"].update(declared=[item], compiled=[item], observed=[observation(item, "needs-human-review", 1)])
            summary["status"] = "unverified"
            source = root / "shard"
            (source / "records").mkdir(parents=True)
            _write_json(source / "records/summary.json", summary)
            (source / "cases").mkdir()
            evidence.rename(source / "cases/000-p2-cache")
            self.assertEqual(export_shard(source, root / "published"), 0)
            bindings = _read_json(source / "records/p2-review-bindings.json")["review_packages"]
            self.assertEqual(validate_bindings(bindings, summary), bindings)
            exported = read_package(root / "published" / SOURCE_SHA / "p2-cache/iphone/a")
            self.assertEqual(bindings[0]["package_sha256"], exported["package_sha256"])
            aggregate = aggregate_nightly([item], [summary], live_in_scope=False, review_packages=bindings)
            self.assertEqual(aggregate["review_packages"], bindings)
            self.assertEqual(aggregate["needs_human_review"], [item])
            self.assertFalse(aggregate["release_eligible"])
            for key, value in (("case_sha256", "0" * 64), ("context", dict(context, tree_sha="d" * 40)),
                               ("identity", dict(item, key="another case"))):
                changed = copy.deepcopy(bindings); changed[0][key] = value
                with self.subTest(key=key), self.assertRaises(ValueError):
                    validate_bindings(changed, summary)


if __name__ == "__main__":
    unittest.main()
