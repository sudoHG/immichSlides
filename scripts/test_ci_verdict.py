"""Guard coverage and admission decisions against accidental green verdicts."""

import ast
import copy
import json
import re
import unittest
from pathlib import Path
from unittest.mock import patch

import ci_summary
from run_host_checks import HOST_CHECKS
from ci_verdict import classify_changes, evaluate_population, parse_policy
from test_ci_summary import valid_summary


def policy():
    return {"schema_version": 1, "approval_records": [approval_record("host")], "expected_skips": [], "deselections": []}


def approval_record(tier):
    return {"approver": "maintainer example", "date": "2026-10-08", "tier": tier,
            "link": "https://github.com/example/project/issues/1#issuecomment-1"}


class PopulationVerdictTests(unittest.TestCase):

    def setUp(self):
        self.summary = valid_summary()
        self.expected = self.summary["population"]["declared"]
        self.policy = policy()

    def verdict(self):
        return evaluate_population(self.summary, self.expected, self.policy, environment="hermetic")

    def test_declared_compiled_and_executed_must_account_for_every_identity(self):
        self.assertEqual(self.verdict()["status"], "passed")
        for collection in ("declared", "compiled", "observed"):
            with self.subTest(collection=collection):
                original = self.summary["population"][collection]
                self.summary["population"][collection] = []
                self.assertEqual(self.verdict()["status"], "failed")
                self.summary["population"][collection] = original

    def test_expected_skip_requires_exact_reason_tier_environment_and_no_execution(self):
        identity = self.expected[0]
        self.policy["expected_skips"] = [{"kind": "host", "key_pattern": "format", "dimensions": {},
                                          "tier": "host", "environment": "hermetic", "reason": "no fixture"}]
        self.summary["status"] = "unverified"
        self.summary["population"]["observed"] = [ci_summary.observation(identity, "skipped", 0, reason="no fixture")]
        self.assertEqual(self.verdict()["status"], "passed")
        self.assertEqual(self.verdict()["expected_skips"], [identity])
        for field, value in (("reason", "different"), ("tier", "nightly"), ("environment", "live")):
            with self.subTest(field=field):
                original = self.policy["expected_skips"][0][field]
                self.policy["expected_skips"][0][field] = value
                self.assertEqual(self.verdict()["status"], "failed")
                self.policy["expected_skips"][0][field] = original
        self.summary["population"]["observed"] = [ci_summary.observation(identity, "passed", 0)]
        self.assertEqual(self.verdict()["status"], "failed")
        for tier, environment, test in (("unit", "hermetic", ci_summary.test_identity("swift", "Tests/skipped()", platform="ios")),
                                        ("ui", "fixture", ci_summary.test_identity("ui", "Tests/testSkipped", platform="ios", device="iphone"))):
            self.summary["run"]["tier"] = tier
            self.expected = self.summary["population"]["declared"] = self.summary["population"]["compiled"] = [test]
            self.summary["population"]["observed"] = [ci_summary.observation(test, "skipped", 0, reason="no fixture")]
            self.policy["expected_skips"] = [{"kind": test["kind"], "key_pattern": test["key"], "dimensions": test["dimensions"],
                                              "tier": tier, "environment": environment, "reason": "no fixture"}]
            for records, status in (([approval_record("host"), approval_record(tier)], "passed"),
                                    ([approval_record("host")], "failed")):
                with self.subTest(tier=tier, approval_tiers=[record["tier"] for record in records]):
                    self.policy["approval_records"] = records
                    verdict = evaluate_population(self.summary, self.expected, self.policy, environment=environment)
                    self.assertEqual(verdict["status"], status)
                    self.assertEqual(verdict["expected_skips"], [test] if status == "passed" else [])

    def test_deselections_require_compilation_reason_owner_and_exclusive_accounting(self):
        entry = {"identity": self.expected[0], "tier": "host", "environment": "hermetic",
                 "reason": "live only", "owning_tier": "nightly-live"}
        self.policy["deselections"] = [entry]
        self.summary["population"]["observed"] = []
        self.summary["population"]["deselected"] = [{k: v for k, v in entry.items() if k not in {"tier", "environment"}}]
        self.assertEqual(self.verdict()["status"], "passed")
        for field in ("reason", "owning_tier"):
            with self.subTest(field=field):
                self.summary["population"]["deselected"][0][field] = "wrong"
                self.assertEqual(self.verdict()["status"], "failed")
                self.summary["population"]["deselected"][0][field] = entry[field]
        self.summary["population"]["compiled"] = []
        self.assertEqual(self.verdict()["status"], "failed")
        self.summary["population"]["compiled"] = self.expected
        self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], "passed", 0)]
        self.assertEqual(self.verdict()["status"], "failed")

    def test_parameter_rows_do_not_hide_missing_compiled_parameters(self):
        function = ci_summary.test_identity("swift", "Tests/works", platform="ios")
        parameters = [ci_summary.test_identity("swift", "Tests/works", platform="ios", parameter=p) for p in ("a", "b")]
        self.expected = [function]
        self.summary["population"]["declared"] = [function]
        self.summary["population"]["compiled"] = parameters
        self.summary["population"]["observed"] = [ci_summary.observation(p, "passed", 0) for p in parameters]
        self.assertEqual(self.verdict()["status"], "passed")
        self.summary["population"]["observed"].pop()
        self.assertEqual(self.verdict()["status"], "failed")
        # Xcode enumerates functions and exports their individual arguments separately.
        compiled = ci_summary.test_identity("swift", "immichSlidesTests/Tests/`works`(value:)", platform="ios")
        parameters = [dict(compiled, dimensions={"platform": "ios", "parameter": p}) for p in ("a", "b")]
        self.summary["population"]["compiled"] = [compiled]
        rows = [ci_summary.observation(p, "passed", 0) for p in [compiled, *parameters]]
        self.summary["population"]["observed"] = rows
        self.assertEqual(self.verdict()["status"], "passed")
        for case in ("failed argument", "duplicate argument", "unknown parent", "no function result"):
            with self.subTest(case=case):
                changed = copy.deepcopy(rows)
                if case == "failed argument":
                    changed[1] = ci_summary.observation(parameters[0], "failed", 0, message="Expectation failed")
                elif case == "duplicate argument":
                    changed.append(copy.deepcopy(changed[1]))
                elif case == "unknown parent":
                    changed[1]["identity"]["key"] = "immichSlidesTests/Other/`works`(value:)"
                else:
                    changed.pop(0)
                self.summary["population"]["observed"] = changed
                self.assertEqual(self.verdict()["status"], "failed")

    def test_failures_infrastructure_partial_results_and_unregistered_retries_stay_red(self):
        for outcome in ("failed", "crashed", "timed-out", "not-run", "needs-human-review", "skipped"):
            with self.subTest(outcome=outcome):
                self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], outcome, 0, reason="unexpected")]
                self.assertEqual(self.verdict()["status"], "failed")
        self.summary = valid_summary()
        self.summary["status"] = "unverified"
        self.assertEqual(self.verdict()["status"], "failed")
        self.summary["status"] = "passed"
        self.summary["infrastructure"] = [{"code": "cancelled", "message": "job cancelled"}]
        self.assertEqual(self.verdict()["status"], "failed")
        self.summary = valid_summary()
        entry = self.summary["population"]["observed"][0]
        entry["outcome"] = "flaky-passed"
        entry["duration_seconds"] = 0.2
        entry["attempts"][0].update(outcome="failed", exit_code=1)
        entry["attempts"].append(dict(entry["attempts"][0], number=2, outcome="passed", exit_code=0))
        self.assertEqual(self.verdict()["status"], "failed")

    def test_proposed_or_ambiguous_policy_cannot_authorize_an_exception(self):
        self.policy["approval_records"] = []
        self.assertEqual(self.verdict()["status"], "passed")
        self.policy["expected_skips"] = [{"kind": "host", "key_pattern": "format", "dimensions": {},
                                          "tier": "host", "environment": "hermetic", "reason": "missing"}]
        self.summary["population"]["observed"] = [ci_summary.observation(self.expected[0], "skipped", 0, reason="missing")]
        self.assertEqual(self.verdict()["status"], "failed")
        self.policy = policy()
        rule = {"kind": "host", "key_pattern": "*", "dimensions": {}, "tier": "host",
                "environment": "hermetic", "reason": "missing"}
        self.policy["proposed"] = {"expected_skips": [rule], "deselections": []}
        self.assertEqual(parse_policy(self.policy)["proposed"], self.policy["proposed"])
        self.assertEqual(self.verdict()["status"], "failed")
        self.assertEqual(self.verdict()["errors"], ["skipped: format"])
        self.policy["expected_skips"] = [rule, dict(rule, key_pattern="format")]
        self.assertEqual(self.verdict()["status"], "failed")

    def test_proposed_section_is_validated_but_never_authorizes_deselections(self):
        entry = {"identity": self.expected[0], "tier": "host", "environment": "hermetic",
                 "reason": "fixture mismatch", "owning_tier": "nightly-live"}
        self.policy["proposed"] = {"expected_skips": [], "deselections": [entry]}
        self.assertEqual(parse_policy(self.policy), self.policy)
        self.assertEqual(self.verdict()["status"], "passed")
        self.summary["population"]["observed"] = []
        self.summary["population"]["deselected"] = [
            {key: value for key, value in entry.items() if key not in {"tier", "environment"}}]
        self.assertEqual(self.verdict()["status"], "failed")
        for proposed in ({"deselections": []}, {"expected_skips": [], "deselections": [dict(entry, owning_tier="host")]},
                         {"expected_skips": [], "deselections": [entry, entry]},
                         {"expected_skips": [], "deselections": [], "approval_state": "approved"}):
            with self.subTest(proposed=proposed), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(self.policy, proposed=proposed))

    def test_malformed_policy_versions_duplicate_rules_and_owner_are_rejected(self):
        record = {"approver": "maintainer example", "date": "2026-10-08", "tier": "host",
                  "link": "https://github.com/example/project/issues/1#issuecomment-1"}
        recorded = dict(policy(), approval_records=[record])
        self.assertEqual(parse_policy(recorded), recorded)
        for field, value in (("approver", ""), ("date", "2026-02-30"), ("date", "20261008"),
                             ("tier", ""), ("link", "http://github.com/example/project/issues/1#issuecomment-1"),
                             ("link", "https://example.com/approval"), ("unknown", "value")):
            with self.subTest(approval_field=field, value=value), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(recorded, approval_records=[dict(record, **{field: value})]))
        for malformed in (None, [], {}, {key: value for key, value in record.items() if key != "tier"}):
            with self.subTest(approval_record=malformed), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(recorded, approval_records=[malformed]))
        for records in (None, {}, [record, record]):
            with self.subTest(approval_records=records), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(recorded, approval_records=records))
        for version in (2, True, "1", None):
            with self.subTest(version=version), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(policy(), schema_version=version))
        rule = {"kind": "host", "key_pattern": "format", "dimensions": {}, "tier": "host",
                "environment": "hermetic", "reason": "no fixture"}
        for entries in ([rule, rule], [dict(rule, reason="")], [dict(rule, dimensions={"unknown": "x"})]):
            with self.subTest(entries=entries), self.assertRaises(ci_summary.ContractError):
                parse_policy(dict(policy(), expected_skips=entries))
        with self.assertRaises(ci_summary.ContractError):
            parse_policy(dict(policy(), deselections=[{"identity": self.expected[0], "tier": "host",
                         "environment": "hermetic", "reason": "elsewhere", "owning_tier": "host"}]))


