#!/usr/bin/env bash
# SwiftPM's CLI does not compile Metal shaders; reuse MLX's matching release artifact.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
[[ $# -le 1 && ($CONFIG == debug || $CONFIG == release) ]] || {
    echo "usage: $0 [debug|release]" >&2
    exit 2
}
# PINNED_MLX_METAL_VERSION: Package.swift pins this same version of mlx-swift.
VERSION="0.31.4"
ARCHIVE_SHA="1375538d225b036830ab838dde45dc32f20709bc2fffa6dc54f6cca57a966398"
LIBRARY_SHA="4306c203e313df5cf796680ee800984172028634922be436802b33d93bf3af1b"
CACHE=".build/local-inference-resources/$VERSION"
LIBRARY="$CACHE/mlx.metallib"
mkdir -p "$CACHE"

has_checksum() {
    [[ -f $1 && $(shasum -a 256 "$1" | awk '{print $1}') == "$2" ]]
}

if ! has_checksum "$LIBRARY" "$LIBRARY_SHA"; then
    ARCHIVE="$(mktemp "$CACHE/Cmlx.XXXXXX")"
    TEMP_LIBRARY="$(mktemp "$CACHE/metallib.XXXXXX")"
    trap 'rm -f "$ARCHIVE" "$TEMP_LIBRARY"' EXIT
    curl --fail --location --retry 3 --silent --show-error \
        "https://github.com/ml-explore/mlx-swift/releases/download/$VERSION/Cmlx.xcframework.zip" \
        -o "$ARCHIVE"
    has_checksum "$ARCHIVE" "$ARCHIVE_SHA" || { echo "local-inference-resources: MLX archive checksum mismatch" >&2; exit 1; }
    unzip -p "$ARCHIVE" Cmlx.xcframework/macos-arm64_x86_64/Cmlx.framework/Versions/A/Resources/default.metallib > "$TEMP_LIBRARY"
    has_checksum "$TEMP_LIBRARY" "$LIBRARY_SHA" || { echo "local-inference-resources: MLX Metal library checksum mismatch" >&2; exit 1; }
    mv "$TEMP_LIBRARY" "$LIBRARY"
    rm -f "$ARCHIVE"
    trap - EXIT
fi

BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"
mkdir -p "$BIN_DIR"
cp "$LIBRARY" "$BIN_DIR/mlx.metallib"
