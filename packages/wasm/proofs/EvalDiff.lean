import Aeneas
import PionLean
import Wasm.Types
import Wasm.Funs

open Aeneas Aeneas.Std Result Pion wasm

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtOptVT (r : Result (Option ValType)) : String :=
  match r.match with
  | .ok none => "None"
  | .ok (some .I32) => "Some(I32)"
  | .ok (some .I64) => "Some(I64)"
  | .ok (some .F32) => "Some(F32)"
  | .ok (some .F64) => "Some(F64)"
  | .ok (some .V128) => "Some(V128)"
  | .ok (some .FuncRef) => "Some(FuncRef)"
  | .ok (some .ExternRef) => "Some(ExternRef)"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"vt_i32={fmtI32 (val_type_code .I32)}"
  , s!"vt_ext={fmtI32 (val_type_code .ExternRef)}"
  , s!"vtf_i32={fmtOptVT (val_type_from_code 127#i32)}"
  , s!"vtf_bad={fmtOptVT (val_type_from_code 0#i32)}"
  , s!"sec_elem={fmtI32 (section_order_rank 9#i32)}"
  , s!"sec_dc={fmtI32 (section_order_rank 12#i32)}"
  , s!"sec_code={fmtI32 (section_order_rank 10#i32)}"
  , s!"sec_data={fmtI32 (section_order_rank 11#i32)}"
  , s!"sec_cust={fmtI32 (section_order_rank 0#i32)}"
  , s!"stk_eq={fmtBool (stack_type_compat 0#i32 0#i32)}"
  , s!"stk_unk={fmtBool (stack_type_compat (-1)#i32 3#i32)}"
  , s!"stk_ne={fmtBool (stack_type_compat 0#i32 1#i32)}"
  , s!"lim_ok={fmtI32 (limits_err_code (Limits.mk 1#i64 (some 10#i64) false false) 65536#i64)}"
  , s!"lim_sh={fmtI32 (limits_err_code (Limits.mk 1#i64 none false true) 65536#i64)}"
  , s!"lim_m64={fmtI32 (limits_err_code (Limits.mk 1#i64 none true false) 65536#i64)}"
  , s!"lim_neg={fmtI32 (limits_err_code (Limits.mk (-1)#i64 none false false) 65536#i64)}"
  , s!"lim_min_hi={fmtI32 (limits_err_code (Limits.mk 70000#i64 none false false) 65536#i64)}"
  , s!"lim_gt={fmtI32 (limits_err_code (Limits.mk 10#i64 (some 5#i64) false false) 65536#i64)}"
  , s!"lim_max_hi={fmtI32 (limits_err_code (Limits.mk 1#i64 (some 70000#i64) false false) 65536#i64)}"
  , s!"leb_sb_pos={fmtI32 (leb128_i32_single_byte 63#i32)}"
  , s!"leb_sb_neg={fmtI32 (leb128_i32_single_byte 64#i32)}"
  , s!"leb_u32_ok={fmtBool (leb128_u32_5th_valid 15#i32)}"
  , s!"leb_u32_bad={fmtBool (leb128_u32_5th_valid 16#i32)}"
  , s!"leb_i32_pos={fmtBool (leb128_i32_5th_valid 7#i32)}"
  , s!"leb_i32_neg={fmtBool (leb128_i32_5th_valid 120#i32)}"
  , s!"leb_i32_bad={fmtBool (leb128_i32_5th_valid 8#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
