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
the following required fields and optional `app_hang_stack`, `continue_watch`,
`simulator_processes`, `pause_window_assertions` and `failure_locations`. All numbers are finite, booleans are not numbers,
and unknown measurements remain null.

| Fields | Bounds and meaning |
| --- | --- |
| `sequence` | Unique integer 0–2^31 - 1 identifying a case invocation in this receipt; never a case title or process identifier |
| `duration_seconds`, `sample_interval_seconds` | Case duration 0–86,400 and nominal interval 0.001–86,400 seconds; the producer samples about every 2 seconds without waiting in the test thread |
| `sample_count`, `truncated` | Integer 0–43,201 retained samples and boolean indicating incomplete collection or retention |
| `idle_percent_min`, `idle_percent_median` | Host idle CPU percentages 0–100 or null; minimum cannot exceed median |
| `load_1m_max`, `app_cpu_percent_peak` | Maximum 1-minute load and peak App CPU percentage, 0–10^6 or null; process CPU uses one core = 100% and may exceed 100% |
| `sampler_wall_seconds`, `sampler_cpu_seconds` | Host-read plus process-snapshot collection wall time 0–86,400 and collector plus child-process CPU time 0–10^12 seconds, or null; interval sleeping is excluded; periodic sampling has the bounded allowances described below |
| `first_failure_elapsed_seconds` | Offset from this case's sampling origin, 0–case duration, or null if no failure is bound; absence never proves a passing case |
| `failure_samples` | At most six samples, no more than `sample_count`, strictly increasing by `elapsed_seconds`, within both the case duration and ±5 seconds of the first failure; empty when the failure time is unavailable |
| `app_hang_stack` (optional) | At most 4,096 compact JSON bytes: `status` (`captured`, `failure`, `timeout`, `cancelled`), `sample_count` (main-thread samples), and `frames` (at most 30 objects containing only `symbol`, allowlisted `module`, and inclusive `samples` count); optional `hint` contains at most three distinct frame indices in observed callee-to-caller order; non-captured states have zero samples and no frames |
| `continue_watch` (optional) | Failed `tvos-lifecycle-pause` only; at most 8,192 compact JSON bytes and the first 80 frames, rounded to three decimals; see the numeric projection below |
| `simulator_processes` (optional) | At most 1,024 compact JSON bytes: `entries` (at most five named entries followed by `other`), boolean `unavailable` and `truncated`; each entry contains only allowlisted `name`, `mean` / `peak` CPU percentages (0–10^6, or null when unavailable), and integer `samples` (0–43,201 valid snapshots) |
| `pause_window_assertions` (optional) | Nonempty list of at most 11 distinct fixed families from the failed pause-window method's existing official legacy export; no assertion text or observed values. See the [family definitions](CI_STRICT_RUNNER.md#pause-window-assertion-families). |
| `failure_locations` (optional) | Failed strict cases only: at most three distinct XCTest-recorded issue locations, projected as `{path, line}` from the already-read legacy failure summaries and bound to the failed official method and resource sequence. `path` is at most 240 ASCII characters, rooted at `immichSlidesUITests/`, `immichSlidesTests/` or `TestSupport/`, with optional directories and a `.swift` filename; components contain letters, digits, underscores or hyphens, and filenames may also contain `+`. `line` is an integer 1–1,000,000. No assertion message is retained. |

Failure document URLs must use `file:` without a host or query; their
zero-based `StartingLineNumber` fragment is converted to the published one-based
line. Only this observed document URL shape is consumed. Absolute input paths
must begin with the executing checkout's literal root or its `/private` alias
before any filesystem resolution, and must then resolve inside that root;
checkout aliases such as `/var` and `/private/var` normalize to that same root,
and only the relative suffix is retained. Other absolute roots, home paths outside that root,
traversal outside the checkout, hosted URLs and non-allowlisted paths are omitted. Missing
locations omit the field. Summaries render `failed at path:line` beside the full
case identity; multiple locations do not establish the first failure. Readers
drop only an invalid `failure_locations` projection and retain the enclosing
case resources, outcome and environment-limit proof. Old nights need no field.
Evidence redaction scans remain strict: `bounded_diagnostics` and
`environment_limit` envelopes are validated on a copy, and any dropped projection
makes the scan fail rather than permitting the original evidence bytes.

These are XCTest's recorded issue locations, which do not always identify the
underlying failing condition. A helper without `file`/`line` forwarding records
its own assertion body. The iOS lifecycle stable-capture helpers and connection
alert helper forward default `#filePath`/`#line` through their wrappers to `XCTFail`,
so those issues identify the caller supplied to the helper. `IOSDriver.openSettings`
forwards to its internal `XCTFail` and `XCTAssertTrue`; the lifecycle
`openSettingsFromSlideshow`, `readFourSettingsFromRealUI` and
`configureTimingPlaybackSettings` wrappers pass that coordinate through.
`confirmPlayPauseState` forwards to its state-readback assertion. With the pinned
Xcode 27.0 toolchain, a controlled direct
`throw AccessLifecycleContract.AssertionError.message(...)` inside the iOS
lifecycle test recorded the throw statement itself, alongside two distinct
forwarded helper caller locations. This does not establish attribution for
errors thrown through other wrappers. Callers such as `IOSDriver.applyPlaybackSettings`
and `clearDiskCache` use `openSettings`' defaults, so their Settings failures
identify those call sites. The pause-next-continue lifecycle tests use
`FirstFailureEvidence.preservingThrownFailure`, which rethrows the original error:
a recorded location such as `UITestSupport.swift:25` may identify that rethrow
wrapper instead of the original throw statement. The error message never supplies a location.

