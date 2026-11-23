import Base64Proofs.Core

open Aeneas Aeneas.Std Result Pion base64

namespace Base64Proofs

private lemma i32_shl_const (x : Std.I32) (k : Std.I32) (h0 : 0 ≤ k.val) (h32 : k.val < 32) :
    Pion.I32.shl x k = ok (⟨x.bv <<< k.val.toNat⟩ : Std.I32) := by
  unfold Pion.I32.shl
  have hc : 0 ≤ k.val ∧ k.val < 32 := ⟨h0, h32⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma i32_bit_zero_above (x : Std.I32) (k : Nat) (h0 : 0 ≤ x.val) (hlt : x.val < 2 ^ k)
    (i : Nat) (hi : i < 32) (hik : k ≤ i) :
    x.bv[i] = false := by
  have ⟨hnat, _⟩ := i32_toNat_of_nonneg x h0
  rw [BitVec.getElem_eq_testBit_toNat, hnat]
  have h1 : x.val.toNat < 2 ^ k := by
    have : (x.val.toNat : Int) = x.val := Int.toNat_of_nonneg h0
    have : ((2 ^ k : Nat) : Int) = (2 : Int) ^ k := by norm_cast
    omega
  exact Nat.testBit_lt_two_pow (by
    have h2 : (2 : Nat) ^ k ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) hik
    omega)

/-- `b64_pack3` of three bytes `0..255` always yields a 24-bit integer in `[0, 2^24)`. -/
theorem b64_pack3_bounds (b0 b1 b2 : Std.I32)
    (h0 : 0 ≤ b0.val ∧ b0.val < 256)
    (h1 : 0 ≤ b1.val ∧ b1.val < 256)
    (h2 : 0 ≤ b2.val ∧ b2.val < 256) :
    ∃ v : Std.I32, b64_pack3 b0 b1 b2 = ok v ∧ 0 ≤ v.val ∧ v.val < 16777216 := by
  unfold b64_pack3
  rw [i32_shl_const b0 16#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i32_shl_const b1 8#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h16 : (16#i32).val.toNat = 16 := by norm_num
  have h8 : (8#i32).val.toNat = 8 := by norm_num
  rw [h16, h8]
  refine ⟨_, rfl, ?_⟩
  have ⟨hn0, _⟩ := i32_toNat_of_nonneg b0 h0.1
  have ⟨hn1, _⟩ := i32_toNat_of_nonneg b1 h1.1
  have ⟨hn2, _⟩ := i32_toNat_of_nonneg b2 h2.1
  have hs0 : (b0.bv <<< 16).toNat < 2 ^ 24 := by
    rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq, Nat.mod_eq_of_lt (by omega)]; omega
  have hs1 : (b1.bv <<< 8).toNat < 2 ^ 24 := by
    rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq, Nat.mod_eq_of_lt (by omega)]; omega
  have hs2 : b2.bv.toNat < 2 ^ 24 := by omega
  have h_or : ∀ (x y : BitVec IScalarTy.I32.numBits), x.toNat < 2 ^ 24 → y.toNat < 2 ^ 24 → (x ||| y).toNat < 2 ^ 24 := by
    intro x y hx hy; rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow (n := 24) hx hy
  set v : Std.I32 := Pion.I32.bor (Pion.I32.bor ⟨b0.bv <<< 16⟩ ⟨b1.bv <<< 8⟩) b2
  have hv_lt : v.bv.toNat < 2 ^ 24 := h_or _ _ (h_or _ _ hs0 hs1) hs2
  have hval : v.val = (v.bv.toNat : Int) := by
    change v.bv.toInt = _; rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
  omega

/-- Exact 24-bit Base64 3-byte ↔ 4-sextet roundtrip: splitting `b64_pack3 b0 b1 b2` into 4 sextets
    and repacking via `b64_pack4_sextets` recovers the exact 24-bit value `v`. -/
