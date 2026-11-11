#!/usr/bin/env python3
"""Check test naming, assertion and wait conventions from docs/TESTING.md sections 2, 3, 4 and 7.

Run from the repo root:

    python3 scripts/check_test_conventions.py

Exits 1 and lists every violation not covered by scripts/test_conventions_allowlist.json, and every
allowlist entry that no longer matches a real violation (the allowlist may only shrink). Regenerate the
allowlist with `--write-allowlist` (maintainers only; see the printed warning).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from collections import Counter
from pathlib import Path

TARGET_GLOBS = ("immichSlidesTests/*.swift", "immichSlidesUITests/*.swift", "TestSupport/*.swift")
ALLOWLIST_PATH = "scripts/test_conventions_allowlist.json"
TIMEOUT_ALLOWLIST_PATH = "scripts/test_timeout_allowlist.json"
TEST_TIER_PLAN_PATH = "scripts/ci-test-tiers.json"
# Approved source identities are independent of the editable plan's links.
APPROVED_TIER_SMOKE = {
    "iphone-album-selection": ("iphone", "Debug", "strict", "filter-album|normal|iphone|Debug|a"),
    "iphone-background-return": ("iphone", "Release", "strict", "ios-lifecycle-background|normal|iphone|Release|a"),
    "iphone-connection-error": ("iphone", "Debug", "strict", "firstboot-failure|auth-401|iphone|Debug|a"),
    "iphone-first-boot": ("iphone", "Debug", "strict", "journey-a|normal|iphone|Debug|a"),
    "iphone-person-return": ("iphone", "Debug", "strict", "filter-person-return|normal|iphone|Debug|a"),
    "iphone-pin-gate": ("iphone", "Debug", "ui", "immichSlidesUITests/testPinProtectionBlocksBackAndRequiresPINForSettings"),
    "iphone-playback-controls": ("iphone", "Debug", "strict", "journey-b|normal|iphone|Debug|a"),
    "iphone-settings-relaunch": ("iphone", "Release", "strict", "ios-lifecycle-settings|normal|iphone|Release|a"),
    "ipad-background-return": ("ipad", "Release", "strict", "ios-lifecycle-background|normal|ipad|Release|a"),
    "ipad-first-boot": ("ipad", "Debug", "strict", "journey-a|normal|ipad|Debug|a"),
    "ipad-playback-controls": ("ipad", "Debug", "strict", "journey-b|normal|ipad|Debug|a"),
    "ipad-rotation": ("ipad", "Debug", "strict", "p2-rotation|normal|ipad|Debug|a"),
    "ipad-settings-sidebar": ("ipad", "Debug", "ui", "FilterSummaryIOSVisualUITests/testIOSSettingsOpenSourceLicensesKeepsPadSidebarResponsive"),
    "tv-album-selection": ("tv", "Debug", "strict", "tvos-album|normal|tv|Debug|a"),
    "tv-background-return": ("tv", "Release", "strict", "tvos-lifecycle-background|normal|tv|Release|a"),
    "tv-directional-wake": ("tv", "Debug", "strict", "tvos-directional-wake|normal|tv|Debug|a"),
    "tv-first-boot": ("tv", "Debug", "strict", "tvos-n1-cold|normal|tv|Debug|a"),
    "tv-pause-resume": ("tv", "Release", "strict", "tvos-lifecycle-pause|normal|tv|Release|a"),
    "tv-person-selection": ("tv", "Debug", "strict", "tvos-person|normal|tv|Debug|a"),
    "tv-pin-gate": ("tv", "Debug", "ui", "FilterSummaryTVOSVisualUITests/testTVOSFullFlowPinGateBlocksSettingsUntilPinValidated"),
    "tv-playback-controls": ("tv", "Debug", "strict", "tvos-flow|normal|tv|Debug|a"),
    "tv-server-switch": ("tv", "Release", "strict", "tvos-switch|normal|tv|Release|a"),
    "tv-settings-relaunch": ("tv", "Release", "strict", "tvos-lifecycle-settings|normal|tv|Release|a"),
}

# Swift Testing functions that intentionally keep a plain (non-raw-identifier) name. Selected by the
# scripts that migrated the rest of the suite to sentence-style raw identifiers; see docs/TESTING.md #2.
SWIFT_TESTING_NAME_EXCEPTIONS = frozenset({
    "externalRuntimeJSONLPassesValidator",
    "normalizeServerURLWorks",
})

# Ticket/PR/process codes forbidden anywhere in a test function name, test type name or file name
# (docs/TESTING.md #2). Matched anywhere inside the name, not only as a standalone word, except where the
# name itself notes a camelCase token boundary (N1/N2/N3, V1, RED): a plain substring match on those would
# also flag ordinary English words ("Credential", "Stored"), so those four use a boundary-aware pattern.
FORBIDDEN_NAME_PATTERNS = (
    ("ticket-pr", re.compile(r"PR\d+")),
    ("ticket-s30x", re.compile(r"S30\d")),
    ("ticket-331", re.compile(r"331-\d+")),
    ("process-phase", re.compile(r"[Pp]hase\d")),
    ("process-todo", re.compile(r"Todo\d+")),
    ("process-n123", re.compile(r"(?:(?<=[a-z0-9])|^)N[123](?=[A-Z]|[^a-zA-Z0-9]|$)")),
    ("process-v1", re.compile(r"(?:(?<=[a-z0-9])|^)V1(?=[A-Z]|[^a-zA-Z0-9]|$)")),
    ("process-journey", re.compile(r"Journey[A-Z]")),
    ("process-selfcheck", re.compile(r"SelfCheck")),
    ("process-golden", re.compile(r"[Gg]olden")),
    ("process-red", re.compile(r"(?:(?<=[a-z0-9])|^)RED(?=[A-Z]|[^a-zA-Z0-9]|$)")),
)
CJK_PATTERN = re.compile(r"[一-鿿]")
# UI labels may use any CJK writing system, including kana and Hangul syllables.
UI_CJK_PATTERN = re.compile(
    r"[\u1100-\u11ff\u3040-\u30ff\u3100-\u312f\u3130-\u318f\u31f0-\u31ff"
    r"\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff\uff65-\uff9f]"
)
UI_QUERY_COLLECTION_PATTERN = re.compile(
    r"\.(?:buttons|staticTexts|texts|textFields|secureTextFields|textViews|searchFields|switches|cells|"
    r"otherElements|navigationBars|tabBars|toolbars|collectionViews|tables|scrollViews|webViews|images|"
    r"links|icons|sliders|steppers|pickers|pickerWheels|segmentedControls|datePickers|timePickers|alerts|"
    r"sheets|keys|menus|menuItems|menuBars|menuBarItems|groups|windows|dialogs|popovers|drawers|"
    r"activityIndicators|progressIndicators|pageIndicators|statusBars|browsers|outlines|outlineRows|rows|"
    r"columns|disclosureTriangles|splitGroups|splitters|radioButtons|radioGroups|checkBoxes|comboBoxes|"
    r"colorWells|wells|rulers|scrollBars|incrementArrows|decrementArrows|sortButtons|closeButtons|zoomButtons)\s*$"
)
UI_QUERY_METHOD_PATTERN = re.compile(r"\.(?:descendants|children|matching|containing)\s*\([^;]*\)\s*$", re.DOTALL)
UI_QUERY_VARIABLE_TYPE_PATTERN = re.compile(r"\b([A-Za-z_]\w*)\s*:\s*(?:XCTest\.)?XCUIElementQuery\b")
NSPREDICATE_OPERATOR_PATTERN = (
    r"(?:==|!=|<=|>=|<|>|(?:BETWEEN|CONTAINS|BEGINSWITH|ENDSWITH|MATCHES|LIKE|IN)\b)(?:\[[a-z]*\])?"
)
NSPREDICATE_FORMAT_PLACEHOLDER_PATTERN = re.compile(r"%%|%(?:(\d+)\$)?([A-Za-z@])")
NSPREDICATE_FORMAT_TOKEN_PATTERN = re.compile(
    rf"""'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|{NSPREDICATE_FORMAT_PLACEHOLDER_PATTERN.pattern}|"""
    rf"{NSPREDICATE_OPERATOR_PATTERN}|[A-Za-z_][\w.]*|&&|\|\||\S",
    re.IGNORECASE,
)
UI_LABEL_LOOKUP_DIRECTIVE_PATTERN = re.compile(r"^\s*//\s*ui-label-lookup:\s*\S")

SOURCE_TEXT_IDENTIFIERS = ("readProjectSource", "projectSwiftSourceFiles")
CONTENTS_OF_PATTERN = re.compile(r"String\(contentsOf:|contentsOfFile")
FILE_PATH_PATTERN = re.compile(r"#filePath")

