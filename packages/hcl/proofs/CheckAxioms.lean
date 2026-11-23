import HclProofs

-- Verify all 24 main theorems depend ONLY on Lean's standard axioms
-- (`propext`, `Classical.choice`, `Quot.sound`) — no `sorryAx`, no custom axioms.

#print axioms HclProofs.hcl_effective_max_depth_exact
#print axioms HclProofs.hcl_effective_max_depth_bounds
#print axioms HclProofs.hcl_effective_max_depth_mono
#print axioms HclProofs.hcl_effective_max_depth_idempotent
#print axioms HclProofs.hcl_limits_default_spec
#print axioms HclProofs.pos_and_span_zero_spec
#print axioms HclProofs.is_hcl_ident_start_subset_cont
#print axioms HclProofs.is_hcl_ident_start_disjoint_digit
#print axioms HclProofs.is_hcl_digit_and_hyphen_in_ident_cont
#print axioms HclProofs.hcl_hex_val_bounds
#print axioms HclProofs.hcl_hex_val_case_insensitive
#print axioms HclProofs.hcl_hex_val_digit_exact
#print axioms HclProofs.is_unicode_space_ascii_exact
#print axioms HclProofs.is_unicode_space_non_ascii_members
#print axioms HclProofs.is_unicode_space_disjoint_ascii_ident
#print axioms HclProofs.unicode_cp_to_lower_ascii_upper
#print axioms HclProofs.unicode_cp_to_upper_ascii_lower
#print axioms HclProofs.unicode_ascii_case_roundtrip_upper
#print axioms HclProofs.unicode_ascii_case_roundtrip_lower
#print axioms HclProofs.unicode_cp_to_lower_ascii_idempotent
#print axioms HclProofs.unicode_cp_to_upper_ascii_idempotent
#print axioms HclProofs.unicode_latin1_case_roundtrip
#print axioms HclProofs.unicode_fullwidth_case_roundtrip
#print axioms HclProofs.unicode_special_go_mappings
