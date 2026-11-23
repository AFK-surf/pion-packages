#!/bin/sh
# Head-to-head benchmark runner for packages/http2:
# Pion Native (--release) vs Go 1.27 golang.org/x/net/http2 (hpack) vs Rust hpack-patched (--release --locked).
# All temporary build artifacts and corpora are isolated in /private/tmp/w10-http2.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w10-http2/bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic HTTP/2 + HPACK corpus -> $OUT_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR"

HPACK_STREAM="$OUT_DIR/hpack_stream.bin"
HEADERS_PLAIN="$OUT_DIR/headers_plain.bin"
FRAME_STREAM="$OUT_DIR/frame_stream.bin"

HPACK_BYTES=$(($(wc -c < "$HPACK_STREAM" | tr -d ' ') * 100))
PLAIN_BYTES=$(($(wc -c < "$HEADERS_PLAIN" | tr -d ' ') * 100))
FRAME_BYTES=$(($(wc -c < "$FRAME_STREAM" | tr -d ' ') * 100))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_http2_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go golang.org/x/net/http2 benchmark (-mod=readonly)"
rm -rf "$OUT_DIR/go-proj"
mkdir -p "$OUT_DIR/go-proj"
cp "$BENCH_DIR/go/go.mod" "$BENCH_DIR/go/go.sum" "$BENCH_DIR/go/main.go" "$OUT_DIR/go-proj/"
(cd "$OUT_DIR/go-proj" && go build -mod=readonly -o "$BIN_DIR/go_http2_bench" .)

echo "==> Building Rust hpack-patched benchmark (--release --locked)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/Cargo.lock" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/http2-bench-rust" "$BIN_DIR/rust_http2_bench"

echo ""
echo "=== BENCH 1: HPACK Header Stream Decode (100,000 header blocks, Huffman + Dynamic Table) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HPACK Header Stream Decode (100k header blocks, Huffman + Dynamic Table)" \
  --impl "pion=$BIN_DIR/pion_http2_bench hpack_decode $HPACK_STREAM" \
  --impl "go_x_net_http2=$BIN_DIR/go_http2_bench hpack_decode $HPACK_STREAM" \
  --impl "rust_hpack=$BIN_DIR/rust_http2_bench hpack_decode $HPACK_STREAM" \
  --baseline rust_hpack \
  --warmup 1 --rounds 5 --ops 100000 --bytes "$HPACK_BYTES" \
  --md-out "$OUT_DIR/bench_hpack_decode.md" --json-out "$OUT_DIR/bench_hpack_decode.json"

echo ""
echo "=== BENCH 2: HPACK Batch Header Encode (100,000 header blocks, Huffman + Dynamic Table) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HPACK Batch Header Encode (100k header blocks, Huffman + Dynamic Table)" \
  --impl "pion=$BIN_DIR/pion_http2_bench hpack_encode $HEADERS_PLAIN" \
  --impl "go_x_net_http2=$BIN_DIR/go_http2_bench hpack_encode $HEADERS_PLAIN" \
  --impl "rust_hpack=$BIN_DIR/rust_http2_bench hpack_encode $HEADERS_PLAIN" \
  --baseline rust_hpack \
  --warmup 1 --rounds 5 --ops 100000 --bytes "$PLAIN_BYTES" \
  --md-out "$OUT_DIR/bench_hpack_encode.md" --json-out "$OUT_DIR/bench_hpack_encode.json"

echo ""
echo "=== BENCH 3: Mixed HTTP/2 Frame Stream End-to-End (200,000 frames: Deframe + Reassemble + HPACK Decode) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Mixed HTTP/2 Frame Stream End-to-End (200k frames)" \
  --impl "pion=$BIN_DIR/pion_http2_bench frame_stream $FRAME_STREAM" \
  --impl "go_x_net_http2=$BIN_DIR/go_http2_bench frame_stream $FRAME_STREAM" \
  --impl "rust_hpack=$BIN_DIR/rust_http2_bench frame_stream $FRAME_STREAM" \
  --baseline rust_hpack \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$FRAME_BYTES" \
  --md-out "$OUT_DIR/bench_frame_stream.md" --json-out "$OUT_DIR/bench_frame_stream.json"
