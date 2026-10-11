"""Missing suite prerequisites must fail, never skip coverage."""

import contextlib
import io
import unittest
from unittest import mock

import check_required_test_tools


class RequiredTestToolsTests(unittest.TestCase):
    def test_portable_partition_requires_all_portable_tools_and_leaves_swift_to_macos(self):
        for missing in (None, "swift", "zstd", "PIL", "yaml"):
            with self.subTest(missing=missing), mock.patch.object(
                    check_required_test_tools.shutil, "which", side_effect=lambda key: None if key == missing else "/tool"), \
                    mock.patch.object(check_required_test_tools.importlib.util, "find_spec",
                                      side_effect=lambda key: None if key == missing else object()):
                self.assertEqual(len(check_required_test_tools.missing_tools(portable=True)),
                                 0 if missing in (None, "swift") else 1)

    def test_all_required_tools_are_checked(self):
        with mock.patch.object(check_required_test_tools.shutil, "which", return_value="/tool") as which, mock.patch.object(
            check_required_test_tools.importlib.util, "find_spec", return_value=object()
        ):
            self.assertEqual(check_required_test_tools.missing_tools(), [])
        self.assertEqual(which.call_args_list, [mock.call("swift"), mock.call("zstd")])

    def test_missing_tools_fail_with_actionable_diagnostics(self):
        output = io.StringIO()
        with mock.patch.object(check_required_test_tools.shutil, "which", return_value=None), mock.patch.object(
            check_required_test_tools.importlib.util, "find_spec", return_value=None
        ), contextlib.redirect_stderr(output):
            self.assertEqual(check_required_test_tools.main(), 1)
        for prerequisite in ["Swift", "zstd", "Pillow", "PyYAML"]:
            self.assertIn(prerequisite, output.getvalue())

    def test_each_missing_tool_is_a_failure(self):
        for tool in ["swift", "zstd", "PIL", "yaml"]:
            with self.subTest(tool=tool), mock.patch.object(
                check_required_test_tools.shutil, "which", side_effect=lambda name: None if name == tool else "/tool"
            ), mock.patch.object(check_required_test_tools.importlib.util, "find_spec",
                                 side_effect=lambda name: None if name == tool else object()):
                self.assertEqual(len(check_required_test_tools.missing_tools()), 1)
