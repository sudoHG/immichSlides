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

import bisect
import json
import re
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

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

CLASS_RE = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase\b[^{]*\{")
EXTENSION_RE = re.compile(r"(?:\b(private|fileprivate)\s+)?\bextension\s+([A-Za-z_][A-Za-z0-9_]*)\b[^{]*\{")
# XCTest runs `func test…()` with no parameters and no return value; a backtick name counts too.
TEST_FUNC_RE = re.compile(
    r"\bfunc\s+(`?)(test[A-Za-z0-9_]*)\1\s*\(\s*\)\s*(?:async\s*)?(?:(?:re)?throws\s*)?"
    r"(\{|->\s*(?:Void|\(\s*\))\s*\{|->)"
)
# `static`/`class` functions and private functions are not XCTest-discoverable test methods.
NON_TEST_MODIFIER_RE = re.compile(r"\b(?:static|class|private|fileprivate)\s+(?:[A-Za-z@_()]+\s+)*$")
OBJC_RENAME_RE = re.compile(r"@objc\s*\(")
FUNC_RE = re.compile(r"\bfunc\s+(`?)([A-Za-z_][A-Za-z0-9_]*)\1\s*(?:<[^>{]*>)?\s*\(")
# Calls that mark a strict test: they read the strict runners' inputs or launch the app the strict way.
STRICT_PRIMITIVES = ("requireStrictE2EInput", "launchStrictE2EApp", "requirePrivatePINInput", "requireStrictE2EPeerServerURL")
CONDITION_TOKEN_RE = re.compile(
    r"\s*(os\(\s*\w+\s*\)|targetEnvironment\(\s*\w+\s*\)|[A-Za-z_][A-Za-z0-9_]*|&&|\|\||!|\(|\))"
)
# Flags the UI test targets are built with. Anything else is an unsupported condition.
KNOWN_FLAGS = {"DEBUG": True}
CONDITION_RE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


class UnsupportedCondition(ValueError):
    pass


def evaluate_condition(condition: str, platform: str) -> bool:
    """Evaluate a `#if` condition for one platform in a Debug simulator build."""
    tokens: list[str] = []
    position, text = 0, condition.strip()
    while position < len(text):
        match = CONDITION_TOKEN_RE.match(text, position)
        if not match:
            raise UnsupportedCondition(condition)
        tokens.append(re.sub(r"\s+", "", match.group(1)))
        position = match.end()
    index = 0

    def peek() -> str | None:
        return tokens[index] if index < len(tokens) else None

    def take() -> str:
        nonlocal index
        if index >= len(tokens):
            raise UnsupportedCondition(condition)
        index += 1
        return tokens[index - 1]

    def atom() -> bool:
        token = take()
        if token == "(":
            value = either()
            if take() != ")":
                raise UnsupportedCondition(condition)
            return value
        if token == "!":
            return not atom()
        if token.startswith("os("):
            return {"os(iOS)": "ios", "os(tvOS)": "tvos"}.get(token) == platform
        if token == "targetEnvironment(simulator)":
            return True
        if token in KNOWN_FLAGS:
            return KNOWN_FLAGS[token]
        raise UnsupportedCondition(condition)

    def both() -> bool:
        value = atom()
        while peek() == "&&":
            take()
            value = atom() and value
        return value

    def either() -> bool:
        value = both()
        while peek() == "||":
            take()
            value = both() or value
        return value

    result = either()
    if index != len(tokens):
        raise UnsupportedCondition(condition)
    return result


def platforms_for_condition(condition: str) -> set[str]:
    """Platforms a `#if` condition allows. Raises UnsupportedCondition for anything unknown."""
    return {platform for platform in PLATFORMS if evaluate_condition(condition, platform)}


def line_platforms(text: str, errors: list[str] | None = None) -> list[set[str]]:
    """For each line, the platforms that compile it, following `#if` blocks.

    An unsupported condition is reported in `errors` and treated as compiling on no platform.
    """
    frames: list[tuple[set[str], set[str]]] = []  # (active branch, platforms already taken)
    result: list[set[str]] = []

    def allowed_for(condition: str) -> set[str]:
        try:
            return platforms_for_condition(condition)
        except UnsupportedCondition:
            if errors is not None:
                errors.append(f"unsupported #if condition: {condition.strip()}")
            return set()

    for line in text.split("\n"):
        match = CONDITION_RE.match(line)
        if match:
            keyword, condition = match.group(1), match.group(2)
            if keyword == "if":
                allowed = allowed_for(condition)
                frames.append((allowed, set(allowed)))
            elif keyword == "elseif" and frames:
                taken = frames[-1][1]
                allowed = allowed_for(condition) - taken
                frames[-1] = (allowed, taken | allowed)
            elif keyword == "else" and frames:
                frames[-1] = (set(PLATFORMS) - frames[-1][1], set(PLATFORMS))
            elif keyword == "endif" and frames:
                frames.pop()
        allowed = set(PLATFORMS)
        for branch, _taken in frames:
            allowed &= branch
        result.append(allowed)
    return result


def string_end(text: str, index: int) -> int:
    """Index just after the string literal at `index` (a `"` or the `#`s of a raw string).

    Handles multiline and raw strings, escapes, and interpolation, including nested strings.
    """
    hashes = 0
    while text.startswith("#", index + hashes):
        hashes += 1
    start = index + hashes
    multiline = text.startswith('"""', start)
    quote = '"""' if multiline else '"'
    closing, escape = quote + "#" * hashes, "\\" + "#" * hashes
    position = start + len(quote)
    while position < len(text):
        if text.startswith(escape, position):
            after = position + len(escape)
            if after < len(text) and text[after] == "(":
                position = interpolation_end(text, after)
            else:
                position = after + 1
        elif text.startswith(closing, position):
            return position + len(closing)
        elif not multiline and text[position] == "\n":
            return position
        else:
            position += 1
    return len(text)


def interpolation_end(text: str, open_paren: int) -> int:
    """Index just after the `)` that closes the interpolation opened at `open_paren`."""
    depth, position = 0, open_paren
    while position < len(text):
        literal = literal_or_comment_end(text, position)
        if literal is not None:
            position = literal
        elif text[position] == "(":
            depth, position = depth + 1, position + 1
        elif text[position] == ")":
            depth, position = depth - 1, position + 1
            if depth == 0:
                return position
        else:
            position += 1
    return len(text)


def literal_or_comment_end(text: str, index: int) -> int | None:
    """If a comment or string literal starts at `index`, the index just after it."""
    if text.startswith("//", index):
        end = text.find("\n", index)
        return len(text) if end < 0 else end
    if text.startswith("/*", index):
        depth, end = 1, index + 2
        while end < len(text) and depth:
            if text.startswith("/*", end):
                depth, end = depth + 1, end + 2
            elif text.startswith("*/", end):
                depth, end = depth - 1, end + 2
            else:
                end += 1
        return end
    if text[index] == '"':
        return string_end(text, index)
    if text[index] == "#":
        hashes = len(text[index:]) - len(text[index:].lstrip("#"))
        if text.startswith('"', index + hashes):
            return string_end(text, index)
        if text.startswith("/", index + hashes):
            end = text.find("/" + "#" * hashes, index + hashes + 1)
            return len(text) if end < 0 else end + 1 + hashes
    return None


def blank_comments_and_strings(text: str) -> str:
    """Replace comments and string literals with spaces, keeping offsets and newlines."""
    out = list(text)
    index = 0
    while index < len(text):
        end = literal_or_comment_end(text, index)
        if end is None:
            index += 1
            continue
        for position in range(index, end):
            if out[position] != "\n":
                out[position] = " "
        index = max(end, index + 1)
    return "".join(out)


def matching_brace(text: str, open_index: int) -> int:
    depth = 0
    for index in range(open_index, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError("unbalanced braces")


class SwiftFile:
    """Class and extension scopes plus zero-argument test methods of one Swift file."""

    def __init__(self, name: str, text: str) -> None:
        self.name = name
        self.code = blank_comments_and_strings(text)
        condition_errors: list[str] = []
        self.platforms_by_line = line_platforms(self.code, condition_errors)
        self.line_starts = [0]
        for line in self.code.split("\n"):
            self.line_starts.append(self.line_starts[-1] + len(line) + 1)
        self.errors: list[str] = []
        self.classes: dict[str, set[str]] = {}
        for m in CLASS_RE.finditer(self.code):
            if self.depth(0, m.start()) != 0:
                self.errors.append(f"{name}: nested XCTestCase class {m.group(1)} is not supported")
            self.classes[m.group(1)] = self.platforms_at(m.start())
        # (open brace, close brace, type name, members are private)
        self.scopes = [
            (m.end() - 1, matching_brace(self.code, m.end() - 1), m.group(1), False) for m in CLASS_RE.finditer(self.code)
        ] + [
            (m.end() - 1, matching_brace(self.code, m.end() - 1), m.group(2), m.group(1) is not None)
            for m in EXTENSION_RE.finditer(self.code)
        ]
        self.test_funcs = [
            (m.start(), m.group(2), self.code[m.end() - 1 : matching_brace(self.code, m.end() - 1)])
            for m in TEST_FUNC_RE.finditer(self.code)
            if m.group(3) != "->" and not NON_TEST_MODIFIER_RE.search(self.code[max(0, m.start() - 80) : m.start()])
        ]
        self.function_bodies: list[tuple[str, str]] = []
        for m in FUNC_RE.finditer(self.code):
            close = self.parameters_end(m.end() - 1)
            brace = self.code.find("{", close)
            between = self.code[close:brace] if brace >= 0 else ""
            if brace < 0 or re.search(r"\bfunc\b|\bvar\b|\blet\b|\}", between):
                continue  # a requirement without a body
            self.function_bodies.append((m.group(2), self.code[brace : matching_brace(self.code, brace)]))
        if self.classes or self.test_funcs:
            self.errors.extend(f"{name}: {error}" for error in condition_errors)
        if OBJC_RENAME_RE.search(self.code):
            self.errors.append(f"{name}: @objc(...) renames are not supported by this check")

    def parameters_end(self, open_paren: int) -> int:
        depth = 0
        for index in range(open_paren, len(self.code)):
            if self.code[index] == "(":
                depth += 1
            elif self.code[index] == ")":
                depth -= 1
                if depth == 0:
                    return index
        return len(self.code)

    def platforms_at(self, offset: int) -> set[str]:
        line = bisect.bisect_right(self.line_starts, offset) - 1
        return self.platforms_by_line[min(line, len(self.platforms_by_line) - 1)]

    def depth(self, start: int, end: int) -> int:
        return self.code.count("{", start, end) - self.code.count("}", start, end)

    def owner(self, offset: int) -> tuple[str, int, bool] | None:
        """The innermost class or extension around an offset, the brace depth inside it, and
        whether its members are private."""
        owners = [scope for scope in self.scopes if scope[0] < offset < scope[1]]
        if not owners:
            return None
        start, _end, name, private = max(owners, key=lambda scope: scope[0])
        return name, self.depth(start, offset), private


def calls_any(body: str, names: set[str]) -> bool:
    return any(re.search(r"\b" + re.escape(name) + r"\s*\(", body) for name in names)


def strict_function_names(parsed: list["SwiftFile"]) -> set[str]:
    """Functions that reach a strict-runner input, directly or through other functions."""
    bodies: dict[str, list[str]] = {}
    for swift_file in parsed:
        for name, body in swift_file.function_bodies:
            bodies.setdefault(name, []).append(body)
    strict = set(STRICT_PRIMITIVES)
    changed = True
    while changed:
        changed = False
        for name, found in bodies.items():
            if name not in strict and any(calls_any(body, strict) for body in found):
                strict.add(name)
                changed = True
    return strict


def parse_ui_tests(
    files: dict[str, str],
) -> tuple[dict[str, set[str]], dict[str, dict[str, set[str]]], list[str], set[str]]:
    """Return (class platforms, class -> method -> platforms, errors, strict tests) across Swift files.

    Strict tests (as `Class/method`) are the ones that need strict-runner inputs.

    A test method in an extension belongs to the extended XCTestCase class. A test method that is
    not a direct member of a direct XCTestCase subclass is an error, so it cannot silently drop out
    of the check. Declarations of one method in several `#if` branches merge their platforms.
    """
    parsed = [SwiftFile(name, text) for name, text in files.items()]
    classes: dict[str, set[str]] = {}
    errors: list[str] = []
    for swift_file in parsed:
        for name, platforms in swift_file.classes.items():
            classes[name] = classes.get(name, set()) | platforms
        errors.extend(swift_file.errors)
    methods: dict[str, dict[str, set[str]]] = {name: {} for name in classes}
    strict_names = strict_function_names(parsed)
    strict_tests: set[str] = set()
    for swift_file in parsed:
        for offset, name, body in swift_file.test_funcs:
            owner = swift_file.owner(offset)
            if owner is not None and owner[0] in classes:
                type_name, depth, private = owner
                if depth == 1 and not private:
                    found = methods[type_name]
                    found[name] = found.get(name, set()) | swift_file.platforms_at(offset)
                    if calls_any(body, strict_names):
                        strict_tests.add(f"{type_name}/{name}")
                # Deeper means a local function or a nested helper type; private extension members
                # are not discoverable.
                continue
            errors.append(f"{swift_file.name}: {name}() is not a member of a direct XCTestCase subclass")
    return classes, methods, errors, strict_tests


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
        final class LexTests: XCTestCase {
            func testCovered() {}
            let open = #"prefix " { " suffix"#
            let nested = "\(String("{"))"
            func testAfterRawString() {}
            let close = #"prefix " } " suffix"#
            let nestedClose = "\(String("}"))"
            func testLast() {}
        }
        """
        _classes, methods, errors, _strict = self.parse(source)
        self.assertEqual(errors, [])
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
            func testReturnsValue() -> Int { 1 }
            func testAsync() async throws {}
        }
        private extension ShapeTests {
            func testPrivateExtension() {}
        }
        """
        _classes, methods, errors, _strict = self.parse(source)
        self.assertEqual(errors, [])
        self.assertEqual(set(methods["ShapeTests"]), {"testBackticked", "testAsync"})

    def test_regex_literals_and_void_returns(self):
        source = """
        final class RegexTests: XCTestCase {
            let open = #/\{/#
            func testAfterRegex() -> Void {}
            let close = #/\}/#
            func testUnitReturn() -> () {}
        }
        """
        _classes, methods, errors, _strict = self.parse(source)
        self.assertEqual(errors, [])
        self.assertEqual(set(methods["RegexTests"]), {"testAfterRegex", "testUnitReturn"})

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
