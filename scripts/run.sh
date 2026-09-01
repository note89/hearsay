#!/usr/bin/env bash
# Rebuild, relaunch. Tail logs with scripts/logs.sh in another pane.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh "${1:-release}"
pkill -x hearsay 2>/dev/null || true
sleep 0.3
open -n build/hearsay.app
echo "launched — look for the waveform icon in the menu bar"
