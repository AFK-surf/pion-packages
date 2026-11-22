#!/bin/sh
# Three-way head-to-head benchmark runner for packages/csv:
#   Pion Native (--release) vs Rust csv (=1.4.0 --release) vs Go encoding/csv.
# All build artifacts, Cargo lockfile, and generated inputs are isolated in /tmp.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-csv-bench"
BIN_DIR="$OUT_DIR/bin"
CSV_DATA="$OUT_DIR/mixed_200k.csv"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic 200k-row mixed CSV corpus -> $CSV_DATA"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"
CSV_BYTES=$(wc -c < "$CSV_DATA" | tr -d ' ')
READ_TOTAL_BYTES=$((CSV_BYTES * 2))

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_read" "$BENCH_DIR/pion_read"
pionc build --release -o "$BIN_DIR/pion_write" "$BENCH_DIR/pion_write"

echo "==> Building Rust csv (=1.4.0 --release, project & lockfile in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bench_read" "$BIN_DIR/rust_read"
cp "$OUT_DIR/rust-target/release/bench_write" "$BIN_DIR/rust_write"

echo "==> Building Go encoding/csv benchmarks"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_read" ./cmd/bench_read)
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_write" ./cmd/bench_write)

WRITE_TOTAL_BYTES=$("$BIN_DIR/pion_write" | awk -F= '/^bytes=/{print $2}')

echo ""
echo "=== BENCH 1 (READ): 200k-row Mixed CSV x 2 rounds ($READ_TOTAL_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CSV Read: 200k-row Mixed CSV x 2 rounds" \
  --impl "pion=$BIN_DIR/pion_read $CSV_DATA" \
  --impl "rust_csv=$BIN_DIR/rust_read $CSV_DATA" \
  --impl "go_csv=$BIN_DIR/go_read $CSV_DATA" \
  --baseline go_csv \
  --warmup 1 --rounds 5 --ops 400000 --bytes "$READ_TOTAL_BYTES" \
  --md-out "$OUT_DIR/read.md" --json-out "$OUT_DIR/read.json"

echo ""
echo "=== BENCH 2 (WRITE): 200k Structured Records x 2 rounds ($WRITE_TOTAL_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CSV Write: 200k Structured Records x 2 rounds" \
  --impl "pion=$BIN_DIR/pion_write" \
  --impl "rust_csv=$BIN_DIR/rust_write" \
  --impl "go_csv=$BIN_DIR/go_write" \
  --baseline go_csv \
  --warmup 1 --rounds 5 --ops 400000 --bytes "$WRITE_TOTAL_BYTES" \
  --md-out "$OUT_DIR/write.md" --json-out "$OUT_DIR/write.json"
