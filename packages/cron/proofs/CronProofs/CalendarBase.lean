import CronProofs.Core

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace CronProofs

open cron

/-! ## Part 2: Proleptic Gregorian Calendar & `DateTime` Bijection -/

section Calendar

/-- Pure mathematical definition of a Gregorian leap year. -/
def isLeapYearMath (y : Int) : Bool :=
  (y % 4 == 0 && y % 100 != 0) || y % 400 == 0

/-- Pure mathematical definition of days in month `m` (1..=12) of year `y`. -/
def daysInMonthMath (y m : Int) : Int :=
  if m == 2 then
    if isLeapYearMath y then 29 else 28
  else if m == 4 || m == 6 || m == 9 || m == 11 then
    30
  else
    31

lemma i32_band_3_eq_zero_iff (y : Std.I32) :
    Pion.I32.band y 3#i32 = 0#i32 ↔ y.val % 4 = 0 := by
  constructor
  · intro h
    have hbv : y.bv &&& 3#32 = 0#32 := congrArg (fun u : Std.I32 => u.bv) h
    have hb0 : y.bv.getLsbD 0 = false := by
      have := congrArg (fun b : BitVec 32 => b.getLsbD 0) hbv
      simpa [BitVec.getLsbD_and] using this
    have hb1 : y.bv.getLsbD 1 = false := by
      have := congrArg (fun b : BitVec 32 => b.getLsbD 1) hbv
      simpa [BitVec.getLsbD_and] using this
    have h0 : y.bv.toNat % 2 = 0 := by
      simp [BitVec.getLsbD, Nat.testBit_zero] at hb0; omega
    have h1 : (y.bv.toNat / 2) % 2 = 0 := by
      simp [BitVec.getLsbD, Nat.testBit_succ, Nat.testBit_zero] at hb1; omega
    have hmod : y.bv.toNat % 4 = 0 := by omega
    have htoInt : y.val = if 2 * y.bv.toNat < 2 ^ 32 then (y.bv.toNat : Int) else (y.bv.toNat : Int) - 2 ^ 32 := by
      simp [IScalar.val, BitVec.toInt_eq_toNat_cond]
    rw [htoInt]
    split <;> omega
  · intro h
    have htoInt : y.val = if 2 * y.bv.toNat < 2 ^ 32 then (y.bv.toNat : Int) else (y.bv.toNat : Int) - 2 ^ 32 := by
      simp [IScalar.val, BitVec.toInt_eq_toNat_cond]
    rw [htoInt] at h
    have hmod : y.bv.toNat % 4 = 0 := by
      split at h <;> omega
    have hbv : y.bv &&& 3#32 = 0#32 := by
      apply BitVec.eq_of_getLsbD_eq
      intro i hi
      simp only [BitVec.getLsbD_and, BitVec.getLsbD_zero]
      have h3 : (3#32).getLsbD i = decide (i < 2) := by
        revert i hi; decide +kernel
      rw [h3]
      by_cases hlt : i < 2
      · have : i = 0 ∨ i = 1 := by omega
        rcases this with rfl | rfl
        · simp [BitVec.getLsbD, Nat.testBit_zero]; omega
        · simp [BitVec.getLsbD, Nat.testBit_succ, Nat.testBit_zero]; omega
      · simp [hlt]
    exact congrArg IScalar.mk hbv

lemma i32_band_15_eq_zero_iff (y : Std.I32) :
    Pion.I32.band y 15#i32 = 0#i32 ↔ y.val % 16 = 0 := by
  constructor
  · intro h
    have hbv : y.bv &&& 15#32 = 0#32 := congrArg (fun u : Std.I32 => u.bv) h
    have hb : ∀ i < 4, y.bv.getLsbD i = false := by
      intro i hi
      have h15 : (15#32).getLsbD i = true := by revert i hi; decide +kernel
      have := congrArg (fun b : BitVec 32 => b.getLsbD i) hbv
      simpa [BitVec.getLsbD_and, h15] using this
    have hb0 := hb 0 (by omega)
    have hb1 := hb 1 (by omega)
    have hb2 := hb 2 (by omega)
    have hb3 := hb 3 (by omega)
    simp [BitVec.getLsbD, Nat.testBit_succ, Nat.testBit_zero] at hb0 hb1 hb2 hb3
    have hmod : y.bv.toNat % 16 = 0 := by omega
    have htoInt : y.val = if 2 * y.bv.toNat < 2 ^ 32 then (y.bv.toNat : Int) else (y.bv.toNat : Int) - 2 ^ 32 := by
      simp [IScalar.val, BitVec.toInt_eq_toNat_cond]
    rw [htoInt]
    split <;> omega
  · intro h
    have htoInt : y.val = if 2 * y.bv.toNat < 2 ^ 32 then (y.bv.toNat : Int) else (y.bv.toNat : Int) - 2 ^ 32 := by
      simp [IScalar.val, BitVec.toInt_eq_toNat_cond]
    rw [htoInt] at h
    have hmod : y.bv.toNat % 16 = 0 := by
      split at h <;> omega
    have hbv : y.bv &&& 15#32 = 0#32 := by
      apply BitVec.eq_of_getLsbD_eq
      intro i hi
      simp only [BitVec.getLsbD_and, BitVec.getLsbD_zero]
      have h15 : (15#32).getLsbD i = decide (i < 4) := by
        revert i hi; decide +kernel
      rw [h15]
      by_cases hlt : i < 4
      · have : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 := by omega
        rcases this with rfl | rfl | rfl | rfl <;>
          simp [BitVec.getLsbD, Nat.testBit_succ, Nat.testBit_zero] <;> omega
      · simp [hlt]
    exact congrArg IScalar.mk hbv

/-- `is_leap_year` matches the standard Gregorian leap-year definition for all `Std.I32`. -/
theorem is_leap_year_spec (year : Std.I32) :
    is_leap_year year = ok (isLeapYearMath year.val) := by
  unfold is_leap_year isLeapYearMath
  by_cases h4 : Pion.I32.band year 3#i32 ≠ 0#i32
  · rw [ite_eq_left h4]
    have hne4 : year.val % 4 ≠ 0 := fun hc => h4 ((i32_band_3_eq_zero_iff year).mpr hc)
    congr 1
    have hne400 : year.val % 400 ≠ 0 := by omega
    have h1 : (year.val % 4 == 0) = false := beq_false_of_ne hne4
    have h2 : (year.val % 400 == 0) = false := beq_false_of_ne hne400
    rw [h1, h2]; rfl
  · rw [ite_eq_right h4]
    have hd4 : year.val % 4 = 0 := (i32_band_3_eq_zero_iff year).mp (not_not.mp h4)
    obtain ⟨r, hrem, hrval⟩ := i32_rem_ok year 25#i32 (by decide) (fun ⟨_, h⟩ => absurd h (by decide))
    rw [hrem, b_ok]
    congr 1
    have htmod : (r == 0#i32) = decide (year.val % 25 = 0) := by
      have h1 : (r == 0#i32) = decide (r.val = 0) := by
        cases h : (r == 0#i32)
        · have : r ≠ 0#i32 := by simpa using h
          have : r.val ≠ 0 := fun hv => this (i32_ext hv)
          simp [this]
        · have : r = 0#i32 := by simpa using h
          subst this; simp
      rw [h1, hrval]
      have htm : Int.tmod year.val 25 = 0 ↔ year.val % 25 = 0 := by
        rw [Int.tmod_eq_emod]
        split <;> omega
      exact decide_eq_decide.mpr htm
    have h16 : (Pion.I32.band year 15#i32 == 0#i32) = decide (year.val % 16 = 0) := by
      cases h : (Pion.I32.band year 15#i32 == 0#i32)
      · have hne : Pion.I32.band year 15#i32 ≠ 0#i32 := by simpa using h
        have : year.val % 16 ≠ 0 := fun hc => hne ((i32_band_15_eq_zero_iff year).mpr hc)
        simp [this]
      · have heq : Pion.I32.band year 15#i32 = 0#i32 := by simpa using h
        have : year.val % 16 = 0 := (i32_band_15_eq_zero_iff year).mp heq
        simp [this]
    have hneq : (r != 0#i32) = !decide (year.val % 25 = 0) := by
      simp [bne, htmod]
    rw [hneq, h16]
    by_cases h25 : year.val % 25 = 0
    · by_cases h16' : year.val % 16 = 0
      · have h400 : year.val % 400 = 0 := by omega
        simp [h25, h16', h400]
      · have h100 : year.val % 100 = 0 := by omega
        have h400 : year.val % 400 ≠ 0 := by omega
        simp [h25, h16', h100, h400]
    · have h100 : year.val % 100 ≠ 0 := by omega
      simp [hd4, h25, h100]

/-- Exact specification of `days_in_month` for all valid months `1 ≤ month ≤ 12`. -/
theorem days_in_month_spec (year month : Std.I32)
    (hm1 : 1 ≤ month.val) (hm12 : month.val ≤ 12) :
    ∃ d : Std.I32, days_in_month year month = ok d ∧
      d.val = daysInMonthMath year.val month.val ∧
      28 ≤ d.val ∧ d.val ≤ 31 ∧
      (month = 2#i32 → d.val = if isLeapYearMath year.val then 29 else 28) := by
  unfold days_in_month
  by_cases h2 : month = 2#i32
  · subst h2
    simp only [↓reduceIte]
    rw [is_leap_year_spec, b_ok]
    cases hl : isLeapYearMath year.val
    · refine ⟨28#i32, rfl, ?_, by simp, by simp, fun _ => by simp [hl]⟩
      simp [daysInMonthMath, hl]
    · refine ⟨29#i32, rfl, ?_, by simp, by simp, fun _ => by simp [hl]⟩
      simp [daysInMonthMath, hl]
  · simp only [h2, ↓reduceIte]
    have hm_ne2 : month.val ≠ 2 := fun hc => h2 (i32_ext hc)
    have hcases :
        month = 1#i32 ∨ month = 3#i32 ∨ month = 4#i32 ∨ month = 5#i32 ∨
        month = 6#i32 ∨ month = 7#i32 ∨ month = 8#i32 ∨ month = 9#i32 ∨
        month = 10#i32 ∨ month = 11#i32 ∨ month = 12#i32 := by
      have : month.val = 1 ∨ month.val = 3 ∨ month.val = 4 ∨ month.val = 5 ∨
             month.val = 6 ∨ month.val = 7 ∨ month.val = 8 ∨ month.val = 9 ∨
             month.val = 10 ∨ month.val = 11 ∨ month.val = 12 := by omega
      rcases this with h | h | h | h | h | h | h | h | h | h | h
      · exact Or.inl (i32_ext h)
      · exact Or.inr (Or.inl (i32_ext h))
      · exact Or.inr (Or.inr (Or.inl (i32_ext h)))
      · exact Or.inr (Or.inr (Or.inr (Or.inl (i32_ext h))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (i32_ext h)))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (i32_ext h))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (i32_ext h)))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (i32_ext h))))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (i32_ext h)))))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (i32_ext h))))))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (i32_ext h))))))))))
    have hshr : ∀ (m : Std.I32),
        (do let t ← Pion.I32.shr m 3#i32; ok (Pion.I32.add 30#i32 (Pion.I32.band (Pion.I32.add m t) 1#i32))) =
        ok (Pion.I32.add 30#i32 (Pion.I32.band (Pion.I32.add m ⟨m.bv.sshiftRight 3⟩) 1#i32)) := by
      intro m
      unfold Pion.I32.shr
      have h03 : 0 ≤ (3#i32).val ∧ (3#i32).val < 32 := by simp
      rw [ite_eq_left h03, b_ok]; rfl
    rcases hcases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
    · exact ⟨31#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩
    · exact ⟨31#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩
    · exact ⟨30#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩
    · exact ⟨31#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩
    · exact ⟨30#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩
    · exact ⟨31#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩
    · exact ⟨31#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩
    · exact ⟨30#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩
    · exact ⟨31#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩
    · exact ⟨30#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩
    · exact ⟨31#i32, by rw [hshr]; rfl, by unfold daysInMonthMath; rfl, by decide, by decide, fun hc => absurd hc (by decide)⟩

/-- Pure mathematical validity predicate for `DateTime`. -/
def DateTimeValid (dt : DateTime) : Prop :=
  1 ≤ dt.year.val ∧ dt.year.val ≤ 9999 ∧
  1 ≤ dt.month.val ∧ dt.month.val ≤ 12 ∧
  1 ≤ dt.day.val ∧ dt.day.val ≤ daysInMonthMath dt.year.val dt.month.val ∧
  0 ≤ dt.hour.val ∧ dt.hour.val ≤ 23 ∧
  0 ≤ dt.minute.val ∧ dt.minute.val ≤ 59 ∧
  0 ≤ dt.second.val ∧ dt.second.val ≤ 59

instance (dt : DateTime) : Decidable (DateTimeValid dt) := by
  unfold DateTimeValid; infer_instance

/-- `DateTime.is_valid` is total and decides `DateTimeValid` exactly. -/
theorem datetime_is_valid_spec (dt : DateTime) :
    DateTime.is_valid dt = ok (decide (DateTimeValid dt)) := by
  unfold DateTime.is_valid DateTimeValid MIN_YEAR MAX_YEAR
  by_cases hy : dt.year.val < 1 ∨ dt.year.val > 9999
  · have hc : ((decide (dt.year < 1#i32)) || (decide (dt.year > 9999#i32))) = true := by
      rcases hy with h | h
      · have : dt.year < 1#i32 := h; simp [this]
      · have : dt.year > 9999#i32 := h; simp [this]
    simp only [hc, ↓reduceIte]
    congr 1
    exact (decide_eq_false (by omega)).symm
  · have hc : ((decide (dt.year < 1#i32)) || (decide (dt.year > 9999#i32))) = false := by
      have h1 : ¬ dt.year < 1#i32 := fun h => hy (Or.inl h)
      have h2 : ¬ dt.year > 9999#i32 := fun h => hy (Or.inr h)
      simp [h1, h2]
    simp only [hc, Bool.false_eq_true, ↓reduceIte]
    by_cases hm : dt.month.val < 1 ∨ dt.month.val > 12
    · have hcm : ((decide (dt.month < 1#i32)) || (decide (dt.month > 12#i32))) = true := by
        rcases hm with h | h
        · have : dt.month < 1#i32 := h; simp [this]
        · have : dt.month > 12#i32 := h; simp [this]
      simp only [hcm, ↓reduceIte]
      congr 1
      exact (decide_eq_false (by omega)).symm
    · have hcm : ((decide (dt.month < 1#i32)) || (decide (dt.month > 12#i32))) = false := by
        have h1 : ¬ dt.month < 1#i32 := fun h => hm (Or.inl h)
        have h2 : ¬ dt.month > 12#i32 := fun h => hm (Or.inr h)
        simp [h1, h2]
      simp only [hcm, Bool.false_eq_true, ↓reduceIte]
      obtain ⟨dim, hdim, hdim_val, _, _, _⟩ := days_in_month_spec dt.year dt.month (by omega) (by omega)
      by_cases hd1 : dt.day < 1#i32
      · simp only [hd1, ↓reduceIte, b_ok]
        congr 1
        have : dt.day.val < 1 := hd1
        exact (decide_eq_false (by omega)).symm
      · simp only [hd1, ↓reduceIte, hdim, b_ok]
        have hd_ge1 : 1 ≤ dt.day.val := by
          have : ¬ dt.day.val < 1 := hd1; omega
        by_cases hd2 : dt.day > dim
        · simp only [decide_eq_true hd2, ↓reduceIte]
          congr 1
          have : dt.day.val > dim.val := hd2
          exact (decide_eq_false (by omega)).symm
        · simp only [decide_eq_false hd2, Bool.false_eq_true, ↓reduceIte]
          have hd_le : dt.day.val ≤ daysInMonthMath dt.year.val dt.month.val := by
            have : ¬ dt.day.val > dim.val := hd2; omega
          by_cases hh : dt.hour.val < 0 ∨ dt.hour.val > 23
          · have hch : ((decide (dt.hour < 0#i32)) || (decide (dt.hour > 23#i32))) = true := by
              rcases hh with h | h
              · have : dt.hour < 0#i32 := h; simp [this]
              · have : dt.hour > 23#i32 := h; simp [this]
            simp only [hch, ↓reduceIte]
            congr 1
            exact (decide_eq_false (by omega)).symm
          · have hch : ((decide (dt.hour < 0#i32)) || (decide (dt.hour > 23#i32))) = false := by
              have h1 : ¬ dt.hour < 0#i32 := fun h => hh (Or.inl h)
              have h2 : ¬ dt.hour > 23#i32 := fun h => hh (Or.inr h)
              simp [h1, h2]
            simp only [hch, Bool.false_eq_true, ↓reduceIte]
            by_cases hmi : dt.minute.val < 0 ∨ dt.minute.val > 59
            · have hcmi : ((decide (dt.minute < 0#i32)) || (decide (dt.minute > 59#i32))) = true := by
                rcases hmi with h | h
                · have : dt.minute < 0#i32 := h; simp [this]
                · have : dt.minute > 59#i32 := h; simp [this]
              simp only [hcmi, ↓reduceIte]
              congr 1
              exact (decide_eq_false (by omega)).symm
            · have hcmi : ((decide (dt.minute < 0#i32)) || (decide (dt.minute > 59#i32))) = false := by
                have h1 : ¬ dt.minute < 0#i32 := fun h => hmi (Or.inl h)
                have h2 : ¬ dt.minute > 59#i32 := fun h => hmi (Or.inr h)
                simp [h1, h2]
              simp only [hcmi, Bool.false_eq_true, ↓reduceIte]
              congr 1
              by_cases hs : 0 ≤ dt.second.val ∧ dt.second.val ≤ 59
              · have hs1 : dt.second >= 0#i32 := hs.1
                have hs2 : dt.second <= 59#i32 := hs.2
                simp only [decide_eq_true hs1, decide_eq_true hs2, Bool.and_self]
                exact (decide_eq_true ⟨by omega, by omega, by omega, by omega, hd_ge1, hd_le, by omega, by omega, by omega, by omega, hs.1, hs.2⟩).symm
              · have hsf : ((decide (dt.second >= 0#i32)) && (decide (dt.second <= 59#i32))) = false := by
                  by_cases hs1 : dt.second >= 0#i32
                  · have hs2 : ¬ dt.second <= 59#i32 := fun h => hs ⟨hs1, h⟩
                    simp [hs1, hs2]
                  · simp [hs1]
                rw [hsf]
                exact (decide_eq_false (by omega)).symm

/-- Red-team F5 guard: a valid `DateTime` has every field strictly `< 64` (no 64-bit shift wrap/trap). -/
lemma datetime_valid_shift_bounds (dt : DateTime) (h : DateTime.is_valid dt = ok true) :
    0 ≤ dt.second.val ∧ dt.second.val < 60 ∧
    0 ≤ dt.minute.val ∧ dt.minute.val < 60 ∧
    0 ≤ dt.hour.val ∧ dt.hour.val < 24 ∧
    1 ≤ dt.day.val ∧ dt.day.val ≤ 31 ∧
    1 ≤ dt.month.val ∧ dt.month.val ≤ 12 ∧
    1 ≤ dt.year.val ∧ dt.year.val ≤ 9999 := by
  rw [datetime_is_valid_spec] at h
  have hv : DateTimeValid dt := of_decide_eq_true (ok_inj h)
  obtain ⟨hy1, hy2, hm1, hm2, hd1, hd2, hh1, hh2, hmi1, hmi2, hs1, hs2⟩ := hv
  have hdim31 : daysInMonthMath dt.year.val dt.month.val ≤ 31 := by
    unfold daysInMonthMath
    split
    · split <;> omega
    · split <;> omega
  omega

/-! ### Pure integer Howard Hinnant civil-calendar bijection -/

/-- Pure integer Howard Hinnant `days_from_civil` (for `year ≥ 1`). -/
def daysFromCivilMath (year month day : Int) : Int :=
  let y := if month ≤ 2 then year - 1 else year
  let era := y / 400
  let yoe := y - era * 400
  let m_adj := if month > 2 then month - 3 else month + 9
  let doy := (153 * m_adj + 2) / 5 + day - 1
  let doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468

/-- Pure integer Howard Hinnant `civil_from_days` (for `z ≥ -719468`). -/
def civilFromDaysMath (z_in : Int) : Int × Int × Int :=
  let z := z_in + 719468
  let era := z / 146097
  let doe := z - era * 146097
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y := yoe + era * 400
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let d := doy - (153 * mp + 2) / 5 + 1
  let m := if mp < 10 then mp + 3 else mp - 9
  let yr := if m ≤ 2 then y + 1 else y
  (yr, m, d)

lemma tdiv_eq_ediv_of_nonneg (a b : Int) (ha : 0 ≤ a) (_hb : 0 < b) :
    Int.tdiv a b = a / b :=
  Int.tdiv_eq_ediv_of_nonneg ha

lemma i32_div_pos_ok (a b : Std.I32) (hb : 0 < b.val) :
    ∃ z : Std.I32, Pion.I32.div a b = ok z ∧ z.val = Int.tdiv a.val b.val :=
  i32_div_ok a b (by omega) (fun ⟨_, h⟩ => by omega)

lemma i64_div_pos_ok (a b : Std.I64) (hb : 0 < b.val) :
    ∃ z : Std.I64, Pion.I64.div a b = ok z ∧ z.val = Int.tdiv a.val b.val :=
  i64_div_ok a b (by omega) (fun ⟨_, h⟩ => by omega)

lemma doe_bounds_math (yoe doy : Int) (hy0 : 0 ≤ yoe) (hy399 : yoe ≤ 399)
    (hd0 : 0 ≤ doy) (hd365 : doy ≤ 365) :
    0 ≤ yoe * 365 + yoe / 4 - yoe / 100 + doy ∧
    yoe * 365 + yoe / 4 - yoe / 100 + doy ≤ 146096 := by omega

lemma dfc_range_math (year month day : Int)
    (hy1 : 1 ≤ year) (hy2 : year ≤ 9999)
    (hm1 : 1 ≤ month) (hm2 : month ≤ 12)
    (hd1 : 1 ≤ day) (hd2 : day ≤ daysInMonthMath year month) :
    -719162 ≤ daysFromCivilMath year month day ∧ daysFromCivilMath year month day ≤ 2932896 := by
  have hdim31 : daysInMonthMath year month ≤ 31 := by
    unfold daysInMonthMath; split <;> (try split) <;> omega
  have hdim2 : month = 2 → day ≤ 29 := by
    intro hm; rw [hm] at hd2; unfold daysInMonthMath at hd2
    simp only [beq_self_eq_true, ↓reduceIte] at hd2; split at hd2 <;> omega
  unfold daysFromCivilMath; dsimp only
  set y := if month ≤ 2 then year - 1 else year
  have hy_b : 0 ≤ y ∧ y ≤ 9999 := by omega
  set era := y / 400
  have hera_b : 0 ≤ era ∧ era ≤ 24 := by omega
  set yoe := y - era * 400
  have hyoe_b : 0 ≤ yoe ∧ yoe ≤ 399 := by omega
  set m_adj := if month > 2 then month - 3 else month + 9
  have hm_b : 0 ≤ m_adj ∧ m_adj ≤ 11 := by omega
  set doy := (153 * m_adj + 2) / 5 + day - 1
  have hdoy_b : 0 ≤ doy ∧ doy ≤ 365 := by
    by_cases hm2eq : month = 2
    · have := hdim2 hm2eq; omega
    · omega
  set doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
  have hdoe_b := doe_bounds_math yoe doy hyoe_b.1 hyoe_b.2 hdoy_b.1 hdoy_b.2
  have hlow : 306 ≤ era * 146097 + doe := by
    by_cases hy0 : y = 0
    · have : month ≤ 2 := by omega
      have : m_adj ≥ 10 := by omega
      have : doy ≥ 306 := by omega
      have : era = 0 := by omega
      have : yoe = 0 := by omega
      omega
    · have : y ≥ 1 := by omega
      have : era ≥ 1 ∨ yoe ≥ 1 := by omega
      rcases this with h1 | h2
      · omega
      · have : yoe * 365 + yoe / 4 - yoe / 100 ≥ 365 := by omega
        omega
  have hhigh : era * 146097 + doe ≤ 3652364 := by
    by_cases hy9999 : y = 9999
    · have : month > 2 := by omega
      have : m_adj ≤ 9 := by omega
      have : doy ≤ 305 := by omega
      have : era = 24 := by omega
      have : yoe = 399 := by omega
      omega
    · have : y ≤ 9998 := by omega
      by_cases he24 : era = 24
      · have : yoe ≤ 398 := by omega
        have : yoe * 365 + yoe / 4 - yoe / 100 ≤ 398 * 365 + 99 - 3 := by omega
        omega
      · have : era ≤ 23 := by omega
        omega
  omega

/-- `days_from_civil` computes `daysFromCivilMath` without trap or overflow on valid dates. -/
theorem days_from_civil_eq (year month day : Std.I32)
    (hy1 : 1 ≤ year.val) (hy2 : year.val ≤ 9999)
    (hm1 : 1 ≤ month.val) (hm2 : month.val ≤ 12)
    (hd1 : 1 ≤ day.val) (hd2 : day.val ≤ daysInMonthMath year.val month.val) :
    ∃ r : Std.I64, days_from_civil year month day = ok r ∧
      r.val = daysFromCivilMath year.val month.val day.val ∧
      -719162 ≤ r.val ∧ r.val ≤ 2932896 := by
  have hrange := dfc_range_math year.val month.val day.val hy1 hy2 hm1 hm2 hd1 hd2
  have hdim31 : daysInMonthMath year.val month.val ≤ 31 := by
    unfold daysInMonthMath; split <;> (try split) <;> omega
  have hdim2 : month.val = 2 → day.val ≤ 29 := by
    intro hm2eq; rw [hm2eq] at hd2; unfold daysInMonthMath at hd2
    simp only [beq_self_eq_true, ↓reduceIte] at hd2; split at hd2 <;> omega
  unfold days_from_civil
  set y : Std.I32 := if month <= 2#i32 then Pion.I32.sub year 1#i32 else year
  have hy_val : y.val = if month.val ≤ 2 then year.val - 1 else year.val := by
    dsimp only [y]
    by_cases h : month.val ≤ 2
    · have h' : month <= 2#i32 := h
      rw [ite_eq_left h', ite_eq_left h, i32_sub_val]
      all_goals (have hc : (1#i32).val = 1 := (by simp); rw [hc]; try omega)
    · have h' : ¬ (month <= 2#i32) := h
      rw [ite_eq_right h', ite_eq_right h]
  have hy_b : 0 ≤ y.val ∧ y.val ≤ 9999 := by omega
  have hy_ge0' : y >= 0#i32 := hy_b.1
  simp only [hy_ge0', ↓reduceIte]
  obtain ⟨era, hera, hera_val⟩ := i32_div_pos_ok y 400#i32 (by simp)
  rw [hera, b_ok, b_ok]
  have hera_ediv : era.val = y.val / 400 := by
    rw [hera_val]; exact tdiv_eq_ediv_of_nonneg y.val 400 hy_b.1 (by omega)
  have hera_b : 0 ≤ era.val ∧ era.val ≤ 24 := by
    have : 0 ≤ y.val / 400 ∧ y.val / 400 ≤ 24 := by omega
    omega
  have h_era400 : (Pion.I32.mul era 400#i32).val = era.val * 400 := by
    rw [i32_mul_val]; all_goals (have hc : (400#i32).val = 400 := (by simp); rw [hc]; try omega)
  set yoe : Std.I32 := Pion.I32.sub y (Pion.I32.mul era 400#i32)
  have hyoe_val : yoe.val = y.val - era.val * 400 := by
    dsimp only [yoe]; rw [i32_sub_val, h_era400] <;> omega
  have hyoe_b : 0 ≤ yoe.val ∧ yoe.val ≤ 399 := by
    have : 0 ≤ y.val - (y.val / 400) * 400 ∧ y.val - (y.val / 400) * 400 ≤ 399 := by omega
    omega
  set m_adj : Std.I32 := if month > 2#i32 then Pion.I32.sub month 3#i32 else Pion.I32.add month 9#i32
  have hm_adj_val : m_adj.val = if month.val > 2 then month.val - 3 else month.val + 9 := by
    dsimp only [m_adj]
    by_cases h : month.val > 2
    · have h' : month > 2#i32 := h
      rw [ite_eq_left h', ite_eq_left h, i32_sub_val]
      all_goals (have hc : (3#i32).val = 3 := (by simp); rw [hc]; try omega)
    · have h' : ¬ (month > 2#i32) := h
      rw [ite_eq_right h', ite_eq_right h, i32_add_val]
      all_goals (have hc : (9#i32).val = 9 := (by simp); rw [hc]; try omega)
  have hm_adj_b : 0 ≤ m_adj.val ∧ m_adj.val ≤ 11 := by omega
  have h153m : (Pion.I32.mul 153#i32 m_adj).val = 153 * m_adj.val := by
    rw [i32_mul_val]; all_goals (have hc : (153#i32).val = 153 := (by simp); rw [hc]; try omega)
  have hm153 : (Pion.I32.add (Pion.I32.mul 153#i32 m_adj) 2#i32).val = 153 * m_adj.val + 2 := by
    rw [i32_add_val, h153m]; all_goals (have hc : (2#i32).val = 2 := (by simp); rw [hc]; try omega)
  obtain ⟨t3, ht3, ht3_val⟩ := i32_div_pos_ok (Pion.I32.add (Pion.I32.mul 153#i32 m_adj) 2#i32) 5#i32 (by simp)
  rw [ht3, b_ok]
  have ht3_ediv : t3.val = (153 * m_adj.val + 2) / 5 := by
    rw [ht3_val, hm153]; exact tdiv_eq_ediv_of_nonneg _ 5 (by omega) (by omega)
  have ht3_b : 0 ≤ t3.val ∧ t3.val ≤ 337 := by
    have : 0 ≤ (153 * m_adj.val + 2) / 5 ∧ (153 * m_adj.val + 2) / 5 ≤ 337 := by omega
    omega
  have ht3d : (Pion.I32.add t3 day).val = t3.val + day.val := by
    rw [i32_add_val] <;> omega
  set doy : Std.I32 := Pion.I32.sub (Pion.I32.add t3 day) 1#i32
  have hdoy_val : doy.val = (153 * m_adj.val + 2) / 5 + day.val - 1 := by
    dsimp only [doy]; rw [i32_sub_val, ht3d, ht3_ediv]
    all_goals (have hc : (1#i32).val = 1 := (by simp); rw [hc]; try omega)
  have hdoy_b : 0 ≤ doy.val ∧ doy.val ≤ 365 := by
    by_cases hm2eq : month.val = 2
    · have h29 := hdim2 hm2eq
      have : m_adj.val = 11 := by omega
      have : (153 * m_adj.val + 2) / 5 = 337 := by omega
      omega
    · have : m_adj.val ≤ 10 := by omega
      have : (153 * m_adj.val + 2) / 5 ≤ 306 := by omega
      omega
  obtain ⟨t4, ht4, ht4_val⟩ := i32_div_pos_ok yoe 4#i32 (by simp)
  rw [ht4, b_ok]
  have ht4_ediv : t4.val = yoe.val / 4 := by
    rw [ht4_val]; exact tdiv_eq_ediv_of_nonneg _ 4 hyoe_b.1 (by omega)
  have ht4_b : 0 ≤ t4.val ∧ t4.val ≤ 99 := by
    have : 0 ≤ yoe.val / 4 ∧ yoe.val / 4 ≤ 99 := by omega
    omega
  obtain ⟨t5, ht5, ht5_val⟩ := i32_div_pos_ok yoe 100#i32 (by simp)
  rw [ht5, b_ok]
  have ht5_ediv : t5.val = yoe.val / 100 := by
    rw [ht5_val]; exact tdiv_eq_ediv_of_nonneg _ 100 hyoe_b.1 (by omega)
  have ht5_b : 0 ≤ t5.val ∧ t5.val ≤ 3 := by
    have : 0 ≤ yoe.val / 100 ∧ yoe.val / 100 ≤ 3 := by omega
    omega
  have h_yoe365 : (Pion.I32.mul yoe 365#i32).val = yoe.val * 365 := by
    rw [i32_mul_val]; all_goals (have hc : (365#i32).val = 365 := (by simp); rw [hc]; try omega)
  have h_yoe_a : (Pion.I32.add (Pion.I32.mul yoe 365#i32) t4).val = yoe.val * 365 + t4.val := by
    rw [i32_add_val, h_yoe365] <;> omega
  have h_yoe_b : (Pion.I32.sub (Pion.I32.add (Pion.I32.mul yoe 365#i32) t4) t5).val =
      yoe.val * 365 + t4.val - t5.val := by
    rw [i32_sub_val, h_yoe_a] <;> omega
  set doe : Std.I32 := Pion.I32.add (Pion.I32.sub (Pion.I32.add (Pion.I32.mul yoe 365#i32) t4) t5) doy
  have hdoe_val : doe.val = yoe.val * 365 + yoe.val / 4 - yoe.val / 100 + doy.val := by
    dsimp only [doe]; rw [i32_add_val, h_yoe_b, ht4_ediv, ht5_ediv] <;> omega
  have hdoe_b : 0 ≤ doe.val ∧ doe.val ≤ 146096 := by
    rw [hdoe_val]; exact doe_bounds_math yoe.val doy.val hyoe_b.1 hyoe_b.2 hdoy_b.1 hdoy_b.2
  have h_era146 : (Pion.I32.mul era 146097#i32).val = era.val * 146097 := by
    rw [i32_mul_val]; all_goals (have hc : (146097#i32).val = 146097 := (by simp); rw [hc]; try omega)
  have h_ed : (Pion.I32.add (Pion.I32.mul era 146097#i32) doe).val = era.val * 146097 + doe.val := by
    rw [i32_add_val, h_era146] <;> omega
  set res : Std.I64 := Pion.I32.to_int64 (Pion.I32.sub (Pion.I32.add (Pion.I32.mul era 146097#i32) doe) 719468#i32)
  have hres_val : res.val = era.val * 146097 + doe.val - 719468 := by
    dsimp only [res]; rw [i32_to_i64_val, i32_sub_val, h_ed]
    all_goals (have hc : (719468#i32).val = 719468 := (by simp); rw [hc]; try omega)
  have hres_eq : res.val = daysFromCivilMath year.val month.val day.val := by
    unfold daysFromCivilMath; dsimp only
    rw [hres_val, hdoe_val, hdoy_val, hyoe_val, hera_ediv, hy_val, hm_adj_val]
  refine ⟨res, rfl, hres_eq, ?_, ?_⟩ <;> omega

def yoeLen (yoe : Int) : Int :=
  if (yoe + 1) % 4 == 0 && (yoe + 1) % 100 != 0 || yoe == 399 then 366 else 365

def yoeStart (yoe : Int) : Int :=
  365 * yoe + yoe / 4 - yoe / 100

def yoeOfDoe (doe : Int) : Int :=
  (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365

lemma yoeLen_eq_366_iff (yoe : Int) :
    yoeLen yoe = 366 ↔ ((yoe + 1) % 4 = 0 ∧ (yoe + 1) % 100 ≠ 0) ∨ yoe = 399 := by
  unfold yoeLen
  by_cases h : ((yoe + 1) % 4 == 0 && (yoe + 1) % 100 != 0 || yoe == 399) = true
  · rw [ite_eq_left h]
    simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, bne_iff_ne] at h
    exact ⟨fun _ => h, fun _ => rfl⟩
  · rw [ite_eq_right h]
    simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, bne_iff_ne] at h
    exact ⟨fun hc => absurd hc (by omega), fun hc => absurd hc h⟩

lemma yoeLen_cases (yoe : Int) :
    yoeLen yoe = 365 ∨ yoeLen yoe = 366 := by
  unfold yoeLen; split <;> simp

lemma yoeOfDoe_yoeStart (yoe doy : Int)
    (hy0 : 0 ≤ yoe) (hy399 : yoe ≤ 399)
    (hd0 : 0 ≤ doy) (hdlen : doy < yoeLen yoe) :
    yoeOfDoe (yoeStart yoe + doy) = yoe := by
  have hdoy_365 : doy ≤ 365 := by
    rcases yoeLen_cases yoe with h | h <;> omega
  have hlen365 : doy = 365 → ((yoe + 1) % 4 = 0 ∧ (yoe + 1) % 100 ≠ 0) ∨ yoe = 399 := by
    intro h365
    have : yoeLen yoe = 366 := by rcases yoeLen_cases yoe with h | h <;> omega
    exact (yoeLen_eq_366_iff yoe).mp this
  let doe := yoeStart yoe + doy
  have hdoe_def : doe = 365 * yoe + yoe / 4 - yoe / 100 + doy := rfl
  have hq146096 : doe / 146096 = if yoe = 399 ∧ doy = 365 then 1 else 0 := by
    by_cases h : yoe = 399 ∧ doy = 365
    · rw [ite_eq_left h]; obtain ⟨rfl, rfl⟩ := h; rw [hdoe_def]; omega
    · rw [ite_eq_right h]; omega
  have hq36524 : doe / 36524 = if yoe = 399 ∧ doy = 365 then 4 else yoe / 100 := by
    by_cases h : yoe = 399 ∧ doy = 365
    · rw [ite_eq_left h]; obtain ⟨rfl, rfl⟩ := h; rw [hdoe_def]; omega
    · rw [ite_eq_right h]
      by_cases h99 : yoe = 99
      · have : doy ≤ 364 := by
          by_cases h365 : doy = 365
          · have := hlen365 h365; omega
          · omega
        omega
      · by_cases h199 : yoe = 199
        · have : doy ≤ 364 := by
            by_cases h365 : doy = 365
            · have := hlen365 h365; omega
            · omega
          omega
        · by_cases h299 : yoe = 299
          · have : doy ≤ 364 := by
              by_cases h365 : doy = 365
              · have := hlen365 h365; omega
              · omega
            omega
          · omega
  have hq1460 : doe / 1460 = yoe / 4 ∨ (doe / 1460 = yoe / 4 + 1 ∧ doy ≥ 1) := by
    by_cases hge : 1460 * (yoe / 4 + 1) ≤ doe
    · right; exact ⟨by omega, by omega⟩
    · left; omega
  change (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 = yoe
  rw [hq146096, hq36524]
  by_cases h : yoe = 399 ∧ doy = 365
  · rw [ite_eq_left h, ite_eq_left h]; obtain ⟨rfl, rfl⟩ := h; rw [hdoe_def]; omega
  · rw [ite_eq_right h, ite_eq_right h]
    rcases hq1460 with hq | ⟨hq, hd1⟩
    · rw [hq]
      by_cases h365 : doy = 365
      · have hmod : (yoe + 1) % 4 = 0 := by rcases hlen365 h365 with ⟨a, _⟩ | b <;> omega
        have hge : 1460 * (yoe / 4 + 1) ≤ doe := by omega
        omega
      · omega
    · rw [hq]; omega

lemma yoeOfDoe_bounds (doe : Int) (h0 : 0 ≤ doe) (h1 : doe ≤ 146096) :
    let yoe := yoeOfDoe doe
    0 ≤ yoe ∧ yoe ≤ 399 ∧ 0 ≤ doe - yoeStart yoe ∧ doe - yoeStart yoe < yoeLen yoe := by
  dsimp only
  have hnext : ∀ y : Int, 0 ≤ y → y ≤ 399 →
      yoeStart (y + 1) = yoeStart y + yoeLen y ∨ (y = 399 ∧ yoeStart y + yoeLen y = 146097) := by
    intro y hy0 hy399
    by_cases h399 : y = 399
    · right; subst h399; exact ⟨rfl, by unfold yoeStart yoeLen; decide⟩
    · left
      by_cases hl : ((y + 1) % 4 = 0 ∧ (y + 1) % 100 ≠ 0) ∨ y = 399
      · have h366 : yoeLen y = 366 := (yoeLen_eq_366_iff y).mpr hl
        rw [h366]; unfold yoeStart; omega
      · have h365 : yoeLen y = 365 := by
          rcases yoeLen_cases y with h | h
          · exact h
          · exact absurd ((yoeLen_eq_366_iff y).mp h) hl
        rw [h365]; unfold yoeStart; omega
  have hex : ∀ (n : Nat), n ≤ 400 → doe < yoeStart n →
      ∃ y : Int, 0 ≤ y ∧ y < n ∧ yoeStart y ≤ doe ∧ doe < yoeStart y + yoeLen y := by
    intro n
    induction n with
    | zero => intro _ hlt; unfold yoeStart at hlt; omega
    | succ k ih =>
      intro hk hlt
      by_cases hlt_k : doe < yoeStart k
      · obtain ⟨y, hy0, hyk, hlo, hhi⟩ := ih (by omega) hlt_k
        exact ⟨y, hy0, by omega, hlo, hhi⟩
      · refine ⟨k, by omega, by omega, by omega, ?_⟩
        rcases hnext k (by omega) (by omega) with heq | ⟨hk399, h146⟩
        · have : ((k + 1 : Nat) : Int) = (k : Int) + 1 := by omega
          rw [this, heq] at hlt; exact hlt
        · omega
  by_cases h146 : doe = 146096
  · subst h146; unfold yoeOfDoe yoeStart yoeLen; decide
  · have h400 : doe < yoeStart (400 : Nat) := by
      have : yoeStart (400 : Nat) = 146096 := by unfold yoeStart; omega
      omega
    obtain ⟨y, hy0, hy400, hlo, hhi⟩ := hex 400 (by omega) h400
    have hyoe_eq : yoeOfDoe doe = y := by
      have hsub : doe = yoeStart y + (doe - yoeStart y) := by omega
      rw [hsub]
      exact yoeOfDoe_yoeStart y (doe - yoeStart y) hy0 (by omega) (by omega) (by omega)
    rw [hyoe_eq]
    exact ⟨hy0, by omega, by omega, by omega⟩

/-- Isolated month/day inverse within a March-based year (`0 ≤ doy ≤ 365`). -/
lemma doy_mp_spec (doy : Int) (h0 : 0 ≤ doy) (h1 : doy ≤ 365) :
    let mp := (5 * doy + 2) / 153
    let d := doy - (153 * mp + 2) / 5 + 1
    let m := if mp < 10 then mp + 3 else mp - 9
    0 ≤ mp ∧ mp ≤ 11 ∧ 1 ≤ m ∧ m ≤ 12 ∧ 1 ≤ d ∧
    (if m > 2 then m - 3 else m + 9) = mp ∧
    (m ≠ 2 → d ≤ daysInMonthMath 2001 m) ∧
    (m = 2 → (doy ≤ 364 → d ≤ 28) ∧ d ≤ 29) := by
  dsimp only
  have hmp_b : 0 ≤ (5 * doy + 2) / 153 ∧ (5 * doy + 2) / 153 ≤ 11 := by omega
  have hmp_c : (5 * doy + 2) / 153 = 0 ∨ (5 * doy + 2) / 153 = 1 ∨ (5 * doy + 2) / 153 = 2 ∨
      (5 * doy + 2) / 153 = 3 ∨ (5 * doy + 2) / 153 = 4 ∨ (5 * doy + 2) / 153 = 5 ∨
      (5 * doy + 2) / 153 = 6 ∨ (5 * doy + 2) / 153 = 7 ∨ (5 * doy + 2) / 153 = 8 ∨
      (5 * doy + 2) / 153 = 9 ∨ (5 * doy + 2) / 153 = 10 ∨ (5 * doy + 2) / 153 = 11 := by omega
  rcases hmp_c with h | h | h | h | h | h | h | h | h | h | h | h <;>
    rw [h] <;>
    (refine ⟨by omega, by omega, by omega, by omega, by omega, by omega, ?_, ?_⟩
     · intro _; unfold daysInMonthMath; simp; omega
     · intro hm; omega)

lemma daysInMonthMath_nonfeb (y1 y2 m : Int) (hm : m ≠ 2) :
    daysInMonthMath y1 m = daysInMonthMath y2 m := by
  unfold daysInMonthMath
  have h : (m == 2) = false := beq_false_of_ne hm
  simp [h]

lemma leap_iff_yoe (era yoe : Int) (hy0 : 0 ≤ yoe) (hy399 : yoe ≤ 399) :
    isLeapYearMath (yoe + era * 400 + 1) = decide (yoeLen yoe = 366) := by
  unfold isLeapYearMath
  by_cases h : yoeLen yoe = 366
  · rw [decide_eq_true h]
    have h1 := (yoeLen_eq_366_iff yoe).mp h
    simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, bne_iff_ne]
    omega
  · rw [decide_eq_false h]
    have h1 : ¬ (((yoe + 1) % 4 = 0 ∧ (yoe + 1) % 100 ≠ 0) ∨ yoe = 399) :=
      fun hc => h ((yoeLen_eq_366_iff yoe).mpr hc)
    simp only [Bool.or_eq_false_iff, Bool.and_eq_false_iff, beq_eq_false_iff_ne, bne_eq_false_iff_eq]
    by_cases h4 : (yoe + era * 400 + 1) % 4 = 0
    · constructor
      · right; omega
      · omega
    · exact ⟨Or.inl h4, by omega⟩



end Calendar

end CronProofs
