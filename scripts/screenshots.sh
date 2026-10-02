#!/usr/bin/env bash
# Capture the native Mac views with sample data, without touching the user's dictations.
set -euo pipefail
cd "$(dirname "$0")/.."
HEARSAY_SCREENSHOT_DIR="$PWD/docs" scripts/test.sh --filter MacScreenshotTests
