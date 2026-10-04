#!/usr/bin/env python3
"""Narrow iPad host test of the public-fixture playback page; does not wait for animation idle through XCTest."""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import plistlib
import re
import signal
import statistics
import subprocess
import sys
import time
import fcntl
import tempfile
import threading
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

from strict_e2e_photo_identity import classify_screenshot
from strict_e2e_server import GLYPHS, PUBLIC_API_KEY, fixture_manifest
from PIL import Image, ImageChops

APP_BUNDLE_ID = "com.331works.immichSlides"
FIXTURE_SET = "a"
FIXTURE_SCENARIO = "normal"
PLAYBACK_INTERVAL_SECONDS = 12
PLAYBACK_INTERVAL_SLIDER_PERCENT = 28


def app_launch_command(udid):
    """Launch the installed app normally, without injecting test settings or forcing a scenario."""
    return ["xcrun", "simctl", "launch", "--terminate-running-process", udid, APP_BUNDLE_ID]


def public_fixture_server_command(script_path, ready_path, log_path):
    return [
        sys.executable,
        str(script_path),
        "--host",
        "127.0.0.1",
        "--port",
        "0",
        "--fixture-set",
        FIXTURE_SET,
        "--scenario",
        FIXTURE_SCENARIO,
        "--ready-file",
        str(ready_path),
        "--log-file",
        str(log_path),
    ]


def visible_mark(path):
    image = Image.open(path).convert("RGB")
    w, h = image.size
    image = image.crop((int(w*.08), int(h*.32), int(w*.92), int(h*.68)))
    r, g, b = image.split()
    white = ImageChops.darker(ImageChops.darker(r, g), b).point(lambda x: 255 if x > 220 else 0)
    box = white.getbbox()
    if box is None:
        return None
    x, y, _, bottom = box
    step = (bottom-y)/7
    if step < 4 or x+11*step > white.width:
        return None
    bits = []
    for row in range(7):
        bits.append("".join("1" if white.getpixel((int(x+(col+.5)*step), int(y+(row+.5)*step))) else "0" for col in range(11)))
    def score(glyph):
        template = [GLYPHS["A"][row]+"0"+GLYPHS[glyph][row] for row in range(7)]
        return sum(a == b for a, b in zip("".join(bits), "".join(template)))/77
    ranked = sorted(((score(str(i)), f"A{i}") for i in range(1, 6)), reverse=True)
    return ranked[0][1] if ranked[0][0] >= .96 and ranked[0][0]-ranked[1][0] >= .04 else None


def control_state(path, frame, screen_width):
    image = Image.open(path).convert("RGB")
    scale = image.width / screen_width
    x,y,w,h = (frame[k] for k in ("x", "y", "width", "height"))
    crop = image.crop(tuple(int(v*scale) for v in (x+w*.23,y+h*.23,x+w*.77,y+h*.77)))
    columns = [sum(max(crop.getpixel((x,y))) < 75 for y in range(crop.height)) > crop.height*.25 for x in range(crop.width)]
    groups = []
    for i, bit in enumerate(columns):
        if bit and (i == 0 or not columns[i-1]):
            groups.append([])
        if bit:
            groups[-1].append(i)
    if len(groups) == 2 and min(map(len, groups)) >= 4:
        return "pause"
    if len(groups) == 1 and len(groups[0]) >= 6:
        return "play"
    return None


def require(ok, message):
    if not ok:
        raise ValueError(message)


def script_repository_root():
    return Path(__file__).resolve().parent.parent


def validate_source_checkout(source_sha, *, repo_root=None, runner=subprocess.run):
    require(bool(re.fullmatch(r"[0-9a-fA-F]{40}", source_sha or "")), "--app-sha must be a 40-character Git SHA")
    root = Path(repo_root or script_repository_root()).resolve()
    head_result = runner(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        timeout=20,
    )
    require(head_result.returncode == 0, f"Cannot read HEAD of the script's repository: {head_result.stderr[:200]}")
    head = head_result.stdout.strip().lower()
    require(bool(re.fullmatch(r"[0-9a-f]{40}", head)), "HEAD of the script's repository is not a full Git SHA")
    require(head == source_sha.lower(), "--app-sha does not match the current HEAD of the script's repository")

    status_result = runner(
        ["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all"],
        capture_output=True,
        text=True,
        timeout=20,
    )
    require(status_result.returncode == 0, f"Cannot check the script repository's working tree: {status_result.stderr[:200]}")
    require(not status_result.stdout, "The script repository working tree is not clean; refusing to verify uncommitted source")
    return head


