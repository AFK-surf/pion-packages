#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="bson"
LEAN_MOD="Bson"
PROOF_MOD="BsonProofs"
PIONC_BIN="${PIONC:-$(command -v pionc 2>/dev/null || echo "$HOME/.pion/bin/pionc")}"
LEAN_CACHE="${LEAN_CACHE:-/private/tmp/pion-lean-shared}"
PION_LEAN_REF="${PION_LEAN_REF:-/private/tmp/pion-lean-ref/lean}"
WORK_DIR="${LEAN_WORK:-/private/tmp/pion-lean-work/$PKG_NAME}"

if [ ! -d "$LEAN_CACHE/aeneas/backends/lean" ] || [ ! -d "$LEAN_CACHE/proj/.lake/packages" ]; then
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
    text = f.read()
for m in re.finditer(r"'([^']+)' depends on axioms: \[([^\]]*)\]", text, re.S):
    thm, ax_str = m.group(1), m.group(2)
    audited.add(thm)
    axs = {a.strip() for a in ax_str.split(",") if a.strip()}
    bad = axs - allowed
    if bad:
        sys.exit(f"FAIL: {thm} uses non-standard axioms: {sorted(bad)}")
for m in re.finditer(r"'([^']+)' does not depend on any axioms", text):
    audited.add(m.group(1))

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

echo "=== [7/7] Native Pion vs Lean value differential cross-check (diff -u) ==="
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "${PKG_NAME}_diff"
version = "0.1.0"

[dependencies]
bson = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "bson"

fn bstr(b : Bool) -> String { if b { "true" } else { "false" } }

pub fn main(world : World) -> Int {
  io_println(world, "sub_rt_0=" + bson::BinarySubtype::from_byte(0).to_byte().to_string())
  io_println(world, "sub_rt_4=" + bson::BinarySubtype::from_byte(4).to_byte().to_string())
  io_println(world, "sub_rt_9=" + bson::BinarySubtype::from_byte(9).to_byte().to_string())
  io_println(world, "sub_rt_42=" + bson::BinarySubtype::from_byte(42).to_byte().to_string())
  io_println(world, "sub_rt_128=" + bson::BinarySubtype::from_byte(128).to_byte().to_string())
  io_println(world, "sub_rt_255=" + bson::BinarySubtype::from_byte(255).to_byte().to_string())
  io_println(world, "sub_rt_neg=" + bson::BinarySubtype::from_byte(-1).to_byte().to_string())
  io_println(world, "hex_0=" + bson::oid_hex_val(48).to_string())
  io_println(world, "hex_9=" + bson::oid_hex_val(57).to_string())
  io_println(world, "hex_a=" + bson::oid_hex_val(97).to_string())
  io_println(world, "hex_f=" + bson::oid_hex_val(102).to_string())
  io_println(world, "hex_A=" + bson::oid_hex_val(65).to_string())
  io_println(world, "hex_F=" + bson::oid_hex_val(70).to_string())
  io_println(world, "hex_bad=" + bson::oid_hex_val(71).to_string())
  io_println(world, "hex_min=" + bson::oid_hex_val(-2147483648).to_string())
  io_println(world, "low_A=" + bson::ascii_lower(65).to_string())
  io_println(world, "low_Z=" + bson::ascii_lower(90).to_string())
  io_println(world, "low_a=" + bson::ascii_lower(97).to_string())
  io_println(world, "low_0=" + bson::ascii_lower(48).to_string())
  io_println(world, "low_max=" + bson::ascii_lower(2147483647).to_string())
  io_println(world, "u128_eq=" + bstr(bson::u128_gt(5UL, 10UL, 5UL, 10UL)))
  io_println(world, "u128_hi_gt=" + bstr(bson::u128_gt(6UL, 0UL, 5UL, 999UL)))
  io_println(world, "u128_hi_lt=" + bstr(bson::u128_gt(4UL, 999UL, 5UL, 0UL)))
  io_println(world, "u128_lo_gt=" + bstr(bson::u128_gt(5UL, 11UL, 5UL, 10UL)))
  io_println(world, "u128_max=" + bstr(bson::u128_gt(18446744073709551615UL, 18446744073709551615UL, 18446744073709551615UL, 18446744073709551614UL)))
  io_println(world, "d_nan_t=" + bstr(bson::dec128_hi_is_nan(0x7C00000000000000UL)))
  io_println(world, "d_nan_f=" + bstr(bson::dec128_hi_is_nan(0x7800000000000000UL)))
  io_println(world, "d_inf_t=" + bstr(bson::dec128_hi_is_infinite(0x7800000000000000UL)))
  io_println(world, "d_inf_neg=" + bstr(bson::dec128_hi_is_infinite(0xF800000000000000UL)))
  io_println(world, "d_inf_f=" + bstr(bson::dec128_hi_is_infinite(0x7C00000000000000UL)))
  io_println(world, "d_zero_p0=" + bstr(bson::dec128_pair_is_zero(0UL, 0UL)))
  io_println(world, "d_zero_m0=" + bstr(bson::dec128_pair_is_zero(0x8000000000000000UL, 0UL)))
  io_println(world, "d_zero_1=" + bstr(bson::dec128_pair_is_zero(0UL, 1UL)))
  io_println(world, "d_zero_nan=" + bstr(bson::dec128_pair_is_zero(0x7C00000000000000UL, 0UL)))
  io_println(world, "d_zero_inf=" + bstr(bson::dec128_pair_is_zero(0x7800000000000000UL, 0UL)))
  io_println(world, "d_zero_c3=" + bstr(bson::dec128_pair_is_zero(0x6000000000000000UL, 42UL)))
  io_println(world, "d_zero_ovf=" + bstr(bson::dec128_pair_is_zero(0x0001ED09BEAD87C0UL, 0x378D8E6400000000UL)))
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"
diff -u "$NATIVE_OUT" "$LEAN_OUT"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (diff -u exit 0)"
echo "PASS: packages/$PKG_NAME Lean 4 proofs"
