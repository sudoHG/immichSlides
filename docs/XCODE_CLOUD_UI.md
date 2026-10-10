# Xcode Cloud fixture UI

The historical **UI - Apple TV (overflow)** workflow ran the same pull-request Apple TV
fixture methods as the GitHub UI shards. It is test-only, accepts an API or manual
start on a branch, and uses the `immichSlides-tvOS` scheme with the
`XcodeCloud-UI-tvOS` plan on Apple TV 4K (3rd generation), tvOS 27.0. Workflow
configuration belongs to the maintainer. Only the trusted main router and API
importer described below can replace GitHub's pull-request evidence. New routing
is inactive until the grouped registry is reviewed and installed.

## Prepared grouped evidence reader (v2)

The reader supports a separate, **inactive** v2 protocol for functional PR tests:
`ios` covers both iPhone and iPad; `tvos` covers Apple TV. The grouped producer,
router and importer are prepared, but no registry is installed and no new Cloud
builds are dispatched. Historical v1 Apple TV evidence remains readable. ASC
configuration and activation require the maintainer's separate rollout.
Part of #283 and Part of #83.

Activation requires a later reviewed `scripts/ci-xcode-cloud-groups.json` on the
PR's trusted base, with `schema_version: 2` and a `groups` object. Each registered
group has a real ASC `workflow_id` and an `actions` list. Each action specifies
`name`, the exact GitHub App `check_name`, repository-relative `plan_path` and
`scheme_path`, and `devices`: a mapping from `iphone`, `ipad` or `appletv` to
exact ASC `{device, os}` labels. Actions must partition the whole group's devices;
workflows, check names and plan templates cannot overlap. No placeholder workflow
UUIDs or unverified device labels are installed by the reader PR. The coordinator
registers workflows after maintainer-approved ASC changes and API readback.

Admission reads this registry only from the verified base. It hashes every
`ci_scripts/` blob, the Cloud scripts, selection/packing/kind/shard rules, area map,
duration data, fixture source/copy and registered schemes/plans. These must be
regular Git blobs with the same bytes on the PR head and base; extra hooks,
symlinks, case shadows and redirected plans refuse Cloud eligibility. Head tree
must equal the admitted merge tree. The author comes from the authenticated PR
API; only `sudoHG` (numeric ID `279902076`) same-repository PRs qualify. Forks, external PRs and nightly
sources cannot supply v2 Cloud evidence. Invalid Cloud eligibility leaves complete
GitHub evidence usable.

`ci_xcode_cloud_groups.selection` reconstructs the immutable selection descriptor.
It contains the admission identity (repository, PR, base, head, merge and tree),
producer run and evidence attempt, group, registry entry, trusted file hashes,
base area-map hash, packed-plan hash, exact identities per device and canonical
runtime-plan hashes per action. Selection requires the base-derived packed
functional protocol. A runtime plan is the trusted template with one enabled UI
target, sorted exact `Class/testMethod()` `selectedTests`, and empty `skippedTests`.
The template byte hash and generated plan hash are distinct. The descriptor and
runtime plans use SHA-256 over UTF-8 JSON with sorted keys, compact separators,
ASCII escaping and no non-finite values. An action shared by iPhone/iPad requires
equal method selections; different selections require separate registered actions
and plans. An empty or partially empty group stays on GitHub.

The trusted main publisher writes the public status context when routing is enabled:
`ci-xcc-selection/<producer-run>/<evidence-attempt>/<group>` on the exact head.
Its description is `Selection only: <base-sha> <descriptor-sha256>` and target is the fixed
repository URL for the admitted merge commit. The reader accepts only a success
from `sudohg-ci[bot]`, numeric user ID `339382712`, returned by that head's status
endpoint with its exact API URL. It binds the route's `pointer_id` to the newest
trusted status ID and refuses conflicting or ambiguous pointer history. A public
pointer grants no artifact or uploader trust by itself. Its success state records
selection bookkeeping, never a test result or a substitute for `ci-ui`.

The v2 wire artifacts are `ci-xcc-route-<run>-<attempt>-<group>/route.json` and
`ci-xcc-import-<run>-<attempt>-<group>/cloud.json`. Both retain the existing
main-only router/importer authentication **before opening artifact bytes**:
fixed workflow path/ID, same repository, `workflow_dispatch` on main, uploader
SHA in main history, successful exact uploader attempt, bounded ZIP/JSON parsing,
nonexpired and unambiguous artifact. Identical importer reuploads remain readable.
Each JSON carries `schema_version: 2`, `identity`, `producer_run_id`,
`producer_attempt`, `group`, `selection_sha256`, `pointer_id`, `uploader_run_id`
and `uploader_attempt`. A routed decision
also carries `decision: routed`, `workflow_id`, `cloud_run_id` and
`runtime_plan_sha256`. An import additionally carries `route_artifact_id`, the
complete `selection` descriptor, `runtime_plan_sha256` and ASC `evidence`. Every binding is rechecked against
admission; no receipt count, candidate registry or arbitrary URL is authoritative.

