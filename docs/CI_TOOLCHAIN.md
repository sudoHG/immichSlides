# CI toolchain and workflow policy

[scripts/ci-pins.json](../scripts/ci-pins.json) is the versioned source for the runner,
Xcode version/build/path, simulator versions/builds/runtime identifiers, device types,
Python, Python packages and zstd. Consumers must compare exact versions and fail when a
pin is unavailable; they must not select the latest installed version as a fallback.

The Xcode and simulator pins match the [hosted Vision probe](https://github.com/sudoHG/immichSlides/actions/runs/37592421181).
Python 3.9.6 and Pillow 11.3.0 match the contributor verification baseline. The workflow
uses Xcode's `/usr/bin/python3` explicitly and verifies its version; a different version
fails rather than falling back to the Homebrew interpreter. For contributor interpreter
setup, see [CONTRIBUTING](../CONTRIBUTING.md#setup).
PyYAML 6.0.3 parses workflow structure safely. Pip 25.3 is the last
release supporting Python 3.9; these dependencies are CI tools and do not ship in the app.

## Python setup

Provision the exact Python version and zstd CLI first. The setup command never installs
Python, Xcode, simulator runtimes or zstd and never changes system packages. Run from the
repository root, with a new task-owned environment path outside the repository:

```bash
python3 scripts/setup_ci_python.py --python /path/to/pinned/python3 --venv /tmp/immichslides-ci-python
source /tmp/immichslides-ci-python/bin/activate
export DEVELOPER_DIR="$(python3 -c 'import json; print(json.load(open("scripts/ci-pins.json"))["xcode"]["developer_dir"])')"
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
it can read repository files. This workflow is separate from the PR gate and the scheduled
toolchain probe below.

## Scheduled Xcode probe

[ci-probe](../.github/workflows/ci-probe.yml) runs daily at 08:17 UTC on the pinned
`xcode-27` runner, with a 20-minute job deadline. Its runner selector must follow
`scripts/ci-pins.json`. It checks out the repository's default branch with persisted
checkout credentials disabled and reuses `scripts/setup_ci_python.py`. It never builds,
boots a simulator, installs platform resources or chooses another Xcode.

`/usr/bin/python3 scripts/probe_ci_toolchain.py` reports two independent signals:

- **Pinned toolchain missing:** the scheduled runner must contain the pinned developer
  directory and exact Xcode `Contents/version.plist` version/build. With that pinned
  `DEVELOPER_DIR`, `xcrun simctl list runtimes --json` must contain exactly one available
  runtime matching each pinned iOS/tvOS identifier, version and build, using the same
  inventory rules as `scripts/setup_ci_python.py`. Missing, unavailable or mismatched
  inventory opens or updates a high-confidence `pinned toolchain missing` issue per
  runner/Xcode version/build. The probe reports it before attempting upstream reads.
- **Possible toolchain change - please check:** anonymous reads of the official
  [arm64 image toolset](https://github.com/actions/runner-images/blob/main/images/macos/toolsets/toolset-xcode-27.json)
  check whether the exact `version+build` Xcode pin is still listed. This verified
  machine-readable source describes image build configuration, not the deployed runner;
  its `install_runtimes: default` does not specify exact runtime builds. Separately, any
  open [Announcement issue](https://github.com/actions/runner-images/labels/Announcement)
  whose combined title/body contains `Xcode` (case insensitive) and the pinned major
  number triggers the same early-warning issue. The number must not be part of a larger
  integer: `27.1` matches major 27, while `127` and `270` do not. The words/numbers need
  not be adjacent. No removal grammar, affected-image checkboxes, beta exclusions or
  runtime/stable-version interpretation are used. Beta/runtime changes, installation
  notices, retained versions, other images and unrelated numeric mentions can all warn;
  these false positives are intentional. This issue quotes all matched announcement
  links and any missing-toolset-pin link and never asserts an actual pinned removal.
  One stable marker per runner/Xcode major keeps all early warnings in one open issue,
  even when the exact minor version or build changes.

When inventory is present, the upstream toolset lists the pin and no open announcement
mentions Xcode with its major, both signals say `quiet` and perform no issue writes.
Each signal has its own stable body marker and bot-authored tracking issue. Updates retain
the issue number and comments and replace the generated title/body with current findings
and the run/attempt link. The repository-scoped issue token is used only for local
tracking issues. The probe never closes issues automatically. A manual missing-pin
simulation uses a separate inventory marker and `[SIMULATION]` title, so it cannot update
a real missing or possible-change issue; genuine early warnings still report normally.
Workflow concurrency serializes issue lookup and creation without cancelling a running probe.

The job receives only `contents: read` and `issues: write` through `GITHUB_TOKEN`; workflow
permissions are `{}`. No App, secret or environment setup is needed. The entry point
rejects the wrong event, ref or workflow path before reading its token, and manual dispatch
requires the repository owner. The only input is boolean `simulate_missing_pin`; it changes
an inventory finding, never checkout code, pins or permissions. Branch dispatch is rejected.
API requests have 30-second deadlines and complete pagination is required (at most 20 pages
per query). Network errors, invalid data and duplicate matching issues fail closed with
exit 1 and no response-body/token logging. Exit 0 means the probe was quiet or successfully
reported an alert; it does not mean a missing toolchain was repaired. Build entry points
continue to reject unavailable pins.

After this workflow and script land on `main`, run the quiet case and the simulation twice.
Dispatch one at a time and wait for its successful completion before starting the next:

```bash
gh workflow run ci-probe.yml --ref main -f simulate_missing_pin=false
gh workflow run ci-probe.yml --ref main -f simulate_missing_pin=true
gh workflow run ci-probe.yml --ref main -f simulate_missing_pin=true
gh run list --workflow ci-probe.yml --event workflow_dispatch --limit 5
gh run view <run-id> --log
```

The real-pin run must say `quiet` for the `missing` signal and create no missing-toolchain
issue. Its `possible` signal may independently warn about matched upstream sources; if
there are none, it must also say `quiet`. The first simulation must open its tracking issue; the repeated simulation
must update the same open issue. Inspect that issue's marker/run link, then close only that
test issue with `gh issue close <simulation-issue-number> --reason completed`, using plain
`gh` as the maintainer identity. This cleanup needs no bot comment. Pre-merge hosted
dispatch acceptance is `PENDING_POST_MERGE`: do not register a temporary workflow or execute
PR code in this trusted job just to produce an early run. Issue #92 stays open until the
coordinator records all three dispatch receipts. The Python seam tests prove the
inventory, announcement, open/update, simulation isolation and quiet decisions before merge:

```bash
python3 -B -m unittest discover -s scripts -p test_probe_ci_toolchain.py
python3 -B -m unittest discover -s scripts -p test_check_workflow_policy.py
python3 -B scripts/check_workflow_policy.py
```

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
  Issue writes are reserved for the exact `ci-probe.yml` and `ci-report.yml` paths.
  `ci-probe.yml` additionally requires the display name `ci-probe`, both scheduled and
  manual triggers only, workflow permissions `{}`, and exactly `contents: read` plus
  `issues: write` at job level.
- Only `.github/workflows/privacy-preflight.yml` may use `pull_request_target`.
- Only `ci-publish.yml` and `ci-report.yml` may use `workflow_run`. The former lists
  `ci-gate` and/or `ci-ui`; the latter lists `ci-nightly` and/or `ci-gate` (post-merge
  reporting). Wildcards and other producer names are rejected. Event types may only be
  `requested`, `in_progress` and `completed`; an omitted type means `completed`.
- Trusted workflow paths are the privacy workflow and `ci-publish.yml`, `ci-report.yml`,
  `ci-probe.yml`, `ci-approval.yml`, `ci-approve.yml` and `ci-release.yml`. Trust comes from
  the exact path, never the display name. Privileged triggers also select this strict
  policy, even if their workflow path is forbidden. Their checkout action may use `main`,
  `refs/heads/main` or `${{ github.event.repository.default_branch }}`, in the same
  repository. Only the privacy path triggered exclusively by `pull_request_target` may
  use `${{ github.event.pull_request.base.sha }}` or omit its checkout ref. A same-named
  workflow with `pull_request`, mixed triggers or another event receives no exception.
  Indirect refs, PR head/merge SHAs and workflow-run head SHAs are rejected.
- Trusted execution is denied by default. Each `run` must be one of the literal reviewed
  commands: `pwd`, `git rev-parse HEAD`, or `/usr/bin/python3 scripts/check_workflow_policy.py`
  with no arguments or `--root .`. Only the privacy path with exclusively
  `pull_request_target` may also invoke `scripts/run_trusted_privacy_preflight.sh` or use
  its existing object-fetch block, matched as a complete literal string. That block fetches
  Git objects without materializing PR code; adding any command makes it unapproved.
  Other shell syntax, redirection, pipelines, global Git options, dynamic arguments,
  arbitrary entry points and artifact path arguments fail closed. Additional trusted
  entry points and argument contracts require an explicit policy change and review.
  Only `ci-probe.yml` may also run the exact setup command shown in its workflow and
  `/usr/bin/python3 scripts/probe_ci_toolchain.py`, without additional arguments or shell
  commands. This exception does not authorize those commands in another trusted workflow.
- Trusted remote actions must be both SHA-pinned and on the input allowlist:
  `actions/checkout` (`ref`, `repository`, `fetch-depth`, `persist-credentials`) or
  `actions/download-artifact` (`path`, `name`, `pattern`, `run-id`, `github-token`,
  `repository`, `artifact-ids`, `merge-multiple`). Other actions, reusable workflows,
  container actions, inline action scripts and unknown inputs are rejected. Local actions
  must be literal paths under `.github/actions`, outside artifact/download directories,
  without inputs. Approved downloads cannot write into that local-action directory.
- Trusted artifact downloads must go into `ci-artifacts` or its children, optionally
  under `${{ runner.temp }}`. They cannot overwrite checked-out scripts or local actions.
  Future approved entry points may read artifact data internally after review; the workflow
  cannot choose an artifact path as an executable, action or argument.
- Trusted command settings cannot change the working directory from the default workspace
  or use shells other than literal `bash`/`sh`. Job containers and services are rejected.
  Workflow/job/step environment bindings must be explicitly reviewed; currently only the
  privacy workflow's `PRIVACY_PR_NUMBER`, `PRIVACY_HEAD_SHA` and `PRIVACY_BASE_SHA` bindings
  to their corresponding event fields, and ci-probe's `CI_PROBE_TOKEN` binding to
  `${{ github.token }}` and `CI_PROBE_SIMULATE_MISSING_PIN` binding to
  `${{ inputs.simulate_missing_pin || false }}` are allowed. Interpreter startup/search variables
  such as `PATH`, `BASH_ENV`, `PYTHONPATH` and `NODE_OPTIONS` cannot be overridden.
- `ci-publisher` may be referenced only by `ci-publish.yml`, `ci-approval.yml` and
  `ci-approve.yml`; `ci-approval` only by `ci-approval.yml`; `release` only by
  `ci-release.yml`. Protected names are matched case-insensitively, as on GitHub.
  Environment names must be literal so expressions cannot hide a protected environment.

Non-trusted workflows retain the general pin, permission, timeout, trigger and protected
environment checks; they do not receive this trusted command/action allowlist.

This is a static workflow guard, not a proof of approved action or repository script
behavior. Reviewers must inspect trusted entry points, local actions and pinned actions for
data-only handling, verify producer path/ID and provenance at runtime, and keep event/ref
checks before credentials are read. GitHub App creation, secrets, environments, settings,
rulesets and approvals remain maintainer-gated; this command performs none of them.

The existing privacy workflows remain unchanged. The shared host-check entry point runs
this standalone command as its own `workflow policy` identity; `scripts/check_all.sh`
delegates to that entry point. `ci-gate` uses this pinned environment setup and records
the pins manifest and workflow-policy hashes in its [producer summary](CI_SUMMARY.md).
