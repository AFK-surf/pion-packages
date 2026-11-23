import Crdt.Types
import Crdt.Funs

open Aeneas Aeneas.Std Result Pion crdt

namespace CrdtEvalDiff

def fmtU64 (r : Result Std.U64) : String :=
  match r.match with
  | .ok v => toString v.val
  | _ => "TRAP"

def fmtI32 (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => toString v.val
  | _ => "TRAP"

def fmtBool (r : Result Bool) : String :=
  match r.match with
  | .ok true => "true"
  | .ok false => "false"
  | _ => "TRAP"

def fmtId (r : Result Id) : String :=
  match r.match with
  | .ok x => s!"({x.client.val},{x.clock.val})"
  | _ => "TRAP"

def fmtDI (r : Result DeleteItem) : String :=
  match r.match with
  | .ok x => s!"({x.clock.val},{x.len.val})"
  | _ => "TRAP"

def u64Max : Std.U64 := 18446744073709551615#u64
def u64MaxM2 : Std.U64 := 18446744073709551614#u64
def u64MaxM5 : Std.U64 := 18446744073709551610#u64

#eval show IO Unit from do
  -- u64_sat_add boundaries (including UInt64::MAX wraparound)
  IO.println s!"sat_0_0={fmtU64 (u64_sat_add 0#u64 0#u64)}"
  IO.println s!"sat_max_0={fmtU64 (u64_sat_add u64Max 0#u64)}"
  IO.println s!"sat_max_1={fmtU64 (u64_sat_add u64Max 1#u64)}"
  IO.println s!"sat_max_max={fmtU64 (u64_sat_add u64Max u64Max)}"
  IO.println s!"sat_m2_4={fmtU64 (u64_sat_add u64MaxM2 4#u64)}"
  -- item_last_id boundaries (len=0, len=1, wraparound)
  IO.println s!"last_len0={fmtId (item_last_id (Id.mk 7#u64 10#u64) 0#u64)}"
  IO.println s!"last_len1={fmtId (item_last_id (Id.mk 7#u64 10#u64) 1#u64)}"
  IO.println s!"last_wrap={fmtId (item_last_id (Id.mk 7#u64 u64MaxM2) 10#u64)}"
  -- delete_item_contains (including wrapping ranges that previously wrapped to 0)
  IO.println s!"cnt_empty={fmtBool (delete_item_contains (DeleteItem.mk 10#u64 0#u64) 10#u64)}"
  IO.println s!"cnt_wrap_in={fmtBool (delete_item_contains (DeleteItem.mk u64MaxM2 4#u64) u64Max)}"
  IO.println s!"cnt_wrap_below={fmtBool (delete_item_contains (DeleteItem.mk u64MaxM2 4#u64) 0#u64)}"
  IO.println s!"cnt_wrap_c12={fmtBool (delete_item_contains (DeleteItem.mk 12#u64 u64MaxM5) u64Max)}"
  -- delete_item_can_merge & delete_item_merge (wrapping + unsorted + commutative)
  IO.println s!"canm_wrap_t={fmtBool (delete_item_can_merge (DeleteItem.mk u64MaxM5 10#u64) (DeleteItem.mk u64Max 5#u64))}"
  IO.println s!"canm_wrap_f={fmtBool (delete_item_can_merge (DeleteItem.mk u64MaxM2 4#u64) (DeleteItem.mk 1#u64 2#u64))}"
  IO.println s!"merge_wrap={fmtDI (delete_item_merge (DeleteItem.mk u64MaxM5 10#u64) (DeleteItem.mk u64Max 5#u64))}"
  IO.println s!"merge_unsorted={fmtDI (delete_item_merge (DeleteItem.mk 20#u64 5#u64) (DeleteItem.mk 10#u64 12#u64))}"
  IO.println s!"merge_max_span={fmtDI (delete_item_merge (DeleteItem.mk 10#u64 5#u64) (DeleteItem.mk 12#u64 u64MaxM5))}"
  -- opt_id_eq, encode_item_info, hex nibbles
  IO.println s!"opt_eq_nn={fmtBool (opt_id_eq none none)}"
  IO.println s!"opt_eq_ss={fmtBool (opt_id_eq (some (Id.mk 1#u64 2#u64)) (some (Id.mk 1#u64 2#u64)))}"
  IO.println s!"opt_eq_sn={fmtBool (opt_id_eq (some (Id.mk 1#u64 2#u64)) none)}"
  IO.println s!"info_enc={fmtI32 (encode_item_info 7#i32 true false true)}"
  IO.println s!"info_ref={fmtI32 (info_ref_id 167#i32)}"
  IO.println s!"hex_c15={fmtI32 (hex_nibble_char 15#i32)}"
  IO.println s!"hex_pF={fmtI32 (parse_hex_nibble 70#i32)}"
  IO.println s!"hex_pmin={fmtI32 (parse_hex_nibble (-2147483648)#i32)}"
  IO.println s!"hex_pmax={fmtI32 (parse_hex_nibble 2147483647#i32)}"

end CrdtEvalDiff
