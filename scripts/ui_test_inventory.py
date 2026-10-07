"""Shared static UI inventory; no runner or candidate imports."""
from __future__ import annotations

import bisect
import re

PLATFORMS = ("ios", "tvos")

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
