#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/decimal`.
#
# Builds a throw-away Lake project in /private/tmp/pion-lean-decimal (zero git
# worktree pollution), extracts `packages/decimal` via `pionc extract-lean`,
# compiles `PionLean`, `Decimal`, and `DecimalProofs`, rejects any
# `sorry`/`admit`/`native_decide`/`bv_decide`, verifies `#print axioms`
# (only `propext`, `Classical.choice`, `Quot.sound`), and runs `EvalDiff.lean`
# + a Pion native differential cross-check (`diff -u`).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-decimal}"
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

echo "=== [2/7] pionc extract-lean packages/decimal ==="
rm -rf "$PROJ/Decimal"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Decimal/$f.lean" ]; then
    echo "FAIL: missing Decimal/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/DecimalProofs"
cp -R "$SCRIPT_DIR/DecimalProofs" "$PROJ/DecimalProofs"
cp "$SCRIPT_DIR/DecimalProofs.lean" "$PROJ/DecimalProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Decimal where\n  globs := #[.submodules `Decimal]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib DecimalProofs where\n  globs := #[.andSubmodules `DecimalProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/DecimalProofs.lean" "$SCRIPT_DIR/DecimalProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Decimal DecimalProofs ==="
cd "$PROJ"
set +e
lake build PionLean Decimal DecimalProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Decimal DecimalProofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
AXIOMS_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" CheckAxioms.lean 2>&1)
echo "$AXIOMS_OUT"
if printf '%s\n' "$AXIOMS_OUT" | grep -E "sorryAx|Lean\.ofReduceBool|Lean\.trustCompiler|axiom" | grep -v -E "^'[^']+' depends on axioms:" | grep -v -E "^\s*$" >/dev/null; then
  :
fi
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

echo "=== [6/7] EvalDiff.lean (#guard + #eval) ==="
EVAL_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" EvalDiff.lean 2>&1)
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
name = "decimal_lean_diff"
version = "0.1.0"

[dependencies]
decimal = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
fn report(w : World, name : String, ok : Bool) -> Unit {
  if ok {
    io_println(w, name + ": PASS")
  } else {
    io_println(w, name + ": FAIL")
  }
}

fn dec_raw_eq(a : decimal::Decimal, b : decimal::Decimal) -> Bool {
  a.lo64 == b.lo64 && a.hi == b.hi && a.flags == b.flags
}

fn wire_bytes(f : UInt, lo : UInt, mid : UInt, hi : UInt) -> Bytes {
  let out = Bytes::new(16)
  out[0] = (f & 0xFFU).to_int().to_byte()
  out[1] = ((f >> 8) & 0xFFU).to_int().to_byte()
  out[2] = ((f >> 16) & 0xFFU).to_int().to_byte()
  out[3] = ((f >> 24) & 0xFFU).to_int().to_byte()
  out[4] = (lo & 0xFFU).to_int().to_byte()
  out[5] = ((lo >> 8) & 0xFFU).to_int().to_byte()
  out[6] = ((lo >> 16) & 0xFFU).to_int().to_byte()
  out[7] = ((lo >> 24) & 0xFFU).to_int().to_byte()
  out[8] = (mid & 0xFFU).to_int().to_byte()
  out[9] = ((mid >> 8) & 0xFFU).to_int().to_byte()
  out[10] = ((mid >> 16) & 0xFFU).to_int().to_byte()
  out[11] = ((mid >> 24) & 0xFFU).to_int().to_byte()
  out[12] = (hi & 0xFFU).to_int().to_byte()
  out[13] = ((hi >> 8) & 0xFFU).to_int().to_byte()
  out[14] = ((hi >> 16) & 0xFFU).to_int().to_byte()
  out[15] = ((hi >> 24) & 0xFFU).to_int().to_byte()
  out
}

fn serde_rt(d : decimal::Decimal) -> Bool {
  match decimal::Decimal::deserialize(d.serialize()) {
    Ok(d2) => dec_raw_eq(d2, d)
    Err(_) => false
  }
}

fn deser_is(b : Bytes, want : decimal::Decimal) -> Bool {
  match decimal::Decimal::deserialize(b) {
    Ok(d) => dec_raw_eq(d, want)
    Err(_) => false
  }
}

fn deser_err(b : Bytes) -> Bool {
  match decimal::Decimal::deserialize(b) {
    Ok(_) => false
    Err(_) => true
  }
}

