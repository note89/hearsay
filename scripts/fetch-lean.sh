#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)
    platform=darwin_aarch64
    checksum=17ee554702c199fc03f37b1c3708245671c93f5d932dcff55a03fa6cdb5e5adf ;;
  Darwin-x86_64)
    platform=darwin
    checksum=a5ef0fb0e14645eaa0e60bc6ba39a07e7deeeec73dc93ce7195b837eb9de2c9f ;;
  Linux-x86_64)
    platform=linux
    checksum=b14f5e5159219dd1a1956c3b806813319f5e94ccd5bdfd56f54520609a5bb5ec ;;
  *) echo "Use an existing Lean 4.24.0 installation on this platform." >&2; exit 1 ;;
esac
toolchain="$PWD/.build/verification/lean-4.24.0-$platform"
if [[ ! -x "$toolchain/bin/lean" ]]; then
  mkdir -p .build/verification
  archive="$(mktemp "$PWD/.build/verification/lean-download.XXXXXX")"
  trap 'rm -f "$archive"' EXIT
  curl --fail --location --silent --show-error --retry 2 \
    "https://github.com/leanprover/lean4/releases/download/v4.24.0/lean-4.24.0-$platform.tar.zst" --output "$archive"
  python3 - "$archive" "$checksum" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "rb") as archive:
    digest = hashlib.sha256()
    for chunk in iter(lambda: archive.read(1024 * 1024), b""):
        digest.update(chunk)
    actual = digest.hexdigest()
if actual != sys.argv[2]:
    raise SystemExit("Lean archive checksum mismatch")
PY
  tar --zstd -xf "$archive" -C .build/verification
fi
"$toolchain/bin/lean" --version >&2
printf '%s\n' "$toolchain/bin/lean"
