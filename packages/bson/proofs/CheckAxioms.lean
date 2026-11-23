import BsonProofs

-- Verify all 24 main theorems depend ONLY on Lean's standard axioms
-- (`propext`, `Classical.choice`, `Quot.sound`) — no `sorryAx`, no custom axioms.

#print axioms BsonProofs.binary_subtype_to_from_byte_roundtrip
#print axioms BsonProofs.binary_subtype_from_byte_ranges
#print axioms BsonProofs.binary_subtype_from_to_byte_canonical
#print axioms BsonProofs.binary_subtype_to_byte_bounds
#print axioms BsonProofs.binary_subtype_eq_refl
#print axioms BsonProofs.binary_subtype_eq_symm
#print axioms BsonProofs.binary_subtype_eq_trans
#print axioms BsonProofs.bson_limits_default_spec
#print axioms BsonProofs.bson_limits_with_validate_preserves_bounds
#print axioms BsonProofs.oid_hex_val_bounds
#print axioms BsonProofs.oid_hex_val_case_insensitive
#print axioms BsonProofs.oid_hex_val_digit_exact
#print axioms BsonProofs.u128_gt_iff_nat
#print axioms BsonProofs.u128_gt_irrefl
#print axioms BsonProofs.u128_gt_asym
#print axioms BsonProofs.u128_gt_trans
#print axioms BsonProofs.ascii_lower_upper_exact
#print axioms BsonProofs.ascii_lower_idempotent
#print axioms BsonProofs.dec128_nan_inf_disjoint
#print axioms BsonProofs.dec128_nan_implies_not_zero
#print axioms BsonProofs.dec128_inf_implies_not_zero
#print axioms BsonProofs.dec128_canonical_signed_zeros
#print axioms BsonProofs.dec128_noncanonical_comb3_is_zero
#print axioms BsonProofs.dec128_negative_iff_msb
