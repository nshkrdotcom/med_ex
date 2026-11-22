#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for tool in git curl tar make cc mix elixir erl; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done

elixir -e 'unless System.version() == "1.20.5" and
  String.trim(File.read!(Path.join([:code.root_dir() |> to_string(), "releases", "29", "OTP_VERSION"]))) == "29.1.2",
  do: System.halt("Activate the Erlang and Elixir versions in .tool-versions")'

mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get --check-locked
mix monorepo.deps.get -- --check-locked
if [[ "${1:-}" == "--fixture" ]]; then
  for tool in uv shasum; do
    command -v "$tool" >/dev/null || { echo "Missing fixture prerequisite: $tool" >&2; exit 1; }
  done
  bash fixtures/circor/prepare.sh "${MED_EX_FIXTURE_DIR:-$PWD/fixtures/circor}"
fi
