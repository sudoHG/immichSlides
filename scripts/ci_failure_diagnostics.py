"""Fixed public diagnostics; private XCTest messages never leave this mapper."""

import json
import math
import re
from copy import deepcopy

from ci_summary import BOUNDED_DIAGNOSTICS_FIELD

FAILURE_PHASES = frozenset({"interval_setup", "hidden_controls", "visible_scene_capture", "background_return",
                            "continue_timing", "paused_hold", "settings_navigation", "control_action", "unknown",
                            "firstboot_setup", "cold_relaunch", "mode_selection", "playback_entry", "history_navigation",
                            "pause_window", "late_image", "image_recovery", "exif_ownership", "filter_selection",
                            "filter_edit", "server_switch", "display_policy",
                            "history_start_capture", "history_first_next_capture", "history_second_next_capture",
                            "history_first_previous_capture", "history_second_previous_capture",
                            "rotation_start_capture", "rotation_landscape_capture", "rotation_portrait_capture"})
FAILURE_CLASSES = frozenset({"interval_readback", "hidden_controls", "scene_identity", "process_lifetime",
                             "timing_window", "navigation", "snapshot_query", "unknown", "control_state", "focus",
                             "evidence_capture", "probe_readback", "fixture_response", "exif_visibility",
                             "exif_correspondence"})
DIAGNOSTIC_FIELDS = frozenset({"failure_phase", "failure_class"})
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
    "simulator-bootstatus", "simulator-readiness", "mode-card", "mode-continue", "mode-departure", "save-password-prompt")
FIRST_FAILURE_ACTIONS = ("unknown", "none", "tap", "select", "up", "down", "left", "right", "back", "home",
    "play-pause", "rotate", "launch", "activate", "terminate", "type", "adjust")
FIRST_FAILURE_TIMING_FIELDS = ("since_action_issued_seconds", "since_action_returned_seconds", "action_duration_seconds",
    "wait_elapsed_seconds", "deadline_seconds", "capture_request_seconds", "capture_return_seconds", "state_age_seconds")

