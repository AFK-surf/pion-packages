import Http1Proofs.Core

open Aeneas Aeneas.Std Result Pion http1

namespace Http1Proofs

/-- RFC 9112: `parse_status_digits` decodes 3 ASCII digits into `0..999` exactly. -/
theorem parse_status_digits_ok (d0 d1 d2 : Std.I32)
    (h0 : 48 ≤ d0.val ∧ d0.val ≤ 57)
    (h1 : 48 ≤ d1.val ∧ d1.val ≤ 57)
    (h2 : 48 ≤ d2.val ∧ d2.val ≤ 57) :
    ∃ s : Std.I32, parse_status_digits d0 d1 d2 = ok s ∧
      s.val = (d0.val - 48) * 100 + (d1.val - 48) * 10 + (d2.val - 48) ∧
      0 ≤ s.val ∧ s.val ≤ 999 := by
  have h48 : (48#i32).val = 48 := by norm_num
  have h57 : (57#i32).val = 57 := by norm_num
  have h100 : (100#i32).val = 100 := by norm_num
  have h10 : (10#i32).val = 10 := by norm_num
  unfold parse_status_digits
  have hcond : ((((((decide (d0 < 48#i32)) || (decide (d0 > 57#i32))) ||
      (decide (d1 < 48#i32))) || (decide (d1 > 57#i32))) ||
      (decide (d2 < 48#i32))) || (decide (d2 > 57#i32))) = false := by
    simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff]
    omega
  rw [hcond]
  simp only [Bool.false_eq_true, ↓reduceIte]
  set s := Pion.I32.add (Pion.I32.add (Pion.I32.mul (Pion.I32.sub d0 48#i32) 100#i32)
    (Pion.I32.mul (Pion.I32.sub d1 48#i32) 10#i32)) (Pion.I32.sub d2 48#i32)
  have hs0 : (Pion.I32.sub d0 48#i32).val = d0.val - 48 := by
    rw [i32_sub_val, h48] <;> omega
  have hs1 : (Pion.I32.sub d1 48#i32).val = d1.val - 48 := by
    rw [i32_sub_val, h48] <;> omega
  have hs2 : (Pion.I32.sub d2 48#i32).val = d2.val - 48 := by
    rw [i32_sub_val, h48] <;> omega
  have hm0 : (Pion.I32.mul (Pion.I32.sub d0 48#i32) 100#i32).val = (d0.val - 48) * 100 := by
    rw [i32_mul_val (Pion.I32.sub d0 48#i32) 100#i32 (by rw [hs0, h100]; omega) (by rw [hs0, h100]; omega), hs0, h100]
  have hm1 : (Pion.I32.mul (Pion.I32.sub d1 48#i32) 10#i32).val = (d1.val - 48) * 10 := by
    rw [i32_mul_val (Pion.I32.sub d1 48#i32) 10#i32 (by rw [hs1, h10]; omega) (by rw [hs1, h10]; omega), hs1, h10]
  have ha0 : (Pion.I32.add (Pion.I32.mul (Pion.I32.sub d0 48#i32) 100#i32)
      (Pion.I32.mul (Pion.I32.sub d1 48#i32) 10#i32)).val =
      (d0.val - 48) * 100 + (d1.val - 48) * 10 := by
    rw [i32_add_val, hm0, hm1] <;> omega
  have hs : s.val = (d0.val - 48) * 100 + (d1.val - 48) * 10 + (d2.val - 48) := by
    change (Pion.I32.add _ _).val = _
    rw [i32_add_val, ha0, hs2] <;> omega
  exact ⟨s, rfl, hs, by omega, by omega⟩

/-- Overflow immunity and exact arithmetic for `u63_decimal_step` (Content-Length & SSE retry):
    when `acc >= 0`, `b` is an ASCII digit, and `acc * 10 + (b - 48) <= INT64_MAX`,
    it returns `res >= 0` with exact mathematical value `acc * 10 + (b - 48)` (no wraparound). -/
theorem u63_decimal_step_ok (acc : Std.I64) (b : Std.I32)
    (hacc : 0 ≤ acc.val)
    (hb : 48 ≤ b.val ∧ b.val ≤ 57)
    (hfit : acc.val * 10 + (b.val - 48) ≤ 9223372036854775807) :
    ∃ res : Std.I64, u63_decimal_step acc b = ok res ∧
      res.val = acc.val * 10 + (b.val - 48) ∧ 0 ≤ res.val := by
  have h48 : (48#i32).val = 48 := by norm_num
  have h57 : (57#i32).val = 57 := by norm_num
  have h0v : (0#i64).val = 0 := by norm_num
  have h7v : (7#i64).val = 7 := by norm_num
  have h10v : (10#i64).val = 10 := by norm_num
  unfold u63_decimal_step
  have hbc : ((decide (b < 48#i32)) || (decide (b > 57#i32))) = false := by
    simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff]; omega
  rw [hbc]
  simp only [Bool.false_eq_true, ↓reduceIte]
  have hm := max_div10_val
  have hsub : (Pion.I32.sub b 48#i32).val = b.val - 48 := by
    rw [i32_sub_val, h48] <;> omega
  have hd : (Pion.I32.to_int64 (Pion.I32.sub b 48#i32)).val = b.val - 48 := by
    rw [i32_to_int64_val, hsub]
  have hlt0 : ¬(acc < 0#i64) := fun h => by
    have : acc.val < (0#i64).val := (iscalar_lt_iff acc 0#i64).mp h; omega
  have hgt : ¬(acc > 922337203685477580#i64) := fun h => by
    have : (922337203685477580#i64).val < acc.val := (iscalar_lt_iff _ acc).mp h; omega
  have hlast : ¬((acc == 922337203685477580#i64) = true ∧
      decide (Pion.I32.to_int64 (Pion.I32.sub b 48#i32) > 7#i64) = true) := by
    rintro ⟨heq, h7⟩
    have heq' : acc.val = (922337203685477580#i64).val := (iscalar_eq_iff _ _).mp (beq_iff_eq.mp heq)
    have h7' : (7#i64).val < (Pion.I32.to_int64 (Pion.I32.sub b 48#i32)).val :=
      (iscalar_lt_iff _ _).mp (of_decide_eq_true h7)
    omega
  have hovf : (((decide (acc < 0#i64)) || (decide (acc > 922337203685477580#i64))) ||
      ((acc == 922337203685477580#i64) &&
        (decide (Pion.I32.to_int64 (Pion.I32.sub b 48#i32) > 7#i64)))) = false := by
    rw [Bool.or_eq_false_iff, Bool.or_eq_false_iff, Bool.and_eq_false_iff]
    refine ⟨⟨decide_eq_false hlt0, decide_eq_false hgt⟩, ?_⟩
    by_cases h1 : (acc == 922337203685477580#i64) = true
    · right
      exact Bool.eq_false_iff.mpr (fun h2 => hlast ⟨h1, h2⟩)
    · left; exact Bool.eq_false_iff.mpr h1
  rw [hovf]
  simp only [Bool.false_eq_true, ↓reduceIte]
  set res := Pion.I64.add (Pion.I64.mul acc 10#i64) (Pion.I32.to_int64 (Pion.I32.sub b 48#i32))
  have hmul : (Pion.I64.mul acc 10#i64).val = acc.val * 10 := by
    rw [i64_mul_val acc 10#i64 (by rw [h10v]; omega) (by rw [h10v]; omega), h10v]
  have hres : res.val = acc.val * 10 + (b.val - 48) := by
    change (Pion.I64.add _ _).val = _
    rw [i64_add_val, hmul, hd] <;> omega
  exact ⟨res, rfl, hres, by omega⟩

/-- `u63_decimal_step` rejects any overflow (`acc * 10 + (b - 48) > INT64_MAX`),
    negative accumulator, or non-digit byte with `-1L`. -/
theorem u63_decimal_step_rejects_overflow_or_invalid (acc : Std.I64) (b : Std.I32)
    (h : b.val < 48 ∨ 57 < b.val ∨ acc.val < 0 ∨ 9223372036854775807 < acc.val * 10 + (b.val - 48)) :
    u63_decimal_step acc b = ok (-1)#i64 := by
  have h48 : (48#i32).val = 48 := by norm_num
  have h57 : (57#i32).val = 57 := by norm_num
  have h0v : (0#i64).val = 0 := by norm_num
  have h7v : (7#i64).val = 7 := by norm_num
  unfold u63_decimal_step
  by_cases hbd : b.val < 48 ∨ 57 < b.val
  · have hbc : ((decide (b < 48#i32)) || (decide (b > 57#i32))) = true := by
      simp only [Bool.or_eq_true, decide_eq_true_eq, iscalar_lt_iff]; omega
    rw [hbc]; rfl
  · have hbc : ((decide (b < 48#i32)) || (decide (b > 57#i32))) = false := by
      simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff]; omega
    rw [hbc]
    simp only [Bool.false_eq_true, ↓reduceIte]
    have hm := max_div10_val
    have hsub : (Pion.I32.sub b 48#i32).val = b.val - 48 := by
      rw [i32_sub_val, h48] <;> omega
    have hd : (Pion.I32.to_int64 (Pion.I32.sub b 48#i32)).val = b.val - 48 := by
      rw [i32_to_int64_val, hsub]
    have hovf : (((decide (acc < 0#i64)) || (decide (acc > 922337203685477580#i64))) ||
        ((acc == 922337203685477580#i64) &&
          (decide (Pion.I32.to_int64 (Pion.I32.sub b 48#i32) > 7#i64)))) = true := by
      rw [Bool.or_eq_true, Bool.or_eq_true, Bool.and_eq_true]
      by_cases hneg : acc.val < 0
      · left; left; exact decide_eq_true ((iscalar_lt_iff acc 0#i64).mpr (by omega))
      · by_cases hgt : 922337203685477580 < acc.val
        · left; right; exact decide_eq_true ((iscalar_lt_iff _ acc).mpr (by omega))
        · right
          refine ⟨beq_iff_eq.mpr ((iscalar_eq_iff _ _).mpr (by omega)),
            decide_eq_true ((iscalar_lt_iff _ _).mpr (by omega))⟩
    rw [hovf]; rfl

/-- Helper: for `0 <= size <= 576460752303423487` and `0 <= v <= 15`,
    `(size << 4) | v` equals `size * 16 + v` with zero signed 64-bit wraparound. -/
lemma i64_shl4_bor_eq (size : Std.I64) (v : Std.I32)
    (hsize0 : 0 ≤ size.val) (hsize1 : size.val ≤ 576460752303423487)
    (hv0 : 0 ≤ v.val) (hv1 : v.val ≤ 15) :
    ∃ r : Std.I64,
      (do let t ← Pion.I64.shl_i32 size 4#i32; ok (Pion.I64.bor t (Pion.I32.to_int64 v))) = ok r ∧
      r.val = size.val * 16 + v.val := by
  have hshl : Pion.I64.shl_i32 size 4#i32 = ok (⟨size.bv <<< (4 : Nat)⟩ : Std.I64) := by
    unfold Pion.I64.shl_i32
    have h4v : (4#i32).val = 4 := by norm_num
    simp only [h4v]
    rfl
  rw [hshl, result_bind_ok]
  refine ⟨Pion.I64.bor (⟨size.bv <<< (4 : Nat)⟩ : Std.I64) (Pion.I32.to_int64 v), rfl, ?_⟩
  have hbv_size : size.bv.toNat = size.val.toNat := by
    have hti := BitVec.toInt_eq_toNat_cond size.bv
    have hsb : size.bv.toInt = size.val := rfl
    have hlt : 2 * size.bv.toNat < 2 ^ 64 := by
      by_contra hge
      push Not at hge
      rw [ite_eq_right (by omega)] at hti
      have hpow : (2 : Int) ^ 64 = 18446744073709551616 := by norm_num
      have hbn : size.bv.toNat < 2 ^ 64 := size.bv.isLt
      omega
    rw [ite_eq_left hlt] at hti
    omega
  have hvt : (Pion.I32.to_int64 v).val = v.val := i32_to_int64_val v
  have hbv_v : (Pion.I32.to_int64 v).bv.toNat = v.val.toNat := by
    have hti := BitVec.toInt_eq_toNat_cond (Pion.I32.to_int64 v).bv
    have hsb : (Pion.I32.to_int64 v).bv.toInt = v.val := hvt
    have hlt : 2 * (Pion.I32.to_int64 v).bv.toNat < 2 ^ 64 := by
      by_contra hge
      push Not at hge
      rw [ite_eq_right (by omega)] at hti
      have hpow : (2 : Int) ^ 64 = 18446744073709551616 := by norm_num
      have hbn : (Pion.I32.to_int64 v).bv.toNat < 2 ^ 64 := (Pion.I32.to_int64 v).bv.isLt
      omega
    rw [ite_eq_left hlt] at hti
    omega
  have hshift_nat : (size.bv <<< (4 : Nat)).toNat = size.val.toNat * 16 := by
    rw [BitVec.toNat_shiftLeft, hbv_size]
    have hlt : size.val.toNat * 16 < 2 ^ 64 := by omega
    rw [Nat.shiftLeft_eq]
    have : (2 : Nat) ^ 4 = 16 := by norm_num
    rw [this, Nat.mod_eq_of_lt hlt]
  have hbor_nat : ((size.bv <<< (4 : Nat)) ||| (Pion.I32.to_int64 v).bv).toNat =
      size.val.toNat * 16 + v.val.toNat := by
    rw [BitVec.toNat_or, hshift_nat, hbv_v]
    have hvn : v.val.toNat < 16 := by omega
    apply Nat.eq_of_testBit_eq
    intro k
    rw [Nat.testBit_or]
    by_cases hk : k < 4
    · have ha0 : (size.val.toNat * 16).testBit k = false := by
        rw [Nat.testBit_eq_decide_div_mod_eq, decide_eq_false_iff_not]
        rcases (by omega : k = 0 ∨ k = 1 ∨ k = 2 ∨ k = 3) with rfl | rfl | rfl | rfl <;> omega
      have hadd : (size.val.toNat * 16 + v.val.toNat).testBit k = v.val.toNat.testBit k := by
        rw [Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
        have hmod : (size.val.toNat * 16 + v.val.toNat) / 2 ^ k % 2 = v.val.toNat / 2 ^ k % 2 := by
          rcases (by omega : k = 0 ∨ k = 1 ∨ k = 2 ∨ k = 3) with rfl | rfl | rfl | rfl <;> omega
        rw [hmod]
      rw [ha0, Bool.false_or, hadd]
    · have hb0 : v.val.toNat.testBit k = false := by
        rw [Nat.testBit_eq_decide_div_mod_eq, decide_eq_false_iff_not]
        have hpow : 16 ≤ 2 ^ k := by
          have : 2 ^ 4 ≤ 2 ^ k := Nat.pow_le_pow_right (by norm_num) (by omega)
          omega
        have : v.val.toNat / 2 ^ k = 0 := Nat.div_eq_of_lt (by omega)
        omega
      have hadd : (size.val.toNat * 16 + v.val.toNat).testBit k = (size.val.toNat * 16).testBit k := by
        rw [Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
        have hpow : 2 ^ k = 16 * 2 ^ (k - 4) := by
          have h1 : 2 ^ 4 = 16 := by norm_num
          rw [← h1, ← Nat.pow_add]
          congr 1; omega
        rw [hpow, ← Nat.div_div_eq_div_mul, ← Nat.div_div_eq_div_mul]
        have h1 : (size.val.toNat * 16 + v.val.toNat) / 16 = size.val.toNat := by omega
        have h2 : (size.val.toNat * 16) / 16 = size.val.toNat := by omega
        rw [h1, h2]
      rw [hb0, Bool.or_false, hadd]
  change ((size.bv <<< (4 : Nat)) ||| (Pion.I32.to_int64 v).bv).toInt = size.val * 16 + v.val
  rw [BitVec.toInt_eq_toNat_cond, hbor_nat]
  have hlt : 2 * (size.val.toNat * 16 + v.val.toNat) < 2 ^ 64 := by
    have : (2 : Nat) ^ 64 = 18446744073709551616 := by norm_num
    omega
  rw [ite_eq_left hlt]
  omega

/-- Overflow immunity and exact arithmetic for `chunk_size_hex_step`:
    for `0 <= digits < 16`, `0 <= v <= 15`, `0 <= size`, and `size * 16 + v <= INT64_MAX`,
    it returns `res >= 0` with exact value `size * 16 + v` (zero signed 64-bit wraparound). -/
theorem chunk_size_hex_step_ok (size : Std.I64) (digits v : Std.I32)
    (hsize : 0 ≤ size.val)
    (hdig : 0 ≤ digits.val ∧ digits.val < 16)
    (hv : 0 ≤ v.val ∧ v.val ≤ 15)
    (hfit : size.val * 16 + v.val ≤ 9223372036854775807) :
    ∃ res : Std.I64, chunk_size_hex_step size digits v = ok res ∧
      res.val = size.val * 16 + v.val ∧ 0 ≤ res.val := by
  have h0i : (0#i32).val = 0 := by norm_num
  have h16i : (16#i32).val = 16 := by norm_num
  have h15i : (15#i32).val = 15 := by norm_num
  have h0l : (0#i64).val = 0 := by norm_num
  unfold chunk_size_hex_step
  have hc1 : ((((decide (digits < 0#i32)) || (decide (digits ≥ 16#i32))) ||
      (decide (v < 0#i32))) || (decide (v > 15#i32))) = false := by
    simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff, iscalar_le_iff]; omega
  rw [hc1]
  simp only [Bool.false_eq_true, ↓reduceIte]
  have hm := max_div16_val
  have hlt0 : ¬(size < 0#i64) := fun h => by
    have : size.val < (0#i64).val := (iscalar_lt_iff size 0#i64).mp h; omega
  have hgt : ¬(size > 576460752303423487#i64) := fun h => by
    have : (576460752303423487#i64).val < size.val := (iscalar_lt_iff _ size).mp h; omega
  have hvgt : ¬(v > 15#i32) := fun h => by
    have : (15#i32).val < v.val := (iscalar_lt_iff _ v).mp h; omega
  have hc2 : (((decide (size < 0#i64)) || (decide (size > 576460752303423487#i64))) ||
      ((size == 576460752303423487#i64) && (decide (v > 15#i32)))) = false := by
    rw [Bool.or_eq_false_iff, Bool.or_eq_false_iff, Bool.and_eq_false_iff]
    exact ⟨⟨decide_eq_false hlt0, decide_eq_false hgt⟩, Or.inr (decide_eq_false hvgt)⟩
  rw [hc2]
  simp only [Bool.false_eq_true, ↓reduceIte]
  obtain ⟨r, hr, hrv⟩ := i64_shl4_bor_eq size v hsize (by omega) hv.1 hv.2
  have hshl : Pion.I64.shl_i32 size 4#i32 = ok (⟨size.bv <<< (4 : Nat)⟩ : Std.I64) := by
    unfold Pion.I64.shl_i32
    have h4v : (4#i32).val = 4 := by norm_num
    simp only [h4v]
    rfl
  rw [hshl, result_bind_ok] at hr ⊢
  have heq : Pion.I64.bor (⟨size.bv <<< (4 : Nat)⟩ : Std.I64) (Pion.I32.to_int64 v) = r :=
    result_ok_inj hr
  rw [heq]
  exact ⟨r, rfl, hrv, by omega⟩

/-- `chunk_size_hex_step` rejects any overflow (`size > (INT64_MAX - 15) / 16`) with `-2L` (`ChunkTooLarge`). -/
theorem chunk_size_hex_step_rejects_overflow (size : Std.I64) (digits v : Std.I32)
    (hdig : 0 ≤ digits.val ∧ digits.val < 16)
    (hv : 0 ≤ v.val ∧ v.val ≤ 15)
    (hovf : 576460752303423487 < size.val) :
    chunk_size_hex_step size digits v = ok (-2)#i64 := by
  have h0i : (0#i32).val = 0 := by norm_num
  have h16i : (16#i32).val = 16 := by norm_num
  have h15i : (15#i32).val = 15 := by norm_num
  unfold chunk_size_hex_step
  have hc1 : ((((decide (digits < 0#i32)) || (decide (digits ≥ 16#i32))) ||
      (decide (v < 0#i32))) || (decide (v > 15#i32))) = false := by
    simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff, iscalar_le_iff]; omega
  rw [hc1]
  simp only [Bool.false_eq_true, ↓reduceIte]
  have hm := max_div16_val
  have hgt : size > 576460752303423487#i64 := (iscalar_lt_iff _ size).mpr (by omega)
  have hc2 : (((decide (size < 0#i64)) || (decide (size > 576460752303423487#i64))) ||
      ((size == 576460752303423487#i64) && (decide (v > 15#i32)))) = true := by
    rw [Bool.or_eq_true, Bool.or_eq_true]
    exact Or.inl (Or.inr (decide_eq_true hgt))
  rw [hc2]; rfl

end Http1Proofs
