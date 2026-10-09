# CI reporting and failure tracking

`ci-report.yml` uses the default `GITHUB_TOKEN`, with `issues: write` and read-only
contents, Actions and pull-request access. It has no App key, publisher environment,
status-writing grant or approval authority. Code and data come from verified main
history. Producer summaries remain self-reported evidence; reporting grants no release
authority. See [trusted publication](CI_PUBLISHER.md) for admission and approval.

## Collection and retention

`workflow_run` is filtered to `branches: [main]`. A main completion reads only its
triggering producer run and the prior verified reporting snapshot. Its job condition
checks the head repository and event: gate/UI must be main pushes, and nightly must
be scheduled or manually dispatched on main. PR and fork completions do not start
reporter jobs and are also excluded by collection and issue synchronization.
Daily scheduled/manual collection finds recent main pushes and nightlies, skips completed attempts already in the snapshot
and revisits pending runs. It never repeats two days of artifact reads per completion.
Branch diagnostic nightlies, including historical #158 probes, remain excluded.
Single-shard dispatches on main remain recorded with `diagnostic_shard`, but cannot
open, update or recover issues. The scheduling plan verifies that flag even when
the aggregate is missing; a manual dispatch without a verified plan is ineligible.
The reporter never crawls PR runs. Producers retain their own per-run JSON artifacts
and step summaries for 30 days.
For a main UI matrix skipped through trusted identical-tree reuse, reporting calls
the existing publisher reuse reader; a skip without its verified proof still fails.
This does not activate skipping or change the producer's matrix.

The latest trusted snapshot is merged, rather than rebuilding historical days from
producer artifacts. Only new evidence from the seven most recent UTC dates may drive
issues or post-merge notifications. Expired artifacts preserve saved results, cannot
create infrastructure notifications, and cannot provide new closure evidence. Verified
history remains for 90 days even after its seven-day producer evidence expires.

Each run entry retains source, identity, manifest/policy hashes, counts, failed/missing
identities and infrastructure codes. It retains nightly observations only for failing
or already tracked methods; complete declared/compiled/observed populations stay in
the producer's own artifact. Fork, CI-changing and approval-based provenance remain
explicit. Candidate error messages, credentials and private runner text are not copied.

The repository's `GITHUB_TOKEN` quota is shared with its other workflows. The reporter
uses `X-RateLimit-Limit` and `X-RateLimit-Remaining`, stops before a request would leave
less than half that quota, and permits at most 150 requests across collection and
synchronization together. The upload carries the consumed budget into synchronization.
After the prior history is verified, reaching either bound preserves that history and
verified updates and defers issue writes. Before history is verified, a rate-limit
stop fails the job and publishes nothing. The next collection replays
eligible saved evidence idempotently, so deferral cannot lose an issue transition. A receipt records requests,
remaining allowance, snapshot bytes and whether collection stopped. JSON artifact
downloads are bounded and never extracted or executed; reading two members of the
same artifact uses one download.

| Artifact prefix | Content | Retention |
| --- | --- | --- |
| `ci-report-daily-<run>-<attempt>` | Compact `history.json` and UTC-day snapshots | 90 days |
| Producer's own PR artifact | Per-run PR summaries; collected by the producer | 30 days |
| `ci-report-runs-<run>-<attempt>` | Updated main/nightly summaries and issue-sync receipts | 7 days |
| `ci-report-health-<month>-<run>-<attempt>` | Monthly health JSON and Markdown from verified rollups | 90 days |

History schema version 2 contains `days`, `issue_index`, `registry`, `budget_stopped`, `api_budget`
and trusted reporter `producer` provenance. Daily schema version 1 contains `day`,
`retention_days` and `entries`; run entries remain version 1. The latest attempt replaces
its run's saved entry; older deliveries cannot overwrite it. A nightly entry also keeps
compact `attempt_history` so the first failure survives reruns. Conflicting identities
or provenance are refused.

