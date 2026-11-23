#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/asn1`.
# All Lake build artifacts stay in /private/tmp/pion-lean-shared (single shared Mathlib .lake, zero git worktree pollution).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-$WORK/pion-ref}"
AENEAS_REV=1dc8ad31b1
PIONC="${PIONC:-pionc}"

mkdir -p "$WORK"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas@$AENEAS_REV in $WORK ==="
if [ ! -d "$PION_REF/lean" ]; then
  if [ -d "/private/tmp/pion-lean-ref/lean" ]; then
    PION_REF="/private/tmp/pion-lean-ref"
  elif [ -d "/private/tmp/pion-lean-ref-semver/lean" ]; then
    PION_REF="/private/tmp/pion-lean-ref-semver"
  else
    git clone --depth 1 -q https://github.com/AFK-surf/pion.git "$PION_REF"
  fi
fi

if [ -z "${AENEAS_DIR:-}" ]; then
  if [ -d "/private/tmp/pion-lean-semver/aeneas/backends/lean" ]; then
    AENEAS_DIR="/private/tmp/pion-lean-semver/aeneas/backends/lean"
  else
    if [ ! -d "$WORK/aeneas/.git" ]; then
      git clone -q https://github.com/AeneasVerif/aeneas.git "$WORK/aeneas"
    fi
    git -C "$WORK/aeneas" checkout -q "$AENEAS_REV"
    AENEAS_DIR="$WORK/aeneas/backends/lean"
  fi
fi

