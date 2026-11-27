#!/usr/bin/env bash
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/.." && pwd -P)
evidence=${1:?Supply a new private preparation evidence directory}
cd "$root"
test -z "$(git status --porcelain)"
unset MIX_ENV MIX_EXS MIX_TARGET MIX_DEPS_PATH MIX_LOCKFILE MIX_BUILD_PATH MIX_BUILD_ROOT
invoker="$root/tools/maintainer"
manifest="$root/build_support/weld.exs"
(
  cd "$invoker"
  mix deps.get --check-locked
  mix weld help project
  mix weld help prepare
  mix weld setup --manifest "$manifest"
  for app in med_ex; do
    mix weld plan --manifest "$manifest" --artifact "$app" --format json >/dev/null
    mix weld project --manifest "$manifest" --artifact "$app" --kind live
  done
)
./build_support/check_consumers.sh --registry --projected-packages --evidence "$evidence" \
  --registry-lock extensions/med_ex_opus/mix.lock \
  --registry-lock extensions/med_ex_rtc/mix.lock -- bash -euo pipefail -c '
    unset MIX_ENV MIX_TARGET MIX_EXS MIX_DEPS_PATH MIX_LOCKFILE MIX_BUILD_PATH MIX_BUILD_ROOT
    cd "$1"
    for app in med_ex; do
      mix weld prepare --manifest "$2" --artifact "$app"
      bundle=$(mix weld path --manifest "$2" --artifact "$app" --kind bundle)
      id=${bundle##*/}
      [[ "$id" =~ ^[0-9a-f]{64}$ ]]
      mix weld track --manifest "$2" --artifact "$app" --identity "$id" --branch "projection/v2/$app"
    done
  ' registry "$invoker" "$manifest"
test -z "$(git status --porcelain)"
