#!/usr/bin/env python3
"""Create and start a shard's fresh pinned simulator before Python setup and downloads."""

import argparse
import os
import subprocess
import time
from pathlib import Path

from ci_summary import ContractError, decode, require

PINS_PATH = Path(__file__).resolve().parent / "ci-pins.json"
SIMULATOR_SETUP_COMMAND_TIMEOUT_SECONDS = 60


def create_and_boot_simulator(device, shard):
    require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
            "automatic simulator creation is hosted-only")
    pins = decode(PINS_PATH.read_text())
    platform_name = "tvos" if device == "appletv" else "ios"
    try:
        udid = subprocess.check_output(["xcrun", "simctl", "create", "ui-" + device + "-" + shard,
            pins["device_types"][device], pins["simulators"][platform_name]["runtime"]],
            text=True, timeout=SIMULATOR_SETUP_COMMAND_TIMEOUT_SECONDS).strip()
    except subprocess.TimeoutExpired:
        raise ContractError("Simulator creation timed out after 60 seconds") from None
    require(bool(udid), "Simulator creation returned no device")
    destination_platform = "tvOS Simulator" if platform_name == "tvos" else "iOS Simulator"
    # Export ownership before boot so the job's always-run cleanup also handles boot failure.
    with open(os.environ["GITHUB_ENV"], "a") as handle:
        handle.write(f"UI_SIMULATOR={udid}\nUI_DESTINATION=platform={destination_platform},id={udid}\nUI_PLATFORM={platform_name}\n")
    started = time.monotonic()
    try:
        completed = subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True, text=True,
            check=False, timeout=SIMULATOR_SETUP_COMMAND_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise ContractError("Early simulator boot timed out after 60 seconds") from None
    require(completed.returncode == 0, "Early simulator boot failed")
    print(f"simulator-early-boot: submitted; elapsed={time.monotonic() - started:.1f}s", flush=True)
    return udid


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", choices=("iphone", "ipad", "appletv"), required=True)
    parser.add_argument("--shard", required=True)
    args = parser.parse_args(argv)
    try:
        create_and_boot_simulator(args.device, args.shard)
    except (ContractError, subprocess.CalledProcessError) as error:
        print("Simulator preparation failed: " + (str(error) if isinstance(error, ContractError) else "simctl create failed"))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
