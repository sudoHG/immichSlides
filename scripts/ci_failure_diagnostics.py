"""Fixed public diagnostics; private XCTest messages never leave this mapper."""

import json
import math
import re
from contextlib import contextmanager
from contextvars import ContextVar

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
VALIDATOR_FAILURE_FIELD = "validator_failure_message"
VALIDATOR_FAILURE_MAX_LENGTH = 512
VALIDATOR_FAILURE_REDACTED = "[redacted validator failure]"
FIRST_FAILURE_FIELD = "first_failure"
FIRST_FAILURE_MAX_BYTES = 8192
FIRST_FAILURE_MAX_SECONDS = 86400
FIRST_FAILURE_MAX_IMAGE_BYTES = 1024 * 1024
FIRST_FAILURE_MAX_IMAGE_SIDE = 1536
ALBUM_CAPTURE_GATE_BOOLEANS = ("stable", "paused", "entry_hint_hidden", "advanced", "layers_changed", "manifest_complete")
ALBUM_CAPTURE_GATE_PHASES = ("unknown", "empty", "stablePhoto", "grace", "transition", "loading",
                             "incomingFromLoading", "paused", "sourceError")
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
NATIVE_ACTIVITY_FIELDS = ("pre_event_idle", "find_window", "synthesize_event", "post_event_idle", "ax_root_acquisition")
_validator_input = ContextVar("first_failure_validator_input", default=None)
_validator_enabled = ContextVar("first_failure_validator_enabled", default=False)

ENVIRONMENT_LIMIT_FIELD = "environment_limit"
ENVIRONMENT_POLICY_VERSION = 4
ENVIRONMENT_IDLE_MAX_PERCENT = 5
ENVIRONMENT_ALBUM_SETTLING_PHASES = frozenset({"transition", "incomingFromLoading"})
# Retained v1/v2 UI waits keep their original interpretation.
ENVIRONMENT_WAIT_STEPS = {
    **{("mode_selection", "navigation", "mode-card", element): "mode"
       for element in ("mode.random.button", "mode.filtered.button")},
    ("mode_selection", "navigation", "mode-continue", "mode.continue.button"): "mode",
    ("playback_entry", "navigation", "query-element", "slideshow.control.playPause.button"): "playback",
    **{("settings_navigation", "navigation", step, "slideshow.control.settings.button"): "playback"
       for step in ("query-element", "select")},
    **{(phase, "hidden_controls", step, element): "playback"
       for phase, steps in (("control_action", ("query-element", "reveal-controls")),
                            ("hidden_controls", ("query-element", "reveal-controls")),
                            ("interval_setup", ("query-element",)))
       for step in steps
       for element in ("slideshow.control.settings.button", "slideshow.control.previous.button",
                       "slideshow.control.playPause.button", "slideshow.control.next.button", "slideshow.hiddenWakeReceiver")},
}
ENVIRONMENT_WAIT_STEPS_V3 = {
    **ENVIRONMENT_WAIT_STEPS,
    **{(phase, "navigation", "mode-departure", "mode.continue.button"): "mode"
       for phase in ("mode_selection", "playback_entry")},
}
ENVIRONMENT_WAIT_STEPS_V4 = {
    **ENVIRONMENT_WAIT_STEPS_V3,
    **{("mode_selection", "navigation", "save-password-prompt", element): "mode"
       for element in ("mode.random.button", "mode.filtered.button")},
}


def environment_failure_projection(receipt):
    return {"source": receipt["source"], "step": receipt["step"], "element": receipt["element"], "action": receipt["action"],
        "app": receipt["state"]["app"],
        "surface": receipt["state"]["surface"],
        "control_bar": receipt["state"]["control_bar"],
        "scene_status": receipt["state"]["scene_status"],
        **{key: receipt["timing"][key] for key in ("wait_elapsed_seconds", "deadline_seconds", "action_duration_seconds")},
        "post_event_idle": receipt.get("native_activity_seconds", {}).get("post_event_idle"),
        **({"gate": dict(receipt["gate"])} if "gate" in receipt else {})}


def environment_timing(failure, phase, failure_class, *, policy_version=ENVIRONMENT_POLICY_VERSION):
    album_capture = (policy_version in {2, 3, 4} and phase == "visible_scene_capture" and failure_class == "probe_readback"
        and failure["step"] == "wait-scene" and failure["element"] == "slideshow.scenePresentation.contract.summary")
    if album_capture:
        gate = failure.get("gate", {})
        if not (gate.get("kind") == "album-capture" and gate.get("stable") is False
                and gate.get("paused") is True and gate.get("entry_hint_hidden") is True
                and gate.get("manifest_complete") is True
                and gate.get("advanced") is True and gate.get("layers_changed") is True
                and gate.get("phase") in ENVIRONMENT_ALBUM_SETTLING_PHASES):
            return False
    wait_steps = (ENVIRONMENT_WAIT_STEPS_V4 if policy_version == 4
        else ENVIRONMENT_WAIT_STEPS_V3 if policy_version == 3 else ENVIRONMENT_WAIT_STEPS)
    expected_surface = "playback" if album_capture else wait_steps.get(
        (phase, failure_class, failure["step"], failure["element"]))
    if (failure["source"] != "xctest" or failure["app"] != "running-foreground"
            or failure["scene_status"] in {"BLACK", "BLANK"}
            or failure["scene_status"] == "UNRECOGNIZABLE" and failure["surface"] in {"playback", "unknown"}
            or failure["surface"] == "unknown"
            or failure["surface"] != expected_surface
            or failure_class == "hidden_controls" and failure["control_bar"] == "visible"):
        return False
    elapsed, deadline = failure["wait_elapsed_seconds"], failure["deadline_seconds"]
    # No receipt field proves a following successful action readback; native idle alone stays red.
    return elapsed is not None and deadline is not None and deadline > 0 and elapsed >= deadline


