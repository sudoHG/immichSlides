# CI toolchain and workflow policy

[`scripts/ci-pins.json`](../scripts/ci-pins.json) owns exact tools, Xcode
path/build, runner, simulator runtimes/device types and Python dependencies.
Missing or mismatched pins fail; never choose another installed runtime.

| Tool or destination | Pin |
| --- | --- |
| Runner | `xcode-27` |
| Xcode | 27.0 (27A266a) |
| iPhone | iPhone 17e, iOS 27.0 (24A434) |
| iPad | iPad Air 11-inch (M4), iOS 27.0 (24A434) |
| Apple TV | Apple TV 4K (3rd generation), tvOS 27.2 (24K150), 4K device type |
| Python | 3.9.6 |
| pip / Pillow / PyYAML | 25.3 / 11.3.0 / 6.0.3 |
| zstd | 1.5.7 |

## Setup

Provision pinned tools first. Setup creates only a task-owned venv and installs
exact wheels without ambient pip configuration/shared caches. It refuses an
existing venv path and installs no system tools or simulator resources.

```bash
/usr/bin/python3 scripts/setup_ci_python.py --python /usr/bin/python3 \
  --venv /tmp/immichslides-ci-python --verify-toolchain
source /tmp/immichslides-ci-python/bin/activate
python3 -B scripts/setup_ci_python.py --venv /tmp/immichslides-ci-python --check
python3 -B scripts/check_workflow_policy.py
scripts/check_all.sh
```

`--verify-toolchain` reads Xcode metadata and inventories runtimes/device types
using the pinned developer directory; it does not build, boot or download.
`--check` only verifies the environment. Builds require 80 GiB free locally.
See [Setup](../CONTRIBUTING.md#setup).

## Remaining workflows

| File | Responsibility |
| --- | --- |
| [ci-gate.yml](../.github/workflows/ci-gate.yml) | PR/main host checks, applicable builds and offline units |
| [privacy-preflight-bootstrap.yml](../.github/workflows/privacy-preflight-bootstrap.yml) | Candidate privacy tests/scan |
| [privacy-preflight.yml](../.github/workflows/privacy-preflight.yml) | Base-owned privacy tests/scan |
| [ci-smoke-shadow.yml](../.github/workflows/ci-smoke-shadow.yml) | Sole nightly and manual main smoke |
| [ci-toolchain.yml](../.github/workflows/ci-toolchain.yml) | Setup/inventory/policy and host checks for relevant PRs or manual runs |

The toolchain workflow has a 30-minute limit, two Python shards and a 1200-second
budget per child. Its path filter includes this guide. It is an additional
toolchain check, not a UI lane. There is no scheduled toolchain issue writer.

## Workflow policy

`python3 -B scripts/check_workflow_policy.py` parses every workflow directly
under `.github/workflows`; `--root PATH` selects another checkout.
Exit 0 means zero violations; violations exit 1; invalid arguments exit 2.
Unreadable/symlinked workflows, malformed or duplicate-key YAML, aliases and
missing jobs/triggers fail closed.

Remote actions use full commit pins (containers use digests).
Permissions are explicit/read-only; repository secrets and job environments are
forbidden. Jobs have bounded timeouts, with the reviewed smoke matrix expression
as the only dynamic exception. Only the trusted privacy path may use
`pull_request_target`; no retained workflow uses `workflow_run`.

Trusted paths have exact command, action-input, checkout-ref and environment
contracts. Privacy fetches candidate objects without executing candidate source.
Smoke stages main-owned control tooling, admits tested main source and treats
downloads as data. Downloads cannot overwrite scripts/actions; loader/search
environment overrides and unreviewed containers/services are rejected.
Smoke plan and artifact contracts are checked explicitly.

Static policy does not prove runtime correctness or change settings, rulesets,
secrets or environments. There is no per-push CI approval flow.
GitHub may separately hold first-time fork contributor runs for built-in approval.
