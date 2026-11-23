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

/-- RFC 1035 §4.1.1: `unpack_header_aa` recovers `aa` from `pack_header_flags_hi`. -/
theorem pack_header_flags_hi_aa (qr : Bool) (op : Std.I32) (aa tc rd : Bool) :
    (do let b ← pack_header_flags_hi qr op aa tc rd; unpack_header_aa b) = ok aa := by
  unfold pack_header_flags_hi unpack_header_aa
  rw [i32_shl_3, result_bind_ok, result_bind_ok]
  congr 1
  have hop0 := op_shl3_and_bit op 4#i32 (by decide)
  simp only [i32_band_bv] at hop0
  have heq : Pion.I32.band (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor
      (if qr then 128#i32 else 0#i32) ⟨(Pion.I32.band op 15#i32).bv <<< 3⟩)
      (if aa then 4#i32 else 0#i32)) (if tc then 2#i32 else 0#i32)) (if rd then 1#i32 else 0#i32)) 4#i32 =
      (if aa then 4#i32 else 0#i32) := by
    apply i32_eq_of_bv
    simp only [i32_band_bv, i32_bor_bv]
    rw [bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, hop0]
    cases qr <;> cases aa <;> cases tc <;> cases rd <;> decide
  rw [heq]; cases aa <;> decide

/-- RFC 1035 §4.1.1: `unpack_header_tc` recovers `tc` from `pack_header_flags_hi`. -/
theorem pack_header_flags_hi_tc (qr : Bool) (op : Std.I32) (aa tc rd : Bool) :
    (do let b ← pack_header_flags_hi qr op aa tc rd; unpack_header_tc b) = ok tc := by
  unfold pack_header_flags_hi unpack_header_tc
  rw [i32_shl_3, result_bind_ok, result_bind_ok]
  congr 1
  have hop0 := op_shl3_and_bit op 2#i32 (by decide)
  simp only [i32_band_bv] at hop0
  have heq : Pion.I32.band (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor
      (if qr then 128#i32 else 0#i32) ⟨(Pion.I32.band op 15#i32).bv <<< 3⟩)
      (if aa then 4#i32 else 0#i32)) (if tc then 2#i32 else 0#i32)) (if rd then 1#i32 else 0#i32)) 2#i32 =
      (if tc then 2#i32 else 0#i32) := by
    apply i32_eq_of_bv
    simp only [i32_band_bv, i32_bor_bv]
    rw [bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, hop0]
    cases qr <;> cases aa <;> cases tc <;> cases rd <;> decide
  rw [heq]; cases tc <;> decide

/-- RFC 1035 §4.1.1: `unpack_header_rd` recovers `rd` from `pack_header_flags_hi`. -/
theorem pack_header_flags_hi_rd (qr : Bool) (op : Std.I32) (aa tc rd : Bool) :
    (do let b ← pack_header_flags_hi qr op aa tc rd; unpack_header_rd b) = ok rd := by
  unfold pack_header_flags_hi unpack_header_rd
  rw [i32_shl_3, result_bind_ok, result_bind_ok]
  congr 1
  have hop0 := op_shl3_and_bit op 1#i32 (by decide)
  simp only [i32_band_bv] at hop0
  have heq : Pion.I32.band (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor
      (if qr then 128#i32 else 0#i32) ⟨(Pion.I32.band op 15#i32).bv <<< 3⟩)
      (if aa then 4#i32 else 0#i32)) (if tc then 2#i32 else 0#i32)) (if rd then 1#i32 else 0#i32)) 1#i32 =
      (if rd then 1#i32 else 0#i32) := by
    apply i32_eq_of_bv
    simp only [i32_band_bv, i32_bor_bv]
    rw [bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, hop0]
    cases qr <;> cases aa <;> cases tc <;> cases rd <;> decide
  rw [heq]; cases rd <;> decide

/-- RFC 1035 §4.1.1: `unpack_header_opcode` recovers `op` (`0 ≤ op < 16`) from `pack_header_flags_hi`. -/
theorem pack_header_flags_hi_opcode (qr : Bool) (op : Std.I32) (aa tc rd : Bool)
    (h0 : 0 ≤ op.val) (h16 : op.val < 16) :
    (do let b ← pack_header_flags_hi qr op aa tc rd; unpack_header_opcode b) = ok op := by
  unfold pack_header_flags_hi unpack_header_opcode
  rw [i32_shl_3, result_bind_ok, result_bind_ok, i32_shr_3, result_bind_ok]
  congr 1
  apply i32_eq_of_bv
  have hmask := i32_mask_15_of_range op h0 h16
  rw [i32_band_bv]
  ext i hi
  rw [BitVec.getElem_and]
  by_cases h4 : i < 4
  · have hlt : 3 + i < 32 := by omega
    have hlt' : 3 + i < IScalarTy.I32.numBits := hlt
    have h15t : (15#i32).bv[i] = true := by
      rw [BitVec.getElem_eq_testBit_toNat]
      rcases (by omega : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3) with rfl | rfl | rfl | rfl <;> decide
    have hqr : (if qr then 128#i32 else 0#i32).bv[3 + i]'hlt' = false := by
      rw [BitVec.getElem_eq_testBit_toNat]
      cases qr <;> rcases (by omega : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3) with rfl | rfl | rfl | rfl <;> decide
    have haa : (if aa then 4#i32 else 0#i32).bv[3 + i]'hlt' = false := by
      rw [BitVec.getElem_eq_testBit_toNat]
      cases aa <;> rcases (by omega : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3) with rfl | rfl | rfl | rfl <;> decide
    have htc : (if tc then 2#i32 else 0#i32).bv[3 + i]'hlt' = false := by
      rw [BitVec.getElem_eq_testBit_toNat]
      cases tc <;> rcases (by omega : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3) with rfl | rfl | rfl | rfl <;> decide
    have hrd : (if rd then 1#i32 else 0#i32).bv[3 + i]'hlt' = false := by
      rw [BitVec.getElem_eq_testBit_toNat]
      cases rd <;> rcases (by omega : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3) with rfl | rfl | rfl | rfl <;> decide
    change (((Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (if qr then 128#i32 else 0#i32)
      ⟨(Pion.I32.band op 15#i32).bv <<< 3⟩) (if aa then 4#i32 else 0#i32))
      (if tc then 2#i32 else 0#i32)) (if rd then 1#i32 else 0#i32)).bv.sshiftRight 3)[i] && (15#i32).bv[i]) = op.bv[i]
    rw [BitVec.getElem_sshiftRight, dite_eq_left hlt]
    simp only [i32_bor_bv, BitVec.getElem_or, hqr, haa, htc, hrd, h15t, Bool.false_or, Bool.or_false, Bool.and_true]
    change ((Pion.I32.band op 15#i32).bv <<< 3)[3 + i]'hlt = op.bv[i]
    rw [BitVec.getElem_shiftLeft]
    have hge3 : ¬(3 + i < 3) := by omega
    have hsub : 3 + i - 3 = i := by omega
    simp only [hge3, decide_false, Bool.not_false, Bool.true_and, hsub, hmask]
  · have h15f : (15#i32).bv[i] = false := by
      have htoNat : (15#i32).bv.toNat = 15 := by decide
      rw [BitVec.getElem_eq_testBit_toNat, htoNat]
      exact Nat.testBit_lt_two_pow (by
        have : (15 : Nat) < 2 ^ 4 := by norm_num
        have : (2 : Nat) ^ 4 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
        omega)
    have hopf : op.bv[i] = false := by
      rw [← hmask, i32_band_bv, BitVec.getElem_and, h15f, Bool.and_false]
    simp only [h15f, Bool.and_false, hopf]

/-- RFC 1035 §4.1.1 + RFC 4035: `pack_header_flags_lo` always produces a byte in `[0, 255]`. -/
theorem pack_header_flags_lo_bounds (ra z ad cd : Bool) (rc : Std.I32) :
    ∃ b : Std.I32, pack_header_flags_lo ra z ad cd rc = ok b ∧ 0 ≤ b.val ∧ b.val < 256 := by
  unfold pack_header_flags_lo
  refine ⟨_, rfl, ?_⟩
  set b : Std.I32 := Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor
    (if ra then 128#i32 else 0#i32) (if z then 64#i32 else 0#i32))
    (if ad then 32#i32 else 0#i32)) (if cd then 16#i32 else 0#i32)) (Pion.I32.band rc 15#i32)
  have hrc : (Pion.I32.band rc 15#i32).bv.toNat < 16 := i32_band_15_toNat_lt rc
  have h_or : ∀ (x y : BitVec IScalarTy.I32.numBits), x.toNat < 256 → y.toNat < 256 → (x ||| y).toNat < 256 := by
    intro x y hx hy; rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow (n := 8) hx hy
  have hra : (if ra then 128#i32 else 0#i32).bv.toNat < 256 := by cases ra <;> decide
  have hz : (if z then 64#i32 else 0#i32).bv.toNat < 256 := by cases z <;> decide
  have had : (if ad then 32#i32 else 0#i32).bv.toNat < 256 := by cases ad <;> decide
  have hcd : (if cd then 16#i32 else 0#i32).bv.toNat < 256 := by cases cd <;> decide
  have hlow : b.bv.toNat < 256 := h_or _ _ (h_or _ _ (h_or _ _ (h_or _ _ hra hz) had) hcd) (by omega)
  have hval : b.val = (b.bv.toNat : Int) := by
    change b.bv.toInt = _; rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
  omega

/-- RFC 1035 §4.1.1 + RFC 4035: `unpack_header_ra/z/ad/cd` recover all 4 flag bits from `pack_header_flags_lo`. -/
theorem pack_header_flags_lo_flags (ra z ad cd : Bool) (rc : Std.I32) :
    (do let b ← pack_header_flags_lo ra z ad cd rc; unpack_header_ra b) = ok ra ∧
    (do let b ← pack_header_flags_lo ra z ad cd rc; unpack_header_z b) = ok z ∧
    (do let b ← pack_header_flags_lo ra z ad cd rc; unpack_header_ad b) = ok ad ∧
    (do let b ← pack_header_flags_lo ra z ad cd rc; unpack_header_cd b) = ok cd := by
  have h15_128 : (15#i32).bv &&& (128#i32).bv = 0#32 := by decide
  have h15_64 : (15#i32).bv &&& (64#i32).bv = 0#32 := by decide
  have h15_32 : (15#i32).bv &&& (32#i32).bv = 0#32 := by decide
  have h15_16 : (15#i32).bv &&& (16#i32).bv = 0#32 := by decide
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold pack_header_flags_lo unpack_header_ra; rw [result_bind_ok]; congr 1
    have heq : Pion.I32.band (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor
        (if ra then 128#i32 else 0#i32) (if z then 64#i32 else 0#i32))
        (if ad then 32#i32 else 0#i32)) (if cd then 16#i32 else 0#i32)) (Pion.I32.band rc 15#i32)) 128#i32 =
        (if ra then 128#i32 else 0#i32) := by
      apply i32_eq_of_bv; simp only [i32_band_bv, i32_bor_bv]
      rw [bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib,
          BitVec.and_assoc, h15_128, BitVec.and_zero]
      cases ra <;> cases z <;> cases ad <;> cases cd <;> decide
    rw [heq]; cases ra <;> decide
  · unfold pack_header_flags_lo unpack_header_z; rw [result_bind_ok]; congr 1
    have heq : Pion.I32.band (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor
        (if ra then 128#i32 else 0#i32) (if z then 64#i32 else 0#i32))
        (if ad then 32#i32 else 0#i32)) (if cd then 16#i32 else 0#i32)) (Pion.I32.band rc 15#i32)) 64#i32 =
        (if z then 64#i32 else 0#i32) := by
      apply i32_eq_of_bv; simp only [i32_band_bv, i32_bor_bv]
      rw [bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib,
          BitVec.and_assoc, h15_64, BitVec.and_zero]
      cases ra <;> cases z <;> cases ad <;> cases cd <;> decide
    rw [heq]; cases z <;> decide
  · unfold pack_header_flags_lo unpack_header_ad; rw [result_bind_ok]; congr 1
    have heq : Pion.I32.band (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor
        (if ra then 128#i32 else 0#i32) (if z then 64#i32 else 0#i32))
        (if ad then 32#i32 else 0#i32)) (if cd then 16#i32 else 0#i32)) (Pion.I32.band rc 15#i32)) 32#i32 =
        (if ad then 32#i32 else 0#i32) := by
      apply i32_eq_of_bv; simp only [i32_band_bv, i32_bor_bv]
      rw [bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib,
          BitVec.and_assoc, h15_32, BitVec.and_zero]
      cases ra <;> cases z <;> cases ad <;> cases cd <;> decide
    rw [heq]; cases ad <;> decide
  · unfold pack_header_flags_lo unpack_header_cd; rw [result_bind_ok]; congr 1
    have heq : Pion.I32.band (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor
        (if ra then 128#i32 else 0#i32) (if z then 64#i32 else 0#i32))
        (if ad then 32#i32 else 0#i32)) (if cd then 16#i32 else 0#i32)) (Pion.I32.band rc 15#i32)) 16#i32 =
        (if cd then 16#i32 else 0#i32) := by
      apply i32_eq_of_bv; simp only [i32_band_bv, i32_bor_bv]
      rw [bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib,
          BitVec.and_assoc, h15_16, BitVec.and_zero]
      cases ra <;> cases z <;> cases ad <;> cases cd <;> decide
    rw [heq]; cases cd <;> decide

/-- RFC 1035 §4.1.1: `unpack_header_rcode` recovers `rc` (`0 ≤ rc < 16`) from `pack_header_flags_lo`. -/
theorem pack_header_flags_lo_rcode (ra z ad cd : Bool) (rc : Std.I32)
    (h0 : 0 ≤ rc.val) (h16 : rc.val < 16) :
    (do let b ← pack_header_flags_lo ra z ad cd rc; unpack_header_rcode b) = ok rc := by
  unfold pack_header_flags_lo unpack_header_rcode
  rw [result_bind_ok]
  congr 1
  apply i32_eq_of_bv
  have hmask := i32_mask_15_of_range rc h0 h16
  rw [i32_band_bv] at hmask
  simp only [i32_band_bv, i32_bor_bv]
  rw [bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, hmask, hmask]
  have h128 : (128#i32).bv &&& (15#i32).bv = 0#32 := by decide
  have h64 : (64#i32).bv &&& (15#i32).bv = 0#32 := by decide
  have h32 : (32#i32).bv &&& (15#i32).bv = 0#32 := by decide
  have h16m : (16#i32).bv &&& (15#i32).bv = 0#32 := by decide
  have h0m : (0#i32).bv &&& (15#i32).bv = 0#32 := by decide
  cases ra <;> cases z <;> cases ad <;> cases cd <;>
    simp only [↓reduceIte, Bool.false_eq_true, h128, h64, h32, h16m, h0m, BitVec.zero_or]

end DnsProofs
