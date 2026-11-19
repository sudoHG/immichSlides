# Host checks and producer records

PR CI is `ci-gate` (host checks, build archives, offline units) plus
`privacy-preflight-bootstrap` and `privacy-preflight-trusted`.
There is no CI approval or separate status publisher: jobs report their own
results. [Smoke](CI_NIGHTLY.md) is the sole nightly and never blocks merges.

## Host checks

`check_all.sh` delegates to `run_host_checks.py`. Its eight `HOST_CHECKS`
entries are Swift formatting, test conventions, release guards, localization
catalog, localization usage, Python prerequisites, workflow policy and Python tests.

```bash
scripts/check_all.sh
python3 -B scripts/run_host_checks.py --output-dir /tmp/immichslides-host-run
python3 -B scripts/ci_summary.py /tmp/immichslides-host-run/summary.json
python3 -B scripts/ci_summary.py --identity /tmp/immichslides-host-run/run-identity.json
```

Use a fresh output directory outside the repo; remove it after reading results.
`check_all.sh --output-dir DIR` keeps records in `DIR/host-records`; without
it temporary host records are removed on exit. Children keep the invoking
interpreter; `check_all.sh` honors `PYTHON`. See [Setup](../CONTRIBUTING.md#setup).

Two deterministic Python shards are the default. Whole modules are balanced
with `ci-host-durations.json`; static checks execute once in shard 1.
Unrecorded tests still run. `--python-shards 1` uses one process.
Each child has its own `--timeout-seconds` budget (default 900, maximum 1200).
Timeout stops the group and records unstarted checks as `not-run`; it fails.
The parent requires both receipts and complete nonoverlapping coverage.
Invalid static inventory keeps failure red and falls back to complete single-process
execution rather than dropping tests.

Hosted Linux/macOS jobs split this inventory with base-owned partition rules
and `HOST_CHECKS` consistency. Both run even when App builds do not apply.
Local execution runs the complete set.

## Versioned records

`ci_summary.py` validates schema-1 summary and run-identity records.
They bind source/event, run/attempt/tier/job, manifest/policy hashes, toolchain,
declared/compiled/observed populations, diagnostics and status.
PR identity includes repository, PR, base, head, merge commit and tree.
Main pushes bind commit/tree; local records retain actual commit/tree and dirty
state, alongside the local snapshot receipt. These are producer claims, not attestations.

Each observation retains one first-result attempt, duration, exit, reason and
optional bounded diagnostics. Swift parameter rows keep their own identities.
JSON keeps successes; Markdown emphasizes failures/skips/missing coverage.
Unknown stays null or unavailable. [Population accounting](CI_POPULATION.md)
compares declarations, enumeration and observations; process exit zero is insufficient.

Checks continue after individual failures where possible. Unexpected skips,
missing/duplicate identities, invalid population, failed commands and infrastructure
errors fail. Matching active skips are permitted; proposed-only exceptions remain
`unverified`. `coverage-failed`, `policy-proposed` and `population-invalid`
describe accounting/policy rather than infrastructure health.

## Build and unit records

[Build archives](CI_BUILD_ARCHIVE.md) record source/toolchain identity, signing,
inventory, hashes and disk observations. [Unit consumers](CI_UNIT_TESTS.md) add
staged declarations, compiled enumeration, official results, consumption and
measurements, then scan before upload or display.

The unit upload allowlist is summary/identity, archive consumption, enumeration,
official tests/summary, measurements and sensitive scan. Raw bundles, logs,
screenshots, activities and quarantine paths remain private.
Gate records last 30 days for PRs and seven days otherwise; archives last one day.

## Safe diagnostics

`ci_bounded_diagnostics.py` and `ci_failure_diagnostics.py` admit closed, bounded
preparation, process-phase, cleanup and first-failure structures. Public text is
sanitized before display. Private inputs, unsupported fields and arbitrary
exception text cannot become public diagnostics.
Diagnostics do not change assertions or establish an unobserved root cause.
Preserve failures and report unexecuted verification as `NOT_RUN`.
