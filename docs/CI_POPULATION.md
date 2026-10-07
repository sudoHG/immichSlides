# Static population and verdict policy

The pure-Python libraries use the [version 1 summary contract](CI_SUMMARY.md).
They do not publish statuses, call GitHub, import candidate modules or execute
candidate source. The future trusted consumer must run these libraries from its
trusted revision and supply independently admitted inputs. The host producer uses
them informationally from its working checkout, which is not trusted publication.

## Static input and identities

`scripts/ci_population.py` accepts source-text maps. `python_sources(directory)`
reads Python files into a module-name map; it reads no private configuration.

- `python_identities(files)` uses the AST, follows imported and assignment aliases and local
  mixins, computes C3 method resolution and respects method overrides. It discovers
  classes visible in `test_*` modules, including imported TestCase subclasses,
  keyed by the defining module/class/method used by unittest. Local classes inside
  function bodies are fixture code, not discovered tests. Unresolved local or
  third-party bases, and dynamic bases, in a test module fail closed, including
  aliases that might otherwise erase a whole suite. Conditional imports or assignments
  that can bind discovered classes or bases raise `ContractError`; harmless constant
  configuration and function-local fixtures are not discovery bindings. Base names,
  imported namespaces and their alias dependencies must be bound exactly once,
  before use. Rebinding before or after a class definition, deletion, mutation and
  forward alias bindings are explicitly rejected rather than resolved from the
  module's final state. Conditional classes, wildcard imports and
  `load_tests` hooks in test modules also fail. Non-test helper modules may contain
  unrelated generic or factory-based classes; a discovered TestCase's MRO must
  still resolve completely. Unshadowed builtins and the explicit Python 3.9
  standard-library allowlist are non-test terminals. Local bindings/modules
  cannot impersonate these terminals; unittest and doctest TestCase bases remain
  recognized test ancestors.
- `swift_identities(files, platform)` finds `@Test` functions in explicit or
  implicit suites, nested suites and cross-file extensions. Module-qualified
  `@Testing.Test` and `@Testing.Suite` have the same meaning as their bare forms.
  Unknown qualifications and unsupported test declarations raise `ContractError`.
  `@Suite` attributes are parsed, but do not replace function identities. Keys are `Type/function`
  (qualified type for nested suites), or `function` for a top-level test. Arguments
  and display names are not keys. `#if os(...)`, compound conditions, `DEBUG` and
  simulator conditions use the shared parser's Debug simulator model. Unknown or
  malformed conditions, ambiguous duplicate function names, unresolved extensions
  and local `@Test` declarations are errors.
  Traditional `XCTestCase` methods in the mixed unit target are also enumerated
  through the shared XCTest parser using platform-filtered source and recorded
  with kind `swift`. Indirect
  inheritance (`Child: Base: XCTestCase`) is explicitly rejected in both XCTest
  inventories until inherited-method enumeration is supported; it never silently
  drops a subclass. Mixed unit functions outside XCTest are classified by the
  parser's explicit mode, without filtering diagnostic strings.
- `ui_identities(files, platform)` reuses `scripts/ui_test_inventory.py`, the
  parser also used by the existing excluded-test check. It intersects method and
  owning-class platforms, merges same-named classes across conditional branches,
  and keys tests as `Class/testMethod`. Module-qualified `XCTest.XCTestCase` is
  supported; unsupported generic XCTest classes and XCTest base aliases fail explicitly.
- `removed_tests(base_population, tested_population, base_sha=admitted_base_sha)`
  requires a record `{base_sha, identities}`, with a valid SHA matching admission
  and unique valid identities. It reports the admitted PR base minus the tested
  merge tree. Removal is informational; a population from later `main` is invalid
  input and never appears as PR removals or coverage expectations.

