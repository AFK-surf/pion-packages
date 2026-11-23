import Aeneas
import PionLean
import Http2.Types
import Http2.Funs
import Http2Proofs.Core

open Aeneas Aeneas.Std Result Pion http2

namespace Http2Proofs

/-- Theorem 16: RFC 9113 §6.5.2 SETTINGS_ENABLE_PUSH (0x2) accepts only 0 or 1. -/
theorem setting_enable_push_iff (v : I64) :
    (validate_setting_value 2#i32 v = ok 0#i32 ↔ v = 0#i64 ∨ v = 1#i64) ∧
    (validate_setting_value 2#i32 v = ok 1#i32 ↔ v ≠ 0#i64 ∧ v ≠ 1#i64) := by
  unfold validate_setting_value
  by_cases h0 : v = 0#i64
  · subst h0; simp
  · by_cases h1 : v = 1#i64
    · subst h1; simp
    · simp [h0, h1]

/-- Theorem 17: RFC 9113 §6.5.2 SETTINGS_INITIAL_WINDOW_SIZE (0x4) returns FLOW_CONTROL_ERROR iff v > 2^31 - 1. -/
theorem setting_initial_window_size_iff (v : I64) :
    (validate_setting_value 4#i32 v = ok 2#i32 ↔ v.val > 2147483647) ∧
    (validate_setting_value 4#i32 v = ok 0#i32 ↔ v.val ≤ 2147483647) := by
  unfold validate_setting_value
  by_cases h : v.val > 2147483647
  · have hlt : (2147483647#i64 : I64) < v := h
    simp [hlt, h, show ¬(v.val ≤ 2147483647) by omega]
  · have hle : ¬((2147483647#i64 : I64) < v) := h
    simp [hle, h, show v.val ≤ 2147483647 by omega]

/-- Theorem 18: RFC 9113 §6.5.2 SETTINGS_MAX_FRAME_SIZE (0x5) accepts iff 16384 ≤ v ≤ 16777215. -/
theorem setting_max_frame_size_iff (v : I64) :
    (validate_setting_value 5#i32 v = ok 0#i32 ↔ 16384 ≤ v.val ∧ v.val ≤ 16777215) ∧
    (validate_setting_value 5#i32 v = ok 1#i32 ↔ v.val < 16384 ∨ v.val > 16777215) := by
  unfold validate_setting_value
  by_cases hlo : v.val < 16384
  · have h1 : v < (16384#i64 : I64) := hlo
    simp [h1, hlo, show ¬(16384 ≤ v.val ∧ v.val ≤ 16777215) by omega]
  · by_cases hhi : v.val > 16777215
    · have h2 : (16777215#i64 : I64) < v := hhi
      simp [h2, hhi, show ¬(16384 ≤ v.val ∧ v.val ≤ 16777215) by omega]
    · have h1 : ¬(v < (16384#i64 : I64)) := hlo
      have h2 : ¬((16777215#i64 : I64) < v) := hhi
      simp [h1, h2, show 16384 ≤ v.val ∧ v.val ≤ 16777215 by omega,
            show ¬(v.val < 16384 ∨ v.val > 16777215) by omega]

/-- Theorem 19: RFC 8441 SETTINGS_ENABLE_CONNECT_PROTOCOL (0x8) accepts only 0 or 1. -/
theorem setting_enable_connect_iff (v : I64) :
    (validate_setting_value 8#i32 v = ok 0#i32 ↔ v = 0#i64 ∨ v = 1#i64) ∧
    (validate_setting_value 8#i32 v = ok 1#i32 ↔ v ≠ 0#i64 ∧ v ≠ 1#i64) := by
  unfold validate_setting_value
  by_cases h0 : v = 0#i64
  · subst h0; simp
  · by_cases h1 : v = 1#i64
    · subst h1; simp
    · simp [h0, h1]

/-- Theorem 20: RFC 9113 §6.5.2 unknown SETTINGS identifiers MUST be ignored (always return 0). -/
theorem setting_unknown_ignored (id : I32) (v : I64)
    (h2 : id ≠ 2#i32) (h4 : id ≠ 4#i32) (h5 : id ≠ 5#i32) (h8 : id ≠ 8#i32) :
    validate_setting_value id v = ok 0#i32 := by
  unfold validate_setting_value
  simp [h2, h4, h5, h8]

/-- Theorem 21: RFC 9113 §8.2.1 HTTP/2 header names MUST NOT contain uppercase ASCII letters A–Z. -/
theorem h2_name_forbids_uppercase (b : I32) (hlo : 65 ≤ b.val) (hhi : b.val ≤ 90) :
    is_valid_h2_name_byte b = ok false := by
  unfold is_valid_h2_name_byte
  have hne : ∀ c : I32, (c.val < 65 ∨ c.val > 90) → (b == c) = false := by
    intro c hc
    apply beq_false_of_ne
    intro heq
    subst heq; omega
  have h1 : ¬((97#i32 : I32) ≤ b) := by change ¬(97 ≤ b.val); omega
  have h2 : ¬(b ≤ (57#i32 : I32)) := by change ¬(b.val ≤ 57); omega
  simp only [h1, h2, decide_false, Bool.false_and, Bool.and_false]
  simp [hne 45#i32 (by decide), hne 95#i32 (by decide), hne 46#i32 (by decide),
        hne 33#i32 (by decide), hne 35#i32 (by decide), hne 36#i32 (by decide),
        hne 37#i32 (by decide), hne 38#i32 (by decide), hne 39#i32 (by decide),
        hne 42#i32 (by decide), hne 43#i32 (by decide), hne 94#i32 (by decide),
        hne 96#i32 (by decide), hne 124#i32 (by decide), hne 126#i32 (by decide)]

/-- Theorem 22: RFC 9113 §8.2.1 HTTP/2 header names allow all lowercase ASCII letters a–z and digits 0–9. -/
theorem h2_name_allows_lower_and_digit (b : I32)
    (h : (97 ≤ b.val ∧ b.val ≤ 122) ∨ (48 ≤ b.val ∧ b.val ≤ 57)) :
    is_valid_h2_name_byte b = ok true := by
  unfold is_valid_h2_name_byte
  rcases h with ⟨hlo, hhi⟩ | ⟨hlo, hhi⟩
  · have h1 : (97#i32 : I32) ≤ b := hlo
    have h2 : b ≤ (122#i32 : I32) := hhi
    simp [h1, h2]
  · have h1 : ¬((97#i32 : I32) ≤ b) := by change ¬(97 ≤ b.val); omega
    have h3 : (48#i32 : I32) ≤ b := hlo
    have h4 : b ≤ (57#i32 : I32) := hhi
    simp [h1, h3, h4]

/-- Theorem 23: RFC 9113 §8.2.1 HTTP/2 header names forbid all CTL bytes, SP (≤ 32), and DEL/non-ASCII (≥ 127). -/
theorem h2_name_forbids_ctl_and_space (b : I32) (h : b.val ≤ 32 ∨ b.val ≥ 127) :
    is_valid_h2_name_byte b = ok false := by
  unfold is_valid_h2_name_byte
  have hne : ∀ c : I32, (33 ≤ c.val ∧ c.val ≤ 126) → (b == c) = false := by
    intro c hc
    apply beq_false_of_ne
    intro heq
    subst heq; omega
  have h1 : ¬((97#i32 : I32) ≤ b ∧ b ≤ (122#i32 : I32)) := by
    change ¬(97 ≤ b.val ∧ b.val ≤ 122); omega
  have h2 : ¬((48#i32 : I32) ≤ b ∧ b ≤ (57#i32 : I32)) := by
    change ¬(48 ≤ b.val ∧ b.val ≤ 57); omega
  have hb1 : (decide (b >= 97#i32) && decide (b <= 122#i32)) = false := by
    rw [Bool.and_eq_false_iff]; by_cases ha : (97#i32 : I32) ≤ b
    · right; rw [decide_eq_false_iff_not]; intro hb; exact h1 ⟨ha, hb⟩
    · left; rw [decide_eq_false_iff_not]; exact ha
  have hb2 : (decide (b >= 48#i32) && decide (b <= 57#i32)) = false := by
    rw [Bool.and_eq_false_iff]; by_cases ha : (48#i32 : I32) ≤ b
    · right; rw [decide_eq_false_iff_not]; intro hb; exact h2 ⟨ha, hb⟩
    · left; rw [decide_eq_false_iff_not]; exact ha
  simp only [hb1, hb2]
  simp [hne 45#i32 (by decide), hne 95#i32 (by decide), hne 46#i32 (by decide),
        hne 33#i32 (by decide), hne 35#i32 (by decide), hne 36#i32 (by decide),
        hne 37#i32 (by decide), hne 38#i32 (by decide), hne 39#i32 (by decide),
        hne 42#i32 (by decide), hne 43#i32 (by decide), hne 94#i32 (by decide),
        hne 96#i32 (by decide), hne 124#i32 (by decide), hne 126#i32 (by decide)]

/-- Theorem 24: RFC 9113 §8.2.1 header value CTL predicate: HTAB (9) and printable ASCII (32..126) are allowed, while 0..8, 10..31, 127 are forbidden. -/
theorem h2_value_ctl_spec (b : I32) :
    (b.val = 9 ∨ (32 ≤ b.val ∧ b.val ≤ 126) → is_h2_value_ctl b = ok false) ∧
    (((0 ≤ b.val ∧ b.val ≤ 8) ∨ (10 ≤ b.val ∧ b.val ≤ 31) ∨ b.val = 127) →
      is_h2_value_ctl b = ok true) := by
  constructor
  · intro h
    unfold is_h2_value_ctl
    rcases h with h9 | ⟨hlo, hhi⟩
    · have hb9 : b = 9#i32 := by
        apply iscalar_eq_of_val_eq; exact h9
      subst hb9; simp
    · have hlt : ¬(b < (32#i32 : I32)) := by change ¬(b.val < 32); omega
      have h127 : (b == 127#i32) = false := by
        apply beq_false_of_ne; intro heq; subst heq; have : (127#i32 : I32).val = 127 := rfl; omega
      simp [hlt, h127]
  · intro h
    unfold is_h2_value_ctl
    rcases h with ⟨h0, h8⟩ | ⟨h10, h31⟩ | h127
    · have hlt : b < (32#i32 : I32) := by change b.val < 32; omega
      have hne9 : (b != 9#i32) = true := by
        simp; intro heq; omega
      simp [hlt, hne9]
    · have hlt : b < (32#i32 : I32) := by change b.val < 32; omega
      have hne9 : (b != 9#i32) = true := by
        simp; intro heq; omega
      simp [hlt, hne9]
    · have hb127 : b = 127#i32 := by
        apply iscalar_eq_of_val_eq; exact h127
      subst hb127; simp

/-- Theorem 25: `is_ascii_digit` characterizes '0'..'9' (48..57) and is disjoint from edge whitespace (SP/HTAB). -/
theorem is_ascii_digit_and_edge_ws_spec (b : I32) :
    (is_ascii_digit b = ok true ↔ 48 ≤ b.val ∧ b.val ≤ 57) ∧
    (is_h2_value_edge_ws b = ok true → is_ascii_digit b = ok false) := by
  constructor
  · unfold is_ascii_digit
    constructor
    · intro h
      have ht : (decide (b >= 48#i32) && decide (b <= 57#i32)) = true := result_ok_inj h
      simp only [Bool.and_eq_true, decide_eq_true_eq] at ht
      exact ht
    · intro ⟨hlo, hhi⟩
      have h1 : (48#i32 : I32) ≤ b := hlo
      have h2 : b ≤ (57#i32 : I32) := hhi
      simp [h1, h2]
  · unfold is_h2_value_edge_ws is_ascii_digit
    intro h
    have ht : ((b == 32#i32) || (b == 9#i32)) = true := result_ok_inj h
    simp only [Bool.or_eq_true, beq_iff_eq] at ht
    rcases ht with rfl | rfl <;> simp

end Http2Proofs
