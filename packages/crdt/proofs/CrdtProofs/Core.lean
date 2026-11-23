import Aeneas
import PionLean
import Crdt.Types
import Crdt.Funs

open Aeneas Aeneas.Std Result Pion crdt

namespace CrdtProofs

lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

lemma uscalar_eq_iff {ty : UScalarTy} (a b : UScalar ty) :
    a = b ↔ a.val = b.val := by
  constructor
  · intro h; subst h; rfl
  · intro h; cases a; cases b; congr; exact BitVec.eq_of_toNat_eq h

lemma uscalar_lt_iff {ty : UScalarTy} (a b : UScalar ty) :
    a < b ↔ a.val < b.val := Iff.rfl

lemma uscalar_gt_iff {ty : UScalarTy} (a b : UScalar ty) :
    a > b ↔ b.val < a.val := Iff.rfl

lemma uscalar_le_iff {ty : UScalarTy} (a b : UScalar ty) :
    a ≤ b ↔ a.val ≤ b.val := Iff.rfl

lemma iscalar_eq_iff {ty : IScalarTy} (a b : IScalar ty) :
    a = b ↔ a.val = b.val := by
  constructor
  · intro h; subst h; rfl
  · intro h; cases a; cases b; congr; exact BitVec.eq_of_toInt_eq h

lemma iscalar_lt_iff {ty : IScalarTy} (a b : IScalar ty) :
    a < b ↔ a.val < b.val := Iff.rfl

lemma iscalar_le_iff {ty : IScalarTy} (a b : IScalar ty) :
    a ≤ b ↔ a.val ≤ b.val := Iff.rfl

lemma u64_add_val (a b : Std.U64) (h : a.val + b.val < 2 ^ 64) :
    (Pion.U64.add a b).val = a.val + b.val := by
  unfold Pion.U64.add
  change (a.bv + b.bv).toNat = a.bv.toNat + b.bv.toNat
  rw [BitVec.toNat_add]
  exact Nat.mod_eq_of_lt h

lemma u64_sub_val (a b : Std.U64) (h : b.val ≤ a.val) :
    (Pion.U64.sub a b).val = a.val - b.val := by
  unfold Pion.U64.sub
  change (a.bv - b.bv).toNat = a.bv.toNat - b.bv.toNat
  rw [BitVec.toNat_sub_of_le h]

