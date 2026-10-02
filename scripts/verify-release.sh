#!/usr/bin/env bash
# Checks a built bundle; --notarized also enforces the Developer ID and ticket.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/hearsay.app}"
NOTARIZED="${2:-}"
[[ $# -le 2 && (-z $NOTARIZED || $NOTARIZED == --notarized) ]] || {
    echo "usage: $0 [APP] [--notarized]" >&2
    exit 2
}
die() { echo "verify-release: $*" >&2; exit 1; }
[[ -d $APP && -f $APP/Contents/Info.plist ]] || die "missing app bundle: $APP"

PLIST="$APP/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")"
[[ $BUNDLE_ID == computer.borrowed.hearsay ]] || die "unexpected bundle identifier: $BUNDLE_ID"
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid bundle version: $VERSION"
[[ $MINIMUM_OS == 26.0 ]] || die "unexpected minimum macOS version: $MINIMUM_OS"
[[ $(lipo -archs "$APP/Contents/MacOS/hearsay") == arm64 ]] || die "the release executable must be arm64"
codesign --verify --strict --deep --verbose=2 "$APP"
SIGNATURE="$(codesign --display --verbose=4 "$APP" 2>&1)"
CODE_FLAGS="$(sed -n 's/^CodeDirectory .* flags=0x\([[:xdigit:]]*\).*/\1/p' <<< "$SIGNATURE")"
[[ -n $CODE_FLAGS ]] && (( (16#$CODE_FLAGS & 0x10000) != 0 )) || die "hardened runtime is missing"

ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS"' EXIT
codesign --display --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null
[[ $(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS") == true ]] || die "microphone entitlement is missing"

if [[ $NOTARIZED == --notarized ]]; then
    REQUIREMENT='anchor apple generic and identifier "computer.borrowed.hearsay" and certificate leaf[subject.OU] = "43BT9GR95A"'
    codesign --verify --strict --deep "-R=$REQUIREMENT" "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
echo "verified hearsay $VERSION ($BUNDLE_ID, arm64)"