FAILURE_MESSAGES_FIELD = "failure_messages"
MAX_FAILURE_MESSAGES = 16
UNRECOGNIZED_FAILURE_MESSAGE = "[unrecognized XCTest failure]"
# Complete code-defined smoke steps only; picker IDs, PIN digits and fixture labels stay private.
SMOKE_FLOW_CONTROL_IDS = (
    "firstboot.serverURL.field", "firstboot.apiKey.field", "firstboot.testConnection.button",
    "firstboot.saveConfig.button", "firstboot.connection.success", "server.keyboard.done.button",
    "mode.random.button", "mode.filtered.button", "mode.continue.button",
    "filterSummary.album.button", "filterSummary.person.button", "filterSummary.startPlayback.button",
    "albumFilter.back.button", "personFilter.back.button",
    "filter.editor.album.entry", "filter.editor.person.entry", "filter.editor.done.button",
    "pinEntry.close.button", "pinEntry.error.message",
    "settings.item.playback", "settings.item.accessProtection", "settings.item.server", "settings.item.about",
    "settings.pin.input.enable", "settings.pin.input.enableConfirm", "settings.pin.enable.button",
    "settings.pin.disable.button", "settings.server.feedback.save.success",
    "settings.playback.autoPlay.link", "settings.playback.autoPlay.off.button",
    "settings.playback.displayMode.link", "settings.playback.displayMode.singlePhoto.button",
    "settings.playback.mode.link", "settings.playback.mode.filtered.button", "settings.playback.showExif.toggle",
    "settings.about.opensource.link", "settings.about.opensource.page", "settings.about.opensource.back.button",
    "slideshow.control.settings.button", "slideshow.control.playPause.button",
    "slideshow.control.next.button", "slideshow.control.previous.button", "slideshow.entryHint.banner",
)
SMOKE_FLOW_FAILURE_MESSAGES = frozenset(
    {"Smoke flow: " + step + "." for step in (
        "App accessibility snapshot is missing", "App accessibility snapshot must succeed",
        "Back must reach Settings root or playback", "Back must return from the person picker to the selected summary",
        "EXIF setting must be readable", "Home must background the app", "Next must publish another scene while paused",
        "Previous must return to the prior scene", "Settings Back is missing", "Settings must apply the changed EXIF value",
        "Settings must offer Back", "Settings value must survive cold relaunch", "action exceeded the shared hang guard",
        "activation must return the app to foreground", "authorization error must be recoverable on first boot",
        "authorization failure must explain the rejected key", "authorization failure must not enable Save",
        "fixture metadata must be supplied", "input must have keyboard focus", "picker target is missing",
        "playback control observation is missing", "playback control snapshot is missing",
        "playback must expose its published history position", "playback must publish a scene before navigation",
        "public fixture must provide a picker target", "required element snapshot is missing",
        "required playback control must be ready", "rotation must reach a landscape App window",
        "selected mode must reach its destination", "selected person must stay on its picker with a solo switch",
        "target album identifier must exist", "target album metadata must exist",
        "the correct synthetic PIN must unlock Settings", "the public URL must reach the real text field",
        "B lists return to filter editor", "Home leaves playback", "Next advances while paused", "album selected",
        "cold playback has usable default focus", "controls hide before directional wake",
        "correct synthetic PIN opens Settings", "direction wakes operable Play/Pause",
        "one eventual automatic scene advance", "paused navigation starts from a settled scene",
        "person picker returns to startable summary", "person selected in normal mode",
        "physical Play/Pause selects solo mode", "relaunch retains autoplay off", "remote Next advances scene",
        "remote Previous returns to scene", "saved server reaches mode default focus",
        "server A photo is playing before switch", "server B playback advances", "server B save succeeds",
        "a B-exclusive photo must appear within the bounded Next path",
        "synthetic PIN enabled", "wrong PIN keeps Settings locked", "B list has no A entries or stale selections",
        "Back completes its page and focus handoff", "Back returns to playback", "PIN gate appears",
        "Set Up Filters has focus", "Settings opens", "Settings or playback is ready for Back",
        "choice Back returns to playback settings", "connection action is available", "empty-filter alert appears",
        "empty-filter alert focus", "empty-filter alert focus moves", "focus observation", "initial remote focus",
        "keyboard returns focus to field", "keyboard submission settles", "playback controls visible",
        "playback has a current scene", "playback index", "public fixture connection succeeds",
        "public switch fixture metadata is required", "real mode path opens filter editor",
        "settled scene has observable references", "settled scene references", "system keyboard opens",
        "system keyboard submit", "system keyboard submit has focus", "usable playback surface",
        "verified connection enables Save", "Play/Pause must reach play", "Play/Pause must reach pause",
        "Play/Pause state is play", "Play/Pause state is pause", "playback option saved: autoPlay",
        "playback option saved: displayMode", "launch", "terminate", "activate", "remote", "type",
    )}
    | {"Smoke flow: " + step + identifier + "." for step in (
        "required element must be available: ", "required element must be ready: ", "control appears: ",
        "remote focus moves toward ", "remote cannot focus ",
    ) for identifier in SMOKE_FLOW_CONTROL_IDS})
# Bound to AccessLifecycleContract.hiddenControlStabilitySeconds by the source audit.
# Retained v1/v2 UI waits keep their original interpretation.


def xctest_tool_class(message):
    """Only reviewed complete native messages can bypass the CPU requirement."""
    if not isinstance(message, str) or len(message) > 512:
        return None
    lifecycle = (
        r"Failed to terminate com\.331works\.immichSlides:[0-9]{1,10}",
        r"Failed to terminate com\.331works\.immichSlides:[0-9]{1,10}: Failed to terminate com\.331works\.immichSlides:[0-9]{1,10}",
        r"Application 'com\.331works\.immichSlides' does not have a process ID",
        r"Failed to launch (?:com\.331works\.immichSlides|Application 'com\.331works\.immichSlides'): Timed out while launching application via Xcode",
    )
    if any(re.fullmatch(pattern, message) for pattern in lifecycle):
        return "process_lifetime"
    if message == "Failed to get matching snapshots: Timed out while evaluating UI query":
        return "snapshot_query"
    return None


