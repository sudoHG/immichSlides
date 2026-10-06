"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations

from strict_e2e_p2_contract_test_fixtures import (
    Any,
    CACHE_CLEAR_REVIEW_CHECKS,
    DEVICES,
    FIXTURE,
    FROZEN_FIXTURE_SHA256,
    IMAGES,
    IMPLEMENTED_SWIFT_SUITES,
    LABEL_SHA256,
    MOVIE,
    ORIENTED_IMAGES,
    P2ContractError,
    P2_CASES,
    PLATFORM_GUARDS,
    PLATFORM_OF,
    Path,
    RAW_VERDICT,
    RECORDING_FILE,
    RECORDING_TIMING_FILE,
    REPO_ROOT,
    REVIEW_FILE,
    REVIEW_SCHEMA,
    SCRIPT_DIR,
    SOURCE_SHA,
    STEPS_FILE,
    STEPS_SCHEMA,
    UDID,
    _device,
    _facts,
    _fixture_data,
    _method_platforms,
    _move_step,
    _patch_json,
    _read_json,
    _rewrite_runner_report,
    _sha256,
    _verify,
    _write_json,
    _write_review,
    build_evidence,
    contract_main,
    device_class_of,
    hashlib,
    io,
    json,
    mock,
    os,
    p2_selector,
    re,
    read_xcresult_facts,
    require_official_execution,
    strict_e2e_p2_contract,
    subprocess,
    sys,
    tempfile,
    unittest,
    validate_raw_evidence,
    verify_evidence,
)

class P2CaseTableTestsCases:
    def test_every_case_maps_devices_to_platform_selectors_and_required_outputs(self) -> None:
        expected_devices = {
            "p2-exif": ("iphone", "ipad", "tv"),
            "p2-cache": ("iphone", "tv"),
            "p2-cache-smoke": ("ipad",),
            "p2-reduce-motion": ("iphone", "tv"),
            "p2-ipad-layout": ("ipad",),
            "p2-rotation": ("iphone", "ipad"),
            "p2-orientation-selfcheck": ("iphone",),
        }
        self.assertEqual({suite: case.devices for suite, case in P2_CASES.items()}, expected_devices)
        for suite, case in P2_CASES.items():
            with self.subTest(suite=suite):
                self.assertTrue(case.pngs)
                self.assertEqual(sorted(case.step_order), sorted((*case.pngs, *case.marks)))
                platforms = {PLATFORM_OF[device] for device in case.devices}
                self.assertEqual(set(case.selectors), platforms)
                for selector in case.selectors.values():
                    bundle, test_class, method = selector.split("/")
                    self.assertEqual(bundle, "immichSlidesUITests")
                    self.assertTrue(test_class.endswith("UITests"), selector)
                    self.assertNotIn("PlaybackSmartFillVisualUITests", selector)
                    self.assertTrue(method.startswith("test"), selector)
        self.assertTrue(P2_CASES["p2-reduce-motion"].video)
        self.assertTrue(P2_CASES["p2-rotation"].video)
        self.assertEqual(
            P2_CASES["p2-cache"].selectors,
            {
                "ios": "immichSlidesUITests/CacheSettingsUITests/testClearDiskCacheFromSettingsIOS",
                "tvos": "immichSlidesUITests/CacheSettingsUITests/testClearDiskCacheFromSettingsTVOS",
            },
        )
        self.assertEqual(
            P2_CASES["p2-cache"].pngs,
            ("cache-before-confirm", "cache-cleared", "cache-returned"),
        )
        self.assertTrue(P2_CASES["p2-cache"].cache_clear)
        self.assertFalse(P2_CASES["p2-cache-smoke"].cache_clear)
        self.assertTrue(P2_CASES["p2-cache-smoke"].cache_return)
        self.assertEqual(P2_CASES["p2-cache-smoke"].pngs, ("cache-page-smoke", "cache-returned"))
        self.assertEqual(P2_CASES["p2-cache-smoke"].e2e_ids, ())


    def test_selector_rejects_platform_outside_case(self) -> None:
        for suite, platform in (
            ("p2-ipad-layout", "tvos"),
            ("p2-rotation", "tvos"),
            ("p2-cache-smoke", "tvos"),
            ("p2-exif", "macos"),
            ("unknown", "ios"),
        ):
            with self.subTest(suite=suite, platform=platform), self.assertRaises(P2ContractError):
                p2_selector(suite, platform)


    def test_device_class_comes_only_from_official_simulator_model(self) -> None:
        self.assertEqual(device_class_of(_device("iphone")), "iphone")
        self.assertEqual(device_class_of(_device("ipad")), "ipad")
        self.assertEqual(device_class_of(_device("tv")), "tv")
        for device in (
            {"modelName": "iPhone 17 Pro", "platform": "iOS"},
            {"modelName": "Mac", "platform": "macOS"},
            {"modelName": "Apple TV 4K", "platform": "iOS Simulator"},
            {"platform": "iOS Simulator"},
        ):
            with self.subTest(device=device), self.assertRaises(P2ContractError):
                device_class_of(device)


