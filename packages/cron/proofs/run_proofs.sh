#!/bin/sh
# End-to-end Lean 4 formal verification runner for `packages/cron`.
#
# Steps:
#   1. Provision a Lake project in /private/tmp/pion-lean-cron/proj
#      (AFK-surf/pion `lean/` + AeneasVerif/aeneas @ 1dc8ad31b1 + cached mathlib).
#   2. Extract `packages/cron` via `pionc extract-lean --json`.
#   3. Scan `packages/cron/proofs/` to reject `sorry`, `admit`, `bv_decide`, `native_decide`.
#   4. Build `PionLean`, `Cron`, and `CronProofs` with `lake build` (0 errors).
#   5. Verify `#print axioms` in `CheckAxioms.lean` (only propext / Classical.choice / Quot.sound).
#   6. Run `EvalDiff.lean` and diff every public-API case against a native Pion binary.
#
# All build artifacts stay under /private/tmp; the git worktree is never modified.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

PROOFS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CRON_DIR=$(CDPATH= cd -- "$PROOFS_DIR/.." && pwd)
WORK="${LEAN_WORK:-/private/tmp/pion-lean-cron}"
PROJ="$WORK/proj"
AENEAS_REV="1dc8ad31b1"

echo "=== [1/6] Provision Lake project in $PROJ ==="
mkdir -p "$WORK"

# Locate or shallow-clone AFK-surf/pion for `lean/` (PionLean + lakefile + manifest).
PION_REF="${PION_REF_DIR:-/private/tmp/pion-lean-ref}"
if [ ! -d "$PION_REF/lean/PionLean" ]; then
  PION_REF="$WORK/pion-ref"
  if [ ! -d "$PION_REF/lean/PionLean" ]; then
    git clone --depth 1 -q https://github.com/AFK-surf/pion.git "$PION_REF"
  fi
fi

# Locate or clone Aeneas @ 1dc8ad31b1.
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

