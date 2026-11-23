import Aeneas
import PionLean
import Regex.Types
import Regex.Funs

open Aeneas Aeneas.Std Result
open regex

def cb (lbl : String) (r : Result Bool) (exp : Bool) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def ci (lbl : String) (r : Result Std.I32) (exp : Std.I32) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def ci64 (lbl : String) (r : Result Std.I64) (exp : Std.I64) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def clk (lbl : String) (r : Result LookKind) (exp : LookKind) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def crInter (lbl : String) (a b : CharRange) (elo ehi : Std.I32) : String :=
  let okLo := (do let r ← char_range_intersect a b; ok r.lo).reducesTo elo
  let okHi := (do let r ← char_range_intersect a b; ok r.hi).reducesTo ehi
  if okLo && okHi then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def runAll : List String := [
  cb "lm_lf" (dfa_is_leftmost .LeftmostFirst) true,
  cb "lm_rev" (dfa_is_leftmost .Reverse) false,
  cb "lm_set" (dfa_is_leftmost .SetAll) false,
  cb "sa_set" (dfa_is_set_all .SetAll) true,
  cb "sa_lf" (dfa_is_set_all .LeftmostFirst) false,
  cb "lk_st" (dfa_look_holds .StartText true false false false false false) true,
  cb "lk_sl" (dfa_look_holds .StartLine false true false false false false) true,
  cb "lk_et" (dfa_look_holds .EndText false false false false false true) true,
  cb "lk_el_nl" (dfa_look_holds .EndLine false false false true false false) true,
  cb "lk_el_no" (dfa_look_holds .EndLine false false false false false false) false,
  cb "lk_wb_t" (dfa_look_holds .WordBoundaryAscii false false true false false false) true,
  cb "lk_wb_f" (dfa_look_holds .WordBoundaryAscii false false true false true false) false,
  cb "lk_nwb_t" (dfa_look_holds .NotWordBoundaryUnicode false false false false false false) true,
  clk "rev_st" (reverse_look_kind .StartText) .EndText,
  clk "rev_et" (reverse_look_kind .EndText) .StartText,
  clk "rev_sl" (reverse_look_kind .StartLine) .EndLine,
  clk "rev_el" (reverse_look_kind .EndLine) .StartLine,
  clk "rev_wb" (reverse_look_kind .WordBoundaryUnicode) .WordBoundaryUnicode,
  cb "iswb_a" (look_is_word_boundary .WordBoundaryAscii) true,
  cb "iswb_na" (look_is_word_boundary .NotWordBoundaryAscii) true,
  cb "iswb_st" (look_is_word_boundary .StartText) false,
  cb "op_ok" (onepass_can_compile false 31#i32 512#i32) true,
  cb "op_look" (onepass_can_compile true 2#i32 10#i32) false,
  cb "op_cap0" (onepass_can_compile false 0#i32 10#i32) false,
  cb "op_cap32" (onepass_can_compile false 32#i32 10#i32) false,
  cb "op_nfa" (onepass_can_compile false 2#i32 513#i32) false,
  ci64 "opm_set0" (onepass_mask_add_slot 0#i64 0#i32 4#i32) 1#i64,
  ci64 "opm_set3" (onepass_mask_add_slot 1#i64 3#i32 4#i32) 9#i64,
  ci64 "opm_oob" (onepass_mask_add_slot 5#i64 4#i32 4#i32) 5#i64,
  ci64 "opm_neg" (onepass_mask_add_slot 5#i64 (-1)#i32 4#i32) 5#i64,
  cb "cap_ok" (captures_slot_valid 0#i32 2#i32) true,
  cb "cap_hi" (captures_slot_valid 1#i32 2#i32) false,
  cb "cap_odd" (captures_slot_valid 1#i32 3#i32) false,
  cb "cap_neg" (captures_slot_valid (-1)#i32 6#i32) false,
  cb "cr_le1" (char_range_le ⟨10#i32, 20#i32⟩ ⟨10#i32, 25#i32⟩) true,
  cb "cr_le2" (char_range_le ⟨11#i32, 12#i32⟩ ⟨10#i32, 99#i32⟩) false,
  crInter "cr_int1" ⟨10#i32, 30#i32⟩ ⟨20#i32, 40#i32⟩ 20#i32 30#i32,
  crInter "cr_int2" ⟨10#i32, 15#i32⟩ ⟨20#i32, 40#i32⟩ 20#i32 15#i32,
  cb "u8c_80" (is_utf8_cont_byte 128#i32) true,
  cb "u8c_bf" (is_utf8_cont_byte 191#i32) true,
  cb "u8c_c0" (is_utf8_cont_byte 192#i32) false,
  ci "u8l_1" (utf8_lead_len 65#i32) 1#i32,
  ci "u8l_4" (utf8_lead_len 240#i32) 4#i32,
  ci "hx_f" (hex_val 102#i32) 15#i32
]

#eval IO.println (String.intercalate "\n" runAll)
