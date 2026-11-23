import Aeneas
import PionLean
import Graph.Types
import Graph.Funs

open Aeneas Aeneas.Std Result Pion graph

namespace GraphProofs

lemma iscalar_le_iff {ty : IScalarTy} (a b : IScalar ty) : a ≤ b ↔ a.val ≤ b.val := Iff.rfl
lemma iscalar_lt_iff {ty : IScalarTy} (a b : IScalar ty) : a < b ↔ a.val < b.val := Iff.rfl
lemma iscalar_eq_iff {ty : IScalarTy} (a b : IScalar ty) : a = b ↔ a.val = b.val := by
  constructor
  · intro h; subst h; rfl
  · intro h; cases a; cases b; congr; exact BitVec.eq_of_toInt_eq h

lemma uscalar_le_iff {ty : UScalarTy} (a b : UScalar ty) : a ≤ b ↔ a.val ≤ b.val := Iff.rfl
lemma uscalar_lt_iff {ty : UScalarTy} (a b : UScalar ty) : a < b ↔ a.val < b.val := Iff.rfl
lemma uscalar_eq_iff {ty : UScalarTy} (a b : UScalar ty) : a = b ↔ a.val = b.val := by
  constructor
  · intro h; subst h; rfl
  · intro h; cases a; cases b; congr; exact BitVec.eq_of_toNat_eq h

lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

lemma i32_bounds (x : Std.I32) :
    -(2147483648 : Int) ≤ x.val ∧ x.val ≤ 2147483647 := by
  have h1 := x.hBounds
  have hpow : (2 : Int) ^ (IScalarTy.I32.numBits - 1) = 2147483648 := by
    change (2 : Int) ^ (32 - 1) = 2147483648; norm_num
  omega

lemma i64_bounds (x : Std.I64) :
    -(9223372036854775808 : Int) ≤ x.val ∧ x.val ≤ 9223372036854775807 := by
  have h1 := x.hBounds
  have hpow : (2 : Int) ^ (IScalarTy.I64.numBits - 1) = 9223372036854775808 := by
    change (2 : Int) ^ (64 - 1) = 9223372036854775808; norm_num
  omega

lemma u64_bounds (x : Std.U64) : x.val < 18446744073709551616 := by
  have h1 := x.bv.isLt
  have hpow : (2 : Nat) ^ UScalarTy.U64.numBits = 18446744073709551616 := by
    change (2 : Nat) ^ 64 = 18446744073709551616; norm_num
  change x.bv.toNat < 18446744073709551616
  omega

