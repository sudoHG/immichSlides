#!/usr/bin/env python3
"""Shared filter contract.

Member labels must be checked against classify_screenshot; the final pool is the union of the per-object sets.
"""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping, Sequence

from strict_e2e_photo_identity import MARKS, classify_public_pattern, classify_screenshot, public_letter_from_bytes
from strict_e2e_server import PUBLIC_API_KEY, _fixture_data, fixture_manifest, public_visual_label


# Hashes track the public fixture manifest fields.
# The empty-album fixture B uses its own glyphs and bars.
FROZEN_FIXTURE_SHA256 = {
    "a": "44f9dc4b144e5fcc5dd14a98b76ba1bf1ca8829648555aebe738c3e2b3048989",
    "b": "4eaeac910ff1abf6555225368882e989f7cd5d5fd568f2cccde20fab60bacf71",
}
START_PLAYBACK_BUTTON_ID = "filterSummary.startPlayback.button"
MEMBER_MANIFEST_KIND = "strict-e2e-member-manifest"
ALLOWED_IDENTITY_SOURCES = frozenset({"public_fixture_photo_mark"})
FILTER_VISUAL_SUITES = (
    "display-policy",
    "filter-album",
    "filter-edit-switch",
    "filter-empty",
    "filter-person",
    "filter-switch",
    "filter-vision",
    "tvos-album",
    "tvos-display-policy",
    "tvos-edit-switch",
    "tvos-person",
    "tvos-switch",
)
FILTER_ALBUM_STEPS = ("album-play-1", "album-play-2", "album-play-3")
FILTER_PERSON_STEPS = {
    "normal_match": "person-normal-1",
    "conflict_normal": "person-conflict-normal-1",
    "no_faces": "person-nofaces-1",
}
FILTER_SWITCH_STEPS = ("switch-b-play-1", "switch-b-play-2")
FILTER_EDIT_SWITCH_STEPS = ("album-switch-b-play-1", "album-switch-b-play-2")
DISPLAY_REGION_BOXES = {
    "center": (0.28, 0.18, 0.72, 0.82),
    "left": (0.0, 0.12, 0.18, 0.82),
    "right": (0.82, 0.12, 1.0, 0.82),
    "top": (0.20, 0.02, 0.80, 0.16),
    "upper": (0.0, 0.0, 1.0, 0.40),
    "mid_left": (0.18, 0.20, 0.42, 0.80),
    "mid_right": (0.58, 0.20, 0.82, 0.80),
    "top_half": (0.0, 0.0, 1.0, 0.50),
    "bottom_half": (0.0, 0.50, 1.0, 1.0),
}
DISPLAY_REGION_PAIRS = (("left", "right"), ("mid_left", "mid_right"), ("center", "bottom_half"))
DISPLAY_POLICY_CANDIDATE_PREFIX = "display-before-candidate-"
REQUEST_LOG_LINE = re.compile(
    r"^request elapsed_ms=\d+ method=(GET|POST) path=\S+ status=\d+ "
    r"range=(present|absent) fixture_asset_id=\S+"
    r"(?: size=(?:thumbnail|preview|fullsize))?$"
)


class FilterContractError(Exception):
    pass


