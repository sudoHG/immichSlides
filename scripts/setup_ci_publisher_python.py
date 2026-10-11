#!/usr/bin/env python3
"""Create the publisher's minimal Linux environment from central package pins."""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from setup_ci_python import PINS_PATH, load_pins, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--venv", required=True, type=Path)
    parser.add_argument("--host-checks", action="store_true", help="Install the existing Pillow pin for portable host tests as well")
    args = parser.parse_args()
    try:
        if args.venv.exists() or args.venv.is_symlink():
            raise ValueError("Refusing to overwrite an existing environment")
        packages = {name: version for name, version in load_pins(PINS_PATH)["python_packages"].items()
                    if args.host_checks or name in {"pip", "PyYAML"}}
        run([sys.executable, "-I", "-m", "venv", str(args.venv.resolve())])
        executable = str(args.venv.resolve() / "bin/python3")
        environment = {key: value for key, value in os.environ.items() if not key.startswith(("PIP_", "PYTHON"))}
        environment["PIP_CONFIG_FILE"] = os.devnull
        run([executable, "-I", "-m", "pip", "--isolated", "install", "--disable-pip-version-check",
             "--index-url", "https://pypi.org/simple", "--only-binary=:all:", "--no-deps", "--no-cache-dir",
             *[f"{name}=={version}" for name, version in packages.items()]], env=environment, timeout=300)
        observed = json.loads(run([executable, "-I", "-c", "import importlib.metadata,json; "
            "print(json.dumps({name:importlib.metadata.version(name) for name in " + repr(list(packages)) + "}))"]))
        if observed != packages:
            raise ValueError("Publisher package pin mismatch")
        run([executable, "-I", "-m", "pip", "--isolated", "check"])
        print("Publisher Python packages PASS: " + json.dumps(observed, sort_keys=True))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print("Publisher environment setup refused invalid pins or installation", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
