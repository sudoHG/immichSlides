"""Trusted feature-area UI selection; producer scheduling is a separate rollout."""

from __future__ import annotations

import fnmatch
import re
import subprocess
from functools import lru_cache
from pathlib import PurePosixPath

from ci_population import ui_identities
from ci_summary import decode, fields, identity_key, require, string, test_identity
from ci_ui_shards import DEVICES, LABEL, SELECTOR, default_plan_population
from ci_ui_test_kinds import classify_ui_methods, method_kind
from ci_verdict import classify_changes

AREA_MAP_PATH = "scripts/ci-ui-areas.json"


def platform_sources_from_project(project):
    """Narrow only explicit synchronized app filters; unfamiliar project syntax stays shared."""
    objects = [(key, body) for _, key, body in re.findall(
        r'^([ \t]+)(\w+) /\*[^\n]*\*/ = \{\n(.*?)^\1\};', project, re.MULTILINE | re.DOTALL)]
    apps = [(key, body) for key, body in objects if re.search(r'isa = PBXNativeTarget;', body)
            and re.search(r'\bname = immichSlides;', body)
            and 'productType = "com.apple.product-type.application";' in body]
    roots = [(key, body) for key, body in objects if 'isa = PBXFileSystemSynchronizedRootGroup;' in body
             and re.search(r'\bpath = immichSlides;', body)]
    if len(apps) != 1 or len(roots) != 1 or len({key for key, _ in objects}) != len(objects):
        return {}
    app_key, app = apps[0]
    root_key, root = roots[0]
    groups = re.search(r'fileSystemSynchronizedGroups = \((.*?)\);', app, re.DOTALL)
    exceptions = re.search(r'exceptions = \((.*?)\);', root, re.DOTALL)
    if groups is None or exceptions is None:
        return {}
    def identifiers(value):
        return re.findall(r'\b\w+\b', re.sub(r'/\*.*?\*/', '', value, flags=re.DOTALL))
    if root_key not in identifiers(groups[1]):
        return {}
    blocks = [body for key, body in objects if key in identifiers(exceptions[1])
              and 'isa = PBXFileSystemSynchronizedBuildFileExceptionSet;' in body
              and re.search(r'\btarget = ' + re.escape(app_key) + r'\b', body)]
    if len(blocks) != 1:
        return {}
    filters = re.search(r'platformFiltersByRelativePath = \{(.*?)\};', blocks[0], re.DOTALL)
    if filters is None:
        return {}
    entries = re.findall(r'\s*(?:"([^"\n]+)"|([^\s=]+))\s*=\s*\((ios|tvos),\s*\);', filters[1])
    residue = re.sub(r'\s*(?:"([^"\n]+)"|([^\s=]+))\s*=\s*\((ios|tvos),\s*\);', '', filters[1])
    if residue.strip():
        return {}
    result = {}
    for quoted, plain, platform in entries:
        path = quoted or plain
        if 'immichSlides/' + path in result or '..' in path.split('/'):
            return {}
        if path.startswith({'ios': 'iOS/', 'tvos': 'tvOS/'}[platform]):
            result['immichSlides/' + path] = platform
    return result


