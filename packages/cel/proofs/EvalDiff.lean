import Aeneas
import PionLean
import Cel.Types
import Cel.Funs

open Aeneas Aeneas.Std Result Pion cel

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtU64 (r : Result U64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def i64Min : I64 := Pion.I64.sub (-9223372036854775807)#i64 1#i64

private def runAll : List String :=
  [ s!"add_i64_ovf={fmtBool (i64_add_overflows 9223372036854775807#i64 1#i64)}"
  , s!"add_i64_udf={fmtBool (i64_add_overflows i64Min (-1)#i64)}"
  , s!"add_i64_ok={fmtBool (i64_add_overflows 100#i64 (-50)#i64)}"
  , s!"sub_i64_ovf={fmtBool (i64_sub_overflows 9223372036854775807#i64 (-1)#i64)}"
  , s!"sub_i64_udf={fmtBool (i64_sub_overflows i64Min 1#i64)}"
  , s!"sub_i64_ok={fmtBool (i64_sub_overflows 50#i64 100#i64)}"
  , s!"add_u64_ovf={fmtBool (u64_add_overflows 18446744073709551615#u64 1#u64)}"
  , s!"add_u64_ok={fmtBool (u64_add_overflows 100#u64 200#u64)}"
  , s!"mul_u64_ovf={fmtBool (u64_mul_overflows 4294967296#u64 4294967296#u64)}"
  , s!"mul_u64_ok={fmtBool (u64_mul_overflows 4294967295#u64 4294967295#u64)}"
  , s!"mul_u64_zero={fmtBool (u64_mul_overflows 0#u64 18446744073709551615#u64)}"
  , s!"cmp_neg_0={fmtI32 (cmp_i64_u64 (-1)#i64 0#u64)}"
  , s!"cmp_min_0={fmtI32 (cmp_i64_u64 i64Min 0#u64)}"
  , s!"cmp_eq_42={fmtI32 (cmp_i64_u64 42#i64 42#u64)}"
  , s!"cmp_gt={fmtI32 (cmp_i64_u64 100#i64 99#u64)}"
  , s!"cmp_max_hi={fmtI32 (cmp_i64_u64 9223372036854775807#i64 9223372036854775808#u64)}"
  , s!"int_u64_0={fmtU64 (int_to_u64 0#i32)}"
  , s!"int_u64_42={fmtU64 (int_to_u64 42#i32)}"
  , s!"int_u64_max={fmtU64 (int_to_u64 2147483647#i32)}"
  , s!"teq_list={fmtBool (cel_type_eq (.List .Int) (.List .Int))}"
  , s!"teq_diff={fmtBool (cel_type_eq (.List .Int) (.List .UInt))}"
  , s!"asgn_dyn={fmtBool (is_assignable (.Map .String .Dyn) (.Map .String .Int))}"
  , s!"asgn_no={fmtBool (is_assignable (.Map .String .Int) (.Map .String .UInt))}"
  , s!"id_start_u={fmtBool (is_ident_start 95#i32)}"
  , s!"id_start_0={fmtBool (is_ident_start 48#i32)}"
  , s!"id_cont_0={fmtBool (is_ident_cont 48#i32)}"
  , s!"dig_9={fmtBool (is_digit 57#i32)}"
  , s!"hex_0={fmtI32 (hex_val 48#i32)}"
  , s!"hex_A={fmtI32 (hex_val 65#i32)}"
  , s!"hex_f={fmtI32 (hex_val 102#i32)}"
  , s!"hex_bad={fmtI32 (hex_val 103#i32)}"
  , s!"hex_neg={fmtI32 (hex_val (-1)#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
