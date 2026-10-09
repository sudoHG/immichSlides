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
Schemes and test plans at every path are CI-trusted inputs. This
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

The `xcode-cloud` environment is main-only and holds `ASC_ISSUER_ID`, `ASC_KEY_ID`
and `ASC_PRIVATE_KEY`; creating or changing it is maintainer work. PR code must
never receive those credentials. The reader below is inactive without a trusted
router decision. Scheduling and fallback integration land separately.

## Trusted importer and acceptance

`ci-xcode-cloud-import` accepts a same-repository PR's authoritative `ci-ui` run
ID through a main-only manual/API dispatch. It checks the full admitted identity,
latest producer attempt, exact current PR head and the successful main router's
artifact before reading App Store Connect. Its protected job checks out main,
executes only the allowlisted importer, has read-only GitHub permissions, and
finishes within ten minutes. It signs a ten-minute ES256 token once; the private
key crosses a pipe to OpenSSL and is never stored or logged. No PR checkout,
artifact execution or PR-controlled environment input can reach the key.

The admission records the head's cloud plan, its SHA-256, fixture/source hashes
and Git tree. The head tree must equal the admitted GitHub merge tree. A moved
base or different merge tree causes GitHub fallback, since Xcode Cloud starts a
branch head rather than GitHub's synthetic merge commit. The strict plan validator
compares its exact methods and fixture environment with the admitted Apple TV
shard union and approved fixture deselections. The copy must match its source.
Admission also records the head's tvOS scheme and every same-name plan path in
the head tree listing. Admission refuses cloud inputs if any two full head-tree
paths are equal under case folding, preventing a case-insensitive checkout from
substituting a shadow plan, scheme or hook. The reader requires one cloud reference resolving exactly
to `container:XcodeCloud-UI-tvOS.xctestplan`, no other same-name file, and no
TestAction pre/post actions. Redirected or ambiguous plan resolution is refused.
API `isPullRequestBuild` must be explicitly false: only the tree-bound branch
execution is accepted, never an unbound cloud pull-request merge build.

The API reader proves membership in overflow workflow
`72574ec0-c168-4317-b469-d3090357ab21` through its paginated build-run collection;
Developer keys cannot read a build run's nonexistent workflow relationship.
It requires one completed successful `XcodeCloud-UI-tvOS - tvOS` test action and
all paginated method results. Every exact method must occur once with `SUCCESS`
on exactly Apple TV 4K (3rd generation), tvOS 27.0. Missing, extra, duplicate,
failed, skipped, partial or unknown results are refused. Pagination cycles,
cross-host links, oversized payloads and unavailable API data are refusals too.

Acceptance separately requires GitHub's completed successful check from the
Xcode Cloud app (ID 117084, slug `xcode-cloud`), with the exact head, overflow check
name and App Store Connect run/action link. Another app, check, workflow, head
or an ambiguous check cannot count. The newest API check ID among checks with
the same app, name and head is authoritative before run/action binding is checked.
A newer failed, cancelled, incomplete or differently bound check prevents an
older success from counting. The app check alone proves no population.

The importer uploads `ci-xcc-import-<producer-run>-<attempt>` only after complete
validation. Publisher and PR diagnostics verify the uploader's workflow ID/path,
same repository, main-history revision, successful latest attempt and artifact
binding to the admitted identity and exact router artifact. They repeat the method
comparison using the independently selected admitted policy and re-read current
app checks. Uploader event, repositories, successful completion and main-history
revision are authenticated before any artifact bytes are opened; an untrusted
uploader, including a fork branch named main, is ignored. Receipts must name that
uploader's current run and attempt. Import success grants no head approval: existing CI-change/fork
approval rules remain authoritative. A failed or missing importer cannot excuse
a GitHub Apple TV skip. Stale attempts and conflicting or expired artifacts fail
closed. Multiple trusted import receipts are accepted only when their complete
content is identical apart from uploader run/attempt, including the same route
artifact and API evidence; the smallest immutable artifact ID is reported.
Routing decisions remain unique. Only literal unexecuted Apple TV skips are excused; GitHub archive,
iPhone and iPad evidence still require their full original populations.
If GitHub collapses a TV-only matrix skip into its expression-named job, the
reader expands only that TV matrix after independent cloud validation, retaining
the original unexecuted job. An iOS matrix or overlapping executed shard cannot
be covered by this normalization.

API evidence stays separate from GitHub producer summaries. Counts report every
admitted and observed Apple TV method; compiled inventory is
`NOT_EXPOSED_BY_API`, since the API does not expose a separate bundle enumeration.
Wall minutes use run timestamps; compute minutes sum action durations. Cloud PR
reports retain Apple TV removals against the admitted base and every applied
fixture deselection; an explicitly owned deselection is reported separately from
source removal. Diagnostics receive the proof already verified for the verdict,
avoiding a second network read that could contradict that evaluation.
Verdicts do not create main-push UI reuse receipts. Daily reporter history remains
main-push only, and refuses cloud PR proof for a push. To disable acceptance,
disable routing; normal GitHub Apple TV jobs need no cloud credentials or receipts.
