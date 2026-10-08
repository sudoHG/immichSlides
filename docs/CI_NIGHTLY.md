# Skeleton nightly

`ci-nightly` schedules at 21:15 UTC (05:15 Singapore time) on the default branch
and supports `workflow_dispatch` on a selected branch. PRs touching its entry points
run planning only; full execution is proven by dispatch before merge. It has read-only
permissions, no secrets/environments and no publisher, reporter or release authority.

```bash
gh workflow run ci-nightly.yml --ref <branch>
gh run list --workflow ci-nightly.yml --branch <branch>
python3 -B scripts/ci_nightly.py plan --output-dir '<fresh-outside-repo>/plan'
python3 -B scripts/run_strict_ci_tracer.py --manifest scripts/nightly-matrix.json \
    --shard iphone-immichSlides-iOS-debug-0 --platform ios \
    --destination 'platform=iOS Simulator,id=<UDID>' \
    --output-dir '<fresh-outside-repo>/shard'
```

Use a configuration-free checkout, dedicated simulator and workspace device-slot/
watchdog wrappers. Preflight rejects files, links and dangling private-config links
without reading them. There is no SHA override: dispatch a ref at the desired commit.
Checkout, workflow, matrix, policy, tree, run or attempt mismatches fail. Schedule
identities require `refs/heads/main`.

## Population and capacity

[`nightly-matrix.json`](../scripts/nightly-matrix.json) explicitly versions device,
configuration, suite, scenario and fixture. Planning validates the complete population
against current selector/scenario/fixture/scheme contracts; duplicates and missing
cases fail. Runtime discovery cannot silently change the scheduled list. Inapplicable
platforms/scenarios and P2 devices are outside the supported population.

The initial 137 cases comprise 54 iPhone, 52 iPad and 31 Apple TV combinations.
All 77 distinct device/suite/scenario identities in the historical local report remain.
Repeat attempts are not new identities. New identities are iPad smoke and iPhone/iPad
image-failure-recovery. Both frozen fixtures run wherever permitted. The 23 explicit
fixture exclusions require A: lifecycle, display policy, image-failure recovery,
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
The 26 shards use `max-parallel: 2`: at least 13 waves, with no reserved macOS slots.
Cold warm-up has 1,200 seconds; each warm invocation has 600. Each case adds a 240-second
reset/export/cleanup allowance; filter-person receives three invocation budgets.
Six cases can require eight invocations, giving a worst shard allowance of 128 minutes.
The job timeout is 150 minutes including setup/upload/cleanup; planning/aggregate have
15-minute caps. Hosted disk floor stays 30 GiB; local default stays 80 GiB.

## Results, scope and eligibility

After finalization, the tracer reads official summary and test identity exports whatever
the runner exit code. It validates integer counts, their sum/result and selected method.
Filter-person combines three session exports, keeps partial counts on failure and checks
any suite total. Valid failed exports still record compilation and official counts.
Nonzero exits remain failures even with passing XCTest counts. Missing/malformed exports
fail. Timeouts/interruptions preserve completed outcomes; unfinished cases are `not-run`.

The always-run aggregate downloads only this attempt's compact records. It validates
every expected shard's identity, hashes and declared/compiled population, then compares
executed identities with scheduling. Every entry has an outcome; synthetic `not-run`
placeholders never count as execution. Missing artifacts, failed/cancelled jobs,
infrastructure failures and matrix discrepancies are red. There is no automatic retry.

[`nightly-policy.json`](../scripts/nightly-policy.json) builds only strict and starts
with `live_tier_in_scope: false`. UI, offline performance, live and live performance are
**not yet in scope**, without making the skeleton red. Setting live scope without live
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

Only compact records upload, retained seven days (PR planning: 30 days). Raw bundles
use existing private export/disposal; products, packages, simulator contents, screenshots,
recordings and logs do not upload. P2 review packages/signed promotion are separate work.
Cleanup waits for the runner group; failed cleanup retains inputs until runner teardown.
Existing Python test files guard equality, scope/eligibility, provenance, P2 separation,
failed/malformed official exports and partial person execution under [Testing section 0](TESTING.md#0-when-to-write-a-test).
Wiring and simulator behavior are verified by real runs. No repository settings,
rulesets, credentials, approvals or environments change.
