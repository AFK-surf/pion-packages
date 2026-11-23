import Cbor.Types
import Cbor.Funs

open Aeneas Aeneas.Std Result Pion cbor

namespace CborEvalDiff

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtOptI32 (r : Result (Option Std.I32)) : String :=
  match r.match with
  | .ok none => "None"
  | .ok (some v) => s!"Some({v.val})"
  | _ => "TRAP"

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"head_u64_0={fmtI32 (head_size_u64 0#u64)}"
  , s!"head_u64_23={fmtI32 (head_size_u64 23#u64)}"
  , s!"head_u64_24={fmtI32 (head_size_u64 24#u64)}"
  , s!"head_u64_255={fmtI32 (head_size_u64 255#u64)}"
  , s!"head_u64_256={fmtI32 (head_size_u64 256#u64)}"
  , s!"head_u64_65535={fmtI32 (head_size_u64 65535#u64)}"
  , s!"head_u64_65536={fmtI32 (head_size_u64 65536#u64)}"
  , s!"head_u64_u32max={fmtI32 (head_size_u64 4294967295#u64)}"
  , s!"head_u64_u32max_p1={fmtI32 (head_size_u64 4294967296#u64)}"
  , s!"head_u64_max={fmtI32 (head_size_u64 18446744073709551615#u64)}"
  , s!"head_int_23={fmtI32 (head_size_int 23#i32)}"
  , s!"head_int_24={fmtI32 (head_size_int 24#i32)}"
  , s!"head_int_65536={fmtI32 (head_size_int 65536#i32)}"
  , s!"head_int_max={fmtI32 (head_size_int 2147483647#i32)}"
  , s!"canon_24_23={fmtBool (is_canonical_arg 24#i32 23#u64)}"
  , s!"canon_24_24={fmtBool (is_canonical_arg 24#i32 24#u64)}"
  , s!"canon_25_255={fmtBool (is_canonical_arg 25#i32 255#u64)}"
  , s!"canon_25_256={fmtBool (is_canonical_arg 25#i32 256#u64)}"
  , s!"canon_26_65535={fmtBool (is_canonical_arg 26#i32 65535#u64)}"
  , s!"canon_26_65536={fmtBool (is_canonical_arg 26#i32 65536#u64)}"
  , s!"canon_27_u32max={fmtBool (is_canonical_arg 27#i32 4294967295#u64)}"
  , s!"canon_27_u32max_p1={fmtBool (is_canonical_arg 27#i32 4294967296#u64)}"
  , s!"canon_28_0={fmtBool (is_canonical_arg 28#i32 0#u64)}"
  , s!"f16_rt_0={fmtOptI32 (do let d ← float16_to_double_bits 0#i32; double_bits_to_float16_exact d)}"
  , s!"f16_rt_m0={fmtOptI32 (do let d ← float16_to_double_bits 32768#i32; double_bits_to_float16_exact d)}"
  , s!"f16_rt_1={fmtOptI32 (do let d ← float16_to_double_bits 15360#i32; double_bits_to_float16_exact d)}"
  , s!"f16_rt_sub={fmtOptI32 (do let d ← float16_to_double_bits 1#i32; double_bits_to_float16_exact d)}"
  , s!"f16_rt_max={fmtOptI32 (do let d ← float16_to_double_bits 31743#i32; double_bits_to_float16_exact d)}"
  , s!"f16_rt_inf={fmtOptI32 (do let d ← float16_to_double_bits 31744#i32; double_bits_to_float16_exact d)}"
  , s!"f16_rt_ninf={fmtOptI32 (do let d ← float16_to_double_bits 64512#i32; double_bits_to_float16_exact d)}"
  , s!"f16_nan_canon={fmtOptI32 (do let d ← float16_to_double_bits 32257#i32; double_bits_to_float16_exact d)}"
  , s!"f16_excess={fmtOptI32 (double_bits_to_float16_exact 4607182418800017409#i64)}"
  , s!"f16_to_d_1={fmtI64 (float16_to_double_bits 15360#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)

end CborEvalDiff
