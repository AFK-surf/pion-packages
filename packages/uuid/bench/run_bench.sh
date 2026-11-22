#!/bin/sh
# Head-to-head benchmark runner for packages/uuid (Pion Native vs Rust uuid + ulid --release).
# All build artifacts and temporary inputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-uuid-bench"
BIN_DIR="$OUT_DIR/bin"
UUID_FILE="$OUT_DIR/uuids_500000.txt"
ULID_FILE="$OUT_DIR/ulids_500000.txt"

mkdir -p "$BIN_DIR"

echo "==> Generating 500,000 UUIDs and 500,000 ULIDs -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR" 500000
UUID_BYTES=$(wc -c < "$UUID_FILE" | tr -d ' ')
ULID_BYTES=$(wc -c < "$ULID_FILE" | tr -d ' ')

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_uuid_batch" "$BENCH_DIR/pion_uuid_batch"
pionc build --release -o "$BIN_DIR/pion_uuid_gen" "$BENCH_DIR/pion_uuid_gen"
pionc build --release -o "$BIN_DIR/pion_ulid_batch" "$BENCH_DIR/pion_ulid_batch"

echo "==> Building Rust uuid + ulid benchmarks (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bench_uuid_batch" "$BIN_DIR/rust_uuid_batch"
cp "$OUT_DIR/rust-target/release/bench_uuid_gen" "$BIN_DIR/rust_uuid_gen"
cp "$OUT_DIR/rust-target/release/bench_ulid_batch" "$BIN_DIR/rust_ulid_batch"

echo ""
echo "=== BENCH 1: UUID Batch Parse + Sort + Format (500,000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "UUID: Batch Parse + Sort + Format (500k)" \
  --impl "pion=$BIN_DIR/pion_uuid_batch $UUID_FILE" \
  --impl "rust_uuid=$BIN_DIR/rust_uuid_batch $UUID_FILE" \
  --baseline rust_uuid \
  --warmup 1 --rounds 5 --ops 500000 --bytes "$UUID_BYTES" \
  --md-out "$OUT_DIR/uuid_batch.md" --json-out "$OUT_DIR/uuid_batch.json"

echo ""
echo "=== BENCH 2: UUID v5 (SHA-1) + v7 Generation & Format (200,000 pairs) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "UUID: v5 (SHA-1) + v7 Generation & Format (200k)" \
  --impl "pion=$BIN_DIR/pion_uuid_gen 200000" \
  --impl "rust_uuid=$BIN_DIR/rust_uuid_gen 200000" \
  --baseline rust_uuid \
  --warmup 1 --rounds 5 --ops 200000 \
  --md-out "$OUT_DIR/uuid_gen.md" --json-out "$OUT_DIR/uuid_gen.json"

echo ""
echo "=== BENCH 3: ULID Batch Parse + Sort + Format (500,000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ULID: Batch Parse + Sort + Format (500k)" \
  --impl "pion=$BIN_DIR/pion_ulid_batch $ULID_FILE" \
  --impl "rust_ulid=$BIN_DIR/rust_ulid_batch $ULID_FILE" \
  --baseline rust_ulid \
  --warmup 1 --rounds 5 --ops 500000 --bytes "$ULID_BYTES" \
  --md-out "$OUT_DIR/ulid_batch.md" --json-out "$OUT_DIR/ulid_batch.json"
