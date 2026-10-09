# Static population and verdict policy

The pure-Python libraries use the [version 1 summary contract](CI_SUMMARY.md).
They do not publish statuses, call GitHub, import candidate modules or execute
candidate source. The future trusted consumer must run these libraries from its
trusted revision and supply independently admitted inputs. The host producer uses
them informationally from its working checkout, which is not trusted publication.

Static population is an independent cross-check alongside the compiled test
enumeration and execution observations. Neither inventory can substitute for the
other: a declaration missing from compilation, or a compiled test missing from
the static population, keeps the verdict red. These libraries implement documented
subsets, not full Swift or Python parsers. Known unsupported or unresolved discovery
forms fail closed with `ContractError`; successful parsing does not remove the
need for the independent compiled enumeration. Extend the existing omission
regressions when adding grammar support.

## Static input and identities

`scripts/ci_population.py` accepts source-text maps. `python_sources(directory)`
reads Python files into a module-name map; it reads no private configuration.
The directory is the import root (a `sys.path` entry). A nested
`pkg/__init__.py` maps to `pkg`, not `pkg.__init__`; the returned `PythonSourceMap`
retains package names and relative diagnostic filenames. Relative imports use
the initializer's own package, or an ordinary module's containing package, with
Python's relative-import levels. Initializer re-exports and supplied child modules
are resolved without imports. Unknown local exports, opaque third-party package
re-exports and module/export collisions are unsupported and raise `ContractError`.
Package initializers are discovery modules even if their names do not match
`test_*`, as in unittest. The root's own initializer is not automatically treated
as a package named after the directory; include its parent import root to do that.
Keep the returned source-map metadata. For copied/serialized module maps, pass
`packages=package_names` to `python_identities`, or explicitly name initializer
keys `pkg.__init__` (normalized on input).

