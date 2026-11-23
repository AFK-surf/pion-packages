#!/bin/sh
set -eu

export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$PATH"
PROOFS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$PROOFS_DIR/.." && pwd)
WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-$WORK/pion-ref}"
AENEAS_REV=1dc8ad31b1
JOBS="${LEAN_NUM_THREADS:-2}"
MEM="${LEAN_MEM_LIMIT:-8192}"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas@$AENEAS_REV in $WORK ==="
mkdir -p "$WORK" "$PROJ/WasmProofs"
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
  mkdir -p "$PROJ/.deps" "$PROJ/.lake" "$PROJ/WasmProofs"
  (cd "$PION_REF/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
  (cd "$PROJ" && lake exe cache get)
else
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

echo "=== [2/7] pionc extract-lean packages/wasm ==="
pionc extract-lean "$PKG_DIR" --out "$PROJ" --json

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|bv_decide|native_decide)\b|^axiom\b' "$PROOFS_DIR/WasmProofs.lean" "$PROOFS_DIR/WasmProofs/"; then
  echo "FAIL: forbidden tactic or axiom found" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

cp "$PROOFS_DIR/WasmProofs.lean" "$PROJ/WasmProofs.lean"
cp "$PROOFS_DIR/WasmProofs/"*.lean "$PROJ/WasmProofs/"
cp "$PROOFS_DIR/CheckAxioms.lean" "$PROJ/CheckAxiomsWasm.lean"
cp "$PROOFS_DIR/EvalDiff.lean" "$PROJ/EvalDiffWasm.lean"

printf '\nlean_lib Wasm where\n  globs := #[.submodules `Wasm]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$MEM" "$JOBS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib WasmProofs where\n  globs := #[.andSubmodules `WasmProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$MEM" "$JOBS" >> "$PROJ/lakefile.lean"

echo "=== [4/7] lake build PionLean Wasm WasmProofs ==="
BUILD_LOG="$WORK/wasm_build.log"
(cd "$PROJ" && LEAN_NUM_THREADS="$JOBS" lake build PionLean Wasm WasmProofs) > "$BUILD_LOG" 2>&1 || {
  cat "$BUILD_LOG"
  echo "FAIL: lake build failed" >&2
  exit 1
}
cat "$BUILD_LOG"
if grep -qE '^warning:|warning: ' "$BUILD_LOG"; then
  echo "FAIL: warnings found in WasmProofs build" >&2
  exit 1
fi
echo "lake build PionLean Wasm WasmProofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
AX_OUT=$(cd "$PROJ" && lake env lean --memory="$MEM" -j "$JOBS" CheckAxiomsWasm.lean)
echo "$AX_OUT"
if echo "$AX_OUT" | grep -vE "^'WasmProofs\.[a-zA-Z0-9_]+' depends on axioms: \[(propext(, Classical\.choice)?(, Quot\.sound)?|Classical\.choice(, Quot\.sound)?|Quot\.sound)\]$" | grep -vE "^'WasmProofs\.[a-zA-Z0-9_]+' does not depend on any axioms$" | grep -q .; then
  echo "FAIL: unexpected axiom detected" >&2
  exit 1
fi
echo "Axioms audit: ONLY standard axioms (propext, Classical.choice, Quot.sound)"

echo "=== [6/7] EvalDiff.lean (#eval) ==="
LEAN_DIFF="$WORK/wasm_lean_diff.txt"
(cd "$PROJ" && lake env lean --memory="$MEM" -j "$JOBS" EvalDiffWasm.lean) > "$LEAN_DIFF"
cat "$LEAN_DIFF"
if grep -q 'FAIL' "$LEAN_DIFF"; then
  echo "FAIL: Lean EvalDiff reported FAIL" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_DIR="$WORK/wasm_native_diff"
rm -rf "$DIFF_DIR" && mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "wasm_diff"
version = "0.1.0"
edition = "2026"

[dependencies]
wasm = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "wasm"