lemma i32_add_val (a b : Std.I32) (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  unfold Pion.I32.add
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  change (a.bv + b.bv).toInt = a.bv.toInt + b.bv.toInt
  rw [BitVec.toInt_add, Int.bmod_eq_of_le] <;> omega

lemma i32_sub_val (a b : Std.I32) (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  unfold Pion.I32.sub
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  change (a.bv - b.bv).toInt = a.bv.toInt - b.bv.toInt
  rw [BitVec.toInt_sub, Int.bmod_eq_of_le] <;> omega

/-- `Id.eq` is exact structural equality on `(client, clock)`. -/
theorem id_eq_iff (a b : Id) :
    Id.eq a b = ok true ↔ a = b := by
  unfold Id.eq
  cases a with | mk c1 k1 =>
  cases b with | mk c2 k2 =>
  simp only [ok.injEq, Bool.and_eq_true, beq_iff_eq, Id.mk.injEq]

/-- `Id.eq` is reflexive. -/
theorem id_eq_refl (a : Id) :
    Id.eq a a = ok true :=
  (id_eq_iff a a).mpr rfl

/-- `Id.eq` is symmetric. -/
theorem id_eq_symm (a b : Id) :
    Id.eq a b = Id.eq b a := by
  unfold Id.eq
  congr 1
  have h1 : (a.client == b.client) = (b.client == a.client) := by
    by_cases hc : a.client = b.client
    · rw [hc]
    · simp only [beq_false_of_ne hc, beq_false_of_ne (Ne.symm hc)]
  have h2 : (a.clock == b.clock) = (b.clock == a.clock) := by
    by_cases hk : a.clock = b.clock
    · rw [hk]
    · simp only [beq_false_of_ne hk, beq_false_of_ne (Ne.symm hk)]
  rw [h1, h2]

/-- `opt_id_eq` is exact structural equality on `Option Id`. -/
theorem opt_id_eq_iff (a b : Option Id) :
    opt_id_eq a b = ok true ↔ a = b := by
  unfold opt_id_eq
  cases a with
  | none =>
    cases b <;> simp
  | some x =>
    cases b with
    | none => simp
    | some y =>
      dsimp only
      unfold Id.eq
      rw [result_bind_ok]
      cases x with | mk c1 k1 =>
      cases y with | mk c2 k2 =>
      simp only [ok.injEq, Option.some.injEq, Bool.and_eq_true, beq_iff_eq, Id.mk.injEq]

/-- `Id.cmp` always returns `-1`, `0`, or `1` (trichotomy). -/
theorem id_cmp_trichotomy (a b : Id) :
    ∃ r : Std.I32, Id.cmp a b = ok r ∧ (r = (-1)#i32 ∨ r = 0#i32 ∨ r = 1#i32) := by
  unfold Id.cmp
  refine ⟨_, rfl, ?_⟩
  split_ifs <;> simp

/-- `Id.cmp a b = ok 0` iff `a = b`. -/
theorem id_cmp_eq_zero_iff (a b : Id) :
    Id.cmp a b = ok 0#i32 ↔ a = b := by
  unfold Id.cmp
  cases a with | mk c1 k1 =>
  cases b with | mk c2 k2 =>
  simp only [ok.injEq, Id.mk.injEq, uscalar_lt_iff]
  split_ifs with h1 h2 h3 h4
  · constructor
    · intro h; exact absurd h (by decide)
    · rintro ⟨rfl, _⟩; omega
  · constructor
    · intro h; exact absurd h (by decide)
    · rintro ⟨rfl, _⟩; omega
  · constructor
    · intro h; exact absurd h (by decide)
    · rintro ⟨_, rfl⟩; omega
  · constructor
    · intro h; exact absurd h (by decide)
    · rintro ⟨_, rfl⟩; omega
  · constructor
    · intro _
      exact ⟨(uscalar_eq_iff _ _).mpr (by omega), (uscalar_eq_iff _ _).mpr (by omega)⟩
    · intro _; rfl

/-- `Id.cmp` is antisymmetric: `cmp a b = -1 ↔ cmp b a = 1`. -/
theorem id_cmp_antisymm (a b : Id) :
    Id.cmp a b = ok (-1)#i32 ↔ Id.cmp b a = ok 1#i32 := by
  unfold Id.cmp
  simp only [ok.injEq, uscalar_lt_iff]
  split_ifs <;> first
    | (simp; done)
    | (exfalso; omega)

/-- `Id.cmp` is transitive: `cmp a b = -1 → cmp b c = -1 → cmp a c = -1`. -/
theorem id_cmp_trans (a b c : Id)
    (hab : Id.cmp a b = ok (-1)#i32) (hbc : Id.cmp b c = ok (-1)#i32) :
    Id.cmp a c = ok (-1)#i32 := by
  unfold Id.cmp at hab hbc ⊢
  simp only [ok.injEq, uscalar_lt_iff] at hab hbc ⊢
  have h_ab : a.client.val < b.client.val ∨ (a.client.val = b.client.val ∧ a.clock.val < b.clock.val) := by
    split_ifs at hab with h1 h2 h3 h4
    · left; exact h1
    · exact absurd hab (by decide)
    · right; exact ⟨by omega, h3⟩
    · exact absurd hab (by decide)
    · exact absurd hab (by decide)
  have h_bc : b.client.val < c.client.val ∨ (b.client.val = c.client.val ∧ b.clock.val < c.clock.val) := by
    split_ifs at hbc with h1 h2 h3 h4
    · left; exact h1
    · exact absurd hbc (by decide)
    · right; exact ⟨by omega, h3⟩
    · exact absurd hbc (by decide)
    · exact absurd hbc (by decide)
  split_ifs with h1 h2 h3 h4
  · rfl
  · exfalso; omega
  · rfl
  · exfalso; omega
  · exfalso; omega

/-- YATA same-origin client tie-breaking (`lhs_client < rhs_client`) is a strict order (irreflexive, asymmetric, transitive). -/
theorem yata_same_origin_strict_order (a b c : Std.U64) :
    yata_same_origin_before a a = ok false ∧
    (yata_same_origin_before a b = ok true → yata_same_origin_before b a = ok false) ∧
    (yata_same_origin_before a b = ok true → yata_same_origin_before b c = ok true → yata_same_origin_before a c = ok true) := by
  unfold yata_same_origin_before
  simp only [ok.injEq, decide_eq_false_iff_not, decide_eq_true_eq, uscalar_lt_iff]
  refine ⟨by omega, fun h => by omega, fun h1 h2 => by omega⟩

end CrdtProofs
