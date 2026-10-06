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

class RawEvidenceTestsCases:
    def test_complete_raw_evidence_is_only_ever_review_required(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            for suite, case in P2_CASES.items():
                device_class = case.devices[0]
                with self.subTest(suite=suite):
                    evidence = build_evidence(Path(raw_directory), suite, device_class)
                    payload = validate_raw_evidence(evidence, suite, "a")
                    self.assertEqual(payload["verdict"], RAW_VERDICT)
                    self.assertNotEqual(payload["verdict"], "PASS")
                    for png in case.pngs:
                        self.assertEqual(
                            payload["artifacts"][f"{png}.png"]["sha256"], _sha256(evidence / f"{png}.png")
                        )
                    if case.video:
                        self.assertIn(RECORDING_FILE, payload["artifacts"])
                    if case.cache_clear:
                        self.assertEqual(payload["cache_clear"], {"target_mark": "A3"})
                        self.assertFalse((evidence / "service.log").exists())


    def test_missing_empty_or_corrupt_required_png_fails(self) -> None:
        for label, mutate in (
            ("missing file", lambda path: path.unlink()),
            ("empty file", lambda path: path.write_bytes(b"")),
            ("not a PNG", lambda path: path.write_bytes(b"not-a-png")),
            ("zero-size PNG", lambda path: path.write_bytes(IMAGES["asset-a-3"][:16] + b"\x00" * 8)),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone", review=False)
                mutate(evidence / "exif-off.png")
                with self.assertRaises(P2ContractError) as raised:
                    validate_raw_evidence(evidence, "p2-exif", "a")
                self.assertIn("exif-off.png", str(raised.exception))


    def test_step_record_must_bind_every_required_png_and_mark(self) -> None:
        def drop_png_reference(steps: list[dict[str, Any]]) -> None:
            steps[0].pop("png")

        def duplicate_png_reference(steps: list[dict[str, Any]]) -> None:
            steps[1]["png"] = steps[0]["png"]

        def drop_mark(steps: list[dict[str, Any]]) -> None:
            steps[:] = [step for step in steps if step["name"] != "rotate-to-portrait"]

        def reverse_time(steps: list[dict[str, Any]]) -> None:
            steps[1]["wall_time"] = steps[0]["wall_time"] - 1

        def repeat_index(steps: list[dict[str, Any]]) -> None:
            steps[1]["index"] = steps[0]["index"]

        def wrong_orientation(steps: list[dict[str, Any]]) -> None:
            for step in steps:
                if step.get("png") == "rotation-landscape-stable.png":
                    step["orientation"] = "portrait"

        def unknown_orientation(steps: list[dict[str, Any]]) -> None:
            steps[0]["orientation"] = "faceUp"

        def missing_referenced_png(steps: list[dict[str, Any]]) -> None:
            steps.append(dict(steps[-1], index=99, wall_time=4000.0, name="extra", png="extra.png"))

        def non_finite_time(steps: list[dict[str, Any]]) -> None:
            steps[-1]["wall_time"] = "NaN"

        def outside_recording(steps: list[dict[str, Any]]) -> None:
            steps[-1]["wall_time"] = 6000.0

        for mutate in (
            drop_png_reference,
            duplicate_png_reference,
            drop_mark,
            reverse_time,
            repeat_index,
            wrong_orientation,
            unknown_orientation,
            missing_referenced_png,
            non_finite_time,
            outside_recording,
        ):
            with self.subTest(mutate=mutate.__name__), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-rotation", "iphone", review=False)
                payload = json.loads((evidence / STEPS_FILE).read_text(encoding="utf-8"))
                mutate(payload["steps"])
                _write_json(evidence / STEPS_FILE, payload)
                with self.assertRaises(P2ContractError):
                    validate_raw_evidence(evidence, "p2-rotation", "a")

        for label, suite, mutate_evidence in (
            ("rotation before the initial portrait frame", "p2-rotation", lambda evidence: _move_step(evidence, "rotate-to-landscape", 0)),
            (
                "Reduce Motion enabled before the off-state observation",
                "p2-reduce-motion",
                lambda evidence: _move_step(evidence, "motion-system-enabled", 1),
            ),
            (
                "portrait frame pixels are landscape",
                "p2-rotation",
                lambda evidence: (evidence / "rotation-start-portrait.png").write_bytes(ORIENTED_IMAGES["landscape"]),
            ),
            (
                "landscape frame is square",
                "p2-ipad-layout",
                lambda evidence: (evidence / "layout-landscape-multi.png").write_bytes(IMAGES["asset-a-3"]),
            ),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), suite, P2_CASES[suite].devices[-1], review=False)
                mutate_evidence(evidence)
                with self.assertRaises(P2ContractError):
                    validate_raw_evidence(evidence, suite, "a")

        for label, mutate_file in (
            ("missing steps file", lambda path: path.unlink()),
            ("empty steps file", lambda path: path.write_text("", encoding="utf-8")),
            ("wrong schema", lambda path: _patch_json(path, schema="other")),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-exif", "tv", review=False)
                mutate_file(evidence / STEPS_FILE)
                with self.assertRaises(P2ContractError):
                    validate_raw_evidence(evidence, "p2-exif", "a")


    def test_video_cases_require_finalized_recording_and_timing(self) -> None:
        for label, mutate in (
            ("missing recording", lambda evidence: (evidence / RECORDING_FILE).unlink()),
            ("empty recording", lambda evidence: (evidence / RECORDING_FILE).write_bytes(b"")),
            ("unfinalized recording", lambda evidence: (evidence / RECORDING_FILE).write_bytes(MOVIE[:-8])),
            ("missing recording timing", lambda evidence: (evidence / RECORDING_TIMING_FILE).unlink()),
            (
                "recording times reversed",
                lambda evidence: _patch_json(evidence / RECORDING_TIMING_FILE, stopped_wall_time=800.0),
            ),
            ("recording stop exit code is not 0", lambda evidence: _patch_json(evidence / RECORDING_TIMING_FILE, stop_exit=1)),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-reduce-motion", "tv", review=False)
                mutate(evidence)
                with self.assertRaises(P2ContractError):
                    validate_raw_evidence(evidence, "p2-reduce-motion", "a")


class CacheClearTestsCases:
    def test_cache_clear_accepts_ui_evidence_without_network_log(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
            self.assertFalse((evidence / "service.log").exists())
            payload = validate_raw_evidence(evidence, "p2-cache", "a")
            self.assertEqual(payload["cache_clear"], {"target_mark": "A3"})


    def test_cache_before_confirm_is_not_identity_classified(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
            (evidence / "cache-before-confirm.png").write_bytes(IMAGES["asset-a-4"])
            payload = validate_raw_evidence(evidence, "p2-cache", "a")
            self.assertEqual(payload["cache_clear"], {"target_mark": "A3"})


    def test_cache_settings_frames_must_be_decodable_png(self) -> None:
        for name in ("cache-before-confirm.png", "cache-cleared.png"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
                (evidence / name).write_bytes(IMAGES["asset-a-3"][:24])
                with self.assertRaisesRegex(P2ContractError, "cannot be fully decoded"):
                    validate_raw_evidence(evidence, "p2-cache", "a")


    def test_returned_frame_must_show_a_recognized_public_photo(self) -> None:
        for suite, device in (("p2-cache", "iphone"), ("p2-cache-smoke", "ipad")):
            with self.subTest(suite=suite), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), suite, device, review=False)
                returned = evidence / "cache-returned.png"
                returned.write_bytes(IMAGES["asset-a-4"])
                payload = validate_raw_evidence(evidence, suite, "a")
                key = "cache_clear" if suite == "p2-cache" else "cache_return"
                self.assertEqual(payload[key], {"target_mark": "A4"})
                # A fully decodable black frame must fail identity, independently of PNG framing.
                from PIL import Image
                Image.new("RGB", (320, 180), "black").save(returned)
                with self.assertRaises(P2ContractError):
                    validate_raw_evidence(evidence, suite, "a")
                returned.unlink()
                with self.assertRaises(P2ContractError):
                    validate_raw_evidence(evidence, suite, "a")

        for label, returned, expected_mark in (
            ("returned frame shows another public photo", IMAGES["asset-a-4"], "A4"),
            ("returned frame is unrecognizable", b"\x89PNG\r\n\x1a\n" + b"\x00" * 64, None),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
                (evidence / "cache-returned.png").write_bytes(returned)
                if expected_mark is None:
                    with self.assertRaises(P2ContractError):
                        validate_raw_evidence(evidence, "p2-cache", "a")
                else:
                    payload = validate_raw_evidence(evidence, "p2-cache", "a")
                    self.assertEqual(payload["cache_clear"], {"target_mark": expected_mark})


    def test_legacy_before_clear_png_name_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
            (evidence / "cache-before-confirm.png").rename(evidence / "cache-before-clear.png")
            with self.assertRaisesRegex(P2ContractError, "cache-before-confirm.png"):
                validate_raw_evidence(evidence, "p2-cache", "a")


    def test_cache_screenshot_steps_must_keep_the_required_order(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache-smoke", "ipad", review=False)
            _move_step(evidence, "cache-returned", 0)
            with self.assertRaisesRegex(P2ContractError, "Step order must be"):
                validate_raw_evidence(evidence, "p2-cache-smoke", "a")

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone", review=False)
            _move_step(evidence, "cache-cleared", 0)
            with self.assertRaisesRegex(P2ContractError, "Step order must be"):
                validate_raw_evidence(evidence, "p2-cache", "a")


    def test_cache_clear_pass_requires_image_bound_manual_checks(self) -> None:
        mutations = (
            ("cache-before-confirm.png", "disk_usage_nonzero_before_confirm", None),
            ("cache-cleared.png", "disk_usage_zero_after_clear", "PARTIAL"),
            ("cache-cleared.png", "success_feedback_visible", None),
            ("cache-returned.png", "playback_normal_after_return", "NEEDS_HUMAN_REVIEW"),
        )
        for image_name, check_name, value in mutations:
            with self.subTest(image=image_name, check=check_name), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-cache", "iphone")
                review = _read_json(evidence / REVIEW_FILE)
                checks = review["artifacts"][image_name]["checks"]
                if value is None:
                    checks.pop(check_name)
                else:
                    checks[check_name] = value
                _write_json(evidence / REVIEW_FILE, review)
                with self.assertRaises(P2ContractError):
                    _verify(evidence, "p2-cache", "iphone")


class VerifyGateTestsCases:
    def test_sanitized_official_export_replaces_credential_bearing_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone")
            _bundle, test_class, method = p2_selector("p2-exif", "ios").split("/")
            payload = {
                "testNodes": [{
                    "nodeType": "UI test bundle",
                    "name": "immichSlidesUITests",
                    "children": [{
                        "nodeType": "Test Case",
                        "nodeIdentifier": f"{test_class}/{method}()",
                        "result": "Passed",
                    }],
                }],
                "devices": [_device("iphone")],
            }
            exported = evidence / "official-tests.json"
            _write_json(exported, payload)
            digest = _sha256(exported)
            _patch_json(evidence / "case-manifest.json", official_tests_sha256=digest)
            _write_json(evidence / "result-bundle-disposal.json", {"official_tests_sha256": digest, "result_bundle_disposed": True})
            (evidence / "strict-p2-exif.xcresult").rmdir()
            self.assertEqual(
                verify_evidence(evidence, suite="p2-exif", device_class="iphone", expected_sha=SOURCE_SHA)["verdict"],
                "PASS",
            )
            exported.write_text(exported.read_text(encoding="utf-8") + " ", encoding="utf-8")
            with self.assertRaises(P2ContractError):
                verify_evidence(evidence, suite="p2-exif", device_class="iphone", expected_sha=SOURCE_SHA)


    def test_signed_complete_evidence_passes_for_every_case_and_device(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            for suite, case in P2_CASES.items():
                for device_class in case.devices:
                    with self.subTest(suite=suite, device_class=device_class):
                        evidence = build_evidence(Path(raw_directory), suite, device_class)
                        result = _verify(evidence, suite, device_class)
                        self.assertEqual(result["verdict"], "PASS")
                        self.assertEqual(result["source_sha"], SOURCE_SHA)
                        self.assertEqual(result["device"]["class"], device_class)


    def test_unsigned_evidence_never_passes_even_with_review_environment(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone", review=False)
            with mock.patch.dict(
                os.environ,
                {"REVIEWED_PASS": "1", "STRICT_E2E_REVIEWED_PASS": "1", "TEST_RUNNER_REVIEWED_PASS": "1"},
            ), self.assertRaises(P2ContractError) as raised:
                _verify(evidence, "p2-exif", "iphone")
            self.assertIn("Missing sign-off", str(raised.exception))


    def test_review_bound_to_other_evidence_or_stale_hash_fails(self) -> None:
        def modify_png(evidence: Path) -> None:
            (evidence / "rotation-landscape-stable.png").write_bytes(IMAGES["asset-a-1"])
            _rewrite_runner_report(evidence, "p2-rotation")

        def modify_video(evidence: Path) -> None:
            (evidence / RECORDING_FILE).write_bytes(MOVIE + b"\x00\x00\x00\x08free")
            _rewrite_runner_report(evidence, "p2-rotation")

        def uncovered_mark(evidence: Path) -> None:
            payload = json.loads((evidence / REVIEW_FILE).read_text(encoding="utf-8"))
            payload["artifacts"][RECORDING_FILE]["time_slices"] = payload["artifacts"][RECORDING_FILE]["time_slices"][:1]
            _write_json(evidence / REVIEW_FILE, payload)

        def drop_video_entry(evidence: Path) -> None:
            payload = json.loads((evidence / REVIEW_FILE).read_text(encoding="utf-8"))
            del payload["artifacts"][RECORDING_FILE]
            _write_json(evidence / REVIEW_FILE, payload)

        def patch_entry(**changes: Any):
            def mutate(evidence: Path) -> None:
                payload = json.loads((evidence / REVIEW_FILE).read_text(encoding="utf-8"))
                payload["artifacts"]["rotation-start-portrait.png"].update(changes)
                _write_json(evidence / REVIEW_FILE, payload)

            return mutate

        def patch_slices(slices: object):
            def mutate(evidence: Path) -> None:
                payload = json.loads((evidence / REVIEW_FILE).read_text(encoding="utf-8"))
                payload["artifacts"][RECORDING_FILE]["time_slices"] = slices
                _write_json(evidence / REVIEW_FILE, payload)

            return mutate

        cases = {
            "image changed after sign-off": modify_png,
            "recording changed after sign-off": modify_video,
            "sign-off omits the recording": drop_video_entry,
            "sign-off bound to the wrong suite": lambda evidence: _patch_json(evidence / REVIEW_FILE, suite="p2-exif"),
            "sign-off bound to the wrong device": lambda evidence: _patch_json(evidence / REVIEW_FILE, device_class="ipad"),
            "sign-off bound to the wrong candidate": lambda evidence: _patch_json(evidence / REVIEW_FILE, source_sha="f" * 40),
            "wrong sign-off schema": lambda evidence: _patch_json(evidence / REVIEW_FILE, schema="other"),
            "no reviewer": lambda evidence: _patch_json(evidence / REVIEW_FILE, reviewer=""),
            "unknown overall verdict": lambda evidence: _patch_json(evidence / REVIEW_FILE, verdict="LOOKS_OK"),
            "empty observation": patch_entry(observation=""),
            "unknown per-item conclusion": patch_entry(conclusion="OK"),
            "wrong pattern fixture hash": patch_entry(fixture_sha256={"A3": "0" * 64}),
            "pattern is not a public mark": patch_entry(visible_marks=["Z9"], fixture_sha256={"Z9": "0" * 64}),
            "missing control bar state": patch_entry(controls=""),
            "recording has no time slices": patch_slices([]),
            "time slices miss the rotate-back-to-portrait mark": uncovered_mark,
            "time slice reversed": patch_slices([{"start_s": 5, "end_s": 1, "observation": "x", "conclusion": "PASS"}]),
            "empty sign-off file": lambda evidence: (evidence / REVIEW_FILE).write_text("", encoding="utf-8"),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-rotation", "iphone")
                mutate(evidence)
                with self.assertRaises(P2ContractError):
                    _verify(evidence, "p2-rotation", "iphone")


    def test_runner_record_cleanup_and_manifest_types_fail_closed(self) -> None:
        def replace_after_run_and_resign(evidence: Path) -> None:
            (evidence / "exif-off.png").write_bytes(IMAGES["asset-a-1"])
            _write_review(evidence, "p2-exif", "iphone")

        def edit_steps_after_run(evidence: Path) -> None:
            payload = json.loads((evidence / STEPS_FILE).read_text(encoding="utf-8"))
            payload["steps"][0]["name"] = "exif-full-on"
            payload["steps"][0]["wall_time"] = 1000.5
            _write_json(evidence / STEPS_FILE, payload)

        cases = {
            "image replaced after the run and re-signed": replace_after_run_and_resign,
            "step record edited after the run": edit_steps_after_run,
            "missing runner report": lambda evidence: (evidence / "visual-identity-runner.json").unlink(),
            "runner report changed to PASS": lambda evidence: _patch_json(evidence / "visual-identity-runner.json", verdict="PASS"),
            "runner cleanup failed": lambda evidence: _write_json(evidence / "cleanup-failures.json", {"failures": ["x"]}),
            "fixture_set is not a string": lambda evidence: _patch_json(evidence / "case-manifest.json", fixture_set=["a"]),
            "fixture service is not the normal scenario": lambda evidence: _patch_json(evidence / "case-manifest.json", scenario="timeout"),
            "runner report suite changed": lambda evidence: _patch_json(evidence / "visual-identity-runner.json", suite="p2-cache"),
            "runner report has extra records": lambda evidence: _patch_json(evidence / "visual-identity-runner.json", mark_offsets={}),
            "sensitive scan PASS but lists matched files": lambda evidence: _patch_json(evidence / "sensitive-scan.json", matched_files=["x"]),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone")
                mutate(evidence)
                with self.assertRaises(P2ContractError):
                    _verify(evidence, "p2-exif", "iphone")


    def test_non_pass_review_is_reported_and_inconsistent_pass_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-ipad-layout", "ipad")
            _write_review(evidence, "p2-ipad-layout", "ipad", verdict="PARTIAL", conclusion="PARTIAL")
            self.assertEqual(_verify(evidence, "p2-ipad-layout", "ipad")["verdict"], "PARTIAL")
            _write_review(evidence, "p2-ipad-layout", "ipad", verdict="PASS", conclusion="NEEDS_HUMAN_REVIEW")
            with self.assertRaises(P2ContractError):
                _verify(evidence, "p2-ipad-layout", "ipad")


    def test_wrong_device_or_version_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            exif = build_evidence(Path(raw_directory), "p2-exif", "iphone")
            layout = build_evidence(Path(raw_directory), "p2-ipad-layout", "ipad")
            cases = {
                "iPhone directory holds an iPad official result": (exif, "p2-exif", "iphone", {"facts": _facts("p2-exif", "ipad")}),
                "device class not allowed for this suite": (layout, "p2-ipad-layout", "ipad", {"check_device_class": "iphone"}),
                "candidate SHA mismatch": (exif, "p2-exif", "iphone", {"expected_sha": "f" * 40}),
                "candidate SHA is not the full 40 characters": (exif, "p2-exif", "iphone", {"expected_sha": SOURCE_SHA[:12]}),
            }
            for label, (evidence, suite, device_class, overrides) in cases.items():
                with self.subTest(label=label), self.assertRaises(P2ContractError):
                    _verify(evidence, suite, device_class, **overrides)


    def test_manifest_version_run_state_and_scan_fail_closed(self) -> None:
        cases = {
            "workspace dirty at run time": {"source_dirty_paths": [" M scripts/run_strict_e2e.py"]},
            "workspace state not recorded": {"source_dirty_paths": None},
            "manifest SHA differs from sign-off": {"source_sha": "e" * 40},
            "manifest is for another suite": {"suite": "p2-cache"},
            "runner did not succeed": {"result": "FAILED", "exit_code": 65},
            "fixture hash changed": {"fixture_sha256": "0" * 64},
            "unknown fixture set": {"fixture_set": "z"},
            "destination has no UDID": {"destination": "platform=iOS Simulator,name=iPhone"},
        }
        for label, changes in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone")
                _patch_json(evidence / "case-manifest.json", **changes)
                with self.assertRaises(P2ContractError):
                    _verify(evidence, "p2-exif", "iphone")
        for label, mutate in (
            ("missing manifest", lambda evidence: (evidence / "case-manifest.json").unlink()),
            ("missing official xcresult", lambda evidence: (evidence / "strict-p2-exif.xcresult").rmdir()),
            ("missing sensitive scan", lambda evidence: (evidence / "sensitive-scan.json").unlink()),
            ("sensitive scan FAIL", lambda evidence: _patch_json(evidence / "sensitive-scan.json", result="FAIL")),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw_directory:
                evidence = build_evidence(Path(raw_directory), "p2-exif", "iphone")
                mutate(evidence)
                with self.assertRaises(P2ContractError):
                    _verify(evidence, "p2-exif", "iphone")


class VerifyCommandLineTestsCases:
    def test_exit_codes_distinguish_pass_reviewed_non_pass_and_contract_failure(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = build_evidence(Path(raw_directory), "p2-cache", "tv")
            facts = _facts("p2-cache", "tv")
            code, stdout, _ = self._run(evidence, "p2-cache", "tv", facts)
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(stdout)["verdict"], "PASS")

            _write_review(evidence, "p2-cache", "tv", verdict="NEEDS_HUMAN_REVIEW", conclusion="NEEDS_HUMAN_REVIEW")
            code, stdout, _ = self._run(evidence, "p2-cache", "tv", facts)
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(stdout)["verdict"], "NEEDS_HUMAN_REVIEW")

            (evidence / REVIEW_FILE).unlink()
            code, stdout, stderr = self._run(evidence, "p2-cache", "tv", facts)
            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("Missing sign-off", stderr)
            self.assertNotIn("Traceback", stderr)