def reviewed_native_failure(message):
    # Diagnostic text only; this grammar grants no XCTest tool or yellow eligibility.
    return isinstance(message, str) and re.fullmatch(
        r"Test exceeded execution time allowance of [0-9]{1,10} minutes?", message) is not None


def validate_failure_messages(messages):
    from ci_summary import require
    require(isinstance(messages, list) and 0 < len(messages) <= MAX_FAILURE_MESSAGES,
            "failure messages: expected a bounded complete failure list")
    prefixes = {prefix for prefix, _, _ in PREFIX_RULES}
    require(all(isinstance(message, str) and (message in prefixes or message == UNRECOGNIZED_FAILURE_MESSAGE
                or message in SMOKE_FLOW_FAILURE_MESSAGES
                or reviewed_native_failure(message)
                or xctest_tool_class(message) is not None) for message in messages),
            "failure messages: unreviewed public message")


def public_failure_messages(messages):
    """Project the complete raw official list; native matches precede assertion unwrapping."""
    if not isinstance(messages, list) or not 0 < len(messages) <= MAX_FAILURE_MESSAGES:
        return None
    public = []
    for message in messages:
        if xctest_tool_class(message) is not None or reviewed_native_failure(message):
            public.append(message)
            continue
        text = normalized_xctest_failure(message)
        if text in SMOKE_FLOW_FAILURE_MESSAGES:
            public.append(text)
            continue
        rule = next((rule for rule in PREFIX_RULES if text is not None and text.startswith(rule[0])), None)
        public.append(rule[0] if rule is not None and xctest_tool_class(rule[0]) is None
                      else UNRECOGNIZED_FAILURE_MESSAGE)
    return public


def failure_messages_diagnostics(messages):
    kinds = {xctest_tool_class(message) for message in messages}
    if None not in kinds and len(kinds) == 1:
        return {"failure_phase": "unknown", "failure_class": kinds.pop()}
    return classify_messages(messages)


def official_failure_count(node):
    """Count the original failure nodes before publishing a complete message list."""
    return int(node.get("nodeType") == "Failure Message") + sum(
        official_failure_count(child) for child in node.get("children", []))


def unavailable_first_failure(source, step="unknown", element="unknown"):
    return {"schema_version": 1, "source": source, "step": step, "element": element, "action": "unknown",
        "timing": dict.fromkeys(FIRST_FAILURE_TIMING_FIELDS), "state": {
            "app": "unknown", "surface": "unknown", "observation": "unavailable", "control_bar": "unknown",
            "focus": "unknown", "history_count": None, "autoplay": "unknown", "orientation": "unknown",
            "scene_status": "unknown", "query_error_code": None}, "validator": None,
        "screenshot": {"status": "not-applicable" if source == "preparation" else "unavailable",
                       "width": None, "height": None, "bytes": None}}


def preparation_first_failure(ledger):
    from ci_bounded_diagnostics import validate_receipt
    receipt = unavailable_first_failure("preparation", element="simulator")
    if ledger is not None:
        validate_receipt(ledger)
        event = next((event for event in ledger["events"] if event["scope"] == "preparation"
                      and event["state"] == "timeout" and event["phase"] in FIRST_FAILURE_STEPS), None)
        if event is not None:
            receipt["step"] = event["phase"] if event["phase"] in FIRST_FAILURE_STEPS else "unknown"
            receipt["timing"]["wait_elapsed_seconds"] = event["elapsed_seconds"]
    validate_first_failure(receipt)
    return receipt


def canonical_first_failure_png(data):
    import io
    from PIL import Image
    if len(data) > 32 * 1024 * 1024:
        return None
    try:
        with Image.open(io.BytesIO(data)) as original:
            if original.format not in {"PNG", "JPEG"} or original.n_frames != 1 or original.width * original.height > 16_777_216:
                return None
            original.load()
            for side in (1536, 1024, 768, 512):
                picture = original.convert("RGB")
                picture.thumbnail((side, side))
                clean = Image.frombytes(picture.mode, picture.size, picture.tobytes())
                output = io.BytesIO()
                clean.save(output, format="PNG")
                png = output.getvalue()
                if len(png) <= FIRST_FAILURE_MAX_IMAGE_BYTES:
                    return png, picture.width, picture.height
    except (OSError, ValueError, Image.DecompressionBombError):
        return None
    return None


