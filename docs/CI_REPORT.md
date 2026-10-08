# CI reporting and failure tracking

`ci-report.yml` uses the default `GITHUB_TOKEN`, with `issues: write` and read-only
contents, Actions and pull-request access. It has no App key, publisher environment,
status-writing grant or approval authority. Code and data come from verified main
history. Producer summaries remain self-reported evidence; reporting grants no release
authority. See [trusted publication](CI_PUBLISHER.md) for admission and approval.

## Collection and retention

`workflow_run` is filtered to `branches: [main]`. A main completion reads only its
triggering producer run and the prior verified reporting snapshot. PR and fork
completions do not start reporter jobs. Daily scheduled/manual collection finds
PR summaries and recent main runs, skips completed attempts already in the snapshot
and revisits pending runs. It never repeats two days of artifact reads per completion.
Branch diagnostic nightlies, including historical #158 probes, remain excluded.

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

The collector checks `X-RateLimit-Remaining`, reserves 100 requests and permits at most
500 API requests per phase. Reaching either bound stops cleanly, preserves the prior
snapshot and any verified updates, and defers issue writes. The next collection replays
eligible saved evidence idempotently, so deferral cannot lose an issue transition. A receipt records requests,
remaining allowance, snapshot bytes and whether collection stopped. JSON artifact
downloads are bounded and never extracted or executed; reading two members of the
same artifact uses one download.

| Artifact prefix | Content | Retention |
| --- | --- | --- |
| `ci-report-daily-<run>-<attempt>` | Compact `history.json` and UTC-day snapshots | 90 days |
| `ci-report-pr-<run>-<attempt>` | Updated per-run PR JSON and Markdown | 30 days |
| `ci-report-runs-<run>-<attempt>` | Other updated summaries and issue-sync receipts | 7 days |

History schema version 2 contains `days`, `issue_index`, `registry`, `budget_stopped`
and trusted reporter `producer` provenance. Daily schema version 1 contains `day`,
`retention_days` and `entries`; run entries remain version 1. The latest attempt replaces
its run's saved entry; older deliveries cannot overwrite it. A nightly entry also keeps
compact `attempt_history` so the first failure survives reruns. Conflicting identities
or provenance are refused.

Consume the newest completed reporter snapshot only after verifying its repository,
workflow ID/path, main ancestry, uploader run/attempt and embedded provenance. The daily
artifact is uploaded before issue synchronization. A later issue-sync failure makes
the job fail while leaving that verified data available for the next collection;
issue-sync success is not a condition for retaining already verified test evidence.
Monthly health calculation belongs to its separate ticket.

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

For a P2 suite, an officially passed method with the suite's passing automated contract
recorded as `needs-human-review` counts as an explicit pass for issue closure only.
Signed human review and release eligibility remain separate and unchanged. The skeleton
nightly remains not release eligible, and unbuilt/informational tiers open no test issues.

## Issue lifecycle

`ci-reported-failure` identifies managed issues. Each failing nightly method identity
has one issue, with strict device/configuration/suite/scenario/fixture dimensions.
UI method/platform identities normalize device shards to their shared registry issue.
A registry issue is reused even if closed or past its review date. Missing or conflicting
registry issues are refused instead of producing duplicates. Adoption preserves existing
prose and labels and adds the reporter label, so removal from the registry does not lose
tracking. Repository issues are filtered locally and directly read because label indexes
can lag writes; new issue visibility is checked with a 60-second deadline.

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
Main-push failures produce one notification per SHA, shared across gate/UI reruns. Missing
admission can notify only after the pushed SHA is independently verified on main and
within the evidence window. Post-merge notifications remain for human triage.

Registry diagnostics list review dates and closed/missing issues without editing the
registry, changing retry eligibility, outcomes or thresholds. See
[listed-only retries](TESTING.md#known-flaky-registry-and-listed-only-retries).

## Commands and acceptance

The dry-run uses the production reader with a client that refuses every non-GET request.
It writes local reports only, never issues or uploaded artifacts. It uses `CI_REPORT_TOKEN`
or captures the existing `gh` authentication internally without displaying credentials:

```bash
python3 -B scripts/ci_report.py --dry-run --repository <owner/repository> \
  --run-id <recent-main-run-id> --output-dir '<outside-repo>/ci-report-dry-run'
PYTHONPATH=scripts python3 -B -m unittest test_ci_report test_ci_publish test_check_workflow_policy
python3 -B scripts/check_workflow_policy.py
```

Repeat `--run-id` to sample multiple recent main runs. Without it, dry-run uses scheduled
collection. Production phases are `--phase collect`, daily upload, then `--phase sync`;
the workflow policy checks this order and the main branch filter.

Existing tests guard method/registry identity, expired snapshots, every rerun attempt,
pass revocation, P2 closure, manual closure, per-identity sync errors, bounded histories,
API reserves, write refusal and publisher diagnostic exceptions. No new test file is
needed for these review fixes. A throwaway seeded lifecycle dispatch can prove writes;
its issues are closed, its branch deleted and task-created labels removed after the
receipt. Production scheduling and automatic main reporting remain `NOT_RUN` until
this workflow merges. No agent approves a run, deployment or exact head.
