#!/bin/sh
set -eu

export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$PATH"
PROOFS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$PROOFS_DIR/.." && pwd)
WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-$WORK/pion-ref}"
AENEAS_REV=1dc8ad31b1
JOBS="${LEAN_NUM_THREADS:-2}"
MEM="${LEAN_MEM_LIMIT:-8192}"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas@$AENEAS_REV in $WORK ==="
mkdir -p "$WORK" "$PROJ/IcalProofs"
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
  mkdir -p "$PROJ/.deps" "$PROJ/.lake" "$PROJ/IcalProofs"
  (cd "$PION_REF/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
  (cd "$PROJ" && lake exe cache get)
else
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

echo "=== [2/7] pionc extract-lean packages/ical ==="
pionc extract-lean "$PKG_DIR" --out "$PROJ" --json

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|bv_decide|native_decide)\b|^axiom\b' "$PROOFS_DIR/IcalProofs.lean" "$PROOFS_DIR/IcalProofs/"; then
  echo "FAIL: forbidden tactic or axiom found" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

cp "$PROOFS_DIR/IcalProofs.lean" "$PROJ/IcalProofs.lean"
cp "$PROOFS_DIR/IcalProofs/"*.lean "$PROJ/IcalProofs/"
cp "$PROOFS_DIR/CheckAxioms.lean" "$PROJ/CheckAxiomsIcal.lean"
cp "$PROOFS_DIR/EvalDiff.lean" "$PROJ/EvalDiffIcal.lean"

printf '\nlean_lib Ical where\n  globs := #[.submodules `Ical]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$MEM" "$JOBS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib IcalProofs where\n  globs := #[.andSubmodules `IcalProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$MEM" "$JOBS" >> "$PROJ/lakefile.lean"

echo "=== [4/7] lake build PionLean Ical IcalProofs ==="
BUILD_LOG="$WORK/ical_build.log"
(cd "$PROJ" && LEAN_NUM_THREADS="$JOBS" lake build PionLean Ical IcalProofs) > "$BUILD_LOG" 2>&1 || {
  cat "$BUILD_LOG"
  echo "FAIL: lake build failed" >&2
  exit 1
}
cat "$BUILD_LOG"
if grep -qE '^warning:|warning: ' "$BUILD_LOG"; then
  echo "FAIL: warnings found in IcalProofs build" >&2
  exit 1
fi
echo "lake build PionLean Ical IcalProofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
AX_OUT=$(cd "$PROJ" && lake env lean --memory="$MEM" -j "$JOBS" CheckAxiomsIcal.lean)
echo "$AX_OUT"
if echo "$AX_OUT" | grep -vE "^'IcalProofs\.[a-zA-Z0-9_]+' depends on axioms: \[(propext(, Classical\.choice)?(, Quot\.sound)?|Classical\.choice(, Quot\.sound)?|Quot\.sound)\]$" | grep -vE "^'IcalProofs\.[a-zA-Z0-9_]+' does not depend on any axioms$" | grep -q .; then
  echo "FAIL: unexpected axiom detected" >&2
  exit 1
fi
echo "Axioms audit: ONLY standard axioms (propext, Classical.choice, Quot.sound)"

echo "=== [6/7] EvalDiff.lean (#eval) ==="
LEAN_DIFF="$WORK/ical_lean_diff.txt"
(cd "$PROJ" && lake env lean --memory="$MEM" -j "$JOBS" EvalDiffIcal.lean) > "$LEAN_DIFF"
cat "$LEAN_DIFF"
if grep -q 'FAIL' "$LEAN_DIFF"; then
  echo "FAIL: Lean EvalDiff reported FAIL" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_DIR="$WORK/ical_native_diff"
rm -rf "$DIFF_DIR" && mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "ical_diff"
version = "0.1.0"
edition = "2026"

[dependencies]
ical = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "ical"

fn report(w : World, label : String, ok : Bool) -> Unit {
  if ok {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "wd_epoch", ical::epoch_day_weekday_mon0(0) == 3)
  report(w, "wd_neg1", ical::epoch_day_weekday_mon0(-1) == 2)
  report(w, "wd_neg4", ical::epoch_day_weekday_mon0(-4) == 6)
  report(w, "wd_p7", ical::epoch_day_weekday_mon0(7) == 3)
  report(w, "doy_jan1", ical::doy_of(19723, 19723) == 1)
  report(w, "doy_dec31", ical::doy_of(20088, 19723) == 366)
  report(w, "neg_ord_last", ical::neg_ordinal_day(31, 31) == -1)
  report(w, "neg_ord_first", ical::neg_ordinal_day(1, 31) == -31)
  report(w, "fdiv_0", ical::floor_div_86400(0L) == 0)
  report(w, "fdiv_pos", ical::floor_div_86400(86400L) == 1)
  report(w, "fdiv_neg1", ical::floor_div_86400(-1L) == -1)
  report(w, "fdiv_neg86400", ical::floor_div_86400(-86400L) == -1)
  report(w, "fdiv_neg86401", ical::floor_div_86400(-86401L) == -2)
  report(w, "w1_2024_mo", ical::week1_start_of(19723, 0) == 19723)
  report(w, "w1_2023_mo", ical::week1_start_of(19358, 0) == 19359)
  report(w, "w1_2020_mo", ical::week1_start_of(18262, 0) == 18260)
  report(w, "jump_past", ical::jump_grid_to(100L, 50L, 60L) == 160L)
  report(w, "jump_exact", ical::jump_grid_to(100L, 220L, 60L) == 220L)
  report(w, "jump_ceil", ical::jump_grid_to(100L, 221L, 60L) == 280L)
  report(w, "up_a", ical::ascii_upper_byte(97) == 65)
  report(w, "up_z", ical::ascii_upper_byte(122) == 90)
  report(w, "up_A", ical::ascii_upper_byte(65) == 65)
  report(w, "name_A", ical::is_ical_name_byte(65))
  report(w, "name_dash", ical::is_ical_name_byte(45))
  report(w, "name_colon", !ical::is_ical_name_byte(58))
  report(w, "name_lf", !ical::is_ical_name_byte(10))
  report(w, "leap_60", ical::clamp_leap_second(60) == 59)
  report(w, "leap_59", ical::clamp_leap_second(59) == 59)
  report(w, "pw_MO", ical::parse_weekday_2_bytes(77, 79) == 0)
  report(w, "pw_su", ical::parse_weekday_2_bytes(115, 117) == 6)
  report(w, "pw_bad", ical::parse_weekday_2_bytes(88, 88) == -1)
  0
}
EOF
NATIVE_DIFF="$WORK/ical_native_diff.txt"
pionc build "$DIFF_DIR" -o "$DIFF_DIR/ical_diff_bin"
"$DIFF_DIR/ical_diff_bin" > "$NATIVE_DIFF"
diff -u "$NATIVE_DIFF" "$LEAN_DIFF"
COUNT=$(wc -l < "$LEAN_DIFF" | tr -d ' ')
echo "Native vs Lean differential: $COUNT cases identical (diff -u exit 0)"
echo "PASS: packages/ical Lean 4 proofs"