def collect_first_failure_image(operation):
    from ci_execution_diagnostics import active
    recorder = active()
    if recorder is None:
        return operation()
    # Existing shared #471 accounting makes this cumulative across a job's child runners.
    return recorder.collect("xcode", operation, cap=max(0, 5 - recorder.charged["xcode"]))


def first_failure_test_key(identifier):
    key = str(identifier).removesuffix("()")
    parts = key.split("/")
    return "/".join(parts[1:]) if len(parts) == 3 and parts[0] == "immichSlidesUITests" else key


def first_failure_environment(directory, selectors, *, screenshots=True):
    """Called only by public-fixture runners; never forward these keys to the App."""
    selectors = [first_failure_test_key(key) for key in selectors]
    return {"STRICT_E2E_FIRST_FAILURE_ENABLED": "1", "STRICT_E2E_FIRST_FAILURE_DIR": str(directory),
            "STRICT_E2E_FIRST_FAILURE_SCREENSHOT": "1" if screenshots else "0",
            "STRICT_E2E_FIRST_FAILURE_TESTS": json.dumps({key: index for index, key in enumerate(selectors)}),
            "STRICT_E2E_FIRST_FAILURE_ELEMENTS": json.dumps(FIRST_FAILURE_ELEMENTS)}


def collect_first_failure_spool(directory, selectors, failed_nodes, output):
    """Project bounded fixture evidence onto official failures; raw spool data is never published."""
    import io
    try:
        from PIL import Image
    except ImportError:
        return
    from ci_summary import decode
    if not directory.is_dir() or directory.is_symlink():
        return
    nodes = {first_failure_test_key(node.get("nodeIdentifier", "")): node
             for node in failed_nodes}
    for index, selector in enumerate(selectors):
        key = first_failure_test_key(selector)
        node = nodes.get(key)
        if node is None:
            continue
        path = directory / f"{index}.json"
        try:
            if not path.is_file() or path.is_symlink() or path.stat().st_size > FIRST_FAILURE_MAX_BYTES:
                continue
            receipt = public_first_failure(decode(path.read_text()))
            if receipt is None or receipt["source"] != "xctest":
                continue
            image_data = None
            if receipt["screenshot"]["status"] == "captured":
                image_path = directory / f"{index}.png"
                def project():
                    try:
                        if (not image_path.is_file() or image_path.is_symlink()
                                or not 0 < image_path.stat().st_size <= FIRST_FAILURE_MAX_IMAGE_BYTES):
                            return None
                        data = image_path.read_bytes()
                        with Image.open(io.BytesIO(data)) as picture:
                            if (picture.format != "PNG" or picture.n_frames != 1
                                    or picture.size != (receipt["screenshot"]["width"], receipt["screenshot"]["height"])):
                                return None
                        return canonical_first_failure_png(data)
                    except (OSError, ValueError, Image.DecompressionBombError):
                        return None
                image = collect_first_failure_image(project)
                if image is None:
                    receipt["screenshot"] = {"status": "unavailable", "width": None, "height": None, "bytes": None}
                else:
                    image_data, width, height = image
                    receipt["screenshot"].update(width=width, height=height, bytes=len(image_data))
                validate_first_failure(receipt)
            if image_data is not None:
                output.mkdir(parents=True, exist_ok=True)
                (output / f"{index}.png").write_bytes(image_data)
                validate_first_failure_image(output / f"{index}.png", receipt)
            node[FIRST_FAILURE_FIELD] = receipt
        except (OSError, ValueError, TypeError, KeyError, Image.DecompressionBombError):
            # A missing or unsafe diagnostic never changes the official failure or its exit code.
            continue


