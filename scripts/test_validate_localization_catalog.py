#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from validate_localization_catalog import (  # noqa: E402
    SOURCE_LANGUAGE,
    TARGET_LOCALES,
    placeholder_signature,
    validate_catalog,
)


class ValidateLocalizationCatalogTests(unittest.TestCase):
    def test_placeholder_signature_normalizes_positional_arguments(self):
        self.assertEqual(
            placeholder_signature("%lld 张 · %@"),
            placeholder_signature("%2$@ · %1$lld photos"),
        )

    def test_complete_catalog_passes(self):
        localizations = {
            locale: {
                "stringUnit": {
                    "state": "translated",
                    "value": "%1$lld 张照片",
                }
            }
            for locale in TARGET_LOCALES
        }
        result = self.validate(
            {
                "sourceLanguage": "en",
                "strings": {"%lld photos": {"localizations": localizations}},
                "version": "1.0",
            }
        )

        self.assertEqual(result.issues, ())
        self.assertTrue(all(value == 1 for value in result.coverage.values()))

    def test_missing_unreviewed_stale_and_placeholder_mismatch_fail(self):
        localizations = {
            locale: {
                "stringUnit": {
                    "state": "translated",
                    "value": "%@ fotos" if locale == "es" else "%lld 张照片",
                }
            }
            for locale in TARGET_LOCALES
            if locale != "ja"
        }
        localizations["zh-Hans"]["stringUnit"]["state"] = "needs_review"
        result = self.validate(
            {
                "sourceLanguage": "en",
                "strings": {
                    "%lld photos": {"localizations": localizations},
                    "Old text": {"extractionState": "stale"},
                },
                "version": "1.0",
            }
        )

        self.assertTrue(any(issue.startswith("missing:ja:") for issue in result.issues))
        self.assertTrue(any(issue.startswith("unreviewed:zh-Hans:") for issue in result.issues))
        self.assertTrue(any(issue.startswith("placeholder:es:") for issue in result.issues))
        self.assertIn("stale:Old text", result.issues)

    def test_cli_fails_when_coverage_is_zero_of_required_keys(self):
        localizations = {
            locale: {
                "stringUnit": {
                    "state": "unknown",
                    "value": "可用",
                }
            }
            for locale in TARGET_LOCALES
        }

        completed = self.run_cli(
            {
                "sourceLanguage": "en",
                "strings": {"Available": {"localizations": localizations}},
                "version": "1.0",
            }
        )

        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("Localizable.coverage.zh-Hans=0/1", completed.stdout)

    def test_cli_fails_when_localizable_has_zero_required_keys(self):
        completed = self.run_cli(
            {
                "sourceLanguage": "en",
                "strings": {},
                "version": "1.0",
            }
        )

        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("Localizable.required=0", completed.stdout)

    def test_cli_fails_when_translation_state_is_missing(self):
        localizations = {
            locale: {"stringUnit": {"value": "可用"}}
            for locale in TARGET_LOCALES
        }

        completed = self.run_cli(
            {
                "sourceLanguage": "en",
                "strings": {"Available": {"localizations": localizations}},
                "version": "1.0",
            }
        )

        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("state-missing:zh-Hans:Available:stringUnit", completed.stdout)

    def test_cli_fails_when_translation_state_is_unknown(self):
        localizations = {
            locale: {
                "stringUnit": {
                    "state": "translated",
                    "value": "可用",
                }
            }
            for locale in TARGET_LOCALES
        }
        localizations["zh-Hans"]["stringUnit"]["state"] = "mystery"

        completed = self.run_cli(
            {
                "sourceLanguage": "en",
                "strings": {"Available": {"localizations": localizations}},
                "version": "1.0",
            }
        )

        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("state-unknown:zh-Hans:Available:stringUnit:mystery", completed.stdout)

    def test_english_is_the_source_and_not_a_required_translation(self):
        self.assertEqual(SOURCE_LANGUAGE, "en")
        self.assertNotIn("en", TARGET_LOCALES)
        self.assertEqual(
            set(TARGET_LOCALES),
            {"zh-Hans", "es", "ja", "zh-Hant-HK", "zh-Hant-TW"},
        )

    def test_non_english_source_language_fails(self):
        result = self.validate(
            {
                "sourceLanguage": "zh-Hans",
                "strings": {"Available": {"localizations": self.complete_localizations("可用")}},
                "version": "1.0",
            }
        )

        self.assertIn("source-language:zh-Hans", result.issues)

    def test_chinese_key_fails_even_when_every_locale_is_translated(self):
        localizations = self.complete_localizations("可用")
        localizations["en"] = {"stringUnit": {"state": "translated", "value": "Available"}}
        result = self.validate(
            {
                "sourceLanguage": "en",
                "strings": {"可用": {"localizations": localizations}},
                "version": "1.0",
            }
        )

        self.assertIn("source-not-english:可用", result.issues)

    def test_kana_and_hangul_keys_fail_as_non_english_sources(self):
        for key in ("ひらがな", "カタカナ", "한국어"):
            with self.subTest(key=key):
                result = self.validate(
                    {
                        "sourceLanguage": "en",
                        "strings": {key: {"localizations": self.complete_localizations("Available")}},
                        "version": "1.0",
                    }
                )

                self.assertIn(f"source-not-english:{key}", result.issues)

    def test_boolean_substitution_argument_number_fails(self):
        localizations = {}
        for locale in TARGET_LOCALES:
            localizations[locale] = {
                "stringUnit": {"state": "translated", "value": "%#@count@"},
                "substitutions": {
                    "count": {
                        "argNum": True,
                        "formatSpecifier": "lld",
                        "variations": {
                            "plural": {
                                "other": {"stringUnit": {"state": "translated", "value": "%lld photos"}}
                            }
                        },
                    }
                },
            }
        result = self.validate(
            {
                "sourceLanguage": "en",
                "strings": {"%lld photos": {"localizations": localizations}},
                "version": "1.0",
            }
        )

        self.assertIn("substitution-metadata:zh-Hans:%lld photos:count", result.issues)

    def test_explicit_english_value_is_checked_like_a_translation(self):
        localizations = self.complete_localizations("%lld 张照片")
        localizations["en"] = {"stringUnit": {"state": "needs_review", "value": "%@ photos"}}
        result = self.validate(
            {
                "sourceLanguage": "en",
                "strings": {"%lld photos": {"localizations": localizations}},
                "version": "1.0",
            }
        )

        self.assertIn("unreviewed:en:%lld photos:stringUnit:needs_review", result.issues)
        self.assertTrue(any(issue.startswith("placeholder:en:") for issue in result.issues))

    def test_info_plist_key_without_english_fails(self):
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "NSLocalNetworkUsageDescription": {
                    "extractionState": "manual",
                    "localizations": self.complete_localizations("需要访问本地网络。"),
                }
            },
            "version": "1.0",
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "InfoPlist.xcstrings"
            path.write_text(json.dumps(catalog, ensure_ascii=False), encoding="utf-8")
            result = validate_catalog(
                path,
                "InfoPlist",
                require_all_live_keys=False,
                require_source_translation=True,
            )

        self.assertIn("missing:en:NSLocalNetworkUsageDescription", result.issues)
        self.assertIn("coverage:en:0/1", result.issues)

    def test_info_plist_key_with_english_passes(self):
        localizations = self.complete_localizations("需要访问本地网络。")
        localizations["en"] = {
            "stringUnit": {"state": "translated", "value": "Local network access is required."}
        }
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "NSLocalNetworkUsageDescription": {
                    "extractionState": "manual",
                    "localizations": localizations,
                }
            },
            "version": "1.0",
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "InfoPlist.xcstrings"
            path.write_text(json.dumps(catalog, ensure_ascii=False), encoding="utf-8")
            result = validate_catalog(
                path,
                "InfoPlist",
                require_all_live_keys=False,
                require_source_translation=True,
            )

        self.assertEqual(result.issues, ())
        self.assertEqual(result.coverage["en"], 1)

    def test_cli_fails_when_info_plist_key_has_no_english(self):
        completed = self.run_cli(
            {
                "sourceLanguage": "en",
                "strings": {"Available": {"localizations": self.complete_localizations("可用")}},
                "version": "1.0",
            },
            info_plist_locales=TARGET_LOCALES,
        )

        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("InfoPlist.coverage.en=0/1", completed.stdout)
        self.assertIn("InfoPlist:missing:en:NSLocalNetworkUsageDescription", completed.stdout)

    def complete_localizations(self, value: str) -> dict:
        return {
            locale: {"stringUnit": {"state": "translated", "value": value}}
            for locale in TARGET_LOCALES
        }

    def validate(self, catalog: dict):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "Localizable.xcstrings"
            path.write_text(json.dumps(catalog, ensure_ascii=False), encoding="utf-8")
            return validate_catalog(path, "Localizable", require_all_live_keys=True)

    def run_cli(
        self,
        localizable_catalog: dict,
        info_plist_locales: tuple[str, ...] = (SOURCE_LANGUAGE, *TARGET_LOCALES),
    ) -> subprocess.CompletedProcess[str]:
        info_plist_localizations = {
            locale: {
                "stringUnit": {
                    "state": "translated",
                    "value": "Local network access is required.",
                }
            }
            for locale in info_plist_locales
        }
        info_plist_catalog = {
            "sourceLanguage": "en",
            "strings": {
                "NSLocalNetworkUsageDescription": {
                    "extractionState": "manual",
                    "localizations": info_plist_localizations,
                }
            },
            "version": "1.0",
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            catalog_dir = root / "immichSlides"
            catalog_dir.mkdir()
            (catalog_dir / "Localizable.xcstrings").write_text(
                json.dumps(localizable_catalog, ensure_ascii=False),
                encoding="utf-8",
            )
            (catalog_dir / "InfoPlist.xcstrings").write_text(
                json.dumps(info_plist_catalog, ensure_ascii=False),
                encoding="utf-8",
            )
            return subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_DIR / "validate_localization_catalog.py"),
                    "--root",
                    str(root),
                    "--limit",
                    "100",
                ],
                capture_output=True,
                check=False,
                text=True,
            )


if __name__ == "__main__":
    unittest.main()
