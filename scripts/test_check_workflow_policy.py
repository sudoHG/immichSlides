"""Guard workflow trust boundaries against accidental privilege and code execution."""

import copy
import re
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

import check_workflow_policy as policy


SHA = "11d5960a326750d5838078e36cf38b85af677262"
TRUSTED = ".github/workflows/ci-publish.yml"


def workflow():
    return {
        "on": {"pull_request": None},
        "permissions": {"contents": "read"},
        "jobs": {"check": {"runs-on": "macos-latest", "timeout-minutes": 5,
                           "steps": [{"uses": f"actions/checkout@{SHA}"}]}},
    }


class WorkflowPolicyTests(unittest.TestCase):
    def test_area_map_errors_identify_the_area_map_and_its_own_rule(self):
        from ci_summary import ContractError
        from ci_ui_selection import AREA_MAP_PATH
        from ci_ui_shards import MANIFEST_PATH
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/workflows/check.yml").write_text(yaml.safe_dump(workflow()))
            (root / "scripts").mkdir()
            (root / MANIFEST_PATH).write_text(
                '{"schema_version": 2, "revision": "test", "default_shard": "default", "shards": {"default": []}}')
            output = io.StringIO()
            with patch("ci_ui_shards.validate_shard_assignments"), \
                    patch("ci_ui_selection.check_area_map", side_effect=ContractError("unmapped app source")), \
                    contextlib.redirect_stderr(output), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(policy.main(["--root", str(root), "--check-ui-shards"]), 1)
            self.assertIn(AREA_MAP_PATH + ":map: [ui-areas] unmapped app source", output.getvalue())
            self.assertNotIn(MANIFEST_PATH, output.getvalue())

    def test_ui_flow_check_requires_area_membership_for_identifiers_reached_through_helpers(self):
        import json
        from ci_summary import test_identity
        from ci_ui_flows import flow_violations
        area_map = {"schema_version": 1, "revision": "areas-v1", "smoke": ["SmokeUITests/testLaunch"],
                    "areas": {"core": {"sources": ["immichSlides/Shared/Model/**"], "tests": ["CoreUITests"]},
                              "settings": {"sources": ["immichSlides/Shared/Settings*.swift"],
                                           "tests": ["SettingsUITests", "ProtectionUITests"]},
                              "protection": {"sources": ["immichSlides/tvOS/ProtectionPage.swift"],
                                             "tests": ["ProtectionUITests/testPage"]},
                              "filter": {"sources": ["immichSlides/Shared/Filter.swift"], "tests": ["FilterUITests"]},
                              "playback": {"sources": ["immichSlides/tvOS/TVOnly.swift"], "tests": ["SmokeUITests"]},
                              "locale": {"sources": ["immichSlides/Shared/Filter.swift"], "tests": ["LocaleUITests"]}},
                    "nightly_default": ["locale"]}
        app = {
            "immichSlides/Shared/Model/Engine.swift": 'let id = "engine.status.flag"',
            "immichSlides/Shared/SettingsHelpers.swift":
                'func pinInputAccessibilityID(_ t: T) -> String { "settings.pin.input.\\(t.name)" }\n'
                'let item = "settings.item.playback"',
            "immichSlides/tvOS/ProtectionPage.swift": "func body() { row(id: pinInputAccessibilityID(.enable)) }",
            "immichSlides/Shared/Filter.swift": 'let start = "filterSummary.startPlayback.button"',
            "immichSlides/tvOS/TVOnly.swift": 'let tv = "tv.only.button"',
        }
        tests = {
            "immichSlidesUITests/Settings.swift": """
final class SettingsUITests: XCTestCase {
    func testOpen() { openSettings(app); app.buttons["engine.status.flag"].tap() }
    func testStart() { app.buttons[Contract.startID].tap() }
    func openSettings(_ app: XCUIApplication) { app.buttons["settings.item.playback"].tap() }
}
final class ProtectionUITests: XCTestCase {
    func testPage() { wait(app.buttons["settings.pin.input.enable"]) }
    func testSidebar() { wait(app.buttons["settings.pin.input.\\(field)"]) }
}
final class OtherUITests: XCTestCase {
    func testOther() {}
    func openSettings(_ app: XCUIApplication) { app.buttons["filterSummary.startPlayback.button"].tap() }
}
final class SmokeUITests: XCTestCase {
    func testLaunch() { app.buttons["filterSummary.startPlayback.button"].tap() }
    func testPlatform() {
#if os(tvOS)
        app.buttons["tv.only.button"].tap()
#endif
    }
}
final class LocaleUITests: XCTestCase {
    func testLeaf() { app.buttons["settings.item.playback"].tap(); app.buttons[Contract.startID].tap() }
    func testNavigationOnly() { app.buttons["settings.item.playback"].tap() }
}
""",
            "TestSupport/Contract.swift": 'enum Contract { static let startID = "filterSummary.startPlayback.button" }',
        }
        keys = ["SettingsUITests/testOpen", "SettingsUITests/testStart", "ProtectionUITests/testPage",
                "ProtectionUITests/testSidebar", "OtherUITests/testOther", "SmokeUITests/testLaunch",
                "SmokeUITests/testPlatform", "LocaleUITests/testLeaf", "LocaleUITests/testNavigationOnly"]
        populations = {"ui-" + platform: [test_identity("ui", key, platform=platform) for key in keys]
                       for platform in ("ios", "tvos")}
        plans = {platform: json.dumps({"testTargets": [{"target": {"name": "immichSlidesUITests"}}]})
                 for platform in ("ios", "tvos")}
        helpers = "immichSlides/Shared/SettingsHelpers.swift"
        exceptions = {"schema_version": 1, "exceptions": [
            {"identifier": "filterSummary.startPlayback.button", "source": "immichSlides/Shared/Filter.swift",
             "reason": "Reviewed."},
            {"navigation": helpers, "areas": ["locale"], "reason": "Route to the captured screen."},
            {"test": "OtherUITests", "reason": "Never launches the app."}]}

        def violations(exception_entries):
            return flow_violations(json.dumps(area_map), json.dumps(dict(exceptions, exceptions=exception_entries)),
                                   app, tests, populations, plans)

        # Own-type helpers, TestSupport constants, delegated and interpolated identifiers and platform
        # conditions are resolved; core and smoke never need a feature membership. A nightly-default
        # test must reach its own leaf screen, and may traverse other files only when they are
        # reviewed navigation sources for its area.
        sidebar = ("ProtectionUITests/testSidebar reaches settings.pin.input.* defined in "
                   "immichSlides/tvOS/ProtectionPage.swift; add it to one of ['protection']")
        start = ("SettingsUITests/testStart reaches filterSummary.startPlayback.button defined in "
                 "immichSlides/Shared/Filter.swift; add it to one of ['filter', 'locale']")
        routes = [f"LocaleUITests/{name} reaches settings.item.playback defined in {helpers}; add it to one of "
                  "['settings']" for name in ("testLeaf", "testNavigationOnly")]
        no_leaf = "LocaleUITests/testNavigationOnly is nightly-default but reaches no identifier from its areas' screens ['locale']"
        self.assertEqual(violations([]), [routes[0], no_leaf, routes[1], sidebar, start])
        self.assertEqual(violations(exceptions["exceptions"][:2]), [no_leaf, sidebar])
        self.assertEqual(violations(exceptions["exceptions"]), [
            no_leaf, sidebar, "stale UI flow exception: test=OtherUITests"])
        for entry in ({"identifier": "Not An Identifier", "source": "x", "reason": "r"},
                      {"test": "OtherUITests", "reason": "two\nlines"},
                      {"test": "OtherUITests", "identifier": "a.b", "reason": "r"},
                      {"navigation": helpers, "areas": ["settings"], "reason": "Not a nightly-default area."},
                      {"navigation": "immichSlides/Shared/*.swift", "areas": ["locale"], "reason": "Glob."}):
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                violations([entry])

    def test_nightly_aggregates_cannot_wait_for_macos_or_require_xcode(self):
        path = policy.LIVE_WORKFLOW
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(set(), self.rules(document, path))
        for job_id in ("aggregate", "ui-aggregate"):
            for mutation in ("runner", "xcode", "toolchain", "bootstrap"):
                with self.subTest(job=job_id, mutation=mutation):
                    changed = copy.deepcopy(document)
                    job = changed["jobs"][job_id]
                    if mutation == "runner":
                        job["runs-on"] = "xcode-27"
                    elif mutation == "bootstrap":
                        for step in job["steps"]:
                            if "setup_ci_publisher_python.py" in step.get("run", ""):
                                step["run"] = "python3 scripts/setup_ci_python.py --venv env"
                    else:
                        job["steps"].append({"run": "xcrun simctl list" if mutation == "xcode" else "python3 setup.py --verify-toolchain"})
                    self.assertIn("nightly-aggregate-platform", self.rules(changed, path))

    def test_nightly_jobs_cannot_bypass_the_change_check(self):
        path = policy.LIVE_WORKFLOW
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual("ubuntu-24.04", document["jobs"]["change"]["runs-on"])
        for job_id in ("plan", "aggregate", "ui-archive", "ui-shards", "ui-aggregate", "live-admission", "live-build"):
            with self.subTest(job=job_id, mutation="dropped gate"):
                changed = copy.deepcopy(document)
                changed["jobs"][job_id]["if"] = changed["jobs"][job_id]["if"].replace(policy.NIGHTLY_CHANGE_GATE, "true")
                self.assertIn("nightly-change-gate", self.rules(changed, path))
            for label, replacement in (("or true", f"({policy.NIGHTLY_CHANGE_GATE} || true)"),
                                       ("negated", f"!({policy.NIGHTLY_CHANGE_GATE})"),
                                       ("output only", "needs.change.outputs.run_nightly != 'false'"),
                                       ("any event", policy.NIGHTLY_CHANGE_GATE.replace("github.event_name == 'schedule' && ", "")),
                                       ("no result check", policy.NIGHTLY_CHANGE_GATE.replace("needs.change.result == 'success' && ", "")),
                                       ("top-level or", f"{policy.NIGHTLY_CHANGE_GATE} || github.event_name == 'schedule'")):
                with self.subTest(job=job_id, mutation=label):
                    changed = copy.deepcopy(document)
                    changed["jobs"][job_id]["if"] = changed["jobs"][job_id]["if"].replace(policy.NIGHTLY_CHANGE_GATE, replacement)
                    self.assertIn("nightly-change-gate", self.rules(changed, path))
        for job_id in ("strict", "live-canary", "live-unit"):
            with self.subTest(job=job_id, mutation="status function"):
                changed = copy.deepcopy(document)
                changed["jobs"][job_id]["if"] = "always()"
                self.assertIn("nightly-change-gate", self.rules(changed, path))
        jobs = document["jobs"]
        class Context(dict):
            def __getattr__(self, name):
                return self.get(name, "")
        def runs(job_id, results, event, change_outputs):
            expression = " ".join(jobs[job_id]["if"].split())
            if expression.startswith("${{"):
                expression = expression[3:-2].strip()
            expression = expression.replace("!=", "\0").replace("&&", " and ").replace("||", " or ").replace("!", " not ")
            expression = expression.replace("\0", "!=").replace("cancelled()", "False")
            expression = re.sub(r"needs\.([\w-]+)", r"needs['\1']", expression)
            outputs = {"change": Context(change_outputs), "live-admission": Context(admitted="true"),
                       "ui-archive": Context(run_ui="true"), "plan": Context(matrix="[]")}
            needs = Context({name: Context(result=results.get(name, "skipped"), outputs=outputs.get(name, Context()))
                             for name in jobs})
            return bool(eval(expression, {"__builtins__": {}}, {"needs": needs, "github": Context(event_name=event, ref="refs/heads/main"),
                                                                   "inputs": Context()}))
        def simulate(event, change_result, change_outputs):
            results = {"change": change_result}
            for job_id in ("plan", "live-admission", "live-build", "strict", "live-canary", "live-unit",
                           "ui-archive", "ui-shards", "ui-aggregate", "aggregate"):
                results[job_id] = "success" if runs(job_id, results, event, change_outputs) else "skipped"
            return {job_id for job_id, result in results.items() if result == "success" and job_id != "change"}
        everything = {"plan", "live-admission", "live-build", "strict", "live-canary", "live-unit",
                      "ui-archive", "ui-shards", "ui-aggregate", "aggregate"}
        with self.subTest(scenario="skipped night"):
            self.assertEqual(set(), simulate("schedule", "success", {"run_nightly": "false"}))
        for label, event, result, outputs in (("record upload failed", "schedule", "failure", {}),
                                              ("change cancelled output", "schedule", "failure", {"run_nightly": "false"}),
                                              ("verdict missing", "schedule", "success", {}),
                                              ("dispatch", "workflow_dispatch", "success", {}),
                                              ("dispatch with a skip-looking output", "workflow_dispatch", "success", {"run_nightly": "false"})):
            with self.subTest(scenario=label):
                self.assertEqual(everything, simulate(event, result, outputs))
        for job_id, job in document["jobs"].items():
            if job_id not in policy.NIGHTLY_UNGATED_JOBS:
                with self.subTest(job=job_id, requirement="explicit status condition"):
                    self.assertIn("!cancelled()", job["if"])
                    self.assertIn("change", job["needs"] if isinstance(job["needs"], list) else [job["needs"]])
        jobs = document["jobs"]
        steps = document["jobs"]["change"]["steps"]
        upload = next(index for index, step in enumerate(steps) if str(step.get("uses", "")).startswith("actions/upload-artifact@"))
        for label, mutate in (("verdict before upload", lambda items: items.insert(upload, items.pop(upload + 1))),
                              ("verdict after failure", lambda items: items[upload + 1].update({"if": "${{ always() }}"})),
                              ("upload tolerates a missing record", lambda items: items[upload]["with"].update({"if-no-files-found": "ignore"})),
                              ("upload continues after failure", lambda items: items[upload].update({"if": "${{ always() }}"})),
                              ("job output skips the verdict step", lambda items: None)):
            with self.subTest(job="change", mutation=label):
                changed = copy.deepcopy(document)
                mutate(changed["jobs"]["change"]["steps"])
                if label.startswith("job output"):
                    changed["jobs"]["change"]["outputs"]["run_nightly"] = "${{ steps.decision.outputs.run_nightly }}"
                self.assertIn("nightly-change-gate", self.rules(changed, path))
        with self.subTest(mutation="missing job"):
            changed = copy.deepcopy(document)
            del changed["jobs"]["change"]
            self.assertIn("nightly-change-gate", self.rules(changed, path))
        for mutation in ("runner", "xcode"):
            with self.subTest(job="change", mutation=mutation):
                changed = copy.deepcopy(document)
                if mutation == "runner":
                    changed["jobs"]["change"]["runs-on"] = "xcode-27"
                else:
                    changed["jobs"]["change"]["steps"].append({"run": "xcrun simctl list"})
                self.assertIn("nightly-aggregate-platform", self.rules(changed, path))

    def test_macos_jobs_cannot_survive_cancellation_through_always(self):
        document = workflow()
        for condition in ("always()", "${{ always() && needs.archive.outputs.run_ui == 'true' }}"):
            with self.subTest(condition=condition):
                document["jobs"]["check"]["if"] = condition
                self.assertIn("macos-cancellation", self.rules(document))
        document["jobs"]["check"]["if"] = "${{ !cancelled() && needs.archive.outputs.run_ui == 'true' }}"
        self.assertNotIn("macos-cancellation", self.rules(document))

    def test_cloud_start_requires_a_scheduling_marker_before_post(self):
        path = policy.XCC_ROUTE_WORKFLOW
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        steps = document["jobs"]["start"]["steps"]
        marker = next(index for index, step in enumerate(steps) if step.get("with", {}).get("name", "").startswith("ci-xcc-post-"))
        post = next(index for index, step in enumerate(steps) if step.get("id") == "start")
        steps[marker], steps[post] = steps[post], steps[marker]
        self.assertIn("xcc-post-marker", self.rules(document, path))
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        steps = document["jobs"]["start"]["steps"]
        marker = next(index for index, step in enumerate(steps) if step.get("with", {}).get("name", "").startswith("ci-xcc-post-"))
        del steps[marker]
        self.assertIn("xcc-post-marker", self.rules(document, path))

    def test_failed_ios_reruns_cannot_repeat_successful_tv_through_dependencies(self):
        path = ".github/workflows/ci-ui.yml"
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertNotIn("xcc-dependencies", self.rules(document, path))
        for job in ("cloud-wait", "appletv-shards"):
            changed = copy.deepcopy(document)
            changed["jobs"][job]["needs"] = ["archive", "shards"]
            with self.subTest(job=job):
                self.assertIn("xcc-dependencies", self.rules(changed, path))
        changed = copy.deepcopy(document)
        changed["jobs"]["appletv-shards"]["if"] = changed["jobs"]["appletv-shards"]["if"].replace(
            "needs.archive.result == 'success' && ", "")
        self.assertIn("xcc-dependencies", self.rules(changed, path))

    def test_ui_failure_cannot_cancel_other_partition_results(self):
        path = ".github/workflows/ci-ui.yml"
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertNotIn("ui-fail-fast", self.rules(document, path))
        for job in ("iphone-shards", "ipad-shards", "appletv-shards"):
            changed = copy.deepcopy(document)
            changed["jobs"][job]["strategy"]["fail-fast"] = True
            with self.subTest(job=job):
                self.assertIn("ui-fail-fast", self.rules(changed, path))

    def test_independent_ui_matrices_cannot_take_the_reserved_macos_slot(self):
        path = ".github/workflows/ci-ui.yml"
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertNotIn("ui-capacity", self.rules(document, path))
        document["jobs"]["iphone-shards"]["strategy"]["max-parallel"] = 3
        document["jobs"]["appletv-shards"]["strategy"]["max-parallel"] = 1
        self.assertIn("ui-capacity", self.rules(document, path))
        split = copy.deepcopy(document)
        split['jobs']['iphone-shards']['strategy']['max-parallel'] = 2
        split['jobs']['ipad-shards']['strategy']['max-parallel'] = 1
        self.assertNotIn('ui-capacity', self.rules(split, path))
        split['jobs']['ipad-shards']['strategy']['max-parallel'] = 2
        self.assertIn('ui-capacity', self.rules(split, path))
        split['jobs']['iphone-shards']['strategy']['max-parallel'] = 1
        # The total is still four, but serial iPhone jobs violate the packing budget.
        self.assertIn('ui-capacity', self.rules(split, path))

    def test_packed_ui_requires_independent_device_outputs_and_reports_string_matrices(self):
        from ci_publish_git import DYNAMIC_UI_SHARDS
        root = Path(__file__).resolve().parent.parent
        path = '.github/workflows/ci-ui.yml'
        document = yaml.load((root / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertNotIn('ui-shards', self.rules(document, path))
        grouped = copy.deepcopy(document)
        job = grouped['jobs']['shards'] = grouped['jobs'].pop('iphone-shards')
        del grouped['jobs']['ipad-shards']
        job['strategy'].update({'max-parallel': 3, 'matrix': {'device': ['iphone', 'ipad'],
                               'shard': DYNAMIC_UI_SHARDS['ios']}})
        self.assertIn('ui-shards', self.rules(grouped, path))
        for mutation in ('platform-output', 'string-matrix'):
            bad = copy.deepcopy(document)
            strategy = bad['jobs']['iphone-shards']['strategy']
            if mutation == 'platform-output':
                strategy['matrix']['shard'] = DYNAMIC_UI_SHARDS['ios']
            else:
                strategy['matrix'] = '${{ fromJSON(needs.archive.outputs.matrix) }}'
            with self.subTest(mutation=mutation):
                self.assertIn('ui-shards', self.rules(bad, path))

    def test_accelerated_ui_capacity_only_accepts_independent_trusted_outputs(self):
        from ci_publish_git import UI_CAPACITIES
        path = '.github/workflows/ci-ui.yml'
        document = yaml.load((Path(__file__).parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        owner = 'selection' if 'selection' in document['jobs'] else 'archive'
        expressions = UI_CAPACITIES[owner]
        for step in document['jobs'][owner]['steps']:
            if 'run' in step:
                step['run'] = step['run'].replace('--pack-scoped-ui', '--pack-scoped-ui --scoped-ui-v2')
        for device, expression in expressions.items():
            document['jobs'][device + '-shards']['strategy']['max-parallel'] = expression
            name = device + '_capacity'
            document['jobs'][owner]['outputs'][name] = '${{ steps.select.outputs.' + name + ' }}'
        self.assertNotIn('ui-capacity', self.rules(document, path))
        for mutation in ('wrong-device', 'arbitrary', 'literal-six', 'unbound-output', 'outside-strategy', 'missing-intent'):
            bad = copy.deepcopy(document)
            strategy = bad['jobs']['iphone-shards']['strategy']
            if mutation == 'wrong-device':
                strategy['max-parallel'] = expressions['ipad']
            elif mutation == 'arbitrary':
                strategy['max-parallel'] = '${{ fromJSON(needs.archive.outputs.capacity) }}'
            elif mutation == 'literal-six':
                for device in expressions:
                    bad['jobs'][device + '-shards']['strategy']['max-parallel'] = 2
            elif mutation == 'unbound-output':
                del bad['jobs'][owner]['outputs']['iphone_capacity']
            elif mutation == 'outside-strategy':
                bad['jobs']['iphone-shards']['env'] = {'UNTRUSTED': expressions['iphone']}
            else:
                for step in bad['jobs'][owner]['steps']:
                    if 'run' in step:
                        step['run'] = step['run'].replace(' --scoped-ui-v2', '')
            with self.subTest(mutation=mutation):
                self.assertIn('ui-capacity', self.rules(bad, path))

    def test_ui_matrix_cannot_omit_a_manifest_partition_or_unbind_its_selection(self):
        from ci_publish_git import DYNAMIC_UI_SHARDS
        from ci_ui_shards import MANIFEST_PATH, parse_shard_manifest
        root = Path(__file__).resolve().parent.parent
        path = ".github/workflows/ci-ui.yml"
        document = yaml.load((root / path).read_text(), Loader=policy.WorkflowLoader)
        shards = list(parse_shard_manifest((root / MANIFEST_PATH).read_text())["shards"])
        for job, platform, output in (("iphone-shards", "ios", "iphone"), ("ipad-shards", "ios", "ipad"),
                                      ("appletv-shards", "tvos", "tvos")):
            literal = copy.deepcopy(document)
            literal["jobs"][job]["strategy"]["matrix"]["shard"] = list(shards)
            # Historical full matrices remain valid without the packed intent.
            for step in literal['jobs']['archive']['steps']:
                if 'run' in step:
                    step['run'] = step['run'].replace(' --pack-scoped-ui', '')
            dynamic = copy.deepcopy(document)
            dynamic["jobs"][job]["strategy"]["matrix"]["shard"] = DYNAMIC_UI_SHARDS[output]
            dynamic["jobs"]["archive"]["outputs"].update({name: "${{ steps.select.outputs." + name + " }}"
                                                          for name in (output + "_shards", "run_" + platform)})
            with self.subTest(job=job):
                for accepted in (literal, dynamic):
                    self.assertNotIn("ui-shards", self.rules(accepted, path, ui_shards=shards))
                omitted = copy.deepcopy(literal)
                omitted["jobs"][job]["strategy"]["matrix"]["shard"].pop()
                unbound = copy.deepcopy(dynamic)
                del unbound["jobs"]["archive"]["outputs"][output + "_shards"]
                other = copy.deepcopy(dynamic)
                other["jobs"][job]["strategy"]["matrix"]["shard"] = DYNAMIC_UI_SHARDS["tvos" if platform == "ios" else "ios"]
                for refused in (omitted, unbound, other):
                    self.assertIn("ui-shards", self.rules(refused, path, ui_shards=shards))

    def test_cloud_event_bridge_cannot_receive_secrets_or_execute_pr_code(self):
        root = Path(__file__).resolve().parent.parent
        path = policy.XCC_DISPATCH_WORKFLOW
        document = yaml.load((root / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(document, path), set())
        for mutation in ("branch", "environment", "secret", "checkout", "command", "write"):
            changed = copy.deepcopy(document)
            job = changed["jobs"]["dispatch"]
            if mutation == "branch":
                job["if"] = "always()"
            elif mutation == "environment":
                job["environment"] = "xcode-cloud"
            elif mutation == "secret":
                job["steps"][-1]["env"]["ASC_PRIVATE_KEY"] = "${{ secrets.ASC_PRIVATE_KEY }}"
            elif mutation == "checkout":
                job["steps"][0]["with"]["ref"] = "${{ github.event.workflow_run.head_sha }}"
            elif mutation == "command":
                job["steps"][-1]["run"] += " --workflow other.yml"
            else:
                job["permissions"]["contents"] = "write"
            with self.subTest(mutation=mutation):
                self.assertTrue(self.rules(changed, path))

    def test_cloud_import_forwarder_is_required_and_has_no_environment_or_arbitrary_dispatch(self):
        path = policy.XCC_ROUTE_WORKFLOW
        document = yaml.load((Path(__file__).resolve().parent.parent / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(document, path), set())
        for mutation in ("missing", "branch", "environment", "needs", "write", "secret", "command", "output"):
            changed = copy.deepcopy(document)
            job = changed["jobs"]["dispatch-import"]
            if mutation == "missing":
                del changed["jobs"]["dispatch-import"]
            elif mutation == "branch":
                job["if"] = "always()"
            elif mutation == "environment":
                job["environment"] = "xcode-cloud"
            elif mutation == "needs":
                job["needs"] = "start"
            elif mutation == "write":
                job["permissions"]["contents"] = "write"
            elif mutation == "secret":
                job["steps"][-1]["env"]["ASC_PRIVATE_KEY"] = "${{ secrets.ASC_PRIVATE_KEY }}"
            elif mutation == "command":
                job["steps"][-1]["run"] += " --workflow other.yml"
            else:
                del changed["jobs"]["route"]["outputs"]
            with self.subTest(mutation=mutation):
                self.assertTrue(self.rules(changed, path))

    def test_cloud_router_cannot_bypass_main_context_budget_serialization_or_credential_scope(self):
        root = Path(__file__).resolve().parent.parent
        path = policy.XCC_ROUTE_WORKFLOW
        document = yaml.load((root / path).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(document, path), set())
        for mutation in ("branch", "fork", "parallel", "write", "early-key", "checkout", "upload", "trigger"):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(document)
                job = changed["jobs"]["route"]
                if mutation == "branch":
                    job["if"] = "always()"
                elif mutation == "fork":
                    job["if"] = "github.ref == 'refs/heads/main'"
                elif mutation == "parallel":
                    changed["jobs"]["start"]["concurrency"]["group"] += "-${{ github.run_id }}"
                elif mutation == "write":
                    job["permissions"]["contents"] = "write"
                elif mutation == "early-key":
                    job["env"] = {"KEY": "${{ secrets.ASC_PRIVATE_KEY }}"}
                elif mutation == "checkout":
                    job["steps"][0]["with"]["ref"] = "${{ github.event.workflow_run.head_sha }}"
                elif mutation == "upload":
                    job["steps"][-1]["if"] = "always()"
                else:
                    changed["on"]["pull_request"] = None
                self.assertTrue(self.rules(changed, path))

    def test_cloud_importer_main_context_and_secret_step_cannot_be_weakened(self):
        path = policy.XCC_IMPORT_WORKFLOW
        source = (Path(__file__).resolve().parent.parent / path).read_text()
        document = yaml.load(source, Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(document, path), set())
        for mutation in ("branch", "event", "checkout", "environment", "permissions", "job-secret", "early-secret", "upload"):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(document)
                job = changed["jobs"]["import"]
                if mutation == "branch":
                    job.pop("if")
                elif mutation == "event":
                    changed["on"]["pull_request"] = None
                elif mutation == "checkout":
                    job["steps"][0]["with"]["ref"] = "${{ github.event.pull_request.head.sha }}"
                elif mutation == "environment":
                    job["environment"] = "release"
                elif mutation == "permissions":
                    job["permissions"]["actions"] = "write"
                elif mutation == "job-secret":
                    job["env"] = policy.XCC_BINDINGS
                elif mutation == "early-secret":
                    job["steps"][0]["env"] = policy.XCC_BINDINGS
                else:
                    job["steps"][-1]["with"]["path"] = "${{ github.workspace }}"
                self.assertTrue(self.rules(changed, path))

    def test_live_environment_and_credentials_are_bound_to_guarded_nightly_jobs(self):
        root = Path(__file__).resolve().parent.parent
        source = (root / ".github/workflows/ci-nightly.yml").read_text()
        document = yaml.load(source, Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(document, ".github/workflows/ci-nightly.yml"), set())
        legal = copy.deepcopy(document)
        steps = legal["jobs"]["live-unit"]["steps"]
        steps[0]["name"] = "Check secrets are absent before injection"
        steps[2]["run"] = "# secrets are injected later\n" + steps[2]["run"]
        steps[3]["name"] = "${{ format('{0}', 'secrets') }}"
        steps[4]["name"] = "${{ github.event.inputs.secrets }} ${{ inputs.check-secrets }}"
        steps[5]["name"] = "Check secrets.IMMICH_TEST_SERVER_URL is absent"
        self.assertEqual(self.rules(legal, ".github/workflows/ci-nightly.yml"), set())
        for mutation in ("other-workflow", "unconditional", "job-secret", "early-secret", "wrong-environment",
                         "run-secret", "with-secret", "bracket-secret", "expression-environment",
                         "whole-context", "dynamic-secret", "lowercase-secret", "uppercase-context",
                         "other-secret", "inherited-context", "binding-context", "env-named-if", "implicit-if"):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(document)
                job = changed["jobs"]["live-unit"]
                path = ".github/workflows/ci-nightly.yml"
                if mutation == "other-workflow":
                    path = ".github/workflows/other.yml"
                elif mutation == "unconditional":
                    job.pop("if")
                elif mutation == "job-secret":
                    job["env"] = {"CI_LIVE_KEY": "${{ secrets.IMMICH_TEST_SERVER_API_KEY }}"}
                elif mutation == "early-secret":
                    job["steps"][0]["env"] = {"CI_LIVE_KEY": "${{ secrets.IMMICH_TEST_SERVER_API_KEY }}"}
                elif mutation == "run-secret":
                    job["steps"][0]["run"] = "echo '${{ secrets.IMMICH_TEST_SERVER_URL }}'"
                elif mutation == "with-secret":
                    job["steps"][0]["with"]["ref"] = "${{ secrets.IMMICH_TEST_SERVER_API_KEY }}"
                elif mutation == "bracket-secret":
                    job["steps"][0]["env"] = {"OTHER": "${{ secrets['IMMICH_TEST_SERVER_URL'] }}"}
                elif mutation == "expression-environment":
                    job["environment"] = "${{ inputs.environment }}"
                elif mutation == "whole-context":
                    job["steps"][0]["env"] = {"OTHER": "${{ toJSON(secrets) }}"}
                elif mutation == "dynamic-secret":
                    job["steps"][0]["env"] = {"OTHER": "${{ secrets[format('IMMICH_{0}', 'TEST_SERVER_URL')] }}"}
                elif mutation == "lowercase-secret":
                    job["steps"][0]["env"] = {"OTHER": "${{ secrets.immich_test_server_url }}"}
                elif mutation == "uppercase-context":
                    job["steps"][0]["env"] = {"OTHER": "${{ toJSON(SeCrEtS) }}"}
                elif mutation == "other-secret":
                    job["env"] = {"OTHER": "${{ secrets.UNRELATED }}"}
                elif mutation == "inherited-context":
                    changed["env"] = {"OTHER": "${{ toJSON(secrets) }}"}
                elif mutation == "env-named-if":
                    job["steps"][0]["env"] = {"if": "'${{ toJSON(secrets) }}'"}
                elif mutation == "implicit-if":
                    job["steps"][0]["if"] = "secrets.OTHER != ''"
                elif mutation == "binding-context":
                    step = next(step for step in job["steps"] if step.get("id") == "live")
                    step["env"]["CI_LIVE_URL"] = "${{ toJSON(secrets) }}"
                else:
                    job["environment"] = "test-server"
                self.assertIn("live-credential", self.rules(changed, path))

    def test_ui_verdict_upload_is_limited_to_the_exact_publisher_output(self):
        document = self.trusted()
        upload = {"uses": "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
                  "with": {"name": "ci-ui-verdict-${{ steps.publish.outputs.ui_verdict_tree }}",
                           "path": "${{ runner.temp }}/ci-ui-verdict/verdict.json",
                           "if-no-files-found": "error", "retention-days": 30}}
        document["jobs"]["check"]["steps"].append(upload)
        self.assertNotIn("trusted-action", self.rules(document, TRUSTED))
        for key, value in (("path", "${{ runner.temp }}/**"), ("retention-days", 90),
                           ("name", "ci-ui-verdict-${{ github.sha }}")):
            bad = copy.deepcopy(document)
            bad["jobs"]["check"]["steps"][-1]["with"][key] = value
            with self.subTest(key=key):
                self.assertIn("trusted-action", self.rules(bad, TRUSTED))

    def rules(self, document, path=".github/workflows/example.yml", **options):
        return {item.rule for item in policy.check_workflow(path, yaml.safe_dump(document), **options)}

    def trusted(self):
        document = workflow()
        document["on"] = {"workflow_run": {"workflows": ["ci-gate", "ci-ui"],
                                           "types": ["requested", "in_progress", "completed"]}}
        document["jobs"]["check"]["steps"][0]["with"] = {"ref": "main"}
        document["jobs"]["check"]["runs-on"] = "ubuntu-24.04"
        return document

    def test_main_push_producers_coalesce_by_replacing_only_pending_runs(self):
        root = Path(__file__).resolve().parent.parent
        for path in (".github/workflows/ci-gate.yml", ".github/workflows/ci-ui.yml"):
            document = yaml.load((root / path).read_text(), Loader=policy.WorkflowLoader)
            self.assertNotIn("concurrency-queue", self.rules(document, path))
            for mutation in (
                    lambda doc: doc["concurrency"].update({"cancel-in-progress": True}),
                    lambda doc: doc["concurrency"].update({"cancel-in-progress": False}),
                    lambda doc: doc["concurrency"].update(group=doc["concurrency"]["group"].replace("run_attempt == 1", "true")),
                    lambda doc: doc["concurrency"].update(group="shared"),
                    lambda doc: doc.pop("concurrency"),
                    lambda doc: next(iter(doc["jobs"].values())).update(concurrency={"group": "x", "cancel-in-progress": True})):
                changed = copy.deepcopy(document)
                mutation(changed)
                with self.subTest(path=path):
                    self.assertIn("concurrency-queue", self.rules(changed, path))

    def test_remote_actions_and_reusable_workflows_require_full_commit_pins(self):
        for uses in ["actions/checkout@v4", "owner/repo@main", "owner/repo@abc123",
                     "owner/repo/.github/workflows/test.yml@v1", "${{ inputs.action }}",
                     "docker://alpine:3", "actions/checkout@" + "g" * 40]:
            with self.subTest(uses=uses):
                document = workflow()
                document["jobs"]["check"]["steps"][0]["uses"] = uses
                self.assertIn("action-pin", self.rules(document))
        document = workflow()
        document["jobs"]["check"]["uses"] = "owner/repo/.github/workflows/test.yml@main"
        self.assertIn("action-pin", self.rules(document))

    def test_immutable_actions_and_local_actions_pass(self):
        for uses in [f"actions/checkout@{SHA}", f"owner/repo/subdir@{SHA}",
                     "./.github/actions/check", "docker://alpine@sha256:" + "a" * 64]:
            with self.subTest(uses=uses):
                document = workflow()
                document["jobs"]["check"]["steps"][0]["uses"] = uses
                self.assertEqual(set(), self.rules(document))

    def test_permissions_must_be_explicit_and_valid_at_workflow_or_every_job(self):
        for value in [None, "write-all", "${{ inputs.permissions }}", {"contents": "admin"}]:
            with self.subTest(value=value):
                document = workflow()
                document["permissions"] = value
                self.assertIn("permissions", self.rules(document))
        document = workflow()
        del document["permissions"]
        self.assertIn("permissions", self.rules(document))
        document["jobs"]["check"]["permissions"] = {}
        self.assertEqual(set(), self.rules(document))
        document["jobs"]["other"] = copy.deepcopy(document["jobs"]["check"])
        del document["jobs"]["other"]["permissions"]
        self.assertIn("permissions", self.rules(document))

    def test_each_job_needs_a_bounded_literal_timeout(self):
        for value in [None, 0, -1, 361, True, "5", "${{ inputs.timeout }}"]:
            with self.subTest(value=value):
                document = workflow()
                document["jobs"]["check"]["timeout-minutes"] = value
                self.assertIn("timeout", self.rules(document))
        document = workflow()
        document["jobs"]["other"] = {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]}
        self.assertIn("timeout", self.rules(document))

    def test_approval_wait_cannot_acquire_credentials_or_execute_an_action(self):
        document = {"on": {"workflow_dispatch": None}, "permissions": {}, "jobs": {
            "wait": {"runs-on": "ubuntu-24.04", "timeout-minutes": 5, "permissions": {},
                     "environment": "ci-approval", "steps": [{"run": "/usr/bin/true"}]}}}
        path = ".github/workflows/ci-approval.yml"
        self.assertEqual(self.rules(document, path), set())
        for key, value in (("permissions", {"contents": "read"}),
                           ("env", {"CI_APP_PRIVATE_KEY": "${{ secrets.CI_APP_PRIVATE_KEY }}"}),
                           ("steps", [{"uses": f"actions/checkout@{SHA}", "with": {"ref": "main"}}])):
            with self.subTest(key=key):
                modified = copy.deepcopy(document)
                modified["jobs"]["wait"][key] = value
                self.assertIn("approval-wait", self.rules(modified, path))

    def test_app_key_binding_is_refused_outside_the_guarded_publisher_step(self):
        document = self.trusted()
        document["jobs"]["check"]["steps"] = [{"run": '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_publish.py route',
            "env": {"CI_APP_PRIVATE_KEY": "${{ secrets.CI_APP_PRIVATE_KEY }}"}}]
        self.assertIn("publisher-credential", self.rules(document, TRUSTED))
        document["jobs"]["check"]["environment"] = "ci-publisher"
        self.assertIn("publisher-credential", self.rules(document, TRUSTED))
        document["jobs"]["check"]["steps"][0]["run"] = '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_publish.py publish'
        self.assertNotIn("publisher-credential", self.rules(document, TRUSTED))
        for scope in ("workflow", "job"):
            for binding in ("CI_APP_ID", "CI_APP_PRIVATE_KEY"):
                with self.subTest(scope=scope, binding=binding):
                    modified = copy.deepcopy(document)
                    owner = modified if scope == "workflow" else modified["jobs"]["check"]
                    owner["env"] = {binding: policy.PUBLISHER_BINDINGS[binding]}
                    self.assertIn("publisher-credential", self.rules(modified, TRUSTED))

    def test_publisher_history_runner_and_approval_queue_contracts_fail_closed(self):
        root = Path(__file__).parents[1]
        publisher = yaml.load((root / TRUSTED).read_text(), Loader=policy.WorkflowLoader)
        self.assertEqual(self.rules(publisher, TRUSTED), set())
        shallow = copy.deepcopy(publisher)
        del shallow["jobs"]["publish"]["steps"][0]["with"]["fetch-depth"]
        self.assertIn("publisher-history", self.rules(shallow, TRUSTED))
        expensive = copy.deepcopy(publisher)
        expensive["jobs"]["admission"]["runs-on"] = "xcode-27"
        self.assertIn("publisher-runner", self.rules(expensive, TRUSTED))
        redundant = copy.deepcopy(publisher)
        del redundant["jobs"]["admission"]["steps"][-1]["if"]
        self.assertIn("publisher-admission", self.rules(redundant, TRUSTED))
        for path in (".github/workflows/ci-approval.yml", ".github/workflows/ci-approve.yml"):
            document = yaml.load((root / path).read_text(), Loader=policy.WorkflowLoader)
            self.assertEqual(self.rules(document, path), set())
            document["jobs"]["record"]["concurrency"] = {"group": "ci-state-pr-${{ inputs.pull_request }}", "cancel-in-progress": False}
            self.assertIn("approval-queue", self.rules(document, path))

    def probe(self):
        document = self.trusted()
        document["name"] = "ci-probe"
        document["on"] = {"schedule": [{"cron": "17 8 * * *"}], "workflow_dispatch": None}
        document["permissions"] = {}
        document["jobs"]["check"]["permissions"] = {"contents": "read", "issues": "write"}
        document["jobs"]["check"]["steps"].extend([
            {"run": '/usr/bin/python3 scripts/setup_ci_python.py --python /usr/bin/python3 --venv "$RUNNER_TEMP/ci-python"'},
            {"run": "/usr/bin/python3 scripts/probe_ci_toolchain.py", "env": {
                "CI_PROBE_TOKEN": "${{ github.token }}",
                "CI_PROBE_SIMULATE_MISSING_PIN": "${{ inputs.simulate_missing_pin || false }}",
            }},
        ])
        return document

    def test_probe_grants_only_its_named_trusted_entry_points_and_bindings(self):
        document = self.probe()
        self.assertEqual(set(), self.rules(document, ".github/workflows/ci-probe.yml"))
        self.assertIn("issue-write", self.rules(document))
        self.assertIn("trusted-run", self.rules(document, TRUSTED))
        for mutation, rule in [
            ({"name": "renamed"}, "probe-contract"),
            ({"on": {"pull_request": None}}, "probe-contract"),
            ({"on": {"workflow_dispatch": None}}, "probe-contract"),
            ({"permissions": {"issues": "write"}}, "probe-contract"),
        ]:
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(document)
                changed.update(mutation)
                self.assertIn(rule, self.rules(changed, ".github/workflows/ci-probe.yml"))
        for key, value in [("contents", "write"), ("actions", "write"), ("id-token", "write")]:
            with self.subTest(permission=key):
                changed = copy.deepcopy(document)
                changed["jobs"]["check"]["permissions"][key] = value
                self.assertIn("probe-contract", self.rules(changed, ".github/workflows/ci-probe.yml"))
        for script in ["/usr/bin/python3 scripts/probe_ci_toolchain.py --root ci-artifacts",
                       "/usr/bin/python3 scripts/probe_ci_toolchain.py; echo unsafe"]:
            with self.subTest(script=script):
                changed = copy.deepcopy(document)
                changed["jobs"]["check"]["steps"][-1]["run"] = script
                self.assertIn("trusted-run", self.rules(changed, ".github/workflows/ci-probe.yml"))
        changed = copy.deepcopy(document)
        changed["jobs"]["check"]["steps"][-1]["env"]["CI_PROBE_TOKEN"] = "${{ secrets.OTHER_TOKEN }}"
        self.assertIn("trusted-environment", self.rules(changed, ".github/workflows/ci-probe.yml"))
        changed = copy.deepcopy(document)
        changed["jobs"]["check"]["steps"][0]["with"]["ref"] = "${{ github.sha }}"
        self.assertIn("trusted-checkout", self.rules(changed, ".github/workflows/ci-probe.yml"))

    def test_issue_write_is_reserved_for_probe_and_report(self):
        for path in [".github/workflows/example.yml", TRUSTED, ".github/workflows/ci-probe.yaml"]:
            with self.subTest(path=path):
                document = workflow()
                document["permissions"]["issues"] = "write"
                self.assertIn("issue-write", self.rules(document, path))
        document = self.trusted()
        document["permissions"]["issues"] = "write"
        self.assertNotIn("issue-write", self.rules(document, ".github/workflows/ci-report.yml"))

    def test_privileged_triggers_use_exact_paths_in_all_yaml_forms(self):
        for event in ["pull_request_target", ["pull_request_target"], {"pull_request_target": None}]:
            with self.subTest(event=event):
                document = workflow()
                document["on"] = event
                self.assertIn("pull-request-target", self.rules(document))
                self.assertEqual(set(), self.rules(document, policy.PRIVACY_WORKFLOW))
                self.assertIn("pull-request-target", self.rules(document, ".github/workflows/privacy-preflight.yaml"))
        document = self.trusted()
        self.assertEqual(set(), self.rules(document, TRUSTED))
        self.assertIn("workflow-run", self.rules(document))
        for event in ["workflow_run", ["workflow_run"]]:
            document["on"] = event
            self.assertIn("workflow-run", self.rules(document, TRUSTED))

    def test_workflow_run_requires_named_producers_and_valid_event_types(self):
        for configuration in [{}, {"workflows": ["*"]}, {"workflows": ["ci-gate", "untrusted"]},
                              {"workflows": "ci-gate"}, {"workflows": ["ci-gate"], "types": ["unknown"]}]:
            with self.subTest(configuration=configuration):
                document = self.trusted()
                document["on"]["workflow_run"] = configuration
                self.assertIn("workflow-run", self.rules(document, TRUSTED))
        document = self.trusted()
        document["on"]["workflow_run"] = {"workflows": ["ci-nightly"], "types": ["completed"]}
        self.assertNotIn("workflow-run", self.rules(document, ".github/workflows/ci-report.yml"))

    def test_reporter_rejects_write_grants_environments_branch_code_and_unbounded_retention(self):
        document = {"name": "ci-report", "on": {"schedule": [{"cron": "30 8 * * *"}],
                    "workflow_dispatch": {"inputs": {"reset_history": {
                        "description": "Maintainer-only explicit bootstrap or reset of reporting history",
                        "required": False, "default": False, "type": "boolean"}}},
                    "workflow_run": {"workflows": ["ci-nightly"], "types": ["completed"], "branches": ["main"]}},
                    "permissions": {}, "jobs": {"report": {"if": "github.ref == 'refs/heads/main' && "
                    "(github.event_name != 'workflow_run' || "
                    "(github.event.workflow_run.head_repository.full_name == github.repository && github.event.workflow_run.head_branch == 'main' && "
                    "((github.event.workflow_run.name == 'ci-nightly' && contains(fromJSON('[\"schedule\",\"workflow_dispatch\"]'), github.event.workflow_run.event)) || "
                    "(contains(fromJSON('[\"ci-gate\",\"ci-ui\"]'), github.event.workflow_run.name) && github.event.workflow_run.event == 'push'))))",
                    "runs-on": "ubuntu-24.04", "timeout-minutes": 30,
                    "permissions": {"contents": "read", "actions": "read", "pull-requests": "read", "issues": "write"},
                    "concurrency": {"group": "ci-report-state", "cancel-in-progress": False},
                    "steps": [{"uses": "actions/checkout@" + SHA, "with": {"ref": "main", "fetch-depth": 0}},
                              {"run": '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_report.py --phase collect',
                               "env": {"CI_REPORT_TOKEN": "${{ github.token }}"}},
                              {"if": "success()", "uses": "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
                               "with": {"name": "ci-report-daily-${{ github.run_id }}-${{ github.run_attempt }}",
                                        "path": "${{ runner.temp }}/ci-report/daily", "if-no-files-found": "error", "retention-days": 90}},
                              {"if": "success()", "run": '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_report.py --phase sync',
                               "env": {"CI_REPORT_TOKEN": "${{ github.token }}"}}]}}}
        document["on"]["workflow_dispatch"]["inputs"]["health_month"] = {
            "description": "Optional UTC health month (YYYY-MM); scheduled collection reports the previous month on day 1",
            "required": False, "default": "", "type": "string"}
        document["jobs"]["report"]["steps"].insert(3, {
            "if": "success() && steps.collect.outputs.health_month != ''",
            "uses": "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            "with": {"name": "ci-report-health-${{ steps.collect.outputs.health_month }}-${{ github.run_id }}-${{ github.run_attempt }}",
                     "path": "${{ runner.temp }}/ci-report/health", "if-no-files-found": "error", "retention-days": 90}})
        self.assertEqual(set(), self.rules(document, policy.REPORT_WORKFLOW))
        for mutate in (lambda job: job["permissions"].update(actions="write"),
                       lambda job: job.update(environment="ci-publisher"),
                       lambda job: job.update({"if": "github.ref == 'refs/heads/main'"}),
                       lambda job: job.update({"if": job["if"].replace("head_repository.full_name == github.repository", "head_repository.full_name != github.repository")}),
                       lambda job: job.update({"if": job["if"].replace("event == 'push'", "event == 'pull_request'")}),
                       lambda job: job["steps"][2].update({"if": "always()"}),
                       lambda job: job["steps"][3].update({"if": "always()"}),
                       lambda job: job["steps"].reverse(),
                       lambda job: job["steps"][0]["with"].update(ref="${{ github.event.workflow_run.head_sha }}"),
                       lambda job: job.update(concurrency={"group": "ci-report-state", "cancel-in-progress": True})):
            changed = copy.deepcopy(document)
            mutate(changed["jobs"]["report"])
            self.assertIn("report-contract", self.rules(changed, policy.REPORT_WORKFLOW))
        changed = copy.deepcopy(document)
        changed["on"]["workflow_run"].pop("branches")
        self.assertIn("report-contract", self.rules(changed, policy.REPORT_WORKFLOW))

    def test_trusted_checkout_rejects_pr_refs_shas_and_indirection(self):
        for ref in ["refs/pull/123/head", "refs/pull/123/merge", "${{ github.event.pull_request.head.sha }}",
                    "${{ github.event.workflow_run.head_sha }}", "${{ github.sha }}", "${{ env.REF }}",
                    "${{ inputs.sha }}", "abc123", "feature", {"head": "sha"}]:
            with self.subTest(ref=ref):
                document = self.trusted()
                document["jobs"]["check"]["steps"][0]["with"]["ref"] = ref
                self.assertIn("trusted-checkout", self.rules(document, TRUSTED))
        document = self.trusted()
        document["jobs"]["check"]["steps"][0]["with"]["repository"] = "${{ github.event.pull_request.head.repo.full_name }}"
        self.assertIn("trusted-checkout", self.rules(document, TRUSTED))

    def test_trusted_checkout_accepts_default_branch_and_privacy_base_only(self):
        for ref in ["main", "refs/heads/main", "${{ github.event.repository.default_branch }}"]:
            document = self.trusted()
            document["jobs"]["check"]["steps"][0]["with"]["ref"] = ref
            self.assertEqual(set(), self.rules(document, TRUSTED))
        document = workflow()
        document["on"] = {"pull_request_target": None}
        document["jobs"]["check"]["steps"][0]["with"] = {"ref": "${{ github.event.pull_request.base.sha }}"}
        self.assertEqual(set(), self.rules(document, policy.PRIVACY_WORKFLOW))
        self.assertIn("trusted-checkout", self.rules(document, TRUSTED))

    def test_trusted_shell_cannot_materialize_pr_code_but_can_fetch_objects(self):
        for command in ["git checkout $HEAD_SHA", "git switch branch", "git reset --hard FETCH_HEAD",
                        "gh pr checkout 123", "git worktree add /tmp/pr FETCH_HEAD"]:
            with self.subTest(command=command):
                document = self.trusted()
                document["jobs"]["check"]["steps"].append({"run": command})
                self.assertIn("trusted-run", self.rules(document, TRUSTED))
        document = workflow()
        document["on"] = {"pull_request_target": None}
        document["jobs"]["check"]["steps"].append({"run": policy.PRIVACY_OBJECT_FETCH})
        self.assertEqual(set(), self.rules(document, policy.PRIVACY_WORKFLOW))
        document["jobs"]["check"]["steps"][-1]["run"] += "\ngit checkout FETCH_HEAD"
        self.assertIn("trusted-run", self.rules(document, policy.PRIVACY_WORKFLOW))

    def test_trusted_artifacts_may_be_read_as_data_but_never_executed(self):
        for command in ["bash ci-artifacts/report.sh", "python3 ci-artifacts/report.py", "./ci-artifacts/run",
                        "source ci-artifacts/env", "chmod +x ci-artifacts/run", "eval $(cat ci-artifacts/code)",
                        "cat ci-artifacts/code | sh", "cd ci-artifacts && ./run", "bash $PAYLOAD",
                        "cat ci-artifacts/code | python3", "cat ci-artifacts/code | /usr/bin/ruby",
                        ". ci-artifacts/env", "echo safe\n./ci-artifacts/run", "env bash ci-artifacts/run",
                        "exec ./ci-artifacts/run", "python3 -c 'import runpy; runpy.run_path(path)'",
                        "chmod +x $PAYLOAD"]:
            with self.subTest(command=command):
                document = self.trusted()
                document["jobs"]["check"]["steps"].extend([
                    {"uses": f"actions/download-artifact@{SHA}", "with": {"path": "ci-artifacts"}},
                    {"run": command},
                ])
                self.assertIn("trusted-run", self.rules(document, TRUSTED))
        document = self.trusted()
        document["jobs"]["check"]["steps"].extend([
            {"uses": f"actions/download-artifact@{SHA}", "with": {"path": "ci-artifacts"}},
            {"run": "python3 scripts/read_summary.py --input ci-artifacts/summary.json"},
        ])
        self.assertIn("trusted-run", self.rules(document, TRUSTED))
        document["jobs"]["check"]["steps"][-1]["run"] = "/usr/bin/python3 scripts/check_workflow_policy.py"
        self.assertEqual(set(), self.rules(document, TRUSTED))

    def test_trusted_artifact_downloads_cannot_overwrite_the_checkout(self):
        for path in [None, ".", "scripts", "ci-artifacts/../scripts", "${{ github.workspace }}", "$DEST"]:
            with self.subTest(path=path):
                document = self.trusted()
                document["jobs"]["check"]["steps"].append({"uses": f"actions/download-artifact@{SHA}", "with": {"path": path}})
                self.assertIn("artifact-execution", self.rules(document, TRUSTED))

    def test_inline_action_scripts_cannot_evaluate_artifact_contents(self):
        document = self.trusted()
        document["jobs"]["check"]["steps"].append({"uses": f"actions/github-script@{SHA}", "with": {
            "script": "eval(require('fs').readFileSync('ci-artifacts/code.js', 'utf8'))"}})
        self.assertIn("artifact-execution", self.rules(document, TRUSTED))

    def test_inline_downloads_cannot_bypass_artifact_isolation(self):
        for script in ["gh run download 123 && bash report.sh",
                       "curl -L https://api.github.com/repos/org/repo/actions/artifacts/123/zip -o payload.zip",
                       "await github.rest.actions.downloadArtifact({artifact_id: 123})"]:
            with self.subTest(script=script):
                document = self.trusted()
                document["jobs"]["check"]["steps"].append({"run": script})
                self.assertIn("trusted-run", self.rules(document, TRUSTED))

    def test_protected_environments_are_bound_to_named_workflows(self):
        for environment, allowed in [("ci-publisher", TRUSTED), ("ci-approval", ".github/workflows/ci-approval.yml"),
                                     ("release", ".github/workflows/ci-release.yml")]:
            for value in [environment, environment.upper(), {"name": environment}]:
                with self.subTest(value=value):
                    document = workflow()
                    document["jobs"]["check"]["steps"][0]["with"] = {"ref": "main"}
                    document["jobs"]["check"]["environment"] = value
                    self.assertIn("environment", self.rules(document))
                    self.assertNotIn("environment", self.rules(document, allowed))
        document = workflow()
        document["jobs"]["check"]["environment"] = "${{ inputs.environment }}"
        self.assertIn("environment", self.rules(document))

    def test_trusted_artifacts_cannot_be_injected_through_loader_environment(self):
        for key, value in [("PATH", "ci-artifacts:$PATH"), ("BASH_ENV", "ci-artifacts/env"),
                           ("PYTHONPATH", "ci-artifacts"), ("NODE_OPTIONS", "--require ci-artifacts/init.js"),
                           ("ENV", "${{ steps.download.outputs.path }}")]:
            with self.subTest(key=key):
                document = self.trusted()
                document["jobs"]["check"]["steps"].append({"uses": f"actions/download-artifact@{SHA}", "with": {"path": "ci-artifacts"}})
                document["env"] = {key: value}
                self.assertIn("artifact-execution", self.rules(document, TRUSTED))

    def test_malformed_or_ambiguous_yaml_fails_closed(self):
        for source in ["on: [", "on: pull_request\non: push", "[]", "", "jobs: {}", "on: 7",
                       "on: pull_request\njobs: []", "!!python/object:os.system {}",
                       "on: &event pull_request\nother: *event", "on: pull_request\n---\non: push"]:
            with self.subTest(source=source):
                self.assertIn("workflow-format", {item.rule for item in policy.check_workflow(TRUSTED, source)})

    def test_reviewed_execution_and_checkout_bypasses_fail_closed(self):
        for review, step, path, expected in [
            ("R1", {"run": "python3 < ci-artifacts/code.py"}, TRUSTED, "trusted-run"),
            ("R2", {"uses": "./ci-artifacts/action"}, TRUSTED, "trusted-action"),
            ("R3", {"run": 'git -C "$GITHUB_WORKSPACE" checkout "$PR_HEAD_SHA"'}, TRUSTED, "trusted-run"),
            ("R4", {"uses": f"actions/checkout@{SHA}"}, policy.PRIVACY_WORKFLOW, "trusted-checkout"),
        ]:
            with self.subTest(review=review):
                document = workflow() if review == "R4" else self.trusted()
                if review == "R4":
                    document["jobs"]["check"]["steps"] = [step]
                else:
                    document["jobs"]["check"]["steps"].extend([
                        {"uses": f"actions/download-artifact@{SHA}", "with": {"path": "ci-artifacts"}}, step,
                    ])
                self.assertIn(expected, self.rules(document, path))

    def test_trusted_allowlists_reject_unreviewed_actions_arguments_and_execution_settings(self):
        for step, expected in [
            ({"uses": f"owner/tool@{SHA}"}, "trusted-action"),
            ({"uses": "./.github/actions/downloads/payload"}, "trusted-action"),
            ({"uses": f"actions/checkout@{SHA}", "with": {"ref": "main", "path": "ci-artifacts"}}, "trusted-action"),
            ({"run": "/usr/bin/python3 scripts/check_workflow_policy.py --root ci-artifacts"}, "trusted-run"),
            ({"run": "pwd", "working-directory": "ci-artifacts"}, "trusted-run"),
            ({"run": "pwd", "shell": "bash --rcfile ci-artifacts/env {0}"}, "trusted-run"),
            ({"run": "pwd", "env": {"GIT_SSH_COMMAND": "ci-artifacts/run"}}, "trusted-environment"),
        ]:
            with self.subTest(step=step):
                document = self.trusted()
                document["jobs"]["check"]["steps"].append(step)
                self.assertIn(expected, self.rules(document, TRUSTED))
        for override in [{"defaults": {"run": {"working-directory": "ci-artifacts"}}},
                         {"container": "alpine"}, {"services": {"payload": {"image": "alpine"}}}]:
            with self.subTest(override=override):
                document = self.trusted()
                document["jobs"]["check"].update(override)
                self.assertIn("trusted-run", self.rules(document, TRUSTED))
        document = self.trusted()
        document["jobs"]["check"]["steps"].extend([
            {"run": "git rev-parse HEAD"}, {"uses": "./.github/actions/check"},
            {"run": "/usr/bin/python3 scripts/check_workflow_policy.py --root ."},
        ])
        self.assertEqual(set(), self.rules(document, TRUSTED))
        for event in ["pull_request", ["pull_request_target", "pull_request"],
                      {"pull_request_target": None, "workflow_dispatch": None}]:
            for ref in [None, "${{ github.event.pull_request.base.sha }}"]:
                with self.subTest(event=event, ref=ref):
                    document = workflow()
                    document["on"] = event
                    document["jobs"]["check"]["steps"][0]["with"] = {"ref": ref}
                    self.assertIn("trusted-checkout", self.rules(document, policy.PRIVACY_WORKFLOW))


if __name__ == "__main__":
    unittest.main()
