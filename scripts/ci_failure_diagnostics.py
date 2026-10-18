"""Fixed public diagnostics; private XCTest messages never leave this mapper."""

import json
import math
import re

from ci_summary import BOUNDED_DIAGNOSTICS_FIELD

FAILURE_PHASES = frozenset({"interval_setup", "hidden_controls", "visible_scene_capture", "background_return",
                            "continue_timing", "paused_hold", "settings_navigation", "control_action", "unknown",
                            "firstboot_setup", "cold_relaunch", "mode_selection", "playback_entry", "history_navigation",
                            "pause_window", "late_image", "image_recovery", "exif_ownership", "filter_selection",
                            "filter_edit", "server_switch", "display_policy"})
FAILURE_CLASSES = frozenset({"interval_readback", "hidden_controls", "scene_identity", "process_lifetime",
                             "timing_window", "navigation", "snapshot_query", "unknown", "control_state", "focus",
                             "evidence_capture", "probe_readback", "fixture_response", "exif_visibility",
                             "exif_correspondence"})
DIAGNOSTIC_FIELDS = frozenset({"failure_phase", "failure_class"})
VALIDATOR_FAILURE_FIELD = "validator_failure_message"
VALIDATOR_FAILURE_MAX_LENGTH = 512
VALIDATOR_FAILURE_REDACTED = "[redacted validator failure]"
FIRST_FAILURE_FIELD = "first_failure"
FIRST_FAILURE_MAX_BYTES = 8192
FIRST_FAILURE_MAX_SECONDS = 86400
FIRST_FAILURE_MAX_IMAGE_BYTES = 1024 * 1024
FIRST_FAILURE_MAX_IMAGE_SIDE = 1536
# The only reviewed element table. Fixture runners supply this vocabulary to the test-only recorder.
FIRST_FAILURE_ELEMENTS = (
    "unknown", "app-window", "system.reduce-motion", "simulator",
    "firstboot.serverURL.field", "firstboot.apiKey.field", "firstboot.testConnection.button",
    "firstboot.saveConfig.button", "mode.random.button", "mode.filtered.button", "mode.continue.button",
    "slideshow.control.settings.button", "slideshow.control.previous.button", "slideshow.control.playPause.button",
    "slideshow.control.next.button", "slideshow.hiddenWakeReceiver", "slideshow.currentAssetId.flag",
    "slideshow.scenePresentation.contract.summary", "slideshow.smartfill.currentManifest.flag",
    "slideshow.smartfill.manifest.flag", "slideshow.requestLifecycle.summary.flag",
    "slideshow.historyLedger.summary.flag", "settings.item.playback", "settings.item.cache",
    "settings.playback.autoPlay.toggle", "settings.playback.interval.slider",
    "settings.playback.showExif.toggle", "settings.playback.displayMode.picker",
    "settings.playback.displayMode.singlePhoto.option", "settings.playback.displayMode.smartFill.option",
    "settings.cache.clearDisk.button", "BackButton",
)
FIRST_FAILURE_STEPS = ("unknown", "launch-app", "reveal-controls", "query-element", "select", "capture-frame",
    "settings-readback", "focus", "history-readback", "rotate", "wait-scene", "simulator-boot",
    "simulator-bootstatus", "simulator-readiness")
FIRST_FAILURE_ACTIONS = ("unknown", "none", "tap", "select", "up", "down", "left", "right", "back", "home",
    "play-pause", "rotate", "launch", "activate", "terminate", "type", "adjust")
FIRST_FAILURE_TIMING_FIELDS = ("since_action_issued_seconds", "since_action_returned_seconds", "action_duration_seconds",
    "wait_elapsed_seconds", "deadline_seconds", "capture_request_seconds", "capture_return_seconds", "state_age_seconds")