WAIT_BOUND_PATTERN = re.compile(
    r"\b(timeout|deadline|elapsed|attempts?|maxIterations|iterations?|budget|ContinuousClock|Date\(\)|\.now\b)",
    re.IGNORECASE,
)
WAIT_PRIMITIVE_PREFIXES = ("Task.yield(", "Task.sleep(", "usleep(", "Thread.sleep(", "RunLoop.current.run(until:")
WAIT_PRIMITIVE_STRIP = re.compile(r"^(try[?!]?\s+)?(await\s+)?")

FUNC_DECL_PATTERN = re.compile(r"func\s+(`[^`]*`|\w+)\s*\(")
TYPE_DECL_PATTERN = re.compile(
    r"(?:@\w+(?:\([^)]*\))?\s*)*\b(?:final\s+)?(?:class|struct|enum)\s+(\w+)"
)
# `\w` matches Unicode letters (including CJK), which is required to catch CJK characters in a raw
# XCTest function name — a plain Swift identifier is not limited to ASCII.
XCTEST_FUNC_PATTERN = re.compile(r"\bfunc\s+(test\w*)\s*\(")
ATTR_PATTERN = re.compile(r"@(Test|Suite)\b")


@dataclass(frozen=True)
class Violation:
    path: str
    line: int
    rule: str
    name: str
    detail: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: [{self.rule}] {self.detail}"

    def allow_key(self) -> tuple:
        return (self.rule, self.path, self.name)


def mask_comments(source: str, *, mask_strings: bool = False) -> str:
    """Blank out comments (and optionally string literals), keeping offsets and newlines intact.

    Copied from scripts/check_release_guards.py so this script has no import-time dependency on it.
    """
    out = list(source)
    i, n = 0, len(source)

    def blank(start: int, end: int) -> None:
        for k in range(start, end):
            if out[k] not in "\n\r":
                out[k] = " "

    while i < n:
        if source.startswith("//", i):
            end = source.find("\n", i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
        elif source.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if source.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif source.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif match := re.match(r'(#*)("""|")', source[i:i + 8]):
            hashes, quote = match.group(1), match.group(2)
            if quote == '"' and not hashes and i > 0 and source[i - 1] == "\\":
                i += 1
                continue
            terminator = quote + hashes
            j = i + len(match.group(0))
            while j < n and not source.startswith(terminator, j):
                if quote == '"' and source[j] == "\n":
                    break
                j += 2 if source[j] == "\\" and not hashes else 1
            j = min(n, j + len(terminator))
            if mask_strings:
                blank(i, j)
            i = j
        else:
            i += 1
    return "".join(out)


def line_of(source: str, index: int) -> int:
    return source.count("\n", 0, index) + 1


def find_matching(text: str, open_idx: int, open_char: str, close_char: str) -> int:
    """Return the index of the character matching text[open_idx], or -1 if unbalanced."""
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        if text[i] == open_char:
            depth += 1
        elif text[i] == close_char:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def raw_identifier_text(token: str) -> str:
    return token[1:-1] if token.startswith("`") and token.endswith("`") else token


def is_raw_identifier(token: str) -> bool:
    return token.startswith("`") and token.endswith("`")


# ---------------------------------------------------------------------------
# Rule a: forbidden-name (ticket/PR/process codes + CJK in function names)
# ---------------------------------------------------------------------------

def check_forbidden_names(path: str, source: str) -> list[Violation]:
    code = mask_comments(source, mask_strings=True)
    violations: list[Violation] = []

    def scan(scope: str, value: str, index: int) -> None:
        for rule, pattern in FORBIDDEN_NAME_PATTERNS:
            if pattern.search(value):
                violations.append(Violation(path, line_of(source, index), "forbidden-name", f"{scope}:{value}",
                                            f"{scope} name `{value}` contains a forbidden ticket/process code ({rule})"))
        if scope == "function" and CJK_PATTERN.search(value):
            violations.append(Violation(path, line_of(source, index), "forbidden-name", f"{scope}:{value}",
                                        f"{scope} name `{value}` contains CJK characters"))

    for func_name, index in iter_test_function_names(code):
        scan("function", raw_identifier_text(func_name), index)
    for match in TYPE_DECL_PATTERN.finditer(code):
        scan("type", match.group(1), match.start(1))

    file_name = Path(path).stem
    scan("file", file_name, 0)
    return violations


def iter_test_function_names(code: str):
    """Yield (name_token, index) for every Swift Testing `@Test` function and every XCTest `test...` function."""
    seen: set[int] = set()
    for attr_match in ATTR_PATTERN.finditer(code):
        if attr_match.group(1) != "Test":
            continue
        pos = attr_match.end()
        pos = skip_attribute_args(code, pos)
        func_match = FUNC_DECL_PATTERN.match(code, pos)
        if not func_match:
            # Allow other attributes/modifiers (e.g. @MainActor) between @Test and func.
            skip = re.match(r"(?:\s*@\w+(?:\([^)]*\))?)*\s*", code[pos:])
            end = pos + (skip.end() if skip else 0)
            func_match = FUNC_DECL_PATTERN.match(code, end)
        if func_match and func_match.start() not in seen:
            seen.add(func_match.start())
            yield func_match.group(1), func_match.start(1)
    for func_match in XCTEST_FUNC_PATTERN.finditer(code):
        if func_match.start() not in seen:
            seen.add(func_match.start())
            yield func_match.group(1), func_match.start(1)


def skip_attribute_args(code: str, pos: int) -> int:
    j = pos
    while j < len(code) and code[j] in " \t\n":
        j += 1
    if j < len(code) and code[j] == "(":
        close = find_matching(code, j, "(", ")")
        return close + 1 if close != -1 else pos
    return pos


# ---------------------------------------------------------------------------
# Rule b: display-name (`@Test("...")` / `@Suite("...")`)
# ---------------------------------------------------------------------------

def check_display_names(path: str, source: str) -> list[Violation]:
    code = mask_comments(source)
    violations: list[Violation] = []
    for attr_match in ATTR_PATTERN.finditer(code):
        kind = attr_match.group(1)
        pos = attr_match.end()
        j = pos
        while j < len(code) and code[j] in " \t\n":
            j += 1
        if j >= len(code) or code[j] != "(":
            continue
        close = find_matching(code, j, "(", ")")
        if close == -1:
            continue
        args = code[j + 1:close]
        stripped = args.lstrip()
        if stripped.startswith('"') or stripped.startswith('#"'):
            name = enclosing_declaration_name(code, close + 1) or f"{kind}@{line_of(source, attr_match.start())}"
            violations.append(Violation(path, line_of(source, attr_match.start()), "display-name", name,
                                        f"@{kind}(\"...\") display-name string is forbidden; use a raw-identifier name instead"))
    return violations


def enclosing_declaration_name(code: str, pos: int) -> str | None:
    skip = re.match(r"(?:\s*@\w+(?:\([^)]*\))?)*\s*(?:final\s+)?", code[pos:])
    end = pos + (skip.end() if skip else 0)
    match = re.match(r"(func|struct|class|enum)\s+(`[^`]*`|[A-Za-z_]\w*)", code[end:])
    if match:
        return raw_identifier_text(match.group(2))
    return None


# ---------------------------------------------------------------------------
# Rule c: swift-testing-name (raw-identifier sentence required for `@Test` funcs)
# ---------------------------------------------------------------------------

def check_swift_testing_names(path: str, source: str) -> list[Violation]:
    code = mask_comments(source, mask_strings=True)
    violations: list[Violation] = []
    for attr_match in ATTR_PATTERN.finditer(code):
        if attr_match.group(1) != "Test":
            continue
        pos = skip_attribute_args(code, attr_match.end())
        skip = re.match(r"(?:\s*@\w+(?:\([^)]*\))?)*\s*", code[pos:])
        end = pos + (skip.end() if skip else 0)
        func_match = FUNC_DECL_PATTERN.match(code, end)
        if not func_match:
            continue
        token = func_match.group(1)
        index = func_match.start(1)
        line = line_of(source, index)
        if not is_raw_identifier(token):
            if token in SWIFT_TESTING_NAME_EXCEPTIONS:
                continue
            violations.append(Violation(path, line, "swift-testing-name", token,
                                        f"@Test func `{token}` must use a backtick raw-identifier sentence name"))
            continue
        name = raw_identifier_text(token)
        if " " not in name:
            violations.append(Violation(path, line, "swift-testing-name", name,
                                        f"@Test raw identifier `{name}` must be a sentence, not a single token"))
            continue
        first_word = name.split(" ", 1)[0]
        # A proper noun / type name reference is allowed to start uppercase: an acronym (all caps) or a
        # camelCase/PascalCase compound (an internal uppercase letter) reads as an identifier, not a sentence
        # word that was capitalized by mistake.
        looks_like_proper_noun = first_word.isupper() or (len(first_word) > 1 and first_word[1:] != first_word[1:].lower())
        if first_word[:1].isupper() and not looks_like_proper_noun:
            violations.append(Violation(path, line, "swift-testing-name", name,
                                        f"@Test raw identifier `{name}` should start lowercase unless the first word is a proper noun or type name"))
    return violations


# ---------------------------------------------------------------------------
# Rule d: source-text (no reading project .swift sources from tests)
# ---------------------------------------------------------------------------

SOURCE_CONTEXT_RADIUS_CHARACTERS = 200

def check_source_text(path: str, source: str) -> list[Violation]:
    code = mask_comments(source)
    violations: list[Violation] = []
    for identifier in SOURCE_TEXT_IDENTIFIERS:
        for match in re.finditer(r"\b" + re.escape(identifier) + r"\b", code):
            violations.append(Violation(path, line_of(source, match.start()), "source-text", identifier,
                                        f"test must not use {identifier} to read project source"))
    for match in CONTENTS_OF_PATTERN.finditer(code):
        window = code[max(0, match.start() - SOURCE_CONTEXT_RADIUS_CHARACTERS):match.end() + SOURCE_CONTEXT_RADIUS_CHARACTERS]
        if ".swift" in window:
            violations.append(Violation(path, line_of(source, match.start()), "source-text", "contentsOf",
                                        "test must not read a .swift source file via contentsOf:/contentsOfFile"))
    for match in FILE_PATH_PATTERN.finditer(code):
        window = code[max(0, match.start() - SOURCE_CONTEXT_RADIUS_CHARACTERS):match.end() + SOURCE_CONTEXT_RADIUS_CHARACTERS]
        if "immichSlides/" in window:
            violations.append(Violation(path, line_of(source, match.start()), "source-text", "filePath",
                                        "test must not resolve immichSlides/ sources relative to #filePath"))
    return violations


# ---------------------------------------------------------------------------
# Rule e: unbounded-wait (`while` loops that only yield/sleep, with no bound)
# ---------------------------------------------------------------------------

def check_unbounded_waits(path: str, source: str) -> list[Violation]:
    code = mask_comments(source)
    violations: list[Violation] = []
    for match in re.finditer(r"\bwhile\b", code):
        brace_open = find_top_level_brace(code, match.end())
        if brace_open == -1:
            continue
        condition = code[match.end():brace_open]
        brace_close = find_matching(code, brace_open, "{", "}")
        if brace_close == -1:
            continue
        body = code[brace_open + 1:brace_close]
        if WAIT_BOUND_PATTERN.search(condition) or WAIT_BOUND_PATTERN.search(body):
            continue
        statements = [s.strip() for s in re.split(r"[\n;]", body)]
        statements = [s for s in statements if s]
        if not statements or not all(is_wait_primitive(s) for s in statements):
            continue
        func_name = enclosing_function_name(code, match.start())
        violations.append(Violation(path, line_of(source, match.start()), "unbounded-wait", func_name,
                                    f"while loop in `{func_name}` only yields/sleeps with no deadline or iteration bound"))
    return violations


# ---------------------------------------------------------------------------
# Rule f: ui-label-lookup (CJK text must not be used to locate app UI elements)
# ---------------------------------------------------------------------------

def iter_string_literals(source: str):
    """Yield (start, end, content) spans for Swift string literals, excluding comments."""
    code = mask_comments(source)
    i = 0
    while i < len(code):
        match = re.match(r"(#*)(\"\"\"|\")", code[i:i + 8])
        if not match:
            i += 1
            continue
        hashes, quote = match.group(1), match.group(2)
        if quote == '"' and not hashes and i > 0 and code[i - 1] == "\\":
            i += 1
            continue
        start = i
        content_start = i + len(match.group(0))
        terminator = quote + hashes
        j = content_start
        while j < len(code) and not code.startswith(terminator, j):
            if quote == '"' and code[j] == "\n":
                break
            j += 2 if code[j] == "\\" and not hashes else 1
        content_end = j
        end = min(len(code), j + len(terminator))
        yield start, end, code[content_start:content_end]
        i = end


def mask_strings_and_block_comments(source: str) -> str:
    """Blank strings and block comments while preserving real line comments."""
    out = list(source)
    i, n = 0, len(source)

    def blank(start: int, end: int) -> None:
        for index in range(start, end):
            if out[index] not in "\n\r":
                out[index] = " "

    while i < n:
        if source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
        elif source.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if source.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif source.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif match := re.match(r'(#*)("""|")', source[i:i + 8]):
            hashes, quote = match.group(1), match.group(2)
            if quote == '"' and not hashes and i > 0 and source[i - 1] == "\\":
                i += 1
                continue
            terminator = quote + hashes
            j = i + len(match.group(0))
            while j < n and not source.startswith(terminator, j):
                if quote == '"' and source[j] == "\n":
                    break
                j += 2 if source[j] == "\\" and not hashes else 1
            j = min(n, j + len(terminator))
            blank(i, j)
            i = j
        else:
            i += 1
    return "".join(out)


def has_ui_label_lookup_directive(source: str, line: int) -> bool:
    """Whether the immediately preceding line gives a nonempty rule-specific reason."""
    if line <= 1:
        return False
    lines = mask_strings_and_block_comments(source).splitlines()
    return line - 2 < len(lines) and bool(UI_LABEL_LOOKUP_DIRECTIVE_PATTERN.match(lines[line - 2]))


def is_xctest_query_expression(query_base: str, query_aliases: set[str]) -> bool:
    if UI_QUERY_COLLECTION_PATTERN.search(query_base) or UI_QUERY_METHOD_PATTERN.search(query_base):
        return True
    variable = re.search(r"\b([A-Za-z_]\w*)\s*$", query_base)
    return bool(variable and variable.group(1) in query_aliases)


def ui_query_aliases(structural_code: str) -> set[str]:
    """Find local names whose declarations identify them as XCTest element queries."""
    aliases = {match.group(1) for match in UI_QUERY_VARIABLE_TYPE_PATTERN.finditer(structural_code)}
    assignments = list(re.finditer(
        r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::\s*(?:XCTest\.)?XCUIElementQuery\s*)?=\s*([^\n;}]*)",
        structural_code,
    ))
    changed = True
    while changed:
        changed = False
        for assignment in assignments:
            name, expression = assignment.groups()
            source_name = re.fullmatch(r"\s*([A-Za-z_]\w*)\s*", expression)
            if (is_xctest_query_expression(expression, aliases) or
                    (source_name and source_name.group(1) in aliases)):
                if name not in aliases:
                    aliases.add(name)
                    changed = True
    return aliases


