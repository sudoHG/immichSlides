import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "check_all.sh"

STUB = """#!/bin/sh
echo "$(basename "$0") $*" >> "$STUB_LOG"
if [ -n "$STUB_FAIL_MATCH" ]; then
    case "$*" in
    *"$STUB_FAIL_MATCH"*) exit 3 ;;
    esac
fi
case "$*" in
*scripts/run_host_checks.py*)
    while [ "$#" -gt 1 ]; do
        if [ "$1" = "--output-dir" ]; then
            mkdir -p "$2"
            printf '%s\\n' 'Fixture host table' > "$2/summary.md"
            break
        fi
        shift
    done
    ;;
esac
exit 0
"""


class CheckAllTests(unittest.TestCase):
    """Runs check_all.sh in a scratch repo with stubbed tools, isolating command order and failure propagation."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.repo = self.tmp / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copy(SCRIPT, self.repo / "scripts" / "check_all.sh")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name in ("xcrun", "python3"):
            stub = bin_dir / name
            stub.write_text(STUB)
            stub.chmod(0o755)
        self.log = self.tmp / "calls.log"
        self.env = dict(os.environ)
        self.env["PATH"] = f"{bin_dir}{os.pathsep}{self.env['PATH']}"
        self.env["STUB_LOG"] = str(self.log)
        self.env.pop("STUB_FAIL_MATCH", None)
        self.env.pop("PYTHON", None)

    def run_check_all(self, *args, fail_match=None):
        env = dict(self.env)
        if fail_match:
            env["STUB_FAIL_MATCH"] = fail_match
        return subprocess.run(
            ["bash", str(self.repo / "scripts" / "check_all.sh"), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_help_prints_usage_and_runs_nothing(self):
        result = self.run_check_all("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage: scripts/check_all.sh", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_unknown_argument_is_usage_error(self):
        result = self.run_check_all("--bogus")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown argument", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_unit_tests_require_destinations_and_output_dir(self):
        out = self.tmp / "out"
        cases = [
            ("--with-unit-tests", "--tvos-destination", "t", "--output-dir", str(out)),
            ("--with-unit-tests", "--ios-destination", "i", "--output-dir", str(out)),
            ("--with-unit-tests", "--ios-destination", "i", "--tvos-destination", "t"),
            ("--with-unit-tests", "--ios-destination"),
        ]
        for args in cases:
            with self.subTest(args=args):
                result = self.run_check_all(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])

    def test_output_dir_inside_repository_is_rejected(self):
        result = self.run_check_all(
            "--with-unit-tests",
            "--ios-destination", "i",
            "--tvos-destination", "t",
            "--output-dir", str(self.repo / "results"),
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("outside the repository", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_destination_without_unit_test_flag_is_rejected(self):
        result = self.run_check_all("--ios-destination", "i")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_shared_host_checks_pass_and_xcode_tests_are_reported_skipped(self):
        for output in (None, self.tmp / "host-output"):
            with self.subTest(output=output):
                self.log.unlink(missing_ok=True)
                args = ("--output-dir", str(output)) if output else ()
                result = self.run_check_all(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = self.calls()
                self.assertEqual(len(calls), 1)
                self.assertIn("scripts/run_host_checks.py", calls[0])
                self.assertIn("Fixture host table", result.stdout)
                self.assertIn("Xcode unit tests were skipped", result.stdout)
                self.assertIn("RESULT: PASS", result.stdout)
                records = Path(calls[0].split("--output-dir ", 1)[1].split()[0])
                if output:
                    self.assertTrue((records / "summary.md").is_file())
                    self.assertEqual(self.run_check_all(*args).returncode, 2)
                    self.assertEqual(len(self.calls()), 1)
                else:
                    self.assertIn("--no-summary-path", calls[0])
                    self.assertNotIn("immichslides-check-all.", result.stdout)
                    self.assertFalse(records.exists())

    def test_failing_host_checks_fail_the_run(self):
        result = self.run_check_all(fail_match="run_host_checks.py")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: host checks (exit 3", result.stdout)
        self.assertIn("RESULT: FAIL (1 step(s) failed)", result.stdout)
        self.assertEqual(len(self.calls()), 1)

    def test_unit_tests_run_for_both_platforms_with_bundles_in_output_dir(self):
        selected = self.tmp / "venv-python"
        selected.write_text(STUB)
        selected.chmod(0o755)
        for override in (None, str(selected)):
            with self.subTest(interpreter=override):
                out = self.tmp / ("overridden-output" if override else "default-output")
                self.log.unlink(missing_ok=True)
                if override:
                    self.env["PYTHON"] = override
                result = self.run_check_all(
                    "--with-unit-tests",
                    "--ios-destination", "platform=iOS Simulator,id=X",
                    "--tvos-destination", "platform=tvOS Simulator,id=Y",
                    "--output-dir", str(out),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = self.calls()
                self.assertEqual(len(calls), 3)
                self.assertTrue(all(call.startswith("venv-python " if override else "python3 ") for call in calls))
                self.assertIn(f"--output-dir {out.resolve()}/host-records", calls[0])
                self.assertNotIn("--no-summary-path", calls[0])
                runner_calls = [c for c in calls if "run_offline_unit_tests.py" in c]
                self.assertEqual(len(runner_calls), 2)
                self.assertIn("--platform ios", runner_calls[0])
                self.assertIn("--platform tvos", runner_calls[1])
                for call in runner_calls:
                    self.assertIn(f"--result-bundle-path {out.resolve()}/", call)
                    self.assertIn("--derived-data-path .derivedData/check-all-", call)
                    self.assertNotIn("--timeout-minutes", call)
                self.assertNotIn("Xcode unit tests were skipped", result.stdout)

    def test_unit_test_failure_propagates(self):
        result = self.run_check_all(
            "--with-unit-tests",
            "--ios-destination", "i",
            "--tvos-destination", "t",
            "--output-dir", str(self.tmp / "out"),
            fail_match="--platform tvos",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: xcode unit tests (tvOS)", result.stdout)


if __name__ == "__main__":
    unittest.main()
