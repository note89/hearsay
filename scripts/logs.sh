#!/usr/bin/env bash
# Live session timings and errors from the running app.
cd "$(dirname "$0")/.."
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)"
exec /usr/bin/log stream --level info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