def validate_first_failure(receipt):
    """Validate a fixed public projection, never a raw assertion, AX tree or probe."""
    from ci_summary import require
    def exact(value, keys, where):
        require(isinstance(value, dict) and set(value) == set(keys), where + ": invalid fields")
    def choice(value, choices, where):
        require(isinstance(value, str) and value in choices, "first failure: invalid " + where)
    def number(value, maximum, where, *, minimum=0, integral=False):
        require(value is None or (type(value) in ((int,) if integral else (int, float))
                and minimum <= value <= maximum and math.isfinite(value)), where + ": invalid number")
    exact(receipt, {"schema_version", "source", "step", "element", "action", "timing", "state", "validator", "screenshot"},
          "first failure")
    require(type(receipt["schema_version"]) is int and receipt["schema_version"] == 1, "first failure: unsupported version")
    choice(receipt["source"], ("xctest", "validator", "preparation"), "source")
    choice(receipt["step"], FIRST_FAILURE_STEPS, "step")
    choice(receipt["element"], FIRST_FAILURE_ELEMENTS, "element")
    choice(receipt["action"], FIRST_FAILURE_ACTIONS, "action")
    timing = receipt["timing"]
    exact(timing, FIRST_FAILURE_TIMING_FIELDS, "first failure timing")
    for value in timing.values():
        number(value, FIRST_FAILURE_MAX_SECONDS, "first failure timing")
    start, end = (timing[key] for key in ("capture_request_seconds", "capture_return_seconds"))
    require(end is None or start is not None and end >= start, "first failure: capture times out of order")
    issued, returned = (timing[key] for key in ("since_action_issued_seconds", "since_action_returned_seconds"))
    require(returned is None or issued is not None and issued >= returned, "first failure: action times out of order")
    state = receipt["state"]
    exact(state, {"app", "surface", "observation", "control_bar", "focus", "history_count", "autoplay",
                  "orientation", "scene_status", "query_error_code"}, "first failure state")
    for key, choices, label in (
            ("app", ("unknown", "not-running", "background", "running-foreground"), "app state"),
            ("surface", ("unknown", "playback", "cache", "playback-settings", "mode", "firstboot", "system-settings"), "surface"),
            ("observation", ("unavailable", "cached", "failure-snapshot"), "state observation"),
            ("control_bar", ("visible", "hidden", "unknown"), "control bar"),
            ("focus", FIRST_FAILURE_ELEMENTS, "focus"),
            ("autoplay", ("on", "off", "unknown"), "autoplay"),
            ("orientation", ("portrait", "landscape", "not_applicable", "unknown"), "orientation"),
            ("scene_status", ("MATCH", "TRANSITION", "BLACK", "BLANK", "UNRECOGNIZABLE", "unknown"), "scene status")):
        choice(state[key], choices, label)
    number(state["history_count"], 2**31 - 1, "first failure state", integral=True)
    number(state["query_error_code"], 2**31 - 1, "first failure state", minimum=-(2**31), integral=True)
    validator = receipt["validator"]
    if validator is not None:
        exact(validator, {"kind", "slot", "axis"}, "first failure validator")
        choice(validator["kind"], ("unknown", "public-scene", "glyph", "fixture-pattern", "timing", "missing-evidence"), "validator kind")
        number(validator["slot"], 64, "first failure validator", minimum=1, integral=True)
        choice(validator["axis"], ("horizontal", "vertical", "both", "unknown"), "validator axis")
        require(receipt["source"] == "validator", "first failure: validator context requires validator source")
    screenshot = receipt["screenshot"]
    exact(screenshot, {"status", "width", "height", "bytes"}, "first failure screenshot")
    choice(screenshot["status"], ("captured", "validated-input", "unavailable", "withheld-privacy", "size-limit", "not-applicable"),
           "screenshot status")
    for key in ("width", "height"):
        number(screenshot[key], FIRST_FAILURE_MAX_IMAGE_SIDE, "first failure screenshot", minimum=1, integral=True)
    number(screenshot["bytes"], FIRST_FAILURE_MAX_IMAGE_BYTES, "first failure screenshot", minimum=1, integral=True)
    retained = screenshot["status"] in ("captured", "validated-input")
    require(all(screenshot[key] is not None if retained else screenshot[key] is None for key in ("width", "height", "bytes")),
            "first failure: screenshot measurements do not match status")
    if screenshot["status"] == "captured":
        require(receipt["source"] == "xctest" and state["app"] == "running-foreground"
                and state["surface"] in ("playback", "cache", "playback-settings", "mode")
                and not receipt["element"].startswith("firstboot.") and not state["focus"].startswith("firstboot."),
                "first failure: screenshot is not an allowed app window")
    if screenshot["status"] == "validated-input":
        require(receipt["source"] == "validator", "first failure: validated input requires validator source")
    if receipt["source"] == "validator":
        require(state["observation"] != "failure-snapshot", "first failure: validator cannot claim a failure snapshot")
    if receipt["source"] == "preparation":
        require(screenshot["status"] == "not-applicable" and state["app"] == "unknown"
                and state["observation"] == "unavailable" and state["history_count"] is None
                and all(state[key] == "unknown" for key in ("surface", "control_bar", "focus", "autoplay", "orientation", "scene_status")),
                "first failure: preparation cannot claim app evidence")
    require(len(json.dumps(receipt, ensure_ascii=True, allow_nan=False).encode()) <= FIRST_FAILURE_MAX_BYTES,
            "first failure: receipt exceeds size bound")


def render_first_failure(receipt):
    validate_first_failure(receipt)
    timing = receipt["timing"]
    def measured(key):
        value = timing[key]
        return "unavailable" if value is None else f"{value:g}s"
    return (f"{receipt['source']}/{receipt['step']}; {receipt['element']}; "
            f"since action={measured('since_action_issued_seconds')}; wait={measured('wait_elapsed_seconds')}; "
            f"deadline={measured('deadline_seconds')}; screenshot={receipt['screenshot']['status']}")


def public_first_failure(receipt):
    try:
        validate_first_failure(receipt)
    except (ValueError, TypeError, OverflowError):
        return None
    return receipt

