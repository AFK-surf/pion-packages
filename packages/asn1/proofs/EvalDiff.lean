import Aeneas
import PionLean
import Asn1.Types
import Asn1.Funs

open Aeneas Aeneas.Std Result Pion asn1

private def fmtI32 (r : Result I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtTagClass (r : Result TagClass) : String :=
  match r.match with
  | .ok .Universal => "Universal"
  | .ok .Application => "Application"
  | .ok .ContextSpecific => "ContextSpecific"
  | .ok .Private => "Private"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"cls_code_univ={fmtI32 (tag_class_code .Universal)}"
  , s!"cls_code_priv={fmtI32 (tag_class_code .Private)}"
  , s!"cls_from_2={fmtTagClass (tag_class_from_code 2#i32)}"
  , s!"cls_from_oob={fmtTagClass (tag_class_from_code 99#i32)}"
  , s!"enc_seq={fmtI32 (encode_tag_first_byte .Universal true 16#i32)}"
  , s!"enc_ctx0={fmtI32 (encode_tag_first_byte .ContextSpecific true 0#i32)}"
  , s!"enc_hi={fmtI32 (encode_tag_first_byte .Application false 40#i32)}"
  , s!"enc_neg={fmtI32 (encode_tag_first_byte .Private false (-5)#i32)}"
  , s!"dec_cls_seq={fmtTagClass (decode_tag_class_byte 48#i32)}"
  , s!"dec_cls_ctx={fmtTagClass (decode_tag_class_byte 160#i32)}"
  , s!"dec_con_seq={fmtBool (decode_tag_constructed_byte 48#i32)}"
  , s!"dec_con_int={fmtBool (decode_tag_constructed_byte 2#i32)}"
  , s!"dec_low_seq={fmtI32 (decode_tag_low_byte 48#i32)}"
  , s!"dec_low_hi={fmtI32 (decode_tag_low_byte 95#i32)}"
  , s!"int_red_0={fmtBool (is_canonical_der_int_pair 0#i32 127#i32)}"
  , s!"int_ok_0={fmtBool (is_canonical_der_int_pair 0#i32 128#i32)}"
  , s!"int_red_ff={fmtBool (is_canonical_der_int_pair 255#i32 128#i32)}"
  , s!"int_ok_ff={fmtBool (is_canonical_der_int_pair 255#i32 127#i32)}"
  , s!"bs_empty_0={fmtBool (is_valid_bit_string_padding 0#i32 0#i32 0#i32)}"
  , s!"bs_empty_1={fmtBool (is_valid_bit_string_padding 0#i32 1#i32 0#i32)}"
  , s!"bs_pad_ok={fmtBool (is_valid_bit_string_padding 2#i32 3#i32 248#i32)}"
  , s!"bs_pad_bad={fmtBool (is_valid_bit_string_padding 2#i32 3#i32 249#i32)}"
  , s!"bs_oob_u8={fmtBool (is_valid_bit_string_padding 2#i32 8#i32 0#i32)}"
  , s!"bs_neg_u={fmtBool (is_valid_bit_string_padding 2#i32 (-1)#i32 0#i32)}"
  , s!"len_neg={fmtI32 (der_length_encoded_size (-1)#i32)}"
  , s!"len_127={fmtI32 (der_length_encoded_size 127#i32)}"
  , s!"len_128={fmtI32 (der_length_encoded_size 128#i32)}"
  , s!"len_256={fmtI32 (der_length_encoded_size 256#i32)}"
  , s!"len_65536={fmtI32 (der_length_encoded_size 65536#i32)}"
  , s!"len_16m={fmtI32 (der_length_encoded_size 16777216#i32)}"
  , s!"len_max={fmtI32 (der_length_encoded_size 2147483647#i32)}"
  , s!"leap_2000={fmtBool (is_leap_year 2000#i32)}"
  , s!"leap_1900={fmtBool (is_leap_year 1900#i32)}"
  , s!"leap_2024={fmtBool (is_leap_year 2024#i32)}"
  , s!"dim_feb_l={fmtI32 (days_in_month 2024#i32 2#i32)}"
  , s!"dim_feb_n={fmtI32 (days_in_month 2023#i32 2#i32)}"
  , s!"dim_apr={fmtI32 (days_in_month 2024#i32 4#i32)}"
  , s!"dim_bad0={fmtI32 (days_in_month 2024#i32 0#i32)}"
  , s!"dim_bad13={fmtI32 (days_in_month 2024#i32 13#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
