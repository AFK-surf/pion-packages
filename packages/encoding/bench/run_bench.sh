#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/encoding:
# Pion Native (`packages/encoding`, --release) vs Mozilla Rust `encoding_rs` (0.8.44, --release).
# All build artifacts and generated corpora live in /tmp/pion-encoding-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-encoding-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
ITERS="${ENCODING_BENCH_ITERS:-100}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating deterministic ~1 MiB HTML corpora (UTF-8, GB18030, Shift_JIS) -> $DATA_DIR"
SIZES=$(python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR")
UTF8_SIZE=$(echo "$SIZES" | awk '{print $1}')
GB_SIZE=$(echo "$SIZES" | awk '{print $2}')
SJIS_SIZE=$(echo "$SIZES" | awk '{print $3}')
echo "    utf8=${UTF8_SIZE} B, gb18030=${GB_SIZE} B, sjis=${SJIS_SIZE} B, iters=${ITERS}"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_encoding" "$BENCH_DIR/pion_bench"

echo "==> Building Rust encoding_rs benchmark (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --offline \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/encoding_bench_rs" "$BIN_DIR/rust_encoding_rs"

echo ""
echo "=== Scenario A: Mixed ASCII + UTF-8 ~1 MiB HTML (${ITERS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Decode UTF-8 ~1 MiB HTML (${ITERS}x)" \
  --impl "pion_encoding=$BIN_DIR/pion_encoding utf8 $DATA_DIR/html_utf8.bin $ITERS" \
  --impl "rust_encoding_rs=$BIN_DIR/rust_encoding_rs utf8 $DATA_DIR/html_utf8.bin $ITERS" \
  --baseline rust_encoding_rs \
  --warmup 1 --rounds 5 --bytes "$((UTF8_SIZE * ITERS))" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench_utf8.md" --json-out "$OUT_DIR/bench_utf8.json"

echo ""
echo "=== Scenario B1: Mixed Chinese GB18030 ~1 MiB HTML (${ITERS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Decode GB18030 ~1 MiB HTML (${ITERS}x)" \
  --impl "pion_encoding=$BIN_DIR/pion_encoding gb18030 $DATA_DIR/html_gb18030.bin $ITERS" \
  --impl "rust_encoding_rs=$BIN_DIR/rust_encoding_rs gb18030 $DATA_DIR/html_gb18030.bin $ITERS" \
  --baseline rust_encoding_rs \
  --warmup 1 --rounds 5 --bytes "$((GB_SIZE * ITERS))" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench_gb18030.md" --json-out "$OUT_DIR/bench_gb18030.json"

echo ""
echo "=== Scenario B2: Mixed Japanese Shift_JIS ~1 MiB HTML (${ITERS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Decode Shift_JIS ~1 MiB HTML (${ITERS}x)" \
  --impl "pion_encoding=$BIN_DIR/pion_encoding sjis $DATA_DIR/html_sjis.bin $ITERS" \
  --impl "rust_encoding_rs=$BIN_DIR/rust_encoding_rs sjis $DATA_DIR/html_sjis.bin $ITERS" \
  --baseline rust_encoding_rs \
  --warmup 1 --rounds 5 --bytes "$((SJIS_SIZE * ITERS))" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench_sjis.md" --json-out "$OUT_DIR/bench_sjis.json"
