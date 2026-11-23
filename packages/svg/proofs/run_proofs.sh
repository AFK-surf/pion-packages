#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/svg.
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

lean_lib Svg where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib SvgProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/svg ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/SvgProofs" "${PROJ_DIR}/SvgProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/SvgProofs" "${PROJ_DIR}/SvgProofs"
cp "${SCRIPT_DIR}/SvgProofs.lean" "${PROJ_DIR}/SvgProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/SvgProofs.lean" "${SCRIPT_DIR}/SvgProofs/" "${SCRIPT_DIR}/CheckAxioms.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden token found in Lean proofs!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Svg.Types Svg.Funs SvgProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Svg.Types Svg.Funs SvgProofs)

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
DIFF_DIR="$(mktemp -d /tmp/svg-native-diff.XXXXXX)"
trap 'rm -rf "${DIFF_DIR}"; kill -- -$$ 2>/dev/null || true' EXIT

cat > "${DIFF_DIR}/pion.toml" <<EOF
[package]
name = "svg_diff_harness"
version = "0.1.0"
edition = "2026"

[dependencies]
svg = { path = "${PKG_DIR}" }
EOF

mkdir -p "${DIFF_DIR}/src"
cat > "${DIFF_DIR}/src/main.pion" <<'EOF'
import "svg"

fn cb(w : World, label : String, got : Bool, exp : Bool) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn ci(w : World, label : String, got : Int, exp : Int) -> Unit {
  if got == exp { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn main(w : World) -> Unit {
  let l = svg::SvgLimits::default()
  ci(w, "lim_depth", l.max_depth, 128)
  ci(w, "lim_bytes", l.max_input_bytes, 16777216)
  ci(w, "rgb_a", svg::SvgColor::rgb(10, 20, 30).a, 255)
  ci(w, "rgba_g", svg::SvgColor::rgba(10, 20, 30, 128).g, 20)
  ci(w, "cl_neg", svg::clamp_u8_int(-5), 0)
  ci(w, "cl_0", svg::clamp_u8_int(0), 0)
  ci(w, "cl_128", svg::clamp_u8_int(128), 128)
  ci(w, "cl_hi", svg::clamp_u8_int(300), 255)
  cb(w, "hl_3", svg::is_valid_hex_color_len(3), true)
  cb(w, "hl_4", svg::is_valid_hex_color_len(4), true)
  cb(w, "hl_6", svg::is_valid_hex_color_len(6), true)
  cb(w, "hl_8", svg::is_valid_hex_color_len(8), true)
  cb(w, "hl_5", svg::is_valid_hex_color_len(5), false)
  ci(w, "hn_0", svg::hex_nibble_code(0), 48)
  ci(w, "hn_9", svg::hex_nibble_code(9), 57)
  ci(w, "hn_10", svg::hex_nibble_code(10), 97)
  ci(w, "hn_15", svg::hex_nibble_code(15), 102)
  ci(w, "h3_f", svg::hex3_channel_expand(15), 255)
  ci(w, "hp_ab", svg::hex_pair_to_byte(10, 11), 171)
  ci(w, "hp_ff", svg::hex_pair_to_byte(15, 15), 255)
  cb(w, "sws_sp", svg::is_svg_ws(32), true)
  cb(w, "sws_ff", svg::is_svg_ws(12), true)
  cb(w, "sws_a", svg::is_svg_ws(97), false)
  cb(w, "xws_sp", svg::is_xml_ws(32), true)
  cb(w, "xws_ff", svg::is_xml_ws(12), false)
  cb(w, "xws_cr", svg::is_xml_ws(13), true)
  cb(w, "dig_0", svg::is_ascii_digit(48), true)
  cb(w, "dig_a", svg::is_ascii_digit(97), false)
  ci(w, "hv_0", svg::hex_val(48), 0)
  ci(w, "hv_A", svg::hex_val(65), 10)
  ci(w, "hv_f", svg::hex_val(102), 15)
  ci(w, "hv_g", svg::hex_val(103), -1)
  ci(w, "hv_sp", svg::hex_val(32), -1)
  cb(w, "ns_0", svg::is_number_start(48), true)
  cb(w, "ns_neg", svg::is_number_start(45), true)
  cb(w, "ns_dot", svg::is_number_start(46), true)
  cb(w, "ns_M", svg::is_number_start(77), false)
  cb(w, "pm_M", svg::is_path_moveto(77), true)
  cb(w, "pm_m", svg::is_path_moveto(109), true)
  cb(w, "pm_L", svg::is_path_moveto(76), false)
  cb(w, "pc_Z", svg::is_path_closepath(90), true)
  cb(w, "pc_z", svg::is_path_closepath(122), true)
  cb(w, "id_A", svg::is_ident_char(65), true)
  cb(w, "id_0", svg::is_ident_char(48), false)
}
EOF

PION_CACHE_DIR="${DIFF_DIR}/pion-cache" pionc build -o "${DIFF_DIR}/diff_bin" "${DIFF_DIR}"
"${DIFF_DIR}/diff_bin" > "${DIFF_DIR}/native.out"
printf '%s\n' "${EVAL_OUT}" > "${DIFF_DIR}/lean.out"
diff -u "${DIFF_DIR}/native.out" "${DIFF_DIR}/lean.out"
CASE_COUNT="$(wc -l < "${DIFF_DIR}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/svg Lean 4 proofs"
