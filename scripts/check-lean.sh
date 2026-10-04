#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
lean_binary="${LEAN:-lean}"
if [[ -z "${LEAN:-}" && -x .build/verification/lean-4.24.0-darwin_aarch64/bin/lean ]]; then
  lean_binary="$PWD/.build/verification/lean-4.24.0-darwin_aarch64/bin/lean"
fi
if [[ "$("$lean_binary" --version)" != *"version 4.24.0,"* ]]; then
  echo "Use the pinned Lean 4.24.0 toolchain (formal/lean/lean-toolchain)." >&2
  exit 1
fi
mkdir -p .build/verification/lean
export LEAN_PATH="$PWD/.build/verification/lean${LEAN_PATH:+:$LEAN_PATH}"
"$lean_binary" -o .build/verification/lean/Scorer.olean formal/lean/Scorer.lean \
  > .build/verification/lean/proof-audit.txt
cat .build/verification/lean/proof-audit.txt
python3 - <<'PY'
from pathlib import Path
import re
expected = {"rowDistance_correct", "distance_self", "distance_zero_iff", "distance_symmetric", "distance_length_bounds"}
found = set()
for line in Path(".build/verification/lean/proof-audit.txt").read_text().splitlines():
    match = re.fullmatch(r"'Hearsay\.(\w+)' depends on axioms: \[(.*?)\]", line)
    if not match or set(match[2].split(", ")) - {"propext", "Classical.choice", "Quot.sound"}:
        raise SystemExit("Proof audit failed: warning, unfinished proof, or unexpected axiom")
    found.add(match[1])
if found != expected:
    raise SystemExit("Proof audit failed: missing theorem")
PY
"$lean_binary" formal/lean/Oracle.lean
bash scripts/check-differential.sh --lean "$lean_binary" "$@"
