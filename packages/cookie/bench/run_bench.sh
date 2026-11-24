#!/bin/sh
# Differential parity check + head-to-head benchmark for packages/cookie:
# Pion Native (--release) vs Rust `cookie` (0.18) + `psl` (2.x) (--release).
# All build artifacts, Cargo target dir, and corpora are isolated in /tmp/pion-cookie-bench.
set -eu

export PATH="${HOME:-}/.pion/bin:${HOME:-}/.cargo/bin:/opt/homebrew/bin:${PATH:-}"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-cookie-bench"
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

echo "==> Generating Set-Cookie and Mozilla PSL corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

SC_CORPUS="$OUT_DIR/set_cookie_corpus.txt"
PSL_CORPUS="$OUT_DIR/psl_corpus.txt"
SC_BYTES=$(wc -c < "$SC_CORPUS" | tr -d ' ')
PSL_BYTES=$(wc -c < "$PSL_CORPUS" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_cookie_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust cookie + psl benchmark (--release, locked)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
if [ -f "$BENCH_DIR/rust/Cargo.lock" ]; then
  cp "$BENCH_DIR/rust/Cargo.lock" "$OUT_DIR/rust-proj/"
  CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
    --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
else
  CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
    --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
fi
cp "$OUT_DIR/rust-target/release/cookie-bench-rust" "$BIN_DIR/rust_cookie_bench"

echo ""
echo "==> Differential Parity Check (iters=0, 1-to-1 line comparison)"
"$BIN_DIR/pion_cookie_bench" parse "$SC_CORPUS" 0 > "$OUT_DIR/diff_parse_pion.txt"
"$BIN_DIR/rust_cookie_bench" parse "$SC_CORPUS" 0 > "$OUT_DIR/diff_parse_rust.txt"
diff -u "$OUT_DIR/diff_parse_rust.txt" "$OUT_DIR/diff_parse_pion.txt"
echo "PASS: Set-Cookie differential parity (200/200 cases, 0 divergences vs Rust cookie 0.18)"

"$BIN_DIR/pion_cookie_bench" psl "$PSL_CORPUS" 0 > "$OUT_DIR/diff_psl_pion.txt"
"$BIN_DIR/rust_cookie_bench" psl "$PSL_CORPUS" 0 > "$OUT_DIR/diff_psl_rust.txt"
diff -u "$OUT_DIR/diff_psl_rust.txt" "$OUT_DIR/diff_psl_pion.txt"
echo "PASS: Mozilla PSL differential parity (106/106 cases, 0 divergences vs Rust psl 2.1.261)"

SC_ITERS=2000
SC_OPS=$((200 * SC_ITERS))
echo ""
echo "=== BENCH 1: RFC 6265bis Set-Cookie Parsing (200 headers x ${SC_ITERS} = ${SC_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "RFC 6265bis Set-Cookie Parsing (200 headers x ${SC_ITERS})" \
  --impl "pion_cookie=$BIN_DIR/pion_cookie_bench parse $SC_CORPUS $SC_ITERS" \
  --impl "rust_cookie=$BIN_DIR/rust_cookie_bench parse $SC_CORPUS $SC_ITERS" \
  --baseline rust_cookie \
  --warmup 1 --rounds 5 --bytes "$((SC_BYTES * SC_ITERS))" --ops "$SC_OPS" \
  --md-out "$OUT_DIR/bench_parse.md" --json-out "$OUT_DIR/bench_parse.json"

PSL_ITERS=2000
PSL_OPS=$((106 * PSL_ITERS))
echo ""
echo "=== BENCH 2: Mozilla PSL Registrable Domain & Public Suffix Lookup (106 domains x ${PSL_ITERS} = ${PSL_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Mozilla PSL Lookup (106 domains x ${PSL_ITERS})" \
  --impl "pion_cookie=$BIN_DIR/pion_cookie_bench psl $PSL_CORPUS $PSL_ITERS" \
  --impl "rust_psl=$BIN_DIR/rust_cookie_bench psl $PSL_CORPUS $PSL_ITERS" \
  --baseline rust_psl \
  --warmup 1 --rounds 5 --bytes "$((PSL_BYTES * PSL_ITERS))" --ops "$PSL_OPS" \
  --md-out "$OUT_DIR/bench_psl.md" --json-out "$OUT_DIR/bench_psl.json"
