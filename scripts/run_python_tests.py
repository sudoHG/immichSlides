#!/usr/bin/env python3
"""Run the existing Python suite and export discovered and observed identities."""

from __future__ import annotations

import argparse
import json
import sys
import time
import unittest
from pathlib import Path

from ci_summary import observation, test_identity


def test_cases(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from test_cases(test)
        else:
            yield test


class RecordingResult(unittest.TextTestResult):
    def __init__(self, *args, fixture_members, **kwargs):
        super().__init__(*args, **kwargs)
        self.observed = []
        self.current = None
        self.fixture_members = fixture_members

    def startTest(self, test):
        super().startTest(test)
        self.current = test
        self.started = time.monotonic()
        self.outcome = "not-run"
        self.reason = None
        self.skip_reasons = []
        self.message = None

    def addSuccess(self, test):
        super().addSuccess(test)
        if self.outcome == "not-run":
            self.outcome = "passed"

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.outcome = "failed"
        self.message = f"{test.id()}: {err[0].__name__}"

    def addError(self, test, err):
        super().addError(test, err)
        if self.current is None:
            self.observed.append(observation(test_identity("python", test.id()), "failed", 0,
                                             message=f"{test.id()}: {err[0].__name__}", exit_code=None))
            return
        self.outcome = "failed"
        self.message = f"{test.id()}: {err[0].__name__}"

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            self.outcome = "failed"
            message = f"{subtest.id()}: {err[0].__name__}: {err[1]}"
            self.message = "; ".join(filter(None, (self.message, message)))

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        reason = reason or "No skip reason provided by unittest"
        if self.current is None:
            for identity in self.fixture_members.get(test.id(), []):
                self.observed.append(observation(identity, "skipped", 0, reason=reason, exit_code=None))
            return
        if self.outcome != "failed":
            self.outcome = "skipped"
        self.skip_reasons.append(reason if test is self.current else f"{test.id()}: {reason}")
        self.reason = "; ".join(self.skip_reasons)

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self.outcome = "failed"
        self.message = f"{test.id()}: expected failure is not an explicit pass"

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self.outcome = "failed"
        self.message = f"{test.id()}: unexpected success"

    def stopTest(self, test):
        self.observed.append(observation(test_identity("python", test.id()), self.outcome,
                                         round(time.monotonic() - self.started, 6), reason=self.reason,
                                         message=self.message, exit_code=0 if self.outcome == "passed" else None))
        super().stopTest(test)
        self.current = None


def run_suite(suite, stream):
    # Snapshot discovery before unittest consumes the suite or skips a fixture's members.
    cases = list(test_cases(suite))
    compiled = [test_identity("python", test.id()) for test in cases]
    fixture_members = {}
    for test, identity in zip(cases, compiled):
        cls = type(test)
        for fixture in (f"setUpClass ({cls.__module__}.{cls.__qualname__})", f"setUpModule ({cls.__module__})"):
            fixture_members.setdefault(fixture, []).append(identity)

    def result_class(*args, **kwargs):
        return RecordingResult(*args, fixture_members=fixture_members, **kwargs)

    result = unittest.TextTestRunner(stream=stream, verbosity=1, resultclass=result_class).run(suite)
    observed_keys = {entry["identity"]["key"] for entry in result.observed}
    for identity in compiled:
        if identity["key"] not in observed_keys:
            result.observed.append(observation(identity, "not-run", 0, exit_code=None,
                                               message="Discovered test was not executed"))
    # Preserve environment skips, but an expected failure is still failed coverage.
    successful = bool(compiled) and result.wasSuccessful() and not result.expectedFailures
    payload = {"compiled": compiled, "observed": result.observed, "exit_code": 0 if successful else 1}
    return payload, payload["exit_code"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.discover(str(Path(__file__).resolve().parent), pattern="test_*.py")
    payload, code = run_suite(suite, sys.stderr)
    args.output.write_text(json.dumps(payload, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
