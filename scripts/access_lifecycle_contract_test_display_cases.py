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

class DisplayStrategyContractTestsCases:
    def test_single_photo_swap_pair_fails_closed(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _single_photo_swap_display("display-before.png"),
                _single_photo_swap_display("display-after.png"),
            )
        message = str(raised.exception)
        self.assertTrue("portrait or square photo" in message or "single public fixture photo" in message, message)


    def test_pool_end_single_photo_pair_fails_closed(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _pool_end_single_photo_display("display-before.png"),
                _pool_end_single_photo_display("display-after.png"),
            )
        message = str(raised.exception)
        self.assertTrue("last pool photo" in message or "Smart Fill" in message, message)


    def test_pool_end_single_photo_inspection_keeps_region_classification(self) -> None:
        report = inspect_display_strategy(
            _pool_end_single_photo_display("display-before.png"),
            _pool_end_single_photo_display("display-after.png"),
        )
        error = str(report.get("error") or "")
        self.assertTrue("last pool photo" in error or "Smart Fill" in error, error)
        self.assertEqual(report["before"]["mark"], "A5")
        self.assertEqual(report["after"]["regions"]["center"]["mark"], "A5")
        self.assertEqual(report["after"]["regions"]["left"]["mark"], "A5")
        self.assertEqual(report["partner_marks"], [])


    def test_unchanged_fullbleed_pair_fails_closed(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _unchanged_fullbleed_display("display-before.png"),
                _unchanged_fullbleed_display("display-after.png"),
            )
        self.assertIn("Display policy did not take effect", str(raised.exception))


    def test_a1_fullbleed_before_fails_even_with_smart_fill_after(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _fixture_png("A1"),
                _compose_smart_fill("A1", "A3"),
            )
        self.assertIn("full-bleed A1", str(raised.exception))
        self.assertIn("A1", str(raised.exception))


    def test_a5_pool_end_before_fails_even_with_smart_fill_after(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _fixture_png("A5"),
                _compose_smart_fill("A5", "A2"),
            )
        self.assertIn("last pool photo A5", str(raised.exception))


    def test_a4_landscape_before_is_not_letterbox_surface(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _fixture_png("A4"),
                _compose_smart_fill("A4", "A2"),
            )
        self.assertIn("portrait or square photo", str(raised.exception))


    def test_before_side_partner_is_not_letterbox(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _compose_side_partner("A2", "A3"),
                _compose_smart_fill("A2", "A4"),
            )
        self.assertIn("second public fixture", str(raised.exception))


    def test_assert_display_before_letterbox_rejects_fullbleed_and_pool_end(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_before_letterbox("A1", [])
        self.assertIn("full-bleed A1", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_before_letterbox("A5", [])
        self.assertIn("last pool photo A5", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_before_letterbox("A4", [])
        self.assertIn("portrait or square photo", str(raised.exception))
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_before_letterbox("A2", ["A3"])
        self.assertIn("second public fixture", str(raised.exception))
        assert_display_before_letterbox("A2", [])
        assert_display_before_letterbox("A3", [])


    def test_side_by_side_regions_pass_during_full_screen_transition(self) -> None:
        # A2 on the left and A3 on the right match by region even when the full-screen color mix is TRANSITION.
        report = assert_display_strategy_visible(
            _side_by_side_transition_display("display-before.png"),
            _side_by_side_transition_display("display-after.png"),
        )
        self.assertIsNone(report.get("error"))
        self.assertEqual(report["before_mark"], "A2")
        self.assertIn("A3", report["partner_marks"])
        self.assertEqual(report["after"]["regions"]["full"]["status"], "TRANSITION")
        self.assertEqual(report["after"]["regions"]["left"]["status"], "MATCH")
        self.assertEqual(report["after"]["regions"]["left"]["mark"], "A2")
        self.assertEqual(report["after"]["regions"]["right"]["status"], "MATCH")
        self.assertEqual(report["after"]["regions"]["right"]["mark"], "A3")
        self.assertFalse(report.get("before_partner_marks"))


    def test_side_by_side_public_fixtures_pass_despite_full_transition(self) -> None:
        report = assert_display_strategy_visible(
            _fixture_png("A2"),
            _side_by_side("A2", "A3"),
        )
        self.assertIsNone(report.get("error"))
        self.assertEqual(report["before_mark"], "A2")
        self.assertIn("A3", report["partner_marks"])
        self.assertEqual(report["after"]["regions"]["full"]["status"], "TRANSITION")
        self.assertEqual(report["after"]["regions"]["left"]["mark"], "A2")
        self.assertEqual(report["after"]["regions"]["right"]["mark"], "A3")


    def test_checkerboard_transition_without_anchor_match_fails_closed(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_strategy_visible(
                _fixture_png("A2"),
                _checkerboard_mix("A2", "A3"),
            )
        self.assertIn("TRANSITION", str(raised.exception))


    def test_letterbox_a2_before_with_partner_after_passes(self) -> None:
        report = assert_display_strategy_visible(
            _fixture_png("A2"),
            _compose_smart_fill("A2", "A3"),
        )
        self.assertIsNone(report.get("error"))
        self.assertEqual(report["before_mark"], "A2")
        self.assertIn("A3", report["partner_marks"])
        self.assertFalse(report.get("before_partner_marks"))


    def test_display_after_pause_fails_pool_burn(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_display_before_pool_burn(
                [
                    "pause",
                    "after-next",
                    "after-play",
                    "before-background",
                    "after-background",
                    "before-wake",
                    "after-wake",
                    "display-before",
                    "display-after",
                ]
            )
        self.assertIn("exhausts the playback pool", str(raised.exception))


    def test_display_before_pause_is_allowed(self) -> None:
        assert_display_before_pool_burn(
            [
                "display-before",
                "display-after",
                "pause",
                "after-next",
                "after-play",
                "before-background",
                "after-background",
                "before-wake",
                "after-wake",
            ]
        )


    def test_hidden_control_wake_before_display_is_not_pool_burn(self) -> None:
        # After a restart the control bar may already be hidden; waking does not advance the random pool, so it is not
        # pool burning.
        assert_display_before_pool_burn(
            [
                "hidden-control-wake-2-before",
                "hidden-control-wake-2-after",
                "display-before",
                "display-after",
                "pause",
            ]
        )


    def test_exhausted_pool_has_no_unshown_partner(self) -> None:
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_unshown_display_partners(
                screenshot_order=[
                    "pause",
                    "after-next",
                    "after-play",
                    "after-background",
                    "after-wake",
                    "display-before",
                ],
                scenes={
                    "pause": "A1",
                    "after_next": "A2",
                    "after_play": "A2",
                    "after_background": "A3",
                    "after_wake": "A4",
                },
                before_mark="A5",
            )
        self.assertIn("unshown partner", str(raised.exception))


    def test_display_first_keeps_unshown_partners(self) -> None:
        assert_unshown_display_partners(
            screenshot_order=["display-before", "display-after", "pause"],
            scenes={"pause": "A1"},
            before_mark="A1",
        )


class PublicFixtureOriginalMetadataTestsCases:
    def test_old_low_resolution_original_metadata_is_rejected(self) -> None:
        # A2 at 180x320 and A3 at 300x300 cannot reach 0.85 effective pixels in Apple TV's two-photo slots.
        with self.assertRaises(AccessLifecycleContractError) as raised:
            assert_appletv_double_layout_visible((("A2", 180, 320), ("A3", 300, 300)))
        self.assertIn("effective pixels too low", str(raised.exception))


    def test_letterbox_fixture_originals_plan_visible_double(self) -> None:
        assets = {asset["label"]: asset for asset in _fixture_data("a")["assets"]}
        assert_appletv_double_layout_visible(
            (
                ("A2", int(assets["A2"]["width"]), int(assets["A2"]["height"])),
                ("A3", int(assets["A3"]["width"]), int(assets["A3"]["height"])),
            )
        )


    def test_public_fixture_png_identity_pixels_stay_small(self) -> None:
        fixture = _fixture_data("a")
        images = fixture["images"]
        by_label = {asset["label"]: asset for asset in fixture["assets"]}
        a2 = Image.open(io.BytesIO(images[by_label["A2"]["id"]]))
        a3 = Image.open(io.BytesIO(images[by_label["A3"]["id"]]))
        self.assertEqual(a2.size, (180, 320))
        self.assertEqual(a3.size, (300, 300))
        self.assertEqual(classify_screenshot(images[by_label["A2"]["id"]]).mark, "A2")
        self.assertEqual(classify_screenshot(images[by_label["A3"]["id"]]).mark, "A3")
