import Http2.Types
import Http2.Funs

open Aeneas Aeneas.Std Result Pion http2

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtState (r : Result StreamState) : String :=
  match r.match with
  | .ok .Idle => "Idle"
  | .ok .ReservedLocal => "ReservedLocal"
  | .ok .ReservedRemote => "ReservedRemote"
  | .ok .Open => "Open"
  | .ok .HalfClosedLocal => "HalfClosedLocal"
  | .ok .HalfClosedRemote => "HalfClosedRemote"
  | .ok .Closed => "Closed"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"parity_srv_1={fmtBool (is_remote_stream_parity true 1#i32)}"
  , s!"parity_srv_2={fmtBool (is_remote_stream_parity true 2#i32)}"
  , s!"parity_cli_2={fmtBool (is_remote_stream_parity false 2#i32)}"
  , s!"parity_cli_1={fmtBool (is_remote_stream_parity false 1#i32)}"
  , s!"parity_zero={fmtBool (is_remote_stream_parity true 0#i32)}"
  , s!"flow_ok={fmtBool (flow_window_add_ok 65535#i64 1024#i64)}"
  , s!"flow_zero={fmtBool (flow_window_add_ok 65535#i64 0#i64)}"
  , s!"flow_ovf={fmtBool (flow_window_add_ok 2147483647#i64 1#i64)}"
  , s!"flow_neg={fmtBool (flow_window_add_ok (-100)#i64 100#i64)}"
  , s!"next_es_open={fmtState (next_state_on_recv_end_stream .Open)}"
  , s!"next_es_hcl={fmtState (next_state_on_recv_end_stream .HalfClosedLocal)}"
  , s!"next_es_closed={fmtState (next_state_on_recv_end_stream .Closed)}"
  , s!"u24_b0={fmtI32 (pack_u24_b0 1193046#i32)}"
  , s!"u24_b1={fmtI32 (pack_u24_b1 1193046#i32)}"
  , s!"u24_b2={fmtI32 (pack_u24_b2 1193046#i32)}"
  , s!"u24_rt={fmtI32 (unpack_u24_be 18#i32 52#i32 86#i32)}"
  , s!"u31_b0={fmtI32 (pack_u31_b0 305419896#i32)}"
  , s!"u31_rt={fmtI32 (unpack_u31_be 18#i32 52#i32 86#i32 120#i32)}"
  , s!"u31_rbit={fmtI32 (unpack_u31_be 146#i32 52#i32 86#i32 120#i32)}"
  , s!"prio_pack_t={fmtI64 (pack_priority_dep true 13#i32)}"
  , s!"prio_pack_f={fmtI64 (pack_priority_dep false 13#i32)}"
  , s!"prio_excl_t={fmtBool (unpack_priority_exclusive 2147483661#i64)}"
  , s!"prio_excl_f={fmtBool (unpack_priority_exclusive 13#i64)}"
  , s!"prio_dep_rt={fmtI32 (unpack_priority_dep 2147483661#i64)}"
  , s!"name_lower={fmtBool (is_valid_h2_name_byte 97#i32)}"
  , s!"name_upper={fmtBool (is_valid_h2_name_byte 65#i32)}"
  , s!"name_space={fmtBool (is_valid_h2_name_byte 32#i32)}"
  , s!"val_ctl_0={fmtBool (is_h2_value_ctl 0#i32)}"
  , s!"val_ctl_tab={fmtBool (is_h2_value_ctl 9#i32)}"
  , s!"val_ctl_del={fmtBool (is_h2_value_ctl 127#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
