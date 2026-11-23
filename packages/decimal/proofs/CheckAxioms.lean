/-
Axiom gate for `packages/decimal` (`packages/decimal/proofs/run_proofs.sh`):
every theorem below may depend ONLY on `propext`, `Classical.choice`, and `Quot.sound`.
-/
import DecimalProofs

-- 1. 96-bit & 128-bit multi-precision arithmetic kernels
#print axioms DecimalProofs.u64_mul_wide_spec
#print axioms DecimalProofs.u96_cmp_spec
#print axioms DecimalProofs.u96_cmp_refl
#print axioms DecimalProofs.u96_cmp_antisymm
#print axioms DecimalProofs.u96_cmp_trans_lt
#print axioms DecimalProofs.inc96_spec
#print axioms DecimalProofs.mul10_add96_spec
#print axioms DecimalProofs.overflow96_div10_spec
#print axioms DecimalProofs.pow10_u32_spec
#print axioms DecimalProofs.pow10_u64_spec
#print axioms DecimalProofs.reduce_scale_overflow96_spec
#print axioms DecimalProofs.aligned_add_96_add_no_overflow
#print axioms DecimalProofs.aligned_add_96_add_overflow_scale0
#print axioms DecimalProofs.aligned_add_96_add_overflow_rescale
#print axioms DecimalProofs.aligned_add_96_sub_spec

-- 2. Decimal flags, sign, scale (0..=28), neg / abs / is_zero invariants
#print axioms DecimalProofs.make_flags_spec
#print axioms DecimalProofs.Decimal.scale_spec
#print axioms DecimalProofs.Decimal.scale_le_28
#print axioms DecimalProofs.Decimal.is_sign_negative_spec
#print axioms DecimalProofs.Decimal.is_sign_positive_spec
#print axioms DecimalProofs.Decimal.is_zero_spec
#print axioms DecimalProofs.Decimal.from_parts_ok_spec
#print axioms DecimalProofs.Decimal.from_parts_err_spec
#print axioms DecimalProofs.Decimal.set_scale_spec
#print axioms DecimalProofs.Decimal.neg_spec
#print axioms DecimalProofs.Decimal.neg_involutive
#print axioms DecimalProofs.Decimal.abs_spec
#print axioms DecimalProofs.Decimal.abs_idempotent
#print axioms DecimalProofs.Decimal.abs_neg

-- 3. 16-byte binary wire format serialize <-> deserialize & F-5 0x801F0000 safety
#print axioms DecimalProofs.Decimal.serialize_spec
#print axioms DecimalProofs.Decimal.serialize_length
#print axioms DecimalProofs.Decimal.deserialize_serialize_roundtrip
#print axioms DecimalProofs.Decimal.deserialize_wrong_length_err
#print axioms DecimalProofs.Decimal.deserialize_always_valid

-- 4. Exact cross-scale decimal comparison & truncation / scale-up
#print axioms DecimalProofs.cmp_magnitude_spec
#print axioms DecimalProofs.Decimal.compare_spec
#print axioms DecimalProofs.Decimal.compare_neg_zero_eq_pos_zero
#print axioms DecimalProofs.Decimal.compare_refl
#print axioms DecimalProofs.Decimal.compare_antisymm
#print axioms DecimalProofs.Decimal.compare_trans_lt
#print axioms DecimalProofs.Decimal.eq_spec
#print axioms DecimalProofs.Decimal.lt_spec
#print axioms DecimalProofs.Decimal.le_spec
#print axioms DecimalProofs.truncate_core_spec
#print axioms DecimalProofs.Decimal.trunc_spec
#print axioms DecimalProofs.scale_up_96_spec