def _sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _app_bundle_hashes(app_bundle):
    bundle = Path(app_bundle).expanduser().resolve()
    require(bundle.suffix == ".app" and bundle.is_dir(), f"App input is not a .app directory: {bundle}")
    info_path = bundle / "Info.plist"
    require(info_path.is_file(), f"App is missing Info.plist: {bundle}")
    try:
        with info_path.open("rb") as info_file:
            info = plistlib.load(info_file)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise ValueError(f"Cannot read App Info.plist: {error}") from error

    bundle_id = info.get("CFBundleIdentifier")
    require(bundle_id == APP_BUNDLE_ID, f"App Bundle ID mismatch: {bundle_id!r}")
    executable = info.get("CFBundleExecutable")
    require(
        isinstance(executable, str) and executable and Path(executable).name == executable,
        "CFBundleExecutable in App Info.plist is invalid",
    )
    executable_path = bundle / executable
    require(executable_path.is_file(), f"App main executable does not exist: {executable_path}")

    debug_dylib_path = bundle / f"{executable}.debug.dylib"
    require(not debug_dylib_path.exists() or debug_dylib_path.is_file(), "App debug dylib path is not a regular file")
    return {
        "bundle_path": str(bundle),
        "bundle_id": bundle_id,
        "executable": executable,
        "executable_sha256": _sha256(executable_path),
        "debug_dylib_sha256": _sha256(debug_dylib_path) if debug_dylib_path.is_file() else None,
    }


def app_bundle_hashes(built_app, installed_app, expected_binary_sha256):
    require(
        bool(re.fullmatch(r"[0-9a-fA-F]{64}", expected_binary_sha256 or "")),
        "--binary-sha256 must be a 64-character SHA-256",
    )
    expected = expected_binary_sha256.lower()
    built = _app_bundle_hashes(built_app)
    installed = _app_bundle_hashes(installed_app)
    require(
        built["executable_sha256"] == expected,
        "Built app main executable SHA-256 does not match --binary-sha256",
    )
    require(
        installed["executable_sha256"] == expected,
        "Installed app main executable SHA-256 does not match the build output SHA-256",
    )
    require(
        (built["debug_dylib_sha256"] is None) == (installed["debug_dylib_sha256"] is None),
        "Built and installed app debug dylib presence differs",
    )
    if built["debug_dylib_sha256"] is not None:
        require(
            built["debug_dylib_sha256"] == installed["debug_dylib_sha256"],
            "Built and installed app debug dylib SHA-256 differ",
        )
    return {"built": built, "installed": installed}


def _git_sha_argument(value):
    if not re.fullmatch(r"[0-9a-fA-F]{40}", value or ""):
        raise argparse.ArgumentTypeError("must be a 40-character Git SHA")
    return value.lower()


def _sha256_argument(value):
    if not re.fullmatch(r"[0-9a-fA-F]{64}", value or ""):
        raise argparse.ArgumentTypeError("must be a 64-character SHA-256")
    return value.lower()