class AdmissionVerdictTests(unittest.TestCase):
    def test_gate_classification_failure_keeps_macos_enabled_and_writes_failed_evidence(self):
        from ci_gate import main
        identity = {"schema_version": 1, "event": "pull_request", "repository": "example/photos",
                    "tree_sha": "d" * 40, "base_sha": "a" * 40, "head_sha": "b" * 40,
                    "merge_sha": "c" * 40, "pull_request": 7}
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            records = Path(directory) / "records"
            outputs = Path(directory) / "outputs"
            with patch("sys.argv", ["ci_gate.py", "classify", "--output-dir", str(records)]), \
                    patch.dict("os.environ", {"GITHUB_OUTPUT": str(outputs), "GITHUB_RUN_ID": "101", "GITHUB_RUN_ATTEMPT": "1"}), \
                    patch("ci_gate.run_identity", return_value=identity), \
                    patch("ci_gate.source_metadata", return_value=(".github/workflows/ci-gate.yml", False)), \
                    patch("ci_gate.read_blob", return_value='{"schema_version":1}'), \
                    patch("ci_gate.classify", side_effect=ci_summary.ContractError("unavailable base")):
                self.assertEqual(main(), 1)
            self.assertEqual(outputs.read_text(), "run_macos=true\n")
            summary = ci_summary.parse_summary((records / "summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertEqual(summary["identity"], identity)
            self.assertEqual(summary["infrastructure"][0]["code"], "classification-failed")

    def test_gate_scheduler_binds_the_base_reader_and_policy_and_both_target_trees(self):
        from ci_gate import classify
        from ci_publish_git import BASE_MODULES, OPTIONAL_BASE_MODULES
        modules = {name: Path(__file__).with_name(name).read_text() for name in BASE_MODULES + OPTIONAL_BASE_MODULES}
        allowlist = Path(__file__).with_name("ci-classification.json").read_text()
        identity = {"event": "pull_request", "base_sha": "a" * 40, "head_sha": "b" * 40,
                    "merge_sha": "c" * 40}
        def repository_input(*args):
            if args[0] == "diff":
                return paths
            if args[-1] == identity["base_sha"]:
                return "immichSlides/base-only.swift\ndocs/base.md"
            return "immichSlides/merge-only.swift\ndocs/merge.md"

        for paths in ("docs/note.md", ""):
            with self.subTest(paths=paths), patch("ci_gate.revision_modules", return_value=modules) as reader, \
                    patch("ci_gate.read_blob", return_value=allowlist) as policy, \
                    patch("ci_gate.git", side_effect=repository_input) as diff, \
                    patch("ci_gate.base_reader", return_value={"app_affected": True, "ci_changing": False}) as evaluate:
                self.assertEqual(classify(identity), evaluate.return_value)
                reader.assert_called_once_with(identity["base_sha"])
                policy.assert_called_once_with(identity["base_sha"], "scripts/ci-classification.json")
                diff.assert_any_call("diff", "--name-only", "--no-renames",
                                     identity["base_sha"] + "..." + identity["head_sha"])
                diff.assert_any_call("ls-tree", "--name-only", "-r", identity["base_sha"])
                diff.assert_any_call("ls-tree", "--name-only", "-r", identity["merge_sha"])
                evaluate.assert_called_once_with(modules, {
                    "operation": "classify", "paths": [paths] if paths else ["__unknown_empty_diff__"],
                    "classification_policy": json.loads(allowlist),
                    "build_target_paths": ["immichSlides/base-only.swift", "immichSlides/merge-only.swift"]})
        with patch("ci_gate.git") as diff:
            self.assertTrue(classify({"event": "push"})["app_affected"])
            diff.assert_not_called()


    def test_classification_covers_kept_workflow_tools_and_their_import_closure(self):
        allowlist = json.loads(Path(__file__).with_name("ci-classification.json").read_text(encoding="utf-8"))
        for paths, members, app, ci in ((["docs/README.md"], set(), False, False),
                                       (["docs/bundled.md"], {"docs/bundled.md"}, True, False),
                                       (["immichSlides/Resources/privacy.html"], set(), True, False),
                                       (["scripts/ci-test-policy.json"], set(), True, True),
                                       (["scripts/ci_population.py"], set(), True, True),
                                       (["scripts/test_ci_summary.py"], set(), True, True),
                                       (["scripts/run_host_checks.py"], set(), True, True),
                                       (["scripts/ui_test_inventory.py"], set(), True, True),
                                       (["scripts/ci-pins.json"], set(), True, True),
                                       (["scripts/smoke-flows.json"], set(), True, True),
                                       (["scripts/test_timeout_allowlist.json"], set(), True, True),
                                       (["immichSlides-iOS.xctestplan"], set(), True, True),
                                       (["immichSlides-tvOS.xctestplan"], set(), True, True),
                                       (["other/XcodeCloud-UI-tvOS.xctestplan"], set(), True, True),
                                       (["Other.xctestplan"], set(), True, True),
                                       (["immichSlides.xcodeproj/xcshareddata/xcschemes/immichSlides-tvOS.xcscheme"], set(), True, True),
                                       ([".github/workflows/ci-gate.yml"], set(), True, True),
                                       ([".github/actions/check/action.yml", ".github/actions/check/check.py"], set(), True, True),
                                       ([".swift-format"], set(), True, True),
                                       (["scripts/check_test_conventions.py", "scripts/test_conventions_allowlist.json"], set(), True, True),
                                       (["AGENTS.md", "CLAUDE.md", ".github/ISSUE_TEMPLATE/bug.md"], set(), True, False),
                                       (["scripts/run_strict_e2e.py", "scripts/test_strict_e2e_photo_identity.py"], set(), True, True),
                                       (["scripts/clean_stale_catalog_entries.py", "scripts/test_clean_stale_catalog_entries.py"], set(), True, False),
                                       (["unknown.file"], set(), True, False)):
            with self.subTest(paths=paths):
                classification = classify_changes(paths, allowlist, build_target_paths=members)
                self.assertEqual((classification["app_affected"], classification["ci_changing"]), (app, ci))
        host_paths = [part for _, command in HOST_CHECKS for part in command if part.startswith("scripts/")]
        host_paths += ["scripts/test_check_test_conventions.py", "scripts/test_check_release_guards.py",
                       "scripts/test_validate_localization_catalog.py", "scripts/test_scan_chinese_strings.py",
                       "scripts/test_required_test_tools.py", "scripts/test_conventions_allowlist.json"]
        root = Path(__file__).resolve().parent.parent
        for workflow in (root / ".github/workflows").glob("*.yml"):
            source = workflow.read_text(encoding="utf-8")
            for reference in re.findall(r"\bscripts/[A-Za-z0-9_./*?\[\]-]+", source):
                if any(character in reference for character in "*?["):
                    matches = [str(path.relative_to(root)) for path in root.glob(reference) if path.is_file()]
                    self.assertTrue(matches, f"workflow path pattern has no files: {reference}")
                    host_paths += matches
                else:
                    host_paths.append(reference)
            for action in re.findall(r"\buses:\s*['\"]?\./([A-Za-z0-9_./-]+)", source):
                action_files = [str(path.relative_to(root)) for path in (root / action).rglob("*") if path.is_file()]
                self.assertTrue(action_files, f"local action path has no files: {action}")
                host_paths += action_files
            # Bare names in the source-free consumer toolset are CI inputs too.
            for copied in re.findall(r"for file in ([^;]+); do", source):
                host_paths += ["scripts/" + name for name in copied.split()]
        host_paths += ["scripts/test_check_all.py", "scripts/test_git_privacy_gate.py", "scripts/__init__.py"]
        host_paths += [str(path.relative_to(root)) for path in (root / "scripts").glob("git_privacy_gate_test_*.py")]
        host_paths += ["scripts/test_run_offline_unit_tests.py"]
        host_paths += [str(path.relative_to(root)) for path in (root / "scripts").glob("run_offline_unit_tests_test_*.py")]
        for path in host_paths:
            with self.subTest(host_path=path):
                self.assertTrue(classify_changes([path], allowlist, build_target_paths=set())["ci_changing"])
        from ci_unit_tests import TOOL_FILES
        host_paths += ["scripts/" + name for name in TOOL_FILES]
        local_modules = {path.stem: path for path in (root / "scripts").glob("*.py")}
        pending = [path for path in local_modules.values()
                   if str(path.relative_to(root)) in set(host_paths)]
        visited = set()
        while pending:
            path = pending.pop()
            if path in visited:
                continue
            visited.add(path)
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"), filename=str(path))):
                if isinstance(node, ast.Import):
                    names = [alias.name for alias in node.names]
                elif isinstance(node, ast.ImportFrom):
                    names = (["__init__"] + [alias.name for alias in node.names] if node.module == "scripts"
                             else [node.module] if node.module else [alias.name for alias in node.names])
                else:
                    continue
                for name in names:
                    module = name.removeprefix("scripts.").split(".")[0]
                    if module in local_modules:
                        dependency = local_modules[module]
                        relative = str(dependency.relative_to(root))
                        with self.subTest(importer=str(path.relative_to(root)), dependency=relative):
                            self.assertTrue(classify_changes([relative], allowlist, build_target_paths=set())["ci_changing"],
                                            "CI-trusted scripts must include their recursive local-import closure")
                        pending.append(dependency)
        for pattern in allowlist["ci_trusted"] + allowlist["app_unaffected"]:
            if not any(character in pattern for character in "*?["):
                with self.subTest(exact_path=pattern):
                    self.assertTrue((root / pattern).is_file(), "exact classification entries must exist")
        with self.assertRaisesRegex(ci_summary.ContractError, "changed path list"):
            classify_changes([], allowlist, build_target_paths=set())
        for path in ("../README.md", "/README.md", "docs/../scripts/x.py"):
            with self.subTest(path=path), self.assertRaises(ci_summary.ContractError):
                classify_changes([path], allowlist, build_target_paths=set())


if __name__ == "__main__":
    unittest.main()
