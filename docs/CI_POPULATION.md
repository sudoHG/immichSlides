# Static population and verdict policy

The pure-Python libraries use the [version 1 summary contract](CI_SUMMARY.md).
They do not publish statuses, call GitHub, import candidate modules or execute
candidate source. The future trusted consumer must run these libraries from its
trusted revision and supply independently admitted inputs. The host producer uses
them informationally from its working checkout, which is not trusted publication.

## Static input and identities

`scripts/ci_population.py` accepts source-text maps. `python_sources(directory)`
reads Python files into a module-name map; it reads no private configuration.

- `python_identities(files)` uses the AST, follows imported aliases and local
  mixins, computes C3 method resolution and respects method overrides. It discovers
  classes visible in `test_*` modules, including imported TestCase subclasses,
  keyed by the defining module/class/method used by unittest. Local classes inside
  function bodies are fixture code, not discovered tests. Conditional classes,
  dynamic bases, wildcard imports and `load_tests` hooks fail closed instead of
  claiming complete static coverage.
- `swift_identities(files, platform)` finds `@Test` functions in explicit or
  implicit suites, nested suites and cross-file extensions. `@Suite` attributes
  are parsed, but do not replace function identities. Keys are `Type/function`
  (qualified type for nested suites), or `function` for a top-level test. Arguments
  and display names are not keys. `#if os(...)`, compound conditions, `DEBUG` and
  simulator conditions use the shared parser's Debug simulator model. Unknown or
  malformed conditions, ambiguous duplicate function names, unresolved extensions
  and local `@Test` declarations are errors.
  Traditional `XCTestCase` methods in the mixed unit target are also enumerated
  through the shared XCTest parser and recorded with kind `swift`.
- `ui_identities(files, platform)` reuses `scripts/ui_test_inventory.py`, the
  parser also used by the existing excluded-test check. It intersects method and
  owning-class platforms and keys tests as `Class/testMethod`.
- `removed_tests(base_population, tested_population)` reports the admitted PR
  base minus the tested merge tree. Removal is informational. No later `main`
  population participates in coverage or a verdict.

Platforms are `ios` and `tvos`, stored in the identity's `platform` dimension.
For static UI input include both `immichSlidesUITests` and `TestSupport`; for unit
input include every Swift file in `immichSlidesTests`. Target membership is a caller
responsibility, not inferred from filenames. Parsers reject unsupported forms;
they do not pretend to implement arbitrary Swift or Python metaprogramming.

Example (from the repository root, with a trusted library on `PYTHONPATH`):

```python
from pathlib import Path
from ci_population import python_identities, python_sources, swift_identities

python_tests = python_identities(python_sources(Path("scripts")))
unit_sources = {str(p): p.read_text(encoding="utf-8")
                for p in Path("immichSlidesTests").rglob("*.swift")}
ios_functions = swift_identities(unit_sources, "ios")
```

## Expected skips and tier deselections

`scripts/ci-test-policy.json` is version 1, with `approval_state`,
`expected_skips` and `deselections`. It ships in **proposed** state. Changing that
state or approving the initial lists is a maintainer gate; agents must not do it.
Proposed entries never authorize passing exceptions in the verdict library.

Expected-skip entries contain `kind`, `key_pattern`, exact `dimensions`, `tier`,
`environment` and exact `reason`. Patterns use case-sensitive shell glob matching
on the whole function key. Exactly one rule must match. Matching a reason alone
does not excuse a skip. A matching skip is reported in `expected_skips` and allows
"passed with N expected skips"; a matching test that executes is a failure.
Only a fully accounted unverified result explained by matching skips can pass.
Infrastructure failures and missing results cannot be explained by skip policy.

The initial proposed list names each of the five
`ReviewedScreenshotCalibrationTests` methods separately, for tier `host`,
environment `hermetic`, reason `STRICT_E2E_REVIEWED_SCREENSHOTS is not set`.
They require an external, human-reviewed calibration screenshot corpus. There is
no class wildcard that silently registers future calibration tests.

