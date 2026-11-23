#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/sse:
# Pion Native (`packages/sse`) vs Rust `eventsource-stream` 0.2.3 (`--release --locked`).
# All temporary artifacts are placed in /private/tmp/w17-sse-bench to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="${SSE_BENCH_OUT:-/private/tmp/w17-sse-bench}"
BIN_DIR="$OUT_DIR/bin"
W1_FILE="$OUT_DIR/w1_stream.sse"
W2_FILE="$OUT_DIR/w2_chunked.sse"
W3_FILE="$OUT_DIR/w3_roundtrip.sse"

W1_EVENTS="${SSE_W1_EVENTS:-25000}"
W1_ITERS="${SSE_W1_ITERS:-10}"
W2_EVENTS="${SSE_W2_EVENTS:-10000}"
W2_ITERS="${SSE_W2_ITERS:-10}"
W3_EVENTS="${SSE_W3_EVENTS:-10000}"
W3_ITERS="${SSE_W3_ITERS:-8}"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic SSE benchmark corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" w1 "$W1_FILE" "$W1_EVENTS"
python3 "$BENCH_DIR/gen_data.py" w2 "$W2_FILE" "$W2_EVENTS"
python3 "$BENCH_DIR/gen_data.py" w3 "$W3_FILE" "$W3_EVENTS"

W1_BYTES=$(wc -c < "$W1_FILE" | tr -d ' ')
W2_BYTES=$(wc -c < "$W2_FILE" | tr -d ' ')
W3_BYTES=$(wc -c < "$W3_FILE" | tr -d ' ')
W1_TOTAL_BYTES=$((W1_BYTES * W1_ITERS))
W2_TOTAL_BYTES=$((W2_BYTES * W2_ITERS))
W3_TOTAL_BYTES=$((W3_BYTES * W3_ITERS))
W1_TOTAL_OPS=$((W1_EVENTS * W1_ITERS))
W2_TOTAL_OPS=$((W2_EVENTS * W2_ITERS))
W3_TOTAL_OPS=$((W3_EVENTS * W3_ITERS))
echo "    W1=${W1_BYTES} B x ${W1_ITERS} = ${W1_TOTAL_BYTES} B (${W1_TOTAL_OPS} events)"
echo "    W2=${W2_BYTES} B x ${W2_ITERS} = ${W2_TOTAL_BYTES} B (${W2_TOTAL_OPS} events)"
echo "    W3=${W3_BYTES} B x ${W3_ITERS} = ${W3_TOTAL_BYTES} B (${W3_TOTAL_OPS} events)"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="$OUT_DIR/pion-cache" pionc build --release -o "$BIN_DIR/pion_sse" "$BENCH_DIR/pion_bench"

echo "==> Building Rust eventsource-stream benchmark (--release --locked, target in /private/tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/sse_bench_rust" "$BIN_DIR/rust_sse"

echo ""
echo "=== W1: High-Throughput Streaming Parse (4 KiB chunks, ${W1_ITERS}x ${W1_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: High-Throughput Streaming Parse (4 KiB chunks, ${W1_ITERS}x ${W1_BYTES} B)" \
  --impl "pion=$BIN_DIR/pion_sse w1 $W1_FILE $W1_ITERS" \
  --impl "rust_eventsource_stream=$BIN_DIR/rust_sse w1 $W1_FILE $W1_ITERS" \
  --baseline rust_eventsource_stream \
  --warmup 1 --rounds 5 --bytes "$W1_TOTAL_BYTES" --ops "$W1_TOTAL_OPS" \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== W2: Fragmented 64-Byte Chunked Streaming Parse (${W2_ITERS}x ${W2_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Fragmented 64-Byte Chunked Streaming Parse (${W2_ITERS}x ${W2_BYTES} B)" \
  --impl "pion=$BIN_DIR/pion_sse w2 $W2_FILE $W2_ITERS" \
  --impl "rust_eventsource_stream=$BIN_DIR/rust_sse w2 $W2_FILE $W2_ITERS" \
  --baseline rust_eventsource_stream \
  --warmup 1 --rounds 5 --bytes "$W2_TOTAL_BYTES" --ops "$W2_TOTAL_OPS" \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W3: Encode + Parse Roundtrip (${W3_ITERS}x ${W3_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: Encode + Parse Roundtrip (${W3_ITERS}x ${W3_BYTES} B)" \
  --impl "pion=$BIN_DIR/pion_sse w3 $W3_FILE $W3_ITERS" \
  --impl "rust_eventsource_stream=$BIN_DIR/rust_sse w3 $W3_FILE $W3_ITERS" \
  --baseline rust_eventsource_stream \
  --warmup 1 --rounds 5 --bytes "$W3_TOTAL_BYTES" --ops "$W3_TOTAL_OPS" \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json"
