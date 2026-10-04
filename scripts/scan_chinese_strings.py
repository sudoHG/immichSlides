#!/usr/bin/env python3
"""Scan Swift source files for user-facing literals missing from the string catalog, and for
Chinese string literals in code.

English is the source language, so the catalog checks apply to literals in any language: a
user-facing literal that is missing from the catalog fails the scan. `scripts/check_all.sh` runs it.
A literal that must not be translated, such as a hidden UI-test probe label, is excluded with a
`// localization-audit: <reason>` comment on one of the three lines before it.

This scanner is stricter than the earlier ad-hoc regex pass:
- it understands normal strings and triple-quoted multiline strings;
- it skips line comments and block comments;
- it separates localized UI strings from raw runtime literals;
- it understands `#Preview` and preview/UI-test fixture scopes;
- it normalizes Swift escapes and interpolation placeholders before catalog
  lookup;
- it reports diagnostics, internal identifiers, and explicit audit exclusions
  separately so they do not get mixed with real UI leakage.

The goal is to catch cases like:
- multiline debug text blocks;
- raw Chinese `return "..."` literals;
- strings that exist in `Localizable.xcstrings` but are still emitted
  directly instead of going through `String(localized:)`.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator

from validate_localization_catalog import TARGET_LOCALES


HAN_RE = re.compile(r"[\u4e00-\u9fff]")
FORMAT_SPECIFIER_RE = re.compile(
    r"%(?:\d+\$)?(?:@|lld|llu|ld|lu|d|u|f|g|s|c)"
)
# Call names must start a word, so `keypadButton(` is not read as `Button(`.
LOCALIZED_CONTEXT_RE = re.compile(
    r"(?:(?<![A-Za-z0-9_])(?:(?:Attributed)?String\s*\(\s*localized\s*:|LocalizedText\.format\s*\(|"
    r"LocalizedStringKey\s*\(|"
    r"LocalizedStringResource\s*\(|Text\s*\(|Button\s*\(|Label\s*\(|"
    r"Toggle\s*\(|Picker\s*\(|ProgressView\s*\(|NavigationLink\s*\(|Section\s*\()|"
    r"\.(?:navigationTitle|alert|accessibilityLabel|accessibilityHint)\s*\()\s*$",
    re.DOTALL,
)
# A literal needs translating only if it contains letters (any script), not just placeholders,
# digits or symbols.
WORD_RE = re.compile(r"[^\W\d_]")
DIAGNOSTIC_CONTEXT_RE = re.compile(
    r"(?:print|debugPrint|dump|os_log|assertionFailure|preconditionFailure|fatalError)"
    r"\s*\([^\"]*$",
    re.DOTALL,
)
INTERNAL_IDENTIFIER_CONTEXT_RE = re.compile(
    r"\bcase\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*$"
)
DECLARATION_SCOPE_RE = re.compile(
    r"\b(?:func|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)[^{}]*$",
    re.DOTALL,
)
AUDIT_EXCLUSION_RE = re.compile(r"localization-audit:\s*([a-z0-9-]+)")


@dataclass(frozen=True)
class StringHit:
    path: Path
    line: int
    literal: str
    prefix: str
    category: str
    in_catalog: bool
    localized_context: bool


def load_catalog_strings(root: Path) -> dict[str, dict]:
    """Load the whole string catalog.

    Xcode normalizes interpolated source strings into placeholder keys such as `%lld` / `%@`, and these
    keys can exist without an English value. Checking missing translations therefore needs the full catalog
    entries, not only the keys found in source.
    """

    catalog_path = root / "immichSlides" / "Localizable.xcstrings"
    with catalog_path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    return data.get("strings", {})


def find_catalog_missing_localizations(strings: dict[str, dict]) -> list[tuple[str, str]]:
    """Find live catalog keys that are missing any target locale."""

    missing: list[tuple[str, str]] = []
    for key, payload in strings.items():
        if not key or payload.get("extractionState") == "stale":
            continue

        localizations = payload.get("localizations", {})
        for locale in TARGET_LOCALES:
            if locale not in localizations:
                missing.append((locale, key))

    return sorted(missing)


def normalize_key_shape(key: str) -> str:
    """Normalize catalog format specifiers and Swift interpolation to `{}`."""

    key = FORMAT_SPECIFIER_RE.sub("{}", key)
    result: list[str] = []
    index = 0

    while index < len(key):
        if key[index] == "\\" and index + 1 < len(key) and key[index + 1] == "(":
            result.append("{}")
            index += 2
            depth = 1
            while index < len(key) and depth > 0:
                if key[index] == "(":
                    depth += 1
                elif key[index] == ")":
                    depth -= 1
                index += 1
            continue

        result.append(key[index])
        index += 1

    return "".join(result)


def decode_swift_literal(literal: str) -> str:
    """Decode the common Swift escapes that also appear decoded in xcstrings."""

    escapes = {
        "0": "\0",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        '"': '"',
        "'": "'",
        "\\": "\\",
    }
    result: list[str] = []
    index = 0
    while index < len(literal):
        if literal[index] != "\\" or index + 1 >= len(literal):
            result.append(literal[index])
            index += 1
            continue

        escaped = literal[index + 1]
        if escaped in escapes:
            result.append(escapes[escaped])
            index += 2
            continue

        # `\(` is Swift interpolation, not a normal escape; leave it for placeholder normalization.
        result.append("\\")
        index += 1

    return "".join(result)


def declaration_scope_label(segment: str) -> str | None:
    match = DECLARATION_SCOPE_RE.search(segment)
    return match.group(1) if match else None


def scope_is_fixture(scope_stack: list[str | None]) -> bool:
    for label in scope_stack:
        if not label:
            continue

        normalized = label.lower()
        if (
            normalized in {"preview", "previewassets"}
            or normalized.startswith("makepreview")
            or normalized.endswith("forpreview")
            or normalized.endswith("previewmodel")
            or "uitesting" in normalized
        ):
            return True

    return False


def iter_swift_files(root: Path, include_tests: bool) -> Iterator[Path]:
    for path in (root / "immichSlides").rglob("*.swift"):
        if not include_tests and ("immichSlidesTests" in path.parts or "immichSlidesUITests" in path.parts):
            continue
        yield path


def skip_line_comment(text: str, index: int) -> int:
    while index < len(text) and text[index] != "\n":
        index += 1
    return index


def skip_block_comment(text: str, index: int) -> int:
    depth = 1
    index += 2
    while index < len(text) and depth > 0:
        if text.startswith("/*", index):
            depth += 1
            index += 2
            continue
        if text.startswith("*/", index):
            depth -= 1
            index += 2
            continue
        index += 1
    return index


def extract_string_hits(
    path: Path,
    text: str,
    catalog_keys: set[str],
    require_han: bool = True,
) -> Iterable[StringHit]:
    index = 0
    line = 1
    scope_stack: list[str | None] = []
    pending_preview_scope = False
    last_structural_index = -1
    catalog_shapes = {normalize_key_shape(key) for key in catalog_keys}

    while index < len(text):
        ch = text[index]

        if ch == "\n":
            line += 1
            index += 1
            continue

        if text.startswith("//", index):
            index = skip_line_comment(text, index)
            continue

        if text.startswith("/*", index):
            index = skip_block_comment(text, index)
            continue

        if text.startswith("#Preview", index):
            pending_preview_scope = True
            index += len("#Preview")
            continue

        if ch == "{":
            segment = text[last_structural_index + 1:index]
            label = "#Preview" if pending_preview_scope else declaration_scope_label(segment)
            scope_stack.append(label)
            pending_preview_scope = False
            last_structural_index = index
            index += 1
            continue

        if ch == "}":
            if scope_stack:
                scope_stack.pop()
            last_structural_index = index
            index += 1
            continue

        if ch != '"':
            index += 1
            continue

        start_line = line
        line_start = text.rfind("\n", 0, index) + 1
        prefix = text[line_start:index]
        context_window = text[max(0, index - 500):index]
        audit_window = "\n".join(context_window.splitlines()[-3:])

        if text.startswith('"""', index):
            index += 3
            start = index
            while index < len(text):
                if text.startswith('"""', index):
                    literal = text[start:index]
                    index += 3
                    break
                if text[index] == "\n":
                    line += 1
                index += 1
            else:
                literal = text[start:]
        else:
            index += 1
            start = index
            escaped = False
            while index < len(text):
                c = text[index]
                if c == "\n":
                    line += 1
                if escaped:
                    escaped = False
                    index += 1
                    continue
                if c == "\\":
                    escaped = True
                    index += 1
                    continue
                if c == '"':
                    literal = text[start:index]
                    index += 1
                    break
                index += 1
            else:
                literal = text[start:]

        decoded_literal = decode_swift_literal(literal)
        if not require_han or HAN_RE.search(decoded_literal):
            localized_context = bool(LOCALIZED_CONTEXT_RE.search(context_window))
            preview_context = (
                pending_preview_scope
                or "#Preview" in scope_stack
                or scope_is_fixture(scope_stack)
                or "Preview" in path.name
            )
            audit_exclusion = AUDIT_EXCLUSION_RE.search(audit_window)
            diagnostic_context = (
                bool(DIAGNOSTIC_CONTEXT_RE.search(context_window))
                or "debug" in path.stem.lower()
                or "diagnostic" in path.stem.lower()
            )
            internal_identifier_context = bool(INTERNAL_IDENTIFIER_CONTEXT_RE.search(prefix))
            in_catalog = (
                decoded_literal in catalog_keys
                or normalize_key_shape(decoded_literal) in catalog_shapes
            )

            if preview_context:
                category = "preview"
            elif audit_exclusion:
                category = f"audit-excluded:{audit_exclusion.group(1)}"
            elif diagnostic_context:
                category = "diagnostic"
            elif internal_identifier_context:
                category = "internal-identifier"
            elif localized_context:
                category = "localized"
            else:
                category = "raw-runtime"

            yield StringHit(
                path=path,
                line=start_line,
                literal=decoded_literal,
                prefix=prefix.rstrip(),
                category=category,
                in_catalog=in_catalog,
                localized_context=localized_context,
            )


