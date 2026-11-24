#!/bin/sh
# Differential parity check + head-to-head benchmark for packages/dash:
# Pion Native (--release) vs Rust `dash-mpd-core` v0.1.0 (from `dash-mpd` v0.21.0) (--release).
# All build artifacts, Cargo target dir, and corpora are isolated in /tmp/pion-dash-bench.
set -eu

export PATH="${HOME:-}/.pion/bin:${HOME:-}/.cargo/bin:/opt/homebrew/bin:${PATH:-}"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-dash-bench"
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

echo "==> Generating synthetic MPEG-DASH .mpd corpus -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

CORPUS="$OUT_DIR/mpd_corpus.txt"
CORPUS_BYTES=$(wc -c < "$CORPUS" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_dash_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust dash-mpd-core benchmark (--release, locked)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust_bench/Cargo.toml" "$BENCH_DIR/rust_bench/src" "$OUT_DIR/rust-proj/"
if [ -f "$BENCH_DIR/rust_bench/Cargo.lock" ]; then
  cp "$BENCH_DIR/rust_bench/Cargo.lock" "$OUT_DIR/rust-proj/"
  CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
    --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
else
  CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
    --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
fi
cp "$OUT_DIR/rust-target/release/dash-bench-rust" "$BIN_DIR/rust_dash_bench"

echo ""
echo "==> Differential Parity Check (iters=0, 1-to-1 field-by-field comparison across 60 MPDs)"
"$BIN_DIR/pion_dash_bench" "$CORPUS" 0 > "$OUT_DIR/diff_pion.txt"
"$BIN_DIR/rust_dash_bench" "$CORPUS" 0 > "$OUT_DIR/diff_rust.txt"
diff -u "$OUT_DIR/diff_rust.txt" "$OUT_DIR/diff_pion.txt"
echo "PASS: MPEG-DASH differential parity (60/60 manifests, 0 divergences vs Rust dash-mpd-core 0.1.0)"

ITERS=200
OPS=$((60 * ITERS))
echo ""
echo "=== BENCH: MPEG-DASH MPD Parsing (60 manifests x ${ITERS} = ${OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "MPEG-DASH MPD Parsing (60 manifests x ${ITERS})" \
  --impl "pion_dash=$BIN_DIR/pion_dash_bench $CORPUS $ITERS" \
  --impl "rust_dash_mpd=$BIN_DIR/rust_dash_bench $CORPUS $ITERS" \
  --baseline rust_dash_mpd \
  --warmup 1 --rounds 5 --bytes "$((CORPUS_BYTES * ITERS))" --ops "$OPS" \
  --md-out "$OUT_DIR/bench_dash.md" --json-out "$OUT_DIR/bench_dash.json"
