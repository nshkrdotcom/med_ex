"""Native build boundary regressions; fixtures exercise Make without fetching libopus."""

import hashlib
import io
import os
import shutil
import subprocess
import tempfile
import tarfile
import unittest
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]


class BuildTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="med-ex-opus-build-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copy(PROJECT / "Makefile", self.root)
        shutil.copytree(PROJECT / "c_src", self.root / "c_src")
        self.bin = self.root / "tools"
        self.bin.mkdir()
        # A download attempt must be observable without touching the network.
        curl = self.bin / "curl"
        curl.write_text('#!/bin/sh\nprintf called >> "$CURL_LOG"\n'
                        'if [ -n "$CURL_FIXTURE" ]; then cp "$CURL_FIXTURE" "$3"; else exit 79; fi\n')
        curl.chmod(0o755)
        self.log = self.root / "curl.log"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        CURL_LOG=str(self.log), TMPDIR=str(self.root))
        self.env.pop("MIX_APP_PATH", None)
        self.env.pop("MED_EX_OPUS_TARBALL", None)
        self.env.pop("CURL_FIXTURE", None)

    def make(self, *args):
        return subprocess.run(["make", *args], cwd=self.root, env=self.env,
                              text=True, capture_output=True, timeout=10)

    def fixture_tarball(self):
        # A tiny configure/install fixture tests the real extraction and make flow.
        # It is deliberately not a codec build or a substitute for pinned-libopus QC.
        configure = b'''#!/bin/sh
set -eu
for arg; do
  case "$arg" in --prefix=*) prefix=${arg#--prefix=} ;; esac
done
printf configured >> "$CONFIGURE_LOG"
printf 'install:\\n\\tmkdir -p "%s/lib"\\n\\ttouch "%s/lib/libopus.a"\\n' "$prefix" "$prefix" > Makefile
'''
        archive = self.root / "fixture.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            entry = tarfile.TarInfo("opus-1.5.2/configure")
            entry.mode = 0o755
            entry.size = len(configure)
            tar.addfile(entry, io.BytesIO(configure))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.root / "c_src/vendor/SHA256SUMS").write_text(f"{digest}  opus-1.5.2.tar.gz\n")
        self.env["CONFIGURE_LOG"] = str(self.root / "configure.log")
        return archive

    def build_library(self, app):
        target = app / "opus_build/install/lib/libopus.a"
        result = self.make(f"MIX_APP_PATH={app}", str(target))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(target.is_file())

    def test_explicit_missing_offline_tarball_never_downloads(self):
        missing = self.root / "offline" / "opus.tar.gz"
        result = self.make(f"MIX_APP_PATH={self.root / 'app'}", f"MED_EX_OPUS_TARBALL={missing}")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists(), result.stderr)
        self.assertIn("MED_EX_OPUS_TARBALL", result.stderr)
        self.assertFalse(missing.parent.exists())

    def test_bad_checksum_is_rejected_before_extraction(self):
        archive = self.root / "bad.tar.gz"
        archive.write_bytes(b"untrusted tarball")
        result = self.make(f"MIX_APP_PATH={self.root / 'app'}", f"MED_EX_OPUS_TARBALL={archive}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertFalse((self.root / "app" / "opus_build").exists())
        self.assertFalse(self.log.exists())

    def test_existing_explicit_tarball_builds_without_network(self):
        self.env["MED_EX_OPUS_TARBALL"] = str(self.fixture_tarball())
        self.build_library(self.root / "app")
        self.assertFalse(self.log.exists())

    def test_relative_tarball_is_rejected_before_building(self):
        archive = self.fixture_tarball()
        self.env["MED_EX_OPUS_TARBALL"] = archive.name
        app = self.root / "app"
        result = self.make(f"MIX_APP_PATH={app}", str(app / "opus_build/install/lib/libopus.a"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MED_EX_OPUS_TARBALL must be an absolute path", result.stderr)
        self.assertFalse((app / "opus_build").exists())
        self.assertFalse(self.log.exists())

    def test_download_is_cached_and_reverified_for_a_fresh_build(self):
        self.env["CURL_FIXTURE"] = str(self.fixture_tarball())
        self.env["XDG_CACHE_HOME"] = str(self.root / "cache")
        self.build_library(self.root / "first")
        self.env["MED_EX_OPUS_TARBALL"] = ""
        self.build_library(self.root / "second")
        self.assertEqual(self.log.read_text(), "called")

        cached = self.root / "cache/med_ex_opus/opus-1.5.2.tar.gz"
        cached.write_bytes(b"corrupt cache")
        result = self.make(f"MIX_APP_PATH={self.root / 'third'}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertFalse((self.root / "third/opus_build").exists())
        self.assertEqual(self.log.read_text(), "called")

    def test_failed_download_leaves_cache_ready_for_retry(self):
        archive = self.fixture_tarball()
        bad = self.root / "bad.tar.gz"
        bad.write_bytes(b"incomplete")
        cache = self.root / "cache"
        self.env.update(XDG_CACHE_HOME=str(cache), CURL_FIXTURE=str(bad))
        app = self.root / "app"
        result = self.make(f"MIX_APP_PATH={app}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertEqual(list((cache / "med_ex_opus").iterdir()), [])
        self.env["CURL_FIXTURE"] = str(archive)
        self.build_library(app)

    def test_build_and_clean_reject_spaced_paths_before_running_recipes(self):
        for target in ([], ["clean"]):
            result = self.make("--dry-run", f"MIX_APP_PATH={self.root}/My Project/app", *target)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("MIX_APP_PATH cannot contain whitespace", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_changed_makefile_rebuilds_the_native_library(self):
        self.env["MED_EX_OPUS_TARBALL"] = str(self.fixture_tarball())
        self.build_library(self.root / "app")
        library = self.root / "app/opus_build/install/lib/libopus.a"
        # Use distinct past timestamps even on filesystems with coarse mtimes.
        timestamp = int(library.stat().st_mtime) - 60
        os.utime(self.root / "c_src/vendor/SHA256SUMS", (timestamp - 1, timestamp - 1))
        os.utime(library, (timestamp, timestamp))
        with (self.root / "Makefile").open("a") as makefile:
            makefile.write("\n# changed native build options\n")
        os.utime(self.root / "Makefile", (timestamp + 1, timestamp + 1))
        self.build_library(self.root / "app")
        self.assertEqual((self.root / "configure.log").read_text(), "configuredconfigured")

    def test_unset_build_root_fails_before_recipes_including_clean(self):
        for args in ([], ["clean"]):
            with self.subTest(args=args):
                result = self.make("--dry-run", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("MIX_APP_PATH", result.stderr)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
