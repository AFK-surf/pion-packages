#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/zip`.
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

echo "=== [2/7] pionc extract-lean packages/zip ==="
rm -rf "$PROJ/Zip"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Zip/$f.lean" ]; then
    echo "FAIL: missing Zip/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/ZipProofs"
cp -R "$SCRIPT_DIR/ZipProofs" "$PROJ/ZipProofs"
cp "$SCRIPT_DIR/ZipProofs.lean" "$PROJ/ZipProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Zip where\n  globs := #[.submodules `Zip]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib ZipProofs where\n  globs := #[.andSubmodules `ZipProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/ZipProofs.lean" "$SCRIPT_DIR/ZipProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Zip ZipProofs ==="
cd "$PROJ"
set +e
lake build PionLean Zip ZipProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Zip ZipProofs: exit 0, 0 errors"

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
name = "zip_lean_diff"
version = "0.1.0"

[dependencies]
zip = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "zip"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "range_ok", zip::in_range64(10L, 20L, 30L))
  report(w, "range_over", !zip::in_range64(10L, 21L, 30L))
  report(w, "range_neg", !zip::in_range64(-1L, 5L, 30L))
  report(w, "range_max_wrap", !zip::in_range64(9223372036854775807L, 1L, 100L))
  report(w, "upper_a", zip::ascii_upper(97) == 65)
  report(w, "upper_z", zip::ascii_upper(122) == 90)
  report(w, "upper_A", zip::ascii_upper(65) == 65)
  report(w, "sep_slash", zip::is_zip_path_sep(47))
  report(w, "sep_bslash", zip::is_zip_path_sep(92))
  report(w, "sep_dot", !zip::is_zip_path_sep(46))
  report(w, "forb_nul", zip::is_zip_forbidden_byte(0))
  report(w, "forb_colon", zip::is_zip_forbidden_byte(58))
  report(w, "forb_del", zip::is_zip_forbidden_byte(127))
  report(w, "forb_a", !zip::is_zip_forbidden_byte(97))
  report(w, "tail_dot", zip::is_zip_forbidden_seg_tail(46))
  report(w, "tail_sp", zip::is_zip_forbidden_seg_tail(32))
  report(w, "tail_a", !zip::is_zip_forbidden_seg_tail(97))
  report(w, "win3_con", zip::is_win_reserved_3(99, 111, 110))
  report(w, "win3_nul", zip::is_win_reserved_3(78, 85, 76))
  report(w, "win3_foo", !zip::is_win_reserved_3(102, 111, 111))
  report(w, "win4_com1", zip::is_win_reserved_4(99, 111, 109, 49))
  report(w, "win4_lpt9", zip::is_win_reserved_4(76, 80, 84, 57))
  report(w, "win4_com0", !zip::is_win_reserved_4(67, 79, 77, 48))

  report(w, "clamp_lo", zip::clamp_int(-5, 1, 12) == 1)
  report(w, "clamp_hi", zip::clamp_int(99, 1, 12) == 12)
  report(w, "clamp_mid", zip::clamp_int(7, 1, 12) == 7)
  report(w, "dim_2000_2", zip::days_in_month(2000, 2) == 29)
  report(w, "dim_2100_2", zip::days_in_month(2100, 2) == 28)
  report(w, "dim_2024_4", zip::days_in_month(2024, 4) == 30)
  report(w, "dos_def_y", zip::DosDateTime::default().year == 1980)
  report(w, "dos_new_lo", zip::DosDateTime::new(1970, 5, 5, 1, 1, 1).year == 1980)
  report(w, "dos_new_hi", zip::DosDateTime::new(2200, 5, 5, 1, 1, 1).year == 2107)
  let dt_e = zip::DosDateTime::new(2024, 2, 30, 12, 34, 57)
  report(w, "dos_new_even", dt_e.day == 29 && dt_e.second == 56)
  let dt_in = zip::DosDateTime::{ year: 2024, month: 2, day: 29, hour: 23, minute: 59, second: 58 }
  let (dd, dtm) = dt_in.to_dos()
  let dt2 = zip::DosDateTime::from_dos(dd, dtm)
  report(w, "dos_rt_2024", dt2.year == 2024 && dt2.month == 2 && dt2.day == 29 && dt2.hour == 23 && dt2.minute == 59 && dt2.second == 58)
  let dt_m = zip::DosDateTime::from_dos(65535U, 65535U)
  report(w, "dos_from_max", dt_m.year == 2107 && dt_m.month == 12 && dt_m.day == 31 && dt_m.hour == 23 && dt_m.minute == 59 && dt_m.second == 58)
  0
}
EOF

"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/zip Lean 4 proofs"
