#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/resp.
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
  mkdir -p "${PROJ_DIR}/.deps"
  ln -s /private/tmp/pion-lean-semver/aeneas/backends/lean "${PROJ_DIR}/.deps/aeneas"
fi

rm -f "${PROJ_DIR}/lakefile.toml"
cat > "${PROJ_DIR}/lakefile.lean" <<EOF
import Lake
open Lake DSL

require aeneas from "./.deps/aeneas"

package «pionlean» where
  leanOptions := #[⟨\`weak.linter.dupNamespace, false⟩]

@[default_target] lean_lib PionLean

lean_lib Resp where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib RespProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/resp ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/RespProofs" "${PROJ_DIR}/RespProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/RespProofs" "${PROJ_DIR}/RespProofs"
cp "${SCRIPT_DIR}/RespProofs.lean" "${PROJ_DIR}/RespProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/RespProofs" "${SCRIPT_DIR}/RespProofs.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden tactic/axiom found!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Resp.Types Resp.Funs RespProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Resp.Types Resp.Funs RespProofs)

echo "=== [5/7] CheckAxioms (standard axioms only) ==="
AXIOM_OUT="$(cd "${PROJ_DIR}" && lake env lean --memory="${LEAN_MEM_LIMIT}" CheckAxioms.lean 2>&1)"
echo "${AXIOM_OUT}"
if echo "${AXIOM_OUT}" | grep -iE 'sorryAx|error:|warning:'; then
  echo "ERROR: non-standard axiom, error, or warning in CheckAxioms!" >&2
  exit 1
fi
THM_COUNT="$(echo "${AXIOM_OUT}" | grep -c "depends on axioms:")"
if [ "${THM_COUNT}" -ne 24 ]; then
  echo "ERROR: expected 24 theorems in CheckAxioms, got ${THM_COUNT}" >&2
  exit 1
fi
echo "CheckAxioms: ${THM_COUNT} theorems verified, standard axioms only"

echo "=== [6/7] Lean EvalDiff ==="
LEAN_OUT="$(cd "${PROJ_DIR}" && lake env lean --memory="${LEAN_MEM_LIMIT}" EvalDiff.lean 2>&1)"
echo "${LEAN_OUT}"
if echo "${LEAN_OUT}" | grep -E 'FAIL|error:|warning:'; then
  echo "ERROR: EvalDiff reported FAIL, error, or warning!" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_TMP="$(mktemp -d /tmp/resp_diff.XXXXXX)"
trap 'rm -rf "${DIFF_TMP}"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM
mkdir -p "${DIFF_TMP}/src" "${DIFF_TMP}/cache"

cat > "${DIFF_TMP}/pion.toml" <<EOF
[package]
name = "resp_diff_runner"
version = "0.1.0"

[dependencies]
resp = { path = "${PKG_DIR}" }
EOF

cat > "${DIFF_TMP}/src/main.pion" <<'EOF'
import "resp"