def validate_first_failure_image(path, receipt):
    import io
    from PIL import Image
    from ci_summary import require
    require(path.is_file() and not path.is_symlink(), "nonregular first failure package input")
    require(0 < path.stat().st_size <= FIRST_FAILURE_MAX_IMAGE_BYTES, "first failure package image exceeds bound")
    data = path.read_bytes()
    require(len(data) == receipt["screenshot"]["bytes"], "first failure package image differs")
    try:
        with Image.open(path) as picture:
            require(picture.format == "PNG" and not picture.info and picture.n_frames == 1,
                    "first failure package image contains unsupported data")
            require(picture.size == (receipt["screenshot"]["width"], receipt["screenshot"]["height"])
                    and max(picture.size) <= FIRST_FAILURE_MAX_IMAGE_SIDE, "first failure package image dimensions differ")
            picture.load()
            canonical = io.BytesIO()
            picture.save(canonical, format="PNG")
            require(canonical.getvalue() == data, "first failure package image contains unsupported data")
    except (OSError, Image.DecompressionBombError):
        raise ValueError("first failure package image cannot be decoded") from None


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
    fields = {"schema_version", "source", "step", "element", "action", "timing", "state", "validator", "screenshot"}
    for optional in ():
        if isinstance(receipt, dict) and optional in receipt:
            fields.add(optional)
    exact(receipt, fields, "first failure")
    require(type(receipt["schema_version"]) is int and receipt["schema_version"] == 1, "first failure: unsupported version")
    choice(receipt["source"], ("xctest", "preparation"), "source")
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
    require(validator is None, "first failure: smoke has no visual validator")
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
    rendered = (f"{receipt['source']}/{receipt['step']}; {receipt['element']}; "
            f"since action={measured('since_action_issued_seconds')}; wait={measured('wait_elapsed_seconds')}; "
            f"deadline={measured('deadline_seconds')}; screenshot={receipt['screenshot']['status']}")
    return rendered


def public_first_failure(receipt):
    try:
        validate_first_failure(receipt)
    except (ValueError, TypeError, OverflowError):
        return None
    return receipt

