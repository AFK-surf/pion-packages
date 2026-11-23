import Url.Types
import Url.Funs

open Aeneas Aeneas.Std Result Pion url

namespace UrlEvalDiff

private def i32 (x : Int) : Std.I32 := ⟨BitVec.ofInt 32 x⟩
private def i64 (x : Int) : Std.I64 := ⟨BitVec.ofInt 64 x⟩

private def showI32 (label : String) (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

private def showI64 (label : String) (r : Result Std.I64) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

private def showU8 (label : String) (r : Result Std.U8) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

private def showIp4 (label : String) (r : Result Ipv4Addr) : String :=
  match r.match with
  | .ok ip => s!"{label}={ip.bits.val}"
  | _ => s!"{label}=TRAP"

private def showOcts (label : String) (r : Result (Std.I32 × Std.I32 × Std.I32 × Std.I32)) : String :=
  match r.match with
  | .ok (a, b, c, d) => s!"{label}={a.val}.{b.val}.{c.val}.{d.val}"
  | _ => s!"{label}=TRAP"

private def showIp6 (label : String) (r : Result Ipv6Addr) : String :=
  match r.match with
  | .ok ip => s!"{label}={ip.s0.val},{ip.s7.val}"
  | _ => s!"{label}=TRAP"

def runAll : List String :=
  [ showI64 "puny_thr_lo" (puny_threshold 36#i64 72#i64)
  , showI64 "puny_thr_mid" (puny_threshold 80#i64 72#i64)
  , showI64 "puny_thr_hi" (puny_threshold 200#i64 72#i64)
  , showI64 "puny_thr_min" (puny_threshold (i64 (-9223372036854775808)) 0#i64)
  , showU8 "puny_enc_0" (puny_encode_digit 0#i64)
  , showU8 "puny_enc_35" (puny_encode_digit 35#i64)
  , showI64 "puny_dec_a" (puny_decode_digit 97#i32)
  , showI64 "puny_dec_Z" (puny_decode_digit 90#i32)
  , showI64 "puny_dec_9" (puny_decode_digit 57#i32)
  , showI64 "puny_dec_min" (puny_decode_digit (i32 (-2147483648)))
  , showI64 "puny_dec_max" (puny_decode_digit (i32 2147483647))
  , showI32 "enc_ctrl_0" (encode_byte_mask 0#i32)
  , showI32 "enc_alnum_A" (encode_byte_mask 65#i32)
  , showI32 "enc_sp" (encode_byte_mask 32#i32)
  , showI32 "enc_del" (encode_byte_mask 127#i32)
  , showI32 "enc_min" (encode_byte_mask (i32 (-2147483648)))
  , showI32 "enc_max" (encode_byte_mask (i32 2147483647))
  , showIp4 "ip4_127" (Ipv4Addr.new 127#i32 0#i32 0#i32 1#i32)
  , showIp4 "ip4_255" (Ipv4Addr.new 255#i32 255#i32 255#i32 255#i32)
  , showIp4 "ip4_oob" (Ipv4Addr.new (i32 (-1)) 256#i32 0#i32 0#i32)
  , showOcts "ip4_octs" (do let ip ← Ipv4Addr.new 192#i32 168#i32 1#i32 42#i32; Ipv4Addr.octets ip)
  , showIp6 "ip6_lo" (Ipv6Addr.new 0#i32 0#i32 0#i32 0#i32 0#i32 0#i32 0#i32 1#i32)
  , showIp6 "ip6_mask" (Ipv6Addr.new (i32 (-1)) 0#i32 0#i32 0#i32 0#i32 0#i32 0#i32 65536#i32)
  ]

#eval IO.println (String.intercalate "\n" runAll)

end UrlEvalDiff