DISPLAY_MINIMUM_SURROUND_FRACTION = 0.04
DISPLAY_REFERENCE_SAMPLE_PIXELS = 80
DISPLAY_FOREGROUND_CHANNEL_TOLERANCE = 24
DISPLAY_MINIMUM_FOREGROUND_MATCH_RATIO = 0.98
DISPLAY_SURROUND_SAMPLE_WIDTH_PIXELS = 240
DISPLAY_MINIMUM_SAMPLE_HEIGHT_PIXELS = 8
DISPLAY_UI_WHITE_CHANNEL_THRESHOLD = 175
DISPLAY_UI_BLACK_CHANNEL_THRESHOLD = 12
DISPLAY_UI_INK_DILATION_PIXELS = 5
DISPLAY_PUBLIC_COLOR_CHANNEL_TOLERANCE = 15
DISPLAY_FOREGROUND_PADDING_PIXELS = 4
DISPLAY_TEXTURE_EDGE_CHANNEL_DELTA = 45
DISPLAY_TEXTURE_CELL_PIXELS = 20
DISPLAY_COLOR_EDGE_CHANNEL_DELTA = 35
DISPLAY_SHARP_COLOR_EDGE_LIMIT = 4
DISPLAY_TEXTURE_AXIS_EDGE_LIMIT = 80
DISPLAY_TEXTURE_BOTH_AXES_EDGE_LIMIT = 12
DISPLAY_BACKGROUND_BLUR_FRACTIONS = (0.025, 0.0625, 0.125)
DISPLAY_BACKGROUND_SAMPLE_STRIDE_PIXELS = 4
DISPLAY_BACKGROUND_CHROMA_TOLERANCE = 26
DISPLAY_MINIMUM_BACKGROUND_MATCH_RATIO = 0.90
DISPLAY_MINIMUM_REGION_IMAGE_PIXELS = 16

def _labels_for(asset_ids: Sequence[str], label_by_id: Mapping[str, str]) -> list[str]:
    try:
        return [label_by_id[asset_id] for asset_id in asset_ids]
    except KeyError as error:
        raise FilterContractError(f"member manifest references an unknown asset: {error}") from error


def _asset_includes_person(asset: Mapping[str, Any], person_id: str) -> bool:
    return any(person.get("id") == person_id for person in asset.get("people") or [])


def _solo_only_qualified(asset: Mapping[str, Any], person_id: str) -> bool:
    # soloOnly only narrows this person's own set: group photos, photos without faces and unassigned faces are excluded.
    people = asset.get("people") or []
    if len(people) != 1 or people[0].get("id") != person_id:
        return False
    if len(people[0].get("faces") or []) != 1:
        return False
    if asset.get("unassignedFaces"):
        return False
    return True


def _set_entry(assets: Sequence[Mapping[str, Any]]) -> dict[str, list[str]]:
    return {
        "asset_ids": [asset["id"] for asset in assets],
        "labels": [asset["label"] for asset in assets],
    }


def _object_sets(fixture: Mapping[str, Any]) -> dict[str, Any]:
    # Each selected album and each person mode is its own set; the final pool is their union.
    # A1/A2/A3/A5 are not hard-coded here.
    assets_by_id = {asset["id"]: asset for asset in fixture["assets"]}
    albums = {}
    for album in fixture["albums"]:
        albums[album["id"]] = _set_entry([assets_by_id[asset_id] for asset_id in album["assetIds"]])
    people: dict[str, Any] = {}
    for person in fixture["people"]:
        person_id = person["id"]
        people[person_id] = {
            "normal": _set_entry(
                [asset for asset in fixture["assets"] if _asset_includes_person(asset, person_id)]
            ),
            "soloOnly": _set_entry(
                [asset for asset in fixture["assets"] if _solo_only_qualified(asset, person_id)]
            ),
        }
    return {"albums": albums, "people": people}


def _person_filter_items(person_filters: Sequence[object]) -> list[tuple[str, str]]:
    items: list[tuple[str, str]] = []
    for raw in person_filters:
        if isinstance(raw, Mapping) and isinstance(raw.get("person_id"), str) and isinstance(raw.get("mode"), str):
            items.append((raw["person_id"], raw["mode"]))
            continue
        raise FilterContractError("a person filter must be a separate person_id + mode")
    return items


def _unique_extend(labels: list[str], extra: Sequence[str]) -> None:
    seen = set(labels)
    for label in extra:
        if label not in seen:
            seen.add(label)
            labels.append(label)


def _classified_mark(image_bytes: bytes, *, asset_id: str) -> str:
    identity = classify_screenshot(image_bytes)
    if identity.status != "MATCH" or identity.mark not in MARKS:
        raise FilterContractError(
            "member-manifest labels do not match classify_screenshot: "
            f"{asset_id} status={identity.status} mark={identity.mark}"
        )
    return identity.mark


