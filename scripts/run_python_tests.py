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


def test_ids(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from test_ids(test)
        else:
            yield test.id()


class RecordingResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.observed = []
        self.current = None

    def startTest(self, test):
        super().startTest(test)
        self.current = test
        self.started = time.monotonic()
        self.outcome = "not-run"
        self.reason = None
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
            self.message = f"{test.id()}: subtest {err[0].__name__}"

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        if self.current is None:
            self.observed.append(observation(test_identity("python", test.id()), "skipped", 0,
                                             reason=reason, exit_code=None))
            return
        if self.outcome != "failed":
            self.outcome = "skipped"
        self.reason = reason or "No skip reason provided by unittest"

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
    compiled = [test_identity("python", key) for key in test_ids(suite)]
    result = unittest.TextTestRunner(stream=stream, verbosity=1, resultclass=RecordingResult).run(suite)
    observed_keys = {entry["identity"]["key"] for entry in result.observed}
    for identity in compiled:
        if identity["key"] not in observed_keys:
            result.observed.append(observation(identity, "not-run", 0, exit_code=None,
                                               message="Discovered test was not executed"))
    # No policy authorizes Python skips at this seam. Empty/missing results fail closed.
    passed = bool(compiled) and len(compiled) == len(result.observed) and all(
        entry["outcome"] == "passed" for entry in result.observed)
    payload = {"compiled": compiled, "observed": result.observed, "exit_code": 0 if passed else 1}
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
