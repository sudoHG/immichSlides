# Secret-free simulator build archives

## Smoke archive reader (explicit opt-in)

The smoke-only `strict-smoke-archive.json` envelope is schema 2 (`kind: smoke-archive`).
It does not change the schema-1 warm receipt's exact destination comparison or the
default Debug archive protocol used by PR UI, unit consumers and nightly. Release
Products inspection/extraction requires an explicit `configuration=Release` argument;
the shared helper's default remains Debug.

The smoke envelope binds a generic iOS Simulator build of
`immichSlides-iOS-settings-resume` / `StrictE2E-iOS` to the clean tested commit, tree,
content fingerprint, package lock, pins, Xcode plist/build and SDK version/build.
Control provenance separately binds the shadow repository, run, first attempt,
workflow ID/path, API head, admitted-main flag and staged main control commit.
The artifact API head identifies that control run; it must never substitute for
the admitted nightly's tested commit, even when two commits have the same tree.
Before and after compilation, the producer repeats workspace preflight and verifies
that the regular source Info.plist's server fields contain only their exact build-variable
references. After compilation it also requires the resolved product fields to be empty.
Historical tested heads need the v2 receipt, source-plist preflight and explicit
expected-control capabilities;
the controller never modifies an old checkout to manufacture support.

An immutable configuration-specific artifact ID and producer-output manifest/tar
hashes precede extraction. The existing traversal/link, complete inventory, plist
server/debug-field and measured ad-hoc-signature gates remain mandatory. Execution
has a separate identity: concrete UDID, pinned iPhone 17e or iPad Air 11-inch (M4)
device type, exact iOS runtime version/build and host architecture. The explicit
compatibility validator connects these identities without rewriting the generic
build destination. tvOS, real devices and other runtimes are rejected.

`run_strict_e2e.py --suite smoke-flow --smoke-archive --test-without-building --smoke-control-path <expected-control.json>`
requires explicitly relocated Products and never rebuilds. Each flow still uses
its own private xctestrun; the full Products inventory is checked before and after
execution. Old warm callers and workflows do not opt in implicitly.
The expected-control JSON comes from the admitted plan, independently of the archive
receipt. Local callers use the local snapshot's recorded commit and `mode: local`.
Both archive verification and `load_smoke_archive(..., control=expected)` compare it;
the loader never treats the receipt's own control as an expectation.

`ci-gate` builds the default iOS and tvOS test plans once per platform, tested commit
and producer attempt, with **Sign to Run Locally** simulator signing and both locked
package-resolution flags. The [full unit consumers](CI_UNIT_TESTS.md) reuse these
archives; the [iPhone UI tracer](CI_UI.md) selects the iOS archive across runs. Host
and privacy jobs are unchanged. [`scripts/ci_build_archive.py`](../scripts/ci_build_archive.py)
uses the existing [identity/summary contract](CI_SUMMARY.md) and [toolchain pins](CI_TOOLCHAIN.md).
For app-unaffected PRs, the Linux classification job skips both build and unit
jobs under the [trusted not-applicable contract](CI_PUBLISHER.md). Host checks
still run on macOS. Unknown and CI-trusted paths run all app jobs; classification
failure or missing output also schedules builds and fails publication; the unit
consumers are skipped in that case. Main pushes and nightly retain their complete
build paths.
The [nightly live producer](CI_LIVE_TESTS.md) reuses this entry point with schedule/dispatch
identity and PR canary builds, exact nightly workflow provenance and the same secret-free checks.
Its summaries describe host checks of archives, not a full Swift population or a
trusted required verdict.

## Workspace preflight and contents

Run the workspace preflight before setup or Xcode:

```bash
/usr/bin/python3 -B scripts/ci_build_archive.py preflight --platform ios \
    --output-dir /tmp/immichslides-workspace-preflight
```

