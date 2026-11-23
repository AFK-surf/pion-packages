#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/websocket`.
#
# Builds a throw-away Lake project in /private/tmp/pion-lean-websocket (zero git
# worktree pollution), extracts `packages/websocket` via `pionc extract-lean`,
# compiles `PionLean`, `Websocket`, and `WebsocketProofs`, rejects any
# `sorry`/`admit`/`native_decide`/`bv_decide`, verifies `#print axioms`
# (only `propext`, `Classical.choice`, `Quot.sound`), and runs `EvalDiff.lean`
# + a Pion native differential cross-check (`diff -u`).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-websocket}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-$WORK/pion-ref}"
AENEAS_REV=1dc8ad31b1
PIONC="${PIONC:-pionc}"

mkdir -p "$WORK"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas@$AENEAS_REV in $WORK ==="
if [ ! -d "$PION_REF/lean" ]; then
  if [ -d "/private/tmp/pion-lean-ref/lean" ]; then
    PION_REF="/private/tmp/pion-lean-ref"
  elif [ -d "/private/tmp/pion-lean-ref-semver/lean" ]; then
    PION_REF="/private/tmp/pion-lean-ref-semver"
  else
    git clone --depth 1 -q https://github.com/AFK-surf/pion.git "$PION_REF"
  fi
fi

if [ -z "${AENEAS_DIR:-}" ]; then
  if [ -d "/private/tmp/pion-lean-semver/aeneas/backends/lean" ]; then
    AENEAS_DIR="/private/tmp/pion-lean-semver/aeneas/backends/lean"
  else
    if [ ! -d "$WORK/aeneas/.git" ]; then
      git clone -q https://github.com/AeneasVerif/aeneas.git "$WORK/aeneas"
    fi
    git -C "$WORK/aeneas" checkout -q "$AENEAS_REV"
    AENEAS_DIR="$WORK/aeneas/backends/lean"
  fi
fi

