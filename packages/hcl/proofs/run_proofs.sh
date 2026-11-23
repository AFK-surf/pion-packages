#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/hcl.
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

lean_lib Hcl where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib HclProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/hcl ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/HclProofs" "${PROJ_DIR}/HclProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/HclProofs" "${PROJ_DIR}/HclProofs"
cp "${SCRIPT_DIR}/HclProofs.lean" "${PROJ_DIR}/HclProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/HclProofs" "${SCRIPT_DIR}/HclProofs.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden tactic/axiom found!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Hcl.Types Hcl.Funs HclProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Hcl.Types Hcl.Funs HclProofs)

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
DIFF_TMP="$(mktemp -d /tmp/hcl_diff.XXXXXX)"
trap 'rm -rf "${DIFF_TMP}"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM
mkdir -p "${DIFF_TMP}/src" "${DIFF_TMP}/cache"

cat > "${DIFF_TMP}/pion.toml" <<EOF
[package]
name = "hcl_diff_runner"
version = "0.1.0"

[dependencies]
hcl = { path = "${PKG_DIR}" }
EOF

cat > "${DIFF_TMP}/src/main.pion" <<'EOF'
import "hcl"

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

fn emit_i64(w : World, label : String, got : Int64, exp : Int64) -> Unit {
  if got == exp {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  emit_i(w, "dep_neg", hcl::hcl_effective_max_depth(-5), 1)
  emit_i(w, "dep_0", hcl::hcl_effective_max_depth(0), 1)
  emit_i(w, "dep_1", hcl::hcl_effective_max_depth(1), 1)
  emit_i(w, "dep_128", hcl::hcl_effective_max_depth(128), 128)
  emit_i(w, "dep_160", hcl::hcl_effective_max_depth(160), 160)
  emit_i(w, "dep_999", hcl::hcl_effective_max_depth(999), 160)
  let ld = hcl::HclLimits::default()
  emit_i(w, "lim_def_d", ld.max_depth, 128)
  emit_i64(w, "lim_def_s", ld.max_steps, 1000000L)
  let ln = hcl::HclLimits::new(32, 500L, 4096)
  emit_i(w, "lim_new_o", ln.max_output_bytes, 4096)
  emit_i(w, "pos_z_l", hcl::Pos::zero().line, 1)
  emit_i(w, "span_z_c", hcl::Span::zero().end.column, 1)
  emit_i(w, "pos_new_o", hcl::Pos::new(3, 7, 42).offset, 42)
  let sp = hcl::Span::new(hcl::Pos::new(1, 1, 0), hcl::Pos::new(2, 5, 20))
  emit_i(w, "span_new_l", sp.end.line, 2)
  emit_b(w, "ids_A", hcl::is_hcl_ident_start(65), true)
  emit_b(w, "ids_us", hcl::is_hcl_ident_start(95), true)
  emit_b(w, "ids_utf8", hcl::is_hcl_ident_start(200), true)
  emit_b(w, "ids_5", hcl::is_hcl_ident_start(53), false)
  emit_b(w, "idc_5", hcl::is_hcl_ident_cont(53), true)
  emit_b(w, "idc_dash", hcl::is_hcl_ident_cont(45), true)
  emit_b(w, "idc_sp", hcl::is_hcl_ident_cont(32), false)
  emit_b(w, "dig_0", hcl::is_hcl_digit(48), true)
  emit_b(w, "dig_9", hcl::is_hcl_digit(57), true)
  emit_b(w, "dig_a", hcl::is_hcl_digit(97), false)
  emit_i(w, "hex_0", hcl::hcl_hex_val(48), 0)
  emit_i(w, "hex_A", hcl::hcl_hex_val(65), 10)
  emit_i(w, "hex_f", hcl::hcl_hex_val(102), 15)
  emit_i(w, "hex_bad", hcl::hcl_hex_val(120), -1)
  emit_b(w, "usp_sp", hcl::is_unicode_space(32), true)
  emit_b(w, "usp_tab", hcl::is_unicode_space(9), true)
  emit_b(w, "usp_nbsp", hcl::is_unicode_space(160), true)
  emit_b(w, "usp_em", hcl::is_unicode_space(8195), true)
  emit_b(w, "usp_ideog", hcl::is_unicode_space(12288), true)
  emit_b(w, "usp_A", hcl::is_unicode_space(65), false)
  emit_i(w, "lo_A", hcl::unicode_cp_to_lower(65), 97)
  emit_i(w, "lo_lat1", hcl::unicode_cp_to_lower(192), 224)
  emit_i(w, "lo_Idot", hcl::unicode_cp_to_lower(304), 105)
  emit_i(w, "lo_greek", hcl::unicode_cp_to_lower(913), 945)
  emit_i(w, "lo_cyril", hcl::unicode_cp_to_lower(1040), 1072)
  emit_i(w, "lo_fw", hcl::unicode_cp_to_lower(65313), 65345)
  emit_i(w, "up_a", hcl::unicode_cp_to_upper(97), 65)
  emit_i(w, "up_lat1", hcl::unicode_cp_to_upper(224), 192)
  emit_i(w, "up_ydier", hcl::unicode_cp_to_upper(255), 376)
  emit_i(w, "up_fsig", hcl::unicode_cp_to_upper(962), 931)
  emit_i(w, "up_fw", hcl::unicode_cp_to_upper(65345), 65313)
  0
}
EOF

PION_CACHE_DIR="${DIFF_TMP}/cache" pionc build "${DIFF_TMP}" -o "${DIFF_TMP}/runner" >/dev/null
"${DIFF_TMP}/runner" > "${DIFF_TMP}/native.out"
printf '%s\n' "${LEAN_OUT}" > "${DIFF_TMP}/lean.out"

diff -u "${DIFF_TMP}/lean.out" "${DIFF_TMP}/native.out"
CASE_COUNT="$(wc -l < "${DIFF_TMP}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/hcl Lean 4 proofs"
