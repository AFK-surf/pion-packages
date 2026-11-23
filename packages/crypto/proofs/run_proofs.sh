#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="crypto"
LEAN_MOD="Crypto"
PROOF_MOD="CryptoProofs"
PIONC_BIN="${PIONC:-$(command -v pionc 2>/dev/null || echo "$HOME/.pion/bin/pionc")}"
LEAN_CACHE="${LEAN_CACHE:-/private/tmp/pion-lean-shared}"
PION_LEAN_REF="${PION_LEAN_REF:-/private/tmp/pion-lean-ref/lean}"
WORK_DIR="${LEAN_WORK:-/private/tmp/pion-lean-work/$PKG_NAME}"

if [ ! -d "$LEAN_CACHE/aeneas" ] || [ ! -d "$LEAN_CACHE/proj/.lake/packages" ]; then
  echo "ERROR: shared Aeneas/Mathlib cache not found under $LEAN_CACHE" >&2
  exit 1
fi
if [ ! -d "$PION_LEAN_REF/PionLean" ] || [ ! -f "$PION_LEAN_REF/PionLean.lean" ]; then
  echo "ERROR: PionLean reference not found at $PION_LEAN_REF/PionLean" >&2
  exit 1
fi

echo "=== [1/7] Checking forbidden proof tokens ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide|unsafe|implemented_by|opaque|extern)\b' \
    "$SCRIPT_DIR/$PROOF_MOD.lean" "$SCRIPT_DIR/$PROOF_MOD"; then
  echo "FAIL: forbidden token found in proofs" >&2
  exit 1
fi

echo "=== [2/7] Preparing isolated workspace $WORK_DIR and extracting Lean 4 model ==="
mkdir -p "$WORK_DIR/.deps" "$WORK_DIR/.lake"
ln -sfn "$LEAN_CACHE/aeneas/backends/lean" "$WORK_DIR/.deps/aeneas"
ln -sfn "$LEAN_CACHE/proj/.lake/packages" "$WORK_DIR/.lake/packages"
cp -f "$PION_LEAN_REF/lean-toolchain" "$WORK_DIR/lean-toolchain"
cp -f "$LEAN_CACHE/proj/lake-manifest.json" "$WORK_DIR/lake-manifest.json"
rm -rf "$WORK_DIR/PionLean" "$WORK_DIR/PionLean.lean"
cp -f "$PION_LEAN_REF/PionLean.lean" "$WORK_DIR/PionLean.lean"
cp -R "$PION_LEAN_REF/PionLean" "$WORK_DIR/PionLean"
rm -rf "$WORK_DIR/$LEAN_MOD" "$WORK_DIR/$LEAN_MOD.lean" "$WORK_DIR/$PROOF_MOD" "$WORK_DIR/$PROOF_MOD.lean" \
       "$WORK_DIR/CheckAxioms.lean" "$WORK_DIR/EvalDiff.lean"

"$PIONC_BIN" extract-lean "$PKG_DIR" --out "$WORK_DIR"
if [ -f "$WORK_DIR/$LEAN_MOD/FunsExternal.lean" ] && grep -qE '^\s*axiom\b' "$WORK_DIR/$LEAN_MOD/FunsExternal.lean"; then
  echo "FAIL: unexpected axiom found in generated $LEAN_MOD/FunsExternal.lean" >&2
  exit 1
fi

echo "=== [3/7] Staging $PROOF_MOD into $WORK_DIR ==="
cp "$SCRIPT_DIR/$PROOF_MOD.lean" "$WORK_DIR/"
cp -R "$SCRIPT_DIR/$PROOF_MOD" "$WORK_DIR/"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$WORK_DIR/"
cp "$SCRIPT_DIR/EvalDiff.lean" "$WORK_DIR/"

cat > "$WORK_DIR/lakefile.lean" <<EOF
import Lake
open Lake DSL

package pion_proofs where
  moreLeanArgs := #["-DwarningAsError=false"]

require aeneas from ".deps/aeneas"

lean_lib PionLean
lean_lib $LEAN_MOD
lean_lib $PROOF_MOD
EOF

