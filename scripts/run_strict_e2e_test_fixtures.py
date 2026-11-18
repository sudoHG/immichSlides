"""Shared fixtures for retained smoke, export, scanner and reset tests."""
from __future__ import annotations

import io
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from run_strict_e2e import CommandError, PRIVATE_RESULT_BUNDLE_ROOT, WRONG_PUBLIC_API_KEY, choose_exit_code, make_test_environment, prepare_evidence_directory, prepare_private_result_bundle_path, read_source_sha, reset_simulator_app, run_cleanup_actions, run_command, write_case_manifest, write_fixture_artifacts, write_sensitive_scan
from run_offline_unit_tests import TestResultsSummary
from sensitive_scan_test_support import compressed_byte_coincidence
from strict_e2e_runner_support import simulator_app_container

SCRIPT_DIR = Path(__file__).resolve().parent

REPO_ROOT = SCRIPT_DIR.parent
