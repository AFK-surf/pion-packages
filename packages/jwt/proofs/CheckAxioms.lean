/-
Axiom audit for all main theorems in `JwtProofs`.
Every theorem must depend only on `propext`, `Classical.choice`, `Quot.sound`
(or no axioms at all).
-/
import JwtProofs

-- Section 1: Constant-time byte comparison
#print axioms JwtProofs.constant_time_eq_spec
#print axioms JwtProofs.constant_time_eq_total
#print axioms JwtProofs.constant_time_eq_iff
#print axioms JwtProofs.constant_time_eq_refl
#print axioms JwtProofs.constant_time_eq_symm

-- Section 2: Anti-CVE algorithm & HMAC key security gate
#print axioms JwtProofs.algorithm_equals_iff
#print axioms JwtProofs.algorithm_equals_total
#print axioms JwtProofs.algorithm_from_str_as_str
#print axioms JwtProofs.algorithm_from_str_ok_iff
#print axioms JwtProofs.algorithm_from_str_rejects_none_variants
#print axioms JwtProofs.algorithm_from_str_rejects_unknown
#print axioms JwtProofs.hmac_key_valid_iff
#print axioms JwtProofs.hmac_key_valid_rejects_empty
#print axioms JwtProofs.alg_in_allowlist_spec
#print axioms JwtProofs.alg_in_allowlist_empty
#print axioms JwtProofs.check_verifier_alg_iff

-- Section 3: Saturating exp / nbf time-window & leeway overflow immunity
#print axioms JwtProofs.saturating_add_nonneg_spec
#print axioms JwtProofs.saturating_sub_nonneg_spec
#print axioms JwtProofs.normalize_leeway_spec
#print axioms JwtProofs.is_expired_sound
#print axioms JwtProofs.is_expired_iff_of_gt_min
#print axioms JwtProofs.is_expired_zero_leeway
#print axioms JwtProofs.is_immature_spec
#print axioms JwtProofs.is_immature_zero_leeway

-- Section 4: Strict unpadded Base64URL character codec & canonical tail bits
#print axioms JwtProofs.b64url_encode_decode_roundtrip
#print axioms JwtProofs.b64url_decode_byte_spec
#print axioms JwtProofs.b64url_decode_rejects_invalid_chars
#print axioms JwtProofs.base64url_len_valid_iff
#print axioms JwtProofs.base64url_len_valid_rejects_mod4_eq1
#print axioms JwtProofs.base64url_tail_bits_valid_iff
#print axioms JwtProofs.base64url_encoded_decoded_len_roundtrip

-- Section 5: SHA-256 bitwise primitives
#print axioms JwtProofs.sha256_ch_same
#print axioms JwtProofs.sha256_maj_same_xy
#print axioms JwtProofs.sha256_maj_symm_xy
#print axioms JwtProofs.sha256_rotr_spec
#print axioms JwtProofs.sha256_rotr_compose
#print axioms JwtProofs.sha256_sigmas_total
