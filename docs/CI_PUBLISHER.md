# Trusted CI publication and approval

`ci-publish` writes informational commit statuses `ci-pr-gate`, `ci-ui` and
`ci-approval-state`. Requiring a context or changing a ruleset is a separate
maintainer decision. It reacts to `ci-gate` and `ci-ui` workflow-run events
(`requested`, `in_progress`, `completed`) and supports main-only manual
re-evaluation. A manual re-evaluation runs no build or test.

## Trust and identities

New producer record shapes require their trusted parser and validator to land first
in a separate PR, alongside the existing reader; see
[reader-first evolution](CI_SUMMARY.md#reader-first-evolution). The nightly UI
successor is read by [the reporter](CI_REPORT.md), so its reader precedes the nightly
producer. This does not change PR admission or publisher status formats.

The workflow checks out `main` only, with full history in publication and admission
so a base remains readable after main advances. Every publisher and approval job
runs on `ubuntu-24.04`. `setup_ci_publisher_python.py` installs only the central
`pip` and `PyYAML` pins in a new isolated environment; it does not require Xcode,
the macOS Python pin, Pillow or zstd. It verifies producer workflow **ID and path**,
repository, event and current PR mapping through GitHub. Forks with empty
`pull_requests` arrays first use GitHub's commit-to-PR API. If that is also empty,
the publisher queries open PRs targeting `main` by the producer's
`head_repository.owner.login:head_branch` label using bounded pagination. Both
paths retain the same checks: exactly one open PR with the producer's head
repository, this repository's `main` base, and the current head SHA for admission.
Stale admission heads, ambiguous matches and pagination failures refuse mapping.
Workflow names and colliding job names do not establish provenance.

The reader treats a cancelled first-attempt main gate as **not evaluated** only
after verifying its workflow ID/path/repository and the complete attempt jobs
list: unique job IDs must match the API's explicit `total_count`. Every job must
have status `completed` with conclusion `cancelled` or `skipped`, have no assigned
runner (`runner_id` is zero or null), and have an explicit empty steps list; an empty
jobs list qualifies only with `total_count: 0`. A newer main-push gate run with a
greater run ID and a different head SHA must also exist. Main history is protected
and linear; a bounded recent run listing supplies that proof. GitHub can set
`started_at` on jobs that never acquired
a runner, so timestamps alone do not prove execution. This applies whether
concurrency replacement or a manual cancellation occurred before execution;
the API does not prove which caused cancellation. Without a newer different push,
the cancellation follows the ordinary failure path. The pushed SHA remains pending
with a link to its cancelled run, never successful and never credited with a
newer SHA's evidence. Main's `ci-approval-state` remains successful with
**Approval not needed**. Started jobs, reruns and ambiguous/API-incomplete evidence
keep the ordinary fail-closed path. This reader does not change producer scheduling.
The reporter retains its separate rule that every cancelled main push is
ineligible for notification; see [CI reporting](CI_REPORT.md).

The same predicate, with the same proof, applies to a first-attempt main `ci-ui`
run replaced while pending, checked against the `ci-ui` workflow and its own newer
main-push run. Its UI status is then pending with "Not evaluated: UI run cancelled
before any job executed" instead of a failure.

### Main-push coalescing

Main history is protected and linear, so a newer pushed SHA contains every older
one. Piling up one `ci-gate` and one `ci-ui` run per merge only spends the five
scarce hosted macOS slots on SHAs nobody will release. Both workflows therefore use
one shared concurrency group for first-attempt main pushes, with
`cancel-in-progress: false` (`scripts/check_workflow_policy.py` enforces the exact
expressions):

```yaml
group: ci-gate-${{ github.event_name }}-${{ github.event.pull_request.number || (github.event_name == 'push' && github.run_attempt == 1 && 'main') || github.run_id }}
cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

- **What may be superseded:** only a run that is still pending in the group, meaning
  no job has started. GitHub allows one running and one pending run per group; a
  newer push replaces the pending one, which ends `cancelled` with no jobs. A run
  counts as running as soon as any job starts, even while its macOS jobs wait.
- **What is never cancelled:** a run that has started. It finishes, so its evidence
  is complete rather than a partial run killed mid-build. Merges are normally
  minutes apart, so the newest main SHA is evaluated in full.
- **Residual race:** GitHub does not guarantee that runs enter a concurrency group
  in push order. In a rare race an older first-attempt run can replace the newest
  pending one, leaving the newest SHA unevaluated. That SHA is reported "not
  evaluated", never success. Later main pushes evaluate the gate, and the nightly
  full tier evaluates main UI. When a specific SHA needs a gate verdict (for example
  before tagging a release), the maintainer uses "Re-run all jobs" on `ci-gate`
  (attempt 2, own group). No trusted
  re-dispatch is added for a race this unlikely.
- **Why not also cancel in-progress runs:** a rolling burst of merges would then
  cancel every SHA before it finished, and nothing would be evaluated. Pending-only
  replacement keeps one finished evaluation per drain. The cost is that one
  started run per workflow keeps its queued macOS jobs until it ends.
- **Reruns and other events:** a rerun has `run_attempt` above 1, so it keys on its
  own run ID, cannot displace the newest pending run and cannot be replaced by a
  later push. Pull requests keep per-PR cancellation. Nightly runs, which stay
  uncancellable, and the trusted publisher, importer and router workflows keep their
  groups.
- **Publication:** a replaced run is not evaluated; the publisher keeps that SHA
  pending with a link and the reporter records `not-run` without a notification.
  The post-merge notification covers evaluated SHAs only.
- **ci-ui:** its group coalesces separately from the gate's, so a replaced UI run
  needs no archive. The final SHA's UI run starts waiting for the gate archive at
  push time while the gate may still queue behind an older run. While the same-head
  gate run is `pending`, the archive selection deadline is paused for at most
  50 minutes in total. The iPhone/iPad and Apple TV selections share one deadline
  that includes the accumulated pause, so the total wall-clock cap is 170 minutes
  inside the 185-minute Linux job timeout. The 15 minutes of margin cover the final
  API reads and downloads, which the deadline does not count; a job that still hits
  the job timeout fails closed (no archive, no pass). The wait ends immediately when
  the same-head gate run was cancelled.
- **Release:** the maintainer tags `v*` on main. Tag the newest SHA whose gate and
  UI runs both evaluated. For a SHA that was replaced, use "Re-run all jobs" on its
  cancelled `ci-gate` and `ci-ui` runs; the rerun is attempt 2 in its own group, so
  later pushes cannot cancel it.

For the same SHA, a first-attempt main UI run is also **not evaluated** only when
its complete jobs listing shows a failed `ui-archive` and every admitted UI shard
skipped without a runner or steps. The sole archive summary must bind to the run,
attempt, trusted admission identity and manifest, with only the exact
`archive-unavailable` timeout outcome and no archive refusal record. The reader
independently verifies that SHA's authoritative gate satisfies the superseded,
unexecuted predicate above. The UI status stays pending with its own run link.
Executed shards, identity mismatches, any refusal, other archive failures and
reruns retain the ordinary failure path.

Admission is separate from publication, serialized by producer run ID with
`cancel-in-progress: false`. It reads GitHub's test merge SHA and commit parents,
fetches that commit as Git objects, and verifies that its first parent belongs to
main history. Candidate code is never checked out, imported or executed.
Base-revision readers derive static host/Python, Swift unit and UI populations
from source text. The trusted `ci-admission-<producer-run-id>` artifact stores:

- the repository, PR number, GitHub merge/base/head/tree identity (or main push identity);
- producer workflow ID and path;
- the complete tree listing, populations and base populations;
- default-plan UI populations by device/shard, the base UI population, and manifest/plan hashes;
- the trusted base reader revision, classification, workflow metadata and policies.

The artifact is kept 30 days. Readers query its exact name, verify the producing
run's workflow ID/path, event, branch and both repository identities, then verify
the uploader's head SHA against fetched main with local `git merge-base --is-ancestor`.
A tag named `main` is insufficient. This lookup does not list publisher history;
API cost depends on matching artifacts rather than newer unrelated runs. Readers
ignore untrusted same-name objects before reading any artifact bytes,
and read only the bounded JSON member; no ZIP is extracted and no artifact code
is executed. Base-reader modules are loaded from Git objects at the verified
main first parent, rechecked against main history, and run in a temporary isolated
subprocess without credentials. Evaluator dependencies, including `ci_flaky.py`
and `ci_ui_shards.py` when present, come from the same base; older bases without
them remain supported. Recording-suite eligibility is declared in `ci_flaky.py`
and shared with the strict runner/P2 contract, so parsing a mixed strict/UI
registry needs no image processing or strict-runner imports in the isolated reader.
Main retains that base; late approval does not
require fetching the old merge commit again.
Reruns preserve the first record because GitHub re-tests the original SHA/ref.
If that record expires, the context stays pending; push an updated branch to get
a new admission. For a fork, closing and reopening also starts fresh runs.

A producer identity must match the record exactly. A mismatch reports
**base moved; push again or update the branch**. An App-created success receipt
`ci-base-mismatch/run-<run-id>/attempt-<attempt>` persists each mismatch as
bookkeeping, explicitly not a test result; a later
attempt is marked repeated only if an earlier receipt exists. Attempt number
alone proves no previous mismatch. Rerunning cannot fix a different admitted merge. Conflicting
PRs do not get producer runs from GitHub and cannot become green.

Push admissions verify repository, `main` and ancestry of the pushed SHA.
`workflow_run` does not carry the complete push `before` range, so push
classification is conservatively app-affecting unless a range was independently
verified. This prevents a multi-commit burst from hiding an earlier app change.

## Current-state publication

Only publication jobs use the `ci-state-pr-<number>` concurrency group. Approval
wait, record and fallback jobs have no replaceable concurrency queue, so another
publication cannot cancel a pending approval record. Publication always
re-reads the current head, selects the highest producer run ID and latest attempt,
and writes all three display contexts. An older completion cannot supersede a
newer failure. An in-progress rerun invalidates the previously green context.
An absent admission is pending even if the producer already completed; the
approval display is pending until trusted classification exists. Only a newly
recorded admission dispatches another evaluation. Superseded queued publication jobs can be
dropped by GitHub without losing their facts: the next job recomputes everything.

Required job names and record artifact names come from the admitted workflow,
including literal matrix expansion. Producer entry points and literal platform
arguments bind each uploading job to its tier/job/shard and independently derived
population; a summary cannot choose its own required population. Exact-head approval permits candidate
workflow **metadata and policy**, while executable population and verdict readers
remain from the base. Every required job must finish successfully; missing,
skipped, failed or cancelled jobs/artifacts are red. GitHub's failed-job rerun API
can regenerate job IDs while retaining execution timestamps and runner IDs.
Equal `started_at`, `completed_at` and `runner_id` retain the earlier evidence
attempt; an actual new execution requires its new artifact. This retains earlier
successful jobs' artifacts and refuses older artifacts for a job that actually reran.
Unknown matrices, shards or tiers fail closed until a supported reader is landed
on main before the producer starts emitting them.

The UI reader supports a Linux `ci_ui_tests.py wait-archive` job and literal
`ci_ui_tests.py run --device DEVICE --shard SHARD` jobs. Each still requires one
bound summary artifact and a successful GitHub job. Supported devices are
`iphone`, `ipad` and `appletv`; the producer determines which device matrix is
currently in scope. A device's shard names must exactly equal the admitted
manifest's names, without duplicate assignments. Each shard's independently
derived default-plan population includes its platform and device. The gate
checks this complete union, including declared, compiled and observed identities.

The producer must emit these literal summary fields and hash logical names:

| Producer | `run.tier` | `run.job` | `run.shard` | Required identities / hashes |
| --- | --- | --- | --- | --- |
| `wait-archive` | `ui-infrastructure` | `ui-archive` | `null` | One `host` identity with key `UI archive selection` and empty dimensions; `hashes.manifests.ui-shards` |
| `run --device DEVICE --shard SHARD` | `ui` | `ui-<device>` | The literal manifest shard | Complete shard UI identities with `platform` and `device`; `hashes.manifests.ui-shards` and `hashes.manifests.test-plan` |

The archive-selection summary still carries the consumer's complete PR
merge/base/head/tree identity (or main push identity). An archive's producer run
ID cannot replace the consumer's `run.id`. Upload artifact names bind the
GitHub job and its actual evidence attempt through the admitted workflow.

Admission retains the base and candidate `scripts/ci-ui-shards.json`, default
plans and their SHA-256 hashes as data. It calls the isolated base revision's
shard rules at admission and stores both rule selections' complete device/shard
populations; publication reads these stored populations without recalculating
them using a later publisher's rules. Candidate-side parsing errors are retained
as an invalid UI input and fail only `ci-ui`. Invalid base manifest, plan or
workflow data refuses admission. Errors computing shards from the tested tree,
including an empty shard after a class or method rename/removal, are recorded for either
rule selection and fail only `ci-ui`; the gate admission still completes. The
base's filtered source population remains available for an approved replacement
manifest to account for removed tests. Renaming or removing a class or exact method
named in the manifest requires updating its selectors and exact-head CI approval,
even when the affected shard remains nonempty. Only the fixed empty-shard and missing-base-workflow
hints reach status descriptions; other parsing details stay generic.
A new workflow absent on the base is
retained only as candidate metadata; exact-head approval is still required before
it is selected. Before approval the context reports
`workflow is absent on the base; exact-head approval required`, and the approval
request is still created. Candidate files are never imported. Every UI summary binds the
manifest hash; device shards also bind their default-plan hash. The base's
known-flaky registry remains authoritative, with eligibility checked against the
producer's GitHub run start date, including reruns. Fixture UI is hermetic for
registry scope; platform-method entries apply to verified devices on that
platform. Device dimensions remain in coverage and expected-skip accounting.

Shard manifest version 1 contains `schema_version`, a named `revision`,
`default_shard` and `shards` (a map from shard names to exact XCTest class names).
The reader also accepts version 2, described in [CI_UI.md](CI_UI.md).
Unknown classes go to the default shard, including tests in extensions. A class
cannot appear twice. The default test plan's class/method selections and
exclusions apply before assignment; Evidence and strict tests stay outside this
population. Every required shard must contain tests on every device in the
producer's literal matrix. An empty shard reports
`shard X has no tests on DEVICE; update scripts/ci-ui-shards.json`; update the
partition before adding a device whose platform would leave a shard empty.
The manifest and both default `immichSlides-iOS.xctestplan` /
`immichSlides-tvOS.xctestplan` files are CI-trusted classification inputs;
changing selections or exclusions requires exact-head approval.
The reader accepts no dynamic matrices or alternate manifest paths.
The post-merge reader additionally accepts skipped device shards on a main push
after independently finding a complete trusted identical-tree PR verdict (success),
or verifying the admitted base workflow's explicit `--defer-main-ui` declaration
(pending: "UI deferred to nightly"). All required selection jobs must still succeed
and supply identity-bound, manifest-bound summaries; skipping a selection job or
only part of the device matrix fails.
GitHub may report a whole skipped matrix as one unexpanded job name. The reader
maps that exact trusted-workflow name to its declared literal shards while
retaining the real job's identity and attempt. Each attempt is normalized before
execution history is merged by logical shard, so a rerun may switch between
skipping and executing the matrix. Overlapping shards within one attempt,
unknown names or an incomplete final job set fail. This mapping supplies no test
observations. Success still requires independent trusted reuse proof; the explicit
trusted deferral declaration supplies only a pending status.

For PR reruns, an older attempt whose `ui-archive` infrastructure job failed may
contain a raw skipped matrix placeholder because no shard started. The reader
discards only that historical placeholder; it contributes no shard evidence.
Its matrix shards acquire a minimum valid attempt after that skip, invalidating
even successful shard evidence retained from earlier attempts.
Later literal jobs must cover the entire required population with records bound
to their own execution attempts. A current PR matrix skip, incomplete later
execution, overlapping literal jobs or stale artifacts remains inadmissible.

Every ordinary run retains the existing successful-job and complete-population checks.

The [feature-area reader](CI_UI.md#feature-areas-and-the-reader-first-rollout)
also admits an exact scoped population. Admission calls `ci_ui_selection.py`
from the verified base with the trusted diff, base classification policy and
base `scripts/ci-ui-areas.json`; candidate area maps never authorize selection,
even after exact-head approval. Both base/candidate shard-rule inputs retain
that same map revision/hash and their derived selections. Historical bases
without this reader/map remain full-only.

Historical unflagged shard computation and feature selection have separate failure
boundaries. A failed selection is stored only in `selection.error`; the complete
population remains admitted, while scoped evidence fails closed. The activated
[packed protocol](#packed-scoped-ui-protocol) instead refuses selection errors.
Host checks require smoke coverage
in every device's default plan. Admission retains the same `immichSlidesUITests`
inventory roots as the producer and shard validation; TestSupport is coverage-only.

For historical unflagged producers, publication first recognizes a complete full
population for compatibility. Otherwise the entire UI population must equal the stored
selection on iPhone, iPad and Apple TV, and every shard must equal its own selected
identities. Arbitrary subsets, per-device omissions and mixtures fail closed.
Compiled and observed equality, run/head/tree identity, manifest/plan hashes,
outcomes, registry and approval checks still apply. Only shards whose independently
selected population is empty may skip: their literal GitHub jobs must be complete,
skipped, have no runner or steps, and supply no summary. Selection exclusions
are not reported as test removals. External cloud evidence retains the full path;
scoped cloud routing is outside this rollout.

### Bound dynamic UI shards

GitHub cannot skip one entry of a static matrix, so a scoped producer lists only
the shards it runs: each UI matrix may take exactly
`shard: ${{ fromJSON(needs.archive.outputs.ios_shards) }}` (or `tvos_shards`) beside
a literal device list of that one platform. The activated packed protocol requires
`iphone_shards` and `ipad_shards` in separate matrices beside each literal device.
Any other dynamic matrix value, a
second occurrence of that expression, or a mixed-platform device list is refused.
Admission binds the expression in both stored `ci-ui.yml` texts to trusted names
and leaves every other byte unchanged. For an unflagged non-CI-changing pull request
with a `scoped` base selection, the names are the manifest-ordered shards with selected
identities (iPhone and iPad must agree); for a docs-only `none` selection they are
empty; otherwise they are every manifest shard. Packed PRs instead bind their exact
independent device lists, including core/unknown/CI-changing selections. Every later reader (job
contract, artifacts, reuse, reporting, Cloud skip recognition) uses the bound text,
so a producer that schedules a different shard set fails the required-job check.
Main-push reuse reads the pushed revision's workflow directly; it binds the dynamic
form to every shard of that revision's manifest before comparing receipt shards,
while input hashes still use the raw workflow bytes. Publication checks the scoped
device scope against the bound workflow's device declarations, so a platform without
selected shards still counts as present.
An unflagged workflow's shard union must equal either the full manifest or exactly
the non-empty selected shards; a packed PR requires only its exact packed union.
A matrix bound to no shard is accepted only as its distinct collapsed matrix
skip: complete, skipped, no runner and no steps. Static literal
matrices remain readable unchanged. The main Cloud router returns `github` with
reason `scoped-ui-selection` for every scoped admission, so a scoped pull request,
including one whose selection has no Apple TV test, never starts a Cloud build.

Scoped successes emit no identical-tree full-UI reuse receipt. Full receipts bind
the area-map hash too, preserving main-push full coverage when area definitions
change. Pull-request producers schedule the bound trusted selection
([scheduling](CI_UI.md#scheduling-the-selection)); full bindings apply to pushes,
nightly, manual and legacy CI-changing runs, and a main push may still skip its matrices
through reuse or nightly deferral.

### Packed scoped UI protocol

The reader recognizes `--pack-scoped-ui` only as one literal flag on the admitted
workflow's `ci_ui_tests.py wait-archive` command. The current producer activates
this flag after the reader landed separately. Historical and
unflagged producers retain the existing full-or-exact-selection compatibility.

Admission reads the area map, synchronized app platform filters and
`scripts/ci-ui-durations.json` from the verified base. The isolated reader executes
only the base `ci_ui_selection.py`, `ci_ui_test_kinds.py` and `ci_ui_packing.py`; candidate scripts and
duration data are never imported or used as selection authority. The map, weights
and project file come only from the base; an approved candidate workflow may
enable the packing protocol for its own run. The deterministic plan
contains exact per-device shard identities, frozen duration hash and predicted
costs, with a canonical SHA-256 over all these fields. The
[selection and packing rules](CI_UI.md#platform-selection-and-capacity-packing)
define its bounded scheduling behavior. Full default-plan partitions remain v2.

For an activated scoped PR the job union must be exactly the nonempty packed
shards, named `scoped-a` through `scoped-f`. All three device declarations remain
mandatory even when one platform has no test. Every executed infrastructure and
device summary must bind `hashes.manifests.ui-scoped-plan` to the admitted hash,
in addition to the existing manifest, default-plan and run/head/tree checks.
Per-job declared, compiled and observed identities must equal its exact plan;
missing, extra, duplicate or cross-device evidence fails closed. Legacy full shard
summaries cannot satisfy a packed selection, even when its union happens to equal
the full population. An excluded platform may produce only the existing complete,
skipped, no-runner/no-steps collapsed matrix record; no archive or device summary
can claim its tests passed. Scoped successes still provide no full reuse receipt.

Every activated PR excludes methods whose method name contains `Screenshot` or
`Acceptance`, including locale methods. Core, unknown and CI-changing PRs retain
all **functional** default-plan methods on every platform. CI-changing evidence
still needs the existing exact-head approval; functional selection cannot waive
that boundary. The host audit rejects methods matching zero or multiple kind rules.
Separate literal iPhone and iPad matrices may bind `iphone_shards` and `ipad_shards`
outputs, so their independently capped counts need not agree. A device output on
another device, or a grouped matrix with differing selected lists, is refused.
Pushes, manual and nightly full runs retain every default-plan method.
Selection/classification/packing errors fail activated PR admission; only unflagged
historical producers retain full-population compatibility on selection errors.
Plan estimates are diagnostic data, not passing samples or duration acceptance.

### Prepared grouped Xcode Cloud reader

The [v2 Cloud evidence contract](XCODE_CLOUD_UI.md#prepared-grouped-evidence-reader-v2)
adds independent iOS (iPhone plus iPad) and tvOS groups to packed functional PR
evaluation. The trusted base registry, exact per-device selection, publisher
pointer/hash, main uploader provenance, retained selection attempt and newest
registered Xcode Cloud App checks all remain mandatory. Each group supplies
complete GitHub evidence or complete API-verified Cloud evidence; partial providers
within one group cannot be combined. Missing Cloud evidence never authorizes
skips. Complete GitHub fallback is evaluated without consuming stale Cloud receipts.
Compiled Cloud identities remain unavailable, and scoped/Cloud PR successes
cannot supply a full identical-tree reuse receipt or daily main history.

The reader additionally recognizes `ci_ui_tests.py select --pack-scoped-ui`,
`wait-group --group ios|tvos` and bounded `needs.selection.outputs` shard matrices.
It accepts one `ui-selection` anchor instead of the legacy `ui-archive`, so later
Cloud groups need not wait for a GitHub gate archive. Independent matrices require
distinct literal name prefixes to authenticate collapsed skips. These are prepared
reader contracts: the registry, commands, pointers and producers are not activated
here. The existing v1 full Apple TV reader remains unchanged in behavior.

The gate reader also supports a Linux `ci_gate.py classify` producer with one
`host` identity, `Gate change classification`, tier `gate-infrastructure`, job
`gate-classification` and null shard. It must succeed and provide an
identity-bound summary like every executed gate job. The producer's classification
output never authorizes a verdict: admission independently derives classification
using the base reader and base allowlist.

On pull requests only, that independent classification may mark the iOS/tvOS
build and unit jobs as **not applicable** when both `app_affected` and
`ci_changing` are false. The literal workflow jobs must still be present in
GitHub's complete job set with conclusion `skipped`; their admitted populations
are reported separately, never counted as executed or passed tests. Missing,
cancelled or failed jobs remain failures. The reader ignores artifacts for those
independently admitted skipped jobs; their bytes are never read. Host checks and classification still require complete
passing evidence. Additional archive proof jobs remain required. Main pushes
and nightly do not acquire this exception. Forks still require exact-head
approval; CI-changing and unknown paths cannot take this path, even with approval.

The `ci-gate` producer's Linux `gate-classification` job keeps host checks on
macOS and skips the four app build/unit jobs when they are not applicable,
retaining one macOS host job for docs-only pull requests. Publication executes
the admitted first parent's verdict reader and independently verifies that
classification before reporting the skipped populations as not applicable.

After publishing a complete PR UI success, the main publisher retains
`ci-ui-verdict-<tree-sha>` for 30 days. Its `verdict.json` version 1 stores the
admitted identity, producer run/attempt, fork/CI-change/approval provenance, exact
manifest/default-plan/policy/registry/classification/workflow/pins hashes, covered
device shards and observed toolchains. This is publisher output, never a producer
claim or a matching artifact name alone. The reuse reader verifies the uploader's
workflow ID/path, event, both repositories, main branch and main-history revision,
then resolves the pushed commit's associated PRs to exactly one same-repository
PR merged into main with `merge_commit_sha` equal to the pushed SHA. The receipt's
PR number and head SHA must match that PR's final head; another green head with
the same tree cannot authorize reuse. It verifies that the upstream UI producer is still its head's newest completed
successful run and exact attempt. A rerun in progress invalidates the receipt.
Unknown versions, missing/expired proof, red/cancelled runs, forks, CI changes,
approval-based verdicts, different trees or inputs, incomplete device coverage,
or observed toolchains that disagree with current pins all mean reuse is unavailable.
Malformed nested receipt fields and corrupt ZIP or compressed data also refuse reuse.
Without explicit trusted deferral intent, unavailable proof means run the UI tier;
skipped shards without proof fail. The [main UI scheduling contract](CI_UI.md#main-ui-scheduling-contract)
additionally recognizes the literal `--defer-main-ui` flag in the admitted base's
archive-selection command. Complete, passed infrastructure records and entirely
unexecuted skipped shards permit a pending "UI deferred to nightly" status when
no trusted identical-tree proof exists. Missing records, invalid provenance and
failed jobs cannot claim this state. A PR or candidate-only flag cannot authorize it.
The publisher repeats this decision before accepting skipped shards. Reuse links
the original successful UI run; deferral links the main nightly workflow.
The publication summary displays the reused producer run/attempt, verdict artifact,
tree and approval/fork/CI-change provenance alongside that link.

Reader changes land in a separate PR before a producer activates new skipping or
deferral behavior. A CI-changing reader PR requires maintainer approval of its
exact head and cannot approve itself.
The [UI producer](CI_UI.md) uses this contract with a Linux archive-selection job
and a literal device/shard matrix whose shard names must match the manifest on
each of iPhone, iPad and Apple TV. Publisher trust and
exact-head approval rules apply to every device. The producer is activated only
after the reuse reader is installed on main.

The bridge calls the admitted base revision's `evaluate_gate`, including per-job
expectations and the complete context population. `ci-pr-gate` includes host,
unit iOS, unit tvOS, both build operations and any supported additional build
proof operations in verified workflow metadata. The required-job union must equal
that population. Before the unit producer ships, valid existing evidence yields
**pending: unit tier not yet produced**, never success. There is no second
publisher implementation of population or gate verdicts.

`ci-ui` is pending for app-affecting changes until that producer is available.
Trusted docs-only classification may display it as not applicable, including an
exact-head-approved docs-only fork; fork/approval labels still apply. Unit/archive
producer changes are independent sibling work; this publisher does not create
or rename their jobs. Fork successes remain explicitly **self-reported**, and
approved CI-changing/fork verdicts are labeled **approval-based**.
Failure Details links identify the authoritative producer run. Publication summaries
retain failing identities, exact attempt exits, counts and missing artifact/identity
diagnostics even after producer failure. Diagnostic parsing errors publish a controlled
infrastructure failure instead of aborting before statuses are written. Admission,
approval and test outcomes remain unchanged. [CI reporting](CI_REPORT.md) keeps daily history and
PR summaries, tracks nightly failures and notifies main-push failures with issue-write.

## Approval and credentials

Fork and CI-changing heads require the maintainer's approval of that exact SHA.
The publisher reserves `ci-approval-request/pr-<number>/<head>` as pending and
marks it successful only after GitHub accepts the dispatch. This context says
bookkeeping, not a test result. A pending receipt with no existing approval run
is retried by a later publication; an accepted dispatch or an existing run prevents
another dispatch for that head. Existing requests for older heads are
cancelled as obsolete. The request run contains two jobs:

1. `wait` has `permissions: {}`, no checkout and no secrets. Its `ci-approval`
   environment supplies GitHub's one-click **Review deployments** action.
2. `record` uses `ci-publisher`, verifies GitHub's environment review history and
   the current head, writes `ci-approved/pr-<number>/<head>` once through the App,
   then dispatches re-evaluation. A stale request cannot grant approval.

Only the approval job and the maintainer-only `ci-approve` fallback write the
immutable approval context. `ci-publish` only reads it, checking the App bot's
identity. It never includes that context in its display writes, so a publisher's
read/approve/write interleaving cannot erase approval. The display context's
Details link and publication summary update immediately when the approval run
is discovered. The reservation also links to that run when visible. After
dispatch, lookup waits at most ten seconds; if GitHub
has not exposed the run yet, the accepted receipt links to the approval workflow
until the next publication can replace it with the run link.

Request reservation and workflow dispatch are two GitHub API operations. If the
job is forcibly interrupted after reservation but before dispatch, a later
publication retries only if no approval run exists. If GitHub accepted the dispatch
before interruption, discovery of its run repairs the pending receipt without
dispatching again. An accepted dispatch whose run is not yet visible retains a
success receipt to prevent duplicate requests. The maintainer uses `ci-approve`
for an expired/rejected approval run. These receipts never grant approval. Agents
must never invoke an approval, approve a deployment, or grant fork/release approval.

The publisher App is generic: its ID comes from `CI_APP_ID`, its slug is read
from authenticated App metadata, and its installation token is scoped to the
current repository with statuses write plus contents/actions/PR read. It has no
workflow-dispatch grant. The workflow's `GITHUB_TOKEN` has actions write solely
for dispatch/cancellation; all commit status writes use the App token.

Before reading the private key, the script checks event, main ref and exact
workflow path. The RSA PEM key reaches OpenSSL only through an inherited pipe;
it is never written to disk, printed or uploaded. JWT/installation tokens are
never printed or uploaded, and tokens are revoked on normal exit. Artifact redirects drop
authorization before following storage URLs. Errors do not echo API response
bodies or subprocess output. No production config/server is accessed.

The already provisioned environments admit only main: `ci-publisher` has
`CI_APP_PRIVATE_KEY` and `CI_APP_ID`, `ci-approval` has the maintainer reviewer and
no secrets, and `release` is unused here. Creating or changing Apps, environments,
secrets or branch policies remains maintainer-gated.

## Commands

With a read-only GitHub token available as `GH_TOKEN`, compute a PR's current
statuses without writing, minting an App token, dispatching or cancelling:

```bash
python3 -B scripts/ci_publish.py dry-run --repository OWNER/REPOSITORY \
  --pr PR_NUMBER --app-login 'APP-SLUG[bot]'
```

Before the trusted workflow exists on main this correctly shows pending
admissions. The App login is an explicit dry-run input; production derives it
from the authenticated App. Do not paste token values into a command.

The maintainer may dispatch `ci-publish` on main with `pull_request` or
`pushed_sha` (exactly one). The maintainer-only fallback `ci-approve` takes
`pull_request` and `head_sha`. Ordinary contributors cannot use these commands
to approve themselves. For organization-owned repositories, reviewer identity
support must be extended explicitly; this repository's maintainer is its owner.

Local security/transition checks:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_ci_publish.py'
python3 -B scripts/check_workflow_policy.py
scripts/check_all.sh --with-unit-tests --ios-destination '<assigned-ios>' \
  --tvos-destination '<assigned-tvos>' --output-dir '<fresh-outside-repo>'
```

Tests use reduced recorded GitHub payload shapes, with repository names/IDs/SHAs
normalized. They guard admission/rerun preservation, stored derived inputs,
matching, push identity, state selection, stale heads, fork approval, immutable
record races, request deduplication, reviewer authentication, retained attempt
evidence, dry-run non-mutation and credential/redirect boundaries.

Real workflow-run execution begins only after this workflow is merged to the
default branch. This bootstrap PR is **Part of #89**, and does not close that
ticket. The PR carries the exact post-merge scenario checklist, including delayed
approval after main advances. A real fork exercise uses the maintainer-provided
secondary account under coordinator control; fixtures do not replace
that acceptance. Credential denial by environment protection is also a real-run
acceptance requirement, separate from the script guard tests.

GitHub's [workflow-run API](https://docs.github.com/en/rest/actions/workflow-runs)
documents environment review history; [rerun behavior](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)
preserves the original SHA/ref. [Static population and verdict policy](CI_POPULATION.md)
and [the summary contract](CI_SUMMARY.md) define the evidence checks.