def parse_area_map(raw):
    area_map = decode(raw)
    fields(area_map, {"schema_version", "revision", "smoke", "areas"}
           | ({"nightly_default", "functional_smoke"} & set(area_map)),
           "UI area map")
    require(type(area_map["schema_version"]) is int and area_map["schema_version"] == 1,
            "unsupported UI area map version")
    string(area_map["revision"], "area map revision")
    require(LABEL.fullmatch(area_map["revision"]) is not None, "invalid area map revision")
    areas = area_map["areas"]
    require(isinstance(areas, dict) and "core" in areas and 1 < len(areas) <= 32,
            "UI area map needs core and feature areas")

    def selectors(values, *, smoke=False):
        require(isinstance(values, list) and values, "UI area selectors must be a nonempty array")
        for value in values:
            require(isinstance(value, str) and SELECTOR.fullmatch(value) is not None
                    and (not smoke or "/" in value), "UI areas assign exact classes or methods; smoke names methods")
        require(len(set(values)) == len(values), "duplicate UI area selector")

    selectors(area_map["smoke"], smoke=True)
    require(len(area_map["smoke"]) <= 8, "UI smoke set must remain small")
    if "functional_smoke" in area_map:
        selectors(area_map["functional_smoke"], smoke=True)
        require(len(area_map["functional_smoke"]) <= 8
                and all(method_kind(key) == "functional" for key in area_map["functional_smoke"]),
                "functional smoke must name a small set of functional methods")
    for name, area in areas.items():
        require(isinstance(name, str) and LABEL.fullmatch(name) is not None, "invalid UI area name")
        fields(area, {"sources", "tests"}, "UI area")
        selectors(area["tests"])
        require(isinstance(area["sources"], list) and area["sources"], "UI area sources must be nonempty")
        for pattern in area["sources"]:
            string(pattern, "UI source glob")
            require(not PurePosixPath(pattern).is_absolute() and ".." not in pattern.split("/")
                    and "\\" not in pattern and str(PurePosixPath(pattern)) == pattern, "invalid UI source glob")
        require(len(set(area["sources"])) == len(area["sources"]), "duplicate UI source glob")
    nightly = area_map.setdefault("nightly_default", [])
    require(isinstance(nightly, list) and len(set(nightly)) == len(nightly)
            and all(isinstance(name, str) and name in areas and name != "core" for name in nightly),
            "nightly-default UI areas must name distinct feature areas")
    return area_map


def matches_test(key, selectors):
    return any(key == selector or key.startswith(selector + "/") for selector in selectors)


def matches_source(path, pattern):
    """Only a standalone ** segment may cross a directory boundary."""
    path_parts, pattern_parts = path.split("/"), pattern.split("/")

    @lru_cache(maxsize=None)
    def matches(path_index, pattern_index):
        if pattern_index == len(pattern_parts):
            return path_index == len(path_parts)
        if pattern_parts[pattern_index] == "**":
            return matches(path_index, pattern_index + 1) or (
                path_index < len(path_parts) and matches(path_index + 1, pattern_index))
        return (path_index < len(path_parts)
                and fnmatch.fnmatchcase(path_parts[path_index], pattern_parts[pattern_index])
                and matches(path_index + 1, pattern_index + 1))

    return matches(0, 0)


def affected_areas(path, area_map):
    return sorted(name for name, area in area_map["areas"].items()
                  if any(matches_source(path, pattern) for pattern in area["sources"]))


def validate_area_coverage(raw, source_paths, populations, *, plans=None):
    """Check both unfiltered platforms, including Evidence and strict identities."""
    area_map = parse_area_map(raw)
    keys = {entry["key"] for platform in ("ios", "tvos") for entry in populations.get("ui-" + platform, [])}
    selectors = [selector for area in area_map["areas"].values() for selector in area["tests"]]
    for selector in selectors + area_map["smoke"] + area_map.get("functional_smoke", []):
        require(any(matches_test(key, [selector]) for key in keys), f"UI area selector matches no test: {selector}")
    for key in sorted(keys):
        require(matches_test(key, selectors), f"unmapped UI test: {key}")
    for path in sorted(source_paths):
        require(affected_areas(path, area_map), f"unmapped app source: {path}")
    if plans is not None:
        for device, platform in DEVICES.items():
            entries = default_plan_population(populations["ui-" + platform], plans[platform])
            require(any(matches_test(entry["key"], area_map["smoke"]) for entry in entries),
                    f"UI smoke set is absent from default plan on {device}")
            if "functional_smoke" in area_map:
                require(any(matches_test(entry["key"], area_map["functional_smoke"]) for entry in entries),
                        f"functional smoke is absent from default plan on {device}")
    return area_map


def check_area_map(root):
    sources = {path.relative_to(root).as_posix(): path.read_text(encoding="utf-8")
               for folder in ("immichSlidesUITests", "TestSupport") for path in (root / folder).rglob("*.swift")}
    populations = {"ui-" + platform: ui_identities(sources, platform) for platform in ("ios", "tvos")}
    source_paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "immichSlides"],
        cwd=root, timeout=30).decode("utf-8").split("\0")
    plans = {platform: (root / ("immichSlides-" + suffix + ".xctestplan")).read_text(encoding="utf-8")
             for platform, suffix in (("ios", "iOS"), ("tvos", "tvOS"))}
    validate_area_coverage((root / AREA_MAP_PATH).read_text(encoding="utf-8"), filter(None, source_paths), populations,
                           plans=plans)


