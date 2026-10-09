# Xcode Cloud Apple TV fixture UI

The **UI - Apple TV (overflow)** workflow runs the same pull-request Apple TV
fixture methods as the GitHub UI shards. It is test-only, accepts an API or manual
start on a branch, and uses the `immichSlides-tvOS` scheme with the
`XcodeCloud-UI-tvOS` plan on Apple TV 4K (3rd generation), tvOS 27.0. Workflow
configuration belongs to the maintainer. This preparation does not enable
automatic routing or change the GitHub UI producer or trusted verdict.

## Population and fixture environment

The source population is the statically declared tvOS UI target, filtered by
`immichSlides-tvOS.xctestplan` and partitioned by `scripts/ci-ui-shards.json`,
with the approved `ui`/`fixture` deselections from `scripts/ci-test-policy.json`.
The cloud plan lists every executed method explicitly; it contains only the UI
target. The existing default plan stays the scheme default. See
[the GitHub UI tier](CI_UI.md#manifest-and-union) for shard and approval rules.

The cloud plan passes these public runtime inputs:

| Input | Value |
| --- | --- |
| `IMMICH_TEST_SERVER_URL` | `http://127.0.0.1:8765/api` |
| `IMMICH_TEST_API_KEY` | `immichslides-public-e2e-key` |
| `IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID` | `album-c-exif` |
| `IMMICHSLIDES_TEST_WAIT_FACTOR` | `2` |
| `UI_TEST_EXPECT_PLATFORM` | `tvOS` |

The app runs in Simplified Chinese, matching the default plan. Infrastructure
waits scale; product deadlines and observation windows do not. No test assertion,
rendering behavior, skip policy, real-server configuration or signing mode changes.
There are no global retries or test repetitions. Failures remain failures.

## Cloud hooks

`ci_post_clone.sh` keeps the existing secret-free pinned archive preflight for
archive actions only. Build-for-testing does not start a fixture process.
For the tvOS scheme's `test` or `test-without-building` action,
`ci_pre_xcodebuild.sh` starts fixture set C on loopback port 8765 using isolated
system Python, and requires readiness within 60 seconds. A failed start fails
the action and stops its process. `ci_post_xcodebuild.sh` verifies and stops that
action's fixture process, then removes its temporary state. Other actions leave
the fixture untouched. Both hooks require the Xcode Cloud environment.

Xcode Cloud makes `ci_scripts/` available to the test action even when the source
checkout is absent. `ci_scripts/fixture_server.py` is an exact committed copy of
`scripts/strict_e2e_server.py`; it needs only the Python standard library.
When updating the source server, regenerate the copy byte for byte in the same
change. Neither directory ships in the iOS or tvOS app.

## Drift checks and proof

`python3 -B scripts/check_xcode_cloud_ui.py`, included in `check_all.sh`, fails
on a missing, extra or duplicate cloud method, a changed fixture copy, unexpected
targets, configuration overrides, skips, repetitions, fixture inputs or scheme
registration. It derives the expected method list with the existing static parser
and GitHub shard rules; counts alone do not establish coverage. When the default
population changes, regenerate the cloud plan's exact selections in the same PR.
Shared schemes and test plans at every path are CI-trusted inputs. This
classification must land on main before routing is activated, because admission
uses the PR base's policy; a candidate cannot grant its own approval.

For a cloud proof, start the existing overflow workflow on the reviewed PR branch
through the App Store Connect API. Verify its resolved commit SHA, workflow ID,
action results and all paginated test results. Compare every executed method
identity and outcome against the source shards; retain missing, extra, duplicate,
failed and skipped methods in the report. Record run wall time from started to
finished, and compute minutes as the sum of action durations. A completed green
cloud check alone cannot prove the population. Raw result bundles and logs can
contain test inputs; keep them private and do not attach them to a public PR.

## Routing and trust rollout

Automatic routing remains disabled until the trusted reader and router land.
The agreed routing policy permits only same-repository PR heads under documented
GitHub macOS congestion and month-to-date cloud use below **45 compute hours**.
Usage is summed from build actions since the start of the UTC calendar month;
the budget resets each month. The router must bind its decision to the exact head
and fall back to GitHub whenever a start or run fails. iPhone and iPad stay on
GitHub. A disabled or absent routing decision runs all GitHub Apple TV shards.

The trusted importer must read the cloud API's executed identities and compare
them with the admitted population before the publisher can accept Apple TV.
Acceptance also requires the Xcode Cloud app's successful completed check on the
exact head from this overflow workflow. The `xcode-cloud` environment is main-only
and holds `ASC_ISSUER_ID`, `ASC_KEY_ID` and `ASC_PRIVATE_KEY`; creating or changing
it is maintainer work. PR code must never receive those credentials. Details of
the implemented decision and importer will be added with their separate changes.
