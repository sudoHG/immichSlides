#!/usr/bin/env python3
"""Entry point for the 15 album and server cases. By default this script only prints commands and runs
host checks; it does not run devices."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from album_server_narrow_contract import (
    OFFICIAL_CASES,
    AlbumServerContractError,
    official_device_command,
    empty_album_is_listed,
    official_case_count,
    validate_official_case_table,
)
from strict_e2e_filter_contract import FROZEN_FIXTURE_SHA256
from strict_e2e_photo_identity import classify_public_pattern
from strict_e2e_server import PUBLIC_API_KEY, _fixture_data, fixture_manifest


REPO_ROOT = Path(__file__).resolve().parent.parent
DESTINATION_PLACEHOLDERS = {
    "iphone": "platform=iOS Simulator,id=<IPHONE_UDID>",
    "ipad": "platform=iOS Simulator,id=<IPAD_UDID>",
    "tvos": "platform=tvOS Simulator,id=<TVOS_UDID>",
}


def host_check() -> int:
    try:
        validate_official_case_table()
        if official_case_count() != 15:
            raise AlbumServerContractError("official method count is not 15")
        if fixture_manifest("a")["fixture_sha256"] != FROZEN_FIXTURE_SHA256["a"]:
            raise AlbumServerContractError("fixture A hash deviates from the frozen contract")
        if fixture_manifest("b")["fixture_sha256"] != FROZEN_FIXTURE_SHA256["b"]:
            raise AlbumServerContractError("fixture B hash deviates from the frozen contract")
        if not empty_album_is_listed("a") or not empty_album_is_listed("b"):
            raise AlbumServerContractError("A/B must list the controlled empty album")
        image_a = _fixture_data("a")["images"]["asset-a-1"]
        image_b = _fixture_data("b")["images"]["asset-b-1"]
        if image_a == image_b:
            raise AlbumServerContractError("A/B public patterns must not be byte-for-byte identical")
        if classify_public_pattern(image_a) != "a" or classify_public_pattern(image_b) != "b":
            raise AlbumServerContractError("A/B public patterns must be visually distinguishable and bound to their fixture set")
    except AlbumServerContractError as error:
        print(str(error), file=sys.stderr)
        return 2
    print(json.dumps({"official_cases": 15, "empty_album": True, "device_run": False}, sort_keys=True))
    return 0


def print_case_command(case_id: str) -> int:
    case = next((item for item in OFFICIAL_CASES if item["id"] == case_id), None)
    if case is None:
        print(f"Unknown case-id: {case_id}", file=sys.stderr)
        return 2
    command = official_device_command(
        case=case,
        destination=DESTINATION_PLACEHOLDERS[case["platform"]],
        derived_data=Path("<DERIVED_DATA>"),
        result_bundle=Path("<RESULT_BUNDLE>"),
        evidence_dir=Path("<EVIDENCE_DIR>"),
        server_url="http://127.0.0.1:<PORT_A>/api",
        server_url_b="http://127.0.0.1:<PORT_B>/api" if case["narrow"] == "server-switch" else None,
    )
    print(" ".join(command))
    return 0


def print_all_commands() -> int:
    for case in OFFICIAL_CASES:
        print(
            f"#{case['id']} {case['platform']} {case['narrow']} {case['selector']} scenario={case['scenario']}"
        )
        print_case_command(case["id"])
        print()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host-check", action="store_true")
    parser.add_argument("--list-cases", action="store_true")
    parser.add_argument("--print-command", action="store_true")
    parser.add_argument("--print-commands", action="store_true")
    parser.add_argument("--case-id")
    parser.add_argument("--execute-device", action="store_true")
    arguments = parser.parse_args(argv)
    if arguments.execute_device:
        print("Test preparation does not run devices.", file=sys.stderr)
        return 2
    if arguments.host_check:
        return host_check()
    if arguments.list_cases:
        for case in OFFICIAL_CASES:
            print(
                json.dumps(
                    {
                        "id": case["id"],
                        "platform": case["platform"],
                        "narrow": case["narrow"],
                        "selector": case["selector"],
                        "scenario": case["scenario"],
                    },
                    ensure_ascii=False,
                )
            )
        print(f"PUBLIC_API_KEY_NAME=immichslides-public-e2e-key len={len(PUBLIC_API_KEY)}")
        return 0
    if arguments.print_command:
        if not arguments.case_id:
            print("--print-command requires --case-id", file=sys.stderr)
            return 2
        return print_case_command(arguments.case_id)
    if arguments.print_commands:
        return print_all_commands()
    return host_check()


if __name__ == "__main__":
    sys.exit(main())
