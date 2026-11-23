#!/bin/sh
# 3-way head-to-head benchmark runner for packages/regex:
# Pion Native (--release) vs Rust regex 1.11.1 (--release) vs Go stdlib regexp (RE2).
# All build artifacts and temporary inputs stay in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-regex-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_FILE="$OUT_DIR/server_logs_20k.txt"

mkdir -p "$BIN_DIR" "$OUT_DIR/rust-src/src"

echo "==> Generating 20,000 synthetic server log lines -> $DATA_FILE"
python3 "$BENCH_DIR/gen_data.py" "$DATA_FILE" 20000
DATA_BYTES=$(wc -c < "$DATA_FILE" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_regex" "$BENCH_DIR/pion_regex"

echo "==> Building Rust regex 1.11.1 benchmark (--release, out-of-tree in /tmp)"
cp "$BENCH_DIR/rust_regex/Cargo.toml" "$OUT_DIR/rust-src/Cargo.toml"
cp "$BENCH_DIR/rust_regex/src/main.rs" "$OUT_DIR/rust-src/src/main.rs"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-src/Cargo.toml"
cp "$OUT_DIR/rust-target/release/regex-bench-rust" "$BIN_DIR/rust_regex"

echo "==> Building Go regexp benchmark"
(cd "$BENCH_DIR/go_regexp" && go build -o "$BIN_DIR/go_regexp" .)

echo ""
echo "=== 1. Mixed Log Multi-Pattern Search (find_iter, 10 iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Regex find_iter: 20,000 Log Lines x 10 iters" \
  --impl "pion=$BIN_DIR/pion_regex find_iter $DATA_FILE 10" \
  --impl "rust_regex=$BIN_DIR/rust_regex find_iter $DATA_FILE 10" \
  --impl "go_regexp=$BIN_DIR/go_regexp find_iter $DATA_FILE 10" \
  --baseline rust_regex \
  --warmup 1 --rounds 5 --bytes $((DATA_BYTES * 10)) \
  --md-out "$OUT_DIR/find_iter.md" --json-out "$OUT_DIR/find_iter.json"

echo ""
echo "=== 2. Structured Log Capture Extraction (captures_iter, 5 iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Regex captures_iter: 20,000 Log Lines (6 groups) x 5 iters" \
  --impl "pion=$BIN_DIR/pion_regex captures_iter $DATA_FILE 5" \
  --impl "rust_regex=$BIN_DIR/rust_regex captures_iter $DATA_FILE 5" \
  --impl "go_regexp=$BIN_DIR/go_regexp captures_iter $DATA_FILE 5" \
  --baseline rust_regex \
  --warmup 1 --rounds 5 --bytes $((DATA_BYTES * 5)) \
  --md-out "$OUT_DIR/captures_iter.md" --json-out "$OUT_DIR/captures_iter.json"

echo ""
echo "=== 3. RegexSet Multi-Rule Parallel Matching (20,000 lines x 16 rules x 5 iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "RegexSet: 20,000 Log Lines x 16 Rules x 5 iters (100,000 ops)" \
  --impl "pion=$BIN_DIR/pion_regex regex_set $DATA_FILE 5" \
  --impl "rust_regex=$BIN_DIR/rust_regex regex_set $DATA_FILE 5" \
  --impl "go_regexp=$BIN_DIR/go_regexp regex_set $DATA_FILE 5" \
  --baseline rust_regex \
  --warmup 1 --rounds 5 --ops 100000 --bytes $((DATA_BYTES * 5)) \
  --md-out "$OUT_DIR/regex_set.md" --json-out "$OUT_DIR/regex_set.json"

echo ""
echo "=== 4. ReDoS Linear-Time Verification (4 pathological patterns x 50 iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ReDoS Linear-Time Verification (a?^40 a^40 + 4000-byte evil inputs x 50 iters)" \
  --impl "pion=$BIN_DIR/pion_regex redos none 50" \
  --impl "rust_regex=$BIN_DIR/rust_regex redos none 50" \
  --impl "go_regexp=$BIN_DIR/go_regexp redos none 50" \
  --baseline rust_regex \
  --warmup 1 --rounds 5 --ops 250 \
  --md-out "$OUT_DIR/redos.md" --json-out "$OUT_DIR/redos.json"