Each failure sample has exactly `elapsed_seconds` (0–86,400), `idle_percent`
(0–100 or null), `load_1m` (0–10^6 or null), and `cpu_percent`. The latter has
exactly `app`, `simulator_daemons`, `test_tools`, and `other`, each 0–10^6 or null.
These categories are disjoint: the App under test; simulator system daemons
descended from `launchd_sim`; XCTest, testmanagerd and xcodebuild tools; and all
remaining host processes. App and test-tool membership takes precedence over
simulator ancestry. Apart from the optional stack's symbol/module names and the simulator projection's allowlisted basenames, no executable names, PIDs, paths, arguments or activity
titles are published. Measurements with unavailable membership must remain null.
Sampling limitations, including missing intervals, do not alter a test result.
The separate [prepared environment-limit proof](#prepared-hosted-strict-environment-limits)
can classify a failed hosted timing observation only when its full criteria are met.
Summary Markdown displays per-case sample counts, idle minimum/median, maximum
load, peak App CPU, sampler costs and truncation; nearby samples remain in JSON.
Failed strict case rows also show compact `sim-top: name mean%/peak%, ...`
lines, one per sampled invocation, including unavailable or truncated status.
The optional projection does not participate in verdicts, yellow eligibility,
retries, deadlines or scheduling.

`simulator_processes` consumes the existing process snapshots and cadence, within
the same 180-second job pool; it adds no child processes, threads or root query.
The same `ps -ww` call adds `comm`, which reads argv[0] (usually the executable
path), because Darwin's existing `ucomm` accounting name truncates long basenames.
Only in memory, the stripped argv[0] basename is compared with the enum below;
no other argv or process environment is read. `-ww` prevents terminal-width
truncation, including without a tty. Category accounting retains its short-name
rules and reads the first whitespace-delimited `ucomm` token when `comm` is present.
A missing `comm` drops only that simulator snapshot (the projection is truncated,
or unavailable when no snapshot remains), preserving the snapshot's category accounting.
The already device-verified App's `launchd_sim` ancestor identifies the assigned
tree in that snapshot. A missing, inaccessible or ambiguous root makes that
snapshot unavailable; it never falls back to other simulator trees. In particular,
before the App appears or after it exits, device-tree evidence can be unavailable.
Roots are resolved again from each snapshot rather than reusing a PID across
reboots. Existing all-tree `simulator_daemons` totals retain their original meaning.
App, XCTest, testmanagerd and xcodebuild entries are excluded before aggregation.

The fixed basename enum is `diagnosticd`, `lsd`, `STExtractionService`, `PosterBoard`,
`intelligenceplatformd`, `photoanalysisd`, `mediaanalysisd`, `fileindexerd`,
`mobileassetd`, `nsurlsessiond`, `chronod`, `Spotlight`, `searchd`,
`BackgroundShortcutRunner`, `MercuryPosterExtension`, `EmojiPosterExtension`,
`GradientPosterExtension`, `SpringBoard`, and `backboardd`. These are explicit
system services and extensions identified in the local iOS/iPadOS/tvOS first-boot investigation: diagnostics and
registration, streaming extraction and assets, analysis/indexing, and wallpaper /
widget activity, plus the SpringBoard/backboardd system UI and event services
observed among the local iPhone/iPad and tvOS CPU leaders. No wildcard matches or
arbitrary basenames are published;
unidentified MobileAsset workers and extensions remain `other`.
Multiple instances of one name are summed per snapshot. Select at most five
names by their CPU mean across valid snapshots, breaking ties by the enum order
above; a confirmed absence in a valid snapshot is zero, while missing snapshots
never enter the denominator. Sum unselected names and unknown processes into
`other` in each snapshot before computing its mean and peak. Thus `other`'s peak
is not a sum of nonconcurrent peaks. Numbers are rounded to three decimals.
All entries share their valid-snapshot count; with no valid snapshots, only
`other` remains, with null mean/peak, zero samples and `unavailable: true`.
Incomplete collection is marked truncated. An invalid producer projection is
dropped alone, preserving the case's numeric evidence.

The last retained phase excludes metadata-only hosting markers, which do not
establish that Xcode reached test execution; other events render as before.
The case manifest and each tracer warm phase retain only that case's resource
sequences and one minimal hosting event per sampled invocation, plus the shared
collection-cost and truncation metadata; the job summary retains the full ledger.
At case start, the sampler records an existing xcode/test-execution started event
with its own sequence. Its sample contains only the Boolean/null hosting flag
derived from `RUNNER_ENVIRONMENT`; all measurements and image version are null,
and `processes` is empty. Recording this metadata consumes no diagnostic allowance
and remains available when Xcode diagnostic accounting is unavailable. The event
counts toward the existing 512-event retention cap and is retained as an anomaly,
so it can evict a success and make `event-cap` truncation and its log notice appear
earlier, bounded by about 64 markers per ledger. A lost event cannot prove hosting.
Every other event is cleared from the case copy to avoid duplicating the growing
job ledger and exceeding the first-failure exporter's 65,536-byte manifest cap.
This binds numbers to the existing case identity without publishing process names.
The tracer validates `warm[].bounded_diagnostics` with the bounded-diagnostics
reader's `validate_receipt` before writing this public sequence-to-case binding.
Environment-limit readers recheck this binding before accepting a proof; resource
measurements alone never change the raw verdict.
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
PID, parent PID, CPU, short accounting names and, for the simulator projection,
`comm` (argv[0], usually the executable path) into private memory. It compares the
stripped argv[0] basename with the allowlist and separately inspects candidate
App executable paths to distinguish the selected simulator, then discards the
table's PIDs, names and paths. No other argv or process environment is read.
Unknown App ownership or a failed process snapshot makes category CPU unavailable.
The first host read primes the counters. Idle is null when successive successful
reads are less than one second apart, including a quick read after a late worker;
each successful read still refreshes the tick and monotonic-time baseline.
Host idle/load ticks follow nominal two-second
deadlines, skipping missed deadlines rather than issuing bursts. Each native host
read runs in one reused daemon worker per case with a 0.2-second wait cap;
observed host-read wall time has a separate ten-second allowance per case,
including the one-time thread startup and each request's response wait. Native
Mach statistics and `getloadavg` launch no subprocess. Reusing the worker avoids
charging thread creation and its scheduling handoff on every two-second tick.
A timed-out host read skips ticks while its worker is still running, then fresh
reads resume within the remaining allowance; late values are discarded. Stop
never waits for another interval or starts a new process snapshot. The worker is
signalled to exit on every case exit, including when idle between requests.
After each request, including a timeout, the collector reserves one 0.2-second
call and prices the remaining invocation deadline using mean request cost
(total host wait, including timeouts and startup, divided by attempted requests).
If two-second ticks would exhaust that allowance, it increases the planned
interval to a multiple of two seconds, capped at four seconds, marking truncation.
Timeouts use that planned interval too. The cap prioritizes recent evidence over
spreading a few samples across a long timeout horizon. Once the unreserved
allowance is exhausted, sampling stops and marks truncation instead of stretching
the gap; subsequent failures can have no nearby evidence and remain red.
Four-second ticks still support a strictly before/after pair within ±5 seconds
when the host responds and Xcode remains running. Arbitrarily slow reads cannot
guarantee that window within ten seconds of total collection cost: longer gaps,
timed-out reads and exhausted budgets retain missing evidence and fail closed.
No bound or test deadline is extended. Reaching the retained-sample cap evicts the
oldest sample instead of ending collection, preserving recent actual samples.
`sample_interval_seconds` remains the nominal two-second interval. Idle is the
mean since the preceding native read: a pre-failure sample can average a longer
interval after throttling, a timeout or host descheduling; a late read that completes
after the failure refreshes the baseline, so the post-failure sample's interval can
start after the failure. No value is interpolated
or relabelled as a two-second measurement. A failed worker start permits another
start on the next planned request. Host costs now
contribute to `sampler_wall_seconds`; older receipts reporting zero when process
snapshots were disabled did not measure host cost.
Process snapshots normally run at most once per ten seconds. After a hosted App
reading of at least 85%, they use two-second ticks only while this case and job
still have a capture allowance and enough budget to reserve a capture. A low or
missing App reading, a capture attempt, or exhausted allowance restores ten-second
process ticks; independent idle/load ticks do not change. Nominal delay from a hang
starting to capture starting can approach 18 seconds (up to ten seconds before the
first high reading, then eight seconds to confirm it); host descheduling can delay
it further. Shorter hangs, including those within eight-second control waits, may
end before a capture starts. Process snapshots share a separate
180-second active-wall allowance shared across
the job ledger. A private `process_sampler_wall_seconds` balance carries only
completed process-snapshot and App stack capture cost across serial case processes; host reads remain
included in the public `sampler_wall_seconds` total without reducing this pool.
Old ledgers without this balance conservatively charge all persisted
`sampler_wall_seconds` costs; an unknown predecessor cost exhausts the allowance.
An invalid private balance makes the inherited ledger unavailable. An
unavailable inherited diagnostic ledger disables process snapshots instead of granting
a fresh allowance, while idle/load ticks continue. Hosted preparation ledger IO
has a 0.1-second cap; an IO timeout can make inherited Xcode accounting unavailable
even on a Release lifecycle shard that has not sampled yet. No
fresh allowance is granted per case. This preserves the existing 10-second
Xcode diagnostic pool for anomaly diagnostics, and keeps
host sampler independent of process-pool exhaustion. The independent host cap remains
ten seconds per invocation and at most 64 invocations per receipt; CPU work is
bounded by these active-wall allowances. The current nightly matrix's longest
strict shards (`iphone`/`ipad` Debug shard 1) expand six suite entries into ten
sampled invocations: each of the two `filter-person` entries has three sessions.
Combined charging could spend 100 seconds on host reads and leave only about 80–90 of
180 seconds for process snapshots (versus about 130 with the old host allowance).
Separate accounting preserves the full process allowance without raising it; the
per-job sampling bound is 180 + 10 × N seconds for N ≤ 64 sampled invocations
(280 seconds for the current longest shard).
The optional stack projection is additive in schema version 1. Old nights without
it remain readable; verdict and environment-limit eligibility rules are unchanged.
The per-case host cap can independently stop idle/load collection earlier; neither
allowance guarantees failure-window coverage through a 600-second invocation.
Ticks without a scheduled process snapshot have null categories and do not mark
the case truncated. Pool exhaustion, unavailable accounting, failed scheduled
snapshots and missing host measurements do mark truncation. An unfinished collector marks cost
unavailable and prevents successor sampling from reclaiming its allowance.
`sampler_cpu_seconds` is currently null because per-case child CPU cannot be
isolated from other runner children; isolated cost measurements include the
collector and `ps` child via process resource usage. Collection ends when Xcode
returns; no extra wait is added to obtain future failure-window samples.

Hosted strict cases (including all their sessions or listed attempts together)
can retain one App main-thread stack when the same identified
simulator App PID has at least 85% CPU (one core = 100%) at consecutive process
reads spanning at least eight seconds. Missing/low reads, PID changes, or gaps
over 4.5 seconds reset that span. These are `ps` CPU estimates, not proof that the
main thread itself was busy. Only one unambiguous App process on the assigned
simulator is eligible. A background `/usr/bin/sample PID 1 10` (one second,
10 ms sampling interval, leaving room for symbolication) has a three-second
subprocess deadline, is cancelled on case exit, and never blocks the idle/load worker.
The case owns the subprocess independently of the capture worker: shutdown closes
the launch gate, kills any in-flight capture and calls `wait` before returning,
even when that worker cannot resume. The capture stays in the runner process group,
so tracer cancellation remains a second cleanup boundary; a detached session could
hide an orphan from that boundary. The capture worker is non-daemon so interpreter
shutdown also waits for its private-file finalizer.
No test or case deadline changes. At most three attempts per job (including
failures) share the existing 180-second process-sampler allowance; three seconds
are reserved before each launch and the completed active wall cost is charged to
both the private balance and public `sampler_wall_seconds`. Unfinished work
retains its full reservation. Shutdown uses 0.8 seconds plus a reap floor:
launch-lock waiting and worker joins share the original 0.8-second deadline, and
after SIGKILL `wait` always receives at least 0.1 second even if lock waiting spent
that deadline. Failure to acquire the lock or reap is recorded in the runner's
existing `cleanup_failures` and `cleanup-failures.json`. Its primary nonzero exit
and any propagating exception are preserved; with no primary failure, the existing
cleanup policy returns 2. Before recording the failure, process-sampling cost is
charged conservatively, including the full reservation for an unfinished capture
and unknown cost for an unfinished sampler. A cleanup retry neither refunds nor
double-charges that reservation. If publishing that cost fails too, inherited
Xcode accounting is made unavailable so the next case cannot reclaim it.
The subprocess deadline does not include PID inspection, raw-file reduction,
worker-owned kill/reap (up to another 0.2 seconds: 0.1 second waiting for the lock
plus a 0.1-second reap floor) or temporary-directory cleanup; their actual
wall cost is charged too, so host descheduling or cleanup can exceed the reservation.
`sample` briefly suspends the App at each sample and consumes CPU for symbolication,
so collection can perturb a running case even though verdict rules and deadlines
do not change. Legitimate high CPU during launch or other work can consume the
case/job allowance before a later hang. The trigger is not a hang diagnosis.

The internal ledger carries `app_hang_capture_attempts`; reservation forfeits all
remaining attempts until the serial child finishes saving its balance. Missing
old or invalid accounting grants no fresh capture allowance. No raw sample is
published: its mode-0700 temporary directory is outside evidence and is removed
on success, failure, cancellation and timeout. The reducer ignores headers,
addresses, binary images and other threads, retains only identifier-shaped
symbols from allowlisted modules, and rejects paths, URLs, UDIDs and selected
domain-like suffixes. The suffix filter is not a general hostname detector;
the module allowlist, symbol-position parsing and restrictive identifier grammar
are the privacy boundary. Only the exact App debug module `immichSlides.debug.dylib`
is mapped to `immichSlides`; symbol filtering is unchanged. PID executable name
and assigned-device membership are checked again immediately before `sample`.
App frames and the selected observed call path take priority over outer framework
wrappers within the 30-frame / 4 KiB cap; remaining frames rank by inclusive sample
count and depth (recursive occurrences can add counts). The hint prefers the deepest
App view body only when its count is at least 80% of the highest App-frame count;
otherwise it uses the hottest App frame, breaking ties by depth. Without App frames,
it uses the deepest public frame with at least 80% of the highest public-frame count.
Closure labels are attributed to their enclosing function, so a body name may
represent its content closure. Unrecognized symbols are omitted.
The enclosing case's resource sequence links the JSON to its identity using the
existing case manifest. The tracer retains that validated case/receipt join in
`strict_case_evidence` for stack-bearing cases independently of yellow eligibility;
Markdown adds `app-hang-stack: ... (anchor/total samples)` in that case's table row alongside
its complete dimensions. Symbols use code formatting and arrows point toward the
callee on the left. Older stack projections without `hint` show one frame without
inventing a path. An invalid producer stack is dropped independently, preserving
the case's numeric measurements and `failure_samples`. Missing symbols or
unsuccessful capture are diagnostic gaps only.

The failed tvOS Continue watch projection is read from the case-owned
`continue-watch-diagnostic.json` in the evidence directory after XCTest and the
official exports finish. The raw file is never added to hosted artifacts.
`frames` contains compact arrays in this order: request, captured, returned
(seconds since Continue), status, public mark, mean luma (0–1, decoded photo mean
when unclassified), photo q95
(0–255), white-core fraction (0–1), controls visible. Only A1–A8 marks (including
combinations of up to four, such as `A1+A2`) and the
existing public identity statuses are accepted; missing classification or pixel
measurements are null. Classification can stop before capture does. `total_frames`
and `truncated` expose omitted frames; `indices` retains recorded anchor/dim/proof
indices only when their frames survived the cap. `wake` is issued/returned seconds
or null. Optional `judge` records the original judge's step (`passed`, `early`,
`late`, `no_transition_start`, `no_stable_new_photo`, `four_second`, `other`, or
`not_evaluated`). `early` also covers scene-check failures before T−2, including
BLACK, UNRECOGNIZABLE or TRANSITION frames and a different public mark.
`rescue_ran` and `rescue_stage` distinguish an unattempted rescue
from `ineligible`, `no_anchor`, `no_dim`, `no_proof`, `missing_pixels`, `span`, `continuity`, `recovery`,
`window_early`, `window_late`, `four_second`, or `passed`. The sealed, passive
observation object cannot run a callback or return a decision to the judge.
Indices describe the last examined candidate, including failed window, recovery
and four-second checks; a later anchor replaces its earlier candidate indices.
Missing pixels interrupt an active candidate with `missing_pixels`; without an
active candidate they do not overwrite the previous candidate's rejection stage.
`single_photo_mode_verified` and `control_bar_wake_skipped` preserve the observed
eligibility and wake context. Source files predating the observation hook use
`not_recorded` for `judge`/`rescue_stage` and null for `rescue_ran`; their existing
`single_photo_mode_verified` and `control_bar_wake_skipped` booleans are preserved.
A missing boolean measurement is null. Projections without these optional fields
remain valid. No legacy `rescue` outcome field is published or accepted; it was
removed before the first main producer, so no archived night depends on it.
Nothing recomputes the verdict. An invalid projection is dropped independently
of resource samples and hang stacks. Source reads are capped at 2 MiB, symlinks
are refused, and no free text, notes, paths, URLs, device IDs or names are retained.
The tracer preserves the case/receipt join independently of yellow eligibility.
The 80-frame and rounding limits normally fit within 8 KiB; the byte-truncation
loop is a fallback for future field growth and also removes indices for omitted frames.
The case row adds `continue-watch: frames=N/total, median request interval=…s,
dim MATCH=k, judge=<step>, rescue=<ran|not-run|unknown>/<stage>`; the interval is
the next request minus the prior request over retained frames. Dim MATCH counts
only MATCH frames with the first MATCH mark, mean below that frame's mean, and
q95 at least three below that frame's plateau measurement. These are observations,
not a replay of the rescue or timing judge. Historical nights without the field
retain their original readability and verdicts.

