#!/bin/sh
# Head-to-head benchmark runner for packages/wasm:
# Pion Native (packages/wasm --release) vs Rust (wasmparser + wasm-encoder + wasmprinter --release --locked).
# All build artifacts and temporary inputs are placed in /tmp/bench-wasm-run.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/bench-wasm-run"
BIN_DIR="$OUT_DIR/bin"
CORPUS="$OUT_DIR/corpus.wasm"

mkdir -p "$BIN_DIR"

echo "==> Compiling real Wasm32 corpus (packages/wasm/wasm_smoke --target wasm32 --release)"
PION_CACHE_DIR="$OUT_DIR/pion-cache" pionc build --target wasm32 --release -o "$CORPUS" "$BENCH_DIR/../wasm_smoke"
CORPUS_BYTES=$(wc -c < "$CORPUS" | tr -d ' ')
echo "Corpus size: $CORPUS_BYTES bytes"

echo "==> Cross-checking corpus with Node WebAssembly.validate"
node -e "const fs=require('fs'); if (!WebAssembly.validate(fs.readFileSync('$CORPUS'))) { process.exit(1); }"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="$OUT_DIR/pion-cache" pionc build --release -o "$BIN_DIR/pion_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust benchmark (--release --locked, target in $OUT_DIR/rust-target)"
rm -rf "$OUT_DIR/rust-build"
cp -R "$BENCH_DIR/rust" "$OUT_DIR/rust-build"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/wasm_bench_rust" "$BIN_DIR/rust_bench"

W1_ROUNDS=20
W2_ROUNDS=20
W3_ROUNDS=5
W1_BYTES=$(( CORPUS_BYTES * W1_ROUNDS ))
W2_BYTES=$(( CORPUS_BYTES * W2_ROUNDS ))
W3_BYTES=$(( CORPUS_BYTES * W3_ROUNDS ))

echo ""
echo "=== WORKLOAD 1: Full Binary Decode + Instruction Traversal ($W1_ROUNDS x ${CORPUS_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Wasm W1: Full Binary Decode + Instruction Traversal (${W1_ROUNDS}x 288 KiB real .wasm)" \
  --impl "pion=$BIN_DIR/pion_bench decode $CORPUS $W1_ROUNDS" \
  --impl "rust_wasmparser=$BIN_DIR/rust_bench decode $CORPUS $W1_ROUNDS" \
  --baseline rust_wasmparser \
  --warmup 1 --rounds 5 --ops "$W1_ROUNDS" --bytes "$W1_BYTES" \
  --md-out "$OUT_DIR/w1_decode.md" --json-out "$OUT_DIR/w1_decode.json"

echo ""
echo "=== WORKLOAD 2: Full Spec Validation ($W2_ROUNDS x ${CORPUS_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Wasm W2: Full WebAssembly Spec Validation (${W2_ROUNDS}x 288 KiB real .wasm)" \
  --impl "pion=$BIN_DIR/pion_bench validate $CORPUS $W2_ROUNDS" \
  --impl "rust_wasmparser=$BIN_DIR/rust_bench validate $CORPUS $W2_ROUNDS" \
  --baseline rust_wasmparser \
  --warmup 1 --rounds 5 --ops "$W2_ROUNDS" --bytes "$W2_BYTES" \
  --md-out "$OUT_DIR/w2_validate.md" --json-out "$OUT_DIR/w2_validate.json"

echo ""
echo "=== WORKLOAD 3: Decode -> Re-encode + WAT Disassembly ($W3_ROUNDS x ${CORPUS_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Wasm W3: Decode -> Re-encode + WAT Disassembly (${W3_ROUNDS}x 288 KiB real .wasm)" \
  --impl "pion=$BIN_DIR/pion_bench roundtrip_wat $CORPUS $W3_ROUNDS" \
  --impl "rust_wasmtools=$BIN_DIR/rust_bench roundtrip_wat $CORPUS $W3_ROUNDS" \
  --baseline rust_wasmtools \
  --warmup 1 --rounds 5 --ops "$W3_ROUNDS" --bytes "$W3_BYTES" \
  --md-out "$OUT_DIR/w3_roundtrip_wat.md" --json-out "$OUT_DIR/w3_roundtrip_wat.json"
