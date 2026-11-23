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

/-- Theorem 15: `is_ical_name_byte` accepts exactly RFC 5545 §3.1 `ALPHA / DIGIT / "-"`. -/
lemma is_ical_name_byte_iff (c : I32) :
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

end IcalProofs