Inside a producer checkout, `Config/env.xcconfig` is forbidden: regular file,
symlink or dangling symlink. The check never opens or follows it and repeats
before/after building. Hosted producers reject ambient server/debug variables
without inspecting their values. Local entry points now automatically snapshot
the intended working tree, exclude private configuration and strip ambient inputs
before this preflight. They record the tested tree; `--strict-ci` refuses dirty
input instead. See [local mode](../CONTRIBUTING.md#setup). Do not copy private
configuration or remove another worktree's symlink.

```bash
/usr/bin/python3 -B scripts/ci_build_archive.py build --platform ios \
    --derived-data-path /tmp/immichslides-archive-derived-ios \
    --output-dir /tmp/immichslides-archive-producer-ios
```

Use `--platform tvos` and fresh paths for tvOS. Local runs keep the 80 GiB default
on `/System/Volumes/Data`.
Only GitHub-hosted CI can pass a smaller `--min-free-gib`; the workflow uses 30 GiB.
Initial hosted inventory was about 39 GiB. Each build records space before/after,
product bytes, archive bytes and threshold in `records/disk.json`. The CI allowance
is based on measured builds: iOS 39.51 to 38.26 GiB and tvOS 38.71 to 37.49 GiB,
about 1.3 GiB consumed per build. Products were 138/151 MiB and archives 34/38 MiB;
the measured post-build reserve above the threshold was at least 7.49 GiB. Review
fresh records after toolchain/project changes without changing local defaults.

`archive/build.tar.gz` contains the complete `Build/Products`: `.xctestrun`, app,
unit/UI bundles, frameworks and bundled public fixtures. Tar preserves permissions
and symlinks, unlike directly uploading Products. DerivedData, package checkouts,
source and raw `.xcresult` are excluded. Builds reject checkout/lock changes,
nonempty `IMMICH_SERVER_URL`/`IMMICH_API_KEY` in product plists, and enabled or
unresolved `ENABLE_DEBUG_*` values. The built app is inspected with
`codesign -dv --verbose=2`; inspection must succeed with `Signature=adhoc`.
Unsigned apps and other signature types fail before archive publication.

Manifest version 1 contains the existing run identity; producer run, workflow,
attempt and artifact name; platform, Debug configuration, actual binary architectures,
actual Xcode build, pins SHA-256, measured `signing_mode=adhoc`, private-configuration absence,
source/Products paths, archive SHA-256 and every file/directory/link. Entries record
permissions, file size/hash or link target. Extraction rejects unlisted/duplicate
paths, traversal, absolute/escaping links, hard links, device files, non-directory
ancestors, changed hashes and changed permissions. Symlink targets are resolved
segment by segment against the full file list, expanding chains before processing
`..`; loops, missing targets and out-of-root targets are refused. Consumers repeat
the app signature measurement after extraction. Summaries store the measured value
in `toolchain.versions.codesign_signature`; the existing canonical signing-mode enum
is set to `sign-to-run-locally` only after an `adhoc` measurement. Preflight/selection
records use `not-applicable` and do not invoke Xcode or infer a signature.

The immutable artifact ID is a producer job output: it does not exist until upload.
Names are `build-PLATFORM-RUN-ATTEMPT`; archives expire after **one day**. Compact
records use existing summary retention (30 days for PRs, 7 days for main pushes).

## Artifact selection, relocation and reruns

Consumers independently derive checkout identity with the existing parser. They
check the repository's artifact API by exact ID for run, name, expiry and commit,
download by ID, then verify the manifest. PR comparison includes repository, PR,
base, head, merge commit and merge tree. Main pushes compare the full push identity.
Inside `ci-gate`, consumers accept only artifacts from the same `github.run_id`,
using producer job outputs; a different-base archive cannot arise by construction.
Python checks still guard full-identity comparisons. The real-run same-head/different-base
refusal is exercised by the cross-run [UI tier tracer](CI_UI.md), which records
the refused and admitted identities before downloading an exact-identity archive.

```bash
# CI supplies GH_TOKEN through a step environment, never a command argument.
/usr/bin/python3 -B scripts/ci_build_archive.py select --platform ios \
    --artifact-id ID --producer-attempt ATTEMPT --selection-path /tmp/archive-selection.json \
    --output-dir /tmp/immichslides-artifact-selection
```

Artifact selection runs in CI with GitHub's run/event metadata and an actions-read token.
These candidate records are claims, not trusted attestations. Fork code can forge
them; the [trusted publisher and exact-head approval](CI_PUBLISHER.md) independently
verify admission and producer evidence before publishing an informational status.

The [unit-test consumers](CI_UNIT_TESTS.md) run on separate GitHub-hosted runners.
Producers check out `source-build`; consumers check out `consumer-source`. After
artifact selection, consumers stage only the entry point, shared private result-bundle
helpers and pins, then remove their entire source checkout. They reject existing
build-time source/Products paths, extract at another absolute path, enumerate the
complete unit bundle and run the entire unit target with `test-without-building`.
The temporary five-selector proof job and entry point are removed. Both execution
and its failure path retain official identities/outcomes and archive provenance
before successful disposal or private quarantine. See CI_UNIT_TESTS for commands,
measurements, job graph, upload rules and unit verdicts.

**Rerun failed jobs** retains successful producer outputs. Consumers download by
artifact ID from the same run, including earlier producer attempts, and record the
attempt reused. Missing/expired archives fail without latest-head/name fallback or
silent rebuild. The failed record says **use Re-run all jobs** to produce fresh
archives. A failed producer rerun creates an archive for the new attempt.
**Rerun all jobs** rebuilds both platforms and creates new attempt-specific archives;
consumers use the new IDs. Previous artifacts are never overwritten.

Workspace preflight and artifact selection require `--output-dir` and write the
existing summary/identity contract on success or failure. Workflow steps share the
job's records path; a later build/consumer replaces successful preflight/selection
records. If either earlier step fails, its failed summary remains available to the
always-run upload/display steps. The preflight records no private values and starts
neither setup nor Xcode. Failures use `workspace-preflight-failed`,
`archive-unavailable` (expired/missing artifacts, including API 404/410), or
`archive-identity-mismatch`; consumer/build errors retain their respective failure codes.
Archive selection/build/validation failures include **use Re-run all jobs**. Early
consumer failures pass through an independent always-run sensitive scan before
upload/display. Download failures retain a failed `archive-unavailable` record.
There is no silent rebuild
or cross-run fallback. An invalid CLI/output location or unparseable run identity
fails before a valid record can be constructed.

Full unit execution establishes relocation for both platforms on the pinned toolchain.
If relocation later fails, the tier must not rely on reuse until fixed or the epic's
per-consumer-build fallback is implemented with a new capacity measurement. Official
raw results are read and disposed on the runner; only compact records are uploaded.
Remove task-owned local outputs after verification. This ticket configures no settings,
required statuses, secrets, environments, approvals or full test-tier policy.
