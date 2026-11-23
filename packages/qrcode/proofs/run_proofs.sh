#!/usr/bin/env bash
set -euo pipefail

trap 'kill -- -$$ 2>/dev/null || true' INT TERM

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PKG="$ROOT/packages/qrcode"
PROOFS="$PKG/proofs"
WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-/private/tmp/pion-lean-ref}"
AENEAS_DIR="${AENEAS_LEAN_DIR:-/private/tmp/pion-lean-semver/aeneas/backends/lean}"
export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas in $WORK ==="
mkdir -p "$PROJ"
cp -R "$PION_REF/lean/PionLean" "$PROJ/"
cp "$PION_REF/lean/PionLean.lean" "$PROJ/"
cp "$PION_REF/lean/lean-toolchain" "$PROJ/"
cp "$PION_REF/lean/lakefile.lean" "$PROJ/"

python3 - "$PROJ/lakefile.lean" "$AENEAS_DIR" "$MEM_LIMIT" "$LEAN_NUM_THREADS" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
aeneas_dir, mem, threads = sys.argv[2], sys.argv[3], sys.argv[4]
txt = p.read_text()
txt = txt.replace("../aeneas/backends/lean", aeneas_dir)
extra = f'''
lean_lib Qrcode where
  moreLeanArgs := #["--memory={mem}", "-j", "{threads}"]

lean_lib QrcodeProofs where
  moreLeanArgs := #["--memory={mem}", "-j", "{threads}"]
'''
if "lean_lib QrcodeProofs" not in txt:
    txt = txt.rstrip() + "\n" + extra
p.write_text(txt)
PY

echo "=== [2/7] pionc extract-lean packages/qrcode ==="
pionc extract-lean "$PKG" --out "$PROJ" --json

rm -rf "$PROJ/QrcodeProofs" "$PROJ/QrcodeProofs.lean" "$PROJ/CheckAxioms.lean" "$PROJ/EvalDiff.lean"
mkdir -p "$PROJ/QrcodeProofs"
cp "$PROOFS/QrcodeProofs.lean" "$PROJ/"
cp "$PROOFS/QrcodeProofs/"*.lean "$PROJ/QrcodeProofs/"
cp "$PROOFS/CheckAxioms.lean" "$PROJ/"
cp "$PROOFS/EvalDiff.lean" "$PROJ/"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "$PROOFS/QrcodeProofs.lean" "$PROOFS/QrcodeProofs/"; then
  echo "FAIL: forbidden tactic or axiom found"
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Qrcode.Types Qrcode.Funs QrcodeProofs ==="
(cd "$PROJ" && lake build PionLean Qrcode.Types Qrcode.Funs QrcodeProofs)

echo "=== [5/7] CheckAxioms (standard axioms only) ==="
AX_OUT="$(cd "$PROJ" && lake env lean CheckAxioms.lean 2>&1)"
echo "$AX_OUT"
python3 - "$AX_OUT" <<'PY'
import sys, re
out = sys.argv[1]
allowed = {"propext", "Classical.choice", "Quot.sound"}
lines = [l.strip() for l in out.splitlines() if l.strip()]
count = 0
for l in lines:
    if "does not depend on any axioms" in l:
        count += 1
        continue
    m = re.search(r"depends on axioms:\s*\[([^\]]*)\]", l)
    if m:
        count += 1
        axs = {a.strip() for a in m.group(1).split(",") if a.strip()}
        bad = axs - allowed
        if bad:
            print(f"FAIL: unexpected axioms {bad} in: {l}")
            sys.exit(1)
    else:
        print(f"FAIL: unexpected CheckAxioms line: {l}")
        sys.exit(1)
if count < 22:
    print(f"FAIL: expected >= 22 checked theorems, got {count}")
    sys.exit(1)
print(f"CheckAxioms: {count} theorems verified, standard axioms only")
PY

echo "=== [6/7] Lean EvalDiff ==="
LEAN_DIFF_OUT="$WORK/qrcode_lean_diff.txt"
(cd "$PROJ" && lake env lean EvalDiff.lean) > "$LEAN_DIFF_OUT"
cat "$LEAN_DIFF_OUT"
if grep -q ': FAIL' "$LEAN_DIFF_OUT"; then
  echo "FAIL: Lean EvalDiff reported a FAIL case"
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_PKG="$WORK/qrcode_native_diff"
rm -rf "$DIFF_PKG"
mkdir -p "$DIFF_PKG/src"
cat > "$DIFF_PKG/pion.toml" <<EOF
[package]
name = "qrcode_native_diff"
version = "0.1.0"

[dependencies]
qrcode = { path = "$PKG" }
EOF

cat > "$DIFF_PKG/src/main.pion" <<'EOF'
import "qrcode"