Search repository artifacts with pagination and order reporter snapshots by artifact
creation time, independently of workflow creation order or completion status. A verified
upload from an earlier attempt remains usable if a later rerun is interrupted. Consume
the newest available snapshot only after verifying its repository,
workflow ID/path, main ancestry, uploader run/attempt and embedded provenance. The daily
artifact is uploaded before issue synchronization. A later issue-sync failure makes
the job fail while leaving that verified data available for the next collection;
issue-sync success is not a condition for retaining already verified test evidence.
Unreadable, invalid, expired or missing snapshots from prior reporter runs fail collection
without uploading a replacement. A first bootstrap or intentional reset requires a
repository-owner `workflow_dispatch` with `reset_history: true`; both the original
and triggering actor must be the owner. The snapshot records the actor, day, run and
that reset dispatch's UTC creation timestamp under `history_reset`. A legacy snapshot
without the timestamp uses one Actions read to verify the reset run's repository,
workflow, main branch and both owner actors, then caches its timestamp in the next
snapshot. This read shares the existing quota reserve and request cap; a budget stop
preserves history and defers writes. Scheduled runs cannot reset history. A read-only dry-run may
start locally without a previous snapshot; it cannot publish that history.

## Method identities and reruns

Nightly aggregates describe suite cases, while the flaky registry describes test
methods. A suite result cannot close or open a method issue. The existing strict tracer
therefore includes `official_methods` in each compact warm trace, taken from officially
exported XCTest results after checking the selected bundle/method and summary counts.
The reporter verifies shard run/attempt, identity, hashes and aggregate case membership,
then verifies each method against the suite's selected methods. Missing exports remain
missing evidence, including partial multi-invocation `filter-person` runs.

All aggregates from attempt 1 through `run_attempt` are read; saved verified attempt
data can replace expired bytes. A failed first attempt remains a failed night after
rerun. A newer attempt without a tracked method observation revokes its earlier pass
eligibility as unverified. `flaky-passed`, skipped, missing and infrastructure results
never supply an explicit pass.
Failed identities from every attempt enter tracking before compaction and issue
synchronization, including a run first collected after its rerun passed.

For a P2 suite, an officially passed method with the suite's passing automated contract
recorded as `needs-human-review` counts as an explicit pass for issue closure only.
Signed human review and release eligibility remain separate and unchanged. The skeleton
nightly remains not release eligible, and unbuilt/informational tiers open no test issues.
A failed strict case creates a case-identity failure with `strict-case-contract-failed`
only when `automated_contract_failed` records an explicit `FAIL` from the runner's
contract receipt and every selected official method passed with valid warm-build evidence.
The tracer exports that boolean without the contract's raw error text. Timeouts, export
failures, missing official methods and unexplained runner failures instead enter
infrastructure tracking; an officially failed method still keeps its method failure.
Later verified case-contract passes can recover
that case issue; they grant no human approval or release authority.

## Issue lifecycle

`ci-reported-failure` identifies managed issues. Each failing nightly method identity
has one issue, with strict device/configuration/suite/scenario/fixture dimensions.
UI method/platform identities normalize device shards to their shared registry issue.
A registry issue is reused even if closed or past its review date. Missing or conflicting
registry issues are refused instead of producing duplicates. Adoption preserves existing
prose and labels and adds the reporter label, so removal from the registry does not lose
tracking. Collection lists only open labelled issues and carries that inventory into
synchronization. Closed issues are searched by label and title only for identities
involved in the current evidence; only matching issues are refreshed directly before
decisions and writes. The snapshot's identity-to-issue index locates adopted issues
whose original maintainer title is preserved, without scanning closed issues.
The same targeted title lookup deduplicates closed post-merge
notifications. Incomplete or oversized search results fail that identity instead of
enumerating accumulated closed issues. New issue label visibility is checked with a
60-second deadline before continuing, so index lag cannot create a duplicate on replay.

Closure requires three distinct UTC nights after the last failing night with explicit
passes for that identity and no registry reference. Multiple runs on one night count
once; any registry reference, including an expired one, blocks closure. A manually
closed issue reopens only for a new verified failure, never by replaying its old
failure or delivering passing nights. Closed issues are not rewritten on passing nights.

The managed state keeps lifetime first/last failure dates and failure-night count,
recent replay bookkeeping and nights since the last failure. At most three older pass
nights are needed for closure; newer attempts inside the evidence window can revoke
their eligibility. This bounds routine history growth. An oversized issue
is isolated to its identity, other issues and outputs continue, and synchronization
still reports failure after the durable rollup upload. Sync receipts contain controlled
error codes rather than candidate text.