# Fixed raise arguments and _require_named_png messages from the reviewed public contracts.
# Source synchronization guards keep these literal and closed-set copies current
# without importing image/fixture dependencies into the isolated trusted reader.
VALIDATOR_FIXED_PREFIXES = (
    # album_server_narrow_contract.py
    "Selectors must be Target/Class/method",
    "The same official method was counted more than once",
    "Zero executions or skips cannot be reported as success",
    "empty-album.json start_enabled may be not applicable only for the Settings filter editor entry",
    "empty-album.json start_enabled must be a recorded Boolean or the Settings editor not-applicable marker",
    "Album-empty member-manifest does not match the requested fixture",
    "Empty-selection start button id does not match the frozen contract",
    "Request logs, index or probes cannot serve as identity truth",
    "The target album needs screenshots of at least two different public identities",
    "The two playback screenshots must be different public identities; an asset ID is not visual proof",
    "The empty album must be the controlled empty fixture; the selection cannot be faked",
    "The empty-album branch cannot use a probe or enum in place of the screen",
    "The empty-result copy must come from the frozen existing production resource",
    "Missing empty-album result screenshot",
    "After the empty album, photos from the old non-empty pool must not keep playing",
    "Missing screenshot of A's selected scope and photo",
    "After switching servers there must be a screenshot of B's public pattern",
    "After switching servers the screen is still the same as A",
    "Missing B save-success screen",
    "Missing screen showing the old selection cleared",
    "ids in observed-ids.json must be a list of strings",
    "Empty observations cannot pass",
    "Observations assembled from the expected manifest cannot pass",
    "A server switch requires a non-empty continuous recording",
    "The server-switch recording was not finalized",
    "Unrecognizable input: empty-album result screenshot cannot be decoded",
    "A server switch requires the B server URL",
    "A server switch must use the suite runner with screen recording",
    # strict_e2e_photo_identity.py
    "Scene probe fields must be text",
    "Visual suites need Pillow. Run python3 -m pip install Pillow first, then run journey-b / pause-window / tvos-flow / tvos-album / tvos-person / tvos-switch.",
    "Unrecognizable input: unreadable public glyph slot: screenshot cannot be decoded",
    "unreadable public glyph slot: single photo color or public texture is missing; slot 1 (both axes)",
    "unreadable public glyph slot: conflicting public background patterns",
    "no public glyph",
    "system overlay box is outside the public frame",
    "unreadable public glyph slot",
    "Still the original photo after the first forward step",
    "Still the same photo after the second forward step",
    "The first back step must return to the first forward photo",
    "Photo changed after pausing over 10 seconds",
    "Still the same photo after resuming playback; it did not advance",
    "Scene round-trip pixels and index sequence disagree: pause publication changed",
    # strict_e2e_filter_contract.py
    "Empty playback membership cannot count as passing",
    "Repeated members cannot count as passing",
    "missing visual input person-conflict-normal.png",
    "single-photo surround still shows a sharp public photo mark; a second photo cannot count as background",
    "single-photo surround still has sharp public photo color-block edges; it cannot count as a blurred background",
    "single-photo surround still has unexplained sharp texture; it cannot be cropped away as blurred background",
    "single-photo surround does not match this photo's blurred background; multi-photo or unknown-frame risk remains",
    "display-policy screenshot is too small to check photo regions",
    "standalone display-policy suite must use fixture A only",
    "display-policy screenshot identity must come from public fixture photo marks",
    "Display strategy must be set through the real UI",
    "display policy must change from SmartFill to single-photo mode",
    "Missing multi-photo before, real settings action, or stable single-photo after screenshot",
    "missing the finite list of before-change candidate screenshots",
    "Before-change screenshot candidates exceed one complete finite rotation of the target album",
    "before-change candidate screenshots must be numbered consecutively in real order",
    "must use the first candidate screenshot in the finite rotation that meets the before-change multi-photo condition",
    "found extra candidate screenshots after the first one that met the condition",
    "display-before.png must keep the raw screenshot of the first valid candidate",
    "The before-change frame must be recognizable as a public fixture photo",
    "Multiple before-change photos cannot be faked by a transition",
    "The before-change frame must actually show at least two different photos",
    "The before-change frame must contain only fixture A; do not mix fixtures A and B or unknown content",
    "after-change cannot use a transition or unknown frame as passing: the stable photo region is still transitioning",
    "The after-change frame must be a recognizable, stable single-photo frame",
    "after-change frame must be a recognizable single-photo frame",
    "Request logs, indexes, and probes cannot be used as identity truth",
    "empty-selection.json start_enabled must be a Boolean",
    "member manifest fixture does not match runner fixture",
    "member manifest is not the frozen contract",
    "wins is not a product filter outcome",
    "Simulator Vision cannot substitute for a device; soloOnly must not be marked PASS",
    "An empty selection cannot start playback",
    "empty selection after server switch must come from the actual filter editor",
    "Unrecognizable input: target album screenshot cannot be decoded",
    "album replacement identity must come from real UI accessibility identifiers",
    "after replacement, UI identifiers must confirm the non-target album is selected",
    "after switching to the non-target album, the default mode must still be filtered playback",
    "after clearing filters and leaving the editor, the default mode must return to random playback",
    "start button id does not match the frozen contract",
    "empty-selection.json fields are incomplete",
    "empty-selection.json album_ids must contain only strings",
    "wins is not a product filter outcome and cannot be asserted as a filter result",
    "person-results.json is missing cases",
    "person-results.json is missing solo_only",
    "simulator Vision must fail or be UNVERIFIED",
    "observed-ids.json ids must be a list of strings",
    "single-photo identity after server switch must come from public fixture photo marks",
    "Single-photo mode must be applied through the real UI after switching servers",
    "single-photo frame after server switch still shows multiple photos",
    "vision-environment.json is missing vision_available",
    "device Vision is missing qualified_marks / face_counts",
    "device Vision face_counts must contain only integers",
    "request log has no checkable lines",
)
VALIDATOR_MANIFEST_PREFIXES = (
    "a person filter must be a separate person_id + mode",
    "member manifest fixture set is unknown",
    "member-manifest labels do not match classify_screenshot: must cover every public fixture photo",
    "member-manifest labels do not match classify_screenshot: every photo must MATCH a distinct classified label",
    "member-manifest labels do not match classify_screenshot: missing person_cases",
    "member-manifest independent object sets do not match fixture derivation",
    "fixture hash has drifted from the frozen contract",
    "member manifest is not the frozen contract",
    "member manifest fixture hash does not match the frozen contract",
    "Request logs, indexes, and probes cannot be used as identity truth",
    "Empty playback membership cannot count as passing",
    "An empty selection cannot start",
    "start button state does not match the selection contract",
    "Simulator Vision cannot substitute for a device; soloOnly must not be marked PASS",
    "Vision unavailable; soloOnly must not pass by accident",
    "An empty soloOnly result cannot pass by coincidence from an empty set",
)
# Retention readers still accept these retired messages; no nightly validator raises them.
VALIDATOR_HISTORICAL_PREFIXES = (
    "member-manifest labels do not match classify_screenshot: must cover all five photos",
    "member-manifest labels do not match classify_screenshot: all five must MATCH and tell A1–A5 apart",
    "An A screen must not pass as B",
    "Display policy cannot pass on enum/probe alone",
    "The fixture yields no multi-photo screen; fix the fixture/preconditions first",
    "A still frame mid-transition cannot pass",
    "After the change the screen must be a stable single-photo public identity",
    "Still multi-photo after the change; cannot pass as single-photo",
    "Display policy did not take effect",
    "server-switch-a-play-1: every slot must show the public pattern a",
)
VALIDATOR_FIXTURE_PATTERNS = ("a", "b", None)
VALIDATOR_IDENTITY_STATUSES = ("UNRECOGNIZABLE", "BLACK", "BLANK", "TRANSITION", "MATCH")
VALIDATOR_IDENTITY_MARKS = ("A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", None)

