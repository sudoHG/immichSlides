"""Guard static inventory against silent loss and execution of candidate code."""

import unittest

from ci_summary import ContractError, test_identity
from ci_population import python_identities, swift_identities, ui_identities, removed_tests


class StaticPopulationTests(unittest.TestCase):
    def test_python_mixins_aliases_and_overrides_match_discovery_without_importing(self):
        files = {
            "cases": "raise RuntimeError('must not execute')\nclass Root:\n def test_inherited(self): pass\n"
                     "class Mixin(Root):\n def test_shared(self): pass\n",
            "test_sample": "import unittest as ut\nfrom cases import Mixin as Cases\n"
                           "class Tests(Cases, ut.TestCase):\n test_inherited = None\n"
                           " def test_local(self): pass\n"
                           " def helper(self):\n  class Hidden(ut.TestCase):\n   def test_hidden(self): pass\n",
        }
        self.assertEqual(python_identities(files), [
            test_identity("python", "test_sample.Tests.test_local"),
            test_identity("python", "test_sample.Tests.test_shared"),
        ])

    def test_imported_test_classes_use_defining_module_and_diamond_mro(self):
        files = {
            "support": "from unittest import TestCase as TC\nclass Root:\n def test_a(self): pass\n"
                       "class Left(Root): pass\nclass Right(Root):\n test_a = None\n"
                       "class Tests(Left, Right, TC):\n def test_b(self): pass\n",
            "test_entry": "from support import Tests as Imported",
        }
        self.assertEqual(python_identities(files), [test_identity("python", "support.Tests.test_b")])

    def test_assignment_base_aliases_cannot_silently_drop_test_classes(self):
        files = {"support": "from unittest import TestCase\nBase = TestCase\nAlias = Base\n",
                 "test_entry": "from support import Alias\nLocal = Alias\n"
                               "class Tests(Local):\n def test_present(self): pass\n"}
        self.assertEqual(python_identities(files), [test_identity("python", "test_entry.Tests.test_present")])

    def test_non_test_helper_bases_do_not_obscure_discovered_tests(self):
        files = {"helpers": "from typing import Generic, TypeVar\nfrom collections import namedtuple\n"
                            "from external import *\nif enabled:\n class Conditional: pass\n"
                            "VALUE = factory().value\n"
                            "T = TypeVar('T')\nclass Box(Generic[T]): pass\n"
                            "class Row(namedtuple('Row', 'value')): pass\n",
                 "test_entry": "from helpers import Box, Row\nfrom unittest import TestCase\n"
                               "class Tests(TestCase):\n def test_present(self): pass\n"}
        self.assertEqual(python_identities(files), [test_identity("python", "test_entry.Tests.test_present")])

    def test_dynamic_or_unresolved_python_discovery_fails_closed(self):
        sources = [
            "class Tests(Missing):\n def test_a(self): pass",
            "import unittest\nBase = factory(unittest.TestCase)\nclass Tests(Base):\n def test_a(self): pass",
            "import unittest\nBase = unittest.TestCase\nBase = factory()\nclass Tests(Base): pass",
            "import unittest\nclass Tests(Missing, unittest.TestCase):\n def test_a(self): pass",
            "import unittest\ndef load_tests(loader, tests, pattern): return tests",
            "import unittest\nif enabled:\n class Tests(unittest.TestCase):\n  def test_a(self): pass",
        ]
        for source in sources:
            with self.subTest(source=source), self.assertRaises(ContractError):
                python_identities({"test_sample": source})

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
                 "final class Legacy: XCTestCase { func testShared() {}\n"
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

    def test_removed_report_uses_pr_base_and_tested_tree_without_later_main(self):
        base = python_identities({"test_a": "import unittest\nclass T(unittest.TestCase):\n def test_old(self): pass"})
        tested = python_identities({"test_a": "import unittest\nclass T(unittest.TestCase):\n def test_new(self): pass"})
        self.assertEqual(removed_tests(base, tested), base)


if __name__ == "__main__":
    unittest.main()
