# Contributing to immichSlides

Thanks for helping out. immichSlides is a SwiftUI photo slideshow client for [Immich](https://immich.app) servers on iOS, iPadOS and tvOS. This guide covers how to propose, build, test and submit a change.

## Before you start

- **Open an issue first** for anything beyond a small fix (new feature, behavior change, UI change, refactor, new dependency). Agree on the approach before writing code.
- **One problem per pull request.** No drive-by refactors, reformatting or cleanup of unrelated code.
- If a change turns out bigger than planned, stop and update the issue instead of growing the PR.

## Setup

- A Mac with the Xcode version the project was last upgraded with (Xcode 26.3, see `LastUpgradeCheck` in `immichSlides.xcodeproj`), the iOS and tvOS Simulator runtimes, Python 3 with Pillow and PyYAML, Swift (included with Xcode), and the zstd CLI (`brew install zstd`) for Python contract tests.
- CI tool versions and the isolated Python setup are documented in [CI toolchain and workflow policy](docs/CI_TOOLCHAIN.md). The host entry point runs the standalone workflow-policy check in the same environment as the other Python checks.
- [Trusted CI publication and approval](docs/CI_PUBLISHER.md) explains the informational App statuses, exact-head fork/CI approval, main-only trusted workflows, and a read-only dry-run. GitHub may separately require approval before a first-time fork contributor's producer run starts.
- All `check_all.sh` Python steps use `"${PYTHON:-python3}"`; child host checks keep that interpreter. Set `PYTHON=/usr/bin/python3` to use the recommended Xcode-bundled Python, or activate a venv made from it and leave `PYTHON` unset. Python 3.14 can hit the [fixture startup stall (#122)](https://github.com/sudoHG/immichSlides/issues/122).

  ```bash
  /usr/bin/python3 scripts/setup_ci_python.py --python /usr/bin/python3 --venv /tmp/immichslides-python
  source /tmp/immichslides-python/bin/activate
  unset PYTHON
  scripts/check_all.sh
  # With the prerequisites already installed for Xcode Python, no PATH change is needed:
  PYTHON=/usr/bin/python3 scripts/check_all.sh
  ```
- Deployment target is iOS / tvOS 18.6.
- `Config/env.xcconfig` is an optional, git-ignored local test configuration. `Config/Debug.xcconfig` includes it only when present, so a fresh clone builds in Xcode without setup.
- The test runners refuse to start `xcodebuild` below 80 GiB free on `/System/Volumes/Data`; pass `--min-free-gib N` with a non-negative integer to change this local safety threshold.
- To seed an optional local configuration from the example without overwriting anything:

  ```bash
  python3 scripts/run_offline_unit_tests.py --prepare-example-config
  ```

- **Unit tests need no Immich server and no credentials.** Run them with the schemes `immichSlides-iOS` / `immichSlides-tvOS` (not `immichSlides`, which is for build, run and archive only):

  ```bash
  xcrun simctl list devices available   # pick a simulator UDID
  python3 scripts/run_offline_unit_tests.py --platform ios --destination 'platform=iOS Simulator,id=<UDID>' --derived-data-path .derivedData/local-ios --result-bundle-path '<outside-repo>/ios.xcresult'
  python3 scripts/run_offline_unit_tests.py --platform tvos --destination 'platform=tvOS Simulator,id=<UDID>' --derived-data-path .derivedData/local-tvos --result-bundle-path '<outside-repo>/tvos.xcresult'
  ```

  A run that times out (exit 124) or selects zero tests is not a pass.
- **UI tests** in the default test plans that need a server run the real app against the Immich server set in `Config/env.xcconfig`, and skip when none is set. They only read from that server; tests that start from the filter summary need its first album to contain photos and at least one person. See [docs/TESTING.md](docs/TESTING.md).
  For secret-free default-plan runs, use [Fixture-server UI mode](docs/CI_FIXTURE_UI.md).
  It starts a public loopback server and measures coverage for every selected test.
- **Strict end-to-end tests** run the real app against a local public fixture server that `scripts/run_strict_e2e.py` starts for you, so they do not touch anyone's Immich server. See [Running controlled integration and end-to-end tests](docs/TESTING.md#running-controlled-integration-and-end-to-end-tests) and `python3 scripts/run_strict_e2e.py --help`.
  Explicit warm-build reuse and the informational hosted tracer are documented in
  [Strict runner warm-build tracer](docs/CI_STRICT_RUNNER.md).
  Versioned matrix reproduction and on-demand hosted runs are documented in
  [Skeleton nightly](docs/CI_NIGHTLY.md); a skeleton run is never release-eligible.
- Optional, once per clone: `scripts/install_git_privacy_hooks.sh` installs the hooks that block secrets and private data from being committed or pushed.

## Using AI coding agents

Welcome, with one rule: the agent must follow [AGENTS.md](AGENTS.md) (`CLAUDE.md` imports it). You are responsible for everything you submit. Read the diff yourself, run the checks yourself, and report results honestly.

## Code style

- Formatting and lint are enforced by `swift-format` using [`.swift-format`](.swift-format).
- Run this before every push; it is the same set of checks a reviewer will run:

  ```bash
  scripts/check_all.sh                     # formatting, conventions, release guards, localization, prerequisites, workflow policy, known-flaky registry, Python tests
  scripts/check_all.sh --output-dir '<fresh-outside-repo>' # keep the host summary and identity in host-records/
  scripts/check_all.sh --with-unit-tests \
      --ios-destination 'platform=iOS Simulator,id=<UDID>' \
      --tvos-destination 'platform=tvOS Simulator,id=<UDID>' \
      --output-dir '<outside-repo>'        # additionally runs the offline unit tests for iOS and tvOS
  ```

- Naming and SwiftUI conventions (View / ViewModel / Store / Service roles, `@MainActor` for UI-driving types, no network or credential access in views) are in [AGENTS.md](AGENTS.md). Code comments are written in English and explain why, not what.
- Architecture overview: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

The [informational iPhone UI tier](docs/CI_UI.md) reuses exact-identity gate archives
and runs class-manifest shards against public loopback fixtures. Its guide includes
one-command shard reproduction by Git revision, listed-only retry, artifact
retention and the remaining iPad/Apple TV boundary.

The informational `ci-gate` host job and [secret-free build archive jobs](docs/CI_BUILD_ARCHIVE.md)
run on pull requests and pushes to `main`. Separate hosted runners execute the
[complete iOS/tvOS unit targets from relocated archives](docs/CI_UNIT_TESTS.md).
The [iPhone UI tier](docs/CI_UI.md) consumes the iOS archive across runs.
Release archive preparation and the maintainer-gated App Store Connect steps are in
[Xcode Cloud to internal TestFlight](docs/XCODE_CLOUD_TESTFLIGHT.md). Its first upload
is manual, the Default workflow stays disabled, and tag starts need later approval.
To keep its JSON and short Markdown records locally, run
`"${PYTHON:-python3}" -B scripts/run_host_checks.py --output-dir /tmp/immichslides-host-run`.
`check_all.sh` uses the same checks. `--output-dir` keeps records in `DIR/host-records`
and optional unit bundles in `DIR`; choose a fresh directory. Without it, temporary
host records are removed on exit. The final terminal report lists each host result
and all nonpassing Python identities.
See [the summary contract](docs/CI_SUMMARY.md) for validation, identity, result
accounting and the current workflow boundary. Existing privacy checks remain required.

## Tests

Follow [docs/TESTING.md](docs/TESTING.md). In short:

- Write a test only when [section 0](docs/TESTING.md#0-when-to-write-a-test) calls for one, and then write it first. If that is not possible, say why in the PR. Name the failure each new test guards against.
- Unit tests use Swift Testing with an English behavior sentence as the name, for example `` @Test func `empty selection cannot start filtered playback`() ``. UI tests use `test` plus `UpperCamelCase` behavior.
- Every test needs an assertion that can fail, every wait needs a deadline, and skips are only for an environment that cannot run the test (for example no server configured).
- Do not put ticket numbers, process codes or non-English text in test names.
- Screenshot, capture and performance tooling goes in the `Evidence` test plans (`immichSlides-Evidence-iOS.xctestplan`, `immichSlides-Evidence-tvOS.xctestplan`), not in the default plans.
- Tests do not depend on your simulator language for the app's own text: the test plans run the app in Simplified Chinese, so UI tests show a Chinese interface. System dialogs follow the simulator, and the tests handle English and Chinese ones, so use a simulator set to English or Chinese. In unit tests, compare user-visible text with `String(localized: "English key")`. In UI tests, find elements by `accessibilityIdentifier`: the UI test process cannot read the app's string catalog.
- Strict end-to-end tests are not in the default or Evidence test plans. Run them with `scripts/run_strict_e2e.py`, which starts the local fixture server and fails if any test skips; run any other way, they fail and name the missing input.
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

The committed `immichSlides.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is the source of package versions and revisions for CI builds. The offline unit, strict E2E and access-lifecycle runners pass `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile` to Xcode, so a missing or incompatible resolution fails instead of selecting other versions. Direct CI build commands must pass both flags too:

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
