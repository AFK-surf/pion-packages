import Base64Proofs

-- Full-domain Base64 length & roundtrip (3 A)
#print axioms Base64Proofs.b64_encoded_len_full_domain
#print axioms Base64Proofs.b64_encoded_len_mono_full
#print axioms Base64Proofs.b64_length_roundtrip_full

-- Base64/Hex bit-packing & full-domain Hex length (7: 3 A + 4 B)
#print axioms Base64Proofs.b64_pack3_bounds
#print axioms Base64Proofs.b64_pack3_pack4_roundtrip
#print axioms Base64Proofs.b64_pack4_neg_if_invalid
#print axioms Base64Proofs.hex_encoded_len_full_domain
#print axioms Base64Proofs.hex_len_roundtrip_full
#print axioms Base64Proofs.hex_pack_byte_roundtrip
#print axioms Base64Proofs.hex_pack_byte_neg_if_invalid

-- Full-domain Base32 length & roundtrip (2 A)
#print axioms Base64Proofs.b32_encoded_len_full_domain
#print axioms Base64Proofs.b32_encoded_len_nopad_roundtrip_full
