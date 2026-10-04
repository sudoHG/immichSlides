#!/usr/bin/env python3
"""Check that debug-only code, test hooks and local test config cannot reach release builds.

Replaces the source-text Swift tests formerly in CodeAuditRegressionTests. Run from the repo root:

    python3 scripts/check_release_guards.py

Exits 1 and lists every violation when a rule is broken.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

PRODUCTION_DIR = "immichSlides"

# Identifiers that exist only for debugging or UI tests. Every code occurrence must sit in an `#if DEBUG` branch.
DEBUG_ONLY_MARKERS = (
    "UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE",
    "PlaybackSequenceDebug",
    "qaPlaybackSequenceRecorder",
    "logQAPlaybackSequence",
    "IMMICHSLIDES_DEBUG_PLAYBACK_SEQUENCE",
    "qa_playback_sequence-",
    "debugUptime",
    "debugDurationMs",
    "debugErrorKind",
    "IMMICHSLIDES_PLAYBACK_CPU_DIAGNOSTICS",
    "isUnitTestHost",
)

# Files that must stay free of image-cache and diagnostics concepts.
FORBIDDEN_IN_FILE = {
    "immichSlides/Shared/Model/PlaybackSessionEngine.swift": (
        "SDWebImage", "SDImageCache", "PlaybackImageRequest", "cacheKey", "requestLifecycle",
    ),
    "immichSlides/Shared/Model/PlaybackSmartFillPlanner.swift": (
        "SDWebImage", "SDImageCache", "PlaybackImageRequest", "diagnostic", "cacheKey",
    ),
}

# Retired performance paths that must not come back anywhere in production code.
RETIRED_SYMBOLS = (
    "PlaybackHotImageWindowPolicy",
    "PlaybackDecodePrewarm",
    "prewarmDecoded",
    "scheduleDecodePrewarm",
    "PlaybackRendererImageLayer",
    "singleBackground",
    "onRendererImageDisplayed",
)
RETIRED_SYMBOLS_EXEMPT_FILE = "immichSlides/Shared/Model/PlaybackImageRequestLifecycleDiagnostics.swift"

# SwiftUI evaluates this getter eagerly for an accessibility label, so it must do no I/O.
ZERO_IO_GETTER = ("immichSlides/Shared/Model/SlideShowViewModel.swift", "playbackImageRequestLifecycleSummaryJSON")
IO_TOKENS = ("flush", "FileHandle", ".write(", "synchronize", "fsync")

# Debug switches that may only be read through PlatformCompat.debugFeatureEnabled.
PLATFORM_COMPAT_ONLY_KEYS = ("ENABLE_DEBUG_FORCE_SINGLE_PHOTO_PLAYBACK", "IMMICHSLIDES_DISABLE_SMART_FILL")
PLATFORM_COMPAT_FILE = "immichSlides/Shared/Component/PlatformCompat.swift"

ENV_XCCONFIG = "Config/env.xcconfig"
ENV_EXAMPLE = "Config/env.example.xcconfig"
DEBUG_XCCONFIG = "Config/Debug.xcconfig"
PBXPROJ = "immichSlides.xcodeproj/project.pbxproj"

# The app's synchronized folder must not contain local configs: Xcode bundles non-source files there.
# Scan every Config/ directory, every .xcconfig (including backup suffixes), and env.xcconfig backups.
LOCAL_CONFIG_DIR = "Config"


@dataclass(frozen=True)
class Violation:
    path: str
    line: int
    rule: str
    detail: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: [{self.rule}] {self.detail}"


def mask_comments(source: str, *, mask_strings: bool = False) -> str:
    """Blank out comments (and optionally string literals), keeping offsets and newlines intact."""
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


def is_inside_debug_region(source: str, index: int) -> bool:
    """True when `index` is inside an `#if DEBUG` / `#elseif DEBUG` branch. Unparseable nesting counts as outside."""
    prefix = mask_comments(source[:index], mask_strings=True)
    branches: list[bool] = []
    for raw in prefix.split("\n"):
        line = raw.strip()
        if not line.startswith("#"):
            continue
        parts = line[1:].split(None, 1)
        if not parts:
            return False
        directive, condition = parts[0], (parts[1].strip() if len(parts) > 1 else "")
        if directive == "if":
            if not condition:
                return False
            branches.append(condition == "DEBUG")
        elif directive in ("elseif", "else", "endif"):
            if not branches:
                return False
            if directive == "elseif":
                branches[-1] = condition == "DEBUG"
            elif directive == "else":
                branches[-1] = False
            else:
                branches.pop()
    return any(branches)


def line_of(source: str, index: int) -> int:
    return source.count("\n", 0, index) + 1


def check_debug_only_markers(path: str, source: str) -> list[Violation]:
    code = mask_comments(source)
    found = []
    for marker in DEBUG_ONLY_MARKERS:
        for match in re.finditer(re.escape(marker), code):
            if not is_inside_debug_region(source, match.start()):
                found.append(Violation(path, line_of(source, match.start()), "debug-only",
                                       f"{marker} must only appear inside #if DEBUG"))
    return found


def check_forbidden_symbols(path: str, source: str) -> list[Violation]:
    code = mask_comments(source)
    found = []
    for symbol in FORBIDDEN_IN_FILE.get(path, ()):
        for match in re.finditer(re.escape(symbol), code):
            found.append(Violation(path, line_of(source, match.start()), "layer-boundary",
                                   f"{symbol} must not be referenced in this file"))
    if path != RETIRED_SYMBOLS_EXEMPT_FILE:
        for symbol in RETIRED_SYMBOLS:
            for match in re.finditer(re.escape(symbol), code):
                found.append(Violation(path, line_of(source, match.start()), "retired-path",
                                       f"{symbol} belongs to a retired performance path"))
    return found


def check_zero_io_getter(path: str, source: str) -> list[Violation]:
    if path != ZERO_IO_GETTER[0]:
        return []
    code = mask_comments(source)
    match = re.search(r"\bvar\s+" + ZERO_IO_GETTER[1] + r"\b[^{]*\{", code)
    if not match:
        return [Violation(path, 1, "zero-io-getter", f"{ZERO_IO_GETTER[1]} not found")]
    depth, end = 0, match.end() - 1
    for end in range(match.end() - 1, len(code)):
        depth += {"{": 1, "}": -1}.get(code[end], 0)
        if depth == 0:
            break
    body = code[match.end():end]
    return [Violation(path, line_of(source, match.end() + body.find(token)), "zero-io-getter",
                      f"{ZERO_IO_GETTER[1]} must not do I/O ({token})")
            for token in IO_TOKENS if token in body]


def check_platform_compat_only_keys(path: str, source: str) -> list[Violation]:
    if path == PLATFORM_COMPAT_FILE:
        return []
    code = mask_comments(source)
    return [Violation(path, line_of(source, m.start()), "debug-switch",
                      f"{key} must be read only through PlatformCompat.debugFeatureEnabled")
            for key in PLATFORM_COMPAT_ONLY_KEYS for m in re.finditer(re.escape(key), code)]


def check_env_example(text: str) -> list[Violation]:
    return [Violation(ENV_EXAMPLE, number, "debug-default-off", f"{m.group(1)} must default to 0")
            for number, line in enumerate(text.split("\n"), 1)
            if (m := re.match(r"\s*(ENABLE_DEBUG_\w+)\s*=\s*(\S*)", line)) and m.group(2) != "0"]


def check_env_xcconfig_debug_only(text: str, debug_config_text: str) -> list[Violation]:
    found = []
    debug_reference_found = False
    for match in re.finditer(r"\n\t\t\w+ /\* (\w+) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;(.*?)\n\t\t\};", text, re.S):
        name, body = match.group(1), match.group(2)
        for reference in re.finditer(
            r"(?m)^\s*baseConfigurationReference(?:Anchor|RelativePath)?\s*=\s*([^;]+);", body
        ):
            target = reference.group(1)
            line = line_of(text, match.start(2) + reference.start())
            if name == "Release":
                found.append(Violation(
                    PBXPROJ, line, "local-config-debug-only",
                    "Release configurations must not have a base configuration reference",
                ))
            elif "env.xcconfig" in target:
                found.append(Violation(
                    PBXPROJ, line, "local-config-debug-only",
                    "env.xcconfig must be included through Config/Debug.xcconfig, not referenced directly",
                ))
            elif name == "Debug" and "Debug.xcconfig" in target:
                debug_reference_found = True
            elif name == "Debug":
                found.append(Violation(
                    PBXPROJ, line, "local-config-debug-only",
                    "Debug base configurations must use Config/Debug.xcconfig",
                ))
            elif "Debug.xcconfig" in target:
                found.append(Violation(
                    PBXPROJ, line, "local-config-debug-only",
                    f"Config/Debug.xcconfig must only back Debug configurations, found on {name}",
                ))

    if not debug_reference_found:
        found.append(Violation(
            PBXPROJ, 1, "local-config-debug-only",
            "at least one Debug configuration must reference Config/Debug.xcconfig",
        ))

    include_name = re.escape(Path(ENV_XCCONFIG).name)
    optional_include = re.compile(rf"(?m)^\s*#include\?\s+[\"']{include_name}[\"']\s*$")
    required_include = re.compile(rf"(?m)^\s*#include\s+[\"']{include_name}[\"']\s*$")
    if not optional_include.search(debug_config_text) or required_include.search(debug_config_text):
        found.append(Violation(
            DEBUG_XCCONFIG, 1, "local-config-debug-only",
            'Config/Debug.xcconfig must include env.xcconfig optionally with #include?',
        ))
    return found


@dataclass(frozen=True)
class AppMembership:
    line: int
    owns_folder: bool
    exceptions: frozenset[str]


def app_target_membership(text: str) -> AppMembership | None:
    """Reads the app target's ownership of the `immichSlides` folder and the exceptions that folder applies to it."""
    target = re.search(r"\n\t\t(\w+) /\* immichSlides \*/ = \{\n\t\t\tisa = PBXNativeTarget;(.*?)\n\t\t\};", text, re.S)
    group = re.search(
        r"\n\t\t(\w+) /\* immichSlides \*/ = \{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;(.*?)\n\t\t\};",
        text, re.S)
    if not target or not group:
        return None
    owned = re.search(r"fileSystemSynchronizedGroups = \((.*?)\);", target.group(2), re.S)
    attached = re.search(r"exceptions = \((.*?)\);", group.group(2), re.S)
    attached_ids = set(re.findall(r"\b(\w+) /\*", attached.group(1))) if attached else set()
    exceptions: set[str] = set()
    exception_sets = re.finditer(
        r"\n\t\t(\w+) /\* [^\n]*\*/ = \{\n\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;(.*?)\n\t\t\};",
        text, re.S)
    for block in exception_sets:
        body = block.group(2)
        listed = re.search(r"membershipExceptions = \((.*?)\);", body, re.S)
        if block.group(1) in attached_ids and f"target = {target.group(1)} " in body and listed:
            exceptions |= {entry.strip().strip('"') for entry in listed.group(1).split(",") if entry.strip()}
    return AppMembership(line_of(text, target.start() + 1),
                         bool(owned) and group.group(1) in owned.group(1), frozenset(exceptions))


