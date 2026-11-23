import TimeProofs.Calendar

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace TimeProofs

open time

/-! ## 3. `Date`, `Time`, `DateTime`, `Timestamp` Strict Total Orders -/

/-- `Date.cmp` never traps and returns `{-1, 0, 1}`. -/
theorem date_cmp_total (a b : Date) :
    ∃ r : Std.I32, Date.cmp a b = ok r ∧ (r = (-1)#i32 ∨ r = 0#i32 ∨ r = 1#i32) := by
  unfold Date.cmp
  split_ifs <;> exact ⟨_, rfl, by decide⟩

theorem date_cmp_refl (a : Date) : Date.cmp a a = ok 0#i32 := by
  unfold Date.cmp; simp

theorem date_cmp_lt_iff (a b : Date) :
    Date.cmp a b = ok (-1)#i32 ↔
      (a.year.val < b.year.val ∨
        (a.year.val = b.year.val ∧ a.month.val < b.month.val) ∨
        (a.year.val = b.year.val ∧ a.month.val = b.month.val ∧ a.day.val < b.day.val)) := by
  unfold Date.cmp
  by_cases h1 : a.year = b.year
  · have h1v : a.year.val = b.year.val := congrArg IScalar.val h1
    simp only [h1, ne_eq, not_true_eq_false, ↓reduceIte, h1v, lt_self_iff_false, true_and, false_or]
    by_cases h2 : a.month = b.month
    · have h2v : a.month.val = b.month.val := congrArg IScalar.val h2
      simp only [h2, ne_eq, not_true_eq_false, ↓reduceIte, h2v, lt_self_iff_false, true_and, false_or]
      by_cases h3 : a.day = b.day
      · have h3v : a.day.val = b.day.val := congrArg IScalar.val h3
        simp only [h3, ne_eq, not_true_eq_false, ↓reduceIte, h3v, lt_self_iff_false, ok_eq_iff, iff_false]
        decide
      · have h3v : a.day.val ≠ b.day.val := fun hv => h3 (i32_ext hv)
        simp only [h3, ne_eq, not_false_eq_true, ↓reduceIte, ok_eq_iff]
        by_cases hlt : a.day < b.day
        · have hltv : a.day.val < b.day.val := hlt
          simp [hlt, hltv]
        · have hltv : ¬ a.day.val < b.day.val := hlt
          simp only [hlt, ↓reduceIte, hltv, iff_false]; decide
    · have h2v : a.month.val ≠ b.month.val := fun hv => h2 (i32_ext hv)
      simp only [h2, ne_eq, not_false_eq_true, ↓reduceIte, ok_eq_iff, h2v, false_and, or_false]
      by_cases hlt : a.month < b.month
      · have hltv : a.month.val < b.month.val := hlt
        simp [hlt, hltv]
      · have hltv : ¬ a.month.val < b.month.val := hlt
        simp only [hlt, ↓reduceIte, hltv, iff_false]; decide
  · have h1v : a.year.val ≠ b.year.val := fun hv => h1 (i32_ext hv)
    simp only [h1, ne_eq, not_false_eq_true, ↓reduceIte, ok_eq_iff, h1v, false_and, or_false]
    by_cases hlt : a.year < b.year
    · have hltv : a.year.val < b.year.val := hlt
      simp [hlt, hltv]
    · have hltv : ¬ a.year.val < b.year.val := hlt
      simp only [hlt, ↓reduceIte, hltv, iff_false]; decide

theorem date_cmp_eq_zero_iff (a b : Date) : Date.cmp a b = ok 0#i32 ↔ a = b := by
  unfold Date.cmp
  constructor
  · intro h
    by_cases h1 : a.year = b.year
    · simp only [h1, ne_eq, not_true_eq_false, ↓reduceIte] at h
      by_cases h2 : a.month = b.month
      · simp only [h2, ne_eq, not_true_eq_false, ↓reduceIte] at h
        by_cases h3 : a.day = b.day
        · cases a; cases b; congr
        · simp only [h3, ne_eq, not_false_eq_true, ↓reduceIte, ok_eq_iff] at h
          split_ifs at h <;> (exfalso; revert h; decide)
      · simp only [h2, ne_eq, not_false_eq_true, ↓reduceIte, ok_eq_iff] at h
        split_ifs at h <;> (exfalso; revert h; decide)
    · simp only [h1, ne_eq, not_false_eq_true, ↓reduceIte, ok_eq_iff] at h
      split_ifs at h <;> (exfalso; revert h; decide)
  · intro h; subst h; exact date_cmp_refl a

theorem date_cmp_antisymm (a b : Date) :
    Date.cmp a b = ok (-1)#i32 ↔ Date.cmp b a = ok 1#i32 := by
  unfold Date.cmp
  by_cases h1 : a.year = b.year
  · simp only [h1, ne_eq, not_true_eq_false, ↓reduceIte]
    by_cases h2 : a.month = b.month
    · simp only [h2, ne_eq, not_true_eq_false, ↓reduceIte]
      by_cases h3 : a.day = b.day
      · simp only [h3, ne_eq, not_true_eq_false, ↓reduceIte, ok_eq_iff]; decide
      · have h3' : b.day ≠ a.day := Ne.symm h3
        have h3v : a.day.val ≠ b.day.val := fun hv => h3 (i32_ext hv)
        simp only [h3, h3', ne_eq, not_false_eq_true, ↓reduceIte, ok_eq_iff]
        by_cases hlt : a.day.val < b.day.val
        · have hlt1 : a.day < b.day := hlt
          have hlt2 : ¬ (b.day < a.day) := show ¬ (b.day.val < a.day.val) by omega
          simp [hlt1, hlt2]
        · have hlt1 : ¬ (a.day < b.day) := hlt
          have hlt2 : b.day < a.day := show b.day.val < a.day.val by omega
          simp [hlt1, hlt2]
    · have h2' : b.month ≠ a.month := Ne.symm h2
      have h2v : a.month.val ≠ b.month.val := fun hv => h2 (i32_ext hv)
      simp only [h2, h2', ne_eq, not_false_eq_true, ↓reduceIte, ok_eq_iff]
      by_cases hlt : a.month.val < b.month.val
      · have hlt1 : a.month < b.month := hlt
        have hlt2 : ¬ (b.month < a.month) := show ¬ (b.month.val < a.month.val) by omega
        simp [hlt1, hlt2]
      · have hlt1 : ¬ (a.month < b.month) := hlt
        have hlt2 : b.month < a.month := show b.month.val < a.month.val by omega
        simp [hlt1, hlt2]
  · have h1' : b.year ≠ a.year := Ne.symm h1
    have h1v : a.year.val ≠ b.year.val := fun hv => h1 (i32_ext hv)
    simp only [h1, h1', ne_eq, not_false_eq_true, ↓reduceIte, ok_eq_iff]
    by_cases hlt : a.year.val < b.year.val
    · have hlt1 : a.year < b.year := hlt
      have hlt2 : ¬ (b.year < a.year) := show ¬ (b.year.val < a.year.val) by omega
      simp [hlt1, hlt2]
    · have hlt1 : ¬ (a.year < b.year) := hlt
      have hlt2 : b.year < a.year := show b.year.val < a.year.val by omega
      simp [hlt1, hlt2]

theorem date_cmp_trans_lt (a b c : Date)
    (hab : Date.cmp a b = ok (-1)#i32) (hbc : Date.cmp b c = ok (-1)#i32) :
    Date.cmp a c = ok (-1)#i32 := by
  rw [date_cmp_lt_iff] at hab hbc ⊢
  omega

/-- **Strict order preservation**: on valid dates, `Date.cmp d1 d2 = -1` iff
    `d1.to_epoch_days < d2.to_epoch_days`. -/
theorem to_epoch_days_strict_mono (d1 d2 : Date) (h1 : ValidDate d1) (h2 : ValidDate d2) :
    ∃ e1 e2 : Std.I32, Date.to_epoch_days d1 = ok e1 ∧ Date.to_epoch_days d2 = ok e2 ∧
      (Date.cmp d1 d2 = ok (-1)#i32 ↔ e1.val < e2.val) := by
  rcases to_epoch_days_spec d1 h1 with ⟨e1, he1, he1v, _⟩
  rcases to_epoch_days_spec d2 h2 with ⟨e2, he2, he2v, _⟩
  refine ⟨e1, e2, he1, he2, ?_⟩
  rw [date_cmp_lt_iff, he1v, he2v]
  exact specEpochDays_strict_mono h1 h2

/-- Valid civil `Time` (`00:00:00.000000000 ..= 23:59:59.999999999`). -/
def ValidTime (t : Time) : Prop :=
  0 ≤ t.hour.val ∧ t.hour.val ≤ 23 ∧
  0 ≤ t.minute.val ∧ t.minute.val ≤ 59 ∧
  0 ≤ t.second.val ∧ t.second.val ≤ 59 ∧
  0 ≤ t.nanosecond.val ∧ t.nanosecond.val ≤ 999999999

/-- Exact nanosecond of day for `Time`. -/
def totalTimeNanos (t : Time) : Int :=
  (t.hour.val * 3600 + t.minute.val * 60 + t.second.val) * 1000000000 + t.nanosecond.val

theorem time_to_second_of_day_spec (t : Time) (ht : ValidTime t) :
    ∃ s : Std.I32, Time.to_second_of_day t = ok s ∧
      s.val = t.hour.val * 3600 + t.minute.val * 60 + t.second.val ∧
      0 ≤ s.val ∧ s.val ≤ 86399 := by
  rcases ht with ⟨hh1, hh2, hm1, hm2, hs1, hs2, _, _⟩
  unfold Time.to_second_of_day
  have h1 : (Pion.I32.mul t.hour 3600#i32).val = t.hour.val * 3600 := by
    simpa using i32_mul_val t.hour 3600#i32 (by simp; omega) (by simp; omega)
  have h2 : (Pion.I32.mul t.minute 60#i32).val = t.minute.val * 60 := by
    simpa using i32_mul_val t.minute 60#i32 (by simp; omega) (by simp; omega)
  have h3 := i32_add_val (Pion.I32.mul t.hour 3600#i32) (Pion.I32.mul t.minute 60#i32)
    (by rw [h1, h2]; omega) (by rw [h1, h2]; omega)
  have h4 := i32_add_val (Pion.I32.add (Pion.I32.mul t.hour 3600#i32) (Pion.I32.mul t.minute 60#i32)) t.second
    (by rw [h3, h1, h2]; omega) (by rw [h3, h1, h2]; omega)
  refine ⟨_, rfl, ?_, ?_, ?_⟩
  · rw [h4, h3, h1, h2]
  · rw [h4, h3, h1, h2]; omega
  · rw [h4, h3, h1, h2]; omega

theorem time_cmp_spec (a b : Time) (ha : ValidTime a) (hb : ValidTime b) :
    Time.cmp a b = ok (if totalTimeNanos a < totalTimeNanos b then (-1)#i32
                       else if totalTimeNanos a = totalTimeNanos b then 0#i32
                       else 1#i32) := by
  rcases time_to_second_of_day_spec a ha with ⟨sa, hsa, hsav, _, _⟩
  rcases time_to_second_of_day_spec b hb with ⟨sb, hsb, hsbv, _, _⟩
  rcases ha with ⟨_, _, _, _, _, _, ha_n1, ha_n2⟩
  rcases hb with ⟨_, _, _, _, _, _, hb_n1, hb_n2⟩
  unfold Time.cmp
  rw [hsa, b_ok, hsb, b_ok]
  unfold totalTimeNanos
  by_cases hs : sa = sb
  · have hsv : sa.val = sb.val := congrArg IScalar.val hs
    simp only [hs, ne_eq, not_true_eq_false, ↓reduceIte]
    by_cases hn : a.nanosecond = b.nanosecond
    · have hnv : a.nanosecond.val = b.nanosecond.val := congrArg IScalar.val hn
      simp only [hn, ne_eq, not_true_eq_false, ↓reduceIte]
      congr 1; split_ifs <;> first | rfl | omega
    · have hnv : a.nanosecond.val ≠ b.nanosecond.val := fun h => hn (i32_ext h)
      simp only [hn, ne_eq, not_false_eq_true, ↓reduceIte]
      by_cases hlt : a.nanosecond.val < b.nanosecond.val
      · have hlt' : a.nanosecond < b.nanosecond := hlt
        have htot : (a.hour.val * 3600 + a.minute.val * 60 + a.second.val) * 1000000000 + a.nanosecond.val <
                    (b.hour.val * 3600 + b.minute.val * 60 + b.second.val) * 1000000000 + b.nanosecond.val := by omega
        simp only [hlt', htot, ↓reduceIte]
      · have hlt' : ¬ (a.nanosecond < b.nanosecond) := hlt
        have htot1 : ¬ ((a.hour.val * 3600 + a.minute.val * 60 + a.second.val) * 1000000000 + a.nanosecond.val <
                        (b.hour.val * 3600 + b.minute.val * 60 + b.second.val) * 1000000000 + b.nanosecond.val) := by omega
        have htot2 : ¬ ((a.hour.val * 3600 + a.minute.val * 60 + a.second.val) * 1000000000 + a.nanosecond.val =
                        (b.hour.val * 3600 + b.minute.val * 60 + b.second.val) * 1000000000 + b.nanosecond.val) := by omega
        simp only [hlt', htot1, htot2, ↓reduceIte]
  · have hsv : sa.val ≠ sb.val := fun h => hs (i32_ext h)
    simp only [hs, ne_eq, not_false_eq_true, ↓reduceIte]
    by_cases hlt : sa.val < sb.val
    · have hlt' : sa < sb := hlt
      have htot : (a.hour.val * 3600 + a.minute.val * 60 + a.second.val) * 1000000000 + a.nanosecond.val <
                  (b.hour.val * 3600 + b.minute.val * 60 + b.second.val) * 1000000000 + b.nanosecond.val := by omega
      simp only [hlt', htot, ↓reduceIte]
    · have hlt' : ¬ (sa < sb) := hlt
      have htot1 : ¬ ((a.hour.val * 3600 + a.minute.val * 60 + a.second.val) * 1000000000 + a.nanosecond.val <
                      (b.hour.val * 3600 + b.minute.val * 60 + b.second.val) * 1000000000 + b.nanosecond.val) := by omega
      have htot2 : ¬ ((a.hour.val * 3600 + a.minute.val * 60 + a.second.val) * 1000000000 + a.nanosecond.val =
                      (b.hour.val * 3600 + b.minute.val * 60 + b.second.val) * 1000000000 + b.nanosecond.val) := by omega
      simp only [hlt', htot1, htot2, ↓reduceIte]

theorem time_cmp_refl (a : Time) (ha : ValidTime a) : Time.cmp a a = ok 0#i32 := by
  rw [time_cmp_spec a a ha ha]; simp

theorem time_cmp_antisymm (a b : Time) (ha : ValidTime a) (hb : ValidTime b) :
    Time.cmp a b = ok (-1)#i32 ↔ Time.cmp b a = ok 1#i32 := by
  rw [time_cmp_spec a b ha hb, time_cmp_spec b a hb ha, ok_eq_iff, ok_eq_iff]
  split_ifs <;> first | exact Iff.rfl | decide | omega

theorem time_cmp_trans_lt (a b c : Time) (ha : ValidTime a) (hb : ValidTime b) (hc : ValidTime c)
    (hab : Time.cmp a b = ok (-1)#i32) (hbc : Time.cmp b c = ok (-1)#i32) :
    Time.cmp a c = ok (-1)#i32 := by
  rw [time_cmp_spec a b ha hb, ok_eq_iff] at hab
  rw [time_cmp_spec b c hb hc, ok_eq_iff] at hbc
  rw [time_cmp_spec a c ha hc, ok_eq_iff]
  split_ifs at hab hbc ⊢ <;> first | rfl | omega | (exfalso; revert hab; decide) | (exfalso; revert hbc; decide)

/-- Valid `Timestamp`: `0 ≤ nanos ≤ 999_999_999`. -/
def ValidTimestamp (t : Timestamp) : Prop :=
  0 ≤ t.nanos.val ∧ t.nanos.val ≤ 999999999

def totalTimestampNanos (t : Timestamp) : Int :=
  t.secs.val * 1000000000 + t.nanos.val

theorem timestamp_cmp_spec (a b : Timestamp) (ha : ValidTimestamp a) (hb : ValidTimestamp b) :
    Timestamp.cmp a b = ok (if totalTimestampNanos a < totalTimestampNanos b then (-1)#i32
                            else if totalTimestampNanos a = totalTimestampNanos b then 0#i32
                            else 1#i32) := by
  rcases ha with ⟨ha1, ha2⟩
  rcases hb with ⟨hb1, hb2⟩
  unfold Timestamp.cmp totalTimestampNanos
  by_cases hs : a.secs = b.secs
  · have hsv : a.secs.val = b.secs.val := congrArg IScalar.val hs
    simp only [hs, ne_eq, not_true_eq_false, ↓reduceIte]
    by_cases hn : a.nanos = b.nanos
    · have hnv : a.nanos.val = b.nanos.val := congrArg IScalar.val hn
      simp only [hn, ne_eq, not_true_eq_false, ↓reduceIte]
      congr 1; split_ifs <;> first | rfl | omega
    · have hnv : a.nanos.val ≠ b.nanos.val := fun h => hn (i32_ext h)
      simp only [hn, ne_eq, not_false_eq_true, ↓reduceIte]
      by_cases hlt : a.nanos.val < b.nanos.val
      · have hlt' : a.nanos < b.nanos := hlt
        simp only [hlt', ↓reduceIte]
        congr 1; split_ifs <;> first | rfl | omega
      · have hlt' : ¬ (a.nanos < b.nanos) := hlt
        simp only [hlt', ↓reduceIte]
        congr 1; split_ifs <;> first | rfl | omega
  · have hsv : a.secs.val ≠ b.secs.val := fun h => hs (i64_ext h)
    simp only [hs, ne_eq, not_false_eq_true, ↓reduceIte]
    by_cases hlt : a.secs.val < b.secs.val
    · have hlt' : a.secs < b.secs := hlt
      have htot : a.secs.val * 1000000000 + a.nanos.val < b.secs.val * 1000000000 + b.nanos.val := by omega
      simp only [hlt', htot, ↓reduceIte]
    · have hlt' : ¬ (a.secs < b.secs) := hlt
      have h1 : ¬ (a.secs.val * 1000000000 + a.nanos.val < b.secs.val * 1000000000 + b.nanos.val) := by omega
      have h2 : ¬ (a.secs.val * 1000000000 + a.nanos.val = b.secs.val * 1000000000 + b.nanos.val) := by omega
      simp only [hlt', h1, h2, ↓reduceIte]

theorem timestamp_cmp_refl (a : Timestamp) : Timestamp.cmp a a = ok 0#i32 := by
  unfold Timestamp.cmp; simp

theorem timestamp_cmp_antisymm (a b : Timestamp) (ha : ValidTimestamp a) (hb : ValidTimestamp b) :
    Timestamp.cmp a b = ok (-1)#i32 ↔ Timestamp.cmp b a = ok 1#i32 := by
  rw [timestamp_cmp_spec a b ha hb, timestamp_cmp_spec b a hb ha, ok_eq_iff, ok_eq_iff]
  split_ifs <;> first | exact Iff.rfl | decide | omega

theorem timestamp_cmp_trans_lt (a b c : Timestamp)
    (ha : ValidTimestamp a) (hb : ValidTimestamp b) (hc : ValidTimestamp c)
    (hab : Timestamp.cmp a b = ok (-1)#i32) (hbc : Timestamp.cmp b c = ok (-1)#i32) :
    Timestamp.cmp a c = ok (-1)#i32 := by
  rw [timestamp_cmp_spec a b ha hb, ok_eq_iff] at hab
  rw [timestamp_cmp_spec b c hb hc, ok_eq_iff] at hbc
  rw [timestamp_cmp_spec a c ha hc, ok_eq_iff]
  split_ifs at hab hbc ⊢ <;> first | rfl | omega | (exfalso; revert hab; decide) | (exfalso; revert hbc; decide)

theorem datetime_cmp_refl (a : DateTime) (ht : ValidTime a.time) :
    DateTime.cmp a a = ok 0#i32 := by
  unfold DateTime.cmp
  rw [date_cmp_refl, b_ok]
  simp [time_cmp_refl a.time ht]

theorem datetime_cmp_antisymm (a b : DateTime)
    (ha : ValidTime a.time) (hb : ValidTime b.time) :
    DateTime.cmp a b = ok (-1)#i32 ↔ DateTime.cmp b a = ok 1#i32 := by
  unfold DateTime.cmp
  rcases date_cmp_total a.date b.date with ⟨r, hr, hr_cases⟩
  rw [hr, b_ok]
  rcases hr_cases with rfl | rfl | rfl
  · have hba := (date_cmp_antisymm a.date b.date).mp hr
    rw [hba, b_ok]; simp
  · have heq := (date_cmp_eq_zero_iff a.date b.date).mp hr
    rw [heq, date_cmp_refl, b_ok]
    simp only [ne_eq, not_true_eq_false, ↓reduceIte]
    rw [time_cmp_spec a.time b.time ha hb, time_cmp_spec b.time a.time hb ha, b_ok, b_ok, ok_eq_iff, ok_eq_iff]
    split_ifs <;> first | exact Iff.rfl | decide | omega
  · have hba := (date_cmp_antisymm b.date a.date).mpr hr
    rw [hba, b_ok]; simp

theorem datetime_cmp_trans_lt (a b c : DateTime)
    (ha : ValidTime a.time) (hb : ValidTime b.time) (hc : ValidTime c.time)
    (hab : DateTime.cmp a b = ok (-1)#i32) (hbc : DateTime.cmp b c = ok (-1)#i32) :
    DateTime.cmp a c = ok (-1)#i32 := by
  unfold DateTime.cmp at hab hbc ⊢
  rcases date_cmp_total a.date b.date with ⟨rab, hrab, hrab_c⟩
  rcases date_cmp_total b.date c.date with ⟨rbc, hrbc, hrbc_c⟩
  rw [hrab, b_ok] at hab
  rw [hrbc, b_ok] at hbc
  rcases hrab_c with rfl | rfl | rfl
  · rcases hrbc_c with rfl | rfl | rfl
    · rw [date_cmp_trans_lt a.date b.date c.date hrab hrbc, b_ok]; simp
    · have hbe := (date_cmp_eq_zero_iff b.date c.date).mp hrbc
      rw [← hbe, hrab, b_ok]; simp
    · rw [if_pos (by decide), ok_eq_iff] at hbc; exfalso; revert hbc; decide
  · have hae := (date_cmp_eq_zero_iff a.date b.date).mp hrab
    simp only [ne_eq, not_true_eq_false, ↓reduceIte] at hab
    rcases hrbc_c with rfl | rfl | rfl
    · rw [hae, hrbc, b_ok]; simp
    · have hbe := (date_cmp_eq_zero_iff b.date c.date).mp hrbc
      rw [hae, hbe, date_cmp_refl, b_ok]
      simp only [ne_eq, not_true_eq_false, ↓reduceIte] at hbc ⊢
      have ht := time_cmp_trans_lt a.time b.time c.time ha hb hc
      have hab' : Time.cmp a.time b.time = ok (-1)#i32 := by
        rcases time_cmp_spec a.time b.time ha hb with h1; rw [h1, b_ok] at hab; rw [h1]; exact hab
      have hbc' : Time.cmp b.time c.time = ok (-1)#i32 := by
        rcases time_cmp_spec b.time c.time hb hc with h1; rw [h1, b_ok] at hbc; rw [h1]; exact hbc
      rw [ht hab' hbc', b_ok]
    · rw [if_pos (by decide), ok_eq_iff] at hbc; exfalso; revert hbc; decide
  · rw [if_pos (by decide), ok_eq_iff] at hab; exfalso; revert hab; decide


end TimeProofs
