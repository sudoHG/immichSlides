#!/usr/bin/env python3
"""Every UI test the default test plans leave out must still run somewhere.

A test left out of a platform's default plan is only allowed when that platform's Evidence plan
selects it or a runner suite reachable from the command line runs it on that platform. Anything else
would silently never run. Known gaps are listed in KNOWN_UNCOVERED, which may only shrink.

The check fails closed: a plan entry or runner selector that does not resolve to a zero-argument
XCTest method compiled for that platform is an error, and so is a test method that belongs to no
XCTestCase class.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent

import run_access_lifecycle_tvos  # noqa: E402
import run_access_lifecycle_ios  # noqa: E402
import run_strict_e2e  # noqa: E402

UI_TARGET = "immichSlidesUITests"
PLATFORMS = ("ios", "tvos")
DEFAULT_PLANS = {"ios": "immichSlides-iOS.xctestplan", "tvos": "immichSlides-tvOS.xctestplan"}
EVIDENCE_PLANS = {"ios": "immichSlides-Evidence-iOS.xctestplan", "tvos": "immichSlides-Evidence-tvOS.xctestplan"}

# Frozen when this check was introduced. Entries may be removed, never added or swapped: a new
# gap must be wired into a runner instead.
APPROVED_KNOWN_UNCOVERED = frozenset({
    # Both need private PIN inputs, and no runner provides them yet.
    ("ios", "AccessLifecycleIOSUITests/testPasswordProtectionNormalUI"),
    ("tvos", "AccessLifecycleTVOSUITests/testTVOSPasswordProtectionNormalUI"),
})
# Left out of the default plans, but no runner or Evidence plan runs them yet. Remove an entry
# as soon as its test gets a runner.
KNOWN_UNCOVERED = set(APPROVED_KNOWN_UNCOVERED)

from ui_test_inventory import (UnsupportedCondition, line_platforms, parse_ui_tests, platforms_for_condition)


def ui_tests() -> tuple[dict[str, set[str]], dict[str, dict[str, set[str]]], list[str], set[str]]:
    """Parse every Swift file compiled into the UI test target, including subfolders."""
    files = {
        str(path.relative_to(ROOT)): path.read_text(encoding="utf-8")
        for folder in (UI_TARGET, "TestSupport")
        for path in sorted((ROOT / folder).rglob("*.swift"))
    }
    return parse_ui_tests(files)


def plan_entries(plan: str, key: str) -> list[str]:
    data = json.loads((ROOT / plan).read_text(encoding="utf-8"))
    targets = [target for target in data["testTargets"] if target["target"]["name"] == UI_TARGET]
    if len(targets) != 1:
        raise ValueError(f"{plan}: expected one {UI_TARGET} target")
    if targets[0].get("enabled") is False:
        raise ValueError(f"{plan}: the {UI_TARGET} target is disabled")
    return [entry.removesuffix("()") for entry in targets[0].get(key, [])]


def reachable_runner_selectors() -> dict[str, set[str]]:
    """Selectors each platform can actually run: suites reachable from the runners' command lines."""
    selectors: dict[str, set[str]] = {platform: set() for platform in PLATFORMS}
    for suite in run_strict_e2e.RUNNER_SUITES:
        for platform in PLATFORMS:
            try:
                selectors[platform].add(run_strict_e2e.resolve_suite_selector(platform, suite))
            except run_strict_e2e.CommandError:
                continue
    if "filter-person" in run_strict_e2e.RUNNER_SUITES:
        selectors["ios"].update(session["selector"] for session in run_strict_e2e.FILTER_PERSON_SESSIONS)
    selectors["ios"].add(run_access_lifecycle_ios.DEVICE_SELECTOR)
    selectors["tvos"].add(run_access_lifecycle_tvos.TVOS_DEVICE_SELECTOR)
    return {platform: {s.removeprefix(f"{UI_TARGET}/") for s in found} for platform, found in selectors.items()}


