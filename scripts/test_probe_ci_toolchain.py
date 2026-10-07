"""Guard inventory, announcement and issue decisions without network or credentials."""

import copy
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
            "version": "27.0", "build": "test-build", "developer_dir": "/synthetic/Xcode.app/Contents/Developer"}}

    def announcement(self, breaking, title="[macOS] Xcode removal"):
        return {"title": title, "body": "### Breaking changes\n" + breaking +
                "\n### Runner images affected\n- [x] Xcode 27 Arm64\n- [ ] macOS 15\n",
                "html_url": "https://github.com/actions/runner-images/issues/123"}

    def test_announcements_distinguish_pin_removal_from_other_tool_and_image_changes(self):
        cases = [
            (self.announcement("Xcode 27.0 will be removed."), True),
            (self.announcement("We will drop Xcode 27 from this image."), True),
            (self.announcement("Xcode 26.4 and 27.0 will be removed."), True),
            (self.announcement("Xcode versions older than 27.1 will be removed."), True),
            (self.announcement("Xcode 27.0 remains installed. OpenSSL 3 will be removed.",
                               "[macOS] OpenSSL removal on Xcode 27"), False),
            (self.announcement("Xcode 26.4 will be removed."), False),
            (self.announcement("Xcode 27.1 will be installed.", "[macOS] Xcode update"), False),
            (self.announcement("Xcode 27.1 will be replaced by Xcode 27.2."), False),
            (self.announcement("Xcode 27.0 will be removed.") | {"body":
                "### Breaking changes\nXcode 27.0 will be removed.\n### Runner images affected\n"
                "- [ ] Xcode 27 Arm64\n- [x] macOS 15\n"}, False),
        ]
        for issue, expected in cases:
            with self.subTest(issue=issue):
                self.assertEqual(expected, bool(probe.removal_announcements(self.pins, [issue])))

    def test_inventory_reports_absence_or_build_mismatch_without_selecting_another_xcode(self):
        import plistlib
        with tempfile.TemporaryDirectory() as directory:
            pins = copy.deepcopy(self.pins)
            contents = Path(directory) / "Xcode.app/Contents"
            pins["xcode"]["developer_dir"] = str(contents / "Developer")
            self.assertTrue(probe.inventory_findings(pins))
            (contents / "Developer").mkdir(parents=True)
            for build, expected in [(pins["xcode"]["build"], False), ("other-build", True)]:
                (contents / "version.plist").write_bytes(plistlib.dumps({
                    "CFBundleShortVersionString": pins["xcode"]["version"], "ProductBuildVersion": build}))
                self.assertEqual(expected, bool(probe.inventory_findings(pins)))

    def test_present_pin_is_quiet_and_missing_or_removed_pin_creates_an_issue(self):
        for findings in [[], ["Pinned Xcode missing"], ["Announced removal: https://example.org"]]:
            with self.subTest(findings=findings):
                api = Mock()
                api.pages.return_value = []
                api.request.return_value = {"number": 123, "html_url": "https://example.org/123"}
                outcome = probe.report_findings(api, "owner/repo", self.pins, findings, "https://example.org/run")
                if findings:
                    self.assertEqual("opened", outcome["action"])
                    self.assertEqual("POST", api.request.call_args.args[0])
                else:
                    self.assertEqual("quiet", outcome["action"])
                    api.pages.assert_not_called()
                    api.request.assert_not_called()

    def test_existing_bot_issue_is_updated_and_simulation_cannot_change_real_tracking_issue(self):
        api = Mock()
        marker = probe.issue_marker(self.pins, False)
        real = {"number": 10, "body": marker, "user": {"login": "github-actions[bot]"},
                "html_url": "https://example.org/10"}
        api.pages.return_value = [real]
        api.request.return_value = real
        outcome = probe.report_findings(api, "owner/repo", self.pins, ["missing"], "https://example.org/run")
        self.assertEqual("updated", outcome["action"])
        self.assertEqual(("PATCH", "repos/owner/repo/issues/10"), api.request.call_args.args[:2])
        api.reset_mock()
        probe.report_findings(api, "owner/repo", self.pins, ["missing"], "https://example.org/run", simulated=True)
        self.assertEqual("POST", api.request.call_args.args[0])
        self.assertIn("SIMULATION", api.request.call_args.args[2]["title"])
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
             patch.object(probe, "GitHubAPI") as api_class:
            api = api_class.return_value
            api.pages.return_value = []
            api.request.return_value = {"html_url": "https://example.org/123"}
            self.assertEqual(0, probe.main())
            self.assertIn("SIMULATION", api.request.call_args.args[2]["title"])
            api.reset_mock()
            os.environ["CI_PROBE_SIMULATE_MISSING_PIN"] = "false"
            self.assertEqual(0, probe.main())
            api.request.assert_not_called()
            api.pages.side_effect = OSError("synthetic network failure")
            self.assertEqual(1, probe.main())
            api.request.assert_not_called()
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
