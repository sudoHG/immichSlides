# Test waits and product timing

`TestSupport/TestWait.swift` belongs to unit/UI test targets on both platforms.
It is absent from the App target. Production code must not use TestWait or read
`IMMICHSLIDES_TEST_WAIT_FACTOR`; the conventions checker enforces this.

## Budgets

```swift
element.waitForExistence(timeout: TestWait.seconds(.infrastructure(5)))
TestWait.until(.product(3)) { pauseHasTakenEffect }
TestWait.observe(seconds: 3) { renderedFrameIsFrozen }
```

Infrastructure covers fixture/machinery availability. Resolve a budget once;
do not scale resolved seconds again. The environment factor defaults to 1.
The remaining smoke runner exposes no wait-factor CLI.

Product deadlines measure an App response; observation windows require an
invariant across a complete span. Neither scales. `until` checks a monotonic
deadline before and after each predicate, rejecting late success.
`observe` fails at the first violated sample and completes the whole window.
Keep polling cadence fixed and clamp the last delay to remaining time.
Never relabel product timing to cure a failure.

## Navigation hang guards

`TestWait.hangGuard()` has one unscaled 60-second monotonic deadline shared by
preparation, action and readback. Each transaction admits one action.
No new query/action starts after expiry. A satisfied query admitted before
expiry may return late. A returned action gets one final observation, including
after expiry; a failed/unsatisfied read cannot pass.
Use a one-shot `probe` for optional branches, never a polling wait.
Do not create guards in polling loops or refresh their deadlines.

### Approved smoke-flow guard exception

The smoke-only guard is 120 seconds in exactly `SmokeFlowIOSUITests.iosSmokeFlow`
and `SmokeFlowTVOSUITests.tvSmokeRunFlow`. The timeout allowlist records one
literal at each site; the shared default and first-boot helpers are unchanged.
The outer method/startup cap is documented in [Smoke runner](CI_STRICT_RUNNER.md#budgets-and-first-results).

### Approved post-tap focus readback exception

`IOSFirstBootNavigation.focusTextField` taps once, then starts the existing
unscaled five-second focus-readback window. It queries the identifier-matched
focused/enabled field without requiring a software keyboard. A satisfied query
admitted before expiry may return late; no query starts at/after expiry.
This readback issues no action and gains no extra post-action observation.
Failure prevents typing; no retap or longer window is permitted.

## Timeout literal ratchet

`scripts/test_timeout_allowlist.json` records existing literals by file,
qualified function, normalized expression and count. Extra/changed literals
fail; removed literals leave stale entries that must be deleted.
Do not regenerate the baseline or add an exception to conceal a failure.
The scanner recognizes timing arguments/constants, duration construction,
sleep APIs and arithmetic; it is lexical, so reviewers still classify meaning.

```bash
python3 -B scripts/check_test_conventions.py
python3 -B -m unittest discover -s scripts -p test_check_test_conventions.py
```
