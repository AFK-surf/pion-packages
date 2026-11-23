import Msgpack.Types
import Msgpack.Funs

open Aeneas Aeneas.Std Result Pion msgpack

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtOptI64 (r : Result (Option Std.I64)) : String :=
  match r.match with
  | .ok none => "None"
  | .ok (some v) => s!"Some({v.val})"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"uint_sz_0={fmtI64 (uint_encoded_size 0#u64)}"
  , s!"uint_sz_127={fmtI64 (uint_encoded_size 127#u64)}"
  , s!"uint_sz_128={fmtI64 (uint_encoded_size 128#u64)}"
  , s!"uint_sz_255={fmtI64 (uint_encoded_size 255#u64)}"
  , s!"uint_sz_256={fmtI64 (uint_encoded_size 256#u64)}"
  , s!"uint_sz_65536={fmtI64 (uint_encoded_size 65536#u64)}"
  , s!"uint_sz_u32max_p1={fmtI64 (uint_encoded_size 4294967296#u64)}"
  , s!"uint_sz_max={fmtI64 (uint_encoded_size 18446744073709551615#u64)}"
  , s!"int_sz_m1={fmtI64 (int_encoded_size (-1)#i64)}"
  , s!"int_sz_m32={fmtI64 (int_encoded_size (-32)#i64)}"
  , s!"int_sz_m33={fmtI64 (int_encoded_size (-33)#i64)}"
  , s!"int_sz_m129={fmtI64 (int_encoded_size (-129)#i64)}"
  , s!"int_sz_m32769={fmtI64 (int_encoded_size (-32769)#i64)}"
  , s!"int_sz_m2147483649={fmtI64 (int_encoded_size (-2147483649)#i64)}"
  , s!"f32_rt_0={fmtOptI64 (do let d ← float32_to_double_bits 0#i64; double_bits_to_float32_exact d)}"
  , s!"f32_rt_m0={fmtOptI64 (do let d ← float32_to_double_bits 2147483648#i64; double_bits_to_float32_exact d)}"
  , s!"f32_rt_1={fmtOptI64 (do let d ← float32_to_double_bits 1065353216#i64; double_bits_to_float32_exact d)}"
  , s!"f32_rt_inf={fmtOptI64 (do let d ← float32_to_double_bits 2139095040#i64; double_bits_to_float32_exact d)}"
  , s!"f32_rt_qnan={fmtOptI64 (do let d ← float32_to_double_bits 2143289344#i64; double_bits_to_float32_exact d)}"
  , s!"f32_rt_snan={fmtOptI64 (do let d ← float32_to_double_bits 2139095041#i64; double_bits_to_float32_exact d)}"
  , s!"f32_excess={fmtOptI64 (double_bits_to_float32_exact 4607182418800017409#i64)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
