import Websocket.Types
import Websocket.Funs

open Aeneas Aeneas.Std Result Pion websocket

namespace WebsocketEvalDiff

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def report (label : String) (passed : Bool) : IO Unit :=
  IO.println s!"{label}: {if passed then "PASS" else "FAIL"}"

#eval show IO Unit from do
  report "xor_involution" (okIs (do let x ← mask_byte_xor 0xAB#i32 0x5C#i32; mask_byte_xor x 0x5C#i32) 0xAB#i32)
  report "xor_zero_id" (okIs (mask_byte_xor 0x7F#i32 0#i32) 0x7F#i32)
  report "mask_key_b0" (okIs (mask_key_byte 0x12345678#u32 0#i32) 0x12#i32)
  report "mask_key_b3" (okIs (mask_key_byte 0x12345678#u32 3#i32) 0x78#i32)
  report "mask_key_periodic" (okIs (mask_key_byte 0x12345678#u32 7#i32) 0x78#i32)
  report "ext_len_125" (okIs (encoded_ext_len 125#i32) 0#i32)
  report "ext_len_126" (okIs (encoded_ext_len 126#i32) 2#i32)
  report "ext_len_65535" (okIs (encoded_ext_len 65535#i32) 2#i32)
  report "ext_len_65536" (okIs (encoded_ext_len 65536#i32) 8#i32)
  report "hdr_len_small_unmasked" (okIs (encoded_header_len 10#i32 false) 2#i32)
  report "hdr_len_large_masked" (okIs (encoded_header_len 70000#i32 true) 14#i32)
  report "opcode_text" (okIs (opcode_from_int 1#i32) (some Opcode.Text))
  report "opcode_pong" (okIs (opcode_from_int 10#i32) (some Opcode.Pong))
  report "opcode_reserved_3" (okIs (opcode_from_int 3#i32) none)
  report "opcode_reserved_15" (okIs (opcode_from_int 15#i32) none)
  report "ctrl_close" (okIs (is_control_opcode Opcode.Close) true)
  report "ctrl_text_false" (okIs (is_control_opcode Opcode.Text) false)
  report "role_srv_unmasked" (okIs (check_role_mask Role.Server false) 1#i32)
  report "role_cli_masked" (okIs (check_role_mask Role.Client true) 2#i32)
  report "ctrl_frag_err" (okIs (check_control_frame true false 5#i32) 1#i32)
  report "ctrl_126_err" (okIs (check_control_frame true true 126#i32) 2#i32)
  report "ctrl_125_ok" (okIs (check_control_frame true true 125#i32) 0#i32)
  report "min_len16_125_false" (okIs (is_minimal_len16 125#i32) false)
  report "min_len16_126_true" (okIs (is_minimal_len16 126#i32) true)
  report "len64_msb_err" (okIs (check_ext_len64 0x80#i32 70000#i64 100000#i32) 1#i32)
  report "len64_nonmin_err" (okIs (check_ext_len64 0#i32 65535#i64 100000#i32) 2#i32)
  report "len64_toolarge_err" (okIs (check_ext_len64 0#i32 200000#i64 100000#i32) 3#i32)
  report "len64_ok" (okIs (check_ext_len64 0#i32 70000#i64 100000#i32) 0#i32)
  report "clamp_over_i32" (okIs (clamp_i64_to_i32_max 3000000000#i64) 2147483647#i32)
  report "frame_total_no_ovf" (okIs (frame_total_bytes 10#i32 true 2147483647#i32) 2147483661#i64)
  report "frag_sum_no_ovf" (okIs (frag_sum_i64 2000000000#i32 2000000000#i32) 4000000000#i64)
  report "close_1000_ok" (okIs (is_valid_close_code 1000#i32) true)
  report "close_1005_false" (okIs (is_valid_close_code 1005#i32) false)
  report "close_1006_false" (okIs (is_valid_close_code 1006#i32) false)
  report "close_1015_false" (okIs (is_valid_close_code 1015#i32) false)
  report "close_4999_ok" (okIs (is_valid_close_code 4999#i32) true)
  report "close_5000_false" (okIs (is_valid_close_code 5000#i32) false)
  report "utf8_ascii_0" (okIs (utf8_dfa_step 0#i32 65#i32) 0#i32)
  report "utf8_overlong_c0" (okIs (utf8_dfa_step 0#i32 0xC0#i32) (-1)#i32)
  report "utf8_surrogate_ed_a0" (okIs (do let s ← utf8_dfa_step 0#i32 0xED#i32; utf8_dfa_step s 0xA0#i32) (-1)#i32)
  report "utf8_above_10ffff" (okIs (do let s ← utf8_dfa_step 0#i32 0xF4#i32; utf8_dfa_step s 0x90#i32) (-1)#i32)
  report "utf8_2byte_ok" (okIs (do let s ← utf8_dfa_step 0#i32 0xC3#i32; utf8_dfa_step s 0xA9#i32) 0#i32)

end WebsocketEvalDiff
