import sys
import unittest
import copy
import json
import tempfile
from unittest.mock import patch
from pathlib import Path


import check_test_conventions as conv

REPO_ROOT = Path(__file__).resolve().parent.parent


def rules(violations):
    return [v.rule for v in violations]


class NavigationWaitTests(unittest.TestCase):
    def test_navigation_waits_reject_refreshed_guards_and_blocking_optional_probes(self):
        cases = (
            ('while pending { let wait = TestWait.hangGuard() }', 'hang-guard-refresh'),
            ('Wait.until(timeout: limit) { TestWait.hangGuard().transaction().probe { ready } }', 'hang-guard-refresh'),
            ('step.until { let wait = TestWait.hangGuard(); return ready }', 'hang-guard-refresh'),
            ('waitUntil(timeout: limit) { let wait = TestWait.hangGuard(); return ready }', 'hang-guard-refresh'),
            ('repeat { let wait = TestWait.hangGuard() } while pending', 'hang-guard-refresh'),
            ('if step.until { pin != nil } { unlock() }', 'hang-guard-optional'),
            ('if wait.transaction().until { pin != nil } { unlock() }', 'hang-guard-optional'),
            ('step.probe { button.waitForExistence(timeout: 60) }', 'hang-guard-probe'),
            ('step.probe({ step.until { ready } })', 'hang-guard-probe'),
            ('step.probe { step.until { ready } }', 'hang-guard-probe'),
            ('let wait = TestWait.hangGuard(timeoutSeconds: 120)', 'hang-guard-duration'),
        )
        for source, expected in cases:
            with self.subTest(source=source):
                self.assertIn(expected, rules(conv.check_navigation_waits('immichSlidesUITests/Flow.swift', source)))
        valid = 'let wait = TestWait.hangGuard(); let step = wait.transaction(); if step.probe { pin != nil } { unlock() }; XCTAssertTrue(step.until { ready })'
        self.assertEqual([], conv.check_navigation_waits('immichSlidesUITests/Flow.swift', valid))
        valid = 'if let timeout { waitUntil(timeout: timeout, condition: condition) } else { let wait = TestWait.hangGuard() }'
        self.assertEqual([], conv.check_navigation_waits('immichSlidesUITests/Flow.swift', valid))
        focus_path = 'immichSlidesUITests/UITestSupport.swift'
        focus = ('func focusTextField() { let readiness = TestWait.hangGuard('
                 'timeoutSeconds: UITestSupportWaitTiming.elementAppearanceTimeoutSeconds) }')
        self.assertEqual([], conv.check_navigation_waits(focus_path, focus))
        for path, source in ((focus_path, focus.replace('elementAppearanceTimeoutSeconds', 'identityPollSeconds')),
                             (focus_path, focus.replace('focusTextField', 'otherNavigation')),
                             ('immichSlidesUITests/Flow.swift', focus)):
            with self.subTest(path=path, source=source):
                self.assertEqual(['hang-guard-duration'], rules(conv.check_navigation_waits(path, source)))


class ForbiddenNameTests(unittest.TestCase):
    path = "immichSlidesTests/Example.swift"

    def test_ticket_pr_in_function_name_is_reported(self):
        source = '@Test\nfunc `testPR46 startup schema`() {}\n'
        violations = conv.check_forbidden_names(self.path, source)
        self.assertEqual(["forbidden-name"], rules(violations))
        self.assertIn("ticket-pr", violations[0].detail)

    def test_clean_function_name_passes(self):
        source = '@Test\nfunc `empty selection cannot start filtered playback`() {}\n'
        self.assertEqual([], conv.check_forbidden_names(self.path, source))

    def test_s30x_ticket_in_type_name_is_reported(self):
        source = "struct S306PrivatePINInputTests {}\n"
        violations = conv.check_forbidden_names(self.path, source)
        self.assertEqual(["forbidden-name"], rules(violations))
        self.assertIn("ticket-s30x", violations[0].detail)

    def test_331_ticket_number_in_a_raw_identifier_sentence_is_reported(self):
        # A plain Swift identifier cannot contain a hyphen, so "331-<digits>" can only appear inside a
        # backtick raw-identifier sentence.
        source = '@Test\nfunc `fixes 331-759 regression in filter summary`() {}\n'
        violations = conv.check_forbidden_names(self.path, source)
        self.assertEqual(["forbidden-name"], rules(violations))
        self.assertIn("ticket-331", violations[0].detail)

    def test_phase_digit_is_reported_in_file_name(self):
        violations = conv.check_forbidden_names("immichSlidesUITests/AppStoreScreenshotPhase0UITests.swift", "")
        self.assertEqual(["forbidden-name"], rules(violations))
        self.assertIn("process-phase", violations[0].detail)

    def test_lowercase_phase_digit_is_reported(self):
        source = "struct Phase3AController {}\n"
        violations = conv.check_forbidden_names(self.path, source)
        self.assertTrue(any("process-phase" in v.detail for v in violations))

    def test_todo_digits_is_reported(self):
        source = "struct Todo11Tracker {}\n"
        violations = conv.check_forbidden_names(self.path, source)
        self.assertIn("process-todo", violations[0].detail)

    def test_n3_as_camelcase_token_is_reported(self):
        source = "func testAlbumServerN3SwitchAndImmediateDisplayPolicy() {}\n"
        violations = conv.check_forbidden_names(self.path, source)
        self.assertEqual(["forbidden-name"], rules(violations))
        self.assertIn("process-n123", violations[0].detail)

    def test_n_digit_inside_an_ordinary_word_is_not_flagged(self):
        # "N3" must be a camelCase token, not any substring; nothing here should match N1/N2/N3.
        source = "func testCredentialStoredCorrectly() {}\n"
        self.assertEqual([], conv.check_forbidden_names(self.path, source))

    def test_v1_as_camelcase_token_is_reported(self):
        source = "func testFilterSummaryV1Layout() {}\n"
        violations = conv.check_forbidden_names(self.path, source)
        self.assertIn("process-v1", violations[0].detail)

    def test_journey_followed_by_capital_is_reported(self):
        source = "struct JourneyAOnboarding {}\n"
        violations = conv.check_forbidden_names(self.path, source)
        self.assertIn("process-journey", violations[0].detail)

    def test_selfcheck_is_reported(self):
        source = "func testReduceMotionSettingRoundTripSelfCheckIOS() {}\n"
        violations = conv.check_forbidden_names(self.path, source)
        self.assertIn("process-selfcheck", violations[0].detail)

    def test_golden_either_case_is_reported(self):
        source = "struct SharedScenePlannerGoldenUnitTests {}\nstruct goldenFixtures {}\n"
        violations = conv.check_forbidden_names(self.path, source)
        self.assertEqual(2, len(violations))

    def test_red_token_and_testred_prefix_are_reported(self):
        source = "func testREDMarksAFailingCase() {}\n"
        violations = conv.check_forbidden_names(self.path, source)
        self.assertIn("process-red", violations[0].detail)

    def test_red_inside_an_ordinary_word_is_not_flagged(self):
        source = "func testCredentialIsStored() {}\n"
        self.assertEqual([], conv.check_forbidden_names(self.path, source))

    def test_forbidden_token_is_flagged_anywhere_in_the_sentence_not_only_as_a_standalone_word(self):
        # Decision: forbidden tokens are flagged wherever they occur in the name, including mid-sentence,
        # because a raw-identifier sentence can embed a ticket code anywhere ("... during Phase2 rollout").
        source = '@Test\nfunc `rollout during Phase2 keeps the previous filter`() {}\n'
        violations = conv.check_forbidden_names(self.path, source)
        self.assertEqual(["forbidden-name"], rules(violations))
        self.assertIn("process-phase", violations[0].detail)

    def test_cjk_in_function_name_is_reported(self):
        source = "func testValidatesCJK输入() {}\n"
        violations = conv.check_forbidden_names(self.path, source)
        self.assertEqual(["forbidden-name"], rules(violations))
        self.assertIn("CJK", violations[0].detail)

    def test_cjk_in_a_comment_is_not_flagged(self):
        source = "// 中文注释\nfunc testPlain() {}\n"
        self.assertEqual([], conv.check_forbidden_names(self.path, source))

    def test_forbidden_token_inside_a_string_literal_is_not_a_name_violation(self):
        source = 'let ticket = "PR46"\nfunc testPlainName() {}\n'
        self.assertEqual([], conv.check_forbidden_names(self.path, source))

    def test_forbidden_token_inside_a_comment_is_not_a_name_violation(self):
        source = "// see PR46 for context\nfunc testPlainName() {}\n"
        self.assertEqual([], conv.check_forbidden_names(self.path, source))


class DisplayNameTests(unittest.TestCase):
    path = "immichSlidesTests/Example.swift"

    def test_test_with_string_display_name_is_reported(self):
        source = '@Test("does the thing")\nfunc doesTheThing() {}\n'
        violations = conv.check_display_names(self.path, source)
        self.assertEqual(["display-name"], rules(violations))
        self.assertEqual("doesTheThing", violations[0].name)

    def test_suite_with_string_display_name_is_reported(self):
        source = '@Suite("My Suite")\nstruct MySuite {}\n'
        violations = conv.check_display_names(self.path, source)
        self.assertEqual(["display-name"], rules(violations))

    def test_display_name_followed_by_trait_is_still_reported(self):
        source = '@Test("does the thing", .timeLimit(.minutes(1)))\nfunc doesTheThing() {}\n'
        violations = conv.check_display_names(self.path, source)
        self.assertEqual(["display-name"], rules(violations))

    def test_bare_test_attribute_passes(self):
        source = "@Test\nfunc `plain sentence name`() {}\n"
        self.assertEqual([], conv.check_display_names(self.path, source))

    def test_enabled_if_trait_is_not_a_display_name(self):
        source = "@Test(.enabled(if: liveEnabled))\nfunc normalizeServerURLWorks() {}\n"
        self.assertEqual([], conv.check_display_names(self.path, source))

    def test_time_limit_trait_with_nested_parens_is_not_a_display_name(self):
        source = "@Test(.timeLimit(.minutes(1)))\nfunc `waits under a minute`() async {}\n"
        self.assertEqual([], conv.check_display_names(self.path, source))

    def test_display_name_string_in_a_comment_is_ignored(self):
        source = '// @Test("looks like a display name but is commented out")\n@Test\nfunc `real name here`() {}\n'
        self.assertEqual([], conv.check_display_names(self.path, source))


