import unittest
from unittest.mock import Mock, patch
import tempfile
import json
import hashlib
import plistlib
from pathlib import Path
from PIL import Image, ImageDraw
import subprocess
from types import SimpleNamespace
from urllib.request import urlopen
from strict_e2e_server import _png

from ipad_pause_host import (
    Run,
    app_launch_command,
    assess,
    control_state,
    public_fixture_server_command,
    script_repository_root,
    visible_mark,
    app_bundle_hashes,
    validate_source_checkout,
)


class PauseEvidenceTests(unittest.TestCase):
    def mode_run(self, tree):
        run = Run.__new__(Run)
        run.args = SimpleNamespace(udid="ipad")
        run.ui = Mock(return_value=tree)
        run.command = Mock(return_value="")
        run.save = Mock()
        run.events = []
        return run

    def test_mode_button_uses_physical_activation_point_and_records_action(self):
        run = self.mode_run([{"AXUniqueId": "mode.random.button", "enabled": True,
                             "type": "Button"}])
        run.tap_mode_button("mode.random.button")
        run.command.assert_called_once_with(
            "axe", "tap", "--id", "mode.random.button", "--element-type", "Button",
            "--tap-style", "physical", "--udid", "ipad")
        self.assertEqual(run.events[0]["state"], "returned")
        self.assertEqual(run.events[0]["targeting"], "accessibility_activation_point")

    def test_mode_activation_rejects_missing_disabled_duplicate_and_other_controls(self):
        button = {"AXUniqueId": "mode.random.button", "enabled": True, "type": "Button"}
        for tree in ([], [{**button, "enabled": False}], [button, button]):
            with self.subTest(tree=tree):
                run = self.mode_run(tree)
                with self.assertRaises(ValueError):
                    run.tap_mode_button("mode.random.button")
                run.command.assert_not_called()
        run = self.mode_run([button])
        with self.assertRaises(ValueError):
            run.tap_mode_button("slideshow.control.playPause.button")
        run.command.assert_not_called()

    def test_mode_activation_failure_preserves_issued_action_and_stops(self):
        run = self.mode_run([{"AXUniqueId": "mode.random.button", "enabled": True,
                             "type": "Button"}])
        run.command.side_effect = RuntimeError("activation failed")
        with self.assertRaisesRegex(RuntimeError, "activation failed"):
            run.tap_mode_button("mode.random.button")
        self.assertEqual(run.events[0]["state"], "issued")

    def make_app_bundle(self, root, name, *, executable=b"loader", debug_dylib=None,
                        bundle_id="com.331works.immichSlides"):
        bundle = Path(root) / name
        bundle.mkdir()
        (bundle / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id,
            "CFBundleExecutable": "immichSlides",
        }))
        (bundle / "immichSlides").write_bytes(executable)
        if debug_dylib is not None:
            (bundle / "immichSlides.debug.dylib").write_bytes(debug_dylib)
        return bundle

    def test_source_sha_must_be_full_and_match_the_script_repository_head(self):
        with self.assertRaisesRegex(ValueError, "40-character"):
            validate_source_checkout("abc", repo_root=Path("/unused"), runner=Mock())

        runner = Mock(side_effect=[
            SimpleNamespace(returncode=0, stdout="a" * 40 + "\n", stderr=""),
            SimpleNamespace(returncode=0, stdout="", stderr=""),
        ])
        root = Path("/candidate/repository")
        self.assertEqual(validate_source_checkout("A" * 40, repo_root=root, runner=runner), "a" * 40)
        self.assertEqual(runner.call_args_list[0].args[0], [
            "git", "-C", str(root), "rev-parse", "HEAD",
        ])
        self.assertEqual(runner.call_args_list[1].args[0], [
            "git", "-C", str(root), "status", "--porcelain", "--untracked-files=all",
        ])

    def test_source_repository_is_derived_from_script_path_not_process_cwd(self):
        script = Path("/candidate/repository/scripts/ipad_pause_host.py")
        with patch("ipad_pause_host.__file__", str(script)):
            self.assertEqual(script_repository_root(), Path("/candidate/repository"))

    def test_source_sha_mismatch_and_dirty_source_checkout_are_rejected(self):
        wrong_head = Mock(return_value=SimpleNamespace(returncode=0, stdout="b" * 40, stderr=""))
        with self.assertRaisesRegex(ValueError, "current HEAD of the script's repository"):
            validate_source_checkout("a" * 40, repo_root=Path("/script/repo"), runner=wrong_head)
        self.assertEqual(wrong_head.call_count, 1)

        dirty = Mock(side_effect=[
            SimpleNamespace(returncode=0, stdout="a" * 40, stderr=""),
            SimpleNamespace(returncode=0, stdout="?? untracked.txt\n", stderr=""),
        ])
        with self.assertRaisesRegex(ValueError, "working tree is not clean"):
            validate_source_checkout("a" * 40, repo_root=Path("/script/repo"), runner=dirty)

    def test_built_and_installed_app_executables_match_independently(self):
        with tempfile.TemporaryDirectory() as temp:
            built = self.make_app_bundle(temp, "Built.app", executable=b"built executable")
            installed = self.make_app_bundle(temp, "Installed.app", executable=b"built executable")
            expected = hashlib.sha256(b"built executable").hexdigest()
            hashes = app_bundle_hashes(built, installed, expected)
            self.assertEqual(hashes["built"]["executable_sha256"], expected)
            self.assertEqual(hashes["installed"]["executable_sha256"], expected)

    def test_matching_debug_dylib_is_included_in_the_artifact_hash_map(self):
        with tempfile.TemporaryDirectory() as temp:
            built = self.make_app_bundle(temp, "Built.app", executable=b"same loader", debug_dylib=b"same debug dylib")
            installed = self.make_app_bundle(temp, "Installed.app", executable=b"same loader", debug_dylib=b"same debug dylib")
            hashes = app_bundle_hashes(
                built,
                installed,
                hashlib.sha256(b"same loader").hexdigest(),
            )
            debug_sha = hashlib.sha256(b"same debug dylib").hexdigest()
            self.assertEqual(hashes["built"]["debug_dylib_sha256"], debug_sha)
            self.assertEqual(hashes["installed"]["debug_dylib_sha256"], debug_sha)

    def test_wrong_built_app_is_rejected_even_when_installed_matches_expected(self):
        with tempfile.TemporaryDirectory() as temp:
            built = self.make_app_bundle(temp, "WrongBuilt.app", executable=b"wrong build")
            installed = self.make_app_bundle(temp, "Installed.app", executable=b"expected")
            expected = hashlib.sha256(b"expected").hexdigest()
            with self.assertRaisesRegex(ValueError, "Built app main executable SHA-256"):
                app_bundle_hashes(built, installed, expected)

    def test_wrong_installed_app_is_rejected_when_built_app_matches_expected(self):
        with tempfile.TemporaryDirectory() as temp:
            built = self.make_app_bundle(temp, "Built.app", executable=b"expected")
            installed = self.make_app_bundle(temp, "WrongInstalled.app", executable=b"stale install")
            expected = hashlib.sha256(b"expected").hexdigest()
            with self.assertRaisesRegex(ValueError, "Installed app main executable SHA-256"):
                app_bundle_hashes(built, installed, expected)

    def test_wrong_bundle_identifier_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            built = self.make_app_bundle(temp, "WrongBundle.app", bundle_id="other.app")
            installed = self.make_app_bundle(temp, "Installed.app")
            expected = hashlib.sha256(b"loader").hexdigest()
            with self.assertRaisesRegex(ValueError, "Bundle ID"):
                app_bundle_hashes(built, installed, expected)

    def test_same_loader_with_different_debug_dylib_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            built = self.make_app_bundle(temp, "Built.app", executable=b"same loader", debug_dylib=b"build dylib")
            installed = self.make_app_bundle(temp, "Installed.app", executable=b"same loader", debug_dylib=b"stale dylib")
            expected = hashlib.sha256(b"same loader").hexdigest()
            with self.assertRaisesRegex(ValueError, "debug dylib SHA-256"):
                app_bundle_hashes(built, installed, expected)

    def test_debug_dylib_presence_must_match_built_app(self):
        with tempfile.TemporaryDirectory() as temp:
            built = self.make_app_bundle(temp, "Built.app", executable=b"same loader", debug_dylib=b"debug")
            installed = self.make_app_bundle(temp, "Installed.app", executable=b"same loader")
            expected = hashlib.sha256(b"same loader").hexdigest()
            with self.assertRaisesRegex(ValueError, "debug dylib presence"):
                app_bundle_hashes(built, installed, expected)

    def test_candidate_identity_failure_precedes_recording_fixture_and_ui(self):
        with tempfile.TemporaryDirectory() as temp:
            built = self.make_app_bundle(temp, "Built.app", executable=b"expected")
            installed = self.make_app_bundle(temp, "Installed.app", executable=b"stale installed")
            run = Run.__new__(Run)
            run.args = SimpleNamespace(
                udid="SIMULATOR-UDID",
                app_sha="a" * 40,
                built_app=str(built),
                binary_sha256=hashlib.sha256(b"expected").hexdigest(),
            )
            run.out = Path(temp) / "evidence"
            run.save = Mock()

            def command(*args):
                if args[:2] == ("df", "-k"):
                    return "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev 1 1 100000000 1% /\n"
                if args[:3] == ("xcrun", "simctl", "get_app_container"):
                    return f"{installed}\n"
                self.fail(f"No command should run before the identity check fails: {args}")

            run.command = Mock(side_effect=command)
            run.start_public_fixture = Mock()
            with patch("ipad_pause_host.validate_source_checkout", return_value="a" * 40), \
                    patch("ipad_pause_host.subprocess.Popen") as popen:
                with self.assertRaisesRegex(ValueError, "Installed app main executable SHA-256"):
                    run.execute()

            run.start_public_fixture.assert_not_called()
            run.save.assert_not_called()
            popen.assert_not_called()

    def test_app_launch_does_not_force_settings_or_test_scenario(self):
        command = app_launch_command("SIMULATOR-UDID")

        self.assertEqual(
            command,
            [
                "xcrun",
                "simctl",
                "launch",
                "--terminate-running-process",
                "SIMULATOR-UDID",
                "com.331works.immichSlides",
            ],
        )
        self.assertFalse(any("UI_TEST" in item or "STRICT_E2E_INPUT" in item for item in command))
        self.assertNotIn("--args", command)

    def test_fixture_server_uses_the_existing_normal_public_fixture(self):
        command = public_fixture_server_command(
            Path("scripts/strict_e2e_server.py"),
            Path("evidence/service-ready.json"),
            Path("evidence/service.log"),
        )

        self.assertIn("--fixture-set", command)
        self.assertEqual(command[command.index("--fixture-set") + 1], "a")
        self.assertEqual(command[command.index("--scenario") + 1], "normal")
        self.assertEqual(command[command.index("--host") + 1], "127.0.0.1")
        self.assertEqual(command[command.index("--port") + 1], "0")

    def test_public_fixture_starts_on_ephemeral_port_and_answers_health_check(self):
        with tempfile.TemporaryDirectory() as temp:
            run = Run.__new__(Run)
            run.out = Path(temp)
            run.fixture_process = None
            run.fixture_url = None
            run.start_public_fixture()
            process = run.fixture_process

            try:
                self.assertIsNotNone(process)
                with urlopen(run.fixture_url.replace("/api", "/healthz"), timeout=2) as response:
                    self.assertEqual(response.status, 200)
                service = json.loads((run.out / "fixture-service.json").read_text(encoding="utf-8"))
                self.assertEqual(service["scenario"], "normal")
                self.assertEqual(service["pid"], process.pid)
            finally:
                if process:
                    Run.stop_child(process, timeout=5)

    def test_playback_settings_are_set_through_visible_controls_and_read_back(self):
        def settings_tree(*, autoplay, interval, display):
            return [
                {
                    "AXUniqueId": "settings.playback.autoPlay.toggle",
                    "AXValue": "1" if autoplay else "0",
                    "enabled": True,
                },
                {"AXUniqueId": "settings.playback.interval.slider", "enabled": autoplay},
                {"AXLabel": f"{interval} 秒", "enabled": True},
                {
                    "AXLabel": "智能填满",
                    "AXValue": "1" if display == "smartFill" else "0",
                    "enabled": True,
                },
                {
                    "AXLabel": "单图模式",
                    "AXValue": "1" if display == "singlePhoto" else "0",
                    "enabled": True,
                },
            ]

        run = Run.__new__(Run)
        run.args = SimpleNamespace(udid="SIMULATOR-UDID")
        run.open_playback_settings = Mock()
        run.ui = Mock(side_effect=[
            settings_tree(autoplay=False, interval=8, display="smartFill"),
            settings_tree(autoplay=True, interval=8, display="smartFill"),
            settings_tree(autoplay=True, interval=12, display="smartFill"),
            settings_tree(autoplay=True, interval=12, display="singlePhoto"),
        ])
        run.tap = Mock()
        run.tap_label = Mock()
        run.command = Mock(return_value="")
        run.save = Mock()

        observed = run.configure_playback_settings_through_ui()

        run.open_playback_settings.assert_called_once_with()
        run.tap.assert_called_once_with("settings.playback.autoPlay.toggle")
        run.tap_label.assert_called_once_with("单图模式")
        run.command.assert_called_once_with(
            "axe",
            "slider",
            "--id",
            "settings.playback.interval.slider",
            "--value",
            "28",
            "--udid",
            "SIMULATOR-UDID",
        )
        self.assertEqual(observed, {
            "autoPlayEnabled": True,
            "intervalSeconds": 12,
            "displayMode": "singlePhoto",
            "source": "real_settings_ui",
        })

    def test_wrong_interval_readback_fails_before_single_photo_is_selected(self):
        run = Run.__new__(Run)
        run.args = SimpleNamespace(udid="SIMULATOR-UDID")
        run.open_playback_settings = Mock()
        run.ui = Mock(side_effect=[
            [
                {"AXUniqueId": "settings.playback.autoPlay.toggle", "AXValue": "1", "enabled": True},
                {"AXUniqueId": "settings.playback.interval.slider", "enabled": True},
                {"AXLabel": "10 秒", "enabled": True},
                {"AXLabel": "单图模式", "AXValue": "0", "enabled": True},
            ],
            [
                {"AXUniqueId": "settings.playback.autoPlay.toggle", "AXValue": "1", "enabled": True},
                {"AXUniqueId": "settings.playback.interval.slider", "enabled": True},
                {"AXLabel": "11 秒", "enabled": True},
                {"AXLabel": "单图模式", "AXValue": "0", "enabled": True},
            ],
        ])
        run.tap = Mock()
        run.tap_label = Mock()
        run.command = Mock(return_value="")
        run.wait_for_ui = Mock(side_effect=lambda predicate, message, timeout=20: run.ui())
        run.save = Mock()

        with self.assertRaisesRegex(ValueError, "12 seconds"):
            run.configure_playback_settings_through_ui()

        run.tap_label.assert_not_called()

    def test_playback_settings_open_from_playback_through_settings_home(self):
        run = Run.__new__(Run)
        run.args = SimpleNamespace(udid="SIMULATOR-UDID")
        run.ui = Mock(side_effect=[
            [{"AXUniqueId": "slideshow.control.settings.button", "enabled": True}],
            [{"AXUniqueId": "settings.item.playback", "enabled": True}],
            [
                {"AXUniqueId": "settings.playback.autoPlay.toggle", "enabled": True},
                {"AXUniqueId": "settings.playback.interval.slider", "enabled": True},
            ],
        ])
        run.wait_for_ui = Mock(side_effect=lambda predicate, message, timeout=20: run.ui())
        run.wake = Mock()
        run.tap = Mock()

        run.open_playback_settings()

        run.wake.assert_called_once_with()
        self.assertEqual(
            [call.args[0] for call in run.tap.call_args_list],
            ["slideshow.control.settings.button", "settings.item.playback"],
        )

    def test_playback_settings_open_from_settings_home(self):
        run = Run.__new__(Run)
        run.args = SimpleNamespace(udid="SIMULATOR-UDID")
        run.ui = Mock(side_effect=[
            [{"AXUniqueId": "settings.item.playback", "enabled": True}],
            [
                {"AXUniqueId": "settings.playback.autoPlay.toggle", "enabled": True},
                {"AXUniqueId": "settings.playback.interval.slider", "enabled": True},
            ],
        ])
        run.wait_for_ui = Mock(side_effect=lambda predicate, message, timeout=20: run.ui())
        run.tap = Mock()

        run.open_playback_settings()

        run.tap.assert_called_once_with("settings.item.playback")

    def test_existing_verified_server_config_must_be_retested_after_edit(self):
        run = Run.__new__(Run)
        run.fixture_url = "http://127.0.0.1:12345/api"
        run.replace_text = Mock()
        run.ui = Mock(return_value=[{"AXUniqueId": "firstboot.saveConfig.button", "enabled": True}])
        run.tap = Mock()
        run.save = Mock()

        with self.assertRaisesRegex(ValueError, "Save remains enabled after server inputs changed"):
            run.configure_public_server_through_ui()

        self.assertEqual(run.replace_text.call_count, 2)
        run.tap.assert_not_called()
        run.save.assert_not_called()

    def test_recording_timeout_is_killed_before_unlock(self):
        run = Run.__new__(Run)
        run.video = process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("video", 10), subprocess.TimeoutExpired("video", 5), 0]
        process.returncode = -9
        run.record_start = 0
        run.video_log = Mock()
        run.lock = Mock()
        run.fixture_process = None
        with self.assertRaises(ValueError):
            run.close()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 3)
        self.assertIsNone(run.video)
        run.lock.close.assert_called_once()

    def test_fixture_is_stopped_even_when_recording_close_fails(self):
        run = Run.__new__(Run)
        run.video = video = Mock()
        video.poll.return_value = None
        video.wait.return_value = 0
        video.returncode = 1
        run.video_log = Mock()
        run.video_log.closed = False
        run.fixture_process = fixture = Mock()
        fixture.poll.return_value = None
        fixture.wait.return_value = 0
        run.lock = Mock()

        with self.assertRaisesRegex(ValueError, "Recording finalization failed"):
            run.close()

        fixture.send_signal.assert_called_once()
        run.lock.close.assert_called_once()
        self.assertIsNone(run.fixture_process)

    def test_button_shapes_and_blank(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/"button.png"
            frame = dict(x=0, y=0, width=60, height=60)
            for shape, expected in [("blank", None), ("play", "play"), ("pause", "pause")]:
                image = Image.new("RGB", (120, 120), "white")
                draw = ImageDraw.Draw(image)
                if shape == "play":
                    draw.polygon([(49, 40), (49, 80), (79, 60)], fill="black")
                elif shape == "pause":
                    draw.rectangle((43, 40, 52, 80), fill="black")
                    draw.rectangle((67, 40, 76, 80), fill="black")
                image.save(path)
                self.assertEqual(control_state(path, frame, 60), expected)

    def test_visible_controls_are_not_toggled_off(self):
        run = Run.__new__(Run)
        run.ui = Mock(return_value=[{"AXUniqueId": "slideshow.control.playPause.button", "enabled": True}])
        run.tap_point = Mock()
        run.wake()
        run.tap_point.assert_not_called()

    def test_public_glyphs_not_color_guesses(self):
        import io
        with tempfile.TemporaryDirectory() as temp:
            for i in range(1, 6):
                screen = Image.new("RGB", (1032, 1376), (245, 245, 245))
                photo = Image.open(io.BytesIO(_png(384, 216, i, f"A{i}")))
                photo = photo.resize((1032, 580))
                screen.paste(photo, (0, 398))
                path = Path(temp)/f"A{i}.png"
                screen.save(path)
                self.assertEqual(visible_mark(path), f"A{i}")
            Image.new("RGB", (1032, 1376), "white").save(path)
            self.assertIsNone(visible_mark(path))

    def evidence(self):
        frames = [{"start": t, "end": t + .1, "mark": "A2", "luma": .5}
                  for t in [x / 2 for x in range(47)]]
        for f in frames:
            if f["start"] >= 12:
                f.update(luma=.3)
            if f["start"] >= 15:
                f.update(mark="A3", luma=.5)
        return frames

    def test_complete_window(self):
        self.assertEqual(assess(self.evidence(), "A2", .5, .2)["status"], "PASS")

    def test_fading_glyph_is_earliest_transition_candidate(self):
        f = self.evidence()
        f[23].update(mark=None, luma=.49)
        self.assertLess(assess(f, "A2", .5, .2)["first_transition_interval"][1], 12)

    def test_small_first_fade_is_not_skipped(self):
        f = self.evidence()
        f[23].update(luma=.4985)
        self.assertLess(assess(f, "A2", .5, .2)["first_transition_interval"][1], 12)

    def test_early_unknown_is_not_ignored(self):
        f = self.evidence()
        f[16].update(mark=None)
        with self.assertRaises(ValueError):
            assess(f, "A2", .5, .2)

    def test_early_transition(self):
        f = self.evidence()
        for x in f:
            if x["start"] >= 7:
                x["luma"] = .2
        with self.assertRaises(ValueError):
            assess(f, "A2", .5, .2)

    def test_late_transition(self):
        f = self.evidence()
        for x in f:
            x["luma"] = .5 if x["start"] < 16 else .2
            x["mark"] = "A2" if x["start"] < 18 else "A3"
        with self.assertRaises(ValueError):
            assess(f, "A2", .5, .2)

    def test_black_without_new_photo(self):
        f = self.evidence()
        for x in f:
            if x["start"] >= 12:
                x.update(mark=None, luma=0)
        with self.assertRaises(ValueError):
            assess(f, "A2", .5, .2)

    def test_missing_early_window(self):
        with self.assertRaises(ValueError):
            assess(self.evidence()[14:], "A2", .5, .2)

    def test_gap_spans_transition(self):
        with self.assertRaises(ValueError):
            assess([x for x in self.evidence() if not 9 < x["start"] < 14], "A2", .5, .2)

    def test_late_command_return_is_not_new_clock(self):
        with self.assertRaises(ValueError):
            assess(self.evidence(), "A2", .5, 8)

    def test_wrong_photo_before_window(self):
        f = self.evidence()
        f[8]["mark"] = "A1"
        with self.assertRaises(ValueError):
            assess(f, "A2", .5, .2)

    def test_new_photo_flashes_only(self):
        f = self.evidence()
        for x in f:
            if x["start"] > 15:
                x["mark"] = "A2"
        with self.assertRaises(ValueError):
            assess(f, "A2", .5, .2)

    def test_darkening_unrelated_to_late_new_photo(self):
        f = self.evidence()
        for x in f:
            if 15 <= x["start"] < 20:
                x["mark"] = "A2"
        with self.assertRaises(ValueError):
            assess(f, "A2", .5, .2)


if __name__ == "__main__":
    unittest.main()
