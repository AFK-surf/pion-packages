#!/bin/sh
# Head-to-head benchmark runner for packages/hyphenation (Pion Native vs Rust `hyphenation` crate --release).
# All build artifacts, Cargo target/lockfile, and temporary inputs are placed in /tmp to keep git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-hyphenation-bench"
BIN_DIR="$OUT_DIR/bin"
WORDS_FILE="$OUT_DIR/words_100k.txt"
PATS_FILE="$OUT_DIR/hyph-en-us.pat.txt"
EXCS_FILE="$OUT_DIR/hyph-en-us.hyp.txt"
WORD_ITERS="${1:-10}"
LOAD_ITERS="${2:-20}"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  else
    PIONC_BIN=$(command -v pionc)
  fi
fi

if [ -d "${HOME:-}/.cargo/bin" ]; then
  PATH="${HOME}/.cargo/bin:$PATH"
  export PATH
fi

mkdir -p "$BIN_DIR"

echo "==> Generating 100,000-word English corpus + hyph-en-us tables -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$WORDS_FILE" "$PATS_FILE" "$EXCS_FILE" 100000
WORDS_BYTES=$(wc -c < "$WORDS_FILE" | tr -d ' ')
TOTAL_WORD_BYTES=$((WORDS_BYTES * WORD_ITERS))
TOTAL_WORD_OPS=$((100000 * WORD_ITERS))

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_hyphenation" "$BENCH_DIR/pion_hyphenation"

echo "==> Building Rust hyphenation benchmark (--release, build & lockfile in /tmp)"
rm -rf "$OUT_DIR/rust_src"
mkdir -p "$OUT_DIR/rust_src"
cp -R "$BENCH_DIR/rust_hyphenation/Cargo.toml" "$BENCH_DIR/rust_hyphenation/src" "$OUT_DIR/rust_src/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust_src/Cargo.toml"
cp "$OUT_DIR/rust-target/release/hyphenation-bench-rust" "$BIN_DIR/rust_hyphenation"

# Use the exact hyph-en-us.pat.txt and hyph-en-us.hyp.txt shipped by the Rust hyphenation crate
# so both implementations run on the 100% identical pattern + exception tables.
CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
RUST_PAT_FILE=$(find "$CARGO_HOME_DIR/registry/src" -path "*/hyphenation-0.8.*/patterns/hyph-en-us.pat.txt" 2>/dev/null | head -n 1 || true)
RUST_HYP_FILE=$(find "$CARGO_HOME_DIR/registry/src" -path "*/hyphenation-0.8.*/patterns/hyph-en-us.hyp.txt" 2>/dev/null | head -n 1 || true)
if [ -n "$RUST_PAT_FILE" ] && [ -n "$RUST_HYP_FILE" ]; then
  cp "$RUST_PAT_FILE" "$PATS_FILE"
  cp "$RUST_HYP_FILE" "$EXCS_FILE"
fi

echo ""
echo "=== Bench 1: Batch Hyphenation (100,000 English words x ${WORD_ITERS} iters = ${TOTAL_WORD_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Hyphenation Batch: 100,000 English words (${WORD_ITERS} iters, ${TOTAL_WORD_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_hyphenation words $WORDS_FILE $PATS_FILE $EXCS_FILE $WORD_ITERS" \
  --impl "rust_hyphenation=$BIN_DIR/rust_hyphenation words $WORDS_FILE $WORD_ITERS" \
  --baseline rust_hyphenation \
  --warmup 1 --rounds 5 --ops "$TOTAL_WORD_OPS" --bytes "$TOTAL_WORD_BYTES" \
  --md-out "$OUT_DIR/bench1_words.md" --json-out "$OUT_DIR/bench1_words.json"

echo ""
echo "=== Bench 2: Dictionary Load (hyph-en-us 4,938 patterns x ${LOAD_ITERS} loads) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Dictionary Load: Pion from_tex vs Rust embedded bincode (${LOAD_ITERS} loads)" \
  --impl "pion=$BIN_DIR/pion_hyphenation load $PATS_FILE $EXCS_FILE $LOAD_ITERS" \
  --impl "rust_hyphenation=$BIN_DIR/rust_hyphenation load $PATS_FILE $EXCS_FILE $LOAD_ITERS" \
  --baseline rust_hyphenation \
  --warmup 1 --rounds 5 --ops "$LOAD_ITERS" \
  --md-out "$OUT_DIR/bench2_load.md" --json-out "$OUT_DIR/bench2_load.json"
