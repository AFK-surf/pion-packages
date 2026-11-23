#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/jsonpath.
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

lean_lib Jsonpath where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib JsonpathProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/jsonpath ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/JsonpathProofs" "${PROJ_DIR}/JsonpathProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/JsonpathProofs" "${PROJ_DIR}/JsonpathProofs"
cp "${SCRIPT_DIR}/JsonpathProofs.lean" "${PROJ_DIR}/JsonpathProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/JsonpathProofs.lean" "${SCRIPT_DIR}/JsonpathProofs/" "${SCRIPT_DIR}/CheckAxioms.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden token found in Lean proofs!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Jsonpath.Types Jsonpath.Funs JsonpathProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Jsonpath.Types Jsonpath.Funs JsonpathProofs)

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
DIFF_DIR="$(mktemp -d /tmp/jsonpath-native-diff.XXXXXX)"
trap 'rm -rf "${DIFF_DIR}"; kill -- -$$ 2>/dev/null || true' EXIT

cat > "${DIFF_DIR}/pion.toml" <<EOF
[package]
name = "jsonpath_diff_harness"
version = "0.1.0"
edition = "2026"

[dependencies]
jsonpath = { path = "${PKG_DIR}" }
EOF

mkdir -p "${DIFF_DIR}/src"
cat > "${DIFF_DIR}/src/main.pion" <<'EOF'
import "jsonpath"

fn cb(w : World, label : String, got : Bool, exp : Bool) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn ci(w : World, label : String, got : Int, exp : Int) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn ci64(w : World, label : String, got : Int64, exp : Int64) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn main(w : World) -> Unit {
  let l = jsonpath::JsonPathLimits::default()
  ci(w, "lim_depth", l.max_depth, 128)
  ci(w, "lim_nodes", l.max_nodes_visited, 1000000)
  cb(w, "ws_sp", jsonpath::is_rfc9535_ws(32), true)
  cb(w, "ws_tab", jsonpath::is_rfc9535_ws(9), true)
  cb(w, "ws_lf", jsonpath::is_rfc9535_ws(10), true)
  cb(w, "ws_cr", jsonpath::is_rfc9535_ws(13), true)
  cb(w, "ws_vt", jsonpath::is_rfc9535_ws(11), false)
  cb(w, "nf_A", jsonpath::is_name_first(65), true)
  cb(w, "nf_us", jsonpath::is_name_first(95), true)
  cb(w, "nf_utf8", jsonpath::is_name_first(0x4E2D), true)
  cb(w, "nf_surr", jsonpath::is_name_first(0xD800), false)
  cb(w, "nf_hi", jsonpath::is_name_first(0x110000), false)
  cb(w, "nf_0", jsonpath::is_name_first(48), false)
  cb(w, "nc_0", jsonpath::is_name_char(48), true)
  cb(w, "ij_ok", jsonpath::rfc9535_ijson_step_overflow(900719925474099L, 1L), false)
  cb(w, "ij_ovf", jsonpath::rfc9535_ijson_step_overflow(900719925474099L, 2L), true)
  cb(w, "ij_0", jsonpath::rfc9535_ijson_step_overflow(0L, 9L), false)
  cb(w, "ij_big", jsonpath::rfc9535_ijson_step_overflow(900719925474100L, 0L), true)
  ci(w, "nbl_a", jsonpath::norm_name_byte_len(97), 1)
  ci(w, "nbl_sq", jsonpath::norm_name_byte_len(39), 2)
  ci(w, "nbl_lf", jsonpath::norm_name_byte_len(10), 2)
  ci(w, "nbl_nul", jsonpath::norm_name_byte_len(0), 6)
  cb(w, "pe_tilde", jsonpath::pointer_needs_escape(126), true)
  cb(w, "pe_slash", jsonpath::pointer_needs_escape(47), true)
  cb(w, "pe_a", jsonpath::pointer_needs_escape(97), false)
  ci(w, "pu_0", jsonpath::pointer_unescape_tilde(48), 126)
  ci(w, "pu_1", jsonpath::pointer_unescape_tilde(49), 47)
  ci(w, "pu_2", jsonpath::pointer_unescape_tilde(50), -1)
  ci64(w, "ni_pos", jsonpath::rfc9535_normalize_index(3L, 10L), 3L)
  ci64(w, "ni_neg", jsonpath::rfc9535_normalize_index(-2L, 10L), 8L)
  ci64(w, "ni_under", jsonpath::rfc9535_normalize_index(-15L, 10L), -5L)
  ci64(w, "ni_zero", jsonpath::rfc9535_normalize_index(0L, 5L), 0L)
  ci64(w, "ds_pos", jsonpath::rfc9535_default_slice_start(10L, 1L), 0L)
  ci64(w, "ds_neg", jsonpath::rfc9535_default_slice_start(10L, -1L), 9L)
  ci64(w, "de_pos", jsonpath::rfc9535_default_slice_end(10L, 1L), 10L)
  ci64(w, "de_neg", jsonpath::rfc9535_default_slice_end(10L, -1L), -11L)
  ci64(w, "cp_lo", jsonpath::rfc9535_clamp_pos_slice(-5L, 10L), 0L)
  ci64(w, "cp_mid", jsonpath::rfc9535_clamp_pos_slice(4L, 10L), 4L)
  ci64(w, "cp_hi", jsonpath::rfc9535_clamp_pos_slice(20L, 10L), 10L)
  ci64(w, "cp_emp", jsonpath::rfc9535_clamp_pos_slice(5L, 0L), 0L)
  ci64(w, "cn_lo", jsonpath::rfc9535_clamp_neg_slice(-5L, 10L), -1L)
  ci64(w, "cn_mid", jsonpath::rfc9535_clamp_neg_slice(4L, 10L), 4L)
  ci64(w, "cn_hi", jsonpath::rfc9535_clamp_neg_slice(20L, 10L), 9L)
  ci64(w, "cn_emp", jsonpath::rfc9535_clamp_neg_slice(5L, 0L), -1L)
}
EOF

PION_CACHE_DIR="${DIFF_DIR}/pion-cache" pionc build -o "${DIFF_DIR}/diff_bin" "${DIFF_DIR}"
"${DIFF_DIR}/diff_bin" > "${DIFF_DIR}/native.out"
printf '%s\n' "${EVAL_OUT}" > "${DIFF_DIR}/lean.out"
diff -u "${DIFF_DIR}/native.out" "${DIFF_DIR}/lean.out"
CASE_COUNT="$(wc -l < "${DIFF_DIR}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/jsonpath Lean 4 proofs"
