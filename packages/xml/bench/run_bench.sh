#!/bin/sh
# Head-to-head benchmark runner for packages/xml (Pion Native vs Rust roxmltree & quick-xml --release).
# All build artifacts and temporary inputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-xml-bench"
BIN_DIR="$OUT_DIR/bin"
CORPUS="$OUT_DIR/mixed_corpus.xml"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic mixed XML corpus -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"
CORPUS_BYTES=$(wc -c < "$CORPUS" | tr -d ' ')
TOTAL_BYTES=$((CORPUS_BYTES * 10))

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_dom" "$BENCH_DIR/pion_dom"
pionc build --release -o "$BIN_DIR/pion_stream" "$BENCH_DIR/pion_stream"
pionc build --release -o "$BIN_DIR/pion_write" "$BENCH_DIR/pion_write"

echo "==> Building Rust roxmltree & quick-xml benchmarks (--release, Cargo in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bench_dom" "$BIN_DIR/rust_dom"
cp "$OUT_DIR/rust-target/release/bench_stream" "$BIN_DIR/rust_stream"
cp "$OUT_DIR/rust-target/release/bench_write" "$BIN_DIR/rust_write"

WRITE_BYTES=$("$BIN_DIR/pion_write" | awk -F= '/^total_bytes=/{print $2}')

echo ""
echo "=== BENCH 1: DOM Parse + Full Tree Traverse (10 rounds, $TOTAL_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "XML Bench 1: DOM Parse + Traverse (10 rounds)" \
  --impl "pion=$BIN_DIR/pion_dom $CORPUS" \
  --impl "rust_roxmltree=$BIN_DIR/rust_dom $CORPUS" \
  --baseline rust_roxmltree \
  --warmup 1 --rounds 5 --bytes "$TOTAL_BYTES" \
  --md-out "$OUT_DIR/dom.md" --json-out "$OUT_DIR/dom.json"

echo ""
echo "=== BENCH 2: Streaming Pull Parse (10 rounds, $TOTAL_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "XML Bench 2: Streaming Pull Parse (10 rounds)" \
  --impl "pion=$BIN_DIR/pion_stream $CORPUS" \
  --impl "rust_quick_xml=$BIN_DIR/rust_stream $CORPUS" \
  --baseline rust_quick_xml \
  --warmup 1 --rounds 5 --bytes "$TOTAL_BYTES" \
  --md-out "$OUT_DIR/stream.md" --json-out "$OUT_DIR/stream.json"

echo ""
echo "=== BENCH 3: Structured XML Serialization (5 rounds, $WRITE_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "XML Bench 3: Write / Serialize (5 rounds)" \
  --impl "pion=$BIN_DIR/pion_write" \
  --impl "rust_quick_xml=$BIN_DIR/rust_write" \
  --baseline rust_quick_xml \
  --warmup 1 --rounds 5 --bytes "$WRITE_BYTES" \
  --md-out "$OUT_DIR/write.md" --json-out "$OUT_DIR/write.json"
