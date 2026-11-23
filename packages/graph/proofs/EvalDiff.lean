import Graph.Types
import Graph.Funs

open Aeneas Aeneas.Std Result Pion graph

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def check (label : String) (b : Bool) : IO Unit :=
  IO.println s!"{label}: {if b then "PASS" else "FAIL"}"

def main : IO Unit := do
  -- NodeId & EdgeId
  check "node_id_rt_0" (okIs (do let n ← NodeId.new 0#i32; NodeId.to_int n) 0#i32)
  check "node_id_rt_42" (okIs (do let n ← NodeId.new 42#i32; NodeId.to_int n) 42#i32)
  check "node_id_eq_true" (okIs (NodeId.eq (NodeId.mk 7#i32) (NodeId.mk 7#i32)) true)
  check "node_id_eq_false" (okIs (NodeId.eq (NodeId.mk 7#i32) (NodeId.mk 8#i32)) false)
  check "edge_id_rt_99" (okIs (do let e ← EdgeId.new 99#i32; EdgeId.to_int e) 99#i32)
  check "edge_id_eq_true" (okIs (EdgeId.eq (EdgeId.mk 3#i32) (EdgeId.mk 3#i32)) true)
  check "edge_id_eq_false" (okIs (EdgeId.eq (EdgeId.mk 3#i32) (EdgeId.mk 4#i32)) false)

  -- CSR bounds
  check "valid_nc_neg1" (okIs (is_valid_node_count (-1)#i32) false)
  check "valid_nc_0" (okIs (is_valid_node_count 0#i32) true)
  check "valid_nc_max" (okIs (is_valid_node_count 67108864#i32) true)
  check "valid_nc_over" (okIs (is_valid_node_count 67108865#i32) false)
  check "valid_idx_neg1" (okIs (is_valid_node_idx (-1)#i32 10#i32) false)
  check "valid_idx_0_10" (okIs (is_valid_node_idx 0#i32 10#i32) true)
  check "valid_idx_9_10" (okIs (is_valid_node_idx 9#i32 10#i32) true)
  check "valid_idx_10_10" (okIs (is_valid_node_idx 10#i32 10#i32) false)

  -- checked_add_i64
  check "cadd_10_20" (okIs (checked_add_i64 10#i64 20#i64) (some 30#i64))
  check "cadd_max_0" (okIs (checked_add_i64 9223372036854775807#i64 0#i64) (some 9223372036854775807#i64))
  check "cadd_max_1_none" (okIs (checked_add_i64 9223372036854775807#i64 1#i64) none)
  check "cadd_min_m1_none" (okIs (checked_add_i64 (Pion.I64.sub (-9223372036854775807)#i64 1#i64) (-1)#i64) none)
  check "cadd_max_negmax" (okIs (checked_add_i64 9223372036854775807#i64 (-9223372036854775807)#i64) (some 0#i64))

  -- 128-bit Bellman-Ford arithmetic
  check "fits_0_max" (okIs (fits_i64 0#i64 9223372036854775807#u64) true)
  check "fits_0_signbit_false" (okIs (fits_i64 0#i64 9223372036854775808#u64) false)
  check "fits_m1_signbit_true" (okIs (fits_i64 (-1)#i64 9223372036854775808#u64) true)
  check "fits_m1_halfmax_false" (okIs (fits_i64 (-1)#i64 9223372036854775807#u64) false)
  check "fits_1_0_false" (okIs (fits_i64 1#i64 0#u64) false)
  check "sign_hi_pos" (okIs (i64_sign_hi 42#i64) 0#i64)
  check "sign_hi_neg" (okIs (i64_sign_hi (-42)#i64) (-1)#i64)
  check "carry_0" (okIs (i128_add_carry 100#u64 200#u64) 0#i64)
  check "carry_1" (okIs (i128_add_carry 18446744073709551615#u64 1#u64) 1#i64)
  check "i128_lt_hi" (okIs (i128_lt (-1)#i64 100#u64 0#i64 0#u64) true)
  check "i128_lt_lo" (okIs (i128_lt 0#i64 5#u64 0#i64 6#u64) true)
  check "i128_lt_eq" (okIs (i128_lt 0#i64 5#u64 0#i64 5#u64) false)

  -- Kruskal LSD Radix Sort key
  check "radix_min" (okIs (i64_to_radix_key (Pion.I64.sub (-9223372036854775807)#i64 1#i64)) 0#u64)
  check "radix_0" (okIs (i64_to_radix_key 0#i64) 9223372036854775808#u64)
  check "radix_max" (okIs (i64_to_radix_key 9223372036854775807#i64) 18446744073709551615#u64)

  -- Dinic residual half-edges & Binary Heap indexing
  check "fwd_edge_5" (okIs (forward_half_edge 5#i32) 10#i32)
  check "twin_10" (okIs (residual_twin 10#i32) 11#i32)
  check "twin_11" (okIs (residual_twin 11#i32) 10#i32)
  check "heap_parent_1" (okIs (heap_parent 1#i32) 0#i32)
  check "heap_parent_2" (okIs (heap_parent 2#i32) 0#i32)
  check "heap_parent_7" (okIs (heap_parent 7#i32) 3#i32)
  check "heap_left_0" (okIs (heap_left_child 0#i32) 1#i32)
  check "heap_left_3" (okIs (heap_left_child 3#i32) 7#i32)