def validate_environment_limit(proof):
    from ci_summary import fields, require
    from ci_bounded_diagnostics import validate_case_resources
    fields(proof, {"schema_version", "policy_version", "runner_hosted", "failure_phase", "failure_class", "failure", "resources"},
           "environment limit")
    require(type(proof["policy_version"]) is int and proof["policy_version"] in {1, 2, 3, 4},
            "environment limit: unsupported policy version")
    require(type(proof["schema_version"]) is int and proof["schema_version"] == 1
            and proof["runner_hosted"] is True, "environment limit: hosted evidence required")
    failure = proof["failure"]
    failure_fields = {"source", "step", "element", "action", "app", "surface", "control_bar", "scene_status", "wait_elapsed_seconds", "deadline_seconds",
                      "action_duration_seconds", "post_event_idle"}
    if proof["policy_version"] in {2, 3, 4} and isinstance(failure, dict) and "gate" in failure:
        failure_fields.add("gate")
    fields(failure, failure_fields, "environment failure")
    receipt = unavailable_first_failure("xctest")
    receipt.update(source=failure["source"], step=failure["step"], element=failure["element"], action=failure["action"])
    receipt["state"]["app"] = failure["app"]
    receipt["state"]["surface"] = failure["surface"]
    receipt["state"]["control_bar"] = failure["control_bar"]
    receipt["state"]["scene_status"] = failure["scene_status"]
    if "gate" in failure:
        receipt["gate"] = failure["gate"]
    for key in ("wait_elapsed_seconds", "deadline_seconds", "action_duration_seconds"):
        receipt["timing"][key] = failure[key]
    if failure["source"] == "xctest":
        receipt["native_activity_seconds"] = dict.fromkeys(NATIVE_ACTIVITY_FIELDS)
        receipt["native_activity_seconds"]["post_event_idle"] = failure["post_event_idle"]
    validate_first_failure(receipt)
    require(isinstance(proof["failure_phase"], str) and isinstance(proof["failure_class"], str)
            and environment_timing(failure, proof["failure_phase"], proof["failure_class"], policy_version=proof["policy_version"]),
            "environment limit: failure is not an eligible timing wait")
    resource = proof["resources"]
    validate_case_resources([resource])
    samples = resource["failure_samples"]
    require(len(samples) >= 2 and all(sample["idle_percent"] is not None
            and sample["idle_percent"] <= ENVIRONMENT_IDLE_MAX_PERCENT for sample in samples)
            and any(sample["elapsed_seconds"] < resource["first_failure_elapsed_seconds"] for sample in samples)
            and any(sample["elapsed_seconds"] > resource["first_failure_elapsed_seconds"] for sample in samples),
            "environment limit: insufficient starvation evidence")


def environment_limit_evidence(summary, entry, resources, *, runner_hosted, policy_version=None):
    """Project checked case evidence; absence or ambiguity always retains the raw failure."""
    from ci_summary import require
    try:
        require(runner_hosted is True and summary["source"]["workflow_path"] == ".github/workflows/ci-nightly.yml"
                and summary["source"]["event"] in {"schedule", "workflow_dispatch"}
                and summary["run"]["tier"] == "strict" and summary["run"]["job"] == "nightly-strict",
                "environment limit: outside hosted nightly strict scope")
        require(entry["outcome"] == "failed" and entry["identity"]["kind"] == "strict"
                and VALIDATOR_FAILURE_FIELD not in entry, "environment limit: not a timing failure")
        receipt = public_first_failure(entry.get(FIRST_FAILURE_FIELD))
        require(receipt is not None, "environment limit: missing first failure")
        candidates = [resource for resource in resources if resource.get("first_failure_elapsed_seconds") is not None]
        require(len(candidates) == 1, "environment limit: ambiguous failure resources")
        proof = {"schema_version": 1, "policy_version": ENVIRONMENT_POLICY_VERSION if policy_version is None else policy_version,
            "runner_hosted": True, "failure_phase": entry.get("failure_phase"),
            "failure_class": entry.get("failure_class"), "failure": environment_failure_projection(receipt),
            "resources": candidates[0]}
        validate_environment_limit(proof)
        return proof
    except (ValueError, TypeError, KeyError, AttributeError):
        return None


def render_environment_limit(proof):
    try:
        validate_environment_limit(proof)
    except (ValueError, TypeError, KeyError, AttributeError):
        return "RED: invalid or obsolete environment-limit proof under the current policy"
    resource = proof["resources"]
    failure = proof["failure"]
    return (f"ENVIRONMENT-LIMITED (yellow; raw failure retained): {proof['failure_phase']}/{proof['failure_class']}; "
        f"wait={failure['wait_elapsed_seconds']}s / deadline={failure['deadline_seconds']}s; "
        f"post-event-idle={failure['post_event_idle']}s; failure at {resource['first_failure_elapsed_seconds']}s; "
        + "; ".join(f"t={sample['elapsed_seconds']}s idle={sample['idle_percent']}% load1={sample['load_1m']} "
                    f"app-cpu={sample['cpu_percent']['app']}%" for sample in resource["failure_samples"]))


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


def remember_validator_input(image_bytes):
    if _validator_enabled.get():
        _validator_input.set(image_bytes if len(image_bytes) <= 32 * 1024 * 1024 else None)


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


def normalize_ui_failure_images(directory):
    """Only exported public-fixture failure attachments are normalized, after XCTest has finished."""
    for path in directory.rglob("*"):
        if path.suffix.lower() not in {".png", ".jpg", ".jpeg"}:
            continue
        try:
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 32 * 1024 * 1024:
                path.unlink(missing_ok=True)
                continue
            image = canonical_first_failure_png(path.read_bytes())
            if image is None:
                path.unlink(missing_ok=True)
                continue
            destination = path if path.suffix.lower() == ".png" else path.with_name(path.name + ".png")
            destination.write_bytes(image[0])
            if destination != path:
                path.unlink()
        except Exception:
            # Unreadable optional media must not reach the existing upload boundary.
            path.unlink(missing_ok=True)


