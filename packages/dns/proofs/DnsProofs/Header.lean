import DnsProofs.Core

open Aeneas Aeneas.Std Result Pion dns

namespace DnsProofs

private lemma i32_shl_3 (x : Std.I32) :
    Pion.I32.shl x 3#i32 = ok (⟨x.bv <<< 3⟩ : Std.I32) := by
  unfold Pion.I32.shl
  have hc : 0 ≤ (3#i32).val ∧ (3#i32).val < 32 := by norm_num
  have h3 : (3#i32).val.toNat = 3 := by norm_num
  simp only [hc, and_self, ↓reduceIte, h3]

private lemma i32_shr_3 (x : Std.I32) :
    Pion.I32.shr x 3#i32 = ok (⟨x.bv.sshiftRight 3⟩ : Std.I32) := by
  unfold Pion.I32.shr
  have hc : 0 ≤ (3#i32).val ∧ (3#i32).val < 32 := by norm_num
  have h3 : (3#i32).val.toNat = 3 := by norm_num
  simp only [hc, and_self, ↓reduceIte, h3]

private lemma bv_and_or_distrib (x y z : BitVec IScalarTy.I32.numBits) :
    (x ||| y) &&& z = (x &&& z) ||| (y &&& z) := by
  ext i; simp [Bool.and_or_distrib_right]

private lemma i32_mask_15_of_range (r : Std.I32) (h0 : 0 ≤ r.val) (h16 : r.val < 16) :
    (Pion.I32.band r 15#i32).bv = r.bv := by
  rw [i32_band_bv]
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_and]
  have h15 : (15#i32).bv.toNat = 15 := by decide
  rw [h15]
  have hr_nat : r.bv.toNat = r.val.toNat := by
    have hti := BitVec.toInt_eq_toNat_cond r.bv
    have hlt : 2 * r.bv.toNat < 2 ^ 32 := by
      by_contra hge; push Not at hge
      rw [ite_eq_right (by omega)] at hti
      change r.bv.toInt ≥ 0 at h0
      omega
    rw [ite_eq_left hlt] at hti
    change r.bv.toNat = r.bv.toInt.toNat
    omega
  have hlt16 : r.bv.toNat < 16 := by omega
  have hmod : r.bv.toNat &&& 15 = r.bv.toNat % 16 := by
    have : (15 : Nat) = 2 ^ 4 - 1 := by norm_num
    rw [this, Nat.and_two_pow_sub_one_eq_mod]
  rw [hmod, Nat.mod_eq_of_lt hlt16]

private lemma i32_band_15_toNat_lt (x : Std.I32) : (Pion.I32.band x 15#i32).bv.toNat < 16 := by
  rw [i32_band_bv, BitVec.toNat_and]
  have h15 : (15#i32).bv.toNat = 15 := by decide
  rw [h15]
  have hmod : x.bv.toNat &&& 15 = x.bv.toNat % 16 := by
    have : (15 : Nat) = 2 ^ 4 - 1 := by norm_num
    rw [this, Nat.and_two_pow_sub_one_eq_mod]
  rw [hmod]; exact Nat.mod_lt _ (by omega)

/-- RFC 1035 §4.1.1: `pack_header_flags_hi` always produces a byte in `[0, 255]`. -/
theorem pack_header_flags_hi_bounds (qr : Bool) (op : Std.I32) (aa tc rd : Bool) :
    ∃ b : Std.I32, pack_header_flags_hi qr op aa tc rd = ok b ∧ 0 ≤ b.val ∧ b.val < 256 := by
  unfold pack_header_flags_hi
  rw [i32_shl_3, result_bind_ok]
  refine ⟨_, rfl, ?_⟩
  set opm := Pion.I32.band op 15#i32
  set b : Std.I32 := Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor
    (if qr then 128#i32 else 0#i32) ⟨opm.bv <<< 3⟩)
    (if aa then 4#i32 else 0#i32)) (if tc then 2#i32 else 0#i32)) (if rd then 1#i32 else 0#i32)
  have hopm : opm.bv.toNat < 16 := i32_band_15_toNat_lt op
  have hop_shl : (opm.bv <<< 3).toNat < 256 := by
    rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq, Nat.mod_eq_of_lt (by omega)]
    omega
  have h_or : ∀ (x y : BitVec IScalarTy.I32.numBits), x.toNat < 256 → y.toNat < 256 → (x ||| y).toNat < 256 := by
    intro x y hx hy; rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow (n := 8) hx hy
  have hqr : (if qr then 128#i32 else 0#i32).bv.toNat < 256 := by cases qr <;> decide
  have haa : (if aa then 4#i32 else 0#i32).bv.toNat < 256 := by cases aa <;> decide
  have htc : (if tc then 2#i32 else 0#i32).bv.toNat < 256 := by cases tc <;> decide
  have hrd : (if rd then 1#i32 else 0#i32).bv.toNat < 256 := by cases rd <;> decide
  have hlow : b.bv.toNat < 256 := h_or _ _ (h_or _ _ (h_or _ _ (h_or _ _ hqr hop_shl) haa) htc) hrd
  have hval : b.val = (b.bv.toNat : Int) := by
    change b.bv.toInt = _; rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
  omega

private lemma op_shl3_and_bit (op m : Std.I32)
    (hm : m.bv[3] = false ∧ m.bv[4] = false ∧ m.bv[5] = false ∧ m.bv[6] = false) :
    (Pion.I32.band ⟨(Pion.I32.band op 15#i32).bv <<< 3⟩ m).bv = 0#32 := by
  rw [i32_band_bv]
  ext i hi
  rw [BitVec.getElem_and, BitVec.getElem_zero]
  change (((Pion.I32.band op 15#i32).bv <<< 3)[i] && m.bv[i]) = false
  rw [BitVec.getElem_shiftLeft]
  by_cases h3 : i < 3
  · simp only [h3, decide_true, Bool.not_true, Bool.false_and]
  · by_cases h7 : i < 7
    · rcases (by omega : i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6) with rfl | rfl | rfl | rfl
      · simp only [hm.1, Bool.and_false]
      · simp only [hm.2.1, Bool.and_false]
      · simp only [hm.2.2.1, Bool.and_false]
      · simp only [hm.2.2.2, Bool.and_false]
    · have h15 : (Pion.I32.band op 15#i32).bv[i - 3] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have hopm := i32_band_15_toNat_lt op
        exact Nat.testBit_lt_two_pow (by
          have : (2 : Nat) ^ 4 ≤ 2 ^ (i - 3) := Nat.pow_le_pow_right (by omega) (by omega)
          omega)
      simp only [h3, decide_false, Bool.not_false, Bool.true_and, h15, Bool.false_and]

/-- RFC 1035 §4.1.1: `unpack_header_qr` recovers `qr` from `pack_header_flags_hi`. -/
theorem pack_header_flags_hi_qr (qr : Bool) (op : Std.I32) (aa tc rd : Bool) :
    (do let b ← pack_header_flags_hi qr op aa tc rd; unpack_header_qr b) = ok qr := by
  unfold pack_header_flags_hi unpack_header_qr
  rw [i32_shl_3, result_bind_ok, result_bind_ok]
  congr 1
  have hop0 := op_shl3_and_bit op 128#i32 (by decide)
  simp only [i32_band_bv] at hop0
  have heq : Pion.I32.band (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor
      (if qr then 128#i32 else 0#i32) ⟨(Pion.I32.band op 15#i32).bv <<< 3⟩)
      (if aa then 4#i32 else 0#i32)) (if tc then 2#i32 else 0#i32)) (if rd then 1#i32 else 0#i32)) 128#i32 =
      (if qr then 128#i32 else 0#i32) := by
    apply i32_eq_of_bv
    simp only [i32_band_bv, i32_bor_bv]
    rw [bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, hop0]
    cases qr <;> cases aa <;> cases tc <;> cases rd <;> decide
  rw [heq]; cases qr <;> decide

end DnsProofs
