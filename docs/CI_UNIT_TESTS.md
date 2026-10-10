# Unit tests from the build archive

`ci-gate` runs the complete `immichSlidesTests` target on the pinned iPhone and Apple TV.
Each consumer uses the [build archive](CI_BUILD_ARCHIVE.md), immutable artifact-ID
selection and manifest checks. It removes its source checkout before enumeration and
execution, with no project, scheme, package checkout or rebuild available.

## Job graph and limits

```mermaid
flowchart LR
    PR[PR merge commit or main push] --> H[host-checks]
    PR --> C[Linux classification]
    C --> I[build-ios when applicable]
    C --> T[build-tvos when applicable]
    I --> U[unit-ios]
    T --> V[unit-tvos]
    U --> R[scanned summary and official exports]
    V --> R
```

Each unit job waits only for its own platform's build. The critical path is the longer
complete platform path or host checks; queue time is measured separately.
The [trusted gate classification](CI_PUBLISHER.md) marks the four build/unit
jobs not applicable on app-unaffected PRs. Host checks still run on macOS.
Main pushes and nightly run the full population. The Linux classification job
has a ten-minute job bound and must provide a passing identity-bound summary.
Build jobs are bounded at 40 minutes and consumer jobs at 45 minutes. Builds have a 30-minute script
bound. Unit consumers have separate boot, enumeration and execution bounds:

| Phase | CI iOS | CI tvOS | Local default |
| --- | ---: | ---: | ---: |
| Simulator boot (`simctl bootstatus -b`) | 240 s | 240 s | 600 s |
| Bundle enumeration, after boot | 660 s | 300 s | 300 s |
| Unit execution | 900 s | 900 s | 900 s |
| Official tests / summary exports | 180 / 180 s | 180 / 180 s | 60 / 60 s |
| Owned simulator shutdown / delete | 60 / 60 s | 60 / 60 s | 60 / 60 s |