if [ ! -f "$PROJ/lakefile.lean" ] || [ ! -d "$PROJ/.lake/packages/mathlib" ]; then
  rm -rf "$PROJ"
  mkdir -p "$PROJ/.deps" "$PROJ/.lake"
  (cd "$PION_REF/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
  (cd "$PROJ" && lake exe cache get)
else
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

echo "=== [2/7] pionc extract-lean packages/websocket ==="
rm -rf "$PROJ/Websocket"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Websocket/$f.lean" ]; then
    echo "FAIL: missing Websocket/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/WebsocketProofs"
cp -R "$SCRIPT_DIR/WebsocketProofs" "$PROJ/WebsocketProofs"
cp "$SCRIPT_DIR/WebsocketProofs.lean" "$PROJ/WebsocketProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Websocket where\n  globs := #[.submodules `Websocket]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib WebsocketProofs where\n  globs := #[.andSubmodules `WebsocketProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/WebsocketProofs.lean" "$SCRIPT_DIR/WebsocketProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Websocket WebsocketProofs ==="
cd "$PROJ"
set +e
lake build PionLean Websocket WebsocketProofs > "$WORK/build.log" 2>&1
RC=$?
set -e
grep -v '^✔\|^trace\|^info' "$WORK/build.log" | tail -80 || true
if [ "$RC" -ne 0 ] || grep -q '^error' "$WORK/build.log"; then
  echo "FAIL: lake build failed (rc=$RC)" >&2
  cat "$WORK/build.log" >&2
  exit 1
fi
if grep -q "declaration uses .sorry" "$WORK/build.log"; then
  echo "FAIL: declaration uses sorry" >&2
  exit 1
fi
echo "lake build PionLean Websocket WebsocketProofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
AXIOMS_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" CheckAxioms.lean 2>&1)
echo "$AXIOMS_OUT"
BAD_AXIOMS=$(printf '%s\n' "$AXIOMS_OUT" | grep -E "depends on axioms:" | sed 's/.*\[//;s/\].*//;s/,/\n/g' | tr -d ' ' | sort -u | grep -v -E '^(propext|Classical\.choice|Quot\.sound)$' || true)
if [ -n "$BAD_AXIOMS" ]; then
  echo "FAIL: unexpected axioms found: $BAD_AXIOMS" >&2
  exit 1
fi
if printf '%s\n' "$AXIOMS_OUT" | grep -q "error:"; then
  echo "FAIL: CheckAxioms.lean reported errors" >&2
  exit 1
fi
echo "Axioms audit: ONLY standard axioms (propext, Classical.choice, Quot.sound)"

echo "=== [6/7] EvalDiff.lean (#eval) ==="
EVAL_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" EvalDiff.lean 2>&1)
echo "$EVAL_OUT"
if printf '%s\n' "$EVAL_OUT" | grep -q "error:"; then
  echo "FAIL: EvalDiff.lean reported errors" >&2
  exit 1
fi
if printf '%s\n' "$EVAL_OUT" | grep -q ': FAIL$'; then
  echo "FAIL: EvalDiff.lean had a FAIL check" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_DIR="$WORK/native-diff"
rm -rf "$DIFF_DIR"
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "websocket_lean_diff"
version = "0.1.0"

[dependencies]
websocket = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "websocket"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "xor_involution", websocket::mask_byte_xor(websocket::mask_byte_xor(0xAB, 0x5C), 0x5C) == 0xAB)
  report(w, "xor_zero_id", websocket::mask_byte_xor(0x7F, 0) == 0x7F)
  report(w, "mask_key_b0", websocket::mask_key_byte(0x12345678U, 0) == 0x12)
  report(w, "mask_key_b3", websocket::mask_key_byte(0x12345678U, 3) == 0x78)
  report(w, "mask_key_periodic", websocket::mask_key_byte(0x12345678U, 7) == 0x78)
  report(w, "ext_len_125", websocket::encoded_ext_len(125) == 0)
  report(w, "ext_len_126", websocket::encoded_ext_len(126) == 2)
  report(w, "ext_len_65535", websocket::encoded_ext_len(65535) == 2)
  report(w, "ext_len_65536", websocket::encoded_ext_len(65536) == 8)
  report(w, "hdr_len_small_unmasked", websocket::encoded_header_len(10, false) == 2)
  report(w, "hdr_len_large_masked", websocket::encoded_header_len(70000, true) == 14)
  report(
    w,
    "opcode_text",
    match websocket::opcode_from_int(1) {
      Some(websocket::Opcode::Text) => true
      _ => false
    },
  )
  report(
    w,
    "opcode_pong",
    match websocket::opcode_from_int(10) {
      Some(websocket::Opcode::Pong) => true
      _ => false
    },
  )
  report(
    w,
    "opcode_reserved_3",
    match websocket::opcode_from_int(3) {
      None => true
      _ => false
    },
  )
  report(
    w,
    "opcode_reserved_15",
    match websocket::opcode_from_int(15) {
      None => true
      _ => false
    },
  )
  report(w, "ctrl_close", websocket::is_control_opcode(websocket::Opcode::Close) == true)
  report(w, "ctrl_text_false", websocket::is_control_opcode(websocket::Opcode::Text) == false)
  report(w, "role_srv_unmasked", websocket::check_role_mask(websocket::Role::Server, false) == 1)
  report(w, "role_cli_masked", websocket::check_role_mask(websocket::Role::Client, true) == 2)
  report(w, "ctrl_frag_err", websocket::check_control_frame(true, false, 5) == 1)
  report(w, "ctrl_126_err", websocket::check_control_frame(true, true, 126) == 2)
  report(w, "ctrl_125_ok", websocket::check_control_frame(true, true, 125) == 0)
  report(w, "min_len16_125_false", websocket::is_minimal_len16(125) == false)
  report(w, "min_len16_126_true", websocket::is_minimal_len16(126) == true)
  report(w, "len64_msb_err", websocket::check_ext_len64(0x80, 70000L, 100000) == 1)
  report(w, "len64_nonmin_err", websocket::check_ext_len64(0, 65535L, 100000) == 2)
  report(w, "len64_toolarge_err", websocket::check_ext_len64(0, 200000L, 100000) == 3)
  report(w, "len64_ok", websocket::check_ext_len64(0, 70000L, 100000) == 0)
  report(w, "clamp_over_i32", websocket::clamp_i64_to_i32_max(3000000000L) == 2147483647)
  report(w, "frame_total_no_ovf", websocket::frame_total_bytes(10, true, 2147483647) == 2147483661L)
  report(w, "frag_sum_no_ovf", websocket::frag_sum_i64(2000000000, 2000000000) == 4000000000L)
  report(w, "close_1000_ok", websocket::is_valid_close_code(1000) == true)
  report(w, "close_1005_false", websocket::is_valid_close_code(1005) == false)
  report(w, "close_1006_false", websocket::is_valid_close_code(1006) == false)
  report(w, "close_1015_false", websocket::is_valid_close_code(1015) == false)
  report(w, "close_4999_ok", websocket::is_valid_close_code(4999) == true)
  report(w, "close_5000_false", websocket::is_valid_close_code(5000) == false)
  report(w, "utf8_ascii_0", websocket::utf8_dfa_step(0, 65) == 0)
  report(w, "utf8_overlong_c0", websocket::utf8_dfa_step(0, 0xC0) == -1)
  report(w, "utf8_surrogate_ed_a0", websocket::utf8_dfa_step(websocket::utf8_dfa_step(0, 0xED), 0xA0) == -1)
  report(w, "utf8_above_10ffff", websocket::utf8_dfa_step(websocket::utf8_dfa_step(0, 0xF4), 0x90) == -1)
  report(w, "utf8_2byte_ok", websocket::utf8_dfa_step(websocket::utf8_dfa_step(0, 0xC3), 0xA9) == 0)
  0
}
EOF
"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/websocket Lean 4 proofs"
