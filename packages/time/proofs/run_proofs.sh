#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/time`.
#
# Builds a throw-away Lake project in /private/tmp/pion-lean-time (zero git
# worktree pollution), extracts `packages/time` via `pionc extract-lean`,
# compiles `PionLean`, `Time`, and `TimeProofs`, rejects any
# `sorry`/`admit`/`native_decide`/`bv_decide`, verifies `#print axioms`
# (only `propext`, `Classical.choice`, `Quot.sound`), and runs `EvalDiff.lean`
# + a Pion native differential cross-check.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

# Clean up any child lake/lean processes on exit/signal (never pkill -f)
CHILD_PIDS=""
cleanup() {
  for p in $CHILD_PIDS; do
    kill -TERM "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

WORK="${LEAN_WORK:-/private/tmp/pion-lean-time}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-$WORK/pion-ref}"
AENEAS_REV=1dc8ad31b1
PIONC="${PIONC:-pionc}"

mkdir -p "$WORK"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas@$AENEAS_REV in $WORK ==="
if [ ! -d "$PION_REF/lean" ]; then
  if [ -d "/private/tmp/pion-lean-ref/lean" ]; then
    PION_REF="/private/tmp/pion-lean-ref"
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

echo "=== [2/7] pionc extract-lean packages/time ==="
rm -rf "$PROJ/Time"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Time/$f.lean" ]; then
    echo "FAIL: missing Time/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/TimeProofs"
cp -R "$SCRIPT_DIR/TimeProofs" "$PROJ/TimeProofs"
cp "$SCRIPT_DIR/TimeProofs.lean" "$PROJ/TimeProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Time where\n  globs := #[.submodules `Time]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib TimeProofs where\n  globs := #[.andSubmodules `TimeProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/TimeProofs.lean" "$SCRIPT_DIR/TimeProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Time TimeProofs ==="
cd "$PROJ"
set +e
lake build PionLean Time TimeProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Time TimeProofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
set +e
AXIOMS_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" CheckAxioms.lean 2>&1)
RC=$?
set -e
printf '%s\n' "$AXIOMS_OUT"
if [ "$RC" -ne 0 ]; then
  echo "FAIL: CheckAxioms.lean (rc=$RC)" >&2
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
print("axioms: %d theorems verified, only propext / Classical.choice / Quot.sound" % expected)
' "$EXPECTED_THMS"

echo "=== [6/7] #eval / #guard on extracted Time.Funs ==="
set +e
EVAL_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" EvalDiff.lean 2>&1)
RC=$?
set -e
printf '%s\n' "$EVAL_OUT"
if [ "$RC" -ne 0 ] || printf '%s' "$EVAL_OUT" | grep -q 'error\|FAIL'; then
  echo "FAIL: EvalDiff.lean (rc=$RC)" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential check ==="
DIFF_DIR="$WORK/native_diff"
rm -rf "$DIFF_DIR"
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "time_lean_diff"
version = "0.1.0"

[dependencies]
time = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "time"

fn report(w : World, name : String, ok : Bool) -> Unit {
  if ok {
    io_println(w, name + ": PASS")
  } else {
    io_println(w, name + ": FAIL")
  }
}

fn is_date_ok(r : Result[time::Date, time::TimeError], y : Int, m : Int, d : Int) -> Bool {
  match r {
    Ok(dt) => dt.year == y && dt.month == m && dt.day == d
    Err(_) => false
  }
}

fn is_date_err(r : Result[time::Date, time::TimeError]) -> Bool {
  match r {
    Ok(_) => false
    Err(_) => true
  }
}

fn is_dur_ok(r : Result[time::SignedDuration, time::TimeError], s : Int64, n : Int) -> Bool {
  match r {
    Ok(dur) => dur.secs == s && dur.nanos == n
    Err(_) => false
  }
}

fn is_dur_err(r : Result[time::SignedDuration, time::TimeError]) -> Bool {
  match r {
    Ok(_) => false
    Err(_) => true
  }
}

pub fn main(w : World) -> Int {
  let i64_min : Int64 = -9223372036854775807L - 1L
  let i64_max : Int64 = 9223372036854775807L
  let dur_min = time::SignedDuration::min()
  let dur_max = time::SignedDuration::max()
  let dur_zero = time::SignedDuration::zero()

  report(w, "leap_1900_false", !time::is_leap_year(1900))
  report(w, "leap_2000_true", time::is_leap_year(2000))
  report(w, "leap_0000_true", time::is_leap_year(0))
  report(w, "leap_neg100_false", !time::is_leap_year(-100))
  report(w, "leap_neg400_true", time::is_leap_year(-400))
  report(w, "dim_2000_02", time::days_in_month_of(2000, 2) == 29)
  report(w, "dim_1900_02", time::days_in_month_of(1900, 2) == 28)

  report(w, "epoch_min_date", time::Date::{ year: -9999, month: 1, day: 1 }.to_epoch_days() == -4371587)
  report(w, "from_epoch_min_date", is_date_ok(time::Date::from_epoch_days(-4371587), -9999, 1, 1))
  report(w, "epoch_0000_02_29", time::Date::{ year: 0, month: 2, day: 29 }.to_epoch_days() == -719469)
  report(w, "from_epoch_0000_02_29", is_date_ok(time::Date::from_epoch_days(-719469), 0, 2, 29))
  report(w, "epoch_1970_01_01", time::Date::{ year: 1970, month: 1, day: 1 }.to_epoch_days() == 0)
  report(w, "from_epoch_1970_01_01", is_date_ok(time::Date::from_epoch_days(0), 1970, 1, 1))
  report(w, "epoch_2000_02_29", time::Date::{ year: 2000, month: 2, day: 29 }.to_epoch_days() == 11016)
  report(w, "from_epoch_2000_02_29", is_date_ok(time::Date::from_epoch_days(11016), 2000, 2, 29))
  report(w, "epoch_max_date", time::Date::{ year: 9999, month: 12, day: 31 }.to_epoch_days() == 2932896)
  report(w, "from_epoch_max_date", is_date_ok(time::Date::from_epoch_days(2932896), 9999, 12, 31))
  report(w, "from_epoch_underflow_err", is_date_err(time::Date::from_epoch_days(-4371588)))
  report(w, "from_epoch_overflow_err", is_date_err(time::Date::from_epoch_days(2932897)))

  report(w, "dur_neg_min_err", is_dur_err(dur_min.checked_neg()))
  report(w, "dur_neg_max_ok", is_dur_ok(dur_max.checked_neg(), -9223372036854775807L, -999999999))
  report(w, "dur_add_max_overflow", is_dur_err(dur_max.checked_add(time::SignedDuration::{ secs: 0L, nanos: 1 })))
  report(w, "dur_add_min_underflow", is_dur_err(dur_min.checked_add(time::SignedDuration::{ secs: 0L, nanos: -1 })))
  report(w, "dur_add_min_max", is_dur_ok(dur_min.checked_add(dur_max), -1L, 0))
  report(w, "dur_sub_zero_neg1_i64min", is_dur_ok(time::SignedDuration::{ secs: 0L, nanos: -1 }.checked_sub(time::SignedDuration::{ secs: i64_min, nanos: 0 }), i64_max, 999999999))
  report(w, "dur_sub_zero_min_err", is_dur_err(dur_zero.checked_sub(dur_min)))
  report(w, "dur_sub_min_min_zero", is_dur_ok(dur_min.checked_sub(dur_min), 0L, 0))

  report(w, "cmp_date_min_max", time::Date::min().cmp(time::Date::max()) == -1)
  report(w, "cmp_time_max_min", time::Time::max().cmp(time::Time::min()) == 1)
  report(w, "cmp_ts_neg1_zero", time::Timestamp::{ secs: -1L, nanos: 999999999 }.cmp(time::Timestamp::unix_epoch()) == -1)
  report(w, "cmp_dur_min_max", dur_min.cmp(dur_max) == -1)
  0
}
EOF
"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/time Lean 4 proofs"
