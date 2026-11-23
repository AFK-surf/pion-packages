#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="http1"
LEAN_MOD="Http1"
PROOF_MOD="Http1Proofs"
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
http1 = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "http1"

fn fmt_framing(f : http1::Framing) -> String {
  match f {
    http1::Framing::None => "None"
    http1::Framing::ContentLength(n) => "CL(" + n.to_string() + ")"
    http1::Framing::Chunked => "Chunked"
  }
}

pub fn main(world : World) -> Int {
  let i64_min = -9223372036854775807L - 1L
  io_println(world, "tchar_A=" + http1::is_tchar_byte(65).to_string())
  io_println(world, "tchar_sp=" + http1::is_tchar_byte(32).to_string())
  io_println(world, "tchar_cr=" + http1::is_tchar_byte(13).to_string())
  io_println(world, "tchar_min=" + http1::is_tchar_byte(-2147483648).to_string())
  io_println(world, "tchar_max=" + http1::is_tchar_byte(2147483647).to_string())
  io_println(world, "hdrval_htab=" + http1::is_header_val_byte(9).to_string())
  io_println(world, "hdrval_obstext=" + http1::is_header_val_byte(200).to_string())
  io_println(world, "hdrval_cr=" + http1::is_header_val_byte(13).to_string())
  io_println(world, "hdrval_nul=" + http1::is_header_val_byte(0).to_string())
  io_println(world, "hdrval_neg1=" + http1::is_header_val_byte(-1).to_string())
  io_println(world, "hex_0=" + http1::hex_digit_value(48).to_string())
  io_println(world, "hex_F=" + http1::hex_digit_value(70).to_string())
  io_println(world, "hex_f=" + http1::hex_digit_value(102).to_string())
  io_println(world, "hex_min=" + http1::hex_digit_value(-2147483648).to_string())
  io_println(world, "hex_max=" + http1::hex_digit_value(2147483647).to_string())
  io_println(world, "lower_Z=" + http1::ascii_lower_byte(90).to_string())
  io_println(world, "lower_min=" + http1::ascii_lower_byte(-2147483648).to_string())
  io_println(world, "eff_204=" + fmt_framing(http1::effective_response_framing(204, http1::Framing::ContentLength(99L))))
  io_println(world, "eff_200=" + fmt_framing(http1::effective_response_framing(200, http1::Framing::ContentLength(99L))))
  io_println(world, "eff_min=" + fmt_framing(http1::effective_response_framing(-2147483648, http1::Framing::Chunked)))
  io_println(world, "te_after_ch=" + http1::te_coding_step(1, true, false).to_string())
  io_println(world, "te_gz_ch=" + http1::te_coding_step(0, true, false).to_string())
  io_println(world, "status_200=" + http1::parse_status_digits(50, 48, 48).to_string())
  io_println(world, "status_bad=" + http1::parse_status_digits(50, 65, 48).to_string())
  io_println(world, "status_min=" + http1::parse_status_digits(-2147483648, 48, 48).to_string())
  io_println(world, "u63_ok=" + http1::u63_decimal_step(123L, 52).to_string())
  io_println(world, "u63_max_ok=" + http1::u63_decimal_step(922337203685477580L, 55).to_string())
  io_println(world, "u63_max_ovf=" + http1::u63_decimal_step(922337203685477580L, 56).to_string())
  io_println(world, "u63_min_acc=" + http1::u63_decimal_step(i64_min, 48).to_string())
  io_println(world, "chunk_ok=" + http1::chunk_size_hex_step(16L, 2, 10).to_string())
  io_println(world, "chunk_16dig=" + http1::chunk_size_hex_step(0L, 16, 1).to_string())
  io_println(world, "chunk_ovf=" + http1::chunk_size_hex_step(576460752303423488L, 15, 0).to_string())
  io_println(world, "chunk_max=" + http1::chunk_size_hex_step(9223372036854775807L, 1, 1).to_string())
  io_println(world, "cl_after_te=" + http1::check_framing_cl(true, false, 5L).to_string())
  io_println(world, "cl_neg_min=" + http1::check_framing_cl(false, false, i64_min).to_string())
  io_println(world, "te_after_cl=" + http1::check_framing_te(true, http1::Version::Http11, 1).to_string())
  io_println(world, "te_http10=" + http1::check_framing_te(false, http1::Version::Http10, 1).to_string())
  io_println(world, "host_dup=" + http1::check_framing_host(1, true).to_string())
  io_println(world, "fin_no_host=" + http1::check_framing_finalize(false, false, 0, 0, true, http1::Version::Http11).to_string())
  io_println(world, "fin_chunked=" + http1::check_framing_finalize(false, true, 1, 1, true, http1::Version::Http11).to_string())
  io_println(world, "fin_cl=" + http1::check_framing_finalize(true, false, 0, 1, true, http1::Version::Http11).to_string())
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"
diff -u "$NATIVE_OUT" "$LEAN_OUT"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (diff -u exit 0)"
echo "PASS: packages/http1 Lean 4 proofs"
