"""Fixed public diagnostics; private XCTest messages never leave this mapper."""

import json
import re

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

# Reviewed prefixes from AccessLifecycleContract (+Controls/+TransitionTiming),
# AccessLifecycleIOSUITests (+Settings/+Navigation), PlaybackHistoryIOSUITests
# (+Support), strict first-batch/filter/late-image/tvOS flows, EXIF ownership,
# ScenePresentationContractUITests, FilterSummaryIOSVisualUITests+Exif,
# FilterSummaryIOSVisualUITests+Launch, their public drivers and XCTest.
# Source locations and enum meanings: docs/CI_STRICT_RUNNER.md#reviewed-prefix-table.
# No activity marker exists in these flows. Suffixes (including values) are discarded.
PREFIX_RULES = (
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
    def object_pairs(pairs):
        value = {}
        for key, child in pairs:
            if key in DIAGNOSTIC_FIELDS and key in value:
                raise ValueError("duplicate failure diagnostic field")
            value[key] = child
        validate_diagnostic_fields(value)
        return value
    try:
        json.loads(data, object_pairs_hook=object_pairs)
    except (json.JSONDecodeError, UnicodeDecodeError):
        if any(('"' + field + '"').encode() in data for field in DIAGNOSTIC_FIELDS):
            raise ValueError("invalid failure diagnostic JSON")
