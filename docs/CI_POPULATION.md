# Static population and verdict policy

The pure-Python libraries use the [summary contract](CI_SUMMARY.md).
Host and unit producers compare static declarations, compiled enumeration and
execution. These libraries do not publish statuses, call GitHub or import source
maps. There is no separate publisher or CI approval step.

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
Platforms are `ios` and `tvos`, stored in the identity's `platform` dimension.
For unit input include every Swift file in `immichSlidesTests`. Target membership is a caller
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

## Expected skips and complete execution

`scripts/ci-test-policy.json` records exact unit skip identities, dimensions,
tier, environment and emitted reason. Historical `approval_records` activate
their tier's entries in the parser; they are metadata, not authentication or a
per-push CI approval requirement. The optional `proposed` lists remain inactive.
The current policy has no deselections.

Every observed skip must match exactly one active rule. A registered skip that
executes, an unexpected reason/platform, missing compilation, duplicate/extra
observations or missing execution fails coverage. Hermetic Live/Evidence skips
do not establish those capabilities. No live nightly exists.

`evaluate_population` compares declared/compiled/observed function sets with an
independent expected population. Swift parameter rows retain their full official
identity and outcome; normalization affects only function coverage comparisons.
All explicitly compiled parameters need observations. Failed, cancelled,
incomplete and unregistered retry outcomes cannot pass.
A proposed-only exception remains unverified, never a passing test result.

Host records preserve static Python declarations, unittest discovery and per-test
observations. Invalid population records `population-invalid` and retains a failed
verdict while still attempting host checks. Coverage/policy diagnostics are not
infrastructure health counts. See [host records](CI_SUMMARY.md) and
[source-free units](CI_UNIT_TESTS.md).

## Classification

`scripts/ci-classification.json` allowlists App-unaffected paths.
The base-owned classifier also checks static build membership and both diff
sides; unknown paths and CI-trusted inputs remain App-affecting.
Host checks always run. On App-unaffected PRs only, both platform build/unit
paths can be not applicable. Main pushes run both platforms.
No classification selects PR UI execution. PR builds compile every scheme
testable, including the UI target; unit jobs execute only the unit target.

Exact policy paths must exist. Workflow/host entry points and their import/test
closure, schemes/plans, pins and scanner policies remain CI-trusted.
The classification is consumed by `ci_gate.py`; jobs report their own results.

## Verification commands

```bash
python3 -B -m unittest discover -s scripts -p test_ci_population.py
python3 -B -m unittest discover -s scripts -p test_ci_verdict.py
scripts/check_all.sh
```