Each build must resolve the exact head, explicitly be a branch build rather than
a PR merge build, and complete successfully. Registered TEST actions and their
newest exact-head Xcode Cloud App checks (app ID `117084`, slug `xcode-cloud`)
must pass and link to the exact build/action. Every paginated method and
destination must succeed; duplicate API results, duplicate identities on one
device, missing/extra methods or destinations, different OS versions, skips and
unknown outcomes refuse the whole group. The same method on iPhone and iPad is
two required identities. Action intervals must fit inside the run. `action_minutes`
sums action wall durations; `compute_upper_minutes` sums each action duration
multiplied by its registered destination count. The latter is an upper bound,
not measured billing. Compiled counts remain `NOT_EXPOSED_BY_API`.

Publication requires each group to have either complete GitHub summaries or one
complete Cloud proof. Groups may choose different providers; partial evidence
within a group cannot be combined. Routed GitHub shards must be completed literal
skips with no runner and no steps, and must supply no UI summaries. A missing or
invalid Cloud proof cannot turn these skips green. If GitHub instead executes all
required selected shards, stale/failed Cloud artifacts are not read and complete
GitHub evidence can pass. Each Linux group wait releases its whole group to
GitHub on a start, timeout, import or proof failure. Missing proof identifies the
group and lists its selected identities as `NOT_RUN` in publisher diagnostics.

The prepared reader also recognizes a Linux `ci_ui_tests.py select --pack-scoped-ui`
anchor (`ui-selection`), independent of the GitHub archive, and optional
`wait-group --group ios|tvos` summaries (`ui-cloud-wait-ios|tvos`). The existing
archive anchor remains supported; exactly one selection anchor is required.
Dynamic matrices may bind the existing `needs.archive.outputs.<scope>_shards`
or `needs.selection.outputs.<scope>_shards`, with the same exact base-derived
lists and per-device bounds. The PR producer uses this independent selection and
two group waits; nightly retains its complete GitHub archive protocol. Separate device matrices must have distinct literal name prefixes
so collapsed skips identify their device; ambiguous skips fail closed. Retained
selection executions bind their original evidence attempt. A later GitHub rerun
must execute after a historical collapsed Cloud skip.

Delivery order is reader merge, producer/router/importer PR, then approved ASC
configuration/readback and real-run acceptance. v1 full Apple TV history remains
readable and is never reinterpreted as scoped or iOS coverage. Real v2 iPhone/iPad,
mixed-group routing, pointer production and failure/budget acceptance are `NOT_RUN`
until the later rollout; this preparation is not completion of #283.

## Group scheduling and accounting

Linux `ui-selection` derives the base-owned functional packed plan immediately.
`ui-cloud-wait-ios` and `ui-cloud-wait-tvos` independently verify imported Cloud
proof or wait for their own matching GitHub gate archive. iPhone/iPad share one
iOS archive. Every fallback retains the exact selected methods; an excluded
platform is never awaited. Main pushes retain explicit nightly deferral, nightly
runs all default-plan tests on GitHub, and forks/external authors never route.

`ci_xcode_cloud_schedule.py` simulates five repository-visible macOS slots from
live assigned jobs and ready queued jobs. Static UI duration estimates use the admitted
base's `scripts/ci-ui-durations.json`, default-plan population and static shard
assignments, with the same device startup overhead as trusted packing. Static
jobs use their shard estimate; scoped jobs use the median of at most 100 recent
successful assigned scoped jobs for their device family (iPhone, iPad or Apple TV).
Without scoped samples, the estimate uses the 120-second lower bound instead of
packing's 28-minute cap, so uncertainty shortens the GitHub forecast. Unknown static shard suffixes use
the device family's largest static shard. These are predictions for another
PR's unknown selection; scoped medians reflect earlier jobs, not this PR's runtime. Skipped jobs and unexpanded UI
template names cannot remove this model. Non-UI jobs use successful job duration
p90s from at most three recent runs of each of `ci-gate`, `ci-ui`, `ci-nightly`
and `ci-toolchain`; publisher/privacy runs cannot displace these samples.
Any macOS job without duration samples, including nightly, live, review, probe
and tracer jobs, also uses the 120-second lower bound. This can underestimate
GitHub waiting and cannot increase Cloud spending through missing history.
Per-device UI caps are two iPhone, one iPad and one Apple TV. A queue job without
known labels or fewer than five assigned macOS jobs keeps GitHub.
Account-wide free slots and exact FIFO order are not exposed; predictions state
this limit. The newest same-head `ci-gate` run supplies the archive dependency:
`build-<platform>` is ready at zero if successful, or at its simulated completion
using remaining p90 when running. Unit jobs wait for their own platform build;
not-yet-created units are included from that dependency. The receipt records each
gate finish and `archive_ready_seconds`. Future UI work for the other platform
group is not modeled, as recorded in `other_group_ui`; visible running jobs from
either group still consume slots. Selected UI jobs share those slots and retain
their per-device caps.
Cloud includes 13 minutes of build time, per-destination selected test estimates,
startup overhead, a registered queue allowance and three minutes for import.
Destinations and actions are estimated serially unless their separate
`destinations_parallel` / `actions_parallel` registry flags are verified true.
Normal routing requires `Cloud + 2 minutes < GitHub` and an idle Cloud workflow
for that group. Predictions are saved with the route receipt, not reported as
measured wall times.

