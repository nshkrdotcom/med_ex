#!/usr/bin/env bash
set -euo pipefail
mode=${1:?Expected sdk, remote, fabric or weld-minimum}
case "$mode" in
  sdk)
    ./build_support/check_architecture.sh
    python3 test/qualification_command_test.py
    python3 extensions/med_ex_opus/test/build_test.py
    mix format --check-formatted
    mix deps.get --check-locked
    mix compile --warnings-as-errors
    mix test
    mix credo --strict
    mix dialyzer
    mix docs --warnings-as-errors
    # The base project covers both private components for analysis and docs.
    # Compile/test each component independently to catch dependency leakage.
    for project in core/med_core core/med_capture tools/maintainer; do
      (
        cd "$project"
        mix deps.get --check-locked
        mix compile --warnings-as-errors
        MIX_ENV=test mix compile --warnings-as-errors
        mix test
      )
    done
    # Providers are direct Mix packages and do not inherit the base's gates.
    for project in extensions/med_ex_opus extensions/med_ex_rtc; do
      (
        cd "$project"
        mix format --check-formatted
        mix deps.get --check-locked
        mix compile --warnings-as-errors
        MIX_ENV=test mix deps.get --check-locked
        MIX_ENV=test mix compile --warnings-as-errors
        mix test
        mix credo --strict
        mix dialyzer
        mix docs --warnings-as-errors
      )
    done
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
    elixir config/runtime_test.exs
    elixir ops/detached_artifacts_test.exs
    node --test ops/docs_hook_test.mjs
    node --test apps/exam/test/browser_acquisition_test.mjs
    python3 ops/qc_native_test.py
    python3 ops/verify_soak_report_test.py
    for project in . core/domain core/store core/interop apps/exam apps/handheld apps/preview; do
      (
        cd "$project"
        mix format --check-formatted
        mix deps.get --check-locked
        mix compile --warnings-as-errors
        if [[ "$project" != . ]]; then
          MIX_ENV=test mix deps.get --check-locked
          MIX_ENV=test mix compile --warnings-as-errors
          mix test
        fi
        mix credo --strict
        mix dialyzer
        mix docs --warnings-as-errors
      )
    done
    ;;
  *) echo "Unknown project qualification: $mode" >&2; exit 2 ;;
esac
