import Aeneas
import PionLean
import Csp.Types
import Csp.Funs

open Aeneas Aeneas.Std Result Pion csp

namespace CspEvalDiff

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

def runAll : List String :=
  [ s!"ws_sp={fmtBool (csp_is_ws (mkI32 32))}"
  , s!"ws_ff={fmtBool (csp_is_ws (mkI32 12))}"
  , s!"ws_lf={fmtBool (csp_is_ws (mkI32 10))}"
  , s!"alpha_A={fmtBool (csp_is_alpha (mkI32 65))}"
  , s!"alpha_z={fmtBool (csp_is_alpha (mkI32 122))}"
  , s!"alpha_5={fmtBool (csp_is_alpha (mkI32 53))}"
  , s!"digit_0={fmtBool (csp_is_digit (mkI32 48))}"
  , s!"digit_9={fmtBool (csp_is_digit (mkI32 57))}"
  , s!"digit_a={fmtBool (csp_is_digit (mkI32 97))}"
  , s!"ill_nul={fmtBool (csp_is_illegal_header_byte (mkI32 0))}"
  , s!"ill_lf={fmtBool (csp_is_illegal_header_byte (mkI32 10))}"
  , s!"ill_cr={fmtBool (csp_is_illegal_header_byte (mkI32 13))}"
  , s!"ill_del={fmtBool (csp_is_illegal_header_byte (mkI32 127))}"
  , s!"ill_tab={fmtBool (csp_is_illegal_header_byte (mkI32 9))}"
  , s!"ill_a={fmtBool (csp_is_illegal_header_byte (mkI32 97))}"
  , s!"ill_utf8={fmtBool (csp_is_illegal_header_byte (mkI32 200))}"
  , s!"ser_a={fmtBool (csp_is_safe_serialized_byte (mkI32 97))}"
  , s!"ser_semi={fmtBool (csp_is_safe_serialized_byte (mkI32 59))}"
  , s!"ser_comma={fmtBool (csp_is_safe_serialized_byte (mkI32 44))}"
  , s!"ser_sp={fmtBool (csp_is_safe_serialized_byte (mkI32 32))}"
  , s!"dir_dash={fmtBool (csp_is_safe_directive_byte (mkI32 45))}"
  , s!"dir_semi={fmtBool (csp_is_safe_directive_byte (mkI32 59))}"
  , s!"port_ok={fmtI32 (csp_port_step (mkI32 80) (mkI32 48))}"
  , s!"port_max={fmtI32 (csp_port_step (mkI32 6553) (mkI32 53))}"
  , s!"port_ovf={fmtI32 (csp_port_step (mkI32 6553) (mkI32 54))}"
  , s!"port_bad={fmtI32 (csp_port_step (mkI32 80) (mkI32 97))}"
  , s!"age_min={fmtI32 (cors_clamp_max_age (mkI32 (-2147483648)))}"
  , s!"age_neg={fmtI32 (cors_clamp_max_age (mkI32 (-5)))}"
  , s!"age_mid={fmtI32 (cors_clamp_max_age (mkI32 600))}"
  , s!"age_cap={fmtI32 (cors_clamp_max_age (mkI32 999999))}"
  , s!"age_max={fmtI32 (cors_clamp_max_age (mkI32 2147483647))}"
  , s!"cuns_q={fmtBool (cors_is_unsafe_request_header_byte (mkI32 34))}"
  , s!"cuns_tab={fmtBool (cors_is_unsafe_request_header_byte (mkI32 9))}"
  , s!"cuns_del={fmtBool (cors_is_unsafe_request_header_byte (mkI32 127))}"
  , s!"clang_en={fmtBool (cors_is_language_byte (mkI32 45))}"
  , s!"clang_col={fmtBool (cors_is_language_byte (mkI32 58))}"
  ]

#eval IO.println (String.intercalate "\n" runAll)

end CspEvalDiff
