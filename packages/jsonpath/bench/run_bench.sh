#!/bin/sh
# Head-to-head benchmark runner for packages/jsonpath:
# Pion Native (`packages/jsonpath` --release) vs Rust (`serde_json_path` + `json-patch` --locked --release).
# All build artifacts and temporary inputs live in /private/tmp/w14-jsonpath-bench to keep git worktree clean.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="${JP_BENCH_OUT:-${TMPDIR:-/tmp}/w14-jsonpath-bench}"
BIN_DIR="$OUT_DIR/bin"

W1_ITERS="${JP_W1_ITERS:-20}"
W2_ITERS="${JP_W2_ITERS:-5000}"
W3_ITERS="${JP_W3_ITERS:-50}"

mkdir -p "$BIN_DIR"

echo "==> Generating JSONPath/Patch benchmark corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

W1_OPS=$((6 * W1_ITERS))
W2_OPS=$((10 * W2_ITERS))
W3_OPS=$((100 * W3_ITERS))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_jsonpath" "$BENCH_DIR/pion_bench"

echo "==> Building Rust serde_json_path + json-patch benchmark (--locked --release)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --locked --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/jsonpath_bench_rust" "$BIN_DIR/rust_jsonpath"

echo ""
echo "=== W1: Complex K8s/OpenAPI JSONPath Compile + Query + Normalized Path (${W1_OPS} queries) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Complex K8s/OpenAPI JSONPath Compile + Query + Normalized Path (${W1_OPS} queries)" \
  --impl "pion=$BIN_DIR/pion_jsonpath w1 $OUT_DIR/w1_k8s.json $OUT_DIR/w1_queries.txt $W1_ITERS" \
  --impl "rust_serde_json_path=$BIN_DIR/rust_jsonpath w1 $OUT_DIR/w1_k8s.json $OUT_DIR/w1_queries.txt $W1_ITERS" \
  --baseline rust_serde_json_path \
  --warmup 1 --rounds 5 --ops "$W1_OPS" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: Precompiled JSONPath Hot-Path Throughput (${W2_OPS} evals) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Precompiled JSONPath Hot-Path Throughput (${W2_OPS} evals)" \
  --impl "pion=$BIN_DIR/pion_jsonpath w2 $OUT_DIR/w2_doc.json $OUT_DIR/w2_queries.txt $W2_ITERS" \
  --impl "rust_serde_json_path=$BIN_DIR/rust_jsonpath w2 $OUT_DIR/w2_doc.json $OUT_DIR/w2_queries.txt $W2_ITERS" \
  --baseline rust_serde_json_path \
  --warmup 1 --rounds 5 --ops "$W2_OPS" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: RFC 6902 diff_patch + apply_patch + RFC 7396 merge_patch Roundtrip (${W3_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: RFC 6902 diff_patch + apply_patch + RFC 7396 merge_patch Roundtrip (${W3_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_jsonpath w3 $OUT_DIR/w3_pairs.jsonl $W3_ITERS" \
  --impl "rust_json_patch=$BIN_DIR/rust_jsonpath w3 $OUT_DIR/w3_pairs.jsonl $W3_ITERS" \
  --baseline rust_json_patch \
  --warmup 1 --rounds 5 --ops "$W3_OPS" \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
