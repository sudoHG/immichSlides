"""Host check: a UI test that uses an app-defined accessibility identifier selects with that file.

A default-plan UI test that references an identifier literal (directly or through any
helper, computed property or stored constant it reaches) depends on every app source
file that defines a matching literal. Such a test must belong to one of that file's
areas, or to the smoke set, so a change to the file schedules the test. Core files
always select the full population. A test only in nightly-default areas must also reach
one of its own leaf screens; a file it only navigates through is accepted only when the
reviewed list names it as a navigation source. Reviewed exceptions live in
scripts/ci-ui-flow-exceptions.json. The analysis over-approximates: helpers resolve
by name across files, and interpolations match any text.
"""

from __future__ import annotations

import re
from functools import lru_cache

from ci_summary import decode, fields, require, string
from ci_ui_selection import AREA_MAP_PATH, affected_areas, matches_test, parse_area_map
from ci_ui_shards import DEVICES, SELECTOR, default_plan_population
from ui_test_inventory import (CLASS_RE, FUNC_RE, blank_comments_and_strings, interpolation_end, line_platforms,
                               literal_or_comment_end, matching_brace)

EXCEPTIONS_PATH = "scripts/ci-ui-flow-exceptions.json"
# A dotted lowerCamel identifier; `*` stands for an interpolation and never starts it.
IDENTIFIER = re.compile(r"[a-z][A-Za-z0-9_]*(?:\.(?:[A-Za-z0-9_*-]+))+")
COMPUTED_RE = re.compile(r"\bvar\s+`?([A-Za-z_]\w*)`?\s*:[^={};]*\{")
STORED_RE = re.compile(r"\b(?:let|var|case)\s+`?([A-Za-z_]\w*)`?\s*(?::[^=\n{};]*)?=")
DECLARED_NAME_RE = re.compile(r"\b(?:let|var|func|case|class|struct|enum|extension|typealias)\s+$")
TOKEN_RE = re.compile(r"\b[A-Za-z_]\w*\b")
DELEGATE_RE = re.compile(r"AccessibilityI(?:D|dentifier)$")
LEXEME_START = re.compile(r"[`\"'/#]")


def identifier_literals(text):
    """(offset, pattern) for single-line string literals that look like identifiers."""
    found, index = [], 0
    while index < len(text):
        candidate = LEXEME_START.search(text, index)
        if candidate is None:
            break
        index = candidate.start()
        if text[index] == "`":
            index = text.index("`", index + 1) + 1
            continue
        end = literal_or_comment_end(text, index)
        if end is None:
            index += 1
            continue
        if text[index] == '"' and not text.startswith('"""', index):
            parts, position = [], index + 1
            while position < end - 1:
                if text.startswith("\\(", position):
                    after = interpolation_end(text, position + 1)
                    parts.append("*")
                    position = after
                elif text[position] == "\\":
                    parts = None
                    break
                else:
                    parts.append(text[position])
                    position += 1
            if parts is not None:
                pattern = re.sub(r"\*+", "*", "".join(parts))
                if IDENTIFIER.fullmatch(pattern):
                    found.append((index, pattern))
        index = max(end, index + 1)
    return found


def overlaps(left, right):
    """Whether two patterns, where `*` is any text, can name the same identifier."""
    @lru_cache(maxsize=None)
    def match(i, j):
        if i == len(left) and j == len(right):
            return True
        if i < len(left) and left[i] == "*":
            return match(i + 1, j) or (j < len(right) and match(i, j + 1))
        if j < len(right) and right[j] == "*":
            return match(i, j + 1) or (i < len(left) and match(i + 1, j))
        return i < len(left) and j < len(right) and left[i] == right[j] and match(i + 1, j + 1)

    return match(0, 0)


