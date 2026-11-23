#!/usr/bin/env bash
set -euo pipefail

trap 'kill -- -$$ 2>/dev/null || true' INT TERM

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PKG="$ROOT/packages/git"
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
lean_lib Git where
  moreLeanArgs := #["--memory={mem}", "-j", "{threads}"]

lean_lib GitProofs where
  moreLeanArgs := #["--memory={mem}", "-j", "{threads}"]
'''
if "lean_lib GitProofs" not in txt:
    txt = txt.rstrip() + "\n" + extra
p.write_text(txt)
PY

echo "=== [2/7] pionc extract-lean packages/git ==="
pionc extract-lean "$PKG" --out "$PROJ" --json

rm -rf "$PROJ/GitProofs" "$PROJ/GitProofs.lean" "$PROJ/CheckAxioms.lean" "$PROJ/EvalDiff.lean"
mkdir -p "$PROJ/GitProofs"
cp "$PROOFS/GitProofs.lean" "$PROJ/"
cp "$PROOFS/GitProofs/"*.lean "$PROJ/GitProofs/"
cp "$PROOFS/CheckAxioms.lean" "$PROJ/"
cp "$PROOFS/EvalDiff.lean" "$PROJ/"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "$PROOFS/GitProofs.lean" "$PROOFS/GitProofs/"; then
  echo "FAIL: forbidden tactic or axiom found"
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Git.Types Git.Funs GitProofs ==="
(cd "$PROJ" && lake build PionLean Git.Types Git.Funs GitProofs)

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
LEAN_DIFF_OUT="$WORK/git_lean_diff.txt"
(cd "$PROJ" && lake env lean EvalDiff.lean) > "$LEAN_DIFF_OUT"
cat "$LEAN_DIFF_OUT"
if grep -q ': FAIL' "$LEAN_DIFF_OUT"; then
  echo "FAIL: Lean EvalDiff reported a FAIL case"
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_PKG="$WORK/git_native_diff"
rm -rf "$DIFF_PKG"
mkdir -p "$DIFF_PKG/src"
cat > "$DIFF_PKG/pion.toml" <<EOF
[package]
name = "git_native_diff"
version = "0.1.0"

[dependencies]
git = { path = "$PKG" }
EOF

cat > "$DIFF_PKG/src/main.pion" <<'EOF'
import "git"

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

fn kind_code(o : Option[git::ObjectKind]) -> Int {
  match o {
    Some(git::ObjectKind::Commit) => 1
    Some(git::ObjectKind::Tree) => 2
    Some(git::ObjectKind::Blob) => 3
    Some(git::ObjectKind::Tag) => 4
    None => 0
  }
}

pub fn main(w : World) -> Int {
  chk_i32(w, "hex_0", git::hex_nibble(48), 0)
  chk_i32(w, "hex_9", git::hex_nibble(57), 9)
  chk_i32(w, "hex_a", git::hex_nibble(97), 10)
  chk_i32(w, "hex_f", git::hex_nibble(102), 15)
  chk_i32(w, "hex_A", git::hex_nibble(65), 10)
  chk_i32(w, "hex_F", git::hex_nibble(70), 15)
  chk_i32(w, "hex_g", git::hex_nibble(103), -1)
  chk_i32(w, "pkt_len_0000", git::pkt_line_decode_len(0, 0, 0, 0), 0)
  chk_i32(w, "pkt_len_0010", git::pkt_line_decode_len(0, 0, 1, 0), 16)
  chk_i32(w, "pkt_len_fff0", git::pkt_line_decode_len(15, 15, 15, 0), 65520)
  chk_i32(w, "pkt_cls_0", git::pkt_line_classify_len(0), 0)
  chk_i32(w, "pkt_cls_1", git::pkt_line_classify_len(1), 1)
  chk_i32(w, "pkt_cls_2", git::pkt_line_classify_len(2), 2)
  chk_i32(w, "pkt_cls_3", git::pkt_line_classify_len(3), -1)
  chk_i32(w, "pkt_cls_4", git::pkt_line_classify_len(4), 3)
  chk_i32(w, "pkt_cls_65520", git::pkt_line_classify_len(65520), 3)
  chk_i32(w, "pkt_cls_65521", git::pkt_line_classify_len(65521), -1)
  chk_bool(w, "ref_ch_sp", git::is_ref_forbidden_char(32), true)
  chk_bool(w, "ref_ch_tilde", git::is_ref_forbidden_char(126), true)
  chk_bool(w, "ref_ch_slash", git::is_ref_forbidden_char(47), false)
  chk_bool(w, "ref_ch_a", git::is_ref_forbidden_char(97), false)
  chk_bool(w, "ref_pair_dotdot", git::is_ref_forbidden_pair(46, 46), true)
  chk_bool(w, "ref_pair_ss", git::is_ref_forbidden_pair(47, 47), true)
  chk_bool(w, "ref_pair_atb", git::is_ref_forbidden_pair(64, 123), true)
  chk_bool(w, "ref_pair_ok", git::is_ref_forbidden_pair(97, 98), false)
  chk_i32(w, "okind_1", kind_code(git::object_kind_from_pack_type_opt(1)), 1)
  chk_i32(w, "okind_4", kind_code(git::object_kind_from_pack_type_opt(4)), 4)
  chk_i32(w, "okind_5", kind_code(git::object_kind_from_pack_type_opt(5)), 0)
  chk_i32(w, "idx_stage_0", git::index_flags_stage(0U), 0)
  chk_i32(w, "idx_stage_3", git::index_flags_stage(12288U), 3)
  chk_i32(w, "idx_pad_63", git::index_v2_padded_len(63), 64)
  chk_i32(w, "idx_pad_64", git::index_v2_padded_len(64), 64)
  chk_i32(w, "idx_padb_63", git::index_v2_pad_bytes(63), 1)
  chk_i32(w, "idx_padb_64", git::index_v2_pad_bytes(64), 0)
  chk_i32(w, "delta_dec_0", git::delta_copy_size_decode(0), 65536)
  chk_i32(w, "delta_dec_42", git::delta_copy_size_decode(42), 42)
  chk_i32(w, "delta_enc_65536", git::delta_copy_size_encode(65536), 0)
  chk_bool(w, "delta_rng_ok", git::delta_copy_range_ok(10, 20, 30, 5, 25), true)
  chk_bool(w, "delta_rng_bad", git::delta_copy_range_ok(11, 20, 30, 5, 25), false)
  0
}
EOF

PION_DIFF_OUT="$WORK/git_pion_diff.txt"
pionc run "$DIFF_PKG" > "$PION_DIFF_OUT"
diff -u "$LEAN_DIFF_OUT" "$PION_DIFF_OUT"
LINES="$(wc -l < "$LEAN_DIFF_OUT" | tr -d ' ')"
echo "Native vs Lean differential: $LINES cases identical (diff -u exit 0)"
echo "PASS: packages/git Lean 4 proofs"