def assess(frames, mark, baseline, press_duration):
    require(0 <= press_duration <= 2, "Tap time uncertainty exceeds 2 seconds")
    require(baseline > .1, "Baseline photo is too dark to detect the transition automatically")
    require(len(frames) >= 15, "Not enough valid frames")
    require(frames[0]["start"] <= 3, "Missing the starting frames after resume")
    require(frames[-1]["end"] >= 18, "Recording/sampling does not cover the window where the new photo is recognizable")
    for i, f in enumerate(frames):
        require(0 <= f["end"] - f["start"] <= 1, "A single screenshot took longer than 1 second")
        if i:
            require(0 <= f["start"] - frames[i-1]["end"] <= .6, "Gap in frame capture")
    early = [f for f in frames if f["end"] <= 6]
    require(early and all(f["mark"] == mark for f in early), "Early frames after resume are not the original photo")
    # A brightness drop only locates the candidate onset; a different public photo must follow,
    # and the final frames need review.
    onset = next((i for i, f in enumerate(frames)
                  if f["luma"] < baseline * .95 or f["mark"] != mark
                  or (i > 0 and f["luma"] < frames[i-1]["luma"] * .998)), None)
    require(onset is not None and onset > 0, "First transition not captured")
    lo = frames[onset-1]["start"] - press_duration
    hi = frames[onset]["end"]
    require(lo >= 10 and hi <= 14, f"Possible first-transition interval [{lo:.3f}, {hi:.3f}] is out of range")
    require(all(f["mark"] == mark for f in frames[:onset]), "Unknown or different photo before the transition")
    new = next((f for f in frames[onset:] if f["mark"] not in (None, mark)), None)
    require(new is not None, "No recognizable different public photo after the transition")
    require(new["end"] - frames[onset]["start"] <= 4, "New photo appeared too late after the candidate darkening")
    stable = [f for f in frames if new["start"] <= f["start"] <= new["start"]+2]
    require(len(stable) >= 3 and stable[-1]["end"]-stable[0]["start"] >= 1
            and all(f["mark"] == new["mark"] for f in stable), "New photo did not stay recognizable")
    return {"status": "PASS", "first_transition_interval": [lo, hi],
            "new_mark": new["mark"], "new_photo_by": new["end"],
            "visual_review": "REQUIRED", "execution_kind": "HOST_UI_NOT_XCTEST"}


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.get("children", []):
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


