# Strict runner warm-build tracer

The informational `ci-strict-tracer` workflow runs on the [pinned hosted toolchain](CI_TOOLCHAIN.md)
only for pull requests touching its workflow, strict runner modules/tests or tracer
manifest, and through `workflow_dispatch`. Other PRs and main pushes do not trigger it.
It covers an iPhone smoke suite,
an Apple TV smoke suite, iPhone P2 rotation with recording, and the dual-server
`filter-switch` suite. [`strict-tracer.json`](../scripts/strict-tracer.json) is only
this tracer's versioned case list, not the complete nightly matrix. Nightly matrix
enumeration and aggregation are documented in [Skeleton nightly](CI_NIGHTLY.md).
Explicit warm runs can opt into [listed-only retries](TESTING.md#known-flaky-registry-and-listed-only-retries)
with `--listed-retry-device`; the tracer and skeleton nightly continue to run once.
Signed visual-review promotion remains separate work.
Simulator preparation and official exports have explicit phase deadlines; timeout
records and private quarantine follow the [nightly infrastructure policy](CI_NIGHTLY.md#population-and-capacity).
The shared preparation gate caps `simctl boot` at 60 seconds and gives boot,
bootstatus and responsive app queries 600 seconds total. Post-boot queries use at
most 300 seconds within that gate. The [shared reset](#shared-simulator-reset)
then starts the separate 120-second app/keychain/privacy reset clock;
individual reset commands have at most 60 seconds. Local strict,
fixture UI, listed retry and access-lifecycle runs use these preparation bounds too.
Official tests and summary exports each have 60 seconds. Unit callers retain
`unit-results-timed-out` with export phase and elapsed time; strict callers retain
their preparation/export phase codes. Test-execution budgets are separate.

Strict builds use their own test plans and settings; they do not consume the default
unit/UI archives. They reuse the [archive workspace preflight](CI_BUILD_ARCHIVE.md),
product inventory and signing inspection. No competing archive producer or artifact
selection mechanism is introduced.

`filter-edit-switch` checks both the original whole-frame color identity and each
full-span photo slot against the non-target album's A1–A5 classifier labels. Public
background colors locate slots independently of glyphs along both rows and columns.
Only a clean partition into vertical stacks or horizontal neighbors is supported;
two-dimensional grids, conflicting axes and mixed palettes fail unreadable. Obscured
lines remain in a slot only when the surrounding lines identify the same photo.
A one-slot partition requires agreement from both axes, so a blank band or foreign
footer cannot borrow the other axis's dominant photo. Each collage slot requires
the active fixture's sharp A/B bitmap, with at least 14 observed cells, five white
cells and agreement with every observed cell. A visible digit must also agree
with the slot's color identity. Unobstructed public texture rows cross-check the
letter, rejecting an unreadable foreign slot even when its photo number matches
its neighbor. Mixed letters, missing glyphs and unreadable slots have distinct
failure reasons. White bands shorter than ten sampled pixels are excluded; up to
four blank rows join adjacent bitmap ink. Wider EXIF text bands may remain
unrecognized, but cannot supply a missing slot's identity.

`journey-b` and `tvos-flow` compare complete per-slot signatures in spatial order
(top to bottom or left to right) for history, pause and resume. Swapping two slots
changes the signature even when the photo set is unchanged. Swift rejects black,
blank, incomplete or mid-transition frames
and records manifest/render probes immediately before and after the PNG, without
adding a wait or retry. Python independently reads every pixel slot, matches its
public identity to `ledgerSceneAssets` using the fixture's hashed references, and
checks stable rendering and slot readiness. tvOS additionally cross-checks
`actionTimestamp` and `scenePublishTimestamp`: Next and Resume require newer
publications, and Pause requires the same publication. The invisible index probe
clamps the scene cursor to the asset count, so it can remain `5/5` across advances;
it must remain readable and consistent during capture but cannot prove progress.
Initial presentation (`publishReason=initial`) has no action timing until the
first navigation; the next publication must still provide valid finite timing.
Backward history identity uses the complete pixel signature and ledger references.
Probes cannot supply a
missing pixel identity. A5 and A1+A5 have different signatures.

`UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE=1` enables the Debug manifest probes.
Probe-only launches are `journey-b`, `tvos-flow`, `ios-lifecycle-first-wake`,
the other `ios-lifecycle-*` selectors, and
`AccessLifecycleIOSUITests.prepareLaunch`, including its cold relaunches and
`run_access_lifecycle_ios.py`'s `testAccessProtectionSettingsAndLifecycle`.
`pause-window` sets the probe plus `UI_TEST_SERVER_URL`, `UI_TEST_API_KEY`,
`UI_TEST_RESET_STATE` and `UI_TEST_FORCE_MODE_SELECTION`.
`tvos-directional-wake` sets those four legacy keys plus
`UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT`, and does not set the scene probe.
Other probe-key launches are the configured SmartFill launch helpers in
`PlaybackHistoryIOSUITests`, `ScenePresentationContractUITests`, and
`FilterSummaryTVOSVisualUITests.testTVOSSlideShowControlBarButtonsCanActivateOnSelect`.
They also set other `UI_TEST_*` keys, so their XCTest mode remains enabled.
The runner's launch audit is a **static declaration of Swift launch keys**,
labelled `declaration_kind=static_swift_launch_keys`; it is not read from the app.
The policy helper validates supplied maps against those declarations, exact
constant values and a public loopback URL. The runner does not yet compare this
declaration against Swift's xcresult launch-key attachment; that comparison is a
follow-up under #434. An empty `forbidden_keys_present` is not runtime evidence.
This exact key is excluded from `isRunningXCTest`: a probe-only launch keeps
the real Keychain path, never enables `immichApiKey.xctestFallback`, and preserves
the ordinary Info.plist debug-server read. Other XCTest keys retain their existing
effect. The flag does not request a reset or bypass onboarding; Release exposes
neither probe. For Debug first-wake and iOS access-lifecycle, which already used the
probe-only key on main, this is a change from the UserDefaults API-key fallback
to the real Keychain path, including ordinary Info.plist behavior; it is not a
restoration relative to main. The strict `ios-lifecycle-first-wake` runner uses
the Release settings-resume scheme; Release already disables XCTest mode and
the fallback on main, so that run does not prove the Debug mode change.
Their additional Debug manifest/motion probe exposure
also needs device verification. New pure environment tests in the existing `UnitTestHostTests`
file guard probe visibility and isolation from XCTest mode. Capture
sidecars are written before an assertion can stop XCTest, preserving failed
probe observations for diagnosis.
The iOS resume-state wait also requires a complete opaque stable frame before
the second Pause that starts history. The tvOS resumed publication-change wait requires
the same stable capture window, with motion progress in its normalized 0...1
range. This excludes the late-motion interval that can cross into a fade while
capturing. Their existing 4-second and 3-second deadlines and failure prefixes
remain unchanged; unmet conditions fail within those windows. Pause still freezes
mid-fade by design, which the dedicated pause-window suite covers. These history
and resumed identity captures require a stable frame and add no retry or extra wait.
The tvOS wait latches a newer action/publication pair from one app snapshot, then
checks the stable window within the same deadline. Index, render and manifest
come from that snapshot; it neither wakes the bar nor queries its missing probe.

These scene contracts, `tvos-edit-switch`, the A frame of server-switch, and
`tvos-person`/`tvos-album` use the same reader. Uniformly across geometries, a
segmentable single-photo frame retains #381's whole-frame color and visible
public-texture judgement, including clipped glyphs. Collages require the strict
glyph, texture and membership rules for every slot. An unsegmentable frame never
falls back to color classification. The surround reader still requires both the
matched public original and its blurred background.
The palette splitter requires only 18 matching samples per line; it does not
prove full pixel coverage inside a slot. Black bars, blank bands or blurred
padding inside a slot can escape this identity reader, and planner-reported
coverage is geometry rather than rendered-pixel evidence. Adjacent slots of
the same photo can also merge; scene contracts check slot counts and references,
while filter contracts have no corresponding probe check. Pixel coverage needs
separate validation; this reader's thresholds remain unchanged.
Unobstructed checker rows must have consistent cell spacing, within two sampled
pixels of raster rounding, with edge cells no wider than interior cells. This
rejects a same-number foreign stripe beside a checker photo. Narrow edge crops
are not classified as stripes by themselves; the complete photo row supplies
the texture evidence. These rules apply identically to both slot orientations.

Within eight raw pixels of a screen edge, segmentation alone may recognize a
unique interpolation between the two colors of the same public photo. Interior
palette, glyph and texture evidence keeps the original tolerance of 12; the
edge interpolation never supplies texture or glyph evidence. Black, white,
ambiguous palette interpolations and blended interiors remain unreadable.
Exact palette matches take precedence. The residual interpolation risk is a
non-palette color near a same-photo color segment on the outermost one to three
sample lines. Nearest-neighbour sampling also misses features narrower than
one sample step anywhere: TV 8 pixels, iPad about 3.4, iPhone about 2.4.
The measured A1 edge sample (77,74,72) motivates this bounded rule.

The pinned Apple TV 4K (3rd generation), tvOS 27.0, produces **3840x2160** PNGs.
Scanner-approved frames measured the A2/A3 seam at x=1382 and the A5/A3 seam at
x=1536. The entry hint and playback controls fit inside (1256,1436)-(2580,1925),
including a four-pixel margin; tvOS has no home indicator. Only measured scene
captures exclude that bounded rectangle from palette and glyph evidence. It
cannot hide a full-height or full-width slot. Overlay ink cannot create bitmap
bands or supply observed cells; letters and digits must still agree with every
remaining cell and meet the unchanged evidence minima. The device-pin guard
requires a measured geometry for all three pinned strict devices.
When a measured overlay splits a glyph, ink fragments are joined only across a
gap wholly inside that overlay and within one palette slot. The ten-pixel band
minimum is applied after joining; short unjoined fragments remain excluded.

The iOS `album-empty` and `filter-album` contracts select their path by the raw
capture size. Unmeasured sizes retain the original whole-frame classifier and
target-album membership rules entirely, without foreground/background checks,
slot counting or per-slot glyph reading. The measured sizes below first check
the foreground/background and count public color slots before reading glyphs.
Exactly one identified slot then uses the original whole-frame classifier and
membership rules, including zoomed photos with clipped glyphs. A measured frame
that fails the palette splitter or background check fails, even if the original
whole-frame classifier matches. This includes letterboxed single-photo frames
whose black surround does not match the photo's blurred background.
Multiple slots use the per-slot reader: every slot must have a readable active-fixture
glyph and a color identity in the original target-album membership set. An unreadable
stacked frame never falls back to whole-frame classification. Stacked frames
are checked as separate photos, never as one dominant whole-frame identity.
Single-photo surrounds are excluded only by the existing matched-original and
blurred-surround checks. `album-empty` still requires both playback captures,
at least two different target photos and different identity sets in the two
captures. Empty-selection, controlled-empty-album, exact-copy and old-pool-photo
rejection checks are unchanged. `tvos-album-empty` retains its whole-frame reader.
Only these two iOS contracts opt into measured system-overlay handling: the
1640x2360 iPad home-indicator box (543,2330)-(1097,2349), or 1170x2532 iPhone
box (373,2489)-(798,2512), is excluded from color sampling, with glyph pixels
unchanged. Each box is narrower than every full-width slot.
For 1170x2532 iPhone captures, glyph bands may join only across gaps wholly inside
the control-bar rows (2126..2314); overlay cells in (68,2126)-(1102,2314) cannot
supply glyph evidence. The merged letter and digit still agree with every observed
cell, and all original cell-count, white-cell, texture and slot checks apply.
`filter-edit-switch` does not opt in. Every pinned iOS strict-suite device must
have a measured geometry; changing a pinned device requires new measurements.

The stacked target-album failure in [#373](https://github.com/sudoHG/immichSlides/issues/373)
is fixed only on measured sizes. Unmeasured sizes keep the original whole-frame
contract, including its known stacked-frame false pass. Successful iOS
`album-empty` and `filter-album` visual reports add `target_album_geometry`:
`measured` means every playback frame used the measured path; `unmeasured` means
at least one frame used the original path. `target_album_frame_geometry` maps
each playback screenshot step to `measured` or `unmeasured`, so mixed-size evidence
does not hide which path judged each frame. These fields are written unchanged to
`visual-identity-runner.json` and to `case-manifest.json` under `visual_identity`;
no consumer reads either field. They do not affect verdicts or runner exit codes.
Unreadable target-album playback screenshots (album-play-*) and empty-result
screenshots (empty-album-result.png, for both iOS and tvOS album-empty suites)
produce a FAIL contract report.
File-read failures remain I/O errors. tvOS reports retain their existing fields.

## Explicit shard warm-up and reuse

Each shard is grouped by scheme and configuration. Ordinary suites default to their
existing Debug setting; settings-resume suites use their dedicated scheme and require
Release. `--configuration Release` selects Release for other suites when required.
Keep each scheme/configuration/device in a separate DerivedData directory and use
one cloned-package directory shared by the shards in that workspace.

```bash
python3 -B scripts/run_strict_e2e.py --platform ios \
    --destination 'platform=iOS Simulator,id=<UDID>' --suite smoke \
    --warm-up-only --derived-data-path '<outside-repo>/derived/ios-debug' \
    --cloned-source-packages-path '<outside-repo>/SourcePackages' \
    --evidence-dir '<outside-repo>/warm-up/ios-debug' --cold-timeout-seconds 1200

python3 -B scripts/run_strict_e2e.py --platform ios \
    --destination 'platform=iOS Simulator,id=<UDID>' --suite smoke \
    --test-without-building --derived-data-path '<outside-repo>/derived/ios-debug' \
    --cloned-source-packages-path '<outside-repo>/SourcePackages' \
    --evidence-dir '<outside-repo>/cases/smoke' --warm-timeout-seconds 600
```

Use a fresh evidence directory for every case. Warm-up requires fresh shard
DerivedData and runs `build-for-testing` without a test, service or recording.
Its receipt binds source contents (including intended uncommitted files, excluding
`__pycache__` and `*.pyc`), toolchain,
scheme, plan, configuration and destination to the signed Products inventory.
Reuse refuses an absent, mismatched or modified build instead of rebuilding.
Use the same configuration and destination in both commands. Per-case `.xctestrun`
copies live beside the private result bundle, with relocated `__TESTROOT__` paths
and fixture/evidence inputs injected only into the test runner. App launch inputs
stay empty. Every warm invocation uses `test-without-building`; Products are hashed
before and after. Recordings begin after that preparation and contain no build.
The existing filter-person sessions each reuse this build and still reset separately.

The cold budget applies only to warm-up; the warm budget applies per reused Xcode
invocation. The runner's local defaults remain 300 seconds for both, and the
default mode remains the existing single `test` call with its fixed 300-second limit
with disposable DerivedData in evidence. Explicit cold/warm timeout options are
rejected in that default mode. Explicit shard DerivedData is retained
until its owner finishes all cases. Package resolution stays locked and simulator
signing stays **Sign to Run Locally**, verified as `adhoc` by `codesign` after warm-up.

## Fixture service startup

Fixture service startup uses a separate 60-second infrastructure budget, shared
by the strict, fixture UI, access-lifecycle and iPad pause host runners. It
requires the ready file to identify the spawned child and `/healthz` to return
HTTP 200; child exit or a mismatched PID fails immediately. Health requests are
capped at one second and the remaining startup budget. Success logs seconds to
healthy; timeout reports elapsed time and the last ready-file/HTTP/error state,
without logging response bodies or addresses. This replaces the ten-second wait
that failed on [the hosted iPhone probe](https://github.com/sudoHG/immichSlides/actions/runs/38122386215/job/114420489109)
after simulator preparation succeeded. Sixty seconds provides bounded startup
headroom; the actual delayed recovery time was not recorded. Test and product
deadlines are unchanged, and an unhealthy service still fails the run.

The service flushes fixed startup-phase records for import, fixture build, bind
and ready-file write, with elapsed and total seconds at each boundary. They
contain no input values, addresses or paths. Strict runs capture stdout in the
private `service-startup.log` and, for a peer service, `service-b-startup.log`
inside the evidence directory; request logs remain separate. Strict and fixture
UI waiters forward at most eight allowlisted records from the first 4 KiB of
their service stdout log and append the last observed phase/state to a startup
`CommandError`. Hosted strict tracers keep the detailed records in private
`runner.log`, but echo that phase-bearing error line to the public job log.
iPad pause host runs publish the service's records directly.

The absence of separate phase lines in a hosted strict public log does not
imply that the child reported none. An absent phase field on a strict or fixture
UI startup error means the bounded reader obtained no valid record; an unreadable log or
records beyond its prefix can also explain that absence. Neither establishes
where startup stalled.

## Shared simulator reset

Strict, fixture UI, listed-retry and standalone access runners share
`reset_simulator_app`: its shared `prepare_simulator` gate boots and waits for
`bootstatus -b`, then waits for a valid app-container
response, terminate only when the app is installed, uninstall with one retry on
failure, require the app container to be absent afterward, then reset keychain and all privacy
permissions. Only a container lookup confirming absence skips termination; an
unknown response fails immediately. Readiness repeats only timed-out container
queries with caps of 10, 20, 40, then 60 seconds, retaining the 60-second cap for
later attempts. Each cap is clamped to the remaining 300-second post-boot budget
and the remaining 600-second combined preparation budget.
Exhausting that budget fails as `simulator-readiness-timeout`, before any reset
mutation; a warm device returns on its first valid response. Uninstall and the
remaining reset steps are still mandatory before Xcode may install the app. A reset error fails the case.

UI consumers run this gate before identity/archive checks, simulator inventory
and fixture server startup/health checks. Standalone fixture and strict runners
also gate before simulator lookups and fixture health checks; resets use the same
gate again, normally returning on the first warm query. UI consumers pass their
successful preparation state to the fixture runner, which skips the redundant
`simctl boot`; fixture resets and retries do the same after their initial gate.
Bootstatus, readiness queries and all reset mutations still run. Strict hosted jobs prepare
the device before cold builds or case runners. Toolchain/pins checks run before
early boot; only archive downloads overlap boot in the UI workflows.

The fixture UI device-inventory query uses the same timed-out-query retry logic
and a separate 300-second readiness budget: 10, 20, 40, then at most 60 seconds
per attempt, clamped to the remaining budget. Nonzero exits, malformed JSON,
missing/unavailable destinations and mismatched device types fail without a
retry; even a valid response after the deadline fails. Logs name
`simulator-inventory`, attempt counts, elapsed time and deadline overrun without
command arguments or output. This does not change the service's 60-second budget.

Boot and readiness finish before the existing 120-second reset deadline starts;
termination, uninstall, the post-uninstall container check and state resets share
that deadline. Individual reset commands retain their 60-second cap. Boot phases,
readiness attempts and elapsed seconds, skipped termination and total reset seconds
are logged. This adds no fixed post-boot sleep and extends no reset or product deadline.

The readiness budget stops new queries and rejects responses after its deadline;
it is not a hard wall-clock bound on subprocess timeout cleanup. Wall time can reach
300 seconds plus the overrun of the last query. A hosted query with a nominal
60-second cap took 130 seconds before timeout returned
([job](https://github.com/sudoHG/immichSlides/actions/runs/38113304252/job/114393826951)).
Logs record each timed-out query's cap and actual elapsed time, plus the final
readiness `deadline_overrun`. Outer runner and job timeouts remain the final bounds.

The combined 600-second gate allows headroom above the observed 202-second boot plus bootstatus
plus a 130-second unresponsive query (332 seconds); the post-boot allowance remains
300 seconds. It logs total preparation elapsed time and overrun as well. In the
[early-boot probe](https://github.com/sudoHG/immichSlides/actions/runs/38116564553),
three iOS jobs failed before readiness: device inventory, fixture health and
toolchain verification. The fourth reached tests after a warm 0.4-second boot check,
0.3-second readiness query and 3.1-second reset, then failed an XCTest assertion.
This is preparation evidence, not a passing UI run.

For capacity planning, adding the measured 56.5–202-second cold boot plus bootstatus range to the
tested 54.2-second-per-query scenario (10 + 20 + 40 + 54.2 = 124.2 seconds) gives
180.7–326.2 seconds, about 3–5.4 minutes per cold iOS job before download overlap.
These are modeled costs, not hosted recovery measurements. Download overlap may
save little time; Python setup now precedes boot, so its cost is not hidden. The
nominal preparation bound is ten minutes plus final subprocess cleanup overrun,
separate from reset and unchanged XCTest deadlines. Reliability may therefore
cost as much as the earlier 3–9-minute enumeration bootstrap; hosted re-probing
must establish the actual critical-path cost.

Use dedicated simulators: keychain/privacy reset applies to the whole device.
Server/UI test variables in direct,
`TEST_RUNNER_` and `SIMCTL_CHILD_` forms are filtered. Strict fixture inputs are
passed explicitly; real server configuration is never used.

Warm mode invokes the existing workspace preflight before setup/build/reuse. It
rejects regular configuration files, links and dangling links without opening them.
Use a checkout without local private configuration, a dedicated simulator that is
not shared with another job, and an outer timeout for device/build commands. The
Local disk preflight requires 80 GiB.

## Tracer, budgets and results

```bash
python3 -B scripts/run_strict_ci_tracer.py --platform ios \
    --destination 'platform=iOS Simulator,id=<UDID>' \
    --output-dir '<fresh-outside-repo>/tracer-ios'
```

Repeat with `--platform tvos` and its destination. The tracer groups its cases,
builds each shard once, then runs each case without building. It does not retry.
The hosted workflow uses an initial 1,200-second cold budget, 600-second warm budget,
and a 30 GiB disk preflight. Each runner segment has an additional 240-second outer
allowance for reset/export/cleanup; warm segments also allow 300 seconds of readiness
per invocation. iOS allows two cold and three warm segments
(105 minutes total); tvOS allows one of each (43 minutes total). The literal
125-minute job timeout covers the larger shard, a separate 10-minute initial simulator
boot budget, and setup, uploads and final cleanup. Both workflows call the same boot
helper as local resets. Initial boot phases and elapsed times are logged before the
first case, so cold boot does not consume the 120-second case-reset
budget. The [nightly capacity policy](CI_NIGHTLY.md#population-and-capacity) records the
hosted measurement used for this boot allowance.
The hosted preparation step has a 13-minute cap, leaving three minutes beyond
the nominal gate for query cleanup and failure diagnostics.
The initial allowance follows
the archive producer's [measured hosted disk use](CI_BUILD_ARCHIVE.md); the tracer
reports its own measurements for review. Hosted cold/warm budgets and the disk exception
do not replace the local xcodebuild budget or 80 GiB disk preflight; the shared local
preparation/export bounds are stated above.

`records/trace.json` is written initially and after every runner segment, including
timeouts and interruptions. It reports each cold/warm duration, exit code, official counts,
build-operation count, immutable Products check and sampled disk usage. Disk is
sampled once per second: minimum free, peak volume use and growth since start;
shorter spikes may be missed and unrelated runner activity is included.
`summary.json`, `summary.md` and `run-identity.json` use the existing producer
[summary contract](CI_SUMMARY.md). Missing results, builds in a warm log, changed
Products and failed strict contracts fail the tracer. P2 contract success is
`needs-human-review`, with overall producer status `unverified`, never visual PASS.
Only a complete observed set with every automated check passing permits a non-failed
status. Cancellation and unexpected exceptions record failed status, an `interrupted`
infrastructure entry and every unfinished case as `not-run`. Each runner starts in
its own process group; timeout/cancellation terminates and waits for that whole group
before deleting build inputs. Shared group-probe behavior is documented in the
[host contract](CI_SUMMARY.md). The runner's final `CommandError` is printed in the job log.
Official summary and selected-method exports are read even after runner failure;
nonzero exits remain failures. Filter-person combines its three session exports
and requires all three passes. Exit 0 means all automated tracer checks completed,
not release eligibility.

### Public failure diagnostics

Failed method nodes in `official-tests*.json` and the tracer's
`trace.json` `official_methods` carry two fixed enums:

- `failure_phase`: `interval_setup`, `hidden_controls`, `visible_scene_capture`,
  `background_return`, `continue_timing`, `paused_hold`, `settings_navigation`,
  `control_action`, `firstboot_setup`, `cold_relaunch`, `mode_selection`,
  `playback_entry`, `history_navigation`, `pause_window`, `late_image`,
  `image_recovery`, `exif_ownership`, `filter_selection`, `filter_edit`,
  `server_switch`, `display_policy`, `unknown`.
- `failure_class`: `interval_readback`, `hidden_controls`, `scene_identity`,
  `process_lifetime`, `timing_window`, `navigation`, `snapshot_query`,
  `control_state`, `focus`, `evidence_capture`, `probe_readback`,
  `fixture_response`, `exif_visibility`, `exif_correspondence`, `unknown`.

The code-defined allowlists and reviewed assertion-prefix table live in
[`ci_failure_diagnostics.py`](../scripts/ci_failure_diagnostics.py). The lifecycle
and History flows have no existing phase activity marker, so the mapper reads
private official legacy failure summaries and discards all message suffixes.
Only `testFailureSummaries` supplies messages; a `testWarningSummaries` entry
for the same method cannot replace or obscure its failure label.
XCTest assertion and caught `AssertionError.message` wrappers are recognized;
unmatched, missing or conflicting messages yield `unknown` for both fields.
Snapshot/hittability failures identify only the class, with an unknown phase.
Empty screenshot data and Autoplay control-state assertions yield unknown for
both fields because they do not establish scene identity or navigation.
These labels locate a check; they do not establish a product or infrastructure
root cause. No assertion text, observed value, path, identifier or frame is
added to public records by the mapper.

The shared export defaults to byte-preserving output without diagnostics. Only
strict and UI callers opt in with `enrich_failure_diagnostics=True`; unit and
lifecycle consumers retain the original tests/summary exports and budgets.
An opted-in failed invocation attempts one additional private export, bounded by
the existing official export timeout. Read failures yield unknown diagnostics
without changing the official result, population, retry eligibility or exit code.
The recorded export hash binds the enriched public bytes. Historical records
without diagnostics remain valid. The existing sensitive scan additionally
requires paired string fields from these exact allowlists in JSON records,
rejecting free text, duplicate diagnostic keys and malformed diagnostic JSON;
credential scanning, publication checks and bundle quarantine remain in force.

#### Reviewed prefix table

The following additions come only from public Swift assertions in the linked source files.
Identical text in other files has also been checked and establishes the same phase.
Each row fixes both enum values before any suffix is read. Shared prefixes receive a
specific phase only when their public call sites establish the same phase. The shared
EXIF helper also runs in the pause-window flow, so its two prefixes retain an `unknown`
phase and only identify the class. The shared driver's EXIF toggle also runs in image
failure recovery, so that prefix retains an `unknown` phase and `control_state` class.
The shared tvOS album/person helpers and paused-capture helper also run in the playback
settings editor and server-switch flows, so their prefixes retain an `unknown` phase.
The existing lifecycle/XCTest rows remain unchanged.

New enum meanings and why the previous vocabulary cannot express them:

| Enum | Meaning and reason |
|---|---|
| `firstboot_setup` | Entering, testing and saving the initial configuration; distinct from playback settings navigation. |
| `cold_relaunch` | Navigation after terminating and relaunching a configured app; distinct from a live background return. |
| `mode_selection` | Choosing a mode or returning to its page; distinct from playback settings navigation. |
| `playback_entry` | Reaching playback from mode/filter selection; distinct from acting on controls during playback. |
| `history_navigation` | Next/Previous retained-history checks; distinct from generic control availability. |
| `pause_window` | Detecting and capturing the outgoing-only transition pause; distinct from an already paused hold. |
| `late_image` | Checks while or after superseded image requests complete; distinct from background return or Continue timing. |
| `image_recovery` | Controlled failing-image response setup/readback; distinct from interval setup or visible-scene capture. |
| `exif_ownership` | EXIF toggle state and visible-card effects in the ownership flow; distinct from scene identity alone. |
| `filter_selection` | Album/person selection and its list/summary navigation; distinct from playback settings navigation. |
| `filter_edit` | Editing/clearing filters through playback settings; distinct from initial selection. |
| `server_switch` | Clearing old selections and preserving process/scene after changing servers; distinct from cold relaunch. |
| `display_policy` | Applying and reading back display mode and its visible scene/process contract; distinct from control actions. |
| `control_state` | Enabled/selected/play-pause state of an existing control; navigation and hidden-controls classes do not express its value. |
| `focus` | Remote system focus on a named UI control/receiver; presence or navigation alone does not prove focus. |
| `evidence_capture` | Missing required captured frames; this does not establish the identity of their absent pixels. |
| `probe_readback` | Missing/inconsistent combined render/manifest/history or synchronized opacity probe evidence; this does not identify a bad photo. |
| `fixture_response` | Controlled image-response mode or delivered-failure count; this is fixture evidence, not navigation or image identity. |
| `exif_visibility` | Visible EXIF card remains after disabling it; photo identity alone cannot express overlay visibility. |
| `exif_correspondence` | EXIF metadata disagrees with the identified photo; neither navigation nor photo identity alone expresses that mismatch. |

| Fixed source prefix | Phase | Class | Public source |
|---|---|---|---|
| `The first-boot page must show the Save Settings button.` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `After a successful save, the app must reach mode selection.` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `A fresh install must reach the normal first-boot page.` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `The first-boot page must show the API Key field.` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `The first-boot page must show the Test Connection button.` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `Save must become enabled after a real connection test succeeds.` | `firstboot_setup` | `control_state` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `A cold launch with saved settings must not return to the first-boot page.` | `cold_relaunch` | `navigation` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `A configured cold launch must go straight to the playback page.` | `cold_relaunch` | `navigation` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `The mode page must offer ` | `mode_selection` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `Chose filter but reached the playback page, so the mode card tap did not register.` | `mode_selection` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `Still on the mode page after Continue; filter mode did not start.` | `mode_selection` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `Filter mode must reach the filter summary page.` | `mode_selection` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `Going back from the filter summary must return to mode selection.` | `mode_selection` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `Random mode must reach the playback page.` | `playback_entry` | `navigation` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `The playback page must show the Previous button.` | `control_action` | `hidden_controls` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After auto-advance, the playback controls must be revealable.` | `control_action` | `hidden_controls` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `The playback page must show Play/Pause.` | `control_action` | `hidden_controls` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After pausing, the playback controls must still be revealable.` | `control_action` | `hidden_controls` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After pausing, the control value must be play.` | `control_action` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `Resuming must continue from the current photo, with the control value back to pause.` | `control_action` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `Previous must be disabled at the history boundary when playback starts.` | `history_navigation` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After two Next taps, Previous must be enabled.` | `history_navigation` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After a pause of at least 10 seconds, autoplay must not resume on its own.` | `paused_hold` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `probe_hit=MISS: frame-synchronized probe never saw outgoing translucent and incoming opacity=0 in 7 s.` | `pause_window` | `timing_window` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `visual_verdict=MISSING_FRAMES: missing a window-detected, after-pause, after-pause-0_3s or play-to-pause keepAlways frame.` | `pause_window` | `evidence_capture` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `visual_verdict=BLACK_OR_BLANK: synced probe missing after pause, or outgoing opacity already 0.` | `pause_window` | `probe_readback` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After pausing, the synced probe does not meet outgoing opacity>0 and incoming opacity=0.` | `pause_window` | `probe_readback` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After late completion the current public mark must stay: no flash back, all black or unreadable: ` | `late_image` | `scene_identity` | [StrictE2ELateImageIOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageIOSUITests.swift) |
| `Next must be tappable twice right after entering the slideshow, before old image requests finish.` | `late_image` | `navigation` | [StrictE2ELateImageIOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageIOSUITests.swift) |
| `The fixture must actually deliver a failing image response` | `image_recovery` | `fixture_response` | [ScenePresentationContractUITests.swift](../immichSlidesUITests/ScenePresentationContractUITests.swift) |
| `Fixture control must acknowledge its response mode` | `image_recovery` | `fixture_response` | [ScenePresentationContractUITests.swift](../immichSlidesUITests/ScenePresentationContractUITests.swift) |
| `After turning EXIF off, the info card in the upper-right area of the public photo must disappear from the screen.` | `exif_ownership` | `exif_visibility` | [ExifToggleUITests.swift](../immichSlidesUITests/ExifToggleUITests.swift) |
| `The required PNG with EXIF off still shows the info card.` | `exif_ownership` | `exif_visibility` | [ExifToggleUITests.swift](../immichSlidesUITests/ExifToggleUITests.swift) |
| `Can't check EXIF: photo status ` | `unknown` | `scene_identity` | [StrictE2EPhotoIdentity.swift](../TestSupport/StrictE2EPhotoIdentity.swift) |
| `EXIF does not match the photo: mark=` | `unknown` | `exif_correspondence` | [StrictE2EPhotoIdentity.swift](../TestSupport/StrictE2EPhotoIdentity.swift) |
| `The EXIF toggle must reach the target state through the real settings.` | `unknown` | `control_state` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift) |
| `Default focus on the mode selection page must land on random playback.` | `mode_selection` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift) |
| `Focus on the mode page must be able to move to filtered playback.` | `mode_selection` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift) |
| `After choosing a mode, focus must be able to move down to the Continue button.` | `mode_selection` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift) |
| `After returning to mode selection, default focus must go back to random playback.` | `mode_selection` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift) |
| `After Continue, the app must reach the playback page and show the control bar.` | `playback_entry` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift) |
| `Before sending the wake arrow key, the hidden receiver layer must have system focus.` | `hidden_controls` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift) |
| `After the control bar wakes again, focus must land on Play/Pause.` | `hidden_controls` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift) |
| `After pressing Down, the hint and the control bar must hide.` | `hidden_controls` | `hidden_controls` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift) |
| `With the control bar hidden, an arrow key must wake it again.` | `hidden_controls` | `hidden_controls` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift) |
| `Default focus on the filter summary must land on the album filter.` | `filter_selection` | `focus` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Focus must land on the target album.` | `unknown` | `focus` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Start Playback must be disabled with an empty selection.` | `filter_selection` | `control_state` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Start Playback must be disabled with 0 albums / 0 people.` | `filter_selection` | `control_state` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Start Playback must be enabled after selecting the target album.` | `filter_selection` | `control_state` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Filtered playback must be startable after selecting the target album` | `filter_selection` | `control_state` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `The album filter entry must be shown.` | `unknown` | `navigation` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `The person filter entry must be shown.` | `unknown` | `navigation` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Opening the album filter must show album cards or a loading state.` | `unknown` | `navigation` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Back from the people list must return to the filter screen.` | `filter_selection` | `navigation` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Back from the album list must return to the filter screen.` | `unknown` | `navigation` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Focus must land on the target person.` | `filter_selection` | `focus` | [StrictE2EFilterTVOSUITests+Support.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests+Support.swift) |
| `Start Playback must open the playback screen.` | `unknown` | `navigation` | [StrictE2EFilterTVOSUITests+Support.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests+Support.swift) |
| `Clear selection must actually receive remote focus` | `filter_edit` | `focus` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `The editor's Done must actually receive remote focus` | `filter_edit` | `focus` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `After Clear, both target and non-target albums must really become unselected; re-tapping each card must not stand in for the clear result` | `filter_edit` | `control_state` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `The filter settings editor must offer a Done entry` | `filter_edit` | `navigation` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Finishing the edit must return to the real playback settings screen` | `filter_edit` | `navigation` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `Server B must clear A's album selection` | `server_switch` | `control_state` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `After switching servers the UI must not keep server A album/person IDs: ` | `server_switch` | `control_state` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `The display mode's selected state must be read back.` | `display_policy` | `control_state` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `No two distinct photos seen within four public album candidates; all failing originals are kept.` | `display_policy` | `scene_identity` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `After the change, a still frame taken mid-transition must not pass` | `display_policy` | `scene_identity` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `After changing the display mode, playback must still be on screen in the same live process.` | `display_policy` | `navigation` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `No two distinct target-album photos were seen in one full four-frame candidate rotation; all candidate originals were kept.` | `display_policy` | `scene_identity` | [StrictE2EFilterIOSUITests.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests.swift) |
| `After the change it must be a stable single photo from the target album, not a transition or multi-photo` | `display_policy` | `scene_identity` | [StrictE2EFilterIOSUITests.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests.swift) |
| `The same live app process must run before and after the display policy change` | `display_policy` | `process_lifetime` | [StrictE2EFilterIOSUITests.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests.swift) |
| `After the server switch, single-photo mode must show a stable single photo from B's target album` | `server_switch` | `scene_identity` | [StrictE2EFilterIOSUITests.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests.swift) |
| `The same process must run before and after applying single-photo mode after the server switch` | `server_switch` | `process_lifetime` | [StrictE2EFilterIOSUITests.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests.swift) |
| `SmartFill must expose the complete manifest, stable visible render state and history cursor together` | `visible_scene_capture` | `probe_readback` | [PlaybackHistoryIOSUITests+Support.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift) |
| `After tapping next, the fully visible SmartFill scene identity did not change in ` | `history_navigation` | `scene_identity` | [PlaybackHistoryIOSUITests+Support.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift) |
| `Pausing must freeze the current transform progress` | `paused_hold` | `scene_identity` | [PlaybackHistoryIOSUITests.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests.swift) |
| `The new scene from a manual next while paused must stay still at p=0` | `paused_hold` | `scene_identity` | [PlaybackHistoryIOSUITests.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests.swift) |
| `The scene from a manual previous while paused must stay still at p=0` | `paused_hold` | `scene_identity` | [PlaybackHistoryIOSUITests.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests.swift) |
| `Play must make the current still scene start moving from p=0 immediately` | `control_action` | `scene_identity` | [PlaybackHistoryIOSUITests.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests.swift) |
| `After starting playback, the playback page should open and show the control bar` | `playback_entry` | `navigation` | [FilterSummaryIOSVisualUITests+Launch.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Launch.swift) |

