#!/usr/bin/env python3
"""Export scanned public-fixture P2 packages and read maintainer-authored reviews."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from ci_summary import decode, duration, fields, identity_key, integer, parse_summary, require, sha, validate_test_identity
from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256
from strict_e2e_p2_contract import (DEVICE_PLATFORM, P2_CASES, P2ContractError, RAW_VERDICT,
                                  RECORDING_TIMING_FILE, REVIEW_FILE, REVIEW_SCHEMA, STEPS_FILE,
                                  evaluate_review, read_official_tests_export, require_official_execution,
                                  validate_raw_evidence)
from strict_e2e_server import PUBLIC_API_KEY, _fixture_data, fixture_manifest

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "scripts/p2-review.html"
SIGNATURE = "These review decisions and observations are my own."
CONTEXT_FIELDS = {"source_sha", "tree_sha", "repository", "workflow_path", "event", "ref",
                  "run_id", "run_attempt", "shard", "matrix_sha256"}
CASE_FIELDS = {"platform", "device", "configuration", "suite", "scenario", "fixture"}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=True, allow_nan=False).encode()).hexdigest()


def file_digest(path):
    require(path.is_file() and not path.is_symlink(), "missing, nonregular or symlinked package input")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True, allow_nan=False) + "\n")


def validate_key(context, case):
    fields(context, CONTEXT_FIELDS, "package context")
    fields(case, CASE_FIELDS, "package case")
    for key in ("source_sha", "tree_sha"):
        sha(context[key])
    sha(context["matrix_sha256"], 64)
    require(context["repository"] == "sudoHG/immichSlides", "unexpected repository")
    require(context["event"] in {"schedule", "workflow_dispatch", "local", "pull_request"}, "unsupported package event")
    expected_workflow = {"local": None, "pull_request": ".github/workflows/ci-p2-review.yml"}.get(
        context["event"], ".github/workflows/ci-nightly.yml")
    require(context["workflow_path"] == expected_workflow,
            "unexpected workflow")
    integer(context["run_attempt"], 1, "run attempt")
    if context["event"] == "local":
        require(context["run_id"] is None and context["ref"] is None, "local package cannot claim a hosted run")
    else:
        require(isinstance(context["run_id"], str) and context["run_id"].isdigit(), "invalid hosted run ID")
        prefix = "refs/pull/" if context["event"] == "pull_request" else "refs/heads/"
        require(isinstance(context["ref"], str) and context["ref"].startswith(prefix)
                and not any(c.isspace() for c in context["ref"]), "invalid branch ref")
    require(isinstance(context["shard"], str) and context["shard"] and
            all(c.isalnum() or c in "-_" for c in context["shard"]), "invalid shard")
    suite = case["suite"]
    require(suite in P2_CASES and case["device"] in P2_CASES[suite].devices, "unsupported suite/device")
    require(case["platform"] == DEVICE_PLATFORM[case["device"]] and case["configuration"] == "Debug"
            and case["scenario"] == "normal" and case["fixture"] in FROZEN_FIXTURE_SHA256,
            "unsupported P2 case")


def scan(directory, *, redact_paths=True):
    from run_strict_e2e import CommandError, WRONG_PUBLIC_API_KEY, write_sensitive_scan
    values = [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY]
    if redact_paths:
        values.extend(["/Users/", "/home/"])
    try:
        with tempfile.TemporaryDirectory(prefix="p2-sensitive-scan-") as temporary:
            report = Path(temporary) / "sensitive-scan.json"
            write_sensitive_scan(directory, values, output_path=report)
            return decode(report.read_text())
    except CommandError:
        raise ValueError("sensitive scan refused publication") from None


def render_page(manifest):
    embedded = json.dumps(manifest, ensure_ascii=True, sort_keys=True).replace("<", "\\u003c")
    return TEMPLATE.read_text().replace("__P2_PACKAGE__", embedded)


def build_package(evidence, destination, context, case):
    """Validate originals before allowlisted projection; never generate a human verdict."""
    validate_key(context, case)
    require(evidence.is_dir() and not evidence.is_symlink(), "invalid evidence directory")
    suite, fixture = case["suite"], case["fixture"]
    contract = P2_CASES[suite]
    for name in [*(name + ".png" for name in contract.pngs), STEPS_FILE,
                 *(["screen-recording.mov", RECORDING_TIMING_FILE] if contract.video else [])]:
        file_digest(evidence / name)
    raw = validate_raw_evidence(evidence, suite, fixture)
    for name in (*raw["artifacts"], *raw["records"], "case-manifest.json", "visual-identity-runner.json",
                 "official-tests.json", "result-bundle-disposal.json", "sensitive-scan.json"):
        file_digest(evidence / name)
    details = decode((evidence / "case-manifest.json").read_text())
    require(details.get("source_sha") == context["source_sha"] and details.get("source_dirty_paths") == [],
            "case must come from the clean tested SHA")
    require(details.get("suite") == suite and details.get("platform") == case["platform"]
            and details.get("scenario") == "normal" and details.get("fixture_set") == fixture
            and details.get("fixture_sha256") == FROZEN_FIXTURE_SHA256[fixture]
            and str(details.get("result", "")).lower() == "passed" and details.get("exit_code") == 0,
            "case did not complete its public fixture contract")
    require(not (evidence / "cleanup-failures.json").exists(), "case cleanup failed")
    report = decode((evidence / "visual-identity-runner.json").read_text())
    require({k: v for k, v in report.items() if k != "execution"} == raw, "raw evidence changed after runner validation")
    disposal = decode((evidence / "result-bundle-disposal.json").read_text())
    official_digest = file_digest(evidence / "official-tests.json")
    require(disposal.get("result_bundle_disposed") is True and
            disposal.get("official_tests_sha256") == details.get("official_tests_sha256") == official_digest,
            "official export or private disposal differs from the run")
    destination_id = next((part[3:] for part in str(details.get("destination", "")).split(",")
                           if part.startswith("id=")), None)
    require(destination_id is not None, "missing original device identity")
    execution = require_official_execution(read_official_tests_export(evidence / "official-tests.json"),
        suite=suite, platform=case["platform"], simulator_udid=destination_id)
    require(execution["device"]["class"] == case["device"], "official device class differs")
    source_scan = decode((evidence / "sensitive-scan.json").read_text())
    require(source_scan.get("result") == "PASS" and source_scan.get("matched_files") == [], "original scan failed")
    scan(evidence, redact_paths=False)
    # Only fixed-shape step/timing records may cross the publication boundary.
    steps = decode((evidence / STEPS_FILE).read_text())
    fields(steps, {"schema", "steps"}, "steps")
    for step in steps["steps"]:
        fields(step, {"index", "name", "wall_time", "orientation"} | ({"png"} if "png" in step else set()), "step")
    if P2_CASES[suite].video:
        timing = decode((evidence / RECORDING_TIMING_FILE).read_text())
        fields(timing, {"started_wall_time", "stopped_wall_time", "stop_exit"}, "recording timing")
    facts = {"schema_version": 1, "raw": raw, "fixture_sha256": FROZEN_FIXTURE_SHA256[fixture],
             "official_tests_sha256": official_digest, "case_manifest_sha256": file_digest(evidence / "case-manifest.json"),
             "official_test": execution["executed_tests"], "official_device_class": execution["device"]["class"]}
    require(not os.path.lexists(destination), "package destination must be fresh")
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Stage and scan before an upload-visible path exists. A refused package is deleted.
    with tempfile.TemporaryDirectory(prefix="p2-staging-", dir=destination.parent) as temporary:
        staged = Path(temporary)
        for name in (*raw["artifacts"], *raw["records"]):
            shutil.copyfile(evidence / name, staged / name)
        fixture_data = _fixture_data(fixture)
        for asset in fixture_data["assets"]:
            (staged / f"fixture-{asset['label']}.png").write_bytes(fixture_data["images"][asset["id"]])
        write_json(staged / "case.json", facts)
        manifest = {"schema_version": 2, "context": context, "case": case, "case_sha256": digest(case),
                    "last_step_wall_time": max(step["wall_time"] for step in steps["steps"]),
                    "facts": facts, "files": {p.name: file_digest(p) for p in sorted(staged.iterdir())},
                    "template_sha256": file_digest(TEMPLATE),
                    "fixture_marks": {a["label"]: a["sha256"] for a in fixture_manifest(fixture)["assets"]},
                    "review_order": [*(name + ".png" for name in contract.pngs),
                                     *(["screen-recording.mov"] if contract.video else [])]}
        manifest["package_sha256"] = digest(manifest)
        write_json(staged / "package.json", manifest)
        (staged / "review.html").write_text(render_page(manifest))
        scan(staged)
        read_package(staged)
        staged.rename(destination)
    return manifest


def validate_manifest(manifest):
    """Validate retained metadata without requiring seven-day media or today's template."""
    manifest = decode(manifest)
    fields(manifest, {"schema_version", "context", "case", "case_sha256", "facts", "files",
                      "template_sha256", "fixture_marks", "review_order", "package_sha256", "last_step_wall_time"}, "package")
    require(type(manifest["schema_version"]) is int and manifest["schema_version"] == 2, "unknown package schema")
    validate_key(manifest["context"], manifest["case"])
    require(manifest["case_sha256"] == digest(manifest["case"]), "case hash differs")
    require(manifest["package_sha256"] == digest({k: v for k, v in manifest.items() if k != "package_sha256"}),
            "package hash differs")
    suite, fixture = manifest["case"]["suite"], manifest["case"]["fixture"]
    contract = P2_CASES[suite]
    duration(manifest["last_step_wall_time"])
    sha(manifest["template_sha256"], 64)
    facts = manifest["facts"]
    require(isinstance(manifest["files"], dict), "file hashes must be an object")
    fields(facts, {"schema_version", "raw", "fixture_sha256", "official_tests_sha256", "case_manifest_sha256",
                   "official_test", "official_device_class"}, "case facts")
    require(type(facts["schema_version"]) is int and facts["schema_version"] == 1, "unknown facts schema")
    require(facts["fixture_sha256"] == FROZEN_FIXTURE_SHA256[fixture] and
            facts["official_device_class"] == manifest["case"]["device"], "fixture or official device differs")
    sha(facts["official_tests_sha256"], 64)
    sha(facts["case_manifest_sha256"], 64)
    method = contract.selectors[manifest["case"]["platform"]].removeprefix("immichSlidesUITests/") + "()"
    require(facts["official_test"] == [method], "official method differs")
    raw = facts["raw"]
    extra = ({"mark_offsets"} if contract.video else set()) | ({"cache_clear"} if contract.cache_clear else set()) | ({"cache_return"} if contract.cache_return else set())
    fields(raw, {"verdict", "suite", "artifacts", "records"} | extra, "raw contract")
    require(raw["verdict"] == RAW_VERDICT and raw["suite"] == suite, "raw contract differs")
    artifacts = {name + ".png" for name in contract.pngs} | ({"screen-recording.mov"} if contract.video else set())
    records = {STEPS_FILE} | ({RECORDING_TIMING_FILE} if contract.video else set())
    fields(raw["artifacts"], artifacts, "artifacts")
    fields(raw["records"], records, "records")
    for name, value in {**raw["artifacts"], **raw["records"]}.items():
        fields(value, {"sha256", "bytes"}, "file facts")
        sha(value["sha256"], 64); integer(value["bytes"], 1, "file bytes")
        require(manifest["files"].get(name) == value["sha256"], "raw file hash differs")
    if contract.video:
        fields(raw["mark_offsets"], contract.marks, "recording marks")
        for offset in raw["mark_offsets"].values():
            duration(offset)
    for key in ("cache_clear", "cache_return"):
        if key in raw:
            fields(raw[key], {"target_mark"}, "machine cache result")
            require(raw[key]["target_mark"] in manifest["fixture_marks"], "machine mark is outside fixture")
    references = {f"fixture-{a['label']}.png": a["sha256"] for a in fixture_manifest(fixture)["assets"]}
    fields(manifest["files"], artifacts | records | {"case.json"} | set(references), "file hashes")
    for value in manifest["files"].values():
        sha(value, 64)
    require(all(manifest["files"][name] == value for name, value in references.items()), "reference hash differs")
    encoded_facts = (json.dumps(facts, sort_keys=True, indent=2, ensure_ascii=True, allow_nan=False) + "\n").encode()
    require(manifest["files"]["case.json"] == hashlib.sha256(encoded_facts).hexdigest(), "facts hash differs")
    require(manifest["fixture_marks"] == {a["label"]: a["sha256"] for a in fixture_manifest(fixture)["assets"]}, "fixture marks differ")
    require(manifest["review_order"] == [*(name + ".png" for name in contract.pngs),
            *(["screen-recording.mov"] if contract.video else [])], "review order differs from contract")
    return manifest


