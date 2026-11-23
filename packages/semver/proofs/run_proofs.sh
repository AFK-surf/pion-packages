#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/semver`.
#
# Builds a throw-away Lake project in /private/tmp/pion-lean-semver (zero git
# worktree pollution), extracts `packages/semver` via `pionc extract-lean`,
# compiles `PionLean`, `Semver`, and `SemverProofs`, rejects any
# `sorry`/`admit`/`native_decide`/`bv_decide`, verifies `#print axioms`
# (only `propext`, `Classical.choice`, `Quot.sound`), and runs `EvalDiff.lean`
# + a Pion native differential cross-check.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-semver}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-$WORK/pion-ref}"
AENEAS_REV=1dc8ad31b1
PIONC="${PIONC:-pionc}"

mkdir -p "$WORK"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas@$AENEAS_REV in $WORK ==="
if [ ! -d "$PION_REF/lean" ]; then
  if [ -d "/private/tmp/pion-lean-ref-semver/lean" ]; then
    PION_REF="/private/tmp/pion-lean-ref-semver"
  else
    git clone --depth 1 -q https://github.com/AFK-surf/pion.git "$PION_REF"
  fi
fi

if [ -z "${AENEAS_DIR:-}" ]; then
  if [ ! -d "$WORK/aeneas/.git" ]; then
    git clone -q https://github.com/AeneasVerif/aeneas.git "$WORK/aeneas"
  fi
  git -C "$WORK/aeneas" checkout -q "$AENEAS_REV"
  AENEAS_DIR="$WORK/aeneas/backends/lean"
fi

if [ ! -f "$PROJ/lakefile.lean" ] || [ ! -d "$PROJ/.lake/packages/mathlib" ]; then
  rm -rf "$PROJ"
  mkdir -p "$PROJ/.deps" "$PROJ/.lake"
  (cd "$PION_REF/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
  (cd "$PROJ" && lake exe cache get)
else
  # Refresh lakefile.lean cleanly from pion/lean so we never duplicate lean_lib blocks
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

echo "=== [2/7] pionc extract-lean packages/semver ==="
rm -rf "$PROJ/Semver"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Semver/$f.lean" ]; then
    echo "FAIL: missing Semver/$f.lean" >&2
    exit 1
  fi
done

cp "$SCRIPT_DIR/SemverProofs.lean" "$PROJ/SemverProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Semver where\n  globs := #[.submodules `Semver]\n' >> "$PROJ/lakefile.lean"
printf '\nlean_lib SemverProofs where\n' >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/SemverProofs.lean" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Semver SemverProofs ==="
cd "$PROJ"
set +e
lake build PionLean Semver SemverProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Semver SemverProofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
set +e
AXIOMS_OUT=$(lake env lean CheckAxioms.lean 2>&1)
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

echo "=== [6/7] #eval / #guard on extracted Semver.Funs ==="
set +e
EVAL_OUT=$(lake env lean EvalDiff.lean 2>&1)
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
name = "semver_lean_diff"
version = "0.1.0"

[dependencies]
semver = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "semver"

fn report(w : World, name : String, ok : Bool) -> Unit {
  if ok {
    io_println(w, name + ": PASS")
  } else {
    io_println(w, name + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  let u64_max : UInt64 = 18446744073709551615UL
  let u64_max_m1 : UInt64 = 18446744073709551614UL

  let v_max = semver::Version::new(u64_max, u64_max, u64_max)
  let v_m1 = semver::Version::new(u64_max_m1, u64_max, u64_max)
  let v_max00 = semver::Version::new(u64_max, 0UL, 0UL)
  let v_zero = semver::Version::new(0UL, 0UL, 0UL)
  let v_100 = semver::Version::new(1UL, 0UL, 0UL)

  let v_100_b1 = match semver::parse_version("1.0.0+b1") { Ok(v) => v, Err(_) => v_zero }
  let v_100_a_b2 = match semver::parse_version("1.0.0-alpha+b2") { Ok(v) => v, Err(_) => v_zero }
  let v_100_a1_b1 = match semver::parse_version("1.0.0-alpha.1+b1") { Ok(v) => v, Err(_) => v_zero }
  let v_100_a1_b2 = match semver::parse_version("1.0.0-alpha.1+b2") { Ok(v) => v, Err(_) => v_zero }

  let c_caret_max = semver::Comparator::{ op: semver::Op::Caret, major: u64_max, minor: Some(0UL), patch: Some(0UL), pre: semver::Prerelease::empty() }
  let c_tilde_max = semver::Comparator::{ op: semver::Op::Tilde, major: 0UL, minor: Some(u64_max), patch: Some(0UL), pre: semver::Prerelease::empty() }
  let c_gt_max = semver::Comparator::{ op: semver::Op::Greater, major: u64_max, minor: None, patch: None, pre: semver::Prerelease::empty() }
  let c_caret_003 = semver::Comparator::{ op: semver::Op::Caret, major: 0UL, minor: Some(0UL), patch: Some(3UL), pre: semver::Prerelease::empty() }

  report(w, "cmp_core_u64max_eq", v_max.cmp_precedence(v_max) == 0)
  report(w, "cmp_core_u64max_lt", v_m1.cmp_precedence(v_max00) == -1)
  report(w, "cmp_prec_rel_gt_pre", v_100_b1.cmp_precedence(v_100_a_b2) == 1)
  report(w, "cmp_prec_build_eq", v_100_a1_b1.cmp_precedence(v_100_a1_b2) == 0)
  report(w, "caret_u64max_no_wrap", !c_caret_max.matches(v_zero))
  report(w, "caret_u64max_self", c_caret_max.matches(v_max))
  report(w, "tilde_u64max_no_wrap", !c_tilde_max.matches(v_100))
  report(w, "greater_u64max_false", !c_gt_max.matches(v_max))
  report(w, "caret_0_0_p_exact", !c_caret_003.matches(semver::Version::new(0UL, 0UL, 4UL)))
  0
}
EOF
"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/semver Lean 4 proofs"