- `python_identities(files)` follows unconditional import aliases and local mixins,
  computes C3 method resolution and respects function-definition overrides. It
  discovers classes visible in `test_*` modules, including imported TestCase
  subclasses, keyed by the defining module/class/method used by unittest. The
  [allowed declaration grammar](#python-declaration-grammar) is enforced before
  returning identities. Unsupported forms raise `ContractError` with file and line;
  they never yield an incomplete successful inventory. Function bodies are opaque
  fixture/runtime code. Unrelated non-test helpers may use generic or factory
  bases; a discovered TestCase's complete MRO must still satisfy the grammar.
  Unshadowed builtins and the explicit Python 3.9 standard-library allowlist are
  non-test terminals; unittest and doctest TestCase bases are test ancestors.
  As in unittest, a class with no `test*` methods is registered once as `runTest`
  when that method exists in its inheritance chain; a class with named tests does
  not also run the fallback.
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
  Before declaration classification, the shared lexer blanks line/block/nested
  comments and string/Character literals, including raw/multiline strings and
  interpolation, preserving offsets and line numbers. Escaped identifiers retain
  their text. Qualified names tolerate whitespace after this pass; comments
  around a module's dot cannot hide inheritance. Unterminated lexical input and
  unresolved XCTest-like class/alias declarations fail explicitly.
  Zero-argument test returns may be implicit or spelled `Void`, `Swift.Void`,
  `()`, `(Void)` or `(Swift.Void)`. An unclassifiable direct `test...` signature
  raises `ContractError`, including unsupported return types. Private/static/class,
  generic and nonzero-argument functions are classified as nondiscoverable.
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

## Python declaration grammar

Supply all local source modules, including imported test-class and mixin providers.
The grammar applies to `test_*.py` and those providers. Imports of unrelated
non-test helpers do not make their unrelated classes discoverable, but an imported
helper must not build classes at import time: a module-level assignment from `type(name, bases, namespace)`,
`types.new_class` or any call that receives `unittest.TestCase` or a test class is rejected, because
unittest would discover the result while the static inventory cannot. At module scope:

| Allowed form | Constraints |
| --- | --- |
| `import` / `from ... import` | Unconditional, explicit names; no star imports |
| `class Name(Base, ...)` | Bases are names or attributes bound once before the definition and statically resolved; no decorators, metaclass keywords, subscript bases or class-name rebinding |
| `def` / `async def` | Function bodies are not evaluated; no discovery hooks such as `load_tests` or dynamic attribute/subclass hooks; signatures use the grammar below |
| `NAME = data` / `NAME: Type = data` | One plain name, never a class, base, discovery-hook, `test*` or `runTest` name; only the data expressions below |
| Docstring / `pass` | No binding or execution |
| `if __name__ == "__main__": unittest.main()` | Exact script entry point, with no arguments, extra statements or else branch; import-based discovery never executes it |

Class bodies accept method definitions, docstrings, `pass` and data assignments
under the same name restrictions; class data assignments cannot call functions.
Method overrides across classes follow C3 MRO; duplicate `test*` or `runTest` definitions within
one class are rejected. Saving a class (`Saved = Hidden`), assigning a base alias,
replacing a class/base import, assigning/deleting any `test*` or `runTest` member (including
`test_a = None`), nested class declarations, conditional bindings and all other
statement forms are outside the grammar. Function-local fixture classes are not
module discovery declarations.

Data expressions are literals, literal containers, references to earlier data
assignments, unary/binary operations and comparisons. Module data can additionally
use unshadowed `bool`, `int`, `float`, `complex`, `str`, `bytes`, `bytearray`, `list`,
`tuple`, `dict`, `set` and `frozenset` constructors. Static `pathlib.Path` imports
support data construction, `resolve`, `with_name`, the `parent`, `parents`, `name`,
`stem`, `suffix` attributes and path-parent indexing. `__file__` and `sys.platform`
are readonly data inputs. Constructor import bindings must stay identical at
definition time; arbitrary factories, unpacking, assignment expressions and
attribute/subscript mutation are unsupported.

The callable-preserving decorators `classmethod`, `staticmethod`, `unittest.skip`,
`skipIf`, `skipUnless` and `expectedFailure` are supported with unshadowed bindings;
skip arguments use the data grammar. `property` is allowed for non-test methods,
excluding `runTest`.
Other decorators are unsupported. Class decorators are always rejected.
Use `with patch(...)` inside method bodies, compile regular expressions inside
functions, and keep helper classes undecorated in modules governed by this grammar.

Signature defaults accept literals, names, literal containers, name/container
unpacking and unary literals. Function and variable annotations accept type names, literal arguments,
attributes, subscripts and type unions; calls, lambdas and assignment expressions
are unsupported. Type unions require deferred annotations. Attribute/subscript type lookups require deferred annotations
(`from __future__ import annotations`) or unshadowed standard-library bindings.
This keeps signature evaluation from invoking an unknown factory or type hook.

Package-form unittest commands initialize imports in `scripts/__init__.py`; test
modules contain declarations rather than executable path setup. The package
initializer is CI-trusted. This is a static declaration contract, not a Python
sandbox or a replacement for executing the tests and comparing their populations.

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

`scripts/ci-test-policy.json` is version 1, with `approval_records`,
`expected_skips` and `deselections`. Each approval record has an `approver`, ISO
calendar `date`, owning `tier` and GitHub comment `link`. There is at most one record
per tier. Exceptions are active only when their tier has a record; entries for
other tiers remain proposed and inactive, so host approval cannot activate unit
or UI exceptions. Records are historical metadata, not approval authentication
or authorization for later entries/heads; the trusted caller still selects policy
using the admitted base and exact-head approval.
Policy approval is a maintainer gate; agents must not perform it.
Proposed entries never authorize passing exceptions in the verdict library.
An optional `proposed` section contains `expected_skips` and `deselections` with the
same entry grammar. Its lists are validated but never participate in the active
verdict, even when that tier has an approval record or the exact head is approved.
Approval requires explicitly promoting the granted entries
to the active lists; an approval record does not move proposals automatically.

When adding a test that needs a skip or deselection, include the policy entry in
the same PR as the test. Record its tier, environment and exact reason, and the
other owning tier for a deselection. This is a CI-trusted policy change: the
maintainer must approve the PR's exact head SHA before candidate exceptions can
apply in the trusted verdict, and a later push requires fresh approval. Keep existing
tier records when proposing exceptions in another tier: the trusted verdict keeps
using the admitted base policy until the exact head is approved. Candidate host checks read their
own policy and may pass with a new entry before approval; that result is
informational. Approval covers only the registered tier/environment: host approval
does not authorize unit, UI or other tier entries. Each tier needs its own measured
identities/reasons and exact-head policy approval. The test must still meet [TESTING section 4](TESTING.md#4-when-a-test-may-skip);
policy approval does not excuse a product failure or missing compilation.

Expected-skip entries contain `kind`, `key_pattern`, exact `dimensions`, `tier`,
`environment` and exact `reason`. Patterns use case-sensitive shell glob matching
on the whole function key. Exactly one rule must match. Matching a reason alone
does not excuse a skip. A matching skip is reported in `expected_skips` and allows
"passed with N expected skips"; a matching test that executes is a failure.
Only a fully accounted unverified result explained by matching skips can pass.
Infrastructure failures and missing results cannot be explained by skip policy.

Reviewed screenshot calibration requires an external, human-reviewed corpus.
Policy entries should name methods individually so adding a test cannot silently
register a new exception through a class wildcard.
Host checks strip `STRICT_E2E_REVIEWED_SCREENSHOTS`, so this environment remains
`hermetic` even when the caller has configured external captures. Run the
[reviewed screenshot calibration](TESTING.md#optional-reviewed-screenshot-calibration-dataset)
directly with unittest to use that corpus.

Deselections contain exact `identity`, `tier`, `environment`, `reason` and
`owning_tier`. The owner must be another tier. A deselected identity must still be
compiled, must not be observed, and must be reported with the policy's exact
reason and owner. A policy-required deselection that executes or is omitted fails.
Measure fixture coverage and the owning tier before proposing a deselection.

`evaluate_population(summary, expected, policy, environment=...)` requires the
`environment` keyword argument and returns
`status`, all `errors`, expected skip identities, deselections, missing compiled
and missing executed identities. Declared and compiled function populations must
equal the independently supplied expected population. Xcode unit keys normalize
their bundle prefix, raw identifier quoting and argument-label signature to static
Swift function keys only for coverage comparisons; original result and policy
identities remain intact. Swift parameter rows can expand a compiled function,
but every explicitly compiled parameter must have its own observation
or approved deselection. Extra observations, failed/cancelled/incomplete results,
human-review outcomes and unregistered retries are failures. Retry eligibility
and the retry executor are described in [Testing conventions](TESTING.md#known-flaky-registry-and-listed-only-retries).
`flaky-passed` is accepted only with the caller-supplied trusted base registry,
an exact active identity/scope, and the summary contract's preserved failed/pass
attempt pair. Without that registry it remains a failure.

The host producer records static Python declarations, dynamic discovery and
observations separately, hashes this policy, and evaluates their equality. Only
fully accounted exceptions matching a proposed policy retain exit 0 / `unverified`
with `policy-proposed`; unexpected skips and missing identities return exit 1.
Approved exceptions can produce `passed`.
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
path affect the app. CI-trusted paths are `.github/workflows/**`, `.github/actions/**`, `.swift-format`,
`scripts/ci_*.py`, every script invoked by `run_host_checks.HOST_CHECKS` or a workflow, and the CI
entry points, policy/data/pins and their own tests listed in
`scripts/ci-classification.json`. This includes test conventions, release guards,
localization catalog/usage, Python prerequisites and workflow-policy checks, plus
`test_conventions_allowlist.json`, `scripts/test_timeout_allowlist.json`, `check_all.sh`, the privacy gate/trusted runner,
their tests and privacy fixture modules, and `scripts/__init__.py`. It also covers
the source-free consumer's copied `run_offline_unit_tests.py` and its test modules.
Every timeout-allowlist edit is CI-changing, including migration removals; this
keeps newly admitted raw waits behind exact-head maintainer approval.
The UI shard manifest `scripts/ci-ui-shards.json` and both default plans,
`immichSlides-iOS.xctestplan` and `immichSlides-tvOS.xctestplan`, are CI-trusted.
Editing default plans or renaming/removing manifest-named classes requires
maintainer approval of that exact head; update the manifest when a shard becomes empty.
The strict tracer's `run_strict_ci_tracer.py` and `strict-tracer.json` are CI inputs;
its warm-build dependencies and tests belong to the same import closure.
The recursive local-import closure is trusted too: the excluded-UI check imports
access-lifecycle and strict runners, so their contracts, fixture support and own
tests are CI inputs. The formatting policy changes the lint verdict.
Regressions derive every `HOST_CHECKS` and workflow `scripts/...` reference (expanding
workflow path globs to actual files),
local-action `uses: ./...` paths, bare filenames in workflow `for file in ...; do` toolsets, and the recursive
local-import closure of every trusted Python script. They require CI-trusted
coverage; every exact classification entry must exist.
Other product/runner tests and scripts outside that closure, `AGENTS.md` and `CLAUDE.md` are not CI-trusted;
adding or removing an ordinary test does not itself require CI-head approval.
Invalid relative paths and empty changed-path lists fail closed. A caller must
explicitly handle a proven zero-diff case; an empty or unavailable diff cannot
authorize `not-applicable`. There is no comment-only classification.

`evaluate_gate` consumes the required job artifacts and independent static
`expected`, `admission_identity`, `required_jobs`, `base_policy`, `environment`
and trusted classification booleans. Every required-job object has `tier`, `job`,
`shard`, `run_id`, `attempt`, independently verified `status` and `conclusion`,
an explicitly supported `workflow_paths` list, and
independently derived `expected={"tree_sha": admitted_tree_sha, "identities":
job_identities}`. The overall `expected` uses the same record shape. Both must
match `admission_identity.tree_sha`; missing, malformed, duplicate or later-main
population records fail validation. Their identity union must equal
the overall expected population; one shard cannot cover an omission in another.
Every artifact must match the admitted run identity, job, run, attempt and workflow;
every required job must be independently verified as `status="completed"` and
`conclusion="success"`. A passing artifact cannot excuse a failed, cancelled,
timed-out, skipped or incomplete job, including failure after artifact upload.
Missing, duplicate or unexpected jobs fail. Each job accounts for its compiled
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
the independently computed removal report. Approval provenance and authentication
are not implemented here.

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
The [trusted publisher](CI_PUBLISHER.md) supplies these libraries with admitted
inputs and publishes through the CI App; candidate host output remains informational.
