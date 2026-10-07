#!/usr/bin/env python3
"""Measure explicit cold builds and warm strict cases; P2 stays needs-human-review."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

from ci_build_archive import file_hash, workspace_preflight
from ci_summary import observation, test_identity, write_summary
from run_host_checks import run_identity, source_metadata, toolchain
from run_strict_e2e import CommandError, write_sensitive_scan, WRONG_PUBLIC_API_KEY
from strict_e2e_build import build_settings, write_json
from strict_e2e_p2_contract import P2_CASES, RAW_VERDICT
from strict_e2e_server import PUBLIC_API_KEY, _fixture_data

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts/strict-tracer.json"
BUILD_OPERATIONS = re.compile(r"^(?:SwiftCompile|SwiftEmitModule|CompileC|Ld |CompileAssetCatalog|CodeSign |ProcessInfoPlistFile )", re.MULTILINE)


def review_material(case, destination):
    destination.mkdir(parents=True)
    # Retain only public fixture review material, never build logs or raw XCTest bundles.
    for pattern in ("*.png", "*.mov", "p2-*.json", "screen-recording-timing.json", "fixture-manifest.json", "official-summary.json"):
        for source in case.glob(pattern):
            shutil.copy2(source, destination / source.name)
    originals = destination / "originals"
    originals.mkdir()
    for name, value in _fixture_data("a")["images"].items():
        (originals / (name + ".png")).write_bytes(value)
    write_sensitive_scan(destination, [PUBLIC_API_KEY, WRONG_PUBLIC_API_KEY])
    write_json(destination / "review-hashes.json", {
        "source_sha": json.loads((case / "case-manifest.json").read_text())["source_sha"],
        "verdict": "needs-human-review",
        "files": {path.relative_to(destination).as_posix(): file_hash(path)
                  for path in sorted(destination.rglob("*")) if path.is_file()},
    })


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("ios", "tvos"), required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cold-timeout-seconds", type=int, default=1200)
    parser.add_argument("--warm-timeout-seconds", type=int, default=600)
    parser.add_argument("--min-free-gib", type=int, default=80)
    args = parser.parse_args(argv)
    if args.cold_timeout_seconds <= 0 or args.warm_timeout_seconds <= 0 or args.min_free_gib < 0:
        parser.error("timeouts must be positive and free space nonnegative")
    output = args.output_dir.resolve()
    if output == ROOT or ROOT in output.parents or os.path.lexists(output):
        parser.error("output must be fresh and outside the checkout")
    output.mkdir(parents=True)
    manifest = json.loads(MANIFEST.read_text())
    cases = [case for case in manifest["cases"] if case["platform"] == args.platform]
    identities = [test_identity("strict", case["suite"], **{key: case[key] for key in ("device", "configuration", "suite", "scenario", "fixture")}) for case in cases]
    identity = run_identity(os.environ, ci=os.environ.get("GITHUB_ACTIONS") == "true")
    workspace_preflight(ROOT)
    workflow, fork = source_metadata(identity, os.environ, ".github/workflows/ci-strict-tracer.yml" if identity["event"] != "local" else None)
    summary = {"schema_version": 1, "identity": identity,
               "source": {"repository": identity["repository"], "event": identity["event"], "workflow_path": workflow, "fork_originated": fork, "ci_changing": None},
               "run": {"id": os.environ.get("GITHUB_RUN_ID"), "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")), "tier": "strict", "job": "strict-tracer", "shard": args.platform},
               "hashes": {"manifests": {"strict-tracer": file_hash(MANIFEST)}, "policies": {}},
               "toolchain": toolchain(), "population": {"declared": identities, "compiled": [], "observed": [], "deselected": [], "removed_by_pr": []},
               "infrastructure": [], "status": "unverified"}
    records = output / "records"
    records.mkdir()
    write_summary(summary, records)
    free_samples = [shutil.disk_usage("/System/Volumes/Data").free]
    stopped = threading.Event()

    def sample_disk():
        while not stopped.wait(1):
            free_samples.append(shutil.disk_usage("/System/Volumes/Data").free)

    sampler = threading.Thread(target=sample_disk, daemon=True)
    sampler.start()
    trace = {"schema_version": 1, "cold": [], "warm": [], "exclusions": manifest["exclusions"],
             "budgets_seconds": {"cold": args.cold_timeout_seconds, "warm": args.warm_timeout_seconds},
             "min_free_gib": args.min_free_gib}
    failed = False

    def invoke(case, evidence, derived, warm):
        command = [sys.executable, "-B", str(ROOT / "scripts/run_strict_e2e.py"),
                   "--platform", args.platform, "--destination", args.destination, "--suite", case["suite"],
                   "--configuration", case["configuration"], "--scenario", case["scenario"], "--fixture-set", case["fixture"],
                   "--evidence-dir", str(evidence), "--derived-data-path", str(derived),
                   "--cloned-source-packages-path", str(output / "SourcePackages"),
                   "--cold-timeout-seconds", str(args.cold_timeout_seconds), "--warm-timeout-seconds", str(args.warm_timeout_seconds),
                   "--min-free-gib", str(args.min_free_gib), "--test-without-building" if warm else "--warm-up-only"]
        started = time.monotonic()
        print(f"{'warm' if warm else 'cold'} {case['suite']}", flush=True)
        with (output / "runner.log").open("a") as log:
            code = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                  timeout=(args.warm_timeout_seconds if warm else args.cold_timeout_seconds) + 240).returncode
        return code, time.monotonic() - started

    try:
        workspace_preflight(ROOT)
        shards = {}
        for case, case_identity in zip(cases, identities):
            scheme, plan, configuration = build_settings(args.platform, case["suite"], case["configuration"])
            shard = scheme + "-" + configuration
            derived = output / "derived" / shard
            if shard not in shards:
                code, duration = invoke(case, output / "warm-up" / shard, derived, False)
                trace["cold"].append({"shard": shard, "duration_seconds": duration, "exit_code": code})
                if code:
                    raise RuntimeError(f"Cold build failed with exit {code}")
                shards[shard] = True
                receipt = json.loads((derived / "strict-warm-build.json").read_text())
                summary["toolchain"]["signing_mode"] = "sign-to-run-locally"
                summary["toolchain"]["versions"]["codesign_signature"] = receipt["signing_mode"]
            evidence = output / "cases" / case["suite"]
            code, duration = invoke(case, evidence, derived, True)
            reuse = evidence / "xcodebuild-reuse.json"
            manifest_path = evidence / "case-manifest.json"
            details = json.loads(manifest_path.read_text()) if manifest_path.is_file() else {}
            log_path = evidence / "xcodebuild.log"
            builds = BUILD_OPERATIONS.findall(log_path.read_text()) if log_path.is_file() else ["missing log"]
            unchanged = reuse.is_file() and json.loads(reuse.read_text())["products_unchanged"] is True
            trace["warm"].append({"identity": case_identity, "duration_seconds": duration, "exit_code": code,
                                  "build_operations": len(builds), "products_unchanged": unchanged,
                                  "official_summary": details.get("official_summary")})
            automated_pass = code == 0 and not builds and unchanged
            outcome = "passed" if automated_pass else "failed"
            if automated_pass and case["suite"] in P2_CASES:
                if details.get("visual_identity", {}).get("verdict") != RAW_VERDICT:
                    outcome = "failed"
                else:
                    outcome = "needs-human-review"
                    review_material(evidence, output / "review" / case["suite"])
            failed |= outcome == "failed"
            # The runner rejects zero/missing/skipped official execution; preserve its observed selector.
            if details.get("official_summary") is not None:
                summary["population"]["compiled"].append(case_identity)
            summary["population"]["observed"].append(observation(case_identity, outcome, duration,
                reason="Original fixture captures need signed human review" if outcome == "needs-human-review" else None, exit_code=code))
            print(f"{case['suite']}: {outcome}, {duration:.1f}s, build operations={len(builds)}", flush=True)
            write_summary(summary, records)
    except (CommandError, ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        failed = True
        summary["infrastructure"].append({"code": "strict-tracer-failed", "message": str(error)})
        print(str(error), file=sys.stderr)
    finally:
        stopped.set()
        sampler.join(timeout=5)
        free_samples.append(shutil.disk_usage("/System/Volumes/Data").free)
        trace["disk"] = {"before_free_gib": free_samples[0] / 1024**3, "after_free_gib": free_samples[-1] / 1024**3,
                         "minimum_free_gib": min(free_samples) / 1024**3,
                         "peak_used_gib": (shutil.disk_usage("/System/Volumes/Data").total - min(free_samples)) / 1024**3,
                         "peak_growth_gib": (free_samples[0] - min(free_samples)) / 1024**3, "sampling_interval_seconds": 1}
        write_json(records / "trace.json", trace)
        summary["status"] = "failed" if failed else ("unverified" if any(item["outcome"] == "needs-human-review" for item in summary["population"]["observed"]) else "passed")
        write_summary(summary, records)
        with (records / "summary.md").open("a") as report:
            report.write("\nCold build durations: " + ", ".join(f"{item['shard']}: {item['duration_seconds']:.1f}s" for item in trace["cold"]) + "\n")
            report.write(f"\nPeak sampled disk growth: {trace['disk']['peak_growth_gib']:.2f} GiB; minimum free: {trace['disk']['minimum_free_gib']:.2f} GiB.\n")
        # All these directories are created by this tracer, after every child has exited.
        for name in ("derived", "SourcePackages"):
            path = output / name
            if path.exists():
                shutil.rmtree(path)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
