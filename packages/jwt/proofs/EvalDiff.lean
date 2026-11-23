/-
Executable `#guard` and `#eval` differential suite over the extracted
`Jwt.Funs` definitions. `run_proofs.sh` compares the stdout of this file
byte-for-byte (`diff -u`) against native Pion execution of `packages/jwt`.
-/
import Jwt.Funs

open Aeneas Aeneas.Std Result Pion jwt

namespace JwtEvalDiff

def i32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
def i64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩
def u8 (n : Nat) : Std.U8 := ⟨BitVec.ofNat 8 n⟩
def u32 (n : Nat) : Std.U32 := ⟨BitVec.ofNat 32 n⟩

def maxI64 : Std.I64 := i64 9223372036854775807
def minI64 : Std.I64 := i64 (-9223372036854775808)

def strBytes (s : String) : Pion.Bytes :=
  ⟨s.toUTF8.toList.map (fun b => u8 b.toNat)⟩

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def algOk (s : String) (want : Algorithm) : Bool :=
  (do
    let res ← algorithm_from_str s
    match res with
    | .Ok a => algorithm_equals a want
    | .Err _ => ok false).reducesTo true

def algIsNoneErr (s : String) : Bool :=
  (do
    let res ← algorithm_from_str s
    match res with
    | .Err .AlgorithmNoneNotAllowed => ok true
    | _ => ok false).reducesTo true

def algIsUnsupported (s : String) : Bool :=
  (do
    let res ← algorithm_from_str s
    match res with
    | .Err (.UnsupportedAlgorithm _) => ok true
    | _ => ok false).reducesTo true

def b64RoundtripAll64 : Bool :=
  (List.range 64).all fun v =>
    (do
      let enc ← b64url_encode_val (i32 v)
      let dec ← b64url_decode_byte enc
      ok (dec == i32 v)).reducesTo true

-- 1. Constant-time equality
#guard okIs (constant_time_eq (strBytes "") (strBytes "")) true
#guard okIs (constant_time_eq (strBytes "abcdef0123456789") (strBytes "abcdef0123456789")) true
#guard okIs (constant_time_eq (strBytes "abcdef0123456789") (strBytes "abcdef0123456788")) false
#guard okIs (constant_time_eq (strBytes "abcdef") (strBytes "bbcdef")) false
#guard okIs (constant_time_eq (strBytes "abc") (strBytes "abcd")) false

-- 2. Anti-CVE algorithm & HMAC key gate
#guard algOk "HS256" .HS256
#guard algOk "HS384" .HS384
#guard algOk "HS512" .HS512
#guard algIsNoneErr "none"
#guard algIsNoneErr "None"
#guard algIsNoneErr "NONE"
#guard algIsNoneErr "nOnE"
#guard algIsUnsupported "RS256"
#guard algIsUnsupported ""
#guard okIs (hmac_key_valid (strBytes "")) false
#guard okIs (hmac_key_valid (strBytes "k")) true
#guard okIs (alg_in_allowlist .HS256 ⟨[]⟩) false
#guard okIs (alg_in_allowlist .HS512 ⟨[.HS256, .HS512]⟩) true
#guard okIs (alg_in_allowlist .HS384 ⟨[.HS256, .HS512]⟩) false
#guard okIs (check_verifier_alg .HS256 .HS256 ⟨[.HS256]⟩) true
#guard okIs (check_verifier_alg .HS256 .HS512 ⟨[.HS256, .HS512]⟩) false

-- 3. Saturating exp / nbf time-window & leeway overflow immunity
#guard okIs (is_expired (i64 1000) (i64 1000) (i64 0)) true
#guard okIs (is_expired (i64 999) (i64 1000) (i64 0)) false
#guard okIs (is_expired (i64 1005) (i64 1000) (i64 10)) false
#guard okIs (is_expired (i64 1010) (i64 1000) (i64 10)) true
#guard okIs (is_expired (i64 1000) (i64 1000) (i64 (-50))) true
#guard okIs (is_expired minI64 minI64 maxI64) true
#guard okIs (is_expired (i64 0) maxI64 maxI64) false
#guard okIs (is_immature (i64 1000) (i64 1000) (i64 0)) false
#guard okIs (is_immature (i64 999) (i64 1000) (i64 0)) true
#guard okIs (is_immature (i64 995) (i64 1000) (i64 10)) false
#guard okIs (is_immature (i64 989) (i64 1000) (i64 10)) true
#guard okIs (is_immature maxI64 maxI64 maxI64) false
#guard okIs (is_immature minI64 (i64 0) (i64 100)) true