def ui_query_subscript_start(
    code: str,
    structural_code: str,
    literal_start: int,
    query_aliases: set[str],
) -> int | None:
    """Return the opening bracket for a CJK string used as an XCTest query subscript."""
    open_brackets: list[int] = []
    for index, character in enumerate(structural_code[:literal_start]):
        if character == "[":
            open_brackets.append(index)
        elif character == "]" and open_brackets:
            open_brackets.pop()

    for bracket_start in reversed(open_brackets):
        query_base = code[:bracket_start].rstrip()
        if is_xctest_query_expression(query_base, query_aliases):
            return bracket_start
    return None


def ui_query_matching_start(code: str, literal_start: int, query_aliases: set[str]) -> int | None:
    """Return a matching(identifier:) call only when it continues an XCTest query chain."""
    prefix = code[:literal_start]
    matching = re.search(r"\bmatching\s*\(\s*identifier\s*:\s*$", prefix)
    if not matching:
        return None
    query_base = prefix[:matching.start()].rstrip()
    if query_base.endswith("."):
        query_base = query_base[:-1].rstrip()
    if is_xctest_query_expression(query_base, query_aliases):
        return matching.start()
    return None


def swift_call_argument_spans(structural_code: str, start: int, end: int) -> list[tuple[int, int]]:
    """Return top-level comma-separated argument spans for a Swift call."""
    opening_to_closing = {"(": ")", "[": "]", "{": "}"}
    closing_to_opening = {closing: opening for opening, closing in opening_to_closing.items()}
    stack: list[str] = []
    spans: list[tuple[int, int]] = []
    argument_start = start
    for index in range(start, end):
        character = structural_code[index]
        if character in opening_to_closing:
            stack.append(character)
        elif character in closing_to_opening:
            if stack and stack[-1] == closing_to_opening[character]:
                stack.pop()
        elif character == "," and not stack:
            spans.append((argument_start, index))
            argument_start = index + 1
    if argument_start < end or spans:
        spans.append((argument_start, end))
    return spans


