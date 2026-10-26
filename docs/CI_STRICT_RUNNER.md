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
The lifecycle pause flows distinguish transition onset from stable new-photo
confirmation; the shared definition and the unchanged platform-specific timing
bounds are documented in [Testing conventions](TESTING.md#running-controlled-integration-and-end-to-end-tests).
Simulator preparation and official exports have explicit phase deadlines; timeout
records and private quarantine follow the [nightly infrastructure policy](CI_NIGHTLY.md#population-and-capacity).
The shared preparation gate caps `simctl boot` at 60 seconds and gives boot,
bootstatus and responsive app queries 600 seconds total. Post-boot queries use at
most 300 seconds within that gate. The [shared reset](#shared-simulator-reset)
then starts the separate 120-second app/keychain/privacy reset clock;
individual reset commands have at most 60 seconds. Local strict,
fixture UI, listed retry and access-lifecycle runs use these preparation bounds too.
Strict preparation never opts into the optional
[UI boot-settling gate](CI_UI.md#fixture-execution-retry-and-public-output),
including hosted scheduled and manually dispatched runs with an early boot.
The hosted canary added about six minutes before strict cases, yet their host
idle medians remained zero under the test workload; waiting before strict did
not provide sustained resource headroom. Shared readiness and reset bounds stay
unchanged.

Official tests and summary exports each have 60 seconds. Unit callers retain
`unit-results-timed-out` with export phase and elapsed time; strict callers retain
their preparation/export phase codes. Test-execution budgets are separate.

Strict builds use their own test plans and settings; they do not consume the default
unit/UI archives. They reuse the [archive workspace preflight](CI_BUILD_ARCHIVE.md),
product inventory and signing inspection. No competing archive producer or artifact
selection mechanism is introduced.

The dual-server `filter-switch` (iOS/iPadOS) and `tvos-switch` contracts also carry
the former standalone server-switch display guarantees. Each records A playback,
B save success, the cleared filter editor and real B UI identifiers, then checks
every A/B photo slot by glyph, color and axis. A continuous recording covers the
flow. On B, real Next actions traverse at most four target-album candidate frames;
every sampled original is retained, and the first real
multi-photo frame becomes `display-before.png`. Exhausting all candidates without
a qualified frame fails. A real Settings change must produce a stable B single
photo in the same live process. Candidate numbering, raw-byte identity, album
membership and the finite denominator are checked by the display-policy contract.
That finite-candidate validator is the sole display-policy authority for merged
switch evidence. Merged switch runs require the original before, Settings and after
screenshots; the report keeps its `display` fields and nested `finite_rotation` result. After
identity is read from the validated foreground when the frame has its matching
blurred surround, rather than from obsolete whole-frame color proxies.
Standalone A uses its original before/after PNGs plus real-UI and same-process metadata.
Fitted single-photo candidates retain their place in that rotation and use the
existing matched-foreground/blurred-surround gate before slot reading; they never
qualify as the multi-photo before frame.
The merged switch contracts read every intermediate candidate per slot, including
its server glyph. Mixed servers, unreadable slots and transitions fail the run
immediately, even if a later candidate could qualify. The standalone display-policy
contracts still treat an unqualified intermediate frame as a candidate to advance
past; the merged switch rule is deliberately stricter.
Fixture B contains eight distinct public synthetic photos. Its ordinary target
album contains B1/B2/B3/B6/B7/B8; B4/B5 remain outside that album, and every person
set is unchanged. B6/B7/B8 mirror A1/A2/A3's landscape, portrait and square sizes.
The maintainer chose this larger pool to model normal usage: a three-photo pool
is an extreme condition. The iPad small-pool limitation remains open in
[#487](https://github.com/sudoHG/immichSlides/issues/487); this fixture change does
not fix it. The four-candidate denominator, deadlines and isolation checks remain.
A and C, and B1–B5's image bytes, remain unchanged.

B6–B8 use two RGB endpoints per identity, matched as a pair within tolerance 12
in both the Python and Swift readers, rather than the original A1–A5 hue scoring. This adds
endpoint-pair scoring and the shared A6–A8 color labels without changing the
existing tolerances or confidence thresholds. A B frame rejected as
`unreadable public glyph slot` or `mixed public glyphs` can indicate a collision with system
chrome: first compare the failing slot's pixels and surrounding controls/EXIF
against both identity endpoints. Preserve the original frame and its slot/axis
exception; do not change tolerances or exclude the frame. The measured collision
history and corpus are in [#486](https://github.com/sudoHG/immichSlides/pull/486).

Whole-frame A1/A2 matches additionally require both real RGB palette endpoints
and clear public row texture from the same PNG. Support and row coverage are
measured inside the detected sharp foreground rectangle, independently of the
blurred surround and screen width. The readers reuse tolerance 12, minimum
support 18, observed row coverage 85% and texture cell drift 2 pixels.
Only one qualified candidate above the existing score floor can confirm an
identity; multiple candidates remain a transition, and missing evidence stays
unrecognizable. Blurred background colors, generic green/gray and a faded frame
without its true RGB pair cannot confirm a new photo. Original black, dark-wash,
score and ambiguity gates still run first. Independently verified composite
rectangles retain their existing interior hue check and complete canvas gates.
Striped candidates additionally need a sharp edge between their actual RGB
endpoints, with at most the existing two-pixel unknown band. A blurred stripe's
monochrome rows alone do not establish clear foreground texture.
The stripe edge check reuses the identity reader's 96-pixel width, so normal
display upscaling does not inflate a sharp source edge. Palette support, row
texture and composite sampling retain their existing 480-pixel cap. An additional
half-resolution probe, capped at 240 pixels wide, locates contiguous sharp
palette runs before the original texture checks. Its rectangle needs the existing
minimum image extent and at least 18 supported pixels per boundary/interior line;
missing interior lines may span at most two probe pixels. White glyph ink can
support rectangle continuity but cannot qualify a texture row. A bitmap whose
entire canvas supplies public palette colors or white ink keeps its original
bounds; fitted captures derive their bounds from independently supported lines.
A zoomed photo interrupted by overlays can retry the complete viewport only
when independently supported sharp runs reach both side edges and every pixel
in its top and bottom 480-wide sample rows supplies the same palette or white ink.
This candidate still passes the unchanged line continuity, RGB pair, row texture and stripe-edge
checks; the retry grants no overlay mask or weaker threshold.
The same viewport retry can mask a partial-height vertical seam inside a zoomed
photo: supported rows above and below the seam can restore its column support,
just as they restore antialiased glyph-edge columns. No additional seam criterion
is applied.
Candidate palette proof reads the PNG's encoded RGB channels in both languages;
display color conversion must not change those values for a tagged video frame.
The existing composite reader keeps its original color conversion.
A narrow region can reuse qualification from the existing full-reference
foreground when its original hue verdict agrees. Alternatively, the same PNG
must pass the unchanged complete two/three-slot composite reader and independently
prove the candidate's sharp texture; the region must supply both RGB endpoints,
no sufficiently supported foreign palette, and one candidate above the existing
score floor. A generic single-photo whole-frame match cannot supply either
provenance. The filter's original surround checks still run before region checks.
For single-photo display-policy validation, the full frame and center, upper,
mid-left and mid-right regions must qualify positively. The left/right margins
may contain the same photo's glyph-free blur: their ungated hue verdict must
agree with the qualified photo, so foreign colors, black and unknown strips
still reject. These margins never acquire a positive single-photo identity.
A new side-band probe uses the existing 240-pixel sample width, minimum sample
height, black-luma threshold and two-line continuity allowance. It rejects only
dark bands spanning the full strip width or height for more than two consecutive
sample lines. A local black block inside a strip can still pass, as can a
same-palette A2 blurred background beside B2; both also passed before single-photo
qualification was introduced.
Evidence used to reject a side partner, an out-of-album photo or an old nonempty
pool uses the ungated hue reader, so qualification cannot hide visible defects.
The shared Python/Swift candidate corpus keeps small portrait-fit controls for
A1/A2 and B1/B2, plus six representative fits generated at device dimensions and
sampled to 480px with NEAREST: A2 on iPad portrait (1640x2360) and landscape
(2360x1640), A1 on iPhone landscape (2532x1170), and B2 on tvOS landscape
(3840x2160), all without overlays at motion scale 1.00; A2 and B2 on iPad portrait
at scale 1.10 retain blurred side margins while the foreground overflows vertically.
These representatives cover the iPad A2 foreground that occupies only 81% of the
portrait width, rather than the complete geometry/photo/motion cross-product.
Background-only rejection remains covered by A1/B1 and the native A2 TV-bar case.
For original 3840x2160 tvOS captures, sharp-foreground continuity and texture
checks ignore the scanner-approved shared color/glyph rectangle
(1256,1436)-(2580,1925). At 1920x1080 the rectangle is (628,718)-(1290,963):
the bar was measured locally, while the hint area is scaled from 4K and was not
observed in the HD inputs. These pixels supply no palette counts or sharp edges;
fully occluded lines supply neither support nor a missing-photo gap. The same
rectangle is mapped into the sampled frame and translated with each foreground
crop. Other dimensions and region crops grant no sharp-foreground exclusion. In particular,
iPhone landscape has no measured entry, and the portrait phone's glyph-only
box grants no palette exclusion. EXIF uses the same reader without waiting for
controls to hide; the six-Next limit and existing deadlines remain unchanged.

The iOS Next driver captures the baseline photo, then issues at most one proactive
wake before preparing the control from a fallible snapshot.
The final snapshot must identify an enabled button with a nonempty frame inside
the window, a visible control bar, and no Settings navigation evidence. It does not
require the optional playback-marker probe. Its frame supplies the sole coordinate tap;
there is no live hittability query or element tap that re-resolves the button.
Snapshot geometry establishes readiness; an observed photo change is required to
pass. This existing check does not establish forward direction. Baseline scene
identification and final readiness share the original 4-second preparation budget,
excluding only the measured canvas-wake duration. Readiness after wake return gets
the pre-wake remainder, not another full preparation window. The outcome window
starts at tap return, lasts at most 4 seconds, and ends within the original
8-second total plus that same measured wake duration. The actual Next tap still
consumes the total ceiling; late snapshots/captures do not pass. Wake delivery,
including XCTest post-event idle, is recorded separately as reveal/action timing.
Image-failure recovery locally prepares Next and redo without the playback probe:
one preparatory snapshot must exclude Settings navigation, then at most one wake
precedes a fresh snapshot of an enabled Next button with a nonempty frame inside
the window. Every preparation poll also excludes Settings navigation evidence.
That frame supplies exactly one coordinate tap, with no live button
query. The original 6-second preparation budget includes the wake. Its stable-photo
outcome starts at tap return, retains the 45-second limit, and is capped by the original 51-second
preparation-plus-outcome total. Recovery still requires an observed advance and the
exact redo photo identity. The shared control-bar tap helper is unchanged.
Neither path retries a tap or a whole flow.

The Swift `captureIdentity` and Python `capture_identity` readers locate each
photo's palette rectangle, rather than assuming equal quadrants or full-span strips. They use
the public fixture RGB pairs, the same tolerance 12 and minimum 18 matching pixels
per line, and a nearest-neighbour sample capped at 480 pixels wide. A composite
requires two or three distinct, non-overlapping rectangles that tile their canvas.
That canvas must cover the image center and fill at least one image axis; each
slot needs clean rows and columns. The legacy readers classify an interior crop
of each rectangle and retain their existing results, including unequal doubles,
balanced triples and all four primary-plus-pair triple orientations. Swift first
runs this unchanged legacy capture path. Only a legacy TRANSITION is eligible
for an additive `strictCaptureSlotMarks` check. Successful strict proof returns
MATCH with the slot marks and the single note `strict-multi-slot`; rejection
returns the legacy result unchanged.
Legacy MATCH, UNRECOGNIZABLE, BLACK and BLANK results never enter the new path.
The region readers and complete-scene inheritance retain the legacy contract.

The strict fallback verifies every complete slot's public texture and bitmap
letter/digit, rather than its glyph-heavy interior crop. Missing interior lines
can join only matching neighbours; an entirely black outer edge contributes no
identity. Mixed slot lines, overlaps and gaps reject strict proof. The fallback
follows the strict Python reader's clipped checker boundary rule below:
one missing sampled line must belong uniquely to
one adjacent photo's palette interpolation across the entire shared span. It
cannot mix the two photos' palettes along the line or use cross-photo RGB
interpolation as proof. Black seams and wider gaps remain rejected. Identities
use top-to-bottom, then left-to-right rectangle order.
Strict rejection cannot revoke a legacy acceptance. In particular, crossing
rectangles can still fall back to a dominant legacy whole-frame mark, and nested
overlays keep their legacy classification. For Next, the comparison sorts all
slot marks, preserving multiplicity, so rearranging the same photos cannot prove
a change. Single-photo marks and all
control actions, deadlines and waits are unchanged.
Changing to a subset or superset still counts as Next: SmartFill can reuse the
current photo as an auxiliary or collapse to one slot. An in-place rearrangement
that also changes the slot set could therefore satisfy this pixel comparison.

Strict-fallback chrome handling mirrors Python `PUBLIC_SCENE_GEOMETRIES`: color and
glyph exclusions are independent, scaled outward to the 480-wide sample and
translated into each slot. They cover the measured iPhone control bar, iPad
home indicator or EXIF panel, and TV control bar/entry hint. Unknown sizes get
no exemption. Glyph fragments join only across gaps wholly inside the measured
box; a bottom-clipped glyph can estimate square cell width from surviving
first-row strokes. Visible cells and digits must still agree with the texture.
The shared `immichSlidesTests/Fixtures/public-photo-identity-cases.json` table
constructs the same checker cells, glyph origins and defect boxes in the Swift
reader suite and `scripts/test_strict_e2e_photo_identity.py`; the table compares
Swift's strict fallback entry with Python `public_frame_photos_from_bytes`.
Each row also asserts the Swift pre-fallback reader's status/mark against
`swiftLegacy` and independently asserts the additive Swift `captureIdentity`
verdict. Python asserts its independent `capture_identity` result against
`pythonCapture`. The Swift test records any pre-fallback MATCH that Python does not
accept with the same mark, and asserts that this set is exactly `stacked-checker`,
`stacked-following-checker`, `stacked-foreign` and `stacked-mixed`. These four synthetic
stacked composites remain a pre-existing reader gap not closed by this change:
Swift accepts A2 while Python returns TRANSITION. Any added or resolved divergence
fails the exact-set assertion. Full capture-reader equivalence does not hold.
Strict rejection does not override legacy
MATCH, and strict proof cannot supply complete-scene inheritance candidates.
Native sizes and all parity rows remain
intact; the Python test draws and caches identical 48-pixel background rectangles
instead of generating and encoding every background pixel in Python.

Intentional differences: both legacy capture readers retain their interior hue
check and cross-photo seam interpolation. The display-policy validator's region
path still uses Python `capture_identity` through `_complete_scene_candidates`;
filter-switch scene validation uses the stricter `public_scene_photos_from_bytes`.
Existing region-contract synthetic pairs stretch square source glyph cells into
rectangles, which the strict readers reject. App SmartFill placement preserves
the source aspect ratio; those synthetic frames are region-contract inputs,
not evidence of App output. Legacy capture also preserves cropped-glyph T layouts,
fractional seams and the dark-top stand-in that the strict reader rejects.
These acceptances are not claims of strict Python parity.

The strict Swift fallback retains rectangle segmentation for real iPad/TV primary-plus-pair
triples; the strict Python full-span axis reader cannot represent those layouts.
It requires a texture pattern in every slot and a sharp stripe for B slots;
Python's multi-photo path permits an unknown texture pattern and does not require
stripe sharpness. Qualified public fixture slots satisfy both Swift checks.
It also accepts stacked mosaics with black borders along the stacking axis
when the canvas fills the other axis; Python's full-span reader rejects them.
It bounds consecutive unsupported interior lines by the single-photo
half-resolution probe and shared texture drift constant (at most four rows at
480 scale); Python joins any length bracketed by the same photo. The existing
eight-pixel cyan-band T-layout negative remains rejected by strict proof. These helpers ship
only in test targets.
The unchanged single-photo fallback has a pre-existing near-endpoint residual:
blend 80% of a sharp stacked A2/A1 frame over 20% of a sharp stacked A3/A2
frame (480x1040, equal slots, public `_png` fixtures). The bottom palette falls
within tolerance 12 of A1 while the top supplies no second exact palette, so
both the old and current Swift reader return MATCH A1. At 20% incoming the same
case is TRANSITION; at 50% it is UNRECOGNIZABLE. This change does not tighten
single-photo qualification or claim that tolerance-admitted near-endpoint blends
can always be distinguished from one static photo; see the boundary residuals below.
The scanner's existing unique same-photo interpolation is used only within its
existing eight-raw-pixel outer edge band, preserving clipped texture edges.

Fixture-A suites also accept A6–A8 through the shared reader vocabulary even
though fixture A contains only A1–A5. This is intentional for this change: the
RGB-pair collision risk is low, and every A frame retained its original
classification in the corpus. The access partner guard uses the actual fixture
pool; the other shared-vocabulary membership checks are unchanged. Per-fixture
membership checks remain a possible follow-up.

The nightly matrix runs only these merged identities; the standalone selectors
and suites have been removed. This does not resolve the pixel-coverage limits
tracked in #434.

`filter-edit-switch` checks both the original whole-frame color identity and each
full-span photo slot against the non-target album's fixture-specific classifier labels. Public
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

`tvos-person` loads the active fixture from `member-manifest.json` and requires
the complete frozen manifest before judging normal, conflict-normal and no-faces
frames against that fixture's glyphs and membership. The runner also requires the
manifest fixture to equal its requested fixture. Missing or invalid manifests
fail closed. Simulator Vision soloOnly results remain `UNVERIFIED`.
Shared scene-reader failures retain their original diagnostic prefix and append
the screenshot basename, slot index and axis when known. Segmentation failures
identify the rejected axes; an unresolved partition reports no guessed slot index.
Foreign-fixture frames report the observed public fixture letter and total slot
count. Context contains only public filenames, fixture letters, indices, axes and counts.

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

Before the initial `tvos-flow` Pause, control-bar readiness and the complete stable
scene share the existing 30-second playback-entry deadline. Each scene poll reads
one fallible App snapshot, and the final observations are attached as
`tvos-entry-capture-window`. Pausing during the initial fade freezes its incoming
layers, even when their opacity has already reached one; that state cannot serve
as the stable history anchor. The single Pause, four-second pause readback,
history-count precondition and capture-time pixel/manifest proof remain unchanged.

`UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE=1` enables the Debug manifest probes.
Probe-only launches are `album-empty`, `filter-person`, `journey-b`, `tvos-flow`, `tvos-person`, `ios-lifecycle-first-wake`,
and `AccessLifecycleIOSUITests.prepareLaunch`, including its cold relaunches and
`run_access_lifecycle_ios.py`'s `testAccessProtectionSettingsAndLifecycle`.
Only iOS `album-empty` sets the real playback interval to 30 seconds through `IOSDriver`
immediately after filtered playback starts, before preparing Pause. Settings are not
reachable from the first-boot filter summary. An already-created target retains its
frozen interval. Debug `album-empty` polls for valid non-empty progress probes and
confirms the current stable target's `motionRawProgress` slope from the existing
`slideshow.scenePresentation.frameSynchronized.summary` leaf with two samples at
least 1 s apart, retaining the same layer identity and history count. The expected
rates are 1/5 and 1/30 per second. The accepted range, 1/60 through 1/15, allows half
to twice the 30 s rate while excluding a frozen probe and the 5 s rate. The scene
probe has no timestamp, so the slope uses monotonic snapshot request/return midpoints
and the actual elapsed time. This absorbs a longer sampling interval under starvation,
but not an accessibility label that lags the rendered timeline; a lagging label can only
fail closed (an unchanged-short-target timeout, or a later Pause-window rejection).
The root contract label can cache progress between state changes; the frame-synchronized
leaf follows the rendering timeline. Both labels and the manifest come from one snapshot.
If the baseline is already a 30 s target, no advance is required. A measured short
target must give way passively before its replacement is sampled again. Baseline
reads, target changes and slope confirmation share the original 12 s setup ceiling:
5 s old target + 2.025 s transition + 1 s sample pair + 3.975 s scheduling margin. If the
old target committed just before the slider was saved, its own 2.025 s transition also
precedes the stable period, so the worst-case margin is about 1.95 s plus the return
navigation time.
Timeout sentences distinguish unreadable probes, an unchanged short target and
an unconfirmed slope. No preparatory Next is issued.
`filter-album` retains its original interval, launch environment and probe-free
Pause preparation. Its first-capture race remains a follow-up blocked on the Swift
multi-photo identity false negative; it does not gain a Swift identity-reader dependency.
Product timing and film-like Pause semantics remain unchanged.
For Debug `album-empty` and `filter-person`, the existing 8 s Pause-preparation window must prove a
stable complete scene and an actionable Play/Pause target together before the
single Pause. Live hittability is checked before the final stable window snapshot;
`album-pause` evidence records that snapshot's request/return and the Pause tap's
issue/return times. Its existing 4 s readback requires the paused probe and button
value `play` in the same window snapshot. Each playback
capture first preserves the original minimum 0.8 s settle, then checks the scene
within the remaining 4 s of the same 4.8 s preparation deadline. Before publishing
one PNG, two full-resolution decoded color frames must match exactly, with the
second screenshot requested at least 0.6 s after the first returns. A mismatch
replaces the comparison baseline and samples again only within that same deadline;
timeout fails instead of publishing an unsettled frame. The identical probe-free
pixel check also runs for Release `album-empty` and `filter-person` (neither in the
nightly matrix; NOT_RUN locally) and all `filter-album` captures,
with the same 0.8 s minimum settle and 4.8 s total budget. The public photo-identity
validator remains mandatory: identical pixels alone cannot prove a valid scene.
For `filter-person`, this replaces a fixed 0.8 s wait followed by up to 4 s of
control reveal with a 0.8 s minimum settle and up to 4 s of scene/pixel observation.
The 4.8 s ceiling is unchanged; the window allocation and required evidence differ.
Release `filter-person` uses ordinary Pause and the probe-free pixel check, with
controls revealed before the capture window. Debug `filter-person` retains the
default 5 s playback interval and reserves no remaining-interval headroom between
the stable check and Pause. A slow check plus tap can therefore enter the next
transition; a frozen transition fails red as `control_action/control_state`.
The stricter Pause-preparation wait's yellow-eligibility change is documented
beside the allowlist in [CI summary](CI_SUMMARY.md#prepared-hosted-strict-environment-limits).
For `filter-album`, widening its former 0.8 s fixed wait to at most 4.8 s is an
approved relaxation of a test-only wait, not a product contract. Controls are
revealed once before starting the 0.8 s settle floor and the following 4 s pixel
window; revealing controls remains outside that capture budget, as on main.
The scene probe can settle before the retained EXIF card finishes its separate
fade; logical EXIF visibility does not prove that the old card's pixels are gone.
The second capture also requires history to advance by one or different layer IDs.
Post-Pause transitions get that capture budget to recover, including the designed
fill-in fade. On timeout, the first capture (`album-play-1`) reports a last-observed
paused transition with the frozen-transition prefix (`control_action/control_state`);
other incomplete first scenes fail as `visible_scene_capture/probe_readback`.
For `album-play-2`, a Next with no observed history advance or last-observed layer
change fails as navigation; an advanced but incomplete scene fails as probe readback,
including a paused transition. History advance remains recorded across polls, so a
later failed snapshot cannot erase it. Navigation and probe-readback failures append
history-advance, last layer-change, phase, paused and manifest-completeness facts
after their reviewed prefixes. The pixel validator still decides photo identity.
For `tvos-person`, the scene key also exposes the existing read-only SmartFill
manifest, motion-frame summary and EXIF tone accessibility anchors. These clear
anchors read existing state; they do not change photo rendering, transition clocks,
auto-hide deadlines or playback commands. Motion trace collection requires its
separate key and is not enabled. Their extra accessibility/label computation is
diagnostic overhead, not a product timing override.
The `ios-lifecycle-settings`, `ios-lifecycle-pause` and `ios-lifecycle-background`
selectors use an empty launch environment and forbid the scene probe.
`ios-lifecycle-pause` pauses initial SmartFill playback through the real controls
before opening Settings; configuration still turns autoplay on through the real
toggle and selects single-photo mode. Before its midpoint pause, it confirms the
paused state, uses a real Next and the existing stable-photo capture window to
establish a bright single-photo identity, then starts T/2 at the real Play press. Pause
tap must return before the existing T-2 boundary and retain that identity. The
pause timestamp is recorded before the later state readback; Continue still counts
T from its press until the old photo starts fading. Play/Pause preparation issues one
canvas wake, then uses one fallible window snapshot per poll for button identity,
enabled state, a nonempty frame inside the window and its current value. These are
snapshot readiness checks, not live hittability queries. An already ready snapshot
is reused for the sole coordinate tap; its effect is proved by snapshot readback.
The original 8-second appearance, 2-second readiness and 4-second state windows
remain independent and fixed. A late snapshot fails, and readback never wakes or
retaps the controls. The shared `IOSDriver` Settings query path is unchanged.
Settings return has no known scene-clock origin and cannot start that wait. The setup
capture is `timing-start.png`; the ordinary paused-frame identity, T+2 hold and
Continue T±2 checks retain their existing deadlines and criteria. A legal frozen
fade is still covered by `pause-window`, rather than admitted as a stable photo.
`tvos-lifecycle-pause` anchors T/2 to a newly confirmed stable public photo. Its
midpoint setup pools the existing two control/focus allocations, conditional
playing-state readback and half-cycle under one absolute deadline. Both visible
and hidden-bar paths poll Play/Pause focus until the anchored T-2 boundary; only
the hidden receiver gets one wake. One Select must return and change the button
state within that same deadline before the before-pause capture. It never retries
Select. The photo-identity, paused hold and Continue T±2 checks remain unchanged.
`pause-window` sets the probe plus `UI_TEST_SERVER_URL`, `UI_TEST_API_KEY`,
`UI_TEST_RESET_STATE`, `UI_TEST_FORCE_MODE_SELECTION` and
`UI_TEST_PAUSE_AT_AUTOMATIC_FADE_MIDPOINT=1`. The last key enables a Debug-only,
one-shot pause at the midpoint of the first automatic fade-out after the first
user Play, through the same command as the user's Pause. Automatic fades before
the first user Play cannot consume the hook. The UI test polls only the frame-synchronized probe
until it reports paused with 0 < outgoing opacity < 1 and incoming opacity 0,
then captures the frozen frame and verifies its identity, opacity and motion
through the existing 0.3-second hold. Before Play, `a2-stable-before-play.png`
must qualify as the ordinary full-bright A2 photo and match its visible EXIF.
Frame-synchronized probes bracket that paused, opaque capture. Its single layer
reference must become the midpoint's outgoing reference; no asset ID substitutes
for the bright PNG's pixel identity. The verdict records the actual outgoing
opacity and the probe-derived paused state; a delayed midpoint callback still
counts when it freezes a translucent outgoing frame. Exact screenshot pixel comparison reuses
the paused-photo comparator's existing chrome exclusions and minimum compared
area. The midpoint PNGs carry the freeze contract, rather than ordinary stable-photo
qualification: all bracketing probes must retain the same paused translucent outgoing
scene and hidden incoming scene, and all three PNGs must retain identical photo
pixels. Black, blank, unreadable, TRANSITION and recognizable wrong-photo midpoint frames fail.
The unchanged rejection-only hue reader rejects a different public mark even when
dim; it never supplies positive identity or stable-photo qualification. EXIF at the
fade boundary may already describe the incoming photo; only the bright
proof carries EXIF correspondence. A complete A3 observed after the hold still fails
as LATE; incoming EXIF text alone does not. No palette, luma or qualification threshold changes.
`pause-window-contract.json` records the bright capture and each midpoint capture's
before/after probes, window frame, expanded chrome exclusions and hierarchy-read
problem. Python requires this sidecar and the bright PNG, independently compares
the original midpoint pixels with those exclusions, and rejects comparisons covering
less than the existing 50% minimum. Missing evidence fails closed. These are current
run inputs, not retained-night summary fields. Probe/contract failures record their
own capture PNG; pixel comparisons record the current candidate PNG, rather than
whichever frame was classified last. Whole-contract failures use window-detected;
bright identity, EXIF and probe failures use the bright PNG.
Preparation uses the existing control-bar tap helper before Next and Previous.
Immediately before each Play/Pause snapshot, one unconditional playback-surface
wake refreshes auto-hide within the same existing 4-second budget; no polling
iteration wakes again. A fallible snapshot and live hittability check prepare the
real target. Play's existing 7-second probe clock starts immediately before its
single action, and state readback retains the original deadline. Post-settings
Play preparation has its own failure message.
It no longer checks whether a human tap can land inside the fade window;
`AutomaticTransitionPauseTests` covers the reducer's pause semantics. Release
compiles out the timer and pause action and returns false for the launch flag.
`tvos-directional-wake` sets those four legacy keys plus
`UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT`, and does not set the scene probe.
Other probe-key launches are the configured SmartFill launch helpers in
`PlaybackHistoryIOSUITests`, `ScenePresentationContractUITests`, and
`FilterSummaryTVOSVisualUITests.testTVOSSlideShowControlBarButtonsCanActivateOnSelect`.
They also set other `UI_TEST_*` keys, so their XCTest mode remains enabled.
The `late-image` case also combines the scene probe with
`UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT`. That hint key enables XCTest mode: the
API key can be restored from the UserDefaults XCTest fallback after cold launch,
and the Info.plist debug server is skipped. This case therefore does not prove
Keychain-only restoration. Image requests still use the ordinary download path.
The runner's launch audit is a **static declaration of Swift launch keys**,
labelled `declaration_kind=static_swift_launch_keys`; it is not read from the app.
This declaration is not compared with any runtime launch keys. Comparing it
against Swift's xcresult launch-key attachment remains tracked in #434.
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

These scene contracts, `tvos-edit-switch`, both A and B frames of server-switch, and
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

At a boundary between different photos, segmentation may omit exactly one
unassigned sampled line when its immediate neighbors independently identify
different palettes. Every unmasked pixel on that line must uniquely resolve
through the existing same-photo interpolation reader to the **same one** of
those adjacent palettes, with at least 18 observed pixels. This permits clipped
checker or stripe edges and can also admit a single-line cross-photo blend
within 12 levels of the permitted interpolation. It supplies no slot, texture
or glyph evidence. Unknown colors, a third palette, mixed adjacent palettes
within the line, non-exact or fully masked neighbors, and two or more unassigned
lines remain unreadable. Full-frame blends without exact runs cannot use this
exception. Color-excluded pixels supply neither color checks nor observations.
The allowance is one sample line at every size: the reader uses NEAREST,
which cannot spread one input line over multiple samples during downscaling.
The motivating 1170x2532 capture has exact A3 through raw y=907, an A3 checker
interpolation at y=908–911, and A2 from y=912. At 480x1039 only sampled y=373
hits the interpolated band. The synthetic regression recreates these positions
on both sides of the existing palette and glyph checks. The sample step is
about 2.44 raw rows, while that band spans four raw rows: a different crop can
put two samples in the band and still fail. The rule remains one sampled line.

This boundary rule does not tighten existing limits. Exhaustive gamma-space
RGB analysis over continuous alpha 0.2–0.8 covers every A1–A8 endpoint-color pair
and both directions; the per-pair exact and segment assignments are in the
generated table in PR #577. These residuals are pair-dependent, not confined to alpha near
zero or one. With lexicographically sorted color indices, the A7 color 1 / A8
color 0 blend is exact-assigned throughout 0.2–0.8 (A7 through alpha 0.5, then A8).
A6 color 1 / A7 color 1 remains exact A6 through alpha 5/16; A2 color 1 / A4
color 1 remains exact A2 through alpha 25/68. A1/A3 also has segment-only
single-line acceptances. Exact assignments take precedence, so bands already
inside palette tolerance are not universally rejected; two or more unassigned
blend lines remain rejected. The existing same-photo unknown-line fill remains
unchanged. An overlay within 12 levels of the permitted interpolation can be
indistinguishable from a checker or stripe edge in a static PNG. Frozen push or
slide transition frames likewise cannot be distinguished from static layouts,
including subpixel seams. The numerical analysis assumes gamma-space channel
blending and round-to-nearest RGB; the measured texture sample supports this
model, but opacity compositing was not verified. NEAREST can miss a raw band
entirely, as noted above.

The pinned Apple TV 4K (3rd generation), tvOS 27.0, produces **3840x2160** PNGs.
Scanner-approved frames measured the A2/A3 seam at x=1382 and the A5/A3 seam at
x=1536. The entry hint and playback controls fit inside (1256,1436)-(2580,1925),
including a four-pixel margin; tvOS has no home indicator. Only measured scene
captures exclude that bounded rectangle from palette and glyph evidence. It
cannot hide a full-height or full-width slot. Overlay ink cannot create bitmap
bands or supply observed cells; letters and digits must still agree with every
remaining cell and meet the unchanged evidence minima. The device-pin guard
requires a measured geometry for all three pinned strict devices.
Two non-pinned local device types supply additional exact-size geometries below.
Hosted CI does not produce either 2064x2752 or 1920x1080: its pinned iPhone,
iPad and TV outputs are 1170x2532, 1640x2360 and 3840x2160. The pinned-device
runs are regression checks only, not proof of a hosted fix; every replayed
3840x2160 frame already passed the base reader.

Local Debug `tvos-flow` B and `tvos-person` A runs on the Apple TV 4K
(3rd generation) **at 1080p** simulator type produced the 1920x1080 originals.
They register the same point-space hint/control rectangle, rounded outward
from the 4K coordinates. The bar (632,858)-(1288,960) was measured in these
frames; neither contains the hint. The HD hint band at y=718-858 is scaled
from 4K, rather than measured or scanner-approved in HD. In the original B4 flow
frame (SHA-256 `581e539f2f1e36093425a950eec690a1f93734182e9c13e2303f84ecf5bb76e2`),
the bar's lower glass edge aliases A2 in sampled rows 235/237. In the original
A3+A5 person frame (`341e2760950bcc2a96f25e1e9afebf98e4ff5fe79209984d5f5e5a6bb91ebaf0`),
the focused Next pill supplies an extra white band in slot 2. Both retain clear
photo glyphs above the bar; the scaled hint mask clips A3's lower rows in the
person frame, which exercises cell-scale inference. HD qualification mirrors
the same rectangle in Swift. Existing 1920x1080 synthetic access-lifecycle and
album-contract frames also pass through this HD mask.

A local Debug `journey-b` B run on an iPad Pro 13-inch produced the 2064x2752
EXIF original. Only its measured panel (1308,60)-(2004,442) is excluded from
palette segmentation and texture, with no glyph mask. This box was measured
from one B3 frame: the right-aligned panel's width depends on its EXIF text,
so another photo at this size can still fail closed outside this box.
The original single B3
(`67c7d5aa96b6998de36482b08a23682bfe27f2ef8193567126728c0162dcaea8`)
has 142 false A8 pixels in sampled row 102, entirely at that panel's lower edge.
This entry does not infer EXIF bounds at other sizes or affect sharp-foreground
qualification. Public-fixture reconstructions cover the EXIF palette alias,
HD flow palette alias and HD person glyph obstruction. Each rejects controls
above the box and a one-pixel-taller frame; EXIF also rejects an alias below
the box, and the person frame rejects white ink left of the HD box. Only the
person reconstruction has wrong-letter/digit, mixed and partial-occlusion
glyph negatives; its partial occlusion preserves A3's top strokes and letter.
When a measured overlay splits a glyph, ink fragments are joined only across a
gap wholly inside that overlay and within one palette slot. The ten-pixel band
minimum is applied after joining; short unjoined fragments remain excluded.
If the overlay clips the bottom of a glyph, surviving complete top-row strokes
can also recover its square cell scale. Candidate generation bounds the inferred
bottom to the same measured overlay and slot; these bounds limit the search.
Acceptance is gated by agreement with every observed letter and digit cell and
the existing observed-cell and white-cell minima. No additional pixels are
excluded. The native-size B3+B8 phone regression
reconstructs the hosted scene from public fixtures, rather than treating its
downscaled failure projection as original pixels.

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
rejection checks are unchanged. `tvos-album-empty` reads every playback slot with
the shared scene reader (glyph, color and axis), including B3/B2 double images.
It retains both required captures, different visual identity sets, target-album
membership and every empty-result check. Its public failures retain the reader's
slot/axis context without introducing new screenshot names into the receipt grammar.
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
Playback reader failures retain the rejected `album-play-1.png` or `album-play-2.png`
name in their public message, including when bounded diagnostic image collection is unavailable.
File-read failures remain I/O errors. tvOS reports retain their existing fields.

## Deterministic late-image response ordering

The `late-image` suite arms `/api/test/late-image` after normal first-boot setup.
Only loopback clients with the existing public fixture key can use this control,
and only in the `out-of-order` scenario. The cold-launch case posts
`{"action":"arm","selection":"initial-primary"}` to select the first asset in
the frozen fixture (A1 or B1). The server holds its first real preview or
fullsize request after arming, by serialized request order, and holds responses
for that asset until the test posts `{"action":"release"}`. Thumbnails and other
assets remain available, including prefetches that arrive before the selected
asset. `selected_asset_id` records that choice; the actual `asset_id` and hold
start stay unset until the selected request arrives. A plain legacy
`{"action":"arm"}` still selects the first image request, and its logs remain
readable. The selector contract rejects any explicit selection other than the
fixture's initial primary asset and requires the first eligible request's real
start timestamp. Its newer comparison request comes after that selected start
record, excluding unrelated pre-hold prefetches. The strict ordering judge itself
is unchanged: the held request must start before the comparison completes and
finish after it. Each arm starts a numbered generation;
a new generation is allowed only after the previous one is released and has no
pending responses. Onboarding requests are served normally before arming.
The frozen manifest's legacy delay metadata stays
unchanged for hash compatibility and no longer schedules responses.

While a hold is active, another asset's preview/fullsize response waits until
the real monotonic clock has crossed the first held request's start millisecond
(`hold_started_elapsed_ms`) before sending its bytes. This covers the judge's
requirement that any one size proves the strict order. A faster response can
otherwise finish in that same logged millisecond, leaving the unchanged strict
timeline unable to prove start-before-completion.
The server polls that absolute clock boundary in one-millisecond intervals;
it never increments a timestamp or treats equal timestamps as ordered. Host
scheduling can delay a wake beyond one interval. Thumbnails, unarmed/released
generations and other scenarios keep their existing response paths.

| Caller or response | Before | After |
| --- | --- | --- |
| iOS `late-image` | Independent control/readiness budgets; 1.5-second settling window from confirmed delivery return | One hold-start + 13 s transaction deadline before release; unchanged post-delivery window |
| tvOS `late-image` | Independent control/readiness budgets; 2.5-second settling window from confirmed delivery return | One hold-start + 13 s transaction deadline before release; unchanged post-delivery window |
| Held preview/fullsize response | Explicit release; existing 15-second App timeout and 90-second fixture cap | Unchanged |
| Other preview/fullsize response during an active hold | Immediate send | Send after the actual held-start millisecond has elapsed |
| Thumbnails, other scenarios, unarmed/released generations and non-image routes | Existing response behavior | Unchanged |

The request-order validator, fixture image bytes, manifest hashes, retries
and environment/yellow eligibility are unchanged.

Both platform tests finish an unarmed preparation through the normal first-boot
and playback UI, disable Autoplay in Settings, clear the disk cache through its
confirmation alert, and terminate the app. They then arm immediately before a
configured cold launch into paused playback. Clearing disk and process memory
prevents pre-arm prefetched photos from satisfying the current-scene race.
They verify two committed history advances and a complete
stable rendered scene with fallible snapshot probes. The unarmed preparation
does not pause or advance playback. Before the first cold-launch Next,
`late-image-initial-scene.json` records the scene manifest and held fixture asset;
both XCTest and the Python verdict require that asset to belong to the initial
scene, rejecting a held prefetch from a future scene.
Before the single judged
`ooo-current-scene` capture, readiness waits for two identical PNG
observations with recognizable public identity and the same paused, stable scene
references across both observations. Each readiness iteration checks AX stability
before requesting a screenshot. Readiness and both iOS judged captures
(`ooo-current-scene` and `ooo-after-late`) use the Swift pre-fallback reader that
corresponds to Python's independent `access_lifecycle_contract.capture_identity`.
Full equivalence is not required for a safe readiness gate: every Swift acceptance
must also be a Python acceptance of the same mark. The four known synthetic stacked
composites above remain exceptions to that one-way condition; this change does not
close that pre-existing reader gap. The general
Swift reader's `strict-multi-slot` fallback cannot qualify this capture: its
measured system-chrome exclusions can accept a Home Indicator that the host
reader counts as a foreign photo palette. Both retained real iPad failure runs had
`notes=["strict-multi-slot"]` for both judged frames, proving legacy rejection before
the general reader's fallback accepted them; the new pre-fallback gate rejects
those real Home Indicator frames. Readiness waits within the existing
budget for a frame its Swift reader can recognize; the host judges captures
independently. A persistent iPad Home Indicator
collision fails at the held deadline as `late_image/timing_window` and remains red.
This does not establish a lower failure rate. The whole held transaction has one unscaled
deadline: actual fixture hold start plus 13 seconds, reserving two seconds of the
unchanged 15-second App download timeout for release and delivery. The arm request's
local issue time anchors the fixture elapsed clock conservatively; time before
hold start, including a launch stall before the first image request, is excluded.
After launch returns, synchronizing the first selected-asset request has a separate
fixed five-second `.product` wait. If no held request appears within that wait,
`Late image fixture control failed: no held response after cold launch` fails as
`late_image/fixture_response`; this pre-hold readiness cap does not extend or renew
the held transaction deadline.
Every held-window wait is clamped to that deadline, including controls, pause,
Next, focus, screenshot readiness and fixture control. It is never an infrastructure
wait or a navigation hang guard. Native XCTest operations cannot be interrupted;
their return is checked before any later action or success assertion.
`late-image-held-window.json` records the hold duration and each step's issue/return
uptimes and duration, including native actions, queries and screenshots.
Exhaustion fails immediately at the next interruptible boundary with
`Held response budget exhausted before release:` (`late_image/timing_window`),
an invalid run that remains red under environment policy v1–v4. Its suffix reports
the longest recorded step's test-owned name and seconds inside the held window,
clipping any pre-hold part of cold launch and omitting private inputs. It also reports
the last current-readiness reader status and notes, or `unavailable` if no identity
was read. Preparation has
separate messages under `late_image` or `cold_relaunch/control_state`; neither
phase appears in the environment timing allowlists. No new reader enums or summary
schema are introduced, and old summaries remain readable.
This preparation does not retry either judged capture or the flow.
They explicitly release the hold, poll for
zero pending responses and at least one successful socket write/flush with no
disconnects, retain the existing 1.5-second iOS / 2.5-second tvOS settling window,
and capture `ooo-after-late`. Delivery means the fixture finished writing the
response; it does not claim that the app displayed or decoded the image. Before
writing a held response, a non-blocking socket peek rejects an already-closed
peer, including an empty read, and records a disconnect instead of delivery.
The UI polls retain fixed product budgets. Both late-image tests add the read-only
scene probe and the existing Debug `UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT=1` launch
key. The entry hint is unrelated to the superseded-response proof; the iOS test
does not spend its post-delivery window dismissing it. No private XCTest
quiescence API is used.

Each hold records its generation, `hold_started_elapsed_ms` and
`released_elapsed_ms`. Its effective duration must be less than 15,000 ms:
[`AssetsDownloadManager.swift`](../immichSlides/Shared/Model/AssetsDownloadManager.swift#L669)
uses SDWebImage managers without overriding the
[pinned SDWebImage 5.21.5 default download timeout of 15 seconds](https://github.com/SDWebImage/SDWebImage/blob/36e79ba485e9bb4d3cd4e3318908866dac5e7b51/SDWebImage/Core/SDWebImageDownloaderConfig.m#L25).
At or beyond that app bound the evaluator rejects the run as invalid, even if a
socket write succeeds. The independent 90-second server cap remains a hang guard:
expiry releases the response, leaves an irreversible `expired` state in that
generation and logs `late_image_hold_expired generation=N`; it cannot produce a
passing run for that generation.

The evaluator validates only the current generation's hold and request timeline,
checks that its held asset was the first preview/fullsize request after arming,
and requires release and confirmed delivery. It separately rejects the held
asset's public label anywhere in either captured scene signature. This generalizes
the exclusion to the actually held image under random order; the two existing
scene and timeline verdict functions, including their original A1 exclusion,
remain byte-identical. Missing or malformed records, invalid timestamps, expiry,
pending responses and disconnects fail closed. A held response that hits the
HTTP fault control still finalizes its pending count; the existing timeline
verdict continues to reject its unsuccessful HTTP status.

For a registered listed retry, the existing reset path closes the old app, posts
`{"action":"reset"}` to release and drain the previous hold within five seconds,
then archives its final records before the second attempt can arm a new
generation. The flaky registry and retry policy are unchanged. Earlier attempt
request audits remain mandatory, while its hold/expiry cannot contaminate the
current generation's verdict.
Fixture control log lines have their own prefix and never count as app requests
or public image identity. The iOS late-image suite reuses the existing onboarding
implementation through `StrictE2EOnboardingIOS` in the UI-test target.
Swift fixture-control failures use the distinct `Late image fixture control failed:`
prefix, left unmapped (`unknown`); they cannot be classified as scene flashbacks.

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

Fixture service health uses a separate 60-second infrastructure budget by default
for strict, access-lifecycle and iPad pause host runners. Fixture UI explicitly
selects 120 seconds for its hosted contention allowance. The waiter
requires the ready file to identify the spawned child and `/healthz` to return
HTTP 200; child exit or a mismatched PID fails immediately. Health requests are
capped at one second and the remaining startup budget. Success logs seconds to
healthy; timeout reports elapsed time and the last ready-file/HTTP/error state,
without logging response bodies or addresses. This replaces the ten-second wait
that failed on [the hosted iPhone probe](https://github.com/sudoHG/immichSlides/actions/runs/38122386215/job/114420489109)
after simulator preparation succeeded. The hosted measurements below raise
only the fixture UI cap. Test and product
deadlines are unchanged, and an unhealthy service still fails the run.

For strict and fixture UI callers that capture the startup log, fixture PNG
generation first gets its own cap, including child import: 120 seconds for strict,
300 seconds for fixture UI. Only the
child's allowlisted `fixture-build` completion starts the health budget; a ready
file alone cannot bypass this step. Build exit and build timeout fail separately
before health requests or tests, and neither can produce a passing result. Job logs record
the build cap and elapsed time, followed by the existing service phase records;
the summary format is unchanged. Callers without a startup log use only the
default health budget.

The October 21 UI samples from runs
[39618104921](https://github.com/sudoHG/immichSlides/actions/runs/39618104921) and
[39541878393](https://github.com/sudoHG/immichSlides/actions/runs/39541878393)
contain 17 completed build waits: median 10.1 seconds, maximum 64.0 seconds.
Two additional builds timed out at 120.5 and 126.6 seconds; those are censored
observations, not completed build durations. Sixteen successful health waits
have a median of 0.1 seconds and maximum of 2.0 seconds, while the second iPad
scoped-a attempt timed out at 68.3 seconds after a completed ready-write phase.
The artifact summaries retain those failures; the job logs retain the bounded
startup records and completed waits. A 300-second build cap gives 2.37 times the
largest censored build wait; 120 seconds gives 1.76 times the censored health
wait. These are bounded contention allowances, not measured recovery guarantees
or estimates of an uncensored tail percentile.

Fixture UI now has 420 seconds of service preparation allowances (previously 180).
The raised caps are explicit in `run_fixture_ui_tests.py`, which `ci_ui_tests.py`
uses for UI shards; strict/tracer and other waiter callers retain their previous
limits. Strict has 180 seconds per service and 360 seconds for two sequential
services, rather than the 420/840 seconds a shared increase would impose.
Existing outer runner and job timeouts still apply and can expire earlier.
Fixture UI's 85-minute total execution
deadline starts before service preparation, so this spends its existing allowance;
it does not extend the 65-minute invocation cap or the 110-minute job cap.
See the separate [archive integrity gate](CI_NIGHTLY.md#complete-fixture-ui) allowance.

The official XCTest reader recognizes the exact `Uncategorized` message shape
`Failed to terminate com.331works.immichSlides:<pid>: Failed to terminate com.331works.immichSlides:0`
as `Official XCTest app lifecycle failure`. This label identifies the observed
lifecycle symptom without assigning an infrastructure or App cause. In the iPad visual-a
sample above, the first-failure receipt records `launch-app`, action `launch`,
App `not-running`, and 61.19 seconds since launch was issued; the official method
failed after 102.50 seconds with exit 65. This classification only denies the
uncategorized-to-assertion detail fallback for that signature. It retains the
failed method, counts, exit code and red verdict; it neither retries launch nor
turns the failure into a skip or environment-limited pass. Assertion-typed issues,
mixed issues, foreign bundle IDs and other messages keep their existing handling.
No reporter schema or verdict rule changes are needed; historical unknown
diagnostics remain failed.

Build and health timeouts both carry exit code 124 from the shared waiter;
fixture UI retains its existing nonzero infrastructure-failure accounting.
An early child exit observed by the build waiter names the last allowlisted
startup phase in the main message, or `unknown` when no phase record is available.

Each logged strict service retains at most 120 seconds for build and 60 seconds for health.
The two services in `filter-switch` / `tvos-switch` can therefore consume up to
360 seconds sequentially. The tracer still caps a warm segment at
`(warm timeout + 300-second simulator readiness) * invocations + 240 seconds`
and a cold segment at `cold timeout + 240 seconds`. Those outer caps include
startup and all other preparation; the 240-second margin is shared, not a
guarantee that both service caps fit alongside fully consumed execution and
readiness budgets. Dual startup alone can exceed that margin by 120 seconds.
The outer deadline can stop the segment before all inner caps are consumed,
which remains a timeout failure and can abort the remaining cases in the shard.
Keeping strict's smaller limits preserves this existing trade-off: one service's
180 seconds fits the shared margin, while two services' 360 seconds do not.
It avoids adding a new single-service overflow or increasing dual startup to
840 seconds, at the cost of retaining strict's earlier preparation failures under
contention. This change does not increase tracer deadlines.

The strict build cap rounds three times the measured 36.480-second successful hosted maximum
up to two minutes. A sample of 56 completed UI shard jobs from nightly runs
[39431510164](https://github.com/sudoHG/immichSlides/actions/runs/39431510164),
[39337939502](https://github.com/sudoHG/immichSlides/actions/runs/39337939502),
[39313506982](https://github.com/sudoHG/immichSlides/actions/runs/39313506982) and
[39271039689](https://github.com/sudoHG/immichSlides/actions/runs/39271039689)
contained 54 completed builds at 2.498–36.480 seconds, one job with no build
completion record, and one health timeout at 60.4 seconds still in fixture build.
That failed build's eventual duration is unknown. Five readable scoped PR shards
in [39369116053](https://github.com/sudoHG/immichSlides/actions/runs/39369116053)
completed builds at 1.962–5.286 seconds; unavailable logs in the six most recent
PR runs do not establish absence of failures.

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
Bootstatus, readiness queries and all reset mutations still run. Strict nightly jobs
submit `simctl boot` once immediately after creating their dedicated device, after
toolchain verification. The command retains its 60-second cap and records failures;
simulator startup and first-boot work then proceed asynchronously during the cold
`build-for-testing`. No readiness wait runs before the build. The tracer's
`--simulator-boot-submitted` mode runs
`prepare_simulator(..., boot_submitted=True, should_check_app=False)` after the
first successful cold build and before any warm case: after
`bootstatus -b`, the bounded query is `simctl spawn UDID launchctl print
system/com.apple.lsd`. This checks that the simulator can spawn a process and its
bootstrap server has registered LaunchServices, without asking the cold app database
for an app container. A nonzero service check fails immediately; only timeouts
repeat under the same 300-second readiness and 600-second preparation budgets,
starting after the build; settling time during compilation spends neither budget.
The gate runs as a child process capped at
`SIMULATOR_PREPARATION_TIMEOUT_SECONDS + 180` (780 seconds), using the same
process-group timeout/cleanup as cold and warm runners. Its private
`simulator-preparation.log` retains output; phase lines are relayed to the job log.
Hard-timeout failures keep available diagnostics and mark every case failed/not-run.
Logs identify this probe as `launch-services-registration`. Its returned `None`
is not an app-absence result; this mode is only for callers that discard the
container value. Each service query records a `simulator-preparation` invocation
with its own sequence; only the enclosing wait records a `simulator-readiness`
timeout, preserving the full wait duration in first-failure receipts. Successful
queries also log their own elapsed seconds, so hosted logs can distinguish a fast
response (for example, under two seconds) from a slow valid response. The timestamped
early-boot line and these query records bound observed settling time; gaps between
probes do not establish the exact moment of recovery.
Creation/boot failures use the workflow's preparation-failure accounting. A failed
post-build gate writes every scheduled case as failed with a not-run attempt and
its preparation receipt, without starting a test. Cold build failures remain build
failures. There is no new preparation or test retry.
After the gate succeeds, each warm child receives `--simulator-boot-submitted`;
after its own initial gate, every reset and existing listed retry reuses that boot.
This reset behavior applies to every `run_strict_e2e` caller, including local runs
and the separate strict-tracer workflow. When `bootstatus -b` reports
`Booting device...`, logs add `simulator-bootstatus: started-device=true` to record
that it initiated a boot or reboot; this does not claim the boot succeeded.
They still run bootstatus, container readiness and every app reset mutation.
The default mode and every reset still query the real container,
terminate an installed app, uninstall and verify absence before tests. Service
registration does not claim app-database readiness or successful test execution.
The separate `ci-strict-tracer.yml` workflow still prepares before cold builds in
the default app-container mode. UI workflows overlap archive downloads with boot.

The fixture UI device-inventory query uses the same timed-out-query retry logic
and a separate 300-second readiness budget: 10, 20, 40, then at most 60 seconds
per attempt, clamped to the remaining budget. Nonzero exits, malformed JSON,
missing/unavailable destinations and mismatched device types fail without a
retry; even a valid response after the deadline fails. Logs name
`simulator-inventory`, attempt counts, elapsed time and deadline overrun without
command arguments or output. The inventory and service health budgets are separate.

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
The iOS pause/Next/Continue suite also reports `needs-human-review` unless its
existing `pause-next-continue.json` has `suite == "pause-next-continue"` and contains exactly one `first_transition_start`
with `status: detected` and boolean `official_signed: true`. Pending, unsigned,
missing or unreadable timing evidence remains review-pending; it does not turn
an official XCTest pass into a test failure. The runner's visual receipt records
`UNVERIFIED`, and the tracer reads the timing receipt directly, including older
cases whose visual receipt said `NOT_REQUIRED`. Official counts and runner exit
codes stay unchanged, and a nonzero exit still fails. This does not reinterpret
fade samples, sign pending evidence or provide missing video for human review.
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

### Public validator failure receipts

The strict tracer emits optional `validator_failure_message` on a failed warm case
with an explicit failing validator receipt, alongside `automated_contract_failed`.
The same public message is retained on its failed summary observation and attempt.
The accepting reader shipped first in PR #459, following
[reader-first evolution](CI_SUMMARY.md#reader-first-evolution).
XCTest diagnostics below remain separate from post-test validator failures.

The value is at most 512 characters. The reviewed grammar in
[`ci_failure_diagnostics.py`](../scripts/ci_failure_diagnostics.py) preserves existing
fixed public validator prefixes from `album_server_narrow_contract.py`,
`strict_e2e_photo_identity.py`, `strict_e2e_filter_contract.py` and
`strict_e2e_filter_manifest.py`, plus screenshot basenames from their actual calls,
slot indices, horizontal/vertical/both-axis labels, fixture A/B letters and counts.
Unavailable context can be `unresolved` or a prefix followed by `; context unresolved`.
The public helper appends that suffix to a recognized bare prefix. Interpolated
messages are limited to the existing count/letter/slot/axis grammar, the public
pattern mismatch (allowlisted screenshot stem, expected fixture `a`/`b`, observed
`a`/`b`/`None`), and the unrecognizable-input message (classifier status and public
photo mark or `None`). AST synchronization tests pin the literal tables and the
classifier pattern/status/mark sets to their contract sources without adding image
dependencies to the isolated reader. The closed `unreadable public glyph:` exception
names are `AttributeError`, `IndexError`,
`KeyError`, `OSError`, `TypeError`, `UnidentifiedImageError` and `ValueError`.
The exact screenshot stems admitted for retained evidence and reader-first producers are
`history-start`, `history-first-next`, `history-second-next`, `history-first-previous`,
`history-second-previous`, `pause-immediate`, `pause-after-10s`, `resumed`,
`album-playback-1`/`album-playback-2`/`album-playback-3`, `album-play-1`/`album-play-2`/`album-play-3`,
`person-normal`, `person-normal-1`, `person-no-faces`, `person-nofaces-1`, `vision-solo-1`,
`person-conflict-normal` and `person-conflict-normal-N` (N = 1 through 99),
`album-switch-b-play-1`/`album-switch-b-play-2`,
`server-switch-a-play-1`, `switch-b-play-1`/`switch-b-play-2`, and `display-after` (all `.png`).
The `album-play-[123]` reader shipped in PR #514 before its filter-album producer
in PR #515. These stems also fit the existing public-pattern-mismatch grammar;
the filter-album producer emits screenshot context, not that mismatch prefix.
`display-after`, `person-normal-1`, `person-nofaces-1` and `vision-solo-1` are admitted
before the corresponding input-registration producer;
`person-solo` and `person-conflict-solo` have no receipt producer and are not admitted.
Unrecognized prefixes, filenames and suffixes are refused rather than treated as public
text. The grammar accepts no URLs, keys, server addresses, directory paths, private
xcresult text or pixel arrays. It does not decode images or change a visual check.

The existing sensitive-output scan also covers UI, unit, fixture and flaky outputs.
On the strict path it validates the field in case evidence, P2 recordings and review packages.
It checks length and duplicate/malformed fields, alongside existing sensitive-value
scanning. **`records/` is uploaded unscanned**, including on failure. The producer
therefore writes only `public_validator_failure_message(...)` output to both
`records/trace.json` and `records/summary.json`, never the raw validator error.
The helper returns `[redacted validator failure]` on refusal instead of dropping
the case. An invalid value written directly to a summary invalidates the entire
shard; reporter-side redaction cannot repair an already public artifact.

The producer regression tests inject a URL, absolute directory path, non-fixture ID and IP into
`visual-identity-runner.json`: trace and summary must contain only the fixed
redaction marker, retaining the failed case and exit code. Aggregation consumes
that actual producer summary, and a real public contract failure reaches the report table.
An upload scan for `records/` is an optional follow-up requiring maintainer approval;
receipt publication adds no workflow step.

The report reader applies the grammar once at its optional trace boundary and
copies a receipt only for outcome `failed`; it retains the redaction marker on refusal.
Valid messages survive aggregation and compact history and appear in
the [nightly failure table](CI_REPORT.md#method-identities-and-reruns).
Historical traces and summaries without the field remain valid and gain no new claim.

<a id="prepared-first-failure-evidence"></a>

### First-failure evidence

Hosted cases also collect a bounded, optional App main-thread stack after
sustained high App CPU. The [resource diagnostics contract](CI_SUMMARY.md#bounded-infrastructure-diagnostics)
defines the trigger, per-case/job caps, redaction, accounting and local-only
`--local-force-app-hang-capture` exercise. Optional capture results do not change
first-failure, functional verdict, environment-limit eligibility or timing rules;
capture cleanup failures use the existing runner cleanup policy below.

Case shutdown owns and reaps a running capture before returning, using the same
0.8 seconds plus a reap floor: launch-lock waiting and worker joins share the
0.8-second deadline, while `wait` gets at least 0.1 second after SIGKILL. Capture launch and
shutdown are serialized, and capture workers finish their private-file cleanup
before interpreter exit. The process remains inside the runner group as an
additional cancellation boundary. Failure to reap is appended to `cleanup_failures`
and written to `cleanup-failures.json`, preserving the primary nonzero exit,
the existing 124 timeout mapping and any propagating exception. A successful primary
run returns 2 under the existing cleanup policy. Sampling cost is retained before
recording the failure, with a full reservation for unfinished capture work and no
fresh allowance for unknown sampler cost. If tracer group cleanup itself fails, the
error and bounded receipt retain sanitized surviving executable/parent basenames
and states; see the [resource diagnostics contract](CI_SUMMARY.md#bounded-infrastructure-diagnostics).

The [hosted strict environment-limit policy](CI_SUMMARY.md#prepared-hosted-strict-environment-limits)
uses these receipts and the same case's resource samples. The strict tracer now
projects qualifying failures at its checkpoint, validates the candidate summary and
official-method binding with the merged readers, and emits no proof on refusal. Its
allowlist, evidence requirements, escalation and retained-proof policy are defined
there. Functional failures and insufficient
evidence stay red, including every UI shard without a continuous sampler.
Local pinned-device timing contracts, all App behavior, test deadlines, visual validators,
thresholds and retry limits remain unchanged. `run_strict_e2e.py` retains its raw
failure exit code; only a complete tracer shard with exclusively yellow failures and
no infrastructure errors exits zero, with per-case workflow and Markdown warnings.

Public-fixture strict/UI failures can publish one first-failure receipt per
method and existing attempt. Historical records without
`first_failure` remain valid. No App code, workflow, assertion, deadline, retry,
threshold, verdict or population changes. The accepting reader must be on main
before a producer PR uses the field; see [reader-first evolution](CI_SUMMARY.md#reader-first-evolution).

Pause/continue and playback-rotation tests hand thrown helper failures to the
recorder before terminating the App, then rethrow the original error to XCTest.
The recorder observes the actual App state; teardown must not replace the business
action or imply that the App crashed. Existing captured frames and timing outputs
remain evidence of their original capture, rather than a reconstructed failure snapshot.
Fixture selectors use `Class/method` throughout environment lookup, spool collection
and attachment. Strip the target prefix only from `target/Class/method`; a class
named `immichSlidesUITests` remains part of the key. Official identifiers are retained.

The optional receipt requires `schema_version: 1`, `source` (`xctest`,
`validator`, `preparation`), `step`, `element`, `action`, `timing`, `state`,
`validator`, and `screenshot`, and accepts optional `native_activity_seconds` and `gate`.
All strings are closed vocabularies in
`ci_failure_diagnostics.py`; `FIRST_FAILURE_ELEMENTS` is the single reviewed
element table, supplied by fixture runners to the test-only recorder.
Unknown elements become `unknown`, never arbitrary identifiers. Unknown numbers
remain null. No assertion text, paths, commands, URLs, asset identifiers, AX trees
or raw probe labels are accepted. Exact fields, finite numbers and range checks
bound the canonical receipt below 8 KiB. Duplicate keys, including nested keys,
and malformed JSON containing the field are refused without echoing candidates.

| Object | Exact fields and meaning |
| --- | --- |
| `timing` | `since_action_issued_seconds`, `since_action_returned_seconds`, `action_duration_seconds`, `wait_elapsed_seconds`, `deadline_seconds`, `capture_request_seconds`, `capture_return_seconds`, `state_age_seconds`; finite 0–86,400 seconds or null |
| `state` | `app`, `surface`, `observation`, `control_bar`, `focus`, `history_count`, `autoplay`, `orientation`, `scene_status`, `query_error_code`; enums and bounded integers/null only |
| `validator` | Null, or exactly closed `kind`, integer/null `slot` (1–64), and closed `axis`; requires validator source |
| `screenshot` | `status`, `width`, `height`, `bytes`; a retained image needs positive dimensions <=1,536 and bytes <=1 MiB; unavailable images have null measurements |
| `native_activity_seconds` | Optional, XCTest source only; exactly `pre_event_idle`, `find_window`, `synthesize_event`, `post_event_idle`, `ax_root_acquisition`, each finite 0–86,400 seconds or null |
| `gate` | Optional album capture timeout facts; exactly `kind: album-capture`, `stable`, `paused`, `entry_hint_hidden`, `advanced`, `layers_changed`, `manifest_complete`, and `phase`; the six condition fields are Boolean or null |

The `gate` reader accepts only XCTest `wait-scene` receipts for
`slideshow.scenePresentation.contract.summary` or `slideshow.control.next.button`.
It describes the last observation in `captureStableAlbumPlaybackPNG`, including
the Album Next timeout. `stable` uses the existing stable-window predicate;
`advanced` retains any observed history advance relative to the previous capture,
while `layers_changed` describes the last observation's layer change. Both remain
null when there is no previous capture. `manifest_complete` describes the existing
complete-visible-scene predicate. Missing observations remain null, and `phase`
accepts only `unknown`, `empty`, `stablePhoto`, `grace`, `transition`, `loading`,
`incomingFromLoading`, `paused`, or `sourceError`, matching the render probe.
Other failure paths omit `gate`. The environment-failure projection retains it,
and policies v2/v3 use it for environment timing and yellow eligibility under the
[versioned proof contract](CI_SUMMARY.md#prepared-hosted-strict-environment-limits).
Policy v1 retains its existing eligibility rules.
Reader support must merge before a producer starts emitting this optional object;
old receipts, including retained nights, remain valid without it.

The test-only producer attaches this projection before each album capture timeout
assertion, including frozen-transition and Album Next failures, using the last poll's
observation without another snapshot. The first-failure recorder writes it into the
initial safe receipt before optional failure capture, and the strict runner retains
it through validated spool export. Context reset before each test prevents facts
from leaking across tests. Normal return clears the facts too, but XCTest aborts
with `continueAfterFailure = false` can skip that `defer`. Successful
captures and post-capture assertions omit the field.

Native activity support follows the
[reader-first merge](CI_SUMMARY.md#reader-first-evolution). Strict-runner failure
exports inspect the existing private xcresult and emit the numeric projection.
Durations describe
native xcresult sub-activities bound to the first failing action, not estimates
from adjacent log lines. Ambiguous or missing activities remain null; zero means
a measured zero. Pre/post-event idle are separated around event synthesis;
AX root acquisition measures only the native application-root acquisition, not
all accessibility work. Nested intervals must not be double-counted. No native
titles or raw logs enter the receipt. Summary/report rendering shows only these
fixed duration labels and numbers, preserving the original attempt and failure.
Tap matching requires a unique duration match among preceding native taps, the
latest native tap before the first official failure, and agreement with the
recorder's action duration within 0.1 seconds. Only a
recorded `select`/`tap` context permits this association. Otherwise the extractor
requires an unambiguous native failure-summary ID. Missing/ambiguous matches
retain nulls. Adjacent native AX root acquisitions within 0.1 seconds of the
tap boundaries are included, using their own actual start/finish bounds.
Pre/post-event idle refer only to the App under test; SpringBoard idle is excluded.
Overlapping intervals are unioned within a category; different categories may
overlap and must not be added as an action total. The unique earliest official failure
timestamp binds the resource window even if no recorder receipt was available.
Unavailable native exports leave the original receipt/result intact. Additional
reads use the independent native allowance specified in
[bounded infrastructure diagnostics](CI_SUMMARY.md#bounded-infrastructure-diagnostics);
successful methods perform no additional xcresult activity reads.
Markdown uses the compact fixed labels `pre`, `window`, `synth`, `post`, and
`ax` for these five fields, respectively; the JSON retains the full field names
and values. If all five values are null, Markdown emits only `native=unavailable`.
Regression coverage checks two reports with 50 first-failure lines each, at both
the maximum native values and all-null values, against the existing 65,000-byte
notification guard. Oversized notification bodies still fail closed; no receipts
are dropped and no result changes.

Reader support for bounded per-case host CPU/load evidence is specified in
[bounded infrastructure diagnostics](CI_SUMMARY.md#bounded-infrastructure-diagnostics).
The sampler's cadence, process-snapshot costs, retention and independent
allowances are defined in that contract. It leaves every test deadline, action,
retry and verdict unchanged. A low idle measurement
is contention evidence, not by itself proof of why an App action was slow.
The case manifest and `trace.json`'s `warm[].bounded_diagnostics` follow that
[receipt binding and validation contract](CI_SUMMARY.md#bounded-infrastructure-diagnostics).
Each `ps` query is capped at 0.5 seconds within the unchanged 180-second allowance.
The private job ledger carries process-only cost separately from each case's
ten-second host-read allowance; the public wall total still includes both.
Old ledgers retain conservative combined-cost charging; see the linked contract
for shard expansion and compatibility details.
If no App process is identified, per-sample App CPU and its case peak remain null;
an identified but idle App can report zero. Diagnostic shutdown or native-projection
errors mark Xcode diagnostics unavailable and truncated without replacing the
execution return code or original exception.

Capture offsets refer to the first failure's monotonic timestamp; they expose
request/return lag rather than claiming an instantaneous image. `observation`
distinguishes cached evidence, a failure snapshot, and unavailable state.
Existing probes may be absent, especially on Release/tvOS; absence does not prove
zero history, hidden controls or a stable scene. Preparation receipts cannot
claim a captured App image. A post-test validator may retain its actual public
input image as `validated-input`; it cannot reconstruct failure-instant App
state after the App exits and cannot claim `observation: failure-snapshot`.
Neither evidence type changes its original result.

The target-album validator registers its raw input before slot counting and includes
the fixed `album-play-N.png` context in identity rejections. Its retained PNG uses
the existing diagnostic budget, canonicalization and `read-failure` hash/attempt gate.
Named person PNGs and the device Vision `vision-solo-1.png` register their original bytes
before classification and retain the fixed screenshot name in identity rejections.
These emitted stems are a subset of the reader allowlist above. Display-policy validators register
the full `display-after.png` before cached foreground or region analysis. Internal
crops do not replace that input. Undecodable bytes make the image unavailable,
rather than retaining a previously registered playback or before image.
Named-PNG classification also clears the retained input before missing-file or read errors.
The person `solo_only` JSON checks and device Vision's non-vacuity JSON check clear
the retained input; their rejections report an unavailable image.
Edit-switch slot checks register the frame being checked, including when a later frame
was already classified. Its iOS whole-frame membership rejection registers the first
frame outside the non-target album. Server-switch candidates and the post-switch single-photo input
retain full frames; nested crop analysis restores the original frame before returning
or propagating a rejection. These registration-only paths add no screenshot-name context.
For iOS and tvOS album-empty, the empty-result image replaces the playback input
before pixel checks. JSON-only failures and a missing result PNG still retain the
last validated playback frame; that image is context, not proof of the empty-result
screen or the JSON failure.
Warm child-runner failures in either initial simulator preparation or the per-case
reset before xcodebuild project only that call's events from the bounded ledger
into the case manifest. Steps absent from the ledger remain `unknown`; no timing
or image is invented. The tracer accepts that preparation receipt only without official
method execution: the case stays failed, its attempt is `not-run`, and the raw runner
exit (including 124) is retained. Aggregation therefore counts these identities as
`missing`, rather than `executed` with a `declared-not-compiled` error. Producer
failure and matrix mismatch still fail the aggregate; this is a count change, not
a verdict change. Failed official methods also supply their existing
phase/class pair to the failed summary observation and attempt; validator or
preparation failures do not acquire XCTest labels.

XCTest capture is allowed only on the failure path of an explicitly
configured public loopback fixture run, on an allowed foreground App surface.
Live/private runs, first-boot credential/PIN pages, Settings.app and SpringBoard
cannot produce public images. The scanner does not inspect pixel semantics;
proven public fixture provenance and producer capture guards are required.
The reader also refuses captured images when the waited element or focus target
is any `firstboot.*` element, even if the reported surface is allowed.
Successful tests must add no AX query, screenshot or public receipt. A synchronous
XCTest screenshot has no independent hard five-second bound: its actual overhead
must be measured, with existing runner/watchdog limits remaining authoritative.

Strict diagnostic media uses a separate failure-only directory inside the
existing scanned `p2-review-*` artifact, never a completed P2 review package.
The reader command is:

```bash
python3 scripts/ci_review_packages.py read-failure --package <directory> --summary <summary.json>
```

The directory contains exactly `first-failure.json` and `first-failure.png`.
Its manifest has exactly `schema_version: 1`, `source_identity`, `run`, `identity`,
`attempt`, `fixture_sha256`, `first_failure`, `image_sha256`. Existing source/run/
identity fields bind it to the supplied strict summary and failed attempt; the
fixture hash must match the frozen public A/B fixture. The PNG is a single,
metadata-free canonical PNG encoded with Pillow, with exact receipt dimensions,
size and digest. Symlinks, extra files, trailing data and metadata are refused;
the manifest is capped at 32 KiB. This reader grants no visual or human PASS.
Ordinary UI media reuses the existing scanned `ui-failures-*` artifact.
`records/` remains unscanned, so validated projection must precede producer writes.
`export-shard` calls `read_failure_package` as a mandatory gate before diagnostic
media can reach the existing upload step. Its staged package must bind the
case source, fixture, exact official method, run and failed attempt; refusal
leaves no uploaded candidate. Diagnostic paths are
`first-failures/<sha>/<suite>/<device>/<configuration>/<scenario>/<fixture>/attempt-N/`;
all public-fixture strict suites can use them, including non-P2 and Release cases.
They do not enter
the completed-P2 package index or change its review bindings.

UI exports normalize existing public-fixture failure screenshots to bounded,
metadata-free canonical PNGs. `check-upload` validates every failure image with
the same image validator, and binds new first-failure images to the corresponding
summary attempt at `failure-screenshots/first-failure-attempt-N/<declared-index>.png`.
Invocation numbers beyond two still belong to attempt two of their individual
identities; the original listed-retry selection and verdicts are unchanged.

The shared recorder lives in `immichSlidesUITests/UITestSupport.swift`; its
Foundation-only timeline lives in `TestSupport/TestWait.swift` (existing UI and
unit-test targets, never the App). Every direct UI `XCTestCase` resets the timeline
before `super.invokeTest`, forwards the first issue to the recorder, then calls
`super.record`; the conventions check rejects missing hooks. Existing native
actions and waits forward once through the shared facades. Known reviewed
identifiers are supplied without new AX reads; other targets remain `unknown`.

Only public-fixture runners inject the opt-in, reviewed vocabulary and private
spool into the UI test target, never the App or unit target. The recorder also
requires a public synthetic key and a loopback `/api` URL. It latches the first
failure (`XCTIssue.isFailure`, ignoring warnings) and persists its bounded safe core before optional failure-only AX reads
and capture. A background-thread issue retains unavailable App/image state.
Foreground captures reject secure text fields, first-boot/server surfaces,
the existing `pinEntry.`/`settings.pin.` namespaces and incomplete trees.
Capture uses one native screen screenshot, cropped to the already-snapshotted
App-window frame without resolving an element again. Optional AX/capture issues
are contained by a non-strict expected-failure scope, so they cannot precede or
replace the original real failure. Diagnostics temporarily permit continuation
inside that scope and restore the caller's setting before forwarding the original
issue; an expected capture issue cannot unwind past the original record call.
The same cropped frame is resized until it
meets the limits; this adds no test retry. Private spools are projected only onto
matching official failures and are removed before private-bundle finalization.
Each existing attempt starts from a recorder-disabled command and receives its
own spool only after configuration succeeds. A configuration failure leaves that
attempt's recorder disabled; it never falls back to a previous attempt's spool.
If the first failed attempt has no receipt, later receipts and their unbound UI
diagnostic images are omitted to preserve the reader invariant.

Action timestamps bracket the actual native call; completed waits stop timing
when the existing waiter returns. `state_age_seconds` measures time since the
failure snapshot query returned, at screenshot request. Existing probe fields
are projected individually; absent fields stay unknown/null. `autoplay` reads
the existing settings toggle value, without inferring a preference from pause.
The post-test validator retains an actual input it evaluated as `validated-input`,
with unavailable App state/timing. Preparation receipts reuse retained #471
timeout measurements; a deadline absent from that ledger stays null.

Passing methods add no AX query, capture, spool or public receipt; only constant
clock/context bookkeeping surrounds existing actions and waits. A snapshot that
throws records its numeric query error but no timing cost; capture offsets remain
null on that path. Successful capture cost is measured by the receipt offsets,
under the existing runner/watchdog limits. The per-image target is at most 1 MiB image
plus 8 KiB receipt for a failing method: 19 failures would add at most 19 MiB plus
152 KiB per attempt (38 MiB plus 304 KiB if all 19 use both existing attempts),
before existing artifact compression and receipt copies in
the current shard artifacts. Optional host image projection uses the existing
#471 shared accounting, stopping when its Xcode collection charge reaches five
seconds per job (43 jobs: at most 215 seconds/night). Earlier #471 collection
consumes that same allowance. A spent allowance or invalid image leaves the core
receipt intact with unavailable media. Image workers only return bytes; timed-out
workers cannot publish late files. Existing UI failure attachments are normalized
outside that optional budget, so they neither consume a later attempt's image
allowance nor disappear when the first-failure budget is spent. Mandatory bounded
publication validation and bookkeeping remain separate, as do synchronous XCTest
capture and export budgets.
The current matrix has 25 strict and 18 UI jobs. Its 132 strict cases include
12 additional filter-person session methods; the UI plans have 318 methods.
Thus at most 462 methods could fail once: 462 MiB of new PNGs plus 3.61 MiB of
logical receipts, or twice those amounts if every method used both allowed
attempts (a conservative bound, since only listed methods may retry).
Passing methods produce none of those bytes. A local optimized bookkeeping
probe measured about 0.28 microseconds added per action/wait pair; this is a
local helper cost, not a hosted wall-clock or full-nightly measurement.

Receipts are visible in producer summaries, the 7-day shard artifacts and
`diagnose_nightly`. Reporter outputs (runs pages, step summary and post-merge
notices) never carry receipts. Compact reporter history keeps **zero** receipt
copies, including nested attempts, `diagnostics.failures` and `attempt_history`;
merging also strips any receipt objects from previously saved dates as a
defensive compatibility measure; reader-first rollout emitted none. The existing
issue-state `first_failure` date string is unchanged. Receipt growth in the
16 MiB `history.json` budget is therefore zero bytes, including in the worst
case; identity, verdict and timing history remain available without the receipt.

Measured baseline: [reporter run 39119552754](https://github.com/sudoHG/immichSlides/actions/runs/39119552754),
artifact `ci-report-daily-39119552754-1` (ID `12133468385`, producer head
`696316746a6f73bf0b24fa20dcc93b3c2ed23e16`). Its ZIP is 339,865 bytes;
all extracted members total 3,827,272 bytes and `history.json` is 1,918,413 bytes
uncompressed (11 dates, October 8–18). Against the 16,777,216-byte history cap,
current headroom is 14,858,803 bytes (14.170 MiB). This is a measured baseline,
not a forecast of unrelated history growth. The cutoff of 89 days before today
can retain 90 calendar dates: keeping three 8 KiB copies for 19 nightly failures
would alone add 42,024,960 bytes (40.078 MiB), before attempt-history copies.
Removing all compact receipt copies avoids that growth without raising the cap.

### Public failure diagnostics

Failed method nodes in `official-tests*.json` and the tracer's
`trace.json` `official_methods` carry two fixed enums:

- `failure_phase`: `interval_setup`, `hidden_controls`, `visible_scene_capture`,
  `background_return`, `continue_timing`, `paused_hold`, `settings_navigation`,
  `control_action`, `firstboot_setup`, `cold_relaunch`, `mode_selection`,
  `playback_entry`, `history_navigation`, `pause_window`, `late_image`,
  `image_recovery`, `exif_ownership`, `filter_selection`, `filter_edit`,
  `server_switch`, `display_policy`, `history_start_capture`,
  `history_first_next_capture`, `history_second_next_capture`,
  `history_first_previous_capture`, `history_second_previous_capture`,
  `rotation_start_capture`, `rotation_landscape_capture`,
  `rotation_portrait_capture`, `unknown`.
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
XCTest assertion and the known Swift `AssertionError.message` and
`Failure(message:)` wrappers are recognized;
unmatched, missing or conflicting messages yield `unknown` for both fields.
Snapshot/hittability failures identify only the class, with an unknown phase.
Journey-b's five history captures and tvOS's matching history captures have separate `history_*_capture` phases,
and rotation's initial portrait, landscape and final portrait stable waits have
separate `rotation_*_capture` phases. These map the existing interpolated names
before the generic capture prefix; the source-check test verifies both the
message template and each call-site name. The remaining onboarding, driver and
rotation precondition messages map through the same reviewed prefix table.
The five history prefixes previously mapped to `visible_scene_capture/scene_identity`;
they now identify the capture site on both platforms, including
`StrictE2ETVOSFlowUITests.swift:343/365/387/415/442` (`evidenceName` arguments).
Empty screenshot data and `Turning off Autoplay in settings must take effect immediately`
yield unknown for both fields. The interval-setup assertions
`Autoplay must be turned on through the real settings.` and
`Autoplay must be on for the pause/background cases.` identify `interval_setup/control_state`.
These labels locate a check; they do not establish a product or infrastructure
root cause. No assertion text, observed value, path, identifier or frame is
added to public records by the mapper.

iOS lifecycle Play/Pause preparation closes its appearance receipt wait before
starting its existing readiness wait. Both still use their original durations;
the final defer closes the current wait instead of leaving the appearance wait
active during later captures. A historical `capture-frame` receipt with an 8 s
deadline can therefore describe a leaked preparation wait, not the duration of
one screenshot call. Completed state-readback waits remain completed. This changes
potential environment-limit eligibility in both directions: the two Play/Pause
hittability failures can now report the completed 2 s readiness wait and qualify
as UI-availability failures under the existing starvation proof, while later
Settings failures no longer inherit the leaked 8 s wait. The exact messages,
Release probe limitation and coordinator acceptance are documented beside the
[environment-limit policy](CI_SUMMARY.md#prepared-hosted-strict-environment-limits).
XCTest pass/fail outcomes, allowlists and policy versions are unchanged.

The control-bar calibration prints each phase before its UI call or classification,
so an XCTest abort that skips defer still leaves the phase-start line. Each call
emits at most five phase lines, one screenshot duration and one total duration,
without extra UI calls. These diagnostics are visible only in local xcodebuild
stdout; hosted summaries do not retain that log. Its Settings-crop unwrap has an explicit
`visible_scene_capture/evidence_capture` prefix, which remains red under the
existing environment-limit policy. This identifies future calibration failures;
it does not attribute historical unknown messages to that assertion.

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
Identical text in other files has also been checked for phase consistency.
Each row fixes both enum values before any suffix is read. Shared prefixes receive a
specific phase only when their public call sites establish the same phase.
`Playback page should show the settings button` also serves tvOS control-bar and
history checks, so it retains an `unknown` phase and `hidden_controls` class. The shared
EXIF helper also runs in the pause-window flow, so its two prefixes retain an `unknown`
phase and only identify the class. The shared driver's EXIF toggle also runs in image
failure recovery, so that prefix retains an `unknown` phase and `control_state` class.
The shared tvOS album/person helpers and paused-capture helper also run in the playback
settings editor and server-switch flows, so their prefixes retain an `unknown` phase.
The shared slideshow "never became tappable" prefix uses `control_action`: every
caller acts on the playback control bar during playback, including Settings opening,
retained-history navigation, Play/Pause, EXIF advance and pause-window A2 search.
The lifecycle autoplay-toggle and single-photo-option availability sentences also
serve Settings readback and display-policy changes, so they use an `unknown` phase
and `hidden_controls` class.
The shared `rotate()` orientation assertion serves portrait and landscape steps,
iPad layout and orientation self-checks, so it retains an `unknown` phase.
The whole-rotation deadline and onboarding iPad orientation assertion also use
`unknown`: neither Continue timing nor display-mode policy describes device rotation.
The tvOS lifecycle hidden-wake helper serves both Settings opening and generic
control-bar recovery in the pause suite. Its focus, transition, screenshot and
single-press checks retain an `unknown` phase, including the shared returned-layer
check used on background return. Shared keyboard helpers also serve first boot and
server switching, and generic focus/selected-option helpers serve several settings
operations; their ambiguous phases remain `unknown`. The selected-option prefix is
restricted to `After choosing settings.playback.` so mode-selection sentences do
not match it. Identity screenshot prefixes include the four reviewed capture names
and `cannot serve as identity:`; unrelated screenshot evidence remains unmatched.
The two simulator-only preconditions retain `unknown/unknown`: they do not report
missing captured frames.

The iPad lifecycle pause judge's thrown timing, brightness, continuity and identity
failures use the fixed prefixes in this section's table. They remain red under every
environment-limit policy: none of their phase/class pairs is an eligible availability
wait. Unreviewed or conflicting messages still produce `unknown/unknown`; no raw
message is published. The shared `Missing settings evidence` settings-readback
message remains `unknown/unknown`; its pause-flow fallback is unreachable because
the invalid-interval assertion throws first.
A wrapper source line does not identify the throwing helper. Also, the first-failure
timeline retains a completed wait until another action or wait begins: a later
`capture-frame` marker does not make `wait_elapsed_seconds` a screenshot duration.
Capture request/return measurements are currently unavailable for XCTest receipts:
`FirstFailureTimeline.timing` writes both fields as null.

Recognizing previously unknown tvOS assertions also makes the following combinations
newly eligible for yellow under the existing device-agnostic environment-limit policy.
This is a classification effect, even though the allowlist and verdict logic are
unchanged. Eligibility still requires the same hosted method/resource binding,
foreground playback surface, exhausted recorded wait and qualifying starvation
samples; no actual product failure becomes a pass. Repeated yellow cases escalate
after two nights under the [existing policy](CI_SUMMARY.md#prepared-hosted-strict-environment-limits).

| Newly yellow-eligible phase / class | Recorded step / element | Source and exposure |
|---|---|---|
| `hidden_controls/hidden_controls` | `reveal-controls` / `slideshow.control.playPause.button` | [Flow wake](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L828) and [lifecycle wake](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L666): `control_bar` must be **other than `visible`**, so both `hidden` and `unknown` pass this guard. The control-bar probe is DEBUG-only ([probe gate](../immichSlides/tvOS/Core/SlideShowViewTV.swift#L243), [probe attachment](../immichSlides/tvOS/Core/SlideShowViewTV.swift#L369)); in the Release pause suite `control_bar` is always `unknown` and this guard never rejects a wake failure. |
| `control_action/hidden_controls` | `query-element` / `slideshow.control.previous.button` | [Flow entry](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L277): a missing Previous button, including a regression that hides it instead of disabling it, can be yellow on a qualifying starved runner. |
| `settings_navigation/navigation` | `query-element` / `slideshow.control.settings.button` | [Settings return](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L631): after reaching playback, failure to show Settings within the existing 8 s wait can be yellow. |

Other newly mapped assertions do not supply additional eligible combinations:
the post-Select Settings assertion has no completed wait timing; wake receiver/hint
queries record an unknown element; mode-selection queries use `query-element`
rather than the allowlisted mode steps; history phases and
`playback_entry/hidden_controls` are absent from the allowlist. The inferred saved
pause failure (`visible_scene_capture/scene_identity`, `capture-frame`,
UNRECOGNIZABLE) and flow failure (`history_navigation/control_state`, or
`history_navigation/hidden_controls` for the entry query) remain red.

The pause-window suite's four `PRECONDITION_FAIL` prefixes describe the A2 search
before Play, although they share `pause_window/scene_identity` with post-Play checks.
The first-failure receipt's completed-wait deadline can help locate these sites:
three A2-search prefixes retain a 4 s deadline from `waitForSettledPhoto`, but
`could not identify the large-text A2 using Next.` usually has no deadline after
the final Next action; a final successor-check `continue` can instead retain 4 s.
The pre-Play `Pause window bright proof must show A2.` check also retains 4 s,
either from the settled-photo wait or a control reveal. Only the 2 s Play-state
readback deadline identifies a post-Play check unambiguously. The screenshot context and a
short elapsed wait alone do not identify the assertion. Strict exports retain the
fixed assertion families below when the existing official legacy summaries are
available; historical receipts without them cannot establish exact attribution.
`Show EXIF info must be on.` is an
`interval_setup/control_state` precondition, like the autoplay setup check, rather
than part of the EXIF ownership flow. Both classifications remain red.
The segmented-control presence and Simplified Chinese label checks use
`control_state` as the closest existing class; they check presence/copy rather
than enabled or selected state and do not introduce a new enum.

<a id="pause-window-assertion-families"></a>

The optional `bounded_diagnostics.case_resources[].pause_window_assertions` list
distinguishes the ten `pause_window/scene_identity` assertion sites without
publishing raw XCTest messages, interpolated values, asset IDs or probe text.
It reuses the existing private legacy export, only for the exact failed pause-window
method and its resource sequence; it performs no additional XCTest query or export.
The list is a sorted set of observed families, not an ordered failure timeline or a
claim about which assertion failed first. Other failure messages in that method
map to `unmapped`; missing summaries omit the field. The existing phase/class,
first-failure receipt, raw outcome and yellow eligibility are unchanged.
The [reader-first consumer boundary](CI_SUMMARY.md#reader-first-evolution) permits
this strict-only producer and reader to ship together, preserving old nights.

| Family | Assertion site |
| --- | --- |
| `successor-order` | A2 successor is A4/A5 or Fixture 5 |
| `successor-a3` | A2 successor cannot be identified as A3 |
| `restored-a2` | Previous did not restore A2 |
| `find-a2` | A2 search exhausted |
| `bright-a2` | Pre-Play bright pixels do not prove A2 |
| `late-a3` | Paused midpoint shows complete A3 |
| `frozen-probe` | Paused identity, opacity or motion changed or missing |
| `frozen-pixels` | Paused photo pixels changed or missing |
| `visible-pixels` | Midpoint lacks visible photo pixels |
| `outgoing-a2` | Midpoint identifies a transition or another photo |
| `unmapped` | Another failure in the same method; no raw text retained |

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
| `history_start_capture` | Initial retained-history screenshot on iOS or tvOS; generic visible-scene capture cannot identify this history site. |
| `history_first_next_capture` | Screenshot after the first retained-history Next; history navigation alone cannot identify the failing capture. |
| `history_second_next_capture` | Screenshot after the second retained-history Next; distinct from the first Next capture. |
| `history_first_previous_capture` | Screenshot after the first retained-history Previous; distinct from advancing history. |
| `history_second_previous_capture` | Screenshot after the second retained-history Previous, returning to the start; distinct from the first Previous capture. |
| `rotation_start_capture` | Initial stable portrait capture before rotating during playback; generic capture cannot identify this rotation site. |
| `rotation_landscape_capture` | Stable landscape capture after the first playback rotation; distinct from the initial portrait capture. |
| `rotation_portrait_capture` | Stable portrait capture after returning from landscape; distinct from the initial portrait capture. |
| `control_state` | Enabled/selected/play-pause state of an existing control; navigation and hidden-controls classes do not express its value. |
| `focus` | Remote system focus on a named UI control/receiver; presence or navigation alone does not prove focus. |
| `evidence_capture` | Missing required captured frames or unserializable capture evidence; this does not establish pixel identity. |
| `probe_readback` | Missing/inconsistent combined render/manifest/history or synchronized opacity probe evidence; this does not identify a bad photo. |
| `fixture_response` | Controlled image-response mode or delivered-failure count; this is fixture evidence, not navigation or image identity. |
| `exif_visibility` | Visible EXIF card remains after disabling it; photo identity alone cannot express overlay visibility. |
| `exif_correspondence` | EXIF metadata disagrees with the identified photo; neither navigation nor photo identity alone expresses that mismatch. |

| Fixed source prefix | Phase | Class | Public source |
|---|---|---|---|
| `tvOS flow entry precondition failed:` | `history_navigation` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L282) and [#L302](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L302); red when the initial scene did not stabilize before the entry pause, or when autoplay advanced before it. The `tvos-entry-capture-window` attachment distinguishes the two |
| `tvOS flow entry anchor must remain paused before checking the history boundary.` | `history_navigation` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L306) |
| `tvOS midpoint setup exhausted the original step budget before the half-cycle pause.` | `continue_timing` | `timing_window` | [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L343) |
| `tvOS midpoint pause requires Play/Pause focus after at most one wake within the original step budget.` | `control_action` | `focus` | [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L364) |
| `tvOS midpoint pause must return in the anchored stable window within the original step budget.` | `continue_timing` | `timing_window` | [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L385) |
| `tvOS midpoint pause must preserve the anchored public photo before manual Next.` | `control_action` | `scene_identity` | [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L391) |
| `tvOS midpoint setup requires a new stable public photo within the original step budget.` | `continue_timing` | `scene_identity` | [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L521) |
| `Midpoint pause confirmation must finish before T-2;` | `continue_timing` | `timing_window` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Midpoint pause tap must return before T-2;` | `continue_timing` | `timing_window` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `The playback page must have play/pause.` | `control_action` | `hidden_controls` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Play/pause must be hittable.` | `control_action` | `hidden_controls` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Play/pause must be hittable before continuing.` | `control_action` | `hidden_controls` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Play/pause value must be readable before acting.` | `control_action` | `probe_readback` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Play/pause must be paused before continuing.` | `continue_timing` | `control_state` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Must be playing before the mid-interval timing.` | `continue_timing` | `control_state` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Must be paused after the midpoint.` | `control_action` | `control_state` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Should be playing after Continue.` | `continue_timing` | `control_state` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `This narrow entry must not enable a password.` | `settings_navigation` | `control_state` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Playback settings must provide the autoplay toggle.` | `unknown` | `hidden_controls` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift), [AccessLifecycleIOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Settings.swift) |
| `Autoplay must be turned on through the real settings.` | `interval_setup` | `control_state` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Autoplay must be on for the pause/background cases.` | `interval_setup` | `control_state` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `The pause/background cases must be able to switch to single-photo mode.` | `interval_setup` | `hidden_controls` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `The display policy should offer single-photo mode.` | `unknown` | `hidden_controls` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift), [AccessLifecycleIOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Settings.swift) |
| `Must return to the playback page after settings.` | `settings_navigation` | `navigation` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Failed to persist iPad watch sample diagnostics:` | `continue_timing` | `evidence_capture` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `First-half-window evidence after Continue crossed the window;` | `continue_timing` | `timing_window` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Auto advance came before T-2;` | `continue_timing` | `timing_window` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `A black screen with no new photo cannot pass automatically` | `continue_timing` | `scene_identity` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `The iPad transition criterion is missing the original photo luma before Continue` | `continue_timing` | `evidence_capture` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `iPad pause-continue lacks valid timing or original photo brightness evidence` | `continue_timing` | `evidence_capture` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `iPad pause-continue is missing verifiable old-photo and transition samples` | `continue_timing` | `evidence_capture` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `iPad pause-continue samples contain invalid timing or brightness` | `continue_timing` | `evidence_capture` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `iPad pause-continue samples are out of order or have a gap` | `continue_timing` | `evidence_capture` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `iPad pause-continue: no transition start via sustained dimming or new photo` | `continue_timing` | `scene_identity` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `A continuous, reliable screenshot of the previous photo must precede the iPad transition start;` | `continue_timing` | `evidence_capture` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `iPad transition: conservative screenshot range must lie fully within T±2 s` | `continue_timing` | `timing_window` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `iPad must keep identifying a different new photo for at least 1 second` | `continue_timing` | `scene_identity` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `iPad new photo must be stably identifiable within 4 s of transition start` | `continue_timing` | `scene_identity` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `Record until a new photo is identifiable, not until the T+2 identity timeout` | `continue_timing` | `evidence_capture` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `Next-photo stable confirmation does not match the current raw screenshot` | `visible_scene_capture` | `evidence_capture` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Next photo did not form a stable new MATCH within ` | `visible_scene_capture` | `scene_identity` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Control-bar calibration must recognize the visible Settings crop.` | `visible_scene_capture` | `evidence_capture` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift); Settings-crop reference unwrap |
| `Screenshot cannot be used as identity;` | `visible_scene_capture` | `scene_identity` | [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `Must be able to return from settings to the playback page.` | `settings_navigation` | `navigation` | [AccessLifecycleIOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Navigation.swift) |
| `The settings list must provide the playback settings entry` | `settings_navigation` | `navigation` | [AccessLifecycleIOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Navigation.swift) |
| `After opening playback settings, the autoplay toggle or the playback settings title must be visible.` | `settings_navigation` | `navigation` | [AccessLifecycleIOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Navigation.swift) |
| `Must not use the internal progress probe as the final criterion` | `unknown` | `evidence_capture` | [AccessLifecycleContract+Controls.swift](../TestSupport/AccessLifecycleContract+Controls.swift) |
| `launchEnvironment must not force-override the settings under test` | `unknown` | `evidence_capture` | [AccessLifecycleContract+Controls.swift](../TestSupport/AccessLifecycleContract+Controls.swift) |
| `Must not use the internal progress value instead of time and the screen` | `control_action` | `evidence_capture` | [AccessLifecycleContract+Controls.swift](../TestSupport/AccessLifecycleContract+Controls.swift) |
| `Photo changes while paused must not be judged by control value changes alone` | `control_action` | `evidence_capture` | [AccessLifecycleContract+Controls.swift](../TestSupport/AccessLifecycleContract+Controls.swift) |
| `The next photo after pause must show a different public pattern` | `control_action` | `scene_identity` | [AccessLifecycleContract+Controls.swift](../TestSupport/AccessLifecycleContract+Controls.swift) |
| `Tap the canvas to wake it before confirming play/pause` | `control_action` | `hidden_controls` | [AccessLifecycleContract+Controls.swift](../TestSupport/AccessLifecycleContract+Controls.swift) |
| `Do not tap again and toggle playback` | `control_action` | `control_state` | [AccessLifecycleContract+Controls.swift](../TestSupport/AccessLifecycleContract+Controls.swift) |
| `The confirmation wait must not happen before continueAt` | `continue_timing` | `timing_window` | [AccessLifecycleContract+Controls.swift](../TestSupport/AccessLifecycleContract+Controls.swift) |
| `A leftover settings button must not stand in for operable play/pause controls` | `control_action` | `hidden_controls` | [AccessLifecycleContract+Controls.swift](../TestSupport/AccessLifecycleContract+Controls.swift) |
| `The click return time must not be earlier than the press` | `continue_timing` | `timing_window` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `Evidence crossing the window must not pass automatically` | `continue_timing` | `timing_window` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `Black screen without a new photo must not pass automatically` | `continue_timing` | `scene_identity` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `Black screen, zoom, control bar gone or unrecognized is not a transition` | `continue_timing` | `scene_identity` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `An in-window start was detected but not signed off` | `continue_timing` | `evidence_capture` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `Uncertain samples must remain pending video review; do not default to PASS` | `continue_timing` | `evidence_capture` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `Too early/late transition or missing start cannot pass automatically` | `continue_timing` | `timing_window` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `Visual ID failed history-start:` | `history_start_capture` | `scene_identity` | [StrictE2ETestSupport.swift](../TestSupport/StrictE2ETestSupport.swift), via [iOS history steps](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) and [tvOS history evidence names](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift); initial capture |
| `Visual ID failed history-first-next:` | `history_first_next_capture` | `scene_identity` | [StrictE2ETestSupport.swift](../TestSupport/StrictE2ETestSupport.swift), via [iOS history steps](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) and [tvOS history evidence names](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift); first Next capture |
| `Visual ID failed history-second-next:` | `history_second_next_capture` | `scene_identity` | [StrictE2ETestSupport.swift](../TestSupport/StrictE2ETestSupport.swift), via [iOS history steps](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) and [tvOS history evidence names](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift); second Next capture |
| `Visual ID failed history-first-previous:` | `history_first_previous_capture` | `scene_identity` | [StrictE2ETestSupport.swift](../TestSupport/StrictE2ETestSupport.swift), via [iOS history steps](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) and [tvOS history evidence names](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift); first Previous capture |
| `Visual ID failed history-second-previous:` | `history_second_previous_capture` | `scene_identity` | [StrictE2ETestSupport.swift](../TestSupport/StrictE2ETestSupport.swift), via [iOS history steps](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) and [tvOS history evidence names](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift); second Previous capture |
| `rotation-start-portrait did not stabilize within the ` | `rotation_start_capture` | `timing_window` | [RotationUITests.swift](../immichSlidesUITests/RotationUITests.swift); initial portrait stable wait |
| `rotation-landscape-stable did not stabilize within the ` | `rotation_landscape_capture` | `timing_window` | [RotationUITests.swift](../immichSlidesUITests/RotationUITests.swift); landscape stable wait |
| `rotation-portrait-stable did not stabilize within the ` | `rotation_portrait_capture` | `timing_window` | [RotationUITests.swift](../immichSlidesUITests/RotationUITests.swift); final portrait stable wait |
| `layout-landscape-multi did not stabilize within the ` | `visible_scene_capture` | `timing_window` | [RotationUITests.swift](../immichSlidesUITests/RotationUITests.swift); iPad landscape multi-photo stable wait |
| `layout-portrait-multi did not stabilize within the ` | `visible_scene_capture` | `timing_window` | [RotationUITests.swift](../immichSlidesUITests/RotationUITests.swift); iPad portrait multi-photo stable wait |
| `Could not recognize a public photo on screen within ` | `visible_scene_capture` | `scene_identity` | [RotationUITests.swift](../immichSlidesUITests/RotationUITests.swift); public photo identity before Next |
| `The public photo on screen did not change after next;` | `history_navigation` | `scene_identity` | [RotationUITests.swift](../immichSlidesUITests/RotationUITests.swift); Next must start a new scene before rotation |
| `Before rotating, the play button value must be pause (playing),` | `control_action` | `control_state` | [RotationUITests.swift](../immichSlidesUITests/RotationUITests.swift); playing-state precondition |
| `The rotation sequence took ` | `unknown` | `timing_window` | [RotationUITests.swift](../immichSlidesUITests/RotationUITests.swift); whole sequence must precede the earliest natural switch |
| `Orientation API: after setting ` | `unknown` | `navigation` | [RotationUITests.swift](../immichSlidesUITests/RotationUITests.swift); shared orientation API window readback |
| `Fresh install must open the normal first-boot page.` | `firstboot_setup` | `navigation` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); initial configuration page |
| `First-boot page must show the API Key field.` | `firstboot_setup` | `navigation` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); secure field availability |
| `The API Key must be entered into the secure field.` | `firstboot_setup` | `control_state` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); secure field value readback |
| `First-boot page must show Test Connection.` | `firstboot_setup` | `navigation` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); connection control availability |
| `First-boot page must show the Save Settings button.` | `firstboot_setup` | `navigation` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); save control availability |
| `A successful save must lead to mode selection.` | `firstboot_setup` | `navigation` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); post-save destination |
| `The interval must be set to 30 seconds with the real slider.` | `interval_setup` | `interval_readback` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); interval slider readback |
| `Playback settings must have display mode segments.` | `display_policy` | `navigation` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); display-mode picker availability |
| `Display mode must offer the target option.` | `display_policy` | `navigation` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); target option availability |
| `Display mode must switch to the target option.` | `display_policy` | `control_state` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); selected option readback |
| `Must be able to return from settings to playback.` | `settings_navigation` | `navigation` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); settings exit |
| `Settings list must have the playback settings entry.` | `settings_navigation` | `navigation` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); playback section availability |
| `After opening playback settings, the auto-play toggle or the playback settings title must be visible.` | `settings_navigation` | `navigation` | [IOSDriver.swift](../immichSlidesUITests/IOSDriver.swift); playback section destination |
| `The mode page must also offer the filter entry.` | `mode_selection` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift); filter entry availability |
| `Playback page after uninstall means a dirty install container;` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift); fresh-install destination |
| `The public test URL must be entered verbatim,` | `firstboot_setup` | `control_state` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift); server field readback |
| `API Key must reach the secure field;` | `firstboot_setup` | `control_state` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift); secure field readback |
| `iPad must rotate to landscape to record split-view evidence.` | `unknown` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift); iPad orientation precondition |
| `The first-boot filter summary must offer a way back to mode selection.` | `mode_selection` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift); return entry availability |
| `The iOS filter summary should no longer use a bottom back button,` | `mode_selection` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift); expected return affordance |
| `Connection test showed a failure alert:` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift); alert blocks connection/save progression; no connection-cause class is claimed |
| `Pause again before history actions so the 5-second timer does not interfere.` | `control_action` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift); paused-state precondition |
| `A nil mark must encode into JSON,` | `visible_scene_capture` | `evidence_capture` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift); capture evidence cannot be serialized; no pixel identity is claimed |
| `tvOS pause-continue evidence is invalid;` | `continue_timing` | `evidence_capture` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `tvOS new photo must be stably identifiable within 4 s of transition start` | `continue_timing` | `scene_identity` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `tvOS Continue wake timing precondition failed: Up must not be requested before T-2.` | `continue_timing` | `timing_window` | [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift); test-timing precondition, always red |
| `All black must not count as a pass` | `unknown` | `scene_identity` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift) |
| `Blank must not count as a pass` | `unknown` | `scene_identity` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift) |
| `Unrecognizable input must not count as a pass` | `unknown` | `scene_identity` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift) |
| `The first-boot page must show the Save Settings button.` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `After a successful save, the app must reach mode selection.` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `A fresh install must reach the normal first-boot page.` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `The first-boot page must show the API Key field.` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `The first-boot page must show the Test Connection button.` | `firstboot_setup` | `navigation` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `Save must become enabled after a real connection test succeeds.` | `firstboot_setup` | `control_state` | [StrictE2EFirstBatchIOSUITests+Onboarding.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+Onboarding.swift) |
| `A cold launch with saved settings must not return to the first-boot page.` | `cold_relaunch` | `navigation` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `A configured cold launch must go straight to the playback page.` | `cold_relaunch` | `navigation` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `First-boot mode navigation must dismiss the exact password prompt,` | `mode_selection` | `navigation` | [UITestSupport.swift](../immichSlidesUITests/UITestSupport.swift) |
| `Mode departure failed after one hittable Continue without a password prompt;` | `playback_entry` | `navigation` | [UITestSupport.swift](../immichSlidesUITests/UITestSupport.swift) |
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
| `Album capture preparation must reach a stable scene before Pause.` | `control_action` | `timing_window` | [StrictE2EFilterIOSUITests+Navigation.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift) |
| `Album capture preparation paused during a transition; Pause freezes the current layers.` | `control_action` | `control_state` | [StrictE2EFilterIOSUITests+Navigation.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift) |
| `Album capture preparation must observe paused playback after one Pause.` | `control_action` | `control_state` | [StrictE2EFilterIOSUITests+Navigation.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift) |
| `Album capture preparation must reach a complete paused scene within the playback capture budget.` | `visible_scene_capture` | `probe_readback` | [StrictE2EFilterIOSUITests+Navigation.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift) |
| `Album capture pixels must match at least 0.6 seconds apart within the playback capture budget.` | `visible_scene_capture` | `scene_identity` | [StrictE2EFilterIOSUITests+Navigation.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift) |
| `Album interval confirmation must read a valid non-empty scene progress probe before Pause.` | `interval_setup` | `probe_readback` | [StrictE2EFilterIOSUITests+Navigation.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift) |
| `Album interval confirmation must observe a new scene after measuring a short interval before Pause.` | `interval_setup` | `timing_window` | [StrictE2EFilterIOSUITests+Navigation.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift) |
| `Album interval confirmation must measure the current scene's 30-second progress slope before Pause.` | `interval_setup` | `interval_readback` | [StrictE2EFilterIOSUITests+Navigation.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift) |
| `Album Next must advance the paused scene within the playback capture budget.` | `history_navigation` | `navigation` | [StrictE2EFilterIOSUITests+Navigation.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift) |
| `Resuming must continue from the current photo, with the control value back to pause.` | `control_action` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `Previous must be disabled at the history boundary when playback starts.` | `history_navigation` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After two Next taps, Previous must be enabled.` | `history_navigation` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After a pause of at least 10 seconds, autoplay must not resume on its own.` | `paused_hold` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After injecting the public fixture, the app must reach the mode page.` | `mode_selection` | `navigation` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After returning to the playback page, the control bar must be revealed again.` | `settings_navigation` | `hidden_controls` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `The settings button must be tappable.` | `settings_navigation` | `hidden_controls` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `The settings list must offer the playback settings entry` | `settings_navigation` | `navigation` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `Could not return from playback settings to the playback page` | `settings_navigation` | `navigation` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `Playback settings must offer the display mode segmented control.` | `display_policy` | `navigation` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `Display mode must offer single photo mode.` | `display_policy` | `navigation` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `The segmented control must remain after selecting single photo mode.` | `display_policy` | `control_state` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `The display mode option must keep its Simplified Chinese copy.` | `display_policy` | `control_state` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `Playback settings must offer the EXIF toggle.` | `settings_navigation` | `navigation` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `Show EXIF info must be on.` | `interval_setup` | `control_state` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `The playback interval must be 5 seconds.` | `interval_setup` | `interval_readback` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `After identifying A2, Next must be tappable to check its successor.` | `pause_window` | `hidden_controls` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `PRECONDITION_FAIL: order became A2→` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `PRECONDITION_FAIL: A2 successor is not A3 (` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `PRECONDITION_FAIL: not the large-text A2 after returning.` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `PRECONDITION_FAIL: could not identify the large-text A2 using Next.` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `Window missed or required frames missing: ` | `pause_window` | `evidence_capture` | [StrictE2EPhotoIdentity.swift](../TestSupport/StrictE2EPhotoIdentity.swift), emitted by [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `The midpoint hook must leave the frame-synchronized probe paused.` | `pause_window` | `probe_readback` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `probe_hit=MISS: frame-synchronized probe never saw outgoing translucent and incoming opacity=0 in 7 s.` | `pause_window` | `timing_window` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `visual_verdict=MISSING_FRAMES: missing a window-detected, after-pause, after-pause-0_3s or play-to-pause keepAlways frame.` | `pause_window` | `evidence_capture` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `visual_verdict=BLACK_OR_BLANK: synced probe missing after pause, or outgoing opacity already 0.` | `pause_window` | `probe_readback` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After pausing, the synced probe does not meet outgoing opacity>0 and incoming opacity=0.` | `pause_window` | `probe_readback` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `The paused pause-window probe identity must not change.` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `Paused pause-window frames must be pixel-identical.` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `Pause window bright proof must show A2.` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `Pause window bright proof must be one frozen opaque scene.` | `pause_window` | `probe_readback` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `Pause window midpoint must contain visible photo pixels.` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `Target window shows the wrong image; cannot count as SUCCESS.` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `The control bar must be visible before opening settings.` | `control_action` | `hidden_controls` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift) |
| `The control bar must be visible before starting pause-window playback.` | `control_action` | `hidden_controls` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After tapping Play, the button value must become pause.` | `control_action` | `control_state` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `Pause before opening settings or identifying photos, so autoplay does not move away.` | `control_action` | `control_state` | [StrictE2EFirstBatchIOSUITests+PauseWindow.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests+PauseWindow.swift), [AccessLifecycleIOSUITests.swift](../immichSlidesUITests/AccessLifecycleIOSUITests.swift), [AccessLifecycleIOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleIOSUITests+Timing.swift) |
| `visual_verdict=LATE: a complete A3 is visible after pause.` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `After late completion the current public mark must stay: no flash back, all black or unreadable: ` | `late_image` | `scene_identity` | [StrictE2ELateImageIOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageIOSUITests.swift) |
| `Next must be tappable twice right after entering the slideshow, before old image requests finish.` | `late_image` | `navigation` | [StrictE2ELateImageIOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageIOSUITests.swift) |
| `Held response budget exhausted before release:` | `late_image` | `timing_window` | [StrictE2ELateImageSupport.swift](../immichSlidesUITests/StrictE2ELateImageSupport.swift) |
| `Late image held asset must belong to the cold-launch scene before the first Next.` | `late_image` | `fixture_response` | [StrictE2ELateImageSupport.swift](../immichSlidesUITests/StrictE2ELateImageSupport.swift) |
| `Late image fixture control failed:` | `late_image` | `fixture_response` | [StrictE2ELateImageSupport.swift](../immichSlidesUITests/StrictE2ELateImageSupport.swift) |
| `Late image cold launch must restore paused playback.` | `cold_relaunch` | `control_state` | [StrictE2ELateImageIOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageIOSUITests.swift), [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift) |
| `Late image preparation must enter playback before opening Settings.` | `late_image` | `navigation` | [StrictE2ELateImageIOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageIOSUITests.swift) |
| `Late image preparation must open Playback Settings.` | `late_image` | `navigation` | [StrictE2ELateImageIOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageIOSUITests.swift), [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift) |
| `Late image preparation must expose the Autoplay switch.` | `late_image` | `navigation` | [StrictE2ELateImageIOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageIOSUITests.swift) |
| `Late image preparation must turn Autoplay off.` | `late_image` | `control_state` | [StrictE2ELateImageIOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageIOSUITests.swift) |
| `Late image preparation must focus Settings.` | `late_image` | `focus` | [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift) |
| `Late image preparation must focus Playback Settings.` | `late_image` | `focus` | [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift) |
| `Late image preparation must expose the Autoplay option.` | `late_image` | `navigation` | [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift) |
| `Late image preparation must focus Autoplay.` | `late_image` | `focus` | [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift) |
| `Late image preparation must expose Autoplay Off.` | `late_image` | `navigation` | [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift) |
| `Late image preparation must focus Autoplay Off.` | `late_image` | `focus` | [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift) |
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
| `The album list must show ` | `unknown` | `navigation` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift), [Support](../immichSlidesUITests/StrictE2EFilterTVOSUITests+Support.swift): shared by initial selection, Settings edits and server switches; discard the dynamic album ID suffix. |
| `An empty album must show the frozen existing production empty-result copy and must not keep the old non-empty pool` | `filter_edit` | `scene_identity` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift): checks the existing empty-result copy after selecting the empty album through the Settings editor. |
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
| `Editor album card must show the manifest-selected album and photo counts` | `server_switch` | `control_state` | [StrictE2EFilterIOSUITests+Navigation.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests+Navigation.swift) |
| `After the change, a still frame taken mid-transition must not pass` | `display_policy` | `scene_identity` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `After changing the display mode, playback must still be on screen in the same live process.` | `display_policy` | `navigation` | [StrictE2EFilterTVOSUITests.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests.swift) |
| `No two distinct target-album photos were seen in one full four-frame candidate rotation; all candidate originals were kept.` | `display_policy` | `scene_identity` | [StrictE2EFilterIOSUITests.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests.swift) |
| `After the change it must be a stable single photo from the target album, not a transition or multi-photo` | `display_policy` | `scene_identity` | [StrictE2EFilterIOSUITests.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests.swift) |
| `The same live app process must run before and after the display policy change` | `display_policy` | `process_lifetime` | [StrictE2EFilterIOSUITests.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests.swift) |
| `After the server switch, single-photo mode must show a stable single photo from B's target album` | `server_switch` | `scene_identity` | [StrictE2EFilterIOSUITests.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests.swift) |
| `The same process must run before and after applying single-photo mode after the server switch` | `server_switch` | `process_lifetime` | [StrictE2EFilterIOSUITests.swift](../immichSlidesUITests/StrictE2EFilterIOSUITests.swift) |
| `SmartFill must expose the complete manifest, stable visible render state and history cursor together` | `visible_scene_capture` | `probe_readback` | [PlaybackHistoryIOSUITests+Support.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift) |
| `After tapping next, the fully visible SmartFill scene identity did not change in ` | `history_navigation` | `scene_identity` | [PlaybackHistoryIOSUITests+Support.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift) |
| `scene identity did not change` | `history_navigation` | `scene_identity` | [PlaybackHistoryIOSUITests+Support.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift), manual Next / Previous identity poll |
| `Pausing must freeze the current transform progress` | `paused_hold` | `scene_identity` | [PlaybackHistoryIOSUITests.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests.swift) |
| `The new scene from a manual next while paused must stay still at p=0` | `paused_hold` | `scene_identity` | [PlaybackHistoryIOSUITests.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests.swift) |
| `The scene from a manual previous while paused must stay still at p=0` | `paused_hold` | `scene_identity` | [PlaybackHistoryIOSUITests.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests.swift) |
| `Play must make the current still scene start moving from p=0 immediately` | `control_action` | `scene_identity` | [PlaybackHistoryIOSUITests.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests.swift) |
| `SmartFill Pause preparation was rejected before the deadline.` | `control_action` | `timing_window` | [PlaybackHistoryIOSUITests.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests.swift), SmartFill Pause delivery-margin gate; the detail names the last gate observation's reason (possibly `none (snapshot gate passed)`) and its remaining margin |
| `After starting playback, the playback page should open and show the control bar` | `playback_entry` | `navigation` | [FilterSummaryIOSVisualUITests+Launch.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Launch.swift) |
| `The slideshow control never became tappable before the deadline.` | `control_action` | `hidden_controls` | [UITestSupport.swift](../immichSlidesUITests/UITestSupport.swift), shared playback control-bar tap callers; [ScenePresentationContractUITests.swift](../immichSlidesUITests/ScenePresentationContractUITests.swift), recovery Next/redo preparation |
| `The slideshow Settings tap had no observed outcome before the deadline.` | `settings_navigation` | `navigation` | [UITestSupport.swift](../immichSlidesUITests/UITestSupport.swift) |
| `The slideshow Settings button must be ready before opening playback settings.` | `settings_navigation` | `hidden_controls` | [PlaybackHistoryIOSUITests+Support.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift) |
| `Playback page should show the settings button` | `unknown` | `hidden_controls` | [FilterSummaryIOSVisualUITests+Navigation.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Navigation.swift), [FilterSummaryTVOSVisualUITests+Playback.swift](../immichSlidesUITests/FilterSummaryTVOSVisualUITests+Playback.swift) |
| `After entering the playback page, the settings button should be visible` | `playback_entry` | `navigation` | [FilterSummaryIOSVisualUITests+Navigation.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Navigation.swift) |
| `Before each screenshot, the playback control bar should wake up reliably` | `visible_scene_capture` | `hidden_controls` | [FilterSummaryIOSVisualUITests+Exif.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Exif.swift) |
| `The control bar may have auto-hidden while waiting for the sampling overlay; it should wake up again before tapping next` | `visible_scene_capture` | `hidden_controls` | [FilterSummaryIOSVisualUITests+Exif.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Exif.swift) |
| `Before retrying next, the playback control bar should wake up again` | `control_action` | `hidden_controls` | [FilterSummaryIOSVisualUITests+Exif.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Exif.swift) |
| `Could not return from the playback settings page to the slideshow` | `settings_navigation` | `navigation` | [PlaybackHistoryIOSUITests+Support.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift) |
| `The playback index probe is empty, so autoplay and retained-history cannot be proven.` | `history_navigation` | `probe_readback` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L835) |
| `Settings subpage must show target option ` | `settings_navigation` | `navigation` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L247) |
| `Must be able to focus ` | `unknown` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L249), [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L135), [TVDriver.swift](../immichSlidesUITests/TVDriver.swift#L237) |
| `After choosing settings.playback.` | `unknown` | `control_state` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L252), [TVDriver.swift](../immichSlidesUITests/TVDriver.swift#L226) |
| `Playback page must show the settings button.` | `settings_navigation` | `hidden_controls` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L410) |
| `Settings button must have focus before opening.` | `settings_navigation` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L419) |
| `After Select on settings, must enter settings or the PIN gate.` | `settings_navigation` | `navigation` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L427) |
| `After returning from settings, must wait for the playback transition to finish.` | `settings_navigation` | `timing_window` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L458) |
| `After returning from settings with the bar hidden, the hidden receiver must have stable focus.` | `settings_navigation` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L467) |
| `After returning from settings, the playback transition must finish before a directional press.` | `unknown` | `timing_window` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L480) |
| `After returning from settings, confirm stable hidden receiver focus before one directional press.` | `unknown` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L486) |
| `First directional press must only wake controls.` | `unknown` | `hidden_controls` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L129) |
| `Settings page must have ` | `settings_navigation` | `navigation` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L642) |
| `Directional key must wake the playback controls.` | `hidden_controls` | `hidden_controls` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L666) |
| `The field must be focused before input.` | `firstboot_setup` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L673), [TVDriver.swift](../immichSlidesUITests/TVDriver.swift#L259) |
| `System keyboard must show Next or Done.` | `firstboot_setup` | `navigation` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L682) |
| `Must focus the system keyboard submit button before submitting text.` | `firstboot_setup` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L686) |
| `After submitting text, focus must return to the field.` | `firstboot_setup` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L691) |
| `A clean install must open the first-boot form.` | `firstboot_setup` | `navigation` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L11), [TVDriver.swift](../immichSlidesUITests/TVDriver.swift#L15) |
| `First-boot form must show the API Key field.` | `firstboot_setup` | `navigation` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L18), [TVDriver.swift](../immichSlidesUITests/TVDriver.swift#L21) |
| `URL submitted; focus must move down to API Key.` | `firstboot_setup` | `focus` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L19) |
| `First-boot form must show Test Connection.` | `firstboot_setup` | `navigation` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L29) |
| `With the real controlled service reachable, the connection test must show as passed.` | `firstboot_setup` | `navigation` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L37) |
| `After connecting, the Save Settings button must show.` | `firstboot_setup` | `navigation` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L47) |
| `After a successful connection, Save Settings must be enabled.` | `firstboot_setup` | `control_state` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L48), [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift#L282), [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L690), [TVDriver.swift](../immichSlidesUITests/TVDriver.swift#L44) |
| `After saving settings, mode selection must open.` | `mode_selection` | `navigation` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L57) |
| `Mode selection focus must start on random playback.` | `mode_selection` | `focus` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L61) |
| `After choosing random play, Continue must show.` | `mode_selection` | `navigation` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L68) |
| `After choosing random play, Continue must be enabled.` | `mode_selection` | `control_state` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L69) |
| `After choosing random play, focus must move down to Continue.` | `mode_selection` | `focus` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L74) |
| `Settings home must show playback settings.` | `settings_navigation` | `navigation` | [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L89), [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L24) |
| `Must return to playback settings.` | `settings_navigation` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L183), [AccessLifecycleTVOSUITests+Settings.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Settings.swift#L537), [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L26) |
| `Focus must reach play/pause.` | `control_action` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L12), [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L315) |
| `After pause, focus must reach next.` | `control_action` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L27), [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L334) |
| `Focus must return to play/pause after next.` | `control_action` | `focus` | [AccessLifecycleTVOSUITests+Navigation.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Navigation.swift#L36), [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L368) |
| `Screenshot before-pause cannot serve as identity:` | `visible_scene_capture` | `scene_identity` | [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L573) |
| `Screenshot after-next cannot serve as identity:` | `visible_scene_capture` | `scene_identity` | [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L573) |
| `Screenshot before-background cannot serve as identity:` | `visible_scene_capture` | `scene_identity` | [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L573) |
| `Screenshot after-background cannot serve as identity:` | `visible_scene_capture` | `scene_identity` | [AccessLifecycleTVOSUITests+Timing.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests+Timing.swift#L573) |
| `Pause/continue tvOS must run on a tvOS Simulator.` | `unknown` | `unknown` | [AccessLifecycleTVOSUITests.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests.swift#L219) |
| `Control bar must show after random playback.` | `playback_entry` | `hidden_controls` | [AccessLifecycleTVOSUITests.swift](../immichSlidesUITests/AccessLifecycleTVOSUITests.swift#L80) |
| `The full tvOS flow must run on a tvOS Simulator.` | `unknown` | `unknown` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L30) |
| `After saving settings, the app must reach the mode selection page.` | `mode_selection` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L43) |
| `After choosing filtered playback, the Continue button must appear.` | `mode_selection` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L211) |
| `After choosing filtered playback, the Continue button must be enabled.` | `mode_selection` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L215) |
| `Focus on the filter summary page must be able to move to Back to Mode Selection.` | `mode_selection` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L235) |
| `Going back from the filter summary must return to the mode selection page.` | `mode_selection` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L242) |
| `After choosing random playback, the Continue button must be enabled.` | `mode_selection` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L249) |
| `After choosing random playback, focus must be able to move down to the Continue button.` | `mode_selection` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L254) |
| `The first playback round must show the one-time remote hint.` | `playback_entry` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L271) |
| `While the one-time hint is shown, default focus must land on the settings button.` | `playback_entry` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L275) |
| `The playback control bar must show the previous button.` | `control_action` | `hidden_controls` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L280) |
| `At the initial history boundary, previous must be disabled.` | `history_navigation` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L282) |
| `Before the history chain starts, focus must be able to move to Play/Pause.` | `history_navigation` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L290) |
| `Autoplay must be paused before the history chain starts.` | `history_navigation` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L298) |
| `After the control bar hides, the wake focus receiver layer must appear.` | `hidden_controls` | `hidden_controls` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L309) |
| `The playback page must expose the read-only index probe.` | `history_navigation` | `probe_readback` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L332) |
| `The start of the history chain must show the previous button.` | `history_navigation` | `hidden_controls` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L338) |
| `A must be at the history start of the current playback session.` | `history_navigation` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L340) |
| `Focus must be able to move from Play/Pause to Next.` | `history_navigation` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L352) |
| `The first next must advance the playback cursor.` | `history_navigation` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L359) |
| `After the first next settles, focus must be able to move to Next again.` | `history_navigation` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L374) |
| `The second next must advance the playback cursor further.` | `history_navigation` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L381) |
| `Focus must be able to move from Next back to Play/Pause.` | `history_navigation` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L396) |
| `Once history exists, focus must be able to move to Previous.` | `history_navigation` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L403) |
| `After the first previous, one earlier history entry remains, so the button must stay enabled.` | `history_navigation` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L411) |
| `After going back once, focus must be able to move to Previous again.` | `history_navigation` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L425) |
| `The end of the history chain must show the previous button.` | `history_navigation` | `hidden_controls` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L434) |
| `After the second previous returns to the history start, the button must be disabled again.` | `history_navigation` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L438) |
| `Before checking autoplay, focus must be able to move to Next.` | `control_action` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L451) |
| `After consuming one step of forward history, focus must be able to move to Next again.` | `history_navigation` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L461) |
| `At the history frontier, focus must be able to move to Play/Pause.` | `history_navigation` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L472) |
| `Pressing Select after pausing must resume autoplay.` | `control_action` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L491) |
| `After auto-advance, focus on wake must return to Play/Pause.` | `control_action` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L487) |
| `The index probe must change after a playback action.` | `history_navigation` | `probe_readback` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L492) |
| `Pressing Select after auto-advance must pause playback.` | `control_action` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L509) |
| `Pausing must not advance an extra photo.` | `paused_hold` | `scene_identity` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L516) |
| `The paused-frame comparison must span at least 10 seconds.` | `paused_hold` | `timing_window` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L530) |
| `During a pause of at least 10 seconds, autoplay must not catch up.` | `paused_hold` | `scene_identity` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L535) |
| `After the pause wait, focus on wake must return to Play/Pause.` | `control_action` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L539) |
| `After the pause wait, autoplay must be resumable.` | `control_action` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L570) |
| `After autoplay resumes, focus on wake must return to Play/Pause.` | `control_action` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L576) |
| `After resuming, playback must advance to another photo.` | `history_navigation` | `probe_readback` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L585) |
| `Autoplay must be pausable again before entering settings.` | `control_action` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L616) |
| `Focus in the playback control bar must be able to move to Settings.` | `settings_navigation` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L622) |
| `The settings button must open the settings page.` | `settings_navigation` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L628) |
| `Pressing Back/Menu on the settings page must return to the playback page.` | `settings_navigation` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L634) |
| `A clean install must reach the first-boot form.` | `firstboot_setup` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L89) |
| `The first-boot form must show the API Key field.` | `firstboot_setup` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L94) |
| `After submitting the URL, focus must be able to move down to API Key.` | `firstboot_setup` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L99) |
| `The first-boot form must show the Test Connection button.` | `firstboot_setup` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L109) |
| `Once the real controlled service is reachable, the connection-test-passed status must show.` | `firstboot_setup` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L675) |
| `Select must not accidentally hit the API Key help sheet.` | `firstboot_setup` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L679) |
| `After a successful connection, the Save Settings button must appear.` | `firstboot_setup` | `navigation` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L688) |
| `The field must be focused before typing.` | `unknown` | `focus` | [StrictE2EFilterTVOSUITests+Support.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests+Support.swift#L381), [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift#L289), [StrictE2ESmokeUITests.swift](../immichSlidesUITests/StrictE2ESmokeUITests.swift#L124), [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L699) |
| `The system keyboard must show Next or Done.` | `unknown` | `navigation` | [StrictE2EFilterTVOSUITests+Support.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests+Support.swift#L394), [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift#L299), [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L709), [TVDriver.swift](../immichSlidesUITests/TVDriver.swift#L266) |
| `Focus the system keyboard submit button before submitting text.` | `firstboot_setup` | `focus` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L713) |
| `The server address must be submitted verbatim.` | `firstboot_setup` | `control_state` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L718) |
| `After submitting text, focus must return to the original field.` | `unknown` | `focus` | [StrictE2EFilterTVOSUITests+Support.swift](../immichSlidesUITests/StrictE2EFilterTVOSUITests+Support.swift#L403), [StrictE2ELateImageTVOSUITests.swift](../immichSlidesUITests/StrictE2ELateImageTVOSUITests.swift#L312), [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L722) |
| `An arrow key must wake the playback control bar.` | `hidden_controls` | `hidden_controls` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L828) |
| `The index probe must change after a playback action. advanceObserved=` | `history_navigation` | `probe_readback` | [StrictE2ETVOSFlowUITests.swift](../immichSlidesUITests/StrictE2ETVOSFlowUITests.swift#L903) |
| `Interval options are missing` | `interval_setup` | `interval_readback` | [AccessLifecycleContract+Controls.swift](../TestSupport/AccessLifecycleContract+Controls.swift#L53) |
| `Identity comes only from public fixture photos, never from logs or index` | `visible_scene_capture` | `evidence_capture` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift#L122) |
| `A forced display mode must not replace the real settings path` | `visible_scene_capture` | `evidence_capture` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift#L160) |
| `Returning to playback must not require the control bar to be visible` | `settings_navigation` | `evidence_capture` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift#L326) |
| `Returning to playback must confirm the playback layer` | `unknown` | `navigation` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift#L329) |
| `After settings return, no direction key until the transition completes` | `unknown` | `timing_window` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift#L359) |
| `After settings return, must confirm the hidden receiver holds focus stably` | `unknown` | `focus` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift#L365) |
| `Must not press twice to mask the first wake` | `unknown` | `hidden_controls` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift#L368) |
| `Wake after settings return is missing before/after screenshots` | `unknown` | `evidence_capture` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift#L371) |
| `A missing image must not count as a pass` | `visible_scene_capture` | `scene_identity` | [AccessLifecycleContract.swift](../TestSupport/AccessLifecycleContract.swift#L437) |

Dynamic leading step names, interpolated album/scene identifiers, bare assertions and
generic messages whose phase is ambiguous remain `unknown`. In particular, the recovery
flow's step-name-led photo checks and shared driver messages beginning with a press
count cannot be classified by this table. The complete-SmartFill-probe prefix diagnoses
combined evidence readback, without deciding which component is absent. Screenshot-empty
and the turning-off-Autoplay prefix retain their previous `unknown` pair. A mixed list containing
an unmatched message or different phase/class pairs still yields the `unknown` pair,
even when another message matches a new row. No hosted hit-rate improvement is claimed
until actual official failure summaries exercise these prefixes.

`Window missed or required frames missing: ` reaches XCTest through the
pause-window caller's `XCTFail(error.localizedDescription)`, with the `failed - `
wrapper, rather than a caught-error wrapper. It cannot be the first failure:
`continueAfterFailure = false` stops this case at the earlier `probe_hit=MISS`
or `visual_verdict=MISSING_FRAMES` check before `assertRequiredFrames` can report it.
Likewise, the flow's outer first/second-Next assertions cannot be first failures:
`waitForScenePublicationAdvance` emits the index-probe `XCTFail` before returning
false, and `continueAfterFailure = false` stops the test there. Their rows describe
the assertions without claiming those outer messages are observed first failures.

Still unknown on the throwing path:

- `Do not use click return time to hide the action's elapsed time` throws
  `AssertionError.message` with the apostrophe escaped as `action\'s`; it has no
  matching table row, like the escaped EXIF sentence below.
- `Fixture image response control timed out` throws the `Failure` struct. Its
  `Failure(message:)` wrapper is supported, but the sentence has no table row;
  a direct caught-error description also remains unmatched.
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
discard the whole attempt as unavailable evidence.
Rollback within the 90-day nightly retention window also restores a reader that
cannot read retained records containing these new phases.
Record fields, scanner implementation, verdicts, populations and budgets do not
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