pub fn main(w : World) -> Int {
  let dec_zero = decimal::Decimal::{ lo64: 0UL, hi: 0U, flags: 0U }
  let dec_neg_zero = decimal::Decimal::{ lo64: 0UL, hi: 0U, flags: 0x80000000U }
  let dec_neg_zero_s2 = decimal::Decimal::{ lo64: 0UL, hi: 0U, flags: 0x80020000U }
  let dec_one = decimal::Decimal::{ lo64: 1UL, hi: 0U, flags: 0U }
  let dec_one_s2 = decimal::Decimal::{ lo64: 100UL, hi: 0U, flags: 0x00020000U }
  let dec_one_s28 = decimal::Decimal::{ lo64: 0x3E25026110000000UL, hi: 0x204FCE5EU, flags: 0x001C0000U }
  let dec_tiny = decimal::Decimal::{ lo64: 1UL, hi: 0U, flags: 0x001C0000U }
  let dec_max = decimal::Decimal::{ lo64: 0xFFFFFFFFFFFFFFFFUL, hi: 0xFFFFFFFFU, flags: 0U }
  let dec_min = decimal::Decimal::{ lo64: 0xFFFFFFFFFFFFFFFFUL, hi: 0xFFFFFFFFU, flags: 0x80000000U }
  let dec_max_s28 = decimal::Decimal::{ lo64: 0xFFFFFFFFFFFFFFFFUL, hi: 0xFFFFFFFFU, flags: 0x001C0000U }

  let fp_err = match decimal::Decimal::from_parts(1U, 0U, 0U, false, 29U) {
    Err(decimal::DecimalError::ScaleExceedsMaximumPrecision(s)) => s == 29U
    _ => false
  }
  let bad_len = Bytes::new(3)
  bad_len[0] = (1).to_byte()
  bad_len[1] = (2).to_byte()
  bad_len[2] = (3).to_byte()

  report(w, "neg_zero_eq_pos_zero", dec_neg_zero.compare(dec_zero) == 0)
  report(w, "neg_zero_s2_eq_pos_zero", dec_neg_zero_s2.compare(dec_zero) == 0)
  report(w, "neg_involutive_max", dec_raw_eq(dec_max.neg().neg(), dec_max))
  report(w, "abs_min_eq_max", dec_raw_eq(dec_min.abs(), dec_max))
  report(w, "abs_neg_zero_nonneg", !dec_neg_zero.abs().is_sign_negative())
  report(w, "from_parts_scale29_err", fp_err)
  report(w, "compare_cross_scale_1_eq_1_00", dec_one.compare(dec_one_s2) == 0)
  report(w, "compare_cross_scale_1_eq_1_28dp", dec_one.compare(dec_one_s28) == 0)
  report(w, "compare_min_lt_max", dec_min.compare(dec_max) == -1)
  report(w, "compare_tiny_gt_zero", dec_tiny.compare(dec_zero) == 1)
  report(w, "serde_roundtrip_zero", serde_rt(dec_zero))
  report(w, "serde_roundtrip_neg_zero", serde_rt(dec_neg_zero))
  report(w, "serde_roundtrip_max", serde_rt(dec_max))
  report(w, "serde_roundtrip_min", serde_rt(dec_min))
  report(w, "serde_roundtrip_max_s28", serde_rt(dec_max_s28))
  report(w, "deser_wrong_len_err", deser_err(bad_len))
  report(w, "deser_f5_mask_0x20", deser_is(wire_bytes(0x00200000U, 12345U, 0U, 0U), decimal::Decimal::{ lo64: 12345UL, hi: 0U, flags: 0U }))
  report(w, "deser_f5_mask_0x3c", deser_is(wire_bytes(0x003C0000U, 12345U, 0U, 0U), decimal::Decimal::{ lo64: 12345UL, hi: 0U, flags: 0x001C0000U }))
  report(w, "deser_f5_scale30_carry", deser_is(wire_bytes(0x001E0000U, 15U, 0U, 0U), dec_tiny))
  report(w, "trunc_max_s28_eq_7", dec_raw_eq(dec_max_s28.trunc(), decimal::Decimal::{ lo64: 7UL, hi: 0U, flags: 0U }))
  0
}
EOF
"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/decimal Lean 4 proofs"