# Fixed smoke and shared first-boot messages only; runtime suffixes remain private.
PREFIX_RULES = (
    ('Smoke flow: ', 'unknown', 'control_state'),
    ('Fresh install must open the normal first-boot page.', 'firstboot_setup', 'navigation'),
    ('First-boot page must show the API Key field.', 'firstboot_setup', 'navigation'),
    ('The API Key must be entered into the secure field.', 'firstboot_setup', 'control_state'),
    ('First-boot page must show Test Connection.', 'firstboot_setup', 'navigation'),
    ('First-boot page must show the Save Settings button.', 'firstboot_setup', 'navigation'),
    ('A successful save must lead to mode selection.', 'firstboot_setup', 'navigation'),
    ('The mode page must also offer the filter entry.', 'mode_selection', 'navigation'),
    ('Playback page after uninstall means a dirty install container;', 'firstboot_setup', 'navigation'),
    ('The public test URL must be entered verbatim,', 'firstboot_setup', 'control_state'),
    ('API Key must reach the secure field;', 'firstboot_setup', 'control_state'),
    ('The first-boot filter summary must offer a way back to mode selection.', 'mode_selection', 'navigation'),
    ('The iOS filter summary should no longer use a bottom back button,', 'mode_selection', 'navigation'),
    ('Connection test showed a failure alert:', 'firstboot_setup', 'navigation'),
    ('The first-boot page must show the Save Settings button.', 'firstboot_setup', 'navigation'),
    ('After a successful save, the app must reach mode selection.', 'firstboot_setup', 'navigation'),
    ('A fresh install must reach the normal first-boot page.', 'firstboot_setup', 'navigation'),
    ('The first-boot page must show the API Key field.', 'firstboot_setup', 'navigation'),
    ('The first-boot page must show the Test Connection button.', 'firstboot_setup', 'navigation'),
    ('Save must become enabled after a real connection test succeeds.', 'firstboot_setup', 'control_state'),
    ('A cold launch with saved settings must not return to the first-boot page.', 'cold_relaunch', 'navigation'),
    ('A configured cold launch must go straight to the playback page.', 'cold_relaunch', 'navigation'),
    ('Chose filter but reached the playback page, so the mode card tap did not register.', 'mode_selection', 'navigation'),
    ('Still on the mode page after Continue; filter mode did not start.', 'mode_selection', 'navigation'),
    ('Filter mode must reach the filter summary page.', 'mode_selection', 'navigation'),
    ('Going back from the filter summary must return to mode selection.', 'mode_selection', 'navigation'),
    ('Random mode must reach the playback page.', 'playback_entry', 'navigation'),
    ('Mode departure failed after one hittable Continue without a password prompt;', 'playback_entry', 'navigation'),
    ('First-boot mode navigation must dismiss the exact password prompt,', 'mode_selection', 'navigation'),
    ('After injecting the public fixture, the app must reach the mode page.', 'mode_selection', 'navigation'),
    ('Default focus on the mode selection page must land on random playback.', 'mode_selection', 'focus'),
    ('Focus on the mode page must be able to move to filtered playback.', 'mode_selection', 'focus'),
    ('After choosing a mode, focus must be able to move down to the Continue button.', 'mode_selection', 'focus'),
    ('After returning to mode selection, default focus must go back to random playback.', 'mode_selection', 'focus'),
    ('After Continue, the app must reach the playback page and show the control bar.', 'playback_entry', 'navigation'),
    ('After starting playback, the playback page should open and show the control bar', 'playback_entry', 'navigation'),
    ('After entering the playback page, the settings button should be visible', 'playback_entry', 'navigation'),
    ('Once the real controlled service is reachable, the connection-test-passed status must show.', 'firstboot_setup', 'navigation'),
    ('Once the real controlled server is reachable, connection test passed must be shown.', 'firstboot_setup', 'navigation'),
    ('After choosing random playback, focus must be able to move down to the Continue button.', 'mode_selection', 'focus'),
    ('With the real controlled service reachable, the connection test must show as passed.', 'firstboot_setup', 'navigation'),
    ('While the one-time hint is shown, default focus must land on the settings button.', 'playback_entry', 'focus'),
    ('Focus on the filter summary page must be able to move to Back to Mode Selection.', 'mode_selection', 'focus'),
    ('Going back from the filter summary must return to the mode selection page.', 'mode_selection', 'navigation'),
    ('After choosing filtered playback, the Continue button must be enabled.', 'mode_selection', 'control_state'),
    ('After submitting the URL, focus must be able to move down to API Key.', 'firstboot_setup', 'focus'),
    ('Must focus the system keyboard submit button before submitting text.', 'firstboot_setup', 'focus'),
    ('After choosing random playback, the Continue button must be enabled.', 'mode_selection', 'control_state'),
    ('After a successful connection, the Save Settings button must appear.', 'firstboot_setup', 'navigation'),
    ('After saving settings, the app must reach the mode selection page.', 'mode_selection', 'navigation'),
    ('After choosing filtered playback, the Continue button must appear.', 'mode_selection', 'navigation'),
    ('Focus the system keyboard submit button before submitting text.', 'firstboot_setup', 'focus'),
    ('After a successful connection, Save Settings must be enabled.', 'firstboot_setup', 'control_state'),
    ('After choosing random play, focus must move down to Continue.', 'mode_selection', 'focus'),
    ('The first playback round must show the one-time remote hint.', 'playback_entry', 'navigation'),
    ('The first-boot form must show the Test Connection button.', 'firstboot_setup', 'navigation'),
    ('Select must not accidentally hit the API Key help sheet.', 'firstboot_setup', 'navigation'),
    ('After submitting text, focus must return to the field.', 'firstboot_setup', 'focus'),
    ('After connecting, the Save Settings button must show.', 'firstboot_setup', 'navigation'),
    ('After choosing random play, Continue must be enabled.', 'mode_selection', 'control_state'),
    ('Mode selection focus must start on random playback.', 'mode_selection', 'focus'),
    ('After saving settings, mode selection must open.', 'mode_selection', 'navigation'),
    ('The first-boot form must show the API Key field.', 'firstboot_setup', 'navigation'),
    ('URL submitted; focus must move down to API Key.', 'firstboot_setup', 'focus'),
    ('After choosing random play, Continue must show.', 'mode_selection', 'navigation'),
    ('A clean install must reach the first-boot form.', 'firstboot_setup', 'navigation'),
    ('A clean install must open the first-boot form.', 'firstboot_setup', 'navigation'),
    ('The server address must be submitted verbatim.', 'firstboot_setup', 'control_state'),
    ('First-boot form must show the API Key field.', 'firstboot_setup', 'navigation'),
    ('Control bar must show after random playback.', 'playback_entry', 'hidden_controls'),
    ('First-boot form must show Test Connection.', 'firstboot_setup', 'navigation'),
    ('The field must be focused before input.', 'firstboot_setup', 'focus'),
    ('After submitting, focus must return to the original field.', 'firstboot_setup', 'focus'),
    ('System keyboard must show Next or Done.', 'firstboot_setup', 'navigation'),
)


