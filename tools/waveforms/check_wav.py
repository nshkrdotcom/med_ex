#!/usr/bin/env python3
"""Independent WAV PCM verification helper for MedEx clinical audio fixtures.

Run via: `uv run --locked python check_wav.py <path-to-wav>`
"""

from __future__ import annotations

import hashlib
import json
import sys
import wave
from pathlib import Path


def inspect_wav(path: Path) -> dict[str, object]:
    with wave.open(str(path), "rb") as wf:
        channels = wf.getnchannels()
        sample_width = wf.getsampwidth()
        sample_rate_hz = wf.getframerate()
        frame_count = wf.getnframes()
        pcm = wf.readframes(frame_count)

    duration_ms = round((frame_count / sample_rate_hz) * 1000) if sample_rate_hz else 0
    return {
        "file": path.name,
        "channels": channels,
        "bits_per_sample": sample_width * 8,
        "sample_rate_hz": sample_rate_hz,
        "sample_count": frame_count,
        "duration_ms": duration_ms,
        "pcm_byte_size": len(pcm),
        "pcm_sha256": hashlib.sha256(pcm).hexdigest(),
        "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: check_wav.py <path-to-wav>", file=sys.stderr)
        return 2
    target = Path(argv[1])
    print(json.dumps(inspect_wav(target), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
