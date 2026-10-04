#!/usr/bin/env python3
"""Clean stale entries in Localizable.xcstrings.

Notes:
This script only handles Xcode String Catalog entries with `extractionState = "stale"`.

Why do stale entries appear?
- Xcode extracts localizable strings automatically while scanning the source.
- If a key was extracted before but the extractor no longer "recognizes" it on a rescan,
  Xcode marks it stale and shows the warning
  "References to this key could not be found in source code" in the editor.

The script handles stale entries in three steps:
1. If a stale key cannot be found anywhere in the source, delete it.
   This usually means it really is a leftover entry.
2. If a stale key is only an old interpolation form and the catalog already has the new placeholder key,
   move the missing translations to the new key, then delete the old key.
3. If a stale key can still be found in the source but there is no better new key,
   only remove `extractionState = stale`.
   This keeps it as a "manually maintained valid translation entry".

The goal is not to "bluntly hide the warnings" but to clear out truly obsolete entries
and turn entries that are still valid but misjudged by the extractor into a stable state.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from scan_chinese_strings import extract_string_hits


ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "immichSlides" / "Localizable.xcstrings"
SOURCE_ROOT = ROOT / "immichSlides"



FORMAT_SPECIFIER_RE = re.compile(r"%(?:\d+\$)?(?:@|lld|llu|d|f)")


def load_catalog() -> dict:
    """Read the whole xcstrings JSON."""

    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def load_swift_sources() -> dict[Path, str]:
    """Read all Swift files; used later to check whether a key still appears in the source."""

    return {
        path: path.read_text(encoding="utf-8")
        for path in SOURCE_ROOT.rglob("*.swift")
    }


def normalize_key_shape(key: str) -> str:
    """Normalize interpolated keys and placeholder keys to one shape.

    Examples:
    - `Current \(count) photos` is normalized to `Current {} photos`
    - `Current %lld photos` is also normalized to `Current {} photos`

    This lets us tell that "these two keys are really two forms of the same string".
    """

    key = FORMAT_SPECIFIER_RE.sub("{}", key)
    result: list[str] = []
    index = 0

    while index < len(key):
        
        if key[index] == "\\" and index + 1 < len(key) and key[index + 1] == "(":
            result.append("{}")
            index += 2
            depth = 1

            # Interpolations can contain parentheses, so do not stop at the first `)`.

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


def source_hits_for_key(key: str, sources: dict[Path, str]) -> list[Path]:
    """Find which Swift files reference a key as a complete string literal."""

    return source_hits_by_key({key}, sources).get(key, [])


def source_hits_by_key(
    keys: set[str],
    sources: dict[Path, str],
) -> dict[str, list[Path]]:
    """Scan the source once and build an index from exact string literals to files."""

    hits_by_key: dict[str, list[Path]] = {}
    for path, text in sources.items():
        for hit in extract_string_hits(path, text, keys, require_han=False):
            if hit.literal in keys:
                hits_by_key.setdefault(hit.literal, []).append(path)
    return hits_by_key


def merge_missing_localizations(from_entry: dict, into_entry: dict) -> int:
    """Move translations that are still useful from the old key to the new key.

    Only fills in "languages the new key does not have yet", so translations you already fixed by hand
    are not overwritten. Returns how many locale entries were copied.
    """

    from_localizations = from_entry.get("localizations", {})
    into_localizations = into_entry.setdefault("localizations", {})

    copied = 0
    for language, payload in from_localizations.items():
        if language not in into_localizations:
            into_localizations[language] = payload
            copied += 1
    return copied


def clean_catalog() -> tuple[int, int, int]:
    """Run the cleanup and return statistics.

    The return values are, in order:
    - how many stale entries were deleted
    - how many stale flags were removed
    - how many locale entries were copied from stale keys to their live equivalents
    """

    catalog = load_catalog()
    sources = load_swift_sources()
    strings: dict[str, dict] = catalog["strings"]

    # Empty keys are invalid catalog entries and are removed even when not marked stale.
    strings.pop("", None)

    stale_keys = [
        key for key, entry in strings.items()
        if entry.get("extractionState") == "stale"
    ]
    source_hits = source_hits_by_key(set(stale_keys), sources)

    normalized_live_keys: dict[str, list[str]] = {}
    for key, entry in strings.items():
        if entry.get("extractionState") == "stale":
            continue
        normalized_live_keys.setdefault(normalize_key_shape(key), []).append(key)

    keys_to_delete: list[str] = []
    removed_stale_flag = 0
    migrated_translation = 0

    for key in stale_keys:
        entry = strings[key]
        hits = source_hits.get(key, [])
        normalized_matches = normalized_live_keys.get(normalize_key_shape(key), [])

        if normalized_matches:
            target_key = normalized_matches[0]
            migrated_translation += merge_missing_localizations(entry, strings[target_key])
            keys_to_delete.append(key)
            continue

        if not hits:
            keys_to_delete.append(key)
            continue

        entry.pop("extractionState", None)
        removed_stale_flag += 1

    for key in keys_to_delete:
        strings.pop(key, None)

    CATALOG_PATH.write_text(
        json.dumps(
            catalog,
            ensure_ascii=False,
            indent=2,
            separators=(",", " : "),
        ) + "\n",
        encoding="utf-8",
    )

    return len(keys_to_delete), removed_stale_flag, migrated_translation


def main() -> int:
    deleted, unmarked, migrated = clean_catalog()
    print(f"deleted={deleted}")
    print(f"unmarked={unmarked}")
    print(f"migrated={migrated}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
