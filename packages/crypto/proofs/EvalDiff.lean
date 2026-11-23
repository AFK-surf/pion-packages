import Aeneas
import PionLean
import Crypto.Types
import Crypto.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion crypto

def checkBool (lbl : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def checkI32 (lbl : String) (r : Result Std.I32) (expected : Std.I32) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def checkI64 (lbl : String) (r : Result Std.I64) (expected : Std.I64) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def checkU32 (lbl : String) (r : Result Std.U32) (expected : Std.U32) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def feA : Fe := Fe.mk 1#i64 2#i64 3#i64 4#i64 5#i64 6#i64 7#i64 8#i64 9#i64 10#i64
def feB : Fe := Fe.mk 11#i64 12#i64 13#i64 14#i64 15#i64 16#i64 17#i64 18#i64 19#i64 20#i64

def runAll : List String := [
  -- ct_diff_acc (4)
  checkI32 "ctd_eq" (ct_diff_acc 0#i32 42#i32 42#i32) 0#i32,
  checkI32 "ctd_ne" (ct_diff_acc 0#i32 42#i32 43#i32) 1#i32,
  checkI32 "ctd_latch" (ct_diff_acc 4#i32 99#i32 99#i32) 4#i32,
  checkI32 "ctd_both" (ct_diff_acc 4#i32 1#i32 2#i32) 7#i32,
  -- fe_cmov & fe_cswap_pair (6)
  checkI64 "cmov_0" (do let r ← fe_cmov feA feB 0#i64; ok r.h0) 1#i64,
  checkI64 "cmov_1" (do let r ← fe_cmov feA feB 1#i64; ok r.h0) 11#i64,
  checkI64 "cmov_h9" (do let r ← fe_cmov feA feB 1#i64; ok r.h9) 20#i64,
  checkI64 "cswap_0a" (do let p ← fe_cswap_pair feA feB 0#i64; ok p.1.h0) 1#i64,
  checkI64 "cswap_1a" (do let p ← fe_cswap_pair feA feB 1#i64; ok p.1.h0) 11#i64,
  checkI64 "cswap_1b" (do let p ← fe_cswap_pair feA feB 1#i64; ok p.2.h9) 10#i64,
  -- fe_add (4)
  checkI64 "feadd_h0" (do let r ← fe_add feA feB; ok r.h0) 12#i64,
  checkI64 "feadd_h4" (do let r ← fe_add feA feB; ok r.h4) 20#i64,
  checkI64 "feadd_h9" (do let r ← fe_add feA feB; ok r.h9) 30#i64,
  checkI64 "feadd_ba" (do let r ← fe_add feB feA; ok r.h0) 12#i64,
  -- x25519 scalar clamping (6)
  checkI32 "xlo_0" (x25519_clamp_low_byte 0#i32) 0#i32,
  checkI32 "xlo_7" (x25519_clamp_low_byte 7#i32) 0#i32,
  checkI32 "xlo_ff" (x25519_clamp_low_byte 255#i32) 248#i32,
  checkI32 "xhi_0" (x25519_clamp_high_byte 0#i32) 64#i32,
  checkI32 "xhi_ff" (x25519_clamp_high_byte 255#i32) 127#i32,
  checkI32 "xhi_80" (x25519_clamp_high_byte 128#i32) 64#i32,
  -- cc_rotl32 (4)
  checkU32 "rot_16" (cc_rotl32 0x12345678#u32 16#u32) 0x56781234#u32,
  checkU32 "rot_12" (cc_rotl32 0x12345678#u32 12#u32) 0x45678123#u32,
  checkU32 "rot_8" (cc_rotl32 0x12345678#u32 8#u32) 0x34567812#u32,
  checkU32 "rot_7" (cc_rotl32 0x80000001#u32 7#u32) 0x000000C0#u32,
  -- ChaCha20-Poly1305 AEAD lengths (6)
  checkBool "ck_32" (chacha20_is_valid_key_len 32#i32) true,
  checkBool "ck_16" (chacha20_is_valid_key_len 16#i32) false,
  checkBool "cn_12" (chacha20_is_valid_nonce_len 12#i32) true,
  checkBool "cn_8" (chacha20_is_valid_nonce_len 8#i32) false,
  checkBool "ct_16" (chacha20_is_valid_ct_len 16#i32) true,
  checkBool "ct_15" (chacha20_is_valid_ct_len 15#i32) false,
  -- HKDF-SHA256 & HKDF-SHA512 (10)
  checkBool "h256_ok" (hkdf_sha256_valid_len 8160#i32) true,
  checkBool "h256_hi" (hkdf_sha256_valid_len 8161#i32) false,
  checkBool "h256_neg" (hkdf_sha256_valid_len (-1)#i32) false,
  checkI32 "h256_b1" (hkdf_sha256_blocks 1#i32) 1#i32,
  checkI32 "h256_b255" (hkdf_sha256_blocks 8160#i32) 255#i32,
  checkBool "h512_ok" (hkdf_sha512_valid_len 16320#i32) true,
  checkBool "h512_hi" (hkdf_sha512_valid_len 16321#i32) false,
  checkI32 "h512_b1" (hkdf_sha512_blocks 1#i32) 1#i32,
  checkI32 "h512_b2" (hkdf_sha512_blocks 65#i32) 2#i32,
  checkI32 "h512_b255" (hkdf_sha512_blocks 16320#i32) 255#i32,
  -- hex_nibble_val (4)
  checkI32 "hx_0" (hex_nibble_val 48#i32) 0#i32,
  checkI32 "hx_a" (hex_nibble_val 97#i32) 10#i32,
  checkI32 "hx_F" (hex_nibble_val 70#i32) 15#i32,
  checkI32 "hx_bad" (hex_nibble_val 71#i32) (-1)#i32
]

#eval IO.println (String.intercalate "\n" runAll)
