#!/bin/sh
# Fair head-to-head benchmark runner for packages/http2:
# Pion Native (--release) vs Go 1.27 golang.org/x/net v0.62.0 vs Rust h2 0.4.20 (--release --locked).
# All temporary build artifacts and corpora are isolated in /private/tmp/fix-http2/bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$BENCH_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT_DIR="${BENCH_OUT:-${TMPDIR:-/tmp}/fix-http2/bench}"
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

echo "==> Building Go golang.org/x/net v0.62.0 benchmark (-mod=readonly)"
rm -rf "$OUT_DIR/go-proj"
mkdir -p "$OUT_DIR/go-proj"
cp "$BENCH_DIR/go/go.mod" "$BENCH_DIR/go/go.sum" "$BENCH_DIR/go/main.go" "$OUT_DIR/go-proj/"
(cd "$OUT_DIR/go-proj" && go build -mod=readonly -o "$BIN_DIR/go_http2_bench" .)

echo "==> Building Rust h2 0.4.20 HPACK + Codec benchmarks (--release --locked)"
rm -rf "$OUT_DIR/rust-h2-hpack" "$OUT_DIR/rust-h2-codec"
mkdir -p "$OUT_DIR/rust-h2-hpack" "$OUT_DIR/rust-h2-codec"
cp -R "$PKG_DIR/audit/diff/rust/Cargo.toml" "$PKG_DIR/audit/diff/rust/Cargo.lock" "$PKG_DIR/audit/diff/rust/src" "$OUT_DIR/rust-h2-hpack/"
sh "$PKG_DIR/audit/diff/rust/vendor_h2_hpack.sh" "$OUT_DIR/rust-h2-hpack"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked --quiet \
  --manifest-path "$OUT_DIR/rust-h2-hpack/Cargo.toml"
cp "$OUT_DIR/rust-target/release/h2-hpack-diff" "$BIN_DIR/rust_h2_hpack"

cp -R "$PKG_DIR/audit/bench/rust_h2codec/Cargo.toml" "$PKG_DIR/audit/bench/rust_h2codec/Cargo.lock" "$PKG_DIR/audit/bench/rust_h2codec/src" "$OUT_DIR/rust-h2-codec/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked --quiet \
  --manifest-path "$OUT_DIR/rust-h2-codec/Cargo.toml"
cp "$OUT_DIR/rust-target/release/h2-codec-bench" "$BIN_DIR/rust_h2_codec"

echo ""
echo "=== BENCH 1: HPACK Header Stream Decode (100,000 header blocks, Huffman + Dynamic Table) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HPACK Header Stream Decode (100k header blocks, Huffman + Dynamic Table)" \
  --impl "pion=$BIN_DIR/pion_http2_bench hpack_decode $HPACK_STREAM" \
  --impl "go_x_net_v0.62=$BIN_DIR/go_http2_bench hpack_decode $HPACK_STREAM" \
  --impl "rust_h2_0.4.20=$BIN_DIR/rust_h2_hpack hpack_decode $HPACK_STREAM" \
  --baseline rust_h2_0.4.20 \
  --warmup 1 --rounds 5 --ops 100000 --bytes "$HPACK_BYTES" \
  --md-out "$OUT_DIR/bench_hpack_decode.md" --json-out "$OUT_DIR/bench_hpack_decode.json"

echo ""
echo "=== BENCH 2: HPACK Batch Header Encode (100,000 header blocks, Huffman ON + Dynamic Table) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HPACK Batch Header Encode (100k header blocks, Huffman ON + Dynamic Table)" \
  --impl "pion=$BIN_DIR/pion_http2_bench hpack_encode $HEADERS_PLAIN" \
  --impl "go_x_net_v0.62=$BIN_DIR/go_http2_bench hpack_encode $HEADERS_PLAIN" \
  --impl "rust_h2_0.4.20=$BIN_DIR/rust_h2_hpack hpack_encode $HEADERS_PLAIN" \
  --baseline rust_h2_0.4.20 \
  --warmup 1 --rounds 5 --ops 100000 --bytes "$PLAIN_BYTES" \
  --md-out "$OUT_DIR/bench_hpack_encode.md" --json-out "$OUT_DIR/bench_hpack_encode.json"

echo ""
echo "=== BENCH 3: Mixed HTTP/2 Frame Engine (200,000 frames: Deframe + CONTINUATION + HPACK) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Mixed HTTP/2 Frame Engine (200k frames: Deframe + CONTINUATION + HPACK)" \
  --impl "pion=$BIN_DIR/pion_http2_bench frame_stream $FRAME_STREAM" \
  --impl "go_x_net_v0.62=$BIN_DIR/go_http2_bench frame_stream $FRAME_STREAM" \
  --impl "rust_h2_0.4.20=$BIN_DIR/rust_h2_codec frames $FRAME_STREAM" \
  --baseline rust_h2_0.4.20 \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$FRAME_BYTES" \
  --md-out "$OUT_DIR/bench_frame_stream.md" --json-out "$OUT_DIR/bench_frame_stream.json"
