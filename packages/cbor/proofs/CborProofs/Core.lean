import Aeneas
import PionLean
import Cbor.Types
import Cbor.Funs

open Aeneas Aeneas.Std Result Pion cbor

namespace CborProofs

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

lemma u64_24_val : (24#u64).val = 24 := by
  change (BitVec.ofNat 64 24).toNat = 24; rw [BitVec.toNat_ofNat]

lemma u64_255_val : (255#u64).val = 255 := by
  change (BitVec.ofNat 64 255).toNat = 255; rw [BitVec.toNat_ofNat]

lemma u64_65535_val : (65535#u64).val = 65535 := by
  change (BitVec.ofNat 64 65535).toNat = 65535; rw [BitVec.toNat_ofNat]

lemma u64_u32max_val : (4294967295#u64).val = 4294967295 := by
  change (BitVec.ofNat 64 4294967295).toNat = 4294967295; rw [BitVec.toNat_ofNat]

lemma i32_bounds (x : Std.I32) :
    -(2147483648 : Int) ≤ x.val ∧ x.val ≤ 2147483647 := by
  have h1 := x.hBounds
  have hpow : (2 : Int) ^ (IScalarTy.I32.numBits - 1) = 2147483648 := by
    change (2 : Int) ^ (32 - 1) = 2147483648; norm_num
  omega

end CborProofs
