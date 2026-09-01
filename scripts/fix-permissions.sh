#!/usr/bin/env bash
# One-time: make hearsay's signature stable so macOS permissions survive rebuilds.
# Usage from project root:  scripts/fix-permissions.sh   (asks for your password once)
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/make-cert.sh
echo "1/4 trust the local hearsay-dev signing certificate (sudo)…"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain scripts/hearsay-dev.pem

echo "2/4 re-sign build/hearsay.app with hearsay-dev…"
echo "    (if a dialog says codesign wants to use key hearsay-dev → Always Allow)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)"
codesign --force --sign hearsay-dev --identifier "$BUNDLE_ID" build/hearsay.app
codesign -dv build/hearsay.app 2>&1 | grep -E "Authority|Signature" || true

echo "3/4 relaunch…"
pkill -x hearsay 2>/dev/null || true
sleep 0.5
open -n build/hearsay.app

echo "4/4 grant both permissions to THIS build — remove any stale 'hearsay' row first (−), then + → $(pwd)/build/hearsay.app"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
echo "    …then the same under Input Monitoring, click Allow if the microphone asks again,"
echo "    then menu-bar icon → Relaunch. Never needed again."
