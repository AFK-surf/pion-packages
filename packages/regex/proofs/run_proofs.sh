#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="regex"
LEAN_MOD="Regex"
PROOF_MOD="RegexProofs"
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
    for line in f:
        m = re.match(r"^'([^']+)' depends on axioms: \[(.*)\]$", line.strip())
        if m:
            thm, ax_str = m.group(1), m.group(2).strip()
            audited.add(thm)
            axs = {a.strip() for a in ax_str.split(",") if a.strip()}
            bad = axs - allowed
            if bad:
                sys.exit(f"FAIL: {thm} uses non-standard axioms: {sorted(bad)}")
        elif re.match(r"^'([^']+)' does not depend on any axioms$", line.strip()):
            audited.add(re.match(r"^'([^']+)'", line.strip()).group(1))

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
regex = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "regex"

fn fb(b : Bool) -> String { if b { "true" } else { "false" } }

fn flk(lk : regex::LookKind) -> String {
  match lk {
    regex::LookKind::StartText => "StartText"
    regex::LookKind::EndText => "EndText"
    regex::LookKind::StartLine => "StartLine"
    regex::LookKind::EndLine => "EndLine"
    regex::LookKind::WordBoundaryAscii => "WordBoundaryAscii"
    regex::LookKind::NotWordBoundaryAscii => "NotWordBoundaryAscii"
    regex::LookKind::WordBoundaryUnicode => "WordBoundaryUnicode"
    regex::LookKind::NotWordBoundaryUnicode => "NotWordBoundaryUnicode"
  }
}

pub fn main(world : World) -> Int {
  let r1 = regex::CharRange::{ lo: 10, hi: 30 }
  let r2 = regex::CharRange::{ lo: 20, hi: 40 }
  let r3 = regex::CharRange::{ lo: 31, hi: 50 }
  let r4 = regex::CharRange::{ lo: 32, hi: 50 }
  let rmin = regex::CharRange::{ lo: -2147483648, hi: 2147483647 }
  io_println(world, "op_add0=" + regex::onepass_mask_add_slot(0L, 0, 4).to_string())
  io_println(world, "op_add62=" + regex::onepass_mask_add_slot(0L, 62, 63).to_string())
  io_println(world, "op_oob63=" + regex::onepass_mask_add_slot(5L, 63, 64).to_string())
  io_println(world, "op_neg=" + regex::onepass_mask_add_slot(5L, -1, 4).to_string())
  io_println(world, "op_can_ok=" + fb(regex::onepass_can_compile(false, 31, 512)))
  io_println(world, "op_can_32=" + fb(regex::onepass_can_compile(false, 32, 10)))
  io_println(world, "op_can_look=" + fb(regex::onepass_can_compile(true, 4, 10)))
  io_println(world, "cap_ok=" + fb(regex::captures_slot_valid(0, 2)))
  io_println(world, "cap_edge=" + fb(regex::captures_slot_valid(1, 3)))
  io_println(world, "cap_neg=" + fb(regex::captures_slot_valid(-1, 10)))
  io_println(world, "cap_min=" + fb(regex::captures_slot_valid(0, -2147483648)))
  io_println(world, "cap_max=" + fb(regex::captures_slot_valid(1073741822, 2147483647)))
  io_println(world, "cr_le_lt=" + fb(regex::char_range_le(r1, r2)))
  io_println(world, "cr_le_gt=" + fb(regex::char_range_le(r2, r1)))
  io_println(world, "cr_le_min=" + fb(regex::char_range_le(rmin, r1)))
  let ov = regex::char_range_intersect(r1, r2)
  let mn = regex::char_range_intersect(rmin, r1)
  io_println(world, "cr_int_ov=" + ov.lo.to_string() + "," + ov.hi.to_string())
  io_println(world, "cr_int_min=" + mn.lo.to_string() + "," + mn.hi.to_string())
  io_println(world, "cr_mrg_adj=" + fb(regex::char_range_can_merge(r1, r3)))
  io_println(world, "cr_mrg_gap=" + fb(regex::char_range_can_merge(r1, r4)))
  io_println(world, "cr_mrg_max=" + fb(regex::char_range_can_merge(rmin, r1)))
  let mg = regex::char_range_merge(r1, r3)
  io_println(world, "cr_mrg_val=" + mg.lo.to_string() + "," + mg.hi.to_string())
  io_println(world, "pike_sl_nl=" + fb(regex::pike_look_holds(regex::LookKind::StartLine, 5, 10, 10, 97, true, false, true)))
  io_println(world, "pike_el_nl=" + fb(regex::pike_look_holds(regex::LookKind::EndLine, 5, 10, 97, 10, true, true, false)))
  io_println(world, "pike_wb_cb=" + fb(regex::pike_look_holds(regex::LookKind::WordBoundaryAscii, 5, 10, 97, 32, true, true, false)))
  io_println(world, "pike_wb_nocb=" + fb(regex::pike_look_holds(regex::LookKind::WordBoundaryAscii, 5, 10, 97, 32, false, true, false)))
  io_println(world, "dfa_el_nl=" + fb(regex::dfa_look_holds(regex::LookKind::EndLine, false, false, true, true, false, false)))
  io_println(world, "dfa_wb=" + fb(regex::dfa_look_holds(regex::LookKind::WordBoundaryAscii, false, false, true, false, false, false)))
  io_println(world, "rev_st=" + flk(regex::reverse_look_kind(regex::LookKind::StartText)))
  io_println(world, "rev_sl=" + flk(regex::reverse_look_kind(regex::LookKind::StartLine)))
  io_println(world, "rev_wb=" + flk(regex::reverse_look_kind(regex::LookKind::WordBoundaryAscii)))
  io_println(world, "u8_128=" + fb(regex::is_utf8_cont_byte(128)))
  io_println(world, "u8_191=" + fb(regex::is_utf8_cont_byte(191)))
  io_println(world, "u8_192=" + fb(regex::is_utf8_cont_byte(192)))
  io_println(world, "u8_neg1=" + fb(regex::is_utf8_cont_byte(-1)))
  io_println(world, "hex_0=" + regex::hex_val(48).to_string())
  io_println(world, "hex_F=" + regex::hex_val(70).to_string())
  io_println(world, "hex_f=" + regex::hex_val(102).to_string())
  io_println(world, "hex_min=" + regex::hex_val(-2147483648).to_string())
  io_println(world, "hex_max=" + regex::hex_val(2147483647).to_string())
  io_println(world, "ws_sp=" + fb(regex::is_regex_ws_byte(32)))
  io_println(world, "meta_sp=" + fb(regex::is_regex_meta_byte(32)))
  io_println(world, "meta_dot=" + fb(regex::is_regex_meta_byte(46)))
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"
diff -u "$NATIVE_OUT" "$LEAN_OUT"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (diff -u exit 0)"
echo "PASS: packages/regex Lean 4 proofs"
