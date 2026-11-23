import Aeneas
import PionLean
import Svg.Types
import Svg.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion svg

def checkBool (lbl : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def checkI32 (lbl : String) (r : Result Std.I32) (expected : Std.I32) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def runAll : List String := [
  -- SvgLimits & SvgColor (4)
  checkI32 "lim_depth" (do let l ← SvgLimits.default; ok l.max_depth) 128#i32,
  checkI32 "lim_bytes" (do let l ← SvgLimits.default; ok l.max_input_bytes) 16777216#i32,
  checkI32 "rgb_a" (do let c ← SvgColor.rgb 10#i32 20#i32 30#i32; ok c.a) 255#i32,
  checkI32 "rgba_g" (do let c ← SvgColor.rgba 10#i32 20#i32 30#i32 128#i32; ok c.g) 20#i32,
  -- clamp_u8_int (4)
  checkI32 "cl_neg" (clamp_u8_int (-5)#i32) 0#i32,
  checkI32 "cl_0" (clamp_u8_int 0#i32) 0#i32,
  checkI32 "cl_128" (clamp_u8_int 128#i32) 128#i32,
  checkI32 "cl_hi" (clamp_u8_int 300#i32) 255#i32,
  -- is_valid_hex_color_len (5)
  checkBool "hl_3" (is_valid_hex_color_len 3#i32) true,
  checkBool "hl_4" (is_valid_hex_color_len 4#i32) true,
  checkBool "hl_6" (is_valid_hex_color_len 6#i32) true,
  checkBool "hl_8" (is_valid_hex_color_len 8#i32) true,
  checkBool "hl_5" (is_valid_hex_color_len 5#i32) false,
  -- hex_nibble_code / hex3_channel_expand / hex_pair_to_byte (7)
  checkI32 "hn_0" (hex_nibble_code 0#i32) 48#i32,
  checkI32 "hn_9" (hex_nibble_code 9#i32) 57#i32,
  checkI32 "hn_10" (hex_nibble_code 10#i32) 97#i32,
  checkI32 "hn_15" (hex_nibble_code 15#i32) 102#i32,
  checkI32 "h3_f" (hex3_channel_expand 15#i32) 255#i32,
  checkI32 "hp_ab" (hex_pair_to_byte 10#i32 11#i32) 171#i32,
  checkI32 "hp_ff" (hex_pair_to_byte 15#i32 15#i32) 255#i32,
  -- is_svg_ws / is_xml_ws (6)
  checkBool "sws_sp" (is_svg_ws 32#i32) true,
  checkBool "sws_ff" (is_svg_ws 12#i32) true,
  checkBool "sws_a" (is_svg_ws 97#i32) false,
  checkBool "xws_sp" (is_xml_ws 32#i32) true,
  checkBool "xws_ff" (is_xml_ws 12#i32) false,
  checkBool "xws_cr" (is_xml_ws 13#i32) true,
  -- is_ascii_digit / hex_val (7)
  checkBool "dig_0" (is_ascii_digit 48#i32) true,
  checkBool "dig_a" (is_ascii_digit 97#i32) false,
  checkI32 "hv_0" (hex_val 48#i32) 0#i32,
  checkI32 "hv_A" (hex_val 65#i32) 10#i32,
  checkI32 "hv_f" (hex_val 102#i32) 15#i32,
  checkI32 "hv_g" (hex_val 103#i32) (-1)#i32,
  checkI32 "hv_sp" (hex_val 32#i32) (-1)#i32,
  -- is_number_start / is_path_moveto / is_path_closepath / is_ident_char (11)
  checkBool "ns_0" (is_number_start 48#i32) true,
  checkBool "ns_neg" (is_number_start 45#i32) true,
  checkBool "ns_dot" (is_number_start 46#i32) true,
  checkBool "ns_M" (is_number_start 77#i32) false,
  checkBool "pm_M" (is_path_moveto 77#i32) true,
  checkBool "pm_m" (is_path_moveto 109#i32) true,
  checkBool "pm_L" (is_path_moveto 76#i32) false,
  checkBool "pc_Z" (is_path_closepath 90#i32) true,
  checkBool "pc_z" (is_path_closepath 122#i32) true,
  checkBool "id_A" (is_ident_char 65#i32) true,
  checkBool "id_0" (is_ident_char 48#i32) false
]

#eval IO.println (String.intercalate "\n" runAll)
