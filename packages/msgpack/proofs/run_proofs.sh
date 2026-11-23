#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/msgpack`.
# All Lake build artifacts stay in /private/tmp/pion-lean-msgpack (zero git worktree pollution).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-msgpack}"
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

echo "=== [2/7] pionc extract-lean packages/msgpack ==="
rm -rf "$PROJ/Msgpack"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Msgpack/$f.lean" ]; then
    echo "FAIL: missing Msgpack/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/MsgpackProofs"
cp -R "$SCRIPT_DIR/MsgpackProofs" "$PROJ/MsgpackProofs"
cp "$SCRIPT_DIR/MsgpackProofs.lean" "$PROJ/MsgpackProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Msgpack where\n  globs := #[.submodules `Msgpack]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib MsgpackProofs where\n  globs := #[.andSubmodules `MsgpackProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/MsgpackProofs.lean" "$SCRIPT_DIR/MsgpackProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Msgpack MsgpackProofs ==="
cd "$PROJ"
set +e
lake build PionLean Msgpack MsgpackProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Msgpack MsgpackProofs: exit 0, 0 errors"

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
name = "msgpack_lean_diff"
version = "0.1.0"

[dependencies]
msgpack = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "msgpack"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

fn opt_i64_eq(a : Option[Int64], expected : Int64) -> Bool {
  match a {
    Some(v) => v == expected
    None => false
  }
}

pub fn main(w : World) -> Int {
  report(w, "dec_default_depth", msgpack::DecodeOptions::default().max_depth == 512)
  report(w, "dec_strict_canon", msgpack::DecodeOptions::strict().require_canonical == true)
  report(w, "enc_default_compact", msgpack::EncodeOptions::default().compact_floats == false)
  report(w, "enc_compact_true", msgpack::EncodeOptions::compact().compact_floats == true)
  report(w, "ext_tag_m128", msgpack::is_valid_ext_tag(-128))
  report(w, "ext_tag_m1", msgpack::is_valid_ext_tag(-1))
  report(w, "ext_tag_127", msgpack::is_valid_ext_tag(127))
  report(w, "ext_tag_128_false", !msgpack::is_valid_ext_tag(128))
  report(w, "ext_tag_m129_false", !msgpack::is_valid_ext_tag(-129))

  report(w, "uint_sz_0", msgpack::uint_encoded_size(0UL) == 1L)
  report(w, "uint_sz_127", msgpack::uint_encoded_size(127UL) == 1L)
  report(w, "uint_sz_128", msgpack::uint_encoded_size(128UL) == 2L)
  report(w, "uint_sz_255", msgpack::uint_encoded_size(255UL) == 2L)
  report(w, "uint_sz_256", msgpack::uint_encoded_size(256UL) == 3L)
  report(w, "uint_sz_65536", msgpack::uint_encoded_size(65536UL) == 5L)
  report(w, "uint_sz_u32max_p1", msgpack::uint_encoded_size(4294967296UL) == 9L)
  report(w, "int_sz_m1", msgpack::int_encoded_size(-1L) == 1L)
  report(w, "int_sz_m32", msgpack::int_encoded_size(-32L) == 1L)
  report(w, "int_sz_m33", msgpack::int_encoded_size(-33L) == 2L)
  report(w, "int_sz_m129", msgpack::int_encoded_size(-129L) == 3L)
  report(w, "int_sz_m32769", msgpack::int_encoded_size(-32769L) == 5L)
  report(w, "int_sz_m2147483649", msgpack::int_encoded_size(-2147483649L) == 9L)

  report(w, "str_sz_31", msgpack::str_encoded_size(31) == 32L)
  report(w, "str_sz_32", msgpack::str_encoded_size(32) == 34L)
  report(w, "bin_sz_255", msgpack::bin_encoded_size(255) == 257L)
  report(w, "bin_sz_256", msgpack::bin_encoded_size(256) == 259L)
  report(w, "cont_head_15", msgpack::container_head_size(15) == 1L)
  report(w, "cont_head_16", msgpack::container_head_size(16) == 3L)
  report(w, "cont_head_65536", msgpack::container_head_size(65536) == 5L)
  report(w, "ext_sz_fix4", msgpack::ext_encoded_size(4) == 6L)
  report(w, "ext_sz_fix16", msgpack::ext_encoded_size(16) == 18L)
  report(w, "ext_sz_3", msgpack::ext_encoded_size(3) == 6L)
  report(w, "ts_sz_32", msgpack::timestamp_encoded_size(1000L, 0) == 6L)
  report(w, "ts_sz_64", msgpack::timestamp_encoded_size(1000L, 500) == 10L)
  report(w, "ts_sz_96_neg", msgpack::timestamp_encoded_size(-1L, 0) == 15L)

  report(w, "f32_pos_zero_rt", opt_i64_eq(msgpack::double_bits_to_float32_exact(msgpack::float32_to_double_bits(0L)), 0L))
  report(w, "f32_neg_zero_rt", opt_i64_eq(msgpack::double_bits_to_float32_exact(msgpack::float32_to_double_bits(2147483648L)), 2147483648L))
  report(w, "f32_1_0_rt", opt_i64_eq(msgpack::double_bits_to_float32_exact(msgpack::float32_to_double_bits(1065353216L)), 1065353216L))
  report(w, "f32_pos_inf_rt", opt_i64_eq(msgpack::double_bits_to_float32_exact(msgpack::float32_to_double_bits(2139095040L)), 2139095040L))
  report(w, "f32_qnan_rt", opt_i64_eq(msgpack::double_bits_to_float32_exact(msgpack::float32_to_double_bits(2143289344L)), 2143289344L))
  report(w, "f32_snan_rt", opt_i64_eq(msgpack::double_bits_to_float32_exact(msgpack::float32_to_double_bits(2139095041L)), 2139095041L))
  0
}
EOF

"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/msgpack Lean 4 proofs"
