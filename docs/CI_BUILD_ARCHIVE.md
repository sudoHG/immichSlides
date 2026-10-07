# Secret-free simulator build archives

`ci-gate` builds the default iOS and tvOS test plans once per platform, tested commit
and producer attempt, with **Sign to Run Locally** simulator signing and both locked
package-resolution flags. The full unit/UI consumers remain separate tickets. Host
and privacy jobs are unchanged. [`scripts/ci_build_archive.py`](../scripts/ci_build_archive.py)
uses the existing [identity/summary contract](CI_SUMMARY.md) and [toolchain pins](CI_TOOLCHAIN.md).
Its summaries describe host checks of archives, not a full Swift population or a
trusted required verdict.

## Workspace preflight and contents

Run the workspace preflight before setup or Xcode:

```bash
/usr/bin/python3 -B scripts/ci_build_archive.py preflight --platform ios \
    --output-dir /tmp/immichslides-workspace-preflight
```

`Config/env.xcconfig` is forbidden: regular file, symlink or dangling symlink. The
check never opens or follows it and repeats before/after building. Ambient server/debug
environment variables are also rejected without inspecting their values. Local archive
builds use a disposable, clean checkout without private configuration; do not copy
private configuration or remove another worktree's symlink.

```bash
/usr/bin/python3 -B scripts/ci_build_archive.py build --platform ios \
    --derived-data-path /tmp/immichslides-archive-derived-ios \
    --output-dir /tmp/immichslides-archive-producer-ios
```

Use `--platform tvos` and fresh paths for tvOS. Local runs keep the 80 GiB default
on `/System/Volumes/Data` and use the workspace device-slot/watchdog wrappers.
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
refusal is deferred to the first cross-run consumer, the [UI tier tracer (#94)](https://github.com/sudoHG/immichSlides/issues/94).

```bash
# CI supplies GH_TOKEN through a step environment, never a command argument.
/usr/bin/python3 -B scripts/ci_build_archive.py select --platform ios \
    --artifact-id ID --producer-attempt ATTEMPT --selection-path /tmp/archive-selection.json \
    --output-dir /tmp/immichslides-artifact-selection
```

Artifact selection runs in CI with GitHub's run/event metadata and an actions-read token.
These candidate records are claims, not trusted attestations. Fork code can forge
them; the epic's later trusted publisher and approval tickets own that boundary.

The relocation matrix runs on separate GitHub-hosted runners. Producers check out
`source-build`; consumers check out `consumer-source`. After artifact selection, consumers
copy only the entry point, its existing helpers and pins to runner temp, then remove
their entire source checkout. Proof rejects existing build-time source/Products paths,
extracts at a different absolute path and calls `test-without-building` with no project
or scheme. Four explicitly selected metadata fixture tests and the fixture-set-A
pause-hold test must all pass with no skips. Compact proof records artifact ID, producer/consumer attempts,
full identity, selections, official counts/test tree, source absence and disk space.
The selectors retain Swift raw-identifier backticks. Exit 0 with no selected tests
is rejected, and official counts/test-tree records are retained even on this failure.
The proof disables Xcode clone-process parallelism and runs on its dedicated
simulator. This avoids an extra simulator startup while preserving the selected
tests, their assertions and the command timeout.
This is a temporary proof job: the [unit-test consumer (#91)](https://github.com/sudoHG/immichSlides/issues/91)
will replace it, removing this separate job and its five hard-coded selectors.
The full unit-test consumer will own the relocated test population instead.

After removing its checkout, the hosted consumer invokes the staged entry point:

```bash
"$RUNNER_TEMP/consumer-python/bin/python3" -B "$RUNNER_TEMP/archive-tools/scripts/ci_build_archive.py" proof \
    --selection-path "$RUNNER_TEMP/archive-selection.json" \
    --archive-dir "$RUNNER_TEMP/archive-download" \
    --relocated-path "$RUNNER_TEMP/consumer-relocated-ios" \
    --output-dir "$RUNNER_TEMP/relocation-records" --min-free-gib 30
```

**Rerun failed jobs** retains successful producer outputs. Consumers download by
artifact ID from the same run, including earlier producer attempts, and record the
attempt reused. Missing/expired archives fail without latest-head/name fallback or
silent rebuild. The failed record says **use Re-run all jobs** to produce fresh
archives. A failed producer rerun creates an archive for the new attempt.
**Rerun all jobs** rebuilds both platforms and creates new attempt-specific archives;
consumers use the new IDs. Previous artifacts are never overwritten.

Workspace preflight and artifact selection require `--output-dir` and write the
existing summary/identity contract on success or failure. Workflow steps share the
job's records path; a later build/proof replaces successful preflight/selection
records. If either earlier step fails, its failed summary remains available to the
always-run upload/display steps. The preflight records no private values and starts
neither setup nor Xcode. Failures use `workspace-preflight-failed`,
`archive-unavailable` (expired/missing artifacts, including API 404/410), or
`archive-identity-mismatch`; proof/build errors retain their respective failure codes.
Every failure message includes **use Re-run all jobs**. There is no silent rebuild
or cross-run fallback. An invalid CLI/output location or unparseable run identity
fails before a valid record can be constructed.

Passing proofs establish relocation for both platforms on the pinned toolchain.
If relocation later fails, the tier must not rely on reuse until fixed or the epic's
per-consumer-build fallback is implemented with a new capacity measurement. Official
raw results are read and disposed on the runner; only compact records are uploaded.
Remove task-owned local outputs after verification. This ticket configures no settings,
required statuses, secrets, environments, approvals or full test-tier policy.
