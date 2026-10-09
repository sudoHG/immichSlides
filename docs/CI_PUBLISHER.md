# Trusted CI publication and approval

`ci-publish` writes informational commit statuses `ci-pr-gate`, `ci-ui` and
`ci-approval-state`. Requiring a context or changing a ruleset is a separate
maintainer decision. It reacts to `ci-gate` and `ci-ui` workflow-run events
(`requested`, `in_progress`, `completed`) and supports main-only manual
re-evaluation. A manual re-evaluation runs no build or test.

## Trust and identities

The workflow checks out `main` only, with full history in publication and admission
so a base remains readable after main advances. Every publisher and approval job
runs on `ubuntu-24.04`. `setup_ci_publisher_python.py` installs only the central
`pip` and `PyYAML` pins in a new isolated environment; it does not require Xcode,
the macOS Python pin, Pillow or zstd. It verifies producer workflow **ID and path**,
repository, event and current PR mapping through GitHub. Forks with empty
`pull_requests` arrays are mapped through GitHub's commit-to-PR API and the head
repository. Workflow names and colliding job names do not establish provenance.

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
including an empty shard after a class rename/removal, are recorded for either
rule selection and fail only `ci-ui`; the gate admission still completes. The
base's filtered source population remains available for an approved replacement
manifest to account for removed tests. Only the fixed empty-shard and missing-base-workflow
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
only after independently finding a complete trusted identical-tree PR verdict.
The archive-selection job must still succeed and supply its identity-bound,
manifest-bound summary; skipping that job or only part of the device matrix fails.
GitHub may report a whole skipped matrix as one unexpanded job name. The reader
maps that exact trusted-workflow name to its declared literal shards while
retaining the real job's identity and attempt. Each attempt is normalized before
execution history is merged by logical shard, so a rerun may switch between
skipping and executing the matrix. Overlapping shards within one attempt,
unknown names or an incomplete final job set fail. This mapping supplies no test
observations and still requires independent trusted reuse proof.
Every ordinary run retains the existing successful-job and complete-population checks.

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
or observed toolchains that disagree with current pins all mean run the UI tier.
Malformed nested receipt fields and corrupt ZIP or compressed data also fall
back to running UI.
The publisher repeats this decision before accepting skipped shards and links
the status to the original successful UI run.
The publication summary displays the reused producer run/attempt, verdict artifact,
tree and approval/fork/CI-change provenance alongside that link.

This reader lands before a producer starts skipping shards. Existing iPhone
producers keep running normally; the separate iPad/Apple TV and reuse producer
rollout activates the new path after the reader is on main. A CI-changing reader
PR still requires maintainer approval of its exact head and cannot approve itself.
The [iPhone UI producer](CI_UI.md) uses this contract with a Linux archive-selection
job and three literal iPhone shards. iPad and Apple TV producer rollout remains
separate; publisher trust and exact-head approval rules apply to every device.

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
