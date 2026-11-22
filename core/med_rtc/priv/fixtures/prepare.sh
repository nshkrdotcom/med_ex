#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:?Usage: bash prepare.sh /path/to/cache}"
mkdir -p "$target"
target="$(cd "$target" && pwd)"

# Keep the platform-specific venv outside Mix dependencies and the SDK artifact.
export UV_PROJECT_ENVIRONMENT="$target/.circor-venv"
exec uv run --project "$here" --locked --python 3.12.14 python "$here/encode.py" "$target"
