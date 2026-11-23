#!/bin/sh
# Head-to-head benchmark runner for packages/unicode_bidi (Pion Native vs Rust unicode-bidi 0.3.18 --release).
# All build artifacts and temporary inputs live in /tmp to keep the git worktree completely clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-unicode-bidi-bench"
BIN_DIR="$OUT_DIR/bin"

if [ -d "${HOME:-}/.cargo/bin" ]; then
  PATH="${HOME}/.cargo/bin:${PATH}"
  export PATH
fi

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

mkdir -p "$BIN_DIR"

echo "==> Generating BiDi corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

LTR_FILE="$OUT_DIR/pure_ltr.txt"
MIX_FILE="$OUT_DIR/mixed_ar_he_en.txt"
DEEP_FILE="$OUT_DIR/deep_isolate_brackets.txt"

LTR_BYTES=$(wc -c < "$LTR_FILE" | tr -d ' ')
MIX_BYTES=$(wc -c < "$MIX_FILE" | tr -d ' ')
DEEP_BYTES=$(wc -c < "$DEEP_FILE" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_bidi" "$BENCH_DIR/pion_bidi"

echo "==> Building Rust unicode-bidi benchmark (--release, build & lockfile in /tmp)"
rm -rf "$OUT_DIR/rust_src"
mkdir -p "$OUT_DIR/rust_src"
cp -R "$BENCH_DIR/rust_bidi/Cargo.toml" "$BENCH_DIR/rust_bidi/src" "$OUT_DIR/rust_src/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust_src/Cargo.toml"
cp "$OUT_DIR/rust-target/release/unicode-bidi-bench-rust" "$BIN_DIR/rust_bidi"

echo ""
echo "=== Bench 1: Pure LTR fast path (2,000 paras x 20 iters = 40,000 ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Bench 1: Pure LTR fast path (2k x 20 = 40k ops)" \
  --impl "pion=$BIN_DIR/pion_bidi levels $LTR_FILE 20" \
  --impl "rust_unicode_bidi=$BIN_DIR/rust_bidi levels $LTR_FILE 20" \
  --baseline rust_unicode_bidi \
  --warmup 1 --rounds 5 --ops 40000 --bytes $((LTR_BYTES * 20)) \
  --md-out "$OUT_DIR/bench1_ltr.md" --json-out "$OUT_DIR/bench1_ltr.json"

echo ""
echo "=== Bench 2: Mixed Arabic/Hebrew/English paragraphs (2,000 paras x 5 iters = 10,000 ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Bench 2: Mixed Ar/He/En paragraphs (2k x 5 = 10k ops)" \
  --impl "pion=$BIN_DIR/pion_bidi levels $MIX_FILE 5" \
  --impl "rust_unicode_bidi=$BIN_DIR/rust_bidi levels $MIX_FILE 5" \
  --baseline rust_unicode_bidi \
  --warmup 1 --rounds 5 --ops 10000 --bytes $((MIX_BYTES * 5)) \
  --md-out "$OUT_DIR/bench2_mixed.md" --json-out "$OUT_DIR/bench2_mixed.json"

echo ""
echo "=== Bench 3: Deeply nested isolates & paired brackets (1,000 paras x 5 iters = 5,000 ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Bench 3: Deep nested isolates & brackets (1k x 5 = 5k ops)" \
  --impl "pion=$BIN_DIR/pion_bidi levels $DEEP_FILE 5" \
  --impl "rust_unicode_bidi=$BIN_DIR/rust_bidi levels $DEEP_FILE 5" \
  --baseline rust_unicode_bidi \
  --warmup 1 --rounds 5 --ops 5000 --bytes $((DEEP_BYTES * 5)) \
  --md-out "$OUT_DIR/bench3_deep.md" --json-out "$OUT_DIR/bench3_deep.json"

echo ""
echo "=== Bench 4: Per-line visual_runs + reorder_line (2,000 lines x 5 iters = 10,000 ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Bench 4: Per-line visual_runs + reorder_line (2k x 5 = 10k ops)" \
  --impl "pion=$BIN_DIR/pion_bidi reorder $MIX_FILE 5" \
  --impl "rust_unicode_bidi=$BIN_DIR/rust_bidi reorder $MIX_FILE 5" \
  --baseline rust_unicode_bidi \
  --warmup 1 --rounds 5 --ops 10000 --bytes $((MIX_BYTES * 5)) \
  --md-out "$OUT_DIR/bench4_reorder.md" --json-out "$OUT_DIR/bench4_reorder.json"