Dynamic leading step names, interpolated album/scene identifiers, bare assertions and
generic messages whose phase is ambiguous remain `unknown`. In particular, the recovery
flow's step-name-led photo checks and shared driver messages beginning with a press
count cannot be classified by this table. The complete-SmartFill-probe prefix diagnoses
combined evidence readback, without deciding which component is absent. Screenshot-empty
and Autoplay-setting prefixes retain their previous `unknown` pair. A mixed list containing
an unmatched message or different phase/class pairs still yields the `unknown` pair,
even when another message matches a new row. No hosted hit-rate improvement is claimed
until actual official failure summaries exercise these prefixes.

Still unknown on the throwing path:

- `Fixture image response control timed out` throws the `Failure` struct, whose
  `Failure(message:)` or direct caught-error wrapper is unsupported; it has no table row.
- `Can't check EXIF: photo status ` is recognized with the real `failed - ` wrapper
  from the pause-window's `XCTFail(error.localizedDescription)` path. Its throwing
  `AssertionError.message` form with the apostrophe escaped as `Can\'t` remains
  `unknown` for both fields. The EXIF mismatch's `failed - ` wrapper likewise keeps
  an unknown phase while identifying `exif_correspondence`.

Adding enum values also requires trusted readers containing the updated allowlists.
Older readers reject those values; a PR using a base reader from before this change may
therefore refuse an enriched failed/flaky-passed record until the updated reader is
trusted. Branch acceptance must run the report script (`ci_report.py --dry-run
--diagnostic-nightly`) from the PR head, or validate on the first `main` nightly after
merge; the installed older trusted report script rejects the new enum values and can
discard the whole attempt as unavailable evidence. Record fields, scanner
implementation, verdicts, populations and budgets do not
change, and every published value remains code-defined.

