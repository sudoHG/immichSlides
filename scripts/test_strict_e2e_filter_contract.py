"""Discovery entry point preserving the existing test class identities."""

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

from strict_e2e_filter_contract_test_membership_cases import MemberManifestContractTestsCases

class MemberManifestContractTests(MemberManifestContractTestsCases, unittest.TestCase):
    pass


from strict_e2e_filter_contract_test_membership_cases import PlaybackMembershipAndIdentityTestsCases

class PlaybackMembershipAndIdentityTests(PlaybackMembershipAndIdentityTestsCases, unittest.TestCase):
    pass


from strict_e2e_filter_contract_test_membership_cases import PersonRuleContractTestsCases

class PersonRuleContractTests(PersonRuleContractTestsCases, unittest.TestCase):
    pass


from strict_e2e_filter_contract_test_membership_cases import AlbumPersonUnionContractTestsCases

class AlbumPersonUnionContractTests(AlbumPersonUnionContractTestsCases, unittest.TestCase):
    pass


from strict_e2e_filter_contract_test_membership_cases import EmptySelectionAndCrossServerTestsCases

class EmptySelectionAndCrossServerTests(EmptySelectionAndCrossServerTestsCases, unittest.TestCase):
    pass


from strict_e2e_filter_contract_test_membership_cases import RequestLogContractTestsCases

class RequestLogContractTests(RequestLogContractTestsCases, unittest.TestCase):
    pass


from strict_e2e_filter_contract_test_display_cases import DeviceFilterVisualIdentityTestsCases

class DeviceFilterVisualIdentityTests(DeviceFilterVisualIdentityTestsCases, unittest.TestCase):
    def _write_pngs(self, evidence: Path, names_and_labels: list[tuple[str, str]], fixture_set: str = "a") -> None:
        write_member_manifest(evidence / "member-manifest.json", fixture_set)
        for name, label in names_and_labels:
            (evidence / f"{name}.png").write_bytes(_fixture_png(label, fixture_set))




from strict_e2e_filter_contract_test_display_cases import DisplayPolicyVisualContractTestsCases

class DisplayPolicyVisualContractTests(DisplayPolicyVisualContractTestsCases, unittest.TestCase):
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




from strict_e2e_filter_contract_test_display_cases import AlbumEditSwitchVisualContractTestsCases

class AlbumEditSwitchVisualContractTests(AlbumEditSwitchVisualContractTestsCases, unittest.TestCase):
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




from strict_e2e_filter_contract_test_identity_cases import SwiftContractMirrorTestsCases

class SwiftContractMirrorTests(SwiftContractMirrorTestsCases, unittest.TestCase):
    pass


from strict_e2e_filter_contract_test_identity_cases import FilterVisualIdentityFromScreenshotsTestsCases

class FilterVisualIdentityFromScreenshotsTests(FilterVisualIdentityFromScreenshotsTestsCases, unittest.TestCase):
    pass


from strict_e2e_filter_contract_test_identity_cases import ServerABFailClosedTestsCases

class ServerABFailClosedTests(ServerABFailClosedTestsCases, unittest.TestCase):
    pass


if __name__ == "__main__":
    unittest.main()
