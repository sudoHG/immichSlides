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
Synthetic coverage includes A1/A2 and B1/B2 at iPhone, iPad and tvOS dimensions,
both orientations, and motion scales 1.00/1.10. Background-only geometry controls
must remain nonmatches; duplicate controls retain their original hue status and
do not count as independent rejection coverage.
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

The Swift `captureIdentity` and Python `capture_identity` readers locate each
photo's palette rectangle, rather than assuming equal quadrants or full-span strips. They use
the public fixture RGB pairs, the same tolerance 12 and minimum 18 matching pixels
per line, and a nearest-neighbour sample capped at 480 pixels wide. A composite
requires two or three distinct, non-overlapping rectangles that tile their canvas.
That canvas must cover the image center and fill at least one image axis; each
slot needs clean rows and columns and an independent interior color match.
This covers unequal doubles, balanced triples and the four primary-plus-pair
triple orientations. Missing interior lines can join only matching neighbours;
an entirely black outer edge contributes no identity. Mixed slot lines, overlaps
and gaps reject the composite. A fractional slot boundary may leave one sampled
row or column between rectangles: every pixel must be an interpolation of its
immediate neighbours in two distinct slots, within the existing RGB tolerance.
Black seams and wider gaps remain rejected. Identities use top-to-bottom, then
left-to-right rectangle order. Otherwise the original whole-frame verdict is preserved,
so single-photo, black and transition frames gain no composite identity. These
helpers ship only in test targets; the glyph/texture validators and their
acceptance requirements are unchanged.
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

`UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE=1` enables the Debug manifest probes.
Probe-only launches are `journey-b`, `tvos-flow`, `tvos-person`, `late-image`, `ios-lifecycle-first-wake`,
and `AccessLifecycleIOSUITests.prepareLaunch`, including its cold relaunches and
`run_access_lifecycle_ios.py`'s `testAccessProtectionSettingsAndLifecycle`.
For `tvos-person`, the scene key also exposes the existing read-only SmartFill
manifest, motion-frame summary and EXIF tone accessibility anchors. These clear
anchors read existing state; they do not change photo rendering, transition clocks,
auto-hide deadlines or playback commands. Motion trace collection requires its
separate key and is not enabled. Their extra accessibility/label computation is
diagnostic overhead, not a product timing override.
The `ios-lifecycle-settings`, `ios-lifecycle-pause` and `ios-lifecycle-background`
selectors use an empty launch environment and forbid the scene probe.
`pause-window` sets the probe plus `UI_TEST_SERVER_URL`, `UI_TEST_API_KEY`,
`UI_TEST_RESET_STATE`, `UI_TEST_FORCE_MODE_SELECTION` and
`UI_TEST_PAUSE_AT_AUTOMATIC_FADE_MIDPOINT=1`. The last key enables a Debug-only,
one-shot pause at the midpoint of the first automatic fade-out after the first
user Play, through the same command as the user's Pause. Automatic fades before
the first user Play cannot consume the hook. The UI test polls only the frame-synchronized probe
until it reports paused with 0 < outgoing opacity < 1 and incoming opacity 0,
then captures the frozen frame and verifies its identity, opacity and motion
through the existing 0.3-second hold. The verdict records the actual outgoing
opacity and the probe-derived paused state; a delayed midpoint callback still
counts when it freezes a translucent outgoing frame. Exact screenshot pixel comparison reuses
the paused-photo comparator's existing chrome exclusions and minimum compared
area; the Python identity verdict remains unchanged. Preparation uses the
existing control-bar tap helper before Next and Previous, and reveals the bar
before starting Play's existing 7-second clock, so evidence reads cannot consume
the bar's visibility window.
It no longer checks whether a human tap can land inside the fade window;
`AutomaticTransitionPauseTests` covers the reducer's pause semantics. Release
compiles out the timer and pause action and returns false for the launch flag.
`tvos-directional-wake` sets those four legacy keys plus
`UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT`, and does not set the scene probe.
Other probe-key launches are the configured SmartFill launch helpers in
`PlaybackHistoryIOSUITests`, `ScenePresentationContractUITests`, and
`FilterSummaryTVOSVisualUITests.testTVOSSlideShowControlBarButtonsCanActivateOnSelect`.
They also set other `UI_TEST_*` keys, so their XCTest mode remains enabled.
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
File-read failures remain I/O errors. tvOS reports retain their existing fields.

## Deterministic late-image response ordering

The `late-image` suite arms `/api/test/late-image` after normal first-boot setup.
Only loopback clients with the existing public fixture key can use this control,
and only in the `out-of-order` scenario. The server chooses the first preview or
fullsize request after arming, by serialized request order, and holds responses
for that asset until the test posts `{"action":"release"}`. Thumbnails and other
assets remain available. Each `{"action":"arm"}` starts a numbered generation;
a new generation is allowed only after the previous one is released and has no
pending responses. Onboarding requests are served normally before arming.
The frozen manifest's legacy delay metadata stays
unchanged for hash compatibility and no longer schedules responses.

