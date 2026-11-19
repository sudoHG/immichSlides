# Secret-free simulator build archives

`ci-gate` builds the unit-only default plans once per applicable tested commit,
platform and producer attempt. [Unit consumers](CI_UNIT_TESTS.md) reuse them
without source. `build-for-testing` compiles every scheme testable, including
the UI target's smoke and App Store screenshot methods. PR CI runs no UI tests;
[smoke nightly](CI_NIGHTLY.md) builds and executes smoke separately.

## Unit archives

Local scripts [snapshot working files](../CONTRIBUTING.md#setup) and exclude
private configuration. Hosted preflight refuses configuration files/symlinks
without opening them and rejects ambient server/debug inputs, before and after build.

```bash
python3 -B scripts/ci_build_archive.py preflight --platform ios \
  --output-dir /tmp/immichslides-preflight
python3 -B scripts/ci_build_archive.py build --platform ios \
  --derived-data-path .derivedData/archive-ios \
  --output-dir /tmp/immichslides-producer-ios
```

Use `tvos` and fresh paths for Apple TV. Local disk reserve is 80 GiB; hosted CI
uses 30 GiB. Both package-resolution flags keep versions locked, and signing
stays Sign to Run Locally. Product server fields must be empty and debug flags
disabled. Signature inspection must measure `Signature=adhoc`.

`archive/build.tar.gz` preserves complete `Build/Products`: xctestrun, App,
unit/UI bundles, frameworks and packaged public fixtures. Source, DerivedData,
package checkouts and raw results are excluded.
The schema-1 manifest binds source/event, run/workflow/attempt, platform/configuration,
toolchain/pins, architectures, signing, paths, archive hash and full inventory.

Extraction rejects unlisted/duplicate paths, traversal, hard links, device files,
changed modes/hashes, non-directory ancestors and escaping/missing/cyclic links.
Consumers remeasure signing. Archives last one day; gate records last 30 days for
PRs and seven days otherwise.

## Selection and relocation

Consumers select immutable artifact IDs/producer attempts, not latest names.
Repository/run/commit and manifest must agree. PR identity includes base, head,
merge commit and tree. Gate consumers admit only same-run producer outputs.
They stage tooling/declarations, remove source, reject surviving build paths,
extract elsewhere, enumerate and execute the complete unit target.

Archive errors never silently rebuild. Missing/expired archives require
**Re-run all jobs**. **Re-run failed jobs** can reuse successful producer IDs from
an earlier attempt of the same run; all-job reruns create new archives.

## Smoke archives

The schema-2 `strict-smoke-archive.json` envelope (`kind: smoke-archive`) binds
a generic iOS Simulator build of `immichSlides-iOS-settings-resume` /
`StrictE2E-iOS` to clean source commit/tree/fingerprint, package lock, pins,
Xcode and SDK. Debug/Release use separate archives; tvOS builds locally.

Control provenance separately binds repository, workflow, run/attempt and staged
main control commit. Artifact API head is control provenance, not tested source.
Expected control comes independently from the admitted plan. Source Info.plist
server fields must remain exact variable references; resolved product values
must be empty.

Immutable IDs and producer manifest/archive hashes precede extraction.
Inventory/link/plist/signature checks remain mandatory.
Execution identity separately names the concrete pinned iPhone/iPad type,
runtime/build and architecture. Compatibility is checked without rewriting the
generic build identity; real devices and other runtimes are refused.
Explicit archive mode, relocated Products and expected control are required.
Schema-1 local warm receipts still compare concrete destinations.
See [Smoke runner](CI_STRICT_RUNNER.md).

## Records and cleanup

Preflight/build/selection write summary/identity on success or failure when valid
inputs permit it. Consumers scan compact records before display/upload.
Raw results stay private. Read outcomes and remove task-owned outputs after
checking path holders. Producer claims are not attestations or release approval.
