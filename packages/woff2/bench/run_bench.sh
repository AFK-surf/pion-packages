#!/bin/sh
# Head-to-head benchmark runner for packages/woff2:
# Pion Native (--release) vs Rust wuff 0.2.10 (--release).
# All build artifacts, Cargo lockfile, and corpora are isolated in /tmp.
set -eu

export PATH="${HOME:-}/.cargo/bin:/opt/homebrew/bin:${PATH:-}"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-woff2-bench"
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

echo "==> Generating real-font WOFF2 & WOFF1 corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

ARIAL_W2="$OUT_DIR/arial.woff2"
MONACO_W2="$OUT_DIR/monaco.woff2"
ARIAL_W1="$OUT_DIR/arial.woff"

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_woff2_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust wuff benchmark (--release, isolated in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/woff2-bench-rust" "$BIN_DIR/rust_woff2_bench"

echo "==> Verifying SFNT semantic identity & Pion 0xB1B0AFBA whole-font checksum"
"$BIN_DIR/pion_woff2_bench" "$ARIAL_W2" 1 "$OUT_DIR/pion_arial_w2.ttf" > "$OUT_DIR/pion_arial_w2.txt"
"$BIN_DIR/rust_woff2_bench" "$ARIAL_W2" 1 "$OUT_DIR/rust_arial_w2.ttf" > "$OUT_DIR/rust_arial_w2.txt"
"$BIN_DIR/pion_woff2_bench" "$MONACO_W2" 1 "$OUT_DIR/pion_monaco_w2.ttf" > "$OUT_DIR/pion_monaco_w2.txt"
"$BIN_DIR/rust_woff2_bench" "$MONACO_W2" 1 "$OUT_DIR/rust_monaco_w2.ttf" > "$OUT_DIR/rust_monaco_w2.txt"
"$BIN_DIR/pion_woff2_bench" "$ARIAL_W1" 1 "$OUT_DIR/pion_arial_w1.ttf" > "$OUT_DIR/pion_arial_w1.txt"
"$BIN_DIR/rust_woff2_bench" "$ARIAL_W1" 1 "$OUT_DIR/rust_arial_w1.ttf" > "$OUT_DIR/rust_arial_w1.txt"

python3 - "$OUT_DIR" <<'PYEOF'
import hashlib, os, struct, sys

def csum(b):
    pad = (4 - len(b) % 4) % 4
    b += b"\x00" * pad
    return sum(w for (w,) in struct.iter_unpack(">I", b)) & 0xFFFFFFFF

out_dir = sys.argv[1]
for name in ["arial_w2", "monaco_w2", "arial_w1"]:
    pt = open(os.path.join(out_dir, f"pion_{name}.txt"), "rb").read()
    rt = open(os.path.join(out_dir, f"rust_{name}.txt"), "rb").read()
    assert pt == rt, f"Summary mismatch on {name}:\n  pion: {pt}\n  rust: {rt}"
    p = open(os.path.join(out_dir, f"pion_{name}.ttf"), "rb").read()
    cs = csum(p)
    assert cs == 0xB1B0AFBA, f"Pion SFNT checksum mismatch on {name}: 0x{cs:08x}"
    print(f"  {name:10s}: OK (sfnt_csum=0xb1b0afba) | {pt.decode().strip()}")
PYEOF

ARIAL_W2_OUT=$(wc -c < "$OUT_DIR/pion_arial_w2.ttf" | tr -d ' ')
MONACO_W2_OUT=$(wc -c < "$OUT_DIR/pion_monaco_w2.ttf" | tr -d ' ')
ARIAL_W1_OUT=$(wc -c < "$OUT_DIR/pion_arial_w1.ttf" | tr -d ' ')

echo ""
echo "=== BENCH 1: WOFF2 Decode — Arial.woff2 (755 KB SFNT x 10) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WOFF2 Decode: Arial.woff2 (755 KB SFNT x 10)" \
  --impl "pion=$BIN_DIR/pion_woff2_bench $ARIAL_W2 10" \
  --impl "rust_wuff=$BIN_DIR/rust_woff2_bench $ARIAL_W2 10" \
  --baseline rust_wuff \
  --warmup 1 --rounds 5 --bytes "$((ARIAL_W2_OUT * 10))" \
  --md-out "$OUT_DIR/bench_arial_w2.md" --json-out "$OUT_DIR/bench_arial_w2.json"

echo ""
echo "=== BENCH 2: WOFF2 Decode — Monaco.woff2 (517 KB SFNT x 10) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WOFF2 Decode: Monaco.woff2 (517 KB SFNT x 10)" \
  --impl "pion=$BIN_DIR/pion_woff2_bench $MONACO_W2 10" \
  --impl "rust_wuff=$BIN_DIR/rust_woff2_bench $MONACO_W2 10" \
  --baseline rust_wuff \
  --warmup 1 --rounds 5 --bytes "$((MONACO_W2_OUT * 10))" \
  --md-out "$OUT_DIR/bench_monaco_w2.md" --json-out "$OUT_DIR/bench_monaco_w2.json"

echo ""
echo "=== BENCH 3: WOFF1 Decode — Arial.woff (755 KB SFNT x 10) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WOFF1 Decode: Arial.woff (755 KB SFNT x 10)" \
  --impl "pion=$BIN_DIR/pion_woff2_bench $ARIAL_W1 10" \
  --impl "rust_wuff=$BIN_DIR/rust_woff2_bench $ARIAL_W1 10" \
  --baseline rust_wuff \
  --warmup 1 --rounds 5 --bytes "$((ARIAL_W1_OUT * 10))" \
  --md-out "$OUT_DIR/bench_arial_w1.md" --json-out "$OUT_DIR/bench_arial_w1.json"
