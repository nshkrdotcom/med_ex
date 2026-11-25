#!/usr/bin/env bash
set -euo pipefail
tool=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
mode=${1:?Expected sdk, remote, fabric or weld-minimum}
case "$mode" in
  sdk)
    ./build_support/check_architecture.sh
    node --test test/*.mjs
    mix format --check-formatted
    mix deps.get --check-locked
    mix compile --warnings-as-errors
    mix docs --warnings-as-errors
    ;;
  remote)
    sha=$(git rev-parse HEAD)
    url=https://github.com/nshkrdotcom/med_ex.git
    [[ $(git ls-remote --exit-code "$url" refs/heads/main | cut -f1) == "$sha" ]]
    ./build_support/check_consumers.sh --transport git --git-url "$url" --git-ref "$sha" --evidence "$2"
    ;;
  weld-minimum)
    cache=${2:?Supply the private minimum toolchain cache directory}
    export ASDF_ELIXIR_VERSION=1.18.4-otp-28 ASDF_ERLANG_VERSION=28.5
    export MIX_HOME="$cache/mix" HEX_HOME="$cache/hex"
    elixir -v
    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
    mix deps.get --check-locked
    mix ci
    ;;
  fabric)
    [[ ! -e .mix_sources.json && ! -L .mix_sources.json ]] || { echo "Default Fabric checkout required." >&2; exit 2; }
    elixir config/sources_test.exs
    for project in . core/domain core/store core/interop apps/exam apps/handheld apps/preview; do
      (
        cd "$project"
        mix format --check-formatted
        mix deps.get --check-locked
        mix compile --warnings-as-errors
        if [[ "$project" == . ]]; then
          mix docs --warnings-as-errors
        else
          MIX_ENV=test mix deps.get --check-locked
          mix test
        fi
      )
    done
    (cd apps/exam && export MF_EXAM_LEGACY_MEDIA=1 && MIX_ENV=test mix deps.get && mix test)
    ;;
  *) echo "Unknown project qualification: $mode" >&2; exit 2 ;;
esac
