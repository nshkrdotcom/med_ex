#!/usr/bin/env bash
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd)
command -v elixir >/dev/null || { echo 'Elixir 1.20 with OTP 29 is required.' >&2; exit 127; }
exec elixir -r "$repo/build_support/check_consumers.exs" \
  -e 'MedEx.ConsumerCheck.main(System.argv())' -- "$@"
