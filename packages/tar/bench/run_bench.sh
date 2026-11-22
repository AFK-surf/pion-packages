#!/bin/sh
# Head-to-head benchmark runner for packages/tar:
# Pion Native (packages/tar) vs Go stdlib (archive/tar) vs Rust (tar --release).
# All build artifacts and temporary inputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-tar-bench"
BIN_DIR="$OUT_DIR/bin"
CORPUS_FILE="$OUT_DIR/corpus_2000.tar"

mkdir -p "$BIN_DIR"

echo "==> Generating 2,000-entry mixed USTAR+PAX+GNU TAR corpus -> $CORPUS_FILE"
python3 "$BENCH_DIR/gen_corpus.py" "$CORPUS_FILE" 2000
CORPUS_BYTES=$(wc -c < "$CORPUS_FILE" | tr -d ' ')
TOTAL_READ_BYTES=$((CORPUS_BYTES * 20))

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_read" "$BENCH_DIR/pion_read"
pionc build --release -o "$BIN_DIR/pion_write" "$BENCH_DIR/pion_write"

echo "==> Building Go archive/tar benchmarks"
rm -rf "$OUT_DIR/go-build"
cp -R "$BENCH_DIR/go" "$OUT_DIR/go-build"
(cd "$OUT_DIR/go-build" && go build -o "$BIN_DIR/go_read" ./cmd/bench_read && go build -o "$BIN_DIR/go_write" ./cmd/bench_write)

echo "==> Building Rust tar benchmarks (--release, target and Cargo.lock in /tmp)"
rm -rf "$OUT_DIR/rust-build"
cp -R "$BENCH_DIR/rust" "$OUT_DIR/rust-build"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bench_read" "$BIN_DIR/rust_read"
cp "$OUT_DIR/rust-target/release/bench_write" "$BIN_DIR/rust_write"

echo ""
echo "=== WORKLOAD 1: Mixed USTAR/PAX/GNU TAR Read (20 x 2,000 = 40,000 entries) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "TAR: Mixed USTAR/PAX/GNU Read (40k entries)" \
  --impl "pion=$BIN_DIR/pion_read $CORPUS_FILE" \
  --impl "go_tar=$BIN_DIR/go_read $CORPUS_FILE" \
  --impl "rust_tar=$BIN_DIR/rust_read $CORPUS_FILE" \
  --baseline go_tar \
  --warmup 1 --rounds 5 --ops 40000 --bytes "$TOTAL_READ_BYTES" \
  --md-out "$OUT_DIR/read.md" --json-out "$OUT_DIR/read.json"

echo ""
echo "=== WORKLOAD 2: Mixed USTAR/PAX/GNU TAR Write (20 x 2,000 = 40,000 entries) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "TAR: Mixed USTAR/PAX/GNU Write (40k entries)" \
  --impl "pion=$BIN_DIR/pion_write" \
  --impl "go_tar=$BIN_DIR/go_write" \
  --impl "rust_tar=$BIN_DIR/rust_write" \
  --baseline go_tar \
  --warmup 1 --rounds 5 --ops 40000 --bytes "$TOTAL_READ_BYTES" \
  --md-out "$OUT_DIR/write.md" --json-out "$OUT_DIR/write.json"
