#!/bin/sh
# Head-to-head benchmark runner for packages/glob (Pion Native vs Rust BurntSushi/globset).
# All build artifacts and temporary inputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-glob-bench"
BIN_DIR="$OUT_DIR/bin"
PATHS_FILE="$OUT_DIR/paths_50k.txt"
RULES_FILE="$OUT_DIR/rules_80.txt"
ITERS="${1:-10}"

mkdir -p "$BIN_DIR"

echo "==> Generating 50,000 monorepo paths + 80 GlobSet rules -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$PATHS_FILE" "$RULES_FILE" 50000
PATHS_BYTES=$(wc -c < "$PATHS_FILE" | tr -d ' ')
TOTAL_BYTES=$((PATHS_BYTES * ITERS))
TOTAL_OPS=$((50000 * ITERS))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_glob" "$BENCH_DIR/pion_glob"

echo "==> Building Rust globset benchmark (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_globset/Cargo.toml"
cp "$OUT_DIR/rust-target/release/glob-bench-rust" "$BIN_DIR/rust_globset"

echo ""
echo "=== GlobSet: 50,000 Monorepo Paths x 80 Rules x ${ITERS} iters (${TOTAL_OPS} matches_into calls) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "GlobSet: 50,000 Paths x 80 Rules (${ITERS} iters, ${TOTAL_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_glob $PATHS_FILE $RULES_FILE $ITERS" \
  --impl "rust_globset=$BIN_DIR/rust_globset $PATHS_FILE $RULES_FILE $ITERS" \
  --baseline rust_globset \
  --warmup 1 --rounds 5 --ops "$TOTAL_OPS" --bytes "$TOTAL_BYTES" \
  --md-out "$OUT_DIR/globset.md" --json-out "$OUT_DIR/globset.json"
