#!/usr/bin/env bash
# End-to-end Lean 4 formal verification & native-vs-Lean differential runner for packages/bson.
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

lean_lib Bson where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]

lean_lib BsonProofs where
  moreLeanArgs := #["--memory=${LEAN_MEM_LIMIT}", "-j", "${LEAN_NUM_THREADS}"]
EOF

echo "=== [2/7] pionc extract-lean packages/bson ==="
pionc extract-lean "${PKG_DIR}" --out "${PROJ_DIR}"

rm -rf "${PROJ_DIR}/BsonProofs" "${PROJ_DIR}/BsonProofs.lean" "${PROJ_DIR}/CheckAxioms.lean" "${PROJ_DIR}/EvalDiff.lean"
cp -R "${SCRIPT_DIR}/BsonProofs" "${PROJ_DIR}/BsonProofs"
cp "${SCRIPT_DIR}/BsonProofs.lean" "${PROJ_DIR}/BsonProofs.lean"
cp "${SCRIPT_DIR}/CheckAxioms.lean" "${PROJ_DIR}/CheckAxioms.lean"
cp "${SCRIPT_DIR}/EvalDiff.lean" "${PROJ_DIR}/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "${SCRIPT_DIR}/BsonProofs" "${SCRIPT_DIR}/BsonProofs.lean" "${SCRIPT_DIR}/EvalDiff.lean"; then
  echo "ERROR: forbidden tactic/axiom found!" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Bson.Types Bson.Funs BsonProofs ==="
(cd "${PROJ_DIR}" && lake build PionLean Bson.Types Bson.Funs BsonProofs)

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
DIFF_TMP="$(mktemp -d /tmp/bson_diff.XXXXXX)"
trap 'rm -rf "${DIFF_TMP}"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM
mkdir -p "${DIFF_TMP}/src" "${DIFF_TMP}/cache"

cat > "${DIFF_TMP}/pion.toml" <<EOF
[package]
name = "bson_diff_runner"
version = "0.1.0"

[dependencies]
bson = { path = "${PKG_DIR}" }
EOF

cat > "${DIFF_TMP}/src/main.pion" <<'EOF'
import "bson"

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
  emit_i(w, "sub_rt_0", bson::BinarySubtype::from_byte(0).to_byte(), 0)
  emit_i(w, "sub_rt_4", bson::BinarySubtype::from_byte(4).to_byte(), 4)
  emit_i(w, "sub_rt_9", bson::BinarySubtype::from_byte(9).to_byte(), 9)
  emit_i(w, "sub_rt_42", bson::BinarySubtype::from_byte(42).to_byte(), 42)
  emit_i(w, "sub_rt_128", bson::BinarySubtype::from_byte(128).to_byte(), 128)
  emit_i(w, "sub_rt_255", bson::BinarySubtype::from_byte(255).to_byte(), 255)
  emit_b(w, "sub_eq_t", bson::binary_subtype_eq(bson::BinarySubtype::Uuid, bson::BinarySubtype::Uuid), true)
  emit_b(w, "sub_eq_f", bson::binary_subtype_eq(bson::BinarySubtype::Uuid, bson::BinarySubtype::Md5), false)
  let ld = bson::BsonLimits::default()
  emit_i(w, "lim_def_d", ld.max_depth, 128)
  emit_i(w, "lim_def_b", ld.max_doc_bytes, 16777216)
  emit_b(w, "lim_def_v", ld.validate_array_keys, false)
  let l2 = bson::BsonLimits::new(64, 4096, 100).with_validate_array_keys(true)
  emit_b(w, "lim_wval", l2.validate_array_keys, true)
  emit_i(w, "hex_0", bson::oid_hex_val(48), 0)
  emit_i(w, "hex_9", bson::oid_hex_val(57), 9)
  emit_i(w, "hex_a", bson::oid_hex_val(97), 10)
  emit_i(w, "hex_f", bson::oid_hex_val(102), 15)
  emit_i(w, "hex_A", bson::oid_hex_val(65), 10)
  emit_i(w, "hex_F", bson::oid_hex_val(70), 15)
  emit_i(w, "hex_bad", bson::oid_hex_val(71), -1)
  emit_i(w, "low_A", bson::ascii_lower(65), 97)
  emit_i(w, "low_Z", bson::ascii_lower(90), 122)
  emit_i(w, "low_a", bson::ascii_lower(97), 97)
  emit_i(w, "low_0", bson::ascii_lower(48), 48)
  emit_b(w, "u128_eq", bson::u128_gt(5UL, 10UL, 5UL, 10UL), false)
  emit_b(w, "u128_hi_gt", bson::u128_gt(6UL, 0UL, 5UL, 999UL), true)
  emit_b(w, "u128_hi_lt", bson::u128_gt(4UL, 999UL, 5UL, 0UL), false)
  emit_b(w, "u128_lo_gt", bson::u128_gt(5UL, 11UL, 5UL, 10UL), true)
  emit_b(w, "u128_lo_lt", bson::u128_gt(5UL, 9UL, 5UL, 10UL), false)
  emit_b(w, "d_nan_t", bson::dec128_hi_is_nan(0x7C00000000000000UL), true)
  emit_b(w, "d_nan_f", bson::dec128_hi_is_nan(0x7800000000000000UL), false)
  emit_b(w, "d_inf_t", bson::dec128_hi_is_infinite(0x7800000000000000UL), true)
  emit_b(w, "d_inf_neg", bson::dec128_hi_is_infinite(0xF800000000000000UL), true)
  emit_b(w, "d_inf_f", bson::dec128_hi_is_infinite(0x7C00000000000000UL), false)
  emit_b(w, "d_neg_f", bson::dec128_hi_is_negative(0UL), false)
  emit_b(w, "d_neg_t", bson::dec128_hi_is_negative(0x8000000000000000UL), true)
  emit_b(w, "d_zero_p0", bson::dec128_pair_is_zero(0UL, 0UL), true)
  emit_b(w, "d_zero_m0", bson::dec128_pair_is_zero(0x8000000000000000UL, 0UL), true)
  emit_b(w, "d_zero_1", bson::dec128_pair_is_zero(0UL, 1UL), false)
  emit_b(w, "d_zero_nan", bson::dec128_pair_is_zero(0x7C00000000000000UL, 0UL), false)
  emit_b(w, "d_zero_inf", bson::dec128_pair_is_zero(0x7800000000000000UL, 0UL), false)
  emit_b(w, "d_zero_c3", bson::dec128_pair_is_zero(0x6000000000000000UL, 42UL), true)
  emit_b(w, "d_zero_ovf", bson::dec128_pair_is_zero(0x0001ED09BEAD87C0UL, 0x378D8E6400000000UL), true)
  0
}
EOF

PION_CACHE_DIR="${DIFF_TMP}/cache" pionc build "${DIFF_TMP}" -o "${DIFF_TMP}/runner" >/dev/null
"${DIFF_TMP}/runner" > "${DIFF_TMP}/native.out"
printf '%s\n' "${LEAN_OUT}" > "${DIFF_TMP}/lean.out"

diff -u "${DIFF_TMP}/lean.out" "${DIFF_TMP}/native.out"
CASE_COUNT="$(wc -l < "${DIFF_TMP}/native.out" | tr -d ' ')"
echo "Native vs Lean differential: ${CASE_COUNT} cases identical (diff -u exit 0)"
echo "PASS: packages/bson Lean 4 proofs"
