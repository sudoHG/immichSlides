"""Guard inventory, announcement and issue decisions without network or credentials."""

import base64
import copy
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import probe_ci_toolchain as probe


class ToolchainProbeTests(unittest.TestCase):
    def setUp(self):
        self.pins = {"runner": "xcode-27", "python": "3.9.6", "xcode": {
            "version": "27.0", "build": "test-build", "developer_dir": "/synthetic/Xcode.app/Contents/Developer"},
            "simulators": {
                "ios": {"runtime": "ios-runtime", "version": "27.0", "build": "ios-build"},
                "tvos": {"runtime": "tvos-runtime", "version": "27.0", "build": "tvos-build"}}}

    def announcement(self, breaking, title="[macOS] Xcode removal"):
        return {"title": title, "body": "### Breaking changes\n" + breaking +
                "\n### Runner images affected\n- [x] Xcode 27 Arm64\n- [ ] macOS 15\n",
                "html_url": "https://github.com/actions/runner-images/issues/123",
                "state": "open", "labels": [{"name": "Announcement"}]}

    def test_open_announcements_mentioning_xcode_and_pinned_major_warn_without_interpreting_prose(self):
        # Replay historical announcements as open, as they were when first announced.
        fixtures = [
            ("14.3", 10703,
             "[macOS] Support policy changes; Xcode 14 and 16 will be removed from macOS 14 on November 4",
             "Starting from the specified date, all minor versions of `Xcode 14` and `Xcode 16` "
             "will be removed from the `macOS-14` image."),
            ("13.0", 4355,
             "[macOS Big Sur] Xcode 13 beta will be removed and Xcode 13.1 set as default on November, 15",
             "- Xcode 13 beta, which is available on `/Applications/Xcode_13.0_beta.app` path, will be removed.\n"
             "- Xcode 13.1 will be set as the default one."),
            ("26.0.1", 13570,
             "[macOS] Deprecation of simulator runtimes for Xcode 26.0.1 on macOS 15 on January 26th",
             "Default Xcode 26.0.1 runtimes existing in the image will be removed, namely:\n"
             '"install_runtimes": [{ "iOS": ["26.0"] }, { "tvOS": ["26.0"] }]'),
        ]
        cases = [
            (self.announcement("Xcode 27.0 will be removed."), True),
            (self.announcement("Xcode 27.0 remains installed. OpenSSL 3 will be removed.",
                               "[macOS] OpenSSL removal on Xcode 27"), True),
            (self.announcement("Xcode 27.1 will be installed.", "[macOS] Xcode update"), True),
            (self.announcement("Xcode 26.4 will be removed.") | {"body": "Xcode 26.4 will be removed."}, False),
            (self.announcement("Xcode 27.0 will be removed.") | {"body":
                "Xcode 27.0 will be removed.\n- [ ] Xcode 27 Arm64\n- [x] macOS 15"}, True),
            (self.announcement("Supported version: **27**", title="Changes to xcode"), True),
            (self.announcement("Xcode 127 and Xcode 270 are supported.") |
                {"body": "Xcode 127 and Xcode 270 are supported."}, False),
            (self.announcement("Python 27 is supported", title="Python update") |
                {"body": "Python 27 is supported"}, False),
            (self.announcement("Xcode 27 changes") | {"state": "closed"}, False),
            (self.announcement("Xcode 27 changes") | {"labels": []}, False),
            (self.announcement("Xcode 27 changes") | {"pull_request": {}}, False),
        ]
        cases = [(self.pins, issue, expected) for issue, expected in cases]
        for version, number, title, body in fixtures:
            pins = dict(self.pins, xcode=dict(self.pins["xcode"], version=version))
            issue = self.announcement(body, title=title) | {
                "html_url": f"https://github.com/actions/runner-images/issues/{number}"}
            cases.append((pins, issue, True))
        for pins, issue, expected in cases:
            with self.subTest(pin=pins["xcode"]["version"], issue=issue):
                findings = probe.possible_announcements(pins, [issue])
                self.assertEqual(expected, bool(findings))
                if expected:
                    self.assertIn(issue["html_url"], findings[0])

    def test_inventory_requires_exact_xcode_and_every_available_pinned_runtime(self):
        import plistlib
        with tempfile.TemporaryDirectory() as directory:
            pins = copy.deepcopy(self.pins)
            contents = Path(directory) / "Xcode.app/Contents"
            pins["xcode"]["developer_dir"] = str(contents / "Developer")
            self.assertTrue(probe.inventory_findings(pins))
            (contents / "Developer").mkdir(parents=True)
            runtimes = [{"identifier": pin["runtime"], "isAvailable": True,
                         "version": pin["version"], "buildversion": pin["build"]}
                        for pin in pins["simulators"].values()]
            for version, build, expected in [("27.0", "test-build", False),
                                              ("27.0", "other-build", True), ("27.1", "test-build", True)]:
                (contents / "version.plist").write_bytes(plistlib.dumps({
                    "CFBundleShortVersionString": version, "ProductBuildVersion": build}))
                with patch.object(probe, "run", return_value=json.dumps({"runtimes": runtimes})) as listing:
                    self.assertEqual(expected, bool(probe.inventory_findings(pins)))
                    if not expected:
                        self.assertEqual(["xcrun", "simctl", "list", "runtimes", "--json"], listing.call_args.args[0])
                        self.assertEqual(pins["xcode"]["developer_dir"], listing.call_args.kwargs["env"]["DEVELOPER_DIR"])
                    else:
                        listing.assert_not_called()
            (contents / "version.plist").write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": "27.0", "ProductBuildVersion": "test-build"}))
            for index, platform in enumerate(pins["simulators"]):
                for mutation in [{"isAvailable": False}, {"version": "27.1"},
                                 {"buildversion": "other-build"}, {"identifier": "other-runtime"}]:
                    changed = copy.deepcopy(runtimes)
                    changed[index].update(mutation)
                    with self.subTest(platform=platform, mutation=mutation), \
                         patch.object(probe, "run", return_value=json.dumps({"runtimes": changed})):
                        self.assertIn(platform, probe.inventory_findings(pins)[0])
                with self.subTest(platform=platform, missing=True), \
                     patch.object(probe, "run", return_value=json.dumps({"runtimes": runtimes[:index] + runtimes[index + 1:]})):
                    self.assertIn(platform, probe.inventory_findings(pins)[0])
            with patch.object(probe, "run", side_effect=OSError("cannot read inventory")):
                with self.assertRaises(OSError):
                    probe.inventory_findings(pins)

    def test_upstream_toolset_absence_is_an_early_warning_not_proof_of_runner_inventory(self):
        api = Mock()
        def manifest(version):
            return {"encoding": "base64", "html_url": "https://github.com/actions/runner-images/blob/main/images/macos/toolsets/toolset-xcode-27.json",
                    "content": base64.b64encode(json.dumps({
                "xcode": {"arm64": {"versions": [{"version": version, "install_runtimes": "default"}]}}}
            ).encode()).decode()}
        for version, expected in [("27.0+test-build", False), ("27.0+other-build", True), ("27.1+test-build", True)]:
            with self.subTest(version=version):
                api.request.return_value = manifest(version)
                findings = probe.toolset_findings(self.pins, api)
                self.assertEqual(expected, bool(findings))
                self.assertEqual(("GET", "repos/actions/runner-images/contents/images/macos/toolsets/toolset-xcode-27.json?ref=main"),
                                 api.request.call_args.args)
                if expected:
                    self.assertIn("toolset-xcode-27.json", findings[0])
        api.request.return_value = {"encoding": "base64", "content": "not base64"}
        with self.assertRaises(ValueError):
            probe.toolset_findings(self.pins, api)

    def test_public_announcement_reads_do_not_send_the_repository_issue_token(self):
        with patch.object(probe.urllib.request, "urlopen", return_value=io.BytesIO(b"[]")) as opening:
            self.assertEqual([], probe.GitHubAPI().pages(probe.UPSTREAM, {"state": "open"}))
            request = opening.call_args.args[0]
            self.assertIsNone(request.get_header("Authorization"))

    def test_present_pin_is_quiet_and_missing_and_possible_signals_have_distinct_issues(self):
        for signal, findings in [("missing", []), ("possible", []),
                                 ("missing", ["Pinned runtime missing"]),
                                 ("possible", ["Announcement: https://example.org/1", "Announcement: https://example.org/2"])]:
            with self.subTest(signal=signal, findings=findings):
                api = Mock()
                api.pages.return_value = []
                api.request.return_value = {"number": 123, "html_url": "https://example.org/123"}
                outcome = probe.report_findings(api, "owner/repo", self.pins, findings, "https://example.org/run", signal=signal)
                if findings:
                    self.assertEqual("opened", outcome["action"])
                    self.assertEqual("POST", api.request.call_args.args[0])
                    payload = api.request.call_args.args[2]
                    self.assertIn("pinned toolchain missing" if signal == "missing" else "possible toolchain change - please check",
                                  payload["title"])
                    for finding in findings:
                        self.assertIn(finding, payload["body"])
                    api.request.assert_called_once()
                else:
                    self.assertEqual("quiet", outcome["action"])
                    api.pages.assert_not_called()
                    api.request.assert_not_called()

    def test_existing_bot_issue_is_updated_and_simulation_cannot_change_real_tracking_issue(self):
        api = Mock()
        marker = probe.issue_marker(self.pins, "missing", False)
        real = {"number": 10, "body": marker, "user": {"login": "github-actions[bot]"},
                "html_url": "https://example.org/10"}
        api.pages.return_value = [real]
        api.request.return_value = real
        outcome = probe.report_findings(api, "owner/repo", self.pins, ["missing"], "https://example.org/run")
        self.assertEqual("updated", outcome["action"])
        self.assertEqual(("PATCH", "repos/owner/repo/issues/10"), api.request.call_args.args[:2])
        possible_marker = probe.issue_marker(self.pins, "possible", False)
        possible = real | {"number": 12, "body": possible_marker}
        changed_pin = dict(self.pins, xcode=dict(self.pins["xcode"], version="27.1", build="next-build"))
        self.assertEqual(possible_marker, probe.issue_marker(changed_pin, "possible", False))
        api.pages.return_value = [real, possible]
        probe.report_findings(api, "owner/repo", changed_pin, ["early warning"], "https://example.org/run", signal="possible")
        self.assertEqual(("PATCH", "repos/owner/repo/issues/12"), api.request.call_args.args[:2])
        api.pages.return_value = [real]
        api.reset_mock()
        probe.report_findings(api, "owner/repo", self.pins, ["missing"], "https://example.org/run", simulated=True)
        self.assertEqual("POST", api.request.call_args.args[0])
        self.assertIn("SIMULATION", api.request.call_args.args[2]["title"])
        simulation = real | {"number": 13, "body": probe.issue_marker(self.pins, "missing", True)}
        api.pages.return_value = [real, simulation]
        probe.report_findings(api, "owner/repo", self.pins, ["missing"], "https://example.org/run", simulated=True)
        self.assertEqual(("PATCH", "repos/owner/repo/issues/13"), api.request.call_args.args[:2])
        api.pages.return_value = [real, real | {"number": 11}]
        with self.assertRaises(ValueError):
            probe.report_findings(api, "owner/repo", self.pins, ["missing"], "https://example.org/run")

    def test_context_rejects_wrong_event_ref_workflow_or_dispatch_actor_before_api_access(self):
        environment = {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_WORKFLOW_REF": "owner/repo/.github/workflows/ci-probe.yml@refs/heads/main",
                       "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_ACTOR": "owner"}
        event = {"repository": {"full_name": "owner/repo", "default_branch": "main", "owner": {"login": "owner"}}}
        self.assertEqual("owner/repo", probe.validate_context(environment, event))
        for key, value in [("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_REF", "refs/heads/feature"),
                           ("GITHUB_WORKFLOW_REF", "owner/repo/.github/workflows/other.yml@refs/heads/main"),
                           ("GITHUB_ACTOR", "contributor")]:
            with self.subTest(key=key):
                with self.assertRaises(ValueError):
                    probe.validate_context(environment | {key: value}, event)

    def test_manual_simulation_reports_separately_and_network_failure_cannot_be_quiet(self):
        environment = {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_WORKFLOW_REF": "owner/repo/.github/workflows/ci-probe.yml@refs/heads/main",
                       "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_ACTOR": "owner",
                       "GITHUB_EVENT_PATH": "/event.json", "CI_PROBE_SIMULATE_MISSING_PIN": "true",
                       "CI_PROBE_TOKEN": "synthetic-test-value", "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}
        event = {"repository": {"full_name": "owner/repo", "default_branch": "main", "owner": {"login": "owner"}}}
        with patch.dict(os.environ, environment, clear=True), \
             patch.object(Path, "read_text", return_value=json.dumps(event)), \
             patch.object(probe, "load_pins", return_value=self.pins), \
             patch.object(probe, "verify_python"), \
             patch.object(probe, "inventory_findings", side_effect=lambda _: []), \
             patch.object(probe, "toolset_findings", return_value=[]), \
             patch.object(probe, "GitHubAPI") as api_class:
            api, upstream = Mock(), Mock()
            api_class.side_effect = lambda token=None: api if token else upstream
            api.pages.return_value = []
            upstream.pages.return_value = []
            api.request.return_value = {"html_url": "https://example.org/123"}
            self.assertEqual(0, probe.main())
            self.assertIn("SIMULATION", api.request.call_args.args[2]["title"])
            api.reset_mock()
            os.environ["CI_PROBE_SIMULATE_MISSING_PIN"] = "false"
            self.assertEqual(0, probe.main())
            api.request.assert_not_called()
            upstream.pages.return_value = [self.announcement("Xcode 27 beta changes")]
            os.environ["CI_PROBE_SIMULATE_MISSING_PIN"] = "true"
            self.assertEqual(0, probe.main())
            self.assertEqual(2, api.request.call_count)
            self.assertIn("pinned toolchain missing", api.request.call_args_list[0].args[2]["title"])
            self.assertIn("possible toolchain change - please check", api.request.call_args_list[1].args[2]["title"])
            self.assertNotIn("SIMULATION", api.request.call_args_list[1].args[2]["title"])
            api.reset_mock()
            os.environ["CI_PROBE_SIMULATE_MISSING_PIN"] = "false"
            upstream.pages.side_effect = OSError("synthetic network failure")
            self.assertEqual(1, probe.main())
            api.request.assert_not_called()
            os.environ["CI_PROBE_SIMULATE_MISSING_PIN"] = "true"
            self.assertEqual(1, probe.main())
            self.assertIn("pinned toolchain missing", api.request.call_args.args[2]["title"])
            api_class.reset_mock()
            os.environ["GITHUB_REF"] = "refs/heads/feature"
            self.assertEqual(1, probe.main())
            api_class.assert_not_called()
            os.environ["GITHUB_REF"] = "refs/heads/main"
            os.environ["GITHUB_EVENT_NAME"] = "schedule"
            os.environ["CI_PROBE_SIMULATE_MISSING_PIN"] = "true"
            self.assertEqual(1, probe.main())
            api_class.assert_not_called()


if __name__ == "__main__":
    unittest.main()
