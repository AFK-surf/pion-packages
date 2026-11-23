#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="time"
LEAN_MOD="Time"
PROOF_MOD="TimeProofs"
PIONC_BIN="${PIONC:-$(command -v pionc 2>/dev/null || echo "$HOME/.pion/bin/pionc")}"
LEAN_CACHE="${LEAN_CACHE:-/private/tmp/pion-lean-shared}"
PION_LEAN_REF="${PION_LEAN_REF:-/private/tmp/pion-lean-ref/lean}"
WORK_DIR="${LEAN_WORK:-/private/tmp/pion-lean-work/$PKG_NAME}"

if [ ! -d "$LEAN_CACHE/aeneas/backends/lean" ] || [ ! -d "$LEAN_CACHE/proj/.lake/packages" ]; then
  echo "ERROR: shared Aeneas/Mathlib cache not found under $LEAN_CACHE" >&2
  exit 1
fi
if [ ! -d "$PION_LEAN_REF/PionLean" ] || [ ! -f "$PION_LEAN_REF/PionLean.lean" ]; then
  echo "ERROR: PionLean reference not found at $PION_LEAN_REF/PionLean" >&2
  exit 1
fi

echo "=== [1/7] Checking forbidden proof tokens ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide|unsafe|implemented_by|opaque|extern)\b' \
    "$SCRIPT_DIR/$PROOF_MOD.lean" "$SCRIPT_DIR/$PROOF_MOD"; then
  echo "FAIL: forbidden token found in proofs" >&2
  exit 1
fi

echo "=== [2/7] Preparing isolated workspace $WORK_DIR and extracting Lean 4 model ==="
mkdir -p "$WORK_DIR/.deps" "$WORK_DIR/.lake"
ln -sfn "$LEAN_CACHE/aeneas/backends/lean" "$WORK_DIR/.deps/aeneas"
ln -sfn "$LEAN_CACHE/proj/.lake/packages" "$WORK_DIR/.lake/packages"
cp -f "$PION_LEAN_REF/lean-toolchain" "$WORK_DIR/lean-toolchain"
cp -f "$LEAN_CACHE/proj/lake-manifest.json" "$WORK_DIR/lake-manifest.json"
rm -rf "$WORK_DIR/PionLean" "$WORK_DIR/PionLean.lean"
cp -f "$PION_LEAN_REF/PionLean.lean" "$WORK_DIR/PionLean.lean"
cp -R "$PION_LEAN_REF/PionLean" "$WORK_DIR/PionLean"
rm -rf "$WORK_DIR/$LEAN_MOD" "$WORK_DIR/$LEAN_MOD.lean" "$WORK_DIR/$PROOF_MOD" "$WORK_DIR/$PROOF_MOD.lean" \
       "$WORK_DIR/CheckAxioms.lean" "$WORK_DIR/EvalDiff.lean"

"$PIONC_BIN" extract-lean "$PKG_DIR" --out "$WORK_DIR"
if [ -f "$WORK_DIR/$LEAN_MOD/FunsExternal.lean" ] && grep -qE '^\s*axiom\b' "$WORK_DIR/$LEAN_MOD/FunsExternal.lean"; then
  echo "FAIL: unexpected axiom found in generated $LEAN_MOD/FunsExternal.lean" >&2
  exit 1
fi

echo "=== [3/7] Staging $PROOF_MOD into $WORK_DIR ==="
cp "$SCRIPT_DIR/$PROOF_MOD.lean" "$WORK_DIR/"
cp -R "$SCRIPT_DIR/$PROOF_MOD" "$WORK_DIR/"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$WORK_DIR/"
cp "$SCRIPT_DIR/EvalDiff.lean" "$WORK_DIR/"

cat > "$WORK_DIR/lakefile.lean" <<EOF
import Lake
open Lake DSL

package pion_proofs where
  moreLeanArgs := #["-DwarningAsError=false"]

require aeneas from ".deps/aeneas"

lean_lib PionLean
lean_lib $LEAN_MOD
lean_lib $PROOF_MOD
EOF