echo "=== [4/7] Building $LEAN_MOD + $PROOF_MOD (0 errors, 0 warnings) ==="
BUILD_LOG="$(mktemp /tmp/${PKG_NAME}_lean_build.XXXXXX)"
AXIOM_LOG="$(mktemp /tmp/${PKG_NAME}_axioms.XXXXXX)"
LEAN_OUT="$(mktemp /tmp/${PKG_NAME}_lean_eval.XXXXXX)"
NATIVE_OUT="$(mktemp /tmp/${PKG_NAME}_native_eval.XXXXXX)"
DIFF_DIR="$(mktemp -d /tmp/${PKG_NAME}_diff.XXXXXX)"
trap 'rm -rf "$BUILD_LOG" "$AXIOM_LOG" "$LEAN_OUT" "$NATIVE_OUT" "$DIFF_DIR"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM

(cd "$WORK_DIR" && lake build "$LEAN_MOD.Types" "$LEAN_MOD.Funs" "$PROOF_MOD") 2>&1 | tee "$BUILD_LOG"
if grep -E '^warning:|^error:' "$BUILD_LOG"; then
  echo "FAIL: Lean build emitted warnings or errors" >&2
  exit 1
fi

echo "=== [5/7] Auditing 1:1 theorem coverage & strict axiom whitelist (CheckAxioms.lean) ==="
(cd "$WORK_DIR" && lake env lean CheckAxioms.lean) 2>&1 | tee "$AXIOM_LOG"
python3 - "$SCRIPT_DIR" "$PROOF_MOD" "$AXIOM_LOG" <<'PYEOF'
import os, re, sys

script_dir, proof_mod, axiom_log = sys.argv[1], sys.argv[2], sys.argv[3]
declared = set()
for root, _, files in os.walk(os.path.join(script_dir, proof_mod)):
    for fn in files:
        if not fn.endswith(".lean"):
            continue
        with open(os.path.join(root, fn)) as f:
            for line in f:
                m = re.match(r"^\s*theorem\s+([A-Za-z0-9_']+)", line)
                if m:
                    declared.add(f"{proof_mod}.{m.group(1)}")

allowed = {"propext", "Classical.choice", "Quot.sound"}
audited = set()
with open(axiom_log) as f:
    for line in f:
        m = re.match(r"^'([^']+)' depends on axioms: \[(.*)\]$", line.strip())
        if m:
            thm, ax_str = m.group(1), m.group(2).strip()
            audited.add(thm)
            axs = {a.strip() for a in ax_str.split(",") if a.strip()}
            bad = axs - allowed
            if bad:
                sys.exit(f"FAIL: {thm} uses non-standard axioms: {sorted(bad)}")
        elif re.match(r"^'([^']+)' does not depend on any axioms$", line.strip()):
            audited.add(re.match(r"^'([^']+)'", line.strip()).group(1))

if not declared:
    sys.exit("FAIL: no non-private theorems declared")
if declared != audited:
    missing = sorted(declared - audited)
    extra = sorted(audited - declared)
    sys.exit(f"FAIL: CheckAxioms mismatch (missing={missing}, extra={extra})")
print(f"Axiom whitelist OK: {len(audited)}/{len(declared)} theorems verified (standard axioms only)")
PYEOF

echo "=== [6/7] Running Lean differential evaluator (EvalDiff.lean) ==="
(cd "$WORK_DIR" && lake env lean EvalDiff.lean) | tee "$LEAN_OUT"
if ! grep -q "=TRAP$" "$LEAN_OUT"; then
  echo "FAIL: EvalDiff must exercise at least one TRAP boundary" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean value differential cross-check (diff -u) ==="
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "${PKG_NAME}_diff"
version = "0.1.0"

[dependencies]
crypto = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "crypto"

