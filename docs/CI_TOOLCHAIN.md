# CI toolchain and workflow policy

[scripts/ci-pins.json](../scripts/ci-pins.json) is the versioned source for the runner,
Xcode version/build/path, simulator versions/builds/runtime identifiers, device types,
Python, Python packages and zstd. Consumers must compare exact versions and fail when a
pin is unavailable; they must not select the latest installed version as a fallback.

The Xcode and simulator pins match the [hosted Vision probe](https://github.com/sudoHG/immichSlides/actions/runs/37592421181).
Python 3.14.7 is installed in that runner image's [software inventory](https://github.com/actions/runner-images/blob/xcode-27-arm64/20260928.0222/images/macos/xcode-27-arm64-Readme.md).
The PR workflow selects that exact pin with a commit-pinned `actions/setup-python`, since
the same runner label can serve newer images with a different default Python.
Pillow 12.3.0 supplies Python 3.14 wheels; the earlier local Pillow 11.3.0 environment is
not the pinned CI environment. PyYAML 6.0.3 parses workflow structure safely. Pip is also
pinned. These dependencies are CI tools and do not ship in the app.

## Python setup

Provision the exact Python version and zstd CLI first. The setup command never installs
Python, Xcode, simulator runtimes or zstd and never changes system packages. Run from the
repository root, with a new task-owned environment path outside the repository:

```bash
python3 scripts/setup_ci_python.py --python /path/to/pinned/python3 --venv /tmp/immichslides-ci-python
source /tmp/immichslides-ci-python/bin/activate
python3 -B scripts/setup_ci_python.py --venv /tmp/immichslides-ci-python --check
python3 -B scripts/check_workflow_policy.py
python3 -B -m unittest discover -s scripts -p test_check_workflow_policy.py
scripts/check_all.sh
```

Setup verifies Python and zstd before creating the environment, refuses an existing path
(including symlinks), and installs only the exact pinned wheels from PyPI. Ambient pip
configuration, alternate indexes, user packages, source builds and shared pip caches are
excluded. The install has a five-minute subprocess deadline; other calls have two-minute
deadlines. `--check` verifies an existing environment without installing anything. Exit 0
means all requested checks passed; exit 1 means a pin, prerequisite, install or verification
failed. Invalid command-line arguments exit 2. A failed install may leave its new venv
directory for inspection; only its owner should remove it before retrying.

`--verify-toolchain` also inventories the pinned Xcode and available simulator runtimes
and device types, using the pinned `DEVELOPER_DIR`. It reads Xcode's `Contents/version.plist`
and calls only `simctl list`: it never invokes `xcodebuild`, builds an app, boots a simulator
or installs platform resources. The repository's 80 GiB pre-build rule still applies to
builds; inventory does not require build space. Ordinary Python setup does not require Xcode.

The bounded [CI toolchain workflow](../.github/workflows/ci-toolchain.yml) proves setup,
inventory, policy, its unit tests and the existing host checks on `xcode-27` for relevant pull requests and manual
dispatches. Its runner selector must match the pins file; GitHub chooses a runner before
it can read repository files. This workflow is not the PR gate or the scheduled toolchain
probe: those are separate epic tickets.

## Workflow policy

`python3 scripts/check_workflow_policy.py` checks every `.yml` and `.yaml` file directly
under `.github/workflows`, without importing candidate scripts or executing workflow code.
`--root /path/to/checkout` checks another checkout. Exit 0 means all workflows passed;
exit 1 prints file, YAML location and violated rule; invalid arguments exit 2. Missing,
unreadable or symlinked workflows, invalid YAML, duplicate keys, YAML aliases, unsupported
tags and missing jobs/triggers fail closed. GitHub's unquoted `on` key is preserved.

The rules are:

- Remote `uses` references (steps and reusable jobs) require a full 40-character commit
  SHA. Container actions require a full `sha256` digest. Repository-local actions may use
  a literal `./` path without parent traversal.
- Permissions must be explicit mappings, including `{}` for no grants. A workflow-level
  mapping may supply each job's permissions; jobs may override it. Blanket permission
  strings are rejected. Each job needs a literal `timeout-minutes` from 1 through 360.
- Only `.github/workflows/privacy-preflight.yml` may use `pull_request_target`.
- Only `ci-publish.yml` and `ci-report.yml` may use `workflow_run`. The former lists
  `ci-gate` and/or `ci-ui`; the latter lists `ci-nightly` and/or `ci-gate` (post-merge
  reporting). Wildcards and other producer names are rejected. Event types may only be
  `requested`, `in_progress` and `completed`; an omitted type means `completed`.
- Trusted workflow paths are the privacy workflow and `ci-publish.yml`, `ci-report.yml`,
  `ci-probe.yml`, `ci-approval.yml`, `ci-approve.yml` and `ci-release.yml`. Trust comes from
  the exact path, never the display name. Their checkout action may use `main`,
  `refs/heads/main` or `${{ github.event.repository.default_branch }}`, in the same
  repository. Privacy may also use `${{ github.event.pull_request.base.sha }}` or its
  event's default checkout. Indirect refs, PR head/merge SHAs and workflow-run head SHAs
  are rejected. Inline shell checkout/switch/reset/worktree materialization is rejected;
  fetching PR Git objects for static inspection is allowed.
- Trusted artifact downloads must go into `ci-artifacts` or its children, optionally
  under `${{ runner.temp }}`. They cannot overwrite checked-out scripts. Inline shell and
  action scripts must not execute, source, evaluate or import artifact code. Reading an
  artifact as an argument to a checked-in parser is allowed. Dynamic interpreter operands
  and inline interpreter code after an artifact download fail closed. Inline `gh run
  download` and artifact API downloads are rejected; use the pinned download action with
  an isolated destination and parse data through reviewed repository scripts.
- `ci-publisher` may be referenced only by `ci-publish.yml`, `ci-approval.yml` and
  `ci-approve.yml`; `ci-approval` only by `ci-approval.yml`; `release` only by
  `ci-release.yml`. Environment names must be literal so expressions cannot hide a
  protected environment.

This is a static workflow guard, not a proof of arbitrary shell, action or repository
script behavior. Reviewers must inspect trusted parser scripts and pinned actions for
data-only handling, verify producer path/ID and provenance at runtime, and keep event/ref
checks before credentials are read. GitHub App creation, secrets, environments, settings,
rulesets and approvals remain maintainer-gated; this command performs none of them.

The existing privacy workflows remain unchanged. This standalone check is deliberately
not wired into `scripts/check_all.sh` or the host-check entry point while ticket 03a is in
flight. Whichever PR lands second must add the standalone policy command to the host-check
sequence, using the pinned environment, and verify that integration.
