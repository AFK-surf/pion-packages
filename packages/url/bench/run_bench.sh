#!/bin/sh
# Head-to-head benchmark runner for packages/url (Pion Native vs Rust url --release).
# All build artifacts and temporary inputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-url-bench"
BIN_DIR="$OUT_DIR/bin"
URL_DATA="$OUT_DIR/urls_100k.txt"
QUERY_DATA="$OUT_DIR/queries_100k.txt"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"
URL_BYTES=$(wc -c < "$URL_DATA" | tr -d ' ')
QUERY_BYTES=$(wc -c < "$QUERY_DATA" | tr -d ' ')
URL_TOTAL_BYTES=$((URL_BYTES * 2))
QUERY_TOTAL_BYTES=$((QUERY_BYTES * 2))

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_url" "$BENCH_DIR/pion_url"
pionc build --release -o "$BIN_DIR/pion_query" "$BENCH_DIR/pion_query"

echo "==> Building Rust url benchmarks (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bench_url" "$BIN_DIR/rust_url"
cp "$OUT_DIR/rust-target/release/bench_query" "$BIN_DIR/rust_query"

echo ""
echo "=== WORKLOAD 1: Mixed URL Parse + Join + Serialize (200,000 ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "URL: Mixed Batch Parse + Join + Serialize (200k ops)" \
  --impl "pion=$BIN_DIR/pion_url $URL_DATA" \
  --impl "rust_url=$BIN_DIR/rust_url $URL_DATA" \
  --baseline rust_url \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$URL_TOTAL_BYTES" \
  --md-out "$OUT_DIR/url.md" --json-out "$OUT_DIR/url.json"

echo ""
echo "=== WORKLOAD 2: URLSearchParams Parse + Mutate + Sort + Serialize (200,000 ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "URL: URLSearchParams Parse + Mutate + Sort + Serialize (200k ops)" \
  --impl "pion=$BIN_DIR/pion_query $QUERY_DATA" \
  --impl "rust_url=$BIN_DIR/rust_query $QUERY_DATA" \
  --baseline rust_url \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$QUERY_TOTAL_BYTES" \
  --md-out "$OUT_DIR/query.md" --json-out "$OUT_DIR/query.json"
