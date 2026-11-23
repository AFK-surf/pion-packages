import Http2.Types
import Http2.Funs

open Aeneas Aeneas.Std Result Pion http2

def check (label : String) (b : Bool) : IO Unit :=
  IO.println s!"{label}: {if b then "PASS" else "FAIL"}"

def eqRes [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def main : IO Unit := do
  check "hpack_sz_0" (eqRes (hpack_entry_size 0#i32 0#i32) 32#i32)
  check "hpack_sz_ex" (eqRes (hpack_entry_size 10#i32 20#i32) 62#i32)
  check "st_eq_open" (eqRes (stream_state_eq .Open .Open) true)
  check "st_eq_diff" (eqRes (stream_state_eq .Open .Closed) false)
  check "parity_srv_1" (eqRes (is_remote_stream_parity true 1#i32) true)
  check "parity_srv_2" (eqRes (is_remote_stream_parity true 2#i32) false)
  check "parity_cli_2" (eqRes (is_remote_stream_parity false 2#i32) true)
  check "parity_cli_1" (eqRes (is_remote_stream_parity false 1#i32) false)
  check "flow_ok" (eqRes (flow_window_add_ok 65535#i64 1024#i64) true)
  check "flow_zero" (eqRes (flow_window_add_ok 65535#i64 0#i64) false)
  check "flow_ovf" (eqRes (flow_window_add_ok 2147483647#i64 1#i64) false)
  check "recv_data_open" (eqRes (can_recv_data_in_state .Open) 0#i32)
  check "recv_data_hcr" (eqRes (can_recv_data_in_state .HalfClosedRemote) 1#i32)
  check "recv_data_idle" (eqRes (can_recv_data_in_state .Idle) 2#i32)
  check "next_es_open" (eqRes (next_state_on_recv_end_stream .Open) .HalfClosedRemote)
  check "next_es_hcl" (eqRes (next_state_on_recv_end_stream .HalfClosedLocal) .Closed)

  check "u24_b0" (eqRes (pack_u24_b0 1193046#i32) 18#i32)
  check "u24_b1" (eqRes (pack_u24_b1 1193046#i32) 52#i32)
  check "u24_b2" (eqRes (pack_u24_b2 1193046#i32) 86#i32)
  check "u24_rt" (eqRes (unpack_u24_be 18#i32 52#i32 86#i32) 1193046#i32)
  check "u31_b0" (eqRes (pack_u31_b0 305419896#i32) 18#i32)
  check "u31_rt" (eqRes (unpack_u31_be 18#i32 52#i32 86#i32 120#i32) 305419896#i32)
  check "u31_rbit" (eqRes (unpack_u31_be 146#i32 52#i32 86#i32 120#i32) 305419896#i32)
  check "prio_pack_t" (eqRes (pack_priority_dep true 13#i32) 2147483661#i64)
  check "prio_pack_f" (eqRes (pack_priority_dep false 13#i32) 13#i64)
  check "prio_excl_t" (eqRes (unpack_priority_exclusive 2147483661#i64) true)
  check "prio_excl_f" (eqRes (unpack_priority_exclusive 13#i64) false)
  check "prio_dep_rt" (eqRes (unpack_priority_dep 2147483661#i64) 13#i32)
  check "hdr_flags_all" (eqRes (encode_headers_flags true true true) 37#i32)
  check "hdr_flags_none" (eqRes (encode_headers_flags false false false) 0#i32)
  check "win_inc_ok" (eqRes (is_valid_window_increment 1#i32) true)
  check "win_inc_0" (eqRes (is_valid_window_increment 0#i32) false)

  check "set_push_ok" (eqRes (validate_setting_value 2#i32 1#i64) 0#i32)
  check "set_push_bad" (eqRes (validate_setting_value 2#i32 2#i64) 1#i32)
  check "set_win_ok" (eqRes (validate_setting_value 4#i32 2147483647#i64) 0#i32)
  check "set_win_bad" (eqRes (validate_setting_value 4#i32 2147483648#i64) 2#i32)
  check "set_mfs_ok" (eqRes (validate_setting_value 5#i32 16384#i64) 0#i32)
  check "set_mfs_lo" (eqRes (validate_setting_value 5#i32 16383#i64) 1#i32)
  check "set_mfs_hi" (eqRes (validate_setting_value 5#i32 16777216#i64) 1#i32)
  check "set_conn_bad" (eqRes (validate_setting_value 8#i32 3#i64) 1#i32)
  check "set_unk_ok" (eqRes (validate_setting_value 99#i32 9999999999#i64) 0#i32)
  check "name_lower" (eqRes (is_valid_h2_name_byte 97#i32) true)
  check "name_upper" (eqRes (is_valid_h2_name_byte 65#i32) false)
  check "name_space" (eqRes (is_valid_h2_name_byte 32#i32) false)
  check "val_ctl_0" (eqRes (is_h2_value_ctl 0#i32) true)
  check "val_ctl_tab" (eqRes (is_h2_value_ctl 9#i32) false)
  check "val_ctl_del" (eqRes (is_h2_value_ctl 127#i32) true)
  check "val_ws_sp" (eqRes (is_h2_value_edge_ws 32#i32) true)
  check "digit_5" (eqRes (is_ascii_digit 53#i32) true)
  check "digit_a" (eqRes (is_ascii_digit 97#i32) false)
