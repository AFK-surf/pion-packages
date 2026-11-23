import Aeneas
import PionLean
import Wasm.Types
import Wasm.Funs

open Aeneas Aeneas.Std Result Pion wasm

private def checkBool (label : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkI32 (label : String) (r : Result I32) (expected : I32) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkOptVT (label : String) (r : Result (Option ValType)) (expected : Option ValType) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkOptRT (label : String) (r : Result (Option RefType)) (expected : Option RefType) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def runAll : List String := [
  checkI32 "vt_i32" (val_type_code .I32) 127#i32,
  checkI32 "vt_v128" (val_type_code .V128) 123#i32,
  checkI32 "vt_ext" (val_type_code .ExternRef) 111#i32,
  checkOptVT "vtf_i32" (val_type_from_code 127#i32) (some .I32),
  checkOptVT "vtf_bad" (val_type_from_code 0#i32) none,
  checkBool "vteq_t" (val_type_equals .F64 .F64) true,
  checkBool "vteq_f" (val_type_equals .I32 .I64) false,
  checkI32 "rt_fn" (ref_type_code .FuncRef) 112#i32,
  checkOptRT "rtf_ext" (ref_type_from_code 111#i32) (some .ExternRef),
  checkOptRT "rtf_bad" (ref_type_from_code 127#i32) none,
  checkI32 "exp_mem" (export_kind_code .Memory) 2#i32,
  checkI32 "vid_fn" (val_type_to_id .FuncRef) 5#i32,
  checkI32 "rid_ext" (ref_type_to_id .ExternRef) 6#i32,
  checkBool "isref_5" (is_ref_id 5#i32) true,
  checkBool "isref_0" (is_ref_id 0#i32) false,
  checkI32 "sec_elem" (section_order_rank 9#i32) 9#i32,
  checkI32 "sec_dc" (section_order_rank 12#i32) 10#i32,
  checkI32 "sec_code" (section_order_rank 10#i32) 11#i32,
  checkI32 "sec_data" (section_order_rank 11#i32) 12#i32,
  checkI32 "sec_cust" (section_order_rank 0#i32) (-1)#i32,
  checkBool "stk_eq" (stack_type_compat 0#i32 0#i32) true,
  checkBool "stk_unk" (stack_type_compat (-1)#i32 3#i32) true,
  checkBool "stk_ne" (stack_type_compat 0#i32 1#i32) false,
  checkI32 "lim_ok" (limits_err_code (Limits.mk 1#i64 (some 10#i64) false false) 65536#i64) 0#i32,
  checkI32 "lim_sh" (limits_err_code (Limits.mk 1#i64 none false true) 65536#i64) 1#i32,
  checkI32 "lim_m64" (limits_err_code (Limits.mk 1#i64 none true false) 65536#i64) 2#i32,
  checkI32 "lim_neg" (limits_err_code (Limits.mk (-1)#i64 none false false) 65536#i64) 3#i32,
  checkI32 "lim_min_hi" (limits_err_code (Limits.mk 70000#i64 none false false) 65536#i64) 4#i32,
  checkI32 "lim_gt" (limits_err_code (Limits.mk 10#i64 (some 5#i64) false false) 65536#i64) 5#i32,
  checkI32 "lim_max_hi" (limits_err_code (Limits.mk 1#i64 (some 70000#i64) false false) 65536#i64) 6#i32,
  checkI32 "leb_sb_pos" (leb128_i32_single_byte 63#i32) 63#i32,
  checkI32 "leb_sb_neg" (leb128_i32_single_byte 64#i32) (-64)#i32,
  checkBool "leb_u32_ok" (leb128_u32_5th_valid 15#i32) true,
  checkBool "leb_u32_bad" (leb128_u32_5th_valid 16#i32) false,
  checkBool "leb_u64_ok" (leb128_u64_10th_valid 1#i32) true,
  checkBool "leb_u64_bad" (leb128_u64_10th_valid 2#i32) false,
  checkBool "leb_i32_pos" (leb128_i32_5th_valid 7#i32) true,
  checkBool "leb_i32_neg" (leb128_i32_5th_valid 120#i32) true,
  checkBool "leb_i32_bad" (leb128_i32_5th_valid 8#i32) false,
  checkBool "leb_i64_ok" (leb128_i64_10th_valid 127#i32) true,
  checkBool "leb_i64_bad" (leb128_i64_10th_valid 1#i32) false,
  checkBool "leb_s33_pos" (leb128_s33_5th_valid 15#i32) true,
  checkBool "leb_s33_neg" (leb128_s33_5th_valid 112#i32) true,
  checkBool "leb_s33_bad" (leb128_s33_5th_valid 16#i32) false
]

#eval IO.println (String.intercalate "\n" runAll)
