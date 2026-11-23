import Aeneas
import PionLean
import Email.Types
import Email.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion email

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"hl_A={fmtI32 (hdr_ascii_lower 65#i32)}"
  , s!"hl_Z={fmtI32 (hdr_ascii_lower 90#i32)}"
  , s!"hl_a={fmtI32 (hdr_ascii_lower 97#i32)}"
  , s!"hl_neg={fmtI32 (hdr_ascii_lower (-1)#i32)}"
  , s!"ft_A={fmtBool (email_is_ftext 65#i32)}"
  , s!"ft_colon={fmtBool (email_is_ftext 58#i32)}"
  , s!"ft_sp={fmtBool (email_is_ftext 32#i32)}"
  , s!"ft_del={fmtBool (email_is_ftext 127#i32)}"
  , s!"inj_nul={fmtBool (email_is_injection_byte 0#i32)}"
  , s!"inj_lf={fmtBool (email_is_injection_byte 10#i32)}"
  , s!"inj_cr={fmtBool (email_is_injection_byte 13#i32)}"
  , s!"inj_sp={fmtBool (email_is_injection_byte 32#i32)}"
  , s!"at_A={fmtBool (addr_is_atext 65#i32)}"
  , s!"at_plus={fmtBool (addr_is_atext 43#i32)}"
  , s!"at_utf8={fmtBool (addr_is_atext 200#i32)}"
  , s!"at_at={fmtBool (addr_is_atext 64#i32)}"
  , s!"at_dot={fmtBool (addr_is_atext 46#i32)}"
  , s!"dt_0={fmtBool (addr_is_dtext 48#i32)}"
  , s!"dt_lbr={fmtBool (addr_is_dtext 91#i32)}"
  , s!"dt_bs={fmtBool (addr_is_dtext 92#i32)}"
  , s!"qt_sp={fmtBool (addr_is_qtext_char 32#i32)}"
  , s!"qt_lf={fmtBool (addr_is_qtext_char 10#i32)}"
  , s!"qt_del={fmtBool (addr_is_qtext_char 127#i32)}"
  , s!"dig_0={fmtBool (dt_is_digit 48#i32)}"
  , s!"dig_a={fmtBool (dt_is_digit 97#i32)}"
  , s!"voff_ok={fmtBool (dt_is_valid_offset_seconds 86340#i32)}"
  , s!"voff_hi={fmtBool (dt_is_valid_offset_seconds 86341#i32)}"
  , s!"noff_pos={fmtI32 (dt_numeric_offset_seconds 43#i32 9#i32 0#i32)}"
  , s!"noff_neg={fmtI32 (dt_numeric_offset_seconds 45#i32 5#i32 30#i32)}"
  , s!"eday_pos={fmtI64 (dt_epoch_floor_day 90000#i64)}"
  , s!"erem_pos={fmtI64 (dt_epoch_rem_sec 90000#i64)}"
  , s!"eday_neg={fmtI64 (dt_epoch_floor_day (-1)#i64)}"
  , s!"erem_neg={fmtI64 (dt_epoch_rem_sec (-1)#i64)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
