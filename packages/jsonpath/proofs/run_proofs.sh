#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="jsonpath"
LEAN_MOD="Jsonpath"
PROOF_MOD="JsonpathProofs"
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
SCAN_PATHS=("$SCRIPT_DIR/$PROOF_MOD.lean")
if [ -d "$SCRIPT_DIR/$PROOF_MOD" ]; then
  SCAN_PATHS+=("$SCRIPT_DIR/$PROOF_MOD")
fi
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide|unsafe|implemented_by|opaque|extern)\b' "${SCAN_PATHS[@]}"; then
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
if [ -d "$SCRIPT_DIR/$PROOF_MOD" ]; then
  cp -R "$SCRIPT_DIR/$PROOF_MOD" "$WORK_DIR/"
fi
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
scan_files = [os.path.join(script_dir, f"{proof_mod}.lean")]
mod_dir = os.path.join(script_dir, proof_mod)
if os.path.isdir(mod_dir):
    for root, _, files in os.walk(mod_dir):
        for fn in files:
            if fn.endswith(".lean"):
                scan_files.append(os.path.join(root, fn))
for path in scan_files:
    if os.path.isfile(path):
        with open(path) as f:
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
jsonpath = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "jsonpath"
fn bstr(b : Bool) -> String { if b { "true" } else { "false" } }
pub fn main(world : World) -> Int {
  io_println(world, "ws_sp=" + bstr(jsonpath::is_rfc9535_ws(32)))
  io_println(world, "ws_tab=" + bstr(jsonpath::is_rfc9535_ws(9)))
  io_println(world, "ws_lf=" + bstr(jsonpath::is_rfc9535_ws(10)))
  io_println(world, "ws_cr=" + bstr(jsonpath::is_rfc9535_ws(13)))
  io_println(world, "ws_vt=" + bstr(jsonpath::is_rfc9535_ws(11)))
  io_println(world, "nf_A=" + bstr(jsonpath::is_name_first(65)))
  io_println(world, "nf_us=" + bstr(jsonpath::is_name_first(95)))
  io_println(world, "nf_utf8=" + bstr(jsonpath::is_name_first(0x4E2D)))
  io_println(world, "nf_surr=" + bstr(jsonpath::is_name_first(0xD800)))
  io_println(world, "nf_hi=" + bstr(jsonpath::is_name_first(0x110000)))
  io_println(world, "nf_0=" + bstr(jsonpath::is_name_first(48)))
  io_println(world, "nc_0=" + bstr(jsonpath::is_name_char(48)))
  io_println(world, "ij_ok=" + bstr(jsonpath::rfc9535_ijson_step_overflow(900719925474099L, 1L)))
  io_println(world, "ij_ovf=" + bstr(jsonpath::rfc9535_ijson_step_overflow(900719925474099L, 2L)))
  io_println(world, "ij_0=" + bstr(jsonpath::rfc9535_ijson_step_overflow(0L, 9L)))
  io_println(world, "ij_big=" + bstr(jsonpath::rfc9535_ijson_step_overflow(900719925474100L, 0L)))
  io_println(world, "ni_pos=" + jsonpath::rfc9535_normalize_index(3L, 10L).to_string())
  io_println(world, "ni_neg=" + jsonpath::rfc9535_normalize_index(-2L, 10L).to_string())
  io_println(world, "ni_under=" + jsonpath::rfc9535_normalize_index(-15L, 10L).to_string())
  io_println(world, "ni_zero=" + jsonpath::rfc9535_normalize_index(0L, 5L).to_string())
  io_println(world, "ds_pos=" + jsonpath::rfc9535_default_slice_start(10L, 1L).to_string())
  io_println(world, "ds_neg=" + jsonpath::rfc9535_default_slice_start(10L, -1L).to_string())
  io_println(world, "de_pos=" + jsonpath::rfc9535_default_slice_end(10L, 1L).to_string())
  io_println(world, "de_neg=" + jsonpath::rfc9535_default_slice_end(10L, -1L).to_string())
  io_println(world, "cp_lo=" + jsonpath::rfc9535_clamp_pos_slice(-5L, 10L).to_string())
  io_println(world, "cp_mid=" + jsonpath::rfc9535_clamp_pos_slice(4L, 10L).to_string())
  io_println(world, "cp_hi=" + jsonpath::rfc9535_clamp_pos_slice(20L, 10L).to_string())
  io_println(world, "cp_emp=" + jsonpath::rfc9535_clamp_pos_slice(5L, 0L).to_string())
  io_println(world, "cn_lo=" + jsonpath::rfc9535_clamp_neg_slice(-5L, 10L).to_string())
  io_println(world, "cn_mid=" + jsonpath::rfc9535_clamp_neg_slice(4L, 10L).to_string())
  io_println(world, "cn_hi=" + jsonpath::rfc9535_clamp_neg_slice(20L, 10L).to_string())
  io_println(world, "cn_emp=" + jsonpath::rfc9535_clamp_neg_slice(5L, 0L).to_string())
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"
diff -u "$NATIVE_OUT" "$LEAN_OUT"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (diff -u exit 0)"
echo "PASS: packages/$PKG_NAME Lean 4 proofs"
