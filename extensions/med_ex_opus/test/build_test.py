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
                        'case "$4" in *xiph.org*) if [ -n "$BAD_PRIMARY" ]; then echo bad > "$3"; exit 0; fi;; esac\n'
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

    def test_bad_primary_uses_verified_mirror(self):
        archive = self.fixture_tarball()
        cache = self.root / "cache"
        self.env.update(CURL_FIXTURE=str(archive), BAD_PRIMARY="1", XDG_CACHE_HOME=str(cache))
        self.build_library(self.root / "app")
        self.assertEqual(self.log.read_text(), "calledcalled")
        self.assertEqual((cache / "med_ex_opus/opus-1.5.2.tar.gz").read_bytes(), archive.read_bytes())

    def test_empty_pin_and_unavailable_hash_commands_fail_closed(self):
        archive = self.fixture_tarball()
        (self.root / "c_src/vendor/SHA256SUMS").write_text("")
        for command in ("sha256sum", "shasum"):
            path = self.bin / command
            path.write_text("#!/bin/sh\nexit 1\n")
            path.chmod(0o755)
        result = self.make(f"MIX_APP_PATH={self.root / 'app'}", f"MED_EX_OPUS_TARBALL={archive}")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "configure.log").exists())

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

    def test_warm_missing_explicit_archive_cannot_reuse_library_or_binary(self):
        archive = self.fixture_tarball()
        self.env["MED_EX_OPUS_TARBALL"] = str(archive)
        app = self.root / "app"
        self.build_library(app)
        (app / "priv").mkdir()
        (app / "priv/opus_encoder").write_text("stale executable")
        archive.unlink()
        result = self.make(f"MIX_APP_PATH={app}", str(app / "opus_build/install/lib/libopus.a"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((app / "priv/opus_encoder").exists())
        self.assertFalse((app / "opus_build/.library-key").exists())
        self.assertFalse(self.log.exists())

    def test_warm_corrupt_or_relative_archive_fails_before_cache_reuse(self):
        for kind in ("corrupt", "relative"):
            archive = self.fixture_tarball()
            self.env["MED_EX_OPUS_TARBALL"] = str(archive)
            app = self.root / kind
            self.build_library(app)
            if kind == "corrupt":
                archive.write_bytes(b"damaged")
            else:
                self.env["MED_EX_OPUS_TARBALL"] = archive.name
            result = self.make(f"MIX_APP_PATH={app}", str(app / "opus_build/install/lib/libopus.a"))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((app / "opus_build/.library-key").exists())

    def test_unchanged_validated_identity_does_not_touch_stamp(self):
        self.env["MED_EX_OPUS_TARBALL"] = str(self.fixture_tarball())
        app = self.root / "app"
        self.build_library(app)
        stamp = app / "opus_build/.library-key"
        original = (stamp.read_bytes(), stamp.stat().st_mtime_ns)
        self.build_library(app)
        self.assertEqual(original, (stamp.read_bytes(), stamp.stat().st_mtime_ns))
        self.assertEqual((self.root / "configure.log").read_text(), "configured")

    def test_pin_flags_and_toolchain_identity_invalidate_warm_library(self):
        archive = self.fixture_tarball()
        self.env["MED_EX_OPUS_TARBALL"] = str(archive)
        app = self.root / "app"
        self.build_library(app)
        self.env["CFLAGS"] = "-O1"
        self.build_library(app)
        self.env["MED_EX_OPUS_CONFIGURE_FLAGS"] = "--disable-tests"
        self.build_library(app)
        compiler = self.bin / "fixture-cc"
        compiler.write_text("#!/bin/sh\ncase \"$1\" in --version) echo fixture-toolchain;; -dumpmachine) echo fixture-target;; *) exec cc \"$@\";; esac\n")
        compiler.chmod(0o755)
        self.env["CC"] = str(compiler)
        self.build_library(app)
        pin = self.root / "c_src/vendor/SHA256SUMS"
        pin.write_text(pin.read_text() + "\n")
        self.build_library(app)
        self.assertEqual((self.root / "configure.log").read_text(), "configured" * 5)

    def test_partial_stamp_never_authorizes_cache(self):
        self.env["MED_EX_OPUS_TARBALL"] = str(self.fixture_tarball())
        app = self.root / "app"
        self.build_library(app)
        (app / "opus_build/.library-key").write_text("partial")
        self.build_library(app)
        self.assertEqual((self.root / "configure.log").read_text(), "configuredconfigured")
        self.assertEqual(len((app / "opus_build/.library-key").read_text().strip()), 64)

    def test_parallel_same_directory_builds_are_serialized(self):
        self.env["MED_EX_OPUS_TARBALL"] = str(self.fixture_tarball())
        app = self.root / "app"
        command = ["make", f"MIX_APP_PATH={app}", str(app / "opus_build/install/lib/libopus.a")]
        processes = [subprocess.Popen(command, cwd=self.root, env=self.env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(4)]
        for process in processes:
            output, error = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, output + error)
        self.assertEqual((self.root / "configure.log").read_text(), "configured")
        self.assertEqual(list(app.glob(".opus-work.*")), [])
        self.assertEqual(list(app.glob(".opus-input.*")), [])

    def test_symlink_archive_and_traversal_are_refused(self):
        archive = self.fixture_tarball()
        link = self.root / "archive-link"
        link.symlink_to(archive)
        self.env["MED_EX_OPUS_TARBALL"] = str(link)
        self.assertNotEqual(self.make(f"MIX_APP_PATH={self.root / 'app'}").returncode, 0)
        bad = self.root / "traversal.tar.gz"
        with tarfile.open(bad, "w:gz") as tar:
            entry = tarfile.TarInfo("opus-1.5.2/../../escape")
            entry.size = 1
            tar.addfile(entry, io.BytesIO(b"x"))
        (self.root / "c_src/vendor/SHA256SUMS").write_text(
            hashlib.sha256(bad.read_bytes()).hexdigest() + "  opus-1.5.2.tar.gz\n")
        self.env["MED_EX_OPUS_TARBALL"] = str(bad)
        self.assertNotEqual(self.make(f"MIX_APP_PATH={self.root / 'app'}").returncode, 0)
        self.assertFalse((self.root / "escape").exists())

    def test_unset_build_root_fails_before_recipes_including_clean(self):
        for args in ([], ["clean"]):
            with self.subTest(args=args):
                result = self.make("--dry-run", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("MIX_APP_PATH", result.stderr)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
