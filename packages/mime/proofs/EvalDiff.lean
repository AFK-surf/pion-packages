import Aeneas
import PionLean
import Mime.Types
import Mime.Funs

open Aeneas Aeneas.Std Result Pion mime

private def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

private def report (label : String) (ok_cond : Bool) : IO Unit :=
  IO.println s!"{label}: {if ok_cond then "PASS" else "FAIL"}"

def main : IO Unit := do
  report "hex_up_0" (okIs (hex_upper_digit 0#i32) 48#i32)
  report "hex_up_9" (okIs (hex_upper_digit 9#i32) 57#i32)
  report "hex_up_10" (okIs (hex_upper_digit 10#i32) 65#i32)
  report "hex_up_15" (okIs (hex_upper_digit 15#i32) 70#i32)
  report "hex_val_0" (okIs (hex_nibble_val 48#i32) 0#i32)
  report "hex_val_A" (okIs (hex_nibble_val 65#i32) 10#i32)
  report "hex_val_f" (okIs (hex_nibble_val 102#i32) 15#i32)
  report "hex_val_bad" (okIs (hex_nibble_val 103#i32) (-1)#i32)
  report "lower_A" (okIs (ascii_lower_byte 65#i32) 97#i32)
  report "lower_Z" (okIs (ascii_lower_byte 90#i32) 122#i32)
  report "lower_a" (okIs (ascii_lower_byte 97#i32) 97#i32)

  report "qp_hi_ab" (okIs (qp_hi_nibble 171#i32) 10#i32)
  report "qp_lo_ab" (okIs (qp_lo_nibble 171#i32) 11#i32)
  report "qp_pack_ab" (okIs (qp_pack_hex_byte 10#i32 11#i32) 171#i32)
  report "qp_lit_a" (okIs (qp_encode_is_literal 97#i32 false) true)
  report "qp_lit_eq" (okIs (qp_encode_is_literal 61#i32 false) false)
  report "qp_lit_eol" (okIs (qp_encode_is_literal 32#i32 true) false)
  report "qp_dec_nul" (okIs (qp_decode_allowed_literal 0#i32) false)
  report "qp_dec_tab" (okIs (qp_decode_allowed_literal 9#i32) true)
  report "qp_dec_del" (okIs (qp_decode_allowed_literal 127#i32) false)
  report "qp_wrap_75_1" (okIs (qp_needs_soft_wrap 75#i32 1#i32) true)
  report "qp_wrap_74_1" (okIs (qp_needs_soft_wrap 74#i32 1#i32) false)
  report "qp_wrap_73_3" (okIs (qp_needs_soft_wrap 73#i32 3#i32) true)

  report "tchar_a" (okIs (is_tchar_byte 97#i32) true)
  report "tchar_pct" (okIs (is_tchar_byte 37#i32) true)
  report "tchar_slash" (okIs (is_tchar_byte 47#i32) false)
  report "tchar_sp" (okIs (is_tchar_byte 32#i32) false)
  report "attr_a" (okIs (is_attr_char_byte 97#i32) true)
  report "attr_pct" (okIs (is_attr_char_byte 37#i32) false)
  report "attr_star" (okIs (is_attr_char_byte 42#i32) false)
  report "attr_apos" (okIs (is_attr_char_byte 39#i32) false)
  report "bchar_eq" (okIs (is_bchar_nospace_byte 61#i32) true)
  report "bchar_sp" (okIs (is_bchar_nospace_byte 32#i32) false)
  report "bchar_quot" (okIs (is_bchar_nospace_byte 34#i32) false)

  report "sep_slash" (okIs (is_path_sep_byte 47#i32) true)
  report "sep_bslash" (okIs (is_path_sep_byte 92#i32) true)
  report "sep_a" (okIs (is_path_sep_byte 97#i32) false)
  report "c0_nul" (okIs (is_filename_c0_or_del 0#i32) true)
  report "c0_del" (okIs (is_filename_c0_or_del 127#i32) true)
  report "c0_sp" (okIs (is_filename_c0_or_del 32#i32) false)
  report "c1_80" (okIs (is_utf8_c1_pair 194#i32 128#i32) true)
  report "c1_a0" (okIs (is_utf8_c1_pair 194#i32 160#i32) false)
  report "bidi_rlo" (okIs (is_utf8_bidi_3byte 226#i32 128#i32 174#i32) true)
  report "bidi_lri" (okIs (is_utf8_bidi_3byte 226#i32 129#i32 166#i32) true)
  report "bidi_ok" (okIs (is_utf8_bidi_3byte 226#i32 128#i32 160#i32) false)