theorem b64_pack3_pack4_roundtrip (b0 b1 b2 : Std.I32)
    (h0 : 0 ≤ b0.val ∧ b0.val < 256)
    (h1 : 0 ≤ b1.val ∧ b1.val < 256)
    (h2 : 0 ≤ b2.val ∧ b2.val < 256) :
    ∃ v : Std.I32, b64_pack3 b0 b1 b2 = ok v ∧
      b64_pack4_sextets
        ⟨v.bv.sshiftRight 18⟩
        (Pion.I32.band ⟨v.bv.sshiftRight 12⟩ 63#i32)
        (Pion.I32.band ⟨v.bv.sshiftRight 6⟩ 63#i32)
        (Pion.I32.band v 63#i32) = ok v := by
  obtain ⟨v, hv, hv0, hvhi⟩ := b64_pack3_bounds b0 b1 b2 h0 h1 h2
  refine ⟨v, hv, ?_⟩
  unfold b64_pack4_sextets
  rw [i32_shl_const _ 18#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i32_shl_const _ 12#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i32_shl_const _ 6#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h18 : (18#i32).val.toNat = 18 := by norm_num
  have h12 : (12#i32).val.toNat = 12 := by norm_num
  have h6 : (6#i32).val.toNat = 6 := by norm_num
  rw [h18, h12, h6]
  congr 1
  apply i32_eq_of_bv
  have h63_true : ∀ j : Nat, (hj : j < 32) → j < 6 → (63#i32).bv[j] = true := by
    intro j hj hj6
    rw [BitVec.getElem_eq_testBit_toNat]
    rcases (by omega : j = 0 ∨ j = 1 ∨ j = 2 ∨ j = 3 ∨ j = 4 ∨ j = 5) with
      rfl | rfl | rfl | rfl | rfl | rfl <;> decide
  have h63_false : ∀ j : Nat, (hj : j < 32) → 6 ≤ j → (63#i32).bv[j] = false := by
    intro j hj hj6
    have h63 : (63#i32).bv.toNat = 63 := by decide
    rw [BitVec.getElem_eq_testBit_toNat, h63]
    exact Nat.testBit_lt_two_pow (by
      have : (63 : Nat) < 2 ^ 6 := by norm_num
      have : (2 : Nat) ^ 6 ≤ 2 ^ j := Nat.pow_le_pow_right (by omega) hj6
      omega)
  ext i hi
  simp only [i32_bor_bv, BitVec.getElem_or]
  change ((((v.bv.sshiftRight 18 <<< 18)[i] ||
      ((Pion.I32.band ⟨v.bv.sshiftRight 12⟩ 63#i32).bv <<< 12)[i]) ||
      ((Pion.I32.band ⟨v.bv.sshiftRight 6⟩ 63#i32).bv <<< 6)[i]) ||
      (Pion.I32.band v 63#i32).bv[i]) = v.bv[i]
  by_cases hi6 : i < 6
  · have ha : (v.bv.sshiftRight 18 <<< 18)[i] = false := by
      rw [BitVec.getElem_shiftLeft]; simp only [show i < 18 by omega, decide_true, Bool.not_true, Bool.false_and]
    have hb : ((Pion.I32.band ⟨v.bv.sshiftRight 12⟩ 63#i32).bv <<< 12)[i] = false := by
      rw [BitVec.getElem_shiftLeft]; simp only [show i < 12 by omega, decide_true, Bool.not_true, Bool.false_and]
    have hc : ((Pion.I32.band ⟨v.bv.sshiftRight 6⟩ 63#i32).bv <<< 6)[i] = false := by
      rw [BitVec.getElem_shiftLeft]; simp only [hi6, decide_true, Bool.not_true, Bool.false_and]
    have hd : (Pion.I32.band v 63#i32).bv[i] = v.bv[i] := by
      rw [i32_band_bv, BitVec.getElem_and, h63_true i hi hi6, Bool.and_true]
    simp only [ha, hb, hc, hd, Bool.false_or]
  · by_cases hi12 : i < 12
    · have ha : (v.bv.sshiftRight 18 <<< 18)[i] = false := by
        rw [BitVec.getElem_shiftLeft]; simp only [show i < 18 by omega, decide_true, Bool.not_true, Bool.false_and]
      have hb : ((Pion.I32.band ⟨v.bv.sshiftRight 12⟩ 63#i32).bv <<< 12)[i] = false := by
        rw [BitVec.getElem_shiftLeft]; simp only [hi12, decide_true, Bool.not_true, Bool.false_and]
      have hd : (Pion.I32.band v 63#i32).bv[i] = false := by
        rw [i32_band_bv, BitVec.getElem_and, h63_false i hi (by omega), Bool.and_false]
      have hc : ((Pion.I32.band ⟨v.bv.sshiftRight 6⟩ 63#i32).bv <<< 6)[i] = v.bv[i] := by
        rw [BitVec.getElem_shiftLeft]; simp only [hi6, decide_false, Bool.not_false, Bool.true_and]
        rw [i32_band_bv, BitVec.getElem_and, h63_true (i - 6) (by omega) (by omega), Bool.and_true]
        change (v.bv.sshiftRight 6)[i - 6] = v.bv[i]
        rw [BitVec.getElem_sshiftRight, dite_eq_left (by omega)]
        congr 1; omega
      simp only [ha, hb, hc, hd, Bool.false_or, Bool.or_false]
    · by_cases hi18 : i < 18
      · have ha : (v.bv.sshiftRight 18 <<< 18)[i] = false := by
          rw [BitVec.getElem_shiftLeft]; simp only [hi18, decide_true, Bool.not_true, Bool.false_and]
        have hc : ((Pion.I32.band ⟨v.bv.sshiftRight 6⟩ 63#i32).bv <<< 6)[i] = false := by
          rw [BitVec.getElem_shiftLeft]; simp only [hi6, decide_false, Bool.not_false, Bool.true_and]
          rw [i32_band_bv, BitVec.getElem_and, h63_false (i - 6) (by omega) (by omega), Bool.and_false]
        have hd : (Pion.I32.band v 63#i32).bv[i] = false := by
          rw [i32_band_bv, BitVec.getElem_and, h63_false i hi (by omega), Bool.and_false]
        have hb : ((Pion.I32.band ⟨v.bv.sshiftRight 12⟩ 63#i32).bv <<< 12)[i] = v.bv[i] := by
          rw [BitVec.getElem_shiftLeft]; simp only [hi12, decide_false, Bool.not_false, Bool.true_and]
          rw [i32_band_bv, BitVec.getElem_and, h63_true (i - 12) (by omega) (by omega), Bool.and_true]
          change (v.bv.sshiftRight 12)[i - 12] = v.bv[i]
          rw [BitVec.getElem_sshiftRight, dite_eq_left (by omega)]
          congr 1; omega
        simp only [ha, hb, hc, hd, Bool.false_or, Bool.or_false]
      · by_cases hi24 : i < 24
        · have hb : ((Pion.I32.band ⟨v.bv.sshiftRight 12⟩ 63#i32).bv <<< 12)[i] = false := by
            rw [BitVec.getElem_shiftLeft]; simp only [hi12, decide_false, Bool.not_false, Bool.true_and]
            rw [i32_band_bv, BitVec.getElem_and, h63_false (i - 12) (by omega) (by omega), Bool.and_false]
          have hc : ((Pion.I32.band ⟨v.bv.sshiftRight 6⟩ 63#i32).bv <<< 6)[i] = false := by
            rw [BitVec.getElem_shiftLeft]; simp only [hi6, decide_false, Bool.not_false, Bool.true_and]
            rw [i32_band_bv, BitVec.getElem_and, h63_false (i - 6) (by omega) (by omega), Bool.and_false]
          have hd : (Pion.I32.band v 63#i32).bv[i] = false := by
            rw [i32_band_bv, BitVec.getElem_and, h63_false i hi (by omega), Bool.and_false]
          have ha : (v.bv.sshiftRight 18 <<< 18)[i] = v.bv[i] := by
            rw [BitVec.getElem_shiftLeft]; simp only [hi18, decide_false, Bool.not_false, Bool.true_and]
            rw [BitVec.getElem_sshiftRight, dite_eq_left (by omega)]
            congr 1; omega
          simp only [ha, hb, hc, hd, Bool.or_false]
        · have hv0b : v.bv[i] = false := i32_bit_zero_above v 24 hv0 hvhi i hi (by omega)
          have ha : (v.bv.sshiftRight 18 <<< 18)[i] = false := by
            rw [BitVec.getElem_shiftLeft]; simp only [hi18, decide_false, Bool.not_false, Bool.true_and]
            rw [BitVec.getElem_sshiftRight]
            by_cases hlt32 : 18 + (i - 18) < 32
            · rw [dite_eq_left hlt32]; exact i32_bit_zero_above v 24 hv0 hvhi _ hlt32 (by omega)
            · rw [dite_eq_right hlt32]
              have ⟨_, hlt31⟩ := i32_toNat_of_nonneg v hv0
              rw [BitVec.msb_eq_decide]; simp only [decide_eq_false_iff_not]; omega
          have hb : ((Pion.I32.band ⟨v.bv.sshiftRight 12⟩ 63#i32).bv <<< 12)[i] = false := by
            rw [BitVec.getElem_shiftLeft]; simp only [hi12, decide_false, Bool.not_false, Bool.true_and]
            rw [i32_band_bv, BitVec.getElem_and, h63_false (i - 12) (by omega) (by omega), Bool.and_false]
          have hc : ((Pion.I32.band ⟨v.bv.sshiftRight 6⟩ 63#i32).bv <<< 6)[i] = false := by
            rw [BitVec.getElem_shiftLeft]; simp only [hi6, decide_false, Bool.not_false, Bool.true_and]
            rw [i32_band_bv, BitVec.getElem_and, h63_false (i - 6) (by omega) (by omega), Bool.and_false]
          have hd : (Pion.I32.band v 63#i32).bv[i] = false := by
            rw [i32_band_bv, BitVec.getElem_and, h63_false i hi (by omega), Bool.and_false]
          simp only [ha, hb, hc, hd, hv0b, Bool.or_false]

/-- Branchless hot-path error check soundness: if ANY of the 4 Base64 sextets is `-1` (invalid),
    `b64_pack4_sextets` produces a strictly negative `Int32` (`v < 0`), so `if v < 0` never misses an error. -/
theorem b64_pack4_neg_if_invalid (s0 s1 s2 s3 : Std.I32)
    (hbad : s0 = (-1)#i32 ∨ s1 = (-1)#i32 ∨ s2 = (-1)#i32 ∨ s3 = (-1)#i32) :
    ∃ v : Std.I32, b64_pack4_sextets s0 s1 s2 s3 = ok v ∧ v.val < 0 := by
  unfold b64_pack4_sextets
  rw [i32_shl_const s0 18#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i32_shl_const s1 12#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i32_shl_const s2 6#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h18 : (18#i32).val.toNat = 18 := by norm_num
  have h12 : (12#i32).val.toNat = 12 := by norm_num
  have h6 : (6#i32).val.toNat = 6 := by norm_num
  rw [h18, h12, h6]
  refine ⟨_, rfl, ?_⟩
  set v : Std.I32 := Pion.I32.bor (Pion.I32.bor (Pion.I32.bor ⟨s0.bv <<< 18⟩ ⟨s1.bv <<< 12⟩) ⟨s2.bv <<< 6⟩) s3
  have hbit31 : v.bv[31] = true := by
    simp only [v, i32_bor_bv, BitVec.getElem_or]
    rcases hbad with rfl | rfl | rfl | rfl
    · simp only [show ((-1)#i32.bv <<< 18)[31] = true by rw [BitVec.getElem_eq_testBit_toNat]; decide, Bool.true_or]
    · simp only [show ((-1)#i32.bv <<< 12)[31] = true by rw [BitVec.getElem_eq_testBit_toNat]; decide, Bool.or_true, Bool.true_or]
    · simp only [show ((-1)#i32.bv <<< 6)[31] = true by rw [BitVec.getElem_eq_testBit_toNat]; decide, Bool.or_true, Bool.true_or]
    · simp only [show ((-1)#i32).bv[31] = true by rw [BitVec.getElem_eq_testBit_toNat]; decide, Bool.or_true]
  have hge : 2 ^ 31 ≤ v.bv.toNat := by
    by_contra hlt; push Not at hlt
    have hf : v.bv[31] = false := by
      rw [BitVec.getElem_eq_testBit_toNat]; exact Nat.testBit_lt_two_pow hlt
    rw [hf] at hbit31; exact absurd hbit31 (by decide)
  change v.bv.toInt < 0
  rw [BitVec.toInt_eq_toNat_cond, ite_eq_right (by omega)]
  have := v.bv.isLt
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  omega

/-- Exact Hex length bijection: `hex_decoded_len (hex_encoded_len n) = ok n` for `0 ≤ n ≤ 1073741823`. -/
theorem hex_len_roundtrip (n : Std.I32) (h0 : 0 ≤ n.val) (hhi : n.val ≤ 1073741823) :
    (do let L ← hex_encoded_len n; hex_decoded_len L) = ok n := by
  unfold hex_encoded_len hex_decoded_len
  rw [result_bind_ok]
  have h2 : (2#i32).val = 2 := by norm_num
  have hmul : (Pion.I32.mul n 2#i32).val = n.val * 2 := by
    have := i32_mul_val n 2#i32 (by rw [h2]; omega) (by rw [h2]; omega)
    rw [h2] at this; exact this
  set L := Pion.I32.mul n 2#i32
  have ⟨hLnat, hLlt⟩ := i32_toNat_of_nonneg L (by omega)
  have heven : Pion.I32.band L 1#i32 = 0#i32 := by
    apply (iscalar_eq_iff _ _).mpr
    have hband : (Pion.I32.band L 1#i32).bv.toNat = L.bv.toNat % 2 := by
      rw [i32_band_bv, BitVec.toNat_and]
      have h1 : (1#i32).bv.toNat = 1 := by decide
      rw [h1]
      have : (1 : Nat) = 2 ^ 1 - 1 := by norm_num
      rw [this, Nat.and_two_pow_sub_one_eq_mod]
    have hval : (Pion.I32.band L 1#i32).val = ((Pion.I32.band L 1#i32).bv.toNat : Int) := by
      change (Pion.I32.band L 1#i32).bv.toInt = _
      rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
    have h0v : (0#i32).val = 0 := by norm_num
    omega
  simp only [heven, ne_eq, not_true_eq_false, ↓reduceIte]
  unfold Pion.I32.shr
  have hc : 0 ≤ (1#i32).val ∧ (1#i32).val < 32 := by norm_num
  have h1n : (1#i32).val.toNat = 1 := by norm_num
  simp only [hc, and_self, ↓reduceIte, h1n]
  rw [result_bind_ok]
  congr 1
  apply (iscalar_eq_iff _ _).mpr
  have hmsb : L.bv.msb = false := by
    rw [BitVec.msb_eq_decide]; simp only [decide_eq_false_iff_not]; omega
  have hshr : (L.bv.sshiftRight 1).toNat = L.bv.toNat / 2 := by
    rw [bv32_sshiftRight_eq_ushiftRight L.bv 1 hmsb, BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
  change (L.bv.sshiftRight 1).toInt = n.val
  rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega), hshr]
  omega

/-- `hex_decoded_len` rejects every odd non-negative length with `-1`. -/
theorem hex_decoded_len_rejects_odd (n : Std.I32) (h0 : 0 ≤ n.val) (hodd : n.val % 2 = 1) :
    hex_decoded_len n = ok (-1)#i32 := by
  unfold hex_decoded_len
  have ⟨hnat, _⟩ := i32_toNat_of_nonneg n h0
  have hband : (Pion.I32.band n 1#i32).bv.toNat = n.bv.toNat % 2 := by
    rw [i32_band_bv, BitVec.toNat_and]
    have h1 : (1#i32).bv.toNat = 1 := by decide
    rw [h1]
    have : (1 : Nat) = 2 ^ 1 - 1 := by norm_num
    rw [this, Nat.and_two_pow_sub_one_eq_mod]
  have hval : (Pion.I32.band n 1#i32).val = ((Pion.I32.band n 1#i32).bv.toNat : Int) := by
    change (Pion.I32.band n 1#i32).bv.toInt = _
    rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
  have h0v : (0#i32).val = 0 := by norm_num
  have hne0 : Pion.I32.band n 1#i32 ≠ 0#i32 := fun h => by
    have hv := (iscalar_eq_iff _ _).mp h; rw [h0v] at hv; omega
  simp only [hne0, ne_eq, not_false_eq_true, ↓reduceIte]

/-- Exact Hex byte ↔ nibble pair roundtrip: `hex_pack_byte (b >> 4) (b & 15) = ok b` for every `0 ≤ b < 256`. -/
theorem hex_pack_byte_roundtrip (b : Std.I32) (h0 : 0 ≤ b.val) (h256 : b.val < 256) :
    hex_pack_byte ⟨b.bv.sshiftRight 4⟩ (Pion.I32.band b 15#i32) = ok b := by
  unfold hex_pack_byte
  rw [i32_shl_const _ 4#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h4 : (4#i32).val.toNat = 4 := by norm_num
  rw [h4]
  congr 1
  apply i32_eq_of_bv
  have h15_true : ∀ j : Nat, (hj : j < 32) → j < 4 → (15#i32).bv[j] = true := by
    intro j hj hj4
    rw [BitVec.getElem_eq_testBit_toNat]
    rcases (by omega : j = 0 ∨ j = 1 ∨ j = 2 ∨ j = 3) with rfl | rfl | rfl | rfl <;> decide
  have h15_false : ∀ j : Nat, (hj : j < 32) → 4 ≤ j → (15#i32).bv[j] = false := by
    intro j hj hj4
    have h15 : (15#i32).bv.toNat = 15 := by decide
    rw [BitVec.getElem_eq_testBit_toNat, h15]
    exact Nat.testBit_lt_two_pow (by
      have : (15 : Nat) < 2 ^ 4 := by norm_num
      have : (2 : Nat) ^ 4 ≤ 2 ^ j := Nat.pow_le_pow_right (by omega) hj4
      omega)
  ext i hi
  simp only [i32_bor_bv, BitVec.getElem_or]
  change (((b.bv.sshiftRight 4 <<< 4)[i] || (Pion.I32.band b 15#i32).bv[i])) = b.bv[i]
  by_cases hi4 : i < 4
  · have ha : (b.bv.sshiftRight 4 <<< 4)[i] = false := by
      rw [BitVec.getElem_shiftLeft]; simp only [hi4, decide_true, Bool.not_true, Bool.false_and]
    have hb : (Pion.I32.band b 15#i32).bv[i] = b.bv[i] := by
      rw [i32_band_bv, BitVec.getElem_and, h15_true i hi hi4, Bool.and_true]
    simp only [ha, hb, Bool.false_or]
  · by_cases hi8 : i < 8
    · have hb : (Pion.I32.band b 15#i32).bv[i] = false := by
        rw [i32_band_bv, BitVec.getElem_and, h15_false i hi (by omega), Bool.and_false]
      have ha : (b.bv.sshiftRight 4 <<< 4)[i] = b.bv[i] := by
        rw [BitVec.getElem_shiftLeft]; simp only [hi4, decide_false, Bool.not_false, Bool.true_and]
        rw [BitVec.getElem_sshiftRight, dite_eq_left (by omega)]
        congr 1; omega
      simp only [ha, hb, Bool.or_false]
    · have hb0 : b.bv[i] = false := i32_bit_zero_above b 8 h0 h256 i hi (by omega)
      have hb : (Pion.I32.band b 15#i32).bv[i] = false := by
        rw [i32_band_bv, BitVec.getElem_and, h15_false i hi (by omega), Bool.and_false]
      have ha : (b.bv.sshiftRight 4 <<< 4)[i] = false := by
        rw [BitVec.getElem_shiftLeft]; simp only [hi4, decide_false, Bool.not_false, Bool.true_and]
        rw [BitVec.getElem_sshiftRight]
        by_cases hlt32 : 4 + (i - 4) < 32
        · rw [dite_eq_left hlt32]; exact i32_bit_zero_above b 8 h0 h256 _ hlt32 (by omega)
        · rw [dite_eq_right hlt32]
          have ⟨_, hlt31⟩ := i32_toNat_of_nonneg b h0
          rw [BitVec.msb_eq_decide]; simp only [decide_eq_false_iff_not]; omega
      simp only [ha, hb, hb0, Bool.or_false]

/-- Branchless Hex error-check soundness: if either nibble is `-1`, `hex_pack_byte` returns `< 0`. -/
theorem hex_pack_byte_neg_if_invalid (hi lo : Std.I32) (hbad : hi = (-1)#i32 ∨ lo = (-1)#i32) :
    ∃ v : Std.I32, hex_pack_byte hi lo = ok v ∧ v.val < 0 := by
  unfold hex_pack_byte
  rw [i32_shl_const hi 4#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h4 : (4#i32).val.toNat = 4 := by norm_num
  rw [h4]
  refine ⟨_, rfl, ?_⟩
  set v : Std.I32 := Pion.I32.bor ⟨hi.bv <<< 4⟩ lo
  have hbit31 : v.bv[31] = true := by
    simp only [v, i32_bor_bv, BitVec.getElem_or]
    rcases hbad with rfl | rfl
    · simp only [show ((-1)#i32.bv <<< 4)[31] = true by rw [BitVec.getElem_eq_testBit_toNat]; decide, Bool.true_or]
    · simp only [show ((-1)#i32).bv[31] = true by rw [BitVec.getElem_eq_testBit_toNat]; decide, Bool.or_true]
  have hge : 2 ^ 31 ≤ v.bv.toNat := by
    by_contra hlt; push Not at hlt
    have hf : v.bv[31] = false := by
      rw [BitVec.getElem_eq_testBit_toNat]; exact Nat.testBit_lt_two_pow hlt
    rw [hf] at hbit31; exact absurd hbit31 (by decide)
  change v.bv.toInt < 0
  rw [BitVec.toInt_eq_toNat_cond, ite_eq_right (by omega)]
  have := v.bv.isLt
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  omega

end Base64Proofs