class SwiftSource:
    def __init__(self, name, text, *, app=False):
        self.name = name
        self.code = blank_comments_and_strings(text)
        errors = []
        self.lines = line_platforms(self.code, errors)
        if app and errors:
            self.lines = [{"ios", "tvos"}] * len(self.lines)  # unknown app conditions compile everywhere
        require(not errors or app, f"{name}: {'; '.join(errors)}")
        self.line_starts = [0]
        for line in self.code.split("\n"):
            self.line_starts.append(self.line_starts[-1] + len(line) + 1)
        self.literals = identifier_literals(text)
        self.scopes = [(match.end() - 1, matching_brace(self.code, match.end() - 1), match[1]) for match in
                       re.finditer(r"\b(?:class|extension|struct|enum)\s+([A-Za-z_]\w*)[^{]*\{", self.code)]

    def platforms_at(self, offset):
        low, high = 0, len(self.line_starts) - 1
        while low + 1 < high:
            middle = (low + high) // 2
            low, high = (middle, high) if self.line_starts[middle] <= offset else (low, middle)
        return self.lines[min(low, len(self.lines) - 1)]

    def patterns(self, start, end, platform):
        return {pattern for offset, pattern in self.literals
                if start <= offset < end and platform in self.platforms_at(offset)}

    def owner(self, offset):
        owners = [(start, name) for start, end, name in self.scopes if start < offset < end]
        return max(owners)[1] if owners else None

    def references(self, start, end, platform):
        """(name, called, receiver) for each token; receiver is None, "self" or "other"."""
        found = set()
        for match in TOKEN_RE.finditer(self.code, start, end):
            before = self.code[max(start, match.start() - 16):match.start()]
            if platform not in self.platforms_at(match.start()) or DECLARED_NAME_RE.search(before):
                continue
            after = self.code[match.end():match.end() + 64].lstrip()
            if after.startswith(":") and not after.startswith("::"):
                continue  # an argument label or a type annotation
            dotted = re.search(r"(\bself\s*)?\.\s*$", before)
            receiver = None if dotted is None else "self" if dotted[1] else "other"
            found.add((match[0], after[:1] in {"(", "{"}, receiver))
        return found


class FlowGraph:
    """Helper graph over the UI test and TestSupport sources, resolved by name.

    A bare or self call prefers the caller's own type, then anything that is not another
    XCTestCase class; a call on another receiver may reach every definition of the name.
    """

    def __init__(self, files):
        self.files = [SwiftSource(name, text) for name, text in sorted(files.items())]
        self.test_classes = {match[1] for source in self.files for match in CLASS_RE.finditer(source.code)}
        self.symbols = {}  # name -> [(called, owner, file, start, end)]
        self.methods = {}  # (type, name) -> [(file, start, end)]
        self.cache = {}
        for source in self.files:
            code, bodies = source.code, []
            for match in FUNC_RE.finditer(code):
                close = code.find(")", match.end())
                brace = code.find("{", match.end())
                if brace < 0 or re.search(r"\bfunc\b|\bvar\b|\blet\b|\}", code[close:brace]):
                    continue
                span = (brace, matching_brace(code, brace))
                bodies.append(span)
                owner = source.owner(match.start())
                self.symbols.setdefault(match[2], []).append((True, owner, source, *span))
                self.methods.setdefault((owner, match[2]), []).append((source, *span))
            for match in COMPUTED_RE.finditer(code):
                span = (match.end() - 1, matching_brace(code, match.end() - 1))
                bodies.append(span)
                self.symbols.setdefault(match[1], []).append((False, source.owner(match.start()), source, *span))
            for match in STORED_RE.finditer(code):
                if any(start < match.start() < end for start, end in bodies):
                    continue  # locals are already part of their function body
                text = files[source.name]
                start = len(text) - len(text[match.end():].lstrip(" \t"))
                if text.startswith('"', start):
                    self.symbols.setdefault(match[1], []).append(
                        (False, source.owner(match.start()), source, start, literal_or_comment_end(text, start)))

    def resolve(self, name, called, receiver, caller):
        candidates = [symbol for symbol in self.symbols.get(name, []) if symbol[0] == called]
        if receiver == "other":
            return candidates
        own = [symbol for symbol in candidates if symbol[1] == caller]
        return own or [symbol for symbol in candidates if symbol[1] not in self.test_classes]

    def edges(self, source, start, end, platform):
        key = (source.name, start, platform)
        if key not in self.cache:
            caller = source.owner(start)
            self.cache[key] = (source.patterns(start, end, platform), [
                (target, target_start, target_end)
                for name, called, receiver in source.references(start, end, platform)
                for _called, _owner, target, target_start, target_end in self.resolve(name, called, receiver, caller)])
        return self.cache[key]

    def test_patterns(self, key, platform):
        owner, _, method = key.partition("/")
        spans = self.methods.get((owner, method), [])
        require(spans, f"cannot locate UI test body: {key}")
        patterns, seen, pending = set(), set(), list(spans)
        while pending:
            found, targets = self.edges(*pending.pop(), platform)
            patterns |= found
            for target in targets:
                if (target[0].name, target[1]) not in seen:
                    seen.add((target[0].name, target[1]))
                    pending.append(target)
        return patterns


