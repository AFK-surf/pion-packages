#!/bin/sh
# Reproducible head-to-head benchmark runner for `packages/json`:
#   Pion Native (`packages/json`, --release)
#   vs Rust (`serde_json =1.0.145`, --release)
#   vs Go (`encoding/json`, stdlib)
# All temporary artifacts and corpora are written under ${TMPDIR:-/tmp}/w17-json-bench.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="${TMPDIR:-/tmp}/w17-json-bench"
BIN_DIR="$OUT_DIR/bin"
mkdir -p "$BIN_DIR"

export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/go/bin:${PATH}"

W1_FILE="$OUT_DIR/w1_events.json"
W2_FILE="$OUT_DIR/w2_records.json"
W3_FILE="$OUT_DIR/w3_wide50k.json"

W1_ITERS="${JSON_W1_ITERS:-5}"
W2_ITERS="${JSON_W2_ITERS:-8}"
W3_ITERS="${JSON_W3_ITERS:-5}"

echo "==> Generating W1 / W2 / W3 corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" w1 "$W1_FILE" 6000
python3 "$BENCH_DIR/gen_data.py" w2 "$W2_FILE" 10000
python3 "$BENCH_DIR/gen_data.py" w3 "$W3_FILE" 50000

W1_BYTES=$(wc -c < "$W1_FILE" | tr -d ' ')
W2_BYTES=$(wc -c < "$W2_FILE" | tr -d ' ')
W3_BYTES=$(wc -c < "$W3_FILE" | tr -d ' ')
echo "    W1=${W1_BYTES} B x${W1_ITERS}, W2=${W2_BYTES} B x${W2_ITERS}, W3=${W3_BYTES} B x${W3_ITERS}"

echo "==> Building Pion Native (--release)"
pionc build --release -o "$BIN_DIR/bench_pion" "$BENCH_DIR/pion_bench"

echo "==> Building Rust serde_json (--release, CARGO_TARGET_DIR=$OUT_DIR/rust-target)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/json_bench_rust" "$BIN_DIR/bench_rust"

echo "==> Building Go encoding/json"
(
  cd "$BENCH_DIR/go_bench"
  go build -o "$BIN_DIR/bench_go" .
)

echo ""
echo "=== W1: Large Realistic JSON Parse (${W1_ITERS}x ${W1_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Large Realistic JSON Document Parse (${W1_ITERS}x ${W1_BYTES} B)" \
  --impl "rust_serde_json=$BIN_DIR/bench_rust w1 $W1_FILE $W1_ITERS" \
  --impl "go_encoding_json=$BIN_DIR/bench_go w1 $W1_FILE $W1_ITERS" \
  --impl "pion_json=$BIN_DIR/bench_pion w1 $W1_FILE $W1_ITERS" \
  --baseline rust_serde_json \
  --warmup 1 --rounds 5 --bytes "$((W1_BYTES * W1_ITERS))" --ops "$W1_ITERS" \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== W2: Parse + Extract/Filter/Mutate + Stringify Roundtrip (${W2_ITERS}x ${W2_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Parse + Extract/Filter/Mutate + Stringify Roundtrip (${W2_ITERS}x ${W2_BYTES} B)" \
  --impl "rust_serde_json=$BIN_DIR/bench_rust w2 $W2_FILE $W2_ITERS" \
  --impl "go_encoding_json=$BIN_DIR/bench_go w2 $W2_FILE $W2_ITERS" \
  --impl "pion_json=$BIN_DIR/bench_pion w2 $W2_FILE $W2_ITERS" \
  --baseline rust_serde_json \
  --warmup 1 --rounds 5 --bytes "$((W2_BYTES * W2_ITERS))" --ops "$W2_ITERS" \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W3: Wide 50,000-Key Object Parse + 50k Random Lookups + Canonical Stringify (${W3_ITERS}x ${W3_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: Wide 50k-Key Object Parse + 50k Lookups + Canonical Stringify (${W3_ITERS}x ${W3_BYTES} B)" \
  --impl "rust_serde_json=$BIN_DIR/bench_rust w3 $W3_FILE $W3_ITERS" \
  --impl "go_encoding_json=$BIN_DIR/bench_go w3 $W3_FILE $W3_ITERS" \
  --impl "pion_json=$BIN_DIR/bench_pion w3 $W3_FILE $W3_ITERS" \
  --baseline rust_serde_json \
  --warmup 1 --rounds 5 --bytes "$((W3_BYTES * W3_ITERS))" --ops "$((50000 * W3_ITERS))" \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json"