def build_phase_file_paths(text: str) -> list[tuple[int, str]]:
    """Paths of explicit file references that a build phase uses, with the line of each build file."""
    paths = dict(re.findall(r'\n\t\t(\w+) /\*[^\n]*\{isa = PBXFileReference;[^\n]*? path = "?([^;\n"]*)"?;', text))
    return [(line_of(text, match.start() + 1), paths[match.group(1)])
            for match in re.finditer(r"\n\t\t\w+ /\*[^\n]*\{isa = PBXBuildFile; fileRef = (\w+)", text)
            if match.group(1) in paths]


def check_local_config_not_bundled(text: str,
                                   local_config_files: tuple[str, ...] = ()) -> list[Violation]:
    membership = app_target_membership(text)
    if membership is None:
        return [Violation(PBXPROJ, 1, "local-config-not-bundled",
                          "app target or its folder not found; update this script")]
    found = [Violation(
        PBXPROJ, membership.line, "local-config-not-bundled",
        f"{path} is a local configuration under {PRODUCTION_DIR}/; move it outside the app synchronized folder",
    ) for path in sorted(set(local_config_files))]
    found.extend(Violation(
        PBXPROJ, membership.line, "local-config-not-bundled",
        f"stale local-config membership exception {path} remains in the app target",
    ) for path in sorted(membership.exceptions)
      if path == LOCAL_CONFIG_DIR or path.startswith(f"{LOCAL_CONFIG_DIR}/") or ".xcconfig" in path)
    # Explicit build phases can bundle local config even when the synchronized-folder scan is clean.
    found.extend(Violation(
        PBXPROJ, line, "local-config-not-bundled", f"{path} is a local config in a build phase; remove it",
    ) for line, path in build_phase_file_paths(text)
      if path == LOCAL_CONFIG_DIR or path.startswith(f"{LOCAL_CONFIG_DIR}/")
      or f"/{LOCAL_CONFIG_DIR}/" in path or ".xcconfig" in path)
    return found


