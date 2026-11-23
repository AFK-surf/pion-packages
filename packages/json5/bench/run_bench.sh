#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/json5:
# Pion Native (`packages/json5`) vs Rust `json5 =1.3.8` + `json-patch =4.2.0` (--release)
# vs Node.js `json5@2.2.3` + `fast-json-patch@3.1.1`.
# All build artifacts and temporary inputs are placed in /private/tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-json5-bench"
BIN_DIR="$OUT_DIR/bin"
NODE_PKG="$OUT_DIR/node_pkg"
CORPUS_FILE="$OUT_DIR/tsconfig_corpus.json5"
DOC_FILE="$OUT_DIR/patch_doc.json"
PATCH_FILE="$OUT_DIR/patch_ops.json"

PARSE_ITERS="${JSON5_PARSE_ITERS:-60}"
RT_ITERS="${JSON5_RT_ITERS:-40}"
PATCH_OPS_EACH="${JSON5_PATCH_OPS_EACH:-50000}"
PATCH_TOTAL_OPS=$((PATCH_OPS_EACH * 2))

mkdir -p "$BIN_DIR" "$NODE_PKG"

echo "==> Generating benchmark inputs -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" corpus "$CORPUS_FILE" 180
python3 "$BENCH_DIR/gen_data.py" patch "$DOC_FILE" "$PATCH_FILE"
FILE_BYTES=$(wc -c < "$CORPUS_FILE" | tr -d ' ')
PARSE_TOTAL_BYTES=$((FILE_BYTES * PARSE_ITERS))
RT_TOTAL_BYTES=$((FILE_BYTES * RT_ITERS))
echo "    corpus=${FILE_BYTES} B, parse_iters=${PARSE_ITERS}, rt_iters=${RT_ITERS}, patch_ops=${PATCH_TOTAL_OPS}"

if [ ! -d "$NODE_PKG/node_modules/json5" ] || [ ! -d "$NODE_PKG/node_modules/fast-json-patch" ]; then
  echo "==> Installing Node json5@2.2.3 and fast-json-patch@3.1.1 in $NODE_PKG"
  (cd "$NODE_PKG" && npm init -y >/dev/null 2>&1 && npm install --no-audit --no-fund json5@2.2.3 fast-json-patch@3.1.1 >/dev/null)
fi

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_json5" "$BENCH_DIR/pion_bench"

echo "==> Building Rust json5 + json-patch benchmark (--release, target in /private/tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/json5_bench_rust" "$BIN_DIR/rust_json5"

echo ""
echo "=== Workload 1: Large Commented Config JSON5 Parse (${PARSE_ITERS}x ${FILE_BYTES} B = ${PARSE_TOTAL_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 1: Large Commented JSON5 Config Parse (${PARSE_ITERS}x Corpus)" \
  --impl "pion=$BIN_DIR/pion_json5 parse $CORPUS_FILE $PARSE_ITERS" \
  --impl "rust_json5=$BIN_DIR/rust_json5 parse $CORPUS_FILE $PARSE_ITERS" \
  --impl "node_json5=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js parse $CORPUS_FILE $PARSE_ITERS" \
  --baseline rust_json5 \
  --warmup 1 --rounds 5 --bytes "$PARSE_TOTAL_BYTES" --ops "$PARSE_ITERS" \
  --md-out "$OUT_DIR/bench_parse.md" --json-out "$OUT_DIR/bench_parse.json"

echo ""
echo "=== Workload 2: JSON5 -> Standard JSON Serialization Roundtrip (${RT_ITERS}x ${FILE_BYTES} B = ${RT_TOTAL_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 2: JSON5 -> Standard JSON Roundtrip (${RT_ITERS}x Corpus)" \
  --impl "pion=$BIN_DIR/pion_json5 roundtrip $CORPUS_FILE $RT_ITERS" \
  --impl "rust_json5=$BIN_DIR/rust_json5 roundtrip $CORPUS_FILE $RT_ITERS" \
  --impl "node_json5=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js roundtrip $CORPUS_FILE $RT_ITERS" \
  --baseline rust_json5 \
  --warmup 1 --rounds 5 --bytes "$RT_TOTAL_BYTES" --ops "$RT_ITERS" \
  --md-out "$OUT_DIR/bench_roundtrip.md" --json-out "$OUT_DIR/bench_roundtrip.json"

echo ""
echo "=== Workload 3: RFC 6902 Patch Apply + RFC 6901 Pointer Query (${PATCH_TOTAL_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 3: RFC 6902 Patch Apply + RFC 6901 Pointer Query (${PATCH_TOTAL_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_json5 patch $DOC_FILE $PATCH_FILE $PATCH_OPS_EACH" \
  --impl "rust_json_patch=$BIN_DIR/rust_json5 patch $DOC_FILE $PATCH_FILE $PATCH_OPS_EACH" \
  --impl "node_fast_json_patch=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js patch $DOC_FILE $PATCH_FILE $PATCH_OPS_EACH" \
  --baseline rust_json_patch \
  --warmup 1 --rounds 5 --ops "$PATCH_TOTAL_OPS" \
  --md-out "$OUT_DIR/bench_patch.md" --json-out "$OUT_DIR/bench_patch.json"
