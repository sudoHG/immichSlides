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

class MemberManifestContractTestsCases:
    def test_frozen_fixture_hashes_are_not_rewritten(self) -> None:
        self.assertEqual(fixture_manifest("a")["fixture_sha256"], FROZEN_FIXTURE_SHA256["a"])
        self.assertEqual(fixture_manifest("b")["fixture_sha256"], FROZEN_FIXTURE_SHA256["b"])
        self.assertNotEqual(FROZEN_FIXTURE_SHA256["a"], FROZEN_FIXTURE_SHA256["b"])


    def test_target_album_has_three_public_marks_and_is_independently_readable(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            path = Path(raw_directory) / "member-manifest.json"
            written = write_member_manifest(path, "a")
            loaded = load_member_manifest(path)

        self.assertEqual(written, loaded)
        self.assertEqual(loaded["kind"], "strict-e2e-member-manifest")
        self.assertEqual(loaded["fixture_set"], "a")
        self.assertEqual(loaded["fixture_sha256"], FROZEN_FIXTURE_SHA256["a"])
        self.assertEqual(loaded["target_album"]["id"], "album-a-target")
        self.assertEqual(loaded["target_album"]["asset_ids"], ["asset-a-1", "asset-a-2", "asset-a-3"])
        self.assertEqual(loaded["target_album"]["labels"], ["A1", "A2", "A3"])
        self.assertEqual(loaded["target_album"]["visual_labels"], ["A1", "A2", "A3"])
        self.assertEqual(loaded["non_target_album"]["labels"], ["A4", "A5"])
        self.assertEqual(write_member_manifest(path.with_name("member-manifest-b.json"), "b")["target_album"]["visual_labels"], ["B1", "B2", "B3"])


    def test_a_and_b_member_ids_stay_mutually_exclusive(self) -> None:
        server_a = member_manifest("a")
        server_b = member_manifest("b")
        self.assertTrue(set(server_a["all_asset_ids"]).isdisjoint(server_b["all_asset_ids"]))
        self.assertTrue(set(server_a["all_album_ids"]).isdisjoint(server_b["all_album_ids"]))
        self.assertTrue(set(server_a["all_person_ids"]).isdisjoint(server_b["all_person_ids"]))
        self.assertEqual(server_b["target_album"]["id"], "album-b-target")
        self.assertEqual(server_b["target_album"]["labels"], ["A1", "A2", "A3"])


    def test_a_and_b_five_images_match_unique_classified_labels(self) -> None:
        expected = ["A1", "A2", "A3", "A4", "A5"]
        for fixture_set in ("a", "b"):
            with self.subTest(fixture_set=fixture_set):
                with tempfile.TemporaryDirectory() as raw_directory:
                    path = Path(raw_directory) / f"member-manifest-{fixture_set}.json"
                    written = write_member_manifest(path, fixture_set)
                    loaded = load_member_manifest(path)
                classified = []
                for label in expected:
                    identity = classify_screenshot(_fixture_png(label, fixture_set))
                    classified.append(
                        require_photo_mark(
                            "public_fixture_photo_mark",
                            identity.status,
                            identity.mark,
                        )
                    )
                self.assertEqual(classified, expected)
                self.assertEqual(len(set(classified)), 5)
                self.assertEqual(
                    written["target_album"]["labels"] + written["non_target_album"]["labels"],
                    classified,
                )
                self.assertEqual(
                    loaded["target_album"]["labels"] + loaded["non_target_album"]["labels"],
                    classified,
                )


    def test_missing_or_tampered_manifest_cannot_pass(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            missing = Path(raw_directory) / "absent.json"
            with self.assertRaises(FilterContractError) as raised:
                load_member_manifest(missing)
            self.assertIn("Missing", str(raised.exception))

            unreadable = Path(raw_directory) / "broken.json"
            unreadable.write_text("{not-json", encoding="utf-8")
            with self.assertRaises(FilterContractError):
                load_member_manifest(unreadable)

            path = Path(raw_directory) / "member-manifest.json"
            write_member_manifest(path, "a")
            payload = json.loads(path.read_text(encoding="utf-8"))
            payload["fixture_sha256"] = "0" * 64
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(FilterContractError) as raised:
                load_member_manifest(path)
            self.assertIn("hash", str(raised.exception))

            write_member_manifest(path, "b")
            payload = json.loads(path.read_text(encoding="utf-8"))
            payload["target_album"]["labels"] = ["A2", "A3", "A3"]
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            with self.assertRaises(FilterContractError) as raised:
                load_member_manifest(path)
            self.assertIn("classify_screenshot", str(raised.exception))

            write_member_manifest(path, "b")
            payload = json.loads(path.read_text(encoding="utf-8"))
            payload["person_cases"]["solo_only_qualified"]["labels"] = ["A1"]
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            with self.assertRaises(FilterContractError) as raised:
                load_member_manifest(path)
            self.assertIn("classify_screenshot", str(raised.exception))

            write_member_manifest(path, "a")
            payload = json.loads(path.read_text(encoding="utf-8"))
            payload["object_sets"]["people"]["person-a-solo"]["normal"]["labels"] = ["A2", "A3"]
            payload["object_sets"]["people"]["person-a-solo"]["normal"]["asset_ids"] = [
                "asset-a-2",
                "asset-a-3",
            ]
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            with self.assertRaises(FilterContractError) as raised:
                load_member_manifest(path)
            self.assertIn("independent object sets", str(raised.exception))


class PlaybackMembershipAndIdentityTestsCases:
    def test_target_album_playback_marks_must_come_from_photo_identity(self) -> None:
        marks = []
        for label in ("A1", "A2", "A3"):
            identity = classify_screenshot(_fixture_png(label))
            marks.append(require_photo_mark("public_fixture_photo_mark", identity.status, identity.mark))
        assert_playback_marks_in_target(marks, "a")


    def test_request_log_index_and_probe_cannot_prove_identity(self) -> None:
        identity = classify_screenshot(_fixture_png("A1"))
        for source in ("request_log", "asset_index", "probe", "currentAssetId"):
            with self.subTest(source=source), self.assertRaises(FilterContractError) as raised:
                require_photo_mark(source, identity.status, identity.mark)
            self.assertIn("identity", str(raised.exception))


    def test_wrong_member_empty_and_unrecognizable_fail_while_sample_repeat_is_allowed(self) -> None:
        with self.assertRaises(FilterContractError) as raised:
            assert_playback_marks_in_target(["A1", "A4"], "a")
        self.assertIn("Unexpected members", str(raised.exception))

        assert_playback_marks_in_target(["A1", "A2", "A1"], "a")

        with self.assertRaises(FilterContractError) as raised:
            assert_playback_marks_in_target([], "a")
        self.assertIn("Empty", str(raised.exception))

        identity = classify_screenshot(b"")
        with self.assertRaises(FilterContractError) as raised:
            require_photo_mark("public_fixture_photo_mark", identity.status, identity.mark)
        self.assertIn("Unrecognizable input", str(raised.exception))


class PersonRuleContractTestsCases:
    def test_person_cases_are_distinguishable_by_public_marks(self) -> None:
        cases = member_manifest("a")["person_cases"]
        self.assertEqual(cases["normal_match"]["person_id"], "person-a-normal")
        self.assertEqual(cases["normal_match"]["labels"], ["A1"])
        self.assertEqual(cases["solo_only_qualified"]["person_id"], "person-a-solo")
        self.assertEqual(cases["solo_only_qualified"]["labels"], ["A2"])
        self.assertEqual(cases["multiple_people_disqualified"]["labels"], ["A3"])
        self.assertEqual(cases["no_faces"]["person_id"], "person-a-no-faces")
        self.assertEqual(cases["no_faces"]["labels"], ["A4"])
        self.assertNotIn("wins", cases["normal_plus_solo_conflict"])
        self.assertEqual(
            cases["normal_plus_solo_conflict"]["labels"],
            cases["solo_only_qualified"]["labels"],
        )
        # This is the public mark both modes contain, not the playback pool of an album+person or both-modes selection.
        self.assertEqual(cases["normal_plus_solo_conflict"]["labels"], ["A2"])
        self.assertEqual(
            {tuple(cases[name]["labels"]) for name in (
                "normal_match",
                "solo_only_qualified",
                "multiple_people_disqualified",
                "no_faces",
            )},
            {("A1",), ("A2",), ("A3",), ("A4",)},
        )


    def test_person_a_solo_normal_allows_a2_a3_a5_and_solo_only_stays_a2(self) -> None:
        solo_labels = {
            asset["label"]
            for asset in fixture_manifest("a")["assets"]
            if any(person["id"] == "person-a-solo" for person in asset["people"])
        }
        self.assertEqual(solo_labels, {"A2", "A3", "A5"})
        self.assertEqual(
            member_manifest("a")["person_cases"]["solo_only_qualified"]["labels"],
            ["A2"],
        )
        self.assertNotIn("wins", member_manifest("a")["person_cases"]["normal_plus_solo_conflict"])


    def test_solo_only_rejects_a5_even_when_vision_is_available(self) -> None:
        with self.assertRaises(FilterContractError) as raised:
            assert_solo_only_not_vacuous(
                environment="device",
                vision_available=True,
                qualified_marks=["A5"],
                face_counts={"A5": 1},
                fixture_set="a",
            )
        self.assertIn("Unexpected members", str(raised.exception))


    def test_no_faces_and_unavailable_vision_cannot_vacuously_pass_solo_only(self) -> None:
        with self.assertRaises(FilterContractError) as raised:
            assert_solo_only_not_vacuous(
                environment="simulator",
                vision_available=True,
                qualified_marks=["A2"],
                face_counts={"A2": 1},
                fixture_set="a",
            )
        self.assertIn("device", str(raised.exception))

        with self.assertRaises(FilterContractError) as raised:
            assert_solo_only_not_vacuous(
                environment="device",
                vision_available=False,
                qualified_marks=["A2"],
                face_counts={"A2": 1},
                fixture_set="a",
            )
        self.assertIn("Vision", str(raised.exception))

        with self.assertRaises(FilterContractError) as raised:
            assert_solo_only_not_vacuous(
                environment="device",
                vision_available=True,
                qualified_marks=[],
                face_counts={},
                fixture_set="a",
            )
        self.assertIn("empty", str(raised.exception))

        with self.assertRaises(FilterContractError) as raised:
            assert_solo_only_not_vacuous(
                environment="device",
                vision_available=True,
                qualified_marks=["A2"],
                face_counts={"A2": 0},
                fixture_set="a",
            )
        self.assertIn("faces", str(raised.exception))
        self.assertNotIn("Unexpected members", str(raised.exception))

        assert_solo_only_not_vacuous(
            environment="device",
            vision_available=True,
            qualified_marks=["A2"],
            face_counts={"A2": 1},
            fixture_set="a",
        )


class AlbumPersonUnionContractTestsCases:
    def test_final_pool_must_equal_total_union(self) -> None:
        albums = ["album-a-target"]
        people = [{"person_id": "person-a-solo", "mode": "normal"}]
        expected = union_selection_labels("a", albums, people)
        assert_final_pool_equals_union(expected, "a", albums, people)

        for missing_index in range(len(expected)):
            incomplete = expected[:missing_index] + expected[missing_index + 1 :]
            with self.assertRaises(FilterContractError) as raised:
                assert_final_pool_equals_union(incomplete, "a", albums, people)
            self.assertIn("Missing selection-union members", str(raised.exception))

        with self.assertRaises(FilterContractError) as raised:
            assert_final_pool_equals_union(expected + ["not-a-selected-object"], "a", albums, people)
        self.assertIn("Members outside the selection union", str(raised.exception))

        with self.assertRaises(FilterContractError) as raised:
            assert_final_pool_equals_union(expected + [expected[0]], "a", albums, people)
        self.assertIn("Repeated members", str(raised.exception))


    def test_selected_objects_are_independent_sets_then_union(self) -> None:
        album = album_selection_labels("a", "album-a-target")
        person_normal = person_selection_labels("a", "person-a-solo", "normal")
        self.assertEqual(album, ["A1", "A2", "A3"])
        self.assertEqual(person_normal, ["A2", "A3", "A5"])
        self.assertIn("A1", album)
        self.assertNotIn("A1", person_normal)
        self.assertIn("A5", person_normal)
        self.assertNotIn("A5", album)

        computed = union_selection_labels(
            "a",
            ["album-a-target"],
            [{"person_id": "person-a-solo", "mode": "normal"}],
        )
        self.assertEqual(set(computed), set(album) | set(person_normal))
        assert_final_pool_equals_union(
            computed,
            "a",
            ["album-a-target"],
            [{"person_id": "person-a-solo", "mode": "normal"}],
        )

        assert_playback_marks_in_union(
            ["A1", "A5"],
            "a",
            ["album-a-target"],
            [{"person_id": "person-a-solo", "mode": "normal"}],
        )
        with self.assertRaises(FilterContractError) as raised:
            assert_playback_marks_in_union(
                ["A1", "A4"],
                "a",
                ["album-a-target"],
                [{"person_id": "person-a-solo", "mode": "normal"}],
            )
        self.assertIn("Members outside the selection union", str(raised.exception))
        with self.assertRaises(FilterContractError) as album_only:
            assert_playback_marks_in_union(["A5"], "a", ["album-a-target"], [])
        self.assertIn("Members outside the selection union", str(album_only.exception))
        with self.assertRaises(FilterContractError) as person_only:
            assert_playback_marks_in_union(
                ["A1"],
                "a",
                [],
                [{"person_id": "person-a-solo", "mode": "normal"}],
            )
        self.assertIn("Members outside the selection union", str(person_only.exception))


    def test_solo_only_does_not_filter_selected_albums_or_the_union(self) -> None:
        solo = person_selection_labels("a", "person-a-solo", "soloOnly")
        self.assertEqual(solo, ["A2"])
        album = album_selection_labels("a", "album-a-target")
        combined = union_selection_labels(
            "a",
            ["album-a-target"],
            [{"person_id": "person-a-solo", "mode": "soloOnly"}],
        )
        self.assertEqual(set(combined), set(album) | set(solo))
        self.assertIn("A1", combined)
        self.assertIn("A3", combined)
        self.assertNotIn("A5", combined)
        assert_final_pool_equals_union(
            combined,
            "a",
            ["album-a-target"],
            [{"person_id": "person-a-solo", "mode": "soloOnly"}],
        )
        assert_playback_marks_in_union(
            ["A1", "A3"],
            "a",
            ["album-a-target"],
            [{"person_id": "person-a-solo", "mode": "soloOnly"}],
        )
        with self.assertRaises(FilterContractError) as raised:
            assert_playback_marks_in_union(
                ["A5"],
                "a",
                ["album-a-target"],
                [{"person_id": "person-a-solo", "mode": "soloOnly"}],
            )
        self.assertIn("Members outside the selection union", str(raised.exception))


    def test_multiple_people_are_union_not_intersection(self) -> None:
        normal = person_selection_labels("a", "person-a-normal", "normal")
        other = person_selection_labels("a", "person-a-other", "normal")
        self.assertEqual(normal, ["A1"])
        self.assertEqual(other, ["A3"])
        both = [
            {"person_id": "person-a-normal", "mode": "normal"},
            {"person_id": "person-a-other", "mode": "normal"},
        ]
        computed = union_selection_labels("a", [], both)
        self.assertEqual(set(computed), set(normal) | set(other))
        self.assertEqual(set(computed), {"A1", "A3"})
        self.assertEqual(set(normal) & set(other), set())
        assert_final_pool_equals_union(computed, "a", [], both)
        assert_playback_marks_in_union(["A1"], "a", [], both)
        assert_playback_marks_in_union(["A3"], "a", [], both)
        with self.assertRaises(FilterContractError) as raised:
            assert_playback_marks_in_union(["A2"], "a", [], both)
        self.assertIn("Members outside the selection union", str(raised.exception))

        solo_and_other = union_selection_labels(
            "a",
            [],
            [
                {"person_id": "person-a-solo", "mode": "normal"},
                {"person_id": "person-a-other", "mode": "normal"},
            ],
        )
        self.assertEqual(set(solo_and_other), {"A2", "A3", "A5"})
        self.assertIn("A2", solo_and_other)
        self.assertIn("A5", solo_and_other)


    def test_multiple_albums_are_union(self) -> None:
        target = album_selection_labels("a", "album-a-target")
        non_target = album_selection_labels("a", "album-a-non-target")
        computed = union_selection_labels(
            "a",
            ["album-a-target", "album-a-non-target"],
            [],
        )
        self.assertEqual(set(computed), set(target) | set(non_target))
        self.assertEqual(set(computed), {"A1", "A2", "A3", "A4", "A5"})
        assert_final_pool_equals_union(
            computed,
            "a",
            ["album-a-target", "album-a-non-target"],
            [],
        )
        assert_playback_marks_in_union(
            ["A4", "A1"],
            "a",
            ["album-a-target", "album-a-non-target"],
            [],
        )


    def test_one_person_solo_only_does_not_filter_another_person(self) -> None:
        solo = person_selection_labels("a", "person-a-solo", "soloOnly")
        other = person_selection_labels("a", "person-a-other", "normal")
        self.assertEqual(solo, ["A2"])
        self.assertEqual(other, ["A3"])
        combined = union_selection_labels(
            "a",
            [],
            [
                {"person_id": "person-a-solo", "mode": "soloOnly"},
                {"person_id": "person-a-other", "mode": "normal"},
            ],
        )
        self.assertEqual(set(combined), set(solo) | set(other))
        self.assertIn("A3", combined)
        assert_final_pool_equals_union(
            combined,
            "a",
            [],
            [
                {"person_id": "person-a-solo", "mode": "soloOnly"},
                {"person_id": "person-a-other", "mode": "normal"},
            ],
        )
        assert_playback_marks_in_union(
            ["A3"],
            "a",
            [],
            [
                {"person_id": "person-a-solo", "mode": "soloOnly"},
                {"person_id": "person-a-other", "mode": "normal"},
            ],
        )


    def test_normal_plus_solo_only_modes_union_is_not_a2_only(self) -> None:
        normal = person_selection_labels("a", "person-a-solo", "normal")
        solo = person_selection_labels("a", "person-a-solo", "soloOnly")
        both = [
            {"person_id": "person-a-solo", "mode": "normal"},
            {"person_id": "person-a-solo", "mode": "soloOnly"},
        ]
        computed = union_selection_labels("a", [], both)
        self.assertEqual(set(computed), set(normal) | set(solo))
        assert_final_pool_equals_union(computed, "a", [], both)
        assert_playback_marks_in_union(["A3", "A5"], "a", [], both)
        with self.assertRaises(FilterContractError) as raised:
            assert_playback_marks_in_union(["A4"], "a", [], both)
        self.assertIn("Members outside the selection union", str(raised.exception))


    def test_final_pool_requires_every_union_member(self) -> None:
        album_ids = ["album-a-target"]
        person_filters = [{"person_id": "person-a-solo", "mode": "normal"}]
        album = set(album_selection_labels("a", "album-a-target"))
        person = set(person_selection_labels("a", "person-a-solo", "normal"))
        self.assertEqual(album - person, {"A1"})
        self.assertEqual(person - album, {"A5"})
        expected = union_selection_labels("a", album_ids, person_filters)
        assert_final_pool_equals_union(
            expected,
            "a",
            album_ids,
            person_filters,
        )
        for missing_index in range(len(expected)):
            incomplete = expected[:missing_index] + expected[missing_index + 1 :]
            with self.assertRaises(FilterContractError) as raised:
                assert_final_pool_equals_union(
                    incomplete,
                    "a",
                    album_ids,
                    person_filters,
                )
            self.assertIn("Missing selection-union members", str(raised.exception))
        with self.assertRaises(FilterContractError) as raised:
            assert_final_pool_equals_union(
                ["A1", "A4", "A5"],
                "a",
                album_ids,
                person_filters,
            )
        self.assertIn("Members outside the selection union", str(raised.exception))


    def test_manifest_object_sets_round_trip_independent_album_and_person_sets(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            path = Path(raw_directory) / "member-manifest.json"
            written = write_member_manifest(path, "a")
            loaded = load_member_manifest(path)
        people = loaded["object_sets"]["people"]["person-a-solo"]
        albums = loaded["object_sets"]["albums"]["album-a-target"]
        self.assertEqual(albums["labels"], ["A1", "A2", "A3"])
        self.assertEqual(people["normal"]["labels"], ["A2", "A3", "A5"])
        self.assertEqual(people["soloOnly"]["labels"], ["A2"])
        self.assertEqual(
            loaded["object_sets"]["people"]["person-a-other"]["normal"]["labels"],
            ["A3"],
        )
        self.assertEqual(written["object_sets"], loaded["object_sets"])
        self.assertNotIn("wins", loaded["object_sets"])
        self.assertNotIn("wins", loaded["person_cases"]["normal_plus_solo_conflict"])


class EmptySelectionAndCrossServerTestsCases:
    def test_empty_selection_cannot_start(self) -> None:
        self.assertEqual(START_PLAYBACK_BUTTON_ID, "filterSummary.startPlayback.button")
        assert_empty_selection_cannot_start(
            album_ids=[],
            person_filters=[],
            start_enabled=False,
        )
        with self.assertRaises(FilterContractError) as raised:
            assert_empty_selection_cannot_start(
                album_ids=[],
                person_filters=[],
                start_enabled=True,
            )
        self.assertIn("empty selection", str(raised.exception))
        assert_empty_selection_cannot_start(
            album_ids=["album-a-target"],
            person_filters=[],
            start_enabled=True,
        )


    def test_server_a_ids_are_foreign_on_server_b(self) -> None:
        assert_foreign_server_ids_absent(["asset-b-1", "album-b-target"], "b")
        with self.assertRaises(FilterContractError) as raised:
            assert_foreign_server_ids_absent(["asset-a-1", "album-a-target", "person-a-normal"], "b")
        self.assertIn("Cross-server", str(raised.exception))


class RequestLogContractTestsCases:
    def test_request_log_format_is_frozen_and_never_contains_api_key(self) -> None:
        log_stream = io.StringIO()
        with RunningServer(fixture_set="b", log_stream=log_stream) as server:
            status, _, _ = server.request("/assets/asset-a-1")
            self.assertEqual(status, 404)
            status, _, _ = server.request(
                "/search/random",
                method="POST",
                body={
                    "size": 1,
                    "albumIds": ["album-a-target"],
                    "isOffline": False,
                    "visibility": "timeline",
                    "withDeleted": False,
                    "withExif": True,
                    "withPeople": True,
                    "withStacked": True,
                },
            )
            self.assertEqual(status, 400)
            status, _, _ = server.request(
                "/search/random?x-api-key=" + PUBLIC_API_KEY,
                method="POST",
                body={
                    "size": 1,
                    "isOffline": False,
                    "visibility": "timeline",
                    "withDeleted": False,
                    "withExif": True,
                    "withPeople": True,
                    "withStacked": True,
                },
            )
            self.assertEqual(status, 200)
            server.request("/assets/asset-b-1/thumbnail?size=preview")

        log_text = log_stream.getvalue()
        assert_request_log_contract(log_text, forbidden=(PUBLIC_API_KEY, "x-api-key"))
        self.assertIn("elapsed_ms=", log_text)
        self.assertIn("fixture_asset_id=asset-b-1", log_text)
        self.assertIn("path=/api/assets/<fixture-id>/thumbnail", log_text)
