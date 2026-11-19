# Smoke nightly

[`ci-smoke-shadow`](../.github/workflows/ci-smoke-shadow.yml) is the only nightly
test workflow. Its historical name remains; there is no comparison phase.
Results are reported and never block merges. PR checks are described in
[CONTRIBUTING](../CONTRIBUTING.md#ci).

## Schedule and scope

The workflow runs on `main` at `7 14 * * *` (14:07 UTC), with `7 19 * * *`
(19:07 UTC) as a backup. Scheduled runs select seven core flows:

- `iphone-first-boot`
- `ipad-rotation`
- `tv-first-boot`
- `tv-playback-controls`
- `tv-pause-resume`
- `tv-background-return`
- `tv-server-switch`

A scheduled run skips when an earlier smoke run already tested that same main
SHA with official first results for the selected flows and completed groups.
A prior failure also counts as tested; the skip summary links its run, attempt
and outcome. Missing or unreadable history causes execution. This also prevents
the backup from repeating an already tested head.

Manual dispatch always executes. Its `scope` input defaults to `full`: all 23
flows. Run the full scope before a release; `core` is available for diagnosis.

```bash
gh workflow run ci-smoke-shadow.yml --ref main -f scope=full
```

There is no per-push CI approval step. GitHub's built-in first-time fork
contributor approval is separate from this main-only workflow.

## Execution and results

[`smoke-flows.json`](../scripts/smoke-flows.json) maps 20 XCTest methods to 23
device flows: eight iPhone, five iPad and ten Apple TV. The manifest validator
checks IDs, platforms, configurations, fixtures and selectors, including the
seven core IDs. No historical planning inventory selects tests.

Only nonempty device/configuration groups start jobs. iOS builds one generic
simulator archive per selected Debug/Release configuration and shares it between
iPhone and iPad groups; Apple TV groups build locally. The nightly compiles and
runs smoke in the UI test target. PR CI compiles all scheme testables, including
that target's smoke and App Store screenshot methods, but runs no UI tests.
App Store screenshots are manual Evidence-plan tooling, not smoke.

Each selected flow records its first result without test retries or yellow
outcomes. Failed or missing results, invalid source/export evidence and failed
group finalization make the aggregate fail. A no-change schedule emits a linked
skip record. Informational reporting does not turn failures into passes.

Scanned compact producer/group artifacts last seven days, configuration archives
one day and aggregates 90 days. This is current artifact retention, not an
obligation to preserve retired readers or legacy data.

Build identity, simulator reset, fixtures, timeouts and private results are in
[the smoke runner guide](CI_STRICT_RUNNER.md). A single local flow or a build-only
run does not establish a complete seven- or 23-flow result.
