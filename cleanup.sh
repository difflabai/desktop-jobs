#!/usr/bin/env bash
# Kill any existing instances of our managed services so we can transition to ada.
# Run once before starting ada for the first time.
set -euo pipefail

echo "Cleaning up existing service processes..."

# ace-step (uvicorn acestep)
pkill -f 'uvicorn acestep.api_server:app' 2>/dev/null && echo "  killed ace-step" || echo "  ace-step not running"

# song-creator
pkill -f 'node.*projects/song-creator-ats' 2>/dev/null && echo "  killed song-creator" || echo "  song-creator not running"

# nanobazaar-seller
pkill -f 'node.*projects/nanobazaar-song-seller' 2>/dev/null && echo "  killed nanobazaar-seller" || echo "  nanobazaar-seller not running"

# Clean up any stale ada state
rm -rf ~/.ada/pids/*.pid 2>/dev/null || true

echo "Done. Ready for: ada start all"
