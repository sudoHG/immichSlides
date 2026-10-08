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
On a branch refusal dispatch, all other jobs skip, consuming no macOS runner slots.
On main the refusal probe intentionally skips every job and generates no traffic.
Normal PR runs record `pr-skipped` admission and skip protected live units; real
external-fork PR proof remains NOT_RUN until the separate fork acceptance ticket.

```sh
# Before merge: only branch environment refusal; no live traffic or macOS jobs.
gh workflow run ci-nightly.yml --ref <branch> \
  -f live_only=true -f probe_environment_refusal=true
# After merge: run once and inspect both live platforms.
gh workflow run ci-nightly.yml --ref main -f live_only=true
```

`live_only` skips strict execution/aggregation and cannot qualify a nightly.
`strict_only` and a selected `shard` skip all live jobs. Use these inputs for strict
diagnostics so the public test Immich server receives no diagnostic traffic.
Schedules retain the strict matrix and add live execution. Nightly scope policy
and aggregate/release eligibility remain unchanged; mandatory live scope and live
performance belong to the separate scope ticket and maintainer decision.

Real live execution is GitHub-only. Never use a private configuration symlink,
local/LAN runner or real server secrets to reproduce it. Pre-merge live acceptance
is **NOT_RUN** because the environment permits `main` only, including solo-only
Vision rules on hosted virtual-Mac simulators. Local unit verification is offline.

## Archive and test selection

The [archive producer](CI_BUILD_ARCHIVE.md) admits the exact nightly path for
schedule/dispatch identities and PR canary builds and records that producer path. All structural checks,
locked packages, configuration-absence checks and default simulator signing remain.
Build jobs have no live environment or secrets; archives expire in one day.
Consumers select the latest unexpired `build-<platform>-<run-id>-<n>` with producer
attempt `n` no greater than the current consumer attempt. Re-running failed live
jobs can reuse a successful archive from an earlier attempt; a missing or expired
archive requires re-running all jobs. Downloads supply token, repository and run ID.
Consumers verify the immutable artifact ID and API provenance
and manifest, stage static declarations from the committed tested tree, remove
source, extract elsewhere and verify signing. Before use, the archive and unpacked
files are searched for the real values and transformed forms.

Only these `*Live*` classes receive test-time configuration:

- `PlaybackPoolResolverLiveIntegrationTests`: membership, deduplication and solo-only rules.
- `SlideShowViewModelLiveIntegrationTests`: loading, filtered playback and sequence rules.
- `FaceBoxLiveProbeTests`: a bounded random geometry sample, with Evidence enabled.

Xcode enumeration returns the whole unit target catalog even with class selectors.
The runner selects these suites from that credential-free catalog, rejects unowned
Live suites and requires every declared selected method to compile. Actual execution
still must equal the selected population exactly, including on the fake canary;
missing, extra or duplicate functions/parameters cannot establish coverage.

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

Only scanned `live-summary.json`, `live-summary.md` and `live-provenance.json`
upload, retained seven days.
Allowed fields are source/run/archive provenance, static declared/compiled function
identities, manifest/policy hashes, measured toolchain/signing, function outcomes,
ordinal parameter outcomes and durations, integer official counts,
process exit and fixed diagnostics. `live-summary.json` uses the shared version-1
summary contract and validator: run/job/shard, population, per-test attempts and
infrastructure entries. Archive ID/producer attempt, process exit and official
counts live in the separate provenance record. Runtime arguments, failure messages and skip
reasons are withheld. Missing/extra/duplicate execution, parameter failure, any skip,
nonzero exit, official result disagreement or failed cleanup fails. Exceptions are
never serialized. Missing records or a refused scan cannot authorize publication.
Fixed phase markers contain no subprocess output or exception text. A canary
preparation/finalization failure publishes its scanned shared failure summary but
no passing canary verdict, so the audit remains red and the phase stays visible.

Boot/enumeration use the [unit consumer bounds](CI_UNIT_TESTS.md); execution is
bounded at 900 seconds, each official export at 60 seconds, and disposal at 15/60
seconds. Jobs have 40-minute caps. Local disk reserve is 80 GiB; hosted reserve is 30 GiB.

## Canary and server acceptance

The credential-free canary runs on PRs and ordinary nightly runs. PRs build only
the secret-free iOS archive for this proof; nightly canaries reuse the real iOS
producer. It registers a fake URL/key derived from the run and attempt with GitHub
masking, injects them as `CI_LIVE_URL/KEY` against a `.invalid` host, and invokes the
same execution core, selectors, private capture, official exports, cleanup, summary
validator and publication scan as real live units. Actual live suites must fail after
enumeration, with nonzero Xcode exit and official results; setup-only failure cannot
establish the canary. Complete selected execution and a genuine failed test are
required; unrelated tests or process-only failure cannot establish it. The normal scanned failed summary and step summary publish,
alongside a run/attempt-bound canary verdict. No real server is contacted.
Scanner regressions cover raw, URL/JSON forms, host/key prefixes, UTF-16, chunk
boundaries and Base64 offsets 0/1/2 in standard and URL-safe alphabets.
After the run finishes, download complete logs and **all** artifacts outside the
repository, then independently audit the extracted directory:

```sh
gh api repos/sudoHG/immichSlides/actions/runs/<run-id>/logs > <outside-repo>/logs.zip
gh run download <run-id> --dir <outside-repo>/artifacts
unzip -q <outside-repo>/logs.zip -d <outside-repo>/logs
python3 -B scripts/ci_live_tests.py audit-canary --run-id <run-id> \
    --attempt <attempt> --path <outside-repo>
```

Audit refuses missing/empty extracted logs, missing canary summaries, wrong run or
attempt, symlinks and raw/transformed leaks. Fake values can be derived independently
without a public secret manifest. Inspect the hosted job summary too. The PR's real
`pr-skipped` log and skipped protected live jobs are the pre-merge PR evidence;
actual external fork proof belongs to #89 and remains NOT_RUN here.

The public test Immich server is read-only and must hold only public or consenting photos: several
hundred in mixed orientations; a recognized named person; a first album containing
photos; an album cover differing in shape from its card; and photos with one face,
several faces and no faces for the solo-only person. The selected person must support
the existing membership/mixed-rule assertions. An EXIF diagnostic album is optional.
Missing content fails the relevant assertion; never weaken a test or accept a skip.
Use minimal one-shot runs and never point local fixture/LAN tests at this server.

Security/result regressions extend existing Python test files: admission, leak
detection, complete official function/parameter outcomes and workflow credential
placement. No new test file or App behavior tests are added.
