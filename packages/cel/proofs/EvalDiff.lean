import Aeneas
import PionLean
import Cel.Types
import Cel.Funs

open Aeneas Aeneas.Std Result Pion cel

private def checkBool (label : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkI32 (label : String) (r : Result I32) (expected : I32) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkU64 (label : String) (r : Result U64) (expected : U64) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def i64Min : I64 := Pion.I64.sub (-9223372036854775807)#i64 1#i64

private def runAll : List String := [
  checkBool "neg_min" (i64_neg_overflows i64Min) true,
  checkBool "neg_max" (i64_neg_overflows 9223372036854775807#i64) false,
  checkBool "add_i64_ovf" (i64_add_overflows 9223372036854775807#i64 1#i64) true,
  checkBool "add_i64_udf" (i64_add_overflows i64Min (-1)#i64) true,
  checkBool "add_i64_ok" (i64_add_overflows 100#i64 (-50)#i64) false,
  checkBool "sub_i64_ovf" (i64_sub_overflows 9223372036854775807#i64 (-1)#i64) true,
  checkBool "sub_i64_udf" (i64_sub_overflows i64Min 1#i64) true,
  checkBool "sub_i64_ok" (i64_sub_overflows 50#i64 100#i64) false,
  checkI32 "div_zero" (i64_div_err_code 42#i64 0#i64) 1#i32,
  checkI32 "div_min_m1" (i64_div_err_code i64Min (-1)#i64) 2#i32,
  checkI32 "div_ok" (i64_div_err_code (-42)#i64 7#i64) 0#i32,
  checkBool "add_u64_ovf" (u64_add_overflows 18446744073709551615#u64 1#u64) true,
  checkBool "add_u64_ok" (u64_add_overflows 100#u64 200#u64) false,
  checkBool "sub_u64_udf" (u64_sub_underflows 5#u64 6#u64) true,
  checkBool "sub_u64_ok" (u64_sub_underflows 6#u64 6#u64) false,
  checkBool "mul_u64_ovf" (u64_mul_overflows 4294967296#u64 4294967296#u64) true,
  checkBool "mul_u64_ok" (u64_mul_overflows 4294967295#u64 4294967295#u64) false,
  checkBool "mul_u64_zero" (u64_mul_overflows 0#u64 18446744073709551615#u64) false,
  checkI32 "cmp_neg_0" (cmp_i64_u64 (-1)#i64 0#u64) (-1)#i32,
  checkI32 "cmp_eq_42" (cmp_i64_u64 42#i64 42#u64) 0#i32,
  checkI32 "cmp_gt" (cmp_i64_u64 100#i64 99#u64) 1#i32,
  checkI32 "cmp_max_hi" (cmp_i64_u64 9223372036854775807#i64 9223372036854775808#u64) (-1)#i32,
  checkU64 "int_u64_42" (int_to_u64 42#i32) 42#u64,
  checkBool "teq_list" (cel_type_eq (.List .Int) (.List .Int)) true,
  checkBool "teq_diff" (cel_type_eq (.List .Int) (.List .UInt)) false,
  checkBool "asgn_dyn" (is_assignable (.Map .String .Dyn) (.Map .String .Int)) true,
  checkBool "asgn_no" (is_assignable (.Map .String .Int) (.Map .String .UInt)) false,
  checkBool "mkey_str" (is_valid_map_key_type .String) true,
  checkBool "mkey_dbl" (is_valid_map_key_type .Double) false,
  checkBool "num_u" (is_numeric_type .UInt) true,
  checkBool "num_b" (is_numeric_type .Bool) false,
  checkBool "bool_dyn" (is_bool_compat .Dyn) true,
  checkBool "id_start_u" (is_ident_start 95#i32) true,
  checkBool "id_start_0" (is_ident_start 48#i32) false,
  checkBool "id_cont_0" (is_ident_cont 48#i32) true,
  checkBool "dig_9" (is_digit 57#i32) true,
  checkI32 "hex_0" (hex_val 48#i32) 0#i32,
  checkI32 "hex_A" (hex_val 65#i32) 10#i32,
  checkI32 "hex_f" (hex_val 102#i32) 15#i32,
  checkI32 "hex_bad" (hex_val 103#i32) (-1)#i32
]

#eval IO.println (String.intercalate "\n" runAll)
