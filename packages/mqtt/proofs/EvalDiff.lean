import Aeneas
import PionLean
import Mqtt.Types
import Mqtt.Funs

open Aeneas Aeneas.Std Result Pion mqtt

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtOptQos (r : Result (Option QoS)) : String :=
  match r.match with
  | .ok none => "None"
  | .ok (some .AtMostOnce) => "Some(0)"
  | .ok (some .AtLeastOnce) => "Some(1)"
  | .ok (some .ExactlyOnce) => "Some(2)"
  | _ => "TRAP"

private def fmtOptPt (r : Result (Option PacketType)) : String :=
  match r.match with
  | .ok none => "None"
  | .ok (some .Connect) => "Some(Connect)"
  | .ok (some .Publish) => "Some(Publish)"
  | .ok (some .Auth) => "Some(Auth)"
  | .ok (some _) => "Some(Other)"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"qos_0={fmtI32 (qos_to_int .AtMostOnce)}"
  , s!"qos_2={fmtI32 (qos_to_int .ExactlyOnce)}"
  , s!"qosf_1={fmtOptQos (qos_from_int_opt 1#i32)}"
  , s!"qosf_3={fmtOptQos (qos_from_int_opt 3#i32)}"
  , s!"ptf_0={fmtOptPt (packet_type_from_int_opt 0#i32)}"
  , s!"ptf_3={fmtOptPt (packet_type_from_int_opt 3#i32)}"
  , s!"ptf_15={fmtOptPt (packet_type_from_int_opt 15#i32)}"
  , s!"ptf_16={fmtOptPt (packet_type_from_int_opt 16#i32)}"
  , s!"vlen_neg={fmtI32 (vbi_encoded_len (-1)#i32)}"
  , s!"vlen_0={fmtI32 (vbi_encoded_len 0#i32)}"
  , s!"vlen_127={fmtI32 (vbi_encoded_len 127#i32)}"
  , s!"vlen_128={fmtI32 (vbi_encoded_len 128#i32)}"
  , s!"vlen_16383={fmtI32 (vbi_encoded_len 16383#i32)}"
  , s!"vlen_16384={fmtI32 (vbi_encoded_len 16384#i32)}"
  , s!"vlen_2097151={fmtI32 (vbi_encoded_len 2097151#i32)}"
  , s!"vlen_2097152={fmtI32 (vbi_encoded_len 2097152#i32)}"
  , s!"vlen_max={fmtI32 (vbi_encoded_len 268435455#i32)}"
  , s!"vlen_over={fmtI32 (vbi_encoded_len 268435456#i32)}"
  , s!"vdec2_min={fmtI32 (vbi_decode_2 128#i32 1#i32)}"
  , s!"vdec2_max={fmtI32 (vbi_decode_2 255#i32 127#i32)}"
  , s!"vdec3_min={fmtI32 (vbi_decode_3 128#i32 128#i32 1#i32)}"
  , s!"vdec4_max={fmtI32 (vbi_decode_4 255#i32 255#i32 255#i32 127#i32)}"
  , s!"fh_pt0={fmtI32 (fixed_header_flags_err_code 0#i32 0#i32)}"
  , s!"fh_pub_ok={fmtI32 (fixed_header_flags_err_code 3#i32 2#i32)}"
  , s!"fh_pub_qos3={fmtI32 (fixed_header_flags_err_code 3#i32 6#i32)}"
  , s!"fh_pub_dup0={fmtI32 (fixed_header_flags_err_code 3#i32 8#i32)}"
  , s!"fh_sub_ok={fmtI32 (fixed_header_flags_err_code 8#i32 2#i32)}"
  , s!"fh_sub_bad={fmtI32 (fixed_header_flags_err_code 8#i32 0#i32)}"
  , s!"cont_80={fmtBool (is_utf8_cont_byte 128#i32)}"
  , s!"cont_bf={fmtBool (is_utf8_cont_byte 191#i32)}"
  , s!"cont_c0={fmtBool (is_utf8_cont_byte 192#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
