import Msgpack.Types
import Msgpack.Funs

open Aeneas Aeneas.Std Result Pion msgpack

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def check (label : String) (b : Bool) : IO Unit :=
  IO.println s!"{label}: {if b then "PASS" else "FAIL"}"

def main : IO Unit := do
  -- Options & ext tags
  check "dec_default_depth" (okIs (do let o ← DecodeOptions.default; ok o.max_depth) 512#i32)
  check "dec_strict_canon" (okIs (do let o ← DecodeOptions.strict; ok o.require_canonical) true)
  check "enc_default_compact" (okIs (do let o ← EncodeOptions.default; ok o.compact_floats) false)
  check "enc_compact_true" (okIs (do let o ← EncodeOptions.compact; ok o.compact_floats) true)
  check "ext_tag_m128" (okIs (is_valid_ext_tag (-128)#i32) true)
  check "ext_tag_m1" (okIs (is_valid_ext_tag (-1)#i32) true)
  check "ext_tag_127" (okIs (is_valid_ext_tag 127#i32) true)
  check "ext_tag_128_false" (okIs (is_valid_ext_tag 128#i32) false)
  check "ext_tag_m129_false" (okIs (is_valid_ext_tag (-129)#i32) false)

  -- Canonical unsigned & signed int sizing
  check "uint_sz_0" (okIs (uint_encoded_size 0#u64) 1#i64)
  check "uint_sz_127" (okIs (uint_encoded_size 127#u64) 1#i64)
  check "uint_sz_128" (okIs (uint_encoded_size 128#u64) 2#i64)
  check "uint_sz_255" (okIs (uint_encoded_size 255#u64) 2#i64)
  check "uint_sz_256" (okIs (uint_encoded_size 256#u64) 3#i64)
  check "uint_sz_65536" (okIs (uint_encoded_size 65536#u64) 5#i64)
  check "uint_sz_u32max_p1" (okIs (uint_encoded_size 4294967296#u64) 9#i64)
  check "int_sz_m1" (okIs (int_encoded_size (-1)#i64) 1#i64)
  check "int_sz_m32" (okIs (int_encoded_size (-32)#i64) 1#i64)
  check "int_sz_m33" (okIs (int_encoded_size (-33)#i64) 2#i64)
  check "int_sz_m129" (okIs (int_encoded_size (-129)#i64) 3#i64)
  check "int_sz_m32769" (okIs (int_encoded_size (-32769)#i64) 5#i64)
  check "int_sz_m2147483649" (okIs (int_encoded_size (-2147483649)#i64) 9#i64)

  -- Str, Bin, Container, Ext, Timestamp sizing
  check "str_sz_31" (okIs (str_encoded_size 31#i32) 32#i64)
  check "str_sz_32" (okIs (str_encoded_size 32#i32) 34#i64)
  check "bin_sz_255" (okIs (bin_encoded_size 255#i32) 257#i64)
  check "bin_sz_256" (okIs (bin_encoded_size 256#i32) 259#i64)
  check "cont_head_15" (okIs (container_head_size 15#i32) 1#i64)
  check "cont_head_16" (okIs (container_head_size 16#i32) 3#i64)
  check "cont_head_65536" (okIs (container_head_size 65536#i32) 5#i64)
  check "ext_sz_fix4" (okIs (ext_encoded_size 4#i32) 6#i64)
  check "ext_sz_fix16" (okIs (ext_encoded_size 16#i32) 18#i64)
  check "ext_sz_3" (okIs (ext_encoded_size 3#i32) 6#i64)
  check "ts_sz_32" (okIs (timestamp_encoded_size 1000#i64 0#i32) 6#i64)
  check "ts_sz_64" (okIs (timestamp_encoded_size 1000#i64 500#i32) 10#i64)
  check "ts_sz_96_neg" (okIs (timestamp_encoded_size (-1)#i64 0#i32) 15#i64)

  -- Float32 exact roundtrip
  check "f32_pos_zero_rt" (okIs (do let d ← float32_to_double_bits 0#i64; double_bits_to_float32_exact d) (some 0#i64))
  check "f32_neg_zero_rt" (okIs (do let d ← float32_to_double_bits 2147483648#i64; double_bits_to_float32_exact d) (some 2147483648#i64))
  check "f32_1_0_rt" (okIs (do let d ← float32_to_double_bits 1065353216#i64; double_bits_to_float32_exact d) (some 1065353216#i64))
  check "f32_pos_inf_rt" (okIs (do let d ← float32_to_double_bits 2139095040#i64; double_bits_to_float32_exact d) (some 2139095040#i64))
  check "f32_qnan_rt" (okIs (do let d ← float32_to_double_bits 2143289344#i64; double_bits_to_float32_exact d) (some 2143289344#i64))
  check "f32_snan_rt" (okIs (do let d ← float32_to_double_bits 2139095041#i64; double_bits_to_float32_exact d) (some 2139095041#i64))
