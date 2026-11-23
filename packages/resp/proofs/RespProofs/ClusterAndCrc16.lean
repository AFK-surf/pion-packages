import Aeneas
import PionLean
import Resp.Types
import Resp.Funs

open Aeneas Aeneas.Std Result Pion resp

namespace RespProofs

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i32_le_iff' (x y : Std.I32) : (x ≤ y) ↔ (x.val ≤ y.val) := Iff.rfl

private lemma i32_shl1_ok (x : Std.I32) : Pion.I32.shl x 1#i32 = ok ⟨x.bv <<< 1⟩ := by
  unfold Pion.I32.shl; rfl

private lemma i32_band_mask_bounds (x : Std.I32) (k : Nat) (hk : k ≤ 16) :
    0 ≤ (x.bv &&& BitVec.ofNat 32 (2 ^ k - 1)).toInt ∧
    (x.bv &&& BitVec.ofNat 32 (2 ^ k - 1)).toInt < 2 ^ k := by
  have hnat : (x.bv &&& BitVec.ofNat 32 (2 ^ k - 1)).toNat < 2 ^ k := by
    rw [BitVec.toNat_and, BitVec.toNat_ofNat]
    have hpow : 2 ^ k - 1 < 2 ^ 32 := by
      have : 2 ^ k ≤ 2 ^ 16 := Nat.pow_le_pow_right (by omega) hk
      omega
    rw [Nat.mod_eq_of_lt hpow, Nat.and_two_pow_sub_one_eq_mod]
    exact Nat.mod_lt _ (Nat.two_pow_pos k)
  have hlt31 : 2 ^ k ≤ 2 ^ 16 := Nat.pow_le_pow_right (by omega) hk
  have hcast : ((2 ^ k : Nat) : Int) = (2 : Int) ^ k := by push_cast; rfl
  rw [BitVec.toInt_eq_toNat_cond]
  split_ifs <;> omega

