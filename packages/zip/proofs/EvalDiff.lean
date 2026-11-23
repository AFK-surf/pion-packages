import Aeneas
import PionLean
import Zip.Types
import Zip.Funs

open Aeneas Aeneas.Std Result Pion zip

private def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

private def report (label : String) (ok_cond : Bool) : IO Unit :=
  IO.println s!"{label}: {if ok_cond then "PASS" else "FAIL"}"

def main : IO Unit := do
  report "range_ok" (okIs (in_range64 10#i64 20#i64 30#i64) true)
  report "range_over" (okIs (in_range64 10#i64 21#i64 30#i64) false)
  report "range_neg" (okIs (in_range64 (-1)#i64 5#i64 30#i64) false)
  report "range_max_wrap" (okIs (in_range64 9223372036854775807#i64 1#i64 100#i64) false)
  report "upper_a" (okIs (ascii_upper 97#i32) 65#i32)
  report "upper_z" (okIs (ascii_upper 122#i32) 90#i32)
  report "upper_A" (okIs (ascii_upper 65#i32) 65#i32)
  report "sep_slash" (okIs (is_zip_path_sep 47#i32) true)
  report "sep_bslash" (okIs (is_zip_path_sep 92#i32) true)
  report "sep_dot" (okIs (is_zip_path_sep 46#i32) false)
  report "forb_nul" (okIs (is_zip_forbidden_byte 0#i32) true)
  report "forb_colon" (okIs (is_zip_forbidden_byte 58#i32) true)
  report "forb_del" (okIs (is_zip_forbidden_byte 127#i32) true)
  report "forb_a" (okIs (is_zip_forbidden_byte 97#i32) false)
  report "tail_dot" (okIs (is_zip_forbidden_seg_tail 46#i32) true)
  report "tail_sp" (okIs (is_zip_forbidden_seg_tail 32#i32) true)
  report "tail_a" (okIs (is_zip_forbidden_seg_tail 97#i32) false)
  report "win3_con" (okIs (is_win_reserved_3 99#i32 111#i32 110#i32) true)
  report "win3_nul" (okIs (is_win_reserved_3 78#i32 85#i32 76#i32) true)
  report "win3_foo" (okIs (is_win_reserved_3 102#i32 111#i32 111#i32) false)
  report "win4_com1" (okIs (is_win_reserved_4 99#i32 111#i32 109#i32 49#i32) true)
  report "win4_lpt9" (okIs (is_win_reserved_4 76#i32 80#i32 84#i32 57#i32) true)
  report "win4_com0" (okIs (is_win_reserved_4 67#i32 79#i32 77#i32 48#i32) false)

  report "clamp_lo" (okIs (clamp_int (-5)#i32 1#i32 12#i32) 1#i32)
  report "clamp_hi" (okIs (clamp_int 99#i32 1#i32 12#i32) 12#i32)
  report "clamp_mid" (okIs (clamp_int 7#i32 1#i32 12#i32) 7#i32)
  report "dim_2000_2" (okIs (days_in_month 2000#i32 2#i32) 29#i32)
  report "dim_2100_2" (okIs (days_in_month 2100#i32 2#i32) 28#i32)
  report "dim_2024_4" (okIs (days_in_month 2024#i32 4#i32) 30#i32)
  report "dos_def_y" (okIs (do let dt ← DosDateTime.default; ok dt.year) 1980#i32)
  report "dos_new_lo" (okIs (do let dt ← DosDateTime.new 1970#i32 5#i32 5#i32 1#i32 1#i32 1#i32; ok dt.year) 1980#i32)
  report "dos_new_hi" (okIs (do let dt ← DosDateTime.new 2200#i32 5#i32 5#i32 1#i32 1#i32 1#i32; ok dt.year) 2107#i32)
  report "dos_new_even" (okIs (do let dt ← DosDateTime.new 2024#i32 2#i32 30#i32 12#i32 34#i32 57#i32; ok (dt.day == 29#i32 && dt.second == 56#i32)) true)
  report "dos_rt_2024" (okIs (do
    let dt := DosDateTime.mk 2024#i32 2#i32 29#i32 23#i32 59#i32 58#i32
    let p ← DosDateTime.to_dos dt
    let dt2 ← DosDateTime.from_dos p.1 p.2
    ok (dt2.year == 2024#i32 && dt2.month == 2#i32 && dt2.day == 29#i32 &&
        dt2.hour == 23#i32 && dt2.minute == 59#i32 && dt2.second == 58#i32)) true)
  report "dos_from_max" (okIs (do
    let dt ← DosDateTime.from_dos 65535#u32 65535#u32
    ok (dt.year == 2107#i32 && dt.month == 12#i32 && dt.day == 31#i32 &&
        dt.hour == 23#i32 && dt.minute == 59#i32 && dt.second == 58#i32)) true)
