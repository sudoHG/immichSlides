"""Bounded official XCTest discovery evidence for fully executed scoped UI shards."""

from __future__ import annotations

import hashlib
import json
import math
import re

from ci_summary import fields, identity_key, require, test_identity

DISCOVERY_MODE = "official-result-discovery-v1"
DISCOVERY_INTENT = "--compiled-from-official-results"
MAX_EXPORT_BYTES = 1024 * 1024
MAX_EXPORT_NODES = 8192
MAX_EXPORT_DEPTH = 32
METHOD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z0-9_]+\(\)")
DEVICES = {"iphone": ("ios", "iOS Simulator", "iPhone"),
           "ipad": ("ios", "iOS Simulator", "iPad"),
           "appletv": ("tvos", "tvOS Simulator", "Apple TV")}


def bounded_hash(value):
    pending, count = [(value, 0)], 0
    while pending:
        item, depth = pending.pop()
        count += 1
        require(count <= MAX_EXPORT_NODES and depth <= MAX_EXPORT_DEPTH, "official discovery export exceeds bounds")
        if isinstance(item, dict):
            require(all(isinstance(key, str) for key in item), "official discovery needs JSON keys")
            pending.extend((child, depth + 1) for child in item.values())
        elif isinstance(item, list):
            pending.extend((child, depth + 1) for child in item)
        else:
            require(item is None or type(item) in {str, bool, int, float}, "official discovery needs JSON values")
            require(type(item) is not float or math.isfinite(item), "nonfinite official discovery value")
            require(type(item) is not int or abs(item) <= 2 ** 63, "oversized official discovery integer")
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    require(len(raw) <= MAX_EXPORT_BYTES, "official discovery export exceeds byte bound")
    return hashlib.sha256(raw).hexdigest()


def official_discovery(payload, device, device_id):
    """Read compiled case nodes without deriving them from declared or observed records."""
    bounded_hash(payload)
    require(device in DEVICES and isinstance(device_id, str) and bool(device_id), "unknown discovery device")
    platform, simulator, model = DEVICES[device]
    require(isinstance(payload, dict) and isinstance(payload.get("devices"), list)
            and len(payload["devices"]) == 1, "official discovery needs exactly one device")
    actual = payload["devices"][0]
    require(isinstance(actual, dict) and actual.get("deviceId") == device_id
            and actual.get("platform") == simulator and isinstance(actual.get("modelName"), str)
            and actual["modelName"].startswith(model), "official discovery device differs")
    cases = {}

    def visit(nodes, bundle=None):
        require(isinstance(nodes, list), "invalid official discovery children")
        for node in nodes:
            require(isinstance(node, dict) and isinstance(node.get("nodeType"), str), "invalid official discovery node")
            kind = node["nodeType"]
            owner = node.get("name") if kind.endswith("test bundle") else bundle
            if kind.endswith("test bundle"):
                require(owner == "immichSlidesUITests", "official discovery contains another test target")
            if kind == "Test Case":
                identifier = node.get("nodeIdentifier")
                require(owner == "immichSlidesUITests" and isinstance(identifier, str)
                        and METHOD.fullmatch(identifier) is not None, "invalid official discovery method")
                key = identifier[:-2]
                require(key not in cases, "duplicate official discovery method")
                require(node.get("result") in {"Passed", "Failed", "Skipped"}, "unknown official discovery result")
                seconds = node.get("durationInSeconds")
                require(type(seconds) in {int, float} and math.isfinite(seconds) and seconds >= 0,
                        "invalid official discovery duration")
                cases[key] = {"identity": test_identity("ui", key, platform=platform, device=device),
                              "result": node["result"], "duration_seconds": seconds}
            visit(node.get("children", []), owner)

    visit(payload.get("testNodes"))
    require(cases, "official discovery contains no compiled methods")
    return cases


def validate_discovery_summary(summary):
    evidence = summary["compiled_evidence"]
    fields(evidence, {"schema_version", "mode", "identity", "run", "plan_sha256", "device_id",
                      "first_exit_code", "official_tests"}, "compiled evidence")
    require(type(evidence["schema_version"]) is int and evidence["schema_version"] == 1
            and evidence["mode"] == DISCOVERY_MODE, "unknown compiled discovery protocol")
    require(summary["identity"]["event"] == "pull_request"
            and summary["source"]["workflow_path"] == ".github/workflows/ci-ui.yml"
            and summary["run"]["tier"] == "ui"
            and re.fullmatch(r"scoped-[a-f]", summary["run"]["shard"] or "") is not None,
            "official discovery is only supported for scoped PR UI")
    require(evidence["identity"] == summary["identity"] and evidence["run"] == summary["run"],
            "compiled discovery identity or attempt differs")
    hashes = summary["hashes"]["manifests"]
    require(evidence["plan_sha256"] == hashes.get("ui-scoped-plan")
            and isinstance(evidence["plan_sha256"], str), "compiled discovery plan differs")
    require(hashes.get("ui-discovery") == bounded_hash(evidence), "compiled discovery hash differs")
    code = evidence["first_exit_code"]
    require(type(code) is int and 0 <= code <= 255, "invalid discovery invocation exit")
    device = summary["run"]["job"].removeprefix("ui-")
    cases = official_discovery(evidence["official_tests"], device, evidence["device_id"])
    population = summary["population"]
    require(not population["deselected"], "official discovery cannot prove deselected compilation")
    compiled = [entry["identity"] for entry in cases.values()]
    expected = {identity_key(entry) for entry in compiled}
    require(expected == {identity_key(entry) for entry in population["declared"]}
            == {identity_key(entry) for entry in population["compiled"]}
            == {identity_key(entry["identity"]) for entry in population["observed"]},
            "declared, discovered, compiled and observed populations differ")
    failed = any(case["result"] == "Failed" for case in cases.values())
    require((code == 0 and not failed) or (code != 0 and failed), "raw exit and official discovery outcomes differ")
    for entry in population["observed"]:
        case = cases[entry["identity"]["key"]]
        first = entry["attempts"][0]
        allowed = {"passed"} if case["result"] == "Passed" else {"skipped"} if case["result"] == "Skipped" else {
            "failed", "crashed", "timed-out"}
        require(first["outcome"] in allowed and abs(first["duration_seconds"] - case["duration_seconds"]) <= 0.000001,
                "official discovery and first observed outcome differ")
        require(first["exit_code"] == (0 if first["outcome"] == "passed" else code),
                "official discovery and observed raw exits differ")