# No arbitrary filename, exception suffix or pixel values.
# See CI_STRICT_RUNNER.md#public-validator-failure-receipts for the public receipt contract.
_VALIDATOR_SCREENSHOT_STEM = (
    r"(?:person-normal|person-no-faces|person-conflict-normal(?:-[1-9][0-9]?)?|"
    r"album-playback-[123]|album-switch-b-play-[12]|server-switch-a-play-1|switch-b-play-[12]|"
    r"history-(?:start|first-next|second-next|first-previous|second-previous)|"
    r"pause-immediate|pause-after-10s|resumed)"
)
_VALIDATOR_SCREENSHOT = _VALIDATOR_SCREENSHOT_STEM + r"\.png"
_VALIDATOR_PREFIX = (
    r"(?:Unrecognizable input: )?(?:no public glyph|mixed public glyphs|"
    r"unreadable public glyph slot(?:: (?:single photo color or public texture is missing|"
    r"public photo colors are missing or mixed|conflicting public background patterns|"
    r"foreign public background pattern|screenshot cannot be decoded))?|"
    r"every slot must show the public glyph of fixture [AB]|"
    r"unreadable public glyph: (?:AttributeError|IndexError|KeyError|OSError|TypeError|"
    r"UnidentifiedImageError|ValueError))"
)
_VALIDATOR_EXPECTED_PATTERN = "(?:" + "|".join(re.escape(value) for value in VALIDATOR_FIXTURE_PATTERNS
                                             if value is not None) + ")"
