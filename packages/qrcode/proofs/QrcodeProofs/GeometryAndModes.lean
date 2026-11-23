import Aeneas
import PionLean
import Qrcode.Types
import Qrcode.Funs

open Aeneas Aeneas.Std Result Pion qrcode

namespace QrcodeProofs

private lemma i32_add_val (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  change -2147483648 ≤ a.bv.toInt + b.bv.toInt at hlo
  change a.bv.toInt + b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv + b.bv).toInt = a.bv.toInt + b.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  change -2147483648 ≤ a.bv.toInt - b.bv.toInt at hlo
  change a.bv.toInt - b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv - b.bv).toInt = a.bv.toInt - b.bv.toInt
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_mul_val (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 2147483647) :
    (Pion.I32.mul a b).val = a.val * b.val := by
  change -2147483648 ≤ a.bv.toInt * b.bv.toInt at hlo
  change a.bv.toInt * b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv * b.bv).toInt = a.bv.toInt * b.bv.toInt
  rw [BitVec.toInt_mul]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_div_nonneg (a b : Std.I32) (ha : 0 ≤ a.val) (hb : 0 < b.val) :
    ∃ q : Std.I32, Pion.I32.div a b = ok q ∧ q.val = a.val / b.val := by
  have h1 : (b.val != 0) = true := bne_iff_ne.mpr (by omega)
  have h2 : ¬ ((decide (a.val = IScalar.min .I32) && decide (b.val = -1)) = true) := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, not_and]; intro _; omega
  have hdiv : Pion.I32.div a b = ok ⟨a.bv.sdiv b.bv⟩ := by
    unfold Pion.I32.div
    change IScalar.div a b = ok ⟨a.bv.sdiv b.bv⟩
    unfold IScalar.div
    simp only [h1, h2, ↓reduceIte]
    rfl
  refine ⟨⟨a.bv.sdiv b.bv⟩, hdiv, ?_⟩
  have hab := a.hBounds; simp [IScalarTy.numBits] at hab
  have ht : a.val.tdiv b.val = a.val / b.val := Int.tdiv_eq_ediv_of_nonneg ha
  have hqlo : 0 ≤ a.val / b.val := Int.ediv_nonneg ha (by omega)
  have hqhi : a.val / b.val ≤ a.val := Int.ediv_le_self b.val ha
  change (a.bv.sdiv b.bv).toInt = a.val / b.val
  rw [BitVec.toInt_sdiv]
  change (a.val.tdiv b.val).bmod (2 ^ 32) = a.val / b.val
  rw [ht, Int.bmod_eq_of_le (by omega) (by omega)]

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private def rawModulesFormula (v : Int) : Int :=
  let base := (16 * v + 128) * v + 64
  if v ≥ 2 then
    let na := v / 7 + 2
    let r1 := base - (25 * na - 10) * na + 55
    if v ≥ 7 then r1 - 36 else r1
  else base

