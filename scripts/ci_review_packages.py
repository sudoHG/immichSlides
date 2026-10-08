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

from ci_summary import decode, fields, integer, parse_summary, require, sha
from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256
from strict_e2e_p2_contract import (DEVICE_PLATFORM, P2_CASES, P2ContractError, RAW_VERDICT,
                                  RECORDING_TIMING_FILE, REVIEW_FILE, REVIEW_SCHEMA, STEPS_FILE,
                                  evaluate_review, read_official_tests_export, require_official_execution,
                                  validate_raw_evidence)
from strict_e2e_server import PUBLIC_API_KEY, _fixture_data, fixture_manifest

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "scripts/p2-review.html"
SIGNATURE = "I personally reviewed these images and recordings."
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
    from run_strict_e2e import WRONG_PUBLIC_API_KEY, write_sensitive_scan
    values = [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY]
    if redact_paths:
        values.extend(["/Users/", "/home/"])
    write_sensitive_scan(directory, values)


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
        manifest = {"schema_version": 1, "context": context, "case": case, "case_sha256": digest(case),
                    "facts": facts, "files": {p.name: file_digest(p) for p in sorted(staged.iterdir())},
                    "template_sha256": file_digest(TEMPLATE),
                    "fixture_marks": {a["label"]: a["sha256"] for a in fixture_manifest(fixture)["assets"]}}
        manifest["package_sha256"] = digest(manifest)
        write_json(staged / "package.json", manifest)
        (staged / "review.html").write_text(render_page(manifest))
        scan(staged)
        read_package(staged)
        staged.rename(destination)
    return manifest


def read_package(directory):
    require(directory.is_dir() and not directory.is_symlink(), "invalid package directory")
    file_digest(directory / "package.json")
    manifest = decode((directory / "package.json").read_text())
    fields(manifest, {"schema_version", "context", "case", "case_sha256", "facts", "files",
                      "template_sha256", "fixture_marks", "package_sha256"}, "package")
    require(type(manifest["schema_version"]) is int and manifest["schema_version"] == 1, "unknown package schema")
    validate_key(manifest["context"], manifest["case"])
    require(manifest["case_sha256"] == digest(manifest["case"]), "case hash differs")
    require(manifest["package_sha256"] == digest({k: v for k, v in manifest.items() if k != "package_sha256"}),
            "package hash differs")
    suite, fixture = manifest["case"]["suite"], manifest["case"]["fixture"]
    raw = validate_raw_evidence(directory, suite, fixture)
    expected_files = set(raw["artifacts"]) | set(raw["records"]) | {"case.json"} | {
        f"fixture-{asset['label']}.png" for asset in fixture_manifest(fixture)["assets"]}
    require(set(manifest["files"]) == expected_files, "package file allowlist differs")
    require({p.name for p in directory.iterdir()} == expected_files | {"package.json", "review.html", "sensitive-scan.json"},
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
    file_digest(directory / "sensitive-scan.json")
    scan(directory)
    return manifest


def record_path(record):
    validate_key(record["context"], record["case"])
    case = record["case"]
    return Path(record["context"]["source_sha"]) / case["suite"] / case["device"] / (case["fixture"] + ".json")


def validate_record(record, package):
    """A declared human signature is checked, never inferred or synthesized by CI."""
    record = decode(record)
    fields(record, {"schema_version", "context", "case", "case_sha256", "package_sha256", "reviewed_at", "signature", "review"}, "review record")
    require(type(record["schema_version"]) is int and record["schema_version"] == 1, "unknown review schema")
    validate_key(record["context"], record["case"])
    manifest = read_package(package)
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
    case, raw = manifest["case"], manifest["facts"]["raw"]
    review = record["review"]
    require(review.get("schema") == REVIEW_SCHEMA and review.get("verdict") in {"PASS", "FAIL", "PARTIAL"}, "invalid human verdict")
    require(set(review.get("artifacts", {})) == set(raw["artifacts"]), "review artifact set differs")
    # Reuse the existing sign-off contract for marks, cache checks and video coverage.
    with tempfile.TemporaryDirectory(prefix="p2-record-validation-") as temporary:
        write_json(Path(temporary) / REVIEW_FILE, review)
        scan(Path(temporary))
        return evaluate_review(Path(temporary), suite=case["suite"], device_class=case["device"],
            source_sha=manifest["context"]["source_sha"], fixture_set=case["fixture"],
            artifacts=raw["artifacts"], mark_offsets=raw.get("mark_offsets", {}),
            cache_target_mark=(raw.get("cache_clear") or raw.get("cache_return") or {}).get("target_mark"))


def export_shard(input_dir, output_dir):
    summary = parse_summary((input_dir / "records/summary.json").read_text())
    identity, run = summary["identity"], summary["run"]
    context = {"source_sha": identity.get("commit_sha"), "tree_sha": identity["tree_sha"],
               "repository": identity["repository"], "workflow_path": summary["source"]["workflow_path"],
               "event": identity["event"], "ref": identity.get("ref"), "run_id": run["id"],
               "run_attempt": run["attempt"], "shard": run["shard"],
               "matrix_sha256": summary["hashes"]["manifests"]["nightly-matrix"]}
    require(not os.path.lexists(output_dir), "shard package directory must be fresh")
    output_dir.mkdir(parents=True)
    packages, missing = [], []
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
            build_package(input_dir / "cases" / f"{index:03d}-{suite}", output_dir / relative, context, case)
            packages.append(relative.as_posix())
        except (ValueError, OSError, P2ContractError):
            missing.append({"case": case, "reason": "package validation or sensitive scan refused publication"})
    write_json(output_dir / "index.json", {"schema_version": 1, "packages": packages, "unavailable": missing})
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
    validate.add_argument("--package", type=Path, required=True)
    read = commands.add_parser("read")
    read.add_argument("--records-dir", type=Path, default=ROOT / "review-records")
    read.add_argument("--sha", required=True)
    read.add_argument("--suite", choices=sorted(P2_CASES), required=True)
    read.add_argument("--device-class", choices=sorted(DEVICE_PLATFORM), required=True)
    read.add_argument("--packages-dir", type=Path, required=True)
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
            verdict = validate_record(record, args.packages_dir / key.with_suffix(""))
            records.append({"fixture": fixture, "verdict": verdict, "context": record["context"]})
        complete = not missing and all(r["verdict"] == "PASS" for r in records)
        require(not records or all({k: v for k, v in r["context"].items() if k != "shard"} ==
                {k: v for k, v in records[0]["context"].items() if k != "shard"} for r in records), "reviews bind different runs")
        print(json.dumps({"status": "PASS" if complete else "PARTIAL", "records": records, "missing_fixtures": missing}, indent=2))
        return 0 if complete else 1
    except (ValueError, OSError, KeyError, TypeError, P2ContractError):
        print("P2 package or review validation failed; no human PASS is inferred.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