Both platform tests pause playback before Next, verify two committed history
advances and a complete stable rendered scene with fallible snapshot probes,
then capture `ooo-current-scene`. They explicitly release the hold, poll for
zero pending responses and at least one successful socket write/flush with no
disconnects, retain the existing 1.5-second iOS / 2.5-second tvOS settling window,
and capture `ooo-after-late`. Delivery means the fixture finished writing the
response; it does not claim that the app displayed or decoded the image. Before
writing a held response, a non-blocking socket peek rejects an already-closed
peer, including an empty read, and records a disconnect instead of delivery.
The UI polls retain fixed product budgets. The read-only scene probe is the
only added app launch key; no private XCTest quiescence API is used.

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
Screenshot names are hand-reviewed against `public_scene_photos_from_bytes`,
`target_album_frame_identity` and server-switch `_require_public_pattern` callers: `history-*`,
`pause-immediate`, `pause-after-10s`, `resumed`, `album-playback-N`, `album-play-1`/`album-play-2`/`album-play-3`, `person-normal`,
`person-no-faces`, `person-conflict-normal(-N)`, `album-switch-b-play-N`,
`server-switch-a-play-1` and `switch-b-play-1`/`switch-b-play-2` (all `.png`).
The `album-play-[123]` reader shipped in PR #514 before its filter-album producer
in PR #515. These stems also fit the existing public-pattern-mismatch grammar;
the filter-album producer emits screenshot context, not that mismatch prefix.
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

Public-fixture strict/UI failures can publish one first-failure receipt per
method and existing attempt. Historical records without
`first_failure` remain valid. No App code, workflow, assertion, deadline, retry,
threshold, verdict or population changes. The accepting reader must be on main
before a producer PR uses the field; see [reader-first evolution](CI_SUMMARY.md#reader-first-evolution).

The optional receipt has exactly `schema_version: 1`, `source` (`xctest`,
`validator`, `preparation`), `step`, `element`, `action`, `timing`, `state`,
`validator`, and `screenshot`. All strings are closed vocabularies in
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
| `tvOS pause-continue evidence is invalid;` | `continue_timing` | `evidence_capture` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
| `tvOS new photo must be stably identifiable within 4 s of transition start` | `continue_timing` | `scene_identity` | [AccessLifecycleContract+TransitionTiming.swift](../TestSupport/AccessLifecycleContract+TransitionTiming.swift) |
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
| `The paused pause-window probe identity must not change.` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
| `Paused pause-window frames must be pixel-identical.` | `pause_window` | `scene_identity` | [StrictE2EFirstBatchIOSUITests.swift](../immichSlidesUITests/StrictE2EFirstBatchIOSUITests.swift) |
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
| `After starting playback, the playback page should open and show the control bar` | `playback_entry` | `navigation` | [FilterSummaryIOSVisualUITests+Launch.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Launch.swift) |
| `The slideshow control never became tappable before the deadline.` | `control_action` | `hidden_controls` | [UITestSupport.swift](../immichSlidesUITests/UITestSupport.swift), shared playback control-bar tap callers |
| `The slideshow Settings tap had no observed outcome before the deadline.` | `settings_navigation` | `navigation` | [UITestSupport.swift](../immichSlidesUITests/UITestSupport.swift) |
| `The slideshow Settings button must be ready before opening playback settings.` | `settings_navigation` | `hidden_controls` | [PlaybackHistoryIOSUITests+Support.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift) |
| `Playback page should show the settings button` | `unknown` | `hidden_controls` | [FilterSummaryIOSVisualUITests+Navigation.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Navigation.swift), [FilterSummaryTVOSVisualUITests+Playback.swift](../immichSlidesUITests/FilterSummaryTVOSVisualUITests+Playback.swift) |
| `After entering the playback page, the settings button should be visible` | `playback_entry` | `navigation` | [FilterSummaryIOSVisualUITests+Navigation.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Navigation.swift) |
| `Before each screenshot, the playback control bar should wake up reliably` | `visible_scene_capture` | `hidden_controls` | [FilterSummaryIOSVisualUITests+Exif.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Exif.swift) |
| `The control bar may have auto-hidden while waiting for the sampling overlay; it should wake up again before tapping next` | `visible_scene_capture` | `hidden_controls` | [FilterSummaryIOSVisualUITests+Exif.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Exif.swift) |
| `Before retrying next, the playback control bar should wake up again` | `control_action` | `hidden_controls` | [FilterSummaryIOSVisualUITests+Exif.swift](../immichSlidesUITests/FilterSummaryIOSVisualUITests+Exif.swift) |
| `Could not return from the playback settings page to the slideshow` | `settings_navigation` | `navigation` | [PlaybackHistoryIOSUITests+Support.swift](../immichSlidesUITests/PlaybackHistoryIOSUITests+Support.swift) |

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
