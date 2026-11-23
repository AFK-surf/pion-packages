#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/effect.
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

lean_lib Effect where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib EffectProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/effect ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/EffectProofs" "${PROJ_DIR}/EffectProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/EffectProofs" "${PROJ_DIR}/EffectProofs"
cp "${SCRIPT_DIR}/EffectProofs.lean" "${PROJ_DIR}/EffectProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/EffectProofs.lean" "${SCRIPT_DIR}/EffectProofs/" "${SCRIPT_DIR}/CheckAxioms.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden token found in Lean proofs!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Effect.Types Effect.Funs EffectProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Effect.Types Effect.Funs EffectProofs)

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
DIFF_DIR="$(mktemp -d /tmp/effect-native-diff.XXXXXX)"
trap 'rm -rf "${DIFF_DIR}"; kill -- -$$ 2>/dev/null || true' EXIT

cat > "${DIFF_DIR}/pion.toml" <<EOF
[package]
name = "effect_diff_harness"
version = "0.1.0"
edition = "2026"

[dependencies]
effect = { path = "${PKG_DIR}" }
EOF

mkdir -p "${DIFF_DIR}/src"
cat > "${DIFF_DIR}/src/main.pion" <<'EOF'
import "effect"

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
  ci64(w, "rng_init0", effect::rng_init_state(0), 2654435769L)
  ci64(w, "rng_init1", effect::rng_init_state(1), 8L)
  ci64(w, "rng_step0", effect::rng_step_u32(0L), 0L)
  ci64(w, "rng_step1", effect::rng_step_u32(1L), 270369L)
  ci(w, "rng_bel0", effect::rng_below_val(100L, 0), 0)
  ci(w, "rng_bel1", effect::rng_below_val(100L, 1), 0)
  ci(w, "rng_bel7", effect::rng_below_val(100L, 7), 2)
  ci(w, "rcap_0", effect::ring_next_cap(0), 8)
  ci(w, "rcap_8", effect::ring_next_cap(8), 16)
  ci(w, "radd_0", effect::ring_slot_add(0, 3, 8), 3)
  ci(w, "radd_w", effect::ring_slot_add(6, 5, 8), 3)
  ci(w, "rprev_0", effect::ring_slot_prev(0, 8), 7)
  ci(w, "rprev_3", effect::ring_slot_prev(3, 8), 2)
  cb(w, "tm_lt", effect::timer_before(10L, 5, 20L, 1), true)
  cb(w, "tm_eq_lt", effect::timer_before(10L, 1, 10L, 2), true)
  cb(w, "tm_eq_eq", effect::timer_before(10L, 2, 10L, 2), false)
  cb(w, "tm_gt", effect::timer_before(20L, 1, 10L, 9), false)
  ci(w, "hp_1", effect::heap_parent(1), 0)
  ci(w, "hp_2", effect::heap_parent(2), 0)
  ci(w, "hp_5", effect::heap_parent(5), 2)
  ci(w, "hl_0", effect::heap_left(0), 1)
  ci(w, "hl_3", effect::heap_left(3), 7)
  cb(w, "q_unb", effect::queue_has_room(-1, 999), true)
  cb(w, "q_ok", effect::queue_has_room(16, 15), true)
  cb(w, "q_full", effect::queue_has_room(16, 16), false)
  cb(w, "qo_shut", effect::queue_can_offer(true, -1, 0), false)
  cb(w, "qo_ok", effect::queue_can_offer(false, 4, 3), true)
  ci(w, "p_ask", effect::priority_asked(), 30)
  ci(w, "p_foc", effect::priority_focused(), 20)
  ci(w, "p_shw", effect::priority_shown(), 10)
  ci(w, "p_det", effect::priority_detail(), 5)
  ci(w, "p_bg", effect::priority_background(), 0)
  ci(w, "p_idl", effect::priority_idle(), -10)
  cb(w, "sl_urg_ok", effect::sched_lane_admits(20, 3, 2, 2, 0, false, false, false), true)
  cb(w, "sl_urg_no", effect::sched_lane_admits(20, 4, 2, 2, 0, false, false, false), false)
  cb(w, "sl_shw_ok", effect::sched_lane_admits(10, 1, 2, 2, 0, false, false, false), true)
  cb(w, "sl_shw_no", effect::sched_lane_admits(10, 2, 2, 2, 0, false, false, false), false)
  cb(w, "sl_bg_ser", effect::sched_lane_admits(0, 1, 2, 2, 0, false, true, false), false)
  cb(w, "sl_bg_ok", effect::sched_lane_admits(0, 0, 2, 2, 0, false, false, false), true)
  cb(w, "sl_idl_no", effect::sched_lane_admits(-10, 1, 2, 2, 0, false, false, false), false)
  cb(w, "sl_idl_ok", effect::sched_lane_admits(-10, 0, 2, 2, 0, false, false, false), true)
  cb(w, "sp_yes", effect::sched_is_preempted(-10, 1, false), true)
  cb(w, "sp_no", effect::sched_is_preempted(0, 1, true), false)
  cb(w, "fc_shield", effect::fiber_should_cut(true, 1), false)
}
EOF

PION_CACHE_DIR="${DIFF_DIR}/pion-cache" pionc build -o "${DIFF_DIR}/diff_bin" "${DIFF_DIR}"
"${DIFF_DIR}/diff_bin" > "${DIFF_DIR}/native.out"
printf '%s\n' "${EVAL_OUT}" > "${DIFF_DIR}/lean.out"
diff -u "${DIFF_DIR}/native.out" "${DIFF_DIR}/lean.out"
CASE_COUNT="$(wc -l < "${DIFF_DIR}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/effect Lean 4 proofs"