def exact_string_literal_value(
    source: str,
    argument_span: tuple[int, int],
    string_literals: list[tuple[int, int, str]],
) -> str | None:
    """Return a literal argument's content only when it is the entire argument expression."""
    start, end = argument_span
    while start < end and source[start].isspace():
        start += 1
    while end > start and source[end - 1].isspace():
        end -= 1
    for literal_start, literal_end, content in string_literals:
        if literal_start == start and literal_end == end:
            return content
    return None


def nspredicate_format_has_visible_comparison(
    structural_code: str,
    source: str,
    open_idx: int,
    close_idx: int,
    string_literals: list[tuple[int, int, str]],
) -> bool:
    """Whether a comparison pairs label/title/value with its own CJK operand."""
    argument_spans = swift_call_argument_spans(structural_code, open_idx + 1, close_idx)
    if not argument_spans:
        return False

    format_literals = [
        (start, end, content)
        for start, end, content in string_literals
        if argument_spans[0][0] <= start and end <= argument_spans[0][1]
    ]
    if not format_literals:
        return False
    escapes = {"n": "\n", "r": "\r", "t": "\t"}
    format_text = "".join(
        re.sub(r'\\(["\\nrt])', lambda match: escapes.get(match.group(1), match.group(1)), content)
        if source[start] == '"' else content
        for start, _, content in format_literals
    )

    substitution_arguments = argument_spans[1:]
    if len(substitution_arguments) == 1:
        start, end = substitution_arguments[0]
        array_argument = re.match(r"\s*argumentArray\s*:\s*\[", structural_code[start:end])
        if array_argument:
            array_start = start + array_argument.end() - 1
            array_end = find_matching(structural_code, array_start, "[", "]")
            if array_end != -1 and not structural_code[array_end + 1:end].strip():
                substitution_arguments = swift_call_argument_spans(structural_code, array_start + 1, array_end)
    sequential_argument_index = 0
    tokens = [match.group(0) for match in NSPREDICATE_FORMAT_TOKEN_PATTERN.finditer(format_text)]
    operands: list[tuple[bool, bool]] = []
    for token in tokens:
        is_visible_property = False
        has_cjk = bool(UI_CJK_PATTERN.search(token))
        placeholder = NSPREDICATE_FORMAT_PLACEHOLDER_PATTERN.fullmatch(token)
        if placeholder and token != "%%":
            positional_index = placeholder.group(1)
            if positional_index is None:
                argument_index = sequential_argument_index
                sequential_argument_index += 1
            else:
                argument_index = int(positional_index) - 1
            if 0 <= argument_index < len(substitution_arguments):
                argument = substitution_arguments[argument_index]
                has_cjk = any(
                    UI_CJK_PATTERN.search(content)
                    for start, end, content in string_literals
                    if argument[0] <= start and end <= argument[1]
                )
                if token.endswith("K"):
                    key = exact_string_literal_value(source, argument, string_literals)
                    is_visible_property = key is not None and key.rsplit(".", 1)[-1].lower() in {"label", "title", "value"}
        elif re.fullmatch(r"[A-Za-z_][\w.]*", token):
            is_visible_property = token.rsplit(".", 1)[-1].lower() in {"label", "title", "value"}
        operands.append((is_visible_property, has_cjk))

    opening_to_closing = {"(": ")", "[": "]", "{": "}"}
    closing_to_opening = {closing: opening for opening, closing in opening_to_closing.items()}
    stack: list[int] = []
    paired_groups: dict[int, int] = {}
    for index, token in enumerate(tokens):
        if token in opening_to_closing:
            stack.append(index)
        elif token in closing_to_opening and stack and tokens[stack[-1]] == closing_to_opening[token]:
            opening = stack.pop()
            paired_groups[opening] = index
            paired_groups[index] = opening

    def comparison_operand(index: int, direction: int) -> tuple[bool, bool]:
        if not 0 <= index < len(tokens):
            return False, False
        start = end = index
        if (direction < 0 and tokens[index] in closing_to_opening
                or direction > 0 and tokens[index] in opening_to_closing):
            if index not in paired_groups:
                return False, False
            start, end = sorted((index, paired_groups[index]))
        elif direction > 0 and index + 1 in paired_groups and tokens[index + 1] == "(":
            end = paired_groups[index + 1]

        # A function call is one operand; a parenthesized property still names that property.
        if start > 0 and tokens[start] == "(" and re.fullmatch(r"[A-Za-z_][\w.]*", tokens[start - 1]):
            if (tokens[start - 1].upper() not in {"AND", "OR", "NOT", "ANY", "ALL", "SOME"}
                    and not re.fullmatch(NSPREDICATE_OPERATOR_PATTERN, tokens[start - 1], re.IGNORECASE)):
                start -= 1
        has_cjk = any(operand[1] for operand in operands[start:end + 1])
        while start < end and tokens[start] == "(" and paired_groups.get(start) == end:
            start += 1
            end -= 1
        is_visible_property = start == end and operands[start][0]
        return is_visible_property, has_cjk

    for index, token in enumerate(tokens):
        if not re.fullmatch(NSPREDICATE_OPERATOR_PATTERN, token, re.IGNORECASE):
            continue
        left_property, left_cjk = comparison_operand(index - 1, -1)
        right_property, right_cjk = comparison_operand(index + 1, 1)
        if (left_property and right_cjk) or (right_property and left_cjk):
            return True
    return False


def nspredicate_call_start(
    structural_code: str,
    source: str,
    literal_start: int,
    string_literals: list[tuple[int, int, str]] | None = None,
) -> int | None:
    """Return the NSPredicate initializer start when a CJK literal compares label/title/value."""
    if string_literals is None:
        string_literals = list(iter_string_literals(source))
    for match in re.finditer(r"\bNSPredicate\s*\(", structural_code):
        open_idx = structural_code.find("(", match.start(), match.end())
        close_idx = find_matching(structural_code, open_idx, "(", ")")
        if close_idx == -1 or not (open_idx < literal_start < close_idx):
            continue
        if nspredicate_format_has_visible_comparison(
            structural_code, source, open_idx, close_idx, string_literals
        ):
            return match.start()
    return None


def check_ui_label_lookups(path: str, source: str) -> list[Violation]:
    """Report CJK string literals used to find app-owned UI elements in UI tests."""
    if not path.startswith("immichSlidesUITests/") or not path.endswith(".swift"):
        return []

    code = mask_comments(source)
    structural_code = mask_comments(source, mask_strings=True)
    query_aliases = ui_query_aliases(structural_code)
    string_literals = list(iter_string_literals(source))
    violations: list[Violation] = []
    seen: set[tuple[int, str]] = set()

    def report(index: int, kind: str) -> None:
        line = line_of(source, index)
        if has_ui_label_lookup_directive(source, line) or (index, kind) in seen:
            return
        seen.add((index, kind))
        violations.append(Violation(path, line, "ui-label-lookup", f"{kind}:{line}",
                                    f"CJK text locates an app UI element through {kind}; use accessibilityIdentifier"))

    for literal_start, _, content in iter_string_literals(source):
        if not UI_CJK_PATTERN.search(content):
            continue

        matching_identifier_start = ui_query_matching_start(code, literal_start, query_aliases)
        if matching_identifier_start is not None:
            report(matching_identifier_start, "matching(identifier:)")
            continue

        subscript_start = ui_query_subscript_start(code, structural_code, literal_start, query_aliases)
        if subscript_start is not None:
            report(subscript_start, "query subscript")
            continue

        predicate_start = nspredicate_call_start(structural_code, code, literal_start, string_literals)
        if predicate_start is not None:
            report(predicate_start, "NSPredicate")

    return violations


