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

The object requires `schema_version: 1`, `collection_seconds`, boolean
`truncated`, and `events` (at most 512 entries), and accepts optional `case_resources`
as specified below. `collection_seconds` contains
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

The reader also accepts `case_resources`, an array of at most 64 case measurements.
Strict producers emit it for each actual Xcode case invocation, including an
existing listed retry. Fixture UI producers do not sample continuously. Each entry has
exactly the following fields. All numbers are finite, booleans are not numbers,
and unknown measurements remain null.

| Fields | Bounds and meaning |
| --- | --- |
| `sequence` | Unique integer 0–2^31 - 1 identifying a case invocation in this receipt; never a case title or process identifier |
| `duration_seconds`, `sample_interval_seconds` | Case duration 0–86,400 and nominal interval 0.001–86,400 seconds; the producer samples about every 2 seconds without waiting in the test thread |
| `sample_count`, `truncated` | Integer 0–43,201 retained samples and boolean indicating incomplete collection or retention |
| `idle_percent_min`, `idle_percent_median` | Host idle CPU percentages 0–100 or null; minimum cannot exceed median |
| `load_1m_max`, `app_cpu_percent_peak` | Maximum 1-minute load and peak App CPU percentage, 0–10^6 or null; process CPU uses one core = 100% and may exceed 100% |
| `sampler_wall_seconds`, `sampler_cpu_seconds` | Active collection wall time 0–86,400 and collector plus child-process CPU time 0–10^12 seconds, or null; sleeping time is excluded; periodic sampling has the separate bounded allowance described below |
| `first_failure_elapsed_seconds` | Offset from this case's sampling origin, 0–case duration, or null if no failure is bound; absence never proves a passing case |
| `failure_samples` | At most six samples, no more than `sample_count`, strictly increasing by `elapsed_seconds`, within both the case duration and ±5 seconds of the first failure; empty when the failure time is unavailable |

