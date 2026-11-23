import Http1Proofs

-- Character classes & CRLF/NUL injection impossibility (5)
#print axioms Http1Proofs.is_tchar_byte_rejects_ctl_sp_nonascii
#print axioms Http1Proofs.is_tchar_byte_accepts_alnum
#print axioms Http1Proofs.is_header_val_byte_rejects_crlf_nul
#print axioms Http1Proofs.hex_digit_value_spec
#print axioms Http1Proofs.hex_digit_value_case_insensitive

-- RFC 9112 framing & anti-smuggling scalar state checks (11)
#print axioms Http1Proofs.effective_response_framing_bodyless
#print axioms Http1Proofs.te_coding_step_rejects_after_chunked
#print axioms Http1Proofs.check_framing_cl_rejects_after_te
#print axioms Http1Proofs.check_framing_te_rejects_http10
#print axioms Http1Proofs.check_framing_host_rejects_duplicate
#print axioms Http1Proofs.check_framing_cl_preserves_inv
#print axioms Http1Proofs.check_framing_te_preserves_inv
#print axioms Http1Proofs.check_framing_host_preserves_inv
#print axioms Http1Proofs.check_framing_finalize_http11_requires_host
#print axioms Http1Proofs.check_framing_finalize_request_te_requires_chunked
#print axioms Http1Proofs.check_framing_finalize_cl_nonneg

-- Numeric decoders & overflow immunity (5)
#print axioms Http1Proofs.parse_status_digits_ok
#print axioms Http1Proofs.u63_decimal_step_ok
#print axioms Http1Proofs.u63_decimal_step_rejects_overflow_or_invalid
#print axioms Http1Proofs.chunk_size_hex_step_ok
#print axioms Http1Proofs.chunk_size_hex_step_rejects_overflow
