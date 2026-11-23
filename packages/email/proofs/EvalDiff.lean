import Aeneas
import PionLean
import Email.Types
import Email.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion email

def checkBool (lbl : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def checkI32 (lbl : String) (r : Result Std.I32) (expected : Std.I32) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def checkI64 (lbl : String) (r : Result Std.I64) (expected : Std.I64) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def runAll : List String := [
  -- EmailLimits::default (2)
  checkI32 "lim_depth" (do let l ← EmailLimits.default; ok l.max_depth) 16#i32,
  checkI32 "lim_body" (do let l ← EmailLimits.default; ok l.max_body_bytes) 67108864#i32,
  -- hdr_ascii_lower & dt_lower (4)
  checkI32 "hl_A" (hdr_ascii_lower 65#i32) 97#i32,
  checkI32 "hl_Z" (hdr_ascii_lower 90#i32) 122#i32,
  checkI32 "hl_a" (hdr_ascii_lower 97#i32) 97#i32,
  checkI32 "dl_M" (dt_lower 77#i32) 109#i32,
  -- email_is_ftext (4)
  checkBool "ft_A" (email_is_ftext 65#i32) true,
  checkBool "ft_colon" (email_is_ftext 58#i32) false,
  checkBool "ft_sp" (email_is_ftext 32#i32) false,
  checkBool "ft_del" (email_is_ftext 127#i32) false,
  -- email_is_injection_byte (4)
  checkBool "inj_nul" (email_is_injection_byte 0#i32) true,
  checkBool "inj_lf" (email_is_injection_byte 10#i32) true,
  checkBool "inj_cr" (email_is_injection_byte 13#i32) true,
  checkBool "inj_sp" (email_is_injection_byte 32#i32) false,
  -- email_effective_fold_limit (3)
  checkI32 "fold_0" (email_effective_fold_limit 0#i32) 78#i32,
  checkI32 "fold_19" (email_effective_fold_limit 19#i32) 78#i32,
  checkI32 "fold_72" (email_effective_fold_limit 72#i32) 72#i32,
  -- addr_is_atext (5)
  checkBool "at_A" (addr_is_atext 65#i32) true,
  checkBool "at_plus" (addr_is_atext 43#i32) true,
  checkBool "at_utf8" (addr_is_atext 200#i32) true,
  checkBool "at_at" (addr_is_atext 64#i32) false,
  checkBool "at_dot" (addr_is_atext 46#i32) false,
  -- addr_is_dtext (3)
  checkBool "dt_0" (addr_is_dtext 48#i32) true,
  checkBool "dt_lbr" (addr_is_dtext 91#i32) false,
  checkBool "dt_bs" (addr_is_dtext 92#i32) false,
  -- addr_is_qtext_char (3)
  checkBool "qt_sp" (addr_is_qtext_char 32#i32) true,
  checkBool "qt_lf" (addr_is_qtext_char 10#i32) false,
  checkBool "qt_del" (addr_is_qtext_char 127#i32) false,
  -- dt_is_digit (2)
  checkBool "dig_0" (dt_is_digit 48#i32) true,
  checkBool "dig_a" (dt_is_digit 97#i32) false,
  -- dt_normalize_year (4)
  checkI32 "yr_2_49" (dt_normalize_year 49#i32 2#i32) 2049#i32,
  checkI32 "yr_2_50" (dt_normalize_year 50#i32 2#i32) 1950#i32,
  checkI32 "yr_3_126" (dt_normalize_year 126#i32 3#i32) 2026#i32,
  checkI32 "yr_4_2026" (dt_normalize_year 2026#i32 4#i32) 2026#i32,
  -- dt_clamp_leap_second (2)
  checkI32 "leap_60" (dt_clamp_leap_second 60#i32) 59#i32,
  checkI32 "leap_42" (dt_clamp_leap_second 42#i32) 42#i32,
  -- dt_is_valid_offset_seconds & dt_numeric_offset_seconds (4)
  checkBool "voff_ok" (dt_is_valid_offset_seconds 86340#i32) true,
  checkBool "voff_hi" (dt_is_valid_offset_seconds 86341#i32) false,
  checkI32 "noff_pos" (dt_numeric_offset_seconds 43#i32 9#i32 0#i32) 32400#i32,
  checkI32 "noff_neg" (dt_numeric_offset_seconds 45#i32 5#i32 30#i32) (-19800)#i32,
  -- dt_epoch_floor_day & dt_epoch_rem_sec (4)
  checkI64 "eday_pos" (dt_epoch_floor_day 90000#i64) 1#i64,
  checkI64 "erem_pos" (dt_epoch_rem_sec 90000#i64) 3600#i64,
  checkI64 "eday_neg" (dt_epoch_floor_day (-1)#i64) (-1)#i64,
  checkI64 "erem_neg" (dt_epoch_rem_sec (-1)#i64) 86399#i64
]

#eval IO.println (String.intercalate "\n" runAll)
