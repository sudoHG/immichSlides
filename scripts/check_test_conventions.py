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

    def expression_end(start):
        depth = 0
        for index in range(start, len(code)):
            character = code[index]
            if depth == 0 and character in ",);\n{}":
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

CHECKS = (check_forbidden_names, check_display_names, check_swift_testing_names, check_source_text,
          check_unbounded_waits, check_ui_label_lookups)


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