def unknown_diagnostics():
    return {"failure_phase": "unknown", "failure_class": "unknown"}


def normalized_xctest_failure(message):
    """Private intermediate for fixed-prefix readers; never publish the returned text."""
    if not isinstance(message, str):
        return None
    # Only unwrap the known Swift error types; arbitrary error descriptions stay private.
    text = re.sub(r"^(?:failed - |XCT(?:Assert\w+|Unwrap) failed(?:\:.*?)? - )", "", message)
    if text.startswith('failed: caught error: "App timeline:'):
        text = text[len('failed: caught error: "'):]
    for wrapper in ('failed: caught error: "message(\\"', 'failed: caught error: "message("',
                    'message(\\"', 'message("',
                    'failed: caught error: "Failure(message: \\"', 'failed: caught error: "Failure(message: "',
                    'Failure(message: \\"', 'Failure(message: "'):
        if text.startswith(wrapper):
            text = text[len(wrapper):]
            break
    return text


def classify_messages(messages):
    matches = set()
    for message in messages:
        text = normalized_xctest_failure(message)
        if text is None:
            return unknown_diagnostics()
        match = next(((phase, kind) for prefix, phase, kind in PREFIX_RULES if text.startswith(prefix)), None)
        if match is None:
            return unknown_diagnostics()
        matches.add(match)
    if len(matches) != 1:
        return unknown_diagnostics()
    phase, kind = matches.pop()
    return {"failure_phase": phase, "failure_class": kind}


def legacy_failure_summaries(value):
    """Read the invocation aggregate once; action issues repeat the same failures."""
    if isinstance(value, dict):
        issues = value.get("issues")
        summaries = issues.get("testFailureSummaries") if isinstance(issues, dict) else None
        rows = summaries.get("_values", []) if isinstance(summaries, dict) else []
        yield from (row for row in rows if isinstance(row, dict)) if isinstance(rows, list) else ()


def legacy_failure_messages(payload):
    """Read only official failure summaries; raw values remain private to their caller."""
    messages = {}
    for row in legacy_failure_summaries(payload):
        name = row.get("testCaseName", {}).get("_value") if isinstance(row.get("testCaseName"), dict) else None
        if isinstance(name, str):
            key = first_failure_test_key(name.removesuffix("()").replace(".", "/"))
            raw = row.get("message")
            messages.setdefault(key, []).append(raw.get("_value") if isinstance(raw, dict) else None)
    return messages


def legacy_diagnostics(payload):
    return {key: classify_messages(values) for key, values in legacy_failure_messages(payload).items()}


