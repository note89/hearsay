#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools ships Testing.framework outside SwiftPM's default search paths.
DEVELOPER_DIR_PATH="$(xcode-select -p)"
TEST_FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
if [[ -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
    swift test --disable-xctest \
        -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_PATH/Library/Developer/usr/lib" "$@"
else
    swift test --disable-xctest "$@"
fi
