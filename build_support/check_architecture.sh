#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
export MIX_ENV=test
export MEDEX_BUILD_ROOT="$(pwd)"
for project in core/med_core core/med_capture .; do
  (
    cd "$project"
    mix deps.get
    mix compile --warnings-as-errors
    mix run --no-start -e 'Code.require_file("build_support/boundary_check.exs", System.fetch_env!("MEDEX_BUILD_ROOT")); c = Mix.Project.config(); MedEx.Build.Boundaries.dependencies!(c[:app], c[:deps])'
    mix test
  )
done
mix run build_support/check_architecture.exs
