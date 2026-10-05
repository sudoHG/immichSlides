"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations

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

PINNED_CHECKOUT = "11d5960a326750d5838078e36cf38b85af677262 # v4.4.0"


class RepositoryPrivacyContractTestsCases:
    def test_trusted_workflow_executes_only_base_scanner(self) -> None:
        workflow = TRUSTED_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("pull_request_target:", workflow)
        trigger_line = next(
            line.strip()
            for line in workflow.splitlines()
            if line.strip().startswith("types:")
        )
        self.assertIn("edited", trigger_line)
        self.assertEqual(workflow.count("uses: actions/checkout@"), 1)
        self.assertIn(f"uses: actions/checkout@{PINNED_CHECKOUT}", workflow)
        self.assertIn(
            "ref: ${{ github.event.pull_request.base.sha }}",
            workflow,
        )
        self.assertIn(
            "run: scripts/run_trusted_privacy_preflight.sh",
            workflow,
        )
        self.assertNotIn(
            "ref: ${{ github.event.pull_request.head.sha }}",
            workflow,
        )
        self.assertNotIn("git checkout ", workflow)
        self.assertNotIn("git switch ", workflow)
        self.assertNotIn("git reset ", workflow)
        self.assertNotIn("git worktree ", workflow)
        self.assertNotIn("python3 scripts/git_privacy_gate.py", workflow)


    def test_trusted_runner_keeps_base_scanner_when_head_replaces_it(
        self,
    ) -> None:
        self.assertTrue(TRUSTED_RUNNER.is_file())
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory) / "trusted-runner"
            repository.mkdir()

            def git(*arguments: str) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    ["git", *arguments],
                    cwd=repository,
                    check=True,
                    capture_output=True,
                    text=True,
                )

            git("init", "-b", "main")
            git("config", "user.name", "Trusted Runner Test")
            git("config", "user.email", "trusted-runner@example.invalid")
            scripts_directory = repository / "scripts"
            scripts_directory.mkdir()
            shutil.copy2(
                TRUSTED_RUNNER,
                scripts_directory / TRUSTED_RUNNER.name,
            )
            (scripts_directory / "test_git_privacy_gate.py").write_text(
                "raise SystemExit(0)\n",
                encoding="utf-8",
            )
            marker_path = Path(temporary_directory) / "runner-marker"
            scanner_path = scripts_directory / SCRIPT.name
            scanner_path.write_text(
                (
                    "import os\n"
                    "from pathlib import Path\n"
                    "Path(os.environ['TRUST_MARKER']).write_text("
                    "'base', encoding='utf-8')\n"
                ),
                encoding="utf-8",
            )
            git("add", "-A")
            git("commit", "-m", "trusted base implementation")
            base_oid = git("rev-parse", "HEAD").stdout.strip()
            scanner_path.write_text(
                (
                    "import os\n"
                    "from pathlib import Path\n"
                    "Path(os.environ['TRUST_MARKER']).write_text("
                    "'head', encoding='utf-8')\n"
                ),
                encoding="utf-8",
            )
            git("add", "-A")
            git("commit", "-m", "candidate replacement")
            head_oid = git("rev-parse", "HEAD").stdout.strip()
            git("checkout", "--detach", base_oid)
            environment = os.environ.copy()
            environment.update(
                {
                    "PRIVACY_BASE_SHA": base_oid,
                    "PRIVACY_HEAD_SHA": head_oid,
                    "TRUST_MARKER": str(marker_path),
                }
            )

            result = subprocess.run(
                [str(scripts_directory / TRUSTED_RUNNER.name)],
                cwd=repository,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(
                result.returncode,
                0,
                msg=f"stdout={result.stdout}\nstderr={result.stderr}",
            )
            self.assertEqual(marker_path.read_text(encoding="utf-8"), "base")
            self.assertEqual(git("rev-parse", "HEAD").stdout.strip(), base_oid)


    def test_contributing_marks_trusted_check_as_post_merge_boundary(self) -> None:
        contributing = CONTRIBUTING.read_text(encoding="utf-8")

        self.assertIn("trusted only for subsequent pull requests after it is merged into `main`", contributing)
        self.assertIn("from the PR's base commit, never from the candidate tree", contributing)
        self.assertIn("not a substitute for the trusted check", contributing)


    def test_bootstrap_check_has_distinct_nontrusted_name(self) -> None:
        workflow = BOOTSTRAP_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("pull_request:", workflow)
        self.assertIn("name: privacy-preflight-bootstrap", workflow)
        self.assertNotIn("name: privacy-preflight-trusted", workflow)
        self.assertEqual(workflow.count("uses: actions/checkout@"), 1)
        self.assertIn(f"uses: actions/checkout@{PINNED_CHECKOUT}", workflow)


    def test_playback_transition_evidence_uses_private_directory_resolver(self) -> None:
        source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in [
                SMART_FILL_UI_TESTS,
                *sorted(SMART_FILL_UI_TESTS.parent.glob(f"{SMART_FILL_UI_TESTS.stem}+*.swift")),
            ]
        )
        start = source.index("func playbackTransitionEvidenceDirectory()")
        end = source.index("\n    func waitUntil(", start)
        implementation = source[start:end]

        self.assertIn("PrivateEvidenceDirectory.resolve(", implementation)
        self.assertNotIn("URL(fileURLWithPath:", implementation)
