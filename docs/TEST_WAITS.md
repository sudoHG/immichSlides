# Test waits and product timing

`TestSupport/TestWait.swift` belongs to the unit and UI test targets on iOS and
tvOS. The app target does not include `TestSupport`. Production code must never
read `IMMICHSLIDES_TEST_WAIT_FACTOR` or use `TestWait`; the conventions check
rejects either access, without an allowlist exception.

Choose a budget at the call site:

```swift
element.waitForExistence(timeout: TestWait.seconds(.infrastructure(5)))
TestWait.until(.infrastructure(10)) { fixtureIsReady }
TestWait.until(.product(3)) { pauseHasTakenEffect }
TestWait.observe(seconds: 3) { renderedFrameIsFrozen }
```

Infrastructure waits cover availability of test machinery: launch, element
discovery, fixture readiness and network setup. `seconds` resolves the budget
once; pass that result to a legacy helper without scaling it again. `until`
polls to a monotonic deadline. Poll cadence stays fixed and its last delay is
clamped to the remaining budget.

Product deadlines measure the app's promise to the user. Observation windows
measure an invariant throughout a fixed span. Neither scales. `observe` fails
on the first violated sample and succeeds only after the whole product window.
Do not classify a product deadline as infrastructure to cure a failure. Existing
elapsed-time bounds and assertions remain in force.

## Runner factor and recording

The factor defaults to `1` locally. Runners accept `--wait-factor`, require a
finite number in `[1, 4]`, and reject invalid inputs rather than clamping them.
The current `ci-ui` workflow explicitly passes `2`. Xcode invocation, job and
result-export budgets remain independent and do not multiply by this factor.

The fixture runner removes ambient and prefixed factor inputs and injects the
validated value only into the UI test target's `EnvironmentVariables` in a
private `.xctestrun` copy. It does not inject it into the app or unit target.
The original archived launch inputs remain unchanged.
`wait-configuration.json` records the factor, bounds, source and fixed product
factor; `summary.json` records it in `toolchain.versions.test_wait_factor`.
These scanned records are published with the shard's other records. `TestWait`
also prints its effective factor on first infrastructure use in the test log.

Run a bounded fixture selection with a secret-free build and dedicated simulator:

```bash
python3 -B scripts/run_fixture_ui_tests.py --device iphone \
  --destination 'platform=iOS Simulator,id=<dedicated-UDID>' \
  --xctestrun '<secret-free-Products>/immichSlides.xctestrun' \
  --only-testing immichSlidesUITests/immichSlidesUITests/testFirstBootValidationAndDisabledSaveButton \
  --wait-factor 2 --output-dir '<fresh-outside-repo>'
```

`ci_ui_tests.py run` and `reproduce` also accept `--wait-factor` (default `1`).
Pass `--wait-factor 2` to reproduce hosted wait budgets. Reproduction still
checks the selected revision's toolchain and device pins.

## Raw literal ratchet

`scripts/check_test_conventions.py` checks all existing test-target Swift file
globs. `scripts/test_timeout_allowlist.json` freezes the pre-migration literals
by file, qualified function (or `<scope>` for declarations outside a function),
normalized expression and occurrence count. No line numbers are stored.

The scanner recognizes timeout/deadline/duration/window/observation/poll/hold
arguments and defaults, named timing constants, numeric duration constructors,
`addingTimeInterval`, `sleep`, `usleep` and `Thread.sleep`. Wrapped and arithmetic
arguments are included. Comments and strings are ignored. This is a lexical
convention check; it does not infer whether a named variable is a product promise.
Choose the classification explicitly during migration.

An additional literal, including a duplicate in an already listed function,
fails. A changed value, moved function/file, removed literal or decreased count
leaves a stale entry and fails. Remove only the corresponding entries/counts
after migration. There is no regeneration flag: regenerating this baseline to
admit new waits defeats the ratchet. Run:

```bash
python3 -B scripts/check_test_conventions.py
python3 -B -m unittest discover -s scripts -p test_check_test_conventions.py
```

## Initial migration boundary

Only these sites introduce the mechanism; area-wide migration is separate:

| Site | Classification | Base duration |
| --- | --- | --- |
| `immichSlidesUITests.testFirstBootValidationAndDisabledSaveButton`: URL field discovery | Infrastructure | Existing 5 seconds |
| `ServerConfigFormTVOSUITests.testTVOSFirstBootCoreElementsAndDisabledSave`: Save discovery | Infrastructure | Existing 5 seconds |
| `PlaybackHistoryIOSUITests.assertSmartFillPauseOnlyFrameFreeze`: initial paused-frame probe deadline | Product deadline | Existing 3 seconds |
| Same helper: four pause sample intervals | Product observation | Existing 0.75 seconds each |

The product sites are listed for maintainer review. Their sampling, elapsed
windows and frame/phase/opacity/progress/pixel assertions are unchanged. These
changes make no claim to fix the hosted failures tracked separately in the CI
epic.
