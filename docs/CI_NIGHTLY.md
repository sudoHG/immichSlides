# Nightly strict and fixture UI tiers

`ci-nightly` schedules a primary run at 14:07 UTC (22:07 Beijing) and a backup at
19:07 UTC (03:07 Beijing the next day) on the default branch, avoiding the busy
top of the hour, and supports
`workflow_dispatch` on a selected branch. GitHub has typically started scheduled
runs 3–4 hours late and can miss a trigger entirely; these times are requests, not
start-time guarantees. Strict and fixture UI work overlap after archive selection;
the full nightly waits for the slower tier, plus aggregation.
Runner queues, shard durations and trigger delays determine completion,
so neither schedule guarantees a morning result. PRs touching its entry points
run planning and credential-free live probes. Branch dispatches provide diagnostic
execution evidence. It has read-only permissions and no publisher, reporter or
release authority. Separate [live unit jobs](CI_LIVE_TESTS.md) use the main-only
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

## Early failure diagnostics

The reporter retains scheduled strict cases as missing when a shard has no valid
summary in `capacity.shard_intervals`. Valid summaries keep their existing method
missing list and declared count, including compile failures, timeouts and interrupts.
Single-shard diagnostics skip this synthesis so undispatched shards do not become
missing report cases. It can read a separate, untrusted
[identity failure receipt](CI_SUMMARY.md#prepared-strict-identity-failure-receipt)
and associate it with the current run/attempt's verified scheduling record. Such
a receipt changes only the public missing reason to `identity-collection-failed`;
it supplies no source identity, compilation or execution evidence. A shard with a
valid interval summary or any corresponding records artifact cannot use this receipt.
Before collecting source identity, the nightly tracer prepares the receipt from
the selected versioned matrix cases and the current job's run/attempt coordinates.
If identity collection raises, it writes only `identity-failure.json` and preserves
the original failure. The workflow uploads it as
`nightly-identity-<shard>-<run>-<attempt>` with the strict artifacts' seven-day
retention; it skips review export and the corresponding `nightly-strict` records
upload so the receipt stays eligible. Successful identity collection writes no
receipt, including when a later build or case fails. Source identity collection
remains after simulator preparation, with the existing Git timeout and no retry.
In `--preparation-failed` accounting mode, an identity failure writes no receipt
and preserves the generic missing-evidence reason: simulator preparation was the
original failure, so accounting must not relabel it as an identity failure.

The reader also accepts a standalone
[UI staging identity failure receipt](CI_SUMMARY.md#prepared-ui-staging-identity-failure-receipt).
It binds the current run, attempt, UI job, shard and ordered methods to the verified
UI plan. A shard with an interval summary or matching UI records artifact retains
its existing reason. Eligible missing methods receive only
`identity-collection-failed`; they remain missing/NOT_RUN and the night stays failed.
Following the reader's merge to main, the nightly UI job invokes
`ci_ui_tests.py stage-download --device <device> --shard <shard>`. It writes
`ui-identity/identity-failure.json` under `RUNNER_TEMP` only when source identity
collection or validation raises: Git failure or timeout, a checkout/`GITHUB_SHA`
mismatch, or identity validation failure.
The declared methods come from the same versioned Swift source, default plan and
shard manifest as scheduling. This computation runs only on the failure path;
successful identity collection retains the original staging outputs and writes no
receipt. Cancellation and subsequent source metadata or staging allocation errors
write no receipt. If diagnostic generation or writing fails, the original identity
exception and exit remain intact, with ordinary missing evidence.

An always-run existence probe gates the separate
`nightly-ui-identity-<device>-<shard>-<run>-<attempt>` upload, with the strict
receipt's seven-day retention. When it exists, the workflow skips `check-upload`,
so no UI records artifact is uploaded and the receipt remains eligible. This does
not fabricate a summary or compiled/executed record. The Git timeout, archive gate,
job budgets, permissions, simulator ordering and retry behavior are unchanged.

For missing strict or UI cases, the reporter can also associate the current
attempt's GitHub job with its check-run annotations. A failure annotation with the
hosted-runner communication-loss marker becomes `hosted-runner-disconnected`.
Annotation text is never published. Missing methods remain NOT_RUN, verified
results from other shards survive, and no previous attempt's successful artifacts
are borrowed. Unavailable annotation facts retain the ordinary failure reason.
No retry of jobs or tests, timeout, budget or simulator ordering changes are involved.

## Skipping an unchanged night

The scheduled nightly first runs a Linux `change` job that uses only the scheduled main
commit, the pinned reader packages and the GitHub API with the job token; it needs no
macOS capacity, Xcode Cloud build or credentials. Nothing in it runs for any other event:
every step is conditioned on `schedule` on `main`, so pull requests and dispatches never
execute the decision program, and their verdict is empty. The decision program and its
dependencies are `scripts/ci_*.py`, the setup scripts and the pins, all CI-trusted paths,
so a commit that edits any of them is classified as affecting by the baseline's policy and
runs the night instead of deciding its own fate.

`scripts/ci_nightly_change.py` walks recent scheduled and full manual `ci-nightly` runs
on main from the newest. A full manual run has no diagnostic input: `shard` is empty
and `live_only`, `ui_only`, `strict_only` and `probe_environment_refusal` are all false.
Manual dispatches have the input-derived run name `ci-nightly full` or `ci-nightly diagnostic`,
so the API reader can identify full manual runs even before they produce artifacts;
diagnostic manual runs never count. Older manual runs without this name count only
after their aggregate proves complete execution with a real result.
Scheduled runs are named `ci-nightly scheduled`; PR planning/probe runs are named
`ci-nightly PR <number>` and cannot be mistaken for a full manual nightly.

A scheduled run (primary or backup) skips when a full nightly already covers the same main SHA:
it is queued or in progress (including waiting/pending/requested states), or completed
with a verified real result, pass **or** fail. Active coverage applies only to the same
SHA and supplies no completed-result evidence. A new app- or CI-affecting main commit
runs. A cancelled primary or an infrastructure failure without a real result cannot
suppress the backup. Manual dispatches themselves still always execute.
An interrupted later run does not erase another full run's proven or active coverage
of that exact SHA.
Only an older active run can cover the current run, so simultaneous triggers cannot
both skip in favor of each other.
If the backup skips on an active primary that is then cancelled or fails infrastructure
without a real result, that night can be lost. The next scheduled trigger runs to recover
when no other complete nightly covers the SHA; the skipped backup is not restarted.

Without exact-SHA coverage, the original real-result baseline rule still applies.
A night skipped by this check (a verified `nightly-change` record, no execution
artifacts) is passed over. The first other night must be the baseline: completed with a
real result, pass **or** fail, with its aggregate artifact present, for the same run,
attempt and commit, a complete strict matrix and no infrastructure error, and a complete UI
tier (every planned shard and sample present, timing for every shard, and only genuine test
failures in its verdict, so a missing shard or a step timeout never counts). A cancelled, timed-out,
unfinished night that cannot cover this run (including a newer active run for the same SHA),
an infrastructure-incomplete night, or one whose evidence is expired or missing,
ends the search with no baseline and the nightly runs. The nightly is skipped when:

- the SHA equals the baseline's, or
- every path changed since the baseline is not app-affecting and not CI-trusted. The
  *baseline's* reader modules and `ci-classification.json` classify the diff, as the gate
  does, so a commit cannot loosen its own classification. Unknown paths, build-target
  files, workflow and test-infrastructure files, and an empty path list all count as affecting.

Otherwise, and on any doubt, it runs: no baseline, a baseline that is not an ancestor,
a classification or API error, or a rate limit that outlasts the two-minute budget. A night
that failed with a real result is a baseline, so an unchanged main does not rerun it.
Consecutive skipped nights chain safely because every skip is within non-affecting changes
of a night with a real result.

Skipping needs all of: the event is `schedule`, `change` succeeded, and its output
`run_nightly` is exactly `false`. That output is written by a last step that runs only after
the decision record artifact uploaded, so a failed decision, a failed upload or a missing
output leaves the job red or the output empty and the full chain runs. Every job below `change`,
including `strict`, `live-canary` and `live-unit`, has an explicit `!cancelled()` condition with
the full gate and its direct predecessors' results, because an implicit `success()` would skip
it when the `change` ancestor failed. When skipped,
`plan`, `strict`, `ui-archive`, `ui-shards`, `live-admission`, `live-build`, `live-canary`,
`live-unit` and both aggregates do not run, so the run ends green on Linux within minutes.
`workflow_dispatch` and `pull_request` always run at the expression level. The policy check
(`nightly-change-gate`) parses every job condition and requires that exact gate as one
conjunct of a pure `&&` chain, so `|| true`, negation or a weaker variant is rejected. It
also checks that the verdict step follows the upload and that the job exports only that
step's output, and it requires the job to stay on Linux without Xcode.

The `nightly-change-<run>-<attempt>` artifact holds the decision; the step summary shows it.
The [reporter](CI_REPORT.md) turns a validated skip into a `not-run` entry with "no change
since the last nightly". It is never a pass for the new SHA, creates no issue outcome, and
supplies no explicit-pass night. Closing a nightly issue needs three executed nights, so
quiet stretches delay closure rather than counting toward it. A skip record is rejected
(the night reads as failed evidence) if it names another run, commit, repository or event,
a baseline outside main, or sits next to aggregate or shard artifacts.

Release eligibility is unchanged and keeps pointing at the **last executed** nightly:
a skip adds no evidence, so a release candidate must still be that nightly's source SHA.
After a non-affecting commit lands, dispatch the nightly (`gh workflow run ci-nightly.yml --ref main`)
if a release needs a fresh run on the new SHA; dispatches always execute.

Diagnose the decision without any GitHub write or workflow output. It reads the real run
history and prints what a scheduled run at the chosen commit would do:

```bash
python3 -B scripts/ci_nightly_change.py --dry-run --repository <owner>/<name> \
    [--head-sha <commit>] [--event schedule]
```

Set `GH_TOKEN` to avoid unauthenticated rate limits. A real `workflow_dispatch` leaves the
change job empty and cannot prove the schedule path (the event differs),
so the first scheduled nights after this lands are the real acceptance: check the
`nightly-change-*` artifact and summary of each, and that a skipped night shows only the
`change` job.

## Population and capacity

[`nightly-matrix.json`](../scripts/nightly-matrix.json) explicitly versions device,
configuration, suite, scenario and fixture. Planning validates the complete population
against current selector/scenario/fixture/scheme contracts; duplicates and missing
cases fail. Runtime discovery cannot silently change the scheduled list. Inapplicable
platforms/scenarios and P2 devices are outside the supported population.

The 132 cases comprise 53 iPhone, 49 iPad and 30 Apple TV combinations,
covering 74 distinct device/suite/scenario identities. Following issue #424,
the three standalone server-switch-display identities were removed after their
guarantees moved into filter-switch and tvos-switch.
Repeat attempts are not new identities. New identities are iPhone/iPad image-failure-recovery.
Both frozen fixtures run wherever permitted. The 22 explicit exclusions comprise two
device exclusions and 20 fixture exclusions. iPad smoke is unsupported: the selected
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
reset/export/cleanup allowance plus 300 seconds of readiness per warm invocation;
filter-person receives three invocation budgets.
Nightly budgets explicitly reserve another 600 seconds for the post-build gate,
with seven minutes of remaining diagnostic/cleanup margin, including the gate's
180-second hard-timeout headroom. Toolchain/pins verification precedes early boot.
The nightly submits boot immediately after creating the dedicated device; startup
and settling overlap the cold build. After a successful build, the tracer runs
bootstatus and the LaunchServices spawn probe in a child process, before any warm
case or fixture health check. Readiness retains its 300-second budget inside the
600-second preparation budget; neither includes build time. The child has a hard
780-second timeout with process-group cleanup. Logs live in the tracer's private
`simulator-preparation.log`; phase and total elapsed lines are relayed to the job
log, rather than the job summary. Bounded diagnostics continue into compact records.
Every `run_strict_e2e` caller reuses its successful initial boot during later resets,
including local runs, listed retries and filter-person sessions; all reset gates
and mutations remain mandatory. The separate strict-tracer workflow still prepares
before building. Before the reset bound, the hosted first iOS smoke
completed in 457.7 seconds including preparation and test execution
([run](https://github.com/sudoHG/immichSlides/actions/runs/37726829510)); 600 seconds
gives cold boot its own budget above that measured complete-case duration.
Local and hosted cases follow the [shared preparation and reset bounds](CI_STRICT_RUNNER.md#shared-simulator-reset).
Official tests and summary exports each have a 60-second deadline. Preparation/export
timeouts name the phase in compact infrastructure entries without command arguments/output, preserve a failed
case record, finish cleanup and quarantine raw bundles privately. Xcode cold/warm
execution budgets are unchanged; the outer warm allowance includes readiness. The tracer
retains these entries even when official exports are unavailable, so application/test execution and infrastructure hangs remain
distinguishable. An xcodebuild test-execution timeout remains a failure of that case,
without an infrastructure entry.
The person shard contains both fixtures: two three-session cases and four single-session
cases require ten invocations. Cold/warm/reset/export allowances total 148 minutes
(24 cold plus 124 warm), with up to 50 more minutes if every invocation consumes
its readiness budget: 198 minutes total. The 215-minute job cap leaves the original
17-minute margin for initial preparation, setup, uploads and final cleanup, so a slow shard
can publish its failed records before runner teardown. Readiness can exceed its
scheduling deadline while the last timed-out query finishes cleanup; see the
[shared bounds and overrun logs](CI_STRICT_RUNNER.md#shared-simulator-reset).
Reaching the job cap is a failure; unrun cases remain unverified.
If simulator creation or the separate preparation gate fails before the tracer starts,
the workflow invokes the tracer's `--preparation-failed` accounting mode before upload.
It writes the same bound compact schema with every planned case failed, every attempt
`not-run` with an infrastructure reason, no compiled cases and empty cold/warm traces.
The aggregate counts zero executions and retains every failure. The trusted reporter
retains the cases as missing with an infrastructure reason and their official methods
as unobserved, tracking the failure under the separate nightly infrastructure issue
according to the [reporting boundary](CI_REPORT.md#issue-lifecycle).
This mode starts no builds or tests and changes no preparation or execution budget.
Planning/aggregate have 15-minute caps.
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
It also runs the
[nightly-default locale screenshots](CI_UI.md#nightly-default-locale-screenshots),
which pull requests omit unless they change a string catalog or a captured screen.

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

Each nightly UI consumer downloads to a fresh directory owned by its run/attempt.
After the download and before the UI run step, a 120-second integrity gate verifies
the selected ID/run/attempt and identity, requires exactly `manifest.json` and
`build.tar.gz`, and reuses the manifest and tar inventory
validators. The selection already validated the immutable artifact ID in this run;
the gate makes no network request. It reads through the gzip trailer before checking
the compressed SHA256: truncation (`EOFError`) reports `archive-download-incomplete`,
while corrupt deflate data or a bad gzip CRC continues to the digest check and reports
`archive-hash-mismatch`. It then checks every declared member size and atomically
renames the verified directory to the run step's archive path. No manifest or
selection schema changes are needed.

Run [39618104921](https://github.com/sudoHG/immichSlides/actions/runs/39618104921)
retained 13 successful gate receipts (0.98–4.62 seconds) and one iPad visual-d
timeout at 30.30 seconds. The latter is censored: completion after 30 seconds
was not observed. The 120-second cap provides approximately four times that
observed cutoff while keeping every integrity check and the fail-closed timeout.
The additional 90 seconds fits within the unchanged 110-minute UI job cap:
the 85-minute fixture runner plus this two-minute gate leaves 23 minutes for
downloads, initial preparation, exports and cleanup. Preparation inside the
fixture runner spends that existing 85-minute allowance, as described in the
[service budget contract](CI_STRICT_RUNNER.md). No workflow timeout changes.

The [download receipt](CI_SUMMARY.md#prepared-archive-download-receipt) records the
action outcome, bounded member sizes, digest/size matches, combined transfer/extract
elapsed time (including step scheduling), gate seconds and available disk. Its
closed-set failure reason reaches the job summary and issue table; raw errors and
paths are not copied into it. Existing member byte sizes are measured before action
and member-set checks, so missing manifests and failed actions still report the tar
size. Unexpected exceptions retain the current section's reason and still write a
receipt; stderr includes only the exception type and the closed-set reason.
A gate refusal is infrastructure failure with no compiled or executed cases; those
cases remain `NOT_RUN`. Missing diagnostics are null and render as `unavailable`
without a unit. The gate adds no retry or budget change.

The standalone simulator creation/boot step runs before the archive downloads.
A gate refusal skips the run step and never reaches XCTest; it does not prevent
that earlier boot. The existing readiness budgets are unchanged.
The gate does not prove simulator readiness, app behavior or runner survival; later
relocation, signing, extraction and UI checks remain required.

The UI matrix needs only the change check, plan and archive selection, so it can
start alongside strict once both platform archives are ready. Both matrices retain
`max-parallel: 2` and `fail-fast: false`. Within the
[five shared hosted macOS slots](CI_PUBLISHER.md#main-push-coalescing), strict and
UI together use at most four, leaving one for PR work once live jobs finish.
The two `live-build` jobs precede `ui-archive`; selection and both aggregate jobs
run on Linux. `live-unit` (at most two jobs) and `live-canary` can briefly compete
with strict, UI and PR jobs for the shared slots; none has a reserved slot.
The UI aggregate still waits for its plan, archive selection and all UI shards;
the final aggregate waits for both strict and the UI aggregate.
Minimum waves round the actual shard count up after division
by two: the current six shards on each of three devices require 18 jobs and nine
start-order waves, without reserved runner slots. Existing invocation, export and
job timeouts remain bounded.
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

Both aggregate jobs run on `ubuntu-24.04` with the reporter's pinned Python packages.
They read compact artifacts and Git source data; they require no Xcode, simulator,
Pillow or zstd tooling. Workflow policy rejects macOS runners, Xcode commands and
toolchain verification in these jobs so reporting does not wait for macOS capacity.

For a branch acceptance run, use the installed trusted reader in read-only mode:

```bash
python3 -B scripts/ci_report.py --dry-run --diagnostic-nightly --run-id <RUN_ID> \
    --output-dir '<fresh-outside-repo>/report'
```

This diagnostic performs no GitHub writes and publishes no trusted history. Production
reporting accepts only main; a branch result does not replace a main nightly.

## Results, scope and eligibility

The commit being released must be the source SHA of the latest nightly run on main,
whose latest attempt must have a verified passing complete fixture UI aggregate for
iPhone, iPad and Apple TV, with no missing shards or samples. Commits merged after
that nightly have deferred, unverified UI and must wait for a later nightly covering
their SHA. An older green run, a diagnostic dispatch or a main UI status deferred to
nightly cannot satisfy this prerequisite. Existing source binding, qualifying-run
and maintainer P2 review requirements still apply.

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
PASS. Unsigned or pending iOS pause timing follows the same aggregate treatment:
the case stays `needs-human-review` in `observed` and `needs_human_review`, while
the producer stays `unverified`. Aggregate health can pass its automated checks
without signing that case. The reporter preserves H for the official method as
well as the case, so pending timing cannot count as an explicit pass night toward
issue recovery. Informational Vision outcomes are listed separately and excluded from
health, with one exception: an informational failure can turn an otherwise
environment-limited night red (see
[prepared hosted strict environment limits](CI_SUMMARY.md#prepared-hosted-strict-environment-limits)).

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
