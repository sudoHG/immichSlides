# iPhone UI tier tracer

`ci-ui` runs on pull requests and pushes to `main`, independently of `ci-gate`.
It is informational: only the [trusted publisher](CI_PUBLISHER.md) writes its
commit status. No required check or repository setting changes here. iPad and
Apple TV producers are a separate rollout; the reader supports their device
dimensions but this workflow schedules only iPhone.

## Classification and archive selection

The Linux `ui-archive` job reads the PR's base classification policy. A docs-only
change outside build membership selects no archive and starts no macOS shard.
The publisher independently derives this classification from admission before
displaying `not applicable`. Unknown paths, CI changes and main pushes run.

For an app-affecting change, Linux waits up to 45 minutes for `ci-gate`'s iOS
build. It verifies GitHub's repository, workflow ID/path, event, PR and head; the
successful `build-ios` job's execution attempt; its bound build record; immutable
artifact ID/name; and the downloaded manifest and tar hash. The manifest must
match the full consumer identity, including base, head, merge commit and merge
tree. A same-head archive from another base is refused and recorded. No archive
is executed on Linux. An expired or missing archive, failed build or timeout
fails selection. A rerun job cannot reuse an earlier attempt's archive; a retained
successful build job keeps its original archive and evidence attempt.

Shards download that exact artifact ID/run. They repeat the full
[archive validation](CI_BUILD_ARCHIVE.md), validate architecture, extract and
inspect files/permissions/links, measure the app's ad-hoc signature and require
the original producer source and Products paths to be absent. Products move to
a different absolute path. Xcode runs `test-without-building`, selecting only
the UI target; the shards never build the app again.

## Manifest and union

[`scripts/ci-ui-shards.json`](../scripts/ci-ui-shards.json) is the version 1
class-assignment manifest, currently named revision `iphone-v1`:

| Shard | Assigned classes |
| --- | --- |
| `navigation` | `immichSlidesUITests` |
| `visual` | `FilterSummaryIOSVisualUITests` |
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

## Fixture execution, retry and public output

The shards use [fixture set C and the existing UI runner](CI_FIXTURE_UI.md),
without a real server, private configuration or changed test assertions. They
retain default simulator signing, pinned toolchains and runtime fixture inputs.
Only this job's pinned iPhone simulator is created and deleted.

`--listed-only-retry` reads the PR's first-parent registry, never the candidate
registry. Only a listed, unexpired assertion failure can receive a second,
exact-method `test-without-building` call after app reset. No global retry or
iteration flags are used. Both official attempts and invocations remain in the
records. A passing retry is `flaky-passed`; an unlisted failure, skipped/crashed/
missing retry or reset failure remains failed. Reset failures preserve attempt
1's observations and `retry-invocations.json`, and record infrastructure failure.
The [registry contract](TESTING.md#known-flaky-registry-and-listed-only-retries)
defines ownership and expiry.

Failed XCTest attachments are exported only from public fixture runs. The
unchanged sensitive scanner checks the records and attachments, and repeats
immediately before publication. A failed scan prevents both record and screenshot
uploads. Failure screenshots have 7-day retention; PR records have 30 days and
main records 7 days. Raw result bundles, Xcode logs and runtime launch inputs
stay on the private result path and are never uploaded. Successful bundles are
disposed; failed bundles remain quarantined until reviewed and deleted locally.

## Capacity, timeouts and measurement

The iPhone matrix has `max-parallel: 2` and `fail-fast: false`. Superseded runs
cancel only within the same PR; main pushes and unrelated PRs are not cancelled.
The Linux selection timeout is 45 minutes inside a 50-minute job. Xcode calls
have a 45-minute timeout and share a 70-minute shard budget inside a 95-minute
job. Local disk checks retain 80 GiB; only hosted jobs pass the existing 30 GiB
allowance. No simulator runtime is downloaded or installed.

`archive-selection.json` records selection wait, producer run/attempt and refused
identities. `shard-timing.json` records shard wall time, caps, timeouts and exit
code. The PR links final real runs and reports workflow wall time and gate
latency, with job queue time separately, including overlapping PRs. These are
measurements, not a promise of reserved capacity: the shared macOS queue can
delay every tier. Gate completion never depends on UI completion.

## Reproduce one shard

From a checkout containing the producer, this one command reads the specified
manifest revision from a disposable clean checkout, builds once without private
configuration, starts the fixture server and runs the selected shard:

```bash
python3 -B scripts/ci_ui_tests.py reproduce --manifest-revision COMMIT_SHA \
  --shard visual --destination 'platform=iOS Simulator,id=<assigned-UDID>' \
  --output-dir '<fresh-outside-repo>'
```

Use the same Python environment as [CONTRIBUTING](../CONTRIBUTING.md#setup).
Check `df -h /System/Volumes/Data` first. Managed local runs wrap this command in
`<workspace>/tools/run_with_watchdog.sh` and
`<workspace>/tools/run_with_device_slot.sh uitier-reproduce --`. Only the assigned
simulator is used; no new local simulator is created. The temporary checkout and
build products are removed after the command; public records remain for review.
Clean those records and any task-owned quarantined failure bundle after recording
the necessary results in the PR. An output directory must be fresh and outside
the source checkout. A revision must contain the producer and manifest.

To reuse a previously verified secret-free build locally:

```bash
python3 -B scripts/ci_ui_tests.py run --device iphone --shard visual \
  --manifest-revision COMMIT_SHA --destination 'platform=iOS Simulator,id=<assigned-UDID>' \
  --xctestrun '<verified-products>/<default-plan>.xctestrun' \
  --output-dir '<fresh-outside-repo>'
```

This direct mode requires a checkout without `Config/env.xcconfig`, including
symlinks. It selects the manifest revision's classes against the current default
plan; use `reproduce` to reproduce the whole historical tree. CI accepts only its
admitted current manifest and the verified archive path. Commands exit nonzero
for failed/incomplete coverage, infrastructure, unapproved skips or privacy
failure; a policy approval and required-status promotion remain maintainer gates.
