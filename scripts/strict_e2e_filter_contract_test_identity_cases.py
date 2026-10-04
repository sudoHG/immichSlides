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

class SwiftContractMirrorTestsCases:
    def test_swift_helper_keeps_frozen_ids_and_button(self) -> None:
        source = (SCRIPT_DIR.parent / "TestSupport" / "StrictE2EFilterContract.swift").read_text(
            encoding="utf-8"
        )
        # Cross-language constant sync: the button ID and frozen fixture hashes must match the Swift mirror, or E2E
        # finds the wrong element or uses the wrong fixture.
        self.assertIn(START_PLAYBACK_BUTTON_ID, source)
        self.assertIn(FROZEN_FIXTURE_SHA256["a"], source)
        self.assertIn(FROZEN_FIXTURE_SHA256["b"], source)


class FilterVisualIdentityFromScreenshotsTestsCases:
    def test_switch_rejects_unobserved_or_nonempty_editor_selection(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            write_member_manifest(evidence / "member-manifest-b.json", "b")
            (evidence / "switch-b-playback.png").write_bytes(_fixture_png("A1", "b"))
            (evidence / "observed-ids-after-switch.json").write_text(
                json.dumps({"ids": ["album-b-target"], "raw_identifiers": []}), encoding="utf-8"
            )
            _write_switch_display_bridge(evidence)
            payload = {
                "album_ids": [], "person_filters": [], "start_enabled": False,
                "selection_source": "accessibility_ui",
                "album_summary": "筛选相册 0 个相册 · 0 张照片",
                "person_summary": "筛选人物 0 个人物 · 0 张照片",
            }
            for mutation in (
                {"selection_source": "probe"},
                {"album_summary": "筛选相册 1 个相册 · 3 张照片"},
                {"person_summary": "筛选人物 1 个人物 · 2 张照片"},
                {"album_summary": ""},
            ):
                with self.subTest(mutation=mutation):
                    (evidence / "empty-selection-after-switch.json").write_text(
                        json.dumps(payload | mutation), encoding="utf-8"
                    )
                    with self.assertRaises(FilterContractError):
                        evaluate_filter_visual_identity(evidence, "tvos-switch")


    def test_album_playback_marks_come_from_classify_screenshot_not_manifest_labels(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            for name, label in zip(
                ("album-playback-1", "album-playback-2", "album-playback-3"),
                ("A1", "A2", "A3"),
            ):
                (evidence / f"{name}.png").write_bytes(_fixture_png(label))
            (evidence / "empty-selection.json").write_text(
                json.dumps({"album_ids": [], "person_filters": [], "start_enabled": False}),
                encoding="utf-8",
            )
            report = evaluate_filter_visual_identity(evidence, "tvos-album")
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["marks"], ["A1", "A2", "A3"])
        self.assertEqual(report["identity_source"], "public_fixture_photo_mark")


    def test_album_playback_rejects_wrong_member_empty_and_black_but_allows_sample_repeat(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            for name, mark in zip(
                ("album-playback-1", "album-playback-2", "album-playback-3"),
                ("A1", "A2", "A4"),
            ):
                (evidence / f"{name}.png").write_bytes(_fixture_png(mark))
            (evidence / "empty-selection.json").write_text(
                json.dumps({"album_ids": [], "person_filters": [], "start_enabled": False}),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError):
                evaluate_filter_visual_identity(evidence, "tvos-album")

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            for name, mark in zip(
                ("album-playback-1", "album-playback-2", "album-playback-3"),
                ("A1", "A2", "A1"),
            ):
                (evidence / f"{name}.png").write_bytes(_fixture_png(mark))
            (evidence / "empty-selection.json").write_text(
                json.dumps({"album_ids": [], "person_filters": [], "start_enabled": False}),
                encoding="utf-8",
            )
            report = evaluate_filter_visual_identity(evidence, "tvos-album")
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["marks"], ["A1", "A2", "A1"])

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "album-playback-1.png").write_bytes(_fixture_png("A1"))
            (evidence / "album-playback-2.png").write_bytes(_fixture_png("A2"))
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "tvos-album")
            self.assertIn("Missing visual input", str(raised.exception))

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            black = b"\x89PNG\r\n\x1a\n"
            for name in ("album-playback-1", "album-playback-2", "album-playback-3"):
                (evidence / f"{name}.png").write_bytes(black)
            (evidence / "empty-selection.json").write_text(
                json.dumps({"album_ids": [], "person_filters": [], "start_enabled": False}),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "tvos-album")
            self.assertIn("Unrecognizable input", str(raised.exception))


    def test_empty_start_enabled_cannot_pass_album_suite(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            for name, label in zip(
                ("album-playback-1", "album-playback-2", "album-playback-3"),
                ("A1", "A2", "A3"),
            ):
                (evidence / f"{name}.png").write_bytes(_fixture_png(label))
            (evidence / "empty-selection.json").write_text(
                json.dumps({"album_ids": [], "person_filters": [], "start_enabled": True}),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "tvos-album")
            self.assertIn("empty selection", str(raised.exception))


    def test_album_suite_requires_a_boolean_start_enabled(self) -> None:
        for selection in (
            {"album_ids": [], "person_filters": []},
            {"album_ids": [], "person_filters": [], "start_enabled": None},
            {"album_ids": [], "person_filters": [], "start_enabled": 0},
        ):
            with self.subTest(selection=selection), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                for name, label in zip(
                    ("album-playback-1", "album-playback-2", "album-playback-3"),
                    ("A1", "A2", "A3"),
                ):
                    (evidence / f"{name}.png").write_bytes(_fixture_png(label))
                (evidence / "empty-selection.json").write_text(json.dumps(selection), encoding="utf-8")
                with self.assertRaises(FilterContractError) as raised:
                    evaluate_filter_visual_identity(evidence, "tvos-album")
                self.assertIn("start_enabled must be a Boolean", str(raised.exception))


    def test_person_suite_classifies_pngs_and_keeps_simulator_vision_unverified(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "person-normal.png").write_bytes(_fixture_png("A1"))
            (evidence / "person-conflict-normal.png").write_bytes(_fixture_png("A2"))
            (evidence / "person-no-faces.png").write_bytes(_fixture_png("A4"))
            (evidence / "person-solo.png").write_bytes(_fixture_png("A2"))
            (evidence / "vision-environment.json").write_text(
                json.dumps({"environment": "simulator", "vision_available": False}),
                encoding="utf-8",
            )
            report = evaluate_filter_visual_identity(evidence, "tvos-person")
        self.assertEqual(report["verdict"], "PARTIAL")
        self.assertEqual(report["vision"]["verdict"], "UNVERIFIED")
        self.assertEqual(report["steps"]["person-normal"]["mark"], "A1")
        self.assertEqual(report["steps"]["person-solo"]["verdict"], "UNVERIFIED")


    def test_person_suite_rejects_solo_only_pass_claim_and_wins_field(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "person-normal.png").write_bytes(_fixture_png("A1"))
            (evidence / "person-conflict-normal.png").write_bytes(_fixture_png("A2"))
            (evidence / "person-no-faces.png").write_bytes(_fixture_png("A4"))
            (evidence / "vision-environment.json").write_text(
                json.dumps({"environment": "simulator", "vision_available": False}),
                encoding="utf-8",
            )
            (evidence / "solo-only-pass.json").write_text("{}", encoding="utf-8")
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "tvos-person")
            self.assertIn("soloOnly", str(raised.exception))

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "person-normal.png").write_bytes(_fixture_png("A1"))
            (evidence / "person-conflict-normal.png").write_bytes(_fixture_png("A2"))
            (evidence / "person-no-faces.png").write_bytes(_fixture_png("A4"))
            (evidence / "vision-environment.json").write_text(
                json.dumps({"environment": "simulator", "vision_available": False, "wins": "soloOnly"}),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "tvos-person")
            self.assertIn("wins", str(raised.exception))

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            (evidence / "person-normal.png").write_bytes(_fixture_png("A1"))
            (evidence / "person-conflict-normal.png").write_bytes(_fixture_png("A2"))
            (evidence / "person-no-faces.png").write_bytes(b"\x89PNG\r\n\x1a\n")
            (evidence / "vision-environment.json").write_text(
                json.dumps({"environment": "simulator", "vision_available": False}),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "tvos-person")
            self.assertIn("Unrecognizable input", str(raised.exception))


    def test_person_conflict_normal_allows_a5_a3_a5_without_a2(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_person_suite(evidence, conflict=["A5", "A3", "A5"])
            report = evaluate_filter_visual_identity(evidence, "tvos-person")
        self.assertEqual(report["steps"]["person-conflict-normal"]["marks"], ["A5", "A3", "A5"])
        self.assertIn(report["steps"]["person-conflict-normal"]["mark"], {"A2", "A3", "A5"})
        self.assertNotIn("wins", report["steps"]["person-conflict-normal"])


    def test_person_conflict_normal_still_allows_a2_when_present(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_person_suite(evidence, conflict=["A5", "A2", "A3"])
            report = evaluate_filter_visual_identity(evidence, "tvos-person")
        self.assertEqual(set(report["steps"]["person-conflict-normal"]["marks"]), {"A5", "A2", "A3"})
        self.assertNotIn("wins", report["steps"]["person-conflict-normal"])


    def test_person_conflict_normal_accepts_a5_only_and_rejects_leftover_a1(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_person_suite(evidence, conflict=["A5"])
            report = evaluate_filter_visual_identity(evidence, "tvos-person")
        self.assertEqual(report["steps"]["person-conflict-normal"]["marks"], ["A5"])

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_person_suite(evidence, conflict=["A5", "A1"])
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "tvos-person")
            self.assertIn("Members outside the selection union", str(raised.exception))
            self.assertIn("A1", str(raised.exception))

        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            _write_person_suite(evidence, conflict=["A5", "A2", "A1"])
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "tvos-person")
            self.assertIn("Members outside the selection union", str(raised.exception))
            self.assertIn("A1", str(raised.exception))


    def test_switch_suite_rejects_old_server_tokens_in_ui_or_log(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            write_member_manifest(evidence / "member-manifest-b.json", "b")
            (evidence / "switch-b-playback.png").write_bytes(_fixture_png("A1", "b"))
            (evidence / "observed-ids-after-switch.json").write_text(
                json.dumps(
                    {
                        "identity_source": "ui_accessibility_identifier",
                        "ids": ["album-b-target"],
                        "raw_identifiers": ["albumFilter.album.album-b-target.button"],
                    }
                ),
                encoding="utf-8",
            )
            (evidence / "empty-selection-after-switch.json").write_text(
                json.dumps({
                    "selection_source": "accessibility_ui",
                    "album_summary": "筛选相册 0 个相册 · 0 张照片",
                    "person_summary": "筛选人物 0 个人物 · 0 张照片",
                }),
                encoding="utf-8",
            )
            _write_switch_display_bridge(evidence)
            report = evaluate_filter_visual_identity(evidence, "tvos-switch")
            self.assertEqual(report["verdict"], "PASS")

            (evidence / "observed-ids-after-switch.json").write_text(
                json.dumps(
                    {
                        "identity_source": "ui_accessibility_identifier",
                        "ids": ["album-b-target"],
                        "raw_identifiers": ["albumFilter.album.album-a-target.button"],
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "tvos-switch")
            self.assertIn("Cross-server", str(raised.exception))

            (evidence / "observed-ids-after-switch.json").write_text(
                json.dumps(
                    {
                        "identity_source": "ui_accessibility_identifier",
                        "ids": ["album-b-target"],
                        "raw_identifiers": ["albumFilter.album.album-b-target.button"],
                    }
                ),
                encoding="utf-8",
            )
            (evidence / "empty-selection-after-switch.json").write_text(
                json.dumps({"album_ids": [], "person_filters": [], "start_enabled": True}),
                encoding="utf-8",
            )
            with self.assertRaises(FilterContractError) as raised:
                evaluate_filter_visual_identity(evidence, "tvos-switch")
            self.assertIn("empty selection", str(raised.exception))

        assert_foreign_id_tokens_absent(["albumFilter.album.album-b-target.button"], "b")
        with self.assertRaises(FilterContractError):
            assert_foreign_id_tokens_absent(["personFilter.person.person-a-normal.button"], "b")


    def test_tvos_switch_bridge_requires_real_b_single_photo_and_same_process(self) -> None:
        invalid_bridges = (
            {
                "name": "mixed-server",
                "screenshot": _side_by_side(_fixture_png("A1", "a"), _fixture_png("A2", "b")),
                "setting_source": "accessibility_ui",
                "process_id_after": 44,
                "error": "fixture B",
            },
            {
                "name": "probe",
                "screenshot": _fixture_png("A1", "b"),
                "setting_source": "probe",
                "process_id_after": 44,
                "error": "real UI",
            },
            {
                "name": "relaunch",
                "screenshot": _fixture_png("A1", "b"),
                "setting_source": "accessibility_ui",
                "process_id_after": 45,
                "error": "same App process remained alive",
            },
        )
        for invalid in invalid_bridges:
            with self.subTest(name=invalid["name"]), tempfile.TemporaryDirectory() as raw_directory:
                evidence = Path(raw_directory)
                write_member_manifest(evidence / "member-manifest-b.json", "b")
                (evidence / "switch-b-playback.png").write_bytes(_fixture_png("A1", "b"))
                (evidence / "observed-ids-after-switch.json").write_text(
                    json.dumps({"ids": ["album-b-target"], "raw_identifiers": []}), encoding="utf-8"
                )
                (evidence / "empty-selection-after-switch.json").write_text(
                    json.dumps({
                        "selection_source": "accessibility_ui",
                        "album_summary": "筛选相册 0 个相册 · 0 张照片",
                        "person_summary": "筛选人物 0 个人物 · 0 张照片",
                    }),
                    encoding="utf-8",
                )
                _write_switch_display_bridge(
                    evidence,
                    screenshot=invalid["screenshot"],
                    setting_source=invalid["setting_source"],
                    process_id_after=invalid["process_id_after"],
                )
                with self.assertRaises(FilterContractError) as raised:
                    evaluate_filter_visual_identity(evidence, "tvos-switch")
                self.assertIn(invalid["error"], str(raised.exception))


class ServerABFailClosedTestsCases:
    def test_empty_filters_return_no_assets_and_unknown_b_routes_fail(self) -> None:
        required = {
            "isOffline": False,
            "visibility": "timeline",
            "withDeleted": False,
            "withExif": True,
            "withPeople": True,
            "withStacked": True,
        }
        with RunningServer(fixture_set="b") as server:
            status, _, body = server.request(
                "/search/random",
                method="POST",
                body={"size": 5, "albumIds": [], **required},
            )
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body), [])

            status, _, body = server.request(
                "/search/random",
                method="POST",
                body={"size": 5, "personIds": [], **required},
            )
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body), [])

            status, _, _ = server.request("/people/person-a-normal/statistics")
            self.assertEqual(status, 404)
            status, _, _ = server.request("/not-a-real-route")
            self.assertEqual(status, 404)
