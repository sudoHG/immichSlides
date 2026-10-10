# Nightly strict and fixture UI tiers

`ci-nightly` schedules at 21:15 UTC on the default branch
and supports `workflow_dispatch` on a selected branch. PRs touching its entry points
run planning and credential-free live probes. Full strict and fixture UI execution
is proven by dispatch before merge. It has read-only permissions and no publisher, reporter or release
authority. Separate [live unit jobs](CI_LIVE_TESTS.md) use the main-only
`immich-test-server` environment after credential-free admission.

```bash
gh workflow run ci-nightly.yml --ref <branch> -f strict_only=true
gh workflow run ci-nightly.yml --ref <branch> -f ui_only=true
gh run list --workflow ci-nightly.yml --branch <branch>
gh workflow run ci-nightly.yml --ref <branch> -f shard=ipad-immichSlides-iOS-debug-3
python3 -B scripts/ci_nightly.py plan --output-dir '<fresh-outside-repo>/plan'
python3 -B scripts/run_strict_ci_tracer.py --manifest scripts/nightly-matrix.json \
    --shard iphone-immichSlides-iOS-debug-0 --platform ios \
    --destination 'platform=iOS Simulator,id=<UDID>' \
    --output-dir '<fresh-outside-repo>/shard'
```

Local planning, tracer execution and aggregation each use the same recorded
working-tree snapshot identity when the source HEAD and working files are unchanged.
Private configuration links are excluded without reading or parking them. Keep the
source tree unchanged across all three commands; `--strict-ci` refuses dirty sources.
Changing a working file between commands produces an identity mismatch and fails
aggregation. Snapshot commits use a fixed non-personal identity; source refs and
the caller's index are unchanged. Paths to plans and records remain caller-relative.
Use a dedicated simulator and workspace device-slot/watchdog wrappers. Hosted
preflight requires a configuration-free checkout and rejects private files and links
without reading them. There is no SHA override: dispatch a ref at the desired commit.
Live execution requires `main`; `live_only` diagnoses live boundaries without strict shards.
Use `strict_only=true` for full strict diagnostics on a branch. A selected `shard`
also skips all live admission/build/canary/unit jobs, including on main, so strict
diagnostics generate no public test Immich server traffic. A plain branch dispatch
attempts live admission and is refused because live execution requires main; its
strict and fixture UI results remain diagnostic. `ui_only=true` runs the complete
fixture UI population and the two credential-free archive producers, while skipping
strict and live execution. Like strict-only and single-shard diagnostics, its fixed
nightly aggregate stays red for incomplete nightly coverage. It cannot close nightly
issues or establish release eligibility. `probe_environment_refusal=true` runs only the
credential-free protected-environment refusal job on a non-main ref. On main it
intentionally skips every job, including live execution; it is not a live proof.
Checkout, workflow, matrix, policy, tree, run or attempt mismatches fail. Schedule
identities require `refs/heads/main`.
The optional dispatch `shard` input diagnoses one known shard exactly once. It retains
the complete scheduling record; missing shards and the diagnostic marker make aggregate
equality fail. This run cannot substitute for a complete nightly, and does not retry cases.

## Population and capacity

[`nightly-matrix.json`](../scripts/nightly-matrix.json) explicitly versions device,
configuration, suite, scenario and fixture. Planning validates the complete population
against current selector/scenario/fixture/scheme contracts; duplicates and missing
cases fail. Runtime discovery cannot silently change the scheduled list. Inapplicable
platforms/scenarios and P2 devices are outside the supported population.

The initial 135 cases comprise 54 iPhone, 50 iPad and 31 Apple TV combinations.
All 77 distinct device/suite/scenario identities in the historical local report remain.
Repeat attempts are not new identities. New identities are iPhone/iPad image-failure-recovery.
Both frozen fixtures run wherever permitted. The 25 explicit exclusions comprise two
device exclusions and 23 fixture exclusions. iPad smoke is unsupported: the selected
`StrictE2ESmokeUITests.testIOSStrictE2EConnectionSmoke` guards
`userInterfaceIdiom == .phone` and skips iPad. The validator checks that guard against
Swift code with comments/strings removed and fails when it changes, requiring a device
scope review. The fixture exclusions require A: lifecycle, display policy, image-failure recovery,
tvOS album selection and dual-server suites. Reasons come from existing contracts.
No assertions, thresholds, App behavior or visual modes change.

Standalone access-protection runners remain excluded: iOS main is unstable, and tvOS
uses a transient Release scheme. Small strict lifecycle suites do run. Offline unit
bundles, manual album/server commands and the iPad pause diagnostic are not strict
matrix inputs or scanned evidence. Filter-vision runs informationally until the
separate simulator Vision contract lands. The tvOS person suite retains normal/no-face
coverage; its existing simulator limitation does not establish verified Vision coverage.