class Run:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.output).resolve()
        self.out.mkdir(parents=True, exist_ok=False)
        self.events = []
        self.counter = 0
        self.video = None
        self.fixture_process = None
        self.fixture_url = None
        self.lock = open(Path(tempfile.gettempdir()) / f"immichSlides-pause-{args.udid}.lock", "w")
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def save(self, name, data):
        (self.out / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")

    def command(self, *cmd):
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        require(r.returncode == 0, f"Command failed {cmd[0:2]}: {r.stderr[:200]}")
        return r.stdout

    def wait_for_ui(self, predicate, message, timeout=20):
        deadline = time.monotonic() + timeout
        while True:
            current = self.ui()
            if predicate(current):
                return current
            if time.monotonic() >= deadline:
                break
            time.sleep(.25)
        raise ValueError(message)

    @staticmethod
    def node(nodes_, uid):
        found = [node for node in nodes_ if node.get("AXUniqueId") == uid]
        require(len(found) == 1, f"Accessible target is not unique: {uid}")
        return found[0]

    def tap_label(self, label):
        found = [node for node in self.ui() if node.get("AXLabel") == label and node.get("enabled")]
        require(len(found) == 1, f"Actionable label is not unique: {label}")
        frame = found[0].get("frame") or {}
        x = frame.get("x", 0) + frame.get("width", 0) / 2
        y = frame.get("y", 0) + frame.get("height", 0) / 2
        require(frame.get("width", 0) > 0 and frame.get("height", 0) > 0, f"Missing actionable coordinates: {label}")
        hit = list(nodes(json.loads(self.command("axe", "describe-ui", "--udid", self.args.udid, "--point", f"{x},{y}"))))
        require(any(node.get("AXLabel") == label for node in hit), f"Label center hit test missed: {label}")
        return self.tap_point(x, y, label)

    def replace_text(self, uid, value, *, verify_value):
        self.tap(uid)
        self.command("axe", "key-combo", "--modifiers", "227", "--key", "4", "--udid", self.args.udid)
        self.command("axe", "type", value, "--udid", self.args.udid)
        if verify_value:
            current = self.wait_for_ui(
                lambda tree: any(node.get("AXUniqueId") == uid and node.get("AXValue") == value for node in tree),
                f"Real UI did not read back the input: {uid}",
            )
            self.node(current, uid)

    def enter_playback_from_mode_selection(self):
        tree = self.ui()
        if not any(node.get("AXUniqueId") == "mode.random.button" for node in tree):
            return False
        self.tap_mode_button("mode.random.button")
        tree = self.wait_for_ui(
            lambda current: any(
                node.get("AXUniqueId") == "mode.continue.button" and node.get("enabled")
                for node in current
            ),
            "Playback mode page has no actionable Continue button",
            timeout=10,
        )
        self.tap_mode_button("mode.continue.button")
        self.wait_for_ui(
            lambda current: any(node.get("AXUniqueId") == "slideshow.control.next.button" for node in current),
            "Did not reach playback after choosing shuffle",
            timeout=30,
        )
        return True

    def open_server_settings(self):
        tree = self.ui()
        if any(node.get("AXUniqueId") == "firstboot.serverURL.field" for node in tree):
            return
        if any(node.get("AXUniqueId") == "slideshow.control.settings.button" for node in tree):
            self.wake()
            self.tap("slideshow.control.settings.button")
            tree = self.wait_for_ui(
                lambda current: any(node.get("AXUniqueId") == "settings.item.server" for node in current),
                "No server settings entry after opening settings from playback",
                timeout=12,
            )
        if any(node.get("AXUniqueId") == "settings.item.server" for node in tree):
            self.tap("settings.item.server")
        else:
            raise ValueError("Launch page is neither the first-launch server form nor offers a real settings entry")
        self.wait_for_ui(
            lambda current: any(node.get("AXUniqueId") == "firstboot.serverURL.field" for node in current)
            and any(node.get("AXUniqueId") == "firstboot.apiKey.field" for node in current),
            "Server settings page is missing the real URL or API Key field",
            timeout=12,
        )

    def configure_public_server_through_ui(self):
        require(self.fixture_url is not None, "Public fixture service is not ready yet")
        self.replace_text("firstboot.serverURL.field", self.fixture_url, verify_value=True)
        self.replace_text("firstboot.apiKey.field", PUBLIC_API_KEY, verify_value=False)
        tree = self.ui()
        require(
            not self.node(tree, "firstboot.saveConfig.button").get("enabled"),
            "Save remains enabled after server inputs changed; cannot prove this fixture was re-tested",
        )
        self.save("server-form-precondition.json", {
            "source": "real_settings_ui",
            "server_url": self.fixture_url,
            "api_key_value_persisted": False,
            "fixture_set": FIXTURE_SET,
        })
        self.tap("firstboot.testConnection.button")
        tree = self.wait_for_ui(
            lambda current: any(
                node.get("AXUniqueId") == "firstboot.saveConfig.button" and node.get("enabled")
                for node in current
            ),
            "Real UI connection test did not succeed; refusing to save the public fixture config",
            timeout=45,
        )
        self.save("server-connection-succeeded.json", {
            "source": "real_settings_ui",
            "save_enabled_after_connection": bool(
                self.node(tree, "firstboot.saveConfig.button").get("enabled")
            ),
            "server_url": self.fixture_url,
            "fixture_set": FIXTURE_SET,
        })
        self.tap("firstboot.saveConfig.button")
        self.wait_for_ui(
            lambda current: any(node.get("AXUniqueId") == "mode.random.button" for node in current)
            or any(node.get("AXUniqueId") == "settings.item.server" for node in current)
            or any(node.get("AXUniqueId") == "firstboot.serverURL.field" for node in current)
            or any(node.get("AXUniqueId") == "slideshow.control.next.button" for node in current),
            "Did not reach a recognizable page after saving the real server settings",
            timeout=20,
        )

    def return_to_playback(self):
        for _ in range(8):
            tree = self.ui()
            if any(node.get("AXUniqueId") == "slideshow.control.next.button" for node in tree):
                return
            if any(node.get("AXUniqueId") == "mode.random.button" for node in tree):
                self.enter_playback_from_mode_selection()
                return
            back_id = next((
                uid for uid in ("global.back.button", "BackButton")
                if any(node.get("AXUniqueId") == uid and node.get("enabled") for node in tree)
            ), None)
            if back_id is None:
                break
            self.tap(back_id)
        raise ValueError("Cannot return to playback through real back navigation; refusing to fake the pause test precondition")

    def open_playback_settings(self):
        tree = self.ui()
        if any(node.get("AXUniqueId") == "settings.playback.interval.slider" for node in tree):
            return
        if any(node.get("AXUniqueId") == "slideshow.control.settings.button" for node in tree):
            self.wake()
            self.tap("slideshow.control.settings.button")
            tree = self.wait_for_ui(
                lambda current: any(node.get("AXUniqueId") == "settings.item.playback" for node in current)
                or any(node.get("AXUniqueId") == "settings.playback.interval.slider" for node in current),
                "No playback settings entry after opening real settings",
                timeout=12,
            )
        if any(node.get("AXUniqueId") == "settings.item.playback" for node in tree):
            self.tap("settings.item.playback")
        self.wait_for_ui(
            lambda current: any(node.get("AXUniqueId") == "settings.playback.autoPlay.toggle" for node in current)
            and any(node.get("AXUniqueId") == "settings.playback.interval.slider" for node in current),
            "Real playback settings page is missing the auto-play toggle or interval slider",
            timeout=12,
        )

    def configure_playback_settings_through_ui(self):
        self.open_playback_settings()
        tree = self.ui()
        auto_play = self.node(tree, "settings.playback.autoPlay.toggle")
        if str(auto_play.get("AXValue")) != "1":
            self.tap("settings.playback.autoPlay.toggle")
            tree = self.wait_for_ui(
                lambda current: any(
                    node.get("AXUniqueId") == "settings.playback.autoPlay.toggle"
                    and str(node.get("AXValue")) == "1"
                    for node in current
                ),
                "Real UI could not turn on auto-play",
                timeout=5,
            )

        if not any(node.get("AXLabel") == f"{PLAYBACK_INTERVAL_SECONDS} 秒" for node in tree):
            self.command(
                "axe",
                "slider",
                "--id",
                "settings.playback.interval.slider",
                "--value",
                str(PLAYBACK_INTERVAL_SLIDER_PERCENT),
                "--udid",
                self.args.udid,
            )
            tree = self.wait_for_ui(
                lambda current: any(
                    node.get("AXLabel") == f"{PLAYBACK_INTERVAL_SECONDS} 秒" for node in current
                ),
                f"The real UI slider did not read back {PLAYBACK_INTERVAL_SECONDS} seconds",
                timeout=8,
            )
        require(
            any(node.get("AXLabel") == f"{PLAYBACK_INTERVAL_SECONDS} 秒" for node in tree),
            f"The real UI slider did not read back {PLAYBACK_INTERVAL_SECONDS} seconds",
        )

        is_single_photo = any(
            node.get("AXLabel") == "单图模式" and str(node.get("AXValue")) == "1"
            for node in tree
        )
        if not is_single_photo:
            self.tap_label("单图模式")
            tree = self.wait_for_ui(
                lambda current: any(
                    node.get("AXLabel") == "单图模式" and str(node.get("AXValue")) == "1"
                    for node in current
                ),
                "Real UI could not save single-photo mode",
                timeout=5,
            )

        settings = {
            "autoPlayEnabled": str(self.node(tree, "settings.playback.autoPlay.toggle").get("AXValue")) == "1",
            "intervalSeconds": PLAYBACK_INTERVAL_SECONDS,
            "displayMode": "singlePhoto",
            "source": "real_settings_ui",
        }
        require(settings["autoPlayEnabled"], "Real playback settings readback: auto-play is not on")
        require(
            any(node.get("AXLabel") == "单图模式" and str(node.get("AXValue")) == "1" for node in tree),
            "Real playback settings readback: single-photo mode is not on",
        )
        self.save("pause-test-real-settings.json", settings)
        return settings

    def prepare_public_fixture(self):
        self.start_public_fixture()
        self.command(*app_launch_command(self.args.udid))
        tree = self.wait_for_ui(
            lambda current: any(node.get("AXUniqueId") in {
                "firstboot.serverURL.field",
                "mode.random.button",
                "slideshow.control.next.button",
                "settings.item.server",
                "settings.playback.interval.slider",
            } for node in current),
            "No supported real page appeared after launching the installed app",
            timeout=20,
        )
        if any(node.get("AXUniqueId") == "firstboot.serverURL.field" for node in tree):
            self.configure_public_server_through_ui()
        else:
            if any(node.get("AXUniqueId") == "mode.random.button" for node in tree):
                self.enter_playback_from_mode_selection()
            self.return_to_playback()
            self.open_server_settings()
            self.configure_public_server_through_ui()

        self.return_to_playback()
        self.configure_playback_settings_through_ui()
        self.tap("BackButton")
        self.verify_settings()

    def start_public_fixture(self):
        ready_path = self.out / "fixture-service-ready.json"
        service_log = self.out / "fixture-service.log"
        manifest = fixture_manifest(FIXTURE_SET)
        self.save("fixture-manifest.json", manifest)
        command = public_fixture_server_command(
            Path(__file__).with_name("strict_e2e_server.py"), ready_path, service_log
        )
        self.fixture_process = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 10
        payload = None
        while time.monotonic() < deadline:
            require(self.fixture_process.poll() is None, f"Public fixture service exited early: {self.fixture_process.returncode}")
            if ready_path.is_file():
                try:
                    candidate = json.loads(ready_path.read_text(encoding="utf-8"))
                    require(candidate.get("pid") == self.fixture_process.pid, "fixture ready PID does not match the child process")
                    with urlopen(f"http://{candidate['host']}:{candidate['port']}/healthz", timeout=1) as response:
                        if response.status == 200:
                            payload = candidate
                            break
                except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError, URLError):
                    pass
            time.sleep(.05)
        require(payload is not None, "Public fixture service health check timed out")
        self.fixture_url = f"http://{payload['host']}:{payload['port']}/api"
        self.save("fixture-service.json", {
            "fixture_set": FIXTURE_SET,
            "scenario": FIXTURE_SCENARIO,
            "server_url": self.fixture_url,
            "pid": payload["pid"],
            "fixture_sha256": manifest["fixture_sha256"],
        })

    def ui(self):
        return list(nodes(json.loads(self.command("axe", "describe-ui", "--udid", self.args.udid))))

    def target(self, uid):
        found = [n for n in self.ui() if n.get("AXUniqueId") == uid and n.get("enabled")]
        require(len(found) == 1, f"Actionable target is not unique: {uid}")
        return found[0]

    def tap_point(self, x, y, name):
        start = time.monotonic()
        wall = time.time()
        event = {"action": name, "x": x, "y": y, "start": start, "wall": wall, "state": "issued"}
        self.events.append(event)
        self.save("actions.json", self.events)
        self.command("axe", "tap", "-x", str(x), "-y", str(y), "--tap-style", "physical", "--udid", self.args.udid)
        end = time.monotonic()
        event.update(end=end, state="returned")
        self.save("actions.json", self.events)
        require(end - start <= 3, f"Tap took abnormally long: {name}")
        return start, end

    def wake(self):
        # Derive the canvas point from the actual root view size; never use another device's hard-coded coordinates.
        current = self.ui()
        if any(n.get("AXUniqueId") == "slideshow.control.playPause.button" and n.get("enabled") for n in current):
            return
        frame = next(n["frame"] for n in current if n.get("frame") and n["frame"].get("width", 0) > 500)
        self.tap_point(frame["width"] * .5, frame["height"] * .4, "wake control bar")
        time.sleep(.25)

    def tap(self, uid):
        n = self.target(uid)
        f = n["frame"]
        x, y = f["x"] + f["width"] / 2, f["y"] + f["height"] / 2
        hit = list(nodes(json.loads(self.command("axe", "describe-ui", "--udid", self.args.udid, "--point", f"{x},{y}"))))
        require(any(n.get("AXUniqueId") == uid for n in hit), f"Target center hit test missed: {uid}")
        return self.tap_point(x, y, uid)

    def tap_mode_button(self, uid):
        # An AX hit test at the mode card center may return only the container, so tap the unique button's
        # activation point instead, still as a physical tap.
        require(uid in {"mode.random.button", "mode.continue.button"}, "Only mode page buttons may use this entry point")
        self.target(uid)
        start = time.monotonic()
        event = {"action": uid, "targeting": "accessibility_activation_point",
                 "start": start, "wall": time.time(), "state": "issued"}
        self.events.append(event)
        self.save("actions.json", self.events)
        self.command("axe", "tap", "--id", uid, "--element-type", "Button",
                     "--tap-style", "physical", "--udid", self.args.udid)
        end = time.monotonic()
        event.update(end=end, state="returned")
        self.save("actions.json", self.events)
        require(end - start <= 3, f"Tap took abnormally long: {uid}")
        return start, end

    def shot(self, label):
        self.counter += 1
        path = self.out / f"{self.counter:03d}-{label}.png"
        start = time.monotonic()
        self.command("axe", "screenshot", "--udid", self.args.udid, "--output", str(path))
        sample = {"start": start, "end": time.monotonic(), "path": path.name}
        with (self.out / "screenshot-timestamps.jsonl").open("a") as log:
            log.write(json.dumps(sample)+"\n")
        return sample

    def identify(self, sample):
        identity = classify_screenshot((self.out / sample["path"]).read_bytes())
        return {**sample, "mark": visible_mark(self.out / sample["path"]),
                "luma": identity.mean_luma, "identity": dataclasses.asdict(identity)}

    def continue_with_visible_clock(self):
        frame = self.target("slideshow.control.playPause.button")["frame"]
        screen = next(n["frame"]["width"] for n in self.ui() if n.get("frame") and n["frame"].get("width",0)>500)
        captured, errors = [], []
        stop = threading.Event()
        ready = threading.Event()
        def collect():
            try:
                while not stop.is_set():
                    captured.append(self.shot("button-toggle"))
                    ready.set()
                    time.sleep(.05)
            except BaseException as e:
                errors.append(str(e))
                ready.set()
        thread = threading.Thread(target=collect)
        thread.start()
        try:
            require(ready.wait(5) and not errors, "Evidence capture was not ready before the tap")
            issued, returned = self.tap("slideshow.control.playPause.button")
            time.sleep(.5)
        finally:
            stop.set()
            thread.join(timeout=25)
        require(not thread.is_alive() and not errors, "Tap evidence capture thread failed")
        for s in captured:
            s["control"] = control_state(self.out/s["path"], frame, screen)
        self.save("button-toggle.json", captured)
        first = next((i for i,s in enumerate(captured) if s["control"] == "pause"), None)
        require(first is not None and first>0, "Did not capture the play triangle turning into the pause bars")
        before = captured[first-1]
        after = captured[first]
        require(before["control"] == "play", "Button state before the change is uncertain")
        self.save("resume-real-time-window.json", {"issued": issued, "returned": returned,
                  "earliest": issued, "latest": returned,
                  "visible_feedback": [before["start"], after["end"]],
                  "note": "Button feedback only proves the action took effect; it does not narrow the real input time"})
        return issued, returned

    def verify_settings(self):
        self.open_playback_settings()
        current = self.ui()
        self.save("real-settings.json", current)
        require(
            any(n.get("AXLabel") == f"{PLAYBACK_INTERVAL_SECONDS} 秒" for n in current),
            f"Precondition: the real setting must be {PLAYBACK_INTERVAL_SECONDS} seconds",
        )
        require(any(n.get("AXUniqueId") == "settings.playback.autoPlay.toggle" and str(n.get("AXValue")) == "1" for n in current), "Precondition: auto-play must be on")
        require(any(n.get("AXLabel") == "单图模式" and str(n.get("AXValue")) == "1" for n in current), "Precondition: single-photo mode is required")
        self.shot("real-settings")
        self.tap("BackButton")
        self.return_to_playback()

    def execute(self):
        available = int(self.command("df", "-k", "/System/Volumes/Data").splitlines()[1].split()[3]) * 1024
        require(available >= 80 * 1024**3, "Data has less than 80Gi free")
        source_head = validate_source_checkout(self.args.app_sha)
        built_app = Path(self.args.built_app).expanduser().resolve()
        app = Path(self.command("xcrun", "simctl", "get_app_container", self.args.udid, APP_BUNDLE_ID, "app").strip())
        hashes = app_bundle_hashes(built_app, app, self.args.binary_sha256)
        self.save("environment.json", {
            "app_sha": source_head,
            "udid": self.args.udid,
            "free_gib": available / 1024**3,
            "test_head": source_head,
            "binary_hashes": hashes,
        })
        self.video_log = (self.out / "recording.log").open("w")
        self.record_start = time.monotonic()
        self.save("recording-start.json", {"wall": time.time(), "monotonic": time.monotonic()})
        self.video = subprocess.Popen(["axe", "record-video", "--udid", self.args.udid, "--fps", "10", "--output", str(self.out / "session.mp4")], stdout=self.video_log, stderr=self.video_log)
        time.sleep(1)
        require(self.video.poll() is None, "Recording did not start")
        self.prepare_public_fixture()
        self.wake()
        require(self.target("slideshow.control.playPause.button").get("AXValue") == "pause", "Not playing at the start")
        scene_start, scene_end = self.tap("slideshow.control.next.button")
        time.sleep(3)
        playing = self.identify(self.shot("playback-midpoint-precondition"))
        require(playing["mark"] is not None, "Photo in the playback precondition is not recognizable")
        self.wake()
        pause_start, pause_end = self.tap("slideshow.control.playPause.button")
        require(pause_start-scene_end >= 3 and pause_end-scene_start <= 10, "Did not pause in the middle of playback")
        self.save("midpoint-pause.json", {"earliest": pause_start-scene_end, "latest": pause_end-scene_start})
        require(self.target("slideshow.control.playPause.button").get("AXValue") == "play", "Pause did not take effect; not retrying")
        before = self.identify(self.shot("paused"))
        require(before["mark"] == playing["mark"], "Not the same public photo before and after pausing")
        self.tap("slideshow.control.next.button")
        time.sleep(3)
        after = self.identify(self.shot("next-photo"))
        require(after["mark"] is not None and before["mark"] != after["mark"], "Next did not show a different public photo")
        hold = []
        until = time.monotonic() + 14
        while time.monotonic() < until:
            hold.append(self.shot("pause-hold"))
            time.sleep(.2)
        hold.append(self.shot("pause-hold-end"))
        hold = [self.identify(s) for s in hold]
        self.save("pause-hold.json", hold)
        require(all(s["mark"] == after["mark"] for s in hold), "Photo changed or became unrecognizable during the pause hold")
        self.wake()
        require(self.target("slideshow.control.playPause.button").get("AXValue") == "play", "Not paused before resuming")
        issued, returned = self.continue_with_visible_clock()
        samples = []
        while time.monotonic() - issued < 23:
            samples.append(self.shot("resume-window"))
        samples = [{**self.identify(s), "start": s["start"] - issued, "end": s["end"] - issued} for s in samples]
        self.save("resume-window.json", samples)
        verdict = assess(samples, after["mark"], statistics.median(s["luma"] for s in hold), returned - issued)
        return verdict

    def close(self):
        failure = None
        process = self.video
        try:
            if process:
                stop_at = time.monotonic()
                self.stop_child(process, timeout=10)
                self.video = None
                self.video_log.close()
                require(process.returncode == 0, "Recording finalization failed")
                require((self.out / "session.mp4").stat().st_size > 1024, "Recording is missing")
                raw = json.loads(self.command("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", str(self.out / "session.mp4")))
                pts = [float(f["best_effort_timestamp_time"]) for f in raw["frames"]]
                require(len(pts) > 10, "Not enough recording frames")
                gap = max(b-a for a,b in zip(pts, pts[1:]))
                self.save("recording-continuity.json", {"frames": len(pts), "max_gap": gap, "duration": pts[-1]-pts[0], "wall_duration": stop_at-self.record_start})
                require(gap <= .6, "Recording capture gap exceeds 0.6 seconds")
                require(abs(pts[-1]-pts[0]-(stop_at-self.record_start)) <= 2, "Recording span does not match the operation clock span")
        except BaseException as caught:
            failure = caught
        finally:
            self.video = None
            if process and not self.video_log.closed:
                self.video_log.close()

        fixture = self.fixture_process
        try:
            if fixture:
                self.stop_child(fixture, timeout=5)
        except BaseException as caught:
            if failure is None:
                failure = caught
            else:
                failure = RuntimeError(f"{failure}; fixture cleanup: {caught}")
        finally:
            self.fixture_process = None
            self.lock.close()
        if failure:
            raise failure

    @staticmethod
    def stop_child(process, *, timeout):
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--app-sha", required=True, type=_git_sha_argument)
    parser.add_argument("--built-app", required=True, help="The .app directory actually built for this candidate")
    parser.add_argument("--binary-sha256", required=True, type=_sha256_argument,
                        help="SHA-256 of CFBundleExecutable in this build output")
    args = parser.parse_args()
    run = Run(args)
    error = None
    try:
        verdict = run.execute()
    except BaseException as caught:
        error = caught
    finally:
        try:
            run.close()
        except BaseException as cleanup_error:
            error = RuntimeError(f"{error or ''}; recording cleanup: {cleanup_error}")
    if error:
        run.save("result.json", {"status": "FAILED", "error": str(error), "execution_kind": "HOST_UI_NOT_XCTEST"})
        raise error
    run.save("result.json", verdict)
    print(json.dumps(verdict, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
