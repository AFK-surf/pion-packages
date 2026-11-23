#!/bin/sh
set -eu

export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$PATH"
PROOFS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$PROOFS_DIR/.." && pwd)
REPO_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-$WORK/pion-ref}"
AENEAS_REV=1dc8ad31b1
JOBS="${LEAN_NUM_THREADS:-2}"
MEM="${LEAN_MEM_LIMIT:-8192}"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas@$AENEAS_REV in $WORK ==="
mkdir -p "$WORK" "$PROJ/CelProofs"
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
  mkdir -p "$PROJ/.deps" "$PROJ/.lake" "$PROJ/CelProofs"
  (cd "$PION_REF/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
  (cd "$PROJ" && lake exe cache get)
else
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

echo "=== [2/7] pionc extract-lean packages/cel ==="
pionc extract-lean "$PKG_DIR" --out "$PROJ" --json

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|bv_decide|native_decide)\b|^axiom\b' "$PROOFS_DIR/CelProofs.lean" "$PROOFS_DIR/CelProofs/"; then
  echo "FAIL: forbidden tactic or axiom found" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

cp "$PROOFS_DIR/CelProofs.lean" "$PROJ/CelProofs.lean"
cp "$PROOFS_DIR/CelProofs/"*.lean "$PROJ/CelProofs/"
cp "$PROOFS_DIR/CheckAxioms.lean" "$PROJ/CheckAxiomsCel.lean"
cp "$PROOFS_DIR/EvalDiff.lean" "$PROJ/EvalDiffCel.lean"

printf '\nlean_lib Cel where\n  globs := #[.submodules `Cel]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$MEM" "$JOBS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib CelProofs where\n  globs := #[.andSubmodules `CelProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$MEM" "$JOBS" >> "$PROJ/lakefile.lean"

echo "=== [4/7] lake build PionLean Cel CelProofs ==="
BUILD_LOG="$WORK/cel_build.log"
(cd "$PROJ" && LEAN_NUM_THREADS="$JOBS" lake build PionLean Cel CelProofs) > "$BUILD_LOG" 2>&1 || {
  cat "$BUILD_LOG"
  echo "FAIL: lake build failed" >&2
  exit 1
}
cat "$BUILD_LOG"
if grep -qE '^warning:|warning: ' "$BUILD_LOG"; then
  echo "FAIL: warnings found in CelProofs build" >&2
  exit 1
fi
echo "lake build PionLean Cel CelProofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
AX_OUT=$(cd "$PROJ" && lake env lean --memory="$MEM" -j "$JOBS" CheckAxiomsCel.lean)
echo "$AX_OUT"
if echo "$AX_OUT" | grep -vE "^'CelProofs\.[a-zA-Z0-9_]+' depends on axioms: \[(propext(, Classical\.choice)?(, Quot\.sound)?|Classical\.choice(, Quot\.sound)?|Quot\.sound)\]$" | grep -q .; then
  echo "FAIL: unexpected axiom detected" >&2
  exit 1
fi
echo "Axioms audit: ONLY standard axioms (propext, Classical.choice, Quot.sound)"

echo "=== [6/7] EvalDiff.lean (#eval) ==="
LEAN_DIFF="$WORK/cel_lean_diff.txt"
(cd "$PROJ" && lake env lean --memory="$MEM" -j "$JOBS" EvalDiffCel.lean) > "$LEAN_DIFF"
cat "$LEAN_DIFF"
if grep -q 'FAIL' "$LEAN_DIFF"; then
  echo "FAIL: Lean EvalDiff reported FAIL" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_DIR="$WORK/cel_native_diff"
rm -rf "$DIFF_DIR" && mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "cel_diff"
version = "0.1.0"
edition = "2026"

[dependencies]
cel = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "cel"

fn b(world : World, name : String, got : Bool, exp : Bool) -> Unit {
  if got == exp {
    io_println(world, name + ": PASS")
  } else {
    io_println(world, name + ": FAIL")
  }
}

fn i(world : World, name : String, got : Int, exp : Int) -> Unit {
  if got == exp {
    io_println(world, name + ": PASS")
  } else {
    io_println(world, name + ": FAIL")
  }
}

fn u(world : World, name : String, got : UInt64, exp : UInt64) -> Unit {
  if got == exp {
    io_println(world, name + ": PASS")
  } else {
    io_println(world, name + ": FAIL")
  }
}

