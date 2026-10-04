#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from clean_stale_catalog_entries import source_hits_for_key  # noqa: E402


class CleanStaleCatalogEntriesTests(unittest.TestCase):
    def test_comments_and_longer_literals_do_not_count_as_exact_source_hits(self):
        path = Path("Fixture.swift")
        sources = {
            path: '// 复用“图片加载中...”提示\nText("图片加载中，请稍候")\n'
        }

        self.assertEqual(source_hits_for_key("图片加载中...", sources), [])

    def test_exact_swift_string_literal_counts_as_source_hit(self):
        path = Path("Fixture.swift")
        sources = {path: 'Text("图片加载中...")\n'}

        self.assertEqual(source_hits_for_key("图片加载中...", sources), [path])

    def test_exact_non_chinese_string_literal_is_also_preserved(self):
        path = Path("Fixture.swift")
        sources = {path: 'Text("Need Help?")\n'}

        self.assertEqual(source_hits_for_key("Need Help?", sources), [path])


if __name__ == "__main__":
    unittest.main()
