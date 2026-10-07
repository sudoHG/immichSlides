# Host checks and producer summary contract

Run the same macOS host checks as `ci-gate` from the repository root:

```bash
/usr/bin/python3 -B scripts/run_host_checks.py --output-dir /tmp/immichslides-host-run
/usr/bin/python3 scripts/ci_summary.py /tmp/immichslides-host-run/summary.json
/usr/bin/python3 scripts/ci_summary.py --identity /tmp/immichslides-host-run/run-identity.json
```

Use the Xcode-bundled `/usr/bin/python3` (3.9.6 on the current toolchain), with
Pillow, Swift and zstd available, as described in
[CONTRIBUTING](../CONTRIBUTING.md). The output directory must be outside the repository
and contain no previous result files. Without `--output-dir`, a new temporary directory
is printed. Remove local outputs after reading the result.

The entry point owns the format, test-convention, release-guard, localization-catalog,
localization-usage, required-tool and Python checks. `check_all.sh` delegates to it and
keeps its existing optional iOS/tvOS unit-test interface. Its temporary host records
are removed on exit; `--output-dir` holds the optional unit bundles and DerivedData.
Checks continue after failures. Exit 0 preserves the legacy command verdict, including
unittest's environment skips; it does not prove complete coverage. The summary is
`unverified` whenever any skip or unexecuted class member is present, with every reason
retained. Expected-skip policy (#88) replaces this interim rule. Exit 1 means a failed
command, missing result, empty Python suite or infrastructure problem; invalid arguments
exit 2. `--timeout-seconds` sets the total
host budget (default 900, maximum 1200), not a product timing threshold. A timeout
stops the child process group and records remaining checks as `not-run`.

Host checks do not compile the app, read private configuration or receive ambient
Immich/test-runner configuration. They run the intended working files directly.
Local dirty runs record the HEAD commit and tree with `dirty: true`; that tree is
explicitly not proof of the changed working files. Snapshot builds belong to the
separate build entry point.

## Version 1

[`scripts/ci_summary.py`](../scripts/ci_summary.py) is the authoritative, executable
schema and validator. All fields below are required; unknown fields and versions,
duplicate JSON keys and identities, booleans used as integers, non-finite durations,
malformed hashes, and incomplete strict identities are rejected. This validates
producer data, not its provenance or a trusted verdict.

| Field | Type and meaning |
| --- | --- |
| `schema_version` | Integer `1` |
| `identity` | Independently versioned run identity, described below |
| `source` | `repository`, `workflow_path`, `event`, `fork_originated`, `ci_changing` |
| `run` | `id` (string or local null), positive integer `attempt`, strings `tier` and `job`, string or null `shard` |
| `hashes` | `manifests` and `policies`, each a map of logical names to lowercase SHA-256 hashes |
| `toolchain` | `versions` (nonempty name-to-version map; unavailable versions are null), `signing_mode` |
| `population` | `declared`, `compiled`, `observed`, `deselected`, `removed_by_pr` arrays |
| `infrastructure` | Array of `{code, message}` outcomes, never silently omitted |
| `status` | Producer execution status: `passed`, `failed`, `unverified` |

Source repository/event must match the identity. CI requires a workflow path below
`.github/workflows/`, a run ID and a boolean fork-origin flag. Classification is not
implemented by the host producer: `ci_changing: null` means **unclassified**, never
"not CI-changing". A future trusted consumer must derive classification itself;
it must never admit an unclassified run as non-CI-changing. Local workflow path and
run ID are null. No approval is claimed by a producer: publisher verdicts separately
record source and whether they rest on approval.

Host checks have no manifests or policy lists yet, so both hash maps are empty.
Later producers hash the exact bytes of each manifest/policy they consume. Versions
record actual tools, not a claim that pins were verified. Host signing is
`not-applicable`; test-build producers use `sign-to-run-locally`.

### Identity record

`run-identity.json` is identical to the summary's `identity` object. Every variant
has `schema_version: 1`, `event`, `repository` (`owner/name`), and lowercase Git
`tree_sha`. Version 1 Git object IDs are 40 lowercase hex characters.

| Event | Additional required fields |
| --- | --- |
| `pull_request` | Positive integer `pull_request`, `merge_sha`, `base_sha`, `head_sha` |
| `push` | `ref` equal to `refs/heads/main`, `pushed_sha` |
| `local` | `commit_sha`, boolean `dirty` |

For a PR, the producer requires checkout HEAD to equal `GITHUB_SHA` and reads exactly
two parents from that commit: first parent is base, second parent is head. It never
substitutes the trigger payload's base/head claims. The tree comes from that merge
commit. A push requires HEAD to equal `GITHUB_SHA` and the main ref. A later trusted
publisher compares these claims with its own admission record/API observations.

### Population and observations

Each identity is `{kind, key, dimensions}`. `kind` is `host`, `python`, `swift`, `ui`
or `strict`; `key` is a nonempty function/check identifier. `dimensions` is a map of
nonempty strings, limited to `device`, `configuration`, `suite`, `scenario`, `fixture`,
`platform`, and `parameter`. Strict identities require exactly the first five,
so two scenarios or fixtures cannot collapse into one result. Python IDs use
`unittest`'s complete module/class/method identity, including inherited mixin tests.
Identity equality uses the entire object, independent of JSON key order.

`declared` and `compiled` contain identities. Host declaration/compilation records
the seven check definitions; Python `compiled` records dynamic unittest discovery.
The host producer does **not** claim static Python enumeration. A trusted static
declared/compiled/executed comparison belongs to the expected-population ticket.
`removed_by_pr` contains identities for reporting only; host checks leave it empty.

An observed entry contains `identity`, `outcome`, `duration_seconds` and a nonempty
`attempts` array. An attempt contains consecutive positive `number`, `outcome`,
nonnegative finite `duration_seconds`, integer or null `exit_code`, string or null
`reason` and `message`. Total duration accounts for every attempt.

Outcomes are `passed`, `failed`, `skipped`, `crashed`, `timed-out`, `not-run`,
`needs-human-review`, or aggregate `flaky-passed`. A skip requires a reason.
`flaky-passed` requires exactly two attempts, failed then passed; the host runner
never retries. A failed retry retains all attempts and a nonpassing final attempt;
other entries have one matching attempt. Parameterized producers
can use the optional `parameter` dimension for per-parameter evidence while retaining
the function key used by static enumeration. Subtest failures in Python fail the
parent identity. Expected failures and unexpected successes do not count as passes.

Each deselection is `{identity, reason, owning_tier}` with nonempty reason and owner.
The validator checks structure, not whether a skip/deselection is approved or whether
populations are complete. Producer status is not a replacement for the later trusted
evaluator. That evaluator must fail closed on missing populations, unexpected skips,
failed/cancelled jobs, absent artifacts and other incomplete evidence.

### Reader-first evolution

Summary and identity versions are independent. Readers dispatch only to explicitly
installed validators in `SUMMARY_READERS`/`IDENTITY_READERS`; version 1 is currently
the only supported version. A successor parser and validator must land in the
trusted reader first, alongside the old parser and supported workflow paths. Only
then can producers emit the successor. A version number alone never enables parsing.

## Current workflow boundary

`ci-gate` runs this host job on PR merge commits and pushes to main. It has read-only
contents permission, bounded job/script budgets, PR-specific cancellation, and no
secrets or status-writing identity. It uploads only `summary.json`, `summary.md` and
`run-identity.json`, with run/attempt-specific names, retained 30 days for PRs and
7 days for pushes. Successful Python identities are kept in JSON; the short Markdown
shows every host check and all nonpassing Python identities.

This job is informational and does not configure required statuses. Builds, unit
jobs, pins/environment policy, expected populations, skip policy, trusted publication
and approval enforcement are separate tickets. The initial workflow bootstraps the
existing Xcode-bundled Python/Pillow/zstd prerequisites; the pins ticket replaces
that setup. Invoke `/usr/bin/python3` explicitly if `python3` on PATH selects
another interpreter.
