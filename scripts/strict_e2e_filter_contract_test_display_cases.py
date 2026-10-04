"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations

from strict_e2e_filter_contract_test_fixtures import (
    DISPLAY_POLICY_CANDIDATE_PREFIX,
    FILTER_VISUAL_SUITES,
    FROZEN_FIXTURE_SHA256,
    FilterContractError,
    Image,
    ImageFilter,
    ImageOps,
    PUBLIC_API_KEY,
    Path,
    RunningServer,
    SCRIPT_DIR,
    START_PLAYBACK_BUTTON_ID,
    _fixture_data,
    _fixture_png,
    _full_frame_transition,
    _side_by_side,
    _solid_png,
    _write_person_suite,
    _write_switch_display_bridge,
    album_selection_labels,
    assert_empty_selection_cannot_start,
    assert_final_pool_equals_union,
    assert_foreign_id_tokens_absent,
    assert_foreign_server_ids_absent,
    assert_playback_marks_in_target,
    assert_playback_marks_in_union,
    assert_request_log_contract,
    assert_solo_only_not_vacuous,
    classify_screenshot,
    evaluate_filter_visual_identity,
    fixture_manifest,
    io,
    json,
    load_member_manifest,
    member_manifest,
    person_selection_labels,
    require_photo_mark,
    subprocess,
    sys,
    tempfile,
    union_selection_labels,
    unittest,
    write_member_manifest,
)

