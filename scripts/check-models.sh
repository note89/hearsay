#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TLA2TOOLS_JAR="${TLA2TOOLS_JAR:-$PWD/.build/formal/tla2tools.jar}"
if [[ ! -f "$TLA2TOOLS_JAR" ]]; then
    echo "Set TLA2TOOLS_JAR to tla2tools.jar; see formal/README.md." >&2
    exit 1
fi
TLA2TOOLS_JAR="$(cd "$(dirname "$TLA2TOOLS_JAR")" && pwd)/$(basename "$TLA2TOOLS_JAR")"
model_output="$(mktemp -d "${TMPDIR:-/tmp}/hearsay-tlc.XXXXXX")"
trap 'rm -rf "$model_output"' EXIT

for model in CleanupDeadline DictationSession; do
    java -XX:+UseParallelGC -cp "$TLA2TOOLS_JAR" tlc2.TLC \
        -workers 1 -metadir "$model_output/$model" \
        -config "formal/$model.cfg" "formal/$model.tla"
    if java -XX:+UseParallelGC -cp "$TLA2TOOLS_JAR" tlc2.TLC \
        -workers 1 -metadir "$model_output/$model-before" \
        -config "formal/$model-before.cfg" "formal/$model.tla" \
        >"$model_output/$model-before.log" 2>&1; then
        echo "$model: expected the pre-fix design to fail" >&2
        exit 1
    fi
    case "$model" in
        CleanupDeadline) invariant=CancellationWins ;;
        DictationSession) invariant=NoStaleSettlement ;;
    esac
    if ! grep -q "Invariant $invariant is violated" "$model_output/$model-before.log"; then
        cat "$model_output/$model-before.log" >&2
        exit 1
    fi
    echo "$model: pre-fix counterexample reproduced ($invariant)"
done