def check_ui_exists_then_reads(path: str, source: str) -> list[Violation]:
    """Reject live element reads that race an earlier existence query."""
    if not path.startswith(("immichSlidesUITests/", "TestSupport/")) or not path.endswith(".swift"):
        return []
    code = mask_comments(source)
    structural_code = mask_comments(source, mask_strings=True)
    receiver = r'\b[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*|\s*\[[^\]\n]*\]|\s*\([^();{}\n]*\))*'
    read_pattern = re.compile(rf'\s*\(*\s*(?P<read>{receiver})\s*\.\s*(?P<property>value|isEnabled|isHittable)\b')
    call_pattern = re.compile(r'\b[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*\s*\(')

    def normalized(expression: str) -> tuple[str, tuple[str, ...]]:
        # Ignore formatting, but keep string keys distinct (including whitespace in them).
        return (re.sub(r"\s+", "", mask_comments(expression, mask_strings=True)),
                tuple(content for _, _, content in iter_string_literals(expression)))

    def helper_receives_receiver(start: int, expected: str) -> bool:
        # Only inspect a call that starts the true branch, and calls nested inside it.
        # A complete argument must be the guarded receiver, not a property or snapshot of it.
        beginning = re.match(r'\s*\(*\s*', structural_code[start:])
        call = call_pattern.match(structural_code, start + beginning.end())
        if call is None:
            return False
        end = find_matching(structural_code, call.end() - 1, "(", ")")
        if end == -1:
            return False
        for nested in call_pattern.finditer(structural_code, call.start(), end):
            closing = find_matching(structural_code, nested.end() - 1, "(", ")")
            if closing == -1 or closing > end:
                continue
            for arg_start, arg_end in swift_call_argument_spans(structural_code, nested.end(), closing):
                label = re.match(r'\s*[A-Za-z_]\w*\s*:', structural_code[arg_start:arg_end])
                if label:
                    arg_start += label.end()
                argument = code[arg_start:arg_end].strip()
                while argument.startswith("(") and find_matching(
                    mask_comments(argument, mask_strings=True), 0, "(", ")"
                ) == len(argument) - 1:
                    argument = argument[1:-1].strip()
                if normalized(argument) == normalized(expected):
                    return True
        return False

    def receiver_start(end: int) -> int:
        while end:
            while end and structural_code[end - 1].isspace():
                end -= 1
            if end and structural_code[end - 1] in ")]":
                closing = structural_code[end - 1]
                opening = {")": "(", "]": "["}[closing]
                depth = 1
                end -= 1
                while end and depth:
                    end -= 1
                    if structural_code[end] == closing:
                        depth += 1
                    elif structural_code[end] == opening:
                        depth -= 1
                continue
            start = end
            while start and (structural_code[start - 1].isalnum() or structural_code[start - 1] == "_"):
                start -= 1
            before = start
            while before and structural_code[before - 1].isspace():
                before -= 1
            if before and structural_code[before - 1] == ".":
                end = before - 1
            else:
                return start
        return end

    violations = []
    for match in re.finditer(r"\.\s*exists\s*\?", structural_code):
        start = receiver_start(match.start())
        read = read_pattern.match(code, match.end())
        expected = code[start:match.start()]
        direct_read = read is not None and normalized(expected) == normalized(read["read"])
        if not direct_read and not helper_receives_receiver(match.end(), expected):
            continue
        read_kind = f"live {read['property']} read" if direct_read else "helper call receiving the same element"
        line = line_of(source, start)
        violations.append(Violation(
            path, line, "ui-exists-then-read", f"{enclosing_function_name(structural_code, start)}:{line}",
            f"exists followed by a {read_kind} can fail after the element disappears; "
            "read evidence from one snapshot and record notVisible when absent"
        ))
    return violations


def find_top_level_brace(code: str, start: int) -> int:
    """Find the `{` that opens the loop body, skipping over any `(...)` condition."""
    depth = 0
    i = start
    n = len(code)
    while i < n:
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
        elif code[i] == "{" and depth == 0:
            return i
        i += 1
    return -1


def is_wait_primitive(statement: str) -> bool:
    stripped = WAIT_PRIMITIVE_STRIP.sub("", statement)
    return any(stripped.startswith(prefix) for prefix in WAIT_PRIMITIVE_PREFIXES)


def enclosing_function_name(code: str, index: int) -> str:
    name = "unknown"
    for match in FUNC_DECL_PATTERN.finditer(code, 0, index):
        name = raw_identifier_text(match.group(1))
    return name


# ---------------------------------------------------------------------------
# Repository scan + allowlist
# ---------------------------------------------------------------------------

def timeout_literal_inventory(path: str, source: str) -> list[dict]:
    """Inventory unclassified Swift timing literals, including defaults and named constants.

    Counts prevent an existing function's exception from admitting another literal.
    Comments/strings and explicitly classified TestWait budgets are not raw waits.
    """
    code = mask_comments(source, mask_strings=True)
    scopes = []
    declarations = re.compile(r"\b(class|struct|enum|extension|func)\s+(`[^`]+`|[\w.]+)")
    for match in declarations.finditer(code):
        opening = find_top_level_brace(code, match.end())
        if opening < 0:
            continue
        closing = find_matching(code, opening, "{", "}")
        if closing >= 0:
            start = match.start()
            if match.group(1) == "func":
                for attribute in re.compile(r"@\w+").finditer(code, 0, start):
                    end = attribute.end()
                    if code[end:end + 1] == "(":
                        end = find_matching(code, end, "(", ")") + 1
                    if end and re.fullmatch(r"\s*(?:@\w+\s+)*(?:(?:private|public|internal|static|final|override|nonisolated)\s+)*", code[end:start]):
                        start = attribute.start()
                        break
            scopes.append((start, closing, match.group(1), raw_identifier_text(match.group(2))))

    def owner(index):
        containing = [(kind, name) for start, end, kind, name in scopes if start <= index <= end]
        names = [name for kind, name in containing]
        if not any(kind == "func" for kind, _ in containing):
            names.append("<scope>")
        return ".".join(names)

    # Keep the original expression for the ratchet, but exclude only classified argument regions
    # from numeric detection. Raw arithmetic outside a nested classified call must still be counted.
    unclassified = list(code)
    for match in re.finditer(r"\bTestWait\.(seconds|until|observe)\s*\(", code):
        opening = code.find("(", match.start(), match.end())
        closing = find_matching(code, opening, "(", ")")
        if closing < 0:
            continue
        arguments = swift_call_argument_spans(code, opening + 1, closing)
        if not arguments:
            continue
        first = code[slice(*arguments[0])].strip()
        if match.group(1) == "observe" and not re.match(r"seconds\s*:", first):
            continue
        for index, (start, end) in enumerate(arguments):
            argument = code[start:end]
            # Conditions can be passed inside the parentheses instead of as a trailing closure.
            if "{" in argument or (index and not re.match(r"\s*pollIntervalSeconds\s*:", argument)):
                continue
            for offset in range(start, end):
                if unclassified[offset] not in "\n\r":
                    unclassified[offset] = " "
    unclassified = "".join(unclassified)
    number = r"(?<![\w.$])[-+]?(?:0[xX][\da-fA-F_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?)\b"
    sites = {}

    def continues_on_next_line(start, newline):
        # Swift continues a statement after a trailing binary operator or before a leading operator or member access.
        before = newline
        while before > start and code[before - 1].isspace():
            before -= 1
        if before > start and code[before - 1] in "+-*/%&|^~=?:":
            return True
        after = newline + 1
        while after < len(code) and code[after].isspace():
            after += 1
        return bool(re.match(r"\.|[-+*/%&|^<>=~?:]+\s", code[after:after + 4]))

    def expression_end(start):
        depth = 0
        for index in range(start, len(code)):
            character = code[index]
            if depth == 0 and (character in ",);{}" or character == "\n" and not continues_on_next_line(start, index)):
                return index
            if character in "([":
                depth += 1
            elif character in ")]":
                depth -= 1
        return len(code)

    heads = (
        r"\b(?:\w*(?:timeout|deadline|duration|pollInterval|observation)\w*|"
        r"\w*window(?!\w*(?:count|limit|size|used)\b)\w*|hold|nanoseconds|forTimeInterval)\s*:\s*",
        r"\b(?:let|var)\s+(?!\w*threshold\b)\w*(?:timeout|deadline|duration|window|seconds|wait|poll|settle|hold|delay|interval)\s*(?::[^=\n]+)?=\s*",
        r"\b(?:let|var)\s+\w+\s*:\s*(?:\w+\.)?(?:TimeInterval|Duration|DispatchTimeInterval)\??\s*=\s*",
    )
    for head in heads:
        for match in re.finditer(head, code, re.IGNORECASE):
            end = expression_end(match.end())
            if re.search(number, unclassified[match.end():end]):
                sites[(match.start(), end)] = re.sub(r"\s+", "", code[match.start():end])
    calls = r"\b(?:addingTimeInterval|sleep|usleep)\s*\(|\.(?:seconds|milliseconds|microseconds|nanoseconds|minutes)\s*\("
    for match in re.finditer(calls, code, re.IGNORECASE):
        opening = code.find("(", match.start(), match.end())
        closing = find_matching(code, opening, "(", ")")
        if closing >= 0 and re.search(number, unclassified[opening + 1:closing]):
            sites[(match.start(), closing + 1)] = re.sub(r"\s+", "", code[match.start():closing + 1])
    sites = {span: literal for span, literal in sites.items()
             if not any(other != span and other[0] <= span[0] and span[1] <= other[1] for other in sites)}
    counts = Counter((owner(start), literal) for (start, _), literal in sites.items())
    return [{"path": path, "function": function, "literal": literal, "count": count}
            for (function, literal), count in sorted(counts.items())]


