# Contributing to immichSlides

Thanks for helping out. immichSlides is a SwiftUI photo slideshow client for [Immich](https://immich.app) servers on iOS, iPadOS and tvOS. This guide covers how to propose, build, test and submit a change.

## Before you start

- **Open an issue first** for anything beyond a small fix (new feature, behavior change, UI change, refactor, new dependency). Agree on the approach before writing code.
- **One problem per pull request.** No drive-by refactors, reformatting or cleanup of unrelated code.
- If a change turns out bigger than planned, stop and update the issue instead of growing the PR.

## Setup

Use the exact [CI pins](docs/CI_TOOLCHAIN.md): Xcode and installed iOS/tvOS
Simulator runtimes, Python with Pillow/PyYAML, Swift and zstd.
Deployment targets are iOS/tvOS 18.6. Setup installs only a task-owned Python
environment; it does not download Xcode or simulator resources.

```bash
/usr/bin/python3 scripts/setup_ci_python.py --python /usr/bin/python3 \
  --venv /tmp/immichslides-python --verify-toolchain
source /tmp/immichslides-python/bin/activate
scripts/check_all.sh
```

`check_all.sh` honors `PYTHON`; its child checks keep that interpreter.
Local script entry points test a clean snapshot of tracked working changes plus
untracked non-ignored files. They exclude private configuration without following
its symlinks and strip ambient test/server inputs.
The tested tree is printed and recorded in `local-snapshot.json` beside output,
or at `--snapshot-record PATH`. `--strict-ci` refuses dirty input.
`--config NAME=VALUE` supplies explicit runtime inputs without recording values.
`--allow-private-config` opts into the original checkout for explicitly authorized
private testing; those results are never public evidence. Archive/fixture
preflight still rejects private configuration.

Direct Xcode/GUI commands retain their normal configuration behavior.
`Config/env.xcconfig` is optional and never needed for offline units.
`--prepare-example-config` is a separate explicit setup operation; it does not
overwrite an existing file.

Run units with `immichSlides-iOS` / `immichSlides-tvOS`; `immichSlides` is
build/run/archive only. Choose the actual pinned simulator UDID and fresh paths:

```bash
df -h /System/Volumes/Data
xcrun simctl list devices available
python3 -B scripts/run_offline_unit_tests.py --platform ios \
  --destination 'platform=iOS Simulator,id=<IPHONE-UDID>' \
  --derived-data-path .derivedData/local-ios \
  --result-bundle-path '<fresh-outside-repo>/ios.xcresult'
df -h /System/Volumes/Data
python3 -B scripts/run_offline_unit_tests.py --platform tvos \
  --destination 'platform=tvOS Simulator,id=<TV-4K-UDID>' \
  --derived-data-path .derivedData/local-tvos \
  --result-bundle-path '<fresh-outside-repo>/tvos.xcresult'
```

No server or credentials are needed. The runner checks 80 GiB free before Xcode.
Exit 124 or zero selected tests is not a pass. Conditional skips are reported
separately. DerivedData stays outside the disposable snapshot and survives runs;
keep it task-specific and delete it and private raw bundles after inspection,
once no process holds them. Cancellation finalizes/reaps owned child groups before
snapshot removal; uncertain cleanup retains the path for diagnosis.

Smoke reproduction uses public loopback fixtures and the
[smoke runner](docs/CI_STRICT_RUNNER.md).
Manual App Store screenshots run from the Evidence plans with the
[exact commands and opt-in](docs/TESTING.md#app-store-screenshots).
Optional once-per-clone privacy hooks: `scripts/install_git_privacy_hooks.sh`.

## Using AI coding agents

Welcome, with one rule: the agent must follow [AGENTS.md](AGENTS.md) (`CLAUDE.md` imports it). You are responsible for everything you submit. Read the diff yourself, run the checks yourself, and report results honestly.

## Code style

- Formatting and lint are enforced by `swift-format` using [`.swift-format`](.swift-format).
- Run this before every push; it is the same set of checks a reviewer will run:

  ```bash
  scripts/check_all.sh                     # formatting, conventions, release guards, localization, prerequisites, workflow policy, Python tests
  scripts/check_all.sh --output-dir '<fresh-outside-repo>' # keep the host summary and identity in host-records/
  scripts/check_all.sh --with-unit-tests \
      --ios-destination 'platform=iOS Simulator,id=<UDID>' \
      --tvos-destination 'platform=tvOS Simulator,id=<UDID>' \
      --output-dir '<outside-repo>'        # additionally runs the offline unit tests for iOS and tvOS
  ```

- Naming and SwiftUI conventions (View / ViewModel / Store / Service roles, `@MainActor` for UI-driving types, no network or credential access in views) are in [AGENTS.md](AGENTS.md). Code comments are written in English and explain why, not what.
- Architecture overview: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## CI

PR CI is `ci-gate` (host checks, build and offline unit tests) plus
`privacy-preflight-bootstrap` and `privacy-preflight-trusted`.
The gate's own job results are the PR result; there is no status publisher or
per-push CI approval step. GitHub may separately hold a first-time fork
contributor's run for its built-in approval.
The main ruleset requires the two privacy checks.

Host checks always run in Linux/macOS partitions. Base-owned classification can
mark both platform build/unit paths not applicable for App-unaffected PRs;
unknown or CI-trusted changes run them. Main pushes run both platforms.
Builds produce [secret-free archives](docs/CI_BUILD_ARCHIVE.md), then
[source-free unit consumers](docs/CI_UNIT_TESTS.md) enumerate and execute them.
PR CI's `build-for-testing` compiles every scheme testable, including the UI
target's smoke and App Store screenshot methods, but runs no UI tests.
The [sole smoke nightly](docs/CI_NIGHTLY.md) compiles and runs smoke when main changes:
seven core flows on the daily schedule, all 23 on manual dispatch before release.
Smoke results are reported and never block merges.

`scripts/check_all.sh` defaults to two Python shards with static checks once;
`--python-shards 1` runs one process.
`--output-dir DIR` retains host records in `DIR/host-records`, and optional
unit bundles in `DIR`. Choose a fresh outside-repo directory and remove it
after reading. [Host records](docs/CI_SUMMARY.md) describe counts and failure
accounting. The [toolchain workflow](docs/CI_TOOLCHAIN.md) additionally runs for
its configured PR paths.

Release uploads remain separate from CI. [Archive-only Xcode Cloud](docs/XCODE_CLOUD_TESTFLIGHT.md)
documents internal TestFlight and the maintainer's explicit upload gate.
CI success or a smoke result does not authorize a tag, release or deployment.

## Tests

Follow [docs/TESTING.md](docs/TESTING.md). In short:

- Write a test only when [section 0](docs/TESTING.md#0-when-to-write-a-test) calls for one, and then write it first. If that is not possible, say why in the PR. Name the failure each new test guards against.
- Unit tests use Swift Testing with an English behavior sentence as the name, for example `` @Test func `empty selection cannot start filtered playback`() ``. UI tests use `test` plus `UpperCamelCase` behavior.
- Every test needs an assertion that can fail, every wait needs a deadline, and skips are only for an environment that cannot run the test (for example no server configured).
- Do not put ticket numbers, process codes or non-English text in test names.
- Screenshot, capture and performance tooling goes in the `Evidence` test plans (`immichSlides-Evidence-iOS.xctestplan`, `immichSlides-Evidence-tvOS.xctestplan`), not in the default plans.
- Tests do not depend on your simulator language for the app's own text: the test plans run the app in Simplified Chinese, so UI tests show a Chinese interface. System dialogs follow the simulator, and the tests handle English and Chinese ones, so use a simulator set to English or Chinese. In unit tests, compare user-visible text with `String(localized: "English key")`. In UI tests, find elements by `accessibilityIdentifier`: the UI test process cannot read the app's string catalog.
- `python3 scripts/check_test_conventions.py` checks the machine-checkable rules.

## UI changes

Reading code or an Xcode Preview is not verification. Build and run the app, open the changed screen and look at it.

- Include **before and after screenshots** of the changed screen, taken on the same device or simulator with the same settings.
- Check what the change can affect:
  - iPhone and iPad, portrait and landscape where supported
  - light and dark mode
  - a large Dynamic Type size
  - tvOS: default focus, moving focus with the remote, Select and Back, and collisions when a focused element scales up
- Truncated or overlapping text, content under the notch, home indicator or tvOS screen edges, hidden or unreachable primary actions, unreadable dark mode text, and lost or stuck tvOS focus all count as failures.
- Make local fixes, not redesigns: do not move navigation or primary actions or change the color language without agreeing in an issue first.
- Keep `accessibilityIdentifier` values stable; UI tests depend on them.
- State what you did not check.

## Localization

Policy: **every new or changed user-facing string must ship with all supported localizations in the same PR.** Machine or AI translation is acceptable, and native-speaker review is welcome. The localization validator fails the build otherwise.

Supported locales in `immichSlides/Localizable.xcstrings`: the source language English (`en`), plus `zh-Hans`, `zh-Hant-HK`, `zh-Hant-TW`, `es` and `ja`.

To add or change a string:

1. Use it through the localization APIs (`String(localized:)`, `Text(...)` with a literal, and so on). Never hard-code display text.
2. Open `immichSlides/Localizable.xcstrings` in Xcode (or edit the JSON) and make sure the key exists. The source language is English (`en`), and keys are the English text. If another key already uses the same English text but needs a different translation, give the new key a distinct English phrase and add an explicit `en` value with the text to display.
3. Add a value for each of `zh-Hans`, `zh-Hant-HK`, `zh-Hant-TW`, `es` and `ja` and set its state to `translated`. Machine or AI translation is fine if you cannot write one of these languages. Entries left `new` or `needs_review`, empty values and stale keys fail validation.
4. Keep format specifiers (`%@`, `%lld`, positional `%1$@`) and plural substitutions identical across locales.
5. Run `python3 scripts/validate_localization_catalog.py`. It must print `status=PASS`. `InfoPlist.xcstrings` is checked too if you change app-level strings.
6. `scripts/check_all.sh` also runs `scripts/scan_chinese_strings.py`, which fails when a literal passed to `Text`, `Button`, `Label`, `.navigationTitle`, `.alert`, `.accessibilityLabel` or `.accessibilityHint` is missing from the catalog.

## Dependencies

The app uses SDWebImageSwiftUI and its transitive dependency SDWebImage through Swift Package Manager. Both are MIT licensed. Discuss any additional third-party package (Swift Package Manager, CocoaPods, vendored code) in an issue first.

### Locked package resolution

The committed `immichSlides.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is the source of package versions and revisions for CI builds. The offline unit and smoke runners pass `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile` to Xcode, so a missing or incompatible resolution fails instead of selecting other versions. Direct CI build commands must pass both flags too:

```bash
xcodebuild build -project immichSlides.xcodeproj -scheme immichSlides \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .derivedData/locked-ios \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
```

For tvOS, use `generic/platform=tvOS Simulator` and a separate DerivedData path. Keep the default simulator signing.

The direct SDWebImageSwiftUI project URL has no `.git` suffix. Keep the lock file's canonical locations as generated by Xcode. To verify a clean resolve, use an empty package checkout directory outside the repository and compare the lock file against the committed version:

```bash
xcodebuild -resolvePackageDependencies -project immichSlides.xcodeproj \
    -scheme immichSlides \
    -clonedSourcePackagesDirPath '<empty-outside-repo>/SourcePackages'
git diff --exit-code -- immichSlides.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

The resolution must remain byte-identical, including every pinned revision. Package upgrades are intentional dependency changes; never regenerate the resolution merely to make a CI build pass. Remove task-owned package checkouts and DerivedData after verification.

## Platforms

iOS / iPadOS and tvOS must both build.

- `immichSlides/Shared/`: business logic and cross-platform views. No iOS-only APIs and no tvOS focus logic here.
- `immichSlides/iOS/` and `immichSlides/tvOS/`: platform views and interaction.
- Keep `#if os(...)` blocks narrow. Keep the existing `IOS`, `TV` and `TVOS` file suffixes and do not add new ones.
- The Xcode project uses synchronized folders, so new files join their folder's target automatically. Anything placed under `immichSlides/` ships in the app, so keep scratch files and backups elsewhere. For platform-specific files, confirm target membership and mention it in the PR.

## Privacy and security

- Never commit API keys, PINs, tokens, Apple IDs, certificates or `.p8` files. Never commit `Config/env.xcconfig` or any other local config, build output, `.xcresult` bundles or scratch scripts.
- Log asset IDs, person IDs, server URLs and photo metadata with `privacy: .private` or redacted.
- Screenshots and recordings must not show private photos, faces, server addresses or credentials. Crop or blur them, or use the public fixture data.
- Do not run tests that create, edit or delete data on a real Immich server.

The PR privacy check blocks credential and local-config files, the image/video and log/data extensions listed in `scripts/git_privacy_gate.py`, image/video content signatures even under another extension, evidence path components such as `screenshots`, and blobs larger than 1 MiB. Screenshots belong in the PR description, not in the diff. If a change genuinely needs a binary asset, explain it in the PR and the maintainer will handle it.

The `privacy-preflight-trusted` check runs the scanner and its self-tests from the PR's base commit, never from the candidate tree. A change introducing or updating the gate becomes trusted only for subsequent pull requests after it is merged into `main`; `privacy-preflight-bootstrap` tests the candidate implementation and is not a substitute for the trusted check.

### Reporting a security issue

Follow [SECURITY.md](SECURITY.md) to report vulnerabilities privately. Do not open a public issue for a security problem.

## Commit messages

Short, imperative English with a conventional prefix: `feat:`, `fix:`, `test:`, `docs:`, `chore:` or `refactor:`.

```text
fix: keep the SmartFill animation running while a person filter is active
test: rename planner determinism tests to describe behavior
```

## Pull requests

Fill in the [pull request template](.github/pull_request_template.md). Before requesting review:

- [ ] Linked issue, and the PR covers one problem
- [ ] `scripts/check_all.sh` passes on the final commit
- [ ] Unit tests pass for both iOS and tvOS on the final commit (`--with-unit-tests`), or the PR says why not
- [ ] New or changed logic has tests, following [docs/TESTING.md](docs/TESTING.md)
- [ ] UI change: before/after screenshots on the same device and settings
- [ ] New or changed strings: all locales complete, validator passes
- [ ] No secrets, local config or private screenshots
- [ ] Docs updated if behavior, commands, directory layout or privacy changed

Reviewers look for:

- A focused change that matches the issue, with no unrelated edits.
- Tests that would fail without the change.
- **Honest results.** Report failing tests with their output. List failures that existed before your change separately. Mark anything you did not verify as not run instead of implying it passed.
- What the user sees: a visible failure, fallback, blank screen or bad crop is a failure, whatever the code path is called. Do not add or change a visual fallback or display mode without agreeing on it first.
- Both platforms still building, and platform code in the right directory.

## Contribution license

By contributing, you license your contribution under GPL-3.0-or-later. You also grant sudoHG perpetual, irrevocable permission to distribute your contribution, as part of immichSlides, through Apple's App Store and TestFlight under Apple's terms.
