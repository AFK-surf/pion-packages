#!/bin/sh
# Head-to-head benchmark runner for packages/bigint:
#   Pion Native (--release, BigIntBuf & immutable BigInt) vs Go math/big vs MoonBit core/bigint.
# All build artifacts are isolated in /tmp; zero worktree pollution.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR="${ROOT_DIR:-$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)}"
BENCH_COMPARE="${BENCH_COMPARE:-$ROOT_DIR/scripts/bench_compare.py}"
PIONC="${PIONC:-pionc}"
OUT_DIR="/tmp/pion-bigint-bench-$$"
BIN_DIR="$OUT_DIR/bin"
mkdir -p "$BIN_DIR"
trap 'rm -rf "$OUT_DIR"' EXIT

echo "==> Building Pion Native benchmarks (--release)"
"$PIONC" build --release -o "$BIN_DIR/pion_pidigits" "$BENCH_DIR/pion_pidigits"
"$PIONC" build --release -o "$BIN_DIR/pion_muldiv" "$BENCH_DIR/pion_muldiv"

IMPL_PI="--impl pion_buf=$BIN_DIR/pion_pidigits --impl pion_imm=$BIN_DIR/pion_pidigits --immutable"
# Note: pass args carefully to bench_compare.py below

HAS_GO=0
if command -v go >/dev/null 2>&1; then
  echo "==> Building Go math/big benchmarks"
  go build -o "$BIN_DIR/go_pidigits" "$BENCH_DIR/go/pidigits.go"
  go build -o "$BIN_DIR/go_muldiv" "$BENCH_DIR/go/muldiv.go"
  HAS_GO=1
fi

HAS_MOON=0
if command -v moon >/dev/null 2>&1; then
  echo "==> Building MoonBit core/bigint benchmarks (--target native --release)"
  cp -R "$BENCH_DIR/mbt" "$OUT_DIR/mbt"
  (cd "$OUT_DIR/mbt" && (moon fmt >/dev/null 2>&1 || true) && moon build --target native --release)
  MBT_PI=$(find "$OUT_DIR/mbt" -path "*/release/*" \( -name "pidigits.exe" -o -name "pidigits" \) -type f 2>/dev/null | head -n 1 || true)
  MBT_MD=$(find "$OUT_DIR/mbt" -path "*/release/*" \( -name "muldiv.exe" -o -name "muldiv" \) -type f 2>/dev/null | head -n 1 || true)
  if [ -n "$MBT_PI" ] && [ -x "$MBT_PI" ] && [ -n "$MBT_MD" ] && [ -x "$MBT_MD" ]; then
    cp "$MBT_PI" "$BIN_DIR/mbt_pidigits"
    cp "$MBT_MD" "$BIN_DIR/mbt_muldiv"
    HAS_MOON=1
  fi
fi

echo ""
echo "=== BENCH 1: pidigits N=2500 ==="
set -- python3 "$BENCH_COMPARE" \
  --title "BigInt pidigits (N=2500)" \
  --impl "pion_buf=$BIN_DIR/pion_pidigits 2500" \
  --impl "pion_imm=$BIN_DIR/pion_pidigits --immutable 2500"
if [ "$HAS_GO" -eq 1 ]; then
  set -- "$@" --impl "go_big=$BIN_DIR/go_pidigits 2500" --baseline go_big
fi
if [ "$HAS_MOON" -eq 1 ]; then
  set -- "$@" --impl "moonbit=$BIN_DIR/mbt_pidigits"
fi
"$@" --warmup 1 --rounds 5 --ops 2500

echo ""
echo "=== BENCH 2: BigInt Mul + Knuth DivRem (2000 rounds, 512x384-bit) ==="
set -- python3 "$BENCH_COMPARE" \
  --title "BigInt Mul + DivRem (2000 rounds)" \
  --impl "pion=$BIN_DIR/pion_muldiv"
if [ "$HAS_GO" -eq 1 ]; then
  set -- "$@" --impl "go_big=$BIN_DIR/go_muldiv" --baseline go_big
fi
if [ "$HAS_MOON" -eq 1 ]; then
  set -- "$@" --impl "moonbit=$BIN_DIR/mbt_muldiv"
fi
"$@" --warmup 1 --rounds 5 --ops 2000
