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

# Kill any ada watch supervisor
if [[ -f "${HOME}/.ada/watch.lock" ]]; then
    pid=$(cat "${HOME}/.ada/watch.lock" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null && echo "  killed ada supervisor (PID $pid)" || true
    fi
    rm -f "${HOME}/.ada/watch.lock"
fi

# Clean up stale ada state
rm -f ~/.ada/pids/*.pid 2>/dev/null || true

echo "Done. Ready for: ./ada start all"