`run_strict_e2e.py --local-force-app-hang-capture` exercises the capture on the
first identified App CPU read, including idle CPU. It is ignored whenever `CI`,
`GITHUB_ACTIONS` or `RUNNER_ENVIRONMENT` is set, so hosted runs cannot use this
local threshold override. It affects only diagnostics, never the App or XCTest.
The failure timestamp is bound after XCTest returns, so historical category CPU
cannot be freshly sampled at the failure time; only actual periodic snapshots
within the existing five-second window are published, with no backfilled values.

Native activity and failure-time extraction has an independent two-second
allowance per case and twenty seconds per strict job. The tracer owns the job
counter in its parent process and precharges up to two seconds before each warm
child via `--native-diagnostics-allowance-seconds` (0–2); it does not reclaim
unverified child costs. Successful cases also hold their prepaid reservation.
The child's counter is shared across that case's fixture sessions and listed
attempts; standalone strict runs default to two seconds. These allowances remain
usable when diagnostic-ledger IO fails and never borrow the Xcode or process
sampling pools. Capped daemon workers precharge before reading; completed work
refunds unused time locally, while timed-out work does not. Late results cannot
bind a failure epoch. No new collection-cost field is published.

Extraction requires one tests reference, one matching selected method and a
unique earliest failure timestamp. Native timestamps require a full date and
time with optional fractional seconds and an explicit `Z`, `+HHMM`/`-HHMM`, or
`+HH:MM`/`-HH:MM` offset; invalid offset minutes and trailing data are rejected.
Missing/oversized objects, timeouts and
ambiguous method, failure or synthesis bindings leave the failure window
empty. Ambiguous tap durations also leave it empty unless a unique XCTest
failure association identifies the native action. If the failure timestamp is
unique but native action details are simply absent, the timestamp can still bind
host samples while native durations remain
null. Existing numeric-only native duration and failure-sample fields are used;
timestamps, activity titles, paths and identifiers remain private.

