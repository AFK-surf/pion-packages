import DecimalProofs.Wire

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace DecimalProofs

open decimal

/-! ## 4. Aligned 96-bit Add/Sub, Exact Cross-Scale Comparison & Truncation -/

/-- Helper: `make_decimal_nonzero_sign` produces a valid `Decimal` with zero clearing negative sign. -/
private theorem make_decimal_nonzero_sign_spec (lo64 : Std.U64) (hi : Std.U32)
    (neg : Bool) (scale : Std.U32) (hs : scale.val ≤ 28) :
    ∃ d : Decimal, make_decimal_nonzero_sign lo64 hi neg scale = ok d ∧
      valid_decimal d ∧
      dec_mag d = val96 lo64 hi ∧
      dec_scale d = scale.val ∧
      dec_neg d = (if val96 lo64 hi = 0 then false else neg) := by
  unfold make_decimal_nonzero_sign
  have hlo := u64_val_lt lo64
  have hhi := u32_val_lt hi
  have hz_iff : ((lo64 == 0#u64) && (hi == 0#u32)) = decide (val96 lo64 hi = 0) := by
    unfold val96
    by_cases h1 : lo64 = 0#u64
    · by_cases h2 : hi = 0#u32
      · rw [h1, h2]
        have : (0#u64 : Std.U64).val + 2 ^ 64 * (0#u32 : Std.U32).val = 0 := by decide
        simp [this]
      · have hne : hi.val ≠ 0 := fun hz => h2 (UScalar.eq_of_val_eq hz)
        have hb1 : (lo64 == 0#u64) = true := by rw [h1]; decide
        have hb2 : (hi == 0#u32) = false := beq_false_of_ne h2
        have hm : lo64.val + 2 ^ 64 * hi.val ≠ 0 := by omega
        rw [hb1, hb2, Bool.true_and, decide_eq_false hm]
    · have hne : lo64.val ≠ 0 := fun hz => h1 (UScalar.eq_of_val_eq hz)
      have hb1 : (lo64 == 0#u64) = false := beq_false_of_ne h1
      have hm : lo64.val + 2 ^ 64 * hi.val ≠ 0 := by omega
      rw [hb1, Bool.false_and, decide_eq_false hm]
  obtain ⟨f, hf, hfv, hfs, hfn⟩ :=
    make_flags_spec (if ((lo64 == 0#u64) && (hi == 0#u32)) = true then false else neg) scale hs
  dsimp only
  rw [hf, b_ok]
  refine ⟨_, rfl, hfv, rfl, hfs, ?_⟩
  unfold dec_neg; dsimp only
  rw [hfn, hz_iff]
  by_cases hz : val96 lo64 hi = 0 <;> simp [hz]

/-- Exact specification of `reduce_scale_overflow96`: divides `2^96 + val96 lo64 hi` by 10
    with banker's rounding and decrements `scale` by 1 without trapping. -/
theorem reduce_scale_overflow96_spec (lo64_in : Std.U64) (hi_in : Std.U32) (scale : Std.U32)
    (hs1 : 1 ≤ scale.val) (hs28 : scale.val ≤ 28) :
    ∃ rlo rhi rscale, reduce_scale_overflow96 lo64_in hi_in scale = ok (rlo, rhi, rscale) ∧
      rscale.val = scale.val - 1 ∧ rscale.val ≤ 28 ∧
      (val96 rlo rhi = (2 ^ 96 + val96 lo64_in hi_in) / 10 ∨
       val96 rlo rhi = (2 ^ 96 + val96 lo64_in hi_in) / 10 + 1) := by
  unfold reduce_scale_overflow96 val96
  have hlo := u64_val_lt lo64_in
  have hhi := u32_val_lt hi_in
  have h10nz : (10#u64 : Std.U64).val ≠ 0 := by decide
  have h10v : (10#u64 : Std.U64).val = 10 := by decide
  obtain ⟨t, ht, htv⟩ := u64_shl32_ok 1#u64
  have htv' : t.val = 2 ^ 32 := by rw [htv]; decide
  rw [ht, b_ok]
  set num := Pion.U64.add (Pion.U32.to_uint64 hi_in) t
  have hnum : num.val = hi_in.val + 2 ^ 32 := by
    simp only [num, u64_add_val, u32_to_uint64_val, htv']
    exact Nat.mod_eq_of_lt (by omega)
  obtain ⟨t1, ht1, ht1v⟩ := u64_div_ok num h10nz
  dsimp only
  rw [ht1, b_ok]
  set hi := Pion.U64.to_uint t1
  have hhi_v : hi.val = num.val / 10 := by
    simp only [hi, u64_to_uint_val, ht1v, h10v]
    exact Nat.mod_eq_of_lt (by omega)
  set rem2 := Pion.U64.sub num (Pion.U64.mul (Pion.U32.to_uint64 hi) 10#u64)
  have hrem2 : rem2.val = num.val % 10 := by
    have hmul : (Pion.U64.mul (Pion.U32.to_uint64 hi) 10#u64).val = hi.val * 10 := by
      rw [u64_mul_val, u32_to_uint64_val, h10v, Nat.mod_eq_of_lt (by omega)]
    rw [u64_sub_val (by omega), hmul]; omega
  obtain ⟨t2, ht2, ht2v⟩ := u64_shl32_ok rem2
  obtain ⟨t3, ht3, ht3v⟩ := u64_shr32_ok lo64_in
  rw [ht2, b_ok, ht3, b_ok]
  have ht2v' : t2.val = (num.val % 10) * 2 ^ 32 := by
    rw [ht2v, hrem2, Nat.mod_eq_of_lt (by omega)]
  set num1 := Pion.U64.add t2 t3
  have hnum1 : num1.val = (num.val % 10) * 2 ^ 32 + lo64_in.val / 2 ^ 32 := by
    simp only [num1, u64_add_val, ht2v', ht3v]
    exact Nat.mod_eq_of_lt (by omega)
  obtain ⟨t4, ht4, ht4v⟩ := u64_div_ok num1 h10nz
  rw [ht4, b_ok]
  set div_ := Pion.U64.to_uint t4
  have hdiv_v : div_.val = num1.val / 10 := by
    simp only [div_, u64_to_uint_val, ht4v, h10v]
    exact Nat.mod_eq_of_lt (by omega)
  set rem1 := Pion.U64.sub num1 (Pion.U64.mul (Pion.U32.to_uint64 div_) 10#u64)
  have hrem1 : rem1.val = num1.val % 10 := by
    have hmul : (Pion.U64.mul (Pion.U32.to_uint64 div_) 10#u64).val = div_.val * 10 := by
      rw [u64_mul_val, u32_to_uint64_val, h10v, Nat.mod_eq_of_lt (by omega)]
    rw [u64_sub_val (by omega), hmul]; omega
  obtain ⟨t5, ht5, ht5v⟩ := u64_shl32_ok rem1
  rw [ht5, b_ok]
  have ht5v' : t5.val = (num1.val % 10) * 2 ^ 32 := by
    rw [ht5v, hrem1, Nat.mod_eq_of_lt (by omega)]
  set num2 := Pion.U64.add t5 (Pion.U64.band lo64_in 4294967295#u64)
  have hnum2 : num2.val = (num1.val % 10) * 2 ^ 32 + lo64_in.val % 2 ^ 32 := by
    simp only [num2, u64_add_val, ht5v', u64_band_mask32]
    exact Nat.mod_eq_of_lt (by omega)
  obtain ⟨lo64, hlo64, hlo64v⟩ := u64_shl32_ok (Pion.U32.to_uint64 div_)
  obtain ⟨t7, ht7, ht7v⟩ := u64_div_ok num2 h10nz
  rw [hlo64, b_ok, ht7, b_ok]
  have hlo64v' : lo64.val = div_.val * 2 ^ 32 := by
    rw [hlo64v, u32_to_uint64_val, Nat.mod_eq_of_lt (u32_val_lt div_)]
  set div1 := Pion.U64.to_uint t7
  have hdiv1_v : div1.val = num2.val / 10 := by
    simp only [div1, u64_to_uint_val, ht7v, h10v]
    exact Nat.mod_eq_of_lt (by omega)
  set lo641 := Pion.U64.add lo64 (Pion.U32.to_uint64 div1)
  have hlo641 : lo641.val = div_.val * 2 ^ 32 + div1.val := by
    simp only [lo641, u64_add_val, hlo64v', u32_to_uint64_val]
    exact Nat.mod_eq_of_lt (by have := u32_val_lt div_; have := u32_val_lt div1; omega)
  have hquot : lo641.val + 2 ^ 64 * hi.val = (2 ^ 96 + (lo64_in.val + 2 ^ 64 * hi_in.val)) / 10 := by
    omega
  have hsc_sub : (Pion.U32.sub scale 1#u32).val = scale.val - 1 := by
    have h1v : (1#u32 : Std.U32).val = 1 := by decide
    rw [u32_sub_val (by omega)]
    omega
  by_cases hround : ((decide (Pion.U32.sub (Pion.U64.to_uint num2) (Pion.U32.mul div1 10#u32) >= 5#u32)) &&
      ((decide (Pion.U32.sub (Pion.U64.to_uint num2) (Pion.U32.mul div1 10#u32) > 5#u32)) ||
       ((Pion.U64.band lo641 1#u64) != 0#u64))) = true
  · simp only [hround, ↓reduceIte]
    set lo642 := Pion.U64.add lo641 1#u64
    have hlo642 : lo642.val = (lo641.val + 1) % 2 ^ 64 := u64_add_val lo641 1#u64
    by_cases hz : lo642 = 0#u64
    · simp only [hz, ↓reduceIte]
      have hlo641_max : lo641.val = 2 ^ 64 - 1 := by
        have : lo642.val = 0 := by rw [hz]; rfl
        have := u64_val_lt lo641; omega
      have hhi1 : (Pion.U32.add hi 1#u32).val = hi.val + 1 := by
        have h1v : (1#u32 : Std.U32).val = 1 := by decide
        rw [u32_add_val, h1v, Nat.mod_eq_of_lt (by omega)]
      refine ⟨0#u64, Pion.U32.add hi 1#u32, Pion.U32.sub scale 1#u32, rfl, hsc_sub, by omega, Or.inr ?_⟩
      have h0v : (0#u64 : Std.U64).val = 0 := by decide
      omega
    · simp only [hz, ↓reduceIte]
      have hne : lo642.val ≠ 0 := fun h0 => hz (UScalar.eq_of_val_eq h0)
      have := u64_val_lt lo641
      refine ⟨lo642, hi, Pion.U32.sub scale 1#u32, rfl, hsc_sub, by omega, Or.inr ?_⟩
      omega
  · simp only [hround, ↓reduceIte]
    exact ⟨lo641, hi, Pion.U32.sub scale 1#u32, rfl, hsc_sub, by omega, Or.inl hquot⟩

/-- `aligned_add_96` (addition, no 96-bit overflow): exact sum, preserves validity and scale. -/
theorem aligned_add_96_add_no_overflow
    (a_lo : Std.U64) (a_hi : Std.U32) (b_lo : Std.U64) (b_hi : Std.U32)
    (neg : Bool) (scale : Std.U32) (hs : scale.val ≤ 28)
    (hfit : val96 a_lo a_hi + val96 b_lo b_hi < 2 ^ 96) :
    ∃ d : Decimal, aligned_add_96 a_lo a_hi b_lo b_hi neg scale false = ok (Res.Ok d) ∧
      valid_decimal d ∧
      dec_mag d = val96 a_lo a_hi + val96 b_lo b_hi ∧
      dec_scale d = scale.val := by
  unfold aligned_add_96
  simp only [Bool.false_eq_true, ↓reduceIte]
  have hal := u64_val_lt a_lo; have hbl := u64_val_lt b_lo
  have hah := u32_val_lt a_hi; have hbh := u32_val_lt b_hi
  unfold val96 at hfit
  set lo2 := Pion.U64.add a_lo b_lo
  have hlo2 : lo2.val = (a_lo.val + b_lo.val) % 2 ^ 64 := u64_add_val a_lo b_lo
  set carry : Std.U64 := if lo2 < a_lo then 1#u64 else 0#u64
  have hcarry : carry.val = (a_lo.val + b_lo.val) / 2 ^ 64 := by
    simp only [carry]
    by_cases hlt : lo2 < a_lo
    · rw [if_pos hlt]
      have : lo2.val < a_lo.val := hlt
      have : (1#u64 : Std.U64).val = 1 := by decide
      omega
    · rw [if_neg hlt]
      have : ¬(lo2.val < a_lo.val) := hlt
      have : (0#u64 : Std.U64).val = 0 := by decide
      omega
  set hi64 := Pion.U64.add (Pion.U64.add (Pion.U32.to_uint64 a_hi) (Pion.U32.to_uint64 b_hi)) carry
  have hhi64 : hi64.val = a_hi.val + b_hi.val + carry.val := by
    simp only [hi64, u64_add_val, u32_to_uint64_val]
    rw [Nat.mod_eq_of_lt (by omega), Nat.mod_eq_of_lt (by omega)]
  have hnotov : ¬(hi64 > 4294967295#u64) := by
    intro h
    have : (4294967295#u64 : Std.U64).val < hi64.val := h
    have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
    omega
  simp only [hnotov, ↓reduceIte]
  obtain ⟨d, hd, hdv, hdm, hds, _⟩ := make_decimal_nonzero_sign_spec lo2 (Pion.U64.to_uint hi64) neg scale hs
  rw [hd, b_ok]
  refine ⟨d, rfl, hdv, ?_, hds⟩
  rw [hdm]; unfold val96
  rw [u64_to_uint_val, Nat.mod_eq_of_lt (by omega)]
  omega

/-- `aligned_add_96` (addition, overflow at `scale = 0`): MUST return `Err(Overflow)` (never truncates). -/
theorem aligned_add_96_add_overflow_scale0
    (a_lo : Std.U64) (a_hi : Std.U32) (b_lo : Std.U64) (b_hi : Std.U32) (neg : Bool)
    (hov : val96 a_lo a_hi + val96 b_lo b_hi ≥ 2 ^ 96) :
    aligned_add_96 a_lo a_hi b_lo b_hi neg 0#u32 false = ok (Res.Err DecimalError.Overflow) := by
  unfold aligned_add_96
  simp only [Bool.false_eq_true, ↓reduceIte]
  have hal := u64_val_lt a_lo; have hbl := u64_val_lt b_lo
  have hah := u32_val_lt a_hi; have hbh := u32_val_lt b_hi
  unfold val96 at hov
  set lo2 := Pion.U64.add a_lo b_lo
  have hlo2 : lo2.val = (a_lo.val + b_lo.val) % 2 ^ 64 := u64_add_val a_lo b_lo
  set carry : Std.U64 := if lo2 < a_lo then 1#u64 else 0#u64
  have hcarry : carry.val = (a_lo.val + b_lo.val) / 2 ^ 64 := by
    simp only [carry]
    by_cases hlt : lo2 < a_lo
    · rw [if_pos hlt]
      have : lo2.val < a_lo.val := hlt
      have : (1#u64 : Std.U64).val = 1 := by decide
      omega
    · rw [if_neg hlt]
      have : ¬(lo2.val < a_lo.val) := hlt
      have : (0#u64 : Std.U64).val = 0 := by decide
      omega
  set hi64 := Pion.U64.add (Pion.U64.add (Pion.U32.to_uint64 a_hi) (Pion.U32.to_uint64 b_hi)) carry
  have hhi64 : hi64.val = a_hi.val + b_hi.val + carry.val := by
    simp only [hi64, u64_add_val, u32_to_uint64_val]
    rw [Nat.mod_eq_of_lt (by omega), Nat.mod_eq_of_lt (by omega)]
  have hgt : hi64 > 4294967295#u64 := by
    show (4294967295#u64 : Std.U64).val < hi64.val
    have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
    omega
  simp [hgt]

/-- `aligned_add_96` (addition, overflow at `1 ≤ scale ≤ 28`): rescales down by 10 to `scale - 1`. -/
theorem aligned_add_96_add_overflow_rescale
    (a_lo : Std.U64) (a_hi : Std.U32) (b_lo : Std.U64) (b_hi : Std.U32)
    (neg : Bool) (scale : Std.U32) (hs1 : 1 ≤ scale.val) (hs28 : scale.val ≤ 28)
    (hov : val96 a_lo a_hi + val96 b_lo b_hi ≥ 2 ^ 96) :
    ∃ d : Decimal, aligned_add_96 a_lo a_hi b_lo b_hi neg scale false = ok (Res.Ok d) ∧
      valid_decimal d ∧ dec_scale d = scale.val - 1 := by
  unfold aligned_add_96
  simp only [Bool.false_eq_true, ↓reduceIte]
  have hal := u64_val_lt a_lo; have hbl := u64_val_lt b_lo
  have hah := u32_val_lt a_hi; have hbh := u32_val_lt b_hi
  unfold val96 at hov
  set lo2 := Pion.U64.add a_lo b_lo
  have hlo2 : lo2.val = (a_lo.val + b_lo.val) % 2 ^ 64 := u64_add_val a_lo b_lo
  set carry : Std.U64 := if lo2 < a_lo then 1#u64 else 0#u64
  have hcarry : carry.val = (a_lo.val + b_lo.val) / 2 ^ 64 := by
    simp only [carry]
    by_cases hlt : lo2 < a_lo
    · rw [if_pos hlt]
      have : lo2.val < a_lo.val := hlt
      have : (1#u64 : Std.U64).val = 1 := by decide
      omega
    · rw [if_neg hlt]
      have : ¬(lo2.val < a_lo.val) := hlt
      have : (0#u64 : Std.U64).val = 0 := by decide
      omega
  set hi64 := Pion.U64.add (Pion.U64.add (Pion.U32.to_uint64 a_hi) (Pion.U32.to_uint64 b_hi)) carry
  have hhi64 : hi64.val = a_hi.val + b_hi.val + carry.val := by
    simp only [hi64, u64_add_val, u32_to_uint64_val]
    rw [Nat.mod_eq_of_lt (by omega), Nat.mod_eq_of_lt (by omega)]
  have hgt : hi64 > 4294967295#u64 := by
    show (4294967295#u64 : Std.U64).val < hi64.val
    have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
    omega
  have hsc_nz : scale ≠ 0#u32 := fun h0 => by
    have : scale.val = 0 := by rw [h0]; rfl
    omega
  simp only [hgt, hsc_nz, ↓reduceIte]
  obtain ⟨rlo, rhi, rsc, hred, hrsc, hrsc28, _⟩ :=
    reduce_scale_overflow96_spec lo2 (Pion.U64.to_uint hi64) scale hs1 hs28
  rw [hred, b_ok]
  obtain ⟨d, hd, hdv, _, hds, _⟩ := make_decimal_nonzero_sign_spec rlo rhi neg rsc hrsc28
  exact ⟨d, by
    change (do let __t ← make_decimal_nonzero_sign rlo rhi neg rsc; ok (Pion.Res.Ok __t)) = _
    rw [hd]; simp, hdv, by rw [hds, hrsc]⟩

/-- `aligned_add_96` (subtraction): exact absolute difference, never overflows, clears `-0`. -/
theorem aligned_add_96_sub_spec
    (a_lo : Std.U64) (a_hi : Std.U32) (b_lo : Std.U64) (b_hi : Std.U32)
    (neg : Bool) (scale : Std.U32) (hs : scale.val ≤ 28) :
    ∃ d : Decimal, aligned_add_96 a_lo a_hi b_lo b_hi neg scale true = ok (Res.Ok d) ∧
      valid_decimal d ∧
      dec_scale d = scale.val ∧
      dec_mag d = Int.natAbs ((val96 a_lo a_hi : Int) - (val96 b_lo b_hi : Int)) := by
  unfold aligned_add_96
  simp only [↓reduceIte]
  have hal := u64_val_lt a_lo; have hbl := u64_val_lt b_lo
  have hah := u32_val_lt a_hi; have hbh := u32_val_lt b_hi
  by_cases hge : (if a_hi ≠ b_hi then decide (a_hi > b_hi) else decide (a_lo >= b_lo)) = true
  · rw [if_pos hge]
    have hval_ge : val96 b_lo b_hi ≤ val96 a_lo a_hi := by
      unfold val96
      by_cases hne : a_hi ≠ b_hi
      · rw [if_pos hne] at hge
        simp only [decide_eq_true_eq] at hge
        have : b_hi.val < a_hi.val := hge; omega
      · rw [if_neg hne] at hge
        simp only [decide_eq_true_eq] at hge
        have heq : a_hi = b_hi := Classical.not_not.mp hne
        have : b_lo.val ≤ a_lo.val := hge; rw [heq]; omega
    set borrow : Std.U32 := if a_lo < b_lo then 1#u32 else 0#u32
    set lo := Pion.U64.sub a_lo b_lo
    set hi := Pion.U32.sub (Pion.U32.sub a_hi b_hi) borrow
    obtain ⟨d, hd, hdv, hdm, hds, _⟩ := make_decimal_nonzero_sign_spec lo hi neg scale hs
    rw [hd, b_ok]
    refine ⟨d, rfl, hdv, hds, ?_⟩
    rw [hdm]; unfold val96 at hval_ge ⊢
    by_cases hlt : a_lo < b_lo
    · have hlt' : a_lo.val < b_lo.val := hlt
      have hbw : borrow.val = 1 := by simp [borrow, hlt]
      have hlo_v : lo.val = 2 ^ 64 + a_lo.val - b_lo.val := u64_sub_wrap_val hlt'
      have hhi_v : hi.val = a_hi.val - b_hi.val - 1 := by
        simp only [hi]
        have h1 : (Pion.U32.sub a_hi b_hi).val = a_hi.val - b_hi.val := u32_sub_val (by omega)
        rw [u32_sub_val (by omega), h1, hbw]
      omega
    · have hge' : b_lo.val ≤ a_lo.val := by have : ¬(a_lo.val < b_lo.val) := hlt; omega
      have hbw : borrow.val = 0 := by simp [borrow, hlt]
      have hlo_v : lo.val = a_lo.val - b_lo.val := u64_sub_val hge'
      have hhi_v : hi.val = a_hi.val - b_hi.val := by
        simp only [hi]
        have h1 : (Pion.U32.sub a_hi b_hi).val = a_hi.val - b_hi.val := u32_sub_val (by omega)
        rw [u32_sub_val (by omega), h1, hbw]; omega
      omega
  · rw [if_neg hge]
    have hval_lt : val96 a_lo a_hi < val96 b_lo b_hi := by
      unfold val96
      by_cases hne : a_hi ≠ b_hi
      · rw [if_pos hne] at hge
        simp only [decide_eq_true_eq] at hge
        have : ¬(b_hi.val < a_hi.val) := hge
        have : a_hi.val ≠ b_hi.val := fun he => hne (UScalar.eq_of_val_eq he)
        omega
      · rw [if_neg hne] at hge
        simp only [decide_eq_true_eq] at hge
        have heq : a_hi = b_hi := Classical.not_not.mp hne
        have : ¬(b_lo.val ≤ a_lo.val) := hge; rw [heq]; omega
    set borrow : Std.U32 := if b_lo < a_lo then 1#u32 else 0#u32
    set lo := Pion.U64.sub b_lo a_lo
    set hi := Pion.U32.sub (Pion.U32.sub b_hi a_hi) borrow
    obtain ⟨d, hd, hdv, hdm, hds, _⟩ := make_decimal_nonzero_sign_spec lo hi (!neg) scale hs
    rw [hd, b_ok]
    refine ⟨d, rfl, hdv, hds, ?_⟩
    rw [hdm]; unfold val96 at hval_lt ⊢
    by_cases hlt : b_lo < a_lo
    · have hlt' : b_lo.val < a_lo.val := hlt
      have hbw : borrow.val = 1 := by simp [borrow, hlt]
      have hlo_v : lo.val = 2 ^ 64 + b_lo.val - a_lo.val := u64_sub_wrap_val hlt'
      have hhi_v : hi.val = b_hi.val - a_hi.val - 1 := by
        simp only [hi]
        have h1 : (Pion.U32.sub b_hi a_hi).val = b_hi.val - a_hi.val := u32_sub_val (by omega)
        rw [u32_sub_val (by omega), h1, hbw]
      omega
    · have hge' : a_lo.val ≤ b_lo.val := by have : ¬(b_lo.val < a_lo.val) := hlt; omega
      have hbw : borrow.val = 0 := by simp [borrow, hlt]
      have hlo_v : lo.val = b_lo.val - a_lo.val := u64_sub_val hge'
      have hhi_v : hi.val = b_hi.val - a_hi.val := by
        simp only [hi]
        have h1 : (Pion.U32.sub b_hi a_hi).val = b_hi.val - a_hi.val := u32_sub_val (by omega)
        rw [u32_sub_val (by omega), h1, hbw]; omega
      omega

/-- Loop specification for `cmp_magnitude_loop0`: scales `(b_lo, b_hi)` by `10^diff` or detects `≥ 2^96`. -/
private theorem cmp_magnitude_loop0_spec (diff : Std.I32) (b_lo : Std.U64) (b_hi : Std.U32)
    (hd0 : 0 ≤ diff.val) (hd28 : diff.val ≤ 28) (B : Nat)
    (hB : val96 b_lo b_hi * 10 ^ diff.val.toNat = B) :
    cmp_magnitude_loop0 diff b_lo b_hi ⦃ res =>
      match res with
      | .inl r => r = (-1)#i32 ∧ B ≥ 2 ^ 96
      | .inr (_, b_lo', b_hi') => val96 b_lo' b_hi' = B ⦄ := by
  unfold cmp_magnitude_loop0
  apply loop.spec_decr_nat
    (measure := fun (d, _, _) => d.val.toNat)
    (inv := fun (d, lo, hi) => 0 ≤ d.val ∧ d.val ≤ 28 ∧ val96 lo hi * 10 ^ d.val.toNat = B)
  · rintro ⟨d, lo, hi⟩ ⟨h0, h28, hinv⟩
    unfold cmp_magnitude_loop0.body
    by_cases hpos : d > 0#i32
    · have hdpos : 0 < d.val := by have : (0#i32 : Std.I32).val < d.val := hpos; exact this
      simp only [hpos, ↓reduceIte]
      set step : Std.I32 := if d >= 9#i32 then 9#i32 else d
      have hstep_pos : 1 ≤ step.val ∧ step.val ≤ 9 ∧ step.val ≤ d.val := by
        simp only [step]
        by_cases h9 : d >= 9#i32
        · rw [if_pos h9]
          have : (9#i32 : Std.I32).val ≤ d.val := h9
          have hv : (9#i32 : Std.I32).val = 9 := by decide
          omega
        · rw [if_neg h9]
          have : ¬((9#i32 : Std.I32).val ≤ d.val) := h9
          have hv : (9#i32 : Std.I32).val = 9 := by decide
          omega
      obtain ⟨p32, hp32, hp32v⟩ := pow10_u32_spec step (by omega) (by omega)
      rw [hp32, b_ok]
      set power := Pion.U32.to_uint64 p32
      have hpow_v : power.val = 10 ^ step.val.toNat := by rw [u32_to_uint64_val, hp32v]
      have hpow_le : power.val ≤ 10 ^ 9 := by
        rw [hpow_v]; exact Nat.pow_le_pow_right (by omega) (by omega)
      have hlo := u64_val_lt lo; have hhi := u32_val_lt hi
      set tmp_lo := Pion.U64.mul (Pion.U64.band lo 4294967295#u64) power
      have htmp_lo : tmp_lo.val = (lo.val % 2 ^ 32) * power.val := by
        simp only [tmp_lo, u64_mul_val, u64_band_mask32]
        have : lo.val % 2 ^ 32 < 2 ^ 32 := Nat.mod_lt _ (by norm_num)
        rw [Nat.mod_eq_of_lt (by nlinarith)]
      obtain ⟨t7, ht7, ht7v⟩ := u64_shr32_ok lo
      obtain ⟨t8, ht8, ht8v⟩ := u64_shr32_ok tmp_lo
      rw [ht7, b_ok, ht8, b_ok]
      have ht7_lt : t7.val < 2 ^ 32 := by omega
      have ht8_lt : t8.val < 10 ^ 9 := by
        have : lo.val % 2 ^ 32 < 2 ^ 32 := Nat.mod_lt _ (by norm_num)
        have : tmp_lo.val < 2 ^ 32 * 10 ^ 9 := by nlinarith
        omega
      set tmp := Pion.U64.add (Pion.U64.mul t7 power) t8
      have htmp : tmp.val = (lo.val / 2 ^ 32) * power.val + tmp_lo.val / 2 ^ 32 := by
        simp only [tmp, u64_add_val, u64_mul_val, ht7v, ht8v]
        have hm1 : (lo.val / 2 ^ 32) * power.val < 2 ^ 64 := by nlinarith
        rw [Nat.mod_eq_of_lt hm1, Nat.mod_eq_of_lt (by nlinarith)]
      obtain ⟨t9, ht9, ht9v⟩ := u64_shl32_ok tmp
      rw [ht9, b_ok]
      set lo1 := Pion.U64.bor (Pion.U64.band tmp_lo 4294967295#u64) t9
      have hlo1 : lo1.val = tmp_lo.val % 2 ^ 32 + (tmp.val % 2 ^ 32) * 2 ^ 32 := by
        have h1 : (Pion.U64.band tmp_lo 4294967295#u64).val < 2 ^ 32 := by
          rw [u64_band_mask32]; exact Nat.mod_lt _ (by norm_num)
        have h2 : t9.val % 2 ^ 32 = 0 := by rw [ht9v]; exact Nat.mul_mod_left _ _
        rw [u64_bor_disjoint_32 h1 h2, u64_band_mask32, ht9v]
      obtain ⟨t10, ht10, ht10v⟩ := u64_shr32_ok tmp
      rw [ht10, b_ok]
      have ht10_lt : t10.val < 2 ^ 32 := by have := u64_val_lt tmp; omega
      set tmp1 := Pion.U64.add t10 (Pion.U64.mul (Pion.U32.to_uint64 hi) power)
      have htmp1 : tmp1.val = tmp.val / 2 ^ 32 + hi.val * power.val := by
        simp only [tmp1, u64_add_val, u64_mul_val, u32_to_uint64_val, ht10v]
        have hm1 : hi.val * power.val < 2 ^ 64 := by nlinarith
        rw [Nat.mod_eq_of_lt hm1, Nat.mod_eq_of_lt (by nlinarith)]
      have hmul_eq : lo1.val + 2 ^ 64 * tmp1.val = val96 lo hi * power.val := by
        unfold val96
        have : lo.val = lo.val % 2 ^ 32 + 2 ^ 32 * (lo.val / 2 ^ 32) := by omega
        have : tmp_lo.val = tmp_lo.val % 2 ^ 32 + 2 ^ 32 * (tmp_lo.val / 2 ^ 32) := by omega
        have : tmp.val = tmp.val % 2 ^ 32 + 2 ^ 32 * (tmp.val / 2 ^ 32) := by omega
        nlinarith
      have hpow_split : 10 ^ d.val.toNat = power.val * 10 ^ (d.val.toNat - step.val.toNat) := by
        rw [hpow_v, ← Nat.pow_add]; congr 1; omega
      by_cases hov : tmp1 > 4294967295#u64
      · simp only [hov, ↓reduceIte, WP.spec_ok]
        refine ⟨trivial, ?_⟩
        have hgt : tmp1.val ≥ 2 ^ 32 := by
          have : (4294967295#u64 : Std.U64).val < tmp1.val := hov
          have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
          omega
        have h1 : val96 lo hi * power.val ≥ 2 ^ 96 := by omega
        have h2 : 0 < 10 ^ (d.val.toNat - step.val.toNat) := Nat.pos_of_ne_zero (by positivity)
        rw [← hinv, hpow_split, ← Nat.mul_assoc]
        exact Nat.le_trans h1 (Nat.le_mul_of_pos_right _ h2)
      · simp only [hov, ↓reduceIte, WP.spec_ok]
        have hle : tmp1.val < 2 ^ 32 := by
          have : ¬((4294967295#u64 : Std.U64).val < tmp1.val) := hov
          have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
          omega
        have hd1 : (Pion.I32.sub d step).val = d.val - step.val := i32_sub_val (by omega) (by omega)
        refine ⟨⟨by omega, by omega, ?_⟩, by omega⟩
        have hval96_eq : val96 lo1 (Pion.U64.to_uint tmp1) = val96 lo hi * power.val := by
          unfold val96; rw [u64_to_uint_val, Nat.mod_eq_of_lt hle]; exact hmul_eq
        rw [hval96_eq, show (Pion.I32.sub d step).val.toNat = d.val.toNat - step.val.toNat by omega,
          Nat.mul_assoc, ← hpow_split, hinv]
    · simp only [hpos, ↓reduceIte, WP.spec_ok]
      have h0v : (0#i32 : Std.I32).val = 0 := by decide
      have hd0' : d.val = 0 := by have : ¬((0#i32 : Std.I32).val < d.val) := hpos; omega
      have : d.val.toNat = 0 := by omega
      rw [this, Nat.pow_zero, Nat.mul_one] at hinv
      exact hinv
  · exact ⟨hd0, hd28, hB⟩

/-- Loop specification for `cmp_magnitude_loop1`: symmetric to `cmp_magnitude_loop0`. -/
private theorem cmp_magnitude_loop1_spec (diff : Std.I32) (a_lo : Std.U64) (a_hi : Std.U32)
    (hd0 : 0 ≤ diff.val) (hd28 : diff.val ≤ 28) (A : Nat)
    (hA : val96 a_lo a_hi * 10 ^ diff.val.toNat = A) :
    cmp_magnitude_loop1 diff a_lo a_hi ⦃ res =>
      match res with
      | .inl r => r = 1#i32 ∧ A ≥ 2 ^ 96
      | .inr (_, a_lo', a_hi') => val96 a_lo' a_hi' = A ⦄ := by
  unfold cmp_magnitude_loop1
  apply loop.spec_decr_nat
    (measure := fun (d, _, _) => d.val.toNat)
    (inv := fun (d, lo, hi) => 0 ≤ d.val ∧ d.val ≤ 28 ∧ val96 lo hi * 10 ^ d.val.toNat = A)
  · rintro ⟨d, lo, hi⟩ ⟨h0, h28, hinv⟩
    unfold cmp_magnitude_loop1.body
    by_cases hpos : d > 0#i32
    · have hdpos : 0 < d.val := by have : (0#i32 : Std.I32).val < d.val := hpos; exact this
      simp only [hpos, ↓reduceIte]
      set step : Std.I32 := if d >= 9#i32 then 9#i32 else d
      have hstep_pos : 1 ≤ step.val ∧ step.val ≤ 9 ∧ step.val ≤ d.val := by
        simp only [step]
        by_cases h9 : d >= 9#i32
        · rw [if_pos h9]
          have : (9#i32 : Std.I32).val ≤ d.val := h9
          have hv : (9#i32 : Std.I32).val = 9 := by decide
          omega
        · rw [if_neg h9]
          have : ¬((9#i32 : Std.I32).val ≤ d.val) := h9
          have hv : (9#i32 : Std.I32).val = 9 := by decide
          omega
      obtain ⟨p32, hp32, hp32v⟩ := pow10_u32_spec step (by omega) (by omega)
      rw [hp32, b_ok]
      set power := Pion.U32.to_uint64 p32
      have hpow_v : power.val = 10 ^ step.val.toNat := by rw [u32_to_uint64_val, hp32v]
      have hpow_le : power.val ≤ 10 ^ 9 := by
        rw [hpow_v]; exact Nat.pow_le_pow_right (by omega) (by omega)
      have hlo := u64_val_lt lo; have hhi := u32_val_lt hi
      set tmp_lo := Pion.U64.mul (Pion.U64.band lo 4294967295#u64) power
      have htmp_lo : tmp_lo.val = (lo.val % 2 ^ 32) * power.val := by
        simp only [tmp_lo, u64_mul_val, u64_band_mask32]
        have : lo.val % 2 ^ 32 < 2 ^ 32 := Nat.mod_lt _ (by norm_num)
        rw [Nat.mod_eq_of_lt (by nlinarith)]
      obtain ⟨t7, ht7, ht7v⟩ := u64_shr32_ok lo
      obtain ⟨t8, ht8, ht8v⟩ := u64_shr32_ok tmp_lo
      rw [ht7, b_ok, ht8, b_ok]
      have ht7_lt : t7.val < 2 ^ 32 := by omega
      have ht8_lt : t8.val < 10 ^ 9 := by
        have : lo.val % 2 ^ 32 < 2 ^ 32 := Nat.mod_lt _ (by norm_num)
        have : tmp_lo.val < 2 ^ 32 * 10 ^ 9 := by nlinarith
        omega
      set tmp := Pion.U64.add (Pion.U64.mul t7 power) t8
      have htmp : tmp.val = (lo.val / 2 ^ 32) * power.val + tmp_lo.val / 2 ^ 32 := by
        simp only [tmp, u64_add_val, u64_mul_val, ht7v, ht8v]
        have hm1 : (lo.val / 2 ^ 32) * power.val < 2 ^ 64 := by nlinarith
        rw [Nat.mod_eq_of_lt hm1, Nat.mod_eq_of_lt (by nlinarith)]
      obtain ⟨t9, ht9, ht9v⟩ := u64_shl32_ok tmp
      rw [ht9, b_ok]
      set lo1 := Pion.U64.bor (Pion.U64.band tmp_lo 4294967295#u64) t9
      have hlo1 : lo1.val = tmp_lo.val % 2 ^ 32 + (tmp.val % 2 ^ 32) * 2 ^ 32 := by
        have h1 : (Pion.U64.band tmp_lo 4294967295#u64).val < 2 ^ 32 := by
          rw [u64_band_mask32]; exact Nat.mod_lt _ (by norm_num)
        have h2 : t9.val % 2 ^ 32 = 0 := by rw [ht9v]; exact Nat.mul_mod_left _ _
        rw [u64_bor_disjoint_32 h1 h2, u64_band_mask32, ht9v]
      obtain ⟨t10, ht10, ht10v⟩ := u64_shr32_ok tmp
      rw [ht10, b_ok]
      have ht10_lt : t10.val < 2 ^ 32 := by have := u64_val_lt tmp; omega
      set tmp1 := Pion.U64.add t10 (Pion.U64.mul (Pion.U32.to_uint64 hi) power)
      have htmp1 : tmp1.val = tmp.val / 2 ^ 32 + hi.val * power.val := by
        simp only [tmp1, u64_add_val, u64_mul_val, u32_to_uint64_val, ht10v]
        have hm1 : hi.val * power.val < 2 ^ 64 := by nlinarith
        rw [Nat.mod_eq_of_lt hm1, Nat.mod_eq_of_lt (by nlinarith)]
      have hmul_eq : lo1.val + 2 ^ 64 * tmp1.val = val96 lo hi * power.val := by
        unfold val96
        have : lo.val = lo.val % 2 ^ 32 + 2 ^ 32 * (lo.val / 2 ^ 32) := by omega
        have : tmp_lo.val = tmp_lo.val % 2 ^ 32 + 2 ^ 32 * (tmp_lo.val / 2 ^ 32) := by omega
        have : tmp.val = tmp.val % 2 ^ 32 + 2 ^ 32 * (tmp.val / 2 ^ 32) := by omega
        nlinarith
      have hpow_split : 10 ^ d.val.toNat = power.val * 10 ^ (d.val.toNat - step.val.toNat) := by
        rw [hpow_v, ← Nat.pow_add]; congr 1; omega
      by_cases hov : tmp1 > 4294967295#u64
      · simp only [hov, ↓reduceIte, WP.spec_ok]
        refine ⟨trivial, ?_⟩
        have hgt : tmp1.val ≥ 2 ^ 32 := by
          have : (4294967295#u64 : Std.U64).val < tmp1.val := hov
          have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
          omega
        have h1 : val96 lo hi * power.val ≥ 2 ^ 96 := by omega
        have h2 : 0 < 10 ^ (d.val.toNat - step.val.toNat) := Nat.pos_of_ne_zero (by positivity)
        rw [← hinv, hpow_split, ← Nat.mul_assoc]
        exact Nat.le_trans h1 (Nat.le_mul_of_pos_right _ h2)
      · simp only [hov, ↓reduceIte, WP.spec_ok]
        have hle : tmp1.val < 2 ^ 32 := by
          have : ¬((4294967295#u64 : Std.U64).val < tmp1.val) := hov
          have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
          omega
        have hd1 : (Pion.I32.sub d step).val = d.val - step.val := i32_sub_val (by omega) (by omega)
        refine ⟨⟨by omega, by omega, ?_⟩, by omega⟩
        have hval96_eq : val96 lo1 (Pion.U64.to_uint tmp1) = val96 lo hi * power.val := by
          unfold val96; rw [u64_to_uint_val, Nat.mod_eq_of_lt hle]; exact hmul_eq
        rw [hval96_eq, show (Pion.I32.sub d step).val.toNat = d.val.toNat - step.val.toNat by omega,
          Nat.mul_assoc, ← hpow_split, hinv]
    · simp only [hpos, ↓reduceIte, WP.spec_ok]
      have h0v : (0#i32 : Std.I32).val = 0 := by decide
      have hd0' : d.val = 0 := by have : ¬((0#i32 : Std.I32).val < d.val) := hpos; omega
      have : d.val.toNat = 0 := by omega
      rw [this, Nat.pow_zero, Nat.mul_one] at hinv
      exact hinv
  · exact ⟨hd0, hd28, hA⟩

/-- Helper: lexicographic `(hi, lo64)` comparison matches `val96` comparison. -/
private theorem cmp_val96_inline (a_lo : Std.U64) (a_hi : Std.U32) (b_lo : Std.U64) (b_hi : Std.U32) :
    let r : Std.I32 := if a_hi < b_hi then (-1)#i32 else if a_hi > b_hi then 1#i32 else
      if a_lo < b_lo then (-1)#i32 else if a_lo > b_lo then 1#i32 else 0#i32
    (r = (-1)#i32 ↔ val96 a_lo a_hi < val96 b_lo b_hi) ∧
    (r = 0#i32 ↔ val96 a_lo a_hi = val96 b_lo b_hi) ∧
    (r = 1#i32 ↔ val96 a_lo a_hi > val96 b_lo b_hi) := by
  have hal := u64_val_lt a_lo; have hbl := u64_val_lt b_lo
  have hah := u32_val_lt a_hi; have hbh := u32_val_lt b_hi
  unfold val96
  dsimp only
  split_ifs with h1 h2 h3 h4
  · have : a_hi.val < b_hi.val := h1
    exact ⟨⟨fun _ => by omega, fun _ => rfl⟩, ⟨fun h => absurd h (by decide), fun _ => by omega⟩,
      ⟨fun h => absurd h (by decide), fun _ => by omega⟩⟩
  · have : b_hi.val < a_hi.val := h2
    exact ⟨⟨fun h => absurd h (by decide), fun _ => by omega⟩, ⟨fun h => absurd h (by decide), fun _ => by omega⟩,
      ⟨fun _ => by omega, fun _ => rfl⟩⟩
  · have : a_hi.val = b_hi.val := by have : ¬(a_hi.val < b_hi.val) := h1; have : ¬(b_hi.val < a_hi.val) := h2; omega
    have : a_lo.val < b_lo.val := h3
    exact ⟨⟨fun _ => by omega, fun _ => rfl⟩, ⟨fun h => absurd h (by decide), fun _ => by omega⟩,
      ⟨fun h => absurd h (by decide), fun _ => by omega⟩⟩
  · have : a_hi.val = b_hi.val := by have : ¬(a_hi.val < b_hi.val) := h1; have : ¬(b_hi.val < a_hi.val) := h2; omega
    have : b_lo.val < a_lo.val := h4
    exact ⟨⟨fun h => absurd h (by decide), fun _ => by omega⟩, ⟨fun h => absurd h (by decide), fun _ => by omega⟩,
      ⟨fun _ => by omega, fun _ => rfl⟩⟩
  · have : a_hi.val = b_hi.val := by have : ¬(a_hi.val < b_hi.val) := h1; have : ¬(b_hi.val < a_hi.val) := h2; omega
    have : a_lo.val = b_lo.val := by have : ¬(a_lo.val < b_lo.val) := h3; have : ¬(b_lo.val < a_lo.val) := h4; omega
    exact ⟨⟨fun h => absurd h (by decide), fun _ => by omega⟩, ⟨fun _ => by omega, fun _ => rfl⟩,
      ⟨fun h => absurd h (by decide), fun _ => by omega⟩⟩

/-- Exact cross-scale magnitude comparison (`cmp_magnitude`):
    for ANY two valid `Decimal`s (`0 ≤ scale ≤ 28`), never traps and matches exact
    cross-multiplied natural number order `dec_mag a * 10^(dec_scale b) ⋛ dec_mag b * 10^(dec_scale a)`. -/
theorem cmp_magnitude_spec (a b : Decimal) (ha : valid_decimal a) (hb : valid_decimal b) :
    ∃ r : Std.I32, cmp_magnitude a b = ok r ∧
      (r = (-1)#i32 ↔ dec_mag a * 10 ^ dec_scale b < dec_mag b * 10 ^ dec_scale a) ∧
      (r = 0#i32 ↔ dec_mag a * 10 ^ dec_scale b = dec_mag b * 10 ^ dec_scale a) ∧
      (r = 1#i32 ↔ dec_mag a * 10 ^ dec_scale b > dec_mag b * 10 ^ dec_scale a) := by
  unfold cmp_magnitude
  obtain ⟨sc1, hsc1, hsc1v⟩ := Decimal.scale_spec a
  obtain ⟨sc2, hsc2, hsc2v⟩ := Decimal.scale_spec b
  rw [hsc1, b_ok, hsc2, b_ok]
  have ha28 : dec_scale a ≤ 28 := ha.2
  have hb28 : dec_scale b ≤ 28 := hb.2
  have hs1v : (Pion.U32.to_int sc1).val = (dec_scale a : Int) := by
    rw [u32_to_int_val (by omega), hsc1v]
  have hs2v : (Pion.U32.to_int sc2).val = (dec_scale b : Int) := by
    rw [u32_to_int_val (by omega), hsc2v]
  have ha_lt96 : dec_mag a < 2 ^ 96 := by
    unfold dec_mag val96; have := u64_val_lt a.lo64; have := u32_val_lt a.hi; omega
  have hb_lt96 : dec_mag b < 2 ^ 96 := by
    unfold dec_mag val96; have := u64_val_lt b.lo64; have := u32_val_lt b.hi; omega
  set s1 := Pion.U32.to_int sc1
  set s2 := Pion.U32.to_int sc2
  by_cases hne : s1 ≠ s2
  · rw [if_pos hne]
    by_cases hgt : s1 > s2
    · rw [if_pos hgt]
      have hs1_gt : dec_scale b < dec_scale a := by have : s2.val < s1.val := hgt; omega
      have hpow_rel : 10 ^ dec_scale a = 10 ^ dec_scale b * 10 ^ (dec_scale a - dec_scale b) := by
        rw [← Nat.pow_add, show dec_scale b + (dec_scale a - dec_scale b) = dec_scale a by omega]
      have hpos_p : 0 < 10 ^ dec_scale b := Nat.pos_of_ne_zero (by positivity)
      set diff := Pion.I32.sub s1 s2
      have hdiff : diff.val = (dec_scale a : Int) - (dec_scale b : Int) := by
        dsimp only [diff]
        rw [i32_sub_val (by omega) (by omega)]
        omega
      by_cases hfast : ((b.hi == 0#u32) && decide (diff <= 19#i32)) = true
      · rw [if_pos hfast]
        simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hfast
        have hdiff19 : diff.val ≤ 19 := by
          have : diff.val ≤ (19#i32 : Std.I32).val := hfast.2
          have hv : (19#i32 : Std.I32).val = 19 := by decide
          omega
        obtain ⟨p64, hp64, hp64v⟩ := pow10_u64_spec diff (by omega) hdiff19
        obtain ⟨nl, nh, hmul, hmulv⟩ := u64_mul_wide_spec b.lo64 p64
        rw [hp64, b_ok, hmul, b_ok]
        have hB_eq : nl.val + 2 ^ 64 * nh.val = dec_mag b * 10 ^ (dec_scale a - dec_scale b) := by
          rw [hmulv, hp64v, show diff.val.toNat = dec_scale a - dec_scale b by omega]
          unfold dec_mag val96; rw [hfast.1]; simp
        by_cases hov : nh > 4294967295#u64
        · have hnh : nh.val ≥ 2 ^ 32 := by
            have : (4294967295#u64 : Std.U64).val < nh.val := hov
            have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
            omega
          have hlt_mag : dec_mag a < dec_mag b * 10 ^ (dec_scale a - dec_scale b) := by omega
          have hlt_rat : dec_mag a * 10 ^ dec_scale b < dec_mag b * 10 ^ dec_scale a := by
            rw [hpow_rel, Nat.mul_comm (10 ^ dec_scale b), ← Nat.mul_assoc]
            exact Nat.mul_lt_mul_of_pos_right hlt_mag hpos_p
          exact ⟨(-1)#i32, by
            change (if nh > 4294967295#u64 then _ else _) = _
            rw [if_pos hov], ⟨fun _ => hlt_rat, fun _ => rfl⟩,
            ⟨fun h => absurd h (by decide), fun h => by omega⟩,
            ⟨fun h => absurd h (by decide), fun h => by omega⟩⟩
        · have hnh : nh.val < 2 ^ 32 := by
            have : ¬((4294967295#u64 : Std.U64).val < nh.val) := hov
            have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
            omega
          have hval_b : val96 nl (Pion.U64.to_uint nh) = dec_mag b * 10 ^ (dec_scale a - dec_scale b) := by
            unfold val96; rw [u64_to_uint_val, Nat.mod_eq_of_lt hnh]; exact hB_eq
          have hcmp := cmp_val96_inline a.lo64 a.hi nl (Pion.U64.to_uint nh)
          rw [hval_b] at hcmp
          refine ⟨_, by
            change (if nh > 4294967295#u64 then _ else _) = _
            rw [if_neg hov], ?_, ?_, ?_⟩
          · rw [hcmp.1, hpow_rel, Nat.mul_comm (10 ^ dec_scale b), ← Nat.mul_assoc]
            exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_p, fun h => Nat.lt_of_mul_lt_mul_right h⟩
          · rw [hcmp.2.1, hpow_rel, Nat.mul_comm (10 ^ dec_scale b), ← Nat.mul_assoc]
            exact ⟨fun h => congrArg (· * 10 ^ dec_scale b) h, fun h => Nat.eq_of_mul_eq_mul_right hpos_p h⟩
          · rw [hcmp.2.2, hpow_rel, Nat.mul_comm (10 ^ dec_scale b), ← Nat.mul_assoc]
            exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_p, fun h => Nat.lt_of_mul_lt_mul_right h⟩
      · rw [if_neg hfast]
        have hloop := cmp_magnitude_loop0_spec diff b.lo64 b.hi (by omega) (by omega)
          (dec_mag b * 10 ^ (dec_scale a - dec_scale b))
          (by unfold dec_mag; rw [show diff.val.toNat = dec_scale a - dec_scale b by omega])
        rw [wp_ok_iff] at hloop
        obtain ⟨res, hres, hpost⟩ := hloop
        rw [hres, b_ok]
        cases res with
        | inl r =>
          obtain ⟨hr, hge96⟩ := hpost
          subst hr
          have hlt_rat : dec_mag a * 10 ^ dec_scale b < dec_mag b * 10 ^ dec_scale a := by
            rw [hpow_rel, Nat.mul_comm (10 ^ dec_scale b), ← Nat.mul_assoc]
            exact Nat.mul_lt_mul_of_pos_right (by omega) hpos_p
          exact ⟨(-1)#i32, rfl, ⟨fun _ => hlt_rat, fun _ => rfl⟩,
            ⟨fun h => absurd h (by decide), fun h => by omega⟩,
            ⟨fun h => absurd h (by decide), fun h => by omega⟩⟩
        | inr st =>
          rcases st with ⟨_, b_lo2, b_hi2⟩
          have hcmp := cmp_val96_inline a.lo64 a.hi b_lo2 b_hi2
          rw [hpost] at hcmp
          refine ⟨_, rfl, ?_, ?_, ?_⟩
          · rw [hcmp.1, hpow_rel, Nat.mul_comm (10 ^ dec_scale b), ← Nat.mul_assoc]
            exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_p, fun h => Nat.lt_of_mul_lt_mul_right h⟩
          · rw [hcmp.2.1, hpow_rel, Nat.mul_comm (10 ^ dec_scale b), ← Nat.mul_assoc]
            exact ⟨fun h => congrArg (· * 10 ^ dec_scale b) h, fun h => Nat.eq_of_mul_eq_mul_right hpos_p h⟩
          · rw [hcmp.2.2, hpow_rel, Nat.mul_comm (10 ^ dec_scale b), ← Nat.mul_assoc]
            exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_p, fun h => Nat.lt_of_mul_lt_mul_right h⟩
    · rw [if_neg hgt]
      have hs2_gt : dec_scale a < dec_scale b := by
        have h1 : ¬(s2.val < s1.val) := hgt
        have h2 : s1.val ≠ s2.val := fun he => hne (IScalar.eq_of_val_eq he)
        omega
      have hpow_rel : 10 ^ dec_scale b = 10 ^ dec_scale a * 10 ^ (dec_scale b - dec_scale a) := by
        rw [← Nat.pow_add, show dec_scale a + (dec_scale b - dec_scale a) = dec_scale b by omega]
      have hpos_p : 0 < 10 ^ dec_scale a := Nat.pos_of_ne_zero (by positivity)
      set diff := Pion.I32.sub s2 s1
      have hdiff : diff.val = (dec_scale b : Int) - (dec_scale a : Int) := by
        dsimp only [diff]
        rw [i32_sub_val (by omega) (by omega)]
        omega
      by_cases hfast : ((a.hi == 0#u32) && decide (diff <= 19#i32)) = true
      · rw [if_pos hfast]
        simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hfast
        have hdiff19 : diff.val ≤ 19 := by
          have : diff.val ≤ (19#i32 : Std.I32).val := hfast.2
          have hv : (19#i32 : Std.I32).val = 19 := by decide
          omega
        obtain ⟨p64, hp64, hp64v⟩ := pow10_u64_spec diff (by omega) hdiff19
        obtain ⟨nl, nh, hmul, hmulv⟩ := u64_mul_wide_spec a.lo64 p64
        rw [hp64, b_ok, hmul, b_ok]
        have hA_eq : nl.val + 2 ^ 64 * nh.val = dec_mag a * 10 ^ (dec_scale b - dec_scale a) := by
          rw [hmulv, hp64v, show diff.val.toNat = dec_scale b - dec_scale a by omega]
          unfold dec_mag val96; rw [hfast.1]; simp
        by_cases hov : nh > 4294967295#u64
        · have hnh : nh.val ≥ 2 ^ 32 := by
            have : (4294967295#u64 : Std.U64).val < nh.val := hov
            have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
            omega
          have hgt_mag : dec_mag b < dec_mag a * 10 ^ (dec_scale b - dec_scale a) := by omega
          have hgt_rat : dec_mag b * 10 ^ dec_scale a < dec_mag a * 10 ^ dec_scale b := by
            rw [hpow_rel, Nat.mul_comm (10 ^ dec_scale a), ← Nat.mul_assoc]
            exact Nat.mul_lt_mul_of_pos_right hgt_mag hpos_p
          exact ⟨1#i32, by
            change (if nh > 4294967295#u64 then _ else _) = _
            rw [if_pos hov], ⟨fun h => absurd h (by decide), fun h => by omega⟩,
            ⟨fun h => absurd h (by decide), fun h => by omega⟩,
            ⟨fun _ => hgt_rat, fun _ => rfl⟩⟩
        · have hnh : nh.val < 2 ^ 32 := by
            have : ¬((4294967295#u64 : Std.U64).val < nh.val) := hov
            have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
            omega
          have hval_a : val96 nl (Pion.U64.to_uint nh) = dec_mag a * 10 ^ (dec_scale b - dec_scale a) := by
            unfold val96; rw [u64_to_uint_val, Nat.mod_eq_of_lt hnh]; exact hA_eq
          have hcmp := cmp_val96_inline nl (Pion.U64.to_uint nh) b.lo64 b.hi
          rw [hval_a] at hcmp
          refine ⟨_, by
            change (if nh > 4294967295#u64 then _ else _) = _
            rw [if_neg hov], ?_, ?_, ?_⟩
          · rw [hcmp.1, hpow_rel, Nat.mul_comm (10 ^ dec_scale a), ← Nat.mul_assoc]
            exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_p, fun h => Nat.lt_of_mul_lt_mul_right h⟩
          · rw [hcmp.2.1, hpow_rel, Nat.mul_comm (10 ^ dec_scale a), ← Nat.mul_assoc]
            exact ⟨fun h => congrArg (· * 10 ^ dec_scale a) h, fun h => Nat.eq_of_mul_eq_mul_right hpos_p h⟩
          · rw [hcmp.2.2, hpow_rel, Nat.mul_comm (10 ^ dec_scale a), ← Nat.mul_assoc]
            exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_p, fun h => Nat.lt_of_mul_lt_mul_right h⟩
      · rw [if_neg hfast]
        have hloop := cmp_magnitude_loop1_spec diff a.lo64 a.hi (by omega) (by omega)
          (dec_mag a * 10 ^ (dec_scale b - dec_scale a))
          (by unfold dec_mag; rw [show diff.val.toNat = dec_scale b - dec_scale a by omega])
        rw [wp_ok_iff] at hloop
        obtain ⟨res, hres, hpost⟩ := hloop
        rw [hres, b_ok]
        cases res with
        | inl r =>
          obtain ⟨hr, hge96⟩ := hpost
          subst hr
          have hgt_rat : dec_mag b * 10 ^ dec_scale a < dec_mag a * 10 ^ dec_scale b := by
            rw [hpow_rel, Nat.mul_comm (10 ^ dec_scale a), ← Nat.mul_assoc]
            exact Nat.mul_lt_mul_of_pos_right (by omega) hpos_p
          exact ⟨1#i32, rfl, ⟨fun h => absurd h (by decide), fun h => by omega⟩,
            ⟨fun h => absurd h (by decide), fun h => by omega⟩,
            ⟨fun _ => hgt_rat, fun _ => rfl⟩⟩
        | inr st =>
          rcases st with ⟨_, a_lo2, a_hi2⟩
          have hcmp := cmp_val96_inline a_lo2 a_hi2 b.lo64 b.hi
          rw [hpost] at hcmp
          refine ⟨_, rfl, ?_, ?_, ?_⟩
          · rw [hcmp.1, hpow_rel, Nat.mul_comm (10 ^ dec_scale a), ← Nat.mul_assoc]
            exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_p, fun h => Nat.lt_of_mul_lt_mul_right h⟩
          · rw [hcmp.2.1, hpow_rel, Nat.mul_comm (10 ^ dec_scale a), ← Nat.mul_assoc]
            exact ⟨fun h => congrArg (· * 10 ^ dec_scale a) h, fun h => Nat.eq_of_mul_eq_mul_right hpos_p h⟩
          · rw [hcmp.2.2, hpow_rel, Nat.mul_comm (10 ^ dec_scale a), ← Nat.mul_assoc]
            exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_p, fun h => Nat.lt_of_mul_lt_mul_right h⟩
  · rw [if_neg hne]
    have hseq : dec_scale a = dec_scale b := by
      have : s1 = s2 := Classical.not_not.mp hne
      have : s1.val = s2.val := congrArg IScalar.val this
      omega
    have hpos_p : 0 < 10 ^ dec_scale b := Nat.pos_of_ne_zero (by positivity)
    have hcmp := cmp_val96_inline a.lo64 a.hi b.lo64 b.hi
    refine ⟨_, rfl, ?_, ?_, ?_⟩
    · rw [hcmp.1, hseq]
      exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_p, fun h => Nat.lt_of_mul_lt_mul_right h⟩
    · rw [hcmp.2.1, hseq]
      exact ⟨fun h => congrArg (· * 10 ^ dec_scale b) h, fun h => Nat.eq_of_mul_eq_mul_right hpos_p h⟩
    · rw [hcmp.2.2, hseq]
      exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_p, fun h => Nat.lt_of_mul_lt_mul_right h⟩

/-- Master theorem for `Decimal::compare`:
    For ANY two valid `Decimal` values `a, b` (arbitrary signs and scales `0..=28`),
    `Decimal.compare a b` never traps and matches exact rational ordering (`dec_lt_rat` / `dec_eq_rat`),
    automatically equating `-0 == +0` at all scales. -/
theorem Decimal.compare_spec (a b : Decimal) (ha : valid_decimal a) (hb : valid_decimal b) :
    ∃ r : Std.I32, Decimal.compare a b = ok r ∧
      (r = (-1)#i32 ↔ dec_lt_rat a b) ∧
      (r = 0#i32 ↔ dec_eq_rat a b) ∧
      (r = 1#i32 ↔ dec_lt_rat b a) := by
  unfold Decimal.compare
  have hz1 : ((a.lo64 == 0#u64) && (a.hi == 0#u32)) = decide (dec_mag a = 0) := by
    have h := Decimal.is_zero_spec a; unfold Decimal.is_zero at h; exact ok_inj h
  have hz2 : ((b.lo64 == 0#u64) && (b.hi == 0#u32)) = decide (dec_mag b = 0) := by
    have h := Decimal.is_zero_spec b; unfold Decimal.is_zero at h; exact ok_inj h
  have hpa : (0 : Int) < 10 ^ dec_scale a := by positivity
  have hpb : (0 : Int) < 10 ^ dec_scale b := by positivity
  by_cases hbz : dec_mag b = 0
  · have hbz_t : ((b.lo64 == 0#u64) && (b.hi == 0#u32)) = true := by rw [hz2, decide_eq_true hbz]
    simp only [hbz_t, ↓reduceIte]
    have hbv : dec_signed_val b = 0 := by unfold dec_signed_val; rw [hbz]; simp
    by_cases haz : dec_mag a = 0
    · have haz_t : ((a.lo64 == 0#u64) && (a.hi == 0#u32)) = true := by rw [hz1, decide_eq_true haz]
      simp only [haz_t, ↓reduceIte]
      have hav : dec_signed_val a = 0 := by unfold dec_signed_val; rw [haz]; simp
      exact ⟨0#i32, rfl,
        ⟨fun h => absurd h (by decide), fun h => by unfold dec_lt_rat at h; rw [hav, hbv] at h; omega⟩,
        ⟨fun _ => by unfold dec_eq_rat; rw [hav, hbv]; simp, fun _ => rfl⟩,
        ⟨fun h => absurd h (by decide), fun h => by unfold dec_lt_rat at h; rw [hav, hbv] at h; omega⟩⟩
    · have haz_f : ((a.lo64 == 0#u64) && (a.hi == 0#u32)) = false := by rw [hz1, decide_eq_false haz]
      simp only [haz_f, Bool.false_eq_true, ↓reduceIte]
      rw [Decimal.is_sign_negative_spec, b_ok]
      cases hna : dec_neg a
      · simp only [Bool.false_eq_true, ↓reduceIte]
        have hav : dec_signed_val a > 0 := by unfold dec_signed_val; rw [hna]; simp; omega
        have hgt : dec_lt_rat b a := by unfold dec_lt_rat; rw [hbv]; nlinarith
        exact ⟨1#i32, rfl, ⟨fun h => absurd h (by decide), fun h => by unfold dec_lt_rat at h; rw [hbv] at h; nlinarith⟩,
          ⟨fun h => absurd h (by decide), fun h => by unfold dec_eq_rat at h; rw [hbv] at h; nlinarith⟩,
          ⟨fun _ => hgt, fun _ => rfl⟩⟩
      · simp only [↓reduceIte]
        have hav : dec_signed_val a < 0 := by unfold dec_signed_val; rw [hna]; simp; omega
        have hlt : dec_lt_rat a b := by unfold dec_lt_rat; rw [hbv]; nlinarith
        exact ⟨(-1)#i32, rfl, ⟨fun _ => hlt, fun _ => rfl⟩,
          ⟨fun h => absurd h (by decide), fun h => by unfold dec_eq_rat at h; rw [hbv] at h; nlinarith⟩,
          ⟨fun h => absurd h (by decide), fun h => by unfold dec_lt_rat at h; rw [hbv] at h; nlinarith⟩⟩
  · have hbz_f : ((b.lo64 == 0#u64) && (b.hi == 0#u32)) = false := by rw [hz2, decide_eq_false hbz]
    simp only [hbz_f, Bool.false_eq_true, ↓reduceIte]
    by_cases haz : dec_mag a = 0
    · have haz_t : ((a.lo64 == 0#u64) && (a.hi == 0#u32)) = true := by rw [hz1, decide_eq_true haz]
      simp only [haz_t, ↓reduceIte, Decimal.is_sign_negative_spec, b_ok]
      have hav : dec_signed_val a = 0 := by unfold dec_signed_val; rw [haz]; simp
      cases hnb : dec_neg b
      · simp only [Bool.false_eq_true, ↓reduceIte]
        have hbv : dec_signed_val b > 0 := by unfold dec_signed_val; rw [hnb]; simp; omega
        have hlt : dec_lt_rat a b := by unfold dec_lt_rat; rw [hav]; nlinarith
        exact ⟨(-1)#i32, rfl, ⟨fun _ => hlt, fun _ => rfl⟩,
          ⟨fun h => absurd h (by decide), fun h => by unfold dec_eq_rat at h; rw [hav] at h; nlinarith⟩,
          ⟨fun h => absurd h (by decide), fun h => by unfold dec_lt_rat at h; rw [hav] at h; nlinarith⟩⟩
      · simp only [↓reduceIte]
        have hbv : dec_signed_val b < 0 := by unfold dec_signed_val; rw [hnb]; simp; omega
        have hgt : dec_lt_rat b a := by unfold dec_lt_rat; rw [hav]; nlinarith
        exact ⟨1#i32, rfl, ⟨fun h => absurd h (by decide), fun h => by unfold dec_lt_rat at h; rw [hav] at h; nlinarith⟩,
          ⟨fun h => absurd h (by decide), fun h => by unfold dec_eq_rat at h; rw [hav] at h; nlinarith⟩,
          ⟨fun _ => hgt, fun _ => rfl⟩⟩
    · have haz_f : ((a.lo64 == 0#u64) && (a.hi == 0#u32)) = false := by rw [hz1, decide_eq_false haz]
      simp only [haz_f, Bool.false_eq_true, ↓reduceIte]
      rw [Decimal.is_sign_negative_spec, b_ok, Decimal.is_sign_negative_spec, b_ok]
      by_cases hsn : dec_neg a ≠ dec_neg b
      · rw [if_pos hsn]
        cases hna : dec_neg a
        · have hnb : dec_neg b = true := by cases h : dec_neg b <;> simp_all
          simp only [Bool.false_eq_true, ↓reduceIte]
          have hav : dec_signed_val a > 0 := by unfold dec_signed_val; rw [hna]; simp; omega
          have hbv : dec_signed_val b < 0 := by unfold dec_signed_val; rw [hnb]; simp; omega
          have hgt : dec_lt_rat b a := by unfold dec_lt_rat; nlinarith
          exact ⟨1#i32, rfl, ⟨fun h => absurd h (by decide), fun h => by unfold dec_lt_rat at h; nlinarith⟩,
            ⟨fun h => absurd h (by decide), fun h => by unfold dec_eq_rat at h; nlinarith⟩,
            ⟨fun _ => hgt, fun _ => rfl⟩⟩
        · have hnb : dec_neg b = false := by cases h : dec_neg b <;> simp_all
          simp only [↓reduceIte]
          have hav : dec_signed_val a < 0 := by unfold dec_signed_val; rw [hna]; simp; omega
          have hbv : dec_signed_val b > 0 := by unfold dec_signed_val; rw [hnb]; simp; omega
          have hlt : dec_lt_rat a b := by unfold dec_lt_rat; nlinarith
          exact ⟨(-1)#i32, rfl, ⟨fun _ => hlt, fun _ => rfl⟩,
            ⟨fun h => absurd h (by decide), fun h => by unfold dec_eq_rat at h; nlinarith⟩,
            ⟨fun h => absurd h (by decide), fun h => by unfold dec_lt_rat at h; nlinarith⟩⟩
      · rw [if_neg hsn]
        have hsneq : dec_neg a = dec_neg b := Classical.not_not.mp hsn
        -- Both branches (same flags fast path vs general cmp_magnitude) compute `mag` matching cross-multiplied magnitude
        have hmag_goal : ∀ mag : Std.I32,
            (mag = (-1)#i32 ↔ dec_mag a * 10 ^ dec_scale b < dec_mag b * 10 ^ dec_scale a) →
            (mag = 0#i32 ↔ dec_mag a * 10 ^ dec_scale b = dec_mag b * 10 ^ dec_scale a) →
            (mag = 1#i32 ↔ dec_mag a * 10 ^ dec_scale b > dec_mag b * 10 ^ dec_scale a) →
            let r := if dec_neg a = true then Pion.I32.neg mag else mag
            (r = (-1)#i32 ↔ dec_lt_rat a b) ∧
            (r = 0#i32 ↔ dec_eq_rat a b) ∧
            (r = 1#i32 ↔ dec_lt_rat b a) := by
          intro mag hltm heqm hgtm
          dsimp only
          cases hna : dec_neg a
          · simp only [Bool.false_eq_true, ↓reduceIte]
            have hnb : dec_neg b = false := by rw [← hsneq, hna]
            unfold dec_lt_rat dec_eq_rat dec_signed_val
            simp only [hna, hnb, Bool.false_eq_true, ↓reduceIte]
            exact ⟨by rw [hltm]; exact_mod_cast Iff.rfl,
                   by rw [heqm]; exact_mod_cast Iff.rfl,
                   by rw [hgtm]; exact_mod_cast Iff.rfl⟩
          · simp only [↓reduceIte]
            have hnb : dec_neg b = true := by rw [← hsneq, hna]
            unfold dec_lt_rat dec_eq_rat dec_signed_val
            simp only [hna, hnb, ↓reduceIte]
            have htri : mag = (-1)#i32 ∨ mag = 0#i32 ∨ mag = 1#i32 := by
              rcases lt_trichotomy (dec_mag a * 10 ^ dec_scale b) (dec_mag b * 10 ^ dec_scale a) with h | h | h
              · exact Or.inl (hltm.mpr h)
              · exact Or.inr (Or.inl (heqm.mpr h))
              · exact Or.inr (Or.inr (hgtm.mpr h))
            rcases htri with rfl | rfl | rfl
            · have h : (dec_mag a : Int) * (10 : Int) ^ dec_scale b < (dec_mag b : Int) * (10 : Int) ^ dec_scale a := by
                exact_mod_cast (hltm.mp rfl)
              have hneg : Pion.I32.neg (-1)#i32 = 1#i32 := by decide
              rw [hneg]
              exact ⟨⟨fun h => absurd h (by decide), fun h' => by linarith⟩,
                     ⟨fun h => absurd h (by decide), fun h' => by linarith⟩,
                     ⟨fun _ => by linarith, fun _ => rfl⟩⟩
            · have h : (dec_mag a : Int) * (10 : Int) ^ dec_scale b = (dec_mag b : Int) * (10 : Int) ^ dec_scale a := by
                exact_mod_cast (heqm.mp rfl)
              have hneg : Pion.I32.neg 0#i32 = 0#i32 := by decide
              rw [hneg]
              exact ⟨⟨fun h => absurd h (by decide), fun h' => by linarith⟩,
                     ⟨fun _ => by linarith, fun _ => rfl⟩,
                     ⟨fun h => absurd h (by decide), fun h' => by linarith⟩⟩
            · have h : (dec_mag b : Int) * (10 : Int) ^ dec_scale a < (dec_mag a : Int) * (10 : Int) ^ dec_scale b := by
                exact_mod_cast (hgtm.mp rfl)
              have hneg : Pion.I32.neg 1#i32 = (-1)#i32 := by decide
              rw [hneg]
              exact ⟨⟨fun _ => by linarith, fun _ => rfl⟩,
                     ⟨fun h => absurd h (by decide), fun h' => by linarith⟩,
                     ⟨fun h => absurd h (by decide), fun h' => by linarith⟩⟩
        by_cases hfl : a.flags = b.flags
        · simp only [hfl, ↓reduceIte]
          have hseq : dec_scale a = dec_scale b := by unfold dec_scale; rw [hfl]
          have hpos_n : 0 < 10 ^ dec_scale b := Nat.pos_of_ne_zero (by positivity)
          have hcmp := cmp_val96_inline a.lo64 a.hi b.lo64 b.hi
          refine ⟨_, rfl, hmag_goal _ ?_ ?_ ?_⟩
          · rw [hcmp.1, hseq]; exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_n, fun h => Nat.lt_of_mul_lt_mul_right h⟩
          · rw [hcmp.2.1, hseq]; exact ⟨fun h => congrArg (· * 10 ^ dec_scale b) h, fun h => Nat.eq_of_mul_eq_mul_right hpos_n h⟩
          · rw [hcmp.2.2, hseq]; exact ⟨fun h => Nat.mul_lt_mul_of_pos_right h hpos_n, fun h => Nat.lt_of_mul_lt_mul_right h⟩
        · simp only [hfl, ↓reduceIte]
          obtain ⟨mag, hmag, hltm, heqm, hgtm⟩ := cmp_magnitude_spec a b ha hb
          rw [hmag, b_ok]
          exact ⟨_, rfl, hmag_goal mag hltm heqm hgtm⟩

/-- `-0 == +0` at all scales: any two zero `Decimal`s compare equal (`0`). -/
theorem Decimal.compare_neg_zero_eq_pos_zero (a b : Decimal)
    (ha : valid_decimal a) (hb : valid_decimal b)
    (hza : dec_mag a = 0) (hzb : dec_mag b = 0) :
    Decimal.compare a b = ok 0#i32 := by
  obtain ⟨r, hr, _, heq, _⟩ := Decimal.compare_spec a b ha hb
  rw [hr]
  have : dec_eq_rat a b := by
    unfold dec_eq_rat dec_signed_val; rw [hza, hzb]; simp
  rw [heq.mpr this]

theorem Decimal.compare_refl (a : Decimal) (ha : valid_decimal a) :
    Decimal.compare a a = ok 0#i32 := by
  obtain ⟨r, hr, _, heq, _⟩ := Decimal.compare_spec a a ha ha
  rw [hr, heq.mpr rfl]

theorem Decimal.compare_antisymm (a b : Decimal) (ha : valid_decimal a) (hb : valid_decimal b)
    {r : Std.I32} (h : Decimal.compare a b = ok r) :
    Decimal.compare b a = ok (Pion.I32.neg r) := by
  obtain ⟨r1, hr1, hlt1, heq1, hgt1⟩ := Decimal.compare_spec a b ha hb
  obtain ⟨r2, hr2, hlt2, heq2, hgt2⟩ := Decimal.compare_spec b a hb ha
  rw [hr1] at h; have hr := ok_inj h; subst hr
  rcases lt_trichotomy (dec_signed_val a * (10 ^ dec_scale b : Int))
      (dec_signed_val b * (10 ^ dec_scale a : Int)) with hlt | heq | hgt
  · rw [hr2, hlt1.mpr hlt, hgt2.mpr hlt]; rfl
  · rw [hr2, heq1.mpr heq, heq2.mpr heq.symm]; rfl
  · rw [hr2, hgt1.mpr hgt, hlt2.mpr hgt]; rfl

theorem Decimal.compare_trans_lt (a b c : Decimal)
    (ha : valid_decimal a) (hb : valid_decimal b) (hc : valid_decimal c)
    (hab : Decimal.compare a b = ok (-1)#i32)
    (hbc : Decimal.compare b c = ok (-1)#i32) :
    Decimal.compare a c = ok (-1)#i32 := by
  obtain ⟨r1, hr1, hlt1, _, _⟩ := Decimal.compare_spec a b ha hb
  obtain ⟨r2, hr2, hlt2, _, _⟩ := Decimal.compare_spec b c hb hc
  obtain ⟨r3, hr3, hlt3, _, _⟩ := Decimal.compare_spec a c ha hc
  rw [hr1] at hab; have h1 := hlt1.mp (ok_inj hab)
  rw [hr2] at hbc; have h2 := hlt2.mp (ok_inj hbc)
  unfold dec_lt_rat at h1 h2
  have hpa : (0 : Int) < 10 ^ dec_scale a := by positivity
  have hpb : (0 : Int) < 10 ^ dec_scale b := by positivity
  have hpc : (0 : Int) < 10 ^ dec_scale c := by positivity
  have h3 : dec_lt_rat a c := by
    unfold dec_lt_rat
    have hmul : (dec_signed_val a * (10 ^ dec_scale c : Int)) * (10 ^ dec_scale b : Int) <
        (dec_signed_val c * (10 ^ dec_scale a : Int)) * (10 ^ dec_scale b : Int) := by
      have m1 : dec_signed_val a * (10 ^ dec_scale b : Int) * (10 ^ dec_scale c : Int) <
          dec_signed_val b * (10 ^ dec_scale a : Int) * (10 ^ dec_scale c : Int) :=
        Int.mul_lt_mul_of_pos_right h1 hpc
      have m2 : dec_signed_val b * (10 ^ dec_scale c : Int) * (10 ^ dec_scale a : Int) <
          dec_signed_val c * (10 ^ dec_scale b : Int) * (10 ^ dec_scale a : Int) :=
        Int.mul_lt_mul_of_pos_right h2 hpa
      linarith
    exact lt_of_mul_lt_mul_right hmul (by omega)
  rw [hr3, hlt3.mpr h3]

theorem Decimal.eq_spec (a b : Decimal) (ha : valid_decimal a) (hb : valid_decimal b) :
    ∃ r : Bool, Decimal.eq a b = ok r ∧ (r = true ↔ dec_eq_rat a b) := by
  unfold Decimal.eq
  obtain ⟨c, hc, _, heq, _⟩ := Decimal.compare_spec a b ha hb
  rw [hc, b_ok]
  exact ⟨c == 0#i32, rfl, by simp [beq_iff_eq, heq]⟩

theorem Decimal.lt_spec (a b : Decimal) (ha : valid_decimal a) (hb : valid_decimal b) :
    ∃ r : Bool, Decimal.lt a b = ok r ∧ (r = true ↔ dec_lt_rat a b) := by
  unfold Decimal.lt
  obtain ⟨c, hc, hlt, heq, hgt⟩ := Decimal.compare_spec a b ha hb
  rw [hc, b_ok]
  refine ⟨decide (c < 0#i32), rfl, ?_⟩
  rw [decide_eq_true_eq]
  rcases lt_trichotomy (dec_signed_val a * (10 ^ dec_scale b : Int))
      (dec_signed_val b * (10 ^ dec_scale a : Int)) with h | h | h
  · rw [hlt.mpr h]; exact ⟨fun _ => h, fun _ => by decide⟩
  · rw [heq.mpr h]; exact ⟨fun hc0 => absurd hc0 (by decide), fun hlt' => by unfold dec_lt_rat at hlt'; omega⟩
  · rw [hgt.mpr h]; exact ⟨fun hc0 => absurd hc0 (by decide), fun hlt' => by unfold dec_lt_rat at hlt'; omega⟩

theorem Decimal.le_spec (a b : Decimal) (ha : valid_decimal a) (hb : valid_decimal b) :
    ∃ r : Bool, Decimal.le a b = ok r ∧ (r = true ↔ dec_lt_rat a b ∨ dec_eq_rat a b) := by
  unfold Decimal.le
  obtain ⟨c, hc, hlt, heq, hgt⟩ := Decimal.compare_spec a b ha hb
  rw [hc, b_ok]
  refine ⟨decide (c <= 0#i32), rfl, ?_⟩
  rw [decide_eq_true_eq]
  rcases lt_trichotomy (dec_signed_val a * (10 ^ dec_scale b : Int))
      (dec_signed_val b * (10 ^ dec_scale a : Int)) with h | h | h
  · rw [hlt.mpr h]; exact ⟨fun _ => Or.inl h, fun _ => by decide⟩
  · rw [heq.mpr h]; exact ⟨fun _ => Or.inr h, fun _ => by decide⟩
  · rw [hgt.mpr h]
    exact ⟨fun hc0 => absurd hc0 (by decide), fun hor => by
      rcases hor with h1 | h2 <;> (unfold dec_lt_rat dec_eq_rat at *; omega)⟩

/-- Loop specification for `truncate_core_loop0`: exact 96-bit division by `10^drop` with sticky flag. -/
private theorem truncate_core_loop0_spec (drop : Std.I32) (q2 q1 q0 : Std.U32) (had_rem : Bool)
    (hd0 : 0 ≤ drop.val) (hd28 : drop.val ≤ 28) :
    truncate_core_loop0 drop q2 q1 q0 had_rem ⦃ res =>
      val96_parts res.2.2.2.1 res.2.2.1 res.2.1 =
        val96_parts q0 q1 q2 / 10 ^ drop.val.toNat ∧
      res.2.2.2.2 = (had_rem || decide (val96_parts q0 q1 q2 % 10 ^ drop.val.toNat ≠ 0)) ⦄ := by
  unfold truncate_core_loop0
  set orig := val96_parts q0 q1 q2
  set total := drop.val.toNat
  apply loop.spec_decr_nat
    (measure := fun (d, _, _, _, _) => d.val.toNat)
    (inv := fun (d, w2, w1, w0, hr) =>
      0 ≤ d.val ∧ d.val ≤ 28 ∧ d.val.toNat ≤ total ∧
      val96_parts w0 w1 w2 = orig / 10 ^ (total - d.val.toNat) ∧
      hr = (had_rem || decide (orig % 10 ^ (total - d.val.toNat) ≠ 0)))
  · rintro ⟨d, w2, w1, w0, hr⟩ ⟨h0, h28, hle_tot, hq_inv, hr_inv⟩
    unfold truncate_core_loop0.body
    by_cases hpos : d > 0#i32
    · have hdpos : 0 < d.val := by have : (0#i32 : Std.I32).val < d.val := hpos; exact this
      simp only [hpos, ↓reduceIte]
      set step : Std.I32 := if d > 9#i32 then 9#i32 else d
      have hstep : 1 ≤ step.val ∧ step.val ≤ 9 ∧ step.val ≤ d.val := by
        simp only [step]
        by_cases h9 : d > 9#i32
        · rw [if_pos h9]
          have : (9#i32 : Std.I32).val < d.val := h9
          have hv : (9#i32 : Std.I32).val = 9 := by decide
          omega
        · rw [if_neg h9]
          have : ¬((9#i32 : Std.I32).val < d.val) := h9
          have hv : (9#i32 : Std.I32).val = 9 := by decide
          omega
      obtain ⟨p32, hp32, hp32v⟩ := pow10_u32_spec step (by omega) (by omega)
      rw [hp32, b_ok]
      set div64 := Pion.U32.to_uint64 p32
      have hdiv_v : div64.val = 10 ^ step.val.toNat := by rw [u32_to_uint64_val, hp32v]
      have hdiv_pos : 0 < div64.val := by rw [hdiv_v]; exact Nat.pos_of_ne_zero (by positivity)
      have hdiv_le : div64.val ≤ 10 ^ 9 := by
        rw [hdiv_v]; exact Nat.pow_le_pow_right (by omega) (by omega)
      have hw0 := u32_val_lt w0; have hw1 := u32_val_lt w1; have hw2 := u32_val_lt w2
      obtain ⟨n2, hn2, hn2v⟩ := u64_div_ok (b := div64) (Pion.U32.to_uint64 w2) (by omega)
      rw [hn2, b_ok]
      have hn2v' : n2.val = w2.val / div64.val := by rw [hn2v, u32_to_uint64_val]
      have hr2v : (Pion.U64.sub (Pion.U32.to_uint64 w2) (Pion.U64.mul n2 div64)).val = w2.val % div64.val := by
        have hmul : (Pion.U64.mul n2 div64).val = n2.val * div64.val := by
          rw [u64_mul_val, Nat.mod_eq_of_lt (by rw [hn2v']; have := Nat.div_mul_le_self w2.val div64.val; omega)]
        rw [u64_sub_val (by rw [hmul, hn2v', u32_to_uint64_val]; exact Nat.div_mul_le_self _ _),
          u32_to_uint64_val, hmul, hn2v']
        have hdm := Nat.div_add_mod w2.val div64.val
        have hle := Nat.div_mul_le_self w2.val div64.val
        have hcomm : w2.val / div64.val * div64.val = div64.val * (w2.val / div64.val) := Nat.mul_comm _ _
        omega
      obtain ⟨t10, ht10, ht10v⟩ := u64_shl32_ok _
      rw [ht10, b_ok]
      have ht10v' : t10.val = (w2.val % div64.val) * 2 ^ 32 := by
        rw [ht10v, hr2v, Nat.mod_eq_of_lt (by have := Nat.mod_lt w2.val hdiv_pos; omega)]
      set c1 := Pion.U64.bor t10 (Pion.U32.to_uint64 w1)
      have hc1 : c1.val = (w2.val % div64.val) * 2 ^ 32 + w1.val := by
        have h1 : (Pion.U32.to_uint64 w1).val < 2 ^ 32 := by rw [u32_to_uint64_val]; exact hw1
        have h2 : t10.val % 2 ^ 32 = 0 := by rw [ht10v']; exact Nat.mul_mod_left _ _
        have hcomm : Pion.U64.bor t10 (Pion.U32.to_uint64 w1) = Pion.U64.bor (Pion.U32.to_uint64 w1) t10 := by
          apply u64_eq_of_bv_eq; exact BitVec.or_comm _ _
        rw [show c1 = Pion.U64.bor (Pion.U32.to_uint64 w1) t10 from hcomm,
          u64_bor_disjoint_32 h1 h2, u32_to_uint64_val, ht10v']; omega
      obtain ⟨n1, hn1, hn1v⟩ := u64_div_ok (b := div64) c1 (by omega)
      rw [hn1, b_ok]
      have hn1_lt : n1.val < 2 ^ 32 := by
        rw [hn1v]; have := Nat.mod_lt w2.val hdiv_pos
        have : c1.val < div64.val * 2 ^ 32 := by nlinarith
        exact Nat.div_lt_of_lt_mul (by linarith)
      have hr1v : (Pion.U64.sub c1 (Pion.U64.mul n1 div64)).val = c1.val % div64.val := by
        have hmul : (Pion.U64.mul n1 div64).val = n1.val * div64.val := by
          rw [u64_mul_val, Nat.mod_eq_of_lt (by rw [hn1v]; have := Nat.div_mul_le_self c1.val div64.val; have := u64_val_lt c1; omega)]
        rw [u64_sub_val (by rw [hmul, hn1v]; exact Nat.div_mul_le_self _ _), hmul, hn1v]
        have hdm := Nat.div_add_mod c1.val div64.val
        have hle := Nat.div_mul_le_self c1.val div64.val
        have hcomm : c1.val / div64.val * div64.val = div64.val * (c1.val / div64.val) := Nat.mul_comm _ _
        omega
      obtain ⟨t12, ht12, ht12v⟩ := u64_shl32_ok _
      rw [ht12, b_ok]
      have ht12v' : t12.val = (c1.val % div64.val) * 2 ^ 32 := by
        rw [ht12v, hr1v, Nat.mod_eq_of_lt (by have := Nat.mod_lt c1.val hdiv_pos; omega)]
      set c0 := Pion.U64.bor t12 (Pion.U32.to_uint64 w0)
      have hc0 : c0.val = (c1.val % div64.val) * 2 ^ 32 + w0.val := by
        have h1 : (Pion.U32.to_uint64 w0).val < 2 ^ 32 := by rw [u32_to_uint64_val]; exact hw0
        have h2 : t12.val % 2 ^ 32 = 0 := by rw [ht12v']; exact Nat.mul_mod_left _ _
        have hcomm : Pion.U64.bor t12 (Pion.U32.to_uint64 w0) = Pion.U64.bor (Pion.U32.to_uint64 w0) t12 := by
          apply u64_eq_of_bv_eq; exact BitVec.or_comm _ _
        rw [show c0 = Pion.U64.bor (Pion.U32.to_uint64 w0) t12 from hcomm,
          u64_bor_disjoint_32 h1 h2, u32_to_uint64_val, ht12v']; omega
      obtain ⟨n0, hn0, hn0v⟩ := u64_div_ok (b := div64) c0 (by omega)
      rw [hn0, b_ok]
      have hn0_lt : n0.val < 2 ^ 32 := by
        rw [hn0v]; have := Nat.mod_lt c1.val hdiv_pos
        have : c0.val < div64.val * 2 ^ 32 := by nlinarith
        exact Nat.div_lt_of_lt_mul (by linarith)
      set r0 := Pion.U64.sub c0 (Pion.U64.mul n0 div64)
      have hr0v : r0.val = c0.val % div64.val := by
        have hmul : (Pion.U64.mul n0 div64).val = n0.val * div64.val := by
          rw [u64_mul_val, Nat.mod_eq_of_lt (by rw [hn0v]; have := Nat.div_mul_le_self c0.val div64.val; have := u64_val_lt c0; omega)]
        rw [u64_sub_val (by rw [hmul, hn0v]; exact Nat.div_mul_le_self _ _), hmul, hn0v]
        have hdm := Nat.div_add_mod c0.val div64.val
        have hle := Nat.div_mul_le_self c0.val div64.val
        have hcomm : c0.val / div64.val * div64.val = div64.val * (c0.val / div64.val) := Nat.mul_comm _ _
        omega
      -- Core 3-limb Euclidean division identity:
      -- val96_parts w0 w1 w2 = val96_parts (to_uint n0) (to_uint n1) (to_uint n2) * div64 + r0
      have hdiv_ident : val96_parts w0 w1 w2 =
          val96_parts (Pion.U64.to_uint n0) (Pion.U64.to_uint n1) (Pion.U64.to_uint n2) * div64.val + r0.val := by
        unfold val96_parts
        rw [u64_to_uint_val, u64_to_uint_val, u64_to_uint_val,
          Nat.mod_eq_of_lt hn0_lt, Nat.mod_eq_of_lt hn1_lt,
          Nat.mod_eq_of_lt (by rw [hn2v']; exact Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hw2)]
        have h2d := Nat.div_add_mod w2.val div64.val
        have h1d := Nat.div_add_mod c1.val div64.val
        have h0d := Nat.div_add_mod c0.val div64.val
        rw [hn0v, hn1v, hn2v', hr0v]
        nlinarith
      have hr0_lt : r0.val < div64.val := by rw [hr0v]; exact Nat.mod_lt _ hdiv_pos
      have hq_step : val96_parts (Pion.U64.to_uint n0) (Pion.U64.to_uint n1) (Pion.U64.to_uint n2) =
          val96_parts w0 w1 w2 / div64.val := by
        rw [hdiv_ident, Nat.mul_comm _ div64.val, Nat.mul_add_div hdiv_pos, Nat.div_eq_of_lt hr0_lt, Nat.add_zero]
      have hr_step : val96_parts w0 w1 w2 % div64.val = r0.val := by
        rw [hdiv_ident, Nat.mul_comm _ div64.val, Nat.mul_add_mod, Nat.mod_eq_of_lt hr0_lt]
      have hd1 : (Pion.I32.sub d step).val = d.val - step.val := i32_sub_val (by omega) (by omega)
      have hpow_comb : 10 ^ (total - (Pion.I32.sub d step).val.toNat) =
          10 ^ (total - d.val.toNat) * div64.val := by
        rw [hdiv_v, ← Nat.pow_add]
        congr 1; omega
      have hq_new : val96_parts (Pion.U64.to_uint n0) (Pion.U64.to_uint n1) (Pion.U64.to_uint n2) =
          orig / 10 ^ (total - (Pion.I32.sub d step).val.toNat) := by
        rw [hq_step, hq_inv, Nat.div_div_eq_div_mul, hpow_comb]
      have hrem_new : (orig % 10 ^ (total - (Pion.I32.sub d step).val.toNat) ≠ 0) ↔
          (orig % 10 ^ (total - d.val.toNat) ≠ 0 ∨ r0.val ≠ 0) := by
        rw [hpow_comb, Nat.mod_mul, ← hq_inv, hr_step]
        have hpos1 : 0 < 10 ^ (total - d.val.toNat) := Nat.pos_of_ne_zero (by positivity)
        have hlt1 : orig % 10 ^ (total - d.val.toNat) < 10 ^ (total - d.val.toNat) := Nat.mod_lt _ hpos1
        constructor
        · intro hne
          by_cases h1 : orig % 10 ^ (total - d.val.toNat) = 0
          · right; intro h2; rw [h1, h2] at hne; exact hne (by simp)
          · exact Or.inl h1
        · rintro (h1 | h2)
          · intro hz; omega
          · intro hz
            have hge : 10 ^ (total - d.val.toNat) ≤ 10 ^ (total - d.val.toNat) * r0.val :=
              Nat.le_mul_of_pos_right _ (by omega)
            omega
      by_cases hr0_nz : r0 ≠ 0#u64
      · simp only [hr0_nz, ne_eq, not_false_eq_true, ↓reduceIte, b_ok, WP.spec_ok]
        have hr0_val_nz : r0.val ≠ 0 := fun hz => hr0_nz (UScalar.eq_of_val_eq hz)
        refine ⟨⟨by omega, by omega, by omega, hq_new, ?_⟩, by omega⟩
        have htrue : orig % 10 ^ (total - (Pion.I32.sub d step).val.toNat) ≠ 0 :=
          hrem_new.mpr (Or.inr hr0_val_nz)
        simp only [htrue, ne_eq, not_false_eq_true, decide_true, Bool.or_true]
      · simp only [hr0_nz, ne_eq, not_true_eq_false, ↓reduceIte, b_ok, WP.spec_ok]
        have hr0_val_z : r0.val = 0 := by
          have : r0 = 0#u64 := Classical.not_not.mp hr0_nz; rw [this]; rfl
        refine ⟨⟨by omega, by omega, by omega, hq_new, ?_⟩, by omega⟩
        rw [hr_inv]
        congr 1
        apply Bool.eq_iff_iff.mpr
        simp only [decide_eq_true_eq, hrem_new, hr0_val_z, ne_eq, not_true_eq_false, or_false]
    · simp only [hpos, ↓reduceIte, WP.spec_ok]
      have h0v : (0#i32 : Std.I32).val = 0 := by decide
      have hd0' : d.val = 0 := by have : ¬((0#i32 : Std.I32).val < d.val) := hpos; omega
      have hsub : total - d.val.toNat = total := by omega
      rw [hsub] at hq_inv hr_inv
      exact ⟨hq_inv, hr_inv⟩
  · refine ⟨hd0, hd28, le_refl _, ?_, ?_⟩
    · simp [orig, total]
    · simp [orig, total, Nat.mod_one]

/-- Exact specification of `truncate_core`: truncates `d` to `target_scale ≤ 28`, preserving
    validity and sign, computing exact `dec_mag d / 10^(dec_scale d - target_scale)` and exact
    discarded-remainder flag `had_rem`. -/
theorem truncate_core_spec (d : Decimal) (target_scale : Std.U32)
    (hd : valid_decimal d) (ht : target_scale.val ≤ 28) :
    ∃ res had_rem, truncate_core d target_scale = ok (res, had_rem) ∧
      valid_decimal res ∧
      dec_neg res = dec_neg d ∧
      (dec_scale d ≤ target_scale.val → res = d ∧ had_rem = false) ∧
      (target_scale.val < dec_scale d →
        dec_scale res = target_scale.val ∧
        dec_mag res = dec_mag d / 10 ^ (dec_scale d - target_scale.val) ∧
        had_rem = decide (dec_mag d % 10 ^ (dec_scale d - target_scale.val) ≠ 0)) := by
  unfold truncate_core
  obtain ⟨sc, hsc, hscv⟩ := Decimal.scale_spec d
  rw [hsc, b_ok]
  have hd28 : dec_scale d ≤ 28 := hd.2
  by_cases hle : sc ≤ target_scale
  · simp only [hle, ↓reduceIte]
    have hle' : dec_scale d ≤ target_scale.val := by have : sc.val ≤ target_scale.val := hle; omega
    exact ⟨d, false, rfl, hd, rfl, fun _ => ⟨rfl, rfl⟩, fun hlt => absurd hlt (by omega)⟩
  · simp only [hle, ↓reduceIte]
    have hlt' : target_scale.val < dec_scale d := by have : ¬(sc.val ≤ target_scale.val) := hle; omega
    set drop := Pion.U32.to_int (Pion.U32.sub sc target_scale)
    have hdrop : drop.val = (dec_scale d - target_scale.val : Nat) := by
      have hsub : (Pion.U32.sub sc target_scale).val = sc.val - target_scale.val := u32_sub_val (by omega)
      rw [u32_to_int_val (by omega), hsub, hscv]
    by_cases hfast : ((d.hi == 0#u32) && decide (drop <= 19#i32)) = true
    · simp only [hfast, ↓reduceIte]
      simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hfast
      have hdrop19 : drop.val ≤ 19 := by
        have : drop.val ≤ (19#i32 : Std.I32).val := hfast.2
        have hv : (19#i32 : Std.I32).val = 19 := by decide
        omega
      obtain ⟨pow, hpow, hpowv⟩ := pow10_u64_spec drop (by omega) hdrop19
      have hpow_eq : pow.val = 10 ^ (dec_scale d - target_scale.val) := by
        rw [hpowv, show drop.val.toNat = dec_scale d - target_scale.val by omega]
      have hpow_pos : 0 < pow.val := by rw [hpow_eq]; exact Nat.pos_of_ne_zero (by positivity)
      obtain ⟨q, hq, hqv⟩ := u64_div_ok (b := pow) d.lo64 (by omega)
      rw [hpow, b_ok, hq, b_ok, Decimal.is_sign_negative_spec, b_ok]
      unfold make_decimal
      obtain ⟨f, hf, hfv, hfs, hfn⟩ := make_flags_spec (dec_neg d) target_scale ht
      rw [hf, b_ok, b_ok]
      refine ⟨Decimal.mk q 0#u32 f, _, rfl, hfv, hfn, fun h => absurd h (by omega), fun _ => ?_⟩
      have hmag_d : dec_mag d = d.lo64.val := by
        unfold dec_mag val96
        rw [hfast.1]
        have h0v : (0#u32 : Std.U32).val = 0 := by decide
        omega
      have hrem_v : (Pion.U64.sub d.lo64 (Pion.U64.mul q pow)).val = d.lo64.val % pow.val := by
        have hmul : (Pion.U64.mul q pow).val = q.val * pow.val := by
          rw [u64_mul_val, Nat.mod_eq_of_lt (by rw [hqv]; have := Nat.div_mul_le_self d.lo64.val pow.val; have := u64_val_lt d.lo64; omega)]
        rw [u64_sub_val (by rw [hmul, hqv]; exact Nat.div_mul_le_self _ _), hmul, hqv]
        have hdm := Nat.div_add_mod d.lo64.val pow.val
        have hle := Nat.div_mul_le_self d.lo64.val pow.val
        have hcomm : d.lo64.val / pow.val * pow.val = pow.val * (d.lo64.val / pow.val) := Nat.mul_comm _ _
        omega
      refine ⟨hfs, ?_, ?_⟩
      · rw [hmag_d]
        unfold dec_mag val96
        have h0v : (0#u32 : Std.U32).val = 0 := by decide
        rw [h0v, hqv, hpow_eq]; omega
      · rw [hmag_d, ← hpow_eq, ← hrem_v]
        by_cases hz : Pion.U64.sub d.lo64 (Pion.U64.mul q pow) = 0#u64
        · rw [hz]; decide
        · have hne : (Pion.U64.sub d.lo64 (Pion.U64.mul q pow)).val ≠ 0 :=
            fun h0 => hz (UScalar.eq_of_val_eq h0)
          simp only [bne, beq_false_of_ne hz, Bool.not_false, hne, ne_eq, not_false_eq_true, decide_true]
    · simp only [hfast, ↓reduceIte]
      obtain ⟨t6, ht6, ht6v⟩ := u64_shr32_ok d.lo64
      rw [ht6, b_ok]
      have hloop := truncate_core_loop0_spec drop d.hi (Pion.U64.to_uint t6) (Pion.U64.to_uint d.lo64) false
        (by omega) (by omega)
      rw [wp_ok_iff] at hloop
      obtain ⟨⟨_, q21, q11, q01, hr11⟩, hres, hq_out, hr_out⟩ := hloop
      rw [hres, b_ok]
      obtain ⟨t14, ht14, ht14v⟩ := u64_shl32_ok (Pion.U32.to_uint64 q11)
      obtain ⟨f, hf, hfv, hfs, hfn⟩ := make_flags_spec (dec_neg d) target_scale ht
      have horig : val96_parts (Pion.U64.to_uint d.lo64) (Pion.U64.to_uint t6) d.hi = dec_mag d := by
        unfold val96_parts dec_mag val96
        rw [u64_to_uint_val, u64_to_uint_val, ht6v]
        have hlt_lo : d.lo64.val / 2 ^ 32 < 2 ^ 32 := by have := u64_val_lt d.lo64; omega
        rw [Nat.mod_eq_of_lt hlt_lo]
        have hdm := Nat.div_add_mod d.lo64.val (2 ^ 32)
        omega
      have hlo64_out : (Pion.U64.bor (Pion.U32.to_uint64 q01) t14).val = q01.val + 2 ^ 32 * q11.val := by
        have h1 : (Pion.U32.to_uint64 q01).val < 2 ^ 32 := by rw [u32_to_uint64_val]; exact u32_val_lt q01
        have h2 : t14.val % 2 ^ 32 = 0 := by rw [ht14v]; exact Nat.mul_mod_left _ _
        rw [u64_bor_disjoint_32 h1 h2, u32_to_uint64_val, ht14v, u32_to_uint64_val,
          Nat.mod_eq_of_lt (u32_val_lt q11)]; ring
      refine ⟨Decimal.mk (Pion.U64.bor (Pion.U32.to_uint64 q01) t14) q21 f, hr11, by
        change (do let __t_12 ← Pion.U64.shl (Pion.U32.to_uint64 q11) 32#u64
                   let __t_13 ← Decimal.is_sign_negative d
                   let __t_14 ← make_decimal (Pion.U64.bor (Pion.U32.to_uint64 q01) __t_12) q21 __t_13 target_scale
                   ok (__t_14, hr11)) = _
        rw [ht14, Decimal.is_sign_negative_spec d]
        unfold make_decimal; simp [hf], hfv, hfn, fun h => absurd h (by omega), fun _ => ?_⟩
      refine ⟨hfs, ?_, ?_⟩
      · unfold dec_mag val96; rw [hlo64_out]
        have : val96_parts q01 q11 q21 = q01.val + 2 ^ 32 * q11.val + 2 ^ 64 * q21.val := rfl
        rw [← this, hq_out, horig, show drop.val.toNat = dec_scale d - target_scale.val by omega]
        rfl
      · dsimp only at hr_out
        rw [hr_out, horig, show drop.val.toNat = dec_scale d - target_scale.val by omega]; simp

/-- Exact specification of `Decimal::trunc`: returns valid integer `Decimal` (`scale = 0`)
    whose mantissa is `dec_mag d / 10^(dec_scale d)`. -/
theorem Decimal.trunc_spec (d : Decimal) (hd : valid_decimal d) :
    ∃ res : Decimal, Decimal.trunc d = ok res ∧
      valid_decimal res ∧
      dec_scale res = 0 ∧
      dec_neg res = dec_neg d ∧
      dec_mag res = dec_mag d / 10 ^ dec_scale d := by
  unfold Decimal.trunc
  obtain ⟨res, hr, htc, hrv, hrn, hle, hgt⟩ := truncate_core_spec d 0#u32 hd (by decide)
  rw [htc, b_ok]
  refine ⟨res, rfl, hrv, ?_, hrn, ?_⟩
  · by_cases hs0 : dec_scale d = 0
    · obtain ⟨rfl, _⟩ := hle (by rw [hs0]; decide)
      exact hs0
    · have h0v : (0#u32 : Std.U32).val = 0 := by decide
      exact (hgt (by omega)).1
  · by_cases hs0 : dec_scale d = 0
    · obtain ⟨rfl, _⟩ := hle (by rw [hs0]; decide)
      rw [hs0, Nat.pow_zero, Nat.div_one]
    · have h0v : (0#u32 : Std.U32).val = 0 := by decide
      have := (hgt (by omega)).2.1
      simpa using this

/-- Exact specification of `scale_up_96`: scales up `(lo64, hi)` from `old_scale` toward
    `target ≤ 28` without ever overflowing 96 bits, preserving exact numerical value. -/
theorem scale_up_96_spec (lo64_in : Std.U64) (hi_in : Std.U32)
    (old_scale target : Std.U32) (neg : Bool)
    (hle : old_scale.val ≤ target.val) (ht28 : target.val ≤ 28) :
    ∃ res : Decimal, scale_up_96 lo64_in hi_in old_scale target neg = ok res ∧
      valid_decimal res ∧
      old_scale.val ≤ dec_scale res ∧
      dec_scale res ≤ target.val ∧
      dec_mag res = val96 lo64_in hi_in * 10 ^ (dec_scale res - old_scale.val) := by
  unfold scale_up_96
  have hloop : scale_up_96_loop0 target old_scale lo64_in hi_in ⦃ st =>
      old_scale.val ≤ st.1.val ∧ st.1.val ≤ target.val ∧
      val96 st.2.1 st.2.2 = val96 lo64_in hi_in * 10 ^ (st.1.val - old_scale.val) ⦄ := by
    unfold scale_up_96_loop0
    apply loop.spec_decr_nat
      (measure := fun (cs, _, _) => target.val - cs.val)
      (inv := fun (cs, lo, hi) =>
        old_scale.val ≤ cs.val ∧ cs.val ≤ target.val ∧
        val96 lo hi = val96 lo64_in hi_in * 10 ^ (cs.val - old_scale.val))
    · rintro ⟨cs, lo, hi⟩ ⟨h1, h2, hinv⟩
      unfold scale_up_96_loop0.body
      by_cases hlt : cs < target
      · have hlt' : cs.val < target.val := hlt
        simp only [hlt, ↓reduceIte]
        have hlo := u64_val_lt lo; have hhi := u32_val_lt hi
        have h10v : (10#u64 : Std.U64).val = 10 := by decide
        set t_lo := Pion.U64.mul (Pion.U64.band lo 4294967295#u64) 10#u64
        have ht_lo : t_lo.val = (lo.val % 2 ^ 32) * 10 := by
          simp only [t_lo, u64_mul_val, u64_band_mask32, h10v]
          have : lo.val % 2 ^ 32 < 2 ^ 32 := Nat.mod_lt _ (by norm_num)
          exact Nat.mod_eq_of_lt (by omega)
        obtain ⟨t, ht, htv⟩ := u64_shr32_ok lo
        obtain ⟨t1, ht1, ht1v⟩ := u64_shr32_ok t_lo
        rw [ht, b_ok, ht1, b_ok]
        set t_mid := Pion.U64.add (Pion.U64.mul t 10#u64) t1
        have ht_mid : t_mid.val = (lo.val / 2 ^ 32) * 10 + t_lo.val / 2 ^ 32 := by
          simp only [t_mid, u64_add_val, u64_mul_val, htv, ht1v, h10v]
          have hm1 : (lo.val / 2 ^ 32) * 10 < 2 ^ 64 := by omega
          rw [Nat.mod_eq_of_lt hm1, Nat.mod_eq_of_lt (by omega)]
        obtain ⟨t2, ht2, ht2v⟩ := u64_shr32_ok t_mid
        rw [ht2, b_ok]
        set t_hi := Pion.U64.add (Pion.U64.mul (Pion.U32.to_uint64 hi) 10#u64) t2
        have ht_hi : t_hi.val = hi.val * 10 + t_mid.val / 2 ^ 32 := by
          simp only [t_hi, u64_add_val, u64_mul_val, u32_to_uint64_val, ht2v, h10v]
          have hm1 : hi.val * 10 < 2 ^ 64 := by omega
          rw [Nat.mod_eq_of_lt hm1, Nat.mod_eq_of_lt (by omega)]
        by_cases hov : t_hi > 4294967295#u64
        · simp only [hov, ↓reduceIte, WP.spec_ok]
          exact ⟨h1, h2, hinv⟩
        · simp only [hov, ↓reduceIte]
          have hthi_lt : t_hi.val < 2 ^ 32 := by
            have : ¬((4294967295#u64 : Std.U64).val < t_hi.val) := hov
            have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
            omega
          obtain ⟨t3, ht3, ht3v⟩ := u64_shl32_ok t_mid
          rw [ht3, b_ok]
          simp only [WP.spec_ok]
          have hcs1 : (Pion.U32.add cs 1#u32).val = cs.val + 1 := by
            rw [u32_add_val]; have : (1#u32 : Std.U32).val = 1 := by decide
            rw [this, Nat.mod_eq_of_lt (by omega)]
          have hlo1 : (Pion.U64.bor (Pion.U64.band t_lo 4294967295#u64) t3).val =
              t_lo.val % 2 ^ 32 + (t_mid.val % 2 ^ 32) * 2 ^ 32 := by
            have h1' : (Pion.U64.band t_lo 4294967295#u64).val < 2 ^ 32 := by
              rw [u64_band_mask32]; exact Nat.mod_lt _ (by norm_num)
            have h2' : t3.val % 2 ^ 32 = 0 := by rw [ht3v]; exact Nat.mul_mod_left _ _
            rw [u64_bor_disjoint_32 h1' h2', u64_band_mask32, ht3v]
          refine ⟨⟨by omega, by omega, ?_⟩, by omega⟩
          have hstep_mul : val96 (Pion.U64.bor (Pion.U64.band t_lo 4294967295#u64) t3) (Pion.U64.to_uint t_hi) =
              val96 lo hi * 10 := by
            unfold val96
            rw [hlo1, u64_to_uint_val, Nat.mod_eq_of_lt hthi_lt]
            omega
          rw [hstep_mul, hinv, hcs1,
            show cs.val + 1 - old_scale.val = (cs.val - old_scale.val) + 1 by omega,
            Nat.pow_succ, Nat.mul_assoc]
      · simp only [hlt, ↓reduceIte, WP.spec_ok]
        exact ⟨h1, h2, hinv⟩
    · exact ⟨le_refl _, hle, by simp⟩
  rw [wp_ok_iff] at hloop
  obtain ⟨⟨cs1, lo1, hi1⟩, hres, h1, h2, hval⟩ := hloop
  dsimp only at h1 h2 hval
  obtain ⟨f, hf, hfv, hfs, _⟩ := make_flags_spec neg cs1 (by omega)
  exact ⟨Decimal.mk lo1 hi1 f, by
    dsimp only; rw [hres, b_ok]
    change (do let __t ← make_decimal lo1 hi1 neg cs1; ok __t) = _
    unfold make_decimal; rw [hf]; simp,
    hfv,
    by unfold dec_scale; dsimp only; rw [hfs]; exact h1,
    by unfold dec_scale; dsimp only; rw [hfs]; exact h2,
    by unfold dec_mag dec_scale; dsimp only; rw [hfs]; exact hval⟩


end DecimalProofs