class Resolver:
    def __init__(self) -> None:
        self.classes, self.methods, parse_errors, self.strict_tests = ui_tests()
        self.errors: list[str] = list(parse_errors)

    def expand(self, platform: str, entry: str, source: str) -> set[str]:
        name, _, method = entry.partition("/")
        if platform not in self.classes.get(name, set()):
            self.errors.append(f"{source}: {entry} is not an XCTestCase class compiled for {platform}")
            return set()
        compiled = {m for m, platforms in self.methods[name].items() if platform in platforms}
        if not method:
            if not compiled:
                self.errors.append(f"{source}: {entry} has no tests on {platform}")
            return {f"{name}/{m}" for m in compiled}
        if method not in compiled:
            self.errors.append(f"{source}: {entry} is not a zero-argument test compiled for {platform}")
            return set()
        return {entry}


class Coverage:
    def __init__(self) -> None:
        resolver = Resolver()
        runners = reachable_runner_selectors()
        self.excluded: dict[str, set[str]] = {}
        self.covered: dict[str, set[str]] = {}
        self.run_by_runner: dict[str, set[str]] = {}
        self.compiled_strict: dict[str, set[str]] = {}
        self.evidence_selected: dict[str, set[str]] = {}
        for platform in PLATFORMS:
            plan = DEFAULT_PLANS[platform]
            if plan_entries(plan, "selectedTests"):
                resolver.errors.append(f"{plan}: the default plans must list exclusions in skippedTests")
            self.excluded[platform] = set()
            for entry in plan_entries(plan, "skippedTests"):
                self.excluded[platform] |= resolver.expand(platform, entry, plan)
            self.run_by_runner[platform] = set()
            for selector in runners[platform]:
                self.run_by_runner[platform] |= resolver.expand(platform, selector, f"runner ({platform})")
            self.evidence_selected[platform] = set()
            for entry in plan_entries(EVIDENCE_PLANS[platform], "selectedTests"):
                self.evidence_selected[platform] |= resolver.expand(platform, entry, EVIDENCE_PLANS[platform])
            self.covered[platform] = self.run_by_runner[platform] | self.evidence_selected[platform]
            self.compiled_strict[platform] = {
                test
                for test in resolver.strict_tests
                if platform in resolver.methods[test.split("/")[0]].get(test.split("/")[1], set())
            }
        self.errors = resolver.errors


def coverage() -> tuple[dict[str, set[str]], dict[str, set[str]], list[str]]:
    result = Coverage()
    return result.excluded, result.covered, result.errors


class ExcludedUITestsHaveARunnerTests(unittest.TestCase):
    def test_every_plan_entry_and_runner_selector_resolves(self):
        _excluded, _covered, errors = coverage()
        self.assertEqual(errors, [])

    def test_every_excluded_ui_test_runs_in_evidence_or_a_runner_suite(self):
        excluded, covered, _errors = coverage()
        uncovered = sorted(
            (platform, test)
            for platform in PLATFORMS
            for test in excluded[platform] - covered[platform]
            if (platform, test) not in KNOWN_UNCOVERED
        )
        self.assertEqual(uncovered, [], "Left out of the default plans but run nowhere")

    def test_strict_tests_are_left_out_of_default_plans_and_run_by_a_runner(self):
        result = Coverage()
        problems = sorted(
            (platform, test)
            for platform in PLATFORMS
            for test in result.compiled_strict[platform]
            if test in result.evidence_selected[platform]
            or test not in result.excluded[platform]
            or ((platform, test) not in KNOWN_UNCOVERED and test not in result.run_by_runner[platform])
        )
        self.assertEqual(problems, [], "Strict tests belong to their runner only; other plans cannot provide its inputs")

    def test_known_uncovered_entries_are_real_and_capped(self):
        excluded, covered, _errors = coverage()
        stale = sorted(
            (platform, test)
            for platform, test in KNOWN_UNCOVERED
            if test not in excluded[platform] or test in covered[platform]
        )
        self.assertEqual(stale, [], "Remove these from KNOWN_UNCOVERED")
        self.assertLessEqual(KNOWN_UNCOVERED, APPROVED_KNOWN_UNCOVERED, "Known gaps may only be removed")


