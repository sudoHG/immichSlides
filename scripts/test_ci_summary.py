"""Guard the producer/reader contract and honest host-check failure reporting."""

import copy
import contextlib
import hashlib
import io
import json
import os
import re
import select
import signal
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import ci_summary
import ci_verdict
import run_host_checks
import run_python_tests


def valid_summary():
    identity = ci_summary.test_identity("host", "format")
    return {
        "schema_version": 1,
        "identity": {"schema_version": 1, "event": "local", "repository": "sudoHG/immichSlides",
                     "commit_sha": "a" * 40, "tree_sha": "b" * 40, "dirty": False},
        "source": {"repository": "sudoHG/immichSlides", "workflow_path": None, "event": "local",
                   "fork_originated": False, "ci_changing": None},
        "run": {"id": None, "attempt": 1, "tier": "host", "job": "host-checks", "shard": None},
        "hashes": {"manifests": {}, "policies": {}},
        "toolchain": {"versions": {"python": "3.13"}, "signing_mode": "not-applicable"},
        "population": {"declared": [identity], "compiled": [identity],
                       "observed": [ci_summary.observation(identity, "passed", 0.1)],
                       "deselected": [], "removed_by_pr": []},
        "infrastructure": [], "status": "passed",
    }


def discovery_summary():
    summary = valid_summary()
    summary.update(schema_version=2, identity={"schema_version": 1, "event": "pull_request",
        "repository": "sudoHG/immichSlides", "pull_request": 1, "base_sha": "a" * 40,
        "head_sha": "b" * 40, "merge_sha": "c" * 40, "tree_sha": "d" * 40})
    summary["source"].update(event="pull_request", workflow_path=".github/workflows/ci-ui.yml")
    summary["run"] = {"id": "123", "attempt": 1, "tier": "ui", "job": "ui-iphone", "shard": "scoped-a"}
    entry = ci_summary.test_identity("ui", "SettingsUITests/testOpen", platform="ios", device="iphone")
    summary["population"].update(declared=[entry], compiled=[entry],
        observed=[ci_summary.observation(entry, "passed", 1)])
    summary["hashes"]["manifests"]["ui-scoped-plan"] = "e" * 64
    summary["compiled_evidence"] = {"schema_version": 1, "mode": "official-result-discovery-v1",
        "identity": copy.deepcopy(summary["identity"]), "run": dict(summary["run"]), "plan_sha256": "e" * 64,
        "device_id": "target", "first_exit_code": 0,
        "official_tests": {"devices": [{"deviceId": "target", "modelName": "iPhone 17", "platform": "iOS Simulator"}],
            "testNodes": [{"nodeType": "UI test bundle", "name": "immichSlidesUITests", "children": [
                {"nodeType": "Test Case", "nodeIdentifier": entry["key"] + "()",
                 "result": "Passed", "durationInSeconds": 1}]}]}}
    refresh_discovery_hash(summary)
    return summary


