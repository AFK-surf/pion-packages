/-
Axiom audit for `packages/tar` Lean 4 proofs (`TarProofs`).
Every main theorem must depend ONLY on Lean's three standard axioms:
`propext`, `Classical.choice`, `Quot.sound` (0 `sorryAx`, 0 `Lean.ofReduceBool`).
-/
import TarProofs

-- Section 1: Typeflags & TarFormat
#print axioms TarProofs.is_header_only_type_total
#print axioms TarProofs.is_header_only_type_iff
#print axioms TarProofs.typeflag_classification
#print axioms TarProofs.format_equals_iff
#print axioms TarProofs.format_equals_refl
#print axioms TarProofs.format_equals_symm
#print axioms TarProofs.format_equals_trans

-- Section 2: 512-Byte Block Alignment & Padding Arithmetic
#print axioms TarProofs.block_padding_total
#print axioms TarProofs.block_padding_zero
#print axioms TarProofs.padded_size_spec
#print axioms TarProofs.padded_size_zero
#print axioms TarProofs.padded_size_mono
#print axioms TarProofs.padded_size_idempotent

-- Section 3: Zip-Slip Path Security & Traversal Impossibility
#print axioms TarProofs.ascii_upper_spec
#print axioms TarProofs.ascii_upper_idempotent
#print axioms TarProofs.is_path_sep_iff
#print axioms TarProofs.is_dotdot_segment_spec
#print axioms TarProofs.has_invalid_path_byte_spec
#print axioms TarProofs.is_windows_reserved_name_total
#print axioms TarProofs.is_windows_reserved_name_sound3
#print axioms TarProofs.validate_extract_path_bytes_sound
#print axioms TarProofs.validate_extract_path_empty_false
#print axioms TarProofs.validate_extract_path_rejects_dotdot
#print axioms TarProofs.validate_extract_path_rejects_nul
#print axioms TarProofs.validate_extract_path_rejects_colon
#print axioms TarProofs.validate_extract_path_rejects_absolute

-- Section 4: TAR Numeric Encoding & Decoding (Octal & GNU Base-256)
#print axioms TarProofs.fits_in_octal_spec
#print axioms TarProofs.fits_in_octal_neg_false
#print axioms TarProofs.fits_in_base256_spec
#print axioms TarProofs.fits_in_octal_imp_fits_in_base256
#print axioms TarProofs.parse_octal_slice_fast_nonneg
#print axioms TarProofs.parse_numeric_slice_base256_sign
#print axioms TarProofs.format_numeric_invalid_width
#print axioms TarProofs.format_numeric_spec