def parse_exceptions(raw):
    """Reviewed exceptions: an identifier from one app file, or a test that never launches the app."""
    document = decode(raw)
    fields(document, {"schema_version", "exceptions"}, "UI flow exceptions")
    require(type(document["schema_version"]) is int and document["schema_version"] == 1,
            "unsupported UI flow exceptions version")
    require(isinstance(document["exceptions"], list), "UI flow exceptions must be an array")
    require(len(document["exceptions"]) <= 24, "UI flow exceptions must remain a small reviewed list")
    seen = set()
    for entry in document["exceptions"]:
        require(isinstance(entry, dict), "UI flow exception must be an object")
        fields(entry, {"identifier", "source", "reason"} if "identifier" in entry else
               {"navigation", "areas", "reason"} if "navigation" in entry else {"test", "reason"}, "UI flow exception")
        for name, value in entry.items():
            if name == "areas":
                require(isinstance(value, list) and value and all(isinstance(item, str) for item in value)
                        and len(set(value)) == len(value), "UI flow navigation areas must be distinct names")
            else:
                string(value, "UI flow exception field")
        require("\n" not in entry["reason"] and len(entry["reason"]) <= 200,
                "UI flow exception reason must be one line")
        if "test" in entry:
            require(SELECTOR.fullmatch(entry["test"]) is not None, "UI flow exception test must be a selector")
        elif "navigation" in entry:
            require(entry["navigation"].startswith("immichSlides/") and entry["navigation"].endswith(".swift")
                    and "*" not in entry["navigation"], "UI flow navigation source must name one app Swift file")
        else:
            require(IDENTIFIER.fullmatch(entry["identifier"]) is not None, "invalid UI flow exception identifier")
        key = tuple(value for name, value in sorted(entry.items()) if name not in {"reason", "areas"})
        require(key not in seen, "duplicate UI flow exception")
        seen.add(key)
    return document["exceptions"]


def app_patterns(app_files):
    """platform -> {pattern: {paths}} for app Swift files compiled on that platform.

    A file that calls an `...AccessibilityID` / `...AccessibilityIdentifier` function also
    defines the identifiers that function returns, as the delegated screen renders them.
    """
    sources = {path: SwiftSource(path, text, app=True) for path, text in sorted(app_files.items())}
    result = {"ios": {}, "tvos": {}}
    for platform, patterns in result.items():
        other = "immichSlides/" + {"ios": "tvOS", "tvos": "iOS"}[platform] + "/"
        compiled = {path: source for path, source in sources.items() if not path.startswith(other)}
        exported = {}
        for source in compiled.values():
            for match in FUNC_RE.finditer(source.code):
                if DELEGATE_RE.search(match[2]) and platform in source.platforms_at(match.start()):
                    brace = source.code.find("{", match.end())
                    found = source.patterns(brace, matching_brace(source.code, brace), platform)
                    exported.setdefault(match[2], set()).update(found)
        for path, source in compiled.items():
            found = source.patterns(0, len(source.code), platform)
            for name, called, _receiver in source.references(0, len(source.code), platform):
                if called:
                    found |= exported.get(name, set())
            for pattern in found:
                patterns.setdefault(pattern, set()).add(path)
    return result


