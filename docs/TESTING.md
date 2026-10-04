# Testing conventions

Rules for adding or changing tests. Each rule can be checked on its own. When in doubt, copy the examples.

Existing tests are being migrated to these rules. Do not rewrite unrelated tests while working on something else.

## 1. Where tests live

| Location | What goes there | Runs by default |
|---|---|---|
| `immichSlidesTests/` | Unit tests: no network, no private config, no reading source files | Yes |
| `immichSlidesTests/*LiveTests.swift` | Integration tests against a real Immich server | Skipped when no server is configured |
| `immichSlidesUITests/` | Complete user flows, for example "pick an album, then start playback" | Yes, except Evidence and strict end-to-end tests; those needing a server skip without one |
| `Evidence` test plan | Screenshot production, App Store screenshots, diagnostic captures, performance sampling | No, run on demand |
| `StrictE2E` test plans | Strict end-to-end flows against the local fixture server | No, run with `scripts/run_strict_e2e.py` |
| `TestSupport/` | Helpers shared by several tests | — |

A test must be able to fail. Anything that only produces screenshots, logs or numbers without judging them is evidence tooling. It belongs in the `Evidence` test plan.

UI tests that need a server run against the one configured in optional `Config/env.xcconfig` and never change its data. `Config/Debug.xcconfig` includes that file only when present, so a fresh clone builds in Xcode without setup. Tests that start from the filter summary, including filtered playback, select the first album and the first person that server lists, so its first album must contain photos and it needs at least one person; without them these tests skip. Tests that need specific photos, such as the EXIF diagnostic album, skip when the server does not have them. The album card frame tests need an album cover whose shape differs from the card among the cards the album filter page loads, and the iOS tap test needs such a cover to reach into another card on screen; without them these tests skip.

The `Evidence` plans are `immichSlides-Evidence-iOS.xctestplan` and `immichSlides-Evidence-tvOS.xctestplan`. The default plans skip what the Evidence plans select, plus the strict end-to-end tests that run through the `StrictE2E` plans. Every UI test the default plans leave out must be selected by the Evidence plan of its platform or run by a runner suite, and a test that needs strict-runner inputs must be run by a runner suite and stay out of the Evidence plans; `scripts/test_excluded_ui_tests_have_a_runner.py` fails otherwise. Its list of known gaps is frozen: entries can be removed, never added or swapped. When you add evidence tooling, list it in both files of its platform. Test plan filters do not apply to the unit test target, so evidence unit tests are gated with `.enabled(if: isEvidenceRun)` instead; the Evidence plans set `IMMICHSLIDES_EVIDENCE=1`. To run it, choose the Evidence plan in Xcode, or pass `-testPlan immichSlides-Evidence-iOS` to `xcodebuild`.

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

Strict end-to-end tests need the local fixture server and inputs that `scripts/run_strict_e2e.py` provides. They live in the `StrictE2E` test plans; the default and Evidence plans leave them out. Run without the runner, they fail and name the missing input, so a strict test that lands in another plan cannot hide. The runner also rejects any skipped test.

**When the behavior under test does not happen, fail. Do not skip:**

- A screen or button does not appear.
- A probe or marker is empty.
- A wait times out.
- The app is not in the expected starting state, for example it did not reach first launch.

These are exactly the problems tests exist to catch.

## 5. Size and duplication

- When a test file grows past about 800 lines, move shared steps into `TestSupport/`.
- Flows that are the same on iOS and tvOS live in shared helpers. Platform files contain only the differences.

## 6. Checklist before submitting

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

Existing violations are tracked in `scripts/test_conventions_allowlist.json` by rule, file path and name (no
line numbers, so the list survives unrelated edits). The check fails on any violation not in the allowlist,
and on any allowlist entry that no longer matches a real violation — so the list can only shrink as tests are
renamed. Maintainers can regenerate it with `python3 scripts/check_test_conventions.py --write-allowlist`
after reviewing the resulting diff; this is not a way to make a real violation disappear.

## Running controlled integration and end-to-end tests

Strict end-to-end tests run the real app against a local public fixture server started by `scripts/run_strict_e2e.py`. They do not access a personal Immich server or need real credentials. Run the Python contract tests separately from the app tests:

```bash
python3 -B -m unittest discover -s scripts -p 'test_*.py'
```

App runs need macOS, a selected Xcode installation, the platform's installed Simulator runtime, Python 3 and Pillow. Python contract tests also require Swift (included with Xcode) and the zstd CLI (`brew install zstd`). Before any build, check `df -h /System/Volumes/Data`; the runners require at least 80 GiB available by default. Use `--min-free-gib N` with a non-negative integer to change this local safety threshold, and install any required Simulator runtime through Xcode. Pick a local simulator UDID with `xcrun simctl list devices available`.

```bash
python3 scripts/run_strict_e2e.py --platform ios --destination 'platform=iOS Simulator,id=<UDID>' --suite journey-a --evidence-dir '<outside-repo>/first-connection'
python3 scripts/run_strict_e2e.py --platform ios --destination 'platform=iOS Simulator,id=<UDID>' --suite firstboot-failure --scenario auth-401 --evidence-dir '<outside-repo>/connection-failure'
python3 scripts/run_strict_e2e.py --platform tvos --destination 'platform=tvOS Simulator,id=<UDID>' --suite tvos-n1-cold --evidence-dir '<outside-repo>/tv-connection'
```

Use `python3 scripts/run_strict_e2e.py --help` for the current suite list. Settings, pause/resume and background-return flows use `ios-lifecycle-settings`, `ios-lifecycle-pause` and `ios-lifecycle-background`, or the same names with a `tvos` prefix. The iOS first-wake flow uses `ios-lifecycle-first-wake`; an iPad pause run uses `ios-lifecycle-pause` with an iPad UDID.

Run serially within a checkout because the runner manages temporary test configuration. Use a new evidence directory outside the repository for each run. The runner prepares the fixture and app state, reads official test statistics, checks result contracts and cleans up. Zero selected tests, skipped strict tests, missing evidence or an unknown image are failures. A successful contract check does not replace human visual review; inspect the current run's original screenshots. The separate [iPad host tool](../scripts/ipad-pause-host-testing.md) remains diagnostic tooling and does not replace an XCTest result.

Result bundles normally go in the directory passed to `--evidence-dir`. The `p2-*` suites instead write them under `Path(tempfile.gettempdir()) / "immichSlides-strict-e2e-private"`, with a separate temporary subdirectory per run and a root created with permissions `0o700`. On macOS this is inside the per-user temporary directory. After a successful run and cleanup, the runner deletes the private bundle and records its disposal in `result-bundle-disposal.json` in the evidence directory. Retained bundles from failed runs or cleanup are recorded in `result-bundle-quarantine.json` there; keep them private.

## Generating a local privacy page

`PRIVACY_POLICY.md` stays in this repository because the app bundles it for tvOS. The official website is maintained separately in [sudoHG/immichSlides-web](https://github.com/sudoHG/immichSlides-web).

`python3 scripts/build_privacy_policy_page.py` generates the privacy page and root redirect in the git-ignored `build/privacy-site/` directory. Use `--output-dir <directory>` to choose another output directory; relative paths resolve from the current working directory. This only generates local files and does not publish the website.