Deselections contain exact `identity`, `tier`, `environment`, `reason` and
`owning_tier`. The owner must be another tier. A deselected identity must still be
compiled, must not be observed, and must be reported with the policy's exact
reason and owner. A policy-required deselection that executes or is omitted fails.
The initial proposed deselection list is **empty**: no tests are moved out of a
tier before fixture coverage is measured. UI shard/fixture selections belong to
their separate ticket, which can propose entries using this model.

`evaluate_population(summary, expected, policy, environment="hermetic")` returns
`status`, all `errors`, expected skip identities, deselections, missing compiled
and missing executed identities. Declared and compiled function populations must
equal the independently supplied expected population. Swift parameter rows can
expand one function, but every compiled parameter must have its own observation
or approved deselection. Extra observations, failed/cancelled/incomplete results,
human-review outcomes and unregistered retries are failures. Retry eligibility
and the flaky registry are separate work; this library currently permits no
`flaky-passed` shortcut.

The host producer now records static Python declarations, dynamic discovery and
observations separately, hashes this policy, and evaluates their equality. Only
the exact proposed calibration skips retain exit 0 / `unverified` with
`policy-proposed`; unexpected skips and missing identities return exit 1.
Approved exceptions can produce `passed`. This explicitly replaces the previous
rule that every skip unconditionally made the summary unverified.

## Classification and gate evaluation

`scripts/ci-classification.json` is an allowlist, never a list of app-sensitive
paths. `classify_changes(paths, policy, build_target_paths=members)` requires static
build membership for the tested tree and both diff sides. PR changes use
`base...head`; pushes use `before..after`; include old and new rename paths.
An allowlisted document can be unaffected only if it is not a build member and
not CI-trusted. The bundled privacy policy, all unknown paths and every trusted
path affect the app. Workflows, scripts (including policy/data/pins), working
rules and Swift formatting configuration are conservatively CI-trusted. Invalid
relative paths fail closed. There is no comment-only classification.

`evaluate_gate` consumes the required job artifacts and independent static
`expected`, `admission_identity`, `required_jobs`, `base_policy`, `environment`
and trusted classification booleans. Every required-job object has `tier`, `job`,
`shard`, `run_id`, `attempt`, an explicitly supported `workflow_paths` list, and
independently derived `expected` identities for that job. Their union must equal
the overall expected population; one shard cannot cover an omission in another.
Every artifact must match the admitted run identity, job, run, attempt and workflow;
missing, duplicate or unexpected jobs fail. Each job accounts for its compiled
population, and the aggregate declared/compiled union must equal the tested tree.

Inputs `fork_originated`, `ci_changing` and `app_affected` are derived by the trusted
caller, not copied from producer claims. A fork PR or CI-changing PR requires
`approved_head` equal to that admission's exact `head_sha`. `select_policy` uses
the base policy unless the exact head is approved and a candidate policy is
supplied. Even then, `proposed` exceptions remain inactive. Verdicts record
`source`, `self_reported`, `approval_based`, every error, skips, deselections and
the independently computed removal report. Approval records and provenance
verification are not implemented here.

For context `ui`, trusted `app_affected=False` returns `not-applicable` only after
approval checks; CI-changing input cannot use that shortcut. Host checks always
run. Generic local evaluation accepts clean local identities; dirty local trees
cannot prove the recorded tree. `ci-gate` consumers **must** pass
`allowed_events=("pull_request", "push")`; manual dispatch is not gate evidence.

Summary and identity parsing use the installed reader registries in
`scripts/ci_summary.py`. A successor is accepted only once its parser/validator is
installed in that trusted reader, with its supported workflow paths. Unknown,
boolean, string, missing and malformed versions fail. No successor is emitted by
this change.

## Verification commands

```bash
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s scripts -p 'test_ci_population.py'
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s scripts -p 'test_ci_verdict.py'
PYTHON=/usr/bin/python3 scripts/check_all.sh --output-dir /tmp/immichslides-ci/w03c/host
```

Use a fresh output directory; records are temporary and should be removed after
reading results. No simulator, build, private server or credential is needed.
There is no trusted publisher or status-writing identity in this ticket.
