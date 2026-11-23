import Aeneas
import PionLean
import Mqtt.Types
import Mqtt.Funs

open Aeneas Aeneas.Std Result Pion mqtt

private def checkBool (label : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkI32 (label : String) (r : Result I32) (expected : I32) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkOptQos (label : String) (r : Result (Option QoS)) (expected : Option QoS) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkOptPt (label : String) (r : Result (Option PacketType)) (expected : Option PacketType) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def runAll : List String := [
  checkI32 "qos_0" (qos_to_int .AtMostOnce) 0#i32,
  checkI32 "qos_2" (qos_to_int .ExactlyOnce) 2#i32,
  checkOptQos "qosf_1" (qos_from_int_opt 1#i32) (some .AtLeastOnce),
  checkOptQos "qosf_3" (qos_from_int_opt 3#i32) none,
  checkI32 "pt_conn" (packet_type_to_int .Connect) 1#i32,
  checkI32 "pt_auth" (packet_type_to_int .Auth) 15#i32,
  checkOptPt "ptf_0" (packet_type_from_int_opt 0#i32) none,
  checkOptPt "ptf_3" (packet_type_from_int_opt 3#i32) (some .Publish),
  checkOptPt "ptf_15" (packet_type_from_int_opt 15#i32) (some .Auth),
  checkOptPt "ptf_16" (packet_type_from_int_opt 16#i32) none,
  checkI32 "vlen_neg" (vbi_encoded_len (-1)#i32) 0#i32,
  checkI32 "vlen_0" (vbi_encoded_len 0#i32) 1#i32,
  checkI32 "vlen_127" (vbi_encoded_len 127#i32) 1#i32,
  checkI32 "vlen_128" (vbi_encoded_len 128#i32) 2#i32,
  checkI32 "vlen_16383" (vbi_encoded_len 16383#i32) 2#i32,
  checkI32 "vlen_16384" (vbi_encoded_len 16384#i32) 3#i32,
  checkI32 "vlen_2097151" (vbi_encoded_len 2097151#i32) 3#i32,
  checkI32 "vlen_2097152" (vbi_encoded_len 2097152#i32) 4#i32,
  checkI32 "vlen_max" (vbi_encoded_len 268435455#i32) 4#i32,
  checkI32 "vlen_over" (vbi_encoded_len 268435456#i32) 0#i32,
  checkI32 "vdec2_min" (vbi_decode_2 128#i32 1#i32) 128#i32,
  checkI32 "vdec2_max" (vbi_decode_2 255#i32 127#i32) 16383#i32,
  checkI32 "vdec3_min" (vbi_decode_3 128#i32 128#i32 1#i32) 16384#i32,
  checkI32 "vdec4_max" (vbi_decode_4 255#i32 255#i32 255#i32 127#i32) 268435455#i32,
  checkI32 "fh_pt0" (fixed_header_flags_err_code 0#i32 0#i32) 1#i32,
  checkI32 "fh_pub_ok" (fixed_header_flags_err_code 3#i32 2#i32) 0#i32,
  checkI32 "fh_pub_qos3" (fixed_header_flags_err_code 3#i32 6#i32) 2#i32,
  checkI32 "fh_pub_dup0" (fixed_header_flags_err_code 3#i32 8#i32) 3#i32,
  checkI32 "fh_sub_ok" (fixed_header_flags_err_code 8#i32 2#i32) 0#i32,
  checkI32 "fh_sub_bad" (fixed_header_flags_err_code 8#i32 0#i32) 3#i32,
  checkI32 "fh_conn_ok" (fixed_header_flags_err_code 1#i32 0#i32) 0#i32,
  checkI32 "fh_conn_bad" (fixed_header_flags_err_code 1#i32 2#i32) 3#i32,
  checkBool "asc_nul" (is_mqtt_forbidden_ascii 0#i32) true,
  checkBool "asc_del" (is_mqtt_forbidden_ascii 127#i32) true,
  checkBool "asc_sp" (is_mqtt_forbidden_ascii 32#i32) false,
  checkBool "cont_80" (is_utf8_cont_byte 128#i32) true,
  checkBool "cont_bf" (is_utf8_cont_byte 191#i32) true,
  checkBool "cont_c0" (is_utf8_cont_byte 192#i32) false,
  checkBool "c1_80" (is_mqtt_c1_control_2b 194#i32 128#i32) true,
  checkBool "c1_a0" (is_mqtt_c1_control_2b 194#i32 160#i32) false
]

#eval IO.println (String.intercalate "\n" runAll)
