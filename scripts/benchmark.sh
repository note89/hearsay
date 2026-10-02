#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Release builds give useful inference timings; debug is available for developing the runner.
BENCHMARK_BUILD="${HEARSAY_BENCHMARK_BUILD:-release}"
[[ $BENCHMARK_BUILD == debug || $BENCHMARK_BUILD == release ]] || {
    echo "benchmark: HEARSAY_BENCHMARK_BUILD must be debug or release" >&2
    exit 2
}
swift build -c "$BENCHMARK_BUILD" --arch arm64 --product hearsay-benchmark >&2
scripts/local-inference-resources.sh "$BENCHMARK_BUILD" >&2
BENCHMARK_BIN="$(swift build -c "$BENCHMARK_BUILD" --arch arm64 --show-bin-path)"
BENCHMARK_REVISION="$(git rev-parse HEAD)"
BENCHMARK_DIGEST="$(rg --files Sources Package.swift Package.resolved | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}')"
export HEARSAY_BENCHMARK_REVISION="$BENCHMARK_REVISION/source-$BENCHMARK_DIGEST/$BENCHMARK_BUILD"
exec "$BENCHMARK_BIN/hearsay-benchmark" "$@"
