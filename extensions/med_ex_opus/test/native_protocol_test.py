"""Exercise the built encoder without BEAM: python3 test/native_protocol_test.py PATH."""

import math
import struct
import subprocess
import sys
import unittest
from pathlib import Path


ENCODER = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else None


def packet(payload):
    return struct.pack(">I", len(payload)) + payload


def unpack(data):
    frames = []
    while data:
        if len(data) < 4:
            raise AssertionError("truncated output header")
        size = struct.unpack(">I", data[:4])[0]
        if len(data) < 4 + size:
            raise AssertionError("truncated output payload")
        frames.append(data[4:4 + size])
        data = data[4 + size:]
    return frames


class NativeProtocolTest(unittest.TestCase):
    def run_encoder(self, data):
        result = subprocess.run([ENCODER], input=data, capture_output=True, timeout=5)
        frames = unpack(result.stdout)
        self.assertTrue(frames[0].startswith(b"med_ex_opus/1 libopus "))
        return result.returncode, frames[1:]

    def test_clean_eof_is_success(self):
        self.assertEqual(self.run_encoder(b""), (0, []))

    def test_partial_header_is_a_protocol_failure(self):
        for length in (1, 2, 3):
            with self.subTest(length=length):
                self.assertEqual(self.run_encoder(b"\0" * length), (4, []))

    def test_bad_lengths_and_partial_payload_are_rejected(self):
        for length in (0, 1919, 1921, 0xFFFFFFFF):
            with self.subTest(length=length):
                self.assertEqual(self.run_encoder(struct.pack(">I", length)), (4, []))
        self.assertEqual(self.run_encoder(struct.pack(">I", 1920) + b"\0" * 1919), (4, []))

    def test_one_opus_packet_is_returned_per_pcm_frame(self):
        pcm = b"".join(struct.pack("<h", int(12000 * math.sin(i / 20))) for i in range(960))
        status, frames = self.run_encoder(packet(pcm) + packet(pcm))
        self.assertEqual(status, 0)
        self.assertEqual(len(frames), 2)
        self.assertTrue(all(0 < len(frame) <= 1275 for frame in frames))


if __name__ == "__main__":
    if ENCODER is None:
        raise SystemExit("Usage: python3 test/native_protocol_test.py PATH_TO_ENCODER")
    unittest.main()
