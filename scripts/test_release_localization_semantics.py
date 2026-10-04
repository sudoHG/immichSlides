#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from validate_localization_catalog import SOURCE_LANGUAGE  # noqa: E402

CATALOG_PATH = ROOT / "immichSlides" / "Localizable.xcstrings"


class ReleaseLocalizationSemanticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.strings = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))["strings"]

    def value(self, key: str, locale: str) -> str:
        localizations = self.strings[key]["localizations"]
        if locale == SOURCE_LANGUAGE and locale not in localizations:
            # The source language renders the key itself when it has no explicit value.
            return key
        return localizations[locale]["stringUnit"]["value"]

    def test_release_reachable_hong_kong_strings_are_localized(self):
        expected = {
            "Filtered Playback is selected, but no filters are set up yet.": "目前為「篩選播放」，但尚未設定篩選條件。",
            "Filtered Playback is on, but no filters are configured yet.": "目前為「篩選播放」，但尚未設定篩選條件。",
            "No filters are selected yet. Choose an album or person first.": "目前尚未選擇篩選條件，請先選擇相簿或人物。",
            "Manage playback, access protection, server connection, and cache in one workspace designed for the remote.": "將播放器、存取保護、伺服器連線及快取管理集中在同一個適合遙控器操作的工作區。",
            "Filter the photos to show by album and person.": "按相簿、人物等方式篩選要輪播的相片",
            "Press Select to toggle selection, and Play/Pause to toggle solo mode.": "按選擇鍵切換選取狀態，按播放／暫停鍵切換單人模式",
            "Before reporting an issue, confirm the version and platform first.": "提交問題前，建議先確認版本號碼及運行平台。",
            "Unable to load people list. Check your network or server settings.": "未能載入人物列表，請檢查網絡或伺服器設定",
            "Normal Mode · Includes group photos": "一般模式 · 合照和單人相片都會顯示",
            "The server URL is not a valid Immich API entry point. It may be missing the correct port or reverse proxy path.": "伺服器位址並非有效的 Immich API 入口，可能欠缺正確的連接埠或反向代理設定",
        }

        for key, value in expected.items():
            with self.subTest(key=key):
                self.assertEqual(self.value(key, "zh-Hant-HK"), value)

    def test_people_and_album_counts_have_english_and_spanish_plural_substitutions(self):
        cases = {
            "%lld people · %lld photos": {
                "en": ("person", "people", "photo", "photos"),
                "es": ("persona", "personas", "foto", "fotos"),
            },
            "%lld albums · %lld photos": {
                "en": ("album", "albums", "photo", "photos"),
                "es": ("álbum", "álbumes", "foto", "fotos"),
            },
        }

        for key, locales in cases.items():
            for locale, words in locales.items():
                with self.subTest(key=key, locale=locale):
                    localization = self.strings[key]["localizations"][locale]
                    self.assertEqual(
                        localization["stringUnit"]["value"],
                        "%#@primary@ · %#@photos@",
                    )
                    substitutions = localization["substitutions"]
                    self.assertEqual(substitutions["primary"]["argNum"], 1)
                    self.assertEqual(substitutions["photos"]["argNum"], 2)
                    primary_plural = substitutions["primary"]["variations"]["plural"]
                    photo_plural = substitutions["photos"]["variations"]["plural"]
                    self.assertEqual(primary_plural["one"]["stringUnit"]["value"], f"%1$lld {words[0]}")
                    self.assertEqual(primary_plural["other"]["stringUnit"]["value"], f"%1$lld {words[1]}")
                    self.assertEqual(photo_plural["one"]["stringUnit"]["value"], f"%2$lld {words[2]}")
                    self.assertEqual(photo_plural["other"]["stringUnit"]["value"], f"%2$lld {words[3]}")

    def test_accessibility_and_japanese_step_translations_are_semantic(self):
        for locale in ("zh-Hant-HK", "zh-Hant-TW"):
            with self.subTest(locale=locale):
                self.assertEqual(self.value("play", locale), "播放")
                self.assertEqual(self.value("focused", locale), "已聚焦")
                self.assertEqual(self.value("notFocused", locale), "未聚焦")

        self.assertEqual(
            self.value("Step %lld of %lld", "ja"),
            "全%2$lldステップ中、%1$lldステップ目",
        )

    def test_entry_hints_use_complete_locale_aware_templates(self):
        expected = {
            "Tap %@ to hide this tip": {
                "en": "Tap %@ to hide this tip",
                "es": "Toca %@ para ocultar este consejo",
                "ja": "%@をタップしてヒントを閉じます",
                "zh-Hant-HK": "點一下%@以隱藏提示",
                "zh-Hant-TW": "點一下%@以隱藏提示",
            },
            "Press %@ to hide this tip": {
                "en": "Press %@ to hide this tip",
                "es": "Pulsa %@ para ocultar este consejo",
                "ja": "%@を押すとヒントが閉じます",
                "zh-Hant-HK": "按%@以隱藏提示",
                "zh-Hant-TW": "按%@以隱藏提示",
            },
        }

        for key, translations in expected.items():
            for locale, value in translations.items():
                with self.subTest(key=key, locale=locale):
                    self.assertEqual(self.value(key, locale), value)

    def test_render_failure_message_tells_the_user_how_to_recover(self):
        key = "The slideshow failed to load. Go back, then reopen the slideshow."
        expected = {
            "en": "The slideshow failed to load. Go back, then reopen the slideshow.",
            "es": "No se pudo cargar la presentación. Vuelve atrás y abre de nuevo la presentación.",
            "ja": "スライドショーを読み込めませんでした。前の画面に戻り、もう一度再生画面を開いてください。",
            "zh-Hant-HK": "播放畫面載入失敗。請返回上一頁，然後重新進入播放畫面。",
            "zh-Hant-TW": "播放畫面載入失敗。請返回上一頁，然後重新進入播放畫面。",
        }

        self.assertNotIn("播放画面加载失败，请重试。", self.strings)
        for locale, value in expected.items():
            with self.subTest(locale=locale):
                self.assertEqual(self.value(key, locale), value)

    def test_spanish_single_photo_mode_uses_one_consistent_term(self):
        self.assertEqual(self.value("Single Photo Mode", "es"), "Modo de foto única")
        self.assertEqual(
            self.value("Choose whether the slideshow uses Smart Fill or Single Photo Mode.", "es"),
            "Elige si la presentación usa Relleno inteligente o el modo de foto única.",
        )


if __name__ == "__main__":
    unittest.main()
