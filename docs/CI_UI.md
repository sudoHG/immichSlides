# UI tier: iPhone, iPad and Apple TV

`ci-ui` runs on pull requests and pushes to `main`, independently of `ci-gate`.
It is informational: only the [trusted publisher](CI_PUBLISHER.md) writes its
commit status. No required check or repository setting changes here. All three
devices use the same archive validation, fixture runner, selection and verdict
path. Packed functional selection was shipped reader first, then activated by the
producer's explicit `--pack-scoped-ui` intent.

Main pushes run the Linux selection jobs and keep the gate's build, unit and host
checks. They run no UI shards: a trusted identical-tree PR verdict is reused, or UI
verification is explicitly deferred to the complete nightly aggregate. Pull
requests keep their fixture UI execution and archive selection.

## Main UI scheduling contract

The trusted reader recognizes `--defer-main-ui` only on the admitted base workflow's
`ci_ui_tests.py select` command (historically `wait-archive`). A completed, successful same-repository main
push with that intent may skip its UI matrix after every required Linux selection
job has published valid, attempt-bound evidence. The publisher first checks the
existing [identical-tree reuse proof](CI_PUBLISHER.md). A valid proof is success
linked to the original PR run; otherwise the UI status is **pending**, explicitly
"UI deferred to nightly", linked to the main nightly workflow. Deferral supplies
no passing UI samples. Missing or invalid selection evidence still fails, and a
workflow without this explicit trusted intent retains the full UI/reuse contract.

