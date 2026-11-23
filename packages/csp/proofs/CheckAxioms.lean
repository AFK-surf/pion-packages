import CspProofs

-- Verify all 24 main theorems depend ONLY on Lean's standard axioms
-- (`propext`, `Classical.choice`, `Quot.sound`) — no `sorryAx`, no custom axioms.

#print axioms CspProofs.parse_limits_default_valid
#print axioms CspProofs.parse_limits_all_nonneg_iff
#print axioms CspProofs.parse_limits_zero_valid
#print axioms CspProofs.csp_illegal_header_byte_rejects_injection
#print axioms CspProofs.csp_illegal_header_byte_allows_ws_and_printable
#print axioms CspProofs.csp_safe_serialized_byte_implies_legal_header
#print axioms CspProofs.csp_safe_serialized_byte_rejects_delimiters
#print axioms CspProofs.csp_safe_directive_byte_implies_safe_serialized
#print axioms CspProofs.csp_is_alpha_digit_disjoint
#print axioms CspProofs.csp_port_step_bounds
#print axioms CspProofs.csp_explicit_port_matches_iff
#print axioms CspProofs.csp_explicit_port_no_downgrade
#print axioms CspProofs.cors_is_include_iff
#print axioms CspProofs.cors_clamp_max_age_exact
#print axioms CspProofs.cors_clamp_max_age_bounds
#print axioms CspProofs.cors_clamp_max_age_mono
#print axioms CspProofs.cors_clamp_max_age_idempotent
#print axioms CspProofs.cors_unsafe_header_byte_rejects_controls
#print axioms CspProofs.cors_unsafe_header_byte_allows_htab_and_alnum
#print axioms CspProofs.cors_unsafe_header_byte_rejects_13_punct
#print axioms CspProofs.cors_language_byte_implies_safe_header_byte
#print axioms CspProofs.cors_language_byte_subset_printable
#print axioms CspProofs.cors_http_ws_spec
#print axioms CspProofs.csp_ws_spec_and_legal_header
