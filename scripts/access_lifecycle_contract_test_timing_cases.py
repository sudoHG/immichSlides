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

class SettingsOpenOrderTestsCases:
    def test_pin_gate_cannot_require_playback_item_first(self) -> None:
        # The PIN gate covers the settings page, but the old check waited for settings.item.playback first.
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_settings_open(
                {
                    "identifiers": ["pinEntry.close.button"],
                    "require_playback_item": True,
                }
            )
        self.assertIn("PIN", str(raised.exception))
        self.assertIn("playback settings", str(raised.exception))


    def test_pin_gate_is_a_legal_settings_open_state(self) -> None:
        assert_settings_open(
            {
                "identifiers": ["pinEntry.close.button"],
                "require_playback_item": False,
            }
        )


    def test_settings_home_may_require_playback_item(self) -> None:
        assert_settings_open(
            {
                "identifiers": ["settings.item.playback"],
                "require_playback_item": True,
            }
        )


class NewStableMarkTimingTestsCases:
    def test_confirm_wait_is_reserved_inside_remaining_budget(self) -> None:
        self.assertEqual(NEW_STABLE_MARK_POLL_INTERVAL, 0.1)
        self.assertEqual(NEW_STABLE_MARK_CONFIRM_WINDOW, 0.8)
        self.assertEqual(NEW_STABLE_MARK_MIN_LUMA, 0.20)
        self.assertEqual(confirm_wait(2.0), 0.8)
        self.assertEqual(confirm_wait(0.5), 0.5)
        self.assertEqual(confirm_wait(0.0), 0.0)
        self.assertEqual(confirm_wait(-1.0), 0.0)
        self.assertEqual(poll_wait(2.0), 0.1)
        self.assertEqual(poll_wait(0.04), 0.04)
        self.assertEqual(poll_wait(0.0), 0.0)


    def test_unconditional_confirm_window_is_the_documented_miss(self) -> None:
        # The old helper always waited 0.8s: with 0.5s left, confirming overran the deadline and could no longer sample
        # the now-stable new frame.
        self.assertGreater(NEW_STABLE_MARK_CONFIRM_WINDOW, 0.5)
        self.assertLess(confirm_wait(0.5), NEW_STABLE_MARK_CONFIRM_WINDOW)


    def test_late_switch_after_failed_confirm_is_sampled_before_deadline(self) -> None:
        # The sample missed a new MATCH at 15.5s because the unconditional 0.8s confirm landed at 16.3s,
        # past the deadline.
        def observe(elapsed: float) -> _MarkSample:
            if elapsed < 15.5:
                return _MarkSample("MATCH", "A3", 0.5)
            if elapsed < 16.0:
                return _MarkSample("MATCH", "A4", 0.5)
            if elapsed < 16.2:
                return _MarkSample("MATCH", "A4", 0.5)
            return _MarkSample("TRANSITION", None, 0.12)

        mark = wait_for_new_stable_mark(
            timeout=16.0,
            initial_mark="A3",
            observe=observe,
        )
        self.assertEqual(mark, "A4")


    def test_unchanged_mark_still_fail_closed(self) -> None:
        def observe(_elapsed: float) -> _MarkSample:
            return _MarkSample("MATCH", "A3", 0.5)

        with self.assertRaises(AccessLifecycleContractError) as raised:
            wait_for_new_stable_mark(timeout=2.0, initial_mark="A3", observe=observe)
        self.assertIn("No new stable frame was observed before backgrounding", str(raised.exception))


    def test_transition_flash_without_stable_confirm_fail_closed(self) -> None:
        def observe(elapsed: float) -> _MarkSample:
            if 0.3 <= elapsed < 0.35:
                return _MarkSample("MATCH", "A4", 0.5)
            return _MarkSample("TRANSITION", None, 0.12)

        with self.assertRaises(AccessLifecycleContractError) as raised:
            wait_for_new_stable_mark(timeout=1.0, initial_mark="A3", observe=observe)
        self.assertIn("No new stable frame was observed before backgrounding", str(raised.exception))


    def test_low_luma_confirm_is_not_stable(self) -> None:
        def observe(elapsed: float) -> _MarkSample:
            if elapsed < 0.2:
                return _MarkSample("MATCH", "A3", 0.5)
            if elapsed < 0.3:
                return _MarkSample("MATCH", "A4", 0.5)
            return _MarkSample("MATCH", "A4", 0.10)

        with self.assertRaises(AccessLifecycleContractError):
            wait_for_new_stable_mark(timeout=2.0, initial_mark="A3", observe=observe)
        self.assertFalse(
            is_confirmed_new_stable_mark(
                status="MATCH",
                mark="A4",
                candidate_mark="A4",
                initial_mark="A3",
                mean_luma=0.10,
            )
        )


    def test_timeout_budget_is_not_lengthened(self) -> None:
        observed_at: list[float] = []

        def observe(elapsed: float) -> _MarkSample:
            observed_at.append(elapsed)
            return _MarkSample("MATCH", "A3", 0.5)

        with self.assertRaises(AccessLifecycleContractError):
            wait_for_new_stable_mark(timeout=1.0, initial_mark="A3", observe=observe)
        self.assertLessEqual(max(observed_at), 1.0)


