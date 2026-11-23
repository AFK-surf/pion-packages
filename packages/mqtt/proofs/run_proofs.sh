#!/usr/bin/env bash
set -euo pipefail

trap 'kill -- -$$ 2>/dev/null || true' INT TERM

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PKG="$ROOT/packages/mqtt"
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
lean_lib Mqtt where
  moreLeanArgs := #["--memory={mem}", "-j", "{threads}"]

lean_lib MqttProofs where
  moreLeanArgs := #["--memory={mem}", "-j", "{threads}"]
'''
if "lean_lib MqttProofs" not in txt:
    txt = txt.rstrip() + "\n" + extra
p.write_text(txt)
PY

echo "=== [2/7] pionc extract-lean packages/mqtt ==="
pionc extract-lean "$PKG" --out "$PROJ" --json

rm -rf "$PROJ/MqttProofs" "$PROJ/MqttProofs.lean" "$PROJ/CheckAxioms.lean" "$PROJ/EvalDiff.lean"
mkdir -p "$PROJ/MqttProofs"
cp "$PROOFS/MqttProofs.lean" "$PROJ/"
cp "$PROOFS/MqttProofs/"*.lean "$PROJ/MqttProofs/"
cp "$PROOFS/CheckAxioms.lean" "$PROJ/"
cp "$PROOFS/EvalDiff.lean" "$PROJ/"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "$PROOFS/MqttProofs.lean" "$PROOFS/MqttProofs/"; then
  echo "FAIL: forbidden tactic or axiom found"
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Mqtt.Types Mqtt.Funs MqttProofs ==="
(cd "$PROJ" && lake build PionLean Mqtt.Types Mqtt.Funs MqttProofs)

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
if count < 27:
    print(f"FAIL: expected >= 27 checked theorems, got {count}")
    sys.exit(1)
print(f"CheckAxioms: {count} theorems verified, standard axioms only")
PY

echo "=== [6/7] Lean EvalDiff ==="
LEAN_DIFF_OUT="$WORK/mqtt_lean_diff.txt"
(cd "$PROJ" && lake env lean EvalDiff.lean) > "$LEAN_DIFF_OUT"
cat "$LEAN_DIFF_OUT"
if grep -q ': FAIL' "$LEAN_DIFF_OUT"; then
  echo "FAIL: Lean EvalDiff reported a FAIL case"
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_PKG="$WORK/mqtt_native_diff"
rm -rf "$DIFF_PKG"
mkdir -p "$DIFF_PKG/src"
cat > "$DIFF_PKG/pion.toml" <<EOF
[package]
name = "mqtt_native_diff"
version = "0.1.0"

[dependencies]
mqtt = { path = "$PKG" }
EOF

cat > "$DIFF_PKG/src/main.pion" <<'EOF'
import "mqtt"

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

fn qos_opt_code(o : Option[mqtt::QoS]) -> Int {
  match o {
    Some(q) => mqtt::qos_to_int(q)
    None => -1
  }
}

fn pt_opt_code(o : Option[mqtt::PacketType]) -> Int {
  match o {
    Some(pt) => mqtt::packet_type_to_int(pt)
    None => -1
  }
}

pub fn main(w : World) -> Int {
  chk_i32(w, "qos_0", mqtt::qos_to_int(mqtt::QoS::AtMostOnce), 0)
  chk_i32(w, "qos_2", mqtt::qos_to_int(mqtt::QoS::ExactlyOnce), 2)
  chk_i32(w, "qosf_1", qos_opt_code(mqtt::qos_from_int_opt(1)), 1)
  chk_i32(w, "qosf_3", qos_opt_code(mqtt::qos_from_int_opt(3)), -1)
  chk_i32(w, "pt_conn", mqtt::packet_type_to_int(mqtt::PacketType::Connect), 1)
  chk_i32(w, "pt_auth", mqtt::packet_type_to_int(mqtt::PacketType::Auth), 15)
  chk_i32(w, "ptf_0", pt_opt_code(mqtt::packet_type_from_int_opt(0)), -1)
  chk_i32(w, "ptf_3", pt_opt_code(mqtt::packet_type_from_int_opt(3)), 3)
  chk_i32(w, "ptf_15", pt_opt_code(mqtt::packet_type_from_int_opt(15)), 15)
  chk_i32(w, "ptf_16", pt_opt_code(mqtt::packet_type_from_int_opt(16)), -1)
  chk_i32(w, "vlen_neg", mqtt::vbi_encoded_len(-1), 0)
  chk_i32(w, "vlen_0", mqtt::vbi_encoded_len(0), 1)
  chk_i32(w, "vlen_127", mqtt::vbi_encoded_len(127), 1)
  chk_i32(w, "vlen_128", mqtt::vbi_encoded_len(128), 2)
  chk_i32(w, "vlen_16383", mqtt::vbi_encoded_len(16383), 2)
  chk_i32(w, "vlen_16384", mqtt::vbi_encoded_len(16384), 3)
  chk_i32(w, "vlen_2097151", mqtt::vbi_encoded_len(2097151), 3)
  chk_i32(w, "vlen_2097152", mqtt::vbi_encoded_len(2097152), 4)
  chk_i32(w, "vlen_max", mqtt::vbi_encoded_len(268435455), 4)
  chk_i32(w, "vlen_over", mqtt::vbi_encoded_len(268435456), 0)
  chk_i32(w, "vdec2_min", mqtt::vbi_decode_2(128, 1), 128)
  chk_i32(w, "vdec2_max", mqtt::vbi_decode_2(255, 127), 16383)
  chk_i32(w, "vdec3_min", mqtt::vbi_decode_3(128, 128, 1), 16384)
  chk_i32(w, "vdec4_max", mqtt::vbi_decode_4(255, 255, 255, 127), 268435455)
  chk_i32(w, "fh_pt0", mqtt::fixed_header_flags_err_code(0, 0), 1)
  chk_i32(w, "fh_pub_ok", mqtt::fixed_header_flags_err_code(3, 2), 0)
  chk_i32(w, "fh_pub_qos3", mqtt::fixed_header_flags_err_code(3, 6), 2)
  chk_i32(w, "fh_pub_dup0", mqtt::fixed_header_flags_err_code(3, 8), 3)
  chk_i32(w, "fh_sub_ok", mqtt::fixed_header_flags_err_code(8, 2), 0)
  chk_i32(w, "fh_sub_bad", mqtt::fixed_header_flags_err_code(8, 0), 3)
  chk_i32(w, "fh_conn_ok", mqtt::fixed_header_flags_err_code(1, 0), 0)
  chk_i32(w, "fh_conn_bad", mqtt::fixed_header_flags_err_code(1, 2), 3)
  chk_bool(w, "asc_nul", mqtt::is_mqtt_forbidden_ascii(0), true)
  chk_bool(w, "asc_del", mqtt::is_mqtt_forbidden_ascii(127), true)
  chk_bool(w, "asc_sp", mqtt::is_mqtt_forbidden_ascii(32), false)
  chk_bool(w, "cont_80", mqtt::is_utf8_cont_byte(128), true)
  chk_bool(w, "cont_bf", mqtt::is_utf8_cont_byte(191), true)
  chk_bool(w, "cont_c0", mqtt::is_utf8_cont_byte(192), false)
  chk_bool(w, "c1_80", mqtt::is_mqtt_c1_control_2b(194, 128), true)
  chk_bool(w, "c1_a0", mqtt::is_mqtt_c1_control_2b(194, 160), false)
  0
}
EOF

PION_DIFF_OUT="$WORK/mqtt_pion_diff.txt"
pionc run "$DIFF_PKG" > "$PION_DIFF_OUT"
diff -u "$LEAN_DIFF_OUT" "$PION_DIFF_OUT"
LINES="$(wc -l < "$LEAN_DIFF_OUT" | tr -d ' ')"
echo "Native vs Lean differential: $LINES cases identical (diff -u exit 0)"
echo "PASS: packages/mqtt Lean 4 proofs"
