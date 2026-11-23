import Crdt.Types
import Crdt.Funs

open Aeneas Aeneas.Std Result Pion crdt

private def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

private def report (label : String) (ok_cond : Bool) : IO Unit :=
  IO.println s!"{label}: {if ok_cond then "PASS" else "FAIL"}"

def main : IO Unit := do
  let id1 := Id.mk 1#u64 10#u64
  let id2 := Id.mk 1#u64 20#u64
  let id3 := Id.mk 2#u64 5#u64
  report "id_eq_same" (okIs (Id.eq id1 id1) true)
  report "id_eq_diff_clock" (okIs (Id.eq id1 id2) false)
  report "id_eq_diff_client" (okIs (Id.eq id1 id3) false)
  report "id_cmp_same" (okIs (Id.cmp id1 id1) 0#i32)
  report "id_cmp_clock_lt" (okIs (Id.cmp id1 id2) (-1)#i32)
  report "id_cmp_clock_gt" (okIs (Id.cmp id2 id1) 1#i32)
  report "id_cmp_client_lt" (okIs (Id.cmp id2 id3) (-1)#i32)
  report "id_cmp_client_gt" (okIs (Id.cmp id3 id1) 1#i32)
  report "opt_id_none_none" (okIs (opt_id_eq none none) true)
  report "opt_id_some_none" (okIs (opt_id_eq (some id1) none) false)
  report "opt_id_some_same" (okIs (opt_id_eq (some id1) (some id1)) true)
  report "opt_id_some_diff" (okIs (opt_id_eq (some id1) (some id2)) false)
  report "yata_before_lt" (okIs (yata_same_origin_before 1#u64 2#u64) true)
  report "yata_before_eq" (okIs (yata_same_origin_before 2#u64 2#u64) false)
  report "yata_before_gt" (okIs (yata_same_origin_before 5#u64 2#u64) false)

  report "type_ref_array" (okIs (type_ref_to_int .YArrayRef) 0#i32)
  report "type_ref_map" (okIs (type_ref_to_int .YMapRef) 1#i32)
  report "type_ref_text" (okIs (type_ref_to_int .YTextRef) 2#i32)
  report "int_to_tr_0" (okIs (do let t ← int_to_type_ref 0#i32; type_ref_to_int t) 0#i32)
  report "int_to_tr_1" (okIs (do let t ← int_to_type_ref 1#i32; type_ref_to_int t) 1#i32)
  report "int_to_tr_2" (okIs (do let t ← int_to_type_ref 2#i32; type_ref_to_int t) 2#i32)
  report "item_last_id_1" (okIs (do let r ← item_last_id id1 1#u64; ok (r.client == 1#u64 && r.clock == 10#u64)) true)
  report "item_last_id_5" (okIs (do let r ← item_last_id id1 5#u64; ok (r.client == 1#u64 && r.clock == 14#u64)) true)

  let d1 := DeleteItem.mk 10#u64 5#u64
  let d2 := DeleteItem.mk 15#u64 3#u64
  let d3 := DeleteItem.mk 12#u64 2#u64
  let d4 := DeleteItem.mk 20#u64 4#u64
  report "del_can_merge_adj" (okIs (delete_item_can_merge d1 d2) true)
  report "del_can_merge_sub" (okIs (delete_item_can_merge d1 d3) true)
  report "del_can_merge_gap" (okIs (delete_item_can_merge d1 d4) false)
  report "del_merge_adj" (okIs (do let m ← delete_item_merge d1 d2; ok (m.clock == 10#u64 && m.len == 8#u64)) true)
  report "del_merge_sub" (okIs (do let m ← delete_item_merge d1 d3; ok (m.clock == 10#u64 && m.len == 5#u64)) true)
  report "del_contains_lo" (okIs (delete_item_contains d1 10#u64) true)
  report "del_contains_hi" (okIs (delete_item_contains d1 14#u64) true)
  report "del_contains_end" (okIs (delete_item_contains d1 15#u64) false)
  report "del_contains_pre" (okIs (delete_item_contains d1 9#u64) false)

  report "info_enc_val" (okIs (encode_item_info 4#i32 true false true) 164#i32)
  report "info_ref_4" (okIs (info_ref_id 164#i32) 4#i32)
  report "info_orig_t" (okIs (info_has_origin 164#i32) true)
  report "info_rorig_f" (okIs (info_has_right_origin 164#i32) false)
  report "info_psub_t" (okIs (info_has_parent_sub 164#i32) true)
  report "info_cant_copy_f" (okIs (info_cant_copy_parent 164#i32) false)
  report "info_cant_copy_t" (okIs (info_cant_copy_parent 36#i32) true)
  report "hex_char_0" (okIs (hex_nibble_char 0#i32) 48#i32)
  report "hex_char_15" (okIs (hex_nibble_char 15#i32) 102#i32)
  report "hex_parse_9" (okIs (parse_hex_nibble 57#i32) 9#i32)
  report "hex_parse_a" (okIs (parse_hex_nibble 97#i32) 10#i32)
  report "hex_parse_F" (okIs (parse_hex_nibble 70#i32) 15#i32)
  report "hex_parse_bad" (okIs (parse_hex_nibble 122#i32) (-1)#i32)