Native dates accept compact and colon-separated timezone offsets and `Z` on
Python 3.9. At stop, the case compares wall-clock and monotonic elapsed time;
a difference greater than 0.5 seconds prevents failure-window binding.

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
Hosted load has exhausted this cap before strict cases started. Raising it to
0.5 s would also widen that late-refund undercount window to about 0.49 s per
commit, so the cap stays unchanged pending a ledger commit-protocol change.
Host ticks and the separately prepaid native allowance do not depend on this IO.
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

The following preparation/anomaly estimates exclude periodic resource sampling,
its separately bounded host reads and the additional native allowance above.
Native extraction adds at most twenty seconds per strict job; actual elapsed
cost is not published separately. The approved preparation/anomaly ceilings apply
across repeated preparations and Xcode invocations.
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

Current selection-only and legacy refunded mode-navigation timing fields: after a card/Not Now tap restarts the wait,
`timing.deadline_seconds` is the remaining observation allowance, not the original
selection/departure duration or total wall time. `wait_elapsed_seconds` measures
that restarted segment, so a display such as `wait=0.31s / deadline=0.30s` is valid.
The nonnegative remainder can be zero, which remains ineligible for yellow.
After Continue returns, the initial departure `deadline_seconds` is the caller's
full duration `D`; the tap, including XCTest's idle waits, is recorded separately
in `action_duration_seconds`. Later actions can replace that single-action field;
the legacy mode observation log and failure detail retain each deducted tap duration and
their total, including Continue. Current selection-only logs retain individual card/Not Now
durations in `nativeTapSeconds`, without a total field. Guarded Continue navigation records
native durations but does not refund them or restart its deadline.