-- 4. Strict unpadded Base64URL character encode/decode & canonical tail bits
#guard b64RoundtripAll64
#guard okIs (b64url_decode_byte (u8 43)) (i32 (-1))
#guard okIs (b64url_decode_byte (u8 47)) (i32 (-1))
#guard okIs (b64url_decode_byte (u8 61)) (i32 (-1))
#guard okIs (b64url_decode_byte (u8 32)) (i32 (-1))
#guard okIs (b64url_decode_byte (u8 0)) (i32 (-1))
#guard okIs (base64url_len_valid (i32 1)) false
#guard okIs (base64url_len_valid (i32 5)) false
#guard okIs (base64url_len_valid (i32 0)) true
#guard okIs (base64url_len_valid (i32 2)) true
#guard okIs (base64url_len_valid (i32 3)) true
#guard okIs (base64url_len_valid (i32 4)) true
#guard okIs (base64url_tail_bits_valid (i32 2) (i32 0x30)) true
#guard okIs (base64url_tail_bits_valid (i32 2) (i32 0x31)) false
#guard okIs (base64url_tail_bits_valid (i32 3) (i32 0x3C)) true
#guard okIs (base64url_tail_bits_valid (i32 3) (i32 0x3D)) false

-- 5. SHA-256 bitwise primitives
#guard okIs (sha256_ch (u32 0x12345678) (u32 0xDEADBEEF) (u32 0xDEADBEEF)) (u32 0xDEADBEEF)
#guard okIs (sha256_maj (u32 0xCAFEBABE) (u32 0xCAFEBABE) (u32 0x11223344)) (u32 0xCAFEBABE)
#guard (do
  let r1 ← sha256_rotr (u32 0x12345678) (u32 7)
  let r2 ← sha256_rotr r1 (u32 11)
  let r3 ← sha256_rotr (u32 0x12345678) (u32 18)
  ok (r2 == r3)).reducesTo true

def fmtResult (label : String) (b : Bool) : String :=
  s!"{label}: {if b then "PASS" else "FAIL"}"