There is no automatic test retry or silent rebuild. The [trusted publisher](https://github.com/sudoHG/immichSlides/issues/89)
owns the `ci-pr-gate` status and required-status enforcement. A failing unit test fails
the producer job; a job conclusion alone is not evidence of that trusted status.

## Execution and records

Selection and identity checks precede tooling staging. Staging statically enumerates
unit declarations from committed Swift source blobs in the selected tree, binding
them to the full selected identity and platform. It retains only these declarations
and the tools. The consumer removes its entire
checkout, extracts to another absolute path, rejects existing build-time source and
Products paths, and remeasures `Signature=adhoc`. Device type, runtime and Xcode build
come from `scripts/ci-pins.json`. Signing stays **Sign to Run Locally**, clone-process
parallelism is disabled, and automatic simulator diagnostic collection is disabled.
Official function/parameter results and failures are still exported.

```sh
python3 -B scripts/ci_build_archive.py select --platform ios \
  --artifact-id ID --producer-attempt ATTEMPT --selection-path /tmp/archive-selection.json \
  --output-dir /tmp/unit-records
python3 -B scripts/ci_unit_tests.py stage --path /tmp/archive-tools \
  --selection-path /tmp/archive-selection.json
# In CI, remove the disposable checkout after selection and staging.
python3 -B /tmp/archive-tools/scripts/ci_unit_tests.py run \
  --selection-path /tmp/archive-selection.json --archive-dir /tmp/archive-download \
  --relocated-path /tmp/consumer-relocated-ios --output-dir /tmp/unit-records \
  --enumeration-profile ci --result-export-timeout-seconds 180
python3 -B /tmp/archive-tools/scripts/ci_unit_tests.py scan --output-dir /tmp/unit-records
```

Use fresh paths and `tvos` selection for Apple TV. Artifact selection requires CI event
metadata and an actions-read token. `--simulator-id <UDID>` selects an existing matching
simulator; otherwise the consumer creates and deletes its own pinned device. Local
archive experiments use real local identity and a null artifact ID, never an invented
GitHub artifact ID. Local runs require 80 GiB free before each Xcode invocation;
hosted runs retain the 30 GiB reserve.

Enumeration and execution use `xcodebuild test-without-building -xctestrun ...` with
`-only-testing:immichSlidesTests`, dedicated DerivedData and private result paths.
No unit identity is deselected. Enumeration errors fail even on process exit zero.
Empty/duplicate identities, missing/extra execution, unparseable results, disagreeing
official counts and failing parameter runs fail the consumer. Compilation is compared
with execution. The consumer validates the staged declaration identity/platform,
records their hash and fills `population.declared` using the
[population library](CI_POPULATION.md). The trusted publisher independently derives
the expected declarations from the admitted tree; enumeration never supplies that set.
Coverage comparisons normalize Xcode's bundle prefix, raw identifier quoting and
argument-label signature to static function keys. Parameter rows retain their full
official identities; their parent function must be compiled, and failures, duplicates
or missing function observations fail coverage. Explicitly enumerated parameters
still require their own observations.

The official overall `result` is classified with the offline runner's rules.
`Failed` fails even when function counts look successful; unknown overall results
cannot pass. The staged [test policy](CI_POPULATION.md#expected-skips-and-tier-deselections)
activates expected skips only for tiers with an approval record. The unit record
covers 37 exact hermetic identities/reasons (19 iOS, 18 tvOS). The consumer records
the policy hash and uses the verdict library's matching rules; every observed skip
must match exactly one rule, including platform and emitted reason. Unlisted skips,
changed reasons and an expected-skip test that runs fail coverage. Otherwise passing
results with approved matching skips are verified. Matching proposed exceptions
remain `unverified` with the non-infrastructure `policy-proposed` diagnostic.
Each approval record activates only its own tier's active entries. The fixture UI
record is separate from unit approval; any future `proposed` entries remain inactive.
Producer policy checks do not authorize trusted
publication or approve a later PR head.

The [unit approval conditions](https://github.com/sudoHG/immichSlides/pull/131#issuecomment-6056062100)
assign live tests to the nightly live tier. Until that tier runs nightly, networking
or filtering changes require a manual live run before merge. Hermetic skips do not
establish live membership, deduplication or performance coverage.
The [live unit runner](CI_LIVE_TESTS.md) implements main-only execution and documents
its pre-merge refusal and post-merge acceptance boundary.

The [summary contract](CI_SUMMARY.md) keeps successful Swift rows in JSON and displays
failures/skips in Markdown. Parameter rows retain official arguments and outcomes.
Skip reasons preserve the exact emitted `Skip Message`, including generic `Test skipped`.
Failed functions and parameters retain the first official `Failure Message` line,
capped at 200 characters. Plain assertion failures do not add infrastructure entries;
timeouts, unavailable results and export failures remain infrastructure failures.

`archive-consumption.json` precedes Xcode and records artifact ID, producer run/attempt,
consumer attempt, identity, archive/manifest hashes, signing, source/Products absence,
process exits, staged declaration hash and official export hash. `bundle-enumeration.json`, `official-tests.json`
and `official-summary.json` preserve independent enumeration, outcomes and counts.
Archive validation failures reuse `archive-identity-mismatch` or `archive-unavailable`
with **use Re-run all jobs**. Simulator/enum failures use `unit-archive-failed`.

Raw bundles stay outside publishable records in the existing private-result storage.
Finalization attempts official export even after Xcode failure, reusing the UI runner's
shared export implementation and explicit `--result-export-timeout-seconds` bound for
each tests and summary export. Omitting the option retains the local 60-second default;
the hosted workflow passes 180 seconds. Execution exits other than 0 or 65 record
`unit-execution-timed-out` (124) or `unit-execution-failed` before result comparison.
An export timeout records the UI runner's distinct `xcresult-export-timeout` infrastructure
code, with phase, bound and elapsed time; it cannot count as a product failure or verified
execution. Owned-simulator shutdown and delete
have 60-second bounds; deletion still runs after shutdown failure. Their durations
and exit codes are measured and shown in `summary.md`. A cleanup that fails, or times out
while results are incomplete or unverified, makes the summary failed, and scanning
continues. A cleanup that only times out (exit 124) after a complete, verified passing
result set (zero exit, exported and compared results, declared = compiled = observed functions
under the trusted identity normalization, no other infrastructure entry) is
recorded as an `infrastructure_notes` entry in `measurements.json` and `summary.md`; it
is not an infrastructure entry in `summary.json`, so it cannot turn that passing population
red. The live runner shares this cleanup and rule (see [live tests](CI_LIVE_TESTS.md)). Failed runs or
export/scan errors retain a private quarantine record; successful export and sensitive
scan precede disposal. A failed enumeration attempts export and retains both process
exits and archive identity, even when no executable test results exist.

An independent `always()` scan runs after the consumer, including when preflight,
selection, download or staging failed, or execution failed before saving its own failed
record. It reuses the sensitive scanner
through the system Python without requiring a completed environment setup or units step.
Failed steps require a `unit-<platform>` failed record. Earlier selection records are
relabeled, and otherwise successful records become classified failures with rerun advice;
an existing failed unit record keeps its original diagnostic and official evidence.
Artifact and step-summary publication require
this scan's `records_safe` output. No records produces **Unit records were not produced;
publication is unavailable.** A refused scan produces only **Unit record scanning refused
publication.** Neither case prints raw diagnostics. Relocated-product cleanup is a
separate `always()` step. The upload allowlist contains only compact records and official
exports; raw bundles, logs, screenshots, activities and quarantine paths never upload.
Records expire after 30 days for PRs and 7 days for other runs.

## Measurements and budgets

Workflow timestamps measure setup and transfer. Monotonic clocks measure build,
packing, separate simulator boot, post-boot enumeration, execution and consumer total.
`measurements.json` also records combined official tests/summary export time, including
timeouts, and result parsing/judgment time. Its `enumeration_budget` and `summary.md`
record the actual per-export bound.
Producer/consumer disk tracers sample free volume space every second, retaining minimum
free space and peak growth. These shared-volume samples include transient simulator
files and other activity; they are not estimates from final Products size. Queue times
come from workflow-created and job-start timestamps; a unit queue starts after its own
build completes. Full per-run measurements and acceptance history belong in PR records.

`--enumeration-profile ci` uses [post-boot calibration](https://github.com/sudoHG/immichSlides/actions/runs/37716498397):
iOS 307.10 s and tvOS 41.62 s. Nearest-rank sample p95, a **2x margin**, upward rounding
to whole minutes and a 300-second floor choose **660 / 300 s**. Omitting the profile
keeps the local 300-second default. Only completed measurements are used. The small
calibration set does not estimate population tail latency or prove capacity.

The [recovery calibration](https://github.com/sudoHG/immichSlides/actions/runs/37717972490)
measured maximum boot at **110.19 s**; 2x and upward minute rounding choose **240 s**.
Its iOS job lasted 556 s, with 110.19 + 251.28 + 70.47 s in the three phases, leaving
**124.06 s** measured job overhead. Adding separate 180-second tests and summary export
bounds, plus 60 seconds each for simulator shutdown and delete, and rounding upward
gives a conservative **660-second overhead allowance**. The hosted export bound reuses
the [UI calibration](CI_UI.md): a unit tests export on
[PR #169](https://github.com/sudoHG/immichSlides/pull/169) took 62.1 seconds against the
former 60-second limit, despite zero product failures. This is an infrastructure
allowance, not a product deadline. A hosted delete exceeded its
former 15-second bound; the 60-second recovery allowance remains bounded.
The shutdown bound follows
[run 38077261419](https://github.com/sudoHG/immichSlides/actions/runs/38077261419) (job 114290062415:
619 passed, 19 approved skips, 0 failed, shutdown stopped at 15.2 s) and the
[#247](https://github.com/sudoHG/immichSlides/pull/247) head run 38035723913 (15.6 s).
Across 22 recent hosted gate runs, 20 iOS shutdowns completed in 4.3-11.8 s (median 5.7 s) and
2 timed out; all 22 tvOS shutdowns completed in 3.4-5.7 s. Both iOS timeouts were followed by a delete that finished in 9-10 s, so
the shutdown needed about 25 s. 60 s leaves more than twice that margin. The runner's shared
interrupt grace is **120 s**. The longest combined bound is therefore
`240 + 660 + 900 + 120 + 660 = 2580 s < 2700 s`.
The guard reads actual workflow `timeout-minutes`; measurements and Markdown record
phase limits, grace, measured overhead and allowance. These are infrastructure budgets;
product assertions and success thresholds do not change.

The provisional feedback budget is **72 minutes (4320 s)**. The method uses
nearest-rank sample p95 across completed hosted success and failure paths, including
queueing through the last completed job, a **1.5x margin** and upward minute rounding.
The [recovery measurement](https://github.com/sudoHG/immichSlides/actions/runs/37741604879)
of 2876 s establishes a conservative floor: `ceil(2876 * 1.5 / 60) = 72`, leaving
1444 s above that observation. Final-configuration paired measurements and the retained
margin are published with [the consumer PR](https://github.com/sudoHG/immichSlides/pull/131).
This budget is **provisional until #93 promotion**. Enforcement belongs to #89;
concurrent PR/nightly capacity and the promotion sample remain unverified.
Script/job timeouts are cancellation bounds, not promises of runner capacity.
