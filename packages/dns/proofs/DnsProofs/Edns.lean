import DnsProofs.Core

open Aeneas Aeneas.Std Result Pion dns

namespace DnsProofs

private lemma i64_shl_24 (x : Std.I64) :
    Pion.I64.shl_i32 x 24#i32 = ok (⟨x.bv <<< 24⟩ : Std.I64) := by
  unfold Pion.I64.shl_i32
  have hc : 0 ≤ (24#i32).val ∧ (24#i32).val < 64 := by norm_num
  have h24 : (24#i32).val.toNat = 24 := by norm_num
  simp only [hc, and_self, ↓reduceIte, h24]

private lemma i64_shl_16 (x : Std.I64) :
    Pion.I64.shl_i32 x 16#i32 = ok (⟨x.bv <<< 16⟩ : Std.I64) := by
  unfold Pion.I64.shl_i32
  have hc : 0 ≤ (16#i32).val ∧ (16#i32).val < 64 := by norm_num
  have h16 : (16#i32).val.toNat = 16 := by norm_num
  simp only [hc, and_self, ↓reduceIte, h16]

private lemma i64_shr_24 (x : Std.I64) :
    Pion.I64.shr_i32 x 24#i32 = ok (⟨x.bv.sshiftRight 24⟩ : Std.I64) := by
  unfold Pion.I64.shr_i32
  have hc : 0 ≤ (24#i32).val ∧ (24#i32).val < 64 := by norm_num
  have h24 : (24#i32).val.toNat = 24 := by norm_num
  simp only [hc, and_self, ↓reduceIte, h24]

private lemma i64_shr_16 (x : Std.I64) :
    Pion.I64.shr_i32 x 16#i32 = ok (⟨x.bv.sshiftRight 16⟩ : Std.I64) := by
  unfold Pion.I64.shr_i32
  have hc : 0 ≤ (16#i32).val ∧ (16#i32).val < 64 := by norm_num
  have h16 : (16#i32).val.toNat = 16 := by norm_num
  simp only [hc, and_self, ↓reduceIte, h16]

private lemma i32_shl_4 (x : Std.I32) :
    Pion.I32.shl x 4#i32 = ok (⟨x.bv <<< 4⟩ : Std.I32) := by
  unfold Pion.I32.shl
  have hc : 0 ≤ (4#i32).val ∧ (4#i32).val < 32 := by norm_num
  have h4 : (4#i32).val.toNat = 4 := by norm_num
  simp only [hc, and_self, ↓reduceIte, h4]

private lemma i32_band_255_to_i64_toNat (x : Std.I32) :
    (Pion.I32.to_int64 (Pion.I32.band x 255#i32)).bv.toNat = (Pion.I32.band x 255#i32).bv.toNat ∧
    (Pion.I32.band x 255#i32).bv.toNat < 256 := by
  have ⟨hb1, hb2⟩ := i32_band_255_bounds x
  have hnat : (Pion.I32.band x 255#i32).bv.toNat < 256 := by
    have hti := BitVec.toInt_eq_toNat_cond (Pion.I32.band x 255#i32).bv
    have hlt : 2 * (Pion.I32.band x 255#i32).bv.toNat < 2 ^ 32 := by
      by_contra hge; push Not at hge
      rw [ite_eq_right (by omega)] at hti
      change (Pion.I32.band x 255#i32).bv.toInt ≥ 0 at hb1
      omega
    rw [ite_eq_left hlt] at hti
    change (Pion.I32.band x 255#i32).bv.toInt ≤ 255 at hb2
    omega
  refine ⟨?_, hnat⟩
  unfold Pion.I32.to_int64
  change (BitVec.ofInt 64 (Pion.I32.band x 255#i32).val).toNat = (Pion.I32.band x 255#i32).bv.toNat
  rw [BitVec.toNat_ofInt]
  have hval : (Pion.I32.band x 255#i32).val = ((Pion.I32.band x 255#i32).bv.toNat : Int) := by
    change (Pion.I32.band x 255#i32).bv.toInt = _
    rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
  rw [hval]
  omega

private lemma i32_toNat_of_range (x : Std.I32) (h0 : 0 ≤ x.val) (hlt : x.val < 256) :
    x.bv.toNat = x.val.toNat ∧ (Pion.I32.band x 255#i32).bv.toNat = x.val.toNat := by
  have hnat : x.bv.toNat = x.val.toNat := by
    have hti := BitVec.toInt_eq_toNat_cond x.bv
    have hlt2 : 2 * x.bv.toNat < 2 ^ 32 := by
      by_contra hge; push Not at hge
      rw [ite_eq_right (by omega)] at hti
      change x.bv.toInt ≥ 0 at h0
      omega
    rw [ite_eq_left hlt2] at hti
    change x.bv.toNat = x.bv.toInt.toNat
    omega
  refine ⟨hnat, ?_⟩
  rw [i32_band_bv, BitVec.toNat_and]
  have h255 : (255#i32).bv.toNat = 255 := by decide
  rw [h255]
  have hmod : x.bv.toNat &&& 255 = x.bv.toNat % 256 := by
    have : (255 : Nat) = 2 ^ 8 - 1 := by norm_num
    rw [this, Nat.and_two_pow_sub_one_eq_mod]
  rw [hmod, Nat.mod_eq_of_lt (by omega), hnat]

private lemma i64_eq_of_bv (a b : Std.I64) (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

private lemma i64_bit_zero_above_8 (x : Std.I64) (hlt : x.bv.toNat < 256) (i : Nat) (hi : i < 64) (h8 : 8 ≤ i) :
    x.bv[i] = false := by
  rw [BitVec.getElem_eq_testBit_toNat]
  exact Nat.testBit_lt_two_pow (by
    have : (2 : Nat) ^ 8 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) h8
    omega)

private lemma db_bit_zero_above_16 (do_bit : Bool) (i : Nat) (hi : i < 64) (h16 : 16 ≤ i) :
    (if do_bit then 32768#i64 else 0#i64).bv[i] = false := by
  cases do_bit
  · simp
  · simp only [↓reduceIte]
    rw [BitVec.getElem_eq_testBit_toNat]
    have h32768 : (32768#i64).bv.toNat = 32768 := by decide
    rw [h32768]
    exact Nat.testBit_lt_two_pow (by
      have : (32768 : Nat) < 2 ^ 16 := by norm_num
      have : (2 : Nat) ^ 16 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) h16
      omega)

/-- RFC 6891: `edns_pack_ttl` always produces a valid unsigned 32-bit TTL (`is_u32 = true`). -/
theorem edns_pack_ttl_is_u32 (ext ver : Std.I32) (do_bit : Bool) :
    ∃ t : Std.I64, edns_pack_ttl ext ver do_bit = ok t ∧ is_u32 t = ok true := by
  unfold edns_pack_ttl
  rw [i64_shl_24, result_bind_ok, i64_shl_16, result_bind_ok]
  refine ⟨_, rfl, ?_⟩
  have ⟨he_eq, he_lt⟩ := i32_band_255_to_i64_toNat ext
  have ⟨hv_eq, hv_lt⟩ := i32_band_255_to_i64_toNat ver
  set e64 := Pion.I32.to_int64 (Pion.I32.band ext 255#i32)
  set v64 := Pion.I32.to_int64 (Pion.I32.band ver 255#i32)
  set db : Std.I64 := if do_bit then 32768#i64 else 0#i64
  set t : Std.I64 := Pion.I64.bor (Pion.I64.bor ⟨e64.bv <<< 24⟩ ⟨v64.bv <<< 16⟩) db
  have he_shl : (e64.bv <<< 24).toNat < 2 ^ 32 := by
    rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq, Nat.mod_eq_of_lt (by omega)]; omega
  have hv_shl : (v64.bv <<< 16).toNat < 2 ^ 32 := by
    rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq, Nat.mod_eq_of_lt (by omega)]; omega
  have hdb_lt : db.bv.toNat < 2 ^ 32 := by cases do_bit <;> decide
  have h_or : ∀ (x y : BitVec IScalarTy.I64.numBits), x.toNat < 2 ^ 32 → y.toNat < 2 ^ 32 → (x ||| y).toNat < 2 ^ 32 := by
    intro x y hx hy; rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow (n := 32) hx hy
  have ht_lt : t.bv.toNat < 2 ^ 32 := h_or _ _ (h_or _ _ he_shl hv_shl) hdb_lt
  have hval : t.val = (t.bv.toNat : Int) := by
    change t.bv.toInt = _; rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
  exact (is_u32_iff t).mpr ⟨by omega, by omega⟩

/-- RFC 6891: `edns_ttl_ext_rcode` recovers `ext` (`0 ≤ ext < 256`) from `edns_pack_ttl`. -/
theorem edns_pack_ttl_ext_rcode (ext ver : Std.I32) (do_bit : Bool)
    (h0 : 0 ≤ ext.val) (h256 : ext.val < 256) :
    (do let t ← edns_pack_ttl ext ver do_bit; edns_ttl_ext_rcode t) = ok ext := by
  unfold edns_pack_ttl edns_ttl_ext_rcode
  rw [i64_shl_24, result_bind_ok, i64_shl_16, result_bind_ok, result_bind_ok, i64_shr_24, result_bind_ok]
  congr 1
  have ⟨he_eq, he_lt⟩ := i32_band_255_to_i64_toNat ext
  have ⟨hv_eq, hv_lt⟩ := i32_band_255_to_i64_toNat ver
  have ⟨_, he_val⟩ := i32_toNat_of_range ext h0 h256
  set e64 := Pion.I32.to_int64 (Pion.I32.band ext 255#i32)
  set v64 := Pion.I32.to_int64 (Pion.I32.band ver 255#i32)
  set db : Std.I64 := if do_bit then 32768#i64 else 0#i64
  set t : Std.I64 := Pion.I64.bor (Pion.I64.bor ⟨e64.bv <<< 24⟩ ⟨v64.bv <<< 16⟩) db
  have hband_eq : (Pion.I64.band ⟨t.bv.sshiftRight 24⟩ 255#i64).bv = e64.bv := by
    rw [i64_band_bv]
    ext i hi
    rw [BitVec.getElem_and]
    by_cases h8 : i < 8
    · have hlt : 24 + i < 64 := by omega
      have h255t : (255#i64).bv[i] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        rcases (by omega : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6 ∨ i = 7) with
          rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
      have hv0 : (v64.bv <<< 16)[24 + i] = false := by
        rw [BitVec.getElem_shiftLeft]
        have hge : ¬(24 + i < 16) := by omega
        simp only [hge, decide_false, Bool.not_false, Bool.true_and]
        exact i64_bit_zero_above_8 v64 (by omega) (24 + i - 16) (by omega) (by omega)
      have hdb0 : db.bv[24 + i] = false := db_bit_zero_above_16 do_bit (24 + i) hlt (by omega)
      change ((t.bv.sshiftRight 24)[i] && (255#i64).bv[i]) = e64.bv[i]
      rw [BitVec.getElem_sshiftRight, dite_eq_left hlt]
      change ((((e64.bv <<< 24) ||| (v64.bv <<< 16)) ||| db.bv)[24 + i] && (255#i64).bv[i]) = e64.bv[i]
      simp only [BitVec.getElem_or, hv0, hdb0, h255t, Bool.or_false, Bool.and_true]
      rw [BitVec.getElem_shiftLeft]
      have hge24 : ¬(24 + i < 24) := by omega
      have hsub : 24 + i - 24 = i := by omega
      simp only [hge24, decide_false, Bool.not_false, Bool.true_and, hsub]
    · have h255f : (255#i64).bv[i] = false := by
        have h255 : (255#i64).bv.toNat = 255 := by decide
        rw [BitVec.getElem_eq_testBit_toNat, h255]
        exact Nat.testBit_lt_two_pow (by
          have : (255 : Nat) < 2 ^ 8 := by norm_num
          have : (2 : Nat) ^ 8 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
          omega)
      have he0 : e64.bv[i] = false := i64_bit_zero_above_8 e64 (by omega) i hi (by omega)
      simp only [h255f, Bool.and_false, he0]
  apply (iscalar_eq_iff _ _).mpr
  unfold Pion.I64.to_int
  change (BitVec.ofInt 32 (Pion.I64.band ⟨t.bv.sshiftRight 24⟩ 255#i64).val).toInt = ext.val
  have h64val : (Pion.I64.band ⟨t.bv.sshiftRight 24⟩ 255#i64).val = ext.val := by
    change (Pion.I64.band ⟨t.bv.sshiftRight 24⟩ 255#i64).bv.toInt = ext.val
    rw [hband_eq, BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
    omega
  rw [h64val, BitVec.toInt_ofInt, Int.bmod_eq_of_le] <;> omega

/-- RFC 6891: `edns_ttl_version` recovers `ver` (`0 ≤ ver < 256`) from `edns_pack_ttl`. -/
theorem edns_pack_ttl_version (ext ver : Std.I32) (do_bit : Bool)
    (h0 : 0 ≤ ver.val) (h256 : ver.val < 256) :
    (do let t ← edns_pack_ttl ext ver do_bit; edns_ttl_version t) = ok ver := by
  unfold edns_pack_ttl edns_ttl_version
  rw [i64_shl_24, result_bind_ok, i64_shl_16, result_bind_ok, result_bind_ok, i64_shr_16, result_bind_ok]
  congr 1
  have ⟨he_eq, he_lt⟩ := i32_band_255_to_i64_toNat ext
  have ⟨hv_eq, hv_lt⟩ := i32_band_255_to_i64_toNat ver
  have ⟨_, hv_val⟩ := i32_toNat_of_range ver h0 h256
  set e64 := Pion.I32.to_int64 (Pion.I32.band ext 255#i32)
  set v64 := Pion.I32.to_int64 (Pion.I32.band ver 255#i32)
  set db : Std.I64 := if do_bit then 32768#i64 else 0#i64
  set t : Std.I64 := Pion.I64.bor (Pion.I64.bor ⟨e64.bv <<< 24⟩ ⟨v64.bv <<< 16⟩) db
  have hband_eq : (Pion.I64.band ⟨t.bv.sshiftRight 16⟩ 255#i64).bv = v64.bv := by
    rw [i64_band_bv]
    ext i hi
    rw [BitVec.getElem_and]
    by_cases h8 : i < 8
    · have hlt : 16 + i < 64 := by omega
      have h255t : (255#i64).bv[i] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        rcases (by omega : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6 ∨ i = 7) with
          rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
      have he0 : (e64.bv <<< 24)[16 + i] = false := by
        rw [BitVec.getElem_shiftLeft]
        have hlt24 : 16 + i < 24 := by omega
        simp only [hlt24, decide_true, Bool.not_true, Bool.false_and]
      have hdb0 : db.bv[16 + i] = false := db_bit_zero_above_16 do_bit (16 + i) hlt (by omega)
      change ((t.bv.sshiftRight 16)[i] && (255#i64).bv[i]) = v64.bv[i]
      rw [BitVec.getElem_sshiftRight, dite_eq_left hlt]
      change ((((e64.bv <<< 24) ||| (v64.bv <<< 16)) ||| db.bv)[16 + i] && (255#i64).bv[i]) = v64.bv[i]
      simp only [BitVec.getElem_or, he0, hdb0, h255t, Bool.false_or, Bool.or_false, Bool.and_true]
      rw [BitVec.getElem_shiftLeft]
      have hge16 : ¬(16 + i < 16) := by omega
      have hsub : 16 + i - 16 = i := by omega
      simp only [hge16, decide_false, Bool.not_false, Bool.true_and, hsub]
    · have h255f : (255#i64).bv[i] = false := by
        have h255 : (255#i64).bv.toNat = 255 := by decide
        rw [BitVec.getElem_eq_testBit_toNat, h255]
        exact Nat.testBit_lt_two_pow (by
          have : (255 : Nat) < 2 ^ 8 := by norm_num
          have : (2 : Nat) ^ 8 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
          omega)
      have hv0 : v64.bv[i] = false := i64_bit_zero_above_8 v64 (by omega) i hi (by omega)
      simp only [h255f, Bool.and_false, hv0]
  apply (iscalar_eq_iff _ _).mpr
  unfold Pion.I64.to_int
  change (BitVec.ofInt 32 (Pion.I64.band ⟨t.bv.sshiftRight 16⟩ 255#i64).val).toInt = ver.val
  have h64val : (Pion.I64.band ⟨t.bv.sshiftRight 16⟩ 255#i64).val = ver.val := by
    change (Pion.I64.band ⟨t.bv.sshiftRight 16⟩ 255#i64).bv.toInt = ver.val
    rw [hband_eq, BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
    omega
  rw [h64val, BitVec.toInt_ofInt, Int.bmod_eq_of_le] <;> omega

/-- RFC 6891: `edns_ttl_dnssec_ok` recovers `do_bit` from `edns_pack_ttl`. -/
theorem edns_pack_ttl_dnssec_ok (ext ver : Std.I32) (do_bit : Bool) :
    (do let t ← edns_pack_ttl ext ver do_bit; edns_ttl_dnssec_ok t) = ok do_bit := by
  unfold edns_pack_ttl edns_ttl_dnssec_ok
  rw [i64_shl_24, result_bind_ok, i64_shl_16, result_bind_ok, result_bind_ok]
  congr 1
  set e64 := Pion.I32.to_int64 (Pion.I32.band ext 255#i32)
  set v64 := Pion.I32.to_int64 (Pion.I32.band ver 255#i32)
  set db : Std.I64 := if do_bit then 32768#i64 else 0#i64
  set t : Std.I64 := Pion.I64.bor (Pion.I64.bor ⟨e64.bv <<< 24⟩ ⟨v64.bv <<< 16⟩) db
  have heq : Pion.I64.band t 32768#i64 = db := by
    apply i64_eq_of_bv
    rw [i64_band_bv]
    ext i hi
    rw [BitVec.getElem_and]
    change ((((e64.bv <<< 24) ||| (v64.bv <<< 16)) ||| db.bv)[i] && (32768#i64).bv[i]) = db.bv[i]
    by_cases h15 : i = 15
    · subst h15
      have he0 : (e64.bv <<< 24)[15] = false := by
        rw [BitVec.getElem_shiftLeft]; simp only [show (15 : Nat) < 24 by omega, decide_true, Bool.not_true, Bool.false_and]
      have hv0 : (v64.bv <<< 16)[15] = false := by
        rw [BitVec.getElem_shiftLeft]; simp only [show (15 : Nat) < 16 by omega, decide_true, Bool.not_true, Bool.false_and]
      have h32768t : (32768#i64).bv[15] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]; decide
      simp only [BitVec.getElem_or, he0, hv0, h32768t, Bool.false_or, Bool.and_true]
    · have hm : (32768#i64).bv[i] = false := by
        have h32768 : (32768#i64).bv.toNat = 32768 := by decide
        rw [BitVec.getElem_eq_testBit_toNat, h32768, Nat.testBit_eq_decide_div_mod_eq]
        by_cases hlt : i < 15
        · have : 32768 / 2 ^ i = 2 ^ (15 - i) := by
            have : (32768 : Nat) = 2 ^ 15 := by norm_num
            rw [this, Nat.pow_div (by omega) (by omega)]
          rw [this]
          obtain ⟨k, hk⟩ : ∃ k, 15 - i = k + 1 := ⟨14 - i, by omega⟩
          rw [hk, Nat.pow_succ]
          have : (2 ^ k * 2) % 2 = 0 := by omega
          simp [this]
        · have hgt : 16 ≤ i := by omega
          have : (32768 : Nat) < 2 ^ i := by
            have : (32768 : Nat) < 2 ^ 16 := by norm_num
            have : (2 : Nat) ^ 16 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) hgt
            omega
          rw [Nat.div_eq_of_lt this]; decide
      have hdb0 : db.bv[i] = false := by
        cases do_bit
        · simp [db]
        · simp only [db, ↓reduceIte]; exact hm
      simp only [hm, Bool.and_false, hdb0]
  rw [heq]; cases do_bit <;> decide

/-- RFC 6891: `combine_extended_rcode` produces exact 12-bit value `ext * 16 + hdr` in `[0, 4095]`. -/
theorem combine_extended_rcode_spec (ext hdr : Std.I32)
    (he0 : 0 ≤ ext.val) (he256 : ext.val < 256)
    (hh0 : 0 ≤ hdr.val) (hh16 : hdr.val < 16) :
    ∃ r : Std.I32, combine_extended_rcode ext hdr = ok r ∧
      r.val = ext.val * 16 + hdr.val ∧ 0 ≤ r.val ∧ r.val < 4096 := by
  unfold combine_extended_rcode
  rw [i32_shl_4, result_bind_ok]
  refine ⟨_, rfl, ?_⟩
  have ⟨_, he_nat⟩ := i32_toNat_of_range ext he0 he256
  have hh_nat : (Pion.I32.band hdr 15#i32).bv.toNat = hdr.val.toNat := by
    have ⟨hn, _⟩ := i32_toNat_of_range hdr hh0 (by omega)
    rw [i32_band_bv, BitVec.toNat_and]
    have h15 : (15#i32).bv.toNat = 15 := by decide
    rw [h15]
    have hmod : hdr.bv.toNat &&& 15 = hdr.bv.toNat % 16 := by
      have : (15 : Nat) = 2 ^ 4 - 1 := by norm_num
      rw [this, Nat.and_two_pow_sub_one_eq_mod]
    rw [hmod, Nat.mod_eq_of_lt (by omega), hn]
  have hdisj : ((Pion.I32.band ext 255#i32).bv <<< 4) &&& (Pion.I32.band hdr 15#i32).bv = 0#32 := by
    ext i hi
    rw [BitVec.getElem_and, BitVec.getElem_shiftLeft, BitVec.getElem_zero]
    by_cases h4 : i < 4
    · simp only [h4, decide_true, Bool.not_true, Bool.false_and]
    · have hh0b : (Pion.I32.band hdr 15#i32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat, hh_nat]
        exact Nat.testBit_lt_two_pow (by
          have : (2 : Nat) ^ 4 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
          omega)
      simp only [hh0b, Bool.and_false]
  have hshl : ((Pion.I32.band ext 255#i32).bv <<< 4).toNat = ext.val.toNat * 16 := by
    rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq, he_nat, Nat.mod_eq_of_lt (by omega)]
  have hor_nat : (Pion.I32.bor ⟨(Pion.I32.band ext 255#i32).bv <<< 4⟩ (Pion.I32.band hdr 15#i32)).bv.toNat =
      ext.val.toNat * 16 + hdr.val.toNat := by
    rw [i32_bor_bv, ← BitVec.add_eq_or_of_and_eq_zero _ _ hdisj, BitVec.toNat_add, hshl, hh_nat,
      Nat.mod_eq_of_lt (by omega)]
  have hval : (Pion.I32.bor ⟨(Pion.I32.band ext 255#i32).bv <<< 4⟩ (Pion.I32.band hdr 15#i32)).val =
      ((Pion.I32.bor ⟨(Pion.I32.band ext 255#i32).bv <<< 4⟩ (Pion.I32.band hdr 15#i32)).bv.toNat : Int) := by
    change (Pion.I32.bor ⟨(Pion.I32.band ext 255#i32).bv <<< 4⟩ (Pion.I32.band hdr 15#i32)).bv.toInt = _
    rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
  omega

end DnsProofs