_VALIDATOR_PATTERN = "(?:" + "|".join(re.escape(str(value)) for value in VALIDATOR_FIXTURE_PATTERNS) + ")"
_VALIDATOR_STATUS = "(?:" + "|".join(map(re.escape, VALIDATOR_IDENTITY_STATUSES)) + ")"
_VALIDATOR_MARK = "(?:" + "|".join(re.escape(str(value)) for value in VALIDATOR_IDENTITY_MARKS) + ")"
_VALIDATOR_PREFIX = (
    "(?:" + _VALIDATOR_PREFIX + "|"
    + "|".join(map(re.escape, VALIDATOR_FIXED_PREFIXES + VALIDATOR_MANIFEST_PREFIXES
                   + VALIDATOR_HISTORICAL_PREFIXES))
    + rf"|{_VALIDATOR_SCREENSHOT_STEM} public pattern must be {_VALIDATOR_EXPECTED_PATTERN}, got {_VALIDATOR_PATTERN}"
    + rf"|Unrecognizable input cannot count as passing: status={_VALIDATOR_STATUS} mark={_VALIDATOR_MARK})"
)
_VALIDATOR_PREFIX_ONLY = re.compile(_VALIDATOR_PREFIX)
_VALIDATOR_COUNT = r"(?:0|[1-9][0-9]{0,2})"
_VALIDATOR_AXIS = r"(?:horizontal|vertical|both axes)"
_VALIDATOR_CONTEXT = (
    rf"(?:screenshot {_VALIDATOR_SCREENSHOT}|slot {_VALIDATOR_COUNT} \({_VALIDATOR_AXIS}\)|"
    rf"{_VALIDATOR_COUNT} slots? \({_VALIDATOR_AXIS}\)|"
    rf"(?:horizontal|vertical) axis, (?:slot count unresolved|{_VALIDATOR_COUNT} completed slots?)|"
    rf"observed fixture [AB] in all {_VALIDATOR_COUNT} slots? \({_VALIDATOR_AXIS}\)|"
    r"horizontal and vertical axes disagree|slot count and axes unresolved|context unresolved)"
)
_VALIDATOR_MESSAGE = re.compile(rf"{_VALIDATOR_PREFIX}(?:; {_VALIDATOR_CONTEXT}){{1,32}}")


def validate_validator_failure_message(value):
    """Validate public text without echoing refused candidate values."""
    if not isinstance(value, str) or not value:
        raise ValueError("validator failure message must be nonempty text")
    if len(value) > VALIDATOR_FAILURE_MAX_LENGTH:
        raise ValueError("validator failure message exceeds length bound")
    if value not in {"unresolved", VALIDATOR_FAILURE_REDACTED} and _VALIDATOR_MESSAGE.fullmatch(value) is None:
        raise ValueError("validator failure message is not public context")


def public_validator_failure_message(value):
    """Keep a failed record when its optional candidate receipt is unsafe."""
    if value is None:
        return "unresolved"
    if (isinstance(value, str) and _VALIDATOR_PREFIX_ONLY.fullmatch(value) is not None
            and _VALIDATOR_MESSAGE.fullmatch(value) is None):
        value += "; context unresolved"
    try:
        scan_diagnostic_json(json.dumps({VALIDATOR_FAILURE_FIELD: value}).encode())
    except (ValueError, TypeError):
        return VALIDATOR_FAILURE_REDACTED
    return value

