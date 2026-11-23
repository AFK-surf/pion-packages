#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/crypto.
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

lean_lib Crypto where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib CryptoProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/crypto ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/CryptoProofs" "${PROJ_DIR}/CryptoProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/CryptoProofs" "${PROJ_DIR}/CryptoProofs"
cp "${SCRIPT_DIR}/CryptoProofs.lean" "${PROJ_DIR}/CryptoProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/CryptoProofs.lean" "${SCRIPT_DIR}/CryptoProofs/" "${SCRIPT_DIR}/CheckAxioms.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden token found in Lean proofs!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Crypto.Types Crypto.Funs CryptoProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Crypto.Types Crypto.Funs CryptoProofs)

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
DIFF_DIR="$(mktemp -d /tmp/crypto-native-diff.XXXXXX)"
trap 'rm -rf "${DIFF_DIR}"; kill -- -$$ 2>/dev/null || true' EXIT

cat > "${DIFF_DIR}/pion.toml" <<EOF
[package]
name = "crypto_diff_harness"
version = "0.1.0"
edition = "2026"

[dependencies]
crypto = { path = "${PKG_DIR}" }
EOF

mkdir -p "${DIFF_DIR}/src"
cat > "${DIFF_DIR}/src/main.pion" <<'EOF'
import "crypto"

fn cb(w : World, label : String, got : Bool, exp : Bool) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn ci(w : World, label : String, got : Int, exp : Int) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn ci64(w : World, label : String, got : Int64, exp : Int64) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn cu32(w : World, label : String, got : UInt, exp : UInt) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn main(w : World) -> Unit {
  let feA = crypto::Fe::{ h0: 1L, h1: 2L, h2: 3L, h3: 4L, h4: 5L, h5: 6L, h6: 7L, h7: 8L, h8: 9L, h9: 10L }
  let feB = crypto::Fe::{ h0: 11L, h1: 12L, h2: 13L, h3: 14L, h4: 15L, h5: 16L, h6: 17L, h7: 18L, h8: 19L, h9: 20L }
  ci(w, "ctd_eq", crypto::ct_diff_acc(0, 42, 42), 0)
  ci(w, "ctd_ne", crypto::ct_diff_acc(0, 42, 43), 1)
  ci(w, "ctd_latch", crypto::ct_diff_acc(4, 99, 99), 4)
  ci(w, "ctd_both", crypto::ct_diff_acc(4, 1, 2), 7)
  ci64(w, "cmov_0", crypto::fe_cmov(feA, feB, 0L).h0, 1L)
  ci64(w, "cmov_1", crypto::fe_cmov(feA, feB, 1L).h0, 11L)
  ci64(w, "cmov_h9", crypto::fe_cmov(feA, feB, 1L).h9, 20L)
  let (s0a, _) = crypto::fe_cswap_pair(feA, feB, 0L)
  let (s1a, s1b) = crypto::fe_cswap_pair(feA, feB, 1L)
  ci64(w, "cswap_0a", s0a.h0, 1L)
  ci64(w, "cswap_1a", s1a.h0, 11L)
  ci64(w, "cswap_1b", s1b.h9, 10L)
  ci64(w, "feadd_h0", crypto::fe_add(feA, feB).h0, 12L)
  ci64(w, "feadd_h4", crypto::fe_add(feA, feB).h4, 20L)
  ci64(w, "feadd_h9", crypto::fe_add(feA, feB).h9, 30L)
  ci64(w, "feadd_ba", crypto::fe_add(feB, feA).h0, 12L)
  ci(w, "xlo_0", crypto::x25519_clamp_low_byte(0), 0)
  ci(w, "xlo_7", crypto::x25519_clamp_low_byte(7), 0)
  ci(w, "xlo_ff", crypto::x25519_clamp_low_byte(255), 248)
  ci(w, "xhi_0", crypto::x25519_clamp_high_byte(0), 64)
  ci(w, "xhi_ff", crypto::x25519_clamp_high_byte(255), 127)
  ci(w, "xhi_80", crypto::x25519_clamp_high_byte(128), 64)
  cu32(w, "rot_16", crypto::cc_rotl32(0x12345678U, 16U), 0x56781234U)
  cu32(w, "rot_12", crypto::cc_rotl32(0x12345678U, 12U), 0x45678123U)
  cu32(w, "rot_8", crypto::cc_rotl32(0x12345678U, 8U), 0x34567812U)
  cu32(w, "rot_7", crypto::cc_rotl32(0x80000001U, 7U), 0x000000C0U)
  cb(w, "ck_32", crypto::chacha20_is_valid_key_len(32), true)
  cb(w, "ck_16", crypto::chacha20_is_valid_key_len(16), false)
  cb(w, "cn_12", crypto::chacha20_is_valid_nonce_len(12), true)
  cb(w, "cn_8", crypto::chacha20_is_valid_nonce_len(8), false)
  cb(w, "ct_16", crypto::chacha20_is_valid_ct_len(16), true)
  cb(w, "ct_15", crypto::chacha20_is_valid_ct_len(15), false)
  cb(w, "h256_ok", crypto::hkdf_sha256_valid_len(8160), true)
  cb(w, "h256_hi", crypto::hkdf_sha256_valid_len(8161), false)
  cb(w, "h256_neg", crypto::hkdf_sha256_valid_len(-1), false)
  ci(w, "h256_b1", crypto::hkdf_sha256_blocks(1), 1)
  ci(w, "h256_b255", crypto::hkdf_sha256_blocks(8160), 255)
  cb(w, "h512_ok", crypto::hkdf_sha512_valid_len(16320), true)
  cb(w, "h512_hi", crypto::hkdf_sha512_valid_len(16321), false)
  ci(w, "h512_b1", crypto::hkdf_sha512_blocks(1), 1)
  ci(w, "h512_b2", crypto::hkdf_sha512_blocks(65), 2)
  ci(w, "h512_b255", crypto::hkdf_sha512_blocks(16320), 255)
  ci(w, "hx_0", crypto::hex_nibble_val(48), 0)
  ci(w, "hx_a", crypto::hex_nibble_val(97), 10)
  ci(w, "hx_F", crypto::hex_nibble_val(70), 15)
  ci(w, "hx_bad", crypto::hex_nibble_val(71), -1)
}
EOF

PION_CACHE_DIR="${DIFF_DIR}/pion-cache" pionc build -o "${DIFF_DIR}/diff_bin" "${DIFF_DIR}"
"${DIFF_DIR}/diff_bin" > "${DIFF_DIR}/native.out"
printf '%s\n' "${EVAL_OUT}" > "${DIFF_DIR}/lean.out"
diff -u "${DIFF_DIR}/native.out" "${DIFF_DIR}/lean.out"
CASE_COUNT="$(wc -l < "${DIFF_DIR}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/crypto Lean 4 proofs"
