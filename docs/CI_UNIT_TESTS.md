# Unit tests from the build archive

`ci-gate` runs the complete `immichSlidesTests` target on the pinned iPhone and Apple TV.
Each consumer uses the [build archive](CI_BUILD_ARCHIVE.md), immutable artifact-ID
selection and manifest checks. It removes its source checkout before enumeration and
execution, with no project, scheme, package checkout or rebuild available.

## Job graph and limits

```mermaid
flowchart LR
    PR[PR merge commit or main push] --> H[host-checks]
    PR --> I[build-ios]
    PR --> T[build-tvos]
    I --> U[unit-ios]
    T --> V[unit-tvos]
    U --> R[scanned summary and official exports]
    V --> R
```

Each unit job waits only for its own platform's build. The critical path is the longer
complete platform path or host checks; queue time is measured separately.
Both build and consumer jobs are bounded at 40 minutes. Builds have a 30-minute script
bound. Unit consumers have separate boot, enumeration and execution bounds:

| Phase | CI iOS | CI tvOS | Local default |
| --- | ---: | ---: | ---: |
| Simulator boot (`simctl bootstatus -b`) | 240 s | 240 s | 600 s |
| Bundle enumeration, after boot | 660 s | 300 s | 300 s |
| Unit execution | 900 s | 900 s | 900 s |

There is no automatic test retry or silent rebuild. The [trusted publisher](https://github.com/sudoHG/immichSlides/issues/89)
owns the `ci-pr-gate` status and required-status enforcement. A failing unit test fails
the producer job; a job conclusion alone is not evidence of that trusted status.

## Execution and records

Selection and identity checks precede tooling staging. The consumer removes its entire
checkout, extracts to another absolute path, rejects existing build-time source and
Products paths, and remeasures `Signature=adhoc`. Device type, runtime and Xcode build
come from `scripts/ci-pins.json`. Signing stays **Sign to Run Locally**, clone-process
parallelism is disabled, and automatic simulator diagnostic collection is disabled.
Official function/parameter results and failures are still exported.

```sh
python3 -B scripts/ci_build_archive.py select --platform ios \
  --artifact-id ID --producer-attempt ATTEMPT --selection-path /tmp/archive-selection.json \
  --output-dir /tmp/unit-records
python3 -B scripts/ci_unit_tests.py stage --path /tmp/archive-tools
# In CI, remove the disposable checkout after selection and staging.
python3 -B /tmp/archive-tools/scripts/ci_unit_tests.py run \
  --selection-path /tmp/archive-selection.json --archive-dir /tmp/archive-download \
  --relocated-path /tmp/consumer-relocated-ios --output-dir /tmp/unit-records \
  --enumeration-profile ci
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
with execution; independent source declarations belong to the [static population policy](https://github.com/sudoHG/immichSlides/pull/130).
Until integrated, `declared` remains empty.

The official overall `result` is classified with the offline runner's rules.
`Failed` fails even when function counts look successful; unknown overall results
cannot pass. Otherwise successful results with skips remain `unverified`, using the
shared `skip-policy-pending` code until policy approval. No expected skip is approved
or applied by this consumer. Exception proposals belong in the PR body; the policy's
proposed section is populated separately after its owning change merges.

The [summary contract](CI_SUMMARY.md) keeps successful Swift rows in JSON and displays
failures/skips in Markdown. Parameter rows retain official arguments and outcomes.
Skip reasons preserve the exact emitted `Skip Message`, including generic `Test skipped`.
Failed functions and parameters retain the first official `Failure Message` line,
capped at 200 characters. Plain assertion failures do not add infrastructure entries;
timeouts, unavailable results and export failures remain infrastructure failures.

`archive-consumption.json` precedes Xcode and records artifact ID, producer run/attempt,
consumer attempt, identity, archive/manifest hashes, signing, source/Products absence,
process exits and official export hash. `bundle-enumeration.json`, `official-tests.json`
and `official-summary.json` preserve independent enumeration, outcomes and counts.
Archive validation failures reuse `archive-identity-mismatch` or `archive-unavailable`
with **use Re-run all jobs**. Simulator/enum failures use `unit-archive-failed`.

Raw bundles stay outside publishable records in the existing private-result storage.
Finalization attempts official export even after Xcode failure. Failed runs or
export/scan errors retain a private quarantine record; successful export and sensitive
scan precede disposal. A failed enumeration attempts export and retains both process
exits and archive identity, even when no executable test results exist.

An independent `always()` scan runs after the consumer, including when preflight,
selection or download failed and execution was skipped. It reuses the sensitive scanner
through the system Python without requiring a completed environment setup or units step.
Download/setup failures replace otherwise successful earlier stage records with a
classified failure and rerun advice. Artifact and step-summary publication require
this scan's `records_safe` output. No records produces **Unit records were not produced;
publication is unavailable.** A refused scan produces only **Unit record scanning refused
publication.** Neither case prints raw diagnostics. Relocated-product cleanup is a
separate `always()` step. The upload allowlist contains only compact records and official
exports; raw bundles, logs, screenshots, activities and quarantine paths never upload.
Records expire after 30 days for PRs and 7 days for other runs.

## Measurements and budgets

Workflow timestamps measure setup and transfer. Monotonic clocks measure build,
packing, separate simulator boot, post-boot enumeration, execution and consumer total.
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
**124.06 s** measured job overhead. Adding the 60-second official-export bound and
rounding upward gives a **240-second overhead allowance**. The runner's shared
interrupt grace is **120 s**. The longest combined bound is therefore
`240 + 660 + 900 + 120 + 240 = 2160 s < 2400 s`.
The guard reads actual workflow `timeout-minutes`; measurements and Markdown record
phase limits, grace, measured overhead and allowance. These are infrastructure budgets;
product assertions and success thresholds do not change.

The provisional feedback budget is **22 minutes (1320 s)**. Its calibration includes
[success](https://github.com/sudoHG/immichSlides/actions/runs/37719766131) at 638 s and
[failure](https://github.com/sudoHG/immichSlides/actions/runs/37717972490) at 872 s,
including queueing through the last completed job. Nearest-rank sample p95 is rank 2
of 2 (872 s); a **1.5x margin** and upward minute rounding give
`ceil(872 * 1.5 / 60) = 22`, leaving 448 s above the maximum observation.
This budget is **provisional until #93 promotion**. Enforcement belongs to #89;
concurrent PR/nightly capacity and the promotion sample remain unverified.
Script/job timeouts are cancellation bounds, not promises of runner capacity.
