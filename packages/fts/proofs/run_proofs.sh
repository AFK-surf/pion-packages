#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/fts.
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

lean_lib Fts where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib FtsProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/fts ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/FtsProofs" "${PROJ_DIR}/FtsProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/FtsProofs" "${PROJ_DIR}/FtsProofs"
cp "${SCRIPT_DIR}/FtsProofs.lean" "${PROJ_DIR}/FtsProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/FtsProofs.lean" "${SCRIPT_DIR}/FtsProofs/" "${SCRIPT_DIR}/CheckAxioms.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden token found in Lean proofs!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Fts.Types Fts.Funs FtsProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Fts.Types Fts.Funs FtsProofs)

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
DIFF_DIR="$(mktemp -d /tmp/fts-native-diff.XXXXXX)"
trap 'rm -rf "${DIFF_DIR}"; kill -- -$$ 2>/dev/null || true' EXIT

cat > "${DIFF_DIR}/pion.toml" <<EOF
[package]
name = "fts_diff_harness"
version = "0.1.0"
edition = "2026"

[dependencies]
fts = { path = "${PKG_DIR}" }
EOF

mkdir -p "${DIFF_DIR}/src"
cat > "${DIFF_DIR}/src/main.pion" <<'EOF'
import "fts"

fn cb(w : World, label : String, got : Bool, exp : Bool) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn ci(w : World, label : String, got : Int, exp : Int) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn main(w : World) -> Unit {
  ci(w, "san_neg", fts::sanitize_scalar(-5), 65533)
  ci(w, "san_sur", fts::sanitize_scalar(55296), 65533)
  ci(w, "san_hi", fts::sanitize_scalar(1114112), 65533)
  ci(w, "san_ok", fts::sanitize_scalar(20013), 20013)
  ci(w, "u8l_1", fts::cp_utf8_len(65), 1)
  ci(w, "u8l_2", fts::cp_utf8_len(233), 2)
  ci(w, "u8l_3", fts::cp_utf8_len(20013), 3)
  ci(w, "u8l_4", fts::cp_utf8_len(128512), 4)
  ci(w, "u8l_sur", fts::cp_utf8_len(56000), 3)
  ci(w, "fa_A", fts::fold_ascii_cp(65), 97)
  ci(w, "fa_a", fts::fold_ascii_cp(97), 97)
  ci(w, "fg_sig", fts::fold_greek_cyrillic(962), 963)
  ci(w, "fg_3a2", fts::fold_greek_cyrillic(930), -1)
  ci(w, "fg_cyrA", fts::fold_greek_cyrillic(1040), 1072)
  ci(w, "fg_cyr0", fts::fold_greek_cyrillic(1024), 1104)
  ci(w, "fg_bad", fts::fold_greek_cyrillic(65), -1)
  cb(w, "cjk_han", fts::is_cjk_cp(20013), true)
  cb(w, "cjk_rt2a", fts::is_cjk_cp(12441), false)
  cb(w, "cjk_rt2b", fts::is_cjk_cp(12448), false)
  cb(w, "cjk_rt2c", fts::is_cjk_cp(12539), false)
  cb(w, "cjk_asc", fts::is_cjk_cp(65), false)
  cb(w, "aw_u", fts::is_ascii_word_cp(95), true)
  cb(w, "aw_sp", fts::is_ascii_word_cp(32), false)
  cb(w, "up_Z", fts::is_upper_cp(90), true)
  cb(w, "lo_a", fts::is_lower_cp(97), true)
  cb(w, "dg_5", fts::is_digit_cp(53), true)
  cb(w, "cam_aB", fts::camel_should_split(97, 66, false), true)
  cb(w, "cam_ABc", fts::camel_should_split(65, 66, true), true)
  cb(w, "cam_ABC", fts::camel_should_split(65, 66, false), false)
  cb(w, "cam_ab", fts::camel_should_split(97, 98, false), false)
  ci(w, "nws_nl", fts::snippet_normalize_ws(10), 32)
  ci(w, "nws_tb", fts::snippet_normalize_ws(9), 32)
  ci(w, "nws_A", fts::snippet_normalize_ws(65), 65)
  ci(w, "ctx_120", fts::snippet_context_before(120), 16)
  ci(w, "ctx_20", fts::snippet_context_before(20), 5)
  ci(w, "we_ok", fts::snippet_win_end(10, 100, 20), 30)
  ci(w, "we_rt3", fts::snippet_win_end(10, 100, 2147483647), 100)
  cb(w, "rg_gt", fts::snippet_range_gt(5, 8, 5, 6), true)
  cb(w, "rg_eq", fts::snippet_range_gt(5, 8, 5, 8), false)
  ci(w, "hc_ok_gt", fts::hit_tiebreak_cmp(20L, 5L, 10L, 1L), -1)
  ci(w, "hc_ok_lt", fts::hit_tiebreak_cmp(10L, 1L, 20L, 5L), 1)
  ci(w, "hc_id_lt", fts::hit_tiebreak_cmp(10L, 1L, 10L, 2L), -1)
  ci(w, "hc_id_gt", fts::hit_tiebreak_cmp(10L, 2L, 10L, 1L), 1)
  ci(w, "hc_eq", fts::hit_tiebreak_cmp(10L, 2L, 10L, 2L), 0)
}
EOF

PION_CACHE_DIR="${DIFF_DIR}/pion-cache" pionc build -o "${DIFF_DIR}/diff_bin" "${DIFF_DIR}"
"${DIFF_DIR}/diff_bin" > "${DIFF_DIR}/native.out"
printf '%s\n' "${EVAL_OUT}" > "${DIFF_DIR}/lean.out"
diff -u "${DIFF_DIR}/native.out" "${DIFF_DIR}/lean.out"
CASE_COUNT="$(wc -l < "${DIFF_DIR}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/fts Lean 4 proofs"
