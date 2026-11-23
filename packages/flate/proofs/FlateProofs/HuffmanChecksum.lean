import FlateProofs.Core

open Aeneas Aeneas.Std Result Pion flate

namespace FlateProofs

private lemma bv_getLsbD_eq_testBit {w : Nat} (x : BitVec w) (i : Nat) :
    x.getLsbD i = x.toNat.testBit i := rfl

private lemma i32_shl_5 (x : Std.I32) :
    Pion.I32.shl x 5#i32 = ok (⟨x.bv <<< 5⟩ : Std.I32) := by
  unfold Pion.I32.shl
  have h5 : (5#i32).val = 5 := by norm_num
  have h5n : (5#i32).val.toNat = 5 := by norm_num
  have hc : 0 ≤ (5#i32).val ∧ (5#i32).val < 32 := by omega
  simp only [hc, and_self, ↓reduceIte, h5n]

private lemma u32_shl_16 (x : Std.U32) :
    Pion.U32.shl x 16#u32 = ok (⟨x.bv <<< 16⟩ : Std.U32) := by
  unfold Pion.U32.shl
  simp [UScalar.val]

private lemma i32_nonneg_toNat (x : Std.I32) (h0 : 0 ≤ x.val) :
    x.bv.toNat = x.val.toNat := by
  have hpow : (2 : Nat) ^ 32 = 4294967296 := by norm_num
  have hlt : x.bv.toNat < 4294967296 := by have := x.bv.isLt; rw [hpow] at this; exact this
  have hti := BitVec.toInt_eq_toNat_cond x.bv
  rw [hpow] at hti
  have : x.bv.toInt = x.val := rfl
  by_cases hc : 2 * x.bv.toNat < 4294967296
  · rw [ite_eq_left hc] at hti; omega
  · rw [ite_eq_right hc] at hti; omega

/-- Inflate Huffman LUT direct-symbol entry packing/unpacking bijection:
    for all `0 <= sym < 2^25` and `1 <= bits <= 15`, `(sym << 5) | bits` is non-zero,
    has subtable flag bit 4 = `0`, low 4 bits = `bits`, and `>> 5` = `sym`. -/
theorem huff_direct_entry_roundtrip (sym bits : Std.I32)
    (hs0 : 0 ≤ sym.val) (hs1 : sym.val < 33554432)
    (hb1 : 1 ≤ bits.val) (hb15 : bits.val ≤ 15) :
    ∃ e : Std.I32, huff_direct_entry sym bits = ok e ∧
      e ≠ 0#i32 ∧
      Pion.I32.band e 16#i32 = 0#i32 ∧
      Pion.I32.band e 15#i32 = bits ∧
      (⟨e.bv.sshiftRight 5⟩ : Std.I32) = sym := by
  unfold huff_direct_entry
  rw [i32_shl_5, result_bind_ok]
  set e := Pion.I32.bor ⟨sym.bv <<< 5⟩ bits
  have hsnat := i32_nonneg_toNat sym hs0
  have hbnat := i32_nonneg_toNat bits (by omega)
  have he_bv : e.bv = (sym.bv <<< 5) ||| bits.bv := rfl
  have hlow : Pion.I32.band e 15#i32 = bits := by
    unfold Pion.I32.band
    congr 1
    apply BitVec.eq_of_getLsbD_eq; intro i _
    rw [BitVec.getLsbD_and, he_bv, BitVec.getLsbD_or]
    by_cases hi : i < 4
    · have h1 : (sym.bv <<< 5).getLsbD i = false := by
        rw [BitVec.getLsbD_shiftLeft]; simp [show ¬(5 ≤ i) by omega]
      have h15 : (15#i32).bv.getLsbD i = true := by
        rw [bv_getLsbD_eq_testBit]
        have : (15#i32).bv.toNat = 2 ^ 4 - 1 := by norm_num
        rw [this, Nat.testBit_two_pow_sub_one]; exact decide_eq_true hi
      rw [h1, h15]; simp
    · have h15 : (15#i32).bv.getLsbD i = false := by
        rw [bv_getLsbD_eq_testBit]
        have : (15#i32).bv.toNat = 2 ^ 4 - 1 := by norm_num
        rw [this, Nat.testBit_two_pow_sub_one]; exact decide_eq_false hi
      have hb : bits.bv.getLsbD i = false := by
        rw [bv_getLsbD_eq_testBit]
        have hpow : 16 ≤ 2 ^ i := by
          have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 4 ≤ i); norm_num at this; omega
        exact Nat.testBit_eq_false_of_lt (by omega)
      rw [h15, hb]; simp
  refine ⟨e, rfl, ?_, ?_, hlow, ?_⟩
  · intro h0
    rw [h0] at hlow
    have h0b : Pion.I32.band 0#i32 15#i32 = 0#i32 := by decide
    have hb0 : bits = 0#i32 := (h0b.symm.trans hlow).symm
    have : bits.val = 0 := by rw [hb0]; norm_num
    omega
  · unfold Pion.I32.band
    apply (iscalar_eq_iff _ _).mpr
    change (e.bv &&& (16#32 : BitVec 32)).toInt = (0#i32).val
    have hzero : e.bv &&& (16#32 : BitVec 32) = 0#32 := by
      apply BitVec.eq_of_getLsbD_eq; intro i _
      rw [BitVec.getLsbD_and, he_bv, BitVec.getLsbD_or, BitVec.getLsbD_zero]
      by_cases hi : i = 4
      · subst hi
        have h1 : (sym.bv <<< 5).getLsbD 4 = false := by rw [BitVec.getLsbD_shiftLeft]; simp
        have h2 : bits.bv.getLsbD 4 = false := by
          rw [bv_getLsbD_eq_testBit]; exact Nat.testBit_eq_false_of_lt (by omega)
        rw [h1, h2]; rfl
      · have h16 : (16#32 : BitVec 32).getLsbD i = false := by
          rw [bv_getLsbD_eq_testBit]
          have : (16#32 : BitVec 32).toNat = 2 ^ 4 := by norm_num
          rw [this, Nat.testBit_two_pow]; simp [Ne.symm hi]
        rw [h16]; simp
    rw [hzero]; rfl
  · have hbv : e.bv.sshiftRight 5 = sym.bv := by
      have hmsb : e.bv.msb = false := by
        rw [BitVec.msb_eq_getLsbD_last, he_bv, BitVec.getLsbD_or]
        have h1 : (sym.bv <<< 5).getLsbD 31 = false := by
          rw [BitVec.getLsbD_shiftLeft]
          have hsub : sym.bv.getLsbD (31 - 5) = false := by
            rw [bv_getLsbD_eq_testBit]
            have h26 : 33554432 ≤ 2 ^ (31 - 5) := by norm_num
            exact Nat.testBit_eq_false_of_lt (by omega)
          rw [hsub]; rfl
        have h2 : bits.bv.getLsbD 31 = false := by
          rw [bv_getLsbD_eq_testBit]; exact Nat.testBit_eq_false_of_lt (by omega)
        rw [h1, h2]; rfl
      apply BitVec.eq_of_getLsbD_eq; intro i hi_lt
      rw [BitVec.getLsbD_sshiftRight]
      by_cases h27 : 5 + i < 32
      · simp only [h27, ↓reduceIte]
        rw [he_bv, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft]
        have hb : bits.bv.getLsbD (5 + i) = false := by
          rw [bv_getLsbD_eq_testBit]
          have hpow : 32 ≤ 2 ^ (5 + i) := by
            have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 5 ≤ 5 + i); norm_num at this; omega
          exact Nat.testBit_eq_false_of_lt (by omega)
        rw [hb]; simp [h27, hi_lt]
      · simp only [h27, ↓reduceIte, hmsb]
        have hlt_i : sym.bv.toNat < 2 ^ i := by
          have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 25 ≤ i); norm_num at this; omega
        rw [bv_getLsbD_eq_testBit, Nat.testBit_eq_false_of_lt hlt_i]; simp
    cases sym; congr 1

/-- Inflate Huffman LUT subtable-pointer entry packing/unpacking bijection:
    for all `0 <= sub_off < 2^25` and `1 <= sub_bits <= 15`, `(sub_off << 5) | 16 | sub_bits`
    is non-zero, has subtable flag bit 4 = `16`, low 4 bits = `sub_bits`, and `>> 5` = `sub_off`. -/
theorem huff_subtable_entry_roundtrip (sub_off sub_bits : Std.I32)
    (ho0 : 0 ≤ sub_off.val) (ho1 : sub_off.val < 33554432)
    (hb1 : 1 ≤ sub_bits.val) (hb15 : sub_bits.val ≤ 15) :
    ∃ e : Std.I32, huff_subtable_entry sub_off sub_bits = ok e ∧
      e ≠ 0#i32 ∧
      Pion.I32.band e 16#i32 = 16#i32 ∧
      Pion.I32.band e 15#i32 = sub_bits ∧
      (⟨e.bv.sshiftRight 5⟩ : Std.I32) = sub_off := by
  unfold huff_subtable_entry
  rw [i32_shl_5, result_bind_ok]
  set e := Pion.I32.bor (Pion.I32.bor ⟨sub_off.bv <<< 5⟩ 16#i32) sub_bits
  have honat := i32_nonneg_toNat sub_off ho0
  have hbnat := i32_nonneg_toNat sub_bits (by omega)
  have he_bv : e.bv = ((sub_off.bv <<< 5) ||| (16#32 : BitVec 32)) ||| sub_bits.bv := rfl
  have hflag : Pion.I32.band e 16#i32 = 16#i32 := by
    unfold Pion.I32.band
    congr 1
    apply BitVec.eq_of_getLsbD_eq; intro i _
    rw [BitVec.getLsbD_and, he_bv, BitVec.getLsbD_or, BitVec.getLsbD_or]
    by_cases hi : i = 4
    · subst hi
      have h16 : (16#i32).bv.getLsbD 4 = true := by decide
      have h16b : (16#32 : BitVec 32).getLsbD 4 = true := by decide
      rw [h16, h16b]; simp
    · have h16 : (16#i32).bv.getLsbD i = false := by
        rw [bv_getLsbD_eq_testBit]
        have : (16#i32).bv.toNat = 2 ^ 4 := by norm_num
        rw [this, Nat.testBit_two_pow]; simp [Ne.symm hi]
      rw [h16]; simp; exact h16
  refine ⟨e, rfl, ?_, hflag, ?_, ?_⟩
  · intro h0
    rw [h0] at hflag
    have : Pion.I32.band 0#i32 16#i32 ≠ 16#i32 := by decide
    exact this hflag
  · unfold Pion.I32.band
    congr 1
    apply BitVec.eq_of_getLsbD_eq; intro i _
    rw [BitVec.getLsbD_and, he_bv, BitVec.getLsbD_or, BitVec.getLsbD_or]
    by_cases hi : i < 4
    · have h1 : (sub_off.bv <<< 5).getLsbD i = false := by
        rw [BitVec.getLsbD_shiftLeft]; simp [show ¬(5 ≤ i) by omega]
      have h16 : (16#32 : BitVec 32).getLsbD i = false := by
        rw [bv_getLsbD_eq_testBit]
        have : (16#32 : BitVec 32).toNat = 2 ^ 4 := by norm_num
        rw [this, Nat.testBit_two_pow]; simp [show 4 ≠ i by omega]
      have h15 : (15#i32).bv.getLsbD i = true := by
        rw [bv_getLsbD_eq_testBit]
        have : (15#i32).bv.toNat = 2 ^ 4 - 1 := by norm_num
        rw [this, Nat.testBit_two_pow_sub_one]; exact decide_eq_true hi
      rw [h1, h16, h15]; simp
    · have h15 : (15#i32).bv.getLsbD i = false := by
        rw [bv_getLsbD_eq_testBit]
        have : (15#i32).bv.toNat = 2 ^ 4 - 1 := by norm_num
        rw [this, Nat.testBit_two_pow_sub_one]; exact decide_eq_false hi
      have hb : sub_bits.bv.getLsbD i = false := by
        rw [bv_getLsbD_eq_testBit]
        have hpow : 16 ≤ 2 ^ i := by
          have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 4 ≤ i); norm_num at this; omega
        exact Nat.testBit_eq_false_of_lt (by omega)
      rw [h15, hb]; simp
  · have hbv : e.bv.sshiftRight 5 = sub_off.bv := by
      have hmsb : e.bv.msb = false := by
        rw [BitVec.msb_eq_getLsbD_last, he_bv, BitVec.getLsbD_or, BitVec.getLsbD_or]
        have h1 : (sub_off.bv <<< 5).getLsbD 31 = false := by
          rw [BitVec.getLsbD_shiftLeft]
          have hsub : sub_off.bv.getLsbD (31 - 5) = false := by
            rw [bv_getLsbD_eq_testBit]
            have h26 : 33554432 ≤ 2 ^ (31 - 5) := by norm_num
            exact Nat.testBit_eq_false_of_lt (by omega)
          rw [hsub]; rfl
        have h16 : (16#32 : BitVec 32).getLsbD 31 = false := by decide
        have h2 : sub_bits.bv.getLsbD 31 = false := by
          rw [bv_getLsbD_eq_testBit]; exact Nat.testBit_eq_false_of_lt (by omega)
        rw [h1, h16, h2]; rfl
      apply BitVec.eq_of_getLsbD_eq; intro i hi_lt
      rw [BitVec.getLsbD_sshiftRight]
      by_cases h27 : 5 + i < 32
      · simp only [h27, ↓reduceIte]
        rw [he_bv, BitVec.getLsbD_or, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft]
        have h16 : (16#32 : BitVec 32).getLsbD (5 + i) = false := by
          rw [bv_getLsbD_eq_testBit]
          have : (16#32 : BitVec 32).toNat = 2 ^ 4 := by norm_num
          rw [this, Nat.testBit_two_pow]; simp [show 4 ≠ 5 + i by omega]
        have hb : sub_bits.bv.getLsbD (5 + i) = false := by
          rw [bv_getLsbD_eq_testBit]
          have hpow : 32 ≤ 2 ^ (5 + i) := by
            have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 5 ≤ 5 + i); norm_num at this; omega
          exact Nat.testBit_eq_false_of_lt (by omega)
        rw [h16, hb]; simp [h27, hi_lt]
      · simp only [h27, ↓reduceIte, hmsb]
        have hlt_i : sub_off.bv.toNat < 2 ^ i := by
          have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 25 ≤ i); norm_num at this; omega
        rw [bv_getLsbD_eq_testBit, Nat.testBit_eq_false_of_lt hlt_i]; simp
    cases sub_off; congr 1

/-- Direct-symbol entries and subtable-pointer entries in the Inflate LUT are strictly disjoint. -/
theorem huff_direct_subtable_disjoint (sym bits sub_off sub_bits : Std.I32)
    (hs0 : 0 ≤ sym.val) (hs1 : sym.val < 33554432) (hb1 : 1 ≤ bits.val) (hb15 : bits.val ≤ 15)
    (ho0 : 0 ≤ sub_off.val) (ho1 : sub_off.val < 33554432) (hsb1 : 1 ≤ sub_bits.val) (hsb15 : sub_bits.val ≤ 15) :
    huff_direct_entry sym bits ≠ huff_subtable_entry sub_off sub_bits := by
  obtain ⟨e1, he1, _, hf1, _, _⟩ := huff_direct_entry_roundtrip sym bits hs0 hs1 hb1 hb15
  obtain ⟨e2, he2, _, hf2, _, _⟩ := huff_subtable_entry_roundtrip sub_off sub_bits ho0 ho1 hsb1 hsb15
  rw [he1, he2]
  intro h
  have eq12 : e1 = e2 := result_ok_inj h
  rw [eq12] at hf1
  have : (0#i32 : Std.I32) ≠ 16#i32 := by decide
  exact this (hf1.symm.trans hf2)

/-- RFC 1950 Adler-32 packing/unpacking bijection:
    for ALL `s1 < 65521` and `s2 < 65521`, `(s2 << 16) | s1` equals `s2 * 65536 + s1`,
    low 16 bits = `s1`, and high 16 bits = `s2`. -/
theorem adler32_pack_roundtrip (s1 s2 : Std.U32)
    (h1 : s1.val < 65521) (h2 : s2.val < 65521) :
    ∃ p : Std.U32, adler32_pack s1 s2 = ok p ∧
      p.val = s2.val * 65536 + s1.val ∧
      Pion.U32.band p 65535#u32 = s1 ∧
      (⟨p.bv >>> 16⟩ : Std.U32) = s2 := by
  unfold adler32_pack
  rw [u32_shl_16, result_bind_ok]
  set p := Pion.U32.bor ⟨s2.bv <<< 16⟩ s1
  have hp_bv : p.bv = (s2.bv <<< 16) ||| s1.bv := rfl
  have hs1_nat : s1.bv.toNat < 65521 := h1
  have hs2_nat : s2.bv.toNat < 65521 := h2
  have hband_zero : (s2.bv <<< 16) &&& s1.bv = 0#32 := by
    apply BitVec.eq_of_getLsbD_eq; intro i _
    rw [BitVec.getLsbD_and, BitVec.getLsbD_zero]
    by_cases hi : i < 16
    · have hl : (s2.bv <<< 16).getLsbD i = false := by rw [BitVec.getLsbD_shiftLeft]; simp [show ¬(16 ≤ i) by omega]
      rw [hl]; simp
    · have hr : s1.bv.getLsbD i = false := by
        rw [bv_getLsbD_eq_testBit]
        have hpow : 65536 ≤ 2 ^ i := by
          have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 16 ≤ i); norm_num at this; omega
        exact Nat.testBit_eq_false_of_lt (by omega)
      rw [hr]; simp
  have hp_val : p.val = s2.val * 65536 + s1.val := by
    have hadd : (s2.bv <<< 16) ||| s1.bv = (s2.bv <<< 16) + s1.bv :=
      (BitVec.add_eq_or_of_and_eq_zero (s2.bv <<< 16) s1.bv hband_zero).symm
    change p.bv.toNat = s2.val * 65536 + s1.val
    rw [hp_bv, hadd, BitVec.toNat_add, BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
    rw [Nat.mod_eq_of_lt (by omega), Nat.mod_eq_of_lt (by omega)]; rfl
  refine ⟨p, rfl, hp_val, ?_, ?_⟩
  · unfold Pion.U32.band
    congr 1
    apply BitVec.eq_of_getLsbD_eq; intro i _
    rw [BitVec.getLsbD_and, hp_bv, BitVec.getLsbD_or]
    by_cases hi : i < 16
    · have hl : (s2.bv <<< 16).getLsbD i = false := by rw [BitVec.getLsbD_shiftLeft]; simp [show ¬(16 ≤ i) by omega]
      have hm : (65535#u32).bv.getLsbD i = true := by
        rw [bv_getLsbD_eq_testBit]
        have : (65535#u32).bv.toNat = 2 ^ 16 - 1 := by norm_num
        rw [this, Nat.testBit_two_pow_sub_one]; exact decide_eq_true hi
      rw [hl, hm]; simp
    · have hm : (65535#u32).bv.getLsbD i = false := by
        rw [bv_getLsbD_eq_testBit]
        have : (65535#u32).bv.toNat = 2 ^ 16 - 1 := by norm_num
        rw [this, Nat.testBit_two_pow_sub_one]; exact decide_eq_false hi
      have hr : s1.bv.getLsbD i = false := by
        rw [bv_getLsbD_eq_testBit]
        have hpow : 65536 ≤ 2 ^ i := by
          have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 16 ≤ i); norm_num at this; omega
        exact Nat.testBit_eq_false_of_lt (by omega)
      rw [hm, hr]; simp
  · have hbv : p.bv >>> 16 = s2.bv := by
      apply BitVec.eq_of_getLsbD_eq; intro i _
      rw [BitVec.getLsbD_ushiftRight, hp_bv, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft]
      by_cases hi : i < 16
      · have hr : s1.bv.getLsbD (16 + i) = false := by
          rw [bv_getLsbD_eq_testBit]
          have hpow : 65536 ≤ 2 ^ (16 + i) := by
            have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 16 ≤ 16 + i); norm_num at this; omega
          exact Nat.testBit_eq_false_of_lt (by omega)
        rw [hr]; simp [show 16 + i < 32 by omega]
      · have h2' : s1.bv.getLsbD (16 + i) = false := by
          rw [bv_getLsbD_eq_testBit]
          have hpow : 65536 ≤ 2 ^ (16 + i) := by
            have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 16 ≤ 16 + i); norm_num at this; omega
          exact Nat.testBit_eq_false_of_lt (by omega)
        have h3 : s2.bv.getLsbD i = false := by
          rw [bv_getLsbD_eq_testBit]
          have hpow : 65536 ≤ 2 ^ i := by
            have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (by omega : 16 ≤ i); norm_num at this; omega
          exact Nat.testBit_eq_false_of_lt (by omega)
        rw [h2', h3]; simp [show ¬(16 + i < 32) by omega]
    cases s2; congr 1

end FlateProofs