mkdir -p "$PROJ/.deps" "$PROJ/.lake"
if [ ! -f "$PROJ/lakefile.lean" ] || [ ! -d "$PROJ/.lake/packages/mathlib" ]; then
  (cd "$PION_REF/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
  if [ -n "${LEAN_PACKAGES_SEED:-}" ]; then
    cp -Rc "$LEAN_PACKAGES_SEED" "$PROJ/.lake/packages" 2>/dev/null || cp -R "$LEAN_PACKAGES_SEED" "$PROJ/.lake/packages"
  else
    (cd "$PROJ" && lake exe cache get)
  fi
else
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

printf '\nlean_lib Cron where\n  globs := #[.submodules `Cron]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib CronProofs where\n  globs := #[.andSubmodules `CronProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [2/6] pionc extract-lean packages/cron ==="
rm -rf "$PROJ/Cron"
EXTRACT_JSON=$(pionc extract-lean --json --out "$PROJ" "$CRON_DIR")
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Cron/$f.lean" ]; then
    echo "FAIL: missing Cron/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/CronProofs"
cp -R "$PROOFS_DIR/CronProofs" "$PROJ/CronProofs"
cp "$PROOFS_DIR/CronProofs.lean" "$PROJ/CronProofs.lean"
cp "$PROOFS_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$PROOFS_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

echo "=== [3/6] Static scan for forbidden proof tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$PROOFS_DIR/CronProofs.lean" "$PROOFS_DIR/CronProofs" "$PROOFS_DIR/CheckAxioms.lean" "$PROOFS_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: forbidden token (sorry/admit/bv_decide/native_decide) found in proofs" >&2
  exit 1
fi
echo "static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/6] lake build PionLean Cron CronProofs ==="
cd "$PROJ"
set +e
lake build PionLean Cron CronProofs > "$WORK/build.log" 2>&1
RC=$?
set -e
grep -v '^✔\|^trace\|^info' "$WORK/build.log" | tail -80 || true
if [ "$RC" -ne 0 ] || grep -q '^error:' "$WORK/build.log"; then
  echo "FAIL: lake build failed (rc=$RC)" >&2
  exit 1
fi
if grep -q "declaration uses .sorry" "$WORK/build.log"; then
  echo "FAIL: declaration uses sorry" >&2
  exit 1
fi
echo "lake build PionLean Cron CronProofs: exit 0, 0 errors"

echo "=== [5/6] Axiom audit (#print axioms) ==="
set +e
AXIOMS_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" CheckAxioms.lean 2>&1)
RC=$?
set -e
printf '%s\n' "$AXIOMS_OUT"
if [ "$RC" -ne 0 ]; then
  echo "FAIL: CheckAxioms.lean failed (rc=$RC)" >&2
  exit 1
fi
EXPECTED_THMS=$(grep -c '^#print axioms' "$PROJ/CheckAxioms.lean")
printf '%s\n' "$AXIOMS_OUT" | python3 -c '
import re, sys
text = sys.stdin.read()
expected = int(sys.argv[1])
allowed = {"propext", "Classical.choice", "Quot.sound"}
found = re.findall(r"^\x27([^\x27]+)\x27 depends on axioms: \[([^\]]*)\]", text, re.M)
free = re.findall(r"^\x27([^\x27]+)\x27 does not depend on any axioms", text, re.M)
bad = [(n, sorted(set(a.replace(",", " ").split()) - allowed)) for n, a in found
       if set(a.replace(",", " ").split()) - allowed]
if bad or len(found) + len(free) != expected:
    print("FAIL: axioms: non-standard=%r, checked %d of %d" % (bad, len(found) + len(free), expected), file=sys.stderr)
    sys.exit(1)
print("axioms: %d/%d theorems verified (only propext / Classical.choice / Quot.sound)" % (expected, expected))
' "$EXPECTED_THMS"

echo "=== [6/6] EvalDiff: Lean #eval vs native Pion differential ==="
set +e
lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" EvalDiff.lean > "$WORK/lean_eval.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  cat "$WORK/lean_eval.out" >&2
  echo "FAIL: EvalDiff.lean failed (rc=$RC)" >&2
  exit 1
fi

# Build a throw-away native Pion runner in $WORK/native_diff for all public API cases.
NATIVE_DIR="$WORK/native_diff"
rm -rf "$NATIVE_DIR"
mkdir -p "$NATIVE_DIR/src"
cat > "$NATIVE_DIR/pion.toml" <<EOF
[package]
name = "cron_eval_diff"
version = "0.1.0"

[dependencies]
cron = { path = "$CRON_DIR" }
EOF

cat > "$NATIVE_DIR/src/main.pion" <<'EOF'
import "cron"

fn fmt_bool(b : Bool) -> String {
  if b { "true" } else { "false" }
}

fn fmt_dt_res(r : Result[cron::DateTime, cron::CronError]) -> String {
  match r {
    Ok(dt) =>
      "Ok(" + dt.year.to_string() + "," + dt.month.to_string() + "," + dt.day.to_string() + "," +
      dt.hour.to_string() + "," + dt.minute.to_string() + "," + dt.second.to_string() + ")"
    Err(_) => "Err"
  }
}

fn mk_dt(y : Int, mo : Int, d : Int, h : Int, mi : Int, s : Int) -> cron::DateTime {
  cron::DateTime::{ year: y, month: mo, day: d, hour: h, minute: mi, second: s }
}

pub fn main(world : World) -> Int {
  let c = match cron::Cron::parse("0 30 12 15 6 *") {
    Ok(v) => v
    Err(_) => return 1
  }
  io_println(world, "leap_1900=" + fmt_bool(cron::is_leap_year(1900)))
  io_println(world, "leap_2000=" + fmt_bool(cron::is_leap_year(2000)))
  io_println(world, "leap_2024=" + fmt_bool(cron::is_leap_year(2024)))
  io_println(world, "leap_2025=" + fmt_bool(cron::is_leap_year(2025)))
  io_println(world, "leap_2100=" + fmt_bool(cron::is_leap_year(2100)))
  io_println(world, "leap_2400=" + fmt_bool(cron::is_leap_year(2400)))
  io_println(world, "dim_2024_2=" + cron::days_in_month(2024, 2).to_string())
  io_println(world, "dim_2100_2=" + cron::days_in_month(2100, 2).to_string())
  io_println(world, "dim_2000_2=" + cron::days_in_month(2000, 2).to_string())
  io_println(world, "dim_2025_4=" + cron::days_in_month(2025, 4).to_string())
  io_println(world, "dim_2025_7=" + cron::days_in_month(2025, 7).to_string())
  io_println(world, "dim_2025_8=" + cron::days_in_month(2025, 8).to_string())
  io_println(world, "dow_1970_01_01=" + cron::weekday_of(1970, 1, 1).to_string())
  io_println(world, "dow_2000_01_01=" + cron::weekday_of(2000, 1, 1).to_string())
  io_println(world, "dow_0001_01_01=" + cron::weekday_of(1, 1, 1).to_string())
  io_println(world, "from_unix_0=" + fmt_dt_res(cron::DateTime::from_unix_secs(0L)))
  io_println(world, "from_unix_neg1=" + fmt_dt_res(cron::DateTime::from_unix_secs(-1L)))
  io_println(world, "from_unix_min=" + fmt_dt_res(cron::DateTime::from_unix_secs(-62135596800L)))
  io_println(world, "from_unix_max=" + fmt_dt_res(cron::DateTime::from_unix_secs(253402300799L)))
  io_println(world, "from_unix_under=" + fmt_dt_res(cron::DateTime::from_unix_secs(-62135596801L)))
  io_println(world, "from_unix_over=" + fmt_dt_res(cron::DateTime::from_unix_secs(253402300800L)))
  io_println(world, "from_unix_f3_alias=" + fmt_dt_res(cron::DateTime::from_unix_secs(4294967296L * 86400L)))
  io_println(world, "to_unix_epoch=" + mk_dt(1970, 1, 1, 0, 0, 0).to_unix_secs().to_string())
  io_println(world, "to_unix_min=" + mk_dt(1, 1, 1, 0, 0, 0).to_unix_secs().to_string())
  io_println(world, "to_unix_max=" + mk_dt(9999, 12, 31, 23, 59, 59).to_unix_secs().to_string())
  io_println(world, "to_unix_leap=" + mk_dt(2024, 2, 29, 12, 34, 56).to_unix_secs().to_string())
  io_println(world, "valid_ok=" + fmt_bool(mk_dt(2024, 2, 29, 23, 59, 59).is_valid()))
  io_println(world, "valid_bad_feb=" + fmt_bool(mk_dt(2100, 2, 29, 0, 0, 0).is_valid()))
  io_println(world, "valid_bad_f5=" + fmt_bool(mk_dt(2025, 6, 15, 12, 30, 64).is_valid()))
  io_println(world, "match_fixed_ok=" + fmt_bool(c.matches(mk_dt(2025, 6, 15, 12, 30, 0))))
  io_println(world, "match_fixed_f5=" + fmt_bool(c.matches(mk_dt(2025, 6, 15, 12, 30, 64))))
  io_println(world, "match_day_ok=" + fmt_bool(c.matches(mk_dt(2025, 6, 15, 12, 30, 0))))
  io_println(world, "match_day_f5=" + fmt_bool(c.matches(mk_dt(2025, 6, 15, 12, 30, 64))))
  0
}
EOF

pionc build --release -o "$NATIVE_DIR/runner" "$NATIVE_DIR"
"$NATIVE_DIR/runner" > "$WORK/native_eval.out"

# Filter Lean output to the matching public-API keys and verify exact byte parity.
grep -E '^(leap_|dim_|dow_|from_unix_|to_unix_|valid_|match_)' "$WORK/lean_eval.out" > "$WORK/lean_public.out"
if ! diff -u "$WORK/native_eval.out" "$WORK/lean_public.out"; then
  echo "FAIL: native Pion and Lean #eval outputs disagree" >&2
  exit 1
fi
PUBLIC_CASES=$(wc -l < "$WORK/native_eval.out" | tr -d ' ')
TOTAL_CASES=$(wc -l < "$WORK/lean_eval.out" | tr -d ' ')
echo "EvalDiff: $TOTAL_CASES Lean #eval cases ($PUBLIC_CASES native-vs-Lean diff -u matched 100%)"
echo "PASS: packages/cron Lean 4 formal verification"