def local_config_files_on_disk(root: Path) -> tuple[str, ...]:
    folder = root / PRODUCTION_DIR
    files = []
    for file in folder.rglob("*"):
        if not file.is_file() or file.name == ".DS_Store":
            continue
        relative = file.relative_to(folder)
        if (LOCAL_CONFIG_DIR in relative.parts or ".xcconfig" in file.name
                or file.name.startswith("env.xcconfig.")):
            files.append(relative.as_posix())
    return tuple(sorted(set(files)))


def check_repository(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    for file in sorted((root / PRODUCTION_DIR).rglob("*.swift")):
        path = file.relative_to(root).as_posix()
        source = file.read_text(encoding="utf-8")
        for check in (check_debug_only_markers, check_forbidden_symbols, check_zero_io_getter,
                      check_platform_compat_only_keys):
            violations.extend(check(path, source))
    for required in [*FORBIDDEN_IN_FILE, ZERO_IO_GETTER[0], PLATFORM_COMPAT_FILE,
                     ENV_EXAMPLE, DEBUG_XCCONFIG, PBXPROJ]:
        if not (root / required).is_file():
            violations.append(Violation(required, 1, "missing-file", "guarded file not found; update this script"))
    if (root / ENV_EXAMPLE).is_file():
        violations.extend(check_env_example((root / ENV_EXAMPLE).read_text(encoding="utf-8")))
    if (root / PBXPROJ).is_file():
        pbxproj = (root / PBXPROJ).read_text(encoding="utf-8")
        debug_config = (root / DEBUG_XCCONFIG).read_text(encoding="utf-8") if (root / DEBUG_XCCONFIG).is_file() else ""
        violations.extend(check_env_xcconfig_debug_only(pbxproj, debug_config))
        local_config_files = local_config_files_on_disk(root)
        violations.extend(check_local_config_not_bundled(pbxproj, local_config_files))
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".", help="repository root")
    args = parser.parse_args(argv)
    violations = check_repository(Path(args.root))
    for violation in violations:
        print(violation)
    print(f"RELEASE_GUARDS_{'FAIL' if violations else 'PASS'} violations={len(violations)}")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