def select_ui_population(paths, classification_policy, *, build_target_paths, area_map, populations, plans, event,
                         platform_scoped=False, platform_sources=None, functional_only=False):
    """Use base data and rules over the trusted diff and tested-tree identities."""
    require(event in {"pull_request", "push", "schedule", "workflow_dispatch"}, "unsupported UI selection event")
    require(type(platform_scoped) is bool and all(platform in DEVICES.values()
            for platform in (platform_sources or {}).values()), "invalid UI platform scope")
    paths = list(paths)
    classification = classify_changes(paths, classification_policy, build_target_paths=build_target_paths)
    area_map = parse_area_map(area_map)
    require(type(functional_only) is bool, "invalid functional UI selection")
    functional_pr = functional_only and event == "pull_request"
    kinds = classify_ui_methods(populations) if functional_pr else {}
    smoke = (area_map.get("functional_smoke", [key for key in area_map["smoke"] if method_kind(key) == "functional"])
             if functional_pr else area_map["smoke"])
    areas, unknown = set(), []
    platform_areas = {platform: set() for platform in ("ios", "tvos")}
    for path in classification["affected_paths"]:
        matched = affected_areas(path, area_map)
        areas.update(matched)
        platform = (platform_sources or {}).get(path) if platform_scoped else None
        for candidate in platform_areas:
            if platform is None or platform == candidate:
                platform_areas[candidate].update(matched)
        if not matched:
            unknown.append(path)
    mode = ("full" if event != "pull_request" or classification["ci_changing"] or unknown or "core" in areas else
            "none" if not classification["app_affected"] else "scoped")
    # Pull requests leave nightly-default tests to the nightly full tier unless one of their areas is selected.
    nightly = [selector for name in area_map["nightly_default"] if name not in areas
               for selector in area_map["areas"][name]["tests"]]
    kept = [selector for name in areas for selector in area_map["areas"][name]["tests"]
            if name in area_map["nightly_default"]] + smoke
    deferred = (event == "pull_request" and not classification["ci_changing"] and not unknown
                and not functional_pr)
    selectors = smoke + [selector for name in areas for selector in area_map["areas"][name]["tests"]]
    selected, omitted = {}, False
    for device, platform in DEVICES.items():
        device_areas = platform_areas[platform] if platform_scoped else areas
        if platform_scoped:
            nightly = [selector for name in area_map["nightly_default"] if name not in device_areas
                       for selector in area_map["areas"][name]["tests"]]
            kept = [selector for name in device_areas if name in area_map["nightly_default"]
                    for selector in area_map["areas"][name]["tests"]] + smoke
        device_selectors = (smoke + [selector for name in device_areas
                            for selector in area_map["areas"][name]["tests"]]) if device_areas else []
        if not platform_scoped:
            device_selectors = selectors
        entries = default_plan_population(populations["ui-" + platform], plans[platform])
        if functional_pr and mode != "none" and (mode == "full" or device_areas):
            require(any(matches_test(entry["key"], smoke) for entry in entries),
                    f"functional smoke is absent from default plan on {device}")
        chosen = []
        for entry in entries:
            if functional_pr and kinds[entry["key"]] != "functional":
                continue
            if not (mode == "full" or mode == "scoped" and matches_test(entry["key"], device_selectors)):
                continue
            if deferred and matches_test(entry["key"], nightly) and not matches_test(entry["key"], kept):
                omitted = True
                continue
            chosen.append(test_identity("ui", entry["key"], platform=platform, device=device))
        selected[device] = sorted(chosen, key=identity_key)
    if functional_pr and mode != "none":
        mode = "scoped"
    elif mode == "full" and omitted:
        mode = "scoped"  # full minus nightly-default tests is an exact trusted selection
    if mode == "scoped":
        validate_area_coverage(area_map, [], populations, plans=plans)
    result = {"mode": mode, "areas": sorted(areas), "unknown_paths": sorted(unknown), "populations": selected}
    if functional_pr:
        result["coverage"] = "functional"
    return result
