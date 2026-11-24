#!/bin/sh
# Fair head-to-head benchmark runner for packages/icc:
# Pion Native (`packages/icc`, --release) vs Rust `qcms 0.3.0` (precached sRGB output, Firefox production config)
# and `moxcms 0.9.2` (--release).
# All build artifacts and generated corpora live in /tmp/pion-icc-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-icc-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
PARSE_ITERS="${ICC_PARSE_ITERS:-20000}"
RGBA_FRAMES="${ICC_RGBA_FRAMES:-20}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating synthetic ICC corpora (Display-P3 v4, sRGB v2 curv[1024], AdobeRGB v2 gamma, Rec.2020 para3) + 1920x1080 RGBA8 frame -> $DATA_DIR"
SIZES=$(python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR")
P3_BYTES=$(echo "$SIZES" | awk '{print $1}')
RGBA_BYTES=$(echo "$SIZES" | awk '{print $2}')
SRGB_BYTES=$(echo "$SIZES" | awk '{print $3}')
ADOBE_BYTES=$(echo "$SIZES" | awk '{print $4}')
REC2020_BYTES=$(echo "$SIZES" | awk '{print $5}')
echo "    p3=${P3_BYTES} B, srgb_curv1024=${SRGB_BYTES} B, adobe=${ADOBE_BYTES} B, rec2020=${REC2020_BYTES} B, frame=${RGBA_BYTES} B (1920x1080 RGBA8)"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_icc" "$BENCH_DIR/pion_bench"

echo "==> Building Rust qcms (precached) + moxcms benchmark (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/icc_rust_bench" "$BIN_DIR/rust_icc"

echo "==> Verifying 1-frame 1920x1080 RGBA8 pixel accuracy (Pion vs precached qcms & moxcms) + anti-identity check"
"$BIN_DIR/pion_icc" rgba "$DATA_DIR/display_p3_v4.icc" "$DATA_DIR/frame_1080p.rgba" 1 "$OUT_DIR/out_pion.rgba" >/dev/null
"$BIN_DIR/rust_icc" qcms_pre rgba "$DATA_DIR/display_p3_v4.icc" "$DATA_DIR/frame_1080p.rgba" 1 "$OUT_DIR/out_qcms.rgba" >/dev/null
"$BIN_DIR/rust_icc" moxcms rgba "$DATA_DIR/display_p3_v4.icc" "$DATA_DIR/frame_1080p.rgba" 1 "$OUT_DIR/out_moxcms.rgba" >/dev/null
python3 - "$OUT_DIR/out_pion.rgba" "$OUT_DIR/out_qcms.rgba" "$OUT_DIR/out_moxcms.rgba" "$DATA_DIR/frame_1080p.rgba" <<'PY'
import sys
p = open(sys.argv[1], "rb").read()
q = open(sys.argv[2], "rb").read()
m = open(sys.argv[3], "rb").read()
orig = open(sys.argv[4], "rb").read()
assert len(p) == len(q) == len(m) == len(orig)
assert p[3::4] == orig[3::4], "Alpha channel modified!"
assert p != orig, "Transform output is identical to input!"
def chk(name, a, b, tol):
    max_d = 0
    exact = 0
    le1 = 0
    for x, y in zip(a, b):
        d = abs(x - y)
        if d > max_d: max_d = d
        if d == 0: exact += 1
        if d <= 1: le1 += 1
    print(f"    1080p accuracy vs {name}: max_err={max_d} LSB, exact={exact*100.0/len(a):.2f}%, <=1LSB={le1*100.0/len(a):.4f}% (alpha 100% preserved)")
    assert max_d <= tol, f"max_err {max_d} > {tol} LSB vs {name}"
chk("qcms_pre", p, q, 2)
chk("moxcms", p, m, 2)
PY

echo ""
echo "=== Scenario A: Parse + Transform::to_srgb across 4 profiles (${PARSE_ITERS} iters each, vs precached qcms & moxcms) ==="
run_parse_bench() {
  name="$1"
  file="$2"
  sz="$3"
  total_bytes=$((sz * PARSE_ITERS))
  echo "--- Scenario A ($name) ---"
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "ICC Parse + Transform Build $name (${PARSE_ITERS}x)" \
    --impl "pion_icc=$BIN_DIR/pion_icc parse $file $PARSE_ITERS" \
    --impl "rust_qcms_pre=$BIN_DIR/rust_icc qcms_pre parse $file $PARSE_ITERS" \
    --impl "rust_moxcms=$BIN_DIR/rust_icc moxcms parse $file $PARSE_ITERS" \
    --baseline rust_qcms_pre \
    --warmup 1 --rounds 5 --bytes "$total_bytes" --ops "$PARSE_ITERS" \
    --md-out "$OUT_DIR/bench_parse_${name}.md" --json-out "$OUT_DIR/bench_parse_${name}.json"
}

run_parse_bench "display_p3_v4" "$DATA_DIR/display_p3_v4.icc" "$P3_BYTES"
run_parse_bench "srgb_v2_curv1024" "$DATA_DIR/srgb_v2_curv1024.icc" "$SRGB_BYTES"
run_parse_bench "adobe_v2_gamma" "$DATA_DIR/adobe_v2_gamma.icc" "$ADOBE_BYTES"
run_parse_bench "rec2020_para3_709" "$DATA_DIR/rec2020_para3_709.icc" "$REC2020_BYTES"

echo ""
echo "=== Scenario B: 1920x1080 RGBA8 Display-P3 -> sRGB (${RGBA_FRAMES} frames, vs precached qcms & moxcms) ==="
RGBA_TOTAL_BYTES=$((RGBA_BYTES * RGBA_FRAMES))
RGBA_TOTAL_PIXELS=$((2073600 * RGBA_FRAMES))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ICC 1920x1080 RGBA8 Display-P3 -> sRGB (${RGBA_FRAMES} frames)" \
  --impl "pion_icc=$BIN_DIR/pion_icc rgba $DATA_DIR/display_p3_v4.icc $DATA_DIR/frame_1080p.rgba $RGBA_FRAMES" \
  --impl "rust_qcms_pre=$BIN_DIR/rust_icc qcms_pre rgba $DATA_DIR/display_p3_v4.icc $DATA_DIR/frame_1080p.rgba $RGBA_FRAMES" \
  --impl "rust_moxcms=$BIN_DIR/rust_icc moxcms rgba $DATA_DIR/display_p3_v4.icc $DATA_DIR/frame_1080p.rgba $RGBA_FRAMES" \
  --baseline rust_qcms_pre \
  --warmup 1 --rounds 5 --bytes "$RGBA_TOTAL_BYTES" --ops "$RGBA_TOTAL_PIXELS" \
  --md-out "$OUT_DIR/bench_rgba.md" --json-out "$OUT_DIR/bench_rgba.json"