def read_package(directory):
    require(directory.is_dir() and not directory.is_symlink(), "invalid package directory")
    file_digest(directory / "package.json")
    manifest = validate_manifest((directory / "package.json").read_text())
    suite, fixture = manifest["case"]["suite"], manifest["case"]["fixture"]
    raw = validate_raw_evidence(directory, suite, fixture)
    expected_files = set(raw["artifacts"]) | set(raw["records"]) | {"case.json"} | {
        f"fixture-{asset['label']}.png" for asset in fixture_manifest(fixture)["assets"]}
    require(set(manifest["files"]) == expected_files, "package file allowlist differs")
    require({p.name for p in directory.iterdir()} == expected_files | {"package.json", "review.html"},
            "unexpected package content")
    for name, expected in manifest["files"].items():
        require(file_digest(directory / name) == expected, "package file hash differs: " + name)
    for asset in fixture_manifest(fixture)["assets"]:
        require(file_digest(directory / f"fixture-{asset['label']}.png") == asset["sha256"], "reference photo differs")
    require(manifest["facts"] == decode((directory / "case.json").read_text())
            and manifest["facts"]["raw"] == raw and raw["verdict"] == RAW_VERDICT, "case facts differ")
    require(manifest["template_sha256"] == file_digest(TEMPLATE), "unsupported review page revision")
    require(file_digest(directory / "review.html") == hashlib.sha256(render_page(manifest).encode()).hexdigest(),
            "review page differs")
    require(manifest["fixture_marks"] == {a["label"]: a["sha256"] for a in fixture_manifest(fixture)["assets"]},
            "fixture mark hashes differ")
    steps = decode((directory / STEPS_FILE).read_text())
    require(manifest["last_step_wall_time"] == max(s["wall_time"] for s in steps["steps"]), "last step clock differs")
    scan(directory)
    return manifest


