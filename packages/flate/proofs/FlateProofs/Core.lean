import Aeneas
import PionLean
import Flate.Types
import Flate.Funs

open Aeneas Aeneas.Std Result Pion flate

namespace FlateProofs

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

lemma i32_add_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val + b.val)
    (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  simp only [Pion.I32.add, Std.I32.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  rw [hpow]
  change (a.val + b.val).bmod (2 ^ 32) = a.val + b.val
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

lemma i32_mul_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val * b.val)
    (hhi : a.val * b.val ≤ 2147483647) :
    (Pion.I32.mul a b).val = a.val * b.val := by
  simp only [Pion.I32.mul, Std.I32.wrapping_mul, IScalar.wrapping_mul, IScalar.val, BitVec.toInt_mul]
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  rw [hpow]
  change (a.val * b.val).bmod (2 ^ 32) = a.val * b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_rem_pos (a b : Std.I32) (hb : 0 < b.val) :
    Pion.I32.rem a b = ok (⟨a.bv.srem b.bv⟩ : Std.I32) := by
  unfold Pion.I32.rem
  have h1 : b.val ≠ 0 := by omega
  simp [HMod.hMod, IScalar.rem, h1]
  omega

lemma i32_rem_nonneg_val (a b : Std.I32) (ha : 0 ≤ a.val) (hb : 0 < b.val) :
    ∃ r : Std.I32, Pion.I32.rem a b = ok r ∧ r.val = a.val % b.val := by
  rw [i32_rem_pos a b hb]
  refine ⟨⟨a.bv.srem b.bv⟩, rfl, ?_⟩
  change (a.bv.srem b.bv).toInt = a.val % b.val
  have ha_b := i32_bounds a
  have hb_b := i32_bounds b
  rw [BitVec.toInt_srem]
  have hav : a.bv.toInt = a.val := rfl
  have hbv : b.bv.toInt = b.val := rfl
  rw [hav, hbv, Int.tmod_eq_emod_of_nonneg ha]

end FlateProofs
