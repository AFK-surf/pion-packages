import Aeneas
import PionLean
import Ical.Types
import Ical.Funs

open Aeneas Aeneas.Std Result Pion ical

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtI64 (r : Result I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"wd_epoch={fmtI32 (epoch_day_weekday_mon0 0#i32)}"
  , s!"wd_neg1={fmtI32 (epoch_day_weekday_mon0 (-1)#i32)}"
  , s!"wd_neg4={fmtI32 (epoch_day_weekday_mon0 (-4)#i32)}"
  , s!"wd_p7={fmtI32 (epoch_day_weekday_mon0 7#i32)}"
  , s!"neg_ord_last={fmtI32 (neg_ordinal_day 31#i32 31#i32)}"
  , s!"neg_ord_first={fmtI32 (neg_ordinal_day 1#i32 31#i32)}"
  , s!"fdiv_0={fmtI32 (floor_div_86400 0#i64)}"
  , s!"fdiv_pos={fmtI32 (floor_div_86400 86400#i64)}"
  , s!"fdiv_neg1={fmtI32 (floor_div_86400 (-1)#i64)}"
  , s!"fdiv_neg86400={fmtI32 (floor_div_86400 (-86400)#i64)}"
  , s!"fdiv_neg86401={fmtI32 (floor_div_86400 (-86401)#i64)}"
  , s!"w1_2024_mo={fmtI32 (week1_start_of 19723#i32 0#i32)}"
  , s!"w1_2023_mo={fmtI32 (week1_start_of 19358#i32 0#i32)}"
  , s!"w1_2020_mo={fmtI32 (week1_start_of 18262#i32 0#i32)}"
  , s!"jump_past={fmtI64 (jump_grid_to 100#i64 50#i64 60#i64)}"
  , s!"jump_exact={fmtI64 (jump_grid_to 100#i64 220#i64 60#i64)}"
  , s!"jump_ceil={fmtI64 (jump_grid_to 100#i64 221#i64 60#i64)}"
  , s!"up_a={fmtI32 (ascii_upper_byte 97#i32)}"
  , s!"up_z={fmtI32 (ascii_upper_byte 122#i32)}"
  , s!"up_A={fmtI32 (ascii_upper_byte 65#i32)}"
  , s!"up_neg={fmtI32 (ascii_upper_byte (-1)#i32)}"
  , s!"name_A={fmtBool (is_ical_name_byte 65#i32)}"
  , s!"name_dash={fmtBool (is_ical_name_byte 45#i32)}"
  , s!"name_colon={fmtBool (is_ical_name_byte 58#i32)}"
  , s!"name_lf={fmtBool (is_ical_name_byte 10#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
