import Aeneas
import PionLean
import Jsonpath.Types
import Jsonpath.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion jsonpath

def checkBool (lbl : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def checkI32 (lbl : String) (r : Result Std.I32) (expected : Std.I32) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def checkI64 (lbl : String) (r : Result Std.I64) (expected : Std.I64) : String :=
  if r.reducesTo expected then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def runAll : List String := [
  -- JsonPathLimits (2)
  checkI32 "lim_depth" (do let l ← JsonPathLimits.default; ok l.max_depth) 128#i32,
  checkI32 "lim_nodes" (do let l ← JsonPathLimits.default; ok l.max_nodes_visited) 1000000#i32,
  -- is_rfc9535_ws (5)
  checkBool "ws_sp" (is_rfc9535_ws 32#i32) true,
  checkBool "ws_tab" (is_rfc9535_ws 9#i32) true,
  checkBool "ws_lf" (is_rfc9535_ws 10#i32) true,
  checkBool "ws_cr" (is_rfc9535_ws 13#i32) true,
  checkBool "ws_vt" (is_rfc9535_ws 11#i32) false,
  -- is_name_first / is_name_char (7)
  checkBool "nf_A" (is_name_first 65#i32) true,
  checkBool "nf_us" (is_name_first 95#i32) true,
  checkBool "nf_utf8" (is_name_first 0x4E2D#i32) true,
  checkBool "nf_surr" (is_name_first 0xD800#i32) false,
  checkBool "nf_hi" (is_name_first 0x110000#i32) false,
  checkBool "nf_0" (is_name_first 48#i32) false,
  checkBool "nc_0" (is_name_char 48#i32) true,
  -- rfc9535_ijson_step_overflow (4)
  checkBool "ij_ok" (rfc9535_ijson_step_overflow 900719925474099#i64 1#i64) false,
  checkBool "ij_ovf" (rfc9535_ijson_step_overflow 900719925474099#i64 2#i64) true,
  checkBool "ij_0" (rfc9535_ijson_step_overflow 0#i64 9#i64) false,
  checkBool "ij_big" (rfc9535_ijson_step_overflow 900719925474100#i64 0#i64) true,
  -- norm_name_byte_len (4)
  checkI32 "nbl_a" (norm_name_byte_len 97#i32) 1#i32,
  checkI32 "nbl_sq" (norm_name_byte_len 39#i32) 2#i32,
  checkI32 "nbl_lf" (norm_name_byte_len 10#i32) 2#i32,
  checkI32 "nbl_nul" (norm_name_byte_len 0#i32) 6#i32,
  -- pointer escape / unescape (6)
  checkBool "pe_tilde" (pointer_needs_escape 126#i32) true,
  checkBool "pe_slash" (pointer_needs_escape 47#i32) true,
  checkBool "pe_a" (pointer_needs_escape 97#i32) false,
  checkI32 "pu_0" (pointer_unescape_tilde 48#i32) 126#i32,
  checkI32 "pu_1" (pointer_unescape_tilde 49#i32) 47#i32,
  checkI32 "pu_2" (pointer_unescape_tilde 50#i32) (-1)#i32,
  -- rfc9535_normalize_index (4)
  checkI64 "ni_pos" (rfc9535_normalize_index 3#i64 10#i64) 3#i64,
  checkI64 "ni_neg" (rfc9535_normalize_index (-2)#i64 10#i64) 8#i64,
  checkI64 "ni_under" (rfc9535_normalize_index (-15)#i64 10#i64) (-5)#i64,
  checkI64 "ni_zero" (rfc9535_normalize_index 0#i64 5#i64) 0#i64,
  -- rfc9535_default_slice_start / end (4)
  checkI64 "ds_pos" (rfc9535_default_slice_start 10#i64 1#i64) 0#i64,
  checkI64 "ds_neg" (rfc9535_default_slice_start 10#i64 (-1)#i64) 9#i64,
  checkI64 "de_pos" (rfc9535_default_slice_end 10#i64 1#i64) 10#i64,
  checkI64 "de_neg" (rfc9535_default_slice_end 10#i64 (-1)#i64) (-11)#i64,
  -- rfc9535_clamp_pos_slice / neg_slice (8)
  checkI64 "cp_lo" (rfc9535_clamp_pos_slice (-5)#i64 10#i64) 0#i64,
  checkI64 "cp_mid" (rfc9535_clamp_pos_slice 4#i64 10#i64) 4#i64,
  checkI64 "cp_hi" (rfc9535_clamp_pos_slice 20#i64 10#i64) 10#i64,
  checkI64 "cp_emp" (rfc9535_clamp_pos_slice 5#i64 0#i64) 0#i64,
  checkI64 "cn_lo" (rfc9535_clamp_neg_slice (-5)#i64 10#i64) (-1)#i64,
  checkI64 "cn_mid" (rfc9535_clamp_neg_slice 4#i64 10#i64) 4#i64,
  checkI64 "cn_hi" (rfc9535_clamp_neg_slice 20#i64 10#i64) 9#i64,
  checkI64 "cn_emp" (rfc9535_clamp_neg_slice 5#i64 0#i64) (-1)#i64
]

#eval IO.println (String.intercalate "\n" runAll)
