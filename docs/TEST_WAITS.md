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
clamped to the remaining budget. The clock is checked before polling and after
each predicate evaluation; a predicate returning success after expiry is rejected.

Product deadlines measure the app's promise to the user. Observation windows
measure an invariant throughout a fixed span. Neither scales. `observe` fails
on the first violated sample and succeeds only after the whole product window.
Do not classify a product deadline as infrastructure to cure a failure. Existing
elapsed-time bounds and assertions remain in force.

Legacy helpers can continue to accept resolved seconds. Classify at their callers
or timing declarations and pass the result through unchanged; wrapping an already
resolved infrastructure value in another infrastructure budget would scale it twice.
Scene-presentation sampling spans, screenshot stability spans and first-visible-tick
offsets remain fixed product timing even when they help collect diagnostic evidence.

Access-lifecycle timing starts at the original user action. Pause holds, background
holds, first-wake evidence, PIN-gate responses and the resume interval's tolerance
remain product timing. A screenshot capture can have its own fixed evidence budget
without extending the first-transition deadline; preserve both bounds separately.
Settings-route probes and responses after Back or Playback taps also stay fixed;
those windows decide the next interaction rather than await fixture availability.
Shared constants used for both machinery readiness and user-visible responses
stay product. Give genuine first-launch, fixture and connection readiness an
independent infrastructure budget at the call site. The first assertion after a
tap or key press, route probes, absence observations and sampling cadence stay
product; discovering a control before the timed action can be infrastructure.

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
checks the selected revision's toolchain and device pins. Historical revisions
keep their original fixed budgets at factor `1`; a non-default factor is refused
before building when the selected revision does not advertise that option.

## Raw literal ratchet

`scripts/check_test_conventions.py` checks all existing test-target Swift file
globs. `scripts/test_timeout_allowlist.json` freezes the pre-migration literals
by file, qualified function (or `<scope>` for declarations outside a function),
normalized expression and occurrence count. No line numbers are stored.

The scanner recognizes timeout/deadline/duration/window/observation/poll/hold
arguments and defaults, named timing constants ending in hold/delay/interval,
typed `TimeInterval`/`Duration`/`DispatchTimeInterval` initializers, numeric duration constructors,
`addingTimeInterval`, `sleep`, `usleep`, `Task.sleep(nanoseconds:)` and
`Thread.sleep(forTimeInterval:)`. Wrapped and arithmetic
arguments are included, including continuation lines (a trailing or leading operator, or a leading `.member`). Comments and strings are ignored. This is a lexical
convention check; it does not infer whether a named variable is a product promise.
Window arguments ending in `Count`, `Limit`, `Size` or `Used` represent counts
and are excluded; timing window names should include their time unit.
Choose the classification explicitly during migration.
Classified `TestWait.seconds`, `until` and `observe` budget/cadence arguments are
masked before numeric detection. Arithmetic literals outside those regions and
raw waits inside predicates still count. The original inventory is from main
`7516d4e`; migrated sites are removed individually while unmigrated and documented
non-timeout entries remain. The allowlist is a
[CI-trusted input](CI_POPULATION.md#classification-and-gate-evaluation); every edit
requires exact-head maintainer approval, including removals during migration.

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
