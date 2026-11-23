#!/bin/sh
# Head-to-head benchmark runner for packages/hcl:
# Pion Native (`packages/hcl` --release) vs Official Go `github.com/hashicorp/hcl/v2`.
# All build artifacts and caches live in /tmp/w13-hcl-bench to keep the git worktree 100% clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/w13-hcl-bench"
BIN_DIR="$OUT_DIR/bin"

W1_ITERS="${HCL_W1_ITERS:-15}"
W2_ITERS="${HCL_W2_ITERS:-1000}"
W3_ITERS="${HCL_W3_ITERS:-3000}"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="/tmp/w13-hcl-bench-pion-cache" pionc build --release -o "$BIN_DIR/pion_hcl" "$BENCH_DIR/pion_bench"

echo "==> Building Go hcl/v2 benchmark"
(cd "$BENCH_DIR/go_bench" && GOCACHE="/tmp/w13-hcl-gocache" GOPATH="/tmp/w13-hcl-gopath" go build -o "$BIN_DIR/go_hcl" .)

echo ""
echo "=== W1: Large Terraform Infra Config (1,111 top-level / 2,111 total blocks) Parse + AST Walk (${W1_ITERS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Large Terraform Infra Config (2,111 blocks) Parse + AST Walk (${W1_ITERS}x)" \
  --impl "pion=$BIN_DIR/pion_hcl w1 $W1_ITERS" \
  --impl "go_hcl=$BIN_DIR/go_hcl w1 $W1_ITERS" \
  --baseline go_hcl \
  --warmup 1 --rounds 5 --ops "$W1_ITERS" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: Batch Config Parse + EvalContext Expressions / For / Templates / Builtins (${W2_ITERS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Batch Parse + EvalContext Full Expr/For/Template/Builtins (${W2_ITERS}x)" \
  --impl "pion=$BIN_DIR/pion_hcl w2 $W2_ITERS" \
  --impl "go_hcl=$BIN_DIR/go_hcl w2 $W2_ITERS" \
  --baseline go_hcl \
  --warmup 1 --rounds 5 --ops "$W2_ITERS" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: Batch Canonical Formatting format_hcl vs hclwrite.Format (${W3_ITERS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: Batch Canonical Formatting format_hcl vs hclwrite.Format (${W3_ITERS}x)" \
  --impl "pion=$BIN_DIR/pion_hcl w3 $W3_ITERS" \
  --impl "go_hcl=$BIN_DIR/go_hcl w3 $W3_ITERS" \
  --baseline go_hcl \
  --warmup 1 --rounds 5 --ops "$W3_ITERS" \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
