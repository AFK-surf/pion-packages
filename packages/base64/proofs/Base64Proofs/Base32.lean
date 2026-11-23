import Base64Proofs.Core

open Aeneas Aeneas.Std Result Pion base64

namespace Base64Proofs

/-- RFC 4648 §6/§7: exact Base32 tail bijection `b32_tail_bytes (b32_tail_symbols r) = ok r` for `r ∈ {0..4}`. -/
theorem b32_tail_roundtrip (r : Std.I32)
    (hr : r = 0#i32 ∨ r = 1#i32 ∨ r = 2#i32 ∨ r = 3#i32 ∨ r = 4#i32) :
    (do let s ← b32_tail_symbols r; b32_tail_bytes s) = ok r := by
  rcases hr with rfl | rfl | rfl | rfl | rfl <;>
    simp [b32_tail_symbols, b32_tail_bytes]

/-- RFC 4648 §6/§7: `b32_tail_bytes` rejects impossible tail lengths `1`, `3`, and `6` with `-1`. -/
theorem b32_tail_bytes_rejects_invalid :
    b32_tail_bytes 1#i32 = ok (-1)#i32 ∧
    b32_tail_bytes 3#i32 = ok (-1)#i32 ∧
    b32_tail_bytes 6#i32 = ok (-1)#i32 := by
  refine ⟨by simp [b32_tail_bytes], by simp [b32_tail_bytes], by simp [b32_tail_bytes]⟩

/-- RFC 4648 §6/§7: padded Base32 `b32_encoded_len` is always a multiple of 8. -/
theorem b32_encoded_len_pad_div8 (n : Std.I32) (h0 : 0 ≤ n.val) (hhi : n.val ≤ 1000000000) :
    ∃ L : Std.I32, b32_encoded_len n true = ok L ∧ L.val % 8 = 0 ∧ 0 ≤ L.val := by
  unfold b32_encoded_len
  have h5 : (5#i32).val = 5 := by norm_num
  have h8 : (8#i32).val = 8 := by norm_num
  have h1 : (1#i32).val = 1 := by norm_num
  have h0v : (0#i32).val = 0 := by norm_num
  obtain ⟨full, hfull, hfullv⟩ := i32_div_pos_val n 5#i32 h0 (by omega)
  rw [hfull, result_bind_ok]
  dsimp only
  rw [h5] at hfullv
  have hmul5 : (Pion.I32.mul full 5#i32).val = full.val * 5 := by
    have := i32_mul_val full 5#i32 (by rw [h5]; omega) (by rw [h5]; omega)
    rw [h5] at this; exact this
  have hremv := i32_sub_val n (Pion.I32.mul full 5#i32) (by omega) (by omega)
  set rem := Pion.I32.sub n (Pion.I32.mul full 5#i32)
  by_cases hr0 : rem = 0#i32
  · have ht0 : b32_tail_symbols rem = ok 0#i32 := by rw [hr0]; simp [b32_tail_symbols]
    rw [ht0, result_bind_ok]
    have hne : (true && (rem != 0#i32)) = false := by rw [hr0]; decide
    simp only [hne, Bool.false_eq_true, ↓reduceIte]
    have hmul8 : (Pion.I32.mul full 8#i32).val = full.val * 8 := by
      have := i32_mul_val full 8#i32 (by rw [h8]; omega) (by rw [h8]; omega)
      rw [h8] at this; exact this
    have hadd0 := i32_add_val (Pion.I32.mul full 8#i32) 0#i32 (by omega) (by omega)
    exact ⟨_, rfl, by omega, by omega⟩
  · have hne : (true && (rem != 0#i32)) = true := by
      simp only [Bool.true_and, bne_iff_ne, ne_eq]; exact hr0
    unfold b32_tail_symbols
    rw [result_bind_ok]
    simp only [hne, ↓reduceIte]
    have hadd1 := i32_add_val full 1#i32 (by omega) (by omega)
    have hmul8 : (Pion.I32.mul (Pion.I32.add full 1#i32) 8#i32).val = (full.val + 1) * 8 := by
      have := i32_mul_val (Pion.I32.add full 1#i32) 8#i32 (by rw [h8]; omega) (by rw [h8]; omega)
      rw [h8] at this; omega
    exact ⟨_, rfl, by omega, by omega⟩

/-- Exact unpadded Base32 length formula & tail decoding roundtrip for every `0 ≤ n ≤ 1_000_000_000`. -/
theorem b32_encoded_len_nopad_roundtrip (n : Std.I32) (h0 : 0 ≤ n.val) (hhi : n.val ≤ 1000000000) :
    ∃ L t : Std.I32,
      b32_encoded_len n false = ok L ∧
      b32_tail_bytes (Pion.I32.band L 7#i32) = ok t ∧
      (L.val / 8) * 5 + t.val = n.val := by
  unfold b32_encoded_len
  have h5 : (5#i32).val = 5 := by norm_num
  have h8 : (8#i32).val = 8 := by norm_num
  obtain ⟨full, hfull, hfullv⟩ := i32_div_pos_val n 5#i32 h0 (by omega)
  rw [hfull, result_bind_ok]
  dsimp only
  rw [h5] at hfullv
  have hmul5 : (Pion.I32.mul full 5#i32).val = full.val * 5 := by
    have := i32_mul_val full 5#i32 (by rw [h5]; omega) (by rw [h5]; omega)
    rw [h5] at this; exact this
  have hremv := i32_sub_val n (Pion.I32.mul full 5#i32) (by omega) (by omega)
  set rem := Pion.I32.sub n (Pion.I32.mul full 5#i32)
  have hmul8 : (Pion.I32.mul full 8#i32).val = full.val * 8 := by
    have := i32_mul_val full 8#i32 (by rw [h8]; omega) (by rw [h8]; omega)
    rw [h8] at this; exact this
  have hrem_cases : rem = 0#i32 ∨ rem = 1#i32 ∨ rem = 2#i32 ∨ rem = 3#i32 ∨ rem = 4#i32 := by
    have : rem.val = 0 ∨ rem.val = 1 ∨ rem.val = 2 ∨ rem.val = 3 ∨ rem.val = 4 := by omega
    rcases this with h | h | h | h | h
    · left; exact (iscalar_eq_iff _ _).mpr (by norm_num; omega)
    · right; left; exact (iscalar_eq_iff _ _).mpr (by norm_num; omega)
    · right; right; left; exact (iscalar_eq_iff _ _).mpr (by norm_num; omega)
    · right; right; right; left; exact (iscalar_eq_iff _ _).mpr (by norm_num; omega)
    · right; right; right; right; exact (iscalar_eq_iff _ _).mpr (by norm_num; omega)
  have hband7 : ∀ x : Std.I32, 0 ≤ x.val → (Pion.I32.band x 7#i32).val = x.val % 8 := by
    intro x hx0
    have ⟨hxnat, _⟩ := i32_toNat_of_nonneg x hx0
    have hb : (Pion.I32.band x 7#i32).bv.toNat = x.bv.toNat % 8 := by
      rw [i32_band_bv, BitVec.toNat_and]
      have h7 : (7#i32).bv.toNat = 7 := by decide
      rw [h7]
      have : (7 : Nat) = 2 ^ 3 - 1 := by norm_num
      rw [this, Nat.and_two_pow_sub_one_eq_mod]
    have hv : (Pion.I32.band x 7#i32).val = ((Pion.I32.band x 7#i32).bv.toNat : Int) := by
      change (Pion.I32.band x 7#i32).bv.toInt = _
      rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
    omega
  rcases hrem_cases with hr | hr | hr | hr | hr
  · have hrv : rem.val = 0 := by rw [hr]; norm_num
    have ht : b32_tail_symbols rem = ok 0#i32 := by rw [hr]; simp [b32_tail_symbols]
    simp only [ht, result_bind_ok, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
    have h0v : (0#i32).val = 0 := by norm_num
    have hadd := i32_add_val (Pion.I32.mul full 8#i32) 0#i32 (by omega) (by omega)
    have hb := hband7 (Pion.I32.add (Pion.I32.mul full 8#i32) 0#i32) (by omega)
    have heq : Pion.I32.band (Pion.I32.add (Pion.I32.mul full 8#i32) 0#i32) 7#i32 = 0#i32 :=
      (iscalar_eq_iff _ _).mpr (by omega)
    exact ⟨_, 0#i32, rfl, by rw [heq]; simp [b32_tail_bytes], by omega⟩
  · have hrv : rem.val = 1 := by rw [hr]; norm_num
    have ht : b32_tail_symbols rem = ok 2#i32 := by rw [hr]; simp [b32_tail_symbols]
    simp only [ht, result_bind_ok, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
    have h2v : (2#i32).val = 2 := by norm_num
    have h1v : (1#i32).val = 1 := by norm_num
    have hadd := i32_add_val (Pion.I32.mul full 8#i32) 2#i32 (by omega) (by omega)
    have hb := hband7 (Pion.I32.add (Pion.I32.mul full 8#i32) 2#i32) (by omega)
    have heq : Pion.I32.band (Pion.I32.add (Pion.I32.mul full 8#i32) 2#i32) 7#i32 = 2#i32 :=
      (iscalar_eq_iff _ _).mpr (by omega)
    exact ⟨_, 1#i32, rfl, by rw [heq]; simp [b32_tail_bytes], by omega⟩
  · have hrv : rem.val = 2 := by rw [hr]; norm_num
    have ht : b32_tail_symbols rem = ok 4#i32 := by rw [hr]; simp [b32_tail_symbols]
    simp only [ht, result_bind_ok, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
    have h4v : (4#i32).val = 4 := by norm_num
    have h2v : (2#i32).val = 2 := by norm_num
    have hadd := i32_add_val (Pion.I32.mul full 8#i32) 4#i32 (by omega) (by omega)
    have hb := hband7 (Pion.I32.add (Pion.I32.mul full 8#i32) 4#i32) (by omega)
    have heq : Pion.I32.band (Pion.I32.add (Pion.I32.mul full 8#i32) 4#i32) 7#i32 = 4#i32 :=
      (iscalar_eq_iff _ _).mpr (by omega)
    exact ⟨_, 2#i32, rfl, by rw [heq]; simp [b32_tail_bytes], by omega⟩
  · have hrv : rem.val = 3 := by rw [hr]; norm_num
    have ht : b32_tail_symbols rem = ok 5#i32 := by rw [hr]; simp [b32_tail_symbols]
    simp only [ht, result_bind_ok, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
    have h5v : (5#i32).val = 5 := by norm_num
    have h3v : (3#i32).val = 3 := by norm_num
    have hadd := i32_add_val (Pion.I32.mul full 8#i32) 5#i32 (by omega) (by omega)
    have hb := hband7 (Pion.I32.add (Pion.I32.mul full 8#i32) 5#i32) (by omega)
    have heq : Pion.I32.band (Pion.I32.add (Pion.I32.mul full 8#i32) 5#i32) 7#i32 = 5#i32 :=
      (iscalar_eq_iff _ _).mpr (by omega)
    exact ⟨_, 3#i32, rfl, by rw [heq]; simp [b32_tail_bytes], by omega⟩
  · have hrv : rem.val = 4 := by rw [hr]; norm_num
    have ht : b32_tail_symbols rem = ok 7#i32 := by rw [hr]; simp [b32_tail_symbols]
    simp only [ht, result_bind_ok, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
    have h7v : (7#i32).val = 7 := by norm_num
    have h4v : (4#i32).val = 4 := by norm_num
    have hadd := i32_add_val (Pion.I32.mul full 8#i32) 7#i32 (by omega) (by omega)
    have hb := hband7 (Pion.I32.add (Pion.I32.mul full 8#i32) 7#i32) (by omega)
    have heq : Pion.I32.band (Pion.I32.add (Pion.I32.mul full 8#i32) 7#i32) 7#i32 = 7#i32 :=
      (iscalar_eq_iff _ _).mpr (by omega)
    exact ⟨_, 4#i32, rfl, by rw [heq]; simp [b32_tail_bytes], by omega⟩

/-- Exact Base32 canonical spare-bit masks for all 4 non-empty tail lengths (`2, 4, 5, 7`). -/
theorem b32_spare_mask_spec :
    b32_spare_mask 2#i32 = ok 3#i32 ∧
    b32_spare_mask 4#i32 = ok 15#i32 ∧
    b32_spare_mask 5#i32 = ok 1#i32 ∧
    b32_spare_mask 7#i32 = ok 7#i32 := by
  refine ⟨by simp [b32_spare_mask], by simp [b32_spare_mask], by simp [b32_spare_mask], by simp [b32_spare_mask]⟩

/-- Canonical encoding invariant for Base32: for EVERY byte `x` and all 4 non-empty tail shapes
    (`rem=1` shifted by 2, `rem=2` shifted by 4, `rem=3` shifted by 1, `rem=4` shifted by 3),
    masking the encoder's last quintet with `b32_spare_mask` is ALWAYS `0`. -/
theorem b32_spare_mask_canonical_zero (x : Std.I32) :
    (Pion.I32.band ⟨x.bv <<< 2⟩ 3#i32) = 0#i32 ∧
    (Pion.I32.band ⟨x.bv <<< 4⟩ 15#i32) = 0#i32 ∧
    (Pion.I32.band ⟨x.bv <<< 1⟩ 1#i32) = 0#i32 ∧
    (Pion.I32.band ⟨x.bv <<< 3⟩ 7#i32) = 0#i32 := by
  have h0f : ∀ i : Nat, (hi : i < 32) → (0#i32).bv[i] = false := by
    intro i hi
    have h0n : (0#i32).bv.toNat = 0 := by decide
    rw [BitVec.getElem_eq_testBit_toNat, h0n]; simp
  refine ⟨?_, ?_, ?_, ?_⟩
  · apply i32_eq_of_bv; rw [i32_band_bv]; ext i hi
    rw [BitVec.getElem_and, h0f i hi]
    change ((x.bv <<< 2)[i] && (3#i32).bv[i]) = false
    rw [BitVec.getElem_shiftLeft]
    by_cases h2 : i < 2
    · simp only [h2, decide_true, Bool.not_true, Bool.false_and]
    · have hm : (3#i32).bv[i] = false := by
        have h3 : (3#i32).bv.toNat = 3 := by decide
        rw [BitVec.getElem_eq_testBit_toNat, h3]
        exact Nat.testBit_lt_two_pow (by
          have : (3 : Nat) < 2 ^ 2 := by norm_num
          have : (2 : Nat) ^ 2 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
          omega)
      simp only [hm, Bool.and_false]
  · apply i32_eq_of_bv; rw [i32_band_bv]; ext i hi
    rw [BitVec.getElem_and, h0f i hi]
    change ((x.bv <<< 4)[i] && (15#i32).bv[i]) = false
    rw [BitVec.getElem_shiftLeft]
    by_cases h4 : i < 4
    · simp only [h4, decide_true, Bool.not_true, Bool.false_and]
    · have hm : (15#i32).bv[i] = false := by
        have h15 : (15#i32).bv.toNat = 15 := by decide
        rw [BitVec.getElem_eq_testBit_toNat, h15]
        exact Nat.testBit_lt_two_pow (by
          have : (15 : Nat) < 2 ^ 4 := by norm_num
          have : (2 : Nat) ^ 4 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
          omega)
      simp only [hm, Bool.and_false]
  · apply i32_eq_of_bv; rw [i32_band_bv]; ext i hi
    rw [BitVec.getElem_and, h0f i hi]
    change ((x.bv <<< 1)[i] && (1#i32).bv[i]) = false
    rw [BitVec.getElem_shiftLeft]
    by_cases h1 : i < 1
    · simp only [h1, decide_true, Bool.not_true, Bool.false_and]
    · have hm : (1#i32).bv[i] = false := by
        have h1v : (1#i32).bv.toNat = 1 := by decide
        rw [BitVec.getElem_eq_testBit_toNat, h1v]
        exact Nat.testBit_lt_two_pow (by
          have : (1 : Nat) < 2 ^ 1 := by norm_num
          have : (2 : Nat) ^ 1 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
          omega)
      simp only [hm, Bool.and_false]
  · apply i32_eq_of_bv; rw [i32_band_bv]; ext i hi
    rw [BitVec.getElem_and, h0f i hi]
    change ((x.bv <<< 3)[i] && (7#i32).bv[i]) = false
    rw [BitVec.getElem_shiftLeft]
    by_cases h3 : i < 3
    · simp only [h3, decide_true, Bool.not_true, Bool.false_and]
    · have hm : (7#i32).bv[i] = false := by
        have h7 : (7#i32).bv.toNat = 7 := by decide
        rw [BitVec.getElem_eq_testBit_toNat, h7]
        exact Nat.testBit_lt_two_pow (by
          have : (7 : Nat) < 2 ^ 3 := by norm_num
          have : (2 : Nat) ^ 3 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
          omega)
      simp only [hm, Bool.and_false]

end Base64Proofs
