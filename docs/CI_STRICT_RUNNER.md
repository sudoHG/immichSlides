# Smoke runner

The historical filename and `scripts/run_strict_e2e.py` entry point now serve
only smoke. Scheduling belongs to [Smoke nightly](CI_NIGHTLY.md).

## Short smoke-flow suite

`--suite smoke-flow` runs the validated [manifest](../scripts/smoke-flows.json)
against public loopback fixtures: 20 methods, 23 device flows.
`--smoke-scope full` is the default; `core` selects the seven scheduled flows.
Choose a pinned simulator, matching `--smoke-device iphone|ipad|tv` and explicit
`--configuration Debug|Release`. Only that device/configuration group executes.
A complete full run needs every nonempty group.

From a configuration-free checkout, with fresh paths:

```bash
df -h /System/Volumes/Data
python3 -B scripts/run_strict_e2e.py --platform ios \
  --destination 'platform=iOS Simulator,id=<UDID>' --suite smoke-flow \
  --smoke-device iphone --configuration Debug --smoke-scope full \
  --derived-data-path .derivedData/smoke-iphone-debug \
  --evidence-dir '<fresh-outside-repo>/smoke-iphone-debug'
```

Use `--platform tvos --smoke-device tv` for Apple TV or `--smoke-device ipad`
for iPad. [Toolchain pins](CI_TOOLCHAIN.md) define exact devices and runtimes.
Local scripts [snapshot working files](../CONTRIBUTING.md#setup) and ignore
ambient private configuration. Local disk preflight requires 80 GiB.

`--smoke-flow ID` diagnoses one flow; its `selection=single-flow` cannot count
as complete group evidence. Release flows configure the fixture through the real
form with no DEBUG launch hooks. Synthetic PIN coverage is not production
Keychain verification.

## Build and reuse

The UI-only schemes `immichSlides-iOS-settings-resume` and
`immichSlides-tvOS-settings-resume` use `StrictE2E-iOS` / `StrictE2E-tvOS`.
These historical plans select only the platform's SmokeFlow class. Compiling
the target also compiles the App Store screenshot methods without executing them.

Add `--warm-up-only` to the command above for build-only verification.
It requires fresh DerivedData and writes a schema-1 identity/inventory receipt.
Reuse with `--test-without-building`, the same source, concrete destination,
configuration and DerivedData, and a fresh evidence directory.
Changed source or Products fail reuse; there is no silent rebuild.
Both package-resolution flags keep the lock file authoritative, and simulator
signing stays Sign to Run Locally.

The separate schema-2 generic iOS smoke archive requires explicit
`--smoke-archive --test-without-building --smoke-control-path PATH` and relocated
Products. Independent expected control and pinned execution compatibility are
verified; see [Build archives](CI_BUILD_ARCHIVE.md).

## Budgets and first results

Each flow has a 180-second native method allowance plus 150 seconds for startup
and finalization: a 330-second invocation cap. Navigation shares the approved
120-second hang guard; existing first-boot helper bounds remain.
Group deadlines cover setup, execution, export and cleanup. Hosted workflow
limits come from group budgets plus the fixed reserve. No test retry, repetition
or yellow result rescues an executed flow.

Each flow resets App state, starts required fixtures and gets a private xctestrun.
Official summary/method results must match its selector. Zero, extra, skipped,
missing or failed results fail. `case-manifest.json` and
`smoke-flow-results.json` bind source, ordered flows, selection and group failures.
Products are checked again afterward. A late group failure invalidates affected
passing flows while preserving earlier failures.

## Shared simulator reset

Use dedicated simulators: uninstall, Keychain and privacy resets affect the
whole device. Boot/bootstatus and service readiness precede the bounded App reset.
The reset terminates/uninstalls the App, confirms absence, resets Keychain/privacy
and disables iOS Password AutoFill with readback. AutoFill remains disabled on that
dedicated simulator; do not use a personal simulator.

The hosted controller may recreate its owned simulator once after preparation
fails, before any flow starts. This is not a retry of an executed test.
Pre-test diagnostics use closed step names, distinguish timeouts and retain
unknown attribution without exposing exception text.

## Fixture service startup

`strict_e2e_server.py` serves frozen public fixture A/B on loopback.
The runner owns startup/health checks and supplies inputs explicitly.
Never substitute a personal server. Member metadata comes from
`strict_e2e_fixture_metadata.py`; fixture bytes and hashes remain fixed.

## Private results and export

Raw XCTest bundles stay outside evidence in the owner-only
`immichSlides-strict-e2e-private` temporary root. Activities can contain public
test keys or synthetic PINs, so bundles never upload.

Finalization exports `official-tests.json` and `official-summary.json`,
including on failure, with bounded xcresulttool calls. Successful export,
checks, sensitive scanning and cleanup precede disposal. Incomplete or failed
runs retain private quarantine for diagnosis. Missing exports cannot pass.
Delete task-owned results/products after reading them and checking path holders.

Only scanned compact records and allowlisted sanitized first-failure diagnostics
may upload. `FirstFailureContext` retains normal first-failure capture.
Raw logs, activities and quarantine paths stay private.
Build success proves compilation, not smoke execution or human visual acceptance.
