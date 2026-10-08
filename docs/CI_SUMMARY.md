# Host checks and producer summary contract

Run the same macOS host checks as `ci-gate` from the repository root:

```bash
"${PYTHON:-python3}" -B scripts/run_host_checks.py --output-dir /tmp/immichslides-host-run
"${PYTHON:-python3}" scripts/ci_summary.py /tmp/immichslides-host-run/summary.json
"${PYTHON:-python3}" scripts/ci_summary.py --identity /tmp/immichslides-host-run/run-identity.json
```

Prerequisites and interpreter setup are described in
[CONTRIBUTING](../CONTRIBUTING.md#setup). `check_all.sh` selects `"${PYTHON:-python3}"`
for every Python step; the host entry point keeps its invoking interpreter for every
child check. An active venv or pyenv is honored when `PYTHON` is unset.
The output directory must be outside the repository
and contain no previous result files. Without `--output-dir`, a new temporary directory
is printed. Remove local outputs after reading the result.

The entry point owns the format, test-convention, release-guard, localization-catalog,
localization-usage, required-tool, workflow-policy, known-flaky-registry and Python checks. `check_all.sh` delegates to it and
keeps its optional iOS/tvOS unit-test interface. With `--output-dir`, it keeps records
in `DIR/host-records` and optional unit bundles in `DIR`; use a fresh output directory
whose `host-records` does not already exist. This option also works without unit tests.
Without it, temporary host records are removed on exit and their path is not printed.
Every run ends with each host outcome and all nonpassing Python identities and reasons,
including after optional unit tests. DerivedData remains in `.derivedData/check-all-{ios,tvos}`.
Checks continue after failures. Exit 0 means commands and coverage succeeded, or the
only coverage exception matches the policy's **proposed** expected-skip list. That last
case remains `unverified` with `policy-proposed` evidence until maintainer approval;
it never counts as a passing gate. Approved matching skips allow `passed`; an
unexpected skip, a registered skip that runs, a missing compiled or executed identity,
or an unapproved deselection fails. The [expected-population and policy model](CI_POPULATION.md)
defines exception accounting.
Exit 1 means failed coverage, a failed command, expected failure, missing result,
empty Python suite or infrastructure problem; invalid arguments
exit 2. `--timeout-seconds` sets the total
host budget (default 900, maximum 1200), not a product timing threshold. A timeout
stops the child process group and records remaining checks as `not-run`.
An interruption records remaining checks as `not-run` with "not run after interruption".
If final record validation fails after the initial placeholder is written, the producer
rewrites a `failed` record with `record-invalid` infrastructure evidence and retains
individually valid, unique observations. Invalid entries cannot become passing coverage.
Persistent filesystem failures return exit 1 and report that recovery could not write.

Host checks do not compile the app, read private configuration or receive ambient
Immich/test-runner configuration. They run the intended working files directly.
Local dirty runs record the HEAD commit and tree with `dirty: true`; that tree is
explicitly not proof of the changed working files. Snapshot builds belong to the
separate build entry point.
Metadata helpers remain importable by source-free archive tooling without the
population/verdict libraries. The host producer loads those libraries after
writing its interruption placeholder; archive consumers do not run host checks.
Without `--workflow-path`, the entry point always records a local identity, even
inside GitHub Actions. Only that explicit flag enables CI identity and the associated
GitHub event, workflow and run metadata. `check_all.sh` does not enable CI identity.

## Version 1

[`scripts/ci_summary.py`](../scripts/ci_summary.py) is the authoritative, executable
schema and validator. All fields below are required; unknown fields and versions,
duplicate JSON keys and identities, booleans used as integers, non-finite durations,
malformed hashes, and incomplete strict identities are rejected. This validates
producer data, not its provenance or a trusted verdict.

| Field | Type and meaning |
| --- | --- |
| `schema_version` | Integer `1` |
| `identity` | Independently versioned run identity, described below |
| `source` | `repository`, `workflow_path`, `event`, `fork_originated`, `ci_changing` |
| `run` | `id` (string or local null), positive integer `attempt`, strings `tier` and `job`, string or null `shard` |
| `hashes` | `manifests` and `policies`, each a map of logical names to lowercase SHA-256 hashes |
| `toolchain` | `versions` (nonempty name-to-version map; unavailable versions are null), `signing_mode` |
| `population` | `declared`, `compiled`, `observed`, `deselected`, `removed_by_pr` arrays |
| `infrastructure` | Version 1 array of `{code, message}` diagnostics, never silently omitted; codes distinguish coverage, policy and population diagnostics from infrastructure outcomes |
| `status` | Producer execution status: `passed`, `failed`, `unverified` |

Source repository/event must match the identity. CI requires a workflow path below
`.github/workflows/`, a run ID and a boolean fork-origin flag. The producer derives
the path from `GITHUB_WORKFLOW_REF` and cross-checks the explicitly required `--workflow-path`.
A deleted PR head repository is conservatively recorded as fork-originated.
Classification is not
implemented by the host producer: `ci_changing: null` means **unclassified**, never
"not CI-changing". A future trusted consumer must derive classification itself;
it must never admit an unclassified run as non-CI-changing. Local workflow path and
run ID are null. No approval is claimed by a producer: publisher verdicts separately
record source and whether they rest on approval.

Host checks hash the exact bytes of `scripts/check_workflow_policy.py` as
`policies.workflow-policy` and `scripts/ci-test-policy.json` as `policies.test-policy`.
CI also records the setup manifest `scripts/ci-pins.json`
as `manifests.ci-pins`; local runs do not claim to consume its setup pins.

Coverage discrepancies use `coverage-failed`, readable test keys and a failed
status, while malformed static populations/policies use `population-invalid`.
Markdown labels `coverage-failed` as `Coverage`, `policy-proposed` as `Policy`, and
`population-invalid` as `Population`; infrastructure health counts must exclude
all three codes, as defined by `NON_INFRASTRUCTURE_DIAGNOSTICS` in `ci_summary.py`.
Other diagnostics retain the `Infrastructure` label. Skipped observations keep their exact reason, and absent
execution is reported without adding fictitious observed rows.
Later producers hash the exact bytes of each additional manifest/policy they consume. Versions
record actual tools, not a claim that pins were verified. Host signing is
`not-applicable`; test-build producers use `sign-to-run-locally`.

### Identity record

`run-identity.json` is identical to the summary's `identity` object. Every variant
has `schema_version: 1`, `event`, `repository` (`owner/name`, or local null when
origin is absent or cannot be interpreted), and lowercase Git
`tree_sha`. Version 1 Git object IDs are 40 lowercase hex characters.

| Event | Additional required fields |
| --- | --- |
| `pull_request` | Positive integer `pull_request`, `merge_sha`, `base_sha`, `head_sha` |
| `push` | `ref` equal to `refs/heads/main`, `pushed_sha` |
| `workflow_dispatch` | `ref` under `refs/heads/` or `refs/tags/`, `commit_sha` |
| `local` | `commit_sha`, boolean `dirty` |

For a PR, the producer requires checkout HEAD to equal `GITHUB_SHA` and reads exactly
two parents from that commit: first parent is base, second parent is head. It never
substitutes the trigger payload's base/head claims. The tree comes from that merge
commit. A push requires HEAD to equal `GITHUB_SHA` and the main ref. A manual dispatch
requires HEAD to equal `GITHUB_SHA` and records the selected branch or tag's full
`GITHUB_REF`; it does not claim to be a PR merge or a main push. A later trusted
publisher compares these claims with its own admission record/API observations.

### Population and observations

Each identity is `{kind, key, dimensions}`. `kind` is `host`, `python`, `swift`, `ui`
or `strict`; `key` is a nonempty function/check identifier. `dimensions` is a map of
nonempty strings, limited to `device`, `configuration`, `suite`, `scenario`, `fixture`,
`platform`, and `parameter`. Strict identities require exactly the first five,
so two scenarios or fixtures cannot collapse into one result. Python IDs use
`unittest`'s complete module/class/method identity, including inherited mixin tests.
Identity equality uses the entire object, independent of JSON key order.

`declared` and `compiled` contain identities. Host declaration/compilation records
the eight check definitions; Python declaration uses the AST and follows mixins,
while `compiled` records dynamic unittest discovery. These are separate inputs to
the population comparison. The [static library](CI_POPULATION.md) also enumerates
Swift unit and UI tests from supplied source text without candidate imports.
The [unit archive consumer](CI_UNIT_TESTS.md) binds declarations from the selected
Git tree before removing its checkout; the publisher independently derives that set.
`removed_by_pr` contains identities for reporting only; host checks leave it empty.

An observed entry contains `identity`, `outcome`, `duration_seconds` and a nonempty
`attempts` array. An attempt contains consecutive positive `number`, `outcome`,
nonnegative finite `duration_seconds`, integer or null `exit_code`, string or null
`reason` and `message`. Total duration accounts for every attempt.

Outcomes are `passed`, `failed`, `skipped`, `crashed`, `timed-out`, `not-run`,
`needs-human-review`, or aggregate `flaky-passed`. A skip requires a reason.
`flaky-passed` requires exactly two attempts, failed then passed; the host runner
never retries. A failed retry retains all attempts and a nonpassing final attempt;
other entries have one matching attempt. Parameterized producers
can use the optional `parameter` dimension for per-parameter evidence. Swift unit
coverage maps official Xcode keys to static function keys and checks compilation
at the parent function, retaining original argument identities and failures.
Subtest failures in Python fail the
parent identity and retain each failing subtest's parameter identity and failure
message. Every subtest skip retains its parameter identity and reason in
the parent's attempt reason. When both occur, JSON and Markdown retain both the
skip reasons and failure messages. A `setUpClass` or `setUpModule` `SkipTest` records
every discovered member of that class or module as `skipped` with the fixture's
reason, without a synthetic setup test identity. Cleanup skips retain a fixture-level
identity such as `tearDownClass (module.Class)` or `tearDownModule (module)` and the
reason; already executed member outcomes remain intact, and the summary is unverified.
Fixture errors, including repeated cleanup errors reported under the same fixture name,
merge into one failed observation retaining every message. A setup error leaves its
unexecuted members `not-run`. Error details retain the first line, capped at 200 characters.
Expected failures and unexpected successes return
exit 1 and do not count as passes.

Each deselection is `{identity, reason, owning_tier}` with nonempty reason and owner.
The validator checks structure, not whether a skip/deselection is approved or whether
populations are complete. Producer status is not a replacement for the later trusted
evaluator. That evaluator must fail closed on missing populations, unexpected skips,
failed/cancelled jobs, absent artifacts and other incomplete evidence.

### Reader-first evolution

Summary and identity versions are independent. Readers dispatch only to explicitly
installed validators in `SUMMARY_READERS`/`IDENTITY_READERS`; version 1 is currently
the only supported version. A successor parser and validator must land in the
trusted reader first, alongside the old parser and supported workflow paths. Only
then can producers emit the successor. A version number alone never enables parsing.

## Current workflow boundary

`ci-gate` runs this host job on PR merge commits and pushes to main. It has read-only
contents permission, bounded job/script budgets, PR-specific cancellation, and no
secrets or status-writing identity. It uploads only `summary.json`, `summary.md` and
`run-identity.json`, with run/attempt-specific names, retained 30 days for PRs and
7 days for pushes. Successful Python and Swift identities are kept in JSON; the short
Markdown shows every host check and all nonpassing Python/Swift identities. Unit failure
rows retain the first official failure-message line, capped at 200 characters, including
parameter outcomes. Plain assertion failures fail the producer without being relabeled
as infrastructure failures.

This job is informational and does not configure required statuses. The workflow also
produces [secret-free build archives](CI_BUILD_ARCHIVE.md) and independent
[complete iOS/tvOS unit consumers](CI_UNIT_TESTS.md), each depending only on its own
platform's build. Unit artifacts and step summaries require the independent always-run
scan, including early-stage failures. Missing records and refused publication each
emit a distinct fixed message, and cleanup runs separately. Unit verdicts use the
offline runner's official overall-result classification and the
`policy-proposed` diagnostic for unapproved unit skips, labeled `Policy` and excluded
from infrastructure health accounting.
Static population, skip/deselection
policy and the verdict evaluator are libraries. Unit consumers apply their recorded
per-tier policy approval to exact hermetic skips; host approval never activates
unit or UI exceptions. Trusted publication and approval
enforcement are separate from producer claims. The workflow consumes the merged
[pins and isolated environment setup](CI_TOOLCHAIN.md) and runs its standalone
workflow-policy check as a distinct host identity. CI sets `PYTHON` to the pinned
venv made from `/usr/bin/python3` and uses it
for the host entry point and validators. Contributor interpreter setup is described in
[CONTRIBUTING](../CONTRIBUTING.md#setup).

The generic identity schema also supports `workflow_dispatch`. Under the `ci-gate`
consumer policy, readers must accept only `pull_request` and `push` events from its expected workflow. A structurally
valid manual-dispatch record is not admissible as a `ci-gate` result.
