import Aeneas
import PionLean
import Hcl.Types
import Hcl.Funs

open Aeneas Aeneas.Std Result Pion hcl

namespace HclProofs

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i32_lt_iff (x y : Std.I32) : (x < y) ↔ (x.val < y.val) := Iff.rfl
private lemma i32_le_iff (x y : Std.I32) : (x ≤ y) ↔ (x.val ≤ y.val) := Iff.rfl

private lemma i32_beq_iff (x y : Std.I32) : (x == y) = true ↔ x.val = y.val := by
  constructor
  · intro h
    have hbv : x.bv = y.bv := by
      change (x.bv == y.bv) = true at h
      exact eq_of_beq h
    exact congrArg BitVec.toInt hbv
  · intro h
    have hbv : x.bv = y.bv := BitVec.eq_of_toInt_eq h
    change (x.bv == y.bv) = true
    rw [hbv, beq_self_eq_true]

private lemma i32_val_neg1 : ((-1)#i32 : Std.I32).val = -1 := by
  change (BitVec.ofInt 32 (-1)).toInt = -1
  rw [BitVec.toInt_ofInt, Int.bmod_def]; omega

private lemma i32_add_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 2147483647) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt ≤ 2147483647 at hhi
  omega

private lemma i32_sub_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 2147483647) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt ≤ 2147483647 at hhi
  omega

