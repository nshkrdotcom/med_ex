#!/usr/bin/env bash
set -euo pipefail
umask 077
tool=$(cd "$(dirname "$0")" && pwd -P)
exec elixir "$tool/qualify_ecosystem.exs" "$@"
