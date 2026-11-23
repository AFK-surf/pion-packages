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

lemma u64_lt_pow64 (x : Std.U64) : x.val < 18446744073709551616 := by
  have h := x.bv.isLt
  have hp : (2 : Nat) ^ UScalarTy.U64.numBits = 18446744073709551616 := by decide
  change x.bv.toNat < 18446744073709551616
  omega

lemma u64_max_val : (18446744073709551615#u64).val = 18446744073709551615 := rfl

lemma u64_add_val (a b : Std.U64) (h : a.val + b.val < 18446744073709551616) :
    (Pion.U64.add a b).val = a.val + b.val := by
  unfold Pion.U64.add
  change (a.bv + b.bv).toNat = a.bv.toNat + b.bv.toNat
  change a.bv.toNat + b.bv.toNat < 18446744073709551616 at h
  rw [BitVec.toNat_add]
  have hp : (2 : Nat) ^ UScalarTy.U64.numBits = 18446744073709551616 := by decide
  exact Nat.mod_eq_of_lt (by omega)

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

end CrdtProofs
