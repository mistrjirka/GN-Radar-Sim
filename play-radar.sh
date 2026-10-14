#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
PYTHON="${RADAR_PYTHON:-python3}"
if ! "$PYTHON" -c 'import numpy, scipy, PIL, matplotlib' 2>/dev/null; then
  echo 'Missing radar dependencies. Create a Python environment and install game/radar/backend/requirements.txt; set RADAR_PYTHON to that interpreter.' >&2
  exit 1
fi
export RADAR_PYTHON="$(command -v "$PYTHON")"
exec godot --path "$PWD" res://game/radar/RadarFlight.tscn "$@"
