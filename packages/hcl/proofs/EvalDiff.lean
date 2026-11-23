import Aeneas
import PionLean
import Hcl.Types
import Hcl.Funs

open Aeneas Aeneas.Std Result Pion hcl

namespace HclEvalDiff

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

def runAll : List String :=
  [ s!"dep_min={fmtI32 (hcl_effective_max_depth (mkI32 (-2147483648)))}"
  , s!"dep_neg={fmtI32 (hcl_effective_max_depth (mkI32 (-5)))}"
  , s!"dep_0={fmtI32 (hcl_effective_max_depth (mkI32 0))}"
  , s!"dep_1={fmtI32 (hcl_effective_max_depth (mkI32 1))}"
  , s!"dep_128={fmtI32 (hcl_effective_max_depth (mkI32 128))}"
  , s!"dep_160={fmtI32 (hcl_effective_max_depth (mkI32 160))}"
  , s!"dep_max={fmtI32 (hcl_effective_max_depth (mkI32 2147483647))}"
  , s!"ids_A={fmtBool (is_hcl_ident_start (mkI32 65))}"
  , s!"ids_us={fmtBool (is_hcl_ident_start (mkI32 95))}"
  , s!"ids_utf8={fmtBool (is_hcl_ident_start (mkI32 200))}"
  , s!"ids_5={fmtBool (is_hcl_ident_start (mkI32 53))}"
  , s!"idc_5={fmtBool (is_hcl_ident_cont (mkI32 53))}"
  , s!"idc_dash={fmtBool (is_hcl_ident_cont (mkI32 45))}"
  , s!"idc_sp={fmtBool (is_hcl_ident_cont (mkI32 32))}"
  , s!"dig_0={fmtBool (is_hcl_digit (mkI32 48))}"
  , s!"dig_9={fmtBool (is_hcl_digit (mkI32 57))}"
  , s!"dig_a={fmtBool (is_hcl_digit (mkI32 97))}"
  , s!"hex_0={fmtI32 (hcl_hex_val (mkI32 48))}"
  , s!"hex_A={fmtI32 (hcl_hex_val (mkI32 65))}"
  , s!"hex_f={fmtI32 (hcl_hex_val (mkI32 102))}"
  , s!"hex_bad={fmtI32 (hcl_hex_val (mkI32 120))}"
  , s!"usp_sp={fmtBool (is_unicode_space (mkI32 32))}"
  , s!"usp_tab={fmtBool (is_unicode_space (mkI32 9))}"
  , s!"usp_nbsp={fmtBool (is_unicode_space (mkI32 160))}"
  , s!"usp_em={fmtBool (is_unicode_space (mkI32 8195))}"
  , s!"usp_ideog={fmtBool (is_unicode_space (mkI32 12288))}"
  , s!"usp_A={fmtBool (is_unicode_space (mkI32 65))}"
  , s!"lo_A={fmtI32 (unicode_cp_to_lower (mkI32 65))}"
  , s!"lo_lat1={fmtI32 (unicode_cp_to_lower (mkI32 192))}"
  , s!"lo_Idot={fmtI32 (unicode_cp_to_lower (mkI32 304))}"
  , s!"lo_greek={fmtI32 (unicode_cp_to_lower (mkI32 913))}"
  , s!"lo_cyril={fmtI32 (unicode_cp_to_lower (mkI32 1040))}"
  , s!"lo_fw={fmtI32 (unicode_cp_to_lower (mkI32 65313))}"
  , s!"up_a={fmtI32 (unicode_cp_to_upper (mkI32 97))}"
  , s!"up_lat1={fmtI32 (unicode_cp_to_upper (mkI32 224))}"
  , s!"up_ydier={fmtI32 (unicode_cp_to_upper (mkI32 255))}"
  , s!"up_fsig={fmtI32 (unicode_cp_to_upper (mkI32 962))}"
  , s!"up_fw={fmtI32 (unicode_cp_to_upper (mkI32 65345))}"
  ]

#eval IO.println (String.intercalate "\n" runAll)

end HclEvalDiff
