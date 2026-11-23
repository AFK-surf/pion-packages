#!/usr/bin/env bash
set -euo pipefail

trap 'kill -- -$$ 2>/dev/null || true' INT TERM

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PKG="$ROOT/packages/jq"
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
lean_lib Jq where
  moreLeanArgs := #["--memory={mem}", "-j", "{threads}"]

lean_lib JqProofs where
  moreLeanArgs := #["--memory={mem}", "-j", "{threads}"]
'''
if "lean_lib JqProofs" not in txt:
    txt = txt.rstrip() + "\n" + extra
p.write_text(txt)
PY

echo "=== [2/7] pionc extract-lean packages/jq ==="
pionc extract-lean "$PKG" --out "$PROJ" --json

rm -rf "$PROJ/JqProofs" "$PROJ/JqProofs.lean" "$PROJ/CheckAxioms.lean" "$PROJ/EvalDiff.lean"
mkdir -p "$PROJ/JqProofs"
cp "$PROOFS/JqProofs.lean" "$PROJ/"
cp "$PROOFS/JqProofs/"*.lean "$PROJ/JqProofs/"
cp "$PROOFS/CheckAxioms.lean" "$PROJ/"
cp "$PROOFS/EvalDiff.lean" "$PROJ/"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "$PROOFS/JqProofs.lean" "$PROOFS/JqProofs/"; then
  echo "FAIL: forbidden tactic or axiom found"
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Jq.Types Jq.Funs JqProofs ==="
(cd "$PROJ" && lake build PionLean Jq.Types Jq.Funs JqProofs)

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
LEAN_DIFF_OUT="$WORK/jq_lean_diff.txt"
(cd "$PROJ" && lake env lean EvalDiff.lean) > "$LEAN_DIFF_OUT"
cat "$LEAN_DIFF_OUT"
if grep -q ': FAIL' "$LEAN_DIFF_OUT"; then
  echo "FAIL: Lean EvalDiff reported a FAIL case"
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_PKG="$WORK/jq_native_diff"
rm -rf "$DIFF_PKG"
mkdir -p "$DIFF_PKG/src"
cat > "$DIFF_PKG/pion.toml" <<EOF
[package]
name = "jq_native_diff"
version = "0.1.0"

[dependencies]
jq = { path = "$PKG" }
EOF

cat > "$DIFF_PKG/src/main.pion" <<'EOF'
import "jq"

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
  chk_bool(w, "ws_sp", jq::is_json_ws(32), true)
  chk_bool(w, "ws_tab", jq::is_json_ws(9), true)
  chk_bool(w, "ws_lf", jq::is_json_ws(10), true)
  chk_bool(w, "ws_cr", jq::is_json_ws(13), true)
  chk_bool(w, "ws_vt", jq::is_json_ws(11), false)
  chk_bool(w, "fast_a", jq::is_json_str_fast_byte(97), true)
  chk_bool(w, "fast_quote", jq::is_json_str_fast_byte(34), false)
  chk_bool(w, "fast_bs", jq::is_json_str_fast_byte(92), false)
  chk_bool(w, "fast_ctrl", jq::is_json_str_fast_byte(31), false)
  chk_bool(w, "fast_nonascii", jq::is_json_str_fast_byte(128), false)
  chk_bool(w, "ident_A", jq::is_ident_char(65), true)
  chk_bool(w, "ident_9", jq::is_ident_char(57), true)
  chk_bool(w, "ident_us", jq::is_ident_char(95), true)
  chk_bool(w, "ident_dash", jq::is_ident_char(45), false)
  chk_i32(w, "hex_0", jq::hex_val(48), 0)
  chk_i32(w, "hex_F", jq::hex_val(70), 15)
  chk_i32(w, "hex_a", jq::hex_val(97), 10)
  chk_i32(w, "hex_bad", jq::hex_val(122), -1)
  chk_i32(w, "san_ok", jq::sanitize_utf8_cp(65), 65)
  chk_i32(w, "san_neg", jq::sanitize_utf8_cp(-1), 65533)
  chk_i32(w, "san_surr", jq::sanitize_utf8_cp(55296), 65533)
  chk_i32(w, "san_hi", jq::sanitize_utf8_cp(1114112), 65533)
  chk_bool(w, "hi_surr", jq::is_high_surrogate(55357), true)
  chk_bool(w, "lo_surr", jq::is_low_surrogate(56832), true)
  chk_i32(w, "surr_emoji", jq::decode_surrogate_pair(55357, 56832), 128512)
  chk_i32(w, "surr_min", jq::decode_surrogate_pair(55296, 56320), 65536)
  chk_i32(w, "surr_max", jq::decode_surrogate_pair(56319, 57343), 1114111)
  chk_i32(w, "clamp_mid", jq::clamp_slice_idx(3, 10), 3)
  chk_i32(w, "clamp_neg", jq::clamp_slice_idx(-2, 10), 8)
  chk_i32(w, "clamp_under", jq::clamp_slice_idx(-50, 10), 0)
  chk_i32(w, "clamp_over", jq::clamp_slice_idx(50, 10), 10)
  chk_i32(w, "clamp_i32min", jq::clamp_slice_idx(-2147483647 - 1, 10), 0)
  chk_i32(w, "clamp64_lo", jq::clamp_slice_i64(-5000000000L, 10), 0)
  chk_i32(w, "clamp64_hi", jq::clamp_slice_i64(5000000000L, 10), 10)
  chk_i32(w, "clamp64_neg", jq::clamp_slice_i64(-3L, 10), 7)
  0
}
EOF

PION_DIFF_OUT="$WORK/jq_pion_diff.txt"
pionc run "$DIFF_PKG" > "$PION_DIFF_OUT"
diff -u "$LEAN_DIFF_OUT" "$PION_DIFF_OUT"
LINES="$(wc -l < "$LEAN_DIFF_OUT" | tr -d ' ')"
echo "Native vs Lean differential: $LINES cases identical (diff -u exit 0)"
echo "PASS: packages/jq Lean 4 proofs"
