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
when present, come from the same base; older bases without it remain supported.
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
Details link points to the existing approval run. The reservation also links to
that run when visible. After dispatch, lookup waits at most ten seconds; if GitHub
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