def record_path(record):
    validate_key(record["context"], record["case"])
    case = record["case"]
    return Path(record["context"]["source_sha"]) / case["suite"] / case["device"] / (case["fixture"] + ".json")


def validate_record(record, package=None):
    """A declared human signature is checked, never inferred or synthesized by CI."""
    record = decode(record)
    fields(record, {"schema_version", "context", "case", "case_sha256", "package_sha256", "reviewed_at", "signature", "review", "package_manifest"}, "review record")
    require(type(record["schema_version"]) is int and record["schema_version"] == 2, "unknown review schema")
    require(isinstance(record["review"], dict), "review must be an object")
    validate_key(record["context"], record["case"])
    manifest = validate_manifest(record["package_manifest"])
    if package is not None:
        require(manifest == read_package(package), "embedded manifest differs from media package")
    for key in ("context", "case", "case_sha256", "package_sha256"):
        require(record[key] == manifest[key], "review differs from package: " + key)
    require(record["signature"] == SIGNATURE and record["review"].get("reviewer") == "sudoHG", "maintainer signature is required")
    timestamp = record["reviewed_at"]
    require(isinstance(timestamp, str) and timestamp.endswith("Z"), "review time must be UTC")
    try:
        reviewed = datetime.fromisoformat(timestamp.removesuffix("Z") + "+00:00")
    except ValueError:
        raise ValueError("invalid review timestamp") from None
    require(reviewed <= datetime.now(timezone.utc), "review time is in the future")
    require(reviewed.timestamp() > manifest["last_step_wall_time"], "review predates the completed package")
    case, raw = manifest["case"], manifest["facts"]["raw"]
    review = record["review"]
    require(review.get("schema") == REVIEW_SCHEMA and review.get("verdict") in {"PASS", "FAIL", "PARTIAL"}, "invalid human verdict")
    require(set(review.get("artifacts", {})) == set(raw["artifacts"]), "review artifact set differs")
    decisions = []
    for name, entry in review["artifacts"].items():
        require(isinstance(entry, dict), "review item must be an object")
        require(isinstance(entry.get("time_slices", []), list) and isinstance(entry.get("checks", {}), dict),
                "invalid item checks or slices")
        require(entry.get("conclusion") != "PASS" or entry.get("controls") != "not-reviewed",
                "passing items cannot have unreviewed controls")
        pieces = [entry, *entry.get("time_slices", [])]
        for piece in pieces:
            require(isinstance(piece, dict), "review slice must be an object")
            require(piece.get("conclusion") in {"PASS", "FAIL", "PARTIAL"}, "invalid item decision")
            require(isinstance(piece.get("observation"), str) and piece["observation"].strip(), "an observation is required")
            decisions.append(piece["conclusion"])
            if piece["conclusion"] != "PASS":
                require(piece["observation"].strip() != "No note entered; reviewer selected PASS.", "nonpassing items require the reviewer's note")
        if any(v != "PASS" for v in entry.get("checks", {}).values()):
            require(entry["observation"].strip() != "No note entered; reviewer selected PASS.", "nonpassing checks require the reviewer's note")
        decisions.extend(entry.get("checks", {}).values())
    require(all(v in {"PASS", "FAIL", "PARTIAL"} for v in decisions), "invalid check decision")
    expected = "FAIL" if "FAIL" in decisions else "PARTIAL" if "PARTIAL" in decisions else "PASS"
    require(review["verdict"] == expected, "overall verdict differs from item decisions")
    # Reuse the existing sign-off contract for marks, cache checks and video coverage.
    with tempfile.TemporaryDirectory(prefix="p2-record-validation-") as temporary:
        write_json(Path(temporary) / REVIEW_FILE, review)
        scan(Path(temporary))
        return evaluate_review(Path(temporary), suite=case["suite"], device_class=case["device"],
            source_sha=manifest["context"]["source_sha"], fixture_set=case["fixture"],
            artifacts=raw["artifacts"], mark_offsets=raw.get("mark_offsets", {}),
            cache_target_mark=(raw.get("cache_clear") or raw.get("cache_return") or {}).get("target_mark"))


