#!/usr/bin/env python3
"""Narrow entry runner: host checks and refusing device execution."""

from __future__ import annotations

import io
import json
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent

import run_album_server_narrow  # noqa: E402


class AlbumServerRunnerTests(unittest.TestCase):
    def test_host_check_passes_without_device(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            exit_code = run_album_server_narrow.main(["--host-check"])
        self.assertEqual(exit_code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["official_cases"], 15)
        self.assertTrue(payload["empty_album"])
        self.assertFalse(payload["device_run"])

    def test_execute_device_is_rejected_in_stage_3(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            exit_code = run_album_server_narrow.main(["--execute-device"])
        self.assertEqual(exit_code, 2)
        self.assertIn("does not run devices", stderr.getvalue())

    def test_print_command_contains_selector(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            exit_code = run_album_server_narrow.main(["--print-command", "--case-id", "2"])
        self.assertEqual(exit_code, 0)
        self.assertIn("testTargetAlbumPlaysAndEmptyAlbumShowsEmptyResult", stdout.getvalue())
        self.assertIn("-only-testing:", stdout.getvalue())

    def test_server_switch_print_command_uses_suite_runner_not_bare_xcodebuild(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            exit_code = run_album_server_narrow.main(["--print-command", "--case-id", "3"])
        self.assertEqual(exit_code, 0)
        text = stdout.getvalue()
        self.assertIn("scripts/run_strict_e2e.py", text)
        self.assertIn("server-switch-display", text)
        self.assertNotIn("xcodebuild", text)


if __name__ == "__main__":
    unittest.main()
