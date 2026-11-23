import RespProofs

-- Verify all 24 main theorems depend ONLY on Lean's standard axioms
-- (`propext`, `Classical.choice`, `Quot.sound`) — no `sorryAx`, no custom axioms.

#print axioms RespProofs.resp_limits_default_spec
#print axioms RespProofs.resp_limits_with_inline_preserves
#print axioms RespProofs.effective_max_buffer_bytes_ge_original
#print axioms RespProofs.effective_max_buffer_bytes_slack
#print axioms RespProofs.effective_max_buffer_bytes_idempotent
#print axioms RespProofs.is_resp_prefix_exact_15
#print axioms RespProofs.is_resp_prefix_disjoint_inline_space
#print axioms RespProofs.is_resp_prefix_disjoint_alnum
#print axioms RespProofs.is_inline_space_spec
#print axioms RespProofs.hex_nibble_bounds
#print axioms RespProofs.hex_nibble_case_insensitive
#print axioms RespProofs.i64_parse_will_overflow_exact
#print axioms RespProofs.crc16_bit_step_bounds
#print axioms RespProofs.crc16_bit_step_zero
#print axioms RespProofs.crc16_bit_step_msb_poly
#print axioms RespProofs.crc16_bit_step_low_exact
#print axioms RespProofs.crc16_to_slot_valid
#print axioms RespProofs.crc16_to_slot_mod
#print axioms RespProofs.crc16_to_slot_idempotent
#print axioms RespProofs.is_valid_cluster_slot_iff
#print axioms RespProofs.is_valid_cluster_slot_boundaries
#print axioms RespProofs.is_valid_slot_range_iff
#print axioms RespProofs.is_valid_slot_range_endpoints_valid
#print axioms RespProofs.is_valid_slot_range_singleton_iff