class P2SwiftSelectorTestsCases:
    def test_implemented_selectors_resolve_to_one_platform_guarded_swift_method(self) -> None:
        self.assertEqual(sorted(IMPLEMENTED_SWIFT_SUITES), sorted(P2_CASES))
        for suite in IMPLEMENTED_SWIFT_SUITES:
            for platform, selector in P2_CASES[suite].selectors.items():
                with self.subTest(suite=suite, platform=platform):
                    bundle, test_class, method = selector.split("/")
                    source = (REPO_ROOT / bundle / f"{test_class}.swift").read_text(encoding="utf-8")
                    self.assertEqual(len(re.findall(rf"\bfinal class {test_class}: XCTestCase\b", source)), 1)
                    self.assertEqual(_method_platforms(source, method), [platform])


    def test_guard_reader_rejects_wrong_missing_or_ambiguous_platform(self) -> None:
        source = "#if os(iOS)\nfunc testA() {}\n#endif\nfunc testB() {}\n#if os(tvOS)\n#if DEBUG\nfunc testC() {}\n#endif\n#endif\n"
        self.assertEqual(_method_platforms(source, "testA"), ["ios"])
        self.assertEqual(_method_platforms(source, "testB"), [None])
        self.assertEqual(_method_platforms(source, "testC"), ["tvos"])
        self.assertEqual(_method_platforms(source, "testD"), [])
        with self.assertRaises(ValueError):
            _method_platforms("#if os(iOS)\n#else\nfunc testA() {}\n#endif\n", "testA")


class OfficialExecutionTestsCases:
    def test_exactly_the_selected_method_must_pass_on_the_destination_device(self) -> None:
        execution = require_official_execution(
            _facts("p2-exif", "ipad"), suite="p2-exif", platform="ios", simulator_udid=UDID
        )
        self.assertEqual(execution["executed_tests"], ["ExifToggleUITests/testExifToggleOwnershipIOS()"])
        self.assertEqual(execution["device"]["class"], "ipad")
        self.assertEqual(execution["device"]["os_version"], "26.4")


    def test_wrong_method_count_result_or_device_fails_closed(self) -> None:
        passing = _facts("p2-cache", "iphone")
        cases = {
            "old method impersonation": _facts("p2-cache", "iphone", identifier="CacheSettingsUITests/testOther()"),
            "missing parentheses is not an official identifier": _facts(
                "p2-cache", "iphone", identifier="CacheSettingsUITests/testClearCacheReloadsVisiblePhotoIOS"
            ),
            "old cache reload selector": _facts(
                "p2-cache", "iphone", identifier="CacheSettingsUITests/testClearCacheReloadsVisiblePhotoIOS()"
            ),
            "skipped": _facts("p2-cache", "iphone", result="Skipped"),
            "failed": _facts("p2-cache", "iphone", result="Failed"),
            "zero executions": {"test_cases": [], "devices": passing["devices"]},
            "two executions": {"test_cases": passing["test_cases"] * 2, "devices": passing["devices"]},
            "wrong bundle": {
                "test_cases": [dict(passing["test_cases"][0], bundle="immichSlidesTests")],
                "devices": passing["devices"],
            },
            "iPad impersonating iPhone for cache clear": _facts("p2-cache", "iphone", devices=[_device("ipad")]),
            "another simulator": _facts("p2-cache", "iphone", devices=[_device("iphone", "SIM-OTHER")]),
            "two devices": _facts("p2-cache", "iphone", devices=[_device("iphone"), _device("iphone")]),
            "tvOS device running the iOS selector": _facts("p2-cache", "iphone", devices=[_device("tv")]),
        }
        for label, facts in cases.items():
            with self.subTest(label=label), self.assertRaises(P2ContractError):
                require_official_execution(facts, suite="p2-cache", platform="ios", simulator_udid=UDID)


    def test_xcresult_reader_collects_test_cases_and_devices_from_official_json(self) -> None:
        official = {
            "devices": [_device("tv")],
            "testNodes": [
                {
                    "nodeType": "Test Plan",
                    "name": "immichSlides-tvOS",
                    "children": [
                        {
                            "nodeType": "UI test bundle",
                            "name": "immichSlidesUITests",
                            "children": [
                                {
                                    "nodeType": "Test Suite",
                                    "name": "ExifToggleUITests",
                                    "children": [
                                        {
                                            "nodeType": "Test Case",
                                            "name": "testExifToggleOwnershipTVOS()",
                                            "nodeIdentifier": "ExifToggleUITests/testExifToggleOwnershipTVOS()",
                                            "result": "Passed",
                                            "children": [{"nodeType": "Repetition", "name": "1"}],
                                        }
                                    ],
                                }
                            ],
                        }
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory() as raw_directory:
            bundle = Path(raw_directory) / "strict-p2-exif.xcresult"
            bundle.mkdir()

            def fake_run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
                self.assertEqual(command[:5], ["xcrun", "xcresulttool", "get", "test-results", "tests"])
                return subprocess.CompletedProcess(command, 0, json.dumps(official), "")

            facts = read_xcresult_facts(bundle, run=fake_run)
            self.assertEqual(
                facts["test_cases"],
                [
                    {
                        "bundle": "immichSlidesUITests",
                        "identifier": "ExifToggleUITests/testExifToggleOwnershipTVOS()",
                        "result": "Passed",
                    }
                ],
            )
            require_official_execution(facts, suite="p2-exif", platform="tvos", simulator_udid=UDID)

            for label, completed in (
                ("tool failure", subprocess.CompletedProcess([], 1, "", "boom")),
                ("empty output", subprocess.CompletedProcess([], 0, "", "")),
                ("not JSON", subprocess.CompletedProcess([], 0, "not json", "")),
            ):
                with self.subTest(label=label), self.assertRaises(P2ContractError):
                    read_xcresult_facts(bundle, run=lambda *_args, _c=completed, **_kw: _c)
        with self.assertRaises(P2ContractError):
            read_xcresult_facts(Path("/nonexistent/strict-p2-exif.xcresult"), run=fake_run)