private lemma i32_band_65535_bounds (x : Std.I32) :
    0 ≤ (Pion.I32.band x 65535#i32).val ∧ (Pion.I32.band x 65535#i32).val ≤ 65535 := by
  have h := i32_band_mask_bounds x 16 (le_refl 16)
  change 0 ≤ (x.bv &&& BitVec.ofNat 32 (2 ^ 16 - 1)).toInt ∧
         (x.bv &&& BitVec.ofNat 32 (2 ^ 16 - 1)).toInt < 65536 at h
  change 0 ≤ (x.bv &&& 65535#32).toInt ∧ (x.bv &&& 65535#32).toInt ≤ 65535
  have hm : BitVec.ofNat 32 (2 ^ 16 - 1) = 65535#32 := by decide
  rw [hm] at h
  omega

private lemma i32_band_16383_bounds (x : Std.I32) :
    0 ≤ (Pion.I32.band x 16383#i32).val ∧ (Pion.I32.band x 16383#i32).val ≤ 16383 := by
  have h := i32_band_mask_bounds x 14 (by omega)
  change 0 ≤ (x.bv &&& BitVec.ofNat 32 (2 ^ 14 - 1)).toInt ∧
         (x.bv &&& BitVec.ofNat 32 (2 ^ 14 - 1)).toInt < 16384 at h
  change 0 ≤ (x.bv &&& 16383#32).toInt ∧ (x.bv &&& 16383#32).toInt ≤ 16383
  have hm : BitVec.ofNat 32 (2 ^ 14 - 1) = 16383#32 := by decide
  rw [hm] at h
  omega

/-- Theorem 13: `crc16_bit_step` is total and always produces a 16-bit masked value in `[0, 65535]`. -/
theorem crc16_bit_step_bounds (crc : Std.I32) :
    ∃ r : Std.I32, crc16_bit_step crc = ok r ∧ 0 ≤ r.val ∧ r.val ≤ 65535 := by
  unfold crc16_bit_step
  by_cases h : Pion.I32.band crc 32768#i32 = 0#i32
  · simp only [ne_eq, h, not_true_eq_false, ↓reduceIte, i32_shl1_ok, result_bind_ok]
    exact ⟨_, rfl, i32_band_65535_bounds _⟩
  · simp only [ne_eq, h, not_false_eq_true, ↓reduceIte, i32_shl1_ok, result_bind_ok]
    exact ⟨_, rfl, i32_band_65535_bounds _⟩

/-- Theorem 14: `crc16_bit_step` fixes `0` (`0 → 0`). -/
theorem crc16_bit_step_zero :
    crc16_bit_step 0#i32 = ok 0#i32 := by
  unfold crc16_bit_step
  have h : Pion.I32.band 0#i32 32768#i32 = 0#i32 := by decide
  simp only [h, ne_eq, not_true_eq_false, ↓reduceIte, i32_shl1_ok, result_bind_ok]
  rfl

/-- Theorem 15: `crc16_bit_step` maps `0x8000` directly to the CRC16-XMODEM generator polynomial `0x1021` (`4129`). -/
theorem crc16_bit_step_msb_poly :
    crc16_bit_step 32768#i32 = ok 4129#i32 := by
  unfold crc16_bit_step
  have h : (Pion.I32.band 32768#i32 32768#i32 = 0#i32) = false := by decide
  simp only [ne_eq, h, Bool.false_eq_true, not_false_eq_true, ↓reduceIte, i32_shl1_ok, result_bind_ok]
  rfl

/-- Theorem 16: For `0 ≤ crc < 32768` (MSB clear), `crc16_bit_step` doubles `crc` exactly (`2 * crc`). -/
theorem crc16_bit_step_low_exact (crc : Std.I32) (h0 : 0 ≤ crc.val) (hhi : crc.val < 32768) :
    ∃ r : Std.I32, crc16_bit_step crc = ok r ∧ r.val = 2 * crc.val := by
  have hnat : crc.bv.toNat < 32768 := by
    change 0 ≤ crc.bv.toInt at h0
    change crc.bv.toInt < 32768 at hhi
    rw [BitVec.toInt_eq_toNat_cond] at h0 hhi
    split_ifs at h0 hhi <;> omega
  have hmsb : Pion.I32.band crc 32768#i32 = 0#i32 := by
    apply IScalar.eq_of_val_eq
    change (crc.bv &&& 32768#32).toInt = (0#32 : BitVec 32).toInt
    have hband0 : (crc.bv &&& 32768#32).toNat = 0 := by
      rw [BitVec.toNat_and]
      have h32k : (32768#32 : BitVec 32).toNat = 2 ^ 15 := by decide
      rw [h32k, Nat.and_two_pow]
      have hdiv : crc.bv.toNat / 2 ^ 15 = 0 := Nat.div_eq_of_lt hnat
      simp only [Nat.testBit, Nat.shiftRight_eq_div_pow, hdiv]
      decide
    rw [BitVec.toInt_eq_toNat_cond, hband0]
    decide
  unfold crc16_bit_step
  simp only [hmsb, ne_eq, not_true_eq_false, ↓reduceIte, i32_shl1_ok, result_bind_ok]
  refine ⟨Pion.I32.band ⟨crc.bv <<< 1⟩ 65535#i32, rfl, ?_⟩
  change ((crc.bv <<< 1) &&& 65535#32).toInt = 2 * crc.bv.toInt
  have hshl : (crc.bv <<< 1).toNat = 2 * crc.bv.toNat := by
    rw [BitVec.toNat_shiftLeft]
    have : crc.bv.toNat * 2 < 2 ^ 32 := by omega
    rw [Nat.shiftLeft_eq, Nat.pow_one, Nat.mod_eq_of_lt this]
    omega
  have hmask : ((crc.bv <<< 1) &&& 65535#32).toNat = 2 * crc.bv.toNat := by
    rw [BitVec.toNat_and, hshl]
    have h65 : (65535#32 : BitVec 32).toNat = 2 ^ 16 - 1 := by decide
    rw [h65, Nat.and_two_pow_sub_one_eq_mod]
    exact Nat.mod_eq_of_lt (by omega)
  rw [BitVec.toInt_eq_toNat_cond, BitVec.toInt_eq_toNat_cond, hmask]
  split_ifs <;> omega

/-- Theorem 17: `crc16_to_slot` always produces a valid Redis Cluster slot in `[0, 16383]` passing `is_valid_cluster_slot`. -/
theorem crc16_to_slot_valid (crc : Std.I32) :
    ∃ s : Std.I32,
      crc16_to_slot crc = ok s ∧
      0 ≤ s.val ∧ s.val ≤ 16383 ∧
      is_valid_cluster_slot s = ok true := by
  obtain ⟨hlo, hhi⟩ := i32_band_16383_bounds crc
  refine ⟨Pion.I32.band crc 16383#i32, rfl, hlo, hhi, ?_⟩
  unfold is_valid_cluster_slot
  apply congrArg ok
  simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
  exact ⟨hlo, hhi⟩

/-- Theorem 18: For non-negative `crc`, `crc16_to_slot` computes `crc % 16384` exactly. -/
theorem crc16_to_slot_mod (crc : Std.I32) (h0 : 0 ≤ crc.val) :
    ∃ s : Std.I32, crc16_to_slot crc = ok s ∧ s.val = crc.val % 16384 := by
  refine ⟨Pion.I32.band crc 16383#i32, rfl, ?_⟩
  change (crc.bv &&& 16383#32).toInt = crc.bv.toInt % 16384
  have hlt31 : crc.bv.toNat < 2 ^ 31 := by
    change 0 ≤ crc.bv.toInt at h0
    rw [BitVec.toInt_eq_toNat_cond] at h0
    split_ifs at h0 <;> omega
  have hhand : (crc.bv &&& 16383#32).toNat = crc.bv.toNat % 16384 := by
    rw [BitVec.toNat_and]
    have h16k : (16383#32 : BitVec 32).toNat = 2 ^ 14 - 1 := by decide
    rw [h16k, Nat.and_two_pow_sub_one_eq_mod]
  rw [BitVec.toInt_eq_toNat_cond, BitVec.toInt_eq_toNat_cond, hhand]
  split_ifs <;> omega

/-- Theorem 19: `crc16_to_slot` is idempotent across all `Int32`. -/
theorem crc16_to_slot_idempotent (crc : Std.I32) :
    (do let s ← crc16_to_slot crc; crc16_to_slot s) = crc16_to_slot crc := by
  unfold crc16_to_slot
  rw [result_bind_ok]
  apply congrArg ok
  apply IScalar.eq_of_val_eq
  change ((crc.bv &&& 16383#32) &&& 16383#32).toInt = (crc.bv &&& 16383#32).toInt
  have hbv : (crc.bv &&& 16383#32) &&& 16383#32 = crc.bv &&& 16383#32 := by
    rw [BitVec.and_assoc, BitVec.and_self]
  rw [hbv]

/-- Theorem 20: `is_valid_cluster_slot` is an exact iff characterization of `[0, 16383]`. -/
theorem is_valid_cluster_slot_iff (slot : Std.I32) :
    is_valid_cluster_slot slot = ok true ↔ 0 ≤ slot.val ∧ slot.val ≤ 16383 := by
  unfold is_valid_cluster_slot
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
  rfl

/-- Theorem 21: `is_valid_cluster_slot` accepts boundary slots `0` & `16383` and rejects `-1` & `16384`. -/
theorem is_valid_cluster_slot_boundaries :
    is_valid_cluster_slot 0#i32 = ok true ∧
    is_valid_cluster_slot 16383#i32 = ok true ∧
    is_valid_cluster_slot (-1)#i32 = ok false ∧
    is_valid_cluster_slot 16384#i32 = ok false := by
  refine ⟨?_, ?_, ?_, ?_⟩ <;> (unfold is_valid_cluster_slot; rfl)

/-- Theorem 22: `is_valid_slot_range` is an exact iff characterization of `0 ≤ start ≤ end ≤ 16383`. -/
theorem is_valid_slot_range_iff (s e : Std.I32) :
    is_valid_slot_range s e = ok true ↔ 0 ≤ s.val ∧ s.val ≤ e.val ∧ e.val ≤ 16383 := by
  unfold is_valid_slot_range
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
  change ((0 ≤ s.val ∧ e.val ≤ 16383) ∧ s.val ≤ e.val) ↔ _
  tauto

/-- Theorem 23: Every valid slot range implies both endpoints are valid cluster slots. -/
theorem is_valid_slot_range_endpoints_valid (s e : Std.I32)
    (h : is_valid_slot_range s e = ok true) :
    is_valid_cluster_slot s = ok true ∧ is_valid_cluster_slot e = ok true := by
  rw [is_valid_slot_range_iff] at h
  rw [is_valid_cluster_slot_iff, is_valid_cluster_slot_iff]
  omega

/-- Theorem 24: A singleton range `[s, s]` is valid iff `s` is a valid cluster slot. -/
theorem is_valid_slot_range_singleton_iff (s : Std.I32) :
    is_valid_slot_range s s = ok true ↔ is_valid_cluster_slot s = ok true := by
  rw [is_valid_slot_range_iff, is_valid_cluster_slot_iff]
  omega

end RespProofs