class SwiftTestingNameTests(unittest.TestCase):
    path = "immichSlidesTests/Example.swift"

    def test_plain_identifier_without_exception_is_reported(self):
        source = "@Test\nfunc doesTheThing() {}\n"
        violations = conv.check_swift_testing_names(self.path, source)
        self.assertEqual(["swift-testing-name"], rules(violations))

    def test_exception_list_entry_passes(self):
        source = "@Test\nfunc normalizeServerURLWorks() {}\n"
        self.assertEqual([], conv.check_swift_testing_names(self.path, source))
        source = "@Test(.enabled(if: externalRuntimeJSONLEnabled))\nfunc externalRuntimeJSONLPassesValidator() throws {}\n"
        self.assertEqual([], conv.check_swift_testing_names(self.path, source))

    def test_raw_identifier_sentence_passes(self):
        source = "@Test\nfunc `empty selection cannot start filtered playback`() {}\n"
        self.assertEqual([], conv.check_swift_testing_names(self.path, source))

    def test_single_word_raw_identifier_is_reported(self):
        source = "@Test\nfunc `works`() {}\n"
        violations = conv.check_swift_testing_names(self.path, source)
        self.assertEqual(["swift-testing-name"], rules(violations))
        self.assertIn("sentence", violations[0].detail)

    def test_uppercase_start_that_is_not_a_proper_noun_is_reported(self):
        source = "@Test\nfunc `Filtering keeps the previous selection`() {}\n"
        violations = conv.check_swift_testing_names(self.path, source)
        self.assertEqual(["swift-testing-name"], rules(violations))
        self.assertIn("lowercase", violations[0].detail)

    def test_acronym_start_is_treated_as_a_proper_noun(self):
        source = "@Test\nfunc `PIN entry clears after three failed attempts`() {}\n"
        self.assertEqual([], conv.check_swift_testing_names(self.path, source))

    def test_type_name_start_is_treated_as_a_proper_noun(self):
        source = "@Test\nfunc `SmartFill keeps headroom on tight crops`() {}\n"
        self.assertEqual([], conv.check_swift_testing_names(self.path, source))

    def test_suite_type_name_is_not_treated_as_a_test_function(self):
        source = "@Suite\nstruct PlaybackPoolResolverTests {}\n"
        self.assertEqual([], conv.check_swift_testing_names(self.path, source))


class SourceTextTests(unittest.TestCase):
    path = "immichSlidesTests/Example.swift"

    def test_read_project_source_identifier_is_reported(self):
        source = "let text = readProjectSource(relativePath: path)\n"
        violations = conv.check_source_text(self.path, source)
        self.assertEqual(["source-text"], rules(violations))

    def test_project_swift_source_files_identifier_is_reported(self):
        source = "for file in projectSwiftSourceFiles() { }\n"
        violations = conv.check_source_text(self.path, source)
        self.assertEqual(["source-text"], rules(violations))

    def test_contents_of_a_swift_file_is_reported(self):
        source = 'let text = try String(contentsOf: url.appendingPathComponent("Engine.swift"), encoding: .utf8)\n'
        violations = conv.check_source_text(self.path, source)
        self.assertEqual(["source-text"], rules(violations))

    def test_contents_of_file_path_ending_in_swift_is_reported(self):
        source = 'let text = try String(contentsOfFile: "immichSlides/Shared/Model/Engine.swift")\n'
        violations = conv.check_source_text(self.path, source)
        self.assertEqual(["source-text"], rules(violations))

    def test_contents_of_a_json_fixture_is_not_reported(self):
        source = 'let text = try String(contentsOf: fixtureURL.appendingPathComponent("scene.json"), encoding: .utf8)\n'
        self.assertEqual([], conv.check_source_text(self.path, source))

    def test_filepath_relative_read_of_immichslides_sources_is_reported(self):
        source = 'let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()\n' \
                 'let source = dir.appendingPathComponent("../../immichSlides/Shared/Model/Engine.swift")\n'
        violations = conv.check_source_text(self.path, source)
        self.assertEqual(["source-text"], rules(violations))

    def test_filepath_used_for_an_unrelated_fixture_path_is_not_reported(self):
        source = 'let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()\n' \
                 'let fixture = dir.appendingPathComponent("Fixtures/scene.json")\n'
        self.assertEqual([], conv.check_source_text(self.path, source))

    def test_marker_inside_a_comment_is_not_reported(self):
        source = "// readProjectSource was removed; do not reintroduce it\nlet a = 1\n"
        self.assertEqual([], conv.check_source_text(self.path, source))


