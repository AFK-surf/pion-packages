import Aeneas
import PionLean
import Jq.Types
import Jq.Funs

open Aeneas Aeneas.Std Result Pion jq

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"hex_0={fmtI32 (hex_val 48#i32)}"
  , s!"hex_F={fmtI32 (hex_val 70#i32)}"
  , s!"hex_a={fmtI32 (hex_val 97#i32)}"
  , s!"hex_bad={fmtI32 (hex_val 122#i32)}"
  , s!"hex_min={fmtI32 (hex_val (-2147483648)#i32)}"
  , s!"san_ok={fmtI32 (sanitize_utf8_cp 65#i32)}"
  , s!"san_neg={fmtI32 (sanitize_utf8_cp (-1)#i32)}"
  , s!"san_surr={fmtI32 (sanitize_utf8_cp 55296#i32)}"
  , s!"san_hi={fmtI32 (sanitize_utf8_cp 1114112#i32)}"
  , s!"hi_surr_t={fmtBool (is_high_surrogate 55357#i32)}"
  , s!"hi_surr_f={fmtBool (is_high_surrogate 56320#i32)}"
  , s!"lo_surr_t={fmtBool (is_low_surrogate 56832#i32)}"
  , s!"lo_surr_f={fmtBool (is_low_surrogate 55296#i32)}"
  , s!"surr_emoji={fmtI32 (decode_surrogate_pair 55357#i32 56832#i32)}"
  , s!"surr_min={fmtI32 (decode_surrogate_pair 55296#i32 56320#i32)}"
  , s!"surr_max={fmtI32 (decode_surrogate_pair 56319#i32 57343#i32)}"
  , s!"clamp_mid={fmtI32 (clamp_slice_idx 3#i32 10#i32)}"
  , s!"clamp_neg={fmtI32 (clamp_slice_idx (-2)#i32 10#i32)}"
  , s!"clamp_under={fmtI32 (clamp_slice_idx (-50)#i32 10#i32)}"
  , s!"clamp_over={fmtI32 (clamp_slice_idx 50#i32 10#i32)}"
  , s!"clamp_i32min={fmtI32 (clamp_slice_idx (-2147483648)#i32 10#i32)}"
  , s!"clamp64_lo={fmtI32 (clamp_slice_i64 (-5000000000)#i64 10#i32)}"
  , s!"clamp64_hi={fmtI32 (clamp_slice_i64 5000000000#i64 10#i32)}"
  , s!"clamp64_neg={fmtI32 (clamp_slice_i64 (-3)#i64 10#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