The separate simulator creation/preparation steps also publish compact records on
failure using `--preparation-failed`: each declared case is failed with a `not-run`
attempt and an infrastructure reason, with no claimed compilation or execution.
The [nightly accounting policy](CI_NIGHTLY.md#population-and-capacity) describes how
aggregation and trusted reporting retain these failures.

CI uploads compact records plus the scanned P2 recording, recording timing proof
and SHA-bound hashes. Screenshots, fixture originals and review-package formats
belong to the separate visual-review work. It never uploads raw `.xcresult`, DerivedData, package clones,
simulator contents or unscanned logs. Raw bundles follow the existing disposal,
quarantine and sensitive-scanning rules under the export bounds above. Recording evidence is retained
for seven days; records use 30 days for PRs and seven days for manual runs.
The tracer removes its build/package directories after its children exit, and the
workflow removes its dedicated simulator and remaining task output after upload.

The two standalone access-protection runners are explicitly excluded in the tracer
manifest: iOS is unstable on main, and tvOS creates a transient isolated Release
scheme. They inherit the reset/environment filter, but keep their local 1,200-second
and existing per-run build behavior. No warm access-protection coverage is claimed.
The strict suite table's small `*-lifecycle-*` cases remain eligible for explicit
Release warm shards. A full nightly matrix must retain these exclusions until the
standalone runners are converted. No repository settings, environments, secrets,
approvals, required statuses or release policy are configured by this tracer.