Platforms are `ios` and `tvos`, stored in the identity's `platform` dimension.
For static UI input include both `immichSlidesUITests` and `TestSupport`; for unit
input include every Swift file in `immichSlidesTests`. Target membership is a caller
responsibility, not inferred from filenames. Parsers reject unsupported forms;
they do not pretend to implement arbitrary Swift or Python metaprogramming.

Example (from the repository root, with a trusted library on `PYTHONPATH`):

```python
from pathlib import Path
from ci_population import python_identities, python_sources, swift_identities, ui_identities

python_tests = python_identities(python_sources(Path("scripts")))
unit_sources = {str(p): p.read_text(encoding="utf-8")
                for p in Path("immichSlidesTests").rglob("*.swift")}
ios_functions = swift_identities(unit_sources, "ios")
ui_sources = {str(p): p.read_text(encoding="utf-8")
              for root in ("immichSlidesUITests", "TestSupport")
              for p in Path(root).rglob("*.swift")}
ios_ui_methods = ui_identities(ui_sources, "ios")
```

## Expected skips and tier deselections

`scripts/ci-test-policy.json` is version 1, with `approval_state`,
`expected_skips` and `deselections`. It ships in **proposed** state. Changing that
state or approving the initial lists is a maintainer gate; agents must not do it.
Proposed entries never authorize passing exceptions in the verdict library.