Legacy IOSDriver Settings and current rotation stable captures exclude their measured native
tap time. After each preparation deduction, `deadline_seconds` records only the
remaining observation allowance and `wait_elapsed_seconds` measures the restarted
segment. The Settings outcome wait uses its original entry allowance minus all
spent non-tap work, excluding its wake and Settings tap. Capture logs and failure
details retain every deduction and their total; the single-action receipt field
continues to describe only the latest action. The playback-rotation 30-second bound
still includes all wall time. The [Settings caller formulas](TESTING.md#3-assertions)
and [rotation caller formulas](TESTING.md#running-controlled-integration-and-end-to-end-tests)
are authoritative.

Current mode departure, IOSDriver Settings entry and Next readiness instead use
an unscaled 60-second monotonic navigation guard. The fixed single-action child
steps share its deadline; native actions no longer extend those paths. For mode
departure and Settings entry the outer wait receipt records that root allowance;
Next has no outer wait, so its readiness receipt records the guard remainder at
readiness start. `action_duration_seconds` still describes only the last action;
it is not a complete native-action total.
Mode diagnostics retain each native duration without treating it as a deduction.
In-flight success and the single post-action observation follow the
[navigation semantics](TESTING.md#3-assertions). Historical receipts and all
environment readers keep their existing interpretation.
Next's separate product outcome window follows the
[authoritative Next contract](TESTING.md#next-and-settings-toggle-hang-guards).

An optional `first_failure.gate` carries the album capture gate's last observed
conditions on its timeout paths only. The First failure line in `summary.md`
renders its fixed Boolean/null facts and enumerated phase; it contains no raw
probe text or identities. Exact fields, phase vocabulary and context restrictions
are specified in [first-failure evidence](CI_STRICT_RUNNER.md#first-failure-evidence).
Both summary versions and the recursive bounded diagnostic/publication readers
accept the object and reject unknown keys or values. Historical receipts may omit
it. Receipt acceptance alone does not grant yellow eligibility; the separately
versioned environment-limit policy below rechecks the projected gate facts.
Producer activation follows the same reader-first merge requirement.

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

Lifecycle pause evidence has a separate receipt version from summary versions.
Unversioned `pause-next-continue.json` keeps its legacy signed screenshot-onset
interpretation for retained 90-day history. Version 2 requires mode
`release-functional`, configuration `Release`, an exact functional signature,
timing `NOT_RUN`, the platform's device and six ordered, hash-bound public-photo
proofs. Missing/unknown versions, signatures, proofs or mismatched hold/resume
identities remain unverified. `pause_timing_verdict` returns `NOT_RUN` for the
explicit functional mode, never `PASS`; the tracer's legacy `p2_verdict` field
carries the separately validated functional verdict. Debug App timeline receipts
and old summary/environment-limit readers are unchanged. Current Release runner
invocations explicitly bind the configuration and require valid version-2
functional evidence on iOS and tvOS; invalid or legacy evidence exits 2 even if
XCTest passes. Configuration-free historical readers preserve old interpretation.

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

A scoped exception permits the optional App hang-stack, Continue watch, simulator-process, pause-window assertion and failure-location projections,
strict runner cleanup member event and their readers
to ship together. The trusted base gate/UI publisher's supported producers in
`ci_publish_git.py` do not consume strict-tracer or P2-review diagnostic artifacts;
candidate tracer checks use their producer checkout's reader, nightly aggregation
uses the run checkout, and the trusted reporter checks out `main`, which contains
the optional reader before a main producer can emit this field. The extension does
not activate a field in required gate/UI records. Old nights and old stack projections remain accepted.
This exception relies on that consumer boundary: introducing the field into a
base-read publication path or reading it with an older revision requires a separate
reader rollout first. The PR must document this transition analysis.
`pause_window_assertions` is emitted only through the strict resource sampler for
the exact failed `StrictE2EFirstBatchIOSUITests/testSinglePhotoOutgoingPauseWindowCapture`
official method and its existing resource sequence. Generic UI exports have no strict
sampler, and `first_failure` and gate/UI records gain no field. Its producer reuses
the already-read legacy failure summaries; missing summaries or ambiguous case
binding omit the projection. The candidate/run/main reader sequence above therefore
also applies to this extension. It never participates in environment-limit eligibility.
`failure_locations` uses that same strict-sampler-only consumer boundary and the
already-read legacy export, for any failed strict method; generic UI exports,
`first_failure` and required gate/UI records gain no field or extra export call.
The candidate/run/main reader sequence therefore permits reader and producer in
one PR. Any future base-read publication requires a reader-first rollout.
`continue_watch`, `app_hang_stack`, `simulator_processes`, `pause_window_assertions` and `failure_locations` are copied into
`environment_limit.resources` in the 90-day yellow history and validated again by
later readers. Their archived validation may only be loosened, never tightened;
otherwise a previously accepted night could become unreadable or red.
For `failure_locations`, preserve the accepted path grammar, path/entry caps and
positive line range; future archived readers may only broaden acceptance. Invalid
projections continue to be dropped alone, including inside retained yellow proofs.
For `simulator_processes`, this freezes acceptance of its current names, nullable
unavailable form, fields, numeric/sample bounds and byte/entry caps: future
readers may only broaden acceptance. A stricter successor producer needs a new
version while preserving this historical reader. Absence of the field remains
valid, including in old proofs. The shared `validate_case_resources` reader is
used by summaries, nightly aggregation, the reporter and environment-limit proof
validation; the trusted-base gate/UI publication paths do not consume this strict
projection. Moving it into those paths requires a separate reader-first rollout.
The `runner_group_*` fields belong to summary-level `events`, not `case_resources`,
and are not copied into `environment_limit.resources`; that 90-day rule does not
apply to them.

On a strict runner process-group cleanup failure, the tracer takes one additional
`ps` read (three-second timeout, 2 MiB parse limit after reading) and retains at most 64 live members in
`events[].runner_group_members`. Each entry has only `name`, `parent` and `state`;
the event is restricted to `xcode/unknown/after-reap`. Executable and parent names
are public tool basenames from a fixed allowlist (plus versioned Python names),
unknown names become `other`, absent parents become `unknown`, and an adopted
parent is reported as `launchd`. The allowlist includes locally verified Xcode 27
`SWBBuildService`, `XCBBuildService` and `swbuild` basenames. Survivor states
use their own closed vocabulary, including `exiting` when macOS reports the `E` flag;
the ordinary sampler's `processes[].state` vocabulary remains unchanged.
Paths, arguments, PIDs and device identifiers
are discarded; zombies and other process groups are excluded. A failed probe is
null, distinct from an empty observed group. A member can exit between the last
group check and this probe, so `none` is a later empty observation and does not
cancel the cleanup error. Optional `runner_group_truncated` is true when more than
64 members were observed; the exception and Markdown show the truncation too.
Old events without this flag remain accepted. Inner exception text is deliberately
dropped for privacy; only its type is retained. Any probe failure, including
KeyboardInterrupt or SystemExit, still raises `RunnerGroupCleanupError` with an
unavailable projection so live build inputs are retained. This failure-only read
does not extend the group grace or change a case verdict, retry, deadline or yellow qualification.

### Prepared hosted strict environment limits

Hogan approved this judgement policy on 2026-10-21. The strict tracer now emits
`environment_limit` from each qualifying warm case's original receipts, using the
merged proof, summary and official-method readers before publication. Existing nights,
raw outcomes, first-attempt failure counts, deadlines, retries and thresholds remain unchanged. The scope is strictly
GitHub-hosted `ci-nightly` strict shards, for `schedule` and `workflow_dispatch`;
`ci-pr-gate`, fixture UI shards, local and self-hosted runs are excluded. Suites marked
`informational` in the manifest never receive a proof. Their failures are excluded
from the tracer's ordinary required-suite verdict, but remain in the producer's
nonpassing-case check when a required suite receives an environment-limit proof.
An informational failure without a proof can therefore keep the producer failed
and turn an otherwise environment-limited (yellow) night red.

A failed strict observation and its sole failed attempt may carry the same optional
`environment_limit` object. It contains exactly `schema_version: 1`, `policy_version: 1`, `2`, `3` or `4`,
`runner_hosted: true`, paired `failure_phase` / `failure_class`, `failure`, and
`resources`. `failure` is the closed projection of `first_failure`: `source`,
`step`, `element`, `action`, `app`, `surface`, `control_bar`, `scene_status`, `wait_elapsed_seconds`, `deadline_seconds`,
`action_duration_seconds`, and `post_event_idle`. Policies v2/v3/v4 additionally accept the
optional, unchanged `gate` object from that receipt; policy v1 keeps its original
closed projection without a gate. Numbers retain the first-failure
bounds and nulls. `resources` is one unchanged, validated `case_resources` entry.
The summary reader recomputes the projection from the original receipt and checks
the nightly strict source. The optional `strict_case_evidence` list binds each strict
case `identity` to its original `bounded_diagnostics` receipt. Each proof must match
that case's resource entry by sequence and full value, and have a matching xcode
event sample whose `runner_hosted` is true. The producer requires exactly one
matching sample; missing, duplicate or conflicting hosting samples fail closed.
The producer fills this evidence slot from the same case trace only after the
candidate summary and official method binding validate. Invalid or ambiguous evidence
emits no proof and retains the raw failure. No unknown field, private assertion or
free text is allowed.

At finalization, nightly strict logs emit one
`environment-limit: not eligible (<reason>)` line per rejected failed case.
The fixed reasons are `informational-suite`, `phase-count`,
`invocation-not-verified`, `invalid-bounded-receipt`, `failure-resource-count`,
`missing-xcode-host-samples`, `hosting-not-proven`, `proof-not-eligible`,
`summary-reader-rejected`, and `official-method-not-bound`. They identify the
first rejecting guard, add no summary field and do not change any verdict.
Resource CPU samples alone do not prove hosting: the same invocation must also
retain an xcode event sample with `runner_hosted: true`. This is a producer
pre-check; the reporter still verifies the current attempt's runner group and
labels through the jobs API, so a forged environment flag is insufficient.

All criteria are required:

1. The producer records GitHub-hosted execution. The reporter additionally binds the
   current-attempt strict job through the Actions API: its runner group is
   `GitHub Actions` and its labels do not include `self-hosted`. Missing hosting
   evidence fails closed.
2. The first failure has `source: xctest`, `app: running-foreground` and an eligible phase/class/step from the
   table below, with the exact target element and expected surface. Unknown surfaces
   are rejected. Its wait elapsed time is at least its positive deadline. Native
   post-event idle alone never qualifies: no existing receipt field proves a following
   successful action readback. `unknown/snapshot_query`, including `Failed to get
   matching snapshot` main-thread hangs, stays red. A hidden-controls timeout while
   `control_bar: visible` also stays red because the target control is still absent.
3. Exactly one resource invocation has a recorded first-failure time. It contains
   at least two distinct, ordered `failure_samples`, each within inclusive ±5 seconds
   of that time, with at least one strictly before and one strictly after the failure,
   each with measured `idle_percent <= 5`. Every retained failure-window
   sample must qualify, including the boundary values. Missing idle is red.
   `truncated: true` and absent category CPU values do not disqualify measured idle;
   load and App CPU are displayed, not used as classification thresholds.
4. For the policy v2/v3/v4 album capture entry, every gate condition below must hold.
   The projected proof retains the gate, and the proof validator rechecks its
   closed shape, kind, Boolean types and eligibility. Summary, official-method,
   nightly aggregation and compact-history readers do not trust a producer's claim.

| Phase | Class | Step and target element | Expected surface |
| --- | --- | --- | --- |
| `mode_selection` | `navigation` | `mode-card`: `mode.random.button` or `mode.filtered.button`; `mode-continue` at `mode.continue.button` (v1/v2/v3/v4) | `mode` |
| `mode_selection`, `playback_entry` | `navigation` | Policies v3/v4: `mode-departure` at `mode.continue.button` | `mode` |
| `mode_selection` | `navigation` | Policy v4 only: `save-password-prompt` at `mode.random.button` or `mode.filtered.button` | `mode` |
| `playback_entry` | `navigation` | `query-element`: `slideshow.control.playPause.button` | `playback` |
| `settings_navigation` | `navigation` | `query-element` or `select`: `slideshow.control.settings.button` | `playback` |
| `control_action`, `hidden_controls` | `hidden_controls` | `query-element` or `reveal-controls`: settings, previous, playPause or next under `slideshow.control.*.button`, or `slideshow.hiddenWakeReceiver` | `playback` |
| `interval_setup` | `hidden_controls` | `query-element`: the same playback controls | `playback` |
| `visible_scene_capture` | `probe_readback` | `wait-scene`: `slideshow.scenePresentation.contract.summary`; policy v2/v3/v4 album gate only | `playback` |

Hogan approved the Save Password mode-selection exception on 2026-10-24.
Policy v4 preserves every v3 entry and adds exactly the two `save-password-prompt`
keys above. The motivating [nightly 39969370437](https://github.com/sudoHG/immichSlides/actions/runs/39969370437),
shard `iphone-immichSlides-iOS-debug-0`, fixture A `album-empty`, reports
`mode_selection/navigation`, `mode.filtered.button`, surface `mode`, wait 23.41 s
against a 22 s deadline. `IOSFirstBootNavigation.navigateMode` and
`selectModeAndContinue` set the step as soon as they observe the prompt, then re-mark
that step at each observation and at timeout; a decline need not have been issued.
The element remains the target card until Continue is issued, then becomes
`mode.continue.button`; issuance is recorded before the native tap, separately from return.
Eligibility still requires the existing hosted marker, a full
deadline and low-idle samples strictly before and after the failure, each at most
5% idle. Other elements, surfaces, phase/class pairs and missing evidence stay red.
Retained v1/v2/v3 receipts never gain this exception; no old night is reclassified.
The nearest red sibling is `save-password-prompt` at `mode.continue.button`:
a prompt observed after Continue has been issued does not gain this exception.

Accepted residual risk (v4 Save Password): the receipt does not record whether a
decline was issued, whether the prompt is still present, or whether the target
card is selected. These functional faults can therefore produce the same receipt
as a slow host: the App re-triggering the prompt after a decline or a card
reselect; an App alert or sheet, duplicate prompt, or ambiguous or unhittable
Not Now preventing any decline; and an App main-thread stall causing `observe()`
to throw while the step stays `save-password-prompt`. With complete hosting and
starvation proof, these indistinguishable faults can be yellow once. A night
without starvation stays red; the second consecutive yellow UTC night escalates
to red, bounding consecutive exposure. The existing weekly review of tests yellow
three or more times still applies. Yellow retains the raw failure and never
counts as pass or recovery; all other failures keep their existing interpretation.

Hogan approved the mode-departure exception on 2026-10-23. Policy v3 preserves
every v2 entry and adds the wait for the mode page to depart after Continue, with the exact step, element,
phase/class and `mode` failure surface above, plus all existing timing, starvation,
hosting and validator exclusions. Any other failure surface stays red.
The receipts confirm both mapped assertion paths: [iPad filter-person,
39840861064](https://github.com/sudoHG/immichSlides/actions/runs/39840861064) reports
`mode_selection/navigation`; [iPhone Release lifecycle-pause,
39873318049](https://github.com/sudoHG/immichSlides/actions/runs/39873318049) reports
`playback_entry/navigation`. These match the generic first-boot navigation and
mode-departure assertion prefixes in `ci_failure_diagnostics.py`.
The `mode-continue` UI-availability wait (a failed Continue tap itself, at
`mode.continue.button`) remains eligible in v1/v2/v3/v4. Continue unavailable before
departure produces `mode-continue` at the card identifier (for example
`mode.random.button`), which no version allowlists, so it remains red. A mode-page `UNRECOGNIZABLE` photo status alone is eligible because
no playback photo is expected there; BLACK/BLANK and unrecognizable playback
remain excluded. The older iPad and album receipts lack hosted markers and remain
red: this exception does not supply missing evidence or reclassify old nights.

Legacy mode-navigation clocks excluded measured tap time, including XCTest's pre- and
post-event waits for the App or prompt host to idle. Each tap can therefore absorb
about 60 seconds of App non-idleness if navigation then succeeds within its
remaining allowance; no evidence attributes that time exclusively to the host.
Current mode departure uses the shared 60-second guard described in the
[caller formulas and native-action diagnostics](TESTING.md#3-assertions).
Selection-only screenshots and the separate Next/rotation clocks retain their prior behavior.

Accepted residual risk (v3/v4 mode departure): Continue tapped but no navigation,
an unhandled non-password alert over the mode page, and load-only navigation bugs
produce receipts identical to a slow departure. With every required proof field,
they can be yellow once on a CPU-starved night. For historical refunded receipts,
the departure deadline was `D` after Continue returned, rather than the pre-tap deadline's remainder
`max(0, D-C)` for tap duration `C`. An App that remains non-idle for a long time
after Continue and then stays on the mode page for `D` seconds can therefore be
yellow with every required starvation proof. Current guard failures retain the same
step/element and policy eligibility, without tap refunds or any reader change.
Unrecognizable playback, including
the motivating iPad journey-b receipt, still stays red. A night without starvation is red;
two consecutive yellow nights escalate to red. Alternating yellow/pass nights
never auto-escalate, so the coordinator reviews any test that is yellow three or
more times in a week (Hogan, 2026-10-22). Local tests on the pinned devices remain
an independent check. Successful mode navigation clears the failure-context step
and element so later assertions cannot reuse its departure eligibility.

Hogan approved the album exception on 2026-10-22. Its `gate.kind` must be
`album-capture`; `paused`, `entry_hint_hidden` and `manifest_complete` must be
true; `stable` must be false. `advanced` and `layers_changed` must both be true.
Every null, missing or other value is red. The phase/progress
audit deliberately narrows the proposed either-signal rule: hidden incoming
layers can change before any new photo is visible, so `layers_changed` alone is
insufficient. `installHiddenLayerIfNeeded` appends a zero-opacity, not-ready layer;
even `promoteHiddenLayer` starts at zero opacity. History advances only after
`incomingBecameVisible` passes its visibility guard.
The generation UUID in layer IDs means a legitimate `transition` or
`incomingFromLoading` after paused Next also changes the observed layer IDs.
The exact phase set is derived from the App's underlying `ScenePresentationPhase`
(the probe reports `underlyingPhase`, not the `.paused` suspension wrapper):

| Gate phase | Eligibility and source semantics |
| --- | --- |
| `transition` | Eligible with all other gate facts: a ready manual Next photo crossfades before `completeTransition` settles it. |
| `incomingFromLoading` | Eligible with all other gate facts: `beginIncomingFromLoading` marks the target ready and promotes its incoming layer before settling. |
| `grace` | Red: `holdPresentationForManualTarget` keeps the old photo while the hidden manual target decodes; a complete old manifest and changed layers do not prove the new photo loaded. |
| `loading` | Red: the target may still be pending; a complete retained photo does not prove the new target loaded. |
| `empty`, `sourceError`, `unknown`, `stablePhoto`, `paused` | Red: absent/error/unknown evidence or a phase outside the reviewed settling states. |

The source semantics live in `PlaybackSessionEngine+ScenePresentationState.swift`;
`StrictE2ESceneCapture.isStableWindow` also requires `stablePhoto`, a sole stable
layer, full opacity and a complete manifest. `manifest_complete` proves positive
slot count, no pending/failed slots, no gaps/overlaps and complete canvas coverage.
The `slideshow.control.next.button` timeout is a confirmed no-advance branch and
always stays red. First-capture timeouts have no previous scene, so #572 emits
null for both progress facts; this also excludes the first-capture
`rejectFrozenAlbumTransition` failure even when its phase is `transition` and
Pause is true. Post-capture scene assertions and other capture steps stay red.

Accepted residual risk: `advanced` is cumulative across polls. A double advance
(`historyCount = previous + 2`), including autoplay advancing while paused, can
still qualify when the final layer IDs differ and every other condition holds.
The receipt cannot distinguish this from slow settling; no Swift change is made.
The first night without CPU starvation is red, two consecutive yellow nights
escalate to red, and independent strict pause and history cases remain in place.

Policy v2 required a new version because its proof projection carries a new field
and its eligibility differs from v1. The v2 activation moved all new proofs to v2,
including the existing UI availability waits. An older trusted reader
would turn even those existing yellows red, which is why the reader merged first.
There is no CLI override. Retained v1 proofs without a gate continue to validate
under exactly the old table entries; they do not gain the album exception. Unknown versions
remain red. The reader-first rollout required a trusted base containing the
reader; stacking alone did not activate trusted acceptance.

Policy v3 also required reader-first rollout, although its proof shape is unchanged:
retained proofs are revalidated by policy version, so changing the v2 allowlist
would change historical verdicts. The v3 activation moved all new proofs to v3.
Reader support was introduced separately before producer activation; trusted
acceptance requires a base containing that reader. A trusted base without the v3 reader rejects new
proofs, including unchanged UI waits and album settling proofs. Versions v1/v2
retain their verdicts; v3 keeps every v2 entry and its album semantics, adding
exactly the two reviewed `mode-departure` entries. Unknown versions
remain red. No original receipt, raw failure, threshold, deadline, wait or retry changes.

Policy v4 follows the same reader-first rollout with an unchanged proof shape.
The producer now emits v4 for all new proofs. Reader support was introduced
separately before activation; trusted acceptance requires a base containing that
reader, and a stacked draft alone does not establish it. Older readers reject v4 even
for existing UI waits and album settling. Retained v1/v2/v3 interpretations stay
unchanged, and unknown or noninteger versions stay red.

This is an explicit allowlist, not an inference from an exception name. A deadline
left over from a completed wait cannot turn a value or scene assertion yellow.
`scene_identity`, `control_state`, `interval_readback`, validator failures, observed
BLACK/BLANK frames, UNRECOGNIZABLE playback frames, process failures, and all other phase/class/step
combinations stay red. In particular, `history_navigation` / no-advance and
`continue_timing` / `timing_window` mix observable functional outcomes with timing
checks and are excluded. Rotation and pause-window contracts are also excluded
without a separately reviewed timing-only interpretation. The pause-window
*preparation* readiness wait (canvas wake → visible Play/Pause control, mapped
`control_action/hidden_controls` at `query-element` on
`slideshow.control.playPause.button`) is an ordinary hidden-controls UI-availability
wait like the other allowlisted control waits, so it can be environment-limited under
the same starvation proof; the pause-window T±2 and midpoint contract assertions
themselves remain excluded (coordinator ruling, 2026-10-24, under Hogan's approved
policy).

The iOS lifecycle Play/Pause receipt correction (#607) also changes potential
yellow eligibility in both directions without changing the waits themselves.
`Play/pause must be hittable.` and `Play/pause must be hittable before continuing.`
now report the finished 2 s readiness wait as `control_action/hidden_controls` at
`query-element` on `slideshow.control.playPause.button`. Previously, the leaked
outer wait reported the appearance time plus about 2 s against an 8 s deadline;
when the first button observation took less than about 6 s, that wait was not
expired and the failure stayed red. The completed readiness wait can now satisfy
the existing exhausted-wait condition and become yellow under the full hosted
starvation proof. In Release, `control_bar` is `unknown` because the probe is
DEBUG-only, so the visible-control-bar exclusion does not reject these failures.
This affects all five calls through `confirmPlayPauseState` and
`pressContinueStartingClock`: the initial pause, setup pause, midpoint Play,
midpoint pause and final Continue in `ios-lifecycle-pause`.

The same correction tightens later `settings_navigation/navigation` failures.
`Tapping settings must open the settings page.` no longer inherits the leaked
8 s wait: its own outcome wait has a zero deadline only when non-tap work exhausts
the entry budget; the measured wake and Settings tap are returned. That
zero-budget case stays red. Less likely,
`Must return to the playback page after settings.` can now retain an earlier
successful Settings-element wait, or no wait after a later tap, instead of the
leaked expired wait, and also stays red. Capture/continue/hold failures and the
historical `unknown/unknown` capture receipts remain red. The new calibration
prefix is `visible_scene_capture/evidence_capture` and remains outside the
allowlist. Allowlists and policy versions are unchanged. The coordinator accepted
this widening under Hogan's approved policy that pure UI-availability waits may
be yellow on proven-starved hosts, as with the pause-window readiness wait above.

Debug `filter-person` tightens Pause-preparation classification. Its former
`IOSDriver.pause` control-availability timeout could be environment-limited as
`control_action/hidden_controls` at `query-element` or `reveal-controls` on
`slideshow.control.playPause.button`, subject to the full existing proof. The
stable-scene preparation timeout now reports `control_action/timing_window` at
`wait-scene` and always stays red. The coordinator accepted this tightening,
subject to Hogan's override; the allowlists and policy versions are unchanged.
The [strict runner capture contract](CI_STRICT_RUNNER.md) also describes the
remaining stable-check-to-Pause race at the unchanged default 5 s interval.

IOSDriver Next uses the
[shared readiness guard](TESTING.md#next-and-settings-toggle-hang-guards), so fewer
short readiness timeouts can reach yellow. Its conditional yellow eligibility is
unchanged: `ENVIRONMENT_WAIT_STEPS` and `ENVIRONMENT_WAIT_STEPS_V3` allow the
`control_action/hidden_controls` availability wait on
`slideshow.control.next.button`, subject to every existing hosted starvation,
surface and positive expired-budget proof. Allowlists, prefix mappings and policy
versions are unchanged; an original zero-budget receipt gains no eligibility.
Baseline and post-Next scene-identity failures remain red. This applies to every
Next caller, including p2-rotation (`testRotationDuringPlaybackIOS`); its rotation
30-second bound, rotation captures and scene-change assertions also stay red.

IOSDriver Settings preserves the entry remainder after its measured native wake
and Settings tap. A failure formerly reached with zero remaining outcome budget
can now produce a positive, fully expired `settings_navigation/navigation` wait at
`query-element` on `slideshow.control.settings.button`. This changes potential
yellow eligibility under the existing v1/v2/v3/v4 allowlists, only with the required
playback surface, hosted scope and starvation proof. Relative to #607, a Settings
outcome failure whose allowance was exhausted by native taps becomes yellow-eligible
again. A second red-to-possibly-yellow path starts with a wake that formerly
exhausted preparation as `settings_navigation/hidden_controls`: returning that
wake time can admit the Settings tap, followed by an expired allowlisted
`settings_navigation/navigation` wait at `query-element`. Failures that still stop
in preparation as `settings_navigation/hidden_controls` remain red, as do
unknown/unrecognizable surfaces and all rotation/layout-capture or 30-second
rotation-bound failures. Prefixes, markers, allowlists and policy versions do not
change. Restarted waits retain only their non-tap remainder, never a fresh full
allowance. The coordinator accepted both availability-wait paths under Hogan's
pure-availability-wait policy, as with #593, #596 and #607.

Accepted residual risk: Settings and rotation deductions include XCTest's pre-
and post-event waits for the App to idle and can absorb about 60 seconds of App
non-idleness per tap when readiness later succeeds. This does not establish
host-only responsibility. Each `StableFrame` iteration can deduct up to three taps:
the first driver wake, explicit refresh and second driver wake. The inner driver's
3 s readiness deadline is not extended, so long taps can keep readiness false
while extending the outer capture deadline. Only non-tap work bounds the number of
iterations; unlike the old single admitted-iteration overrun, several iterations
can overrun the original wall-clock deadline. The unchanged playback-rotation
30-second product bound still includes that time and can independently fail.
`p2-ipad-layout` has no such 30-second outer bound, only the 600 s warm / 1200 s cold
invocation caps. In the extreme, capture can run to the invocation cap and lose its
`first_failure` receipt; that timeout or missing receipt stays red. No cap is added.

Missing or ambiguous receipts, samples or case bindings stay red; an old night gains no classification.
`firstboot_setup/navigation` also includes a confirmed connection-error alert,
and `mode_selection/navigation` at `query-element` includes an unexpected legacy
control assertion, so neither qualifies. Under v1/v2, `mode-departure` stays red.
Under v3/v4, it may be yellow only with the exact mode-page timing and starvation
proof above; an unexpected destination or any missing evidence stays red.
An unrecognizable photo identity on a known non-playback surface, such as the mode
page, does not by itself assert that the App displayed a wrong photo.

With complete matrix evidence, the accepting strict aggregate uses
`status: environment-limited` and an `environment_limited` identity list when
all nonpassing cases qualify. It exits zero with a prominent warning for every
yellow case and all its sample numbers; raw observations remain `failed` and never
count as passes. Any red case, missing case, infrastructure/cleanup error, failed
matrix job or failed UI aggregate keeps the night red. Exclusively yellow strict
jobs exit zero with per-case workflow warnings while preserving failed receipts and
the producer summary's raw `failed` status; an unrelated job failure must never be
ignored by the aggregate.

The reporter binds every claim to the same case's trace resource entry and official
method receipt, then checks the aggregate list against the shard claims. Existing
log, warm-build/reuse and invocation-infrastructure requirements remain mandatory;
an outer invocation timeout or interruption cannot become yellow. Report tables
and compact history retain the bounded proof and every yellow warning,
including when a red case keeps the overall night failed. They preserve raw failure
counts and add the separate `environment-limited` count. Yellow cannot
satisfy recovery, become a product flake or use a quarantine retry. Existing
`ci-known-flaky.json` entries are unchanged. Timing acceptance still requires local
runs on the pinned devices.

The reporter escalates the same strict method identity (including suite and all
case dimensions) after consecutive UTC yellow nights, using its retained history.
`ENVIRONMENT_YELLOW_NIGHTS_BEFORE_RED = 2` is the single policy constant.
The second and later consecutive yellow nights become red
in the report and use ordinary Issue/notification tracking, while raw outcomes
and the original proof remain unchanged. A missing night or explicit pass breaks
the yellow sequence; another case or a diagnostic run cannot contribute. Yellow
never erases a red failure night or supplies an explicit-pass recovery night.
Nights containing yellow are ineligible unchanged-SHA baselines so the next
scheduled night can collect the evidence needed for escalation.

Retained compact proofs are rechecked under their supported policy version (v1,
v2, v3 or v4). Missing, unknown or obsolete policy versions and invalid proofs degrade to red with a fixed public
reason; rendering, history loading and issue decisions must not raise because of
those proofs. Original first-failure receipts remain outside compact history.

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