private lemma raw_data_modules_exact (v : Std.I32) (hlo : 1 ≤ v.val) (hhi : v.val ≤ 40) :
    ∃ m : Std.I32, raw_data_modules v = ok m ∧ m.val = rawModulesFormula v.val := by
  unfold raw_data_modules rawModulesFormula
  have hnotout : ¬ (((decide (v < 1#i32)) || (decide (v > 40#i32))) = true) := by
    simp only [Bool.or_eq_true, decide_eq_true_eq, not_or]
    exact ⟨by change ¬ (v.val < 1); omega, by change ¬ (v.val > 40); omega⟩
  simp only [hnotout]
  have c16 : (16#i32 : Std.I32).val = 16 := rfl
  have c128 : (128#i32 : Std.I32).val = 128 := rfl
  have c64 : (64#i32 : Std.I32).val = 64 := rfl
  have c2 : (2#i32 : Std.I32).val = 2 := rfl
  have c25 : (25#i32 : Std.I32).val = 25 := rfl
  have c10 : (10#i32 : Std.I32).val = 10 := rfl
  have c55 : (55#i32 : Std.I32).val = 55 := rfl
  have c36 : (36#i32 : Std.I32).val = 36 := rfl
  have hm1 : (Pion.I32.mul 16#i32 v).val = 16 * v.val := by
    have h := i32_mul_val 16#i32 v (by rw [c16]; omega) (by rw [c16]; omega)
    rw [c16] at h; exact h
  have ha1 : (Pion.I32.add (Pion.I32.mul 16#i32 v) 128#i32).val = 16 * v.val + 128 := by
    have h := i32_add_val (Pion.I32.mul 16#i32 v) 128#i32 (by omega) (by omega)
    omega
  have hm2 : (Pion.I32.mul (Pion.I32.add (Pion.I32.mul 16#i32 v) 128#i32) v).val = (16 * v.val + 128) * v.val := by
    have h := i32_mul_val (Pion.I32.add (Pion.I32.mul 16#i32 v) 128#i32) v (by nlinarith) (by nlinarith)
    rw [ha1] at h; exact h
  have hres : (Pion.I32.add (Pion.I32.mul (Pion.I32.add (Pion.I32.mul 16#i32 v) 128#i32) v) 64#i32).val =
      (16 * v.val + 128) * v.val + 64 := by
    have h := i32_add_val (Pion.I32.mul (Pion.I32.add (Pion.I32.mul 16#i32 v) 128#i32) v) 64#i32 (by nlinarith) (by nlinarith)
    omega
  by_cases hv2 : v.val ≥ 2
  · have hge2 : v ≥ 2#i32 := hv2
    simp only [hge2, hv2, ↓reduceIte]
    obtain ⟨q, hq, hqv⟩ := i32_div_nonneg v 7#i32 (by omega) (by decide)
    rw [hq, result_bind_ok]
    change q.val = v.val / 7 at hqv
    have hna : (Pion.I32.add q 2#i32).val = v.val / 7 + 2 := by
      have h := i32_add_val q 2#i32 (by omega) (by omega); omega
    have hm3 : (Pion.I32.mul 25#i32 (Pion.I32.add q 2#i32)).val = 25 * (v.val / 7 + 2) := by
      have h := i32_mul_val 25#i32 (Pion.I32.add q 2#i32) (by rw [c25]; omega) (by rw [c25]; omega)
      rw [c25, hna] at h; exact h
    have hs1 : (Pion.I32.sub (Pion.I32.mul 25#i32 (Pion.I32.add q 2#i32)) 10#i32).val = 25 * (v.val / 7 + 2) - 10 := by
      have h := i32_sub_val (Pion.I32.mul 25#i32 (Pion.I32.add q 2#i32)) 10#i32 (by omega) (by omega)
      omega
    have hm4 : (Pion.I32.mul (Pion.I32.sub (Pion.I32.mul 25#i32 (Pion.I32.add q 2#i32)) 10#i32) (Pion.I32.add q 2#i32)).val =
        (25 * (v.val / 7 + 2) - 10) * (v.val / 7 + 2) := by
      have hqbd : 0 ≤ v.val / 7 ∧ v.val / 7 ≤ 5 := ⟨by omega, by omega⟩
      have h := i32_mul_val (Pion.I32.sub (Pion.I32.mul 25#i32 (Pion.I32.add q 2#i32)) 10#i32) (Pion.I32.add q 2#i32)
        (by nlinarith) (by nlinarith)
      rw [hs1, hna] at h; exact h
    have hqbd : 0 ≤ v.val / 7 ∧ v.val / 7 ≤ 5 := ⟨by omega, by omega⟩
    have hs2 : (Pion.I32.sub (Pion.I32.add (Pion.I32.mul (Pion.I32.add (Pion.I32.mul 16#i32 v) 128#i32) v) 64#i32)
        (Pion.I32.mul (Pion.I32.sub (Pion.I32.mul 25#i32 (Pion.I32.add q 2#i32)) 10#i32) (Pion.I32.add q 2#i32))).val =
        (16 * v.val + 128) * v.val + 64 - (25 * (v.val / 7 + 2) - 10) * (v.val / 7 + 2) := by
      have h := i32_sub_val
        (Pion.I32.add (Pion.I32.mul (Pion.I32.add (Pion.I32.mul 16#i32 v) 128#i32) v) 64#i32)
        (Pion.I32.mul (Pion.I32.sub (Pion.I32.mul 25#i32 (Pion.I32.add q 2#i32)) 10#i32) (Pion.I32.add q 2#i32))
        (by nlinarith) (by nlinarith)
      rw [hres, hm4] at h; exact h
    have hr1 : (Pion.I32.add (Pion.I32.sub (Pion.I32.add (Pion.I32.mul (Pion.I32.add (Pion.I32.mul 16#i32 v) 128#i32) v) 64#i32)
        (Pion.I32.mul (Pion.I32.sub (Pion.I32.mul 25#i32 (Pion.I32.add q 2#i32)) 10#i32) (Pion.I32.add q 2#i32))) 55#i32).val =
        (16 * v.val + 128) * v.val + 64 - (25 * (v.val / 7 + 2) - 10) * (v.val / 7 + 2) + 55 := by
      have h := i32_add_val
        (Pion.I32.sub (Pion.I32.add (Pion.I32.mul (Pion.I32.add (Pion.I32.mul 16#i32 v) 128#i32) v) 64#i32)
          (Pion.I32.mul (Pion.I32.sub (Pion.I32.mul 25#i32 (Pion.I32.add q 2#i32)) 10#i32) (Pion.I32.add q 2#i32)))
        55#i32 (by nlinarith) (by nlinarith)
      rw [hs2, c55] at h; exact h
    by_cases hv7 : v.val ≥ 7
    · have hge7 : v ≥ 7#i32 := hv7
      simp only [hge7, hv7, ↓reduceIte]
      have hr2 := i32_sub_val
        (Pion.I32.add (Pion.I32.sub (Pion.I32.add (Pion.I32.mul (Pion.I32.add (Pion.I32.mul 16#i32 v) 128#i32) v) 64#i32)
          (Pion.I32.mul (Pion.I32.sub (Pion.I32.mul 25#i32 (Pion.I32.add q 2#i32)) 10#i32) (Pion.I32.add q 2#i32))) 55#i32)
        36#i32 (by nlinarith) (by nlinarith)
      rw [hr1, c36] at hr2
      exact ⟨_, rfl, hr2⟩
    · have hlt7 : ¬ (v ≥ 7#i32) := hv7
      simp only [hlt7, hv7, ↓reduceIte]
      exact ⟨_, rfl, hr1⟩
  · have hlt2 : ¬ (v ≥ 2#i32) := hv2
    simp only [hlt2, hv2, ↓reduceIte]
    exact ⟨_, rfl, hres⟩

private lemma rawModulesFormula_bounds_and_mono :
    (∀ k : Fin 40, 208 ≤ rawModulesFormula (k.val + 1) ∧ rawModulesFormula (k.val + 1) ≤ 29648) ∧
    (∀ k : Fin 39, rawModulesFormula (k.val + 1) < rawModulesFormula (k.val + 2)) := by
  decide

/-- Theorem 5: `raw_data_modules` succeeds for all 40 QR versions and stays within `[208, 29648]` bits. -/
theorem raw_data_modules_valid_bounds (v : Std.I32) (hlo : 1 ≤ v.val) (hhi : v.val ≤ 40) :
    ∃ m : Std.I32, raw_data_modules v = ok m ∧ 208 ≤ m.val ∧ m.val ≤ 29648 := by
  obtain ⟨m, hm, hmv⟩ := raw_data_modules_exact v hlo hhi
  have hk := rawModulesFormula_bounds_and_mono.1 ⟨(v.val - 1).toNat, by omega⟩
  have heq : ((v.val - 1).toNat : Int) + 1 = v.val := by omega
  rw [heq] at hk
  exact ⟨m, hm, by omega, by omega⟩

/-- Theorem 6: `raw_data_modules` is strictly increasing from version 1 (208 bits) to version 40 (29,648 bits). -/
theorem raw_data_modules_strictly_increasing (v : Std.I32) (hlo : 1 ≤ v.val) (hhi : v.val ≤ 39) :
    ∃ m1 m2 : Std.I32,
      raw_data_modules v = ok m1 ∧
      raw_data_modules (Pion.I32.add v 1#i32) = ok m2 ∧
      m1.val < m2.val := by
  have c1 : (1#i32 : Std.I32).val = 1 := rfl
  have hv1 : (Pion.I32.add v 1#i32).val = v.val + 1 := by
    have h := i32_add_val v 1#i32 (by omega) (by omega); omega
  obtain ⟨m1, hm1, hm1v⟩ := raw_data_modules_exact v hlo (by omega)
  obtain ⟨m2, hm2, hm2v⟩ := raw_data_modules_exact (Pion.I32.add v 1#i32) (by omega) (by omega)
  have hk := rawModulesFormula_bounds_and_mono.2 ⟨(v.val - 1).toNat, by omega⟩
  have heq1 : ((v.val - 1).toNat : Int) + 1 = v.val := by omega
  have heq2 : ((v.val - 1).toNat : Int) + 2 = v.val + 1 := by omega
  rw [heq1, heq2] at hk
  rw [hv1] at hm2v
  exact ⟨m1, m2, hm1, hm2, by omega⟩

/-- Theorem 7: `total_codewords v` equals `raw_data_modules v / 8` and lies in `[26, 3706]` for all `v ∈ [1, 40]`. -/
theorem total_codewords_spec (v : Std.I32) (hlo : 1 ≤ v.val) (hhi : v.val ≤ 40) :
    ∃ m cw : Std.I32,
      raw_data_modules v = ok m ∧
      total_codewords v = ok cw ∧
      cw.val = m.val / 8 ∧ 26 ≤ cw.val ∧ cw.val ≤ 3706 := by
  obtain ⟨m, hm, hm1, hm2⟩ := raw_data_modules_valid_bounds v hlo hhi
  obtain ⟨cw, hcw, hcwv⟩ := i32_div_nonneg m 8#i32 (by omega) (by decide)
  unfold total_codewords
  rw [hm, result_bind_ok, hcw, result_bind_ok]
  change cw.val = m.val / 8 at hcwv
  exact ⟨m, cw, rfl, rfl, hcwv, by omega, by omega⟩

/-- Theorem 8: `char_count_bits` is non-negative, bounded by 16, and monotonic in QR version for every mode. -/
theorem char_count_bits_mono (v1 v2 : Std.I32) (m : Mode) (hle : v1.val ≤ v2.val) :
    ∃ b1 b2 : Std.I32,
      char_count_bits v1 m = ok b1 ∧
      char_count_bits v2 m = ok b2 ∧
      0 ≤ b1.val ∧ b1.val ≤ b2.val ∧ b2.val ≤ 16 := by
  unfold char_count_bits
  by_cases h1a : v1.val ≤ 9
  · have h1a' : v1 ≤ 9#i32 := h1a
    by_cases h2a : v2.val ≤ 9
    · have h2a' : v2 ≤ 9#i32 := h2a
      cases m <;> simp only [h1a', h2a', ↓reduceIte] <;> exact ⟨_, _, rfl, rfl, by decide, by decide, by decide⟩
    · have h2a' : ¬ (v2 ≤ 9#i32) := h2a
      by_cases h2b : v2.val ≤ 26
      · have h2b' : v2 ≤ 26#i32 := h2b
        cases m <;> simp only [h1a', h2a', h2b', ↓reduceIte] <;> exact ⟨_, _, rfl, rfl, by decide, by decide, by decide⟩
      · have h2b' : ¬ (v2 ≤ 26#i32) := h2b
        cases m <;> simp only [h1a', h2a', h2b', ↓reduceIte] <;> exact ⟨_, _, rfl, rfl, by decide, by decide, by decide⟩
  · have h1a' : ¬ (v1 ≤ 9#i32) := h1a
    have h2a' : ¬ (v2 ≤ 9#i32) := by change ¬ (v2.val ≤ 9); omega
    by_cases h1b : v1.val ≤ 26
    · have h1b' : v1 ≤ 26#i32 := h1b
      by_cases h2b : v2.val ≤ 26
      · have h2b' : v2 ≤ 26#i32 := h2b
        cases m <;> simp only [h1a', h1b', h2a', h2b', ↓reduceIte] <;> exact ⟨_, _, rfl, rfl, by decide, by decide, by decide⟩
      · have h2b' : ¬ (v2 ≤ 26#i32) := h2b
        cases m <;> simp only [h1a', h1b', h2a', h2b', ↓reduceIte] <;> exact ⟨_, _, rfl, rfl, by decide, by decide, by decide⟩
    · have h1b' : ¬ (v1 ≤ 26#i32) := h1b
      have h2b' : ¬ (v2 ≤ 26#i32) := by change ¬ (v2.val ≤ 26); omega
      cases m <;> simp only [h1a', h1b', h2a', h2b', ↓reduceIte] <;> exact ⟨_, _, rfl, rfl, by decide, by decide, by decide⟩

/-- Theorem 9: `ceil_sixths` rounds any non-negative cost in 6ths of a bit up to the next multiple of 6. -/
theorem ceil_sixths_spec (cost : Std.I32) (hlo : 0 ≤ cost.val) (hhi : cost.val ≤ 1000000010) :
    ∃ r : Std.I32, ceil_sixths cost = ok r ∧
      cost.val ≤ r.val ∧ r.val < cost.val + 6 ∧ r.val % 6 = 0 := by
  unfold ceil_sixths
  have c5 : (5#i32 : Std.I32).val = 5 := rfl
  have c6 : (6#i32 : Std.I32).val = 6 := rfl
  have hadd : (Pion.I32.add cost 5#i32).val = cost.val + 5 := by
    have h := i32_add_val cost 5#i32 (by omega) (by omega); omega
  obtain ⟨q, hq, hqv⟩ := i32_div_nonneg (Pion.I32.add cost 5#i32) 6#i32 (by omega) (by decide)
  rw [hq, result_bind_ok]
  change q.val = (Pion.I32.add cost 5#i32).val / 6 at hqv
  have hmul : (Pion.I32.mul q 6#i32).val = q.val * 6 := by
    have h := i32_mul_val q 6#i32 (by rw [c6]; omega) (by rw [c6]; omega)
    rw [c6] at h; exact h
  exact ⟨Pion.I32.mul q 6#i32, rfl, by omega, by omega, by omega⟩

end QrcodeProofs