echo "=== [4/7] Building $LEAN_MOD + $PROOF_MOD (0 errors, 0 warnings) ==="
BUILD_LOG="$(mktemp /tmp/${PKG_NAME}_lean_build.XXXXXX)"
AXIOM_LOG="$(mktemp /tmp/${PKG_NAME}_axioms.XXXXXX)"
LEAN_OUT="$(mktemp /tmp/${PKG_NAME}_lean_eval.XXXXXX)"
NATIVE_OUT="$(mktemp /tmp/${PKG_NAME}_native_eval.XXXXXX)"
DIFF_DIR="$(mktemp -d /tmp/${PKG_NAME}_diff.XXXXXX)"
trap 'rm -rf "$BUILD_LOG" "$AXIOM_LOG" "$LEAN_OUT" "$NATIVE_OUT" "$DIFF_DIR"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM

(cd "$WORK_DIR" && lake build "$LEAN_MOD.Types" "$LEAN_MOD.Funs" "$PROOF_MOD") 2>&1 | tee "$BUILD_LOG"
if grep -E '^warning:|^error:' "$BUILD_LOG"; then
  echo "FAIL: Lean build emitted warnings or errors" >&2
  exit 1
fi

echo "=== [5/7] Auditing 1:1 theorem coverage & strict axiom whitelist (CheckAxioms.lean) ==="
(cd "$WORK_DIR" && lake env lean CheckAxioms.lean) 2>&1 | tee "$AXIOM_LOG"
python3 - "$SCRIPT_DIR" "$PROOF_MOD" "$AXIOM_LOG" <<'PYEOF'
import os, re, sys

script_dir, proof_mod, axiom_log = sys.argv[1], sys.argv[2], sys.argv[3]
declared = set()
for root, _, files in os.walk(os.path.join(script_dir, proof_mod)):
    for fn in files:
        if not fn.endswith(".lean"):
            continue
        with open(os.path.join(root, fn)) as f:
            for line in f:
                m = re.match(r"^\s*theorem\s+([A-Za-z0-9_']+)", line)
                if m:
                    declared.add(f"{proof_mod}.{m.group(1)}")

allowed = {"propext", "Classical.choice", "Quot.sound"}
audited = set()
with open(axiom_log) as f:
    text = f.read()
for m in re.finditer(r"'([^']+)' depends on axioms: \[([^\]]*)\]", text, re.S):
    thm, ax_str = m.group(1), m.group(2)
    audited.add(thm)
    axs = {a.strip() for a in ax_str.split(",") if a.strip()}
    bad = axs - allowed
    if bad:
        sys.exit(f"FAIL: {thm} uses non-standard axioms: {sorted(bad)}")
for m in re.finditer(r"'([^']+)' does not depend on any axioms", text):
    audited.add(m.group(1))

if not declared:
    sys.exit("FAIL: no non-private theorems declared")
if declared != audited:
    missing = sorted(declared - audited)
    extra = sorted(audited - declared)
    sys.exit(f"FAIL: CheckAxioms mismatch (missing={missing}, extra={extra})")
print(f"Axiom whitelist OK: {len(audited)}/{len(declared)} theorems verified (standard axioms only)")
PYEOF

echo "=== [6/7] Running Lean differential evaluator (EvalDiff.lean) ==="
(cd "$WORK_DIR" && lake env lean EvalDiff.lean) | tee "$LEAN_OUT"

echo "=== [7/7] Native Pion vs Lean value differential cross-check (diff -u) ==="
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "${PKG_NAME}_diff"
version = "0.1.0"

[dependencies]
time = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "time"

fn fmt_date_res(r : Result[time::Date, time::TimeError]) -> String {
  match r {
    Ok(d) => "Ok(" + d.year.to_string() + "," + d.month.to_string() + "," + d.day.to_string() + ")"
    Err(_) => "Err"
  }
}

fn fmt_dur_res(r : Result[time::SignedDuration, time::TimeError]) -> String {
  match r {
    Ok(d) => "Ok(" + d.secs.to_string() + "," + d.nanos.to_string() + ")"
    Err(_) => "Err"
  }
}

