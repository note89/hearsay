#!/usr/bin/env bash
# Restart the arena and verify all three layers: server TS compiles, served browser JS parses, scoring tests pass.
set -euo pipefail
cd "$(dirname "$0")/.."

bun build --target=bun scripts/bakeoff-arena.ts --outfile=/dev/null
pkill -f "bun scripts/bakeoff-arena.ts" 2>/dev/null || true
for _ in $(seq 20); do lsof -i :4141 -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.2; done
(nohup bun scripts/bakeoff-arena.ts > /tmp/bakeoff-arena.log 2>&1 &)
for _ in $(seq 40); do curl -sf localhost:4141/data >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf localhost:4141/data >/dev/null || { echo "arena did not come up"; cat /tmp/bakeoff-arena.log; exit 1; }
PAGE_JS=/tmp/arena-page.js
curl -s localhost:4141/ | python3 -c "
import sys, re
open('$PAGE_JS','w').write(re.search(r'<script>(.*)</script>', sys.stdin.read(), re.S).group(1))"
node --check "$PAGE_JS"
node scripts/arena-tests.js "$PAGE_JS"
echo "arena OK: server TS compiles, browser JS parses, scoring tests pass"
