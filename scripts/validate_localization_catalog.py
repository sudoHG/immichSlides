#!/usr/bin/env python3
"""Validate release-localization coverage, review state, and placeholders."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator


SOURCE_LANGUAGE = "en"
# The source language is English: keys are the English text, so English needs no translation entry.
# An explicit English entry is still allowed (for example a plural or a key disambiguated from another
# key with the same English text) and is checked like a translation.
TARGET_LOCALES = ("zh-Hans", "es", "ja", "zh-Hant-HK", "zh-Hant-TW")
# Catches Han, kana and Hangul in a key. It is a heuristic: keys in other non-Latin scripts
# (Cyrillic, Arabic, Thai, ...) or in Latin-script languages such as Spanish are not detected.
NON_ENGLISH_SCRIPT_RE = re.compile(
    r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff"
    r"\u3041-\u309f\u30a1-\u30fa\u30fd-\u30ff\u31f0-\u31ff\uff66-\uff9f"
    r"\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]"
)
FORMAT_SPECIFIER_RE = re.compile(
    r"%(?:(\d+)\$)?(@|lld|llu|ld|lu|d|u|f|g|s|c)"
)
SUBSTITUTION_REFERENCE_RE = re.compile(r"%(?:(\d+)\$)?#@([A-Za-z0-9_]+)@")
UNREVIEWED_STATES = {"new", "needs_review"}


@dataclass(frozen=True)
class CatalogValidationResult:
    label: str
    key_count: int
    required_key_count: int
    coverage: dict[str, int]
    issues: tuple[str, ...]


def iter_string_units(node: object, path: str = "") -> Iterator[tuple[str, dict]]:
    if isinstance(node, dict):
        unit = node.get("stringUnit")
        if isinstance(unit, dict):
            yield path or "stringUnit", unit

        for key, value in node.items():
            if key == "stringUnit":
                continue
            child_path = f"{path}.{key}" if path else key
            yield from iter_string_units(value, child_path)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from iter_string_units(value, f"{path}[{index}]")


def is_integer(value: object) -> bool:
    """True for an int that is not a bool (bool is an int subclass in Python)."""

    return isinstance(value, int) and not isinstance(value, bool)


def placeholder_signature(value: str) -> tuple[tuple[int, str], ...]:
    """Return argument index/type pairs, normalizing positional specifiers."""

    implicit_index = 1
    signature: list[tuple[int, str]] = []
    for match in FORMAT_SPECIFIER_RE.finditer(value):
        explicit_index, value_type = match.groups()
        if explicit_index is None:
            argument_index = implicit_index
            implicit_index += 1
        else:
            argument_index = int(explicit_index)
        signature.append((argument_index, value_type))

    return tuple(sorted(signature))


def placeholder_issues_for_localization(
    key: str,
    locale: str,
    localization: dict,
) -> list[str]:
    """Validate direct placeholders and String Catalog plural substitutions."""

    source_signature = placeholder_signature(key)
    substitutions = localization.get("substitutions")
    if not isinstance(substitutions, dict) or not substitutions:
        issues: list[str] = []
        for unit_path, unit in iter_string_units(localization):
            target_signature = placeholder_signature(unit.get("value", ""))
            if target_signature != source_signature:
                issues.append(
                    f"placeholder:{locale}:{key}:{unit_path}:"
                    f"source={source_signature}:target={target_signature}"
                )
        return issues

    issues = []
    top_level_unit = localization.get("stringUnit")
    if not isinstance(top_level_unit, dict):
        return [f"missing-string-unit:{locale}:{key}:stringUnit"]

    top_level_value = top_level_unit.get("value", "")
    references = SUBSTITUTION_REFERENCE_RE.findall(top_level_value)
    referenced_names = [name for _, name in references]
    composed_signature = list(placeholder_signature(top_level_value))

    for name in referenced_names:
        substitution = substitutions.get(name)
        if not isinstance(substitution, dict):
            issues.append(f"substitution-missing:{locale}:{key}:{name}")
            continue

        argument_number = substitution.get("argNum")
        format_specifier = substitution.get("formatSpecifier")
        if not is_integer(argument_number) or not isinstance(format_specifier, str):
            issues.append(f"substitution-metadata:{locale}:{key}:{name}")
            continue
        composed_signature.append((argument_number, format_specifier))

    unreferenced_names = sorted(set(substitutions) - set(referenced_names))
    for name in unreferenced_names:
        issues.append(f"substitution-unreferenced:{locale}:{key}:{name}")

    normalized_composed_signature = tuple(sorted(composed_signature))
    if normalized_composed_signature != source_signature:
        issues.append(
            f"placeholder:{locale}:{key}:stringUnit:"
            f"source={source_signature}:target={normalized_composed_signature}"
        )

    source_by_argument = dict(source_signature)
    for name, substitution in substitutions.items():
        if not isinstance(substitution, dict):
            continue
        argument_number = substitution.get("argNum")
        format_specifier = substitution.get("formatSpecifier")
        if not is_integer(argument_number) or not isinstance(format_specifier, str):
            continue

        expected_specifier = source_by_argument.get(argument_number)
        if expected_specifier != format_specifier:
            issues.append(
                f"substitution-type:{locale}:{key}:{name}:"
                f"source={expected_specifier}:target={format_specifier}"
            )

        expected_signature = ((argument_number, format_specifier),)
        for unit_path, unit in iter_string_units(substitution, f"substitutions.{name}"):
            target_signature = placeholder_signature(unit.get("value", ""))
            if target_signature != expected_signature:
                issues.append(
                    f"placeholder:{locale}:{key}:{unit_path}:"
                    f"source={expected_signature}:target={target_signature}"
                )

    return issues


def validate_catalog(
    path: Path,
    label: str,
    require_all_live_keys: bool,
    require_source_translation: bool = False,
) -> CatalogValidationResult:
    """Validate one string catalog.

    `require_source_translation` makes an explicit English entry mandatory for every required key.
    Info.plist keys need it: their key is a plist key name, not English text, so without an `en`
    entry an unsupported-language device would fall back to the raw Info.plist value.
    """
    catalog = json.loads(path.read_text(encoding="utf-8"))
    strings: dict[str, dict] = catalog.get("strings", {})
    issues: list[str] = []
    source_language = catalog.get("sourceLanguage")
    if source_language != SOURCE_LANGUAGE:
        issues.append(f"source-language:{source_language}")
    required_locales = ((SOURCE_LANGUAGE,) if require_source_translation else ()) + TARGET_LOCALES
    coverage = {locale: 0 for locale in required_locales}
    required_keys: list[str] = []

    for key, payload in strings.items():
        extraction_state = payload.get("extractionState")
        if not key:
            issues.append("empty-key")
            continue
        if extraction_state == "stale":
            issues.append(f"stale:{key}")
            continue
        if NON_ENGLISH_SCRIPT_RE.search(key):
            issues.append(f"source-not-english:{key}")

        is_required = require_all_live_keys or extraction_state == "manual"
        if is_required:
            required_keys.append(key)

        localizations = payload.get("localizations", {})
        for locale, localization in localizations.items():
            units = list(iter_string_units(localization))
            for unit_path, unit in units:
                state = unit.get("state")
                if state is None:
                    issues.append(f"state-missing:{locale}:{key}:{unit_path}")
                elif state in UNREVIEWED_STATES:
                    issues.append(f"unreviewed:{locale}:{key}:{unit_path}:{state}")
                elif state != "translated":
                    issues.append(f"state-unknown:{locale}:{key}:{unit_path}:{state}")
                if not unit.get("value", ""):
                    issues.append(f"empty-value:{locale}:{key}:{unit_path}")

        if not is_required:
            continue

        source_localization = localizations.get(SOURCE_LANGUAGE)
        if source_localization is not None and not require_source_translation:
            issues.extend(
                placeholder_issues_for_localization(
                    key,
                    SOURCE_LANGUAGE,
                    source_localization,
                )
            )

        for locale in required_locales:
            localization = localizations.get(locale)
            if localization is None:
                issues.append(f"missing:{locale}:{key}")
                continue

            units = list(iter_string_units(localization))
            if not units:
                issues.append(f"missing-string-unit:{locale}:{key}")
                continue

            locale_is_complete = True
            for unit_path, unit in units:
                if unit.get("state") != "translated" or not unit.get("value", ""):
                    locale_is_complete = False

            placeholder_issues = placeholder_issues_for_localization(
                key,
                locale,
                localization,
            )
            if placeholder_issues:
                issues.extend(placeholder_issues)
                locale_is_complete = False

            if locale_is_complete:
                coverage[locale] += 1

    if require_all_live_keys and not required_keys:
        issues.append("required-empty")

    required_key_count = len(required_keys)
    for locale in required_locales:
        if coverage[locale] != required_key_count:
            issues.append(
                f"coverage:{locale}:{coverage[locale]}/{required_key_count}"
            )

    return CatalogValidationResult(
        label=label,
        key_count=len(strings),
        required_key_count=required_key_count,
        coverage=coverage,
        issues=tuple(issues),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="Repository root directory")
    parser.add_argument("--limit", type=int, default=200, help="Maximum issues to print")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    results = (
        validate_catalog(
            root / "immichSlides" / "Localizable.xcstrings",
            label="Localizable",
            require_all_live_keys=True,
        ),
        validate_catalog(
            root / "immichSlides" / "InfoPlist.xcstrings",
            label="InfoPlist",
            require_all_live_keys=False,
            require_source_translation=True,
        ),
    )

    all_issues: list[str] = []
    for result in results:
        print(f"{result.label}.keys={result.key_count}")
        print(f"{result.label}.required={result.required_key_count}")
        for locale in result.coverage:
            print(
                f"{result.label}.coverage.{locale}="
                f"{result.coverage[locale]}/{result.required_key_count}"
            )
        print(f"{result.label}.issues={len(result.issues)}")
        all_issues.extend(f"{result.label}:{issue}" for issue in result.issues)

    for issue in all_issues[: args.limit]:
        print(issue)
    if len(all_issues) > args.limit:
        print(f"... truncated {len(all_issues) - args.limit} more")

    print(f"status={'PASS' if not all_issues else 'FAIL'}")
    return 0 if not all_issues else 1


if __name__ == "__main__":
    raise SystemExit(main())
