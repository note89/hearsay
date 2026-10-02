#!/usr/bin/env bash
# Builds the Apple Silicon app with the same hardened runtime as a release.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
[[ $# -le 1 && ($CONFIG == debug || $CONFIG == release) ]] || {
    echo "usage: $0 [debug|release]" >&2
    exit 2
}
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)"
APP="build/hearsay.app"
mkdir -p build
BUILD_LOG="build/hearsay-$CONFIG-build.log"

if ! swift build -c "$CONFIG" --arch arm64 > "$BUILD_LOG" 2>&1; then
    tail -n 40 "$BUILD_LOG" >&2
    echo "bundle: build failed (full log: $BUILD_LOG)" >&2
    exit 1
fi
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/hearsay" "$APP/Contents/MacOS/hearsay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"

# Reuse the release identity locally so permission grants survive updates.
# Without it, retain the project's stable development identity where available.
SIGNING_IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
DEVELOPER_ID="Developer ID Application: Nils Olof Tson Eriksson (43BT9GR95A)"
IDENTITY="${HEARSAY_SIGN_IDENTITY:-}"
if [[ -n $IDENTITY ]]; then
    [[ $IDENTITY == - || $SIGNING_IDENTITIES == *"\"$IDENTITY\""* ]] || {
        echo "bundle: signing identity '$IDENTITY' is unavailable" >&2
        exit 1
    }
elif [[ $SIGNING_IDENTITIES == *"\"$DEVELOPER_ID\""* ]]; then
    IDENTITY="$DEVELOPER_ID"
elif [[ $SIGNING_IDENTITIES == *'"hearsay-dev"'* ]]; then
    IDENTITY="hearsay-dev"
else
    echo "warning: no stable signing identity found — ad-hoc signing resets permission grants every build" >&2
    IDENTITY="-"
fi
codesign --force --options runtime --timestamp=none \
    --entitlements Resources/hearsay.entitlements \
    --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --deep "$APP"
echo "built $APP (signed: $IDENTITY)"
