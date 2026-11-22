#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$DIR/2530_AV.wav"
URL="https://physionet.org/files/circor-heart-sound/1.0.3/training_data/2530_AV.wav"
EXPECTED_SHA="493602122456932b91e62a694bd42f4d2c14f952804d17be85a1613f1ccd4e9f"

if [ ! -f "$TARGET" ]; then
  curl -fsSL "$URL" -o "$TARGET"
fi

ACTUAL_SHA="$(sha256sum "$TARGET" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "Checksum mismatch for $TARGET: expected $EXPECTED_SHA, got $ACTUAL_SHA" >&2
  exit 1
fi

echo "Verified CirCor fixture: $TARGET ($ACTUAL_SHA)"
