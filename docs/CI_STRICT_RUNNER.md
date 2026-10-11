# Strict runner warm-build tracer

The informational `ci-strict-tracer` workflow runs on the [pinned hosted toolchain](CI_TOOLCHAIN.md)
only for pull requests touching its workflow, strict runner modules/tests or tracer
manifest, and through `workflow_dispatch`. Other PRs and main pushes do not trigger it.
It covers an iPhone smoke suite,
an Apple TV smoke suite, iPhone P2 rotation with recording, and the dual-server
`filter-switch` suite. [`strict-tracer.json`](../scripts/strict-tracer.json) is only
this tracer's versioned case list, not the complete nightly matrix. Nightly matrix
enumeration and aggregation are documented in [Skeleton nightly](CI_NIGHTLY.md).
Explicit warm runs can opt into [listed-only retries](TESTING.md#known-flaky-registry-and-listed-only-retries)
with `--listed-retry-device`; the tracer and skeleton nightly continue to run once.
Signed visual-review promotion remains separate work.
Simulator preparation and official exports have explicit phase deadlines; timeout
records and private quarantine follow the [nightly infrastructure policy](CI_NIGHTLY.md#population-and-capacity).
The shared boot helper caps `simctl boot` at 60 seconds and gives boot plus bootstatus
600 seconds total. It finishes before the separate 120-second app/keychain/privacy
reset clock starts; individual reset commands have at most 60 seconds. Local strict,
fixture UI, listed retry and access-lifecycle runs use these preparation bounds too.
Official tests and summary exports each have 60 seconds. Unit callers retain
`unit-results-timed-out` with export phase and elapsed time; strict callers retain
their preparation/export phase codes. Test-execution budgets are separate.

Strict builds use their own test plans and settings; they do not consume the default
unit/UI archives. They reuse the [archive workspace preflight](CI_BUILD_ARCHIVE.md),
product inventory and signing inspection. No competing archive producer or artifact
selection mechanism is introduced.

## Explicit shard warm-up and reuse

Each shard is grouped by scheme and configuration. Ordinary suites default to their
existing Debug setting; settings-resume suites use their dedicated scheme and require
Release. `--configuration Release` selects Release for other suites when required.
Keep each scheme/configuration/device in a separate DerivedData directory and use
one cloned-package directory shared by the shards in that workspace.

```bash
python3 -B scripts/run_strict_e2e.py --platform ios \
    --destination 'platform=iOS Simulator,id=<UDID>' --suite smoke \
    --warm-up-only --derived-data-path '<outside-repo>/derived/ios-debug' \
    --cloned-source-packages-path '<outside-repo>/SourcePackages' \
    --evidence-dir '<outside-repo>/warm-up/ios-debug' --cold-timeout-seconds 1200

python3 -B scripts/run_strict_e2e.py --platform ios \
    --destination 'platform=iOS Simulator,id=<UDID>' --suite smoke \
    --test-without-building --derived-data-path '<outside-repo>/derived/ios-debug' \
    --cloned-source-packages-path '<outside-repo>/SourcePackages' \
    --evidence-dir '<outside-repo>/cases/smoke' --warm-timeout-seconds 600
```

Use a fresh evidence directory for every case. Warm-up requires fresh shard
DerivedData and runs `build-for-testing` without a test, service or recording.
Its receipt binds source contents (including intended uncommitted files, excluding
`__pycache__` and `*.pyc`), toolchain,
scheme, plan, configuration and destination to the signed Products inventory.
Reuse refuses an absent, mismatched or modified build instead of rebuilding.
Use the same configuration and destination in both commands. Per-case `.xctestrun`
copies live beside the private result bundle, with relocated `__TESTROOT__` paths
and fixture/evidence inputs injected only into the test runner. App launch inputs
stay empty. Every warm invocation uses `test-without-building`; Products are hashed
before and after. Recordings begin after that preparation and contain no build.
The existing filter-person sessions each reuse this build and still reset separately.

The cold budget applies only to warm-up; the warm budget applies per reused Xcode
invocation. The runner's local defaults remain 300 seconds for both, and the
default mode remains the existing single `test` call with its fixed 300-second limit
with disposable DerivedData in evidence. Explicit cold/warm timeout options are
rejected in that default mode. Explicit shard DerivedData is retained
until its owner finishes all cases. Package resolution stays locked and simulator
signing stays **Sign to Run Locally**, verified as `adhoc` by `codesign` after warm-up.

## Shared simulator reset

Strict, fixture UI, listed-retry and standalone access runners share
`reset_simulator_app`: boot and wait for `bootstatus -b`, query the app container,
terminate only when the app is installed, uninstall with one retry, require the
app container to be absent afterward, then reset keychain and all privacy
permissions. Only a container lookup confirming absence skips termination; an
unknown or timed-out lookup fails. Uninstall and the remaining reset steps are
still mandatory before Xcode may install the app. A reset error fails the case.

Boot finishes before the existing 120-second reset deadline starts; the presence
query and all remaining reset commands share that deadline. Individual reset
commands retain their 60-second cap. Boot phases, the extra presence-query seconds,
skipped termination and total reset seconds are logged. This adds no fixed
post-boot sleep and extends no reset or product deadline.

Use dedicated simulators: keychain/privacy reset applies to the whole device.
Server/UI test variables in direct,
`TEST_RUNNER_` and `SIMCTL_CHILD_` forms are filtered. Strict fixture inputs are
passed explicitly; real server configuration is never used.

Warm mode invokes the existing workspace preflight before setup/build/reuse. It
rejects regular configuration files, links and dangling links without opening them.
Use a checkout without local private configuration, a dedicated simulator that is
not shared with another job, and an outer timeout for device/build commands. The
Local disk preflight requires 80 GiB.

## Tracer, budgets and results

```bash
python3 -B scripts/run_strict_ci_tracer.py --platform ios \
    --destination 'platform=iOS Simulator,id=<UDID>' \
    --output-dir '<fresh-outside-repo>/tracer-ios'
```

Repeat with `--platform tvos` and its destination. The tracer groups its cases,
builds each shard once, then runs each case without building. It does not retry.
The hosted workflow uses an initial 1,200-second cold budget, 600-second warm budget,
and a 30 GiB disk preflight. Each runner segment has an additional 240-second outer
allowance for reset/export/cleanup. iOS allows two cold and three warm segments
(90 minutes total); tvOS allows one of each (38 minutes total). The literal
110-minute job timeout covers the larger shard, a separate 10-minute initial simulator
boot budget, and setup, uploads and final cleanup. Both workflows call the same boot
helper as local resets. Initial boot phases and elapsed times are logged before the
first case, so cold boot does not consume the 120-second case-reset
budget. The [nightly capacity policy](CI_NIGHTLY.md#population-and-capacity) records the
hosted measurement used for this boot allowance.
The initial allowance follows
the archive producer's [measured hosted disk use](CI_BUILD_ARCHIVE.md); the tracer
reports its own measurements for review. Hosted cold/warm budgets and the disk exception
do not replace the local xcodebuild budget or 80 GiB disk preflight; the shared local
preparation/export bounds are stated above.

`records/trace.json` is written initially and after every runner segment, including
timeouts and interruptions. It reports each cold/warm duration, exit code, official counts,
build-operation count, immutable Products check and sampled disk usage. Disk is
sampled once per second: minimum free, peak volume use and growth since start;
shorter spikes may be missed and unrelated runner activity is included.
`summary.json`, `summary.md` and `run-identity.json` use the existing producer
[summary contract](CI_SUMMARY.md). Missing results, builds in a warm log, changed
Products and failed strict contracts fail the tracer. P2 contract success is
`needs-human-review`, with overall producer status `unverified`, never visual PASS.
Only a complete observed set with every automated check passing permits a non-failed
status. Cancellation and unexpected exceptions record failed status, an `interrupted`
infrastructure entry and every unfinished case as `not-run`. Each runner starts in
its own process group; timeout/cancellation terminates and waits for that whole group
before deleting build inputs. Shared group-probe behavior is documented in the
[host contract](CI_SUMMARY.md). The runner's final `CommandError` is printed in the job log.
Official summary and selected-method exports are read even after runner failure;
nonzero exits remain failures. Filter-person combines its three session exports
and requires all three passes. Exit 0 means all automated tracer checks completed,
not release eligibility.

CI uploads compact records plus the scanned P2 recording, recording timing proof
and SHA-bound hashes. Screenshots, fixture originals and review-package formats
belong to the separate visual-review work. It never uploads raw `.xcresult`, DerivedData, package clones,
simulator contents or unscanned logs. Raw bundles follow the existing disposal,
quarantine and sensitive-scanning rules under the export bounds above. Recording evidence is retained
for seven days; records use 30 days for PRs and seven days for manual runs.
The tracer removes its build/package directories after its children exit, and the
workflow removes its dedicated simulator and remaining task output after upload.

The two standalone access-protection runners are explicitly excluded in the tracer
manifest: iOS is unstable on main, and tvOS creates a transient isolated Release
scheme. They inherit the reset/environment filter, but keep their local 1,200-second
and existing per-run build behavior. No warm access-protection coverage is claimed.
The strict suite table's small `*-lifecycle-*` cases remain eligible for explicit
Release warm shards. A full nightly matrix must retain these exclusions until the
standalone runners are converted. No repository settings, environments, secrets,
approvals, required statuses or release policy are configured by this tracer.
