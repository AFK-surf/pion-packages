import Aeneas
import PionLean
import Ical.Types
import Ical.Funs

open Aeneas Aeneas.Std Result Pion ical

private def checkBool (label : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkI32 (label : String) (r : Result I32) (expected : I32) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkI64 (label : String) (r : Result I64) (expected : I64) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def runAll : List String := [
  checkI32 "wd_epoch" (epoch_day_weekday_mon0 0#i32) 3#i32,
  checkI32 "wd_neg1" (epoch_day_weekday_mon0 (-1)#i32) 2#i32,
  checkI32 "wd_neg4" (epoch_day_weekday_mon0 (-4)#i32) 6#i32,
  checkI32 "wd_p7" (epoch_day_weekday_mon0 7#i32) 3#i32,
  checkI32 "doy_jan1" (doy_of 19723#i32 19723#i32) 1#i32,
  checkI32 "doy_dec31" (doy_of 20088#i32 19723#i32) 366#i32,
  checkI32 "neg_ord_last" (neg_ordinal_day 31#i32 31#i32) (-1)#i32,
  checkI32 "neg_ord_first" (neg_ordinal_day 1#i32 31#i32) (-31)#i32,
  checkI32 "fdiv_0" (floor_div_86400 0#i64) 0#i32,
  checkI32 "fdiv_pos" (floor_div_86400 86400#i64) 1#i32,
  checkI32 "fdiv_neg1" (floor_div_86400 (-1)#i64) (-1)#i32,
  checkI32 "fdiv_neg86400" (floor_div_86400 (-86400)#i64) (-1)#i32,
  checkI32 "fdiv_neg86401" (floor_div_86400 (-86401)#i64) (-2)#i32,
  checkI32 "w1_2024_mo" (week1_start_of 19723#i32 0#i32) 19723#i32,
  checkI32 "w1_2023_mo" (week1_start_of 19358#i32 0#i32) 19359#i32,
  checkI32 "w1_2020_mo" (week1_start_of 18262#i32 0#i32) 18260#i32,
  checkI64 "jump_past" (jump_grid_to 100#i64 50#i64 60#i64) 160#i64,
  checkI64 "jump_exact" (jump_grid_to 100#i64 220#i64 60#i64) 220#i64,
  checkI64 "jump_ceil" (jump_grid_to 100#i64 221#i64 60#i64) 280#i64,
  checkI32 "up_a" (ascii_upper_byte 97#i32) 65#i32,
  checkI32 "up_z" (ascii_upper_byte 122#i32) 90#i32,
  checkI32 "up_A" (ascii_upper_byte 65#i32) 65#i32,
  checkBool "name_A" (is_ical_name_byte 65#i32) true,
  checkBool "name_dash" (is_ical_name_byte 45#i32) true,
  checkBool "name_colon" (is_ical_name_byte 58#i32) false,
  checkBool "name_lf" (is_ical_name_byte 10#i32) false,
  checkI32 "leap_60" (clamp_leap_second 60#i32) 59#i32,
  checkI32 "leap_59" (clamp_leap_second 59#i32) 59#i32,
  checkI32 "pw_MO" (parse_weekday_2_bytes 77#i32 79#i32) 0#i32,
  checkI32 "pw_su" (parse_weekday_2_bytes 115#i32 117#i32) 6#i32,
  checkI32 "pw_bad" (parse_weekday_2_bytes 88#i32 88#i32) (-1)#i32
]

#eval IO.println (String.intercalate "\n" runAll)