@contextmanager
def public_fixture_validator_scope(directory, *, screenshots=False):
    """Only the controlled fixture runner enters this scope; keep an actual validator input on failure."""
    enabled, image_token = _validator_enabled.set(True), _validator_input.set(None)
    try:
        yield
    except Exception as error:
        receipt = unavailable_first_failure("validator", "capture-frame", "app-window")
        receipt["validator"] = {"kind": "unknown", "slot": None, "axis": "unknown"}
        message = public_validator_failure_message(str(error.__cause__ or error))
        match = re.search(r"\bslot ([1-9][0-9]?) \((horizontal|vertical|both)(?: axes)?\)", message)
        if match is not None and int(match[1]) <= 64:
            receipt["validator"] = {"kind": "glyph", "slot": int(match[1]), "axis": match[2]}
        data = _validator_input.get()
        try:
            if screenshots and data:
                image = collect_first_failure_image(lambda: canonical_first_failure_png(data))
                if image is not None:
                    png, width, height = image
                    receipt["screenshot"] = {"status": "validated-input", "width": width, "height": height, "bytes": len(png)}
                    path = directory / "first-failure-validator.png"
                    path.write_bytes(png)
                    validate_first_failure_image(path, receipt)
        except Exception:
            # An optional diagnostic must preserve the exception already raised by the validator.
            receipt["screenshot"] = {"status": "unavailable", "width": None, "height": None, "bytes": None}
        try:
            validate_first_failure(receipt)
            (directory / "first-failure-validator.json").write_text(json.dumps(receipt, sort_keys=True) + "\n")
        except (OSError, ValueError, TypeError):
            pass
        raise
    finally:
        _validator_enabled.reset(enabled)
        _validator_input.reset(image_token)


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


def configure_first_failure_attempt(command, directory, selectors, *, screenshots=True):
    """Give each existing listed attempt a private spool, without changing retry selection or flags."""
    import plistlib
    from pathlib import Path
    position = command.index("-xctestrun") + 1
    source = Path(command[position])
    payload = plistlib.loads(source.read_bytes())
    for configuration in payload.get("TestConfigurations", []):
        for target in configuration.get("TestTargets", []):
            if target.get("BlueprintName") == "immichSlidesUITests":
                target.setdefault("EnvironmentVariables", {}).update(
                    first_failure_environment(directory, selectors, screenshots=screenshots))
    prepared = source.with_name(source.stem + "-first-failure-" + directory.name + source.suffix)
    try:
        prepared.write_bytes(plistlib.dumps(payload))
    except OSError:
        prepared.unlink(missing_ok=True)
        raise
    command = list(command)
    command[position] = str(prepared)
    return command, prepared


def attach_first_failures(observed, official, number):
    """Keep the first failing attempt's receipt across the runner's existing listed retry."""
    def visit(node):
        if not isinstance(node, dict):
            return
        receipt = public_first_failure(node.get(FIRST_FAILURE_FIELD))
        if node.get("nodeType") == "Test Case" and node.get("result") == "Failed" and receipt is not None:
            key = first_failure_test_key(node.get("nodeIdentifier", ""))
            for entry in observed:
                if first_failure_test_key(entry["identity"]["key"]) != key:
                    continue
                first = next((attempt for attempt in entry["attempts"] if attempt["outcome"] != "passed"), None)
                for attempt in entry["attempts"]:
                    if attempt["number"] == number and attempt["outcome"] in {"failed", "crashed", "timed-out"}:
                        if attempt is first or first is not None and FIRST_FAILURE_FIELD in first:
                            attempt[FIRST_FAILURE_FIELD] = receipt
                if first is not None and FIRST_FAILURE_FIELD in first:
                    entry[FIRST_FAILURE_FIELD] = first[FIRST_FAILURE_FIELD]
        for child in node.get("children", []) if isinstance(node.get("children", []), list) else []:
            visit(child)
    for node in official.get("testNodes", []):
        visit(node)


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
            receipt = decode(path.read_text())
            validate_first_failure(receipt)
            if receipt["source"] != "xctest":
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


