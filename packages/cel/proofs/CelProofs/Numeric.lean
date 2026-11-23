import Aeneas
import PionLean
import Cel.Types
import Cel.Funs

open Aeneas Aeneas.Std Result Pion cel

namespace CelProofs

private lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

private lemma i64_sub_val_of_bounds (a b : I64)
    (hlo : -9223372036854775808 ≤ a.val - b.val)
    (hhi : a.val - b.val ≤ 9223372036854775807) :
    (Pion.I64.sub a b).val = a.val - b.val := by
  have hwrap : (Pion.I64.sub a b).val = Int.bmod (a.val - b.val) (2 ^ 64) := by
    change (I64.wrapping_sub a b).val = Int.bmod (a.val - b.val) (2 ^ 64)
    simp only [I64.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i64_add_val_of_bounds (a b : I64)
    (hlo : -9223372036854775808 ≤ a.val + b.val)
    (hhi : a.val + b.val ≤ 9223372036854775807) :
    (Pion.I64.add a b).val = a.val + b.val := by
  have hwrap : (Pion.I64.add a b).val = Int.bmod (a.val + b.val) (2 ^ 64) := by
    change (I64.wrapping_add a b).val = Int.bmod (a.val + b.val) (2 ^ 64)
    simp only [I64.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma u64_sub_val_of_le (a b : U64) (hle : b.val ≤ a.val) :
    (Pion.U64.sub a b).val = a.val - b.val := by
  have hwrap : (Pion.U64.sub a b).val = (a.bv - b.bv).toNat := rfl
  rw [hwrap, BitVec.toNat_sub_of_le]
  · rfl
  · exact hle

private lemma i64_min_val :
    (Pion.I64.sub (-9223372036854775807)#i64 1#i64).val = -9223372036854775808 := by
  decide

private lemma i64_max_val : (9223372036854775807#i64 : I64).val = 9223372036854775807 := by
  decide

private lemma u64_max_val : (18446744073709551615#u64 : U64).val = 18446744073709551615 := by
  decide

private lemma i64_reinterpret_u64_val (i : I64) (hi : 0 ≤ i.val) :
    ((Pion.I64.reinterpret_as_uint64 i).val : Int) = i.val := by
  have hbv : (Pion.I64.reinterpret_as_uint64 i).bv = i.bv := by
    change i.bv.signExtend 64 = i.bv
    exact BitVec.signExtend_eq i.bv
  have hlt : i.bv.toNat < 2 ^ 63 := by
    have htoInt : i.val = i.bv.toInt := rfl
    rw [BitVec.toInt_eq_toNat_cond] at htoInt
    split_ifs at htoInt with h
    · omega
    · have := i.bv.isLt; omega
  have hval : (Pion.I64.reinterpret_as_uint64 i).val = i.bv.toNat := by
    change (Pion.I64.reinterpret_as_uint64 i).bv.toNat = i.bv.toNat
    rw [hbv]
  rw [hval]
  have htoInt : i.val = i.bv.toInt := rfl
  rw [BitVec.toInt_eq_toNat_cond] at htoInt
  split_ifs at htoInt with h
  · omega
  · omega

private lemma u64_div_ok (a b : U64) (hb : b.val ≠ 0) :
    ∃ q, Pion.U64.div a b = ok q ∧ q.val = a.val / b.val := by
  have hspec := Pion.U64.div_spec (x := a) (y := b) hb
  have hok : Pion.U64.div a b = ok (⟨a.bv / b.bv⟩ : U64) := by
    change UScalar.div a b = _
    simp only [UScalar.div]
    have hbv : ¬(b.bv = 0#64) := fun h => hb (by change b.bv.toNat = 0; rw [h]; rfl)
    simp [hbv]
  rw [hok] at hspec
  simp only [WP.spec_ok] at hspec
  exact ⟨⟨a.bv / b.bv⟩, hok, hspec⟩

/-- Theorem 1: `i64_neg_overflows a` returns `true` iff `a = INT64_MIN` (i.e. `-a` exceeds `INT64_MAX`). -/
theorem i64_neg_overflows_iff (a : I64) :
    i64_neg_overflows a = ok true ↔ a.val = -9223372036854775808 := by
  unfold i64_neg_overflows
  constructor
  · intro h
    have h1 := result_ok_inj h
    have h2 : a = Pion.I64.sub (-9223372036854775807)#i64 1#i64 := by simpa using h1
    rw [h2, i64_min_val]
  · intro h
    have heq : a = Pion.I64.sub (-9223372036854775807)#i64 1#i64 := by
      apply IScalar.eq_of_val_eq
      rw [h, i64_min_val]
    rw [heq]
    simp

/-- Theorem 2: `i64_add_overflows a b` returns `true` iff `a + b` lies outside `[-2^63, 2^63 - 1]`. -/
theorem i64_add_overflows_iff (a b : I64) :
    i64_add_overflows a b = ok true ↔
      (a.val + b.val < -9223372036854775808 ∨ a.val + b.val > 9223372036854775807) := by
  unfold i64_add_overflows
  have ha_lo : -9223372036854775808 ≤ a.val := by have := a.hBounds; simp at this; omega
  have ha_hi : a.val ≤ 9223372036854775807 := by have := a.hBounds; simp at this; omega
  have hb_lo : -9223372036854775808 ≤ b.val := by have := b.hBounds; simp at this; omega
  have hb_hi : b.val ≤ 9223372036854775807 := by have := b.hBounds; simp at this; omega
  constructor
  · intro h
    have h1 := result_ok_inj h
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at h1
    rcases h1 with ⟨hbp, hap⟩ | ⟨hbn, han⟩
    · have hbp' : 0 < b.val := hbp
      have hsub := i64_sub_val_of_bounds 9223372036854775807#i64 b
        (by rw [i64_max_val]; omega) (by rw [i64_max_val]; omega)
      have hap' : (Pion.I64.sub 9223372036854775807#i64 b).val < a.val := hap
      rw [hsub, i64_max_val] at hap'
      omega
    · have hbn' : b.val < 0 := hbn
      have hsub := i64_sub_val_of_bounds (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b
        (by rw [i64_min_val]; omega) (by rw [i64_min_val]; omega)
      have han' : a.val < (Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val := han
      rw [hsub, i64_min_val] at han'
      omega
  · intro h
    apply congrArg ok
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
    rcases h with hlo | hhi
    · right
      have hbn : b.val < 0 := by omega
      have hsub := i64_sub_val_of_bounds (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b
        (by rw [i64_min_val]; omega) (by rw [i64_min_val]; omega)
      refine ⟨hbn, ?_⟩
      show a.val < (Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val
      rw [hsub, i64_min_val]; omega
    · left
      have hbp : 0 < b.val := by omega
      have hsub := i64_sub_val_of_bounds 9223372036854775807#i64 b
        (by rw [i64_max_val]; omega) (by rw [i64_max_val]; omega)
      have hlt : (Pion.I64.sub 9223372036854775807#i64 b).val < a.val := by
        rw [hsub, i64_max_val]; omega
      exact ⟨hbp, hlt⟩

/-- Theorem 3: `i64_sub_overflows a b` returns `true` iff `a - b` lies outside `[-2^63, 2^63 - 1]`. -/
theorem i64_sub_overflows_iff (a b : I64) :
    i64_sub_overflows a b = ok true ↔
      (a.val - b.val < -9223372036854775808 ∨ a.val - b.val > 9223372036854775807) := by
  unfold i64_sub_overflows
  have ha_lo : -9223372036854775808 ≤ a.val := by have := a.hBounds; simp at this; omega
  have ha_hi : a.val ≤ 9223372036854775807 := by have := a.hBounds; simp at this; omega
  have hb_lo : -9223372036854775808 ≤ b.val := by have := b.hBounds; simp at this; omega
  have hb_hi : b.val ≤ 9223372036854775807 := by have := b.hBounds; simp at this; omega
  constructor
  · intro h
    have h1 := result_ok_inj h
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at h1
    rcases h1 with ⟨hbn, hap⟩ | ⟨hbp, han⟩
    · have hbn' : b.val < 0 := hbn
      have hadd := i64_add_val_of_bounds 9223372036854775807#i64 b
        (by rw [i64_max_val]; omega) (by rw [i64_max_val]; omega)
      have hap' : (Pion.I64.add 9223372036854775807#i64 b).val < a.val := hap
      rw [hadd, i64_max_val] at hap'
      omega
    · have hbp' : 0 < b.val := hbp
      have hadd := i64_add_val_of_bounds (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b
        (by rw [i64_min_val]; omega) (by rw [i64_min_val]; omega)
      have han' : a.val < (Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val := han
      rw [hadd, i64_min_val] at han'
      omega
  · intro h
    apply congrArg ok
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
    rcases h with hlo | hhi
    · right
      have hbp : 0 < b.val := by omega
      have hadd := i64_add_val_of_bounds (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b
        (by rw [i64_min_val]; omega) (by rw [i64_min_val]; omega)
      refine ⟨hbp, ?_⟩
      show a.val < (Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val
      rw [hadd, i64_min_val]; omega
    · left
      have hbn : b.val < 0 := by omega
      have hadd := i64_add_val_of_bounds 9223372036854775807#i64 b
        (by rw [i64_max_val]; omega) (by rw [i64_max_val]; omega)
      refine ⟨hbn, ?_⟩
      show (Pion.I64.add 9223372036854775807#i64 b).val < a.val
      rw [hadd, i64_max_val]; omega

/-- Theorem 4: `i64_div_err_code` classifies division-by-zero (`1`), `INT64_MIN / -1` overflow (`2`), and safe division (`0`). -/
theorem i64_div_err_code_spec (a b : I64) :
    ∃ r, i64_div_err_code a b = ok r ∧
      (r = 1#i32 ↔ b.val = 0) ∧
      (r = 2#i32 ↔ (a.val = -9223372036854775808 ∧ b.val = -1)) ∧
      (r = 0#i32 ↔ (b.val ≠ 0 ∧ ¬(a.val = -9223372036854775808 ∧ b.val = -1))) := by
  unfold i64_div_err_code
  refine ⟨_, rfl, ?_, ?_, ?_⟩
  · by_cases hb : b = 0#i64
    · subst hb; simp
    · have hbv : b.val ≠ 0 := fun h => hb (IScalar.eq_of_val_eq h)
      simp only [hb, ↓reduceIte, hbv, iff_false]
      split_ifs <;> decide
  · by_cases hb : b = 0#i64
    · subst hb
      simp only [↓reduceIte]
      constructor
      · intro h; cases h
      · intro ⟨_, h1⟩; exact absurd h1 (by decide)
    · simp only [hb, ↓reduceIte]
      by_cases hcond : ((a == Pion.I64.sub (-9223372036854775807)#i64 1#i64) && (b == (-1)#i64)) = true
      · simp only [hcond, ↓reduceIte, true_iff]
        simp only [Bool.and_eq_true, beq_iff_eq] at hcond
        rcases hcond with ⟨ha, hb1⟩
        exact ⟨by rw [ha, i64_min_val], by rw [hb1]; decide⟩
      · have hcf : ((a == Pion.I64.sub (-9223372036854775807)#i64 1#i64) && (b == (-1)#i64)) = false :=
          Bool.eq_false_iff.mpr hcond
        simp only [hcf, Bool.false_eq_true, ↓reduceIte]
        constructor
        · intro h; cases h
        · intro ⟨ha, hb1⟩
          exfalso
          apply hcond
          simp only [Bool.and_eq_true, beq_iff_eq]
          exact ⟨IScalar.eq_of_val_eq (by rw [ha, i64_min_val]),
                 IScalar.eq_of_val_eq (by rw [hb1]; decide)⟩
  · by_cases hb : b = 0#i64
    · subst hb; simp
    · have hbv : b.val ≠ 0 := fun h => hb (IScalar.eq_of_val_eq h)
      simp only [hb, ↓reduceIte]
      by_cases hcond : ((a == Pion.I64.sub (-9223372036854775807)#i64 1#i64) && (b == (-1)#i64)) = true
      · simp only [hcond, ↓reduceIte]
        simp only [Bool.and_eq_true, beq_iff_eq] at hcond
        rcases hcond with ⟨ha, hb1⟩
        constructor
        · intro h; cases h
        · intro ⟨_, hnot⟩
          exact absurd ⟨by rw [ha, i64_min_val], by rw [hb1]; decide⟩ hnot
      · have hcf : ((a == Pion.I64.sub (-9223372036854775807)#i64 1#i64) && (b == (-1)#i64)) = false :=
          Bool.eq_false_iff.mpr hcond
        simp only [hcf, Bool.false_eq_true, ↓reduceIte, true_iff]
        refine ⟨hbv, fun ⟨ha, hb1⟩ => hcond ?_⟩
        simp only [Bool.and_eq_true, beq_iff_eq]
        exact ⟨IScalar.eq_of_val_eq (by rw [ha, i64_min_val]),
               IScalar.eq_of_val_eq (by rw [hb1]; decide)⟩

/-- Theorem 5: `u64_add_overflows a b` returns `true` iff `a + b ≥ 2^64`. -/
theorem u64_add_overflows_iff (a b : U64) :
    u64_add_overflows a b = ok true ↔ a.val + b.val ≥ 2 ^ 64 := by
  unfold u64_add_overflows
  have hb_lt : b.val < 2 ^ 64 := b.bv.isLt
  have hb_le : b.val ≤ (18446744073709551615#u64 : U64).val := by
    rw [u64_max_val]; omega
  have hsub := u64_sub_val_of_le 18446744073709551615#u64 b hb_le
  rw [u64_max_val] at hsub
  constructor
  · intro h
    have h1 := result_ok_inj h
    have h2 : (Pion.U64.sub 18446744073709551615#u64 b).val < a.val := by simpa using h1
    rw [hsub] at h2
    omega
  · intro h
    apply congrArg ok
    have hlt : (Pion.U64.sub 18446744073709551615#u64 b).val < a.val := by
      rw [hsub]; omega
    exact decide_eq_true hlt

/-- Theorem 6: `u64_add_overflows` is commutative. -/
theorem u64_add_overflows_comm (a b : U64) :
    u64_add_overflows a b = u64_add_overflows b a := by
  have h1 := u64_add_overflows_iff a b
  have h2 := u64_add_overflows_iff b a
  unfold u64_add_overflows at h1 h2 ⊢
  apply congrArg ok
  apply Bool.eq_iff_iff.mpr
  constructor
  · intro ht
    have hge : a.val + b.val ≥ 2 ^ 64 := h1.mp (congrArg ok ht)
    exact result_ok_inj (h2.mpr (by omega))
  · intro ht
    have hge : b.val + a.val ≥ 2 ^ 64 := h2.mp (congrArg ok ht)
    exact result_ok_inj (h1.mpr (by omega))

/-- Theorem 7: `u64_sub_underflows a b` returns `true` iff `a < b`. -/
theorem u64_sub_underflows_iff (a b : U64) :
    u64_sub_underflows a b = ok true ↔ a.val < b.val := by
  unfold u64_sub_underflows
  constructor
  · intro h; have h1 := result_ok_inj h; simpa using h1
  · intro h; apply congrArg ok; simp [h]

/-- Theorem 8: `u64_mul_overflows a b` returns `true` iff `a * b ≥ 2^64`. -/
theorem u64_mul_overflows_iff (a b : U64) :
    ∃ r, u64_mul_overflows a b = ok r ∧ (r = true ↔ a.val * b.val ≥ 2 ^ 64) := by
  unfold u64_mul_overflows
  by_cases hab : ((a != 0#u64) && (b != 0#u64)) = true
  · simp only [hab, ↓reduceIte]
    simp only [Bool.and_eq_true, bne_iff_ne] at hab
    rcases hab with ⟨ha0, hb0⟩
    have hbv : b.val ≠ 0 := fun h => hb0 (UScalar.eq_of_val_eq h)
    have hbpos : 0 < b.val := Nat.pos_of_ne_zero hbv
    rcases u64_div_ok 18446744073709551615#u64 b hbv with ⟨q, hdiv, hqval⟩
    rw [hdiv, result_bind_ok]
    refine ⟨decide (a > q), rfl, ?_⟩
    rw [u64_max_val] at hqval
    simp only [decide_eq_true_eq]
    change q.val < a.val ↔ a.val * b.val ≥ 2 ^ 64
    rw [hqval]
    have hiff := Nat.le_div_iff_mul_le (x := a.val) (y := 18446744073709551615) hbpos
    omega
  · have habf : ((a != 0#u64) && (b != 0#u64)) = false := Bool.eq_false_iff.mpr hab
    simp only [habf, Bool.false_eq_true, ↓reduceIte]
    refine ⟨false, rfl, ?_⟩
    simp only [Bool.false_eq_true, false_iff, not_le]
    have hzero : a.val = 0 ∨ b.val = 0 := by
      by_contra h
      push Not at h
      apply hab
      simp only [Bool.and_eq_true, bne_iff_ne]
      exact ⟨fun h0 => h.1 (by rw [h0]; rfl), fun h0 => h.2 (by rw [h0]; rfl)⟩
    rcases hzero with h0 | h0 <;> simp [h0]

/-- Theorem 9: `u64_mul_overflows` is commutative. -/
theorem u64_mul_overflows_comm (a b : U64) :
    u64_mul_overflows a b = u64_mul_overflows b a := by
  rcases u64_mul_overflows_iff a b with ⟨r1, hr1, hiff1⟩
  rcases u64_mul_overflows_iff b a with ⟨r2, hr2, hiff2⟩
  rw [hr1, hr2]
  apply congrArg ok
  apply Bool.eq_iff_iff.mpr
  rw [hiff1, hiff2, Nat.mul_comm]

/-- Theorem 10: `cmp_i64_u64` is an exact mathematical trichotomy in `ℤ` between `Int64` and `UInt64`. -/
theorem cmp_i64_u64_spec (i : I64) (u : U64) :
    ∃ r, cmp_i64_u64 i u = ok r ∧
      (r = (-1)#i32 ↔ i.val < (u.val : Int)) ∧
      (r = 0#i32 ↔ i.val = (u.val : Int)) ∧
      (r = 1#i32 ↔ i.val > (u.val : Int)) := by
  unfold cmp_i64_u64
  by_cases hneg : i < 0#i64
  · simp only [hneg, ↓reduceIte]
    have hi : i.val < 0 := hneg
    refine ⟨(-1)#i32, rfl, ?_, ?_, ?_⟩
    · simp; omega
    · constructor
      · intro h; cases h
      · intro h; omega
    · constructor
      · intro h; cases h
      · intro h; omega
  · simp only [hneg, ↓reduceIte]
    have hi : 0 ≤ i.val := by
      change ¬(i.val < 0) at hneg; omega
    have hiu := i64_reinterpret_u64_val i hi
    set iu := Pion.I64.reinterpret_as_uint64 i
    refine ⟨_, rfl, ?_, ?_, ?_⟩
    · by_cases hlt : iu < u
      · simp only [hlt, ↓reduceIte, true_iff]
        have : iu.val < u.val := hlt; omega
      · simp only [hlt, ↓reduceIte]
        have hge : u.val ≤ iu.val := by change ¬(iu.val < u.val) at hlt; omega
        by_cases hgt : iu > u
        · simp only [hgt, ↓reduceIte]
          constructor
          · intro h; cases h
          · intro h; omega
        · simp only [hgt, ↓reduceIte]
          constructor
          · intro h; cases h
          · intro h; omega
    · by_cases hlt : iu < u
      · simp only [hlt, ↓reduceIte]
        have : iu.val < u.val := hlt
        constructor
        · intro h; cases h
        · intro h; omega
      · simp only [hlt, ↓reduceIte]
        by_cases hgt : iu > u
        · simp only [hgt, ↓reduceIte]
          have : u.val < iu.val := hgt
          constructor
          · intro h; cases h
          · intro h; omega
        · simp only [hgt, ↓reduceIte, true_iff]
          have h1 : ¬(iu.val < u.val) := hlt
          have h2 : ¬(u.val < iu.val) := hgt
          omega
    · by_cases hlt : iu < u
      · simp only [hlt, ↓reduceIte]
        have : iu.val < u.val := hlt
        constructor
        · intro h; cases h
        · intro h; omega
      · simp only [hlt, ↓reduceIte]
        by_cases hgt : iu > u
        · simp only [hgt, ↓reduceIte, true_iff]
          have : u.val < iu.val := hgt; omega
        · simp only [hgt, ↓reduceIte]
          have h2 : ¬(u.val < iu.val) := hgt
          constructor
          · intro h; cases h
          · intro h; omega

/-- Theorem 11: Every negative `Int64` is strictly less than every `UInt64` (including `0UL`). -/
theorem cmp_i64_u64_neg_always_lt (i : I64) (u : U64) (hi : i.val < 0) :
    cmp_i64_u64 i u = ok (-1)#i32 := by
  rcases cmp_i64_u64_spec i u with ⟨r, hr, hlt, _, _⟩
  rw [hr, hlt.mpr (by omega)]

/-- Theorem 12: `int_to_u64` preserves the exact integer value for every non-negative `Int`. -/
theorem int_to_u64_nonneg_exact (n : I32) (hn : 0 ≤ n.val) :
    ∃ u, int_to_u64 n = ok u ∧ (u.val : Int) = n.val := by
  unfold int_to_u64
  have h64 : (Pion.I32.to_int64 n).val = n.val := by
    change (IScalar.cast .I64 n).val = n.val
    have hbv : (IScalar.cast .I64 n).bv = n.bv.signExtend 64 := rfl
    change (IScalar.cast .I64 n).bv.toInt = n.bv.toInt
    rw [hbv]
    exact BitVec.toInt_signExtend_of_le (by decide)
  refine ⟨Pion.I64.reinterpret_as_uint64 (Pion.I32.to_int64 n), rfl, ?_⟩
  rw [i64_reinterpret_u64_val _ (by omega), h64]

end CelProofs
