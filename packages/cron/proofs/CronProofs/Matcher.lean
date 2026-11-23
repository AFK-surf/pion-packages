import CronProofs.Bitmask
import CronProofs.CalendarBijection

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace CronProofs

open cron

/-! ## Part 3: Bitmask Matcher Safety Guards (`matches_fixed_fields`, `matches_day`) -/

section MatcherGuards

private theorem u64_shr_and_one_eq_zero_iff (m : Std.U64) (k : Nat) (hk : k < 64) :
    Pion.U64.band ⟨m.bv >>> k⟩ 1#u64 = 0#u64 ↔ m.bv.getLsbD k = false := by
  rw [u64_band_eq_zero_iff]
  constructor
  · intro h
    have h0 := h 0 (by omega) (by decide)
    simpa [BitVec.getLsbD_ushiftRight] using h0
  · intro h i hi h1
    have hi0 : i = 0 := by
      have : (1#64).getLsbD i = decide (i < 1) := mask_lo1 i hi
      change (1#64).getLsbD i = true at h1
      rw [this] at h1
      have := of_decide_eq_true h1
      omega
    subst hi0
    simpa [BitVec.getLsbD_ushiftRight] using h

/-- Red-team F5 guard: `matches_fixed_fields` returns `ok false` on every invalid `DateTime`. -/
theorem matches_fixed_fields_rejects_invalid (c : Cron) (dt : DateTime)
    (hinv : DateTime.is_valid dt = ok false) :
    matches_fixed_fields c dt = ok false := by
  unfold matches_fixed_fields
  rw [hinv, b_ok]
  simp

/-- Red-team F5 guard: `matches_day` returns `ok false` on every invalid `DateTime`. -/
theorem matches_day_rejects_invalid (c : Cron) (dt : DateTime)
    (hinv : DateTime.is_valid dt = ok false) :
    matches_day c dt = ok false := by
  unfold matches_day
  rw [hinv, b_ok]
  simp

/-- On every valid `DateTime`, `matches_fixed_fields` never traps (all shifts `< 64`)
    and matches the exact 4-field bitmask test. -/
theorem matches_fixed_fields_valid_exact (c : Cron) (dt : DateTime)
    (hv : DateTime.is_valid dt = ok true) :
    matches_fixed_fields c dt = ok (
      c.seconds_mask.bv.getLsbD dt.second.val.toNat &&
      c.minutes_mask.bv.getLsbD dt.minute.val.toNat &&
      c.hours_mask.bv.getLsbD dt.hour.val.toNat &&
      c.months_mask.bv.getLsbD dt.month.val.toNat) := by
  have hb := datetime_valid_shift_bounds dt hv
  obtain ⟨hs0, hs60, hmi0, hmi60, hh0, hh24, _, _, hm1, hm12, _, _⟩ := hb
  unfold matches_fixed_fields
  rw [hv, b_ok]
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte]
  rw [u64_shr_i32_ok c.seconds_mask dt.second hs0 (by omega), b_ok]
  by_cases hs : c.seconds_mask.bv.getLsbD dt.second.val.toNat = false
  · have h0 := (u64_shr_and_one_eq_zero_iff c.seconds_mask dt.second.val.toNat (by omega)).mpr hs
    simp only [h0, hs, ↓reduceIte, Bool.false_and]
  · have hst : c.seconds_mask.bv.getLsbD dt.second.val.toNat = true := Bool.eq_true_of_not_eq_false hs
    have hne : Pion.U64.band ⟨c.seconds_mask.bv >>> dt.second.val.toNat⟩ 1#u64 ≠ 0#u64 := by
      intro h0
      exact hs ((u64_shr_and_one_eq_zero_iff c.seconds_mask dt.second.val.toNat (by omega)).mp h0)
    simp only [hne, ↓reduceIte, hst, Bool.true_and]
    rw [u64_shr_i32_ok c.minutes_mask dt.minute hmi0 (by omega), b_ok]
    by_cases hmi : c.minutes_mask.bv.getLsbD dt.minute.val.toNat = false
    · have h0 := (u64_shr_and_one_eq_zero_iff c.minutes_mask dt.minute.val.toNat (by omega)).mpr hmi
      simp only [h0, hmi, ↓reduceIte, Bool.false_and]
    · have hmit : c.minutes_mask.bv.getLsbD dt.minute.val.toNat = true := Bool.eq_true_of_not_eq_false hmi
      have hne2 : Pion.U64.band ⟨c.minutes_mask.bv >>> dt.minute.val.toNat⟩ 1#u64 ≠ 0#u64 := by
        intro h0
        exact hmi ((u64_shr_and_one_eq_zero_iff c.minutes_mask dt.minute.val.toNat (by omega)).mp h0)
      simp only [hne2, ↓reduceIte, hmit, Bool.true_and]
      rw [u64_shr_i32_ok c.hours_mask dt.hour hh0 (by omega), b_ok]
      by_cases hh : c.hours_mask.bv.getLsbD dt.hour.val.toNat = false
      · have h0 := (u64_shr_and_one_eq_zero_iff c.hours_mask dt.hour.val.toNat (by omega)).mpr hh
        simp only [h0, hh, ↓reduceIte, Bool.false_and]
      · have hht : c.hours_mask.bv.getLsbD dt.hour.val.toNat = true := Bool.eq_true_of_not_eq_false hh
        have hne3 : Pion.U64.band ⟨c.hours_mask.bv >>> dt.hour.val.toNat⟩ 1#u64 ≠ 0#u64 := by
          intro h0
          exact hh ((u64_shr_and_one_eq_zero_iff c.hours_mask dt.hour.val.toNat (by omega)).mp h0)
        simp only [hne3, ↓reduceIte, hht, Bool.true_and]
        rw [u64_shr_i32_ok c.months_mask dt.month (by omega) (by omega), b_ok]
        congr 1
        cases hm : c.months_mask.bv.getLsbD dt.month.val.toNat
        · have h0 := (u64_shr_and_one_eq_zero_iff c.months_mask dt.month.val.toNat (by omega)).mpr hm
          rw [h0]; rfl
        · have hne4 : Pion.U64.band ⟨c.months_mask.bv >>> dt.month.val.toNat⟩ 1#u64 ≠ 0#u64 := by
            intro h0
            have := (u64_shr_and_one_eq_zero_iff c.months_mask dt.month.val.toNat (by omega)).mp h0
            simp [hm] at this
          exact bne_iff_ne.mpr hne4

end MatcherGuards


end CronProofs
