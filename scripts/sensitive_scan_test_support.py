"""Synthetic compressed-byte coincidence fixture for scanner tests only."""

import random
import re
import subprocess


def compressed_byte_coincidence() -> tuple[bytes, bytes, str]:
    rng = random.Random(73)
    chunks = [bytes(rng.randrange(32, 127) for _ in range(64)) for _ in range(32)]
    logical = b"".join(rng.choice(chunks) for _ in range(200))
    blob = subprocess.run(
        ["zstd", "-q", "-c", "--no-check"], input=logical, capture_output=True, check=True
    ).stdout
    # Piped input has a window descriptor and no content size or dictionary ID.
    assert blob[4] == 0
    block_header = int.from_bytes(blob[6:9], "little")
    assert (block_header >> 1) & 3 == 2  # A compressed block, not a raw or skippable payload.
    block = blob[9 : 9 + (block_header >> 3)]
    for match in re.finditer(rb"[ -~]{4,}", block):
        run = match.group()
        for start in range(len(run) - 3):
            needle = run[start : start + 4]
            if needle not in logical:
                return blob, logical, needle.decode("ascii")
    raise AssertionError("The real compressed block must contain a cleartext-pattern coincidence")
