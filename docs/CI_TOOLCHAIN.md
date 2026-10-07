# CI toolchain and workflow policy

[scripts/ci-pins.json](../scripts/ci-pins.json) is the versioned source for the runner,
Xcode version/build/path, simulator versions/builds/runtime identifiers, device types,
Python, Python packages and zstd. Consumers must compare exact versions and fail when a
pin is unavailable; they must not select the latest installed version as a fallback.

The Xcode and simulator pins match the [hosted Vision probe](https://github.com/sudoHG/immichSlides/actions/runs/37592421181).
Python 3.9.6 and Pillow 11.3.0 match the contributor verification baseline. The workflow
uses Xcode's `/usr/bin/python3` explicitly and verifies its version; a different version
fails rather than falling back to the Homebrew interpreter. Hosted Python 3.14 passed the
policy tests but failed existing P2 fixture health checks; compatibility work belongs in
a separate issue. PyYAML 6.0.3 parses workflow structure safely. Pip 25.3 is the last
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
  to their corresponding event fields are allowed. Interpreter startup/search variables
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
