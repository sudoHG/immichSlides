# Host checks and producer summary contract

[CI reporting and failure tracking](CI_REPORT.md) describes retained daily rollups,
main/nightly reports and notifications built from these records and trusted admissions.
PR producers retain their own per-run summaries.

Run the complete local host checks from the repository root:

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
The workflow-policy host check also validates [UI shard assignments](CI_UI.md)
against the unfiltered iOS/tvOS population union.
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
The hosted Linux partition explicitly uses 1200 seconds inside its 25-minute job;
the macOS partition and local default retain 900 seconds.

The shared host/strict group probe on macOS uses `ps -g <group> -o pgid=,stat=`
to select the runner's process group instead of inspecting every simulator process.
Its existing five-second deadline remains unchanged. Empty stdout/stderr with exit 1
means the selected group is absent; other errors and timeouts propagate. Zombie-only
groups are stopped, while live descendants still require termination. Other platforms
retain the full-system query. The existing descendant/pipe-EOF regressions cover this
guarantee, and targeted-query/error regressions live in `test_ci_summary.py`.
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
schema and validator. All top-level fields below are required; the prepared archive
download receipt, bounded diagnostics below and the paired failure diagnostics and strict validator receipt
on observations and attempts are explicitly optional. Other unknown fields and versions,
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

### Bounded infrastructure diagnostics