fn emit_b(w : World, label : String, got : Bool, exp : Bool) -> Unit {
  if got == exp {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

fn emit_i(w : World, label : String, got : Int, exp : Int) -> Unit {
  if got == exp {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  let ld = resp::RespLimits::default()
  emit_i(w, "lim_def_d", ld.max_depth, 128)
  emit_i(w, "lim_def_b", ld.max_bulk_len, 67108864)
  emit_i(w, "lim_def_il", ld.max_inline_len, 65536)
  let lw = resp::RespLimits::new(64, 1024, 100, 1024, 500).with_max_inline_len(4096)
  emit_i(w, "lim_wil", lw.max_inline_len, 4096)
  emit_i(w, "eff_slack", resp::effective_max_buffer_bytes(resp::RespLimits::new(64, 1000, 100, 1000, 500)), 1016)
  emit_i(w, "eff_keep", resp::effective_max_buffer_bytes(resp::RespLimits::new(64, 1000, 100, 2000, 500)), 2000)
  emit_i(w, "eff_small", resp::effective_max_buffer_bytes(resp::RespLimits::new(64, 1000, 100, 500, 500)), 500)
  emit_b(w, "pfx_plus", resp::is_resp_prefix(43), true)
  emit_b(w, "pfx_dollar", resp::is_resp_prefix(36), true)
  emit_b(w, "pfx_star", resp::is_resp_prefix(42), true)
  emit_b(w, "pfx_tilde", resp::is_resp_prefix(126), true)
  emit_b(w, "pfx_pipe", resp::is_resp_prefix(124), true)
  emit_b(w, "pfx_gt", resp::is_resp_prefix(62), true)
  emit_b(w, "pfx_P", resp::is_resp_prefix(80), false)
  emit_b(w, "pfx_sp", resp::is_resp_prefix(32), false)
  emit_b(w, "sp_sp", resp::is_inline_space(32), true)
  emit_b(w, "sp_vt", resp::is_inline_space(11), true)
  emit_b(w, "sp_cr", resp::is_inline_space(13), true)
  emit_b(w, "sp_a", resp::is_inline_space(97), false)
  emit_i(w, "hex_0", resp::hex_nibble(48), 0)
  emit_i(w, "hex_9", resp::hex_nibble(57), 9)
  emit_i(w, "hex_A", resp::hex_nibble(65), 10)
  emit_i(w, "hex_f", resp::hex_nibble(102), 15)
  emit_i(w, "hex_bad", resp::hex_nibble(122), -1)
  emit_b(w, "ovf_pos_ok", resp::i64_parse_will_overflow(922337203685477580L, 7L, false), false)
  emit_b(w, "ovf_pos_hi", resp::i64_parse_will_overflow(922337203685477580L, 8L, false), true)
  emit_b(w, "ovf_neg_ok", resp::i64_parse_will_overflow(-922337203685477580L, 8L, true), false)
  emit_b(w, "ovf_neg_lo", resp::i64_parse_will_overflow(-922337203685477580L, 9L, true), true)
  emit_i(w, "crc_0", resp::crc16_bit_step(0), 0)
  emit_i(w, "crc_msb", resp::crc16_bit_step(32768), 4129)
  emit_i(w, "crc_low", resp::crc16_bit_step(1234), 2468)
  emit_i(w, "crc_ffff", resp::crc16_bit_step(65535), 61407)
  emit_i(w, "slot_0", resp::crc16_to_slot(0), 0)
  emit_i(w, "slot_wrap", resp::crc16_to_slot(16384), 0)
  emit_i(w, "slot_ffff", resp::crc16_to_slot(65535), 16383)
  emit_b(w, "vslot_0", resp::is_valid_cluster_slot(0), true)
  emit_b(w, "vslot_max", resp::is_valid_cluster_slot(16383), true)
  emit_b(w, "vslot_neg", resp::is_valid_cluster_slot(-1), false)
  emit_b(w, "vslot_hi", resp::is_valid_cluster_slot(16384), false)
  emit_b(w, "vran_ok", resp::is_valid_slot_range(0, 16383), true)
  emit_b(w, "vran_eq", resp::is_valid_slot_range(5461, 5461), true)
  emit_b(w, "vran_rev", resp::is_valid_slot_range(100, 99), false)
  emit_b(w, "vran_neg", resp::is_valid_slot_range(-1, 10), false)
  emit_b(w, "vran_hi", resp::is_valid_slot_range(0, 16384), false)
  0
}
EOF

PION_CACHE_DIR="${DIFF_TMP}/cache" pionc build "${DIFF_TMP}" -o "${DIFF_TMP}/runner" >/dev/null
"${DIFF_TMP}/runner" > "${DIFF_TMP}/native.out"
printf '%s\n' "${LEAN_OUT}" > "${DIFF_TMP}/lean.out"

diff -u "${DIFF_TMP}/lean.out" "${DIFF_TMP}/native.out"
CASE_COUNT="$(wc -l < "${DIFF_TMP}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/resp Lean 4 proofs"
