"""Compile actual framing code with scripted I/O; no libopus qualification claim."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
CASES = (
    "clean_eof", "fragmented_frames", "short_header", "short_payload",
    "invalid_length", "read_error", "write_error_header", "write_error_payload",
    "zero_write", "codec_error", "hello_overflow", "create_error", "exact_read_states",
)


class NativeIOTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which(os.environ.get("CC", "cc"))
        if compiler is None:
            raise RuntimeError("native I/O unit checks require a C11 compiler")
        cls.temporary = tempfile.TemporaryDirectory(prefix="med-ex-opus-io-")
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        (root / "opus.h").write_text("""
#include <stdint.h>
typedef int16_t opus_int16;
typedef int32_t opus_int32;
typedef struct { int unused; } OpusEncoder;
#define OPUS_APPLICATION_AUDIO 2049
#define OPUS_OK 0
OpusEncoder *opus_encoder_create(opus_int32, int, int, int *);
void opus_encoder_destroy(OpusEncoder *);
const char *opus_get_version_string(void);
opus_int32 opus_encode(OpusEncoder *, const opus_int16 *, int, unsigned char *, opus_int32);
""")
        cls.binary = root / "native_io_test"
        result = subprocess.run([
            compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            "-fstack-protector-strong", "-D_FORTIFY_SOURCE=2", "-I", str(root),
            str(PROJECT / "test/native_io_test.c"), "-o", str(cls.binary),
        ], capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)


def check_case(case):
    def test(self):
        result = subprocess.run([self.binary, case], input=b"", capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
    return test


for name in CASES:
    setattr(NativeIOTest, "test_" + name, check_case(name))


if __name__ == "__main__":
    unittest.main()
