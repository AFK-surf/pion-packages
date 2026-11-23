#!/bin/sh
# Head-to-head benchmark runner for packages/protobuf:
# Pion Native (packages/protobuf) vs Rust (prost 0.13.5 --release) vs Go (google.golang.org/protobuf protowire).
# All build artifacts and temporary inputs are placed in /private/tmp to keep the git worktree clean.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-protobuf-bench"
BIN_DIR="$OUT_DIR/bin"
CORPUS_FILE="$OUT_DIR/spans_2000.pb"

mkdir -p "$BIN_DIR"

echo "==> Generating 2,000 OTel/RPC Span records -> $CORPUS_FILE"
python3 "$BENCH_DIR/gen_corpus.py" "$CORPUS_FILE" 2000
CORPUS_RAW_BYTES=$(wc -c < "$CORPUS_FILE" | tr -d ' ')
# Strip 4-byte length prefix per message (2000 * 4 = 8000 bytes)
SPAN_PAYLOAD_BYTES=$(( (CORPUS_RAW_BYTES - 8000) * 50 ))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust prost 0.13.5 benchmark (--release --locked, target in /private/tmp)"
rm -rf "$OUT_DIR/rust-build"
cp -R "$BENCH_DIR/rust" "$OUT_DIR/rust-build"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/protobuf_bench_rust" "$BIN_DIR/rust_bench"

echo "==> Building Go google.golang.org/protobuf benchmark (pinned via go.sum)"
rm -rf "$OUT_DIR/go-build"
cp -R "$BENCH_DIR/go" "$OUT_DIR/go-build"
(cd "$OUT_DIR/go-build" && go build -o "$BIN_DIR/go_bench" .)

echo ""
echo "=== WORKLOAD 1: OTel/RPC Nested Span Batch Decode (100,000 spans) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Protobuf: OTel/RPC Span Batch Decode (100k nested spans)" \
  --impl "pion=$BIN_DIR/pion_bench decode_spans $CORPUS_FILE" \
  --impl "rust_prost=$BIN_DIR/rust_bench decode_spans $CORPUS_FILE" \
  --impl "go_protobuf=$BIN_DIR/go_bench decode_spans $CORPUS_FILE" \
  --baseline rust_prost \
  --warmup 1 --rounds 5 --ops 100000 --bytes "$SPAN_PAYLOAD_BYTES" \
  --md-out "$OUT_DIR/decode_spans.md" --json-out "$OUT_DIR/decode_spans.json"

echo ""
echo "=== WORKLOAD 2: OTel/RPC Nested Span Batch Encode (100,000 spans) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Protobuf: OTel/RPC Span Batch Encode (100k nested spans)" \
  --impl "pion=$BIN_DIR/pion_bench encode_spans" \
  --impl "rust_prost=$BIN_DIR/rust_bench encode_spans" \
  --impl "go_protobuf=$BIN_DIR/go_bench encode_spans" \
  --baseline rust_prost \
  --warmup 1 --rounds 5 --ops 100000 --bytes "$SPAN_PAYLOAD_BYTES" \
  --md-out "$OUT_DIR/encode_spans.md" --json-out "$OUT_DIR/encode_spans.json"

echo ""
echo "=== WORKLOAD 3: Packed Repeated sint64 + double Encode+Decode (8 x 400k values, ~20 MB) ==="
PACKED_BYTES=$("$BIN_DIR/pion_bench" packed_numeric | awk -F= '/^encoded_bytes=/{print $2}')
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Protobuf: Packed sint64 + double Roundtrip (8 x 400k values)" \
  --impl "pion=$BIN_DIR/pion_bench packed_numeric" \
  --impl "rust_prost=$BIN_DIR/rust_bench packed_numeric" \
  --impl "go_protobuf=$BIN_DIR/go_bench packed_numeric" \
  --baseline rust_prost \
  --warmup 1 --rounds 5 --ops 3200000 --bytes "$PACKED_BYTES" \
  --md-out "$OUT_DIR/packed_numeric.md" --json-out "$OUT_DIR/packed_numeric.json"
