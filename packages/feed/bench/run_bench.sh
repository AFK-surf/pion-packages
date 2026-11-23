#!/bin/sh
# Head-to-head benchmark runner for packages/feed:
# Pion Native (--release) vs Rust feed-rs 2.4.0 (--release --locked).
# All build artifacts and corpora are isolated in /private/tmp/w16-feed-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w16-feed-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic RSS 2.0, Atom 1.0, and JSON Feed 1.1 corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR"

W1_CORPUS="$OUT_DIR/w1_rss2_1500.xml"
W2_CORPUS="$OUT_DIR/w2_atom_1500.xml"
W3_CORPUS="$OUT_DIR/w3_jsonfeed_2000.json"

W1_BYTES=$(wc -c < "$W1_CORPUS" | tr -d ' ')
W2_BYTES=$(wc -c < "$W2_CORPUS" | tr -d ' ')
W3_BYTES=$(wc -c < "$W3_CORPUS" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_feed_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust feed-rs benchmark (--release --locked, isolated in /private/tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/Cargo.lock" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/feed-bench-rust" "$BIN_DIR/rust_feed_bench"

echo ""
echo "=== W1: RSS 2.0 + Extensions Batch Parse (1,500 items) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: RSS 2.0 + Extensions Batch Parse (1,500 items)" \
  --impl "pion=$BIN_DIR/pion_feed_bench rss2 $W1_CORPUS" \
  --impl "rust_feed_rs=$BIN_DIR/rust_feed_bench rss2 $W1_CORPUS" \
  --baseline rust_feed_rs \
  --warmup 1 --rounds 5 --bytes "$W1_BYTES" --ops 1500 \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: Atom 1.0 (RFC 4287) + XHTML Batch Parse (1,500 entries) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Atom 1.0 (RFC 4287) + XHTML Batch Parse (1,500 entries)" \
  --impl "pion=$BIN_DIR/pion_feed_bench atom $W2_CORPUS" \
  --impl "rust_feed_rs=$BIN_DIR/rust_feed_bench atom $W2_CORPUS" \
  --baseline rust_feed_rs \
  --warmup 1 --rounds 5 --bytes "$W2_BYTES" --ops 1500 \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: JSON Feed 1.1 Batch Parse (2,000 items) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: JSON Feed 1.1 Batch Parse (2,000 items)" \
  --impl "pion=$BIN_DIR/pion_feed_bench json_feed $W3_CORPUS" \
  --impl "rust_feed_rs=$BIN_DIR/rust_feed_bench json_feed $W3_CORPUS" \
  --baseline rust_feed_rs \
  --warmup 1 --rounds 5 --bytes "$W3_BYTES" --ops 2000 \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
