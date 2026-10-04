import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_test_conventions as conv

REPO_ROOT = Path(__file__).resolve().parent.parent


def rules(violations):
    return [v.rule for v in violations]


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


class RepositoryTests(unittest.TestCase):
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
