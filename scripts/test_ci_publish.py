"""Protect the isolated immediate-base classification and host reader."""
import json
import unittest
from pathlib import Path
from unittest.mock import patch
from ci_publish_git import BASE_MODULES, OPTIONAL_BASE_MODULES, base_reader, revision_modules
from ci_summary import ContractError, test_identity
from run_host_checks import HOST_CHECKS


class PublisherTests(unittest.TestCase):
    def test_base_reader_carries_same_revision_dependencies_and_tolerates_older_bases(self):
        root = Path(__file__).parent
        modules = {name: (root / name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
        def blob(revision, path):
            self.assertEqual(revision, "a" * 40)
            return modules[path.removeprefix("scripts/")]
        with patch("ci_publish_git.git", side_effect=lambda *args: args[-1]), patch("ci_publish_git.read_blob", side_effect=blob):
            self.assertEqual(revision_modules("a" * 40), modules)
        with patch("ci_publish_git.git", return_value=""), patch("ci_publish_git.read_blob", side_effect=blob):
            self.assertEqual(set(revision_modules("a" * 40)), set(BASE_MODULES))

    def test_base_reader_enumerates_candidate_text_without_executing_candidate_verdict_code(self):
        root = Path(__file__).parent
        modules = {name: (root / name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
        payload = {"operation": "classify", "sources": {"scripts/ci_verdict.py": 'raise RuntimeError("candidate verdict executed")'},
                   "paths": ["scripts/ci_verdict.py"], "build_target_paths": [],
                   "classification_policy": {"schema_version": 1, "app_unaffected": ["docs/**"], "ci_trusted": ["scripts/ci_*.py"]}}
        result = base_reader(modules, payload)
        self.assertTrue(result["ci_changing"])
        population = [test_identity("host", name) for name, _ in HOST_CHECKS]
        parts = base_reader(modules, {"operation": "host", "population": population})
        self.assertEqual(parts["host-macos"], [test_identity("host", "swift-format lint")])
        self.assertEqual(len(parts["host-linux"]) + len(parts["host-macos"]), len(population))
        for changes in ({"paths": ["../private"]}, {"classification_policy": {}}, {"operation": "unknown"}):
            with self.subTest(changes=changes), self.assertRaises(ContractError):
                base_reader(modules, dict(payload, **changes))
        with self.assertRaises(ContractError):
            base_reader(modules, {"operation": "host", "population": population[:-1]})
