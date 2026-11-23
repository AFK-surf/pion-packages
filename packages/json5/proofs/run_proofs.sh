#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/json5.
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="${HOME}/.pion/bin:${HOME}/.elan/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LEAN_WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"
LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
PROJ_DIR="${LEAN_WORK}/proj"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas in ${LEAN_WORK} ==="
mkdir -p "${PROJ_DIR}"
if [ ! -d "${PROJ_DIR}/PionLean" ]; then
  if [ -d /private/tmp/pion-lean-ref/PionLean ]; then
    cp -R /private/tmp/pion-lean-ref/PionLean "${PROJ_DIR}/PionLean"
    cp /private/tmp/pion-lean-ref/PionLean.lean "${PROJ_DIR}/PionLean.lean"
  else
    echo "ERROR: PionLean reference missing" >&2
    exit 1
  fi
fi

if [ ! -e "${PROJ_DIR}/.deps/aeneas" ]; then
  if [ ! -d "${LEAN_WORK}/aeneas/backends/lean" ]; then
    rm -rf "${LEAN_WORK}/aeneas"
    git clone --filter=blob:none -q https://github.com/AeneasVerif/aeneas.git "${LEAN_WORK}/aeneas"
    git -C "${LEAN_WORK}/aeneas" checkout -q 1dc8ad31b1
  fi
  mkdir -p "${PROJ_DIR}/.deps"
  ln -sfn "${LEAN_WORK}/aeneas/backends/lean" "${PROJ_DIR}/.deps/aeneas"
fi

rm -f "${PROJ_DIR}/lakefile.toml"
cat > "${PROJ_DIR}/lakefile.lean" <<EOF
import Lake
open Lake DSL

require aeneas from "./.deps/aeneas"

package «pionlean» where
  leanOptions := #[⟨\`weak.linter.dupNamespace, false⟩]

@[default_target] lean_lib PionLean

lean_lib Json5 where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib Json5Proofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/json5 ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/Json5Proofs" "${PROJ_DIR}/Json5Proofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/Json5Proofs" "${PROJ_DIR}/Json5Proofs"
cp "${SCRIPT_DIR}/Json5Proofs.lean" "${PROJ_DIR}/Json5Proofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/Json5Proofs.lean" "${SCRIPT_DIR}/Json5Proofs/" "${SCRIPT_DIR}/CheckAxioms.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden token found in Lean proofs!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Json5.Types Json5.Funs Json5Proofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Json5.Types Json5.Funs Json5Proofs)

echo "=== [5/7] CheckAxioms (standard axioms only) ==="
AXIOMS_OUT="$(cd "${PROJ_DIR}" && lake env lean --memory="${LEAN_MEM_LIMIT}" -j "${LEAN_NUM_THREADS}" CheckAxioms.lean 2>&1)"
echo "${AXIOMS_OUT}"
if echo "${AXIOMS_OUT}" | grep -E 'sorryAx|Lean\.ofReduceBool|Lean\.trustCompiler|error:|warning:'; then
  echo "ERROR: non-standard axiom, error, or warning detected!" >&2
  exit 1
fi
THM_COUNT="$(echo "${AXIOMS_OUT}" | grep -c 'depends on axioms:' || true)"
if [ "${THM_COUNT}" -lt 24 ]; then
  echo "ERROR: expected at least 24 theorems in CheckAxioms, got ${THM_COUNT}" >&2
  exit 1
fi
echo "CheckAxioms: ${THM_COUNT} theorems verified, standard axioms only"

echo "=== [6/7] Lean EvalDiff (44 cases) ==="
EVAL_OUT="$(cd "${PROJ_DIR}" && lake env lean --memory="${LEAN_MEM_LIMIT}" -j "${LEAN_NUM_THREADS}" EvalDiff.lean 2>&1)"
echo "${EVAL_OUT}"
if echo "${EVAL_OUT}" | grep -E 'FAIL|error:|warning:'; then
  echo "ERROR: EvalDiff reported FAIL, error, or warning!" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_DIR="$(mktemp -d /tmp/json5-native-diff.XXXXXX)"
trap 'rm -rf "${DIFF_DIR}"; kill -- -$$ 2>/dev/null || true' EXIT

cat > "${DIFF_DIR}/pion.toml" <<EOF
[package]
name = "json5_diff_harness"
version = "0.1.0"
edition = "2026"

[dependencies]
json5 = { path = "${PKG_DIR}" }
EOF

mkdir -p "${DIFF_DIR}/src"
cat > "${DIFF_DIR}/src/main.pion" <<'EOF'
import "json5"

