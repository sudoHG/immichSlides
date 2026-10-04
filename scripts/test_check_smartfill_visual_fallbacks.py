#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "check_smartfill_visual_fallbacks.py"


class SmartFillVisualFallbackCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp_dir.name)
        self._run(["git", "init", "-q"], cwd=self.repo)
        self._run(["git", "config", "user.email", "smartfill-guardrail@example.invalid"], cwd=self.repo)
        self._run(["git", "config", "user.name", "SmartFill Guardrail"], cwd=self.repo)
        self._write("immichSlides/Shared/Component/SlideItemView.swift", "Image(uiImage: image).scaledToFit()\\n")
        self._write("immichSlides/Shared/Component/SmartFillSceneView.swift", "struct SmartFillSceneView {}\\n")
        self._write("immichSlides/Shared/Model/PlaybackSmartFillPlanner.swift", "struct PlannerBaseline {}\\n")
        self._write("docs/ARCHITECTURE.md", "safeFullDisplay is forbidden in production diff\\n")
        self._run(["git", "add", "."], cwd=self.repo)
        self._run(["git", "commit", "-q", "-m", "baseline"], cwd=self.repo)
        self.base_ref = self._run(["git", "rev-parse", "HEAD"], cwd=self.repo).stdout.strip()
        self._run(["git", "update-ref", "refs/remotes/origin/main", self.base_ref], cwd=self.repo)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_records_baseline_forbidden_hits_without_failing_clean_diff(self):
        result = self._guardrail()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("guardrail_check_status=PASS", result.stdout)
        self.assertIn("forbidden_visual_diff_production_hits=0", result.stdout)
        self.assertIn("forbidden_visual_baseline_allowed_hits=", result.stdout)

    def test_defaults_to_public_main_branch(self):
        result = self._guardrail(use_default_base_ref=True)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("guardrail_check_status=PASS", result.stdout)

    def test_fails_when_diff_adds_safe_full_display_to_production(self):
        self._write("immichSlides/Shared/Model/PlaybackSmartFillPlanner.swift", "let mode = \"safeFullDisplay\"\\n")

        result = self._guardrail()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("guardrail_check_status=FAIL", result.stdout)
        self.assertIn("forbidden_visual_diff_production_hits=1", result.stdout)
        self.assertIn("safeFullDisplay", result.stdout)
        self.assertIn("diffProductionHit=immichSlides/Shared/Model/PlaybackSmartFillPlanner.swift:1:", result.stdout)

    def test_fails_when_diff_adds_fit_blurred_background_to_production(self):
        self._write("immichSlides/Shared/Model/PlaybackSmartFillPlanner.swift", "let mode = \"fit-blurred-background\"\\n")

        result = self._guardrail()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("forbidden_visual_diff_production_hits=1", result.stdout)
        self.assertIn("fit-blurred-background", result.stdout)

    def test_fails_when_diff_adds_scaled_to_fit_slot_to_production(self):
        self._write("immichSlides/Shared/Model/PlaybackSmartFillPlanner.swift", "Image(uiImage: image).scaledToFit()\\n")

        result = self._guardrail()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("forbidden_visual_diff_production_hits=1", result.stdout)
        self.assertIn("scaledToFit", result.stdout)

    def test_fails_when_renderer_file_has_any_production_diff(self):
        self._write("immichSlides/Shared/Component/SmartFillSceneView.swift", "struct SmartFillSceneView { let changed = true }\\n")

        result = self._guardrail()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("smartfill_renderer_diff_empty=FAIL", result.stdout)

    def test_allows_forbidden_words_in_docs_and_negative_fixtures(self):
        self._write("docs/ARCHITECTURE.md", "safeFullDisplay and fit-blurred-background stay documented\\n")
        self._write("TestSupport/SmartFillVisualFallbackFixtures/safeFullDisplay.swift", "let forbidden = \"safeFullDisplay\"\\n")

        result = self._guardrail()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("forbidden_visual_allowed_hits=", result.stdout)
        self.assertIn("allowedHit=docs/ARCHITECTURE.md:", result.stdout)
        self.assertIn("forbidden_visual_diff_production_hits=0", result.stdout)

    def _guardrail(self, *, use_default_base_ref=False):
        command = [sys.executable, str(SCRIPT), "--repo-root", str(self.repo)]
        if not use_default_base_ref:
            command.extend(["--base-ref", self.base_ref])
        return subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
        )

    def _write(self, relative_path, content):
        path = self.repo / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def _run(self, args, cwd):
        return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=True)


if __name__ == "__main__":
    unittest.main()