pub fn main(world : World) -> Int {
  let i64_min = -9223372036854775807L - 1L
  let i64_max = 9223372036854775807L
  let dur_min = time::SignedDuration::min()
  let dur_max = time::SignedDuration::max()
  let dur_zero = time::SignedDuration::zero()
  io_println(world, "leap_1900=" + time::is_leap_year(1900).to_string())
  io_println(world, "leap_2000=" + time::is_leap_year(2000).to_string())
  io_println(world, "leap_0=" + time::is_leap_year(0).to_string())
  io_println(world, "leap_min=" + time::is_leap_year(-2147483648).to_string())
  io_println(world, "leap_max=" + time::is_leap_year(2147483647).to_string())
  io_println(world, "dim_2000_2=" + time::days_in_month_of(2000, 2).to_string())
  io_println(world, "dim_1900_2=" + time::days_in_month_of(1900, 2).to_string())
  io_println(world, "dim_2024_12=" + time::days_in_month_of(2024, 12).to_string())
  io_println(world, "ep_min=" + time::Date::{ year: -9999, month: 1, day: 1 }.to_epoch_days().to_string())
  io_println(world, "from_ep_min=" + fmt_date_res(time::Date::from_epoch_days(-4371587)))
  io_println(world, "ep_0000_0229=" + time::Date::{ year: 0, month: 2, day: 29 }.to_epoch_days().to_string())
  io_println(world, "from_ep_0000_0229=" + fmt_date_res(time::Date::from_epoch_days(-719469)))
  io_println(world, "ep_1970=" + time::Date::{ year: 1970, month: 1, day: 1 }.to_epoch_days().to_string())
  io_println(world, "from_ep_1970=" + fmt_date_res(time::Date::from_epoch_days(0)))
  io_println(world, "ep_max=" + time::Date::{ year: 9999, month: 12, day: 31 }.to_epoch_days().to_string())
  io_println(world, "from_ep_max=" + fmt_date_res(time::Date::from_epoch_days(2932896)))
  io_println(world, "from_ep_oob_lo=" + fmt_date_res(time::Date::from_epoch_days(-4371588)))
  io_println(world, "from_ep_oob_hi=" + fmt_date_res(time::Date::from_epoch_days(2932897)))
  io_println(world, "from_ep_i32min=" + fmt_date_res(time::Date::from_epoch_days(-2147483648)))
  io_println(world, "from_ep_i32max=" + fmt_date_res(time::Date::from_epoch_days(2147483647)))
  io_println(world, "dur_new_norm=" + fmt_dur_res(time::SignedDuration::new(1L, -500000000)))
  io_println(world, "dur_new_ovf=" + fmt_dur_res(time::SignedDuration::new(i64_max, 1000000000)))
  io_println(world, "dur_neg_min=" + fmt_dur_res(dur_min.checked_neg()))
  io_println(world, "dur_neg_max=" + fmt_dur_res(dur_max.checked_neg()))
  io_println(world, "dur_add_ovf=" + fmt_dur_res(dur_max.checked_add(time::SignedDuration::{ secs: 0L, nanos: 1 })))
  io_println(world, "dur_add_unf=" + fmt_dur_res(dur_min.checked_add(time::SignedDuration::{ secs: 0L, nanos: -1 })))
  io_println(world, "dur_add_minmax=" + fmt_dur_res(dur_min.checked_add(dur_max)))
  io_println(world, "dur_sub_edge=" + fmt_dur_res(time::SignedDuration::{ secs: 0L, nanos: -1 }.checked_sub(time::SignedDuration::{ secs: i64_min, nanos: 0 })))
  io_println(world, "dur_sub_ovf=" + fmt_dur_res(dur_zero.checked_sub(dur_min)))
  io_println(world, "dur_sub_self=" + fmt_dur_res(dur_min.checked_sub(dur_min)))
  io_println(world, "cmp_date=" + time::Date::{ year: -9999, month: 1, day: 1 }.cmp(time::Date::{ year: 9999, month: 12, day: 31 }).to_string())
  io_println(world, "cmp_time=" + time::Time::{ hour: 23, minute: 59, second: 59, nanosecond: 999999999 }.cmp(time::Time::{ hour: 0, minute: 0, second: 0, nanosecond: 0 }).to_string())
  io_println(world, "cmp_ts=" + time::Timestamp::{ secs: -1L, nanos: 999999999 }.cmp(time::Timestamp::{ secs: 0L, nanos: 0 }).to_string())
  io_println(world, "cmp_dur=" + dur_min.cmp(dur_max).to_string())
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"
diff -u "$NATIVE_OUT" "$LEAN_OUT"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (diff -u exit 0)"
echo "PASS: packages/time Lean 4 proofs"