fn cb(w : World, label : String, got : Bool, exp : Bool) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn ci(w : World, label : String, got : Int, exp : Int) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn cu64(w : World, label : String, got : UInt64, exp : UInt64) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn main(w : World) -> Unit {
  cb(w, "hs_ok", json5::is_high_surrogate(55357), true)
  cb(w, "hs_lo", json5::is_high_surrogate(56320), false)
  cb(w, "ls_ok", json5::is_low_surrogate(56832), true)
  cb(w, "ls_hi", json5::is_low_surrogate(55296), false)
  ci(w, "sp_min", json5::decode_surrogate_pair(55296, 56320), 65536)
  ci(w, "sp_max", json5::decode_surrogate_pair(56319, 57343), 1114111)
  ci(w, "sp_emo", json5::decode_surrogate_pair(55357, 56832), 128512)
  ci(w, "hx4_0", json5::pack_hex4(0, 0, 4, 1), 65)
  ci(w, "hx4_f", json5::pack_hex4(15, 15, 15, 15), 65535)
  ci(w, "hx2_a", json5::pack_hex2(10, 5), 165)
  ci(w, "hx2_f", json5::pack_hex2(15, 15), 255)
  cb(w, "uws_ls", json5::is_unicode_j5_ws(8232), true)
  cb(w, "uws_ps", json5::is_unicode_j5_ws(8233), true)
  cb(w, "uws_bom", json5::is_unicode_j5_ws(65279), true)
  cb(w, "uws_sp", json5::is_unicode_j5_ws(32), false)
  cb(w, "u8c_ok", json5::is_utf8_cont(128), true)
  cb(w, "u8c_no", json5::is_utf8_cont(192), false)
  cb(w, "u8_3_ok", json5::utf8_valid_3byte(228, 184, 173), true)
  cb(w, "u8_3_ov", json5::utf8_valid_3byte(224, 159, 128), false)
  cb(w, "u8_3_sr", json5::utf8_valid_3byte(237, 160, 128), false)
  cb(w, "u8_4_ok", json5::utf8_valid_4byte(240, 159, 152, 128), true)
  cb(w, "u8_4_ov", json5::utf8_valid_4byte(240, 143, 128, 128), false)
  cb(w, "u8_4_hi", json5::utf8_valid_4byte(244, 144, 128, 128), false)
  cu64(w, "hnz_0", json5::hash_ensure_nonzero(0UL), 1UL)
  cu64(w, "hnz_7", json5::hash_ensure_nonzero(7UL), 7UL)
  cu64(w, "sm64_0", json5::splitmix64(0UL), 16294208416658607535UL)
  cb(w, "hgr_no", json5::hash_needs_grow(19, 32), false)
  cb(w, "hgr_yes", json5::hash_needs_grow(20, 32), true)
  cb(w, "hgr_ful", json5::hash_needs_grow(32, 32), true)
  ci(w, "hns_0", json5::hash_next_slot(0, 31), 1)
  ci(w, "hns_w", json5::hash_next_slot(31, 31), 0)
  ci(w, "pe_til", json5::pointer_escape_suffix(126), 48)
  ci(w, "pe_sl", json5::pointer_escape_suffix(47), 49)
  ci(w, "pe_a", json5::pointer_escape_suffix(97), -1)
  ci(w, "pu_0", json5::pointer_unescape_byte(48), 126)
  ci(w, "pu_1", json5::pointer_unescape_byte(49), 47)
  ci(w, "pu_2", json5::pointer_unescape_byte(50), -1)
  cb(w, "je_q", json5::json_needs_escape_ascii(34), true)
  cb(w, "je_bs", json5::json_needs_escape_ascii(92), true)
  cb(w, "je_nl", json5::json_needs_escape_ascii(10), true)
  cb(w, "je_a", json5::json_needs_escape_ascii(97), false)
  ci(w, "lut_sp", json5::ascii_lut_flags(32), 3)
  ci(w, "lut_A", json5::ascii_lut_flags(65), 12)
  ci(w, "lut_0", json5::ascii_lut_flags(48), 24)
}
EOF

PION_CACHE_DIR="${DIFF_DIR}/pion-cache" pionc build -o "${DIFF_DIR}/diff_bin" "${DIFF_DIR}"
"${DIFF_DIR}/diff_bin" > "${DIFF_DIR}/native.out"
printf '%s\n' "${EVAL_OUT}" > "${DIFF_DIR}/lean.out"
diff -u "${DIFF_DIR}/native.out" "${DIFF_DIR}/lean.out"
CASE_COUNT="$(wc -l < "${DIFF_DIR}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/json5 Lean 4 proofs"
