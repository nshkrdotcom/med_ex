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
  mix run --no-start -e 'unless Weld.version() == "0.19.0", do: Mix.raise("Expected the official Weld 0.19.0 lock")'
  mix weld.setup "$manifest"
  for app in med_ex med_ex_opus med_ex_rtc; do
    mix weld.inspect "$manifest" --artifact "$app" --format json >/dev/null
    mix weld.project "$manifest" --artifact "$app" --live
    mix weld.project "$manifest" --artifact "$app"
  done
)
./build_support/check_consumers.sh --registry --projected-packages --evidence "$evidence" \
  --registry-lock extensions/med_ex_opus/mix.lock \
  --registry-lock extensions/med_ex_rtc/mix.lock -- bash -euo pipefail -c '
    unset MIX_ENV MIX_TARGET MIX_EXS MIX_DEPS_PATH MIX_LOCKFILE MIX_BUILD_PATH MIX_BUILD_ROOT
    cd "$1"
    for app in med_ex med_ex_opus med_ex_rtc; do
      mix weld.verify "$2" --artifact "$app"
      mix release.prepare "$2" --artifact "$app"
      mix release.track "$2" --artifact "$app"
    done
  ' registry "$invoker" "$manifest"
test -z "$(git status --porcelain)"