When adding a test that needs a skip or deselection, include the policy entry in
the same PR as the test. Record its tier, environment and exact reason, and the
other owning tier for a deselection. This is a CI-trusted policy change: the
maintainer must approve the PR's exact head SHA before candidate exceptions can
apply in the trusted verdict, and a later push requires fresh approval. After the
initial lists are approved, add entries to that approved file without resetting
its whole-file `approval_state`: the trusted verdict keeps using the admitted
base policy until the exact head is approved. Candidate host checks read their
own policy and may pass with a new entry before approval; that result is
informational. The initial lists in this PR remain `proposed` pending their
separate maintainer decision. The test must still meet [TESTING section 4](TESTING.md#4-when-a-test-may-skip);
policy approval does not excuse a product failure or missing compilation.

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
Host checks strip `STRICT_E2E_REVIEWED_SCREENSHOTS`, so this environment remains
`hermetic` even when the caller has configured external captures. Run the
[reviewed screenshot calibration](TESTING.md#optional-reviewed-screenshot-calibration-dataset)
directly with unittest to use that corpus.

Deselections contain exact `identity`, `tier`, `environment`, `reason` and
`owning_tier`. The owner must be another tier. A deselected identity must still be
compiled, must not be observed, and must be reported with the policy's exact
reason and owner. A policy-required deselection that executes or is omitted fails.
The initial proposed deselection list is **empty**: no tests are moved out of a
tier before fixture coverage is measured. UI shard/fixture selections belong to
their separate ticket, which can propose entries using this model.

### Pending unit-layer exceptions

Approval of the five entries and empty deselection list above covers **only the
host layer**. The review identified a 23-site unit-layer conditional-skip backlog;
it remains pending in [unit producer ticket #91](https://github.com/sudoHG/immichSlides/issues/91).
Known suites and gating files are listed below; none is authorized by the host policy.

| Unit source | Pending condition |
| --- | --- |
| `FaceBoxLiveProbeTests.swift` | Live inputs and Evidence-plan gating |
| `PerformanceLiveIntegrationTests.swift` | Live inputs and Evidence-plan gating |
| `PlaybackPoolResolverLiveIntegrationTests.swift` | Live membership configuration |
| `SlideShowViewModelLiveIntegrationTests.swift` | Live playback/dedup configuration |
| `ExifForegroundAnalyzerPerformanceIOSTests.swift` | Evidence-plan gating |
| `PlaybackRuntimeEvidenceManifestTests+Startup.swift` | External runtime evidence JSONL |
| `EvidenceRun.swift` | Shared Evidence-plan environment switch |

The current source-tree census finds 21 `.enabled(if:)` / `.disabled(` attributes
across six test files, plus the shared Evidence switch. Reconcile that census with
the review's 23-site backlog in #91, enumerate compiled identities and record actual
emitted skip reasons/owning tiers before proposing unit entries. Head-SHA approval
is required for those entries too; host approval cannot authorize unit skips.

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
Coverage discrepancies use `coverage-failed` diagnostics with readable function
keys and a failed status. The version 1 diagnostic array stores these separately
by code. Markdown labels `coverage-failed` as `Coverage`, `policy-proposed` as
`Policy`, and `population-invalid` as `Population`. Infrastructure health counts
must exclude all three codes (the shared `NON_INFRASTRUCTURE_DIAGNOSTICS` mapping
defines this boundary). Unexpected skips retain their observed reason; missing
compiled/executed identities are named without inventing execution rows.
The producer writes its interruption placeholder before parsing the policy or
static population. Invalid inputs record `population-invalid`, all host checks
still run, and the final failed record preserves their observations.

## Classification and gate evaluation

`scripts/ci-classification.json` is an allowlist, never a list of app-sensitive
paths. `classify_changes(paths, policy, build_target_paths=members)` requires static
build membership for the tested tree and both diff sides. PR changes use
`base...head`; pushes use `before..after`; include old and new rename paths.
An allowlisted document can be unaffected only if it is not a build member and
not CI-trusted. The bundled privacy policy, all unknown paths and every trusted
path affect the app. CI-trusted paths are `.github/workflows/**`, `.swift-format`,
`scripts/ci_*.py`, every script invoked by `run_host_checks.HOST_CHECKS`, and the CI
entry points, policy/data/pins and their own tests listed in
`scripts/ci-classification.json`. This includes test conventions, release guards,
localization catalog/usage, Python prerequisites and workflow-policy checks, plus
`test_conventions_allowlist.json`. The formatting policy changes the lint verdict.
A regression requires every `HOST_CHECKS` script to be covered by `ci_trusted`.
Ordinary product/runner tests and other scripts, `AGENTS.md` and `CLAUDE.md` are not CI-trusted;
adding or removing an ordinary test does not itself require CI-head approval.
Invalid relative paths fail closed. There is no comment-only classification.

`evaluate_gate` consumes the required job artifacts and independent static
`expected`, `admission_identity`, `required_jobs`, `base_policy`, `environment`
and trusted classification booleans. Every required-job object has `tier`, `job`,
`shard`, `run_id`, `attempt`, an explicitly supported `workflow_paths` list, and
independently derived `expected` identities for that job. Their union must equal
the overall expected population; one shard cannot cover an omission in another.
Every artifact must match the admitted run identity, job, run, attempt and workflow;
missing, duplicate or unexpected jobs fail. Each job accounts for its compiled
population, and the aggregate declared/compiled union must equal the tested tree.
PR evaluation also requires independently derived `base_population={"base_sha":
admitted_base_sha, "identities": base_identities}`. Missing, malformed, duplicate
or mismatched base records fail validation before removal reporting; valid
removals never affect the coverage verdict.

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
run. `allowed_events` defaults to `("pull_request", "push")`, so local and manual
dispatch records are rejected by default. A local caller explicitly opts in with
`allowed_events=("local",)`; dirty local trees still cannot prove the recorded tree.
Manual dispatch is not `ci-gate` evidence.

Summary and identity parsing use the installed reader registries in
`scripts/ci_summary.py`. A successor is accepted only once its parser/validator is
installed in that trusted reader, with its supported workflow paths. Unknown,
boolean, string, missing and malformed versions fail. No successor is emitted by
this change.

## Verification commands

```bash
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s scripts -p 'test_ci_population.py'
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s scripts -p 'test_ci_verdict.py'
PYTHON=/usr/bin/python3 scripts/check_all.sh --output-dir '<fresh-outside-repo>'
```

Use a fresh output directory; records are temporary and should be removed after
reading results. No simulator, build, private server or credential is needed.
There is no trusted publisher or status-writing identity in this ticket.
