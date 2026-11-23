#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/regex.
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

lean_lib Regex where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib RegexProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/regex ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/RegexProofs" "${PROJ_DIR}/RegexProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/RegexProofs" "${PROJ_DIR}/RegexProofs"
cp "${SCRIPT_DIR}/RegexProofs.lean" "${PROJ_DIR}/RegexProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/RegexProofs.lean" "${SCRIPT_DIR}/RegexProofs/" "${SCRIPT_DIR}/CheckAxioms.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden token found in Lean proofs!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Regex.Types Regex.Funs RegexProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Regex.Types Regex.Funs RegexProofs)

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
DIFF_DIR="$(mktemp -d /tmp/regex-native-diff.XXXXXX)"
trap 'rm -rf "${DIFF_DIR}"; kill -- -$$ 2>/dev/null || true' EXIT

cat > "${DIFF_DIR}/pion.toml" <<EOF
[package]
name = "regex_diff_harness"
version = "0.1.0"
edition = "2026"

[dependencies]
regex = { path = "${PKG_DIR}" }
EOF

mkdir -p "${DIFF_DIR}/src"
cat > "${DIFF_DIR}/src/main.pion" <<'EOF'
import "regex"

fn cb(w : World, label : String, got : Bool, exp : Bool) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn ci(w : World, label : String, got : Int, exp : Int) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn ci64(w : World, label : String, got : Int64, exp : Int64) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn lk_id(lk : regex::LookKind) -> Int {
  match lk {
    regex::LookKind::StartText => 0
    regex::LookKind::EndText => 1
    regex::LookKind::StartLine => 2
    regex::LookKind::EndLine => 3
    regex::LookKind::WordBoundaryAscii => 4
    regex::LookKind::NotWordBoundaryAscii => 5
    regex::LookKind::WordBoundaryUnicode => 6
    regex::LookKind::NotWordBoundaryUnicode => 7
  }
}

fn clk(w : World, label : String, got : regex::LookKind, exp : regex::LookKind) -> Unit {
  ci(w, label, lk_id(got), lk_id(exp))
}

