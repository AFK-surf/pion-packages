#!/bin/sh
# Head-to-head benchmark runner for packages/promql:
# Pion Native (`packages/promql` --release) vs Go `github.com/prometheus/prometheus/promql/parser`.
# All build artifacts live in /private/tmp/w14-promql-bench to keep the git worktree 100% clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w14-promql-bench"
BIN_DIR="$OUT_DIR/bin"

W1_OPS="${PROMQL_W1_OPS:-20000}"
W2_OPS="${PROMQL_W2_OPS:-50000}"
W3_ITERS="${PROMQL_W3_ITERS:-200}"
W3_POINTS=$((W3_ITERS * 28))

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="/private/tmp/w14-promql-pion-cache" pionc build --release -o "$BIN_DIR/pion_promql" "$BENCH_DIR/pion_bench"

echo "==> Building Go prometheus/promql/parser benchmark (-mod=readonly)"
(cd "$BENCH_DIR/go_bench" && go build -mod=readonly -o "$BIN_DIR/go_promql" .)

echo ""
echo "=== W1: Production PromQL Parse + Canonical String() (${W1_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Production PromQL Parse + Canonical String() (${W1_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_promql w1 $W1_OPS" \
  --impl "go_promql=$BIN_DIR/go_promql w1 $W1_OPS" \
  --baseline go_promql \
  --warmup 1 --rounds 5 --ops "$W1_OPS" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: Metric Selector Parse + Label Extraction (${W2_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Metric Selector Parse + Label Extraction (${W2_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_promql w2 $W2_OPS" \
  --impl "go_promql=$BIN_DIR/go_promql w2 $W2_OPS" \
  --baseline go_promql \
  --warmup 1 --rounds 5 --ops "$W2_OPS" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: In-Memory Time-Series Eval (${W3_ITERS} iters, ${W3_POINTS} points) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: In-Memory Time-Series Eval (${W3_ITERS} iters, ${W3_POINTS} points)" \
  --impl "pion=$BIN_DIR/pion_promql w3 $W3_ITERS" \
  --impl "go_promql=$BIN_DIR/go_promql w3 $W3_ITERS" \
  --baseline go_promql \
  --warmup 1 --rounds 5 --ops "$W3_POINTS" \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