The optional `bounded_diagnostics` object is measurement evidence only. Historical
field-free records remain valid, and population, status, timeout and retry rules
are unchanged. Producers use the reader contract merged before activation,
following [reader-first evolution](#reader-first-evolution). The isolated trusted
reader carries `ci_bounded_diagnostics.py`; source-free unit tools also carry the
separate `ci_execution_diagnostics.py` producer.

The object has exactly `schema_version: 1`, `collection_seconds`, boolean
`truncated`, and `events` (at most 512 entries). `collection_seconds` contains
exactly `preparation`, `xcode` and `fixture`: finite nonnegative diagnostic
collection seconds up to a sanity cap of 86,400, or null when unavailable.
The approved job collection budgets remain 5, 10 and 2 seconds respectively;
Markdown marks measured values above those budgets as `over budget` and nulls
as `unavailable`. Budget enforcement belongs to the producers and their
mocked-clock tests; an overrun or missing measurement must not discard a summary.
`truncated` means collection or retention stopped at a cap; absent measurements
remain unavailable and never prove health. Readers validate shape and bounds,
not that a producer actually enforced its collection deadlines.

Every event has exactly these fields:

| Field | Meaning |
| --- | --- |
| `scope` | `preparation`, `xcode` or `fixture` |
| `phase` | Preparation: `simulator-preparation`, `simulator-readiness`, `simulator-boot`, `simulator-bootstatus`, `simulator-container`; Xcode: `unknown`, `xcodebuild`, `build`, `test-launch`, `test-execution`, `official-export`; fixture: `import`, `fixture-build`, `image-generation`, `fixture-generation`, `manifest`, `bind`, `ready-write` |
| `state` | `started`, `completed`, `spawn-started`, `spawn-completed`, `communicate-started`, `timeout`, `kill-started`, `kill-completed`, `reap-started`, `reap-completed`, `before-kill`, `after-reap` |
| `sequence` | Nonnegative integer invocation identifier, at most 2^31 - 1; event times share that invocation's start |
| `elapsed_seconds` | Finite nonnegative offset from invocation start, at most 86,400; permits evidence of deadline overruns |
| `cpu_seconds` | Finite nonnegative CPU time, at most 10^12, or null |
| `sample` | Null or the fixed statistics object below |
| `input_sha256` | Null or a lowercase SHA-256 of deterministic public fixture inputs, allowed only in fixture scope on `image-generation` or `fixture-generation`; never hash private inputs |
| `official_exports` | Null or exactly boolean `bundle`, `summary`, `tests`, allowed only for Xcode scope; existence is not proof of a complete or passing export |

Statistics contain exactly `cpu_percent` (0–100 or null), `memory_free_bytes`
(integer 0–2^50 or null), `load_average` (three finite numbers 0–10^6 or null),
`runner_hosted` (boolean or null), `image_version` (three integers 0–2^31 - 1 or
null), and `processes` (at most 64 entries). Image versions contain only numeric
version components, never raw environment values. Each process entry has exactly
`name`, `state`, `count` (integer 1–65,536), `cpu_percent` (0–10^6 or null,
aggregated across matching processes), and `rss_bytes` (integer 0–2^50 or null).
Names are limited to `simctl`, `CoreSimulatorService`, `Simulator`, `launchd_sim`,
`xcodebuild`, `xctest`, `testmanagerd`, `immichSlides`,
`immichSlidesUITests-Runner`, and `swift-frontend`. States are `running`,
`sleeping`, `uninterruptible`, `stopped`, `zombie`, or `unknown`.

Unknown keys, free text, command arguments, paths, environment and server data
are refused. The JSON publication scanner validates nested receipts and rejects
duplicate keys in a document containing this field. Summary Markdown displays
collection costs, event count, truncation and the last retained phase per scope; detailed
measurements stay in the summary JSON. Trusted report failure/missing counts and
issue decisions do not consume the measurements.

Successful phases retain only started/completed events. At 512 events the oldest
success is evicted first; incoming anomalies replace older anomalies only when
no successes remain. Thus the latest timeout and export observations survive a
full receipt. A truncated receipt is attached even when it contains no events.
Preparation uses the same `subprocess.run` as ordinary execution: its internal
spawn/communicate/kill boundaries are unobserved, and timeout/reap observations
are taken after the call has killed, waited and closed its pipes. Start samples
run before the preparation deadline starts; anomaly samples run after failure
is decided, with no sampling inside the readiness retry loop. Successful runs
discard their buffered start sample. Preparation `cpu_seconds` measures the
runner's own process time, including diagnostic threads, not simctl CPU time.
The nightly preparation step hands the same compact
receipt to the tracer even with `--preparation-failed`. Serial strict children
share the job ledger: each reserves its remaining collection allowance before
starting, then returns unused allowance after completion. Missing or invalid
accounting disables further collection instead of granting another budget.
The internal ledger stores the public receipt and remaining numeric allowances;
allowances are distinct from observed `collection_seconds`. A lost child's
collection measurements remain null rather than treating its reservation as an
observation. Only the validated public receipt is attached to summaries.
Fixture children receive a reserved emission allowance of at most 0.2 s; the
parent harvests only validated fixture events from a separate file of at most
512 KiB, passed through the child's environment. Emission defaults to disabled
when no reader grants an allowance. The original `fixture-startup:` stdout and
its 4096-byte reader window are unchanged. Import is visible before other service
imports run. PNG and cache-miss fixture
generation carry hashes of public generation arguments; these input digests are
distinct from `hashes.manifests.fixture-c`, the generated manifest digest, and
are not independently bound to that manifest by the reader. Cached deepcopies
and nested fixture-set generation do not create duplicate generation envelopes.

Every process sample has a 0.25 s cap, with 0.08 s subprocess deadlines; receipt
IO and public Xcode progress reads have 0.1 s caps, and fixture log reads have a
0.25 s cap. Capped daemon workers prevent a stuck diagnostic from blocking the
runner. Retention and cumulative collection budgets stop additional work and
mark truncation. Fixture writes run on a single daemon outside the ready path;
each write has a 10 ms CPU allowance and no synchronous ready-path IO wait.
The only drain wait is capped at 10 ms after service exit or failure is
decided; sealing the writer before health serving never waits. A blocked file
writer cannot hold up ready or process exit. Fixture
collection accounting includes emitter bookkeeping/IO CPU time and conservatively
reserves the final write allowance and drain wait before reporting its footer;
overlapped scheduler waits are not added job latency. Enqueueing and public input
hashing leave small CPU bookkeeping costs on the existing startup path; the
0.2 s child allowance is charged in full before spawn. Out-of-range measurements become null (or zero for a required
elapsed offset), and receipts are validated before attachment; invalid receipts
are dropped without changing the verdict. Xcode timeout observations follow
stdlib cleanup; they do not claim a pre-kill sample. They retain allowlisted
process statistics, the last
recognized public phase, and official-export existence booleans. Existing bundle
export, retention and privacy rules still apply. Ready is written at the existing
point after generation and bind; health and the 60 s deadline remain authoritative.

The approved per-job ceilings apply across repeated preparations and services.
Both the 25 strict jobs and 18 fixture UI jobs use the shared producers: at most
43 × 5 s = 3.59 machine minutes/night for preparation and 43 × 2 s = 1.44 for
fixture startup. Xcode diagnostics add at most 10 s (0.167 machine minutes) per
failed strict job. With one such failed job, the combined ceiling is 5.19 machine
minutes/night and 2.74 minutes wall time at two jobs per matrix (13 strict waves
and nine UI waves, conservatively summed). These are ceilings and ideal parallel
estimates, not hosted measurements or billing. Existing readiness, Xcode and
service deadlines remain unchanged.

PR CI uses the same ceilings. For a six-shard functional `ci-ui` selection,
6 × (5 + 2) s = 0.70 machine minutes/push; two `ci-strict-tracer` jobs add
2 × (5 + 2) s = 0.234 machine minutes, plus 0.167 per failed strict job.
With one failure the combined ceiling is 1.10 machine minutes/push. Two serial
UI shards per device add at most 14 s wall time; the parallel strict jobs add
at most 17 s with one failure, or 0.284 minutes of combined critical-path
overhead when the tiers overlap. Selection/Cloud waits run no producers. Actual
packing, runner queues and approval waits determine the full workflow wall time;
these figures describe diagnostic overhead, not total CI duration.

### Prepared strict identity failure receipt

The reader accepts `identity-failure.json` in a separate artifact named
`nightly-identity-<shard>-<run>-<attempt>`. It is an untrusted failure diagnostic,
not a summary or source identity. Its exact version 1 fields are:

| Field | Meaning |
| --- | --- |
| `schema_version` | Integer `1` |
| `run` | Exactly string `id` and integer `attempt`, matching the current attempt |
| `job` | Literal `nightly-strict` |
| `shard` | The scheduled strict shard ID |
| `phase` | Literal `identity-collection` |
| `reason` | Literal `identity-collection-failed` |
| `declared` | Exactly the scheduling record's ordered strict case identities |

Unknown fields, paths, environment SHAs and command output are not accepted.
The reporter independently binds the scheduling artifact to the GitHub run,
aggregate identity, tested tree, matrix digest and exact scheduled shards. Only
cases still missing from that attempt receive the reason; the receipt never
contributes compiled or executed evidence, and cannot establish an explicit pass
or close an issue. Invalid, duplicate, expired or foreign-attempt receipts leave
the ordinary missing-evidence failure intact. Following the reader-first merge,
the nightly tracer emits this standalone receipt only when source identity
collection or validation raises an exception, preserving that failure. This
includes Git failures, checkout/`GITHUB_SHA` mismatches and unsupported events;
cancellation signals do not produce the receipt. Preparation-failure accounting
also excludes it, as described in [the nightly guide](CI_NIGHTLY.md#early-failure-diagnostics).
It writes no receipt after successful identity collection; the failure path skips
review export and the records artifact
upload. The selected versioned matrix supplies the declared cases, while the
reporter independently verifies their scheduling binding.

### Prepared archive download receipt

The optional top-level `archive_download` object is accepted only on version 1
nightly UI shard summaries (`ui-iphone`, `ui-ipad`, `ui-appletv`, tier `ui`, a nonempty
shard, and `schedule` or `workflow_dispatch` from `ci-nightly.yml`). Historical
field-free records remain valid. The nightly consumer emits it after the archive
download; reader support reached main before this producer was enabled.

The receipt has exactly these fields; unknown fields and free-text reasons are rejected.

| Field | Meaning |
| --- | --- |
| `schema_version` | Integer `1` |
| `artifact_id` | Integer immutable artifact ID from 1 through 2^63 - 1 (signed 64-bit diagnostic ceiling); not independent proof of API provenance |
| `action_outcome` | `success`, `failure`, `cancelled`, or `skipped` |
| `member_bytes` | Exactly `manifest.json` and `build.tar.gz`, each an integer byte count from 0 through the existing 128 MiB UI download cap, or null |
| `digests_matched` | Exactly `manifest` and `tar`, each boolean or null (not reached) |
| `size_matched` | Boolean or null; every manifest-declared tar member size matches (the manifest has no compressed total size) |
| `transfer_extract_seconds` | Finite elapsed action time from 0 through 6600 seconds (the 110-minute UI job cap), or null when unavailable; transfer and extraction are combined |
| `gate_seconds` | Finite elapsed validation/publication time from 0 through 6600 seconds, or null when unavailable |
| `free_disk_bytes` | Integer available bytes from 0 through 1 PiB (2^50 bytes), or null when unavailable |
| `failure_reason` | Null for a successful gate, otherwise one of the closed-set codes below |

Failure codes are `archive-member-missing`, `archive-member-extra`,
`archive-size-mismatch`, `archive-hash-mismatch`, `archive-identity-mismatch`,
`archive-toolchain-mismatch`, `archive-manifest-invalid`, `archive-download-incomplete`,
`archive-gate-timeout`, and `archive-publish-failed`. A failed receipt requires
`status: failed`, a matching infrastructure code, no compiled tests, and only
`not-run` test attempts (or no observations). It cannot count as a product failure
or evidence of test execution. A successful receipt requires action success,
positive member sizes and all three integrity checks true. Timing and disk
measurements may be null even on success, so unavailable diagnostics cannot prevent
writing an otherwise valid summary. Failure receipt measurements are diagnostics;
the reader validates their types and bounds but does not cross-check them against
the reason. The enclosing summary already provides run/attempt coordinates;
observed archive coordinate mismatches use `archive-identity-mismatch`, without
duplicating those coordinates in the receipt. It does not excuse any later test
or infrastructure failure. Summary Markdown displays the compact measurements
and reason; null measurements display as `unavailable`. An invalid shard summary
can make the trusted reporter drop the whole nightly attempt, rather than only that shard.

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
| `schedule` | `ref` equal to `refs/heads/main`, `commit_sha` |
| `local` | `commit_sha`, boolean `dirty` |

For a PR, the producer requires checkout HEAD to equal `GITHUB_SHA` and reads exactly
two parents from that commit: first parent is base, second parent is head. It never
substitutes the trigger payload's base/head claims. The tree comes from that merge
commit. A push requires HEAD to equal `GITHUB_SHA` and the main ref. A manual dispatch
requires HEAD to equal `GITHUB_SHA` and records the selected branch or tag's full
`GITHUB_REF`; a schedule records its exact SHA and main ref. Neither claims to be
a PR merge or a main push. A later trusted
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

| Optional observation / attempt field | Type and meaning |
| --- | --- |
| `failure_phase` | String from the fixed [public failure diagnostics](CI_STRICT_RUNNER.md#public-failure-diagnostics) allowlist; paired with `failure_class` |
| `failure_class` | String from the same contract's fixed class allowlist; paired with `failure_phase` |
| `validator_failure_message` | Optional bounded public text on failed strict observations/attempts; see [public validator failure receipts](CI_STRICT_RUNNER.md#public-validator-failure-receipts) |

The paired `failure_phase` and `failure_class` enums are optional in both summary versions 1 and 2. When either is
present on an observation or attempt, both must be present and allowlisted strings;
free text, unpaired fields and all other unknown fields remain invalid. Historical
records without the pair remain valid. Strict/UI producers label failed methods,
use `unknown` for unavailable or ambiguous diagnostics, and retain the first
failure's labels on an observation after a listed retry passes. The enums do not
participate in outcome, population, retry or verdict evaluation.

The strict tracer emits the optional `validator_failure_message` field for failed
cases with an explicit failing validator receipt, on both the observation and attempt.
Readers accept at most 512 characters from the
reviewed public validator grammar, or the fixed `unresolved` / `[redacted validator failure]`
markers. It is independent of the XCTest diagnostic pair. Historical field-free
records remain valid. Refused values are never echoed in validation errors;
the sensitive-output scanner checks this field recursively, including duplicate keys
and malformed JSON, only where invoked. **`records/` is uploaded unscanned.** The
producer contract requires writing only `public_validator_failure_message(...)`
output to trace and summary, never raw errors. An invalid summary value invalidates
the whole shard. The reporter has one optional-trace trust boundary; its redaction
retains the failed case and exit code but cannot protect an already uploaded artifact.
The [strict receipt contract](CI_STRICT_RUNNER.md#public-validator-failure-receipts)
defines the producer privacy regression and the optional upload-scan follow-up.

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
installed validators in `SUMMARY_READERS`/`IDENTITY_READERS`. Identity version 1 and
summary versions 1 and 2 are supported. Existing producers still emit version 1;
version 2 is activated only for eligible scoped PR UI producers below.
A successor parser and validator must land in the
trusted reader first, alongside the old parser and supported workflow paths. Only
then can producers emit the successor. A version number alone never enables parsing.
The same rule applies to optional field extensions: an older trusted base reader
still rejects the failure diagnostic pair. If reader and producer changes ship
together, a PR or descendant branch whose `base_sha` predates the reader can have
its entire record refused when a failed or `flaky-passed` UI observation contains
the new fields. This transition risk must be stated in the PR; acceptance of the
fields requires the updated reader in the trusted base.

The validator receipt rollout uses two PRs: first install reader/scanner/report
acceptance without changing producer output, then, only after that reader is on
main, activate the strict producer. A stacked producer PR opened before the first
PR reaches main still uses the old trusted base and is not a safe substitute.

## Prepared version 2: scoped official discovery

Version 2 keeps every version 1 field and adds `compiled_evidence`, validated by
[`ci_ui_discovery.py`](../scripts/ci_ui_discovery.py). It is supported only for
pull-request `ci-ui` jobs named `ui-<device>` with `scoped-a` through `scoped-f`.
The admitted shard command must explicitly opt in with
`--compiled-from-official-results`; an opted-in packed functional shard without an
approved base fixture deselection must supply version 2. A deselection matching the
admitted population retains version 1 enumeration; every other shard retains version 1.
The producer now uses the same eligibility helper and skips preliminary enumeration
only on eligible scoped PR shards; other paths retain version 1 enumeration.

The evidence contains `schema_version: 1`, mode `official-result-discovery-v1`,
the exact summary `identity` and `run` including attempt, `plan_sha256`,
`device_id`, the raw first invocation `first_exit_code`, and `official_tests` from
Xcode's `test-results tests` export. `hashes.manifests.ui-discovery` hashes the
canonical complete evidence; `plan_sha256` equals `ui-scoped-plan`. The export is
bounded to 1 MiB, 8,192 JSON values and depth 32. Its one recorded simulator must
match the destination ID and device platform/model.

The reader independently walks official `immichSlidesUITests` case nodes to derive
the discovered population. For complete evidence, declared, discovered, compiled and observed identities
must be exactly equal, with no duplicate, missing or extra method and no tier
deselection. Official results and durations must match each observation's first
attempt; raw nonzero exits remain failures. Existing approved retry accounting
still retains that first failure. Absent, malformed or incomplete exports fail
closed. This proof cannot cover a deselected method or a nightly/full partition.

An incomplete first invocation has a fail-only shape when `first_exit_code` is
nonzero and `status` is `failed`: discovered is a strict subset of declared,
compiled equals discovered, and observed still records every declared identity.
Undiscovered identities have one `not-run` or `timed-out` attempt retaining that
raw exit; discovered cases retain their official results and durations. An absent
export is represented by `official_tests: null`. The fixture's final writer retains
these records instead of losing them during summary validation. The verdict always
reports missing compiled identities and fails; this shape cannot establish a pass.

## Prepared Linux/macOS host partition

The reader recognizes one literal `run_host_checks.py --host-platform linux` and
one literal `--host-platform macos` producer, with summary jobs `host-linux` and
`host-macos`. The verified base's `host_partition` owns the split: macOS owns
`swift-format lint` and the Swift JSON encoding Python test listed in
`MACOS_PYTHON_TESTS` that is present in the admitted population; Linux owns every
remaining host and Python identity. Removing or renaming a listed case does not
block the split: removal is still reported, and a new name is executed on Linux.
The two sets are disjoint and their union must equal the complete admitted host
inventory. Both jobs and exact per-job evidence are required; candidate exclusions,
duplicate ownership, unknown platforms and missing jobs cannot pass.
The gate producer now activates both partitions. Each Python executor first
checks full dynamic discovery against the complete static inventory, then runs
its base-owned subset. Linux uses the existing pinned Python packages and zstd;
macOS executes the base-listed Swift-calling methods and swift-format. The default local host
command remains unsplit and still runs every host check and Python method.

## Current workflow boundary

`ci-gate` runs both host partitions on PR merge commits and pushes to main. Each has read-only
contents permission, bounded job/script budgets, PR-specific cancellation (main pushes replace only a pending run, see [coalescing](CI_PUBLISHER.md#main-push-coalescing)), and no
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
venv made from `/usr/bin/python3` on macOS; Linux uses Ubuntu's system Python with
the same pinned packages. Each uses its venv for the host entry point and validators. Contributor interpreter setup is described in
[CONTRIBUTING](../CONTRIBUTING.md#setup).

The generic identity schema also supports `workflow_dispatch` and `schedule`.
The strict matrix and skeleton aggregate are described in [Skeleton nightly](CI_NIGHTLY.md).
Under the `ci-gate`
consumer policy, readers must accept only `pull_request` and `push` events from its expected workflow. A structurally
valid manual-dispatch record is not admissible as a `ci-gate` result.
