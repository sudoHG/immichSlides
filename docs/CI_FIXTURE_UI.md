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

Use an isolated checkout with no `Config/env.xcconfig`. On a managed local
worktree, park only that worktree's read-only symlink and restore it in an EXIT
trap, checking its `readlink` target. Do not read or copy its contents. Device
runs on the maintainer's workspace use the existing watchdog and device-slot
wrappers; iPhone and iPad runs are serial. The runner checks the 80 GiB disk
threshold before every Xcode invocation.

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

`--only-testing immichSlidesUITests/<Class>/<method>` reproduces an exact test;
repeat it for multiple tests. The runner rejects selections outside the default
plan. `--timeout-minutes` bounds each Xcode invocation (default 90). A nonzero
Xcode exit, missing result, unexpected identity, failed test, unapproved skip,
malformed export or sensitive-scan failure fails the run. There are no automatic
retries.

## Coverage and policy

The runner statically derives the selected default-plan population, enumerates
the compiled tests and reads official xcresult outcomes. It emits the shared
`summary.json` / `summary.md` contract plus `fixture-coverage.json` and
`fixture-coverage.md`, one row per selected test and device. Missing results stay
`not-run`; a skipped test never counts as fixture-covered. The JSON includes
`covered_selectors` for the tests observed passing, which is measurement output,
not an approved exclusion policy.

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
All non-covered identities are proposed for the `nightly-live` owning tier.
Device, build and diagnostic opt-in limits do not imply that live data fixes the
skip; that tier's owner must honor each recorded prerequisite. A product failure
is still a failure; moving it to another tier does not fix it.

The UI-shard workflow is separate work. Until it exists, coverage is proven by
local device-slot runs, and CI execution on all three devices is `NOT_RUN`.
The PR records the per-test measurements and any proposed exceptions.

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
