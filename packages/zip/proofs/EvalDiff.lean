import Aeneas
import PionLean
import Zip.Types
import Zip.Funs

open Aeneas Aeneas.Std Result Pion zip

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtDt (r : Result DosDateTime) : String :=
  match r.match with
  | .ok dt => s!"({dt.year.val},{dt.month.val},{dt.day.val},{dt.hour.val},{dt.minute.val},{dt.second.val})"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"range_ok={fmtBool (in_range64 10#i64 20#i64 30#i64)}"
  , s!"range_over={fmtBool (in_range64 10#i64 21#i64 30#i64)}"
  , s!"range_neg={fmtBool (in_range64 (-1)#i64 5#i64 30#i64)}"
  , s!"range_max_wrap={fmtBool (in_range64 9223372036854775807#i64 1#i64 100#i64)}"
  , s!"upper_a={fmtI32 (ascii_upper 97#i32)}"
  , s!"upper_z={fmtI32 (ascii_upper 122#i32)}"
  , s!"upper_A={fmtI32 (ascii_upper 65#i32)}"
  , s!"clamp_lo={fmtI32 (clamp_int (-5)#i32 1#i32 12#i32)}"
  , s!"clamp_hi={fmtI32 (clamp_int 99#i32 1#i32 12#i32)}"
  , s!"clamp_mid={fmtI32 (clamp_int 7#i32 1#i32 12#i32)}"
  , s!"dim_2000_2={fmtI32 (days_in_month 2000#i32 2#i32)}"
  , s!"dim_2100_2={fmtI32 (days_in_month 2100#i32 2#i32)}"
  , s!"dim_2024_4={fmtI32 (days_in_month 2024#i32 4#i32)}"
  , s!"dos_new_lo={fmtDt (DosDateTime.new 1970#i32 5#i32 5#i32 1#i32 1#i32 1#i32)}"
  , s!"dos_new_hi={fmtDt (DosDateTime.new 2200#i32 5#i32 5#i32 1#i32 1#i32 1#i32)}"
  , s!"dos_new_even={fmtDt (DosDateTime.new 2024#i32 2#i32 30#i32 12#i32 34#i32 57#i32)}"
  , s!"dos_rt_2024={fmtDt (do let dt := DosDateTime.mk 2024#i32 2#i32 29#i32 23#i32 59#i32 58#i32; let p ← DosDateTime.to_dos dt; DosDateTime.from_dos p.1 p.2)}"
  , s!"dos_from_max={fmtDt (DosDateTime.from_dos 65535#u32 65535#u32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