def bucket_for_hit(hit: StringHit) -> str | None:
    """Return the report bucket for a literal, or None when it needs no report.

    English is the source language, so the catalog checks look at literals in any language. The
    other buckets exist to track Chinese text in code and only report Chinese literals.
    """

    is_chinese = bool(HAN_RE.search(hit.literal))
    if hit.category == "localized":
        has_words = bool(WORD_RE.search(normalize_key_shape(hit.literal)))
        return "localized-missing" if has_words and not hit.in_catalog else None
    if hit.category.startswith("audit-excluded:"):
        return "audit-excluded"
    if hit.category == "raw-runtime":
        if hit.in_catalog:
            return "raw-runtime-in-catalog"
        return "raw-runtime-missing" if is_chinese else None
    return hit.category if is_chinese else None


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan Swift files for Chinese literals.")
    parser.add_argument("--root", default=".", help="Repository root directory")
    parser.add_argument("--include-tests", action="store_true", help="Also scan test targets")
    parser.add_argument("--limit", type=int, default=200, help="Maximum lines to print per category")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    catalog_strings = load_catalog_strings(root)
    catalog_keys = set(catalog_strings.keys())
    catalog_missing_localizations = find_catalog_missing_localizations(catalog_strings)

    buckets: dict[str, list[StringHit]] = {
        "raw-runtime-missing": [],
        "raw-runtime-in-catalog": [],
        "localized-missing": [],
        "preview": [],
        "diagnostic": [],
        "internal-identifier": [],
        "audit-excluded": [],
    }

    for path in iter_swift_files(root, include_tests=args.include_tests):
        text = path.read_text(encoding="utf-8")
        for hit in extract_string_hits(path, text, catalog_keys, require_han=False):
            bucket = bucket_for_hit(hit)
            if bucket is not None:
                buckets[bucket].append(hit)

    print(f"catalog_keys={len(catalog_keys)}")
    print(f"catalog-missing-localizations={len(catalog_missing_localizations)}")
    for locale, key in catalog_missing_localizations[: args.limit]:
        print(f"catalog:{locale}:{key}")
    if len(catalog_missing_localizations) > args.limit:
        print(f"... truncated {len(catalog_missing_localizations) - args.limit} more")

    for name in (
        "localized-missing",
        "raw-runtime-missing",
        "raw-runtime-in-catalog",
        "preview",
        "diagnostic",
        "internal-identifier",
        "audit-excluded",
    ):
        hits = buckets[name]
        print(f"{name}={len(hits)}")
        for hit in hits[: args.limit]:
            print(f"{hit.path.relative_to(root)}:{hit.line}: {hit.literal}")
        if len(hits) > args.limit:
            print(f"... truncated {len(hits) - args.limit} more")

    return 0 if (
        not catalog_missing_localizations
        and not buckets["localized-missing"]
        and not buckets["raw-runtime-missing"]
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