#eval do
  let checks : List (String × Bool) := [
    ("ct_eq_empty", okIs (constant_time_eq (strBytes "") (strBytes "")) true),
    ("ct_eq_same", okIs (constant_time_eq (strBytes "abcdef0123456789") (strBytes "abcdef0123456789")) true),
    ("ct_eq_diff_last", okIs (constant_time_eq (strBytes "abcdef0123456789") (strBytes "abcdef0123456788")) false),
    ("ct_eq_diff_first", okIs (constant_time_eq (strBytes "abcdef") (strBytes "bbcdef")) false),
    ("ct_eq_diff_len", okIs (constant_time_eq (strBytes "abc") (strBytes "abcd")) false),

    ("alg_hs256", algOk "HS256" .HS256),
    ("alg_hs384", algOk "HS384" .HS384),
    ("alg_hs512", algOk "HS512" .HS512),
    ("alg_reject_none_lower", algIsNoneErr "none"),
    ("alg_reject_none_title", algIsNoneErr "None"),
    ("alg_reject_none_upper", algIsNoneErr "NONE"),
    ("alg_reject_none_mixed", algIsNoneErr "nOnE"),
    ("alg_reject_rs256", algIsUnsupported "RS256"),
    ("alg_reject_empty", algIsUnsupported ""),
    ("hmac_key_reject_empty", okIs (hmac_key_valid (strBytes "")) false),
    ("hmac_key_accept_nonempty", okIs (hmac_key_valid (strBytes "k")) true),
    ("allowlist_empty", okIs (alg_in_allowlist .HS256 ⟨[]⟩) false),
    ("allowlist_hit", okIs (alg_in_allowlist .HS512 ⟨[.HS256, .HS512]⟩) true),
    ("allowlist_miss", okIs (alg_in_allowlist .HS384 ⟨[.HS256, .HS512]⟩) false),
    ("verifier_alg_match", okIs (check_verifier_alg .HS256 .HS256 ⟨[.HS256]⟩) true),
    ("verifier_alg_mismatch", okIs (check_verifier_alg .HS256 .HS512 ⟨[.HS256, .HS512]⟩) false),

    ("exp_exact_boundary", okIs (is_expired (i64 1000) (i64 1000) (i64 0)) true),
    ("exp_before_expiry", okIs (is_expired (i64 999) (i64 1000) (i64 0)) false),
    ("exp_within_leeway", okIs (is_expired (i64 1005) (i64 1000) (i64 10)) false),
    ("exp_past_leeway", okIs (is_expired (i64 1010) (i64 1000) (i64 10)) true),
    ("exp_neg_leeway_clamped", okIs (is_expired (i64 1000) (i64 1000) (i64 (-50))) true),
    ("exp_min_i64_no_wrap", okIs (is_expired minI64 minI64 maxI64) true),
    ("exp_max_i64_no_wrap", okIs (is_expired (i64 0) maxI64 maxI64) false),
    ("nbf_exact_boundary", okIs (is_immature (i64 1000) (i64 1000) (i64 0)) false),
    ("nbf_before_valid", okIs (is_immature (i64 999) (i64 1000) (i64 0)) true),
    ("nbf_within_leeway", okIs (is_immature (i64 995) (i64 1000) (i64 10)) false),
    ("nbf_outside_leeway", okIs (is_immature (i64 989) (i64 1000) (i64 10)) true),
    ("nbf_max_i64_no_wrap", okIs (is_immature maxI64 maxI64 maxI64) false),
    ("nbf_min_i64_no_wrap", okIs (is_immature minI64 (i64 0) (i64 100)) true),

    ("b64url_64_roundtrip", b64RoundtripAll64),
    ("b64url_reject_plus", okIs (b64url_decode_byte (u8 43)) (i32 (-1))),
    ("b64url_reject_slash", okIs (b64url_decode_byte (u8 47)) (i32 (-1))),
    ("b64url_reject_pad", okIs (b64url_decode_byte (u8 61)) (i32 (-1))),
    ("b64url_reject_space", okIs (b64url_decode_byte (u8 32)) (i32 (-1))),
    ("b64url_reject_nul", okIs (b64url_decode_byte (u8 0)) (i32 (-1))),
    ("b64url_len_mod4_eq1_reject", okIs (base64url_len_valid (i32 1)) false && okIs (base64url_len_valid (i32 5)) false),
    ("b64url_len_valid_0234", okIs (base64url_len_valid (i32 0)) true && okIs (base64url_len_valid (i32 2)) true && okIs (base64url_len_valid (i32 3)) true && okIs (base64url_len_valid (i32 4)) true),
    ("b64url_tail_rem2_ok", okIs (base64url_tail_bits_valid (i32 2) (i32 0x30)) true),
    ("b64url_tail_rem2_bad", okIs (base64url_tail_bits_valid (i32 2) (i32 0x31)) false),
    ("b64url_tail_rem3_ok", okIs (base64url_tail_bits_valid (i32 3) (i32 0x3C)) true),
    ("b64url_tail_rem3_bad", okIs (base64url_tail_bits_valid (i32 3) (i32 0x3D)) false),

    ("sha256_ch_same", okIs (sha256_ch (u32 0x12345678) (u32 0xDEADBEEF) (u32 0xDEADBEEF)) (u32 0xDEADBEEF)),
    ("sha256_maj_same", okIs (sha256_maj (u32 0xCAFEBABE) (u32 0xCAFEBABE) (u32 0x11223344)) (u32 0xCAFEBABE)),
    ("sha256_rotr_compose", (do
      let r1 ← sha256_rotr (u32 0x12345678) (u32 7)
      let r2 ← sha256_rotr r1 (u32 11)
      let r3 ← sha256_rotr (u32 0x12345678) (u32 18)
      ok (r2 == r3)).reducesTo true)
  ]
  for (label, b) in checks do
    IO.println (fmtResult label b)

end JwtEvalDiff