class DeviceFilterVisualIdentityTestsCases:
    def test_filter_album_identity_comes_from_classify_screenshot_not_json(self) -> None:
        self.assertIn("filter-album", FILTER_VISUAL_SUITES)
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_pngs(
                evidence,
                [("album-play-1", "A1"), ("album-play-2", "A2"), ("album-play-3", "A3")],
            )
            (evidence / "visual-identity.json").write_text(
                json.dumps({"marks": ["A4", "A5", "A4"], "source": "swift_index"}),
                encoding="utf-8",
            )
            report = evaluate_filter_visual_identity(evidence, "filter-album")
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["marks"], ["A1", "A2", "A3"])
            self.assertEqual(report["identity_source"], "public_fixture_photo_mark")

            (evidence / "album-play-3.png").write_bytes(_fixture_png("A4"))
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "filter-album")
            self.assertIn("Unexpected members", str(raised.exception))

            self._write_pngs(
                evidence,
                [("album-play-1", "A1"), ("album-play-2", "A1"), ("album-play-3", "A2")],
            )
            repeated = evaluate_filter_visual_identity(evidence, "filter-album")
            self.assertEqual(repeated["verdict"], "PASS")
            self.assertEqual(repeated["marks"], ["A1", "A1", "A2"])

            (evidence / "album-play-1.png").unlink()
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "filter-album")
            self.assertIn("album-play-1.png", str(raised.exception))


    def test_filter_empty_selection_json_cannot_enable_start(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            write_member_manifest(evidence / "member-manifest.json", "a")
            payload = {
                "album_ids": [],
                "person_filters": [],
                "start_enabled": False,
                "start_button_id": START_PLAYBACK_BUTTON_ID,
            }
            (evidence / "empty-selection.json").write_text(json.dumps(payload), encoding="utf-8")
            report = evaluate_filter_visual_identity(evidence, "filter-empty")
            self.assertEqual(report["verdict"], "PASS")

            payload["start_enabled"] = True
            (evidence / "empty-selection.json").write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "filter-empty")
            self.assertIn("empty selection", str(raised.exception))


    def test_filter_empty_rejects_non_string_album_ids(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            write_member_manifest(evidence / "member-manifest.json", "a")
            (evidence / "empty-selection.json").write_text(
                json.dumps(
                    {
                        "album_ids": [1],
                        "person_filters": [],
                        "start_enabled": False,
                        "start_button_id": START_PLAYBACK_BUTTON_ID,
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "filter-empty")
            self.assertIn("album_ids", str(raised.exception))


    def test_filter_person_rejects_wins_and_trusts_png_marks(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_pngs(
                evidence,
                [
                    ("person-normal-1", "A1"),
                    ("person-conflict-normal-1", "A2"),
                    ("person-nofaces-1", "A4"),
                ],
            )
            (evidence / "person-results.json").write_text(
                json.dumps(
                    {
                        "cases": {
                            "solo_only": {"environment": "simulator", "verdict": "UNVERIFIED"},
                        }
                    }
                ),
                encoding="utf-8",
            )
            report = evaluate_filter_visual_identity(evidence, "filter-person")
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["normal_match"], "A1")
            self.assertEqual(report["conflict_normal"], "A2")
            self.assertEqual(report["no_faces"], "A4")
            self.assertEqual(report["solo_only_verdict"], "UNVERIFIED")
            self.assertNotIn("wins", report)

            (evidence / "person-results.json").write_text(
                json.dumps({"wins": "soloOnly", "cases": {}}),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "filter-person")
            self.assertIn("wins", str(raised.exception))

            self._write_pngs(
                evidence,
                [
                    ("person-normal-1", "A1"),
                    ("person-conflict-normal-1", "A2"),
                    ("person-nofaces-1", "A4"),
                ],
            )
            (evidence / "person-results.json").write_text(
                json.dumps({"cases": {"solo_only": {"environment": "simulator", "verdict": "PASS"}}}),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "filter-person")
            self.assertIn("device", str(raised.exception))


    def test_filter_switch_rejects_old_ids_and_classifies_b_playback(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            write_member_manifest(evidence / "member-manifest.json", "b")
            write_member_manifest(evidence / "member-manifest-a.json", "a")
            write_member_manifest(evidence / "member-manifest-b.json", "b")
            (evidence / "switch-b-play-1.png").write_bytes(_fixture_png("A1", "b"))
            (evidence / "switch-b-play-2.png").write_bytes(_fixture_png("A2", "b"))
            _write_switch_display_bridge(evidence)
            (evidence / "observed-ids.json").write_text(
                json.dumps({"ids": ["album-b-target", "person-b-normal", "asset-b-1"]}),
                encoding="utf-8",
            )
            (evidence / "request-log-b.log").write_text(
                "request elapsed_ms=1 method=GET path=/api/albums status=200 range=absent fixture_asset_id=asset-b-1\n",
                encoding="utf-8",
            )
            report = evaluate_filter_visual_identity(evidence, "filter-switch")
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["marks"], ["A1", "A2"])

            (evidence / "observed-ids.json").write_text(
                json.dumps({"ids": ["album-b-target", "album-a-target"]}),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "filter-switch")
            self.assertIn("Cross-server", str(raised.exception))


class DisplayPolicyVisualContractTestsCases:
    def test_fitted_foreground_does_not_hide_foreign_background_or_extra_photos(self) -> None:
        photo = Image.open(io.BytesIO(_fixture_png("A1"))).convert("RGB")
        foreign = Image.open(io.BytesIO(_fixture_png("A2"))).convert("RGB")
        scenes = {}
        scene = ImageOps.fit(foreign, (320, 696)).filter(ImageFilter.GaussianBlur(40))
        scene.paste(photo, (0, 258))
        scenes["foreign-blurred-background"] = scene
        scene = Image.new("RGB", (320, 696), (25, 25, 25))
        scene.paste(photo, (0, 258))
        scenes["unknown-surrounding-content"] = scene
        scene = ImageOps.fit(photo, (320, 696)).filter(ImageFilter.GaussianBlur(40))
        scene.paste(photo, (0, 258))
        texture = Image.new("RGB", (112, 112))
        texture.putdata([
            (value, value, value)
            for y in range(112) for x in range(112)
            for value in [30 if (x // 5 + y // 5) % 2 else 150]
        ])
        scene.paste(texture, (8, 100))
        scenes["unknown-texture-in-background"] = scene
        for texture_name, colors, stripes in (
            ("unknown-colored-texture", ((20, 80, 140), (140, 30, 90)), False),
            ("unknown-gray-stripes", ((30, 30, 30), (150, 150, 150)), True),
        ):
            scene = ImageOps.fit(photo, (320, 696)).filter(ImageFilter.GaussianBlur(40))
            scene.paste(photo, (0, 258))
            texture.putdata([colors[(x // 5 + (0 if stripes else y // 5)) % 2] for y in range(112) for x in range(112)])
            scene.paste(texture, (8, 100))
            scenes[texture_name] = scene
        for label, fixture_set in (("A2", "a"), ("A1", "a"), ("A1", "b")):
            scene = ImageOps.fit(photo, (320, 696)).filter(ImageFilter.GaussianBlur(40))
            scene.paste(photo, (0, 258))
            extra = Image.open(io.BytesIO(_fixture_png(label, fixture_set))).convert("RGB")
            scene.paste(ImageOps.fit(extra, (112, 112)), (8, 100))
            scenes[f"extra-{fixture_set}-{label}"] = scene
        for name, scene in scenes.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw_directory:
                buffer = io.BytesIO()
                scene.save(buffer, format="PNG")
                evidence = Path(raw_directory)
                self._write_evidence(
                    evidence,
                    before=_side_by_side(_fixture_png("A1"), _fixture_png("A2")),
                    after=buffer.getvalue(),
                )
                with self.assertRaises(FilterContractError):
                    evaluate_filter_visual_identity(evidence, "display-policy")


    def test_fitted_single_photo_does_not_count_blurred_background_as_another_photo(self) -> None:
        with Image.open(io.BytesIO(_fixture_png("A1"))) as photo:
            scene = ImageOps.fit(photo.convert("RGB"), (320, 696)).filter(ImageFilter.GaussianBlur(40))
            scene.paste(photo, (0, 258))
            buffer = io.BytesIO()
            scene.save(buffer, format="PNG")
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_evidence(
                evidence,
                before=_side_by_side(_fixture_png("A1"), _fixture_png("A2")),
                after=buffer.getvalue(),
            )
            report = evaluate_filter_visual_identity(evidence, "display-policy")
            self.assertEqual(report["after_mark"], "A1")


    @unittest.skipUnless(sys.platform == "darwin", "Swift/CoreGraphics candidate location is only verified on macOS")
    def test_swift_capture_candidate_recognizes_public_fit_without_rewriting_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            write_member_manifest(directory / "member-manifest.json", "a")
            main = directory / "main.swift"
            main.write_text('''import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let original = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let candidate = try StrictE2EFilterContract.displayCandidatePNG(original, evidenceDirectory: root)
let result = StrictE2EPhotoIdentity.classify(png: candidate)
print("\\(candidate != original)|\\(result.status.rawValue)|\\(result.mark ?? "nil")")
''', encoding="utf-8")
            executable = directory / "recognize"
            subprocess.run([
                "swiftc", str(SCRIPT_DIR.parent / "TestSupport/StrictE2EFilterContract.swift"),
                str(SCRIPT_DIR.parent / "TestSupport/StrictE2EPhotoIdentity.swift"), str(main), "-o", str(executable),
            ], check=True, capture_output=True, text=True)
            for fixture_set in ("a", "b"):
                with self.subTest(fixture_set=fixture_set):
                    photo = Image.open(io.BytesIO(_fixture_png("A1", fixture_set))).convert("RGB")
                    scene = ImageOps.fit(photo, (320, 696)).filter(ImageFilter.GaussianBlur(40))
                    scene.paste(photo, (0, 258))
                    path = directory / f"{fixture_set}-raw.png"
                    scene.save(path)
                    original = path.read_bytes()
                    result = subprocess.run([str(executable), str(directory), str(path)], check=True, capture_output=True, text=True)
                    self.assertEqual(result.stdout.strip(), "true|MATCH|A1")
                    self.assertEqual(path.read_bytes(), original)


    def test_smartfill_multi_to_single_requires_real_same_process_pngs(self) -> None:
        self.assertIn("display-policy", FILTER_VISUAL_SUITES)
        self.assertIn("tvos-display-policy", FILTER_VISUAL_SUITES)
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_evidence(
                evidence,
                before=_side_by_side(_fixture_png("A1"), _fixture_png("A2")),
                after=_fixture_png("A3"),
            )

            report = evaluate_filter_visual_identity(evidence, "display-policy")

            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["before_marks"], ["A1", "A2"])
            self.assertEqual(report["after_mark"], "A3")


    def test_display_policy_requires_same_live_process_and_bounded_candidate_rotation(self) -> None:
        before = _side_by_side(_fixture_png("A1"), _fixture_png("A2"))
        after = _fixture_png("A3")
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_evidence(evidence, before=before, after=after)
            payload = json.loads((evidence / "display-policy.json").read_text(encoding="utf-8"))
            payload["process_id_after"] = 45
            (evidence / "display-policy.json").write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "display-policy")
            self.assertIn("same App process remained alive", str(raised.exception))

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_evidence(evidence, before=before, after=after)
            payload = json.loads((evidence / "display-policy.json").read_text(encoding="utf-8"))
            payload["before_candidate_steps"] = [
                f"{DISPLAY_POLICY_CANDIDATE_PREFIX}{index:02d}" for index in range(1, 6)
            ]
            (evidence / "display-policy.json").write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "display-policy")
            self.assertIn("one complete finite rotation", str(raised.exception))


    def test_display_policy_rejects_non_multi_or_unstable_before_frame(self) -> None:
        invalid_frames = (
            ("single", _fixture_png("A1"), "The before-change frame must actually show at least two different photos"),
            (
                "transition",
                _full_frame_transition(_fixture_png("A1"), _fixture_png("A2")),
                "Multiple before-change photos cannot be faked by a transition",
            ),
            ("unknown", _solid_png((25, 25, 25)), "The before-change frame must be recognizable as a public fixture photo"),
        )
        for name, before, expected_error in invalid_frames:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                self._write_evidence(evidence, before=before, after=_fixture_png("A3"))

                with self.assertRaises(FilterContractError) as raised:
                    evaluate_filter_visual_identity(evidence, "display-policy")

                self.assertIn(expected_error, str(raised.exception))


    def test_display_policy_rejects_mixed_server_before_frame(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_evidence(
                evidence,
                before=_side_by_side(_fixture_png("A1", "a"), _fixture_png("A2", "b")),
                after=_fixture_png("A3"),
            )

            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "display-policy")

            self.assertIn("The before-change frame must contain only fixture A", str(raised.exception))


    def test_display_policy_rejects_multi_mixed_transition_and_unknown_after_frame(self) -> None:
        invalid_frames = (
            (
                "multi",
                _side_by_side(_fixture_png("A1"), _fixture_png("A2")),
                "The after-change frame must be a recognizable, stable single-photo frame",
            ),
            (
                "mixed_server",
                _side_by_side(_fixture_png("A1", "a"), _fixture_png("A2", "b")),
                "after-change frame must contain only target album photos from fixture A",
            ),
            (
                "transition",
                _full_frame_transition(_fixture_png("A1"), _fixture_png("A2")),
                "after-change cannot use a transition or unknown frame as passing",
            ),
            ("unknown", _solid_png((25, 25, 25)), "after-change cannot use a transition or unknown frame as passing"),
        )
        before = _side_by_side(_fixture_png("A1"), _fixture_png("A2"))
        for name, after, expected_error in invalid_frames:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                self._write_evidence(evidence, before=before, after=after)

                with self.assertRaises(FilterContractError) as raised:
                    evaluate_filter_visual_identity(evidence, "display-policy")

                self.assertIn(expected_error, str(raised.exception))


    def test_display_policy_rejects_declared_modes_without_real_ui_source(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_evidence(
                evidence,
                before=_side_by_side(_fixture_png("A1"), _fixture_png("A2")),
                after=_fixture_png("A3"),
                setting_source="probe",
            )

            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "display-policy")

            self.assertIn("Display strategy must be set through the real UI", str(raised.exception))


    def test_filter_vision_simulator_is_unverified_and_device_needs_face_count(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            write_member_manifest(evidence / "member-manifest.json", "a")
            (evidence / "vision-environment.json").write_text(
                json.dumps({"environment": "simulator", "vision_available": True}),
                encoding="utf-8",
            )
            report = evaluate_filter_visual_identity(evidence, "filter-vision")
            self.assertEqual(report["verdict"], "UNVERIFIED")

            (evidence / "vision-environment.json").write_text(
                json.dumps(
                    {
                        "environment": "device",
                        "vision_available": True,
                        "qualified_marks": ["A2"],
                        "face_counts": {"A2": 1},
                    }
                ),
                encoding="utf-8",
            )
            (evidence / "vision-solo-1.png").write_bytes(_fixture_png("A2"))
            report = evaluate_filter_visual_identity(evidence, "filter-vision")
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["mark"], "A2")

            (evidence / "vision-environment.json").write_text(
                json.dumps(
                    {
                        "environment": "device",
                        "vision_available": True,
                        "qualified_marks": ["A2"],
                        "face_counts": {"A2": 0},
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "filter-vision")
            self.assertIn("faces", str(raised.exception))

            for count in (True, None, "1"):
                with self.subTest(count=count):
                    (evidence / "vision-environment.json").write_text(
                        json.dumps(
                            {
                                "environment": "device",
                                "vision_available": True,
                                "qualified_marks": ["A2"],
                                "face_counts": {"A2": count},
                            }
                        ),
                        encoding="utf-8",
                    )
                    with self.assertRaises(FilterContractError) as raised:
                        evaluate_filter_visual_identity(evidence, "filter-vision")
                    self.assertIn("face_counts must contain only integers", str(raised.exception))


class AlbumEditSwitchVisualContractTestsCases:
    def test_normal_editor_switch_requires_filtered_mode_then_random_after_clear(self) -> None:
        for suite in ("filter-edit-switch", "tvos-edit-switch"):
            with self.subTest(suite=suite), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                self._write_valid_evidence(evidence)

                self.assertIn(suite, FILTER_VISUAL_SUITES)
                report = evaluate_filter_visual_identity(evidence, suite)

                self.assertEqual(report["verdict"], "PASS")
                self.assertEqual(report["mode_after_replace"], "filtered")
                self.assertEqual(report["mode_after_clear_and_exit"], "random")
                self.assertEqual(report["marks"], ["A4", "A5"])


    def test_reverting_album_to_target_photos_fails_the_non_target_counterfactual(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_valid_evidence(evidence)
            (evidence / "album-switch-b-play-1.png").write_bytes(_fixture_png("A1"))

            with self.assertRaises(FilterContractError):
                evaluate_filter_visual_identity(evidence, "filter-edit-switch")


    def test_mode_regression_and_unverifiable_mode_source_fail_closed(self) -> None:
        for source, after_replace, after_clear in (
            ("accessibility_ui", "random", "random"),
            ("accessibility_ui", "filtered", "filtered"),
            ("test_probe", "filtered", "random"),
        ):
            with self.subTest(source=source, after_replace=after_replace, after_clear=after_clear), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                self._write_valid_evidence(evidence)
                payload = {
                    "identity_source": source,
                    "selected_album_id_after_replace": "album-a-non-target",
                    "mode_after_replace": after_replace,
                    "mode_after_clear_and_exit": after_clear,
                }
                (evidence / "album-edit-modes.json").write_text(json.dumps(payload), encoding="utf-8")

                with self.assertRaises(FilterContractError):
                    evaluate_filter_visual_identity(evidence, "filter-edit-switch")


    def test_only_declared_non_target_album_identity_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_valid_evidence(evidence)
            (evidence / "album-switch-b-play-2.png").write_bytes(_fixture_png("B1", fixture_set="b"))

            with self.assertRaises(FilterContractError):
                evaluate_filter_visual_identity(evidence, "tvos-edit-switch")