The [nightly UI aggregate](CI_NIGHTLY.md#complete-fixture-ui) is the verification of
record for deferred UI. Main build, unit and host checks retain their own verdicts.
Pull-request and nightly population selection is independent of this main-only
contract. Reader changes precede producer activation in a separate PR.

The [grouped Cloud hooks](XCODE_CLOUD_UI.md) remain inactive without reviewed
registration. All pull-request UI runs currently stay on GitHub, including core,
unknown and CI-changing PRs. Each platform has an independent Linux group wait,
so iPhone/iPad start when the iOS provider and archive evidence are ready without
waiting for tvOS. Each wait publishes its own operational summary and gates only
its platform using `!cancelled()`. Invalid retained Cloud proof requires a full
rerun. Independent matrices take concurrency from the trusted
scoped plan, with at most two jobs per device and five UI slots in total. The
planner also models the PR's own gate unit jobs competing for those five slots.

The [nightly fixture UI tier](CI_NIGHTLY.md#complete-fixture-ui) reuses these shard
consumers and complete default-plan populations on all three devices. It consumes
its own run's existing iOS/tvOS archives and always executes every shard, with no
post-merge verdict reuse. Its UI aggregate is independently judged by `ci-report`.

## Classification and archive selection

The Linux `ui-selection` job reads the PR's base classification policy. A docs-only
change outside build membership selects no archive and starts no macOS shard.
The publisher independently derives this classification from admission before
displaying `not applicable`. Unknown paths and CI changes run UI on pull requests.
Main pushes use trusted identical-tree reuse or explicit nightly deferral.

For an app-affecting PR, two independent Linux group waits select Cloud proof or
their own affected platform's `ci-gate` archive within 180 minutes. No archive is
awaited for a verified Cloud group. iPhone and iPad share the iOS archive; Apple TV
uses the tvOS archive. An excluded platform is never awaited. Routing remains
inactive without the reviewed [group registry](XCODE_CLOUD_UI.md#maintainer-morning-checklist-routing-remains-inactive).

Each platform is checked at least once, even if downloading and verifying the
first platform consumed the remaining deadline; an already-ready archive is
checked before the deadline is enforced. Each selection records the configured
`timeout_minutes` and its actual `wait_seconds`.

Selection verifies GitHub's repository, workflow ID/path, event, PR and head;
the successful platform build job's execution attempt; its bound build record; immutable
artifact ID/name; and the downloaded manifest and tar hash. The manifest must
match the full consumer identity, including base, head, merge commit and merge
tree. Runs from another head repository or base are refused and recorded even
when their build failed or was cancelled. The record's source and complete identity
are checked before build success or waiting; only an exact-identity build failure
is fatal. A cancelled run without a record can be refused by its recorded PR base,
but cannot establish an exact identity. No archive is executed on Linux. An expired
or missing exact-identity archive or timeout fails selection. A rerun job cannot
reuse an earlier attempt's archive; a retained
successful build job keeps its original archive and evidence attempt.

Shards download that exact artifact ID/run. They repeat the full
[archive validation](CI_BUILD_ARCHIVE.md), validate architecture, extract and
inspect files/permissions/links, measure the app's ad-hoc signature and require
the original producer source and Products paths to be absent. Products move to
a different absolute path. Xcode runs `test-without-building`, selecting only
the UI target; the shards never build the app again.

## Feature areas and the reader-first rollout

[`scripts/ci-ui-areas.json`](../scripts/ci-ui-areas.json) maps source globs to
exact UI classes or `Class/testMethod` selectors. The map is CI-trusted;
edits require exact-head approval and become selection authority for subsequent
PRs only after merging. The admission's base reader and base map always choose
areas, including when candidate workflow metadata has approval. Source globs match
path segments: `*`, `?` and character classes cannot cross `/`; a standalone `**`
segment explicitly includes zero or more directories.

| Area | Sources and UI coverage |
| --- | --- |
| `settings` | Shared settings host, iOS settings navigation, tvOS settings primitives and playback pages; settings navigation, category checks and flows that edit filters through settings |
| `playback` | Slideshow views, rendering components, controls and tvOS playback pages; playback, history, EXIF, motion, rotation and playback settings |
| `filter` | Album/person editors, summary cards and preview state; selection, summaries, focus, filter editing and filtered playback |
| `access-protection` | PIN entry and tvOS access protection page; PIN gates, protection feedback and lifecycle checks |
| `about-legal` | tvOS about/privacy pages and bundled privacy policy; about, licenses and privacy navigation |
| `onboarding` | First boot, server form components, mode selection, mode cards and onboarding scaffold; setup, mode selection and entry hints |
| `server-connection` | Server form components and tvOS server/cache pages; field input, validation, help and connection feedback |
| `cache` | tvOS server/cache pages; metrics, confirmation and cache clearing |
| `core` | All shared models, playback engine, networking, app entry, platform/layout helpers, localization/assets, project/config files and test support; all functional default-plan methods on PRs, the complete population on full runs |
| `localization` | Both string catalogs; every locale acceptance screenshot method (nightly-default) |
| `localization-settings`, `-about`, `-filter`, `-onboarding`, `-playback` | Only the leaf screen files each locale screenshot family captures; that family's locale methods (nightly-default) |

Multiple memberships are intentional: a settings host change affects its category
flows, a mode selector affects both onboarding and filtering, and the combined
server/cache page affects both areas. Shared model changes select all functional PR tests even when
the model's name mentions one feature. No broad app-directory catch-all hides a
new, unreviewed feature file. An unknown changed path selects all functional PR tests.

Mode selection/cards, the iOS onboarding scaffold and filter-summary containers
are shared launch routes in the default UI flows. Their source globs overlap every
feature area so a settings, playback or about test that traverses setup is retained
when those containers change. Leaf pages keep their feature memberships. The server
forms overlap onboarding, and tvOS playback pages overlap settings; tests that edit
filters or return from playback through settings also belong to settings. Slideshow
hosts and control bars overlap settings because those flows use them to enter
settings. The first-boot launch check belongs to onboarding, and the iPad About
sidebar check that probes the server form also belongs to server/connection.
Review the helpers a test calls,
not just the screen named by its method, when checking these relationships.

The applicable platform's functional smoke set explicitly names
`ServerConfigFormIOSUITests/testIOSFirstBootServerFieldsKeyboardAppear`
(iPhone/iPad) and
`ServerConfigFormTVOSUITests/testTVOSFirstBootCoreElementsAndDisabledSave`
(Apple TV). For ordinary app-affecting PRs the trusted selection is the union of
affected areas plus applicable smoke methods, filtered by the unchanged default
plans, method kind and each path's proven platform. Allowlisted docs-only changes
select no UI. Core, unknown and CI-changing PRs select all functional methods on
all platforms. Every PR excludes screenshots, including locale acceptance methods.
Nightly and other non-PR full runs stay complete. An unavailable or empty diff
selects all functional PR tests, never docs-only proof.

The host workflow-policy check (`--check-ui-shards`, included in `check_all.sh`)
uses `ui_identities` over `immichSlidesUITests` and `TestSupport` on both platforms.
It rejects any unmapped UI identity, including Evidence/strict methods, stale
selectors or unmapped app file, and requires an applicable smoke method in every
device's default plan. Violations identify `scripts/ci-ui-areas.json` with the
`ui-areas` rule. TestSupport is included only in this coverage audit; admission,
producer and shard inventories retain their `immichSlidesUITests` roots.
To add a test, choose the areas whose behavior it
checks and add its class or exact method to their `tests` lists. Class selectors
include future methods; mixed classes use exact methods so new flows need a
reviewed assignment. Add the corresponding source glob for a new app file.
Do not assign a feature to core merely to satisfy coverage; use core when shared
behavior needs full coverage. Cross-area selectors are allowed; duplicates within
one selector list are rejected. The identifier-to-flow check below then confirms the
assignment against the identifiers the test actually uses.

### Scheduling the selection

Pull-request UI runs schedule only the trusted selection. The Linux `ui-selection`
job repeats admission's selection from base data (`planned_ui_selection` in
`ci_ui_tests.py`): the base map, classification policy, project platform proof,
frozen durations and default plans, the `base...head` diff and the tested tree's
UI inventory. It publishes `iphone_shards`, `ipad_shards`, `appletv_shards`, the
canonical packed plan hash, and `run_ios`/`run_tvos`. Each matrix takes its device's list through
`fromJSON(...)` and keeps its `max-parallel` cap, so an empty shard never takes a
macOS runner. A platform with no selected test skips its whole matrix. Each shard
runs only its packed identities in the platform's archive selection record;
`ui-selection.json` records the mode, device lists, keys and complete hashed plan.
CI-changing and unknown-path PRs pack all functional methods. Selection errors
fail closed. Nightly and other non-PR full runs retain duration-balanced v2 shards
and every default-plan method. A main push still skips all matrices when it reuses
a trusted PR verdict or defers UI to nightly (see the
[main contract](#main-ui-scheduling-contract)). Docs-only PRs schedule none.

Admission binds the same lists from its own base reader. The producer cannot widen
or narrow its own population: any difference fails the required-job check.
Publication requires the exact trusted packed set across every device and shard,
with the same plan hash on every infrastructure and UI summary. Historical
unflagged producers retain full-or-exact-selection compatibility; an activated
producer cannot substitute full evidence. Partial, mixed or extra populations fail.
Only independently empty selected shards may be unexecuted literal skips.
Scoped success cannot supply a full post-merge reuse receipt.
GitHub cannot skip one entry of a static matrix, so the reader accepts
[bound dynamic shard lists](CI_PUBLISHER.md#bound-dynamic-ui-shards). The main Cloud
router keeps every group on GitHub while its reviewed registry is absent.
[Grouped Cloud routing](XCODE_CLOUD_UI.md) uses the same functional selection
after separate activation. Nightly and main push deferral retain their contracts;
historical full selections retain the legacy evidence reader.

The nightly full UI tier is the safety net for cross-area regressions. The release
rule still requires a green, release-eligible nightly for the exact release SHA
and its complete required human reviews; a scoped PR result cannot replace it.
See [the nightly contract](CI_NIGHTLY.md) and [publisher trust](CI_PUBLISHER.md).

### Platform selection and capacity packing

The `ci-ui.yml` producer activates the reader's protocol with the literal
`--pack-scoped-ui` flag on its admitted `ci_ui_tests.py select` command (historically `wait-archive`).
The reader landed separately before this producer. Historical unflagged runs
retain their original contract. No assertions, skips, deadlines or default plans change.

The [acceleration reader](CI_PUBLISHER.md#prepared-scoped-ui-acceleration-reader)
landed before the producer's `--scoped-ui-v2` and
`--compiled-from-official-results` activation. Eligible scoped PR shards discover
compiled methods from the first official test result instead of starting a
separate enumeration invocation. Gate host checks run as the base-owned Linux
and short macOS partitions; their union still covers the complete host suite.

With this intent, selection pairs each changed path's areas with its proven
platform. An iOS-only settings file selects iPhone/iPad settings and smoke tests;
a tvOS-only filter file selects Apple TV filter and smoke tests. A mixed diff
unions these pairs rather than running every affected area on both platforms.
Narrowing requires an explicit `platformFiltersByRelativePath` entry attached to
the synchronized app root and app target in the **base** Xcode project. A directory
or filename alone supplies no proof. Missing or unfamiliar project syntax remains
shared. On PRs, methods whose **method name** contains `Screenshot` or `Acceptance`
are screenshot tests; every other method is functional. Class names do not affect
this rule. The host audit applies both predicates to every unfiltered method on
both platforms and rejects an unclassified or ambiguous method. New tests are
classified automatically by their method name and still need reviewed area coverage.
The base map's separate `functional_smoke` uses functional first-boot checks:
`ServerConfigFormIOSUITests/testIOSFirstBootServerFieldsKeyboardAppear` runs on
both iPhone and iPad, and the TV first-boot core-elements check runs on Apple TV.
The host audit rejects smoke methods recorded as an expected baseline fixture
skip on any applicable device. The legacy screenshot smoke remains available
only for historical unflagged producers.
Core, unknown and CI-changing PRs run **all functional methods** on all platforms,
without screenshot or locale methods, even when a catalog or captured screen changes.
The nightly and other non-PR full runs retain the complete default-plan population.

For a scoped run the base reader packs the exact selected methods independently
on each device into `scoped-a` through `scoped-f`. It uses deterministic longest
method first assignment and identity ordering for ties. Separate literal iPhone
and iPad matrices let their different method durations choose different counts.
Their dynamic values are `shard` lists from `iphone_shards` and `ipad_shards`
and the matching device capacity outputs; Apple TV uses `appletv_shards`.
Each device's
count is bounded by `ceil(selected estimated test seconds / 900)`, six shards and
its method count. Candidate counts must fit the existing 28-minute estimated job
budget; impossible packing or classification fails the activated PR admission.
No method is dropped, duplicated, replaced or borrowed from another device.

The `capacity-v2` planner models archive readiness at 270 seconds for iOS and
300 seconds for tvOS, two gate unit consumers finishing at 450 and 750 seconds,
and 60 seconds for trusted publication. Without preliminary enumeration, its
fixed per-job budgets are 345/190/200 seconds for iPhone/iPad/Apple TV.
Each device's `max-parallel` is bound to its base-computed capacity, at most two;
the three limits sum to at most five. The planner chooses the fewest jobs when
predicted push-to-status time fits 30 minutes. Otherwise it minimizes that time,
then runner minutes, within the same caps and records `fits_target: false`.
Predictions do **not** establish a 30-minute pass.
Gate queue time, real test duration and runner overhead still require hosted
measurement. Full/nightly runs retain every existing duration-balanced v2 shard.

With the updated frozen weights, iOS settings selects 29/29/0 methods in 2/2/0
jobs, with a 25:17 push-to-status estimate and 67.5 UI runner-minutes. Apple TV
filter selects 0/0/26 in 0/0/1: 23:33 and 17.5 UI runner-minutes. Shared settings
selects 29/29/34 in 2/1/2: 30:24 and 94.3 UI runner-minutes, so its plan explicitly
misses the target. These include modeled build readiness, this PR's gate unit
occupancy and publication, and assume no external queue. They are estimates,
not hosted acceptance. Core still selects all 51/51/60 functional methods.

[`scripts/ci-ui-durations.json`](../scripts/ci-ui-durations.json) supplies frozen,
per-device method seconds. The initial weights are the maximum observed duration
per method in the latest execution attempts of UI runs
[38051247254](https://github.com/sudoHG/immichSlides/actions/runs/38051247254) and
[38035723923](https://github.com/sudoHG/immichSlides/actions/runs/38035723923), rounded
to milliseconds with a one-second floor. The successor takes the maximum of
those weights and every observed method, including failures, from the settings,
filter and Shared probes [38079041000](https://github.com/sudoHG/immichSlides/actions/runs/38079041000),
[38082318919](https://github.com/sudoHG/immichSlides/actions/runs/38082318919) and
[38083825853](https://github.com/sudoHG/immichSlides/actions/runs/38083825853), including
the unchanged iPad rerun. No existing weight was reduced.
An unseen method receives 120 seconds; weights never determine coverage. This
file is CI-trusted and host-validated. Only base weights can choose a PR's plan,
including an exact-head-approved candidate that edits them. Updating estimates
requires a reviewed data change; it cannot reduce the trusted selected test set.

The publisher binds the packed matrix names and requires each infrastructure and
UI summary to carry the same `hashes.manifests.ui-scoped-plan` hash. Declared,
compiled and observed identities must equal the base plan for that job. An active
packed run cannot substitute legacy full-shard evidence; empty platforms still
declare their devices and admit only an unexecuted collapsed matrix skip. See
[publisher validation](CI_PUBLISHER.md#packed-scoped-ui-protocol).
The producer publishes this plan, carries its exact per-job selectors,
and avoids waiting for or downloading an unselected platform's gate archive.
Archive identity and signature checks remain mandatory for every selected platform.
An earlier build with a different head/base/tree cannot supply a cache shortcut.

The [acceleration reader](CI_PUBLISHER.md#prepared-scoped-ui-acceleration-reader)
requires official-result discovery intent on every shard command before admitting
`capacity-v2`. A shard with an approved base fixture deselection keeps version 1
and preliminary enumeration. Base policy controls only this protocol eligibility;
deselections, expected skips, the local verdict and the policy hash use the tested
tree's policy, which the reader accepts only after exact-head approval. If an
eligible base has no fixture deselection but the candidate adds one for the shard,
the producer fails before simulator or Xcode preflight with an explicit conflict.
Merge that policy change before running the successor protocol for the shard.
An eligible shard with an incomplete first invocation
can write a fail-only version 2 record: compiled equals the discovered subset,
all undiscovered methods remain `not-run` or `timed-out`, and their attempts retain
the nonzero raw first exit. A missing export is recorded as `null`. The final writer
keeps the diagnostics, while the verdict reports missing compiled identities and
fails. Official discovery does not establish a 30-minute acceptance result.
Rejected proofs include their reason in `summary.md` and stderr. Failure attachments
are exported before discovery is parsed. After the sensitive scan passes,
`check-upload` may publish failed diagnostics carrying `discovery-record-invalid`;
ordinary summary metadata must still validate, and the publisher still rejects
the invalid proof. A scan failure blocks diagnostic upload as well.

### Nightly-default locale screenshots

The multi-language acceptance screenshots (Japanese, Spanish, Traditional Chinese
HK/TW) check layout in other languages and remain mapped to the areas listed in
`nightly_default`. Every PR excludes **all** screenshot methods by method name,
even when a catalog, captured leaf screen, core file or CI contract changes.
Those changes retain their affected functional tests; core and unknown paths
select every functional method. The
[nightly full UI](CI_NIGHTLY.md#complete-fixture-ui) runs every locale and
default-language screenshot method, together with every functional method.
Historical unflagged producers retain their earlier area-sensitive locale policy.
No test policy deselection is involved: every method stays in the default plans.
Adding a test to a nightly-default area is a CI-trusted map change; list every such
method in the PR for maintainer approval. The settings-family screenshots also capture
the slideshow frame before opening settings. Its localized content is the control bar,
which belongs to `localization-settings`. The slideshow host files
(`SlideShowViewIOS.swift`, `SlideShowViewTV.swift`) define no identifier those tests
reach, so they select only the playback family's entry-hint screenshots.

### Identifier-to-flow check

The same host step runs [`scripts/ci_ui_flows.py`](../scripts/ci_ui_flows.py) under its
own `ui-flows` rule. For each default-plan UI test on each platform it collects the
dotted identifier literals (`area.element.kind`) the test method reaches, directly or
through helpers, computed properties and stored constants in `immichSlidesUITests` and
`TestSupport`. A bare or `self` call resolves to the caller's own type first, then to
shared helpers outside other test classes; a call on another receiver may reach any
definition with that name. `#if os(...)` branches follow the platform, and an
interpolation matches any text. An app Swift file compiled on that platform defines an
identifier when it contains a matching literal or calls a function whose name ends in
`AccessibilityID`/`AccessibilityIdentifier` that returns one. The test must belong to
one of each defining file's areas or to the smoke set; core files already select the
all functional PR methods and the complete population on full runs. A test only
in nightly-default areas is checked the same way and must
also reach at least one identifier from its own areas' leaf screens; a file it only
traverses on the way to the captured screen must be a reviewed navigation source for
one of its areas. The analysis over-approximates by design, so a false dependency is
resolved by adding the membership, not by weakening the check.

[`scripts/ci-ui-flow-exceptions.json`](../scripts/ci-ui-flow-exceptions.json) holds a
small reviewed list (at most 24) with a one-line `reason` each: an `identifier` from one
`source` file that does not imply a flow dependency (for example a defensive "dismiss
the PIN sheet if shown" branch), a `test` that never launches the app, or a
`navigation` app file with the nightly-default `areas` whose locale screenshots only
pass through it (launch routes, the slideshow control bar, the settings list). A
captured screen belongs in the family's sources, never in this list. An exception that
no longer suppresses anything fails as stale. When the check reports a test, add
the test to one of the named areas; add an exception only with a reason a reviewer can
verify in the helper code.

## Manifest and union

[`scripts/ci-ui-shards.json`](../scripts/ci-ui-shards.json) is the version 2
assignment manifest, named revision `multidevice-method-v2`. Exact method
assignments use the reader shipped in [PR #232](https://github.com/sudoHG/immichSlides/pull/232):

| Shard | Assignment | iPhone / iPad methods | Apple TV methods |
| --- | --- | --- | --- |
| `navigation` | `immichSlidesUITests`, `ServerConfigFormTVOSUITests` | 21 | 6 |
| `visual-a` | Exact methods in the two filter-summary visual classes | 15 | 22 |
| `visual-b` | Exact methods in the two filter-summary visual classes | 16 | 21 |
| `visual-c` | Exact methods in the two filter-summary visual classes | 15 | 22 |
| `visual-d` | Exact methods in the two filter-summary visual classes | 15 | 21 |
| `default` | Every unassigned class/method, including new methods outside class assignments | 21 | 20 |

The named revision describes the assignment. The exact Git revision and
SHA-256 of the manifest bytes identify a reproduction. Every default-plan
identity has exactly one shard. iPhone and iPad share the iOS assignments;
all six shard names remain nonempty on Apple TV. Their complete populations are
103, 103 and 112 identities, respectively.

The trusted reader supports the historical class-only schema version 1 and
schema version 2 with the same fields. Each v2 shard array may assign exact classes or exact `Class/testMethod`
selectors, without parentheses or a target prefix. Duplicate selectors and a
class assignment overlapping any of its method assignments are rejected,
including overlaps within one shard. Unassigned classes and methods go to
`default_shard`; adding a method to a class partitioned by methods therefore
cannot silently omit it. The default plan still filters before assignment.
Version 2 selectors must match the unfiltered iOS/tvOS population union;
unknown classes, deleted methods and misspellings fail admission and host checks.
Removing the last test of a shard, or any method assigned by the version 2
manifest, requires a manifest edit with exact-head approval.
Changing the manifest or matching workflow shards is a CI-changing change
that requires exact-head approval. Full-population consumers, including nightly
UI, must derive their shard names from this manifest. The default plans continue
to describe the whole device population independently of its partition.

The default plan filters the statically declared population before assignment.
Selections plus approved tier deselections must equal that population for the
device. Evidence/strict tests excluded by the plan stay excluded. Each shard
records its declared and compiled identities, observed outcomes and exact skip
reasons; missing, duplicate or unexpected identities fail. Admission derives
and stores these populations using the base revision's shard rules. The publisher
checks that stored shard union and each summary's manifest/default-plan hashes.
A candidate manifest or policy
is effective in the trusted verdict only after exact-head approval.

Both default plans are unchanged. Platform compilation selects the applicable
classes; the partition remains nonempty on every device. Device-scope expected
skips use the existing approved `ui` policy, with exact identity and skip reason.

## Post-merge reuse

On a main push, Linux first looks for the [trusted publisher's UI verdict
receipt](CI_PUBLISHER.md). UI reuse succeeds only for a complete successful
same-repository, non-CI-changing PR verdict on an identical tree, with identical
manifest, default-plan, policy, registry, classification, workflow and pins hashes
and observed toolchains matching those pins. All currently scheduled device
shards must be covered. Fork or approval-based verdicts never qualify; missing,
expired, malformed, red, cancelled, superseded or rerunning verdicts cannot be reused.
Without `--defer-main-ui`, unavailable proof runs UI. With the trusted declaration,
the main UI status is pending and verification belongs to the complete nightly
aggregate, as described by the [scheduling contract](#main-ui-scheduling-contract).
Ordinary PRs do not use this reuse path.
The receipt must name the one same-repository PR actually merged by the pushed
SHA and that PR's final head. A different green head with the same tree cannot
authorize reuse. Linux archive selection receives only `contents: read`,
`actions: read`, `checks: read` and `pull-requests: read`; the last permission supports the
commit-to-merged-PR lookup without granting any write authority.

When reusing a verdict, the archive-selection job still runs and publishes its
bound summary and `archive-selection.json` with `status: reused` and the original
verdict provenance.
Its `run_ui`, `run_ios` and `run_tvos` outputs are `false`, which skips both macOS
matrices. The publisher independently
validates both archive and cloud-selection operational summaries, then
repeats the reuse decision before accepting those skipped jobs; an arbitrary
producer skip, partial skip or failed selection job cannot become green.
For execution, `archive-selection-ios.json` and `archive-selection-tvos.json`
bind each platform's immutable artifact ID, producer run/attempt and manifest.
Real identical-tree green/red post-merge exercises require maintainer-controlled
merges; unit contract fixtures do not replace those acceptance runs.

## Fixture execution, retry and public output

The workflow passes an explicit infrastructure wait factor and publishes its
scanned configuration record. Product timing never scales; see
[test waits and the raw literal ratchet](TEST_WAITS.md).

The shards use [fixture set C and the existing UI runner](CI_FIXTURE_UI.md),
without a real server, private configuration or changed test assertions. They
retain default simulator signing, pinned toolchains and runtime fixture inputs.
Only each job's pinned device simulator is created and deleted.

Fixture UI runners use the [shared simulator reset](CI_STRICT_RUNNER.md#shared-simulator-reset),
including its clean-install requirements, preparation bounds and timing logs.

`--listed-only-retry` reads the PR's first-parent registry, never the candidate
registry. Only a listed, unexpired assertion failure can receive a second,
exact-method `test-without-building` call after app reset. No global retry or
iteration flags are used. Both official attempts and invocations remain in the
records. A passing retry is `flaky-passed`; an unlisted failure, skipped/crashed/
missing retry or reset failure remains failed. Reset failures preserve attempt
1's observations and `retry-invocations.json`, and record infrastructure failure.
An official-result read error records `official-result-read-failed` with its
exception type and a bounded message. Validated completed cases survive an
incomplete result; only missing official cases stay `not-run`. Exit 124 marks
the invocation `timed-out` and records `xcodebuild-timeout`, so partial passes
cannot turn a timed-out shard green. Result export timeouts additionally record
`xcresult-export-timeout`; infrastructure errors never obtain a retry.
The [registry contract](TESTING.md#known-flaky-registry-and-listed-only-retries)
defines ownership and expiry.

The prepared UI target requests screenshot capture and retains failed-test
attachments; the archived `.xctestrun` and unit target stay unchanged. Failed
XCTest attachments are exported only from public fixture runs. The
unchanged sensitive scanner checks the records and attachments, and repeats
immediately before publication. A failed scan prevents both record and screenshot
uploads. Failure screenshots have 7-day retention; PR records have 30 days and
main records 7 days. Raw result bundles, Xcode logs and runtime launch inputs
stay on the private result path and are never uploaded. Successful bundles are
disposed; failed bundles remain quarantined until reviewed and deleted locally.

## Capacity, timeouts and measurement

Scoped pull requests bind only their non-empty selected shards with base-computed
per-device limits: at most two each and at most five in total. The five-slot model
includes gate unit occupancy; it does not reserve runners or remove queue time.
Non-scoped `ci-ui` retains two/one/one limits; nightly retains its independent
cap of two and complete duration-balanced partitions. Every matrix retains
`fail-fast: false`, so a failed shard does not suppress another selected shard.
Host policy checks require every admitted partition and exact capacity. Each shard list is either
the ordered manifest keys or the bound archive output that admission resolves.
Independent device matrices let iOS start without waiting for Cloud selection;
only Apple TV waits for that decision.
Apple TV still executes after an iOS failure when cloud proof is absent.
Superseded runs
cancel only within the same PR. First-attempt main pushes share one group per
workflow with `cancel-in-progress: false`: a run waiting in the group is replaced by
the next push, a started run finishes ([coalescing rules](CI_PUBLISHER.md#main-push-coalescing)).
The Linux selection timeout is one 120-minute deadline shared by both archive
platforms, extended by up to 50 minutes in total while the same-head gate run is held
pending, inside a 185-minute job. Xcode calls
have a 65-minute timeout and share an 85-minute shard budget inside a 110-minute
job. The earlier visual invocation consumed 2,643 seconds of its 2,700-second
budget and was stopped at 2,715 seconds in [the hosted run](https://github.com/sudoHG/immichSlides/actions/runs/37796334799/job/113382323589).
A subsequent control completed all 61 visual cases in 3,097.84 seconds of shard
wall time, [exit 65 with one EXIF assertion](https://github.com/sudoHG/immichSlides/actions/runs/37798609844/job/113394133806).
The larger infrastructure budget preserves product assertions and observation
windows; partitioning does not change those allowances.

The four visual partitions use completed hosted per-method durations, including
failures and approved skips. The frozen selectors cover all 61 iOS and 86 Apple TV
visual methods in those baselines; later unassigned methods go to `default`.
No assertion, default plan, approved skip or device was removed.

| Hosted run | Device | Complete visual methods | Shard wall (min) | Non-method overhead (min) | Raw exit |
| --- | --- | --- | --- | --- | --- |
| [37894467497](https://github.com/sudoHG/immichSlides/actions/runs/37894467497) | iPhone | 61 | 41.04 | 4.73 | 65 |
| [37878587213](https://github.com/sudoHG/immichSlides/actions/runs/37878587213) | iPad | 61 | 48.69 | 8.52 | 65 |
| [37943119387](https://github.com/sudoHG/immichSlides/actions/runs/37943119387) | iPhone | 61 | 50.70 | 8.97 | 65 |
| [37943119387](https://github.com/sudoHG/immichSlides/actions/runs/37943119387) | iPad | 61 | 66.76 | 7.95 | 65 |
| [37943119387](https://github.com/sudoHG/immichSlides/actions/runs/37943119387) | Apple TV | 86 | 58.26 | 2.79 | 65 |

For each method, take its maximum duration across these runs on its platform.
Sort by descending duration, then exact method identity; assign to the partition
with the smallest accumulated duration, breaking ties by shard order. Freeze
the resulting selectors in the manifest. New unassigned methods go to `default`.
Apple TV is balanced separately into the same four names; iPhone and iPad share
the iOS balance. The non-method overhead is shard wall time minus the sum of
observed method durations.

Four is the smallest shared partition count whose projections stay within
about 25 minutes on every measured baseline, retaining the entire original
non-method overhead for each partition. Three projects up to 28.97 minutes on
the latest iPad baseline. Four projects at most 19.99 minutes on iPhone, 24.22
on iPad and 16.84 on Apple TV. These are conservative sizing estimates; the
[producer PR #247](https://github.com/sudoHG/immichSlides/pull/247) reports real
partition measurements and complete official results.
On a full run at concurrency three, the twelve iOS jobs require at least four
waves; the six Apple TV jobs run sequentially. A single feature area usually still
binds all eighteen jobs: the visual partitions are balanced by duration, not by
area, so an area's tests appear in most partitions and each job runs fewer tests. The matrices can overlap; only Apple TV
waits for Cloud selection. Shared-runner queueing and archive selection still
contribute to full-matrix feedback; [PR #247](https://github.com/sudoHG/immichSlides/pull/247) measures that latency and
its overlap with the gate rather than claiming a 30-minute result from sizing
alone. Scoped pull requests schedule fewer, non-empty shards; their
[selection](#scheduling-the-selection) decides the job count. [PR #247](https://github.com/sudoHG/immichSlides/pull/247)
includes all 147 methods' measured maximum durations and partition loads.

The archive wait shares the repository's `GITHUB_TOKEN` budget of 1,000 requests per
hour with every other workflow. Both `ui-cloud-wait-ios` and `ui-cloud-wait-tvos`
use the same archive selector: it checks immediately, then every 30 seconds for
the first 10 minutes of archive selection, covering the measured 4–6 minute build
window. It then backs off at 60, 120, 240 and 300 seconds. Artifacts are listed only
after the platform build job completes; workflow, run, attempt, identity, manifest
and hash checks still apply to every selected archive. The pins hash is read once
per selection and reused in its receipt; run and job metadata remain fresh on every poll.

With one matching run, one attempt and one page per listing, an unfinished PR
build costs two setup requests (workflow and PR), then two per poll (runs and
jobs): 44 requests through 10 minutes, or 116 over the critical-path waits'
180-minute timeout, compared with 82 under immediate exponential backoff
(34 additional requests per platform). A ready archive adds three requests
(artifact listing, build-record ZIP and archive ZIP); pagination, additional runs
or attempts, and rate-limit retries add requests. Two platform waits therefore
cost 232 requests for that 180-minute unfinished-build scenario, versus 164 before.
Polling alone adds at most 30 seconds of discovery delay during the fast window;
API reads, archive downloads and job scheduling add their own time. Queueing that
outlasts the fast window can still incur the 300-second interval.

A read refused for a documented rate limit (`Retry-After`, an exhausted
`x-ratelimit-remaining`, or the secondary-limit response) waits for the reset inside the
remaining deadline and then continues, as does the archive download; the Cloud wait opts in
the same way, while the router, importer and dispatcher do not. Any other refusal, and
every write, still fails immediately.

Hosted shards pass `--result-export-timeout-seconds 180`; local commands retain
60 seconds. The 60-second `xcresulttool get test-results tests` limit expired
in [the default control](https://github.com/sudoHG/immichSlides/actions/runs/37798609844/job/113394133909),
so the hosted allowance is bounded at three times that observed limit and is
checked against fresh run measurements. Each compact official export records
elapsed time and its bound in `export-timing*.json`; normalized result reading
records its per-attempt total in `export-read-timing.json`. Shard timing also records
the bound. Local disk checks retain 80 GiB; only hosted jobs pass the existing 30 GiB
allowance. No simulator runtime is downloaded or installed.

The platform selection records include selection wait, producer run/attempt and refused
identities. `shard-timing.json` records shard wall time, caps, timeouts and exit
code. The PR/main workflow passes its actual strategy cap to `--max-parallel`;
nightly retains the runner's default of two. The PR links final real runs and reports workflow wall time and gate
latency, with job queue time separately, including overlapping PRs. Platform wall
time is the span from its first shard start to its last shard finish; shard wall
and queue times are reported separately. These are
measurements, not a promise of reserved capacity: the shared macOS queue can
delay every tier. Gate completion never depends on UI completion.

## Reproduce one shard

From a checkout containing the producer, this one command snapshots the current
working tree (including uncommitted and untracked, non-ignored files), builds once
without private configuration, starts the fixture server and runs the selected
shard. It records the tested tree in `local-snapshot.json` and `reproduction.json`,
and prints the exact build, shard and Xcode test commands. Before
building it reads that revision's pins, freezes the locally selected Xcode path, verifies its
version/build, and checks the assigned UDID's exact runtime version/build and
device type. The local Xcode bundle path may differ from hosted macOS; version
and build must still match. A missing or mismatched pin fails before any build:

```bash
python3 -B scripts/ci_ui_tests.py reproduce \
  --device ipad --shard visual-c --destination 'platform=iOS Simulator,id=<assigned-UDID>' \
  --wait-factor 2 --output-dir '<fresh-outside-repo>'
```

Use the same Python environment as [CONTRIBUTING](../CONTRIBUTING.md#setup).
`--wait-factor 2` matches hosted infrastructure budgets; product deadlines and
observation windows remain fixed. See [test waits](TEST_WAITS.md). Omit the option
to use the local default factor `1`, including historical revisions without factor support.
Check `df -h /System/Volumes/Data` first. Use a dedicated simulator and a bounded
command. Only the assigned simulator is used; no new local simulator is created. The temporary checkout and
build products are removed after the command; public records remain for review.
Clean those records and any task-owned quarantined failure bundle after recording
the necessary results in the PR. An output directory must be fresh and outside
the source checkout. A revision must contain the producer and manifest.
Use `--device iphone` for iPhone (also the backward-compatible default), or
`--device appletv` with `platform=tvOS Simulator,id=<assigned-UDID>` for Apple TV.
Reproduction builds only the selected device's platform and verifies that device's
exact runtime and device-type pins before the build.

Pass `--manifest-revision COMMIT_SHA` to explicitly reproduce that historical
tree instead of the working tree. Use `--strict-ci` to refuse local changes.
For a packed PR shard, retain `ui-selection.json` from that run's archive artifact
and pass `--shard scoped-a --selection-path '<retained-selection>/ui-selection.json'`.
The command validates its tested tree, canonical plan hash and exact device selectors
before building, and records the same plan hash on every per-test summary. Choose the
matching tested tree with `--manifest-revision` when reproducing a historical run.
An existing private `Config/env.xcconfig` symlink is left untouched and excluded
from the snapshot. Ambient test configuration is ignored; the fixture runner
injects only public set C runtime inputs. Fixture preflight starts its server
before the fixture runner's build/enumeration and fails if it cannot become ready.

To reuse a previously verified secret-free build locally:

```bash
python3 -B scripts/ci_ui_tests.py run --device iphone --shard visual-b \
  --manifest-revision COMMIT_SHA --destination 'platform=iOS Simulator,id=<assigned-UDID>' \
  --xctestrun '<verified-products>/<default-plan>.xctestrun' \
  --wait-factor 2 --output-dir '<fresh-outside-repo>'
```

This direct mode also snapshots the checkout by default, excluding private
`Config/env.xcconfig` files and symlinks. It selects the manifest revision's selectors against the current default
plan; use `reproduce` to reproduce the whole historical tree. CI accepts only its
admitted current manifest and the verified archive path. Commands exit nonzero
for failed/incomplete coverage, infrastructure, unapproved skips or privacy
failure; a policy approval and required-status promotion remain maintainer gates.
For a historical version 1 manifest, use its original `visual` shard name.