def test_node_diagnostics(payload):
    diagnostics = {}
    def visit(node):
        if not isinstance(node, dict):
            return
        if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
            validate_diagnostic_fields({key: value for key, value in node.items() if key != FIRST_FAILURE_FIELD})
            key = str(node.get("nodeIdentifier", "")).removesuffix("()")
            diagnostics[key] = ({field: node[field] for field in DIAGNOSTIC_FIELDS}
                                if DIAGNOSTIC_FIELDS <= node.keys() else unknown_diagnostics())
            if FAILURE_MESSAGES_FIELD in node:
                diagnostics[key][FAILURE_MESSAGES_FIELD] = deepcopy(node[FAILURE_MESSAGES_FIELD])
            receipt = public_first_failure(node.get(FIRST_FAILURE_FIELD))
            if receipt is not None and receipt["source"] == "xctest":
                diagnostics[key][FIRST_FAILURE_FIELD] = receipt
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
        if {"environment_limit", "validator_failure_message"} & value.keys():
            raise ValueError("retired diagnostic field")
        if FAILURE_MESSAGES_FIELD in value:
            validate_failure_messages(value[FAILURE_MESSAGES_FIELD])
        if FIRST_FAILURE_FIELD in value:
            validate_first_failure(value[FIRST_FAILURE_FIELD])
        if BOUNDED_DIAGNOSTICS_FIELD in value:
            from ci_bounded_diagnostics import validate_receipt
            validate_receipt(value[BOUNDED_DIAGNOSTICS_FIELD])
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
    diagnostic_fields = DIAGNOSTIC_FIELDS | {BOUNDED_DIAGNOSTICS_FIELD, FIRST_FAILURE_FIELD, FAILURE_MESSAGES_FIELD}
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
        checked = deepcopy(value) if BOUNDED_DIAGNOSTICS_FIELD in value else value
        validate_diagnostic_fields(checked)
        if checked != value:
            raise ValueError("failure locations: invalid projection")
        return value
    try:
        json.loads(data, object_pairs_hook=object_pairs)
        if bounded_seen and duplicate_seen:
            raise ValueError("duplicate bounded diagnostic JSON key")
        if first_failure_seen and duplicate_seen:
            raise ValueError("duplicate first failure JSON key")
    except (json.JSONDecodeError, UnicodeDecodeError):
        ascii_keys = re.sub(rb"\\u00([0-9a-fA-F]{2})", lambda match: bytes([int(match[1], 16)]), data)
        if any(('"' + field + '"').encode() in ascii_keys for field in (BOUNDED_DIAGNOSTICS_FIELD, FIRST_FAILURE_FIELD, FAILURE_MESSAGES_FIELD)) or any(
                ('"' + field + '"').encode() in data for field in DIAGNOSTIC_FIELDS):
            raise ValueError("invalid failure diagnostic JSON")


def validate_ui_first_failure_images(directory, summary):
    from ci_summary import require
    declared = summary["population"]["declared"]
    observed = {entry["identity"]["key"]: entry for entry in summary["population"]["observed"]}
    expected = set()
    for index, identity in enumerate(declared):
        entry = observed.get(identity["key"], {})
        attempts = entry.get("attempts", []) + ([entry["retry_failure"]] if "retry_failure" in entry else [])
        for attempt in attempts:
            receipt = attempt.get(FIRST_FAILURE_FIELD)
            if receipt is None or receipt["screenshot"]["status"] != "captured":
                continue
            folder = directory / ("first-failure-attempt-" + str(attempt["number"]))
            require(folder.is_dir() and not folder.is_symlink(), "invalid first failure package directory")
            path = folder / f"{index}.png"
            validate_first_failure_image(path, receipt)
            expected.add(path)
    folders = list(directory.glob("first-failure-attempt-*"))
    require(all(folder.is_dir() and not folder.is_symlink() and folder in {path.parent for path in expected}
                for folder in folders), "invalid first failure package directory")
    actual = {path for folder in folders for path in folder.iterdir()}
    require(actual == expected, "unexpected first failure package content")
    for path in directory.rglob("*"):
        if path.suffix.lower() in {".png", ".jpg", ".jpeg"}:
            require(path.is_file() and not path.is_symlink(), "nonregular first failure package input")
            require(0 < path.stat().st_size <= FIRST_FAILURE_MAX_IMAGE_BYTES, "first failure package image exceeds bound")
            from PIL import Image
            try:
                with Image.open(path) as image:
                    receipt = {"screenshot": {"width": image.width, "height": image.height, "bytes": path.stat().st_size}}
            except (OSError, Image.DecompressionBombError):
                raise ValueError("first failure package image cannot be decoded") from None
            validate_first_failure_image(path, receipt)
