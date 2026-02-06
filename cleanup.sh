#!/usr/bin/env bash
# Kill any existing instances of managed services for clean transition to ada.
# Run once before starting ada for the first time.
set -euo pipefail

echo "Cleaning up existing service processes..."

# ace-step (uvicorn acestep)
pkill -f 'uvicorn acestep.api_server:app' 2>/dev/null && echo "  killed ace-step" || echo "  ace-step not running"

# song-creator
pkill -f 'node.*projects/song-creator-ats' 2>/dev/null && echo "  killed song-creator" || echo "  song-creator not running"

# nanobazaar-seller
pkill -f 'node.*projects/nanobazaar-song-seller' 2>/dev/null && echo "  killed nanobazaar-seller" || echo "  nanobazaar-seller not running"

# Stop any running ada supervisor
if [[ -f ~/.ada/watch.lock ]]; then
    wpid=$(cat ~/.ada/watch.lock 2>/dev/null)
    if [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then
        kill "$wpid" 2>/dev/null && echo "  killed ada supervisor (PID $wpid)" || true
    fi
    rm -f ~/.ada/watch.lock
fi

# Clean stale pid files
rm -f ~/.ada/pids/*.pid 2>/dev/null || true

echo "Done. Ready for: ada start all"
