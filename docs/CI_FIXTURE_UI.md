# Fixture-server UI mode

`scripts/run_fixture_ui_tests.py` runs only the UI target of the default iOS or
tvOS plan against a public loopback fixture server. It injects the server URL and
public key into the test runner at runtime. It clears ambient server, UI-test and
strict-test inputs, and refuses a private configuration file, symlink or dangling
symlink. The build retains the default **Sign to Run Locally** signature; app
product plists pass the shared archive check for empty server values and disabled
debug configuration.
Existing UI tests, app launch paths, assertions and deadlines are unchanged.
The runtime inputs also name C's dedicated EXIF diagnostic album and provide
an external directory for the existing scene-presentation contract collectors.

## Commands

Local entry points create a recorded working-tree snapshot that excludes
`Config/env.xcconfig`, including a private or dangling symlink, without reading,
copying or parking it. Hosted entry points require a configuration-free checkout.
See [local mode](../CONTRIBUTING.md#setup). Device runs use a dedicated simulator
and a bounded command; iPhone and iPad runs are
serial. Before every Xcode invocation the
runner uses the shared archive disk guard with `--min-free-gib` (default 80).
Only GitHub-hosted runners may lower this threshold. For their approximately
39 GiB free disks, pass `--min-free-gib 30`, as the archive jobs do:

```bash
python3 -B scripts/run_fixture_ui_tests.py \
  --device iphone --destination 'platform=iOS Simulator,id=<UDID>' \
  --xctestrun '<relocated-products>/<default-plan>.xctestrun' \
  --output-dir "$RUNNER_TEMP/fixture-iphone" --min-free-gib 30
```

The shared guard requires both `GITHUB_ACTIONS=true` and
`RUNNER_ENVIRONMENT=github-hosted` for thresholds below 80; local and self-hosted
runs retain the 80 GiB minimum. Negative thresholds are rejected.
Pass `--wait-factor 2` when matching the hosted UI tier's infrastructure budgets;
the local default is `1`. Product deadlines and observation windows never scale.
The bounded factor and its published record are described in [test waits](TEST_WAITS.md).

```bash
python3 -B scripts/run_fixture_ui_tests.py \
  --device iphone --destination 'platform=iOS Simulator,id=<UDID>' \
  --derived-data-path .derivedData/fixture-iphone \
  --output-dir '<outside-repo>/fixture-iphone' --mode measure
```

Use `--device ipad` with the iPad destination, or `--device appletv` with a tvOS
destination. `--derived-data-path` builds once using the locked package versions
and requires a fresh directory. To reuse a secret-free build, replace it with
`--xctestrun '<build-products>/<default-plan>.xctestrun'`. The iOS build can serve
both iPhone and iPad. Build archive provenance and relocation verification belong
to the archive consumer, which must run before passing the xctestrun here.
The runner verifies the destination UDID's CoreSimulator device type before
building, then requires the official result to record exactly that UDID, model
class and simulator platform. A CLI device label alone cannot claim coverage.

`--only-testing immichSlidesUITests/<Class>/<method>` reproduces an exact test;
repeat it for multiple tests. The runner rejects selections outside the default
plan. `--timeout-minutes` bounds each Xcode invocation (default 90). A nonzero
Xcode exit, missing result, unexpected identity, failed test, unapproved skip,
malformed export or sensitive-scan failure fails the run. There are no automatic
retries by default. The [UI tier](CI_UI.md) explicitly passes
`--listed-only-retry`, `--shard` and `--shard-manifest`, with a total Xcode budget
and failure-attachment export. This uses only the base registry, retains both
official attempts and preserves the first attempt if the retry reset fails.
`--failure-screenshots` requests screenshot capture with failure-only retention
in the prepared UI target's temporary `.xctestrun`, overriding the archive's
default video format. The archived run file and unit target stay unchanged.
Only failed-test attachments are exported, then scanned before publication.

With `--failure-screenshots`, a run where any Xcode invocation exits nonzero also
copies the app and UI test runner crash reports (`immichSlides*.ips` / `.crash`)
that the host wrote for this simulator since the test run began, to
`failure-screenshots/crash-logs/`, so they are published and scanned with the
failure attachments. A report counts only if it was last modified after the
runner took its baseline, is not in that baseline by name (so a report the host
later moves into `Retired` is excluded), its process name starts with
`immichSlides` and it names this simulator's UDID. At most 5 reports of at most
1 MiB each (4 MiB in total) are kept, earliest first; each file is read up to the
limit plus one byte. The host home directory is replaced by `~` and stable device
identifiers (`crashReporterKey`, `CrashReporter Key`, `Anonymous UUID`,
`Sleep/Wake UUID`, boot session UUID) by `<redacted>`; binary image UUIDs stay
for symbolication. `manifest.json` lists what was kept and what was omitted.
The collection is evidence only and best effort: any error while listing, reading
or writing is reported on stderr and never changes the exit code, the test results
or the other exported evidence. An app that
left the foreground without a report there (for example a kill by the system) shows
as zero collected reports in the runner output.

## Coverage and policy

The runner statically derives the selected default-plan population, enumerates
the compiled tests and reads official xcresult outcomes. It emits the shared
`summary.json` / `summary.md` contract plus `fixture-coverage.json` and
`fixture-coverage.md`, one row per selected test and device. Missing results stay
`not-run`; a skipped test never counts as fixture-covered. The JSON includes
`covered_selectors` for the tests observed passing, which is measurement output,
not an approved exclusion policy.
Before compiled enumeration completes, pre-seeded rows say `not attempted`.
After enumeration, missing declarations say `not compiled`, while compiled
tests with no official result retain that separate reason.

If the XCTest runner aborts while bootstrapping enumeration (`never finished
bootstrapping` and `signal abrt while preparing to run tests`, tracked in #257),
the runner runs the enumeration command once more. No other enumeration error is
retried, tests are never retried by this path, and a second failure fails the run
as before. The first attempt stays in `compiled-tests-attempt-1.json` and the
retry is recorded in `enumeration-retry.json`; it is not added to the summary's
`infrastructure` list, because any entry there fails the verdict.

`--mode measure` attempts every selected test, including active tier deselections.
All skips fail measurement, including approved environment skips.
The default `--mode pr` applies only approved `ui` / `fixture` deselections from
`scripts/ci-test-policy.json`, by exact identity including platform and device.
Deselected tests remain in declared and compiled accounting and are passed to
Xcode with `-skip-testing`. The shared verdict library also checks approved
expected skips by exact test, dimensions and official reason; these never count
as fixture-covered. Device or build applicability limits stay separate from
server/fixture gaps. The `proposed` section uses the same entry grammar as
the approved lists and **never affects execution or verdicts**. The maintainer
must promote approved proposals to the active lists; agents cannot approve them.
The [maintainer-approved UI policy](https://github.com/sudoHG/immichSlides/issues/96#issuecomment-6056730461)
contains 28 active `ui` / `fixture` expected skips: 24 device-scope, two manual EXIF
diagnostics and two debug-fill tests. Identity, platform/device dimensions and
official reason must match exactly; another device or changed reason fails.
The separate UI approval record activates this tier without granting another tier's
exceptions. Future proposals stay in `proposed` until explicitly promoted.
Live data cannot fix these prerequisites. Debug fill stays in the default plan as
an approved skip: the shared archive check forbids `ENABLE_DEBUG_*=1` in hosted tiers.
Product failures remain failures, tracked separately without an exclusion
proposal; they must not be attributed to fixture gaps without evidence.
Only demonstrated fixture/server gaps may become `nightly-live` deselections.

The [UI-shard workflow](CI_UI.md) schedules iPhone, iPad and Apple TV on pull
requests and main pushes. The PR records the per-test measurements,
real run links and any proposed exceptions; proposals remain inactive.

## Public fixture and output boundaries

Fixture set **C** supplies 40 synthetic photos with landscape, portrait and square
shapes, 12 albums with differing cover shapes, an additional populated album
matching the existing `ui-test-album-id` launch-hook seed, a ten-photo diagnostic
album where every photo has EXIF metadata, and three synthetic people.
The first person matches the first populated album. Every asset has a different
deterministic PNG with a unique C-labelled identity. This corpus supports UI interactions; it does
not prove real-person Vision filtering or live API compatibility. Frozen sets A
and B keep their metadata and image hashes; strict runners still select only A/B.
Future data changes require another fixture set.

The server binds only `127.0.0.1` on an ephemeral port, and only its exact child
process is stopped. Raw bundles, launch inputs and Xcode logs stay in the existing
owner-only private result root outside the output directory. Official test
exports and public coverage records pass the unchanged sensitive scanner.
Successful runs delete their private bundle and logs. Failed bundles remain
quarantined for local diagnosis and must never be uploaded. Delete task-owned
DerivedData, private failed-run files and temporary output after reviewing the
results and putting the necessary table, hashes and commands in the PR.
