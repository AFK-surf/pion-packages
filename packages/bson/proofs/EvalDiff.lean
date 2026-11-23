import Aeneas
import PionLean
import Bson.Types
import Bson.Funs

open Aeneas Aeneas.Std Result Pion bson

namespace BsonEvalDiff

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def mkU64 (n : Nat) : Std.U64 := ⟨BitVec.ofNat 64 n⟩

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

def runAll : List String :=
  [ s!"sub_rt_0={fmtI32 (do let s ← BinarySubtype.from_byte (mkI32 0); BinarySubtype.to_byte s)}"
  , s!"sub_rt_4={fmtI32 (do let s ← BinarySubtype.from_byte (mkI32 4); BinarySubtype.to_byte s)}"
  , s!"sub_rt_9={fmtI32 (do let s ← BinarySubtype.from_byte (mkI32 9); BinarySubtype.to_byte s)}"
  , s!"sub_rt_42={fmtI32 (do let s ← BinarySubtype.from_byte (mkI32 42); BinarySubtype.to_byte s)}"
  , s!"sub_rt_128={fmtI32 (do let s ← BinarySubtype.from_byte (mkI32 128); BinarySubtype.to_byte s)}"
  , s!"sub_rt_255={fmtI32 (do let s ← BinarySubtype.from_byte (mkI32 255); BinarySubtype.to_byte s)}"
  , s!"sub_rt_neg={fmtI32 (do let s ← BinarySubtype.from_byte (mkI32 (-1)); BinarySubtype.to_byte s)}"
  , s!"hex_0={fmtI32 (oid_hex_val (mkI32 48))}"
  , s!"hex_9={fmtI32 (oid_hex_val (mkI32 57))}"
  , s!"hex_a={fmtI32 (oid_hex_val (mkI32 97))}"
  , s!"hex_f={fmtI32 (oid_hex_val (mkI32 102))}"
  , s!"hex_A={fmtI32 (oid_hex_val (mkI32 65))}"
  , s!"hex_F={fmtI32 (oid_hex_val (mkI32 70))}"
  , s!"hex_bad={fmtI32 (oid_hex_val (mkI32 71))}"
  , s!"hex_min={fmtI32 (oid_hex_val (mkI32 (-2147483648)))}"
  , s!"low_A={fmtI32 (ascii_lower (mkI32 65))}"
  , s!"low_Z={fmtI32 (ascii_lower (mkI32 90))}"
  , s!"low_a={fmtI32 (ascii_lower (mkI32 97))}"
  , s!"low_0={fmtI32 (ascii_lower (mkI32 48))}"
  , s!"low_max={fmtI32 (ascii_lower (mkI32 2147483647))}"
  , s!"u128_eq={fmtBool (u128_gt (mkU64 5) (mkU64 10) (mkU64 5) (mkU64 10))}"
  , s!"u128_hi_gt={fmtBool (u128_gt (mkU64 6) (mkU64 0) (mkU64 5) (mkU64 999))}"
  , s!"u128_hi_lt={fmtBool (u128_gt (mkU64 4) (mkU64 999) (mkU64 5) (mkU64 0))}"
  , s!"u128_lo_gt={fmtBool (u128_gt (mkU64 5) (mkU64 11) (mkU64 5) (mkU64 10))}"
  , s!"u128_max={fmtBool (u128_gt (mkU64 18446744073709551615) (mkU64 18446744073709551615) (mkU64 18446744073709551615) (mkU64 18446744073709551614))}"
  , s!"d_nan_t={fmtBool (dec128_hi_is_nan (mkU64 0x7C00000000000000))}"
  , s!"d_nan_f={fmtBool (dec128_hi_is_nan (mkU64 0x7800000000000000))}"
  , s!"d_inf_t={fmtBool (dec128_hi_is_infinite (mkU64 0x7800000000000000))}"
  , s!"d_inf_neg={fmtBool (dec128_hi_is_infinite (mkU64 0xF800000000000000))}"
  , s!"d_inf_f={fmtBool (dec128_hi_is_infinite (mkU64 0x7C00000000000000))}"
  , s!"d_zero_p0={fmtBool (dec128_pair_is_zero (mkU64 0) (mkU64 0))}"
  , s!"d_zero_m0={fmtBool (dec128_pair_is_zero (mkU64 0x8000000000000000) (mkU64 0))}"
  , s!"d_zero_1={fmtBool (dec128_pair_is_zero (mkU64 0) (mkU64 1))}"
  , s!"d_zero_nan={fmtBool (dec128_pair_is_zero (mkU64 0x7C00000000000000) (mkU64 0))}"
  , s!"d_zero_inf={fmtBool (dec128_pair_is_zero (mkU64 0x7800000000000000) (mkU64 0))}"
  , s!"d_zero_c3={fmtBool (dec128_pair_is_zero (mkU64 0x6000000000000000) (mkU64 42))}"
  , s!"d_zero_ovf={fmtBool (dec128_pair_is_zero (mkU64 0x0001ED09BEAD87C0) (mkU64 0x378D8E6400000000))}"
  ]

#eval IO.println (String.intercalate "\n" runAll)

end BsonEvalDiff
