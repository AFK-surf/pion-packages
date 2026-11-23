#!/bin/sh
# Head-to-head benchmark runner for packages/cedar:
# Pion Native (`packages/cedar` --release) vs official Rust `cedar-policy` (--release).
# All build artifacts live in /private/tmp/w16-cedar-bench to keep the git worktree 100% clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w16-cedar-bench"
BIN_DIR="$OUT_DIR/bin"

W1_ROUNDS="${CEDAR_W1_ROUNDS:-50}"
W1_OPS=$((W1_ROUNDS * 200))
W2_REQS="${CEDAR_W2_REQS:-3000}"
W3_REQS="${CEDAR_W3_REQS:-2000}"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="/private/tmp/w16-cedar-pion-cache" pionc build --release -o "$BIN_DIR/pion_cedar" "$BENCH_DIR/pion_bench"

echo "==> Building Rust cedar-policy benchmark (--release)"
CARGO_TARGET_DIR="/private/tmp/w16-cedar-cargo-target" cargo build --release --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "/private/tmp/w16-cedar-cargo-target/release/cedar_rust_bench" "$BIN_DIR/rust_cedar"

echo ""
echo "=== W1: Policy Set Parse + Format (${W1_OPS} policies) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Policy Set Parse + Format (${W1_OPS} policies)" \
  --impl "pion=$BIN_DIR/pion_cedar w1 $W1_ROUNDS" \
  --impl "cedar_policy_rust=$BIN_DIR/rust_cedar w1 $W1_ROUNDS" \
  --baseline cedar_policy_rust \
  --warmup 1 --rounds 5 --ops "$W1_OPS" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: Large-Scale Authorization (60 policies, 250-node DAG, ${W2_REQS} reqs) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Large-Scale Authorization (60 policies, 250-node DAG, ${W2_REQS} reqs)" \
  --impl "pion=$BIN_DIR/pion_cedar w2 $W2_REQS" \
  --impl "cedar_policy_rust=$BIN_DIR/rust_cedar w2 $W2_REQS" \
  --baseline cedar_policy_rust \
  --warmup 1 --rounds 5 --ops "$W2_REQS" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: Extensions & Predicates (decimal/ip/like/set, ${W3_REQS} reqs) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: Extensions & Predicates (decimal/ip/like/set, ${W3_REQS} reqs)" \
  --impl "pion=$BIN_DIR/pion_cedar w3 $W3_REQS" \
  --impl "cedar_policy_rust=$BIN_DIR/rust_cedar w3 $W3_REQS" \
  --baseline cedar_policy_rust \
  --warmup 1 --rounds 5 --ops "$W3_REQS" \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
