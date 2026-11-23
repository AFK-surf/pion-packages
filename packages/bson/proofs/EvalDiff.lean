import Aeneas
import PionLean
import Bson.Types
import Bson.Funs

open Aeneas Aeneas.Std Result Pion bson

namespace BsonEvalDiff

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def mkU64 (n : Nat) : Std.U64 := ⟨BitVec.ofNat 64 n⟩

private def checkCase [BEq α] (label : String) (r : Result α) (expected : α) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

def runAll : List String :=
  [ checkCase "sub_rt_0" (do let s ← BinarySubtype.from_byte (mkI32 0); BinarySubtype.to_byte s) (mkI32 0)
  , checkCase "sub_rt_4" (do let s ← BinarySubtype.from_byte (mkI32 4); BinarySubtype.to_byte s) (mkI32 4)
  , checkCase "sub_rt_9" (do let s ← BinarySubtype.from_byte (mkI32 9); BinarySubtype.to_byte s) (mkI32 9)
  , checkCase "sub_rt_42" (do let s ← BinarySubtype.from_byte (mkI32 42); BinarySubtype.to_byte s) (mkI32 42)
  , checkCase "sub_rt_128" (do let s ← BinarySubtype.from_byte (mkI32 128); BinarySubtype.to_byte s) (mkI32 128)
  , checkCase "sub_rt_255" (do let s ← BinarySubtype.from_byte (mkI32 255); BinarySubtype.to_byte s) (mkI32 255)
  , checkCase "sub_eq_t" (binary_subtype_eq BinarySubtype.Uuid BinarySubtype.Uuid) true
  , checkCase "sub_eq_f" (binary_subtype_eq BinarySubtype.Uuid BinarySubtype.Md5) false
  , checkCase "lim_def_d" (do let l ← BsonLimits.default; ok l.max_depth) (mkI32 128)
  , checkCase "lim_def_b" (do let l ← BsonLimits.default; ok l.max_doc_bytes) (mkI32 16777216)
  , checkCase "lim_def_v" (do let l ← BsonLimits.default; ok l.validate_array_keys) false
  , checkCase "lim_wval" (do let l ← BsonLimits.new (mkI32 64) (mkI32 4096) (mkI32 100); let l2 ← BsonLimits.with_validate_array_keys l true; ok l2.validate_array_keys) true
  , checkCase "hex_0" (oid_hex_val (mkI32 48)) (mkI32 0)
  , checkCase "hex_9" (oid_hex_val (mkI32 57)) (mkI32 9)
  , checkCase "hex_a" (oid_hex_val (mkI32 97)) (mkI32 10)
  , checkCase "hex_f" (oid_hex_val (mkI32 102)) (mkI32 15)
  , checkCase "hex_A" (oid_hex_val (mkI32 65)) (mkI32 10)
  , checkCase "hex_F" (oid_hex_val (mkI32 70)) (mkI32 15)
  , checkCase "hex_bad" (oid_hex_val (mkI32 71)) (mkI32 (-1))
  , checkCase "low_A" (ascii_lower (mkI32 65)) (mkI32 97)
  , checkCase "low_Z" (ascii_lower (mkI32 90)) (mkI32 122)
  , checkCase "low_a" (ascii_lower (mkI32 97)) (mkI32 97)
  , checkCase "low_0" (ascii_lower (mkI32 48)) (mkI32 48)
  , checkCase "u128_eq" (u128_gt (mkU64 5) (mkU64 10) (mkU64 5) (mkU64 10)) false
  , checkCase "u128_hi_gt" (u128_gt (mkU64 6) (mkU64 0) (mkU64 5) (mkU64 999)) true
  , checkCase "u128_hi_lt" (u128_gt (mkU64 4) (mkU64 999) (mkU64 5) (mkU64 0)) false
  , checkCase "u128_lo_gt" (u128_gt (mkU64 5) (mkU64 11) (mkU64 5) (mkU64 10)) true
  , checkCase "u128_lo_lt" (u128_gt (mkU64 5) (mkU64 9) (mkU64 5) (mkU64 10)) false
  , checkCase "d_nan_t" (dec128_hi_is_nan (mkU64 0x7C00000000000000)) true
  , checkCase "d_nan_f" (dec128_hi_is_nan (mkU64 0x7800000000000000)) false
  , checkCase "d_inf_t" (dec128_hi_is_infinite (mkU64 0x7800000000000000)) true
  , checkCase "d_inf_neg" (dec128_hi_is_infinite (mkU64 0xF800000000000000)) true
  , checkCase "d_inf_f" (dec128_hi_is_infinite (mkU64 0x7C00000000000000)) false
  , checkCase "d_neg_f" (dec128_hi_is_negative (mkU64 0)) false
  , checkCase "d_neg_t" (dec128_hi_is_negative (mkU64 0x8000000000000000)) true
  , checkCase "d_zero_p0" (dec128_pair_is_zero (mkU64 0) (mkU64 0)) true
  , checkCase "d_zero_m0" (dec128_pair_is_zero (mkU64 0x8000000000000000) (mkU64 0)) true
  , checkCase "d_zero_1" (dec128_pair_is_zero (mkU64 0) (mkU64 1)) false
  , checkCase "d_zero_nan" (dec128_pair_is_zero (mkU64 0x7C00000000000000) (mkU64 0)) false
  , checkCase "d_zero_inf" (dec128_pair_is_zero (mkU64 0x7800000000000000) (mkU64 0)) false
  , checkCase "d_zero_c3" (dec128_pair_is_zero (mkU64 0x6000000000000000) (mkU64 42)) true
  , checkCase "d_zero_ovf" (dec128_pair_is_zero (mkU64 0x0001ED09BEAD87C0) (mkU64 0x378D8E6400000000)) true
  ]

#eval IO.println (String.intercalate "\n" runAll)

end BsonEvalDiff
