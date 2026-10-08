"""Static UI shard rules shared by trusted admission and untrusted producers."""

from __future__ import annotations

import re

from ci_summary import decode, fields, identity_key, require, string, test_identity, validate_test_identity

MANIFEST_PATH = "scripts/ci-ui-shards.json"
DEVICES = {"iphone": "ios", "ipad": "ios", "appletv": "tvos"}
LABEL = re.compile(r"[a-z][a-z0-9-]*")
CLASS = re.compile(r"[A-Za-z_]\w*")
SELECTOR = re.compile(r"[A-Za-z_]\w*(?:/test[A-Za-z_]\w*)?")


def parse_shard_manifest(raw):
    manifest = decode(raw)
    fields(manifest, {"schema_version", "revision", "default_shard", "shards"}, "UI shard manifest")
    require(type(manifest["schema_version"]) is int and manifest["schema_version"] == 1,
            "unsupported UI shard manifest version")
    string(manifest["revision"], "manifest revision")
    require(LABEL.fullmatch(manifest["revision"]) is not None, "invalid UI manifest revision")
    shards = manifest["shards"]
    require(isinstance(shards, dict) and 0 < len(shards) <= 16, "UI manifest needs bounded shards")
    require(isinstance(manifest["default_shard"], str) and manifest["default_shard"] in shards,
            "default shard is absent from UI manifest")
    assigned = set()
    for name, classes in shards.items():
        require(isinstance(name, str) and LABEL.fullmatch(name) is not None, "invalid UI shard name")
        require(isinstance(classes, list), "shard classes must be an array")
        for name in classes:
            require(isinstance(name, str) and CLASS.fullmatch(name) is not None, "shards assign exact UI classes")
            require(name not in assigned, "UI class belongs to more than one shard")
            assigned.add(name)
    return manifest


def default_plan_population(population, raw_plan):
    plan = decode(raw_plan)
    require(isinstance(plan.get("testTargets"), list), "default UI plan has no targets")
    require(all(isinstance(item, dict) and isinstance(item.get("target"), dict) for item in plan["testTargets"]),
            "invalid default UI plan target")
    targets = [item for item in plan["testTargets"] if item.get("target", {}).get("name") == "immichSlidesUITests"]
    require(len(targets) == 1 and targets[0].get("enabled", True) is True, "default plan needs one enabled UI target")
    target = targets[0]
    def selectors(field):
        values = target.get(field, [])
        require(isinstance(values, list), "default UI plan selectors must be an array")
        require(all(isinstance(value, str) and SELECTOR.fullmatch(value.removesuffix("()")) for value in values),
                "unsupported default UI plan selector")
        return [value.removesuffix("()") for value in values]
    excluded, included = selectors("skippedTests"), selectors("selectedTests")
    def matches(key, patterns):
        return any(key == item or key.startswith(item + "/") for item in patterns)
    return [entry for entry in population if not matches(entry["key"], excluded)
            and (not included or matches(entry["key"], included))]


def shard_populations(population, plan, raw_manifest, device):
    manifest = parse_shard_manifest(raw_manifest)
    require(device in DEVICES, "unsupported UI device")
    tokens = set()
    for entry in population:
        validate_test_identity(entry)
        require(entry["kind"] == "ui" and entry["dimensions"] == {"platform": DEVICES[device]},
                "UI source population differs from the device platform")
        token = identity_key(entry)
        require(token not in tokens, "duplicate UI source population")
        tokens.add(token)
    assignment = {name: shard for shard, names in manifest["shards"].items() for name in names}
    result = {shard: [] for shard in manifest["shards"]}
    for entry in default_plan_population(population, plan):
        name = entry["key"].split("/")[0]
        shard = assignment.get(name, manifest["default_shard"])
        result[shard].append(test_identity("ui", entry["key"], platform=DEVICES[device], device=device))
    return {shard: sorted(entries, key=identity_key) for shard, entries in result.items()}
