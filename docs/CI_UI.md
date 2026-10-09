# UI tier: iPhone, iPad and Apple TV

`ci-ui` runs on pull requests and pushes to `main`, independently of `ci-gate`.
It is informational: only the [trusted publisher](CI_PUBLISHER.md) writes its
commit status. No required check or repository setting changes here. All three
devices use the same archive validation, fixture runner, selection and verdict
path. The trusted reuse reader must land on main before this producer is activated.

## Classification and archive selection

The Linux `ui-archive` job reads the PR's base classification policy. A docs-only
change outside build membership selects no archive and starts no macOS shard.
The publisher independently derives this classification from admission before
displaying `not applicable`. Unknown paths, CI changes and main pushes run.

For an app-affecting change, Linux shares one 120-minute deadline while selecting
`ci-gate`'s iOS and tvOS builds. iPhone and iPad share the iOS archive; Apple TV
uses the tvOS archive.

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

## Manifest and union

[`scripts/ci-ui-shards.json`](../scripts/ci-ui-shards.json) is the version 1
class-assignment manifest, currently named revision `multidevice-v1`:

| Shard | Assigned classes |
| --- | --- |
| `navigation` | `immichSlidesUITests`, `ServerConfigFormTVOSUITests` |
| `visual` | `FilterSummaryIOSVisualUITests`, `FilterSummaryTVOSVisualUITests` |
| `default` | Every other or newly introduced class |

The named revision describes the assignment. The exact Git revision and
SHA-256 of the manifest bytes identify a reproduction. Class extensions keep
their class assignment. Every class has exactly one shard; duplicate class
assignments, unknown schema versions or a missing default shard fail.

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
receipt](CI_PUBLISHER.md). UI is skipped only for a complete successful
same-repository, non-CI-changing PR verdict on an identical tree, with identical
manifest, default-plan, policy, registry, classification, workflow and pins hashes
and observed toolchains matching those pins. All currently scheduled device
shards must be covered. Fork or approval-based verdicts never qualify; missing,
expired, malformed, red, cancelled, superseded or rerunning verdicts run UI.
Ordinary PRs do not use this reuse path.
The receipt must name the one same-repository PR actually merged by the pushed
SHA and that PR's final head. A different green head with the same tree cannot
authorize reuse. Linux archive selection receives only `contents: read`,
`actions: read` and `pull-requests: read`; the last permission supports the
commit-to-merged-PR lookup without granting any write authority.

The archive-selection job still runs and publishes its bound summary and
`archive-selection.json` with `status: reused` and the original verdict provenance.
Its `run_ui` output suppresses the entire macOS matrix. The publisher independently
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

The nine device/shard jobs share `max-parallel: 2` and `fail-fast: false`. Superseded runs
cancel only within the same PR; main pushes and unrelated PRs are not cancelled.
The Linux selection timeout is 120 minutes inside a 130-minute job. Xcode calls
have a 65-minute timeout and share an 85-minute shard budget inside a 110-minute
job. The earlier visual invocation consumed 2,643 seconds of its 2,700-second
budget and was stopped at 2,715 seconds in [the hosted run](https://github.com/sudoHG/immichSlides/actions/runs/37796334799/job/113382323589).
A subsequent control completed all 61 visual cases in 3,097.84 seconds of shard
wall time, [exit 65 with one EXIF assertion](https://github.com/sudoHG/immichSlides/actions/runs/37798609844/job/113394133806).
The larger infrastructure budget preserves product assertions and observation
windows. [Splitting the large visual class](https://github.com/sudoHG/immichSlides/issues/176) is follow-up work.

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
code. The PR links final real runs and reports workflow wall time and gate
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
  --device ipad --shard visual --destination 'platform=iOS Simulator,id=<assigned-UDID>' \
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
An existing private `Config/env.xcconfig` symlink is left untouched and excluded
from the snapshot. Ambient test configuration is ignored; the fixture runner
injects only public set C runtime inputs. Fixture preflight starts its server
before the fixture runner's build/enumeration and fails if it cannot become ready.

To reuse a previously verified secret-free build locally:

```bash
python3 -B scripts/ci_ui_tests.py run --device iphone --shard visual \
  --manifest-revision COMMIT_SHA --destination 'platform=iOS Simulator,id=<assigned-UDID>' \
  --xctestrun '<verified-products>/<default-plan>.xctestrun' \
  --wait-factor 2 --output-dir '<fresh-outside-repo>'
```

This direct mode also snapshots the checkout by default, excluding private
`Config/env.xcconfig` files and symlinks. It selects the manifest revision's classes against the current default
plan; use `reproduce` to reproduce the whole historical tree. CI accepts only its
admitted current manifest and the verified archive path. Commands exit nonzero
for failed/incomplete coverage, infrastructure, unapproved skips or privacy
failure; a policy approval and required-status promotion remain maintainer gates.
