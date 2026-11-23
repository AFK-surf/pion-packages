import Aeneas
import PionLean
import Asn1.Types
import Asn1.Funs

open Aeneas Aeneas.Std Result Pion asn1

private def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

private def report (label : String) (ok_cond : Bool) : IO Unit :=
  IO.println s!"{label}: {if ok_cond then "PASS" else "FAIL"}"

def main : IO Unit := do
  report "cls_univ" (okIs (tag_class_code .Universal) 0#i32)
  report "cls_priv" (okIs (tag_class_code .Private) 3#i32)
  report "cls_from_2" (okIs (tag_class_from_code 2#i32) .ContextSpecific)
  report "cls_eq_t" (okIs (tag_class_equals .Application .Application) true)
  report "cls_eq_f" (okIs (tag_class_equals .Universal .Private) false)
  report "tag_eq_t" (okIs (Tag.equals (Tag.mk .Universal true 16#i32) (Tag.mk .Universal true 16#i32)) true)
  report "tag_eq_f" (okIs (Tag.equals (Tag.mk .Universal true 16#i32) (Tag.mk .Universal false 16#i32)) false)

  report "enc_seq" (okIs (encode_tag_first_byte .Universal true 16#i32) 48#i32)
  report "enc_ctx0" (okIs (encode_tag_first_byte .ContextSpecific true 0#i32) 160#i32)
  report "enc_hi" (okIs (encode_tag_first_byte .Application false 40#i32) 95#i32)
  report "dec_cls_seq" (okIs (decode_tag_class_byte 48#i32) .Universal)
  report "dec_cls_ctx" (okIs (decode_tag_class_byte 160#i32) .ContextSpecific)
  report "dec_con_seq" (okIs (decode_tag_constructed_byte 48#i32) true)
  report "dec_con_int" (okIs (decode_tag_constructed_byte 2#i32) false)
  report "dec_low_seq" (okIs (decode_tag_low_byte 48#i32) 16#i32)
  report "dec_low_hi" (okIs (decode_tag_low_byte 95#i32) 31#i32)

  report "bool_0" (okIs (is_canonical_der_bool_byte 0#i32) true)
  report "bool_ff" (okIs (is_canonical_der_bool_byte 255#i32) true)
  report "bool_1" (okIs (is_canonical_der_bool_byte 1#i32) false)
  report "int_red_0" (okIs (is_canonical_der_int_pair 0#i32 127#i32) false)
  report "int_ok_0" (okIs (is_canonical_der_int_pair 0#i32 128#i32) true)
  report "int_red_ff" (okIs (is_canonical_der_int_pair 255#i32 128#i32) false)
  report "int_ok_ff" (okIs (is_canonical_der_int_pair 255#i32 127#i32) true)
  report "bs_empty_0" (okIs (is_valid_bit_string_padding 0#i32 0#i32 0#i32) true)
  report "bs_empty_1" (okIs (is_valid_bit_string_padding 0#i32 1#i32 0#i32) false)
  report "bs_pad_ok" (okIs (is_valid_bit_string_padding 2#i32 3#i32 248#i32) true)
  report "bs_pad_bad" (okIs (is_valid_bit_string_padding 2#i32 3#i32 249#i32) false)
  report "bs_bad_u8" (okIs (is_valid_bit_string_padding 2#i32 8#i32 0#i32) false)
  report "len_1" (okIs (der_length_encoded_size 127#i32) 1#i32)
  report "len_2" (okIs (der_length_encoded_size 128#i32) 2#i32)
  report "len_3" (okIs (der_length_encoded_size 256#i32) 3#i32)
  report "len_4" (okIs (der_length_encoded_size 65536#i32) 4#i32)
  report "len_5" (okIs (der_length_encoded_size 16777216#i32) 5#i32)

  report "leap_2000" (okIs (is_leap_year 2000#i32) true)
  report "leap_1900" (okIs (is_leap_year 1900#i32) false)
  report "leap_2024" (okIs (is_leap_year 2024#i32) true)
  report "dim_feb_l" (okIs (days_in_month 2024#i32 2#i32) 29#i32)
  report "dim_feb_n" (okIs (days_in_month 2023#i32 2#i32) 28#i32)
  report "dim_apr" (okIs (days_in_month 2024#i32 4#i32) 30#i32)
  report "dim_bad" (okIs (days_in_month 2024#i32 13#i32) 0#i32)
  report "utc_50" (okIs (utc_time_expand_year 50#i32) 1950#i32)
  report "utc_49" (okIs (utc_time_expand_year 49#i32) 2049#i32)
  report "hms_ok" (okIs (is_valid_hms 23#i32 59#i32 59#i32) true)
  report "hms_bad" (okIs (is_valid_hms 24#i32 0#i32 0#i32) false)
  report "pem_A" (okIs (is_pem_label_char 65#i32) true)
  report "pem_sp" (okIs (is_pem_label_char 32#i32) false)
  report "pem_dash" (okIs (is_pem_label_char 45#i32) false)
  report "ku_ca" (okIs ((KeyUsage.mk 32#i32).key_cert_sign) true)
  report "ku_ca_ds" (okIs ((KeyUsage.mk 32#i32).digital_signature) false)
  report "ku_all_do" (okIs ((KeyUsage.mk 511#i32).decipher_only) true)
