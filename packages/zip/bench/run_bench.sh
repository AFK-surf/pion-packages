#!/bin/sh
# Head-to-head benchmark runner for packages/zip:
# Pion Native (packages/zip) vs Go 1.27 (archive/zip) vs Rust (zip =2.2.3 --release).
# All build artifacts and temporary inputs go to /private/tmp/pion-zip-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-zip-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic corpora -> $OUT_DIR"
CORPUS_INFO=$(python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR")
echo "  $CORPUS_INFO"
MIXED_UNCOMP=$(printf '%s\n' "$CORPUS_INFO" | sed -n 's/.*mixed_uncomp=\([0-9]*\).*/\1/p')

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go archive/zip benchmark"
rm -rf "$OUT_DIR/go-build"
cp -R "$BENCH_DIR/go" "$OUT_DIR/go-build"
(cd "$OUT_DIR/go-build" && GOCACHE="$OUT_DIR/gocache" go build -o "$BIN_DIR/go_bench" .)

echo "==> Building Rust zip benchmark (--release, target in /private/tmp)"
rm -rf "$OUT_DIR/rust-build"
cp -R "$BENCH_DIR/rust" "$OUT_DIR/rust-build"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build -q --release \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/zip_bench_rust" "$BIN_DIR/rust_bench"

echo ""
echo "=== WORKLOAD 1: Multi-File Mixed Text/JSON ZIP Full Decompress + CRC-32 (23.6 MB uncompressed) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ZIP: Full Decompress + CRC-32 (200 mixed files, 23.6 MB)" \
  --impl "pion=$BIN_DIR/pion_bench read $OUT_DIR/mixed_28mb.zip 1" \
  --impl "go_zip=$BIN_DIR/go_bench read $OUT_DIR/mixed_28mb.zip 1" \
  --impl "rust_zip=$BIN_DIR/rust_bench read $OUT_DIR/mixed_28mb.zip 1" \
  --baseline go_zip \
  --warmup 1 --rounds 5 --bytes "$MIXED_UNCOMP" \
  --md-out "$OUT_DIR/read.md" --json-out "$OUT_DIR/read.json"

echo ""
echo "=== WORKLOAD 2: Multi-File Mixed Text/JSON ZIP Write Deflate L6 (23.6 MB uncompressed) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ZIP: Deflate L6 Pack & Write (200 mixed files, 23.6 MB)" \
  --impl "pion=$BIN_DIR/pion_bench write $OUT_DIR/mixed_28mb.bundle 1" \
  --impl "go_zip=$BIN_DIR/go_bench write $OUT_DIR/mixed_28mb.bundle 1" \
  --impl "rust_zip=$BIN_DIR/rust_bench write $OUT_DIR/mixed_28mb.bundle 1" \
  --baseline go_zip \
  --warmup 1 --rounds 5 --bytes "$MIXED_UNCOMP" \
  --md-out "$OUT_DIR/write.md" --json-out "$OUT_DIR/write.json"

echo ""
echo "=== WORKLOAD 3: 20,000-Entry Central Directory Index Scan + 20,000 Random Name Lookups (x3 iters = 60k ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ZIP: 20,000-Entry CD Scan + 60,000 Random Name Lookups" \
  --impl "pion=$BIN_DIR/pion_bench lookup $OUT_DIR/index_20k.zip 3" \
  --impl "go_zip=$BIN_DIR/go_bench lookup $OUT_DIR/index_20k.zip 3" \
  --impl "rust_zip=$BIN_DIR/rust_bench lookup $OUT_DIR/index_20k.zip 3" \
  --baseline go_zip \
  --warmup 1 --rounds 5 --ops 60000 \
  --md-out "$OUT_DIR/lookup.md" --json-out "$OUT_DIR/lookup.json"
