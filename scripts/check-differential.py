#!/usr/bin/env python3
"""Compare actual Swift/Rust contracts and optionally the kernel-checked Lean oracle."""
import argparse
import json
import os
from pathlib import Path
import random
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(command, rows):
    try:
        process = subprocess.run(command, input="".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows),
                                 text=True, capture_output=True, cwd=ROOT, timeout=120, check=True)
    except subprocess.CalledProcessError as error:
        print(error.stderr, file=sys.stderr)
        raise
    results = [json.loads(line) for line in process.stdout.splitlines()]
    if len(results) != len(rows):
        raise RuntimeError(f"{command[0]} returned {len(results)} results for {len(rows)} cases")
    return results


def corpus(seed, count):
    fixtures = json.loads((ROOT / "formal/differential/regressions.json").read_text())
    words = ["invoice", "cache", "FRIDAY", "ação", "åäö", "你好", "e\u0301", "é", "we’re", "won't",
             "HTTP2", "p99", "90's", "5ms", "23%", "1,250,000", "14th", "...", "🙂", "$1", "\\path",
             "um", "uh", "", "read me", "Mprox", "co_op", "foo-bar", "١٢", "१२", "²", "Ⅳ"]
    spaces = [" ", "\t", "\n", "\r\n", "\u00a0", "\u2003", "\u202f"]
    rules = [{"from": "mprox", "to": "mprocs"}, {"from": "read me", "to": "Readme"},
             {"from": "cache", "to": "$1\\store"}, {"from": "foo", "to": "bar"},
             {"from": "bar", "to": "baz"}]
    rng = random.Random(seed)
    def text():
        return rng.choice(spaces).join(rng.choice(words) if rng.randrange(4) else str(rng.randrange(10000))
                                     for _ in range(rng.randrange(13)))
    return fixtures + [{"reference": text(), "hypothesis": text(), "rewrites": rng.sample(rules, rng.randrange(6))}
                       for _ in range(count)]


def shrink(case, swift, rust):
    """Deletion shrink across text and rules; keep the mismatch as the predicate."""
    def differs(candidate):
        return run([swift], [candidate])[0] != run([rust], [candidate])[0]
    result = dict(case)
    for field in ("reference", "hypothesis", "rewrites"):
        items = list(result[field])
        index = 0
        while index < len(items):
            smaller = items[:index] + items[index + 1:]
            candidate = dict(result, **{field: smaller if field == "rewrites" else "".join(smaller)})
            if differs(candidate):
                items = smaller
                result = candidate
            else:
                index += 1
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True)
    parser.add_argument("--rust", required=True)
    parser.add_argument("--lean", help="Pinned Lean binary; requires scripts/check-lean.sh to build the proof module")
    parser.add_argument("--seed", type=int, default=int(os.environ.get("HEARSAY_DIFFERENTIAL_SEED", "20261004")))
    parser.add_argument("--cases", type=int, default=1000)
    args = parser.parse_args()
    if args.cases < 0:
        parser.error("--cases must be nonnegative")
    rows = corpus(args.seed, args.cases)
    swift = run([args.swift], rows)
    rust = run([args.rust], rows)
    for index, (a, b) in enumerate(zip(swift, rust)):
        if a != b:
            reduced = shrink(rows[index], args.swift, args.rust)
            print(f"Mismatch: seed={args.seed}, case={index}\n{json.dumps(reduced, ensure_ascii=False)}", file=sys.stderr)
            print(f"Swift: {run([args.swift], [reduced])[0]}\nRust: {run([args.rust], [reduced])[0]}", file=sys.stderr)
            return 1
    if args.lean:
        oracle = run([args.lean, "--run", str(ROOT / "formal/lean/Oracle.lean")], swift)
        for index, (result, distance) in enumerate(zip(swift, oracle)):
            if result["distance"] != distance:
                raise AssertionError(f"Lean distance differs: seed={args.seed}, case={index}: {rows[index]}")
    print(f"Passed {len(rows)} cross-port cases (seed={args.seed})" + (" against Lean" if args.lean else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