pub fn main(world : World) -> Int {
  let fe_a = crypto::Fe::{ h0: 1L, h1: 2L, h2: 3L, h3: 4L, h4: 5L, h5: 6L, h6: 7L, h7: 8L, h8: 9L, h9: 10L }
  let fe_b = crypto::Fe::{ h0: 100L, h1: 200L, h2: 300L, h3: 400L, h4: 500L, h5: 600L, h6: 700L, h7: 800L, h8: 900L, h9: 1000L }
  io_println(world, "ct_eq=" + crypto::ct_diff_acc(0, 42, 42).to_string())
  io_println(world, "ct_ne=" + crypto::ct_diff_acc(0, 42, 43).to_string())
  io_println(world, "ct_min_max=" + crypto::ct_diff_acc(0, -2147483648, 2147483647).to_string())
  io_println(world, "cmov_0=" + crypto::fe_cmov(fe_a, fe_b, 0L).h0.to_string())
  io_println(world, "cmov_1=" + crypto::fe_cmov(fe_a, fe_b, 1L).h0.to_string())
  let (s0a, s0b) = crypto::fe_cswap_pair(fe_a, fe_b, 0L)
  let (s1a, s1b) = crypto::fe_cswap_pair(fe_a, fe_b, 1L)
  io_println(world, "cswap_0=" + s0a.h0.to_string() + "," + s0b.h0.to_string())
  io_println(world, "cswap_1=" + s1a.h0.to_string() + "," + s1b.h0.to_string())
  io_println(world, "clamp_lo_0=" + crypto::x25519_clamp_low_byte(0).to_string())
  io_println(world, "clamp_lo_255=" + crypto::x25519_clamp_low_byte(255).to_string())
  io_println(world, "clamp_lo_neg1=" + crypto::x25519_clamp_low_byte(-1).to_string())
  io_println(world, "clamp_hi_0=" + crypto::x25519_clamp_high_byte(0).to_string())
  io_println(world, "clamp_hi_255=" + crypto::x25519_clamp_high_byte(255).to_string())
  io_println(world, "clamp_hi_min=" + crypto::x25519_clamp_high_byte(-2147483648).to_string())
  io_println(world, "rotl_16=" + crypto::cc_rotl32(0x12345678U, 16U).to_string())
  io_println(world, "rotl_max=" + crypto::cc_rotl32(0xFFFFFFFFU, 7U).to_string())
  io_println(world, "hkdf_1=" + crypto::hkdf_sha256_blocks(1).to_string())
  io_println(world, "hkdf_8160=" + crypto::hkdf_sha256_blocks(8160).to_string())
  io_println(world, "hkdf_8161_oob=" + crypto::hkdf_sha256_blocks(8161).to_string())
  io_println(world, "hkdf_0=" + crypto::hkdf_sha256_blocks(0).to_string())
  io_println(world, "hkdf_neg1=" + crypto::hkdf_sha256_blocks(-1).to_string())
  io_println(world, "hex_0=" + crypto::hex_nibble_val(48).to_string())
  io_println(world, "hex_F=" + crypto::hex_nibble_val(70).to_string())
  io_println(world, "hex_f=" + crypto::hex_nibble_val(102).to_string())
  io_println(world, "hex_min=" + crypto::hex_nibble_val(-2147483648).to_string())
  io_println(world, "hex_max=" + crypto::hex_nibble_val(2147483647).to_string())
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"

# Also verify native trap on shift >= 32 (cc_rotl32(1, 32) and cc_rotl32(1, 0))
for shift_case in "rotl_trap_32:32U" "rotl_trap_0:0U"; do
  cname="${shift_case%%:*}"
  sval="${shift_case##*:}"
  cat > "$DIFF_DIR/src/main.pion" <<EOF
import "crypto"
pub fn main(world : World) -> Int {
  io_println(world, crypto::cc_rotl32(1U, $sval).to_string())
  0
}
EOF
  "$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/trap_bin" >/dev/null
  if "$DIFF_DIR/trap_bin" >/dev/null 2>&1; then
    echo "FAIL: expected native trap for $cname" >&2
    exit 1
  fi
done
# Compare non-TRAP lines verbatim and verify TRAP lines exist in Lean output
grep -v '=TRAP$' "$LEAN_OUT" > "$DIFF_DIR/lean_ok.txt"
diff -u "$NATIVE_OUT" "$DIFF_DIR/lean_ok.txt"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (including 2 verified native+Lean TRAP cases, diff -u exit 0)"
echo "PASS: packages/crypto Lean 4 proofs"
