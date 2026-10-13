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
vertical photo slot against the non-target album's A1–A5 classifier labels. Public
background colors locate slots independently of glyphs; obscured rows remain in a
slot only when the surrounding rows identify the same photo. Each slot requires
the active fixture's sharp A/B bitmap, with at least 14 observed cells, five white
cells and agreement with every observed cell. A visible digit must also agree
with the slot's color identity. Unobstructed public texture rows cross-check the
letter, rejecting an unreadable foreign slot even when its photo number matches
its neighbor. Mixed letters, missing glyphs and unreadable slots have distinct
failure reasons. White bands shorter than ten sampled pixels are excluded; up to
four blank rows join adjacent bitmap ink. Wider EXIF text bands may remain
unrecognized, but cannot supply a missing slot's identity.

`tvos-edit-switch` retains the previous centered region reader and whole-frame
album membership check. The reader used for single-photo surrounds is unchanged.

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
contain no input values, addresses or paths. Strict and iPad pause host runs
publish these records directly; fixture UI forwards at most eight allowlisted
records from the first 4 KiB of its private service log. Its timeout also names
the last observed phase and state when available. No record means the child has
not reported a phase; it does not prove where startup stalled.

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