def qualifying(context):
    return (context["event"] in {"schedule", "workflow_dispatch"}
            and context["workflow_path"] == ".github/workflows/ci-nightly.yml"
            and context["ref"] == "refs/heads/main")


def shard_context(summary):
    identity, run = summary["identity"], summary["run"]
    return {"source_sha": identity.get("commit_sha", identity.get("merge_sha")), "tree_sha": identity["tree_sha"],
            "repository": identity["repository"], "workflow_path": summary["source"]["workflow_path"],
            "event": identity["event"], "ref": identity.get("ref"), "run_id": run["id"],
            "run_attempt": run["attempt"], "shard": run["shard"],
            "matrix_sha256": summary["hashes"]["manifests"]["nightly-matrix"]}


def validate_bindings(entries, summary=None):
    require(isinstance(entries, list), "package bindings must be a list")
    seen = set()
    for entry in entries:
        fields(entry, {"identity", "context", "case_sha256", "package_sha256"}, "package binding")
        identity = entry["identity"]
        validate_test_identity(identity)
        require(identity["kind"] == "strict", "package binding requires a strict case")
        dimensions = identity["dimensions"]
        require(dimensions["device"] in DEVICE_PLATFORM, "unsupported binding device")
        case = {**dimensions, "platform": DEVICE_PLATFORM[dimensions["device"]]}
        validate_key(entry["context"], case)
        require(entry["case_sha256"] == digest(case), "binding case hash differs")
        sha(entry["package_sha256"], 64)
        token = digest({"context": entry["context"], "case_sha256": entry["case_sha256"]})
        require(token not in seen, "duplicate package binding")
        seen.add(token)
    if summary is not None:
        wanted = {identity_key(e["identity"]) for e in summary["population"]["observed"]
                  if e["outcome"] == "needs-human-review" and e["identity"]["dimensions"]["suite"] in P2_CASES}
        require({identity_key(e["identity"]) for e in entries} == wanted, "completed P2 package bindings are missing or unexpected")
        require(all(e["context"] == shard_context(summary) for e in entries), "package binding has another shard/run/tree")
    return entries


