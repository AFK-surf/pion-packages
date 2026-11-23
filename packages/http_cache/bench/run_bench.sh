#!/bin/sh
# Head-to-head benchmark runner for packages/http_cache:
# Pion Native (--release) vs Rust `http-cache-semantics` 3.0.0 (--release).
# All build artifacts, Cargo target dir, and corpora are isolated in /tmp/pion-http-cache-bench.
set -eu

export PATH="${HOME:-}/.cargo/bin:/opt/homebrew/bin:${PATH:-}"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-http-cache-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

echo "==> Generating realistic YouTube / Twitter(X) / CDN / API caching corpus -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

CORPUS="$OUT_DIR/corpus.txt"
CORPUS_BYTES=$(wc -c < "$CORPUS" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_http_cache_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust http-cache-semantics 3.0.0 benchmark (--release, isolated in /tmp/pion-http-cache-bench)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/http-cache-bench-rust" "$BIN_DIR/rust_http_cache_bench"

ITERS=5000
OPS=$((12 * ITERS))

echo ""
echo "=== BENCH: RFC 9111 Cache-Control + Freshness + Vary + Revalidation + 304 (12 real-world scenarios x ${ITERS} = ${OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HTTP Cache Policy + Vary + Revalidation + 304 (12 real-world scenarios x ${ITERS})" \
  --impl "pion=$BIN_DIR/pion_http_cache_bench $CORPUS $ITERS" \
  --impl "rust_http_cache_semantics=$BIN_DIR/rust_http_cache_bench $CORPUS $ITERS" \
  --baseline rust_http_cache_semantics \
  --warmup 1 --rounds 5 --bytes "$((CORPUS_BYTES * ITERS))" --ops "$OPS" \
  --md-out "$OUT_DIR/bench_http_cache.md" --json-out "$OUT_DIR/bench_http_cache.json"