class ParserTests(unittest.TestCase):
    SOURCE = """
    import XCTest

    #if os(tvOS)
    final class OnlyTVTests: XCTestCase {
        func testA() {}
    }
    #endif

    final class SharedTests: XCTestCase {
        // A brace in a comment: {
        let marker = "} and #if os(iOS) in a string"
        #if os(iOS)
        @MainActor
        func testPhone() {}
        #else
        func testTV() {}
        #endif
        #if DEBUG
        func testBoth() {}
        #endif
        func testWithArgument(value: Int) {}
        static func testFactory() {}
        func helper() {}
    }

    extension SharedTests {
        func testFromExtension() {}
    }
    """

    def parse(self, source: str):
        return parse_ui_tests({"Fixture.swift": source})

    def test_platform_blocks_decide_where_classes_and_methods_compile(self):
        classes, methods, errors, _strict = self.parse(self.SOURCE)
        self.assertEqual(errors, [])
        self.assertEqual(classes, {"OnlyTVTests": {"tvos"}, "SharedTests": {"ios", "tvos"}})
        self.assertEqual(methods["OnlyTVTests"], {"testA": {"tvos"}})
        self.assertEqual(
            methods["SharedTests"],
            {
                "testPhone": {"ios"},
                "testTV": {"tvos"},
                "testBoth": {"ios", "tvos"},
                "testFromExtension": {"ios", "tvos"},
            },
        )

    def test_test_method_outside_an_xctestcase_class_is_an_error(self):
        _classes, _methods, errors, _strict = self.parse("final class Helper: NSObject {\n    func testIgnored() {}\n}\n")
        self.assertEqual(errors, ["Fixture.swift: testIgnored() is not a member of a direct XCTestCase subclass"])

    def test_nested_helpers_and_local_functions_are_not_tests(self):
        source = """
        final class OuterTests: XCTestCase {
            struct Helper {
                func testLooksLikeATest() {}
            }
            func testReal() {
                func testLocal() {}
            }
        }
        """
        _classes, methods, errors, _strict = self.parse(source)
        self.assertEqual(errors, [])
        self.assertEqual(methods["OuterTests"], {"testReal": {"ios", "tvos"}})

    def test_nested_xctestcase_class_is_an_error(self):
        source = "enum Namespace {\n    final class InnerTests: XCTestCase {\n        func testA() {}\n    }\n}\n"
        _classes, _methods, errors, _strict = self.parse(source)
        self.assertIn("Fixture.swift: nested XCTestCase class InnerTests is not supported", errors)

    def test_compound_and_unknown_conditions(self):
        self.assertEqual(platforms_for_condition(" DEBUG && !os(tvOS)"), {"ios"})
        self.assertEqual(platforms_for_condition(" os(iOS) && os(tvOS)"), set())
        self.assertEqual(platforms_for_condition(" os(macOS)"), set())
        self.assertEqual(platforms_for_condition(" os(iOS) || DEBUG"), {"ios", "tvos"})
        self.assertEqual(platforms_for_condition(" (os(iOS) || os(tvOS)) && targetEnvironment(simulator)"), {"ios", "tvos"})
        with self.assertRaises(UnsupportedCondition):
            platforms_for_condition(" canImport(UIKit)")
        errors: list[str] = []
        self.assertEqual(line_platforms("#if SOMETHING_ELSE\nfunc x() {}\n#endif", errors)[1], set())
        self.assertEqual(errors, ["unsupported #if condition: SOMETHING_ELSE"])

    def test_raw_strings_and_interpolation_do_not_hide_tests(self):
        source = """
        /* class CommentOnly: XCTestCase { func testFake() {} } */
        // class LineCommentOnly: XCTestCase { func testFake() {} }
        final class /* outer /* nested */ end */ LexTests: XCTest /* module */ . XCTestCase {
            func testCovered() {}
            let open = #"prefix " { " suffix"#
            let nested = "\(String("{"))"
            func testAfterRawString() {}
            let close = #"prefix " } " suffix"#
            let nestedClose = "\(String("}"))"
            let rawCall = "\(helper.`don't call`())"
            let character: Character = "{"
            let decoy = "class Fake: XCTestCase { func testFake() {} }"
            func testLast() {}
        }
        """
        classes, methods, errors, _strict = self.parse(source)
        self.assertEqual(errors, [])
        self.assertEqual(set(classes), {"LexTests"})
        self.assertEqual(set(methods["LexTests"]), {"testCovered", "testAfterRawString", "testLast"})

    def test_same_test_in_both_branches_compiles_on_both_platforms(self):
        source = """
        final class BranchTests: XCTestCase {
            #if os(iOS)
            func testSameName() {}
            #else
            func testSameName() {}
            #endif
        }
        """
        _classes, methods, _errors, _strict = self.parse(source)
        self.assertEqual(methods["BranchTests"], {"testSameName": {"ios", "tvos"}})

    def test_xctest_method_shapes(self):
        source = """
        final class ShapeTests: XCTestCase {
            func `testBackticked`() {}
            func testAsync() async throws {}
        }
        private extension ShapeTests {
            func testPrivateExtension() {}
        }
        """
        _classes, methods, errors, _strict = self.parse(source)
        self.assertEqual(errors, [])
        self.assertEqual(set(methods["ShapeTests"]), {"testBackticked", "testAsync"})
        _classes, _methods, errors, _strict = self.parse("class ShapeTests: XCTestCase { func testReturnsValue() -> Int { 1 } }")
        self.assertTrue(any("unsupported XCTest test signature" in error for error in errors))

    def test_regex_literals_and_void_returns(self):
        source = """
        final class RegexTests: XCTestCase {
            let open = #/\{/#
            func testAfterRegex() -> Void {}
            let close = #/\}/#
            func testUnitReturn() -> () {}
            func testQualifiedReturn() -> Swift.Void {}
            func testParenthesizedReturn() -> (Void) {}
            func testParenthesizedQualifiedReturn() -> (Swift.Void) {}
        }
        """
        _classes, methods, errors, _strict = self.parse(source)
        self.assertEqual(errors, [])
        self.assertEqual(set(methods["RegexTests"]), {"testAfterRegex", "testUnitReturn", "testQualifiedReturn",
                                                   "testParenthesizedReturn", "testParenthesizedQualifiedReturn"})

    def test_objc_rename_in_an_extension_file_is_an_error(self):
        _classes, _methods, errors, _strict = parse_ui_tests(
            {
                "A.swift": "final class ATests: XCTestCase {\n    func testA() {}\n}\n",
                "B.swift": "extension ATests {\n    @objc(testLost) func helper() {}\n}\n",
            }
        )
        self.assertEqual(errors, ["B.swift: @objc(...) renames are not supported by this check"])

    def test_objc_renames_are_an_error(self):
        source = "final class ObjcTests: XCTestCase {\n    @objc(testOther) func helper() {}\n}\n"
        _classes, _methods, errors, _strict = self.parse(source)
        self.assertEqual(errors, ["Fixture.swift: @objc(...) renames are not supported by this check"])

    def test_strict_tests_are_found_through_helper_calls(self):
        source = """
        final class StrictTests: XCTestCase {
            func testDirect() { _ = try? requireStrictE2EInput() }
            func testThroughHelpers() { outer() }
            func testPlain() { plainHelper() }
            private func outer() { inner() }
            private func inner() { _ = try? launchStrictE2EApp() }
            private func plainHelper() {}
        }
        """
        _classes, _methods, errors, strict = self.parse(source)
        self.assertEqual(errors, [])
        self.assertEqual(strict, {"StrictTests/testDirect", "StrictTests/testThroughHelpers"})

    def test_negated_platform_condition(self):
        self.assertEqual(platforms_for_condition(" !os(tvOS)"), {"ios"})
        self.assertEqual(platforms_for_condition(" DEBUG"), {"ios", "tvos"})


if __name__ == "__main__":
    unittest.main()
