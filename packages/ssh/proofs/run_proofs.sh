#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="ssh"
LEAN_MOD="Ssh"
PROOF_MOD="SshProofs"
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
ssh = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "ssh"
fn opt_ct(o : Option[ssh::CertType]) -> String {
  match o {
    None => "None"
    Some(ssh::CertType::User) => "Some(User)"
    Some(ssh::CertType::Host) => "Some(Host)"
  }
}
pub fn main(world : World) -> Int {
  io_println(world, "pad_0_8=" + ssh::ssh_packet_padding_len(0, 8, 4).to_string())
  io_println(world, "pad_3_8=" + ssh::ssh_packet_padding_len(3, 8, 4).to_string())
  io_println(world, "pad_7_16=" + ssh::ssh_packet_padding_len(7, 16, 4).to_string())
  io_println(world, "pad_8_16=" + ssh::ssh_packet_padding_len(8, 16, 4).to_string())
  io_println(world, "hdr_ok=" + ssh::ssh_packet_header_err_code(16, 12U, 4, 35000).to_string())
  io_println(world, "hdr_over=" + ssh::ssh_packet_header_err_code(40000, 35001U, 4, 35000).to_string())
  io_println(world, "hdr_small=" + ssh::ssh_packet_header_err_code(16, 4U, 4, 35000).to_string())
  io_println(world, "hdr_eof=" + ssh::ssh_packet_header_err_code(15, 12U, 4, 35000).to_string())
  io_println(world, "hdr_align=" + ssh::ssh_packet_header_err_code(20, 13U, 4, 35000).to_string())
  io_println(world, "hdr_pad3=" + ssh::ssh_packet_header_err_code(16, 12U, 3, 35000).to_string())
  io_println(world, "hdr_padge=" + ssh::ssh_packet_header_err_code(16, 12U, 12, 35000).to_string())
  io_println(world, "ct_u=" + ssh::cert_type_code(ssh::CertType::User).to_string())
  io_println(world, "ct_h=" + ssh::cert_type_code(ssh::CertType::Host).to_string())
  io_println(world, "ctf_1=" + opt_ct(ssh::cert_type_from_code(1U)))
  io_println(world, "ctf_2=" + opt_ct(ssh::cert_type_from_code(2U)))
  io_println(world, "ctf_0=" + opt_ct(ssh::cert_type_from_code(0U)))
  io_println(world, "tv_ok=" + ssh::cert_time_valid_code(100UL, 50UL, 200UL).to_string())
  io_println(world, "tv_early=" + ssh::cert_time_valid_code(49UL, 50UL, 200UL).to_string())
  io_println(world, "tv_exp=" + ssh::cert_time_valid_code(200UL, 50UL, 200UL).to_string())
  io_println(world, "tv_forever=" + ssh::cert_time_valid_code(18446744073709551615UL, 50UL, 18446744073709551615UL).to_string())
  io_println(world, "mask_1=" + ssh::cidr_rem_mask(1).to_string())
  io_println(world, "mask_4=" + ssh::cidr_rem_mask(4).to_string())
  io_println(world, "mask_7=" + ssh::cidr_rem_mask(7).to_string())
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"
diff -u "$NATIVE_OUT" "$LEAN_OUT"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (diff -u exit 0)"
echo "PASS: packages/$PKG_NAME Lean 4 proofs"
