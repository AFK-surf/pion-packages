import WebsocketProofs.Core

open Aeneas Aeneas.Std Result Pion websocket

namespace WebsocketProofs

/-- RFC 6455 §5.3 XOR masking involution: applying the same mask byte twice restores the original byte. -/
theorem mask_byte_xor_involutive (b m : Std.I32) :
    (do let x ← mask_byte_xor b m; mask_byte_xor x m) = ok b := by
  unfold mask_byte_xor
  rw [result_bind_ok]
  congr 1
  unfold Pion.I32.bxor
  cases b with | mk bv =>
  cases m with | mk mv =>
  change IScalar.mk ((bv ^^^ mv) ^^^ mv) = IScalar.mk bv
  congr 1
  rw [BitVec.xor_assoc, BitVec.xor_self, BitVec.xor_zero]

lemma i32_band_3_bounds (idx : Std.I32) :
    0 ≤ (Pion.I32.band idx 3#i32).val ∧ (Pion.I32.band idx 3#i32).val ≤ 3 := by
  unfold Pion.I32.band
  change 0 ≤ (idx.bv &&& 3#32).toInt ∧ (idx.bv &&& 3#32).toInt ≤ 3
  have hlt : (idx.bv &&& 3#32).toNat ≤ 3 := by
    rw [BitVec.toNat_and]
    exact Nat.le_trans Nat.and_le_right (by norm_num)
  rw [BitVec.toInt_eq_toNat_cond]
  have hcond : 2 * (idx.bv &&& 3#32).toNat < 2 ^ 32 := by omega
  rw [ite_eq_left hcond]
  omega

/-- `mask_key_byte` never overflows shift bounds and always returns a byte in `[0, 255]`. -/
theorem mask_key_byte_bounds (mask_key : Std.U32) (idx : Std.I32) :
    ∃ r : Std.I32, mask_key_byte mask_key idx = ok r ∧ 0 ≤ r.val ∧ r.val ≤ 255 := by
  unfold mask_key_byte
  set lane := Pion.I32.band idx 3#i32
  have hlane : 0 ≤ lane.val ∧ lane.val ≤ 3 := i32_band_3_bounds idx
  have h3v : (3#i32).val = 3 := by norm_num
  have h8v : (8#i32).val = 8 := by norm_num
  have hsub : (Pion.I32.sub 3#i32 lane).val = 3 - lane.val := by
    rw [i32_sub_val 3#i32 lane (by rw [h3v]; omega) (by rw [h3v]; omega), h3v]
  set shift := Pion.I32.mul (Pion.I32.sub 3#i32 lane) 8#i32
  have hshift : shift.val = (3 - lane.val) * 8 := by
    change (Pion.I32.mul (Pion.I32.sub 3#i32 lane) 8#i32).val = _
    rw [i32_mul_val (Pion.I32.sub 3#i32 lane) 8#i32 (by rw [hsub, h8v]; omega) (by rw [hsub, h8v]; omega), hsub, h8v]
  have hshr : Pion.U32.shr_i32 mask_key shift = ok (⟨mask_key.bv >>> shift.val.toNat⟩ : Std.U32) := by
    unfold Pion.U32.shr_i32
    have hc : 0 ≤ shift.val ∧ shift.val < 32 := by omega
    simp only [hc, and_self, ↓reduceIte]
  dsimp only
  rw [hshr, result_bind_ok]
  set res := Pion.U32.to_int (Pion.U32.band (⟨mask_key.bv >>> shift.val.toNat⟩ : Std.U32) 255#u32)
  refine ⟨res, rfl, ?_, ?_⟩
  · have hlt : ((mask_key.bv >>> shift.val.toNat) &&& 255#32).toNat ≤ 255 := by
      rw [BitVec.toNat_and]
      exact Nat.le_trans Nat.and_le_right (by norm_num)
    change 0 ≤ ((mask_key.bv >>> shift.val.toNat) &&& 255#32).toInt
    rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
    omega
  · have hlt : ((mask_key.bv >>> shift.val.toNat) &&& 255#32).toNat ≤ 255 := by
      rw [BitVec.toNat_and]
      exact Nat.le_trans Nat.and_le_right (by norm_num)
    change ((mask_key.bv >>> shift.val.toNat) &&& 255#32).toInt ≤ 255
    rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
    omega

/-- `mask_key_byte` is periodic with period 4 (`idx + 4` selects the same mask byte as `idx`). -/
theorem mask_key_byte_periodic (mask_key : Std.U32) (idx : Std.I32) :
    mask_key_byte mask_key (Pion.I32.add idx 4#i32) = mask_key_byte mask_key idx := by
  unfold mask_key_byte
  have hlane_eq : Pion.I32.band (Pion.I32.add idx 4#i32) 3#i32 = Pion.I32.band idx 3#i32 := by
    unfold Pion.I32.band Pion.I32.add
    change (⟨(idx.bv + 4#32) &&& 3#32⟩ : Std.I32) = ⟨idx.bv &&& 3#32⟩
    congr 1
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_and, BitVec.toNat_and, BitVec.toNat_add]
    have h3 : (3#32).toNat = 3 := by norm_num
    have h4 : (4#32).toNat = 4 := by norm_num
    rw [h3, h4]
    have hmod : ∀ n : Nat, n &&& 3 = n % 4 := fun n => by
      have : (3 : Nat) = 2 ^ 2 - 1 := by norm_num
      rw [this, Nat.and_two_pow_sub_one_eq_mod]
    rw [hmod, hmod]
    have hpow : (2 : Nat) ^ 32 = 4 * 1073741824 := by norm_num
    omega
  rw [hlane_eq]

/-- RFC 6455 §5.2: exact specification of `encoded_ext_len`. -/
private lemma encoded_ext_len_spec (plen : Std.I32) :
    (plen.val < 126 → encoded_ext_len plen = ok 0#i32) ∧
    (126 ≤ plen.val ∧ plen.val ≤ 65535 → encoded_ext_len plen = ok 2#i32) ∧
    (65535 < plen.val → encoded_ext_len plen = ok 8#i32) := by
  have h126 : (126#i32).val = 126 := by norm_num
  have h65535 : (65535#i32).val = 65535 := by norm_num
  refine ⟨?_, ?_, ?_⟩
  · intro h
    unfold encoded_ext_len
    have hlt : plen < 126#i32 := (iscalar_lt_iff plen 126#i32).mpr (by omega)
    simp only [hlt, ↓reduceIte]
  · intro h
    unfold encoded_ext_len
    have hlt : ¬(plen < 126#i32) := fun hc => by have := (iscalar_lt_iff plen 126#i32).mp hc; omega
    have hle : plen ≤ 65535#i32 := (iscalar_le_iff plen 65535#i32).mpr (by omega)
    simp only [hlt, hle, ↓reduceIte]
  · intro h
    unfold encoded_ext_len
    have hlt : ¬(plen < 126#i32) := fun hc => by have := (iscalar_lt_iff plen 126#i32).mp hc; omega
    have hle : ¬(plen ≤ 65535#i32) := fun hc => by have := (iscalar_le_iff plen 65535#i32).mp hc; omega
    simp only [hlt, hle, ↓reduceIte]

/-- RFC 6455 §5.2: `encoded_header_len` is always in `[2, 14]`. -/
theorem encoded_header_len_bounds (plen : Std.I32) (masked : Bool) :
    ∃ h : Std.I32, encoded_header_len plen masked = ok h ∧ 2 ≤ h.val ∧ h.val ≤ 14 := by
  unfold encoded_header_len
  obtain ⟨h0, h2, h8⟩ := encoded_ext_len_spec plen
  by_cases c1 : plen.val < 126
  · rw [h0 c1, result_bind_ok]
    cases masked <;> exact ⟨_, rfl, by norm_num, by norm_num⟩
  · by_cases c2 : plen.val ≤ 65535
    · rw [h2 ⟨by omega, c2⟩, result_bind_ok]
      cases masked <;> exact ⟨_, rfl, by norm_num, by norm_num⟩
    · rw [h8 (by omega), result_bind_ok]
      cases masked <;> exact ⟨_, rfl, by norm_num, by norm_num⟩

/-- RFC 6455 §5.2: 64-bit payload length with MSB = 1 is rejected (`1`). -/
theorem check_ext_len64_rejects_msb (h2 : Std.I32) (len64 : Std.I64) (m : Std.I32)
    (hmsb : Pion.I32.band h2 128#i32 ≠ 0#i32) :
    check_ext_len64 h2 len64 m = ok 1#i32 := by
  unfold check_ext_len64
  rw [ite_eq_left hmsb]

/-- RFC 6455 §5.2: 64-bit payload length exceeding `max_message_size` is rejected (`3`). -/
theorem check_ext_len64_rejects_too_large (h2 : Std.I32) (len64 : Std.I64) (m : Std.I32)
    (hmsb : Pion.I32.band h2 128#i32 = 0#i32)
    (hmin : 65536 ≤ len64.val)
    (hbig : m.val < len64.val) :
    check_ext_len64 h2 len64 m = ok 3#i32 := by
  have h65536 := u16_max_plus_1_i64_val
  have hm := i32_to_int64_val m
  unfold check_ext_len64
  have hne : ¬(Pion.I32.band h2 128#i32 ≠ 0#i32) := not_not.mpr hmsb
  have hlt : ¬(len64 < 65536#i64) := fun hc => by have := (iscalar_lt_iff len64 65536#i64).mp hc; omega
  have hgt : len64 > Pion.I32.to_int64 m := (iscalar_lt_iff (Pion.I32.to_int64 m) len64).mpr (by omega)
  simp only [hne, hlt, hgt, ↓reduceIte]

end WebsocketProofs
