#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="crdt"
LEAN_MOD="Crdt"
PROOF_MOD="CrdtProofs"
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
crdt = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "crdt"

fn fmt_id(x : crdt::Id) -> String {
  "(" + x.client.to_string() + "," + x.clock.to_string() + ")"
}

fn fmt_di(x : crdt::DeleteItem) -> String {
  "(" + x.clock.to_string() + "," + x.len.to_string() + ")"
}

pub fn main(world : World) -> Int {
  let u64_max = 18446744073709551615UL
  let u64_max_m2 = 18446744073709551614UL
  let u64_max_m5 = 18446744073709551610UL
  io_println(world, "sat_0_0=" + crdt::u64_sat_add(0UL, 0UL).to_string())
  io_println(world, "sat_max_0=" + crdt::u64_sat_add(u64_max, 0UL).to_string())
  io_println(world, "sat_max_1=" + crdt::u64_sat_add(u64_max, 1UL).to_string())
  io_println(world, "sat_max_max=" + crdt::u64_sat_add(u64_max, u64_max).to_string())
  io_println(world, "sat_m2_4=" + crdt::u64_sat_add(u64_max_m2, 4UL).to_string())
  io_println(world, "last_len0=" + fmt_id(crdt::item_last_id(crdt::Id::new(7UL, 10UL), 0UL)))
  io_println(world, "last_len1=" + fmt_id(crdt::item_last_id(crdt::Id::new(7UL, 10UL), 1UL)))
  io_println(world, "last_wrap=" + fmt_id(crdt::item_last_id(crdt::Id::new(7UL, u64_max_m2), 10UL)))
  io_println(world, "cnt_empty=" + crdt::delete_item_contains(crdt::DeleteItem::{ clock: 10UL, len: 0UL }, 10UL).to_string())
  io_println(world, "cnt_wrap_in=" + crdt::delete_item_contains(crdt::DeleteItem::{ clock: u64_max_m2, len: 4UL }, u64_max).to_string())
  io_println(world, "cnt_wrap_below=" + crdt::delete_item_contains(crdt::DeleteItem::{ clock: u64_max_m2, len: 4UL }, 0UL).to_string())
  io_println(world, "cnt_wrap_c12=" + crdt::delete_item_contains(crdt::DeleteItem::{ clock: 12UL, len: u64_max_m5 }, u64_max).to_string())
  io_println(world, "canm_wrap_t=" + crdt::delete_item_can_merge(crdt::DeleteItem::{ clock: u64_max_m5, len: 10UL }, crdt::DeleteItem::{ clock: u64_max, len: 5UL }).to_string())
  io_println(world, "canm_wrap_f=" + crdt::delete_item_can_merge(crdt::DeleteItem::{ clock: u64_max_m2, len: 4UL }, crdt::DeleteItem::{ clock: 1UL, len: 2UL }).to_string())
  io_println(world, "merge_wrap=" + fmt_di(crdt::delete_item_merge(crdt::DeleteItem::{ clock: u64_max_m5, len: 10UL }, crdt::DeleteItem::{ clock: u64_max, len: 5UL })))
  io_println(world, "merge_unsorted=" + fmt_di(crdt::delete_item_merge(crdt::DeleteItem::{ clock: 20UL, len: 5UL }, crdt::DeleteItem::{ clock: 10UL, len: 12UL })))
  io_println(world, "merge_max_span=" + fmt_di(crdt::delete_item_merge(crdt::DeleteItem::{ clock: 10UL, len: 5UL }, crdt::DeleteItem::{ clock: 12UL, len: u64_max_m5 })))
  io_println(world, "opt_eq_nn=" + crdt::opt_id_eq(None, None).to_string())
  io_println(world, "opt_eq_ss=" + crdt::opt_id_eq(Some(crdt::Id::new(1UL, 2UL)), Some(crdt::Id::new(1UL, 2UL))).to_string())
  io_println(world, "opt_eq_sn=" + crdt::opt_id_eq(Some(crdt::Id::new(1UL, 2UL)), None).to_string())
  io_println(world, "info_enc=" + crdt::encode_item_info(7, true, false, true).to_string())
  io_println(world, "info_ref=" + crdt::info_ref_id(167).to_string())
  io_println(world, "hex_c15=" + crdt::hex_nibble_char(15).to_string())
  io_println(world, "hex_pF=" + crdt::parse_hex_nibble(70).to_string())
  io_println(world, "hex_pmin=" + crdt::parse_hex_nibble(-2147483648).to_string())
  io_println(world, "hex_pmax=" + crdt::parse_hex_nibble(2147483647).to_string())
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"
diff -u "$NATIVE_OUT" "$LEAN_OUT"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (diff -u exit 0)"
echo "PASS: packages/crdt Lean 4 proofs"
