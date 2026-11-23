#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/cbor`.
#
# Builds a throw-away Lake project in /private/tmp/pion-lean-cbor (zero git
# worktree pollution), extracts `packages/cbor` via `pionc extract-lean`,
# compiles `PionLean`, `Cbor`, and `CborProofs`, rejects any
# `sorry`/`admit`/`native_decide`/`bv_decide`, verifies `#print axioms`
# (only `propext`, `Classical.choice`, `Quot.sound`), and runs `EvalDiff.lean`
# + a Pion native differential cross-check (`diff -u`).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-cbor}"
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

echo "=== [2/7] pionc extract-lean packages/cbor ==="
rm -rf "$PROJ/Cbor"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Cbor/$f.lean" ]; then
    echo "FAIL: missing Cbor/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/CborProofs"
cp -R "$SCRIPT_DIR/CborProofs" "$PROJ/CborProofs"
cp "$SCRIPT_DIR/CborProofs.lean" "$PROJ/CborProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Cbor where\n  globs := #[.submodules `Cbor]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib CborProofs where\n  globs := #[.andSubmodules `CborProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/CborProofs.lean" "$SCRIPT_DIR/CborProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Cbor CborProofs ==="
cd "$PROJ"
set +e
lake build PionLean Cbor CborProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Cbor CborProofs: exit 0, 0 errors"

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
name = "cbor_lean_diff"
version = "0.1.0"

[dependencies]
cbor = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "cbor"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

fn opt_i32_eq(o : Option[Int], want : Int) -> Bool {
  match o {
    Some(v) => v == want
    None => false
  }
}

fn opt_i64_eq(o : Option[Int64], want : Int64) -> Bool {
  match o {
    Some(v) => v == want
    None => false
  }
}

pub fn main(w : World) -> Int {
  report(w, "head_u64_0", cbor::head_size_u64(0UL) == 1)
  report(w, "head_u64_23", cbor::head_size_u64(23UL) == 1)
  report(w, "head_u64_24", cbor::head_size_u64(24UL) == 2)
  report(w, "head_u64_255", cbor::head_size_u64(255UL) == 2)
  report(w, "head_u64_256", cbor::head_size_u64(256UL) == 3)
  report(w, "head_u64_65535", cbor::head_size_u64(65535UL) == 3)
  report(w, "head_u64_65536", cbor::head_size_u64(65536UL) == 5)
  report(w, "head_u64_u32max", cbor::head_size_u64(4294967295UL) == 5)
  report(w, "head_u64_u32max_p1", cbor::head_size_u64(4294967296UL) == 9)
  report(w, "head_int_23", cbor::head_size_int(23) == 1)
  report(w, "head_int_24", cbor::head_size_int(24) == 2)
  report(w, "head_int_65536", cbor::head_size_int(65536) == 5)
  report(w, "canon_ai24_23_false", cbor::is_canonical_arg(24, 23UL) == false)
  report(w, "canon_ai24_24_true", cbor::is_canonical_arg(24, 24UL) == true)
  report(w, "canon_ai25_255_false", cbor::is_canonical_arg(25, 255UL) == false)
  report(w, "canon_ai25_256_true", cbor::is_canonical_arg(25, 256UL) == true)
  report(w, "canon_ai26_65535_false", cbor::is_canonical_arg(26, 65535UL) == false)
  report(w, "canon_ai26_65536_true", cbor::is_canonical_arg(26, 65536UL) == true)
  report(w, "canon_ai27_u32max_false", cbor::is_canonical_arg(27, 4294967295UL) == false)
  report(w, "canon_ai27_u32max_p1_true", cbor::is_canonical_arg(27, 4294967296UL) == true)
  report(w, "canon_ai28_false", cbor::is_canonical_arg(28, 0UL) == false)
  report(w, "days_2000_02", cbor::days_in_month(2000, 2) == 29)
  report(w, "days_2100_02", cbor::days_in_month(2100, 2) == 28)
  report(w, "f16_pos_zero_rt", opt_i32_eq(cbor::double_bits_to_float16_exact(cbor::float16_to_double_bits(0)), 0))
  report(w, "f16_neg_zero_rt", opt_i32_eq(cbor::double_bits_to_float16_exact(cbor::float16_to_double_bits(32768)), 32768))
  report(w, "f16_1_0_rt", opt_i32_eq(cbor::double_bits_to_float16_exact(cbor::float16_to_double_bits(15360)), 15360))
  report(w, "f16_1_5_rt", opt_i32_eq(cbor::double_bits_to_float16_exact(cbor::float16_to_double_bits(15872)), 15872))
  report(w, "f16_min_subnormal_rt", opt_i32_eq(cbor::double_bits_to_float16_exact(cbor::float16_to_double_bits(1)), 1))
  report(w, "f16_max_normal_rt", opt_i32_eq(cbor::double_bits_to_float16_exact(cbor::float16_to_double_bits(31743)), 31743))
  report(w, "f16_pos_inf_rt", opt_i32_eq(cbor::double_bits_to_float16_exact(cbor::float16_to_double_bits(31744)), 31744))
  report(w, "f16_neg_inf_rt", opt_i32_eq(cbor::double_bits_to_float16_exact(cbor::float16_to_double_bits(64512)), 64512))
  report(w, "f16_nan_canon", opt_i32_eq(cbor::double_bits_to_float16_exact(cbor::float16_to_double_bits(32257)), 32256))
  report(w, "f32_pos_zero_rt", opt_i64_eq(cbor::double_bits_to_float32_exact(cbor::float32_to_double_bits(0L)), 0L))
  report(w, "f32_neg_zero_rt", opt_i64_eq(cbor::double_bits_to_float32_exact(cbor::float32_to_double_bits(2147483648L)), 2147483648L))
  report(w, "f32_100000_rt", opt_i64_eq(cbor::double_bits_to_float32_exact(cbor::float32_to_double_bits(1203982336L)), 1203982336L))
  report(w, "f32_pos_inf_rt", opt_i64_eq(cbor::double_bits_to_float32_exact(cbor::float32_to_double_bits(2139095040L)), 2139095040L))
  0
}
EOF
"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/cbor Lean 4 proofs"