def repository_timeout_inventory(root: Path) -> list[dict]:
    return [entry for file in iter_target_files(root)
            for entry in timeout_literal_inventory(file.relative_to(root).as_posix(), file.read_text(encoding="utf-8"))]


def partition_timeout_allowlist(current: list[dict], allowed: list[dict]):
    def key(entry):
        return (entry["path"], entry["function"], entry["literal"])
    for entries in (current, allowed):
        keys = [key(entry) for entry in entries]
        if len(keys) != len(set(keys)) or any(type(e["count"]) is not int or e["count"] < 1 for e in entries):
            raise ValueError("timeout allowlist needs unique sites and positive integer counts")
    actual, baseline = {key(e): e["count"] for e in current}, {key(e): e["count"] for e in allowed}
    added = [e for e in current if actual[key(e)] > baseline.get(key(e), 0)]
    stale = [e for e in allowed if baseline[key(e)] > actual.get(key(e), 0)]
    return added, stale


def check_product_wait_factor(path: str, source: str) -> list[Violation]:
    code = mask_comments(source)
    return [Violation(path, line_of(source, match.start()), "product-wait-factor", "TestWait",
                      "production code must not read the test wait factor or use TestWait")
            for match in re.finditer(r"\bTestWait\b|IMMICHSLIDES_TEST_WAIT_FACTOR", code)]


def check_navigation_waits(path: str, source: str) -> list[Violation]:
    """Keep navigation deadlines outside polling and optional branches to one observation."""
    code = mask_comments(source, mask_strings=True)
    violations = []

    def reject(index, rule, detail):
        violations.append(Violation(path, line_of(source, index), rule,
                                    enclosing_function_name(code, index), detail))

    for match in re.finditer(r"\b(?:while|for|repeat)\b|\bwaitUntil\s*(?=[({])|\.(?:until|observe)\s*(?=[({])", code):
        opening = find_top_level_brace(code, match.end())
        if match.group().startswith("waitUntil"):
            call_opening = code.find("(", match.end())
            call_closing = find_matching(code, call_opening, "(", ")") if call_opening >= 0 else -1
            if call_closing >= 0:
                trailing = re.match(r"\s*\{", code[call_closing + 1:])
                if trailing is None:
                    continue
                opening = call_closing + 1 + trailing.end() - 1
        closing = find_matching(code, opening, "{", "}") if opening >= 0 else -1
        if closing >= 0 and re.search(r"\bTestWait\.hangGuard\s*\(", code[opening:closing]):
            reject(match.start(), "hang-guard-refresh", "create the shared hang guard before polling")
    for match in re.finditer(r"\bif\s+!?(?!Wait\b|TestWait\b)\w+(?:\.transaction\s*\(\s*\))?\.until\b", code):
        reject(match.start(), "hang-guard-optional", "optional branches must use a single-observation probe")
    for match in re.finditer(r"\.probe\s*(?:\(\s*)?\{", code):
        opening = code.find("{", match.start(), match.end())
        closing = find_matching(code, opening, "{", "}")
        if closing >= 0 and re.search(r"\.wait\w*\s*\(|\.(?:until|observe)\s*[({]|\b(?:sleep|usleep)\s*\(|RunLoop\.", code[opening:closing]):
            reject(match.start(), "hang-guard-probe", "a probe must not poll, sleep or invoke another wait")
    if path.startswith("immichSlidesUITests/"):
        for match in re.finditer(r"\bTestWait\.hangGuard\s*\(\s*[^)\s]", code):
            # Hogan's D1 approval keeps post-tap focus readback on its existing five-second budget.
            if (path == "immichSlidesUITests/UITestSupport.swift"
                    and enclosing_function_name(code, match.start()) == "focusTextField"
                    and re.match(r"TestWait\.hangGuard\s*\(\s*timeoutSeconds\s*:\s*"
                                 r"UITestSupportWaitTiming\.elementAppearanceTimeoutSeconds\s*\)",
                                 code[match.start():])):
                continue
            reject(match.start(), "hang-guard-duration", "UI navigation uses the default unscaled hang guard")
    return violations


CHECKS = (check_forbidden_names, check_display_names, check_swift_testing_names, check_source_text,
          check_unbounded_waits, check_ui_label_lookups, check_ui_exists_then_reads, check_navigation_waits)


def iter_target_files(root: Path):
    for pattern in TARGET_GLOBS:
        for file in sorted(root.glob(pattern)):
            yield file


