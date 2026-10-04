#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/verification
swiftc -parse-as-library Sources/Bakeoff/Scorer.swift Sources/Lexicon/Lexicon.swift \
  Sources/Polish/Polisher.swift formal/differential/SwiftContracts.swift \
  -o .build/verification/swift-contracts
cargo build --manifest-path crossplatform/Cargo.toml -p hearsay-core --example contracts --locked
rust_binary="${CARGO_TARGET_DIR:-crossplatform/target}/debug/examples/contracts"
python3 scripts/check-differential.py --swift .build/verification/swift-contracts \
  --rust "$rust_binary" "$@"
