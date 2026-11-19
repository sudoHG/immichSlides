# Offline units from build archives

`ci-gate` runs the complete `immichSlidesTests` target on the pinned iPhone and
Apple TV when App builds apply. Each consumer depends only on its platform's
[archive](CI_BUILD_ARCHIVE.md), selects an immutable artifact ID/producer attempt,
stages tooling/declarations and removes its checkout before enumeration/execution.
No project, package checkout or rebuild remains.

Default plans are unit-only, but `build-for-testing` compiles every scheme
testable, including the UI target's smoke and App Store screenshot methods.
PR CI runs no UI tests; the smoke nightly executes smoke. Manual screenshots use the
[Evidence plans](TESTING.md#app-store-screenshots).

## Limits and coverage

| Phase | CI iOS | CI tvOS | Local default |
| --- | ---: | ---: | ---: |
| Boot | 240 s | 240 s | 600 s |
| Post-boot enumeration | 660 s | 300 s | 300 s |
| Execution | 900 s | 900 s | 900 s |
| Each official export | 180 s | 180 s | 60 s |
| Owned simulator shutdown / delete | 60 / 60 s | 60 / 60 s | 60 / 60 s |

Build/unit workflow limits are 40/45 minutes. These are cancellation bounds,
not capacity promises. There is no automatic test retry, silent rebuild,
separate publisher or CI approval step. Failing units fail their own job.

Staged Swift declarations come from selected committed blobs and bind full
identity/platform. Consumers verify inventory/signing, reject surviving build-time
paths, extract elsewhere and use exact pinned simulator types/runtimes.
Signing stays ad-hoc; clone-process parallelism is disabled.

Enumeration/execution use `test-without-building -only-testing:immichSlidesTests`.
Empty, duplicate, missing, extra, malformed and failed results fail coverage.
Declared, compiled and observed function sets must agree. Parameter rows retain
original arguments/outcomes; normalization affects only coverage comparisons.

[`ci-test-policy.json`](../scripts/ci-test-policy.json) registers exact hermetic
unit skips. Each must match one active entry with the right platform, tier,
environment and reason. Unlisted skips, registered skips that execute and missing
compilation fail. Conditional Live/Evidence skips establish neither real-server
nor evidence coverage. There is no live nightly.
See [population accounting](CI_POPULATION.md).

## Records and finalization

`archive-consumption.json` records artifact/run/attempt identity, hashes, signing,
absent paths, process exits, declarations and official export hash.
`bundle-enumeration.json`, `official-tests.json` and `official-summary.json`
preserve independent compilation and results. `measurements.json` records setup,
transfer, boot, enumeration, execution, exports, judgment, cleanup and disk samples.

Raw bundles remain private. Finalization attempts official export after Xcode
failure and scans compact records before publication. Successful export/scan
precede disposal; incomplete or failed runs retain quarantine for diagnosis.
The independent workflow scan also runs after preflight, selection, download or
staging failure. Unsafe or absent records are not displayed/uploaded.

Owned simulator shutdown/delete are bounded separately. A cleanup timeout after
complete verified passing results is an infrastructure note; other cleanup
failures fail. Missing tests, failed assertions and incomplete exports stay red.

The upload allowlist is summary JSON/Markdown, identity, archive consumption,
enumeration, official tests/summary, measurements and sensitive scan.
Raw bundles, logs, screenshots, activities and quarantine paths never upload.
Records last 30 days for PRs and seven days otherwise.

## Local reproduction

Use [CONTRIBUTING](../CONTRIBUTING.md#setup) for ordinary offline units with no
server/credentials. Source-free experiments use `ci_unit_tests.py stage`, `run`
and `scan`; CI supplies artifact selection metadata. Never invent GitHub IDs.
`--simulator-id UDID` selects an existing matching device; otherwise the consumer
creates/deletes its own pinned simulator.

Expired/missing archives require **Re-run all jobs**. Failed-job reruns can reuse
successful producer IDs from the same run/earlier attempts; rerunning all jobs
produces fresh attempt-specific archives.
