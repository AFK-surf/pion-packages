import Aeneas
import PionLean
import Ical.Types
import Ical.Funs

open Aeneas Aeneas.Std Result Pion ical

namespace IcalProofs

private lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

private lemma i32_sub_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  have hwrap : (Pion.I32.sub a b).val = Int.bmod (a.val - b.val) (2 ^ 32) := by
    change (I32.wrapping_sub a b).val = Int.bmod (a.val - b.val) (2 ^ 32)
    simp only [I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

/-- Theorem 13: `ascii_upper_byte` is idempotent on all `I32` values. -/
theorem ascii_upper_byte_idempotent (c : I32) :
    (do let u ← ascii_upper_byte c; ascii_upper_byte u) = ascii_upper_byte c := by
  unfold ascii_upper_byte
  rw [result_bind_ok]
  by_cases h : ((decide (c >= 97#i32)) && (decide (c <= 122#i32))) = true
  · simp only [h, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at h
    have hlo : 97 ≤ c.val := h.1
    have hhi : c.val ≤ 122 := h.2
    have c32 : (32#i32 : I32).val = 32 := rfl
    have hsub := i32_sub_val_of_bounds c 32#i32 (by omega) (by omega)
    have hnot : ¬(Pion.I32.sub c 32#i32 >= 97#i32) := fun hge => by
      have : 97 ≤ (Pion.I32.sub c 32#i32).val := hge; omega
    simp only [hnot, decide_false, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
  · have hf : ((decide (c >= 97#i32)) && (decide (c <= 122#i32))) = false := Bool.eq_false_iff.mpr h
    simp only [hf, Bool.false_eq_true, ↓reduceIte]

/-- Theorem 14: `ascii_upper_byte` never produces an ASCII lowercase byte `'a'..'z'`. -/
theorem ascii_upper_byte_no_lowercase (c u : I32) (h : ascii_upper_byte c = ok u) :
    ¬(97 ≤ u.val ∧ u.val ≤ 122) := by
  unfold ascii_upper_byte at h
  have hu := result_ok_inj h
  subst hu
  by_cases hlo : ((decide (c >= 97#i32)) && (decide (c <= 122#i32))) = true
  · simp only [hlo, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hlo
    have h1 : 97 ≤ c.val := hlo.1
    have h2 : c.val ≤ 122 := hlo.2
    have c32 : (32#i32 : I32).val = 32 := rfl
    have hsub := i32_sub_val_of_bounds c 32#i32 (by omega) (by omega)
    omega
  · have hf : ((decide (c >= 97#i32)) && (decide (c <= 122#i32))) = false := Bool.eq_false_iff.mpr hlo
    simp only [hf, Bool.false_eq_true, ↓reduceIte]
    intro ⟨h1, h2⟩
    apply hlo
    simp only [Bool.and_eq_true, decide_eq_true_eq]
    exact ⟨h1, h2⟩

/-- Theorem 15: `is_ical_name_byte` accepts exactly RFC 5545 §3.1 `ALPHA / DIGIT / "-"`. -/
theorem is_ical_name_byte_iff (c : I32) :
    is_ical_name_byte c = ok true ↔
      ((65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122) ∨
       (48 ≤ c.val ∧ c.val ≤ 57) ∨ c.val = 45) := by
  unfold is_ical_name_byte
  constructor
  · intro h
    have h1 := result_ok_inj h
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at h1
    rcases h1 with (((⟨a, b⟩ | ⟨a, b⟩) | ⟨a, b⟩) | heq)
    · exact Or.inl ⟨a, b⟩
    · exact Or.inr (Or.inl ⟨a, b⟩)
    · exact Or.inr (Or.inr (Or.inl ⟨a, b⟩))
    · exact Or.inr (Or.inr (Or.inr (by rw [heq]; rfl)))
  · intro h
    apply congrArg ok
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq]
    rcases h with ⟨a, b⟩ | ⟨a, b⟩ | ⟨a, b⟩ | heq
    · left; left; left; exact ⟨a, b⟩
    · left; left; right; exact ⟨a, b⟩
    · left; right; exact ⟨a, b⟩
    · right; exact IScalar.eq_of_val_eq heq

/-- Theorem 16: `is_ical_name_byte` is closed under ASCII uppercasing. -/
theorem is_ical_name_byte_upper_closed (c : I32) (h : is_ical_name_byte c = ok true) :
    (do let u ← ascii_upper_byte c; is_ical_name_byte u) = ok true := by
  have hc := (is_ical_name_byte_iff c).mp h
  unfold ascii_upper_byte
  rw [result_bind_ok]
  rw [is_ical_name_byte_iff]
  by_cases hlo : ((decide (c >= 97#i32)) && (decide (c <= 122#i32))) = true
  · simp only [hlo, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hlo
    have h1 : 97 ≤ c.val := hlo.1
    have h2 : c.val ≤ 122 := hlo.2
    have c32 : (32#i32 : I32).val = 32 := rfl
    have hsub := i32_sub_val_of_bounds c 32#i32 (by omega) (by omega)
    exact Or.inl ⟨by omega, by omega⟩
  · have hf : ((decide (c >= 97#i32)) && (decide (c <= 122#i32))) = false := Bool.eq_false_iff.mpr hlo
    simp only [hf, Bool.false_eq_true, ↓reduceIte]
    exact hc

/-- Theorem 17: `is_ical_name_byte` rejects RFC 5545 content-line delimiters (`\r`, `\n`, `:`, `;`, space). -/
theorem is_ical_name_byte_rejects_delimiters :
    is_ical_name_byte 13#i32 = ok false ∧
    is_ical_name_byte 10#i32 = ok false ∧
    is_ical_name_byte 58#i32 = ok false ∧
    is_ical_name_byte 59#i32 = ok false ∧
    is_ical_name_byte 32#i32 = ok false := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> (unfold is_ical_name_byte; apply congrArg ok; decide)

/-- Theorem 18: `clamp_leap_second` maps `[0, 60]` into `[0, 59]`. -/
theorem clamp_leap_second_bounds (sc : I32) (h0 : 0 ≤ sc.val) (h60 : sc.val ≤ 60) :
    ∃ r, clamp_leap_second sc = ok r ∧ 0 ≤ r.val ∧ r.val ≤ 59 := by
  unfold clamp_leap_second
  by_cases h : sc = 60#i32
  · simp only [h, ↓reduceIte]
    exact ⟨59#i32, rfl, by decide, by decide⟩
  · simp only [h, ↓reduceIte]
    have hne : sc.val ≠ 60 := fun hv => h (IScalar.eq_of_val_eq hv)
    exact ⟨sc, rfl, h0, by omega⟩

/-- Theorem 19: `clamp_leap_second` is idempotent. -/
theorem clamp_leap_second_idempotent (sc : I32) :
    (do let r ← clamp_leap_second sc; clamp_leap_second r) = clamp_leap_second sc := by
  unfold clamp_leap_second
  rw [result_bind_ok]
  by_cases h : sc = 60#i32
  · simp only [h, ↓reduceIte]
    have hne : (59#i32 : I32) ≠ 60#i32 := by decide
    simp only [hne, ↓reduceIte]
  · simp only [h, ↓reduceIte]

/-- Theorem 20: `parse_weekday_2_bytes` always returns a code in `[-1, 6]`. -/
theorem parse_weekday_2_bytes_range (a0 b0 : I32) :
    ∃ r, parse_weekday_2_bytes a0 b0 = ok r ∧ -1 ≤ r.val ∧ r.val ≤ 6 := by
  unfold parse_weekday_2_bytes ascii_upper_byte
  rw [result_bind_ok, result_bind_ok]
  split_ifs
  all_goals exact ⟨_, rfl, by decide, by decide⟩

/-- Theorem 21: `parse_weekday_2_bytes` decodes all 7 RFC 5545 weekdays (`MO`..`SU`) and lowercase `mo`..`su` into `0..6`. -/
theorem parse_weekday_2_bytes_all_7 :
    parse_weekday_2_bytes 77#i32 79#i32 = ok 0#i32 ∧
    parse_weekday_2_bytes 84#i32 85#i32 = ok 1#i32 ∧
    parse_weekday_2_bytes 87#i32 69#i32 = ok 2#i32 ∧
    parse_weekday_2_bytes 84#i32 72#i32 = ok 3#i32 ∧
    parse_weekday_2_bytes 70#i32 82#i32 = ok 4#i32 ∧
    parse_weekday_2_bytes 83#i32 65#i32 = ok 5#i32 ∧
    parse_weekday_2_bytes 83#i32 85#i32 = ok 6#i32 ∧
    parse_weekday_2_bytes 109#i32 111#i32 = ok 0#i32 ∧
    parse_weekday_2_bytes 115#i32 117#i32 = ok 6#i32 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals
    unfold parse_weekday_2_bytes ascii_upper_byte
    rw [result_bind_ok, result_bind_ok]
    simp

/-- Theorem 22: `ParseLimits::default` sets strictly positive bounds on every DoS defense limit. -/
theorem parse_limits_default_positive :
    ∃ lim, ParseLimits.default = ok lim ∧
      0 < lim.max_depth.val ∧ 0 < lim.max_lines.val ∧ 0 < lim.max_components.val ∧
      0 < lim.max_properties_per_component.val ∧ 0 < lim.max_line_bytes.val := by
  unfold ParseLimits.default
  exact ⟨_, rfl, by decide, by decide, by decide, by decide, by decide⟩

end IcalProofs