class ModeContinueAndWakeHelperTestsCases:
    def test_wake_helper_isolates_evidence_from_autoplay_boundary(self) -> None:
        from access_lifecycle_contract import (
            WAKE_EVIDENCE_BUDGET_SECONDS,
            hide_wait_for_wake,
            should_wait_for_autoplay_before_wake,
            wake_window_crosses_autoplay,
        )

        self.assertEqual(WAKE_EVIDENCE_BUDGET_SECONDS, 2.5)
        self.assertTrue(
            wake_window_crosses_autoplay(
                elapsed_before=11.48,
                elapsed_after=13.66,
                interval_seconds=12,
            )
        )
        self.assertFalse(
            wake_window_crosses_autoplay(
                elapsed_before=9.0,
                elapsed_after=10.5,
                interval_seconds=12,
            )
        )
        self.assertEqual(
            hide_wait_for_wake(
                hide_seconds=9,
                remaining_to_autoplay=9.5,
                evidence_budget=2.5,
            ),
            7.0,
        )
        self.assertEqual(
            hide_wait_for_wake(
                hide_seconds=9,
                remaining_to_autoplay=12,
                evidence_budget=2.5,
            ),
            9.0,
        )
        self.assertEqual(
            hide_wait_for_wake(
                hide_seconds=9,
                remaining_to_autoplay=2.0,
                evidence_budget=2.5,
            ),
            0.0,
        )
        self.assertTrue(
            should_wait_for_autoplay_before_wake(
                remaining_to_autoplay=2.0,
                evidence_budget=2.5,
            )
        )
        self.assertFalse(
            should_wait_for_autoplay_before_wake(
                remaining_to_autoplay=9.5,
                evidence_budget=2.5,
            )
        )


