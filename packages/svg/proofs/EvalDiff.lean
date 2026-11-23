import Aeneas
import PionLean
import Svg.Types
import Svg.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion svg

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"cl_neg={fmtI32 (clamp_u8_int (-5)#i32)}"
  , s!"cl_0={fmtI32 (clamp_u8_int 0#i32)}"
  , s!"cl_128={fmtI32 (clamp_u8_int 128#i32)}"
  , s!"cl_hi={fmtI32 (clamp_u8_int 300#i32)}"
  , s!"hn_0={fmtI32 (hex_nibble_code 0#i32)}"
  , s!"hn_9={fmtI32 (hex_nibble_code 9#i32)}"
  , s!"hn_10={fmtI32 (hex_nibble_code 10#i32)}"
  , s!"hn_15={fmtI32 (hex_nibble_code 15#i32)}"
  , s!"hp_ab={fmtI32 (hex_pair_to_byte 10#i32 11#i32)}"
  , s!"hp_ff={fmtI32 (hex_pair_to_byte 15#i32 15#i32)}"
  , s!"sws_sp={fmtBool (is_svg_ws 32#i32)}"
  , s!"sws_ff={fmtBool (is_svg_ws 12#i32)}"
  , s!"sws_a={fmtBool (is_svg_ws 97#i32)}"
  , s!"xws_sp={fmtBool (is_xml_ws 32#i32)}"
  , s!"xws_ff={fmtBool (is_xml_ws 12#i32)}"
  , s!"xws_cr={fmtBool (is_xml_ws 13#i32)}"
  , s!"dig_0={fmtBool (is_ascii_digit 48#i32)}"
  , s!"dig_a={fmtBool (is_ascii_digit 97#i32)}"
  , s!"hv_0={fmtI32 (hex_val 48#i32)}"
  , s!"hv_A={fmtI32 (hex_val 65#i32)}"
  , s!"hv_f={fmtI32 (hex_val 102#i32)}"
  , s!"hv_g={fmtI32 (hex_val 103#i32)}"
  , s!"ns_0={fmtBool (is_number_start 48#i32)}"
  , s!"ns_neg={fmtBool (is_number_start 45#i32)}"
  , s!"ns_M={fmtBool (is_number_start 77#i32)}"
  , s!"pm_M={fmtBool (is_path_moveto 77#i32)}"
  , s!"pm_L={fmtBool (is_path_moveto 76#i32)}"
  , s!"pc_Z={fmtBool (is_path_closepath 90#i32)}"
  , s!"id_A={fmtBool (is_ident_char 65#i32)}"
  , s!"id_0={fmtBool (is_ident_char 48#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
