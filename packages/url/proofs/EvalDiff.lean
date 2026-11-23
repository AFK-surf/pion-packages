import Aeneas
import PionLean
import Url.Types
import Url.Funs

open Aeneas Aeneas.Std Result Pion url

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def mkI64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩

private def checkCase {α : Type} [BEq α] (label : String) (r : Result α) (expected : α) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

def runAll : List String := [
  -- Punycode threshold
  checkCase "pth_lo" (puny_threshold (mkI64 36) (mkI64 72)) (mkI64 1),
  checkCase "pth_eq" (puny_threshold (mkI64 72) (mkI64 72)) (mkI64 1),
  checkCase "pth_mid" (puny_threshold (mkI64 80) (mkI64 72)) (mkI64 8),
  checkCase "pth_hi" (puny_threshold (mkI64 108) (mkI64 72)) (mkI64 26),
  -- Punycode digits
  checkCase "penc_0" (puny_encode_digit (mkI64 0)) 97#u8,
  checkCase "penc_25" (puny_encode_digit (mkI64 25)) 122#u8,
  checkCase "penc_26" (puny_encode_digit (mkI64 26)) 48#u8,
  checkCase "penc_35" (puny_encode_digit (mkI64 35)) 57#u8,
  checkCase "pdec_a" (puny_decode_digit (mkI32 97)) (mkI64 0),
  checkCase "pdec_Z" (puny_decode_digit (mkI32 90)) (mkI64 25),
  checkCase "pdec_0" (puny_decode_digit (mkI32 48)) (mkI64 26),
  checkCase "pdec_9" (puny_decode_digit (mkI32 57)) (mkI64 35),
  checkCase "pdec_bad" (puny_decode_digit (mkI32 45)) (mkI64 (-1)),
  -- Percent-encode masks
  checkCase "emask_nul" (encode_byte_mask (mkI32 0)) (mkI32 255),
  checkCase "emask_tab" (encode_byte_mask (mkI32 9)) (mkI32 255),
  checkCase "emask_sp" (encode_byte_mask (mkI32 32)) (mkI32 254),
  checkCase "emask_hash" (encode_byte_mask (mkI32 35)) (mkI32 252),
  checkCase "emask_apos" (encode_byte_mask (mkI32 39)) (mkI32 136),
  checkCase "emask_star" (encode_byte_mask (mkI32 42)) (mkI32 0),
  checkCase "emask_slash" (encode_byte_mask (mkI32 47)) (mkI32 224),
  checkCase "emask_A" (encode_byte_mask (mkI32 65)) (mkI32 0),
  checkCase "emask_qmark" (encode_byte_mask (mkI32 63)) (mkI32 240),
  checkCase "emask_dollar" (encode_byte_mask (mkI32 36)) (mkI32 192),
  checkCase "emask_del" (encode_byte_mask (mkI32 127)) (mkI32 255),
  checkCase "emask_utf8" (encode_byte_mask (mkI32 200)) (mkI32 255),
  checkCase "eset_ctrl" (encode_set_mask .Controls) (mkI32 1),
  checkCase "eset_comp" (encode_set_mask .Component) (mkI32 64),
  -- IPv4
  checkCase "v4_loopback" (do let ip ← Ipv4Addr.new (mkI32 127) (mkI32 0) (mkI32 0) (mkI32 1); Ipv4Addr.to_u32 ip) 2130706433#u32,
  checkCase "v4_bcast" (do let ip ← Ipv4Addr.new (mkI32 255) (mkI32 255) (mkI32 255) (mkI32 255); Ipv4Addr.to_u32 ip) 4294967295#u32,
  checkCase "v4_octets" (do let ip ← Ipv4Addr.from_u32 3232235777#u32; Ipv4Addr.octets ip) (mkI32 192, mkI32 168, mkI32 1, mkI32 1),
  checkCase "v4_eq_t" (do let a ← Ipv4Addr.from_u32 1#u32; let b ← Ipv4Addr.from_u32 1#u32; Ipv4Addr.eq a b) true,
  checkCase "v4_eq_f" (do let a ← Ipv4Addr.from_u32 1#u32; let b ← Ipv4Addr.from_u32 2#u32; Ipv4Addr.eq a b) false,
  -- IPv6
  checkCase "v6_seg0" (do let ip ← Ipv6Addr.new (mkI32 0x2001) (mkI32 0x0db8) (mkI32 0) (mkI32 0) (mkI32 0) (mkI32 0) (mkI32 0) (mkI32 1); ipv6_seg ip (mkI32 0)) (mkI32 0x2001),
  checkCase "v6_seg7" (do let ip ← Ipv6Addr.new (mkI32 0x2001) (mkI32 0x0db8) (mkI32 0) (mkI32 0) (mkI32 0) (mkI32 0) (mkI32 0) (mkI32 0x10001); ipv6_seg ip (mkI32 7)) (mkI32 1),
  checkCase "v6_eq_t" (do let a ← Ipv6Addr.new (mkI32 1) (mkI32 2) (mkI32 3) (mkI32 4) (mkI32 5) (mkI32 6) (mkI32 7) (mkI32 8); let b ← Ipv6Addr.new (mkI32 1) (mkI32 2) (mkI32 3) (mkI32 4) (mkI32 5) (mkI32 6) (mkI32 7) (mkI32 8); Ipv6Addr.eq a b) true,
  checkCase "v6_eq_f" (do let a ← Ipv6Addr.new (mkI32 1) (mkI32 2) (mkI32 3) (mkI32 4) (mkI32 5) (mkI32 6) (mkI32 7) (mkI32 8); let b ← Ipv6Addr.new (mkI32 1) (mkI32 2) (mkI32 3) (mkI32 4) (mkI32 5) (mkI32 6) (mkI32 7) (mkI32 9); Ipv6Addr.eq a b) false
]

#eval IO.println (String.intercalate "\n" runAll)
