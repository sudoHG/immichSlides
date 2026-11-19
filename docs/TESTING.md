# Testing conventions

These rules apply to new or changed tests. Do not rewrite unrelated tests.
[CONTRIBUTING](../CONTRIBUTING.md#setup) owns setup and local snapshot commands.

PR CI runs host checks, build and offline units through `ci-gate`, plus the two
privacy checks. It no longer compiles or executes the UI test target.
The [sole nightly](CI_NIGHTLY.md) compiles/runs smoke: seven core flows when
main changes, all 23 on manual dispatch before release. Smoke results are
reported and never block merges. There is no CI approval step.

## 0. When to write a test

Every test must guard a failure that can realistically happen again.
If you cannot name that failure in one sentence, do not write the test.

Write a test when fixing a logic bug, changing rules (calculation, parsing, state,
persistence, migration, privacy/security), or changing a consumed file/response
contract. Write the regression first and show it fails without the fix.
Cover each rule once at the smallest seam; prefer one parameterized test.

Do not write tests that prove removal, test ordinary helpers, duplicate coverage,
pin design values, repeat compiler/framework guarantees or check configuration
plumbing that a real run already verifies. Docs, comments, copy, visual changes
and behavior-preserving refactors do not need new tests.
Delete tests with the removed code path. Visual changes need running-app evidence
under [AGENTS.md](../AGENTS.md#ui-work).

Prefer an existing test file. A new file needs a reason in the PR.
A new workflow, validator or UI test needs maintainer approval before implementation.
Host partition rules live in `scripts/run_host_checks.py`; Darwin-only Python
tests must have base-owned partition support before relying on it.

## 1. Where tests live

| Location or plan | Responsibility | Execution |
| --- | --- | --- |
| `immichSlidesTests/` | Unit behavior; no external network/private config/source reads; loopback fakes allowed | Unit-only default plans |
| Unit `*Live*Tests.swift` | Conditional real-server integration | Skip without configured data; no live nightly |
| `SmokeFlowIOSUITests` / `SmokeFlowTVOSUITests` | Core user/system/remote boundaries | Smoke runner |
| `immichSlides-Evidence-iOS` / `immichSlides-Evidence-tvOS` | App Store screenshots plus the unit target's conditional evidence cases | Manual only |
| `TestSupport/` | Shared test helpers | Never in the App target |

The default plans select only `immichSlidesTests`.
Historical `StrictE2E-iOS` / `StrictE2E-tvOS` plans select only SmokeFlow classes.
Evidence plans select the platform's App Store screenshot class and unit target,
and set `IMMICHSLIDES_EVIDENCE=1`. Screenshot execution has its own additional
opt-in; see [App Store screenshots](#app-store-screenshots).

Unit fixtures belong under `immichSlidesTests/Fixtures/`, copied as a folder into
both platform test bundles. Resolve them through `Bundle(for:)`, resource name,
extension and subdirectory; require missing resources to fail.
Never use `#filePath` or `Bundle.main` for unit fixtures.
[Source-free unit consumers](CI_UNIT_TESTS.md) verify relocation and packaging.

## 2. Naming

File/type names match. Unit suites are `<Subject>Tests`; UI classes are
`<Feature>UITests`. Platform suffixes stay `IOS` / `TVOS`.
Suite types use ordinary UpperCamelCase, not raw identifiers.

Swift Testing methods use short lowercase-starting English behavior sentences:

```swift
@Test func `empty selection cannot start filtered playback`() { … }
```

XCTest methods start with `test` followed by UpperCamelCase behavior.
Do not add display-name strings to `@Test` or `@Suite`.
Do not put PR/ticket numbers, dates, people, non-English words or process labels
such as Phase, Journey, SelfCheck, Golden or RED in names.

## 3. Assertions

Every behavioral test needs an assertion that can fail. Screenshots/logs do not
replace it. Assert rules, not design constants. Do not read Swift source to assert
implementation text.

Every wait has a deadline. Use [TestWait](TEST_WAITS.md); fixed sleeps are not
readiness gates. Product deadlines/observation spans never scale.
Polling reads are non-failing; only the outer deadline fails.
Take one fallible snapshot per observation and retain its satisfying values.
Do not check `exists` then make a second live value/enabled/hittable query.
Unknown or failed snapshots cannot prove absence or readiness.

Navigation shares one monotonic hang guard across preparation, one action per
transaction and readback. No guard is created inside a poll; optional branches
use one non-polling probe. Product response windows stay separate.
The approved smoke guard is 120 seconds; the shared default remains 60.
[TEST_WAITS](TEST_WAITS.md) documents late-read and focus semantics.

Use stable accessibility identifiers. The plans launch the App in Simplified
Chinese; unit copy assertions use `String(localized:)`.
System dialogs follow simulator language; handle English/Chinese and decline
Save Password rather than storing credentials.
SwiftUI alert content does not expose identifiers: visible-text lookups need
`// ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers`.
Intentional system/copy lookups need an immediately preceding nonempty directive.

Do not alter system settings in behavioral tests. Unavoidable evidence changes
must restore the original setting. The dedicated smoke simulator reset is the
documented [exception](CI_STRICT_RUNNER.md#shared-simulator-reset).

## 4. When a test may skip

Skip only when the environment cannot run it: missing configured server/data or
an inapplicable platform/device. Give a plain English reason.
A missing screen/control, empty probe, timeout or wrong starting state fails.

Exact expected skip identities, dimensions and reasons belong in
`scripts/ci-test-policy.json`; [population accounting](CI_POPULATION.md)
rejects unregistered skips and missing compilation. A hermetic skip is not live
coverage. Do not add retries, loosen thresholds or register product failures
as environmental exceptions.

## 5. Size and duplication

Keep each rule covered once. Shared unit helpers stay near unit tests; helpers
used by both targets live in TestSupport. Large suites can split into
`<Type>+<Concern>.swift` without changing suite/method identities or guards.

Python `test_*.py` files are discovery entry points. Moved methods use
`*_test_*_cases.py` mixins and `*_test_fixtures.py` providers.
Follow the [declaration grammar](CI_POPULATION.md#python-declaration-grammar):
unconditional explicit imports, statically resolvable classes, no discovery hooks
or class decorators. Patch inside method bodies.

## 6. Before submitting

Report the realistic failure each new test guards and its before/after proof.
Check naming, failing assertions, bounded waits, localization, exact skip reasons
and both platforms. Keep screenshot tooling in Evidence plans.
List failures separately from `NOT_RUN` or environment-blocked verification.

## 7. Automated check

`scripts/check_test_conventions.py` checks names, display names, source reads,
bounded waits, identifier lookups, hang-guard use and timeout literals across
unit/UI/TestSupport Swift files. It also validates the smoke manifest/selectors
and plan exclusions. Existing convention/timeout allowlists may only lose stale
entries; do not regenerate them to hide violations.

```bash
python3 -B scripts/check_test_conventions.py
scripts/check_all.sh
```

The host runner compares static Python declarations, unittest discovery and
observed identities. [Host records](CI_SUMMARY.md) explain shards, limits and
failure accounting; [unit consumers](CI_UNIT_TESTS.md) explain Swift enumeration.
Local raw unit bundles are private and must not be uploaded.

## Smoke flows

There are ten iOS methods and ten tvOS methods, mapped to 23 device flows.
The authoritative per-device/configuration selectors are
[`smoke-flows.json`](../scripts/smoke-flows.json), validated against compiled-source
platform inventory. [Smoke nightly](CI_NIGHTLY.md) owns scope/scheduling;
[Smoke runner](CI_STRICT_RUNNER.md) owns build/reset/fixture/export commands.

## App Store screenshots

The Evidence plans retain `AppStoreScreenshotUITests` and
`AppStoreScreenshotTVOSUITests`, including their support extensions.
Evidence mode alone does not enable them: explicitly set
`TEST_RUNNER_APP_STORE_SCREENSHOT_RUN=1`.

Run direct Xcode commands only in a configuration-free checkout, using a
dedicated matching simulator, task-specific DerivedData and fresh output outside the repository
and at least 80 GiB free. The commands below select only the connection screen,
which uses the built-in display-only demo prefill and needs no server.
They do not submit or save that configuration.

```bash
df -h /System/Volumes/Data
TEST_RUNNER_APP_STORE_SCREENSHOT_RUN=1 \
TEST_RUNNER_APP_STORE_SCREENSHOT_PLATFORM_GROUP=iPhone_6_1 \
TEST_RUNNER_APP_STORE_SCREENSHOT_LOCALES=zh-Hans \
TEST_RUNNER_APP_STORE_SCREENSHOT_SLOTS=07_connect_immich \
TEST_RUNNER_APP_STORE_SCREENSHOT_OUTPUT_ROOT='<fresh-outside-repo>/screenshots-ios' \
xcodebuild test -project immichSlides.xcodeproj -scheme immichSlides-iOS \
  -testPlan immichSlides-Evidence-iOS -configuration Debug \
  -destination 'platform=iOS Simulator,id=<IPHONE-UDID>' \
  -derivedDataPath .derivedData/screenshots-ios \
  -resultBundlePath '<fresh-outside-repo>/screenshots-ios.xcresult' \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:immichSlidesUITests/AppStoreScreenshotUITests/testSubmissionPrimarySelectedScreenshots

df -h /System/Volumes/Data
TEST_RUNNER_APP_STORE_SCREENSHOT_RUN=1 \
TEST_RUNNER_APP_STORE_SCREENSHOT_OUTPUT_ROOT='<fresh-outside-repo>/screenshots-tv' \
xcodebuild test -project immichSlides.xcodeproj -scheme immichSlides-tvOS \
  -testPlan immichSlides-Evidence-tvOS -configuration Debug \
  -destination 'platform=tvOS Simulator,id=<TV-4K-UDID>' \
  -derivedDataPath .derivedData/screenshots-tv \
  -resultBundlePath '<fresh-outside-repo>/screenshots-tv.xcresult' \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:immichSlidesUITests/AppStoreScreenshotTVOSUITests/testZhHansTVOS4KConnectScreenshot
```

For iPad use `APP_STORE_SCREENSHOT_PLATFORM_GROUP=iPad_11` and its UDID.
Other available platform groups are `iPhone_6_9`, `iPhone_6_3` and `iPad_13`;
primary 6.9-inch/13-inch groups enforce accepted pixel sizes.
The selected-batch method on either platform accepts comma-separated
`APP_STORE_SCREENSHOT_LOCALES` / `APP_STORE_SCREENSHOT_SLOTS`.
Omitting slots requests every slot. Photo/filter slots require an explicitly
authorized matching screenshot dataset/configuration; smoke fixtures do not
supply the hard-coded screenshot brief's albums and people.
Do not substitute a personal server for an offline run.
Outputs include PNGs and a manifest; review blockers, locale, pixel size and
actual images before accepting. Keep private photos out of public evidence and
delete task-owned results/products after checking path holders.