Each failure sample has exactly `elapsed_seconds` (0–86,400), `idle_percent`
(0–100 or null), `load_1m` (0–10^6 or null), and `cpu_percent`. The latter has
exactly `app`, `simulator_daemons`, `test_tools`, and `other`, each 0–10^6 or null.
These categories are disjoint: the App under test; simulator system daemons
descended from `launchd_sim`; XCTest, testmanagerd and xcodebuild tools; and all
remaining host processes. App and test-tool membership takes precedence over
simulator ancestry. No executable names, PIDs, paths, arguments or activity
titles are published. Measurements with unavailable membership must remain null.
Sampling limitations, including missing intervals, do not alter a test result.
The separate [prepared environment-limit proof](#prepared-hosted-strict-environment-limits)
can classify a failed hosted timing observation only when its full criteria are met.
Summary Markdown displays per-case sample counts, idle minimum/median, maximum
load, peak App CPU, sampler costs and truncation; nearby samples remain in JSON.
The case manifest and each tracer warm phase retain a bounded receipt with an
empty `events` list and only that case's resource sequences, plus the shared
collection-cost and truncation metadata; the job summary retains the full ledger.
This binds numbers to the existing case identity without publishing process names.
The tracer validates `warm[].bounded_diagnostics` with the bounded-diagnostics
reader's `validate_receipt` before writing this public sequence-to-case binding.
Trusted trace readers ignore this field; they do not validate or use it for verdicts.
`sequence` comes from the same monotonically increasing ledger counter as events;
it is not an identity or an attempt number. The sampler claims its sequence
immediately before the corresponding `xcodebuild` event. The enclosing case
manifest or tracer warm phase supplies the case identity and its dimensions.
Within that case, sorting resource entries by sequence follows actual Xcode
invocation order, including fixture sessions and the existing listed retry's
attempt order recorded in `*-attempts.json`. Do not infer a test name from the
sequence or assume every number represents a separate test method. In the job
ledger, use those same sequence values to join back to the enclosing case.

Host idle is a delta of Mach CPU ticks; category CPU is the macOS `ps` short-term
percentage estimate, with one core = 100%. These have different averaging windows
and need not sum to the same instantaneous host utilization. The collector reads
only PID, parent PID, CPU and short executable names in private memory, inspects
candidate App executable paths to distinguish the selected simulator, then
discards every PID/name/path. It never requests argv or process environments.
Unknown App ownership or a failed process snapshot makes category CPU unavailable.
The first interval primes the host counters. Collection pauses for the nominal
interval plus the preceding sample's work; stop never waits for another interval.
Periodic sampling has a separate 180-second active-wall allowance shared across
the job ledger. Each successor subtracts all persisted `sampler_wall_seconds`
costs; an unknown predecessor cost exhausts the allowance conservatively. An
unavailable inherited diagnostic ledger prevents sampling instead of granting
a fresh allowance. No
fresh allowance is granted per case. This preserves the existing 10-second
Xcode diagnostic pool for native extraction and anomaly diagnostics, and keeps
the sampler running through a 20–30 minute shard. At a two-second interval,
900 samples cost about 28 seconds at the measured 31 ms/sample or 92 seconds
at the measured busy-host 102 ms/sample. The 180-second allowance is bounded,
not a guarantee under arbitrarily slow host scheduling. Caps and unavailable
measurements set per-case truncation. An unfinished collector marks cost
unavailable and prevents successor sampling from reclaiming its allowance.
`sampler_cpu_seconds` is currently null because per-case child CPU cannot be
isolated from other runner children; isolated cost measurements include the
collector and `ps` child via process resource usage. Collection ends when Xcode
returns; no extra wait is added to obtain future failure-window samples.

Current producers collect preparation and Xcode diagnostics only. Fixture-scope
events remain reader-compatible, but no fixture diagnostics are emitted or
harvested; `collection_seconds.fixture` is always null. The fixture servers,
startup environment and health deadline use their ordinary paths unchanged.

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
Ledger IO has a separate 1.5 s pool reserved once within the 5 s preparation
ceiling, with a 0.1 s cap precharged per read or write. Completed IO refunds
unused time in memory. Writes first persist the conservative balance, then
persist a refund within the same worker deadline, reserving up to 10 ms for
that final write. A failed or late refund leaves the conservative balance.
The pool's unused reservation stays held for the job; only measured time
enters collection costs. A child whose reservation fails skips its normal exit
save. Instead it attempts a capped write of its loaded receipt with truncation
set and the original scope allowances unchanged; IO still spends the shared
pool. If that write also fails, the prior disk receipt remains authoritative.
Each write uses a distinct temporary file, including overlapping timed-out workers.
The refund deadline check precedes atomic replacement: a scheduling pause between
them can commit after the caller times out. That window can undercount up to
about 0.09 s per late commit; the caller still waits at most its 0.1 s IO cap.
Exhausting preparation sampling never gates persistence of Xcode
events. Start samples leave 0.5 s for anomaly sampling; the IO pool has its own
exhaustion/truncation boundary rather than borrowing another scope's budget.
A fresh process must read the ledger before learning that its inherited IO
pool is exhausted. That first read can consume up to 0.1 s outside the exhausted
pool's accounting; subsequent IO in that process is disabled. Long local runs
can repeat this overhead across new children after exhaustion.
The internal ledger stores the public receipt and remaining numeric allowances;
allowances are distinct from observed `collection_seconds`. A lost child's
collection measurements remain null rather than treating its reservation as an
observation. Only the validated public receipt is attached to summaries.
Every process sample has a 0.25 s cap, with 0.08 s subprocess deadlines; public
Xcode progress reads have a 0.1 s cap. Capped daemon workers prevent a stuck diagnostic from blocking the
runner. Retention and cumulative collection budgets stop additional work and
mark truncation.
The first truncation per process also starts a best-effort, non-waited stderr
write: `bounded-diagnostics truncated: <reason>`. Reasons come from a closed set
of collection/IO/retention code paths and inherited truncation; the line
contains no values or paths and is never added to records. The daemon uses
`os.write(2, ...)` directly, avoiding buffered stderr's interpreter-shutdown lock;
a full stderr pipe blocks only that non-waited writer, which may outlive collection.
The strict tracer forwards only the first exact prefix/allowlisted reason from
each child's private runner log to job stderr, preserving its original exit code.
It latches that signal and marks truncation after every subsequent checkpoint
load, including when the child could not load or persist its own receipt.
Out-of-range measurements become null (or zero for a required
elapsed offset), and receipts are validated before attachment; invalid receipts
are dropped without changing the verdict. Xcode timeout observations follow
stdlib cleanup; they do not claim a pre-kill sample. They retain allowlisted
process statistics, the last
recognized public phase, and official-export existence booleans. Existing bundle
export, retention and privacy rules still apply. Ready is written at the existing
point after generation and bind; health and the 60 s deadline remain authoritative.

The approved per-job ceilings apply across repeated preparations and Xcode invocations.
Both the 25 strict jobs and 18 fixture UI jobs use the shared producers: at most
43 × 5 s = 3.59 machine minutes/night for preparation. Xcode diagnostics add at
most 10 s (0.167 machine minutes) per failed strict job. With one such failed
job, the combined ceiling is 3.75 machine minutes/night. Strict and UI can overlap
after archive selection, each at two jobs per matrix. Preparation and Xcode
diagnostics add at most 75 s along the strict tier (13 waves plus one failure)
and 45 s along UI (nine waves); summing them gives a conservative 2.00-minute
wall-time allowance. The final aggregate waits for both tiers. These are ceilings
and ideal parallel
estimates, not hosted measurements or billing. Existing readiness, Xcode and
service deadlines remain unchanged.

PR CI uses the same ceilings. For a six-shard functional `ci-ui` selection,
6 × 5 s = 0.50 machine minutes/push; two `ci-strict-tracer` jobs add
2 × 5 s = 0.167 machine minutes, plus 0.167 per failed strict job.
With one failure the combined ceiling is 0.834 machine minutes/push. Two serial
UI shards per device add at most 10 s wall time; the parallel strict jobs add
at most 15 s with one failure, or 0.25 minutes of combined critical-path
overhead when the tiers overlap. Selection/Cloud waits run no producers. Actual
packing, runner queues and approval waits determine the full workflow wall time;
these figures describe diagnostic overhead, not total CI duration.

Direct strict invocations also activate an in-memory recorder: `ci-p2-review`
runs two serial processes (warm build and test), each capped at 5 s plus
10 s on an Xcode timeout, so that job adds at most 0.167 machine minutes and
10 s wall time without timeouts, or 0.50 machine minutes and 30 s with both
timed out. Direct helper calls in the iOS/tvOS access-lifecycle runners and
`ci_flaky.run_ui` activate no session themselves; when called within an active
strict session they share its existing ceiling. An explicitly wrapped independent
invocation would add at most 0.25 machine minutes and 15 s wall time. These
direct callers publish no bounded receipt themselves. They have no scheduled
nightly frequency and are outside the 43-job nightly estimate above; add their
per-invocation costs for any manual or additional workflow runs.

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

### Prepared UI staging identity failure receipt

The reader also accepts the same seven-field `identity-failure.json` in a separate
`nightly-ui-identity-<device>-<shard>-<run>-<attempt>` artifact. Its `job` is exactly
`ui-<device>`, its `shard` is the scheduled UI shard name, and `declared` is the
UI plan's ordered method identities for that device/shard. The version, run,
phase and reason fields follow the strict receipt contract above.

The reporter first verifies the UI plan against the tested commit's tree, Swift
sources, default plans, shard manifest and hashes, and recomputes the aggregate
from available records. Only a shard with neither an interval summary nor a
matching current-attempt UI records artifact is eligible. Unknown fields, malformed,
duplicate, expired or foreign-attempt receipts retain the generic missing reason.
Missing methods stay missing/NOT_RUN, the verdict stays failed, and other shards'
formal results survive. The receipt is untrusted: it supplies no source identity,
paths, environment SHAs, command output, compiled/executed evidence, pass night or
issue closure. Following the reader's merge to main, nightly UI staging emits
this receipt only when source identity collection or validation raises: Git
failure or timeout, a checkout/`GITHUB_SHA` mismatch, or identity validation failure. It
derives the ordered methods from the same versioned Swift source, default plan
and shard manifest used by scheduling, without collecting or substituting a
source identity. The normal path does not compute or write a receipt. Cancellation,
subsequent source metadata validation and archive staging allocation failures
write no receipt. A diagnostic write failure preserves the original identity
exception and exit. The workflow uploads the receipt separately with seven-day
retention and skips the records scan/upload on that path; see
[the nightly guide](CI_NIGHTLY.md#early-failure-diagnostics).

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
| `first_failure` | Optional fixed-vocabulary receipt on a failing public-fixture strict/UI observation and its first failing attempt; see [first-failure evidence](CI_STRICT_RUNNER.md#first-failure-evidence) |

The paired `failure_phase` and `failure_class` enums are optional in both summary versions 1 and 2. When either is
present on an observation or attempt, both must be present and allowlisted strings;
free text, unpaired fields and all other unknown fields remain invalid. Historical
records without the pair remain valid. Strict/UI producers label failed methods,
use `unknown` for unavailable or ambiguous diagnostics, and retain the first
failure's labels on an observation after a listed retry passes. The enums do not
participate in outcome, population, retry or verdict evaluation.

Public-fixture strict/UI runners emit `first_failure` only after reader acceptance
on main. It is accepted in both summary versions, recursively checked by the publication
scanner, and visible in producer summaries, the 7-day shard artifacts and
`diagnose_nightly`. Reporter outputs (runs pages, step summary and post-merge
notices) never carry receipts. Compact reporter history omits receipt objects,
including all nested copies, to avoid growth
against its 16 MiB hard cap; the measured baseline and budget are documented in
[first-failure evidence](CI_STRICT_RUNNER.md#first-failure-evidence). A receipt cannot be
attached to a passing attempt or a host/unit observation. The observation must
equal its first failing attempt's receipt; an existing listed retry cannot replace
that first receipt with the retry's state. Preparation receipts belong to
`not-run` attempts.

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

Retiring a producer identity must also preserve interpretation of its retained
records. Keep historical selectors in the reader, gated by the night's verified
scheduling evidence, until the last affected producer artifact expires; do not
restore retired identities to current scheduling. See the
[reporter's historical strict selectors](CI_REPORT.md#collection-and-retention).

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
The same sequence applies to `bounded_diagnostics.case_resources` and
`first_failure.native_activity_seconds`: merge reader support before opening the
producer activation PR. Historical records without either optional field remain valid.

### Prepared hosted strict environment limits

Hogan approved this judgement policy on 2026-10-21. This is the reader stage:
no tracer emits `environment_limit` yet. Merge this reader before activating the
producer in a separate PR. Existing nights, raw outcomes, first-attempt failure
counts, deadlines, retries and thresholds remain unchanged. The scope is strictly
GitHub-hosted `ci-nightly` strict shards, for `schedule` and `workflow_dispatch`;
`ci-pr-gate`, fixture UI shards, local and self-hosted runs are excluded.

A failed strict observation and its sole failed attempt may carry the same optional
`environment_limit` object. It contains exactly `schema_version: 1`,
`runner_hosted: true`, paired `failure_phase` / `failure_class`, `failure`, and
`resources`. `failure` is the closed projection of `first_failure`: `source`,
`step`, `action`, `app`, `surface`, `scene_status`, `wait_elapsed_seconds`, `deadline_seconds`,
`action_duration_seconds`, and `post_event_idle`. Numbers retain the first-failure
bounds and nulls. `resources` is one unchanged, validated `case_resources` entry.
The summary reader recomputes the projection from the original receipt and checks
the nightly strict source. No unknown field, private assertion or free text is allowed.

All criteria are required:

1. The producer records GitHub-hosted execution. The reporter additionally binds the
   current-attempt strict job through the Actions API: its runner group is
   `GitHub Actions` and its labels do not include `self-hosted`. Missing hosting
   evidence fails closed.
2. The first failure has `source: xctest`, `app: running-foreground` and an eligible phase/class/step from the
   table below. Its wait elapsed time is at least its positive deadline; alternatively
   a `select` / `tap` has native `post_event_idle >= 20` seconds, with action duration
   at least that idle duration. The existing native collector uniquely binds that
   interval to the failing action. A slow unrelated action cannot qualify.
3. Exactly one resource invocation has a recorded first-failure time. It contains
   at least two distinct, ordered `failure_samples`, each within inclusive ±5 seconds
   of that time, each with measured `idle_percent <= 5`. Every retained failure-window
   sample must qualify, including the boundary values. Missing idle is red.
   `truncated: true` and absent category CPU values do not disqualify measured idle;
   load and App CPU are displayed, not used as classification thresholds.

| Phase | Class | Eligible steps | Timing-only interpretation |
| --- | --- | --- | --- |
| `mode_selection` | `navigation` | `mode-card`, `mode-continue` | Dedicated mode control readiness wait |
| `playback_entry` | `navigation` | `query-element` | Playback surface availability wait |
| `settings_navigation` | `navigation` | `query-element`, `select` | Settings surface wait or bound native input idle |
| `control_action`, `hidden_controls` | `hidden_controls` | `query-element`, `reveal-controls` | Control availability wait |
| `interval_setup` | `hidden_controls` | `query-element` | Settings control availability wait |
| `unknown` | `snapshot_query` | `query-element`, `select` | XCTest snapshot wait or bound native input idle |

This is an explicit allowlist, not an inference from an exception name. A deadline
left over from a completed wait cannot turn a value or scene assertion yellow.
`scene_identity`, `control_state`, `interval_readback`, validator failures, observed
BLACK/BLANK frames, UNRECOGNIZABLE playback frames, process failures, and all other phase/class/step
combinations stay red. In particular, `history_navigation` / no-advance and
`continue_timing` / `timing_window` mix observable functional outcomes with timing
checks and are excluded. Rotation and pause-window contracts are also excluded
without a separately reviewed timing-only interpretation. Missing or ambiguous
receipts, samples or case bindings stay red; an old night gains no classification.
`firstboot_setup/navigation` also includes a confirmed connection-error alert,
and `mode_selection/navigation` at `query-element` includes an unexpected legacy
control assertion, so neither qualifies. `playback_entry/navigation` at
`mode-departure` specifically reports Continue returned without a password prompt
while the mode page was still observed; that known navigation defect stays red.
An unrecognizable photo identity on a known non-playback surface, such as the mode
page, does not by itself assert that the App displayed a wrong photo.

With complete matrix evidence, the accepting strict aggregate uses
`status: environment-limited` and an `environment_limited` identity list when
all nonpassing cases qualify. It exits zero with a prominent warning for every
yellow case and all its sample numbers; raw observations remain `failed` and never
count as passes. Any red case, missing case, infrastructure/cleanup error, failed
matrix job or failed UI aggregate keeps the night red. Producer activation must
make exclusively yellow strict jobs exit zero while preserving failed receipts;
an unrelated job failure must never be ignored by the aggregate.

The reporter binds every claim to the same case's trace resource entry and official
method receipt, then checks the aggregate list against the shard claims. Existing
log, warm-build/reuse and invocation-infrastructure requirements remain mandatory;
an outer invocation timeout or interruption cannot become yellow. Report tables
and compact history retain the bounded proof and every yellow warning,
including when a red case keeps the overall night failed. They preserve raw failure
counts and add the separate `environment-limited` count. Yellow cannot trigger a
product failure issue, satisfy recovery, become a product flake or use a quarantine
retry. Existing `ci-known-flaky.json` entries are unchanged. Timing acceptance still
requires local runs on the pinned devices.
The unchanged-night reader accepts this status as executed coverage, as it already
does for complete red nights; this grants no pass or recovery evidence. Diagnostic
or incomplete nights remain ineligible baselines.

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

The Python executor flushes `PYTHON START` and `PYTHON FINISH` lines with the
discovered test identity, outcome and elapsed time. If one test (or discovery or
the interval between tests) remains active for at least 60 seconds, a daemon
monitor emits a code-only stack snapshot at its next 60-second tick. Collection
is capped at 20 timer intervals (~20 min), eight threads and 32 frames per
thread. The main thread is first and the monitor itself is excluded. Only Python
files directly under `scripts/` appear, with repository-relative filenames,
line numbers and function names; no locals, source lines, exception text,
external paths or thread names are logged. This is log-only diagnostic evidence:
the summary schema, population accounting, verdicts and host budget are unchanged.
The monitor retains its real clock independently of test clock mocks and has a
bounded shutdown wait; a blocked stack-log write cannot block test execution.

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
