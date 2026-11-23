#!/bin/sh
# Head-to-head benchmark runner for packages/proxy:
# Pion Native (--release) vs Go 1.27 reference (W1/W2 hand-written; W3 net/http.ReadRequest/ReadResponse + fixed header re-emit).
# All build artifacts are isolated in /private/tmp/w18-proxy-bench.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w18-proxy-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="$OUT_DIR/pion-cache" pionc build --release -o "$BIN_DIR/pion_proxy_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go 1.27 reference benchmark"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_proxy_bench" .)

echo ""
echo "=== W1: Proxy URL Parse + Redaction + NO_PROXY Match (200,000 ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Proxy URL Parse + Redaction + NO_PROXY Match (200k ops)" \
  --impl "pion=$BIN_DIR/pion_proxy_bench url" \
  --impl "go_ref=$BIN_DIR/go_proxy_bench url" \
  --baseline go_ref \
  --warmup 1 --rounds 5 --ops 200000 \
  --md-out "$OUT_DIR/bench_w1_url.md" --json-out "$OUT_DIR/bench_w1_url.json"

echo ""
echo "=== W2: SOCKS5 Full Bidirectional Handshake (UserPass + ATYP=0x03, 500,000 rounds) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: SOCKS5 Full Bidirectional Handshake (500k rounds)" \
  --impl "pion=$BIN_DIR/pion_proxy_bench socks5" \
  --impl "go_ref=$BIN_DIR/go_proxy_bench socks5" \
  --baseline go_ref \
  --warmup 1 --rounds 5 --ops 500000 \
  --md-out "$OUT_DIR/bench_w2_socks5.md" --json-out "$OUT_DIR/bench_w2_socks5.json"

echo ""
echo "=== W3: HTTP CONNECT + Forward-Proxy Header Sanitization (100,000 requests) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: HTTP CONNECT + Forward-Proxy Sanitization (100k reqs)" \
  --impl "pion=$BIN_DIR/pion_proxy_bench http" \
  --impl "go_net_http=$BIN_DIR/go_proxy_bench http" \
  --baseline go_net_http \
  --warmup 1 --rounds 5 --ops 100000 \
  --md-out "$OUT_DIR/bench_w3_http.md" --json-out "$OUT_DIR/bench_w3_http.json"
