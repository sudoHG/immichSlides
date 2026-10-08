# Live unit tests

`ci-nightly` builds a secret-free archive per platform, then runs selected live
unit suites on pinned iPhone and Apple TV simulators. The protected environment is
**`immich-test-server`**, the real name of the epic's `test-server` environment.
Its selected-branch policy allows exactly `main`, with no reviewers or repository
fallback secrets. The maintainer configured `IMMICH_TEST_SERVER_URL` and
`IMMICH_TEST_SERVER_API_KEY`; this ticket changes no settings, secrets or approvals.

## Admission and configuration

Credential-free admission checks the repository, schedule/manual event, actor and
triggering actor (`sudoHG`), exact workflow path/ref, checkout SHA and ancestry of
`origin/main`. Mismatches fail. PRs alone skip, with distinct `fork-skipped` and
`pr-skipped` reasons, without reaching a protected job. Producers and consumers
repeat admission before the credential step. There is no SHA override: a manual
run tests `GITHUB_SHA` on `main`, after verifying ancestry of `origin/main`.

The environment's branch policy is independent. The negative probe binds no
secrets, performs no checkout and has no token permissions; GitHub must refuse
the branch job before it executes. Reaching `/usr/bin/false` would also fail.

```sh
# Before merge: branch refusal, fork-style probe and canary; no live traffic.
gh workflow run ci-nightly.yml --ref <branch> \
  -f live_only=true -f probe_environment_refusal=true
# After merge: run once and inspect both live platforms.
gh workflow run ci-nightly.yml --ref main -f live_only=true
```

`live_only` skips strict execution/aggregation and cannot qualify a nightly.
Schedules retain the strict matrix and add live execution. Nightly scope policy
and aggregate/release eligibility remain unchanged; mandatory live scope and live
performance belong to the separate scope ticket and maintainer decision.

Real live execution is GitHub-only. Never use a private configuration symlink,
local/LAN runner or real server secrets to reproduce it. Pre-merge live acceptance
is **NOT_RUN** because the environment permits `main` only, including solo-only
Vision rules on hosted virtual-Mac simulators. Local unit verification is offline.

## Archive and test selection

The [archive producer](CI_BUILD_ARCHIVE.md) admits the exact nightly path for
schedule/dispatch identities and records that producer path. All structural checks,
locked packages, configuration-absence checks and default simulator signing remain.
Build jobs have no live environment or secrets; archives expire in one day.
Consumers select the same run/attempt's immutable artifact ID, verify API provenance
and manifest, stage static declarations from the committed tested tree, remove
source, extract elsewhere and verify signing. Before use, the archive and unpacked
files are searched for the real values and transformed forms.

Only these `*Live*` classes receive test-time configuration:

- `PlaybackPoolResolverLiveIntegrationTests`: membership, deduplication and solo-only rules.
- `SlideShowViewModelLiveIntegrationTests`: loading, filtered playback and sequence rules.
- `FaceBoxLiveProbeTests`: a bounded random geometry sample, with Evidence enabled.

`PerformanceLiveIntegrationTests` is owned by the live-performance ticket. Other
Evidence suites are offline performance and never receive secrets. The 37 approved
hermetic skips remain unchanged; Evidence identities do not all belong to live units.
No App code, existing assertion, threshold or skip approval changes. Runs use only
the listed selectors, once, with no automatic retries or additional library scans.

Injection maps the URL to `TEST_RUNNER_IMMICH_TEST_SERVER_URL` and the key to
`TEST_RUNNER_IMMICH_TEST_API_KEY`, the existing test helper's inputs. Only test
execution gets them; enumeration, archive creation, simulator tools and official
export use a clean environment. No config or `.xctestrun` file contains credentials.

## Results and privacy

All live subprocess output is captured privately. Raw bundles and exports stay
private until parsing. The runner deletes its captures, bundle, DerivedData and
products afterward, including failure; job teardown completes cancellation cleanup.
Live logs, products, screenshots, simulator data, diagnostics and raw results never upload.

Only scanned `live-summary.json` and `live-summary.md` upload, retained seven days.
Allowed fields are source/run/archive provenance, static declared/compiled function
identities, manifest/policy hashes, measured toolchain/signing, function outcomes,
ordinal parameter outcomes and durations, integer official counts,
process exit and fixed diagnostics. Runtime arguments, failure messages and skip
reasons are withheld. Missing/extra/duplicate execution, parameter failure, any skip,
nonzero exit, official result disagreement or failed cleanup fails. Exceptions are
never serialized. Missing records or a refused scan cannot authorize publication.

Boot/enumeration use the [unit consumer bounds](CI_UNIT_TESTS.md); execution is
bounded at 900 seconds, each official export at 60 seconds, and disposal at 15/60
seconds. Jobs have 40-minute caps. Local disk reserve is 80 GiB; hosted reserve is 30 GiB.

## Canary and server acceptance

The credential-free canary registers a per-run fake URL/key with GitHub masking.
A subprocess deliberately exits 65 after emitting raw, URL-encoded, JSON-escaped,
base64, host-only and key-prefix forms into the same private capture used by live
execution. The scan must refuse that capture; only a constant verdict uploads.
Scanner regressions also cover UTF-16 and chunk boundaries. After the run finishes,
download and extract logs/artifacts outside the repository, then independently audit:

```sh
gh api repos/sudoHG/immichSlides/actions/runs/<run-id>/logs > <outside-repo>/logs.zip
gh run download <run-id> --name live-canary-<run-id>-<attempt> --dir <outside-repo>/records
unzip -q <outside-repo>/logs.zip -d <outside-repo>/logs
python3 -B scripts/ci_live_tests.py audit-canary --run-id <run-id> --path <outside-repo>
```

Fake values derive from the run ID for independent audit, without a public secret
manifest. Inspect the hosted job summary too. The hosted fork-style probe supplies
a fork PR payload to the actual admission function without credentials; an actual
external fork PR is a separate real-run observation when available.

The read-only mock server must hold only public or consenting photos: several
hundred in mixed orientations; a recognized named person; a first album containing
photos; an album cover differing in shape from its card; and photos with one face,
several faces and no faces for the solo-only person. The selected person must support
the existing membership/mixed-rule assertions. An EXIF diagnostic album is optional.
Missing content fails the relevant assertion; never weaken a test or accept a skip.
Use minimal one-shot runs and never point local fixture/LAN tests at this server.

Security/result regressions extend existing Python test files: admission, leak
detection, complete official function/parameter outcomes and workflow credential
placement. No new test file or App behavior tests are added.