Nightly infrastructure has a separate operational issue and is never inserted into test
populations. Recovery needs three successful nightly aggregates with verified evidence.
Main-push test failures produce one notification per SHA, shared across gate/UI reruns.
They require a verified failing identity and a push created at or after the recorded
bootstrap/reset timestamp, within the evidence window. Missing admission, unbuilt or
missing tiers, and a red aggregate without a failing identity cannot produce a test
failure notification. Historical backfill remains in rollups without retroactive
post-merge notifications; missing creation timestamps or reset boundaries are ineligible.
For the same SHA and producer workflow, the newest run supersedes older deliveries,
including when the replacement is still pending or passed. Cancelled main pushes and
nightlies retain `conclusion: cancelled` and normally `status: unverified`, read no missing
artifacts, and cannot open/recover test or infrastructure issues. Legacy entries in
the recent discovery window are refreshed once to record their creation time and
conclusion. Aggregate reporting remains separate from verified test failures.
Post-merge notifications remain for human triage.

Cancelled first-attempt main gate runs whose complete GitHub jobs list proves
that no runner or step executed, and which have a newer main-push gate run with
a greater run ID and a different head SHA, are retained as `not-run`, with an empty test
population and an explicit not-evaluated reason. They do not open post-merge
failure notifications or count as passes. This label does not change the rule
that every cancelled main push is ineligible for notification. A run cancelled
after any job starts, a cancelled rerun, no newer different push, or
missing/ambiguous job evidence retains `unverified` in the reporter; the publisher
keeps its ordinary fail-closed path. Every job must have status `completed` with
conclusion `cancelled` or `skipped`, no runner and an empty steps list. The jobs'
unique IDs must match the API's explicit `total_count`; an empty list requires
`total_count: 0`. Both neutral reader paths retain the saved first-execution
health fields without inventing test observations.

The same SHA's first-attempt main UI run is also `not-run` only when its bound
archive summary failed solely with `archive-unavailable`, no refusal exists, and
every admitted shard skipped without executing. Other UI failures remain eligible
for notification. The publisher uses the same predicates; see
[trusted publication](CI_PUBLISHER.md). Previously saved failure entries carrying
an identity, and their human-triage notifications, are preserved rather than
rewritten by this reader update. Entries without an identity are read again.

