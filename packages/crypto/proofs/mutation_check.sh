#!/usr/bin/env bash
# Semantic mutation kill-rate gate for packages/crypto Stage 2 A-grade Lean 4 proofs.
# Injects 10 real cryptographic semantic faults into isolated temporary copies of
# packages/crypto/src/{ed25519,chacha20}.pion (never touching the repository worktree),
# re-extracts the Lean 4 model via `pionc extract-lean`, and verifies that `lake build`
# rejects each mutant. Enforces kill rate >= 90%.
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PIONC_BIN="${PIONC:-$(command -v pionc 2>/dev/null || echo "$HOME/.pion/bin/pionc")}"
LEAN_CACHE="${LEAN_CACHE:-/private/tmp/pion-lean-shared}"
PION_LEAN_REF="${PION_LEAN_REF:-/private/tmp/pion-lean-ref/lean}"

TMP_ROOT="$(mktemp -d /tmp/crypto_mut.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM

MUT_PKG="$TMP_ROOT/pkg"
MUT_WORK="$TMP_ROOT/work"
cp -R "$PKG_DIR" "$MUT_PKG"
rm -rf "$MUT_PKG/proofs" "$MUT_PKG/audit" "$MUT_PKG/audit_v030" "$MUT_PKG/audit_v040" "$MUT_PKG/bench"

mkdir -p "$MUT_WORK/.deps" "$MUT_WORK/.lake"
ln -sfn "$LEAN_CACHE/aeneas/backends/lean" "$MUT_WORK/.deps/aeneas"
ln -sfn "$LEAN_CACHE/proj/.lake/packages" "$MUT_WORK/.lake/packages"
cp -f "$PION_LEAN_REF/lean-toolchain" "$MUT_WORK/lean-toolchain"
cp -f "$LEAN_CACHE/proj/lake-manifest.json" "$MUT_WORK/lake-manifest.json"
cp -f "$PION_LEAN_REF/PionLean.lean" "$MUT_WORK/PionLean.lean"
cp -R "$PION_LEAN_REF/PionLean" "$MUT_WORK/PionLean"
cp "$SCRIPT_DIR/CryptoProofs.lean" "$MUT_WORK/"
cp -R "$SCRIPT_DIR/CryptoProofs" "$MUT_WORK/"

cat > "$MUT_WORK/lakefile.lean" <<'EOF'
import Lake
open Lake DSL

package pion_proofs where
  moreLeanArgs := #["-DwarningAsError=false"]

require aeneas from ".deps/aeneas"

lean_lib PionLean
lean_lib Crypto
lean_lib CryptoProofs
EOF

# Warm up PionLean once in MUT_WORK
"$PIONC_BIN" extract-lean "$MUT_PKG" --out "$MUT_WORK" >/dev/null
(cd "$MUT_WORK" && lake build PionLean Crypto.Types) >/dev/null 2>&1

run_mutant() {
  local id="$1"
  local file="$2"
  local nth="$3"
  local old="$4"
  local new="$5"
  local desc="$6"

  # Restore clean source file
  cp -f "$PKG_DIR/src/$file" "$MUT_PKG/src/$file"

  python3 - "$MUT_PKG/src/$file" "$nth" "$old" "$new" <<'PYEOF'
import sys
path, nth, old, new = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = open(path).read()
idx = -1
for _ in range(nth):
    idx = s.find(old, idx + 1)
    if idx == -1:
        sys.exit(f"ERROR: pattern {old!r} occurrence #{nth} not found in {path}")
s2 = s[:idx] + new + s[idx + len(old):]
open(path, "w").write(s2)
PYEOF

  rm -rf "$MUT_WORK/Crypto" "$MUT_WORK/Crypto.lean"
  "$PIONC_BIN" extract-lean "$MUT_PKG" --out "$MUT_WORK" >/dev/null 2>&1
  # Remove stale .olean for Crypto.Funs and FieldAndPoly1305 so lake rebuilds them
  rm -f "$MUT_WORK/.lake/build/lib/lean/Crypto/Funs.olean" \
        "$MUT_WORK/.lake/build/lib/lean/CryptoProofs/FieldAndPoly1305.olean"

  if (cd "$MUT_WORK" && lake build CryptoProofs.FieldAndPoly1305) >/dev/null 2>&1; then
    echo "SURVIVED  $id  ($desc)"
    cp -f "$PKG_DIR/src/$file" "$MUT_PKG/src/$file"
    return 1
  else
    echo "KILLED    $id  ($desc)"
    cp -f "$PKG_DIR/src/$file" "$MUT_PKG/src/$file"
    return 0
  fi
}

TOTAL=0
KILLED=0

check_one() {
  TOTAL=$((TOTAL + 1))
  if run_mutant "$@"; then
    KILLED=$((KILLED + 1))
  fi
}

echo "=== Running Stage 2 semantic mutation kill-rate gate (10 mutants) ==="
check_one "M01_fe_mul_prime18"     "ed25519.pion"  1 "let g9_19 = 19L * g9"               "let g9_19 = 18L * g9"               "fe_mul: wrong prime reduction 19 -> 18"
check_one "M02_fe_mul_wrap20"      "ed25519.pion"  1 "h0 = h0 + c9 * 19L"                 "h0 = h0 + c9 * 20L"                 "fe_mul: wrong carry wrap-around 19 -> 20"
check_one "M03_fe_mul_shift25"     "ed25519.pion"  1 "let c0 = (h0 + 33554432L) >> 26"    "let c0 = (h0 + 33554432L) >> 25"    "fe_mul: wrong radix-2^25.5 carry shift 26 -> 25"
check_one "M04_fe_sq_cross19"      "ed25519.pion"  1 "let f5_38 = 38L * f5"               "let f5_38 = 19L * f5"               "fe_sq: missing factor of 2 in cross-radix term"
check_one "M05_fe_sq_wrap17"       "ed25519.pion"  2 "h0 = h0 + c9 * 19L"                 "h0 = h0 + c9 * 17L"                 "fe_sq: wrong carry wrap-around 19 -> 17"
check_one "M06_fe_add_sign"        "ed25519.pion"  1 "h9: a.h9 + b.h9,"                   "h9: a.h9 - b.h9,"                   "fe_add: limb sign flip + -> -"
check_one "M07_fe_sub_sign"        "ed25519.pion"  1 "h9: a.h9 - b.h9,"                   "h9: a.h9 + b.h9,"                   "fe_sub: limb sign flip - -> +"
check_one "M08_poly_clamp_bit"     "chacha20.pion" 1 "& 0x3ffff03UL"                      "& 0x3ffff07UL"                      "poly1305_clamp_r: missed RFC 8439 §2.5 clamp bit"
check_one "M09_poly_reduce_thresh" "chacha20.pion" 1 "let mut g0 = h0 + 5UL"              "let mut g0 = h0 + 4UL"              "poly1305_final_reduce: wrong 2^130-5 threshold 5 -> 4"
check_one "M10_ct_nibble_off1"     "ed25519.pion"  1 "(((a ^ b) - 1) >> 31)"              "(((a ^ b) - 2) >> 31)"              "ct_eq_nibble: off-by-one branch-free equality"

PCT=$((KILLED * 100 / TOTAL))
echo "=== Mutation kill summary: $KILLED / $TOTAL killed (${PCT}%) ==="
if [ "$PCT" -lt 90 ]; then
  echo "FAIL: mutation kill rate ${PCT}% < 90% threshold" >&2
  exit 1
fi
echo "PASS: packages/crypto Stage 2 mutation kill gate (${KILLED}/${TOTAL} = ${PCT}% >= 90%)"
