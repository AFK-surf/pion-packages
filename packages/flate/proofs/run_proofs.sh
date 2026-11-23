#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/flate`.
# All Lake build artifacts stay in /private/tmp/pion-lean-flate (zero git worktree pollution).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-flate}"
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

echo "=== [2/7] pionc extract-lean packages/flate ==="
rm -rf "$PROJ/Flate"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Flate/$f.lean" ]; then
    echo "FAIL: missing Flate/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/FlateProofs"
cp -R "$SCRIPT_DIR/FlateProofs" "$PROJ/FlateProofs"
cp "$SCRIPT_DIR/FlateProofs.lean" "$PROJ/FlateProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Flate where\n  globs := #[.submodules `Flate]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib FlateProofs where\n  globs := #[.andSubmodules `FlateProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/FlateProofs.lean" "$SCRIPT_DIR/FlateProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Flate FlateProofs ==="
cd "$PROJ"
set +e
lake build PionLean Flate FlateProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Flate FlateProofs: exit 0, 0 errors"

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
name = "flate_lean_diff"
version = "0.1.0"

[dependencies]
flate = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "flate"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "level_neg1_false", !flate::is_valid_level(-1))
  report(w, "level_0_true", flate::is_valid_level(0))
  report(w, "level_9_true", flate::is_valid_level(9))
  report(w, "level_10_false", !flate::is_valid_level(10))
  report(w, "limits_default", flate::DecompressLimits::default().max_output_bytes == 268435456)
  report(w, "limits_new_1024", flate::DecompressLimits::new(1024).max_output_bytes == 1024)
  report(w, "btype_0_true", flate::is_valid_btype(0))
  report(w, "btype_2_true", flate::is_valid_btype(2))
  report(w, "btype_3_false", !flate::is_valid_btype(3))
  report(w, "nlen_0_ffff", flate::is_valid_stored_nlen(0, 65535))
  report(w, "nlen_1234_ok", flate::is_valid_stored_nlen(1234, 64301))
  report(w, "nlen_1234_bad", !flate::is_valid_stored_nlen(1234, 64300))

  report(w, "zlib_flevel_0", flate::zlib_flevel(0) == 0)
  report(w, "zlib_flevel_1", flate::zlib_flevel(1) == 0)
  report(w, "zlib_flevel_5", flate::zlib_flevel(5) == 1)
  report(w, "zlib_flevel_6", flate::zlib_flevel(6) == 2)
  report(w, "zlib_flevel_9", flate::zlib_flevel(9) == 3)
  report(w, "zlib_flg_0", flate::zlib_compute_flg(120, 0) == 1)
  report(w, "zlib_flg_1", flate::zlib_compute_flg(120, 1) == 94)
  report(w, "zlib_flg_2", flate::zlib_compute_flg(120, 2) == 156)
  report(w, "zlib_flg_3", flate::zlib_compute_flg(120, 3) == 218)
  report(w, "zlib_chk_78_9c_ok", flate::zlib_check_header(120, 156) == 0)
  report(w, "zlib_chk_fcheck_err", flate::zlib_check_header(120, 155) == 1)
  report(w, "zlib_chk_cm_err", flate::zlib_check_header(121, 24) == 2)
  report(w, "zlib_chk_cinfo_err", flate::zlib_check_header(136, 28) == 3)

  report(w, "huff_direct_65_8", flate::huff_direct_entry(65, 8) == 2088)
  report(w, "huff_subtable_1024_5", flate::huff_subtable_entry(1024, 5) == 32789)
  report(w, "bit_rev_0_0", flate::bit_reverse(0, 0) == 0)
  report(w, "bit_rev_1_3", flate::bit_reverse(1, 3) == 4)
  report(w, "bit_rev_5_4", flate::bit_reverse(5, 4) == 10)
  report(w, "bit_rev_13_8", flate::bit_reverse(13, 8) == 176)

  report(w, "adler_pack_1_0", flate::adler32_pack(1U, 0U) == 1U)
  report(w, "adler_pack_sample", flate::adler32_pack(500U, 1000U) == 65536500U)
  report(w, "crc32_poly_0", flate::crc32_byte_poly(0U) == 0U)
  report(w, "crc32_poly_1", flate::crc32_byte_poly(1U) == 1996959894U)
  report(w, "crc32_poly_128", flate::crc32_byte_poly(128U) == 3988292384U)
  report(w, "crc32_poly_255", flate::crc32_byte_poly(255U) == 755167117U)
  0
}
EOF

"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/flate Lean 4 proofs"
