#!/usr/bin/env python3
"""Shared filter contract.

Member manifest, union of independent per-object sets, person rules, empty selection and negative cases
must fail first.
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageFilter, ImageOps


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from strict_e2e_filter_contract import (  # noqa: E402
    DISPLAY_POLICY_CANDIDATE_PREFIX,
    FILTER_VISUAL_SUITES,
    FROZEN_FIXTURE_SHA256,
    START_PLAYBACK_BUTTON_ID,
    FilterContractError,
    album_selection_labels,
    assert_empty_selection_cannot_start,
    assert_final_pool_equals_union,
    assert_foreign_id_tokens_absent,
    assert_foreign_server_ids_absent,
    assert_observed_covers_object_uniques,
    assert_playback_marks_in_target,
    assert_playback_marks_in_union,
    assert_request_log_contract,
    assert_solo_only_not_vacuous,
    evaluate_filter_visual_identity,
    load_member_manifest,
    member_manifest,
    person_selection_labels,
    require_photo_mark,
    union_selection_labels,
    write_member_manifest,
)
from strict_e2e_photo_identity import classify_screenshot  # noqa: E402
from strict_e2e_server import PUBLIC_API_KEY, _fixture_data, fixture_manifest  # noqa: E402
from test_strict_e2e_server import RunningServer  # noqa: E402


def _fixture_png(label: str, fixture_set: str = "a") -> bytes:
    return _fixture_data(fixture_set)["images"][f"asset-{fixture_set}-{label[-1]}"]


def _side_by_side(first_png: bytes, second_png: bytes) -> bytes:
    with Image.open(io.BytesIO(first_png)) as first, Image.open(io.BytesIO(second_png)) as second:
        first_rgb = first.convert("RGB").resize((160, 568))
        second_rgb = second.convert("RGB").resize((160, 568))
        scene = Image.new("RGB", (320, 568))
        scene.paste(first_rgb, (0, 0))
        scene.paste(second_rgb, (160, 0))
        buffer = io.BytesIO()
        scene.save(buffer, format="PNG")
        return buffer.getvalue()


def _full_frame_transition(first_png: bytes, second_png: bytes) -> bytes:
    with Image.open(io.BytesIO(first_png)) as first, Image.open(io.BytesIO(second_png)) as second:
        first_rgb = first.convert("RGB").resize((320, 568))
        second_rgb = second.convert("RGB").resize((320, 568))
        blend = Image.blend(first_rgb, second_rgb, 0.5)
        buffer = io.BytesIO()
        blend.save(buffer, format="PNG")
        return buffer.getvalue()


def _solid_png(color: tuple[int, int, int]) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (320, 568), color).save(buffer, format="PNG")
    return buffer.getvalue()


def _write_person_suite(
    evidence: Path,
    *,
    conflict: list[str],
) -> None:
    (evidence / "person-normal.png").write_bytes(_fixture_png("A1"))
    for index, label in enumerate(conflict):
        name = "person-conflict-normal.png" if index == 0 else f"person-conflict-normal-{index + 1}.png"
        (evidence / name).write_bytes(_fixture_png(label))
    (evidence / "person-no-faces.png").write_bytes(_fixture_png("A4"))
    payload = {"environment": "simulator", "vision_available": False}
    (evidence / "vision-environment.json").write_text(json.dumps(payload), encoding="utf-8")


def _write_switch_display_bridge(
    evidence: Path,
    *,
    screenshot: bytes | None = None,
    setting_source: str = "accessibility_ui",
    mode_after: str = "singlePhoto",
    process_id_after: int = 44,
) -> None:
    (evidence / "switch-b-single-after.png").write_bytes(
        _fixture_png("A1", "b") if screenshot is None else screenshot
    )
    (evidence / "display-policy-after-switch.json").write_text(
        json.dumps(
            {
                "identity_source": "public_fixture_photo_mark",
                "setting_source": setting_source,
                "mode_after": mode_after,
                "process_id_before": 44,
                "process_id_after": process_id_after,
            }
        ),
        encoding="utf-8",
    )


class MemberManifestContractTests(unittest.TestCase):
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


class PlaybackMembershipAndIdentityTests(unittest.TestCase):
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


class PersonRuleContractTests(unittest.TestCase):
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


class AlbumPersonUnionContractTests(unittest.TestCase):
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
        assert_observed_covers_object_uniques(
            expected,
            "a",
            album_ids,
            person_filters,
        )
        for missing_index in range(len(expected)):
            incomplete = expected[:missing_index] + expected[missing_index + 1 :]
            with self.assertRaises(FilterContractError) as raised:
                assert_observed_covers_object_uniques(
                    incomplete,
                    "a",
                    album_ids,
                    person_filters,
                )
            self.assertIn("Missing selection-union members", str(raised.exception))
        with self.assertRaises(FilterContractError) as raised:
            assert_observed_covers_object_uniques(
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


class EmptySelectionAndCrossServerTests(unittest.TestCase):
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


class RequestLogContractTests(unittest.TestCase):
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


class DeviceFilterVisualIdentityTests(unittest.TestCase):
    def _write_pngs(self, evidence: Path, names_and_labels: list[tuple[str, str]], fixture_set: str = "a") -> None:
        write_member_manifest(evidence / "member-manifest.json", fixture_set)
        for name, label in names_and_labels:
            (evidence / f"{name}.png").write_bytes(_fixture_png(label, fixture_set))

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


class DisplayPolicyVisualContractTests(unittest.TestCase):
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

    def _write_evidence(
        self,
        evidence: Path,
        *,
        before: bytes,
        after: bytes,
        setting_source: str = "accessibility_ui",
        mode_before: str = "smartFill",
        mode_after: str = "singlePhoto",
    ) -> None:
        write_member_manifest(evidence / "member-manifest.json", "a")
        (evidence / "display-before.png").write_bytes(before)
        candidate_step = f"{DISPLAY_POLICY_CANDIDATE_PREFIX}01"
        (evidence / f"{candidate_step}.png").write_bytes(before)
        (evidence / "display-after.png").write_bytes(after)
        (evidence / "display-policy.json").write_text(
            json.dumps(
                {
                    "identity_source": "public_fixture_photo_mark",
                    "setting_source": setting_source,
                    "mode_before": mode_before,
                    "mode_after": mode_after,
                    "process_id_before": 44,
                    "process_id_after": 44,
                    "before_candidate_steps": [candidate_step],
                    "selected_before_step": candidate_step,
                }
            ),
            encoding="utf-8",
        )

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


class AlbumEditSwitchVisualContractTests(unittest.TestCase):
    def _write_valid_evidence(self, evidence: Path) -> None:
        write_member_manifest(evidence / "member-manifest.json", "a")
        (evidence / "album-switch-b-play-1.png").write_bytes(_fixture_png("A4"))
        (evidence / "album-switch-b-play-2.png").write_bytes(_fixture_png("A5"))
        (evidence / "album-edit-modes.json").write_text(
            json.dumps(
                {
                    "identity_source": "accessibility_ui",
                    "selected_album_id_after_replace": "album-a-non-target",
                    "mode_after_replace": "filtered",
                    "mode_after_clear_and_exit": "random",
                }
            ),
            encoding="utf-8",
        )

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


class SwiftContractMirrorTests(unittest.TestCase):
    def test_swift_helper_keeps_frozen_ids_and_button(self) -> None:
        source = (SCRIPT_DIR.parent / "TestSupport" / "StrictE2EFilterContract.swift").read_text(
            encoding="utf-8"
        )
        # Cross-language constant sync: the button ID and frozen fixture hashes must match the Swift mirror, or E2E
        # finds the wrong element or uses the wrong fixture.
        self.assertIn(START_PLAYBACK_BUTTON_ID, source)
        self.assertIn(FROZEN_FIXTURE_SHA256["a"], source)
        self.assertIn(FROZEN_FIXTURE_SHA256["b"], source)


class FilterVisualIdentityFromScreenshotsTests(unittest.TestCase):
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


class ServerABFailClosedTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
