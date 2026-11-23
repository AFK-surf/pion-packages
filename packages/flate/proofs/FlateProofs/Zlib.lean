import FlateProofs.Core

open Aeneas Aeneas.Std Result Pion flate

namespace FlateProofs

private lemma i32_shl_const (x k : Std.I32) (h0 : 0 ≤ k.val) (h32 : k.val < 32) :
    Pion.I32.shl x k = ok (⟨x.bv <<< k.val.toNat⟩ : Std.I32) := by
  unfold Pion.I32.shl
  have hc : 0 ≤ k.val ∧ k.val < 32 := ⟨h0, h32⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma i32_shr_const (x k : Std.I32) (h0 : 0 ≤ k.val) (h32 : k.val < 32) :
    Pion.I32.shr x k = ok (⟨x.bv.sshiftRight k.val.toNat⟩ : Std.I32) := by
  unfold Pion.I32.shr
  have hc : 0 ≤ k.val ∧ k.val < 32 := ⟨h0, h32⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma zlib_flevel_spec (level : Std.I32) :
    (level.val ≤ 1 → zlib_flevel level = ok 0#i32) ∧
    (2 ≤ level.val ∧ level.val ≤ 5 → zlib_flevel level = ok 1#i32) ∧
    (level.val = 6 → zlib_flevel level = ok 2#i32) ∧
    (7 ≤ level.val → zlib_flevel level = ok 3#i32) := by
  have h1 : (1#i32).val = 1 := by norm_num
  have h5 : (5#i32).val = 5 := by norm_num
  have h6 : (6#i32).val = 6 := by norm_num
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro h; unfold zlib_flevel
    have c1 : level ≤ 1#i32 := (iscalar_le_iff _ _).mpr (by omega)
    simp only [c1, ↓reduceIte]
  · intro h; unfold zlib_flevel
    have c1 : ¬(level ≤ 1#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c2 : level ≤ 5#i32 := (iscalar_le_iff _ _).mpr (by omega)
    simp only [c1, c2, ↓reduceIte]
  · intro h; unfold zlib_flevel
    have c3 : level = 6#i32 := (iscalar_eq_iff _ _).mpr (by omega)
    rw [c3]
    have c1 : ¬((6#i32 : Std.I32) ≤ 1#i32) := by decide
    have c2 : ¬((6#i32 : Std.I32) ≤ 5#i32) := by decide
    simp only [c1, c2, ↓reduceIte]
  · intro h; unfold zlib_flevel
    have c1 : ¬(level ≤ 1#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c2 : ¬(level ≤ 5#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c3 : level ≠ 6#i32 := fun hc => by have := (iscalar_eq_iff _ _).mp hc; omega
    simp only [c1, c2, c3, ↓reduceIte]

private lemma zlib_flevel_bounds (level : Std.I32) :
    ∃ fl : Std.I32, zlib_flevel level = ok fl ∧ 0 ≤ fl.val ∧ fl.val ≤ 3 := by
  obtain ⟨h0, h1, h2, h3⟩ := zlib_flevel_spec level
  by_cases c1 : level.val ≤ 1
  · exact ⟨0#i32, h0 c1, by norm_num, by norm_num⟩
  · by_cases c2 : level.val ≤ 5
    · exact ⟨1#i32, h1 ⟨by omega, c2⟩, by norm_num, by norm_num⟩
    · by_cases c3 : level.val = 6
      · exact ⟨2#i32, h2 c3, by norm_num, by norm_num⟩
      · exact ⟨3#i32, h3 (by omega), by norm_num, by norm_num⟩

/-- RFC 1950 §2.2: `zlib_compute_flg` produces a byte `flg ∈ [0, 255]` satisfying `(cmf * 256 + flg) % 31 = 0`
    for EVERY `cmf ∈ [0, 255]` and `flevel ∈ [0, 3]`. -/
theorem zlib_compute_flg_fcheck (cmf flevel : Std.I32)
    (hcmf0 : 0 ≤ cmf.val) (hcmf1 : cmf.val ≤ 255)
    (hfl0 : 0 ≤ flevel.val) (hfl1 : flevel.val ≤ 3) :
    ∃ flg : Std.I32, zlib_compute_flg cmf flevel = ok flg ∧
      0 ≤ flg.val ∧ flg.val ≤ 255 ∧
      (cmf.val * 256 + flg.val) % 31 = 0 := by
  unfold zlib_compute_flg
  rw [i32_shl_const flevel 6#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h6n : (6#i32).val.toNat = 6 := by norm_num
  rw [h6n]
  set base : Std.I32 := ⟨flevel.bv <<< 6⟩
  have hbase_val : base.val = flevel.val * 64 := by
    have hpow : (2 : Nat) ^ 32 = 4294967296 := by norm_num
    have hflt : flevel.bv.toNat < 4294967296 := by have := flevel.bv.isLt; rw [hpow] at this; exact this
    have hti := BitVec.toInt_eq_toNat_cond flevel.bv
    rw [hpow] at hti
    have hfnat : flevel.bv.toNat = flevel.val.toNat := by
      have : flevel.bv.toInt = flevel.val := rfl
      by_cases hlt : 2 * flevel.bv.toNat < 4294967296
      · rw [ite_eq_left hlt] at hti; omega
      · rw [ite_eq_right hlt] at hti; omega
    have hshl : (flevel.bv <<< 6).toNat = flevel.bv.toNat * 64 := by
      rw [BitVec.toNat_shiftLeft, hpow, Nat.shiftLeft_eq]
      rw [Nat.mod_eq_of_lt (by omega)]
    have hti2 := BitVec.toInt_eq_toNat_cond (flevel.bv <<< 6)
    rw [hpow, hshl] at hti2
    change (flevel.bv <<< 6).toInt = flevel.val * 64
    rw [ite_eq_left (by omega)] at hti2
    omega
  have h256 : (256#i32).val = 256 := by norm_num
  have h31 : (31#i32).val = 31 := by norm_num
  have h0 : (0#i32).val = 0 := by norm_num
  have hmul : (Pion.I32.mul cmf 256#i32).val = cmf.val * 256 := by
    rw [i32_mul_val cmf 256#i32 (by rw [h256]; omega) (by rw [h256]; omega), h256]
  have hsum : (Pion.I32.add (Pion.I32.mul cmf 256#i32) base).val = cmf.val * 256 + base.val := by
    rw [i32_add_val _ base (by rw [hmul]; omega) (by rw [hmul]; omega), hmul]
  obtain ⟨r, hr_eq, hr_val⟩ := i32_rem_nonneg_val (Pion.I32.add (Pion.I32.mul cmf 256#i32) base) 31#i32
    (by rw [hsum]; omega) (by omega)
  rw [hr_eq, result_bind_ok]
  rw [hsum, h31] at hr_val
  by_cases hr0 : r = 0#i32
  · simp only [hr0, ↓reduceIte]
    have hr_is0 : (cmf.val * 256 + base.val) % 31 = 0 := by
      have : r.val = 0 := by rw [hr0]; exact h0
      omega
    have hflg : (Pion.I32.add base 0#i32).val = base.val := by
      rw [i32_add_val base 0#i32 (by omega) (by omega), h0]; omega
    refine ⟨Pion.I32.add base 0#i32, rfl, by omega, by omega, by rw [hflg]; exact hr_is0⟩
  · simp only [hr0, ↓reduceIte]
    have hr_ne0 : r.val ≠ 0 := fun e => hr0 ((iscalar_eq_iff r 0#i32).mpr (by omega))
    have hsub : (Pion.I32.sub 31#i32 r).val = 31 - r.val := by
      rw [i32_sub_val 31#i32 r (by omega) (by omega), h31]
    have hflg : (Pion.I32.add base (Pion.I32.sub 31#i32 r)).val = base.val + (31 - r.val) := by
      rw [i32_add_val base _ (by omega) (by omega), hsub]
    refine ⟨Pion.I32.add base (Pion.I32.sub 31#i32 r), rfl, by omega, by omega, ?_⟩
    rw [hflg]; omega

/-- RFC 1950 Encoder-Decoder Duality: for EVERY compression level, the zlib header `(0x78, zlib_compute_flg 0x78 (zlib_flevel level))`
    ALWAYS passes `zlib_check_header` with status `0`! -/
theorem zlib_encoder_decoder_duality (level : Std.I32) :
    (do let fl ← zlib_flevel level
        let flg ← zlib_compute_flg 120#i32 fl
        zlib_check_header 120#i32 flg) = ok 0#i32 := by
  obtain ⟨fl, hfl, hfl0, hfl3⟩ := zlib_flevel_bounds level
  rw [hfl, result_bind_ok]
  have h120 : (120#i32).val = 120 := by norm_num
  obtain ⟨flg, hflg, hflg0, hflg255, hfcheck⟩ := zlib_compute_flg_fcheck 120#i32 fl (by omega) (by omega) hfl0 hfl3
  rw [hflg, result_bind_ok]
  unfold zlib_check_header
  have h256 : (256#i32).val = 256 := by norm_num
  have h31 : (31#i32).val = 31 := by norm_num
  have hmul : (Pion.I32.mul 120#i32 256#i32).val = 120 * 256 := by
    rw [i32_mul_val 120#i32 256#i32 (by rw [h120, h256]; omega) (by rw [h120, h256]; omega), h120, h256]
  have hsum : (Pion.I32.add (Pion.I32.mul 120#i32 256#i32) flg).val = 120 * 256 + flg.val := by
    rw [i32_add_val _ flg (by rw [hmul]; omega) (by rw [hmul]; omega), hmul]
  obtain ⟨r, hr_eq, hr_val⟩ := i32_rem_nonneg_val (Pion.I32.add (Pion.I32.mul 120#i32 256#i32) flg) 31#i32
    (by rw [hsum]; omega) (by omega)
  rw [hr_eq, result_bind_ok]
  have h0 : (0#i32).val = 0 := by norm_num
  have hr0 : r = 0#i32 := (iscalar_eq_iff r 0#i32).mpr (by rw [hr_val, hsum, h31, h0]; omega)
  simp only [hr0, ne_eq, not_true_eq_false, ↓reduceIte]
  rw [i32_shr_const 120#i32 4#i32 (by norm_num) (by norm_num), result_bind_ok]
  have hcm : Pion.I32.band 120#i32 15#i32 = 8#i32 := by decide
  have hcinfo : ¬(Pion.I32.band (⟨(120#i32).bv.sshiftRight (4#i32).val.toNat⟩ : Std.I32) 15#i32 > 7#i32) := by decide
  simp only [hcm, hcinfo, not_true_eq_false, ↓reduceIte]

end FlateProofs
