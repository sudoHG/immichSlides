# AGENTS.md

immichSlides is a SwiftUI photo slideshow app for [Immich](https://immich.app) servers, targeting iOS, iPadOS and tvOS. This file tells coding agents, and the people directing them, how to work in this repository. Read it fully before your first change.

Where things live and what the domain words mean: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). How to write tests: [docs/TESTING.md](docs/TESTING.md). How to open a pull request: [CONTRIBUTING.md](CONTRIBUTING.md).

## Hard boundaries

Never do these without explicit approval from the maintainer, whatever the task says:

- Push, merge, publish, release, or rewrite Git history.
- Add a third-party dependency (Swift package, CocoaPod, Python package). Open an issue first.
- Add or change a visual fallback or presentation mode (see [Honest results](#honest-results)).
- Loosen a test, metric, validator, threshold or check to make something pass.
- Create, edit or delete data on a real Immich server.
- Commit secrets, local config (`Config/env.xcconfig`), build output, `.xcresult` bundles, screenshots or scratch scripts.
- Overwrite, reformat, restore or delete changes you did not make. Report them instead.

Agents never approve CI runs, fork commits, CI-changing commits or releases, even when asked; they may only request approval.

## Language

- Everything committed to the repository is written in English: identifiers, comments, commit messages, docs. Some existing comments and docs are still in Chinese. Translate them only in a task that asks for it, not as drive-by edits.
- User-facing strings are the exception: they live in the string catalog and are localized (see [Localization](#localization)).
- Talk to the person you are working for in their language. Lead with the conclusion, and ask only for decisions that are genuinely theirs.

## How to work

- Do what the task asks and nothing more. No drive-by refactors, redesigns or cleanup of unrelated code. If the problem turns out bigger than the task, stop and explain before expanding.
- Read the relevant code, its callers and its tests before changing anything. Do not guess at behavior.
- For any non-trivial change, state up front what you will change, what you will not touch, and how you will verify it.
- Fix correctness first, then consistency, then visual polish.
- Before changing logic or state flow, decide with [docs/TESTING.md](docs/TESTING.md) section 0 whether a test is needed. When it is, write it first; if it cannot come first, say why and what you will verify instead. Do not add tests the standard rules out.
- Behavior-preserving refactors must keep features, UI, interaction and statistics unchanged. Verify against the same baseline before and after, and keep pre-existing failures separate from new regressions. Performance claims need before/after measurements.
- Every change must build and pass tests on both iOS and tvOS, even if it only targets one of them.

## Honest results

These rules exist because past work "passed" while users still saw failures. They are not negotiable.

- What the user sees decides. A visible failure, fallback, blank screen, a single photo padding a multi-photo layout, or a bad crop is a failure, whatever the code path or enum is called.
- Never improve a metric by redefining success. Do not rename failures, add "safe" categories, change denominators or thresholds, exclude samples, or bypass validators. Metrics may only become stricter, and only with approval.
- Do not add or change a visual fallback or presentation mode without explicit approval. This includes blurred or black fills, letterboxing, placeholder collages and single-photo wrappers.
- A task about photo selection, layout, cropping, candidate search or loading performance must not change rendering, display modes, fallback UI or acceptance criteria unless approved first.
- Report outcomes exactly. Failed tests are reported with their output. Anything not verified is marked `NOT_RUN`, `BLOCKED_ENV` or `NEEDS_HUMAN_REVIEW`. Never write `PASS` without evidence.
- If a reviewer or the maintainer says a result looks like a fallback or a cheat, stop and re-check goals, metrics and visual evidence before continuing.

## Repository layout

| Path | Contents |
|---|---|
| `immichSlides/Shared/` | Business logic and cross-platform views |
| `immichSlides/iOS/` | iOS / iPadOS views and interaction |
| `immichSlides/tvOS/` | tvOS views, focus and remote handling |
| `immichSlidesTests/` | Unit tests (Swift Testing) |
| `immichSlidesUITests/` | UI tests (XCTest) |
| `TestSupport/` | Shared test helpers. Never used by production code |
| `scripts/` | Checks, test runners, localization validator, privacy gate, with Python tests |
| `docs/` | Architecture, testing conventions, decisions |

- No iOS-only APIs in `Shared/`. No tvOS focus logic in shared views. Keep `#if os(...)` blocks narrow.
- Reuse the existing types and domain terms from [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Do not introduce a second name for something that already has one.
- The Xcode project uses synchronized folders, so new files join their folder's target automatically. Anything placed under `immichSlides/` ships in the app, so keep scratch files and backups elsewhere. For platform-specific files, confirm the iOS and tvOS target membership and state it in your report.

## Commands

`Config/env.xcconfig` is an optional, git-ignored local test configuration. `Config/Debug.xcconfig` includes it only when present, so a fresh clone builds in Xcode without setup. If you need a local test configuration, `python3 scripts/run_offline_unit_tests.py --prepare-example-config` creates it from the example without overwriting anything. Unit tests need no real credentials or server.

Script entry points ignore local configuration by default and test a recorded working-tree snapshot. Use `--allow-private-config` explicitly for private local testing; see [CONTRIBUTING.md](CONTRIBUTING.md#setup) for mode and evidence boundaries.

Every `check_all.sh` Python step uses `"${PYTHON:-python3}"`. Prerequisites and interpreter setup are described in [CONTRIBUTING.md](CONTRIBUTING.md#setup).

```bash
# All host checks: formatting, test conventions, release guards, localization, prerequisites, workflow policy, known-flaky registry, Python tests
scripts/check_all.sh

# Offline unit tests (pick a local simulator UDID with `xcrun simctl list devices available`)
# The runner stops xcodebuild after --timeout-minutes (default 45, 0 disables) and exits 124: a timed-out run is not a pass.
python3 scripts/run_offline_unit_tests.py --platform ios --destination 'platform=iOS Simulator,id=<UDID>' --derived-data-path .derivedData/local-ios --result-bundle-path '<outside-repo>/ios.xcresult'
python3 scripts/run_offline_unit_tests.py --platform tvos --destination 'platform=tvOS Simulator,id=<UDID>' --derived-data-path .derivedData/local-tvos --result-bundle-path '<outside-repo>/tvos.xcresult'

# Format Swift code (configuration in .swift-format)
xcrun swift-format format --in-place --recursive immichSlides immichSlidesTests immichSlidesUITests TestSupport

# Git privacy hooks (once per clone)
scripts/install_git_privacy_hooks.sh
```

`check_all.sh` delegates its host checks to `scripts/run_host_checks.py`, including the Python suite and per-test observations. The shared commands and versioned records are described in [docs/CI_SUMMARY.md](docs/CI_SUMMARY.md).

Schemes: `immichSlides` is for build, run and archive only. Run tests through `immichSlides-iOS` / `immichSlides-tvOS`. End-to-end runners and their suites are described in [docs/TESTING.md](docs/TESTING.md#running-controlled-integration-and-end-to-end-tests).

## Swift and SwiftUI conventions

Formatting is not a matter of taste here: `.swift-format` decides it and `check_all.sh` enforces it. These rules cover what a formatter cannot.

- Types use `UpperCamelCase`. Pick the suffix by responsibility:
  - `View`: SwiftUI screens
  - `ViewModel`: UI state and orchestration
  - `Store`: persistence and local state
  - `Service`: network and system APIs

  Use `Resolver`, `Manager` or `Coordinator` only when the role really matches.
- Platform-specific files keep the existing suffixes `IOS`, `TV` and `TVOS`. Do not introduce new ones.
- Booleans start with `is`, `has`, `can`, `should` or `did`. Async task handles end in `Task`. Test injection points end in `ForTesting`. Avoid vague names like `data`, `result`, `manager` or `helper` outside tiny scopes.
- ViewModels and Stores that drive UI are `@MainActor`. Make concurrency boundaries explicit.
- Views do not perform network requests, credential access or playback-pool computation. That belongs in ViewModels, Stores, Services or Resolvers. Keep `body` small by extracting subviews and private helpers.
- Numbers with meaning become named constants, with the unit in the name or comment.
- Debug-only code and test hooks stay behind `#if DEBUG` and go through `PlatformCompat`. `scripts/check_release_guards.py` enforces this.

## Comments

- Write comments in English. Explain why and what constraints apply, not what the line does.
- Keep them short, usually one line. Put longer reasoning about state flow, races, cancellation, persistence, focus or privacy in `docs/` and link to it.
- Delete stale comments and commented-out code. Keep license headers and tool directives as they are.

## Localization

- Every user-visible string goes through `immichSlides/Localizable.xcstrings`. No hard-coded user-facing text.
- The catalog's source language is English (`en`): keys are the English text. When two strings share the same English text but need different translations, the second key gets a distinct English phrase plus an explicit `en` value holding the displayed text.
- A new or changed string ships with translations for every shipped locale: `zh-Hans`, `zh-Hant-HK`, `zh-Hant-TW`, `es` and `ja`. Machine or AI translation is acceptable; missing translations are not. `scripts/validate_localization_catalog.py` fails otherwise.
- Keep format specifiers (`%@`, `%lld`) identical across translations. Check that the longest translation still fits the UI (see [UI work](#ui-work)).
- A literal passed to `Text`, `Button`, `Label`, `.navigationTitle`, `.alert`, `.accessibilityLabel` or `.accessibilityHint` must be a catalog key. `scripts/scan_chinese_strings.py`, run by `check_all.sh`, fails otherwise. A literal that must not be translated, such as a hidden UI-test probe label, gets a `// localization-audit: <reason>` comment on the line above it.

## Tests

Follow [docs/TESTING.md](docs/TESTING.md). In short: write a test only when it guards a failure that can realistically happen again (section 0), unit tests are named with raw-identifier English sentences, every test has an assertion that can fail, every wait has a deadline, tests skip only when the environment cannot run them, and screenshot or capture tooling lives in the Evidence test plans. Tests must not depend on the simulator language: the test plans run the app in Simplified Chinese, system dialogs are handled in English and Chinese; unit tests compare user-visible text with `String(localized:)`, and UI tests find elements by `accessibilityIdentifier`. `scripts/check_test_conventions.py` enforces what a machine can judge.

## UI work

- Verify UI changes in the running app. Build and run on a simulator or device, open the changed screen, take a screenshot and look at it. Reading code or an Xcode Preview is not verification.
- Check what the change can affect:
  - layout: iPhone and iPad, portrait and landscape where supported
  - colors: light and dark mode
  - text: a large Dynamic Type size, and the longest localization
  - tvOS: default focus, moving focus with the remote, Select and Back, and collisions when a focused element scales up
- Any of these is a failure: truncated text, overlapping elements, content under the notch, home indicator or tvOS screen edges, a primary action that is hidden or cannot be tapped or focused, unreadable text in dark mode, lost or stuck tvOS focus.
- Include before and after screenshots of the changed screen, taken on the same device with the same settings. Say what you did not check. Whether it looks right is the maintainer's call.
- UI changes are local fixes, not redesigns. Do not move navigation, primary actions or information hierarchy, and do not change the color language, unless the task says so.
- Keep `accessibilityIdentifier` values stable. UI tests depend on them.

Useful simulator commands. Restore any setting you change when you are done.

```bash
xcrun simctl io booted screenshot <outside-repo>/after.png
xcrun simctl ui booted appearance dark    # or light
xcrun simctl ui booted content_size accessibility-extra-large    # reset with: large
```

## Privacy and logging

- API keys, PINs, tokens, Apple IDs, certificates and `.p8` files never appear in logs, screenshots, docs, commits or test code. API keys are stored only through the existing Keychain path.
- Log asset IDs, person IDs, server URLs, error details and photo metadata with `privacy: .private` or redacted.
- `Config/env.xcconfig` is optional local test configuration. It is never committed and never becomes a production dependency.
- Photos, faces and server URLs from a real server may appear in local evidence. Crop or minimize them before sharing anything publicly.
- Treat any real Immich server as read-only. Before any action that creates, edits or deletes remote albums, photos, people or settings, describe its impact and get approval.
- User-facing error messages explain what the user can do next, not only the underlying error.

## Commits

- Commit only when asked. One logical change per commit.
- Messages are short, imperative English with a type prefix: `feat:`, `fix:`, `refactor:`, `test:`, `docs:` or `chore:`. Example: `fix: keep tvOS focus on the play button after closing settings`.
- No ticket numbers, dates or personal names in messages, branch names, file names or identifiers.

## Definition of done

Work is done only when all of these hold on the final commit. Earlier runs on other commits do not count.

- [ ] `scripts/check_all.sh` passes.
- [ ] Offline unit tests pass on iOS and tvOS, or failures that already existed before your change are listed separately with evidence.
- [ ] Where [docs/TESTING.md](docs/TESTING.md) section 0 calls for a test, it fails without the change; no test the standard rules out was added.
- [ ] New user-visible strings are localized for every shipped locale.
- [ ] UI changes have before/after screenshots.
- [ ] Docs that describe changed behavior, commands, directory boundaries, target membership or privacy are updated.
- [ ] The report below is complete, including what was not verified.

## Documentation and sources of truth

- Source code, tests and the Xcode project configuration describe actual behavior. When a doc disagrees with them, point out the conflict before fixing either one.
- Each topic has one authoritative document. Link to it instead of copying its content:
  - `AGENTS.md`: rules for working in this repository
  - [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): structure, key types and glossary
  - [docs/TESTING.md](docs/TESTING.md): test conventions
  - [CONTRIBUTING.md](CONTRIBUTING.md): pull request process
  - `docs/decisions/ADR-YYYY-MM-DD-title.md`: lasting architecture decisions. Supersede an ADR with a new one; do not delete it.
- Do not put task status, roadmaps or history in this file.

## Keeping these rules useful

When the same mistake shows up twice, do not just fix it again. Propose a rule here or, better, an automated check in `scripts/`, so the next contributor cannot repeat it. Rules that a script can enforce belong in a script.

## Reporting back

When you finish, report in this order:

1. Files changed
2. What changed
3. What was deliberately left unchanged
4. Verification commands and exit codes
5. What was not verified, and why
6. Remaining risks and suggested next steps, and whether docs were updated
