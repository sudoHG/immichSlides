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






class SummaryContractTests(unittest.TestCase):




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


    def test_first_failure_rejects_one_private_unbounded_or_misbound_field(self):
        summary = archive_download_summary()
        summary.pop("archive_download")
        identity = summary["population"]["declared"][0]
        item = ci_summary.observation(identity, "failed", 1, exit_code=65)
        item["first_failure"] = item["attempts"][0]["first_failure"] = first_failure_receipt()
        summary["population"]["observed"] = [item]
        summary["status"] = "failed"
        cases = [
            (("raw_assertion",), "private", "first failure: invalid fields"),
            (("schema_version",), True, "first failure: unsupported version"),
            (("source",), "private-server", "first failure: invalid source"),
            (("step",), "raw assertion", "first failure: invalid step"),
            (("element",), "album.private-id", "first failure: invalid element"),
            (("action",), "https://private.invalid", "first failure: invalid action"),
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
            (("validator",), {"kind": "glyph", "slot": None, "axis": "unknown"}, "first failure: smoke has no visual validator"),
            (("state", "surface"), "firstboot", "first failure: screenshot is not an allowed app window"),
            (("state", "app"), "background", "first failure: screenshot is not an allowed app window"),
            (("source",), "validator", "first failure: invalid source"),
            (("element",), "firstboot.serverURL.field", "first failure: screenshot is not an allowed app window"),
            (("state", "focus"), "firstboot.apiKey.field", "first failure: screenshot is not an allowed app window"),
        ]
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
        for kind in ("host", "swift"):
            changed = copy.deepcopy(summary)
            changed["population"]["observed"][0]["identity"]["kind"] = kind
            with self.subTest(kind=kind), self.assertRaisesRegex(ci_summary.ContractError,
                    "^first failure requires a failing UI observation$"):
                ci_summary.parse_summary(changed)


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

    def test_runner_cleanup_members_round_trip_and_reject_private_or_unbounded_projections(self):
        from ci_failure_diagnostics import scan_diagnostic_json
        summary = archive_download_summary()
        summary.pop("archive_download")
        summary["bounded_diagnostics"] = bounded_diagnostics_receipt()
        event = summary["bounded_diagnostics"]["events"][1]
        event.update(scope="xcode", phase="unknown", state="after-reap", sample=None,
                     runner_group_members=[{"name": "sample", "parent": "Python", "state": "sleeping"}],
                     runner_group_truncated=False)
        self.assertEqual(summary, ci_summary.parse_summary(json.dumps(summary)))
        scan_diagnostic_json(json.dumps(summary).encode())
        self.assertIn("sample(parent=Python,state=sleeping)", ci_summary.render_markdown(summary))
        legacy = copy.deepcopy(summary)
        legacy["bounded_diagnostics"]["events"][1].pop("runner_group_truncated")
        self.assertEqual(legacy, ci_summary.parse_summary(legacy))
        for field, value in (("name", "/private/secret"), ("name", "private-tool"),
                ("parent", "12345678-1234-1234-1234-123456789012"), ("state", "S args")):
            changed = copy.deepcopy(summary)
            changed["bounded_diagnostics"]["events"][1]["runner_group_members"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ci_summary.ContractError, "runner group: invalid projection"):
                ci_summary.parse_summary(changed)
        for field, value, message in (("runner_group_members", event["runner_group_members"] * 65, "runner group: invalid projection"),
                ("scope", "preparation", "runner group: invalid event"),
                ("state", "started", "runner group: invalid event"),
                ("phase", "test-execution", "runner group: invalid event")):
            changed = copy.deepcopy(summary)
            changed["bounded_diagnostics"]["events"][1][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ci_summary.ContractError, message):
                ci_summary.parse_summary(changed)
        event["runner_group_members"] *= 64
        self.assertEqual(summary, ci_summary.parse_summary(summary))
        event["runner_group_truncated"] = True
        self.assertEqual(summary, ci_summary.parse_summary(summary))
        self.assertIn("truncated after 64 members", ci_summary.render_markdown(summary))
        for value in (None, 0, "true"):
            changed = copy.deepcopy(summary)
            changed["bounded_diagnostics"]["events"][1]["runner_group_truncated"] = value
            with self.subTest(truncation=value), self.assertRaisesRegex(ci_summary.ContractError, "runner group: invalid truncation flag"):
                ci_summary.parse_summary(changed)
        for missing in (True, False):
            changed = copy.deepcopy(summary)
            target = changed["bounded_diagnostics"]["events"][1]
            if missing:
                target.pop("runner_group_members")
            else:
                target["runner_group_members"] = target["runner_group_members"][:1]
            with self.subTest(missing=missing), self.assertRaisesRegex(ci_summary.ContractError, "runner group: invalid truncation flag"):
                ci_summary.parse_summary(changed)
        event["runner_group_members"] = [{"name": "SWBBuildService", "parent": "launchd", "state": "exiting"}]
        event["runner_group_truncated"] = False
        self.assertEqual(summary, ci_summary.parse_summary(summary))
        changed = copy.deepcopy(summary)
        changed["bounded_diagnostics"]["events"][0]["sample"]["processes"][0]["state"] = "exiting"
        with self.assertRaisesRegex(ci_summary.ContractError, "^bounded diagnostic process: invalid state$"):
            ci_summary.parse_summary(changed)
        event["runner_group_members"] = None
        self.assertEqual(summary, ci_summary.parse_summary(summary))
        self.assertIn("Runner cleanup survivors: unavailable", ci_summary.render_markdown(summary))


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


    def test_host_platform_parts_preserve_every_identity_once(self):
        with patch.object(run_host_checks, "MACOS_PYTHON_TESTS", frozenset({"synthetic.Sample.test_macos"})):
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

    def test_python_shards_balance_recorded_time_and_admit_new_methods_exactly_once(self):
        with patch.object(run_host_checks, "MACOS_PYTHON_TESTS", frozenset({"synthetic.Sample.test_macos"})):
            population = [ci_summary.test_identity("host", "test conventions")]
            population += [ci_summary.test_identity("python", key) for key in
                           ("test_a.C.testOne", "test_a.C.testTwo", "test_b.C.testOne", "test_c.C.testOne")]
            weights = {"python_modules": {"test_a": 8, "test_b": 6, "test_c": 2},
                       "host_checks": {"test conventions": 4}}
            parts = run_host_checks.python_shard_populations(population, weights)
            self.assertEqual(parts, run_host_checks.python_shard_populations(list(reversed(population)), weights))
            self.assertEqual([entry["key"] for entry in parts[0]], ["test conventions", "test_b.C.testOne"])
            self.assertEqual([entry["key"] for entry in parts[1]], ["test_a.C.testOne", "test_a.C.testTwo", "test_c.C.testOne"])
            for candidate in (population + [ci_summary.test_identity("python", "test_new.C.testAdded")], population[1:-1]):
                shards = run_host_checks.python_shard_populations(candidate, weights)
                keys = [ci_summary.identity_key(entry) for shard in shards for entry in shard]
                self.assertEqual(sorted(keys), sorted(map(ci_summary.identity_key, candidate)))
                self.assertEqual(len(keys), len(set(keys)))
            with self.assertRaises(ci_summary.ContractError):
                run_host_checks.python_shard_populations(population + population[-1:], weights)
            mac = ci_summary.test_identity("python", sorted(run_host_checks.MACOS_PYTHON_TESTS)[0])
            portable = ci_summary.test_identity("python", "portable.C.testAdded")
            new_case_weights = {"python_modules": {mac["key"].split(".")[0]: 200, "portable": 3},
                                "host_checks": {"test conventions": 4}}
            self.assertEqual(run_host_checks.python_shard_populations([population[0], mac, portable], new_case_weights)[0],
                             [population[0]])

    def test_host_shard_merge_fails_closed_for_incomplete_or_unbound_execution(self):
        template = valid_summary()
        parts = [[ci_summary.test_identity("python", "test_a.C.testOne")],
                 [ci_summary.test_identity("python", "test_b.C.testTwo")]]
        template["population"].update(declared=parts[0] + parts[1], compiled=[], observed=[])
        shards = []
        for number, entries in enumerate(parts, 1):
            shard = copy.deepcopy(template)
            shard["run"]["shard"] = "python-" + str(number)
            shard["population"].update(declared=list(entries), compiled=list(entries),
                observed=[ci_summary.observation(entry, "passed", 1) for entry in entries])
            shards.append((number, shard, 0))
        compiled, observed, infrastructure = run_host_checks.merge_host_shards(template, parts, shards)
        self.assertEqual(compiled, parts[0] + parts[1])
        self.assertEqual([row["identity"] for row in observed], compiled)
        self.assertEqual(infrastructure, [])
        def different_source(value):
            value[1][1]["identity"]["tree_sha"] = "c" * 40
        def duplicate(value):
            value[1][1]["population"]["observed"] *= 2
        def missing(value):
            value[1][1]["population"]["observed"] = []
        def compiled_missing(value):
            value[1][1]["population"]["compiled"] = []
        def wrong_partition(value):
            value[1][1]["population"] = copy.deepcopy(value[0][1]["population"])
        def missing_receipt(value):
            value[1] = (2, None, -signal.SIGTERM)
        def malformed(value):
            value[1][1]["status"] = "invalid"
        def swapped_execution(value):
            first, second = (entry[1]["population"] for entry in value)
            for field in ("compiled", "observed"):
                first[field], second[field] = second[field], first[field]
        for defect in (lambda value: value.pop(), different_source, duplicate, missing, compiled_missing,
                       wrong_partition, missing_receipt, malformed, swapped_execution):
            bad = copy.deepcopy(shards)
            defect(bad)
            with self.subTest(defect=defect.__name__), self.assertRaises(ci_summary.ContractError):
                run_host_checks.merge_host_shards(template, parts, bad)
        def extra_compiled(value):
            value[1][1]["population"]["compiled"].append(ci_summary.test_identity("python", "test_extra.C.testOther"))
        def declared_missing(value):
            value[1][1]["population"]["declared"] = []
        def cross_assignment(value):
            value[1][1]["population"]["observed"] = copy.deepcopy(value[0][1]["population"]["observed"])
        def wrong_run(value):
            value[1][1]["run"]["attempt"] += 1
        def wrong_hash(value):
            value[1][1]["hashes"]["policies"]["workflow-policy"] = "f" * 64
        for defect in (different_source, duplicate, wrong_partition, declared_missing, extra_compiled,
                       cross_assignment, wrong_run, wrong_hash):
            bad = copy.deepcopy(shards)
            bad[1][1]["status"] = "failed"
            defect(bad)
            with self.subTest(failed_defect=defect.__name__), self.assertRaises(ci_summary.ContractError):
                run_host_checks.merge_host_shards(template, parts, bad)
        bad = copy.deepcopy(shards)
        cross_assignment(bad)
        bad[0][1]["population"]["observed"] = []
        for _, shard, _ in bad:
            shard["status"] = "failed"
        with self.assertRaisesRegex(ci_summary.ContractError, "host shard execution differs"):
            run_host_checks.merge_host_shards(template, parts, bad)
        bad = copy.deepcopy(shards)
        for _, shard, _ in bad:
            shard["status"] = "failed"
            shard["population"]["observed"].append(ci_summary.observation(
                ci_summary.test_identity("python", "setUpClass (test_extra.C)"), "failed", 0))
        with self.assertRaisesRegex(ci_summary.ContractError, "duplicate host shard identity"):
            run_host_checks.merge_host_shards(template, parts, bad)

    def test_parallel_host_main_publishes_success_and_preserves_failed_shard_evidence(self):
        python = [ci_summary.test_identity("python", "test_a.C.testOne"),
                  ci_summary.test_identity("python", "test_b.C.testTwo")]
        weights = {"python_modules": {}, "host_checks": {}}
        class Broken(unittest.TestCase):
            @classmethod
            def setUpClass(cls):
                raise RuntimeError("fixture setup failed")

            def testTwo(self):
                self.fail("a broken fixture must not execute its member")
        Broken.__module__, Broken.__qualname__ = "test_b", "C"
        fixture, fixture_code = run_python_tests.run_suite(
            unittest.defaultTestLoader.loadTestsFromTestCase(Broken), io.StringIO())
        self.assertEqual(fixture_code, 1)
        for failure in (None, "python", "fixture", "static", "interrupted", "missing-python-results",
                        "failed-status", "cancelled", "parent-timeout", "policy-proposed"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                def children(*args, **kwargs):
                    template = json.loads((output / "summary.json").read_text())
                    template["hashes"]["policies"]["test-policy"] = hashlib.sha256(
                        (run_host_checks.REPO_ROOT / "scripts/ci-test-policy.json").read_bytes()).hexdigest()
                    template["population"]["declared"].extend(python)
                    parts = run_host_checks.python_shard_populations(template["population"]["declared"], weights)
                    receipts = []
                    for number, entries in enumerate(parts, 1):
                        shard = copy.deepcopy(template)
                        shard["run"]["shard"] = "python-" + str(number)
                        rows = [ci_summary.observation(entry, "passed", 0) for entry in entries]
                        code = 0
                        if failure == "static" and number == 1 or failure == "python" and number == 2:
                            target = next(row for row in rows if row["identity"]["kind"] ==
                                          ("host" if failure == "static" else "python"))
                            rows[rows.index(target)] = ci_summary.observation(target["identity"], "failed", 0, exit_code=1)
                            code = 1
                        compiled = entries
                        if number == 2 and failure == "fixture":
                            compiled, rows, code = fixture["compiled"], fixture["observed"], fixture_code
                        if number == 2 and failure in {"interrupted", "missing-python-results"}:
                            shard["infrastructure"] = [{"code": failure, "message": "child diagnostic"}]
                            compiled, rows = [], []
                            code = 1
                        if number == 2 and failure in {"cancelled", "parent-timeout"}:
                            code = -signal.SIGTERM if failure == "cancelled" else 124
                        shard["status"] = ("failed" if (code and failure not in {"cancelled", "parent-timeout"}
                                                      or failure == "failed-status" and number == 2) else "passed")
                        if failure == "policy-proposed":
                            shard["status"] = "unverified"
                            shard["infrastructure"] = [{"code": "policy-proposed", "message": "recompute on union"}]
                        shard["population"].update(declared=entries, compiled=compiled, observed=rows)
                        receipts.append((number, shard, code))
                    return receipts
                with patch("sys.argv", ["run_host_checks.py", "--output-dir", str(output)]), \
                        patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                        patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                        patch.object(run_host_checks, "python_shard_weights", return_value=weights), \
                        patch("ci_population.python_identities", return_value=python), \
                        patch.object(run_host_checks, "run_parallel_shards", side_effect=children) as launch, \
                        patch.object(run_host_checks, "run_steps") as steps, \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    code = run_host_checks.main()
                succeeds = failure in {None, "policy-proposed"}
                self.assertEqual(code, 0 if succeeds else 1)
                launch.assert_called_once_with(output.resolve(), timeout_seconds=900, host_platform=None, workflow_path=None)
                steps.assert_not_called()
                summary = ci_summary.parse_summary((output / "summary.json").read_text())
                self.assertEqual(summary["status"], "passed" if succeeds else "failed")
                rows = summary["population"]["observed"]
                expected = summary["population"]["declared"]
                if failure == "fixture":
                    expected = expected + [ci_summary.test_identity("python", "setUpClass (test_b.C)")]
                elif failure in {"interrupted", "missing-python-results"}:
                    expected = [entry for entry in expected if entry != python[1]]
                self.assertEqual({ci_summary.identity_key(row["identity"]) for row in rows},
                                 {ci_summary.identity_key(entry) for entry in expected})
                self.assertTrue(any(row["identity"]["kind"] == "python" and row["outcome"] == "passed" for row in rows))
                if failure == "python":
                    self.assertEqual([row["identity"] for row in rows if row["outcome"] == "failed"
                                      and row["identity"]["kind"] == "python"], python[1:])
                    self.assertIn(python[1]["key"], (output / "summary.md").read_text())
                if failure in {"python", "fixture", "failed-status", "cancelled", "parent-timeout"}:
                    self.assertEqual(next(row["outcome"] for row in rows
                        if row["identity"] == ci_summary.test_identity("host", "python tests")), "failed")
                if failure == "fixture":
                    failed = next(row for row in rows if row["identity"]["key"] == "setUpClass (test_b.C)")
                    self.assertEqual(failed["outcome"], "failed")
                    self.assertIn("fixture setup failed", failed["attempts"][0]["message"])
                    self.assertIn("setUpClass (test_b.C)", (output / "summary.md").read_text())
                if failure == "static":
                    self.assertTrue(any(row["identity"]["kind"] == "host" and row["outcome"] == "failed" for row in rows))
                    self.assertEqual(next(row["outcome"] for row in rows
                        if row["identity"] == ci_summary.test_identity("host", "python tests")), "passed")
                expected_codes = [failure] if failure in {"interrupted", "missing-python-results"} else []
                self.assertEqual([entry["code"] for entry in summary["infrastructure"]], expected_codes)

    def test_child_deadline_wait_stops_when_parent_changes_or_never_publishes(self):
        for reason in ("parent changed", "timed out"):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "deadline.json"
                parents = [42, 42, 43] if reason == "parent changed" else [42, 42, 42]
                with patch.object(run_host_checks.os, "getppid", side_effect=parents), \
                        patch.object(run_host_checks.time, "monotonic", side_effect=[0, 0, 31]), \
                        patch.object(run_host_checks.time, "sleep", side_effect=[None, AssertionError("unbounded wait")]):
                    with self.assertRaisesRegex(ci_summary.ContractError, reason):
                        run_host_checks.shard_execution_deadline(path)
                self.assertTrue(path.with_suffix(".ready").exists())

    def test_shared_execution_clock_excludes_sleep_on_macos(self):
        with patch.object(run_host_checks.time, "CLOCK_UPTIME_RAW", 8, create=True):
            for host, clock in (("darwin", 8), ("linux", run_host_checks.time.CLOCK_MONOTONIC)):
                with self.subTest(host=host), patch.object(run_host_checks.sys, "platform", host), \
                        patch.object(run_host_checks.time, "clock_gettime", return_value=123) as read:
                    self.assertEqual(run_host_checks.execution_clock(), 123)
                    read.assert_called_once_with(clock)

    def test_child_deadline_receipt_is_published_as_step_timeout(self):
        python = [ci_summary.test_identity("python", "test_a.C.testOne"),
                  ci_summary.test_identity("python", "test_b.C.testTwo")]
        weights = {"python_modules": {}, "host_checks": {}}
        launch = run_host_checks.run_parallel_shards
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            (root / "scripts").mkdir()
            def children(*args, **kwargs):
                template = json.loads((output / "summary.json").read_text())
                template["hashes"]["policies"]["test-policy"] = hashlib.sha256(
                    (run_host_checks.REPO_ROOT / "scripts/ci-test-policy.json").read_bytes()).hexdigest()
                template["population"]["declared"].extend(python)
                parts = run_host_checks.python_shard_populations(template["population"]["declared"], weights)
                receipts = []
                for number, entries in enumerate(parts, 1):
                    shard = copy.deepcopy(template)
                    shard["run"]["shard"] = "python-" + str(number)
                    shard["population"].update(declared=entries, compiled=[], observed=[])
                    receipts.append(shard)
                (root / "receipts.json").write_text(json.dumps(receipts))
                (root / "scripts/run_host_checks.py").write_text('''import argparse, json, pathlib, sys, time
sys.path.insert(0, SCRIPTS)
import run_host_checks as host
p = argparse.ArgumentParser()
p.add_argument('--output-dir', type=pathlib.Path)
p.add_argument('--python-shard', type=int)
p.add_argument('--timeout-seconds', type=float)
p.add_argument('--shard-deadline-path', type=pathlib.Path)
a = p.parse_args()
assert a.timeout_seconds == 1
time.sleep(.2)  # Startup precedes the child's full execution budget.
deadline = host.shard_execution_deadline(a.shard_deadline_path)
receipt = json.loads((a.output_dir.parent.parent / 'receipts.json').read_text())[a.python_shard - 1]
hosts = [entry for entry in receipt['population']['declared'] if entry['kind'] == 'host']
steps = [(entry['key'], ['true']) for entry in hosts if entry['key'] != 'python tests']
steps.append(('python tests', [sys.executable, '-c', 'import time; time.sleep(30)']))
rows, infrastructure = host.run_steps(steps, a.output_dir, timeout_seconds=a.timeout_seconds,
                                    deadline_monotonic=deadline)
receipt['population'].update(compiled=hosts, observed=[row for row in rows if row['identity'] in hosts])
receipt['infrastructure'] = infrastructure + [{'code': 'missing-python-results', 'message': 'Python result identities are missing or malformed'}]
receipt['status'] = 'failed'
time.sleep(.1)  # Receipt finalization must finish before the parent's kill backstop.
(a.output_dir / 'summary.json').write_text(json.dumps(receipt))
raise SystemExit(1)
'''.replace("SCRIPTS", repr(str(Path(run_host_checks.__file__).parent))))
                with patch.object(run_host_checks, "REPO_ROOT", root):
                    return launch(*args, **kwargs)
            with patch("sys.argv", ["run_host_checks.py", "--python-shards", "2", "--timeout-seconds", "1",
                                    "--output-dir", str(output)]), \
                    patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                    patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                    patch.object(run_host_checks, "python_shard_weights", return_value=weights), \
                    patch("ci_population.python_identities", return_value=python), \
                    patch.object(run_host_checks, "run_parallel_shards", side_effect=children), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(run_host_checks.main(), 1)
            summary = ci_summary.parse_summary((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertEqual([entry["code"] for entry in summary["infrastructure"]],
                             ["step-timeout", "missing-python-results"] * 2, summary["infrastructure"])
            self.assertEqual([entry["message"] for entry in summary["infrastructure"] if entry["code"] == "step-timeout"],
                             ["python tests: host-check time budget exhausted"] * 2)
            self.assertEqual(sorted(map(ci_summary.identity_key, summary["population"]["compiled"])),
                             sorted(ci_summary.identity_key(ci_summary.test_identity("host", name))
                                    for name, _ in run_host_checks.HOST_CHECKS))
            self.assertEqual(len(summary["population"]["observed"]), len(run_host_checks.HOST_CHECKS))
            self.assertIn("timed-out", [row["outcome"] for row in summary["population"]["observed"]])

    def test_parallel_host_children_launch_together_and_keep_independent_budgets(self):
        template = valid_summary()
        template["population"]["declared"] = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            # A rendezvous makes sequential execution fail without measuring a fast host's timing.
            (root / "scripts/run_host_checks.py").write_text('''import argparse, json, pathlib, sys, time
sys.path.insert(0, SCRIPTS)
import run_host_checks as host
p = argparse.ArgumentParser()
p.add_argument('--output-dir', type=pathlib.Path)
p.add_argument('--python-shard', type=int)
p.add_argument('--timeout-seconds', type=float)
p.add_argument('--shard-deadline-path', type=pathlib.Path)
a = p.parse_args()
(a.output_dir / 'started').touch()
other = a.output_dir.parent / ('python-' + str(3 - a.python_shard)) / 'started'
deadline = time.monotonic() + 5
while not other.exists() and time.monotonic() < deadline:
    time.sleep(.01)
if not other.exists() or a.timeout_seconds != 7:
    raise SystemExit(1)
time.sleep(.2)  # Startup must not consume the child's execution budget.
ready = host.execution_clock()
execution_deadline = host.shard_execution_deadline(a.shard_deadline_path)
assert execution_deadline >= ready + a.timeout_seconds
summary = json.loads((a.output_dir.parent / 'template.json').read_text())
summary['run']['shard'] = 'python-' + str(a.python_shard)
(a.output_dir / 'summary.json').write_text(json.dumps(summary))
'''.replace("SCRIPTS", repr(str(Path(run_host_checks.__file__).parent))))
            (root / "template.json").write_text(json.dumps(template))
            with patch.object(run_host_checks, "REPO_ROOT", root), contextlib.redirect_stdout(io.StringIO()) as log:
                shards = run_host_checks.run_parallel_shards(root, timeout_seconds=7, host_platform=None, workflow_path=None)
            self.assertEqual([(number, code) for number, _, code in shards], [(1, 0), (2, 0)])
            self.assertIn("Python shard 1 wall time:", log.getvalue())
            self.assertIn("Python shard 2 wall time:", log.getvalue())
            (root / "scripts/run_host_checks.py").write_text('''import argparse, pathlib, sys, time
sys.path.insert(0, SCRIPTS)
import run_host_checks as host
p = argparse.ArgumentParser()
p.add_argument('--output-dir')
p.add_argument('--python-shard')
p.add_argument('--timeout-seconds')
p.add_argument('--shard-deadline-path', type=pathlib.Path)
a = p.parse_args()
host.shard_execution_deadline(a.shard_deadline_path)
time.sleep(2)
'''.replace("SCRIPTS", repr(str(Path(run_host_checks.__file__).parent))))
            with patch.object(run_host_checks, "REPO_ROOT", root), \
                    patch.object(run_host_checks, "GROUP_TERM_GRACE_SECONDS", .05), \
                    patch.object(run_host_checks, "SHARD_FINALIZATION_MARGIN_SECONDS", 0), \
                    contextlib.redirect_stdout(io.StringIO()):
                timed_out = run_host_checks.run_parallel_shards(root / "timeout", timeout_seconds=.1,
                                                               host_platform=None, workflow_path=None)
            self.assertEqual([(number, code) for number, _, code in timed_out], [(1, 124), (2, 124)])
            self.assertTrue(all(payload is None for _, payload, _ in timed_out))

    def test_host_shard_timeout_allows_child_step_group_cleanup_before_killing_the_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "scripts/run_host_checks.py").write_text('''import argparse, pathlib, signal, subprocess, sys, time
sys.path.insert(0, SCRIPTS)
import run_host_checks as host
p = argparse.ArgumentParser()
p.add_argument('--output-dir', type=pathlib.Path)
p.add_argument('--python-shard')
p.add_argument('--timeout-seconds')
p.add_argument('--shard-deadline-path', type=pathlib.Path)
a = p.parse_args()
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
def stop(signum, frame):
    time.sleep(.3)
    child.terminate()
    child.wait()
    raise SystemExit(1)
signal.signal(signal.SIGTERM, stop)
(a.output_dir / 'descendant.pid').write_text(str(child.pid))
host.shard_execution_deadline(a.shard_deadline_path)
time.sleep(30)
'''.replace("SCRIPTS", repr(str(Path(run_host_checks.__file__).parent))))
            try:
                with patch.object(run_host_checks, "REPO_ROOT", root), \
                        patch.object(run_host_checks, "SHARD_FINALIZATION_MARGIN_SECONDS", 0), \
                        patch.object(run_host_checks, "GROUP_TERM_GRACE_SECONDS", .05), \
                        contextlib.redirect_stdout(io.StringIO()):
                    shards = run_host_checks.run_parallel_shards(root, timeout_seconds=1, host_platform=None, workflow_path=None)
                self.assertEqual([code for _, _, code in shards], [124, 124])
                for number in (1, 2):
                    pid = int((root / ("python-" + str(number)) / "descendant.pid").read_text())
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
            finally:
                for path in root.glob("python-*/descendant.pid"):
                    try:
                        os.kill(int(path.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_host_duration_weights_refuse_invalid_or_nonfinite_costs(self):
        weights = {"schema_version": 1, "source": {}, "python_modules": {"test_a": 1},
                   "python_tests": {}, "host_checks": {}}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            path = root / "scripts/ci-host-durations.json"
            path.write_text(json.dumps(weights))
            with patch.object(run_host_checks, "REPO_ROOT", root):
                self.assertEqual(run_host_checks.python_shard_weights(), weights)
                invalid = [dict(weights, schema_version=True), dict(weights, host_checks=[])]
                invalid += [dict(weights, python_modules={"test_a": cost}) for cost in (-1, True, float("inf"), "1")]
                for candidate in invalid:
                    path.write_text(json.dumps(candidate))
                    with self.subTest(candidate=candidate), self.assertRaises(ci_summary.ContractError):
                        run_host_checks.python_shard_weights()

    def test_internal_host_shards_run_static_checks_once_and_preserve_empty_shard_receipts(self):
        with patch.object(run_host_checks, "MACOS_PYTHON_TESTS", frozenset({"synthetic.Sample.test_macos"})):
            python = [ci_summary.test_identity("python", "portable.Sample.test_rule"),
                      ci_summary.test_identity("python", sorted(run_host_checks.MACOS_PYTHON_TESTS)[0])]
            complete = [ci_summary.test_identity("host", name) for name, _ in run_host_checks.HOST_CHECKS] + python
            weights = {"python_modules": {}, "host_checks": {}}
            keys = lambda entries: sorted(map(ci_summary.identity_key, entries))
            for scope in (None, "linux", "macos"):
                recorded, static = [], []
                expected = run_host_checks.host_partition(complete, scope) if scope else complete
                for number in (1, 2):
                    with self.subTest(scope=scope, shard=number), tempfile.TemporaryDirectory() as directory:
                        output = Path(directory)
                        def steps(commands, *args, **kwargs):
                            self.assertEqual(kwargs.get("deadline_monotonic"), 17)
                            manifest = json.loads((output / "python-selection.json").read_text())
                            self.assertEqual(manifest["inventory"], python)
                            static.extend(name for name, _ in commands if name != "python tests")
                            (output / "python-results.json").write_text(json.dumps({"compiled": manifest["selected"],
                                "observed": [ci_summary.observation(entry, "passed", 0) for entry in manifest["selected"]]}))
                            return [ci_summary.observation(ci_summary.test_identity("host", name), "passed", 0)
                                    for name, _ in commands], []
                        arguments = ["run_host_checks.py", "--python-shard", str(number), "--output-dir", str(output),
                                     "--shard-deadline-path", str(output / "execution-deadline.json")]
                        if scope:
                            arguments += ["--host-platform", scope]
                        with patch("sys.argv", arguments), \
                                patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                                patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                                patch.object(run_host_checks, "python_shard_weights", return_value=weights), \
                                patch.object(run_host_checks, "shard_execution_deadline", return_value=17), \
                                patch("ci_population.python_identities", return_value=python), \
                                patch.object(run_host_checks, "run_steps", side_effect=steps), \
                                patch.object(run_host_checks, "run_parallel_shards", side_effect=AssertionError("unexpected fan-out")), \
                                contextlib.redirect_stdout(io.StringIO()):
                            self.assertEqual(run_host_checks.main(), 0)
                        summary = ci_summary.parse_summary((output / "summary.json").read_text())
                        population = summary["population"]
                        self.assertEqual(summary["status"], "passed")
                        self.assertEqual(keys(population["declared"]), keys(population["compiled"]))
                        self.assertEqual(keys(population["compiled"]), keys([row["identity"] for row in population["observed"]]))
                        recorded.extend(population["declared"])
                self.assertEqual(keys(recorded), keys(expected))
                self.assertEqual(sorted(static), sorted(entry["key"] for entry in expected
                    if entry["kind"] == "host" and entry["key"] != "python tests"))

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
        with patch.object(run_host_checks, "MACOS_PYTHON_TESTS", frozenset({"synthetic.Sample.test_macos"})):
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
                    with patch("sys.argv", ["run_host_checks.py", "--python-shards", "1", "--host-platform", scope, "--output-dir", str(output)]), \
                            patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                            patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                            patch("ci_population.python_identities", return_value=python), \
                            patch.object(run_host_checks, "run_steps", side_effect=steps), \
                            patch.object(run_host_checks, "run_parallel_shards", side_effect=AssertionError("unexpected fan-out")), \
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

            with patch("sys.argv", ["run_host_checks.py", "--python-shards", "1", "--output-dir", str(output)]), \
                    patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                    patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                    patch.object(run_host_checks, "run_steps", side_effect=steps), \
                    patch.object(run_host_checks, "run_parallel_shards", side_effect=AssertionError("unexpected fan-out")), \
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

            with patch("sys.argv", ["run_host_checks.py", "--python-shards", "1", "--output-dir", str(output)]), \
                    patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]) as identity_call, \
                    patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                    patch("ci_population.python_identities", return_value=[identity]), \
                    patch.object(run_host_checks, "run_steps", side_effect=steps), \
                    patch.object(run_host_checks, "run_parallel_shards", side_effect=AssertionError("unexpected fan-out")), \
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

                with patch("sys.argv", ["run_host_checks.py", "--python-shards", "1", "--output-dir", str(output)]), \
                        patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                        patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                        patch("ci_population.python_identities", return_value=[identity]), \
                        patch("ci_verdict.parse_policy", side_effect=lambda raw: policy if isinstance(raw, str) else parse_policy(raw)), \
                        patch.object(run_host_checks, "run_steps", side_effect=steps), \
                        patch.object(run_host_checks, "run_parallel_shards", side_effect=AssertionError("unexpected fan-out")), \
                        contextlib.redirect_stdout(io.StringIO()):
                    code = run_host_checks.main()
                self.assertEqual(code, 0)
                summary = ci_summary.parse_summary((output / "summary.json").read_text())
                self.assertEqual(summary["status"], outcome)
                self.assertEqual(summary["population"]["declared"][-1], identity)
                self.assertIn("test-policy", summary["hashes"]["policies"])

    def test_invalid_population_or_policy_still_writes_placeholder_and_runs_all_checks(self):
        cases = [("python_identities", ["--python-shards", "1"]),
                 ("python_identities", []), ("python_identities", ["--python-shards", "2"]),
                 ("parse_policy", ["--python-shards", "1"])]
        for invalid, arguments in cases:
            with self.subTest(invalid=invalid, arguments=arguments), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"

                def steps(commands, *args, **kwargs):
                    placeholder = ci_summary.parse_summary((output / "summary.json").read_text())
                    self.assertEqual(placeholder["status"], "unverified")
                    self.assertEqual(placeholder["population"]["observed"], [])
                    self.assertEqual([name for name, _ in commands], [name for name, _ in run_host_checks.HOST_CHECKS])
                    (output / "python-results.json").write_text(json.dumps({"compiled": [], "observed": []}))
                    return [ci_summary.observation(ci_summary.test_identity("host", name), "passed", 0)
                            for name, _ in commands], []

                with patch("sys.argv", ["run_host_checks.py", *arguments, "--output-dir", str(output)]), \
                        patch.object(run_host_checks, "run_identity", return_value=valid_summary()["identity"]), \
                        patch.object(run_host_checks, "toolchain", return_value=valid_summary()["toolchain"]), \
                        patch(("ci_population." if invalid == "python_identities" else "ci_verdict.") + invalid,
                              side_effect=ci_summary.ContractError("unsupported test base")), \
                        patch.object(run_host_checks, "run_steps", side_effect=steps) as run, \
                        patch.object(run_host_checks, "run_parallel_shards", side_effect=AssertionError("unexpected fan-out")), \
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
            with patch.object(run_host_checks.subprocess, "Popen") as spawn, \
                    contextlib.redirect_stdout(io.StringIO()):
                records, infrastructure = run_host_checks.run_steps(steps, root, timeout_seconds=3,
                                                                    deadline_monotonic=0)
            spawn.assert_not_called()
            self.assertEqual([entry["outcome"] for entry in records], ["not-run"] * len(steps))

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
