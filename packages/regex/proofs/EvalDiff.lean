import Regex.Types
import Regex.Funs

open Aeneas Aeneas.Std Result Pion regex

namespace RegexEvalDiff

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

private def showBool (label : String) (r : Result Bool) : String :=
  match r.match with
  | .ok b => s!"{label}={if b then "true" else "false"}"
  | _ => s!"{label}=TRAP"

private def showCR (label : String) (r : Result CharRange) : String :=
  match r.match with
  | .ok cr => s!"{label}={cr.lo.val},{cr.hi.val}"
  | _ => s!"{label}=TRAP"

private def showLK (label : String) (r : Result LookKind) : String :=
  match r.match with
  | .ok .StartText => s!"{label}=StartText"
  | .ok .EndText => s!"{label}=EndText"
  | .ok .StartLine => s!"{label}=StartLine"
  | .ok .EndLine => s!"{label}=EndLine"
  | .ok .WordBoundaryAscii => s!"{label}=WordBoundaryAscii"
  | .ok .NotWordBoundaryAscii => s!"{label}=NotWordBoundaryAscii"
  | .ok .WordBoundaryUnicode => s!"{label}=WordBoundaryUnicode"
  | .ok .NotWordBoundaryUnicode => s!"{label}=NotWordBoundaryUnicode"
  | _ => s!"{label}=TRAP"

def runAll : List String :=
  let r1 : CharRange := ⟨10#i32, 30#i32⟩
  let r2 : CharRange := ⟨20#i32, 40#i32⟩
  let r3 : CharRange := ⟨31#i32, 50#i32⟩
  let r4 : CharRange := ⟨32#i32, 50#i32⟩
  let rmin : CharRange := ⟨i32 (-2147483648), i32 2147483647⟩
  [ showI64 "op_add0" (onepass_mask_add_slot 0#i64 0#i32 4#i32)
  , showI64 "op_add62" (onepass_mask_add_slot 0#i64 62#i32 63#i32)
  , showI64 "op_oob63" (onepass_mask_add_slot 5#i64 63#i32 64#i32)
  , showI64 "op_neg" (onepass_mask_add_slot 5#i64 (i32 (-1)) 4#i32)
  , showBool "op_can_ok" (onepass_can_compile false 31#i32 512#i32)
  , showBool "op_can_32" (onepass_can_compile false 32#i32 10#i32)
  , showBool "op_can_look" (onepass_can_compile true 4#i32 10#i32)
  , showBool "cap_ok" (captures_slot_valid 0#i32 2#i32)
  , showBool "cap_edge" (captures_slot_valid 1#i32 3#i32)
  , showBool "cap_neg" (captures_slot_valid (i32 (-1)) 10#i32)
  , showBool "cap_min" (captures_slot_valid 0#i32 (i32 (-2147483648)))
  , showBool "cap_max" (captures_slot_valid (i32 1073741822) (i32 2147483647))
  , showBool "cr_le_lt" (char_range_le r1 r2)
  , showBool "cr_le_gt" (char_range_le r2 r1)
  , showBool "cr_le_min" (char_range_le rmin r1)
  , showCR "cr_int_ov" (char_range_intersect r1 r2)
  , showCR "cr_int_min" (char_range_intersect rmin r1)
  , showBool "cr_mrg_adj" (char_range_can_merge r1 r3)
  , showBool "cr_mrg_gap" (char_range_can_merge r1 r4)
  , showBool "cr_mrg_max" (char_range_can_merge rmin r1)
  , showCR "cr_mrg_val" (char_range_merge r1 r3)
  , showBool "pike_sl_nl" (pike_look_holds .StartLine 5#i32 10#i32 10#i32 97#i32 true false true)
  , showBool "pike_el_nl" (pike_look_holds .EndLine 5#i32 10#i32 97#i32 10#i32 true true false)
  , showBool "pike_wb_cb" (pike_look_holds .WordBoundaryAscii 5#i32 10#i32 97#i32 32#i32 true true false)
  , showBool "pike_wb_nocb" (pike_look_holds .WordBoundaryAscii 5#i32 10#i32 97#i32 32#i32 false true false)
  , showBool "dfa_el_nl" (dfa_look_holds .EndLine false false true true false false)
  , showBool "dfa_wb" (dfa_look_holds .WordBoundaryAscii false false true false false false)
  , showLK "rev_st" (reverse_look_kind .StartText)
  , showLK "rev_sl" (reverse_look_kind .StartLine)
  , showLK "rev_wb" (reverse_look_kind .WordBoundaryAscii)
  , showBool "u8_128" (is_utf8_cont_byte 128#i32)
  , showBool "u8_191" (is_utf8_cont_byte 191#i32)
  , showBool "u8_192" (is_utf8_cont_byte 192#i32)
  , showBool "u8_neg1" (is_utf8_cont_byte (i32 (-1)))
  , showI32 "hex_0" (hex_val 48#i32)
  , showI32 "hex_F" (hex_val 70#i32)
  , showI32 "hex_f" (hex_val 102#i32)
  , showI32 "hex_min" (hex_val (i32 (-2147483648)))
  , showI32 "hex_max" (hex_val (i32 2147483647))
  , showBool "ws_sp" (is_regex_ws_byte 32#i32)
  , showBool "meta_sp" (is_regex_meta_byte 32#i32)
  , showBool "meta_dot" (is_regex_meta_byte 46#i32)
  ]

#eval IO.println (String.intercalate "\n" runAll)

end RegexEvalDiff
