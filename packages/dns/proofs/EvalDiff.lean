import Dns.Types
import Dns.Funs

open Aeneas Aeneas.Std Result Pion dns

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"is_u32_0={fmtBool (is_u32 0#i64)}"
  , s!"is_u32_neg={fmtBool (is_u32 (-1)#i64)}"
  , s!"is_u32_max={fmtBool (is_u32 4294967295#i64)}"
  , s!"is_u32_over={fmtBool (is_u32 4294967296#i64)}"
  , s!"lower_A={fmtI32 (ascii_lower_byte 65#i32)}"
  , s!"lower_Z={fmtI32 (ascii_lower_byte 90#i32)}"
  , s!"lower_a={fmtI32 (ascii_lower_byte 97#i32)}"
  , s!"lower_neg={fmtI32 (ascii_lower_byte (-1)#i32)}"
  , s!"hex_0={fmtI32 (hex_val 48#i32)}"
  , s!"hex_F={fmtI32 (hex_val 70#i32)}"
  , s!"hex_f={fmtI32 (hex_val 102#i32)}"
  , s!"hex_bad={fmtI32 (hex_val 71#i32)}"
  , s!"hex_min={fmtI32 (hex_val (-2147483648)#i32)}"
  , s!"b64_A={fmtI32 (b64url_val 65#i32)}"
  , s!"b64_z={fmtI32 (b64url_val 122#i32)}"
  , s!"b64_0={fmtI32 (b64url_val 48#i32)}"
  , s!"b64_dash={fmtI32 (b64url_val 45#i32)}"
  , s!"b64_under={fmtI32 (b64url_val 95#i32)}"
  , s!"b64_plus_bad={fmtI32 (b64url_val 43#i32)}"
  , s!"hdr_hi_pack={fmtI32 (pack_header_flags_hi true 5#i32 true false true)}"
  , s!"hdr_hi_mask={fmtI32 (pack_header_flags_hi false (-1)#i32 false false false)}"
  , s!"hdr_hi_qr_t={fmtBool (unpack_header_qr 173#i32)}"
  , s!"hdr_hi_qr_f={fmtBool (unpack_header_qr 45#i32)}"
  , s!"edns_pack={fmtI64 (edns_pack_ttl 1#i32 2#i32 true)}"
  , s!"edns_ext_rt={fmtI32 (do let t ← edns_pack_ttl 255#i32 0#i32 true; edns_ttl_ext_rcode t)}"
  , s!"edns_badvers={fmtI32 (combine_extended_rcode 1#i32 0#i32)}"
  , s!"edns_badcookie={fmtI32 (combine_extended_rcode 1#i32 7#i32)}"
  , s!"edns_max={fmtI32 (combine_extended_rcode 255#i32 15#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
