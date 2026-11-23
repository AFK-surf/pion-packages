import Dns.Types
import Dns.Funs

open Aeneas Aeneas.Std Result Pion dns

private def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

private def report (label : String) (ok_cond : Bool) : IO Unit :=
  IO.println s!"{label}: {if ok_cond then "PASS" else "FAIL"}"

def main : IO Unit := do
  report "lim_def_ptrs" (okIs (do let d ← DecodeLimits.default; ok d.max_pointers) 128#i32)
  report "lim_strict_trail" (okIs (do let s ← DecodeLimits.strict; ok s.allow_trailing_bytes) false)
  report "enc_opt_def" (okIs (do let o ← EncodeOptions.default; ok o.compress) true)
  report "enc_opt_uncomp" (okIs (do let o ← EncodeOptions.uncompressed; ok o.compress) false)
  report "ipv4_eq_true" (okIs (do let a ← Ipv4Addr.new 1#i32 1#i32 1#i32 1#i32; let b ← Ipv4Addr.new 257#i32 1#i32 1#i32 1#i32; Ipv4Addr.eq a b) true)
  report "ipv6_eq_false" (okIs (Ipv6Addr.eq (Ipv6Addr.mk 0#u64 1#u64) (Ipv6Addr.mk 0#u64 2#u64)) false)
  report "is_u8_255" (okIs (is_u8 255#i32) true)
  report "is_u8_256" (okIs (is_u8 256#i32) false)
  report "is_u16_max" (okIs (is_u16 65535#i32) true)
  report "is_u16_neg" (okIs (is_u16 (-1)#i32) false)
  report "is_u32_max" (okIs (is_u32 4294967295#i64) true)
  report "is_u32_over" (okIs (is_u32 4294967296#i64) false)

  report "lower_A" (okIs (ascii_lower_byte 65#i32) 97#i32)
  report "lower_Z" (okIs (ascii_lower_byte 90#i32) 122#i32)
  report "lower_a" (okIs (ascii_lower_byte 97#i32) 97#i32)
  report "digit_0" (okIs (is_ascii_digit 48#i32) true)
  report "digit_slash" (okIs (is_ascii_digit 47#i32) false)
  report "hex_F" (okIs (hex_val 70#i32) 15#i32)
  report "hex_bad" (okIs (hex_val 71#i32) (-1)#i32)
  report "b64_A" (okIs (b64url_val 65#i32) 0#i32)
  report "b64_z" (okIs (b64url_val 122#i32) 51#i32)
  report "b64_0" (okIs (b64url_val 48#i32) 52#i32)
  report "b64_dash" (okIs (b64url_val 45#i32) 62#i32)
  report "b64_under" (okIs (b64url_val 95#i32) 63#i32)
  report "b64_plus_bad" (okIs (b64url_val 43#i32) (-1)#i32)

  report "hdr_hi_pack" (okIs (pack_header_flags_hi true 5#i32 true false true) 173#i32)
  report "hdr_hi_qr" (okIs (unpack_header_qr 173#i32) true)
  report "hdr_hi_op" (okIs (unpack_header_opcode 173#i32) 5#i32)
  report "hdr_hi_aa" (okIs (unpack_header_aa 173#i32) true)
  report "hdr_hi_tc" (okIs (unpack_header_tc 173#i32) false)
  report "hdr_hi_rd" (okIs (unpack_header_rd 173#i32) true)
  report "hdr_lo_pack" (okIs (pack_header_flags_lo true false true true 3#i32) 179#i32)
  report "hdr_lo_ra" (okIs (unpack_header_ra 179#i32) true)
  report "hdr_lo_z" (okIs (unpack_header_z 179#i32) false)
  report "hdr_lo_ad" (okIs (unpack_header_ad 179#i32) true)
  report "hdr_lo_cd" (okIs (unpack_header_cd 179#i32) true)
  report "hdr_lo_rcode" (okIs (unpack_header_rcode 179#i32) 3#i32)

  report "edns_ext_rt" (okIs (do let t ← edns_pack_ttl 1#i32 0#i32 true; edns_ttl_ext_rcode t) 1#i32)
  report "edns_ver_rt" (okIs (do let t ← edns_pack_ttl 1#i32 2#i32 true; edns_ttl_version t) 2#i32)
  report "edns_do_t" (okIs (do let t ← edns_pack_ttl 1#i32 0#i32 true; edns_ttl_dnssec_ok t) true)
  report "edns_do_f" (okIs (do let t ← edns_pack_ttl 1#i32 0#i32 false; edns_ttl_dnssec_ok t) false)
  report "edns_badvers" (okIs (combine_extended_rcode 1#i32 0#i32) 16#i32)
  report "edns_badcookie" (okIs (combine_extended_rcode 1#i32 7#i32) 23#i32)
