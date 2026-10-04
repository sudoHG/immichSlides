from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
GENERATOR = REPOSITORY_ROOT / "scripts" / "build_privacy_policy_page.py"
POLICY = REPOSITORY_ROOT / "PRIVACY_POLICY.md"


class PrivacyPolicyPageGeneratorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.temporary_root = Path(self.temporary_directory.name)
        self.repository = self.temporary_root / "repository"
        (self.repository / "scripts").mkdir(parents=True)
        shutil.copy2(GENERATOR, self.repository / "scripts" / GENERATOR.name)
        shutil.copy2(POLICY, self.repository / POLICY.name)
        self.generator = self.repository / "scripts" / GENERATOR.name

    def run_generator(self, working_directory: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(self.generator), *arguments],
            cwd=working_directory,
            capture_output=True,
            check=False,
            text=True,
        )

    def assert_pages_exist(self, output_directory: Path) -> None:
        self.assertTrue((output_directory / "privacy" / "index.html").is_file())
        self.assertTrue((output_directory / "index.html").is_file())

    def test_default_output_uses_build_privacy_site(self) -> None:
        completed = self.run_generator(self.repository)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assert_pages_exist(self.repository / "build" / "privacy-site")

    def test_absolute_output_directory_writes_both_pages(self) -> None:
        output_directory = self.temporary_root / "external-output"
        completed = self.run_generator(
            self.repository,
            "--output-dir",
            str(output_directory),
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assert_pages_exist(output_directory)
        self.assertIn(str(output_directory), completed.stdout)

    def test_relative_output_directory_is_resolved_from_invocation_directory(self) -> None:
        invocation_directory = self.temporary_root / "invocation"
        invocation_directory.mkdir()
        output_directory = invocation_directory / "relative-output"
        completed = self.run_generator(
            invocation_directory,
            "--output-dir",
            "relative-output",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assert_pages_exist(output_directory)
        self.assertIn(str(output_directory), completed.stdout)


if __name__ == "__main__":
    unittest.main()
