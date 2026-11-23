import Aeneas
import PionLean
import Http2.Types
import Http2.Funs
import Http2Proofs.Core

open Aeneas Aeneas.Std Result Pion http2

namespace Http2Proofs

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

end Http2Proofs