Shards group by device/platform/scheme/configuration, then split into chunks of at most
six, retaining ordinary Debug and settings-resume Release. The [warm tracer](CI_STRICT_RUNNER.md)
builds once per shard, resets app/keychain/privacy and uses `test-without-building`
with immutable Products checks. Case directories are unique across repeated suites.
The 25 shards use `max-parallel: 2`: at least 13 waves, with no reserved macOS slots.
Cold warm-up has 1,200 seconds; each warm invocation has 600. Each case adds a 240-second
reset/export/cleanup allowance; filter-person receives three invocation budgets.
Both workflows and local reset callers use the shared boot helper. The workflow
boots each new simulator in a separate step with a shared 600-second
deadline (boot command capped at 60 seconds). It records both phase and total elapsed
times in logs and the job summary. Before the reset bound, the hosted first iOS smoke
completed in 457.7 seconds including preparation and test execution
([run](https://github.com/sudoHG/immichSlides/actions/runs/37726829510)); 600 seconds
gives cold boot its own budget above that measured complete-case duration.
Local reset callers also finish boot before starting the reset clock. App/keychain/privacy
resets share a separate 120-second deadline, with individual reset commands
capped at 60 seconds. Bootstatus uses the remaining 600-second boot budget. Official
tests and summary exports each have a 60-second deadline. Preparation/export timeouts name the phase in
compact infrastructure entries without command arguments/output, preserve a failed
case record, finish cleanup and quarantine raw bundles privately. Existing cold/warm
and outer deadlines are unchanged. The tracer retains these entries even when official
exports are unavailable, so application/test execution and infrastructure hangs remain
distinguishable. An xcodebuild test-execution timeout remains a failure of that case,
without an infrastructure entry.
The person shard contains both fixtures: two three-session cases and four single-session
cases require ten invocations. Its conservative outer allowances total 148 minutes
(24 cold plus 124 warm). The 165-minute job cap leaves 17 minutes for initial boot, setup/upload/cleanup
so a slow shard can publish its failed records before runner teardown. Individual
runner, test and infrastructure deadlines are unchanged; reaching the job cap is a
failure. Planning/aggregate have 15-minute caps.
Hosted disk floor stays 30 GiB; local default stays 80 GiB.

## Complete fixture UI

Scheduled runs and ordinary dispatches plan all three devices' complete default-plan
UI populations at the checked-out main head. Branch dispatches provide diagnostic
evidence for a candidate commit. The [existing UI class manifest](CI_UI.md#manifest-and-union)
partitions each device into shards. The current v1 manifest has default, navigation
and visual: nine shards total. Names, counts and the matrix come from that manifest
through the shared helpers; the separate v2 exact-method reader can support additional
visual partitions without a nightly protocol change.
New default-plan tests join this population automatically. Evidence plans, strict-only
tests, offline performance and the uncapped benchmark are outside this UI tier.

The existing credential-free `live-build` jobs produce one iOS and one tvOS archive
for the same event, source, run and attempt. iPhone/iPad share the iOS archive and
Apple TV uses tvOS. Linux verifies their immutable artifact IDs and manifests without
waiting for a different workflow or reusing a PR verdict. Consumers use the same
`ci_ui_tests.py` relocation, fixture-set C runner, official exports, listed-only retry
and sensitive-scan path as `ci-ui`; no app or UI test code is added. A branch acceptance
dispatch reads its tested HEAD registry only in the `ci-nightly` fixture `ui-shards`
job with an exact workflow/ref binding; other branch registry consumers are refused.
This branch evidence remains self-reported and diagnostic. Live admission and
credential-bearing jobs retain their independent main-only boundary.

The UI matrix waits for the strict matrix to settle, then runs with `max-parallel: 2`
and `fail-fast: false`. Minimum waves round the actual shard count up after division
by two: the current nine shards require five start-order waves, without
reserved runner slots. Existing invocation, export and job timeouts remain bounded.
Each shard publishes timing and its bound summary even after a test failure when
the sensitive scan succeeds. When the workflow has not been cancelled, the UI
aggregate checks each shard verdict, compiled population and executed/default-plan
union, retaining approved skips and both retry attempts. Missing shards or samples,
duplicate/foreign records, missing timing and failed/cancelled matrix jobs remain red.

`nightly-ui.json` and `nightly-ui.md` record every shard verdict, scheduled/executed/
deselected/missing counts, wall seconds from UI planning through aggregation, shard
intervals and observed start-order waves. The fixed `nightly.json` v2 embeds this
aggregate, and the [trusted reporter](CI_REPORT.md) independently reads the same
attempt's shard artifacts and recomputes the UI verdict. UI failures enter the existing
nightly failure issue lifecycle; missing evidence cannot close an issue. The trusted
reader and producer follow the [reader-first contract](CI_PUBLISHER.md). Diagnostics
without a standalone UI aggregate retain a v1 fixed record, preserving strict results.
Missing UI evidence still fails the nightly. Every published shard binds its complete
declared population and manifest/policy hashes before runtime preflight; a shard whose
source cannot be bound remains missing rather than invalidating the other shards.

For a branch acceptance run, use the installed trusted reader in read-only mode:

```bash
python3 -B scripts/ci_report.py --dry-run --diagnostic-nightly --run-id <RUN_ID> \
    --output-dir '<fresh-outside-repo>/report'
```

This diagnostic performs no GitHub writes and publishes no trusted history. Production
reporting accepts only main; a branch result does not replace a main nightly.

## Results, scope and eligibility

After finalization, the tracer reads official summary and test identity exports whatever
the runner exit code. It validates integer counts, their sum/result and selected method.
Filter-person combines three session exports, keeps partial counts on failure and checks
any suite total. Valid failed exports still record compilation and official counts.
Nonzero exits remain failures even with passing XCTest counts. Missing/malformed exports
fail. Timeouts/interruptions preserve completed outcomes; unfinished cases are `not-run`.

When the workflow has not been cancelled, the aggregate downloads only this
attempt's compact records, including P2 package hash bindings written before upload.
It carries the bindings into its
aggregate and rollup metadata for review validation after media expiry. It validates
every expected shard's identity, run, hashes and declared population, then checks
compilation per entry and compares executed identities with scheduling. A missing
compiled identity fails only that entry as `declared-not-compiled`; other observed
outcomes remain available. Attempted failures count as execution. A failed entry whose
attempts are all `not-run` does not count, just like a synthetic `not-run` placeholder.
Every entry has an outcome. Missing artifacts, failed/cancelled jobs,
infrastructure failures and matrix discrepancies are red. There is no automatic retry.
Only Actions **Re-run all jobs** is supported: artifact provenance is bound to one
run attempt. Re-running only failed jobs cannot reuse successful shards from an earlier
attempt, and the aggregate fails for their missing artifacts.

The aggregate entry point is:

```bash
python3 -B scripts/ci_nightly.py aggregate --plan '<outside-repo>/plan.json' \
    --records-dir '<outside-repo>/shard-artifacts' \
    --output-dir '<fresh-outside-repo>/aggregate' --matrix-job-result success \
    --ui-record '<outside-repo>/ui-aggregate/nightly-ui.json'
```

Run it in the same event/run/attempt context as planning; the hosted workflow supplies
that context. Shard directories are named `nightly-strict-<shard>-<run-id>-<attempt>`.
For a local plan the run ID is `None` and attempt is 1. Downloaded CI records must not
be relabeled as a local run. The matrix job result comes from Actions, not its artifacts.
For local execution, copy the contents of each tracer's `records` directory into
`<records-dir>/nightly-strict-<shard>-None-1/` before aggregation. The plan,
tracer summary and aggregate must all have the same snapshot commit and tree SHA;
missing or mismatched records remain failures. A single diagnostic shard cannot
establish complete nightly equality.

[`nightly-policy.json`](../scripts/nightly-policy.json) builds strict and fixture UI,
with `live_tier_in_scope: false`. Offline performance, live and live performance are
**not yet mandatory aggregate inputs**, without making the skeleton red. Supplemental live unit jobs
now run independently; mandatory scope/aggregate integration belongs to the separate
scope ticket. Setting live scope without live
results fails; enabling it is a separate maintainer decision. Automated cases must pass
or flaky-pass. P2 contract success is `needs-human-review`; contracts gate without visual
PASS. Informational Vision outcomes are listed separately and excluded from health.

`nightly.json` records health/equality, every outcome, exclusions, source/run/attempt,
hashes, shard intervals, start-order waves and wall time from planning through aggregate.
Actions job timestamps show queue delay and teardown separately. Start-order waves batch
two starts without claiming reservations. `nightly.md` exposes this in the job summary.
The embedded rollup entry always records `release_eligible: false` and the skeleton reason,
even when green. The separate trusted reporter will write 90-day rollups. No release
policy is enabled; skeletons are never release-eligible.

Compact records are retained seven days (PR planning: 30 days). Separately,
[P2 review packages](CI_P2_REVIEWS.md) export scanned public-fixture images, recordings
and redacted records for seven days. Raw bundles use existing private export/disposal;
products, simulator contents and logs do not upload. Human review never promotes
automated P2 success or makes the skeleton release-eligible.
Cleanup waits for the runner group; failed cleanup retains inputs until runner teardown.
Existing Python test files guard equality, scope/eligibility, provenance, P2 separation,
failed/malformed official exports and partial person execution under [Testing section 0](TESTING.md#0-when-to-write-a-test).
Wiring and simulator behavior are verified by real runs. No repository settings,
rulesets, credentials, approvals or environments change.
