#!/usr/bin/env python3
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent

from scan_chinese_strings import bucket_for_hit, extract_string_hits, iter_swift_files  # noqa: E402


class ScanChineseStringsTests(unittest.TestCase):
    def hits(self, source: str, catalog_keys: set[str] | None = None):
        return list(
            extract_string_hits(
                Path("Fixture.swift"),
                source,
                catalog_keys or set(),
            )
        )

    def test_multiline_localized_interpolation_matches_catalog_placeholder(self):
        hits = self.hits(
            'Text(\n    "\\(Int(seconds)) 秒"\n)',
            {"%lld 秒"},
        )

        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0].category, "localized")
        self.assertTrue(hits[0].in_catalog)

    def test_escaped_newline_matches_decoded_catalog_key(self):
        hits = self.hits(
            'LocalizedText.format(\n    "提示：\\n%@",\n    detail\n)',
            {"提示：\n%@"},
        )

        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0].category, "localized")
        self.assertTrue(hits[0].in_catalog)

    def test_preview_and_ui_test_fixture_scopes_are_nonblocking(self):
        source = '''
#Preview {
    Demo(title: "预览标题")
}

func peopleAdjustedForUITesting() {
    let names = ["测试人物"]
}
'''

        hits = self.hits(source)

        self.assertEqual([hit.category for hit in hits], ["preview", "preview"])

    def test_diagnostic_and_internal_enum_literals_are_classified(self):
        source = '''
print("加载日志")
enum Layout: String {
    case grid = "均衡宫格"
}
'''

        hits = self.hits(source)

        self.assertEqual(
            [hit.category for hit in hits],
            ["diagnostic", "internal-identifier"],
        )

    def test_explicit_audit_exclusion_is_classified(self):
        hits = self.hits(
            '// localization-audit: parser-marker 结构标记。\nlet marker = "## 中文"'
        )

        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0].category, "audit-excluded:parser-marker")

    def test_custom_component_string_without_catalog_entry_remains_blocking(self):
        hits = self.hits('CustomRow(title: "真实界面文案")')

        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0].category, "raw-runtime")
        self.assertFalse(hits[0].in_catalog)

    def buckets(self, source: str, catalog_keys: set[str] | None = None) -> list[str | None]:
        hits = extract_string_hits(Path("Fixture.swift"), source, catalog_keys or set(), require_han=False)
        return [bucket_for_hit(hit) for hit in hits]

    def test_english_ui_text_missing_from_the_catalog_is_reported(self):
        self.assertEqual(self.buckets('Text("Start Slideshow")'), ["localized-missing"])

    def test_english_ui_text_in_the_catalog_is_not_reported(self):
        self.assertEqual(self.buckets('Text("Start Slideshow")', {"Start Slideshow"}), [None])

    def test_accessibility_label_is_checked_like_visible_text(self):
        self.assertEqual(self.buckets('view.accessibilityLabel("Close")'), ["localized-missing"])

    def test_call_name_that_only_ends_in_button_is_not_a_localized_context(self):
        self.assertEqual(self.buckets('keypadButton("Clear")'), [None])

    def test_ui_text_in_any_script_missing_from_the_catalog_is_reported(self):
        source = 'Text("キャンセル")\nText("Привет")\nText("É")'
        self.assertEqual(self.buckets(source), ["localized-missing"] * 3)

    def test_literal_without_words_needs_no_translation(self):
        self.assertEqual(self.buckets('Text("\\(count)")\nText("0")\nText("·")'), [None, None, None])

    def test_audit_comment_excludes_english_literal(self):
        source = '// localization-audit: ui-test-probe\nText("flush")'
        self.assertEqual(self.buckets(source), ["audit-excluded"])

    def test_raw_english_literal_outside_ui_calls_is_not_reported(self):
        self.assertEqual(self.buckets('let identifier = "settings.item.server"'), [None])

    def test_include_tests_scans_both_test_targets(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for relative in ("immichSlides/App.swift", "immichSlidesTests/A.swift", "immichSlidesUITests/B.swift"):
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_text("", encoding="utf-8")

            without_tests = {path.name for path in iter_swift_files(root, include_tests=False)}
            with_tests = {path.name for path in iter_swift_files(root, include_tests=True)}

        self.assertEqual(without_tests, {"App.swift"})
        self.assertEqual(with_tests, {"App.swift", "A.swift", "B.swift"})


if __name__ == "__main__":
    unittest.main()