# Reviewed prefixes from AccessLifecycleContract (+Controls/+TransitionTiming),
# AccessLifecycleIOSUITests (+Settings/+Navigation), PlaybackHistoryIOSUITests
# (+Support), strict first-batch/filter/late-image/tvOS flows, EXIF ownership,
# ScenePresentationContractUITests, FilterSummaryIOSVisualUITests+Exif,
# FilterSummaryIOSVisualUITests+Launch, their public drivers and XCTest.
# Source locations and enum meanings: docs/CI_STRICT_RUNNER.md#reviewed-prefix-table.
# No activity marker exists in these flows. Suffixes (including values) are discarded.
PREFIX_RULES = (
    ("Editor album card must show the manifest-selected album and photo counts", "server_switch", "control_state"),
    ("The iOS slider must be settable to ", "interval_setup", "interval_readback"),
    ("The control bar is not hidden yet; cannot verify the first wake.", "hidden_controls", "hidden_controls"),
    ("The first wake should only bring up the control bar.", "hidden_controls", "hidden_controls"),
    ("Switching photos while waking must not count as a pass", "hidden_controls", "scene_identity"),
    ("Jumping to another photo on return from background must not count as a pass", "background_return", "scene_identity"),
    ("Background return is missing the original process identity", "background_return", "process_lifetime"),
    ("System pause analog must not rebuild the process", "background_return", "process_lifetime"),
    ("The process exited after Home; activate would Open/rebuild it", "background_return", "process_lifetime"),
    ("Must return to the playback page after coming back from the background.", "background_return", "navigation"),
    ("On background return, do not wait a playback cycle before capturing identity", "background_return", "timing_window"),
    ("The first-half evidence window after Continue crossed its bounds;", "continue_timing", "timing_window"),
    ("The same public pattern must stay for the first half of T after Continue", "continue_timing", "scene_identity"),
    ("No automatic photo change was captured within T±2;", "continue_timing", "timing_window"),
    ("Automatic photo change occurred before T-2;", "continue_timing", "timing_window"),
    ("After about a full T, it must switch to the next scene", "continue_timing", "scene_identity"),
    ("An automatic photo change during the pause hold must not count as a pass", "paused_hold", "scene_identity"),
    ("The pause hold must last at least T+2 seconds", "paused_hold", "timing_window"),
    ("After pausing, the rendered transform/frame of every SmartFill slot must stay frozen", "paused_hold", "scene_identity"),
    ("After pausing, the photo pixels outside the control bar and entry hint must stay frozen:", "paused_hold", "scene_identity"),
    ("Screenshot must not be empty:", "unknown", "unknown"),
    ("No new stable frame appeared before going to the background", "visible_scene_capture", "scene_identity"),
    ("Turning off Autoplay in settings must take effect immediately", "unknown", "unknown"),
    ("After opening settings, enter playback settings before locating the interval row", "settings_navigation", "navigation"),
    ("Playback page should show the 'Next' button", "control_action", "hidden_controls"),
    ("The first-boot page must show the Save Settings button.", "firstboot_setup", "navigation"),
    ("After a successful save, the app must reach mode selection.", "firstboot_setup", "navigation"),
    ("A fresh install must reach the normal first-boot page.", "firstboot_setup", "navigation"),
    ("The first-boot page must show the API Key field.", "firstboot_setup", "navigation"),
    ("The first-boot page must show the Test Connection button.", "firstboot_setup", "navigation"),
    ("Save must become enabled after a real connection test succeeds.", "firstboot_setup", "control_state"),
    ("A cold launch with saved settings must not return to the first-boot page.", "cold_relaunch", "navigation"),
    ("A configured cold launch must go straight to the playback page.", "cold_relaunch", "navigation"),
    ("The mode page must offer ", "mode_selection", "navigation"),
    ("Chose filter but reached the playback page, so the mode card tap did not register.", "mode_selection", "navigation"),
    ("Still on the mode page after Continue; filter mode did not start.", "mode_selection", "navigation"),
    ("Filter mode must reach the filter summary page.", "mode_selection", "navigation"),
    ("Going back from the filter summary must return to mode selection.", "mode_selection", "navigation"),
    ("Random mode must reach the playback page.", "playback_entry", "navigation"),
    ("The playback page must show the Previous button.", "control_action", "hidden_controls"),
    ("After auto-advance, the playback controls must be revealable.", "control_action", "hidden_controls"),
    ("The playback page must show Play/Pause.", "control_action", "hidden_controls"),
    ("After pausing, the playback controls must still be revealable.", "control_action", "hidden_controls"),
    ("After pausing, the control value must be play.", "control_action", "control_state"),
    ("Resuming must continue from the current photo, with the control value back to pause.", "control_action", "control_state"),
    ("Previous must be disabled at the history boundary when playback starts.", "history_navigation", "control_state"),
    ("After two Next taps, Previous must be enabled.", "history_navigation", "control_state"),
    ("After a pause of at least 10 seconds, autoplay must not resume on its own.", "paused_hold", "control_state"),
    ("probe_hit=MISS: frame-synchronized probe never saw outgoing translucent and incoming opacity=0 in 7 s.", "pause_window", "timing_window"),
    ("visual_verdict=MISSING_FRAMES: missing a window-detected, after-pause, after-pause-0_3s or play-to-pause keepAlways frame.", "pause_window", "evidence_capture"),
    ("visual_verdict=BLACK_OR_BLANK: synced probe missing after pause, or outgoing opacity already 0.", "pause_window", "probe_readback"),
    ("After pausing, the synced probe does not meet outgoing opacity>0 and incoming opacity=0.", "pause_window", "probe_readback"),
    ("The paused pause-window probe identity must not change.", "pause_window", "scene_identity"),
    ("Paused pause-window frames must be pixel-identical.", "pause_window", "scene_identity"),
    ("After late completion the current public mark must stay: no flash back, all black or unreadable: ", "late_image", "scene_identity"),
    ("Next must be tappable twice right after entering the slideshow, before old image requests finish.", "late_image", "navigation"),
    ("The fixture must actually deliver a failing image response", "image_recovery", "fixture_response"),
    ("Fixture control must acknowledge its response mode", "image_recovery", "fixture_response"),
    ("After turning EXIF off, the info card in the upper-right area of the public photo must disappear from the screen.", "exif_ownership", "exif_visibility"),
    ("The required PNG with EXIF off still shows the info card.", "exif_ownership", "exif_visibility"),
    ("Can't check EXIF: photo status ", "unknown", "scene_identity"),
    ("EXIF does not match the photo: mark=", "unknown", "exif_correspondence"),
    ("The EXIF toggle must reach the target state through the real settings.", "unknown", "control_state"),
    ("Default focus on the mode selection page must land on random playback.", "mode_selection", "focus"),
    ("Focus on the mode page must be able to move to filtered playback.", "mode_selection", "focus"),
    ("After choosing a mode, focus must be able to move down to the Continue button.", "mode_selection", "focus"),
    ("After returning to mode selection, default focus must go back to random playback.", "mode_selection", "focus"),
    ("After Continue, the app must reach the playback page and show the control bar.", "playback_entry", "navigation"),
    ("Before sending the wake arrow key, the hidden receiver layer must have system focus.", "hidden_controls", "focus"),
    ("After the control bar wakes again, focus must land on Play/Pause.", "hidden_controls", "focus"),
    ("After pressing Down, the hint and the control bar must hide.", "hidden_controls", "hidden_controls"),
    ("With the control bar hidden, an arrow key must wake it again.", "hidden_controls", "hidden_controls"),
    ("Default focus on the filter summary must land on the album filter.", "filter_selection", "focus"),
    ("Focus must land on the target album.", "unknown", "focus"),
    ("The album list must show ", "unknown", "navigation"),
    ("An empty album must show the frozen existing production empty-result copy and must not keep the old non-empty pool", "filter_edit", "scene_identity"),
    ("Start Playback must be disabled with an empty selection.", "filter_selection", "control_state"),
    ("Start Playback must be disabled with 0 albums / 0 people.", "filter_selection", "control_state"),
    ("Start Playback must be enabled after selecting the target album.", "filter_selection", "control_state"),
    ("Filtered playback must be startable after selecting the target album", "filter_selection", "control_state"),
    ("The album filter entry must be shown.", "unknown", "navigation"),
    ("The person filter entry must be shown.", "unknown", "navigation"),
    ("Opening the album filter must show album cards or a loading state.", "unknown", "navigation"),
    ("Back from the people list must return to the filter screen.", "filter_selection", "navigation"),
    ("Back from the album list must return to the filter screen.", "unknown", "navigation"),
    ("Focus must land on the target person.", "filter_selection", "focus"),
    ("Start Playback must open the playback screen.", "unknown", "navigation"),
    ("Clear selection must actually receive remote focus", "filter_edit", "focus"),
    ("The editor's Done must actually receive remote focus", "filter_edit", "focus"),
    ("After Clear, both target and non-target albums must really become unselected; re-tapping each card must not stand in for the clear result", "filter_edit", "control_state"),
    ("The filter settings editor must offer a Done entry", "filter_edit", "navigation"),
    ("Finishing the edit must return to the real playback settings screen", "filter_edit", "navigation"),
    ("Server B must clear A's album selection", "server_switch", "control_state"),
    ("After switching servers the UI must not keep server A album/person IDs: ", "server_switch", "control_state"),
    ("The display mode's selected state must be read back.", "display_policy", "control_state"),
    ("No two distinct photos seen within four public album candidates; all failing originals are kept.", "display_policy", "scene_identity"),
    ("After the change, a still frame taken mid-transition must not pass", "display_policy", "scene_identity"),
    ("After changing the display mode, playback must still be on screen in the same live process.", "display_policy", "navigation"),
    ("No two distinct target-album photos were seen in one full four-frame candidate rotation; all candidate originals were kept.", "display_policy", "scene_identity"),
    ("After the change it must be a stable single photo from the target album, not a transition or multi-photo", "display_policy", "scene_identity"),
    ("The same live app process must run before and after the display policy change", "display_policy", "process_lifetime"),
    ("After the server switch, single-photo mode must show a stable single photo from B's target album", "server_switch", "scene_identity"),
    ("The same process must run before and after applying single-photo mode after the server switch", "server_switch", "process_lifetime"),
    ("SmartFill must expose the complete manifest, stable visible render state and history cursor together", "visible_scene_capture", "probe_readback"),
    ("After tapping next, the fully visible SmartFill scene identity did not change in ", "history_navigation", "scene_identity"),
    ("scene identity did not change", "history_navigation", "scene_identity"),
    ("Pausing must freeze the current transform progress", "paused_hold", "scene_identity"),
    ("The new scene from a manual next while paused must stay still at p=0", "paused_hold", "scene_identity"),
    ("The scene from a manual previous while paused must stay still at p=0", "paused_hold", "scene_identity"),
    ("Play must make the current still scene start moving from p=0 immediately", "control_action", "scene_identity"),
    ("After starting playback, the playback page should open and show the control bar", "playback_entry", "navigation"),
    ("The slideshow control never became tappable before the deadline.", "control_action", "hidden_controls"),
    ("The slideshow Settings tap had no observed outcome before the deadline.", "settings_navigation", "navigation"),
    ("The slideshow Settings button must be ready before opening playback settings.", "settings_navigation", "hidden_controls"),
    ("Playback page should show the settings button", "unknown", "hidden_controls"),
    ("After entering the playback page, the settings button should be visible", "playback_entry", "navigation"),
    ("Before each screenshot, the playback control bar should wake up reliably", "visible_scene_capture", "hidden_controls"),
    ("The control bar may have auto-hidden while waiting for the sampling overlay; it should wake up again before tapping next", "visible_scene_capture", "hidden_controls"),
    ("Before retrying next, the playback control bar should wake up again", "control_action", "hidden_controls"),
    ("Could not return from the playback settings page to the slideshow", "settings_navigation", "navigation"),
    ("Failed to get matching snapshot", "unknown", "snapshot_query"),
    ("Failed to determine hittability", "unknown", "snapshot_query"),
)


