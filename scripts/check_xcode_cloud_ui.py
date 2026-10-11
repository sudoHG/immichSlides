#!/usr/bin/env python3
"""Check the cloud UI plan and fixture copy against the GitHub Apple TV tier."""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from ci_population import ui_identities
from ci_summary import fields, require
from ci_ui_shards import MANIFEST_PATH, shard_populations
from ci_verdict import parse_policy, tier_approved

ROOT = Path(__file__).resolve().parent.parent
PLAN_PATH = "XcodeCloud-UI-tvOS.xctestplan"
FIXTURE_ENVIRONMENT = {
    "CG_NUMERICS_SHOW_BACKTRACE": "1",
    "UI_TEST_EXPECT_PLATFORM": "tvOS",
    "IMMICH_TEST_SERVER_URL": "http://127.0.0.1:8765/api",
    "IMMICH_TEST_API_KEY": "immichslides-public-e2e-key",
    "IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID": "album-c-exif",
    "IMMICHSLIDES_TEST_WAIT_FACTOR": "2",
}
METHOD = re.compile(r"[A-Za-z_]\w*/test[A-Za-z_]\w*\(\)")


def fixture_population(root):
    sources = root / "immichSlidesUITests"
    declared = ui_identities({path.relative_to(sources).as_posix(): path.read_text()
                             for path in sources.rglob("*.swift")}, "tvos")
    shards = shard_populations(declared, json.loads((root / "immichSlides-tvOS.xctestplan").read_text()),
                               json.loads((root / MANIFEST_PATH).read_text()), "appletv")
    policy = parse_policy((root / "scripts/ci-test-policy.json").read_text())
    deselected = [entry["identity"] for entry in policy["deselections"]
                  if tier_approved(policy, "ui") and entry["tier"] == "ui" and entry["environment"] == "fixture"]
    return {shard: [entry for entry in entries if entry not in deselected] for shard, entries in shards.items()}


def validate_plan(plan, population, *, platform="tvOS"):
    fields(plan, {"version", "configurations", "defaultOptions", "testTargets"}, "cloud UI plan")
    require(type(plan["version"]) is int and plan["version"] == 1, "unsupported cloud UI plan version")
    configurations = plan["configurations"]
    require(isinstance(configurations, list) and len(configurations) == 1, "cloud UI needs one configuration")
    fields(configurations[0], {"id", "name", "options"}, "cloud UI configuration")
    require(configurations[0]["options"] == {}, "cloud UI configuration must not override defaults")
    options = plan["defaultOptions"]
    fields(options, {"environmentVariableEntries", "language", "performanceAntipatternCheckerEnabled",
                     "targetForVariableExpansion"}, "cloud UI defaults")
    require(options["language"] == "zh-Hans" and options["performanceAntipatternCheckerEnabled"] is True,
            "cloud UI language/checker differs from the default plan")
    require(options["targetForVariableExpansion"] == {
        "containerPath": "container:immichSlides.xcodeproj", "identifier": "120E64472F0CA2A5003B1480",
        "name": "immichSlides"}, "cloud UI variable expansion needs the app target")
    environment = options["environmentVariableEntries"]
    require(isinstance(environment, list), "cloud fixture environment must be an array")
    observed = {}
    for entry in environment:
        fields(entry, {"key", "value"}, "cloud fixture environment entry")
        require(isinstance(entry["key"], str) and entry["key"] not in observed, "duplicate cloud fixture input")
        observed[entry["key"]] = entry["value"]
    require(observed == dict(FIXTURE_ENVIRONMENT, UI_TEST_EXPECT_PLATFORM=platform), "cloud fixture inputs differ from the PR fixture environment")
    targets = plan["testTargets"]
    require(isinstance(targets, list) and len(targets) == 1, "cloud UI needs only the UI test target")
    fields(targets[0], {"target", "selectedTests"}, "cloud UI target")
    require(targets[0]["target"] == {
        "containerPath": "container:immichSlides.xcodeproj", "identifier": "12F4D6672F6A9FF70049C717",
        "name": "immichSlidesUITests"}, "cloud UI target differs from the shared UI target")
    selections = targets[0]["selectedTests"]
    require(isinstance(selections, list) and selections, "cloud UI needs explicit method selections")
    require(all(isinstance(value, str) and METHOD.fullmatch(value) for value in selections),
            "cloud UI selections must identify exact methods")
    selected = [value.removesuffix("()") for value in selections]
    require(len(selected) == len(set(selected)), "duplicate cloud UI method")
    expected = [entry["key"] for entries in population.values() for entry in entries]
    require(set(selected) == set(expected), "cloud UI population differs from the GitHub Apple TV shards: "
            f"missing={sorted(set(expected) - set(selected))}; extra={sorted(set(selected) - set(expected))}")
    return sorted(selected)


def validate_fixture_copy(root):
    source, copy = root / "scripts/strict_e2e_server.py", root / "ci_scripts/fixture_server.py"
    require(all(path.is_file() and not path.is_symlink() for path in (source, copy)),
            "fixture source and copy must be regular files")
    require(source.read_bytes() == copy.read_bytes(), "cloud fixture server copy differs from scripts/strict_e2e_server.py")


def main():
    try:
        population = fixture_population(ROOT)
        selected = validate_plan(json.loads((ROOT / PLAN_PATH).read_text()), population)
        validate_fixture_copy(ROOT)
        ios = json.loads((ROOT / "XcodeCloud-UI-iOS.xctestplan").read_text())
        # This seed makes the template explicit; the trusted pointer replaces it
        # before every Cloud test build. It is never selected by default.
        from ci_summary import test_identity
        validate_plan(ios, {"seed": [test_identity("ui", "immichSlidesUITests/testPlaybackSettingsBlocksFilteredModeWhenSelectionEmpty",
                      platform="ios", device="iphone")]}, platform="iOS")
        ios_scheme = ET.parse(ROOT / "immichSlides.xcodeproj/xcshareddata/xcschemes/immichSlides-iOS.xcscheme")
        ios_references = ios_scheme.findall("./TestAction/TestPlans/TestPlanReference")
        require(sum(entry.get("reference") == "container:XcodeCloud-UI-iOS.xctestplan" for entry in ios_references) == 1
                and [entry.get("reference") for entry in ios_references if entry.get("default") == "YES"] ==
                ["container:immichSlides-iOS.xctestplan"], "Cloud iOS template must preserve the default plan")
        scheme = ET.parse(ROOT / "immichSlides.xcodeproj/xcshareddata/xcschemes/immichSlides-tvOS.xcscheme")
        references = scheme.findall("./TestAction/TestPlans/TestPlanReference")
        require(sum(entry.get("reference") == "container:" + PLAN_PATH for entry in references) == 1,
                "cloud UI plan must appear once in the tvOS scheme")
        require([entry.get("reference") for entry in references if entry.get("default") == "YES"] ==
                ["container:immichSlides-tvOS.xctestplan"], "cloud UI must preserve the default tvOS plan")
        counts = ", ".join(f"{name}={len(entries)}" for name, entries in sorted(population.items()))
        print(f"Xcode Cloud UI contract PASS: {len(selected)} exact Apple TV methods ({counts}); fixture copy identical")
        return 0
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError) as error:
        print(f"Xcode Cloud UI contract FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
