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

/-- `is_valid_level` accepts iff `0 <= level <= 9`. -/
theorem is_valid_level_spec (level : Std.I32) :
    is_valid_level level = ok (decide (0 ≤ level.val ∧ level.val ≤ 9)) := by
  unfold is_valid_level; congr 1

/-- Default `DecompressLimits` enforces the 256 MiB Zip Bomb guard (`268435456` bytes). -/
theorem decompress_limits_default_spec :
    ∃ l : DecompressLimits, DecompressLimits.default = ok l ∧ l.max_output_bytes.val = 268435456 := by
  refine ⟨DecompressLimits.mk 268435456#i32, rfl, ?_⟩
  change (BitVec.ofInt 32 268435456).toInt = 268435456
  rw [BitVec.toInt_ofInt]; norm_num

/-- `DecompressLimits::new` preserves the configured limit exactly. -/
theorem decompress_limits_new_spec (lim : Std.I32) :
    ∃ l : DecompressLimits, DecompressLimits.new lim = ok l ∧ l.max_output_bytes = lim :=
  ⟨DecompressLimits.mk lim, rfl, rfl⟩

/-- RFC 1951 §3.2.3: `is_valid_btype` accepts `0, 1, 2` and rejects reserved `3` (and out-of-range values). -/
theorem is_valid_btype_spec (btype : Std.I32) :
    is_valid_btype btype = ok (decide (0 ≤ btype.val ∧ btype.val ≤ 2)) := by
  unfold is_valid_btype; congr 1

/-- RFC 1951 §3.2.4: `is_valid_stored_nlen` is symmetric and accepts every `(slen, slen ^ 0xFFFF)` pair. -/
theorem is_valid_stored_nlen_spec (slen nlen : Std.I32) :
    is_valid_stored_nlen slen nlen = is_valid_stored_nlen nlen slen ∧
    is_valid_stored_nlen slen (Pion.I32.bxor slen 65535#i32) = ok true := by
  constructor
  · unfold is_valid_stored_nlen Pion.I32.bxor
    congr 1; congr 1; congr 1; exact BitVec.xor_comm slen.bv nlen.bv
  · unfold is_valid_stored_nlen Pion.I32.bxor
    congr 1
    rw [beq_iff_eq]
    cases slen with | mk bv =>
    congr 1
    change bv ^^^ (bv ^^^ (65535#i32).bv) = (65535#i32).bv
    rw [← BitVec.xor_assoc, BitVec.xor_self, BitVec.zero_xor]

end FlateProofs
