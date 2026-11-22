#!/bin/sh
# Head-to-head benchmark runner for packages/http1:
# Pion Native vs Rust httparse 1.10.1 (--release) vs Go net/http.
# All build artifacts, Cargo lockfile, and corpora are isolated in /tmp.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-http1-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic HTTP/1.1 & SSE corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

REQ_DATA="$OUT_DIR/requests.bin"
RESP_DATA="$OUT_DIR/responses_chunked.bin"
SSE_DATA="$OUT_DIR/sse_llm.bin"

REQ_BYTES=$(($(wc -c < "$REQ_DATA" | tr -d ' ') * 4))
RESP_BYTES=$(($(wc -c < "$RESP_DATA" | tr -d ' ') * 4))
SSE_BYTES=$(($(wc -c < "$SSE_DATA" | tr -d ' ') * 2))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_http1_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust httparse 1.10.1 benchmark (--release, project & lockfile in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/http1-bench-rust" "$BIN_DIR/rust_http1_bench"

echo "==> Building Go net/http benchmark"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_http1_bench" .)

echo ""
echo "=== BENCH 1: HTTP/1.1 Request Parse (200,000 requests) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HTTP/1.1 Request Parse (200k mixed requests)" \
  --impl "pion=$BIN_DIR/pion_http1_bench req $REQ_DATA" \
  --impl "rust_httparse=$BIN_DIR/rust_http1_bench req $REQ_DATA" \
  --impl "go_net_http=$BIN_DIR/go_http1_bench req $REQ_DATA" \
  --baseline rust_httparse \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$REQ_BYTES" \
  --md-out "$OUT_DIR/bench_req.md" --json-out "$OUT_DIR/bench_req.json"

echo ""
echo "=== BENCH 2: HTTP/1.1 Response + Chunked Parse (100,000 responses) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HTTP/1.1 Response + Chunked Parse (100k chunked responses)" \
  --impl "pion=$BIN_DIR/pion_http1_bench resp_chunked $RESP_DATA" \
  --impl "rust_httparse=$BIN_DIR/rust_http1_bench resp_chunked $RESP_DATA" \
  --impl "go_net_http=$BIN_DIR/go_http1_bench resp_chunked $RESP_DATA" \
  --baseline rust_httparse \
  --warmup 1 --rounds 5 --ops 100000 --bytes "$RESP_BYTES" \
  --md-out "$OUT_DIR/bench_resp_chunked.md" --json-out "$OUT_DIR/bench_resp_chunked.json"

echo ""
echo "=== BENCH 3: WHATWG SSE Streaming Decode (400,000 LLM events, 4 KiB chunks) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WHATWG SSE Streaming Decode (400k LLM token events, 4 KiB chunks)" \
  --impl "pion=$BIN_DIR/pion_http1_bench sse $SSE_DATA" \
  --impl "rust_sse=$BIN_DIR/rust_http1_bench sse $SSE_DATA" \
  --impl "go_sse=$BIN_DIR/go_http1_bench sse $SSE_DATA" \
  --baseline rust_sse \
  --warmup 1 --rounds 5 --ops 400000 --bytes "$SSE_BYTES" \
  --md-out "$OUT_DIR/bench_sse.md" --json-out "$OUT_DIR/bench_sse.json"
