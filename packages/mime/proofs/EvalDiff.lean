import Aeneas
import PionLean
import Mime.Types
import Mime.Funs

open Aeneas Aeneas.Std Result Pion mime

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"hex_up_0={fmtI32 (hex_upper_digit 0#i32)}"
  , s!"hex_up_9={fmtI32 (hex_upper_digit 9#i32)}"
  , s!"hex_up_10={fmtI32 (hex_upper_digit 10#i32)}"
  , s!"hex_up_15={fmtI32 (hex_upper_digit 15#i32)}"
  , s!"hex_val_0={fmtI32 (hex_nibble_val 48#i32)}"
  , s!"hex_val_A={fmtI32 (hex_nibble_val 65#i32)}"
  , s!"hex_val_f={fmtI32 (hex_nibble_val 102#i32)}"
  , s!"hex_val_bad={fmtI32 (hex_nibble_val 103#i32)}"
  , s!"lower_A={fmtI32 (ascii_lower_byte 65#i32)}"
  , s!"lower_Z={fmtI32 (ascii_lower_byte 90#i32)}"
  , s!"lower_a={fmtI32 (ascii_lower_byte 97#i32)}"
  , s!"qp_hi_ab={fmtI32 (qp_hi_nibble 171#i32)}"
  , s!"qp_lo_ab={fmtI32 (qp_lo_nibble 171#i32)}"
  , s!"qp_pack_ab={fmtI32 (qp_pack_hex_byte 10#i32 11#i32)}"
  , s!"qp_lit_a={fmtBool (qp_encode_is_literal 97#i32 false)}"
  , s!"qp_lit_eq={fmtBool (qp_encode_is_literal 61#i32 false)}"
  , s!"qp_lit_eol={fmtBool (qp_encode_is_literal 32#i32 true)}"
  , s!"qp_dec_nul={fmtBool (qp_decode_allowed_literal 0#i32)}"
  , s!"qp_dec_tab={fmtBool (qp_decode_allowed_literal 9#i32)}"
  , s!"qp_dec_del={fmtBool (qp_decode_allowed_literal 127#i32)}"
  , s!"qp_wrap_75_1={fmtBool (qp_needs_soft_wrap 75#i32 1#i32)}"
  , s!"qp_wrap_74_1={fmtBool (qp_needs_soft_wrap 74#i32 1#i32)}"
  , s!"qp_wrap_73_3={fmtBool (qp_needs_soft_wrap 73#i32 3#i32)}"
  , s!"tchar_a={fmtBool (is_tchar_byte 97#i32)}"
  , s!"tchar_pct={fmtBool (is_tchar_byte 37#i32)}"
  , s!"tchar_slash={fmtBool (is_tchar_byte 47#i32)}"
  , s!"attr_a={fmtBool (is_attr_char_byte 97#i32)}"
  , s!"attr_pct={fmtBool (is_attr_char_byte 37#i32)}"
  , s!"bchar_eq={fmtBool (is_bchar_nospace_byte 61#i32)}"
  , s!"bchar_sp={fmtBool (is_bchar_nospace_byte 32#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
