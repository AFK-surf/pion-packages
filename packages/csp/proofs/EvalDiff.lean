import Aeneas
import PionLean
import Csp.Types
import Csp.Funs

open Aeneas Aeneas.Std Result Pion csp

namespace CspEvalDiff

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩

private def checkCase [BEq α] (label : String) (r : Result α) (expected : α) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

def runAll : List String :=
  [ checkCase "lim_def" (do let l ← ParseLimits.default; parse_limits_all_nonneg l) true
  , checkCase "lim_zero" (do let l ← ParseLimits.new (mkI32 0) (mkI32 0) (mkI32 0) (mkI32 0); parse_limits_all_nonneg l) true
  , checkCase "lim_neg" (do let l ← ParseLimits.new (mkI32 (-1)) (mkI32 1) (mkI32 1) (mkI32 1); parse_limits_all_nonneg l) false
  , checkCase "ws_sp" (csp_is_ws (mkI32 32)) true
  , checkCase "ws_ff" (csp_is_ws (mkI32 12)) true
  , checkCase "ws_lf" (csp_is_ws (mkI32 10)) false
  , checkCase "alpha_A" (csp_is_alpha (mkI32 65)) true
  , checkCase "alpha_z" (csp_is_alpha (mkI32 122)) true
  , checkCase "alpha_5" (csp_is_alpha (mkI32 53)) false
  , checkCase "digit_0" (csp_is_digit (mkI32 48)) true
  , checkCase "digit_9" (csp_is_digit (mkI32 57)) true
  , checkCase "digit_a" (csp_is_digit (mkI32 97)) false
  , checkCase "ill_nul" (csp_is_illegal_header_byte (mkI32 0)) true
  , checkCase "ill_lf" (csp_is_illegal_header_byte (mkI32 10)) true
  , checkCase "ill_cr" (csp_is_illegal_header_byte (mkI32 13)) true
  , checkCase "ill_del" (csp_is_illegal_header_byte (mkI32 127)) true
  , checkCase "ill_tab" (csp_is_illegal_header_byte (mkI32 9)) false
  , checkCase "ill_a" (csp_is_illegal_header_byte (mkI32 97)) false
  , checkCase "ill_utf8" (csp_is_illegal_header_byte (mkI32 200)) false
  , checkCase "ser_a" (csp_is_safe_serialized_byte (mkI32 97)) true
  , checkCase "ser_semi" (csp_is_safe_serialized_byte (mkI32 59)) false
  , checkCase "ser_comma" (csp_is_safe_serialized_byte (mkI32 44)) false
  , checkCase "ser_sp" (csp_is_safe_serialized_byte (mkI32 32)) false
  , checkCase "dir_dash" (csp_is_safe_directive_byte (mkI32 45)) true
  , checkCase "dir_semi" (csp_is_safe_directive_byte (mkI32 59)) false
  , checkCase "port_ok" (csp_port_step (mkI32 80) (mkI32 48)) (mkI32 800)
  , checkCase "port_max" (csp_port_step (mkI32 6553) (mkI32 53)) (mkI32 65535)
  , checkCase "port_ovf" (csp_port_step (mkI32 6553) (mkI32 54)) (mkI32 (-1))
  , checkCase "port_bad" (csp_port_step (mkI32 80) (mkI32 97)) (mkI32 (-1))
  , checkCase "pm_eq" (csp_explicit_port_matches (mkI32 8443) (mkI32 8443) false) true
  , checkCase "pm_upg" (csp_explicit_port_matches (mkI32 80) (mkI32 443) true) true
  , checkCase "pm_noupg" (csp_explicit_port_matches (mkI32 80) (mkI32 443) false) false
  , checkCase "pm_nodown" (csp_explicit_port_matches (mkI32 443) (mkI32 80) true) false
  , checkCase "inc_inc" (cors_is_include CredentialsMode.Include) true
  , checkCase "inc_omit" (cors_is_include CredentialsMode.Omit) false
  , checkCase "age_neg" (cors_clamp_max_age (mkI32 (-5))) (mkI32 0)
  , checkCase "age_mid" (cors_clamp_max_age (mkI32 600)) (mkI32 600)
  , checkCase "age_cap" (cors_clamp_max_age (mkI32 999999)) (mkI32 86400)
  , checkCase "cws_cr" (cors_is_http_ws (mkI32 13)) true
  , checkCase "cws_ff" (cors_is_http_ws (mkI32 12)) false
  , checkCase "cuns_q" (cors_is_unsafe_request_header_byte (mkI32 34)) true
  , checkCase "cuns_tab" (cors_is_unsafe_request_header_byte (mkI32 9)) false
  , checkCase "clang_en" (cors_is_language_byte (mkI32 45)) true
  , checkCase "clang_col" (cors_is_language_byte (mkI32 58)) false
  ]

#eval IO.println (String.intercalate "\n" runAll)

end CspEvalDiff
