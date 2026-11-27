#!/usr/bin/env bash
# One source matrix. --fast permits the intentional development selector;
# the release lane requires genuine locked dependencies and production compile.
set -euo pipefail
mode=${1:?Expected sdk, remote, fabric or weld-minimum}
shift
case "$mode" in
  remote)
    sha=$(git rev-parse HEAD)
    url=https://github.com/nshkrdotcom/med_ex.git
    [[ $(git ls-remote --exit-code "$url" refs/heads/main | cut -f1) == "$sha" ]]
    ./build_support/check_consumers.sh --transport git --git-url "$url" --git-ref "$sha" --evidence "${1:?Supply the private evidence directory}"
    ;;
  weld-minimum)
    cache=${1:?Supply the private minimum toolchain cache directory}
    export ASDF_ELIXIR_VERSION=1.18.4-otp-28 ASDF_ERLANG_VERSION=28.5
    export MIX_HOME="$cache/mix" HEX_HOME="$cache/hex"
    elixir -v
    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
    mix deps.get --check-locked
    mix ci
    ;;
  sdk|fabric) ;;
  *) echo "Unknown project qualification: $mode" >&2; exit 2 ;;
esac
[[ "$mode" == sdk || "$mode" == fabric ]] || exit 0
jobs=2
fast=false
checks_only=false
while (( $# )); do
  case "$1" in
    --fast) fast=true; shift ;;
    --checks-only) checks_only=true; shift ;;
    --jobs) jobs=${2:?Supply 1--4 jobs}; shift 2 ;;
    *) echo 'Use [--fast] [--checks-only] [--jobs 1..4].' >&2; exit 2 ;;
  esac
done
[[ "$jobs" =~ ^[1-4]$ ]] || { echo 'Use 1--4 jobs.' >&2; exit 2; }
root=$(pwd -P)
source "$root/build_support/receipt_fixture.sh"
if [[ "$mode" == sdk ]]; then
  medex_receipt_fixture "$root/core/med_core/test/fixtures/receipt_vectors_v2.json"
else
  if ! "$fast" && [[ -e .mix_sources.json || -L .mix_sources.json ]]; then
    echo 'Release source gates require the default locked Fabric checkout.' >&2
    exit 2
  fi
  medex_receipt_fixture "$root/../med_ex/core/med_core/test/fixtures/receipt_vectors_v2.json"
fi
failures=0
run() {
  local status=0
  "$@" || status=$?
  printf 'QC phase=%s exit=%s\n' "$*" "$status"
  if ((status)); then failures=$((failures + 1)); fi
  return 0
}
if [[ "$mode" == sdk ]]; then
  run python3 test/qualification_command_test.py
  run python3 test/receipt_fixture_test.py
  run python3 test/qualify_projects_test.py
  run python3 extensions/med_ex_opus/test/build_test.py
  run python3 extensions/med_ex_opus/test/native_io_test.py
else
  run node --test ops/docs_hook_test.mjs
  run node --test apps/exam/test/browser_acquisition_test.mjs apps/exam/test/browser_acquisition_recovery_test.mjs
  run python3 ops/qc_native_test.py
  run python3 ops/verify_soak_report_test.py
fi
if "$checks_only"; then
  printf 'QC summary mode=%s independent_failures=%s\n' "$mode" "$failures"
  ((failures == 0))
  exit
fi
# A failed bootstrap blocks dependent Mix checks, not the independent short tests.
setup=(mix setup --jobs "$jobs")
if ! "$fast"; then setup+=(--locked); fi
if "${setup[@]}"; then
  quality=(mix quality --jobs "$jobs")
  if ! "$fast"; then quality+=(--release); fi
  run "${quality[@]}"
else
  failures=$((failures + 1))
  printf 'BLOCKED project quality: dependency bootstrap failed\n'
fi
printf 'QC summary mode=%s failures=%s\n' "$mode" "$failures"
((failures == 0))
