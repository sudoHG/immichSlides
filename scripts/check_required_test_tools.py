#!/usr/bin/env python3
"""Fail explicitly when prerequisites for the complete Python test suite are unavailable."""

import argparse
import importlib.util
import shutil
import sys


def missing_tools(*, portable=False) -> list[str]:
    missing = []
    for executable, guidance in [
        ("swift", "Swift: select an installed Xcode toolchain or provision Swift on PATH"),
        ("zstd", "zstd: provision the zstd CLI on PATH for compressed evidence scan tests"),
    ]:
        if portable and executable == "swift":
            continue
        if shutil.which(executable) is None:
            missing.append(guidance)
    for module, package in (("PIL", "Pillow"), ("yaml", "PyYAML")):
        if importlib.util.find_spec(module) is None:
            missing.append(f"{package}: use a Python environment with {package} installed")
    return missing


def main(argv=()) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portable", action="store_true", help="Swift execution belongs to the paired macOS partition")
    args = parser.parse_args(argv)
    missing = missing_tools(portable=args.portable)
    if missing:
        print("Missing Python test prerequisites:\n" + "\n".join(missing), file=sys.stderr)
        return 1
    print("Python test prerequisites available: " + ("" if args.portable else "Swift, ") + "zstd, Pillow, PyYAML")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
