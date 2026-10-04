# iPad pause host narrow test

Run the automated iPad pause regression with the `ios-lifecycle-pause` XCTest described in [docs/TESTING.md](../docs/TESTING.md#running-controlled-integration-and-end-to-end-tests). This host script is a separate diagnostic tool; its results do not replace XCTest results.

This entry starts from **the already built and installed iPad Simulator App of the current candidate** and drives the real visible screens with AXe. It does not build or install the App, and it does not pass off private XCTest launch arguments as successful settings. Before running, the source repository must be a clean worktree after commit, and `--app-sha` must exactly match the current `HEAD` of the repository that contains the script. The result type is fixed to `HOST_UI_NOT_XCTEST` and must not rewrite or override historical XCTest failures.

## Preparation and inputs

Requires macOS, Xcode's `simctl`, AXe, `ffprobe`, Python 3 + Pillow, and one booted iPad Simulator in exclusive use. `--built-app` must point to the `.app` actually produced by this candidate's build, and the Bundle ID of both the built bundle and the installed bundle must be `com.331works.immichSlides`. The `Debug` configuration of the shared scheme `immichSlides-iOS` is recommended. Record the real build command, exit code, scheme, configuration, destination, derived data path and the full Git SHA of the build source. The script can only check the current clean source `HEAD`, the contents of the build product and the contents of the installed product; the SHA alone cannot prove that the build command actually compiled this source.

`--binary-sha256` must be computed from the `CFBundleExecutable` named in the `Info.plist` of `--built-app`. The script computes the main-executable hashes of the built bundle and the installed bundle separately and compares each with it. If `<CFBundleExecutable>.debug.dylib` exists in either bundle, the script also requires it to be present or absent in both alike with identical file hashes, and records the hash mapping of both sides in `environment.json`. The source SHA, the built main-executable hash and the installed main-executable hash cannot stand in for one another.

At run time the script starts the repository's existing `strict_e2e_server.py` in the evidence directory with public fixture set A and the `normal` scenario, binds a random loopback port and checks `/healthz`. It then launches the App with a normal `simctl launch` without arguments and, depending on the current first screen, enters the first-launch server form or the normal settings page. Through the visible UI it enters the fixture URL and the public test Key in place of the existing values, actually runs "Test Connection" and saves, and then sets autoplay, 12 seconds and single photo on the visible playback settings page. It leaves the settings page, enters it again and reads the actual control states. Any mismatch in entry, connection, save or read-back exits non-zero, and the pause judgment cannot continue. The fixture server is stopped during cleanup.

## Commands

Run from the candidate repository root. Replace the UDID, the built `.app`, the output directory and the two SHAs with the real values of this candidate; the output directory must be a new persistent evidence directory. The main-executable SHA is computed from the build product, not copied from the installed bundle:

```sh
APP_SOURCE_SHA="$(git rev-parse HEAD)"
BUILT_APP="<path-to-this-build-output/immichSlides.app>"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$BUILT_APP/Info.plist")"
APP_BINARY_SHA256="$(shasum -a 256 "$BUILT_APP/$APP_EXECUTABLE" | awk '{print $1}')"

python3 scripts/ipad_pause_host.py \
  --udid <iPad-Simulator-UDID> \
  --output <new-persistent-evidence-directory> \
  --app-sha "$APP_SOURCE_SHA" \
  --built-app "$BUILT_APP" \
  --binary-sha256 "$APP_BINARY_SHA256"

python3 -m unittest discover -s scripts -p test_ipad_pause_host.py
```

The script checks that Data has at least 80 GiB free and takes a lock per UDID. It does not start a build, does not download runtimes and does not clean up other tasks' artifacts. The Git check locates the repository through the script path and uses `git -C` to read HEAD and `git status --porcelain --untracked-files=all`; any tracked or non-ignored untracked change is rejected before recording, fixtures and UI actions start. The actual build command and its exit code should be saved with the run evidence; the script itself does not claim to prove the build source.

## Kept criteria and boundaries

The shuffle card and the Continue button on the mode selection page use unique, enabled accessibilityIdentifiers and are tapped at their activation point through AXe `tap --id --element-type Button --tap-style physical`. The geometric center of a SwiftUI card may return only the container, so that result cannot prove the button is not tappable. Action times are still written to the evidence; a command that fails or takes longer than 3 seconds fails immediately, and then an actionable Continue button and the playback page's Next button must actually appear. This path is allowed only for these two mode page buttons; pause, next and resume still use the original center hit check, and the timing criteria do not change.

The resume step still keeps the 14-second pause hold and the criterion that the full uncertainty interval of the first transition must fall within 10–14 seconds. The timing includes the uncertainty from sending the touch command until it returns and from screenshot capture. The button changing from a triangle to two vertical bars only proves that the resume action took effect and does not narrow the timing interval. After the transition, a different public pattern must also appear within 4 seconds and keep being recognized. Manual review of the raw recording remains part of the final visual sign-off.

Glyph recognition applies only to the central A1–A5 of the public fixtures and is verified with single photo on iPad in portrait; it cannot be generalized to recognizing real photos. Unknown or dimmed frames are used to locate the earliest transition candidate and do not prove a correct transition on their own. An early unknown frame, no different following photo, or a persistently uncertain frame all fail.

Artifacts include the fixture manifest / server health info, the real UI precondition read-back, the time of each touch, screenshots, continuously sampled PNGs, `session.mp4`, recording continuity and the result JSON. The public fixture Key is a synthetic test value, not a user credential; still check that the recording does not capture real credentials. Passing with the host method only shows that this one physical UI path runs on this Simulator. It does not equal an XCTest pass and does not cover real photos, a physical remote or all settings combinations.
