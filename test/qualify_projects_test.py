#!/usr/bin/env python3
"""Exercise the real shell dispatcher; external tools are controlled fixtures.

This proves orchestration/failure behavior, never Elixir or application health.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]


class ProjectDispatchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="medex-dispatch-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "build_support").mkdir()
        for name in ("receipt_fixture.sh", "qualify_projects.sh"):
            shutil.copy2(SOURCE / "build_support" / name, self.root / "build_support" / name)
        self.trace = self.root / "commands"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        script = """#!/bin/bash
set -eu
name=${0##*/}
if [[ "$name" == python3 && "${1:-}" == - ]]; then
  exec "$REAL_PYTHON" "$@"
fi
printf '%s\\n' "$name $*" >> "$TRACE"
[[ "$name ${1:-}" != "${FAIL_TASK:-}" ]] || exit 7
"""
        for name in ("mix", "elixir", "node", "python3"):
            path = self.bin / name
            path.write_text(script)
            path.chmod(0o755)
        architecture = self.root / "build_support/check_architecture.sh"
        architecture.write_text("#!/bin/bash\nprintf 'architecture\\n' >> \"$TRACE\"\n")
        architecture.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        REAL_PYTHON=sys.executable, TRACE=str(self.trace),
                        MEDEX_RECEIPT_VECTORS=str(SOURCE / "core/med_core/test/fixtures/receipt_vectors_v2.json"))

    def run_dispatch(self, *args, failure=""):
        result = subprocess.run(["bash", "build_support/qualify_projects.sh", *args],
                                cwd=self.root, env=dict(self.env, FAIL_TASK=failure),
                                text=True, capture_output=True, timeout=10)
        commands = self.trace.read_text().splitlines() if self.trace.exists() else []
        return result, commands

    def test_sdk_one_root_matrix_with_bounded_jobs(self):
        result, commands = self.run_dispatch("sdk", "--fast", "--jobs", "3")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual([line for line in commands if line.startswith("mix ")],
                         ["mix setup --jobs 3", "mix quality --jobs 3"])
        self.assertNotIn("architecture", commands)

    def test_release_uses_locked_setup_and_production_quality(self):
        result, commands = self.run_dispatch("fabric", "--jobs", "1")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("mix setup --jobs 1 --locked", commands)
        self.assertIn("mix quality --jobs 1 --release", commands)
        self.assertFalse(any("mix dialyzer" in command for command in commands))

    def test_setup_failure_blocks_only_dependent_quality(self):
        result, commands = self.run_dispatch("sdk", "--fast", failure="mix setup")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any("native_io_test.py" in line for line in commands))
        self.assertFalse(any(line.startswith("mix quality") for line in commands))
        self.assertIn("BLOCKED project quality", result.stdout)

    def test_independent_failure_is_aggregated_and_does_not_stop_matrix(self):
        result, commands = self.run_dispatch("fabric", "--fast", failure="node --test")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("python3 ops/verify_soak_report_test.py", commands)
        self.assertIn("mix quality --jobs 2", commands)
        self.assertIn("failures=2", result.stdout)

    def test_release_refuses_source_selector_before_build(self):
        (self.root / ".mix_sources.json").write_text("{}")
        result, commands = self.run_dispatch("fabric")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(commands, [])
        self.assertIn("default locked Fabric checkout", result.stderr)

    def test_checks_only_never_bootstraps_or_repeats_the_source_matrix(self):
        result, commands = self.run_dispatch("sdk", "--checks-only")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue(any("native_io_test.py" in line for line in commands))
        self.assertFalse(any(line.startswith("mix ") for line in commands))

    def test_invalid_job_count_never_runs_tools(self):
        result, commands = self.run_dispatch("sdk", "--jobs", "5")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(commands, [])


if __name__ == "__main__":
    unittest.main()
