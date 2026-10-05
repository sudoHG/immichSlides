import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_release_guards as guards

REPO_ROOT = Path(__file__).resolve().parent.parent


def index_of(source: str, needle: str) -> int:
    return source.index(needle)


class DebugRegionTests(unittest.TestCase):
    def test_marker_inside_if_debug_is_inside(self):
        source = "#if DEBUG\nlet marker = 1\n#endif\n"
        self.assertTrue(guards.is_inside_debug_region(source, index_of(source, "marker")))

    def test_else_branch_of_if_debug_is_outside(self):
        source = "#if DEBUG\nlet a = 1\n#else\nlet marker = 1\n#endif\n"
        self.assertFalse(guards.is_inside_debug_region(source, index_of(source, "marker")))

    def test_elseif_debug_branch_is_inside(self):
        source = "#if os(tvOS)\nlet a = 1\n#elseif DEBUG\nlet marker = 1\n#endif\n"
        self.assertTrue(guards.is_inside_debug_region(source, index_of(source, "marker")))

    def test_nested_platform_check_inside_debug_is_inside(self):
        source = "#if DEBUG\n#if os(iOS)\nlet marker = 1\n#endif\n#endif\n"
        self.assertTrue(guards.is_inside_debug_region(source, index_of(source, "marker")))

    def test_code_after_endif_is_outside(self):
        source = "#if DEBUG\nlet a = 1\n#endif\nlet marker = 1\n"
        self.assertFalse(guards.is_inside_debug_region(source, index_of(source, "marker")))

    def test_directive_in_comment_does_not_count(self):
        source = "// #if DEBUG\nlet marker = 1\n"
        self.assertFalse(guards.is_inside_debug_region(source, index_of(source, "marker")))

    def test_directive_in_block_comment_does_not_count(self):
        source = "/*\n#if DEBUG\n*/\nlet marker = 1\n"
        self.assertFalse(guards.is_inside_debug_region(source, index_of(source, "marker")))

    def test_directive_in_string_does_not_count(self):
        source = 'let text = "#if DEBUG"\nlet marker = 1\n'
        self.assertFalse(guards.is_inside_debug_region(source, index_of(source, "marker")))

    def test_directive_in_multiline_string_does_not_count(self):
        source = 'let text = """\n#if DEBUG\n"""\nlet marker = 1\n'
        self.assertFalse(guards.is_inside_debug_region(source, index_of(source, "marker")))

    def test_compound_condition_is_not_treated_as_debug(self):
        source = "#if DEBUG && os(iOS)\nlet marker = 1\n#endif\n"
        self.assertFalse(guards.is_inside_debug_region(source, index_of(source, "marker")))

    def test_unbalanced_endif_counts_as_outside(self):
        source = "#endif\n#if DEBUG\nlet marker = 1\n#endif\n"
        self.assertFalse(guards.is_inside_debug_region(source, index_of(source, "marker")))


