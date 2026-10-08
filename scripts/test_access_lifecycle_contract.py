"""Discovery entry point preserving the existing test class identities."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

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

from access_lifecycle_contract_test_validation_cases import FailClosedTestsCases

class FailClosedTests(FailClosedTestsCases, unittest.TestCase):
    pass


from access_lifecycle_contract_test_sensitive_scan_cases import SensitiveScanTestsCases

class SensitiveScanTests(SensitiveScanTestsCases, unittest.TestCase):
    pass


from access_lifecycle_contract_test_validation_cases import SlideshowReturnTestsCases

class SlideshowReturnTests(SlideshowReturnTestsCases, unittest.TestCase):
    pass


from access_lifecycle_contract_test_validation_cases import SettingsReturnWakeTestsCases

class SettingsReturnWakeTests(SettingsReturnWakeTestsCases, unittest.TestCase):
    pass


from access_lifecycle_contract_test_validation_cases import SystemPauseAnalogTimingTestsCases

class SystemPauseAnalogTimingTests(SystemPauseAnalogTimingTestsCases, unittest.TestCase):
    pass


from access_lifecycle_contract_test_display_cases import DisplayStrategyContractTestsCases

class DisplayStrategyContractTests(DisplayStrategyContractTestsCases, unittest.TestCase):
    pass


from access_lifecycle_contract_test_display_cases import PublicFixtureOriginalMetadataTestsCases

class PublicFixtureOriginalMetadataTests(PublicFixtureOriginalMetadataTestsCases, unittest.TestCase):
    pass


from access_lifecycle_contract_test_timing_cases import SettingsOpenOrderTestsCases

class SettingsOpenOrderTests(SettingsOpenOrderTestsCases, unittest.TestCase):
    pass


from access_lifecycle_contract_test_timing_cases import NewStableMarkTimingTestsCases

class NewStableMarkTimingTests(NewStableMarkTimingTestsCases, unittest.TestCase):
    pass


from access_lifecycle_contract_test_timing_cases import ModeContinueAndWakeHelperTestsCases

class ModeContinueAndWakeHelperTests(ModeContinueAndWakeHelperTestsCases, unittest.TestCase):
    pass


from access_lifecycle_contract_test_timing_cases import CaptureRegionIdentityTestsCases

class CaptureRegionIdentityTests(CaptureRegionIdentityTestsCases, unittest.TestCase):
    pass


if __name__ == "__main__":
    unittest.main()