Registry diagnostics list review dates and closed/missing issues without editing the
registry, changing retry eligibility, outcomes or thresholds. See
[listed-only retries](TESTING.md#known-flaky-registry-and-listed-only-retries).

## Registry upkeep and monthly health

The daily schedule and eligible nightly completions check every registry entry.
`runs/registry.json`, `runs/registry.md` and the job summary show its owner, review-by
date, age, linked issue state and date eligibility. Workflow warnings start seven UTC
days before review-by and continue through expiry; closed, missing or unread issues
also warn. Unread state is `unknown`, not evidence that the issue is missing. Issue
reads reuse the inventory and deduplicate issue numbers; upkeep adds no API requests
or issue writes.

The existing `ci_flaky.eligible_entry` is authoritative: an entry remains date eligible
through its review-by UTC day and is no longer retried the following day. Expiry does
not invalidate registry formatting, fail all PRs, remove entries or change outcomes.
Issue state does not change eligibility. Any registry reference still blocks automatic
issue closure, including an expired reference.

On the first UTC day of each month, the existing daily schedule reports the previous
calendar month. An owner dispatch can set `health_month: YYYY-MM` for a previous month
or the current partial month without resetting history. Health uploads follow daily
history and precede issue synchronization, so an issue-write failure cannot lose them.
No extra schedule, macOS job, secret, App key or write permission is introduced.

Health uses the reporter's verified snapshot and daily rollups. It shows exact available
days, days with runs, statuses, diagnostic/incomplete runs and missing calendar days.
Scope remains main pushes and nightlies; PR producers are not collected. Sparse or
budget-stopped history cannot establish a complete month or passing CI.

New entries retain optional version 1 `health` metrics before population compaction:
first-call failures (including crashes/timeouts), flaky-passed outcomes, total skips,
unexpected skips checked against approved base policy and exact reasons, summed test
durations including automatic retries, GitHub run timing and artifact bytes. Strict
nightly skips remain unexpected under the existing aggregate contract. First-failure
counts use GitHub attempt 1; nightly history and previously collected gate/UI counts
survive reruns. Optional `first_execution_health` stores these counts separately from
the latest execution's metrics and survives pending/in-progress rerun snapshots.
Missing attempt 1 is unavailable. Final outcome totals use the latest saved attempt.
Nightly official method exports contain no measured method durations; their zero
observation durations are placeholders. Nightly test duration is therefore unavailable,
not zero. Measured case invocation wall time includes other work and does not substitute
for summed method durations.

Queue seconds sum job creation-to-start intervals from the existing gate/UI job reader,
including retained jobs after reruns. Missing timestamps or nightly job data are
unavailable; workflow start time never stands in for runner queue time. Run
duration means start to GitHub's completed-run update, not CPU/billed time. Artifact
bytes count unique artifact IDs listed for each run at collection, including earlier
attempts; existing reads supply metadata without new requests. This historical sample
is not current repository storage. Compact snapshot and selected month rollup JSON byte
sizes are measured separately. Each metric shows sampled/unavailable run counts and
covers available observations only; a run without any test observations supplies no
test metrics. Health introduces no gating threshold.

Legacy outcome counts supply flaky-passed and total skip counts where observations were
recorded. Unrecorded first calls, skip classification, timing and artifact sizes remain
unavailable. Tracked method subsets never stand in for complete populations. Registry
dates/ages use the report date, while issue states show the snapshot collection date
(or explicitly say that the legacy date was not recorded). Entries aged at least 30
days are counted for review; age does not change eligibility.

Standalone read-only health uses `ReportGitHub` and `read_snapshot`, including uploader
provenance, main ancestry, daily validation, the 150-request cap and half-quota reserve.
Missing/unreadable history is refused; low quota before verification stops without a
report. Health computation adds no API requests or writes to collection. The collection
budget remains shared with synchronization; reports after a budget stop mark history
incomplete.

## Commands and acceptance

The dry-run uses the production reader with a client that refuses every non-GET request.
It writes local reports only, never issues or uploaded artifacts. It uses `CI_REPORT_TOKEN`
or captures the existing `gh` authentication internally without displaying credentials:

```bash
python3 -B scripts/ci_report.py --dry-run --repository <owner/repository> \
  --run-id <recent-main-run-id> --output-dir '<outside-repo>/ci-report-dry-run'
python3 -B scripts/ci_report.py --phase health --dry-run --month YYYY-MM \
  --repository <owner/repository> --output-dir '<outside-repo>/ci-health'
PYTHONPATH=scripts python3 -B -m unittest test_ci_report test_ci_publish test_check_workflow_policy
python3 -B scripts/check_workflow_policy.py
```

Repeat `--run-id` to sample multiple recent main runs. Without it, dry-run uses scheduled
collection. Production phases are `--phase collect`, daily/optional health upload, then `--phase sync`;
the workflow policy checks this order and the main branch filter.

Existing tests guard method/registry identity, expired snapshots, every rerun attempt,
pass revocation, P2 closure, manual closure, per-identity sync errors, bounded histories,
API reserves, write refusal, snapshot upload ordering, interrupted reruns, bounded
closed-issue reads, infrastructure classification and publisher diagnostic exceptions. No new test file is
needed for these review fixes. A throwaway seeded lifecycle dispatch can prove writes;
its issues are closed, its branch deleted and task-created labels removed after the
receipt. Production scheduling and automatic main reporting remain `NOT_RUN` until
this workflow merges. No agent approves a run, deployment or exact head.

Upkeep/health cases extend the existing reporter tests: warning/date boundaries versus
actual retry eligibility, unknown issue state, first-failure retention across reruns
and compaction, unavailable legacy metrics, invalid rollups/metrics, approved skip
reasons, month/year boundaries and low-quota read refusal. Workflow-policy cases guard
monthly upload ordering and success-only conditions. Real-rollup acceptance must cite
the reporter run/attempt, available dates and counts; sparse bootstrap history is not
a full monthly baseline. A read-only Linux branch probe may exercise monthly collection
and upload without issue synchronization; delete its branch after recording the run.
