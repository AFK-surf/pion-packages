#!/bin/sh
# Head-to-head benchmark runner for packages/cel:
# Pion Native (`packages/cel` --release) vs Go `github.com/google/cel-go` (v0.24.1).
# All build artifacts live in /tmp/bench-cel-out to keep the git worktree 100% clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/bench-cel-out"
BIN_DIR="$OUT_DIR/bin"

W1_ITERS="${CEL_W1_ITERS:-250000}"
W2_ITERS="${CEL_W2_ITERS:-10000}"
W3_ITERS="${CEL_W3_ITERS:-200}"

W1_OPS=$((W1_ITERS * 4))
W2_OPS=$((W2_ITERS * 2))
W3_OPS=$((W3_ITERS * 10))

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="/tmp/bench-cel-pion-cache" pionc build --release -o "$BIN_DIR/pion_cel" "$BENCH_DIR/pion_bench"

echo "==> Building Go cel-go benchmark"
(cd "$BENCH_DIR/go_bench" && go build -o "$BIN_DIR/go_cel" .)

echo ""
echo "=== W1: Compiled IAM / K8s Admission Batch Eval (${W1_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Compiled IAM / K8s Admission Batch Eval (${W1_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_cel w1 $W1_ITERS" \
  --impl "go_cel=$BIN_DIR/go_cel w1 $W1_ITERS" \
  --baseline go_cel \
  --warmup 1 --rounds 5 --ops "$W1_OPS" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: Macros + Regex matches + Timestamp Batch Eval (${W2_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Macros + Regex matches + Timestamp Batch Eval (${W2_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_cel w2 $W2_ITERS" \
  --impl "go_cel=$BIN_DIR/go_cel w2 $W2_ITERS" \
  --baseline go_cel \
  --warmup 1 --rounds 5 --ops "$W2_OPS" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: End-to-End Compile + Eval (${W3_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: End-to-End Compile + Eval (${W3_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_cel w3 $W3_ITERS" \
  --impl "go_cel=$BIN_DIR/go_cel w3 $W3_ITERS" \
  --baseline go_cel \
  --warmup 1 --rounds 5 --ops "$W3_OPS" \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
