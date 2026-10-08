# CI reporting and failure tracking

`ci-report` runs after `ci-gate`, `ci-ui` and `ci-nightly` complete, at 08:30 UTC
daily, and on manual dispatch. Its Linux job checks out **main**, verifies the
exact workflow/ref/event before reading its token, and uses only `GITHUB_TOKEN`:
contents/actions/pull requests read, issues write. It never uses an environment,
the publisher App, status writes, a real server or candidate executable code.
All actions are pinned and the job has a 30-minute bound. Workflow-policy checks
enforce these grants, main checkout, full history and serialized issue writes.

## Evidence and history

Every invocation rebuilds today and yesterday from GitHub's producer-run list;
a completion also rebuilds its original UTC start day. This repairs dropped
pending completion events in the serialized Actions queue. One entry identifies
repository, workflow path and ID, run/attempt, event, tested identity and hashes
when available, fork origin, CI-changing classification and approval basis.
`null` CI-changing means admission/classification is unavailable. Fork results
remain explicitly self-reported. An approval is never inferred from an artifact.

PR and main-push records reuse [publisher admission and base readers](CI_PUBLISHER.md).
Each summary binds its uploading job and actual evidence attempt, including jobs
retained across failed-job reruns. Missing, expired, malformed or mismatched
artifacts stay failed; other valid job records remain visible. Successful runs
still require the admitted base verdict. Official failures retain identities,
counts and exact attempt exit codes even when Actions is red. Runner messages
and private values are not copied. Expected skips, deselections and removed tests
remain in the base evaluation; raw skips never imply policy acceptance.

Nightly records require the exact workflow ID/path, repository, main ancestry,
latest attempt and aggregate identity. Scheduled and main-dispatched nightlies
are included; PR planning and branch diagnostic nightlies are excluded.
Branch nightly completions skip the report job before checkout or artifact uploads.
Tiers that are not yet in scope create no failure issues. Informational cases do not
open issues. The current skeleton remains **not release eligible**; the reporter
does not grant release authority or replace the fixed nightly aggregate.

Artifacts uploaded by the reporter:

| Artifact prefix | Content | Retention |
| --- | --- | --- |
| `ci-report-daily-<reporter-run>-<attempt>` | UTC-date JSON files, all producer entries plus registry/issue receipts | 90 days |
| `ci-report-pr-<reporter-run>-<attempt>` | Per-run PR JSON and readable Markdown | 30 days |
| `ci-report-runs-<reporter-run>-<attempt>` | Other per-run JSON and Markdown | 7 days |

Rollup schema version 1 has `day`, `retention_days`, `entries`, `registry` and
`issue_actions`. Entry schema version 1 has `source`, `run`, `day`, `status`,
`release_eligible`, `observed` and `diagnostics`; valid evidence adds `identity`,
`hashes` and the trusted `evaluation` or nightly tier information. Diagnostics
separate counts, failed identities/exit codes, missing identities and
infrastructure. Readable lists show at most 50 identities per category; per-run
JSON keeps the complete population and diagnostics. The same run's latest attempt
replaces earlier attempts in a snapshot; conflicting duplicate entries are refused. For a date, consume the
newest successful reporter snapshot by reporter run ID and attempt, after
verifying its workflow ID/path, main ancestry and repository. Never trust a
same-name PR artifact or use an incomplete/failed reporter snapshot for promotion.
Monthly health calculation belongs to its separate ticket.

## Issue lifecycle

The `ci-reported-failure` label identifies reporter-created issues. Each failing
nightly identity has one tracking issue. UI method/platform identities share
their registry issue across iPhone/iPad shards; strict identities retain device,
configuration, suite, scenario and fixture. A registry issue is reused even if
it is closed or its review date has expired. Missing or conflicting registry
issues fail reporting instead of creating duplicates. Existing issue prose is
preserved, and only an appended managed section changes.
The reporter filters the repository's issue collection locally because GitHub's
label index can lag a create, fetches issue bodies directly and waits up to
60 seconds for a newly created issue to become visible before further writes.

The managed JSON marker stores nights and run/attempt outcomes. Replayed events
are idempotent and delivery order cannot move the first/last failure dates
backward. An issue records failure-night count, first and last failure, explicit
pass nights and run links. A manually closed issue reopens on a new failure.
Closure requires **three distinct UTC nights after the last failing night**,
each with only explicit passes for that identity. Multiple runs in one night
count once. A failed first attempt remains a failing night after rerun;
`flaky-passed`, skips, missing evidence and infrastructure outcomes cannot supply
an explicit pass. Any registry reference blocks closure, including expired
entries, until a maintainer removes the reference. Issue history that exceeds
GitHub's body limit fails for human reconciliation rather than dropping history.

Nightly infrastructure has its own clearly named operational tracking issue;
it is never added to test populations or pass counts. Its recovery requires
three explicit successful nightly aggregates. Product assertion failures stay
product failures. Main-push aggregate failures open one post-merge notification
per pushed SHA, updated across gate/UI reports. Missing admission still notifies
after the pushed SHA is independently verified on main. Notification issues
remain open for human triage; the three-night rule applies to nightly identities.

Registry reporting checks review dates (inclusive) and issue state. Expired,
closed or missing issues are listed in the rollup and summary; these diagnostics
do not change retry eligibility, test outcomes or thresholds. The reporter does
not edit the registry. See [listed-only retries](TESTING.md#known-flaky-registry-and-listed-only-retries).

## Commands and acceptance

After merge, a maintainer can rebuild the recent daily snapshots without rerunning
tests:

```bash
gh workflow run ci-report.yml --ref main
PYTHONPATH=scripts python3 -B -m unittest test_ci_report test_ci_publish test_check_workflow_policy
python3 -B scripts/check_workflow_policy.py
```

The local Python tests guard premature closure, registry issue reuse, replay and
out-of-order deliveries, missing evidence, post-merge notification identity,
rollup conflicts/provenance and credential boundaries. They never access GitHub.
The new reporter test file owns this new state/persistence contract; publisher
and workflow-policy regressions stay in their existing files.

Pre-merge end-to-end acceptance uses a task-owned throwaway branch, one explicitly
authorized dispatch, freshly created `ci-report-lifecycle-probe` issues and
clearly labeled synthetic dates. That temporary branch may run its branch script
with issue-write only; no such exception or probe job ships in this workflow.
All probe issues are closed and the temporary branch is deleted after its receipts
are recorded. Production main scheduling and automatic post-merge events remain
`NOT_RUN` until merge. No agent approves a run, deployment or exact head.
