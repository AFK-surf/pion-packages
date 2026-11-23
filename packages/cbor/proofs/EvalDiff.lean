import Cbor.Types
import Cbor.Funs

open Aeneas Aeneas.Std Result Pion cbor

namespace CborEvalDiff

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def report (label : String) (passed : Bool) : IO Unit :=
  IO.println s!"{label}: {if passed then "PASS" else "FAIL"}"

#eval show IO Unit from do
  report "head_u64_0" (okIs (head_size_u64 0#u64) 1#i32)
  report "head_u64_23" (okIs (head_size_u64 23#u64) 1#i32)
  report "head_u64_24" (okIs (head_size_u64 24#u64) 2#i32)
  report "head_u64_255" (okIs (head_size_u64 255#u64) 2#i32)
  report "head_u64_256" (okIs (head_size_u64 256#u64) 3#i32)
  report "head_u64_65535" (okIs (head_size_u64 65535#u64) 3#i32)
  report "head_u64_65536" (okIs (head_size_u64 65536#u64) 5#i32)
  report "head_u64_u32max" (okIs (head_size_u64 4294967295#u64) 5#i32)
  report "head_u64_u32max_p1" (okIs (head_size_u64 4294967296#u64) 9#i32)
  report "head_int_23" (okIs (head_size_int 23#i32) 1#i32)
  report "head_int_24" (okIs (head_size_int 24#i32) 2#i32)
  report "head_int_65536" (okIs (head_size_int 65536#i32) 5#i32)
  report "canon_ai24_23_false" (okIs (is_canonical_arg 24#i32 23#u64) false)
  report "canon_ai24_24_true" (okIs (is_canonical_arg 24#i32 24#u64) true)
  report "canon_ai25_255_false" (okIs (is_canonical_arg 25#i32 255#u64) false)
  report "canon_ai25_256_true" (okIs (is_canonical_arg 25#i32 256#u64) true)
  report "canon_ai26_65535_false" (okIs (is_canonical_arg 26#i32 65535#u64) false)
  report "canon_ai26_65536_true" (okIs (is_canonical_arg 26#i32 65536#u64) true)
  report "canon_ai27_u32max_false" (okIs (is_canonical_arg 27#i32 4294967295#u64) false)
  report "canon_ai27_u32max_p1_true" (okIs (is_canonical_arg 27#i32 4294967296#u64) true)
  report "canon_ai28_false" (okIs (is_canonical_arg 28#i32 0#u64) false)
  report "days_2000_02" (okIs (days_in_month 2000#i32 2#i32) 29#i32)
  report "days_2100_02" (okIs (days_in_month 2100#i32 2#i32) 28#i32)
  report "f16_pos_zero_rt" (okIs (do let d ← float16_to_double_bits 0#i32; double_bits_to_float16_exact d) (some 0#i32))
  report "f16_neg_zero_rt" (okIs (do let d ← float16_to_double_bits 32768#i32; double_bits_to_float16_exact d) (some 32768#i32))
  report "f16_1_0_rt" (okIs (do let d ← float16_to_double_bits 15360#i32; double_bits_to_float16_exact d) (some 15360#i32))
  report "f16_1_5_rt" (okIs (do let d ← float16_to_double_bits 15872#i32; double_bits_to_float16_exact d) (some 15872#i32))
  report "f16_min_subnormal_rt" (okIs (do let d ← float16_to_double_bits 1#i32; double_bits_to_float16_exact d) (some 1#i32))
  report "f16_max_normal_rt" (okIs (do let d ← float16_to_double_bits 31743#i32; double_bits_to_float16_exact d) (some 31743#i32))
  report "f16_pos_inf_rt" (okIs (do let d ← float16_to_double_bits 31744#i32; double_bits_to_float16_exact d) (some 31744#i32))
  report "f16_neg_inf_rt" (okIs (do let d ← float16_to_double_bits 64512#i32; double_bits_to_float16_exact d) (some 64512#i32))
  report "f16_nan_canon" (okIs (do let d ← float16_to_double_bits 32257#i32; double_bits_to_float16_exact d) (some 32256#i32))
  report "f32_pos_zero_rt" (okIs (do let d ← float32_to_double_bits 0#i64; double_bits_to_float32_exact d) (some 0#i64))
  report "f32_neg_zero_rt" (okIs (do let d ← float32_to_double_bits 2147483648#i64; double_bits_to_float32_exact d) (some 2147483648#i64))
  report "f32_100000_rt" (okIs (do let d ← float32_to_double_bits 1203982336#i64; double_bits_to_float32_exact d) (some 1203982336#i64))
  report "f32_pos_inf_rt" (okIs (do let d ← float32_to_double_bits 2139095040#i64; double_bits_to_float32_exact d) (some 2139095040#i64))

end CborEvalDiff
