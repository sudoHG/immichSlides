# Testing conventions

Rules for adding or changing tests. Each rule can be checked on its own. When in doubt, copy the examples.

Existing tests are being migrated to these rules. Do not rewrite unrelated tests while working on something else.

**Local runner default:** script entry points run in a clean snapshot of the
current tracked working files plus untracked, non-ignored files. They ignore
ambient test/server inputs and private `Config/env.xcconfig` files or symlinks;
no link is parked, followed or copied. The tested tree SHA is printed and recorded
in `local-snapshot.json` beside output/evidence records, or an explicit
`--snapshot-record` path. `--strict-ci` refuses dirty trees;
`--allow-private-config` opts into the original checkout for local private testing.
Use `--config NAME=VALUE` for explicit runtime inputs. Run example-config setup
alone or with `--check` before starting tests. All existing runner flags remain available. This does not change
Xcode GUI/direct commands or hosted producer contracts. The full mode/command
policy is in [CONTRIBUTING](../CONTRIBUTING.md#setup).
Cancellation forwards SIGINT to the runner first so Xcode and private-bundle
finalizers can finish, then escalates if needed. A snapshot is removed only after
its child process groups exit; unverifiable cleanup retains its path for diagnosis.
The snapshot receipt records the final exit code, including cleanup failure.
`ci_ui_tests.py check-upload` only inspects results an earlier run wrote, so it keeps that run's receipt and writes none.
DerivedData remains in the original checkout or an explicit stable path, outside
the disposable snapshot. Local nightly plan, tracer and aggregate identities must
match; see [the nightly guide](CI_NIGHTLY.md).

## 0. When to write a test

Every test must guard a failure that can realistically happen again. If you cannot name that failure in one sentence, do not write the test.

Write a test when you:

- fix a logic bug: one regression test that fails before the fix and passes after it;
- add or change logic that applies rules: decisions, calculations, parsing, state transitions, persistence and migration, privacy or security guards. Cover each rule's cases once, at the smallest seam, in one parameterized test where possible;
- change a contract other code or tools rely on: file formats, decoding of server responses, persisted keys, verdicts of the privacy scanners and checks.

Do not write a test that:

- proves something is gone: a removed button, deleted code, a renamed key. When you remove a feature, delete its tests;
- tests test helpers or other test tooling, unless that tooling judges results for others, like the privacy scanners and the check scripts;
- covers a purely visual or styling change, a copy change, a refactor that keeps behavior, comments or docs. Visual changes are verified with screenshots (see `AGENTS.md`, "UI work"); refactors rely on the existing tests;
- checks what the compiler, the type system or the framework already guarantees, or pins a design value (see section 3);
- checks configuration plumbing that one real run already verifies;
- repeats a case another test already covers.

Prefer extending an existing test file. A new test file needs a reason in the pull request. The pull request states, for every new test, the failure it guards against.

A Python test that needs macOS (Swift, CoreGraphics, `xcrun` or Darwin-only tools)
must first have its full test identity added to `MACOS_PYTHON_TESTS` in
`scripts/run_host_checks.py`, in a separate PR that merges **before** the test relies
on that entry. The host partition is read from the base commit, so adding the entry
in the same PR as the test cannot move that PR's test to the macOS share. The
workflow-policy host check rejects Darwin-only skip conditions whose test identities
are missing from `MACOS_PYTHON_TESTS`.

For a UI method, assign its class or exact method to the behavior areas in
`scripts/ci-ui-areas.json`. The host audit classifies each method exactly once:
names containing `Screenshot` or `Acceptance` are screenshots; all others are
functional. PRs select functional methods by each changed path's area and proven
platform, plus smoke on selected platforms; core, unknown and CI-changing PRs
select all functional methods. The nightly runs the complete default plans,
including locale screenshots. New methods receive a conservative duration weight
and still execute. Scoped packing preserves the exact selection and bounds jobs
by `ceil(selected estimated minutes / 15)`, with base-owned matrix capacities
within five shared macOS slots; see [the UI protocol](CI_UI.md#platform-selection-and-capacity-packing).
Every Python method outside `MACOS_PYTHON_TESTS` belongs to the portable Linux partition. Both
partitions must cover the complete discovered suite without new environment skips.

## 1. Where tests live

| Location | What goes there | Runs by default |
|---|---|---|
| `immichSlidesTests/` | Unit tests: no external network (a hermetic fixture server on loopback is allowed), no private config, no reading source files | Yes |
| `immichSlidesTests/*Live*Tests.swift` (`*LiveTests`, `*LiveIntegrationTests`, `*LiveProbeTests`) | Integration tests against a real Immich server | Skipped when no server is configured |
| `immichSlidesUITests/` | Complete user flows, for example "pick an album, then start playback" | Yes, except Evidence and strict end-to-end tests; those needing a server skip without one |
| `Evidence` test plan | Screenshot production, App Store screenshots, diagnostic captures, performance sampling | No, run on demand |
| `StrictE2E` test plans | Strict end-to-end flows against the local fixture server | No, run with `scripts/run_strict_e2e.py` |
| `TestSupport/` | Helpers shared by several tests | — |

Default-plan server-dependent UI tests can run hermetically through
[`run_fixture_ui_tests.py`](CI_FIXTURE_UI.md). That entry point uses runtime
fixture configuration and records per-test coverage; it never uses private config.
The separate [Xcode Cloud Apple TV plan](XCODE_CLOUD_UI.md) selects the same
pull-request fixture methods explicitly; a host check rejects population or
fixture-copy drift. It is an optional plan and leaves both default plans unchanged.

The [PR UI protocol](CI_UI.md#platform-selection-and-capacity-packing)
classifies every method by its method name: `Screenshot` or `Acceptance` means
screenshot; otherwise it is functional. Its host audit rejects unclassified or
ambiguous methods. Following reader-first activation, PRs run only
functional methods selected by area and proven platform; core, unknown and
CI-changing PRs run all functional methods. The nightly still runs everything.
Add each test to the appropriate area in `scripts/ci-ui-areas.json`; no test-kind
allowlist or assertion change is needed. Default test plans stay unchanged.

A test must be able to fail. Anything that only produces screenshots, logs or numbers without judging them is evidence tooling. It belongs in the `Evidence` test plan.

Unit test fixtures stay under `immichSlidesTests/Fixtures/`. The synchronized unit test target marks
`Fixtures` as an explicit resource folder and copies it into `immichSlidesTests.xctest` on both platforms.
This preserves subdirectories and PNG bytes, including the hashes checked by the pause-hold test;
individual PNG resources would otherwise go through Xcode's PNG processing. Look them up by resource
name, extension and `Fixtures/...` subdirectory with `Bundle(for:)` and a class declared in the unit
test target, never with `#filePath` or `Bundle.main`.
Require the resource URL so a missing fixture fails the test. The compiled tests must work without
the source checkout; see [Relocated unit tests](#relocated-unit-tests).

UI tests that need a server run against the one configured in optional `Config/env.xcconfig` and never change its data. `Config/Debug.xcconfig` includes that file only when present, so a fresh clone builds in Xcode without setup. EXIF diagnostic UI tests also read `IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID` from the environment or that file and skip when the key is unset or empty. Tests that start from the filter summary, including filtered playback, select the first album and the first person that server lists, so its first album must contain photos and it needs at least one person; without them these tests skip. Tests that need specific photos, such as the EXIF diagnostic album, skip when the server does not have them. The album card frame tests need an album cover whose shape differs from the card among the cards the album filter page loads, and the iOS tap test needs such a cover to reach into another card on screen; without them these tests skip.

The `Evidence` plans are `immichSlides-Evidence-iOS.xctestplan` and `immichSlides-Evidence-tvOS.xctestplan`. The default plans skip what the Evidence plans select, plus the strict end-to-end tests that run through the `StrictE2E` plans. Every UI test the default plans leave out must be selected by the Evidence plan of its platform or run by a runner suite, and a test that needs strict-runner inputs must be run by a runner suite and stay out of the Evidence plans; `scripts/test_excluded_ui_tests_have_a_runner.py` fails otherwise. Its list of known gaps is frozen: entries can be removed, never added or swapped. When you add evidence tooling, list it in both files of its platform. Test plan filters do not apply to the unit test target, so evidence unit tests are gated with `.enabled(if: isEvidenceRun)` instead; the Evidence plans set `IMMICHSLIDES_EVIDENCE=1`. To run it, choose the Evidence plan in Xcode, or pass `-testPlan immichSlides-Evidence-iOS` to `xcodebuild`.
Editing either default test plan requires maintainer approval of that exact head.

## 2. Naming

**Files and types**

- The file name matches the type name.
- Unit test suites are named `<Subject>Tests`, for example `PlaybackPoolResolverTests`.
- UI test classes are named `<Feature>UITests`, for example `AlbumFilterUITests`.
- Platform-only tests add `IOS` or `TVOS`, for example `ServerConfigFormTVOSTests`.
- Suite type names stay plain `UpperCamelCase`. Do not use raw identifiers for them, because that would shadow the type under test.

**Unit tests (Swift Testing)**

Name the function with a raw identifier: a short lowercase English sentence saying what should happen, and under what condition. Do not add a separate display name.

```swift
@Test func `empty selection cannot start filtered playback`() { … }
@Test func `startup summary rejects first image shown before slot is ready`() { … }
```

**UI tests (XCTest)**

XCTest only discovers methods starting with `test`. Use `UpperCamelCase` after the prefix, still describing behavior:

```swift
func testSwitchingServerClearsPreviousFilters() { … }
```

**Examples**

| ✅ Good | ❌ Bad | Why |
|---|---|---|
| `` `empty selection cannot start filtered playback` `` | `testFilterEmptySelectionCannotStart` | The good name states the outcome |
| `` `startup summary rejects first image shown before slot is ready` `` | `@Test("PR46 startup schema 应拒绝…")` | Ticket number, mixed languages, duplicate name |
| `testSwitchingServerClearsPreviousFilters` | `testAlbumServerN3SwitchAndImmediateDisplayPolicy` | `N3` is an internal process code |
| `` `input field meets minimum tap height` `` | `输入胶囊高度保持 46` | Pins a design value (see section 3) |

**Never use in test, file or suite names:**

- Ticket or PR numbers: `PR46`, `331-759`, `S306`, `S307`
- Phase or process words: `Phase0`, `phase3A`, `Todo11`, `N2`, `N3`, `V1`, `Journey`, `SelfCheck`, `RED`, `Golden`
- Dates, people's names, non-English text

## 3. Assertions

1. **Every test has at least one assertion that can fail.** Screenshots may accompany assertions but never replace them.
2. **Test rules, not design values.** "Input height is at least 44 pt" and "input text is larger than placeholder text" are good tests. "Height equals 46" is not: a design change should not turn tests red.
3. **Do not assert on source text.** No reading `.swift` files and no `contains("some code")` checks. Enforce structure with the compiler, access control or a lint script.
4. **Every wait has a deadline.** Use `waitForExistence(timeout:)` or polling with a deadline. Unbounded `while` loops are forbidden. Do not use fixed `sleep` calls to wait for UI in new code.
5. **Failure messages are English and optional.** `#expect(a == b)` already prints both values. Add a message only when the expectation is not obvious.
6. **Do not change system settings.** If unavoidable, do it only in the `Evidence` plan and always restore the original value.
7. **Do not depend on the simulator language.** The test plans set `"language" : "zh-Hans"`, so the app under test runs in Simplified Chinese whatever the simulator uses; a UI test that needs another language passes `-AppleLanguages` itself. Unit tests run inside the app, so they compare user-visible text with `String(localized: "English key")` instead of translated text. UI tests run in a separate process that cannot read the app's string catalog: find elements by `accessibilityIdentifier`, and when a UI test must check text, check it in the language the test launches the app in. System UI (alerts such as Save Password?, permission prompts, the keyboard) follows the simulator's language, not the app's. The tests recognize English and Chinese system labels, so run them on a simulator set to English or Chinese; new code that handles system UI matches both, and dismisses Save Password? with Not Now so no test credential is stored.

SwiftUI app alerts are an exception to identifier lookup: the system renders their contents and does not
expose identifiers attached to alert buttons or message Text on iOS or tvOS. Locate the alert, its title,
message and actions by their visible text, preserving the test's language, assertions and deadlines.
Annotate these lookups with `// ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers`.

## 4. When a test may skip

Skip **only when the environment cannot run the test**:

- No test server is configured.
- The device or platform does not apply.
- Required external test data does not exist.

State the reason in one plain English sentence.

An unregistered skip fails the host checks. When adding a test that needs an expected
skip or a tier deselection, include its `scripts/ci-test-policy.json` change in the
same PR: specify the exact tier, environment and reason, plus the owning tier for
a deselection. That CI policy change requires maintainer approval of the PR's exact
head SHA; a later push requires fresh approval. New entries become effective in
the trusted verdict only after that approval. Candidate host checks read their own
policy and may pass earlier; their result is informational. Adding an entry to an
already approved file does not require resetting its whole-file approval state.
See [Static population and verdict policy](CI_POPULATION.md#expected-skips-and-tier-deselections)
for the entry formats and accounting rules.
Approval covers only the registered tier and environment. Host approval does not
authorize unit or UI exceptions; each tier requires measured identities/reasons
and its own head-SHA policy approval.

Strict end-to-end tests need the local fixture server and inputs that `scripts/run_strict_e2e.py` provides. They live in the `StrictE2E` test plans; the default and Evidence plans leave them out. Run without the runner, they fail and name the missing input, so a strict test that lands in another plan cannot hide. The runner also rejects any skipped test.

**When the behavior under test does not happen, fail. Do not skip:**

- A screen or button does not appear.
- A probe or marker is empty.
- A wait times out.
- The app is not in the expected starting state, for example it did not reach first launch.

These are exactly the problems tests exist to catch.

## 5. Size and duplication

- When a test file grows past about 800 lines, move shared steps into `TestSupport/`.
- A large suite or XCTest class can also be split into `<Type>+<Concern>.swift` extensions in its
  existing target. Keep its suite/class name, test methods, traits and platform guards unchanged so
  test-plan and runner selectors still identify the same tests.
- Python `test_*.py` modules remain discovery entry points. Moved methods live in non-discovered
  `*_test_*_cases.py` mixins and shared fixtures in `*_test_fixtures.py`; the original classes inherit
  those methods so discovered test IDs and counts stay unchanged.
  Entry points and their test-class/mixin providers must follow the
  [Python declaration grammar](CI_POPULATION.md#python-declaration-grammar);
  unsupported discovery-changing forms fail host checks with `population-invalid`.
  Use `with patch(...)` inside the method body instead of patch decorators,
  compile regexes inside functions, and use plain helper classes instead of
  decorating classes in these modules.
- Flows that are the same on iOS and tvOS live in shared helpers. Platform files contain only the differences.

## 6. Checklist before submitting

- [ ] Every new test guards a failure that can realistically happen again (section 0), and the pull request names it
- [ ] Names are English and describe behavior: raw-identifier sentences for unit tests, `test…` for UI tests, nothing from the forbidden list
- [ ] No `@Test("…")` display names
- [ ] Every test has an assertion that can fail
- [ ] No pinned design values, no source-text assertions
- [ ] Unit tests compare user-visible text with `String(localized:)`; UI tests find elements by `accessibilityIdentifier`
- [ ] Every wait has a deadline
- [ ] Skips happen only when the environment cannot run the test
- [ ] Screenshot and capture tooling lives in the `Evidence` plan
- [ ] New comments are in English

## 7. Automated check

Classify new waits with the [central test wait API](TEST_WAITS.md). Infrastructure
budgets can scale by the runner's recorded factor; product deadlines and
observation windows never scale. The same conventions entry point enforces the
per-file/function timeout-literal allowlist and rejects production factor access.

`scripts/check_test_conventions.py` enforces the rules a machine can judge, over
`immichSlidesTests/*.swift`, `immichSlidesUITests/*.swift` and `TestSupport/*.swift`:

- **forbidden-name**: ticket/PR/process codes (`PR46`, `S306`, `331-759`, `Phase0`/`phase3A`, `Todo11`,
  `N1`/`N2`/`N3` and `V1` as camelCase tokens, `Journey<Capital>`, `SelfCheck`, `Golden`/`golden`, `RED` as a
  token or `testRED` prefix) anywhere in a test function name, test type name or file name, and CJK
  characters anywhere in a test function name. A forbidden token is flagged wherever it appears in the name,
  not only as a standalone word.
- **display-name**: `@Test("…")` and `@Suite("…")` display-name strings, including when traits follow the
  string. `@Test(.enabled(if: …))` and other trait-only argument lists are fine.
- **swift-testing-name**: every Swift Testing `@Test` function must use a backtick raw-identifier sentence
  (multiple words, lowercase-starting unless the first word is a proper noun or type name — an acronym or a
  camelCase/PascalCase compound), except the two functions listed in the script's exception list.
- **source-text**: no `readProjectSource`/`projectSwiftSourceFiles`, no `String(contentsOf:`/`contentsOfFile`
  on a path ending in `.swift`, and no `#filePath`-relative read of `immichSlides/` sources. Reading fixtures
  (JSON, etc.) is unaffected.
- **unbounded-wait**: a `while` loop whose body consists only of `Task.yield()`/`Task.sleep`/`usleep`/
  `Thread.sleep`/`RunLoop.current.run(until:)` calls, with no deadline, timeout, elapsed-time or iteration
  bound in its condition or body, fails.
- **ui-label-lookup**: UI tests must not locate elements with CJK text (Han characters, kana or Hangul) in query
  subscripts, `matching(identifier:)`, or `NSPredicate` comparisons on `label`, `title` or `value`. Use the
  element's `accessibilityIdentifier`. Predicate checks include `%K` key-path arguments, including literal
  `argumentArray:` arrays, and reversed comparisons. Each comparison is checked against its own operands,
  so CJK used only in an `identifier` clause is not reported because another clause checks visible text.
  Symbolic and keyword comparison operators support modifiers such as `[c]`, `[d]` and `[cd]` in both directions.
  When a UI test intentionally checks displayed copy or interacts with system UI, put
  `// ui-label-lookup: <reason>` on the line immediately above the lookup. The reason must be nonempty,
  and the directive must be a real line comment outside block comments and multiline strings.
  SwiftUI app-alert text lookups use the exception described in section 3, with its explicit directive.

Run it with the other Python tests: `python3 -B -m unittest discover -s scripts -p 'test_*.py'`, or directly
with `python3 scripts/check_test_conventions.py`.

For the complete local host entry point, use `"${PYTHON:-python3}" -B scripts/run_host_checks.py`.
Hosted CI splits the same inventory with `--host-platform linux` and
`--host-platform macos`; runner ownership comes from the trusted base reader.
It runs these Python tests and records each discovered identity, outcome and duration
alongside the other host checks. `scripts/check_all.sh` delegates its host checks to
that entry point and uses the same interpreter for optional unit runners.
Prerequisites and interpreter setup are described in [CONTRIBUTING](../CONTRIBUTING.md#setup).
Commands and the versioned records are described in
[CI_SUMMARY.md](CI_SUMMARY.md).

Existing violations are tracked in `scripts/test_conventions_allowlist.json` by rule, file path and name (no
line numbers, so the list survives unrelated edits). The check fails on any violation not in the allowlist,
and on any allowlist entry that no longer matches a real violation — so the list can only shrink as tests are
renamed. Maintainers can regenerate it with `python3 scripts/check_test_conventions.py --write-allowlist`
after reviewing the resulting diff; this is not a way to make a real violation disappear.

## Relocated unit tests

This verifies fixture packaging as well as independence from the build-time source path. A normal
`xcodebuild test` run cannot prove relocation. Use a disposable clone of the intended commit, never
rename your working checkout. The clone must have no `Config/env.xcconfig`, including dangling
symlinks; do not copy private configuration into it. Keep the default simulator signing.

Run the following in Bash, once for each platform. Set `scheme` to `immichSlides-iOS` or
`immichSlides-tvOS`, and `destination` to an installed simulator of that platform. The scheme and
default test plan have the same name. Use a dedicated simulator and a bounded command;
check at least 80 GiB free on `/System/Volumes/Data` before each Xcode invocation.

```bash
set -euo pipefail
checkout="$PWD"
commit="$(git rev-parse HEAD)"
scheme=immichSlides-iOS
destination='platform=iOS Simulator,id=<UDID>'
relocation_root="$(mktemp -d /tmp/immichslides-relocation.XXXXXX)"
git clone --no-local "$checkout" "$relocation_root/source"
git -C "$relocation_root/source" checkout --detach "$commit"
test ! -e "$relocation_root/source/Config/env.xcconfig"
test ! -L "$relocation_root/source/Config/env.xcconfig"

df -h /System/Volumes/Data
xcodebuild build-for-testing \
    -project "$relocation_root/source/immichSlides.xcodeproj" \
    -scheme "$scheme" -testPlan "$scheme" -destination "$destination" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
    -only-testing:immichSlidesTests \
    '-skip-testing:immichSlidesTests/PlaybackRuntimeEvidenceManifestTests/externalRuntimeJSONLPassesValidator()' \
    -derivedDataPath "$relocation_root/derived"

# Preserve the complete Products directory, including its .xctestrun and symlinks.
ditto "$relocation_root/derived/Build/Products" "$relocation_root/relocated-products"
mv "$relocation_root/source" "$relocation_root/source-hidden"
mv "$relocation_root/derived" "$relocation_root/derived-hidden"
test ! -e "$relocation_root/source"
test ! -e "$relocation_root/derived"
xctestruns=("$relocation_root/relocated-products/"*.xctestrun)
test "${#xctestruns[@]}" -eq 1

df -h /System/Volumes/Data
xcodebuild test-without-building -xctestrun "${xctestruns[0]}" \
    -destination "$destination" -only-testing:immichSlidesTests \
    '-skip-testing:immichSlidesTests/PlaybackRuntimeEvidenceManifestTests/externalRuntimeJSONLPassesValidator()' \
    -resultBundlePath "$relocation_root/relocated.xcresult"
xcrun xcresulttool get test-results summary --path "$relocation_root/relocated.xcresult"
xcrun xcresulttool get test-results tests --path "$relocation_root/relocated.xcresult"
```

Both Xcode commands must exit 0. Inspect the official results: nonzero executed tests, no failures,
and the four metadata fixture tests plus the fixture-set-A pause-hold test must pass. Report skipped
tests and their reasons separately; exit 0 alone does not prove all tests ran. After reading the
results and confirming no process uses the disposable directory, delete `relocation_root`, including
the clone, products, DerivedData and result bundle. The original checkout is untouched throughout.

## Running controlled integration and end-to-end tests

Strict end-to-end tests run the real app against a local public fixture server started by `scripts/run_strict_e2e.py`. They do not access a personal Immich server or need real credentials. Run the Python contract tests separately from the app tests:

```bash
python3 -B -m unittest discover -s scripts -p 'test_*.py'
```

App runs need macOS, a selected Xcode installation and the platform's installed Simulator runtime. Python prerequisites and interpreter setup are described in [CONTRIBUTING](../CONTRIBUTING.md#setup). Before any build, check `df -h /System/Volumes/Data`; the runners require at least 80 GiB available by default. Use `--min-free-gib N` with a non-negative integer to change this local safety threshold, and install any required Simulator runtime through Xcode. Pick a local simulator UDID with `xcrun simctl list devices available`.

```bash
python3 scripts/run_strict_e2e.py --platform ios --destination 'platform=iOS Simulator,id=<UDID>' --suite journey-a --evidence-dir '<outside-repo>/first-connection'
python3 scripts/run_strict_e2e.py --platform ios --destination 'platform=iOS Simulator,id=<UDID>' --suite firstboot-failure --scenario auth-401 --evidence-dir '<outside-repo>/connection-failure'
python3 scripts/run_strict_e2e.py --platform tvos --destination 'platform=tvOS Simulator,id=<UDID>' --suite tvos-n1-cold --evidence-dir '<outside-repo>/tv-connection'
```

Use `python3 scripts/run_strict_e2e.py --help` for the current suite list. Settings, pause/resume and background-return flows use `ios-lifecycle-settings`, `ios-lifecycle-pause` and `ios-lifecycle-background`, or the same names with a `tvos` prefix. The iOS first-wake flow uses `ios-lifecycle-first-wake`; an iPad pause run uses `ios-lifecycle-pause` with an iPad UDID.

`image-failure-recovery` runs only `ScenePresentationContractUITests/testIOSImageFailureRecovery` on iOS in single-photo mode with a 30-second interval, using fixture A and case ID `image-failure-recovery`. Through normal app controls and the fixture-only `/api/test/image-response` endpoint, every fullsize thumbnail request for the startup photo returns HTTP 503 until the mode is reset. The flow turns on the EXIF overlay and fails if that photo's `Fixture 1` caption is visible while it waits for the first stable photo or within 5 seconds after it; the caption identifies the photo because the pixel classifier reads its letterboxed portrait frame as A2. Otherwise the flow verifies the visible replacement, Previous/Redo history and continued playback. The endpoint does not change metadata, other assets, preview responses or the frozen fixture. Result bundles use the existing private export/disposal path. This flow requires the strict runner and is excluded from the default and Evidence plans.

`p2-cache-smoke` on iPad pauses on a recognized single photo with a 30-second interval, then requires both cache completion and a recognized public photo in `cache-returned.png` after returning to playback; as with `p2-cache`, a signed review must list that same photo. It retains its smoke designation and does not claim the full P2 disk-usage review.

Run serially within a checkout because the runner manages temporary test configuration. Use a new evidence directory outside the repository for each run. The runner prepares the fixture and app state, reads official test statistics, checks result contracts and cleans up. Zero selected tests, skipped strict tests, missing evidence or an unknown image are failures. A successful contract check does not replace human visual review; inspect the current run's original screenshots. The separate [iPad host tool](../scripts/ipad-pause-host-testing.md) remains diagnostic tooling and does not replace an XCTest result.

For explicit shard warm-up, build reuse, cold/warm budgets, full simulator resets and
the informational CI tracer, see [Strict runner warm-build tracer](CI_STRICT_RUNNER.md).
Local preparation now completes a bounded simulator boot before starting the app-reset
clock: the boot command has 60 seconds, boot and bootstatus share 600 seconds, and
app/keychain/privacy reset then has 120 seconds with individual commands capped at
60 seconds. Official tests and summary exports each have 60 seconds. These bounds
also apply to fixture UI, listed retries and access-lifecycle runners through the
shared reset/export helpers. Preparation/export timeouts retain failed records and
private quarantine; xcodebuild test-execution timeouts remain case failures.
Versioned nightly shards, exclusions and aggregate rules are documented in
[Skeleton nightly](CI_NIGHTLY.md).

### Known-flaky registry and listed-only retries

`scripts/ci-known-flaky.json` is the authoritative registry. Each entry names one
exact XCTest method and platform (UI) or device/configuration/suite/scenario/fixture
tuple (strict), its tier/environment scope, the shared per-identity tracking issue,
owner, added date, review-by date, symptom and evidence. Wildcards and unit/Python
entries are rejected. Use the same issue when the nightly reporter is introduced;
do not open a second issue for the same identity.

The host gate runs `python3 -B scripts/ci_flaky.py`. It checks the candidate file's
format, duplicates and static test existence on the relevant platform, including
strict-suite membership. It does not contact GitHub or gate on calendar age/issue
state. [CI reporting](CI_REPORT.md) checks expiration and issue state without changing the test verdict. A review date is
inclusive; an entry past that date simply loses retry eligibility. Ordinary passes
stay passes and expiration cannot fail unrelated tests.

PR consumers read the registry from the checked-out merge commit's first parent.
An absent base registry means an empty list, including during initial rollout.
The PR's candidate entries cannot excuse its own failures. CI cannot override the
registry revision. Main push/dispatch/schedule consumers use their tested main revision;
local runs use `HEAD`, with an explicit local `--registry-ref <commit>` available
for isolated acceptance probes. Both the revision and exact policy hash are kept.
Trusted verdict callers supplying `base_registry` must also supply `evaluated_on`
as the trusted producer run's calendar date, rather than the later verdict date.
`ci_verdict` rejects a missing date; producer-provided entries do not select that policy.

Only an official first-call assertion failure (Xcode exit 65) with an exact active
entry may obtain one retry. Official typed failure summaries must classify every
failure for that method as `Assertion Failure`. When Xcode emits `Uncategorized`,
official per-test details must instead identify each failure by XCTest's assertion
message prefix and a positive source line. Crash/unknown messages, missing details
and infrastructure errors are ineligible. The executor resets the app, keychain and simulator
privacy state, then calls `test-without-building` with only the failed method.
Global retry/repetition/iteration flags are rejected. Both calls, official exports,
exit codes, durations and per-test attempts remain recorded. Failed then passed is
`flaky-passed`, which is distinct from an explicit pass; the reporter must not
count it toward closing the issue. A second failure, skip, crash, timeout, missing
or wrong/extra result stays failed. Unlisted failures never receive a second call.

For a built UI target on a dedicated simulator, with a secret-free checkout:

```bash
python3 -B scripts/ci_flaky.py --xctestrun '<Products>/tests.xctestrun' \
  --platform ios --destination 'platform=iOS Simulator,id=<UDID>' \
  --only-testing immichSlidesUITests/ExampleUITests \
  --output-dir '<fresh-outside-repo>/ui-attempts'
```

The UI adapter enumerates the selected compiled tests and compares them with
observations. Each test invocation and the enumeration use `--min-free-gib N`
(default 80). Only GitHub-hosted Actions runners may lower that threshold; their
consumer command can pass `--min-free-gib 30`, using the shared archive disk guard.
Its local declared list is that compiled selection; the [UI producer](CI_UI.md)
independently compares its manifest shards against the admitted static population.
This adapter does not implement shard assignment, fixture selection or trusted
publication. Pass fixture inputs explicitly through the per-run xctestrun; ambient
server inputs are stripped. Each invocation gets an independent private directory
so every raw bundle can be exported/disposed before its directory is removed;
only compact records are suitable for the trusted summary consumer.
The adapter uses `-collect-test-diagnostics never` to keep failed invocations
bounded without simulator diagnostic collection. Execution errors and timeouts
retain all attempted calls in `retry-invocations.json`; a retry timeout records a
second `timed-out` attempt and returns failure.

Strict warm runs opt in with `--listed-retry-device iphone`, `ipad` or `tv`, together
with `--test-without-building`. This preserves the existing cold/default runner and
informational tracer behavior. It uses the same executor and retains per-session
attempt exports, including `filter-person`. `retry-invocations.json` has a `sessions`
map keyed by Xcode log stem, so later sessions retain earlier retries. Every warm
attempt writes `<stem>-reuse.json` with duration, exit code, timeout budget and
Products immutability; a first attempt's receipt moves with its archived outputs.
Recording suites (P2 cases with `video=True`, `server-switch-display` and
`tvos-server-switch-display`) are refused by registry validation and the retry CLI.
Existing visual/evidence validators
still run on the final attempt and must pass. The target UDID's simulator device
type determines the device class; the argument and every official result device
must agree. A retry moves the case's first outputs to `attempt-1/<case>/`, records
service-log byte offsets, and exports only the final attempt's request segment for
timeline validation. Request invariants (unknown paths, 400 bodies, forbidden key
fields and cross-server IDs, as applicable) are audited on every attempt's segment;
any violation fails the run even when the final test passes. Reset logs are appended
across sessions and attempts. An image-validator
failure outside XCTest does not authorize a retry. The hosted shard demonstration
remains an open acceptance criterion of #97 until #94 supplies the UI shards;
standalone access-lifecycle warm conversion remains excluded. #140 tracks its
flake but is not registered because the UI tier excludes that test.

Every strict suite and both access-lifecycle runners write raw XCTest result bundles under
`Path(tempfile.gettempdir()) / "immichSlides-strict-e2e-private"`, outside `--evidence-dir`.
The root and each new holding directory have owner-only permissions (`0o700`); a symlink root is
refused. On macOS this is inside the per-user temporary directory. Raw activities can contain
fixture keys or synthetic PIN input, so never upload these bundles.

During finalization, including failed runs, the runner exports official test identities and outcomes
with `xcrun xcresulttool get test-results tests --compact` to `official-tests.json` and retains
`official-summary.json`. Exports containing test credentials are refused before writing.
After export, cleanup and the unchanged sensitive scanner succeed, a successful run deletes its
bundle and writes `result-bundle-disposal.json`, including the export's SHA-256. A failed run,
export, scan or cleanup keeps the bundle private and records `result-bundle-quarantine.json`;
inspect it locally and delete it after diagnosing the failure. Finalization failures cannot make
a run pass. Unexpected evidence or validator exceptions also retain the private bundle; disposal
requires completed checks, and an existing Xcode failure exit code takes precedence over handled
evidence or cleanup errors. The existing P2 export and disposal contract stays unchanged.

`filter-person` runs three isolated sessions (`normal`, `conflict-normal`, `nofaces`). Each has its
own private bundle, `official-tests-<session>.json`, `official-summary-<session>.json` and disposal
or quarantine record with the same suffix. `official-summary.json` remains the suite aggregate;
the case manifest records each session export's hash. A later session failure preserves all
attempted sessions, including earlier passes, without claiming the suite passed.

Run the standalone access-protection flows with:

```bash
python3 scripts/run_access_lifecycle_ios.py --device iphone --destination 'platform=iOS Simulator,id=<UDID>' --evidence-dir '<outside-repo>/access-iphone'
python3 scripts/run_access_lifecycle_ios.py --device ipad --destination 'platform=iOS Simulator,id=<UDID>' --evidence-dir '<outside-repo>/access-ipad'
python3 scripts/run_access_lifecycle_tvos.py --platform tvos --destination 'platform=tvOS Simulator,id=<UDID>' --evidence-dir '<outside-repo>/access-tv'
```

These flows use the same bundle export/disposal mechanism and check both fixture keys and synthetic
PINs. Their `--print-command` mode previews a private-path placeholder without allocating a bundle.
They remain separate from the strict suite table.

The offline unit runner and `check_all.sh --with-unit-tests` retain their explicitly requested
local bundles for inspection; they are excluded from the strict evidence/upload path. They do not
produce scanner-approved public evidence and their raw bundles must not be uploaded. The album/server
narrow entry point only prints device commands and refuses device execution; its manual command
output is also excluded. The iPad pause host tool does not produce XCTest bundles and remains
diagnostic-only. Future matrix consumers must exclude these unconverted manual/local entries
explicitly rather than treating their outputs as scanned strict results.

The CI [unit archive consumer](CI_UNIT_TESTS.md) is a separate converted entry point:
it uses the existing private bundle export/disposal helpers, exports official results
even on failure, scans compact records before upload and records archive provenance.
It runs every unit identity, including the conditional Live and Evidence skips; its
exact hermetic skip identities/reasons use the active per-tier unit policy described
in [CI_UNIT_TESTS](CI_UNIT_TESTS.md). This approval does not establish live coverage.

The original motion and visibility collectors in `ScenePresentationContractUITests` write `<displayMode>-contract-evidence.json` and `<displayMode>-trace.txt` to the directory in `TEST_RUNNER_SCENE_PRESENTATION_CONTRACT_RUN_DIR`. Set it through the environment of `xcodebuild` to a directory outside the repository; on iOS these collectors skip when it is unset, on tvOS it is optional. No runner script sets this variable. The directory is created with owner-only permissions (`0o700`) and the run refuses a path inside a Git worktree. The evidence uses schema `scene-presentation-contract-evidence-v3`: product SHA, device name, runtime identifier and video path are omitted when the run cannot observe them, never filled with a placeholder.

### Filter summary runtime screenshots

The Filter Summary visual UI tests save runtime screenshots only when `IMMICHSLIDES_SCREENSHOT_EXPORT_DIR` or `TEST_RUNNER_IMMICHSLIDES_SCREENSHOT_EXPORT_DIR` is set; otherwise they save nothing. Use a directory outside any Git worktree. It is created with owner-only permissions (`0o700`), each PNG is written with `0o600`, and a path that cannot be prepared fails the test. The screenshots can show real library photos: keep them private and delete them after review.

### Optional SmartFill evidence inputs

`PlaybackSmartFillVisualUITests` runs from the Evidence plans. Its scene collectors default to 20 scenes;
`IMMICHSLIDES_SMARTFILL_SCENE_COUNT` overrides that count, followed by
`TEST_RUNNER_IMMICHSLIDES_SMARTFILL_SCENE_COUNT`. Fixed-album cases require
`IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID` or `TEST_RUNNER_IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID` and only read
that album from the configured server.

Set `IMMICHSLIDES_SMARTFILL_EVIDENCE_ROOT` or `TEST_RUNNER_IMMICHSLIDES_SMARTFILL_EVIDENCE_ROOT` to an
output directory outside any Git worktree. Runtime manifests and screenshots are written under
`ui-runtime/<device>`. The general `TEST_RUNNER_UI_TEST_EVIDENCE_DIR` / `UI_TEST_EVIDENCE_DIR` input is
used by the other evidence helpers. Motion evidence uses `TEST_RUNNER_SMARTFILL_MOTION_EVIDENCE_DIR`,
then `SMARTFILL_MOTION_EVIDENCE_DIR`, or the SmartFill runtime directory's `motion-runtime` child. Keep real-server
evidence private and delete it after review. See the helper implementations for timing and tracing inputs.

### Optional reviewed screenshot calibration dataset

The Python photo-identity calibration cases accept `STRICT_E2E_REVIEWED_SCREENSHOTS`, an external
directory of reviewed public-fixture captures. The authoritative relative-path list is
`REVIEWED_SCREENSHOT_RELATIVE_PATHS` in [test_strict_e2e_photo_identity.py](../scripts/test_strict_e2e_photo_identity.py).
It includes iPhone/iPad history, an iPad pause-window transition and tvOS pause/resume captures. An unset
input skips those calibration cases; a configured directory with missing files fails.

Obtain the complete reviewed capture set from the maintainer, or regenerate the history and pause flows
with the strict runner's `journey-b`, `pause-window` and `tvos-flow` suites on their applicable devices.
Review the exported originals against the marks, history order and transition expectations in
`ReviewedScreenshotCalibrationTests` before assigning the required relative paths; runner exports do
not automatically produce this dataset's filenames. Run with
`STRICT_E2E_REVIEWED_SCREENSHOTS='<external-directory>' python3 -B -m unittest discover -s scripts -p 'test_strict_e2e_photo_identity.py'`.
Synthetic images do not replace reviewed Simulator captures for these calibration cases.
The host entry point removes `STRICT_E2E_REVIEWED_SCREENSHOTS` from every check's
environment so its `hermetic` skip policy stays accurate. Run reviewed calibration
directly with the unittest command above; setting the variable for `check_all.sh`
does not enable calibration.

### Standalone SmartFill planner benchmark

Run from the repository root on macOS with Xcode's Swift compiler. The benchmark compiles the real
planner and its model dependencies; it does not launch the app or access a server. Use an output path
outside the repository:

```bash
xcrun swiftc -O -parse-as-library \
    scripts/smartfill_planner_benchmark.swift \
    immichSlides/Shared/Model/ImmichModels.swift \
    immichSlides/Shared/Model/ImmichTypes.swift \
    immichSlides/Shared/Model/LocalizedText.swift \
    immichSlides/Shared/Model/PlaybackScene.swift \
    immichSlides/Shared/Model/PlaybackProtection.swift \
    immichSlides/Shared/Model/PlaybackSmartFillTypes.swift \
    immichSlides/Shared/Model/PlaybackSmartFillLayoutPolicy.swift \
    immichSlides/Shared/Model/PlaybackSmartFillRejectReason.swift \
    immichSlides/Shared/Model/PlaybackSmartFillPlanner.swift \
    immichSlides/Shared/Model/PlaybackSmartFillPlanner+Search.swift \
    immichSlides/Shared/Model/PlaybackSmartFillPlanner+Evaluation.swift \
    immichSlides/Shared/Model/PlaybackSmartFillPlanner+Geometry.swift \
    immichSlides/Shared/Model/PlaybackSmartFillPlanner+Readback.swift \
    immichSlides/Shared/Model/PlaybackSessionEngine.swift \
    immichSlides/Shared/Model/PlaybackSessionEngine+ScenePresentationState.swift \
    immichSlides/Shared/Model/ScenePresentationTypes.swift \
    immichSlides/Shared/Model/ScenePresentationEffect.swift \
    immichSlides/Shared/Model/SceneActiveTimeClock.swift \
    immichSlides/Shared/Model/SceneLifecycleContract.swift \
    immichSlides/Shared/Model/PlaybackIntervalPolicy.swift \
    -o /tmp/immichslides-planner-benchmark
/tmp/immichslides-planner-benchmark --max-wall-ms 1000
rm /tmp/immichslides-planner-benchmark
```

`--max-wall-ms` bounds the corpus loop and reports whether it was capped. `--stream` prints each call;
`--require-max-ms` fails when the slowest call reaches the supplied limit. Keep the corpus fingerprint,
compiler options and execution environment identical when comparing timing results.

### Strict end-to-end case identifiers

`case-manifest.json` lists the case IDs a suite covers. They name coverage that the mapped XCTest selector already implements; they are not a separate spec. `scripts/run_strict_e2e.py` (`CASE_E2E_IDS`) and `scripts/strict_e2e_p2_contract.py` (`P2_CASES`) are the sources of truth.

| ID | Coverage |
|---|---|
| `E2E-P0-01` | First-boot server setup |
| `E2E-P0-02` | First-boot setup survives a cold relaunch |
| `E2E-P0-03` | Random or core playback is reached |
| `E2E-P0-04` | Album filter members, empty album, or album edit-switch |
| `E2E-P0-05` | Person filter rules. Vision solo-only is reported `UNVERIFIED` on simulators and has no device path yet ([#80](https://github.com/sudoHG/immichSlides/issues/80)) |
| `E2E-P0-06` | Server-switch isolation |
| `E2E-P0-07` | A late image keeps the current scene |
| `E2E-P0-08`, `E2E-P0-09` | Playback control state on the iOS and tvOS playback flows |
| `N1` | tvOS first-boot save and configured cold launch |
| `E2E-P2-01` | EXIF toggle ownership (`p2-exif`) |
| `E2E-P2-02` | Clearing the disk cache from Settings and returning to playback (`p2-cache`) |
| `E2E-P2-03` | System Reduce Motion on and off, single and SmartFill scenes (`p2-reduce-motion`) |
| `E2E-P2-04` | SmartFill multi-photo layout in both iPad orientations (`p2-ipad-layout`) |
| `E2E-P2-05` | Rotation during playback on iPhone and iPad (`p2-rotation`) |

## Generating a local privacy page

Diagnostic identity fields are opaque correlation values. Playback request lifecycle JSONL hashes
`assetId` and `sceneId` at serialization with `PlaybackImageRequestLifecycleDiagnostics.redactedHash`;
request IDs remain unchanged so request events can still be joined. Motion seed summaries hash scene,
slot and asset identities without changing the seed used for animation. Motion probes use the same
identity tokens as the seed summary, including their diagnostic accessibility identifier suffix.
iOS and Apple TV product trace
`slotRefs` uses `PlaybackScene.diagnosticSlotReferences`, the same ordered ledger tokens as the
runtime manifest. Consumers must compare these tokens rather than raw server IDs.

`PRIVACY_POLICY.md` stays in this repository because the app bundles it for tvOS. The official website is maintained separately in [sudoHG/immichSlides-web](https://github.com/sudoHG/immichSlides-web).

`python3 scripts/build_privacy_policy_page.py` generates the privacy page and root redirect in the git-ignored `build/privacy-site/` directory. Use `--output-dir <directory>` to choose another output directory; relative paths resolve from the current working directory. This only generates local files and does not publish the website.
