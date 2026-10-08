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




if __name__ == "__main__":
    unittest.main()