/-- Theorem 1: `hcl_effective_max_depth` computes exact stack-safe clamping `if d < 1 then 1 else min d 160` across all `Int32`. -/
lemma hcl_effective_max_depth_exact (d : Std.I32) :
    ∃ r : Std.I32, hcl_effective_max_depth d = ok r ∧
      r.val = (if d.val < 1 then 1 else min d.val 160) := by
  unfold hcl_effective_max_depth
  by_cases hlo : d < 1#i32
  · simp only [hlo, ↓reduceIte]
    have hv : d.val < 1 := (i32_lt_iff d 1#i32).mp hlo
    refine ⟨1#i32, rfl, ?_⟩
    change (1 : Int) = if d.val < 1 then 1 else min d.val 160
    simp only [hv, ↓reduceIte]
  · simp only [hlo, ↓reduceIte]
    have hvge : ¬ (d.val < 1) := fun h => hlo ((i32_lt_iff d 1#i32).mpr h)
    by_cases hhi : d > 160#i32
    · simp only [hhi, ↓reduceIte]
      have hv : 160 < d.val := (i32_lt_iff 160#i32 d).mp hhi
      refine ⟨160#i32, rfl, ?_⟩
      change (160 : Int) = if d.val < 1 then 1 else min d.val 160
      simp only [hvge, ↓reduceIte]
      symm; exact min_eq_right (by omega)
    · simp only [hhi, ↓reduceIte]
      have hvle : d.val ≤ 160 := by
        have : ¬ (160 < d.val) := fun h => hhi ((i32_lt_iff 160#i32 d).mpr h)
        omega
      refine ⟨d, rfl, ?_⟩
      simp only [hvge, ↓reduceIte]
      symm; exact min_eq_left hvle

/-- Theorem 3: `hcl_effective_max_depth` is monotonically non-decreasing across all `Int32`. -/
theorem hcl_effective_max_depth_mono (d1 d2 : Std.I32) (hle : d1.val ≤ d2.val) :
    ∃ r1 r2 : Std.I32, hcl_effective_max_depth d1 = ok r1 ∧ hcl_effective_max_depth d2 = ok r2 ∧ r1.val ≤ r2.val := by
  obtain ⟨r1, hr1, hv1⟩ := hcl_effective_max_depth_exact d1
  obtain ⟨r2, hr2, hv2⟩ := hcl_effective_max_depth_exact d2
  refine ⟨r1, r2, hr1, hr2, ?_⟩
  rw [hv1, hv2]
  split_ifs with h1 h2
  · omega
  · exact le_min (by omega) (by omega)
  · omega
  · exact min_le_min hle (le_refl _)

/-- Theorem 7: Every HCL identifier start byte is also a valid identifier continuation byte. -/
theorem is_hcl_ident_start_subset_cont (b : Std.I32)
    (h : is_hcl_ident_start b = ok true) :
    is_hcl_ident_cont b = ok true := by
  unfold is_hcl_ident_cont
  rw [h, result_bind_ok]
  rfl

/-- Theorem 8: `is_hcl_ident_start` and `is_hcl_digit` are strictly disjoint across all `Int32`. -/
theorem is_hcl_ident_start_disjoint_digit (b : Std.I32) :
    ¬ (is_hcl_ident_start b = ok true ∧ is_hcl_digit b = ok true) := by
  rintro ⟨hs, hd⟩
  unfold is_hcl_ident_start at hs
  unfold is_hcl_digit at hd
  simp only [ok.injEq, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff, i32_beq_iff] at hs hd
  change ((((65 ≤ b.val ∧ b.val ≤ 90) ∨ (97 ≤ b.val ∧ b.val ≤ 122)) ∨ b.val = 95) ∨ 128 ≤ b.val) at hs
  change 48 ≤ b.val ∧ b.val ≤ 57 at hd
  omega

/-- Theorem 10: `hcl_hex_val` always returns `-1` (invalid) or a nibble in `[0, 15]`. -/
theorem hcl_hex_val_bounds (b : Std.I32) :
    ∃ r : Std.I32, hcl_hex_val b = ok r ∧ (r.val = -1 ∨ (0 ≤ r.val ∧ r.val ≤ 15)) := by
  unfold hcl_hex_val
  by_cases h1 : ((decide (b >= 48#i32)) && (decide (b <= 57#i32))) = true
  · simp only [h1, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h1
    change 48 ≤ b.val ∧ b.val ≤ 57 at h1
    have hsub := i32_sub_val b 48#i32 (by change -2147483648 ≤ b.val - 48; omega) (by change b.val - 48 ≤ 2147483647; omega)
    change (Pion.I32.sub b 48#i32).val = b.val - 48 at hsub
    exact ⟨Pion.I32.sub b 48#i32, rfl, Or.inr ⟨by omega, by omega⟩⟩
  · have h1f := Bool.eq_false_iff.mpr h1
    simp only [h1f, Bool.false_eq_true, ↓reduceIte]
    by_cases h2 : ((decide (b >= 65#i32)) && (decide (b <= 70#i32))) = true
    · simp only [h2, ↓reduceIte]
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h2
      change 65 ≤ b.val ∧ b.val ≤ 70 at h2
      have hsub := i32_sub_val b 55#i32 (by change -2147483648 ≤ b.val - 55; omega) (by change b.val - 55 ≤ 2147483647; omega)
      change (Pion.I32.sub b 55#i32).val = b.val - 55 at hsub
      exact ⟨Pion.I32.sub b 55#i32, rfl, Or.inr ⟨by omega, by omega⟩⟩
    · have h2f := Bool.eq_false_iff.mpr h2
      simp only [h2f, Bool.false_eq_true, ↓reduceIte]
      by_cases h3 : ((decide (b >= 97#i32)) && (decide (b <= 102#i32))) = true
      · simp only [h3, ↓reduceIte]
        simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h3
        change 97 ≤ b.val ∧ b.val ≤ 102 at h3
        have hsub := i32_sub_val b 87#i32 (by change -2147483648 ≤ b.val - 87; omega) (by change b.val - 87 ≤ 2147483647; omega)
        change (Pion.I32.sub b 87#i32).val = b.val - 87 at hsub
        exact ⟨Pion.I32.sub b 87#i32, rfl, Or.inr ⟨by omega, by omega⟩⟩
      · have h3f := Bool.eq_false_iff.mpr h3
        simp only [h3f, Bool.false_eq_true, ↓reduceIte]
        exact ⟨(-1)#i32, rfl, Or.inl i32_val_neg1⟩

end HclProofs
