#!/bin/sh
# Head-to-head benchmark runner for packages/lepton:
# Pion Native (--release) vs Rust lepton_jpeg 0.5.8 (--release).
# All build artifacts and generated JPEG corpora are isolated in a unique temp directory.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pion-lepton-bench.XXXXXX")
trap 'rm -rf "$OUT_DIR"' EXIT
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

if [ -z "$PIONC_BIN" ] || [ ! -x "$PIONC_BIN" ]; then
  echo "FAIL: pionc not found on PATH or at \$HOME/.pion/bin/pionc" >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Building Rust lepton_jpeg 0.5.8 reference & JPEG corpus generator (--release)"
rm -rf "$OUT_DIR/rust_src"
cp -R "$BENCH_DIR/rust" "$OUT_DIR/rust_src"
CARGO_TARGET_DIR="$OUT_DIR/cargo-target" cargo build --release --manifest-path "$OUT_DIR/rust_src/Cargo.toml"
cp "$OUT_DIR/cargo-target/release/rust_lepton_bench" "$BIN_DIR/rust_lepton_bench"

echo "==> Generating deterministic 512x512 baseline (SOF0) + progressive (SOF2) JPEGs -> $DATA_DIR"
"$BIN_DIR/rust_lepton_bench" gen "$DATA_DIR"
ls -lh "$DATA_DIR"/*.jpg

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_lepton_bench" "$BENCH_DIR/pion_bench"

BASE_JPG="$DATA_DIR/photo_512_base.jpg"
PROG_JPG="$DATA_DIR/photo_512_prog.jpg"
BASE_SIZE=$(wc -c < "$BASE_JPG" | tr -d ' ')
PROG_SIZE=$(wc -c < "$PROG_JPG" | tr -d ' ')
BASE_SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$BASE_JPG")
PROG_SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$PROG_JPG")

ITERS=10
BASE_BYTES=$((BASE_SIZE * ITERS))
PROG_BYTES=$((PROG_SIZE * ITERS))

echo ""
echo "=== BENCH 1: Baseline 512x512 JPEG (SOF0, $BASE_SIZE B) Roundtrip x$ITERS ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Lepton Baseline 512x512 JPEG (SOF0) Roundtrip (x$ITERS)" \
  --impl "pion_lepton=$BIN_DIR/pion_lepton_bench roundtrip $BASE_JPG $ITERS $DATA_DIR/pion_base.lep" \
  --impl "rust_lepton_jpeg=$BIN_DIR/rust_lepton_bench roundtrip $BASE_JPG $ITERS $DATA_DIR/rust_base.lep" \
  --baseline rust_lepton_jpeg \
  --expect-sha256 "$BASE_SHA" \
  --warmup 1 --rounds 5 --bytes "$BASE_BYTES" \
  --md-out "$OUT_DIR/bench_base_rt.md" --json-out "$OUT_DIR/bench_base_rt.json"

echo ""
echo "=== BENCH 2: Progressive 512x512 JPEG (SOF2, $PROG_SIZE B) Roundtrip x$ITERS ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Lepton Progressive 512x512 JPEG (SOF2) Roundtrip (x$ITERS)" \
  --impl "pion_lepton=$BIN_DIR/pion_lepton_bench roundtrip $PROG_JPG $ITERS $DATA_DIR/pion_prog.lep" \
  --impl "rust_lepton_jpeg=$BIN_DIR/rust_lepton_bench roundtrip $PROG_JPG $ITERS $DATA_DIR/rust_prog.lep" \
  --baseline rust_lepton_jpeg \
  --expect-sha256 "$PROG_SHA" \
  --warmup 1 --rounds 5 --bytes "$PROG_BYTES" \
  --md-out "$OUT_DIR/bench_prog_rt.md" --json-out "$OUT_DIR/bench_prog_rt.json"

echo ""
echo "=== BENCH 3: Baseline 512x512 JPEG (SOF0) Decode-Only x$ITERS ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Lepton Baseline 512x512 JPEG (SOF0) Decode (x$ITERS)" \
  --impl "pion_lepton=$BIN_DIR/pion_lepton_bench decode $DATA_DIR/pion_base.lep $ITERS" \
  --impl "rust_lepton_jpeg=$BIN_DIR/rust_lepton_bench decode $DATA_DIR/rust_base.lep $ITERS" \
  --baseline rust_lepton_jpeg \
  --expect-sha256 "$BASE_SHA" \
  --warmup 1 --rounds 5 --bytes "$BASE_BYTES" \
  --md-out "$OUT_DIR/bench_base_dec.md" --json-out "$OUT_DIR/bench_base_dec.json"

echo ""
echo "=== Compressed Sizes Summary ==="
PION_BASE_LEN=$(wc -c < "$DATA_DIR/pion_base.lep" | tr -d ' ')
RUST_BASE_LEN=$(wc -c < "$DATA_DIR/rust_base.lep" | tr -d ' ')
PION_PROG_LEN=$(wc -c < "$DATA_DIR/pion_prog.lep" | tr -d ' ')
RUST_PROG_LEN=$(wc -c < "$DATA_DIR/rust_prog.lep" | tr -d ' ')
python3 - "$BASE_SIZE" "$PION_BASE_LEN" "$RUST_BASE_LEN" "$PROG_SIZE" "$PION_PROG_LEN" "$RUST_PROG_LEN" <<'PY'
import sys
b_orig, b_pion, b_rust, p_orig, p_pion, p_rust = map(int, sys.argv[1:7])
def pct(orig, comp):
    return (1.0 - comp / orig) * 100.0
print(f"Baseline 512x512 (SOF0): orig={b_orig} B | pion={b_pion} B (-{pct(b_orig, b_pion):.2f}%) | rust={b_rust} B (-{pct(b_orig, b_rust):.2f}%)")
print(f"Progressive 512x512 (SOF2): orig={p_orig} B | pion={p_pion} B (-{pct(p_orig, p_pion):.2f}%) | rust={p_rust} B (-{pct(p_orig, p_rust):.2f}%)")
PY
