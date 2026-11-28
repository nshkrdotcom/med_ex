"""Candidate construction orchestration; replace Mix/Weld/Hex boundaries only."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1]
UPSTREAM = ("med_ex", "med_ex_opus", "med_ex_rtc")
PROJECTS = ("core/domain", "core/store", "apps/exam", "apps/handheld", "apps/preview")


class PrepareCandidatesTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="med-candidate-flow-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.sdk = self.root / "med_ex"
        self.fabric = self.root / "med_fabric"
        self.out = self.root / "evidence"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        matrix = SOURCE / "build_support/release_matrix.json"
        self.versions = {p["name"]: p["version"] for p in json.loads(matrix.read_text())["packages"]}
        self.registry = self.root / "registry"
        (self.registry / "tarballs").mkdir(parents=True)
        for name in UPSTREAM:
            (self.registry / "tarballs" / f"{name}-{self.versions[name]}.tar").write_text(name)
        (self.registry / "public_key").write_text("test key")
        for repo in (self.sdk, self.fabric):
            (repo / "build_support").mkdir(parents=True)
            (repo / "tools/maintainer").mkdir(parents=True)
            (repo / "tools/maintainer/mix.lock").write_text("[]")
            (repo / "mix.lock").write_text("[]")
            shutil.copy2(matrix, repo / "build_support/release_matrix.json")
            self.git(repo, "init", "-q")
        shutil.copy2(SOURCE / "build_support/prepare_candidates.sh", self.sdk / "build_support")
        for project in PROJECTS + ("core/interop",):
            path = self.fabric / project
            path.mkdir(parents=True)
            names = UPSTREAM if project == "apps/preview" else (() if project == "core/interop" else UPSTREAM[:1])
            entries = [["jason", "1.4.5", "hexpm", "c" * 64]]
            entries.extend([name, self.versions[name], "hexpm", "a" * 64] for name in names)
            (path / "mix.lock").write_text(json.dumps(sorted(entries)))
        self.write(self.sdk / "build_support/qualify_ecosystem.sh", "#!/bin/sh\nexit 0\n")
        self.write(self.sdk / "build_support/check_consumers.sh", """#!/bin/bash
set -eu
while [[ $1 != -- ]]; do shift; done
shift
export TEST_REGISTRY_ACTIVE=1
exec "$@"
""")
        self.write(self.fabric / "build_support/prepare_qualification.sh", """#!/bin/bash
set -eu
mkdir "$2"
printf '%s\\n' "$TEST_ROOT/exam-bundle" > "$2/bundle-path"
""")
        self.write(self.bin / "curl", """#!/bin/bash
set -eu
url= output=
while (($#)); do
  case "$1" in
    http://*) url=$1; shift ;;
    -o) output=$2; shift 2 ;;
    --max-time) shift 2 ;;
    *) shift ;;
  esac
done
source="$TEST_ROOT/registry/${url#http://127.0.0.1:12345/}"
if [[ -n "$output" ]]; then cp "$source" "$output"; else cat "$source"; fi
""")
        self.write(self.bin / "mix", """#!/bin/bash
set -eu
[[ "$TEST_REGISTRY_ACTIVE" == 1 ]]
case "$1" in
  hex.repo) echo http://127.0.0.1:12345 ;;
  weld) echo "$TEST_ROOT/sdk-bundle" ;;
  deps.unlock) : ;;
  deps.get)
    if [[ $# == 1 ]]; then
      lock=$(cat mix.lock)
      for name in med_ex med_ex_opus med_ex_rtc; do
        version=$(jq -r --arg name "$name" '.[] | select(.[0] == $name) | .[1]' <<< "$lock")
        if [[ -n "$version" ]]; then
          digest=$(sha256sum "$TEST_ROOT/registry/tarballs/$name-$version.tar" | cut -d' ' -f1)
          lock=$(jq -c --arg name "$name" --arg digest "$digest" 'map(if .[0] == $name then .[3] = $digest else . end)' <<< "$lock")
        fi
      done
      if [[ ${DRIFT:-0} == 1 ]]; then
        lock=$(jq -c 'map(if .[0] == "jason" then .[3] = "changed" else . end)' <<< "$lock")
      fi
      printf '%s' "$lock" > mix.lock
    fi ;;
  hex.build) printf '%s' "${PWD##*/}" > "$3" ;;
  *) exit 90 ;;
esac
""")
        self.write(self.bin / "elixir", """#!/bin/bash
set -eu
if [[ $1 == -r ]]; then cat "${@: -1}"; else
  [[ $2 == inputs ]]
  jq -e '.schema == "medfabric.detached_inputs.v2" and (.packages | length == 6)' "$4" >/dev/null
  echo '{}' > "$5"
fi
""")
        for repo in (self.sdk, self.fabric):
            self.commit(repo)
        self.bundle(self.sdk, "med_ex", "sdk-bundle", (self.registry / "tarballs" / f"med_ex-{self.versions['med_ex']}.tar").read_bytes())
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", TEST_ROOT=str(self.root))

    @staticmethod
    def write(path, text):
        path.write_text(text)
        path.chmod(0o755)

    @staticmethod
    def git(repo, *args):
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()

    def commit(self, repo):
        self.git(repo, "add", ".")
        self.git(repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")

    def bundle(self, repo, app, name, contents):
        directory = self.root / name
        directory.mkdir()
        (directory / "package.tar").write_bytes(contents)
        (directory / "bundle.json").write_text(json.dumps({
            "schema": "weld.bundle/2", "artifact": app, "source": {"commit": self.git(repo, "rev-parse", "HEAD")},
            "archive_sha256": hashlib.sha256(contents).hexdigest(),
        }))

    def run_stage(self, stage, **env):
        return subprocess.run([str(self.sdk / "build_support/prepare_candidates.sh"), stage, str(self.out)],
                              env=dict(self.env, **env), text=True, capture_output=True, timeout=30)

    def sync_and_commit(self):
        result = self.run_stage("sync")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        changed = self.git(self.fabric, "diff", "--name-only").splitlines()
        self.assertEqual(set(changed), {p + "/mix.lock" for p in PROJECTS})
        self.assertFalse((self.out / "candidate-inputs.json").exists())
        self.assertNotEqual(self.run_stage("build").returncode, 0)
        self.commit(self.fabric)
        self.bundle(self.fabric, "mf_exam", "exam-bundle", b"exam")

    def test_sync_then_build_exact_manifest(self):
        self.sync_and_commit()
        result = self.run_stage("build")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((self.out / "candidate-inputs.json").read_text())
        self.assertEqual(set(manifest["packages"]), set(self.versions))
        for entry in manifest["packages"].values():
            self.assertEqual(entry["sha256"], hashlib.sha256(Path(entry["archive"]).read_bytes()).hexdigest())

    def test_changed_upstream_bytes_fail_closed(self):
        self.sync_and_commit()
        (self.registry / "tarballs" / f"med_ex_opus-{self.versions['med_ex_opus']}.tar").write_text("changed")
        result = self.run_stage("build")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Upstream archive changed", result.stdout + result.stderr)
        self.assertFalse((self.out / "candidate-inputs.json").exists())
        (self.registry / "tarballs" / f"med_ex_opus-{self.versions['med_ex_opus']}.tar").write_text("med_ex_opus")
        retry = self.run_stage("build")
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertEqual(len(list(self.out.glob("build.*"))), 2)

    def test_third_party_lock_drift_fails(self):
        result = self.run_stage("sync", DRIFT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected lock resolution", result.stdout + result.stderr)
        self.assertFalse((self.out / "candidate-inputs.json").exists())


if __name__ == "__main__":
    unittest.main()
