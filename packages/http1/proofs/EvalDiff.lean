import Http1.Types
import Http1.Funs

open Aeneas Aeneas.Std Result Pion http1

namespace Http1EvalDiff

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def framingEq (a b : Framing) : Bool :=
  match a, b with
  | .None, .None => true
  | .ContentLength x, .ContentLength y => x == y
  | .Chunked, .Chunked => true
  | _, _ => false

instance : BEq Framing := ⟨framingEq⟩

def resEq {α ε : Type} [BEq α] [BEq ε] (a b : Pion.Res α ε) : Bool :=
  match a, b with
  | .Ok x, .Ok y => x == y
  | .Err x, .Err y => x == y
  | _, _ => false

instance {α ε : Type} [BEq α] [BEq ε] : BEq (Pion.Res α ε) := ⟨resEq⟩

def stateEq (a b : FramingState) : Bool :=
  a.has_cl == b.has_cl &&
  a.cl_val == b.cl_val &&
  a.has_te == b.has_te &&
  a.te_state == b.te_state &&
  a.host_count == b.host_count

instance : BEq FramingState := ⟨stateEq⟩

def report (label : String) (passed : Bool) : IO Unit :=
  IO.println s!"{label}: {if passed then "PASS" else "FAIL"}"

#eval show IO Unit from do
  report "tchar_A" (okIs (is_tchar_byte 65#i32) true)
  report "tchar_sp_false" (okIs (is_tchar_byte 32#i32) false)
  report "tchar_cr_false" (okIs (is_tchar_byte 13#i32) false)
  report "uri_slash" (okIs (is_uri_byte 47#i32) true)
  report "uri_sp_false" (okIs (is_uri_byte 32#i32) false)
  report "hdrval_htab" (okIs (is_header_val_byte 9#i32) true)
  report "hdrval_obstext" (okIs (is_header_val_byte 200#i32) true)
  report "hdrval_cr_false" (okIs (is_header_val_byte 13#i32) false)
  report "hdrval_nul_false" (okIs (is_header_val_byte 0#i32) false)
  report "hex_0" (okIs (hex_digit_value 48#i32) 0#i32)
  report "hex_F" (okIs (hex_digit_value 70#i32) 15#i32)
  report "hex_f" (okIs (hex_digit_value 102#i32) 15#i32)
  report "hex_g_neg1" (okIs (hex_digit_value 103#i32) (-1)#i32)
  report "lower_Z" (okIs (ascii_lower_byte 90#i32) 122#i32)
  report "lower_a" (okIs (ascii_lower_byte 97#i32) 97#i32)
  report "bodyless_101" (okIs (is_bodyless_status 101#i32) true)
  report "bodyless_204" (okIs (is_bodyless_status 204#i32) true)
  report "bodyless_304" (okIs (is_bodyless_status 304#i32) true)
  report "bodyless_200_false" (okIs (is_bodyless_status 200#i32) false)
  report "eff_framing_204" (okIs (effective_response_framing 204#i32 (Framing.ContentLength 99#i64)) Framing.None)
  report "eff_framing_200" (okIs (effective_response_framing 200#i32 (Framing.ContentLength 99#i64)) (Framing.ContentLength 99#i64))
  report "te_after_chunked_neg1" (okIs (te_coding_step 1#i32 true false) (-1)#i32)
  report "te_gzip_then_chunked" (okIs (te_coding_step 0#i32 true false) 1#i32)
  report "minor_0" (okIs (parse_http_minor 48#i32) (Pion.Res.Ok Version.Http10))
  report "minor_1" (okIs (parse_http_minor 49#i32) (Pion.Res.Ok Version.Http11))
  report "minor_x" (okIs (parse_http_minor 120#i32) (Pion.Res.Err HttpError.InvalidVersion))
  report "status_200" (okIs (parse_status_digits 50#i32 48#i32 48#i32) (Pion.Res.Ok 200#i32))
  report "status_bad" (okIs (parse_status_digits 50#i32 65#i32 48#i32) (Pion.Res.Err HttpError.InvalidStatus))
  report "u63_step_ok" (okIs (u63_decimal_step 123#i64 52#i32) (some 1234#i64))
  report "u63_step_max_ok" (okIs (u63_decimal_step 922337203685477580#i64 55#i32) (some 9223372036854775807#i64))
  report "u63_step_max_ovf" (okIs (u63_decimal_step 922337203685477580#i64 56#i32) none)
  report "chunk_hex_ok" (okIs (chunk_size_hex_step 16#i64 2#i32 10#i32) (Pion.Res.Ok 266#i64))
  report "chunk_hex_16dig_err" (okIs (chunk_size_hex_step 0#i64 16#i32 1#i32) (Pion.Res.Err HttpError.InvalidChunkSize))
  report "chunk_hex_ovf" (okIs (chunk_size_hex_step 576460752303423488#i64 15#i32 0#i32) (Pion.Res.Err HttpError.ChunkTooLarge))
  let st0 := FramingState.mk false 0#i64 false 0#i32 0#i32
  let st_cl := FramingState.mk true 10#i64 false 0#i32 1#i32
  let st_te := FramingState.mk false 0#i64 true 1#i32 1#i32
  report "smuggle_cl_after_te" (okIs (framing_on_content_length st_te 5#i64) (Pion.Res.Err HttpError.AmbiguousFraming))
  report "smuggle_te_after_cl" (okIs (framing_on_transfer_encoding st_cl .Http11 1#i32) (Pion.Res.Err HttpError.AmbiguousFraming))
  report "smuggle_http10_te" (okIs (framing_on_transfer_encoding st0 .Http10 1#i32) (Pion.Res.Err HttpError.InvalidTransferEncoding))
  report "smuggle_dup_host" (okIs (framing_on_host st_cl true) (Pion.Res.Err HttpError.InvalidHost))
  report "finalize_missing_host" (okIs (framing_finalize st0 true .Http11) (Pion.Res.Err HttpError.InvalidHost))
  report "finalize_chunked_ok" (okIs (framing_finalize st_te true .Http11) (Pion.Res.Ok Framing.Chunked))
  report "finalize_cl_ok" (okIs (framing_finalize st_cl true .Http11) (Pion.Res.Ok (Framing.ContentLength 10#i64)))

end Http1EvalDiff
