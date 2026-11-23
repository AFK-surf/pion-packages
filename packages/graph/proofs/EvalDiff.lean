import Graph.Types
import Graph.Funs

open Aeneas Aeneas.Std Result Pion graph

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtU64 (r : Result Std.U64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtOptI64 (r : Result (Option Std.I64)) : String :=
  match r.match with
  | .ok none => "None"
  | .ok (some v) => s!"Some({v.val})"
  | _ => "TRAP"

private def i64Min : Std.I64 := Pion.I64.sub (-9223372036854775807)#i64 1#i64

private def runAll : List String :=
  [ s!"cadd_10_20={fmtOptI64 (checked_add_i64 10#i64 20#i64)}"
  , s!"cadd_max_0={fmtOptI64 (checked_add_i64 9223372036854775807#i64 0#i64)}"
  , s!"cadd_max_1={fmtOptI64 (checked_add_i64 9223372036854775807#i64 1#i64)}"
  , s!"cadd_min_m1={fmtOptI64 (checked_add_i64 i64Min (-1)#i64)}"
  , s!"cadd_max_nmax={fmtOptI64 (checked_add_i64 9223372036854775807#i64 (-9223372036854775807)#i64)}"
  , s!"fits_0_max={fmtBool (fits_i64 0#i64 9223372036854775807#u64)}"
  , s!"fits_0_sb={fmtBool (fits_i64 0#i64 9223372036854775808#u64)}"
  , s!"fits_m1_sb={fmtBool (fits_i64 (-1)#i64 9223372036854775808#u64)}"
  , s!"fits_m1_hm={fmtBool (fits_i64 (-1)#i64 9223372036854775807#u64)}"
  , s!"fits_1_0={fmtBool (fits_i64 1#i64 0#u64)}"
  , s!"sign_hi_pos={fmtI64 (i64_sign_hi 42#i64)}"
  , s!"sign_hi_neg={fmtI64 (i64_sign_hi (-42)#i64)}"
  , s!"carry_0={fmtI64 (i128_add_carry 100#u64 200#u64)}"
  , s!"carry_1={fmtI64 (i128_add_carry 18446744073709551615#u64 1#u64)}"
  , s!"i128_lt_hi={fmtBool (i128_lt (-1)#i64 100#u64 0#i64 0#u64)}"
  , s!"i128_lt_lo={fmtBool (i128_lt 0#i64 5#u64 0#i64 6#u64)}"
  , s!"i128_lt_eq={fmtBool (i128_lt 0#i64 5#u64 0#i64 5#u64)}"
  , s!"radix_min={fmtU64 (i64_to_radix_key i64Min)}"
  , s!"radix_0={fmtU64 (i64_to_radix_key 0#i64)}"
  , s!"radix_max={fmtU64 (i64_to_radix_key 9223372036854775807#i64)}"
  , s!"fwd_5={fmtI32 (forward_half_edge 5#i32)}"
  , s!"twin_10={fmtI32 (residual_twin 10#i32)}"
  , s!"twin_11={fmtI32 (residual_twin 11#i32)}"
  , s!"hp_1={fmtI32 (heap_parent 1#i32)}"
  , s!"hp_2={fmtI32 (heap_parent 2#i32)}"
  , s!"hp_7={fmtI32 (heap_parent 7#i32)}"
  , s!"hl_0={fmtI32 (heap_left_child 0#i32)}"
  , s!"hl_3={fmtI32 (heap_left_child 3#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