if [ ! -f "$PROJ/lakefile.lean" ] || [ ! -d "$PROJ/.lake/packages/mathlib" ]; then
  rm -rf "$PROJ"
  mkdir -p "$PROJ/.deps" "$PROJ/.lake"
  (cd "$PION_REF/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
  (cd "$PROJ" && lake exe cache get)
else
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

echo "=== [2/7] pionc extract-lean packages/asn1 ==="
rm -rf "$PROJ/Asn1"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Asn1/$f.lean" ]; then
    echo "FAIL: missing Asn1/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/Asn1Proofs"
cp -R "$SCRIPT_DIR/Asn1Proofs" "$PROJ/Asn1Proofs"
cp "$SCRIPT_DIR/Asn1Proofs.lean" "$PROJ/Asn1Proofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Asn1 where\n  globs := #[.submodules `Asn1]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib Asn1Proofs where\n  globs := #[.andSubmodules `Asn1Proofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/Asn1Proofs.lean" "$SCRIPT_DIR/Asn1Proofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Asn1 Asn1Proofs ==="
cd "$PROJ"
set +e
lake build PionLean Asn1 Asn1Proofs > "$WORK/build.log" 2>&1
RC=$?
set -e
grep -v '^✔\|^trace\|^info' "$WORK/build.log" | tail -80 || true
if [ "$RC" -ne 0 ] || grep -q '^error' "$WORK/build.log"; then
  echo "FAIL: lake build failed (rc=$RC)" >&2
  cat "$WORK/build.log" >&2
  exit 1
fi
if grep -q "declaration uses .sorry" "$WORK/build.log"; then
  echo "FAIL: declaration uses sorry" >&2
  exit 1
fi
echo "lake build PionLean Asn1 Asn1Proofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
AXIOMS_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" CheckAxioms.lean 2>&1)
echo "$AXIOMS_OUT"
BAD_AXIOMS=$(printf '%s\n' "$AXIOMS_OUT" | grep -E "depends on axioms:" | sed 's/.*\[//;s/\].*//;s/,/\n/g' | tr -d ' ' | sort -u | grep -v -E '^(propext|Classical\.choice|Quot\.sound)$' || true)
if [ -n "$BAD_AXIOMS" ]; then
  echo "FAIL: unexpected axioms found: $BAD_AXIOMS" >&2
  exit 1
fi
if printf '%s\n' "$AXIOMS_OUT" | grep -q "error:"; then
  echo "FAIL: CheckAxioms.lean reported errors" >&2
  exit 1
fi
echo "Axioms audit: ONLY standard axioms (propext, Classical.choice, Quot.sound)"

echo "=== [6/7] EvalDiff.lean (#eval) ==="
EVAL_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" --run EvalDiff.lean 2>&1)
echo "$EVAL_OUT"
if printf '%s\n' "$EVAL_OUT" | grep -q "error:"; then
  echo "FAIL: EvalDiff.lean reported errors" >&2
  exit 1
fi
if printf '%s\n' "$EVAL_OUT" | grep -q ': FAIL$'; then
  echo "FAIL: EvalDiff.lean had a FAIL check" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_DIR="$WORK/native-diff"
rm -rf "$DIFF_DIR"
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "asn1_lean_diff"
version = "0.1.0"

[dependencies]
asn1 = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "asn1"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "cls_univ", asn1::tag_class_code(asn1::TagClass::Universal) == 0)
  report(w, "cls_priv", asn1::tag_class_code(asn1::TagClass::Private) == 3)
  report(w, "cls_from_2", asn1::tag_class_equals(asn1::tag_class_from_code(2), asn1::TagClass::ContextSpecific))
  report(w, "cls_eq_t", asn1::tag_class_equals(asn1::TagClass::Application, asn1::TagClass::Application))
  report(w, "cls_eq_f", !asn1::tag_class_equals(asn1::TagClass::Universal, asn1::TagClass::Private))
  report(w, "tag_eq_t", asn1::Tag::new(asn1::TagClass::Universal, true, 16).equals(asn1::Tag::new(asn1::TagClass::Universal, true, 16)))
  report(w, "tag_eq_f", !asn1::Tag::new(asn1::TagClass::Universal, true, 16).equals(asn1::Tag::new(asn1::TagClass::Universal, false, 16)))

  report(w, "enc_seq", asn1::encode_tag_first_byte(asn1::TagClass::Universal, true, 16) == 48)
  report(w, "enc_ctx0", asn1::encode_tag_first_byte(asn1::TagClass::ContextSpecific, true, 0) == 160)
  report(w, "enc_hi", asn1::encode_tag_first_byte(asn1::TagClass::Application, false, 40) == 95)
  report(w, "dec_cls_seq", asn1::tag_class_equals(asn1::decode_tag_class_byte(48), asn1::TagClass::Universal))
  report(w, "dec_cls_ctx", asn1::tag_class_equals(asn1::decode_tag_class_byte(160), asn1::TagClass::ContextSpecific))
  report(w, "dec_con_seq", asn1::decode_tag_constructed_byte(48))
  report(w, "dec_con_int", !asn1::decode_tag_constructed_byte(2))
  report(w, "dec_low_seq", asn1::decode_tag_low_byte(48) == 16)
  report(w, "dec_low_hi", asn1::decode_tag_low_byte(95) == 31)

  report(w, "bool_0", asn1::is_canonical_der_bool_byte(0))
  report(w, "bool_ff", asn1::is_canonical_der_bool_byte(255))
  report(w, "bool_1", !asn1::is_canonical_der_bool_byte(1))
  report(w, "int_red_0", !asn1::is_canonical_der_int_pair(0, 127))
  report(w, "int_ok_0", asn1::is_canonical_der_int_pair(0, 128))
  report(w, "int_red_ff", !asn1::is_canonical_der_int_pair(255, 128))
  report(w, "int_ok_ff", asn1::is_canonical_der_int_pair(255, 127))
  report(w, "bs_empty_0", asn1::is_valid_bit_string_padding(0, 0, 0))
  report(w, "bs_empty_1", !asn1::is_valid_bit_string_padding(0, 1, 0))
  report(w, "bs_pad_ok", asn1::is_valid_bit_string_padding(2, 3, 248))
  report(w, "bs_pad_bad", !asn1::is_valid_bit_string_padding(2, 3, 249))
  report(w, "bs_bad_u8", !asn1::is_valid_bit_string_padding(2, 8, 0))
  report(w, "len_1", asn1::der_length_encoded_size(127) == 1)
  report(w, "len_2", asn1::der_length_encoded_size(128) == 2)
  report(w, "len_3", asn1::der_length_encoded_size(256) == 3)
  report(w, "len_4", asn1::der_length_encoded_size(65536) == 4)
  report(w, "len_5", asn1::der_length_encoded_size(16777216) == 5)

  report(w, "leap_2000", asn1::is_leap_year(2000))
  report(w, "leap_1900", !asn1::is_leap_year(1900))
  report(w, "leap_2024", asn1::is_leap_year(2024))
  report(w, "dim_feb_l", asn1::days_in_month(2024, 2) == 29)
  report(w, "dim_feb_n", asn1::days_in_month(2023, 2) == 28)
  report(w, "dim_apr", asn1::days_in_month(2024, 4) == 30)
  report(w, "dim_bad", asn1::days_in_month(2024, 13) == 0)
  report(w, "utc_50", asn1::utc_time_expand_year(50) == 1950)
  report(w, "utc_49", asn1::utc_time_expand_year(49) == 2049)
  report(w, "hms_ok", asn1::is_valid_hms(23, 59, 59))
  report(w, "hms_bad", !asn1::is_valid_hms(24, 0, 0))
  report(w, "pem_A", asn1::is_pem_label_char(65))
  report(w, "pem_sp", !asn1::is_pem_label_char(32))
  report(w, "pem_dash", !asn1::is_pem_label_char(45))
  report(w, "ku_ca", (asn1::KeyUsage::{ bits: 32 }).key_cert_sign())
  report(w, "ku_ca_ds", !(asn1::KeyUsage::{ bits: 32 }).digital_signature())
  report(w, "ku_all_do", (asn1::KeyUsage::{ bits: 511 }).decipher_only())
  0
}
EOF

"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/asn1 Lean 4 proofs"
