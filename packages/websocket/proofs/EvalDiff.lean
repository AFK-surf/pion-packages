import Websocket.Types
import Websocket.Funs

open Aeneas Aeneas.Std Result Pion websocket

namespace WebsocketEvalDiff

def fmtI32 (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => toString v.val
  | _ => "TRAP"

def fmtOptOp (r : Result (Option Opcode)) : String :=
  match r.match with
  | .ok (some .Continuation) => "Some(0)"
  | .ok (some .Text) => "Some(1)"
  | .ok (some .Binary) => "Some(2)"
  | .ok (some .Close) => "Some(8)"
  | .ok (some .Ping) => "Some(9)"
  | .ok (some .Pong) => "Some(10)"
  | .ok none => "None"
  | _ => "TRAP"

#eval show IO Unit from do
  IO.println s!"xor_ab={fmtI32 (mask_byte_xor 0xAB#i32 0x55#i32)}"
  IO.println s!"xor_min={fmtI32 (mask_byte_xor (-2147483648)#i32 2147483647#i32)}"
  IO.println s!"mkey_0={fmtI32 (mask_key_byte 0x37FA213D#u32 0#i32)}"
  IO.println s!"mkey_3={fmtI32 (mask_key_byte 0x37FA213D#u32 3#i32)}"
  IO.println s!"mkey_neg1={fmtI32 (mask_key_byte 0x37FA213D#u32 (-1)#i32)}"
  IO.println s!"mkey_min={fmtI32 (mask_key_byte 0xFFFFFFFF#u32 (-2147483648)#i32)}"
  IO.println s!"hlen_0_f={fmtI32 (encoded_header_len 0#i32 false)}"
  IO.println s!"hlen_125_t={fmtI32 (encoded_header_len 125#i32 true)}"
  IO.println s!"hlen_126_f={fmtI32 (encoded_header_len 126#i32 false)}"
  IO.println s!"hlen_65536_t={fmtI32 (encoded_header_len 65536#i32 true)}"
  IO.println s!"hlen_min_f={fmtI32 (encoded_header_len (-2147483648)#i32 false)}"
  IO.println s!"hlen_max_t={fmtI32 (encoded_header_len 2147483647#i32 true)}"
  IO.println s!"ext64_msb={fmtI32 (check_ext_len64 0x80#i32 65536#i64 1048576#i32)}"
  IO.println s!"ext64_nonmin={fmtI32 (check_ext_len64 0#i32 65535#i64 1048576#i32)}"
  IO.println s!"ext64_big={fmtI32 (check_ext_len64 0#i32 2000000#i64 1048576#i32)}"
  IO.println s!"ext64_ok={fmtI32 (check_ext_len64 0#i32 65536#i64 1048576#i32)}"
  IO.println s!"ext64_i64max={fmtI32 (check_ext_len64 0#i32 9223372036854775807#i64 2147483647#i32)}"
  IO.println s!"op_1={fmtOptOp (opcode_from_int 1#i32)}"
  IO.println s!"op_8={fmtOptOp (opcode_from_int 8#i32)}"
  IO.println s!"op_3={fmtOptOp (opcode_from_int 3#i32)}"
  IO.println s!"op_min={fmtOptOp (opcode_from_int (-2147483648)#i32)}"
  IO.println s!"op_max={fmtOptOp (opcode_from_int 2147483647#i32)}"
  IO.println s!"utf8_ascii={fmtI32 (utf8_dfa_step 0#i32 65#i32)}"
  IO.println s!"utf8_e0={fmtI32 (utf8_dfa_step 0#i32 224#i32)}"
  IO.println s!"utf8_e0_ovl={fmtI32 (utf8_dfa_step 3#i32 159#i32)}"
  IO.println s!"utf8_2b_lead={fmtI32 (utf8_dfa_step 0#i32 194#i32)}"
  IO.println s!"utf8_2b_cont={fmtI32 (utf8_dfa_step 1#i32 128#i32)}"
  IO.println s!"utf8_sticky={fmtI32 (utf8_dfa_step (-1)#i32 65#i32)}"
  IO.println s!"utf8_min={fmtI32 (utf8_dfa_step (-2147483648)#i32 (-1)#i32)}"

end WebsocketEvalDiff
