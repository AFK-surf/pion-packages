import Aeneas
import PionLean
import Mime.Types
import Mime.Funs
import MimeProofs.Codec

open Aeneas Aeneas.Std Result Pion mime

namespace MimeProofs

/-- Theorem 12: RFC 5987 §3.2.1 `attr-char` is strictly a subset of RFC 9110 §5.6.2 `tchar`. -/
theorem attr_char_subset_of_tchar (c : I32) :
    is_attr_char_byte c = ok true → is_tchar_byte c = ok true := by
  unfold is_attr_char_byte is_tchar_byte
  intro h
  have ht := result_ok_inj h
  congr 1
  simp only [Bool.or_eq_true] at ht ⊢
  tauto

/-- Theorem 14: RFC 9110 §5.6.2 `tchar` forbids CTLs, SP, non-ASCII, and header delimiters (`/`, `;`, `=`, `"`). -/
theorem tchar_forbids_ctl_space_and_separators (c : I32)
    (h : c.val ≤ 32 ∨ c.val ≥ 127 ∨ c = 47#i32 ∨ c = 59#i32 ∨ c = 61#i32 ∨ c = 34#i32) :
    is_tchar_byte c = ok false := by
  unfold is_tchar_byte
  rcases h with hle | hge | rfl | rfl | rfl | rfl
  · have hne : ∀ k : I32, 33 ≤ k.val → (c == k) = false := fun k hk =>
      beq_false_of_ne (by intro heq; subst heq; omega)
    have h1 : ¬((48#i32 : I32) ≤ c) := by change ¬(48 ≤ c.val); omega
    have h2 : ¬((65#i32 : I32) ≤ c) := by change ¬(65 ≤ c.val); omega
    have h3 : ¬((97#i32 : I32) ≤ c) := by change ¬(97 ≤ c.val); omega
    simp [h1, h2, h3, hne 33#i32 (by decide), hne 35#i32 (by decide), hne 36#i32 (by decide),
          hne 37#i32 (by decide), hne 38#i32 (by decide), hne 39#i32 (by decide),
          hne 42#i32 (by decide), hne 43#i32 (by decide), hne 45#i32 (by decide),
          hne 46#i32 (by decide), hne 94#i32 (by decide), hne 95#i32 (by decide),
          hne 96#i32 (by decide), hne 124#i32 (by decide), hne 126#i32 (by decide)]
  · have hne : ∀ k : I32, k.val ≤ 126 → (c == k) = false := fun k hk =>
      beq_false_of_ne (by intro heq; subst heq; omega)
    have h1 : ¬(c ≤ (57#i32 : I32)) := by change ¬(c.val ≤ 57); omega
    have h2 : ¬(c ≤ (90#i32 : I32)) := by change ¬(c.val ≤ 90); omega
    have h3 : ¬(c ≤ (122#i32 : I32)) := by change ¬(c.val ≤ 122); omega
    simp [h1, h2, h3, hne 33#i32 (by decide), hne 35#i32 (by decide), hne 36#i32 (by decide),
          hne 37#i32 (by decide), hne 38#i32 (by decide), hne 39#i32 (by decide),
          hne 42#i32 (by decide), hne 43#i32 (by decide), hne 45#i32 (by decide),
          hne 46#i32 (by decide), hne 94#i32 (by decide), hne 95#i32 (by decide),
          hne 96#i32 (by decide), hne 124#i32 (by decide), hne 126#i32 (by decide)]
  · congr 1
  · congr 1
  · congr 1
  · congr 1

/-- Theorem 15: RFC 2046 §5.1.1 multipart `bcharsnospace` forbids CTLs (incl. CR/LF), SP, non-ASCII, `"`, and `\`. -/
theorem bchar_nospace_forbids_ctl_space_and_quotes (c : I32)
    (h : c.val ≤ 32 ∨ c.val ≥ 127 ∨ c = 34#i32 ∨ c = 92#i32) :
    is_bchar_nospace_byte c = ok false := by
  unfold is_bchar_nospace_byte
  rcases h with hle | hge | rfl | rfl
  · have hne : ∀ k : I32, 33 ≤ k.val → (c == k) = false := fun k hk =>
      beq_false_of_ne (by intro heq; subst heq; omega)
    have h1 : ¬((48#i32 : I32) ≤ c) := by change ¬(48 ≤ c.val); omega
    have h2 : ¬((65#i32 : I32) ≤ c) := by change ¬(65 ≤ c.val); omega
    have h3 : ¬((97#i32 : I32) ≤ c) := by change ¬(97 ≤ c.val); omega
    simp [h1, h2, h3, hne 39#i32 (by decide), hne 40#i32 (by decide), hne 41#i32 (by decide),
          hne 43#i32 (by decide), hne 44#i32 (by decide), hne 45#i32 (by decide),
          hne 46#i32 (by decide), hne 47#i32 (by decide), hne 58#i32 (by decide),
          hne 61#i32 (by decide), hne 63#i32 (by decide), hne 95#i32 (by decide)]
  · have hne : ∀ k : I32, k.val ≤ 126 → (c == k) = false := fun k hk =>
      beq_false_of_ne (by intro heq; subst heq; omega)
    have h1 : ¬(c ≤ (57#i32 : I32)) := by change ¬(c.val ≤ 57); omega
    have h2 : ¬(c ≤ (90#i32 : I32)) := by change ¬(c.val ≤ 90); omega
    have h3 : ¬(c ≤ (122#i32 : I32)) := by change ¬(c.val ≤ 122); omega
    simp [h1, h2, h3, hne 39#i32 (by decide), hne 40#i32 (by decide), hne 41#i32 (by decide),
          hne 43#i32 (by decide), hne 44#i32 (by decide), hne 45#i32 (by decide),
          hne 46#i32 (by decide), hne 47#i32 (by decide), hne 58#i32 (by decide),
          hne 61#i32 (by decide), hne 63#i32 (by decide), hne 95#i32 (by decide)]
  · congr 1
  · congr 1

end MimeProofs