def validate_ui_first_failure_images(directory, summary):
    from ci_summary import require
    declared = summary["population"]["declared"]
    observed = {entry["identity"]["key"]: entry for entry in summary["population"]["observed"]}
    expected = set()
    for index, identity in enumerate(declared):
        for attempt in observed.get(identity["key"], {}).get("attempts", []):
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
    for optional in ("native_activity_seconds", "gate"):
        if isinstance(receipt, dict) and optional in receipt:
            fields.add(optional)
    exact(receipt, fields, "first failure")
    require(type(receipt["schema_version"]) is int and receipt["schema_version"] == 1, "first failure: unsupported version")
    choice(receipt["source"], ("xctest", "validator", "preparation"), "source")
    choice(receipt["step"], FIRST_FAILURE_STEPS, "step")
    choice(receipt["element"], FIRST_FAILURE_ELEMENTS, "element")
    choice(receipt["action"], FIRST_FAILURE_ACTIONS, "action")
    if "gate" in receipt:
        gate = receipt["gate"]
        exact(gate, {"kind", "phase", *ALBUM_CAPTURE_GATE_BOOLEANS}, "first failure gate")
        choice(gate["kind"], ("album-capture",), "gate kind")
        choice(gate["phase"], ALBUM_CAPTURE_GATE_PHASES, "gate phase")
        for key in ALBUM_CAPTURE_GATE_BOOLEANS:
            require(gate[key] is None or type(gate[key]) is bool, "first failure gate: invalid boolean")
        require(receipt["source"] == "xctest" and receipt["step"] == "wait-scene"
                and receipt["element"] in ("slideshow.scenePresentation.contract.summary", "slideshow.control.next.button"),
                "first failure: gate requires album capture timeout context")
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
    if "native_activity_seconds" in receipt:
        require(receipt["source"] == "xctest", "first failure: native activity requires xctest source")
        exact(receipt["native_activity_seconds"], NATIVE_ACTIVITY_FIELDS, "first failure native activity")
        for value in receipt["native_activity_seconds"].values():
            number(value, FIRST_FAILURE_MAX_SECONDS, "first failure native activity")
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
    if "gate" in receipt:
        gate = receipt["gate"]
        rendered += "; gate=" + gate["kind"] + ": " + ", ".join(
            key + "=" + json.dumps(gate[key]) for key in ALBUM_CAPTURE_GATE_BOOLEANS)
        rendered += ", phase=" + gate["phase"]
    if "native_activity_seconds" in receipt:
        native = receipt["native_activity_seconds"]
        if all(value is None for value in native.values()):
            rendered += "; native=unavailable"
        else:
            labels = (("pre", "pre_event_idle"), ("window", "find_window"),
                      ("synth", "synthesize_event"), ("post", "post_event_idle"),
                      ("ax", "ax_root_acquisition"))
            rendered += "; native: " + ", ".join(
                label + "=" + ("unavailable" if native[key] is None else f"{native[key]:g}s")
                for label, key in labels)
    return rendered


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
    "Pause window bright proof must show A2",
    "Pause window capture contract is missing or invalid",
    "Pause window bright proof must be one frozen opaque scene",
    "The paused pause-window probe identity must not change",
    "Pause window midpoint must contain visible photo pixels",
    "Target window shows the wrong image; cannot count as SUCCESS",
    "Pause window pixel comparison is not usable",
    "Paused pause-window frames must be pixel-identical",
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
    r"(?:person-normal(?:-1)?|person-no-faces|person-nofaces-1|vision-solo-1|"
    r"person-conflict-normal(?:-[1-9][0-9]?)?|"
    r"album-playback-[123]|album-play-[123]|album-switch-b-play-[12]|server-switch-a-play-1|switch-b-play-[12]|"
    r"history-(?:start|first-next|second-next|first-previous|second-previous)|"
    r"pause-immediate|pause-after-10s|resumed|display-after)"
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
    # tvOS timing-precondition fixes: keep separate from the broader diagnostics-only expansion.
    ("tvOS Continue wake timing precondition failed: Up must not be requested before T-2.", "continue_timing", "timing_window"),
    ("tvOS flow entry precondition failed:", "history_navigation", "control_state"),
    ("tvOS flow entry anchor must remain paused before checking the history boundary.", "history_navigation", "control_state"),
    ("tvOS midpoint setup exhausted the original step budget before the half-cycle pause.", "continue_timing", "timing_window"),
    ("tvOS midpoint pause requires Play/Pause focus after at most one wake within the original step budget.", "control_action", "focus"),
    ("tvOS midpoint pause must return in the anchored stable window within the original step budget.", "continue_timing", "timing_window"),
    ("tvOS midpoint pause must preserve the anchored public photo before manual Next.", "control_action", "scene_identity"),
    ("tvOS midpoint setup requires a new stable public photo within the original step budget.", "continue_timing", "scene_identity"),
    # Existing reviewed prefixes.
    ("Visual ID failed history-start:", "history_start_capture", "scene_identity"),
    ("Visual ID failed history-first-next:", "history_first_next_capture", "scene_identity"),
    ("Visual ID failed history-second-next:", "history_second_next_capture", "scene_identity"),
    ("Visual ID failed history-first-previous:", "history_first_previous_capture", "scene_identity"),
    ("Visual ID failed history-second-previous:", "history_second_previous_capture", "scene_identity"),
    ("rotation-start-portrait did not stabilize within the ", "rotation_start_capture", "timing_window"),
    ("rotation-landscape-stable did not stabilize within the ", "rotation_landscape_capture", "timing_window"),
    ("rotation-portrait-stable did not stabilize within the ", "rotation_portrait_capture", "timing_window"),
    ("layout-landscape-multi did not stabilize within the ", "visible_scene_capture", "timing_window"),
    ("layout-portrait-multi did not stabilize within the ", "visible_scene_capture", "timing_window"),
    ("Could not recognize a public photo on screen within ", "visible_scene_capture", "scene_identity"),
    ("The public photo on screen did not change after next;", "history_navigation", "scene_identity"),
    ("Before rotating, the play button value must be pause (playing),", "control_action", "control_state"),
    ("The rotation sequence took ", "unknown", "timing_window"),
    ("Orientation API: after setting ", "unknown", "navigation"),
    ("Fresh install must open the normal first-boot page.", "firstboot_setup", "navigation"),
    ("First-boot page must show the API Key field.", "firstboot_setup", "navigation"),
    ("The API Key must be entered into the secure field.", "firstboot_setup", "control_state"),
    ("First-boot page must show Test Connection.", "firstboot_setup", "navigation"),
    ("First-boot page must show the Save Settings button.", "firstboot_setup", "navigation"),
    ("A successful save must lead to mode selection.", "firstboot_setup", "navigation"),
    ("The interval must be set to 30 seconds with the real slider.", "interval_setup", "interval_readback"),
    ("Playback settings must have display mode segments.", "display_policy", "navigation"),
    ("Display mode must offer the target option.", "display_policy", "navigation"),
    ("Display mode must switch to the target option.", "display_policy", "control_state"),
    ("Must be able to return from settings to playback.", "settings_navigation", "navigation"),
    ("Settings list must have the playback settings entry.", "settings_navigation", "navigation"),
    ("After opening playback settings, the auto-play toggle or the playback settings title must be visible.", "settings_navigation", "navigation"),
    ("The mode page must also offer the filter entry.", "mode_selection", "navigation"),
    ("Playback page after uninstall means a dirty install container;", "firstboot_setup", "navigation"),
    ("The public test URL must be entered verbatim,", "firstboot_setup", "control_state"),
    ("API Key must reach the secure field;", "firstboot_setup", "control_state"),
    ("iPad must rotate to landscape to record split-view evidence.", "unknown", "navigation"),
    ("The first-boot filter summary must offer a way back to mode selection.", "mode_selection", "navigation"),
    ("The iOS filter summary should no longer use a bottom back button,", "mode_selection", "navigation"),
    ("Connection test showed a failure alert:", "firstboot_setup", "navigation"),
    ("Pause again before history actions so the 5-second timer does not interfere.", "control_action", "control_state"),
    ("A nil mark must encode into JSON,", "visible_scene_capture", "evidence_capture"),
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
    ("tvOS pause-continue evidence is invalid;", "continue_timing", "evidence_capture"),
    ("iPhone pause-continue evidence is invalid;", "continue_timing", "evidence_capture"),
    ("tvOS new photo must be stably identifiable within 4 s of transition start", "continue_timing", "scene_identity"),
    ("iPhone new photo must be stably identifiable within 4 s of transition start", "continue_timing", "scene_identity"),
    ("All black must not count as a pass", "unknown", "scene_identity"),
    ("Blank must not count as a pass", "unknown", "scene_identity"),
    ("Unrecognizable input must not count as a pass", "unknown", "scene_identity"),
    ("No automatic photo change was captured within T±2;", "continue_timing", "timing_window"),
    ("Automatic photo change occurred before T-2;", "continue_timing", "timing_window"),
    ("Midpoint pause confirmation must finish before T-2;", "continue_timing", "timing_window"),
    ("Midpoint pause tap must return before T-2;", "continue_timing", "timing_window"),
    ("The playback page must have play/pause.", "control_action", "hidden_controls"),
    ("Play/pause must be hittable.", "control_action", "hidden_controls"),
    ("Play/pause must be hittable before continuing.", "control_action", "hidden_controls"),
    ("Play/pause value must be readable before acting.", "control_action", "probe_readback"),
    ("Play/pause must be paused before continuing.", "continue_timing", "control_state"),
    ("Must be playing before the mid-interval timing.", "continue_timing", "control_state"),
    ("Must be paused after the midpoint.", "control_action", "control_state"),
    ("Should be playing after Continue.", "continue_timing", "control_state"),
    ("This narrow entry must not enable a password.", "settings_navigation", "control_state"),
    ("Playback settings must provide the autoplay toggle.", "unknown", "hidden_controls"),
    ("Autoplay must be turned on through the real settings.", "interval_setup", "control_state"),
    ("Autoplay must be on for the pause/background cases.", "interval_setup", "control_state"),
    ("The pause/background cases must be able to switch to single-photo mode.", "interval_setup", "hidden_controls"),
    ("The display policy should offer single-photo mode.", "unknown", "hidden_controls"),
    ("Must return to the playback page after settings.", "settings_navigation", "navigation"),
    ("Failed to persist iPad watch sample diagnostics:", "continue_timing", "evidence_capture"),
    ("First-half-window evidence after Continue crossed the window;", "continue_timing", "timing_window"),
    ("Auto advance came before T-2;", "continue_timing", "timing_window"),
    ("A black screen with no new photo cannot pass automatically", "continue_timing", "scene_identity"),
    ("The iPad transition criterion is missing the original photo luma before Continue", "continue_timing", "evidence_capture"),
    ("Next-photo stable confirmation does not match the current raw screenshot", "visible_scene_capture", "evidence_capture"),
    ("Next photo did not form a stable new MATCH within ", "visible_scene_capture", "scene_identity"),
    ("Control-bar calibration must recognize the visible Settings crop.", "visible_scene_capture", "evidence_capture"),
    ("Screenshot cannot be used as identity;", "visible_scene_capture", "scene_identity"),
    ("Must be able to return from settings to the playback page.", "settings_navigation", "navigation"),
    ("The settings list must provide the playback settings entry", "settings_navigation", "navigation"),
    ("After opening playback settings, the autoplay toggle or the playback settings title must be visible.", "settings_navigation", "navigation"),
    ("Must not use the internal progress probe as the final criterion", "unknown", "evidence_capture"),
    ("launchEnvironment must not force-override the settings under test", "unknown", "evidence_capture"),
    ("Must not use the internal progress value instead of time and the screen", "control_action", "evidence_capture"),
    ("Photo changes while paused must not be judged by control value changes alone", "control_action", "evidence_capture"),
    ("The next photo after pause must show a different public pattern", "control_action", "scene_identity"),
    ("Tap the canvas to wake it before confirming play/pause", "control_action", "hidden_controls"),
    ("Do not tap again and toggle playback", "control_action", "control_state"),
    ("The confirmation wait must not happen before continueAt", "continue_timing", "timing_window"),
    ("A leftover settings button must not stand in for operable play/pause controls", "control_action", "hidden_controls"),
    ("The click return time must not be earlier than the press", "continue_timing", "timing_window"),
    ("Evidence crossing the window must not pass automatically", "continue_timing", "timing_window"),
    ("Black screen without a new photo must not pass automatically", "continue_timing", "scene_identity"),
    ("Black screen, zoom, control bar gone or unrecognized is not a transition", "continue_timing", "scene_identity"),
    ("An in-window start was detected but not signed off", "continue_timing", "evidence_capture"),
    ("Uncertain samples must remain pending video review; do not default to PASS", "continue_timing", "evidence_capture"),
    ("Too early/late transition or missing start cannot pass automatically", "continue_timing", "timing_window"),
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
    ("Chose filter but reached the playback page, so the mode card tap did not register.", "mode_selection", "navigation"),
    ("Still on the mode page after Continue; filter mode did not start.", "mode_selection", "navigation"),
    ("Filter mode must reach the filter summary page.", "mode_selection", "navigation"),
    ("Going back from the filter summary must return to mode selection.", "mode_selection", "navigation"),
    ("Random mode must reach the playback page.", "playback_entry", "navigation"),
    ("Mode departure failed after one hittable Continue without a password prompt;", "playback_entry", "navigation"),
    ("First-boot mode navigation must dismiss the exact password prompt,", "mode_selection", "navigation"),
    ("The playback page must show the Previous button.", "control_action", "hidden_controls"),
    ("After auto-advance, the playback controls must be revealable.", "control_action", "hidden_controls"),
    ("The playback page must show Play/Pause.", "control_action", "hidden_controls"),
    ("After pausing, the playback controls must still be revealable.", "control_action", "hidden_controls"),
    ("After pausing, the control value must be play.", "control_action", "control_state"),
    ("Album capture preparation must reach a stable scene before Pause.", "control_action", "timing_window"),
    ("Album capture preparation paused during a transition; Pause freezes the current layers.", "control_action", "control_state"),
    ("Album capture preparation must observe paused playback after one Pause.", "control_action", "control_state"),
    ("Album capture preparation must reach a complete paused scene within the playback capture budget.", "visible_scene_capture", "probe_readback"),
    ("Album capture pixels must match at least 0.6 seconds apart within the playback capture budget.", "visible_scene_capture", "scene_identity"),
    ("Album interval confirmation must read a valid non-empty scene progress probe before Pause.", "interval_setup", "probe_readback"),
    ("Album interval confirmation must observe a new scene after measuring a short interval before Pause.", "interval_setup", "timing_window"),
    ("Album interval confirmation must measure the current scene's 30-second progress slope before Pause.", "interval_setup", "interval_readback"),
    ("Album Next must advance the paused scene within the playback capture budget.", "history_navigation", "navigation"),
    ("Next control must be actionable before tapping.", "control_action", "hidden_controls"),
    ("Final Next preparation must provide an actionable control.", "control_action", "hidden_controls"),
    ("The current scene must be readable before tapping Next.", "visible_scene_capture", "scene_identity"),
    ("One Next tap must change the visible scene.", "control_action", "scene_identity"),
    ("Play/pause value must be readable before pausing.", "control_action", "probe_readback"),
    ("Playback page must provide play/pause.", "control_action", "hidden_controls"),
    ("Playback page must provide the settings entry.", "settings_navigation", "hidden_controls"),
    ("Tapping settings must open the settings page.", "settings_navigation", "navigation"),
    ("Resuming must continue from the current photo, with the control value back to pause.", "control_action", "control_state"),
    ("Previous must be disabled at the history boundary when playback starts.", "history_navigation", "control_state"),
    ("Playback must start with exactly one retained history entry.", "history_navigation", "control_state"),
    ("After two Next taps, Previous must be enabled.", "history_navigation", "control_state"),
    ("Visual ID failed ", "visible_scene_capture", "scene_identity"),
    ("After a pause of at least 10 seconds, autoplay must not resume on its own.", "paused_hold", "control_state"),
    ("After injecting the public fixture, the app must reach the mode page.", "mode_selection", "navigation"),
    ("After returning to the playback page, the control bar must be revealed again.", "settings_navigation", "hidden_controls"),
    ("The settings button must be tappable.", "settings_navigation", "hidden_controls"),
    ("The settings list must offer the playback settings entry", "settings_navigation", "navigation"),
    ("Could not return from playback settings to the playback page", "settings_navigation", "navigation"),
    ("Playback settings must offer the display mode segmented control.", "display_policy", "navigation"),
    ("Display mode must offer single photo mode.", "display_policy", "navigation"),
    ("The segmented control must remain after selecting single photo mode.", "display_policy", "control_state"),
    ("The display mode option must keep its Simplified Chinese copy.", "display_policy", "control_state"),
    ("Playback settings must offer the EXIF toggle.", "settings_navigation", "navigation"),
    ("Show EXIF info must be on.", "interval_setup", "control_state"),
    ("The playback interval must be 5 seconds.", "interval_setup", "interval_readback"),
    ("After identifying A2, Next must be tappable to check its successor.", "pause_window", "hidden_controls"),
    ("PRECONDITION_FAIL: order became A2→", "pause_window", "scene_identity"),
    ("PRECONDITION_FAIL: A2 successor is not A3 (", "pause_window", "scene_identity"),
    ("PRECONDITION_FAIL: not the large-text A2 after returning.", "pause_window", "scene_identity"),
    ("PRECONDITION_FAIL: could not identify the large-text A2 using Next.", "pause_window", "scene_identity"),
    ("Window missed or required frames missing: ", "pause_window", "evidence_capture"),
    ("The midpoint hook must leave the frame-synchronized probe paused.", "pause_window", "probe_readback"),
    ("probe_hit=MISS: frame-synchronized probe never saw outgoing translucent and incoming opacity=0 in 7 s.", "pause_window", "timing_window"),
    ("visual_verdict=MISSING_FRAMES: missing a window-detected, after-pause, after-pause-0_3s or play-to-pause keepAlways frame.", "pause_window", "evidence_capture"),
    ("visual_verdict=BLACK_OR_BLANK: synced probe missing after pause, or outgoing opacity already 0.", "pause_window", "probe_readback"),
    ("After pausing, the synced probe does not meet outgoing opacity>0 and incoming opacity=0.", "pause_window", "probe_readback"),
    ("The paused pause-window probe identity must not change.", "pause_window", "scene_identity"),
    ("Paused pause-window frames must be pixel-identical.", "pause_window", "scene_identity"),
    ("Pause window bright proof must show A2.", "pause_window", "scene_identity"),
    ("Pause window bright proof must be one frozen opaque scene.", "pause_window", "probe_readback"),
    ("Pause window midpoint must contain visible photo pixels.", "pause_window", "scene_identity"),
    ("Target window shows the wrong image; cannot count as SUCCESS.", "pause_window", "scene_identity"),
    ("The control bar must be visible before opening settings.", "control_action", "hidden_controls"),
    ("The control bar must be visible before starting pause-window playback.", "control_action", "hidden_controls"),
    ("After tapping Play, the button value must become pause.", "control_action", "control_state"),
    ("Pause before opening settings or identifying photos, so autoplay does not move away.", "control_action", "control_state"),
    ("visual_verdict=LATE: a complete A3 is visible after pause.", "pause_window", "scene_identity"),
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
    ("Person selection preparation must provide an actionable card;", "filter_selection", "control_state"),
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
    ("SmartFill Pause preparation was rejected before the deadline.", "control_action", "timing_window"),
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
    ("After returning from settings, confirm stable hidden receiver focus before one directional press.", "unknown", "focus"),
    ("After returning from settings with the bar hidden, the hidden receiver must have stable focus.", "settings_navigation", "focus"),
    ("After returning from settings, the playback transition must finish before a directional press.", "unknown", "timing_window"),
    ("After the first previous, one earlier history entry remains, so the button must stay enabled.", "history_navigation", "control_state"),
    ("Once the real controlled service is reachable, the connection-test-passed status must show.", "firstboot_setup", "navigation"),
    ("After the second previous returns to the history start, the button must be disabled again.", "history_navigation", "control_state"),
    ("After choosing random playback, focus must be able to move down to the Continue button.", "mode_selection", "focus"),
    ("After consuming one step of forward history, focus must be able to move to Next again.", "history_navigation", "focus"),
    ("With the real controlled service reachable, the connection test must show as passed.", "firstboot_setup", "navigation"),
    ("While the one-time hint is shown, default focus must land on the settings button.", "playback_entry", "focus"),
    ("Focus on the filter summary page must be able to move to Back to Mode Selection.", "mode_selection", "focus"),
    ("After returning from settings, must wait for the playback transition to finish.", "settings_navigation", "timing_window"),
    ("Going back from the filter summary must return to the mode selection page.", "mode_selection", "navigation"),
    ("Before the history chain starts, focus must be able to move to Play/Pause.", "history_navigation", "focus"),
    ("After settings return, must confirm the hidden receiver holds focus stably", "unknown", "focus"),
    ("Pressing Back/Menu on the settings page must return to the playback page.", "settings_navigation", "navigation"),
    ("Identity comes only from public fixture photos, never from logs or index", "visible_scene_capture", "evidence_capture"),
    ("After the control bar hides, the wake focus receiver layer must appear.", "hidden_controls", "hidden_controls"),
    ("After the first next settles, focus must be able to move to Next again.", "history_navigation", "focus"),
    ("After choosing filtered playback, the Continue button must be enabled.", "mode_selection", "control_state"),
    ("After settings return, no direction key until the transition completes", "unknown", "timing_window"),
    ("After submitting the URL, focus must be able to move down to API Key.", "firstboot_setup", "focus"),
    ("The index probe must change after a playback action. advanceObserved=", "history_navigation", "probe_readback"),
    ("Must focus the system keyboard submit button before submitting text.", "firstboot_setup", "focus"),
    ("After choosing random playback, the Continue button must be enabled.", "mode_selection", "control_state"),
    ("After going back once, focus must be able to move to Previous again.", "history_navigation", "focus"),
    ("After a successful connection, the Save Settings button must appear.", "firstboot_setup", "navigation"),
    ("Returning to playback must not require the control bar to be visible", "settings_navigation", "evidence_capture"),
    ("Focus in the playback control bar must be able to move to Settings.", "settings_navigation", "focus"),
    ("After saving settings, the app must reach the mode selection page.", "mode_selection", "navigation"),
    ("After choosing filtered playback, the Continue button must appear.", "mode_selection", "navigation"),
    ("At the history frontier, focus must be able to move to Play/Pause.", "history_navigation", "focus"),
    ("During a pause of at least 10 seconds, autoplay must not catch up.", "paused_hold", "scene_identity"),
    ("After autoplay resumes, focus on wake must return to Play/Pause.", "control_action", "focus"),
    ("A must be at the history start of the current playback session.", "history_navigation", "control_state"),
    ("Focus the system keyboard submit button before submitting text.", "firstboot_setup", "focus"),
    ("After submitting text, focus must return to the original field.", "unknown", "focus"),
    ("After Select on settings, must enter settings or the PIN gate.", "settings_navigation", "navigation"),
    ("After the pause wait, focus on wake must return to Play/Pause.", "control_action", "focus"),
    ("Wake after settings return is missing before/after screenshots", "unknown", "evidence_capture"),
    ("After a successful connection, Save Settings must be enabled.", "firstboot_setup", "control_state"),
    ("After choosing random play, focus must move down to Continue.", "mode_selection", "focus"),
    ("The start of the history chain must show the previous button.", "history_navigation", "hidden_controls"),
    ("Before checking autoplay, focus must be able to move to Next.", "control_action", "focus"),
    ("A forced display mode must not replace the real settings path", "visible_scene_capture", "evidence_capture"),
    ("The first playback round must show the one-time remote hint.", "playback_entry", "navigation"),
    ("Once history exists, focus must be able to move to Previous.", "history_navigation", "focus"),
    ("After auto-advance, focus on wake must return to Play/Pause.", "control_action", "focus"),
    ("At the initial history boundary, previous must be disabled.", "history_navigation", "control_state"),
    ("The end of the history chain must show the previous button.", "history_navigation", "hidden_controls"),
    ("The paused-frame comparison must span at least 10 seconds.", "paused_hold", "timing_window"),
    ("The second next must advance the playback cursor further.", "history_navigation", "navigation"),
    ("Pressing Select after pausing must resume autoplay.", "control_action", "control_state"),
    ("Autoplay must be pausable again before entering settings.", "control_action", "control_state"),
    ("The first-boot form must show the Test Connection button.", "firstboot_setup", "navigation"),
    ("Autoplay must be paused before the history chain starts.", "history_navigation", "control_state"),
    ("The playback page must expose the read-only index probe.", "history_navigation", "probe_readback"),
    ("Focus must be able to move from Next back to Play/Pause.", "history_navigation", "focus"),
    ("Select must not accidentally hit the API Key help sheet.", "firstboot_setup", "navigation"),
    ("The playback control bar must show the previous button.", "control_action", "hidden_controls"),
    ("Pressing Select after auto-advance must pause playback.", "control_action", "control_state"),
    ("After resuming, playback must advance to another photo.", "history_navigation", "probe_readback"),
    ("After submitting text, focus must return to the field.", "firstboot_setup", "focus"),
    ("After connecting, the Save Settings button must show.", "firstboot_setup", "navigation"),
    ("After choosing random play, Continue must be enabled.", "mode_selection", "control_state"),
    ("Returning to playback must confirm the playback layer", "unknown", "navigation"),
    ("The index probe must change after a playback action.", "history_navigation", "probe_readback"),
    ("Mode selection focus must start on random playback.", "mode_selection", "focus"),
    ("Focus must be able to move from Play/Pause to Next.", "history_navigation", "focus"),
    ("Pause/continue tvOS must run on a tvOS Simulator.", "unknown", "unknown"),
    ("After the pause wait, autoplay must be resumable.", "control_action", "control_state"),
    ("First directional press must only wake controls.", "unknown", "hidden_controls"),
    ("Directional key must wake the playback controls.", "hidden_controls", "hidden_controls"),
    ("After saving settings, mode selection must open.", "mode_selection", "navigation"),
    ("The full tvOS flow must run on a tvOS Simulator.", "unknown", "unknown"),
    ("The first next must advance the playback cursor.", "history_navigation", "navigation"),
    ("The settings button must open the settings page.", "settings_navigation", "navigation"),
    ("The first-boot form must show the API Key field.", "firstboot_setup", "navigation"),
    ("An arrow key must wake the playback control bar.", "hidden_controls", "hidden_controls"),
    ("Settings button must have focus before opening.", "settings_navigation", "focus"),
    ("URL submitted; focus must move down to API Key.", "firstboot_setup", "focus"),
    ("After choosing random play, Continue must show.", "mode_selection", "navigation"),
    ("A clean install must reach the first-boot form.", "firstboot_setup", "navigation"),
    ("A clean install must open the first-boot form.", "firstboot_setup", "navigation"),
    ("The server address must be submitted verbatim.", "firstboot_setup", "control_state"),
    ("Playback page must show the settings button.", "settings_navigation", "hidden_controls"),
    ("First-boot form must show the API Key field.", "firstboot_setup", "navigation"),
    ("Control bar must show after random playback.", "playback_entry", "hidden_controls"),
    ("Focus must return to play/pause after next.", "control_action", "focus"),
    ("The system keyboard must show Next or Done.", "unknown", "navigation"),
    ("Must not press twice to mask the first wake", "unknown", "hidden_controls"),
    ("First-boot form must show Test Connection.", "firstboot_setup", "navigation"),
    ("Settings home must show playback settings.", "settings_navigation", "navigation"),
    ("Settings subpage must show target option ", "settings_navigation", "navigation"),
    ("Pausing must not advance an extra photo.", "paused_hold", "scene_identity"),
    ("The field must be focused before typing.", "unknown", "focus"),
    ("A missing image must not count as a pass", "visible_scene_capture", "scene_identity"),
    ("The field must be focused before input.", "firstboot_setup", "focus"),
    ("System keyboard must show Next or Done.", "firstboot_setup", "navigation"),
    ("After pause, focus must reach next.", "control_action", "focus"),
    ("Must return to playback settings.", "settings_navigation", "focus"),
    ("Focus must reach play/pause.", "control_action", "focus"),
    ("Interval options are missing", "interval_setup", "interval_readback"),
    ("Settings page must have ", "settings_navigation", "navigation"),
    ("Must be able to focus ", "unknown", "focus"),
    ("After choosing settings.playback.", "unknown", "control_state"),
    ("Screenshot before-pause cannot serve as identity:", "visible_scene_capture", "scene_identity"),
    ("Screenshot after-next cannot serve as identity:", "visible_scene_capture", "scene_identity"),
    ("Screenshot before-background cannot serve as identity:", "visible_scene_capture", "scene_identity"),
    ("Screenshot after-background cannot serve as identity:", "visible_scene_capture", "scene_identity"),
    ("The playback index probe is empty, so autoplay and retained-history cannot be proven.", "history_navigation", "probe_readback"),
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
        # Only unwrap the known Swift error types; arbitrary error descriptions stay private.
        text = re.sub(r"^(?:failed - |XCT(?:Assert\w+|Unwrap) failed(?:\:.*?)? - )", "", message)
        for wrapper in ('failed: caught error: "message(\\"', 'failed: caught error: "message("',
                        'message(\\"', 'message("',
                        'failed: caught error: "Failure(message: \\"', 'failed: caught error: "Failure(message: "',
                        'Failure(message: \\"', 'Failure(message: "'):
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
            validate_diagnostic_fields({key: value for key, value in node.items() if key != FIRST_FAILURE_FIELD})
            key = str(node.get("nodeIdentifier", "")).removesuffix("()")
            diagnostics[key] = ({field: node[field] for field in DIAGNOSTIC_FIELDS}
                                if DIAGNOSTIC_FIELDS <= node.keys() else unknown_diagnostics())
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
        if ENVIRONMENT_LIMIT_FIELD in value:
            validate_environment_limit(value[ENVIRONMENT_LIMIT_FIELD])
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
        first_failure_seen |= FIRST_FAILURE_FIELD in value or ENVIRONMENT_LIMIT_FIELD in value
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
        if any(('"' + field + '"').encode() in ascii_keys for field in (BOUNDED_DIAGNOSTICS_FIELD, FIRST_FAILURE_FIELD, ENVIRONMENT_LIMIT_FIELD)) or any(
                ('"' + field + '"').encode() in data for field in DIAGNOSTIC_FIELDS | {VALIDATOR_FAILURE_FIELD}):
            raise ValueError("invalid failure diagnostic JSON")
