#!/usr/bin/env bash
# The BEAM port owns stdin. EOF is also cancellation if the runner disappears.
set -euo pipefail
gate_seconds=${1:?Expected an explicit gate wall-time budget in seconds}
[[ "$gate_seconds" =~ ^[1-9][0-9]{0,3}$ ]] && ((gate_seconds <= 5400)) || {
  echo 'Gate wall-time budget must be 1..5400 seconds.' >&2
  exit 2
}
shift
[[ $# -gt 0 ]] || { echo 'Expected a gate command.' >&2; exit 2; }
exec {owner_fd}<&0
timeout --signal=TERM --kill-after=30s "${gate_seconds}s" "$@" </dev/null &
worker=$!
(
  if ! IFS= read -r -u "$owner_fd"; then kill -TERM "$worker" 2>/dev/null || true; fi
) &
watcher=$!
exec {owner_fd}<&-
cleanup() {
  rc=$?
  trap - EXIT
  kill -TERM "$worker" "$watcher" 2>/dev/null || true
  wait "$worker" "$watcher" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
wait "$worker"
