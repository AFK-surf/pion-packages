import Crypto.Types
import Crypto.Funs

open Aeneas Aeneas.Std Result Pion crypto

namespace CryptoEvalDiff

private def i32 (x : Int) : Std.I32 := ⟨BitVec.ofInt 32 x⟩
private def u32 (x : Nat) : Std.U32 := ⟨BitVec.ofNat 32 x⟩

private def showI32 (label : String) (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

private def showU32 (label : String) (r : Result Std.U32) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

private def showFe0 (label : String) (r : Result Fe) : String :=
  match r.match with
  | .ok f => s!"{label}={f.h0.val}"
  | _ => s!"{label}=TRAP"

private def showCswap0 (label : String) (r : Result (Fe × Fe)) : String :=
  match r.match with
  | .ok p => s!"{label}={p.1.h0.val},{p.2.h0.val}"
  | _ => s!"{label}=TRAP"

def feA : Fe := ⟨1#i64, 2#i64, 3#i64, 4#i64, 5#i64, 6#i64, 7#i64, 8#i64, 9#i64, 10#i64⟩
def feB : Fe := ⟨100#i64, 200#i64, 300#i64, 400#i64, 500#i64, 600#i64, 700#i64, 800#i64, 900#i64, 1000#i64⟩

def runAll : List String :=
  [ showI32 "ct_eq" (ct_diff_acc 0#i32 42#i32 42#i32)
  , showI32 "ct_ne" (ct_diff_acc 0#i32 42#i32 43#i32)
  , showI32 "ct_min_max" (ct_diff_acc 0#i32 (i32 (-2147483648)) (i32 2147483647))
  , showFe0 "cmov_0" (fe_cmov feA feB 0#i64)
  , showFe0 "cmov_1" (fe_cmov feA feB 1#i64)
  , showCswap0 "cswap_0" (fe_cswap_pair feA feB 0#i64)
  , showCswap0 "cswap_1" (fe_cswap_pair feA feB 1#i64)
  , showI32 "clamp_lo_0" (x25519_clamp_low_byte 0#i32)
  , showI32 "clamp_lo_255" (x25519_clamp_low_byte 255#i32)
  , showI32 "clamp_lo_neg1" (x25519_clamp_low_byte (i32 (-1)))
  , showI32 "clamp_hi_0" (x25519_clamp_high_byte 0#i32)
  , showI32 "clamp_hi_255" (x25519_clamp_high_byte 255#i32)
  , showI32 "clamp_hi_min" (x25519_clamp_high_byte (i32 (-2147483648)))
  , showU32 "rotl_16" (cc_rotl32 (u32 0x12345678) 16#u32)
  , showU32 "rotl_max" (cc_rotl32 (u32 0xFFFFFFFF) 7#u32)
  , showU32 "rotl_trap_32" (cc_rotl32 1#u32 32#u32)
  , showU32 "rotl_trap_0" (cc_rotl32 1#u32 0#u32)
  , showI32 "hkdf_1" (hkdf_sha256_blocks 1#i32)
  , showI32 "hkdf_8160" (hkdf_sha256_blocks 8160#i32)
  , showI32 "hkdf_8161_oob" (hkdf_sha256_blocks 8161#i32)
  , showI32 "hkdf_0" (hkdf_sha256_blocks 0#i32)
  , showI32 "hkdf_neg1" (hkdf_sha256_blocks (i32 (-1)))
  , showI32 "hex_0" (hex_nibble_val 48#i32)
  , showI32 "hex_F" (hex_nibble_val 70#i32)
  , showI32 "hex_f" (hex_nibble_val 102#i32)
  , showI32 "hex_min" (hex_nibble_val (i32 (-2147483648)))
  , showI32 "hex_max" (hex_nibble_val (i32 2147483647))
  ]

#eval IO.println (String.intercalate "\n" runAll)

end CryptoEvalDiff
