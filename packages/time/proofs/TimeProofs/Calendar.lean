import TimeProofs.Core

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace TimeProofs

open time

/-! ## 1. Gregorian Leap Year & Days in Month -/

/-- Mathematical definition of a proleptic Gregorian leap year. -/
def IsLeapYear (y : Int) : Prop :=
  (y % 4 = 0 ∧ y % 100 ≠ 0) ∨ y % 400 = 0

instance (y : Int) : Decidable (IsLeapYear y) := by
  unfold IsLeapYear; infer_instance

/-- Mathematical specification of days in a Gregorian month (`1 ≤ m ≤ 12`). -/
def specDaysInMonth (y m : Int) : Int :=
  if m = 2 then (if IsLeapYear y then 29 else 28)
  else if m = 4 ∨ m = 6 ∨ m = 9 ∨ m = 11 then 30
  else 31

/-- `is_leap_year` never traps on any `Int` (`Std.I32`, including negative years and `INT32_MIN`)
    and matches the proleptic Gregorian leap-year definition exactly. -/
theorem is_leap_year_spec (year : Std.I32) :
    is_leap_year year = ok (decide (IsLeapYear year.val)) := by
  unfold is_leap_year
  have h3 := i32_band_3_val year
  have h15 := i32_band_15_val year
  by_cases hmod4 : year.val % 4 = 0
  · have hband3 : Pion.I32.band year 3#i32 = 0#i32 := i32_ext (by simpa using h3.trans hmod4)
    simp only [hband3, ne_eq, not_true_eq_false, ↓reduceIte]
    rcases i32_rem_ok year 25#i32 (by decide) (by simp) with ⟨rem, hrem_eq, hrem_val⟩
    rw [hrem_eq, b_ok]
    congr 1
    have h25 : (rem != 0#i32) = decide (year.val % 25 ≠ 0) := by
      have hiff : rem.val = 0 ↔ year.val % 25 = 0 := by
        rw [hrem_val]
        have h25v : (25#i32).val = 25 := by decide
        rw [h25v, ← Int.dvd_iff_tmod_eq_zero, ← Int.dvd_iff_emod_eq_zero]
      by_cases h0 : rem = 0#i32
      · subst h0
        have : year.val % 25 = 0 := hiff.mp (by decide)
        simp [this]
      · have hne : rem.val ≠ 0 := fun hv => h0 (i32_ext (by simpa using hv))
        have : year.val % 25 ≠ 0 := fun h => hne (hiff.mpr h)
        simp [h0, this]
    have h16 : (Pion.I32.band year 15#i32 == 0#i32) = decide (year.val % 16 = 0) := by
      by_cases h0 : Pion.I32.band year 15#i32 = 0#i32
      · have : year.val % 16 = 0 := by
          have := congrArg IScalar.val h0
          rw [h15] at this
          simpa using this
        rw [beq_iff_eq.mpr h0, decide_eq_true this]
      · have hne : year.val % 16 ≠ 0 := fun hm =>
          h0 (i32_ext (by rw [h15]; simpa using hm))
        rw [beq_false_of_ne h0, decide_eq_false hne]
    rw [h25, h16]
    unfold IsLeapYear
    by_cases h100 : year.val % 100 = 0 <;> by_cases h400 : year.val % 400 = 0 <;>
      by_cases h25m : year.val % 25 = 0 <;> by_cases h16m : year.val % 16 = 0 <;>
      simp [hmod4, h100, h400, h25m, h16m] <;> omega
  · have hband3 : Pion.I32.band year 3#i32 ≠ 0#i32 := fun heq => by
      have := congrArg IScalar.val heq
      rw [h3] at this
      exact hmod4 (by simpa using this)
    simp only [hband3, ne_eq, not_false_eq_true, ↓reduceIte]
    congr 1
    have hnot : ¬ IsLeapYear year.val := by
      unfold IsLeapYear; omega
    simp [hnot]

/-- Century & BCE leap-year corollaries. -/
theorem leap_year_1900 : is_leap_year 1900#i32 = ok false := by
  rw [is_leap_year_spec]; rfl

theorem leap_year_2000 : is_leap_year 2000#i32 = ok true := by
  rw [is_leap_year_spec]; rfl

theorem leap_year_2100 : is_leap_year 2100#i32 = ok false := by
  rw [is_leap_year_spec]; rfl

theorem leap_year_2400 : is_leap_year 2400#i32 = ok true := by
  rw [is_leap_year_spec]; rfl

theorem leap_year_zero : is_leap_year 0#i32 = ok true := by
  rw [is_leap_year_spec]; rfl

theorem leap_year_neg400 : is_leap_year (-400)#i32 = ok true := by
  rw [is_leap_year_spec]; rfl

theorem leap_year_neg100 : is_leap_year (-100)#i32 = ok false := by
  rw [is_leap_year_spec]; rfl

/-- `days_in_month_of` never traps for `1 ≤ month ≤ 12`, always returns a value in `[28, 31]`,
    and equals `specDaysInMonth year.val month.val` (in particular, 29/28 for February). -/
theorem days_in_month_of_spec (year month : Std.I32)
    (hm1 : 1 ≤ month.val) (hm12 : month.val ≤ 12) :
    ∃ d : Std.I32, days_in_month_of year month = ok d ∧
      d.val = specDaysInMonth year.val month.val ∧
      28 ≤ d.val ∧ d.val ≤ 31 := by
  unfold days_in_month_of
  by_cases hm2 : month = 2#i32
  · subst hm2
    simp only [↓reduceIte, is_leap_year_spec, b_ok]
    refine ⟨_, rfl, ?_, ?_, ?_⟩
    · unfold specDaysInMonth
      by_cases hl : IsLeapYear year.val <;> simp [hl]
    · by_cases hl : IsLeapYear year.val <;> simp [hl]
    · by_cases hl : IsLeapYear year.val <;> simp [hl]
  · have hm2v : month.val ≠ 2 := fun h => hm2 (i32_ext (by simpa using h))
    simp only [hm2, ↓reduceIte]
    rcases i32_div_ok month 8#i32 (by decide) (by simp) with ⟨q, hq_eq, hq_val⟩
    rw [hq_eq, b_ok]
    have hq8 : q.val = month.val / 8 := by
      rw [hq_val]
      have h8v : (8#i32).val = 8 := by decide
      rw [h8v, Int.tdiv_eq_ediv_of_nonneg (by omega)]
    have hsum_val : (Pion.I32.add month q).val = month.val + month.val / 8 := by
      rw [i32_add_val month q (by omega) (by omega), hq8]
    rcases i32_rem_ok (Pion.I32.add month q) 2#i32 (by decide) (by simp) with ⟨r, hr_eq, hr_val⟩
    rw [hr_eq, b_ok]
    have hr2 : r.val = (month.val + month.val / 8) % 2 := by
      rw [hr_val, hsum_val]
      have h2v : (2#i32).val = 2 := by decide
      rw [h2v, Int.tmod_eq_emod_of_nonneg (by omega)]
    have h30 : (30#i32).val = 30 := by decide
    have hres_val : (Pion.I32.add 30#i32 r).val = 30 + (month.val + month.val / 8) % 2 := by
      rw [i32_add_val 30#i32 r (by rw [h30]; omega) (by rw [h30]; omega), h30, hr2]
    refine ⟨_, rfl, ?_, ?_, ?_⟩
    · rw [hres_val]; unfold specDaysInMonth
      have hm_cases : month.val = 1 ∨ month.val = 3 ∨ month.val = 4 ∨ month.val = 5 ∨
          month.val = 6 ∨ month.val = 7 ∨ month.val = 8 ∨ month.val = 9 ∨
          month.val = 10 ∨ month.val = 11 ∨ month.val = 12 := by omega
      rcases hm_cases with h | h | h | h | h | h | h | h | h | h | h <;> simp [h]
    · rw [hres_val]; omega
    · rw [hres_val]; omega

theorem days_in_month_of_feb (year : Std.I32) :
    days_in_month_of year 2#i32 = ok (if IsLeapYear year.val then 29#i32 else 28#i32) := by
  unfold days_in_month_of
  simp only [↓reduceIte, is_leap_year_spec, b_ok]
  by_cases hl : IsLeapYear year.val <;> simp [hl]

/-! ## 2. Hinnant / Neri-Schneider Gregorian Calendar Bijection (`-9999..=9999`) -/

/-- A valid Gregorian `Date` within `jiff`'s `-9999-01-01 ..= 9999-12-31` range. -/
def ValidDate (d : Date) : Prop :=
  -9999 ≤ d.year.val ∧ d.year.val ≤ 9999 ∧
  1 ≤ d.month.val ∧ d.month.val ≤ 12 ∧
  1 ≤ d.day.val ∧ d.day.val ≤ specDaysInMonth d.year.val d.month.val

/-- Valid Unix epoch day range matching `-9999-01-01 ..= 9999-12-31`. -/
def ValidEpochDays (z : Std.I32) : Prop :=
  -4371587 ≤ z.val ∧ z.val ≤ 2932896

/-- Pure mathematical Gregorian epoch day formula (days since 1970-01-01). -/
def specEpochDays (year month day : Int) : Int :=
  let j := if month ≤ 2 then 1 else 0
  let y := year + 32800 - j
  let m := if j = 1 then month + 12 else month
  let d := day - 1
  let y_star := (1461 * y) / 4 - y / 100 + y / 400
  let m_star := (979 * m - 2919) / 32
  y_star + m_star + d - 12699422

/-- `Date.to_epoch_days` never traps on any valid `Date` and returns `specEpochDays`
    within `[-4371587, 2932896]`. -/
theorem to_epoch_days_spec (d : Date) (hd : ValidDate d) :
    ∃ ed : Std.I32, Date.to_epoch_days d = ok ed ∧
      ed.val = specEpochDays d.year.val d.month.val d.day.val ∧
      ValidEpochDays ed := by
  rcases hd with ⟨hy1, hy2, hm1, hm12, hd1, hdm⟩
  have hdim_le : specDaysInMonth d.year.val d.month.val ≤ 31 := by
    unfold specDaysInMonth; split_ifs <;> omega
  unfold Date.to_epoch_days
  dsimp only
  set jI : Std.I32 := if d.month ≤ 2#i32 then 1#i32 else 0#i32
  set j : Int := if d.month.val ≤ 2 then 1 else 0
  have hj_val : jI.val = j := by
    simp only [jI, j]
    by_cases hle : d.month.val ≤ 2
    · have hle' : d.month ≤ 2#i32 := hle
      simp [hle, hle']
    · have hle' : ¬ (d.month ≤ 2#i32) := hle
      simp [hle, hle']
  set yI := Pion.I32.sub (Pion.I32.add d.year 32800#i32) jI
  have hy_val : yI.val = d.year.val + 32800 - j := by
    have hadd := i32_add_val d.year 32800#i32 (by simp; omega) (by simp; omega)
    have hsub := i32_sub_val (Pion.I32.add d.year 32800#i32) jI (by rw [hadd]; simp; omega) (by rw [hadd]; simp; omega)
    rw [hsub, hadd, hj_val]; simp
  have hy_rng : 22800 ≤ yI.val ∧ yI.val ≤ 42799 := by omega
  set mI : Std.I32 := if jI = 1#i32 then Pion.I32.add d.month 12#i32 else d.month
  set m : Int := if j = 1 then d.month.val + 12 else d.month.val
  have hm_val : mI.val = m := by
    simp only [mI, m]
    by_cases hj1 : j = 1
    · have hj1' : jI = 1#i32 := i32_ext (by rw [hj_val, hj1]; decide)
      simp only [hj1, hj1', ↓reduceIte]
      have ha := i32_add_val d.month 12#i32 (by simp; omega) (by simp; omega)
      simpa using ha
    · have hj1' : jI ≠ 1#i32 := fun h => hj1 (by have := congrArg IScalar.val h; rw [hj_val] at this; exact this)
      simp [hj1, hj1']
  have hm_rng : 3 ≤ mI.val ∧ mI.val ≤ 14 := by omega
  set dI := Pion.I32.sub d.day 1#i32
  have hd_val : dI.val = d.day.val - 1 := by
    have h := i32_sub_val d.day 1#i32 (by simp; omega) (by simp; omega)
    have h1 : (1#i32).val = 1 := by decide
    rw [h, h1]
  -- Step 1: c = (y * 41944) >> 22 = y / 100
  have hmul1 : (Pion.I32.mul yI 41944#i32).val = yI.val * 41944 := by
    simpa using i32_mul_val yI 41944#i32 (by simp; omega) (by simp; omega)
  rcases i32_shr_val (Pion.I32.mul yI 41944#i32) 22#i32 (by decide) (by decide) with ⟨cI, hc_eq, hc_val⟩
  rw [hc_eq, b_ok]
  have hc_exact : cI.val = yI.val / 100 := by
    have hpow : (2 ^ (22#i32).val.toNat : Int) = 4194304 := by decide
    rw [hc_val, hmul1, hpow]; omega
  -- Step 2: t1 = (1461 * y) >> 2
  have hmul2 : (Pion.I32.mul 1461#i32 yI).val = 1461 * yI.val := by
    simpa using i32_mul_val 1461#i32 yI (by simp; omega) (by simp; omega)
  rcases i32_shr_val (Pion.I32.mul 1461#i32 yI) 2#i32 (by decide) (by decide) with ⟨t1I, ht1_eq, ht1_val⟩
  rw [ht1_eq, b_ok]
  have ht1_exact : t1I.val = (1461 * yI.val) / 4 := by
    have hpow : (2 ^ (2#i32).val.toNat : Int) = 4 := by decide
    rw [ht1_val, hmul2, hpow]
  -- Step 3: t2 = c >> 2 = y / 400
  rcases i32_shr_val cI 2#i32 (by decide) (by decide) with ⟨t2I, ht2_eq, ht2_val⟩
  rw [ht2_eq, b_ok]
  have ht2_exact : t2I.val = yI.val / 400 := by
    have hpow : (2 ^ (2#i32).val.toNat : Int) = 4 := by decide
    rw [ht2_val, hc_exact, hpow]; omega
  -- Step 4: y_star = t1 - c + t2
  set y_starI := Pion.I32.add (Pion.I32.sub t1I cI) t2I
  have hy_star_val : y_starI.val = (1461 * yI.val) / 4 - yI.val / 100 + yI.val / 400 := by
    have hs := i32_sub_val t1I cI (by omega) (by omega)
    have ha := i32_add_val (Pion.I32.sub t1I cI) t2I (by rw [hs]; omega) (by rw [hs]; omega)
    rw [ha, hs, ht1_exact, hc_exact, ht2_exact]
  -- Step 5: m_star = (979 * m - 2919) >> 5
  have hmul3 : (Pion.I32.mul 979#i32 mI).val = 979 * mI.val := by
    simpa using i32_mul_val 979#i32 mI (by simp; omega) (by simp; omega)
  have hsub3 : (Pion.I32.sub (Pion.I32.mul 979#i32 mI) 2919#i32).val = 979 * mI.val - 2919 := by
    have hs := i32_sub_val (Pion.I32.mul 979#i32 mI) 2919#i32 (by rw [hmul3]; simp; omega) (by rw [hmul3]; simp; omega)
    rw [hs, hmul3]; simp
  rcases i32_shr_val (Pion.I32.sub (Pion.I32.mul 979#i32 mI) 2919#i32) 5#i32 (by decide) (by decide) with ⟨m_starI, hm_star_eq, hm_star_val⟩
  rw [hm_star_eq, b_ok]
  have hm_star_exact : m_starI.val = (979 * mI.val - 2919) / 32 := by
    have hpow : (2 ^ (5#i32).val.toNat : Int) = 32 := by decide
    rw [hm_star_val, hsub3, hpow]
  -- Final assembly
  have h1269 : (12699422#i32).val = 12699422 := by decide
  have ha1 := i32_add_val y_starI m_starI (by omega) (by omega)
  have ha2 := i32_add_val (Pion.I32.add y_starI m_starI) dI (by rw [ha1]; omega) (by rw [ha1]; omega)
  have hs2 := i32_sub_val (Pion.I32.add (Pion.I32.add y_starI m_starI) dI) 12699422#i32
    (by rw [ha2, ha1, h1269]; omega) (by rw [ha2, ha1, h1269]; omega)
  refine ⟨_, rfl, ?_, ?_⟩
  · rw [hs2, h1269, ha2, ha1, hy_star_val, hm_star_exact, hd_val, hy_val, hm_val]
    rfl
  · unfold ValidEpochDays
    rw [hs2, h1269, ha2, ha1, hy_star_val, hm_star_exact, hd_val]
    have hys_lo : (1461 * 22800) / 4 - 22800 / 100 + 22800 / 400 ≤ (1461 * yI.val) / 4 - yI.val / 100 + yI.val / 400 := by
      have h4 : (1461 * 22800) / 4 + 365 * (yI.val - 22800) ≤ (1461 * yI.val) / 4 := by omega
      have h100 : yI.val / 100 - 22800 / 100 ≤ (yI.val - 22800) / 100 + 1 := by omega
      have h400 : 22800 / 400 ≤ yI.val / 400 := by omega
      by_cases heq : yI.val = 22800 <;> omega
    have hys_lo1 : 22801 ≤ yI.val → (1461 * 22801) / 4 - 22801 / 100 + 22801 / 400 ≤ (1461 * yI.val) / 4 - yI.val / 100 + yI.val / 400 := by
      intro h221
      have h4 : (1461 * 22801) / 4 + 365 * (yI.val - 22801) ≤ (1461 * yI.val) / 4 := by omega
      have h100 : yI.val / 100 - 22801 / 100 ≤ (yI.val - 22801) / 100 + 1 := by omega
      have h400 : 22801 / 400 ≤ yI.val / 400 := by omega
      by_cases heq : yI.val = 22801 <;> omega
    have hys_hi : (1461 * yI.val) / 4 - yI.val / 100 + yI.val / 400 ≤ (1461 * 42799) / 4 - 42799 / 100 + 42799 / 400 := by
      have h4 : (1461 * yI.val) / 4 + 365 * (42799 - yI.val) ≤ (1461 * 42799) / 4 := by omega
      have h100 : 42799 / 100 - yI.val / 100 ≤ (42799 - yI.val) / 100 + 1 := by omega
      have h400 : yI.val / 400 ≤ 42799 / 400 := by omega
      by_cases heq : yI.val = 42799 <;> omega
    have hys_hi1 : yI.val ≤ 42798 → (1461 * yI.val) / 4 - yI.val / 100 + yI.val / 400 ≤ (1461 * 42798) / 4 - 42798 / 100 + 42798 / 400 := by
      intro h428
      have h4 : (1461 * yI.val) / 4 + 365 * (42798 - yI.val) ≤ (1461 * 42798) / 4 := by omega
      have h100 : 42798 / 100 - yI.val / 100 ≤ (42798 - yI.val) / 100 + 1 := by omega
      have h400 : yI.val / 400 ≤ 42798 / 400 := by omega
      by_cases heq : yI.val = 42798 <;> omega
    have hms_lo : 0 ≤ (979 * mI.val - 2919) / 32 := by omega
    have hms_hi : (979 * mI.val - 2919) / 32 ≤ 337 := by omega
    have hms_13 : 13 ≤ mI.val → 306 ≤ (979 * mI.val - 2919) / 32 := by omega
    have hms_12 : mI.val ≤ 12 → (979 * mI.val - 2919) / 32 ≤ 275 := by omega
    have hy_m_lo : yI.val = 22800 → 13 ≤ mI.val := by
      intro h22; have : j = 1 := by omega
      have : m = d.month.val + 12 := by simp [m, this]
      omega
    have hy_m_hi : yI.val = 42799 → mI.val ≤ 12 := by
      intro h42; have : j = 0 := by omega
      have : m = d.month.val := by simp [m, this]
      omega
    constructor
    · by_cases h22 : yI.val = 22800
      · have := hms_13 (hy_m_lo h22); omega
      · have := hys_lo1 (by omega); omega
    · by_cases h42 : yI.val = 42799
      · have := hms_12 (hy_m_hi h42); omega
      · have := hys_hi1 (by omega); omega

private theorem ystar_mono (u v : Int) (huv : u ≤ v) :
    (1461 * u) / 4 - u / 100 + u / 400 ≤ (1461 * v) / 4 - v / 100 + v / 400 := by
  by_cases heq : u = v
  · subst heq; exact le_rfl
  · have h4 : (1461 * u) / 4 + 365 * (v - u) ≤ (1461 * v) / 4 := by omega
    have h100 : v / 100 - u / 100 ≤ (v - u) / 100 + 1 := by omega
    have h400 : u / 400 ≤ v / 400 := by omega
    omega

private theorem ystar_step (y : Int) :
    ((1461 * (y + 1)) / 4 - (y + 1) / 100 + (y + 1) / 400) -
    ((1461 * y) / 4 - y / 100 + y / 400) =
    if IsLeapYear (y - 32800 + 1) then 366 else 365 := by
  have h4 : (1461 * (y + 1)) / 4 - (1461 * y) / 4 = 365 + if (y + 1) % 4 = 0 then 1 else 0 := by
    have hr : y % 4 = 0 ∨ y % 4 = 1 ∨ y % 4 = 2 ∨ y % 4 = 3 := by omega
    rcases hr with hr | hr | hr | hr <;> split_ifs <;> omega
  have h100 : (y + 1) / 100 - y / 100 = if (y + 1) % 100 = 0 then 1 else 0 := by
    split_ifs <;> omega
  have h400 : (y + 1) / 400 - y / 400 = if (y + 1) % 400 = 0 then 1 else 0 := by
    split_ifs <;> omega
  have hm4 : (y - 32800 + 1) % 4 = (y + 1) % 4 := by omega
  have hm100 : (y - 32800 + 1) % 100 = (y + 1) % 100 := by omega
  have hm400 : (y - 32800 + 1) % 400 = (y + 1) % 400 := by omega
  unfold IsLeapYear
  simp only [hm4, hm100, hm400]
  split_ifs at h4 h100 h400 ⊢ <;> omega

/-- Pure mathematical inverse of `specEpochDays` (Neri-Schneider Euclidean form). -/
private def specFromEpochDays (days : Int) : Int × Int × Int :=
  let n := days + 12699422
  let n1 := 4 * n + 3
  let c := n1 / 146097
  let nc := (n1 - c * 146097) / 4
  let n2 := 4 * nc + 3
  let z := n2 / 1461
  let ny := nc - (1461 * z) / 4
  let y := 100 * c + z
  let n3 := 2141 * ny + 197913
  let m := n3 / 65536
  let d := ((n3 % 65536) * 31345) / 67108864
  let j := if ny ≥ 306 then 1 else 0
  let year := y - 32800 + j
  let month := if j = 1 then m - 12 else m
  (year, month, d + 1)

/-- Year-level Neri-Schneider inverse (isolated from month/day arithmetic for fast kernel checking). -/
private theorem neri_year_inv (n : Int) (hn1 : 8327835 ≤ n) (hn2 : n ≤ 15632318) :
    let n1 := 4 * n + 3
    let c := n1 / 146097
    let nc := (n1 - c * 146097) / 4
    let n2 := 4 * nc + 3
    let z := n2 / 1461
    let ny := nc - (1461 * z) / 4
    let y := 100 * c + z
    (22800 ≤ y ∧ y ≤ 42799) ∧
    (0 ≤ ny ∧ ny ≤ 365) ∧
    ((1461 * y) / 4 - y / 100 + y / 400 + ny = n) ∧
    (ny = 365 → IsLeapYear (y - 32800 + 1)) := by
  dsimp only
  generalize hn1_eq : 4 * n + 3 = n1
  generalize hc_eq : n1 / 146097 = c
  generalize hnc_eq : (n1 - c * 146097) / 4 = nc
  generalize hn2_eq : 4 * nc + 3 = n2
  generalize hz_eq : n2 / 1461 = z
  generalize hny_eq : nc - (1461 * z) / 4 = ny
  generalize hy_eq : 100 * c + z = y
  have hc_div : 146097 * c ≤ n1 ∧ n1 < 146097 * (c + 1) := by omega
  have hnc_div : 4 * nc ≤ n1 - c * 146097 ∧ n1 - c * 146097 < 4 * (nc + 1) := by omega
  have hz_div : 1461 * z ≤ n2 ∧ n2 < 1461 * (z + 1) := by omega
  have hnc_rng : 0 ≤ nc ∧ nc ≤ 36524 := by omega
  have hz_rng : 0 ≤ z ∧ z ≤ 99 := by omega
  have hny_rng : 0 ≤ ny ∧ ny ≤ 365 := by omega
  have hc_rng : 228 ≤ c ∧ c ≤ 427 := by omega
  have hy_rng : 22800 ≤ y ∧ y ≤ 42799 := by omega
  have hy_div100 : y / 100 = c := by omega
  have hy_div400 : y / 400 = c / 4 := by omega
  have hy_1461 : (1461 * y) / 4 = 36525 * c + (1461 * z) / 4 := by omega
  have hc_146097 : 36524 * c + c / 4 + nc = n := by omega
  have hy_star_inv : (1461 * y) / 4 - y / 100 + y / 400 + ny = n := by omega
  refine ⟨hy_rng, hny_rng, hy_star_inv, ?_⟩
  intro h365
  clear hy_div100 hy_div400 hy_1461 hc_146097 hy_star_inv hc_eq hnc_eq hz_eq
  unfold IsLeapYear
  by_cases hz99 : z = 99
  · have hnc36524 : nc = 36524 := by
      have h1461 : (1461 * z) / 4 = 36159 := by rw [hz99]; norm_num
      have hny' : nc - (1461 * z) / 4 = 365 := hny_eq.trans h365
      linarith
    have hrem : n1 - c * 146097 = 146096 := by
      have h1 : 4 * 36524 ≤ n1 - c * 146097 := hnc36524 ▸ hnc_div.1
      have h2 : n1 < 146097 * (c + 1) := hc_div.2
      linarith
    have hc4 : c % 4 = 3 := by
      have h3 : 4 * n + 3 - c * 146097 = 146096 := hn1_eq ▸ hrem
      clear * - h3
      omega
    have hy400 : (y - 32800 + 1) % 400 = 0 := by
      have hy99 : y = 100 * c + 99 := by rw [← hy_eq, hz99]
      clear * - hy99 hc4
      omega
    exact Or.inr hy400
  · have hz4 : z % 4 = 3 := by
      have h1 : 4 * nc + 3 < 1461 * (z + 1) := hn2_eq ▸ hz_div.2
      have h2 : nc - (1461 * z) / 4 = 365 := hny_eq.trans h365
      clear * - h1 h2
      omega
    have hy4 : (y - 32800 + 1) % 4 = 0 := by
      clear * - hy_eq hz4
      omega
    have hy100 : (y - 32800 + 1) % 100 ≠ 0 := by
      clear * - hy_eq hz_rng hz99
      omega
    exact Or.inl ⟨hy4, hy100⟩

/-- Month/day-level Neri-Schneider inverse (isolated from century/year arithmetic). -/
private theorem neri_month_inv (ny : Int) (h0 : 0 ≤ ny) (h365 : ny ≤ 365) :
    let n3 := 2141 * ny + 197913
    let m := n3 / 65536
    let d := ((n3 % 65536) * 31345) / 67108864
    (3 ≤ m ∧ m ≤ 14) ∧
    ((979 * m - 2919) / 32 + d = ny) ∧
    (ny ≥ 306 ↔ m ≥ 13) ∧
    (0 ≤ d) ∧
    (m = 14 → d ≤ 28 ∧ (ny ≤ 364 → d ≤ 27)) ∧
    (m ≠ 14 → d + 1 ≤ specDaysInMonth 2001 (if m ≥ 13 then m - 12 else m)) := by
  dsimp only
  generalize hn3_eq : 2141 * ny + 197913 = n3
  generalize hm_eq : n3 / 65536 = m
  have hm_div : 65536 * m ≤ n3 ∧ n3 < 65536 * (m + 1) := by omega
  have hm_rng : 3 ≤ m ∧ m ≤ 14 := by omega
  have hn3_mod : n3 % 65536 = n3 - 65536 * m := by omega
  rw [hn3_mod]
  generalize hd_eq : ((n3 - 65536 * m) * 31345) / 67108864 = d
  have hd_div : 67108864 * d ≤ (n3 - 65536 * m) * 31345 ∧ (n3 - 65536 * m) * 31345 < 67108864 * (d + 1) := by omega
  have hcases : m = 3 ∨ m = 4 ∨ m = 5 ∨ m = 6 ∨ m = 7 ∨ m = 8 ∨
                m = 9 ∨ m = 10 ∨ m = 11 ∨ m = 12 ∨ m = 13 ∨ m = 14 := by omega
  refine ⟨hm_rng, ?_, ?_, ?_, ?_, ?_⟩
  · rcases hcases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> omega
  · omega
  · omega
  · intro hm14; subst hm14; omega
  · intro hne14
    unfold specDaysInMonth
    rcases hcases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
    all_goals first | contradiction | (simp; omega)

/-- Key algebraic lemma: `specFromEpochDays` produces a valid Gregorian date whose `specEpochDays`
    equals `days` for every `-4371587 ≤ days ≤ 2932896`. -/
private theorem specFromEpochDays_valid_and_inv (days : Int)
    (hlo : -4371587 ≤ days) (hhi : days ≤ 2932896) :
    let (year, month, day) := specFromEpochDays days
    (-9999 ≤ year ∧ year ≤ 9999 ∧ 1 ≤ month ∧ month ≤ 12 ∧
      1 ≤ day ∧ day ≤ specDaysInMonth year month) ∧
    specEpochDays year month day = days := by
  dsimp only [specFromEpochDays, specEpochDays]
  have hyi := neri_year_inv (days + 12699422) (by omega) (by omega)
  dsimp only at hyi
  rcases hyi with ⟨hy_rng, hny_rng, hy_star_inv, hny365_leap⟩
  set n := days + 12699422
  set n1 := 4 * n + 3
  set c := n1 / 146097
  set nc := (n1 - c * 146097) / 4
  set n2 := 4 * nc + 3
  set z := n2 / 1461
  set ny := nc - (1461 * z) / 4
  set y := 100 * c + z
  have hmi := neri_month_inv ny hny_rng.1 hny_rng.2
  dsimp only at hmi
  rcases hmi with ⟨hm_rng, hm_star_inv, hny_ge_306_iff, hd_nonneg, hd_feb, hd_other⟩
  set n3 := 2141 * ny + 197913
  set m := n3 / 65536
  set d := ((n3 % 65536) * 31345) / 67108864
  have hd_valid : 1 ≤ d + 1 ∧ d + 1 ≤ specDaysInMonth (y - 32800 + if ny ≥ 306 then 1 else 0)
      (if (if ny ≥ 306 then (1 : Int) else 0) = 1 then m - 12 else m) := by
    refine ⟨by omega, ?_⟩
    by_cases h306 : ny ≥ 306
    · have hm1314 : m = 13 ∨ m = 14 := by omega
      rcases hm1314 with hm13 | hm14
      · have ho := hd_other (by omega)
        simp only [h306, ↓reduceIte, hm13] at ho ⊢
        unfold specDaysInMonth at ho ⊢; simp at ho ⊢; omega
      · simp only [h306, ↓reduceIte, hm14]
        unfold specDaysInMonth
        have hfeb := hd_feb hm14
        by_cases hl : IsLeapYear (y - 32800 + 1)
        · simp [hl]; omega
        · have hny_lt : ny ≤ 364 := by
            by_contra hge
            exact hl (hny365_leap (by omega))
          simp [hl]; omega
    · have ho := hd_other (by omega)
      have hnot13 : ¬ (m ≥ 13) := by omega
      simp only [h306, ↓reduceIte, zero_ne_one]
      simp only [hnot13, ↓reduceIte] at ho
      unfold specDaysInMonth at ho ⊢
      have hne2 : m ≠ 2 := by omega
      simp only [hne2, ↓reduceIte] at ho ⊢
      exact ho
  have hy_bounds : -9999 ≤ y - 32800 + (if ny ≥ 306 then 1 else 0) ∧
                   y - 32800 + (if ny ≥ 306 then 1 else 0) ≤ 9999 := by
    by_cases h306 : ny ≥ 306
    · simp only [h306, ↓reduceIte]
      have hy_hi : y ≤ 42798 := by
        by_contra hge
        have hy42799 : y = 42799 := by omega
        have : (1461 * 42799) / 4 - 42799 / 100 + 42799 / 400 + ny = n := by rw [← hy42799]; exact hy_star_inv
        omega
      omega
    · simp only [h306, ↓reduceIte]
      have hy_lo : y ≥ 22801 := by
        by_contra hlt
        have hy22800 : y = 22800 := by omega
        have : (1461 * 22800) / 4 - 22800 / 100 + 22800 / 400 + ny = n := by rw [← hy22800]; exact hy_star_inv
        omega
      omega
  refine ⟨⟨hy_bounds.1, hy_bounds.2, ?_, ?_, hd_valid.1, hd_valid.2⟩, ?_⟩
  · omega
  · omega
  · by_cases h306 : ny ≥ 306
    · simp only [h306, ↓reduceIte]
      have hm1314 : m = 13 ∨ m = 14 := by omega
      rcases hm1314 with hm13 | hm14
      · simp only [hm13] at hm_star_inv ⊢
        have hcond : ((13 : Int) - 12 ≤ 2) := by decide
        simp only [hcond, ↓reduceIte]
        have hy_eq : y - 32800 + 1 + 32800 - 1 = y := by omega
        have hm_eq : (13 : Int) - 12 + 12 = 13 := by decide
        rw [hy_eq, hm_eq]
        omega
      · simp only [hm14] at hm_star_inv ⊢
        have hcond : ((14 : Int) - 12 ≤ 2) := by decide
        simp only [hcond, ↓reduceIte]
        have hy_eq : y - 32800 + 1 + 32800 - 1 = y := by omega
        have hm_eq : (14 : Int) - 12 + 12 = 14 := by decide
        rw [hy_eq, hm_eq]
        omega
    · simp only [h306, ↓reduceIte, zero_ne_one]
      have hnotle2 : ¬ (m ≤ 2) := by omega
      simp only [hnotle2, ↓reduceIte, zero_ne_one]
      have hy_eq : y - 32800 + 0 + 32800 - 0 = y := by omega
      rw [hy_eq]
      omega

/-- `Date.from_epoch_days` never traps on any `Std.I32`; for `ValidEpochDays days`,
    it returns `ok (.Ok d)` matching `specFromEpochDays days.val`, with `ValidDate d`. -/
theorem from_epoch_days_spec (days : Std.I32) (h : ValidEpochDays days) :
    ∃ d : Date, Date.from_epoch_days days = ok (Pion.Res.Ok d) ∧
      (d.year.val, d.month.val, d.day.val) = specFromEpochDays days.val ∧
      ValidDate d := by
  rcases h with ⟨hlo, hhi⟩
  unfold Date.from_epoch_days
  have hnot_out : ((decide (days < min_epoch_days)) || (decide (days > max_epoch_days))) = false := by
    have h1 : ¬ (days < min_epoch_days) := by
      show ¬ (days.val < (-4371587 : Int)); omega
    have h2 : ¬ (days > max_epoch_days) := by
      show ¬ (days.val > (2932896 : Int)); omega
    simp [h1, h2]
  simp only [hnot_out, Bool.false_eq_true, ↓reduceIte]
  -- n = days + 12699422
  set nI := Pion.I32.add days 12699422#i32
  have hn_val : nI.val = days.val + 12699422 := by
    have hc : (12699422#i32).val = 12699422 := by decide
    have h := i32_add_val days 12699422#i32 (by rw [hc]; omega) (by rw [hc]; omega)
    rw [h, hc]
  -- n1 = (n << 2) + 3
  rcases i32_shl_2_val nI (by omega) (by omega) with ⟨sh1I, hsh1_eq, hsh1_val⟩
  rw [hsh1_eq, b_ok]
  set n1I := Pion.I32.add sh1I 3#i32
  have hn1_val : n1I.val = 4 * nI.val + 3 := by
    have ha := i32_add_val sh1I 3#i32 (by simp; omega) (by simp; omega)
    rw [ha, hsh1_val]; simp; omega
  -- c = ((n1.to_int64() * 963315389L) >> 47).to_int()
  have hn1_64 : (Pion.I32.to_int64 n1I).val = n1I.val := i32_to_int64_val n1I
  have hmul_c : (Pion.I64.mul (Pion.I32.to_int64 n1I) 963315389#i64).val = n1I.val * 963315389 := by
    have hm := i64_mul_val (Pion.I32.to_int64 n1I) 963315389#i64 (by rw [hn1_64]; simp; omega) (by rw [hn1_64]; simp; omega)
    rw [hm, hn1_64]; simp
  rcases i64_shr_i32_val (Pion.I64.mul (Pion.I32.to_int64 n1I) 963315389#i64) 47#i32 (by decide) (by decide) with ⟨c64I, hc64_eq, hc64_val⟩
  rw [hc64_eq, b_ok]
  have hc64_exact : c64I.val = n1I.val / 146097 := by
    have hpow : (2 ^ (47#i32).val.toNat : Int) = 140737488355328 := by decide
    rw [hc64_val, hmul_c, hpow]; omega
  set cI := Pion.I64.to_int c64I
  have hc_val : cI.val = n1I.val / 146097 := by
    rw [i64_to_int_val c64I (by omega) (by omega), hc64_exact]
  -- nc = (n1 - c * 146097) >> 2
  have hmul_c146 : (Pion.I32.mul cI 146097#i32).val = cI.val * 146097 := by
    simpa using i32_mul_val cI 146097#i32 (by simp; omega) (by simp; omega)
  have hsub_nc : (Pion.I32.sub n1I (Pion.I32.mul cI 146097#i32)).val = n1I.val - cI.val * 146097 := by
    rw [i32_sub_val n1I _ (by rw [hmul_c146]; omega) (by rw [hmul_c146]; omega), hmul_c146]
  rcases i32_shr_val (Pion.I32.sub n1I (Pion.I32.mul cI 146097#i32)) 2#i32 (by decide) (by decide) with ⟨ncI, hnc_eq, hnc_val⟩
  rw [hnc_eq, b_ok]
  have hnc_exact : ncI.val = (n1I.val - cI.val * 146097) / 4 := by
    have hp2_sh : (2 ^ (2#i32).val.toNat : Int) = 4 := by decide
    rw [hnc_val, hsub_nc, hp2_sh]
  -- n2 = (nc << 2) + 3
  rcases i32_shl_2_val ncI (by omega) (by omega) with ⟨sh2I, hsh2_eq, hsh2_val⟩
  rw [hsh2_eq, b_ok]
  set n2I := Pion.I32.add sh2I 3#i32
  have hn2_val : n2I.val = 4 * ncI.val + 3 := by
    have ha := i32_add_val sh2I 3#i32 (by simp; omega) (by simp; omega)
    rw [ha, hsh2_val]; simp; omega
  -- p2 = 2939745L * n2.to_int64()
  have hn2_64 : (Pion.I32.to_int64 n2I).val = n2I.val := i32_to_int64_val n2I
  set p2I := Pion.I64.mul 2939745#i64 (Pion.I32.to_int64 n2I)
  have hp2_val : p2I.val = 2939745 * n2I.val := by
    have hm := i64_mul_val 2939745#i64 (Pion.I32.to_int64 n2I) (by rw [hn2_64]; simp; omega) (by rw [hn2_64]; simp; omega)
    rw [hm, hn2_64]; simp
  -- z = (p2 >> 32).to_int()
  rcases i64_shr_i32_val p2I 32#i32 (by decide) (by decide) with ⟨z64I, hz64_eq, hz64_val⟩
  rw [hz64_eq, b_ok]
  have hz64_exact : z64I.val = n2I.val / 1461 := by
    have hpow : (2 ^ (32#i32).val.toNat : Int) = 4294967296 := by decide
    rw [hz64_val, hp2_val, hpow]; omega
  set zI := Pion.I64.to_int z64I
  have hz_val : zI.val = n2I.val / 1461 := by
    rw [i64_to_int_val z64I (by omega) (by omega), hz64_exact]
  -- ny = (((p2 & 4294967295L) * 1461L) >> 34).to_int()
  have hband_p2 : (Pion.I64.band p2I 4294967295#i64).val = p2I.val % 4294967296 :=
    i64_band_u32max_val p2I
  have hmul_ny : (Pion.I64.mul (Pion.I64.band p2I 4294967295#i64) 1461#i64).val =
      (p2I.val % 4294967296) * 1461 := by
    have hm := i64_mul_val (Pion.I64.band p2I 4294967295#i64) 1461#i64 (by rw [hband_p2]; simp; omega) (by rw [hband_p2]; simp; omega)
    rw [hm, hband_p2]; simp
  rcases i64_shr_i32_val (Pion.I64.mul (Pion.I64.band p2I 4294967295#i64) 1461#i64) 34#i32 (by decide) (by decide) with ⟨ny64I, hny64_eq, hny64_val⟩
  rw [hny64_eq, b_ok]
  have hny64_exact : ny64I.val = ncI.val - (1461 * zI.val) / 4 := by
    have hpow : (2 ^ (34#i32).val.toNat : Int) = 17179869184 := by decide
    have hp2_mod : (2939745 * n2I.val) % 4294967296 = 2939745 * n2I.val - 4294967296 * zI.val := by
      have hz_div : (2939745 * n2I.val) / 4294967296 = zI.val := by
        have hpow32 : (2 ^ (32#i32).val.toNat : Int) = 4294967296 := by decide
        rw [hz_val, ← hz64_exact, hz64_val, hp2_val, hpow32]
      omega
    rw [hny64_val, hmul_ny, hp2_val, hp2_mod, hpow]
    omega
  set nyI := Pion.I64.to_int ny64I
  have hny_val : nyI.val = ncI.val - (1461 * zI.val) / 4 := by
    rw [i64_to_int_val ny64I (by omega) (by omega), hny64_exact]
  -- y = 100 * c + z
  set yI := Pion.I32.add (Pion.I32.mul 100#i32 cI) zI
  have hy_val : yI.val = 100 * cI.val + zI.val := by
    have hm := i32_mul_val 100#i32 cI (by simp; omega) (by simp; omega)
    rw [i32_add_val _ zI (by rw [hm]; simp; omega) (by rw [hm]; simp; omega), hm]; simp
  -- n3 = 2141 * ny + 197913
  set n3I := Pion.I32.add (Pion.I32.mul 2141#i32 nyI) 197913#i32
  have hn3_val : n3I.val = 2141 * nyI.val + 197913 := by
    have hm := i32_mul_val 2141#i32 nyI (by simp; omega) (by simp; omega)
    rw [i32_add_val _ 197913#i32 (by rw [hm]; simp; omega) (by rw [hm]; simp; omega), hm]; simp
  -- m = n3 >> 16
  rcases i32_shr_val n3I 16#i32 (by decide) (by decide) with ⟨mI, hm_eq, hm_val⟩
  rw [hm_eq, b_ok]
  have hm_exact : mI.val = n3I.val / 65536 := by
    have hpow : (2 ^ (16#i32).val.toNat : Int) = 65536 := by decide
    rw [hm_val, hpow]
  -- d = ((n3 & 65535) * 31345) >> 26
  have hband_n3 : (Pion.I32.band n3I 65535#i32).val = n3I.val % 65536 :=
    i32_band_65535_val n3I
  have hmul_d : (Pion.I32.mul (Pion.I32.band n3I 65535#i32) 31345#i32).val =
      (n3I.val % 65536) * 31345 := by
    have hm := i32_mul_val (Pion.I32.band n3I 65535#i32) 31345#i32 (by rw [hband_n3]; simp; omega) (by rw [hband_n3]; simp; omega)
    rw [hm, hband_n3]; simp
  rcases i32_shr_val (Pion.I32.mul (Pion.I32.band n3I 65535#i32) 31345#i32) 26#i32 (by decide) (by decide) with ⟨dI, hd_eq, hd_val⟩
  rw [hd_eq, b_ok]
  have hd_exact : dI.val = ((n3I.val % 65536) * 31345) / 67108864 := by
    have hpow : (2 ^ (26#i32).val.toNat : Int) = 67108864 := by decide
    rw [hd_val, hmul_d, hpow]
  -- j, year, month, day
  set jI : Std.I32 := if nyI ≥ 306#i32 then 1#i32 else 0#i32
  set j : Int := if nyI.val ≥ 306 then 1 else 0
  have hj_val : jI.val = j := by
    simp only [jI, j]
    by_cases hge : nyI.val ≥ 306
    · have hge' : nyI ≥ 306#i32 := hge
      simp [hge, hge']
    · have hge' : ¬ (nyI ≥ 306#i32) := hge
      simp [hge, hge']
  set yearI := Pion.I32.add (Pion.I32.sub yI 32800#i32) jI
  have hyear_val : yearI.val = yI.val - 32800 + j := by
    have hs := i32_sub_val yI 32800#i32 (by simp; omega) (by simp; omega)
    rw [i32_add_val _ jI (by rw [hs]; simp; omega) (by rw [hs]; simp; omega), hs, hj_val]; simp
  set monthI : Std.I32 := if jI = 1#i32 then Pion.I32.sub mI 12#i32 else mI
  have hmonth_val : monthI.val = if j = 1 then mI.val - 12 else mI.val := by
    simp only [monthI]
    by_cases hj1 : j = 1
    · have hj1' : jI = 1#i32 := i32_ext (by rw [hj_val, hj1]; decide)
      simp only [hj1, hj1', ↓reduceIte]
      simpa using i32_sub_val mI 12#i32 (by simp; omega) (by simp; omega)
    · have hj1' : jI ≠ 1#i32 := fun h => hj1 (by have := congrArg IScalar.val h; rw [hj_val] at this; exact this)
      simp [hj1, hj1']
  have hday_val : (Pion.I32.add dI 1#i32).val = dI.val + 1 := by
    simpa using i32_add_val dI 1#i32 (by simp; omega) (by simp; omega)
  have hspec_eq : (yearI.val, monthI.val, (Pion.I32.add dI 1#i32).val) = specFromEpochDays days.val := by
    dsimp only [specFromEpochDays]
    rw [hyear_val, hmonth_val, hday_val]
    simp only [j, hy_val, hm_exact, hd_exact, hn3_val, hny_val, hz_val, hn2_val, hnc_exact, hc_val, hn1_val, hn_val]
  have hvalid_raw := (specFromEpochDays_valid_and_inv days.val hlo hhi).1
  have hvalid : ValidDate (Date.mk yearI monthI (Pion.I32.add dI 1#i32)) := by
    have h1 : (specFromEpochDays days.val).1 = yearI.val := (congrArg Prod.fst hspec_eq).symm
    have h2 : (specFromEpochDays days.val).2.1 = monthI.val := (congrArg (fun p => p.2.1) hspec_eq).symm
    have h3 : (specFromEpochDays days.val).2.2 = (Pion.I32.add dI 1#i32).val := (congrArg (fun p => p.2.2) hspec_eq).symm
    unfold ValidDate
    change -9999 ≤ (specFromEpochDays days.val).1 ∧ (specFromEpochDays days.val).1 ≤ 9999 ∧
      1 ≤ (specFromEpochDays days.val).2.1 ∧ (specFromEpochDays days.val).2.1 ≤ 12 ∧
      1 ≤ (specFromEpochDays days.val).2.2 ∧
      (specFromEpochDays days.val).2.2 ≤ specDaysInMonth (specFromEpochDays days.val).1 (specFromEpochDays days.val).2.1 at hvalid_raw
    rw [h1, h2, h3] at hvalid_raw
    exact hvalid_raw
  exact ⟨Date.mk yearI monthI (Pion.I32.add dI 1#i32), rfl, hspec_eq, hvalid⟩

/-- `Date.from_epoch_days` returns `Err` outside `[-4371587, 2932896]` without trapping. -/
theorem from_epoch_days_out_of_range (days : Std.I32) (h : ¬ ValidEpochDays days) :
    ∃ e : TimeError, Date.from_epoch_days days = ok (Pion.Res.Err e) := by
  unfold ValidEpochDays at h
  unfold Date.from_epoch_days
  have hout : ((decide (days < min_epoch_days)) || (decide (days > max_epoch_days))) = true := by
    by_cases h1 : days.val < -4371587
    · have h1' : days < min_epoch_days := h1
      simp [h1']
    · have h2 : days.val > 2932896 := by omega
      have h2' : days > max_epoch_days := h2
      simp [h2']
  simp only [hout, ↓reduceIte]
  unfold TimeError.new
  rw [b_ok]
  exact ⟨_, rfl⟩

/-- Strict monotonicity of `specEpochDays` on valid Gregorian dates. -/
theorem specEpochDays_strict_mono {y1 m1 d1 y2 m2 d2 : Int}
    (hv1 : -9999 ≤ y1 ∧ y1 ≤ 9999 ∧ 1 ≤ m1 ∧ m1 ≤ 12 ∧ 1 ≤ d1 ∧ d1 ≤ specDaysInMonth y1 m1)
    (hv2 : -9999 ≤ y2 ∧ y2 ≤ 9999 ∧ 1 ≤ m2 ∧ m2 ≤ 12 ∧ 1 ≤ d2 ∧ d2 ≤ specDaysInMonth y2 m2) :
    (y1 < y2 ∨ (y1 = y2 ∧ m1 < m2) ∨ (y1 = y2 ∧ m1 = m2 ∧ d1 < d2)) ↔
      specEpochDays y1 m1 d1 < specEpochDays y2 m2 d2 := by
  have haux : ∀ a1 b1 c1 a2 b2 c2 : Int,
      (-9999 ≤ a1 ∧ a1 ≤ 9999 ∧ 1 ≤ b1 ∧ b1 ≤ 12 ∧ 1 ≤ c1 ∧ c1 ≤ specDaysInMonth a1 b1) →
      (-9999 ≤ a2 ∧ a2 ≤ 9999 ∧ 1 ≤ b2 ∧ b2 ≤ 12 ∧ 1 ≤ c2 ∧ c2 ≤ specDaysInMonth a2 b2) →
      (a1 < a2 ∨ (a1 = a2 ∧ b1 < b2) ∨ (a1 = a2 ∧ b1 = b2 ∧ c1 < c2)) →
      specEpochDays a1 b1 c1 < specEpochDays a2 b2 c2 := by
    intro a1 b1 c1 a2 b2 c2 h1 h2 hlt
    rcases h1 with ⟨ha1a, ha1b, hb1a, hb1b, hc1a, hc1b⟩
    rcases h2 with ⟨ha2a, ha2b, hb2a, hb2b, hc2a, hc2b⟩
    -- Express specEpochDays cleanly in shifted coordinates (sy, sm, sd)
    set j1 : Int := if b1 ≤ 2 then 1 else 0
    set sy1 : Int := a1 + 32800 - j1
    set sm1 : Int := if j1 = 1 then b1 + 12 else b1
    set j2 : Int := if b2 ≤ 2 then 1 else 0
    set sy2 : Int := a2 + 32800 - j2
    set sm2 : Int := if j2 = 1 then b2 + 12 else b2
    have hsm1 : 3 ≤ sm1 ∧ sm1 ≤ 14 := by omega
    have hsm2 : 3 ≤ sm2 ∧ sm2 ≤ 14 := by omega
    have hday_in_y1 : 0 ≤ (979 * sm1 - 2919) / 32 + (c1 - 1) ∧
        (979 * sm1 - 2919) / 32 + (c1 - 1) ≤ (if IsLeapYear (sy1 - 32800 + 1) then 365 else 364) := by
      unfold specDaysInMonth at hc1b
      by_cases hfeb : b1 = 2
      · subst hfeb
        have : j1 = 1 := by simp [j1]
        have : sm1 = 14 := by simp [sm1, this]
        have : sy1 - 32800 + 1 = a1 := by omega
        rw [this]
        by_cases hl : IsLeapYear a1 <;> simp [hl] at hc1b ⊢ <;> omega
      · by_cases hle2 : b1 ≤ 2
        · have : b1 = 1 := by omega
          subst this; simp [j1, sm1] at *; split_ifs <;> omega
        · have : j1 = 0 := by simp [j1, hle2]
          have : sm1 = b1 := by simp [sm1, this]
          split_ifs at hc1b ⊢ <;> omega
    have hday_in_y2 : 0 ≤ (979 * sm2 - 2919) / 32 + (c2 - 1) := by omega
    unfold specEpochDays
    dsimp only
    show ((1461 * sy1) / 4 - sy1 / 100 + sy1 / 400) + (979 * sm1 - 2919) / 32 + (c1 - 1) - 12699422 <
         ((1461 * sy2) / 4 - sy2 / 100 + sy2 / 400) + (979 * sm2 - 2919) / 32 + (c2 - 1) - 12699422
    by_cases hsy_lt : sy1 < sy2
    · have h1 := ystar_step sy1
      have h2 := ystar_mono (sy1 + 1) sy2 (by omega)
      by_cases hl : IsLeapYear (sy1 - 32800 + 1) <;> simp only [hl, ↓reduceIte] at hday_in_y1 h1 <;> omega
    · have hsy_eq : sy1 = sy2 := by
        by_contra hne
        have : sy1 > sy2 := by omega
        omega
      rw [hsy_eq]
      have hsm_le : sm1 ≤ sm2 := by omega
      by_cases hsm_lt : sm1 < sm2
      · have hsm1_cases : sm1 = 3 ∨ sm1 = 4 ∨ sm1 = 5 ∨ sm1 = 6 ∨ sm1 = 7 ∨ sm1 = 8 ∨
                          sm1 = 9 ∨ sm1 = 10 ∨ sm1 = 11 ∨ sm1 = 12 ∨ sm1 = 13 := by omega
        unfold specDaysInMonth at hc1b
        rcases hsm1_cases with h | h | h | h | h | h | h | h | h | h | h <;>
          · simp only [h] at hc1b ⊢; split_ifs at hc1b <;> omega
      · have hsm_eq : sm1 = sm2 := by omega
        rw [hsm_eq]; omega
  constructor
  · exact haux y1 m1 d1 y2 m2 d2 hv1 hv2
  · intro hlt
    by_contra hnot
    by_cases heq : y1 = y2 ∧ m1 = m2 ∧ d1 = d2
    · rcases heq with ⟨rfl, rfl, rfl⟩; omega
    · have hgt : y2 < y1 ∨ (y2 = y1 ∧ m2 < m1) ∨ (y2 = y1 ∧ m2 = m1 ∧ d2 < d1) := by omega
      have := haux y2 m2 d2 y1 m1 d1 hv2 hv1 hgt
      omega

/-- Injectivity of `specEpochDays` on valid Gregorian dates (immediate from strict monotonicity). -/
private theorem specEpochDays_injective {y1 m1 d1 y2 m2 d2 : Int}
    (hv1 : -9999 ≤ y1 ∧ y1 ≤ 9999 ∧ 1 ≤ m1 ∧ m1 ≤ 12 ∧ 1 ≤ d1 ∧ d1 ≤ specDaysInMonth y1 m1)
    (hv2 : -9999 ≤ y2 ∧ y2 ≤ 9999 ∧ 1 ≤ m2 ∧ m2 ≤ 12 ∧ 1 ≤ d2 ∧ d2 ≤ specDaysInMonth y2 m2)
    (heq : specEpochDays y1 m1 d1 = specEpochDays y2 m2 d2) :
    y1 = y2 ∧ m1 = m2 ∧ d1 = d2 := by
  have h12 := (specEpochDays_strict_mono hv1 hv2).mpr
  have h21 := (specEpochDays_strict_mono hv2 hv1).mpr
  by_contra hne
  have hord : (y1 < y2 ∨ (y1 = y2 ∧ m1 < m2) ∨ (y1 = y2 ∧ m1 = m2 ∧ d1 < d2)) ∨
              (y2 < y1 ∨ (y2 = y1 ∧ m2 < m1) ∨ (y2 = y1 ∧ m2 = m1 ∧ d2 < d1)) := by omega
  rcases hord with hlt | hgt
  · have := (specEpochDays_strict_mono hv1 hv2).mp hlt; omega
  · have := (specEpochDays_strict_mono hv2 hv1).mp hgt; omega

/-- **Inverse roundtrip**: for every epoch day `z` in `[-4371587, 2932896]`,
    `Date.from_epoch_days z` produces a valid `Date d` such that `Date.to_epoch_days d = ok z`. -/
theorem to_epoch_days_from_epoch_days (z : Std.I32) (hz : ValidEpochDays z) :
    ∃ d : Date, Date.from_epoch_days z = ok (Pion.Res.Ok d) ∧
      ValidDate d ∧ Date.to_epoch_days d = ok z := by
  rcases from_epoch_days_spec z hz with ⟨d, hfrom, hspec, hvd⟩
  rcases to_epoch_days_spec d hvd with ⟨ed, hto, hed_val, _⟩
  have hinv := (specFromEpochDays_valid_and_inv z.val hz.1 hz.2).2
  change specEpochDays (specFromEpochDays z.val).1 (specFromEpochDays z.val).2.1 (specFromEpochDays z.val).2.2 = z.val at hinv
  have hy : d.year.val = (specFromEpochDays z.val).1 := congrArg Prod.fst hspec
  have hm : d.month.val = (specFromEpochDays z.val).2.1 := congrArg (fun p => p.2.1) hspec
  have hday : d.day.val = (specFromEpochDays z.val).2.2 := congrArg (fun p => p.2.2) hspec
  have hed_eq : ed = z := i32_ext (by rw [hed_val, hy, hm, hday]; exact hinv)
  exact ⟨d, hfrom, hvd, hed_eq ▸ hto⟩

/-- **Forward roundtrip**: for every valid `Date d` (`-9999-01-01 ..= 9999-12-31`),
    `Date.from_epoch_days (Date.to_epoch_days d) = ok (.Ok d)`. -/
theorem from_epoch_days_to_epoch_days (d : Date) (hd : ValidDate d) :
    ∃ ed : Std.I32, Date.to_epoch_days d = ok ed ∧
      Date.from_epoch_days ed = ok (Pion.Res.Ok d) := by
  rcases to_epoch_days_spec d hd with ⟨ed, hto, hed_val, hed_valid⟩
  rcases to_epoch_days_from_epoch_days ed hed_valid with ⟨d', hfrom, hvd', hto'⟩
  rcases to_epoch_days_spec d' hvd' with ⟨ed', hto'', hed'_val, _⟩
  have hed_same : ed' = ed := ok_inj (hto''.symm.trans hto')
  have hspec_eq : specEpochDays d'.year.val d'.month.val d'.day.val =
      specEpochDays d.year.val d.month.val d.day.val := by
    rw [← hed'_val, hed_same, hed_val]
  rcases specEpochDays_injective hvd' hd hspec_eq with ⟨hy, hm, hday⟩
  have hd_eq : d' = d := by
    cases d; cases d'
    congr 1
    · exact i32_ext hy
    · exact i32_ext hm
    · exact i32_ext hday
  exact ⟨ed, hto, hd_eq ▸ hfrom⟩


end TimeProofs
