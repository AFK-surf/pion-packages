#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="graph"
LEAN_MOD="Graph"
PROOF_MOD="GraphProofs"
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
                m = re.match(r"^\s*theorem\s+([A-Za-z0-9_.']+)", line)
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
graph = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "graph"

fn bstr(b : Bool) -> String { if b { "true" } else { "false" } }

fn opt_i64(o : Option[Int64]) -> String {
  match o {
    None => "None"
    Some(v) => "Some(" + v.to_string() + ")"
  }
}

pub fn main(world : World) -> Int {
  let i64_min : Int64 = -9223372036854775807L - 1L
  io_println(world, "cadd_10_20=" + opt_i64(graph::checked_add_i64(10L, 20L)))
  io_println(world, "cadd_max_0=" + opt_i64(graph::checked_add_i64(9223372036854775807L, 0L)))
  io_println(world, "cadd_max_1=" + opt_i64(graph::checked_add_i64(9223372036854775807L, 1L)))
  io_println(world, "cadd_min_m1=" + opt_i64(graph::checked_add_i64(i64_min, -1L)))
  io_println(world, "cadd_max_nmax=" + opt_i64(graph::checked_add_i64(9223372036854775807L, -9223372036854775807L)))
  io_println(world, "fits_0_max=" + bstr(graph::fits_i64(0L, 9223372036854775807UL)))
  io_println(world, "fits_0_sb=" + bstr(graph::fits_i64(0L, 9223372036854775808UL)))
  io_println(world, "fits_m1_sb=" + bstr(graph::fits_i64(-1L, 9223372036854775808UL)))
  io_println(world, "fits_m1_hm=" + bstr(graph::fits_i64(-1L, 9223372036854775807UL)))
  io_println(world, "fits_1_0=" + bstr(graph::fits_i64(1L, 0UL)))
  io_println(world, "sign_hi_pos=" + graph::i64_sign_hi(42L).to_string())
  io_println(world, "sign_hi_neg=" + graph::i64_sign_hi(-42L).to_string())
  io_println(world, "carry_0=" + graph::i128_add_carry(100UL, 200UL).to_string())
  io_println(world, "carry_1=" + graph::i128_add_carry(18446744073709551615UL, 1UL).to_string())
  io_println(world, "i128_lt_hi=" + bstr(graph::i128_lt(-1L, 100UL, 0L, 0UL)))
  io_println(world, "i128_lt_lo=" + bstr(graph::i128_lt(0L, 5UL, 0L, 6UL)))
  io_println(world, "i128_lt_eq=" + bstr(graph::i128_lt(0L, 5UL, 0L, 5UL)))
  io_println(world, "radix_min=" + graph::i64_to_radix_key(i64_min).to_string())
  io_println(world, "radix_0=" + graph::i64_to_radix_key(0L).to_string())
  io_println(world, "radix_max=" + graph::i64_to_radix_key(9223372036854775807L).to_string())
  io_println(world, "fwd_5=" + graph::forward_half_edge(5).to_string())
  io_println(world, "twin_10=" + graph::residual_twin(10).to_string())
  io_println(world, "twin_11=" + graph::residual_twin(11).to_string())
  io_println(world, "hp_1=" + graph::heap_parent(1).to_string())
  io_println(world, "hp_2=" + graph::heap_parent(2).to_string())
  io_println(world, "hp_7=" + graph::heap_parent(7).to_string())
  io_println(world, "hl_0=" + graph::heap_left_child(0).to_string())
  io_println(world, "hl_3=" + graph::heap_left_child(3).to_string())
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"
diff -u "$NATIVE_OUT" "$LEAN_OUT"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (diff -u exit 0)"
echo "PASS: packages/$PKG_NAME Lean 4 proofs"