def unknown_diagnostics():
    return {"failure_phase": "unknown", "failure_class": "unknown"}


def classify_messages(messages):
    matches = set()
    for message in messages:
        if not isinstance(message, str):
            return unknown_diagnostics()
        # XCTest assertion wrappers and Swift's caught AssertionError.message wrapper.
        text = re.sub(r"^(?:failed - |XCTAssert\w+ failed(?:\:.*?)? - )", "", message)
        for wrapper in ('failed: caught error: "message(\\"', 'failed: caught error: "message("',
                        'message(\\"', 'message("'):
            if text.startswith(wrapper):
                text = text[len(wrapper):]
                break
        match = next(((phase, kind) for prefix, phase, kind in PREFIX_RULES if text.startswith(prefix)), None)
        if match is None:
            return unknown_diagnostics()
        matches.add(match)
    if len(matches) != 1:
        return unknown_diagnostics()
    phase, kind = matches.pop()
    return {"failure_phase": phase, "failure_class": kind}


def legacy_diagnostics(payload):
    messages = {}
    def visit(value):
        if isinstance(value, dict):
            summaries = value.get("testFailureSummaries")
            rows = summaries.get("_values", []) if isinstance(summaries, dict) else []
            for row in rows if isinstance(rows, list) else []:
                if not isinstance(row, dict):
                    continue
                name = row.get("testCaseName", {}).get("_value") if isinstance(row.get("testCaseName"), dict) else None
                if isinstance(name, str):
                    key = name.removesuffix("()").replace(".", "/")
                    raw = row.get("message")
                    messages.setdefault(key, []).append(raw.get("_value") if isinstance(raw, dict) else None)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(payload)
    return {key: classify_messages(values) for key, values in messages.items()}


