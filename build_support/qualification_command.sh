#!/usr/bin/env bash
# The BEAM port owns stdin. EOF is also cancellation if the runner disappears.
set -euo pipefail
exec {owner_fd}<&0
timeout --signal=TERM --kill-after=30s 2400s "$@" </dev/null &
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
