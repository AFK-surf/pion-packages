#!/bin/sh
# Head-to-head benchmark runner for packages/time (Pion Native vs Rust jiff vs Go time).
# All build artifacts and temporary inputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-time-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_FILE="$OUT_DIR/rfc3339_200k.txt"

mkdir -p "$BIN_DIR"

echo "==> Generating 200,000 RFC 3339 timestamps -> $DATA_FILE"
python3 "$BENCH_DIR/gen_data.py" "$DATA_FILE" 200000
DATA_BYTES=$(wc -c < "$DATA_FILE" | tr -d ' ')

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_rfc3339" "$BENCH_DIR/pion_rfc3339"
pionc build --release -o "$BIN_DIR/pion_civil" "$BENCH_DIR/pion_civil"

echo "==> Building Rust jiff benchmarks (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bench_rfc3339" "$BIN_DIR/rust_rfc3339"
cp "$OUT_DIR/rust-target/release/bench_civil" "$BIN_DIR/rust_civil"

echo "==> Building Go time benchmarks"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_rfc3339" ./cmd/bench_rfc3339 && go build -o "$BIN_DIR/go_civil" ./cmd/bench_civil)

echo ""
echo "=== WORKLOAD 1: RFC 3339 Batch Parse + Offset Shift + Format (200,000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Time: RFC 3339 Batch Parse + Offset Shift + Format (200k)" \
  --impl "pion=$BIN_DIR/pion_rfc3339 $DATA_FILE" \
  --impl "rust_jiff=$BIN_DIR/rust_rfc3339 $DATA_FILE" \
  --impl "go_time=$BIN_DIR/go_rfc3339 $DATA_FILE" \
  --baseline rust_jiff \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$DATA_BYTES" \
  --md-out "$OUT_DIR/rfc3339.md" --json-out "$OUT_DIR/rfc3339.json"

echo ""
echo "=== WORKLOAD 2: Civil Calendar & Epoch Intensive Computation (2,000,000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Time: Civil Calendar & Epoch Roundtrip (2M ops)" \
  --impl "pion=$BIN_DIR/pion_civil" \
  --impl "rust_jiff=$BIN_DIR/rust_civil" \
  --impl "go_time=$BIN_DIR/go_civil" \
  --baseline rust_jiff \
  --warmup 1 --rounds 5 --ops 2000000 \
  --md-out "$OUT_DIR/civil.md" --json-out "$OUT_DIR/civil.json"
