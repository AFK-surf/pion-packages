import Jwt.Funs

open Aeneas Aeneas.Std Result Pion jwt

namespace JwtEvalDiff

private def i32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def i64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩
private def u8 (n : Nat) : Std.U8 := ⟨BitVec.ofNat 8 n⟩
private def u32 (n : Nat) : Std.U32 := ⟨BitVec.ofNat 32 n⟩

private def maxI64 : Std.I64 := i64 9223372036854775807
private def minI64 : Std.I64 := i64 (-9223372036854775808)

private def strBytes (s : String) : Pion.Bytes :=
  ⟨s.toUTF8.toList.map (fun b => u8 b.toNat)⟩

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtU32 (r : Result Std.U32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtAlgRes (r : Result (Pion.Res Algorithm JwtError)) : String :=
  match r.match with
  | .ok (.Ok .HS256) => "Ok(HS256)"
  | .ok (.Ok .HS384) => "Ok(HS384)"
  | .ok (.Ok .HS512) => "Ok(HS512)"
  | .ok (.Err .AlgorithmNoneNotAllowed) => "Err(NoneNotAllowed)"
  | .ok (.Err (.UnsupportedAlgorithm _)) => "Err(Unsupported)"
  | .ok (.Err _) => "Err(Other)"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"ct_eq_empty={fmtBool (constant_time_eq (strBytes "") (strBytes ""))}"
  , s!"ct_eq_same={fmtBool (constant_time_eq (strBytes "abcdef0123456789") (strBytes "abcdef0123456789"))}"
  , s!"ct_eq_diff_last={fmtBool (constant_time_eq (strBytes "abcdef0123456789") (strBytes "abcdef0123456788"))}"
  , s!"ct_eq_diff_len={fmtBool (constant_time_eq (strBytes "abc") (strBytes "abcd"))}"
  , s!"alg_hs256={fmtAlgRes (algorithm_from_str "HS256")}"
  , s!"alg_hs384={fmtAlgRes (algorithm_from_str "HS384")}"
  , s!"alg_hs512={fmtAlgRes (algorithm_from_str "HS512")}"
  , s!"alg_none={fmtAlgRes (algorithm_from_str "none")}"
  , s!"alg_NONE={fmtAlgRes (algorithm_from_str "NONE")}"
  , s!"alg_rs256={fmtAlgRes (algorithm_from_str "RS256")}"
  , s!"allow_empty={fmtBool (alg_in_allowlist .HS256 ⟨[]⟩)}"
  , s!"allow_hit={fmtBool (alg_in_allowlist .HS512 ⟨[.HS256, .HS512]⟩)}"
  , s!"allow_miss={fmtBool (alg_in_allowlist .HS384 ⟨[.HS256, .HS512]⟩)}"
  , s!"ver_match={fmtBool (check_verifier_alg .HS256 .HS256 ⟨[.HS256]⟩)}"
  , s!"ver_miss={fmtBool (check_verifier_alg .HS256 .HS512 ⟨[.HS256, .HS512]⟩)}"
  , s!"exp_eq={fmtBool (is_expired (i64 1000) (i64 1000) (i64 0))}"
  , s!"exp_before={fmtBool (is_expired (i64 999) (i64 1000) (i64 0))}"
  , s!"exp_leeway={fmtBool (is_expired (i64 1005) (i64 1000) (i64 10))}"
  , s!"exp_neg_lw={fmtBool (is_expired (i64 1000) (i64 1000) (i64 (-50)))}"
  , s!"exp_min={fmtBool (is_expired minI64 minI64 maxI64)}"
  , s!"exp_max={fmtBool (is_expired (i64 0) maxI64 maxI64)}"
  , s!"nbf_eq={fmtBool (is_immature (i64 1000) (i64 1000) (i64 0))}"
  , s!"nbf_before={fmtBool (is_immature (i64 999) (i64 1000) (i64 0))}"
  , s!"nbf_leeway={fmtBool (is_immature (i64 995) (i64 1000) (i64 10))}"
  , s!"nbf_max={fmtBool (is_immature maxI64 maxI64 maxI64)}"
  , s!"nbf_min={fmtBool (is_immature minI64 (i64 0) (i64 100))}"
  , s!"b64_dec_A={fmtI32 (b64url_decode_byte (u8 65))}"
  , s!"b64_dec_dash={fmtI32 (b64url_decode_byte (u8 45))}"
  , s!"b64_dec_under={fmtI32 (b64url_decode_byte (u8 95))}"
  , s!"b64_dec_plus={fmtI32 (b64url_decode_byte (u8 43))}"
  , s!"b64_dec_pad={fmtI32 (b64url_decode_byte (u8 61))}"
  , s!"b64_len_1={fmtBool (base64url_len_valid (i32 1))}"
  , s!"b64_len_4={fmtBool (base64url_len_valid (i32 4))}"
  , s!"rotr_7={fmtU32 (sha256_rotr (u32 0x12345678) (u32 7))}"
  ]

#eval IO.println (String.intercalate "\n" runAll)

end JwtEvalDiff
