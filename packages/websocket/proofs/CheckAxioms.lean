import WebsocketProofs

-- RFC 6455 §5.2-5.3 framing, length & XOR masking
#print axioms WebsocketProofs.mask_byte_xor_involutive
#print axioms WebsocketProofs.mask_byte_xor_zero
#print axioms WebsocketProofs.mask_byte_xor_comm
#print axioms WebsocketProofs.mask_key_byte_bounds
#print axioms WebsocketProofs.mask_key_byte_periodic
#print axioms WebsocketProofs.encoded_ext_len_spec
#print axioms WebsocketProofs.encoded_header_len_bounds
#print axioms WebsocketProofs.is_minimal_len16_spec
#print axioms WebsocketProofs.check_ext_len64_rejects_msb
#print axioms WebsocketProofs.check_ext_len64_rejects_nonminimal
#print axioms WebsocketProofs.check_ext_len64_rejects_too_large
#print axioms WebsocketProofs.check_ext_len64_accepts_valid
#print axioms WebsocketProofs.clamp_i64_to_i32_max_spec
#print axioms WebsocketProofs.frame_total_bytes_exact
#print axioms WebsocketProofs.frag_sum_i64_exact

-- RFC 6455 §5.1, §5.2, §5.5, §7.4.1 opcodes, masking direction, control frames & close codes
#print axioms WebsocketProofs.opcode_roundtrip
#print axioms WebsocketProofs.opcode_from_int_sound
#print axioms WebsocketProofs.opcode_from_int_rejects_reserved
#print axioms WebsocketProofs.is_control_opcode_iff_ge8
#print axioms WebsocketProofs.check_role_mask_spec
#print axioms WebsocketProofs.check_control_frame_spec
#print axioms WebsocketProofs.is_valid_close_code_spec
#print axioms WebsocketProofs.is_valid_close_code_rejects_forbidden

-- RFC 3629 incremental UTF-8 DFA
#print axioms WebsocketProofs.utf8_dfa_sticky_error
#print axioms WebsocketProofs.utf8_dfa_ascii_accept
#print axioms WebsocketProofs.utf8_dfa_rejects_lone_continuation
#print axioms WebsocketProofs.utf8_dfa_rejects_overlong_c0_c1
#print axioms WebsocketProofs.utf8_dfa_rejects_above_f4
#print axioms WebsocketProofs.utf8_dfa_rejects_overlong_e0
#print axioms WebsocketProofs.utf8_dfa_rejects_surrogate_ed
#print axioms WebsocketProofs.utf8_dfa_rejects_overlong_f0
#print axioms WebsocketProofs.utf8_dfa_rejects_above_10ffff_f4
#print axioms WebsocketProofs.utf8_dfa_accepts_valid_2byte
#print axioms WebsocketProofs.utf8_dfa_state_bounds
