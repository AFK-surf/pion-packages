import DecimalProofs.Arith96

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace DecimalProofs

open decimal

/-! ## 2. `Decimal` Flags, Sign, Scale (`0..=28`) & `neg`/`abs`/`is_zero` Invariants -/

theorem make_flags_spec (neg : Bool) (scale : Std.U32) (hs : scale.val ≤ 28) :
    ∃ f : Std.U32, make_flags neg scale = ok f ∧
      valid_flags f ∧
      ((f.bv &&& MASK_SCALE) >>> 16).toNat = scale.val ∧
      ((f.bv &&& MASK_SIGN) != ZERO_BV32) = neg := by
  unfold make_flags
  obtain ⟨s, hshl, hsbv⟩ := u32_shl16_ok (Pion.U32.band scale 255#u32)
  rw [hshl, b_ok]
  have hs_nat : scale.bv.toNat ≤ 28 := hs
  have hband : (Pion.U32.band scale 255#u32).bv = scale.bv := by
    simp only [Pion.U32.band]
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_and]
    have h255 : (255#u32 : Std.U32).bv.toNat = 2 ^ 8 - 1 := by decide
    rw [h255, Nat.and_two_pow_sub_one_eq_mod]
    omega
  have hsbv' : s.bv = scale.bv <<< 16 := by
    rw [hsbv, hband]
  have hs_toNat : s.bv.toNat = scale.bv.toNat * 2 ^ 16 := by
    rw [hsbv', BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
    have : scale.bv.toNat * 2 ^ 16 < 2 ^ 32 := by omega
    exact Nat.mod_eq_of_lt this
  have hres_s : (s.bv &&& MASK_RES) = ZERO_BV32 := by
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_and]
    have hm_val : MASK_RES.toNat = 0x7FE0FFFF := by decide
    have hz_val : ZERO_BV32.toNat = 0 := by decide
    rw [hm_val, hz_val]
    apply Nat.eq_of_testBit_eq
    intro i
    rw [Nat.testBit_and, Nat.zero_testBit]
    by_cases hi : 16 ≤ i ∧ i < 21
    · have hmask : (0x7FE0FFFF : Nat).testBit i = false := by
        rcases hi with ⟨h1, h2⟩
        have : i = 16 ∨ i = 17 ∨ i = 18 ∨ i = 19 ∨ i = 20 := by omega
        rcases this with rfl | rfl | rfl | rfl | rfl <;> decide
      rw [hmask, Bool.and_false]
    · have hsbit : s.bv.toNat.testBit i = false := by
        rw [hs_toNat, ← Nat.shiftLeft_eq, Nat.testBit_shiftLeft]
        by_cases h16 : 16 ≤ i
        · have hi5 : 5 ≤ i - 16 := by omega
          have htb : scale.bv.toNat.testBit (i - 16) = false := by
            apply Nat.testBit_lt_two_pow
            have : 2 ^ 5 ≤ 2 ^ (i - 16) := Nat.pow_le_pow_right (by omega) hi5
            omega
          simp only [h16, decide_true, Bool.true_and]
          exact htb
        · simp [h16]
      rw [hsbit, Bool.false_and]
  have hscale_s : ((s.bv &&& MASK_SCALE) >>> 16).toNat = scale.val := by
    rw [BitVec.toNat_ushiftRight, BitVec.toNat_and, Nat.shiftRight_eq_div_pow]
    have hm_val : MASK_SCALE.toNat = 0x00FF0000 := by decide
    rw [hm_val]
    have heq : s.bv.toNat &&& 0x00FF0000 = s.bv.toNat := by
      apply Nat.eq_of_testBit_eq
      intro i
      rw [Nat.testBit_and]
      by_cases hi : 16 ≤ i ∧ i < 21
      · have hm : (0x00FF0000 : Nat).testBit i = true := by
          have : i = 16 ∨ i = 17 ∨ i = 18 ∨ i = 19 ∨ i = 20 := by omega
          rcases this with rfl | rfl | rfl | rfl | rfl <;> decide
        rw [hm, Bool.and_true]
      · have hsbit : s.bv.toNat.testBit i = false := by
          rw [hs_toNat, ← Nat.shiftLeft_eq, Nat.testBit_shiftLeft]
          by_cases h16 : 16 ≤ i
          · have hi5 : 5 ≤ i - 16 := by omega
            have htb : scale.bv.toNat.testBit (i - 16) = false := by
              apply Nat.testBit_lt_two_pow
              have : 2 ^ 5 ≤ 2 ^ (i - 16) := Nat.pow_le_pow_right (by omega) hi5
              omega
            simp only [h16, decide_true, Bool.true_and]
            exact htb
          · simp [h16]
        rw [hsbit, Bool.false_and]
    rw [heq, hs_toNat]
    have hsc_eq : scale.val = scale.bv.toNat := rfl
    omega
  have hsign_s : (s.bv &&& MASK_SIGN) = ZERO_BV32 := by
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_and]
    have hm_val : MASK_SIGN.toNat = 2 ^ 31 := by decide
    have hz_val : ZERO_BV32.toNat = 0 := by decide
    rw [hm_val, hz_val]
    apply Nat.eq_of_testBit_eq
    intro i
    rw [Nat.testBit_and, Nat.zero_testBit, Nat.testBit_two_pow]
    by_cases h31 : 31 = i
    · subst h31
      have htb : s.bv.toNat.testBit 31 = false := by
        apply Nat.testBit_lt_two_pow; omega
      simp only [decide_true, Bool.and_true]
      exact htb
    · simp [h31]
  cases neg with
  | false =>
    refine ⟨s, rfl, ⟨hres_s, by omega⟩, hscale_s, ?_⟩
    simp [hsign_s]
  | true =>
    refine ⟨Pion.U32.bor s SIGN_MASK, rfl, ?_, ?_, ?_⟩
    · constructor
      · dsimp only [Pion.U32.bor, SIGN_MASK]
        rw [BitVec.and_or_distrib_right, hres_s]
        decide
      · dsimp only [Pion.U32.bor, SIGN_MASK]
        rw [BitVec.and_or_distrib_right]
        have hsm : (MASK_SIGN &&& MASK_SCALE) = ZERO_BV32 := by decide
        change (((s.bv &&& MASK_SCALE) ||| (MASK_SIGN &&& MASK_SCALE)) >>> 16).toNat ≤ 28
        rw [hsm]
        change ((s.bv &&& MASK_SCALE ||| 0#32) >>> 16).toNat ≤ 28
        rw [BitVec.or_zero]; omega
    · dsimp only [Pion.U32.bor, SIGN_MASK]
      rw [BitVec.and_or_distrib_right]
      have hsm : (MASK_SIGN &&& MASK_SCALE) = ZERO_BV32 := by decide
      change (((s.bv &&& MASK_SCALE) ||| (MASK_SIGN &&& MASK_SCALE)) >>> 16).toNat = scale.val
      rw [hsm]
      change ((s.bv &&& MASK_SCALE ||| 0#32) >>> 16).toNat = scale.val
      rw [BitVec.or_zero, hscale_s]
    · dsimp only [Pion.U32.bor, SIGN_MASK]
      rw [BitVec.and_or_distrib_right, hsign_s]
      decide

theorem Decimal.scale_spec (d : Decimal) :
    ∃ s : Std.U32, Decimal.scale d = ok s ∧ s.val = dec_scale d := by
  unfold Decimal.scale dec_scale
  obtain ⟨t, ht, htbv⟩ := u32_shr16_ok (Pion.U32.band d.flags SCALE_MASK)
  rw [ht, b_ok]
  refine ⟨t, rfl, ?_⟩
  simp only [UScalar.val, htbv, Pion.U32.band, SCALE_MASK]
  rfl

theorem Decimal.scale_le_28 (d : Decimal) (hd : valid_decimal d) :
    ∃ s : Std.U32, Decimal.scale d = ok s ∧ s.val ≤ 28 := by
  obtain ⟨s, hs, hsv⟩ := Decimal.scale_spec d
  exact ⟨s, hs, by rw [hsv]; exact hd.2⟩

theorem Decimal.is_sign_negative_spec (d : Decimal) :
    Decimal.is_sign_negative d = ok (dec_neg d) := by
  unfold Decimal.is_sign_negative dec_neg SIGN_MASK
  simp only [Pion.U32.band, bne, BEq.beq]
  rfl

theorem Decimal.is_sign_positive_spec (d : Decimal) :
    Decimal.is_sign_positive d = ok (!(dec_neg d)) := by
  unfold Decimal.is_sign_positive dec_neg SIGN_MASK
  simp only [Pion.U32.band, bne, BEq.beq, Bool.not_not]
  rfl

theorem Decimal.is_zero_spec (d : Decimal) :
    Decimal.is_zero d = ok (decide (dec_mag d = 0)) := by
  unfold Decimal.is_zero dec_mag val96
  have hlo := u64_val_lt d.lo64
  have hhi := u32_val_lt d.hi
  by_cases h1 : d.lo64 = 0#u64
  · by_cases h2 : d.hi = 0#u32
    · rw [h1, h2]
      have : (0#u64 : Std.U64).val + 2 ^ 64 * (0#u32 : Std.U32).val = 0 := by decide
      simp [this]
    · have hne : d.hi.val ≠ 0 := fun hz => h2 (UScalar.eq_of_val_eq hz)
      have hb1 : (d.lo64 == 0#u64) = true := by rw [h1]; decide
      have hb2 : (d.hi == 0#u32) = false := beq_false_of_ne h2
      have hm : d.lo64.val + 2 ^ 64 * d.hi.val ≠ 0 := by omega
      rw [hb1, hb2, Bool.true_and, decide_eq_false hm]
  · have hne : d.lo64.val ≠ 0 := fun hz => h1 (UScalar.eq_of_val_eq hz)
    have hb1 : (d.lo64 == 0#u64) = false := beq_false_of_ne h1
    have hm : d.lo64.val + 2 ^ 64 * d.hi.val ≠ 0 := by omega
    rw [hb1, Bool.false_and, decide_eq_false hm]

/-- `Decimal::from_parts` succeeds for `scale ≤ 28`, producing a valid `Decimal` with exact
    mantissa, scale, and sign. -/
theorem Decimal.from_parts_ok_spec (lo mid hi : Std.U32) (neg : Bool) (scale : Std.U32)
    (hs : scale.val ≤ 28) :
    ∃ d : Decimal, Decimal.from_parts lo mid hi neg scale = ok (Res.Ok d) ∧
      valid_decimal d ∧
      dec_mag d = val96_parts lo mid hi ∧
      dec_scale d = scale.val ∧
      dec_neg d = neg := by
  unfold Decimal.from_parts
  have hnotgt : ¬(scale > MAX_SCALE) := by
    intro h; have : (28#u32 : Std.U32).val < scale.val := h
    have hv : (28#u32 : Std.U32).val = 28 := by decide
    omega
  simp only [hnotgt, ↓reduceIte]
  obtain ⟨t, ht, htv⟩ := u64_shl32_ok (Pion.U32.to_uint64 mid)
  obtain ⟨f, hf, hfv, hfs, hfn⟩ := make_flags_spec neg scale hs
  rw [ht, b_ok, hf, b_ok]
  refine ⟨_, rfl, hfv, ?_, hfs, hfn⟩
  unfold dec_mag val96 val96_parts
  have hlo_lt : (Pion.U32.to_uint64 lo).val < 2 ^ 32 := by
    rw [u32_to_uint64_val]; exact u32_val_lt lo
  have ht_mod : t.val % 2 ^ 32 = 0 := by rw [htv]; exact Nat.mul_mod_left _ _
  rw [u64_bor_disjoint_32 hlo_lt ht_mod, u32_to_uint64_val, htv, u32_to_uint64_val,
    Nat.mod_eq_of_lt (u32_val_lt mid)]
  ring

/-- `Decimal::from_parts` strictly rejects `scale > 28` with `Err(ScaleExceedsMaximumPrecision)`. -/
theorem Decimal.from_parts_err_spec (lo mid hi : Std.U32) (neg : Bool) (scale : Std.U32)
    (hs : scale.val > 28) :
    Decimal.from_parts lo mid hi neg scale =
      ok (Res.Err (DecimalError.ScaleExceedsMaximumPrecision scale)) := by
  unfold Decimal.from_parts
  have hgt : scale > MAX_SCALE := by
    show (28#u32 : Std.U32).val < scale.val
    have hv : (28#u32 : Std.U32).val = 28 := by decide
    omega
  simp [hgt]

/-- `Decimal::set_scale` preserves validity for `scale ≤ 28` and rejects `scale > 28`. -/
theorem Decimal.set_scale_spec (d : Decimal) (scale : Std.U32) :
    (scale.val ≤ 28 → ∃ d', Decimal.set_scale d scale = ok (Res.Ok d') ∧
      valid_decimal d' ∧ dec_mag d' = dec_mag d ∧ dec_scale d' = scale.val ∧ dec_neg d' = dec_neg d) ∧
    (scale.val > 28 → Decimal.set_scale d scale =
      ok (Res.Err (DecimalError.ScaleExceedsMaximumPrecision scale))) := by
  constructor
  · intro hs
    unfold Decimal.set_scale make_decimal
    have hnotgt : ¬(scale > MAX_SCALE) := by
      intro h; have : (28#u32 : Std.U32).val < scale.val := h
      have hv : (28#u32 : Std.U32).val = 28 := by decide
      omega
    simp only [hnotgt, ↓reduceIte, Decimal.is_sign_negative_spec, b_ok]
    obtain ⟨f, hf, hfv, hfs, hfn⟩ := make_flags_spec (dec_neg d) scale hs
    rw [hf, b_ok, b_ok]
    exact ⟨Decimal.mk d.lo64 d.hi f, rfl, hfv, rfl, hfs, hfn⟩
  · intro hs
    unfold Decimal.set_scale
    have hgt : scale > MAX_SCALE := by
      show (28#u32 : Std.U32).val < scale.val
      have hv : (28#u32 : Std.U32).val = 28 := by decide
      omega
    simp [hgt]

/-- `Decimal::neg` never traps, preserves `valid_decimal`, preserves mantissa and scale,
    flips the sign bit, and is strictly involutive (`neg (neg d) = d`). -/
theorem Decimal.neg_spec (d : Decimal) :
    ∃ d' : Decimal, Decimal.neg d = ok d' ∧
      d'.lo64 = d.lo64 ∧ d'.hi = d.hi ∧
      d'.flags = Pion.U32.bxor d.flags SIGN_MASK ∧
      (valid_decimal d → valid_decimal d') ∧
      dec_scale d' = dec_scale d ∧
      dec_neg d' = !(dec_neg d) := by
  have hbody : Decimal.neg d = ok (Decimal.mk d.lo64 d.hi (Pion.U32.bxor d.flags SIGN_MASK)) := by
    unfold Decimal.neg
    by_cases hz : ((d.lo64 == 0#u64) && (d.hi == 0#u32)) = true
    · simp only [hz, ↓reduceIte]
      simp only [Bool.and_eq_true, beq_iff_eq] at hz
      rw [hz.1, hz.2]
    · simp [hz]
  rw [hbody]
  refine ⟨_, rfl, rfl, rfl, rfl, ?_, ?_, ?_⟩
  · intro ⟨hres, hsc⟩
    constructor
    · dsimp only [Pion.U32.bxor, SIGN_MASK]
      rw [bv_and_xor_distrib_right, hres]
      decide
    · dsimp only [Pion.U32.bxor, SIGN_MASK]
      rw [bv_and_xor_distrib_right]
      have hsm : (MASK_SIGN &&& MASK_SCALE) = ZERO_BV32 := by decide
      change (((d.flags.bv &&& MASK_SCALE) ^^^ (MASK_SIGN &&& MASK_SCALE)) >>> 16).toNat ≤ 28
      rw [hsm]
      change ((d.flags.bv &&& MASK_SCALE ^^^ 0#32) >>> 16).toNat ≤ 28
      rw [BitVec.xor_zero]; exact hsc
  · unfold dec_scale
    dsimp only [Pion.U32.bxor, SIGN_MASK]
    rw [bv_and_xor_distrib_right]
    have hsm : (MASK_SIGN &&& MASK_SCALE) = ZERO_BV32 := by decide
    change (((d.flags.bv &&& MASK_SCALE) ^^^ (MASK_SIGN &&& MASK_SCALE)) >>> 16).toNat = _
    rw [hsm]
    change ((d.flags.bv &&& MASK_SCALE ^^^ 0#32) >>> 16).toNat = _
    rw [BitVec.xor_zero]
  · unfold dec_neg
    dsimp only [Pion.U32.bxor, SIGN_MASK]
    rw [bv_and_xor_distrib_right]
    have hsm : (MASK_SIGN &&& MASK_SIGN) = MASK_SIGN := by decide
    change (((d.flags.bv &&& MASK_SIGN) ^^^ (MASK_SIGN &&& MASK_SIGN)) != ZERO_BV32) = _
    rw [hsm]
    have hbit : d.flags.bv &&& MASK_SIGN = ZERO_BV32 ∨
        d.flags.bv &&& MASK_SIGN = MASK_SIGN := by
      by_cases h : d.flags.bv.getLsbD 31 = true
      · right
        apply BitVec.eq_of_getLsbD_eq
        intro i hi
        simp only [BitVec.getLsbD_and]
        by_cases h31 : i = 31
        · subst h31; simp [h]
        · have : MASK_SIGN.getLsbD i = false := by
            have : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6 ∨ i = 7 ∨
                   i = 8 ∨ i = 9 ∨ i = 10 ∨ i = 11 ∨ i = 12 ∨ i = 13 ∨ i = 14 ∨ i = 15 ∨
                   i = 16 ∨ i = 17 ∨ i = 18 ∨ i = 19 ∨ i = 20 ∨ i = 21 ∨ i = 22 ∨ i = 23 ∨
                   i = 24 ∨ i = 25 ∨ i = 26 ∨ i = 27 ∨ i = 28 ∨ i = 29 ∨ i = 30 := by omega
            rcases this with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
                             rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
                             rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
                             rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
          simp [this]
      · left
        apply BitVec.eq_of_getLsbD_eq
        intro i hi
        simp only [BitVec.getLsbD_and]
        have hz : ZERO_BV32.getLsbD i = false := by simp [ZERO_BV32]
        rw [hz]
        by_cases h31 : i = 31
        · subst h31
          have hf : d.flags.bv.getLsbD 31 = false := by
            cases hb : d.flags.bv.getLsbD 31 <;> simp_all
          rw [BitVec.getLsbD_eq_getElem hi] at hf
          simp [hf]
        · have : MASK_SIGN.getLsbD i = false := by
            have : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6 ∨ i = 7 ∨
                   i = 8 ∨ i = 9 ∨ i = 10 ∨ i = 11 ∨ i = 12 ∨ i = 13 ∨ i = 14 ∨ i = 15 ∨
                   i = 16 ∨ i = 17 ∨ i = 18 ∨ i = 19 ∨ i = 20 ∨ i = 21 ∨ i = 22 ∨ i = 23 ∨
                   i = 24 ∨ i = 25 ∨ i = 26 ∨ i = 27 ∨ i = 28 ∨ i = 29 ∨ i = 30 := by omega
            rcases this with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
                             rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
                             rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
                             rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
          simp [this]
    rcases hbit with h0 | h1
    · rw [h0]; decide
    · rw [h1]; decide

theorem Decimal.neg_involutive (d : Decimal) :
    (do let d1 ← Decimal.neg d; Decimal.neg d1) = ok d := by
  obtain ⟨d1, hd1, hlo1, hhi1, hf1, _, _, _⟩ := Decimal.neg_spec d
  obtain ⟨d2, hd2, hlo2, hhi2, hf2, _, _, _⟩ := Decimal.neg_spec d1
  rw [hd1, b_ok, hd2]
  congr 1
  cases d with
  | mk lo hi flags =>
    cases d2 with
    | mk lo2 hi2 flags2 =>
      simp only at hlo1 hhi1 hf1 hlo2 hhi2 hf2
      subst hlo2; subst hhi2; subst hlo1; subst hhi1
      congr 1
      rw [hf2, hf1]
      apply u32_eq_of_bv_eq
      dsimp only [Pion.U32.bxor]
      rw [BitVec.xor_assoc, BitVec.xor_self, BitVec.xor_zero]

/-- `Decimal::abs` never traps, is always non-negative, preserves `valid_decimal` and scale,
    is idempotent (`abs (abs d) = abs d`), and satisfies `abs (neg d) = abs d`. -/
theorem Decimal.abs_spec (d : Decimal) :
    ∃ d' : Decimal, Decimal.abs d = ok d' ∧
      Decimal.is_sign_negative d' = ok false ∧
      (valid_decimal d → valid_decimal d') ∧
      dec_mag d' = dec_mag d ∧
      dec_scale d' = dec_scale d := by
  unfold Decimal.abs
  refine ⟨_, rfl, ?_, ?_, rfl, ?_⟩
  · rw [Decimal.is_sign_negative_spec]
    congr 1
    unfold dec_neg
    dsimp only [Pion.U32.band]
    change ((d.flags.bv &&& MASK_ABS) &&& MASK_SIGN != ZERO_BV32) = false
    rw [BitVec.and_assoc]
    have h0 : (MASK_ABS &&& MASK_SIGN) = ZERO_BV32 := by decide
    rw [h0]
    change (d.flags.bv &&& 0#32 != ZERO_BV32) = false
    rw [BitVec.and_zero]; decide
  · intro ⟨hres, hsc⟩
    constructor
    · dsimp only [Pion.U32.band]
      change (d.flags.bv &&& MASK_ABS) &&& MASK_RES = ZERO_BV32
      rw [BitVec.and_assoc, BitVec.and_comm MASK_ABS, ← BitVec.and_assoc, hres]
      decide
    · dsimp only [Pion.U32.band]
      change (((d.flags.bv &&& MASK_ABS) &&& MASK_SCALE) >>> 16).toNat ≤ 28
      rw [BitVec.and_assoc]
      have hmask : (MASK_ABS &&& MASK_SCALE) = MASK_SCALE := by decide
      rw [hmask]; exact hsc
  · unfold dec_scale
    dsimp only [Pion.U32.band]
    change (((d.flags.bv &&& MASK_ABS) &&& MASK_SCALE) >>> 16).toNat = _
    rw [BitVec.and_assoc]
    have hmask : (MASK_ABS &&& MASK_SCALE) = MASK_SCALE := by decide
    rw [hmask]

theorem Decimal.abs_idempotent (d : Decimal) :
    (do let d1 ← Decimal.abs d; Decimal.abs d1) = Decimal.abs d := by
  unfold Decimal.abs
  simp only [b_ok]
  congr 1; congr 1
  apply u32_eq_of_bv_eq
  dsimp only [Pion.U32.band]
  rw [BitVec.and_assoc, BitVec.and_self]

theorem Decimal.abs_neg (d : Decimal) :
    (do let d1 ← Decimal.neg d; Decimal.abs d1) = Decimal.abs d := by
  obtain ⟨d1, hd1, hlo1, hhi1, hf1, _, _, _⟩ := Decimal.neg_spec d
  rw [hd1, b_ok]
  unfold Decimal.abs
  congr 1
  rw [hlo1, hhi1, hf1]
  congr 1
  apply u32_eq_of_bv_eq
  dsimp only [Pion.U32.band, Pion.U32.bxor, SIGN_MASK]
  rw [bv_and_xor_distrib_right]
  have h0 : ((2147483648#u32 : Std.U32).bv &&& (2147483647#u32 : Std.U32).bv) = 0#32 := by decide
  rw [h0, BitVec.xor_zero]


end DecimalProofs
