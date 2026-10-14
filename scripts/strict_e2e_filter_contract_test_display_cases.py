"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations

from access_lifecycle_contract_test_fixtures import IPAD_SCREEN
from test_album_server_narrow_contract import (
    IPHONE_SCREEN, TV_SCREEN, UNMEASURED_SCREEN, _cover, _full_screen, _iphone_control_split_frame,
    _letterbox, _stacked_album_frame, _unmeasured_album_frame, _with_home_indicator,
)
from strict_e2e_photo_identity import (
    IdentityAssertionError, public_frame_photos_from_bytes, public_frame_slot_count_from_bytes,
    public_letter_from_bytes,
)

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
    def test_filter_album_unmeasured_geometry_keeps_the_main_result(self) -> None:
        for fixture_set in ("a", "b"):
            for shape, frame in (
                ("home indicator", _unmeasured_album_frame(fixture_set)),
                ("letterbox", _letterbox(_fixture_png("A3", fixture_set), UNMEASURED_SCREEN)),
            ):
                with self.subTest(fixture_set=fixture_set, shape=shape), tempfile.TemporaryDirectory() as raw:
                    evidence = Path(raw)
                    self._write_pngs(evidence, [("album-play-1", "A1"), ("album-play-2", "A2"), ("album-play-3", "A3")], fixture_set)
                    self.assertEqual(Image.open(io.BytesIO(frame)).size, UNMEASURED_SCREEN)
                    identity = classify_screenshot(frame)
                    mark = require_photo_mark("public_fixture_photo_mark", identity.status, identity.mark)
                    self.assertEqual(mark, "A3")
                    (evidence / "album-play-1.png").write_bytes(frame)
                    report = evaluate_filter_visual_identity(evidence, "filter-album")
                    self.assertEqual(report["marks"], [mark, "A2", "A3"])
                    self.assertEqual(report["target_album_geometry"], "unmeasured")
                    self.assertEqual(report["target_album_frame_geometry"], {
                        name: "unmeasured" for name in ("album-play-1", "album-play-2", "album-play-3")})
        for screen in (IPHONE_SCREEN, IPAD_SCREEN):
            with self.subTest(measured_screen=screen), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                self._write_pngs(evidence, [("album-play-1", "A1"), ("album-play-2", "A2"), ("album-play-3", "A3")])
                frame = _letterbox(_fixture_png("A3"), screen)
                self.assertEqual(classify_screenshot(frame).status, "MATCH")
                (evidence / "album-play-1.png").write_bytes(frame)
                with self.assertRaisesRegex(FilterContractError, "does not match.*blurred background"):
                    evaluate_filter_visual_identity(evidence, "filter-album")

    def test_filter_album_single_slot_zoomed_glyph_keeps_the_main_result(self) -> None:
        from strict_e2e_filter_contract import TARGET_ALBUM_GLYPH_OVERLAY_BOXES
        for fixture_set in ("a", "b"):
            with self.subTest(fixture_set=fixture_set), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                self._write_pngs(evidence, [("album-play-1", "A1"), ("album-play-2", "A2"), ("album-play-3", "A3")], fixture_set)
                frame = _full_screen("A1", IPHONE_SCREEN, fixture_set)
                self.assertEqual(Image.open(io.BytesIO(frame)).size, IPHONE_SCREEN)
                identity = classify_screenshot(frame)
                mark = require_photo_mark("public_fixture_photo_mark", identity.status, identity.mark)
                self.assertEqual(mark, "A1")
                self.assertEqual(public_frame_slot_count_from_bytes(frame), 1)
                with self.assertRaises(IdentityAssertionError):
                    public_frame_photos_from_bytes(frame, glyph_overlay_box=TARGET_ALBUM_GLYPH_OVERLAY_BOXES[IPHONE_SCREEN])
                (evidence / "album-play-1.png").write_bytes(frame)
                report = evaluate_filter_visual_identity(evidence, "filter-album")
                self.assertEqual(report["marks"], [mark, "A2", "A3"])
                self.assertEqual(report["target_album_geometry"], "unmeasured")
                self.assertEqual(report["target_album_frame_geometry"], {
                    "album-play-1": "measured", "album-play-2": "unmeasured", "album-play-3": "unmeasured"})

    def test_filter_album_control_bar_gap_cannot_join_different_glyphs(self) -> None:
        for fixture_set in ("a", "b"):
            with self.subTest(fixture_set=fixture_set), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                self._write_pngs(evidence, [("album-play-1", "A1"), ("album-play-2", "A2"), ("album-play-3", "A3")], fixture_set)
                (evidence / "album-play-1.png").write_bytes(_iphone_control_split_frame(fixture_set))
                self.assertEqual(evaluate_filter_visual_identity(evidence, "filter-album")["marks"], ["A2", "A1", "A2", "A3"])
                for case in ("foreign_bottom_half", "outside_gap"):
                    with self.subTest(case=case):
                        invalid = _iphone_control_split_frame(fixture_set, **{case: True})
                        self.assertEqual(classify_screenshot(invalid).status, "MATCH")
                        (evidence / "album-play-1.png").write_bytes(invalid)
                        with self.assertRaises(FilterContractError):
                            evaluate_filter_visual_identity(evidence, "filter-album")

    def test_filter_album_system_ink_exclusion_keeps_footer_photo_patches_visible(self) -> None:
        for fixture_set, screen in (
            ("a", IPAD_SCREEN), ("a", IPHONE_SCREEN), ("b", IPAD_SCREEN), ("b", IPHONE_SCREEN),
        ):
            with self.subTest(fixture_set=fixture_set, screen=screen), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                self._write_pngs(evidence, [("album-play-1", "A1"), ("album-play-2", "A2"), ("album-play-3", "A3")], fixture_set)
                photo = _stacked_album_frame(fixture_set) if screen == IPAD_SCREEN else _full_screen("A3", screen, fixture_set)
                (evidence / "album-play-1.png").write_bytes(_with_home_indicator(photo))
                expected = ["A1", "A3", "A2", "A3"] if screen == IPAD_SCREEN else ["A3", "A2", "A3"]
                self.assertEqual(evaluate_filter_visual_identity(evidence, "filter-album")["marks"], expected)
                for patch_fixture in (fixture_set, "b" if fixture_set == "a" else "a"):
                    with self.subTest(patch_fixture=patch_fixture):
                        (evidence / "album-play-1.png").write_bytes(
                            _with_home_indicator(photo, patch_fixture))
                        with self.assertRaises(FilterContractError):
                            evaluate_filter_visual_identity(evidence, "filter-album")

    def test_filter_album_reads_every_slot_in_real_size_stacked_target_frames(self) -> None:
        for fixture_set in ("a", "b"):
            with self.subTest(fixture_set=fixture_set), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                self._write_pngs(evidence, [("album-play-1", "A1"), ("album-play-2", "A2"), ("album-play-3", "A3")], fixture_set)
                stacked = _stacked_album_frame(fixture_set)
                self.assertEqual(Image.open(io.BytesIO(stacked)).size, IPAD_SCREEN)
                self.assertNotEqual(classify_screenshot(stacked).status, "MATCH")
                (evidence / "album-play-1.png").write_bytes(stacked)
                for name, mark in (("album-play-2", "A2"), ("album-play-3", "A3")):
                    (evidence / f"{name}.png").write_bytes(_full_screen(mark, IPAD_SCREEN, fixture_set))
                report = evaluate_filter_visual_identity(evidence, "filter-album")
                self.assertEqual(report["verdict"], "PASS")
                self.assertEqual(report["marks"], ["A1", "A3", "A2", "A3"])
                self.assertEqual(report["target_album_geometry"], "measured")
                self.assertEqual(report["target_album_frame_geometry"], {
                    name: "measured" for name in ("album-play-1", "album-play-2", "album-play-3")})

    def test_filter_album_rejects_wrong_or_unreadable_stacked_slots(self) -> None:
        for fixture_set, other in (("a", "b"), ("b", "a")):
            with self.subTest(fixture_set=fixture_set), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                self._write_pngs(evidence, [("album-play-1", "A1"), ("album-play-2", "A2"), ("album-play-3", "A3")], fixture_set)
                for case, frame in (
                    ("wrong album", _stacked_album_frame(fixture_set, top_mark="A4")),
                    ("mixed fixture", _stacked_album_frame(fixture_set, top_fixture=other)),
                    ("other fixture", _stacked_album_frame(other)),
                    ("unreadable slot", _stacked_album_frame(fixture_set, unreadable_top=True)),
                    ("unreadable foreign slot", _stacked_album_frame(fixture_set, top_fixture=other, unreadable_top=True)),
                ):
                    with self.subTest(case=case):
                        (evidence / "album-play-1.png").write_bytes(frame)
                        with self.assertRaises(FilterContractError):
                            evaluate_filter_visual_identity(evidence, "filter-album")

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
    def test_tv_switch_requires_every_slot_in_both_orientations_to_match_the_album(self) -> None:
        from test_strict_e2e_photo_identity import FrameGlyphBoundaryTests
        for fixture_set in ("a", "b"):
            other = "b" if fixture_set == "a" else "a"
            for horizontal in (False, True):
                with self.subTest(fixture=fixture_set, horizontal=horizontal), tempfile.TemporaryDirectory() as raw:
                    evidence = Path(raw)
                    self._write_valid_evidence(evidence, fixture_set)
                    positive = FrameGlyphBoundaryTests._pair(fixture_set, 4, 5, horizontal=horizontal)
                    (evidence / "album-switch-b-play-1.png").write_bytes(positive)
                    self.assertEqual(evaluate_filter_visual_identity(evidence, "tvos-edit-switch")["verdict"], "PASS")
                    for case, first, source, options in (("wrong album", 1, fixture_set, {}),
                                                        ("other fixture", 4, other, {}),
                                                        ("mixed", 4, fixture_set, {"second_fixture": other}),
                                                        ("unreadable", 4, fixture_set, {"unreadable": True})):
                        with self.subTest(case=case):
                            frame = FrameGlyphBoundaryTests._pair(source, first, 5, horizontal=horizontal, **options)
                            (evidence / "album-switch-b-play-1.png").write_bytes(frame)
                            with self.assertRaises(FilterContractError):
                                evaluate_filter_visual_identity(evidence, "tvos-edit-switch")

    def _render_edit_switch_frame(self, fixture_set: str, shape: str, index: int = 4, second_fixture: str | None = None,
                                 unreadable_top: str = "") -> bytes:
        def photo(number: int, source: str = fixture_set):
            return Image.open(io.BytesIO(_fixture_png(f"A{number}", source))).convert("RGB")

        if shape == "stacked":
            # Release iPhone capture: the seam is at y=780 on a 1170x2532 screen.
            frame = Image.new("RGB", IPHONE_SCREEN)
            top = photo(index)
            if unreadable_top:
                from PIL import ImageDraw
                # Remove the letter or whole label while retaining the photo colors.
                cell = max(8, min(top.width // 18, top.height // 10))
                left, y = (top.width - 11 * cell) // 2, (top.height - 7 * cell) // 2
                columns = 5 if unreadable_top == "letter" else 11
                ImageDraw.Draw(top).rectangle((left, y, left + columns * cell - 1, y + 7 * cell - 1), fill=top.getpixel((0, 0)))
            frame.paste(_cover(top, (1170, 780)), (0, 0))
            frame.paste(_cover(photo(5, second_fixture or fixture_set), (1170, 1752)), (0, 780))
        else:
            size = IPAD_SCREEN if shape == "ipad-crop" else TV_SCREEN if shape == "tv" else IPHONE_SCREEN
            frame = _cover(photo(index), size)
            if shape == "ipad-crop":
                # Release 1640x2360 A4 capture: sampled glyph band y=145..546,
                # letter origin about -72 at width 480. A 16px rightward pan of
                # the centered 3540x2360 cover reproduces this horizontal crop.
                frame = _cover(photo(index), (size[0] + 32, size[1])).crop((0, 0, *size))
            if shape == "iphone-crop" and index == 5:
                from PIL import ImageDraw
                # B5's captured Ken Burns translation moves the label 26 screen pixels right.
                frame = _cover(photo(index), (size[0] + 52, size[1])).crop((0, 0, *size))
                # Scanner-approved Release B5 capture: EXIF card (325,187)-(1130,590).
                # White row bounds measured after 1170 -> 480 NEAREST sampling; solid
                # ink masks conservatively cover the text and icons without depending on a font.
                draw = ImageDraw.Draw(frame, "RGBA")
                draw.rounded_rectangle((325, 187, 1130, 590), radius=50, fill=(255, 255, 255, 64))
                for x0, y0, x1, y1 in ((151, 93, 446, 110), (151, 122, 426, 139),
                                       (151, 151, 273, 166), (150, 180, 381, 198), (150, 210, 250, 227)):
                    draw.rectangle(tuple(round(value * 1170 / 480) for value in (x0, y0, x1, y1)), fill="white")
                draw.rounded_rectangle((73, 2130, 1096, 2310), radius=90, fill=(255, 255, 255, 80))
        encoded = io.BytesIO()
        frame.save(encoded, format="PNG")
        return encoded.getvalue()

    def test_release_smartfill_frame_shapes_preserve_fixture_and_album_identity(self) -> None:
        for fixture_set, other_set in (("a", "b"), ("b", "a")):
            for shape, index in (("stacked", 4), ("iphone-crop", 4), ("iphone-crop", 5), ("ipad-crop", 4)):
                with self.subTest(fixture_set=fixture_set, shape=shape, index=index), tempfile.TemporaryDirectory() as raw_directory:
                    evidence = Path(raw_directory)
                    self._write_valid_evidence(evidence, fixture_set)
                    frame = evidence / "album-switch-b-play-1.png"
                    frame_bytes = self._render_edit_switch_frame(fixture_set, shape, index)
                    self.assertEqual(Image.open(io.BytesIO(frame_bytes)).size, IPAD_SCREEN if shape == "ipad-crop" else IPHONE_SCREEN)
                    # iPad B was already green with the old reader; only the observed
                    # failing layouts require an old-reader rejection.
                    if shape == "stacked" or (shape == "iphone-crop" and (index == 4 or fixture_set == "b")) or (shape == "ipad-crop" and fixture_set == "a"):
                        self.assertIsNone(public_letter_from_bytes(frame_bytes))
                    frame.write_bytes(frame_bytes)
                    self.assertEqual(evaluate_filter_visual_identity(evidence, "filter-edit-switch")["verdict"], "PASS")

                    frame.write_bytes(self._render_edit_switch_frame(other_set, shape, index))
                    with self.assertRaises(FilterContractError) as raised:
                        evaluate_filter_visual_identity(evidence, "filter-edit-switch")
                    self.assertIn("public glyph", str(raised.exception))

    def test_mixed_or_missing_public_glyphs_are_rejected(self) -> None:
        from strict_e2e_server import _png

        for fixture_set, other_set in (("a", "b"), ("b", "a")):
            for case, frame_bytes, reason in (
                ("mixed glyphs", self._render_edit_switch_frame(fixture_set, "stacked", second_fixture=other_set), "mixed public glyphs"),
                ("no glyph", _png(360, 240, 4, "", striped=fixture_set == "b"), "no public glyph"),
            ):
                with self.subTest(fixture_set=fixture_set, case=case), tempfile.TemporaryDirectory() as raw_directory:
                    evidence = Path(raw_directory)
                    self._write_valid_evidence(evidence, fixture_set)
                    (evidence / "album-switch-b-play-1.png").write_bytes(frame_bytes)
                    with self.assertRaises(FilterContractError) as raised:
                        evaluate_filter_visual_identity(evidence, "filter-edit-switch")
                    self.assertIn(reason, str(raised.exception))

    def test_every_stacked_slot_must_belong_to_the_non_target_album(self) -> None:
        for fixture_set in ("a", "b"):
            for index in (1, 2):
                with self.subTest(fixture_set=fixture_set, wrong_album_photo=index), tempfile.TemporaryDirectory() as raw:
                    evidence = Path(raw)
                    self._write_valid_evidence(evidence, fixture_set)
                    frame = self._render_edit_switch_frame(fixture_set, "stacked", index)
                    self.assertEqual(classify_screenshot(frame).mark, "A5")
                    (evidence / "album-switch-b-play-1.png").write_bytes(frame)
                    with self.assertRaises(FilterContractError) as raised:
                        evaluate_filter_visual_identity(evidence, "filter-edit-switch")
                    self.assertIn("non-target album", str(raised.exception))

    def test_an_unreadable_foreign_slot_cannot_borrow_the_other_slots_glyph(self) -> None:
        for fixture_set, other_set in (("a", "b"), ("b", "a")):
            for index in (4, 5):
                for erased in ("letter", "whole label"):
                    with self.subTest(fixture_set=fixture_set, unreadable_photo=index, erased=erased), tempfile.TemporaryDirectory() as raw:
                        evidence = Path(raw)
                        self._write_valid_evidence(evidence, fixture_set)
                        frame = self._render_edit_switch_frame(other_set, "stacked", index, fixture_set, unreadable_top=erased)
                        with self.assertRaisesRegex(IdentityAssertionError, "unreadable public glyph slot"):
                            public_frame_photos_from_bytes(frame)
                        (evidence / "album-switch-b-play-1.png").write_bytes(frame)
                        with self.assertRaises(FilterContractError) as raised:
                            evaluate_filter_visual_identity(evidence, "filter-edit-switch")
                        if classify_screenshot(frame).status == "MATCH":
                            self.assertIn("unreadable public glyph slot", str(raised.exception))
                        else:
                            self.assertIn("Unrecognizable input", str(raised.exception))

    def test_missing_post_switch_frames_keep_the_original_contract_error(self) -> None:
        for suite in ("filter-edit-switch", "tvos-edit-switch"):
            with self.subTest(suite=suite), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                self._write_valid_evidence(evidence)
                (evidence / "album-switch-b-play-1.png").unlink()
                with self.assertRaises(FilterContractError) as raised:
                    evaluate_filter_visual_identity(evidence, suite)
                self.assertIn("Missing visual input", str(raised.exception))

    def test_tvos_single_photo_keeps_color_and_public_texture_at_real_screen_size(self) -> None:
        for fixture_set in ("a", "b"):
            with self.subTest(fixture_set=fixture_set), tempfile.TemporaryDirectory() as raw:
                evidence = Path(raw)
                self._write_valid_evidence(evidence, fixture_set)
                frame = self._render_edit_switch_frame(fixture_set, "tv", 4)
                self.assertEqual(Image.open(io.BytesIO(frame)).size, TV_SCREEN)
                self.assertEqual(public_letter_from_bytes(frame), fixture_set.upper())
                (evidence / "album-switch-b-play-1.png").write_bytes(frame)
                self.assertEqual(evaluate_filter_visual_identity(evidence, "tvos-edit-switch")["verdict"], "PASS")

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


    def test_fixture_b_frames_from_the_non_target_album_pass(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_valid_evidence(evidence, "b")

            report = evaluate_filter_visual_identity(evidence, "filter-edit-switch")

            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["marks"], ["A4", "A5"])


    def test_wrong_album_or_wrong_fixture_frames_are_rejected_for_both_fixtures(self) -> None:
        for fixture_set, other_set in (("a", "b"), ("b", "a")):
            with self.subTest(fixture_set=fixture_set, case="target album frame"), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                self._write_valid_evidence(evidence, fixture_set)
                (evidence / "album-switch-b-play-1.png").write_bytes(_fixture_png("A1", fixture_set))
                with self.assertRaises(FilterContractError):
                    evaluate_filter_visual_identity(evidence, "filter-edit-switch")

            with self.subTest(fixture_set=fixture_set, case="other fixture's non-target frame"), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                self._write_valid_evidence(evidence, fixture_set)
                (evidence / "album-switch-b-play-2.png").write_bytes(_fixture_png("A5", other_set))
                with self.assertRaises(FilterContractError) as raised:
                    evaluate_filter_visual_identity(evidence, "filter-edit-switch")
                self.assertIn("public glyph", str(raised.exception))


    def test_only_declared_non_target_album_identity_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            self._write_valid_evidence(evidence)
            (evidence / "album-switch-b-play-2.png").write_bytes(_fixture_png("B1", fixture_set="b"))

            with self.assertRaises(FilterContractError):
                evaluate_filter_visual_identity(evidence, "tvos-edit-switch")