def test_node_diagnostics(payload):
    diagnostics = {}
    def visit(node):
        if not isinstance(node, dict):
            return
        if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
            validate_diagnostic_fields(node)
            key = str(node.get("nodeIdentifier", "")).removesuffix("()")
            diagnostics[key] = ({field: node[field] for field in DIAGNOSTIC_FIELDS}
                                if DIAGNOSTIC_FIELDS <= node.keys() else unknown_diagnostics())
        children = node.get("children", [])
        for child in children if isinstance(children, list) else []:
            visit(child)
    nodes = payload.get("testNodes", []) if isinstance(payload, dict) else []
    for node in nodes if isinstance(nodes, list) else []:
        visit(node)
    return diagnostics


def validate_diagnostic_fields(value):
    """Reject free text, unpaired fields and non-string values, without echoing them."""
    if isinstance(value, dict):
        if FIRST_FAILURE_FIELD in value:
            validate_first_failure(value[FIRST_FAILURE_FIELD])
        if BOUNDED_DIAGNOSTICS_FIELD in value:
            from ci_bounded_diagnostics import validate_receipt
            validate_receipt(value[BOUNDED_DIAGNOSTICS_FIELD])
        if VALIDATOR_FAILURE_FIELD in value:
            validate_validator_failure_message(value[VALIDATOR_FAILURE_FIELD])
        if DIAGNOSTIC_FIELDS & value.keys():
            if not DIAGNOSTIC_FIELDS <= value.keys():
                raise ValueError("failure diagnostics require both enum fields")
            if (not isinstance(value["failure_phase"], str) or value["failure_phase"] not in FAILURE_PHASES
                    or not isinstance(value["failure_class"], str) or value["failure_class"] not in FAILURE_CLASSES):
                raise ValueError("failure diagnostics contain a non-allowlisted enum")
        for child in value.values():
            validate_diagnostic_fields(child)
    elif isinstance(value, list):
        for child in value:
            validate_diagnostic_fields(child)


def scan_diagnostic_json(data):
    diagnostic_fields = DIAGNOSTIC_FIELDS | {VALIDATOR_FAILURE_FIELD, BOUNDED_DIAGNOSTICS_FIELD, FIRST_FAILURE_FIELD}
    bounded_seen = False
    first_failure_seen = False
    duplicate_seen = False
    def object_pairs(pairs):
        nonlocal bounded_seen, first_failure_seen, duplicate_seen
        value = {}
        for key, child in pairs:
            if key in diagnostic_fields and key in value:
                raise ValueError("duplicate failure diagnostic field")
            duplicate_seen |= key in value
            value[key] = child
        bounded_seen |= BOUNDED_DIAGNOSTICS_FIELD in value
        first_failure_seen |= FIRST_FAILURE_FIELD in value
        validate_diagnostic_fields(value)
        return value
    try:
        json.loads(data, object_pairs_hook=object_pairs)
        if bounded_seen and duplicate_seen:
            raise ValueError("duplicate bounded diagnostic JSON key")
        if first_failure_seen and duplicate_seen:
            raise ValueError("duplicate first failure JSON key")
    except (json.JSONDecodeError, UnicodeDecodeError):
        ascii_keys = re.sub(rb"\\u00([0-9a-fA-F]{2})", lambda match: bytes([int(match[1], 16)]), data)
        if any(('"' + field + '"').encode() in ascii_keys for field in (BOUNDED_DIAGNOSTICS_FIELD, FIRST_FAILURE_FIELD)) or any(
                ('"' + field + '"').encode() in data for field in DIAGNOSTIC_FIELDS | {VALIDATOR_FAILURE_FIELD}):
            raise ValueError("invalid failure diagnostic JSON")
