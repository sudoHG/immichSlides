"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations

from access_lifecycle_contract_test_fixtures import (
    ALLOWED_SYSTEM_PAUSE_ACTIVATION,
    AccessLifecycleContractError,
    Callable,
    DEVICE_SYNTHETIC_PINS,
    FILTER_FROZEN_SHA256,
    FROZEN_FIXTURE_SHA256,
    HIDDEN_CONTROL_BAR_PLAYBACK_IDENTIFIER,
    IPAD_SCREEN,
    IPHONE_SCREEN,
    Image,
    ImageDraw,
    ImageFilter,
    LARGE_XCRESULT_NOISE_SIZE,
    LARGE_XCRESULT_SCAN_DEADLINE_SECONDS,
    MIN_STABLE_HIDDEN_WAKE_FOCUS_OBSERVATIONS,
    NEW_STABLE_MARK_CONFIRM_WINDOW,
    NEW_STABLE_MARK_MIN_LUMA,
    NEW_STABLE_MARK_POLL_INTERVAL,
    NON_PLAYBACK_LAYER_PREFIXES,
    PLAYBACK_LAYER_PREFIX,
    Path,
    SCRIPT_DIR,
    SYNTHETIC_PIN,
    TV_SCREEN,
    _FALSE_GZIP_UNIT,
    _MarkSample,
    _STAND_IN_FRAMES,
    _checkerboard_mix,
    _compose_side_partner,
    _compose_smart_fill,
    _cover,
    _device_payload,
    _device_payload_ready_for_background,
    _dissolve_screen,
    _fixture_data,
    _fixture_image,
    _fixture_png,
    _gzip_content_frame,
    _large_xcresult_noise,
    _png_bytes,
    _pool_end_single_photo_display,
    _side_by_side,
    _side_by_side_screen,
    _side_by_side_transition_display,
    _single_on_own_blur,
    _single_photo_swap_display,
    _stacked_screen,
    _stand_in_png,
    _system_pause_payload,
    _unchanged_fullbleed_display,
    _valid_payload,
    _valid_settings_return_wake,
    _with_bottom_controls,
    _zstd_cli_frame,
    _zstd_content_frame,
    _zstd_frame_size,
    _zstd_skippable_frame,
    assert_appletv_double_layout_visible,
    assert_display_before_letterbox,
    assert_display_before_pool_burn,
    assert_display_strategy_visible,
    assert_returned_to_slideshow,
    assert_settings_open,
    assert_settings_return_wake,
    assert_system_pause_activation,
    assert_system_pause_identity_timing,
    assert_unshown_display_partners,
    capture_identity,
    classify_display_regions,
    classify_screenshot,
    compressed_byte_coincidence,
    confirm_wait,
    evaluate_access_lifecycle_evidence,
    gzip,
    inspect_display_strategy,
    io,
    is_confirmed_new_stable_mark,
    is_slideshow_layer,
    json,
    logical_content_bytes,
    mock,
    poll_wait,
    scan_sensitive_evidence,
    subprocess,
    sys,
    tempfile,
    time,
    unittest,
    wait_for_new_stable_mark,
)

