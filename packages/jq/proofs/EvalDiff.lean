import Aeneas
import PionLean
import Jq.Types
import Jq.Funs

open Aeneas Aeneas.Std Result Pion jq

private def checkBool (label : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkI32 (label : String) (r : Result I32) (expected : I32) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def runAll : List String := [
  checkBool "ws_sp" (is_json_ws 32#i32) true,
  checkBool "ws_tab" (is_json_ws 9#i32) true,
  checkBool "ws_lf" (is_json_ws 10#i32) true,
  checkBool "ws_cr" (is_json_ws 13#i32) true,
  checkBool "ws_vt" (is_json_ws 11#i32) false,
  checkBool "fast_a" (is_json_str_fast_byte 97#i32) true,
  checkBool "fast_quote" (is_json_str_fast_byte 34#i32) false,
  checkBool "fast_bs" (is_json_str_fast_byte 92#i32) false,
  checkBool "fast_ctrl" (is_json_str_fast_byte 31#i32) false,
  checkBool "fast_nonascii" (is_json_str_fast_byte 128#i32) false,
  checkBool "ident_A" (is_ident_char 65#i32) true,
  checkBool "ident_9" (is_ident_char 57#i32) true,
  checkBool "ident_us" (is_ident_char 95#i32) true,
  checkBool "ident_dash" (is_ident_char 45#i32) false,
  checkI32 "hex_0" (hex_val 48#i32) 0#i32,
  checkI32 "hex_F" (hex_val 70#i32) 15#i32,
  checkI32 "hex_a" (hex_val 97#i32) 10#i32,
  checkI32 "hex_bad" (hex_val 122#i32) (-1)#i32,
  checkI32 "san_ok" (sanitize_utf8_cp 65#i32) 65#i32,
  checkI32 "san_neg" (sanitize_utf8_cp (-1)#i32) 65533#i32,
  checkI32 "san_surr" (sanitize_utf8_cp 55296#i32) 65533#i32,
  checkI32 "san_hi" (sanitize_utf8_cp 1114112#i32) 65533#i32,
  checkBool "hi_surr" (is_high_surrogate 55357#i32) true,
  checkBool "lo_surr" (is_low_surrogate 56832#i32) true,
  checkI32 "surr_emoji" (decode_surrogate_pair 55357#i32 56832#i32) 128512#i32,
  checkI32 "surr_min" (decode_surrogate_pair 55296#i32 56320#i32) 65536#i32,
  checkI32 "surr_max" (decode_surrogate_pair 56319#i32 57343#i32) 1114111#i32,
  checkI32 "clamp_mid" (clamp_slice_idx 3#i32 10#i32) 3#i32,
  checkI32 "clamp_neg" (clamp_slice_idx (-2)#i32 10#i32) 8#i32,
  checkI32 "clamp_under" (clamp_slice_idx (-50)#i32 10#i32) 0#i32,
  checkI32 "clamp_over" (clamp_slice_idx 50#i32 10#i32) 10#i32,
  checkI32 "clamp_i32min" (clamp_slice_idx (-2147483648)#i32 10#i32) 0#i32,
  checkI32 "clamp64_lo" (clamp_slice_i64 (-5000000000)#i64 10#i32) 0#i32,
  checkI32 "clamp64_hi" (clamp_slice_i64 5000000000#i64 10#i32) 10#i32,
  checkI32 "clamp64_neg" (clamp_slice_i64 (-3)#i64 10#i32) 7#i32
]

#eval IO.println (String.intercalate "\n" runAll)
