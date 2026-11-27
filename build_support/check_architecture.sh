#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
export MIX_ENV=test
export MEDEX_BUILD_ROOT="$(pwd -P)"
unset MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE MIX_TARGET MIX_EXS

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [base_projection_path]" >&2
  exit 2
fi

components=$(elixir -e '
  {data, _} = Code.eval_file("build_support/composition.exs")
  Enum.each(data.components, &IO.puts/1)
')

for project in $components .; do
  (
    cd "$project"
    mix deps.get
    mix compile --warnings-as-errors
    mix run --no-start -e '
      root = System.fetch_env!("MEDEX_BUILD_ROOT")
      Code.require_file("build_support/boundary_check.exs", root)
      config = Mix.Project.config()
      cwd = File.cwd!()
      expected = if cwd == root, do: "med_ex", else: Path.basename(cwd)
      version = File.read!(Path.join(root, "VERSION")) |> String.trim()
      unless Atom.to_string(config[:app]) == expected and config[:version] == version,
        do: Mix.raise("unexpected component app or version: #{inspect(config[:app])}")
      MedEx.Build.Boundaries.dependencies!(config[:app], config[:deps])
    '
    mix test
  )
done

if [ "$#" -eq 1 ]; then
  projection=$(cd "$1" && pwd -P)
  root=$(pwd -P)
  report=$(mktemp)
  trap 'rm -f "$report"' EXIT
  (
    cd tools/maintainer
    MIX_ENV=dev mix compile --warnings-as-errors
    MIX_ENV=dev mix weld plan --root "$root" --artifact med_ex --format json > "$report"
  )
  (
    cd "$projection"
    mix deps.get
    mix compile --warnings-as-errors
    mix test
  )
  mix run --no-start build_support/check_architecture.exs "$projection" "$report"
else
  mix run --no-start build_support/check_architecture.exs
fi
