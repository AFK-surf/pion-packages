import Fts.Types
import Fts.Funs

open Aeneas Aeneas.Std Result Pion fts

namespace FtsEvalDiff

private def i32 (x : Int) : Std.I32 := ⟨BitVec.ofInt 32 x⟩
private def i64 (x : Int) : Std.I64 := ⟨BitVec.ofInt 64 x⟩

private def showI32 (label : String) (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

private def showBool (label : String) (r : Result Bool) : String :=
  match r.match with
  | .ok b => s!"{label}={if b then "true" else "false"}"
  | _ => s!"{label}=TRAP"

def runAll : List String :=
  [ showI32 "san_neg1" (sanitize_scalar (i32 (-1)))
  , showI32 "san_min" (sanitize_scalar (i32 (-2147483648)))
  , showI32 "san_max" (sanitize_scalar (i32 2147483647))
  , showI32 "san_sur" (sanitize_scalar 55296#i32)
  , showI32 "san_ok" (sanitize_scalar 19968#i32)
  , showI32 "len_sur" (cp_utf8_len 56000#i32)
  , showI32 "len_oob" (cp_utf8_len (i32 (-1)))
  , showI32 "len_4" (cp_utf8_len 128512#i32)
  , showI32 "fold_A" (fold_ascii_cp 65#i32)
  , showI32 "fold_min" (fold_ascii_cp (i32 (-2147483648)))
  , showI32 "cyr_1040" (fold_greek_cyrillic 1040#i32)
  , showI32 "cyr_1024" (fold_greek_cyrillic 1024#i32)
  , showI32 "grk_3A2" (fold_greek_cyrillic 930#i32)
  , showBool "cjk_han" (is_cjk_cp 19968#i32)
  , showBool "cjk_rt2" (is_cjk_cp 12441#i32)
  , showBool "cjk_A" (is_cjk_cp 65#i32)
  , showI32 "nws_nl" (snippet_normalize_ws 10#i32)
  , showI32 "nws_A" (snippet_normalize_ws 65#i32)
  , showI32 "ctx_120" (snippet_context_before 120#i32)
  , showI32 "ctx_20" (snippet_context_before 20#i32)
  , showI32 "ctx_0_oob" (snippet_context_before 0#i32)
  , showI32 "ctx_min_oob" (snippet_context_before (i32 (-2147483648)))
  , showI32 "we_rt3_max" (snippet_win_end 50#i32 100#i32 (i32 2147483647))
  , showI32 "we_all_max" (snippet_win_end (i32 2147483647) (i32 2147483647) (i32 2147483647))
  , showI32 "we_ok" (snippet_win_end 10#i32 100#i32 25#i32)
  , showBool "rg_gt" (snippet_range_gt 5#i32 10#i32 3#i32 10#i32)
  , showBool "rg_eq" (snippet_range_gt 5#i32 10#i32 5#i32 10#i32)
  , showI32 "hc_gt" (hit_tiebreak_cmp (i64 9223372036854775807) 1#i64 (i64 (-9223372036854775808)) 2#i64)
  , showI32 "hc_tie" (hit_tiebreak_cmp 100#i64 1#i64 100#i64 2#i64)
  , showI32 "hc_eq" (hit_tiebreak_cmp 100#i64 5#i64 100#i64 5#i64)
  ]

#eval IO.println (String.intercalate "\n" runAll)

end FtsEvalDiff