def _album_label_pairs(payload: Mapping[str, Any], key: str) -> list[tuple[str, str]]:
    album = payload.get(key)
    if not isinstance(album, Mapping):
        raise FilterContractError(f"member-manifest labels do not match classify_screenshot: missing {key}")
    asset_ids = album.get("asset_ids")
    labels = album.get("labels")
    if not isinstance(asset_ids, list) or not isinstance(labels, list) or len(asset_ids) != len(labels):
        raise FilterContractError(
            f"member-manifest labels do not match classify_screenshot: {key} lengths differ"
        )
    pairs: list[tuple[str, str]] = []
    for asset_id, label in zip(asset_ids, labels):
        if not isinstance(asset_id, str) or not isinstance(label, str):
            raise FilterContractError(
                f"member-manifest labels do not match classify_screenshot: {key} contains non-strings"
            )
        pairs.append((asset_id, label))
    return pairs


def _assert_labels_match_photo_identity(payload: Mapping[str, Any]) -> None:
    # Index names A1–A5 cannot stand in for image identity;
    # both write and read check the public fixture images, fail-closed.
    fixture_set = payload.get("fixture_set")
    if fixture_set not in FROZEN_FIXTURE_SHA256:
        raise FilterContractError("member manifest fixture set is unknown")
    images = _fixture_data(str(fixture_set))["images"]
    pairs = _album_label_pairs(payload, "target_album") + _album_label_pairs(payload, "non_target_album")
    if len(pairs) != 5:
        raise FilterContractError("member-manifest labels do not match classify_screenshot: must cover all five photos")
    classified: list[str] = []
    for asset_id, expected in pairs:
        image = images.get(asset_id)
        if image is None:
            raise FilterContractError(
                f"member-manifest labels do not match classify_screenshot: missing image {asset_id}"
            )
        mark = _classified_mark(image, asset_id=asset_id)
        if mark != expected:
            raise FilterContractError(
                "member-manifest labels do not match classify_screenshot: "
                f"{asset_id} expected={expected} mark={mark}"
            )
        pattern = classify_public_pattern(image)
        if pattern != fixture_set:
            raise FilterContractError(
                "member-manifest public pattern does not match the fixture set: "
                f"{asset_id} pattern={pattern} set={fixture_set}"
            )
        classified.append(mark)
    if len(set(classified)) != 5 or set(classified) != set(MARKS):
        raise FilterContractError(
            "member-manifest labels do not match classify_screenshot: all five must MATCH and tell A1–A5 apart"
        )
    label_by_id = dict(pairs)
    person_cases = payload.get("person_cases")
    if not isinstance(person_cases, Mapping):
        raise FilterContractError("member-manifest labels do not match classify_screenshot: missing person_cases")
    for name, case in person_cases.items():
        if not isinstance(case, Mapping):
            raise FilterContractError(
                f"member-manifest labels do not match classify_screenshot: person_cases {name}"
            )
        asset_ids = case.get("asset_ids")
        labels = case.get("labels")
        if not isinstance(asset_ids, list) or not isinstance(labels, list):
            raise FilterContractError(
                f"member-manifest labels do not match classify_screenshot: person_cases {name}"
            )
        expected_labels: list[str] = []
        for asset_id in asset_ids:
            if not isinstance(asset_id, str) or asset_id not in label_by_id:
                raise FilterContractError(
                    "member-manifest labels do not match classify_screenshot: "
                    f"person_cases {name} {asset_id}"
                )
            expected_labels.append(label_by_id[asset_id])
        if labels != expected_labels:
            raise FilterContractError(
                "member-manifest labels do not match classify_screenshot: "
                f"person_cases {name} expected={expected_labels} labels={labels}"
            )
    expected_object_sets = _object_sets(fixture_manifest(str(fixture_set)))
    if payload.get("object_sets") != expected_object_sets:
        raise FilterContractError("member-manifest independent object sets do not match fixture derivation")