class UILabelLookupTests(unittest.TestCase):
    path = "immichSlidesUITests/Example.swift"

    def test_cjk_element_subscript_is_reported(self):
        source = 'let button = app.buttons["完成"]\n'
        violations = conv.check_ui_label_lookups(self.path, source)
        self.assertEqual(["ui-label-lookup"], rules(violations))
        self.assertEqual(1, violations[0].line)

    def test_cjk_in_ternary_query_subscript_is_reported(self):
        source = 'let button = picker.buttons[singlePhoto ? "单图模式" : "智能填满"]\n'
        violations = conv.check_ui_label_lookups(self.path, source)
        self.assertEqual(["ui-label-lookup"], rules(violations))
        self.assertEqual(1, violations[0].line)

    def test_cjk_nested_in_query_subscript_expression_is_reported(self):
        source = 'let button = app.buttons[labels[isSinglePhoto ? "单图" : "智能"]]\n'
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_containing_query_chain_subscript_is_reported(self):
        source = 'let label = app.staticTexts.containing(predicate)["完成"]\n'
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_ternary_cjk_dictionary_subscript_is_ignored(self):
        source = 'let value = titles[isSinglePhoto ? "单图" : "多图"]\n'
        self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_system_ui_collection_subscripts_are_reported(self):
        for collection in ("sheets", "keys"):
            with self.subTest(collection=collection):
                source = f'let element = app.{collection}["完成"]\n'
                self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_xctest_query_variable_subscript_is_reported(self):
        source = 'let buttonQuery = app.buttons\nlet button = buttonQuery["完成"]\n'
        violations = conv.check_ui_label_lookups(self.path, source)
        self.assertEqual(["ui-label-lookup"], rules(violations))
        self.assertEqual(2, violations[0].line)

    def test_typed_xctest_query_parameter_subscript_is_reported(self):
        source = 'func find(query: XCUIElementQuery) -> XCUIElement { query["完成"] }\n'
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_cjk_matching_identifier_is_reported(self):
        source = 'let button = app.buttons.matching(identifier: "播放设置").firstMatch\n'
        violations = conv.check_ui_label_lookups(self.path, source)
        self.assertEqual(["ui-label-lookup"], rules(violations))
        self.assertIn("matching(identifier:)", violations[0].detail)

    def test_nspredicate_visible_text_comparisons_are_reported(self):
        for property_name in ("label", "title", "value"):
            with self.subTest(property_name=property_name):
                source = (
                    'let query = app.buttons.matching(NSPredicate(format: "'
                    + property_name
                    + ' CONTAINS %@", "播放设置"))\n'
                )
                violations = conv.check_ui_label_lookups(self.path, source)
                self.assertEqual(["ui-label-lookup"], rules(violations))
                self.assertIn("NSPredicate", violations[0].detail)

    def test_nspredicate_key_placeholder_for_visible_properties_is_reported(self):
        for property_name in ("label", "title", "value"):
            for format_string, arguments in (
                ("%K == %@", f'"{property_name}", "完成"'),
                ("%@ == %K", f'"完成", "{property_name}"'),
            ):
                with self.subTest(property_name=property_name, format_string=format_string):
                    source = (
                        'let query = app.buttons.matching(NSPredicate(format: "'
                        + format_string
                        + '", '
                        + arguments
                        + '))\n'
                    )
                    self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_right_hand_visible_property_is_reported_for_each_operator(self):
        operators = (
            "==", "!=", "<=", ">=", "<", ">", "BETWEEN", "CONTAINS", "BEGINSWITH", "ENDSWITH", "MATCHES",
            "LIKE", "IN", "CONTAINS[c]", "MATCHES[c]",
        )
        for property_name in ("label", "title", "value"):
            for operator in operators:
                with self.subTest(property_name=property_name, operator=operator):
                    for format_string, arguments in (
                        (f"%@ {operator} {property_name}", '"完成"'),
                        (f"%K {operator} %@", f'"{property_name}", "完成"'),
                        (f"%@ {operator} %K", f'"完成", "{property_name}"'),
                    ):
                        with self.subTest(format_string=format_string):
                            source = (
                                'let query = app.buttons.matching(NSPredicate(format: "'
                                + format_string
                                + '", '
                                + arguments
                                + '))\n'
                            )
                            self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_key_placeholder_order_in_compound_format_is_preserved(self):
        source = (
            'let query = NSPredicate(format: "%@ == identifier AND %K == %@", '
            '"unused", "title", "完成")\n'
        )
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_argument_array_forward_visible_comparisons_are_reported(self):
        for property_name in ("label", "title", "value"):
            for operator in ("==", "!=", "<=", ">=", "<", ">", "BETWEEN", "CONTAINS", "BEGINSWITH",
                             "ENDSWITH", "MATCHES", "LIKE", "IN", "CONTAINS[c]", "MATCHES[c]"):
                with self.subTest(property_name=property_name, operator=operator):
                    source = (
                        f'let query = app.buttons.matching(NSPredicate(format: "%K {operator} %@", '
                        f'argumentArray: ["{property_name}", "完成"]))\n'
                    )
                    self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_argument_array_reversed_visible_comparisons_are_reported(self):
        for property_name in ("label", "title", "value"):
            for operator in ("==", "!=", "<=", ">=", "<", ">", "BETWEEN", "CONTAINS", "BEGINSWITH",
                             "ENDSWITH", "MATCHES", "LIKE", "IN", "CONTAINS[c]", "MATCHES[c]"):
                with self.subTest(property_name=property_name, operator=operator):
                    source = (
                        f'let query = app.buttons.matching(NSPredicate(format: "%@ {operator} %K", '
                        f'argumentArray: ["完成", "{property_name}"]))\n'
                    )
                    self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_argument_array_identifier_key_is_not_reported(self):
        for source in (
            'let query = NSPredicate(format: "%K == %@", argumentArray: ["identifier", "完成"])\n',
            'let query = NSPredicate(format: "%@ == %K", argumentArray: ["完成", "identifier"])\n',
        ):
            with self.subTest(source=source):
                self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_nspredicate_argument_array_preserves_nested_arguments_and_comments(self):
        source = (
            'let query = NSPredicate(format: "%@ == identifier AND %K IN %@",\n'
            '    argumentArray: [\n'
            '        ["unused", "values"], /* the first substitution is one argument */\n'
            '        "label", ["完成", "取消"],\n'
            '    ])\n'
        )
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_compound_comparisons_keep_cjk_with_their_own_attribute(self):
        for property_name in ("label", "title", "value"):
            for is_reversed in (False, True):
                for uses_argument_array in (False, True):
                    for nested_values in (False, True):
                        for cjk_attribute in ("identifier", property_name):
                            with self.subTest(property_name=property_name, is_reversed=is_reversed,
                                              uses_argument_array=uses_argument_array, nested_values=nested_values,
                                              cjk_attribute=cjk_attribute):
                                values = ["完成", "Done"] if cjk_attribute == "identifier" else ["Done", "完成"]
                                arguments = []
                                for key, value in zip(("identifier", property_name), values):
                                    value_expression = f'["{value}", ["Other"]]' if nested_values else f'"{value}"'
                                    pair = [value_expression, f'"{key}"'] if is_reversed else [f'"{key}"', value_expression]
                                    arguments.extend(pair)
                                operator = "CONTAINS" if is_reversed and nested_values else "IN" if nested_values else "=="
                                format_text = (
                                    f"%@ {operator} %K AND %@ {operator} %K" if is_reversed
                                    else f"%K {operator} %@ AND %K {operator} %@"
                                )
                                joined_arguments = ", ".join(arguments)
                                substitutions = f"argumentArray: [{joined_arguments}]" if uses_argument_array else joined_arguments
                                source = f'let query = NSPredicate(format: "{format_text}", {substitutions})\n'
                                expected = [] if cjk_attribute == "identifier" else ["ui-label-lookup"]
                                self.assertEqual(expected, rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_literal_compound_comparisons_do_not_cross_attributes(self):
        for source, expected in (
            ('let query = NSPredicate(format: "identifier == \'完成\' AND label == \'Done\'")\n', []),
            ('let query = NSPredicate(format: "\'完成\' == identifier OR \'Done\' == title")\n', []),
            ('let query = NSPredicate(format: "identifier == \'Done\' AND value == \'完成\'")\n', ["ui-label-lookup"]),
            ('let query = NSPredicate(format: "\'Done\' == identifier OR \'完成\' == label")\n', ["ui-label-lookup"]),
            ('let query = NSPredicate(format: "%@ == \'label\' AND identifier == %@", "完成", "Done")\n', []),
        ):
            with self.subTest(source=source):
                self.assertEqual(expected, rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_symbolic_operator_modifiers_work_in_both_directions(self):
        operators = tuple(f"{symbol}[{options}]" for symbol in ("==", "!=", "<", "<=", ">", ">=")
                          for options in ("c", "d", "cd"))
        for operator in operators:
            for property_name in ("label", "title", "value"):
                for is_reversed in (False, True):
                    for uses_argument_array in (False, True):
                        with self.subTest(operator=operator, property_name=property_name, is_reversed=is_reversed,
                                          uses_argument_array=uses_argument_array):
                            format_text = f"%@ {operator} %K" if is_reversed else f"%K {operator} %@"
                            arguments = f'"完成", "{property_name}"' if is_reversed else f'"{property_name}", "完成"'
                            substitutions = f"argumentArray: [{arguments}]" if uses_argument_array else arguments
                            source = f'let query = NSPredicate(format: "{format_text}", {substitutions})\n'
                            self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_modified_identifier_comparisons_are_not_reported(self):
        for operator in ("==[c]", "==[d]", "==[cd]", "!=[c]", "!=[d]", "!=[cd]"):
            for source in (
                f'let query = NSPredicate(format: "identifier {operator} %@", "完成")\n',
                f'let query = NSPredicate(format: "%@ {operator} identifier", "完成")\n',
                f'let query = NSPredicate(format: "%K {operator} %@", "identifier", "完成")\n',
                f'let query = NSPredicate(format: "%@ {operator} %K", "完成", "identifier")\n',
                f'let query = NSPredicate(format: "%K {operator} %@", argumentArray: ["identifier", "完成"])\n',
                f'let query = NSPredicate(format: "%@ {operator} %K", argumentArray: ["完成", "identifier"])\n',
            ):
                with self.subTest(source=source):
                    self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_nspredicate_grouped_operands_keep_each_comparison_separate(self):
        for source, expected in (
            ('let query = NSPredicate(format: "(identifier IN {\'完成\', \'取消\'}) AND (label == \'Done\')")\n', []),
            ('let query = NSPredicate(format: "{\'完成\', \'取消\'} CONTAINS identifier OR (\'Done\' == title)")\n', []),
            ('let query = NSPredicate(format: "(label) IN {\'Done\', \'完成\'}")\n', ["ui-label-lookup"]),
            ('let query = NSPredicate(format: "{\'Done\', \'完成\'} CONTAINS (value)")\n', ["ui-label-lookup"]),
            (r'let query = NSPredicate(format: "identifier == \"完成\" AND label == \"Done\"")' + '\n', []),
            (r'let query = NSPredicate(format: "identifier == \"Done\" AND label == \"完成\"")' + '\n', ["ui-label-lookup"]),
        ):
            with self.subTest(source=source):
                self.assertEqual(expected, rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_positional_placeholders_keep_operand_associations(self):
        for format_text, arguments, expected in (
            ("%1$K == %2$@ AND %3$K == %4$@", '"identifier", "完成", "label", "Done"', []),
            ("%4$@ == %3$K AND %2$@ == %1$K", '"identifier", "完成", "label", "Done"', []),
            ("%4$@ == %3$K AND %2$@ == %1$K", '"identifier", "Done", "label", "完成"', ["ui-label-lookup"]),
        ):
            for substitutions in (arguments, f"argumentArray: [{arguments}]"):
                with self.subTest(format_text=format_text, substitutions=substitutions):
                    source = f'let query = NSPredicate(format: "{format_text}", {substitutions})\n'
                    self.assertEqual(expected, rules(conv.check_ui_label_lookups(self.path, source)))

    def test_nspredicate_identifier_keypaths_do_not_look_like_visible_properties(self):
        for source in (
            'let query = app.buttons.matching(NSPredicate(format: "identifier == %@", "完成"))\n',
            'let query = app.buttons.matching(NSPredicate(format: "%K == %@", "identifier", "完成"))\n',
            'let query = app.buttons.matching(NSPredicate(format: "%@ == identifier", "完成"))\n',
            (
                'let query = app.buttons.matching(NSPredicate(format: "%K == %@ AND %K == %@", '
                '"identifier", "label", "identifier", "完成"))\n'
            ),
        ):
            with self.subTest(source=source):
                self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_nspredicate_quoted_label_value_is_not_mistaken_for_key_placeholder(self):
        source = (
            'let query = app.buttons.matching(NSPredicate(format: "%K == %@ AND identifier == %@", '
            '"identifier", "label", "完成"))\n'
        )
        self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_nspredicate_regex_comparison_with_embedded_cjk_is_reported(self):
        source = 'let query = app.buttons.matching(NSPredicate(format: "label == \'完成\'"))\n'
        violations = conv.check_ui_label_lookups(self.path, source)
        self.assertEqual(["ui-label-lookup"], rules(violations))

    def test_nspredicate_match_operator_options_are_reported(self):
        source = 'let query = NSPredicate(format: "label MATCHES[c] %@", "完.*")\n'
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_matching_identifier_outside_an_xctest_query_is_ignored(self):
        source = 'let match = model.matching(identifier: "完成")\n'
        self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_matching_identifier_on_an_xctest_query_variable_is_reported(self):
        source = (
            'let buttonQuery = app.buttons\n'
            'let button = buttonQuery.matching(identifier: "完成").firstMatch\n'
        )
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_japanese_kana_and_korean_hangul_are_reported(self):
        for visible_text in ("かな", "완료"):
            with self.subTest(visible_text=visible_text):
                source = f'let button = app.buttons["{visible_text}"]\n'
                self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_multiline_subscript_and_predicate_literals_are_reported(self):
        subscript_source = (
            'let button = app.buttons[\n'
            '    """\n'
            '    完成\n'
            '    """\n'
            ']\n'
        )
        predicate_source = (
            'let predicate = NSPredicate(\n'
            '    format: """\n'
            '    title == "播放设置"\n'
            '    """\n'
            ')\n'
        )
        subscript_violations = conv.check_ui_label_lookups(self.path, subscript_source)
        predicate_violations = conv.check_ui_label_lookups(self.path, predicate_source)
        self.assertEqual([1], [v.line for v in subscript_violations])
        self.assertEqual([1], [v.line for v in predicate_violations])

    def test_previous_line_directive_exempts_the_lookup(self):
        source = (
            '// ui-label-lookup: this assertion checks the Simplified Chinese button copy\n'
            'let button = app.buttons["完成"]\n'
        )
        self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_previous_line_directive_exempts_a_multiline_lookup(self):
        source = (
            '// ui-label-lookup: this assertion checks the Simplified Chinese button copy\n'
            'let button = app.buttons[\n'
            '    """\n'
            '    完成\n'
            '    """\n'
            ']\n'
        )
        self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_real_directive_after_nested_comment_and_raw_multiline_string_exempts_lookup(self):
        source = (
            '/* outer\n'
            '    /* inner */\n'
            '*/\n'
            'let message = #"""\n'
            'not a directive\n'
            '"""#\n'
            '// ui-label-lookup: assert a localized system label\n'
            'let button = app.buttons["完成"]\n'
        )
        self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_directive_without_a_reason_does_not_exempt_the_lookup(self):
        source = '// ui-label-lookup:\nlet button = app.buttons["完成"]\n'
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_whitespace_only_directive_reason_does_not_exempt_the_lookup(self):
        source = '// ui-label-lookup: \t\nlet button = app.buttons["完成"]\n'
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_directive_text_inside_block_comment_does_not_exempt_the_lookup(self):
        source = (
            '/*\n'
            ' // ui-label-lookup: a comment in the block is not a directive\n'
            ' */ let button = app.buttons["完成"]\n'
        )
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_directive_text_inside_nested_block_comment_does_not_exempt_the_lookup(self):
        source = (
            '/* outer\n'
            '    /* inner */\n'
            '    // ui-label-lookup: still inside the outer block\n'
            '*/ let button = app.buttons["完成"]\n'
        )
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_directive_text_inside_multiline_string_does_not_exempt_the_lookup(self):
        source = (
            'let message = """\n'
            '// ui-label-lookup: this is string content"""\n'
            'let button = app.buttons["完成"]\n'
        )
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_directive_text_inside_raw_multiline_string_does_not_exempt_the_lookup(self):
        source = (
            'let message = #"""\n'
            '// ui-label-lookup: this is raw string content"""#\n'
            'let button = app.buttons["完成"]\n'
        )
        self.assertEqual(["ui-label-lookup"], rules(conv.check_ui_label_lookups(self.path, source)))

    def test_identifier_subscript_and_cjk_text_assertion_pass(self):
        source = (
            'let button = app.buttons["settings.playback.done"]\n'
            'XCTAssertEqual(button.label, "完成")\n'
        )
        self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_comments_and_nonlookup_cjk_text_are_ignored(self):
        source = (
            '// app.buttons["完成"]\n'
            'let expectedCopy = "完成"\n'
            'XCTAssertEqual(button.label, expectedCopy)\n'
        )
        self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_dictionary_subscript_is_not_treated_as_an_element_query(self):
        source = 'let titles = ["完成": "Done"]\nlet title = titles["完成"]\n'
        self.assertEqual([], conv.check_ui_label_lookups(self.path, source))

    def test_non_ui_test_file_is_ignored(self):
        source = 'let button = app.buttons["完成"]\n'
        self.assertEqual([], conv.check_ui_label_lookups("immichSlidesTests/Example.swift", source))


class UIExistsThenReadTests(unittest.TestCase):
    def test_live_property_read_after_exists_is_rejected_but_snapshot_reads_pass(self):
        path = "immichSlidesUITests/Example.swift"
        cases = [
            ('button.exists ? button.value : "notVisible"', True),
            ('button.exists ? button.isEnabled : false', True),
            ('button.exists ? button.isHittable : false', True),
            ('button.exists\n    ? ((button.value as? String) ?? "") : "notVisible"', True),
            ('app.buttons["play"].exists ? app.buttons["play"].value : "notVisible"', True),
            ('button.exists /* can disappear here */ ? button.isEnabled : false', True),
            ('button.exists ? playPauseState(button) : "notVisible"', True),
            ('button.exists ? self.accessibilityValueString(for: button) : ""', True),
            ('button.exists\n ? format(prefix: "state:", value: playPauseState(button)) : ""', True),
            ('app.buttons["play"].exists ? state(of: app.buttons["play"]) : ""', True),
            ('button.exists ? state(of: (button), fallback: "") : ""', True),
            ('button.exists ? other.value : "notVisible"', False),
            ('app.buttons["play"].exists ? app.buttons["pause"].value : "notVisible"', False),
            ('button.exists ? playPauseState(other) : "notVisible"', False),
            ('app.buttons["play"].exists ? state(of: app.buttons["pause"]) : ""', False),
            ('app.buttons["play pause"].exists ? state(of: app.buttons["playpause"]) : ""', False),
            ('button.exists ? state(of: button.identifier) : ""', False),
            ('button.exists ? state(of: try? button.snapshot()) : ""', False),
            ('button.exists ? (try? button.snapshot())?.value : nil', False),
            ('button.exists ? "visible" : playPauseState(button)', False),
            ('button.exists ? "visible" : "missing"; record(button)', False),
            ('button.exists ? format("playPauseState(button)") : ""', False),
            ('button.exists ? state(other) /* playPauseState(button) */ : ""', False),
            ('snapshot?.value as? String ?? "notVisible"', False),
            ('// button.exists ? button.isEnabled : false', False),
            ('let example = "button.exists ? button.isHittable : false"', False),
        ]
        for expression, rejected in cases:
            with self.subTest(expression=expression):
                source = "func recordEvidence() {\n    let observed = " + expression + "\n}\n"
                violations = [violation for check in conv.CHECKS for violation in check(path, source)
                              if violation.rule == "ui-exists-then-read"]
                self.assertEqual(["ui-exists-then-read"] if rejected else [], rules(violations))
                if rejected:
                    self.assertEqual(2, violations[0].line)
                    self.assertIn("snapshot", violations[0].detail)

    def test_helper_read_in_test_support_is_rejected_but_unit_sources_are_ignored(self):
        source = 'func evidence() { let state = button.exists ? playPauseState(button) : "" }'
        self.assertEqual(["ui-exists-then-read"], rules(conv.check_ui_exists_then_reads(
            "TestSupport/Evidence.swift", source)))
        self.assertEqual([], conv.check_ui_exists_then_reads("immichSlidesTests/Example.swift", source))


class UnboundedWaitTests(unittest.TestCase):
    path = "immichSlidesTests/Example.swift"

    def test_yield_only_loop_without_a_bound_is_reported(self):
        source = "func poll() async {\n    while !condition() {\n        await Task.yield()\n    }\n}\n"
        violations = conv.check_unbounded_waits(self.path, source)
        self.assertEqual(["unbounded-wait"], rules(violations))
        self.assertEqual("poll", violations[0].name)

    def test_sleep_only_loop_without_a_bound_is_reported(self):
        source = "func poll() async {\n    while !condition() {\n        try? await Task.sleep(for: .milliseconds(10))\n    }\n}\n"
        violations = conv.check_unbounded_waits(self.path, source)
        self.assertEqual(["unbounded-wait"], rules(violations))

    def test_loop_with_a_deadline_in_the_condition_passes(self):
        source = "func poll() {\n    while Date() < deadline {\n        Thread.sleep(forTimeInterval: 0.01)\n    }\n}\n"
        self.assertEqual([], conv.check_unbounded_waits(self.path, source))

    def test_loop_with_a_deadline_check_in_the_body_passes(self):
        source = ("func poll() async {\n"
                  "    while !condition() {\n"
                  "        guard clock.now < deadline else { return }\n"
                  "        await Task.yield()\n"
                  "    }\n}\n")
        self.assertEqual([], conv.check_unbounded_waits(self.path, source))

    def test_loop_with_iteration_bound_in_condition_passes(self):
        source = "func poll() {\n    var attempts = 0\n    while attempts < 50 {\n        attempts += 1\n    }\n}\n"
        self.assertEqual([], conv.check_unbounded_waits(self.path, source))

    def test_loop_that_does_real_work_besides_waiting_is_not_reported(self):
        source = ("func walk() {\n"
                  "    while true {\n"
                  "        let candidate = next()\n"
                  "        if candidate == nil { break }\n"
                  "    }\n}\n")
        self.assertEqual([], conv.check_unbounded_waits(self.path, source))

    def test_loop_with_no_wait_primitive_at_all_is_not_reported(self):
        source = "func walk() {\n    while cursor != 0 {\n        cursor = next(cursor)\n    }\n}\n"
        self.assertEqual([], conv.check_unbounded_waits(self.path, source))

    def test_commented_out_while_loop_is_ignored(self):
        source = "func poll() {\n    // while true { await Task.yield() }\n}\n"
        self.assertEqual([], conv.check_unbounded_waits(self.path, source))


class MaskingTests(unittest.TestCase):
    def test_mask_comments_blanks_line_and_block_comments_but_keeps_strings(self):
        source = '// PR46\nlet a = "PR46"\n/* Phase0 */\nlet b = 1\n'
        masked = conv.mask_comments(source)
        self.assertNotIn("PR46\n", masked.splitlines(keepends=True)[0])
        self.assertIn('"PR46"', masked)
        self.assertNotIn("Phase0", masked)

    def test_mask_comments_with_mask_strings_blanks_both(self):
        source = 'let a = "PR46"\n'
        masked = conv.mask_comments(source, mask_strings=True)
        self.assertNotIn("PR46", masked)
        self.assertEqual(len(source), len(masked))


class AllowlistTests(unittest.TestCase):
    def test_unknown_violation_not_in_allowlist_fails(self):
        violations = [conv.Violation("immichSlidesTests/A.swift", 1, "forbidden-name", "file:APhase0", "x")]
        unallowed, stale = conv.partition_against_allowlist(violations, [])
        self.assertEqual(violations, unallowed)
        self.assertEqual([], stale)

    def test_matching_allowlist_entry_is_not_reported(self):
        violations = [conv.Violation("immichSlidesTests/A.swift", 1, "forbidden-name", "file:APhase0", "x")]
        allowlist = [{"rule": "forbidden-name", "path": "immichSlidesTests/A.swift", "name": "file:APhase0"}]
        unallowed, stale = conv.partition_against_allowlist(violations, allowlist)
        self.assertEqual([], unallowed)
        self.assertEqual([], stale)

    def test_stale_allowlist_entry_with_no_matching_violation_fails(self):
        allowlist = [{"rule": "forbidden-name", "path": "immichSlidesTests/A.swift", "name": "file:APhase0"}]
        unallowed, stale = conv.partition_against_allowlist([], allowlist)
        self.assertEqual([], unallowed)
        self.assertEqual(allowlist, stale)

    def test_allowlist_entry_only_matches_its_own_rule_path_and_name(self):
        violations = [conv.Violation("immichSlidesTests/A.swift", 1, "forbidden-name", "file:APhase0", "x")]
        allowlist = [{"rule": "swift-testing-name", "path": "immichSlidesTests/A.swift", "name": "file:APhase0"}]
        unallowed, stale = conv.partition_against_allowlist(violations, allowlist)
        self.assertEqual(violations, unallowed)
        self.assertEqual(allowlist, stale)


class TimeoutLiteralTests(unittest.TestCase):
    def test_timeout_inventory_ignores_comments_strings_and_classified_budgets(self):
        source = '''
        // element.waitForExistence(timeout: 9)
        let message = "timeout: 9"
        func poll() {
            element.waitForExistence(timeout: TestWait.seconds(.infrastructure(9)))
            TestWait.until(.product(3)) { true }
            scene(candidateWindowUsed: 12, recentWindowLimit: 4, candidateWindowSize: 8, windowCount: 3)
            let brightChannelThreshold: UInt8 = 210
            let cropRetentionThreshold: Double = 0.60
        }
        '''
        self.assertEqual([], conv.timeout_literal_inventory("TestSupport/A.swift", source))

    def test_wrapped_and_arithmetic_literals_cannot_bypass_inventory(self):
        calls = (("wait(timeout: ", ("TimeInterval(5)", "baseTimeout + 5", "1_000 / 10", ".seconds(5)")),
                 ("wait(windowSeconds: ", ("5", "baseSeconds + 5")),
                 ("wait(windowLimitSeconds: ", ("5",)),
                 ("Task.sleep(nanoseconds: ", ("20_000_000", "UInt64(5)", "baseNanoseconds + 5", "1_000 / 10")),
                 ("Thread.sleep(forTimeInterval: ", ("TimeInterval(5)", "baseSeconds + 5", "1_000 / 10")))
        calls += (("Date().addingTimeInterval(", ("TimeInterval(5)", "interval / 200", "(interval + 5) / 2")),
                  ("usleep(", ("UInt32(5)", "interval / 200")),
                  ("Task.sleep(for: .milliseconds(", ("Int64(5))", "interval / 200)")))
        for call, values in calls:
            for value in values:
                with self.subTest(value=value, call=call):
                    self.assertTrue(conv.timeout_literal_inventory("TestSupport/A.swift", "func poll() { " + call + value + ") }"))
        source = "func poll() { f(TestWait.seconds(.product(3)), timeout: 5) }"
        self.assertEqual(1, len(conv.timeout_literal_inventory("TestSupport/A.swift", source)))
        for wrapped in ("wait(timeout: base\n    + 5)", "wait(timeout: base +\n    5)", "let pollDelay = base\n    + 5"):
            with self.subTest(wrapped=wrapped):
                self.assertTrue(conv.timeout_literal_inventory("TestSupport/A.swift", "func poll() { " + wrapped + " }"))
        self.assertEqual([], conv.timeout_literal_inventory("TestSupport/A.swift", "func poll() { let pollDelay = base\n    let other = 5 }"))

    def test_named_and_typed_timing_initializers_cannot_bypass_inventory(self):
        declarations = ["let " + name + " = 0.25" for name in (
            "systemPauseHold", "positiveControlHold", "reducedMotionHold", "multiPhotoHold", "transitionHold",
            "midTransitionDelay", "settledDelay", "previousFlowTransitionSettleDelay", "sampleInterval")]
        declarations += [keyword + " span: " + value_type + " = " + value
                         for keyword in ("let", "var")
                         for value_type, value in (("TimeInterval", "5"), ("Duration", ".seconds(5)"),
                                                  ("DispatchTimeInterval", ".milliseconds(5)"),
                                                  ("Foundation.TimeInterval", "interval / 200"))]
        for declaration in declarations:
            with self.subTest(declaration=declaration):
                entries = conv.timeout_literal_inventory("TestSupport/A.swift", "func poll() { " + declaration + " }")
                self.assertEqual(1, len(entries))
                self.assertEqual("poll", entries[0]["function"])

    def test_classified_regions_ignore_only_their_own_numeric_arguments(self):
        for expression in (
                "TestWait.seconds(.product(3))", "TimeInterval(TestWait.seconds(.infrastructure(5)))",
                "TestWait.seconds(.product(base + 5)) / factor",
                "TestWait.seconds(isSlow ? .infrastructure(5) : .product(3))"):
            for prefix in ("wait(timeout: ", "Date().addingTimeInterval(", "Thread.sleep(forTimeInterval: "):
                with self.subTest(expression=expression, prefix=prefix):
                    source = "func poll() { " + prefix + expression + ") }"
                    self.assertEqual([], conv.timeout_literal_inventory("TestSupport/A.swift", source))
        for expression in (
                "TestWait.seconds(.infrastructure(5)) + 5", "5 + TestWait.seconds(.product(3))"):
            with self.subTest(expression=expression):
                source = "func poll() { wait(timeout: " + expression + ") }"
                self.assertEqual(1, len(conv.timeout_literal_inventory("TestSupport/A.swift", source)))
        source = '''func poll() {
            TestWait.until(.infrastructure(5), pollIntervalSeconds: 0.1) { wait(timeout: 7); return true }
            TestWait.observe(seconds: 3, pollIntervalSeconds: 0.1) { wait(timeout: 8); return true }
            TestWait.until(budget, pollIntervalSeconds: 0.1, { wait(timeout: 9); return true })
        }'''
        entries = conv.timeout_literal_inventory("TestSupport/A.swift", source)
        self.assertEqual({"timeout:7", "timeout:8", "timeout:9"}, {entry["literal"] for entry in entries})

    def test_test_time_limit_is_owned_by_its_function(self):
        source = "struct Flow { @Test(.timeLimit(.minutes(1)))\nfunc `finishes before its deadline`() {} }"
        entries = conv.timeout_literal_inventory("immichSlidesTests/A.swift", source)
        self.assertEqual("Flow.finishes before its deadline", entries[0]["function"])

    def test_timeout_inventory_tracks_calls_defaults_constants_and_nested_scopes(self):
        source = '''
        enum Timing { static let timeoutSeconds: TimeInterval = 8 }
        class Flow {
            func poll(timeout: Double = 4) {
                element.waitForExistence(timeout: 5)
                element.waitForExistence(timeout: 5)
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                Task.sleep(for: .milliseconds(100))
            }
            func next() { element.waitForExistence(timeout: 6) }
        }
        '''
        entries = conv.timeout_literal_inventory("TestSupport/A.swift", source)
        self.assertTrue(any(e["function"] == "Timing.<scope>" for e in entries))
        self.assertTrue(any(e["function"] == "Flow.poll" and e["count"] == 2 for e in entries))
        self.assertTrue(any(e["function"] == "Flow.next" for e in entries))
        self.assertEqual(6, len(entries))

    def test_new_changed_duplicated_moved_and_removed_literals_fail(self):
        path = "TestSupport/A.swift"
        source = "func poll() { element.waitForExistence(timeout: 5) }"
        baseline = conv.timeout_literal_inventory(path, source)
        self.assertEqual(([], []), conv.partition_timeout_allowlist(baseline, baseline))
        for changed_path, changed_source in (
                (path, source.replace("5", "6")),
                (path, source.replace(" }", "; element.waitForExistence(timeout: 5) }")),
                (path, source.replace("poll", "next")),
                (path, source.replace("5)", "5\n    + 100)")),
                ("TestSupport/B.swift", source),
                (path, "func poll() {}")):
            with self.subTest(path=changed_path, source=changed_source):
                current = conv.timeout_literal_inventory(changed_path, changed_source)
                added, stale = conv.partition_timeout_allowlist(current, baseline)
                self.assertTrue(added or stale)

    def test_timeout_exceptions_reject_duplicates_and_invalid_counts(self):
        baseline = conv.timeout_literal_inventory("TestSupport/A.swift", "func poll() { wait(timeout: 5) }")
        for invalid in (baseline * 2, [dict(baseline[0], count=0)], [dict(baseline[0], count=True)]):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    conv.partition_timeout_allowlist(baseline, invalid)

    def test_product_factor_access_is_reported_but_comments_are_ignored(self):
        for source in ('let key = "IMMICHSLIDES_TEST_WAIT_FACTOR"', 'let budget = TestWait.seconds(.product(3))'):
            with self.subTest(source=source):
                self.assertEqual(["product-wait-factor"], rules(conv.check_product_wait_factor("immichSlides/A.swift", source)))
        self.assertEqual([], conv.check_product_wait_factor("immichSlides/A.swift", "// TestWait is test-only"))


class SmokeManifestTests(unittest.TestCase):
    def test_manifest_rejects_execution_and_compiled_selector_drift(self):
        from strict_e2e_smoke import validate_manifest, unique_object
        planned = [{"id": "iphone-first-boot", "device": "iphone", "configuration": "Debug", "fixture": "a"}]
        manifest = {"schema_version": 1, "flows": [{"id": "iphone-first-boot", "device": "iphone",
            "platform": "ios", "configuration": "Debug", "fixtures": ["a"], "selector": "SmokeFlowIOSUITests/testFirstBoot"}]}
        methods = {"SmokeFlowIOSUITests/testFirstBoot": {"ios"}}
        self.assertEqual(manifest["flows"], validate_manifest(manifest, planned, methods))
        mutations = [
            (lambda p: p.update(schema_version=True), "smoke-manifest-shape"),
            (lambda p: p.update(flows=None), "smoke-manifest-shape"),
            (lambda p: p.update(extra=True), "smoke-manifest-shape"),
            (lambda p: p["flows"][0].update(extra=True), "smoke-manifest-shape"),
            (lambda p: p["flows"].append(copy.deepcopy(p["flows"][0])), "smoke-manifest-population: duplicate iphone-first-boot"),
            (lambda p: p["flows"].clear(), "smoke-manifest-population: missing iphone-first-boot"),
            (lambda p: p["flows"][0].update(id="unknown"), "smoke-manifest-population: unknown unknown"),
            (lambda p: p["flows"][0].update(device="ipad"), "smoke-manifest-mapping: iphone-first-boot device"),
            (lambda p: p["flows"][0].update(platform="tvos"), "smoke-manifest-mapping: iphone-first-boot platform"),
            (lambda p: p["flows"][0].update(configuration="Release"), "smoke-manifest-mapping: iphone-first-boot configuration"),
            (lambda p: p["flows"][0].update(fixtures=["a", "b"]), "smoke-manifest-mapping: iphone-first-boot fixtures"),
            (lambda p: p["flows"][0].update(selector="BootUITests/testMissing"), "smoke-manifest-selector: iphone-first-boot"),
            (lambda p: p["flows"][0].update(selector=[]), "smoke-manifest-selector: iphone-first-boot"),
        ]
        for mutate, message in mutations:
            with self.subTest(message=message):
                changed = copy.deepcopy(manifest)
                mutate(changed)
                with self.assertRaisesRegex(ValueError, message):
                    validate_manifest(changed, planned, methods)
        with self.assertRaisesRegex(ValueError, "smoke-manifest-selector: iphone-first-boot"):
            validate_manifest(manifest, planned, {"SmokeFlowIOSUITests/testFirstBoot": {"tvos"}})
        with self.assertRaisesRegex(ValueError, "smoke-manifest-shape: duplicate JSON key schema_version"):
            json.loads('{"schema_version":1,"schema_version":1,"flows":[]}', object_pairs_hook=unique_object)

    def test_smoke_binding_requires_the_contracted_method_and_bidirectional_inventory(self):
        from strict_e2e_smoke import validate_manifest
        planned = [{"id": "iphone-first-boot", "device": "iphone", "configuration": "Debug", "fixture": "a"}]
        selector = "SmokeFlowIOSUITests/testFirstBoot"
        manifest = {"schema_version": 1, "flows": [dict(planned[0], platform="ios", fixtures=["a"], selector=selector)]}
        del manifest["flows"][0]["fixture"]
        inventory = [{"kind": "ui", "identifier": selector, "target_home": "smoke", "smoke_flows": ["iphone-first-boot"]}]
        methods = {selector: {"ios"}, "SmokeFlowIOSUITests/testSettingsRelaunch": {"ios"},
                   "LegacyUITests/testFirstBoot": {"ios"}}
        self.assertEqual(manifest["flows"], validate_manifest(manifest, planned, methods, inventory))
        for changed_selector in ("SmokeFlowIOSUITests/testSettingsRelaunch", "LegacyUITests/testFirstBoot"):
            with self.subTest(selector=changed_selector), self.assertRaisesRegex(ValueError, "smoke-manifest-binding"):
                changed = copy.deepcopy(manifest)
                changed["flows"][0]["selector"] = changed_selector
                validate_manifest(changed, planned, methods, inventory)
        for change in (lambda rows: rows.clear(), lambda rows: rows.append(copy.deepcopy(rows[0])),
                       lambda rows: rows[0].update(kind="strict"), lambda rows: rows[0].update(target_home="unit"),
                       lambda rows: rows[0].update(smoke_flows=[]),
                       lambda rows: rows[0].update(smoke_flows=["iphone-first-boot", "unknown"]),
                       lambda rows: rows.append(dict(rows[0], identifier="SmokeFlowIOSUITests/testUnused"))):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "smoke-manifest-inventory"):
                changed = copy.deepcopy(inventory)
                change(changed)
                validate_manifest(manifest, planned, methods, changed)

    def test_smoke_is_excluded_from_every_existing_plan_population(self):
        from strict_e2e_smoke import validate_exclusions
        methods = {"SmokeFlowIOSUITests/testFirstBoot": {"ios"}, "SmokeFlowTVOSUITests/testFirstBoot": {"tvos"}}
        flows = [{"platform": platform, "selector": selector} for selector, platforms in methods.items() for platform in platforms]
        plans = {platform: {name: {"testTargets": [{"target": {"name": "immichSlidesUITests"}, **fields}]}
                            for name, fields in (("default", {"skippedTests": ["SmokeFlowIOSUITests", "SmokeFlowTVOSUITests"]}),
                                                 ("Evidence", {"selectedTests": ["LegacyUITests"]}),
                                                 ("XcodeCloud", {"selectedTests": ["LegacyUITests"]}))}
                 for platform in ("ios", "tvos")}
        validate_exclusions(flows, methods, plans)
        for platform in plans:
            for name in plans[platform]:
                for use_class in (True, False):
                    with self.subTest(platform=platform, plan=name, use_class=use_class):
                        changed = copy.deepcopy(plans)
                        target = changed[platform][name]["testTargets"][0]
                        if name == "default":
                            target["skippedTests"] = []
                        else:
                            selector = next(flow["selector"] for flow in flows if flow["platform"] == platform)
                            target["selectedTests"] = [selector.split("/")[0] if use_class else selector + "()"]
                        with self.assertRaisesRegex(ValueError, "smoke-manifest-exclusion"):
                            validate_exclusions(flows, methods, changed)

    def test_main_rejects_a_bad_smoke_manifest_in_a_temporary_repository(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            (root / "scripts/smoke-flows.json").write_text('{"schema_version":2,"flows":[]}')
            (root / "scripts/ci-test-tiers.json").write_text('{"smoke_flows":[],"inventory":[]}')
            with patch.object(conv, "check_repository", return_value=[]), patch.object(conv, "check_test_tier_plan", return_value=[]), \
                    patch.object(conv, "repository_timeout_inventory", return_value=[]):
                self.assertEqual(1, conv.main(["--root", temporary]))

    def test_main_checks_inventory_and_plan_exclusion_after_a_valid_compiled_manifest(self):
        import io
        from contextlib import redirect_stdout
        from strict_e2e_smoke import MANIFEST
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            (root / "immichSlidesUITests").mkdir()
            (root / "immichSlidesUITests/SmokeFlowIOSUITests.swift").write_text(
                '#if os(iOS)\nfinal class SmokeFlowIOSUITests: XCTestCase {\nfunc testFirstBoot() {}\n}\n#endif\n')
            selector = "SmokeFlowIOSUITests/testFirstBoot"
            flow = {"id": "iphone-first-boot", "platform": "ios", "device": "iphone", "configuration": "Debug",
                    "fixtures": ["a"], "selector": selector}
            (root / MANIFEST).write_text(json.dumps({"schema_version": 1, "flows": [flow]}))
            plan = {"smoke_flows": [{"id": flow["id"], "device": "iphone", "configuration": "Debug", "fixture": "a"}],
                    "inventory": [{"kind": "ui", "identifier": selector, "target_home": "smoke", "smoke_flows": [flow["id"]]}]}
            tier_path = root / "scripts/ci-test-tiers.json"
            tier_path.write_text(json.dumps(plan))
            for suffix in ("iOS", "tvOS"):
                for stem, fields in (("immichSlides-", {"skippedTests": ["SmokeFlowIOSUITests", "SmokeFlowTVOSUITests"]}),
                                     ("immichSlides-Evidence-", {"selectedTests": ["LegacyUITests"]}),
                                     ("XcodeCloud-UI-", {"selectedTests": ["LegacyUITests"]})):
                    (root / (stem + suffix + ".xctestplan")).write_text(json.dumps({"testTargets": [
                        {"target": {"name": "immichSlidesUITests"}, **fields}]}))
            with patch.object(conv, "check_repository", return_value=[]), patch.object(conv, "check_test_tier_plan", return_value=[]), \
                    patch.object(conv, "repository_timeout_inventory", return_value=[]):
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(0, conv.main(["--root", temporary]))
                invalid = copy.deepcopy(plan)
                invalid["inventory"][0]["target_home"] = "unit"
                tier_path.write_text(json.dumps(invalid))
                output = io.StringIO()
                with redirect_stdout(output):
                    self.assertEqual(1, conv.main(["--root", temporary]))
                self.assertIn("smoke-manifest-inventory", output.getvalue())
                tier_path.write_text(json.dumps(plan))
                path = root / "immichSlides-iOS.xctestplan"
                leaked = json.loads(path.read_text())
                leaked["testTargets"][0]["skippedTests"] = []
                path.write_text(json.dumps(leaked))
                output = io.StringIO()
                with redirect_stdout(output):
                    self.assertEqual(1, conv.main(["--root", temporary]))
                self.assertIn("smoke-manifest-exclusion", output.getvalue())


class RepositoryTests(unittest.TestCase):
    def test_target_tier_plan_rejects_population_drift_and_unproved_coverage(self):
        plan = json.loads((REPO_ROOT / conv.TEST_TIER_PLAN_PATH).read_text())
        context = conv.test_tier_context(REPO_ROOT)
        self.assertEqual([], conv.validate_test_tier_plan(plan, *context))
        mutations = (
            ('unsupported version', lambda p: p.update(schema_version=2), 'tier-plan-version'),
            ('accidental activation', lambda p: p.update(mode='active'), 'tier-plan-mode'),
            ('changed retry policy', lambda p: p['migration'].update(yellow_and_retry='expanded'), 'tier-plan-migration'),
            ('nonboolean removal flag', lambda p: p['migration'].update(unit_coverage_prs_remove_ui_tests=0), 'tier-plan-migration'),
            ('missing smoke', lambda p: p['smoke_flows'].pop(), 'tier-plan-smoke-population'),
            ('duplicate smoke', lambda p: p['smoke_flows'].__setitem__(0, p['smoke_flows'][1]), 'tier-plan-smoke-population'),
            ('missing UI method', lambda p: p['inventory'].pop(), 'tier-plan-inventory'),
            ('duplicate strict row', lambda p: p['inventory'].append(p['inventory'][0]), 'tier-plan-inventory'),
            ('unknown home', lambda p: p['inventory'][0].update(target_home='ignore'), 'tier-plan-home'),
            ('unproved coverage', lambda p: (p['inventory'][0].update(status='covered'),
                                            p['inventory'][0].pop('mutation_proof', None)), 'tier-plan-coverage'),
            ('unknown status', lambda p: p['inventory'][0].update(status='done'), 'tier-plan-coverage'),
            ('nonexistent replacement', lambda p: p['inventory'][0].update(replacement_tests=['MissingTests/never runs']), 'tier-plan-replacement'),
            ('unknown smoke reference', lambda p: p['inventory'][0].update(smoke_flows=['missing']), 'tier-plan-replacement'),
            ('missing smoke mapping', lambda p: next(r for r in p['inventory']
                                                    if r['identifier'] == p['smoke_flows'][0]['source']['identifier']
                                                    ).update(smoke_flows=[]), 'tier-plan-replacement'),
            ('wrong source configuration', lambda p: p['smoke_flows'][0].update(configuration='Release'), 'tier-plan-smoke-source'),
            ('wrong selector', lambda p: p['smoke_flows'][0]['source'].update(selector='MissingUITests/testNoSuchMethod'), 'tier-plan-smoke-source'),
            ('wrong fixture', lambda p: p['smoke_flows'][0].update(fixture='b'), 'tier-plan-smoke-contract'),
            ('lost assertion boundary', lambda p: p['smoke_flows'][0].update(must_not_assert=[]), 'tier-plan-smoke-contract'),
            ('empty user path', lambda p: p['smoke_flows'][0].update(user_path=''), 'tier-plan-smoke-contract'),
            ('missing weekly group', lambda p: p['weekly_human_review']['groups'].pop(), 'tier-plan-human-review'),
            ('missing review recording', lambda p: p['weekly_human_review']['groups'][0].update(recordings=[]), 'tier-plan-human-review'),
            ('unknown review reference', lambda p: p['inventory'][0].update(human_review_groups=['missing']), 'tier-plan-replacement'),
            ('missing release device', lambda p: p['release_full_set'].pop(), 'tier-plan-release'),
            ('missing release smoke', lambda p: p['release_full_set'][0]['smoke_flows'].pop(), 'tier-plan-release'),
            ('missing release visuals', lambda p: p['release_full_set'][0].update(human_review_groups=[]), 'tier-plan-release'),
            ('missing Release build', lambda p: p['release_full_set'][0].update(configurations=['Debug']), 'tier-plan-release'),
            ('malformed inventory', lambda p: p.update(inventory=None), 'tier-plan-shape'),
        )
        for label, mutate, expected in mutations:
            with self.subTest(mutation=label):
                changed = copy.deepcopy(plan)
                mutate(changed)
                self.assertIn(expected, [e.split(':', 1)[0] for e in conv.validate_test_tier_plan(changed, *context)])
        self.assertEqual([], conv.check_test_tier_plan(REPO_ROOT))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / conv.TEST_TIER_PLAN_PATH).write_text('{"schema_version":')
            self.assertEqual(["tier-plan-input"], rules(conv.check_test_tier_plan(root)))
            self.assertEqual(1, conv.main(["--root", directory]))
            (root / conv.TEST_TIER_PLAN_PATH).write_text(json.dumps(plan))
            (root / "immichSlidesUITests").mkdir()
            (root / "immichSlidesUITests/Flow.swift").write_text('func testUnowned() {}')
            violations = conv.check_test_tier_plan(root)
            self.assertEqual(["tier-plan-input"], rules(violations))
            self.assertEqual("immichSlidesUITests/Flow.swift: testUnowned() is not a member of a direct XCTestCase subclass",
                             violations[0].detail)

    def test_target_tier_plan_reports_each_bad_row_and_accepts_proven_replacements(self):
        plan = json.loads((REPO_ROOT / conv.TEST_TIER_PLAN_PATH).read_text())
        context = conv.test_tier_context(REPO_ROOT)
        row_id = plan['inventory'][0]['identifier']

        def reject(mutate, rule, *details):
            changed = copy.deepcopy(plan)
            mutate(changed)
            errors = conv.validate_test_tier_plan(changed, *context)
            matching = [e for e in errors if e.startswith(rule + ':')]
            self.assertTrue(matching, errors)
            for detail in details:
                self.assertTrue(any(detail in e for e in matching), errors)

        reject(lambda p: p['inventory'][0].pop('status'), 'tier-plan-shape', row_id, 'missing', 'status')
        reject(lambda p: p['inventory'][0].update(typo=[]), 'tier-plan-shape', row_id, 'extra', 'typo')
        reject(lambda p: p['inventory'][0].update(replacement_tests=['MissingTests/unknown']),
               'tier-plan-replacement', row_id, 'MissingTests/unknown')
        reject(lambda p: p['inventory'][0].update(human_review_groups=['tv-focus']),
               'tier-plan-review-device', row_id, 'tv-focus')
        ipad_id = 'p2-cache-smoke|normal|ipad|Debug|a'
        reject(lambda p: next(r for r in p['inventory'] if r['identifier'] == ipad_id).update(
            smoke_flows=['iphone-first-boot']), 'tier-plan-smoke-device', ipad_id, 'iphone-first-boot', 'ipad')
        tv_id = 'FilterSummaryTVOSVisualUITests/testTVOSAlbumFilterUpFromThirdCardCanReachTopBar'
        reject(lambda p: next(r for r in p['inventory'] if r['identifier'] == tv_id).update(
            human_review_groups=['ipad-rotation-split']), 'tier-plan-review-device', tv_id, 'ipad-rotation-split')
        reject(lambda p: next(r for r in p['inventory'] if r['identifier'] == tv_id).update(
            smoke_flows=['iphone-album-selection']), 'tier-plan-smoke-device', tv_id, 'iphone-album-selection', 'tv')
        reject(lambda p: next(r for r in p['inventory'] if r['identifier'] == tv_id).update(target_home='pr-smoke'),
               'tier-plan-pr-smoke', tv_id, 'not be')
        reject(lambda p: p['inventory'][0].update(identifier='malformed'),
               'tier-plan-identifier', 'malformed')
        reject(lambda p: p['inventory'][0].update(identifier='a||iphone|Debug|a'),
               'tier-plan-identifier', 'a||iphone|Debug|a')
        reject(lambda p: p['smoke_flows'][0].update(id=[]), 'tier-plan-shape', 'id')
        reject(lambda p: p['smoke_flows'][0].update(peer_fixture='b'), 'tier-plan-smoke-contract', 'peer_fixture')
        reject(lambda p: p['migration'].update(nightly_budget_minutes=''), 'tier-plan-shape', 'nightly_budget_minutes')
        for field in ('smoke_flows', 'inventory', 'release_full_set'):
            reject(lambda p: p.update({field: {}}), 'tier-plan-shape', field)
        for field in ('replacement_tests', 'smoke_flows', 'human_review_groups', 'mutation_proof'):
            for value in ('', {}, [None]):
                with self.subTest(field=field, value=value):
                    reject(lambda p: p['inventory'][0].update({field: value}),
                           'tier-plan-shape', row_id, field)
        for section, field in (('smoke_flows', 'must_not_assert'), ('release_full_set', 'smoke_flows'),
                               ('release_full_set', 'human_review_groups'), ('release_full_set', 'configurations'),
                               ('release_full_set', 'visual_variants'), ('release_full_set', 'additional_review')):
            reject(lambda p: p[section][0].update({field: ''}), 'tier-plan-shape', field)
        for field in ('devices', 'screenshots', 'recordings', 'look_for'):
            reject(lambda p: p['weekly_human_review']['groups'][0].update({field: {}}),
                   'tier-plan-shape', field)
        for index in range(len(plan['smoke_flows'])):
            with self.subTest(flow=plan['smoke_flows'][index]['id']):
                reject(lambda p: p['smoke_flows'][index]['source'].update(identifier='different'),
                       'tier-plan-smoke-source', plan['smoke_flows'][index]['id'], 'different')
                flow = plan['smoke_flows'][index]
                alternative = next((key, case) for key, case in context[1].items()
                                   if all(case[k] == flow[k] for k in ('device', 'configuration', 'fixture'))
                                   and key != flow['source']['identifier'])
                reject(lambda p: p['smoke_flows'][index].update(source=dict(
                    kind='strict', identifier=alternative[0], selector=alternative[1]['selector'])),
                    'tier-plan-smoke-source', flow['id'], alternative[0])
        for key, value in (('owner', 'unassigned'), ('escalate_to', 'unassigned')):
            reject(lambda p: p['weekly_human_review'].update({key: value}), 'tier-plan-human-review', key)
        reject(lambda p: p['release_full_set'][0].update(owner='unassigned'), 'tier-plan-release', 'owner')
        pr_smoke = context[3]
        for identifier in pr_smoke:
            reject(lambda p: next(r for r in p['inventory'] if r['identifier'] == identifier).update(target_home='unit'),
                   'tier-plan-pr-smoke', identifier, 'pr-smoke')
            reject(lambda p: p['inventory'].remove(next(r for r in p['inventory'] if r['identifier'] == identifier)),
                   'tier-plan-pr-smoke', identifier, 'missing')

        changed = copy.deepcopy(plan)
        changed['inventory'][0].pop('status')
        changed['inventory'][1]['replacement_tests'] = ['MissingTests/second row']
        errors = conv.validate_test_tier_plan(changed, *context)
        self.assertTrue(any(row_id in e and 'status' in e for e in errors), errors)
        self.assertTrue(any(changed['inventory'][1]['identifier'] in e and 'MissingTests/second row' in e
                            for e in errors), errors)

        changed = copy.deepcopy(plan)
        row_index = next(i for i, r in enumerate(changed['inventory']) if r['identifier'] == ipad_id)
        row = changed['inventory'][row_index]
        row['target_home'] = 'unit'
        row['human_review_groups'] = []
        row['smoke_flows'] = ['ipad-first-boot']
        changed['smoke_flows'][0]['must_not_assert'].append('extra-exclusion')
        self.assertEqual([], conv.validate_test_tier_plan(changed, *context))
        del row['human_review_groups']
        self.assertEqual([], conv.validate_test_tier_plan(changed, *context))
        row['status'] = 'covered'
        row['mutation_proof'] = [dict(pr='https://github.com/sudoHG/immichSlides/pull/719', test=test,
                                     mutation='Ignore the input rule', failed_then_passed_on=['ios', 'tvos'])
                                 for test in row['replacement_tests']]
        self.assertEqual([], conv.validate_test_tier_plan(changed, *context))
        for field in ('pr', 'test', 'mutation', 'failed_then_passed_on'):
            bad = copy.deepcopy(changed)
            bad['inventory'][row_index]['mutation_proof'][0].pop(field)
            self.assertTrue(any('mutation_proof' in e and field in e
                                for e in conv.validate_test_tier_plan(bad, *context)))
        for field, value in (('pr', 'unreviewed'), ('test', 'MissingTests/unknown'),
                             ('mutation', ''), ('failed_then_passed_on', ['ios'])):
            bad = copy.deepcopy(changed)
            bad['inventory'][row_index]['mutation_proof'][0][field] = value
            self.assertTrue(any(e.startswith('tier-plan-coverage:') and 'mutation_proof' in e
                                for e in conv.validate_test_tier_plan(bad, *context)))
        for replacements, proofs in ((row['replacement_tests'], []), ([], row['mutation_proof']),
                                     (['MissingTests/unknown'], row['mutation_proof'])):
            bad = copy.deepcopy(changed)
            bad['inventory'][row_index].update(replacement_tests=replacements, mutation_proof=proofs)
            self.assertTrue(any(e.startswith('tier-plan-coverage:') for e in
                                conv.validate_test_tier_plan(bad, *context)))

    def test_target_tier_replacements_and_mutation_receipts_match_compiled_platforms(self):
        plan = json.loads((REPO_ROOT / conv.TEST_TIER_PLAN_PATH).read_text())
        context = conv.test_tier_context(REPO_ROOT)
        tv_test = 'ServerConfigFormTVOSTests/plain text field commits final value to binding on end editing'
        ios_test = 'FilterSummaryNavigationIdentityIOSTests/album and people entries use distinct stable identifiers'
        shared_test = 'AppFlowStateMachineTests/app initial route goes straight to playback when configured, else to first boot'
        tv_id = 'tvos-n1-cold|normal|tv|Debug|a'
        shared_id = next(key for key, platforms in context[0].items() if set(platforms) == {'ios', 'tvos'})
        for identifier, replacement, receipt_platforms, expected_rule, detail in (
                (tv_id, tv_test, ['tvos'], None, None),
                (plan['inventory'][0]['identifier'], tv_test, ['tvos'], 'tier-plan-replacement', 'ios'),
                (shared_id, tv_test, ['tvos'], 'tier-plan-replacement', 'ios'),
                (tv_id, ios_test, ['ios'], 'tier-plan-replacement', 'tvos'),
                (tv_id, tv_test, ['ios', 'tvos'], 'tier-plan-coverage', 'failed_then_passed_on'),
                (tv_id, shared_test, ['tvos'], 'tier-plan-coverage', 'failed_then_passed_on'),
                (tv_id, shared_test, ['ios', 'tvos'], None, None)):
            with self.subTest(identifier=identifier, replacement=replacement, platforms=receipt_platforms):
                changed = copy.deepcopy(plan)
                row = next(r for r in changed['inventory'] if r['identifier'] == identifier)
                row.update(status='covered', replacement_tests=[replacement], mutation_proof=[dict(
                    pr='https://github.com/sudoHG/immichSlides/pull/718', test=replacement,
                    mutation='Ignore the input rule', failed_then_passed_on=receipt_platforms)])
                errors = conv.validate_test_tier_plan(changed, *context)
                if expected_rule is None:
                    self.assertEqual([], errors)
                else:
                    self.assertTrue(any(e.startswith(expected_rule + ':') and identifier in e
                                        and replacement in e and detail in e for e in errors), errors)
                    if expected_rule == 'tier-plan-replacement':
                        self.assertTrue(any(e.startswith('tier-plan-coverage:') and identifier in e for e in errors), errors)
                        row['status'] = 'pending'
                        self.assertTrue(any(e.startswith('tier-plan-replacement:') and identifier in e
                                            and replacement in e and detail in e for e in
                                            conv.validate_test_tier_plan(changed, *context)))

    def test_target_tier_context_reads_nested_sources_and_reports_invalid_inputs(self):
        from strict_e2e_runner_support import CommandError
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for folder in ('scripts', 'immichSlidesUITests/Nested', 'immichSlidesTests/Nested'):
                (root / folder).mkdir(parents=True)
            (root / 'scripts/nightly-matrix.json').write_text('{"cases": []}')
            areas = dict(schema_version=1, revision='test-areas', smoke=['RootUITests/testRoot',
                         'NestedUITests/testNestedScreenshot'], functional_smoke=['NestedUITests/testNested'], areas={
                             'core': dict(sources=['immichSlides/Shared/**'], tests=['RootUITests']),
                             'feature': dict(sources=['immichSlides/iOS/**'], tests=['NestedUITests'])})
            (root / 'scripts/ci-ui-areas.json').write_text(json.dumps(areas))
            (root / 'immichSlidesUITests/Flow.swift').write_text('class RootUITests: XCTestCase { func testRoot() {} }')
            (root / 'immichSlidesUITests/Nested/Flow.swift').write_text('class NestedUITests: XCTestCase { func testNested() {} }')
            (root / 'immichSlidesTests/Rule.swift').write_text('struct RootTests { @Test func `root rule`() {} }')
            (root / 'immichSlidesTests/Nested/Rule.swift').write_text(
                '#if os(tvOS)\nstruct NestedTests { @Test func `nested rule`() {} }\n#endif')
            ui, _, units, pr_smoke = conv.test_tier_context(root)
            self.assertEqual({'RootUITests/testRoot', 'NestedUITests/testNested'}, set(ui))
            self.assertEqual({'ios': {'RootTests/root rule'},
                              'tvos': {'RootTests/root rule', 'NestedTests/nested rule'}}, units)
            self.assertEqual({'NestedUITests/testNested'}, pr_smoke)
            del areas['functional_smoke']
            (root / 'scripts/ci-ui-areas.json').write_text(json.dumps(areas))
            self.assertEqual({'RootUITests/testRoot'}, conv.test_tier_context(root)[3])
            areas['smoke'].append(areas['smoke'][0])
            (root / 'scripts/ci-ui-areas.json').write_text(json.dumps(areas))
            with self.assertRaisesRegex(ValueError, 'duplicate UI area selector'):
                conv.test_tier_context(root)
            areas['smoke'].pop()
            (root / 'scripts/ci-ui-areas.json').write_text(json.dumps(areas))
            plan = json.loads((REPO_ROOT / conv.TEST_TIER_PLAN_PATH).read_text())
            (root / conv.TEST_TIER_PLAN_PATH).write_text(json.dumps(plan))
            with patch('run_strict_e2e.resolve_suite_selector', side_effect=CommandError('unknown suite')):
                (root / 'scripts/nightly-matrix.json').write_text(json.dumps({'cases': [dict(
                    suite='unknown', scenario='normal', device='iphone', configuration='Debug', fixture='a', platform='ios')]}))
                errors = conv.check_test_tier_plan(root)
                self.assertEqual(['tier-plan-input'], rules(errors))
                self.assertIn('unknown suite', errors[0].detail)
                self.assertIn('unknown|normal|iphone|Debug|a', errors[0].detail)
            with patch.object(conv, 'test_tier_context', side_effect=CommandError('context failure')):
                errors = conv.check_test_tier_plan(root)
                self.assertEqual(['tier-plan-input'], rules(errors))
                self.assertIn('context failure', errors[0].detail)
            with patch('run_strict_e2e.resolve_suite_selector', return_value='malformed'):
                errors = conv.check_test_tier_plan(root)
                self.assertEqual(['tier-plan-input'], rules(errors))
                self.assertIn('malformed', errors[0].detail)
            (root / conv.TEST_TIER_PLAN_PATH).write_text(
                '{"inventory":[{"identifier":"offending-row","status":"covered","status":"pending"}]}')
            errors = conv.check_test_tier_plan(root)
            self.assertEqual(['tier-plan-input'], rules(errors))
            self.assertIn('duplicate', errors[0].detail)
            self.assertIn('status', errors[0].detail)
            self.assertIn('offending-row', errors[0].detail)

    def test_every_direct_ui_case_forwards_the_first_failure_before_xctest(self):
        import tempfile
        hook = "override func record(_ issue: XCTIssue) { FirstFailureEvidence.record(self, issue: issue); super.record(issue) }"
        reset = "override func invokeTest() { FirstFailureContext.reset(); super.invokeTest() }"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "immichSlidesUITests"
            folder.mkdir()
            source = folder / "FlowUITests.swift"
            source.write_text("final class FlowUITests: XCTestCase { " + hook + reset + " }")
            self.assertEqual([], conv.check_repository(root))
            for missing, detail in ((hook, " must forward record(_:) to FirstFailureEvidence before super.record"),
                    (reset, " must reset the first-failure timeline before super.invokeTest")):
                source.write_text("final class FlowUITests: XCTestCase { " + (hook + reset).replace(missing, "") + " }")
                violations = conv.check_repository(root)
                self.assertEqual(["first-failure-hook"], rules(violations))
                self.assertEqual("FlowUITests" + detail, violations[0].detail)

    def test_repository_passes_with_the_committed_allowlist(self):
        violations = conv.check_repository(REPO_ROOT)
        allowlist = conv.load_allowlist(REPO_ROOT / conv.ALLOWLIST_PATH)
        unallowed, stale = conv.partition_against_allowlist(violations, allowlist)
        self.assertEqual([], [str(v) for v in unallowed])
        self.assertEqual([], stale)

    def test_repository_scan_actually_finds_test_functions(self):
        # Guards against the check passing only because it finds nothing to inspect.
        found = 0
        for file in conv.iter_target_files(REPO_ROOT):
            code = conv.mask_comments(file.read_text(encoding="utf-8"), mask_strings=True)
            found += sum(1 for _ in conv.iter_test_function_names(code))
        self.assertGreater(found, 50)


if __name__ == "__main__":
    unittest.main()
