#!/bin/sh
# Head-to-head benchmark runner for packages/lua:
# Pion Native (`packages/lua` --release) vs Go `github.com/yuin/gopher-lua` (v1.1.1).
# All build artifacts live in /private/tmp/w14-lua-bench to keep git worktree 100% clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w14-lua-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="/private/tmp/w14-lua-bench-cache" pionc build --release -o "$BIN_DIR/pion_lua" "$BENCH_DIR/pion_bench"

echo "==> Building Go gopher-lua benchmark (-mod=readonly)"
(cd "$BENCH_DIR/go_bench" && go build -mod=readonly -o "$BIN_DIR/go_lua" .)

echo ""
echo "=== W1: Sieve + Recursive Fib + Table Sort/Aggregate ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Sieve(4000)x20 + Fib(24) + Table Sort/Aggregate" \
  --impl "pion=$BIN_DIR/pion_lua w1" \
  --impl "gopher_lua=$BIN_DIR/go_lua w1" \
  --baseline gopher_lua \
  --warmup 1 --rounds 5 \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: Closures + Metatable OOP + Lua Pattern gsub/gmatch/format (1500 iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Closures + Metatable OOP + Pattern gsub/gmatch/format (1500 iters)" \
  --impl "pion=$BIN_DIR/pion_lua w2" \
  --impl "gopher_lua=$BIN_DIR/go_lua w2" \
  --baseline gopher_lua \
  --warmup 1 --rounds 5 --ops 1500 \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3 (Fair): Compile + Fresh Sandbox VM Exec (2000 scripts, Go same subset base/table/string/math) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3 (Fair): Fresh Sandbox VM Exec (2000 scripts, matched stdlib subset)" \
  --impl "pion=$BIN_DIR/pion_lua w3" \
  --impl "gopher_lua_fair=$BIN_DIR/go_lua w3_fair" \
  --baseline gopher_lua_fair \
  --warmup 1 --rounds 5 --ops 2000 \
  --md-out "$OUT_DIR/bench_w3_fair.md" --json-out "$OUT_DIR/bench_w3_fair.json"

echo ""
echo "=== W3 (Full Go NewState): Compile + Fresh Sandbox VM Exec (2000 scripts, Go all libs) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3 (Full Go NewState): Fresh Sandbox VM Exec (2000 scripts, Go all libs)" \
  --impl "pion=$BIN_DIR/pion_lua w3" \
  --impl "gopher_lua=$BIN_DIR/go_lua w3" \
  --baseline gopher_lua \
  --warmup 1 --rounds 5 --ops 2000 \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
