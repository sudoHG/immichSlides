"""Fixed public diagnostics; private XCTest messages never leave this mapper."""

import json
import re

FAILURE_PHASES = frozenset({"interval_setup", "hidden_controls", "visible_scene_capture", "background_return",
                            "continue_timing", "paused_hold", "settings_navigation", "control_action", "unknown"})
FAILURE_CLASSES = frozenset({"interval_readback", "hidden_controls", "scene_identity", "process_lifetime",
                             "timing_window", "navigation", "snapshot_query", "unknown"})
DIAGNOSTIC_FIELDS = frozenset({"failure_phase", "failure_class"})

# Reviewed prefixes from AccessLifecycleContract (+Controls/+TransitionTiming),
# AccessLifecycleIOSUITests (+Settings/+Navigation), PlaybackHistoryIOSUITests
# (+Support), FilterSummaryIOSVisualUITests+Exif and XCTest.
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
    ("Screenshot must not be empty:", "visible_scene_capture", "scene_identity"),
    ("No new stable frame appeared before going to the background", "visible_scene_capture", "scene_identity"),
    ("Turning off Autoplay in settings must take effect immediately", "settings_navigation", "navigation"),
    ("After opening settings, enter playback settings before locating the interval row", "settings_navigation", "navigation"),
    ("Playback page should show the 'Next' button", "control_action", "hidden_controls"),
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
