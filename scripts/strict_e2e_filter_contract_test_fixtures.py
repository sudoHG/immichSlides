"""Moved fixtures and imports shared by the existing test classes."""

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


# Real public-fixture chrome, sampled by dominant RGB bins without averaging.
# The origin identifies the photo palette underneath each translucent overlay.
PUBLIC_APP_CHROME_SAMPLES = {
    # switch-b-play-2.png, ffafdacdbc9d56bdc45cb2f6ca66b89caa83c56d8732eda7505e7ac64ac5d57b, (477,2164,1163,2245).
    "ipad-glass": ("a", 3, (
        (255, 122, 223), (255, 120, 219), (255, 116, 232), (0, 0, 0),
        (163, 3, 127), (255, 123, 222), (164, 3, 128), (255, 129, 252),
        (141, 2, 108), (43, 20, 39), (192, 93, 168), (219, 100, 198),
        (223, 60, 185), (119, 2, 87), (66, 30, 60), (171, 78, 155))),
    # switch-b-play-1.png, 3a9f1302c0c4e5da8665d94460c322c3c48ab6cc4d1461632dd1ea80f400c142, (884,60,1580,442).
    "ipad-exif": ("b", 7, (
        (255, 133, 244), (255, 255, 255), (232, 121, 222), (236, 123, 226),
        (223, 116, 213), (255, 207, 254), (185, 51, 144), (233, 166, 227),
        (229, 141, 221), (187, 98, 187), (223, 140, 223), (233, 95, 233),
        (229, 164, 223), (221, 84, 184), (234, 95, 197), (226, 90, 191))),
    # server-switch-a-play-1.png, cc34b34054eb297817ad847fe0adad24df66773a35ff20866bcadecce4824de2, (68,2126,1102,2314).
    "iphone-glass": ("a", 1, (
        (0, 0, 0), (37, 109, 19), (91, 61, 91), (255, 255, 255),
        (27, 86, 14), (183, 166, 182), (155, 187, 146), (226, 239, 222),
        (174, 192, 167), (139, 189, 126), (156, 207, 143), (142, 200, 127),
        (165, 211, 153), (160, 179, 152), (223, 238, 219), (192, 223, 184))),
    # switch-b-play-1.png, 4a43319ef30e268941c2dbe81096629c2805f206a293c8bb0f7dbd1c476060fa, (329,186,1130,591).
    "iphone-exif": ("b", 7, (
        (152, 57, 255), (255, 255, 255), (226, 62, 160), (223, 61, 158),
        (233, 64, 165), (224, 62, 159), (133, 50, 223), (255, 147, 255),
        (255, 180, 255), (254, 121, 239), (161, 63, 255), (164, 65, 255),
        (251, 83, 194), (120, 30, 245), (46, 5, 166), (83, 18, 205))),
    # TV server-switch-a-play-1.png, e5a20b2cc56c32612c4a32a449ad32ebf66bb1b351304f6aa5e795dbc7af205a.
    # Entry hint (1332,1440,2080,1648); focus glass (1256,1716,2580,1925); EXIF (2930,62,3620,442).
    "tv-entry-hint": ("a", 1, (
        (252, 251, 252), (90, 55, 90), (31, 112, 9), (96, 62, 96),
        (34, 114, 13), (98, 64, 98), (95, 77, 95), (96, 62, 95),
        (177, 177, 177), (95, 62, 96), (30, 88, 15), (127, 102, 127),
        (192, 192, 191), (193, 193, 192), (193, 191, 191), (216, 229, 212))),
    "tv-focus-glass": ("a", 1, (
        (255, 255, 255), (109, 79, 109), (68, 132, 52), (58, 131, 39),
        (55, 125, 37), (213, 213, 213), (0, 0, 0), (35, 103, 18),
        (78, 52, 78), (32, 95, 17), (65, 126, 50), (130, 88, 130),
        (172, 102, 172), (157, 97, 157), (208, 123, 208), (105, 149, 94))),
    "tv-exif": ("a", 1, (
        (113, 82, 113), (255, 255, 255), (58, 131, 39), (52, 118, 35),
        (91, 61, 91), (37, 109, 19), (129, 88, 129), (95, 69, 95),
        (162, 100, 162), (155, 99, 155), (50, 149, 24), (160, 144, 160),
        (41, 169, 7), (29, 195, 0), (156, 139, 156), (126, 104, 126))),
    # display-after.png, a393b61561f17328c4dde1d718376f73a2a665a2d39a4d850c5d8acb19daa009, (543,2330,1097,2349).
    "home-indicator": (None, None, (
        (84, 62, 91), (88, 62, 97), (136, 74, 156), (127, 69, 144),
        (100, 65, 111), (94, 64, 104), (96, 63, 106))),
    # Native edge strips: retain the dominant exact RGB in every 32-channel bin, without averaging.
    # server-switch-a-play-1.png, SHA 9f44e8935770690cdcfec83ca491f163f0272cfc2db160d9e313d916a9245c44, native (3840, 2160).
    # Edge strips ((3000, 59, 3530, 64), (3000, 438, 3530, 443), (2928, 110, 2934, 389), (3614, 110, 3620, 389)).
    "tv-exif-edges": ("a", 1, (
        (17, 223, 0), (11, 238, 0), (55, 93, 43), (37, 109, 19),
        (48, 99, 33), (49, 155, 22), (55, 138, 33), (48, 161, 20),
        (61, 162, 33), (47, 217, 0), (36, 224, 0), (91, 61, 91),
        (66, 83, 58), (73, 77, 67), (82, 124, 68), (67, 135, 49),
        (87, 159, 64), (94, 190, 61), (68, 205, 26), (79, 199, 43),
        (122, 85, 122), (97, 113, 88), (107, 106, 101), (108, 156, 88),
        (125, 158, 106), (108, 182, 78), (129, 88, 129), (129, 117, 122),
        (155, 99, 155), (138, 152, 121), (157, 154, 142), (133, 168, 109),
        (186, 108, 186), (168, 148, 156), (180, 141, 171), (193, 119, 190),
        (200, 115, 200), (198, 129, 195), (216, 120, 216), (213, 121, 213))),
    # server-switch-a-play-1.png, SHA 9f44e8935770690cdcfec83ca491f163f0272cfc2db160d9e313d916a9245c44, native (3840, 2160).
    # Edge strips ((1380, 1438, 2030, 1445), (1450, 1643, 2030, 1650), (1330, 1480, 1337, 1608), (2075, 1480, 2082, 1608)).
    "tv-entry-hint-edges": ("a", 1, (
        (31, 93, 16), (31, 112, 9), (32, 94, 16), (52, 92, 42),
        (32, 112, 9), (62, 102, 52), (58, 128, 39), (66, 44, 66),
        (95, 62, 96), (95, 77, 95), (67, 118, 54), (73, 106, 65),
        (67, 135, 48), (80, 141, 64), (96, 62, 95), (96, 63, 96),
        (106, 84, 106), (126, 98, 126), (127, 100, 128), (105, 157, 92),
        (110, 159, 97), (116, 163, 103), (128, 100, 127), (135, 110, 135),
        (154, 135, 154), (159, 142, 160), (133, 173, 123), (140, 177, 131),
        (160, 142, 159), (169, 153, 169), (165, 190, 159), (177, 177, 177),
        (191, 187, 192), (166, 195, 159), (178, 196, 171), (192, 189, 191),
        (192, 188, 192), (192, 202, 189), (217, 217, 217))),
    # server-switch-a-play-1.png, SHA 9f44e8935770690cdcfec83ca491f163f0272cfc2db160d9e313d916a9245c44, native (3840, 2160).
    # Edge strips ((1350, 1714, 2490, 1722), (1350, 1918, 2490, 1926), (1254, 1780, 1262, 1860), (2574, 1780, 2582, 1860)).
    "tv-control-edges": ("a", 1, (
        (31, 91, 16), (24, 186, 0), (18, 202, 0), (24, 224, 14),
        (32, 95, 17), (33, 96, 17), (54, 123, 36), (43, 155, 14),
        (51, 128, 32), (51, 172, 21), (60, 170, 34), (37, 193, 16),
        (32, 229, 14), (78, 52, 78), (90, 66, 90), (72, 122, 60),
        (80, 127, 70), (73, 128, 60), (82, 133, 69), (65, 191, 33),
        (88, 179, 64), (72, 221, 33), (94, 200, 64), (65, 235, 19),
        (81, 235, 38), (109, 79, 109), (100, 118, 93), (121, 99, 121),
        (96, 138, 86), (124, 156, 115), (97, 185, 73), (127, 160, 119),
        (107, 213, 76), (122, 216, 96), (97, 235, 58), (114, 237, 77),
        (141, 93, 141), (157, 97, 157), (128, 159, 121), (150, 138, 150),
        (134, 163, 127), (148, 172, 141), (143, 220, 117), (159, 215, 140),
        (133, 236, 98), (172, 102, 172), (161, 152, 161), (160, 180, 155),
        (173, 188, 169), (164, 194, 156), (185, 196, 182), (175, 239, 144),
        (183, 232, 161), (208, 123, 208), (192, 155, 192), (194, 187, 194),
        (192, 214, 186), (223, 223, 223), (193, 239, 170), (222, 235, 218),
        (228, 156, 228), (238, 190, 238), (224, 214, 224), (231, 240, 215),
        (244, 244, 244))),
    # switch-b-play-1.png, SHA 3a9f1302c0c4e5da8665d94460c322c3c48ab6cc4d1461632dd1ea80f400c142, native (1640, 2360).
    # Edge strips ((930, 58, 1530, 65), (930, 438, 1530, 445), (882, 110, 890, 392), (1575, 110, 1583, 392)).
    "ipad-exif-edges": ("b", 7, (
        (185, 51, 144), (189, 55, 189), (193, 58, 153), (195, 60, 195),
        (200, 65, 161), (217, 81, 217), (225, 87, 188), (230, 92, 193),
        (229, 92, 229), (250, 110, 215), (250, 110, 250), (255, 133, 244),
        (255, 173, 252), (255, 207, 254), (255, 255, 255))),
    # immichslides-switch-r1-ipad-native-hint.png, SHA 4e9f80924c9056f837e4a6824ca79005d6ce6fedac4368e38a25affbf7adf890, native (1640, 2360).
    # Edge strips ((544, 1918, 1056, 1926), (650, 2084, 1056, 2093), (500, 1960, 508, 2050), (1092, 1960, 1100, 2050)).
    # Unscaled video frame at 42s; movie SHA d71209722b2668eec79f6e8028fd33427ddcf8209dd9381be03a1f7b61eaa621.
    "ipad-entry-hint-edges": ("a", 3, (
        (95, 28, 61), (94, 40, 48), (123, 12, 88), (126, 6, 100),
        (101, 46, 51), (124, 34, 77), (108, 61, 97), (118, 74, 80),
        (116, 77, 109), (143, 1, 110), (129, 62, 95), (153, 54, 117),
        (155, 40, 131), (131, 76, 81), (138, 66, 103), (151, 119, 124),
        (153, 122, 129), (159, 129, 131), (179, 27, 146), (160, 40, 133),
        (178, 94, 159), (179, 95, 160), (175, 97, 155), (187, 102, 167),
        (167, 139, 146), (181, 158, 161), (189, 169, 172), (207, 122, 187),
        (214, 123, 192), (193, 129, 175), (207, 155, 196), (211, 161, 173),
        (209, 161, 198), (216, 205, 208), (238, 115, 208), (249, 129, 222),
        (255, 137, 232), (224, 171, 183), (237, 173, 222), (255, 160, 251),
        (225, 198, 218), (232, 217, 230), (238, 238, 238))),
    # server-switch-a-play-1.png, SHA 2380aebec7d61dfa75762cbe9ec398819cc26591eb4a6e261d7cdb17c649fcbe, native (1640, 2360).
    # Edge strips ((540, 2117, 1100, 2125), (540, 2230, 1100, 2239), (475, 2155, 483, 2201), (1158, 2155, 1166, 2201)).
    "ipad-control-edges": ("a", 3, (
        (54, 19, 22), (67, 26, 30), (73, 30, 33), (93, 41, 46),
        (108, 28, 65), (111, 51, 57), (120, 43, 69), (120, 65, 75),
        (136, 29, 91), (143, 2, 109), (130, 59, 87), (143, 84, 89),
        (149, 90, 96), (156, 96, 102), (160, 7, 123), (165, 3, 129),
        (163, 80, 117), (179, 91, 135), (163, 102, 107), (186, 122, 129),
        (190, 131, 140), (221, 63, 180), (192, 96, 149), (205, 106, 162),
        (209, 148, 159), (222, 148, 173), (227, 68, 187), (248, 93, 220),
        (226, 122, 184), (255, 124, 223), (255, 123, 225), (225, 148, 177),
        (252, 157, 207), (254, 143, 240), (235, 169, 176), (255, 183, 192),
        (255, 171, 224))),
    # switch-b-play-1.png, SHA 4a43319ef30e268941c2dbe81096629c2805f206a293c8bb0f7dbd1c476060fa, native (1170, 2532).
    # Edge strips ((385, 183, 1075, 191), (385, 586, 1075, 594), (326, 240, 334, 540), (1126, 240, 1134, 540)).
    "iphone-exif-edges": ("b", 7, (
        (59, 6, 146), (46, 5, 166), (85, 7, 119), (71, 6, 132),
        (83, 18, 205), (115, 8, 94), (99, 7, 106), (126, 21, 160),
        (96, 23, 217), (120, 30, 245), (126, 42, 247), (156, 9, 70),
        (158, 24, 137), (128, 21, 163), (156, 34, 218), (152, 57, 255),
        (166, 9, 68), (188, 26, 115), (160, 24, 139), (184, 37, 191),
        (187, 38, 194), (174, 58, 249), (169, 68, 255), (205, 27, 109),
        (219, 35, 126), (222, 36, 129), (219, 42, 170), (214, 62, 223),
        (215, 63, 224), (208, 93, 254), (222, 106, 254), (242, 44, 148),
        (249, 57, 160), (226, 63, 214), (255, 70, 181), (252, 90, 203),
        (254, 121, 239), (255, 147, 255), (255, 180, 255))),
    # immichslides-switch-r1-iphone-native-hint41.png, SHA 2ea1f9518b2ea806aaa48fb626c22bbf98e996785c167a732d61ea53e109667f, native (1170, 2532).
    # Edge strips ((150, 1847, 825, 1855), (300, 2080, 825, 2088), (96, 1900, 104, 2035), (875, 1900, 883, 2035)).
    # Unscaled video frame at 41s; movie SHA c6ca5e799e55d4f03ffa9e0043eb4257a3e21bb2cdb7b2d9cb6cd3a6654ddc73.
    "iphone-entry-hint-edges": ("a", 1, (
        (18, 63, 9), (20, 66, 9), (34, 58, 25), (59, 39, 59),
        (37, 87, 27), (58, 94, 49), (59, 98, 48), (65, 48, 63),
        (75, 55, 75), (65, 68, 60), (89, 73, 90), (95, 89, 96),
        (66, 96, 60), (88, 101, 82), (101, 86, 103), (125, 119, 123),
        (127, 125, 129), (127, 136, 124), (127, 130, 130), (127, 167, 117),
        (129, 123, 126), (129, 123, 130), (129, 137, 125), (153, 153, 153),
        (159, 143, 160), (136, 175, 125), (139, 179, 129), (160, 144, 161),
        (160, 160, 158), (167, 167, 167), (190, 193, 190), (192, 194, 189),
        (195, 197, 195))),
    # server-switch-a-play-1.png, SHA 0b2ab5a1ab231354d19c0b29515c84ae18cfa53153bed72ec69163682a1c63fe, native (1170, 2532).
    # Edge strips ((168, 2126, 1000, 2134), (168, 2305, 1000, 2313), (69, 2190, 77, 2250), (1093, 2190, 1101, 2250)).
    "iphone-control-edges": ("a", 1, (
        (29, 15, 29), (8, 42, 3), (27, 86, 14), (31, 96, 16),
        (43, 26, 43), (60, 38, 60), (36, 79, 24), (58, 90, 47),
        (37, 109, 19), (47, 100, 32), (91, 61, 91), (70, 80, 63),
        (81, 70, 78), (71, 120, 59), (78, 124, 67), (78, 137, 63),
        (89, 144, 75), (104, 76, 104), (97, 123, 88), (124, 104, 124),
        (99, 149, 86), (121, 159, 111), (109, 160, 95), (125, 169, 111),
        (138, 117, 138), (128, 131, 124), (158, 143, 158), (135, 175, 125),
        (159, 179, 153), (143, 204, 127), (148, 216, 131), (157, 238, 136),
        (173, 158, 173), (161, 178, 155), (168, 177, 164), (162, 220, 146),
        (189, 193, 184), (163, 235, 146), (188, 248, 173), (192, 169, 191),
        (194, 170, 193), (195, 203, 189), (208, 199, 208), (199, 236, 188),
        (220, 248, 212), (224, 199, 223), (228, 196, 227), (226, 242, 222),
        (255, 255, 255))),
}


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
    fixture_set: str = "a",
) -> None:
    write_member_manifest(evidence / "member-manifest.json", fixture_set)
    (evidence / "person-normal.png").write_bytes(_fixture_png("A1", fixture_set))
    for index, label in enumerate(conflict):
        name = "person-conflict-normal.png" if index == 0 else f"person-conflict-normal-{index + 1}.png"
        (evidence / name).write_bytes(_fixture_png(label, fixture_set))
    (evidence / "person-no-faces.png").write_bytes(_fixture_png("A4", fixture_set))
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
