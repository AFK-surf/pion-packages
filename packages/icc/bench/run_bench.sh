#!/bin/sh
# Head-to-head benchmark runner for packages/icc:
# Pion Native (`packages/icc`, --release) vs Rust `qcms 0.3` & `moxcms 0.9` (--release).
# All build artifacts and generated corpora live in /tmp/pion-icc-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-icc-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
PARSE_ITERS="${ICC_PARSE_ITERS:-100000}"
RGBA_FRAMES="${ICC_RGBA_FRAMES:-50}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating synthetic Display-P3 v4 ICC + 1920x1080 RGBA8 frame -> $DATA_DIR"
SIZES=$(python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR")
ICC_BYTES=$(echo "$SIZES" | awk '{print $1}')
RGBA_BYTES=$(echo "$SIZES" | awk '{print $2}')
echo "    icc=${ICC_BYTES} B, frame=${RGBA_BYTES} B (1920x1080 RGBA8 = 2,073,600 px)"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_icc" "$BENCH_DIR/pion_bench"

echo "==> Building Rust qcms + moxcms benchmark (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/icc_rust_bench" "$BIN_DIR/rust_icc"

echo "==> Verifying 1-frame 1920x1080 RGBA8 pixel accuracy (Pion vs qcms & moxcms)"
"$BIN_DIR/pion_icc" rgba "$DATA_DIR/display_p3_v4.icc" "$DATA_DIR/frame_1080p.rgba" 1 "$OUT_DIR/out_pion.rgba" >/dev/null
"$BIN_DIR/rust_icc" qcms rgba "$DATA_DIR/display_p3_v4.icc" "$DATA_DIR/frame_1080p.rgba" 1 "$OUT_DIR/out_qcms.rgba" >/dev/null
"$BIN_DIR/rust_icc" moxcms rgba "$DATA_DIR/display_p3_v4.icc" "$DATA_DIR/frame_1080p.rgba" 1 "$OUT_DIR/out_moxcms.rgba" >/dev/null
python3 - "$OUT_DIR/out_pion.rgba" "$OUT_DIR/out_qcms.rgba" "$OUT_DIR/out_moxcms.rgba" "$DATA_DIR/frame_1080p.rgba" <<'PY'
import sys
p = open(sys.argv[1], "rb").read()
q = open(sys.argv[2], "rb").read()
m = open(sys.argv[3], "rb").read()
orig = open(sys.argv[4], "rb").read()
assert len(p) == len(q) == len(m) == len(orig)
assert p[3::4] == orig[3::4], "Alpha channel modified!"
def chk(name, a, b, tol):
    max_d = 0
    exact = 0
    for x, y in zip(a, b):
        d = abs(x - y)
        if d > max_d: max_d = d
        if d == 0: exact += 1
    print(f"    1080p accuracy vs {name}: max_err={max_d} LSB, exact={exact*100.0/len(a):.2f}% (alpha 100% preserved)")
    assert max_d <= tol, f"max_err {max_d} > {tol} LSB vs {name}"
chk("qcms", p, q, 1)
chk("moxcms", p, m, 2)
PY

echo ""
echo "=== Scenario A: Parse Display-P3 v4 + Transform::to_srgb (${PARSE_ITERS} iters) ==="
PARSE_TOTAL_BYTES=$((ICC_BYTES * PARSE_ITERS))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ICC Parse + Transform Build Display-P3 v4 (${PARSE_ITERS}x)" \
  --impl "pion_icc=$BIN_DIR/pion_icc parse $DATA_DIR/display_p3_v4.icc $PARSE_ITERS" \
  --impl "rust_qcms=$BIN_DIR/rust_icc qcms parse $DATA_DIR/display_p3_v4.icc $PARSE_ITERS" \
  --impl "rust_moxcms=$BIN_DIR/rust_icc moxcms parse $DATA_DIR/display_p3_v4.icc $PARSE_ITERS" \
  --baseline rust_qcms \
  --warmup 1 --rounds 5 --bytes "$PARSE_TOTAL_BYTES" --ops "$PARSE_ITERS" \
  --md-out "$OUT_DIR/bench_parse.md" --json-out "$OUT_DIR/bench_parse.json"

echo ""
echo "=== Scenario B: 1920x1080 RGBA8 Display-P3 -> sRGB (${RGBA_FRAMES} frames) ==="
RGBA_TOTAL_BYTES=$((RGBA_BYTES * RGBA_FRAMES))
RGBA_TOTAL_PIXELS=$((2073600 * RGBA_FRAMES))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ICC 1920x1080 RGBA8 Display-P3 -> sRGB (${RGBA_FRAMES} frames)" \
  --impl "pion_icc=$BIN_DIR/pion_icc rgba $DATA_DIR/display_p3_v4.icc $DATA_DIR/frame_1080p.rgba $RGBA_FRAMES" \
  --impl "rust_qcms=$BIN_DIR/rust_icc qcms rgba $DATA_DIR/display_p3_v4.icc $DATA_DIR/frame_1080p.rgba $RGBA_FRAMES" \
  --impl "rust_moxcms=$BIN_DIR/rust_icc moxcms rgba $DATA_DIR/display_p3_v4.icc $DATA_DIR/frame_1080p.rgba $RGBA_FRAMES" \
  --baseline rust_qcms \
  --warmup 1 --rounds 5 --bytes "$RGBA_TOTAL_BYTES" --ops "$RGBA_TOTAL_PIXELS" \
  --md-out "$OUT_DIR/bench_rgba.md" --json-out "$OUT_DIR/bench_rgba.json"