fn cr_inter(w : World, label : String, a : regex::CharRange, b : regex::CharRange, elo : Int, ehi : Int) -> Unit {
  let r = regex::char_range_intersect(a, b)
  if r.lo == elo && r.hi == ehi { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn main(w : World) -> Unit {
  cb(w, "lm_lf", regex::dfa_is_leftmost(regex::DfaMode::LeftmostFirst), true)
  cb(w, "lm_rev", regex::dfa_is_leftmost(regex::DfaMode::Reverse), false)
  cb(w, "lm_set", regex::dfa_is_leftmost(regex::DfaMode::SetAll), false)
  cb(w, "sa_set", regex::dfa_is_set_all(regex::DfaMode::SetAll), true)
  cb(w, "sa_lf", regex::dfa_is_set_all(regex::DfaMode::LeftmostFirst), false)
  cb(w, "lk_st", regex::dfa_look_holds(regex::LookKind::StartText, true, false, false, false, false, false), true)
  cb(w, "lk_sl", regex::dfa_look_holds(regex::LookKind::StartLine, false, true, false, false, false, false), true)
  cb(w, "lk_et", regex::dfa_look_holds(regex::LookKind::EndText, false, false, false, false, false, true), true)
  cb(w, "lk_el_nl", regex::dfa_look_holds(regex::LookKind::EndLine, false, false, false, true, false, false), true)
  cb(w, "lk_el_no", regex::dfa_look_holds(regex::LookKind::EndLine, false, false, false, false, false, false), false)
  cb(w, "lk_wb_t", regex::dfa_look_holds(regex::LookKind::WordBoundaryAscii, false, false, true, false, false, false), true)
  cb(w, "lk_wb_f", regex::dfa_look_holds(regex::LookKind::WordBoundaryAscii, false, false, true, false, true, false), false)
  cb(w, "lk_nwb_t", regex::dfa_look_holds(regex::LookKind::NotWordBoundaryUnicode, false, false, false, false, false, false), true)
  clk(w, "rev_st", regex::reverse_look_kind(regex::LookKind::StartText), regex::LookKind::EndText)
  clk(w, "rev_et", regex::reverse_look_kind(regex::LookKind::EndText), regex::LookKind::StartText)
  clk(w, "rev_sl", regex::reverse_look_kind(regex::LookKind::StartLine), regex::LookKind::EndLine)
  clk(w, "rev_el", regex::reverse_look_kind(regex::LookKind::EndLine), regex::LookKind::StartLine)
  clk(w, "rev_wb", regex::reverse_look_kind(regex::LookKind::WordBoundaryUnicode), regex::LookKind::WordBoundaryUnicode)
  cb(w, "iswb_a", regex::look_is_word_boundary(regex::LookKind::WordBoundaryAscii), true)
  cb(w, "iswb_na", regex::look_is_word_boundary(regex::LookKind::NotWordBoundaryAscii), true)
  cb(w, "iswb_st", regex::look_is_word_boundary(regex::LookKind::StartText), false)
  cb(w, "op_ok", regex::onepass_can_compile(false, 31, 512), true)
  cb(w, "op_look", regex::onepass_can_compile(true, 2, 10), false)
  cb(w, "op_cap0", regex::onepass_can_compile(false, 0, 10), false)
  cb(w, "op_cap32", regex::onepass_can_compile(false, 32, 10), false)
  cb(w, "op_nfa", regex::onepass_can_compile(false, 2, 513), false)
  ci64(w, "opm_set0", regex::onepass_mask_add_slot(0L, 0, 4), 1L)
  ci64(w, "opm_set3", regex::onepass_mask_add_slot(1L, 3, 4), 9L)
  ci64(w, "opm_oob", regex::onepass_mask_add_slot(5L, 4, 4), 5L)
  ci64(w, "opm_neg", regex::onepass_mask_add_slot(5L, -1, 4), 5L)
  cb(w, "cap_ok", regex::captures_slot_valid(0, 2), true)
  cb(w, "cap_hi", regex::captures_slot_valid(1, 2), false)
  cb(w, "cap_odd", regex::captures_slot_valid(1, 3), false)
  cb(w, "cap_neg", regex::captures_slot_valid(-1, 6), false)
  cb(w, "cr_le1", regex::char_range_le(regex::CharRange::{ lo: 10, hi: 20 }, regex::CharRange::{ lo: 10, hi: 25 }), true)
  cb(w, "cr_le2", regex::char_range_le(regex::CharRange::{ lo: 11, hi: 12 }, regex::CharRange::{ lo: 10, hi: 99 }), false)
  cr_inter(w, "cr_int1", regex::CharRange::{ lo: 10, hi: 30 }, regex::CharRange::{ lo: 20, hi: 40 }, 20, 30)
  cr_inter(w, "cr_int2", regex::CharRange::{ lo: 10, hi: 15 }, regex::CharRange::{ lo: 20, hi: 40 }, 20, 15)
  cb(w, "u8c_80", regex::is_utf8_cont_byte(128), true)
  cb(w, "u8c_bf", regex::is_utf8_cont_byte(191), true)
  cb(w, "u8c_c0", regex::is_utf8_cont_byte(192), false)
  ci(w, "u8l_1", regex::utf8_lead_len(65), 1)
  ci(w, "u8l_4", regex::utf8_lead_len(240), 4)
  ci(w, "hx_f", regex::hex_val(102), 15)
}
EOF

PION_CACHE_DIR="${DIFF_DIR}/pion-cache" pionc build -o "${DIFF_DIR}/diff_bin" "${DIFF_DIR}"
"${DIFF_DIR}/diff_bin" > "${DIFF_DIR}/native.out"
printf '%s\n' "${EVAL_OUT}" > "${DIFF_DIR}/lean.out"
diff -u "${DIFF_DIR}/native.out" "${DIFF_DIR}/lean.out"
CASE_COUNT="$(wc -l < "${DIFF_DIR}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/regex Lean 4 proofs"
