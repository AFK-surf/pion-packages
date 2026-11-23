import Aeneas
import PionLean
import HttpCache.Types
import HttpCache.Funs

open Aeneas Aeneas.Std Result Pion http_cache

namespace HttpCacheProofs

private lemma result_bind_ok' {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

/-- Theorem 17: Every heuristically cacheable status code is understood by the RFC 9111 cache engine. -/
theorem heuristically_cacheable_implies_understood (s : Std.I32)
    (h : is_heuristically_cacheable_status s = ok true) :
    is_understood_status s = ok true := by
  unfold is_understood_status
  rw [h, result_bind_ok']
  rfl

/-- Theorem 20: Every understood status code is a valid final HTTP status code in `[200, 599]` and excludes `206`. -/
theorem understood_status_final_range (s : Std.I32)
    (h : is_understood_status s = ok true) :
    200 ≤ s.val ∧ s.val ≤ 599 ∧ s.val ≠ 206 := by
  unfold is_understood_status at h
  unfold is_heuristically_cacheable_status at h
  rw [result_bind_ok'] at h
  simp only [ok.injEq, Bool.or_eq_true, beq_iff_eq] at h
  rcases h with ((((((h | h) | h) | h) | h) | h) | h)
  · rcases h with ((((((((((h | h) | h) | h) | h) | h) | h) | h) | h) | h) | h) <;> (subst h; decide)
  · subst h; decide
  · subst h; decide
  · subst h; decide
  · subst h; decide
  · subst h; decide
  · subst h; decide

private lemma i32_rem_pos_ok (a b : Std.I32) (ha : 0 ≤ a.val) (hb : 0 < b.val) :
    ∃ r : Std.I32, Pion.I32.rem a b = ok r ∧ r.val = a.val % b.val := by
  have hnotmin : ¬ (a.val = -2147483648 ∧ b.val = -1) := by omega
  have hbne : (b.val != 0) = true := bne_iff_ne.mpr (by omega)
  have hrem : Pion.I32.rem a b = ok ⟨a.bv.srem b.bv⟩ := by
    unfold Pion.I32.rem
    simp only [hnotmin, ↓reduceIte]
    change IScalar.rem a b = _
    unfold IScalar.rem
    simp only [hbne, ↓reduceIte]
  refine ⟨⟨a.bv.srem b.bv⟩, hrem, ?_⟩
  change (a.bv.srem b.bv).toInt = a.bv.toInt % b.bv.toInt
  rw [BitVec.toInt_srem]
  exact Int.tmod_eq_emod_of_nonneg ha

/-- Theorem 22: `is_leap_year` implements the exact Gregorian leap-year rule for all non-negative years. -/
theorem is_leap_year_spec (year : Std.I32) (hy : 0 ≤ year.val) :
    is_leap_year year = ok true ↔
      (year.val % 4 = 0 ∧ (year.val % 100 ≠ 0 ∨ year.val % 400 = 0)) := by
  obtain ⟨r4, hr4, hr4v⟩ := i32_rem_pos_ok year 4#i32 hy (by decide)
  obtain ⟨r100, hr100, hr100v⟩ := i32_rem_pos_ok year 100#i32 hy (by decide)
  obtain ⟨r400, hr400, hr400v⟩ := i32_rem_pos_ok year 400#i32 hy (by decide)
  have c4 : (4#i32 : Std.I32).val = 4 := rfl
  have c100 : (100#i32 : Std.I32).val = 100 := rfl
  have c400 : (400#i32 : Std.I32).val = 400 := rfl
  have c0 : (0#i32 : Std.I32).val = 0 := rfl
  rw [c4] at hr4v; rw [c100] at hr100v; rw [c400] at hr400v
  unfold is_leap_year
  rw [hr4, result_bind_ok']
  by_cases h4 : r4 = 0#i32
  · simp only [h4, ↓reduceIte]
    have hy4 : year.val % 4 = 0 := by rw [← hr4v, h4]; rfl
    rw [hr100, result_bind_ok']
    by_cases h100 : r100 = 0#i32
    · subst h100
      simp only [ne_eq, not_true_eq_false, ↓reduceIte]
      have hy100 : year.val % 100 = 0 := by rw [← hr100v]; rfl
      rw [hr400, result_bind_ok']
      simp only [ok.injEq, beq_iff_eq]
      constructor
      · intro h400; exact ⟨hy4, Or.inr (by rw [← hr400v, h400]; rfl)⟩
      · intro ⟨_, h⟩
        rcases h with hne | h400
        · exact (hne hy100).elim
        · exact IScalar.eq_of_val_eq (by omega)
    · simp only [ne_eq, h100, not_false_eq_true, ↓reduceIte]
      have hy100 : year.val % 100 ≠ 0 := fun h => h100 (IScalar.eq_of_val_eq (by omega))
      exact ⟨fun _ => ⟨hy4, Or.inl hy100⟩, fun _ => trivial⟩
  · simp only [h4, ↓reduceIte]
    have hy4 : year.val % 4 ≠ 0 := fun h => h4 (IScalar.eq_of_val_eq (by omega))
    constructor
    · intro hf; simp at hf
    · intro ⟨h, _⟩; exact (hy4 h).elim

/-- Theorem 23: `days_in_month` always succeeds and returns a day count in `[28, 31]` for all non-negative years. -/
theorem days_in_month_bounds (year month : Std.I32) (hy : 0 ≤ year.val) :
    ∃ d : Std.I32, days_in_month year month = ok d ∧ 28 ≤ d.val ∧ d.val ≤ 31 := by
  unfold days_in_month
  by_cases hm2 : month = 2#i32
  · simp only [hm2, ↓reduceIte]
    obtain ⟨r4, hr4, _⟩ := i32_rem_pos_ok year 4#i32 hy (by decide)
    obtain ⟨r100, hr100, _⟩ := i32_rem_pos_ok year 100#i32 hy (by decide)
    obtain ⟨r400, hr400, _⟩ := i32_rem_pos_ok year 400#i32 hy (by decide)
    have hly : ∃ b : Bool, is_leap_year year = ok b := by
      unfold is_leap_year
      rw [hr4, result_bind_ok']
      split_ifs
      · rw [hr100, result_bind_ok']
        split_ifs
        · exact ⟨true, rfl⟩
        · rw [hr400, result_bind_ok']; exact ⟨_, rfl⟩
      · exact ⟨false, rfl⟩
    obtain ⟨b, hb⟩ := hly
    rw [hb, result_bind_ok']
    cases b
    · exact ⟨28#i32, rfl, by decide, by decide⟩
    · exact ⟨29#i32, rfl, by decide, by decide⟩
  · simp only [hm2, ↓reduceIte]
    split_ifs
    · exact ⟨30#i32, rfl, by decide, by decide⟩
    · exact ⟨31#i32, rfl, by decide, by decide⟩

/-- Theorem 24: February has 29 days if and only if `is_leap_year` holds (and 28 days otherwise). -/
theorem days_in_month_feb_leap_iff (year : Std.I32) (hy : 0 ≤ year.val) :
    days_in_month year 2#i32 = ok 29#i32 ↔ is_leap_year year = ok true := by
  obtain ⟨r4, hr4, _⟩ := i32_rem_pos_ok year 4#i32 hy (by decide)
  obtain ⟨r100, hr100, _⟩ := i32_rem_pos_ok year 100#i32 hy (by decide)
  obtain ⟨r400, hr400, _⟩ := i32_rem_pos_ok year 400#i32 hy (by decide)
  have hly : ∃ b : Bool, is_leap_year year = ok b := by
    unfold is_leap_year
    rw [hr4, result_bind_ok']
    split_ifs
    · rw [hr100, result_bind_ok']
      split_ifs
      · exact ⟨true, rfl⟩
      · rw [hr400, result_bind_ok']; exact ⟨_, rfl⟩
    · exact ⟨false, rfl⟩
  obtain ⟨b, hb⟩ := hly
  unfold days_in_month
  simp only [↓reduceIte, hb, result_bind_ok']
  cases b <;> simp

end HttpCacheProofs