class FailClosedTestsCases:
    def test_skip_cannot_pass(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(_valid_payload(status="skip"))
        self.assertIn("skip", str(raised.exception))
        self.assertNotIn("PASS", str(raised.exception))


    def test_missing_screenshot_cannot_pass(self) -> None:
        payload = _valid_payload()
        screenshots = dict(payload["screenshots"])  # type: ignore[arg-type]
        del screenshots["after_play"]
        payload["screenshots"] = screenshots
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Missing screenshots", str(raised.exception))


    def test_unknown_request_cannot_pass(self) -> None:
        payload = _valid_payload(requests=["settings.open", "/not-a-real-route"])
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Unknown request", str(raised.exception))
        self.assertIn("/not-a-real-route", str(raised.exception))


    def test_unchanged_default_settings_cannot_pass_as_persisted(self) -> None:
        payload = _valid_payload()
        defaults = {
            "autoPlayEnabled": True,
            "intervalSeconds": 5,
            "showExif": True,
            "displayMode": "smartFill",
        }
        settings = dict(payload["settings"])  # type: ignore[arg-type]
        settings["before"] = defaults
        settings["after_restart"] = dict(defaults)
        payload["settings"] = settings
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Settings were not persisted", str(raised.exception))


    def test_black_or_unrecognizable_scene_cannot_pass(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_play"] = "BLACK"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("All-black output", str(raised.exception))

        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_wake"] = "UNRECOGNIZABLE"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Unrecognizable input", str(raised.exception))


    def test_blank_scene_cannot_pass(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["pause"] = "BLANK"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Blank output", str(raised.exception))


    def test_retry_masking_cannot_pass(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(_valid_payload(retries_used_to_pass=True))
        self.assertIn("Retry", str(raised.exception))


    def test_ipad_missing_license_stack_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background()
        payload["device"] = "ipad"
        payload.pop("ipad_license_return", None)
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("return stack", str(raised.exception))


    def test_display_policy_same_png_cannot_pass_when_device_ran(self) -> None:
        payload = _device_payload_ready_for_background()
        display = dict(payload["display_policy"])  # type: ignore[arg-type]
        display["png_sha256_after"] = display["png_sha256_before"]
        payload["display_policy"] = display
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("display policy", str(raised.exception))


    def test_valid_device_payload_marks_device_tests_run(self) -> None:
        result = evaluate_access_lifecycle_evidence(_device_payload_ready_for_background())
        self.assertTrue(result["device_tests_run"])
        self.assertEqual(result["d01"], "PARTIAL")
        self.assertEqual(result["verdict"], "PASS")


    def test_settings_not_persisted_cannot_pass(self) -> None:
        payload = _valid_payload()
        settings = dict(payload["settings"])  # type: ignore[arg-type]
        settings["after_restart"] = {
            "autoPlayEnabled": True,
            "intervalSeconds": 5,
            "showExif": True,
            "displayMode": "smartFill",
        }
        payload["settings"] = settings
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Settings were not persisted", str(raised.exception))


    def test_launch_argument_cannot_impersonate_settings(self) -> None:
        payload = _valid_payload()
        settings = dict(payload["settings"])  # type: ignore[arg-type]
        settings["source"] = "launch_argument"
        payload["settings"] = settings
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("formal persistence", str(raised.exception))


    def test_userdefaults_injection_cannot_impersonate_settings(self) -> None:
        payload = _valid_payload()
        settings = dict(payload["settings"])  # type: ignore[arg-type]
        settings["source"] = "userdefaults_injection"
        payload["settings"] = settings
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("formal persistence", str(raised.exception))


    def test_old_scene_return_after_play_cannot_pass(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_play"] = "A1"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("previous scene", str(raised.exception))


    def test_background_jump_cannot_pass(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_background"] = "A3"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("background return", str(raised.exception))


    def test_wake_switch_cannot_pass(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_wake"] = "A3"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("waking the controls", str(raised.exception))


    def test_stacked_mark_wake_switch_still_fail_closed(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes.update(
            {
                "after_next": "A4+A1",
                "after_play": "A4+A1",
                "before_background": "A4+A1",
                "after_background": "A4+A1",
                "before_wake": "A4+A1",
                "after_wake": "A5",
            }
        )
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Changing photos while waking the controls", str(raised.exception))


    def test_stacked_region_scene_marks_are_not_unrecognizable(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes.update(
            {
                "after_next": "A4+A1",
                "after_play": "A4+A1",
                "before_background": "A4+A1",
                "after_background": "A4+A1",
                "before_wake": "A4+A1",
                "after_wake": "A4+A1",
            }
        )
        payload["scenes"] = scenes
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")


    def test_forced_display_mode_cannot_pass(self) -> None:
        payload = _valid_payload(
            launch_environment={"UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE": "singlePhoto"}
        )
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("forced display mode", str(raised.exception))


    def test_progress_after_play_must_be_zero(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(_valid_payload(progress_after_play=3))
        self.assertIn("progress", str(raised.exception))


    def test_device_missing_settings_at_background_screenshot_cannot_pass(self) -> None:
        payload = _device_payload()
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Missing screenshots", str(raised.exception))
        self.assertIn("settings_at_background", str(raised.exception))


    def test_device_autoplay_off_at_background_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background(autoplay_enabled=False)
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Autoplay", str(raised.exception))


    def test_device_wait_equal_to_read_interval_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background(
            interval_seconds=14,
            wait_seconds=14,
        )
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("interval", str(raised.exception))


    def test_device_wait_not_bound_to_read_interval_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background(interval_seconds=12, wait_seconds=16)
        background = dict(payload["background"])  # type: ignore[arg-type]
        background["interval_seconds"] = 14
        payload["background"] = background
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("interval", str(raised.exception))


    def test_device_missing_progress_after_next_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background()
        payload.pop("progress_after_next", None)
        payload["progress_after_play"] = 0
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Progress", str(raised.exception))


    def test_device_progress_after_next_nonzero_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background(progress_after_next=0.4)
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("progress", str(raised.exception))


    def test_device_progress_without_probe_raw_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background()
        payload["progress_raw_after_next"] = ""
        payload["progress_raw_after_play"] = ""
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Progress", str(raised.exception))


    def test_device_presentation_probe_raw_counts_as_measured_progress(self) -> None:
        payload = _device_payload_ready_for_background()
        payload["progress_source"] = "slideshow.scenePresentation.contract.summary"
        payload["progress_raw_after_next"] = (
            "schemaVersion=scene-presentation-contract-probe-v1;"
            "phase=stablePhoto;motionRawProgress=0.000000"
        )
        payload["progress_raw_after_play"] = (
            "schemaVersion=scene-presentation-contract-probe-v1;"
            "phase=stablePhoto;motionRawProgress=0.000000"
        )
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")


    def test_device_restart_autoplay_off_cannot_pass(self) -> None:
        payload = _device_payload_ready_for_background()
        settings = dict(payload["settings"])  # type: ignore[arg-type]
        settings["before"] = {
            "autoPlayEnabled": False,
            "intervalSeconds": 12,
            "showExif": False,
            "displayMode": "singlePhoto",
        }
        settings["after_restart"] = dict(settings["before"])  # type: ignore[arg-type]
        payload["settings"] = settings
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Settings were not persisted", str(raised.exception))


    def test_device_measured_play_progress_may_advance_on_new_scene(self) -> None:
        payload = _device_payload_ready_for_background(progress_after_play=0.05)
        payload["progress_raw_after_play"] = (
            "eventType=motionFrame;renderRole=stable;progress=0.050000"
        )
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")


    def test_official_iphone_shape_cannot_pass_as_executed_spec(self) -> None:
        payload = _device_payload()
        payload["progress_after_play"] = 0
        payload["settings"] = {
            "source": "real_settings_ui",
            "before": {
                "autoPlayEnabled": False,
                "intervalSeconds": 14,
                "showExif": False,
                "displayMode": "smartFill",
            },
            "after_restart": {
                "autoPlayEnabled": False,
                "intervalSeconds": 14,
                "showExif": False,
                "displayMode": "smartFill",
            },
        }
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        error = str(raised.exception)
        self.assertTrue(
            "Missing screenshots" in error or "Autoplay" in error or "Progress" in error or "interval" in error,
            error,
        )


    def test_log_or_index_cannot_be_identity(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(_valid_payload(identity_source="asset_id"))
        self.assertIn("Identity", str(raised.exception))


    def test_wrong_pin_entry_cannot_pass(self) -> None:
        payload = _valid_payload()
        pin_flow = dict(payload["pin_flow"])  # type: ignore[arg-type]
        pin_flow["wrong_pin_entered"] = True
        payload["pin_flow"] = pin_flow
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("incorrect PIN", str(raised.exception))
        self.assertNotIn(SYNTHETIC_PIN, str(raised.exception))


    def test_cancel_dropping_protection_cannot_pass(self) -> None:
        payload = _valid_payload()
        pin_flow = dict(payload["pin_flow"])  # type: ignore[arg-type]
        pin_flow["cancel_still_protected"] = False
        payload["pin_flow"] = pin_flow
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("cancelling", str(raised.exception))


    def test_uitest_storage_cannot_claim_formal_keychain(self) -> None:
        payload = _valid_payload()
        pin_flow = dict(payload["pin_flow"])  # type: ignore[arg-type]
        pin_flow["storage_kind"] = "keychain"
        payload["pin_flow"] = pin_flow
        payload["xctest_config_present"] = True
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("Keychain", str(raised.exception))


    def test_keychain_failure_stays_partial(self) -> None:
        payload = _valid_payload()
        pin_flow = dict(payload["pin_flow"])  # type: ignore[arg-type]
        pin_flow["storage_kind"] = "keychain_failure"
        payload["pin_flow"] = pin_flow
        payload["xctest_config_present"] = False
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["d01"], "PARTIAL")
        self.assertNotEqual(result["verdict"], "PASS")
        self.assertEqual(result["verdict"], "PARTIAL")


    def test_valid_host_contract_passes_without_claiming_device_ui(self) -> None:
        result = evaluate_access_lifecycle_evidence(_valid_payload())
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["d01"], "PARTIAL")
        self.assertEqual(result["fixture_sha256"], FROZEN_FIXTURE_SHA256["a"])
        self.assertFalse(result["device_tests_run"])
        self.assertFalse(result["skip_counted_as_pass"])


class SlideshowReturnTestsCases:
    def test_hidden_control_bar_is_still_slideshow_layer(self) -> None:
        # After Menu, the app is already on the playback layer even when the control bar is hidden.
        self.assertTrue(
            is_slideshow_layer(
                [
                    "slideshow.hiddenWakeReceiver",
                    "slideshow.exifForegroundTone.flag",
                ]
            )
        )


    def test_settings_button_is_not_required_to_return(self) -> None:
        assert_returned_to_slideshow(
            {
                "identifiers": ["slideshow.hiddenWakeReceiver"],
                "control_bar_visible": False,
                "settings_button_visible": False,
            }
        )


    def test_requiring_settings_button_cannot_pass_as_return(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_returned_to_slideshow(
                {
                    "identifiers": ["slideshow.hiddenWakeReceiver"],
                    "control_bar_visible": False,
                    "settings_button_visible": False,
                    "require_settings_button": True,
                }
            )
        self.assertIn("control bar", str(raised.exception))
        self.assertIn("playback", str(raised.exception))


    def test_system_pause_analog_return_requiring_settings_button_cannot_pass(self) -> None:
        # After Home and activation, the control bar is already hidden, but the old check still required settings and
        # play buttons before counting the return.
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_returned_to_slideshow(
                {
                    "identifiers": ["slideshow.hiddenWakeReceiver"],
                    "control_bar_visible": False,
                    "settings_button_visible": False,
                    "play_button_visible": False,
                    "require_settings_button": True,
                    "system_pause_analog": True,
                }
            )
        self.assertIn("control bar", str(raised.exception))
        self.assertIn("playback", str(raised.exception))


    def test_settings_or_pin_layer_is_not_slideshow(self) -> None:
        for identifiers in (
            ["settings.item.playback"],
            ["settings.playback.autoPlay.link"],
            ["pinEntry.close.button"],
            ["firstboot.serverURL.field"],
            ["mode.random.button"],
            ["slideshow.hiddenWakeReceiver", "settings.item.playback"],
        ):
            with self.subTest(identifiers=identifiers):
                self.assertFalse(is_slideshow_layer(identifiers))
                with self.assertRaises(AccessLifecycleContractError) as raised:
                    assert_returned_to_slideshow({"identifiers": identifiers})
                self.assertIn("playback layer", str(raised.exception))


    def test_visible_control_bar_still_counts_as_slideshow(self) -> None:
        assert_returned_to_slideshow(
            {
                "identifiers": ["slideshow.control.settings.button"],
                "control_bar_visible": True,
                "settings_button_visible": True,
            }
        )


    def test_hidden_bar_return_does_not_waive_wake_scene_check(self) -> None:
        assert_returned_to_slideshow(
            {
                "identifiers": ["slideshow.hiddenWakeReceiver"],
                "control_bar_visible": False,
                "settings_button_visible": False,
            }
        )
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_wake"] = "A3"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("waking the controls", str(raised.exception))


    def test_layer_prefixes_stay_locked(self) -> None:
        self.assertEqual(PLAYBACK_LAYER_PREFIX, "slideshow.")
        self.assertEqual(
            NON_PLAYBACK_LAYER_PREFIXES,
            ("settings.", "pinEntry.", "firstboot.", "mode."),
        )


class SettingsReturnWakeTestsCases:
    def test_immediate_up_during_menu_transition_cannot_pass(self) -> None:
        # Up was pressed about 0.56s after Menu, before the playback transition finished or the receiver gained stable focus.
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(
                    transition_complete=False,
                    hidden_wake_receiver_focused=False,
                    hidden_wake_receiver_focus_stable=False,
                    consecutive_focused_observations=0,
                    screenshots={"before": "", "after": ""},
                )
            )
        self.assertIn("transition", str(raised.exception))


    def test_settings_layer_during_return_cannot_be_woken(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(identifiers=["settings.item.playback"])
            )
        self.assertIn("playback layer", str(raised.exception))


    def test_mixed_settings_and_slideshow_identifiers_cannot_be_woken(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(
                    identifiers=[
                        HIDDEN_CONTROL_BAR_PLAYBACK_IDENTIFIER,
                        "settings.item.playback",
                    ]
                )
            )
        self.assertIn("playback layer", str(raised.exception))


    def test_unfocused_hidden_receiver_cannot_be_woken(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(
                    hidden_wake_receiver_focused=False,
                    hidden_wake_receiver_focus_stable=False,
                )
            )
        self.assertIn("stably focused", str(raised.exception))


    def test_one_shot_focus_is_not_stable(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(
                    hidden_wake_receiver_focus_stable=False,
                    consecutive_focused_observations=1,
                )
            )
        self.assertIn("stably focused", str(raised.exception))


    def test_double_press_cannot_mask_first_wake(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(_valid_settings_return_wake(directional_press_count=2))
        self.assertIn("press twice", str(raised.exception))
        self.assertIn("first wake", str(raised.exception))


    def test_missing_before_after_screenshots_cannot_pass(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_return_wake(
                _valid_settings_return_wake(screenshots={"before": "", "after": "after.png"})
            )
        self.assertIn("screenshots", str(raised.exception))


    def test_ready_hidden_receiver_allows_single_press_with_screenshots(self) -> None:
        assert_settings_return_wake(_valid_settings_return_wake())


    def test_stable_observation_floor_stays_locked(self) -> None:
        self.assertGreaterEqual(MIN_STABLE_HIDDEN_WAKE_FOCUS_OBSERVATIONS, 5)
        self.assertEqual(
            HIDDEN_CONTROL_BAR_PLAYBACK_IDENTIFIER,
            "slideshow.hiddenWakeReceiver",
        )


class SystemPauseAnalogTimingTestsCases:
    def test_wake_before_background_identity_cannot_pass(self) -> None:
        # After activation, Up woke the hidden control before after-background was captured.
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_system_pause_identity_timing(
                [
                    "before-background",
                    "hidden-control-wake-2-before",
                    "hidden-control-wake-2-after",
                    "after-background",
                ]
            )
        self.assertIn("waking the control bar", str(raised.exception))
        self.assertIn("identity", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(
                _system_pause_payload(
                    screenshot_order=[
                        "pause",
                        "after-next",
                        "after-play",
                        "before-background",
                        "hidden-control-wake-2-before",
                        "hidden-control-wake-2-after",
                        "after-background",
                        "before-wake",
                        "after-wake",
                    ]
                )
            )
        self.assertIn("waking the control bar", str(raised.exception))
        self.assertIn("identity", str(raised.exception))


    def test_identity_before_independent_wake_can_pass_timing(self) -> None:
        assert_system_pause_identity_timing(
            [
                "before-background",
                "after-background",
                "hidden-control-wake-2-before",
                "hidden-control-wake-2-after",
                "before-wake",
                "after-wake",
            ]
        )
        result = evaluate_access_lifecycle_evidence(_system_pause_payload())
        self.assertEqual(result["verdict"], "PASS")


    def test_missing_identity_timing_cannot_pass_system_pause(self) -> None:
        payload = _system_pause_payload()
        del payload["screenshot_order"]
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("timing", str(raised.exception))


    def test_background_jump_still_fails_with_correct_identity_timing(self) -> None:
        payload = _system_pause_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["after_background"] = "A3"
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("background return", str(raised.exception))
        self.assertIn("Changing photos", str(raised.exception))


    def test_launch_or_rebuilt_process_is_not_desktop_pid_analog(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_system_pause_activation(
                {
                    "system_pause_activation": "launch",
                    "process_rebuilt": False,
                    "home_left_app_running": True,
                }
            )
        self.assertIn("rebuild", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(
                _system_pause_payload(system_pause_activation="launch")
            )
        self.assertIn("rebuild", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(_system_pause_payload(process_rebuilt=True))
        self.assertIn("rebuild", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(
                _system_pause_payload(home_left_app_running=False)
            )
        self.assertIn("Open", str(raised.exception))


    def test_activate_existing_process_is_allowed(self) -> None:
        assert_system_pause_activation(
            {
                "system_pause_activation": ALLOWED_SYSTEM_PAUSE_ACTIVATION,
                "process_rebuilt": False,
                "home_left_app_running": True,
            }
        )
