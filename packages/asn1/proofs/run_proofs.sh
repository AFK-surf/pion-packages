#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="asn1"
LEAN_MOD="Asn1"
PROOF_MOD="Asn1Proofs"
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
asn1 = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "asn1"

fn cls_name(c : asn1::TagClass) -> String {
  match c {
    asn1::TagClass::Universal => "Universal"
    asn1::TagClass::Application => "Application"
    asn1::TagClass::ContextSpecific => "ContextSpecific"
    asn1::TagClass::Private => "Private"
  }
}

fn bstr(b : Bool) -> String { if b { "true" } else { "false" } }

pub fn main(world : World) -> Int {
  io_println(world, "cls_code_univ=" + asn1::tag_class_code(asn1::TagClass::Universal).to_string())
  io_println(world, "cls_code_priv=" + asn1::tag_class_code(asn1::TagClass::Private).to_string())
  io_println(world, "cls_from_2=" + cls_name(asn1::tag_class_from_code(2)))
  io_println(world, "cls_from_oob=" + cls_name(asn1::tag_class_from_code(99)))
  io_println(world, "enc_seq=" + asn1::encode_tag_first_byte(asn1::TagClass::Universal, true, 16).to_string())
  io_println(world, "enc_ctx0=" + asn1::encode_tag_first_byte(asn1::TagClass::ContextSpecific, true, 0).to_string())
  io_println(world, "enc_hi=" + asn1::encode_tag_first_byte(asn1::TagClass::Application, false, 40).to_string())
  io_println(world, "enc_neg=" + asn1::encode_tag_first_byte(asn1::TagClass::Private, false, -5).to_string())
  io_println(world, "dec_cls_seq=" + cls_name(asn1::decode_tag_class_byte(48)))
  io_println(world, "dec_cls_ctx=" + cls_name(asn1::decode_tag_class_byte(160)))
  io_println(world, "dec_con_seq=" + bstr(asn1::decode_tag_constructed_byte(48)))
  io_println(world, "dec_con_int=" + bstr(asn1::decode_tag_constructed_byte(2)))
  io_println(world, "dec_low_seq=" + asn1::decode_tag_low_byte(48).to_string())
  io_println(world, "dec_low_hi=" + asn1::decode_tag_low_byte(95).to_string())
  io_println(world, "int_red_0=" + bstr(asn1::is_canonical_der_int_pair(0, 127)))
  io_println(world, "int_ok_0=" + bstr(asn1::is_canonical_der_int_pair(0, 128)))
  io_println(world, "int_red_ff=" + bstr(asn1::is_canonical_der_int_pair(255, 128)))
  io_println(world, "int_ok_ff=" + bstr(asn1::is_canonical_der_int_pair(255, 127)))
  io_println(world, "bs_empty_0=" + bstr(asn1::is_valid_bit_string_padding(0, 0, 0)))
  io_println(world, "bs_empty_1=" + bstr(asn1::is_valid_bit_string_padding(0, 1, 0)))
  io_println(world, "bs_pad_ok=" + bstr(asn1::is_valid_bit_string_padding(2, 3, 248)))
  io_println(world, "bs_pad_bad=" + bstr(asn1::is_valid_bit_string_padding(2, 3, 249)))
  io_println(world, "bs_oob_u8=" + bstr(asn1::is_valid_bit_string_padding(2, 8, 0)))
  io_println(world, "bs_neg_u=" + bstr(asn1::is_valid_bit_string_padding(2, -1, 0)))
  io_println(world, "len_neg=" + asn1::der_length_encoded_size(-1).to_string())
  io_println(world, "len_127=" + asn1::der_length_encoded_size(127).to_string())
  io_println(world, "len_128=" + asn1::der_length_encoded_size(128).to_string())
  io_println(world, "len_256=" + asn1::der_length_encoded_size(256).to_string())
  io_println(world, "len_65536=" + asn1::der_length_encoded_size(65536).to_string())
  io_println(world, "len_16m=" + asn1::der_length_encoded_size(16777216).to_string())
  io_println(world, "len_max=" + asn1::der_length_encoded_size(2147483647).to_string())
  io_println(world, "leap_2000=" + bstr(asn1::is_leap_year(2000)))
  io_println(world, "leap_1900=" + bstr(asn1::is_leap_year(1900)))
  io_println(world, "leap_2024=" + bstr(asn1::is_leap_year(2024)))
  io_println(world, "dim_feb_l=" + asn1::days_in_month(2024, 2).to_string())
  io_println(world, "dim_feb_n=" + asn1::days_in_month(2023, 2).to_string())
  io_println(world, "dim_apr=" + asn1::days_in_month(2024, 4).to_string())
  io_println(world, "dim_bad0=" + asn1::days_in_month(2024, 0).to_string())
  io_println(world, "dim_bad13=" + asn1::days_in_month(2024, 13).to_string())
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"
diff -u "$NATIVE_OUT" "$LEAN_OUT"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (diff -u exit 0)"
echo "PASS: packages/$PKG_NAME Lean 4 proofs"
