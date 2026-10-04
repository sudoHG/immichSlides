#!/usr/bin/env python3
"""Fail explicitly when prerequisites for the complete Python test suite are unavailable."""

import importlib.util
import shutil
import sys


def missing_tools() -> list[str]:
    missing = []
    for executable, guidance in [
        ("swift", "Swift: select an installed Xcode toolchain or provision Swift on PATH"),
        ("zstd", "zstd: provision the zstd CLI on PATH for compressed evidence scan tests"),
    ]:
        if shutil.which(executable) is None:
            missing.append(guidance)
    if importlib.util.find_spec("PIL") is None:
        missing.append("Pillow: use a Python environment with Pillow installed")
    return missing


def main() -> int:
    missing = missing_tools()
    if missing:
        print("Missing Python test prerequisites:\n" + "\n".join(missing), file=sys.stderr)
        return 1
    print("Python test prerequisites available: Swift, zstd, Pillow")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