def flow_violations(raw_map, raw_exceptions, app_files, test_files, populations, plans):
    area_map = parse_area_map(raw_map)
    exceptions = parse_exceptions(raw_exceptions)
    require(all(set(item.get("areas", [])) <= set(area_map["nightly_default"]) for item in exceptions),
            "UI flow navigation sources apply only to nightly-default areas")
    graph = FlowGraph(test_files)
    definitions = app_patterns(app_files)
    defining = {}  # (platform, used pattern) -> app paths with an overlapping literal
    used, violations, path_areas = set(), set(), {}
    for device, platform in DEVICES.items():
        for entry in default_plan_population(populations["ui-" + platform], plans[platform]):
            key = entry["key"]
            if matches_test(key, area_map["smoke"]):
                continue
            skipped = [index for index, item in enumerate(exceptions)
                       if "test" in item and matches_test(key, [item["test"]])]
            own = [name for name, area in area_map["areas"].items() if matches_test(key, area["tests"])]
            nightly_only = bool(own) and set(own) <= set(area_map["nightly_default"])
            found, leaf = set(), False
            for pattern in sorted(graph.test_patterns(key, platform)):
                if (platform, pattern) not in defining:
                    defining[platform, pattern] = sorted({path for defined, paths in definitions[platform].items()
                                                          if overlaps(pattern, defined) for path in paths})
                for path in defining[platform, pattern]:
                    if path not in path_areas:
                        path_areas[path] = affected_areas(path, area_map)
                    areas = path_areas[path]
                    if set(own) & set(areas):
                        leaf = True
                    if "core" in areas or set(own) & set(areas):
                        continue
                    excepted = [index for index, item in enumerate(exceptions)
                                if item.get("identifier") == pattern and item.get("source") == path
                                or nightly_only and item.get("navigation") == path and set(own) & set(item["areas"])]
                    if excepted:
                        used.update(excepted)
                        continue
                    found.add(f"{key} reaches {pattern} defined in {path}; add it to one of {areas}")
            if nightly_only and not leaf:
                found.add(f"{key} is nightly-default but reaches no identifier from its areas' screens {own}")
            if found and skipped:
                used.update(skipped)
            elif found:
                violations |= found
    for index, item in enumerate(exceptions):
        if index not in used:
            violations.add("stale UI flow exception: " + ", ".join(
                f"{name}={value}" for name, value in sorted(item.items()) if name not in {"reason", "areas"}))
    return sorted(violations)


def check_flows(root, populations):
    """Host entry point; populations are the producer's immichSlidesUITests identities."""
    tests = {path.relative_to(root).as_posix(): path.read_text(encoding="utf-8")
             for folder in ("immichSlidesUITests", "TestSupport") for path in (root / folder).rglob("*.swift")}
    app = {path.relative_to(root).as_posix(): path.read_text(encoding="utf-8")
           for path in (root / "immichSlides").rglob("*.swift")}
    plans = {platform: (root / ("immichSlides-" + suffix + ".xctestplan")).read_text(encoding="utf-8")
             for platform, suffix in (("ios", "iOS"), ("tvos", "tvOS"))}
    return flow_violations((root / AREA_MAP_PATH).read_text(encoding="utf-8"),
                           (root / EXCEPTIONS_PATH).read_text(encoding="utf-8"), app, tests, populations, plans)