fn report(w : World, label : String, ok : Bool) -> Unit {
  if ok {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "vt_i32", wasm::val_type_code(wasm::ValType::I32) == 127)
  report(w, "vt_v128", wasm::val_type_code(wasm::ValType::V128) == 123)
  report(w, "vt_ext", wasm::val_type_code(wasm::ValType::ExternRef) == 111)
  let vtf_i32 = match wasm::val_type_from_code(127) {
    Some(wasm::ValType::I32) => true
    _ => false
  }
  report(w, "vtf_i32", vtf_i32)
  let vtf_bad = match wasm::val_type_from_code(0) {
    None => true
    _ => false
  }
  report(w, "vtf_bad", vtf_bad)
  report(w, "vteq_t", wasm::val_type_equals(wasm::ValType::F64, wasm::ValType::F64))
  report(w, "vteq_f", !wasm::val_type_equals(wasm::ValType::I32, wasm::ValType::I64))
  report(w, "rt_fn", wasm::ref_type_code(wasm::RefType::FuncRef) == 112)
  let rtf_ext = match wasm::ref_type_from_code(111) {
    Some(wasm::RefType::ExternRef) => true
    _ => false
  }
  report(w, "rtf_ext", rtf_ext)
  let rtf_bad = match wasm::ref_type_from_code(127) {
    None => true
    _ => false
  }
  report(w, "rtf_bad", rtf_bad)
  report(w, "exp_mem", wasm::export_kind_code(wasm::ExportKind::Memory) == 2)
  report(w, "vid_fn", wasm::val_type_to_id(wasm::ValType::FuncRef) == 5)
  report(w, "rid_ext", wasm::ref_type_to_id(wasm::RefType::ExternRef) == 6)
  report(w, "isref_5", wasm::is_ref_id(5))
  report(w, "isref_0", !wasm::is_ref_id(0))
  report(w, "sec_elem", wasm::section_order_rank(9) == 9)
  report(w, "sec_dc", wasm::section_order_rank(12) == 10)
  report(w, "sec_code", wasm::section_order_rank(10) == 11)
  report(w, "sec_data", wasm::section_order_rank(11) == 12)
  report(w, "sec_cust", wasm::section_order_rank(0) == -1)
  report(w, "stk_eq", wasm::stack_type_compat(0, 0))
  report(w, "stk_unk", wasm::stack_type_compat(-1, 3))
  report(w, "stk_ne", !wasm::stack_type_compat(0, 1))
  report(w, "lim_ok", wasm::limits_err_code(wasm::Limits::{ min: 1L, max: Some(10L), is_memory64: false, shared: false }, 65536L) == 0)
  report(w, "lim_sh", wasm::limits_err_code(wasm::Limits::{ min: 1L, max: None, is_memory64: false, shared: true }, 65536L) == 1)
  report(w, "lim_m64", wasm::limits_err_code(wasm::Limits::{ min: 1L, max: None, is_memory64: true, shared: false }, 65536L) == 2)
  report(w, "lim_neg", wasm::limits_err_code(wasm::Limits::{ min: -1L, max: None, is_memory64: false, shared: false }, 65536L) == 3)
  report(w, "lim_min_hi", wasm::limits_err_code(wasm::Limits::{ min: 70000L, max: None, is_memory64: false, shared: false }, 65536L) == 4)
  report(w, "lim_gt", wasm::limits_err_code(wasm::Limits::{ min: 10L, max: Some(5L), is_memory64: false, shared: false }, 65536L) == 5)
  report(w, "lim_max_hi", wasm::limits_err_code(wasm::Limits::{ min: 1L, max: Some(70000L), is_memory64: false, shared: false }, 65536L) == 6)
  report(w, "leb_sb_pos", wasm::leb128_i32_single_byte(63) == 63)
  report(w, "leb_sb_neg", wasm::leb128_i32_single_byte(64) == -64)
  report(w, "leb_u32_ok", wasm::leb128_u32_5th_valid(15))
  report(w, "leb_u32_bad", !wasm::leb128_u32_5th_valid(16))
  report(w, "leb_u64_ok", wasm::leb128_u64_10th_valid(1))
  report(w, "leb_u64_bad", !wasm::leb128_u64_10th_valid(2))
  report(w, "leb_i32_pos", wasm::leb128_i32_5th_valid(7))
  report(w, "leb_i32_neg", wasm::leb128_i32_5th_valid(120))
  report(w, "leb_i32_bad", !wasm::leb128_i32_5th_valid(8))
  report(w, "leb_i64_ok", wasm::leb128_i64_10th_valid(127))
  report(w, "leb_i64_bad", !wasm::leb128_i64_10th_valid(1))
  report(w, "leb_s33_pos", wasm::leb128_s33_5th_valid(15))
  report(w, "leb_s33_neg", wasm::leb128_s33_5th_valid(112))
  report(w, "leb_s33_bad", !wasm::leb128_s33_5th_valid(16))
  0
}
EOF
NATIVE_DIFF="$WORK/wasm_native_diff.txt"
pionc build "$DIFF_DIR" -o "$DIFF_DIR/wasm_diff_bin"
"$DIFF_DIR/wasm_diff_bin" > "$NATIVE_DIFF"
diff -u "$NATIVE_DIFF" "$LEAN_DIFF"
COUNT=$(wc -l < "$LEAN_DIFF" | tr -d ' ')
echo "Native vs Lean differential: $COUNT cases identical (diff -u exit 0)"
echo "PASS: packages/wasm Lean 4 proofs"