class RuleTests(unittest.TestCase):
    path = "immichSlides/Shared/Model/Example.swift"

    def test_debug_marker_outside_debug_is_reported(self):
        source = 'let flag = environment["IMMICHSLIDES_DEBUG_PLAYBACK_SEQUENCE"]\n'
        violations = guards.check_debug_only_markers(self.path, source)
        self.assertEqual(["debug-only"], [v.rule for v in violations])
        self.assertEqual(1, violations[0].line)

    def test_debug_marker_inside_debug_passes(self):
        source = '#if DEBUG\nlet flag = environment["IMMICHSLIDES_DEBUG_PLAYBACK_SEQUENCE"]\n#endif\n'
        self.assertEqual([], guards.check_debug_only_markers(self.path, source))

    def test_debug_marker_in_comment_is_ignored(self):
        source = "// qaPlaybackSequenceRecorder is only created in DEBUG builds\nlet a = 1\n"
        self.assertEqual([], guards.check_debug_only_markers(self.path, source))

    def test_exif_diagnostics_and_playback_overlay_require_debug_regions(self):
        markers = (
            "UI_TEST_SHOW_EXIF_SAMPLING_DEBUG", "shouldShowExifSamplingDebugOverlay",
            "exifSamplingDebugSnapshot", "exifSamplingDebugOverlay", "ExifSamplingDebugSnapshot",
            "ExifForegroundAnalyzer.debugSnapshot", "debugSnapshotSynchronously",
            "legacyToneForBenchmark", "displayedBackdropToneForBenchmark",
            "displayedBackdropAverageToneForBenchmark", "displayedBackdropEffectiveLuminance",
            "DebugOverlayView", "PlaybackDebugOverlaySceneSummary",
        )
        for marker in markers:
            with self.subTest(marker=marker):
                source = f"let diagnostic = {marker}\n"
                self.assertTrue(guards.check_debug_only_markers(self.path, source))
                self.assertEqual([], guards.check_debug_only_markers(
                    self.path, f"#if DEBUG\n{source}#endif\n"))

    def test_exif_diagnostic_switch_must_be_owned_by_platform_compat(self):
        source = '#if DEBUG\nlet flag = environment["UI_TEST_SHOW_EXIF_SAMPLING_DEBUG"]\n#endif\n'
        self.assertEqual(["debug-switch"], [v.rule for v in
                         guards.check_platform_compat_only_keys(self.path, source)])
        self.assertEqual([], guards.check_platform_compat_only_keys(guards.PLATFORM_COMPAT_FILE, source))

    def test_playback_injections_and_diagnostic_data_require_debug_regions(self):
        markers = (
            "lastDownloadDuration", "lastDownloadBytes", "didLastDownloadHitCache",
            "currentSmartFillRuntimeQADebugSummary", "smartFillRuntimeQADebugSummary", "qaDebugSummary",
            "recordingQADebugSummary", "smartFillQADebugSummary", "qaSummaryRecordingPublishTiming",
            "qaSummary", "visionFaceAuditState", "visionFaceAuditTask",
            "refreshVisionFaceAuditForCurrentAsset", "clearVisionFaceAuditState",
            "loadAssetsHookForTesting", "loadMoreAssetsHookForTesting", "initialPhotoLoadHookForTesting",
            "backgroundPreloadHookForTesting", "indexChangePhotoLoadHookForTesting",
            "playbackManifestTimestampProviderForTesting", "scenePresentationTimestampProviderForTesting",
            "transitionWindowPreloadHookForTesting", "smartFillMotionPreparedSlotPreloadHookForTesting",
            "replacePlaybackAssetsForTesting", "forceNextPhotoRecoveryMessageForTesting",
            "visibleImageAssetIdProbeLabel", "overlayAssetIdProbeLabel", "recordSmartFillFirstImageDisplayedForTesting",
            "prepareVisualAuditSelectionsForUITestsIfNeeded", "uiTestReadinessMarkers",
            "VisualAuditPreparation", "isAlbumVisualAuditReady", "isPeopleVisualAuditReady",
            "isFilterSummaryVisualAuditReady", "isFilterEditorVisualAuditReady", "shouldExposeUITestReadinessMarkers",
            "shouldResetStateForTesting", "visionAuditTriggerKey", "visionFaceAuditCandidateURLs", "makeQADebugSummary",
            "rejectedLayoutDiagnostic", "recordRejectedLayoutDiagnostic", "maximumRejectedLayoutSummar",
            "smartFillPlannerLabel", "diagnosticSlotReferences", "manifestSlotRefs",
        )
        for marker in markers:
            with self.subTest(marker=marker):
                source = f"let probe = {marker}\n"
                self.assertTrue(guards.check_debug_only_markers(self.path, source))
                self.assertEqual([], guards.check_debug_only_markers(
                    self.path, f"#if DEBUG\n{source}#endif\n"))

    def test_preparation_hint_and_contract_readers_require_debug_and_platform_compat(self):
        keys = (
            "UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS", "UI_TEST_PREPARE_FILTER_EDITOR_VISUAL_SELECTIONS",
            "UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT", "UI_TEST_DISABLE_DEBUG_FILL_APIKEY_BUTTON",
            "UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE", "UI_TEST_RESET_STATE",
        )
        for key in keys:
            with self.subTest(key=key):
                source = f'let flag = environment["{key}"] == "1"\n'
                self.assertTrue(guards.check_debug_only_markers(guards.PLATFORM_COMPAT_FILE, source))
                self.assertEqual([], guards.check_debug_only_markers(
                    guards.PLATFORM_COMPAT_FILE, f"#if DEBUG\n{source}#endif\n"))
                self.assertEqual(["debug-switch"], [v.rule for v in
                                 guards.check_platform_compat_only_keys(self.path, source)])
                self.assertEqual([], guards.check_platform_compat_only_keys(guards.PLATFORM_COMPAT_FILE, source))

    def test_engine_must_not_reference_image_cache(self):
        path = "immichSlides/Shared/Model/PlaybackSessionEngine.swift"
        violations = guards.check_forbidden_symbols(path, "let cache = SDImageCache.shared\n")
        self.assertEqual(["layer-boundary"], [v.rule for v in violations])

    def test_planner_split_file_must_not_reference_image_cache(self):
        path = "immichSlides/Shared/Model/PlaybackSmartFillPlanner+X.swift"
        violations = guards.check_forbidden_symbols(path, "let cache = SDImageCache.shared\n")
        self.assertEqual([(path, 1, "layer-boundary")], [(v.path, v.line, v.rule) for v in violations])

    def test_forbidden_symbol_in_comment_is_ignored(self):
        path = "immichSlides/Shared/Model/PlaybackSmartFillPlanner.swift"
        self.assertEqual([], guards.check_forbidden_symbols(path, "// no diagnostic hooks here\nlet a = 1\n"))

    def test_retired_symbol_is_reported_anywhere_except_diagnostics(self):
        source = "func scheduleDecodePrewarm() {}\n"
        self.assertEqual(["retired-path"], [v.rule for v in guards.check_forbidden_symbols(self.path, source)])
        self.assertEqual([], guards.check_forbidden_symbols(guards.RETIRED_SYMBOLS_EXEMPT_FILE, source))

    def test_zero_io_getter_rejects_file_writes(self):
        path, name = guards.ZERO_IO_GETTER
        source = f"var {name}: String {{\n    handle.write(data)\n    return json\n}}\n"
        violations = guards.check_zero_io_getter(path, source)
        self.assertEqual(["zero-io-getter"], [v.rule for v in violations])
        self.assertEqual(2, violations[0].line)

    def test_zero_io_getter_passes_without_io(self):
        path, name = guards.ZERO_IO_GETTER
        source = f"var {name}: String {{\n    return summary.json\n}}\nfunc flushLater() {{ handle.write(data) }}\n"
        self.assertEqual([], guards.check_zero_io_getter(path, source))

    def test_zero_io_getter_missing_is_reported(self):
        path, _ = guards.ZERO_IO_GETTER
        self.assertEqual(["zero-io-getter"], [v.rule for v in guards.check_zero_io_getter(path, "let a = 1\n")])

    def test_single_photo_switch_outside_platform_compat_is_reported(self):
        source = 'let off = ProcessInfo.processInfo.environment["IMMICHSLIDES_DISABLE_SMART_FILL"] == "1"\n'
        self.assertEqual(["debug-switch"], [v.rule for v in guards.check_platform_compat_only_keys(self.path, source)])
        self.assertEqual([], guards.check_platform_compat_only_keys(guards.PLATFORM_COMPAT_FILE, source))

    def test_env_example_debug_switch_must_default_off(self):
        text = "IMMICH_API_KEY =\nENABLE_DEBUG_AUTO_SERVER = 0\nENABLE_DEBUG_SETTINGS_ENTRY = 1\n"
        violations = guards.check_env_example(text)
        self.assertEqual([(3, "debug-default-off")], [(v.line, v.rule) for v in violations])

    def test_env_xcconfig_on_release_configuration_is_reported(self):
        text = (
            "\n\t\tAAA /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbaseConfigurationReference = DBG /* Debug.xcconfig */;\n\t\t};"
            "\n\t\tBBB /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbaseConfigurationReference = DBG /* Debug.xcconfig */;\n\t\t};"
        )
        violations = guards.check_env_xcconfig_debug_only(text, '#include? "env.xcconfig"\n')
        self.assertEqual(["local-config-debug-only"], [v.rule for v in violations])
        self.assertIn("Release", violations[0].detail)

    def test_direct_env_xcconfig_reference_is_reported(self):
        text = (
            "\n\t\tBBB /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbaseConfigurationReference = DBG /* Debug.xcconfig */;\n\t\t};"
            "\n\t\tAAA /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbaseConfigurationReferenceRelativePath = Config/env.xcconfig;\n\t\t};"
        )
        violations = guards.check_env_xcconfig_debug_only(text, '#include? "env.xcconfig"\n')
        self.assertEqual(["local-config-debug-only"], [v.rule for v in violations])
        self.assertIn("Config/Debug.xcconfig", violations[0].detail)

    def test_debug_config_must_include_env_optionally(self):
        text = (
            "\n\t\tAAA /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbaseConfigurationReference = DBG /* Debug.xcconfig */;\n\t\t};"
        )
        violations = guards.check_env_xcconfig_debug_only(text, '#include "env.xcconfig"\n')
        self.assertEqual(["local-config-debug-only"], [v.rule for v in violations])
        self.assertIn("optional", violations[0].detail)

    def test_release_config_must_not_reference_any_xcconfig(self):
        text = (
            "\n\t\tAAA /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbaseConfigurationReference = DBG /* Debug.xcconfig */;\n\t\t};"
            "\n\t\tBBB /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbaseConfigurationReference = OTHER /* Release.xcconfig */;\n\t\t};"
        )
        violations = guards.check_env_xcconfig_debug_only(text, '#include? "env.xcconfig"\n')
        self.assertEqual(["local-config-debug-only"], [v.rule for v in violations])
        self.assertIn("Release configurations", violations[0].detail)

    def app_project(self, *, owns_folder: bool, exceptions: list[str], attached: bool = True, extra: str = "") -> str:
        owned = ("\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\tGRP /* immichSlides */,\n\t\t\t);\n"
                 if owns_folder else "")
        attached_sets = "\t\t\t\tEXC /* Exceptions */,\n" if attached else ""
        listed = "".join(f"\t\t\t\t{entry},\n" for entry in exceptions)
        return (
            extra
            + "\n\t\tEXC /* Exceptions */ = {\n\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n"
            f"\t\t\tmembershipExceptions = (\n{listed}\t\t\t);\n\t\t\ttarget = APP /* immichSlides */;\n\t\t}};"
            "\n\t\tGRP /* immichSlides */ = {\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
            f"\t\t\texceptions = (\n{attached_sets}\t\t\t\tTSX /* Test exceptions */,\n\t\t\t);\n\t\t}};"
            f"\n\t\tAPP /* immichSlides */ = {{\n\t\t\tisa = PBXNativeTarget;\n{owned}"
            "\t\t\tname = immichSlides;\n\t\t};"
        )

    def reported_paths(self, text: str, local_config_files=()) -> list[str]:
        violations = guards.check_local_config_not_bundled(text, local_config_files)
        return [v.detail.split(" is a local configuration under ")[0] for v in violations
                if " is a local configuration under " in v.detail]

    def test_synchronized_folder_with_local_config_is_reported(self):
        text = self.app_project(owns_folder=True, exceptions=["Info.plist"])
        self.assertEqual(["Config/env.xcconfig"], self.reported_paths(text, ("Config/env.xcconfig",)))

    def test_excluding_a_local_config_does_not_make_it_allowed(self):
        text = self.app_project(owns_folder=True, exceptions=["Config/env.xcconfig"])
        self.assertEqual(["Config/env.xcconfig"], self.reported_paths(text, ("Config/env.xcconfig",)))

    def test_stale_config_exceptions_are_reported(self):
        text = self.app_project(owns_folder=True, exceptions=['"Config/env.xcconfig"'])
        violations = guards.check_local_config_not_bundled(text)
        self.assertEqual(["local-config-not-bundled"], [v.rule for v in violations])
        self.assertIn("stale", violations[0].detail)

    def test_excluding_the_config_folder_does_not_count(self):
        # Xcode still bundles the files when only the folder is excluded.
        text = self.app_project(owns_folder=True, exceptions=["Config"])
        self.assertEqual(["Config/env.xcconfig"], self.reported_paths(text, ("Config/env.xcconfig",)))

    def test_exception_set_not_attached_to_the_folder_does_not_count(self):
        text = self.app_project(owns_folder=True, exceptions=["Info.plist"], attached=False)
        self.assertEqual(["Config/env.xcconfig"], self.reported_paths(text, ("Config/env.xcconfig",)))

    def test_exception_set_for_another_target_does_not_count(self):
        other = (
            "\n\t\tTSX /* Test exceptions */ = {\n\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n"
            "\t\t\tmembershipExceptions = (\n\t\t\t\tConfig/env.xcconfig,\n"
            "\t\t\t\tConfig/env.example.xcconfig,\n\t\t\t);\n"
            "\t\t\ttarget = TST /* immichSlidesTests */;\n\t\t};"
        )
        text = self.app_project(owns_folder=True, exceptions=["Info.plist"], extra=other)
        # Another target's exceptions must neither count as stale app exceptions nor hide a config file.
        self.assertEqual([], guards.check_local_config_not_bundled(text))
        self.assertEqual(["Config/env.xcconfig"], self.reported_paths(text, ("Config/env.xcconfig",)))

    def test_other_local_config_file_is_reported_even_if_excluded(self):
        text = self.app_project(owns_folder=True, exceptions=["Config/env.xcconfig.bak"])
        self.assertEqual(["Config/env.xcconfig.bak"], self.reported_paths(text, ("Config/env.xcconfig.bak",)))

    def test_unowned_folder_listing_local_config_is_reported(self):
        text = self.app_project(owns_folder=False, exceptions=["Config/env.xcconfig", "Shared/App.swift"])
        self.assertEqual(["Config/env.xcconfig"], self.reported_paths(text, ("Config/env.xcconfig",)))

    def test_xcconfig_in_a_build_phase_is_reported(self):
        extra = (
            "\n\t\tBF1 /* env.xcconfig in Resources */ = {isa = PBXBuildFile; fileRef = REF /* env.xcconfig */; };"
            "\n\t\tREF /* env.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; "
            "path = immichSlides/Shared/env.xcconfig; sourceTree = \"<group>\"; };"
        )
        text = self.app_project(owns_folder=True, exceptions=["Info.plist"], extra=extra)
        violations = guards.check_local_config_not_bundled(text)
        self.assertEqual(["local-config-not-bundled"], [v.rule for v in violations])
        self.assertIn("immichSlides/Shared/env.xcconfig", violations[0].detail)

    def test_env_xcconfig_backup_in_app_root_is_found_on_disk(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / guards.PRODUCTION_DIR / "env.xcconfig.bak"
            path.parent.mkdir(parents=True)
            path.write_text("x", encoding="utf-8")
            self.assertEqual(("env.xcconfig.bak",), guards.local_config_files_on_disk(root))

    def test_missing_app_target_is_reported(self):
        self.assertEqual(["local-config-not-bundled"], [v.rule for v in guards.check_local_config_not_bundled("")])

    def test_files_under_config_and_stray_xcconfig_are_found_on_disk(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for relative in ("Config/env.xcconfig.bak", "Config/secrets.json", "Config/.DS_Store",
                             "Config/Local/notes.txt", "Shared/Extra.xcconfig.bak", "Shared/App.swift"):
                (root / guards.PRODUCTION_DIR / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / guards.PRODUCTION_DIR / relative).write_text("x", encoding="utf-8")
            self.assertEqual(("Config/Local/notes.txt", "Config/env.xcconfig.bak", "Config/secrets.json",
                              "Shared/Extra.xcconfig.bak"),
                             guards.local_config_files_on_disk(root))

    def test_repository_check_reports_a_stray_local_config_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / guards.PBXPROJ).parent.mkdir(parents=True)
            shutil.copy(REPO_ROOT / guards.PBXPROJ, root / guards.PBXPROJ)
            (root / guards.PRODUCTION_DIR / "Config").mkdir(parents=True)
            (root / guards.PRODUCTION_DIR / "env.xcconfig.bak").write_text("x", encoding="utf-8")
            violations = [v for v in guards.check_repository(root) if v.rule == "local-config-not-bundled"]
        self.assertEqual(["env.xcconfig.bak"], [v.detail.split(" is a local configuration under ")[0]
                                                 for v in violations])


class RepositoryTests(unittest.TestCase):
    def test_repository_passes_all_release_guards(self):
        violations = guards.check_repository(REPO_ROOT)
        self.assertEqual([], [str(v) for v in violations])

    def test_repository_actually_contains_guarded_markers_in_debug_regions(self):
        # Guards against the check passing only because it finds nothing to inspect.
        checked = 0
        for file in (REPO_ROOT / guards.PRODUCTION_DIR).rglob("*.swift"):
            source = file.read_text(encoding="utf-8")
            code = guards.mask_comments(source)
            for marker in guards.DEBUG_ONLY_MARKERS:
                checked += len(re.findall(re.escape(marker), code))
        self.assertGreater(checked, 20)

    def test_repository_pbxproj_backs_debug_with_optional_env_xcconfig(self):
        text = (REPO_ROOT / guards.PBXPROJ).read_text(encoding="utf-8")
        debug_config = (REPO_ROOT / guards.DEBUG_XCCONFIG).read_text(encoding="utf-8")
        blocks = re.findall(r"/\* (\w+) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;(.*?)\n\t\t\};", text, re.S)
        self.assertIn("Debug", [name for name, body in blocks if "Debug.xcconfig" in body])
        self.assertIn('#include? "env.xcconfig"', debug_config)
        self.assertIn("Release", [name for name, _ in blocks])

    def test_repository_app_target_builds_new_files_in_its_folder(self):
        # The docs promise that a new file under immichSlides/ joins the app target automatically.
        membership = guards.app_target_membership((REPO_ROOT / guards.PBXPROJ).read_text(encoding="utf-8"))
        self.assertIsNotNone(membership)
        self.assertTrue(membership.owns_folder)
        self.assertLessEqual(membership.exceptions, {"Info.plist", "PrivacyInfo.xcprivacy"})

    def test_repository_build_phase_parsing_finds_the_privacy_manifest(self):
        # Canary: if Xcode changes how it writes build files, the explicit-reference check would find nothing.
        text = (REPO_ROOT / guards.PBXPROJ).read_text(encoding="utf-8")
        paths = [path for _, path in guards.build_phase_file_paths(text)]
        self.assertIn("immichSlides/PrivacyInfo.xcprivacy", paths)


if __name__ == "__main__":
    unittest.main()
