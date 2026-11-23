#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/csp.
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="${HOME}/.pion/bin:${HOME}/.elan/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$PKG_DIR/../.." && pwd)"

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

lean_lib Csp where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib CspProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/csp ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/CspProofs" "${PROJ_DIR}/CspProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/CspProofs" "${PROJ_DIR}/CspProofs"
cp "${SCRIPT_DIR}/CspProofs.lean" "${PROJ_DIR}/CspProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/CspProofs" "${SCRIPT_DIR}/CspProofs.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden tactic/axiom found!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Csp.Types Csp.Funs CspProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Csp.Types Csp.Funs CspProofs)

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
DIFF_TMP="$(mktemp -d /tmp/csp_diff.XXXXXX)"
trap 'rm -rf "${DIFF_TMP}"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM
mkdir -p "${DIFF_TMP}/src" "${DIFF_TMP}/cache"

cat > "${DIFF_TMP}/pion.toml" <<EOF
[package]
name = "csp_diff_runner"
version = "0.1.0"

[dependencies]
csp = { path = "${PKG_DIR}" }
EOF

cat > "${DIFF_TMP}/src/main.pion" <<'EOF'
import "csp"

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
  emit_b(w, "lim_def", csp::parse_limits_all_nonneg(csp::ParseLimits::default()), true)
  emit_b(w, "lim_zero", csp::parse_limits_all_nonneg(csp::ParseLimits::new(0, 0, 0, 0)), true)
  emit_b(w, "lim_neg", csp::parse_limits_all_nonneg(csp::ParseLimits::new(-1, 1, 1, 1)), false)
  emit_b(w, "ws_sp", csp::csp_is_ws(32), true)
  emit_b(w, "ws_ff", csp::csp_is_ws(12), true)
  emit_b(w, "ws_lf", csp::csp_is_ws(10), false)
  emit_b(w, "alpha_A", csp::csp_is_alpha(65), true)
  emit_b(w, "alpha_z", csp::csp_is_alpha(122), true)
  emit_b(w, "alpha_5", csp::csp_is_alpha(53), false)
  emit_b(w, "digit_0", csp::csp_is_digit(48), true)
  emit_b(w, "digit_9", csp::csp_is_digit(57), true)
  emit_b(w, "digit_a", csp::csp_is_digit(97), false)
  emit_b(w, "ill_nul", csp::csp_is_illegal_header_byte(0), true)
  emit_b(w, "ill_lf", csp::csp_is_illegal_header_byte(10), true)
  emit_b(w, "ill_cr", csp::csp_is_illegal_header_byte(13), true)
  emit_b(w, "ill_del", csp::csp_is_illegal_header_byte(127), true)
  emit_b(w, "ill_tab", csp::csp_is_illegal_header_byte(9), false)
  emit_b(w, "ill_a", csp::csp_is_illegal_header_byte(97), false)
  emit_b(w, "ill_utf8", csp::csp_is_illegal_header_byte(200), false)
  emit_b(w, "ser_a", csp::csp_is_safe_serialized_byte(97), true)
  emit_b(w, "ser_semi", csp::csp_is_safe_serialized_byte(59), false)
  emit_b(w, "ser_comma", csp::csp_is_safe_serialized_byte(44), false)
  emit_b(w, "ser_sp", csp::csp_is_safe_serialized_byte(32), false)
  emit_b(w, "dir_dash", csp::csp_is_safe_directive_byte(45), true)
  emit_b(w, "dir_semi", csp::csp_is_safe_directive_byte(59), false)
  emit_i(w, "port_ok", csp::csp_port_step(80, 48), 800)
  emit_i(w, "port_max", csp::csp_port_step(6553, 53), 65535)
  emit_i(w, "port_ovf", csp::csp_port_step(6553, 54), -1)
  emit_i(w, "port_bad", csp::csp_port_step(80, 97), -1)
  emit_b(w, "pm_eq", csp::csp_explicit_port_matches(8443, 8443, false), true)
  emit_b(w, "pm_upg", csp::csp_explicit_port_matches(80, 443, true), true)
  emit_b(w, "pm_noupg", csp::csp_explicit_port_matches(80, 443, false), false)
  emit_b(w, "pm_nodown", csp::csp_explicit_port_matches(443, 80, true), false)
  emit_b(w, "inc_inc", csp::cors_is_include(csp::CredentialsMode::Include), true)
  emit_b(w, "inc_omit", csp::cors_is_include(csp::CredentialsMode::Omit), false)
  emit_i(w, "age_neg", csp::cors_clamp_max_age(-5), 0)
  emit_i(w, "age_mid", csp::cors_clamp_max_age(600), 600)
  emit_i(w, "age_cap", csp::cors_clamp_max_age(999999), 86400)
  emit_b(w, "cws_cr", csp::cors_is_http_ws(13), true)
  emit_b(w, "cws_ff", csp::cors_is_http_ws(12), false)
  emit_b(w, "cuns_q", csp::cors_is_unsafe_request_header_byte(34), true)
  emit_b(w, "cuns_tab", csp::cors_is_unsafe_request_header_byte(9), false)
  emit_b(w, "clang_en", csp::cors_is_language_byte(45), true)
  emit_b(w, "clang_col", csp::cors_is_language_byte(58), false)
  0
}
EOF

PION_CACHE_DIR="${DIFF_TMP}/cache" pionc build "${DIFF_TMP}" -o "${DIFF_TMP}/runner" >/dev/null
"${DIFF_TMP}/runner" > "${DIFF_TMP}/native.out"
printf '%s\n' "${LEAN_OUT}" > "${DIFF_TMP}/lean.out"

diff -u "${DIFF_TMP}/lean.out" "${DIFF_TMP}/native.out"
CASE_COUNT="$(wc -l < "${DIFF_TMP}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/csp Lean 4 proofs"
