#!/bin/sh
# Head-to-head benchmark runner for packages/cbor:
# Pion Native (packages/cbor) vs Go (fxamacker/cbor/v2) vs Rust (ciborium).
# All build artifacts and temporary inputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-cbor-bench"
BIN_DIR="$OUT_DIR/bin"
CORPUS_FILE="$OUT_DIR/corpus_2000.cbor"

mkdir -p "$BIN_DIR"

echo "==> Generating 2,000 WebAuthn/COSE + Telemetry CBOR records -> $CORPUS_FILE"
python3 "$BENCH_DIR/gen_corpus.py" "$CORPUS_FILE" 2000
CORPUS_BYTES=$(wc -c < "$CORPUS_FILE" | tr -d ' ')
TOTAL_DEC_BYTES=$((CORPUS_BYTES * 40))

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_encode" "$BENCH_DIR/pion_encode"
pionc build --release -o "$BIN_DIR/pion_decode" "$BENCH_DIR/pion_decode"

echo "==> Building Go fxamacker/cbor/v2 benchmarks (copying module to /tmp so go.sum stays out of worktree)"
rm -rf "$OUT_DIR/go-build"
cp -R "$BENCH_DIR/go" "$OUT_DIR/go-build"
(cd "$OUT_DIR/go-build" && go mod tidy && go build -o "$BIN_DIR/go_encode" ./cmd/bench_encode && go build -o "$BIN_DIR/go_decode" ./cmd/bench_decode)

echo "==> Building Rust ciborium benchmarks (--release, target and Cargo.lock in /tmp)"
rm -rf "$OUT_DIR/rust-build"
cp -R "$BENCH_DIR/rust" "$OUT_DIR/rust-build"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bench_encode" "$BIN_DIR/rust_encode"
cp "$OUT_DIR/rust-target/release/bench_decode" "$BIN_DIR/rust_decode"

echo ""
echo "=== WORKLOAD 1: Deterministic CBOR Batch Encode (50,000 WebAuthn/COSE + Telemetry records) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CBOR: Deterministic Batch Encode (50k WebAuthn/COSE + Telemetry)" \
  --impl "pion=$BIN_DIR/pion_encode" \
  --impl "go_fxamacker=$BIN_DIR/go_encode" \
  --impl "rust_ciborium=$BIN_DIR/rust_encode" \
  --baseline go_fxamacker \
  --warmup 1 --rounds 5 --ops 50000 \
  --md-out "$OUT_DIR/encode.md" --json-out "$OUT_DIR/encode.json"

echo ""
echo "=== WORKLOAD 2: CBOR Batch Decode + Tree Walk (40 x 2,000 = 80,000 records) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CBOR: Batch Decode + Tree Walk (80k WebAuthn/COSE + Telemetry)" \
  --impl "pion=$BIN_DIR/pion_decode $CORPUS_FILE" \
  --impl "go_fxamacker=$BIN_DIR/go_decode $CORPUS_FILE" \
  --impl "rust_ciborium=$BIN_DIR/rust_decode $CORPUS_FILE" \
  --baseline go_fxamacker \
  --warmup 1 --rounds 5 --ops 80000 --bytes "$TOTAL_DEC_BYTES" \
  --md-out "$OUT_DIR/decode.md" --json-out "$OUT_DIR/decode.json"
