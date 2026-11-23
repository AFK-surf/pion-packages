import Http1.Types
import Http1.Funs

open Aeneas Aeneas.Std Result Pion http1

namespace Http1EvalDiff

def fmtI32 (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => toString v.val
  | _ => "TRAP"

def fmtI64 (r : Result Std.I64) : String :=
  match r.match with
  | .ok v => toString v.val
  | _ => "TRAP"

def fmtBool (r : Result Bool) : String :=
  match r.match with
  | .ok true => "true"
  | .ok false => "false"
  | _ => "TRAP"

def fmtFraming (r : Result Framing) : String :=
  match r.match with
  | .ok .None => "None"
  | .ok (.ContentLength n) => s!"CL({n.val})"
  | .ok .Chunked => "Chunked"
  | _ => "TRAP"

#eval show IO Unit from do
  IO.println s!"tchar_A={fmtBool (is_tchar_byte 65#i32)}"
  IO.println s!"tchar_sp={fmtBool (is_tchar_byte 32#i32)}"
  IO.println s!"tchar_cr={fmtBool (is_tchar_byte 13#i32)}"
  IO.println s!"tchar_min={fmtBool (is_tchar_byte (-2147483648)#i32)}"
  IO.println s!"tchar_max={fmtBool (is_tchar_byte 2147483647#i32)}"
  IO.println s!"hdrval_htab={fmtBool (is_header_val_byte 9#i32)}"
  IO.println s!"hdrval_obstext={fmtBool (is_header_val_byte 200#i32)}"
  IO.println s!"hdrval_cr={fmtBool (is_header_val_byte 13#i32)}"
  IO.println s!"hdrval_nul={fmtBool (is_header_val_byte 0#i32)}"
  IO.println s!"hdrval_neg1={fmtBool (is_header_val_byte (-1)#i32)}"
  IO.println s!"hex_0={fmtI32 (hex_digit_value 48#i32)}"
  IO.println s!"hex_F={fmtI32 (hex_digit_value 70#i32)}"
  IO.println s!"hex_f={fmtI32 (hex_digit_value 102#i32)}"
  IO.println s!"hex_min={fmtI32 (hex_digit_value (-2147483648)#i32)}"
  IO.println s!"hex_max={fmtI32 (hex_digit_value 2147483647#i32)}"
  IO.println s!"lower_Z={fmtI32 (ascii_lower_byte 90#i32)}"
  IO.println s!"lower_min={fmtI32 (ascii_lower_byte (-2147483648)#i32)}"
  IO.println s!"eff_204={fmtFraming (effective_response_framing 204#i32 (Framing.ContentLength 99#i64))}"
  IO.println s!"eff_200={fmtFraming (effective_response_framing 200#i32 (Framing.ContentLength 99#i64))}"
  IO.println s!"eff_min={fmtFraming (effective_response_framing (-2147483648)#i32 Framing.Chunked)}"
  IO.println s!"te_after_ch={fmtI32 (te_coding_step 1#i32 true false)}"
  IO.println s!"te_gz_ch={fmtI32 (te_coding_step 0#i32 true false)}"
  IO.println s!"status_200={fmtI32 (parse_status_digits 50#i32 48#i32 48#i32)}"
  IO.println s!"status_bad={fmtI32 (parse_status_digits 50#i32 65#i32 48#i32)}"
  IO.println s!"status_min={fmtI32 (parse_status_digits (-2147483648)#i32 48#i32 48#i32)}"
  IO.println s!"u63_ok={fmtI64 (u63_decimal_step 123#i64 52#i32)}"
  IO.println s!"u63_max_ok={fmtI64 (u63_decimal_step 922337203685477580#i64 55#i32)}"
  IO.println s!"u63_max_ovf={fmtI64 (u63_decimal_step 922337203685477580#i64 56#i32)}"
  IO.println s!"u63_min_acc={fmtI64 (u63_decimal_step (-9223372036854775808)#i64 48#i32)}"
  IO.println s!"chunk_ok={fmtI64 (chunk_size_hex_step 16#i64 2#i32 10#i32)}"
  IO.println s!"chunk_16dig={fmtI64 (chunk_size_hex_step 0#i64 16#i32 1#i32)}"
  IO.println s!"chunk_ovf={fmtI64 (chunk_size_hex_step 576460752303423488#i64 15#i32 0#i32)}"
  IO.println s!"chunk_max={fmtI64 (chunk_size_hex_step 9223372036854775807#i64 1#i32 1#i32)}"
  IO.println s!"cl_after_te={fmtI32 (check_framing_cl true false 5#i64)}"
  IO.println s!"cl_neg_min={fmtI32 (check_framing_cl false false (-9223372036854775808)#i64)}"
  IO.println s!"te_after_cl={fmtI32 (check_framing_te true .Http11 1#i32)}"
  IO.println s!"te_http10={fmtI32 (check_framing_te false .Http10 1#i32)}"
  IO.println s!"host_dup={fmtI32 (check_framing_host 1#i32 true)}"
  IO.println s!"fin_no_host={fmtI32 (check_framing_finalize false false 0#i32 0#i32 true .Http11)}"
  IO.println s!"fin_chunked={fmtI32 (check_framing_finalize false true 1#i32 1#i32 true .Http11)}"
  IO.println s!"fin_cl={fmtI32 (check_framing_finalize true false 0#i32 1#i32 true .Http11)}"

end Http1EvalDiff
