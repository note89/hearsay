#!/usr/bin/env bash
# Builds hearsay and wraps it into build/hearsay.app (needed so macOS grants
# microphone / accessibility / input-monitoring permissions to *this* app).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)"
APP="build/hearsay.app"
BUILD_LOG=/tmp/hearsay-build.log

if ! swift build -c "$CONFIG" > "$BUILD_LOG" 2>&1; then
    grep -E "error:" "$BUILD_LOG" | sort -u | head -20
    echo "build failed (full log: $BUILD_LOG)"
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/hearsay" "$APP/Contents/MacOS/hearsay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer the local stable cert; any Apple Development cert second; ad-hoc only with a loud warning,
# because macOS keys permission grants to the signature.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/hearsay-dev/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
if [ -z "$IDENTITY" ]; then
    echo "warning: no stable signing identity found — ad-hoc signing resets permission grants every build" >&2
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
echo "built $APP (signed: $IDENTITY)"