def export_shard(input_dir, output_dir):
    summary = parse_summary((input_dir / "records/summary.json").read_text())
    context = shard_context(summary)
    require(not os.path.lexists(output_dir), "shard package directory must be fresh")
    output_dir.mkdir(parents=True)
    packages, missing, bindings = [], [], []
    observed = {json.dumps(e["identity"], sort_keys=True): e for e in summary["population"]["observed"]}
    for index, item in enumerate(summary["population"]["declared"]):
        dimensions = item["dimensions"]
        suite = dimensions["suite"]
        if suite not in P2_CASES:
            continue
        case = {**dimensions, "platform": DEVICE_PLATFORM[dimensions["device"]]}
        entry = observed.get(json.dumps(item, sort_keys=True))
        if entry is None or entry["outcome"] != "needs-human-review":
            missing.append({"case": case, "reason": "automated contract did not pass"})
            continue
        relative = Path(context["source_sha"]) / suite / dimensions["device"] / dimensions["fixture"]
        try:
            manifest = build_package(input_dir / "cases" / f"{index:03d}-{suite}", output_dir / relative, context, case)
            bindings.append({"identity": item, "context": context, "case_sha256": manifest["case_sha256"],
                             "package_sha256": manifest["package_sha256"]})
            packages.append(relative.as_posix())
        except (ValueError, OSError, P2ContractError):
            missing.append({"case": case, "reason": "package validation or sensitive scan refused publication"})
    write_json(output_dir / "index.json", {"schema_version": 1, "packages": packages, "unavailable": missing})
    write_json(input_dir / "records/p2-review-bindings.json", {"schema_version": 1, "review_packages": bindings})
    scan(output_dir)
    print(f"P2 packages: {len(packages)}; unavailable: {len(missing)}. Human review remains pending.")
    return 1 if any(m["reason"] != "automated contract did not pass" for m in missing) else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("export-shard")
    export.add_argument("--input-dir", type=Path, required=True)
    export.add_argument("--output-dir", type=Path, required=True)
    single = commands.add_parser("export-case")
    single.add_argument("--evidence-dir", type=Path, required=True)
    single.add_argument("--output-dir", type=Path, required=True)
    single.add_argument("--suite", choices=sorted(P2_CASES), required=True)
    single.add_argument("--device-class", choices=sorted(DEVICE_PLATFORM), required=True)
    single.add_argument("--fixture", choices=sorted(FROZEN_FIXTURE_SHA256), default="a")
    validate = commands.add_parser("validate-record")
    validate.add_argument("--record", type=Path, required=True)
    validate.add_argument("--package", type=Path)
    read = commands.add_parser("read")
    read.add_argument("--records-dir", type=Path, default=ROOT / "review-records")
    read.add_argument("--sha", required=True)
    read.add_argument("--suite", choices=sorted(P2_CASES), required=True)
    read.add_argument("--device-class", choices=sorted(DEVICE_PLATFORM), required=True)
    read.add_argument("--packages-dir", type=Path)
    read.add_argument("--bindings", type=Path, help="Retained shard bindings or nightly.json")
    args = parser.parse_args(argv)
    try:
        if args.command == "export-case":
            from run_host_checks import run_identity, source_metadata
            identity = run_identity(os.environ, ci=os.environ.get("GITHUB_ACTIONS") == "true")
            workflow, _ = source_metadata(identity, os.environ, None)
            context = {"source_sha": identity.get("commit_sha", identity.get("merge_sha")),
                       "tree_sha": identity["tree_sha"], "repository": identity["repository"],
                       "workflow_path": workflow, "event": identity["event"],
                       "ref": os.environ.get("GITHUB_REF") if identity["event"] != "local" else None,
                       "run_id": os.environ.get("GITHUB_RUN_ID"), "run_attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
                       "shard": "review-probe-" + args.device_class,
                       "matrix_sha256": file_digest(ROOT / "scripts/nightly-matrix.json")}
            case = {"suite": args.suite, "device": args.device_class, "platform": DEVICE_PLATFORM[args.device_class],
                    "configuration": "Debug", "scenario": "normal", "fixture": args.fixture}
            output = args.output_dir.resolve()
            require(output != ROOT and ROOT not in output.parents, "output must be outside checkout")
            build_package(args.evidence_dir, output, context, case)
            print("Scanned public fixture package exported; human review remains pending.")
            return 0
        if args.command == "export-shard":
            require(args.output_dir.resolve() != ROOT and ROOT not in args.output_dir.resolve().parents, "output must be outside checkout")
            return export_shard(args.input_dir, args.output_dir)
        if args.command == "validate-record":
            record = decode(args.record.read_text())
            verdict = validate_record(record, args.package)
            print(f"{verdict}: {record_path(record).as_posix()}")
            return 0 if verdict == "PASS" else 1
        sha(args.sha)
        require(args.device_class in P2_CASES[args.suite].devices, "unsupported suite/device")
        bindings = None
        if args.bindings is not None and os.path.lexists(args.bindings):
            file_digest(args.bindings)
            payload = decode(args.bindings.read_text())
            require(type(payload.get("schema_version")) is int and payload["schema_version"] == 1, "unknown binding schema")
            bindings = validate_bindings(payload.get("review_packages"))
        records, missing = [], []
        for fixture in sorted(FROZEN_FIXTURE_SHA256):
            key = Path(args.sha) / args.suite / args.device_class / (fixture + ".json")
            path = args.records_dir / key
            if not path.is_file():
                missing.append(fixture)
                continue
            require(not path.is_symlink(), "symlinked review record")
            record = decode(path.read_text())
            require(record_path(record) == key, "record stored under another key")
            package = args.packages_dir / key.with_suffix("") if args.packages_dir else None
            media = package is not None and os.path.lexists(package)
            verdict = validate_record(record, package if media else None)
            if bindings is not None:
                matches = [b for b in bindings if b["context"] == record["context"] and b["case_sha256"] == record["case_sha256"]]
                require(len(matches) == 1 and matches[0]["package_sha256"] == record["package_sha256"], "review differs from compact producer binding")
            records.append({"fixture": fixture, "verdict": verdict, "context": record["context"],
                            "qualifying": qualifying(record["context"]), "media_status": "available" if media else "package-expired",
                            "binding_status": "verified" if bindings is not None else "binding-unavailable"})
        is_qualifying = bool(records) and all(r["qualifying"] for r in records)
        complete = not missing and all(r["verdict"] == "PASS" for r in records) and is_qualifying and bindings is not None
        require(not records or all({k: v for k, v in r["context"].items() if k != "shard"} ==
                {k: v for k, v in records[0]["context"].items() if k != "shard"} for r in records), "reviews bind different runs")
        status = "FAIL" if any(r["verdict"] == "FAIL" for r in records) else "NON_QUALIFYING" if records and not is_qualifying else "PASS" if complete else "PARTIAL"
        print(json.dumps({"status": status, "qualifying": is_qualifying, "records": records, "missing_fixtures": missing}, indent=2))
        return 0 if complete else 1
    except (ValueError, OSError, KeyError, TypeError, P2ContractError):
        print("P2 package or review validation failed; no human PASS is inferred.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
