"""Guard static inventory against silent loss and execution of candidate code."""

import unittest

from ci_summary import ContractError, observation, test_identity
from ci_population import python_identities, swift_identities, ui_identities
from ci_verdict import evaluate_population
from test_ci_summary import valid_summary


class StaticPopulationTests(unittest.TestCase):
    def test_python_mixins_aliases_and_overrides_match_discovery_without_importing(self):
        files = {
            "cases": "def must_not_execute():\n raise RuntimeError('must not execute')\nclass Root:\n def test_inherited(self): pass\n"
                     "class Mixin(Root):\n def test_shared(self): pass\n",
            "test_sample": "import unittest as ut\nfrom cases import Mixin as Cases\n"
                           "class Tests(Cases, ut.TestCase):\n def test_inherited(self): pass\n"
                           " def test_local(self): pass\n"
                           " def helper(self):\n  class Hidden(ut.TestCase):\n   def test_hidden(self): pass\n",
        }
        self.assertEqual(python_identities(files), [
            test_identity("python", "test_sample.Tests.test_inherited"),
            test_identity("python", "test_sample.Tests.test_local"),
            test_identity("python", "test_sample.Tests.test_shared"),
        ])

    def test_imported_test_classes_use_defining_module_and_diamond_mro(self):
        files = {
            "support": "from unittest import TestCase as TC\nclass Root:\n def test_a(self): pass\n"
                       "class Left(Root): pass\nclass Right(Root):\n def test_a(self): pass\n"
                       "class Tests(Left, Right, TC):\n def test_b(self): pass\n",
            "test_entry": "from support import Tests as Imported",
        }
        self.assertEqual(python_identities(files), [test_identity("python", "support.Tests.test_a"),
                                                  test_identity("python", "support.Tests.test_b")])

    def test_assignment_base_aliases_are_outside_the_allowed_grammar(self):
        files = {"support": "from unittest import TestCase\nBase = TestCase\nAlias = Base\n",
                 "test_entry": "from support import Alias\nLocal = Alias\n"
                               "class Tests(Local):\n def test_present(self): pass\n"}
        with self.assertRaisesRegex(ContractError, r"(?:support|test_entry)\.py:\d+:"):
            python_identities(files)

    def test_non_test_helper_bases_do_not_obscure_discovered_tests(self):
        files = {"helpers": "from typing import Generic, TypeVar\nfrom collections import namedtuple\n"
                            "from external import *\nif enabled:\n class Conditional: pass\n"
                            "VALUE = factory().value\n"
                            "T = TypeVar('T')\nclass Box(Generic[T]): pass\n"
                            "class Row(namedtuple('Row', 'value')): pass\n",
                 "test_entry": "from helpers import Box, Row\nfrom unittest import TestCase\n"
                               "class Tests(TestCase):\n def test_present(self): pass\n"}
        self.assertEqual(python_identities(files), [test_identity("python", "test_entry.Tests.test_present")])

        files["test_entry"] += ("from enum import Enum\nfrom typing import NamedTuple, Generic\n"
                                "from http.server import BaseHTTPRequestHandler\n"
                                "class Error(ValueError): pass\nclass Failure(Exception): pass\n"
                                "class Color(Enum): pass\nclass LocalRow(NamedTuple): pass\n"
                                "class LocalBox(Generic): pass\nclass Handler(BaseHTTPRequestHandler): pass\n")
        self.assertEqual(python_identities(files), [test_identity("python", "test_entry.Tests.test_present")])

    def test_dynamic_or_unresolved_python_discovery_fails_closed(self):
        sources = [
            "class Tests(Missing):\n def test_a(self): pass",
            "import unittest\nBase = factory(unittest.TestCase)\nclass Tests(Base):\n def test_a(self): pass",
            "import unittest\nBase = unittest.TestCase\nBase = factory()\nclass Tests(Base): pass",
            "import unittest\nclass Tests(Missing, unittest.TestCase):\n def test_a(self): pass",
            "import unittest\ndef load_tests(loader, tests, pattern): return tests",
            "import unittest\nif enabled:\n class Tests(unittest.TestCase):\n  def test_a(self): pass",
            "from third_party import Base\nclass Helper(Base): pass",
            "ValueError = factory()\nclass Helper(ValueError): pass",
            "def Exception(): pass\nclass Helper(Exception): pass",
        ]
        for source in sources:
            with self.subTest(source=source), self.assertRaises(ContractError):
                python_identities({"test_sample": source})

    def test_conditional_imports_and_base_assignments_cannot_hide_test_classes(self):
        support = "from unittest import TestCase\nclass Imported(TestCase):\n def test_hidden(self): pass\n"
        always = "import unittest\nclass Always(unittest.TestCase):\n def test_always(self): pass\n"
        for binding in ("if True:\n from support import Imported",
                        "try:\n from support import Imported\nexcept ImportError:\n pass",
                        "if True:\n import support as cases",
                        "if True:\n Alias = support.Imported",
                        "if True:\n Base = None\nclass Tests(Base): pass",
                        "for Imported in support.cases:\n pass",
                        "with context() as Imported:\n pass",
                        "if (Alias := support.Imported):\n pass",
                        "try:\n Base = unittest.TestCase\nexcept Exception:\n Base = object\nclass Tests(Base): pass",
                        "if True:\n unittest.TestCase = object"):
            with self.subTest(binding=binding), self.assertRaisesRegex(ContractError, r"test_entry\.py:\d+:"):
                python_identities({"support": support, "test_entry": always + binding})
        # Function-local fixtures and unconditional data configuration do not change discovery.
        self.assertEqual(python_identities({"test_entry": always + "TIMEOUT = 5\n"
                                           "def helper():\n if True:\n  from support import Imported"}),
                         [test_identity("python", "test_entry.Always.test_always")])

    def test_rebinding_base_names_before_or_after_class_definition_is_rejected(self):
        for source in (
                "Base = unittest.TestCase\nclass Tests(Base): pass\nBase = object",
                "Base = object\nBase = unittest.TestCase\nclass Tests(Base): pass",
                "Base = unittest.TestCase\nAlias = Base\nclass Tests(Alias): pass\nBase = object",
                "Alias = Base\nBase = unittest.TestCase\nclass Tests(Alias): pass",
                "class Base(unittest.TestCase): pass\nclass Tests(Base): pass\nBase = object",
                "class Tests(unittest.TestCase): pass\nunittest = replacement",
                "Base = unittest.TestCase\nclass Tests(Base): pass\ndel Base",
                "Base = unittest.TestCase\nclass Tests(Base): pass\nBase += other",
                "class Tests(Base): pass\nBase = unittest.TestCase"):
            with self.subTest(source=source), self.assertRaisesRegex(ContractError, r"test_entry\.py:\d+:"):
                python_identities({"test_entry": "import unittest\n" + source})

    def test_saved_class_aliases_and_provider_rebindings_fail_with_file_and_line(self):
        provider = "from unittest import TestCase\nclass Hidden(TestCase):\n def test_hidden(self): pass\n"
        for files in (
                {"support": provider, "test_entry": "from support import Hidden\nSaved = Hidden\nHidden = None"},
                {"support": provider + "Saved = Hidden\nHidden = None\n", "test_entry": "from support import Saved"},
                {"support": provider + "Hidden = None\n", "test_entry": "from support import Hidden"}):
            with self.subTest(files=files), self.assertRaisesRegex(ContractError, r"(?:test_entry|support)\.py:\d+:"):
                python_identities(files)

    def test_test_member_assignments_and_other_unsupported_grammar_fail_closed(self):
        for member in ("if True:\n  test_hidden = helper", "try:\n  test_hidden = helper\n except Exception:\n  pass",
                       "test_hidden = helper", "test_hidden = None", "del test_hidden", "test_hidden += helper",
                       "if True:\n  del test_hidden", "if True:\n  def test_hidden(self): pass",
                       "Alias = unittest.TestCase", "helper()", "@replace\n def test_hidden(self): pass",
                       "def helper(self, marker=replace()): pass", "def helper(self, marker=lambda: None): pass",
                       "def helper(self, marker: replace()): pass", "def helper(self) -> replace(): pass",
                       "def helper(self, marker: factory[0]): pass", "def helper(self, marker: factory | object): pass",
                       "marker: replace() = None", "marker: factory[0]", "VALUES = set()",
                       "def classmethod(function): return function\n @classmethod\n def test_hidden(self): pass"):
            source = "import unittest\nclass Tests(unittest.TestCase):\n def helper(self): pass\n " + member
            with self.subTest(member=member), self.assertRaisesRegex(ContractError, r"test_entry\.py:\d+:"):
                python_identities({"test_entry": source})
        for declaration in ("@replace\nclass Tests(unittest.TestCase): pass",
                            "class Tests(unittest.TestCase, metaclass=replace): pass",
                            "Saved = factory()", "marker: replace() = None", "from support import *", "exec(source)",
                            "if True:\n TIMEOUT = 5", "unittest.TestCase.test_hidden = helper",
                            "if __name__ == '__main__':\n factory().main()",
                            "def set(): return factory()\nVALUES = set()\nfrom builtins import set"):
            with self.subTest(declaration=declaration), self.assertRaisesRegex(ContractError, r"test_entry\.py:\d+:"):
                python_identities({"test_entry": "import unittest\n" + declaration})

    def test_swift_suites_extensions_platforms_and_parameters_keep_function_identity(self):
        files = {
            "A.swift": '@Suite(.serialized)\nstruct Tests {\n @Test(arguments: [1, 2])\n'
                       ' func `each input works`(value: Int) {}\n'
                       ' #if os(iOS)\n @Test func phone() {}\n #else\n @Test func tv() {}\n #endif\n'
                       ' let decoy = "@Test func fake() { }"\n}\n',
            "B.swift": 'extension Tests {\n @Test func extended() {}\n}\n'
                       '#if os(tvOS)\n@Suite struct TVOnly { @Test func works() {} }\n#endif',
        }
        ios = swift_identities(files, "ios")
        tvos = swift_identities(files, "tvos")
        self.assertEqual([item["key"] for item in ios], ["Tests/each input works", "Tests/extended", "Tests/phone"])
        self.assertEqual([item["key"] for item in tvos], ["TVOnly/works", "Tests/each input works", "Tests/extended", "Tests/tv"])
        self.assertTrue(all(item["dimensions"] == {"platform": "ios"} for item in ios))

    def test_swift_nested_suites_and_unknown_conditions_cannot_drop_tests(self):
        source = "@Suite struct Outer { @Suite struct Inner { @Test func works() {} } }"
        self.assertEqual(swift_identities({"A.swift": source}, "ios"),
                         [test_identity("swift", "Outer.Inner/works", platform="ios")])
        for source in ("#if UNKNOWN\n@Test func hidden() {}\n#endif", "@Test var broken = 1",
                       "@Other.Test func hidden() {}", "@Testing.Test.Extra func hidden() {}",
                       "@Testing.Test var broken = 1", "@Testing.Suite actor Unsupported {}",
                       "extension Missing { @Test func hidden() {} }", "#if os(iOS)\n@Test func a() {}"):
            with self.subTest(source=source), self.assertRaises(ContractError):
                swift_identities({"A.swift": source}, "ios")

    def test_ui_inventory_reuses_platform_and_extension_rules(self):
        files = {"A.swift": "#if os(iOS)\nfinal class Tests: XCTestCase { func testA() {} }\n#endif",
                 "B.swift": "extension Tests { func testExtended() {} }"}
        self.assertEqual(ui_identities(files, "ios"), [
            test_identity("ui", "Tests/testA", platform="ios"),
            test_identity("ui", "Tests/testExtended", platform="ios"),
        ])
        self.assertEqual(ui_identities(files, "tvos"), [])

    def test_swift_unit_inventory_includes_xctest_classes_beside_testing_suites(self):
        files = {"A.swift": "@Suite struct Modern { @Test func testModern() {} }\n"
                 "final class Legacy: XCTest.XCTestCase { func testShared() {}\n"
                 "#if os(iOS)\nfunc testPhone() {}\n#endif\n}",
                 "B.swift": "extension Legacy { func testExtension() {} }"}
        self.assertEqual([entry["key"] for entry in swift_identities(files, "ios")],
                         ["Legacy/testExtension", "Legacy/testPhone", "Legacy/testShared", "Modern/testModern"])
        self.assertTrue(all(entry["kind"] == "swift" for entry in swift_identities(files, "tvos")))
        self.assertEqual([entry["key"] for entry in swift_identities(files, "tvos")],
                         ["Legacy/testExtension", "Legacy/testShared", "Modern/testModern"])

    def test_indirect_xctest_inheritance_is_explicitly_rejected_in_both_targets(self):
        files = {"Base.swift": "class Base: XCTestCase { func testBase() {} }",
                 "Child.swift": "class Middle: Base {}\nclass Child: Middle { func testChild() {} }"}
        for inventory in (swift_identities, ui_identities):
            with self.subTest(inventory=inventory.__name__), self.assertRaisesRegex(
                    ContractError, "indirect XCTestCase inheritance"):
                inventory(files, "ios")
            for source in ("class Generic<T>: XCTestCase { func testHidden() {} }",
                           "typealias Base = XCTestCase\nclass Child: Base { func testHidden() {} }"):
                with self.subTest(inventory=inventory.__name__, source=source), self.assertRaisesRegex(
                        ContractError, "XCTestCase inheritance"):
                    inventory({"Unsupported.swift": source}, "ios")

    def test_missing_compilation_of_conditional_xctest_or_qualified_attributes_is_red(self):
        conditional = "class Always: XCTestCase { func testAlways() {} }\n" \
                      "#if os(iOS)\nclass Tests: XCTestCase { func testPhone() {} }\n" \
                      "#else\nclass Tests: XCTestCase { func testTV() {} }\n#endif"
        qualified = "@Test func always() {}\n@Testing.Suite struct Tests {\n" \
                    "@Testing.Test func mustRun() {}\n}"
        for inventory, source, keys in (
                (swift_identities, conditional, {"ios": "Tests/testPhone", "tvos": "Tests/testTV"}),
                (ui_identities, conditional, {"ios": "Tests/testPhone", "tvos": "Tests/testTV"}),
                (swift_identities, qualified, {"ios": "Tests/mustRun", "tvos": "Tests/mustRun"})):
            for platform, key in keys.items():
                with self.subTest(inventory=inventory.__name__, platform=platform, key=key):
                    kind = "ui" if inventory is ui_identities else "swift"
                    missing = test_identity(kind, key, platform=platform)
                    expected = inventory({"Tests.swift": source}, platform)
                    self.assertIn(missing, expected)
                    compiled = [identity for identity in expected if identity != missing]
                    self.assertTrue(compiled, "retain a passing test so omissions cannot hide behind an empty suite")
                    summary = valid_summary()
                    summary["population"].update(declared=expected, compiled=compiled,
                                                 observed=[observation(identity, "passed", 0) for identity in compiled])
                    verdict = evaluate_population(summary, expected,
                        {"schema_version": 1, "approval_state": "approved", "expected_skips": [], "deselections": []},
                        environment="hermetic")
                    self.assertEqual(verdict["status"], "failed")
                    self.assertEqual(verdict["missing_compiled"], [missing])


if __name__ == "__main__":
    unittest.main()
