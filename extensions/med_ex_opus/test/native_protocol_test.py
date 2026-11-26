"""Exercise the built encoder without BEAM: python3 test/native_protocol_test.py PATH."""

import ctypes
import ctypes.util
import math
import os
import select
import signal
import struct
import subprocess
import sys
import unittest
from pathlib import Path


ENCODER = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else None

TONE = b"".join(struct.pack("<h", int(12000 * math.sin(i / 20))) for i in range(960))


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

    @unittest.skipUnless(sys.platform.startswith("linux"), "uses procfs to observe the codec child")
    def test_retirement_reaps_a_stopped_codec(self):
        with subprocess.Popen([ENCODER], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as port:
            children = Path(f"/proc/{port.pid}/task/{port.pid}/children")
            try:
                size = struct.unpack(">I", port.stdout.read(4))[0]
                self.assertTrue(port.stdout.read(size).startswith(b"med_ex_opus/1 "))
                worker, = map(int, children.read_text().split())
                os.kill(worker, signal.SIGSTOP)
                port.stdout.close()
                self.assertEqual(port.wait(timeout=2), 128 + signal.SIGKILL)
                self.assertFalse(Path(f"/proc/{worker}").exists())
            finally:
                if port.poll() is None:
                    port.stdin.close()
                    for child in children.read_text().split():
                        try:
                            os.kill(int(child), signal.SIGCONT)
                        except ProcessLookupError:
                            pass
                    port.wait(timeout=2)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux parent-death signal")
    def test_supervisor_kill_terminates_stopped_codec(self):
        # Adopt and reap the orphan ourselves so this also works in containers
        # whose PID 1 does not reap adopted children.
        libc = ctypes.CDLL(None)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)  # PR_SET_CHILD_SUBREAPER
        self.addCleanup(libc.prctl, 36, 0, 0, 0, 0)
        with subprocess.Popen([ENCODER], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as port:
            size = struct.unpack(">I", port.stdout.read(4))[0]
            self.assertTrue(port.stdout.read(size).startswith(b"med_ex_opus/1 "))
            children = Path(f"/proc/{port.pid}/task/{port.pid}/children")
            child, = map(int, children.read_text().split())
            os.kill(child, signal.SIGSTOP)
            fd = os.pidfd_open(child)
            try:
                port.kill()
                port.wait(timeout=2)
                self.assertTrue(select.select([fd], [], [], 2)[0], "codec survived supervisor")
            finally:
                signal.pidfd_send_signal(fd, signal.SIGKILL)
                os.close(fd)
                _, status = os.waitpid(child, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), -signal.SIGKILL)

    def test_partial_header_is_a_protocol_failure(self):
        for length in (1, 2, 3):
            with self.subTest(length=length):
                self.assertEqual(self.run_encoder(b"\0" * length), (4, []))

    def test_bad_lengths_and_partial_payload_are_rejected(self):
        for length in (0, 1919, 1921, 0xFFFFFFFF):
            with self.subTest(length=length):
                self.assertEqual(self.run_encoder(struct.pack(">I", length)), (4, []))
        self.assertEqual(self.run_encoder(struct.pack(">I", 1920) + b"\0" * 1919), (4, []))

    def test_tone_decodes_to_one_non_silent_frame(self):
        pcm = TONE
        status, packets = self.run_encoder(packet(pcm))
        self.assertEqual(status, 0)
        encoded, = packets

        library = ctypes.util.find_library("opus")
        self.assertIsNotNone(library, "codec qualification requires the libopus shared library")
        opus = ctypes.CDLL(library)
        opus.opus_decoder_create.argtypes = (ctypes.c_int32, ctypes.c_int, ctypes.POINTER(ctypes.c_int))
        opus.opus_decoder_create.restype = ctypes.c_void_p
        opus.opus_decoder_destroy.argtypes = (ctypes.c_void_p,)
        opus.opus_decoder_destroy.restype = None
        opus.opus_decode.argtypes = (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32,
                                     ctypes.POINTER(ctypes.c_int16), ctypes.c_int, ctypes.c_int)
        opus.opus_decode.restype = ctypes.c_int
        error = ctypes.c_int()
        decoder = opus.opus_decoder_create(48000, 1, ctypes.byref(error))
        self.assertEqual(error.value, 0)
        self.assertTrue(decoder)
        self.addCleanup(opus.opus_decoder_destroy, decoder)
        samples = (ctypes.c_int16 * 960)()
        self.assertTrue(encoded)
        self.assertEqual(opus.opus_decode(decoder, encoded, len(encoded), samples, 960, 0), 960)
        self.assertGreater(sum(s * s for s in samples) / len(samples), 1000 ** 2)

    def test_one_opus_packet_is_returned_per_pcm_frame(self):
        pcm = TONE
        status, frames = self.run_encoder(packet(pcm) + packet(pcm))
        self.assertEqual(status, 0)
        self.assertEqual(len(frames), 2)
        self.assertTrue(all(0 < len(frame) <= 1275 for frame in frames))


if __name__ == "__main__":
    if ENCODER is None:
        raise SystemExit("Usage: python3 test/native_protocol_test.py PATH_TO_ENCODER")
    unittest.main()
