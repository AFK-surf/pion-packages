import Aeneas
import PionLean
import Fts.Types
import Fts.Funs

open Aeneas Aeneas.Std Result
open fts

def cb (lbl : String) (r : Result Bool) (exp : Bool) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def ci (lbl : String) (r : Result Std.I32) (exp : Std.I32) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def runAll : List String := [
  ci "san_neg" (sanitize_scalar (-5)#i32) 65533#i32,
  ci "san_sur" (sanitize_scalar 55296#i32) 65533#i32,
  ci "san_hi" (sanitize_scalar 1114112#i32) 65533#i32,
  ci "san_ok" (sanitize_scalar 20013#i32) 20013#i32,
  ci "u8l_1" (cp_utf8_len 65#i32) 1#i32,
  ci "u8l_2" (cp_utf8_len 233#i32) 2#i32,
  ci "u8l_3" (cp_utf8_len 20013#i32) 3#i32,
  ci "u8l_4" (cp_utf8_len 128512#i32) 4#i32,
  ci "u8l_sur" (cp_utf8_len 56000#i32) 3#i32,
  ci "fa_A" (fold_ascii_cp 65#i32) 97#i32,
  ci "fa_a" (fold_ascii_cp 97#i32) 97#i32,
  ci "fg_sig" (fold_greek_cyrillic 962#i32) 963#i32,
  ci "fg_3a2" (fold_greek_cyrillic 930#i32) (-1)#i32,
  ci "fg_cyrA" (fold_greek_cyrillic 1040#i32) 1072#i32,
  ci "fg_cyr0" (fold_greek_cyrillic 1024#i32) 1104#i32,
  ci "fg_bad" (fold_greek_cyrillic 65#i32) (-1)#i32,
  cb "cjk_han" (is_cjk_cp 20013#i32) true,
  cb "cjk_rt2a" (is_cjk_cp 12441#i32) false,
  cb "cjk_rt2b" (is_cjk_cp 12448#i32) false,
  cb "cjk_rt2c" (is_cjk_cp 12539#i32) false,
  cb "cjk_asc" (is_cjk_cp 65#i32) false,
  cb "aw_u" (is_ascii_word_cp 95#i32) true,
  cb "aw_sp" (is_ascii_word_cp 32#i32) false,
  cb "up_Z" (is_upper_cp 90#i32) true,
  cb "lo_a" (is_lower_cp 97#i32) true,
  cb "dg_5" (is_digit_cp 53#i32) true,
  cb "cam_aB" (camel_should_split 97#i32 66#i32 false) true,
  cb "cam_ABc" (camel_should_split 65#i32 66#i32 true) true,
  cb "cam_ABC" (camel_should_split 65#i32 66#i32 false) false,
  cb "cam_ab" (camel_should_split 97#i32 98#i32 false) false,
  ci "nws_nl" (snippet_normalize_ws 10#i32) 32#i32,
  ci "nws_tb" (snippet_normalize_ws 9#i32) 32#i32,
  ci "nws_A" (snippet_normalize_ws 65#i32) 65#i32,
  ci "ctx_120" (snippet_context_before 120#i32) 16#i32,
  ci "ctx_20" (snippet_context_before 20#i32) 5#i32,
  ci "we_ok" (snippet_win_end 10#i32 100#i32 20#i32) 30#i32,
  ci "we_rt3" (snippet_win_end 10#i32 100#i32 2147483647#i32) 100#i32,
  cb "rg_gt" (snippet_range_gt 5#i32 8#i32 5#i32 6#i32) true,
  cb "rg_eq" (snippet_range_gt 5#i32 8#i32 5#i32 8#i32) false,
  ci "hc_ok_gt" (hit_tiebreak_cmp 20#i64 5#i64 10#i64 1#i64) (-1)#i32,
  ci "hc_ok_lt" (hit_tiebreak_cmp 10#i64 1#i64 20#i64 5#i64) 1#i32,
  ci "hc_id_lt" (hit_tiebreak_cmp 10#i64 1#i64 10#i64 2#i64) (-1)#i32,
  ci "hc_id_gt" (hit_tiebreak_cmp 10#i64 2#i64 10#i64 1#i64) 1#i32,
  ci "hc_eq" (hit_tiebreak_cmp 10#i64 2#i64 10#i64 2#i64) 0#i32
]

#eval IO.println (String.intercalate "\n" runAll)