def member_manifest(fixture_set: str) -> dict[str, Any]:
    fixture = fixture_manifest(fixture_set)
    frozen_hash = FROZEN_FIXTURE_SHA256.get(fixture_set)
    if frozen_hash is None or fixture["fixture_sha256"] != frozen_hash:
        raise FilterContractError("fixture hash has drifted from the frozen contract")

    label_by_id = {asset["id"]: asset["label"] for asset in fixture["assets"]}
    albums = {album["fixture_role"]: album for album in fixture["albums"]}
    person_cases = fixture["person_cases"]
    target = albums["target"]
    non_target = albums["non_target"]
    empty = albums["empty"]
    payload = {
        "schema_version": 1,
        "kind": MEMBER_MANIFEST_KIND,
        "fixture_set": fixture_set,
        "fixture_sha256": fixture["fixture_sha256"],
        "identity_source": "public_fixture_photo_mark",
        "request_log_is_not_identity": True,
        "start_playback_button_id": START_PLAYBACK_BUTTON_ID,
        "all_asset_ids": list(fixture["asset_ids"]),
        "all_album_ids": list(fixture["album_ids"]),
        "all_person_ids": list(fixture["person_ids"]),
        "target_album": {
            "id": target["id"],
            "asset_ids": list(target["assetIds"]),
            "labels": _labels_for(target["assetIds"], label_by_id),
            "visual_labels": [
                public_visual_label(str(fixture_set), int(str(asset_id).rsplit("-", 1)[-1]))
                for asset_id in target["assetIds"]
            ],
        },
        "non_target_album": {
            "id": non_target["id"],
            "asset_ids": list(non_target["assetIds"]),
            "labels": _labels_for(non_target["assetIds"], label_by_id),
            "visual_labels": [
                public_visual_label(str(fixture_set), int(str(asset_id).rsplit("-", 1)[-1]))
                for asset_id in non_target["assetIds"]
            ],
        },
        "empty_album": {
            "id": empty["id"],
            "asset_ids": list(empty["assetIds"]),
            "labels": _labels_for(empty["assetIds"], label_by_id),
            "asset_count": empty["assetCount"],
        },
        "person_cases": {
            "normal_match": {
                "person_id": f"person-{fixture_set}-normal",
                "asset_ids": list(person_cases["normal_match"]),
                "labels": _labels_for(person_cases["normal_match"], label_by_id),
            },
            "solo_only_qualified": {
                "person_id": f"person-{fixture_set}-solo",
                "asset_ids": list(person_cases["solo_only_qualified"]),
                "labels": _labels_for(person_cases["solo_only_qualified"], label_by_id),
            },
            "multiple_people_disqualified": {
                "person_id": f"person-{fixture_set}-solo",
                "asset_ids": list(person_cases["multiple_people_disqualified"]),
                "labels": _labels_for(person_cases["multiple_people_disqualified"], label_by_id),
            },
            "no_faces": {
                "person_id": f"person-{fixture_set}-no-faces",
                "asset_ids": list(person_cases["no_faces"]),
                "labels": _labels_for(person_cases["no_faces"], label_by_id),
            },
            # Conflict and soloOnly may share one public mark and must not be written as wins;
            # the album+person playback pool is the object_sets union.
            "normal_plus_solo_conflict": {
                "person_id": f"person-{fixture_set}-solo",
                "modes": ["normal", "soloOnly"],
                "asset_ids": list(person_cases["solo_only_qualified"]),
                "labels": _labels_for(person_cases["solo_only_qualified"], label_by_id),
            },
        },
        "object_sets": _object_sets(fixture),
    }
    _assert_labels_match_photo_identity(payload)
    return payload


def write_member_manifest(path: Path, fixture_set: str) -> dict[str, Any]:
    payload = member_manifest(fixture_set)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    references = path.parent / "public-reference-images"
    references.mkdir(exist_ok=True)
    for name in ("a", "b"):
        for index, image in enumerate(_fixture_data(name)["images"].values(), start=1):
            (references / f"{name.upper()}{index}.png").write_bytes(image)
    return payload