def check_repository(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    for file in iter_target_files(root):
        path = file.relative_to(root).as_posix()
        source = file.read_text(encoding="utf-8")
        for check in CHECKS:
            violations.extend(check(path, source))
        if path.startswith("immichSlidesUITests/"):
            code = mask_comments(source, mask_strings=True)
            for match in re.finditer(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b[^\{]*\{", code):
                end = find_matching(code, match.end() - 1, "{", "}")
                body = re.sub(r"[\s;]+", "", code[match.end():end])
                hook = "overridefuncrecord(_issue:XCTIssue){FirstFailureEvidence.record(self,issue:issue)super.record(issue)}"
                reset = "overridefuncinvokeTest(){FirstFailureContext.reset()super.invokeTest()}"
                detail = None
                if hook not in body:
                    detail = " must forward record(_:) to FirstFailureEvidence before super.record"
                elif reset not in body:
                    detail = " must reset the first-failure timeline before super.invokeTest"
                if detail is not None:
                    name = match.group(1)
                    violations.append(Violation(path, line_of(source, match.start()), "first-failure-hook", name,
                        name + detail))
    for file in sorted((root / "immichSlides").rglob("*.swift")):
        violations.extend(check_product_wait_factor(file.relative_to(root).as_posix(), file.read_text(encoding="utf-8")))
    return violations


def load_allowlist(allowlist_path: Path) -> list[dict]:
    if not allowlist_path.is_file():
        return []
    return json.loads(allowlist_path.read_text(encoding="utf-8"))


def write_allowlist(allowlist_path: Path, violations: list[Violation]) -> None:
    entries = sorted({(v.rule, v.path, v.name) for v in violations})
    payload = [{"rule": rule, "path": path, "name": name} for rule, path, name in entries]
    allowlist_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def partition_against_allowlist(violations: list[Violation], allowlist: list[dict]):
    allowed_keys = {(e["rule"], e["path"], e["name"]) for e in allowlist}
    matched_keys: set[tuple] = set()
    unallowed: list[Violation] = []
    for v in violations:
        key = v.allow_key()
        if key in allowed_keys:
            matched_keys.add(key)
        else:
            unallowed.append(v)
    stale = [e for e in allowlist if (e["rule"], e["path"], e["name"]) not in matched_keys]
    return unallowed, stale


def test_tier_context(root: Path):
    """Read only public source inventories; this plan never supplies execution selectors."""
    from ci_population import swift_identities
    from run_strict_e2e import CommandError, resolve_suite_selector
    from ui_test_inventory import parse_ui_tests

    _, methods, errors, _ = parse_ui_tests({p.relative_to(root).as_posix(): p.read_text(encoding="utf-8")
                                          for p in (root / "immichSlidesUITests").rglob("*.swift")})
    if errors:
        raise ValueError("; ".join(errors))
    ui = {f"{suite}/{method}": platforms for suite, entries in methods.items()
          for method, platforms in entries.items()}
    cases = json.loads((root / "scripts/nightly-matrix.json").read_text(encoding="utf-8"))["cases"]
    strict = {}
    for case in cases:
        key = "|".join(case[field] for field in ("suite", "scenario", "device", "configuration", "fixture"))
        try:
            selector = resolve_suite_selector(case["platform"], case["suite"])
        except CommandError as error:
            raise ValueError(f"strict {key}: {error}") from error
        if len(selector.split("/")) != 3 or not all(selector.split("/")):
            raise ValueError(f"strict {key}: malformed selector {selector!r}")
        strict[key] = dict(case, selector=selector.split("/", 1)[1])
    sources = {p.relative_to(root).as_posix(): p.read_text(encoding="utf-8")
               for p in (root / "immichSlidesTests").rglob("*.swift")}
    units = {entry["key"] for platform in ("ios", "tvos") for entry in swift_identities(sources, platform)}
    areas = json.loads((root / "scripts/ci-ui-areas.json").read_text(encoding="utf-8"))
    return ui, strict, units, set(areas["functional_smoke"])


def validate_test_tier_plan(plan, ui, strict, units, pr_smoke) -> list[str]:
    """Reject incomplete migration accounting without changing any running population."""
    errors = []

    def check(condition, rule, where, detail):
        if not condition:
            errors.append(f"{rule}: {where}: {detail}")

    def obj(value, where, required, optional=()):
        if not isinstance(value, dict):
            check(False, "tier-plan-shape", where, "expected object")
            return {}
        missing, extra = set(required) - value.keys(), value.keys() - set(required) - set(optional)
        check(not missing and not extra, "tier-plan-shape", where,
              f"missing keys {sorted(missing)}; extra keys {sorted(extra)}")
        return value

    def text_field(value):
        return isinstance(value, str) and bool(value.strip())

    def objects(value, where):
        if not isinstance(value, list):
            check(False, "tier-plan-shape", where, "expected list of objects")
            return []
        return value

    def strings(value, where):
        if not isinstance(value, list) or not all(text_field(v) for v in value):
            check(False, "tier-plan-shape", where, "expected list of nonempty strings")
            return set()
        return set(value)

    def text_keys(value, where, keys):
        for key in keys:
            check(text_field(value.get(key)), "tier-plan-shape", where, f"{key} must be a nonempty string")

    plan = obj(plan, "plan", ("schema_version", "revision", "mode", "baseline_sha", "migration", "smoke_flows",
                              "inventory", "weekly_human_review", "release_full_set"))
    check(type(plan.get("schema_version")) is int and plan.get("schema_version") == 1,
          "tier-plan-version", "plan", f"schema_version={plan.get('schema_version')!r}; expected 1")
    check(plan.get("mode") == "planning-only", "tier-plan-mode", "plan", "mode must remain planning-only")
    migration = obj(plan.get("migration"), "migration", (
        "wave_one_removes_ui_tests", "app_behavior", "replacement_gate", "yellow_and_retry", "history_readable_days",
        "shadow_runs", "executed_nights_after_switch", "unexplained_red_allowed", "nightly_budget_minutes", "reference_meaning"))
    for key, expected in {"wave_one_removes_ui_tests": False, "app_behavior": "unchanged",
                          "yellow_and_retry": "frozen-no-new-exceptions", "shadow_runs": {"minimum": 5, "maximum": 7},
                          "executed_nights_after_switch": 10, "unexplained_red_allowed": 0, "history_readable_days": 90}.items():
        check(type(migration.get(key)) is type(expected) and migration.get(key) == expected,
              "tier-plan-migration", "migration", f"{key} must be {expected!r} ({type(expected).__name__})")
    check(text_field(migration.get("replacement_gate")), "tier-plan-migration", "migration", "missing replacement_gate")
    check(isinstance(migration.get("nightly_budget_minutes"), list)
          and all(type(v) is int for v in migration.get("nightly_budget_minutes", [])),
          "tier-plan-shape", "migration", "nightly_budget_minutes must be a list of integers")
    flows = {}
    additions = {"tv-pause-resume", "tv-server-switch", "ipad-first-boot", "ipad-background-return"}
    for index, value in enumerate(objects(plan.get("smoke_flows"), "smoke_flows")):
        where = f"smoke_flows[{index}] {value.get('id')!r}" if isinstance(value, dict) else f"smoke_flows[{index}]"
        flow = obj(value, where, ("id", "device", "configuration", "fixture", "source", "selection_basis", "user_path", "must_not_assert"),
                   ("peer_fixture",))
        text_keys(flow, where, ("id", "device", "configuration", "fixture", "selection_basis", "user_path"))
        source = obj(flow.get("source"), where + ".source", ("kind", "identifier", "selector"))
        flow["source"] = source
        text_keys(source, where + ".source", ("kind", "identifier", "selector"))
        fid = flow.get("id")
        if not text_field(fid):
            continue
        check(fid not in flows, "tier-plan-smoke-population", where, f"duplicate id {fid}")
        flows[fid] = flow
        approved = APPROVED_TIER_SMOKE.get(fid)
        actual = (flow.get("device"), flow.get("configuration"), source.get("kind"), source.get("identifier"))
        check(approved == actual, "tier-plan-smoke-source", where, f"source {actual!r}; approved {approved!r}")
        platform = "tvos" if flow.get("device") == "tv" else "ios"
        selector = source.get("selector")
        valid = text_field(selector) and selector in ui and platform in ui[selector]
        if source.get("kind") == "strict":
            case = strict.get(source["identifier"], {}) if text_field(source.get("identifier")) else {}
            valid = valid and all(case.get(key) == flow.get(key) for key in ("device", "configuration", "fixture"))
            valid = valid and case.get("selector") == selector
        else:
            valid = valid and source.get("kind") == "ui" and source.get("identifier") == selector
        check(valid, "tier-plan-smoke-source", where, f"unknown or mismatched source {source!r}")
        forbidden = strings(flow.get("must_not_assert"), where + ".must_not_assert")
        check(flow.get("fixture") == "a" and flow.get("configuration") in ("Debug", "Release")
              and text_field(flow.get("user_path")) and {"mid-animation-pixels", "second-level-windows", "glyph-identity"} <= forbidden,
              "tier-plan-smoke-contract", where, "fixture/configuration/user_path/must_not_assert violates smoke boundary")
        check(flow.get("peer_fixture") == ("b" if fid == "tv-server-switch" else None),
              "tier-plan-smoke-contract", where, "peer_fixture must be b only for tv-server-switch")
        check(flow.get("selection_basis") == ("maintainer-addition" if fid in additions else "shared-core"),
              "tier-plan-smoke-population", where, "incorrect selection_basis")
    check(set(flows) == set(APPROVED_TIER_SMOKE), "tier-plan-smoke-population", "smoke_flows",
          f"missing ids {sorted(set(APPROVED_TIER_SMOKE) - flows.keys())}; unknown ids {sorted(flows.keys() - APPROVED_TIER_SMOKE.keys())}")
    weekly = obj(plan.get("weekly_human_review"), "weekly_human_review",
                 ("owner", "escalate_to", "cadence", "unreviewed_status", "fixture_policy", "groups"))
    for key, expected in (("owner", "Claude (coordinator)"), ("escalate_to", "Hogan")):
        check(weekly.get(key) == expected, "tier-plan-human-review", "weekly_human_review", f"{key} must be {expected}")
    groups = {}
    for index, value in enumerate(objects(weekly.get("groups"), "weekly_human_review.groups")):
        where = f"review group[{index}] {value.get('id')!r}" if isinstance(value, dict) else f"review group[{index}]"
        group = obj(value, where, ("id", "title", "devices", "screenshots", "recordings", "look_for"))
        text_keys(group, where, ("id", "title"))
        devices = strings(group.get("devices"), where + ".devices")
        check(bool(devices) and devices <= {"iphone", "ipad", "tv"}, "tier-plan-human-review", where, f"unknown/empty devices {sorted(devices)}")
        for key in ("screenshots", "recordings", "look_for"):
            check(bool(strings(group.get(key), where + "." + key)), "tier-plan-human-review", where, f"missing {key}")
        if text_field(group.get("id")):
            check(group["id"] not in groups, "tier-plan-human-review", where, "duplicate id")
            groups[group["id"]] = devices
    check(len(groups) == 6, "tier-plan-human-review", "weekly_human_review", f"expected 6 groups; found {sorted(groups)}")
    keys = []
    for index, value in enumerate(objects(plan.get("inventory"), "inventory")):
        where = f"inventory[{index}] {value.get('identifier')!r}" if isinstance(value, dict) else f"inventory[{index}]"
        row = obj(value, where, ("kind", "identifier", "target_home", "replacement_tests", "smoke_flows", "status"),
                  ("human_review_groups", "mutation_proof"))
        text_keys(row, where, ("kind", "identifier", "target_home", "status"))
        kind, identifier, home = row.get("kind"), row.get("identifier"), row.get("target_home")
        parts = identifier.split("/" if kind == "ui" else "|") if text_field(identifier) else []
        valid_id = all(parts) and (kind == "ui" and len(parts) == 2 or kind == "strict" and len(parts) == 5)
        check(valid_id, "tier-plan-identifier", where, f"malformed kind/identifier {kind!r}/{identifier!r}")
        if not valid_id:
            continue
        keys.append((kind, identifier))
        check(home in ("unit", "smoke", "pr-smoke", "human-review", "delete"), "tier-plan-home", where, f"unknown target_home {home!r}")
        replacements = strings(row.get("replacement_tests"), where + ".replacement_tests")
        linked_flows = strings(row.get("smoke_flows"), where + ".smoke_flows")
        reviews = strings(row.get("human_review_groups", []), where + ".human_review_groups")
        expected_flows = {fid for fid, flow in flows.items() if
                          (flow.get("source", {}).get("kind"), flow.get("source", {}).get("identifier")) == (kind, identifier)
                          or kind == "ui" and flow.get("source", {}).get("selector") == identifier}
        for field, unknown in (("replacement_tests", replacements - units), ("smoke_flows", linked_flows - flows.keys()),
                               ("human_review_groups", reviews - groups.keys())):
            check(not unknown, "tier-plan-replacement", where, f"unknown {field} references {sorted(unknown)}")
        direct_anchor = any((flow.get("source", {}).get("kind"), flow.get("source", {}).get("identifier"))
                            == (kind, identifier) for flow in flows.values())
        check(expected_flows <= linked_flows and (not direct_anchor or home == "smoke")
              and (home != "smoke" or bool(linked_flows)), "tier-plan-replacement", where,
              f"missing smoke_flows {sorted(expected_flows - linked_flows)} or incorrect target_home {home!r}; anchors {sorted(expected_flows)}")
        check(home not in ("smoke", "human-review") or bool(reviews), "tier-plan-replacement", where, "missing human_review_groups")
        devices = ({strict[identifier]["device"]} if kind == "strict" and identifier in strict else
                   {device for device, platform in (("iphone", "ios"), ("ipad", "ios"), ("tv", "tvos"))
                    if platform in ui.get(identifier, set())})
        for group in reviews & groups.keys():
            check(bool(devices & groups[group]), "tier-plan-review-device", where,
                  f"human_review_groups {group!r} devices {sorted(groups[group])} do not apply to row devices {sorted(devices)}")
        check((kind == "ui" and identifier in pr_smoke) == (home == "pr-smoke"),
              "tier-plan-pr-smoke", where, f"target_home must {'be' if identifier in pr_smoke else 'not be'} pr-smoke for functional_smoke {identifier}")
        proof_tests = set()
        for proof_index, value in enumerate(objects(row.get("mutation_proof", []), where + ".mutation_proof")):
            proof_where = f"{where}.mutation_proof[{proof_index}]"
            proof = obj(value, proof_where, ("pr", "test", "mutation", "failed_then_passed_on"))
            text_keys(proof, proof_where, ("pr", "test", "mutation"))
            platforms = strings(proof.get("failed_then_passed_on"), proof_where + ".failed_then_passed_on")
            valid = (text_field(proof.get("pr")) and re.fullmatch(r"https://github\.com/sudoHG/immichSlides/pull/[1-9][0-9]*", proof["pr"])
                     and text_field(proof.get("test")) and proof["test"] in replacements
                     and text_field(proof.get("mutation")) and platforms == {"ios", "tvos"})
            check(bool(valid), "tier-plan-coverage", proof_where, f"invalid mutation_proof reference/evidence {proof!r}")
            if valid:
                proof_tests.add(proof["test"])
        check(row.get("status") == "pending" or row.get("status") == "covered" and bool(replacements)
              and replacements <= units and replacements == proof_tests, "tier-plan-coverage", where,
              f"status {row.get('status')!r} requires existing replacement_tests and mutation_proof for every test; missing {sorted(replacements - proof_tests)}")
    expected = {("ui", key) for key in ui} | {("strict", key) for key in strict}
    for key, count in Counter(keys).items():
        check(count == 1, "tier-plan-inventory", str(key), f"duplicate inventory identity ({count} rows)")
    for key in sorted(expected - set(keys)):
        check(False, "tier-plan-inventory", str(key), "missing inventory identity")
    for key in sorted(set(keys) - expected):
        check(False, "tier-plan-inventory", str(key), "unknown inventory identity")
    for identifier in sorted(pr_smoke):
        check(("ui", identifier) in keys, "tier-plan-pr-smoke", identifier,
              "missing functional_smoke inventory row with target_home pr-smoke")
    release_devices = []
    for index, value in enumerate(objects(plan.get("release_full_set"), "release_full_set")):
        where = f"release_full_set[{index}] {value.get('device')!r}" if isinstance(value, dict) else f"release_full_set[{index}]"
        entry = obj(value, where, ("device", "owner", "smoke_flows", "configurations", "unit_platform", "unit_and_interface_scope",
                                   "human_review_groups", "visual_variants", "additional_review"))
        device = entry.get("device")
        if text_field(device):
            release_devices.append(device)
        else:
            check(False, "tier-plan-shape", where, "device must be a nonempty string")
            device = None
        for field, expected in (("smoke_flows", {fid for fid, flow in flows.items() if flow.get("device") == device}),
                                ("human_review_groups", {gid for gid, devices in groups.items() if device in devices}),
                                ("configurations", {"Debug", "Release"})):
            actual = strings(entry.get(field), where + "." + field)
            check(actual == expected, "tier-plan-release", where,
                  f"{field}: missing {sorted(expected - actual)}; extra/unknown {sorted(actual - expected)}")
        for field in ("visual_variants", "additional_review"):
            check(bool(strings(entry.get(field), where + "." + field)), "tier-plan-release", where, f"missing {field}")
        check(entry.get("owner") == "Hogan", "tier-plan-release", where, "owner must be Hogan")
        check(entry.get("unit_platform") == ("tvos" if device == "tv" else "ios")
              and text_field(entry.get("unit_and_interface_scope")), "tier-plan-release", where, "invalid unit_platform/unit_and_interface_scope")
    check(Counter(release_devices) == {"iphone": 1, "ipad": 1, "tv": 1}, "tier-plan-release", "release_full_set",
          f"device population {release_devices!r}; expected iphone, ipad, tv once each")
    return errors


def unique_tier_json_object(pairs):
    """Reject duplicate keys before JSON's last-value-wins decoding can hide evidence."""
    result = {}
    for key, value in pairs:
        if key in result:
            identity = next((v for k, v in pairs if k in ("identifier", "id", "device")), "plan")
            raise ValueError(f"{identity}: duplicate JSON key {key!r}")
        result[key] = value
    return result


def check_test_tier_plan(root: Path) -> list[Violation]:
    from strict_e2e_runner_support import CommandError

    try:
        plan = json.loads((root / TEST_TIER_PLAN_PATH).read_text(encoding="utf-8"), object_pairs_hook=unique_tier_json_object)
        errors = validate_test_tier_plan(plan, *test_tier_context(root))
    except (OSError, ValueError, CommandError, KeyError, TypeError, IndexError) as error:
        return [Violation(TEST_TIER_PLAN_PATH, 1, "tier-plan-input", "target tiers", str(error))]
    return [Violation(TEST_TIER_PLAN_PATH, 1, error.split(":", 1)[0], "target tiers", error) for error in errors]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--write-allowlist", action="store_true",
                        help="regenerate scripts/test_conventions_allowlist.json from current violations")
    args = parser.parse_args(argv)
    root = Path(args.root)
    allowlist_path = root / ALLOWLIST_PATH

    violations = check_repository(root)

    if args.write_allowlist:
        print("WARNING: --write-allowlist regenerates the allowlist from whatever violations exist right now. "
              "This is for maintainers reconciling a known, reviewed state (e.g. after a rename pass) — "
              "it is not a way to make failing violations disappear. Review the diff before committing it.")
        write_allowlist(allowlist_path, violations)
        print(f"Wrote {len(violations)} entries to {allowlist_path}")
        return 0

    allowlist = load_allowlist(allowlist_path)
    # Production access is never allowlist-eligible.
    ordinary = [v for v in violations if v.rule != "product-wait-factor"]
    unallowed, stale = partition_against_allowlist(ordinary, allowlist)
    unallowed.extend(v for v in violations if v.rule == "product-wait-factor")
    unallowed.extend(check_test_tier_plan(root))

    timeout_path = root / TIMEOUT_ALLOWLIST_PATH
    timeout_allowed = json.loads(timeout_path.read_text(encoding="utf-8")) if timeout_path.is_file() else []
    timeout_added, timeout_stale = partition_timeout_allowlist(repository_timeout_inventory(root), timeout_allowed)

    for v in unallowed:
        print(v)
    for e in stale:
        print(f"{e['path']}: [stale-allowlist] {e['rule']} entry for `{e['name']}` no longer matches a violation")

    for e in timeout_added:
        print(f"{e['path']}: [raw-timeout] `{e['function']}`: {e['literal']} count={e['count']}")
    for e in timeout_stale:
        print(f"{e['path']}: [stale-timeout-allowlist] `{e['function']}`: {e['literal']} count={e['count']}")

    total = len(unallowed) + len(stale) + len(timeout_added) + len(timeout_stale)
    print(f"TEST_CONVENTIONS_{'FAIL' if total else 'PASS'} violations={len(unallowed)} stale_allowlist={len(stale)} "
          f"raw_timeouts={len(timeout_added)} stale_timeouts={len(timeout_stale)}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
