#!/bin/sh
# Head-to-head benchmark and 251-vector IETF differential cross-check for
# packages/structured_fields: Pion Native (--release) vs Rust `sfv 0.16.1` (--release).
# All build artifacts, Cargo target dir, and corpora are isolated in /tmp/pion-sfv-bench.
set -eu

export PATH="${HOME:-}/.pion/bin:${HOME:-}/.cargo/bin:/opt/homebrew/bin:${PATH:-}"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-sfv-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

echo "==> Generating browser + complex corpora and 251 official IETF vectors -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_sfv_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust sfv 0.16.1 benchmark (--release, isolated in $OUT_DIR)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust_bench/Cargo.toml" "$BENCH_DIR/rust_bench/src" "$OUT_DIR/rust-proj/"
if [ -f "$BENCH_DIR/rust_bench/Cargo.lock" ]; then
  cp "$BENCH_DIR/rust_bench/Cargo.lock" "$OUT_DIR/rust-proj/"
fi
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/sfv-bench-rust" "$BIN_DIR/rust_sfv_bench"

echo ""
echo "=== DIFF: 251 official IETF httpwg/structured-field-tests bidirectional cross-check (Pion vs Rust sfv 0.16.1) ==="
"$BIN_DIR/pion_sfv_bench" diff "$OUT_DIR/ietf_vectors.txt" > "$OUT_DIR/diff_pion.txt"
"$BIN_DIR/rust_sfv_bench" diff "$OUT_DIR/ietf_vectors.txt" > "$OUT_DIR/diff_rust.txt"
if diff -u "$OUT_DIR/diff_rust.txt" "$OUT_DIR/diff_pion.txt" > "$OUT_DIR/diff_result.txt"; then
  echo "PASS: 251/251 official IETF vectors 100% byte-for-byte identical between Pion and Rust sfv 0.16.1!"
else
  echo "DIFFS FOUND between Rust sfv and Pion:"
  cat "$OUT_DIR/diff_result.txt"
  exit 1
fi

CORPUS1="$OUT_DIR/corpus_browser.txt"
CORPUS1_BYTES=$(wc -c < "$CORPUS1" | tr -d ' ')
ITERS1=5000
OPS1=$((24 * ITERS1))

echo ""
echo "=== BENCH 1: Real-World Browser HTTP Headers (24 headers x ${ITERS1} = ${OPS1} parse+serialize ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "RFC 9651 Browser HTTP Headers Parse+Serialize (24 headers x ${ITERS1})" \
  --impl "pion=$BIN_DIR/pion_sfv_bench bench $CORPUS1 $ITERS1" \
  --impl "rust_sfv=$BIN_DIR/rust_sfv_bench bench $CORPUS1 $ITERS1" \
  --baseline rust_sfv \
  --warmup 1 --rounds 5 --bytes "$((CORPUS1_BYTES * ITERS1))" --ops "$OPS1" \
  --md-out "$OUT_DIR/bench_browser.md" --json-out "$OUT_DIR/bench_browser.json"

CORPUS2="$OUT_DIR/corpus_complex.txt"
CORPUS2_BYTES=$(wc -c < "$CORPUS2" | tr -d ' ')
ITERS2=4000
OPS2=$((16 * ITERS2))

echo ""
echo "=== BENCH 2: Complex Nested RFC 9651 (Dates, Display Strings, Binary, Inner Lists, 16 cases x ${ITERS2} = ${OPS2} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "RFC 9651 Complex Nested Parse+Serialize (16 cases x ${ITERS2})" \
  --impl "pion=$BIN_DIR/pion_sfv_bench bench $CORPUS2 $ITERS2" \
  --impl "rust_sfv=$BIN_DIR/rust_sfv_bench bench $CORPUS2 $ITERS2" \
  --baseline rust_sfv \
  --warmup 1 --rounds 5 --bytes "$((CORPUS2_BYTES * ITERS2))" --ops "$OPS2" \
  --md-out "$OUT_DIR/bench_complex.md" --json-out "$OUT_DIR/bench_complex.json"
