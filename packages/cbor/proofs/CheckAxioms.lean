import CborProofs

-- Core DecodeOptions invariants
#print axioms CborProofs.decode_options_default_spec
#print axioms CborProofs.decode_options_strict_spec

-- RFC 8949 §4.2.1 Deterministic CBOR & RFC 3339 Tag 0
#print axioms CborProofs.head_size_u64_spec
#print axioms CborProofs.head_size_u64_bounds
#print axioms CborProofs.head_size_u64_mono
#print axioms CborProofs.head_size_int_agrees_u64
#print axioms CborProofs.is_canonical_arg_spec
#print axioms CborProofs.is_canonical_arg_rejects_reserved
#print axioms CborProofs.canonical_encoder_decoder_duality
#print axioms CborProofs.days_in_month_gregorian_spots

-- IEEE-754 Binary16 / Binary32 <-> Binary64 bit-level conversions
#print axioms CborProofs.float16_pos_zero_roundtrip
#print axioms CborProofs.float16_neg_zero_roundtrip
#print axioms CborProofs.float16_inf_roundtrip
#print axioms CborProofs.float16_canonical_nan_roundtrip
#print axioms CborProofs.double_bits_to_float16_any_nan_canonical
#print axioms CborProofs.double_bits_to_float16_rejects_excess_precision
#print axioms CborProofs.float32_zero_roundtrip
#print axioms CborProofs.float32_inf_roundtrip
#print axioms CborProofs.double_bits_to_float32_any_nan_canonical
#print axioms CborProofs.double_bits_to_float32_rejects_excess_precision
#print axioms CborProofs.float16_normal_spots_roundtrip
#print axioms CborProofs.float16_to_double_bits_normal_exact
