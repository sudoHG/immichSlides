# Xcode Cloud Apple TV fixture UI

The **UI - Apple TV (overflow)** workflow runs the same pull-request Apple TV
fixture methods as the GitHub UI shards. It is test-only, accepts an API or manual
start on a branch, and uses the `immichSlides-tvOS` scheme with the
`XcodeCloud-UI-tvOS` plan on Apple TV 4K (3rd generation), tvOS 27.0. Workflow
configuration belongs to the maintainer. Only the trusted main router and API
importer described below can replace GitHub's pull-request Apple TV evidence.

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
archive actions only. Build-for-testing does not start a fixture process.
For the tvOS scheme's `test` or `test-without-building` action,
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
dispatches the fixed main router with the producer ID and attempt. In-progress
events do not dispatch again; non-PR sources are successful no-ops. This
five-minute bridge has no environment or ASC secrets and alone receives
`actions: write` for the two fixed dispatches. A successful routed router
completion dispatches the importer after uploader validation. GitHub documents
[`workflow_dispatch` as an exception for events sent using `GITHUB_TOKEN`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).
The resulting dispatch-to-`workflow_run` chain still needs runtime proof on main.

The main-only router has two Linux jobs. The short `xcc-start` job holds the
account budget concurrency group while deciding, uploading a reservation, starting
or reconciling one build, and uploading the start result. The separate poll job
uses a producer/attempt concurrency group and never holds the account start lock.
Both use `cancel-in-progress: false`: a running job is retained, but GitHub can
replace an older **pending** job in the same group. A replaced router cannot
authorize a skip; its producer falls back when no complete decision appears.

A reservation binds the admitted head/tree, producer ID, archive evidence attempt,
branch reference, reservation time and pre-start build inventory. Its immutable
main-authenticated artifact is uploaded **before POST**. Failed or interrupted
main attempts can supply reservation state, with workflow, event, repository,
main ancestry and historical uploader attempt authenticated before reading bytes.
After an uncertain POST, subsequent routers reconcile the fixed workflow's build
collection and never blindly POST again. Missing source commits, multiple matches,
expired state or unavailable inventory keep the reservation unresolved.
A known terminal build releases its account reservation. An unresolved or running
reservation blocks other starts until reconciliation.

Routing requires trusted `app_affected is True`, a same-repository current PR,
matching head/merge tree and the admitted exact population. It also requires at
least **five running macOS jobs** and one macOS job queued for **120 seconds**,
measured across repository attempts using `xcode-27` and `macos-*` runner labels.
Before POST, the producer must still be authoritative, its cloud selection must
be open, and at least **110 minutes** must remain in the **115-minute** budget
measured from `ci-ui.run_started_at`: 100 for Cloud and ten for import.

The account cap is **45 compute hours** including the proposed 100-minute build.
Usage scans every accessible product and all actions of runs that can overlap the
current UTC calendar month, including failed actions. Completed runs ending before
the month are not scanned. Never-started actions cost zero; each unfinished run
reserves at least 100 minutes, counting actual action time if greater. Missing or
inconsistent inventory/timing fails closed. The accounting window resets at
00:00 UTC on the first of the month; correspondence with Apple's billing month is
`NOT_RUN` until runtime acceptance.

ASC tokens are signed on first use and renewed after eight minutes before each
API request. Reads retry 429, 5xx and timeouts with exponential backoff within the
deadline. POST is never automatically retried. Each poll rechecks the producer
and selection, and stops on completion or supersession. Cloud completion also
waits for the newest matching app check to complete with this Cloud run's link
before method validation. Failed starts/runs, refused evidence and deadlines
produce a GitHub fallback decision. The published
[ASC API specification](https://developer.apple.com/app-store-connect/api/)
exposes no build cancellation operation: an unconfirmed terminal state keeps the
persistent account reservation and blocks new starts, rather than claiming a
cancellation or refund. The independent main importer repeats the API validation.

`ui-archive` only waits for the two normal gate archives. iPhone and iPad shards
start when the archive is ready. A separate Linux `ui-cloud-wait` job gates only
Apple TV and supplies its own operational summary; it runs after the iOS shards
so failed-job reruns refresh that selection too. It checks complete trusted proof
before checking the deadline, allowing Cloud to finish while iOS runs.
GitHub Apple TV uses `!cancelled()`, so cancellation cannot start new macOS work.
It runs all three original shards unless the current selection validates Cloud;
the publisher repeats the full trust check independently of the producer output.

Route/import run names include the producer ID and evidence attempt. The Linux
wait immediately returns GitHub for inactive workflows or a matching finished
route/import with no valid artifact. Polling backs off from 60 to 300 seconds,
with one admission/attempt lookup and small bounded run pages, keeping concurrent
waits below the repository token's 1,000 requests/hour budget. Missing workflows,
missing artifacts, importer failure, stale checks and timeout cannot authorize
skips. Main pushes and forks select GitHub without waiting for Cloud.

Failed-job reruns bind proof to the attempt that executed `ui-archive`, identified
by its GitHub execution timestamps and runner (or unchanged job ID when those
fields are absent). GitHub may regenerate retained job IDs on a rerun.
A retained archive with complete valid proof reuses that
same proof and starts no additional Cloud or GitHub TV work. Without valid proof,
the new Linux selection requires GitHub TV. Routers never start Cloud for an
attempt that retained the archive. A historical collapsed TV skip supplies no
test evidence; without Cloud proof, subsequent literal TV execution is required.
Do not manually rerun route/import workflows: dispatch for the producer/evidence
attempt instead. Receipts are validated against
`actions/runs/<uploader>/attempts/<uploader_attempt>`, while failed or incomplete
latest uploader runs remain unacceptable verdict sources.

To disable routing, prefer a reviewed main change setting
`ROUTING_ENABLED = False` in `scripts/ci_xcode_cloud_route.py`: this publishes a
prompt GitHub decision. Disabling the GitHub route or import workflow also causes
an immediate GitHub choice once the Linux selection runs. Disabling the bridge
leaves active workflows with no matching run, so the Linux wait can consume the
remaining 115-minute budget before fallback. None changes the Xcode Cloud
workflow; already started Cloud work retains its account reservation.

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
ID through a main-only manual/API dispatch, including the credential-free bridge's
dispatch after successful main router completion.
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
