import Aeneas
import PionLean
import Bson.Types
import Bson.Funs

open Aeneas Aeneas.Std Result Pion bson

namespace BsonProofs

private lemma result_bind_ok' {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma u64_lt_iff (x y : Std.U64) : (x < y) ↔ (x.val < y.val) := Iff.rfl

private lemma u64_beq_iff (x y : Std.U64) : (x == y) = true ↔ x.val = y.val := by
  constructor
  · intro h
    have hbv : x.bv = y.bv := by
      change (x.bv == y.bv) = true at h
      exact eq_of_beq h
    exact congrArg BitVec.toNat hbv
  · intro h
    have hbv : x.bv = y.bv := BitVec.eq_of_toNat_eq h
    change (x.bv == y.bv) = true
    rw [hbv, beq_self_eq_true]

private lemma u64_bne_iff (x y : Std.U64) : (x != y) = true ↔ x.val ≠ y.val := by
  simp only [bne_iff_ne, ne_eq]
  exact ⟨fun h hv => h (UScalar.eq_of_val_eq hv), fun h heq => h (congrArg UScalar.val heq)⟩

private lemma u64_shr58 (x : Std.U64) : Pion.U64.shr x 58#u64 = ok ⟨x.bv >>> 58⟩ := by
  unfold Pion.U64.shr; rfl

private lemma u64_shr61 (x : Std.U64) : Pion.U64.shr x 61#u64 = ok ⟨x.bv >>> 61⟩ := by
  unfold Pion.U64.shr; rfl

private lemma u64_shr63 (x : Std.U64) : Pion.U64.shr x 63#u64 = ok ⟨x.bv >>> 63⟩ := by
  unfold Pion.U64.shr; rfl

private lemma i32_le_iff' (x y : Std.I32) : (x ≤ y) ↔ (x.val ≤ y.val) := Iff.rfl

private lemma i32_add_val' (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 2147483647) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt ≤ 2147483647 at hhi
  omega

/-- Theorem 13: `u128_gt` implements the exact 128-bit unsigned ordering `a_hi * 2^64 + a_lo > b_hi * 2^64 + b_lo`. -/
theorem u128_gt_iff_nat (a_hi a_lo b_hi b_lo : Std.U64) :
    u128_gt a_hi a_lo b_hi b_lo = ok true ↔
      a_hi.val * (2 ^ 64) + a_lo.val > b_hi.val * (2 ^ 64) + b_lo.val := by
  unfold u128_gt
  have halo : a_lo.val < 2 ^ 64 := a_lo.bv.isLt
  have hblo : b_lo.val < 2 ^ 64 := b_lo.bv.isLt
  by_cases heq : a_hi = b_hi
  · subst heq
    simp only [ne_eq, not_true_eq_false, ↓reduceIte, ok.injEq, decide_eq_true_eq, gt_iff_lt, u64_lt_iff]
    omega
  · simp only [ne_eq, heq, not_false_eq_true, ↓reduceIte, ok.injEq, decide_eq_true_eq, gt_iff_lt, u64_lt_iff]
    have hvne : a_hi.val ≠ b_hi.val := fun h => heq (UScalar.eq_of_val_eq h)
    constructor <;> (intro h; omega)

/-- Theorem 18: `ascii_lower` is idempotent across all `Int32`. -/
theorem ascii_lower_idempotent (c : Std.I32) :
    (do let r ← ascii_lower c; ascii_lower r) = ascii_lower c := by
  unfold ascii_lower
  by_cases h : ((decide (c >= 65#i32)) && (decide (c <= 90#i32))) = true
  · simp only [h, ↓reduceIte, result_bind_ok']
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
    change 65 ≤ c.val ∧ c.val ≤ 90 at h
    set cl := Pion.I32.add c 32#i32
    have hcl : cl.val = c.val + 32 :=
      i32_add_val' c 32#i32 (by change -2147483648 ≤ c.val + 32; omega) (by change c.val + 32 ≤ 2147483647; omega)
    have hf : ((decide (cl >= 65#i32)) && (decide (cl <= 90#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h2
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h2
      change 65 ≤ cl.val ∧ cl.val ≤ 90 at h2; omega
    simp only [hf, Bool.false_eq_true, ↓reduceIte]
  · have hf := Bool.eq_false_iff.mpr h
    simp only [hf, Bool.false_eq_true, ↓reduceIte, result_bind_ok']

/-- Theorem 23: IEEE 754-2008 §3.5.2 non-canonical BID (`comb2 = 3`, finite) always decodes to zero for ANY `lo : U64`. -/
theorem dec128_noncanonical_comb3_is_zero (hi lo : Std.U64)
    (hnotnan : dec128_hi_is_nan hi = ok false)
    (hnotinf : dec128_hi_is_infinite hi = ok false)
    (hcomb3 : Pion.U64.band ⟨hi.bv >>> 61⟩ 3#u64 = 3#u64) :
    dec128_pair_is_zero hi lo = ok true := by
  unfold dec128_hi_is_nan at hnotnan
  unfold dec128_hi_is_infinite at hnotinf
  unfold dec128_pair_is_zero
  rw [u64_shr58 hi, result_bind_ok'] at hnotnan hnotinf ⊢
  simp only [ok.injEq] at hnotnan hnotinf
  simp only [hnotnan, hnotinf, Bool.or_self, Bool.false_eq_true, ↓reduceIte]
  rw [u64_shr61 hi, result_bind_ok']
  simp only [hcomb3, ↓reduceIte]

end BsonProofs
