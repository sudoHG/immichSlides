# Testing conventions

Rules for adding or changing tests. Each rule can be checked on its own. When in doubt, copy the examples.

Existing tests are being migrated to these rules. Do not rewrite unrelated tests while working on something else.

**Local runner default:** script entry points run in a clean snapshot of the
current tracked working files plus untracked, non-ignored files. They ignore
ambient test/server inputs and private `Config/env.xcconfig` files or symlinks;
no link is parked, followed or copied. The tested tree SHA is printed and recorded
in `local-snapshot.json` beside output/evidence records, or an explicit
`--snapshot-record` path. `--strict-ci` refuses dirty trees;
`--allow-private-config` opts into the original checkout for local private testing.
Use `--config NAME=VALUE` for explicit runtime inputs. Run example-config setup
alone or with `--check` before starting tests. All existing runner flags remain available. This does not change
Xcode GUI/direct commands or hosted producer contracts. The full mode/command
policy is in [CONTRIBUTING](../CONTRIBUTING.md#setup).
Cancellation forwards SIGINT to the runner first so Xcode and private-bundle
finalizers can finish, then escalates if needed. A snapshot is removed only after
its child process groups exit; unverifiable cleanup retains its path for diagnosis.
The snapshot receipt records the final exit code, including cleanup failure.
`ci_ui_tests.py check-upload` only inspects results an earlier run wrote, so it keeps that run's receipt and writes none.
DerivedData remains in the original checkout or an explicit stable path, outside
the disposable snapshot. Local nightly plan, tracer and aggregate identities must
match; see [the nightly guide](CI_NIGHTLY.md).

## 0. When to write a test

Every test must guard a failure that can realistically happen again. If you cannot name that failure in one sentence, do not write the test.

Write a test when you:

- fix a logic bug: one regression test that fails before the fix and passes after it;
- add or change logic that applies rules: decisions, calculations, parsing, state transitions, persistence and migration, privacy or security guards. Cover each rule's cases once, at the smallest seam, in one parameterized test where possible;
- change a contract other code or tools rely on: file formats, decoding of server responses, persisted keys, verdicts of the privacy scanners and checks.

Do not write a test that:

- proves something is gone: a removed button, deleted code, a renamed key. When you remove a feature, delete its tests;
- tests test helpers or other test tooling, unless that tooling judges results for others, like the privacy scanners and the check scripts;
- covers a purely visual or styling change, a copy change, a refactor that keeps behavior, comments or docs. Visual changes are verified with screenshots (see `AGENTS.md`, "UI work"); refactors rely on the existing tests;
- checks what the compiler, the type system or the framework already guarantees, or pins a design value (see section 3);
- checks configuration plumbing that one real run already verifies;
- repeats a case another test already covers.

Prefer extending an existing test file. A new test file needs a reason in the pull request. The pull request states, for every new test, the failure it guards against.

A Python test that needs macOS (Swift, CoreGraphics, `xcrun` or Darwin-only tools)
must first have its full test identity added to `MACOS_PYTHON_TESTS` in
`scripts/run_host_checks.py`, in a separate PR that merges **before** the test relies
on that entry. The host partition is read from the base commit, so adding the entry
in the same PR as the test cannot move that PR's test to the macOS share. The
workflow-policy host check rejects Darwin-only skip conditions whose test identities
are missing from `MACOS_PYTHON_TESTS`.

For a UI method, assign its class or exact method to the behavior areas in
`scripts/ci-ui-areas.json`. The host audit classifies each method exactly once:
names containing `Screenshot` or `Acceptance` are screenshots; all others are
functional. PRs select functional methods by each changed path's area and proven
platform, plus smoke on selected platforms; core, unknown and CI-changing PRs
select all functional methods. The nightly runs the complete default plans,
including locale screenshots. New methods receive a conservative duration weight
and still execute. Scoped packing preserves the exact selection and bounds jobs
by `ceil(selected estimated minutes / 15)`, with base-owned matrix capacities
within five shared macOS slots; see [the UI protocol](CI_UI.md#platform-selection-and-capacity-packing).
Every Python method outside `MACOS_PYTHON_TESTS` belongs to the portable Linux
partition. Both partitions must cover the complete discovered suite without new
environment skips.

## 1. Where tests live

| Location | What goes there | Runs by default |
|---|---|---|
| `immichSlidesTests/` | Unit tests: no external network (a hermetic fixture server on loopback is allowed), no private config, no reading source files | Yes |
| `immichSlidesTests/*Live*Tests.swift` (`*LiveTests`, `*LiveIntegrationTests`, `*LiveProbeTests`) | Integration tests against a real Immich server | Skipped when no server is configured |
| `immichSlidesUITests/` | Complete user flows, for example "pick an album, then start playback" | Yes, except Evidence and strict end-to-end tests; those needing a server skip without one |
| `Evidence` test plan | Screenshot production, App Store screenshots, diagnostic captures, performance sampling | No, run on demand |
| `StrictE2E` test plans | Strict end-to-end flows against the local fixture server | No, run with `scripts/run_strict_e2e.py` |
| `TestSupport/` | Helpers shared by several tests | — |

Default-plan server-dependent UI tests can run hermetically through
[`run_fixture_ui_tests.py`](CI_FIXTURE_UI.md). That entry point uses runtime
fixture configuration and records per-test coverage; it never uses private config.
The separate [Xcode Cloud Apple TV plan](XCODE_CLOUD_UI.md) selects the same
pull-request fixture methods explicitly; a host check rejects population or
fixture-copy drift. It is an optional plan and leaves both default plans unchanged.

The [PR UI protocol](CI_UI.md#platform-selection-and-capacity-packing)
classifies every method by its method name: `Screenshot` or `Acceptance` means
screenshot; otherwise it is functional. Its host audit rejects unclassified or
ambiguous methods. Following reader-first activation, PRs run only
functional methods selected by area and proven platform; core, unknown and
CI-changing PRs run all functional methods. The nightly still runs everything.
Add each test to the appropriate area in `scripts/ci-ui-areas.json`; no test-kind
allowlist or assertion change is needed. Default test plans stay unchanged.

A test must be able to fail. Anything that only produces screenshots, logs or numbers without judging them is evidence tooling. It belongs in the `Evidence` test plan.

Unit test fixtures stay under `immichSlidesTests/Fixtures/`. The synchronized unit test target marks
`Fixtures` as an explicit resource folder and copies it into `immichSlidesTests.xctest` on both platforms.
This preserves subdirectories and PNG bytes, including the hashes checked by the pause-hold test;
individual PNG resources would otherwise go through Xcode's PNG processing. Look them up by resource
name, extension and `Fixtures/...` subdirectory with `Bundle(for:)` and a class declared in the unit
test target, never with `#filePath` or `Bundle.main`.
Require the resource URL so a missing fixture fails the test. The compiled tests must work without
the source checkout; see [Relocated unit tests](#relocated-unit-tests).

UI tests that need a server run against the one configured in optional `Config/env.xcconfig` and never change its data. `Config/Debug.xcconfig` includes that file only when present, so a fresh clone builds in Xcode without setup. EXIF diagnostic UI tests also read `IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID` from the environment or that file and skip when the key is unset or empty. Tests that start from the filter summary, including filtered playback, select the first album and the first person that server lists, so its first album must contain photos and it needs at least one person; without them these tests skip. Tests that need specific photos, such as the EXIF diagnostic album, skip when the server does not have them. The album card frame tests need an album cover whose shape differs from the card among the cards the album filter page loads, and the iOS tap test needs such a cover to reach into another card on screen; without them these tests skip.

The `Evidence` plans are `immichSlides-Evidence-iOS.xctestplan` and `immichSlides-Evidence-tvOS.xctestplan`. The default plans skip what the Evidence plans select, plus the strict end-to-end tests that run through the `StrictE2E` plans. Every UI test the default plans leave out must be selected by the Evidence plan of its platform or run by a runner suite, and a test that needs strict-runner inputs must be run by a runner suite and stay out of the Evidence plans; `scripts/test_excluded_ui_tests_have_a_runner.py` fails otherwise. Its list of known gaps is frozen: entries can be removed, never added or swapped. When you add evidence tooling, list it in both files of its platform. Test plan filters do not apply to the unit test target, so evidence unit tests are gated with `.enabled(if: isEvidenceRun)` instead; the Evidence plans set `IMMICHSLIDES_EVIDENCE=1`. To run it, choose the Evidence plan in Xcode, or pass `-testPlan immichSlides-Evidence-iOS` to `xcodebuild`.
Editing either default test plan requires maintainer approval of that exact head.

## 2. Naming

**Files and types**

- The file name matches the type name.
- Unit test suites are named `<Subject>Tests`, for example `PlaybackPoolResolverTests`.
- UI test classes are named `<Feature>UITests`, for example `AlbumFilterUITests`.
- Platform-only tests add `IOS` or `TVOS`, for example `ServerConfigFormTVOSTests`.
- Suite type names stay plain `UpperCamelCase`. Do not use raw identifiers for them, because that would shadow the type under test.

**Unit tests (Swift Testing)**

Name the function with a raw identifier: a short lowercase English sentence saying what should happen, and under what condition. Do not add a separate display name.

```swift
@Test func `empty selection cannot start filtered playback`() { … }
@Test func `startup summary rejects first image shown before slot is ready`() { … }
```

**UI tests (XCTest)**

XCTest only discovers methods starting with `test`. Use `UpperCamelCase` after the prefix, still describing behavior:

```swift
func testSwitchingServerClearsPreviousFilters() { … }
```

**Examples**

| ✅ Good | ❌ Bad | Why |
|---|---|---|
| `` `empty selection cannot start filtered playback` `` | `testFilterEmptySelectionCannotStart` | The good name states the outcome |
| `` `startup summary rejects first image shown before slot is ready` `` | `@Test("PR46 startup schema 应拒绝…")` | Ticket number, mixed languages, duplicate name |
| `testSwitchingServerClearsPreviousFilters` | `testAlbumServerN3SwitchAndImmediateDisplayPolicy` | `N3` is an internal process code |
| `` `input field meets minimum tap height` `` | `输入胶囊高度保持 46` | Pins a design value (see section 3) |

**Never use in test, file or suite names:**

- Ticket or PR numbers: `PR46`, `331-759`, `S306`, `S307`
- Phase or process words: `Phase0`, `phase3A`, `Todo11`, `N2`, `N3`, `V1`, `Journey`, `SelfCheck`, `RED`, `Golden`
- Dates, people's names, non-English text

## 3. Assertions

Polling conditions use non-failing reads and return the observation that satisfied the condition;
only the outer timeout records a failure. Read evidence-only attributes from one application snapshot
and record `notVisible` when a control is absent. Do not use `element.exists ? element.value`,
`isEnabled` or `isHittable`: the control can disappear between those live queries.
The `ui-exists-then-read` convention check enforces this in UI tests and `TestSupport`,
including helper calls such as `element.exists ? playPauseState(element) : "notVisible"`.
It matches the same receiver passed as a complete argument (optionally labeled or parenthesized),
when the true branch starts with a call, including calls nested inside it; passing another element,
a derived property or a snapshot is outside this rule.
Snapshots expose enabled state, not hittability, so pause-stage evidence uses `*_enabled` keys.

For navigation without a product response limit, create `TestWait.hangGuard()` once
before appearance/preparation and share it with nested steps. Its unscaled 60-second
monotonic deadline is never refreshed. Each `transaction()` permits one action;
`perform` refuses a second action or an action issued after the deadline.
`until` accepts a satisfied observation started before expiry even if it returns
late. An action issued before expiry permits exactly one subsequent observation,
including after expiry; an unsatisfied or failed observation cannot pass. Otherwise
no query starts after expiry. Use `probe` for optional branches: it takes one fresh
observation and never polls or sleeps. Do not create guards inside polling loops,
put waits in probes or use a full guard to choose an optional branch. The convention
checker detects direct guard creation inside `while`, `for`, `repeat`, `waitUntil`,
`.until` and `.observe` bodies, and waits/sleeps directly inside `.probe` closures.
For `waitUntil`, `.until` and `.observe`, the guard-creation check scans only trailing
closures; parenthesized closure arguments such as `readiness.until({ ... })` and
`waitUntil(timeout: limit, condition: { ... })` require manual review.
Its optional-branch rule matches only `if step.until` and `if step.transaction().until`
(including negation); `guard`, compound conditions, assigned results and indirect
helper calls still require review. Product waits and complete evidence windows retain
their existing semantics, cadence and budgets.

Filter Summary visual tests share one guard from Start Playback through their
single control-bar wake and readiness read. They open Settings through `IOSDriver`.
The one-time entry-hint check returns from the Settings root with at most one Back
action, recognizes playback independently of auto-hidden controls, then wakes
hidden controls within that same guard. EXIF diagnostic return paths and capture refresh
helpers retain their existing windows.

For iOS first-boot paths that type and save server credentials, use
`IOSFirstBootNavigation` in `UITestSupport`, including the interactive visual-audit
pack. Use `selectMode` for selection-only screenshots and `selectModeAndContinue`
to leave the mode page; both use the same observation, prompt handling and selection
checks. Fixture paths that inject configuration retain their original card tap,
Continue readiness check, single Continue tap and destination assertions, with the
original independent waits. The exception is `testSinglePhotoOutgoingPauseWindowCapture`
(strict `pause-window`): it launches with injected configuration but retains the full
helper through `StrictE2EFirstBatchIOSUITests+Onboarding.swift`, because that path
already handled the prompt before the shared observer was introduced.
Each poll first reads actual App windows. Only an unobstructed mode page with no
password-title/decline clues and both the target card and Continue live-hittable
can omit the SpringBoard and alert search before Continue is issued. After Continue,
always search for the prompt. Other surfaces, modal clues or either
blocked control still use the complete search. Each prompt's exact English/Chinese
Save Password title and unique Not Now action come from the same fallible window snapshot.
Enumerate real window elements rather than an application snapshot's children:
an application snapshot can omit the main window and change the apparent indices.
Inspect every captured window: a late credential sheet can be in a
later SpringBoard window and absent from the app's accessibility tree. Mode selection
and Continue attributes share one app window subtree. Retain the actual window
elements from that enumeration for live checks and taps within the observation;
do not enumerate them again. Multiple matching prompt windows are ambiguous and never authorize a tap.
When App windows lack the prompt, the UI-test runner's iPad idiom enables an early
fallible `app.alerts` query before SpringBoard windows: iPad can expose the remote
credential modal only there. Only an exact App prompt with a unique Not Now action
ends this observation's search early. Otherwise inspect every SpringBoard window;
keep any unrelated App alert as a modal obstacle. iPhone retains the original order:
App windows, then SpringBoard windows, then the final App alert query if no window
contains the prompt. On both idioms retain that final query for a late remote alert
that becomes queryable after the system-window observations. Each observation uses
at most two App alert queries on iPad and one on iPhone. Printed diagnostics count
`earlyAlertHits` and `terminalAlertHits` separately, counting only exact password
prompts with a unique decline action, without changing receipt sources.
Require exactly one alert, the exact password title and one decline button in
that same snapshot. Multiple alerts or a failed snapshot are unknown and cannot
authorize a tap or prove disappearance. Receipts distinguish `window-index-N`
from `alert-snapshot`. A still-present prompt needs a fresh exact snapshot and
live-hittable decline action before another decline within the same deadline.
Record a returned decline separately from a later snapshot confirming disappearance.
Public snapshots do not expose hittability: immediately before a real tap, match
both the observed identifier and label, require exactly one live match, and check
its label, frame and `isHittable`. An alert source must still contain exactly one
alert. Receipts include the live decline label. Check the same absolute deadline again.
Never equate a visible frame with hittability, decline an unrelated alert, or save
credentials. Do not capture screenshots between detecting the prompt and declining
it. Mode cards, Not Now and Continue all require live hittability; a non-hittable
card waits for a fresh observation, without a coordinate tap that can invoke
XCTest's generic interruption handler. Read selection from the unique mode card's
snapshot `isSelected` trait, rather than a generic system-symbol identifier.
Confirm the intended mode is selected and unobstructed before issuing one Continue.
`selectModeAndContinue` starts one unscaled 60-second monotonic guard before preparation.
The card, exact Not Now and Continue each have one fixed single-action child transaction;
all share the root deadline. Neither a prompt nor a returned tap refreshes it.
No target is tapped again. Every native query in the composite window/alert observer
checks admission independently. A final in-flight satisfied observation is accepted late;
an action returning after expiry gets one complete composite observation of App windows,
SpringBoard windows and alerts, using the normal prompt search. That single admitted
observation may finish after expiry but cannot authorize another observation or action.
The destination must still be explicit, mode must be absent and no captured window
may have a modal obstacle. Unknown never passes.

The returned `ModeDeparture` retains the satisfying snapshot and the same guard.
`confirms` first evaluates that immutable evidence and admits any necessary fresh snapshot
only before the root deadline. The driver's `waitForPlaybackControls` retains live
hittability, optional entry-hint dismissal and one canvas wake under that guard.
Hint dismissal and wake each have one fixed action transaction; the exact password
prompt reuses the transaction from mode navigation, so it cannot be declined again.
Failed composite observations and unexpected modals keep polling within the original
guard. AccessLifecycle's first-boot arrival confirmation also dismisses the exact
Save Password prompt under that same guard and single decline transaction.
A late hint or wake tap gets one direct live-hittability query, with no further action.
Prompt dismissal must still establish that the exact modal is gone; an expired guard
cannot authorize fresh queries for both modal absence and subsequent live hittability.
It cannot infer hittability from a visible frame.
Standalone prompt dismissal/visibility and selection-only screenshot paths retain their
existing clocks; selection-only still excludes measured card/Not Now taps.

In the old deadlines below, `t0` is entry, `tc` Continue issue, `A` pre-Continue
card/Not Now time, `C` Continue time and `B` post-Continue Not Now time.

| Caller | Previous selection / departure deadline | Current deadline | Product-timing boundary |
| --- | --- | --- | --- |
| journey-b filtered | `t0+14+A` / `tc+C+20+B` | `t0+60`, shared through summary confirmation | No product measurement; cold journey-a bypasses this helper. |
| journey-b random, pause-stage, single-photo | `t0+14+A` / `tc+C+30+B` | `t0+60`, shared through controls confirmation | Pause-window T±2 still starts at the later Play action. |
| Strict Filter, including display-policy entry | `t0+22+A` / `tc+C+28+B` | `t0+60`, shared through summary confirmation | No change to display-policy or membership assertions. |
| Late-image unarmed preparation | `t0+10+A` / `tc+C+8+B` | `t0+60`, shared through playback-entry confirmation | Settings/cache preparation only. The judged cold launch bypasses mode navigation; all held-window waits share the unscaled hold-start + 13 s deadline (15 s App timeout minus 2 s release/delivery margin), never this navigation guard. |
| Access lifecycle | `t0+22+A` / `tc+C+30+B` | `t0+60`, shared through controls confirmation | Lifecycle timing starts later and keeps its own origin. |
| `IOSDriver.launchToPlayback` | `t0+7+A` / `tc+C+30+B` | `t0+60`, shared through controls confirmation | Cache, motion, EXIF and rotation measurements remain separate. |
| Interactive visual audit | `t0+5+A` / `tc+C+8+B` | `t0+60`, shared through album-button confirmation | No product measurement. |
| Visual-audit selection-only | `t0+5+A` | Unchanged | No Continue. |

Mode diagnostics record `nativeTapSeconds`. Guarded Continue navigation does not
subtract those durations; selection-only navigation still refunds card/Not Now time.
The outer failure marker remains the target card until Continue, then
`mode-departure` / `mode.continue.button`. The issued flag is set immediately before
the native tap and tracked separately from its return. Each composite observation
and the final timeout re-mark the step and element without restarting the shared wait.
The existing failure prefixes and
[v3/v4 environment readers](CI_SUMMARY.md#prepared-hosted-strict-environment-limits)
are unchanged; fewer bounded navigation timeouts can therefore reach yellow, but
a remaining qualifying failure is still subject to the same fail-closed policy.
Mode-navigation failures append bounded observation counts/durations, snapshot match
counts and selection traits, previously queried live hittability, and closed modal
source/stage/tap-guard enums. Unknown values stay unknown. The latest observation is
retained even when the deadline rejects it; diagnostics issue no extra live queries
and do not change navigation guards, budgets or the existing failure prefixes.

For iOS slideshow Settings readiness, use one fallible window snapshot for enabled
state and a non-empty button frame fully contained in that window. This is a snapshot
readiness gate, not a claim of live hittability: the shared tap verifies the resulting
page or state. Do not query the transient button again to read hittability or tap it.
Return false at the deadline without a final condition call. The current-asset poll retains its successful
snapshot value and records snapshot failures separately from an absent probe; timeout
attachments include the failure count and last snapshot error. Its failure-message
suffix contains the count and numeric error code. Playback History also retains the
last polling snapshot's window presence, flag state and presentation phase/layer roles,
then labels its two bounded failure-time direct flag reads (window and app root)
separately, with request/return uptimes and elapsed time since the triggering action.
Only public synthetic fixture asset IDs and bounded existing hashed scene references
are printed verbatim; other nonempty IDs are redacted. Playback-entry timeout text
retains the last successful Settings poll and its playback-marker observation. A failed
snapshot leaves that observation intact and sets `lastSnapshotSucceeded=false`;
attributes are unknown only until a snapshot first succeeds. Diagnostic reads never restart the
deadline or turn a timeout into success.
The iOS control-bar tap helper takes a preparatory window snapshot, then spends
one proactive reveal immediately before a fresh target snapshot and one real
coordinate tap at that frame's centre, relative to the observed window frame. The
playback-area tap only shows the bar and restarts auto-hide; it does not hide an
already visible bar. The existing eight-second appearance budget starts before
preparation, includes the reveal and never restarts. The coordinate reuses the
snapshot frame and offset; XCTest re-resolves the window query at tap time.
The helper checks the same deadline immediately before the tap. Next/Previous/Play-Pause receive
one real tap and return immediately; their callers retain their scene-change,
Play/Pause and EXIF retry budgets. The shared helper does not compare their values.
Among the shared helper's actions, only Settings verifies an outcome: a Settings
entry or the playback toggle. Its existing five-second product appearance wait
starts when the coordinate tap returns,
so XCTest's idle wait does not consume the outcome window. This window stays fixed
under every wait factor; an observation completing after it expires never passes.
There is no control-tap retry: a call sends at most one reveal and one control tap.
Before its reveal, a fresh snapshot must show playback and contain neither the
system `BackButton` nor any `settings.*` identifier. Either navigation signal
suppresses further actions. The one returned Settings tap gets its fixed appearance
wait even if XCTest's event delivery outlasted preparation.
Wait-only Settings callers return as soon as a snapshot proves readiness within
the original deadline; they do not synthesize a redundant reveal on success.
The action helper still refreshes auto-hide before taking its tap snapshot.
Wait-only launch, EXIF capture/Next preparation and Playback History callers that
need the bar use `refreshSlideshowControlBarButton` explicitly. It spends the
step's existing timeout on one reveal and a fresh ready snapshot; neither failed
snapshots nor navigation evidence authorize a reveal. Playback History refreshes
after its back-navigation loop, including the early-ready path, before returning.
No refresh restarts a deadline or sends a second reveal.

For iOS control-bar navigation only, a Debug app launch may explicitly set
`UI_TEST_CONTROL_BAR_AUTO_HIDE_SECONDS=60`. `PlatformCompat` accepts whole seconds
from 1 through 3600; missing or invalid values retain the product's eight-second
delay. The override is not compiled into Release and does not change tvOS.
Opt in at the specific test's launch with
`SlideshowControlBarNavigationTestConfiguration.extendedAutoHideLaunchEnvironment`,
never in a shared launch default. Keep the real delay in first-wake/auto-hide
contracts, hidden-control screenshots and identity reads, visual/P2 evidence, and
pause-window/timeline captures. Settings page screenshots may opt in when the
playback bar is only used to reach Settings. Native XCTest tap delivery can outlast
eight seconds on a busy host; the override does not extend test waits, retry
actions or change product timing assertions.
The three ServerConfigForm Settings keyboard methods, the English Settings-only
acceptance captures and the four localized About captures opt in explicitly.
Their shared launch defaults stay empty. Acceptance methods that also capture
playback keep eight seconds. ServerConfigForm retains the enabled, in-window,
live-hittable Settings observation and taps its captured frame once; it does not
resolve the transient button again or send repeated canvas taps while polling.
Its existing 25/12-second readiness and eight-second Settings outcome windows,
and all keyboard response windows, are unchanged. The override cannot cover an
input stall longer than 60 seconds; a missed Settings outcome still fails.
Control-bar visibility is an input to SmartFill planning; changing it discards
prepared next. With this override, the SmartFill history round-trip test no longer
covers a wake re-showing the bar, discarding prepared next, then Next. That path
remains in the non-opted SmartFill manual-lifecycle, StrictE2E Filter and
AccessLifecycle Navigation tests.

The separate strict `pause-window` Play/Pause preparation starts its existing
4-second readiness observation after its single canvas wake returns. Native tap
delivery, including XCTest's post-event idle wait, cannot consume that observation before
the first snapshot; the wake's cost is recorded as `action_duration`/`post_event_idle`. It records
the wake as `reveal-controls` and the subsequent wait as `query-element`, both
targeting `slideshow.control.playPause.button`. Late readiness snapshots still
fail; the actual Play/Pause tap, 2-second Play readback, 4-second Pause readback in
`pausePlaybackIfNeeded` and 7-second midpoint detection retain their existing clocks
and deadlines.
Playback History Settings entry and sampling-overlay pre-Next retain their
explicit refresh assertions so their mapped failure prefixes stay available.

The strict single-photo `pause-window` case also launches with the existing
`IMMICHSLIDES_DISABLE_SMART_FILL=1` Debug override. Its initial autoplay must consume
single photos even before Settings is reached: a slow initial Pause can otherwise
retain a SmartFill scene containing A3 in the consumed history and make A2's next
candidate A4. With this override, selecting single photo in Settings has no playback
effect; this suite only proves that the control is reachable. The iPhone/iPad Release
`display-policy` suite uses no override and proves that the real Settings selection
changes playback to a stable single photo. The fast pause-window path previously
guarded release of the current scene's partner incidentally; the Next-order unit
tests in `SlideShowViewModelStartupTests+DisplayMode.swift` cover that rule and
preservation of earlier scenes' consumed assets. EXIF and five-second interval
assertions remain. This case sets no interval or auto-hide override; the outgoing
automatic fade, midpoint pause and all later image/freeze assertions keep their real
five-second product interval and existing evidence windows.

The SmartFill manual-lifecycle Pause also requires a complete stable scene and
history cursor in the control's own tap snapshot, within the same appearance
deadline. Every settled slot in the existing motion-frame summary must also expose
at least 2.5 seconds until its diagnostic handoff deadline: the measured hosted tap
latency of about 1.9 seconds plus 0.6 seconds of reserve. The diagnostic motion clock
starts 1.0 second before stable presentation, so the effective required margin
before the product's stable deadline is about 3.5 seconds. Subtract the
test process's current system uptime, rather than the render sample's time, to
account for stale snapshots. Missing or non-finite timing fields fail readiness.
A legal pause can freeze a transition indefinitely; the later stable identity
check cannot wait for that paused transition to finish. The tap gate adds no
snapshot, reveal or control-tap retry, and all post-Pause checks remain.

Both `runManualLifecycleContract` variants (SinglePhoto and SmartFill) explicitly
launch with `UI_TEST_PLAYBACK_INTERVAL_SECONDS=60` so automatic advance does not race their
manual Pause/Next/Previous/Play sequence on slow hosts. The iOS and tvOS Debug initializers
seed the saved product interval after state reset through `PlatformCompat`,
accepting whole seconds from 5 through 60; missing or invalid input leaves the
setting unchanged. Release never reads the override.
The three person-membership launches (`testFilterPersonNormalMatch`,
`testFilterPersonConflictNormal`, and `testFilterPersonNoFaces`) also explicitly
use 60 seconds. The single `tvos-person` launch also explicitly uses 60 seconds
for its membership captures; no other tvOS launch opts in. These membership
launches do not judge the autoplay interval. Their capture scope and XCTest-mode
side effects are documented in [the strict runner contract](CI_STRICT_RUNNER.md).
Other callers, including `tvos-flow`, normal five-second autoplay and pause-frame contracts, retain
their existing intervals. The motion, frozen progress, manual
navigation and current-scene resume assertions and all product windows stay unchanged.
For these two variants the 60-second interval is the primary protection;
SmartFill's 2.5-second diagnostic / roughly 3.5-second stable-time margin gate remains a backstop.

All motion reads in these two variants explicitly use
`slideshow.scenePresentation.frameSynchronized.summary`: initial and pre-Pause motion,
both frozen-progress samples, paused Next/Previous static origins and post-Play motion.
The root contract label is outside the rendering `TimelineView` and can retain a
state-change sample while the scene keeps moving. The frame-synchronized leaf uses
the same progress calculation and serializer with the renderer's current snapshot;
SmartFill still divides active time by the scene's frozen interval. Probe selection
does not change phase predicates, assertion prefixes, thresholds or product windows.
Other callers retain the root probe unless they explicitly select frame synchronization.

On rejection, this SmartFill call reports the last reason (button not ready,
scene incomplete or margin insufficient, or `none (snapshot gate passed)` when the
final observation passed the gate but no tap was issued before the deadline, for
example because the reveal used the remaining time or Settings navigation was seen),
the last observed remaining margin in seconds (or unavailable), required margin, elapsed preparation time and control timing,
and attaches the SmartFill probe labels. Its mapped `control_action/timing_window`
failure remains red and is not eligible for environment-limited classification.

If a snapshot shows playback with the control outside the window, the waiter
may reveal once within its original deadline, then only observe; a failed
snapshot never authorizes a reveal. Settings readiness failures are classified from
the caller's assertion prefix, including the `hidden_controls` class; the waiter's
text stays in the private suffix. Shared tap prefixes distinguish no tap and no
Settings outcome. Private suffixes include the last sanitized observation,
error count/code, iteration/tap counts, boolean
Settings outcome/navigation fields, aggregate snapshot/reveal/tap/verify durations
and individual reveal/tap durations in seconds.
The same diagnostic is printed on every return from readiness, refresh and action helpers, so
local XCTest activity logs can compare event latency without additional queries.
IOSDriver wake and tap paths append each measured duration to the same lists
as their aggregate timing fields.

<a id="next-and-settings-toggle-hang-guards"></a>

`IOSDriver.next` shares one unscaled 60-second monotonic guard from the baseline
photo read through one canvas wake, control preparation and one Next tap. Baseline
and readiness reads started before expiry may satisfy late; they never authorize
a tap after expiry. The baseline still uses the same screenshot identity reader.
The Next outcome retains its four-second product window from tap return and
requires a different recognized scene captured before that deadline.
The final fresh snapshot requires an enabled Next control with a nonempty frame
inside the window, the complete visible control bar and no Settings navigation
evidence. Its frame supplies the sole coordinate tap, without a live hittability
query or optional playback probe. A changed scene does not establish forward
direction. Diagnostics record the baseline capture's Unix timestamp without an
extra read. With autoplay running, the baseline can be stale by the time Next is
tapped; a swallowed tap plus an automatic advance can satisfy the scene-change
check. The guard does not distinguish those causes.

AccessLifecycle's Settings extension uses one fresh guard per requested toggle
change, spanning appearance, the initial fallible snapshot, at most one tap and
the requested-state readback. A failed or unknown value cannot prove an off state.
An already-correct initial snapshot needs no tap; a returned tap permits one final
read under the shared guard, including after expiry. The Timing extension and
`PlaybackIntervalSliderIOS` keep their existing clocks and adjustment behavior.
The autoplay check after changing display policy remains optional: one non-polling
presence probe skips an absent toggle without waiting out the guard. A present
toggle uses the same guarded initial-state read, single tap and readback.

| Caller | Previous deadline | Current deadline |
| --- | --- | --- |
| `IOSDriver.next` baseline / readiness | Entry + 4 s; measured wake refunded for readiness | Entry + 60 s, shared through Next issue; no wake refund |
| `IOSDriver.next` outcome | Earlier of entry + 8 s + measured wake and tap return + 4 s | Tap return + 4 s |
| Settings autoplay on | Appearance 12 s, then independent 4 s after any tap | Toggle entry + 60 s |
| Settings EXIF off | Appearance 8 s, then independent 4 s after any tap | Toggle entry + 60 s |
| Settings autoplay after display-policy change | Optional appearance 3 s, then 4 s after a tap | One optional presence probe; if present, initial state, tap and readback share toggle entry + 60 s |

Failure prefixes and environment readers are unchanged. Baseline and Next outcome
identity failures remain red; toggle readback failures gain no yellow eligibility.
Next readiness retains its existing hidden-controls eligibility with the longer
shared deadline, so fewer short readiness timeouts can reach yellow. Product
timing and complete evidence windows remain separate from these guards.
`IOSDriver.openSettings` now starts one 60-second monotonic guard before prompt
handling and control preparation. Exact Not Now, canvas wake and Settings
each permit one action under that same root deadline. The optional prompt branch
uses a non-polling probe. Prompt clearance completes before the sole proactive
wake; its composite modal search is not repeated inside the refreshed auto-hide
window. With no Settings navigation evidence, the wake refreshes even visible
controls, followed immediately by a fresh target snapshot, the existing complete
control-bar check and live-hittability check. No Debug-only probe is required;
unknown surfaces still cannot complete Settings navigation.
A returned Settings action permits one outcome snapshot
after expiry; only an actual Settings surface or explicitly permitted PIN entry passes.
Native wake/tap duration lists remain diagnostic and no longer extend this path.
Pause, `revealControls`, `revealUsableControls` and rotation stable-frame
deductions retain their existing clocks.

| Settings caller | Previous preparation / outcome deadline | Current deadline | Timing boundary |
| --- | --- | --- | --- |
| Cache, ReduceMotion, EXIF, Rotation, image-failure recovery and strict album capture | `t0+23+W` / `t0+23+W+C` | `t0+60`, shared through outcome | Existing cache, motion, EXIF, recovery, album and rotation windows remain unchanged. |
| AccessLifecycle with permitted PIN entry | `t0+15+W` / `t0+15+W+C` | `t0+60`, shared through outcome | Subsequent PIN behavior and lifecycle timing remain unchanged. |

The other migrated readiness hotspots use the same unscaled guard: album/person
filter entry changes from a tap followed by serial 12 + 2-second marker waits to
one 60-second preparation/action/outcome transaction; initial current-asset readiness
changes from 20 infrastructure seconds (or 8 product seconds in single-photo setup)
to 60 seconds. Explicit current-asset change/readback timeouts remain unchanged.
The two tvOS Next publication-summary waits change their 10-second readiness caps
to 60-second guards. Autoplay and resume retain their 3-second product waits after
the existing 6-second observation, rejecting observations that return after the
product deadline. Publication advancement and optional complete stable-scene predicates,
and the surrounding autoplay and screenshot measurement windows, remain identical.

The outcome field becomes true only after the wait accepts an observation within its window.
Verify time includes its snapshot time; no extra diagnostic snapshot runs after
timeout. Playback History Settings uses the explicit bounded refresh, without
the generic waiter's final condition call. Playback History
Play/Pause polls, including manual lifecycle pause/resume, read the value from one
fallible application snapshot per poll and reveal an absent control within the original deadline.
Playback History failure suffixes retain the original Pause tap issue/return and
the first state readback's request/return, independently of later polling wakes.
Next diagnostics retain its ordinal, pre-tap identity, issue/return and the last
same-snapshot manifest completeness/geometry, contract and history cursor fields.
Control diagnostics retain the single wake's issue/return and its first subsequent
snapshot of all four buttons (exists/enabled/frame/window containment), presentation
and playback marker. Each control helper starts a fresh diagnostic record, so an
action that never wakes cannot inherit a previous wake or visibility transition.
The existence-only Settings synchronization waiter starts its original existence
wait directly after wake, with no added success-path snapshot. Only a timeout
takes one diagnostic window snapshot; that sample cannot establish whether the
controls appeared and auto-hid between wake and timeout. When no wake happened,
the suffix still reports Play/Pause and playback-marker presence from the last
existing observation, or unknown if it failed. Snapshot APIs do not expose hittability, so
the suffix explicitly reports `hittable=unavailable(snapshot-api)`. Visibility is
reported as never observed, shown, or shown then absent (an auto-hide candidate);
unobserved intervals never prove the controls were never displayed. Other control
actions reuse their existing snapshots. These diagnostics add no waits or actions,
do not replace failed assertions, and do not affect the failure reader or yellow policy.

The lifecycle midpoint/Continue helpers always wake the canvas once before their
appearance wait, retaining the existing 8-second appearance and 2-second readiness
windows. They reuse one fallible snapshot's identity, enabled state, contained
frame and value for at most one coordinate tap; the 4-second state readback uses
snapshots without another wake or live control query. Pause's T-2 bound uses the
tap return before readback; Continue's T origin remains its press.

On tvOS, `refreshTVOSSlideshowControlBar` refreshes controls before dependent reads
and Select actions. The visible bar consumes Up, so the helper moves focus to an
adjacent control and back, confirming both moves. A just-disabled Previous cannot
regain focus, so that boundary refresh confirms Play/Pause instead. A visible snapshot alone does
not refresh auto-hide. If hidden, the helper waits for the wake receiver to have
focus and sends Up, within the caller's existing appearance deadline.
Callers then confirm the intended control's focus before Select. Repeat this
sequence after screenshots, scene sampling or other waits; do not reuse an earlier
visibility or focus observation. Evidence text can reuse a value already captured
in that refreshed window. Product auto-hide and one Select per action remain unchanged.
Read an initial history boundary from one fallible snapshot before slow evidence captures.
Keep cold-launch existence and focus waits fallible and bounded; either wait may wake a
focused hidden receiver, at most once across both waits. Record whether a wake was sent,
and require actual Play/Pause focus afterward. Direction drivers must still issue their
bounded press when a target cannot yet be read, and choose observed focus deterministically.
Read Previous's current enabled state before deciding whether a move is possible.
Before pausing person evidence, prove a readable frame within the original loading deadline;
Debug must bracket the same PNG with fully opaque stable scene probes. Then take one fresh
snapshot confirming Play/Pause exists and has focus, and immediately send the one Select.
If focus was lost, refresh controls, restore focus and re-prove within that same deadline.
Write evidence after Select. Classify and save the paused PNG from the same bytes, and keep
membership validation for every original capture. Consecutive Release pixel identities alone
do not prove full opacity.

1. **Every test has at least one assertion that can fail.** Screenshots may accompany assertions but never replace them.
2. **Test rules, not design values.** "Input height is at least 44 pt" and "input text is larger than placeholder text" are good tests. "Height equals 46" is not: a design change should not turn tests red.
3. **Do not assert on source text.** No reading `.swift` files and no `contains("some code")` checks. Enforce structure with the compiler, access control or a lint script.
4. **Every wait has a deadline.** Use `waitForExistence(timeout:)` or polling with a deadline. Unbounded `while` loops are forbidden. Do not use fixed `sleep` calls to wait for UI in new code.
5. **Failure messages are English and optional.** `#expect(a == b)` already prints both values. Add a message only when the expectation is not obvious.
6. **Do not change system settings in tests.** If unavoidable, do it only in the `Evidence` plan and always restore the original value. Dedicated fixture-runner preparation disables iOS Password AutoFill outside the app and UI tests; its scope, reset ordering and readback requirement are defined in [Shared simulator reset](CI_STRICT_RUNNER.md#shared-simulator-reset).
7. **Do not depend on the simulator language.** The test plans set `"language" : "zh-Hans"`, so the app under test runs in Simplified Chinese whatever the simulator uses; a UI test that needs another language passes `-AppleLanguages` itself. Unit tests run inside the app, so they compare user-visible text with `String(localized: "English key")` instead of translated text. UI tests run in a separate process that cannot read the app's string catalog: find elements by `accessibilityIdentifier`, and when a UI test must check text, check it in the language the test launches the app in. System UI (alerts such as Save Password?, permission prompts, the keyboard) follows the simulator's language, not the app's. The tests recognize English and Chinese system labels, so run them on a simulator set to English or Chinese; new code that handles system UI matches both, and dismisses Save Password? with Not Now so no test credential is stored.

SwiftUI app alerts are an exception to identifier lookup: the system renders their contents and does not
expose identifiers attached to alert buttons or message Text on iOS or tvOS. Locate the alert, its title,
message and actions by their visible text, preserving the test's language, assertions and deadlines.
Annotate these lookups with `// ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers`.

## 4. When a test may skip

Skip **only when the environment cannot run the test**:

- No test server is configured.
- The device or platform does not apply.
- Required external test data does not exist.

State the reason in one plain English sentence.

An unregistered skip fails the host checks. When adding a test that needs an expected
skip or a tier deselection, include its `scripts/ci-test-policy.json` change in the
same PR: specify the exact tier, environment and reason, plus the owning tier for
a deselection. That CI policy change requires maintainer approval of the PR's exact
head SHA; a later push requires fresh approval. New entries become effective in
the trusted verdict only after that approval. Candidate host checks read their own
policy and may pass earlier; their result is informational. Adding an entry to an
already approved file does not require resetting its whole-file approval state.
See [Static population and verdict policy](CI_POPULATION.md#expected-skips-and-tier-deselections)
for the entry formats and accounting rules.
Approval covers only the registered tier and environment. Host approval does not
authorize unit or UI exceptions; each tier requires measured identities/reasons
and its own head-SHA policy approval.

Strict end-to-end tests need the local fixture server and inputs that `scripts/run_strict_e2e.py` provides. They live in the `StrictE2E` test plans; the default and Evidence plans leave them out. Run without the runner, they fail and name the missing input, so a strict test that lands in another plan cannot hide. The runner also rejects any skipped test.

**When the behavior under test does not happen, fail. Do not skip:**

- A screen or button does not appear.
- A probe or marker is empty.
- A wait times out.
- The app is not in the expected starting state, for example it did not reach first launch.

These are exactly the problems tests exist to catch.

## 5. Size and duplication

- When a test file grows past about 800 lines, move shared steps into `TestSupport/`.
- A large suite or XCTest class can also be split into `<Type>+<Concern>.swift` extensions in its
  existing target. Keep its suite/class name, test methods, traits and platform guards unchanged so
  test-plan and runner selectors still identify the same tests.
- Python `test_*.py` modules remain discovery entry points. Moved methods live in non-discovered
  `*_test_*_cases.py` mixins and shared fixtures in `*_test_fixtures.py`; the original classes inherit
  those methods so discovered test IDs and counts stay unchanged.
  Entry points and their test-class/mixin providers must follow the
  [Python declaration grammar](CI_POPULATION.md#python-declaration-grammar);
  unsupported discovery-changing forms fail host checks with `population-invalid`.
  Use `with patch(...)` inside the method body instead of patch decorators,
  compile regexes inside functions, and use plain helper classes instead of
  decorating classes in these modules.
- Flows that are the same on iOS and tvOS live in shared helpers. Platform files contain only the differences.

## 6. Checklist before submitting

- [ ] Every new test guards a failure that can realistically happen again (section 0), and the pull request names it
- [ ] Names are English and describe behavior: raw-identifier sentences for unit tests, `test…` for UI tests, nothing from the forbidden list
- [ ] No `@Test("…")` display names
- [ ] Every test has an assertion that can fail
- [ ] No pinned design values, no source-text assertions
- [ ] Unit tests compare user-visible text with `String(localized:)`; UI tests find elements by `accessibilityIdentifier`
- [ ] Every wait has a deadline
- [ ] Skips happen only when the environment cannot run the test
- [ ] Screenshot and capture tooling lives in the `Evidence` plan
- [ ] New comments are in English

## 7. Automated check

Classify new waits with the [central test wait API](TEST_WAITS.md). Infrastructure
budgets can scale by the runner's recorded factor; product deadlines and
observation windows never scale. The same conventions entry point enforces the
per-file/function timeout-literal allowlist and rejects production factor access.

`scripts/check_test_conventions.py` enforces the rules a machine can judge, over
`immichSlidesTests/*.swift`, `immichSlidesUITests/*.swift` and `TestSupport/*.swift`:

- **forbidden-name**: ticket/PR/process codes (`PR46`, `S306`, `331-759`, `Phase0`/`phase3A`, `Todo11`,
  `N1`/`N2`/`N3` and `V1` as camelCase tokens, `Journey<Capital>`, `SelfCheck`, `Golden`/`golden`, `RED` as a
  token or `testRED` prefix) anywhere in a test function name, test type name or file name, and CJK
  characters anywhere in a test function name. A forbidden token is flagged wherever it appears in the name,
  not only as a standalone word.
- **display-name**: `@Test("…")` and `@Suite("…")` display-name strings, including when traits follow the
  string. `@Test(.enabled(if: …))` and other trait-only argument lists are fine.
- **swift-testing-name**: every Swift Testing `@Test` function must use a backtick raw-identifier sentence
  (multiple words, lowercase-starting unless the first word is a proper noun or type name — an acronym or a
  camelCase/PascalCase compound), except the two functions listed in the script's exception list.
- **source-text**: no `readProjectSource`/`projectSwiftSourceFiles`, no `String(contentsOf:`/`contentsOfFile`
  on a path ending in `.swift`, and no `#filePath`-relative read of `immichSlides/` sources. Reading fixtures
  (JSON, etc.) is unaffected.
- **unbounded-wait**: a `while` loop whose body consists only of `Task.yield()`/`Task.sleep`/`usleep`/
  `Thread.sleep`/`RunLoop.current.run(until:)` calls, with no deadline, timeout, elapsed-time or iteration
  bound in its condition or body, fails.
- **ui-label-lookup**: UI tests must not locate elements with CJK text (Han characters, kana or Hangul) in query
  subscripts, `matching(identifier:)`, or `NSPredicate` comparisons on `label`, `title` or `value`. Use the
  element's `accessibilityIdentifier`. Predicate checks include `%K` key-path arguments, including literal
  `argumentArray:` arrays, and reversed comparisons. Each comparison is checked against its own operands,
  so CJK used only in an `identifier` clause is not reported because another clause checks visible text.
  Symbolic and keyword comparison operators support modifiers such as `[c]`, `[d]` and `[cd]` in both directions.
  When a UI test intentionally checks displayed copy or interacts with system UI, put
  `// ui-label-lookup: <reason>` on the line immediately above the lookup. The reason must be nonempty,
  and the directive must be a real line comment outside block comments and multiline strings.
  SwiftUI app-alert text lookups use the exception described in section 3, with its explicit directive.

Run it with the other Python tests: `python3 -B -m unittest discover -s scripts -p 'test_*.py'`, or directly
with `python3 scripts/check_test_conventions.py`.

For the complete local host entry point, use `"${PYTHON:-python3}" -B scripts/run_host_checks.py`.
Hosted CI splits the same inventory with `--host-platform linux` and
`--host-platform macos`; runner ownership comes from the trusted base reader.
It runs these Python tests and records each discovered identity, outcome and duration
alongside the other host checks. `scripts/check_all.sh` delegates its host checks to
that entry point and uses the same interpreter for optional unit runners.
Prerequisites and interpreter setup are described in [CONTRIBUTING](../CONTRIBUTING.md#setup).
Commands and the versioned records are described in
[CI_SUMMARY.md](CI_SUMMARY.md).

Existing violations are tracked in `scripts/test_conventions_allowlist.json` by rule, file path and name (no
line numbers, so the list survives unrelated edits). The check fails on any violation not in the allowlist,
and on any allowlist entry that no longer matches a real violation — so the list can only shrink as tests are
renamed. Maintainers can regenerate it with `python3 scripts/check_test_conventions.py --write-allowlist`
after reviewing the resulting diff; this is not a way to make a real violation disappear.

## Relocated unit tests

This verifies fixture packaging as well as independence from the build-time source path. A normal
`xcodebuild test` run cannot prove relocation. Use a disposable clone of the intended commit, never
rename your working checkout. The clone must have no `Config/env.xcconfig`, including dangling
symlinks; do not copy private configuration into it. Keep the default simulator signing.

Run the following in Bash, once for each platform. Set `scheme` to `immichSlides-iOS` or
`immichSlides-tvOS`, and `destination` to an installed simulator of that platform. The scheme and
default test plan have the same name. Use a dedicated simulator and a bounded command;
check at least 80 GiB free on `/System/Volumes/Data` before each Xcode invocation.

```bash
set -euo pipefail
checkout="$PWD"
commit="$(git rev-parse HEAD)"
scheme=immichSlides-iOS
destination='platform=iOS Simulator,id=<UDID>'
relocation_root="$(mktemp -d /tmp/immichslides-relocation.XXXXXX)"
git clone --no-local "$checkout" "$relocation_root/source"
git -C "$relocation_root/source" checkout --detach "$commit"
test ! -e "$relocation_root/source/Config/env.xcconfig"
test ! -L "$relocation_root/source/Config/env.xcconfig"

df -h /System/Volumes/Data
xcodebuild build-for-testing \
    -project "$relocation_root/source/immichSlides.xcodeproj" \
    -scheme "$scheme" -testPlan "$scheme" -destination "$destination" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
    -only-testing:immichSlidesTests \
    '-skip-testing:immichSlidesTests/PlaybackRuntimeEvidenceManifestTests/externalRuntimeJSONLPassesValidator()' \
    -derivedDataPath "$relocation_root/derived"

# Preserve the complete Products directory, including its .xctestrun and symlinks.
ditto "$relocation_root/derived/Build/Products" "$relocation_root/relocated-products"
mv "$relocation_root/source" "$relocation_root/source-hidden"
mv "$relocation_root/derived" "$relocation_root/derived-hidden"
test ! -e "$relocation_root/source"
test ! -e "$relocation_root/derived"
xctestruns=("$relocation_root/relocated-products/"*.xctestrun)
test "${#xctestruns[@]}" -eq 1

df -h /System/Volumes/Data
xcodebuild test-without-building -xctestrun "${xctestruns[0]}" \
    -destination "$destination" -only-testing:immichSlidesTests \
    '-skip-testing:immichSlidesTests/PlaybackRuntimeEvidenceManifestTests/externalRuntimeJSONLPassesValidator()' \
    -resultBundlePath "$relocation_root/relocated.xcresult"
xcrun xcresulttool get test-results summary --path "$relocation_root/relocated.xcresult"
xcrun xcresulttool get test-results tests --path "$relocation_root/relocated.xcresult"
```

Both Xcode commands must exit 0. Inspect the official results: nonzero executed tests, no failures,
and the four metadata fixture tests plus the fixture-set-A pause-hold test must pass. Report skipped
tests and their reasons separately; exit 0 alone does not prove all tests ran. After reading the
results and confirming no process uses the disposable directory, delete `relocation_root`, including
the clone, products, DerivedData and result bundle. The original checkout is untouched throughout.

## Running controlled integration and end-to-end tests

Strict end-to-end tests run the real app against a local public fixture server started by `scripts/run_strict_e2e.py`. They do not access a personal Immich server or need real credentials. Run the Python contract tests separately from the app tests:

```bash
python3 -B -m unittest discover -s scripts -p 'test_*.py'
```

App runs need macOS, a selected Xcode installation and the platform's installed Simulator runtime. Python prerequisites and interpreter setup are described in [CONTRIBUTING](../CONTRIBUTING.md#setup). Before any build, check `df -h /System/Volumes/Data`; the runners require at least 80 GiB available by default. Use `--min-free-gib N` with a non-negative integer to change this local safety threshold, and install any required Simulator runtime through Xcode. Pick a local simulator UDID with `xcrun simctl list devices available`.

```bash
python3 scripts/run_strict_e2e.py --platform ios --destination 'platform=iOS Simulator,id=<UDID>' --suite journey-a --evidence-dir '<outside-repo>/first-connection'
python3 scripts/run_strict_e2e.py --platform ios --destination 'platform=iOS Simulator,id=<UDID>' --suite firstboot-failure --scenario auth-401 --evidence-dir '<outside-repo>/connection-failure'
python3 scripts/run_strict_e2e.py --platform tvos --destination 'platform=tvOS Simulator,id=<UDID>' --suite tvos-n1-cold --evidence-dir '<outside-repo>/tv-connection'
```

Use `python3 scripts/run_strict_e2e.py --help` for the current suite list. Settings, pause/resume and background-return flows use `ios-lifecycle-settings`, `ios-lifecycle-pause` and `ios-lifecycle-background`, or the same names with a `tvos` prefix. The iOS first-wake flow uses `ios-lifecycle-first-wake`; an iPad pause run uses `ios-lifecycle-pause` with an iPad UDID.

The iPhone/iPad pause timing flow calibrates the visible Settings glyph and its normalized
button rectangle before Next and Continue timing. Dense Next/Continue capture loops record
only screenshot bytes and request/return times; they perform no accessibility queries or
image classification between captures. Deferred classification derives control-bar visibility
from each original frame by matching the calibrated glyph. The existing 5% sustained-dimming
threshold prevents control-bar disappearance from being mistaken for photo dimming. Calibration
also requires Settings to remain hittable after its screenshot, before timing starts.
This pixel reader is limited to the controlled fixture flow and stable screen
geometry. The screenshot gap, ordering, Continue origin and transition/stability contracts
remain unchanged. The tvOS continuation watch uses the same calibrated pixel reader.

On iOS, `PlaybackIntervalSliderIOS` drives the real interval slider for both
`IOSDriver` and the lifecycle flows. It reads only `settings.playback.interval.value`.
Interior adjustments correct the last requested normalized position by
`(targetSeconds - displayedSeconds) / 25`, with at most five adjustments in total;
only endpoints use a thumb-start drag past the track end. The settings-persistence
flow requires a displayed interval different from its initial value and preserves
that same value across restart, without requiring an exact interior target.
The iOS pause/background lifecycle flows request 12 seconds and require displayed T in
the inclusive 10–15 second window, enabled explicitly at the timing-contract call.
Other callers retain exact requested values. T/2 is therefore at least 5 seconds
and T−2 at least 8 seconds, while the upper bound limits run time. Every timing
assertion uses that displayed T; T±2 tolerances, capture deadlines relative to T,
hidden-control and visible-scene checks stay unchanged. First-wake requires exactly
30 seconds, and `IOSDriver` continues to require its exact 15/30 second settings.
Unreadable values and values outside the timing window fail.

The tvOS lifecycle timing flows request 10 seconds, an offered value in
`SettingsViewTV.intervalOptions` and different from the initial 5-second setting.
Settings persistence uses that same request, or 15 seconds if the initial value
is already 10 seconds, so all four settings still change. Timing receipts record
the requested and actual interval separately. A genuinely unavailable request
still falls back to the nearest offered interval and requires desktop closeout;
an exact offered request does not require interval review. All timing assertions
continue to use actual T with the existing T±2 and four-second confirmation rules.

Pause/continue timing distinguishes transition onset from stable new-photo confirmation.
The additional Debug suites `ios-lifecycle-pause-timeline` (iPhone and iPad) and
`tvos-lifecycle-pause-timeline` use the App's own monotonic DEBUG timeline instead
of the screenshot timing algorithm below. The existing Release lifecycle suites
retain that algorithm and their complete functional coverage unchanged.

For the Debug suites, the T origin is **App received Continue**, rather than the
runner issuing the Continue press. The receipt, the first committed display tick
showing the old photo dimming, and the complete new photo's stable display tick
all use `ProcessInfo.systemUptime`. The onset must remain in T±2 seconds, and the
new photo must be stable within onset + 4 seconds on iPhone, iPad and tvOS.
Runner tap issue/return and App receipt are retained separately as diagnostics.
Stable means opacity exactly 1, the prerender barrier ready and every photo slot
decoded; planning, download completion and a scheduled timer are insufficient.

`PlaybackLifecycleTimeline` is enabled only through `PlatformCompat` in DEBUG.
The XCTest process supplies `UI_TEST_EVIDENCE_DIR` and a per-case nonce; the App
appends a separate `playback-lifecycle-timeline.jsonl`, with a per-launch nonce
and contiguous sequence numbers. It uses neither the capped sequence recorder,
container reads nor accessibility transport. A file request/response handshake
in the real XCTest runner brackets an App uptime sample with runner uptime
samples before the clocks are compared. Its bracket width affects screenshot
attribution uncertainty only; it supplies no timing tolerance or deadline extension.
Checkpoints seal complete event prefixes;
partial trailing JSONL lines are never evidence. Missing events, nonce changes,
sequence gaps and missing checkpoints fail. The host reader binds the official
Swift judge receipt to the event prefix and each original content PNG by SHA-256;
it does not implement another timing judge. Existing summaries and Release
signatures remain readable, and new timeline failures cannot become yellow.

`LifecycleTimelineJudge` is a pure function shared by unit and UI tests. Pause
holds must not fade or commit another frame. A manual navigation receipt while
paused permits one manual transition to one new target, with exactly one commit,
ending only at that target's `sceneStable(isPaused)`. Target/source provenance
rejects automatic changes and a second target inside that window.
The exact reducer branches for `fadeInNextPhotoIfPausedInFadeGap`, the short
manual-hold raise and `beginPausedManualCrossfadeIfHeld` are explicit exceptions.
The raise names the layer marked `isRaisedForHold`, rather than `currentTarget`.
A held manual target may crossfade after Pause once ready, including after the
raised photo settles; its identity must match the pending hold captured at Pause
or the current paused manual navigation. Each permitted transition then freezes
(see the manual-hold
[ADR](decisions/ADR-2026-09-30-hold-the-current-photo-until-a-manual-target-is-ready.md)
and [architecture glossary](ARCHITECTURE.md#5-glossary)). The observer records
these exceptions without modifying playback state, timers or animation.
Automatic fades through black and the accepted approximately 0.2-second startup
black remain intentional; this change introduces no black-duration threshold.
Stable black images, wrong photos and missing conclusive content still fail.

Every screenshot records the runner's full [request, return] uptime interval.
Its content is judged only when that entire interval belongs to one stable photo
or frozen frame in the App timeline; a boundary-crossing interval is inconclusive.
Each proof point still requires a conclusive content check, otherwise it fails as
missing evidence. Screenshot duration itself has no 1.001-second precision gate
in these Debug cases. Screenshots independently identify public fixture pixels;
the App's asset hashes only cross-check that identity, never supply it.
The held-photo proof also compares exact decoded pixels before and after T+2 in
the central photo band (10–90% of width, 30–60% of height), excluding the separately
animated top EXIF and bottom control overlays. It applies no pixel tolerance.

Local App-only SIGSTOP verification starts the paused App's 24-second STOP **before
Continue control preparation**; the STOP may overlap preparation queries or remote
presses. The origin is App receipt by construction of the judge and its timing
mutations. The STOP runs show that pre-action delays do not consume that window;
they do not prove tolerance of 24-second
native tap delivery. A tap delivered after the eight-second control auto-hide can
only wake the controls and fail for missing `continueReceived`. That navigation
residual is outside this timing contract; do not retry the tap or extend auto-hide.
To inject once, create `playback-lifecycle-inject-stop` in the run's evidence
directory. The XCTest process writes `playback-lifecycle-before-continue` while
paused, then waits for `playback-lifecycle-stop-armed`; the host stops the exact
device's App PID, writes the armed file, waits 24 seconds and sends SIGCONT.

The Debug observer caches launch configuration and scene/asset hashes. A directory
change notification refreshes the cached request only when its modification date
changes; committed ticks consume that cache without reading files. Body evaluation
compares numeric layer samples, with fingerprint SHA-256 computed only for emitted
events. JSONL appends and request-change reads still add Debug-only scheduling cost.

iPhone, iPad and tvOS share the sustained-dimming predicate and constants in
`AccessLifecycleContract`: a bright MATCH anchor must identify the old photo at
or above 95% of baseline, followed by a contiguous run of at least two dim MATCH
samples identifying that photo below 95%. A strict decrease greater than the
existing luminance tolerance must occur between adjacent dim samples. Before that
decrease, at most one frozen dim frame is allowed, equal to the preceding dim
frame within the tolerance; a rise beyond the tolerance rejects the candidate.
Only when a frozen frame occurred must the span from the bright anchor's request
to the decreasing frame's request fit the designed 1.0-second outgoing fade, plus
timing tolerance. The plain bright-anchor-plus-two-decreasing-dims shape has no
span cap, preserving its previous behavior at slow capture cadences. The first
dim sample supplies the onset request time. A vetoed candidate can push onset
later, potentially to the first identified new photo. The frozen-frame remedy
requires three capture intervals totaling at most 1.0 s plus tolerance (about
0.334 s on average); at 4K it often cannot apply. These bounds are not conservative
for early fades: rejecting their dimming evidence can hide an early start behind
a later new photo, or reject an in-window start as late. The control-bar state must
remain unchanged from the anchor through that decrease, with every gap between a
frame's recorded `returned` time and the next request no greater than the existing
0.1-second poll cadence plus its tolerance. Pinned 4K TV capture measured
0.309-second median and 0.453-second maximum request cadence: requiring three
already-dim MATCH frames can outlast the identifiable portion of the designed
1.0-second outgoing fade. That original predicate retains at least three observations
without counting black or unrecognized frames as fade evidence. An isolated black
frame, a constant whole-screen dim or a dimming sequence that recovers the old
photo's brightness through the shared 0.8-second new-photo stable-window confirmation
cannot establish a dimming start on any platform. This recovery-veto cutoff also
applies to iPad, whose own stable-photo requirement is one second. The shared
predicate vetoes that recovery, including iPad's two-dim-frame flicker case.
The tvOS Continue collector captures full-resolution screenshots from
`XCUIScreen.main` without an application lookup. It retains dense capture through
the original absolute deadline and classifies photo identity afterwards. A local
adapter first confirms visible controls, then probes only from T−2 until the
single wake or its deadline; it does not tax every earlier capture. Before reading
those full PNGs, it crops the calibrated Settings rectangle from that screenshot's
CGImage and feeds the lossless crop to the unchanged control-bar reader.
Calibration uses the same rectangle and reader thresholds.
The current crop result is consumed immediately; it cannot wait behind the next
full screenshot as the former asynchronous PNG probe did. Offline classification
still uses the original full PNG. The diagnostic records each crop probe's frame
index, visibility, request and return for comparison with the original reader's
sample and for measurement of the capture-path cost. Crop probing occurs between
`captured` and `returned`, so its cost counts in that frame's span rather than in
the 0.101-second gap. Locally it took a median 45.751 ms and maximum 48.134 ms,
only on initial visibility confirmation (frame 0 in these runs) and in the wake
window; hosted probe cost is unmeasured. This added span cannot itself create a
T±2 false pass: it can only admit decline chains after T−2, or at initial
confirmation, where an admitted chain can only make the onset earlier.

A missing crop result cannot prove auto-hide. After observing visible controls
followed by auto-hide, it sends at most one Up, only when its request falls in
[T−2, T−0.8], to restore the original visible control state. Window gating
guarantees the T−2 lower bound; an earlier auto-hide no longer causes a runtime
failure. Host configuration checks instead pin the product auto-hide delay at
8 seconds and this flow's requested interval at 10 seconds, so changing either
still fails checks. After T−0.8, the wake is skipped and capture continues
unchanged. A skipped wake returns to main's hidden-state comparison:
hidden-state frames are compared with the visible-state baseline, so the effect direction depends on the unmeasured
luminance difference between those states. It can delay or lose the onset
(a loosening direction for the four-second rule) or reject a bright anchor (a
false failure). A screenshot or crop read that returns after T−0.8 still skips
the wake; eliminating the extra asynchronous frame does not guarantee a timely
observation on every host. In hosted run 40134453780 the first hidden frame
returned at 9.414 seconds, already beyond the 9.2-second wake deadline and
unrescuable by this change. In run 40102889537 it returned at 9.111 seconds,
leaving about 89 ms for the total probe delay accumulated in the wake window
before that frame's decision, including probes of earlier in-window frames
(one probe took about 46–48 ms locally). Hosted
summaries omit `control_bar_probes`; their probe cost has not been measured.
This is not evidence that the six-of-seven nightly failure is fixed.

The `skipped` flag is also set when the deadline passes without any observed
auto-hide, so it does not distinguish "too late" from "not needed". Continue resets
the App's `PlaybackViewMetrics.controlBarAutoHideDelaySeconds` timer; the pinned
8 seconds equals T−2 for this flow's pinned T=10 seconds.
Up does not toggle playback or reset the Continue origin: control visibility triggers
`updateFutureProtectionSnapshot`, which can discard the prepared next scene,
invalidate a pending transition and re-plan it. This can delay a switch and cause
a false failure. Before the wake deadline was added, the final asynchronous-probe
commit's three Up returns were 9.216327, 9.478780 and 9.086156 seconds. Adding the
0.3-second bar animation to the latest return ends at 9.778780 seconds, about
6 ms after the measured 9.773-second earliest fade. The 0.8-second lead now leaves
26 ms before T−0.25, the earliest fade measured in one trace (9.773 seconds,
rounded), after the measured maximum 0.224-second press gap plus 0.3-second
animation (0.8−0.224−0.3−0.25). T−0.25 is a single observed value, not a
contractual lower bound: the contract accepts fades from T−2, and this allowance
does not guarantee that a contract-valid fade is never interrupted by the wake,
nor that a same-state bright anchor is captured before luminance falls below 95%.
It is a measured allowance, not a bound on future press latency.
Up itself blocks capture for 0.218–0.224 seconds, exceeding the unchanged
0.101-second gap guard. A dimming chain spanning that gap or a control-state
change cannot sign onset. Missing an early onset can defer it to a TRANSITION or
new-photo frame, shortening the measured onset-to-stable delay: this is a
loosening direction for the four-second rule, and can also hide an early fade.
Re-planning delays the physical switch; the gap can delay its detection. A fresh
same-state bright anchor remains mandatory after the wake; the original predicate's
luminance comparisons retain the original baseline. The tvOS rescue described
below is an explicit exception, using a local photo anchor.
`continue-watch-diagnostic.json` saves every frame's
request/capture/return times and the wake times or skipped flag, including on
assertion failure. Identity, luminance and control-state `samples` stop at the
first stable new photo; later captured frames retain timestamps and decoded-photo
q95, white-core coverage and same-image mean metrics.
A transition identity or a different identified photo remains direct onset
evidence; tvOS also vetoes a TRANSITION marker when the old photo recovers through
the same shared confirmation cutoff. iPad still applies conservative screenshot bounds
and requires one second of stable new-photo identification.

The iPhone and tvOS T±2 check uses the detected onset's screenshot-request offset, independently
of when the new photo becomes readable.
Unlike iPad's conservative bounds, this request time can differ from the actual
onset in either direction by about one capture duration (up to roughly 0.45 s in
the measured 4K trace), with sampling delay also contributing when it lags onset.
A lag can accept an early fade just before T−2 or reject an in-window fade near
T+2 as late. If fading begins after the request but before the image is read,
the request leads onset: a late fade just after T+2 can pass, or an in-window
fade near T−2 can be rejected as early.
A different public photo must then remain identified and bright for the shared
0.8-second stable confirmation window; no new
photo means failure. Dense capture continues through the shared T+2+4-second
look-ahead, before classification, so a designed fade beginning inside T±2 can pass
when the new photo becomes stable after T+2. Like iPad, iPhone and tvOS require stable-photo
confirmation to return within four seconds of the onset request, using the same
deadline check and constant. This deadline has a known false-failure risk at 4K:
the three Release runs before the wake deadline was added left only
84.561–462.077 ms of stability margin, and the three runs with the deadline left
167.933–433.008 ms. The 377.516 ms spread is about 1.5 median capture cadences.
An earlier, more accurate onset or a later stable-photo return from capture
jitter can exhaust that margin; a missed early onset instead
shortens the measured delay. Wake-triggered re-planning can delay the switch and
violate T±2, without necessarily increasing its onset-to-stable delay. The bound
and verdict stay unchanged; a later sampling failure is not a pass.
Every screenshot requested before T−2 (including the
existing timing tolerance) must still identify the old photo: black, blank,
unrecognizable, transition and different-photo frames fail, even if they recover.
Detected starts before T−2 or after T+2 also fail. Evidence records the onset,
stable new photo and request/return/classification
times separately, retaining the matching cached PNGs. Pause-hold equality and the
first-half-window old-photo check are unchanged.
iPhone retains `pending_video_review` (H) when an in-window change cannot establish
an onset, even if a new photo is later confirmed. Sustained dimming can be signed
only with the new photo confirmed within the shared four-second bound; it does
not turn an isolated black frame or uniform dim into a start. The iPhone receipt
records the start-to-stable return delay and retains cached dense PNGs requested
from T−2 through confirmation as `continue-transition-<sample index>.png`, alongside
the sample request/return/classification times. These exports happen after dense
capture and use the existing public fixture evidence path.

The tvOS A1 photo rescue is a maintainer-approved validator loosening:
it expands its PASS set and changes the #555 ruling:
one dim old-photo MATCH followed by a decoded, strictly decreasing MATCH or
UNRECOGNIZABLE photo measurement may establish a bounded fade interval. It does
not reclassify UNRECOGNIZABLE as MATCH. The shared sustained-dimming predicate,
iPhone and iPad entries remain unchanged. The rescue runs only after the original
tvOS judge throws the typed late-window error. The public tvOS entry converts
outgoing late errors to the legacy `message(...)` wrapper so XCTest text retains
the existing `continue_timing/timing_window` classification. Every original PASS retains
exactly its original onset, window and four-second computation; early, invalid,
missing-stable-photo and four-second failures cannot be rescued.

The tvOS call site supplies named A1 thresholds and enables rescue only from the
singlePhoto option's actual selected-state readback. Its offline helper decodes
each original 3840x2160 PNG, computes photo q95 from the fixed top-left 72% by 78%
region, and derives the original reader's mean from that same decoded image.
The means must agree exactly. Missing metrics, decode failures, `unreadable` or
`undrawn` notes break the chain; zero is never substituted for missing evidence.
All earlier same-A1, same-control-state frames through the anchor must have q95
equal to the calibration maximum, including a first-half observation. An anchor
requires q95=255 and at least 6% white-core coverage: RGB channels >=254 remain
white after erosion by 2% of the original screen dimensions on each axis.
The current single-photo policy scales about the centre without translation;
the unit contract bounds two seconds of motion by 1% per axis, with an additional
1% sampling margin. A geometry-policy change must invalidate that unit bound.

The first dim still requires an A1 MATCH, a q95 drop of at least three channel
units and a mean drop exceeding the existing 0.001 tolerance. At most one prior
quantized old-image frame is allowed: q95 has fallen by one or two units and
mean has not risen. Subsequent outgoing observations must decrease in mean by
more than 0.001 and in q95 by at least one unit, with unchanged controls and
the original 0.101-second return-to-request gap. A later decoded MATCH or
UNRECOGNIZABLE proof must lose at least 0.030 mean luma from the local anchor
and have q95 below 95% of 255. The 0.030 guard exceeds the measured short-span,
same-state motion/control variation; the independent q95 and white-core checks
distinguish photo attenuation from changing colour areas. The request span is
at most 1.001 seconds and the anchor-request to proof-return span at most
2.001 seconds. Original recovery vetoes remain, and reappearing A1 identity
after loss of recognition, or bright/rising old-photo q95 after proof, vetoes
the rescue through the shared stable-photo cutoff. Incoming unrecognized
brightness may rise after proof; it never supplies the outgoing decline.

The entire interval [anchor request, proof return] must lie within T±2 using
the iPad-style 0.001-second boundary tolerance. Stable-new-photo confirmation
must return within the unchanged four seconds, measured from the interval's
lower bound. The interval deliberately includes the later proof rather than
backdating a small dip from its first dim return. It can reject otherwise valid
late-window fades or sparse captures. q95=255 still has roughly one channel
tick of quantization slack (about 4 ms in the reviewed fade model), plus a
rendering tick; this is not a guaranteed physical-onset enclosure.

Known residual: non-App full-screen dimming near T+2 that persists into a later
real fade could still satisfy the rescue. The singlePhoto App path has no such
overlay, but this pixel-only rule does not prove the absence of system overlays.
The diagnostic records optional q95, white-core fraction and same-image mean
for every captured frame, plus the mode readback and rescue interval. A rescue
retains its anchor/dim/proof PNGs. Existing `detected` / `official_signed` receipt
semantics are retained, and outgoing failures preserve the legacy error wrapper
and message prefixes used by CI classification; the interval is an additive field.

Continue issued is zero, aligning tvOS with iOS `press.issued`; the remote Select
return time is recorded separately and never becomes the screenshot-request
clock's origin. This intentionally replaces tvOS's former Select-return origin.

The combined access-protection flow requests 12 seconds and narrows its window to
12–15 seconds. Its lower bound is rounded up from the product's 8-second control
auto-hide delay, the existing 0.6-second hidden-control stability requirement and
the 2.5-second wake-evidence budget. Slider adjustment and validation use that same
window, and the validated displayed T becomes the wake interval. Its 9-second
control-hide wait remains capped by the remaining interval minus the evidence
budget; autoplay checks before hiding and before the wake frame remain unchanged.
Background, PIN, pause/Next/Play, hidden-control and visible-scene assertions are
unchanged. The combined runner uses Debug, where the measured-progress probes exist.

`image-failure-recovery` runs only `ScenePresentationContractUITests/testIOSImageFailureRecovery` on iOS in single-photo mode with a 30-second interval, using fixture A and case ID `image-failure-recovery`. Through normal app controls and the fixture-only `/api/test/image-response` endpoint, every fullsize thumbnail request for the startup photo returns HTTP 503 until the mode is reset. The flow turns on the EXIF overlay and fails if that photo's `Fixture 1` caption is visible while it waits for the first stable photo or within 5 seconds after it; this independent caption guard remains alongside pixel identity. Otherwise the flow verifies the visible replacement, Previous/Redo history and continued playback. The endpoint does not change metadata, other assets, preview responses or the frozen fixture. Result bundles use the existing private export/disposal path. This flow requires the strict runner and is excluded from the default and Evidence plans.

`p2-cache-smoke` on iPad pauses on a recognized single photo with a 30-second interval, then requires both cache completion and a recognized public photo in `cache-returned.png` after returning to playback; as with `p2-cache`, a signed review must list that same photo. It retains its smoke designation and does not claim the full P2 disk-usage review.

`p2-ipad-layout` checks the multi-photo identity of each frame used by its stable
pair, instead of taking a separate scene-check screenshot before the saved frame.
Control readiness, orientation, the 10-second observation allowance, the 0.5-second pair spacing
and the pixel-difference limit remain unchanged. Thrown failures are recorded
before app termination. Stable-frame diagnostics separate control preparation,
screenshot capture and pixel analysis without additional UI reads. IOSDriver Next
uses the [shared readiness guard and separate product outcome window](#next-and-settings-toggle-hang-guards);
that section also defines its snapshot geometry, baseline capture diagnostics and
autoplay limitation.

Rotation captures first use the existing control-readiness check, with no extra
canvas tap in the steady state. If that check fails, the capture refreshes the bar
once and checks readiness once more, starting the second check after the wake
returns with a freshly reset auto-hide timer. This does not guarantee that the
timer cannot expire during a slow native interaction. Both checks and the refresh
run inside an iteration the existing stable-frame loop admits; like the existing
check, they are not cut off at its deadline. Only the measured native helper-wake
and explicit-refresh tap durations are excluded from the enclosing stable-frame
allowance; queries, polling, screenshot capture and pixel analysis remain charged.
The driver reports its measured wakes directly, independently of receipt enablement,
without a UI query. Every deduction appears in `deductedTapSeconds` and
`totalDeductedTapSeconds` in capture logs and failure details. The inner driver's
3-second readiness checks retain their original deadlines. Playback-rotation logs still
measure all elapsed time, including every tap, against the 30-second natural-switch
bound; the original start timestamp and bound are unchanged.
Every saved candidate still requires all three controls to be
hittable, the requested orientation and public photo identity, and the stable
frame pair. Other stable-frame callers report no tap deductions and retain their deadlines.
Failures retain the `visible_scene_capture` / `timing_window` or rotation-capture
classification; this does not introduce yellow eligibility.

Let `t0` be capture entry, `tr` rotation issue and `R` the sum of that capture's
returned helper-wake/refresh tap durations. The shared stable-frame callers are:

| Caller | Old stable deadline | New stable deadline | Product boundary |
| --- | --- | --- | --- |
| iPad multi-photo layout: landscape and portrait `captureStable` | `t0+10` | `t0+10+R` | Orientation setup and multi-photo selection precede capture. No 30-second outer bound; only the 600 s warm / 1200 s cold invocation caps apply. |
| Playback rotation: initial portrait `captureStable` | `t0+10` | `t0+10+R` | The whole sequence remains strictly below 30 seconds from the original Next request. |
| Playback rotation: landscape and final portrait `captureStable` | `tr+10` | `tr+10+R` | Window settling and stable observation still share 10 active seconds; every wall-clock second also consumes the unchanged 30-second bound. |
| Orientation self-check: direct `StableFrame.wait` | `tr+10` | `tr+10` | No deduction callback. |
| ReduceMotion segments: direct `StableFrame.wait` | `t0+10` | `t0+10` | No deduction callback; recording holds are unchanged. |

These exclusions can absorb about 60 seconds of App non-idleness inside each
XCTest tap when the outcome later arrives within the remaining allowance. This is
not proof that the time was outside the App's responsibility. Each `StableFrame`
iteration can deduct up to three native taps: the first driver wake, explicit
refresh and second driver wake. The inner 3-second readiness check is not extended;
long taps can therefore leave readiness false while extending the outer capture
deadline. Only non-tap work bounds the iteration count, so the original wall-clock
deadline can be exceeded across several iterations rather than just one admitted
iteration. No cap is added. The playback-rotation 30-second bound still rejects
an overlong completed sequence, but `p2-ipad-layout` has no such outer bound.
In the extreme, its capture can reach the 600 s warm / 1200 s cold invocation cap
and lose the `first_failure` receipt; an invocation timeout or missing receipt
still stays red.
See the [environment-limit contract](CI_SUMMARY.md#prepared-hosted-strict-environment-limits)
for the Settings receipt eligibility change and unchanged red rotation failures.

Run serially within a checkout because the runner manages temporary test configuration. Use a new evidence directory outside the repository for each run. The runner prepares the fixture and app state, reads official test statistics, checks result contracts and cleans up. Zero selected tests, skipped strict tests, missing evidence or an unknown image are failures. A successful contract check does not replace human visual review; inspect the current run's original screenshots. The separate [iPad host tool](../scripts/ipad-pause-host-testing.md) remains diagnostic tooling and does not replace an XCTest result.

For explicit shard warm-up, build reuse, cold/warm budgets, full simulator resets and
the informational CI tracer, see [Strict runner warm-build tracer](CI_STRICT_RUNNER.md).
Local preparation now completes a bounded simulator boot before starting the app-reset
clock: the boot command has 60 seconds, boot and bootstatus share 600 seconds, and
app/keychain/privacy reset then has 120 seconds with individual commands capped at
60 seconds. Official tests and summary exports each have 60 seconds. These bounds
also apply to fixture UI, listed retries and access-lifecycle runners through the
shared reset/export helpers. Preparation/export timeouts retain failed records and
private quarantine; xcodebuild test-execution timeouts remain case failures.
Versioned nightly shards, exclusions and aggregate rules are documented in
[Skeleton nightly](CI_NIGHTLY.md).

### Known-flaky registry and listed-only retries

`scripts/ci-known-flaky.json` is the authoritative registry. Each entry names one
exact XCTest method and platform (UI) or device/configuration/suite/scenario/fixture
tuple (strict), its tier/environment scope, the shared per-identity tracking issue,
owner, added date, review-by date, symptom and evidence. Wildcards and unit/Python
entries are rejected. Use the same issue when the nightly reporter is introduced;
do not open a second issue for the same identity.

The host gate runs `python3 -B scripts/ci_flaky.py`. It checks the candidate file's
format, duplicates and static test existence on the relevant platform, including
strict-suite membership. It does not contact GitHub or gate on calendar age/issue
state. [CI reporting](CI_REPORT.md) checks expiration and issue state without changing the test verdict. A review date is
inclusive; an entry past that date simply loses retry eligibility. Ordinary passes
stay passes and expiration cannot fail unrelated tests.

PR consumers read the registry from the checked-out merge commit's first parent.
An absent base registry means an empty list, including during initial rollout.
The PR's candidate entries cannot excuse its own failures. CI cannot override the
registry revision. Main push/dispatch/schedule consumers use their tested main revision;
local runs use `HEAD`, with an explicit local `--registry-ref <commit>` available
for isolated acceptance probes. Both the revision and exact policy hash are kept.
Trusted verdict callers supplying `base_registry` must also supply `evaluated_on`
as the trusted producer run's calendar date, rather than the later verdict date.
`ci_verdict` rejects a missing date; producer-provided entries do not select that policy.

Only an official first-call assertion failure (Xcode exit 65) with an exact active
entry may obtain one retry. Official typed failure summaries must classify every
failure for that method as `Assertion Failure`. When Xcode emits `Uncategorized`,
official per-test details must instead identify each failure by XCTest's assertion
message prefix and a positive source line. Crash/unknown messages, missing details
and infrastructure errors are ineligible. The executor resets the app, keychain and simulator
privacy state, then calls `test-without-building` with only the failed method.
Global retry/repetition/iteration flags are rejected. Both calls, official exports,
exit codes, durations and per-test attempts remain recorded. Failed then passed is
`flaky-passed`, which is distinct from an explicit pass; the reporter must not
count it toward closing the issue. A second failure, skip, crash, timeout, missing
or wrong/extra result stays failed. Unlisted failures never receive a second call.

For a built UI target on a dedicated simulator, with a secret-free checkout:

```bash
python3 -B scripts/ci_flaky.py --xctestrun '<Products>/tests.xctestrun' \
  --platform ios --destination 'platform=iOS Simulator,id=<UDID>' \
  --only-testing immichSlidesUITests/ExampleUITests \
  --output-dir '<fresh-outside-repo>/ui-attempts'
```

The UI adapter enumerates the selected compiled tests and compares them with
observations. Each test invocation and the enumeration use `--min-free-gib N`
(default 80). Only GitHub-hosted Actions runners may lower that threshold; their
consumer command can pass `--min-free-gib 30`, using the shared archive disk guard.
Its local declared list is that compiled selection; the [UI producer](CI_UI.md)
independently compares its manifest shards against the admitted static population.
This adapter does not implement shard assignment, fixture selection or trusted
publication. Pass fixture inputs explicitly through the per-run xctestrun; ambient
server inputs are stripped. Each invocation gets an independent private directory
so every raw bundle can be exported/disposed before its directory is removed;
only compact records are suitable for the trusted summary consumer.
The adapter uses `-collect-test-diagnostics never` to keep failed invocations
bounded without simulator diagnostic collection. Execution errors and timeouts
retain all attempted calls in `retry-invocations.json`; a retry timeout records a
second `timed-out` attempt and returns failure.

Strict warm runs opt in with `--listed-retry-device iphone`, `ipad` or `tv`, together
with `--test-without-building`. This preserves the existing cold/default runner and
informational tracer behavior. It uses the same executor and retains per-session
attempt exports, including `filter-person`. `retry-invocations.json` has a `sessions`
map keyed by Xcode log stem, so later sessions retain earlier retries. Every warm
attempt writes `<stem>-reuse.json` with duration, exit code, timeout budget and
Products immutability; a first attempt's receipt moves with its archived outputs.
Recording suites (P2 cases with `video=True`, `filter-switch` and
`tvos-switch`) are refused by registry validation and the retry CLI.
Existing visual/evidence validators
still run on the final attempt and must pass. The target UDID's simulator device
type determines the device class; the argument and every official result device
must agree. A retry moves the case's first outputs to `attempt-1/<case>/`, records
service-log byte offsets, and exports only the final attempt's request segment for
timeline validation. Request invariants (unknown paths, 400 bodies, forbidden key
fields and cross-server IDs, as applicable) are audited on every attempt's segment;
any violation fails the run even when the final test passes. Reset logs are appended
across sessions and attempts. An image-validator
failure outside XCTest does not authorize a retry. The hosted shard demonstration
remains an open acceptance criterion of #97 until #94 supplies the UI shards;
standalone access-lifecycle warm conversion remains excluded. #140 tracks its
flake but is not registered because the UI tier excludes that test.

Every strict suite and both access-lifecycle runners write raw XCTest result bundles under
`Path(tempfile.gettempdir()) / "immichSlides-strict-e2e-private"`, outside `--evidence-dir`.
The root and each new holding directory have owner-only permissions (`0o700`); a symlink root is
refused. On macOS this is inside the per-user temporary directory. Raw activities can contain
fixture keys or synthetic PIN input, so never upload these bundles.

During finalization, including failed runs, the runner exports official test identities and outcomes
with `xcrun xcresulttool get test-results tests --compact` to `official-tests.json` and retains
`official-summary.json`. Exports containing test credentials are refused before writing.
After export, cleanup and the unchanged sensitive scanner succeed, a successful run deletes its
bundle and writes `result-bundle-disposal.json`, including the export's SHA-256. A failed run,
export, scan or cleanup keeps the bundle private and records `result-bundle-quarantine.json`;
inspect it locally and delete it after diagnosing the failure. Finalization failures cannot make
a run pass. Unexpected evidence or validator exceptions also retain the private bundle; disposal
requires completed checks, and an existing Xcode failure exit code takes precedence over handled
evidence or cleanup errors. The existing P2 export and disposal contract stays unchanged.

`filter-person` runs three isolated sessions (`normal`, `conflict-normal`, `nofaces`). Each has its
own private bundle, `official-tests-<session>.json`, `official-summary-<session>.json` and disposal
or quarantine record with the same suffix. `official-summary.json` remains the suite aggregate;
the case manifest records each session export's hash. A later session failure preserves all
attempted sessions, including earlier passes, without claiming the suite passed.
Its Debug and Release capture paths, window allocation and residual timing limits are described
in the [strict runner capture contract](CI_STRICT_RUNNER.md).

Run the standalone access-protection flows with:

```bash
python3 scripts/run_access_lifecycle_ios.py --device iphone --destination 'platform=iOS Simulator,id=<UDID>' --evidence-dir '<outside-repo>/access-iphone'
python3 scripts/run_access_lifecycle_ios.py --device ipad --destination 'platform=iOS Simulator,id=<UDID>' --evidence-dir '<outside-repo>/access-ipad'
python3 scripts/run_access_lifecycle_tvos.py --platform tvos --destination 'platform=tvOS Simulator,id=<UDID>' --evidence-dir '<outside-repo>/access-tv'
```

These flows use the same bundle export/disposal mechanism and check both fixture keys and synthetic
PINs. Their `--print-command` mode previews a private-path placeholder without allocating a bundle.
They remain separate from the strict suite table.

The combined iOS access-lifecycle flow brackets photo-identity screenshots with the
frame-synchronized scene probe, using one fallible application snapshot per poll within
the existing capture deadline. Before Pause, the flow requires a playing stable scene
within the existing pause deadline. Both capture observations must show an opaque stable scene,
complete slot readiness and unchanged scene references/publication; paused Next also
requires the user pause. Swift SmartFill Next/Play identity decisions use every ordered
ledger scene reference; the captures must still contain recognizable stable pixels.
The Swift dominant pixel mark is not used as Next/Play scene identity in this flow;
background return and wake still compare it (see #439). Python independently reads pause,
Next and Play PNGs through `scene_mark_from_png`, combining detected slot marks from fixed stack/side
regions. It rejects unchanged Next and a Play mark different from Next or equal to pause;
this region sampling is not an exhaustive audit of the manifest's slots. Before-wake and
after-wake captures share one wake-evidence deadline, including the intervening tap;
the budget is not restarted. Stable-capture failures stop XCTest immediately and retain
the last observation and screenshot only as diagnostic evidence.
Single-photo display captures use the stable layer and current-asset probe. Settings and
PIN screenshots do not require a playback scene.

The offline unit runner and `check_all.sh --with-unit-tests` retain their explicitly requested
local bundles for inspection; they are excluded from the strict evidence/upload path. They do not
produce scanner-approved public evidence and their raw bundles must not be uploaded. The album/server
narrow entry point only prints device commands and refuses device execution; its manual command
output is also excluded. The iPad pause host tool does not produce XCTest bundles and remains
diagnostic-only. Future matrix consumers must exclude these unconverted manual/local entries
explicitly rather than treating their outputs as scanned strict results.

The CI [unit archive consumer](CI_UNIT_TESTS.md) is a separate converted entry point:
it uses the existing private bundle export/disposal helpers, exports official results
even on failure, scans compact records before upload and records archive provenance.
It runs every unit identity, including the conditional Live and Evidence skips; its
exact hermetic skip identities/reasons use the active per-tier unit policy described
in [CI_UNIT_TESTS](CI_UNIT_TESTS.md). This approval does not establish live coverage.

The original motion and visibility collectors in `ScenePresentationContractUITests` write `<displayMode>-contract-evidence.json` and `<displayMode>-trace.txt` to the directory in `TEST_RUNNER_SCENE_PRESENTATION_CONTRACT_RUN_DIR`. Set it through the environment of `xcodebuild` to a directory outside the repository; on iOS these collectors skip when it is unset, on tvOS it is optional. No runner script sets this variable. The directory is created with owner-only permissions (`0o700`) and the run refuses a path inside a Git worktree. The evidence uses schema `scene-presentation-contract-evidence-v3`: product SHA, device name, runtime identifier and video path are omitted when the run cannot observe them, never filled with a placeholder.

### Filter summary runtime screenshots

The Filter Summary visual UI tests save runtime screenshots only when `IMMICHSLIDES_SCREENSHOT_EXPORT_DIR` or `TEST_RUNNER_IMMICHSLIDES_SCREENSHOT_EXPORT_DIR` is set; otherwise they save nothing. Use a directory outside any Git worktree. It is created with owner-only permissions (`0o700`), each PNG is written with `0o600`, and a path that cannot be prepared fails the test. The screenshots can show real library photos: keep them private and delete them after review.

### Optional SmartFill evidence inputs

`PlaybackSmartFillVisualUITests` runs from the Evidence plans. Its scene collectors default to 20 scenes;
`IMMICHSLIDES_SMARTFILL_SCENE_COUNT` overrides that count, followed by
`TEST_RUNNER_IMMICHSLIDES_SMARTFILL_SCENE_COUNT`. Fixed-album cases require
`IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID` or `TEST_RUNNER_IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID` and only read
that album from the configured server.

Set `IMMICHSLIDES_SMARTFILL_EVIDENCE_ROOT` or `TEST_RUNNER_IMMICHSLIDES_SMARTFILL_EVIDENCE_ROOT` to an
output directory outside any Git worktree. Runtime manifests and screenshots are written under
`ui-runtime/<device>`. The general `TEST_RUNNER_UI_TEST_EVIDENCE_DIR` / `UI_TEST_EVIDENCE_DIR` input is
used by the other evidence helpers. Motion evidence uses `TEST_RUNNER_SMARTFILL_MOTION_EVIDENCE_DIR`,
then `SMARTFILL_MOTION_EVIDENCE_DIR`, or the SmartFill runtime directory's `motion-runtime` child. Keep real-server
evidence private and delete it after review. See the helper implementations for timing and tracing inputs.

### Optional reviewed screenshot calibration dataset

The Python photo-identity calibration cases accept `STRICT_E2E_REVIEWED_SCREENSHOTS`, an external
directory of reviewed public-fixture captures. The authoritative relative-path list is
`REVIEWED_SCREENSHOT_RELATIVE_PATHS` in [test_strict_e2e_photo_identity.py](../scripts/test_strict_e2e_photo_identity.py).
It includes iPhone/iPad history, an iPad pause-window transition and tvOS pause/resume captures. An unset
input skips those calibration cases; a configured directory with missing files fails.

Obtain the complete reviewed capture set from the maintainer, or regenerate the history and pause flows
with the strict runner's `journey-b`, `pause-window` and `tvos-flow` suites on their applicable devices.
Review the exported originals against the marks, history order and transition expectations in
`ReviewedScreenshotCalibrationTests` before assigning the required relative paths; runner exports do
not automatically produce this dataset's filenames. Run with
`STRICT_E2E_REVIEWED_SCREENSHOTS='<external-directory>' python3 -B -m unittest discover -s scripts -p 'test_strict_e2e_photo_identity.py'`.
Synthetic images do not replace reviewed Simulator captures for these calibration cases.
The host entry point removes `STRICT_E2E_REVIEWED_SCREENSHOTS` from every check's
environment so its `hermetic` skip policy stays accurate. Run reviewed calibration
directly with the unittest command above; setting the variable for `check_all.sh`
does not enable calibration.

### Standalone SmartFill planner benchmark

Run from the repository root on macOS with Xcode's Swift compiler. The benchmark compiles the real
planner and its model dependencies; it does not launch the app or access a server. Use an output path
outside the repository:

```bash
xcrun swiftc -O -parse-as-library \
    scripts/smartfill_planner_benchmark.swift \
    immichSlides/Shared/Model/ImmichModels.swift \
    immichSlides/Shared/Model/ImmichTypes.swift \
    immichSlides/Shared/Model/LocalizedText.swift \
    immichSlides/Shared/Model/PlaybackScene.swift \
    immichSlides/Shared/Model/PlaybackProtection.swift \
    immichSlides/Shared/Model/PlaybackSmartFillTypes.swift \
    immichSlides/Shared/Model/PlaybackSmartFillLayoutPolicy.swift \
    immichSlides/Shared/Model/PlaybackSmartFillRejectReason.swift \
    immichSlides/Shared/Model/PlaybackSmartFillPlanner.swift \
    immichSlides/Shared/Model/PlaybackSmartFillPlanner+Search.swift \
    immichSlides/Shared/Model/PlaybackSmartFillPlanner+Evaluation.swift \
    immichSlides/Shared/Model/PlaybackSmartFillPlanner+Geometry.swift \
    immichSlides/Shared/Model/PlaybackSmartFillPlanner+Readback.swift \
    immichSlides/Shared/Model/PlaybackSessionEngine.swift \
    immichSlides/Shared/Model/PlaybackSessionEngine+ScenePresentationState.swift \
    immichSlides/Shared/Model/ScenePresentationTypes.swift \
    immichSlides/Shared/Model/ScenePresentationEffect.swift \
    immichSlides/Shared/Model/SceneActiveTimeClock.swift \
    immichSlides/Shared/Model/SceneLifecycleContract.swift \
    immichSlides/Shared/Model/PlaybackIntervalPolicy.swift \
    -o /tmp/immichslides-planner-benchmark
/tmp/immichslides-planner-benchmark --max-wall-ms 1000
rm /tmp/immichslides-planner-benchmark
```

`--max-wall-ms` bounds the corpus loop and reports whether it was capped. `--stream` prints each call;
`--require-max-ms` fails when the slowest call reaches the supplied limit. Keep the corpus fingerprint,
compiler options and execution environment identical when comparing timing results.

### Strict end-to-end case identifiers

`case-manifest.json` lists the case IDs a suite covers. They name coverage that the mapped XCTest selector already implements; they are not a separate spec. `scripts/run_strict_e2e.py` (`CASE_E2E_IDS`) and `scripts/strict_e2e_p2_contract.py` (`P2_CASES`) are the sources of truth.

| ID | Coverage |
|---|---|
| `E2E-P0-01` | First-boot server setup |
| `E2E-P0-02` | First-boot setup survives a cold relaunch |
| `E2E-P0-03` | Random or core playback is reached |
| `E2E-P0-04` | Album filter members, empty album, or album edit-switch |
| `E2E-P0-05` | Person filter rules. Vision solo-only is reported `UNVERIFIED` on simulators and has no device path yet ([#80](https://github.com/sudoHG/immichSlides/issues/80)) |
| `E2E-P0-06` | Server-switch isolation |
| `E2E-P0-07` | A late image keeps the current scene |
| `E2E-P0-08`, `E2E-P0-09` | Playback control state on the iOS and tvOS playback flows |
| `N1` | tvOS first-boot save and configured cold launch |
| `E2E-P2-01` | EXIF toggle ownership (`p2-exif`) |
| `E2E-P2-02` | Clearing the disk cache from Settings and returning to playback (`p2-cache`) |
| `E2E-P2-03` | System Reduce Motion on and off, single and SmartFill scenes (`p2-reduce-motion`) |
| `E2E-P2-04` | SmartFill multi-photo layout in both iPad orientations (`p2-ipad-layout`) |
| `E2E-P2-05` | Rotation during playback on iPhone and iPad (`p2-rotation`) |

## Generating a local privacy page

Diagnostic identity fields are opaque correlation values. Playback request lifecycle JSONL hashes
`assetId` and `sceneId` at serialization with `PlaybackImageRequestLifecycleDiagnostics.redactedHash`;
request IDs remain unchanged so request events can still be joined. Motion seed summaries hash scene,
slot and asset identities without changing the seed used for animation. Motion probes use the same
identity tokens as the seed summary, including their diagnostic accessibility identifier suffix.
iOS and Apple TV product trace
`slotRefs` uses `PlaybackScene.diagnosticSlotReferences`, the same ordered ledger tokens as the
runtime manifest. Consumers must compare these tokens rather than raw server IDs.

`PRIVACY_POLICY.md` stays in this repository because the app bundles it for tvOS. The official website is maintained separately in [sudoHG/immichSlides-web](https://github.com/sudoHG/immichSlides-web).

`python3 scripts/build_privacy_policy_page.py` generates the privacy page and root redirect in the git-ignored `build/privacy-site/` directory. Use `--output-dir <directory>` to choose another output directory; relative paths resolve from the current working directory. This only generates local files and does not publish the website.
