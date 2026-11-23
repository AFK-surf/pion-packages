#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/email.
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

lean_lib Email where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib EmailProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/email ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/EmailProofs" "${PROJ_DIR}/EmailProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/EmailProofs" "${PROJ_DIR}/EmailProofs"
cp "${SCRIPT_DIR}/EmailProofs.lean" "${PROJ_DIR}/EmailProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/EmailProofs.lean" "${SCRIPT_DIR}/EmailProofs/" "${SCRIPT_DIR}/CheckAxioms.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden token found in Lean proofs!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Email.Types Email.Funs EmailProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Email.Types Email.Funs EmailProofs)

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
DIFF_DIR="$(mktemp -d /tmp/email-native-diff.XXXXXX)"
trap 'rm -rf "${DIFF_DIR}"; kill -- -$$ 2>/dev/null || true' EXIT

cat > "${DIFF_DIR}/pion.toml" <<EOF
[package]
name = "email_diff_harness"
version = "0.1.0"
edition = "2026"

[dependencies]
email = { path = "${PKG_DIR}" }
EOF

mkdir -p "${DIFF_DIR}/src"
cat > "${DIFF_DIR}/src/main.pion" <<'EOF'
import "email"

fn cb(w : World, name : String, got : Bool, exp : Bool) -> Unit {
  if got == exp { io_println(w, name + ": PASS") } else { io_println(w, name + ": FAIL") }
}

fn ci(w : World, name : String, got : Int, exp : Int) -> Unit {
  if got == exp { io_println(w, name + ": PASS") } else { io_println(w, name + ": FAIL") }
}

fn ci64(w : World, name : String, got : Int64, exp : Int64) -> Unit {
  if got == exp { io_println(w, name + ": PASS") } else { io_println(w, name + ": FAIL") }
}

fn main(w : World) -> Unit {
  let l = email::EmailLimits::default()
  ci(w, "lim_depth", l.max_depth, 16)
  ci(w, "lim_body", l.max_body_bytes, 67108864)
  ci(w, "hl_A", email::hdr_ascii_lower(65), 97)
  ci(w, "hl_Z", email::hdr_ascii_lower(90), 122)
  ci(w, "hl_a", email::hdr_ascii_lower(97), 97)
  ci(w, "dl_M", email::dt_lower(77), 109)
  cb(w, "ft_A", email::email_is_ftext(65), true)
  cb(w, "ft_colon", email::email_is_ftext(58), false)
  cb(w, "ft_sp", email::email_is_ftext(32), false)
  cb(w, "ft_del", email::email_is_ftext(127), false)
  cb(w, "inj_nul", email::email_is_injection_byte(0), true)
  cb(w, "inj_lf", email::email_is_injection_byte(10), true)
  cb(w, "inj_cr", email::email_is_injection_byte(13), true)
  cb(w, "inj_sp", email::email_is_injection_byte(32), false)
  ci(w, "fold_0", email::email_effective_fold_limit(0), 78)
  ci(w, "fold_19", email::email_effective_fold_limit(19), 78)
  ci(w, "fold_72", email::email_effective_fold_limit(72), 72)
  cb(w, "at_A", email::addr_is_atext(65), true)
  cb(w, "at_plus", email::addr_is_atext(43), true)
  cb(w, "at_utf8", email::addr_is_atext(200), true)
  cb(w, "at_at", email::addr_is_atext(64), false)
  cb(w, "at_dot", email::addr_is_atext(46), false)
  cb(w, "dt_0", email::addr_is_dtext(48), true)
  cb(w, "dt_lbr", email::addr_is_dtext(91), false)
  cb(w, "dt_bs", email::addr_is_dtext(92), false)
  cb(w, "qt_sp", email::addr_is_qtext_char(32), true)
  cb(w, "qt_lf", email::addr_is_qtext_char(10), false)
  cb(w, "qt_del", email::addr_is_qtext_char(127), false)
  cb(w, "dig_0", email::dt_is_digit(48), true)
  cb(w, "dig_a", email::dt_is_digit(97), false)
  ci(w, "yr_2_49", email::dt_normalize_year(49, 2), 2049)
  ci(w, "yr_2_50", email::dt_normalize_year(50, 2), 1950)
  ci(w, "yr_3_126", email::dt_normalize_year(126, 3), 2026)
  ci(w, "yr_4_2026", email::dt_normalize_year(2026, 4), 2026)
  ci(w, "leap_60", email::dt_clamp_leap_second(60), 59)
  ci(w, "leap_42", email::dt_clamp_leap_second(42), 42)
  cb(w, "voff_ok", email::dt_is_valid_offset_seconds(86340), true)
  cb(w, "voff_hi", email::dt_is_valid_offset_seconds(86341), false)
  ci(w, "noff_pos", email::dt_numeric_offset_seconds(43, 9, 0), 32400)
  ci(w, "noff_neg", email::dt_numeric_offset_seconds(45, 5, 30), -19800)
  ci64(w, "eday_pos", email::dt_epoch_floor_day(90000L), 1L)
  ci64(w, "erem_pos", email::dt_epoch_rem_sec(90000L), 3600L)
  ci64(w, "eday_neg", email::dt_epoch_floor_day(-1L), -1L)
  ci64(w, "erem_neg", email::dt_epoch_rem_sec(-1L), 86399L)
}
EOF

PION_CACHE_DIR="${DIFF_DIR}/pion-cache" pionc build -o "${DIFF_DIR}/diff_bin" "${DIFF_DIR}"
"${DIFF_DIR}/diff_bin" > "${DIFF_DIR}/native.out"
printf '%s\n' "${EVAL_OUT}" > "${DIFF_DIR}/lean.out"
diff -u "${DIFF_DIR}/native.out" "${DIFF_DIR}/lean.out"
CASE_COUNT="$(wc -l < "${DIFF_DIR}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/email Lean 4 proofs"
