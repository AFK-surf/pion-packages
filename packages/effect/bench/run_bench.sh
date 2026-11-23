#!/bin/sh
# 4-mode wasm_smoke SHA-256 verification + head-to-head benchmark runner for packages/effect
# (Pion Native vs Go vs Node.js). All build artifacts go to $OUT_DIR (never into the git worktree).
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="${EFFECT_BENCH_OUT:-${TMPDIR:-/tmp}/pion-effect-bench}"
BIN_DIR="$OUT_DIR/bin"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$PATH"

mkdir -p "$BIN_DIR"

echo "==> 1. 4-Mode Smoke Verification (Native debug/release + Wasm32 debug/release)"
pionc build -o "$BIN_DIR/smoke_native_debug" "$BENCH_DIR/wasm_smoke"
pionc build --release -o "$BIN_DIR/smoke_native_release" "$BENCH_DIR/wasm_smoke"
pionc build --target wasm32 -o "$BIN_DIR/smoke_wasm_debug.wasm" "$BENCH_DIR/wasm_smoke"
pionc build --release --target wasm32 -o "$BIN_DIR/smoke_wasm_release.wasm" "$BENCH_DIR/wasm_smoke"

"$BIN_DIR/smoke_native_debug" > "$OUT_DIR/smoke_native_debug.out"
"$BIN_DIR/smoke_native_release" > "$OUT_DIR/smoke_native_release.out"
node "$WASM_RT" "$BIN_DIR/smoke_wasm_debug.wasm" > "$OUT_DIR/smoke_wasm_debug.out"
node "$WASM_RT" "$BIN_DIR/smoke_wasm_release.wasm" > "$OUT_DIR/smoke_wasm_release.out"

python3 - "$OUT_DIR" <<'EOF'
import hashlib, os, sys
out = sys.argv[1]
modes = ["smoke_native_debug", "smoke_native_release", "smoke_wasm_debug", "smoke_wasm_release"]
shas = {}
for m in modes:
    data = open(os.path.join(out, m + ".out"), "rb").read()
    h = hashlib.sha256(data).hexdigest()
    shas[m] = h
    print(f"  {m:22s}: sha256={h} ({len(data)} bytes)")
if len(set(shas.values())) != 1:
    print("FAIL: 4-mode SHA-256 mismatch!", file=sys.stderr)
    sys.exit(1)
print("PASS: All 4 modes produced byte-identical stdout.")
EOF

echo ""
echo "==> 2. Building Head-to-Head Benchmarks (Pion --release, Go, Node.js)"
pionc build --release -o "$BIN_DIR/pion_effect_bench" "$BENCH_DIR/pion_bench"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_effect_bench" .)

echo ""
echo "=== W1: Bounded Queue Ping-Pong (50,000 messages, cap=16) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Effect W1: Bounded Queue Ping-Pong (50k msgs, cap=16)" \
  --impl "pion=$BIN_DIR/pion_effect_bench queue" \
  --impl "go=$BIN_DIR/go_effect_bench queue" \
  --impl "node=node $BENCH_DIR/node/bench.mjs queue" \
  --baseline go \
  --warmup 1 --rounds 5 --ops 50000 \
  --md-out "$OUT_DIR/w1_queue.md" --json-out "$OUT_DIR/w1_queue.json"

echo ""
echo "=== W2: Virtual-Clock Timer Heap Scheduling (20,000 timers) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Effect W2: Virtual-Clock Timer Scheduling (20k timers)" \
  --impl "pion=$BIN_DIR/pion_effect_bench timers" \
  --impl "go=$BIN_DIR/go_effect_bench timers" \
  --impl "node=node $BENCH_DIR/node/bench.mjs timers" \
  --baseline go \
  --warmup 1 --rounds 5 --ops 20000 \
  --md-out "$OUT_DIR/w2_timers.md" --json-out "$OUT_DIR/w2_timers.json"

echo ""
echo "=== W3: Structured Concurrent Fan-Out & Join (2,500 x 4 = 10,000 fibers) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Effect W3: Structured Fan-Out & Join (10k fibers)" \
  --impl "pion=$BIN_DIR/pion_effect_bench fanout" \
  --impl "go=$BIN_DIR/go_effect_bench fanout" \
  --impl "node=node $BENCH_DIR/node/bench.mjs fanout" \
  --baseline go \
  --warmup 1 --rounds 5 --ops 10000 \
  --md-out "$OUT_DIR/w3_fanout.md" --json-out "$OUT_DIR/w3_fanout.json"