The start job holds the shared account lock and refreshes head, pointer, queue,
inventory and budget immediately before its single POST. Reconciliation scans
only route runs created in the last two hours, once per preparation. Its count
limit comes from the measured remaining core rate budget: run-list pages
(at most 100 runs each), 16 estimated requests per scheduling attempt and a
200-request reserve must fit. The per-attempt estimate covers artifact lists,
both receipts' authentication/download in both checks and admission/producer
lookups. At 1,000 remaining requests, the observed peak of 46 runs fits; a lower
budget, incomplete or changing pages, duplicate runs, or the filtered-list
1,000-result ceiling selects GitHub. Retained scheduling artifacts identify
older attempts after a router rerun; their exact attempts remain authenticated
and each consumes the same allowance against a freshly measured budget.
Excluding the current uploader never excludes its older markers.
The start refresh reuses authenticated history and duration samples under
the same lock. These bounds limit scan pressure on the shared 1,000-request/hour
repository token; exceptional artifact pagination and concurrent consumers can
still exhaust it, which selects GitHub. A persisted, authenticated reconciliation
ledger is the long-term way to avoid scan cost growing with window traffic
(Refs #297); this slice does not introduce one.
The Linux group waiter reads just one page each of route/import runs, filtered
to creation after the producer attempt start minus five minutes. Its polling
delay doubles from 60 seconds to a maximum of 300 seconds. Missing final import
proof still selects GitHub within the existing 110-minute deadline.
A complete refreshed ASC workflow inventory remains the source of active
compute evidence. Missing history, pagination or API limits select GitHub. The policy cap is
2,700 compute minutes, reduced when the confirmed account allowance is smaller.
Missing confirmed `cap_minutes`, a valid Apple `billing_anchor`, an explicit
per-group `queue_seconds_upper` or a reviewed `asc_visibility_delay_seconds` returns the
group to GitHub before reading ASC inventory; a UTC-only estimate cannot start it.
Admission uses destination wall-time accounting across every reviewed product
and workflow, including failed actions and active work; unknown configuration,
missing inventory or missing timestamps refuses a new start. `R` is the selected
destination wall estimate multiplied by 1.3, plus five minutes, rounded up to
five minutes. Normal starts require `usage + R + 120 <= cap`. Both the UTC month
and confirmed Apple billing period are checked. `billing_anchor` stores the
confirmed recurring day of month (1–31) and IANA `time_zone`; boundaries are local
midnight, clamping the day to the last day of shorter months. Current windows
are derived on each decision, so UTC and Apple usage reset automatically at their
respective boundaries without a monthly registry change. Confirm this model
matches the actual account renewal; a different renewal rule needs a reviewed
implementation before activation. In the final three UTC days,
only a confirmed matching expiry window removes the 120-minute reserve and
reduces the comparison margin to zero; Cloud still must be faster.

An authenticated before-POST marker reserves work if POST outcome is unknown.
Its reservation is recomputed from trusted admission while visibility is pending.
No POST retry is automatic. The start phase records the actual instant immediately
before invoking POST. Reconciliation uses that time for an ambiguous POST rather
than the earlier arm time, allowing ten seconds of clock skew and requiring a
unique match. Arm writes a local `post_attempted: false` start record before the
marker; start atomically replaces it with `post_attempted: true` and the actual
POST time before calling ASC. The always-upload step depends on arm's output,
so interruption before start produces unposted evidence even without start
outputs. Every phase derives its deadline from the same actual runner job start,
leaving two minutes of the 20-minute start job for artifact upload. An authenticated
main start that refused before POST (including a superseded producer or other error),
a definitive 4xx or unique visible matching build allows reconciliation. Once
the marker's bounded start deadline plus the reviewed ASC inventory visibility
delay has elapsed, a complete inventory with no possible matching build proves
the start absent under that reviewed visibility bound. A late same-head build or
a row with unknown commit in that interval blocks this absence proof. This is
inventory evidence, not marker expiry.
The delay must be explicitly reviewed as 60–3,600 seconds; verify the bound before
activation. The two-hour scan covers the 30-minute producer start window,
20-minute start job and at most 60-minute visibility delay. Outside it, accepted
builds remain covered by full account inventory. Successful but stale ASC
inventory beyond the reviewed delay can violate this assumption; the API exposes
no guaranteed maximum visibility lag. Reconcile this operational risk before
activation. Unresolved markers block further starts. Active work uses
a reviewed upper reservation, at least `110 * largest destination count + 5`
minutes, increasing with elapsed time. The API exposes action elapsed time rather
than billing totals, and cannot bound a stalled service's final charge or cancel
that build. This guard controls new starts; it cannot guarantee the final bill
stays below 45 hours. Other app/release usage and API scope must be reconciled
by the coordinator before activation.

To disable grouped routing, delete the registry or set `routing_enabled: false`
in a reviewed main change. That stops new dispatches; cancel already dispatched
route runs separately. Already started Cloud builds continue to run and bill,
and their inventory still counts toward usage. GitHub executes the complete
trusted selection whenever complete Cloud evidence is unavailable.

## Maintainer morning checklist (routing remains inactive)

No runtime placeholder registry is committed. The iOS ASC workflow UUID, exact
action/check names and device/runtime labels are deliberately unset. The optional
`XcodeCloud-UI-iOS` template is attached to the iOS scheme without changing its
default plan; its explicit one-method seed is replaced by a verified pointer
before every Cloud test build. The existing tvOS template is replaced likewise.

1. With the maintainer-approved App Manager key, create the test-only iOS workflow
   and read back both platform workflows. Use `immichSlides-iOS` /
   `XcodeCloud-UI-iOS` and `immichSlides-tvOS` / `XcodeCloud-UI-tvOS`; no archive,
   release, automatic PR/nightly trigger, repetitions or global retries. Select
   pinned iPhone, iPad and Apple TV destinations. Read back **no custom or secret
   environment variables** on either test workflow: app and test code executes
   from the PR, so hook validation cannot protect workflow-level secrets. Pin
   Xcode and simulator runtimes to `scripts/ci-pins.json`, and select a fixed
   macOS **27.0**, matching the established [fixed Cloud environment](XCODE_CLOUD_TESTFLIGHT.md#exact-workflow-settings)
   and pinned toolchain (never Latest). If either fixed version is unavailable,
   stop and report it rather than substituting Latest.
   The pins do not currently encode a macOS version, so record and review that
   explicit ASC selection too. Allow manual branch starts for any PR branch.
   Confirm destination parallelism
   and exact GitHub App check names with a real controlled run. Workflow creation
   and editing stay with the coordinator; router/importer only read and start.
2. Read back real workflow and SCM repository UUIDs, all accessible account product
   IDs and every account workflow. Confirm the key covers all billable activity,
   the allowance and recurring billing anchor; never copy credentials into the
   registry. The tvOS group must reuse the existing Apple TV workflow UUID
   (`WORKFLOW_ID` in `scripts/ci_xcode_cloud.py`), allowing retained v1 POST
   markers and started builds to reconcile; do not substitute a new workflow.
   The existing Developer runtime key must separately prove read/start/results
   access to the new iOS workflow. Editing permission does not prove runtime scope.
3. Prepare a reviewable `scripts/ci-xcode-cloud-groups.json` with `schema_version: 2`,
   initially `routing_enabled: false`, `groups` as described above,
   `scm_repository_id`, `account_product_ids`, `account_action_destinations`
   (conservative counts by action name), `unknown_active_minutes`, `cap_minutes`
   and a confirmed `billing_anchor: {day, time_zone}`. It also requires
   `asc_visibility_delay_seconds` (60–3,600): establish a conservative bound for
   accepted starts appearing in complete workflow inventory, including interruption
   probes; do not activate without that evidence. Each group also needs
   `workflow_attributes_sha256` (canonical hash of all GET workflow attributes)
   and `queue_seconds_upper`. Set `destinations_parallel` / `actions_parallel`
   true only after observed concurrency proves that prediction; absent/false
   uses serial timing. `account_workflow_attributes_sha256` maps every
   account workflow UUID to the same attributes hash. Any configuration drift
   disables new starts. Review the destinations/counts and inactive registry first.
4. After the producer is reviewed and merged, enable routing in a separate reviewed
   registry change. A trusted-base registry is mandatory; a PR cannot activate its
   own candidate registry. Run real exact-head iOS-only settings, tvOS-only filter
   and Shared selections under a busy queue, plus free-slot, margin, low-budget,
   month-end, fork/nightly, start failure, missing proof and mixed-provider full
   rerun cases. Record exact method/destination equality, current App checks,
   importer/publisher URLs, measured wall time and labeled compute upper bounds.
   Confirm complete GitHub fallback and that missing evidence cannot pass `ci-ui`.

Cloud's branch-start API cannot inject per-run test selections or an exact commit
SHA. `ci_scripts/cloud_selection.py` reads only fixed public GitHub APIs, proves
the selected base is on main, loads allowlisted base Python from Git objects and
recomputes the descriptor from static checkout data before writing plans. It
rejects advanced branches, changed hooks, stale pointers or differing merge trees.
No ASC key, private server or candidate generator is used in the Cloud hook.
Per-device selections that differ require separately registered actions/plans;
an unregistered iOS workflow, uncertain queue or unverified billing window cannot
be substituted with invented identifiers or evidence.

## Population and fixture environment

The source population is the statically declared tvOS UI target, filtered by
`immichSlides-tvOS.xctestplan` and partitioned by `scripts/ci-ui-shards.json`,
with the approved `ui`/`fixture` deselections from `scripts/ci-test-policy.json`.
The cloud plan lists every executed method explicitly; it contains only the UI
target. The existing default plan stays the scheme default. See
[the GitHub UI tier](CI_UI.md#manifest-and-union) for shard and approval rules.

The cloud plan passes these public runtime inputs:

| Input | Value |
| --- | --- |
| `IMMICH_TEST_SERVER_URL` | `http://127.0.0.1:8765/api` |
| `IMMICH_TEST_API_KEY` | `immichslides-public-e2e-key` |
| `IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID` | `album-c-exif` |
| `IMMICHSLIDES_TEST_WAIT_FACTOR` | `2` |
| `UI_TEST_EXPECT_PLATFORM` | `tvOS` |

The app runs in Simplified Chinese, matching the default plan. Infrastructure
waits scale; product deadlines and observation windows do not. No test assertion,
rendering behavior, skip policy, real-server configuration or signing mode changes.
There are no global retries or test repetitions. Failures remain failures.

## Cloud hooks

`ci_post_clone.sh` keeps the existing secret-free pinned archive preflight for
archive actions. For manual build-for-testing actions it verifies the trusted
selection pointer and materializes the exact per-action functional plan from
base-owned Git objects, using isolated system Python; no valid pointer fails the
action. Build-for-testing does not start a fixture process.
For either iOS or tvOS scheme's `test` or `test-without-building` action,
`ci_pre_xcodebuild.sh` starts fixture set C on loopback port 8765 using isolated
system Python, and requires readiness within 60 seconds. A failed start fails
the action and stops its process. `ci_post_xcodebuild.sh` verifies and stops that
action's fixture process, then removes its temporary state. Other actions leave
the fixture untouched. Both hooks require the Xcode Cloud environment.

Xcode Cloud makes `ci_scripts/` available to the test action even when the source
checkout is absent. `ci_scripts/fixture_server.py` is an exact committed copy of
`scripts/strict_e2e_server.py`; it needs only the Python standard library.
When updating the source server, regenerate the copy byte for byte in the same
change. Neither directory ships in the iOS or tvOS app.

## Drift checks and proof

`python3 -B scripts/check_xcode_cloud_ui.py`, included in `check_all.sh`, fails
on a missing, extra or duplicate cloud method, a changed fixture copy, unexpected
targets, configuration overrides, skips, repetitions, fixture inputs or scheme
registration. It derives the expected method list with the existing static parser
and GitHub shard rules; counts alone do not establish coverage. When the default
population changes, regenerate the cloud plan's exact selections in the same PR.
Schemes and test plans at every path are CI-trusted inputs. This
classification must land on main before routing is activated, because admission
uses the PR base's policy; a candidate cannot grant its own approval.

For a cloud proof, start the existing overflow workflow on the reviewed PR branch
through the App Store Connect API. Verify its resolved commit SHA, workflow ID,
action results and all paginated test results. Compare every executed method
identity and outcome against the source shards; retain missing, extra, duplicate,
failed and skipped methods in the report. Record run wall time from started to
finished, and compute minutes as the sum of action durations. A completed green
cloud check alone cannot prove the population. Raw result bundles and logs can
contain test inputs; keep them private and do not attach them to a public PR.

## Routing and trust rollout

`ci-xcode-cloud-dispatch` handles `ci-ui` **requested** events on main and
dispatches the fixed main router with the producer ID and attempt. Non-PR
sources are successful no-ops. This five-minute bridge has no environment or
ASC secrets and receives `actions: write` only for the fixed router dispatch.
The router's separate, credential-free `dispatch-import` job follows a successful
recorded poll and dispatches the fixed importer for a current routed producer.
Authenticated GitHub and fallback decisions finish this job without dispatching;
only a routed decision requires a terminal Cloud build.
It authenticates the main router, its attempt, successful poll job and unique
artifact before opening the decision. Its only write permission is `actions: write`.
The documented
[`workflow_dispatch` exception for events sent using `GITHUB_TOKEN`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)
permits both API dispatches.
The automatic importer dispatch still needs runtime proof on main.

The main-only router has three Linux jobs. The short `xcc-start` job holds the
account budget concurrency group while checking the ASC inventory, starting
or reusing one build, and uploading the start result. The separate poll job
uses a producer/attempt concurrency group and never holds the account start lock.
Both use `cancel-in-progress: false`: a running job is retained, but GitHub can
replace an older **pending** job in the same group. A replaced router cannot
authorize a skip; its producer falls back when no complete decision appears.

The fixed overflow workflow's ASC build inventory is the sole source of truth
for in-flight builds and projected usage. Before starting, the router reuses the
newest existing build for the exact head, even if it is already complete. Otherwise,
any non-`COMPLETE` overflow build blocks a start until **three hours** after its
ASC `createdDate`. A stuck older build stops blocking but still counts at least
100 minutes, or its actual elapsed action minutes if higher. Missing or invalid
inventory fails closed. A terminal build for another head no longer blocks
starts; it still cannot supply accepted test evidence.

An immutable **about-to-POST marker** uploads successfully before the start step
can POST. The marker and start receipt bind the producer ID, archive evidence
attempt and admitted identity, with main workflow provenance authenticated before
opening bytes. They schedule waiting only; they are never quota state. A POST HTTP
4xx is a definite rejection; 5xx, network errors and timeouts leave an uncertain
outcome and send the current producer's Apple TV tier to GitHub immediately.
The poll does not try to recover an uncertain POST from inventory. A router never
retries its POST. A later router reads the ASC inventory
and reuses a visible exact-head build. A rare duplicate during ASC visibility lag
is accepted: the global start lock, one in-flight rule and 45-hour cap bound this
risk once builds are visible. Test acceptance still verifies the chosen run's
exact head, population and newest app check independently.

The remainder of this section describes the historical v1 router. Its CLI no
longer starts new builds; the grouped policy above replaces it after activation.
Without a reviewed active registry, pull-request UI runs on GitHub only.
Functional packing makes every app-affecting PR
[scoped](CI_PUBLISHER.md#bound-dynamic-ui-shards), including core, unknown and
CI-changing PRs; the historical router returned `scoped-ui-selection` for them.
Nightly and main-push scheduling are unaffected. The historical full-selection
overflow protocol below requires trusted `app_affected is True`, a base selection
that is not scoped, a same-repository current PR,
matching head/merge tree and the admitted exact population. It also requires at
least **five running macOS jobs** and one macOS job queued for **120 seconds**,
measured across repository attempts using `xcode-27` and `macos-*` runner labels.
Before POST, the producer must still be authoritative, its cloud selection must
be open, and no more than **30 minutes** may have passed since
`ci-ui.run_started_at`. The router poll remains bounded to 100 minutes.

The account cap is **45 compute hours** including the proposed 100-minute build.
Usage equals completed and elapsed running/pending action minutes in the current
UTC calendar month across every accessible product, including failed actions.
Each non-`COMPLETE` overflow build counts as **max(100 minutes, its completed plus
running/pending elapsed action minutes)**, without counting those minutes twice.
This includes stuck builds and builds created in an earlier month. Completed
runs ending before the month are not scanned. Never-started actions cost zero. A terminal
`SKIPPED` or `CANCELED` action with no start timestamp also costs zero. Missing or
inconsistent inventory/timing fails closed; a `COMPLETE` build with any unfinished
action refuses a start until a later router re-reads a consistent snapshot. The
accounting window resets at 00:00 UTC on the first of the month; correspondence with Apple's billing month is
`NOT_RUN` until runtime acceptance.

ASC tokens are signed on first use and renewed after eight minutes before each
API request. ASC and GitHub reads retry 429, 5xx and timeouts with exponential
backoff within the deadline. A failed Linux poll round has no conclusion and
keeps waiting. POST is never automatically retried. Each poll rechecks the producer
and selection, and stops on completion or supersession. A superseded producer
logs one line and exits successfully without a new start or verdict; a
failed/cancelled poll cannot start the downstream dispatch job. Cloud completion also
waits for the newest matching app check to complete with this Cloud run's link
before method validation. Failed starts/runs, refused evidence and deadlines
produce a GitHub fallback decision. The published
[ASC API specification](https://developer.apple.com/app-store-connect/api/)
exposes no build cancellation operation. A fallback does not cancel or refund
Cloud work; its ASC inventory state continues to count under the rules above.
The independent main importer repeats the API validation.

The `ui-archive` job only waits for the two normal gate archives, within the
[bounded archive-selection deadline](CI_UI.md#capacity-timeouts-and-measurement).
iPhone and iPad shards start when the archive is ready. A separate Linux `ui-cloud-wait` job gates only
Apple TV and supplies its own operational summary; it depends only on the archive,
so it never serializes iOS and TV. Their concurrency limits are documented in
[UI capacity](CI_UI.md#capacity-timeouts-and-measurement).
Cloud selection checks complete trusted proof before checking the deadline,
allowing Cloud to finish while the gate archive is built.
GitHub Apple TV requires the archive job to succeed and uses `!cancelled()`, so
archive failure or cancellation cannot start new macOS work. Linux cloud-wait
immediately selects GitHub when the archive conclusion is not success, preserving
the publisher's neutral `archive_blocked_ui` path.
Apple TV runs the shards admission bound for the run: every manifest shard
(`default`, `navigation`, `visual-a` through `visual-d`) for historical full
selections, or the packed functional shards for current app-affecting PRs. Until
#283 lands, every PR UI run stays on GitHub, so none uses Cloud overflow; nightly
and main-push scheduling are unaffected. A historical full run skips its TV shards
when the current selection validates Cloud;
the publisher repeats the full trust check independently of the producer output.

Route/import run names include the producer ID and evidence attempt. The Linux
wait immediately returns GitHub for inactive workflows or a matching finished
route/import with no valid artifact. Polling backs off from 60 to 300 seconds,
with one admission/attempt lookup and small bounded run pages, keeping concurrent
waits below the repository token's 1,000 requests/hour budget. Missing workflows,
missing artifacts, importer failure, stale checks and timeout cannot authorize
skips. GitHub reads retry transient errors, and a failed round keeps waiting.
Admission fetches main once per cloud-wait run; all later receipt ancestry checks
use that snapshot. Git command failures select GitHub. Main pushes and forks
select GitHub without waiting for Cloud.

With no start receipt but a matching main-authenticated POST marker, selection
waits at most the **20-minute `xcc-start` timeout** from the marker for `start.json`.
If the POST response omits `createdDate`, a retried ASC GET obtains it before the
start receipt is written. Without a build or marker, including a full rerun with
no manual route task, selection immediately chooses GitHub. There is a small
residual race if selection runs before the marker has uploaded: GitHub starts
and later Cloud work cannot authorize skipping it.

Once a start receipt is available, the deadline is strictly **Cloud creation +
1.3 × 69 minutes + 10 minutes** (99.7 minutes from ASC `createdDate`). Queueing
uses the same budget, with no `startedDate` extension. Complete trusted proof is
checked before that deadline.

Failed-job reruns bind proof to the attempt that executed `ui-archive`, identified
by its GitHub execution timestamps and runner (or unchanged job ID when those
fields are absent). GitHub may regenerate retained job IDs on a rerun.
A failed-iOS-job rerun retains successful Cloud selection and Apple TV jobs,
reusing complete valid proof without starting additional TV work. If that
retained Cloud proof becomes invalid, a **full rerun** is required; the fresh
selection chooses GitHub unless a matching manual main route has already started
a valid build. Routers never start Cloud for an attempt that retained the archive.
A historical collapsed TV skip supplies no test evidence; without Cloud proof,
subsequent literal TV execution is required.
Do not manually rerun route/import workflows: dispatch for the producer/evidence
attempt instead. Receipts are validated against
`actions/runs/<uploader>/attempts/<uploader_attempt>`. The named historical attempt
must have succeeded independently of an in-progress, failed or cancelled latest
attempt; the latest run supplies only trusted provenance before opening bytes.

The following switch belongs to the historical v1 Apple TV router only; it does
not control grouped v2 routing. Use the grouped disable procedure above for new
dispatches. Historical v1 routing used a reviewed main change setting
`ROUTING_ENABLED = False` in `scripts/ci_xcode_cloud_route.py` to publish a
prompt GitHub decision. The current CLI refuses all new v1 starts. Disabling the GitHub route or import workflow also causes
an immediate GitHub choice once the Linux selection runs. Disabling the bridge
leaves no matching started build, so the Linux selection chooses GitHub
immediately. None changes the Xcode Cloud
workflow; already started Cloud work remains in the ASC inventory and usage.

For deterministic acceptance on an ordinary app PR, the maintainer may set the
repository variable `CI_XCC_ROUTING_OVERRIDE` to one reviewed head and mode:

| Value | Effect |
| --- | --- |
| `<40-lowercase-hex-head>:force-congestion` | Bypass only measured congestion |
| `<40-lowercase-hex-head>:github` | Record the GitHub decision |
| `<40-lowercase-hex-head>:force-start-failure` | Bypass congestion and submit an invalid branch reference |

Set the variable **before pushing** that exact ordinary app head, let its
requested event dispatch the main router, and remove the variable after the
decision. Other heads use automatic congestion; malformed values fail closed.
All admission, population, remaining-budget and quota guards still apply.
For forced fallback, use a fresh app head with the last mode, verify the real
ASC 400/404/422 rejection in its trusted receipt, then verify all three GitHub
TV shard populations and the final publisher verdict. The diagnostic cannot
create a valid Cloud build or authorize a skip. A main-only manual dispatch also
accepts producer ID, archive evidence attempt and `mode: github` or
`mode: force-start-failure` before any decision exists.

The `xcode-cloud` environment is main-only and holds `ASC_ISSUER_ID`, `ASC_KEY_ID`
and `ASC_PRIVATE_KEY`; creating/changing it and repository variables is maintainer
work. PR code never receives those credentials. The trusted workflows must land
on main before ordinary app-head routed/non-routed/fallback acceptance runs.

## Trusted importer and acceptance

`ci-xcode-cloud-import` accepts a same-repository PR's authoritative `ci-ui` run
ID through a main-only manual/API dispatch, including the router's credential-free
dispatch after a successful poll. The importer waits up to two minutes for the
router workflow to finish, repeatedly using the strict successful-uploader reader;
an in-progress or failed uploader never supplies accepted evidence.
It checks the full admitted identity,
archive evidence attempt, exact current PR head and the successful main router's
artifact before reading App Store Connect. Its protected job checks out main,
executes only the allowlisted importer, has read-only GitHub permissions, and
finishes within ten minutes. It signs a ten-minute ES256 token on use and renews by age; the private
key crosses a pipe to OpenSSL and is never stored or logged. No PR checkout,
artifact execution or PR-controlled environment input can reach the key.

The admission records the head's cloud plan, its SHA-256, fixture/source hashes
and Git tree. The head tree must equal the admitted GitHub merge tree. A moved
base or different merge tree causes GitHub fallback, since Xcode Cloud starts a
branch head rather than GitHub's synthetic merge commit. The strict plan validator
compares its exact methods and fixture environment with the admitted Apple TV
shard union and approved fixture deselections. The copy must match its source.
Admission also records the head's tvOS scheme and every same-name plan path in
the head tree listing. Admission refuses cloud inputs if any two full head-tree
paths are equal under case folding, preventing a case-insensitive checkout from
substituting a shadow plan, scheme or hook. The reader requires one cloud reference resolving exactly
to `container:XcodeCloud-UI-tvOS.xctestplan`, no other same-name file, and no
TestAction pre/post actions. Redirected or ambiguous plan resolution is refused.
API `isPullRequestBuild` must be explicitly false: only the tree-bound branch
execution is accepted, never an unbound cloud pull-request merge build.

The API reader proves membership in overflow workflow
`72574ec0-c168-4317-b469-d3090357ab21` through its paginated build-run collection;
Developer keys cannot read a build run's nonexistent workflow relationship.
It requires one completed successful `XcodeCloud-UI-tvOS - tvOS` test action and
all paginated method results. Every exact method must occur once with `SUCCESS`
on exactly Apple TV 4K (3rd generation), tvOS 27.0. Missing, extra, duplicate,
failed, skipped, partial or unknown results are refused. Pagination cycles,
cross-host links, oversized payloads and unavailable API data are refusals too.

Acceptance separately requires GitHub's completed successful check from the
Xcode Cloud app (ID 117084, slug `xcode-cloud`), with the exact head, overflow check
name and App Store Connect run/action link. Another app, check, workflow, head
or an ambiguous check cannot count. The newest API check ID among checks with
the same app, name and head is authoritative before run/action binding is checked.
A newer failed, cancelled, incomplete or differently bound check prevents an
older success from counting. The app check alone proves no population.

The importer uploads `ci-xcc-import-<producer-run>-<attempt>` only after complete
validation. Publisher and PR diagnostics verify the uploader's workflow ID/path,
same repository, main-history revision, successful latest attempt and artifact
binding to the admitted identity and exact router artifact. They repeat the method
comparison using the independently selected admitted policy and re-read current
app checks. Uploader event, repositories, successful completion and main-history
revision are authenticated before any artifact bytes are opened; an untrusted
uploader, including a fork branch named main, is ignored. Receipts must name that
uploader's authenticated historical attempt. Import success grants no head approval: existing CI-change/fork
approval rules remain authoritative. A failed or missing importer cannot excuse
a GitHub Apple TV skip. Stale attempts and conflicting or expired artifacts fail
closed. Multiple trusted import receipts are accepted only when their complete
content is identical apart from uploader run/attempt, including the same route
artifact and API evidence; the smallest immutable artifact ID is reported.
Routing decisions remain unique. Only literal unexecuted Apple TV skips are excused; GitHub archive,
iPhone and iPad evidence still require their full original populations.
If GitHub collapses a TV-only matrix skip into its expression-named job, the
reader expands only that TV matrix after independent cloud validation, retaining
the original unexecuted job. An iOS matrix or overlapping executed shard cannot
be covered by this normalization.

API evidence stays separate from GitHub producer summaries. Counts report every
admitted and observed Apple TV method; compiled inventory is
`NOT_EXPOSED_BY_API`, since the API does not expose a separate bundle enumeration.
Wall minutes use run timestamps; compute minutes sum action durations. Cloud PR
reports retain Apple TV removals against the admitted base and every applied
fixture deselection; an explicitly owned deselection is reported separately from
source removal. Diagnostics receive the proof already verified for the verdict,
avoiding a second network read that could contradict that evaluation.
Verdicts do not create main-push UI reuse receipts. Daily reporter history remains
main-push only, and refuses cloud PR proof for a push. To disable acceptance,
disable routing; normal GitHub Apple TV jobs need no cloud credentials or receipts.
