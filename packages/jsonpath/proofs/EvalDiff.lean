import Aeneas
import PionLean
import Jsonpath.Types
import Jsonpath.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion jsonpath

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"ws_sp={fmtBool (is_rfc9535_ws 32#i32)}"
  , s!"ws_tab={fmtBool (is_rfc9535_ws 9#i32)}"
  , s!"ws_lf={fmtBool (is_rfc9535_ws 10#i32)}"
  , s!"ws_cr={fmtBool (is_rfc9535_ws 13#i32)}"
  , s!"ws_vt={fmtBool (is_rfc9535_ws 11#i32)}"
  , s!"nf_A={fmtBool (is_name_first 65#i32)}"
  , s!"nf_us={fmtBool (is_name_first 95#i32)}"
  , s!"nf_utf8={fmtBool (is_name_first 0x4E2D#i32)}"
  , s!"nf_surr={fmtBool (is_name_first 0xD800#i32)}"
  , s!"nf_hi={fmtBool (is_name_first 0x110000#i32)}"
  , s!"nf_0={fmtBool (is_name_first 48#i32)}"
  , s!"nc_0={fmtBool (is_name_char 48#i32)}"
  , s!"ij_ok={fmtBool (rfc9535_ijson_step_overflow 900719925474099#i64 1#i64)}"
  , s!"ij_ovf={fmtBool (rfc9535_ijson_step_overflow 900719925474099#i64 2#i64)}"
  , s!"ij_0={fmtBool (rfc9535_ijson_step_overflow 0#i64 9#i64)}"
  , s!"ij_big={fmtBool (rfc9535_ijson_step_overflow 900719925474100#i64 0#i64)}"
  , s!"ni_pos={fmtI64 (rfc9535_normalize_index 3#i64 10#i64)}"
  , s!"ni_neg={fmtI64 (rfc9535_normalize_index (-2)#i64 10#i64)}"
  , s!"ni_under={fmtI64 (rfc9535_normalize_index (-15)#i64 10#i64)}"
  , s!"ni_zero={fmtI64 (rfc9535_normalize_index 0#i64 5#i64)}"
  , s!"ds_pos={fmtI64 (rfc9535_default_slice_start 10#i64 1#i64)}"
  , s!"ds_neg={fmtI64 (rfc9535_default_slice_start 10#i64 (-1)#i64)}"
  , s!"de_pos={fmtI64 (rfc9535_default_slice_end 10#i64 1#i64)}"
  , s!"de_neg={fmtI64 (rfc9535_default_slice_end 10#i64 (-1)#i64)}"
  , s!"cp_lo={fmtI64 (rfc9535_clamp_pos_slice (-5)#i64 10#i64)}"
  , s!"cp_mid={fmtI64 (rfc9535_clamp_pos_slice 4#i64 10#i64)}"
  , s!"cp_hi={fmtI64 (rfc9535_clamp_pos_slice 20#i64 10#i64)}"
  , s!"cp_emp={fmtI64 (rfc9535_clamp_pos_slice 5#i64 0#i64)}"
  , s!"cn_lo={fmtI64 (rfc9535_clamp_neg_slice (-5)#i64 10#i64)}"
  , s!"cn_mid={fmtI64 (rfc9535_clamp_neg_slice 4#i64 10#i64)}"
  , s!"cn_hi={fmtI64 (rfc9535_clamp_neg_slice 20#i64 10#i64)}"
  , s!"cn_emp={fmtI64 (rfc9535_clamp_neg_slice 5#i64 0#i64)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