def refresh_discovery_hash(summary):
    raw = json.dumps(summary["compiled_evidence"], sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    summary["hashes"]["manifests"]["ui-discovery"] = hashlib.sha256(raw).hexdigest()


def archive_download_summary():
    summary = valid_summary()
    summary["identity"] = {"schema_version": 1, "event": "schedule", "repository": "sudoHG/immichSlides",
                           "ref": "refs/heads/main", "commit_sha": "a" * 40, "tree_sha": "b" * 40}
    summary["source"].update(event="schedule", workflow_path=".github/workflows/ci-nightly.yml")
    summary["run"] = {"id": "123", "attempt": 2, "tier": "ui", "job": "ui-ipad", "shard": "navigation"}
    case = ci_summary.test_identity("ui", "NavigationUITests/testOpen", platform="ios", device="ipad")
    summary["population"].update(declared=[case], compiled=[case], observed=[ci_summary.observation(case, "passed", 1)])
    summary["archive_download"] = {"schema_version": 1, "artifact_id": 456,
        "action_outcome": "success", "member_bytes": {"manifest.json": 100, "build.tar.gz": 200},
        "digests_matched": {"manifest": True, "tar": True}, "size_matched": True,
        "transfer_extract_seconds": 2.5, "gate_seconds": 0.1, "free_disk_bytes": 1000, "failure_reason": None}
    return summary


def bounded_diagnostics_receipt(*, resources=False):
    receipt = {"schema_version": 1, "collection_seconds": {"preparation": 0.1, "xcode": 0.2, "fixture": 0.01},
        "truncated": False, "events": [
            {"scope": "preparation", "phase": "simulator-readiness", "state": "timeout", "sequence": 1,
             "elapsed_seconds": 301.5, "cpu_seconds": 0.01, "input_sha256": None, "official_exports": None,
             "sample": {"cpu_percent": 25.0, "memory_free_bytes": 1000, "load_average": [2.0, 1.0, 1.0],
                 "runner_hosted": True, "image_version": [20261006, 244, 1],
                 "processes": [{"name": "simctl", "state": "sleeping", "count": 1,
                                "cpu_percent": 0.0, "rss_bytes": 1024}]}},
            {"scope": "xcode", "phase": "test-execution", "state": "before-kill", "sequence": 2,
             "elapsed_seconds": 600.0, "cpu_seconds": None, "sample": None, "input_sha256": None,
             "official_exports": {"bundle": True, "summary": False, "tests": False}},
            {"scope": "fixture", "phase": "import", "state": "started", "sequence": 3,
             "elapsed_seconds": 0.0, "cpu_seconds": 0.0, "sample": None, "input_sha256": None,
             "official_exports": None},
            {"scope": "fixture", "phase": "image-generation", "state": "started", "sequence": 3,
             "elapsed_seconds": 0.1, "cpu_seconds": 0.02, "sample": None, "input_sha256": "e" * 64,
             "official_exports": None}]}
    if resources:
        receipt["case_resources"] = [{"sequence": 4, "duration_seconds": 12, "sample_interval_seconds": 2,
            "sample_count": 6, "truncated": False, "idle_percent_min": 10, "idle_percent_median": 30,
            "load_1m_max": 4, "app_cpu_percent_peak": 120, "sampler_wall_seconds": 0.06,
            "sampler_cpu_seconds": 0.03, "first_failure_elapsed_seconds": 8,
            "failure_samples": [{"elapsed_seconds": 6, "idle_percent": 10, "load_1m": 4,
                "cpu_percent": {"app": 120, "simulator_daemons": 30, "test_tools": 50, "other": 80}}]}]
    return receipt


def first_failure_receipt(*, native=False, gate=False):
    receipt = {"schema_version": 1, "source": "xctest", "step": "query-element",
        "element": "slideshow.control.playPause.button", "action": "select",
        "timing": {"since_action_issued_seconds": 8.28, "since_action_returned_seconds": 8.1,
            "action_duration_seconds": 0.18, "wait_elapsed_seconds": 5.1, "deadline_seconds": 5,
            "capture_request_seconds": 0.01, "capture_return_seconds": 0.3, "state_age_seconds": 0.1},
        "state": {"app": "running-foreground", "surface": "playback", "observation": "cached",
            "control_bar": "hidden", "focus": "slideshow.hiddenWakeReceiver", "history_count": 3,
            "autoplay": "on", "orientation": "landscape", "scene_status": "MATCH", "query_error_code": -25202},
        "validator": None, "screenshot": {"status": "captured", "width": 1536, "height": 864, "bytes": 1000}}
    if native:
        receipt["native_activity_seconds"] = {"pre_event_idle": 0.01, "find_window": 0.02,
            "synthesize_event": 0.36, "post_event_idle": 23.05, "ax_root_acquisition": None}
    if gate:
        receipt.update(step="wait-scene", element="slideshow.scenePresentation.contract.summary",
            gate={"kind": "album-capture", "stable": False, "paused": True, "entry_hint_hidden": False,
                  "advanced": None, "layers_changed": None, "manifest_complete": True, "phase": "stablePhoto"})
    return receipt


def hosted_timeout_summary():
    summary = valid_summary()
    summary["identity"].update(event="schedule", ref="refs/heads/main")
    summary["identity"].pop("dirty")
    summary["source"].update(event="schedule", workflow_path=".github/workflows/ci-nightly.yml")
    summary["run"].update(id="10", tier="strict", job="nightly-strict", shard="iphone-debug-0")
    identity = ci_summary.test_identity("strict", "smoke", device="iphone", configuration="Debug",
        suite="smoke", scenario="normal", fixture="a")
    row = ci_summary.observation(identity, "failed", 12, exit_code=65,
        failure_diagnostics={"failure_phase": "settings_navigation", "failure_class": "navigation"})
    row["first_failure"] = row["attempts"][0]["first_failure"] = first_failure_receipt()
    row["first_failure"]["element"] = "slideshow.control.settings.button"
    summary["population"].update(declared=[identity], compiled=[identity], observed=[row])
    summary["status"] = "failed"
    resource = bounded_diagnostics_receipt(resources=True)["case_resources"][0]
    resource["failure_samples"] = [dict(resource["failure_samples"][0], elapsed_seconds=6, idle_percent=0),
        dict(resource["failure_samples"][0], elapsed_seconds=10, idle_percent=5)]
    diagnostics = bounded_diagnostics_receipt()
    diagnostics["events"][0].update(scope="xcode", phase="test-execution", sequence=4)
    diagnostics["case_resources"] = [resource]
    summary["strict_case_evidence"] = [{"identity": identity, "bounded_diagnostics": diagnostics}]
    return summary, resource


def hosted_album_timeout_summary():
    summary, resource = hosted_timeout_summary()
    row = summary["population"]["observed"][0]
    row.update(failure_phase="visible_scene_capture", failure_class="probe_readback")
    row["attempts"][0].update(failure_phase="visible_scene_capture", failure_class="probe_readback")
    receipt = row["first_failure"]
    receipt.update(step="wait-scene", element="slideshow.scenePresentation.contract.summary",
        gate={"kind": "album-capture", "stable": False, "paused": True, "entry_hint_hidden": True,
              "advanced": True, "layers_changed": True, "manifest_complete": True, "phase": "transition"})
    receipt["timing"].update(wait_elapsed_seconds=5.23, deadline_seconds=4.8)
    return summary, resource


def hosted_mode_departure_summary(phase):
    summary, resource = hosted_timeout_summary()
    row = summary["population"]["observed"][0]
    row.update(failure_phase=phase, failure_class="navigation")
    row["attempts"][0].update(failure_phase=phase, failure_class="navigation")
    row["first_failure"].update(step="mode-departure", element="mode.continue.button", action="tap")
    row["first_failure"]["state"].update(surface="mode", scene_status="UNRECOGNIZABLE",
        observation="failure-snapshot", control_bar="unknown", focus="unknown", history_count=None,
        autoplay="unknown", orientation="portrait", query_error_code=None)
    return summary, resource


def album_capture_gate_rejections(receipt):
    """Single-fact violations shared by proof-reader and producer boundary tests."""
    from ci_failure_diagnostics import ALBUM_CAPTURE_GATE_PHASES
    ineligible = "environment limit: failure is not an eligible timing wait"
    cases = [("missing gate", None, None, "delete", ineligible)]
    for field in receipt["gate"]:
        cases.append(("missing " + field, field, None, "delete", "first failure gate: invalid fields"))
    cases += [(field + "=" + repr(value), field, value, "set", message)
        for field, values, message in (
            ("kind", (None, "other"), "first failure: invalid gate kind"),
            ("stable", (True, None), ineligible),
            ("paused", (False, None), ineligible),
            ("entry_hint_hidden", (False, None), ineligible),
            ("advanced", (False, None), ineligible),
            ("layers_changed", (False, None), ineligible),
            ("manifest_complete", (False, None), ineligible),
            ("phase", (None, "other"), "first failure: invalid gate phase"),
            ("phase", tuple(phase for phase in ALBUM_CAPTURE_GATE_PHASES
                            if phase not in {"transition", "incomingFromLoading"}), ineligible))
        for value in values]
    for field in ("stable", "paused", "entry_hint_hidden", "advanced", "layers_changed", "manifest_complete"):
        for value in (0, 1, "true"):
            cases.append((field + "=" + repr(value), field, value, "set", "first failure gate: invalid boolean"))
    for label, field, value, operation, message in cases:
        changed = copy.deepcopy(receipt)
        if field is None:
            changed.pop("gate")
        elif operation == "delete":
            changed["gate"].pop(field)
        else:
            changed["gate"][field] = value
        yield label, changed, message
    changed = copy.deepcopy(receipt)
    changed["gate"] = None
    yield "null gate", changed, "first failure gate: invalid fields"
    changed = copy.deepcopy(receipt)
    changed["element"] = "slideshow.control.next.button"
    yield "Next did not advance", changed, ineligible
    changed = copy.deepcopy(receipt)
    changed["gate"].update(advanced=None, layers_changed=None)
    yield "first capture frozen transition", changed, ineligible


class SummaryContractTests(unittest.TestCase):
    def test_mode_departure_policy_preserves_each_retained_version(self):
        from ci_failure_diagnostics import (ENVIRONMENT_WAIT_STEPS, ENVIRONMENT_WAIT_STEPS_V3,
            environment_limit_evidence, scan_diagnostic_json, validate_environment_limit)
        self.assertEqual({**ENVIRONMENT_WAIT_STEPS,
            **{(phase, "navigation", "mode-departure", "mode.continue.button"): "mode"
               for phase in ("mode_selection", "playback_entry")}}, ENVIRONMENT_WAIT_STEPS_V3)
        for phase in ("mode_selection", "playback_entry"):
            summary, resource = hosted_mode_departure_summary(phase)
            row = summary["population"]["observed"][0]
            proof = environment_limit_evidence(summary, row, [resource], runner_hosted=True, policy_version=3)
            with self.subTest(phase=phase):
                self.assertIsNotNone(proof)
                row["environment_limit"] = row["attempts"][0]["environment_limit"] = proof
                self.assertEqual(proof, ci_summary.parse_summary(summary)["population"]["observed"][0]["environment_limit"])
                scan_diagnostic_json(json.dumps(summary).encode())
                for version in (1, 2):
                    with self.subTest(legacy_version=version), self.assertRaisesRegex(ci_summary.ContractError,
                            "^environment limit: failure is not an eligible timing wait$"):
                        validate_environment_limit(dict(proof, policy_version=version))
        for version in (1, 2, 3):
            summary, resource = hosted_mode_departure_summary("mode_selection")
            row = summary["population"]["observed"][0]
            row["first_failure"]["step"] = "mode-continue"
            with self.subTest(continue_version=version):
                proof = environment_limit_evidence(summary, row, [resource], runner_hosted=True, policy_version=version)
                self.assertIsNotNone(proof)
                row["environment_limit"] = row["attempts"][0]["environment_limit"] = proof
                self.assertEqual(proof, ci_summary.parse_summary(summary)["population"]["observed"][0]["environment_limit"])
        for phase in ("transition", "incomingFromLoading"):
            summary, resource = hosted_album_timeout_summary()
            row = summary["population"]["observed"][0]
            row["first_failure"]["gate"]["phase"] = phase
            proof = environment_limit_evidence(summary, row, [resource], runner_hosted=True, policy_version=3)
            with self.subTest(album_phase=phase):
                self.assertIsNotNone(proof)
                row["environment_limit"] = row["attempts"][0]["environment_limit"] = proof
                self.assertEqual(proof, ci_summary.parse_summary(summary)["population"]["observed"][0]["environment_limit"])
                if phase == "transition":
                    for label, receipt, message in album_capture_gate_rejections(row["first_failure"]):
                        changed = copy.deepcopy(proof)
                        changed["failure"].pop("gate")
                        if "gate" in receipt:
                            changed["failure"]["gate"] = receipt["gate"]
                        changed["failure"]["element"] = receipt["element"]
                        with self.subTest(v3_album_rejection=label), self.assertRaisesRegex(ci_summary.ContractError,
                                "^" + message + "$"):
                            validate_environment_limit(changed)

    def test_mode_departure_rejects_each_non_timing_or_unproven_failure(self):
        from ci_failure_diagnostics import environment_limit_evidence, validate_environment_limit
        summary, resource = hosted_mode_departure_summary("mode_selection")
        row = summary["population"]["observed"][0]
        proof = environment_limit_evidence(summary, row, [resource], runner_hosted=True, policy_version=3)
        self.assertIsNotNone(proof)
        for path, value in (
                *((("failure", "surface"), surface) for surface in (
                    "playback", "firstboot", "cache", "playback-settings", "system-settings", "unknown")),
                (("failure", "step"), "mode-card"), (("failure", "step"), "query-element"),
                (("failure", "element"), "mode.random.button"),
                (("failure_phase",), "firstboot_setup"), (("failure_class",), "control_state"),
                (("failure", "source"), "validator"), (("failure", "app"), "background"),
                (("failure", "scene_status"), "BLACK"), (("failure", "scene_status"), "BLANK"),
                (("failure", "wait_elapsed_seconds"), 4.99), (("failure", "wait_elapsed_seconds"), None),
                (("failure", "deadline_seconds"), 0), (("failure", "deadline_seconds"), None)):
            changed = copy.deepcopy(proof)
            target = changed
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(path=path, value=value), self.assertRaisesRegex(ci_summary.ContractError,
                    "^environment limit: failure is not an eligible timing wait$"):
                validate_environment_limit(changed)
        for path, value in (
                (("failure_samples", 0, "elapsed_seconds"), 9),
                (("failure_samples", 1, "elapsed_seconds"), 7),
                (("failure_samples", 0, "elapsed_seconds"), 8),
                (("failure_samples", 1, "elapsed_seconds"), 8),
                (("failure_samples", 0, "idle_percent"), 5.01),
                (("failure_samples",), [resource["failure_samples"][0]])):
            changed = copy.deepcopy(proof)
            target = changed["resources"]
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(resource_path=path, value=value), self.assertRaisesRegex(ci_summary.ContractError,
                    "^environment limit: insufficient starvation evidence$"):
                validate_environment_limit(changed)

    def test_album_environment_policy_rechecks_gate_and_preserves_legacy_proofs(self):
        from ci_failure_diagnostics import environment_limit_evidence, validate_environment_limit
        summary, resource = hosted_album_timeout_summary()
        row = summary["population"]["observed"][0]
        proof = environment_limit_evidence(summary, row, [resource], runner_hosted=True, policy_version=2)
        self.assertIsNotNone(proof)
        self.assertEqual(row["first_failure"]["gate"], proof["failure"]["gate"])
        row["environment_limit"] = row["attempts"][0]["environment_limit"] = proof
        self.assertEqual(proof, ci_summary.parse_summary(summary)["population"]["observed"][0]["environment_limit"])
        for phase in ("transition", "incomingFromLoading"):
            changed = copy.deepcopy(row)
            changed["first_failure"]["gate"]["phase"] = phase
            with self.subTest(phase=phase):
                self.assertIsNotNone(environment_limit_evidence(summary, changed, [resource],
                    runner_hosted=True, policy_version=2))
        for label, receipt, message in album_capture_gate_rejections(row["first_failure"]):
            changed = copy.deepcopy(row)
            changed["first_failure"] = receipt
            tampered = copy.deepcopy(proof)
            tampered["failure"].pop("gate")
            if "gate" in receipt:
                tampered["failure"]["gate"] = receipt["gate"]
            tampered["failure"]["element"] = receipt["element"]
            with self.subTest(violation=label):
                self.assertIsNone(environment_limit_evidence(summary, changed, [resource],
                    runner_hosted=True, policy_version=2))
                with self.assertRaisesRegex(ci_summary.ContractError, "^" + message + "$"):
                    validate_environment_limit(tampered)
        for elapsed in (7, 9):
            changed = copy.deepcopy(proof)
            changed["resources"]["failure_samples"][1 if elapsed == 7 else 0]["elapsed_seconds"] = elapsed
            with self.subTest(one_sided=elapsed), self.assertRaisesRegex(ci_summary.ContractError,
                    "^environment limit: insufficient starvation evidence$"):
                validate_environment_limit(changed)
        for path, value in (
                (("failure_phase",), "history_navigation"), (("failure_class",), "scene_identity"),
                (("failure", "surface"), "mode"), (("failure", "app"), "not-running"),
                *((("failure", "scene_status"), status) for status in ("BLACK", "BLANK", "UNRECOGNIZABLE")),
                (("failure", "wait_elapsed_seconds"), 4.79), (("failure", "wait_elapsed_seconds"), None),
                (("failure", "deadline_seconds"), 0), (("failure", "deadline_seconds"), None)):
            changed = copy.deepcopy(proof)
            target = changed
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(common_rule=path, value=value), self.assertRaisesRegex(ci_summary.ContractError,
                    "^environment limit: failure is not an eligible timing wait$"):
                validate_environment_limit(changed)
        old, old_resource = hosted_timeout_summary()
        old_row = old["population"]["observed"][0]
        legacy = environment_limit_evidence(old, old_row, [old_resource], runner_hosted=True, policy_version=1)
        old_row["environment_limit"] = old_row["attempts"][0]["environment_limit"] = legacy
        self.assertEqual(legacy, ci_summary.parse_summary(old)["population"]["observed"][0]["environment_limit"])
        with self.assertRaisesRegex(ci_summary.ContractError, "^environment failure: expected fields"):
            validate_environment_limit(dict(proof, policy_version=1))

    def test_album_gate_survives_public_summary_and_rejects_unbounded_facts(self):
        from ci_failure_diagnostics import public_first_failure, scan_diagnostic_json
        for summary in (archive_download_summary(), discovery_summary()):
            summary.pop("archive_download", None)
            if "compiled_evidence" in summary:
                summary["compiled_evidence"]["first_exit_code"] = 65
                summary["compiled_evidence"]["official_tests"]["testNodes"][0]["children"][0]["result"] = "Failed"
                refresh_discovery_hash(summary)
            identity = summary["population"]["declared"][0]
            row = ci_summary.observation(identity, "failed", 1, exit_code=65)
            row["first_failure"] = row["attempts"][0]["first_failure"] = first_failure_receipt(gate=True)
            summary["population"]["observed"] = [row]
            summary["status"] = "failed"
            for element in ("slideshow.scenePresentation.contract.summary", "slideshow.control.next.button"):
                row["first_failure"]["element"] = element
                with self.subTest(version=summary["schema_version"], element=element):
                    read = ci_summary.parse_summary(json.dumps(summary))
                    receipt = read["population"]["observed"][0]["first_failure"]
                    self.assertEqual(row["first_failure"]["gate"], public_first_failure(receipt)["gate"])
                    line = next(line for line in ci_summary.render_markdown(read).splitlines() if "First failure:" in line)
                    self.assertIn("gate=album-capture", line)
                    self.assertIn("stable=false, paused=true, entry_hint_hidden=false, advanced=null, layers_changed=null, manifest_complete=true, phase=stablePhoto", line)
                    scan_diagnostic_json(json.dumps({"nested": [read]}).encode())
            # A timeout before any completed poll publishes only nulls and an unknown phase.
            unobserved = copy.deepcopy(row["first_failure"])
            unobserved["gate"] = {"kind": "album-capture", **dict.fromkeys(("stable", "paused", "entry_hint_hidden",
                "advanced", "layers_changed", "manifest_complete")), "phase": "unknown"}
            self.assertEqual(unobserved["gate"], public_first_failure(unobserved)["gate"])
            missing = copy.deepcopy(row["first_failure"])
            del missing["gate"]["manifest_complete"]
            self.assertIsNone(public_first_failure(missing))
            cases = [
                (("gate",), None, "first failure gate: invalid fields"),
                (("gate", "asset_id"), "private", "first failure gate: invalid fields"),
                (("gate", "kind"), "private", "first failure: invalid gate kind"),
                (("gate", "phase"), "private", "first failure: invalid gate phase"),
                (("source",), "validator", "first failure: gate requires album capture timeout context"),
                (("step",), "capture-frame", "first failure: gate requires album capture timeout context"),
                (("element",), "app-window", "first failure: gate requires album capture timeout context"),
            ]
            for key in ("stable", "paused", "entry_hint_hidden", "advanced", "layers_changed", "manifest_complete"):
                for invalid in (0, 1, "true", [], {}):
                    cases.append((("gate", key), invalid, "first failure gate: invalid boolean"))
            for path, value, message in cases:
                changed = copy.deepcopy(row["first_failure"])
                target = changed
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.subTest(path=path, value=value):
                    self.assertIsNone(public_first_failure(changed))
                    with self.assertRaisesRegex(ci_summary.ContractError, "^" + message + "$"):
                        scan_diagnostic_json(json.dumps({"nested": [{"first_failure": changed}]}).encode())

    def test_first_failure_lines_follow_all_summary_table_rows(self):
        summary = archive_download_summary()
        summary.pop("archive_download")
        first = summary["population"]["declared"][0]
        second = {**first, "key": first["key"] + "Second"}
        deselected = {**first, "key": first["key"] + "Elsewhere"}
        summary["population"].update(declared=[first, second, deselected], compiled=[first, second],
            deselected=[{"identity": deselected, "reason": "Owned elsewhere", "owning_tier": "strict"}],
            observed=[ci_summary.observation(identity, "failed", 1, exit_code=65) for identity in (first, second)])
        summary["status"] = "failed"
        row = summary["population"]["observed"][0]
        row["first_failure"] = row["attempts"][0]["first_failure"] = first_failure_receipt()
        rendered = ci_summary.render_markdown(summary)
        table_end = rendered.index("| " + deselected["key"] + " |")
        self.assertGreater(rendered.index("First failure:"), table_end)
        self.assertIn("First failure: " + first["key"], rendered)

    def test_first_failure_survives_summary_aggregation_and_flaky_first_attempt(self):
        from ci_failure_diagnostics import environment_limit_evidence
        yellow, resources = hosted_timeout_summary()
        row = yellow["population"]["observed"][0]
        proof = environment_limit_evidence(yellow, row, [resources], runner_hosted=True)
        self.assertIsNotNone(proof)
        for changed_field, value in (("failure_class", "scene_identity"), ("failure_class", "control_state")):
            changed = copy.deepcopy(row)
            changed[changed_field] = value
            busy = copy.deepcopy(resources)
            for sample in busy["failure_samples"]:
                sample["idle_percent"] = 0
            self.assertIsNone(environment_limit_evidence(yellow, changed, [busy], runner_hosted=True))
        for change in ("busy", "one", "missing", "outside", "duplicate", "before only", "after only"):
            changed = copy.deepcopy(resources)
            if change == "busy":
                changed["failure_samples"][1]["idle_percent"] = 5.01
            elif change == "one":
                changed["failure_samples"].pop()
            elif change == "missing":
                changed["failure_samples"][1]["idle_percent"] = None
            elif change == "outside":
                changed["failure_samples"][0]["elapsed_seconds"] = 2.99
            elif change == "duplicate":
                changed["failure_samples"][1]["elapsed_seconds"] = 6
            elif change == "before only":
                changed["failure_samples"][1]["elapsed_seconds"] = 7
            else:
                changed["failure_samples"][0]["elapsed_seconds"] = 9
            with self.subTest(change=change):
                self.assertIsNone(environment_limit_evidence(yellow, row, [changed], runner_hosted=True))
        self.assertIsNone(environment_limit_evidence(yellow, row, [resources], runner_hosted=False))
        local = copy.deepcopy(yellow)
        local["source"]["event"] = "local"
        self.assertIsNone(environment_limit_evidence(local, row, [resources], runner_hosted=True))
        truncated = copy.deepcopy(resources)
        truncated["truncated"] = True
        for sample in truncated["failure_samples"]:
            sample["cpu_percent"] = dict.fromkeys(sample["cpu_percent"])
        self.assertIsNotNone(environment_limit_evidence(yellow, row, [truncated], runner_hosted=True))
        boundary = copy.deepcopy(resources)
        boundary["duration_seconds"] = 13
        boundary["failure_samples"][0]["elapsed_seconds"] = 3
        boundary["failure_samples"][1]["elapsed_seconds"] = 13
        self.assertIsNotNone(environment_limit_evidence(yellow, row, [boundary], runner_hosted=True))
        mode_wait = copy.deepcopy(row)
        mode_wait.update(failure_phase="mode_selection", failure_class="navigation")
        mode_wait["first_failure"].update(step="mode-card", element="mode.random.button", action="tap")
        mode_wait["first_failure"]["state"].update(surface="mode", scene_status="UNRECOGNIZABLE")
        # Main run 39591470339: a real mode-card deadline failure, with no resource samples.
        mode_wait["first_failure"]["timing"].update(wait_elapsed_seconds=7.788485416666845, deadline_seconds=7)
        no_samples = dict(resources, sample_count=0, first_failure_elapsed_seconds=None,
            failure_samples=[], idle_percent_min=None, idle_percent_median=None, truncated=True)
        self.assertIsNone(environment_limit_evidence(yellow, mode_wait, [no_samples], runner_hosted=True))
        self.assertIsNotNone(environment_limit_evidence(yellow, mode_wait, [resources], runner_hosted=True))
        pending_review = ci_summary.observation(row["identity"], "needs-human-review", 12)
        self.assertIsNone(environment_limit_evidence(yellow, pending_review, [resources], runner_hosted=True))
        for phase, step in (("playback_entry", "mode-departure"), ("firstboot_setup", "query-element"),
                            ("mode_selection", "query-element")):
            wrong_target = copy.deepcopy(row)
            wrong_target.update(failure_phase=phase, failure_class="navigation")
            wrong_target["first_failure"]["step"] = step
            with self.subTest(unlisted_navigation_target=(phase, step)):
                self.assertIsNone(environment_limit_evidence(yellow, wrong_target, [resources], runner_hosted=True))
        for elapsed, expected in ((5, True), (4.99, False)):
            changed = copy.deepcopy(row)
            changed["first_failure"]["timing"]["wait_elapsed_seconds"] = elapsed
            self.assertEqual(environment_limit_evidence(yellow, changed, [resources], runner_hosted=True) is not None, expected)
        # Native idle alone has no following successful readback and must remain red.
        for step, action, duration in (("select", "tap", 25), ("query-element", "tap", 25),
                                       ("select", "select", 25), ("select", "tap", 19)):
            changed = copy.deepcopy(row)
            receipt = changed["first_failure"]
            receipt.update(step=step, action=action)
            receipt["timing"].update(wait_elapsed_seconds=None, deadline_seconds=None, action_duration_seconds=duration)
            receipt["native_activity_seconds"] = dict.fromkeys(("pre_event_idle", "find_window", "synthesize_event",
                "post_event_idle", "ax_root_acquisition"))
            receipt["native_activity_seconds"]["post_event_idle"] = 20
            self.assertIsNone(environment_limit_evidence(yellow, changed, [resources], runner_hosted=True))
        for state_field, value in (("surface", "unknown"), ("surface", "mode"), ("scene_status", "BLANK"),
                                   ("scene_status", "UNRECOGNIZABLE")):
            changed = copy.deepcopy(row)
            changed["first_failure"]["state"][state_field] = value
            with self.subTest(state_field=state_field, value=value):
                self.assertIsNone(environment_limit_evidence(yellow, changed, [resources], runner_hosted=True))
        for step, element in (("mode-continue", "mode.continue.button"), ("mode-card", "mode.filtered.button")):
            changed = copy.deepcopy(mode_wait)
            changed["first_failure"].update(step=step, element=element)
            self.assertIsNotNone(environment_limit_evidence(yellow, changed, [resources], runner_hosted=True))
            changed["first_failure"]["state"]["surface"] = "playback"
            self.assertIsNone(environment_limit_evidence(yellow, changed, [resources], runner_hosted=True))
        changed = copy.deepcopy(row)
        changed["first_failure"]["source"] = "validator"
        changed["first_failure"]["screenshot"] = {"status": "unavailable", "width": None, "height": None, "bytes": None}
        self.assertIsNone(environment_limit_evidence(yellow, changed, [resources], runner_hosted=True))
        changed = copy.deepcopy(row)
        changed.update(failure_phase="unknown", failure_class="snapshot_query")
        self.assertIsNone(environment_limit_evidence(yellow, changed, [resources], runner_hosted=True))
        changed.update(failure_phase="hidden_controls", failure_class="hidden_controls")
        self.assertIsNotNone(environment_limit_evidence(yellow, changed, [resources], runner_hosted=True))
        changed["first_failure"]["state"]["control_bar"] = "visible"
        self.assertIsNone(environment_limit_evidence(yellow, changed, [resources], runner_hosted=True))
        changed = copy.deepcopy(row)
        changed["first_failure"]["element"] = "unknown"
        self.assertIsNone(environment_limit_evidence(yellow, changed, [resources], runner_hosted=True))
        for source_change in ("black", "process", "validator", "phase", "missing receipt", "multiple cases"):
            changed = copy.deepcopy(row)
            cases = [resources]
            if source_change == "black":
                changed["first_failure"]["state"]["scene_status"] = "BLACK"
            elif source_change == "process":
                changed["first_failure"]["state"]["app"] = "not-running"
                changed["first_failure"]["screenshot"] = {"status": "unavailable", "width": None, "height": None, "bytes": None}
            elif source_change == "validator":
                changed["validator_failure_message"] = "All black must not count as a pass"
            elif source_change == "phase":
                changed["failure_phase"] = "history_navigation"
            elif source_change == "missing receipt":
                changed.pop("first_failure")
            else:
                cases = [resources, dict(resources, sequence=5)]
            with self.subTest(source_change=source_change):
                self.assertIsNone(environment_limit_evidence(yellow, changed, cases, runner_hosted=True))
        row["environment_limit"] = row["attempts"][0]["environment_limit"] = proof
        self.assertEqual("failed", ci_summary.parse_summary(json.dumps(yellow))["population"]["observed"][0]["outcome"])
        self.assertIn("ENVIRONMENT-LIMITED", ci_summary.render_markdown(yellow))
        self.assertIn("| failed (environment-limited; yellow) |", ci_summary.render_markdown(yellow))
        from ci_failure_diagnostics import scan_diagnostic_json
        scan_diagnostic_json(json.dumps(yellow).encode())
        for mutation in ("missing", "identity", "sequence", "hosted", "resources", "missing host", "conflicting host"):
            changed = copy.deepcopy(yellow)
            changed["strict_case_evidence"] = copy.deepcopy(changed["strict_case_evidence"])
            evidence = changed["strict_case_evidence"][0]
            if mutation == "missing":
                changed.pop("strict_case_evidence")
            elif mutation == "identity":
                evidence["identity"] = dict(evidence["identity"], key="other-case")
            elif mutation == "sequence":
                evidence["bounded_diagnostics"]["events"][0]["sequence"] = 5
            elif mutation == "hosted":
                evidence["bounded_diagnostics"]["events"][0]["sample"]["runner_hosted"] = False
            elif mutation == "missing host":
                evidence["bounded_diagnostics"]["events"][0]["sample"] = None
            elif mutation == "conflicting host":
                event = copy.deepcopy(evidence["bounded_diagnostics"]["events"][0])
                event["sample"]["runner_hosted"] = False
                evidence["bounded_diagnostics"]["events"].append(event)
            else:
                evidence["bounded_diagnostics"]["case_resources"][0]["failure_samples"][0]["idle_percent"] = 1
            with self.subTest(binding=mutation), self.assertRaisesRegex(ci_summary.ContractError,
                    "^environment limit differs from summary case evidence$"):
                ci_summary.parse_summary(json.dumps(changed))
        for mutation, message in (("not a list", "invalid strict case evidence"),
                ("duplicate", "invalid or duplicate strict case evidence"),
                ("non-strict", "invalid or duplicate strict case evidence"),
                ("extra field", "strict case evidence: expected fields")):
            changed = copy.deepcopy(yellow)
            if mutation == "not a list":
                changed["strict_case_evidence"] = None
            elif mutation == "duplicate":
                changed["strict_case_evidence"].append(copy.deepcopy(changed["strict_case_evidence"][0]))
            elif mutation == "non-strict":
                changed["strict_case_evidence"][0]["identity"] = ci_summary.test_identity("host", "other")
            else:
                changed["strict_case_evidence"][0]["extra"] = True
            with self.subTest(case_evidence=mutation), self.assertRaisesRegex(ci_summary.ContractError, "^" + message):
                ci_summary.parse_summary(json.dumps(changed))
        private = copy.deepcopy(yellow)
        private["population"]["observed"][0]["environment_limit"]["private"] = "forbidden"
        with self.assertRaisesRegex(ci_summary.ContractError, "^environment limit: expected fields"):
            scan_diagnostic_json(json.dumps(private).encode())
        for path, value, prefix in ((('schema_version',), True, "environment limit: hosted evidence required"),
                (('policy_version',), 999, "environment limit: unsupported policy version"),
                (('policy_version',), 4, "environment limit: unsupported policy version"),
                (('policy_version',), True, "environment limit: unsupported policy version"),
                (('policy_version',), 3.0, "environment limit: unsupported policy version"),
                (('runner_hosted',), False, "environment limit: hosted evidence required"),
                (('failure', 'step'), 'unknown', "environment limit: failure is not an eligible timing wait"),
                (('resources', 'failure_samples'), [], "environment limit: insufficient starvation evidence")):
            changed = copy.deepcopy(yellow)
            target = changed["population"]["observed"][0]["environment_limit"]
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(path=path, value=value), self.assertRaisesRegex(ci_summary.ContractError, "^" + prefix):
                ci_summary.parse_summary(json.dumps(changed))
        for mutation in ("local", "ui", "mismatched", "passed", "orphan attempt"):
            changed = copy.deepcopy(yellow)
            if mutation == "local":
                changed["source"]["event"] = "local"
            elif mutation == "ui":
                changed["run"]["tier"] = "ui"
            elif mutation == "mismatched":
                changed["population"]["observed"][0]["attempts"][0].pop("environment_limit")
            elif mutation == "orphan attempt":
                changed["population"]["observed"][0].pop("environment_limit")
            else:
                changed["population"]["observed"][0]["outcome"] = "passed"
            message = {"local": "source/identity mismatch", "ui": "environment limit differs from scoped first failure evidence",
                "mismatched": "environment limit requires one matching failed strict attempt",
                "passed": "environment limit requires one matching failed strict attempt",
                "orphan attempt": "environment limit attempt requires observation evidence"}[mutation]
            with self.subTest(mutation=mutation), self.assertRaisesRegex(ci_summary.ContractError, "^" + message + "$"):
                ci_summary.parse_summary(json.dumps(changed))
        summary = archive_download_summary()
        summary.pop("archive_download")
        identity = summary["population"]["declared"][0]
        failed = ci_summary.observation(identity, "failed", 1, exit_code=65)
        failed["first_failure"] = failed["attempts"][0]["first_failure"] = first_failure_receipt(native=True)
        summary["population"]["observed"] = [failed]
        summary["status"] = "failed"
        with tempfile.TemporaryDirectory() as directory:
            ci_summary.write_summary(summary, Path(directory))
            read = ci_summary.parse_summary((Path(directory) / "summary.json").read_text())
        self.assertEqual(read["population"]["observed"], [failed])
        self.assertIn("query-element", ci_summary.render_markdown(read))
        self.assertIn("post=23.05s", ci_summary.render_markdown(read))
        self.assertIn("ax=unavailable", ci_summary.render_markdown(read))
        from ci_flaky import merge_retry
        second = ci_summary.observation(identity, "failed", 2, exit_code=65)
        later_receipt = first_failure_receipt()
        later_receipt["step"] = "capture-frame"
        second["first_failure"] = second["attempts"][0]["first_failure"] = later_receipt
        merged = merge_retry(failed, second)
        self.assertEqual("failed", merged["outcome"])
        self.assertEqual(failed["first_failure"], merged["first_failure"])
        self.assertEqual(later_receipt, merged["attempts"][1]["first_failure"])
        changed = copy.deepcopy(merged)
        changed["first_failure"] = later_receipt
        with self.assertRaisesRegex(ci_summary.ContractError, "^first failure must match the first failing attempt$"):
            ci_summary.validate_observation(changed)
        # Existing retry semantics retain the first receipt, without attaching it to the passing attempt.
        failed.update(outcome="flaky-passed", duration_seconds=2)
        failed["attempts"].append({**ci_summary.observation(identity, "passed", 1)["attempts"][0], "number": 2})
        summary["status"] = "passed"
        self.assertEqual(ci_summary.parse_summary(json.dumps(summary)), summary)
        failed["first_failure"]["timing"]["deadline_seconds"] = 6
        with self.assertRaisesRegex(ci_summary.ContractError, "^first failure must match the first failing attempt$"):
            # Break aliasing to change only the observation receipt.
            changed = copy.deepcopy(summary)
            changed["population"]["observed"][0]["attempts"][0]["first_failure"] = first_failure_receipt()
            ci_summary.parse_summary(json.dumps(changed))

    def test_first_failure_rejects_one_private_unbounded_or_misbound_field(self):
        summary = archive_download_summary()
        summary.pop("archive_download")
        identity = summary["population"]["declared"][0]
        item = ci_summary.observation(identity, "failed", 1, exit_code=65)
        item["first_failure"] = item["attempts"][0]["first_failure"] = first_failure_receipt(native=True)
        summary["population"]["observed"] = [item]
        summary["status"] = "failed"
        cases = [
            (("raw_assertion",), "private", "first failure: invalid fields"),
            (("schema_version",), True, "first failure: unsupported version"),
            (("source",), "private-server", "first failure: invalid source"),
            (("step",), "raw assertion", "first failure: invalid step"),
            (("element",), "album.private-id", "first failure: invalid element"),
            (("action",), "https://private.invalid", "first failure: invalid action"),
            (("native_activity_seconds",), {}, "first failure native activity: invalid fields"),
            (("native_activity_seconds", "title"), "private", "first failure native activity: invalid fields"),
            (("timing", "deadline_seconds"), True, "first failure timing: invalid number"),
            (("timing", "wait_elapsed_seconds"), float("inf"), "first failure timing: invalid number"),
            (("timing", "deadline_seconds"), 86401, "first failure timing: invalid number"),
            (("timing", "state_age_seconds"), -1, "first failure timing: invalid number"),
            (("timing",), {}, "first failure timing: invalid fields"),
            (("timing", "capture_return_seconds"), 0, "first failure: capture times out of order"),
            (("timing", "since_action_returned_seconds"), 9, "first failure: action times out of order"),
            (("state", "app"), "private", "first failure: invalid app state"),
            (("state", "surface"), "private", "first failure: invalid surface"),
            (("state", "observation"), "private", "first failure: invalid state observation"),
            (("state", "control_bar"), True, "first failure: invalid control bar"),
            (("state", "focus"), "private-focus", "first failure: invalid focus"),
            (("state", "history_count"), 2**31, "first failure state: invalid number"),
            (("state", "history_count"), 3.5, "first failure state: invalid number"),
            (("state", "autoplay"), True, "first failure: invalid autoplay"),
            (("state", "orientation"), "private", "first failure: invalid orientation"),
            (("state", "scene_status"), "asset-private", "first failure: invalid scene status"),
            (("state", "query_error_code"), -(2**31)-1, "first failure state: invalid number"),
            (("state", "raw_probe"), "layerIDs=private", "first failure state: invalid fields"),
            (("screenshot", "width"), 1537, "first failure screenshot: invalid number"),
            (("screenshot", "status"), "private", "first failure: invalid screenshot status"),
            (("screenshot", "height"), None, "first failure: screenshot measurements do not match status"),
            (("screenshot", "status"), "validated-input", "first failure: validated input requires validator source"),
            (("screenshot", "bytes"), 1048577, "first failure screenshot: invalid number"),
            (("screenshot", "path"), "/tmp/private.png", "first failure screenshot: invalid fields"),
            (("validator",), {"kind": "raw error", "slot": None, "axis": "unknown"}, "first failure: invalid validator kind"),
            (("validator",), {"kind": "glyph", "slot": None, "axis": "private"}, "first failure: invalid validator axis"),
            (("validator",), {"kind": "glyph", "slot": 0, "axis": "unknown"}, "first failure validator: invalid number"),
            (("validator",), {}, "first failure validator: invalid fields"),
            (("validator",), {"kind": "glyph", "slot": None, "axis": "unknown"},
                "first failure: validator context requires validator source"),
            (("state", "surface"), "firstboot", "first failure: screenshot is not an allowed app window"),
            (("state", "app"), "background", "first failure: screenshot is not an allowed app window"),
            (("source",), "validator", "first failure: screenshot is not an allowed app window"),
            (("element",), "firstboot.serverURL.field", "first failure: screenshot is not an allowed app window"),
            (("state", "focus"), "firstboot.apiKey.field", "first failure: screenshot is not an allowed app window"),
        ]
        for key in ("pre_event_idle", "find_window", "synthesize_event", "post_event_idle", "ax_root_acquisition"):
            for invalid in (-1, True, float("nan"), float("inf"), 86401, "private-title"):
                cases.append((("native_activity_seconds", key), invalid, "first failure native activity: invalid number"))
        self.assertEqual(ci_summary.parse_summary(summary), summary)
        for path, value, message in cases:
            changed = copy.deepcopy(summary)
            # Keep the two receipts equal; each negative changes one receipt field only.
            for receipt in (changed["population"]["observed"][0]["first_failure"],
                            changed["population"]["observed"][0]["attempts"][0]["first_failure"]):
                target = receipt
                for component in path[:-1]:
                    target = target[component]
                target[path[-1]] = value
            with self.subTest(path=path):
                with self.assertRaisesRegex(ci_summary.ContractError, "^" + message + "$") as error:
                    ci_summary.parse_summary(changed)
                self.assertNotIn("private", str(error.exception))
        for level in ("observation", "attempt"):
            changed = copy.deepcopy(summary)
            target = changed["population"]["observed"][0]
            if level == "attempt":
                target = target["attempts"][0]
            target["outcome"] = "passed"
            with self.subTest(level=level), self.assertRaisesRegex(ci_summary.ContractError,
                    "^first failure requires a failing strict or UI " + level + "$"):
                ci_summary.parse_summary(changed)
        for kind in ("host", "swift"):
            changed = copy.deepcopy(summary)
            changed["population"]["observed"][0]["identity"]["kind"] = kind
            with self.subTest(kind=kind), self.assertRaisesRegex(ci_summary.ContractError,
                    "^first failure requires a failing strict or UI observation$"):
                ci_summary.parse_summary(changed)

    def test_first_failure_supports_unavailable_preparation_validator_and_scoped_ui_records(self):
        receipt = first_failure_receipt()
        receipt.update(source="preparation", step="simulator-boot", element="simulator", action="none")
        receipt["timing"] = dict.fromkeys(receipt["timing"])
        receipt["timing"].update(wait_elapsed_seconds=60.2, deadline_seconds=60)
        receipt["state"].update(app="unknown", observation="unavailable", history_count=None,
            surface="unknown", control_bar="unknown", focus="unknown", autoplay="unknown", orientation="unknown", scene_status="unknown")
        receipt["screenshot"] = {"status": "not-applicable", "width": None, "height": None, "bytes": None}
        summary = archive_download_summary()
        summary.pop("archive_download")
        identity = summary["population"]["declared"][0]
        failed = ci_summary.observation(identity, "not-run", 0, exit_code=124)
        failed["first_failure"] = failed["attempts"][0]["first_failure"] = receipt
        summary["population"].update(observed=[failed], compiled=[])
        summary["status"] = "failed"
        self.assertEqual(ci_summary.parse_summary(json.dumps(summary)), summary)
        receipt["native_activity_seconds"] = first_failure_receipt(native=True)["native_activity_seconds"]
        with self.assertRaisesRegex(ci_summary.ContractError, "^first failure: native activity requires xctest source$"):
            ci_summary.parse_summary(summary)
        del receipt["native_activity_seconds"]
        changed = copy.deepcopy(summary)
        changed["population"]["observed"][0]["attempts"][0]["outcome"] = "failed"
        with self.assertRaisesRegex(ci_summary.ContractError, "^first failure source must match execution state$"):
            ci_summary.parse_summary(changed)
        for section, key, value in (("state", "app", "running-foreground"),
                ("state", "observation", "cached"), ("state", "history_count", 1),
                ("state", "surface", "playback"), ("state", "control_bar", "hidden"),
                ("state", "focus", "slideshow.hiddenWakeReceiver"), ("state", "autoplay", "off"),
                ("state", "orientation", "landscape"), ("state", "scene_status", "MATCH"),
                ("screenshot", "status", "unavailable")):
            changed = copy.deepcopy(summary)
            row = changed["population"]["observed"][0]
            for current in (row["first_failure"], row["attempts"][0]["first_failure"]):
                current[section][key] = value
            with self.subTest(section=section, key=key), self.assertRaisesRegex(ci_summary.ContractError,
                    "^first failure: preparation cannot claim app evidence$"):
                ci_summary.parse_summary(changed)
        scoped = discovery_summary()
        receipt = first_failure_receipt()
        item = scoped["population"]["observed"][0]
        item["outcome"] = item["attempts"][0]["outcome"] = scoped["status"] = "failed"
        item["attempts"][0]["exit_code"] = scoped["compiled_evidence"]["first_exit_code"] = 65
        item["first_failure"] = item["attempts"][0]["first_failure"] = receipt
        scoped["compiled_evidence"]["official_tests"]["testNodes"][0]["children"][0]["result"] = "Failed"
        refresh_discovery_hash(scoped)
        self.assertEqual(ci_summary.parse_summary(json.dumps(scoped)), scoped)
        receipt.update(source="validator", validator={"kind": "glyph", "slot": 2, "axis": "vertical"})
        receipt["screenshot"]["status"] = "validated-input"
        self.assertEqual(ci_summary.parse_summary(json.dumps(scoped)), scoped)
        receipt["native_activity_seconds"] = first_failure_receipt(native=True)["native_activity_seconds"]
        with self.assertRaisesRegex(ci_summary.ContractError, "^first failure: native activity requires xctest source$"):
            ci_summary.parse_summary(scoped)
        del receipt["native_activity_seconds"]
        receipt["state"]["observation"] = "failure-snapshot"
        with self.assertRaisesRegex(ci_summary.ContractError, "^first failure: validator cannot claim a failure snapshot$"):
            ci_summary.parse_summary(scoped)

    def test_first_failure_scanner_and_ui_upload_reject_invalid_receipts_and_media(self):
        import io
        from PIL import Image
        from ci_ui_tests import main as ui_main
        from run_strict_e2e import CommandError, write_sensitive_scan
        receipt = first_failure_receipt(native=True)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            picture = io.BytesIO()
            Image.new("RGB", (320, 180), "blue").save(picture, format="PNG")
            receipt["screenshot"].update(width=320, height=180, bytes=len(picture.getvalue()))
            image_path = root / "failure-screenshots/first-failure-attempt-1/0.png"
            image_path.parent.mkdir(parents=True)
            image_path.write_bytes(picture.getvalue())
            path = root / "diagnostic.json"
            path.write_text(json.dumps({"nested": [{"first_failure": receipt}]}))
            summary = archive_download_summary()
            summary.pop("archive_download")
            identity = summary["population"]["declared"][0]
            failed = ci_summary.observation(identity, "failed", 1, exit_code=65)
            failed["first_failure"] = failed["attempts"][0]["first_failure"] = receipt
            summary["population"]["observed"] = [failed]
            summary["status"] = "failed"
            ci_summary.write_summary(summary, root)
            with patch("ci_ui_tests.output"):
                self.assertEqual(0, ui_main(["check-upload", "--output-dir", str(root)]))
            self.assertEqual("PASS", json.loads((root / "sensitive-scan.json").read_text())["result"])
            from contextlib import redirect_stderr
            extra = root / "failure-screenshots/legacy.png"
            for defect in ("dimensions", "metadata", "size"):
                supplied = io.BytesIO()
                if defect == "size":
                    import random
                    image = Image.frombytes("RGB", (1536, 1024), random.Random(0).randbytes(1536 * 1024 * 3))
                else:
                    image = Image.new("RGB", (2000, 100) if defect == "dimensions" else (320, 180), "blue")
                image.save(supplied, format="PNG", **({"icc_profile": b"PRIVATE_PROFILE"} if defect == "metadata" else {}))
                extra.write_bytes(supplied.getvalue())
                with self.subTest(defect=defect), patch("ci_ui_tests.output"), redirect_stderr(io.StringIO()) as errors:
                    self.assertEqual(1, ui_main(["check-upload", "--output-dir", str(root)]))
                self.assertIn("first failure package image " + {"dimensions": "dimensions differ",
                    "metadata": "contains unsupported data", "size": "exceeds bound"}[defect], errors.getvalue())
                self.assertNotIn("PRIVATE_PROFILE", errors.getvalue())
            extra.unlink()
            for defect, message in (("missing-image", "nonregular first failure package input"),
                    ("symlink-image", "nonregular first failure package input"),
                    ("symlink-directory", "invalid first failure package directory"),
                    ("foreign-directory", "invalid first failure package directory"),
                    ("extra-file", "unexpected first failure package content")):
                held = root / "held"
                foreign = root / "failure-screenshots/first-failure-attempt-2"
                if defect in {"missing-image", "symlink-image"}:
                    image_path.rename(held)
                    if defect == "symlink-image":
                        image_path.symlink_to(held)
                elif defect == "symlink-directory":
                    image_path.parent.rename(held)
                    image_path.parent.symlink_to(held, target_is_directory=True)
                elif defect == "foreign-directory":
                    foreign.mkdir()
                else:
                    (image_path.parent / "unexpected.txt").write_text("public")
                try:
                    with self.subTest(defect=defect), patch("ci_ui_tests.output"), redirect_stderr(io.StringIO()) as errors:
                        self.assertEqual(1, ui_main(["check-upload", "--output-dir", str(root)]))
                    self.assertIn(message, errors.getvalue())
                finally:
                    if defect in {"missing-image", "symlink-image"}:
                        image_path.unlink(missing_ok=True)
                        held.rename(image_path)
                    elif defect == "symlink-directory":
                        image_path.parent.unlink()
                        held.rename(image_path.parent)
                    elif defect == "foreign-directory":
                        foreign.rmdir()
                    else:
                        (image_path.parent / "unexpected.txt").unlink()
            for raw in ('{"first_failure":' + json.dumps(receipt).replace('"source": "xctest"',
                        '"source": "private", "source": "xctest"') + '}',
                        '{"first_failure":', '{"first_\\u0066ailure":',
                        '{"first_failure":' + json.dumps(receipt).replace('"post_event_idle": 23.05',
                            '"post_event_idle": 1, "post_event_idle": 23.05') + '}',
                        json.dumps({"first_failure": {**receipt, "element": "private-id"}})):
                path.write_text(raw)
                with self.subTest(raw=raw[:40]), self.assertRaisesRegex(CommandError,
                        "^The evidence redaction scan found API Key values or invalid public failure diagnostics:"):
                    write_sensitive_scan(root, ["synthetic-secret"])

    def test_bounded_diagnostic_scanner_refuses_nested_private_duplicate_and_broken_receipts(self):
        from ci_failure_diagnostics import scan_diagnostic_json
        receipt = bounded_diagnostics_receipt(resources=True)
        safe = json.dumps({"nested": [{"bounded_diagnostics": receipt}]})
        scan_diagnostic_json(safe.encode())
        private = copy.deepcopy(receipt)
        private["events"][0]["sample"]["processes"][0]["name"] = "private-application"
        for raw, message in ((json.dumps({"nested": [{"bounded_diagnostics": private}]}),
                              "bounded diagnostic process: invalid name"),
                             ('{"bounded_diagnostics":' + json.dumps(receipt) + ',"bounded_diagnostics":' + json.dumps(receipt) + '}',
                              "duplicate failure diagnostic field"),
                             ('{"bounded_diagnostics":' + json.dumps(receipt).replace('"scope": "preparation"',
                                 '"scope": "private-scope", "scope": "preparation"', 1) + '}',
                              "duplicate bounded diagnostic JSON key"),
                             ('{"bounded_diagnostics":' + json.dumps(receipt).replace('"app": 120',
                                 '"app": 1, "app": 120') + '}', "duplicate bounded diagnostic JSON key"),
                             ('{"bounded_diagnostics":', "invalid failure diagnostic JSON"),
                             ('{"bounde\\u0064_diagnostics":', "invalid failure diagnostic JSON")):
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValueError, "^" + re.escape(message) + "$") as raised:
                    scan_diagnostic_json(raw.encode())
                self.assertNotIn("private-", str(raised.exception))

    def test_bounded_diagnostics_round_trip_preserves_failure_and_not_run_accounting(self):
        from ci_failure_diagnostics import scan_diagnostic_json
        summary = archive_download_summary()
        summary.pop("archive_download")
        summary["status"] = "failed"
        case = summary["population"]["declared"][0]
        summary["population"].update(compiled=[], observed=[ci_summary.observation(case, "not-run", 0, exit_code=None)])
        summary["infrastructure"] = [{"code": "simulator-preparation-failed", "message": "Preparation failed"}]
        summary["bounded_diagnostics"] = bounded_diagnostics_receipt(resources=True)
        with tempfile.TemporaryDirectory() as directory:
            ci_summary.write_summary(summary, Path(directory))
            data = Path(directory, "summary.json").read_bytes()
            self.assertEqual(ci_summary.parse_summary(data.decode()), summary)
            scan_diagnostic_json(data)
            rendered = Path(directory, "summary.md").read_text()
            self.assertIn("Bounded diagnostics (measurements only)", rendered)
            for detail in ("preparation=0.1 s", "xcode=0.2 s", "fixture=0.01 s", "events=4", "truncated=no",
                           "Last retained phase", "simulator-readiness/timeout", "test-execution/before-kill", "image-generation/started"):
                self.assertIn(detail, rendered)
            self.assertNotIn("(over budget)", rendered)
            self.assertIn("Case resources 4 (measurements only)", rendered)
            self.assertIn("idle min/median=10/30%", rendered)
            self.assertIn("sampler wall/cpu=0.06/0.03s", rendered)

            marker = {"scope": "xcode", "phase": "test-execution", "state": "started", "sequence": 5,
                "elapsed_seconds": 0, "cpu_seconds": None, "input_sha256": None, "official_exports": None,
                "sample": {"runner_hosted": True, "cpu_percent": None, "memory_free_bytes": None,
                           "load_average": None, "image_version": None, "processes": []}}
            summary["bounded_diagnostics"]["events"].append(marker)
            self.assertEqual(rendered.replace("events=4", "events=5"), ci_summary.render_markdown(summary))
            summary["bounded_diagnostics"]["events"].pop()

        summary["bounded_diagnostics"]["events"][0]["phase"] = "simulator-preparation"
        self.assertEqual(ci_summary.parse_summary(summary), summary)
        self.assertIn("simulator-preparation/timeout", ci_summary.render_markdown(summary))
        summary["bounded_diagnostics"]["events"][3]["phase"] = "fixture-generation"
        self.assertEqual(ci_summary.parse_summary(summary), summary)
        summary["bounded_diagnostics"]["events"] = []
        self.assertIn("Last retained phase: none", ci_summary.render_markdown(summary))

    def test_bounded_diagnostics_retains_over_budget_and_unavailable_collection_times(self):
        for measurements, details in (({"preparation": 5.001, "xcode": 10.001, "fixture": 2.001},
                                      ("preparation=5.001 s (over budget)", "xcode=10.001 s (over budget)",
                                       "fixture=2.001 s (over budget)")),
                                     ({"preparation": None, "xcode": None, "fixture": None},
                                      ("preparation=unavailable", "xcode=unavailable", "fixture=unavailable")),
                                     ({"preparation": 5, "xcode": 10, "fixture": 2},
                                      ("preparation=5 s", "xcode=10 s", "fixture=2 s"))):
            with self.subTest(measurements=measurements):
                summary = valid_summary()
                summary["bounded_diagnostics"] = bounded_diagnostics_receipt()
                summary["bounded_diagnostics"]["collection_seconds"] = measurements
                self.assertEqual(ci_summary.parse_summary(summary), summary)
                rendered = ci_summary.render_markdown(summary)
                for detail in details:
                    self.assertIn(detail, rendered)
                if measurements == {"preparation": 5, "xcode": 10, "fixture": 2}:
                    self.assertNotIn("(over budget)", rendered)

    def test_bounded_diagnostics_accepts_missing_sample_statistics_and_empty_processes(self):
        for processes in ([{"name": "simctl", "state": "unknown", "count": 1,
                            "cpu_percent": None, "rss_bytes": None}], []):
            with self.subTest(processes=processes):
                summary = valid_summary()
                summary["bounded_diagnostics"] = bounded_diagnostics_receipt()
                summary["bounded_diagnostics"]["events"][0]["sample"] = {
                    "cpu_percent": None, "memory_free_bytes": None, "load_average": None,
                    "runner_hosted": None, "image_version": None, "processes": processes}
                self.assertEqual(ci_summary.parse_summary(summary), summary)
                rendered = ci_summary.render_markdown(summary)
                diagnostics = rendered.partition("Bounded diagnostics (measurements only):")[2]
                self.assertIn("simulator-readiness/timeout", diagnostics)
                self.assertNotIn("None", diagnostics)
        summary = valid_summary()
        summary["bounded_diagnostics"] = bounded_diagnostics_receipt(resources=True)
        case = summary["bounded_diagnostics"]["case_resources"][0]
        for field in ("idle_percent_min", "idle_percent_median", "load_1m_max", "app_cpu_percent_peak",
                      "sampler_wall_seconds", "sampler_cpu_seconds"):
            case[field] = None
        sample = case["failure_samples"][0]
        sample.update(idle_percent=None, load_1m=None, cpu_percent=dict.fromkeys(sample["cpu_percent"]))
        self.assertEqual(ci_summary.parse_summary(summary), summary)
        self.assertIn("idle min/median=unavailable/unavailable%", ci_summary.render_markdown(summary))
        case.update(sample_count=0, first_failure_elapsed_seconds=None, failure_samples=[], truncated=True)
        self.assertEqual(ci_summary.parse_summary(summary), summary)
        summary["bounded_diagnostics"]["case_resources"] = []
        self.assertEqual(ci_summary.parse_summary(summary), summary)

    def test_bounded_diagnostics_rejects_single_private_or_unbounded_measurements(self):
        base = archive_download_summary()
        base.pop("archive_download")
        base["bounded_diagnostics"] = bounded_diagnostics_receipt(resources=True)
        receipt = ("bounded_diagnostics",)
        event = (*receipt, "events", 0)
        sample = (*event, "sample")
        process = (*sample, "processes", 0)
        resources = (*receipt, "case_resources")
        case = (*resources, 0)
        near = (*case, "failure_samples", 0)
        mutations = [
            (receipt, None, "bounded diagnostics: invalid fields"),
            ((*receipt, "schema_version"), True, "bounded diagnostics: unsupported version"),
            ((*receipt, "collection_seconds"), {}, "bounded diagnostics collection: invalid fields"),
            ((*receipt, "collection_seconds", "preparation"), 86401, "bounded diagnostics preparation collection: invalid number"),
            ((*receipt, "collection_seconds", "xcode"), 86401, "bounded diagnostics xcode collection: invalid number"),
            ((*receipt, "collection_seconds", "fixture"), 86401, "bounded diagnostics fixture collection: invalid number"),
            ((*receipt, "truncated"), 0, "bounded diagnostics: truncated must be boolean"),
            (resources, None, "case resources: invalid case count"),
            (resources, base["bounded_diagnostics"]["case_resources"] * 65, "case resources: invalid case count"),
            (resources, base["bounded_diagnostics"]["case_resources"] * 2, "case resources: duplicate sequence"),
            (case, {}, "case resources: invalid fields"),
            ((*case, "sequence"), True, "case resources sequence: invalid number"),
            ((*case, "sequence"), -1, "case resources sequence: invalid number"),
            ((*case, "sequence"), 0.5, "case resources sequence: invalid number"),
            ((*case, "sequence"), 2**31, "case resources sequence: invalid number"),
            ((*case, "sample_count"), 0.5, "case resources sample count: invalid number"),
            ((*case, "sample_count"), 43202, "case resources sample count: invalid number"),
            ((*case, "sample_count"), 0, "case resources: samples exceed count"),
            ((*case, "truncated"), 0, "case resources: truncated must be boolean"),
            ((*case, "idle_percent_min"), 31, "case resources: idle statistics out of order"),
            ((*case, "failure_samples"), {}, "case resources: invalid failure samples"),
            ((*case, "failure_samples"), [base["bounded_diagnostics"]["case_resources"][0]["failure_samples"][0]] * 7,
             "case resources: invalid failure samples"),
            (near, {}, "case resource sample: invalid fields"),
            ((*near, "elapsed_seconds"), 14, "case resources: sample outside failure window"),
            ((*near, "elapsed_seconds"), 2, "case resources: sample outside failure window"),
            ((*case, "first_failure_elapsed_seconds"), None, "case resources: sample outside failure window"),
            ((*near, "elapsed_seconds"), 13, "case resources: sample outside case"),
            ((*case, "sample_interval_seconds"), 0, "case resources interval: invalid number"),
            ((*case, "first_failure_elapsed_seconds"), 13, "case resources: failure outside case"),
            ((*near, "cpu_percent"), {"private-process": 10}, "case resource categories: invalid fields"),
            ((*case, "failure_samples"), [base["bounded_diagnostics"]["case_resources"][0]["failure_samples"][0]] * 2,
             "case resources: samples out of order"),
            ((*receipt, "events"), {}, "bounded diagnostics: invalid event count"),
            ((*receipt, "events"), base["bounded_diagnostics"]["events"] * 129, "bounded diagnostics: invalid event count"),
            (event, {}, "bounded diagnostic event: invalid fields"),
            ((*event, "scope"), "private-server", "bounded diagnostic event: invalid scope"),
            ((*event, "phase"), "private-command", "bounded diagnostic event: invalid phase"),
            ((*event, "phase"), "import", "bounded diagnostic event: invalid phase"),
            ((*event, "state"), "private-output", "bounded diagnostic event: invalid state"),
            ((*event, "sequence"), True, "bounded diagnostic sequence: invalid number"),
            ((*event, "sequence"), 0.5, "bounded diagnostic sequence: invalid number"),
            ((*event, "sequence"), 2**31, "bounded diagnostic sequence: invalid number"),
            ((*event, "input_sha256"), "e" * 64, "bounded diagnostic event: invalid public input hash"),
            ((*receipt, "events", 3, "input_sha256"), "private-input", "bounded diagnostic event: invalid public input hash"),
            ((*receipt, "events", 2, "input_sha256"), "e" * 64, "bounded diagnostic event: invalid public input hash"),
            ((*event, "official_exports"), {"bundle": True, "summary": False, "tests": False},
             "bounded diagnostic event: exports require xcode scope"),
            ((*receipt, "events", 1, "official_exports"), {}, "bounded diagnostic exports: invalid fields"),
            ((*receipt, "events", 1, "official_exports", "tests"), "private-path", "bounded diagnostic exports: invalid boolean"),
            (sample, {}, "bounded diagnostic sample: invalid fields"),
            ((*sample, "runner_hosted"), "private-environment", "bounded diagnostic sample: invalid runner flag"),
            ((*sample, "image_version"), "private-image", "bounded diagnostic image version: invalid vector"),
            ((*sample, "image_version", 0), True, "bounded diagnostic image component: invalid number"),
            ((*sample, "image_version", 0), 0.5, "bounded diagnostic image component: invalid number"),
            ((*sample, "image_version", 0), 2**31, "bounded diagnostic image component: invalid number"),
            ((*sample, "memory_free_bytes"), 0.5, "bounded diagnostic memory: invalid number"),
            ((*sample, "load_average"), [1, 2], "bounded diagnostic load: invalid vector"),
            ((*sample, "load_average", 0), -1, "bounded diagnostic load: invalid number"),
            ((*sample, "processes"), base["bounded_diagnostics"]["events"][0]["sample"]["processes"] * 65,
             "bounded diagnostic sample: invalid process count"),
            (process, {}, "bounded diagnostic process: invalid fields"),
            ((*process, "name"), "private-process", "bounded diagnostic process: invalid name"),
            ((*process, "state"), "private-state", "bounded diagnostic process: invalid state"),
            ((*process, "count"), 0, "bounded diagnostic process count: invalid number"),
            ((*process, "count"), 65537, "bounded diagnostic process count: invalid number"),
            ((*process, "rss_bytes"), 0.5, "bounded diagnostic process memory: invalid number"),
        ]
        for path, maximum, label in (
                ((*case, "duration_seconds"), 86400, "duration"),
                ((*case, "sample_interval_seconds"), 86400, "interval"),
                ((*case, "idle_percent_min"), 100, "idle"), ((*case, "idle_percent_median"), 100, "idle"),
                ((*case, "load_1m_max"), 10**6, "load"), ((*case, "app_cpu_percent_peak"), 10**6, "app cpu"),
                ((*case, "sampler_wall_seconds"), 86400, "wall cost"), ((*case, "sampler_cpu_seconds"), 10**12, "cpu cost"),
                ((*case, "first_failure_elapsed_seconds"), 86400, "failure time"),
                ((*near, "elapsed_seconds"), 86400, "sample time"), ((*near, "idle_percent"), 100, "sample idle"),
                ((*near, "load_1m"), 10**6, "sample load"),
                *(((*near, "cpu_percent", category), 10**6, "category cpu")
                  for category in ("app", "simulator_daemons", "test_tools", "other"))):
            for invalid in (-1, True, float("nan"), float("inf"), "private-statistic", maximum + 1):
                mutations.append((path, invalid, "case resources " + label + ": invalid number"))
        for field, maximum in (("elapsed_seconds", 86400), ("cpu_seconds", 10**12)):
            for invalid in (-1, True, float("nan"), float("inf"), "private-statistic", maximum + 1):
                mutations.append(((*event, field), invalid, "bounded diagnostic " + field + ": invalid number"))
        for path, maximum, label in ((*sample, "cpu_percent"), 100, "cpu"), ((*sample, "memory_free_bytes"), 2**50, "memory"), \
                ((*process, "cpu_percent"), 10**6, "process cpu"), ((*process, "rss_bytes"), 2**50, "process memory"):
            mutations.append((path, maximum + 1, "bounded diagnostic " + label + ": invalid number"))
        self.assertEqual(ci_summary.parse_summary(base), base)
        boundary = copy.deepcopy(base)
        boundary["bounded_diagnostics"].update(collection_seconds={"preparation": 86400, "xcode": 86400, "fixture": 86400},
                                              truncated=True, events=boundary["bounded_diagnostics"]["events"] * 128)
        boundary["bounded_diagnostics"]["events"][0]["sample"]["processes"] *= 64
        self.assertEqual(ci_summary.parse_summary(boundary), boundary)
        resources_boundary = copy.deepcopy(base)
        case_boundary = resources_boundary["bounded_diagnostics"]["case_resources"][0]
        case_boundary.update(duration_seconds=13, sample_count=43201)
        case_boundary["failure_samples"] = [{**copy.deepcopy(case_boundary["failure_samples"][0]), "elapsed_seconds": value}
                                            for value in (3, 5, 7, 9, 11, 13)]
        resources_boundary["bounded_diagnostics"]["case_resources"] = [
            {**copy.deepcopy(case_boundary), "sequence": sequence} for sequence in range(64)]
        self.assertEqual(ci_summary.parse_summary(resources_boundary), resources_boundary)
        case_boundary.update(sequence=2**31 - 1, first_failure_elapsed_seconds=case_boundary["duration_seconds"])
        case_boundary["failure_samples"] = [{**copy.deepcopy(case_boundary["failure_samples"][0]), "elapsed_seconds": 13}]
        resources_boundary["bounded_diagnostics"]["case_resources"] = [case_boundary]
        self.assertEqual(ci_summary.parse_summary(resources_boundary), resources_boundary)
        for path, value, message in mutations:
            changed = copy.deepcopy(base)
            target = changed
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(path=path, value=value):
                with self.assertRaisesRegex(ci_summary.ContractError, "^" + re.escape(message) + "$") as raised:
                    ci_summary.parse_summary(changed)
                self.assertNotIn("private-", str(raised.exception))

    def test_nightly_archive_receipt_accepts_historical_success_and_not_run_failures(self):
        summary = archive_download_summary()
        historical = {key: value for key, value in summary.items() if key != "archive_download"}
        self.assertEqual(ci_summary.parse_summary(historical), historical)
        self.assertEqual(ci_summary.parse_summary(json.dumps(summary)), summary)
        rendered = ci_summary.render_markdown(summary)
        for detail in ("Archive download: action=success", "manifest.json=100", "build.tar.gz=200",
                       "manifest digest=yes", "tar digest=yes", "size=yes", "transfer/extract=2.5 s",
                       "gate=0.1 s", "free disk=1000 bytes", "failure=none"):
            self.assertIn(detail, rendered)
        optional_measurements = copy.deepcopy(summary)
        optional_measurements["archive_download"].update(transfer_extract_seconds=None, gate_seconds=None, free_disk_bytes=None)
        with tempfile.TemporaryDirectory() as directory:
            ci_summary.write_summary(optional_measurements, Path(directory))
            self.assertEqual(ci_summary.parse_summary(Path(directory, "summary.json").read_text()), optional_measurements)
            for detail in ("transfer/extract=unavailable;", "gate=unavailable;", "free disk=unavailable;"):
                self.assertIn(detail, Path(directory, "summary.md").read_text())
        for reason in ("archive-member-missing",):
            failed = copy.deepcopy(summary)
            failed["status"] = "failed"
            failed["population"].update(compiled=[], observed=[ci_summary.observation(
                failed["population"]["declared"][0], "not-run", 0, reason=reason)])
            failed["infrastructure"] = [{"code": reason, "message": reason}]
            failed["archive_download"].update(failure_reason=reason, size_matched=None,
                member_bytes={"manifest.json": None, "build.tar.gz": None}, digests_matched={"manifest": None, "tar": None},
                transfer_extract_seconds=None, free_disk_bytes=None)
            with self.subTest(reason=reason):
                self.assertEqual(ci_summary.parse_summary(json.dumps(failed)), failed)
                self.assertIn("failure=" + reason, ci_summary.render_markdown(failed))
                self.assertIn("manifest.json=unavailable", ci_summary.render_markdown(failed))

    def test_nightly_archive_receipt_rejects_invalid_fields_and_false_success(self):
        from ci_ui_tests import MAX_ARCHIVE_BYTES
        import yaml
        base = archive_download_summary()
        self.assertEqual(ci_summary.parse_summary(base), base)
        workflow = yaml.safe_load(Path(ci_summary.__file__).resolve().parent.parent.joinpath(
            ".github/workflows/ci-nightly.yml").read_text())
        job_seconds = workflow["jobs"]["ui-shards"]["timeout-minutes"] * 60
        push_identity = {key: value for key, value in base["identity"].items() if key not in {"event", "commit_sha"}}
        push_identity.update(event="push", pushed_sha=base["identity"]["commit_sha"])
        for key, maximum in (("artifact_id", 2**63 - 1), ("free_disk_bytes", 2**50),
                             ("transfer_extract_seconds", job_seconds), ("gate_seconds", job_seconds)):
            boundary = copy.deepcopy(base)
            boundary["archive_download"][key] = maximum
            self.assertEqual(ci_summary.parse_summary(boundary), boundary)
        boundary = copy.deepcopy(base)
        boundary["archive_download"]["member_bytes"]["build.tar.gz"] = MAX_ARCHIVE_BYTES
        self.assertEqual(ci_summary.parse_summary(boundary), boundary)
        mutations = [
            (("archive_download",), None, "archive download receipt: expected fields " + str(sorted(base["archive_download"]))),
            (("archive_download", "schema_version"), True, "unsupported archive download receipt"),
            (("archive_download", "artifact_id"), True, "archive artifact ID: expected integer >= 1"),
            (("archive_download", "artifact_id"), 0, "archive artifact ID: expected integer >= 1"),
            (("archive_download", "artifact_id"), 2**63, "archive artifact ID exceeds bound"),
            (("identity",), push_identity, "archive download receipt requires a nightly UI shard"),
            (("source", "workflow_path"), ".github/workflows/ci-ui.yml", "archive download receipt requires a nightly UI shard"),
            (("run", "job"), "ui-other", "archive download receipt requires a nightly UI shard"),
            (("run", "tier"), "host", "archive download receipt requires a nightly UI shard"),
            (("run", "shard"), None, "archive download receipt requires a nightly UI shard"),
            (("archive_download", "action_outcome"), "warning", "invalid archive download action outcome"),
            (("archive_download", "failure_reason"), "private-server.example", "invalid archive download failure reason"),
            (("archive_download", "member_bytes"), {}, "archive member bytes: expected fields ['build.tar.gz', 'manifest.json']"),
            (("archive_download", "member_bytes", "build.tar.gz"), -1, "archive member bytes: expected integer >= 0"),
            (("archive_download", "member_bytes", "build.tar.gz"), MAX_ARCHIVE_BYTES + 1, "archive member bytes exceed bound"),
            (("archive_download", "digests_matched"), {}, "archive digest matches: expected fields ['manifest', 'tar']"),
            (("archive_download", "digests_matched", "tar"), "yes", "archive digest match must be boolean or null"),
            (("archive_download", "size_matched"), 1, "archive size match must be boolean or null"),
            (("archive_download", "transfer_extract_seconds"), -1, "duration must be finite and nonnegative"),
            (("archive_download", "gate_seconds"), float("inf"), "duration must be finite and nonnegative"),
            (("archive_download", "transfer_extract_seconds"), job_seconds + 1, "archive elapsed seconds exceed bound"),
            (("archive_download", "gate_seconds"), job_seconds + 1, "archive elapsed seconds exceed bound"),
            (("archive_download", "free_disk_bytes"), True, "archive free disk bytes: expected integer >= 0"),
            (("archive_download", "free_disk_bytes"), 2**50 + 1, "archive free disk bytes exceed bound"),
            (("archive_download", "action_outcome"), "failure", "successful archive gate requires complete integrity checks"),
            (("archive_download", "member_bytes", "manifest.json"), 0, "successful archive gate requires complete integrity checks"),
            (("archive_download", "member_bytes", "manifest.json"), None, "successful archive gate requires complete integrity checks"),
            (("archive_download", "digests_matched", "manifest"), False, "successful archive gate requires complete integrity checks"),
            (("archive_download", "size_matched"), None, "successful archive gate requires complete integrity checks"),
        ]
        for path, value, message in mutations:
            summary = copy.deepcopy(base)
            target = summary
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            if path == ("identity",):
                # Keep the enclosing record valid so only the receipt's event scope is wrong.
                summary["source"]["event"] = value["event"]
                without_receipt = {key: value for key, value in summary.items() if key != "archive_download"}
                self.assertEqual(ci_summary.parse_summary(without_receipt), without_receipt)
            with self.subTest(path=path, value=value), self.assertRaisesRegex(ci_summary.ContractError, "^" + re.escape(message) + "$"):
                ci_summary.parse_summary(summary)

    def test_failed_archive_receipt_cannot_mask_execution_or_a_passing_producer(self):
        summary = archive_download_summary()
        summary["status"] = "failed"
        summary["archive_download"]["failure_reason"] = "archive-hash-mismatch"
        summary["archive_download"]["digests_matched"]["tar"] = False
        summary["infrastructure"] = [{"code": "archive-hash-mismatch", "message": "archive-hash-mismatch"}]
        case = summary["population"]["declared"][0]
        summary["population"].update(compiled=[], observed=[ci_summary.observation(case, "not-run", 0)])
        self.assertEqual(ci_summary.parse_summary(summary), summary)
        for change in ("status", "diagnostic", "compiled", "observation"):
            changed = copy.deepcopy(summary)
            if change == "status":
                changed["status"] = "passed"
            elif change == "diagnostic":
                changed["infrastructure"][0]["code"] = "ui-shard-preflight-failed"
            elif change == "compiled":
                changed["population"]["compiled"] = [case]
            else:
                changed["population"]["observed"] = [ci_summary.observation(case, "passed", 1)]
            with self.subTest(change=change), self.assertRaisesRegex(ci_summary.ContractError,
                    "^failed archive gate requires failed infrastructure and no executed or compiled tests$"):
                ci_summary.parse_summary(changed)

    def test_strict_validator_receipts_are_optional_bounded_and_fail_only(self):
        summary = valid_summary()
        case = ci_summary.test_identity("strict", "tvos-person", device="tv", configuration="Debug",
                                        suite="tvos-person", scenario="normal", fixture="a")
        failed = ci_summary.observation(case, "failed", 1, exit_code=2)
        summary["population"].update(declared=[case], compiled=[case], observed=[failed])
        summary["status"] = "failed"
        self.assertEqual(ci_summary.parse_summary(json.dumps(summary)), summary)
        message = "unreadable public glyph slot; slot 1 (horizontal); screenshot person-normal.png"
        boundary = ("no public glyph; screenshot person-normal.png" + "; context unresolved" * 16
                    + "; slot 1 (horizontal)" * 7)
        self.assertEqual(512, len(boundary))
        album_messages = ["unreadable public glyph slot: public photo colors are missing or mixed; "
                          f"vertical axis, 0 completed slots; horizontal axis, 0 completed slots; screenshot album-play-{index}.png"
                          for index in (1, 2, 3)]
        added_messages = [message.replace("person-normal.png", name + ".png") for name in
                          ("display-after", "person-normal-1", "person-nofaces-1", "vision-solo-1")]
        for value in (message, "unresolved", "[redacted validator failure]", boundary, *album_messages, *added_messages):
            failed["validator_failure_message"] = failed["attempts"][0]["validator_failure_message"] = value
            self.assertEqual(ci_summary.parse_summary(json.dumps(summary)), summary)
        for value, prefix in ((None, "validator failure message"), ("", "validator failure message"),
                              (boundary.replace("slot 1 (", "slot 10 (", 1), "validator failure message exceeds"),
                              (message.replace("person-normal.png", "private-name.png"), "validator failure message is not public"),
                              (message.replace("person-normal.png", "album-play-4.png"), "validator failure message is not public"),
                              (message.replace("person-normal.png", "album-play-0.png"), "validator failure message is not public"),
                              (message + "; server 192.0.2.1", "validator failure message is not public"),
                              *[(message.replace("person-normal.png", name + ".png"), "validator failure message is not public")
                                for name in ("display-after-1", "person-solo", "person-conflict-solo", "vision-solo",
                                             "vision-solo-0", "vision-solo-2", "vision-solo-1-private")]):
            with self.subTest(value=value):
                broken = copy.deepcopy(summary)
                broken["population"]["observed"][0]["validator_failure_message"] = value
                with self.assertRaisesRegex(ci_summary.ContractError, prefix) as raised:
                    ci_summary.parse_summary(json.dumps(broken))
                self.assertNotIn("private-name", str(raised.exception))
                self.assertNotIn("192.0.2.1", str(raised.exception))
        for level, change in (("observation", "kind"), ("observation", "outcome"),
                              ("attempt", "kind"), ("attempt", "outcome")):
            with self.subTest(level=level, change=change):
                broken = copy.deepcopy(summary)
                item = broken["population"]["observed"][0]
                item.pop("validator_failure_message")
                item["attempts"][0].pop("validator_failure_message")
                target = item if level == "observation" else item["attempts"][0]
                target["validator_failure_message"] = message
                if change == "kind":
                    item["identity"] = ci_summary.test_identity("host", "format")
                else:
                    target["outcome"] = "passed"
                with self.assertRaisesRegex(ci_summary.ContractError,
                        "validator failure message requires a failed strict " + level + "$"):
                    ci_summary.parse_summary(broken)

    def test_partitioned_python_execution_preserves_exact_discovery_and_runs_only_its_members(self):
        calls = []
        class Sample(unittest.TestCase):
            def test_linux(self):
                calls.append("linux")
                self.assertTrue(True)

            def test_macos(self):
                calls.append("macos")
                self.assertTrue(True)

        def suite():
            return unittest.defaultTestLoader.loadTestsFromTestCase(Sample)
        inventory = [ci_summary.test_identity("python", case.id()) for case in run_python_tests.test_cases(suite())]
        for index in (0, 1):
            selected = [inventory[index]]
            part = run_python_tests.partition_suite(suite(), {"inventory": inventory, "selected": selected})
            payload, code = run_python_tests.run_suite(part, io.StringIO())
            self.assertEqual((code, payload["compiled"]), (0, selected))
            self.assertEqual([entry["identity"] for entry in payload["observed"]], selected)
        self.assertEqual(calls, ["linux", "macos"])
        for manifest in ({"inventory": inventory[:-1], "selected": inventory[:-1]},
                         {"inventory": inventory + inventory[:1], "selected": inventory[:1]},
                         {"inventory": inventory, "selected": inventory + inventory[:1]}):
            with self.subTest(manifest=manifest), self.assertRaises(ci_summary.ContractError):
                run_python_tests.partition_suite(suite(), manifest)

    def test_scoped_official_discovery_requires_bound_complete_compiled_and_executed_population(self):
        summary = discovery_summary()
        self.assertEqual(ci_summary.parse_summary(json.dumps(summary)), summary)
        changes = (
            lambda value: value["compiled_evidence"].update(mode="unknown"),
            lambda value: value["compiled_evidence"].update(schema_version=True),
            lambda value: value["compiled_evidence"].update(first_exit_code=True),
            lambda value: value["compiled_evidence"]["run"].update(attempt=2),
            lambda value: value["compiled_evidence"]["identity"].update(head_sha="f" * 40),
            lambda value: value["compiled_evidence"].update(plan_sha256="f" * 64),
            lambda value: value["compiled_evidence"].update(first_exit_code=65),
            lambda value: value["compiled_evidence"]["official_tests"]["devices"][0].update(modelName="iPad Pro"),
            lambda value: value["compiled_evidence"]["official_tests"]["devices"][0].update(deviceId="other"),
            lambda value: value["compiled_evidence"]["official_tests"]["testNodes"][0].update(children=[]),
            lambda value: value["compiled_evidence"]["official_tests"]["testNodes"][0].update(name="immichSlidesTests"),
            lambda value: value["population"].update(compiled=[]),
            lambda value: value["population"].update(observed=[]),
        )
        for mutate in changes:
            bad = copy.deepcopy(summary)
            mutate(bad)
            refresh_discovery_hash(bad)
            with self.subTest(mutate=mutate), self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_summary(bad)
        bad = copy.deepcopy(summary)
        bad["compiled_evidence"]["official_tests"]["testNodes"][0]["children"].append(
            copy.deepcopy(bad["compiled_evidence"]["official_tests"]["testNodes"][0]["children"][0]))
        refresh_discovery_hash(bad)
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(bad)
        from ci_ui_discovery import MAX_EXPORT_BYTES, MAX_EXPORT_DEPTH, MAX_EXPORT_NODES
        nested = None
        for _ in range(MAX_EXPORT_DEPTH + 1):
            nested = {"child": nested}
        for padding in ("x" * (MAX_EXPORT_BYTES + 1), [None] * (MAX_EXPORT_NODES + 1), nested):
            bad = copy.deepcopy(summary)
            bad["compiled_evidence"]["official_tests"]["padding"] = padding
            refresh_discovery_hash(bad)
            with self.subTest(padding_type=type(padding).__name__), self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_summary(bad)
        bad = copy.deepcopy(summary)
        bad["hashes"]["manifests"]["ui-discovery"] = "f" * 64
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(bad)
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / "summary.json"
            record.write_text(json.dumps(bad))
            result = subprocess.run([sys.executable, str(Path(ci_summary.__file__)), str(record)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 1)
            self.assertTrue(result.stdout.startswith("FAIL:"), result)
            self.assertNotIn("Traceback", result.stderr)

    def test_incomplete_official_discovery_writes_fail_only_diagnostics_with_raw_first_exit(self):
        from run_fixture_ui_tests import write_fixture_summary
        missing = ci_summary.test_identity("ui", "SettingsUITests/testMissing", platform="ios", device="iphone")
        policy = {"schema_version": 1, "approval_records": [], "expected_skips": [], "deselections": []}
        for code, export in ((1, "partial"), (65, "partial-unread"), (65, "empty"), (124, "missing")):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                summary = discovery_summary()
                summary["status"] = "failed"
                summary["compiled_evidence"]["first_exit_code"] = code
                summary["population"]["declared"].append(missing)
                if export == "empty":
                    summary["compiled_evidence"]["official_tests"]["testNodes"][0]["children"] = []
                    summary["population"]["compiled"] = []
                    summary["population"]["observed"] = []
                elif export == "missing":
                    summary["compiled_evidence"]["official_tests"] = None
                    summary["population"]["compiled"] = []
                    summary["population"]["observed"] = []
                elif export == "partial-unread":
                    summary["population"]["compiled"] = []
                    summary["population"]["observed"] = []
                self.assertEqual(write_fixture_summary(summary, Path(directory)), code)
                saved = ci_summary.parse_summary((Path(directory) / "summary.json").read_text())
                undiscovered = [entry for entry in saved["population"]["observed"]
                                if entry["identity"] not in saved["population"]["compiled"]]
                self.assertTrue(undiscovered)
                self.assertEqual({entry["outcome"] for entry in undiscovered}, {"timed-out" if code == 124 else "not-run"})
                self.assertEqual({entry["attempts"][0]["exit_code"] for entry in undiscovered}, {code})
                verdict = ci_verdict.evaluate_population(saved, saved["population"]["declared"], policy, environment="fixture")
                self.assertEqual(verdict["status"], "failed")
                self.assertEqual(sorted(map(ci_summary.identity_key, verdict["missing_compiled"])),
                                 sorted(ci_summary.identity_key(entry["identity"]) for entry in undiscovered))
                def claim_missing_passed(value):
                    entry = value["population"]["observed"][-1]
                    entry["outcome"] = entry["attempts"][0]["outcome"] = "passed"
                    entry["attempts"][0]["exit_code"] = 0
                for mutate in (lambda value: value.update(status="passed"),
                               lambda value: value["compiled_evidence"].update(first_exit_code=0),
                               lambda value: value["population"]["compiled"].append(missing),
                               claim_missing_passed,
                               lambda value: value["population"]["observed"][-1]["attempts"][0].update(exit_code=0)):
                    bad = copy.deepcopy(saved)
                    mutate(bad)
                    refresh_discovery_hash(bad)
                    with self.subTest(mutate=mutate), self.assertRaises(ci_summary.ContractError):
                        ci_summary.parse_summary(bad)

    def test_official_discovery_cannot_cover_nightly_full_or_deselected_tests(self):
        for mutate in (lambda value: value["run"].update(shard="visual-a"),
                       lambda value: value["source"].update(workflow_path=".github/workflows/ci-nightly.yml"),
                       lambda value: value["population"]["deselected"].append({
                           "identity": value["population"]["declared"][0], "reason": "not runnable", "owning_tier": "nightly"})):
            bad = discovery_summary()
            mutate(bad)
            bad["compiled_evidence"]["run"] = dict(bad["run"])
            refresh_discovery_hash(bad)
            with self.subTest(mutate=mutate), self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_summary(bad)

    def test_official_discovery_retains_first_failure_raw_exit_and_expected_skip(self):
        for result, outcome, code in (("Failed", "failed", 65), ("Skipped", "skipped", 0)):
            summary = discovery_summary()
            summary['compiled_evidence']['first_exit_code'] = code
            case = summary['compiled_evidence']['official_tests']['testNodes'][0]['children'][0]
            case['result'] = result
            summary['population']['observed'] = [ci_summary.observation(summary['population']['declared'][0],
                outcome, 1, exit_code=code, reason='Official XCTest ' + result)]
            summary['status'] = 'failed' if code else 'passed'
            refresh_discovery_hash(summary)
            with self.subTest(result=result):
                self.assertEqual(ci_summary.parse_summary(summary), summary)
            def change_consistent_duration(value):
                observed = value['population']['observed'][0]
                observed['duration_seconds'] = observed['attempts'][0]['duration_seconds'] = 2
            for mutate in (lambda value: value['population']['observed'][0]['attempts'][0].update(exit_code=1),
                           change_consistent_duration,
                           lambda value: value['compiled_evidence'].update(first_exit_code=0 if code else 65)):
                bad = copy.deepcopy(summary)
                mutate(bad)
                refresh_discovery_hash(bad)
                with self.subTest(result=result, mutate=mutate), self.assertRaises(ci_summary.ContractError):
                    ci_summary.parse_summary(bad)

    def test_host_platform_parts_preserve_every_identity_once(self):
        from run_host_checks import MACOS_PYTHON_TESTS, host_partition
        population = [ci_summary.test_identity("host", name) for name, _ in run_host_checks.HOST_CHECKS]
        population += [ci_summary.test_identity("python", key) for key in MACOS_PYTHON_TESTS]
        population.append(ci_summary.test_identity("python", "test_example.ExampleTests.testPortable"))
        linux, macos = (host_partition(population, scope) for scope in ("linux", "macos"))
        key = ci_summary.identity_key
        self.assertFalse(set(map(key, linux)) & set(map(key, macos)))
        self.assertEqual(sorted(map(key, population)), sorted(map(key, linux + macos)))
        self.assertEqual({entry["key"] for entry in macos}, {"swift-format lint", *MACOS_PYTHON_TESTS})
        removed = [entry for entry in population if entry["key"] not in MACOS_PYTHON_TESTS]
        renamed = removed + [ci_summary.test_identity("python", "test_example.ExampleTests.testRenamedSwiftCase")]
        for entries in (removed, renamed):
            parts = [host_partition(entries, scope) for scope in ("linux", "macos")]
            self.assertEqual(sorted(map(key, entries)), sorted(map(key, parts[0] + parts[1])))
            self.assertEqual({entry["key"] for entry in parts[1]}, {"swift-format lint"})
        for entries, scope in ((population, "unknown"), (population + population[:1], "linux"),
                               ([entry for entry in population if entry["key"] != "workflow policy"], "linux")):
            with self.subTest(scope=scope), self.assertRaises(ci_summary.ContractError):
                host_partition(entries, scope)
        from ci_population import python_identities, python_sources
        python_identities(python_sources(Path(__file__).parent), macos_python_tests=MACOS_PYTHON_TESTS)
        macos_key = "test_example.ExampleTests.testMacOS"
        for decorator in ('skipUnless(sys.platform == "darwin", "macOS")',
                          'skipIf(sys.platform != "darwin", "macOS")',
                          'skipUnless("darwin" == sys.platform, "macOS")',
                          'skipIf(not (sys.platform == "darwin"), "macOS")',
                          'skipUnless(sys.platform in {"darwin"}, "macOS")',
                          'skipUnless(IS_MACOS, "macOS")'):
            sources = {"provider": 'import sys\nimport unittest as checks\n'
                       'IS_MACOS = sys.platform == "darwin"\n'
                       'class Cases:\n    @checks.' + decorator + '\n'
                       '    def testMacOS(self): pass\n',
                       "test_example": 'import unittest\nfrom provider import Cases\n'
                       'class ExampleTests(Cases, unittest.TestCase): pass\n'}
            with self.subTest(decorator=decorator):
                self.assertEqual(python_identities(sources, macos_python_tests={macos_key}),
                                 [ci_summary.test_identity("python", macos_key)])
                with self.assertRaisesRegex(ci_summary.ContractError, macos_key + ".*MACOS_PYTHON_TESTS"):
                    python_identities(sources, macos_python_tests=set())
        for decorator in ('skipUnless(sys.platform in {"darwin", "linux"}, "POSIX")',
                          'skipIf(sys.platform == "darwin", "non-macOS")'):
            portable = dict(sources, provider=sources["provider"].replace(
                'skipUnless(IS_MACOS, "macOS")', decorator))
            with self.subTest(portable=decorator):
                self.assertEqual(python_identities(portable, macos_python_tests=set()),
                                 [ci_summary.test_identity("python", macos_key)])

    def test_current_summary_round_trips_and_names_failures_in_markdown(self):
        summary = valid_summary()
        self.assertEqual(ci_summary.parse_summary(json.dumps(summary)), summary)
        summary["population"]["observed"][0] = ci_summary.observation(
            summary["population"]["declared"][0], "failed", 0.2, message="format exited 1", exit_code=1)
        summary["status"] = "failed"
        self.assertIn("format exited 1", ci_summary.render_markdown(ci_summary.parse_summary(summary)))
        from ci_unit_tests import judge_execution
        from run_offline_unit_tests import TestResultsSummary
        unit = valid_summary()
        skipped = ci_summary.observation(ci_summary.test_identity("swift", "immichSlidesTests/A/a()", platform="ios"),
                                         "skipped", 0, reason="Test skipped")
        proposed = {"schema_version": 1, "approval_records": [], "deselections": [], "expected_skips": [
            {"kind": "swift", "key_pattern": skipped["identity"]["key"], "dimensions": {"platform": "ios"},
             "tier": "unit", "environment": "hermetic", "reason": "Test skipped"}]}
        self.assertEqual(judge_execution(unit, {"A/a()"}, [skipped], TestResultsSummary(1, 0, 0, 1, "Passed"), 0, proposed), 0)
        diagnostics = [(code, category, "diagnostic detail") for code, category in
                       (("policy-proposed", "Policy"), ("population-invalid", "Population"),
                        ("coverage-failed", "Coverage"), ("step-timeout", "Infrastructure"))]
        diagnostics.append((unit["infrastructure"][0]["code"], "Policy", unit["infrastructure"][0]["message"]))
        for code, category, message in diagnostics:
            with self.subTest(code=code):
                summary["infrastructure"] = [{"code": code, "message": message}]
                markdown = ci_summary.render_markdown(summary)
                self.assertIn(f"{category}: {code}: {message}", markdown)
                if category != "Infrastructure":
                    self.assertNotIn("Infrastructure:", markdown)

    def test_malformed_or_unknown_contracts_are_rejected(self):
        changes = [
            ("schema_version", 99), ("schema_version", True), ("status", "green"),
            ("unexpected_field", 1), ("run.attempt", 0), ("run.attempt", True),
            ("source.repository", "other/repo"), ("source.event", "push"),
            ("hashes.policies.skip", "not-a-hash"), ("toolchain.signing_mode", "disabled"),
            ("population.observed.0.duration_seconds", -1),
            ("population.observed.0.attempts.0.duration_seconds", float("nan")),
            ("population.observed.0.outcome", "invented"),
            ("population.observed.0.attempts.0.number", 2),
        ]
        for path, value in changes:
            with self.subTest(path=path, value=value):
                summary = valid_summary()
                target = summary
                parts = path.split(".")
                for part in parts[:-1]:
                    target = target[int(part)] if isinstance(target, list) else target[part]
                target[parts[-1]] = value
                with self.assertRaises(ci_summary.ContractError):
                    ci_summary.parse_summary(summary)
        for raw in ('[]', '{', '{"schema_version":1,"schema_version":2}'):
            with self.subTest(raw=raw), self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_summary(raw)
        summary = valid_summary()
        del summary["population"]
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(summary)

    def test_explicit_successor_reader_is_required_before_producer_transition(self):
        summary = valid_summary()
        summary["schema_version"] = 2
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(summary)

        def successor(payload):
            normalized = copy.deepcopy(payload)
            normalized["schema_version"] = 1
            ci_summary.validate_summary_v1(normalized)

        with patch.dict(ci_summary.SUMMARY_READERS, {2: successor}):
            self.assertEqual(ci_summary.parse_summary(summary), summary)
            summary["run"]["attempt"] = 0
            with self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_summary(summary)

    def test_duplicate_identities_and_unexplained_skips_or_deselections_are_rejected(self):
        for collection in ("declared", "compiled", "observed"):
            with self.subTest(collection=collection):
                summary = valid_summary()
                summary["population"][collection] *= 2
                with self.assertRaises(ci_summary.ContractError):
                    ci_summary.parse_summary(summary)
        summary = valid_summary()
        entry = summary["population"]["observed"][0]
        entry["outcome"] = entry["attempts"][0]["outcome"] = "skipped"
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(summary)
        summary = valid_summary()
        summary["population"]["deselected"] = [{"identity": summary["population"]["declared"][0],
                                                "reason": "live only", "owning_tier": ""}]
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(summary)

    def test_strict_keys_and_retry_attempts_preserve_full_identity_and_outcomes(self):
        summary = valid_summary()
        identity = ci_summary.test_identity("strict", "playback", device="iphone", configuration="Release",
                                            suite="smoke", scenario="single", fixture="A")
        summary["population"]["declared"] = summary["population"]["compiled"] = [identity]
        entry = ci_summary.observation(identity, "failed", 1, exit_code=1)
        entry["attempts"].append({"number": 2, "outcome": "passed", "duration_seconds": 2,
                                  "exit_code": 0, "reason": None, "message": None})
        entry["outcome"] = "flaky-passed"
        entry["duration_seconds"] = 3
        summary["population"]["observed"] = [entry]
        ci_summary.parse_summary(summary)
        entry["outcome"] = "failed"
        entry["attempts"][1]["outcome"] = "skipped"
        entry["attempts"][1]["reason"] = "retry fixture unavailable"
        ci_summary.parse_summary(summary)
        del identity["dimensions"]["fixture"]
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_summary(summary)

    def test_ci_identity_schemas_fail_closed(self):
        pr = {"schema_version": 1, "event": "pull_request", "repository": "sudoHG/immichSlides",
              "pull_request": 86, "merge_sha": "a" * 40, "base_sha": "b" * 40,
              "head_sha": "c" * 40, "tree_sha": "d" * 40}
        push = {"schema_version": 1, "event": "push", "repository": "sudoHG/immichSlides",
                "ref": "refs/heads/main", "pushed_sha": "a" * 40, "tree_sha": "b" * 40}
        dispatch = {"schema_version": 1, "event": "workflow_dispatch", "repository": "sudoHG/immichSlides",
                    "ref": "refs/heads/feature", "commit_sha": "a" * 40, "tree_sha": "b" * 40}
        schedule = dict(dispatch, event="schedule", ref="refs/heads/main")
        for identity in (pr, push, dispatch, schedule):
            self.assertEqual(ci_summary.parse_identity(json.dumps(identity)), identity)
            for key in identity:
                broken = dict(identity)
                del broken[key]
                with self.subTest(event=identity["event"], key=key), self.assertRaises(ci_summary.ContractError):
                    ci_summary.parse_identity(broken)
        push["ref"] = "refs/heads/other"
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_identity(push)
        for ref in (None, "", "main", "refs/pull/120/merge"):
            with self.subTest(ref=ref), self.assertRaises(ci_summary.ContractError):
                ci_summary.parse_identity(dict(dispatch, ref=ref))
        with self.assertRaises(ci_summary.ContractError):
            ci_summary.parse_identity(dict(schedule, ref="refs/heads/feature"))


class HostResultTests(unittest.TestCase):
    def test_python_progress_names_a_slow_test_without_exporting_its_inputs(self):
        stream = io.StringIO()
        progress = run_python_tests.TestProgress(stream)
        progress.clock = lambda: 0.0
        progress.stopped = unittest.mock.Mock()
        progress.stopped.wait.side_effect = [False, True]

        class Sample(unittest.TestCase):
            def test_slow(self):
                private_input = "private test input must not appear"
                external = types.SimpleNamespace(f_code=types.SimpleNamespace(
                    co_filename="/private/local-config.py", co_name="private_dynamic_name"),
                    f_lineno=1, f_back=None)
                progress.clock = lambda: 120.0
                with tempfile.TemporaryDirectory() as raw:
                    linked = Path(raw) / "linked-scripts"
                    linked.symlink_to(Path(__file__).resolve().parent, target_is_directory=True)
                    def frame(name, path):
                        return types.SimpleNamespace(f_code=types.SimpleNamespace(
                            co_filename=str(path), co_name=name), f_lineno=1, f_back=external)
                    # A busy server can have more workers than the stack cap; put main last.
                    frames = {888: frame("monitor_should_be_excluded", __file__)}
                    frames.update({i: frame("background_worker", __file__) for i in range(10)})
                    frames[999] = frame("test_slow", linked / Path(__file__).name)
                    with self.subTest(input=private_input), \
                            patch.object(run_python_tests.threading, "main_thread", return_value=types.SimpleNamespace(ident=999)), \
                            patch.object(run_python_tests.threading, "get_ident", return_value=888), \
                            patch.object(run_python_tests.sys, "_current_frames", return_value=frames):
                        progress.watch()

        with patch.object(run_python_tests.os, "write") as write:
            payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Sample),
                                                       stream, progress=progress)
        self.assertEqual(0, code)
        key = payload["compiled"][0]["key"]
        self.assertIn("PYTHON START " + key + "\n", stream.getvalue())
        self.assertIn("PYTHON FINISH " + key + " passed 120.000s\n", stream.getvalue())
        write.assert_called_once()
        descriptor, raw = write.call_args.args
        self.assertEqual(2, descriptor)
        self.assertIn("PYTHON SLOW " + key + " 120.000s\n", raw.decode())
        self.assertRegex(raw.decode(), r"scripts/test_ci_summary\.py:\d+ in test_slow")
        self.assertEqual("  scripts/test_ci_summary.py:1 in test_slow", raw.decode().splitlines()[2])
        self.assertNotIn("monitor_should_be_excluded", raw.decode())
        self.assertEqual(8, raw.decode().count(" (innermost first):"))
        for private in ("private test input", "/private/", "private_dynamic_name"):
            self.assertNotIn(private, stream.getvalue() + raw.decode())

    def test_host_partitions_execute_the_complete_discovered_suite_once_and_keep_separate_records(self):
        python = [ci_summary.test_identity("python", "portable.Sample.test_rule"),
                  ci_summary.test_identity("python", next(iter(run_host_checks.MACOS_PYTHON_TESTS)))]
        records = []
        for scope in ("linux", "macos"):
            with self.subTest(scope=scope), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"
                def steps(commands, *args, **kwargs):
                    manifest = json.loads((output / "python-selection.json").read_text())
                    self.assertEqual(manifest["inventory"], python)
                    self.assertEqual(len(manifest["selected"]), 1)
                    (output / "python-results.json").write_text(json.dumps({"compiled": manifest["selected"],
                        "observed": [ci_summary.observation(entry, "passed", 1) for entry in manifest["selected"]]}))
                    invocation = next(command for name, command in commands if name == "python tests")
                    self.assertIn("--selection-path", invocation)
                    return [ci_summary.observation(ci_summary.test_identity("host", name), "passed", 0)
                            for name, command in commands], []
                with patch("sys.argv", ["run_host_checks.py", "--host-platform", scope, "--output-dir", str(output)]), \
                        patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                        patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                        patch("ci_population.python_identities", return_value=python), \
                        patch.object(run_host_checks, "run_steps", side_effect=steps), \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(run_host_checks.main(), 0)
                summary = ci_summary.parse_summary((output / "summary.json").read_text())
                self.assertEqual(summary["run"]["job"], "host-" + scope)
                self.assertEqual({ci_summary.identity_key(entry) for entry in summary["population"]["declared"]},
                                 {ci_summary.identity_key(entry) for entry in summary["population"]["compiled"]})
                self.assertEqual({ci_summary.identity_key(entry) for entry in summary["population"]["declared"]},
                                 {ci_summary.identity_key(entry["identity"]) for entry in summary["population"]["observed"]})
                records.extend(summary["population"]["declared"])
        self.assertEqual(len(records), len(run_host_checks.HOST_CHECKS) + len(python))
        self.assertEqual(len({ci_summary.identity_key(entry) for entry in records}), len(records))

    def test_local_repository_metadata_accepts_remote_forms_and_missing_origin(self):
        remotes = [
            ("https://github.com/sudoHG/immichSlides.git/", "sudoHG/immichSlides"),
            ("ssh://git@github.com/sudoHG/immichSlides.git", "sudoHG/immichSlides"),
            ("git@github-work:sudoHG/immichSlides/", "sudoHG/immichSlides"),
            ("/tmp/local-clone", None),
            (subprocess.CalledProcessError(2, ["git", "remote", "get-url", "origin"]), None),
        ]
        for remote, repository in remotes:
            with self.subTest(remote=remote):
                def answers(*args):
                    if args == ("remote", "get-url", "origin"):
                        if isinstance(remote, Exception):
                            raise remote
                        return remote
                    return {("rev-parse", "HEAD"): "a" * 40,
                            ("rev-parse", "HEAD^{tree}"): "b" * 40,
                            ("status", "--porcelain"): ""}[args]

                with patch.object(run_host_checks, "git", side_effect=answers):
                    # Ambient CI configuration must not switch a local caller into CI mode.
                    identity = run_host_checks.run_identity({"GITHUB_EVENT_NAME": "workflow_dispatch",
                                                             "GITHUB_REPOSITORY": "other/repo"})
                self.assertEqual(identity["event"], "local")
                self.assertEqual(identity["repository"], repository)
                summary = valid_summary()
                summary["identity"] = identity
                summary["source"]["repository"] = repository
                ci_summary.parse_summary(summary)
        with tempfile.TemporaryDirectory() as directory, \
                patch("sys.argv", ["run_host_checks.py", "--output-dir", directory]), \
                patch.object(run_host_checks, "git", side_effect=subprocess.CalledProcessError(128, ["git"])), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(run_host_checks.main(), 1)
        self.assertIn("Git metadata command failed", errors.getvalue())

    def test_ci_source_cross_checks_workflow_reference_and_handles_deleted_forks(self):
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            identity = {"event": "pull_request", "repository": "sudoHG/immichSlides"}
            workflow = ".github/workflows/ci-gate.yml"
            env = {"GITHUB_EVENT_PATH": str(event_path),
                   "GITHUB_WORKFLOW_REF": f"sudoHG/immichSlides/{workflow}@refs/pull/120/merge"}
            for repo, expected in (({"full_name": "sudoHG/immichSlides"}, False),
                                   ({"full_name": "contributor/immichSlides"}, True), (None, True)):
                with self.subTest(repo=repo):
                    event_path.write_text(json.dumps({"pull_request": {"head": {"repo": repo}}}))
                    self.assertEqual(run_host_checks.source_metadata(identity, env, workflow), (workflow, expected))
            for reference, requested in ((env["GITHUB_WORKFLOW_REF"], ".github/workflows/copied.yml"),
                                         ("other/repo/.github/workflows/ci-gate.yml@main", workflow),
                                         ("", workflow)):
                with self.subTest(reference=reference), self.assertRaises(ci_summary.ContractError):
                    run_host_checks.source_metadata(identity, dict(env, GITHUB_WORKFLOW_REF=reference), requested)

    def test_pr_identity_reads_checkout_parents_instead_of_event_claims(self):
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            event_path.write_text(json.dumps({"number": 86, "pull_request": {
                "base": {"sha": "0" * 40}, "head": {"sha": "0" * 40}}}))
            answers = {("rev-parse", "HEAD"): "a" * 40,
                       ("rev-parse", "HEAD^{tree}"): "d" * 40,
                       ("cat-file", "commit", "a" * 40): "tree " + "d" * 40 + "\nparent " + "b" * 40 +
                       "\nparent " + "c" * 40 + "\nauthor Contributor\n\nMerge message"}
            env = {"GITHUB_REPOSITORY": "sudoHG/immichSlides", "GITHUB_EVENT_NAME": "pull_request",
                   "GITHUB_SHA": "a" * 40, "GITHUB_EVENT_PATH": str(event_path)}
            with patch.object(run_host_checks, "git", side_effect=lambda *args: answers[args]):
                identity = run_host_checks.run_identity(env, ci=True)
                self.assertEqual((identity["base_sha"], identity["head_sha"]), ("b" * 40, "c" * 40))
                env["GITHUB_SHA"] = "0" * 40
                with self.assertRaises(ci_summary.ContractError):
                    run_host_checks.run_identity(env, ci=True)
                env["GITHUB_SHA"] = "a" * 40
                answers[("cat-file", "commit", "a" * 40)] = "parent " + "b" * 40 + "\n\nMerge message"
                with self.assertRaises(ci_summary.ContractError):
                    run_host_checks.run_identity(env, ci=True)
                for event, ref, field in (("push", "refs/heads/main", "pushed_sha"),
                                          ("schedule", "refs/heads/main", "commit_sha"),
                                          ("workflow_dispatch", "refs/heads/feature", "commit_sha")):
                    with self.subTest(event=event):
                        trigger = dict(env, GITHUB_EVENT_NAME=event, GITHUB_REF=ref)
                        identity = run_host_checks.run_identity(trigger, ci=True)
                        self.assertEqual((identity["event"], identity["ref"], identity[field]),
                                         (event, ref, "a" * 40))
                        with self.assertRaises(ci_summary.ContractError):
                            run_host_checks.run_identity(dict(trigger, GITHUB_SHA="0" * 40), ci=True)

    def test_python_failures_skips_subtests_and_empty_suites_never_report_success(self):
        class Sample(unittest.TestCase):
            def test_pass(self):
                self.assertTrue(True)

            def test_fail(self):
                self.fail("plain failure " + "x" * 240 + "\nsecond line must not be exported")

            def test_skip(self):
                self.skipTest("missing fixture")

            def test_subtest_skip(self):
                for fixture in ("A", "B"):
                    with self.subTest(fixture=fixture):
                        self.skipTest(f"missing fixture {fixture}")

            def test_mixed_subtests(self):
                with self.subTest(fixture="A"):
                    self.skipTest("fixture A unavailable")
                with self.subTest(fixture="B"):
                    self.fail("fixture B failed")

            @unittest.expectedFailure
            def test_unexpected_success(self):
                self.assertTrue(True)

        payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Sample), io.StringIO())
        self.assertEqual(code, 1)
        outcomes = {entry["identity"]["key"].rsplit(".", 1)[-1]: entry for entry in payload["observed"]}
        self.assertEqual(outcomes["test_fail"]["outcome"], "failed")
        message = outcomes["test_fail"]["attempts"][0]["message"]
        self.assertIn("AssertionError: plain failure", message)
        self.assertNotIn("second line", message)
        self.assertLessEqual(len(message.split("AssertionError: ", 1)[1]), 200)
        self.assertEqual(outcomes["test_pass"]["outcome"], "passed")
        self.assertEqual(outcomes["test_skip"]["attempts"][0]["reason"], "missing fixture")
        self.assertEqual(outcomes["test_unexpected_success"]["outcome"], "failed")
        self.assertEqual(outcomes["test_subtest_skip"]["outcome"], "skipped")
        reason = outcomes["test_subtest_skip"]["attempts"][0]["reason"]
        summary = valid_summary()
        summary["population"]["observed"] = [outcomes["test_subtest_skip"]]
        summary["status"] = "unverified"
        markdown = ci_summary.render_markdown(ci_summary.parse_summary(summary))
        for fixture in ("A", "B"):
            self.assertIn(f"missing fixture {fixture}", reason)
            self.assertIn(f"fixture='{fixture}'", reason)
            self.assertIn(f"missing fixture {fixture}", markdown)
        mixed = outcomes["test_mixed_subtests"]
        self.assertEqual(mixed["outcome"], "failed")
        summary["population"]["observed"] = [mixed]
        summary["status"] = "failed"
        markdown = ci_summary.render_markdown(ci_summary.parse_summary(summary))
        for detail in ("fixture A unavailable", "fixture='B'", "AssertionError", "fixture B failed"):
            self.assertIn(detail, markdown)
        self.assertEqual(len(payload["compiled"]), 6)
        empty, code = run_python_tests.run_suite(unittest.TestSuite(), io.StringIO())
        self.assertEqual(code, 1)
        self.assertEqual(empty["observed"], [])

    def test_expected_failures_return_failure_with_their_actual_reason(self):
        class Sample(unittest.TestCase):
            @unittest.expectedFailure
            def test_expected_failure(self):
                self.fail("known failure")

        payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Sample), io.StringIO())
        self.assertEqual(code, 1)
        entry = payload["observed"][0]
        self.assertEqual(entry["outcome"], "failed")
        self.assertIn("expected failure", entry["attempts"][0]["message"])
        self.assertIn("known failure", entry["attempts"][0]["message"])

    def test_python_class_setup_error_names_failure_and_accounts_for_missing_tests(self):
        for stage in ("setup", "teardown", "cleanups"):
            with self.subTest(stage=stage):
                class Sample(unittest.TestCase):
                    @classmethod
                    def setUpClass(cls):
                        def cleanup():
                            raise ValueError("class cleanup broken")
                        cls.addClassCleanup(cleanup)
                        if stage == "setup":
                            raise RuntimeError("fixture unavailable")
                        if stage == "cleanups":
                            def other_cleanup():
                                raise RuntimeError("fixture unavailable")
                            cls.addClassCleanup(other_cleanup)

                    @classmethod
                    def tearDownClass(cls):
                        if stage == "teardown":
                            raise RuntimeError("fixture unavailable")

                    def test_member(self):
                        self.assertTrue(True)

                payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Sample), io.StringIO())
                self.assertEqual(code, 1)
                self.assertEqual([entry["outcome"] for entry in payload["observed"]],
                                 ["failed", "not-run"] if stage == "setup" else ["passed", "failed"])
                failure = next(entry for entry in payload["observed"] if entry["outcome"] == "failed")
                self.assertIn("setUpClass" if stage == "setup" else "tearDownClass", failure["identity"]["key"])
                summary = valid_summary()
                summary["status"] = "failed"
                summary["population"].update(compiled=payload["compiled"], observed=payload["observed"])
                markdown = ci_summary.render_markdown(ci_summary.parse_summary(summary))
                for message in ("RuntimeError: fixture unavailable", "ValueError: class cleanup broken"):
                    self.assertIn(message, failure["attempts"][0]["message"])
                    self.assertIn(message, markdown)

    def test_python_fixture_skip_records_every_discovered_member_with_its_reason(self):
        class Sample(unittest.TestCase):
            def test_never_started(self):
                self.fail("must not run")

            def test_also_never_started(self):
                self.fail("must not run")

        def skip_fixture(*args):
            raise unittest.SkipTest("external calibration screenshots unavailable")

        class OtherSample(Sample):
            pass

        module = types.ModuleType("fixture_skip_regression")
        for scope in ("class", "module"):
            with self.subTest(scope=scope), patch.dict(sys.modules, {module.__name__: module}), \
                    patch.object(Sample, "__module__", module.__name__), \
                    patch.object(OtherSample, "__module__", module.__name__), \
                    patch.object(Sample, "setUpClass", classmethod(skip_fixture) if scope == "class" else classmethod(lambda cls: None)), \
                    patch.object(module, "setUpModule", skip_fixture if scope == "module" else lambda: None, create=True):
                suite = unittest.defaultTestLoader.loadTestsFromTestCase(Sample)
                if scope == "module":
                    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(OtherSample))
                payload, code = run_python_tests.run_suite(suite, io.StringIO())
                self.assertEqual(code, 0)
                self.assertEqual([entry["identity"] for entry in payload["observed"]], payload["compiled"])
                self.assertEqual([entry["outcome"] for entry in payload["observed"]],
                                 ["skipped"] * (2 if scope == "class" else 4))
                for entry in payload["observed"]:
                    self.assertEqual(entry["attempts"][0]["reason"], "external calibration screenshots unavailable")

        class SetupCleanupSample(unittest.TestCase):
            @classmethod
            def setUpClass(cls):
                cls.addClassCleanup(skip_fixture)
                raise unittest.SkipTest("setup fixture unavailable")

            def test_never_started(self):
                self.fail("must not run")

        payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(SetupCleanupSample), io.StringIO())
        self.assertEqual(code, 0)
        self.assertEqual([entry["identity"] for entry in payload["observed"]], payload["compiled"])
        reason = payload["observed"][0]["attempts"][0]["reason"]
        self.assertIn("setup fixture unavailable", reason)
        self.assertIn("external calibration screenshots unavailable", reason)

        class CleanupSample(unittest.TestCase):
            def test_pass(self):
                self.assertTrue(True)

        for fixture in ("tearDownClass", "tearDownModule"):
            with self.subTest(fixture=fixture), patch.dict(sys.modules, {module.__name__: module}), \
                    patch.object(CleanupSample, "__module__", module.__name__), \
                    patch.object(CleanupSample, "tearDownClass", classmethod(skip_fixture) if fixture == "tearDownClass" else classmethod(lambda cls: None)), \
                    patch.object(module, "tearDownModule", skip_fixture if fixture == "tearDownModule" else lambda: None, create=True):
                payload, code = run_python_tests.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(CleanupSample), io.StringIO())
                self.assertEqual(code, 0)
                self.assertEqual([entry["outcome"] for entry in payload["observed"]], ["passed", "skipped"])
                cleanup = payload["observed"][-1]
                self.assertTrue(cleanup["identity"]["key"].startswith(fixture + " ("))
                self.assertEqual(cleanup["attempts"][0]["reason"], "external calibration screenshots unavailable")
                summary = valid_summary()
                summary["status"] = "unverified"
                summary["population"].update(compiled=payload["compiled"], observed=payload["observed"])
                self.assertIn("external calibration screenshots unavailable",
                              ci_summary.render_markdown(ci_summary.parse_summary(summary)))

    def test_invalid_final_record_is_rewritten_failed_with_executed_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            identity = ci_summary.test_identity("python", "fixture.Sample.test_failure")
            failure = ci_summary.observation(identity, "failed", 0, message="assertion broken", exit_code=None)

            def steps(*args, **kwargs):
                (output / "python-results.json").write_text(json.dumps({"compiled": [identity], "observed": [failure, failure]}))
                return [ci_summary.observation(ci_summary.test_identity("host", name), "failed" if name == "python tests" else "passed", 0)
                        for name, _ in run_host_checks.HOST_CHECKS], []

            with patch("sys.argv", ["run_host_checks.py", "--output-dir", str(output)]), \
                    patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                    patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                    patch.object(run_host_checks, "run_steps", side_effect=steps), \
                    contextlib.redirect_stdout(io.StringIO()) as terminal, contextlib.redirect_stderr(io.StringIO()):
                code = run_host_checks.main()
            self.assertEqual(code, 1)
            summary = ci_summary.parse_summary((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertIn("record-invalid", [item["code"] for item in summary["infrastructure"]])
            self.assertEqual(len(summary["population"]["observed"]), len(run_host_checks.HOST_CHECKS) + 1)
            for name, _ in run_host_checks.HOST_CHECKS:
                self.assertIn(name, terminal.getvalue())
            self.assertIn(identity["key"], terminal.getvalue())

    def test_host_coverage_failures_are_distinct_from_infrastructure(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            identity = ci_summary.test_identity("python", "calibration.Sample.test_photo")

            def steps(*args, **kwargs):
                (output / "python-results.json").write_text(json.dumps({"compiled": [identity], "observed": [
                    ci_summary.observation(identity, "skipped", 0, reason="external screenshots unavailable", exit_code=None)]}))
                return [ci_summary.observation(ci_summary.test_identity("host", name), "passed", 0)
                        for name, _ in run_host_checks.HOST_CHECKS], []

            with patch("sys.argv", ["run_host_checks.py", "--output-dir", str(output)]), \
                    patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]) as identity_call, \
                    patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                    patch("ci_population.python_identities", return_value=[identity]), \
                    patch.object(run_host_checks, "run_steps", side_effect=steps), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = run_host_checks.main()
            self.assertEqual(code, 1)
            identity_call.assert_called_once_with(os.environ, ci=False)
            summary = ci_summary.parse_summary((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertEqual(summary["population"]["observed"][-1]["attempts"][0]["reason"], "external screenshots unavailable")
            self.assertEqual({item["code"] for item in summary["infrastructure"]}, {"coverage-failed"})
            self.assertTrue(all(identity["key"] in item["message"] for item in summary["infrastructure"]))
            markdown = ci_summary.render_markdown(summary)
            self.assertIn("Coverage: coverage-failed: skipped: " + identity["key"], markdown)
            self.assertNotIn("Infrastructure:", markdown)

    def test_host_policy_distinguishes_proposed_and_approved_expected_skips(self):
        identity = ci_summary.test_identity("python", "calibration.Sample.test_photo")
        parse_policy = ci_verdict.parse_policy
        for state, outcome in (("proposed", "unverified"), ("approved", "passed")):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"
                record = {"approver": "maintainer example", "date": "2026-10-08", "tier": "host",
                          "link": "https://github.com/example/project/issues/1#issuecomment-1"}
                policy = {"schema_version": 1, "approval_records": [record] if state == "approved" else [], "deselections": [],
                          "expected_skips": [{"kind": "python", "key_pattern": identity["key"], "dimensions": {},
                                              "tier": "host", "environment": "hermetic", "reason": "no fixture"}]}

                def steps(*args, **kwargs):
                    (output / "python-results.json").write_text(json.dumps({"compiled": [identity], "observed": [
                        ci_summary.observation(identity, "skipped", 0, reason="no fixture")]}))
                    return [ci_summary.observation(ci_summary.test_identity("host", name), "passed", 0)
                            for name, _ in run_host_checks.HOST_CHECKS], []

                with patch("sys.argv", ["run_host_checks.py", "--output-dir", str(output)]), \
                        patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                        patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                        patch("ci_population.python_identities", return_value=[identity]), \
                        patch("ci_verdict.parse_policy", side_effect=lambda raw: policy if isinstance(raw, str) else parse_policy(raw)), \
                        patch.object(run_host_checks, "run_steps", side_effect=steps), \
                        contextlib.redirect_stdout(io.StringIO()):
                    code = run_host_checks.main()
                self.assertEqual(code, 0)
                summary = ci_summary.parse_summary((output / "summary.json").read_text())
                self.assertEqual(summary["status"], outcome)
                self.assertEqual(summary["population"]["declared"][-1], identity)
                self.assertIn("test-policy", summary["hashes"]["policies"])

    def test_invalid_population_or_policy_still_writes_placeholder_and_runs_all_checks(self):
        for invalid in ("python_identities", "parse_policy"):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"

                def steps(commands, *args, **kwargs):
                    placeholder = ci_summary.parse_summary((output / "summary.json").read_text())
                    self.assertEqual(placeholder["status"], "unverified")
                    self.assertEqual(placeholder["population"]["observed"], [])
                    self.assertEqual([name for name, _ in commands], [name for name, _ in run_host_checks.HOST_CHECKS])
                    (output / "python-results.json").write_text(json.dumps({"compiled": [], "observed": []}))
                    return [ci_summary.observation(ci_summary.test_identity("host", name), "passed", 0)
                            for name, _ in commands], []

                with patch("sys.argv", ["run_host_checks.py", "--output-dir", str(output)]), \
                        patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                        patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                        patch(("ci_population." if invalid == "python_identities" else "ci_verdict.") + invalid,
                              side_effect=ci_summary.ContractError("unsupported test base")), \
                        patch.object(run_host_checks, "run_steps", side_effect=steps) as run, \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    code = run_host_checks.main()
                self.assertEqual(code, 1)
                run.assert_called_once()
                summary = ci_summary.parse_summary((output / "summary.json").read_text())
                self.assertEqual(summary["status"], "failed")
                self.assertEqual(len(summary["population"]["observed"]), len(run_host_checks.HOST_CHECKS))
                self.assertIn("population-invalid", [item["code"] for item in summary["infrastructure"]])

    def test_host_environment_excludes_external_screenshot_calibration(self):
        with patch.dict(os.environ, {"STRICT_E2E_REVIEWED_SCREENSHOTS": "/external/reviewed", "PATH": "/bin"}, clear=True):
            self.assertNotIn("STRICT_E2E_REVIEWED_SCREENSHOTS", run_host_checks.clean_environment())
            self.assertEqual(run_host_checks.clean_environment()["PATH"], "/bin")

    def test_host_failures_and_timeouts_name_the_step_and_continue(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            steps = [("format", ["/bin/sh", "-c", "exit 3"]),
                     ("slow", ["/bin/sleep", "30"]), ("last", ["/usr/bin/true"])]
            with contextlib.redirect_stdout(io.StringIO()):
                records, infrastructure = run_host_checks.run_steps(steps, root, timeout_seconds=3)
            self.assertEqual([entry["outcome"] for entry in records], ["failed", "timed-out", "not-run"])
            self.assertIn("format", records[0]["attempts"][0]["message"])
            self.assertEqual(records[0]["attempts"][0]["exit_code"], 3)
            self.assertEqual(infrastructure[0]["code"], "step-timeout")
            with patch.object(run_host_checks.subprocess, "Popen") as spawn, \
                    patch.object(run_host_checks, "stop_group"), contextlib.redirect_stdout(io.StringIO()):
                spawn.return_value.wait.side_effect = KeyboardInterrupt
                records, infrastructure = run_host_checks.run_steps(steps, root, timeout_seconds=3)
            self.assertEqual(spawn.call_count, 1)
            self.assertEqual(infrastructure[0]["code"], "interrupted")
            for entry in records[1:]:
                self.assertEqual(entry["outcome"], "not-run")
                self.assertIn("not run after interruption", entry["attempts"][0]["message"])

    def test_timeout_kills_a_surviving_child_after_the_parent_exits(self):
        code = """import os, signal, time
if os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print('child ready', flush=True)
while True:
    time.sleep(30)
"""
        process = subprocess.Popen([sys.executable, "-c", code], start_new_session=True,
                                   stdout=subprocess.PIPE, text=True)
        try:
            self.assertTrue(select.select([process.stdout], [], [], 10)[0], "child did not become ready")
            self.assertEqual(process.stdout.readline().strip(), "child ready")
            with patch.object(run_host_checks, "GROUP_TERM_GRACE_SECONDS", 0.1, create=True):
                run_host_checks.stop_group(process)
            # EOF requires every process holding this pipe to exit, including the child.
            process.communicate(timeout=5)

            self.assertEqual(process.returncode, -signal.SIGTERM)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                # macOS can leave only an adopted zombie in the group after pipe EOF.
                pass
            process.communicate(timeout=5)

    def test_process_group_liveness_ignores_zombies_but_keeps_live_children(self):
        for states, alive in (("42 Z\n99 S\n", False), ("42 Z\n42 S\n", True), ("99 S\n", False)):
            with self.subTest(states=states), patch.object(run_host_checks.subprocess, "check_output", return_value=states):
                self.assertEqual(run_host_checks.group_has_live_members(42), alive)

    def test_macos_group_probe_avoids_a_slow_full_system_query_without_widening_the_deadline(self):
        def probe(command, **kwargs):
            self.assertEqual(kwargs["timeout"], 5)
            if "-axo" in command:
                raise subprocess.TimeoutExpired(command, 5)
            self.assertEqual(command, ["ps", "-g", "42", "-o", "pgid=,stat="])
            return "42 Z\n42 S\n"

        with patch.object(run_host_checks.sys, "platform", "darwin"), \
                patch.object(run_host_checks.subprocess, "check_output", side_effect=probe):
            self.assertTrue(run_host_checks.group_has_live_members(42))

    def test_macos_absent_group_is_stopped_but_probe_errors_are_not_hidden(self):
        command = ["ps", "-g", "42", "-o", "pgid=,stat="]
        missing = subprocess.CalledProcessError(1, command, output="", stderr="")
        with patch.object(run_host_checks.sys, "platform", "darwin"), \
                patch.object(run_host_checks.subprocess, "check_output", side_effect=missing):
            self.assertFalse(run_host_checks.group_has_live_members(42))
        errors = [subprocess.CalledProcessError(1, command, output="42 S\n", stderr=""),
                  subprocess.CalledProcessError(1, command, output="", stderr="permission denied"),
                  subprocess.CalledProcessError(2, command, output="", stderr=""),
                  subprocess.TimeoutExpired(command, 5)]
        for error in errors:
            with self.subTest(error=error), patch.object(run_host_checks.sys, "platform", "darwin"), \
                    patch.object(run_host_checks.subprocess, "check_output", side_effect=error):
                with self.assertRaises(type(error)):
                    run_host_checks.group_has_live_members(42)

    def test_non_macos_probe_keeps_full_query_and_propagates_empty_exit_one(self):
        with patch.object(run_host_checks.sys, "platform", "linux"), \
                patch.object(run_host_checks.subprocess, "check_output", return_value="42 S\n") as probe:
            self.assertTrue(run_host_checks.group_has_live_members(42))
            self.assertEqual(probe.call_args.args[0], ["ps", "-axo", "pgid=,stat="])
            self.assertEqual(probe.call_args.kwargs["timeout"], 5)
        with patch.object(run_host_checks.sys, "platform", "linux"), \
                patch.object(run_host_checks.subprocess, "check_output", side_effect=
                             subprocess.CalledProcessError(1, ["ps"], output="", stderr="")):
            with self.assertRaises(subprocess.CalledProcessError):
                run_host_checks.group_has_live_members(42)


if __name__ == "__main__":
    unittest.main()
