import Aeneas
import PionLean
import Hcl.Types
import Hcl.Funs

open Aeneas Aeneas.Std Result Pion hcl

namespace HclEvalDiff

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def mkI64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩

private def checkCase [BEq α] (label : String) (r : Result α) (expected : α) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

def runAll : List String :=
  [ checkCase "dep_neg" (hcl_effective_max_depth (mkI32 (-5))) (mkI32 1)
  , checkCase "dep_0" (hcl_effective_max_depth (mkI32 0)) (mkI32 1)
  , checkCase "dep_1" (hcl_effective_max_depth (mkI32 1)) (mkI32 1)
  , checkCase "dep_128" (hcl_effective_max_depth (mkI32 128)) (mkI32 128)
  , checkCase "dep_160" (hcl_effective_max_depth (mkI32 160)) (mkI32 160)
  , checkCase "dep_999" (hcl_effective_max_depth (mkI32 999)) (mkI32 160)
  , checkCase "lim_def_d" (do let l ← HclLimits.default; ok l.max_depth) (mkI32 128)
  , checkCase "lim_def_s" (do let l ← HclLimits.default; ok l.max_steps) (mkI64 1000000)
  , checkCase "lim_new_o" (do let l ← HclLimits.new (mkI32 32) (mkI64 500) (mkI32 4096); ok l.max_output_bytes) (mkI32 4096)
  , checkCase "pos_z_l" (do let p ← Pos.zero; ok p.line) (mkI32 1)
  , checkCase "span_z_c" (do let s ← Span.zero; ok s.«end».column) (mkI32 1)
  , checkCase "pos_new_o" (do let p ← Pos.new (mkI32 3) (mkI32 7) (mkI32 42); ok p.offset) (mkI32 42)
  , checkCase "span_new_l" (do let p1 ← Pos.new (mkI32 1) (mkI32 1) (mkI32 0); let p2 ← Pos.new (mkI32 2) (mkI32 5) (mkI32 20); let sp ← Span.new p1 p2; ok sp.«end».line) (mkI32 2)
  , checkCase "ids_A" (is_hcl_ident_start (mkI32 65)) true
  , checkCase "ids_us" (is_hcl_ident_start (mkI32 95)) true
  , checkCase "ids_utf8" (is_hcl_ident_start (mkI32 200)) true
  , checkCase "ids_5" (is_hcl_ident_start (mkI32 53)) false
  , checkCase "idc_5" (is_hcl_ident_cont (mkI32 53)) true
  , checkCase "idc_dash" (is_hcl_ident_cont (mkI32 45)) true
  , checkCase "idc_sp" (is_hcl_ident_cont (mkI32 32)) false
  , checkCase "dig_0" (is_hcl_digit (mkI32 48)) true
  , checkCase "dig_9" (is_hcl_digit (mkI32 57)) true
  , checkCase "dig_a" (is_hcl_digit (mkI32 97)) false
  , checkCase "hex_0" (hcl_hex_val (mkI32 48)) (mkI32 0)
  , checkCase "hex_A" (hcl_hex_val (mkI32 65)) (mkI32 10)
  , checkCase "hex_f" (hcl_hex_val (mkI32 102)) (mkI32 15)
  , checkCase "hex_bad" (hcl_hex_val (mkI32 120)) (mkI32 (-1))
  , checkCase "usp_sp" (is_unicode_space (mkI32 32)) true
  , checkCase "usp_tab" (is_unicode_space (mkI32 9)) true
  , checkCase "usp_nbsp" (is_unicode_space (mkI32 160)) true
  , checkCase "usp_em" (is_unicode_space (mkI32 8195)) true
  , checkCase "usp_ideog" (is_unicode_space (mkI32 12288)) true
  , checkCase "usp_A" (is_unicode_space (mkI32 65)) false
  , checkCase "lo_A" (unicode_cp_to_lower (mkI32 65)) (mkI32 97)
  , checkCase "lo_lat1" (unicode_cp_to_lower (mkI32 192)) (mkI32 224)
  , checkCase "lo_Idot" (unicode_cp_to_lower (mkI32 304)) (mkI32 105)
  , checkCase "lo_greek" (unicode_cp_to_lower (mkI32 913)) (mkI32 945)
  , checkCase "lo_cyril" (unicode_cp_to_lower (mkI32 1040)) (mkI32 1072)
  , checkCase "lo_fw" (unicode_cp_to_lower (mkI32 65313)) (mkI32 65345)
  , checkCase "up_a" (unicode_cp_to_upper (mkI32 97)) (mkI32 65)
  , checkCase "up_lat1" (unicode_cp_to_upper (mkI32 224)) (mkI32 192)
  , checkCase "up_ydier" (unicode_cp_to_upper (mkI32 255)) (mkI32 376)
  , checkCase "up_fsig" (unicode_cp_to_upper (mkI32 962)) (mkI32 931)
  , checkCase "up_fw" (unicode_cp_to_upper (mkI32 65345)) (mkI32 65313)
  ]

#eval IO.println (String.intercalate "\n" runAll)

end HclEvalDiff