fn chk_i32(w : World, label : String, actual : Int, expected : Int) -> Unit {
  if actual == expected {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

fn chk_bool(w : World, label : String, actual : Bool, expected : Bool) -> Unit {
  if actual == expected {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  chk_i32(w, "ec_L_fb", qrcode::EcLevel::L.format_bits(), 1)
  chk_i32(w, "ec_M_fb", qrcode::EcLevel::M.format_bits(), 0)
  chk_i32(w, "ec_Q_fb", qrcode::EcLevel::Q.format_bits(), 3)
  chk_i32(w, "ec_H_fb", qrcode::EcLevel::H.format_bits(), 2)
  chk_i32(w, "mode_num", qrcode::Mode::Numeric.indicator(), 1)
  chk_i32(w, "mode_alnum", qrcode::Mode::Alphanumeric.indicator(), 2)
  chk_i32(w, "mode_byte", qrcode::Mode::Byte.indicator(), 4)
  chk_i32(w, "mode_kanji", qrcode::Mode::Kanji.indicator(), 8)
  chk_i32(w, "mode_eci", qrcode::Mode::Eci.indicator(), 7)
  chk_i32(w, "vsize_1", qrcode::version_size(1), 21)
  chk_i32(w, "vsize_7", qrcode::version_size(7), 45)
  chk_i32(w, "vsize_40", qrcode::version_size(40), 177)
  chk_i32(w, "raw_v1", qrcode::raw_data_modules(1), 208)
  chk_i32(w, "raw_v7", qrcode::raw_data_modules(7), 1568)
  chk_i32(w, "raw_v40", qrcode::raw_data_modules(40), 29648)
  chk_i32(w, "cw_v1", qrcode::total_codewords(1), 26)
  chk_i32(w, "cw_v40", qrcode::total_codewords(40), 3706)
  chk_i32(w, "ccb_v1_num", qrcode::char_count_bits(1, qrcode::Mode::Numeric), 10)
  chk_i32(w, "ccb_v10_byte", qrcode::char_count_bits(10, qrcode::Mode::Byte), 16)
  chk_i32(w, "ccb_v27_kanji", qrcode::char_count_bits(27, qrcode::Mode::Kanji), 12)
  chk_i32(w, "ceil6_0", qrcode::ceil_sixths(0), 0)
  chk_i32(w, "ceil6_1", qrcode::ceil_sixths(1), 6)
  chk_i32(w, "ceil6_6", qrcode::ceil_sixths(6), 6)
  chk_i32(w, "ceil6_7", qrcode::ceil_sixths(7), 12)
  chk_bool(w, "mask0_3_5", qrcode::apply_mask_condition(0, 3, 5), true)
  chk_bool(w, "mask1_3_5", qrcode::apply_mask_condition(1, 3, 5), false)
  chk_bool(w, "mask2_6_5", qrcode::apply_mask_condition(2, 6, 5), true)
  chk_bool(w, "mask3_4_5", qrcode::apply_mask_condition(3, 4, 5), true)
  chk_bool(w, "mask4_3_2", qrcode::apply_mask_condition(4, 3, 2), true)
  chk_bool(w, "mask5_2_3", qrcode::apply_mask_condition(5, 2, 3), true)
  chk_bool(w, "mask6_2_3", qrcode::apply_mask_condition(6, 2, 3), true)
  chk_bool(w, "mask7_2_3", qrcode::apply_mask_condition(7, 2, 3), false)
  chk_i32(w, "kanji_min", qrcode::kanji_value(0x81, 0x40), 0)
  chk_i32(w, "kanji_mid", qrcode::kanji_value(0x93, 0x5F), 3487)
  chk_i32(w, "kanji_hi", qrcode::kanji_value(0xEB, 0xBF), 8191)
  chk_i32(w, "kanji_7f", qrcode::kanji_value(0x81, 0x7F), -1)
  chk_i32(w, "kfrom_0", qrcode::kanji_from_value(0), 33088)
  chk_i32(w, "kfrom_3487", qrcode::kanji_from_value(3487), 37727)
  chk_i32(w, "kfrom_8191", qrcode::kanji_from_value(8191), 60351)
  chk_i32(w, "kfrom_bad", qrcode::kanji_from_value(63), -1)
  0
}
EOF

PION_DIFF_OUT="$WORK/qrcode_pion_diff.txt"
pionc run "$DIFF_PKG" > "$PION_DIFF_OUT"
diff -u "$LEAN_DIFF_OUT" "$PION_DIFF_OUT"
LINES="$(wc -l < "$LEAN_DIFF_OUT" | tr -d ' ')"
echo "Native vs Lean differential: $LINES cases identical (diff -u exit 0)"
echo "PASS: packages/qrcode Lean 4 proofs"
