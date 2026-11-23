import Aeneas
import PionLean
import Http2.Types
import Http2.Funs
import Http2Proofs.Core

open Aeneas Aeneas.Std Result Pion http2

namespace Http2Proofs

private lemma i32_mk_bv (x : BitVec 32) : (⟨x⟩ : I32).bv = x := rfl

private lemma i32_255_mask_range (x : I32) :
    0 ≤ (Pion.I32.band x 255#i32).val ∧ (Pion.I32.band x 255#i32).val ≤ 255 := by
  have hval : (Pion.I32.band x 255#i32).val = (Pion.I32.band x 255#i32).bv.toInt := rfl
  have htoNat : (Pion.I32.band x 255#i32).bv.toNat ≤ 255 := by
    rw [i32_band_bv, BitVec.toNat_and]
    have : (255#i32).bv.toNat = 255 := by decide
    rw [this]
    exact Nat.and_le_right
  have h2 : (Pion.I32.band x 255#i32).bv.toInt =
      if 2 * (Pion.I32.band x 255#i32).bv.toNat < 2 ^ 32 then ((Pion.I32.band x 255#i32).bv.toNat : Int)
      else ((Pion.I32.band x 255#i32).bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  omega

private lemma i32_127_mask_range (x : I32) :
    0 ≤ (Pion.I32.band x 127#i32).val ∧ (Pion.I32.band x 127#i32).val ≤ 127 := by
  have hval : (Pion.I32.band x 127#i32).val = (Pion.I32.band x 127#i32).bv.toInt := rfl
  have htoNat : (Pion.I32.band x 127#i32).bv.toNat ≤ 127 := by
    rw [i32_band_bv, BitVec.toNat_and]
    have : (127#i32).bv.toNat = 127 := by decide
    rw [this]
    exact Nat.and_le_right
  have h2 : (Pion.I32.band x 127#i32).bv.toInt =
      if 2 * (Pion.I32.band x 127#i32).bv.toNat < 2 ^ 32 then ((Pion.I32.band x 127#i32).bv.toNat : Int)
      else ((Pion.I32.band x 127#i32).bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  omega

/-- Theorem 7: `pack_u24_b0/b1/b2` produce valid wire bytes in `[0, 255]`. -/
theorem u24_pack_bytes_range (v : I32) :
    ∃ b0 b1 b2, pack_u24_b0 v = ok b0 ∧ pack_u24_b1 v = ok b1 ∧ pack_u24_b2 v = ok b2 ∧
      0 ≤ b0.val ∧ b0.val ≤ 255 ∧ 0 ≤ b1.val ∧ b1.val ≤ 255 ∧ 0 ≤ b2.val ∧ b2.val ≤ 255 := by
  unfold pack_u24_b0 pack_u24_b1 pack_u24_b2
  rw [i32_shr_ok v 16#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shr_ok v 8#i32 (by decide) (by decide), result_bind_ok]
  refine ⟨_, _, _, rfl, rfl, rfl, ?_⟩
  have h0 := i32_255_mask_range (⟨v.bv.sshiftRight (16#i32 : I32).val.toNat⟩ : I32)
  have h1 := i32_255_mask_range (⟨v.bv.sshiftRight (8#i32 : I32).val.toNat⟩ : I32)
  have h2 := i32_255_mask_range v
  omega

/-- Theorem 8: RFC 9113 §4.1 24-bit frame length pack/unpack roundtrip for all `0 ≤ v ≤ 16777215`. -/
theorem u24_roundtrip (v : I32) (hlo : 0 ≤ v.val) (hhi : v.val ≤ 16777215) :
    (do
      let b0 ← pack_u24_b0 v
      let b1 ← pack_u24_b1 v
      let b2 ← pack_u24_b2 v
      unpack_u24_be b0 b1 b2) = ok v := by
  unfold pack_u24_b0 pack_u24_b1 pack_u24_b2 unpack_u24_be
  rw [i32_shr_ok v 16#i32 (by decide) (by decide), result_bind_ok, result_bind_ok]
  rw [i32_shr_ok v 8#i32 (by decide) (by decide), result_bind_ok, result_bind_ok, result_bind_ok]
  rw [i32_shl_ok _ 16#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok _ 8#i32 (by decide) (by decide), result_bind_ok]
  congr 1
  apply iscalar_eq_of_bv_eq
  apply BitVec.eq_of_getElem_eq
  intro i hi
  have h16n : (16#i32 : I32).val.toNat = 16 := rfl
  have h8n : (8#i32 : I32).val.toNat = 8 := rfl
  simp only [i32_bor_bv, i32_band_bv, i32_mk_bv, h16n, h8n, BitVec.getElem_or, BitVec.getElem_and, BitVec.getElem_shiftLeft]
  by_cases h8 : i < 8
  · have h16 : i < 16 := by omega
    have hm : (255#i32).bv[i] = true := by
      rw [BitVec.getElem_eq_testBit_toNat]
      have : (255#i32).bv.toNat = 255 := by decide
      rw [this]; revert i h8; decide
    simp only [h8, h16, decide_true, Bool.not_true, Bool.false_and, Bool.false_or, hm, Bool.and_true]
  · by_cases h16 : i < 16
    · have hm0 : (255#i32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (255#i32).bv.toNat = 255 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i)))
      have hm1 : (255#i32).bv[i - 8] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (255#i32).bv.toNat = 255 := by decide
        rw [this]
        have : i - 8 < 8 := by omega
        revert this; generalize i - 8 = k; intro hk; revert k hk; decide
      have hlt : 8 + (i - 8) < 32 := by omega
      simp only [h8, h16, decide_false, decide_true, Bool.not_false, Bool.not_true,
                 Bool.false_and, Bool.true_and, Bool.false_or, hm0,
                 Bool.and_false, Bool.or_false, hm1, Bool.and_true]
      change (v.bv.sshiftRight 8)[i - 8] = v.bv[i]
      simp only [BitVec.getElem_sshiftRight, hlt, ↓reduceDIte]
      congr 1; omega
    · by_cases h24 : i < 24
      · have hm0 : (255#i32).bv[i] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (255#i32).bv.toNat = 255 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i)))
        have hm1 : (255#i32).bv[i - 8] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (255#i32).bv.toNat = 255 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i - 8)))
        have hm2 : (255#i32).bv[i - 16] = true := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (255#i32).bv.toNat = 255 := by decide
          rw [this]
          have : i - 16 < 8 := by omega
          revert this; generalize i - 16 = k; intro hk; revert k hk; decide
        have hlt : 16 + (i - 16) < 32 := by omega
        simp only [h8, h16, decide_false, Bool.not_false, Bool.true_and,
                   hm0, hm1, hm2, Bool.and_false, Bool.and_true, Bool.or_false]
        change (v.bv.sshiftRight 16)[i - 16] = v.bv[i]
        simp only [BitVec.getElem_sshiftRight, hlt, ↓reduceDIte]
        congr 1; omega
      · have hm0 : (255#i32).bv[i] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (255#i32).bv.toNat = 255 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i)))
        have hm1 : (255#i32).bv[i - 8] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (255#i32).bv.toNat = 255 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i - 8)))
        have hm2 : (255#i32).bv[i - 16] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (255#i32).bv.toNat = 255 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i - 16)))
        have hv0 : v.bv[i] = false := bv32_getElem_high_false v hlo (by omega : v.val < ((2 ^ 24 : Nat) : Int)) i hi (by omega)
        simp only [h8, h16, decide_false, Bool.not_false,
                   hm0, hm1, hm2, Bool.and_false, Bool.or_false, hv0]

/-- Theorem 9: `pack_u31_b0..b3` produce valid wire bytes (`b0 ∈ [0, 127]` with R bit cleared, `b1..b3 ∈ [0, 255]`). -/
theorem u31_pack_bytes_range (sid : I32) :
    ∃ b0 b1 b2 b3, pack_u31_b0 sid = ok b0 ∧ pack_u31_b1 sid = ok b1 ∧
      pack_u31_b2 sid = ok b2 ∧ pack_u31_b3 sid = ok b3 ∧
      0 ≤ b0.val ∧ b0.val ≤ 127 ∧ 0 ≤ b1.val ∧ b1.val ≤ 255 ∧
      0 ≤ b2.val ∧ b2.val ≤ 255 ∧ 0 ≤ b3.val ∧ b3.val ≤ 255 := by
  unfold pack_u31_b0 pack_u31_b1 pack_u31_b2 pack_u31_b3
  rw [i32_shr_ok sid 24#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shr_ok sid 16#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shr_ok sid 8#i32 (by decide) (by decide), result_bind_ok]
  refine ⟨_, _, _, _, rfl, rfl, rfl, rfl, ?_⟩
  have h0 := i32_127_mask_range (⟨sid.bv.sshiftRight (24#i32 : I32).val.toNat⟩ : I32)
  have h1 := i32_255_mask_range (⟨sid.bv.sshiftRight (16#i32 : I32).val.toNat⟩ : I32)
  have h2 := i32_255_mask_range (⟨sid.bv.sshiftRight (8#i32 : I32).val.toNat⟩ : I32)
  have h3 := i32_255_mask_range sid
  omega

/-- Theorem 10: RFC 9113 §4.1 31-bit stream ID pack/unpack roundtrip for all `0 ≤ sid ≤ 2^31 - 1`. -/
theorem u31_roundtrip (sid : I32) (hlo : 0 ≤ sid.val) :
    (do
      let b0 ← pack_u31_b0 sid
      let b1 ← pack_u31_b1 sid
      let b2 ← pack_u31_b2 sid
      let b3 ← pack_u31_b3 sid
      unpack_u31_be b0 b1 b2 b3) = ok sid := by
  unfold pack_u31_b0 pack_u31_b1 pack_u31_b2 pack_u31_b3 unpack_u31_be
  rw [i32_shr_ok sid 24#i32 (by decide) (by decide), result_bind_ok, result_bind_ok]
  rw [i32_shr_ok sid 16#i32 (by decide) (by decide), result_bind_ok, result_bind_ok]
  rw [i32_shr_ok sid 8#i32 (by decide) (by decide), result_bind_ok, result_bind_ok, result_bind_ok]
  rw [i32_shl_ok _ 24#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok _ 16#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok _ 8#i32 (by decide) (by decide), result_bind_ok]
  congr 1
  apply iscalar_eq_of_bv_eq
  apply BitVec.eq_of_getElem_eq
  intro i hi
  have h24n : (24#i32 : I32).val.toNat = 24 := rfl
  have h16n : (16#i32 : I32).val.toNat = 16 := rfl
  have h8n : (8#i32 : I32).val.toNat = 8 := rfl
  simp only [i32_bor_bv, i32_band_bv, i32_mk_bv, h24n, h16n, h8n, BitVec.getElem_or, BitVec.getElem_and, BitVec.getElem_shiftLeft]
  by_cases h8 : i < 8
  · have h16 : i < 16 := by omega
    have h24 : i < 24 := by omega
    have hm : (255#i32).bv[i] = true := by
      rw [BitVec.getElem_eq_testBit_toNat]
      have : (255#i32).bv.toNat = 255 := by decide
      rw [this]; revert i h8; decide
    simp only [h8, h16, h24, decide_true, Bool.not_true, Bool.false_and, Bool.false_or, hm, Bool.and_true]
  · by_cases h16 : i < 16
    · have h24 : i < 24 := by omega
      have hm0 : (255#i32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (255#i32).bv.toNat = 255 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i)))
      have hm1 : (255#i32).bv[i - 8] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (255#i32).bv.toNat = 255 := by decide
        rw [this]
        have : i - 8 < 8 := by omega
        revert this; generalize i - 8 = k; intro hk; revert k hk; decide
      have hlt : 8 + (i - 8) < 32 := by omega
      simp only [h8, h16, h24, decide_false, decide_true, Bool.not_false, Bool.not_true,
                 Bool.false_and, Bool.true_and, Bool.false_or, hm0,
                 Bool.and_false, Bool.or_false, hm1, Bool.and_true]
      change (sid.bv.sshiftRight 8)[i - 8] = sid.bv[i]
      simp only [BitVec.getElem_sshiftRight, hlt, ↓reduceDIte]
      congr 1; omega
    · by_cases h24 : i < 24
      · have hm0 : (255#i32).bv[i] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (255#i32).bv.toNat = 255 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i)))
        have hm1 : (255#i32).bv[i - 8] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (255#i32).bv.toNat = 255 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i - 8)))
        have hm2 : (255#i32).bv[i - 16] = true := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (255#i32).bv.toNat = 255 := by decide
          rw [this]
          have : i - 16 < 8 := by omega
          revert this; generalize i - 16 = k; intro hk; revert k hk; decide
        have hlt : 16 + (i - 16) < 32 := by omega
        simp only [h8, h16, h24, decide_false, decide_true, Bool.not_false, Bool.not_true,
                   Bool.false_and, Bool.true_and, Bool.false_or,
                   hm0, hm1, hm2, Bool.and_false, Bool.and_true, Bool.or_false]
        change (sid.bv.sshiftRight 16)[i - 16] = sid.bv[i]
        simp only [BitVec.getElem_sshiftRight, hlt, ↓reduceDIte]
        congr 1; omega
      · by_cases h31 : i < 31
        · have hm0 : (255#i32).bv[i] = false := by
            rw [BitVec.getElem_eq_testBit_toNat]
            have : (255#i32).bv.toNat = 255 := by decide
            rw [this]
            exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i)))
          have hm1 : (255#i32).bv[i - 8] = false := by
            rw [BitVec.getElem_eq_testBit_toNat]
            have : (255#i32).bv.toNat = 255 := by decide
            rw [this]
            exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i - 8)))
          have hm2 : (255#i32).bv[i - 16] = false := by
            rw [BitVec.getElem_eq_testBit_toNat]
            have : (255#i32).bv.toNat = 255 := by decide
            rw [this]
            exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 8 ≤ i - 16)))
          have hm3 : (127#i32).bv[i - 24] = true := by
            rw [BitVec.getElem_eq_testBit_toNat]
            have : (127#i32).bv.toNat = 127 := by decide
            rw [this]
            have : i - 24 < 7 := by omega
            revert this; generalize i - 24 = k; intro hk; revert k hk; decide
          have hlt : 24 + (i - 24) < 32 := by omega
          simp only [h8, h16, h24, decide_false, Bool.not_false, Bool.true_and,
                     hm0, hm1, hm2, hm3, Bool.and_false, Bool.and_true, Bool.or_false]
          change (sid.bv.sshiftRight 24)[i - 24] = sid.bv[i]
          simp only [BitVec.getElem_sshiftRight, hlt, ↓reduceDIte]
          congr 1; omega
        · have hi32 : i < 32 := hi
          have hi31 : i = 31 := by omega
          subst hi31
          have hsid_hi : sid.val < ((2 ^ 31 : Nat) : Int) := sid.hBounds.2
          have hsid31 : sid.bv[31] = false :=
            bv32_getElem_high_false sid hlo hsid_hi 31 (by omega) (by omega)
          have hm0 : (255#i32).bv[31]'(by decide) = false := by decide
          have hm1 : (255#i32).bv[23]'(by decide) = false := by decide
          have hm2 : (255#i32).bv[15]'(by decide) = false := by decide
          have hm3 : (127#i32).bv[7]'(by decide) = false := by decide
          simp only [show ¬(31 < 8) by omega, show ¬(31 < 16) by omega, show ¬(31 < 24) by omega,
                     decide_false, Bool.not_false,
                     hm0, hm1, hm2, hm3, Bool.and_false, Bool.or_false, hsid31]

/-- Theorem 11: RFC 9113 §4.1 setting the R reserved bit (`b0 | 0x80`) MUST be ignored by `unpack_u31_be`. -/
theorem u31_ignores_reserved_bit (b0 b1 b2 b3 : I32) :
    unpack_u31_be (Pion.I32.bor b0 128#i32) b1 b2 b3 = unpack_u31_be b0 b1 b2 b3 := by
  unfold unpack_u31_be
  have hmask : Pion.I32.band (Pion.I32.bor b0 128#i32) 127#i32 = Pion.I32.band b0 127#i32 := by
    apply iscalar_eq_of_bv_eq
    apply BitVec.eq_of_getElem_eq
    intro i hi
    simp only [i32_band_bv, i32_bor_bv, BitVec.getElem_and, BitVec.getElem_or]
    by_cases h7 : i < 7
    · have h128 : (128#i32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (128#i32).bv.toNat = 128 := by decide
        rw [this]; revert i h7; decide
      rw [h128]; simp
    · have h127 : (127#i32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (127#i32).bv.toNat = 127 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 7 ≤ i)))
      rw [h127]; simp
  rw [hmask]

/-- Theorem 12: RFC 9113 §4.1 `unpack_u31_be` always returns a non-negative 31-bit stream ID (`0 ≤ sid ≤ 2^31 - 1`) for wire bytes `b1..b3 ∈ [0, 255]`. -/
theorem u31_unpack_nonneg (b0 b1 b2 b3 : I32)
    (hb1 : 0 ≤ b1.val ∧ b1.val ≤ 255)
    (hb2 : 0 ≤ b2.val ∧ b2.val ≤ 255)
    (hb3 : 0 ≤ b3.val ∧ b3.val ≤ 255) :
    ∃ sid, unpack_u31_be b0 b1 b2 b3 = ok sid ∧ 0 ≤ sid.val ∧ sid.val ≤ 2147483647 := by
  unfold unpack_u31_be
  rw [i32_shl_ok _ 24#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok _ 16#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok _ 8#i32 (by decide) (by decide), result_bind_ok]
  refine ⟨_, rfl, ?_⟩
  apply bv32_nonneg_of_msb_false
  have h24n : (24#i32 : I32).val.toNat = 24 := rfl
  have h16n : (16#i32 : I32).val.toNat = 16 := rfl
  have h8n : (8#i32 : I32).val.toNat = 8 := rfl
  simp only [i32_bor_bv, i32_band_bv, i32_mk_bv, h24n, h16n, h8n, BitVec.getElem_or, BitVec.getElem_and, BitVec.getElem_shiftLeft]
  have h0 : (127#i32).bv[7] = false := by decide
  have h1 : b1.bv[15] = false := bv32_getElem_high_false b1 hb1.1 (by omega : b1.val < ((2 ^ 8 : Nat) : Int)) 15 (by omega) (by omega)
  have h2 : b2.bv[23] = false := bv32_getElem_high_false b2 hb2.1 (by omega : b2.val < ((2 ^ 8 : Nat) : Int)) 23 (by omega) (by omega)
  have h3 : b3.bv[31] = false := bv32_getElem_high_false b3 hb3.1 (by omega : b3.val < ((2 ^ 8 : Nat) : Int)) 31 (by omega) (by omega)
  simp only [show ¬(31 < 24) by omega, show ¬(31 < 16) by omega, show ¬(31 < 8) by omega,
             decide_false, Bool.not_false, h0, h1, h2, h3, Bool.and_false, Bool.or_false]

private lemma i32_to_int64_val (x : I32) : (Pion.I32.to_int64 x).val = x.val := by
  have h1 : (Pion.I32.to_int64 x).val = (BitVec.signExtend 64 x.bv).toInt := rfl
  rw [h1, BitVec.toInt_signExtend_of_le (by omega)]
  rfl

private lemma i64_to_int_val_of_nonneg (x : I64) (hlo : 0 ≤ x.val) (hhi : x.val ≤ 2147483647) :
    (Pion.I64.to_int x).val = x.val := by
  have h1 : (Pion.I64.to_int x).val = (BitVec.signExtend 32 x.bv).toInt := rfl
  rw [h1, BitVec.toInt_signExtend]
  have hx : x.bv.toInt = x.val := rfl
  have hmin : min 32 64 = 32 := rfl
  rw [hx, hmin]
  have hm : x.val % ((2 ^ 32 : Nat) : Int) = x.val := Int.emod_eq_of_lt hlo (by omega)
  simp only [Int.bmod, hm]
  split <;> omega

/-- Theorem 13: RFC 9113 §6.2/§6.3 Priority dependency word full bijection (exclusive bit + 31-bit stream dependency). -/
theorem priority_dep_roundtrip (excl : Bool) (dep : I32) (hlo : 0 ≤ dep.val) :
    ∃ raw, pack_priority_dep excl dep = ok raw ∧
      unpack_priority_exclusive raw = ok excl ∧
      unpack_priority_dep raw = ok dep := by
  unfold pack_priority_dep unpack_priority_exclusive unpack_priority_dep
  refine ⟨_, rfl, ?_, ?_⟩
  · -- unpack_priority_exclusive
    cases excl
    · simp only [Bool.false_eq_true, ↓reduceIte]
      have hz : Pion.I64.band (Pion.I64.band (Pion.I32.to_int64 dep) 2147483647#i64) 2147483648#i64 = 0#i64 := by
        apply iscalar_eq_of_bv_eq
        apply BitVec.eq_of_getElem_eq
        intro i hi
        simp only [i64_band_bv, BitVec.getElem_and]
        have hdisj : ((2147483647#i64).bv[i] && (2147483648#i64).bv[i]) = false := by
          revert i hi; decide
        have h0 : (0#i64).bv[i] = false := by simp
        rw [Bool.and_assoc, hdisj, Bool.and_false, h0]
      rw [hz]; congr 1
    · simp only [↓reduceIte]
      have hnz : Pion.I64.band (Pion.I64.bor (Pion.I64.band (Pion.I32.to_int64 dep) 2147483647#i64) 2147483648#i64) 2147483648#i64 = 2147483648#i64 := by
        apply iscalar_eq_of_bv_eq
        apply BitVec.eq_of_getElem_eq
        intro i hi
        simp only [i64_band_bv, i64_bor_bv, BitVec.getElem_and, BitVec.getElem_or]
        by_cases h31 : i = 31
        · subst h31
          have hbit : (2147483648#i64).bv[31]'(by decide) = true := by decide
          rw [hbit]; simp
        · have hbit : (2147483648#i64).bv[i] = false := by
            rw [BitVec.getElem_eq_testBit_toNat]
            have : (2147483648#i64).bv.toNat = 2 ^ 31 := by decide
            rw [this, Nat.testBit_two_pow]
            simp [Ne.symm h31]
          rw [hbit]; simp
      rw [hnz]; congr 1
  · -- unpack_priority_dep
    have hdep_hi : dep.val ≤ 2147483647 := by
      have h := dep.hBounds.2
      change dep.val < 2 ^ 31 at h
      omega
    have hdep_bv : ∀ (b : Bool),
        Pion.I64.to_int (Pion.I64.band (if b then Pion.I64.bor (Pion.I64.band (Pion.I32.to_int64 dep) 2147483647#i64) 2147483648#i64
          else Pion.I64.band (Pion.I32.to_int64 dep) 2147483647#i64) 2147483647#i64) = dep := by
      intro b
      have hcast_val : (Pion.I32.to_int64 dep).val = dep.val := i32_to_int64_val dep
      have hmask : Pion.I64.band (if b then Pion.I64.bor (Pion.I64.band (Pion.I32.to_int64 dep) 2147483647#i64) 2147483648#i64
          else Pion.I64.band (Pion.I32.to_int64 dep) 2147483647#i64) 2147483647#i64 =
          Pion.I32.to_int64 dep := by
        apply iscalar_eq_of_bv_eq
        apply BitVec.eq_of_getElem_eq
        intro i hi
        have hcast_hi : ∀ j (hj : j < 64), 31 ≤ j → (Pion.I32.to_int64 dep).bv[j] = false := by
          intro j hj h31
          rw [BitVec.getElem_eq_testBit_toNat]
          have htn : (Pion.I32.to_int64 dep).bv.toNat = dep.val.toNat := by
            have h1 : (Pion.I32.to_int64 dep).val = (Pion.I32.to_int64 dep).bv.toInt := rfl
            have h2 : (Pion.I32.to_int64 dep).bv.toInt =
                if 2 * (Pion.I32.to_int64 dep).bv.toNat < 2 ^ 64 then ((Pion.I32.to_int64 dep).bv.toNat : Int)
                else ((Pion.I32.to_int64 dep).bv.toNat : Int) - 2 ^ 64 := by
              rw [BitVec.toInt_eq_toNat_cond]; rfl
            have hlt := (Pion.I32.to_int64 dep).bv.isLt
            omega
          rw [htn]
          apply Nat.testBit_lt_two_pow
          have hlt31 : dep.val.toNat < 2 ^ 31 := by omega
          exact Nat.lt_of_lt_of_le hlt31 (Nat.pow_le_pow_right (by omega) h31)
        by_cases h31 : i < 31
        · have hm : (2147483647#i64).bv[i] = true := by
            rw [BitVec.getElem_eq_testBit_toNat]
            have : (2147483647#i64).bv.toNat = 2 ^ 31 - 1 := by decide
            rw [this, Nat.testBit_two_pow_sub_one]; simp [h31]
          have he : (2147483648#i64).bv[i] = false := by
            rw [BitVec.getElem_eq_testBit_toNat]
            have : (2147483648#i64).bv.toNat = 2 ^ 31 := by decide
            rw [this, Nat.testBit_two_pow]; simp [show 31 ≠ i by omega]
          cases b <;> simp only [↓reduceIte, Bool.false_eq_true, i64_band_bv, i64_bor_bv,
            BitVec.getElem_and, BitVec.getElem_or, hm, he, Bool.and_true, Bool.or_false]
        · have hm : (2147483647#i64).bv[i] = false := by
            rw [BitVec.getElem_eq_testBit_toNat]
            have : (2147483647#i64).bv.toNat = 2 ^ 31 - 1 := by decide
            rw [this, Nat.testBit_two_pow_sub_one]; simp [show ¬(i < 31) by omega]
          have hc := hcast_hi i hi (by omega)
          cases b <;> simp only [↓reduceIte, Bool.false_eq_true, i64_band_bv, i64_bor_bv,
            BitVec.getElem_and, BitVec.getElem_or, hm, hc, Bool.and_false]
      rw [hmask]
      apply iscalar_eq_of_val_eq
      rw [i64_to_int_val_of_nonneg (Pion.I32.to_int64 dep) (by omega) (by omega), hcast_val]
    rw [hdep_bv excl]

/-- Theorem 14: `unpack_priority_dep` always returns a non-negative 31-bit stream dependency in `[0, 2^31 - 1]`. -/
theorem priority_dep_unpack_nonneg (raw : I64) :
    ∃ dep, unpack_priority_dep raw = ok dep ∧ 0 ≤ dep.val ∧ dep.val ≤ 2147483647 := by
  unfold unpack_priority_dep
  refine ⟨Pion.I64.to_int (Pion.I64.band raw 2147483647#i64), rfl, ?_⟩
  have hval : (Pion.I64.band raw 2147483647#i64).val = (Pion.I64.band raw 2147483647#i64).bv.toInt := rfl
  have htoNat : (Pion.I64.band raw 2147483647#i64).bv.toNat ≤ 2147483647 := by
    rw [i64_band_bv, BitVec.toNat_and]
    have : (2147483647#i64).bv.toNat = 2147483647 := by decide
    rw [this]
    exact Nat.and_le_right
  have h2 : (Pion.I64.band raw 2147483647#i64).bv.toInt =
      if 2 * (Pion.I64.band raw 2147483647#i64).bv.toNat < 2 ^ 64 then ((Pion.I64.band raw 2147483647#i64).bv.toNat : Int)
      else ((Pion.I64.band raw 2147483647#i64).bv.toNat : Int) - 2 ^ 64 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  have hband_range : 0 ≤ (Pion.I64.band raw 2147483647#i64).val ∧ (Pion.I64.band raw 2147483647#i64).val ≤ 2147483647 := by
    omega
  have hcast : (Pion.I64.to_int (Pion.I64.band raw 2147483647#i64)).val = (Pion.I64.band raw 2147483647#i64).val :=
    i64_to_int_val_of_nonneg _ hband_range.1 hband_range.2
  omega

/-- Theorem 15: RFC 9113 §6.2 `encode_headers_flags` cleanly packs END_STREAM (0x01), END_HEADERS (0x04), PRIORITY (0x20) with PADDED (0x08) always 0. -/
theorem encode_headers_flags_roundtrip (es eh prio : Bool) :
    ∃ fl, encode_headers_flags es eh prio = ok fl ∧
      ((Pion.I32.band fl 1#i32 != 0#i32) = es) ∧
      ((Pion.I32.band fl 4#i32 != 0#i32) = eh) ∧
      ((Pion.I32.band fl 32#i32 != 0#i32) = prio) ∧
      (Pion.I32.band fl 8#i32 = 0#i32) := by
  cases es <;> cases eh <;> cases prio <;>
    (unfold encode_headers_flags; refine ⟨_, rfl, by decide, by decide, by decide, by decide⟩)

/-- Theorem 15b: RFC 9113 §6.9 `is_valid_window_increment` characterizes `[1, 2^31 - 1]`. -/
theorem is_valid_window_increment_iff (inc : I32) :
    is_valid_window_increment inc = ok true ↔ 1 ≤ inc.val ∧ inc.val ≤ 2147483647 := by
  unfold is_valid_window_increment
  constructor
  · intro h
    have ht : (decide (inc > 0#i32) && decide (inc <= 2147483647#i32)) = true := result_ok_inj h
    simp only [Bool.and_eq_true, decide_eq_true_eq] at ht
    have h1 : 0 < inc.val := ht.1
    have h2 : inc.val ≤ 2147483647 := ht.2
    omega
  · intro ⟨hlo, hhi⟩
    have h1 : (0#i32 : I32) < inc := by change 0 < inc.val; omega
    have h2 : inc ≤ (2147483647#i32 : I32) := hhi
    simp [h1, h2]

end Http2Proofs