lemma i64_max_val : (9223372036854775807#i64).val = 9223372036854775807 := by
  change (BitVec.ofInt 64 9223372036854775807).toInt = 9223372036854775807
  rw [BitVec.toInt_ofInt]; norm_num

lemma i64_neg_max_val : ((-9223372036854775807)#i64).val = -9223372036854775807 := by
  change (BitVec.ofInt 64 (-9223372036854775807)).toInt = -9223372036854775807
  rw [BitVec.toInt_ofInt]; norm_num

lemma u64_half_max_val : (9223372036854775807#u64).val = 9223372036854775807 := by
  change (BitVec.ofNat 64 9223372036854775807).toNat = 9223372036854775807
  rw [BitVec.toNat_ofNat]

lemma u64_sign_bit_val : (9223372036854775808#u64).val = 9223372036854775808 := by
  change (BitVec.ofNat 64 9223372036854775808).toNat = 9223372036854775808
  rw [BitVec.toNat_ofNat]

lemma i64_sub_val (a b : Std.I64)
    (hlo : -(9223372036854775808 : Int) ≤ a.val - b.val)
    (hhi : a.val - b.val ≤ 9223372036854775807) :
    (Pion.I64.sub a b).val = a.val - b.val := by
  simp only [Pion.I64.sub, Std.I64.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
  have hpow : (2 : Nat) ^ IScalarTy.I64.numBits = 2 ^ 64 := rfl
  rw [hpow]
  change (a.val - b.val).bmod (2 ^ 64) = a.val - b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i64_add_val (a b : Std.I64)
    (hlo : -(9223372036854775808 : Int) ≤ a.val + b.val)
    (hhi : a.val + b.val ≤ 9223372036854775807) :
    (Pion.I64.add a b).val = a.val + b.val := by
  simp only [Pion.I64.add, Std.I64.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
  have hpow : (2 : Nat) ^ IScalarTy.I64.numBits = 2 ^ 64 := rfl
  rw [hpow]
  change (a.val + b.val).bmod (2 ^ 64) = a.val + b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_sub_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val - b.val)
    (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  simp only [Pion.I32.sub, Std.I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  rw [hpow]
  change (a.val - b.val).bmod (2 ^ 32) = a.val - b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_add_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val + b.val)
    (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  simp only [Pion.I32.add, Std.I32.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  rw [hpow]
  change (a.val + b.val).bmod (2 ^ 32) = a.val + b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

/-- `NodeId::new` and `NodeId::to_int` form an exact roundtrip bijection. -/
theorem node_id_roundtrip (idx : Std.I32) :
    (do let n ← NodeId.new idx; NodeId.to_int n) = ok idx := by
  unfold NodeId.new NodeId.to_int; rw [result_bind_ok]

/-- `NodeId::eq` is an equivalence relation matching raw index equality. -/
theorem node_id_eq_equiv (a b c : NodeId) :
    NodeId.eq a a = ok true ∧
    (NodeId.eq a b = ok true ↔ a.index = b.index) ∧
    (NodeId.eq a b = ok true → NodeId.eq b a = ok true) ∧
    (NodeId.eq a b = ok true → NodeId.eq b c = ok true → NodeId.eq a c = ok true) := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold NodeId.eq; simp
  · unfold NodeId.eq; constructor
    · intro h; exact beq_iff_eq.mp (result_ok_inj h)
    · intro h; rw [h]; simp
  · unfold NodeId.eq; intro h; have := beq_iff_eq.mp (result_ok_inj h); rw [this]; simp
  · unfold NodeId.eq; intro h1 h2
    have e1 := beq_iff_eq.mp (result_ok_inj h1)
    have e2 := beq_iff_eq.mp (result_ok_inj h2)
    rw [e1, e2]; simp

/-- `EdgeId::new` and `EdgeId::to_int` form an exact roundtrip bijection. -/
theorem edge_id_roundtrip (idx : Std.I32) :
    (do let e ← EdgeId.new idx; EdgeId.to_int e) = ok idx := by
  unfold EdgeId.new EdgeId.to_int; rw [result_bind_ok]

/-- `EdgeId::eq` is an equivalence relation matching raw index equality. -/
theorem edge_id_eq_equiv (a b c : EdgeId) :
    EdgeId.eq a a = ok true ∧
    (EdgeId.eq a b = ok true ↔ a.index = b.index) ∧
    (EdgeId.eq a b = ok true → EdgeId.eq b a = ok true) ∧
    (EdgeId.eq a b = ok true → EdgeId.eq b c = ok true → EdgeId.eq a c = ok true) := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold EdgeId.eq; simp
  · unfold EdgeId.eq; constructor
    · intro h; exact beq_iff_eq.mp (result_ok_inj h)
    · intro h; rw [h]; simp
  · unfold EdgeId.eq; intro h; have := beq_iff_eq.mp (result_ok_inj h); rw [this]; simp
  · unfold EdgeId.eq; intro h1 h2
    have e1 := beq_iff_eq.mp (result_ok_inj h1)
    have e2 := beq_iff_eq.mp (result_ok_inj h2)
    rw [e1, e2]; simp

/-- `is_valid_node_count` holds iff `0 <= node_count <= 67108864`. -/
theorem is_valid_node_count_spec (n : Std.I32) :
    is_valid_node_count n = ok (decide (0 ≤ n.val ∧ n.val ≤ 67108864)) := by
  unfold is_valid_node_count; congr 1

/-- `is_valid_node_idx` holds iff `0 <= idx < n`, and is always `false` when `n <= 0`. -/
theorem is_valid_node_idx_spec (idx n : Std.I32) :
    is_valid_node_idx idx n = ok (decide (0 ≤ idx.val ∧ idx.val < n.val)) := by
  unfold is_valid_node_idx; congr 1

end GraphProofs
