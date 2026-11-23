#!/bin/sh
# Head-to-head benchmark runner for packages/openapi:
# Pion Native (`packages/openapi` --release) vs Go `github.com/getkin/kin-openapi` (`-mod=readonly`).
# All build artifacts and caches live in /private/tmp/w15-openapi-bench to keep the git worktree 100% clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w15-openapi-bench"
BIN_DIR="$OUT_DIR/bin"

W1_ITERS="${OPENAPI_W1_ITERS:-10}"
W2_OPS="${OPENAPI_W2_OPS:-50000}"
W3_OPS="${OPENAPI_W3_OPS:-10000}"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="/private/tmp/w15-openapi-bench-pion-cache" pionc build --release -o "$BIN_DIR/pion_openapi" "$BENCH_DIR/pion_bench"

echo "==> Building Go kin-openapi benchmark (-mod=readonly)"
(cd "$BENCH_DIR/go_bench" && GOCACHE="/private/tmp/w15-openapi-gocache" GOPATH="/private/tmp/w15-openapi-gopath" go build -mod=readonly -o "$BIN_DIR/go_kin" .)

echo ""
echo "=== W1: Large OpenAPI 3.0.3 Spec (150 paths / 250 ops / dense \$ref) Parse + \$ref + Validate (${W1_ITERS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Large OpenAPI 3.0.3 Spec (150 paths / 250 ops) Parse + Ref + Validate (${W1_ITERS}x)" \
  --impl "pion=$BIN_DIR/pion_openapi w1 $W1_ITERS" \
  --impl "go_kin=$BIN_DIR/go_kin w1 $W1_ITERS" \
  --baseline go_kin \
  --warmup 1 --rounds 5 --ops "$W1_ITERS" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: High-Frequency RFC 6570 Routing + Path Param Extraction (${W2_OPS} lookups) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: High-Frequency RFC 6570 Routing + Param Extraction (${W2_OPS} lookups)" \
  --impl "pion=$BIN_DIR/pion_openapi w2 $W2_OPS" \
  --impl "go_kin=$BIN_DIR/go_kin w2 $W2_OPS" \
  --baseline go_kin \
  --warmup 1 --rounds 5 --ops "$W2_OPS" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: Request Body + Parameter Validation (${W3_OPS} requests) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: Request Body + Parameter Validation (${W3_OPS} requests)" \
  --impl "pion=$BIN_DIR/pion_openapi w3 $W3_OPS" \
  --impl "go_kin=$BIN_DIR/go_kin w3 $W3_OPS" \
  --baseline go_kin \
  --warmup 1 --rounds 5 --ops "$W3_OPS" \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
