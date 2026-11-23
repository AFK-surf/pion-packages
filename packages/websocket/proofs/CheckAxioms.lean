import WebsocketProofs

-- Frame masking & extended length checks (6)
#print axioms WebsocketProofs.mask_byte_xor_involutive
#print axioms WebsocketProofs.mask_key_byte_bounds
#print axioms WebsocketProofs.mask_key_byte_periodic
#print axioms WebsocketProofs.encoded_header_len_bounds
#print axioms WebsocketProofs.check_ext_len64_rejects_msb
#print axioms WebsocketProofs.check_ext_len64_rejects_too_large

-- Protocol opcode decoding (1)
#print axioms WebsocketProofs.opcode_from_int_sound

-- RFC 3629 incremental UTF-8 DFA (5)
#print axioms WebsocketProofs.utf8_dfa_sticky_error
#print axioms WebsocketProofs.utf8_dfa_ascii_accept
#print axioms WebsocketProofs.utf8_dfa_rejects_overlong_e0
#print axioms WebsocketProofs.utf8_dfa_accepts_valid_2byte
#print axioms WebsocketProofs.utf8_dfa_state_bounds
