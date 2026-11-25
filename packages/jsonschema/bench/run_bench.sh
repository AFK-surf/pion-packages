#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/jsonschema:
# Pion Native (`packages/jsonschema` --release) vs Rust `jsonschema =0.29.1` (--locked --release) vs Node.js `ajv@8.17.1` (ajv/dist/2020).
# All build artifacts and temporary inputs live in /private/tmp/w10-jsonschema to keep git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
if [ -d /private/tmp ]; then
  OUT_DIR="${BENCH_OUT:-/private/tmp/w10-jsonschema/bench}"
else
  OUT_DIR="${BENCH_OUT:-/tmp/w10-jsonschema/bench}"
fi
BIN_DIR="$OUT_DIR/bin"
NODE_PKG="$OUT_DIR/node_pkg"

W1_N="${JS_W1_N:-500}"
W1_ITERS="${JS_W1_ITERS:-100}"
W2_N="${JS_W2_N:-200}"
W2_ITERS="${JS_W2_ITERS:-100}"
W3_N="${JS_W3_N:-200}"
W3_ITERS="${JS_W3_ITERS:-10}"

mkdir -p "$BIN_DIR" "$NODE_PKG"

echo "==> Generating JSON Schema benchmark corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR" "$W1_N" "$W2_N" "$W3_N"

W1_OPS=$((W1_N * W1_ITERS))
W2_OPS=$((W2_N * W2_ITERS))
W3_OPS=$((W3_N * W3_ITERS))

if [ ! -d "$NODE_PKG/node_modules/ajv" ]; then
  echo "==> Installing Node ajv@8.17.1 in $NODE_PKG"
  (cd "$NODE_PKG" && npm init -y >/dev/null 2>&1 && npm install --no-audit --no-fund ajv@8.17.1 >/dev/null)
fi

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_jsonschema" "$BENCH_DIR/pion_bench"

echo "==> Building Rust jsonschema benchmark (--locked --release, target in /private/tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --locked --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/jsonschema_bench_rust" "$BIN_DIR/rust_jsonschema"

echo ""
echo "=== Workload 1: OpenAPI / MCP Tool Call Batch Validation (${W1_OPS} instances) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 1: OpenAPI / MCP Tool Call Batch Validation (${W1_OPS} instances)" \
  --impl "pion=$BIN_DIR/pion_jsonschema batch $OUT_DIR/w1_schema.json $OUT_DIR/w1_instances.jsonl $W1_ITERS" \
  --impl "rust_jsonschema=$BIN_DIR/rust_jsonschema batch $OUT_DIR/w1_schema.json $OUT_DIR/w1_instances.jsonl $W1_ITERS" \
  --impl "node_ajv=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js batch $OUT_DIR/w1_schema.json $OUT_DIR/w1_instances.jsonl $W1_ITERS" \
  --baseline rust_jsonschema \
  --warmup 1 --rounds 5 --ops "$W1_OPS" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== Workload 2: Complex Manifest / Workflow Schema Batch Validation (${W2_OPS} instances) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 2: Complex Manifest / Workflow Schema Batch Validation (${W2_OPS} instances)" \
  --impl "pion=$BIN_DIR/pion_jsonschema batch $OUT_DIR/w2_schema.json $OUT_DIR/w2_instances.jsonl $W2_ITERS" \
  --impl "rust_jsonschema=$BIN_DIR/rust_jsonschema batch $OUT_DIR/w2_schema.json $OUT_DIR/w2_instances.jsonl $W2_ITERS" \
  --impl "node_ajv=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js batch $OUT_DIR/w2_schema.json $OUT_DIR/w2_instances.jsonl $W2_ITERS" \
  --baseline rust_jsonschema \
  --warmup 1 --rounds 5 --ops "$W2_OPS" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== Workload 3: Schema Compilation + Validation End-to-End (${W3_OPS} schemas) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 3: Schema Compilation + Validation End-to-End (${W3_OPS} schemas)" \
  --impl "pion=$BIN_DIR/pion_jsonschema e2e $OUT_DIR/w3_pairs.jsonl $W3_ITERS" \
  --impl "rust_jsonschema=$BIN_DIR/rust_jsonschema e2e $OUT_DIR/w3_pairs.jsonl $W3_ITERS" \
  --impl "node_ajv=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js e2e $OUT_DIR/w3_pairs.jsonl $W3_ITERS" \
  --baseline rust_jsonschema \
  --warmup 1 --rounds 5 --ops "$W3_OPS" \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
