"""Discovery entry point preserving the existing test class identities."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from git_privacy_gate_test_fixtures import (
    BOOTSTRAP_WORKFLOW,
    CANONICAL_LFS_POINTER,
    CONTRIBUTING,
    HOOKS_ROOT,
    INSTALLER,
    MINIMAL_GIF_PAYLOAD,
    MINIMAL_PDF_PAYLOAD,
    PRINTABLE_DESCRIPTOR_GIF_PAYLOAD,
    Path,
    REPOSITORY_ROOT,
    SCRIPT,
    SMART_FILL_UI_TESTS,
    TRUSTED_RUNNER,
    TRUSTED_WORKFLOW,
    ZERO_OID,
    make_minimal_pdf_payload,
    os,
    shutil,
    subprocess,
    sys,
    tempfile,
    unittest,
)

from git_privacy_gate_test_scanning_cases import GitPrivacyGateTestsCasesScanning
from git_privacy_gate_test_push_cases import GitPrivacyGateTestsCasesPush
from git_privacy_gate_test_hooks_cases import GitPrivacyGateTestsCasesHooks

class GitPrivacyGateTests(GitPrivacyGateTestsCasesScanning, GitPrivacyGateTestsCasesPush, GitPrivacyGateTestsCasesHooks, unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary_directory.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Privacy Gate Test")
        self.git("config", "user.email", "privacy-gate@example.invalid")
        self.write("Sources/App.swift", "struct App {}\n")
        self.commit("baseline")
        self.base_oid = self.git("rev-parse", "HEAD").stdout.strip()


    def tearDown(self) -> None:
        self.temporary_directory.cleanup()


    def write(self, relative_path: str, content: str) -> None:
        path = self.repo / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-m", message)


    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repo,
            check=True,
            capture_output=True,
            text=True,
        )


    def git_without_check(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )


    def install_gate_files(self, *, configure: bool = True) -> None:
        scripts_directory = self.repo / "scripts"
        hooks_directory = self.repo / ".githooks"
        scripts_directory.mkdir(exist_ok=True)
        hooks_directory.mkdir(exist_ok=True)
        shutil.copy2(SCRIPT, scripts_directory / SCRIPT.name)
        shutil.copy2(INSTALLER, scripts_directory / INSTALLER.name)
        for hook_name in ("commit-msg", "pre-commit", "pre-push"):
            target = hooks_directory / hook_name
            shutil.copy2(HOOKS_ROOT / hook_name, target)
            target.chmod(0o755)
        if configure:
            subprocess.run(
                [str(scripts_directory / INSTALLER.name)],
                cwd=self.repo,
                check=True,
                capture_output=True,
                text=True,
            )


    def run_gate(
        self,
        *arguments: str,
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=self.repo,
            input=input_text,
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )


    def assert_allowed(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(
            result.returncode,
            0,
            msg=f"stdout={result.stdout}\nstderr={result.stderr}",
        )
        self.assertIn("PRIVACY_GATE_PASS", result.stdout)


    def assert_blocked(
        self,
        result: subprocess.CompletedProcess[str],
        reason: str,
    ) -> None:
        self.assertEqual(
            result.returncode,
            2,
            msg=f"stdout={result.stdout}\nstderr={result.stderr}",
        )
        self.assertIn("PRIVACY_GATE_BLOCKED", result.stderr)
        self.assertIn(reason, result.stderr)




from git_privacy_gate_test_repository_cases import RepositoryPrivacyContractTestsCases

class RepositoryPrivacyContractTests(RepositoryPrivacyContractTestsCases, unittest.TestCase):
    pass


if __name__ == "__main__":
    unittest.main()