class CaptureRegionIdentityTestsCases:
    def test_ipad_after_next_full_screen_is_transition(self) -> None:
        png = _stand_in_png("ipad-stacked-smart-fill", "after-next.png")
        full = classify_screenshot(png)
        self.assertEqual(full.status, "TRANSITION")
        self.assertIsNone(full.mark)


    def test_ipad_after_next_left_right_boxes_miss_stacked_pair(self) -> None:
        png = _stand_in_png("ipad-stacked-smart-fill", "after-next.png")
        regions = classify_display_regions(png)
        self.assertEqual(regions["left"].status, "TRANSITION")
        self.assertEqual(regions["right"].status, "TRANSITION")
        self.assertNotEqual({regions["left"].mark, regions["right"].mark}, {"A4", "A1"})


    def test_ipad_after_next_capture_identity_is_stacked_a4_a1(self) -> None:
        identity = capture_identity(_stand_in_png("ipad-stacked-smart-fill", "after-next.png"))
        self.assertEqual(identity.status, "MATCH")
        self.assertEqual(identity.mark, "A4+A1")


    def test_iphone_late_frames_composite_identity_changes(self) -> None:
        before = capture_identity(_stand_in_png("iphone", "failure-late-frames", "late-178.png"))
        after = capture_identity(_stand_in_png("iphone", "failure-late-frames", "late-184.png"))
        self.assertEqual(before.status, "MATCH")
        self.assertEqual(after.status, "MATCH")
        self.assertEqual(before.mark, "A3+A5")
        self.assertEqual(after.mark, "A4+A5")
        self.assertNotEqual(before.mark, after.mark)
        full_after = classify_screenshot(
            _stand_in_png("iphone", "failure-late-frames", "late-184.png")
        )
        self.assertEqual(full_after.status, "MATCH")
        self.assertEqual(full_after.mark, "A5")
        self.assertNotEqual(after.mark, full_after.mark)


    def test_capture_new_stable_mark_does_not_miss_composite_change(self) -> None:
        before_png = _stand_in_png("iphone", "failure-late-frames", "late-178.png")
        after_png = _stand_in_png("iphone", "failure-late-frames", "late-184.png")
        initial = capture_identity(before_png)

        def observe(elapsed: float) -> object:
            png = before_png if elapsed < 0.5 else after_png
            return capture_identity(png)

        mark = wait_for_new_stable_mark(
            timeout=2.0,
            initial_mark=str(initial.mark),
            observe=observe,
        )
        self.assertEqual(mark, "A4+A5")


    def test_full_screen_classify_misses_iphone_composite_change(self) -> None:
        before_png = _stand_in_png("iphone", "failure-late-frames", "late-178.png")
        after_png = _stand_in_png("iphone", "failure-late-frames", "late-184.png")
        initial = classify_screenshot(before_png)
        self.assertEqual(initial.status, "TRANSITION")

        def observe(elapsed: float) -> _MarkSample:
            identity = classify_screenshot(before_png if elapsed < 0.5 else after_png)
            return _MarkSample(identity.status, identity.mark, identity.mean_luma)

        mark = wait_for_new_stable_mark(
            timeout=2.0,
            initial_mark="UNRECOGNIZABLE",
            observe=observe,
        )
        self.assertEqual(mark, "A5")


    def test_transition_without_region_match_is_not_capture_pass(self) -> None:
        identity = capture_identity(_checkerboard_mix("A2", "A3"))
        self.assertEqual(identity.status, "TRANSITION")
        self.assertIsNone(identity.mark)


    def test_unrecognizable_late_frame_is_not_promoted(self) -> None:
        identity = capture_identity(_stand_in_png("iphone", "failure-late-frames", "late-160.png"))
        self.assertIn(identity.status, {"UNRECOGNIZABLE", "BLANK", "BLACK", "TRANSITION"})
        self.assertIsNone(identity.mark)
        self.assertNotEqual(identity.status, "MATCH")


    def test_black_bytes_stay_fail_closed(self) -> None:
        canvas = Image.new("RGB", (64, 64), (0, 0, 0))
        identity = capture_identity(_png_bytes(canvas))
        self.assertEqual(identity.status, "BLACK")
        self.assertIsNone(identity.mark)


    def test_single_fixture_still_uses_full_match(self) -> None:
        identity = capture_identity(_fixture_png("A2"))
        self.assertEqual(identity.status, "MATCH")
        self.assertEqual(identity.mark, "A2")


    def test_iphone_wake_pair_keeps_stacked_identity(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        before_png = _stand_in_png("iphone-wake-pair", "before-wake.png")
        after_png = _stand_in_png("iphone-wake-pair", "after-wake.png")
        before_full = classify_screenshot(before_png)
        before_regions = classify_display_regions(before_png)
        self.assertEqual(before_full.status, "MATCH")
        self.assertEqual(before_full.mark, "A5")
        self.assertEqual(before_regions["top_half"].status, "TRANSITION")
        self.assertEqual(before_regions["top"].status, "MATCH")
        self.assertEqual(before_regions["top"].mark, "A1")
        self.assertEqual(before_regions["bottom_half"].status, "MATCH")
        self.assertEqual(before_regions["bottom_half"].mark, "A5")
        before = capture_identity(before_png)
        after = capture_identity(after_png)
        self.assertEqual(before.status, "MATCH")
        self.assertEqual(after.status, "MATCH")
        self.assertEqual(before.mark, "A1+A5")
        self.assertEqual(after.mark, "A1+A5")
        self.assertEqual(scene_mark_from_bytes(before_png), "A1+A5")
        self.assertEqual(scene_mark_from_bytes(after_png), "A1+A5")


    def test_iphone_wake_pair_does_not_report_switch(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["before_wake"] = scene_mark_from_bytes(
            _stand_in_png("iphone-wake-pair", "before-wake.png")
        )
        scenes["after_wake"] = scene_mark_from_bytes(
            _stand_in_png("iphone-wake-pair", "after-wake.png")
        )
        payload["scenes"] = scenes
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")


    def test_ipad_display_before_is_stacked_not_unrecognizable(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        before_png = _stand_in_png("ipad-display-switch", "display-before.png")
        after_png = _stand_in_png("ipad-display-switch", "display-after.png")
        full = classify_screenshot(before_png)
        self.assertEqual(full.status, "TRANSITION")
        self.assertIsNone(full.mark)
        before = capture_identity(before_png)
        after = capture_identity(after_png)
        self.assertEqual(before.status, "MATCH")
        self.assertEqual(before.mark, "A4+A1")
        self.assertEqual(after.status, "MATCH")
        self.assertEqual(after.mark, "A1")
        self.assertEqual(scene_mark_from_bytes(before_png), "A4+A1")
        self.assertEqual(scene_mark_from_bytes(after_png), "A1")
        payload = _device_payload_ready_for_background()
        display = dict(payload["display_policy"])  # type: ignore[arg-type]
        display["mark_before"] = "A4+A1"
        display["mark_after"] = "A1"
        payload["display_policy"] = display
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")


    def test_iphone_pause_next_play_is_stacked_new_scene(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        pause_png = _stand_in_png("iphone-pause-next-play", "pause.png")
        after_next_png = _stand_in_png("iphone-pause-next-play", "after-next.png")
        after_play_png = _stand_in_png("iphone-pause-next-play", "after-play.png")
        full_next = classify_screenshot(after_next_png)
        self.assertEqual(full_next.status, "MATCH")
        self.assertEqual(full_next.mark, "A5")
        pause = scene_mark_from_bytes(pause_png)
        after_next = scene_mark_from_bytes(after_next_png)
        after_play = scene_mark_from_bytes(after_play_png)
        self.assertEqual(pause, "A4+A5")
        self.assertEqual(after_next, "A1+A5")
        self.assertEqual(after_play, "A1+A5")
        regions = classify_display_regions(after_next_png)
        self.assertEqual(regions["upper"].status, "MATCH")
        self.assertEqual(regions["upper"].mark, "A1")
        self.assertEqual(regions["bottom_half"].status, "MATCH")
        self.assertEqual(regions["bottom_half"].mark, "A5")
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes["pause"] = pause
        scenes["after_next"] = after_next
        scenes["after_play"] = after_play
        payload["scenes"] = scenes
        result = evaluate_access_lifecycle_evidence(payload)
        self.assertEqual(result["verdict"], "PASS")


    def test_stacked_after_play_returning_to_pause_still_fail_closed(self) -> None:
        payload = _valid_payload()
        scenes = dict(payload["scenes"])  # type: ignore[arg-type]
        scenes.update(
            {
                "pause": "A4+A5",
                "after_next": "A1+A5",
                "after_play": "A4+A5",
                "before_background": "A1+A5",
                "after_background": "A1+A5",
                "before_wake": "A1+A5",
                "after_wake": "A1+A5",
            }
        )
        payload["scenes"] = scenes
        with self.assertRaises(AccessLifecycleContractError) as raised:
            evaluate_access_lifecycle_evidence(payload)
        self.assertIn("previous scene", str(raised.exception))


    def test_ipad_after_next_scene_mark_is_stacked_match(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        png = _stand_in_png("ipad-stacked-after-next", "after-next.png")
        full = classify_screenshot(png)
        self.assertEqual(full.status, "TRANSITION")
        self.assertIsNone(full.mark)
        self.assertEqual(scene_mark_from_bytes(png), "A4+A1")


    def test_scene_mark_does_not_promote_transition_or_black(self) -> None:
        from access_lifecycle_contract import scene_mark_from_bytes

        mixed = scene_mark_from_bytes(_checkerboard_mix("A2", "A3"))
        self.assertIn(mixed, {"TRANSITION", "UNRECOGNIZABLE", "BLACK", "BLANK"})
        self.assertNotEqual(mixed, "A2")
        self.assertNotEqual(mixed, "A3")
        self.assertNotIn("+", mixed)
        black = scene_mark_from_bytes(_png_bytes(Image.new("RGB", (64, 64), (0, 0, 0))))
        self.assertEqual(black, "BLACK")
        single = scene_mark_from_bytes(_fixture_png("A2"))
        self.assertEqual(single, "A2")