def load_member_manifest(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FilterContractError(f"Missing member manifest: {path.name}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FilterContractError(f"member manifest is unreadable: {error}") from error
    if not isinstance(payload, dict) or payload.get("kind") != MEMBER_MANIFEST_KIND:
        raise FilterContractError("member manifest is not the frozen contract")
    fixture_set = payload.get("fixture_set")
    if fixture_set not in FROZEN_FIXTURE_SHA256:
        raise FilterContractError("member manifest fixture set is unknown")
    expected_hash = fixture_manifest(str(fixture_set))["fixture_sha256"]
    frozen_hash = FROZEN_FIXTURE_SHA256[str(fixture_set)]
    if payload.get("fixture_sha256") != expected_hash or payload.get("fixture_sha256") != frozen_hash:
        raise FilterContractError("member manifest fixture hash does not match the frozen contract")
    _assert_labels_match_photo_identity(payload)
    return payload


def require_photo_mark(source: str, status: str, mark: str | None) -> str:
    if source not in ALLOWED_IDENTITY_SOURCES:
        raise FilterContractError("Request logs, indexes, and probes cannot be used as identity truth")
    if status != "MATCH" or mark not in MARKS:
        raise FilterContractError(f"Unrecognizable input cannot count as passing: status={status} mark={mark}")
    return mark


def assert_playback_marks_in_target(marks: Sequence[str], fixture_set: str) -> None:
    if not marks:
        raise FilterContractError("Empty playback membership cannot count as passing")
    allowed = member_manifest(fixture_set)["target_album"]["labels"]
    wrong = [mark for mark in marks if mark not in allowed]
    if wrong:
        raise FilterContractError("Unexpected members cannot count as passing: " + ", ".join(wrong))


def selection_is_empty(
    *,
    album_ids: Sequence[str],
    person_filters: Sequence[object],
    tag_ids: Sequence[str] = (),
    rating: int | None = None,
    is_favorite: bool | None = None,
) -> bool:
    return not album_ids and not person_filters and not tag_ids and rating is None and is_favorite is None


def assert_empty_selection_cannot_start(
    *,
    album_ids: Sequence[str],
    person_filters: Sequence[object],
    start_enabled: bool,
    tag_ids: Sequence[str] = (),
    rating: int | None = None,
    is_favorite: bool | None = None,
) -> None:
    empty = selection_is_empty(
        album_ids=album_ids,
        person_filters=person_filters,
        tag_ids=tag_ids,
        rating=rating,
        is_favorite=is_favorite,
    )
    if empty and start_enabled:
        raise FilterContractError("An empty selection cannot start")
    if (not empty) != start_enabled:
        raise FilterContractError("start button state does not match the selection contract")


def assert_solo_only_not_vacuous(
    *,
    environment: str,
    vision_available: bool,
    qualified_marks: Sequence[str],
    face_counts: Mapping[str, int | None],
    fixture_set: str,
) -> None:
    if environment != "device":
        raise FilterContractError("Simulator Vision cannot substitute for a device; soloOnly must not be marked PASS")
    if not vision_available:
        raise FilterContractError("Vision unavailable; soloOnly must not pass by accident")
    if not qualified_marks:
        raise FilterContractError("An empty soloOnly result cannot pass by coincidence from an empty set")
    allowed = set(member_manifest(fixture_set)["person_cases"]["solo_only_qualified"]["labels"])
    for mark in qualified_marks:
        if mark not in allowed:
            raise FilterContractError(f"Unexpected members cannot count as a soloOnly pass: {mark}")
        if face_counts.get(mark) != 1:
            raise FilterContractError(f"no faces or face count is not 1; cannot count as a soloOnly pass: {mark}")


def assert_foreign_server_ids_absent(observed_ids: Sequence[str], local_fixture_set: str) -> None:
    local = member_manifest(local_fixture_set)
    allowed = set(local["all_asset_ids"]) | set(local["all_album_ids"]) | set(local["all_person_ids"])
    foreign = [item for item in observed_ids if item not in allowed]
    if foreign:
        raise FilterContractError("Cross-server stale IDs remain: " + ", ".join(foreign))
