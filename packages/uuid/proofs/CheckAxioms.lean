/-
Axiom audit for `packages/uuid/proofs/UuidProofs.lean`.
Every main theorem must depend ONLY on Lean's three standard axioms:
`propext`, `Classical.choice`, `Quot.sound` (0 `sorryAx`, 0 `Lean.ofReduceBool`).
-/
import UuidProofs

-- 1. 128-bit Unsigned Total Order & Uuid / Ulid Equivalence
#print axioms UuidProofs.uuid_from_as_u64_pair
#print axioms UuidProofs.uuid_as_from_u64_pair
#print axioms UuidProofs.ulid_from_as_u64_pair
#print axioms UuidProofs.ulid_as_from_u64_pair
#print axioms UuidProofs.ulid_uuid_roundtrip
#print axioms UuidProofs.uuid_ulid_roundtrip
#print axioms UuidProofs.uuid_eq_iff
#print axioms UuidProofs.ulid_eq_iff
#print axioms UuidProofs.uuid_compare_total
#print axioms UuidProofs.uuid_compare_spec_lt
#print axioms UuidProofs.uuid_compare_spec_gt
#print axioms UuidProofs.uuid_compare_spec_eq
#print axioms UuidProofs.uuid_compare_refl
#print axioms UuidProofs.uuid_compare_antisymm
#print axioms UuidProofs.uuid_compare_trans
#print axioms UuidProofs.uuid_lt_iff_compare
#print axioms UuidProofs.ulid_compare_total
#print axioms UuidProofs.ulid_compare_spec_lt
#print axioms UuidProofs.ulid_compare_spec_gt
#print axioms UuidProofs.ulid_compare_spec_eq
#print axioms UuidProofs.ulid_compare_refl
#print axioms UuidProofs.ulid_compare_antisymm
#print axioms UuidProofs.ulid_compare_trans
#print axioms UuidProofs.ulid_lt_iff_compare
#print axioms UuidProofs.uuid_is_nil_iff
#print axioms UuidProofs.uuid_is_max_iff
#print axioms UuidProofs.uuid_nil_min
#print axioms UuidProofs.uuid_max_max
#print axioms UuidProofs.ulid_nil_min
#print axioms UuidProofs.ulid_max_max

-- 2. RFC 9562 Version & Variant Bitfield Invariants
#print axioms UuidProofs.set_version_and_variant_variant
#print axioms UuidProofs.set_version_and_variant_version_num
#print axioms UuidProofs.new_v4_from_u64_pair_spec
#print axioms UuidProofs.set_version_and_variant_v3_v5_v8
#print axioms UuidProofs.new_v8_spec
#print axioms UuidProofs.new_v7_from_parts_spec
#print axioms UuidProofs.new_v7_from_parts_strict_monotonic
#print axioms UuidProofs.uuid_nil_version
#print axioms UuidProofs.uuid_max_version

-- 3. ULID 48-bit Timestamp + 80-bit Random Bijection & Monotonicity
#print axioms UuidProofs.ulid_from_parts_roundtrip
#print axioms UuidProofs.ulid_from_parts_reject_invalid
#print axioms UuidProofs.ulid_parts_bijection
#print axioms UuidProofs.ulid_from_parts_strict_monotonic
#print axioms UuidProofs.ulid_increment_ok
#print axioms UuidProofs.ulid_increment_overflow

-- 4. Hex & Crockford Base32 Single-Character Codecs
#print axioms UuidProofs.hex_lower_roundtrip
#print axioms UuidProofs.hex_upper_roundtrip
#print axioms UuidProofs.hex_val_char_case_insensitive
#print axioms UuidProofs.hex_val_char_range
#print axioms UuidProofs.crockford_encode_decode_roundtrip
#print axioms UuidProofs.crockford_encode_decode_strict_roundtrip
#print axioms UuidProofs.crockford_aliases
#print axioms UuidProofs.crockford_strict_rejects_aliases
#print axioms UuidProofs.crockford_case_insensitive
#print axioms UuidProofs.crockford_rejects_invalid
