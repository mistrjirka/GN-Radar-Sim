#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
PYTHON="${RADAR_PYTHON:-python3}"
if ! "$PYTHON" -c 'import numpy, scipy, PIL, matplotlib' 2>/dev/null; then
  echo 'Install game/radar/backend/requirements.txt in a Python environment and set RADAR_PYTHON.' >&2
  exit 1
fi
export RADAR_PYTHON="$(command -v "$PYTHON")"
exec godot --path "$PWD" res://game/cockpit/CockpitGame.tscn "$@"