pub fn main(world : World) -> Int {
  let i64_min : Int64 = -9223372036854775807L - 1L
  b(world, "neg_min", cel::i64_neg_overflows(i64_min), true)
  b(world, "neg_max", cel::i64_neg_overflows(9223372036854775807L), false)
  b(world, "add_i64_ovf", cel::i64_add_overflows(9223372036854775807L, 1L), true)
  b(world, "add_i64_udf", cel::i64_add_overflows(i64_min, -1L), true)
  b(world, "add_i64_ok", cel::i64_add_overflows(100L, -50L), false)
  b(world, "sub_i64_ovf", cel::i64_sub_overflows(9223372036854775807L, -1L), true)
  b(world, "sub_i64_udf", cel::i64_sub_overflows(i64_min, 1L), true)
  b(world, "sub_i64_ok", cel::i64_sub_overflows(50L, 100L), false)
  i(world, "div_zero", cel::i64_div_err_code(42L, 0L), 1)
  i(world, "div_min_m1", cel::i64_div_err_code(i64_min, -1L), 2)
  i(world, "div_ok", cel::i64_div_err_code(-42L, 7L), 0)
  b(world, "add_u64_ovf", cel::u64_add_overflows(18446744073709551615UL, 1UL), true)
  b(world, "add_u64_ok", cel::u64_add_overflows(100UL, 200UL), false)
  b(world, "sub_u64_udf", cel::u64_sub_underflows(5UL, 6UL), true)
  b(world, "sub_u64_ok", cel::u64_sub_underflows(6UL, 6UL), false)
  b(world, "mul_u64_ovf", cel::u64_mul_overflows(4294967296UL, 4294967296UL), true)
  b(world, "mul_u64_ok", cel::u64_mul_overflows(4294967295UL, 4294967295UL), false)
  b(world, "mul_u64_zero", cel::u64_mul_overflows(0UL, 18446744073709551615UL), false)
  i(world, "cmp_neg_0", cel::cmp_i64_u64(-1L, 0UL), -1)
  i(world, "cmp_eq_42", cel::cmp_i64_u64(42L, 42UL), 0)
  i(world, "cmp_gt", cel::cmp_i64_u64(100L, 99UL), 1)
  i(world, "cmp_max_hi", cel::cmp_i64_u64(9223372036854775807L, 9223372036854775808UL), -1)
  u(world, "int_u64_42", cel::int_to_u64(42), 42UL)
  b(world, "teq_list", cel::cel_type_eq(cel::CelType::List(cel::CelType::Int), cel::CelType::List(cel::CelType::Int)), true)
  b(world, "teq_diff", cel::cel_type_eq(cel::CelType::List(cel::CelType::Int), cel::CelType::List(cel::CelType::UInt)), false)
  b(world, "asgn_dyn", cel::is_assignable(cel::CelType::Map(cel::CelType::String, cel::CelType::Dyn), cel::CelType::Map(cel::CelType::String, cel::CelType::Int)), true)
  b(world, "asgn_no", cel::is_assignable(cel::CelType::Map(cel::CelType::String, cel::CelType::Int), cel::CelType::Map(cel::CelType::String, cel::CelType::UInt)), false)
  b(world, "mkey_str", cel::is_valid_map_key_type(cel::CelType::String), true)
  b(world, "mkey_dbl", cel::is_valid_map_key_type(cel::CelType::Double), false)
  b(world, "num_u", cel::is_numeric_type(cel::CelType::UInt), true)
  b(world, "num_b", cel::is_numeric_type(cel::CelType::Bool), false)
  b(world, "bool_dyn", cel::is_bool_compat(cel::CelType::Dyn), true)
  b(world, "id_start_u", cel::is_ident_start(95), true)
  b(world, "id_start_0", cel::is_ident_start(48), false)
  b(world, "id_cont_0", cel::is_ident_cont(48), true)
  b(world, "dig_9", cel::is_digit(57), true)
  i(world, "hex_0", cel::hex_val(48), 0)
  i(world, "hex_A", cel::hex_val(65), 10)
  i(world, "hex_f", cel::hex_val(102), 15)
  i(world, "hex_bad", cel::hex_val(103), -1)
  0
}
EOF
NATIVE_DIFF="$WORK/cel_native_diff.txt"
pionc build "$DIFF_DIR" -o "$DIFF_DIR/cel_diff_bin"
"$DIFF_DIR/cel_diff_bin" > "$NATIVE_DIFF"
diff -u "$NATIVE_DIFF" "$LEAN_DIFF"
COUNT=$(wc -l < "$LEAN_DIFF" | tr -d ' ')
echo "Native vs Lean differential: $COUNT cases identical (diff -u exit 0)"
echo "PASS: packages/cel Lean 4 proofs"
